#!/usr/bin/env python3
import argparse
import json
import struct
import sys

ETH_P_IP = 0x0800
ETH_P_IPV6 = 0x86DD
ETH_P_VLAN = 0x8100

PCAP_MAGICS = {
    0xA1B2C3D4: ("<", 1_000_000),
    0xD4C3B2A1: (">", 1_000_000),
    0xA1B23C4D: ("<", 1_000_000_000),
    0x4D3CB2A1: (">", 1_000_000_000),
}


class Packet:
    __slots__ = ("ts", "caplen", "wirelen", "ipver", "src", "dst", "proto",
                 "sport", "dport", "payload", "icmp6_type", "raw")

    def __init__(self):
        """start an empty packet record"""
        self.ts = 0.0
        self.caplen = self.wirelen = 0
        self.ipver = None
        self.src = self.dst = None
        self.proto = None
        self.sport = self.dport = None
        self.payload = b""
        self.icmp6_type = None
        self.raw = b""


def ip4(b):
    """format four bytes as a dotted IPv4 address"""
    return ".".join(str(x) for x in b)


def ip6(b):
    """convert 16 bytes to IPv6 text"""
    parts = [f"{b[i] << 8 | b[i + 1]:x}" for i in range(0, 16, 2)]
    best_i = best_n = cur_i = cur_n = -1
    for i, p in enumerate(parts + ["x"]):
        if p == "0":
            if cur_i < 0:
                cur_i, cur_n = i, 0
            cur_n += 1
        else:
            if cur_n > best_n:
                best_i, best_n = cur_i, cur_n
            cur_i = cur_n = -1
    if best_n > 1:
        return ":".join(parts[:best_i]) + "::" + ":".join(parts[best_i + best_n:])
    return ":".join(parts)


def parse_transport(pkt, proto, data):
    """parse the transport header into the packet"""
    pkt.proto = {6: "tcp", 17: "udp", 1: "icmp", 58: "icmp6"}.get(proto, str(proto))
    if proto in (6, 17) and len(data) >= 4:
        pkt.sport, pkt.dport = struct.unpack(">HH", data[:4])
        if proto == 17 and len(data) >= 8:
            pkt.payload = data[8:]
        elif proto == 6 and len(data) >= 20:
            off = (data[12] >> 4) * 4
            pkt.payload = data[off:] if len(data) >= off else b""
    elif proto == 58 and data:
        pkt.icmp6_type = data[0]
        pkt.payload = data


def parse_ip(pkt, ethertype, data):
    """parse the IP header into the packet"""
    if ethertype == ETH_P_IP and len(data) >= 20:
        pkt.ipver = 4
        ihl = (data[0] & 0x0F) * 4
        pkt.src, pkt.dst = ip4(data[12:16]), ip4(data[16:20])
        parse_transport(pkt, data[9], data[ihl:])
    elif ethertype == ETH_P_IPV6 and len(data) >= 40:
        pkt.ipver = 6
        pkt.src, pkt.dst = ip6(data[8:24]), ip6(data[24:40])
        nxt, off = data[6], 40
        for _ in range(8):
            if nxt in (0, 43, 60) and len(data) >= off + 8:
                nxt, off = data[off], off + (data[off + 1] + 1) * 8
                continue
            break
        parse_transport(pkt, nxt, data[off:])


def read_pcap(path):
    """read the packets from a pcap file"""
    with open(path, "rb") as f:
        hdr = f.read(24)
        if len(hdr) < 24:
            raise ValueError(f"{path}: too short to be a pcap ({len(hdr)} bytes)")
        magic = struct.unpack("<I", hdr[:4])[0]
        if magic not in PCAP_MAGICS:
            magic_be = struct.unpack(">I", hdr[:4])[0]
            if magic_be not in PCAP_MAGICS:
                raise ValueError(f"{path}: not a classic pcap (magic {magic:#x})")
            magic = magic_be
        endian, divisor = PCAP_MAGICS[magic]
        linktype = struct.unpack(endian + "I", hdr[20:24])[0]
        while True:
            rh = f.read(16)
            if len(rh) < 16:
                break
            ts_s, ts_frac, caplen, wirelen = struct.unpack(endian + "IIII", rh)
            data = f.read(caplen)
            if len(data) < caplen:
                break
            pkt = Packet()
            pkt.ts = ts_s + ts_frac / divisor
            pkt.caplen, pkt.wirelen, pkt.raw = caplen, wirelen, data
            if linktype == 1 and len(data) >= 14:
                et = struct.unpack(">H", data[12:14])[0]
                body = data[14:]
                if et == ETH_P_VLAN and len(body) >= 4:
                    et = struct.unpack(">H", body[2:4])[0]
                    body = body[4:]
                parse_ip(pkt, et, body)
            elif linktype == 101 and data:
                parse_ip(pkt, ETH_P_IP if data[0] >> 4 == 4 else ETH_P_IPV6, data)
            yield pkt


def dns_name(buf, pos):
    """decode a DNS name from the buffer"""
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


TYPES = {1: "A", 2: "NS", 5: "CNAME", 12: "PTR", 16: "TXT", 28: "AAAA",
         33: "SRV", 41: "OPT", 255: "ANY"}
RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 5: "REFUSED"}


def parse_dns(buf):
    """parse a DNS message"""
    if len(buf) < 12:
        return None
    tid, flags, qd, an = struct.unpack(">HHHH", buf[:8])
    ns, ar = struct.unpack(">HH", buf[8:12])
    rec = {"id": tid, "qr": (flags >> 15) & 1, "rcode": RCODES.get(flags & 0xF, flags & 0xF),
           "questions": [], "answers": []}
    pos = 12
    for _ in range(qd):
        name, pos2 = dns_name(buf, pos)
        if name is None or pos2 is None or pos2 + 4 > len(buf):
            rec["truncated"] = True
            return rec
        qtype, _qclass = struct.unpack(">HH", buf[pos2:pos2 + 4])
        rec["questions"].append({"name": name, "type": TYPES.get(qtype, qtype)})
        pos = pos2 + 4
    for _ in range(an):
        name, pos2 = dns_name(buf, pos)
        if name is None or pos2 is None or pos2 + 10 > len(buf):
            rec["truncated"] = True
            return rec
        rtype, _rc, _ttl, rdlen = struct.unpack(">HHIH", buf[pos2:pos2 + 10])
        rdata = buf[pos2 + 10:pos2 + 10 + rdlen]
        val = None
        if rtype == 1 and rdlen == 4:
            val = ip4(rdata)
        elif rtype == 28 and rdlen == 16:
            val = ip6(rdata)
        elif rtype in (12, 5, 2):
            val, _ = dns_name(buf, pos2 + 10)
        elif rtype == 33 and rdlen > 6:
            val, _ = dns_name(buf, pos2 + 16)
        rec["answers"].append({"name": name, "type": TYPES.get(rtype, rtype), "data": val})
        pos = pos2 + 10 + rdlen
    return rec


def parse_ra(payload):
    """parse an ICMPv6 router advertisement"""
    if len(payload) < 16 or payload[0] != 134:
        return None
    out = {"hoplimit": payload[4], "flags": payload[5],
           "router_lifetime": struct.unpack(">H", payload[6:8])[0],
           "prefixes": [], "rdnss": [], "mtu": None}
    pos = 16
    while pos + 8 <= len(payload):
        otype, olen8 = payload[pos], payload[pos + 1]
        if olen8 == 0:
            break
        olen = olen8 * 8
        opt = payload[pos:pos + olen]
        if otype == 3 and len(opt) >= 32:
            out["prefixes"].append({"prefix": ip6(opt[16:32]), "len": opt[2],
                                    "flags": opt[3],
                                    "valid": struct.unpack(">I", opt[4:8])[0],
                                    "preferred": struct.unpack(">I", opt[8:12])[0]})
        elif otype == 5 and len(opt) >= 8:
            out["mtu"] = struct.unpack(">I", opt[4:8])[0]
        elif otype == 25 and len(opt) >= 24:
            for i in range(8, len(opt) - 15, 16):
                out["rdnss"].append(ip6(opt[i:i + 16]))
        pos += olen
    return out


def matches(p, a):
    """return whether a packet passes the command line filters"""
    if a.v4 and p.ipver != 4:
        return False
    if a.v6 and p.ipver != 6:
        return False
    if a.proto and p.proto != a.proto:
        return False
    if a.port is not None and a.port not in (p.sport, p.dport):
        return False
    if a.host and a.host not in (p.src, p.dst):
        return False
    return True


def main():
    """print the packet summary"""
    ap = argparse.ArgumentParser()
    ap.add_argument("pcap")
    ap.add_argument("--summary", action="store_true")
    ap.add_argument("--flows", action="store_true")
    ap.add_argument("--dns", action="store_true")
    ap.add_argument("--mdns", action="store_true")
    ap.add_argument("--ra", action="store_true")
    ap.add_argument("--proto")
    ap.add_argument("--port", type=int)
    ap.add_argument("--host")
    ap.add_argument("--v4", action="store_true")
    ap.add_argument("--v6", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if not (a.summary or a.flows or a.dns or a.mdns or a.ra):
        a.summary = True

    try:
        pkts = [p for p in read_pcap(a.pcap) if matches(p, a)]
    except (OSError, ValueError) as e:
        print(f"pcapstat: {e}", file=sys.stderr)
        return 2

    out = {"file": a.pcap, "packets": len(pkts)}
    if a.summary:
        out["v4"] = sum(1 for p in pkts if p.ipver == 4)
        out["v6"] = sum(1 for p in pkts if p.ipver == 6)
        out["bytes"] = sum(p.wirelen for p in pkts)
        by = {}
        for p in pkts:
            by[p.proto or "none"] = by.get(p.proto or "none", 0) + 1
        out["by_proto"] = by
        if pkts:
            out["first_ts"] = round(pkts[0].ts, 6)
            out["last_ts"] = round(pkts[-1].ts, 6)
    if a.flows:
        flows = {}
        for p in pkts:
            k = f"{p.proto}|{p.src}:{p.sport}|{p.dst}:{p.dport}"
            f = flows.setdefault(k, {"packets": 0, "bytes": 0})
            f["packets"] += 1
            f["bytes"] += p.wirelen
        out["flows"] = flows
    if a.dns or a.mdns:
        want = 5353 if a.mdns and not a.dns else 53
        recs = []
        for p in pkts:
            if p.proto != "udp" or want not in (p.sport, p.dport):
                continue
            r = parse_dns(p.payload)
            if r is None:
                continue
            r["src"], r["dst"], r["ts"] = p.src, p.dst, round(p.ts, 6)
            recs.append(r)
        out["mdns" if (a.mdns and not a.dns) else "dns"] = recs
    if a.ra:
        ras = []
        for p in pkts:
            if p.proto != "icmp6":
                continue
            r = parse_ra(p.payload)
            if r:
                r["src"], r["dst"], r["ts"] = p.src, p.dst, round(p.ts, 6)
                ras.append(r)
        out["ra"] = ras

    if a.json:
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0
    for k, v in out.items():
        if isinstance(v, dict) and k == "by_proto":
            print(f"{k}=" + ",".join(f"{kk}:{vv}" for kk, vv in sorted(v.items())))
        elif isinstance(v, dict):
            print(f"{k}_count={len(v)}")
            for kk, vv in sorted(v.items()):
                print(f"  {kk} packets={vv['packets']} bytes={vv['bytes']}")
        elif isinstance(v, list):
            print(f"{k}_count={len(v)}")
            for item in v:
                print("  " + json.dumps(item, sort_keys=True))
        else:
            print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
