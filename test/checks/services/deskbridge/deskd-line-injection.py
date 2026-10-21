#!/usr/bin/env python3
import base64
import importlib.util
import json
import os
import socket
import sys
import time

from desk_hello import android_hello

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD_PATH = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.join(HERE, "..", "..", "..", "..", "src", "services", "deskbridge", "deskd.py"))


def load_deskd():
    """return the deskd module loaded from its file"""
    spec = importlib.util.spec_from_file_location("rhizo_deskd_under_test", DESKD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_clip_set_injection(port, wl_lines_path):
    """check the clip_set newline refusal"""
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    stream, hello = android_hello(sock, "checktoken")
    if not hello or hello.get("t") != "hello_ok":
        print("check-deskd-line-injection: the bridge refused the hello: %r" % hello)
        return False

    legit_b64 = base64.b64encode(b"RHIZO_INJECTED_LINE_CANARY_PAYLOAD").decode()
    split = len(legit_b64) // 2
    evil_b64 = legit_b64[:split] + "\n" + legit_b64[split:]
    assert base64.b64decode(evil_b64) == b"RHIZO_INJECTED_LINE_CANARY_PAYLOAD"
    stream.write(json.dumps({"t": "clip_set", "mime": "text/plain", "b64": evil_b64}).encode() + b"\n")
    stream.flush()

    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if os.path.exists(wl_lines_path) and os.path.getsize(wl_lines_path) > 0:
            break
        time.sleep(0.1)
    time.sleep(0.3)

    lines = []
    if os.path.exists(wl_lines_path):
        with open(wl_lines_path) as f:
            lines = [line.rstrip("\n") for line in f if line.strip()]

    if lines:
        print("check-deskd-line-injection: rhizo-wlbridge received %d line(s) from ONE "
              "malicious clip_set, wanted 0: %r" % (len(lines), lines))
        return False
    print("check-deskd-line-injection: a clip_set carrying an embedded newline in its b64 "
          "was refused whole; no line reached rhizo-wlbridge")
    return True


class _Recorder:
    """fake for Deskd.to_composer"""

    def __init__(self):
        """start with no recorded commands"""
        self.calls = []

    def __call__(self, command):
        """record the command and return true"""
        self.calls.append(command)
        return True


def test_drag_data_injection(deskd):
    """check newline injection through a drag mime type"""
    inst = object.__new__(deskd.Deskd)
    inst.dragout = {"cid": "5"}
    rec = _Recorder()
    inst.to_composer = rec
    evil_mime = "text/plain\nRHIZO_INJECTED_DRAG_CANARY"
    msg = {"mime": evil_mime, "b64": base64.b64encode(b"x").decode()}
    try:
        inst.on_android_drag_data(msg)
    except ValueError:
        pass
    if rec.calls:
        print("check-deskd-line-injection: on_android_drag_data sent %r to the composer's "
              "control FIFO for a mime carrying a newline" % (rec.calls,))
        return False
    print("check-deskd-line-injection: on_android_drag_data refused a mime carrying a "
          "newline before it ever reached the composer's control FIFO")
    return True


def test_press_on_pad_coercion(deskd):
    """check newline injection through a pad press coordinate"""
    inst = object.__new__(deskd.Deskd)
    inst.drop = {"cid": "5"}
    rec = _Recorder()
    inst.to_composer = rec
    evil_x = "10\nRHIZO_INJECTED_PRESS_CANARY"
    msg = {"x": evil_x, "y": "20"}
    try:
        inst.press_on_pad(msg)
    except ValueError:
        pass
    for call in rec.calls:
        if "RHIZO_INJECTED_PRESS_CANARY" in call:
            print("check-deskd-line-injection: press_on_pad sent %r to the composer's "
                  "control FIFO for an x carrying a newline" % (call,))
            return False
    print("check-deskd-line-injection: press_on_pad's int(float(...)) coercion refused "
          "an x carrying a newline before it reached the composer's control FIFO")
    return True


def main():
    """run the injection checks and return the exit code"""
    port, wl_lines_path = int(sys.argv[1]), sys.argv[3]
    deskd = load_deskd()
    ok = True
    ok = test_clip_set_injection(port, wl_lines_path) and ok
    ok = test_drag_data_injection(deskd) and ok
    ok = test_press_on_pad_coercion(deskd) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
