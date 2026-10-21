#!/usr/bin/env python3

import argparse
import json
import os
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
sys.path.insert(0, os.path.join(REPO, "src", "services", "deskbridge"))
import dbus_min

PATH = "/org/freedesktop/Notifications"
IFACE = "org.freedesktop.Notifications"
CAPABILITIES = ["actions", "body", "body-markup", "icon-static"]
SERVER_INFO = ["rhizo-notify-sink", "Rhizo", "1", "1.2"]

INTROSPECT_XML = (
    '<interface name="org.freedesktop.Notifications">'
    '<method name="Notify">'
    '<arg name="app_name" type="s" direction="in"/>'
    '<arg name="replaces_id" type="u" direction="in"/>'
    '<arg name="app_icon" type="s" direction="in"/>'
    '<arg name="summary" type="s" direction="in"/>'
    '<arg name="body" type="s" direction="in"/>'
    '<arg name="actions" type="as" direction="in"/>'
    '<arg name="hints" type="a{sv}" direction="in"/>'
    '<arg name="expire_timeout" type="i" direction="in"/>'
    '<arg name="id" type="u" direction="out"/>'
    "</method>"
    '<method name="CloseNotification">'
    '<arg name="id" type="u" direction="in"/>'
    "</method>"
    '<method name="GetCapabilities">'
    '<arg name="capabilities" type="as" direction="out"/>'
    "</method>"
    '<method name="GetServerInformation">'
    '<arg name="name" type="s" direction="out"/>'
    '<arg name="vendor" type="s" direction="out"/>'
    '<arg name="version" type="s" direction="out"/>'
    '<arg name="spec_version" type="s" direction="out"/>'
    "</method>"
    '<signal name="NotificationClosed">'
    '<arg name="id" type="u"/>'
    '<arg name="reason" type="u"/>'
    "</signal>"
    '<signal name="ActionInvoked">'
    '<arg name="id" type="u"/>'
    '<arg name="action_key" type="s"/>'
    "</signal>"
    "</interface>"
)


def encode_png(width, height, rowstride, has_alpha, n_channels, raw):
    """encode image data to PNG"""
    want_channels = 4 if has_alpha else 3
    if n_channels != want_channels:
        raise ValueError("image-data has n_channels=%d but has_alpha=%r" % (n_channels, has_alpha))
    scanlines = bytearray()
    for y in range(height):
        start = y * rowstride
        scanlines.append(0)
        scanlines += raw[start:start + width * n_channels]

    def chunk(tag, data):
        """return a PNG chunk with its length and checksum"""
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    color_type = 6 if has_alpha else 2
    ihdr = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(scanlines), 9))
        + chunk(b"IEND", b"")
    )


def decode_png(data):
    """decode a PNG file to pixel rows"""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG file")
    pos = 8
    width = height = n_channels = None
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, color_type = struct.unpack(">IIBB", body[:10])
            if depth != 8:
                raise ValueError("PNG bit depth %d is not supported by this decoder" % depth)
            n_channels = 4 if color_type == 6 else 3
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    stride = width * n_channels
    rows = []
    pos = 0
    for _ in range(height):
        filt = raw[pos]
        pos += 1
        if filt != 0:
            raise ValueError("PNG filter type %d is not supported by this decoder" % filt)
        rows.append(raw[pos:pos + stride])
        pos += stride
    return width, height, n_channels, rows


class Sink:
    def __init__(self, conn, record_path, icon_dir):
        """store the connection, record path and icon directory"""
        self.conn = conn
        self.record_path = record_path
        self.icon_dir = icon_dir
        self.next_id = 0

    def alloc_id(self):
        """return the next notification id"""
        self.next_id += 1
        return self.next_id

    def handle(self, msg):
        """answer a method call to the notification service"""
        if self.conn.handle_standard(msg):
            return
        if msg.mtype != dbus_min.METHOD_CALL:
            return
        if msg.member == "Notify":
            self.do_notify(msg)
        elif msg.member == "GetCapabilities":
            self.conn.send_reply(msg, "as", [CAPABILITIES])
        elif msg.member == "CloseNotification":
            self.do_close(msg)
        elif msg.member == "GetServerInformation":
            self.conn.send_reply(msg, "ssss", SERVER_INFO)
        else:
            self.conn.send_error(msg, "org.freedesktop.DBus.Error.UnknownMethod",
                                  "no method %s on %s" % (msg.member, IFACE))

    def do_notify(self, msg):
        """record a notification, save its image and reply with its id"""
        app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout = msg.body
        notif_id = replaces_id if replaces_id else self.alloc_id()
        record = {
            "id": notif_id,
            "app_name": app_name,
            "replaces_id": replaces_id,
            "app_icon": app_icon,
            "summary": summary,
            "body": body,
            "actions": actions,
            "hints": {},
            "expire_timeout": expire_timeout,
        }
        for key, variant in hints.items():
            if key == "image-data":
                record["hints"][key] = self.save_image(notif_id, variant.value)
            else:
                record["hints"][key] = variant.value
        with open(self.record_path, "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        self.conn.send_reply(msg, "u", [notif_id])

    def save_image(self, notif_id, value):
        """save image-data as a PNG and return its record"""
        width, height, rowstride, has_alpha, bits_per_sample, n_channels, data = value
        if bits_per_sample != 8:
            raise ValueError("image-data with %d bits per sample is not supported" % bits_per_sample)
        name = "%d.png" % notif_id
        with open(os.path.join(self.icon_dir, name), "wb") as f:
            f.write(encode_png(width, height, rowstride, has_alpha, n_channels, bytes(data)))
        return {"file": name, "width": width, "height": height}

    def do_close(self, msg):
        """reply to a close call and emit NotificationClosed"""
        notif_id = msg.body[0]
        self.conn.send_reply(msg, "", [])
        self.conn.emit_signal(PATH, IFACE, "NotificationClosed", "uu", [notif_id, 3])

    def handle_command(self, line):
        """emit ActionInvoked or NotificationClosed for a stdin line"""
        if not line:
            return False
        parts = line.split(" ", 2)
        cmd = parts[0]
        if cmd == "quit":
            return True
        if cmd == "invoke" and len(parts) >= 2:
            notif_id = int(parts[1])
            action = parts[2] if len(parts) > 2 else ""
            self.conn.emit_signal(PATH, IFACE, "ActionInvoked", "us", [notif_id, action])
            return False
        if cmd == "close" and len(parts) >= 2:
            notif_id = int(parts[1])
            reason = int(parts[2]) if len(parts) > 2 else 3
            self.conn.emit_signal(PATH, IFACE, "NotificationClosed", "uu", [notif_id, reason])
            return False
        sys.stderr.write("unknown stdin command: %r\n" % line)
        return False


def serve(record_path, icon_dir):
    """serve the notification name until stopped"""
    conn = dbus_min.Connection.connect()
    conn.hello()
    code = conn.request_name(IFACE, dbus_min.NAME_FLAG_DO_NOT_QUEUE)
    if code != dbus_min.REQUEST_NAME_REPLY_PRIMARY_OWNER:
        sys.stderr.write("could not own %s: RequestName returned %d\n" % (IFACE, code))
        return 1
    conn.register_object(PATH, INTROSPECT_XML)
    sink = Sink(conn, record_path, icon_dir)

    os.set_blocking(0, False)
    stdin_buf = bytearray()
    print("ready")
    sys.stdout.flush()

    try:
        while True:
            r, _, _ = select.select([conn.fileno(), 0], [], [])
            if conn.fileno() in r:
                for msg in conn.dispatch():
                    sink.handle(msg)
            if 0 in r:
                data = os.read(0, 4096)
                if not data:
                    return 0
                stdin_buf += data
                while b"\n" in stdin_buf:
                    nl = stdin_buf.index(b"\n")
                    line = bytes(stdin_buf[:nl]).decode("utf-8", "replace").strip()
                    del stdin_buf[:nl + 1]
                    if sink.handle_command(line):
                        return 0
    except ConnectionError as e:
        sys.stderr.write("session bus closed (%s), rhizo-notify-sink exits\n" % e)
        return 1


def _build_selftest_hints():
    """build the image-data hint used by the selftest"""
    width, height, n_channels, rowstride = 2, 2, 4, 12
    pixels = [
        (255, 0, 0, 255), (0, 255, 0, 128),
        (0, 0, 255, 64), (255, 255, 0, 0),
    ]
    raw = bytearray(b"\xaa" * (rowstride * height))
    for y in range(height):
        for x in range(width):
            r, g, b, a = pixels[y * width + x]
            off = y * rowstride + x * n_channels
            raw[off:off + 4] = bytes((r, g, b, a))
    hint = dbus_min.Variant("(iiibiiay)", (width, height, rowstride, True, 8, n_channels, list(raw)))
    return hint, width, height, n_channels, pixels


def _wait_for_signal(conn, member, timeout):
    """return the body of the next matching signal"""
    deadline = time.monotonic() + timeout
    while True:
        for msg in conn.dispatch():
            if msg.mtype == dbus_min.SIGNAL and msg.member == member:
                return msg.body
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None
        select.select([conn.fileno()], [], [], remaining)


def _verify(sink_env, record_path, icon_dir, sink_proc, checks):
    """send the selftest notifications and check the record and icons"""
    def check(ok, why):
        """record a check and print a failure message when it is false"""
        checks.append((ok, why))
        if not ok:
            sys.stderr.write("selftest FAIL: %s\n" % why)
        return ok

    conn = dbus_min.Connection.connect(sink_env["DBUS_SESSION_BUS_ADDRESS"])
    conn.hello()
    conn.add_match("type='signal',interface='%s'" % IFACE)

    summary = "héllo ☃ notify"
    body_text = "line one\nline two \U0001F600"
    actions = ["default", "Open it"]
    hint, width, height, n_channels, pixels = _build_selftest_hints()
    expire_timeout = 5000
    args = ["rhizo-selftest", 0, "", summary, body_text, actions, {"image-data": hint}, expire_timeout]
    reply = conn.call("org.freedesktop.Notifications", PATH, IFACE, "Notify", "susssasa{sv}i", args)
    notif_id = reply[0]

    with open(record_path) as f:
        lines = f.readlines()
    if not check(bool(lines), "record file has no lines"):
        return False
    record = json.loads(lines[-1])
    check(record["id"] == notif_id, "recorded id %r != returned id %r" % (record["id"], notif_id))
    check(record["app_name"] == "rhizo-selftest", "app_name mismatch: %r" % record["app_name"])
    check(record["replaces_id"] == 0, "replaces_id mismatch: %r" % record["replaces_id"])
    check(record["app_icon"] == "", "app_icon mismatch: %r" % record["app_icon"])
    check(record["summary"] == summary, "summary mismatch: %r != %r" % (record["summary"], summary))
    check(record["body"] == body_text, "body mismatch: %r != %r" % (record["body"], body_text))
    check(record["actions"] == actions, "actions mismatch: %r != %r" % (record["actions"], actions))
    check(record["expire_timeout"] == expire_timeout, "expire_timeout mismatch: %r" % record["expire_timeout"])

    img = record["hints"].get("image-data")
    if not check(bool(img) and img.get("width") == width and img.get("height") == height,
                 "image-data hint metadata wrong: %r" % img):
        return False
    with open(os.path.join(icon_dir, img["file"]), "rb") as f:
        png_bytes = f.read()
    dw, dh, dchan, rows = decode_png(png_bytes)
    if not check((dw, dh, dchan) == (width, height, n_channels),
                 "decoded PNG shape %r != %r" % ((dw, dh, dchan), (width, height, n_channels))):
        return False
    for y in range(height):
        for x in range(width):
            got = tuple(rows[y][x * n_channels:(x + 1) * n_channels])
            want = pixels[y * width + x]
            check(got == want, "pixel (%d,%d) decoded to %r, sent %r" % (x, y, got, want))

    caps = conn.call("org.freedesktop.Notifications", PATH, IFACE, "GetCapabilities", "", [])
    check(caps[0] == CAPABILITIES, "GetCapabilities returned %r" % (caps,))

    info = conn.call("org.freedesktop.Notifications", PATH, IFACE, "GetServerInformation", "", [])
    check(info == SERVER_INFO, "GetServerInformation returned %r" % (info,))

    xml = conn.call("org.freedesktop.Notifications", PATH, "org.freedesktop.DBus.Introspectable",
                     "Introspect", "", [])
    check("ActionInvoked" in xml[0] and "Notify" in xml[0], "Introspect XML is missing the interface")

    conn.call("org.freedesktop.Notifications", PATH, "org.freedesktop.DBus.Peer", "Ping", "", [])

    sink_proc.stdin.write("invoke %d default\n" % notif_id)
    sink_proc.stdin.flush()
    invoked = _wait_for_signal(conn, "ActionInvoked", 5.0)
    check(invoked == [notif_id, "default"], "ActionInvoked was %r" % (invoked,))

    close_reply = conn.call("org.freedesktop.Notifications", PATH, IFACE, "CloseNotification", "u", [notif_id])
    check(close_reply == [], "CloseNotification reply was %r" % (close_reply,))
    closed = _wait_for_signal(conn, "NotificationClosed", 5.0)
    check(closed == [notif_id, 3], "NotificationClosed was %r" % (closed,))

    return all(ok for ok, _ in checks)


def selftest():
    """run notify-sink.py on a private session bus"""
    tmp = tempfile.mkdtemp(prefix="rhizo-notify-selftest-")
    daemon = None
    sink_proc = None
    try:
        daemon = subprocess.Popen(
            ["dbus-daemon", "--session", "--print-address", "--nofork"],
            stdout=subprocess.PIPE, text=True,
        )
        addr = daemon.stdout.readline().strip()
        if not addr:
            sys.stderr.write("dbus-daemon printed no address\n")
            return 1

        env = dict(os.environ)
        env["DBUS_SESSION_BUS_ADDRESS"] = addr
        record_path = os.path.join(tmp, "record.jsonl")
        icon_dir = os.path.join(tmp, "icons")
        os.mkdir(icon_dir)

        sink_proc = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "--record", record_path, "--icon-dir", icon_dir],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, text=True,
        )
        ready = sink_proc.stdout.readline().strip()
        if ready != "ready":
            sys.stderr.write("sink did not report ready, got %r; stderr:\n%s\n" % (ready, sink_proc.stderr.read()))
            return 1

        checks = []
        ok = _verify(env, record_path, icon_dir, sink_proc, checks)
        sys.stderr.write("selftest: %d/%d checks passed\n" % (sum(1 for c, _ in checks if c), len(checks)))
        return 0 if ok else 1
    finally:
        if sink_proc is not None:
            try:
                sink_proc.stdin.write("quit\n")
                sink_proc.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
            try:
                sink_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                sink_proc.kill()
                sys.stderr.write("sink did not exit on quit, stderr:\n%s\n" % sink_proc.stderr.read())
        if daemon is not None:
            daemon.terminate()
            try:
                daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                daemon.kill()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    """parse the arguments and serve or run the selftest"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--record")
    ap.add_argument("--icon-dir")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest())

    if not args.record or not args.icon_dir:
        ap.error("--record and --icon-dir are required outside --selftest")
    sys.exit(serve(args.record, args.icon_dir))


if __name__ == "__main__":
    main()
