#!/usr/bin/env python3
import base64
import collections
import hashlib
import importlib.util
import os
import select
import selectors
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.normpath(os.path.join(HERE, "..", "deskd.py")))
HINT = "x-kde-passwordManagerHint"

failures = []


def check(name, ok, detail=""):
    """print and record the result of a named check"""
    print(("ok   %s" if ok else "FAIL %s") % name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def load():
    """load deskd as a module with logging silenced"""
    spec = importlib.util.spec_from_file_location("deskd_clip_order_under_test", DESKD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = lambda msg: None
    return module


class Rig:
    """simulated clipboard streams for rhizo-deskd"""

    def __init__(self, d, profile="sway", ready=True):
        """create a rhizo-deskd with simulated streams"""
        self.profile = profile
        self.gives_nothing = False
        self.stalls = False
        self.host = None
        self.mimes = None
        self.owner = None
        self.android = None
        self.handed = []
        self.composer_sets = []
        self.focused = False
        self.serial = 0
        self.sel_serial = 0
        self.input_serial = 0
        self.stdin = collections.deque()
        self.wl_out = collections.deque()
        self.control = collections.deque()
        self.seq = 0
        self.payloads = {}
        d.resolve_drop_path = lambda p: p
        d.read_raw = lambda p, _off, _n: self.payloads[p]
        deskd = d.Deskd.__new__(d.Deskd)
        rig = self

        class Bridge:
            reaped = False
            pidfd = None

            def set(self, mime, b64):
                """record a clipboard set sent to wlbridge"""
                rig.stdin.append(("set", base64.b64decode(b64)))

            def get(self, mime, tag=None):
                """record a clipboard get sent to wlbridge"""
                rig.stdin.append(("get", (mime, tag)))

        class Control:
            def new_lines(self):
                """return the next queued control line, if any"""
                if not rig.control:
                    return []
                return [rig.control.popleft()]

        deskd.wl = Bridge()
        deskd.wl.ready = ready
        deskd.control = Control()
        deskd.wl_dead = False
        deskd.session_writes = 0
        deskd.wl_session_write = 0
        deskd.wl_clipboard = profile == "sway"
        deskd.wl_write_armed = False
        deskd.android_clip_sha256 = None
        deskd.host_clip_sha256 = None
        deskd.android_clip = None
        deskd.clip_cid_seq = 0
        deskd.pending_get = None
        deskd.pending_get_deadline = None
        deskd.pending = None
        deskd.wl_host_gen = 0
        deskd.wl_get_gens = collections.deque()
        if hasattr(deskd, "init_clip_state"):
            deskd.init_clip_state()
        deskd.wl_clipboard = profile == "sway"
        deskd.to_android = self.android_gets
        deskd.to_composer = self.composer_gets
        self.deskd = deskd

    def next_serial(self):
        """return the next serial number"""
        self.serial += 1
        return self.serial

    def select(self, raw, owner, mimes=("text/plain",), serial=None):
        """set the host selection and queue events"""
        self.host, self.owner, self.mimes = raw, owner, tuple(mimes) if raw is not None else None
        self.sel_serial = self.next_serial() if serial is None else serial
        if self.profile == "sway":
            self.wl_out.append("selection none" if raw is None else "selection " + " ".join(self.mimes))
        if self.focused:
            self.composer_reports()

    def composer_reports(self):
        """queue a clip line for control.out"""
        if self.host is None or HINT in self.mimes:
            self.control.append("clip none")
            return
        self.seq += 1
        path = "/data/rhizo_control/clip-%d" % self.seq
        self.payloads[path] = self.host
        self.control.append("clip id=%d mime=text/plain path=%s sha256=%s"
                            % (self.seq, path, hashlib.sha256(self.host).hexdigest()))

    def focus_rhizo(self):
        """focus the composer and queue its report"""
        self.focused = True
        self.input_serial = self.next_serial()
        self.composer_reports()

    def composer_gets(self, command):
        """apply a clip set command to the host"""
        word, verb, _cid, mime, b64 = command.split(" ", 4)
        assert (word, verb) == ("clip", "set"), command
        raw = base64.b64decode(b64)
        self.composer_sets.append(raw)
        if self.host is not None and self.input_serial < self.sel_serial:
            return
        self.select(raw, "composer", serial=self.input_serial)

    def wlbridge_runs(self):
        """run the queued rhizo-wlbridge commands"""
        while self.stdin:
            cmd, arg = self.stdin.popleft()
            if cmd == "get":
                mime, tag = arg
                suffix = "" if tag is None else " %s" % tag
                if self.stalls:
                    self.wl_out.append("error get %s selection owner never finished sending %s within 60s"
                                       % (tag, mime) if tag is not None else
                                       "error selection owner never finished sending %s within 60s" % mime)
                elif self.host is None or mime not in self.mimes or self.gives_nothing:
                    self.wl_out.append("nodata %s%s" % (mime, suffix))
                else:
                    self.wl_out.append("data %s %s%s" % (mime, base64.b64encode(self.host).decode(), suffix))
            else:
                self.select(arg, "wlbridge")

    def reads_in_flight(self):
        """return the number of pending gets"""
        return len(getattr(self.deskd, "wl_gets", None) or getattr(self.deskd, "wl_get_gens", ()))

    def deliver_wl(self, n=None):
        """pass rhizo-wlbridge output lines to rhizo-deskd"""
        while self.wl_out and n != 0:
            self.deskd.handle_wl_line(self.wl_out.popleft())
            n = None if n is None else n - 1

    def settle_wl(self):
        """run wlbridge and deliver its output"""
        while self.stdin or self.wl_out:
            self.wlbridge_runs()
            self.deliver_wl()

    def wlbridge_exits(self):
        """end wlbridge and run deskd's on_wl"""
        if self.owner == "wlbridge":
            self.select(None, None)
            self.wl_out.clear()

        class Pipe:
            def close(self):
                """do nothing"""
                pass

        class Proc:
            stdin = stdout = Pipe()

            def poll(self):
                """return an exit status of zero"""
                return 0
        r, w = os.pipe()
        os.close(w)
        wl = self.deskd.wl
        wl.fileno = lambda: r
        wl.infileno = lambda: r
        wl.proc = Proc()
        self.deskd.sel = selectors.DefaultSelector()
        self.deskd.sel.register(r, selectors.EVENT_READ, None)
        self.deskd.on_wl(None)
        os.close(r)

    def deliver_control(self, n=None):
        """deliver queued control lines to deskd, up to a count"""
        while self.control and n != 0:
            self.deskd.on_control(None)
            n = None if n is None else n - 1

    def android_gets(self, msg):
        """record a clipboard set handed to the android app"""
        if msg.get("t") != "clip_set":
            return True
        raw = base64.b64decode(msg["b64"])
        self.handed.append(raw)
        self.android = raw
        return True

    def android_reports(self, raw):
        """report clipboard data from the android app to deskd"""
        self.deskd.clip_from_android({"mime": "text/plain", "b64": base64.b64encode(raw).decode()})

    def app_copies(self, raw):
        """send the app's copy to rhizo-deskd"""
        self.android = raw
        self.android_reports(raw)

    def legacy_echoes(self, since):
        """report the clips in self.handed[since:-1]"""
        for raw in self.handed[since:-1]:
            self.android_reports(raw)


def wake(fd, bound):
    """select on the fd with a timeout"""
    return bool(select.select([fd], [], [], bound)[0])


def check_control_watch_waits_for_line():
    """test the control.out watch wake-ups"""
    d = load()
    real_resolve, real_read = d.resolve_drop_path, d.read_raw
    tmp = tempfile.mkdtemp(prefix="test-deskd-control.")
    try:
        d.HOST_DATA = tmp + "/"
        d.CONTROL_DIR = os.path.join(tmp, "rhizo_control")
        d.CONTROL_OUT = os.path.join(d.CONTROL_DIR, "control.out")
        os.mkdir(d.CONTROL_DIR)
        open(d.CONTROL_OUT, "w").close()
        rig = Rig(d, "gnome")
        d.resolve_drop_path, d.read_raw = real_resolve, real_read
        watch = d.ControlWatch()
        rig.deskd.control = watch
        image = b"\x89PNG rhizo-host-image-gnome"
        name = "clip-104-5692012430445-7"
        with open(os.path.join(d.CONTROL_DIR, name), "wb") as f:
            f.write(image)
        woke = wake(watch.fileno(), 5)
        if woke:
            rig.deskd.on_control(None)
        with open(d.CONTROL_OUT, "a") as f:
            f.write("clip id=7 mime=image/png path=/data/rhizo_control/%s sha256=%s\n"
                    % (name, hashlib.sha256(image).hexdigest()))
        woke_for_line = wake(watch.fileno(), 5)
        if woke_for_line:
            rig.deskd.on_control(None)
        check("gnome: a composer clip line appended after its payload's creation wakes deskd and reaches Android",
              woke and woke_for_line and rig.handed == [image],
              "woke on the payload %r, woke on the line %r, handed %r" % (woke, woke_for_line, rig.handed))
        if wake(watch.fileno(), 0):
            rig.deskd.on_control(None)
        with open(d.CONTROL_OUT, "a") as f:
            f.write("power-confirm ok\n")
        idle = not wake(watch.fileno(), 0.2)
        check("gnome: once no payload's line is awaited, other appends to control.out wake nothing",
              idle, "an unrelated append woke deskd")

        text = b"rhizo-h2a-3ab3e28679d1b3f41407ee67"
        name = "clip-105-293572113643-3"
        with open(os.path.join(d.CONTROL_DIR, name), "wb") as f:
            f.write(text)
        line = ("clip id=3 mime=text/plain path=/data/rhizo_control/%s sha256=%s\n"
                % (name, hashlib.sha256(text).hexdigest()))

        class AppendsFirst:
            """test libc for inotify_add_watch"""

            def __init__(self, libc):
                """store the wrapped libc"""
                self.libc = libc

            def inotify_add_watch(self, fd, path, mask):
                """append a control line before adding the inotify watch"""
                if path == d.CONTROL_OUT.encode():
                    with open(d.CONTROL_OUT, "a") as f:
                        f.write(line)
                return self.libc.inotify_add_watch(fd, path, mask)

            def __getattr__(self, attr):
                """pass other attributes through to the wrapped libc"""
                return getattr(self.libc, attr)

        real_libc, watch.libc = watch.libc, AppendsFirst(watch.libc)
        try:
            if wake(watch.fileno(), 5):
                rig.deskd.on_control(None)
            while text not in rig.handed and wake(watch.fileno(), 0.5):
                rig.deskd.on_control(None)
        finally:
            watch.libc = real_libc
        check("gnome: a composer line appended while deskd arms its append watch reaches Android",
              rig.handed[-1:] == [text], "handed %r" % rig.handed)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    """run the clip ordering scenarios"""
    d = load()
    gone, frozen = b"rhizo-earlier-clip", b"rhizo-frozen-nonce"

    rig = Rig(d)
    rig.select(gone, "test")
    rig.settle_wl()
    rig.select(None, None)
    rig.settle_wl()
    rig.focus_rhizo()
    rig.app_copies(frozen)
    rig.settle_wl()
    rig.deliver_control(1)
    sets_before = len(rig.composer_sets)
    rig.wlbridge_exits()
    handed_over = rig.composer_sets[sets_before:]
    rig.deliver_control()
    check("sway: the app's clip is handed to the composer once the wlbridge exits, an earlier 'clip none' notwithstanding",
          handed_over == [frozen] and rig.host == frozen,
          "handed %r after the exit, host %r" % (handed_over, rig.host))

    rig = Rig(d)
    earlier, copied = b"rhizo-host-image-h2a", b"rhizo-app-image-a2h"
    rig.focused = True
    rig.select(earlier, "test")
    rig.settle_wl()
    rig.deliver_control()
    mark = len(rig.handed)
    rig.focus_rhizo()
    rig.app_copies(copied)
    rig.settle_wl()
    rig.deliver_control()
    rig.legacy_echoes(mark)
    rig.settle_wl()
    rig.deliver_control()
    check("sway: the app's copy stays on the host and in Android when the composer's focus-time report lands after it",
          rig.host == copied and rig.android == copied,
          "host %r, android %r, handed after the copy %r" % (rig.host, rig.android, rig.handed[mark:]))

    rig = Rig(d)
    hostclip, appclip = b"rhizo-host-copy", b"rhizo-app-copy-after"
    rig.select(hostclip, "test")
    rig.deliver_wl()
    mark = len(rig.handed)
    rig.app_copies(appclip)
    rig.settle_wl()
    rig.legacy_echoes(mark)
    rig.settle_wl()
    check("sway: a host read answered after deskd's own set of a newer copy is not carried over it",
          rig.host == appclip and rig.android == appclip and hostclip not in rig.handed[mark:],
          "host %r, android %r, handed %r" % (rig.host, rig.android, rig.handed[mark:]))

    rig = Rig(d)
    rig.select(b"hunter2", "test", mimes=("text/plain", HINT))
    rig.settle_wl()
    check("sway: a selection offered with %s never reaches Android on the wlbridge leg" % HINT,
          rig.handed == [], "handed %r" % rig.handed)

    rig = Rig(d, "gnome")
    rig.focused = True
    rig.select(b"rhizo-gnome-copy", "test")
    rig.deliver_control()
    check("gnome: a host copy the composer reports reaches Android",
          rig.handed == [b"rhizo-gnome-copy"], "handed %r" % rig.handed)
    rig = Rig(d)
    rig.focused = True
    rig.app_copies(b"rhizo-before-exit")
    rig.settle_wl()
    rig.deliver_control()
    rig.wlbridge_exits()
    rig.deliver_control()
    rig.select(b"rhizo-after-exit", "test")
    rig.deliver_control()
    check("sway: once the wlbridge exits, a host copy the composer reports reaches Android",
          rig.handed[-1:] == [b"rhizo-after-exit"], "handed %r" % rig.handed)

    rig = Rig(d)
    secret = b"rhizo-password"
    rig.select(b"rhizo-before-the-secret", "test")
    rig.deliver_wl()
    rig.wl_out.append("error invalid base64 for text/plain")
    rig.deliver_wl()
    rig.select(secret, "test", mimes=("text/plain", HINT))
    rig.settle_wl()
    check("sway: a hinted selection made while a read is in flight never reaches Android, an error between notwithstanding",
          secret not in rig.handed and rig.reads_in_flight() == 0,
          "handed %r, %d read(s) still in flight" % (rig.handed, rig.reads_in_flight()))

    rig = Rig(d)
    rig.select(b"rhizo-slow-source", "test")
    rig.deliver_wl()
    rig.deskd.pending_get_deadline = 0
    rig.deskd.expire_pending()
    rig.select(secret, "test", mimes=("text/plain", HINT))
    rig.settle_wl()
    check("sway: the late answer to a read deskd gave up on never reaches Android",
          secret not in rig.handed and rig.reads_in_flight() == 0,
          "handed %r, %d read(s) still in flight" % (rig.handed, rig.reads_in_flight()))

    rig = Rig(d)
    rig.gives_nothing = True
    rig.select(b"rhizo-empty-source", "test")
    rig.settle_wl()
    rig.gives_nothing = False
    rig.select(b"rhizo-after-nodata", "test")
    rig.settle_wl()
    check("sway: a copy after a read that gave nothing reaches Android, and no read is left in flight",
          rig.handed == [b"rhizo-after-nodata"] and rig.reads_in_flight() == 0,
          "handed %r, %d read(s) still in flight" % (rig.handed, rig.reads_in_flight()))

    rig = Rig(d)
    rig.stalls = True
    rig.select(b"rhizo-stalled-source", "test")
    rig.settle_wl()
    rig.stalls = False
    rig.select(b"rhizo-after-error", "test")
    rig.settle_wl()
    check("sway: a copy after a read the wlbridge failed reaches Android, and no read is left in flight",
          rig.handed == [b"rhizo-after-error"] and rig.reads_in_flight() == 0,
          "handed %r, %d read(s) still in flight" % (rig.handed, rig.reads_in_flight()))

    rig = Rig(d, ready=False)
    older, current = b"rhizo-older-selection", b"rhizo-current-selection"
    rig.focused = True
    rig.select(older, "test")
    rig.wl_out.clear()
    rig.focused = False
    rig.select(current, "test")
    rig.settle_wl()
    rig.deliver_control()
    rig.deskd.handle_wl_line("ready")
    rig.deliver_control()
    check("sway: the composer's earlier report before the wlbridge is ready is not carried over its current one",
          rig.android == current and older not in rig.handed, "android %r, handed %r" % (rig.android, rig.handed))
    rig = Rig(d, "gnome", ready=False)
    rig.deskd.wl_clipboard = True
    rig.focused = True
    rig.select(b"rhizo-gnome-early", "test")
    rig.deliver_control()
    rig.deskd.handle_wl_line("noclipboard the compositor offers no zwlr_data_control_manager_v1")
    rig.deskd.handle_wl_line("ready")
    rig.deliver_control()
    check("gnome: a composer report from before the wlbridge said noclipboard reaches Android",
          rig.handed == [b"rhizo-gnome-early"], "handed %r" % rig.handed)
    rig = Rig(d, ready=False)
    rig.focused = True
    rig.select(b"rhizo-bridge-never-ready", "test")
    rig.wl_out.clear()
    rig.deliver_control()
    rig.wlbridge_exits()
    rig.deliver_control()
    check("sway: a composer report held while the wlbridge started reaches Android once it exits unready",
          rig.handed == [b"rhizo-bridge-never-ready"], "handed %r" % rig.handed)

    check_control_watch_waits_for_line()

    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
