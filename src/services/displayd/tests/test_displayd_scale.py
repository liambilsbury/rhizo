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
    """load displayd as a module"""
    spec = importlib.util.spec_from_file_location("rhizo_displayd_scale_under_test", DISPLAYD)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


DUMP = "\n".join([
    '  DisplayDeviceInfo{"Built-in Screen": uniqueId="local:1", 1280 x 800, modeId 1, density 400, '
    '400.0 x 400.0 dpi, address {port=0}, state ON}',
    '  DisplayDeviceInfo{"Rhizo display 2": uniqueId="local:2", 1920 x 1008, modeId 12, density 0, '
    '800.0 x 800.0 dpi, address {port=1}, state ON}',
    '  DisplayDeviceInfo{"Rhizo display 9": uniqueId="local:9", 960 x 540, modeId 3, density 0, '
    '400.0 x 400.0 dpi, address {port=10}, state ON}',
])


def main():
    """run the display scale cases"""
    d = load()
    sway = d.scaled_density(546, 800, 400.0)
    check("scale.sway-keeps-pixels", sway == 1092, "got %r, want 1092" % sway)
    kwin = d.scaled_density(1092, 800, 800.0)
    check("scale.kwin-keeps-logical-size", kwin == 1092, "got %r, want 1092" % kwin)
    old = 1092 * 2
    check("scale.old-rule-is-four-times", old != kwin and old == 4 * 546, "the old rule's %d" % old)

    d.android = lambda cmd: DUMP
    check("dpi.port-1", d.device_dpi(1) == 800.0, "got %r" % d.device_dpi(1))
    check("dpi.port-10-not-port-1", d.device_dpi(10) == 400.0, "got %r" % d.device_dpi(10))
    check("dpi.port-absent", d.device_dpi(5) is None, "got %r" % d.device_dpi(5))
    d.android = lambda cmd: None
    check("dpi.no-answer", d.device_dpi(1) is None, "got %r" % d.device_dpi(1))

    planned = d.plan(["display scaled id=2 port=1 scale=1.5 dpi=600"])
    check("plan.fractional-scale", planned == [("scaled", (2, 1, 1.5, 600))], "got %r" % (planned,))
    check("scale.fractional-on-kwin", d.scaled_density(819, 600, 600.0) == 819,
          "got %r" % d.scaled_density(819, 600, 600.0))
    check("scale.fractional-on-sway", d.scaled_density(546, 600, 400.0) == 819,
          "got %r" % d.scaled_density(546, 600, 400.0))

    state = {"physical": 546, "override": None}
    writes = []

    def android(cmd):
        """answer Android commands with display and density state"""
        if cmd.startswith("dumpsys display"):
            return DUMP
        if cmd.startswith("wm density -d"):
            out = "Physical density: %d" % state["physical"]
            return out + ("\nOverride density: %d" % state["override"] if state["override"] else "")
        if cmd.startswith("wm density "):
            state["override"] = int(cmd.split()[2])
            writes.append(state["override"])
            state["physical"] = 1092
            return ""
        return None
    d.android = android
    d.logical_id_for_port = lambda port: 4
    d.tell_composer_cursor_scale = lambda cid, port: "told"
    d.log = lambda msg: None
    first = d.apply(2, 1, 2.0, 800)
    check("apply.base-moved-under-the-write-is-pending", first is False and writes == [546],
          "apply -> %r after writing %r" % (first, writes))
    second = d.apply(2, 1, 2.0, 800)
    check("apply.next-pass-writes-the-scaled-density", second is True and writes == [546, 1092],
          "apply -> %r after writing %r" % (second, writes))

    if failures:
        print("test_displayd_scale: %d failure(s)" % len(failures))
        return 1
    print("test_displayd_scale: a scale change's density follows the DPI the framework holds, on sway and KWin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
