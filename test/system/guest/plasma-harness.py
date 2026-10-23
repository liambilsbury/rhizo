#!/usr/bin/env python3
"""Driver for KWin on the plasma profile."""
import argparse
import json
import os
import re
import select
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

USAGE = """Usage:
  plasma-harness.py await-name NAME SECONDS
  plasma-harness.py ping
  plasma-harness.py windows
  plasma-harness.py window-op ID fullscreen|unfullscreen|maximize|unmaximize|
                              move X Y|resize W H|to_monitor NAME|activate|close|above
  plasma-harness.py notify-watch --record PATH
  plasma-harness.py notifications list|activate ID [KEY] --record PATH
  plasma-harness.py outputs list|add WxH|remove NAME|scale NAME N|reset|reset-scale
  plasma-harness.py seat-devices
  plasma-harness.py layouts
  plasma-harness.py shot OUT.png [x y w h] [--output NAME]
  plasma-harness.py --selftest

A shot's x y w h is a logical layout rect.

`windows` prints one JSON object per window. `seat-devices` and `outputs list` print one JSON array.
ID is the id desk_windows prints, KWin's internalId with the braces removed.
Exit 1 reports a failure. Exit 3 reports an unsupported verb."""

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [_HERE, os.path.join(_HERE, "..", "..", "..", "src", "services", "deskbridge")]
import dbus_min  # noqa: E402

HARNESS_DEST = "org.rhizo.Harness"
HARNESS_PATH = "/org/rhizo/Harness"
HARNESS_IFACE = "org.rhizo.Harness"
HARNESS_XML = ('<interface name="org.rhizo.Harness"><method name="Report">'
               '<arg name="report" type="s" direction="in"/></method></interface>')

KWIN_DEST = "org.kde.KWin"
SCRIPTING_PATH = "/Scripting"
SCRIPTING_IFACE = "org.kde.kwin.Scripting"
SCRIPT_IFACE = "org.kde.kwin.Script"
LAYOUTS_PATH = "/Layouts"
LAYOUTS_IFACE = "org.kde.KeyboardLayouts"
INPUT_PATH = "/org/kde/KWin/InputDevice"
INPUT_MANAGER_IFACE = "org.kde.KWin.InputDeviceManager"
INPUT_DEVICE_IFACE = "org.kde.KWin.InputDevice"
PROPS_IFACE = "org.freedesktop.DBus.Properties"

SCRIPT_TIMEOUT_S = 10.0
EXIT_CANNOT = 3


class Cannot(RuntimeError):
    """exception for an unanswerable verb"""


SCRIPT_FRAME = """(function () {
    const nonce = %(nonce)s;
    function report(ok, data) {
        callDBus("%(dest)s", "%(path)s", "%(iface)s", "Report", JSON.stringify({nonce: nonce, ok: ok, data: data}));
    }
    try {
        report(true, (function () {
%(body)s
        })());
    } catch (e) {
        report(false, String(e));
    }
})();
"""

WINDOWS_BODY = """return workspace.windowList().map(w => ({
    internalId: String(w.internalId), resourceClass: w.resourceClass, desktopFileName: w.desktopFileName,
    caption: w.caption, pid: w.pid, rect: {x: w.clientGeometry.x, y: w.clientGeometry.y,
    width: w.clientGeometry.width, height: w.clientGeometry.height},
    frameHeight: w.frameGeometry.height, frameWidth: w.frameGeometry.width, fullScreen: w.fullScreen,
    maximizeArea: workspace.clientArea(KWin.MaximizeArea, w),
    maximizeMode: w.maximizeMode, active: w.active, minimized: w.minimized,
    output: w.output ? w.output.name : "", normalWindow: w.normalWindow, dialog: w.dialog,
    popupWindow: w.popupWindow, notification: w.notification,
    criticalNotification: w.criticalNotification}));"""

WINDOW_OP_BODY = """const want = %(id)s, op = %(op)s, a = %(a)s, b = %(b)s;
const w = workspace.windowList().find(w => String(w.internalId).replace(/[{}]/g, "") === want);
if (!w) throw new Error("no window " + want);
const g = w.frameGeometry, c = w.clientGeometry;
if (op === "fullscreen") w.fullScreen = true;
else if (op === "unfullscreen") w.fullScreen = false;
else if (op === "maximize") w.setMaximize(true, true);
else if (op === "unmaximize") w.setMaximize(false, false);
else if (op === "move") w.frameGeometry = {x: a - (c.x - g.x), y: b - (c.y - g.y), width: g.width, height: g.height};
else if (op === "resize") w.frameGeometry = {x: g.x, y: g.y, width: a + (g.width - c.width), height: b + (g.height - c.height)};
else if (op === "to_monitor") {
    const o = workspace.screens.find(s => s.name === a);
    if (!o) throw new Error("no output " + a);
    workspace.sendClientToScreen(w, o);
}
else if (op === "activate") workspace.activeWindow = w;
else if (op === "close") w.closeWindow();
else if (op === "above") w.keepAbove = true;
else throw new Error("unknown op " + op);
return "ok";"""

PING_BODY = "return workspace.screens.map(s => s.name);"

WINDOW_ID_RE = re.compile(r"^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")
OUTPUT_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
WINDOW_OPS = {"fullscreen": 0, "unfullscreen": 0, "maximize": 0, "unmaximize": 0, "move": 2,
              "resize": 2, "to_monitor": 1, "activate": 0, "close": 0, "above": 0}


def window_op_body(win_id, op, args):
    """build the script body for a window op"""
    if not WINDOW_ID_RE.match(win_id or ""):
        raise RuntimeError("window id %r is not a KWin internalId without braces" % win_id)
    if op not in WINDOW_OPS:
        raise RuntimeError("unknown window op %r" % op)
    if len(args) != WINDOW_OPS[op]:
        raise RuntimeError("%s takes %d argument(s), got %d" % (op, WINDOW_OPS[op], len(args)))
    a = b = "null"
    if WINDOW_OPS[op] == 2:
        try:
            a, b = (str(int(v)) for v in args)
        except ValueError:
            raise RuntimeError("%s takes two integers, got %s" % (op, " ".join(args)))
    elif op == "to_monitor":
        if not OUTPUT_NAME_RE.match(args[0]):
            raise RuntimeError("output name %r is not one KWin gives" % args[0])
        a = json.dumps(args[0])
    return WINDOW_OP_BODY % {"id": json.dumps(win_id), "op": json.dumps(op), "a": a, "b": b}


def render_script(nonce, body):
    """return the harness script text for a nonce and body"""
    return SCRIPT_FRAME % {"nonce": json.dumps(nonce), "dest": HARNESS_DEST, "path": HARNESS_PATH,
                           "iface": HARNESS_IFACE, "body": body}


def take_report(raw, nonce):
    """parse a Report argument for a nonce"""
    try:
        rep = json.loads(raw)
    except ValueError:
        return False, False, None
    if not isinstance(rep, dict) or rep.get("nonce") != nonce:
        return False, False, None
    return True, bool(rep.get("ok")), rep.get("data")


def run_script(conn, body, timeout=SCRIPT_TIMEOUT_S):
    """run a KWin script and return its report"""
    code = conn.request_name(HARNESS_DEST, dbus_min.NAME_FLAG_DO_NOT_QUEUE)
    if code not in (dbus_min.REQUEST_NAME_REPLY_PRIMARY_OWNER, dbus_min.REQUEST_NAME_REPLY_ALREADY_OWNER):
        raise RuntimeError("could not own %s: RequestName returned %d (another plasma-harness.py "
                           "running at once?)" % (HARNESS_DEST, code))
    conn.register_object(HARNESS_PATH, HARNESS_XML)
    nonce = "%d-%d" % (os.getpid(), time.monotonic_ns())
    name = "rhizo-harness-" + nonce
    fd, path = tempfile.mkstemp(prefix="rhizo-harness-", suffix=".js")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(render_script(nonce, body))
        (sid,) = conn.call(KWIN_DEST, SCRIPTING_PATH, SCRIPTING_IFACE, "loadScript", "ss", [path, name])
        if sid < 0:
            raise RuntimeError("kwin refused to load the script %s (loadScript returned %d)" % (path, sid))
        script_path = "/Scripting/Script%d" % sid
        try:
            conn.call(KWIN_DEST, script_path, SCRIPT_IFACE, "run", "", [])
            ok, data = _await_report(conn, nonce, timeout)
        except BaseException:
            _unload_script(conn, script_path, name)
            raise
        _unload_script(conn, script_path, name, strict=True)
    finally:
        os.unlink(path)
    if not ok:
        raise RuntimeError("the kwin script threw: %s" % data)
    return data


def _unload_script(conn, script_path, name, strict=False):
    """unload a KWin script"""
    errors = []
    try:
        conn.call(KWIN_DEST, script_path, SCRIPT_IFACE, "stop", "", [])
    except Exception as e:
        errors.append(e)
    try:
        (loaded,) = conn.call(KWIN_DEST, SCRIPTING_PATH, SCRIPTING_IFACE, "isScriptLoaded", "s", [name])
        if loaded:
            conn.call(KWIN_DEST, SCRIPTING_PATH, SCRIPTING_IFACE, "unloadScript", "s", [name])
    except Exception as e:
        errors.append(e)
    if strict and errors:
        raise RuntimeError("unloading the kwin script %s failed: %s" % (name, errors[0]))


def _await_report(conn, nonce, timeout):
    """wait for a Report call with the nonce"""
    deadline = time.monotonic() + timeout
    while True:
        for msg in conn.dispatch():
            if conn.handle_standard(msg) or msg.mtype != dbus_min.METHOD_CALL:
                continue
            if msg.interface == HARNESS_IFACE and msg.member == "Report" and msg.signature == "s":
                conn.send_reply(msg, "", [])
                matched, ok, data = take_report(msg.body[0], nonce)
                if matched:
                    return ok, data
            else:
                conn.send_error(msg, "org.freedesktop.DBus.Error.UnknownMethod",
                                "%s.%s is not answered here" % (msg.interface, msg.member))
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("the kwin script reported nothing within %.0fs" % timeout)
        select.select([conn.fileno()], [], [], remaining)


BUS_DEST, BUS_PATH, BUS_IFACE = "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus"


def await_name(conn, name, timeout):
    """return the process id of a bus name"""
    conn.add_match("type='signal',sender='%s',interface='%s',member='NameOwnerChanged',arg0='%s'"
                   % (BUS_DEST, BUS_IFACE, name))
    deadline = time.monotonic() + timeout
    (has,) = conn.call(BUS_DEST, BUS_PATH, BUS_IFACE, "NameHasOwner", "s", [name])
    while not has:
        has = any(m.mtype == dbus_min.SIGNAL and m.member == "NameOwnerChanged" and len(m.body) == 3
                  and m.body[0] == name and m.body[2] for m in conn.dispatch())
        if has:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("%s got no owner on the session bus within %.0fs" % (name, timeout))
        select.select([conn.fileno()], [], [], remaining)
    (pid,) = conn.call(BUS_DEST, BUS_PATH, BUS_IFACE, "GetConnectionUnixProcessID", "s", [name])
    return pid


NOTIFY_DEST = "org.freedesktop.Notifications"
NOTIFY_PATH = "/org/freedesktop/Notifications"
NOTIFY_IFACE = "org.freedesktop.Notifications"
NOTIFY_MANAGER_IFACE = "org.kde.NotificationManager"
WATCHER_PATH = "/NotificationWatcher"
WATCHER_IFACE = "org.kde.NotificationWatcher"
WATCHER_XML = ('<interface name="org.kde.NotificationWatcher"><method name="Notify">'
               '<arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="u" direction="in"/>'
               '<arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/>'
               '<arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/>'
               '</method><method name="CloseNotification"><arg type="u" direction="in"/></method></interface>')


def plain(v):
    """convert a D-Bus value to JSON data"""
    if isinstance(v, dbus_min.Variant):
        return plain(v.value)
    if isinstance(v, dict):
        return {k: plain(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [plain(x) for x in v]
    if isinstance(v, (bytes, bytearray)):
        return "<%d bytes>" % len(v)
    return v


def watch_event(mtype, iface, member, signature, body):
    """map a bus message to a record line"""
    if mtype == dbus_min.METHOD_CALL and iface == WATCHER_IFACE and member == "Notify" \
            and signature == "ususssasa{sv}i":
        nid, app, replaces, icon, summary, text, actions, hints, _timeout = body
        return {"event": "notify", "id": nid, "app_name": app, "replaces_id": replaces, "app_icon": icon,
                "summary": summary, "body": text, "actions": list(actions), "hints": plain(hints)}
    if mtype == dbus_min.SIGNAL and iface == NOTIFY_IFACE and member == "NotificationClosed" and signature == "uu":
        return {"event": "closed", "id": body[0], "reason": body[1]}
    if mtype == dbus_min.SIGNAL and iface == NOTIFY_IFACE and member == "ActionInvoked" and signature == "us":
        return {"event": "action", "id": body[0], "key": body[1]}
    return None


def cmd_notify_watch(record):
    """record notifications to a file"""
    conn = connect()
    conn.register_object(WATCHER_PATH, WATCHER_XML)
    conn.add_match("type='signal',sender='%s',path='%s',interface='%s'" % (NOTIFY_DEST, NOTIFY_PATH, NOTIFY_IFACE))
    conn.call(NOTIFY_DEST, NOTIFY_PATH, NOTIFY_MANAGER_IFACE, "RegisterWatcher", "", [])
    with open(record, "a", encoding="utf-8") as fh:
        print("ready", flush=True)
        while True:
            for msg in conn.dispatch():
                if conn.handle_standard(msg):
                    continue
                ev = watch_event(msg.mtype, msg.interface, msg.member, msg.signature, msg.body)
                if msg.mtype == dbus_min.METHOD_CALL:
                    if ev or (msg.interface == WATCHER_IFACE and msg.member == "CloseNotification"):
                        conn.send_reply(msg, "", [])
                    else:
                        conn.send_error(msg, "org.freedesktop.DBus.Error.UnknownMethod",
                                        "%s.%s is not answered here" % (msg.interface, msg.member))
                if ev:
                    fh.write(json.dumps(ev) + "\n")
                    fh.flush()
            select.select([conn.fileno()], [], [])


def open_notifications(lines):
    """return the unclosed notifications in a record"""
    live = {}
    for line in lines:
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("event") == "notify":
            live[ev["id"]] = ev
        elif ev.get("event") == "closed":
            live.pop(ev.get("id"), None)
    return live


def notification_json(ev):
    """map a notify event to list output"""
    hints = ev.get("hints") or {}
    icon = hints.get("image-path", "")
    return {"id": str(ev["id"]), "source": hints.get("desktop-entry", ev.get("app_name", "")),
            "title": ev.get("summary", ""), "body": ev.get("body", ""),
            "has_default_action": "default" in (ev.get("actions") or [])[0::2],
            "icon": icon if isinstance(icon, str) else ""}


def read_record(record):
    """return the lines of the notification record"""
    try:
        with open(record, encoding="utf-8") as fh:
            return fh.read().splitlines()
    except OSError as e:
        raise RuntimeError("the notification record %s did not read: %s" % (record, e))


def cmd_notifications_activate(conn, record, nid, key, timeout=10.0):
    """run a notification action"""
    live = open_notifications(read_record(record))
    ev = next((e for i, e in live.items() if str(i) == nid), None)
    if ev is None:
        raise RuntimeError("notification %s is not open in the watcher's record" % nid)
    declared = (ev.get("actions") or [])[0::2]
    if key not in declared:
        raise RuntimeError("notification %s declares no action '%s' (declared: %s)" % (nid, key, " ".join(declared) or "none"))
    conn.add_match("type='signal',sender='%s',path='%s',interface='%s'" % (NOTIFY_DEST, NOTIFY_PATH, NOTIFY_IFACE))
    conn.call(NOTIFY_DEST, NOTIFY_PATH, NOTIFY_MANAGER_IFACE, "InvokeAction", "us", [int(nid), key])
    want = {("action", int(nid), key)} | ({("closed", int(nid), None)} if key == "default" else set())
    deadline = time.monotonic() + timeout
    while True:
        for m in conn.dispatch():
            got = watch_event(m.mtype, m.interface, m.member, m.signature, m.body)
            if got:
                want.discard((got["event"], got["id"], got.get("key")))
        if not want:
            break
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("the server sent no %s for notification %s within %.0fs"
                               % (" or ".join(k for k, _i, _x in want), nid, timeout))
        select.select([conn.fileno()], [], [], remaining)
    if key == "default":
        while any(str(i) == nid for i in open_notifications(read_record(record))):
            if time.monotonic() >= deadline:
                raise RuntimeError("notification %s is still listed after activation -- expected it withdrawn" % nid)
            time.sleep(0.1)



def is_app_window(w):
    """return true for app and dialog windows"""
    return bool(w.get("normalWindow") or w.get("dialog")) and not w.get("popupWindow") \
        and not w.get("notification") and not w.get("criticalNotification")


def window_json(w):
    """map a KWin window to harness JSON"""
    f = w.get("rect") or {}
    out = {
        "id": str(w.get("internalId", "")).strip("{}"),
        "app_id": w.get("resourceClass") or w.get("desktopFileName") or "",
        "title": w.get("caption") or "",
        "x": round(f.get("x", 0)), "y": round(f.get("y", 0)),
        "w": round(f.get("width", 0)), "h": round(f.get("height", 0)),
        "decoration_h": max(0, round(w.get("frameHeight", f.get("height", 0)) - f.get("height", 0))),
        "fullscreen": bool(w.get("fullScreen")),
        "maximized": w.get("maximizeMode") == 3,
        "focused": bool(w.get("active")),
        "monitor": w.get("output") or "",
    }
    area = w.get("maximizeArea")
    if area and area.get("width") and area.get("height"):
        out["work_area"] = {"w": round(area["width"] - (w.get("frameWidth", f.get("width", 0)) - f.get("width", 0))),
                            "h": round(area["height"] - (w.get("frameHeight", f.get("height", 0)) - f.get("height", 0)))}
    return out


def windows_json(raw):
    """return the json form of each application window"""
    return [window_json(w) for w in raw if is_app_window(w)]


ROTATED = (2, 8)


def logical_rect(o):
    """return an output's rectangle in logical coordinates"""
    size = o.get("size") or {}
    scale = float(o.get("scale") or 1)
    w, h = size.get("width", 0), size.get("height", 0)
    if o.get("rotation") in ROTATED:
        w, h = h, w
    pos = o.get("pos") or {}
    return {"x": pos.get("x", 0), "y": pos.get("y", 0), "width": round(w / scale), "height": round(h / scale)}


def outputs_json(ks):
    """map kscreen-doctor JSON to the outputs list"""
    enabled = [o for o in ks.get("outputs", []) if o.get("enabled")]
    first = min((o.get("priority", 0) for o in enabled), default=None)
    out = []
    for o in enabled:
        mode = next((m for m in o.get("modes", []) if m.get("id") == o.get("currentModeId")), {})
        msize = mode.get("size") or {}
        out.append({
            "name": o.get("name"),
            "active": True,
            "primary": o.get("priority", 0) == first,
            "scale": float(o.get("scale") or 1),
            "rect": logical_rect(o),
            "current_mode": {"width": msize.get("width"), "height": msize.get("height"),
                             "refresh": mode.get("refreshRate")},
        })
    return out


def output_to_add(ks, w, h):
    """return the disabled output name and x"""
    enabled = [o for o in ks.get("outputs", []) if o.get("enabled")]
    maxx = max((logical_rect(o)["x"] + logical_rect(o)["width"] for o in enabled), default=0)
    for o in ks.get("outputs", []):
        if o.get("enabled"):
            continue
        mode = next((m for m in o.get("modes", []) if m.get("id") == o.get("currentModeId")), {})
        if (mode.get("size") or {}) == {"width": w, "height": h}:
            return o.get("name"), maxx
    raise RuntimeError("outputs add %dx%d: no disabled output has that mode" % (w, h))


def _name_key(name):
    """split a name into its text and trailing number for ordering"""
    m = re.match(r"^(.*?)(\d+)$", name or "")
    return (m.group(1), int(m.group(2))) if m else (name or "", -1)


def reset_args(ks, scale_only=False):
    """return the kscreen-doctor reset arguments"""
    if scale_only:
        return ["output.%s.scale.1" % o.get("name") for o in ks.get("outputs", [])
                if o.get("enabled") and float(o.get("scale") or 1) != 1.0]
    outs = sorted(ks.get("outputs", []), key=lambda o: _name_key(o.get("name")))
    args, x = [], 0
    for prio, o in enumerate(outs, start=1):
        name = o.get("name")
        mode = next((m for m in o.get("modes", []) if m.get("id") == o.get("currentModeId")), {})
        wrong_prio = len(outs) > 1 and o.get("priority") != prio
        if not o.get("enabled") or float(o.get("scale") or 1) != 1.0 or (o.get("pos") or {}) != {"x": x, "y": 0} \
                or wrong_prio:
            args += ["output.%s.enable" % name, "output.%s.scale.1" % name, "output.%s.position.%d,0" % (name, x)]
            if len(outs) > 1:
                args.append("output.%s.priority.%d" % (name, prio))
        x += (mode.get("size") or {}).get("width", 0)
    return args


def kscreen(*args, timeout=20.0):
    """run kscreen-doctor and return its output"""
    try:
        out = subprocess.run(["kscreen-doctor"] + list(args), capture_output=True, text=True,
                             timeout=max(timeout, 0.1), stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise RuntimeError("kscreen-doctor %s did not finish within %.0fs" % (" ".join(args), timeout))
    if out.returncode != 0:
        raise RuntimeError("kscreen-doctor %s exited %d: %s" % (" ".join(args), out.returncode,
                                                                out.stderr.strip()[:300]))
    return out.stdout


def kscreen_state(timeout=20.0):
    """return the parsed kscreen-doctor json state"""
    raw = kscreen("--json", timeout=timeout)
    try:
        return json.loads(raw)
    except ValueError:
        raise RuntimeError("kscreen-doctor --json printed no JSON: %r" % raw[:200])


def poll_kscreen(predicate, what, deadline_s=10.0):
    """poll the layout for a predicate"""
    deadline = time.monotonic() + deadline_s
    while True:
        ks = kscreen_state(timeout=deadline - time.monotonic())
        if predicate(ks):
            return ks
        if time.monotonic() >= deadline:
            raise RuntimeError("%s did not take within %.0fs" % (what, deadline_s))
        time.sleep(min(0.25, max(deadline - time.monotonic(), 0)))


def _output(ks, name):
    """return the output of the given name, or None"""
    return next((o for o in ks.get("outputs", []) if o.get("name") == name), None)


OUTPUTS_ARGS = {"list": 0, "add": 1, "remove": 1, "scale": 2, "reset": 0, "reset-scale": 0}


def cmd_outputs(verb, args):
    """run an outputs verb through kscreen-doctor"""
    if len(args) != OUTPUTS_ARGS[verb]:
        raise RuntimeError("outputs %s takes %d argument(s), got %d" % (verb, OUTPUTS_ARGS[verb], len(args)))
    ks = kscreen_state()
    if verb == "list":
        print(json.dumps(outputs_json(ks)))
    elif verb == "add":
        w, h = (int(v) for v in args[0].split("x"))
        name, x = output_to_add(ks, w, h)
        kscreen("output.%s.enable" % name, "output.%s.position.%d,0" % (name, x))
        poll_kscreen(lambda s: (_output(s, name) or {}).get("enabled")
                     and (_output(s, name).get("pos") or {}).get("x") == x, "enabling %s at %d,0" % (name, x))
        print(name)
    elif verb == "remove":
        name = args[0]
        if not (_output(ks, name) or {}).get("enabled"):
            raise RuntimeError("outputs remove %s: no enabled output has that name" % name)
        kscreen("output.%s.disable" % name)
        poll_kscreen(lambda s: not (_output(s, name) or {}).get("enabled"), "disabling %s" % name)
    elif verb == "scale":
        name, scale = args[0], float(args[1])
        if not (_output(ks, name) or {}).get("enabled"):
            raise RuntimeError("outputs scale %s: no enabled output has that name" % name)
        kscreen("output.%s.scale.%s" % (name, args[1]))
        poll_kscreen(lambda s: abs(float((_output(s, name) or {}).get("scale") or 0) - scale) < 1e-6,
                     "scale %s on %s" % (args[1], name))
    elif verb in ("reset", "reset-scale"):
        scale_only = verb == "reset-scale"
        change = reset_args(ks, scale_only)
        if change:
            kscreen(*change)
            poll_kscreen(lambda s: not reset_args(s, scale_only), "putting the outputs back (%s)" % " ".join(change))
        print("reset: %s" % (" ".join(change) or "nothing to put back"))


CLUTTER_POINTER, CLUTTER_KEYBOARD, CLUTTER_TABLET, CLUTTER_TOUCHPAD, CLUTTER_TOUCHSCREEN = 0, 1, 4, 5, 6


def device_json(props):
    """map a KWin input device to JSON"""
    if props.get("keyboard"):
        kind = CLUTTER_KEYBOARD
    elif props.get("touchpad"):
        kind = CLUTTER_TOUCHPAD
    elif props.get("pointer"):
        kind = CLUTTER_POINTER
    elif props.get("touch"):
        kind = CLUTTER_TOUCHSCREEN
    elif props.get("tabletTool"):
        kind = CLUTTER_TABLET
    else:
        kind = None
    return {"name": props.get("name", ""), "device_type": kind,
            "vendor_id": "%04x" % props.get("vendor", 0), "product_id": "%04x" % props.get("product", 0)}


def _plain(props):
    """unwrap D-Bus variants in a property map"""
    return {k: (v.value if isinstance(v, dbus_min.Variant) else v) for k, v in props.items()}


def cmd_seat_devices(conn):
    """return the seat's input devices from kwin"""
    try:
        (names,) = conn.call(KWIN_DEST, INPUT_PATH, PROPS_IFACE, "Get", "ss",
                             [INPUT_MANAGER_IFACE, "devicesSysNames"])
    except dbus_min.DBusError as e:
        raise Cannot("kwin exports no %s at %s (%s): a kwin_wayland --virtual has no libinput "
                     "devices to list" % (INPUT_MANAGER_IFACE, INPUT_PATH, e))
    out = []
    for sysname in names.value if isinstance(names, dbus_min.Variant) else names:
        (props,) = conn.call(KWIN_DEST, "%s/%s" % (INPUT_PATH, sysname), PROPS_IFACE, "GetAll", "s",
                             [INPUT_DEVICE_IFACE])
        out.append(device_json(_plain(props)))
    return out


PNG_SIG = b"\x89PNG\r\n\x1a\n"


def png_decode(data):
    """decode an 8-bit PNG into rows"""
    if data[:8] != PNG_SIG:
        raise RuntimeError("not a PNG")
    pos, idat, ihdr = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + n
    if ihdr is None:
        raise RuntimeError("a PNG with no IHDR")
    w, h, depth, ctype, _comp, _filt, interlace = ihdr
    if depth != 8 or ctype not in (2, 6) or interlace:
        raise RuntimeError("PNG depth %d color type %d interlace %d: only 8-bit RGB/RGBA, "
                           "non-interlaced, is cropped here" % (depth, ctype, interlace))
    bpp = 3 if ctype == 2 else 4
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        base = y * (stride + 1)
        ftype, line = raw[base], bytearray(raw[base + 1:base + 1 + stride])
        for i in range(stride):
            left = line[i - bpp] if i >= bpp else 0
            up, ul = prev[i], (prev[i - bpp] if i >= bpp else 0)
            if ftype == 1:
                line[i] = (line[i] + left) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + up) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + ((left + up) >> 1)) & 0xFF
            elif ftype == 4:
                p = left + up - ul
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else ul)) & 0xFF
            elif ftype != 0:
                raise RuntimeError("PNG row %d has filter type %d" % (y, ftype))
        rows.append(bytes(line))
        prev = line
    return w, h, bpp, rows


def png_encode(w, h, bpp, rows):
    """encode raw rows as a PNG"""
    def chunk(kind, body):
        """return a PNG chunk with its length and checksum"""
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + r for r in rows)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2 if bpp == 3 else 6, 0, 0, 0)
    return PNG_SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")


def png_crop(data, x, y, w, h):
    """return a cropped PNG of a region of the capture"""
    iw, ih, bpp, rows = png_decode(data)
    if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > iw or y + h > ih:
        raise RuntimeError("crop %d,%d %dx%d lies outside the %dx%d capture" % (x, y, w, h, iw, ih))
    return png_encode(w, h, bpp, [r[x * bpp:(x + w) * bpp] for r in rows[y:y + h]])


def capture_rect(outputs, rect, img_w, img_h):
    """map a layout rect to capture pixels"""
    rects = [o["rect"] for o in outputs]
    if not rects:
        raise RuntimeError("no enabled output to map a region onto")
    x0, y0 = min(r["x"] for r in rects), min(r["y"] for r in rects)
    bw = max(r["x"] + r["width"] for r in rects) - x0
    bh = max(r["y"] + r["height"] for r in rects) - y0
    kx, ky = img_w / bw, img_h / bh
    if abs(kx - ky) > 1e-6:
        raise RuntimeError("the %dx%d capture scales the %dx%d layout by %.4f across and %.4f down"
                           % (img_w, img_h, bw, bh, kx, ky))
    x, y, w, h = rect
    return round((x - x0) * kx), round((y - y0) * kx), round(w * kx), round(h * kx)


def output_crop(outputs, name, img_w, img_h):
    """return the capture rect of an output"""
    target = next((o["rect"] for o in outputs if o["name"] == name), None)
    if target is None:
        raise RuntimeError("shot --output %s: no enabled output has that name" % name)
    return capture_rect(outputs, (target["x"], target["y"], target["width"], target["height"]), img_w, img_h)


def cmd_shot(out_path, region, output):
    """capture the screen with spectacle and crop it"""
    try:
        os.unlink(out_path)
    except FileNotFoundError:
        pass
    work = tempfile.mkdtemp(prefix="rhizo-plasma-shot-")
    try:
        full = os.path.join(work, "full.png")
        try:
            res = subprocess.run(["spectacle", "--background", "--nonotify", "--fullscreen", "--pointer", "--output", full],
                                 capture_output=True, text=True, timeout=30, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            raise RuntimeError("spectacle did not finish within 30s")
        if res.returncode != 0:
            raise RuntimeError("spectacle exited %d: %s" % (res.returncode, res.stderr.strip()[:300]))
        try:
            with open(full, "rb") as fh:
                data = fh.read()
        except OSError as e:
            raise RuntimeError("spectacle exited 0 and wrote no %s: %s" % (full, e))
        if data[:8] != PNG_SIG:
            raise RuntimeError("spectacle wrote %d bytes that are not a PNG" % len(data))
        if output or region:
            iw, ih = struct.unpack(">II", data[16:24])
            outs = outputs_json(kscreen_state())
            rect = output_crop(outs, output, iw, ih) if output else capture_rect(outs, region, iw, ih)
            data = png_crop(data, *rect)
        tmp = out_path + ".part"
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, out_path)
    finally:
        shutil.rmtree(work)
    return out_path



def connect():
    """connect to the session bus and say hello"""
    conn = dbus_min.Connection.connect()
    conn.hello()
    return conn


def main_run(args):
    """run the chosen command and return its exit status"""
    if args.cmd == "shot":
        region = tuple(args.region) if args.region else None
        if region and len(region) != 4:
            raise RuntimeError("shot takes x y w h, got %s" % " ".join(map(str, region)))
        print(cmd_shot(args.out, region, args.output))
        return 0
    if args.cmd == "outputs":
        cmd_outputs(args.outputs_verb, args.rest)
        return 0
    if args.cmd == "notify-watch":
        cmd_notify_watch(args.record)
        return 0
    if args.cmd == "notifications" and args.notif_verb == "list":
        for ev in open_notifications(read_record(args.record)).values():
            print(json.dumps(notification_json(ev)))
        return 0
    conn = connect()
    if args.cmd == "await-name":
        print("owner %s pid=%d" % (args.name, await_name(conn, args.name, args.seconds)))
    elif args.cmd == "ping":
        (pid,) = conn.call(BUS_DEST, BUS_PATH, BUS_IFACE, "GetConnectionUnixProcessID", "s", [KWIN_DEST])
        screens = run_script(conn, PING_BODY)
        print("rhizo-harness kwin pid=%d outputs=%s" % (pid, ",".join(screens)))
    elif args.cmd == "windows":
        for w in windows_json(run_script(conn, WINDOWS_BODY)):
            print(json.dumps(w))
    elif args.cmd == "window-op":
        run_script(conn, window_op_body(args.id, args.op, args.args))
    elif args.cmd == "notifications":
        if not args.id:
            raise RuntimeError("notifications activate takes the notification's id")
        cmd_notifications_activate(conn, args.record, args.id, args.key)
        print("invoked=%s" % args.key)
    elif args.cmd == "seat-devices":
        print(json.dumps(cmd_seat_devices(conn)))
    elif args.cmd == "layouts":
        (layouts,) = conn.call(KWIN_DEST, LAYOUTS_PATH, LAYOUTS_IFACE, "getLayoutsList", "", [])
        print(" ".join(short for short, _variant, _name in layouts))
    return 0


def build_parser():
    """build the argument parser with every subcommand"""
    ap = argparse.ArgumentParser(description=__doc__ + "\n\n" + USAGE, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true")
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("await-name")
    p.add_argument("name")
    p.add_argument("seconds", type=float)
    sub.add_parser("ping")
    sub.add_parser("windows")
    p = sub.add_parser("window-op")
    p.add_argument("id")
    p.add_argument("op")
    p.add_argument("args", nargs="*")
    p = sub.add_parser("notify-watch")
    p.add_argument("--record", required=True)
    p = sub.add_parser("notifications")
    p.add_argument("notif_verb", choices=["list", "activate"])
    p.add_argument("id", nargs="?")
    p.add_argument("key", nargs="?", default="default")
    p.add_argument("--record", required=True)
    p = sub.add_parser("outputs")
    p.add_argument("outputs_verb", choices=["list", "add", "remove", "scale", "reset", "reset-scale"])
    p.add_argument("rest", nargs="*")
    sub.add_parser("seat-devices")
    sub.add_parser("layouts")
    p = sub.add_parser("shot")
    p.add_argument("out")
    p.add_argument("region", nargs="*", type=int, help="x y w h")
    p.add_argument("--output", help="crop to one output's rect")
    return ap


def main():
    """parse the arguments and run the chosen command or the selftest"""
    ap = build_parser()
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if not args.cmd:
        ap.error("a subcommand is required outside --selftest")
    try:
        return main_run(args)
    except Cannot as e:
        sys.stderr.write("plasma-harness.py %s: %s\n" % (args.cmd, e))
        return EXIT_CANNOT
    except (dbus_min.DBusError, RuntimeError, TimeoutError, ConnectionError, OSError) as e:
        sys.stderr.write("plasma-harness.py %s: %s\n" % (args.cmd, e))
        return 1



def selftest():
    """run the offline checks"""
    n = 0

    def check(cond, what):
        """count a passing check and raise on a failing one"""
        nonlocal n
        if not cond:
            raise AssertionError(what)
        n += 1

    foot = {"internalId": "{a7b1e12a-80c6-4df5-8df6-015757f367d2}", "resourceClass": "t24foot",
            "desktopFileName": "t24foot", "caption": "~ - fish", "rect": {"x": 652, "y": 296.5,
            "width": 696, "height": 532}, "frameHeight": 568, "fullScreen": False, "maximizeMode": 3, "active": True,
            "output": "Virtual-0", "normalWindow": True, "dialog": False, "popupWindow": False,
            "notification": False, "criticalNotification": False}
    menu = dict(foot, internalId="{1a23c960-79e6-4010-a0ee-3f5610ff77ad}", resourceClass="",
                popupWindow=True)
    panel = dict(foot, internalId="{6227a99e-f080-4ad9-850d-d99db7bd5ca0}", resourceClass="plasmashell",
                 normalWindow=False)
    toast = dict(foot, internalId="{9b29cf03-636a-44bf-b16e-769733324df2}", resourceClass="plasmashell",
                 caption="hello", normalWindow=False, notification=True)
    got = windows_json([foot, menu, panel, toast])
    check(got == [{"id": "a7b1e12a-80c6-4df5-8df6-015757f367d2", "app_id": "t24foot", "title": "~ - fish",
                   "x": 652, "y": 296, "w": 696, "h": 532, "decoration_h": 36, "fullscreen": False, "maximized": True,
                   "focused": True, "monitor": "Virtual-0"}], "windows: %r" % got)
    check(window_json(dict(foot, maximizeMode=1))["maximized"] is False, "vertical-only maximize read as maximized")
    paneled = window_json(dict(foot, frameWidth=696, maximizeArea={"x": 0, "y": 0, "width": 1280, "height": 754}))
    check(paneled["work_area"] == {"w": 1280, "h": 718}, "the maximize area less the frame: %r" % paneled)
    check(window_json(dict(foot, resourceClass="", desktopFileName="org.x"))["app_id"] == "org.x",
          "app_id falls back to desktopFileName")

    notify = watch_event(dbus_min.METHOD_CALL, WATCHER_IFACE, "Notify", "ususssasa{sv}i",
                         [1, "rhizo-proof", 0, "", "rhizo proof", "a notification body",
                          ["default", "Open", "other", "Other"],
                          {"sender-pid": dbus_min.Variant("x", 8340), "image-data": dbus_min.Variant("ay", b"abc")}, -1])
    check(notify == {"event": "notify", "id": 1, "app_name": "rhizo-proof", "replaces_id": 0, "app_icon": "",
                     "summary": "rhizo proof", "body": "a notification body",
                     "actions": ["default", "Open", "other", "Other"],
                     "hints": {"sender-pid": 8340, "image-data": "<3 bytes>"}}, "a Notify call: %r" % notify)
    second = dict(notify, id=2, summary="second", actions=[], hints={"desktop-entry": "rhizo-x", "image-path": "/i.png"})
    closed = watch_event(dbus_min.SIGNAL, NOTIFY_IFACE, "NotificationClosed", "uu", [1, 3])
    action = watch_event(dbus_min.SIGNAL, NOTIFY_IFACE, "ActionInvoked", "us", [1, "default"])
    check(closed == {"event": "closed", "id": 1, "reason": 3} and action == {"event": "action", "id": 1, "key": "default"},
          "the close and action signals: %r %r" % (closed, action))
    check(watch_event(dbus_min.METHOD_CALL, WATCHER_IFACE, "Notify", "us", [1, "x"]) is None,
          "a Notify of another signature read as a notification")
    lines = [json.dumps(e) for e in (notify, second)] + ["not json"]
    check([notification_json(e) for e in open_notifications(lines).values()] ==
          [{"id": "1", "source": "rhizo-proof", "title": "rhizo proof", "body": "a notification body",
            "has_default_action": True, "icon": ""},
           {"id": "2", "source": "rhizo-x", "title": "second", "body": "a notification body",
            "has_default_action": False, "icon": "/i.png"}], "the open notifications in gnome's shape")
    check(list(open_notifications(lines + [json.dumps(closed)])) == [2], "a closed notification still listed")

    for bad, why in ((("{a7b1}", "close", []), "not a KWin internalId"), (("a7b1e12a-80c6-4df5-8df6-015757f367d2",
                     "explode", []), "unknown window op"), (("a7b1e12a-80c6-4df5-8df6-015757f367d2", "move", ["1"]),
                     "takes 2 argument"), (("a7b1e12a-80c6-4df5-8df6-015757f367d2", "move", ["1", "x"]),
                     "two integers"), (("a7b1e12a-80c6-4df5-8df6-015757f367d2", "to_monitor", ['V"); x(']),
                     "not one KWin gives")):
        try:
            window_op_body(*bad)
        except RuntimeError as e:
            check(why in str(e), "window-op %r refused for %s, not %s" % (bad, e, why))
        else:
            check(False, "window-op %r was not refused" % (bad,))
    body = window_op_body("a7b1e12a-80c6-4df5-8df6-015757f367d2", "move", ["100", "50"])
    check('want = "a7b1e12a-80c6-4df5-8df6-015757f367d2", op = "move", a = 100, b = 50' in body, body[:120])
    body = window_op_body("a7b1e12a-80c6-4df5-8df6-015757f367d2", "to_monitor", ["Virtual-1"])
    check('a = "Virtual-1", b = null' in body, body[:120])

    check(take_report(json.dumps({"nonce": "1-2", "ok": True, "data": [1]}), "1-2") == (True, True, [1]),
          "this call's report taken")
    check(take_report(json.dumps({"nonce": "9-9", "ok": True, "data": [1]}), "1-2")[0] is False,
          "another call's report taken as this one's")
    check(take_report("not json", "1-2")[0] is False, "a non-report taken")
    script = render_script("1-2", "return 1;")
    check('const nonce = "1-2";' in script and '"Report"' in script, script[:200])

    ks = {"outputs": [
        {"name": "Virtual-1", "enabled": True, "priority": 2, "scale": 2, "rotation": 1,
         "pos": {"x": 1920, "y": 0}, "size": {"width": 1920, "height": 1080}, "currentModeId": "1",
         "modes": [{"id": "1", "refreshRate": 60, "size": {"width": 1920, "height": 1080}}]},
        {"name": "Virtual-0", "enabled": True, "priority": 1, "scale": 1, "rotation": 1,
         "pos": {"x": 0, "y": 0}, "size": {"width": 1920, "height": 1080}, "currentModeId": "1",
         "modes": [{"id": "1", "refreshRate": 60, "size": {"width": 1920, "height": 1080}}]},
        {"name": "Virtual-2", "enabled": False, "priority": 3, "scale": 1, "rotation": 1,
         "pos": {"x": 0, "y": 0}, "size": {"width": 1280, "height": 720}, "currentModeId": "1",
         "modes": [{"id": "1", "refreshRate": 60, "size": {"width": 1280, "height": 720}}]}]}
    outs = outputs_json(ks)
    check([o["name"] for o in outs] == ["Virtual-1", "Virtual-0"], "a disabled output listed: %r" % outs)
    check(outs[0]["rect"] == {"x": 1920, "y": 0, "width": 960, "height": 540} and outs[0]["primary"] is False,
          "a scale-2 output's logical rect: %r" % outs[0])
    check(outs[1]["primary"] is True and outs[1]["current_mode"] == {"width": 1920, "height": 1080, "refresh": 60},
          "the primary and its mode: %r" % outs[1])
    check(logical_rect(dict(ks["outputs"][1], rotation=2))["width"] == 1080, "a rotated output kept its width")
    check(output_to_add(ks, 1280, 720) == ("Virtual-2", 2880), "add placement: %r" % (output_to_add(ks, 1280, 720),))
    try:
        output_to_add(ks, 800, 600)
    except RuntimeError as e:
        check("no disabled output has that mode" in str(e), str(e))
    else:
        check(False, "add of a size no disabled output has was not refused")
    check(reset_args(ks) == ["output.Virtual-1.enable", "output.Virtual-1.scale.1", "output.Virtual-1.position.1920,0",
                             "output.Virtual-1.priority.2", "output.Virtual-2.enable", "output.Virtual-2.scale.1",
                             "output.Virtual-2.position.3840,0", "output.Virtual-2.priority.3"],
          "reset of a scaled and a disabled output: %r" % reset_args(ks))
    start = {"outputs": [dict(o, enabled=True, scale=1, pos={"x": 1920 * i, "y": 0}, priority=i + 1) for i, o in
                         enumerate(sorted(ks["outputs"], key=lambda o: o["name"]))]}
    check(reset_args(start) == [], "reset of the start layout: %r" % reset_args(start))
    swapped = {"outputs": [dict(o, priority=2 if o["name"] == "Virtual-0" else 1 if o["name"] == "Virtual-1" else 3)
                           for o in start["outputs"]]}
    check(reset_args(swapped) == ["output.Virtual-0.enable", "output.Virtual-0.scale.1", "output.Virtual-0.position.0,0",
                                  "output.Virtual-0.priority.1", "output.Virtual-1.enable", "output.Virtual-1.scale.1",
                                  "output.Virtual-1.position.1920,0", "output.Virtual-1.priority.2"],
          "reset of swapped priorities: %r" % reset_args(swapped))
    lone = {"outputs": [dict(start["outputs"][0], priority=0)]}
    check(reset_args(lone) == [], "a lone output's priority 0 read as wrong: %r" % reset_args(lone))
    check(reset_args(ks, scale_only=True) == ["output.Virtual-1.scale.1"],
          "a seat login's scale-only reset: %r" % reset_args(ks, scale_only=True))
    check(capture_rect(outs, (1930, 20, 100, 50), 5760, 2160) == (3860, 40, 200, 100),
          "a region on the scale-2 output: %r" % (capture_rect(outs, (1930, 20, 100, 50), 5760, 2160),))
    moved = [dict(outs[1], rect={"x": 1920, "y": 0, "width": 1920, "height": 1080})]
    check(capture_rect(moved, (2000, 10, 100, 50), 1920, 1080) == (80, 10, 100, 50),
          "a region on a layout not at 0,0: %r" % (capture_rect(moved, (2000, 10, 100, 50), 1920, 1080),))
    check(output_crop(outs, "Virtual-1", 5760, 2160) == (3840, 0, 1920, 1080),
          "the scale-2 output's capture rect: %r" % (output_crop(outs, "Virtual-1", 5760, 2160),))
    try:
        output_crop(outs, "Virtual-1", 5760, 1080)
    except RuntimeError as e:
        check("across" in str(e), str(e))
    else:
        check(False, "a capture scaled unevenly was cropped")

    check(device_json({"name": "AT Translated Set 2 keyboard", "keyboard": True, "pointer": False,
                       "vendor": 1, "product": 1}) == {"name": "AT Translated Set 2 keyboard",
                                                       "device_type": CLUTTER_KEYBOARD,
                                                       "vendor_id": "0001", "product_id": "0001"},
          "a keyboard device")
    check(device_json({"name": "VMMouse", "pointer": True, "vendor": 2, "product": 19})["device_type"]
          == CLUTTER_POINTER and device_json({"vendor": 2, "product": 19})["product_id"] == "0013",
          "a pointer device")

    pixels = [b"".join(bytes([x, y, (x * y) & 0xFF, 255]) for x in range(5)) for y in range(6)]
    plain = png_encode(5, 6, 4, pixels)
    sub_raw = b"".join(b"\x01" + bytes((p[i] - (p[i - 4] if i >= 4 else 0)) & 0xFF for i in range(len(p)))
                       for p in pixels)
    start = plain.index(b"IDAT") - 4
    end = start + 12 + struct.unpack(">I", plain[start:start + 4])[0]
    body = zlib.compress(sub_raw)
    sub_png = plain[:start] + struct.pack(">I", len(body)) + b"IDAT" + body \
        + struct.pack(">I", zlib.crc32(b"IDAT" + body) & 0xFFFFFFFF) + plain[end:]
    w, h, bpp, back = png_decode(png_crop(sub_png, 1, 2, 3, 2))
    check((w, h, bpp) == (3, 2, 4) and back == [pixels[2][4:16], pixels[3][4:16]],
          "a sub-filtered PNG cropped to 1,2 3x2")
    try:
        png_crop(sub_png, 3, 0, 3, 1)
    except RuntimeError as e:
        check("outside" in str(e), str(e))
    else:
        check(False, "a crop past the capture's edge was taken")
    class FakeMsg:
        mtype, interface, member, signature = dbus_min.METHOD_CALL, HARNESS_IFACE, "Report", "s"

        def __init__(self, body):
            """hold the body of a fake message"""
            self.body = [body]

    class FakeConn:
        def __init__(self, fail):
            """start a fake connection with the calls that should fail"""
            self.fail, self.calls, self.nonce = fail, [], None

        def request_name(self, name, flags):
            """accept the requested bus name"""
            return dbus_min.REQUEST_NAME_REPLY_PRIMARY_OWNER

        def register_object(self, path, xml):
            """ignore an object registration"""
            pass

        def call(self, dest, path, iface, member, sig, args, timeout=5.0):
            """record the call and answer script loads and queries"""
            self.calls.append(member)
            if member == "loadScript":
                with open(args[0], encoding="utf-8") as fh:
                    self.nonce = re.search(r'const nonce = "([^"]+)"', fh.read()).group(1)
                return [7]
            if member in self.fail:
                raise self.fail[member]
            return [True] if member == "isScriptLoaded" else []

        def dispatch(self):
            """return a fake report message carrying the loaded nonce"""
            return [FakeMsg(json.dumps({"nonce": self.nonce, "ok": True, "data": "fine"}))]

        def handle_standard(self, msg):
            """decline to handle a standard call"""
            return False

        def send_reply(self, *args):
            """ignore a reply"""
            pass

    fake = FakeConn({"run": ValueError("run broke"), "stop": KeyError("stop broke")})
    try:
        run_script(fake, "return 1;")
        check(False, "a run that raised returned")
    except ValueError as e:
        check(str(e) == "run broke", "the run's error was replaced: %r" % e)
    except BaseException as e:
        check(False, "the run's error was replaced by %r" % e)
    check(fake.calls[-3:] == ["stop", "isScriptLoaded", "unloadScript"],
          "the unload after a raising stop() on the error path: %r" % fake.calls)
    fake = FakeConn({"stop": OSError("stop broke")})
    try:
        run_script(fake, "return 1;")
        check(False, "a stop() that raised after a good run went unreported")
    except RuntimeError as e:
        check("unloading the kwin script" in str(e) and "stop broke" in str(e), str(e))
    check(fake.calls[-2:] == ["isScriptLoaded", "unloadScript"], "the unload after a raising stop(): %r" % fake.calls)
    fake = FakeConn({})
    check(run_script(fake, "return 1;") == "fine" and fake.calls[-3:] == ["stop", "isScriptLoaded", "unloadScript"],
          "a clean run: %r" % fake.calls)

    class Waited(Exception):
        pass

    class Sig:
        def __init__(self, iface, member, signature, body):
            """hold a fake signal message"""
            self.mtype, self.interface, self.member, self.signature, self.body = \
                dbus_min.SIGNAL, iface, member, signature, body

    class FakeBus:
        def __init__(self, replies, batches):
            """start a fake bus with canned replies and message batches"""
            self.replies, self.buffered, self.later = replies, list(batches[0]), [list(b) for b in batches[1:]]
            self.calls, self.waits = [], 0

        def add_match(self, rule):
            """ignore a match rule"""
            pass

        def call(self, dest, path, iface, member, sig, args, timeout=5.0):
            """record the call and return its canned reply"""
            self.calls.append(member)
            r = self.replies[member]
            return r(args) if callable(r) else r

        def dispatch(self):
            """return the buffered messages and clear them"""
            out, self.buffered = self.buffered, []
            return out

        def fileno(self):
            """return a placeholder file descriptor"""
            return -1

        def select(self, rlist, wlist, xlist, timeout=None):
            """release the next batch of messages"""
            if self.buffered:
                raise Waited("waited with %d message(s) already buffered" % len(self.buffered))
            self.waits += 1
            if self.later:
                self.buffered = self.later.pop(0)
                return rlist, [], []
            return [], [], []

    def waiting(bus, fn, *args):
        """run a function with select replaced by the bus's select"""
        real = select.select
        select.select = bus.select
        try:
            return fn(bus, *args)
        finally:
            select.select = real

    owner = Sig(BUS_IFACE, "NameOwnerChanged", "sss", ["org.kde.t24", "", ":1.42"])
    name_replies = {"NameHasOwner": [False], "GetConnectionUnixProcessID": [4242]}
    bus = FakeBus(name_replies, [[owner]])
    try:
        check(waiting(bus, await_name, "org.kde.t24", 5.0) == 4242 and bus.waits == 0,
              "await_name with the owner buffered by NameHasOwner: %r" % bus.calls)
    except Waited as e:
        check(False, "await_name %s" % e)
    bus = FakeBus(name_replies, [[], [Sig(BUS_IFACE, "NameOwnerChanged", "sss", ["org.kde.other", "", ":1.9"])],
                                 [owner]])
    check(waiting(bus, await_name, "org.kde.t24", 5.0) == 4242 and bus.waits == 2,
          "await_name with the owner arriving on the second wait, another name's first: %d waits" % bus.waits)
    bus = FakeBus(name_replies, [[]])
    try:
        waiting(bus, await_name, "org.kde.t24", 0)
        check(False, "await_name returned with no owner")
    except RuntimeError as e:
        check(str(e) == "org.kde.t24 got no owner on the session bus within 0s", str(e))

    nd = tempfile.mkdtemp(prefix="plasma-harness-selftest-")
    try:
        record = os.path.join(nd, "record")

        def opened():
            """write a notify event to the record"""
            with open(record, "w", encoding="utf-8") as fh:
                fh.write(json.dumps({"event": "notify", "id": 1, "app_name": "t24", "summary": "s",
                                     "actions": ["default", "Open", "later", "Later"], "hints": {}}) + "\n")

        def invoked(args):
            """write a closed event to the record"""
            with open(record, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"event": "closed", "id": args[0], "reason": 2}) + "\n")
            return []

        action = Sig(NOTIFY_IFACE, "ActionInvoked", "us", [1, "default"])
        closed = Sig(NOTIFY_IFACE, "NotificationClosed", "uu", [1, 2])
        opened()
        bus = FakeBus({"InvokeAction": invoked}, [[action, closed]])
        try:
            waiting(bus, cmd_notifications_activate, record, "1", "default", 5.0)
            check(bus.waits == 0 and bus.calls == ["InvokeAction"],
                  "activate with ActionInvoked and the close buffered by InvokeAction: %r" % bus.calls)
        except Waited as e:
            check(False, "activate %s" % e)
        opened()
        bus = FakeBus({"InvokeAction": invoked}, [[], [action], [closed]])
        waiting(bus, cmd_notifications_activate, record, "1", "default", 5.0)
        check(bus.waits == 2, "activate with ActionInvoked and the close on two waits: %d waits" % bus.waits)
        opened()
        bus = FakeBus({"InvokeAction": []}, [[]])
        try:
            waiting(bus, cmd_notifications_activate, record, "1", "later", 0)
            check(False, "activate returned with no ActionInvoked")
        except RuntimeError as e:
            check(str(e) == "the server sent no action for notification 1 within 0s", str(e))
    finally:
        shutil.rmtree(nd)
    print("plasma-harness selftest: %d assertions" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
