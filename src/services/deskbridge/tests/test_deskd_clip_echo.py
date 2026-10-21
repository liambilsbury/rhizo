#!/usr/bin/env python3
import base64
import collections
import hashlib
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.normpath(os.path.join(HERE, "..", "deskd.py")))
STEP_BOUND = 400
UNCARRIED = b"<a host selection offering no mime deskd carries>"

failures = []


def check(name, ok, detail=""):
    """print and record the result of a named check"""
    print(("ok   %s" if ok else "FAIL %s") % name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def load():
    """load deskd as a module with logging silenced"""
    spec = importlib.util.spec_from_file_location("deskd_clip_echo_under_test", DESKD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = lambda msg: None
    return module


class Desktop:
    """simulated host and Android clipboards"""

    def __init__(self, d, android="real", profile="sway"):
        """create a rhizo-deskd with fake inputs"""
        self.d = d
        self.android = android
        self.profile = profile
        self.queue = collections.deque()
        self.host = None
        self.android = None
        self.suppress = None
        self.owner = None
        self.to_android = []
        self.payloads = {}
        self.control = []
        self.seq = 0
        self.android_up = True
        d.resolve_drop_path = lambda p: p
        d.read_raw = lambda p, _off, _n: self.payloads[p]
        deskd = d.Deskd.__new__(d.Deskd)
        world = self

        class Bridge:
            ready = True

            def set(self, mime, b64):
                """select the data as the wlbridge clipboard"""
                world.select(base64.b64decode(b64), "wlbridge")

            def get(self, mime, tag):
                """queue a wl_data reply carrying the host clipboard"""
                world.queue.append(("wl_data", mime, world.host, tag))

        class Control:
            def new_lines(self):
                """return and clear the queued control lines"""
                lines, world.control[:] = list(world.control), []
                return lines

        deskd.wl = Bridge()
        deskd.control = Control()
        deskd.wl_dead = False
        deskd.session_writes = 0
        deskd.wl_session_write = 0
        deskd.wl_clipboard = profile == "sway"
        deskd.android_clip_sha256 = None
        deskd.host_clip_sha256 = None
        deskd.pushed_to_android = None
        deskd.pushed_to_host = None
        deskd.pushed_to_composer_sha256 = None
        deskd.received_from_composer_sha256 = None
        deskd.init_clip_state()
        deskd.to_android = self.android_gets
        deskd.to_composer = self.composer_gets
        self.deskd = deskd

    def select(self, raw, owner="host"):
        """set the host selection and queue events"""
        self.host = raw
        self.owner = owner
        self.queue.append(("composer_sees", raw))
        if self.profile == "sway":
            self.queue.append(("wl_sees", raw))

    def android_gets(self, msg):
        """record the clip_set payload"""
        if not self.android_up:
            return False
        if msg.get("t") != "clip_set":
            return True
        raw = base64.b64decode(msg["b64"])
        self.to_android.append(raw)
        self.android = raw
        if self.android == "echo":
            self.queue.append(("android", raw))
        else:
            self.suppress = raw
            self.queue.append(("changed",))
        return True

    def composer_gets(self, command):
        """apply a clip set command to the host"""
        word, verb, _cid, mime, b64 = command.split(" ", 4)
        assert (word, verb) == ("clip", "set"), command
        if self.profile == "sway" and self.owner == "wlbridge":
            return
        self.select(base64.b64decode(b64), "composer")

    def wlbridge_exits(self):
        """simulate rhizo-wlbridge exiting"""
        if self.owner == "wlbridge":
            self.host, self.owner = None, None
        import selectors

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
        wl.reaped, wl.pidfd = False, None
        self.deskd.sel = selectors.DefaultSelector()
        self.deskd.sel.register(r, selectors.EVENT_READ, None)
        self.deskd.wl_write_armed = False
        self.deskd.on_wl(None)
        os.close(r)

    def android_copies(self, raw):
        """copy the data in Android"""
        self.android = raw
        self.queue.append(("android", raw) if self.android == "echo" else ("changed",))

    def host_copies(self, raw):
        """copy the data on the host"""
        self.select(raw)

    def settle(self):
        """deliver queued events and return the step count"""
        steps = 0
        while self.queue:
            steps += 1
            if steps > STEP_BOUND:
                return None
            kind, *rest = self.queue.popleft()
            if kind == "changed":
                cur = self.android
                if cur == self.suppress:
                    self.suppress = None
                    continue
                kind, rest = "android", [cur]
            if kind == "android":
                self.deskd.clip_from_android({"mime": "text/plain", "b64": base64.b64encode(rest[0]).decode()})
            elif kind == "composer_sees":
                if rest[0] == UNCARRIED:
                    self.control.append("clip none")
                else:
                    self.seq += 1
                    path = "/data/rhizo_control/clip-%d" % self.seq
                    self.payloads[path] = rest[0]
                    self.control.append("clip id=%d mime=text/plain path=%s sha256=%s"
                                        % (self.seq, path, hashlib.sha256(rest[0]).hexdigest()))
                self.deskd.on_control(None)
            elif kind == "wl_sees":
                self.deskd.handle_wl_line("selection image/bmp" if rest[0] == UNCARRIED else "selection text/plain")
            elif kind == "wl_data":
                mime, raw, tag = rest
                self.deskd.handle_wl_line("data %s %s %s" % (mime, base64.b64encode(raw).decode(), tag))
        return steps


def main():
    """run the clip echo cases"""
    d = load()
    x, y = b"rhizo-android-clip-round-1", b"rhizo-android-clip-round-2"

    for android in ("echo", "real"):
        desk = Desktop(d, android)
        desk.android_copies(x)
        steps = desk.settle()
        check("%s android: one Android copy crosses to the host and settles, nothing coming back" % android,
              steps is not None and desk.to_android == [] and desk.host == x,
              "steps %r, the android app was handed %d clip(s) back: %r" % (steps, len(desk.to_android), desk.to_android[:3]))
        desk.to_android.clear()
        desk.android_copies(y)
        steps = desk.settle()
        check("%s android: a second Android copy settles and both sides hold it, not the first" % android,
              steps is not None and desk.host == y and desk.android == y and x not in desk.to_android,
              "steps %r, host %r, android %r, handed %r" % (steps, desk.host, desk.android, desk.to_android[:4]))
        z = b"rhizo-host-clip"
        desk.host_copies(z)
        steps = desk.settle()
        check("%s android: a genuine host copy reaches Android and settles" % android,
              steps is not None and desk.android == z and desk.host == z,
              "steps %r, host %r, android %r" % (steps, desk.host, desk.android))
        desk.android_copies(y)
        steps = desk.settle()
        check("%s android: a later Android copy of earlier bytes reaches the host" % android,
              steps is not None and desk.host == y, "steps %r, host %r" % (steps, desk.host))

    for profile in ("sway", "gnome"):
        for name, first, second in (("Android then Android", "a", "a"), ("host then Android", "h", "a"),
                                    ("Android then host", "a", "h"), ("host then host", "h", "h")):
            desk = Desktop(d, "real", profile)
            one, two = b"rhizo-first-" + first.encode(), b"rhizo-second-" + second.encode()
            (desk.host_copies if first == "h" else desk.android_copies)(one)
            (desk.host_copies if second == "h" else desk.android_copies)(two)
            steps = desk.settle()
            want = {two} if first == second else {one, two}
            check("%s, %s in flight together: settles with both sides on %s" % (profile, name,
                                                                                 "the newer" if first == second else "one clip"),
                  steps is not None and desk.host == desk.android and desk.host in want,
                  "steps %r, host %r, android %r" % (steps, desk.host, desk.android))

    for profile in ("sway", "gnome"):
        desk = Desktop(d, "real", profile)
        h = b"rhizo-host-clip-android-gone"
        desk.android_up = False
        desk.host_copies(h)
        desk.settle()
        desk.android_up = True
        desk.host_copies(h)
        steps = desk.settle()
        check("%s: a host copy repeated after the android app was gone for the first reaches Android" % profile,
              steps is not None and desk.android == h, "steps %r, android %r" % (steps, desk.android))

    for profile in ("sway", "gnome"):
        desk = Desktop(d, "real", profile)
        desk.android_copies(y)
        desk.settle()
        desk.select(UNCARRIED)
        desk.settle()
        desk.android_copies(b"rhizo-other")
        desk.settle()
        desk.android_copies(y)
        steps = desk.settle()
        check("%s: an Android copy repeated after the host moved to an uncarried selection reaches the host" % profile,
              steps is not None and desk.host == y, "steps %r, host %r" % (steps, desk.host))
        desk = Desktop(d, "echo", profile)
        desk.android_copies(y)
        desk.settle()
        desk.select(UNCARRIED)
        desk.settle()
        desk.android_copies(y)
        steps = desk.settle()
        check("%s: the same Android copy made again right after the host went uncarried reaches the host" % profile,
              steps is not None and desk.host == y, "steps %r, host %r" % (steps, desk.host))

    desk = Desktop(d, "real", "sway")
    desk.android_copies(x)
    desk.settle()
    check("sway: the wlbridge's set holds the host selection over the composer's",
          desk.host == x and desk.owner == "wlbridge", "host %r owned by %r" % (desk.host, desk.owner))
    desk.wlbridge_exits()
    desk.settle()
    check("sway: once the wlbridge exits, Android's clip is back on the host through the composer",
          desk.host == x and desk.owner == "composer", "host %r owned by %r" % (desk.host, desk.owner))
    desk = Desktop(d, "real", "sway")
    desk.android_copies(x)
    desk.settle()
    desk.android_up = False
    desk.host_copies(y)
    desk.settle()
    desk.android_up = True
    desk.wlbridge_exits()
    desk.settle()
    check("sway: a host copy of its own is not overwritten when the wlbridge exits",
          desk.host == y and desk.owner == "host", "host %r owned by %r" % (desk.host, desk.owner))

    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
