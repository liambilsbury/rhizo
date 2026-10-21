#!/usr/bin/env python3
import os
import struct
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
PCAPSTAT = os.path.join(TOOLS, "..", "..", "..", "system", "tools", "pcapstat.py")

FAILURES = []


def fail(msg):
    """record a failure message"""
    FAILURES.append(msg)


def eth(payload, ethertype):
    """return an ethernet frame with the given ethertype and payload"""
    return b"\x02\x00\x00\x00\x00\x01" + b"\x02\x00\x00\x00\x00\x02" + \
        struct.pack(">H", ethertype) + payload


def ipv4(payload, proto, src, dst):
    """return an IPv4 packet"""
    def a(s):
        """return the four bytes of a dotted address"""
        return bytes(int(x) for x in s.split("."))
    hdr = struct.pack(">BBHHHBBH", 0x45, 0, 20 + len(payload), 0, 0, 64, proto, 0)
    return hdr + a(src) + a(dst) + payload


def ipv6(payload, nxt, src, dst):
    """return an IPv6 packet"""
    def a(s):
        """return the sixteen bytes of an IPv6 address"""
        parts = s.split("::")
        head = parts[0].split(":") if parts[0] else []
        tail = parts[1].split(":") if len(parts) > 1 and parts[1] else []
        mid = ["0"] * (8 - len(head) - len(tail))
        return b"".join(struct.pack(">H", int(x, 16)) for x in head + mid + tail)
    return struct.pack(">IHBB", 6 << 28, len(payload), nxt, 255) + a(src) + a(dst) + payload


def udp(payload, sport, dport):
    """return a UDP datagram with the given payload and ports"""
    return struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload


def qname(name):
    """return a DNS name encoded as length-prefixed labels"""
    out = b""
    for label in name.split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def dns_query(name, qtype=1, tid=0x1234):
    """return a DNS query payload for a name and type"""
    return struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0) + qname(name) + \
        struct.pack(">HH", qtype, 1)


def dns_answer_a(name, ip, tid=0x1234):
    """return a DNS answer payload giving an A record for a name"""
    def a(s):
        """return the four bytes of a dotted address"""
        return bytes(int(x) for x in s.split("."))
    body = struct.pack(">HHHHHH", tid, 0x8180, 1, 1, 0, 0) + qname(name) + \
        struct.pack(">HH", 1, 1)
    body += b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + a(ip)
    return body


def icmp6_ra(prefix_hi, rdnss_hi):
    """build an ICMPv6 router advertisement body"""
    body = struct.pack(">BBHBBHII", 134, 0, 0, 64, 0, 1800, 0, 0)
    pio = struct.pack(">BBBBIII", 3, 4, 64, 0xC0, 2592000, 604800, 0) + \
        struct.pack(">8H", prefix_hi, 0, 0, 0, 0, 0, 0, 0)
    rdnss = struct.pack(">BBHI", 25, 3, 0, 1800) + \
        struct.pack(">8H", rdnss_hi, 0, 0, 0, 0, 0, 0, 1)
    return body + pio + rdnss


def write_pcap(path, frames):
    """write frames to a pcap file"""
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 262144, 1))
        for i, fr in enumerate(frames):
            f.write(struct.pack("<IIII", 1700000000 + i, 0, len(fr), len(fr)))
            f.write(fr)


def run(path, *args):
    """run pcapstat on a file and return its exit code and output"""
    r = subprocess.run([sys.executable, PCAPSTAT, path, *args],
                       capture_output=True, text=True)
    return r.returncode, r.stdout


def full_fixture():
    """return the frames of the full capture fixture"""
    return [
            eth(ipv4(udp(dns_query("rhizo-test.internal"), 40000, 53),
                     17, "192.168.100.73", "192.168.100.1"), 0x0800),
            eth(ipv4(udp(dns_answer_a("rhizo-test.internal", "192.168.100.1"), 53, 40000),
                     17, "192.168.100.1", "192.168.100.73"), 0x0800),
            eth(ipv4(udp(dns_query("_rhizotest._tcp.local", 12), 5353, 5353),
                     17, "192.168.100.73", "224.0.0.251"), 0x0800),
            eth(ipv6(icmp6_ra(0xFD00, 0xFD00), 58, "fe80::1", "ff02::1"), 0x86DD),
        eth(ipv4(struct.pack(">HHIIBBHHH", 1234, 80, 0, 0, 5 << 4, 0x02, 0, 0, 0),
                 6, "192.168.100.73", "192.168.100.1"), 0x0800),
    ]


def verify(d, frames):
    """run the assertions against a pcap of frames"""
    FAILURES.clear()
    good = os.path.join(d, "fixture.pcap")
    write_pcap(good, frames)
    if True:
        rc, out = run(good, "--summary")
        if rc != 0:
            fail(f"--summary exited {rc}")
        for w in ["packets=5", "v4=4", "v6=1"]:
            if w not in out:
                fail(f"--summary missing {w!r}; got:\n{out}")

        rc, out = run(good, "--dns")
        if "rhizo-test.internal" not in out:
            fail(f"--dns did not report the queried name; got:\n{out}")
        if '"data": "192.168.100.1"' not in out:
            fail(f"--dns did not decode the A record; got:\n{out}")
        if '"type": "A"' not in out:
            fail(f"--dns did not report the record type; got:\n{out}")

        rc, out = run(good, "--mdns")
        if "_rhizotest._tcp.local" not in out:
            fail(f"--mdns did not report the mDNS question; got:\n{out}")
        if "mdns_count=1" not in out:
            fail(f"--mdns counted the wrong number of records; got:\n{out}")

        rc, out = run(good, "--ra")
        if "ra_count=1" not in out:
            fail(f"--ra did not find the router advertisement; got:\n{out}")
        if '"prefix": "fd00::"' not in out:
            fail(f"--ra did not decode the prefix; got:\n{out}")
        if '"rdnss": [\n' not in out and "fd00::1" not in out:
            fail(f"--ra did not decode the RDNSS server; got:\n{out}")

        rc, out = run(good, "--flows", "--proto", "tcp")
        if "flows_count=1" not in out:
            fail(f"--flows --proto tcp should isolate one flow; got:\n{out}")

        rc, out = run(good, "--summary", "--v6")
        if "packets=1" not in out:
            fail(f"--v6 should select exactly the one IPv6 frame; got:\n{out}")

    return list(FAILURES)


def main():
    """run the pcapstat fixture checks"""
    selftest = "--selftest" in sys.argv
    with tempfile.TemporaryDirectory() as d:
        frames = full_fixture()
        problems = verify(d, frames)

        degraded = verify(d, [frames[0], frames[2], frames[4]])
        if not degraded:
            print("FAIL: the assertions passed against a fixture missing the DNS "
                  "answer and the RA",
                  file=sys.stderr)
            return 1
        if selftest:
            print(f"check-pcapstat: selftest ok -- {len(degraded)} assertion(s) "
                  "caught the degraded fixture")
            return 0
        for msg in problems:
            print(f"FAIL: {msg}", file=sys.stderr)
        if problems:
            print("check-pcapstat: pcapstat.py does not read what it claims to",
                  file=sys.stderr)
            return 1

        bad = os.path.join(d, "truncated.pcap")
        q = struct.pack(">HHHHHH", 1, 0x0100, 1, 0, 0, 0) + b"\x3frhizo"
        write_pcap(bad, [eth(ipv4(udp(q, 40000, 53), 17, "10.0.0.1", "10.0.0.2"), 0x0800)])
        rc, out = run(bad, "--dns")
        if rc != 0:
            print(f"FAIL: --dns on a truncated name exited {rc}", file=sys.stderr)
            return 1
        if "rhizo" in out and '"truncated": true' not in out:
            print(f"FAIL: --dns invented a name from a truncated question:\n{out}",
                  file=sys.stderr)
            return 1

        junk = os.path.join(d, "junk.pcap")
        with open(junk, "wb") as f:
            f.write(b"this is not a pcap file at all, not even close")
        rc, out = run(junk, "--summary")
        if rc == 0:
            print("FAIL: a non-pcap file was accepted instead of refused",
                  file=sys.stderr)
            return 1

    print("check-pcapstat: pcapstat.py reads every fixture and refuses every bad one")
    return 0


if __name__ == "__main__":
    sys.exit(main())
