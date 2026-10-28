import collections
import os
import secrets
import socket
import struct

from nb_common import Service, log, monotonic, sanitize_for_log

DNS_PORT = 53
FORWARD_TIMEOUT = 2.0
LOCAL_TTL = 60
PORTAL_TTL = 5
PORTAL_POLL_SECONDS = 1.0

MAX_PENDING = 2048
MAX_TCP_CONNS = 64
TCP_IDLE_TIMEOUT = 30.0
FWD_ROTATE_INTERVAL = 30.0

QTYPE_A = 1
QTYPE_AAAA = 28
RCODE_NOERROR = 0
RCODE_SERVFAIL = 2
RCODE_NXDOMAIN = 3

FLAG_QR = 0x8000
FLAG_AA = 0x0400
FLAG_RA = 0x0080

QTYPE_NAMES = {1: "A", 2: "NS", 5: "CNAME", 6: "SOA", 12: "PTR", 15: "MX",
               16: "TXT", 28: "AAAA", 33: "SRV", 255: "ANY"}


def qtype_name(qtype):
    """return the name of a query type, or its number"""
    return QTYPE_NAMES.get(qtype, str(qtype))


def fmt_src(addr):
    """format an address and port as text"""
    return "%s:%s" % (addr[0], addr[1])


def parse_header(msg):
    """unpack the 12-byte DNS header"""
    if len(msg) < 12:
        return None
    return struct.unpack(">HHHHHH", msg[:12])


def parse_name(msg, offset, max_jumps=32):
    """parse a DNS name from a message"""
    labels = []
    pos = offset
    end = None
    jumps = 0
    while True:
        if pos >= len(msg):
            return None, offset
        length = msg[pos]
        if length == 0:
            if end is None:
                end = pos + 1
            return ".".join(labels), end
        if length & 0xC0 == 0xC0:
            if pos + 1 >= len(msg):
                return None, offset
            jumps += 1
            if jumps > max_jumps:
                return None, offset
            if end is None:
                end = pos + 2
            pos = ((length & 0x3F) << 8) | msg[pos + 1]
            continue
        if length & 0xC0:
            return None, offset
        pos += 1
        if pos + length > len(msg):
            return None, offset
        labels.append(msg[pos:pos + length].decode("ascii", "replace"))
        pos += length


def parse_question(msg, offset):
    """parse a question at an offset"""
    name, pos = parse_name(msg, offset)
    if name is None or pos + 4 > len(msg):
        return None
    qtype, qclass = struct.unpack(">HH", msg[pos:pos + 4])
    return name, qtype, qclass, pos + 4


def parse_query(msg):
    """parse a query message"""
    hdr = parse_header(msg)
    if hdr is None:
        return None
    txid, _flags, qd, _an, _ns, _ar = hdr
    if qd < 1:
        return None
    q = parse_question(msg, 12)
    if q is None:
        return None
    qname, qtype, qclass, _pos = q
    return txid, qname, qtype, qclass


def parse_a_record(msg, offset):
    """parse an A record at an offset"""
    name, pos = parse_name(msg, offset)
    if name is None or pos + 10 > len(msg):
        return None
    rtype, rclass, ttl, rdlen = struct.unpack(">HHIH", msg[pos:pos + 10])
    pos += 10
    if rtype != QTYPE_A or rdlen != 4 or pos + 4 > len(msg):
        return None
    return name, socket.inet_ntoa(msg[pos:pos + 4]), ttl, pos + 4


def encode_name(name):
    """encode a name as DNS labels"""
    name = name.strip(".")
    if not name:
        return b"\x00"
    out = bytearray()
    for label in name.split("."):
        raw = label.encode("ascii")
        if not raw or len(raw) > 63:
            raise ValueError("bad label %r in name %r" % (label, name))
        out.append(len(raw))
        out += raw
    out.append(0)
    return bytes(out)


def set_txid(msg, txid):
    """replace the transaction id of a message"""
    return struct.pack(">H", txid) + msg[2:]


def build_response(txid, qname, qtype, qclass, rcode, aa, answer_ip=None, ttl=60):
    """build a DNS response message"""
    flags = FLAG_QR | FLAG_RA | (FLAG_AA if aa else 0) | (rcode & 0xF)
    question = encode_name(qname) + struct.pack(">HH", qtype, qclass)
    ancount = 1 if answer_ip else 0
    msg = struct.pack(">HHHHHH", txid, flags, 1, ancount, 0, 0) + question
    if answer_ip:
        if ":" in answer_ip:
            rdata = socket.inet_pton(socket.AF_INET6, answer_ip)
            rtype = QTYPE_AAAA
        else:
            rdata = socket.inet_aton(answer_ip)
            rtype = QTYPE_A
        msg += b"\xc0\x0c" + struct.pack(">HHIH", rtype, qclass, ttl, len(rdata)) + rdata
    return msg


def classify_query(qname, qtype, local_map, portal_ip, local_map6=None):
    """return the action and address for a query"""
    key = qname.rstrip(".").lower()
    if portal_ip is not None:
        return ("portal", portal_ip) if qtype == QTYPE_A else ("portal-nxdomain", None)
    local_ip = local_map.get(key)
    local_ip6 = (local_map6 or {}).get(key)
    if qtype == QTYPE_AAAA and local_ip6 is not None:
        return ("local", local_ip6)
    if local_ip is not None:
        return ("local", local_ip) if qtype == QTYPE_A else ("local-empty", None)
    if local_ip6 is not None:
        return ("local-empty", None)
    return ("forward", None)


Pending = collections.namedtuple(
    "Pending", "client_txid qname qtype qclass proto addr conn body "
               "resolvers resolver_index deadline start")


class PendingTable:
    """table of pending upstream queries"""

    def __init__(self):
        """start with no pending queries"""
        self._entries = {}

    def __len__(self):
        """return the number of pending queries"""
        return len(self._entries)

    def alloc(self, upstream):
        """return an unused transaction id for an upstream"""
        for _ in range(0x10000):
            candidate = secrets.randbelow(0x10000)
            if (upstream, candidate) not in self._entries:
                return candidate
        return None

    def add(self, upstream, txid, pending):
        """record a pending query under its upstream and transaction id"""
        self._entries[(upstream, txid)] = pending

    def pop(self, upstream, txid):
        """remove and return the pending query"""
        return self._entries.pop((upstream, txid), None)

    def pop_expired(self, now):
        """remove and return the pending queries past their deadline"""
        expired = [(k, p) for k, p in self._entries.items() if p.deadline <= now]
        for k, _p in expired:
            del self._entries[k]
        return expired

    def next_deadline(self):
        """return the earliest deadline"""
        if not self._entries:
            return None
        return min(p.deadline for p in self._entries.values())


def _parse_local_a(entries, family=socket.AF_INET):
    """parse NAME=ADDRESS entries for a family"""
    out = {}
    for raw in entries:
        if "=" not in raw:
            log("NB_DNS_CONFIG_BAD entry=%s reason=missing-equals", raw)
            continue
        name, ip = raw.split("=", 1)
        name = name.strip().rstrip(".").lower()
        ip = ip.strip()
        if not name:
            log("NB_DNS_CONFIG_BAD entry=%s reason=empty-name", raw)
            continue
        try:
            socket.inet_pton(family, ip)
        except OSError:
            log("NB_DNS_CONFIG_BAD entry=%s reason=bad-ip family=%s", raw,
                "inet6" if family == socket.AF_INET6 else "inet")
            continue
        out[name] = ip
    return out


class _TcpConn:
    def __init__(self, sock, addr):
        """store the client socket and address"""
        self.sock = sock
        self.addr = addr
        self.buf = bytearray()
        self.closed = False
        self.last_activity = monotonic()


def prune_idle_tcp(conns, now, idle_timeout=TCP_IDLE_TIMEOUT):
    """return the keys of idle TCP connections"""
    return [k for k, c in conns.items() if now - c.last_activity > idle_timeout]


def validate_forward_reply(data, addr, pending):
    """check an upstream reply against its query"""
    if addr[1] != DNS_PORT:
        return "bad-source-port"
    if len(data) < 12:
        return "short-reply"
    q = parse_question(data, 12)
    if q is None:
        return "unparseable-question"
    qname, qtype, qclass, _pos = q
    if (qname.rstrip(".").lower() != pending.qname.rstrip(".").lower()
            or qtype != pending.qtype or qclass != pending.qclass):
        return "question-mismatch"
    return None


def _upstream_addr(upstream, port):
    """return the family and address of a resolver"""
    if ":" not in upstream:
        return socket.AF_INET, (upstream, port)
    host, _, scope = upstream.partition("%")
    scope_id = 0
    if scope:
        scope_id = int(scope) if scope.isdigit() else socket.if_nametoindex(scope)
    return socket.AF_INET6, (host, port, 0, scope_id)


class _ForwardSocket:
    """UDP sockets to upstream resolvers"""

    def __init__(self, rotate_interval=FWD_ROTATE_INTERVAL):
        """open the UDP socket for queries"""
        self.rotate_interval = rotate_interval
        self.sock = self._new_socket(socket.AF_INET)
        self.sock6 = None
        self._rotate_at = monotonic() + rotate_interval

    @staticmethod
    def _new_socket(family):
        """open a non-blocking UDP socket bound to any port"""
        s = socket.socket(family, socket.SOCK_DGRAM)
        s.bind(("::" if family == socket.AF_INET6 else "0.0.0.0", 0))
        s.setblocking(False)
        return s

    def socks(self):
        """return the forwarding sockets in use"""
        return [self.sock] if self.sock6 is None else [self.sock, self.sock6]

    def sock_for(self, family):
        """return the forwarding socket for an address family"""
        if family == socket.AF_INET:
            return self.sock
        if self.sock6 is None:
            self.sock6 = self._new_socket(family)
        return self.sock6

    def maybe_rotate(self, now, pending_count):
        """replace the forwarding sockets when due"""
        if now < self._rotate_at or pending_count:
            return False
        old = self.socks()
        self.sock = self._new_socket(socket.AF_INET)
        if self.sock6 is not None:
            self.sock6 = self._new_socket(socket.AF_INET6)
        self._rotate_at = now + self.rotate_interval
        for s in old:
            try:
                s.close()
            except OSError:
                pass
        log("NB_DNS_FWD_ROTATED")
        return True

    def close(self):
        """close the forwarding sockets, ignoring errors"""
        for s in self.socks():
            try:
                s.close()
            except OSError:
                pass


class DnsService(Service):
    """UDP and TCP DNS forwarder"""
    name = "dns"

    def __init__(self, cfg):
        """bind the DNS sockets on the veth address"""
        self._local_a = _parse_local_a(getattr(cfg, "local_a", []))
        self._local_aaaa = _parse_local_a(getattr(cfg, "local_aaaa", []),
                                          socket.AF_INET6)
        self._resolvers = []
        self._portal_path = os.path.join(cfg.state_dir, "portal")
        self._portal_key = None
        self._portal_ip = None
        self._pending = PendingTable()
        self._tcp_conns = {}
        self._next_portal_check = 0.0

        self._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._udp.bind((cfg.veth_addr, DNS_PORT))
        self._udp.setblocking(False)

        self._tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._tcp.bind((cfg.veth_addr, DNS_PORT))
        self._tcp.listen(16)
        self._tcp.setblocking(False)

        self._fwd = _ForwardSocket()

        self._refresh_portal()

    def sockets(self):
        """return the DNS sockets"""
        return ([self._udp, self._tcp] + self._fwd.socks()
                + [c.sock for c in self._tcp_conns.values()])

    def on_host_state(self, state):
        """store the resolver list of the host state"""
        self._resolvers = list(state.resolvers)
        log("NB_DNS_UPSTREAMS list=%s", ",".join(self._resolvers) or "-")

    def next_tick(self, now):
        """return the time of the next deadline"""
        deadline = self._pending.next_deadline()
        times = [self._next_portal_check]
        if deadline is not None:
            times.append(deadline)
        if self._tcp_conns:
            times.append(min(c.last_activity for c in self._tcp_conns.values())
                         + TCP_IDLE_TIMEOUT)
        if not self._pending:
            times.append(self._fwd._rotate_at)
        return min(times)

    def tick(self, now):
        """run the periodic DNS work"""
        if now >= self._next_portal_check:
            self._refresh_portal()
            self._next_portal_check = now + PORTAL_POLL_SECONDS
        for key, pending in self._pending.pop_expired(now):
            log("NB_DNS_TIMEOUT qname=%s upstream=%s", sanitize_for_log(pending.qname), key[0])
            self._dispatch(pending, pending.resolver_index + 1)
        self._fwd.maybe_rotate(now, len(self._pending))
        for fd in prune_idle_tcp(self._tcp_conns, now):
            conn = self._tcp_conns.get(fd)
            if conn is not None:
                log("NB_DNS_TCP_IDLE_CLOSE src=%s", fmt_src(conn.addr))
                self._close_tcp(conn)

    def on_readable(self, sock):
        """handle a readable socket by its kind"""
        if sock is self._udp:
            self._on_udp_readable()
            return
        if sock is self._tcp:
            self._on_tcp_accept()
            return
        if sock in self._fwd.socks():
            self._on_fwd_readable(sock)
            return
        conn = self._tcp_conns.get(sock.fileno())
        if conn is not None:
            self._on_tcp_client_readable(conn)

    def _on_udp_readable(self):
        """read a UDP query and handle it"""
        try:
            data, addr = self._udp.recvfrom(4096)
        except OSError as e:
            log("NB_DNS_MALFORMED reason=udp-recv-error error=%s", e)
            return
        self._handle_query(data, "udp", addr, None)

    def _on_tcp_accept(self):
        """accept a TCP client unless too many are open"""
        try:
            conn, addr = self._tcp.accept()
        except OSError as e:
            log("NB_DNS_MALFORMED reason=tcp-accept-error error=%s", e)
            return
        if len(self._tcp_conns) >= MAX_TCP_CONNS:
            log("NB_DNS_MALFORMED reason=tcp-conn-limit-reached limit=%d", MAX_TCP_CONNS)
            try:
                conn.close()
            except OSError:
                pass
            return
        conn.setblocking(False)
        self._tcp_conns[conn.fileno()] = _TcpConn(conn, addr)

    def _on_tcp_client_readable(self, conn):
        """read queries from a TCP client"""
        try:
            chunk = conn.sock.recv(4096)
        except OSError as e:
            log("NB_DNS_MALFORMED reason=tcp-recv-error error=%s", e)
            self._close_tcp(conn)
            return
        if not chunk:
            self._close_tcp(conn)
            return
        conn.last_activity = monotonic()
        conn.buf += chunk
        while len(conn.buf) >= 2:
            (length,) = struct.unpack(">H", conn.buf[:2])
            if len(conn.buf) < 2 + length:
                return
            msg = bytes(conn.buf[2:2 + length])
            del conn.buf[:2 + length]
            self._handle_query(msg, "tcp", conn.addr, conn)

    def _on_fwd_readable(self, sock):
        """read an upstream reply and answer the waiting client"""
        try:
            data, addr = sock.recvfrom(4096)
        except OSError as e:
            log("NB_DNS_MALFORMED reason=forward-recv-error error=%s", e)
            return
        if len(data) < 4:
            log("NB_DNS_MALFORMED reason=short-upstream-reply upstream=%s", addr[0])
            return
        our_txid = struct.unpack(">H", data[:2])[0]
        pending = self._pending.pop(addr[0].partition("%")[0], our_txid)
        if pending is None:
            log("NB_DNS_MALFORMED reason=unmatched-reply upstream=%s", addr[0])
            return
        reason = validate_forward_reply(data, addr, pending)
        if reason is not None:
            log("NB_DNS_MALFORMED reason=%s upstream=%s qname=%s",
                reason, addr[0], sanitize_for_log(pending.qname))
            return
        rcode = struct.unpack(">H", data[2:4])[0] & 0xF
        ms = (monotonic() - pending.start) * 1000.0
        log("NB_DNS_FORWARD qname=%s upstream=%s rcode=%s ms=%.1f",
            sanitize_for_log(pending.qname), addr[0], rcode, ms)
        self._reply(pending.proto, pending.addr, pending.conn, set_txid(data, pending.client_txid))

    def _handle_query(self, data, proto, addr, conn):
        """answer a query locally or forward it upstream"""
        parsed = parse_query(data)
        if parsed is None:
            log("NB_DNS_MALFORMED reason=parse-failed proto=%s", proto)
            return
        txid, qname, qtype, qclass = parsed
        log_qname = sanitize_for_log(qname)
        log("NB_DNS_QUERY qname=%s qtype=%s src=%s proto=%s",
            log_qname, qtype_name(qtype), fmt_src(addr), proto)

        action, ip = classify_query(qname, qtype, self._local_a, self._portal_ip,
                                    self._local_aaaa)
        if action == "local":
            log("NB_DNS_LOCAL qname=%s ip=%s", log_qname, ip)
            self._reply(proto, addr, conn,
                        build_response(txid, qname, qtype, qclass, RCODE_NOERROR, True, ip, LOCAL_TTL))
            return
        if action == "portal":
            log("NB_DNS_PORTAL qname=%s ip=%s", log_qname, ip)
            self._reply(proto, addr, conn,
                        build_response(txid, qname, qtype, qclass, RCODE_NOERROR, True, ip, PORTAL_TTL))
            return
        if action == "local-empty":
            self._reply(proto, addr, conn, build_response(txid, qname, qtype, qclass, RCODE_NOERROR, True))
            return
        if action == "portal-nxdomain":
            log("NB_DNS_PORTAL qname=%s nxdomain", log_qname)
            self._reply(proto, addr, conn, build_response(txid, qname, qtype, qclass, RCODE_NXDOMAIN, True))
            return

        if not self._resolvers:
            log("NB_DNS_SERVFAIL qname=%s reason=no-upstreams", log_qname)
            self._reply(proto, addr, conn, build_response(txid, qname, qtype, qclass, RCODE_SERVFAIL, False))
            return
        if len(self._pending) >= MAX_PENDING:
            log("NB_DNS_SERVFAIL qname=%s reason=pending-table-full", log_qname)
            self._reply(proto, addr, conn, build_response(txid, qname, qtype, qclass, RCODE_SERVFAIL, False))
            return
        pending = Pending(client_txid=txid, qname=qname, qtype=qtype, qclass=qclass,
                           proto=proto, addr=addr, conn=conn, body=data[2:],
                           resolvers=tuple(self._resolvers), resolver_index=0,
                           deadline=0.0, start=monotonic())
        self._dispatch(pending, 0)

    def _dispatch(self, pending, resolver_index):
        """send a query to an upstream resolver"""
        log_qname = sanitize_for_log(pending.qname)
        if resolver_index >= len(pending.resolvers):
            log("NB_DNS_SERVFAIL qname=%s reason=upstream-timeout", log_qname)
            reply = build_response(pending.client_txid, pending.qname, pending.qtype,
                                    pending.qclass, RCODE_SERVFAIL, False)
            self._reply(pending.proto, pending.addr, pending.conn, reply)
            return
        upstream = pending.resolvers[resolver_index]
        upstream_key = upstream.partition("%")[0]
        our_txid = self._pending.alloc(upstream_key)
        if our_txid is None:
            log("NB_DNS_SERVFAIL qname=%s reason=id-space-exhausted upstream=%s", log_qname, upstream)
            reply = build_response(pending.client_txid, pending.qname, pending.qtype,
                                    pending.qclass, RCODE_SERVFAIL, False)
            self._reply(pending.proto, pending.addr, pending.conn, reply)
            return
        next_pending = pending._replace(resolver_index=resolver_index,
                                         deadline=monotonic() + FORWARD_TIMEOUT)
        try:
            family, dest = _upstream_addr(upstream, DNS_PORT)
            self._fwd.sock_for(family).sendto(struct.pack(">H", our_txid) + next_pending.body, dest)
        except OSError:
            log("NB_DNS_TIMEOUT qname=%s upstream=%s", log_qname, upstream)
            self._dispatch(next_pending, resolver_index + 1)
            return
        self._pending.add(upstream_key, our_txid, next_pending)

    def _reply(self, proto, addr, conn, payload):
        """send a reply over UDP or TCP"""
        if proto == "udp":
            try:
                self._udp.sendto(payload, addr)
            except OSError as e:
                log("NB_DNS_MALFORMED reason=udp-send-error error=%s", e)
            return
        if conn is None or conn.closed:
            log("NB_DNS_MALFORMED reason=tcp-client-gone")
            return
        try:
            conn.sock.sendall(struct.pack(">H", len(payload)) + payload)
        except OSError as e:
            log("NB_DNS_MALFORMED reason=tcp-send-error error=%s", e)
            self._close_tcp(conn)

    def _close_tcp(self, conn):
        """close a TCP client connection and forget it"""
        if conn.closed:
            return
        conn.closed = True
        self._tcp_conns.pop(conn.sock.fileno(), None)
        try:
            conn.sock.close()
        except OSError:
            pass

    def _refresh_portal(self):
        """reload the portal address when its file changed"""
        try:
            st = os.stat(self._portal_path)
        except OSError:
            self._portal_key = None
            self._portal_ip = None
            return
        key = (st.st_ino, st.st_size, st.st_mtime_ns)
        if key == self._portal_key:
            return
        self._portal_key = key
        try:
            with open(self._portal_path) as f:
                text = f.read().strip()
        except OSError as e:
            log("NB_DNS_CONFIG_BAD entry=%s reason=portal-read-error", e)
            self._portal_ip = None
            return
        try:
            socket.inet_aton(text)
        except OSError:
            log("NB_DNS_CONFIG_BAD entry=%s reason=bad-portal-ip", text)
            self._portal_ip = None
            return
        self._portal_ip = text
