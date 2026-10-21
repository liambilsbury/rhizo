import errno
import ipaddress
import os
import select
import socket
import threading
import time

from nb_common import Service, log, sanitize_for_log
from nb_hoststate import split_proxy_url

HEAD_MAX = 64 * 1024
RELAY_MAX = 1 << 20
RECV_CHUNK = 65536
HEAD_TIMEOUT = 10.0
CONNECT_TIMEOUT = 10.0
RESOLVE_TIMEOUT = 5.0
IDLE_TIMEOUT = 300.0

MAX_CONNS = 256

STATE_HEAD = "head"
STATE_RESOLVING = "resolving"
STATE_CONNECTING = "connecting"
STATE_RELAY = "relay"
STATE_DEAD = "dead"

DEFAULT_DENIED_NETWORKS = (
    "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
    "::1/128", "fe80::/10", "ff00::/8",
)

CONNECT_POLICY_DENY_LOCAL = "deny-local"
CONNECT_POLICY_ANY = "any"
CONNECT_POLICY_DEFAULT = CONNECT_POLICY_DENY_LOCAL


def _parse_networks(cidrs):
    """parse CIDR strings into networks"""
    nets = []
    for c in cidrs:
        try:
            nets.append(ipaddress.ip_network(c, strict=False))
        except ValueError:
            log("NB_PROXY_CONFIG_BAD entry=%s reason=bad-cidr", sanitize_for_log(str(c)))
    return nets


class TargetPolicy:
    """policy for allowed proxy targets"""

    def __init__(self, deny=DEFAULT_DENIED_NETWORKS, allow=(), host_addrs=()):
        """build the allow and deny network lists"""
        self.allow_nets = _parse_networks(allow)
        self.deny_nets = _parse_networks(deny)
        self.deny_nets += _parse_networks(
            ["%s/32" % a if ":" not in a else "%s/128" % a for a in host_addrs])

    def is_allowed(self, ip_str):
        """return whether an address is allowed"""
        try:
            addr = ipaddress.ip_address(ip_str)
        except ValueError:
            return False
        for net in self.allow_nets:
            if addr in net:
                return True
        for net in self.deny_nets:
            if addr in net:
                return False
        return True


def _literal_ip(host):
    """parse host for an IP address"""
    try:
        ipaddress.ip_address(host)
        return host
    except ValueError:
        return None


def target_policy_for_mode(mode, allow=(), host_addrs=()):
    """build the TargetPolicy for a connect mode"""
    if mode == CONNECT_POLICY_ANY:
        return TargetPolicy(deny=[], allow=[])
    if mode != CONNECT_POLICY_DENY_LOCAL:
        log("NB_PROXY_CONFIG_BAD entry=%s reason=unknown-connect-policy",
            sanitize_for_log(str(mode)))
    return TargetPolicy(allow=allow, host_addrs=host_addrs)


def _policy_from_cfg(cfg):
    """build the TargetPolicy from the config"""
    mode = getattr(cfg, "proxy_connect_policy", None) or CONNECT_POLICY_DEFAULT
    allow = getattr(cfg, "proxy_allow", None) or []
    host_addrs = getattr(cfg, "proxy_host_addrs", None) or []
    return target_policy_for_mode(mode, allow=allow, host_addrs=host_addrs)


class _Resolution:
    """hostname lookup on a separate thread"""

    def __init__(self, host):
        """start a name lookup thread"""
        self.host = host
        self.ip = None
        self.error = None
        self.notify_r, self._notify_w = socket.socketpair()
        self.notify_r.setblocking(False)
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        """resolve the host name and signal completion"""
        try:
            infos = socket.getaddrinfo(self.host, None, socket.AF_UNSPEC, socket.SOCK_STREAM)
            self.ip = infos[0][4][0]
        except (OSError, UnicodeError) as e:
            self.error = str(e)
        try:
            self._notify_w.send(b"\x01")
        except OSError:
            pass

    def consume(self):
        """read the completion signal byte"""
        try:
            self.notify_r.recv(1)
        except OSError:
            pass

    def close(self):
        """close the signal sockets, ignoring errors"""
        for s in (self.notify_r, self._notify_w):
            try:
                s.close()
            except OSError:
                pass


class _Conn:
    """proxy connection with upstream socket"""

    def __init__(self, client_sock, client_addr):
        """store the client socket and address"""
        self.client = client_sock
        self.client_addr = client_addr
        self.upstream = None
        self.state = STATE_HEAD
        self.head_buf = b""
        self.target = None
        self.pending_upstream_out = b""
        self.buf_c2u = b""
        self.buf_u2c = b""
        self.rx = 0
        self.tx = 0
        self.connect_deadline = None
        self.need_established_reply = False
        self.resolution = None
        self.pending_port = None
        self.check_policy = False
        self.last_activity = 0.0

    def peers(self):
        """return the sockets this connection waits on"""
        s = [self.client]
        if self.upstream is not None:
            s.append(self.upstream)
        if self.resolution is not None:
            s.append(self.resolution.notify_r)
        return s


def _origin_form(method, version, path, headers, host, port):
    """rebuild the request head in origin form with a Host header"""
    lines = ["%s %s %s" % (method, path, version)]
    has_host = any(h.split(":", 1)[0].strip().lower() == "host" for h in headers if h.strip())
    lines.extend(h for h in headers if h.strip())
    if not has_host:
        host_header = host if port == 80 else "%s:%d" % (host, port)
        lines.append("Host: %s" % host_header)
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


class ProxyService(Service):
    name = "proxy"

    def __init__(self, cfg, target_policy=None):
        """bind the listener and store the target policy"""
        self.addr = cfg.veth_addr
        self.port = cfg.proxy_port
        self.upstream_addr = None
        self.no_proxy = []
        self.target_policy = target_policy if target_policy is not None else _policy_from_cfg(cfg)
        self.listener = self._bind()
        self.conns = {}
        self.by_sock = {}

    def _bind(self):
        """create the listening socket on the veth address"""
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((self.addr, self.port))
        s.listen(128)
        s.setblocking(False)
        return s

    def sockets(self):
        """return the listener and every connection's sockets"""
        out = [self.listener]
        for conn in self.conns.values():
            out.extend(conn.peers())
        return out

    def on_host_state(self, state):
        """store the upstream proxy and no-proxy list of the host state"""
        self.upstream_addr = split_proxy_url(state.proxy_url)
        self.no_proxy = list(state.no_proxy)
        log("NB_PROXY_UPSTREAM url=%s source=%s", state.proxy_url or "-", state.proxy_source or "-")

    def next_tick(self, now):
        """return the earliest deadline for tick"""
        if any(c.state == STATE_CONNECTING for c in self.conns.values()):
            return now
        if any(c.state == STATE_RELAY and (c.buf_c2u or c.buf_u2c)
               for c in self.conns.values()):
            return now
        deadlines = [c.connect_deadline for c in self.conns.values()
                     if c.connect_deadline is not None]
        deadlines += [c.last_activity + IDLE_TIMEOUT for c in self.conns.values()
                      if c.state == STATE_RELAY]
        return min(deadlines) if deadlines else None

    def tick(self, now):
        """check connection timeouts and pending connects"""
        for conn in list(self.conns.values()):
            if conn.state in (STATE_HEAD, STATE_RESOLVING) and \
                    conn.connect_deadline is not None and now > conn.connect_deadline:
                reason = "resolve_timeout" if conn.state == STATE_RESOLVING else "head_timeout"
                self._fail_conn(conn, reason)
            elif conn.state == STATE_RELAY and now - conn.last_activity > IDLE_TIMEOUT:
                self._close_conn(conn, "idle_timeout")
            elif conn.state == STATE_RELAY and (conn.buf_c2u or conn.buf_u2c):
                self._flush(conn)

        pending = [c for c in self.conns.values() if c.state == STATE_CONNECTING]
        socks = [c.upstream for c in pending if c.upstream is not None]
        if not socks:
            return
        try:
            _, writable, errored = select.select([], socks, socks, 0)
        except (OSError, ValueError) as e:
            log("NB_PROXY_FAIL target=- reason=select_error:%s", e)
            return
        ready = set(writable) | set(errored)
        for conn in pending:
            if conn.upstream in ready:
                self._check_connect(conn)
            elif conn.connect_deadline is not None and now > conn.connect_deadline:
                self._fail_conn(conn, "connect_timeout")

    def on_readable(self, sock):
        """handle a readable socket"""
        if sock is self.listener:
            self._accept()
            return
        conn = self.by_sock.get(sock)
        if conn is None:
            return
        if conn.state == STATE_HEAD:
            self._read_head(conn)
        elif conn.state == STATE_RESOLVING:
            if conn.resolution is not None and sock is conn.resolution.notify_r:
                self._finish_resolve(conn)
            else:
                self._buffer_early_client_data(conn)
        elif conn.state == STATE_CONNECTING:
            if sock is conn.upstream:
                self._check_connect(conn)
            else:
                self._buffer_early_client_data(conn)
        elif conn.state == STATE_RELAY:
            self._relay_from(conn, sock)

    def close(self):
        """tear down every connection and close the listener"""
        for conn in list(self.conns.values()):
            self._teardown(conn)
        try:
            self.listener.close()
        except OSError:
            pass

    def _accept(self):
        """accept pending client connections"""
        for _ in range(16):
            try:
                csock, addr = self.listener.accept()
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    return
                log("NB_PROXY_FAIL target=- reason=accept_error:%s", e)
                return
            if len(self.conns) >= MAX_CONNS:
                log("NB_PROXY_FAIL target=- reason=conn_limit_reached limit=%d", MAX_CONNS)
                try:
                    csock.close()
                except OSError:
                    pass
                continue
            csock.setblocking(False)
            conn = _Conn(csock, addr)
            now = time.monotonic()
            conn.connect_deadline = now + HEAD_TIMEOUT
            conn.last_activity = now
            self.conns[id(conn)] = conn
            self.by_sock[csock] = conn

    def _read_head(self, conn):
        """read the request head from a client"""
        try:
            chunk = conn.client.recv(RECV_CHUNK)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return
            self._fail_conn(conn, "recv_error:%s" % e)
            return
        if not chunk:
            self._fail_conn(conn, "client_closed_before_head")
            return
        conn.rx += len(chunk)
        conn.head_buf += chunk
        if len(conn.head_buf) > HEAD_MAX:
            self._fail_conn(conn, "head_too_large")
            return
        idx = conn.head_buf.find(b"\r\n\r\n")
        if idx < 0:
            return
        self._start_request(conn, conn.head_buf[:idx], conn.head_buf[idx + 4:])

    def _start_request(self, conn, head_bytes, rest_bytes):
        """parse the request head and start the connect"""
        text = head_bytes.decode("latin-1")
        lines = text.split("\r\n")
        parts = lines[0].split(" ")
        if len(parts) != 3:
            self._fail_conn(conn, "bad_request_line")
            return
        method, target, version = parts
        headers = lines[1:]

        if method == "CONNECT":
            host, sep, port_s = target.rpartition(":")
            if not sep or not port_s.isdigit() or not host:
                self._fail_conn(conn, "bad_connect_target")
                return
            origin = (host, int(port_s))
        else:
            if not target.lower().startswith("http://"):
                self._fail_conn(conn, "not_absolute_uri")
                return
            without = target[len("http://"):]
            hostport, _, tail = without.partition("/")
            path = "/" + tail
            if "@" in hostport:
                hostport = hostport.rsplit("@", 1)[1]
            if ":" in hostport:
                h, _, p = hostport.rpartition(":")
                if not p.isdigit() or not h:
                    self._fail_conn(conn, "bad_absolute_uri")
                    return
                origin = (h, int(p))
            else:
                if not hostport:
                    self._fail_conn(conn, "bad_absolute_uri")
                    return
                origin = (hostport, 80)

        conn.target = sanitize_for_log("%s:%d" % origin)
        use_upstream = self.upstream_addr is not None and not self._no_proxy_match(origin[0])
        via = ("%s:%d" % self.upstream_addr) if use_upstream else "direct"
        log("NB_PROXY_REQUEST method=%s target=%s via=%s", method, conn.target, via)

        if use_upstream:
            log("NB_PROXY_CONNECT target=%s via=%s", conn.target, via)
            connect_to = self.upstream_addr
            conn.pending_upstream_out = head_bytes + b"\r\n\r\n" + rest_bytes
            check_policy = False
        else:
            reason = "no_proxy" if self.upstream_addr is not None else "no_upstream"
            log("NB_PROXY_DIRECT target=%s reason=%s", conn.target, reason)
            connect_to = origin
            check_policy = True
            if method == "CONNECT":
                conn.pending_upstream_out = rest_bytes
                conn.need_established_reply = True
            else:
                conn.pending_upstream_out = _origin_form(
                    method, version, path, headers, origin[0], origin[1]) + rest_bytes

        self._begin_target_connect(conn, connect_to, check_policy)

    def _no_proxy_match(self, host):
        """return whether a host matches a no-proxy entry"""
        h = host.lower()
        for pat in self.no_proxy:
            p = pat.strip().lower().lstrip(".")
            if p and (h == p or h.endswith("." + p)):
                return True
        return False

    def _begin_target_connect(self, conn, addr, check_policy):
        """resolve the host and start the connect"""
        host, port = addr
        ip = _literal_ip(host)
        if ip is not None:
            if check_policy and not self.target_policy.is_allowed(ip):
                self._fail_conn(conn, "target_denied")
                return
            self._begin_connect(conn, (ip, port))
            return
        conn.pending_port = port
        conn.check_policy = check_policy
        conn.resolution = _Resolution(host)
        self.by_sock[conn.resolution.notify_r] = conn
        conn.state = STATE_RESOLVING
        conn.connect_deadline = time.monotonic() + RESOLVE_TIMEOUT

    def _finish_resolve(self, conn):
        """read the lookup result and start the upstream connection"""
        res = conn.resolution
        res.consume()
        self.by_sock.pop(res.notify_r, None)
        conn.resolution = None
        if res.ip is None:
            res.close()
            self._fail_conn(conn, "resolve_failed:%s" % (res.error or "unknown"))
            return
        ip = res.ip
        res.close()
        if conn.check_policy and not self.target_policy.is_allowed(ip):
            self._fail_conn(conn, "target_denied")
            return
        self._begin_connect(conn, (ip, conn.pending_port))

    def _begin_connect(self, conn, addr):
        """start a non-blocking connection to the upstream address"""
        try:
            usock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            usock.setblocking(False)
            rc = usock.connect_ex(addr)
        except OSError as e:
            self._fail_conn(conn, "connect_setup_error:%s" % e)
            return
        if rc not in (0, errno.EINPROGRESS):
            usock.close()
            self._fail_conn(conn, "connect_error:%s" % os.strerror(rc))
            return
        conn.upstream = usock
        self.by_sock[usock] = conn
        conn.state = STATE_CONNECTING
        conn.connect_deadline = time.monotonic() + CONNECT_TIMEOUT
        if rc == 0:
            self._check_connect(conn)

    def _check_connect(self, conn):
        """check whether the upstream connect finished"""
        if conn.upstream is None:
            return
        err = conn.upstream.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
        if err != 0:
            self._fail_conn(conn, "connect_failed:%s" % os.strerror(err))
            return
        conn.state = STATE_RELAY
        conn.connect_deadline = None
        conn.last_activity = time.monotonic()
        if conn.need_established_reply:
            conn.buf_u2c += b"HTTP/1.1 200 Connection established\r\n\r\n"
        conn.buf_c2u += conn.pending_upstream_out
        conn.pending_upstream_out = b""
        log("NB_PROXY_ESTABLISHED target=%s", conn.target)
        self._flush(conn)

    def _buffer_early_client_data(self, conn):
        """buffer data the client sent before the upstream connected"""
        try:
            chunk = conn.client.recv(RECV_CHUNK)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return
            self._fail_conn(conn, "recv_error:%s" % e)
            return
        if not chunk:
            self._fail_conn(conn, "client_closed_before_established")
            return
        conn.rx += len(chunk)
        conn.pending_upstream_out += chunk
        if len(conn.pending_upstream_out) > RELAY_MAX:
            self._fail_conn(conn, "buffer_exceeded")

    def _relay_from(self, conn, sock):
        """pump data from whichever side is readable"""
        if sock is conn.client:
            self._pump(conn, conn.client, "buf_c2u", is_client_side=True)
        elif conn.upstream is not None and sock is conn.upstream:
            self._pump(conn, conn.upstream, "buf_u2c", is_client_side=False)

    def _pump(self, conn, src, bufattr, is_client_side):
        """read from a side into the buffer for the other"""
        try:
            chunk = src.recv(RECV_CHUNK)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return
            self._close_conn(conn, "recv_error:%s" % e)
            return
        if not chunk:
            self._close_conn(conn)
            return
        conn.last_activity = time.monotonic()
        if is_client_side:
            conn.rx += len(chunk)
        else:
            conn.tx += len(chunk)
        buf = getattr(conn, bufattr) + chunk
        if len(buf) > RELAY_MAX:
            self._close_conn(conn, "buffer_exceeded")
            return
        setattr(conn, bufattr, buf)
        self._flush(conn)

    def _flush(self, conn):
        """send buffered data in both directions"""
        if conn.upstream is not None and conn.buf_c2u:
            conn.buf_c2u = self._send_some(conn, conn.upstream, conn.buf_c2u)
        if conn.buf_u2c and conn.state != STATE_DEAD:
            conn.buf_u2c = self._send_some(conn, conn.client, conn.buf_u2c)

    def _send_some(self, conn, sock, data):
        """send as much data as the socket accepts"""
        try:
            n = sock.send(data)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                return data
            self._close_conn(conn, "send_error:%s" % e)
            return b""
        return data[n:]

    def _peer_str(self, conn):
        """return the client address as text"""
        try:
            return "%s:%d" % conn.client_addr
        except (TypeError, ValueError):
            return "-"

    def _fail_conn(self, conn, reason):
        """log a connection failure and tear the connection down"""
        log("NB_PROXY_FAIL target=%s reason=%s", conn.target or self._peer_str(conn), reason)
        self._teardown(conn)

    def _close_conn(self, conn, reason=None):
        """log the close of a connection and tear it down"""
        if reason:
            log("NB_PROXY_FAIL target=%s reason=%s", conn.target or self._peer_str(conn), reason)
        log("NB_PROXY_CLOSE target=%s rx=%d tx=%d", conn.target or self._peer_str(conn), conn.rx, conn.tx)
        self._teardown(conn)

    def _teardown(self, conn):
        """mark a connection dead and close its sockets"""
        conn.state = STATE_DEAD
        if conn.resolution is not None:
            self.by_sock.pop(conn.resolution.notify_r, None)
            conn.resolution.close()
            conn.resolution = None
        for s in (conn.client, conn.upstream):
            if s is None:
                continue
            self.by_sock.pop(s, None)
            try:
                s.close()
            except OSError:
                pass
        self.conns.pop(id(conn), None)
