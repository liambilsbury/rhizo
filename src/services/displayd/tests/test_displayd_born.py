#!/usr/bin/env python3
import importlib.util
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DISPLAYD = os.path.normpath(os.path.join(HERE, "..", "displayd.py"))

failures = []


def check(name, ok, detail=""):
    """print and record the result of a named check"""
    print(("ok   %s" if ok else "FAIL %s") % name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def load():
    """load displayd as a module with logging silenced"""
    spec = importlib.util.spec_from_file_location("displayd_under_test", DISPLAYD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = lambda msg: None
    module.seat_locked = lambda: None
    return module


class Stop(Exception):
    pass


def write(path, data, mode="ab"):
    """write bytes to a file, appending by default"""
    with open(path, mode) as f:
        f.write(data)


def test_process_started_at(base):
    """test process_started_at against fake proc files"""
    d = load()
    if not hasattr(d, "process_started_at"):
        check("process_started_at exists", False, "displayd.py has none")
        return
    proc = os.path.join(base, "proc")
    os.makedirs(os.path.join(proc, "4242"))
    write(os.path.join(proc, "stat"), b"cpu  1 2 3\nbtime 1000000\nprocesses 9\n", "wb")
    fields = ["S"] + ["0"] * 18 + [str(500 * os.sysconf("SC_CLK_TCK"))] + ["0"] * 10
    write(os.path.join(proc, "4242", "stat"), ("4242 (init second) " + " ".join(fields)).encode(), "wb")
    d.PROC_ROOT = proc
    got = d.process_started_at("4242")
    check("an init's start is btime plus its starttime", got == 1000500.0, "got %r" % (got,))
    check("an unreadable pid has no start", d.process_started_at("99") is None)


def test_start_offset(base):
    """check the offset where displayd starts reading the control output"""
    d = load()
    if not hasattr(d, "start_offset"):
        check("start_offset exists", False, "displayd.py has none")
        return
    ctl = os.path.join(base, "offset-control.out")
    write(ctl, b"display pooled id=2 port=1 960x1080\n", "wb")
    mtime = os.stat(ctl).st_mtime
    d.process_started_at = lambda pid: mtime - 5
    got = d.start_offset(ctl, "1")
    check("a file written since this init started is read from its start", got == 0, "got %r" % (got,))
    d.process_started_at = lambda pid: mtime + 5
    got = d.start_offset(ctl, "1")
    check("a file older than this init is skipped to its end", got == os.path.getsize(ctl), "got %r" % (got,))
    d.process_started_at = lambda pid: None
    got = d.start_offset(ctl, "1")
    check("an init whose start cannot be read skips the file", got == os.path.getsize(ctl), "got %r" % (got,))
    got = d.start_offset(os.path.join(base, "absent"), "1")
    check("no file yet reads the one that comes from its start", got == 0, "got %r" % (got,))


def test_plan():
    """check the plan displayd makes from control output lines"""
    d = load()
    if not hasattr(d, "plan"):
        check("plan exists", False, "displayd.py has none")
        return
    got = d.plan(["display pooled id=2 port=1 960x1080", "display claimed id=2",
                  "display added id=5 port=4 960x1080", "display powered id=3 port=2",
                  "display scaled id=2 port=1 scale=2 dpi=800",
                  "display pooled id=6 port=5 960x1080", "display spare-released id=6",
                  "display powered id=7 port=6", "display remove id=7 ok",
                  "display remove id=3 no-such-display"])
    want = [("born", (2, 1)), ("born", (5, 4)), ("born", (3, 2)), ("scaled", (2, 1, 2, 800)),
            ("gone", (6,)), ("gone", (7,))]
    check("born lines in order, added included, removed displays dropped and reported gone, "
          "a failed remove ignored",
          got == want, "got %r" % (got,))
    got = d.plan(["display remove id=2 ok", "display pooled id=2 port=1 960x1080"])
    check("a display id reborn after its removal is announced",
          got == [("gone", (2,)), ("born", (2, 1))], "got %r" % (got,))


def run_main(d, ctl, on_tick):
    """run displayd's main loop with stubbed helpers"""
    announced, applied = [], []
    d.CONTROL_OUT = ctl
    d.wait_for_init = lambda *a, **k: "4242"
    d.announce_born = lambda *a: announced.append(a)
    d.apply = lambda *a: applied.append(a) or True
    ticks = [0]

    def sleep(_s):
        """count ticks and stop the loop"""
        ticks[0] += 1
        if not on_tick(ticks[0]):
            raise Stop()

    real = d.time.sleep
    d.time.sleep = sleep
    try:
        d.main()
    except Stop:
        pass
    finally:
        d.time.sleep = real
    return announced, applied


def test_main_replays_this_boot(base):
    """check that displays from this boot are announced again"""
    d = load()
    ctl = os.path.join(base, "main-control.out")
    write(ctl, b"display pooled id=2 port=1 960x1080\ndisplay claimed id=2\n", "wb")
    d.process_started_at = lambda pid: os.stat(ctl).st_mtime - 5
    announced, _ = run_main(d, ctl, lambda t: t < 2)
    check("a display this boot announced before the daemon started is announced",
          announced == [(2, 1)], "announced %r" % (announced,))


def test_main_recreated_file(base):
    """test reading a recreated control.out"""
    d = load()
    ctl = os.path.join(base, "recreate-control.out")
    write(ctl, b"display pooled id=9 port=8 960x1080\n" * 40, "wb")
    d.process_started_at = lambda pid: os.stat(ctl).st_mtime + 5

    def tick(t):
        """replace the control file with new display lines on the first tick"""
        if t == 1:
            os.unlink(ctl)
            write(ctl, b"".join(b"display pooled id=%d port=%d 960x1080\n" % (i, i)
                                for i in range(10, 70)), "wb")
            return True
        return t < 3

    announced, _ = run_main(d, ctl, tick)
    check("the last boot's file is not announced, and its recreation is read from its start",
          sorted(announced) == [(i, i) for i in range(10, 70)],
          "announced %d, first %r" % (len(announced), sorted(announced)[:2]))


def test_main_retries_pending(base):
    """check that a display whose announce is unbound is retried"""
    d = load()
    ctl = os.path.join(base, "pending-control.out")
    write(ctl, b"display pooled id=2 port=1 960x1080\ndisplay pooled id=3 port=2 960x1080\n"
               b"display spare-released id=3\n", "wb")
    d.process_started_at = lambda pid: os.stat(ctl).st_mtime - 5
    answers = {2: [d.UNBOUND, d.UNBOUND, "told"]}
    calls = []

    def born(cid, port):
        """return the next answer for a display, or told"""
        calls.append(cid)
        return answers[cid].pop(0) if answers.get(cid) else "told"

    d.CONTROL_OUT = ctl
    d.wait_for_init = lambda *a, **k: "4242"
    d.announce_born = born
    d.apply = lambda *a: True
    ticks = [0]

    def sleep(_s):
        """count ticks and stop after the fifth"""
        ticks[0] += 1
        if ticks[0] > 5:
            raise Stop()

    real = d.time.sleep
    d.time.sleep = sleep
    try:
        d.main()
    except Stop:
        pass
    finally:
        d.time.sleep = real
    check("an unbound display is asked again each pass until told, then never again; a released one never",
          calls == [2, 2, 2], "calls %r" % (calls,))


class FakeSandbox:
    """fake Android shell for a display"""

    def __init__(self, override=None, registered=True):
        """store the density override and registration state"""
        self.override = override
        self.registered = registered
        self.sent = []

    def android(self, cmd):
        """record the command and return fake output"""
        self.sent.append(cmd)
        if "DisplayDeviceInfo" in cmd:
            return "" if not self.registered else "DisplayDeviceInfo{\"Rhizo display 2\": 960 x 1080, modeId 11, density 0, 400.0 x 400.0 dpi, address {port=1}}"
        if cmd.startswith("dumpsys display"):
            if not self.registered:
                return "mViewports=[DisplayViewport{type=INTERNAL, displayId=0, physicalPort=0}]"
            return "mViewports=[DisplayViewport{type=EXTERNAL, displayId=2, physicalPort=1}]"
        if cmd == "wm density -d 2":
            return "Physical density: 546\n" + (
                "Override density: %d\n" % self.override if self.override else "")
        if cmd == "wm density reset -d 2":
            self.override = None
            return ""
        if cmd.startswith("wm density ") and cmd.endswith(" -d 2"):
            self.override = int(cmd.split()[2])
            return ""
        if cmd == "settings get system mouse_pointer_acceleration_enabled":
            return "0\n"
        if cmd == "dumpsys input":
            return ("Input Manager State:\n  Pointer Speed: 0\n"
                    "  Display with Mouse Scaling Disabled: {}\n\nInput Reader State:\n"
                    "  Device 21: rhizo-mouse-1\n    AssociatedDisplayPort: 1\n"
                    "    Cursor Input Mapper:\n      XScale: 1.000\n      YScale: 1.000\n"
                    + ("      DisplayId: 2\n" if self.registered else ""))
        return ""


def run_real(d, ctl, ticks_wanted, on_tick=None):
    """run rhizo-displayd main for ticks_wanted passes"""
    d.CONTROL_OUT = ctl
    d.wait_for_init = lambda *a, **k: "4242"
    d.process_started_at = lambda pid: os.stat(ctl).st_mtime - 5
    ticks = [0]

    def sleep(_s):
        """count ticks and call the callback"""
        ticks[0] += 1
        if on_tick:
            on_tick(ticks[0])
        if ticks[0] >= ticks_wanted:
            raise Stop()

    real = d.time.sleep
    d.time.sleep = sleep
    try:
        d.main()
    except Stop:
        pass
    finally:
        d.time.sleep = real


def test_scale_before_registration(base):
    """check a scale seen before registration"""
    cases = [
        ("a scale that arrives before the framework registers the display is applied once it does, "
         "and a born line beside it does not reset it",
         b"display pooled id=2 port=1 960x1080\ndisplay scaled id=2 port=1 scale=2 dpi=800\n",
         ["wm density 1092 -d 2"], 1092),
        ("of two scales before registration, only the latest is applied",
         b"display scaled id=2 port=1 scale=2 dpi=800\ndisplay scaled id=2 port=1 scale=3 dpi=1200\n",
         ["wm density 1638 -d 2"], 1638),
        ("a pending scale is dropped when its display goes",
         b"display scaled id=2 port=1 scale=2 dpi=800\ndisplay remove id=2 ok\n", [], None),
    ]
    for name, text, want_sets, want_override in cases:
        d = load()
        box = FakeSandbox(registered=False)
        d.android = box.android
        ctl = os.path.join(base, "unregistered-control.out")
        write(ctl, text, "wb")

        def register(tick, box=box):
            """register the display on the third tick"""
            if tick == 3:
                box.registered = True

        run_real(d, ctl, 8, register)
        sets = [c for c in box.sent if c.startswith("wm density ") and c.split()[2].isdigit()]
        resets = [c for c in box.sent if c.startswith("wm density reset")]
        check(name, sets == want_sets and not resets and box.override == want_override,
              "sets=%r resets=%r override=%r" % (sets, resets, box.override))


def test_scale_in_same_batch_survives(base):
    """check that a scale in the same batch as the display survives"""
    d = load()
    box = FakeSandbox()
    d.android = box.android
    ctl = os.path.join(base, "samebatch-control.out")
    write(ctl, b"display pooled id=2 port=1 960x1080\n"
               b"display scaled id=2 port=1 scale=2 dpi=800\n", "wb")
    run_real(d, ctl, 2)
    resets = [c for c in box.sent if c.startswith("wm density reset")]
    check("a born display scaled in the same batch keeps its scale: no reset after the scale-up",
          box.override == 1092 and not resets,
          "override=%r resets=%r" % (box.override, resets))

    d = load()
    box = FakeSandbox(override=1092)
    d.android = box.android
    ctl = os.path.join(base, "reused-control.out")
    write(ctl, b"display scaled id=2 port=1 scale=2 dpi=800\ndisplay remove id=2 ok\n"
               b"display pooled id=2 port=1 960x1080\n", "wb")
    run_real(d, ctl, 2)
    check("a composer id removed and reborn has its leftover override cleared",
          box.override is None and "wm density reset -d 2" in box.sent,
          "override=%r sent=%r" % (box.override, box.sent))


def test_pending_is_bounded(base):
    """check that the pending displays stay bounded"""
    d = load()
    ctl = os.path.join(base, "bound-control.out")
    write(ctl, b"display pooled id=2 port=1 960x1080\n", "wb")
    d.CONTROL_OUT = ctl
    d.wait_for_init = lambda *a, **k: "4242"
    d.process_started_at = lambda pid: os.stat(ctl).st_mtime - 5
    d.apply = lambda *a: True
    d.PENDING_LOG_S = 3
    clock = [0.0]
    d._now = lambda: clock[0]
    calls = []
    d.announce_born = lambda cid, port: (calls.append(clock[0]) if cid == 2 else None) or d.UNBOUND
    logs = []
    d.log = logs.append

    def sleep(_s):
        """advance a fake clock and add a display"""
        clock[0] += 1.0
        if clock[0] == 12.0:
            write(ctl, b"display pooled id=5 port=4 960x1080\n")
        if clock[0] >= 18.0:
            raise Stop()

    real = d.time.sleep
    d.time.sleep = sleep
    try:
        d.main()
    except Stop:
        pass
    finally:
        d.time.sleep = real
    parked = [t for t in calls if 4.0 < t < 12.0]
    parks = [m for m in logs if "stopped asking" in m]
    check("an unbound display is asked for PENDING_LOG_S, then not at all",
          calls[:4] == [0.0, 1.0, 2.0, 3.0] and not parked, "calls %r" % (calls,))
    check("a new display line asks again", any(t >= 12.0 for t in calls), "calls %r" % (calls,))
    check("each park is logged once", len([m for m in parks if "display 2 " in m]) == 2,
          "logs %r" % (parks,))


def test_reply_does_not_wake(base):
    """check that a reply line does not wake the loop"""
    d = load()
    ctl = os.path.join(base, "reply-control.out")
    write(ctl, b"display pooled id=2 port=1 960x1080\n", "wb")
    d.CONTROL_OUT = ctl
    d.wait_for_init = lambda *a, **k: "4242"
    d.process_started_at = lambda pid: os.stat(ctl).st_mtime - 5
    d.apply = lambda *a: True
    d.PENDING_LOG_S = 3
    clock = [0.0]
    d._now = lambda: clock[0]
    calls = []
    d.announce_born = lambda cid, port: calls.append(clock[0]) or d.UNBOUND
    d.log = lambda msg: None

    def sleep(_s):
        """advance a fake clock and write reply lines"""
        clock[0] += 1.0
        if clock[0] == 8.0:
            write(ctl, b"display cursor-scale id=3 milli=2250\ndisplay claimed id=3\n"
                       b"display toplevel id=3 app_id=x title=y\n")
        if clock[0] >= 12.0:
            raise Stop()

    real = d.time.sleep
    d.time.sleep = sleep
    try:
        d.main()
    except Stop:
        pass
    finally:
        d.time.sleep = real
    check("a parked display is not woken by the composer's other replies (its own cursor-scale among them)",
          calls and max(calls) <= 5.0, "calls %r" % (calls,))


def test_born_retires_same_port(base):
    """test born lines retiring same-port state"""
    d = load()
    box = FakeSandbox(registered=False)
    d.android = box.android
    ctl = os.path.join(base, "sameport-control.out")
    write(ctl, b"display pooled id=2 port=1 960x1080\n"
               b"display scaled id=2 port=1 scale=2 dpi=800\n", "wb")

    def tick(t, box=box):
        """add a display and register it"""
        if t == 2:
            write(ctl, b"display pooled id=7 port=1 960x1080\n")
        if t == 4:
            box.registered = True

    run_real(d, ctl, 8, tick)
    sets = [c for c in box.sent if c.startswith("wm density ") and c.split()[2].isdigit()]
    told = [c for c in box.sent if "cursor-scale" in c]
    check("a born line on a port drops the earlier pending scale and announcement of another id there",
          not sets and box.override is None
          and not any("cursor-scale 2 " in c for c in told)
          and any("cursor-scale 7 " in c for c in told),
          "sets=%r told=%r override=%r" % (sets, told, box.override))


def test_pending_scale_is_bounded(base):
    """check that the pending scales stay bounded"""
    d = load()
    ctl = os.path.join(base, "scalebound-control.out")
    write(ctl, b"display scaled id=2 port=1 scale=2 dpi=800\n", "wb")
    d.CONTROL_OUT = ctl
    d.wait_for_init = lambda *a, **k: "4242"
    d.process_started_at = lambda pid: os.stat(ctl).st_mtime - 5
    d.PENDING_LOG_S = 3
    clock = [0.0]
    d._now = lambda: clock[0]
    calls = []
    d.apply = lambda *a: calls.append(clock[0]) and False
    d.log = lambda msg: None

    def sleep(_s):
        """advance a fake clock and add a display"""
        clock[0] += 1.0
        if clock[0] == 12.0:
            write(ctl, b"display pooled id=5 port=4 960x1080\n")
        if clock[0] >= 14.0:
            raise Stop()

    real = d.time.sleep
    d.time.sleep = sleep
    try:
        d.main()
    except Stop:
        pass
    finally:
        d.time.sleep = real
    check("an unresolvable scale is retried for PENDING_LOG_S, parked, and asked again on a display line",
          calls[:4] == [0.0, 0.0, 1.0, 2.0] and not [t for t in calls if 5.0 < t < 12.0]
          and any(t >= 12.0 for t in calls), "calls %r" % (calls,))


def test_born_resets_override():
    """check that a born display resets its density override"""
    d = load()
    if not hasattr(d, "reset_density_override"):
        check("reset_density_override exists", False, "displayd.py has none")
        return
    for override, want_reset in ((True, True), (False, False)):
        sent = []

        def android(cmd, override=override):
            """answer Android commands"""
            sent.append(cmd)
            if cmd.startswith("dumpsys display"):
                return "mViewports=[DisplayViewport{type=EXTERNAL, displayId=2, physicalPort=1}]"
            if cmd == "wm density -d 2":
                return "Physical density: 546\n" + ("Override density: 1092\n" if override else "")
            if cmd == "settings get system mouse_pointer_acceleration_enabled":
                return "0\n"
            if cmd == "dumpsys input":
                return ("Input Manager State:\n  Pointer Speed: 0\n"
                        "  Display with Mouse Scaling Disabled: {}\n\nInput Reader State:\n"
                        "  Device 21: rhizo-mouse-1\n    AssociatedDisplayPort: 1\n"
                        "    Cursor Input Mapper:\n      XScale: 1.000\n      YScale: 1.000\n"
                        "      DisplayId: 2\n")
            return ""
        d.android = android
        d.time.sleep = lambda s: None
        d.announce_born(2, 1)
        reset = "wm density reset -d 2" in sent
        told = any("cursor-scale 2 2250" in c for c in sent)
        what = "with" if override else "without"
        check("a display born %s an override %s, and is told its cursor scale"
              % (what, "has it reset" if want_reset else "is left alone"),
              reset == want_reset and told, "sent %r" % (sent,))


def main():
    """run every check in a temporary directory"""
    base = tempfile.mkdtemp(prefix="displayd-born-")
    try:
        test_process_started_at(base)
        test_start_offset(base)
        test_plan()
        test_main_replays_this_boot(base)
        test_main_recreated_file(base)
        test_main_retries_pending(base)
        test_scale_in_same_batch_survives(base)
        test_scale_before_registration(base)
        test_pending_scale_is_bounded(base)
        test_reply_does_not_wake(base)
        test_born_retires_same_port(base)
        test_pending_is_bounded(base)
        test_born_resets_override()
    finally:
        shutil.rmtree(base)
    if failures:
        print("FAILED: %s" % ", ".join(failures))
        return 1
    print("rhizo-displayd announces every display this boot has, and clears a born display's leftover density")
    return 0


if __name__ == "__main__":
    sys.exit(main())
