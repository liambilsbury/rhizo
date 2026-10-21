#!/usr/bin/env python3
import importlib.util
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
    """load deskd as a module with logging silenced"""
    spec = importlib.util.spec_from_file_location("deskd_control_rearm_under_test", DESKD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.log = lambda msg: None
    return module


def append(path, text):
    """append text to a file"""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)


def authenticated(d, deskd):
    """run promote_pending on a fake connection"""
    conn_r, conn_w = os.pipe()
    deskd.pending = conn_r
    deskd.sel.register(conn_r, selectors.EVENT_READ, None)
    deskd.android = None
    deskd.to_android = lambda msg: None
    deskd.rearm_dragwatch = lambda: None
    d.LineReader = lambda size: None
    d.OutQueue = lambda: None
    deskd.promote_pending()
    deskd.sel.unregister(conn_r)
    os.close(conn_r)
    os.close(conn_w)


def drops_read(d, deskd, payload, line):
    """write a drop and return the new lines"""
    append(os.path.join(d.CONTROL_DIR, payload), "x")
    append(d.CONTROL_OUT, line + "\n")
    got = []
    for key, _mask in deskd.sel.select(0.5):
        if key.fileobj == deskd.control.fileno():
            got += deskd.control.new_lines()
    return got


def run(d, tmp):
    """run the control watch re-arm cases"""
    d.CONTROL_DIR = os.path.join(tmp, "data", "rhizo_control")
    d.CONTROL_OUT = os.path.join(d.CONTROL_DIR, "control.out")
    deskd = d.Deskd.__new__(d.Deskd)
    deskd.sel = selectors.DefaultSelector()
    deskd.connect_control()
    check("a control directory missing at start leaves the watch unarmed", not deskd.control.armed)

    os.makedirs(d.CONTROL_DIR)
    append(d.CONTROL_OUT, "display powered id=2\n")
    authenticated(d, deskd)
    line = "drop id=3 port=2 x=640 y=384 mime=text/plain path=/data/rhizo_control/drop-3-1"
    got = drops_read(d, deskd, "drop-3-1", line)
    check("the android app's authentication arms the watch, and a drop after it is read",
          deskd.control.armed and line in got, "armed=%s read=%r" % (deskd.control.armed, got))

    os.rename(os.path.join(tmp, "data"), os.path.join(tmp, "data-old"))
    os.makedirs(d.CONTROL_DIR)
    authenticated(d, deskd)
    line = "drop id=4 port=2 x=10 y=20 mime=text/plain path=/data/rhizo_control/drop-4-1"
    got = drops_read(d, deskd, "drop-4-1", line)
    check("a remounted /data's new control directory is watched at the next authentication",
          line in got, "read=%r" % (got,))

    for name in os.listdir(d.CONTROL_DIR):
        os.unlink(os.path.join(d.CONTROL_DIR, name))
    os.rmdir(d.CONTROL_DIR)
    os.makedirs(d.CONTROL_DIR)
    st = os.stat(d.CONTROL_DIR)
    deskd.control.dir_id = (st.st_dev, st.st_ino)
    for key, _mask in deskd.sel.select(0.5):
        if key.fileobj == deskd.control.fileno():
            deskd.control.new_lines()
    authenticated(d, deskd)
    line = "drop id=5 port=2 x=30 y=40 mime=text/plain path=/data/rhizo_control/drop-5-1"
    got = drops_read(d, deskd, "drop-5-1", line)
    check("a control directory back with the old identity is watched again at the next authentication",
          line in got, "armed=%s read=%r" % (deskd.control.armed, got))


def main():
    """run the check against a loaded deskd"""
    d = load()
    with tempfile.TemporaryDirectory() as tmp:
        try:
            run(d, tmp)
        except AttributeError as exc:
            check("deskd re-arms its control watch", False, str(exc))
    if failures:
        print("%d check(s) failed" % len(failures))
        sys.exit(1)
    print("rhizo-deskd's control watch follows the sandbox's /data")


if __name__ == "__main__":
    main()
