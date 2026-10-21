#!/usr/bin/env python3
import argparse
import ctypes
import json
import os
import select
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dbus_min  # noqa: E402

IFACE = "org.freedesktop.Notifications"
OBJECT = "/org/freedesktop/Notifications"
SIGNALS = ("ActionInvoked", "NotificationClosed", "ActivationToken")
LINE_MAX = 1 << 20
KEY_MAX = 1024
ERROR_MAX = 1024
UINT32_LIMIT = 1 << 32
EXIT_REFUSED = 3
IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_DELETE_SELF = 0x00000400
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
PEERCRED = struct.Struct("3i")


class BusClosed(Exception):
    """Session bus connection that ended"""


def log(msg):
    """write a timestamped message to stderr"""
    sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def attach_bus():
    """connect to the session bus and match the notification signals"""
    bus = dbus_min.Connection.connect()
    try:
        bus.hello()
        for member in SIGNALS:
            bus.add_match("type='signal',interface='%s',member='%s'" % (IFACE, member))
    except (OSError, ValueError, dbus_min.DBusError):
        bus.close()
        raise
    return bus


class DirWatch:
    """inotify watch on the socket's directory"""

    def __init__(self, path):
        """watch path's directory for entries coming and going"""
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.fd = self.libc.inotify_init1(0o2000000)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1")
        mask = IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVED_FROM | IN_MOVED_TO
        if self.libc.inotify_add_watch(self.fd, os.path.dirname(path).encode(), mask) < 0:
            err = ctypes.get_errno()
            os.close(self.fd)
            raise OSError(err, "inotify_add_watch %s: %s" % (os.path.dirname(path), os.strerror(err)))

    def wait(self):
        """block until the directory changes"""
        os.read(self.fd, 65536)

    def close(self):
        """close the inotify descriptor"""
        os.close(self.fd)


def connect_deskd(path):
    """connect to rhizo-deskd's socket and check its uid"""
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.connect(path)
        _pid, uid, _gid = PEERCRED.unpack(conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, PEERCRED.size))
    except OSError:
        conn.close()
        raise
    if uid != os.getuid():
        conn.close()
        raise PermissionError("%s is served by uid %d, this process runs as uid %d" % (path, uid, os.getuid()))
    return conn


def send(conn, obj):
    """write a JSON line to rhizo-deskd"""
    conn.sendall(json.dumps(obj, separators=(",", ":")).encode("utf-8") + b"\n")


def forward_signals(conn, msgs):
    """send the notification signals to rhizo-deskd"""
    for msg in msgs:
        if msg.interface != IFACE:
            continue
        if msg.member == "ActionInvoked":
            send(conn, {"t": "action", "id": msg.body[0], "action": msg.body[1]})
        elif msg.member == "NotificationClosed":
            send(conn, {"t": "closed", "id": msg.body[0]})
        elif msg.member == "ActivationToken":
            send(conn, {"t": "token", "id": msg.body[0], "token": msg.body[1]})


def bus_call(bus, member, signature, args):
    """call a notification method"""
    try:
        return bus.call(IFACE, OBJECT, IFACE, member, signature, args)
    except (ConnectionError, ValueError) as exc:
        raise BusClosed("%s: %s" % (type(exc).__name__, exc)) from exc


def bus_signals(bus):
    """return the queued bus messages"""
    try:
        return bus.dispatch()
    except (ConnectionError, ValueError) as exc:
        raise BusClosed("%s: %s" % (type(exc).__name__, exc)) from exc


def notify(bus, conn, msg):
    """call Notify for a request and send the result"""
    hints = {name: dbus_min.Variant("s", value) for name, value in msg["hints"].items()}
    try:
        body = bus_call(bus, "Notify", "susssasa{sv}i",
                        ["Rhizo", msg["replaces"], "", msg["title"], msg["body"], msg["actions"], hints, -1])
    except (dbus_min.DBusError, TimeoutError) as exc:
        send(conn, {"t": "notify_failed", "key": msg["key"], "error": error_text(exc)})
        return
    send(conn, {"t": "notified", "key": msg["key"], "id": body[0]})


def error_text(exc):
    """return an exception as a bounded error string"""
    return ("%s: %s" % (type(exc).__name__, exc))[:ERROR_MAX]


def uint32(value):
    """check that a value is a uint32"""
    if type(value) is not int or not 0 <= value < UINT32_LIMIT:
        raise ValueError("%r is not a uint32" % (value,))
    return value


def check_request(msg):
    """check a request and return its type"""
    kind = msg["t"]
    if kind == "notify":
        texts = [msg["key"], msg["title"], msg["body"], *msg["actions"], *msg["hints"].keys(), *msg["hints"].values()]
        for text in texts:
            if not isinstance(text, str):
                raise TypeError("notify field %r is not a string" % (text,))
            if "\x00" in text:
                raise ValueError("notify field %r holds a NUL" % text[:80])
            text.encode("utf-8")
        uint32(msg["replaces"])
    elif kind == "close":
        uint32(msg["id"])
    elif kind == "refused":
        str(msg["reason"])
    else:
        raise ValueError("unknown request type %r" % (kind,))
    return kind


def request_key(msg):
    """return a request's notification key, or an empty string"""
    key = msg.get("key") if isinstance(msg, dict) else None
    return key[:KEY_MAX] if isinstance(key, str) else ""


def handle_line(bus, conn, line):
    """act on a request line from rhizo-deskd"""
    msg = None
    try:
        msg = json.loads(line.decode("utf-8"))
        kind = check_request(msg)
    except (ValueError, KeyError, TypeError, AttributeError, RecursionError) as exc:
        log("rhizo-deskd sent a malformed request, dropped: %s" % error_text(exc))
        send(conn, {"t": "notify_failed", "key": request_key(msg), "error": "malformed request: " + error_text(exc)})
        return
    if kind == "notify":
        notify(bus, conn, msg)
    elif kind == "close":
        close_notification(bus, msg)
    else:
        raise PermissionError("rhizo-deskd refused this relay: %s" % msg["reason"])


def close_notification(bus, msg):
    """call CloseNotification for a request"""
    try:
        bus_call(bus, "CloseNotification", "u", [msg["id"]])
    except (dbus_min.DBusError, TimeoutError) as exc:
        log("CloseNotification for id %d failed: %s: %s" % (msg["id"], type(exc).__name__, exc))


def serve(bus, conn, address):
    """relay between rhizo-deskd and the session bus"""
    send(conn, {"t": "hello", "bus": address, "name": bus.unique_name})
    buf = bytearray()
    skipping = False
    while True:
        readable = select.select([conn, bus.fileno()], [], [])[0]
        if bus.fileno() in readable:
            forward_signals(conn, bus_signals(bus))
        if conn not in readable:
            continue
        data = conn.recv(65536)
        if not data:
            return "rhizo-deskd closed the connection"
        buf += data
        while b"\n" in buf:
            line, _, rest = bytes(buf).partition(b"\n")
            buf = bytearray(rest)
            if skipping:
                skipping = False
                continue
            handle_line(bus, conn, line)
            forward_signals(conn, bus_signals(bus))
        if len(buf) > LINE_MAX:
            if not skipping:
                log("a line from rhizo-deskd is over %d bytes, dropped" % LINE_MAX)
                send(conn, {"t": "notify_failed", "key": "", "error": "a request over %d bytes was dropped" % LINE_MAX})
            skipping = True
            buf.clear()


def main():
    """attach the session bus and serve rhizo-deskd's socket"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    args = ap.parse_args()
    address = os.environ.get("DBUS_SESSION_BUS_ADDRESS")
    if not address:
        log("no DBUS_SESSION_BUS_ADDRESS in the user session, nothing to relay")
        return 1
    try:
        bus = attach_bus()
    except (OSError, ValueError, dbus_min.DBusError) as exc:
        log("session bus %s not attached: %s: %s" % (address, type(exc).__name__, exc))
        return 1
    log("session bus %s attached as %s" % (address, bus.unique_name))
    while True:
        try:
            watch = DirWatch(args.socket)
        except (FileNotFoundError, NotADirectoryError):
            log("%s is gone, rhizo-deskd is not serving notifications" % os.path.dirname(args.socket))
            return 0
        except OSError as exc:
            log("cannot watch %s for rhizo-deskd's socket: %s" % (os.path.dirname(args.socket), exc))
            return 1
        try:
            conn = connect_deskd(args.socket)
        except (FileNotFoundError, NotADirectoryError):
            log("%s is gone, rhizo-deskd is not serving notifications" % args.socket)
            watch.close()
            return 0
        except ConnectionRefusedError:
            watch.wait()
            watch.close()
            continue
        except PermissionError as exc:
            log("%s" % exc)
            watch.close()
            return EXIT_REFUSED
        watch.close()
        log("connected to rhizo-deskd at %s" % args.socket)
        try:
            why = serve(bus, conn, address)
        except PermissionError as exc:
            log("%s" % exc)
            return EXIT_REFUSED
        except BusClosed as exc:
            log("session bus %s closed (%s), the relay ends with the session" % (address, exc))
            return 0
        except (ConnectionResetError, BrokenPipeError) as exc:
            why = "rhizo-deskd's connection broke: %s" % exc
        except (ValueError, KeyError, TypeError) as exc:
            log("rhizo-deskd sent a malformed request: %s: %s" % (type(exc).__name__, exc))
            return 1
        finally:
            conn.close()
        log(why)


if __name__ == "__main__":
    sys.exit(main())
