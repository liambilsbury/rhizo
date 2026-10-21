#!/usr/bin/env python3
"""Run GNOME's D-Bus calls for the system tests"""
import argparse
import io
import json
import os
import re
import sys
import tempfile
import time

USAGE = """Usage:
  gnome-harness.py ping
  gnome-harness.py shot OUT.png [x y w h] [--output NAME]
  gnome-harness.py pointer abs X Y | rel DX DY | btn CODE 0|1 | axis h|v VALUE
                          | drag SX SY DX DY
  gnome-harness.py pointer-session   stdin: press X Y | moveto X Y | abs X Y | release | quit
  gnome-harness.py key single CODE 0|1 | chord CODE [CODE...]
  gnome-harness.py windows
  gnome-harness.py window-op ID fullscreen|unfullscreen|maximize|unmaximize|
                             move X Y|resize W H|to_monitor NAME|activate|close|above
  gnome-harness.py outputs list|remove NAME|add WxH|scale NAME N
  gnome-harness.py seat-devices
  gnome-harness.py notifications list|activate ID [KEY]
  gnome-harness.py --selftest"""

_HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(_HERE)))
sys.path[:0] = [_HERE, os.path.join(_HERE, "..", "..", "..", "src", "services", "deskbridge")]
import dbus_min  # noqa: E402

HARNESS_DEST = "org.rhizo.Harness"
HARNESS_PATH = "/org/rhizo/Harness"
HARNESS_IFACE = "org.rhizo.Harness"

SHELL_DEST = "org.gnome.Shell"
SCREENSHOT_PATH = "/org/gnome/Shell/Screenshot"
SCREENSHOT_IFACE = "org.gnome.Shell.Screenshot"
SCREENSHOT_OWN_NAME = "org.gnome.Screenshot"

RD_DEST = "org.gnome.Mutter.RemoteDesktop"
RD_PATH = "/org/gnome/Mutter/RemoteDesktop"
RD_IFACE = "org.gnome.Mutter.RemoteDesktop"
RD_SESSION_IFACE = "org.gnome.Mutter.RemoteDesktop.Session"

SC_DEST = "org.gnome.Mutter.ScreenCast"
SC_PATH = "/org/gnome/Mutter/ScreenCast"
SC_IFACE = "org.gnome.Mutter.ScreenCast"
SC_SESSION_IFACE = "org.gnome.Mutter.ScreenCast.Session"

DC_DEST = "org.gnome.Mutter.DisplayConfig"
DC_PATH = "/org/gnome/Mutter/DisplayConfig"
DC_IFACE = "org.gnome.Mutter.DisplayConfig"

PROPS_IFACE = "org.freedesktop.DBus.Properties"

METHOD_VERIFY, METHOD_TEMPORARY, METHOD_PERSISTENT = 0, 1, 2

STATE_SIG = "ua((ssss)a(siiddada{sv})a{sv})a(iiduba(ssss)a{sv})a{sv}"
APPLY_MONITORS_SIG = "uua(iiduba(ssa{sv}))a{sv}"


def _prop(props, key):
    """return a property value, unwrapping a D-Bus variant"""
    value = props.get(key)
    return value.value if isinstance(value, dbus_min.Variant) else value


def current_modes(monitors):
    """return the current mode of each connector"""
    out = {}
    for spec, modes, _props in monitors:
        for mode_id, w, h, refresh, _pref, _scales, mode_props in modes:
            if _prop(mode_props, "is-current"):
                out[spec[0]] = (mode_id, w, h, refresh)
    return out


def logical_layout(state):
    """return a dict per logical monitor"""
    _serial, monitors, logical_monitors, _props = state
    modes = current_modes(monitors)
    out = []
    for x, y, scale, transform, primary, specs, _lprops in logical_monitors:
        if not specs:
            continue
        connector = specs[0][0]
        mode_id, w, h, refresh = modes.get(connector, ("", 0, 0, 0.0))
        out.append({"connector": connector, "x": x, "y": y, "scale": scale,
                    "transform": transform, "primary": primary, "mode_id": mode_id,
                    "mode_w": w, "mode_h": h, "refresh": refresh,
                    "w": int(w / scale) if scale else 0, "h": int(h / scale) if scale else 0})
    return out


def apply_entry(lm, **change):
    """return a logical monitor in ApplyMonitorsConfig form"""
    lm = dict(lm, **change)
    return (lm["x"], lm["y"], lm["scale"], lm["transform"], lm["primary"],
            [(lm["connector"], lm["mode_id"], {})])


def dbus_get_prop(conn, dest, path, iface, prop):
    """return the value of a D-Bus property"""
    (variant,) = conn.call(dest, path, PROPS_IFACE, "Get", "ss", [iface, prop])
    return variant.value



def rd_create_session(conn, start=True):
    """create a RemoteDesktop session and return its path"""
    (session_path,) = conn.call(RD_DEST, RD_PATH, RD_IFACE, "CreateSession", "", [])
    if start:
        conn.call(RD_DEST, session_path, RD_SESSION_IFACE, "Start", "", [])
    return session_path


def rd_stop(conn, session_path):
    """stop a RemoteDesktop session"""
    conn.call(RD_DEST, session_path, RD_SESSION_IFACE, "Stop", "", [])


def rd_stream_session(conn, connectors):
    """create a RemoteDesktop session with ScreenCast streams"""
    session_path = rd_create_session(conn, start=False)
    try:
        session_id = dbus_get_prop(conn, RD_DEST, session_path, RD_SESSION_IFACE, "SessionId")
        props = {"remote-desktop-session-id": dbus_min.Variant("s", session_id)}
        (sc_session_path,) = conn.call(SC_DEST, SC_PATH, SC_IFACE, "CreateSession", "a{sv}", [props])
        streams = {}
        for connector in connectors:
            (streams[connector],) = conn.call(SC_DEST, sc_session_path, SC_SESSION_IFACE,
                                              "RecordMonitor", "sa{sv}", [connector, {}])
        conn.call(RD_DEST, session_path, RD_SESSION_IFACE, "Start", "", [])
    except Exception:
        rd_stop(conn, session_path)
        raise
    return session_path, streams


def stream_point(layout, x, y):
    """return the stream point for a global position"""
    hit = next((lm for lm in layout
                if lm["x"] <= x < lm["x"] + lm["w"] and lm["y"] <= y < lm["y"] + lm["h"]), layout[0])
    return hit["connector"], float(x - hit["x"]), float(y - hit["y"])



LANDING_DEADLINE_S = 2.0


def _assert_pointer_at(conn, x, y, tolerance=1.0):
    """check the pointer position with GetPointer"""
    deadline = time.monotonic() + LANDING_DEADLINE_S
    while True:
        (pointer_json,) = conn.call(HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "GetPointer", "", [])
        pos = json.loads(pointer_json)
        if abs(pos["x"] - x) <= tolerance and abs(pos["y"] - y) <= tolerance:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("pointer landed at (%s, %s), wanted (%s, %s) within %s" %
                                (pos["x"], pos["y"], x, y, tolerance))
        time.sleep(0.02)


def cmd_pointer_abs(conn, x, y):
    """move the pointer to an absolute position"""
    try:
        layout = logical_layout(get_state(conn))
        if not layout:
            raise RuntimeError("GetCurrentState reported no logical monitors at all")
        connector, sx, sy = stream_point(layout, x, y)
        rd_path, streams = rd_stream_session(conn, [connector])
        try:
            conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerMotionAbsolute",
                      "sdd", [streams[connector], sx, sy])
        finally:
            rd_stop(conn, rd_path)
        _assert_pointer_at(conn, x, y)
        return
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("pointer abs: stream-based absolute motion failed (%s) "
                          "-- falling back to a relative slam-to-corner\n" % e)
    rd_path = rd_create_session(conn)
    try:
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerMotionRelative",
                  "dd", [-1e6, -1e6])
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerMotionRelative",
                  "dd", [float(x), float(y)])
    finally:
        rd_stop(conn, rd_path)
    _assert_pointer_at(conn, x, y)


def cmd_pointer_drag(conn, sx, sy, dx, dy):
    """drag the pointer between two positions"""
    layout = logical_layout(get_state(conn))
    if not layout:
        raise RuntimeError("GetCurrentState reported no logical monitors at all")
    src = stream_point(layout, sx, sy)
    dst = stream_point(layout, dx, dy)
    rd_path, streams = rd_stream_session(conn, sorted({src[0], dst[0]}))
    try:
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerMotionAbsolute",
                  "sdd", [streams[src[0]], src[1], src[2]])
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerButton", "ib", [272, True])
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerMotionAbsolute",
                  "sdd", [streams[dst[0]], dst[1], dst[2]])
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerButton", "ib", [272, False])
    finally:
        rd_stop(conn, rd_path)
    _assert_pointer_at(conn, dx, dy)


class PointerSession:
    """pointer input through a RemoteDesktop session"""

    STEPS = 6

    def __init__(self, conn):
        """open a RemoteDesktop session with a stream per logical monitor"""
        self.conn = conn
        self.layout = logical_layout(get_state(conn))
        if not self.layout:
            raise RuntimeError("GetCurrentState reported no logical monitors at all")
        self.rd, self.streams = rd_stream_session(conn, [lm["connector"] for lm in self.layout])
        self.pressed = False

    def _abs(self, x, y):
        """move the pointer to an absolute point and check where it landed"""
        connector, sx, sy = stream_point(self.layout, x, y)
        self.conn.call(RD_DEST, self.rd, RD_SESSION_IFACE, "NotifyPointerMotionAbsolute",
                       "sdd", [self.streams[connector], sx, sy])
        _assert_pointer_at(self.conn, x, y)

    def moveto(self, x, y):
        """move the pointer to a point in steps from its current position"""
        (pointer_json,) = self.conn.call(HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "GetPointer", "", [])
        start = json.loads(pointer_json)
        for i in range(1, self.STEPS + 1):
            self._abs(round(start["x"] + (x - start["x"]) * i / self.STEPS),
                      round(start["y"] + (y - start["y"]) * i / self.STEPS))

    def button(self, down):
        """press or release the primary button"""
        self.conn.call(RD_DEST, self.rd, RD_SESSION_IFACE, "NotifyPointerButton", "ib", [272, down])
        self.pressed = down

    def handle(self, line):
        """return the result line for a command"""
        words = line.split()
        verb, args = (words[0], words[1:]) if words else ("", [])
        if verb in ("press", "moveto", "abs") and len(args) == 2:
            x, y = int(float(args[0])), int(float(args[1]))
            if verb == "moveto":
                self.moveto(x, y)
                return "movedto %d %d" % (x, y)
            self._abs(x, y)
            if verb == "abs":
                return "moved %d %d" % (x, y)
            self.button(True)
            return "pressed %d %d" % (x, y)
        if verb == "release" and not args:
            self.button(False)
            return "released"
        raise ValueError("unknown command %r (press X Y | moveto X Y | abs X Y | release | quit)" % line)

    def close(self):
        """release a held button and stop the session"""
        try:
            if self.pressed:
                self.button(False)
        finally:
            rd_stop(self.conn, self.rd)


def cmd_pointer_session(conn, stdin=None, stdout=None):
    """run pointer session commands from stdin"""
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    session = PointerSession(conn)
    try:
        print("ready", file=stdout, flush=True)
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            if line == "quit":
                break
            try:
                answer = session.handle(line)
            except Exception as e:  # noqa: BLE001
                answer = "error %s: %s" % (line.split()[0], e)
            print(answer, file=stdout, flush=True)
    finally:
        session.close()


def cmd_pointer_rel(conn, dx, dy):
    """send a relative pointer motion in a new session"""
    rd_path = rd_create_session(conn)
    try:
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerMotionRelative",
                  "dd", [float(dx), float(dy)])
    finally:
        rd_stop(conn, rd_path)


def cmd_pointer_btn(conn, code, state):
    """send a pointer button event in a new session"""
    rd_path = rd_create_session(conn)
    try:
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerButton",
                  "ib", [int(code), bool(int(state))])
    finally:
        rd_stop(conn, rd_path)


def cmd_pointer_axis(conn, axis, value):
    """send a pointer scroll event on an axis in a new session"""
    dx, dy = (float(value), 0.0) if axis == "h" else (0.0, float(value))
    rd_path = rd_create_session(conn)
    try:
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyPointerAxis",
                  "ddu", [dx, dy, 0])
    finally:
        rd_stop(conn, rd_path)


def cmd_key(conn, code, state):
    """send a key press or release in a new session"""
    rd_path = rd_create_session(conn)
    try:
        conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyKeyboardKeycode",
                  "ub", [int(code), bool(int(state))])
    finally:
        rd_stop(conn, rd_path)


def cmd_key_chord(conn, codes):
    """press and release a chord of key codes"""
    rd_path = rd_create_session(conn)
    try:
        for code in codes:
            conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyKeyboardKeycode", "ub", [int(code), True])
        for code in reversed(codes):
            conn.call(RD_DEST, rd_path, RD_SESSION_IFACE, "NotifyKeyboardKeycode", "ub", [int(code), False])
    finally:
        rd_stop(conn, rd_path)



def _output_rect(conn, connector):
    """return the logical rect of a connector"""
    for lm in logical_layout(get_state(conn)):
        if lm["connector"] == connector:
            return int(lm["x"]), int(lm["y"]), lm["w"], lm["h"]
    raise RuntimeError("shot --output %s: no active logical monitor uses that connector" % connector)


def cmd_shot(conn, out_path, region, output=None):
    """write a screenshot to out_path"""
    code = conn.request_name(SCREENSHOT_OWN_NAME, dbus_min.NAME_FLAG_DO_NOT_QUEUE)
    if code != dbus_min.REQUEST_NAME_REPLY_PRIMARY_OWNER:
        raise RuntimeError("could not own %s: RequestName returned %d "
                            "(another gnome-harness.py running concurrently?)" % (SCREENSHOT_OWN_NAME, code))
    try:
        os.unlink(out_path)
    except FileNotFoundError:
        pass
    if output:
        x, y, w, h = _output_rect(conn, output)
        ok, filename = conn.call(SHELL_DEST, SCREENSHOT_PATH, SCREENSHOT_IFACE, "ScreenshotArea",
                                  "iiiibs", [x, y, w, h, False, out_path])
    elif region:
        x, y, w, h = region
        ok, filename = conn.call(SHELL_DEST, SCREENSHOT_PATH, SCREENSHOT_IFACE, "ScreenshotArea",
                                  "iiiibs", [x, y, w, h, False, out_path])
    else:
        ok, filename = conn.call(SHELL_DEST, SCREENSHOT_PATH, SCREENSHOT_IFACE, "Screenshot",
                                  "bbs", [False, False, out_path])
    if not ok:
        raise RuntimeError("gnome-shell reported a screenshot failure for %s" % out_path)
    if filename != out_path:
        raise RuntimeError("gnome-shell wrote %r, asked for %r" % (filename, out_path))
    try:
        size = os.path.getsize(out_path)
    except OSError as e:
        raise RuntimeError("screenshot reported success but %s is not readable: %s" % (out_path, e))
    if size <= 0:
        raise RuntimeError("screenshot at %s is empty (0 bytes)" % out_path)
    return filename



def cmd_ping(conn):
    """return the harness's ping reply"""
    (info,) = conn.call(HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "Ping", "", [])
    return info


def cmd_windows(conn):
    """return the harness's window list"""
    (windows_json,) = conn.call(HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "GetWindows", "", [])
    return json.loads(windows_json)


def cmd_window_op(conn, win_id, op, args):
    """run an operation on a window through the harness"""
    conn.call(HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "WindowOp",
              "uss", [int(win_id), op, json.dumps(args)])


def cmd_seat_devices(conn):
    """return the harness's seat device list"""
    (devices_json,) = conn.call(HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "GetSeatDevices", "", [])
    return json.loads(devices_json)


def cmd_notifications_list(conn):
    """return the harness's notification list"""
    (notifs_json,) = conn.call(HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "GetNotifications", "", [])
    return json.loads(notifs_json)


def cmd_notifications_activate(conn, notif_id, key="default"):
    """activate the notification action named key"""
    (invoked,) = conn.call(HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "ActivateNotification", "ss",
                           [notif_id, key])
    if not invoked:
        raise RuntimeError("notification %s: action '%s' was not invoked" % (notif_id, key))
    if key == "default":
        remaining = cmd_notifications_list(conn)
        if any(n.get("id") == notif_id for n in remaining):
            raise RuntimeError("notification %s is still listed after activation -- expected it to be withdrawn" % notif_id)
    return invoked



def get_state(conn):
    """return the display configuration's current state"""
    return conn.call(DC_DEST, DC_PATH, DC_IFACE, "GetCurrentState", "", [])


def state_to_json(state):
    """convert a GetCurrentState reply to output JSON"""
    return [{
        "name": lm["connector"],
        "active": True,
        "primary": lm["primary"],
        "scale": lm["scale"],
        "rect": {"x": lm["x"], "y": lm["y"], "width": lm["w"], "height": lm["h"]},
        "current_mode": {"width": lm["mode_w"], "height": lm["mode_h"], "refresh": lm["refresh"]},
    } for lm in logical_layout(state)]


def _poll_state_until(conn, predicate, deadline_s=5.0, interval_s=0.25):
    """poll GetCurrentState and return the matching state"""
    deadline = time.monotonic() + deadline_s
    while True:
        state = get_state(conn)
        if predicate(state):
            return state
        if time.monotonic() >= deadline:
            return None
        time.sleep(interval_s)


def apply_monitors(conn, serial, logical_monitors):
    """send ApplyMonitorsConfig to mutter"""
    conn.call(DC_DEST, DC_PATH, DC_IFACE, "ApplyMonitorsConfig", APPLY_MONITORS_SIG,
              [serial, METHOD_TEMPORARY, logical_monitors, {}])


def cmd_outputs_add(conn, size):
    """add a virtual monitor to the layout"""
    w, h = (int(v) for v in size.split("x"))
    state = get_state(conn)
    serial, monitors, _logical_monitors, _props = state
    layout = logical_layout(state)
    used = {lm["connector"] for lm in layout}
    connector = mode_id = None
    for spec, modes, _mprops in monitors:
        if spec[0] in used:
            continue
        for mid, mw, mh, *_rest in modes:
            if mw == w and mh == h:
                connector, mode_id = spec[0], mid
                break
        if connector:
            break
    if connector is None:
        raise RuntimeError(
            "outputs add %dx%d: no unused virtual monitor offers that mode" % (w, h))

    maxx = int(max((lm["x"] + lm["w"] for lm in layout), default=0))
    new_logical = [apply_entry(lm) for lm in layout] + [(maxx, 0, 1.0, 0, False, [(connector, mode_id, {})])]
    apply_monitors(conn, serial, new_logical)

    def connector_present(state):
        """return whether the connector is in the logical layout"""
        return any(lm["connector"] == connector for lm in logical_layout(state))

    if _poll_state_until(conn, connector_present) is None:
        raise RuntimeError("outputs add %s: ApplyMonitorsConfig did not bring %s into the "
                            "logical layout within 5s" % (size, connector))
    return connector


def cmd_outputs_remove(conn, name):
    """remove a connector's logical monitor"""
    state = get_state(conn)
    layout = logical_layout(state)
    kept = [apply_entry(lm) for lm in layout if lm["connector"] != name]
    if len(kept) == len(layout):
        raise RuntimeError("outputs remove %s: no active logical monitor uses that connector" % name)
    apply_monitors(conn, state[0], kept)

    def connector_absent(state):
        """return whether the connector is absent from the logical layout"""
        return not any(lm["connector"] == name for lm in logical_layout(state))

    if _poll_state_until(conn, connector_absent) is None:
        raise RuntimeError("outputs remove %s: ApplyMonitorsConfig did not remove it from the "
                            "logical layout within 5s" % name)


def cmd_outputs_scale(conn, name, scale):
    """set the scale of a connector's logical monitor"""
    state = get_state(conn)
    layout = logical_layout(state)
    if not any(lm["connector"] == name for lm in layout):
        raise RuntimeError("outputs scale %s: no active logical monitor uses that connector" % name)
    new_logical = [apply_entry(lm, scale=float(scale)) if lm["connector"] == name else apply_entry(lm)
                   for lm in layout]
    apply_monitors(conn, state[0], new_logical)

    target = float(scale)

    def scale_applied(state):
        """return whether the connector has the requested scale"""
        return any(lm["connector"] == name and abs(lm["scale"] - target) < 1e-6
                   for lm in logical_layout(state))

    if _poll_state_until(conn, scale_applied) is None:
        raise RuntimeError("outputs scale %s %s: ApplyMonitorsConfig did not apply the new "
                            "scale within 5s" % (name, scale))



def connect():
    """connect to the session bus and say hello"""
    conn = dbus_min.Connection.connect()
    conn.hello()
    return conn


def main_run(args):
    """run the command named in args"""
    conn = connect()
    if args.cmd == "ping":
        print(cmd_ping(conn))
    elif args.cmd == "shot":
        region = tuple(args.region) if args.region else None
        filename = cmd_shot(conn, args.out, region, args.output)
        print(filename)
    elif args.cmd == "pointer":
        if args.pointer_verb == "abs":
            cmd_pointer_abs(conn, args.x, args.y)
        elif args.pointer_verb == "rel":
            cmd_pointer_rel(conn, args.dx, args.dy)
        elif args.pointer_verb == "btn":
            cmd_pointer_btn(conn, args.code, args.state)
        elif args.pointer_verb == "axis":
            cmd_pointer_axis(conn, args.axis, args.value)
        elif args.pointer_verb == "drag":
            cmd_pointer_drag(conn, args.sx, args.sy, args.dx, args.dy)
    elif args.cmd == "pointer-session":
        cmd_pointer_session(conn)
    elif args.cmd == "key":
        if args.key_verb == "chord":
            cmd_key_chord(conn, args.codes)
        elif args.key_verb == "single":
            cmd_key(conn, args.code, args.state)
    elif args.cmd == "windows":
        for w in cmd_windows(conn):
            print(json.dumps(w))
    elif args.cmd == "window-op":
        op_args = {}
        if args.op == "move":
            op_args = {"x": int(args.a), "y": int(args.b)}
        elif args.op == "resize":
            op_args = {"w": int(args.a), "h": int(args.b)}
        elif args.op == "to_monitor":
            op_args = {"monitor": args.a}
        cmd_window_op(conn, args.id, args.op, op_args)
    elif args.cmd == "seat-devices":
        print(json.dumps(cmd_seat_devices(conn)))
    elif args.cmd == "notifications":
        if args.notif_verb == "list":
            for n in cmd_notifications_list(conn):
                print(json.dumps(n))
        elif args.notif_verb == "activate":
            cmd_notifications_activate(conn, args.id, args.key)
            print("invoked=%s" % args.key)
    elif args.cmd == "outputs":
        if args.outputs_verb == "list":
            print(json.dumps(state_to_json(get_state(conn))))
        elif args.outputs_verb == "add":
            print(cmd_outputs_add(conn, args.size))
        elif args.outputs_verb == "remove":
            cmd_outputs_remove(conn, args.name)
        elif args.outputs_verb == "scale":
            cmd_outputs_scale(conn, args.name, args.n)
    else:
        raise AssertionError("unhandled cmd %r" % args.cmd)
    return 0


def build_parser():
    """build the argument parser"""
    ap = argparse.ArgumentParser(description=__doc__ + "\n\n" + USAGE, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true")
    sub = ap.add_subparsers(dest="cmd")

    sub.add_parser("ping")

    p = sub.add_parser("shot")
    p.add_argument("out")
    p.add_argument("region", nargs="*", type=int, help="x y w h")
    p.add_argument("--output", help="capture one connector's own logical rect, sway's -o NAME")

    p = sub.add_parser("pointer")
    psub = p.add_subparsers(dest="pointer_verb", required=True)
    pa = psub.add_parser("abs"); pa.add_argument("x", type=float); pa.add_argument("y", type=float)
    pr = psub.add_parser("rel"); pr.add_argument("dx", type=float); pr.add_argument("dy", type=float)
    pb = psub.add_parser("btn"); pb.add_argument("code", type=int); pb.add_argument("state", type=int)
    px = psub.add_parser("axis"); px.add_argument("axis", choices=["h", "v"]); px.add_argument("value", type=float)
    pd = psub.add_parser("drag")
    pd.add_argument("sx", type=float); pd.add_argument("sy", type=float)
    pd.add_argument("dx", type=float); pd.add_argument("dy", type=float)
    sub.add_parser("pointer-session")

    p = sub.add_parser("key")
    ksub = p.add_subparsers(dest="key_verb", required=True)
    ks = ksub.add_parser("single"); ks.add_argument("code", type=int); ks.add_argument("state", type=int)
    kc = ksub.add_parser("chord"); kc.add_argument("codes", type=int, nargs="+")

    sub.add_parser("windows")

    p = sub.add_parser("window-op")
    p.add_argument("id", type=int)
    p.add_argument("op", choices=["fullscreen", "unfullscreen", "maximize", "unmaximize",
                                   "move", "resize", "to_monitor", "activate", "close", "above"])
    p.add_argument("a", nargs="?")
    p.add_argument("b", nargs="?")

    sub.add_parser("seat-devices")

    p = sub.add_parser("notifications")
    nsub = p.add_subparsers(dest="notif_verb", required=True)
    nsub.add_parser("list")
    na = nsub.add_parser("activate"); na.add_argument("id"); na.add_argument("key", nargs="?", default="default")

    p = sub.add_parser("outputs")
    osub = p.add_subparsers(dest="outputs_verb", required=True)
    osub.add_parser("list")
    oa = osub.add_parser("add"); oa.add_argument("size")
    orm = osub.add_parser("remove"); orm.add_argument("name")
    osc = osub.add_parser("scale"); osc.add_argument("name"); osc.add_argument("n", type=float)

    return ap


def main():
    """parse the arguments and run the chosen command or the selftest"""
    ap = build_parser()
    args = ap.parse_args()
    if args.selftest:
        sys.exit(_selftest.run())
    if not args.cmd:
        ap.error("a subcommand is required outside --selftest")
    try:
        sys.exit(main_run(args))
    except (dbus_min.DBusError, RuntimeError, TimeoutError, ConnectionError) as e:
        sys.stderr.write("gnome-harness.py %s: %s\n" % (args.cmd, e))
        sys.exit(1)


# selftest against a fake D-Bus peer
class _selftest:
    import socket
    import threading

    NO_REPLY = object()
    ERROR_REPLY = object()

    STATE_SIG = STATE_SIG

    class FakeBus(threading.Thread):
        def __init__(self, sock, handlers):
            """store the socket and method table"""
            super().__init__(daemon=True)
            self.sock = sock
            self.handlers = handlers
            self.calls = []
            self._stopping = False
            self._serial = 0

        def _read_sasl_line(self):
            """read a line of the SASL handshake from the client"""
            buf = bytearray()
            while not buf.endswith(b"\r\n"):
                b = self.sock.recv(1)
                if not b:
                    raise ConnectionError("fake bus: client closed during SASL")
                buf += b
            return buf[:-2].decode("ascii")

        def run(self):
            """answer the handshake and the method calls from the client"""
            nul = self.sock.recv(1)
            assert nul == b"\0", nul
            auth = self._read_sasl_line()
            assert auth.startswith("AUTH EXTERNAL"), auth
            self.sock.sendall(b"OK 0000000000000000000000000000000000000000\r\n")
            begin = self._read_sasl_line()
            assert begin == "BEGIN", begin
            self.sock.settimeout(0.2)
            buf = bytearray()
            while not self._stopping:
                try:
                    data = self.sock.recv(65536)
                except OSError:
                    continue
                if not data:
                    return
                buf += data
                while True:
                    parsed = dbus_min.try_parse_message(bytes(buf))
                    if parsed is None:
                        break
                    msg, consumed = parsed
                    del buf[:consumed]
                    self._handle(msg)

        def _handle(self, msg):
            """reply to a method call"""
            if msg.mtype != dbus_min.METHOD_CALL:
                return
            self.calls.append((msg.destination, msg.path, msg.interface, msg.member, msg.signature, msg.body))
            if msg.member == "Hello":
                self._reply(msg, "s", [":1.999"])
                return
            if msg.member == "RequestName":
                self._reply(msg, "u", [dbus_min.REQUEST_NAME_REPLY_PRIMARY_OWNER])
                return
            handler = self.handlers.get((msg.interface, msg.member))
            if handler is None:
                self._error(msg, "org.freedesktop.DBus.Error.UnknownMethod",
                            "no handler registered for %s.%s in this test case" % (msg.interface, msg.member))
                return
            try:
                sig, reply_args = handler(msg)
            except Exception as e:  # noqa: BLE001
                sys.stderr.write("FakeBus: handler for %s.%s raised %r -- treating as NO_REPLY\n"
                                  % (msg.interface, msg.member, e))
                return
            if sig is _selftest.NO_REPLY:
                return
            if sig is _selftest.ERROR_REPLY:
                self._error(msg, *reply_args)
                return
            self._reply(msg, sig, reply_args)

        def _reply(self, msg, sig, args):
            """send a method return for a message"""
            self._serial += 1
            out = dbus_min.build_message(dbus_min.METHOD_RETURN, dbus_min.FLAG_NO_REPLY_EXPECTED,
                                          self._serial, sig, args, reply_serial=msg.serial)
            self.sock.sendall(out)

        def _error(self, msg, error_name, text):
            """send an error reply for a message"""
            self._serial += 1
            out = dbus_min.build_message(dbus_min.ERROR, dbus_min.FLAG_NO_REPLY_EXPECTED,
                                          self._serial, "s", [text],
                                          error_name=error_name, reply_serial=msg.serial)
            self.sock.sendall(out)

        def stop(self):
            """ask the fake bus to stop"""
            self._stopping = True

    @classmethod
    def _run_case(cls, handlers, action):
        """run an action against a fake bus"""
        client_sock, bus_sock = cls.socket.socketpair(cls.socket.AF_UNIX, cls.socket.SOCK_STREAM)
        bus = cls.FakeBus(bus_sock, handlers)
        bus.start()
        conn = dbus_min.Connection(client_sock)
        conn._authenticate()
        conn.hello()
        try:
            result = action(conn)
        finally:
            bus.stop()
            try:
                client_sock.close()
            finally:
                bus_sock.close()
            bus.join(timeout=2)
        return result, bus.calls

    @staticmethod
    def _v(sig, value):
        """return a D-Bus variant of a signature and value"""
        return dbus_min.Variant(sig, value)

    @staticmethod
    def _ok(sig="", args=None):
        """return a handler that answers with a fixed signature and arguments"""
        return lambda m: (sig, args if args is not None else [])

    @staticmethod
    def _find(calls, member, nth=0):
        """return the nth recorded call of a member, or None"""
        matching = [c for c in calls if c[3] == member]
        return matching[nth] if len(matching) > nth else None

    @classmethod
    def _expect(cls, check, calls, member, dest, path, iface, sig, body=None, nth=0):
        """check the recorded call's fields"""
        c = cls._find(calls, member, nth)
        if c is None:
            check(False, "%s: no call recorded (want the %d(th) call)" % (member, nth))
            return None
        check(c[0] == dest, "%s: destination %r != %r" % (member, c[0], dest))
        check(c[1] == path, "%s: path %r != %r" % (member, c[1], path))
        check(c[2] == iface, "%s: interface %r != %r" % (member, c[2], iface))
        check((c[4] or "") == sig, "%s: signature %r != %r" % (member, c[4], sig))
        if body is not None:
            check(c[5] == body, "%s: body %r != %r" % (member, c[5], body))
        return c

    @staticmethod
    def _parse_extension_iface():
        """parse the extension IFACE_XML for method signatures"""
        path = os.path.join(REPO, "tools", "build", "test-tools", "gen-gnome-harness-ext.sh")
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        m = re.search(r"const IFACE_XML = `(.*?)`;", text, re.S)
        if not m:
            raise RuntimeError("could not find IFACE_XML in %s" % path)
        xml = m.group(1)
        bus_m = re.search(r"const BUS_NAME = '([^']+)';", text)
        bus_name = bus_m.group(1) if bus_m else None
        methods = {}
        for meth_m in re.finditer(r'<method name="([^"]+)">(.*?)</method>', xml, re.S):
            name, body = meth_m.group(1), meth_m.group(2)
            in_sig = "".join(arg_m.group(1) for arg_m in re.finditer(
                r'<arg type="([^"]+)" direction="in"', body))
            methods[name] = in_sig
        return bus_name, methods

    ONE_MONITOR_STATE = [
        1,
        [(("Meta-0", "v", "p", "s"),
          [("m0", 1920, 1080, 60.0, 1.0, [1.0], {"is-current": dbus_min.Variant("b", True)})], {})],
        [(0, 0, 1.0, 0, True, [("Meta-0", "v", "p", "s")], {})],
        {},
    ]

    @classmethod
    def _rd_sc_handlers(cls, rd_path="/rd/1", sc_path="/sc/1", stream_path="/sc/1/stream",
                        session_id="sess-id-1", state=None):
        """return the D-Bus method table for a session"""
        state = state if state is not None else cls.ONE_MONITOR_STATE
        return {
            (DC_IFACE, "GetCurrentState"): cls._ok(cls.STATE_SIG, state),
            (RD_IFACE, "CreateSession"): cls._ok("o", [rd_path]),
            (RD_SESSION_IFACE, "Start"): cls._ok(),
            (RD_SESSION_IFACE, "Stop"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyPointerMotionAbsolute"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyPointerMotionRelative"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyPointerButton"): cls._ok(),
            (PROPS_IFACE, "Get"): cls._ok("v", [cls._v("s", session_id)]),
            (SC_IFACE, "CreateSession"): cls._ok("o", [sc_path]),
            (SC_SESSION_IFACE, "RecordMonitor"): cls._ok("o", [stream_path]),
            (SC_SESSION_IFACE, "Start"): cls._ok(),
            (SC_SESSION_IFACE, "Stop"): cls._ok(),
        }

    @classmethod
    def _stateful_outputs_handlers(cls, initial_state):
        """return the method table for monitor configuration"""
        holder = {"state": list(initial_state)}

        def get_current_state(m):
            """return the current monitor state"""
            return cls.STATE_SIG, holder["state"]

        def apply_config(m):
            """apply a monitor configuration to the held state"""
            serial, method, logical, props = m.body
            chosen = {c: mid for *_head, mons in logical for c, mid, _mp in mons}
            monitors = []
            for spec, modes, mprops in holder["state"][1]:
                want = chosen.get(spec[0])
                monitors.append((spec, [
                    (mid, w, h, r, pref, scales,
                     dict(mode_props, **({"is-current": cls._v("b", mid == want)} if want else {})))
                    for mid, w, h, r, pref, scales, mode_props in modes], mprops))
            specs = {spec[0]: spec for spec, _modes, _mp in holder["state"][1]}
            state_logical = [(x, y, sc, t, p, [specs[c] for c, _mid, _mp in mons], {})
                             for x, y, sc, t, p, mons in logical]
            holder["state"] = [holder["state"][0], monitors, state_logical, holder["state"][3]]
            return "", []

        return {
            (DC_IFACE, "GetCurrentState"): get_current_state,
            (DC_IFACE, "ApplyMonitorsConfig"): apply_config,
        }, holder

    @classmethod
    def run(cls):
        """run the selftest assertions"""
        checks = []

        def check(ok, why):
            """record a check and print a failure message when it is false"""
            checks.append((ok, why))
            if not ok:
                sys.stderr.write("selftest FAIL: %s\n" % why)
            return ok

        bus_name, ext_methods = cls._parse_extension_iface()
        check(bus_name == HARNESS_DEST, "gen-gnome-harness-ext.sh BUS_NAME %r != HARNESS_DEST %r" % (bus_name, HARNESS_DEST))
        harness_calls_made = {
            "Ping": "", "GetPointer": "", "GetWindows": "", "WindowOp": "uss",
            "GetSeatDevices": "", "GetNotifications": "", "ActivateNotification": "ss",
        }
        for member, sig in harness_calls_made.items():
            if not check(member in ext_methods, "org.rhizo.Harness.%s: gnome-harness.py calls it, "
                         "the extension does not export it" % member):
                continue
            check(ext_methods[member] == sig, "org.rhizo.Harness.%s in-signature: extension declares %r, "
                  "gnome-harness.py sends %r" % (member, ext_methods[member], sig))

        handlers = {(HARNESS_IFACE, "Ping"): cls._ok("s", ["rhizo-harness 1 pid=1234"])}
        info, calls = cls._run_case(handlers, cmd_ping)
        check(info == "rhizo-harness 1 pid=1234", "ping returned %r" % (info,))
        cls._expect(check, calls, "Ping", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "", body=[])

        shot_tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
        shot_tmp.write(b"old bytes from a previous run")
        shot_tmp.close()
        try:
            def do_shot(conn):
                """answer a screenshot call by writing a small PNG"""
                with open(shot_tmp.name, "wb") as f:
                    f.write(b"\x89PNG\r\n\x1a\nfake but non-empty")
                return "bs", [True, shot_tmp.name]
            handlers = {(SCREENSHOT_IFACE, "ScreenshotArea"): do_shot}
            filename, calls = cls._run_case(handlers, lambda conn: cmd_shot(conn, shot_tmp.name, (1, 2, 300, 400)))
            check(filename == shot_tmp.name, "shot returned %r" % (filename,))
            cls._expect(check, calls, "RequestName", "org.freedesktop.DBus", "/org/freedesktop/DBus",
                        "org.freedesktop.DBus", "su", body=[SCREENSHOT_OWN_NAME, dbus_min.NAME_FLAG_DO_NOT_QUEUE])
            cls._expect(check, calls, "ScreenshotArea", SHELL_DEST, SCREENSHOT_PATH, SCREENSHOT_IFACE,
                        "iiiibs", body=[1, 2, 300, 400, False, shot_tmp.name])
            req_idx = next(i for i, c in enumerate(calls) if c[3] == "RequestName")
            shot_idx = next(i for i, c in enumerate(calls) if c[3] == "ScreenshotArea")
            check(req_idx < shot_idx, "RequestName must precede ScreenshotArea")

            try:
                cls._run_case({(SCREENSHOT_IFACE, "ScreenshotArea"): cls._ok("bs", [False, ""])},
                              lambda conn: cmd_shot(conn, shot_tmp.name, (1, 2, 300, 400)))
                check(False, "shot with ok=False should have raised")
            except RuntimeError as e:
                check("failure" in str(e), "shot ok=False error did not say so: %r" % e)

            def do_shot_output(conn):
                """answer a screenshot call by writing a small PNG"""
                with open(shot_tmp.name, "wb") as f:
                    f.write(b"\x89PNG\r\n\x1a\nfake but non-empty")
                return "bs", [True, shot_tmp.name]
            handlers = {
                (DC_IFACE, "GetCurrentState"): cls._ok(cls.STATE_SIG, cls.ONE_MONITOR_STATE),
                (SCREENSHOT_IFACE, "ScreenshotArea"): do_shot_output,
            }
            filename, calls = cls._run_case(handlers, lambda conn: cmd_shot(conn, shot_tmp.name, None, "Meta-0"))
            check(filename == shot_tmp.name, "shot --output returned %r" % (filename,))
            cls._expect(check, calls, "ScreenshotArea", SHELL_DEST, SCREENSHOT_PATH, SCREENSHOT_IFACE,
                        "iiiibs", body=[0, 0, 1920, 1080, False, shot_tmp.name])

            try:
                cls._run_case({(DC_IFACE, "GetCurrentState"): cls._ok(cls.STATE_SIG, cls.ONE_MONITOR_STATE)},
                              lambda conn: cmd_shot(conn, shot_tmp.name, None, "Meta-9"))
                check(False, "shot --output on an unknown connector should have raised")
            except RuntimeError as e:
                check("Meta-9" in str(e), "shot --output error did not name the connector: %r" % e)
        finally:
            try:
                os.unlink(shot_tmp.name)
            except FileNotFoundError:
                pass

        handlers = cls._rd_sc_handlers()
        handlers[(HARNESS_IFACE, "GetPointer")] = cls._ok("s", [json.dumps({"x": 640, "y": 480})])
        _, calls = cls._run_case(handlers, lambda conn: cmd_pointer_abs(conn, 640, 480))
        cls._expect(check, calls, "NotifyPointerMotionAbsolute", RD_DEST, "/rd/1", RD_SESSION_IFACE,
                    "sdd", body=["/sc/1/stream", 640.0, 480.0])
        cls._expect(check, calls, "RecordMonitor", SC_DEST, "/sc/1", SC_SESSION_IFACE,
                    "sa{sv}", body=["Meta-0", {}])
        cls._expect(check, calls, "GetPointer", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "", body=[])
        order = [(c[2], c[3]) for c in calls if c[3] in ("CreateSession", "RecordMonitor", "Start", "Stop")]
        want = [(RD_IFACE, "CreateSession"), (SC_IFACE, "CreateSession"), (SC_SESSION_IFACE, "RecordMonitor"),
                (RD_SESSION_IFACE, "Start"), (RD_SESSION_IFACE, "Stop")]
        check(order == want, "RemoteDesktop/ScreenCast call order %r, want %r" % (order, want))

        handlers = {
            (DC_IFACE, "GetCurrentState"): lambda m: (cls.NO_REPLY, None),
            (RD_IFACE, "CreateSession"): cls._ok("o", ["/rd/2"]),
            (RD_SESSION_IFACE, "Start"): cls._ok(),
            (RD_SESSION_IFACE, "Stop"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyPointerMotionRelative"): cls._ok(),
            (HARNESS_IFACE, "GetPointer"): cls._ok("s", [json.dumps({"x": 10, "y": 20})]),
        }
        _, calls = cls._run_case(handlers, lambda conn: cmd_pointer_abs(conn, 10, 20))
        cls._expect(check, calls, "NotifyPointerMotionRelative", RD_DEST, "/rd/2", RD_SESSION_IFACE,
                    "dd", body=[-1e6, -1e6], nth=0)
        cls._expect(check, calls, "NotifyPointerMotionRelative", RD_DEST, "/rd/2", RD_SESSION_IFACE,
                    "dd", body=[10.0, 20.0], nth=1)

        handlers = {
            (DC_IFACE, "GetCurrentState"): lambda m: (cls.NO_REPLY, None),
            (RD_IFACE, "CreateSession"): cls._ok("o", ["/rd/3"]),
            (RD_SESSION_IFACE, "Start"): cls._ok(),
            (RD_SESSION_IFACE, "Stop"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyPointerMotionRelative"): cls._ok(),
            (HARNESS_IFACE, "GetPointer"): cls._ok("s", [json.dumps({"x": 999, "y": 999})]),
        }
        try:
            cls._run_case(handlers, lambda conn: cmd_pointer_abs(conn, 10, 20))
            check(False, "pointer abs fallback landing off-target should have raised")
        except RuntimeError as e:
            check("wanted (10, 20)" in str(e), "fallback miss error did not name the target: %r" % e)

        handlers = cls._rd_sc_handlers(rd_path="/rd/4", sc_path="/sc/4", stream_path="/sc/4/stream")
        handlers[(HARNESS_IFACE, "GetPointer")] = cls._ok("s", [json.dumps({"x": 300, "y": 300})])
        _, calls = cls._run_case(handlers, lambda conn: cmd_pointer_drag(conn, 100, 100, 300, 300))
        create_calls = [c for c in calls if c[2] == RD_IFACE and c[3] == "CreateSession"]
        check(len(create_calls) == 1, "pointer drag opened more than one RemoteDesktop session for one gesture")
        create_idx = next(i for i, c in enumerate(calls) if c[2] == RD_IFACE and c[3] == "CreateSession")
        stop_idx = next(i for i, c in enumerate(calls) if c[1] == "/rd/4" and c[3] == "Stop")
        check(create_idx < stop_idx, "pointer drag: CreateSession must precede the session's own Stop")
        cls._expect(check, calls, "NotifyPointerMotionAbsolute", RD_DEST, "/rd/4", RD_SESSION_IFACE,
                    "sdd", body=["/sc/4/stream", 100.0, 100.0], nth=0)
        cls._expect(check, calls, "NotifyPointerButton", RD_DEST, "/rd/4", RD_SESSION_IFACE,
                    "ib", body=[272, True], nth=0)
        cls._expect(check, calls, "NotifyPointerMotionAbsolute", RD_DEST, "/rd/4", RD_SESSION_IFACE,
                    "sdd", body=["/sc/4/stream", 300.0, 300.0], nth=1)
        cls._expect(check, calls, "NotifyPointerButton", RD_DEST, "/rd/4", RD_SESSION_IFACE,
                    "ib", body=[272, False], nth=1)

        def session_handlers(land=lambda x, y: (x, y)):
            """return the method table for a pointer session"""
            handlers = cls._rd_sc_handlers(rd_path="/rd/5", sc_path="/sc/5", stream_path="/sc/5/stream")
            at = {"x": 0, "y": 0}

            def motion(m):
                """record where a motion call put the pointer"""
                at["x"], at["y"] = land(m.body[1], m.body[2])
                return "", []
            handlers[(RD_SESSION_IFACE, "NotifyPointerMotionAbsolute")] = motion
            handlers[(HARNESS_IFACE, "GetPointer")] = lambda m: ("s", [json.dumps(at)])
            return handlers

        def run_session(handlers, script):
            """run a script through a pointer session"""
            out = io.StringIO()
            _, calls = cls._run_case(handlers, lambda conn: cmd_pointer_session(
                conn, stdin=io.StringIO(script), stdout=out))
            return out.getvalue().splitlines(), calls

        lines, calls = run_session(session_handlers(), "press 100 100\nmoveto 400 300\nwiggle\nrelease\nquit\n")
        check(lines == ["ready", "pressed 100 100", "movedto 400 300",
                        "error wiggle: unknown command 'wiggle' (press X Y | moveto X Y | abs X Y | release | quit)",
                        "released"],
              "pointer-session answers %r" % (lines,))
        moves = [c[5] for c in calls if c[3] == "NotifyPointerMotionAbsolute"]
        check(len(moves) == 1 + PointerSession.STEPS and moves[-1] == ["/sc/5/stream", 400.0, 300.0],
              "pointer-session moves %r: want the press's own and %d steps ending at 400,300"
              % (moves, PointerSession.STEPS))
        buttons = [c[5] for c in calls if c[3] == "NotifyPointerButton"]
        check(buttons == [[272, True], [272, False]], "pointer-session buttons %r" % (buttons,))
        order = [(c[2], c[3]) for c in calls if c[3] in ("CreateSession", "RecordMonitor", "Start", "Stop")]
        check(order == [(RD_IFACE, "CreateSession"), (SC_IFACE, "CreateSession"),
                        (SC_SESSION_IFACE, "RecordMonitor"), (RD_SESSION_IFACE, "Start"),
                        (RD_SESSION_IFACE, "Stop")],
              "pointer-session opened and closed %r, want one session held throughout" % (order,))

        lines, calls = run_session(session_handlers(), "press 50 60\n")
        buttons = [c[5] for c in calls if c[3] == "NotifyPointerButton"]
        check(lines == ["ready", "pressed 50 60"] and buttons == [[272, True], [272, False]],
              "pointer-session at EOF with the button held: answers %r, buttons %r" % (lines, buttons))

        lines, _ = run_session(session_handlers(land=lambda x, y: (x + 40, y)), "abs 200 200\nquit\n")
        check(len(lines) == 2 and lines[1].startswith("error abs: pointer landed at (240"),
              "pointer-session did not answer a missed landing with error: %r" % (lines,))

        handlers = session_handlers()
        lag = {"reads": 0}
        answer = handlers[(HARNESS_IFACE, "GetPointer")]

        def lagging(m):
            """report the origin on the first read and the real position afterwards"""
            lag["reads"] += 1
            return ("s", [json.dumps({"x": 0, "y": 0})]) if lag["reads"] == 1 else answer(m)
        handlers[(HARNESS_IFACE, "GetPointer")] = lagging
        lines, _ = run_session(handlers, "abs 300 300\nquit\n")
        check(lines == ["ready", "moved 300 300"] and lag["reads"] >= 2,
              "pointer-session failed a move whose first read lagged: %r after %d reads" % (lines, lag["reads"]))

        rd_only = {
            (RD_IFACE, "CreateSession"): cls._ok("o", ["/rd/x"]),
            (RD_SESSION_IFACE, "Start"): cls._ok(),
            (RD_SESSION_IFACE, "Stop"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyPointerMotionRelative"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyPointerButton"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyPointerAxis"): cls._ok(),
            (RD_SESSION_IFACE, "NotifyKeyboardKeycode"): cls._ok(),
        }

        _, calls = cls._run_case(rd_only, lambda conn: cmd_pointer_rel(conn, 1.5, -2.5))
        cls._expect(check, calls, "NotifyPointerMotionRelative", RD_DEST, "/rd/x", RD_SESSION_IFACE,
                    "dd", body=[1.5, -2.5])

        _, calls = cls._run_case(rd_only, lambda conn: cmd_pointer_btn(conn, 272, 1))
        cls._expect(check, calls, "NotifyPointerButton", RD_DEST, "/rd/x", RD_SESSION_IFACE,
                    "ib", body=[272, True])

        _, calls = cls._run_case(rd_only, lambda conn: cmd_pointer_axis(conn, "h", 3.0))
        cls._expect(check, calls, "NotifyPointerAxis", RD_DEST, "/rd/x", RD_SESSION_IFACE,
                    "ddu", body=[3.0, 0.0, 0])

        _, calls = cls._run_case(rd_only, lambda conn: cmd_key(conn, 30, 0))
        cls._expect(check, calls, "NotifyKeyboardKeycode", RD_DEST, "/rd/x", RD_SESSION_IFACE,
                    "ub", body=[30, False])

        _, calls = cls._run_case(rd_only, lambda conn: cmd_key_chord(conn, [29, 42, 30]))
        key_calls = [c for c in calls if c[3] == "NotifyKeyboardKeycode"]
        check([c[5] for c in key_calls] == [[29, True], [42, True], [30, True],
                                             [30, False], [42, False], [29, False]],
              "key chord press/release order %r" % ([c[5] for c in key_calls],))

        sample_windows = [{"id": 7, "app_id": "rhizo-com.example", "title": "T", "x": 0, "y": 0,
                            "w": 100, "h": 200, "fullscreen": False, "maximized": True,
                            "focused": True, "monitor": "Meta-0"}]
        handlers = {(HARNESS_IFACE, "GetWindows"): cls._ok("s", [json.dumps(sample_windows)])}
        windows, calls = cls._run_case(handlers, cmd_windows)
        check(windows == sample_windows, "windows JSON round-trip %r" % (windows,))
        cls._expect(check, calls, "GetWindows", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "", body=[])

        handlers = {(HARNESS_IFACE, "WindowOp"): cls._ok()}
        _, calls = cls._run_case(handlers, lambda conn: cmd_window_op(conn, 7, "move", {"x": 5, "y": 6}))
        cls._expect(check, calls, "WindowOp", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "uss",
                    body=[7, "move", json.dumps({"x": 5, "y": 6})])

        _, calls = cls._run_case(handlers, lambda conn: cmd_window_op(conn, 9, "to_monitor", {"monitor": "Meta-1"}))
        cls._expect(check, calls, "WindowOp", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "uss",
                    body=[9, "to_monitor", json.dumps({"monitor": "Meta-1"})])

        sample_devices = [{"name": "rhizo virtual pointer", "device_type": 1, "vendor_id": "", "product_id": ""}]
        handlers = {(HARNESS_IFACE, "GetSeatDevices"): cls._ok("s", [json.dumps(sample_devices)])}
        devices, calls = cls._run_case(handlers, cmd_seat_devices)
        check(devices == sample_devices, "seat-devices JSON round-trip %r" % (devices,))
        cls._expect(check, calls, "GetSeatDevices", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "", body=[])

        sample_notifs = [{"id": "5", "source": "rhizo-com.example", "title": "Hi", "body": "there",
                           "has_default_action": True, "icon": "/tmp/rhizo-notif-icons.x/icon-0.png"}]
        handlers = {(HARNESS_IFACE, "GetNotifications"): cls._ok("s", [json.dumps(sample_notifs)])}
        notifs, calls = cls._run_case(handlers, cmd_notifications_list)
        check(notifs == sample_notifs, "notifications list JSON round-trip %r" % (notifs,))
        cls._expect(check, calls, "GetNotifications", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE, "", body=[])

        empty_after = []
        handlers = {
            (HARNESS_IFACE, "ActivateNotification"): cls._ok("b", [True]),
            (HARNESS_IFACE, "GetNotifications"): cls._ok("s", [json.dumps(empty_after)]),
        }
        invoked, calls = cls._run_case(handlers, lambda conn: cmd_notifications_activate(conn, "5"))
        check(invoked is True, "notifications activate returned %r, wanted True" % (invoked,))
        cls._expect(check, calls, "ActivateNotification", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE,
                    "ss", body=["5", "default"])
        handlers = {(HARNESS_IFACE, "ActivateNotification"): cls._ok("b", [True])}
        invoked, calls = cls._run_case(handlers, lambda conn: cmd_notifications_activate(conn, "5", "reply"))
        cls._expect(check, calls, "ActivateNotification", HARNESS_DEST, HARNESS_PATH, HARNESS_IFACE,
                    "ss", body=["5", "reply"])
        try:
            cls._run_case({}, lambda conn: cmd_notifications_activate(conn, "5", "Open"))
            check(False, "notifications activate should have raised on the extension's error reply")
        except dbus_min.DBusError:
            pass
        js_text = "notification ext-5: the shell took no click on it"
        handlers = {(HARNESS_IFACE, "ActivateNotification"):
                    lambda m: (cls.ERROR_REPLY, ("org.gnome.gjs.JSError.Error", js_text))}
        try:
            cls._run_case(handlers, lambda conn: cmd_notifications_activate(conn, "ext-5"))
            check(False, "notifications activate should have raised on the extension's JS error")
        except dbus_min.DBusError as e:
            check(str(e) == "org.gnome.gjs.JSError.Error: " + js_text,
                  "the extension's JS error reached the caller as %r, not whole" % str(e))
        handlers = {(HARNESS_IFACE, "ActivateNotification"): cls._ok("b", [False])}
        try:
            cls._run_case(handlers, lambda conn: cmd_notifications_activate(conn, "5", "reply"))
            check(False, "notifications activate should have raised when nothing was invoked")
        except RuntimeError as e:
            check("was not invoked" in str(e), "not-invoked error did not say so: %r" % e)

        handlers = {
            (HARNESS_IFACE, "ActivateNotification"): cls._ok("b", [True]),
            (HARNESS_IFACE, "GetNotifications"): cls._ok("s", [json.dumps(sample_notifs)]),
        }
        try:
            cls._run_case(handlers, lambda conn: cmd_notifications_activate(conn, "5"))
            check(False, "notifications activate should have raised when the id was still listed")
        except RuntimeError as e:
            check("still listed" in str(e), "still-listed error did not say so: %r" % e)

        canned_state = [
            3,
            [
                (("Meta-0", "v", "p", "s0"), [("m0", 1920, 1080, 60.0, 1.0, [1.0], {"is-current": cls._v("b", True)})], {}),
                (("Meta-1", "v", "p", "s1"), [("m1", 1280, 720, 60.0, 1.0, [1.0], {"is-current": cls._v("b", True)})], {}),
            ],
            [(0, 0, 1.0, 0, True, [("Meta-0", "v", "p", "s0")], {})],
            {},
        ]
        handlers = {(DC_IFACE, "GetCurrentState"): cls._ok(cls.STATE_SIG, canned_state)}
        state, calls = cls._run_case(handlers, get_state)
        as_json = state_to_json(state)
        check(isinstance(as_json, list) and len(as_json) == 1,
              "outputs list shape: want a 1-element array, got %r" % (as_json,))
        if as_json:
            entry = as_json[0]
            check(entry.get("name") == "Meta-0", "outputs list entry 'name' %r != 'Meta-0'" % entry.get("name"))
            check(entry.get("rect") == {"x": 0, "y": 0, "width": 1920, "height": 1080},
                  "outputs list entry 'rect' %r" % entry.get("rect"))
            check(entry.get("primary") is True, "outputs list entry 'primary' %r != True" % entry.get("primary"))
        cls._expect(check, calls, "GetCurrentState", DC_DEST, DC_PATH, DC_IFACE, "", body=[])

        handlers, _holder = cls._stateful_outputs_handlers(canned_state)
        connector, calls = cls._run_case(handlers, lambda conn: cmd_outputs_add(conn, "1280x720"))
        check(connector == "Meta-1", "outputs add picked connector %r, want Meta-1" % connector)
        apply_call = cls._expect(check, calls, "ApplyMonitorsConfig", DC_DEST, DC_PATH, DC_IFACE,
                                 APPLY_MONITORS_SIG)
        if apply_call is not None:
            serial, method, logical, _props = apply_call[5]
            check(serial == 3, "ApplyMonitorsConfig serial %r != 3" % serial)
            check(method == 1, "ApplyMonitorsConfig method %r != 1 (literal, not METHOD_TEMPORARY)" % method)
            check(len(logical) == 2 and logical[1][5][0][0] == "Meta-1",
                  "ApplyMonitorsConfig did not add Meta-1 as a second logical monitor: %r" % (logical,))
            check(logical[1][0] == 1920, "outputs add did not place the new monitor to the right (x=%r)" % logical[1][0])
        state_calls = [c for c in calls if c[3] == "GetCurrentState"]
        check(len(state_calls) >= 2, "outputs add did not re-read GetCurrentState after applying (got %d calls)"
              % len(state_calls))

        handlers, _holder = cls._stateful_outputs_handlers(canned_state)
        _, calls = cls._run_case(handlers, lambda conn: cmd_outputs_remove(conn, "Meta-0"))
        apply_call = cls._expect(check, calls, "ApplyMonitorsConfig", DC_DEST, DC_PATH, DC_IFACE,
                                 APPLY_MONITORS_SIG)
        if apply_call is not None:
            _serial, _method, logical, _props = apply_call[5]
            check(not any(c == "Meta-0" for lm in logical for c, _mid, _mp in lm[5]),
                  "outputs remove did not drop Meta-0 from the applied logical_monitors: %r" % (logical,))
        final_state = cls.STATE_SIG, _holder["state"]
        check(not any(lm[5][0][0] == "Meta-0" for lm in final_state[1][2]),
              "outputs remove: Meta-0 still present after the re-read")

        handlers = {(DC_IFACE, "GetCurrentState"): cls._ok(cls.STATE_SIG, canned_state)}
        try:
            cls._run_case(handlers, lambda conn: cmd_outputs_remove(conn, "Meta-9"))
            check(False, "outputs remove on an unknown connector should have raised")
        except RuntimeError as e:
            check("Meta-9" in str(e), "outputs remove error did not name the connector: %r" % e)

        handlers, _holder = cls._stateful_outputs_handlers(canned_state)
        _, calls = cls._run_case(handlers, lambda conn: cmd_outputs_scale(conn, "Meta-0", 2.0))
        apply_call = cls._expect(check, calls, "ApplyMonitorsConfig", DC_DEST, DC_PATH, DC_IFACE,
                                 APPLY_MONITORS_SIG)
        if apply_call is not None:
            check(apply_call[5][2][0][2] == 2.0, "outputs scale did not rewrite the scale field: %r" % (apply_call[5][2],))
        check(_holder["state"][2][0][2] == 2.0, "outputs scale: re-read state does not show scale=2.0")

        try:
            cls._run_case(
                {(DC_IFACE, "GetCurrentState"): cls._ok(cls.STATE_SIG, canned_state)},
                lambda conn: cmd_outputs_scale(conn, "Meta-9", 2.0))
            check(False, "outputs scale on an unknown connector should have raised")
        except RuntimeError as e:
            check("Meta-9" in str(e), "outputs scale error did not name the connector: %r" % e)

        n = len(checks)
        failed = [why for ok, why in checks if not ok]
        print("gnome-harness selftest: %d assertions, %d failed" % (n, len(failed)))
        return 0 if not failed else 1


if __name__ == "__main__":
    main()
