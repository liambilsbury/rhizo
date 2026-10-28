import errno
import os
import socket
import struct
import time

FAMILY_NAME = b"rhizo_wlan"
FAMILY_VERSION = 1
TIMEOUT = 5.0
RECV_SIZE = 65536

CMD_CREATE = 1
CMD_DESTROY = 2
CMD_SET_STATE = 3
CMD_GET_STATE = 4

ATTR_HOST_IFNAME = 1
ATTR_WLAN_IFNAME = 2
ATTR_WLAN_MAC = 3
ATTR_HOST_MAC = 4
ATTR_NETNS_PID = 5
ATTR_NETNS_FD = 6
ATTR_OWNER_UID = 7
ATTR_ALPHA2 = 8
ATTR_PRESENT = 9
ATTR_SSID = 10
ATTR_BSSID = 11
ATTR_SIGNAL_MBM = 12
ATTR_CONNECTED = 13
ATTR_WIPHY_NAME = 14
ATTR_WLAN_IFINDEX = 15
ATTR_HOST_IFINDEX = 16

MAX_SSID_LEN = 32
MIN_SIGNAL_MBM = -12800
IFNAMSIZ = 16

AF_NETLINK = getattr(socket, "AF_NETLINK", 16)
NETLINK_GENERIC = 16
SOL_NETLINK = 270
NETLINK_CAP_ACK = 10
NETLINK_EXT_ACK = 11

NLMSG_HDR = "=IHHII"
NLMSG_HDRLEN = 16
NLMSG_ERROR = 2
NLMSG_DONE = 3
NLM_F_REQUEST = 0x1
NLM_F_ACK = 0x4
NLM_F_CAPPED = 0x100
NLM_F_ACK_TLVS = 0x200
NLMSGERR_ATTR_MSG = 1
NLA_TYPE_MASK = 0x3fff

GENL_ID_CTRL = 0x10
GENL_HDR = "=BBH"
GENL_HDRLEN = 4
CTRL_CMD_GETFAMILY = 3
CTRL_ATTR_FAMILY_ID = 1
CTRL_ATTR_FAMILY_NAME = 2

NOT_LOADED = ("no rhizo_wlan generic netlink family: the driver is not loaded, or this is not the "
              "initial network namespace")


class WlanError(OSError):
    """a refused or failed rhizo_wlan request"""

    def __init__(self, err, message):
        """keep the errno and a message naming the request"""
        super().__init__(err, message)


def _align(n):
    """round a length up to netlink's 4-byte alignment"""
    return (n + 3) & ~3


def _nla(attr_type, value):
    """build a netlink attribute"""
    raw = struct.pack("=HH", 4 + len(value), attr_type) + value
    return raw + b"\0" * (_align(len(raw)) - len(raw))


def _attrs(buf):
    """return each attribute type's first value in a buffer"""
    out = {}
    pos = 0
    while pos + 4 <= len(buf):
        length, atype = struct.unpack_from("=HH", buf, pos)
        if length < 4 or pos + length > len(buf):
            break
        out.setdefault(atype & NLA_TYPE_MASK, buf[pos + 4:pos + length])
        pos += _align(length)
    return out


def _string(value):
    """decode a NUL-terminated string attribute"""
    return value.split(b"\0", 1)[0].decode("utf-8", "replace")


def _u32(value, default=0):
    """unpack a native u32 attribute"""
    return struct.unpack("=I", value[:4])[0] if value and len(value) >= 4 else default


def _u8(value, default=0):
    """unpack a u8 attribute"""
    return value[0] if value else default


def _ifname(value, what):
    """encode an interface name as a NUL-terminated attribute value"""
    if not isinstance(value, str):
        raise WlanError(errno.EINVAL, "%s must be a str, not %s" % (what, type(value).__name__))
    raw = value.encode()
    if not raw or len(raw) >= IFNAMSIZ:
        raise WlanError(errno.EINVAL, "%s %r must be 1-%d bytes" % (what, value, IFNAMSIZ - 1))
    return raw + b"\0"


def _mac(value, what):
    """return a hardware address as 6 bytes"""
    if isinstance(value, str):
        try:
            value = bytes(int(part, 16) for part in value.split(":"))
        except ValueError:
            raise WlanError(errno.EINVAL, "%s %r is not a hardware address" % (what, value)) from None
    if not isinstance(value, (bytes, bytearray)) or len(value) != 6:
        raise WlanError(errno.EINVAL, "%s must be 6 bytes" % what)
    return bytes(value)


class _Socket:
    """a single-request generic netlink socket"""

    def __init__(self):
        """open and bind the socket with extended acks"""
        self.sock = socket.socket(AF_NETLINK, socket.SOCK_RAW | socket.SOCK_CLOEXEC, NETLINK_GENERIC)
        try:
            self.sock.bind((0, 0))
            for opt in (NETLINK_EXT_ACK, NETLINK_CAP_ACK):
                try:
                    self.sock.setsockopt(SOL_NETLINK, opt, 1)
                except OSError:
                    pass
        except OSError:
            self.sock.close()
            raise
        self.seq = 0

    def __enter__(self):
        """return the socket wrapper"""
        return self

    def __exit__(self, *_exc):
        """close the socket"""
        self.sock.close()

    def request(self, family, cmd, version, attrs, what):
        """send a request and return its reply's attributes, or None"""
        self.seq += 1
        payload = struct.pack(GENL_HDR, cmd, version, 0) + b"".join(attrs)
        self.sock.send(struct.pack(NLMSG_HDR, NLMSG_HDRLEN + len(payload), family,
                                   NLM_F_REQUEST | NLM_F_ACK, self.seq, 0) + payload)
        reply = None
        deadline = time.monotonic() + TIMEOUT
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise WlanError(errno.ETIMEDOUT, "%s: no answer from the kernel" % what)
            self.sock.settimeout(left)
            try:
                data = self.sock.recv(RECV_SIZE)
            except TimeoutError:
                continue
            pos = 0
            while pos + NLMSG_HDRLEN <= len(data):
                length, mtype, flags, seq, _pid = struct.unpack_from(NLMSG_HDR, data, pos)
                if length < NLMSG_HDRLEN or pos + length > len(data):
                    break
                body = data[pos + NLMSG_HDRLEN:pos + length]
                pos += _align(length)
                if seq != self.seq:
                    continue
                if mtype == NLMSG_ERROR:
                    err = struct.unpack_from("=i", body)[0] if len(body) >= 4 else -errno.EIO
                    if err < 0:
                        raise WlanError(-err, _error_message(what, -err, flags, body))
                    return reply
                if mtype == NLMSG_DONE:
                    return reply
                if mtype == family and len(body) >= GENL_HDRLEN:
                    reply = _attrs(body[GENL_HDRLEN:])


def _error_message(what, err, flags, body):
    """describe a netlink error with its extended ack message"""
    text = os.strerror(err)
    if flags & NLM_F_ACK_TLVS:
        echoed = NLMSG_HDRLEN
        if not flags & NLM_F_CAPPED and len(body) >= 4 + 4:
            echoed = _align(struct.unpack_from("=I", body, 4)[0])
        msg = _attrs(body[4 + echoed:]).get(NLMSGERR_ATTR_MSG)
        if msg:
            text = "%s (%s)" % (text, _string(msg))
    return "%s: %s" % (what, text)


def _family(sock, what):
    """return the rhizo_wlan family's id"""
    try:
        reply = sock.request(GENL_ID_CTRL, CTRL_CMD_GETFAMILY, 1,
                             [_nla(CTRL_ATTR_FAMILY_NAME, FAMILY_NAME + b"\0")], what)
    except WlanError as e:
        if e.errno == errno.ENOENT:
            raise WlanError(errno.ENOENT, "%s: %s" % (what, NOT_LOADED)) from None
        raise
    raw = (reply or {}).get(CTRL_ATTR_FAMILY_ID)
    if raw is None or len(raw) < 2:
        raise WlanError(errno.EPROTO, "%s: the kernel named no rhizo_wlan family id" % what)
    return struct.unpack("=H", raw[:2])[0]


def _call(cmd, attrs, what):
    """send a rhizo_wlan command and return its reply's attributes"""
    try:
        with _Socket() as sock:
            return sock.request(_family(sock, what), cmd, FAMILY_VERSION, attrs, what)
    except WlanError:
        raise
    except OSError as e:
        raise WlanError(e.errno or errno.EIO, "%s: %s" % (what, e.strerror or e)) from None


def wlan_available():
    """return True when the rhizo_wlan generic netlink family resolves"""
    try:
        with _Socket() as sock:
            _family(sock, "wlan_available")
        return True
    except OSError:
        return False


def create(host_if, wlan_if, wlan_mac, netns_pid, owner_uid, host_mac=None, netns_fd=None,
           alpha2=None):
    """make a station and host interface pair"""
    attrs = [_nla(ATTR_HOST_IFNAME, _ifname(host_if, "host_if")),
             _nla(ATTR_WLAN_IFNAME, _ifname(wlan_if, "wlan_if")),
             _nla(ATTR_WLAN_MAC, _mac(wlan_mac, "wlan_mac")),
             _nla(ATTR_OWNER_UID, struct.pack("=I", owner_uid))]
    if (netns_pid is None) == (netns_fd is None):
        raise WlanError(errno.EINVAL, "create %s: name the namespace by netns_pid or netns_fd" % host_if)
    if netns_pid is not None:
        attrs.append(_nla(ATTR_NETNS_PID, struct.pack("=I", netns_pid)))
    else:
        attrs.append(_nla(ATTR_NETNS_FD, struct.pack("=I", netns_fd)))
    if host_mac is not None:
        attrs.append(_nla(ATTR_HOST_MAC, _mac(host_mac, "host_mac")))
    if alpha2 is not None:
        raw = alpha2.encode() if isinstance(alpha2, str) else bytes(alpha2)
        if len(raw) != 2:
            raise WlanError(errno.EINVAL, "create %s: alpha2 %r must be 2 characters" % (host_if, alpha2))
        attrs.append(_nla(ATTR_ALPHA2, raw))
    _call(CMD_CREATE, attrs, "create %s" % host_if)


def destroy(host_if):
    """remove the pair whose host end is host_if"""
    _call(CMD_DESTROY, [_nla(ATTR_HOST_IFNAME, _ifname(host_if, "host_if"))], "destroy %s" % host_if)


def set_state(host_if, present, ssid=b"", bssid=b"", signal_mbm=0):
    """set the station's access point"""
    what = "set_state %s" % host_if
    attrs = [_nla(ATTR_HOST_IFNAME, _ifname(host_if, "host_if")),
             _nla(ATTR_PRESENT, struct.pack("=B", 1 if present else 0))]
    if present:
        if not isinstance(ssid, (bytes, bytearray)) or not 1 <= len(ssid) <= MAX_SSID_LEN:
            raise WlanError(errno.EINVAL, "%s: ssid must be 1-%d bytes" % (what, MAX_SSID_LEN))
        signal = int(signal_mbm)
        if not MIN_SIGNAL_MBM <= signal <= 0:
            raise WlanError(errno.EINVAL, "%s: signal_mbm %d is outside %d..0" % (what, signal, MIN_SIGNAL_MBM))
        attrs += [_nla(ATTR_SSID, bytes(ssid)), _nla(ATTR_BSSID, _mac(bssid, "bssid")),
                  _nla(ATTR_SIGNAL_MBM, struct.pack("=i", signal))]
    _call(CMD_SET_STATE, attrs, what)


def get_state(host_if):
    """return the pair's names, owner, access point and connection"""
    a = _call(CMD_GET_STATE, [_nla(ATTR_HOST_IFNAME, _ifname(host_if, "host_if"))],
              "get_state %s" % host_if)
    if a is None:
        raise WlanError(errno.EPROTO, "get_state %s: the kernel sent no state" % host_if)
    signal = a.get(ATTR_SIGNAL_MBM)
    return {
        "host_if": _string(a.get(ATTR_HOST_IFNAME, b"")),
        "wlan_if": _string(a.get(ATTR_WLAN_IFNAME, b"")),
        "host_ifindex": _u32(a.get(ATTR_HOST_IFINDEX)),
        "wlan_ifindex": _u32(a.get(ATTR_WLAN_IFINDEX)),
        "wiphy": _string(a.get(ATTR_WIPHY_NAME, b"")),
        "owner_uid": _u32(a.get(ATTR_OWNER_UID)),
        "present": bool(_u8(a.get(ATTR_PRESENT))),
        "connected": bool(_u8(a.get(ATTR_CONNECTED))),
        "ssid": bytes(a.get(ATTR_SSID, b"")),
        "bssid": bytes(a.get(ATTR_BSSID, b"")),
        "signal_mbm": struct.unpack("=i", signal[:4])[0] if signal and len(signal) >= 4 else 0,
    }
