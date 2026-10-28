import ipaddress
import json
import os
import socket
import struct

from nb_common import Service, log, monotonic, now

BOOTREQUEST = 1
BOOTREPLY = 2
HTYPE_ETHER = 1
HLEN_ETHER = 6
MAGIC_COOKIE = b"\x63\x82\x53\x63"
FLAG_BROADCAST = 0x8000
ZERO_ADDR = b"\x00\x00\x00\x00"

MSG_DISCOVER = 1
MSG_OFFER = 2
MSG_REQUEST = 3
MSG_DECLINE = 4
MSG_ACK = 5
MSG_NAK = 6
MSG_RELEASE = 7
MSG_INFORM = 8

HEADER_FMT = ">BBBBIHH4s4s4s4s16s64s128s4s"
HEADER_LEN = struct.calcsize(HEADER_FMT)


def ip_to_bytes(s):
    """convert a dotted address to 4 bytes"""
    return socket.inet_aton(s)


def ip_to_int(s):
    """convert a dotted address to an integer"""
    return struct.unpack(">I", socket.inet_aton(s))[0]


def int_to_ip(n):
    """convert an integer to a dotted address"""
    return socket.inet_ntoa(struct.pack(">I", n))


def mac_str(b):
    """format a hardware address as colon-separated hex"""
    return ":".join("%02x" % x for x in b)


def parse_options(data):
    """parse DHCP options into a code dictionary"""
    opts = {}
    i, n = 0, len(data)
    while i < n:
        code = data[i]
        i += 1
        if code == 255:
            break
        if code == 0:
            continue
        if i >= n:
            return None
        length = data[i]
        i += 1
        if i + length > n:
            return None
        opts[code] = data[i:i + length]
        i += length
    return opts


def parse_packet(data):
    """parse a BOOTREQUEST into a dictionary"""
    if len(data) < HEADER_LEN:
        return None, "short"
    fields = struct.unpack(HEADER_FMT, data[:HEADER_LEN])
    (op, htype, hlen, _hops, xid, secs, flags, ciaddr, _yiaddr, _siaddr,
     _giaddr, chaddr, _sname, _fname, cookie) = fields
    if cookie != MAGIC_COOKIE:
        return None, "cookie"
    if op != BOOTREQUEST:
        return None, "op"
    if htype != HTYPE_ETHER or hlen != HLEN_ETHER:
        return None, "htype"
    options = parse_options(data[HEADER_LEN:])
    if options is None:
        return None, "options"
    if 53 not in options or len(options[53]) != 1:
        return None, "msgtype"
    return {
        "xid": xid, "secs": secs, "flags": flags,
        "ciaddr": ciaddr, "chaddr": chaddr[:hlen],
        "msg_type": options[53][0],
        "options": options,
    }, None


def build_header(op, xid, flags, ciaddr, yiaddr, chaddr):
    """pack a DHCP header"""
    return struct.pack(HEADER_FMT, op, HTYPE_ETHER, len(chaddr), 0, xid, 0, flags,
                        ip_to_bytes(ciaddr), ip_to_bytes(yiaddr), ZERO_ADDR, ZERO_ADDR,
                        chaddr.ljust(16, b"\x00")[:16], b"\x00" * 64, b"\x00" * 128,
                        MAGIC_COOKIE)


def encode_options(msg_type, server_id, mask=None, router=None, dns=None,
                    lease_seconds=None, broadcast=None, domain=None):
    """encode the DHCP options of a reply"""
    out = bytearray([53, 1, msg_type])
    if server_id:
        out += bytes([54, 4]) + ip_to_bytes(server_id)
    if mask:
        out += bytes([1, 4]) + ip_to_bytes(mask)
    if router:
        out += bytes([3, 4]) + ip_to_bytes(router)
    if dns:
        out += bytes([6, 4]) + ip_to_bytes(dns)
    if broadcast:
        out += bytes([28, 4]) + ip_to_bytes(broadcast)
    if lease_seconds is not None:
        out += bytes([51, 4]) + struct.pack(">I", lease_seconds)
    if domain:
        db = domain.encode()
        out += bytes([15, len(db)]) + db
    out += bytes([255])
    return bytes(out)


def build_reply(msg_type, req, yiaddr, server_id, mask=None, router=None, dns=None,
                 lease_seconds=None, broadcast=None, domain=None):
    """build a DHCP reply packet for a request"""
    header = build_header(BOOTREPLY, req["xid"], req["flags"], "0.0.0.0", yiaddr,
                           req["chaddr"])
    return header + encode_options(msg_type, server_id, mask, router, dns,
                                    lease_seconds, broadcast, domain)


def decode_reply(data):
    """decode a reply into readable fields"""
    if len(data) < HEADER_LEN:
        return None
    fields = struct.unpack(HEADER_FMT, data[:HEADER_LEN])
    (op, _htype, _hlen, _hops, xid, _secs, flags, _ciaddr, yiaddr, _siaddr,
     _giaddr, _chaddr, _sname, _fname, _cookie) = fields
    options = parse_options(data[HEADER_LEN:])
    if options is None:
        return None
    out = {"op": op, "xid": xid, "flags": flags, "yiaddr": socket.inet_ntoa(yiaddr)}
    if 53 in options and len(options[53]) == 1:
        out["msg_type"] = options[53][0]
    for code, key in ((1, "mask"), (3, "router"), (6, "dns"), (54, "server_id"),
                      (28, "broadcast")):
        if code in options and len(options[code]) == 4:
            out[key] = socket.inet_ntoa(options[code])
    if 51 in options and len(options[51]) == 4:
        out["lease"] = struct.unpack(">I", options[51])[0]
    if 15 in options:
        out["domain"] = options[15].decode(errors="replace")
    return out


class DhcpService(Service):
    name = "dhcp"

    def __init__(self, cfg):
        """load the leases and the address pool"""
        self.cfg = cfg
        net = ipaddress.ip_network(cfg.subnet, strict=False)
        self.mask = str(net.netmask)
        self.broadcast = str(net.broadcast_address)
        self.pool_start = ip_to_int(cfg.pool_start)
        self.pool_end = ip_to_int(cfg.pool_end)
        self.domain = None
        self.state_path = os.path.join(cfg.state_dir, "leases.json")
        self.leases = self._load_leases()
        self._sock = None
        self._anchor_mono = monotonic()
        self._anchor_wall = now()

    def sockets(self):
        """return the server socket"""
        if self._sock is None:
            self._sock = self._open_socket()
        return [self._sock] if self._sock is not None else []

    def _open_socket(self):
        """open a broadcast UDP socket bound to the veth interface"""
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                         self.cfg.veth_if.encode())
            s.bind(("", 67))
            s.setblocking(False)
            return s
        except OSError as e:
            log("NB_DHCP_SOCKET_FAILED if=%s error=%s", self.cfg.veth_if, e)
            return None

    def on_host_state(self, state):
        """store the first search domain of the host state"""
        self.domain = state.search[0] if state.search else None

    def on_readable(self, sock):
        """read a datagram and handle it"""
        try:
            data, _addr = sock.recvfrom(65536)
        except OSError as e:
            log("NB_DHCP_BAD reason=recv:%s len=0", e)
            return
        self._handle(data, sock)

    def _handle(self, data, sock):
        """parse and dispatch a datagram"""
        req, reason = parse_packet(data)
        if req is None:
            log("NB_DHCP_BAD reason=%s len=%d", reason, len(data))
            return
        try:
            self._dispatch(req, sock)
        except (OSError, struct.error, UnicodeError) as e:
            log("NB_DHCP_BAD reason=dispatch:%s len=%d", e, len(data))

    def _dispatch(self, req, sock):
        """call the handler for the message type of a request"""
        mt = req["msg_type"]
        if mt == MSG_DISCOVER:
            self._discover(req, sock)
        elif mt == MSG_REQUEST:
            self._request(req, sock)
        elif mt == MSG_DECLINE:
            self._decline(req)
        elif mt == MSG_RELEASE:
            self._release(req)
        elif mt == MSG_INFORM:
            self._inform(req, sock)

    def _discover(self, req, sock):
        """offer an address to a client that sent a discover"""
        mac = mac_str(req["chaddr"])
        ip = self._allocate(mac)
        if ip is None:
            log("NB_DHCP_POOL_EXHAUSTED mac=%s", mac)
            return
        reply = build_reply(MSG_OFFER, req, ip, self.cfg.veth_addr, self.mask,
                             self.cfg.veth_addr, self.cfg.veth_addr,
                             self.cfg.lease_seconds, self.broadcast, self.domain)
        self._send(sock, req, reply)
        log("NB_DHCP_OFFER mac=%s ip=%s dns=%s router=%s lease=%d",
            mac, ip, self.cfg.veth_addr, self.cfg.veth_addr, self.cfg.lease_seconds)

    def _request(self, req, sock):
        """acknowledge or refuse a client's request for an address"""
        mac = mac_str(req["chaddr"])
        opts = req["options"]
        if 54 in opts and len(opts[54]) == 4:
            if socket.inet_ntoa(opts[54]) != self.cfg.veth_addr:
                return
        req_ip = None
        if 50 in opts and len(opts[50]) == 4:
            req_ip = socket.inet_ntoa(opts[50])
        elif req["ciaddr"] != ZERO_ADDR:
            req_ip = socket.inet_ntoa(req["ciaddr"])
        if req_ip is None:
            self._nak(req, sock, mac, "no_address")
            return
        req_ip_int = ip_to_int(req_ip)
        if not self.pool_start <= req_ip_int <= self.pool_end:
            self._nak(req, sock, mac, "outside_pool")
            return
        existing = self.leases.get(mac)
        if existing is not None and existing["ip"] != req_ip:
            self._nak(req, sock, mac, "mismatched_lease")
            return
        if existing is None and self._holder_of(req_ip) is not None:
            self._nak(req, sock, mac, "address_in_use")
            return
        self.leases[mac] = {"ip": req_ip,
                            "expires": self._wall_for_mono(monotonic()) + self.cfg.lease_seconds}
        self._save_leases()
        reply = build_reply(MSG_ACK, req, req_ip, self.cfg.veth_addr, self.mask,
                             self.cfg.veth_addr, self.cfg.veth_addr,
                             self.cfg.lease_seconds, self.broadcast, self.domain)
        self._send(sock, req, reply)
        log("NB_DHCP_ACK mac=%s ip=%s lease=%d", mac, req_ip, self.cfg.lease_seconds)

    def _nak(self, req, sock, mac, reason):
        """send a NAK reply and log the reason"""
        reply = build_reply(MSG_NAK, req, "0.0.0.0", self.cfg.veth_addr)
        self._send(sock, req, reply, force_broadcast=True)
        log("NB_DHCP_NAK mac=%s reason=%s", mac, reason)

    def _decline(self, req):
        """drop the lease for an address a client declined"""
        mac = mac_str(req["chaddr"])
        opts = req["options"]
        ip = None
        if 50 in opts and len(opts[50]) == 4:
            ip = socket.inet_ntoa(opts[50])
        lease = self.leases.get(mac)
        if ip is None and lease is not None:
            ip = lease["ip"]
        if ip is None:
            log("NB_DHCP_BAD reason=decline_no_address len=0")
            return
        if lease is not None:
            del self.leases[mac]
            self._save_leases()
        log("NB_DHCP_DECLINE mac=%s ip=%s", mac, ip)

    def _release(self, req):
        """drop the lease of a client that released its address"""
        mac = mac_str(req["chaddr"])
        lease = self.leases.pop(mac, None)
        if lease is None:
            log("NB_DHCP_BAD reason=release_unknown_mac len=0")
            return
        self._save_leases()
        log("NB_DHCP_RELEASE mac=%s ip=%s", mac, lease["ip"])

    def _inform(self, req, sock):
        """answer an inform request with configuration only"""
        mac = mac_str(req["chaddr"])
        if req["ciaddr"] == ZERO_ADDR:
            log("NB_DHCP_BAD reason=inform_no_ciaddr len=0")
            return
        ip = socket.inet_ntoa(req["ciaddr"])
        reply = build_reply(MSG_ACK, req, "0.0.0.0", self.cfg.veth_addr, self.mask,
                             self.cfg.veth_addr, self.cfg.veth_addr, None,
                             self.broadcast, self.domain)
        self._send(sock, req, reply)
        log("NB_DHCP_ACK mac=%s ip=%s lease=%d", mac, ip, 0)

    def _send(self, sock, req, reply, force_broadcast=False):
        """send a reply to the client by broadcast or unicast"""
        broadcast = force_broadcast or bool(req["flags"] & FLAG_BROADCAST) \
            or req["ciaddr"] == ZERO_ADDR
        dest = ("255.255.255.255", 68) if broadcast else (socket.inet_ntoa(req["ciaddr"]), 68)
        try:
            sock.sendto(reply, dest)
        except OSError as e:
            log("NB_DHCP_BAD reason=send:%s len=%d", e, len(reply))

    def _allocate(self, mac):
        """return the client's lease address or a free one"""
        existing = self.leases.get(mac)
        if existing is not None:
            return existing["ip"]
        used = {lease["ip"] for lease in self.leases.values()}
        for ip_int in range(self.pool_start, self.pool_end + 1):
            ip = int_to_ip(ip_int)
            if ip in used:
                continue
            self.leases[mac] = {"ip": ip,
                                "expires": self._wall_for_mono(monotonic()) + self.cfg.lease_seconds}
            self._save_leases()
            return ip
        return None

    def _holder_of(self, ip):
        """return the hardware address holding an address, or None"""
        for mac, lease in self.leases.items():
            if lease["ip"] == ip:
                return mac
        return None

    def _wall_for_mono(self, mono):
        """convert a monotonic time to wall time"""
        return self._anchor_wall + (mono - self._anchor_mono)

    def _mono_for_wall(self, wall):
        """convert a wall time to monotonic time"""
        return self._anchor_mono + (wall - self._anchor_wall)

    def next_tick(self, now_mono):
        """return the time of the earliest lease expiry"""
        if not self.leases:
            return None
        soonest = min(lease["expires"] for lease in self.leases.values())
        return self._mono_for_wall(soonest)

    def tick(self, now_mono):
        """remove expired leases and save the rest"""
        wall = self._wall_for_mono(now_mono)
        expired = [mac for mac, lease in self.leases.items() if lease["expires"] <= wall]
        if not expired:
            return
        for mac in expired:
            ip = self.leases.pop(mac)["ip"]
            log("NB_DHCP_EXPIRE mac=%s ip=%s", mac, ip)
        self._save_leases()

    def _load_leases(self):
        """read the saved leases"""
        try:
            with open(self.state_path) as f:
                raw = json.load(f)
        except FileNotFoundError:
            return {}
        except (OSError, ValueError) as e:
            log("NB_DHCP_LEASES_LOAD_FAILED path=%s error=%s", self.state_path, e)
            return {}
        leases = {}
        for mac, rec in raw.items():
            ip, expires = rec.get("ip"), rec.get("expires")
            if ip is None or expires is None:
                log("NB_DHCP_LEASES_LOAD_FAILED path=%s error=bad_record:%s",
                    self.state_path, mac)
                continue
            leases[mac] = {"ip": ip, "expires": float(expires)}
        return leases

    def _save_leases(self):
        """write the leases to the state file"""
        tmp = self.state_path + ".tmp"
        try:
            with open(tmp, "w") as f:
                json.dump(self.leases, f)
            os.replace(tmp, self.state_path)
        except OSError as e:
            log("NB_DHCP_LEASES_SAVE_FAILED path=%s error=%s", self.state_path, e)
