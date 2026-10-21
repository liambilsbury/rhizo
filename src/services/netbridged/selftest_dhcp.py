#!/usr/bin/env python3
import argparse
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nb_dhcp  # noqa: E402
from nb_dhcp import DhcpService, build_header, decode_reply, ip_to_int, \
    parse_packet  # noqa: E402

FAILURES = []


def fail(msg):
    """record a failure message"""
    FAILURES.append(msg)


def make_cfg(state_dir):
    """build a service config for the given state directory"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--veth-if", default="vethrhz0")
    ap.add_argument("--veth-addr", default="192.168.100.1")
    ap.add_argument("--subnet", default="192.168.100.0/24")
    ap.add_argument("--pool-start", default="192.168.100.50")
    ap.add_argument("--pool-end", default="192.168.100.52")
    ap.add_argument("--lease-seconds", type=int, default=600)
    ap.add_argument("--state-dir", default=state_dir)
    return ap.parse_args([])


def encode_options_raw(pairs):
    """encode raw option pairs followed by the end marker"""
    out = bytearray()
    for code, value in pairs:
        out += bytes([code, len(value)]) + value
    out += bytes([255])
    return bytes(out)


def discover(mac, xid=1, broadcast=True):
    """build a discover packet for a hardware address"""
    flags = 0x8000 if broadcast else 0
    header = build_header(nb_dhcp.BOOTREQUEST, xid, flags, "0.0.0.0", "0.0.0.0", mac)
    return header + encode_options_raw([(53, bytes([nb_dhcp.MSG_DISCOVER]))])


def request(mac, requested_ip=None, server_id=None, xid=1, ciaddr="0.0.0.0"):
    """build a request packet"""
    header = build_header(nb_dhcp.BOOTREQUEST, xid, 0x8000, ciaddr, "0.0.0.0", mac)
    opts = [(53, bytes([nb_dhcp.MSG_REQUEST]))]
    if requested_ip is not None:
        opts.append((50, nb_dhcp.ip_to_bytes(requested_ip)))
    if server_id is not None:
        opts.append((54, nb_dhcp.ip_to_bytes(server_id)))
    return header + encode_options_raw(opts)


class FakeSock:
    """fake socket for DHCP tests"""

    def __init__(self):
        """start with no sent packets"""
        self.sent = []

    def sendto(self, data, dest):
        """record a sent packet and its destination"""
        self.sent.append((data, dest))


def new_service(state_dir):
    """create a DHCP service for the given state directory"""
    cfg = make_cfg(state_dir)
    svc = DhcpService(cfg)
    return svc


def test_offer_options(d):
    """check the options of an offer"""
    svc = new_service(d)
    sock = FakeSock()
    svc._handle(discover(b"\xaa\xbb\xcc\x00\x00\x01"), sock)
    if len(sock.sent) != 1:
        fail(f"a DISCOVER should produce exactly one reply, got {len(sock.sent)}")
        return
    reply = decode_reply(sock.sent[0][0])
    if reply is None:
        fail("the OFFER did not decode")
        return
    if reply.get("msg_type") != nb_dhcp.MSG_OFFER:
        fail(f"expected an OFFER, got msg_type={reply.get('msg_type')}")
    if reply.get("router") != "192.168.100.1":
        fail(f"wrong router option: {reply.get('router')}")
    if reply.get("dns") != "192.168.100.1":
        fail(f"DNS option should be our own address, got {reply.get('dns')}")
    if reply.get("mask") != "255.255.255.0":
        fail(f"wrong subnet mask: {reply.get('mask')}")
    if reply.get("lease") != 600:
        fail(f"wrong lease time: {reply.get('lease')}")
    if reply.get("server_id") != "192.168.100.1":
        fail(f"wrong server identifier: {reply.get('server_id')}")
    ip_int = ip_to_int(reply["yiaddr"])
    if not (svc.pool_start <= ip_int <= svc.pool_end):
        fail(f"offered address {reply['yiaddr']} is outside the pool")


def test_request_wrong_server_ignored(d):
    """check that a request naming another server is ignored"""
    svc = new_service(d)
    sock = FakeSock()
    svc._handle(request(b"\xaa\xbb\xcc\x00\x00\x02", requested_ip="192.168.100.50",
                        server_id="10.9.9.9"), sock)
    if sock.sent:
        fail("a REQUEST naming a different server identifier got a reply")


def test_request_outside_pool_naked(d):
    """check that a request outside the pool is refused"""
    svc = new_service(d)
    sock = FakeSock()
    svc._handle(request(b"\xaa\xbb\xcc\x00\x00\x03", requested_ip="192.168.100.9",
                        server_id="192.168.100.1"), sock)
    if not sock.sent:
        fail("a REQUEST for an out-of-pool address got no reply at all")
        return
    reply = decode_reply(sock.sent[0][0])
    if reply is None or reply.get("msg_type") != nb_dhcp.MSG_NAK:
        fail(f"expected a NAK, got {reply}")


def test_same_mac_same_address(d):
    """check that the same hardware address gets the same address"""
    svc = new_service(d)
    sock = FakeSock()
    mac = b"\xaa\xbb\xcc\x00\x00\x04"
    svc._handle(discover(mac, xid=1), sock)
    svc._handle(discover(mac, xid=2), sock)
    if len(sock.sent) != 2:
        fail(f"two DISCOVERs should produce two OFFERs, got {len(sock.sent)}")
        return
    first = decode_reply(sock.sent[0][0])["yiaddr"]
    second = decode_reply(sock.sent[1][0])["yiaddr"]
    if first != second:
        fail(f"the same MAC got two different addresses: {first} then {second}")


def test_pool_exhaustion(d, caplog):
    """check that the pool runs out after its last address"""
    svc = new_service(d)
    sock = FakeSock()
    offered = set()
    for i in range(svc.pool_start, svc.pool_end + 1):
        mac = bytes([0xaa, 0xbb, 0xcc, 0, 0, i - svc.pool_start])
        svc._handle(discover(mac, xid=i), sock)
    for data, _dest in sock.sent:
        reply = decode_reply(data)
        if reply is not None and "yiaddr" in reply:
            offered.add(reply["yiaddr"])
    if len(offered) != (svc.pool_end - svc.pool_start + 1):
        fail(f"expected {svc.pool_end - svc.pool_start + 1} distinct addresses, "
             f"got {len(offered)}")

    before = len(sock.sent)
    extra_mac = b"\xaa\xbb\xcc\x00\x00\xff"
    svc._handle(discover(extra_mac, xid=999), sock)
    if len(sock.sent) != before:
        fail("an exhausted pool still sent an OFFER instead of refusing")
    if not any("NB_DHCP_POOL_EXHAUSTED" in line for line in caplog):
        fail("pool exhaustion was not logged")
    offered_after = {decode_reply(data)["yiaddr"] for data, _d in sock.sent
                     if decode_reply(data) is not None and "yiaddr" in decode_reply(data)}
    if len(offered_after) != len(offered):
        fail("pool exhaustion handed out a duplicate address")


def test_truncated_packet_rejected(d):
    """test truncated DHCP packet parsing"""
    header = build_header(nb_dhcp.BOOTREQUEST, 1, 0, "0.0.0.0", "0.0.0.0",
                          b"\xaa\xbb\xcc\x00\x00\x05")
    truncated = header + bytes([53, 1, nb_dhcp.MSG_DISCOVER]) + bytes([12, 10]) + b"abc"
    req, reason = parse_packet(truncated)
    if req is not None:
        fail(f"a truncated packet was parsed instead of refused: {req}")
    if reason is None:
        fail("a truncated packet was refused with no reason recorded")

    too_short = header[:10]
    req, reason = parse_packet(too_short)
    if req is not None:
        fail("a packet shorter than the fixed header was parsed")


def test_bad_cookie_rejected():
    """check that a packet with a bad magic cookie is rejected"""
    good = discover(b"\xaa\xbb\xcc\x00\x00\x06")
    corrupted = bytearray(good)
    corrupted[236:240] = b"\x00\x00\x00\x00"
    req, reason = parse_packet(bytes(corrupted))
    if req is not None:
        fail("a packet with a wrong magic cookie was parsed")
    if reason != "cookie":
        fail(f"expected reason=cookie, got {reason!r}")


def capture_log(fn):
    """run a function while capturing the lines it logs"""
    lines = []
    orig = nb_dhcp.log

    def spy(fmt, *args):
        """record a log line and pass it on"""
        lines.append(fmt % args if args else fmt)
        orig(fmt, *args)

    nb_dhcp.log = spy
    try:
        fn(lines)
    finally:
        nb_dhcp.log = orig
    return lines


def run_all():
    """run every check and collect the failures"""
    FAILURES.clear()
    with tempfile.TemporaryDirectory() as d1:
        test_offer_options(d1)
    with tempfile.TemporaryDirectory() as d2:
        test_request_wrong_server_ignored(d2)
    with tempfile.TemporaryDirectory() as d3:
        test_request_outside_pool_naked(d3)
    with tempfile.TemporaryDirectory() as d4:
        test_same_mac_same_address(d4)
    with tempfile.TemporaryDirectory() as d5:
        capture_log(lambda lines: test_pool_exhaustion(d5, lines))
    with tempfile.TemporaryDirectory() as d6:
        test_truncated_packet_rejected(d6)
    test_bad_cookie_rejected()
    return list(FAILURES)


def run_all_broken():
    """run test_offer_options with DNS 10.0.0.1"""
    real_build_reply = nb_dhcp.build_reply

    def broken_build_reply(msg_type, req, yiaddr, server_id, mask=None, router=None,
                           dns=None, lease_seconds=None, broadcast=None, domain=None):
        """build a reply with a wrong DNS server"""
        return real_build_reply(msg_type, req, yiaddr, server_id, mask, router,
                                "10.0.0.1", lease_seconds, broadcast, domain)

    nb_dhcp.build_reply = broken_build_reply
    try:
        FAILURES.clear()
        with tempfile.TemporaryDirectory() as d:
            test_offer_options(d)
        return list(FAILURES)
    finally:
        nb_dhcp.build_reply = real_build_reply


def main():
    """run the DHCP checks"""
    selftest = "--selftest" in sys.argv
    if selftest:
        broken = run_all_broken()
        if not broken:
            print("FAIL: breaking ip_to_int did not make any assertion fail", file=sys.stderr)
            return 1
        print(f"selftest_dhcp: selftest ok -- {len(broken)} assertion(s) "
              "caught the broken run")
        return 0

    problems = run_all()
    for msg in problems:
        print(f"FAIL: {msg}", file=sys.stderr)
    if problems:
        print("selftest_dhcp: nb_dhcp.py does not do what it claims to", file=sys.stderr)
        return 1
    print("selftest_dhcp: all fixtures decoded correctly, all bad ones refused")
    return 0


if __name__ == "__main__":
    sys.exit(main())
