#!/usr/bin/env python3
import os
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nb_dns as dns
import nb_hoststate

FAILURES = []


def check(cond, msg):
    """record a failure message when a condition is false"""
    if not cond:
        FAILURES.append(msg)


def run_checks(break_one=False):
    """check the DNS wire encoding and decisions"""
    FAILURES.clear()

    q = dns.build_response(0x1234, "rhizo.local", dns.QTYPE_A, 1,
                            dns.RCODE_NOERROR, True, "192.168.100.7", 60)
    hdr = dns.parse_header(q)
    check(hdr is not None, "round trip: header did not parse")
    txid, flags, _qd, _an, _ns, _ar = hdr
    check(txid == 0x1234, f"round trip: txid {txid:#x} != 0x1234")
    check(bool(flags & 0x0400), "round trip: AA bit not set on a local-style answer")
    parsed_q = dns.parse_question(q, 12)
    check(parsed_q is not None, "round trip: question did not parse")
    qname, _qtype, _qclass, pos = parsed_q
    check(qname == "rhizo.local", f"round trip: qname {qname!r} != 'rhizo.local'")
    rr = dns.parse_a_record(q, pos)
    check(rr is not None, "round trip: A record did not parse")
    _name, ip, ttl, _end = rr
    want_ip = "10.0.0.9" if break_one else "192.168.100.7"
    check(ip == want_ip, f"round trip: answer ip {ip!r} != {want_ip!r}")
    check(ttl == 60, f"round trip: ttl {ttl} != 60")

    msg = q + b"\xc0\x0c" + struct.pack(">HH", dns.QTYPE_A, 1)
    ptr_q = dns.parse_question(msg, len(q))
    check(ptr_q is not None, "compressed pointer: did not decode")
    check(ptr_q[0] == "rhizo.local", f"compressed pointer: decoded {ptr_q[0]!r}")

    truncated = struct.pack(">HHHHHH", 1, 0, 1, 0, 0, 0) + b"\x3frhizo"
    name, _pos = dns.parse_name(truncated, 12)
    check(name is None, f"truncated name: got {name!r} instead of None")

    local_map = {"router.rhizo": "192.168.100.1"}
    action, ip = dns.classify_query("router.rhizo", dns.QTYPE_A, local_map, None)
    check(action == "local", f"local-a: action {action!r} != 'local'")
    check(ip == "192.168.100.1", f"local-a: ip {ip!r} != '192.168.100.1'")
    other_action, _ip = dns.classify_query("elsewhere.example", dns.QTYPE_A, local_map, None)
    check(other_action == "forward", "local-a: an unrelated name was not sent to forward")

    action, ip = dns.classify_query("anything.at.all", dns.QTYPE_A, {}, "10.9.9.9")
    check(action == "portal", f"portal: action {action!r} != 'portal'")
    check(ip == "10.9.9.9", f"portal: ip {ip!r} != '10.9.9.9'")

    action, ip = dns.classify_query("router.rhizo", dns.QTYPE_A, local_map, "10.9.9.9")
    check(action == "portal", f"portal over local: action {action!r} != 'portal'")
    check(ip == "10.9.9.9", f"portal over local: ip {ip!r} != '10.9.9.9'")
    action, _ip = dns.classify_query("v6.rhizo", dns.QTYPE_AAAA,
                                      {}, "10.9.9.9", {"v6.rhizo": "fd00::9"})
    check(action == "portal-nxdomain",
          f"portal over local AAAA: action {action!r} != 'portal-nxdomain'")
    nxdomain = dns.build_response(0x7, "v6.rhizo", dns.QTYPE_AAAA, 1, dns.RCODE_NXDOMAIN, True)
    _txid, nflags, _qd, nan, _ns, _ar = dns.parse_header(nxdomain)
    check((nflags & 0xF) == dns.RCODE_NXDOMAIN, "portal-nxdomain: rcode is not NXDOMAIN")
    check(nan == 0, "portal-nxdomain: answer count is not 0")

    servfail = dns.build_response(0x9, "no-upstream.example", dns.QTYPE_A, 1,
                                   dns.RCODE_SERVFAIL, False)
    check(len(servfail) > 0, "no-upstreams: response was empty")
    _txid, sflags, _qd, _an, _ns, _ar = dns.parse_header(servfail)
    check((sflags & 0xF) == dns.RCODE_SERVFAIL, "no-upstreams: rcode is not SERVFAIL")

    table = dns.PendingTable()
    p1 = dns.Pending(client_txid=0xAAAA, qname="one.example", qtype=1, qclass=1,
                      proto="udp", addr=("10.0.0.1", 5001), conn=None, body=b"body-one",
                      resolvers=("8.8.8.8",), resolver_index=0, deadline=0.0, start=0.0)
    p2 = dns.Pending(client_txid=0xBBBB, qname="one.example", qtype=1, qclass=1,
                      proto="udp", addr=("10.0.0.2", 5002), conn=None, body=b"body-one",
                      resolvers=("8.8.8.8",), resolver_index=0, deadline=0.0, start=0.0)
    t1 = table.alloc("8.8.8.8")
    table.add("8.8.8.8", t1, p1)
    t2 = table.alloc("8.8.8.8")
    table.add("8.8.8.8", t2, p2)
    check(t1 != t2, "txid rewrite: two in-flight queries got the same forwarded id")
    matched = table.pop("8.8.8.8", t2)
    check(matched is not None, "txid rewrite: a live entry did not match")
    check(matched.addr == p2.addr, f"txid rewrite: reply for client 2 routed to {matched.addr}")
    check(table.pop("8.8.8.8", t2) is None, "txid rewrite: a popped entry was still there")
    check(table.pop("8.8.8.8", t1).addr == p1.addr, "txid rewrite: client 1's own entry mismatched")

    table2 = dns.PendingTable()
    ids = []
    for i in range(20):
        tid = table2.alloc("9.9.9.9")
        table2.add("9.9.9.9", tid, p1._replace(client_txid=i))
        ids.append(tid)
    diffs = [ids[i + 1] - ids[i] for i in range(len(ids) - 1)]
    check(not all(d == 1 for d in diffs),
          "txid alloc: 20 consecutive ids were exactly sequential")

    table3 = dns.PendingTable()
    for i in range(0x10000):
        table3.add("1.2.3.4", i, p1._replace(client_txid=i))
    exhausted = table3.alloc("1.2.3.4")
    check(exhausted is None,
          f"txid alloc exhaustion: alloc() on a full id space returned "
          f"{exhausted!r}, not None")
    if hasattr(table3, "__len__"):
        check(len(table3) == 0x10000, f"PendingTable.__len__ reported {len(table3)}, wanted 0x10000")
    else:
        check(False, "resource-bounds: PendingTable has no __len__")

    if hasattr(dns, "validate_forward_reply"):
        good = p1._replace(qname="secure.example", qtype=1, qclass=1)
        reply = dns.build_response(0xBEEF, "secure.example", 1, 1, dns.RCODE_NOERROR, True, "1.2.3.4")
        check(dns.validate_forward_reply(reply, ("8.8.8.8", 53), good) is None,
              "forward-reply: a genuine reply on port 53 with a matching question was rejected")
        check(dns.validate_forward_reply(reply, ("8.8.8.8", 5353), good) == "bad-source-port",
              "forward-reply: a reply from a non-53 source port was not flagged bad-source-port")
        mismatched_reply = dns.build_response(0xBEEF, "attacker.example", 1, 1, dns.RCODE_NOERROR, True, "6.6.6.6")
        check(dns.validate_forward_reply(mismatched_reply, ("8.8.8.8", 53), good) == "question-mismatch",
              "forward-reply: a reply answering a DIFFERENT question was not flagged question-mismatch")
    else:
        check(False, "forward-reply: no validate_forward_reply()")

    class _FakeTcp:
        def __init__(self, last_activity):
            """store the last activity time"""
            self.last_activity = last_activity
    if hasattr(dns, "prune_idle_tcp"):
        conns = {1: _FakeTcp(0.0), 2: _FakeTcp(100.0)}
        idle = dns.prune_idle_tcp(conns, now=50.0, idle_timeout=30.0)
        check(idle == [1], f"prune_idle_tcp: expected only fileno 1 idle, got {idle}")
    else:
        check(False, "resource-bounds: no prune_idle_tcp()")

    check(hasattr(dns, "MAX_PENDING"),
          "resource-bounds: no MAX_PENDING")
    check(hasattr(dns, "MAX_TCP_CONNS"),
          "resource-bounds: no MAX_TCP_CONNS -- DNS-over-TCP connections are unbounded")

    if hasattr(dns, "_ForwardSocket"):
        fwd = dns._ForwardSocket(rotate_interval=0.0)
        port_before = fwd.sock.getsockname()[1]
        rotated_while_pending = fwd.maybe_rotate(time.monotonic() + 1.0, pending_count=1)
        check(not rotated_while_pending,
              "forward-socket: rotated while a query was still outstanding")
        check(fwd.sock.getsockname()[1] == port_before,
              "forward-socket: the source port changed despite a pending query")
        rotated = fwd.maybe_rotate(time.monotonic() + 1.0, pending_count=0)
        check(rotated, "forward-socket: did not rotate once nothing was pending, past its interval")
        check(fwd.sock.getsockname()[1] != port_before,
              "forward-socket: the source port is unchanged after a rotation")
        fwd.close()
    else:
        check(False, "resource-bounds: no _ForwardSocket")

    captured = []
    real_log = dns.log
    dns.log = lambda fmt, *a: captured.append(fmt % a if a else fmt)
    try:
        svc = dns.DnsService.__new__(dns.DnsService)
        svc._local_a, svc._local_aaaa, svc._resolvers = {}, {}, []
        svc._portal_ip = None
        svc._pending = dns.PendingTable()
        svc._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        svc._udp.bind(("127.0.0.1", 0))
        svc._udp.setblocking(False)
        label = "evil\nNB_READY_forged".encode("ascii")
        query = (struct.pack(">HHHHHH", 0x4242, 0x0100, 1, 0, 0, 0)
                 + bytes([len(label)]) + label + b"\x00" + struct.pack(">HH", 1, 1))
        svc._handle_query(query, "udp", ("10.0.0.5", 12345), None)

        if hasattr(dns, "_ForwardSocket"):
            svc._resolvers = ["8.8.8.8"]
            svc._tcp_conns = {}
            svc._next_portal_check = 999999.0
            svc._fwd = dns._ForwardSocket()
            bad_pending = dns.Pending(client_txid=1, qname="evil\nNB_READY_2", qtype=1, qclass=1,
                                       proto="udp", addr=("10.0.0.5", 1), conn=None, body=b"",
                                       resolvers=("8.8.8.8",), resolver_index=0,
                                       deadline=0.0, start=0.0)
            svc._pending.add("8.8.8.8", 1, bad_pending)
            svc.tick(1.0)
            svc._fwd.close()
        svc._udp.close()
    finally:
        dns.log = real_log
    for line in captured:
        check("\n" not in line and "\r" not in line,
              f"log-injection: a captured log line carries a raw "
              f"newline/carriage-return: {line!r}")

    forward_v6_checks(break_one)
    resolv_conf_checks()
    return list(FAILURES)


def resolv_conf_checks():
    """check resolv.conf parsing"""
    servers, _ = nb_hoststate.parse_resolv_conf(
        "nameserver 0:0:0:0:0:0:0:1\nnameserver 2001:DB8::53\nnameserver FE80::1%lo\n"
        "nameserver 192.0.2.1\nnameserver dns.example\n")
    check(servers == ["::1", "2001:db8::53", "fe80::1%lo", "192.0.2.1"],
          f"resolv-conf: resolvers read as {servers}, not canonical with the non-address dropped")


def forward_v6_checks(break_one):
    """check forwarding to an IPv6 resolver"""
    if not hasattr(dns, "_upstream_addr"):
        check(False, "ipv6-upstream: no _upstream_addr()")
        return
    check(dns._upstream_addr("192.0.2.1", 53) == (socket.AF_INET, ("192.0.2.1", 53)),
          "ipv6-upstream: a v4 resolver is not addressed as AF_INET")
    check(dns._upstream_addr("2001:db8::53", 53) == (socket.AF_INET6, ("2001:db8::53", 53, 0, 0)),
          "ipv6-upstream: a global v6 resolver is not addressed as AF_INET6")
    lo = socket.if_nametoindex("lo")
    for scope in ("lo", str(lo)):
        check(dns._upstream_addr("fe80::1%" + scope, 53) == (socket.AF_INET6, ("fe80::1", 53, 0, lo)),
              f"ipv6-upstream: a link-local resolver lost its scope %{scope}")

    real_port, real_log = dns.DNS_PORT, dns.log
    dns.log = lambda fmt, *a: None
    stub = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    svc = dns.DnsService.__new__(dns.DnsService)
    try:
        stub.bind(("::1", 0))
        stub.settimeout(2)
        dns.DNS_PORT = stub.getsockname()[1]
        client.bind(("127.0.0.1", 0))
        client.settimeout(2)
        svc._local_a, svc._local_aaaa, svc._resolvers = {}, {}, ["::1"]
        svc._portal_ip, svc._pending, svc._tcp_conns = None, dns.PendingTable(), {}
        svc._udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        svc._udp.bind(("127.0.0.1", 0))
        svc._fwd = dns._ForwardSocket()
        query = (struct.pack(">HHHHHH", 0x5151, 0x0100, 1, 0, 0, 0) + b"\x07example\x03org\x00"
                 + struct.pack(">HH", 1, 1))
        svc._handle_query(query, "udp", client.getsockname(), None)
        data, src = stub.recvfrom(4096)
        check(src[0] == "::1", f"ipv6-upstream: the query left from {src[0]}, not over the v6 socket")
        our_txid = struct.unpack(">H", data[:2])[0]
        answer_ip = "192.0.2.99"
        reply = dns.build_response(our_txid, "example.org", 1, 1, dns.RCODE_NOERROR, True, answer_ip, 30)
        stub.sendto(reply, src)
        socks = svc._fwd.socks()
        check(len(socks) == len(set(socks)) and any(s.family == socket.AF_INET6 for s in socks),
              "ipv6-upstream: no v6 upstream socket was opened")
        for sock in socks:
            if sock.family == socket.AF_INET6:
                svc._on_fwd_readable(sock)
        got, _ = client.recvfrom(4096)
        rr = dns.parse_a_record(got, dns.parse_question(got, 12)[3])
        want_ip = "198.51.100.1" if break_one else answer_ip
        check(rr is not None and rr[1] == want_ip,
              f"ipv6-upstream: the client got {rr and rr[1]!r}, want {want_ip!r}")
    except (OSError, TypeError) as e:
        check(False, f"ipv6-upstream: the forward round trip failed: {e!r}")
    finally:
        dns.DNS_PORT, dns.log = real_port, real_log
        for s in (stub, client, getattr(svc, "_udp", None)):
            if s is not None:
                s.close()
        if hasattr(svc, "_fwd"):
            svc._fwd.close()


def main():
    """run the DNS checks"""
    selftest = "--selftest" in sys.argv
    if selftest:
        problems = run_checks(break_one=True)
        if not problems:
            print("FAIL: run_checks passed against a deliberately broken answer", file=sys.stderr)
            return 1
        print(f"selftest_dns: selftest ok -- {len(problems)} assertion(s) caught the break")
        return 0

    problems = run_checks(break_one=False)
    for msg in problems:
        print(f"FAIL: {msg}", file=sys.stderr)
    if problems:
        print("selftest_dns: nb_dns.py does not do what it claims", file=sys.stderr)
        return 1
    print("selftest_dns: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
