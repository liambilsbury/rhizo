#!/usr/bin/env python3
import errno
import signal
import socket
import struct
import subprocess
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [
    HERE,
    os.path.normpath(os.path.join(HERE, "..")),
    os.path.normpath(os.path.join(HERE, "..", "..", "androidd")),
]
from sandbox import capabilities

ADB_PORT = 5555
NETLINK_NETFILTER = 12
NF_NETLINK_CONNTRACK_NEW = 1
NF_NETLINK_CONNTRACK_UPDATE = 2
NF_NETLINK_CONNTRACK_DESTROY = 4
CT_NEW = 1 << 8 | 0
CT_DELETE = 1 << 8 | 2
CTA_TUPLE_REPLY = 2
CTA_ID = 12
CTA_TUPLE_IP = 1
CTA_IP_V4_SRC = 1
CTA_IP_V4_DST = 2
CTA_TUPLE_PROTO = 2
CTA_PROTO_NUM = 1
CTA_PROTO_SRC_PORT = 2
CTA_PROTO_DST_PORT = 3
CTA_PROTOINFO = 4
CTA_PROTOINFO_TCP = 1
CTA_PROTOINFO_TCP_STATE = 1
TCP_CONNTRACK_TIME_WAIT = 7
TCP_CONNTRACK_CLOSE = 8
NLA_TYPE_MASK = 0x3FFF
IPPROTO_TCP = 6
CT_GET = 1 << 8 | 1
NLMSG_ERROR = 2
NLMSG_DONE = 3
NLM_F_REQUEST = 1
NLM_F_CREATE = 0x400
NLM_F_DUMP = 0x300
SO_RCVBUFFORCE = 33
RCVBUF_BYTES = 4 << 20


def _instanced(base, sandbox_id, sep="-"):
    """build the instance name from base and id"""
    return base if sandbox_id == 0 else "%s%s%s" % (base, sep, sandbox_id)


SANDBOX_ID = int(os.environ.get("RHIZO_SANDBOX_ID", "0"))
TIMER_UNIT = _instanced("rhizo-server-idle-stop", SANDBOX_ID)
ANDROIDD_UNIT = "androidd.service" if SANDBOX_ID == 0 else "androidd@%d.service" % SANDBOX_ID
ADB_GUEST_ADDR = "192.168.%d.50" % (100 + SANDBOX_ID)


def log(msg):
    """print a message"""
    print(msg, flush=True)


def nl_attrs(buf):
    """return a netlink attribute buffer as {type: payload}"""
    attrs, off = {}, 0
    while off + 4 <= len(buf):
        length, kind = struct.unpack_from("=HH", buf, off)
        if length < 4:
            break
        attrs[kind & NLA_TYPE_MASK] = buf[off + 4:off + length]
        off += (length + 3) & ~3
    return attrs


def reply_tuple(payload):
    """return the protocol, source address and port of the reply tuple"""
    reply = nl_attrs(nl_attrs(payload[4:]).get(CTA_TUPLE_REPLY, b""))
    ip = nl_attrs(reply.get(CTA_TUPLE_IP, b""))
    proto = nl_attrs(reply.get(CTA_TUPLE_PROTO, b""))
    if CTA_IP_V4_SRC not in ip or CTA_PROTO_NUM not in proto or CTA_PROTO_SRC_PORT not in proto:
        return None
    return (proto[CTA_PROTO_NUM][0], socket.inet_ntoa(ip[CTA_IP_V4_SRC]),
            struct.unpack("!H", proto[CTA_PROTO_SRC_PORT])[0])


def session_key(payload):
    """return the reply destination and conntrack id"""
    attrs = nl_attrs(payload[4:])
    reply = nl_attrs(attrs.get(CTA_TUPLE_REPLY, b""))
    ip = nl_attrs(reply.get(CTA_TUPLE_IP, b""))
    proto = nl_attrs(reply.get(CTA_TUPLE_PROTO, b""))
    dst = socket.inet_ntoa(ip[CTA_IP_V4_DST]) if CTA_IP_V4_DST in ip else None
    dport = struct.unpack("!H", proto[CTA_PROTO_DST_PORT])[0] if CTA_PROTO_DST_PORT in proto else None
    ct_id = struct.unpack("!I", attrs[CTA_ID])[0] if CTA_ID in attrs else None
    return (dst, dport, ct_id)


def nl_messages(data):
    """yield each netlink message's type, flags and payload"""
    off = 0
    while off + 16 <= len(data):
        length, kind, flags = struct.unpack_from("=IHH", data, off)
        if length < 16:
            return
        yield kind, flags, data[off + 16:off + length]
        off += (length + 3) & ~3


def is_adb_session(payload):
    """check a conntrack message for the adb session"""
    return reply_tuple(payload) == (IPPROTO_TCP, ADB_GUEST_ADDR, ADB_PORT)


def is_closed(payload):
    """check a conntrack message for time_wait or close"""
    tcp = nl_attrs(nl_attrs(nl_attrs(payload[4:]).get(CTA_PROTOINFO, b"")).get(CTA_PROTOINFO_TCP, b""))
    state = tcp.get(CTA_PROTOINFO_TCP_STATE, b"")
    return len(state) == 1 and state[0] in (TCP_CONNTRACK_TIME_WAIT, TCP_CONNTRACK_CLOSE)


def event_name(kind, flags, payload):
    """return a conntrack event's name"""
    if kind == CT_DELETE:
        return "DESTROY"
    if kind != CT_NEW:
        return None
    if flags & NLM_F_CREATE:
        return "NEW"
    return "CLOSE" if is_closed(payload) else None


def conntrack_events(sock):
    """yield each adb event and its session key"""
    while True:
        try:
            data = sock.recv(65536)
        except OSError as e:
            if e.errno != errno.ENOBUFS:
                raise
            yield "OVERRUN", None
            continue
        if not data:
            return
        for kind, flags, payload in nl_messages(data):
            event = event_name(kind, flags, payload) if is_adb_session(payload) else None
            if event:
                yield event, session_key(payload)


def conntrack_sessions(sock):
    """return a table dump's open adb session keys"""
    sock.send(struct.pack("=IHHII", 20, CT_GET, NLM_F_REQUEST | NLM_F_DUMP, 1, 0) + struct.pack("=BBH", socket.AF_INET, 0, 0))
    keys = set()
    while True:
        for kind, _, payload in nl_messages(sock.recv(65536)):
            if kind == NLMSG_DONE:
                return keys
            if kind == NLMSG_ERROR:
                err = -struct.unpack_from("=i", payload)[0]
                raise OSError(err, "conntrack table dump failed: %s" % os.strerror(err))
            if kind == CT_NEW and is_adb_session(payload) and not is_closed(payload):
                keys.add(session_key(payload))


def read_table():
    """dump the conntrack table's adb session keys"""
    with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_NETFILTER) as dump:
        return conntrack_sessions(dump)


def drain(sock):
    """discard every event the socket holds"""
    while True:
        try:
            sock.recv(65536, socket.MSG_DONTWAIT)
        except BlockingIOError:
            return
        except OSError as e:
            if e.errno != errno.ENOBUFS:
                raise


def reread_table(events):
    """discard the queued events and dump the table"""
    drain(events)
    return read_table()


class Sessions:
    """Adb sessions this run counts"""

    def __init__(self, before):
        """store the table's entries at start as uncounted"""
        self.before, self.counted = set(before), set()

    def opened(self, key):
        """count an opened session"""
        self.before.discard(key)
        self.counted.add(key)

    def closed(self, key):
        """drop a session and return whether it counted"""
        self.before.discard(key)
        if key in self.counted:
            self.counted.discard(key)
            return True
        return False

    def resync(self, table):
        """count the table's entries opened since the start"""
        self.before &= table
        self.counted = table - self.before


def start_sessions(first, second):
    """return the sessions of the two start dumps"""
    sessions = Sessions(first & second)
    sessions.counted = second - first
    return sessions


def handle(event, key, sessions, idle_stop_s, read_sessions):
    """apply an event to the sessions and timer"""
    if event == "OVERRUN":
        sessions.resync(read_sessions())
        log("the conntrack event socket overran (ENOBUFS) and lost events -- "
            "re-read the table: %d session(s) opened since the start" % len(sessions.counted))
        if sessions.counted:
            cancel_timer()
        else:
            arm_timer(idle_stop_s)
    elif event == "NEW":
        sessions.opened(key)
        cancel_timer()
    elif sessions.closed(key) and not sessions.counted:
        arm_timer(idle_stop_s)


def start_line(before):
    """return the journal line for the start"""
    return ("started this run's own session count at 0 -- the %d adb entries already in the conntrack "
            "table, phantom or real, are never counted" % before)


def count_line(count, event):
    """return the journal line for an event"""
    return "count=%d %s tcp reply-src=%s:%d" % (count, event, ADB_GUEST_ADDR, ADB_PORT)


def cancel_timer():
    """stop the idle-stop timer"""
    state = subprocess.run(
        ["systemctl", "is-active", "%s.timer" % TIMER_UNIT],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.strip()
    if state != "active":
        log("no %s.timer armed (state=%s) -- nothing to cancel" % (TIMER_UNIT, state))
        return
    r = subprocess.run(["systemctl", "stop", "%s.timer" % TIMER_UNIT],
                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False)
    if r.returncode != 0:
        log("systemctl stop %s.timer failed (rc=%d): %s" %
            (TIMER_UNIT, r.returncode, r.stderr.strip()))
        return
    log("canceled the armed idle-stop timer")


def arm_timer(idle_stop_s):
    """start the idle-stop timer"""
    state = subprocess.run(
        ["systemctl", "is-active", "%s.timer" % TIMER_UNIT],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.strip()
    if state == "active":
        log("a %s.timer is already armed -- leaving its own deadline alone" % TIMER_UNIT)
        return
    subprocess.run(
        ["systemd-run", "--collect", "--on-active=%ds" % idle_stop_s,
         "--unit=%s" % TIMER_UNIT, "systemctl", "stop", ANDROIDD_UNIT],
        check=True)
    log("armed a %ds idle-stop timer (%s.timer)" % (idle_stop_s, TIMER_UNIT))


def _handle_term(signum, frame):
    """cancel the timer and exit"""
    log("received signal %d -- canceling any armed idle-stop timer before exit" % signum)
    cancel_timer()
    sys.exit(0)


def main():
    """watch adb connection events and arm the timer"""
    cancel_timer()
    signal.signal(signal.SIGTERM, _handle_term)

    policy = capabilities.policy_or_deny(
        log=lambda m: print(m, file=sys.stderr), instance_id=SANDBOX_ID)
    idle_stop_s = policy.scope("server.idle_stop_s")
    if idle_stop_s == 0:
        log("server.idle_stop_s=0 -- idle-stop is off, exiting")
        return 0
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_NETFILTER)
    sock.setsockopt(socket.SOL_SOCKET, SO_RCVBUFFORCE, RCVBUF_BYTES)
    try:
        first = read_table()
        sock.bind((0, NF_NETLINK_CONNTRACK_NEW | NF_NETLINK_CONNTRACK_UPDATE | NF_NETLINK_CONNTRACK_DESTROY))
        second = read_table()
    except OSError as e:
        log("cannot read the conntrack table at start: %s -- idle-stop is not watching" % e)
        return 1
    sessions = start_sessions(first, second)
    log(start_line(len(sessions.before)))
    if sessions.counted:
        log(count_line(len(sessions.counted), "NEW"))

    for event, key in conntrack_events(sock):
        handle(event, key, sessions, idle_stop_s, lambda: reread_table(sock))
        log(count_line(len(sessions.counted), event))
    log("the conntrack netlink socket closed -- nothing left to watch")
    return 1


if __name__ == "__main__":
    sys.exit(main())
