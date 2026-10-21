#!/usr/bin/env python3
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import nb_ra  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PCAPSTAT = os.path.join(HERE, "..", "..", "..", "test", "system", "tools", "pcapstat.py")

PREFIX = "fd00:12ab:cd34::"
MAC = bytes.fromhex("aabbccddeeff")
MTU = 1500
ROUTER_LIFETIME = 1800
VALID_LIFETIME = 2592000
PREFERRED_LIFETIME = 604800
RDNSS_LIFETIME = 40

FAILURES = []


def fail(msg):
    """record a failure message"""
    FAILURES.append(msg)


def iter_options(pkt):
    """yield each option type and bytes"""
    pos = 16
    while pos + 8 <= len(pkt):
        otype, olen8 = pkt[pos], pkt[pos + 1]
        if olen8 == 0:
            break
        olen = olen8 * 8
        yield otype, pkt[pos:pos + olen]
        pos += olen


def find_option(pkt, otype):
    """return the option of a type in a packet, or None"""
    for t, opt in iter_options(pkt):
        if t == otype:
            return opt
    return None


def test_header(pkt):
    """check the router advertisement header fields"""
    if pkt[0] != nb_ra.ICMPV6_RA:
        fail(f"expected ICMPv6 type 134, got {pkt[0]}")
    lifetime = struct.unpack(">H", pkt[6:8])[0]
    if lifetime != ROUTER_LIFETIME:
        fail(f"expected router lifetime {ROUTER_LIFETIME}, got {lifetime}")


def test_prefix_info(pkt):
    """check the prefix information option"""
    opt = find_option(pkt, nb_ra.ND_OPT_PREFIX_INFO)
    if opt is None:
        fail("no Prefix Information option found")
        return
    if opt[1] != 4:
        fail(f"Prefix Information option should be 4 8-octet units, got {opt[1]}")
    if opt[2] != 64:
        fail(f"expected prefix length 64, got {opt[2]}")
    if opt[3] != 0xC0:
        fail(f"expected on-link+autonomous flags 0xc0, got {opt[3]:#x}")
    prefix = socket.inet_ntop(socket.AF_INET6, opt[16:32])
    if prefix != PREFIX:
        fail(f"expected prefix {PREFIX}, got {prefix}")


def test_rdnss(pkt):
    """check the recursive DNS server option"""
    opt = find_option(pkt, nb_ra.ND_OPT_RDNSS)
    if opt is None:
        fail("no RDNSS option found")
        return
    if opt[0] != nb_ra.ND_OPT_RDNSS:
        fail(f"RDNSS option type should be 25, got {opt[0]}")
    if len(opt) % 8 != 0 or opt[1] * 8 != len(opt):
        fail(f"RDNSS option length field {opt[1]} does not match its size {len(opt)}")
    num_addrs = (len(opt) - 8) // 16
    if num_addrs < 1:
        fail("RDNSS option carries no addresses")
        return
    addr = socket.inet_ntop(socket.AF_INET6, opt[8:24])
    expected = nb_ra.rdnss_address(PREFIX)
    if addr != expected:
        fail(f"expected RDNSS server {expected}, got {addr}")


def test_slla(pkt):
    """check the source link-layer address option"""
    opt = find_option(pkt, nb_ra.ND_OPT_SLLA)
    if opt is None:
        fail("no Source Link-Layer Address option found")
        return
    if opt[2:8] != MAC:
        fail(f"expected mac {MAC.hex()}, got {opt[2:8].hex()}")


def test_length_alignment(pkt):
    """check the packet length alignment"""
    if len(pkt) % 8 != 0:
        fail(f"total RA length {len(pkt)} is not a whole number of 8-octet units")


def test_filter():
    """check that the ICMPv6 filter passes only the wanted type"""
    filt = nb_ra.build_icmp6_filter([nb_ra.ICMPV6_RS])
    if not nb_ra.filter_will_pass(filt, nb_ra.ICMPV6_RS):
        fail("a filter built for RS-only blocks type 133")
    if nb_ra.filter_will_pass(filt, nb_ra.ICMPV6_RA):
        fail("a filter built for RS-only passes type 134")


def eth_frame(payload, ethertype):
    """build an Ethernet frame with a payload"""
    return b"\x33\x33\x00\x00\x00\x01" + b"\x02\x00\x00\x00\x00\x01" + \
        struct.pack(">H", ethertype) + payload


def ipv6_frame(payload, nxt, src, dst):
    """build an IPv6 frame with a payload"""
    def addr(s):
        """pack an IPv6 address"""
        return socket.inet_pton(socket.AF_INET6, s)
    return struct.pack(">IHBB", 6 << 28, len(payload), nxt, 255) + \
        addr(src) + addr(dst) + payload


def write_pcap(path, frames):
    """write frames to a pcap file"""
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1))
        for i, fr in enumerate(frames):
            f.write(struct.pack("<IIII", 1700000000 + i, 0, len(fr), len(fr)))
            f.write(fr)


def test_pcapstat_cross_check(pkt, d):
    """check the packet against pcapstat output"""
    if not os.path.exists(PCAPSTAT):
        fail(f"pcapstat.py not found at {PCAPSTAT}")
        return
    frame = eth_frame(ipv6_frame(pkt, 58, "fe80::1", "ff02::1"), 0x86DD)
    path = os.path.join(d, "ra.pcap")
    write_pcap(path, [frame])
    r = subprocess.run([sys.executable, PCAPSTAT, path, "--ra", "--json"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        fail(f"pcapstat.py exited {r.returncode} on a built RA: {r.stderr}")
        return
    try:
        out = json.loads(r.stdout)
    except ValueError as e:
        fail(f"pcapstat.py did not print valid json: {e}, got:\n{r.stdout}")
        return
    ras = out.get("ra", [])
    if len(ras) != 1:
        fail(f"pcapstat.py found {len(ras)} router advertisements, expected 1")
        return
    ra = ras[0]
    if ra.get("router_lifetime") != ROUTER_LIFETIME:
        fail(f"pcapstat.py read router_lifetime={ra.get('router_lifetime')}, "
             f"expected {ROUTER_LIFETIME}")
    prefixes = ra.get("prefixes", [])
    if not prefixes or prefixes[0].get("prefix") != PREFIX or prefixes[0].get("len") != 64:
        fail(f"pcapstat.py did not read back the prefix correctly: {prefixes}")
    if nb_ra.rdnss_address(PREFIX) not in ra.get("rdnss", []):
        fail(f"pcapstat.py did not read back the RDNSS server: {ra.get('rdnss')}")
    if ra.get("mtu") != MTU:
        fail(f"pcapstat.py read mtu={ra.get('mtu')}, expected {MTU}")


def run_all(d):
    """run every check and collect the failures"""
    FAILURES.clear()
    pkt = nb_ra.build_ra(PREFIX, MAC, MTU, ROUTER_LIFETIME, VALID_LIFETIME,
                         PREFERRED_LIFETIME, RDNSS_LIFETIME)
    test_header(pkt)
    test_prefix_info(pkt)
    test_rdnss(pkt)
    test_slla(pkt)
    test_length_alignment(pkt)
    test_filter()
    test_pcapstat_cross_check(pkt, d)
    return list(FAILURES)


def run_all_broken():
    """run the flags test with zero flags"""
    real_flags = nb_ra.PIO_ON_LINK_AUTONOMOUS
    nb_ra.PIO_ON_LINK_AUTONOMOUS = 0
    try:
        FAILURES.clear()
        pkt = nb_ra.build_ra(PREFIX, MAC, MTU, ROUTER_LIFETIME, VALID_LIFETIME,
                             PREFERRED_LIFETIME, RDNSS_LIFETIME)
        test_prefix_info(pkt)
        return list(FAILURES)
    finally:
        nb_ra.PIO_ON_LINK_AUTONOMOUS = real_flags


def main():
    """run the router advertisement checks"""
    selftest = "--selftest" in sys.argv
    if selftest:
        broken = run_all_broken()
        if not broken:
            print("FAIL: zeroing the Prefix Information flags did not make any "
                  "assertion fail", file=sys.stderr)
            return 1
        print(f"selftest_ra: selftest ok -- {len(broken)} assertion(s) caught "
              "the broken run")
        return 0

    with tempfile.TemporaryDirectory() as d:
        problems = run_all(d)
    for msg in problems:
        print(f"FAIL: {msg}", file=sys.stderr)
    if problems:
        print("selftest_ra: nb_ra.py does not build what it claims to", file=sys.stderr)
        return 1
    print("selftest_ra: the built RA decodes correctly and pcapstat.py agrees")
    return 0


if __name__ == "__main__":
    sys.exit(main())
