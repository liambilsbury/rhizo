#!/usr/bin/env python3
import json
import os
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
RELAY = os.path.join(ROOT, "src", "services", "deskbridge", "desk-notify.py")
SINK = os.path.join(ROOT, "test", "system", "guest", "notify-sink.py")
BOUND_S = 15
GOOD = {"t": "notify", "key": "k-good", "replaces": 0, "title": "good", "body": "good-nonce",
        "actions": ["default", "Open"], "hints": {}}
BAD = [
    ("oversized", b'{"t":"notify","key":"k-big","title":"' + b"x" * (2 << 20) + b'"}\n', ""),
    ("nested", b"[" * 200000 + b"\n", ""),
    ("title not a string", json.dumps(dict(GOOD, key="k-int", title=5)).encode() + b"\n", "k-int"),
    ("lone surrogate", json.dumps(dict(GOOD, key="k-sur", title="\ud800")).encode() + b"\n", "k-sur"),
    ("NUL in a body", json.dumps(dict(GOOD, key="k-nul", body="a\x00b")).encode() + b"\n", "k-nul"),
    ("close id not a uint32", b'{"t":"close","id":"x"}\n', ""),
]


def read_lines(conn, buf, count):
    """return count JSON lines read from conn"""
    out = []
    while len(out) < count:
        if b"\n" not in buf:
            if not select.select([conn], [], [], BOUND_S)[0]:
                break
            data = conn.recv(65536)
            if not data:
                break
            buf += data
            continue
        line, _, rest = bytes(buf).partition(b"\n")
        buf[:] = rest
        out.append(json.loads(line))
    return out


def bad_lines(tmp, address):
    """return failures for the malformed requests"""
    path = os.path.join(tmp, "notify.sock")
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(1)
    log = os.path.join(tmp, "relay.log")
    with open(log, "w") as out:
        relay = subprocess.Popen([sys.executable, RELAY, "--socket", path], stdout=out, stderr=subprocess.STDOUT,
                                 env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address))
    try:
        if not select.select([listener], [], [], BOUND_S)[0]:
            return ["rhizo-desk-notify never connected: %r" % open(log).read()[-300:]]
        conn, _ = listener.accept()
        buf = bytearray()
        hello = read_lines(conn, buf, 1)
        if not hello or hello[0].get("t") != "hello":
            return ["rhizo-desk-notify sent %r, want a hello" % hello]
        bad = []
        for name, line, key in BAD:
            try:
                conn.sendall(line)
            except OSError as exc:
                relay.wait(BOUND_S)
                return bad + ["%s request: the connection broke (%s), rhizo-desk-notify exited %s: %r"
                              % (name, exc, relay.returncode, open(log).read()[-300:])]
            reply = read_lines(conn, buf, 1)
            if not reply or reply[0].get("t") != "notify_failed" or reply[0].get("key") != key:
                bad.append("%s request: want notify_failed for key %r, got %r" % (name, key, reply))
            if relay.poll() is not None:
                bad.append("%s request: rhizo-desk-notify exited %d: %r" % (name, relay.returncode,
                                                                            open(log).read()[-300:]))
                return bad
        conn.sendall(json.dumps(GOOD).encode() + b"\n")
        reply = read_lines(conn, buf, 1)
        if not reply or reply[0].get("t") != "notified" or reply[0].get("key") != "k-good":
            bad.append("the good notification after the bad ones got %r, want notified" % reply)
        if "Traceback" in open(log).read():
            bad.append("rhizo-desk-notify raised: %r" % open(log).read()[-400:])
        conn.close()
        return bad
    finally:
        if relay.poll() is None:
            relay.terminate()
            relay.wait(BOUND_S)
        listener.close()


def unwatchable(tmp, address):
    """return failures for a socket directory inotify cannot watch"""
    if os.geteuid() == 0:
        return []
    locked = os.path.join(tmp, "locked")
    os.mkdir(locked, 0o000)
    try:
        out = subprocess.run([sys.executable, RELAY, "--socket", os.path.join(locked, "notify.sock")],
                             capture_output=True, text=True, timeout=BOUND_S,
                             env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address))
    except subprocess.TimeoutExpired:
        return ["rhizo-desk-notify kept running on a directory it cannot watch"]
    finally:
        os.chmod(locked, 0o700)
    if out.returncode != 1 or "cannot watch" not in out.stderr:
        return ["unwatchable directory: want exit 1 naming the watch, got %d %r" % (out.returncode, out.stderr[-300:])]
    return []


def main():
    """return the failures"""
    if shutil.which("dbus-daemon") is None:
        return ["no dbus-daemon on this host"]
    with tempfile.TemporaryDirectory() as tmp:
        out = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"],
                             capture_output=True, text=True, timeout=BOUND_S)
        address, pid = out.stdout.split("\n")[:2]
        bus_fd = os.pidfd_open(int(pid))
        os.mkdir(os.path.join(tmp, "icons"))
        sink = subprocess.Popen([sys.executable, SINK, "--record", os.path.join(tmp, "record.jsonl"), "--icon-dir",
                                 os.path.join(tmp, "icons")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address))
        sink.stdout.readline()
        try:
            return bad_lines(tmp, address) + unwatchable(tmp, address)
        finally:
            sink.stdin.close()
            sink.wait(BOUND_S)
            if not select.select([bus_fd], [], [], 0)[0]:
                signal.pidfd_send_signal(bus_fd, signal.SIGTERM)
                select.select([bus_fd], [], [], BOUND_S)
            os.close(bus_fd)


if __name__ == "__main__":
    failures = main()
    for failure in failures:
        print("FAIL:", failure)
    print("desk-notify-bad-lines:", "FAIL" if failures else "ok")
    sys.exit(1 if failures else 0)
