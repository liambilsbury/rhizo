#!/usr/bin/env python3
import argparse
import os
import select
import socket
import struct
import sys

MDNS_PORT = 5353
MDNS_GROUP4 = "224.0.0.251"
MDNS_GROUP6 = "ff02::fb"
IF_INET6_PATH = "/proc/net/if_inet6"
IPV6_SCOPE_GLOBAL = 0x00

SERVICE_TYPE = "_rhizotest._tcp.local"
MARKER = "RHIZO-LAN-OK"
TXT_MARKER = "marker=" + MARKER

TYPE_A = 1
TYPE_PTR = 12
TYPE_TXT = 16
TYPE_AAAA = 28
TYPE_SRV = 33
TYPE_ANY = 255
CLASS_IN = 1
RR_TTL = 120


def log(event, *fields):
    """write an event line with its fields to stderr"""
    parts = " ".join("%s=%s" % (k, v) for k, v in fields)
    print("%s %s" % (event, parts), file=sys.stderr, flush=True)


def read_global_ipv6(ifname, path=IF_INET6_PATH):
    """return the interface's global ipv6 address"""
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError as e:
        log("LANFIX_FAIL", ("reason", "if_inet6_read"), ("path", path), ("error", e))
        return None
    for line in lines:
        parts = line.split()
        if len(parts) != 6:
            continue
        addr_hex, _idx, _plen, scope_hex, _flags, devname = parts
        if devname != ifname:
            continue
        try:
            scope = int(scope_hex, 16)
        except ValueError:
            continue
        if scope == IPV6_SCOPE_GLOBAL:
            return socket.inet_ntop(socket.AF_INET6, bytes.fromhex(addr_hex))
    return None


def encode_name(name):
    """encode a dns name as length-prefixed labels"""
    out = bytearray()
    for label in name.rstrip(".").split("."):
        out.append(len(label))
        out.extend(label.encode("ascii"))
    out.append(0)
    return bytes(out)


def decode_name(buf, pos):
    """decode a DNS name at an offset"""
    labels, jumped, guard = [], False, 0
    end = pos
    while guard < 128:
        guard += 1
        if pos >= len(buf):
            return None, None
        n = buf[pos]
        if n == 0:
            pos += 1
            if not jumped:
                end = pos
            return ".".join(labels), end
        if n & 0xC0 == 0xC0:
            if pos + 1 >= len(buf):
                return None, None
            if not jumped:
                end = pos + 2
            pos = ((n & 0x3F) << 8) | buf[pos + 1]
            jumped = True
            continue
        if pos + 1 + n > len(buf):
            return None, None
        labels.append(buf[pos + 1:pos + 1 + n].decode("ascii", "replace"))
        pos += 1 + n
    return None, None


def parse_questions(data):
    """decode the DNS header and questions"""
    if len(data) < 12:
        return None
    tid, _flags, qd, _an, _ns, _ar = struct.unpack(">HHHHHH", data[:12])
    pos = 12
    out = []
    for _ in range(qd):
        name, pos2 = decode_name(data, pos)
        if name is None or pos2 is None or pos2 + 4 > len(data):
            return None
        qtype, _qclass = struct.unpack(">HH", data[pos2:pos2 + 4])
        out.append((name.lower(), qtype))
        pos = pos2 + 4
    return tid, out


def encode_rr(name, rtype, rdata, ttl=RR_TTL):
    """encode a resource record"""
    return encode_name(name) + struct.pack(">HHIH", rtype, CLASS_IN, ttl, len(rdata)) + rdata


def rr_ptr(instance_fqdn):
    """return the PTR record data for an instance name"""
    return encode_name(instance_fqdn)


def rr_srv(host_fqdn, port):
    """return the SRV record data for a host and port"""
    return struct.pack(">HHH", 0, 0, port) + encode_name(host_fqdn)


def rr_txt(text):
    """return the TXT record data for a text"""
    body = text.encode("ascii")
    return bytes([len(body)]) + body


def rr_a(ip):
    """return the A record data for an IPv4 address"""
    return socket.inet_aton(ip)


def rr_aaaa(ip6):
    """return the AAAA record data for an IPv6 address"""
    return socket.inet_pton(socket.AF_INET6, ip6)


def build_response(tid, records):
    """build an mDNS response packet from records"""
    flags = struct.pack(">H", 0x8400)
    counts = struct.pack(">HHHH", 0, len(records), 0, 0)
    body = b"".join(encode_rr(name, rtype, rdata) for name, rtype, rdata in records)
    return struct.pack(">H", tid) + flags + counts + body


class Fixture:
    def __init__(self, iface, ip4, port, instance, ip6=None):
        """store the interface, addresses, port and instance name to announce"""
        self.iface = iface
        self.ip4 = ip4
        self.ip6 = ip6
        self.port = port
        self.instance = instance
        self.instance_fqdn = "%s.%s" % (instance, SERVICE_TYPE)
        self.host_fqdn = "%s.local" % instance

    def records_for(self, qname, qtype):
        """return the records for a DNS question"""
        q = qname.rstrip(".")
        any_type = qtype == TYPE_ANY
        recs = []
        if q == SERVICE_TYPE and (qtype == TYPE_PTR or any_type):
            recs.append((SERVICE_TYPE, TYPE_PTR, rr_ptr(self.instance_fqdn)))
            recs.append((self.instance_fqdn, TYPE_SRV, rr_srv(self.host_fqdn, self.port)))
            recs.append((self.instance_fqdn, TYPE_TXT, rr_txt(TXT_MARKER)))
            recs.append((self.host_fqdn, TYPE_A, rr_a(self.ip4)))
            if self.ip6:
                recs.append((self.host_fqdn, TYPE_AAAA, rr_aaaa(self.ip6)))
        elif q == self.instance_fqdn and (qtype in (TYPE_SRV, TYPE_TXT) or any_type):
            recs.append((self.instance_fqdn, TYPE_SRV, rr_srv(self.host_fqdn, self.port)))
            recs.append((self.instance_fqdn, TYPE_TXT, rr_txt(TXT_MARKER)))
        elif q == self.host_fqdn:
            if qtype == TYPE_A or any_type:
                recs.append((self.host_fqdn, TYPE_A, rr_a(self.ip4)))
            if self.ip6 and (qtype == TYPE_AAAA or any_type):
                recs.append((self.host_fqdn, TYPE_AAAA, rr_aaaa(self.ip6)))
        return recs


def answer_query(fixture, data, from_ip):
    """return the response to an mDNS query, or None when nothing matches"""
    parsed = parse_questions(data)
    if parsed is None:
        return None
    tid, questions = parsed
    if not questions:
        return None
    records = []
    for qname, qtype in questions:
        log("LANFIX_QUERY", ("qname", qname), ("from", from_ip))
        records.extend(fixture.records_for(qname, qtype))
    if not records:
        return None
    log("LANFIX_ANSWER", ("qname", questions[0][0]), ("records", len(records)))
    return build_response(tid, records)


def _mreqn(multiaddr_bytes, ifindex):
    """pack a struct ip_mreqn"""
    return struct.pack("=4s4si", multiaddr_bytes, b"\x00\x00\x00\x00", ifindex)


def open_v4_socket(ifname):
    """open an IPv4 multicast socket on an interface"""
    ifindex = socket.if_nametoindex(ifname)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, ifname.encode())
    s.bind(("", MDNS_PORT))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                 _mreqn(socket.inet_aton(MDNS_GROUP4), ifindex))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, _mreqn(b"\x00\x00\x00\x00", ifindex))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    return s, ifindex


def open_v6_socket(ifname):
    """open an IPv6 multicast socket on an interface"""
    ifindex = socket.if_nametoindex(ifname)
    s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, ifname.encode())
    s.bind(("", MDNS_PORT))
    mreq = struct.pack("=16sI", socket.inet_pton(socket.AF_INET6, MDNS_GROUP6), ifindex)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_JOIN_GROUP, mreq)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, ifindex)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_LOOP, 0)
    return s, ifindex


def handle_mdns(fixture, sock, ifindex, family):
    """read a mDNS query and send its answer"""
    try:
        data, addr = sock.recvfrom(65536)
    except OSError as e:
        log("LANFIX_FAIL", ("reason", "recv"), ("family", family), ("error", e))
        return
    resp = answer_query(fixture, data, addr[0])
    if resp is None:
        return
    dest = (MDNS_GROUP4, MDNS_PORT) if family == 4 else (MDNS_GROUP6, MDNS_PORT, 0, ifindex)
    try:
        sock.sendto(resp, dest)
    except OSError as e:
        log("LANFIX_FAIL", ("reason", "send"), ("family", family), ("error", e))


def handle_tcp(tcp_sock):
    """accept a TCP connection, send the marker and close it"""
    conn, addr = tcp_sock.accept()
    try:
        body = MARKER.encode("ascii")
        conn.sendall(body)
        log("LANFIX_TCP", ("from", addr[0]), ("bytes", len(body)))
    except OSError as e:
        log("LANFIX_FAIL", ("reason", "tcp_send"), ("from", addr[0]), ("error", e))
    finally:
        conn.close()


def serve(fixture):
    """answer mDNS queries and TCP connections until stopped"""
    v4_sock, v4_idx = open_v4_socket(fixture.iface)
    v6_sock = v6_idx = None
    if fixture.ip6:
        v6_sock, v6_idx = open_v6_socket(fixture.iface)
    tcp_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tcp_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp_sock.bind((fixture.ip4, fixture.port))
    tcp_sock.listen(8)
    log("LANFIX_READY", ("iface", fixture.iface), ("ip", fixture.ip4), ("port", fixture.port))
    socks = [v4_sock, tcp_sock] + ([v6_sock] if v6_sock else [])
    while True:
        readable, _w, _x = select.select(socks, [], [])
        for s in readable:
            if s is tcp_sock:
                handle_tcp(tcp_sock)
            elif s is v4_sock:
                handle_mdns(fixture, v4_sock, v4_idx, 4)
            elif s is v6_sock:
                handle_mdns(fixture, v6_sock, v6_idx, 6)


def _verify_record(name, rtype, got, fixture):
    """compare a decoded record with the fixture values"""
    want_type = {TYPE_PTR: "PTR", TYPE_SRV: "SRV", TYPE_TXT: "TXT",
                 TYPE_A: "A", TYPE_AAAA: "AAAA"}.get(rtype)
    if got["type"] != want_type or got["name"].rstrip(".").lower() != name.rstrip(".").lower():
        return False
    if rtype == TYPE_A:
        return got["data"] == fixture.ip4
    if rtype == TYPE_AAAA:
        return socket.inet_pton(socket.AF_INET6, got["data"]) == socket.inet_pton(socket.AF_INET6, fixture.ip6)
    if rtype == TYPE_PTR:
        return got["data"].rstrip(".").lower() == fixture.instance_fqdn.lower()
    if rtype == TYPE_SRV:
        return got["data"].rstrip(".").lower() == fixture.host_fqdn.lower()
    return True


def selftest():
    """parse built responses with pcapstat parse_dns"""
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("rhizo_pcapstat", os.path.join(here, "..", "tools", "pcapstat.py"))
    pcapstat = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pcapstat)

    fixture = Fixture("eth-test", "10.77.0.2", 8053, "rhizo-lanfix", ip6="fd00::2")
    cases = [(SERVICE_TYPE, TYPE_PTR), (fixture.instance_fqdn, TYPE_ANY), (fixture.host_fqdn, TYPE_ANY)]
    ok = True
    for qname, qtype in cases:
        records = fixture.records_for(qname, qtype)
        if not records:
            print("SELFTEST FAILED: no records built for qname=%s type=%s" % (qname, qtype), file=sys.stderr)
            ok = False
            continue
        wire = build_response(0x1234, records)
        parsed = pcapstat.parse_dns(wire)
        if parsed is None or parsed.get("truncated"):
            print("SELFTEST FAILED: pcapstat could not parse the response for qname=%s" % qname, file=sys.stderr)
            ok = False
            continue
        if len(parsed["answers"]) != len(records):
            print("SELFTEST FAILED: qname=%s built %d records, pcapstat read back %d"
                  % (qname, len(records), len(parsed["answers"])), file=sys.stderr)
            ok = False
            continue
        for (name, rtype, _rdata), got in zip(records, parsed["answers"]):
            if not _verify_record(name, rtype, got, fixture):
                print("SELFTEST FAILED: qname=%s record mismatch: built name=%s type=%d, "
                      "pcapstat read %r" % (qname, name, rtype, got), file=sys.stderr)
                ok = False
    if not ok:
        return 1
    print("selftest ok: pcapstat.parse_dns agrees with every record this fixture builds")
    return 0


def main():
    """parse the arguments and serve the fixture"""
    p = argparse.ArgumentParser()
    p.add_argument("--iface")
    p.add_argument("--ip")
    p.add_argument("--port", type=int, default=8053)
    p.add_argument("--instance", default="rhizo-lanfix")
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        sys.exit(selftest())
    if not a.iface or not a.ip:
        p.error("--iface and --ip are required")
    ip6 = read_global_ipv6(a.iface)
    fixture = Fixture(a.iface, a.ip, a.port, a.instance, ip6)
    serve(fixture)


if __name__ == "__main__":
    main()
