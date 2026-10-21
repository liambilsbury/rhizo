#!/usr/bin/env python3
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
SINK = os.path.join(ROOT, "test", "system", "guest", "notify-sink.py")
BOUND_S = 15


def main():
    """return the failures"""
    if shutil.which("dbus-daemon") is None:
        return ["no dbus-daemon on this host"]
    with tempfile.TemporaryDirectory() as tmp:
        out = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"],
                             capture_output=True, text=True, timeout=BOUND_S)
        address, bus_pid = out.stdout.split("\n")[0], int(out.stdout.split("\n")[1])
        bus_fd = os.pidfd_open(bus_pid)
        os.mkdir(os.path.join(tmp, "icons"))
        sink = subprocess.Popen([sys.executable, SINK, "--record", os.path.join(tmp, "record.jsonl"),
                                 "--icon-dir", os.path.join(tmp, "icons")],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address), text=True)
        try:
            if sink.stdout.readline().strip() != "ready":
                return [f"the sink never owned the notification name: {sink.stderr.read()[-300:]!r}"]
            signal.pidfd_send_signal(bus_fd, signal.SIGTERM)
            select.select([bus_fd], [], [], BOUND_S)
            rc = sink.wait(BOUND_S)
            err = sink.stderr.read()
        finally:
            if sink.poll() is None:
                sink.kill()
                sink.wait(BOUND_S)
            if not select.select([bus_fd], [], [], 0)[0]:
                signal.pidfd_send_signal(bus_fd, signal.SIGKILL)
            os.close(bus_fd)
    if rc != 1 or "Traceback" in err or "session bus closed" not in err:
        return [f"the sink's session bus closing: want rc 1 and a 'session bus closed' line, no traceback; got rc {rc}, "
                f"stderr {err.strip()[-400:]!r}"]
    return []


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("notify-sink-bus-closed:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
