#!/usr/bin/env python3
import base64
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
    spec = importlib.util.spec_from_file_location("deskd_noclipboard_under_test", DESKD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = lambda msg: None
    return module


class Bridge:
    """fake rhizo-wlbridge connection"""

    def __init__(self):
        """start with no sets recorded and the bridge not ready"""
        self.sets = []
        self.ready = False

    def set(self, mime, b64):
        """record a clipboard set"""
        self.sets.append((mime, b64))


def deskd_with_bridge(d):
    """build a deskd with a fake bridge and composer"""
    deskd = d.Deskd.__new__(d.Deskd)
    deskd.wl = Bridge()
    deskd.wl_dead = False
    deskd.session_writes = 0
    deskd.wl_session_write = 0
    deskd.wl_clipboard = True
    deskd.android_clip_sha256 = None
    deskd.host_clip_sha256 = None
    deskd.init_clip_state()
    composer = []
    deskd.to_composer = composer.append
    return deskd, composer


def main():
    """check clipboard behavior when wlbridge has no clipboard"""
    d = load()
    b64 = base64.b64encode(b"rhizo-a2h-clip").decode("ascii")

    deskd, composer = deskd_with_bridge(d)
    deskd.handle_wl_line("ready")
    deskd.handle_wl_line("noclipboard the compositor offers no zwlr_data_control_manager_v1")
    deskd.clip_from_android({"mime": "text/plain", "b64": b64})
    check("after `noclipboard` the android app's clip goes to the composer leg and no `set` reaches the bridge",
          deskd.wl.sets == [] and composer == ["clip set 1 text/plain %s" % b64],
          "bridge sets %r, composer %r" % (deskd.wl.sets, composer))

    deskd, composer = deskd_with_bridge(d)
    deskd.handle_wl_line("ready")
    deskd.clip_from_android({"mime": "text/plain", "b64": b64})
    check("a bridge with a clipboard leg still gets the clip, beside the composer",
          deskd.wl.sets == [("text/plain", b64)] and composer == ["clip set 1 text/plain %s" % b64],
          "bridge sets %r, composer %r" % (deskd.wl.sets, composer))

    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("all 2 passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
