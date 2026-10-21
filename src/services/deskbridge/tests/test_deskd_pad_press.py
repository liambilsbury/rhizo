#!/usr/bin/env python3
import importlib.util
import os
import sys

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
    """load deskd as a module with logging silenced"""
    spec = importlib.util.spec_from_file_location("deskd_pad_press_under_test", DESKD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = lambda msg: None
    return module


def bridge(d):
    """build a deskd with no pad press"""
    deskd = d.Deskd.__new__(d.Deskd)
    deskd.pad_press = None
    deskd.pending_up = None
    sent = []
    deskd.to_composer = sent.append
    return deskd, sent


def downs(sent):
    """return the touch down lines among the sent lines"""
    return [line for line in sent if line.startswith("inject touch down ")]


def main():
    """run the drop pad press cases"""
    d = load()

    deskd, sent = bridge(d)
    deskd.drop = {"cid": "3", "x": "640", "y": "384"}
    shown = {"t": "drop_pad", "display": 3, "x": 16, "y": 16}
    deskd.press_on_pad(shown)
    deskd.press_on_pad(shown)
    check("a pad reported shown twice for one drop is pressed once",
          downs(sent) == ["inject touch down 3 16 16"], "sent %r" % sent)

    deskd, sent = bridge(d)
    deskd.drop = {"cid": "3", "x": "640", "y": "384"}
    deskd.press_on_pad(shown)
    deskd.drop = {"cid": "4", "x": "100", "y": "100"}
    deskd.press_on_pad({"t": "drop_pad", "display": 4, "x": 16, "y": 16})
    check("the pad shown for a new drop is pressed",
          downs(sent) == ["inject touch down 3 16 16", "inject touch down 4 16 16"], "sent %r" % sent)

    deskd, sent = bridge(d)
    d.resolve_drop_path = lambda path: "/nonexistent/drop"
    d.read_raw = lambda *a, **k: b"payload"
    deskd.to_android = lambda msg: None
    deskd.logical_display_for = lambda cid: "3"
    deskd.on_composer_drop("drop id=3 port=2 x=640 y=384 mime=text/plain path=/data/a")
    deskd.press_on_pad(shown)
    cid, x, y, _, _ = deskd.pad_press
    deskd.pad_press = (cid, x, y, 4, 0)
    deskd.on_composer_drop("drop id=3 port=2 x=900 y=200 mime=text/plain path=/data/b")
    deskd.press_on_pad(shown)
    check("a second drop on the same display lifts the first's finger, then gets its own press "
          "and a full retry budget",
          sent == ["inject touch down 3 16 16", "inject touch up 3", "inject touch down 3 16 16"]
          and deskd.pad_press[3] == 0,
          "sent %r, press %r" % (sent, deskd.pad_press))

    deskd, sent = bridge(d)
    deskd.drop = {"cid": "3", "x": "640", "y": "384"}
    deskd.press_on_pad(shown)
    cid, x, y, attempts, _ = deskd.pad_press
    deskd.pad_press = (cid, x, y, attempts, 0)
    deskd.repress_when_due()
    check("a pad that did not arm is pressed again when its retry is due",
          sent[-2:] == ["inject touch up 3", "inject touch down 3 16 16"], "sent %r" % sent)

    if failures:
        print("%d failure(s)" % len(failures))
        sys.exit(1)


if __name__ == "__main__":
    main()
