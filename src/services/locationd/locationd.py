#!/usr/bin/env python3
"""relay the host's GeoClue location to android's GNSS HAL over a unix socket"""
import argparse
import math
import os
import re
import select
import signal
import socket
import struct
import sys
import time

import dbus_min

SYSTEM_BUS = "unix:path=/run/dbus/system_bus_socket"
GC = "org.freedesktop.GeoClue2"
GC_MANAGER = "/org/freedesktop/GeoClue2/Manager"
GC_MANAGER_IFACE = "org.freedesktop.GeoClue2.Manager"
GC_CLIENT_IFACE = "org.freedesktop.GeoClue2.Client"
GC_LOCATION_IFACE = "org.freedesktop.GeoClue2.Location"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
BUS_NAME = "org.freedesktop.DBus"
ACCESS_DENIED = "org.freedesktop.DBus.Error.AccessDenied"
NO_GEOCLUE = ("org.freedesktop.DBus.Error.ServiceUnknown", "org.freedesktop.DBus.Error.NameHasNoOwner")
NO_REPLY = ("org.freedesktop.DBus.Error.NoReply", "org.freedesktop.DBus.Error.Timeout",
            "org.freedesktop.DBus.Error.TimedOut")
MATCHES = (
    "type='signal',sender='%s',interface='%s',member='PropertiesChanged',"
    "path_namespace='/org/freedesktop/GeoClue2/Client'" % (GC, PROPS_IFACE),
    "type='signal',sender='%s',interface='%s',member='NameOwnerChanged',arg0='%s'" % (BUS_NAME, BUS_NAME, GC),
)
DESKTOP_ID = "rhizo"
ACCURACY_EXACT = 8
GETCLIENT_TIMEOUT_S = 5
RETRY_S = 5
HAL_UID = 1021
SANDBOX_CGROUP_RE = (r"^/(rhizo(-[1-9][0-9]?)?|system\.slice/(androidd|system-androidd\.slice/androidd@[1-9][0-9]?)"
                     r"\.service/android)/(?!supervisor(/|$))")
SO_PEERPIDFD = 77
PEERCRED = struct.Struct("3i")
LINE_MAX = 512


def log(msg):
    """print a line to the log"""
    print("rhizo-locationd: " + msg, flush=True)


def proc_cgroup(pid):
    """return the unified cgroup path of a pid, or None"""
    try:
        with open("/proc/%d/cgroup" % pid) as f:
            for line in f:
                if line.startswith("0::"):
                    return line[3:].strip()
    except OSError:
        pass
    return None


def peer_verdict(conn, want_uid, cgroup_re):
    """return the peer's pid and any reason to refuse it"""
    pid, uid, _ = PEERCRED.unpack(conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, PEERCRED.size))
    if uid != want_uid:
        return pid, "uid %d is not uid %d" % (uid, want_uid)
    try:
        pidfd = conn.getsockopt(socket.SOL_SOCKET, SO_PEERPIDFD)
    except OSError as e:
        return pid, "no pidfd for it (%s)" % e.strerror
    try:
        cgroup = proc_cgroup(pid)
        waiter = select.poll()
        waiter.register(pidfd, select.POLLIN)
        exited = bool(waiter.poll(0))
    finally:
        os.close(pidfd)
    if exited:
        return pid, "it exited before its cgroup could be read"
    if cgroup is None or not cgroup_re.match(cgroup):
        return pid, "cgroup %s is not a Rhizo sandbox cgroup" % cgroup
    return pid, None


def fix_line(props):
    """return the fix line of GeoClue Location properties, or None"""
    v = {k: x.value if isinstance(x, dbus_min.Variant) else x for k, x in props.items()}
    lat, lon, acc, ts = v.get("Latitude"), v.get("Longitude"), v.get("Accuracy"), v.get("Timestamp")
    if not all(isinstance(x, float) and math.isfinite(x) for x in (lat, lon, acc)):
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180 and acc > 0 and ts and ts[0] > 0):
        return None
    parts = ["fix", "lat=%.7f" % lat, "lon=%.7f" % lon, "acc=%.2f" % (math.ceil(acc * 100) / 100)]
    alt, speed, heading = v.get("Altitude"), v.get("Speed"), v.get("Heading")
    if isinstance(alt, float) and math.isfinite(alt) and alt > -sys.float_info.max:
        parts.append("alt=%.2f" % alt)
    if isinstance(speed, float) and math.isfinite(speed) and speed >= 0:
        parts.append("speed=%.2f" % speed)
    if isinstance(heading, float) and math.isfinite(heading) and heading >= 0:
        parts.append("heading=%.1f" % heading)
    parts.append("time_ms=%d" % (ts[0] * 1000 + ts[1] // 1000))
    line = " ".join(parts)
    return line if len(line) < LINE_MAX else None


class Hal:
    """an accepted HAL connection"""

    def __init__(self, sock, pid, n):
        """keep the socket, its peer pid and its sequence number"""
        self.sock = sock
        self.pid = pid
        self.n = n
        self.buf = b""


class Relay:
    """the socket, its HAL connections and their shared GeoClue client"""

    def __init__(self, path, bus_address, peer_uid, cgroup_re):
        """start with no HAL, no bus and no client"""
        self.path = path
        self.bus_address = bus_address
        self.peer_uid = peer_uid
        self.cgroup_re = cgroup_re
        self.server = None
        self.hals = {}
        self.seq = 0
        self.bus = None
        self.pending = {}
        self.getclient = None
        self.client = None
        self.owner = None
        self.active = False
        self.phase = "idle"
        self.deadline = None
        self.status = None
        self.fixes = 0

    def listen(self):
        """bind the HAL socket"""
        if os.path.lexists(self.path):
            os.unlink(self.path)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC | socket.SOCK_NONBLOCK)
        self.server.bind(self.path)
        os.chmod(self.path, 0o666)
        self.server.listen(8)
        log("listening on %s" % self.path)

    def run(self):
        """serve until killed"""
        self.listen()
        while True:
            handlers = {self.server.fileno(): self.accept}
            for fd, hal in self.hals.items():
                handlers[fd] = lambda hal=hal: self.on_hal(hal)
            if self.bus is not None:
                handlers[self.bus.fileno()] = self.on_bus
            poller = select.poll()
            for fd in handlers:
                poller.register(fd, select.POLLIN)
            wait = None if self.deadline is None else max(0, int((self.deadline - time.monotonic()) * 1000) + 1)
            for fd, _ in poller.poll(wait):
                handlers[fd]()
            if self.deadline is not None and time.monotonic() >= self.deadline:
                self.on_deadline()

    def accept(self):
        """accept a sandboxed HAL and close other peers"""
        try:
            conn, _ = self.server.accept()
        except (BlockingIOError, InterruptedError):
            return
        try:
            pid, why = peer_verdict(conn, self.peer_uid, self.cgroup_re)
        except OSError as e:
            pid, why = 0, "no peer credentials (%s)" % e.strerror
        if why:
            log("peer refused: pid %d: %s" % (pid, why))
            conn.close()
            return
        conn.setblocking(False)
        self.seq += 1
        hal = Hal(conn, pid, self.seq)
        self.hals[conn.fileno()] = hal
        log("hal %d connected: pid %d" % (hal.n, pid))
        if len(self.hals) == 1:
            self.begin()
        elif self.status:
            self.send(hal, self.status)

    def on_hal(self, hal):
        """read a HAL's lines"""
        if self.hals.get(hal.sock.fileno()) is not hal:
            return
        try:
            data = hal.sock.recv(4096)
        except (BlockingIOError, InterruptedError):
            return
        except OSError as e:
            self.drop(hal, e.strerror)
            return
        if not data:
            self.drop(hal, "closed")
            return
        hal.buf += data
        while b"\n" in hal.buf:
            line, hal.buf = hal.buf.split(b"\n", 1)
            words = line.decode("ascii", "replace").split()
            if words and words[0] == "hello":
                fields = dict(w.split("=", 1) for w in words[1:] if "=" in w)
                log("hal %d hello v=%s interval_ms=%s" % (hal.n, fields.get("v", "?"), fields.get("interval_ms", "?")))
        if len(hal.buf) > LINE_MAX:
            self.drop(hal, "a line over %d bytes" % LINE_MAX)

    def send(self, hal, line):
        """send a line to a HAL or drop it"""
        data = (line + "\n").encode("ascii")
        try:
            sent = hal.sock.send(data)
        except OSError:
            sent = -1
        if sent != len(data):
            self.drop(hal, "not reading")

    def broadcast(self, line):
        """send a line to the HALs and keep it"""
        self.status = line
        for hal in list(self.hals.values()):
            if self.hals.get(hal.sock.fileno()) is hal:
                self.send(hal, line)

    def state(self, value, reason):
        """send a new state to the HALs"""
        line = "state value=%s reason=%s" % (value, reason)
        if line != self.status:
            log(line)
            self.broadcast(line)

    def drop(self, hal, why):
        """close a HAL connection, ending the session after the last"""
        self.hals.pop(hal.sock.fileno(), None)
        hal.sock.close()
        log("hal %d gone: %s" % (hal.n, why))
        if not self.hals:
            self.end()

    def connect(self):
        """connect to the system bus and return whether it succeeded"""
        bus = None
        try:
            bus = dbus_min.Connection.connect(self.bus_address)
            bus.hello()
            for rule in MATCHES:
                bus.add_match(rule)
        except (OSError, ValueError, dbus_min.DBusError) as e:
            log("system bus unreachable: %s" % e)
            if bus is not None:
                bus.close()
            return False
        self.bus = bus
        return True

    def lose_bus(self, why):
        """drop the bus and its state"""
        log("system bus lost: %s" % why)
        try:
            self.bus.close()
        except OSError:
            pass
        self.bus = None
        self.pending.clear()
        self.getclient = None
        self.forget()
        if self.hals:
            self.reset("unavailable", "no-bus")

    def call(self, kind, path, iface, member, signature="", args=(), client=None):
        """send a GeoClue call and record its kind and client"""
        if self.bus is None:
            return None
        try:
            serial = self.bus.call_async(GC, path, iface, member, signature, list(args))
        except OSError as e:
            self.lose_bus(str(e))
            return None
        self.pending[serial] = (kind, client or self.client)
        return serial

    def begin(self):
        """request a client from GeoClue"""
        self.deadline = None
        if self.bus is None and self.connect():
            self.on_bus()
        if self.bus is None:
            self.reset("unavailable", "no-bus")
            return
        self.phase = "getting"
        self.getclient = self.call("getclient", GC_MANAGER, GC_MANAGER_IFACE, "GetClient")
        if self.getclient is not None:
            self.deadline = time.monotonic() + GETCLIENT_TIMEOUT_S

    def start(self):
        """configure the client and start it"""
        self.phase = "starting"
        for name, sig, value in (("DesktopId", "s", DESKTOP_ID), ("RequestedAccuracyLevel", "u", ACCURACY_EXACT),
                                 ("DistanceThreshold", "u", 0), ("TimeThreshold", "u", 0)):
            self.call("set", self.client, PROPS_IFACE, "Set", "ssv",
                      (GC_CLIENT_IFACE, name, dbus_min.Variant(sig, value)))
        self.call("start", self.client, GC_CLIENT_IFACE, "Start")

    def release(self, path):
        """delete a client"""
        self.call("delete", GC_MANAGER, GC_MANAGER_IFACE, "DeleteClient", "o", (path,), client=path)

    def forget(self):
        """drop the client without a call to GeoClue"""
        self.client = None
        self.owner = None
        self.active = False

    def reset(self, value, reason):
        """drop the client, notify the HALs and schedule a retry"""
        if self.client:
            self.release(self.client)
        self.forget()
        self.state(value, reason)
        self.phase = "retry"
        self.deadline = time.monotonic() + RETRY_S

    def end(self):
        """stop and release the client once no HAL is left"""
        if self.client:
            self.call("stop", self.client, GC_CLIENT_IFACE, "Stop")
            self.release(self.client)
            log("last hal gone: client stopped and released after %d fix(es)" % self.fixes)
        self.forget()
        self.phase = "idle"
        self.deadline = None
        self.status = None
        self.fixes = 0

    def set_active(self, active):
        """follow the client's Active property"""
        if active and not self.active:
            self.active = True
            self.state("waiting", "started")
        elif not active and self.active:
            self.active = False
            self.state("denied", "revoked")

    def on_deadline(self):
        """act on a GetClient timeout or a due retry"""
        self.deadline = None
        if self.phase == "getting":
            self.state("unavailable", "no-agent")
            self.begin()
        elif self.phase == "denied":
            self.call("start", self.client, GC_CLIENT_IFACE, "Start")
            self.phase = "starting"
        elif self.phase == "retry" and self.hals:
            self.begin()

    def on_bus(self):
        """handle the bus messages"""
        if self.bus is None:
            return
        try:
            msgs = self.bus.dispatch()
        except (OSError, ValueError) as e:
            self.lose_bus(str(e))
            return
        for m in msgs:
            if self.bus is None:
                return
            if m.mtype in (dbus_min.METHOD_RETURN, dbus_min.ERROR):
                entry = self.pending.pop(m.reply_serial, None)
                if entry:
                    self.on_reply(entry[0], entry[1], m)
            elif m.mtype == dbus_min.SIGNAL:
                self.on_signal(m)
            elif m.mtype == dbus_min.METHOD_CALL and not self.bus.handle_standard(m) \
                    and not m.flags & dbus_min.FLAG_NO_REPLY_EXPECTED:
                self.bus.send_error(m, "org.freedesktop.DBus.Error.UnknownMethod", "no such method")

    def on_reply(self, kind, client, m):
        """handle the reply to a call"""
        failed = m.mtype == dbus_min.ERROR
        text = "%s: %s" % (m.error_name, m.body[0] if m.body else "") if failed else ""
        if kind == "getclient":
            if failed:
                if m.reply_serial == self.getclient and self.phase == "getting" and self.hals:
                    log("GetClient failed: %s" % text)
                    reason = ("no-geoclue" if m.error_name in NO_GEOCLUE else
                              "no-agent" if m.error_name in NO_REPLY else "dbus-error")
                    self.reset("unavailable", reason)
                return
            client = m.body[0]
            if self.client is not None or not self.hals:
                if client != self.client:
                    self.release(client)
                return
            self.client = client
            self.owner = m.sender
            self.deadline = None
            log("geoclue client %s" % client)
            self.start()
        elif client != self.client:
            if failed and kind == "delete":
                log("DeleteClient %s failed: %s" % (client, text))
        elif kind == "set" and failed:
            log("setting up %s failed: %s" % (client, text))
            self.reset("unavailable", "dbus-error")
        elif kind == "start":
            if not failed:
                self.phase = "active"
                self.set_active(True)
            elif m.error_name == ACCESS_DENIED:
                self.phase = "denied"
                self.deadline = time.monotonic() + RETRY_S
                self.state("denied", "disabled" if "disabled" in text else "refused")
                log("Start refused: %s" % text)
            else:
                log("Start failed: %s" % text)
                self.reset("unavailable", "dbus-error")
        elif kind == "getall":
            if failed:
                log("reading a location failed: %s" % text)
                return
            line = fix_line(m.body[0])
            if line is None:
                log("fix dropped: GeoClue gave no usable latitude, longitude, accuracy or timestamp")
                return
            if not self.fixes:
                log("first fix: accuracy %s m" % line.split("acc=", 1)[1].split()[0])
            self.fixes += 1
            self.broadcast(line)

    def on_signal(self, m):
        """handle a signal from GeoClue or the bus"""
        if m.sender == BUS_NAME and m.member == "NameOwnerChanged":
            if len(m.body) == 3 and m.body[0] == GC and not m.body[2] and self.client:
                log("geoclue left the bus")
                self.forget()
                self.reset("unavailable", "no-geoclue")
            return
        if not self.client or m.path != self.client or m.sender != self.owner:
            return
        if m.interface == PROPS_IFACE and m.member == "PropertiesChanged" and len(m.body) >= 2:
            if m.body[0] == GC_CLIENT_IFACE and "Active" in m.body[1]:
                self.set_active(bool(m.body[1]["Active"].value))
        elif m.interface == GC_CLIENT_IFACE and m.member == "LocationUpdated" and len(m.body) == 2:
            if m.body[1] != "/":
                self.call("getall", m.body[1], PROPS_IFACE, "GetAll", "s", (GC_LOCATION_IFACE,))


def main(argv=None):
    """parse arguments and serve"""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--bus", default=SYSTEM_BUS, help=argparse.SUPPRESS)
    parser.add_argument("--peer-uid", type=int, default=HAL_UID, help=argparse.SUPPRESS)
    parser.add_argument("--peer-cgroup", default=SANDBOX_CGROUP_RE, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if (args.bus, args.peer_uid, args.peer_cgroup) != (SYSTEM_BUS, HAL_UID, SANDBOX_CGROUP_RE):
        log("test override: bus %s, peers uid %d in cgroups matching %s" % (args.bus, args.peer_uid, args.peer_cgroup))
    # a stop through `systemctl mask --now` keeps the runtime directory
    signal.signal(signal.SIGTERM, lambda *_: (os.path.lexists(args.socket) and os.unlink(args.socket), os._exit(0)))
    Relay(args.socket, args.bus, args.peer_uid, re.compile(args.peer_cgroup)).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
