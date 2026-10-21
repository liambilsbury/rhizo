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


def device(dev_id, name, port, mapper=None):
    """return a dumpsys input device block"""
    lines = ["  Device %d: %s" % (dev_id, name),
             "    EventHub Devices: [ %d ] " % dev_id,
             "    AssociatedDisplayPort: %d" % port,
             "    Sources: MOUSE"]
    if mapper is not None:
        xscale, yscale, display = mapper
        lines += ["    Cursor Input Mapper:",
                  "      Parameters:",
                  "        HasAssociatedDisplay: true",
                  "      XScale: %s" % xscale,
                  "      YScale: %s" % yscale]
        if display is not None:
            lines.append("      DisplayId: %s" % display)
        lines.append("      ViewportDensityDpi: 0")
    else:
        lines += ["    Keyboard Input Mapper:", "      Parameters:"]
    return "\n".join(lines)


def dump(devices, speed="0", unscaled="", release="a16"):
    """return a fake dumpsys input output"""
    head = ["INPUT MANAGER (dumpsys input)", "", "Input Manager State:",
            "  Display not interactive: {}"]
    if speed is not None:
        head.append("  Pointer Speed: %s" % speed)
    exempt = ("Display with Mouse Pointer Acceleration Disabled" if release == "a15"
              else "Display with Mouse Scaling Disabled")
    head += ["  %s: {%s}" % (exempt, unscaled), "",
             "Event Hub State:", "  Devices:", "    21: rhizo-mouse-1", "",
             "Input Reader State (Nums of device: %d):" % len(devices)]
    return "\n".join(head + devices + ["", "Input Dispatcher State:", "  DispatchEnabled: true", ""])


MOUSE_1 = device(21, "rhizo-mouse-1", 1, ("1.000", "1.000", "2"))
MOUSE_0 = device(17, "rhizo-mouse-0", 0, ("1.250", "1.250", "0"))
KEYBOARD_1 = device(13, "rhizo-keyboard-1", 1)


def test_gain():
    """check that the gain is read from dumpsys input"""
    d = load()
    check("rhizo-displayd reads the gain from dumpsys input",
          hasattr(d, "cursor_gain_milli") and hasattr(d, "flat_pointer_gain"),
          "no cursor_gain_milli/flat_pointer_gain")
    if not hasattr(d, "cursor_gain_milli") or not hasattr(d, "flat_pointer_gain"):
        return
    g = d.cursor_gain_milli
    check("flat curve gain is 1.0 at speed -7, 2.25 at 0, 3.5 at 7",
          [d.flat_pointer_gain(s) for s in (-7, 0, 7)] == [1.0, 2.25, 3.5],
          "got %r" % [d.flat_pointer_gain(s) for s in (-7, 0, 7)])
    got = g(dump([KEYBOARD_1, MOUSE_0, MOUSE_1]), 1)
    check("an external display at speed 0 is XScale 1.000 x 2.25, not density/160",
          got == 2250, "got %r (the old formula sent 3412)" % (got,))
    got = g(dump([MOUSE_0, MOUSE_1]), 0)
    check("the internal display's own XScale is multiplied in", got == 2812, "got %r" % (got,))
    got = g(dump([MOUSE_1], speed="-7"), 1)
    check("the dumped pointer speed sets the curve's gain", got == 1000, "got %r" % (got,))
    got = g(dump([MOUSE_1], unscaled="2"), 1)
    check("a display with mouse scaling disabled takes neither factor", got == 1000, "got %r" % (got,))
    got = g(dump([MOUSE_1], unscaled="0"), 1)
    check("scaling disabled on another display leaves this one scaled", got == 2250, "got %r" % (got,))
    got = g(dump([KEYBOARD_1, MOUSE_0]), 1)
    check("no mouse on the port: no gain", got is None, "got %r" % (got,))
    got = g(dump([device(21, "rhizo-mouse-1", 1, ("1.000", "1.000", None))]), 1)
    check("a mouse not yet bound to a display: no gain", got is None, "got %r" % (got,))
    got = g(dump([device(21, "rhizo-mouse-1", 1, ("1.250", "1.000", "2"))]), 1)
    check("axes that scale apart: no single gain", got is None, "got %r" % (got,))
    got = g(dump([MOUSE_1], speed=None), 1)
    check("no pointer speed in the dump: no gain", got is None, "got %r" % (got,))
    got = g("", 1)
    check("an empty dump: no gain", got is None, "got %r" % (got,))
    got = d.cursor_gain(dump([MOUSE_1]), 1, acceleration_off=False)
    check("a16 with pointer acceleration on: no constant gain, and not a wait for a mouse",
          got == (None, d.NO_CONSTANT_GAIN), "got %r" % (got,))
    got = d.cursor_gain(dump([MOUSE_1]), 1, acceleration_off=True)
    check("a16/a17 with acceleration off: the flat gain", got == (2250, None), "got %r" % (got,))
    got = d.cursor_gain(dump([MOUSE_1], release="a15"), 1, acceleration_off=True)
    check("a15, display not exempt: accelerated whatever the (absent) setting says",
          got == (None, d.NO_CONSTANT_GAIN), "got %r" % (got,))
    got = d.cursor_gain(dump([MOUSE_1], release="a15", unscaled="2"), 1, acceleration_off=False)
    check("a15, display exempt from acceleration: XScale alone", got == (1000, None), "got %r" % (got,))
    got = d.cursor_gain(dump([MOUSE_0], release="a15", unscaled="0"), 0, acceleration_off=False)
    check("a15 keeps the mapper's own XScale on an exempt display", got == (1250, None), "got %r" % (got,))
    got = d.cursor_gain(dump([KEYBOARD_1], release="a15"), 1, acceleration_off=True)
    check("a15 with no mouse on the port: unbound", got == (None, d.UNBOUND), "got %r" % (got,))


def stub_android(d, answers, sent, accel=None):
    """replace android() with a recording stub"""
    reads = list(accel) if accel is not None else None

    def android(cmd):
        """answer Android commands with the dump and the acceleration setting"""
        sent.append(cmd)
        if cmd == "dumpsys input":
            return answers.pop(0) if answers else ""
        if cmd == "settings get system mouse_pointer_acceleration_enabled":
            if reads is None:
                return "0\n"
            return (reads.pop(0) if reads else "") + "\n"
        if "DisplayDeviceInfo" in cmd:
            return "DisplayDeviceInfo{\"Rhizo display 2\": 960 x 1080, modeId 11, density 0, 400.0 x 400.0 dpi, address {port=1}}"
        if cmd.startswith("dumpsys display"):
            return "mViewports=[DisplayViewport{type=EXTERNAL, displayId=2, physicalPort=1}]"
        if cmd.startswith("wm density -d"):
            return "Physical density: 546\nOverride density: 1092\n"
        return ""
    d.android = android


def writes(sent):
    """return the cursor-scale commands among the sent commands"""
    return [c for c in sent if "cursor-scale" in c]


def test_tell_and_born():
    """check the gain told to the composer for a born display"""
    d = load()
    sent = []
    stub_android(d, [dump([MOUSE_1])], sent)
    told = d.tell_composer_cursor_scale(2, 1)
    check("the composer is told the dumped gain for its display",
          told == "told" and writes(sent) == ["echo display cursor-scale 2 2250 > %s" % d.CONTROL_IN],
          "told=%r writes=%r" % (told, writes(sent)))

    sent = []
    stub_android(d, [dump([KEYBOARD_1])], sent)
    told = d.tell_composer_cursor_scale(2, 1)
    check("no gain read: nothing is written and the caller hears the mouse is unbound",
          told == d.UNBOUND and writes(sent) == [], "told=%r writes=%r" % (told, writes(sent)))

    sent = []
    stub_android(d, [dump([KEYBOARD_1]), dump([KEYBOARD_1]), dump([KEYBOARD_1, MOUSE_1])], sent)
    verdicts = [d.announce_born(2, 1) for _ in range(3)]
    check("a born display answers unbound until its mouse is bound, then is told once",
          verdicts == [d.UNBOUND, d.UNBOUND, "told"]
          and writes(sent) == ["echo display cursor-scale 2 2250 > %s" % d.CONTROL_IN],
          "verdicts=%r writes=%r" % (verdicts, writes(sent)))


def puts(sent):
    """return the settings put commands among the sent commands"""
    return [c for c in sent if c.startswith("settings put")]


def test_acceleration_turned_off():
    """check that acceleration is turned off"""
    d = load()
    sent = []
    stub_android(d, [dump([MOUSE_1])], sent, accel=["1", "0"])
    told = d.tell_composer_cursor_scale(2, 1)
    check("acceleration found on (a wiped or updated /data) is turned off, read back, then the gain sent",
          told == "told" and puts(sent) == ["settings put system mouse_pointer_acceleration_enabled 0"]
          and writes(sent) == ["echo display cursor-scale 2 2250 > %s" % d.CONTROL_IN],
          "told=%r puts=%r writes=%r" % (told, puts(sent), writes(sent)))
    sent = []
    stub_android(d, [dump([MOUSE_1])], sent, accel=["null", "null"])
    told = d.tell_composer_cursor_scale(2, 1)
    check("an unset setting (Android's default, on) is turned off too",
          told == d.UNBOUND and puts(sent) and writes(sent) == [],
          "told=%r puts=%r writes=%r" % (told, puts(sent), writes(sent)))
    sent = []
    stub_android(d, [dump([MOUSE_1])], sent, accel=["", ""])
    told = d.tell_composer_cursor_scale(2, 1)
    check("no settings provider yet: nothing sent, and the caller asks again",
          told == d.UNBOUND and writes(sent) == [], "told=%r writes=%r" % (told, writes(sent)))
    sent = []
    stub_android(d, [dump([MOUSE_1])], sent, accel=["0"])
    told = d.tell_composer_cursor_scale(2, 1)
    check("acceleration already off: no write to the setting",
          told == "told" and puts(sent) == [], "told=%r puts=%r" % (told, puts(sent)))
    sent = []
    stub_android(d, [dump([MOUSE_1], release="a15")], sent, accel=["null"])
    told = d.tell_composer_cursor_scale(2, 1)
    check("a15: no setting touched, no cursor scale sent, the display reported non-constant",
          told == d.NO_CONSTANT_GAIN and puts(sent) == [] and writes(sent) == []
          and not any("mouse_pointer_acceleration" in c for c in sent),
          "told=%r sent=%r" % (told, sent))


def test_scale_change_sends_gain():
    """check that a scale change sends the gain"""
    d = load()
    for scale in (2, 1):
        sent = []
        stub_android(d, [dump([MOUSE_1])], sent)
        d.apply(2, 1, scale, 400 * scale)
        check("a scale-%d change tells the composer the gain, not a density" % scale,
              writes(sent) == ["echo display cursor-scale 2 2250 > %s" % d.CONTROL_IN],
              "writes=%r" % (writes(sent),))


def main():
    """run every check"""
    test_gain()
    test_tell_and_born()
    test_acceleration_turned_off()
    test_scale_change_sends_gain()
    if failures:
        print("FAILED: %s" % ", ".join(failures))
        return 1
    print("rhizo-displayd tells the composer the mouse gain Android's own mapper applies")
    return 0


if __name__ == "__main__":
    sys.exit(main())
