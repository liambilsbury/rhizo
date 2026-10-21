#!/usr/bin/env python3
import base64
import contextlib
import importlib.util
import io
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD_PATH = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.join(HERE, "..", "..", "..", "..", "src", "services", "deskbridge", "deskd.py"))


def load_deskd():
    """return the deskd module loaded from its file"""
    spec = importlib.util.spec_from_file_location("rhizo_deskd_under_test", DESKD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _Recorder:
    def __init__(self):
        """start with no recorded calls"""
        self.calls = []

    def __call__(self, obj):
        """record the object it was called with"""
        self.calls.append(obj)


def test_traversal_escapes_host_data(deskd):
    """test composer drop path traversal"""
    with tempfile.TemporaryDirectory(prefix="rhizo-drop-traversal-") as tmp:
        host_data = os.path.join(tmp, "host_data") + os.sep
        os.mkdir(host_data)
        secret_path = os.path.join(tmp, "secret.txt")
        with open(secret_path, "wb") as f:
            f.write(b"TOP SECRET CONTENTS")
        launch_log = os.path.join(tmp, "launch.log")
        with open(launch_log, "w") as f:
            f.write("boot display=3 cdisplay=5 ok\n")

        deskd.HOST_DATA = host_data
        deskd.LAUNCH_LOG = launch_log

        inst = object.__new__(deskd.Deskd)
        rec = _Recorder()
        inst.to_android = rec
        inst.drop = None
        inst.pad_press = None

        line = "drop id=5 path=/data/../secret.txt mime=text/plain x=1 y=2"
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            inst.on_composer_drop(line)

        if rec.calls:
            sent = rec.calls[0]
            leaked = base64.b64decode(sent.get("b64", "")) if "b64" in sent else b""
            print("check-deskd-drop-traversal: on_composer_drop forwarded %d bytes to the android app "
                  "for a path that escapes HOST_DATA: %r" % (len(leaked), leaked[:64]))
            return False
        print("check-deskd-drop-traversal: a path escaping HOST_DATA via '..' was refused, "
              "nothing forwarded to the android app")
    return True


def test_legitimate_path_still_works(deskd):
    """test a legitimate drop path"""
    with tempfile.TemporaryDirectory(prefix="rhizo-drop-traversal-legit-") as tmp:
        host_data = os.path.join(tmp, "host_data") + os.sep
        os.mkdir(host_data)
        payload_path = os.path.join(host_data, "payload.bin")
        with open(payload_path, "wb") as f:
            f.write(b"legitimate drop payload")
        launch_log = os.path.join(tmp, "launch.log")
        with open(launch_log, "w") as f:
            f.write("boot display=3 cdisplay=5 ok\n")

        deskd.HOST_DATA = host_data
        deskd.LAUNCH_LOG = launch_log

        inst = object.__new__(deskd.Deskd)
        rec = _Recorder()
        inst.to_android = rec
        inst.drop = None
        inst.pad_press = None

        line = "drop id=5 path=/data/payload.bin mime=text/plain x=1 y=2"
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            inst.on_composer_drop(line)

        if not rec.calls:
            print("check-deskd-drop-traversal: a legitimate in-HOST_DATA drop was refused; "
                  "stderr was: %s" % buf.getvalue())
            return False
        got = base64.b64decode(rec.calls[0]["b64"])
        if got != b"legitimate drop payload":
            print("check-deskd-drop-traversal: legitimate payload bytes corrupted: %r" % got)
            return False
        print("check-deskd-drop-traversal: a legitimate in-HOST_DATA drop still reaches the android app intact")
    return True


def test_oversized_read_is_capped(deskd):
    """test the MAX_PAYLOAD read cap"""
    with tempfile.TemporaryDirectory(prefix="rhizo-drop-traversal-cap-") as tmp:
        host_data = os.path.join(tmp, "host_data") + os.sep
        os.mkdir(host_data)
        big_path = os.path.join(host_data, "big.bin")
        cap = 4096
        with open(big_path, "wb") as f:
            f.write(b"X" * (cap * 4))
        launch_log = os.path.join(tmp, "launch.log")
        with open(launch_log, "w") as f:
            f.write("boot display=3 cdisplay=5 ok\n")

        deskd.HOST_DATA = host_data
        deskd.LAUNCH_LOG = launch_log
        old_cap = deskd.MAX_PAYLOAD
        deskd.MAX_PAYLOAD = cap
        try:
            inst = object.__new__(deskd.Deskd)
            rec = _Recorder()
            inst.to_android = rec
            inst.drop = None
            inst.pad_press = None

            line = "drop id=5 path=/data/big.bin mime=text/plain x=1 y=2"
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                inst.on_composer_drop(line)
        finally:
            deskd.MAX_PAYLOAD = old_cap

        if rec.calls:
            print("check-deskd-drop-traversal: an oversized drop payload (%d bytes, cap %d) "
                  "was forwarded to the android app anyway" % (cap * 4, cap))
            return False
        if "over the" not in buf.getvalue() and "cap" not in buf.getvalue():
            print("check-deskd-drop-traversal: an oversized drop payload was refused, but with "
                  "no cap-related message: %r" % buf.getvalue())
            return False
        print("check-deskd-drop-traversal: an oversized drop payload was refused under its cap")
    return True


def main():
    """run the drop checks and return the exit code"""
    deskd = load_deskd()
    ok = True
    ok = test_traversal_escapes_host_data(deskd) and ok
    ok = test_legitimate_path_still_works(deskd) and ok
    ok = test_oversized_read_is_capped(deskd) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
