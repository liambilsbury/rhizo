import random
import socket
import struct

from nb_common import Service, log, monotonic

ICMPV6_RS = 133
ICMPV6_RA = 134
ND_OPT_SLLA = 1
ND_OPT_PREFIX_INFO = 3
ND_OPT_MTU = 5
ND_OPT_RDNSS = 25
ICMP6_FILTER = 1
PIO_ON_LINK_AUTONOMOUS = 0xC0
ALL_ROUTERS = "ff02::1"
MAX_SOLICITED_DELAY = 0.5

DEFAULT_ROUTER_LIFETIME = 1800
DEFAULT_VALID_LIFETIME = 2592000
DEFAULT_PREFERRED_LIFETIME = 604800


def rdnss_address(prefix):
    """return the DNS server address within a prefix"""
    return prefix + "1"


def _ra_header(router_lifetime):
    """build the router advertisement header"""
    return struct.pack(">BBHBBHII", ICMPV6_RA, 0, 0, 64, 0, router_lifetime, 0, 0)


def _prefix_info_option(prefix, prefix_len, valid_lifetime, preferred_lifetime):
    """build a prefix information option"""
    addr = socket.inet_pton(socket.AF_INET6, prefix)
    return struct.pack(">BBBBIII", ND_OPT_PREFIX_INFO, 4, prefix_len,
                        PIO_ON_LINK_AUTONOMOUS, valid_lifetime, preferred_lifetime,
                        0) + addr


def _slla_option(mac):
    """build a source link-layer address option"""
    if len(mac) != 6:
        raise ValueError(f"source link-layer address must be 6 bytes, got {len(mac)}")
    return struct.pack(">BB", ND_OPT_SLLA, 1) + mac


def _mtu_option(mtu):
    """build an MTU option"""
    return struct.pack(">BBHI", ND_OPT_MTU, 1, 0, mtu)


def _rdnss_option(addrs, lifetime):
    """build a recursive DNS server option"""
    length_units = 1 + 2 * len(addrs)
    out = struct.pack(">BBHI", ND_OPT_RDNSS, length_units, 0, lifetime)
    for a in addrs:
        out += socket.inet_pton(socket.AF_INET6, a)
    return out


def build_ra(prefix, mac, mtu, router_lifetime, valid_lifetime, preferred_lifetime,
             rdnss_lifetime):
    """build a router advertisement packet"""
    header = _ra_header(router_lifetime)
    pio = _prefix_info_option(prefix, 64, valid_lifetime, preferred_lifetime)
    slla = _slla_option(mac)
    mtu_opt = _mtu_option(mtu)
    rdnss = _rdnss_option([rdnss_address(prefix)], rdnss_lifetime)
    return header + pio + slla + mtu_opt + rdnss


def build_icmp6_filter(pass_types):
    """pack an icmp6_filter from the type list"""
    words = [0xFFFFFFFF] * 8
    for t in pass_types:
        words[t >> 5] &= ~(1 << (t & 31)) & 0xFFFFFFFF
    return struct.pack("@8I", *words)


def filter_will_pass(filt, icmp_type):
    """evaluate an icmp6_filter for a type"""
    words = struct.unpack("@8I", filt)
    return (words[icmp_type >> 5] & (1 << (icmp_type & 31))) == 0


def _read_sysfs(iface, attr):
    """read an attribute of a network interface from sysfs"""
    with open(f"/sys/class/net/{iface}/{attr}") as f:
        return f.read().strip()


class RaService(Service):
    name = "ra"

    def __init__(self, cfg):
        """store the config and read the interface address and MTU"""
        self.cfg = cfg
        self.ra_interval = getattr(cfg, "ra_interval", 20)
        self.dns_addr = rdnss_address(cfg.ula_prefix)
        self.mac, self.mtu = self._read_interface(cfg.veth_if)
        self._sock = None
        self._next_periodic = 0.0
        self._next_solicited = None
        self._sent_once = False

    def _read_interface(self, iface):
        """read the interface address and MTU from sysfs"""
        try:
            mac_text = _read_sysfs(iface, "address")
            mtu_text = _read_sysfs(iface, "mtu")
        except OSError as e:
            log("NB_RA_FAIL reason=sysfs_read:%s", e)
            raise
        try:
            mac = bytes(int(x, 16) for x in mac_text.split(":"))
            mtu = int(mtu_text)
        except ValueError as e:
            log("NB_RA_FAIL reason=sysfs_parse:%s mac=%s mtu=%s", e, mac_text, mtu_text)
            raise
        if len(mac) != 6:
            log("NB_RA_FAIL reason=mac_length:%d", len(mac))
            raise ValueError(f"bad mac length for {iface}: {len(mac)}")
        return mac, mtu

    def sockets(self):
        """return the router advertisement socket"""
        if self._sock is None:
            self._sock = self._open_socket()
        return [self._sock] if self._sock is not None else []

    def unhealthy(self):
        """report a missing ICMPv6 socket"""
        return "" if self.sockets() else "no ICMPv6 socket on %s" % self.cfg.veth_if

    def _open_socket(self):
        """open the ICMPv6 socket on the veth interface"""
        try:
            s = socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                         self.cfg.veth_if.encode())
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_UNICAST_HOPS, 255)
            ifindex = socket.if_nametoindex(self.cfg.veth_if)
            s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF,
                         struct.pack("I", ifindex))
            s.setsockopt(socket.IPPROTO_ICMPV6, ICMP6_FILTER,
                         build_icmp6_filter([ICMPV6_RS]))
            s.setblocking(False)
            return s
        except OSError as e:
            log("NB_RA_FAIL reason=socket:%s if=%s", e, self.cfg.veth_if)
            return None

    def on_host_state(self, state):
        """ignore host state changes"""
        pass

    def on_readable(self, sock):
        """read a router solicitation and schedule an advertisement"""
        try:
            data, addr = sock.recvfrom(128)
        except OSError as e:
            log("NB_RA_FAIL reason=recv:%s", e)
            return
        if not data or data[0] != ICMPV6_RS:
            return
        log("NB_RA_SOLICIT from=%s", addr[0])
        candidate = monotonic() + random.uniform(0, MAX_SOLICITED_DELAY)
        if self._next_solicited is None or candidate < self._next_solicited:
            self._next_solicited = candidate

    def next_tick(self, now):
        """return the earliest time an advertisement is due"""
        deadlines = [self._next_periodic]
        if self._next_solicited is not None:
            deadlines.append(self._next_solicited)
        return min(deadlines)

    def tick(self, now):
        """send the solicited and periodic advertisements that are due"""
        if self._next_solicited is not None and now >= self._next_solicited:
            self._next_solicited = None
            self._send("solicited")
        if now >= self._next_periodic:
            self._send("periodic" if self._sent_once else "startup")
            self._next_periodic = now + self.ra_interval

    def _send(self, reason):
        """build and send a router advertisement"""
        if self._sock is None:
            log("NB_RA_FAIL reason=no_socket")
            return
        rdnss_lifetime = 2 * self.ra_interval
        packet = build_ra(self.cfg.ula_prefix, self.mac, self.mtu,
                          DEFAULT_ROUTER_LIFETIME, DEFAULT_VALID_LIFETIME,
                          DEFAULT_PREFERRED_LIFETIME, rdnss_lifetime)
        try:
            self._sock.sendto(packet, (ALL_ROUTERS, 0, 0, 0))
        except OSError as e:
            log("NB_RA_FAIL reason=send:%s", e)
            return
        self._sent_once = True
        log("NB_RA_SENT dst=%s prefix=%s/64 rdnss=%s lifetime=%d reason=%s",
            ALL_ROUTERS, self.cfg.ula_prefix, self.dns_addr,
            DEFAULT_ROUTER_LIFETIME, reason)
