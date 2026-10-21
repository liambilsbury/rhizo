#!/usr/bin/env python3
import ctypes
import json
import os
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from desk_hello import android_hello, send  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
DESKD = os.path.join(ROOT, "src", "services", "deskbridge", "deskd.py")
RELAY = os.path.join(ROOT, "src", "services", "deskbridge", "desk-notify.py")
SINK = os.path.join(ROOT, "test", "system", "guest", "notify-sink.py")
DESKD_UNIT = os.path.join(ROOT, "src", "services", "deskbridge", "deskd.service")
NOTIFY_PATH_UNIT = os.path.join(ROOT, "src", "services", "deskbridge", "desk-notify.path")
TMPFILES = os.path.join(ROOT, "src", "services", "units", "session", "desktop-session.tmpfiles")
BOUND_S = 15
FAKE_WLBRIDGE = """#!/usr/bin/env python3
import sys
print("ready", flush=True)
for line in sys.stdin:
    if line.startswith("get "):
        print("nodata %s" % line.split(" ", 1)[1].strip(), flush=True)
"""


def wait_until(predicate):
    """return predicate's value once true or at the bound"""
    deadline = time.monotonic() + BOUND_S
    while True:
        value = predicate()
        if value or time.monotonic() > deadline:
            return value
        time.sleep(0.1)


def read(path):
    """return a file's text, empty when it is missing"""
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def start_deskd(tmp, port, wl, sock_path, log, env):
    """start rhizo-deskd writing to log"""
    with open(log, "w") as out:
        return subprocess.Popen([sys.executable, DESKD, "--port", str(port), "--token", "checktoken", "--bridge", wl,
                                 "--bind", "127.0.0.1", "--notify-socket", sock_path],
                                stdout=out, stderr=subprocess.STDOUT, env=env)


def notify(port, key, body):
    """send an android app notification through rhizo-deskd"""
    with socket.create_connection(("127.0.0.1", port), timeout=BOUND_S) as conn:
        stream, hello = android_hello(conn, "checktoken")
        if not hello or hello.get("t") != "hello_ok":
            return False
        send(stream, {"t": "notify", "key": key, "pkg": "com.example.poster", "title": key, "body": body})
    return True


IN_CREATE = 0x00000100
IN_MOVED_TO = 0x00000080
INOTIFY_EVENT = struct.Struct("iIII")


def dir_events(fd):
    """return the (mask, name) events queued on an inotify fd"""
    out = []
    while select.select([fd], [], [], 0)[0]:
        buf = os.read(fd, 65536)
        off = 0
        while off < len(buf):
            _wd, mask, _cookie, length = INOTIFY_EVENT.unpack_from(buf, off)
            name = buf[off + INOTIFY_EVENT.size:off + INOTIFY_EVENT.size + length].rstrip(b"\0").decode()
            out.append((mask, name))
            off += INOTIFY_EVENT.size + length
    return out


def restart_case(tmp, address, bodies):
    """return failures across a rhizo-deskd restart"""
    session_env = os.path.join(tmp, "session.env")
    open(session_env, "w").close()
    wl = os.path.join(tmp, "fake-wlbridge.py")
    with open(wl, "w") as f:
        f.write(FAKE_WLBRIDGE)
    os.chmod(wl, 0o755)
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    sockdir = os.path.join(tmp, "rhizo-desk-notify")
    os.mkdir(sockdir, 0o700)
    sock_path = os.path.join(sockdir, "notify.sock")
    env = dict(os.environ, RHIZO_DESKTOP_SESSION_ENV=session_env, RHIZO_POLICY_CONF=os.path.join(tmp, "none"))
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    logs = [os.path.join(tmp, "deskd-1.log"), os.path.join(tmp, "deskd-2.log")]
    relay_logs = [os.path.join(tmp, "relay-1.log"), os.path.join(tmp, "relay-2.log")]
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    inotify_fd = libc.inotify_init1(0o2000000)
    libc.inotify_add_watch(inotify_fd, sockdir.encode(), IN_CREATE | IN_MOVED_TO)
    deskd = relay = None
    bad = []
    try:
        deskd = start_deskd(tmp, port, wl, sock_path, logs[0], env)
        if not wait_until(lambda: "notification socket" in read(logs[0]) and os.path.exists(sock_path)):
            return ["the first rhizo-deskd bound no notification socket: %r" % read(logs[0])[-300:]]
        named = [(mask, name) for mask, name in dir_events(inotify_fd) if name == "notify.sock"]
        if not named or named[0][0] & IN_MOVED_TO == 0:
            bad.append("notify.sock first appeared by %r, want a rename of a listening socket (IN_MOVED_TO)" % named)
        relay = start_relay(sock_path, relay_logs[0], address)
        if not wait_until(lambda: "session bus attached" in read(logs[0])):
            return bad + ["the first rhizo-deskd never attached the relay: %r" % read(logs[0])[-300:]]
        deskd.send_signal(signal.SIGKILL)
        deskd.wait(BOUND_S)
        os.unlink(sock_path)
        try:
            rc = relay.wait(BOUND_S)
        except subprocess.TimeoutExpired:
            return bad + ["the relay kept running after rhizo-deskd died and its socket was removed"]
        if rc != 0:
            bad.append("the relay exited %d once the socket was removed, want 0: %r" % (rc, read(relay_logs[0])[-300:]))
        deskd = start_deskd(tmp, port, wl, sock_path, logs[1], env)
        if not wait_until(lambda: os.path.exists(sock_path)):
            return bad + ["the restarted rhizo-deskd bound no socket: %r" % read(logs[1])[-300:]]
        relay = start_relay(sock_path, relay_logs[1], address)
        if not wait_until(lambda: "session bus attached" in read(logs[1])):
            return bad + ["a relay started on the restarted rhizo-deskd's socket never attached: %r %r"
                          % (read(logs[1])[-300:], read(relay_logs[1])[-300:])]
        if not notify(port, "after-restart", "restart-nonce"):
            bad.append("the restarted rhizo-deskd refused the android app hello")
        if not wait_until(lambda: "restart-nonce" in bodies()):
            bad.append("the notification after the restart never reached the desktop: %r" % bodies())
        text = "".join(read(p) for p in logs + relay_logs)
        if "Traceback" in text:
            bad.append("a program raised: %r" % text[-400:])
        return bad
    finally:
        os.close(inotify_fd)
        for proc in (relay, deskd):
            if proc is not None and proc.poll() is None:
                proc.terminate()
                proc.wait(BOUND_S)


def start_relay(sock_path, log, address):
    """start rhizo-desk-notify writing to log"""
    with open(log, "w") as out:
        return subprocess.Popen([sys.executable, RELAY, "--socket", sock_path], stdout=out, stderr=subprocess.STDOUT,
                                env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address))


def unit_values(path, key):
    """return a unit file's values for a key"""
    out = []
    for line in read(path).replace("\\\n", " ").splitlines():
        line = line.strip()
        if line.startswith(key + "="):
            out.append(line[len(key) + 1:])
    return out


def units_keep_socket_dir():
    """return failures for where the units put the socket"""
    exec_start = " ".join(unit_values(DESKD_UNIT, "ExecStart")).split()
    if "--notify-socket" not in exec_start:
        return ["rhizo-deskd.service names no --notify-socket"]
    sock = exec_start[exec_start.index("--notify-socket") + 1]
    bad = []
    dirs = [line.split()[1] for line in read(TMPFILES).splitlines() if line.startswith("d ")]
    if os.path.dirname(sock) not in dirs:
        bad.append("%s's directory is not one rhizo-desktop-session.tmpfiles makes at boot (%s)" % (sock, dirs))
    if "/usr/bin/rm -f " + sock not in unit_values(DESKD_UNIT, "ExecStopPost"):
        bad.append("rhizo-deskd.service does not remove %s when it stops (ExecStopPost)" % sock)
    if unit_values(NOTIFY_PATH_UNIT, "PathExists") != [sock]:
        bad.append("rhizo-desk-notify.path watches %r, not %s" % (unit_values(NOTIFY_PATH_UNIT, "PathExists"), sock))
    return bad


def main():
    """return the failures"""
    if shutil.which("dbus-daemon") is None:
        return ["no dbus-daemon on this host"]
    bad = units_keep_socket_dir()
    with tempfile.TemporaryDirectory() as tmp:
        out = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"],
                             capture_output=True, text=True, timeout=BOUND_S)
        address, pid = out.stdout.split("\n")[:2]
        bus_fd = os.pidfd_open(int(pid))
        record = os.path.join(tmp, "record.jsonl")
        os.mkdir(os.path.join(tmp, "icons"))
        sink = subprocess.Popen([sys.executable, SINK, "--record", record, "--icon-dir", os.path.join(tmp, "icons")],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address))
        sink.stdout.readline()
        try:
            bad += restart_case(tmp, address, lambda: [json.loads(line).get("body")
                                                       for line in read(record).splitlines()])
        finally:
            sink.stdin.close()
            sink.wait(BOUND_S)
            if not select.select([bus_fd], [], [], 0)[0]:
                signal.pidfd_send_signal(bus_fd, signal.SIGTERM)
                select.select([bus_fd], [], [], BOUND_S)
            os.close(bus_fd)
    return bad


if __name__ == "__main__":
    failures = main()
    for failure in failures:
        print("FAIL:", failure)
    print("deskd-restart-relay:", "FAIL" if failures else "ok")
    sys.exit(1 if failures else 0)
