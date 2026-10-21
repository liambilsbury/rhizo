import hashlib
import socket
import struct

from nb_common import Service, log, monotonic, sanitize_for_log

MDNS_PORT = 5353
MDNS_GROUP4 = "224.0.0.251"
MDNS_GROUP6 = "ff02::fb"
DEDUPE_WINDOW = 1.0
IF_INET6_PATH = "/proc/net/if_inet6"
IPV6_SCOPE_GLOBAL = 0x00
SIDES = ("veth", "uplink")

MAX_SEEN = 4096
RATE_LIMIT_PER_SEC = 50
MAX_MDNS_MESSAGE = 9000


def other_side(side):
    """return the opposite side name"""
    return "uplink" if side == "veth" else "veth"


def digest(payload):
    """return the SHA-1 digest of a payload"""
    return hashlib.sha1(payload).digest()


def should_relay(seen, payload_digest, mono, window=DEDUPE_WINDOW):
    """check the payload digest against recent relays"""
    last = seen.get(payload_digest)
    return last is None or mono - last >= window


def expire_seen(seen, mono, window=DEDUPE_WINDOW, max_seen=MAX_SEEN):
    """remove old entries from the seen table"""
    for d in [k for k, t in seen.items() if mono - t >= window]:
        del seen[d]
    if len(seen) > max_seen:
        for d, _t in sorted(seen.items(), key=lambda kv: kv[1])[:len(seen) - max_seen]:
            del seen[d]


class _RateLimiter:
    """Per-second packet rate limit"""

    def __init__(self, limit_per_sec=RATE_LIMIT_PER_SEC):
        """set the per-second packet limit and an empty window"""
        self.limit = limit_per_sec
        self._window_start = 0.0
        self._count = 0

    def allow(self, mono):
        """count a packet against the per-second limit"""
        if mono - self._window_start >= 1.0:
            self._window_start = mono
            self._count = 0
        self._count += 1
        return self._count <= self.limit


def _skip_question(buf, pos):
    """return the position after a question, or None if truncated"""
    name, pos = dns_name(buf, pos)
    if name is None or pos + 4 > len(buf):
        return None
    return pos + 4


def _skip_rr(buf, pos):
    """return the position after a resource record, or None if truncated"""
    name, pos = dns_name(buf, pos)
    if name is None or pos + 10 > len(buf):
        return None
    rdlen = struct.unpack(">H", buf[pos + 8:pos + 10])[0]
    pos += 10
    if pos + rdlen > len(buf):
        return None
    return pos + rdlen


def is_valid_message(data, max_len=MAX_MDNS_MESSAGE):
    """check the DNS message framing"""
    if not (12 <= len(data) <= max_len):
        return False
    qd, an, ns, ar = struct.unpack(">HHHH", data[4:12])
    if qd > 64 or an > 64 or ns > 64 or ar > 64:
        return False
    pos = 12
    for _ in range(qd):
        pos = _skip_question(data, pos)
        if pos is None:
            return False
    for _ in range(an + ns + ar):
        pos = _skip_rr(data, pos)
        if pos is None:
            return False
    return pos <= len(data)


def relay_step(seen, mono, side, data, senders):
    """relay the data to the other side"""
    d = digest(data)
    if not should_relay(seen, d, mono):
        return "drop", "loop"
    peer = other_side(side)
    send = senders.get(peer)
    if send is None:
        return "drop", "no_peer"
    send(data)
    seen[d] = mono
    return "relay", None


def dns_name(buf, pos):
    """decode the domain name at pos"""
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


def first_dns_name(data):
    """return the first name in the message"""
    if len(data) < 12:
        return None
    _id, _flags, qd, an, _ns, _ar = struct.unpack(">HHHHHH", data[:12])
    if qd == 0 and an == 0:
        return None
    name, _next_pos = dns_name(data, 12)
    return name


def qname_or_dash(data):
    """return the first name of a message, or a dash"""
    return first_dns_name(data) or "-"


def has_global_ipv6(ifname, path=IF_INET6_PATH):
    """check ifname for a global IPv6 address"""
    try:
        with open(path) as f:
            lines = f.readlines()
    except OSError as e:
        log("NB_MDNS_FAIL reason=if_inet6_read path=%s error=%s", path, e)
        return False
    for line in lines:
        parts = line.split()
        if len(parts) != 6:
            continue
        _addr, _idx, _plen, scope_hex, _flags, devname = parts
        if devname != ifname:
            continue
        try:
            scope = int(scope_hex, 16)
        except ValueError:
            log("NB_MDNS_FAIL reason=if_inet6_scope path=%s line=%s", path, line.rstrip())
            continue
        if scope == IPV6_SCOPE_GLOBAL:
            return True
    return False


def _mreqn(multiaddr_bytes, ifindex):
    """build an ip_mreqn struct for ifindex"""
    return struct.pack("=4s4si", multiaddr_bytes, b"\x00\x00\x00\x00", ifindex)


def open_v4_socket(ifname):
    """open an mDNS IPv4 socket bound to an interface"""
    ifindex = socket.if_nametoindex(ifname)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, ifname.encode())
    s.bind(("", MDNS_PORT))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
                _mreqn(socket.inet_aton(MDNS_GROUP4), ifindex))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                _mreqn(b"\x00\x00\x00\x00", ifindex))
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 0)
    s.setblocking(False)
    return s, ifindex


def open_v6_socket(ifname):
    """open an mDNS IPv6 socket bound to an interface"""
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
    s.setblocking(False)
    return s, ifindex


class MdnsService(Service):
    name = "mdns"

    def __init__(self, cfg):
        """store the interface names and empty socket tables"""
        self.cfg = cfg
        self.veth_if = cfg.veth_if
        self.uplink_if = cfg.mdns_uplink_if or cfg.uplink
        self._socks = {}
        self._ifindex = {}
        self._by_fd = {}
        self._seen = {}
        self._rate = {side: _RateLimiter() for side in SIDES}
        self._open_v4()
        self._check_v6()

    def _iface(self, side):
        """return the interface name of a side"""
        return self.veth_if if side == "veth" else self.uplink_if

    def _open_one(self, side, family, opener):
        """open a socket for a side and family"""
        ifname = self._iface(side)
        try:
            sock, ifindex = opener(ifname)
        except OSError as e:
            log("NB_MDNS_FAIL reason=socket side=%s family=%d if=%s errno=%s error=%s",
                side, family, ifname, getattr(e, "errno", None), e)
            return
        self._socks[(side, family)] = sock
        self._ifindex[(side, family)] = ifindex
        self._by_fd[sock.fileno()] = (side, family)

    def _open_v4(self):
        """open the IPv4 socket on each side"""
        for side in SIDES:
            self._open_one(side, 4, open_v4_socket)
        if ("veth", 4) in self._socks and ("uplink", 4) in self._socks:
            log("NB_MDNS_UP veth=%s uplink=%s family=4", self.veth_if, self.uplink_if)

    def _check_v6(self):
        """open the IPv6 socket on each side with a global address"""
        for side in SIDES:
            if (side, 6) in self._socks:
                continue
            if not has_global_ipv6(self._iface(side)):
                continue
            self._open_one(side, 6, open_v6_socket)
            if (side, 6) in self._socks:
                log("NB_MDNS_UP veth=%s uplink=%s family=6", self.veth_if, self.uplink_if)

    def sockets(self):
        """return the open sockets"""
        return list(self._socks.values())

    def unhealthy(self):
        """report missing v4 sockets"""
        missing = [s for s in SIDES if (s, 4) not in self._socks]
        if missing:
            return "no v4 socket on %s (%s)" % (
                ", ".join(missing),
                ", ".join("%s=%s" % (s, self._iface(s)) for s in missing))
        return ""

    def on_readable(self, sock):
        """relay a datagram from a socket to the other side"""
        meta = self._by_fd.get(sock.fileno())
        if meta is None:
            log("NB_MDNS_FAIL reason=unregistered_socket")
            return
        side, family = meta
        try:
            data, _addr = sock.recvfrom(65536)
        except OSError as e:
            log("NB_MDNS_FAIL reason=recv side=%s errno=%s error=%s",
                side, getattr(e, "errno", None), e)
            return
        self._relay(side, family, data)

    def _dest(self, side, family):
        """return the multicast destination for a family and side"""
        if family == 4:
            return MDNS_GROUP4, MDNS_PORT
        return MDNS_GROUP6, MDNS_PORT, 0, self._ifindex[(side, 6)]

    def _relay(self, side, family, data):
        """relay a datagram to the other side"""
        mono = monotonic()
        if not self._rate[side].allow(mono):
            log("NB_MDNS_DROP reason=rate_limited side=%s bytes=%d", side, len(data))
            return
        if not is_valid_message(data):
            log("NB_MDNS_DROP reason=malformed side=%s bytes=%d", side, len(data))
            return
        peer = other_side(side)
        target = self._socks.get((peer, family))
        senders = {}
        if target is not None:
            dest = self._dest(peer, family)
            senders[peer] = lambda payload: target.sendto(payload, dest)
        try:
            action, reason = relay_step(self._seen, mono, side, data, senders)
        except OSError as e:
            log("NB_MDNS_FAIL reason=send side=%s errno=%s error=%s",
                peer, getattr(e, "errno", None), e)
            return
        if action == "drop":
            log("NB_MDNS_DROP reason=%s bytes=%d", reason, len(data))
            return
        log("NB_MDNS_RELAY from=%s to=%s bytes=%d qname=%s family=%d",
            self._iface(side), self._iface(peer), len(data),
            sanitize_for_log(qname_or_dash(data)), family)

    def next_tick(self, now_mono):
        """return the next tick time"""
        return now_mono + 1.0

    def tick(self, now_mono):
        """expire seen entries and check for IPv6 sockets to open"""
        expire_seen(self._seen, now_mono)
        self._check_v6()
