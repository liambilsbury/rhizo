#!/usr/bin/env python3
"""HTTP forward and CONNECT proxy for the proxy-relay test"""
import argparse
import select
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USAGE = """Usage: proxy-fixture.py --port PORT --tag TAG [--bind 127.0.0.1]
       proxy-fixture.py --selftest"""

CONNECT_TIMEOUT = 10.0
RELAY_TIMEOUT = 10.0
RECV_CHUNK = 65536
HEAD_MAX = 64 * 1024
RELAY_MAX = 64 * 1024 * 1024


def log(event, *fields):
    """write an event line with its fields to stderr"""
    parts = " ".join("%s=%s" % (k, v) for k, v in fields)
    print("%s %s" % (event, parts), file=sys.stderr, flush=True)


def parse_request_line(line):
    """parse an HTTP request line"""
    parts = line.strip().split()
    if len(parts) != 3:
        return None
    return tuple(parts)


def parse_absolute_target(target):
    """parse host port and path from a URI"""
    if not target.lower().startswith("http://"):
        return None
    rest = target[len("http://"):]
    hostport, _, tail = rest.partition("/")
    path = "/" + tail
    if "@" in hostport:
        hostport = hostport.rsplit("@", 1)[1]
    if not hostport:
        return None
    if ":" in hostport:
        host, _, port_s = hostport.rpartition(":")
        if not host or not port_s.isdigit():
            return None
        return (host, int(port_s), path)
    return (hostport, 80, path)


def parse_connect_target(target):
    """parse host and port from a CONNECT target"""
    host, sep, port_s = target.rpartition(":")
    if not sep or not host or not port_s.isdigit():
        return None
    return (host, int(port_s))


def build_origin_request(method, version, path, header_lines, host, port):
    """build the origin-form request bytes"""
    lines = ["%s %s %s" % (method, path, version)]
    has_host = any(h.split(":", 1)[0].strip().lower() == "host" for h in header_lines if h.strip())
    lines.extend(h for h in header_lines if h.strip())
    if not has_host:
        host_header = host if port == 80 else "%s:%d" % (host, port)
        lines.append("Host: %s" % host_header)
    return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")


def insert_tag_header(head_bytes, tag):
    """add the X-Rhizo-Proxy header to a response head"""
    lines = head_bytes.decode("latin-1").split("\r\n")
    lines.insert(1, "X-Rhizo-Proxy: %s" % tag)
    return "\r\n".join(lines).encode("latin-1")


def _read_head(sock):
    """read a response head from the socket"""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(RECV_CHUNK)
        if not chunk:
            raise ConnectionError("origin closed before the response head completed")
        buf += chunk
        if len(buf) > HEAD_MAX:
            raise ValueError("response head exceeds %d bytes" % HEAD_MAX)
    idx = buf.find(b"\r\n\r\n")
    return buf[:idx + 4], buf[idx + 4:]


def _content_length(head_bytes):
    """return the content length of a response head, or None"""
    for line in head_bytes.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            try:
                return int(line.split(b":", 1)[1].strip())
            except ValueError:
                return None
    return None


def _status_from_head(head_bytes):
    """return the status code of a response head"""
    parts = head_bytes.split(b"\r\n", 1)[0].split(b" ", 2)
    return parts[1].decode("latin-1") if len(parts) >= 2 else "?"


def _relay_body(origin_sock, wfile, extra, content_length):
    """copy the response body from origin_sock to wfile"""
    written = len(extra)
    if extra:
        wfile.write(extra)
    if content_length is not None:
        remaining = content_length - written
        while remaining > 0:
            chunk = origin_sock.recv(min(RECV_CHUNK, remaining))
            if not chunk:
                break
            wfile.write(chunk)
            written += len(chunk)
            remaining -= len(chunk)
    else:
        while written < RELAY_MAX:
            chunk = origin_sock.recv(RECV_CHUNK)
            if not chunk:
                break
            wfile.write(chunk)
            written += len(chunk)
    return written


def _pump_tunnel(client_sock, origin_sock):
    """copy bytes between two sockets"""
    socks = [client_sock, origin_sock]
    while True:
        readable, _w, errored = select.select(socks, [], socks, RELAY_TIMEOUT)
        if errored or not readable:
            return
        for s in readable:
            other = origin_sock if s is client_sock else client_sock
            try:
                chunk = s.recv(RECV_CHUNK)
            except OSError:
                return
            if not chunk:
                return
            try:
                other.sendall(chunk)
            except OSError:
                return


class ProxyFixHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        """discard the server's log lines"""
        pass

    def _from(self):
        """return the client's address as host:port"""
        return "%s:%d" % self.client_address

    def do_GET(self):
        """forward a request for an absolute URI to its origin and relay the response"""
        tag = self.server.tag
        target = self.path
        parsed = parse_absolute_target(target)
        if parsed is None:
            log("PROXYFIX_FAIL", ("tag", tag), ("target", target), ("reason", "not_absolute_uri"))
            self.send_error(400, "not an absolute-URI proxy request")
            return
        host, port, path = parsed
        log("PROXYFIX_REQUEST", ("tag", tag), ("method", self.command), ("target", target), ("from", self._from()))

        body = b""
        cl = self.headers.get("Content-Length")
        if cl is not None:
            try:
                body = self.rfile.read(int(cl))
            except (ValueError, OSError) as e:
                log("PROXYFIX_FAIL", ("tag", tag), ("target", target), ("reason", "bad_request_body:%s" % e))
                self.send_error(400, "bad request body")
                return

        header_lines = ["%s: %s" % (k, v) for k, v in self.headers.items()]
        req_bytes = build_origin_request(self.command, self.request_version, path, header_lines, host, port) + body

        try:
            origin = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        except OSError as e:
            log("PROXYFIX_FAIL", ("tag", tag), ("target", target), ("reason", "connect_error:%s" % e))
            self.send_error(502, "could not reach origin")
            return
        origin.settimeout(RELAY_TIMEOUT)
        try:
            origin.sendall(req_bytes)
            head, extra = _read_head(origin)
        except (OSError, ValueError) as e:
            log("PROXYFIX_FAIL", ("tag", tag), ("target", target), ("reason", "origin_response_error:%s" % e))
            self.send_error(502, "origin did not answer")
            origin.close()
            return

        status = _status_from_head(head)
        self.wfile.write(insert_tag_header(head, tag))
        written = _relay_body(origin, self.wfile, extra, _content_length(head))
        origin.close()
        log("PROXYFIX_RESPONSE", ("tag", tag), ("target", target), ("status", status), ("bytes", written))

    do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_GET

    def do_CONNECT(self):
        """open a tunnel to the CONNECT target"""
        tag = self.server.tag
        target = self.path
        parsed = parse_connect_target(target)
        if parsed is None:
            log("PROXYFIX_FAIL", ("tag", tag), ("target", target), ("reason", "bad_connect_target"))
            self.send_error(400, "bad CONNECT target")
            return
        host, port = parsed
        log("PROXYFIX_CONNECT", ("tag", tag), ("target", target), ("from", self._from()))

        try:
            origin = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        except OSError as e:
            log("PROXYFIX_FAIL", ("tag", tag), ("target", target), ("reason", "connect_error:%s" % e))
            self.send_error(502, "could not reach origin")
            return
        origin.settimeout(RELAY_TIMEOUT)
        try:
            self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
        except OSError as e:
            log("PROXYFIX_FAIL", ("tag", tag), ("target", target), ("reason", "established_write_error:%s" % e))
            origin.close()
            return
        self.close_connection = True
        _pump_tunnel(self.connection, origin)
        origin.close()


class Server(ThreadingHTTPServer):
    daemon_threads = True


GOOD_ABSOLUTE_LINE = "GET http://rhizo-test.internal:8080/nettest HTTP/1.1"
GOOD_CONNECT_LINE = "CONNECT rhizo-test.internal:443 HTTP/1.1"
BAD_ABSOLUTE_LINE = "GET /nettest HTTP/1.1"
BAD_CONNECT_LINE = "CONNECT rhizo-test.internal HTTP/1.1"


def selftest():
    """check the request parsers on sample lines"""
    ok = True

    method, target, _version = parse_request_line(GOOD_ABSOLUTE_LINE)
    got = parse_absolute_target(target)
    want = ("rhizo-test.internal", 8080, "/nettest")
    if got != want:
        print("SELFTEST FAILED: absolute-URI target parsed as %r, want %r" % (got, want), file=sys.stderr)
        ok = False

    method, target, _version = parse_request_line(GOOD_CONNECT_LINE)
    got = parse_connect_target(target)
    want = ("rhizo-test.internal", 443)
    if got != want:
        print("SELFTEST FAILED: CONNECT target parsed as %r, want %r" % (got, want), file=sys.stderr)
        ok = False

    _method, target, _version = parse_request_line(BAD_ABSOLUTE_LINE)
    if parse_absolute_target(target) is not None:
        print("SELFTEST FAILED: a relative-form request line was accepted as absolute-URI", file=sys.stderr)
        ok = False

    _method, target, _version = parse_request_line(BAD_CONNECT_LINE)
    if parse_connect_target(target) is not None:
        print("SELFTEST FAILED: a CONNECT target with no port was accepted", file=sys.stderr)
        ok = False

    tagged = insert_tag_header(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n", "up-a")
    if b"X-Rhizo-Proxy: up-a" not in tagged:
        print("SELFTEST FAILED: X-Rhizo-Proxy header was not inserted into %r" % tagged, file=sys.stderr)
        ok = False

    if not ok:
        return 1
    print("selftest ok: absolute-URI and CONNECT lines parse correctly, malformed ones are "
          "refused, and the response tag is inserted")
    return 0


def main():
    """parse the arguments and serve the proxy or run the selftest"""
    p = argparse.ArgumentParser(description=__doc__ + "\n\n" + USAGE)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--port", type=int)
    p.add_argument("--tag")
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        sys.exit(selftest())
    if a.port is None or not a.tag:
        p.error("--port and --tag are required")

    httpd = Server((a.bind, a.port), ProxyFixHandler)
    httpd.tag = a.tag
    log("PROXYFIX_READY", ("bind", a.bind), ("port", a.port), ("tag", a.tag))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
