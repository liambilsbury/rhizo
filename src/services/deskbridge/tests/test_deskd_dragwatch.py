#!/usr/bin/env python3
import importlib.util
import json
import os
import selectors
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.normpath(os.path.join(HERE, "..", "deskd.py")))

failures = []


def check(name, ok, detail=""):
    """print and record the result of a named check"""
    print(("ok   %s" if ok else "FAIL %s") % name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


def load():
    """load the rhizo-deskd module for testing"""
    spec = importlib.util.spec_from_file_location("deskd_dragwatch_under_test", DESKD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = lambda msg: None
    module.init_running = lambda pid: pid == "100"
    return module


def append(path, text):
    """append text to a file"""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)


def record(display, cdisplay, pkg="com.rhizo.deskapp", init=100):
    """return a launch log record for a display"""
    return ("1790409551.1 event=am_start_return pid=77 pkg=%s activity=.Main display=%d "
            "cdisplay=%d bus=none init=%d\n" % (pkg, display, cdisplay, init))


def bridge(d, tmp, drag=True):
    """create a Deskd with recorded messages"""
    d.LAUNCH_LOG = os.path.join(tmp, "launch", "rhizo-launch.log")
    d.CONTROL_OUT = os.path.join(tmp, "control.out")
    deskd = d.Deskd.__new__(d.Deskd)
    deskd.sel = selectors.DefaultSelector()
    deskd.drag_enabled = drag
    deskd.android = object()
    deskd.android_ok = True
    deskd.dragout = None
    deskd.cid_by_display = {}
    deskd.pads = {}
    deskd.pending_up = None
    sent = []
    deskd.to_android = sent.append
    deskd.composer = []
    deskd.to_composer = deskd.composer.append
    return deskd, sent


def say(deskd, msg):
    """pass a JSON message line to Deskd"""
    deskd.handle_android_line(json.dumps(msg).encode("utf-8"))


def dragwatches(sent):
    """return the displays of the dragwatch messages sent"""
    return [m.get("display") for m in sent if m.get("t") == "dragwatch"]


def deliver(deskd):
    """run the ready selector callbacks"""
    for key, mask in deskd.sel.select(0.5):
        key.data(key, mask)


def control_watch(d, deskd):
    """attach a ControlWatch and return a close function"""
    watch = d.ControlWatch.__new__(d.ControlWatch)
    rfd, wfd = os.pipe()
    os.set_blocking(rfd, False)
    watch.fd, watch.offset, watch.wd = rfd, 0, -1
    watch.reset_awaited()
    deskd.control = watch
    return lambda: (os.close(rfd), os.close(wfd))


def test_launch_after_power(d, tmp):
    """test arming from a later launch record"""
    deskd, sent = bridge(d, tmp)
    os.makedirs(os.path.dirname(d.LAUNCH_LOG))
    append(d.LAUNCH_LOG, "1790409550.0 event=invocation pid=77 pkg=com.rhizo.deskapp activity=.Main\n")
    if hasattr(deskd, "connect_launches"):
        deskd.connect_launches()
    close = control_watch(d, deskd)
    try:
        append(d.CONTROL_OUT, "display pooled id=2 port=1 960x1080\ndisplay powered id=2 port=1\n")
        deskd.on_control(None)
        append(d.LAUNCH_LOG, record(5, 2))
        deliver(deskd)
        deskd.on_control(None)
    finally:
        close()
    check("a launch record written after the pool fill powered its display arms that display",
          dragwatches(sent) == [5] and deskd.cid_by_display.get(5) == "2",
          "dragwatch sent for %r, cid_by_display %r" % (dragwatches(sent), deskd.cid_by_display))


def test_dir_created_later(d, tmp):
    """check a launch directory created after deskd started"""
    deskd, sent = bridge(d, tmp)
    if not hasattr(deskd, "connect_launches"):
        check("a launch directory created after deskd started is still followed", False,
              "this deskd has no launch watch")
        return
    deskd.connect_launches()
    os.makedirs(os.path.dirname(d.LAUNCH_LOG))
    deliver(deskd)
    append(d.LAUNCH_LOG, record(4, 3))
    deliver(deskd)
    check("a launch directory created after deskd started is still followed",
          dragwatches(sent) == [4], "dragwatch sent for %r" % (dragwatches(sent),))


def test_history_and_reauth(d, tmp):
    """test launch records at start and re-arm"""
    deskd, sent = bridge(d, tmp)
    os.makedirs(os.path.dirname(d.LAUNCH_LOG))
    append(d.LAUNCH_LOG, record(3, 2) + record(6, 4))
    if not hasattr(deskd, "connect_launches"):
        check("records already in the log at start are history, and a re-authenticated android app "
              "is asked to watch only the newest", False, "this deskd has no launch watch")
        return
    deskd.connect_launches()
    deliver(deskd)
    before = list(dragwatches(sent))
    append(d.LAUNCH_LOG, record(3, 5))
    deskd.launches.offset = os.stat(d.LAUNCH_LOG).st_size
    deskd.rearm_dragwatch()
    check("records already in the log at start are history, and a re-authenticated android app "
          "is asked to watch each display once, with its newest composer id",
          before == [] and dragwatches(sent) == [6, 3] and deskd.cid_by_display == {6: "4", 3: "5"},
          "at start %r, after re-auth %r, cid_by_display %r"
          % (before, dragwatches(sent), deskd.cid_by_display))


def test_powered_line_arms_nothing(d, tmp):
    """test display powered lines on control.out"""
    deskd, sent = bridge(d, tmp)
    os.makedirs(os.path.dirname(d.LAUNCH_LOG))
    append(d.LAUNCH_LOG, record(7, 3))
    append(d.CONTROL_OUT, "display powered id=3 port=2\n")
    close = control_watch(d, deskd)
    try:
        deskd.on_control(None)
    finally:
        close()
    check("a 'display powered' line arms no pad, even when an earlier launch record names its id",
          dragwatches(sent) == [], "dragwatch sent for %r" % (dragwatches(sent),))


def test_drag_off(d, tmp):
    """check that no launch is watched when drag is off"""
    deskd, sent = bridge(d, tmp, drag=False)
    os.makedirs(os.path.dirname(d.LAUNCH_LOG))
    if not hasattr(deskd, "connect_launches"):
        check("with desktop.drag off no launch is watched and no pad is asked for", False,
              "this deskd has no launch watch")
        return
    deskd.connect_launches()
    append(d.LAUNCH_LOG, record(5, 2))
    deliver(deskd)
    deskd.rearm_dragwatch()
    check("with desktop.drag off no launch is watched and no pad is asked for",
          deskd.launches is None and dragwatches(sent) == [] and not deskd.sel.get_map(),
          "launches %r, dragwatch %r, selector %r"
          % (deskd.launches, dragwatches(sent), dict(deskd.sel.get_map())))


def two_windows(d, tmp):
    """create a Deskd with two launched apps"""
    deskd, sent = bridge(d, tmp)
    os.makedirs(os.path.dirname(d.LAUNCH_LOG))
    deskd.connect_launches()
    append(d.LAUNCH_LOG, record(5, 2) + record(7, 3, pkg="com.rhizo.other"))
    deliver(deskd)
    for display in (5, 7):
        say(deskd, {"t": "dragwatch_ready", "display": display, "x": 16, "y": 16})
    return deskd, sent


def test_drag_out_of_first_window(d, tmp):
    """check a drag that leaves the first window"""
    deskd, sent = two_windows(d, tmp)
    say(deskd, {"t": "drag_started", "mimes": ["text/plain"], "display": 5})
    say(deskd, {"t": "drag_data", "mime": "text/plain", "b64": "eA==", "display": 5})
    sent_before_end = len(sent)
    say(deskd, {"t": "drag_ended", "result": True, "display": 5})
    want = ["inject touch move 2 16 16", "drag start 2 text/plain eA=="]
    check("with two app windows up, a drag out of the first is carried from its own pad on its "
          "own composer display, and its end re-arms that display",
          deskd.composer == want and dragwatches(sent[sent_before_end:]) == [5]
          and dragwatches(sent[:sent_before_end]) == [5, 7] and deskd.dragout is None,
          "composer %r, dragwatch before end %r, after %r, dragout %r"
          % (deskd.composer, dragwatches(sent[:sent_before_end]),
             dragwatches(sent[sent_before_end:]), deskd.dragout))


def test_drag_reported_by_every_pad(d, tmp):
    """test drag reports from every pad"""
    ok, detail = True, []
    for order in ((5, 7), (7, 5)):
        deskd, sent = two_windows(d, os.path.join(tmp, "%d-%d" % order))
        with clock(d) as now:
            say(deskd, {"t": "drag_started", "mimes": ["text/plain"], "display": order[0]})
            now[0] += 0.3
            say(deskd, {"t": "drag_started", "mimes": ["text/plain"], "display": order[1]})
            moves = list(deskd.composer)
            now[0] += 0.2
            deskd.lift_when_due()
            early = deskd.composer[len(moves):]
            now[0] += 0.2
            deskd.lift_when_due()
        lifts = deskd.composer[len(moves):]
        say(deskd, {"t": "drag_data", "mime": "text/plain", "b64": "eA==", "display": 5})
        good = (sorted(moves) == ["inject touch move 2 16 16", "inject touch move 3 16 16"] and early == []
                and sorted(lifts) == ["inject touch up 2", "inject touch up 3"]
                and deskd.composer[-1] == "drag start 2 text/plain eA==" and deskd.pending_up is None)
        ok = ok and good
        detail.append("order %r: moves %r, lifted 0.2s after the later move %r, at 0.4s %r, last %r"
                      % (order, moves, early, lifts, deskd.composer[-1:]))
    check("a drag every pad reports is moved and lifted on each reporting display one dwell after the "
          "later move, whichever reported last, and its payload is served from the display whose pad read it",
          ok, "; ".join(detail))


def test_drop_lift_survives_a_report(d, tmp):
    """test the drop lift with a second pad"""
    deskd, sent = two_windows(d, tmp)
    with clock(d) as now:
        deskd.drop = {"cid": "2", "x": 40, "y": 50}
        deskd.finish_drag()
        say(deskd, {"t": "drag_started", "mimes": ["text/plain"], "display": 7})
        now[0] += 0.4
        deskd.lift_when_due()
    lifts = [c for c in deskd.composer if c.startswith("inject touch up")]
    check("an incoming drop's lift is still sent when another display's pad reports the drag it started",
          sorted(lifts) == ["inject touch up 2", "inject touch up 3"], "composer %r" % (deskd.composer,))


class clock:
    """test clock for time.monotonic"""
    def __init__(self, d):
        """store the module and a clock starting at 1000"""
        self.d, self.now = d, [1000.0]

    def __enter__(self):
        """replace the monotonic clock with a settable one"""
        self.real = self.d.time.monotonic
        self.d.time.monotonic = lambda: self.now[0]
        return self.now

    def __exit__(self, *exc):
        """restore the monotonic clock"""
        self.d.time.monotonic = self.real


def test_drop_end_rearms_its_display(d, tmp):
    """test re-arming at the drop end"""
    deskd, sent = two_windows(d, tmp)
    before = len(sent)
    say(deskd, {"t": "drag_ended", "result": True, "display": 5})
    check("an incoming drop's end re-arms the display it landed on, never the one launched last",
          dragwatches(sent[before:]) == [5], "re-armed %r" % (dragwatches(sent[before:]),))


def test_reauth_skips_a_gone_sandbox(d, tmp):
    """test re-authentication with a gone sandbox"""
    deskd, sent = bridge(d, tmp)
    os.makedirs(os.path.dirname(d.LAUNCH_LOG))
    append(d.LAUNCH_LOG, record(3, 2, init=99) + record(4, 5) + record(6, 7, init=99))
    deskd.connect_launches()
    deskd.rearm_dragwatch()
    check("a re-authenticated android app is asked to watch only displays a running sandbox launched",
          dragwatches(sent) == [4] and deskd.cid_by_display == {4: "5"},
          "dragwatch %r, cid_by_display %r" % (dragwatches(sent), deskd.cid_by_display))


def test_ready_without_display(d, tmp):
    """check a dragwatch ready message that names no display"""
    deskd, sent = two_windows(d, tmp)
    pads = dict(deskd.pads)
    try:
        say(deskd, {"t": "dragwatch_ready", "x": 16, "y": 16})
        raised = None
    except (KeyError, ValueError, TypeError) as exc:
        raised = exc
    check("a ready naming no display is ignored, never an error that drops the android app",
          raised is None and deskd.pads == pads, "raised %r, pads %r" % (raised, deskd.pads))


def test_display_gone(d, tmp):
    """check that a display the android app reports gone is dropped"""
    deskd, sent = two_windows(d, tmp)
    say(deskd, {"t": "dragwatch_error", "display": 5, "reason": "no display 5"})
    say(deskd, {"t": "drag_started", "mimes": ["text/plain"], "display": 5})
    say(deskd, {"t": "drag_ended", "result": False, "display": 5})
    check("a display the android app reports gone is dropped, and a drag reported from it is carried "
          "nowhere and re-arms nothing",
          deskd.composer == [] and 5 not in deskd.cid_by_display and 5 not in deskd.pads
          and dragwatches(sent) == [5, 7],
          "composer %r, cid_by_display %r, pads %r, dragwatch %r"
          % (deskd.composer, deskd.cid_by_display, deskd.pads, dragwatches(sent)))


def main():
    """run every check"""
    d = load()
    tests = (test_launch_after_power, test_dir_created_later, test_history_and_reauth,
             test_powered_line_arms_nothing, test_drag_off, test_drag_out_of_first_window,
             test_drag_reported_by_every_pad, test_drop_lift_survives_a_report,
             test_drop_end_rearms_its_display, test_display_gone, test_reauth_skips_a_gone_sandbox,
             test_ready_without_display)
    for test in tests:
        with tempfile.TemporaryDirectory() as tmp:
            test(d, tmp)
    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("all %d passed" % len(tests))
    return 0


if __name__ == "__main__":
    sys.exit(main())
