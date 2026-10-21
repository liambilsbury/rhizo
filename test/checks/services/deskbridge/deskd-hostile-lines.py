#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import os
import select
import selectors
import socket
import sys
import tempfile
import threading
import types

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD_PATH = os.path.join(HERE, "..", "..", "..", "..", "src", "services", "deskbridge", "deskd.py")
NESTED = b"[" * 200000 + b"\n"


def load_deskd(session_env):
    """return deskd loaded with a session.env path"""
    os.environ["RHIZO_DESKTOP_SESSION_ENV"] = session_env
    spec = importlib.util.spec_from_file_location("rhizo_deskd_under_test", DESKD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def bare(deskd):
    """return a bare Deskd with a selector"""
    inst = object.__new__(deskd.Deskd)
    inst.sel = selectors.DefaultSelector()
    inst.notifs = deskd.NotifTable()
    inst.notif_pkg = {}
    inst.activation_tokens = {}
    inst.relay = None
    inst.relay_pending = None
    return inst


def quiet(fn, *args):
    """return the exception fn raises"""
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            fn(*args)
        except BaseException as exc:
            return exc
    return None


def send_quietly(conn, data):
    """send data on conn, ignoring a closed peer"""
    try:
        conn.sendall(data)
    except OSError:
        pass


def send_soon(conn, data):
    """send data on conn from a thread"""
    threading.Thread(target=send_quietly, args=(conn, data), daemon=True).start()


def drain(fn, conn, attached):
    """call fn while conn is readable and attached"""
    while attached() and select.select([conn], [], [], 2)[0]:
        exc = quiet(fn)
        if exc is not None:
            return exc
    return None


def admitted_relay(deskd, inst):
    """attach a socketpair relay to inst"""
    near, far = socket.socketpair()
    relay = deskd.Relay(near)
    relay.bus = "unix:path=/nonexistent"
    near.setblocking(False)
    inst.relay = relay
    inst.sel.register(near, selectors.EVENT_READ, inst.on_relay_dispatch)
    return far


def test_nested_lines(deskd):
    """return failures for a nested line on each reader"""
    bad = []
    inst = bare(deskd)
    near, far = socket.socketpair()
    near.setblocking(False)
    inst.pending, inst.pending_reader = near, deskd.LineReader(deskd.MAX_PAYLOAD * 2)
    inst.pending_deadline, inst.pending_challenge = None, None
    inst.sel.register(near, selectors.EVENT_READ, inst.on_pending)
    send_soon(far, NESTED)
    exc = drain(lambda: inst.on_pending(None), near, lambda: inst.pending is not None)
    if exc is not None or inst.pending is not None:
        bad.append("an unauthenticated nested line escaped on_pending as %r, or the peer was kept" % (exc,))
    far.close()
    near, far = socket.socketpair()
    near.setblocking(False)
    inst.android, inst.android_reader, inst.android_ok, inst.dragout = near, deskd.LineReader(deskd.MAX_PAYLOAD * 2), True, None
    inst.sel.register(near, selectors.EVENT_READ, inst.on_android)
    send_soon(far, NESTED)
    exc = drain(lambda: inst.on_android(None), near, lambda: inst.android is not None)
    if exc is not None or inst.android is not None:
        bad.append("a nested android line escaped on_android as %r, or the android app stayed connected" % (exc,))
    far.close()
    inst = bare(deskd)
    far = admitted_relay(deskd, inst)
    send_soon(far, NESTED)
    exc = drain(inst.on_relay, inst.relay.conn, lambda: inst.relay is not None)
    if exc is not None or inst.relay is not None:
        bad.append("a nested relay line escaped on_relay as %r, or the relay stayed attached" % (exc,))
    far.close()
    return bad


def test_relay_caps(deskd):
    """return failures for oversized or misshapen relay fields"""
    bad = []
    inst = bare(deskd)
    far = admitted_relay(deskd, inst)
    send_soon(far, b'{"t":"hello","bus":"' + b"x" * (deskd.RELAY_LINE_MAX + 16))
    exc = drain(inst.on_relay, inst.relay.conn, lambda: inst.relay is not None)
    if exc is not None or inst.relay is not None:
        bad.append("a relay line past RELAY_LINE_MAX=%d raised %r or kept the relay" % (deskd.RELAY_LINE_MAX, exc))
    far.close()
    inst = bare(deskd)
    far = admitted_relay(deskd, inst)
    for token in ("abc\ndisplay kill 0", "a b", "t" * 300):
        quiet(inst.handle_relay_line, {"t": "token", "id": 7, "token": token})
        if 7 in inst.activation_tokens:
            bad.append("activation token %r was kept, outside the broker's shape" % token[:40])
            inst.activation_tokens.clear()
    quiet(inst.handle_relay_line, {"t": "token", "id": 7, "token": "kwin-1234:ab_cd"})
    if inst.activation_tokens.get(7) != "kwin-1234:ab_cd":
        bad.append("a token of the broker's shape was not kept: %r" % inst.activation_tokens)
    exc = quiet(inst.handle_relay_line, {"t": "notified", "key": "k" * (deskd.NOTIFY_KEY_MAX + 1), "id": 9})
    if inst.notifs.get_key(9) is not None or not isinstance(exc, ValueError):
        bad.append("a notified key past NOTIFY_KEY_MAX=%d was stored, or not refused by ValueError (%r)"
                   % (deskd.NOTIFY_KEY_MAX, exc))
    far.close()
    return bad


def test_notify_caps(deskd):
    """return failures for an uncapped title or body"""
    inst = bare(deskd)
    sent = []
    inst.relay = types.SimpleNamespace(bus="unix:path=/nonexistent")
    inst.to_relay = lambda obj, _what: sent.append(obj)
    quiet(inst.notify_desktop, {"key": "k1", "pkg": "com.example.flood", "title": "t" * 100000,
                                "body": "漢" * 180000})
    quiet(inst.notify_desktop, {"key": "k2", "pkg": "com.example.flood", "title": "\ud800", "body": "plain"})
    quiet(inst.notify_desktop, {"key": "k3", "pkg": "com.example.flood", "title": "t\x00", "body": "b\x00"})
    if len(sent) != 3:
        return ["notify_desktop forwarded %d of 3 notifications" % len(sent)]
    bad = []
    title, body = sent[0]["title"], sent[0]["body"]
    if len(title) > deskd.NOTIFY_TITLE_MAX or len(body) > deskd.NOTIFY_BODY_MAX or not body.endswith("…"):
        bad.append("title %d / body %d characters were forwarded, caps %d / %d with a trailing marker"
                   % (len(title), len(body), deskd.NOTIFY_TITLE_MAX, deskd.NOTIFY_BODY_MAX))
    if len(json.dumps(sent[0])) > deskd.RELAY_LINE_MAX:
        bad.append("one capped notification is %d bytes of JSON, past RELAY_LINE_MAX" % len(json.dumps(sent[0])))
    try:
        sent[1]["title"].encode("utf-8")
    except UnicodeEncodeError:
        bad.append("a lone surrogate in a title was forwarded")
    if sent[1]["body"] != "plain":
        bad.append("a short body was changed: %r" % sent[1]["body"])
    if "\x00" in sent[2]["title"] + sent[2]["body"]:
        bad.append("a NUL in a title or body was forwarded: %r" % sent[2])
    return bad


def test_bumped_relay_refused(deskd, tmp):
    """return failures for a bumped pending relay"""
    inst = bare(deskd)
    path = os.path.join(tmp, "notify.sock")
    inst.relay_listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    inst.relay_listener.bind(path)
    inst.relay_listener.listen(4)
    first, second = socket.socket(socket.AF_UNIX), socket.socket(socket.AF_UNIX)
    first.connect(path)
    quiet(inst.on_relay_accept, None)
    second.connect(path)
    quiet(inst.on_relay_accept, None)
    first.settimeout(5)
    try:
        line = first.recv(4096)
    except OSError as exc:
        line = repr(exc).encode()
    for s in (first, second, inst.relay_listener):
        s.close()
    try:
        msg = json.loads(line.decode("utf-8").splitlines()[0])
    except (ValueError, IndexError):
        msg = {}
    if msg.get("t") != "refused":
        return ["a pending relay bumped before session.env existed got %r, not a refused line" % line[:120]]
    return []


def main():
    """run the hostile-line checks"""
    with tempfile.TemporaryDirectory(prefix="rhizo-deskd-hostile-") as tmp:
        deskd = load_deskd(os.path.join(tmp, "absent-session.env"))
        bad = []
        for name in ("NOTIFY_TITLE_MAX", "NOTIFY_BODY_MAX", "NOTIFY_KEY_MAX", "RELAY_LINE_MAX"):
            if not hasattr(deskd, name):
                bad.append("rhizo-deskd defines no %s" % name)
        if not bad:
            bad = (test_nested_lines(deskd) + test_relay_caps(deskd) + test_notify_caps(deskd)
                   + test_bumped_relay_refused(deskd, tmp))
        else:
            bad += test_nested_lines(deskd) + test_bumped_relay_refused(deskd, tmp)
    for line in bad:
        print("FAIL:", line)
    print("deskd-hostile-lines:", "FAIL" if bad else "ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
