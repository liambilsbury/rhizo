#!/usr/bin/env python3
import base64
import builtins
import contextlib
import hashlib
import importlib.util
import io
import os
import pathlib
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DISPLAYD = os.path.normpath(os.path.join(HERE, "..", "displayd", "displayd.py"))
KEYMAPD = os.path.normpath(os.path.join(HERE, "..", "keymapd", "keymapd.py"))
DESKD = os.path.normpath(os.path.join(HERE, "..", "deskbridge", "deskd.py"))
REAL_OPEN = io.open

failures = []


def check(name, ok, detail=""):
    """print and record the result of a named check"""
    print(("ok   %s" if ok else "FAIL %s") % name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def load(path, name):
    """load a module from a file path under a name"""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def append(path, data):
    """append bytes to a file using the real open"""
    with REAL_OPEN(path, "ab") as f:
        f.write(data)


@contextlib.contextmanager
def io_stack_blocked():
    """raise on calls to builtins.open and io.open"""
    calls = []

    def boom(*a, **k):
        """fail when anything opens a file through the io stack"""
        calls.append((a, k))
        raise AssertionError("opened through the io stack: %r %r" % (a, k))

    saved = builtins.open, io.open
    builtins.open = io.open = boom
    try:
        yield calls
    finally:
        builtins.open, io.open = saved


class Stop(Exception):
    pass


def test_displayd(tmp):
    """test rhizo-displayd reads of control.out"""
    d = load(DISPLAYD, "displayd_under_test")
    ctl = os.path.join(tmp, "displayd-control.out")
    append(ctl, b"display added id=1 port=0 960x1080\n")
    d.CONTROL_OUT = ctl
    d.wait_for_init = lambda *a, **k: "4242"
    d.process_started_at = lambda pid: os.stat(ctl).st_mtime + 3600
    d.log = lambda msg: None
    applied, born = [], []
    d.apply = lambda *a: applied.append(a) or True
    d.announce_born = lambda *a: born.append(a)
    ticks = [0]

    def sleep(_s):
        """append display lines on the first call and stop on the second"""
        ticks[0] += 1
        if ticks[0] == 1:
            append(ctl, b"display scaled id=3 port=2 scale=2 dpi=320\ndisplay powered id=4 port=5\n")
        else:
            raise Stop()

    real_sleep = d.time.sleep
    d.time.sleep = sleep
    try:
        with io_stack_blocked() as calls:
            try:
                d.main()
            except Stop:
                pass
    finally:
        d.time.sleep = real_sleep
    check("displayd: never opens control.out through the io stack", not calls,
          "opened: %r" % (calls[:1],))
    check("displayd: applies the scale line appended after it started", applied == [(3, 2, 2, 320)],
          "applied %r" % (applied,))
    check("displayd: announces the display born after it started, and none from before",
          born == [(4, 5)], "born %r" % (born,))


def test_keymapd(tmp):
    """check that keymapd reads its control output without the io stack"""
    k = load(KEYMAPD, "keymapd_under_test")
    ctl = os.path.join(tmp, "keymapd-control.out")
    append(ctl, b"display added id=1 port=0 960x1080\nkeymap ready digest=7 path=/data/x\n")
    k.CONTROL_OUT = ctl
    watch = k.KeymapWatch.__new__(k.KeymapWatch)
    watch.offset = 0
    with io_stack_blocked() as calls:
        try:
            first = watch.new_lines()
        except AssertionError as e:
            first = ["<raised: %s>" % e]
        append(ctl, b"keymap ready digest=9 path=/data/y\n")
        try:
            second = watch.new_lines()
        except AssertionError as e:
            second = ["<raised: %s>" % e]
    check("keymapd: new_lines never opens control.out through the io stack", not calls,
          "opened: %r" % (calls[:1],))
    check("keymapd: the first read returns every line from offset 0",
          first == ["display added id=1 port=0 960x1080", "keymap ready digest=7 path=/data/x"], "got %r" % (first,))
    check("keymapd: the next read returns only the appended line",
          second == ["keymap ready digest=9 path=/data/y"], "got %r" % (second,))

    keymap = os.path.join(tmp, "keymap.xkb")
    raw = b"xkb_keymap { };\n"
    append(keymap, raw)
    k.sandbox_to_host = lambda p: keymap
    k.log = lambda msg: None
    sent = []
    k.send_table = lambda digest, table: sent.append(digest)
    k.encode_table = lambda entries: b""

    class Xkb:
        def resolve(self, text):
            """return the text as a one-item list"""
            return [text]

    with io_stack_blocked() as calls:
        try:
            k.resolve_and_send(Xkb(), k.fnv1a32(raw), "/data/keymap.xkb")
        except AssertionError:
            pass
    check("keymapd: resolve_and_send never opens the keymap through the io stack", not calls,
          "opened: %r" % (calls[:1],))
    check("keymapd: resolve_and_send reads the keymap and sends its table", sent == [k.fnv1a32(raw)],
          "sent %r" % (sent,))


def test_deskd(tmp):
    """test rhizo-deskd reads of its input files"""
    d = load(DESKD, "deskd_under_test")
    ctl = os.path.join(tmp, "deskd-control.out")
    append(ctl, b"display added id=1 port=0 960x1080\n")
    d.CONTROL_OUT = ctl
    watch = d.ControlWatch.__new__(d.ControlWatch)
    rfd, wfd = os.pipe()
    os.set_blocking(rfd, False)
    watch.fd, watch.offset, watch.wd = rfd, 0, -1
    watch.reset_awaited()
    with io_stack_blocked() as calls:
        try:
            first = watch.new_lines()
            append(ctl, b"clip id=1 mime=text/plain sha256=x path=/data/y\n")
            second = watch.new_lines()
        except AssertionError as e:
            first = second = ["<raised: %s>" % e]
    os.close(rfd)
    os.close(wfd)
    check("deskd: ControlWatch.new_lines never opens control.out through the io stack", not calls,
          "opened: %r" % (calls[:1],))
    check("deskd: the first read returns every line from offset 0",
          first == ["display added id=1 port=0 960x1080"], "got %r" % (first,))
    check("deskd: the next read returns only the appended line",
          second == ["clip id=1 mime=text/plain sha256=x path=/data/y"], "got %r" % (second,))

    launch = os.path.join(tmp, "rhizo-launch.log")
    append(launch, b"1 event=am_start_return pid=9 pkg=com.x display=5 cdisplay=3 bus=bus0\n")
    d.LAUNCH_LOG = launch
    payload = os.path.join(tmp, "clip-1")
    raw = b"rhizo-clip-payload"
    append(payload, raw)
    d.resolve_drop_path = lambda p: payload
    token = os.path.join(tmp, "token")
    append(token, b"tok123\n")
    deskd = d.Deskd.__new__(d.Deskd)
    deskd.args = type("Args", (), {"token": None, "token_file": token})()
    deskd.android_clip_sha256 = None
    deskd.host_clip_sha256 = None
    sent = []
    deskd.to_android = sent.append
    d.log = lambda msg: None
    line = "clip id=1 mime=text/plain sha256=%s path=/data/rhizo_control/clip-1" % hashlib.sha256(raw).hexdigest()
    with io_stack_blocked() as calls:
        try:
            logical = deskd.logical_display_for("3")
            tok = deskd.current_token()
            deskd.on_composer_clip(line)
        except AssertionError as e:
            logical = tok = "<raised: %s>" % e
    check("deskd: the launch log, the token and a clip payload are never read through the io stack",
          not calls, "opened: %r" % (calls[:1],))
    check("deskd: the launch log maps composer display 3 to Android display 5", logical == "5",
          "got %r" % (logical,))
    check("deskd: the token file reads back", tok == "tok123", "got %r" % (tok,))
    check("deskd: the clip payload reaches the android app whole",
          [m.get("b64") for m in sent] == [base64.b64encode(raw).decode("ascii")], "sent %r" % (sent,))


def test_detects_io_stack(tmp):
    """test detection of io stack opens"""
    path = os.path.join(tmp, "probe")
    append(path, b"x")
    roads = {
        "open()": lambda: open(path, "rb"),
        "io.open()": lambda: io.open(path, "rb"),
        "os.fdopen()": lambda: os.fdopen(os.open(path, os.O_RDONLY), "rb"),
        "pathlib read_bytes()": lambda: pathlib.Path(path).read_bytes(),
    }
    for name, road in roads.items():
        with io_stack_blocked() as calls:
            try:
                road()
            except AssertionError:
                pass
        check("harness: a read through %s is caught" % name, len(calls) == 1, "recorded %r" % (calls,))
    with io_stack_blocked() as calls:
        fd = os.open(path, os.O_RDONLY)
        got = os.pread(fd, 1, 0)
        os.close(fd)
    check("harness: a descriptor read is not caught and reads the file", not calls and got == b"x",
          "recorded %r, read %r" % (calls, got))


def main():
    """run every check in a temporary directory"""
    with tempfile.TemporaryDirectory() as tmp:
        test_detects_io_stack(tmp)
        test_displayd(tmp)
        test_keymapd(tmp)
        test_deskd(tmp)
    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("all ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
