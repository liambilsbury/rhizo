#!/usr/bin/env python3
import importlib.util
import os
import selectors
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
DESKD = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.normpath(os.path.join(HERE, "..", "deskd.py")))
EVENT_BOUND = 15

failures = []


def check(name, ok, detail=""):
    """print and record the result of a named check"""
    print(("ok   %s" if ok else "FAIL %s") % name + ("" if ok else ": " + detail))
    if not ok:
        failures.append(name)


class Log:
    """captured rhizo-deskd log lines"""

    def __init__(self):
        """start with no logged lines"""
        self.lines = []
        self.lock = threading.Lock()
        self.cv = threading.Condition(self.lock)

    def __call__(self, msg):
        """record a logged line and wake waiters"""
        with self.cv:
            self.lines.append(msg)
            self.cv.notify_all()

    def wait_for(self, prefix):
        """wait for logged lines with a prefix and return them"""
        with self.cv:
            self.cv.wait_for(lambda: any(l.startswith(prefix) for l in self.lines), EVENT_BOUND)
            return [l for l in self.lines if l.startswith(prefix)]


def load(log):
    """load deskd as a module with the given logger"""
    spec = importlib.util.spec_from_file_location("deskd_wlbridge_reap_under_test", DESKD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = log
    return module


def deskd_on(d, stub):
    """build a deskd around a wlbridge started from a stub"""
    deskd = d.Deskd.__new__(d.Deskd)
    deskd.sel = selectors.DefaultSelector()
    deskd.wl = d.WlBridge(stub, set())
    deskd.sel.register(deskd.wl.fileno(), selectors.EVENT_READ, deskd.on_wl)
    deskd.wl_write_armed = False
    deskd.wl_dead = False
    deskd.session_writes = 0
    deskd.wl_session_write = 0
    deskd.relay = None
    deskd.wl_clipboard = True
    deskd.init_clip_state()
    deskd.android = None
    deskd.openers = []
    deskd.pending = None
    deskd.pending_deadline = None
    deskd.pending_up = None
    deskd.pad_press = None
    threading.Thread(target=deskd.run, daemon=True).start()
    return deskd


def stub(tmp, name, body):
    """write an executable shell stub"""
    path = os.path.join(tmp, name)
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)
    return path


def main():
    """run the rhizo-wlbridge reap cases"""
    tmp = tempfile.mkdtemp(prefix="deskd-wlreap-")

    log = Log()
    d = load(log)
    deskd = deskd_on(d, stub(tmp, "exits", "echo ready\nexit 5\n"))
    pid = deskd.wl.proc.pid
    reaped = log.wait_for("rhizo-wlbridge reaped")
    check("a bridge that exits outright is reaped and its rc logged",
          reaped == ["rhizo-wlbridge reaped: rc=5"] and not os.path.exists("/proc/%d" % pid),
          "reap lines %r, /proc/%d %s" % (reaped, pid, "present" if os.path.exists("/proc/%d" % pid) else "gone"))

    log = Log()
    d = load(log)
    deskd = deskd_on(d, stub(tmp, "lingers", "echo ready\nexec 1>&-\nread line\nexit 3\n"))
    pid = deskd.wl.proc.pid
    eof = log.wait_for("rhizo-wlbridge exited")
    alive = os.path.exists("/proc/%d" % pid) and deskd.wl.proc.returncode is None
    check("the end of output reaches on_wl while that bridge still runs", bool(eof) and alive,
          "eof lines %r, returncode %r" % (eof, deskd.wl.proc.returncode))
    os.write(deskd.wl.infileno(), b"exit\n")
    reaped = log.wait_for("rhizo-wlbridge reaped")
    check("a bridge exiting after its end of output is reaped by a later loop pass, rc logged",
          reaped == ["rhizo-wlbridge reaped: rc=3"] and not os.path.exists("/proc/%d" % pid),
          "reap lines %r, /proc/%d %s" % (reaped, pid, "present" if os.path.exists("/proc/%d" % pid) else "gone"))

    log = Log()
    d = load(log)
    real_pidfd_open = os.pidfd_open

    def refused(_pid, _flags=0):
        """refuse pidfd_open with a permission error"""
        raise PermissionError(1, "Operation not permitted")
    os.pidfd_open = refused
    try:
        deskd = deskd_on(d, stub(tmp, "lingers2", "echo ready\nexec 1>&-\nread line\nexit 4\n"))
        pid = deskd.wl.proc.pid
        fallback = log.wait_for("rhizo-wlbridge exit not watchable by pidfd")
        os.write(deskd.wl.infileno(), b"exit\n")
        reaped = log.wait_for("rhizo-wlbridge reaped")
    finally:
        os.pidfd_open = real_pidfd_open
    check("with pidfd_open refused, a later pass re-polls and reaps the bridge, rc logged",
          bool(fallback) and reaped == ["rhizo-wlbridge reaped: rc=4"] and not os.path.exists("/proc/%d" % pid),
          "fallback lines %r, reap lines %r, /proc/%d %s" % (
              fallback, reaped, pid, "present" if os.path.exists("/proc/%d" % pid) else "gone"))

    for f in os.listdir(tmp):
        os.unlink(os.path.join(tmp, f))
    os.rmdir(tmp)
    if failures:
        print("%d failure(s)" % len(failures))
        return 1
    print("all 4 passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
