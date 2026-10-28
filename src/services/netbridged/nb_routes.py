import errno
import os
import socket
import struct

from nb_common import log, monotonic, sanitize_for_log

UPLINKS_FILE = "uplinks"
RETRY_SECONDS = 5.0
SUBSCRIBE_RETRY_SECONDS = 30.0
QUERY_TIMEOUT = 1.0
RECV_SIZE = 65536

AF_NETLINK = getattr(socket, "AF_NETLINK", 16)
NETLINK_ROUTE = 0

NLMSG_HDR = "=IHHII"
NLMSG_HDRLEN = 16
NLMSG_ERROR = 2
NLMSG_DONE = 3
NLMSG_OVERRUN = 4
NLM_F_REQUEST = 0x1
NLM_F_MULTI = 0x2
NLM_F_DUMP_INTR = 0x10
NLM_F_REPLACE = 0x100
NLM_F_DUMP = 0x300
NLA_TYPE_MASK = 0x3fff

RTM_NEWLINK = 16
RTM_DELLINK = 17
RTM_NEWROUTE = 24
RTM_DELROUTE = 25
RTM_GETROUTE = 26
RTMSG = "=BBBBBBBBI"
RTMSG_LEN = 12
RTNEXTHOP = "=HBBi"
RTNEXTHOP_LEN = 8
IFINFOMSG = "=BBHiII"
IFINFOMSG_LEN = 16
RTA_OIF = 4
RTA_GATEWAY = 5
RTA_PRIORITY = 6
RTA_MULTIPATH = 9
RTA_TABLE = 15
RT_TABLE_MAIN = 254
RTN_UNICAST = 1
RTNH_F_DEAD = 0x1
RTNH_F_LINKDOWN = 0x10
IFF_UP = 0x1
IFF_RUNNING = 0x40
IFF_LOWER_UP = 0x10000
LINK_STATE_FLAGS = IFF_UP | IFF_RUNNING | IFF_LOWER_UP
IFLA_WIRELESS = 11
RTMGRP_LINK = 0x1
RTMGRP_IPV4_ROUTE = 0x40
RTMGRP_IPV6_ROUTE = 0x400


def nl_align(n):
    """round a length up to netlink's 4-byte alignment"""
    return (n + 3) & ~3


def nlmsg(msg_type, flags, seq, payload):
    """build a netlink message"""
    return struct.pack(NLMSG_HDR, NLMSG_HDRLEN + len(payload), msg_type, flags, seq, 0) + payload


def iter_nlmsgs(data):
    """yield each message's type, flags, sequence and payload"""
    pos = 0
    while pos + NLMSG_HDRLEN <= len(data):
        length, mtype, flags, seq, _pid = struct.unpack_from(NLMSG_HDR, data, pos)
        if length < NLMSG_HDRLEN or pos + length > len(data):
            return
        yield mtype, flags, seq, data[pos + NLMSG_HDRLEN:pos + length]
        pos += nl_align(length)


def nla(attr_type, value):
    """build a netlink attribute"""
    raw = struct.pack("=HH", 4 + len(value), attr_type) + value
    return raw + b"\0" * (nl_align(len(raw)) - len(raw))


def iter_attrs(buf):
    """yield each attribute's type and value in a buffer"""
    pos = 0
    while pos + 4 <= len(buf):
        length, atype = struct.unpack_from("=HH", buf, pos)
        if length < 4 or pos + length > len(buf):
            return
        yield atype & NLA_TYPE_MASK, buf[pos + 4:pos + length]
        pos += nl_align(length)


def attrs_of(buf):
    """return each attribute type's first value in a buffer"""
    out = {}
    for atype, value in iter_attrs(buf):
        out.setdefault(atype, value)
    return out


def u32_of(value, default=None):
    """unpack a native u32 attribute value"""
    if value is None or len(value) < 4:
        return default
    return struct.unpack("=I", value[:4])[0]


def interface_name(ifindex):
    """return an interface's name, or None"""
    try:
        return socket.if_indextoname(ifindex)
    except (OSError, OverflowError):
        return None


def write_atomic(path, text, mode):
    """replace a file's text through a temporary file and rename"""
    tmp = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".tmp")
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "w") as f:
            os.fchmod(f.fileno(), mode)
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class DefaultRoute:
    """a default route of the host's main table"""
    __slots__ = ("family", "metric", "ifindex", "ifindexes", "live", "usable", "key")


def _iter_nexthops(buf):
    """yield each multipath hop's ifindex, flags and gateway"""
    pos = 0
    while pos + RTNEXTHOP_LEN <= len(buf):
        length, flags, _hops, ifindex = struct.unpack_from(RTNEXTHOP, buf, pos)
        if length < RTNEXTHOP_LEN or pos + length > len(buf):
            return
        gateway = attrs_of(buf[pos + RTNEXTHOP_LEN:pos + length]).get(RTA_GATEWAY, b"")
        yield ifindex, flags, gateway
        pos += nl_align(length)


def parse_default_route(payload):
    """return a route message's main-table default route, or None"""
    if len(payload) < RTMSG_LEN:
        return None
    family, dst_len, _src, tos, table, _proto, _scope, rtype, flags = \
        struct.unpack_from(RTMSG, payload)
    if family not in (socket.AF_INET, socket.AF_INET6) or dst_len != 0:
        return None
    attrs = attrs_of(payload[RTMSG_LEN:])
    if u32_of(attrs.get(RTA_TABLE), table) != RT_TABLE_MAIN:
        return None
    hops = []
    if RTA_OIF in attrs:
        hops.append((u32_of(attrs[RTA_OIF], 0), flags, attrs.get(RTA_GATEWAY, b"")))
    hops.extend(_iter_nexthops(attrs.get(RTA_MULTIPATH, b"")))
    live = [i for i, f, _gw in hops if i > 0 and not f & (RTNH_F_DEAD | RTNH_F_LINKDOWN)]
    r = DefaultRoute()
    r.family = family
    r.metric = u32_of(attrs.get(RTA_PRIORITY), 0)
    r.ifindexes = frozenset(i for i, _f, _gw in hops if i > 0)
    r.usable = rtype == RTN_UNICAST and bool(live)
    r.live = tuple(live) if r.usable else ()
    r.ifindex = live[0] if live else 0
    r.key = (family, tos, r.metric, rtype, tuple((i, gw) for i, _f, gw in hops))
    return r


def parse_link(payload):
    """return a link message's ifindex, flags and wireless-event marker"""
    if len(payload) < IFINFOMSG_LEN:
        return None
    _family, _pad, _type, index, flags, _change = struct.unpack_from(IFINFOMSG, payload)
    return index, flags, IFLA_WIRELESS in attrs_of(payload[IFINFOMSG_LEN:])


class RouteTable:
    """the host's main-table default routes"""

    def __init__(self):
        """start empty"""
        self.routes = {}
        self.link_state = {}

    def replace(self, payloads):
        """replace the routes with those of a dump"""
        routes = {}
        for payload in payloads:
            r = parse_default_route(payload)
            if r is not None:
                routes[r.key] = r
        self.routes = routes

    def apply_route(self, mtype, nlflags, payload):
        """apply a route notification"""
        r = parse_default_route(payload)
        if r is None:
            return False
        if mtype == RTM_NEWROUTE:
            if nlflags & NLM_F_REPLACE:
                return "resync"
            self.routes[r.key] = r
            return True
        if mtype == RTM_DELROUTE:
            if self.routes.pop(r.key, None) is None:
                return "resync"
            return True
        return False

    def apply_link(self, mtype, payload):
        """return True when a link change affects a default route"""
        parsed = parse_link(payload)
        if parsed is None:
            return False
        index, flags, wireless = parsed
        if wireless:
            return False
        if mtype == RTM_DELLINK:
            self.link_state.pop(index, None)
            changed = True
        else:
            state = flags & LINK_STATE_FLAGS
            changed = self.link_state.get(index) != state
            self.link_state[index] = state
        return changed and any(index in r.ifindexes for r in self.routes.values())

    def uplink(self):
        """return the lowest-metric default route, preferring IPv4"""
        for family in (socket.AF_INET, socket.AF_INET6):
            best = None
            for r in self.routes.values():
                if r.family == family and r.usable and (best is None or r.metric < best.metric):
                    best = r
            if best is not None:
                return best
        return None

    def carrying(self, family):
        """return the ifindexes of a family's usable default routes"""
        return {i for r in self.routes.values() if r.family == family for i in r.live}


def collect_replies(data, seq, dump, out):
    """add a datagram's replies to out, True when complete"""
    for mtype, flags, mseq, payload in iter_nlmsgs(data):
        if mseq != seq:
            continue
        if mtype in (NLMSG_ERROR, NLMSG_DONE):
            err = struct.unpack_from("=i", payload)[0] if len(payload) >= 4 else 0
            if err < 0:
                raise OSError(-err, os.strerror(-err))
            if flags & NLM_F_DUMP_INTR:
                raise OSError(errno.EINTR, "netlink dump interrupted")
            return True
        if flags & NLM_F_DUMP_INTR:
            raise OSError(errno.EINTR, "netlink dump interrupted")
        out.append((mtype, flags, payload))
        if not dump:
            return True
    return False


class NetlinkQuery:
    """blocking netlink request and reply per protocol"""

    def __init__(self, timeout=QUERY_TIMEOUT):
        """start with no socket open"""
        self.timeout = timeout
        self._socks = {}
        self._seq = 0

    def _sock(self, proto):
        """return a protocol's query socket"""
        sock = self._socks.get(proto)
        if sock is None:
            sock = socket.socket(AF_NETLINK, socket.SOCK_RAW | socket.SOCK_CLOEXEC, proto)
            sock.bind((0, 0))
            self._socks[proto] = sock
        return sock

    def request(self, proto, msg_type, flags, payload):
        """send a request and return its replies"""
        self._seq = (self._seq % 0x7fffffff) + 1
        seq = self._seq
        sock = self._sock(proto)
        sock.send(nlmsg(msg_type, flags | NLM_F_REQUEST, seq, payload))
        dump = flags & NLM_F_DUMP == NLM_F_DUMP
        out = []
        deadline = monotonic() + self.timeout
        while True:
            left = deadline - monotonic()
            if left <= 0:
                raise OSError(errno.ETIMEDOUT, "netlink reply timed out")
            sock.settimeout(left)
            try:
                data = sock.recv(RECV_SIZE)
            except TimeoutError:
                continue
            if collect_replies(data, seq, dump, out):
                return out

    def close(self):
        """close the query sockets"""
        for sock in self._socks.values():
            try:
                sock.close()
            except OSError:
                pass
        self._socks.clear()


def dump_routes(query):
    """return the payloads of the host's routes"""
    req = struct.pack(RTMSG, socket.AF_UNSPEC, 0, 0, 0, 0, 0, 0, 0, 0)
    replies = query.request(NETLINK_ROUTE, RTM_GETROUTE, NLM_F_DUMP, req)
    return [body for mtype, _flags, body in replies if mtype == RTM_NEWROUTE]


def open_route_events():
    """open a netlink socket subscribed to route and link changes"""
    sock = socket.socket(AF_NETLINK, socket.SOCK_RAW | socket.SOCK_NONBLOCK | socket.SOCK_CLOEXEC,
                         NETLINK_ROUTE)
    try:
        sock.bind((0, RTMGRP_LINK | RTMGRP_IPV4_ROUTE | RTMGRP_IPV6_ROUTE))
    except OSError:
        sock.close()
        raise
    return sock


def format_uplinks(v4, v6):
    """return the uplinks file text"""
    return "".join("%s%s\n" % (tag, "".join(" " + n for n in names))
                   for tag, names in (("v4", v4), ("v6", v6)))


class UplinkWatcher:
    """follow the host's main-table default routes and write <state-dir>/uplinks"""
    name = "uplinks"

    def __init__(self, state_dir, query=None, clock=monotonic, sockets=True, ifname=interface_name):
        """prepare the route reader"""
        self.path = os.path.join(state_dir, UPLINKS_FILE)
        self.query = query if query is not None else NetlinkQuery()
        self.clock = clock
        self.ifname = ifname
        self.use_sockets = sockets
        self.table = RouteTable()
        self.known = False
        self.listeners = []
        self._sock = None
        self._pending = None
        self._resync = False
        self._retry_at = None
        self._written = None
        self._errors = {}

    def start(self):
        """subscribe to routes, dump them and write the uplinks file"""
        self._subscribe()
        self._resync = True
        self._note("startup")
        self.process()

    def sockets(self):
        """return the route socket to poll"""
        return [self._sock] if self._sock is not None else []

    def on_host_state(self, _state):
        """ignore resolver and proxy changes"""

    def _subscribe(self):
        """open the route event socket or schedule a retry"""
        if not self.use_sockets or self._sock is not None:
            return
        try:
            self._sock = open_route_events()
        except OSError as e:
            self._error("subscribe", e)
            self._arm_retry(SUBSCRIBE_RETRY_SECONDS)
            return
        self._errors.pop("subscribe", None)

    def resync(self):
        """replace the route table with a fresh dump"""
        for _attempt in range(2):
            try:
                payloads = dump_routes(self.query)
            except OSError as e:
                if e.errno == errno.EINTR:
                    continue
                self._error("dump_routes", e)
                break
            self.table.replace(payloads)
            self._errors.pop("dump_routes", None)
            self._resync = False
            self.known = True
            return True
        self._resync = True
        self._arm_retry(RETRY_SECONDS)
        return False

    def _note(self, reason):
        """record the first pending reason to act"""
        if self._pending is None:
            self._pending = reason

    def feed(self, data):
        """read a datagram from the route socket"""
        for mtype, flags, _seq, payload in iter_nlmsgs(data):
            if mtype in (RTM_NEWROUTE, RTM_DELROUTE):
                got = self.table.apply_route(mtype, flags, payload)
                if got == "resync":
                    self._resync = True
                if got:
                    self._note("route")
            elif mtype in (RTM_NEWLINK, RTM_DELLINK):
                if self.table.apply_link(mtype, payload):
                    self._resync = True
                    self._note("link")
            elif mtype == NLMSG_OVERRUN:
                self._resync = True
                self._note("overrun")

    def process(self):
        """apply the changes of the fed datagrams"""
        reason, self._pending = self._pending, None
        if self._resync:
            self.resync()
        if reason is None or not self.known:
            return
        self.write_uplinks()
        for listener in list(self.listeners):
            try:
                listener(reason)
            except Exception as e:  # noqa: BLE001
                log("NB_SERVICE_ERROR name=%s where=on_routes error=%s",
                    getattr(getattr(listener, "__self__", None), "name", "?"), e)

    def deliver(self, data):
        """feed a datagram and apply it"""
        self.feed(data)
        self.process()

    def on_readable(self, sock):
        """drain the route socket and apply the changes"""
        while True:
            try:
                data = sock.recv(RECV_SIZE)
            except BlockingIOError:
                break
            except OSError as e:
                if e.errno != errno.ENOBUFS:
                    raise
                self._resync = True
                self._note("overrun")
                continue
            if not data:
                break
            self.feed(data)
        self.process()

    def uplink(self):
        """return the route the host sends by, or None"""
        return self.table.uplink()

    def write_uplinks(self):
        """write the interfaces carrying a default route on a change"""
        lists = []
        for family in (socket.AF_INET, socket.AF_INET6):
            names = {self.ifname(i) for i in self.table.carrying(family)}
            lists.append(sorted(n for n in names if n))
        text = format_uplinks(*lists)
        if text == self._written:
            return
        try:
            write_atomic(self.path, text, 0o644)
        except OSError as e:
            self._error("write_uplinks", e)
            self._arm_retry(RETRY_SECONDS)
            return
        self._errors.pop("write_uplinks", None)
        self._written = text
        log("NB_UPLINKS v4=%s v6=%s", ",".join(lists[0]) or "-", ",".join(lists[1]) or "-")

    def _error(self, call, e):
        """log an error once until its call succeeds again"""
        key = (getattr(e, "errno", None), str(e))
        if self._errors.get(call) == key:
            return
        self._errors[call] = key
        log("NB_UPLINKS_ERROR call=%s errno=%s error=%s -- retrying",
            call, key[0] if key[0] is not None else "-", sanitize_for_log(key[1]))

    def _arm_retry(self, delay):
        """schedule a retry no later than delay from now"""
        at = self.clock() + delay
        if self._retry_at is None or at < self._retry_at:
            self._retry_at = at

    def next_tick(self, _mono):
        """return the time of the next retry, or None"""
        return self._retry_at

    def tick(self, mono):
        """subscribe, dump and write again after a failure"""
        if self._retry_at is None or mono < self._retry_at:
            return
        self._retry_at = None
        self._subscribe()
        self._resync = True
        self._note("retry")
        self.process()

    def close(self):
        """close the route socket and the query socket"""
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        close = getattr(self.query, "close", None)
        if close is not None:
            close()
