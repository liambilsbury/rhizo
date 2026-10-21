#!/usr/bin/env python3
import argparse, socket, struct, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def parse_qname(query):
    """return the lowercased query name and type of a dns query"""
    labels, pos = [], 12
    while query[pos] != 0:
        n = query[pos]
        labels.append(query[pos + 1:pos + 1 + n].decode("ascii", "replace"))
        pos += n + 1
    qtype = struct.unpack(">H", query[pos + 1:pos + 3])[0]
    return ".".join(labels).lower(), qtype


def build_a_response(query, answer_ip, ttl=60):
    """build a DNS A record response"""
    tid = query[:2]
    flags = struct.pack(">H", 0x8180)
    counts = struct.pack(">HHHH", 1, 1, 0, 0)
    qend = query.find(b"\x00", 12) + 5
    question = query[12:qend]
    answer = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, ttl, 4) + socket.inet_aton(answer_ip)
    return tid + flags + counts + question + answer


def build_nxdomain(query):
    """build a DNS NXDOMAIN response"""
    tid = query[:2]
    flags = struct.pack(">H", 0x8183)
    counts = struct.pack(">HHHH", 1, 0, 0, 0)
    qend = query.find(b"\x00", 12) + 5
    return tid + flags + counts + query[12:qend]


def dns_server(bind_ip, hostname, answer_ip, log, ttl=60):
    """serve DNS on UDP port 53"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((bind_ip, 53))
    log(f"DNS listening on {bind_ip}:53, {hostname} -> A {answer_ip}, else NXDOMAIN")
    while True:
        data, addr = sock.recvfrom(512)
        try:
            qname, qtype = parse_qname(data)
        except Exception as e:
            log(f"DNS: malformed query from {addr[0]}: {e}")
            continue
        is_match = qname.rstrip(".") == hostname and qtype == 1
        resp = build_a_response(data, answer_ip, ttl) if is_match else build_nxdomain(data)
        sock.sendto(resp, addr)
        log(f"DNS {addr[0]}:{addr[1]} asked {qname} type={qtype} -> {'A ' + answer_ip if is_match else 'NXDOMAIN'} "
            f"query={data[:96].hex()} response={resp[:96].hex()}")


PORTAL_REDIRECT = None
THROUGHPUT_BODY = (b"RHIZO-NET-THROUGHPUT-" * (32 * 1024 * 1024 // 21 + 1))[: 32 * 1024 * 1024]
THROUGHPUT2_BODY = (b"RHIZO-NET-THROUGHPUT2-" * (8 * 1024 * 1024 // 22 + 1))[: 8 * 1024 * 1024]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        """write an http log line to stderr"""
        sys.stderr.write("HTTP " + (fmt % a) + "\n")

    def do_GET(self):
        """send the response for a GET path"""
        if self.path == "/generate_204" and PORTAL_REDIRECT:
            self.send_response(302)
            self.send_header("Location", PORTAL_REDIRECT)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/generate_204":
            self.send_response(204)
            self.end_headers()
            return
        if self.path == "/nettest":
            body = f"RHIZO-NET-OK req={time.time_ns()} served-by={socket.gethostname()}\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/throughput":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(THROUGHPUT_BODY)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(THROUGHPUT_BODY)
            return
        if self.path == "/throughput2":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(THROUGHPUT2_BODY)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(THROUGHPUT2_BODY)
            return
        self.send_response(404)
        self.end_headers()


def main():
    """serve HTTP on two ports"""
    p = argparse.ArgumentParser()
    p.add_argument("--ip", required=True, help="bind/answer IP (the veth host-side address)")
    p.add_argument("--port2", type=int, default=8081,
                   help="second fixture port")
    p.add_argument("--hostname", default="rhizo-test.internal")
    p.add_argument("--with-dns", action="store_true",
                   help="also serve DNS on :53, which rhizo-netbridged owns")
    p.add_argument("--portal-redirect", default=None, metavar="URL",
                   help="answer /generate_204 with a 302 to URL, so the probe "
                        "sees a captive portal instead of an open network")
    p.add_argument("--ttl", type=int, default=60,
                   help="answer TTL; a live-change proof needs one short enough "
                        "that Android's own resolver cache cannot mask the change")
    a = p.parse_args()
    log = lambda m: print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)
    global PORTAL_REDIRECT
    PORTAL_REDIRECT = a.portal_redirect

    if a.with_dns:
        threading.Thread(target=dns_server, args=(a.ip, a.hostname, a.ip, log, a.ttl), daemon=True).start()
    if ":" in a.ip:
        ThreadingHTTPServer.address_family = socket.AF_INET6
    httpd = ThreadingHTTPServer((a.ip, 80), Handler)
    log(f"HTTP listening on {a.ip}:80 (/nettest, /generate_204, /throughput)")

    def _serve_second():
        """serve the second fixture port"""
        h2 = ThreadingHTTPServer((a.ip, a.port2), Handler)
        log(f"HTTP listening on {a.ip}:{a.port2} (second fixture port, /throughput2)")
        h2.serve_forever()
    threading.Thread(target=_serve_second, daemon=True).start()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
