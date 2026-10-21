#!/usr/bin/env python3
import errno
import ipaddress
import os
import select
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nb_proxy  # noqa: E402

FAILURES = []
CAPTURED_LOG = []


def fail(msg):
    """record a failure message"""
    FAILURES.append(msg)


def _capture_log(fmt, *args):
    """record a log line"""
    CAPTURED_LOG.append(fmt % args if args else fmt)


nb_proxy.log = _capture_log


class _Cfg:
    def __init__(self, veth_addr, proxy_port):
        """store the veth address and proxy port"""
        self.veth_addr = veth_addr
        self.proxy_port = proxy_port


class _State:
    def __init__(self, proxy_url=None, no_proxy=None):
        """store the proxy URL and no-proxy list"""
        self.proxy_url = proxy_url
        self.proxy_source = "selftest"
        self.no_proxy = no_proxy or []


class EchoServer:
    """loopback echo socket for tests"""

    def __init__(self):
        """serve an echo connection from a thread"""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.received = b""
        self._lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        """echo a connection"""
        try:
            conn, _ = self.sock.accept()
        except OSError:
            return
        conn.settimeout(5)
        try:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                with self._lock:
                    self.received += chunk
                conn.sendall(b"ECHO:" + chunk)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def snapshot(self):
        """return the bytes received so far"""
        with self._lock:
            return self.received

    def close(self):
        """close the listening socket, ignoring errors"""
        try:
            self.sock.close()
        except OSError:
            pass
        self.thread.join(timeout=2)


class FakeUpstreamProxy:
    """fake upstream proxy for relay tests"""

    def __init__(self):
        """serve a proxy connection from a thread"""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.received = b""
        self._lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        """answer a proxy request and echo"""
        try:
            conn, _ = self.sock.accept()
        except OSError:
            return
        conn.settimeout(5)
        try:
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                buf += chunk
            with self._lock:
                self.received += buf
            conn.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                with self._lock:
                    self.received += chunk
                conn.sendall(b"ECHO:" + chunk)
        except OSError:
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def snapshot(self):
        """return the bytes received so far"""
        with self._lock:
            return self.received

    def close(self):
        """close the listening socket, ignoring errors"""
        try:
            self.sock.close()
        except OSError:
            pass
        self.thread.join(timeout=2)


class ClientReader:
    """receive buffer for a socket"""

    def __init__(self, sock):
        """store the socket and an empty buffer"""
        self.sock = sock
        self.buf = b""

    def pull(self):
        """read all bytes currently available from the socket"""
        while True:
            r, _, _ = select.select([self.sock], [], [], 0)
            if not r:
                break
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            self.buf += chunk
        return self.buf


def _make_service(proxy_url=None, no_proxy=None, target_policy=None):
    """create a proxy service with a local listener"""
    if target_policy is not None:
        svc = nb_proxy.ProxyService(_Cfg("127.0.0.1", 0), target_policy=target_policy)
    else:
        svc = nb_proxy.ProxyService(_Cfg("127.0.0.1", 0))
    svc.on_host_state(_State(proxy_url, no_proxy))
    return svc


def _permissive_policy():
    """return a TargetPolicy with empty deny list"""
    if not hasattr(nb_proxy, "TargetPolicy"):
        return None
    return nb_proxy.TargetPolicy(deny=[], allow=[])


def _connect_client(svc):
    """connect a client to the proxy listener"""
    port = svc.listener.getsockname()[1]
    client = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    client.settimeout(5)
    client.connect(("127.0.0.1", port))
    return client


def _client_is_closed(sock):
    """return whether the peer closed the socket"""
    r, _, _ = select.select([sock], [], [], 0)
    if not r:
        return False
    try:
        chunk = sock.recv(1)
    except OSError:
        return True
    return chunk == b""


def pump_until(svc, predicate, timeout_s=3.0):
    """run the service until a condition holds"""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        socks = svc.sockets()
        try:
            r, _, _ = select.select(socks, [], [], 0.02)
        except (OSError, ValueError):
            r = []
        for s in r:
            try:
                svc.on_readable(s)
            except OSError:
                pass
        now = time.monotonic()
        nt = svc.next_tick(now)
        if nt is not None and nt <= now:
            svc.tick(now)
    return predicate()


def _check_connect_via_upstream(corrupt):
    """check a CONNECT request through an upstream proxy"""
    upstream = FakeUpstreamProxy()
    svc = _make_service(proxy_url="http://127.0.0.1:%d" % upstream.port)
    client = _connect_client(svc)
    reader = ClientReader(client)
    try:
        client.sendall(b"CONNECT secure.example:443 HTTP/1.1\r\nHost: secure.example:443\r\n\r\n")
        if not pump_until(svc, lambda: b"\r\n\r\n" in upstream.snapshot()):
            fail("connect-via-upstream: upstream never received the CONNECT head")
            return
        got = upstream.snapshot()
        want = b"CONNECT deliberately-wrong-target HTTP/1.1" if corrupt \
            else b"CONNECT secure.example:443 HTTP/1.1"
        if not got.startswith(want):
            fail("connect-via-upstream: upstream head was %r, expected it to start with %r"
                 % (got[:60], want))
            return
        client.sendall(b"PING")
        if not pump_until(svc, lambda: b"ECHO:PING" in reader.pull()):
            fail("connect-via-upstream: the tunnel did not relay a PING/ECHO round trip")
    finally:
        client.close()
        svc.close()
        upstream.close()


def _check_connect_direct():
    """check a direct CONNECT request"""
    origin = EchoServer()
    svc = _make_service(proxy_url=None, target_policy=_permissive_policy())
    client = _connect_client(svc)
    reader = ClientReader(client)
    try:
        client.sendall(b"CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % origin.port)
        if not pump_until(svc, lambda: b"200 Connection established" in reader.pull()):
            fail("connect-direct: proxy never answered 200 Connection established itself")
            return
        client.sendall(b"PING")
        if not pump_until(svc, lambda: b"ECHO:PING" in reader.pull()):
            fail("connect-direct: the tunnel did not relay PING/ECHO to the origin and back")
    finally:
        client.close()
        svc.close()
        origin.close()


def _check_absolute_uri_direct():
    """check a direct request with an absolute URI"""
    origin = EchoServer()
    svc = _make_service(proxy_url=None, target_policy=_permissive_policy())
    client = _connect_client(svc)
    try:
        target = "http://127.0.0.1:%d/some/path?x=1" % origin.port
        client.sendall(("GET %s HTTP/1.1\r\n\r\n" % target).encode())
        if not pump_until(svc, lambda: bool(origin.snapshot())):
            fail("absolute-uri-direct: origin never received a rewritten request")
            return
        got = origin.snapshot()
        want_line = b"GET /some/path?x=1 HTTP/1.1\r\n"
        if not got.startswith(want_line):
            fail("absolute-uri-direct: request line was %r, wanted %r"
                 % (got.split(b"\r\n", 1)[0], want_line))
            return
        want_host = ("Host: 127.0.0.1:%d" % origin.port).encode()
        if want_host not in got:
            fail("absolute-uri-direct: no rewritten Host header found; got %r" % got[:200])
    finally:
        client.close()
        svc.close()
        origin.close()


def _check_no_proxy_match():
    """check that no-proxy hosts connect directly"""
    upstream = FakeUpstreamProxy()
    origin = EchoServer()
    svc = _make_service(proxy_url="http://127.0.0.1:%d" % upstream.port, no_proxy=["127.0.0.1"],
                        target_policy=_permissive_policy())
    client = _connect_client(svc)
    reader = ClientReader(client)
    try:
        client.sendall(b"CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % origin.port)
        if not pump_until(svc, lambda: b"200 Connection established" in reader.pull()):
            fail("no-proxy-match: proxy did not answer 200 directly for a no_proxy host")
            return
        client.sendall(b"PING")
        if not pump_until(svc, lambda: b"ECHO:PING" in reader.pull()):
            fail("no-proxy-match: the direct tunnel never relayed PING/ECHO")
        if upstream.snapshot():
            fail("no-proxy-match: the configured upstream saw traffic for a no_proxy host: %r"
                 % upstream.snapshot()[:80])
    finally:
        client.close()
        svc.close()
        origin.close()
        upstream.close()


def _check_bad_request_refused():
    """check that a bad request is refused"""
    svc = _make_service(proxy_url=None)
    client = _connect_client(svc)
    CAPTURED_LOG.clear()
    try:
        client.sendall(b"not a proxy request at all\r\n\r\n")
        if not pump_until(svc, lambda: _client_is_closed(client)):
            fail("bad-request: the proxy left the socket open instead of refusing it")
            return
        if not any("NB_PROXY_FAIL" in ln and "reason=" in ln for ln in CAPTURED_LOG):
            fail("bad-request: no NB_PROXY_FAIL reason= was logged for the bad request line")
    finally:
        client.close()
        svc.close()


def _check_target_policy_default_denies_loopback():
    """test the default target policy for loopback"""
    svc = nb_proxy.ProxyService(_Cfg("127.0.0.1", 0))
    svc.on_host_state(_State(None))
    client = _connect_client(svc)
    CAPTURED_LOG.clear()
    try:
        client.sendall(b"CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n")
        if not pump_until(svc, lambda: _client_is_closed(client)):
            fail("target-policy-default: an unconfigured proxy let a CONNECT "
                 "to 127.0.0.1 through instead of refusing it by default")
            return
        if not any("target_denied" in ln for ln in CAPTURED_LOG):
            fail("target-policy-default: no target_denied reason was logged "
                 "for the default-denied loopback target")
    finally:
        client.close()
        svc.close()


def _check_target_policy_denies_link_local_and_multicast():
    """check that link-local and multicast targets are denied"""
    svc = nb_proxy.ProxyService(_Cfg("127.0.0.1", 0))
    svc.on_host_state(_State(None))
    try:
        for target in (b"169.254.1.5:80", b"224.0.0.251:80"):
            client = _connect_client(svc)
            CAPTURED_LOG.clear()
            try:
                client.sendall(b"CONNECT " + target + b" HTTP/1.1\r\n\r\n")
                if not pump_until(svc, lambda: _client_is_closed(client)):
                    fail("target-policy-default: %r was not refused" % target)
                    continue
                if not any("target_denied" in ln for ln in CAPTURED_LOG):
                    fail("target-policy-default: no target_denied logged for %r" % target)
            finally:
                client.close()
    finally:
        svc.close()


def _check_target_policy_allow_override():
    """test TargetPolicy with an allow entry"""
    if not hasattr(nb_proxy, "TargetPolicy"):
        fail("target-policy-allow: no TargetPolicy in nb_proxy yet")
        return
    origin = EchoServer()
    policy = nb_proxy.TargetPolicy(allow=["127.0.0.1/32"])
    svc = nb_proxy.ProxyService(_Cfg("127.0.0.1", 0), target_policy=policy)
    svc.on_host_state(_State(None))
    client = _connect_client(svc)
    reader = ClientReader(client)
    try:
        client.sendall(b"CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % origin.port)
        if not pump_until(svc, lambda: b"200 Connection established" in reader.pull()):
            fail("target-policy-allow: an explicit allow override still refused an in-scope target")
            return
        client.sendall(b"PING")
        if not pump_until(svc, lambda: b"ECHO:PING" in reader.pull()):
            fail("target-policy-allow: an allowed loopback target did not relay")
    finally:
        client.close()
        svc.close()
        origin.close()


def _check_target_policy_bad_entries_stay_denied():
    """test unparseable policy entries"""
    if not hasattr(nb_proxy, "TargetPolicy"):
        fail("target-policy-bad-entry: no TargetPolicy in nb_proxy yet")
        return
    policy = nb_proxy.TargetPolicy(allow=["not-a-cidr-at-all"])
    if policy.is_allowed("127.0.0.1"):
        fail("target-policy-bad-entry: an unparseable allow entry made a "
             "denied address (127.0.0.1) allowed")
    policy2 = nb_proxy.TargetPolicy(deny=["also-not-a-cidr"])
    if not policy2.is_allowed("8.8.8.8"):
        fail("target-policy-bad-entry: a broken deny list denied an "
             "unrelated public address instead of being ignored")


def _check_connect_policy_vocabulary():
    """check the connect policy mode values"""
    if not hasattr(nb_proxy, "target_policy_for_mode"):
        fail("connect-policy: no target_policy_for_mode()")
        return
    deny_local = nb_proxy.target_policy_for_mode("deny-local")
    if deny_local.is_allowed("127.0.0.1"):
        fail("connect-policy: mode='deny-local' allowed a loopback target")
    any_mode = nb_proxy.target_policy_for_mode("any")
    if not any_mode.is_allowed("127.0.0.1"):
        fail("connect-policy: mode='any' still refused a loopback target")
    for bad_mode in (None, "", "Any", "DENY-LOCAL", "open", "  any  "):
        policy = nb_proxy.target_policy_for_mode(bad_mode)
        if policy.is_allowed("127.0.0.1"):
            fail(f"connect-policy: mode={bad_mode!r} allowed a loopback target; "
                 f"expected deny-local")

    class _BareCfg:
        veth_addr = "127.0.0.1"
        proxy_port = 0
    svc = nb_proxy.ProxyService(_BareCfg())
    try:
        if svc.target_policy.is_allowed("127.0.0.1"):
            fail("connect-policy: a cfg with no proxy_connect_policy field "
                 "at all defaulted to allowing a loopback target")
    finally:
        svc.close()


def _check_hostname_resolution_offloaded():
    """test CONNECT with a hostname target"""
    if not hasattr(nb_proxy, "STATE_RESOLVING"):
        fail("hostname-resolution: no STATE_RESOLVING state")
        return

    calls = []
    real_connect_ex = socket.socket.connect_ex

    def spy_connect_ex(self, addr):
        """record the connect address"""
        calls.append(addr)
        return errno.EINPROGRESS

    permissive = _permissive_policy()
    svc = nb_proxy.ProxyService(_Cfg("127.0.0.1", 0), target_policy=permissive)
    svc.on_host_state(_State(None))
    client = _connect_client(svc)
    socket.socket.connect_ex = spy_connect_ex
    try:
        client.sendall(b"CONNECT localhost:443 HTTP/1.1\r\n\r\n")
        pump_until(svc, lambda: bool(calls) or _client_is_closed(client), timeout_s=3.0)
    finally:
        socket.socket.connect_ex = real_connect_ex
        client.close()
        svc.close()

    if not calls:
        fail("hostname-resolution: connect_ex() was never invoked for a "
             "resolvable hostname target")
        return
    seen_host = calls[0][0]
    try:
        ipaddress.ip_address(seen_host)
    except ValueError:
        fail("hostname-resolution: connect_ex() received the raw hostname "
             "%r" % (seen_host,))
        return

    hold = threading.Event()
    real_getaddrinfo = nb_proxy.socket.getaddrinfo

    def slow_getaddrinfo(host, *a, **kw):
        """resolve a name after waiting for a release event"""
        hold.wait(2.0)
        return real_getaddrinfo(host, *a, **kw)

    svc2 = nb_proxy.ProxyService(_Cfg("127.0.0.1", 0), target_policy=permissive)
    svc2.on_host_state(_State(None))
    client2 = _connect_client(svc2)
    nb_proxy.socket.getaddrinfo = slow_getaddrinfo
    t0 = time.monotonic()
    try:
        client2.sendall(b"CONNECT localhost:443 HTTP/1.1\r\n\r\n")
        pump_until(svc2, lambda: False, timeout_s=0.2)
        elapsed = time.monotonic() - t0
        if elapsed > 1.0:
            fail("hostname-resolution: dispatching a hostname CONNECT took "
                 "%.2fs with the resolver held open" % elapsed)
    finally:
        hold.set()
        nb_proxy.socket.getaddrinfo = real_getaddrinfo
        client2.close()
        svc2.close()


def _check_head_timeout():
    """check the request head timeout"""
    if not hasattr(nb_proxy, "HEAD_TIMEOUT"):
        fail("resource-bounds: no HEAD_TIMEOUT")
        return
    svc = _make_service(proxy_url=None)
    client = _connect_client(svc)
    try:
        if not pump_until(svc, lambda: len(svc.conns) >= 1, timeout_s=2.0):
            fail("head-timeout: the connection was never even accepted")
            return
        future = time.monotonic() + nb_proxy.HEAD_TIMEOUT + 1.0
        svc.tick(future)
        if svc.conns:
            fail("head-timeout: a connection that never sent its request "
                 "head was still open %.0fs past HEAD_TIMEOUT"
                 % (nb_proxy.HEAD_TIMEOUT + 1))
    finally:
        client.close()
        svc.close()


def _check_max_conns_enforced():
    """check the MAX_CONNS connection limit"""
    if not hasattr(nb_proxy, "MAX_CONNS"):
        fail("resource-bounds: no MAX_CONNS -- proxy connections are unbounded")
        return
    svc = _make_service(proxy_url=None)
    clients = []
    try:
        cap = nb_proxy.MAX_CONNS
        for _ in range(cap + 20):
            clients.append(_connect_client(svc))
            if len(clients) % 32 == 0:
                pump_until(svc, lambda: False, timeout_s=0.05)
        pump_until(svc, lambda: False, timeout_s=1.5)
        if len(svc.conns) > cap:
            fail("max-conns: %d connections were accepted, over MAX_CONNS=%d"
                 % (len(svc.conns), cap))
    finally:
        for c in clients:
            c.close()
        svc.close()


def _check_idle_timeout():
    """check that an idle relay is closed after the idle timeout"""
    if not hasattr(nb_proxy, "IDLE_TIMEOUT"):
        fail("resource-bounds: no IDLE_TIMEOUT")
        return
    origin = EchoServer()
    svc = _make_service(proxy_url=None, target_policy=_permissive_policy())
    client = _connect_client(svc)
    reader = ClientReader(client)
    try:
        client.sendall(b"CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % origin.port)
        if not pump_until(svc, lambda: b"200 Connection established" in reader.pull()):
            fail("idle-timeout: the setup CONNECT itself failed")
            return
        future = time.monotonic() + nb_proxy.IDLE_TIMEOUT + 1.0
        svc.tick(future)
        if svc.conns:
            fail("idle-timeout: an established relay with no traffic was "
                 "still open %.0fs past IDLE_TIMEOUT" % (nb_proxy.IDLE_TIMEOUT + 1))
    finally:
        client.close()
        svc.close()
        origin.close()


def _check_flush_retries_without_new_data():
    """test tick() with bytes in buf_u2c"""
    origin = EchoServer()
    svc = _make_service(proxy_url=None, target_policy=_permissive_policy())
    client = _connect_client(svc)
    reader = ClientReader(client)
    try:
        client.sendall(b"CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % origin.port)
        if not pump_until(svc, lambda: b"200 Connection established" in reader.pull()):
            fail("flush-retry: the setup CONNECT itself failed")
            return
        conn = next(iter(svc.conns.values()))
        conn.buf_u2c += b"STUCK-BYTES"
        deadline = time.monotonic() + 2.0
        seen = False
        while time.monotonic() < deadline:
            now = time.monotonic()
            nt = svc.next_tick(now)
            if nt is not None and nt <= now:
                svc.tick(now)
            if b"STUCK-BYTES" in reader.pull():
                seen = True
                break
            time.sleep(0.01)
        if not seen:
            fail("flush-retry: bytes left over from a partial send were "
                 "never retried by tick() with no new data from either side")
    finally:
        client.close()
        svc.close()
        origin.close()


def _check_log_injection_sanitized():
    """test log lines for embedded newlines"""
    svc = _make_service(proxy_url=None)
    client = _connect_client(svc)
    CAPTURED_LOG.clear()
    try:
        client.sendall(b"CONNECT evil\nNB_READY_forged:80 HTTP/1.1\r\n\r\n")
        pump_until(svc, lambda: bool(CAPTURED_LOG) or _client_is_closed(client), timeout_s=2.0)
    finally:
        client.close()
        svc.close()
    if not CAPTURED_LOG:
        fail("log-injection: no log line was captured for the crafted request at all")
        return
    for line in CAPTURED_LOG:
        if "\n" in line or "\r" in line:
            fail("log-injection: a captured log line carries a raw newline "
                 "or carriage return: %r" % line)


def run_all(corrupt=False):
    """run every check and collect the failures"""
    FAILURES.clear()
    _check_connect_via_upstream(corrupt)
    _check_connect_direct()
    _check_absolute_uri_direct()
    _check_no_proxy_match()
    _check_bad_request_refused()
    _check_target_policy_default_denies_loopback()
    _check_target_policy_denies_link_local_and_multicast()
    _check_target_policy_allow_override()
    _check_target_policy_bad_entries_stay_denied()
    _check_connect_policy_vocabulary()
    _check_hostname_resolution_offloaded()
    _check_head_timeout()
    _check_max_conns_enforced()
    _check_idle_timeout()
    _check_flush_retries_without_new_data()
    _check_log_injection_sanitized()
    return list(FAILURES)


def main():
    """run the proxy checks"""
    selftest = "--selftest" in sys.argv
    if selftest:
        problems = run_all(corrupt=True)
        if not problems:
            print("FAIL: corrupting an expectation produced no failure", file=sys.stderr)
            return 1
        print("selftest_proxy: selftest ok -- %d assertion(s) caught the corrupted run"
             % len(problems))
        return 0

    problems = run_all(corrupt=False)
    for msg in problems:
        print("FAIL: %s" % msg, file=sys.stderr)
    if problems:
        print("selftest_proxy: nb_proxy does not relay what it claims to", file=sys.stderr)
        return 1
    print("selftest_proxy: CONNECT and absolute-URI requests relay correctly, direct and via upstream")
    return 0


if __name__ == "__main__":
    sys.exit(main())
