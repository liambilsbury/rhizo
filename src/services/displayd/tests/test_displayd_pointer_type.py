#!/usr/bin/env python3
import importlib.util
import os
import sys

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
    return module


def controller(display, requested, resolved):
    """return a display's mouse PointerController block as PointerChoreographer dumps it"""
    return ["    %s :     PointerController:" % display,
            "          Presentation: POINTER",
            "          Pointer Display ID: %s" % display,
            "          Viewports:",
            "          Spot Controllers:",
            "          Cursor Controller:",
            "            MouseCursorController:",
            "              viewport: Viewport INTERNAL: displayId=%s" % display,
            "              requestedPointerType: %d" % requested,
            "              resolvedPointerType: %d" % resolved,
            "              skipScreenshot: false"]


def dump(mice, touch=()):
    """return the PointerChoreographer part of a fake dumpsys input"""
    lines = ["PointerChoreographer:", "  Show Touches Enabled: false", "  MousePointerControllers:"]
    for display, requested, resolved in mice:
        lines += controller(display, requested, resolved)
    lines.append("  TouchPointerControllers:")
    for device, requested, resolved in touch:
        lines += controller(device, requested, resolved)
    lines += ["  StylusPointerControllers:", "  DrawingTabletControllers:", ""]
    return "\n".join(lines)


def test_resolved_type():
    """read the resolvedPointerType of a display's mouse controller"""
    d = load()
    text = dump([(0, 1000, 1000), (2, 1008, 1008), (3, 1, 1000)], touch=[(2, 1007, 1007)])
    check("display 2 draws TEXT", d.resolved_pointer_type(text, "2") == 1008,
          repr(d.resolved_pointer_type(text, "2")))
    check("display 3's unspecified request resolves to ARROW", d.resolved_pointer_type(text, "3") == 1000,
          repr(d.resolved_pointer_type(text, "3")))
    check("a touch controller with the display's number is not read", d.resolved_pointer_type(
        dump([(0, 1000, 1000)], touch=[(2, 1007, 1007)]), "2") is None)
    check("a display with no mouse controller has no type", d.resolved_pointer_type(text, "9") is None)
    check("a custom icon reads -1", d.resolved_pointer_type(dump([(2, -1, -1)]), "2") == -1)
    check("a dump with no PointerChoreographer has no type", d.resolved_pointer_type("Input Reader State:", "2") is None)


def test_plan_asks():
    """plan the newest unknown-image line per display and drop a removed display's"""
    d = load()
    got = d.plan(["display cursor-unknown id=2 port=1 digest=11",
                  "display cursor-unknown id=2 port=1 digest=12",
                  "display cursor-unknown id=3 port=2 digest=13",
                  "display cursor-unknown id=4 port=3 digest=14",
                  "display remove id=4 ok"])
    want = [("cursor", (2, 1, 12)), ("cursor", (3, 2, 13)), ("gone", (4,))]
    check("plan keeps the newest ask per display", got == want, repr(got))


def test_tell():
    """read the type, wait, then reply with the requested digest"""
    d = load()
    calls = []
    slept = []

    def android(cmd):
        calls.append(cmd)
        if cmd.startswith("dumpsys display"):
            return "mViewports=[DisplayViewport{type=EXTERNAL, displayId=2, physicalPort=1}]\n"
        if cmd == d.POINTER_GREP:
            return dump([(2, 1007, 1007)])
        return ""

    d.android = android
    ok = d.tell_composer_pointer_type(5, 1, 4242, sleep=slept.append)
    sent = [c for c in calls if c.startswith("echo display cursor-type")]
    check("the answer is sent", ok and sent == ["echo display cursor-type 5 4242 1007 > %s" % d.CONTROL_IN],
          repr(calls))
    check("the answer waits the settle time after the read", slept == [d.POINTER_TYPE_SETTLE_S] and
          calls.index(d.POINTER_GREP) < calls.index(sent[0]) if sent else False, repr((slept, calls)))

    calls.clear()
    d.android = lambda cmd: calls.append(cmd) or ("" if cmd == d.POINTER_GREP else
                                                   "mViewports=[DisplayViewport{displayId=2, physicalPort=1}]")
    check("no type read sends no answer", not d.tell_composer_pointer_type(5, 1, 4242, sleep=slept.append) and
          not any(c.startswith("echo") for c in calls), repr(calls))


def main():
    """run all of the checks"""
    test_resolved_type()
    test_plan_asks()
    test_tell()
    if failures:
        print("FAILED: %s" % ", ".join(failures))
        return 1
    print("rhizo-displayd names the pointer type each cursor image draws")
    return 0


if __name__ == "__main__":
    sys.exit(main())
