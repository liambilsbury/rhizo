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
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from desk_hello import android_hello, send  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
DESKD = os.path.join(ROOT, "src", "services", "deskbridge", "deskd.py")
RELAY = os.path.join(ROOT, "src", "services", "deskbridge", "desk-notify.py")
SINK = os.path.join(ROOT, "test", "system", "guest", "notify-sink.py")
BOUND_S = 15
FAKE_WLBRIDGE = """#!/usr/bin/env python3
import os
import sys
with open(os.environ["FAKE_WL_STARTS"], "a") as f:
    f.write("%d %s\\n" % (os.getpid(), os.environ.get("WAYLAND_DISPLAY")))
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
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return ""


class Bus:
    """session dbus-daemon with a notification sink"""

    def __init__(self, tmp, name):
        """start the dbus-daemon and the sink"""
        out = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"],
                             capture_output=True, text=True, timeout=BOUND_S)
        self.address, pid = out.stdout.split("\n")[:2]
        self.pidfd = os.pidfd_open(int(pid))
        self.record = os.path.join(tmp, name + ".jsonl")
        os.mkdir(os.path.join(tmp, name + "-icons"))
        self.sink = subprocess.Popen([sys.executable, SINK, "--record", self.record, "--icon-dir",
                                      os.path.join(tmp, name + "-icons")],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=self.address), text=True)
        self.sink_ready = self.sink.stdout.readline().strip() == "ready"

    def stop(self):
        """stop the sink and the dbus-daemon"""
        if self.sink.poll() is None:
            self.sink.stdin.close()
            self.sink.wait(BOUND_S)
        if self.pidfd >= 0:
            if not select.select([self.pidfd], [], [], 0)[0]:
                signal.pidfd_send_signal(self.pidfd, signal.SIGTERM)
                select.select([self.pidfd], [], [], BOUND_S)
            os.close(self.pidfd)
            self.pidfd = -1


class FakeBus:
    """listener answering SASL with a reply"""

    def __init__(self, tmp, name, reply):
        """listen on a socket in tmp"""
        path = os.path.join(tmp, name)
        self.address = "unix:path=" + path
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(4)
        self.conns = []
        self.reply = reply
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        """answer each connection's auth line with the reply"""
        while True:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            self.conns.append(conn)
            buf = b""
            while not buf.endswith(b"\r\n"):
                chunk = conn.recv(256)
                if not chunk:
                    break
                buf += chunk
            if self.reply is not None:
                conn.sendall(self.reply)

    def stop(self):
        """close the listener and its connections"""
        self.srv.close()
        for conn in self.conns:
            conn.close()


class Rig:
    """deskd under a fake desktop session"""

    def __init__(self, tmp):
        """lay out the session.env, bridge and log paths"""
        self.session_env = os.path.join(tmp, "session.env")
        self.starts = os.path.join(tmp, "wl-starts")
        self.wl = os.path.join(tmp, "fake-wlbridge.py")
        with open(self.wl, "w") as f:
            f.write(FAKE_WLBRIDGE)
        os.chmod(self.wl, 0o755)
        self.log_path = os.path.join(tmp, "deskd.log")
        self.policy = os.path.join(tmp, "no-policy.conf")
        self.socket = os.path.join(tmp, "notify.sock")
        self.tmp = tmp
        self.deskd = None
        self.port = None
        self.relays = []

    def log(self):
        """return rhizo-deskd's log"""
        return read(self.log_path)

    def wl_starts(self):
        """return the pid and WAYLAND_DISPLAY of each wlbridge start"""
        return [line.split(" ", 1) for line in read(self.starts).splitlines()]

    def write(self, address, display):
        """write session.env the way rhizo-desktop-session.service does"""
        with open(self.session_env + ".tmp", "w") as f:
            f.write("XDG_RUNTIME_DIR=%s\nWAYLAND_DISPLAY=%s\nDBUS_SESSION_BUS_ADDRESS=%s\n"
                    % (os.path.dirname(self.session_env), display, address))
        os.rename(self.session_env + ".tmp", self.session_env)

    def relay(self, bus):
        """start rhizo-desk-notify on bus"""
        log = os.path.join(self.tmp, "relay-%d.log" % len(self.relays))
        with open(log, "w") as out:
            proc = subprocess.Popen([sys.executable, RELAY, "--socket", self.socket], stdout=out,
                                    stderr=subprocess.STDOUT, env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=bus.address))
        self.relays.append((proc, log))
        return proc, log

    def start(self, bus):
        """start rhizo-deskd and a relay on bus in wayland-1"""
        self.write(bus.address, "wayland-1")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        env = dict(os.environ, WAYLAND_DISPLAY="wayland-1", RHIZO_DESKTOP_SESSION_ENV=self.session_env,
                   FAKE_WL_STARTS=self.starts, RHIZO_POLICY_CONF=self.policy)
        env.pop("DBUS_SESSION_BUS_ADDRESS", None)
        with open(self.log_path, "w") as out:
            self.deskd = subprocess.Popen([sys.executable, DESKD, "--port", str(self.port), "--token", "checktoken",
                                           "--bridge", self.wl, "--bind", "127.0.0.1", "--notify-socket", self.socket],
                                          stdout=out, stderr=subprocess.STDOUT, env=env)
        if not wait_until(lambda: "notification socket" in self.log()):
            return False
        self.relay(bus)
        return wait_until(lambda: "session bus attached" in self.log() and len(self.wl_starts()) == 1)

    def wait_log(self, *markers):
        """wait for every marker in the log or rhizo-deskd's exit"""
        return wait_until(lambda: all(m in self.log() for m in markers) or self.deskd.poll() is not None)

    def end_session(self, bus):
        """stop the bus and the newest rhizo-wlbridge"""
        bus.stop()
        os.kill(int(self.wl_starts()[-1][0]), signal.SIGTERM)

    def alive(self, what):
        """return the failure when rhizo-deskd exited or either program raised"""
        raised = [log for _proc, log in self.relays if "Traceback" in read(log)]
        if self.deskd.poll() is not None or "Traceback" in self.log() or raised:
            return [f"{what}: rhizo-deskd exited or raised, returncode {self.deskd.poll()}, "
                    f"log tail {self.log().strip()[-500:]!r}, relay tracebacks "
                    f"{[read(log)[-300:] for log in raised]!r}"]
        return []

    def delivers(self, what, bus):
        """return the failure when a notification misses bus"""
        with socket.create_connection(("127.0.0.1", self.port), timeout=BOUND_S) as sock:
            stream, hello = android_hello(sock, "checktoken")
            if not hello or hello.get("t") != "hello_ok":
                return [f"{what}: rhizo-deskd refused the android app hello: {hello!r}"]
            send(stream, {"t": "notify", "key": "k1", "pkg": "com.example.poster",
                          "title": "after the new session", "body": "reattach-nonce"})
            records = wait_until(lambda: [json.loads(line) for line in read(bus.record).splitlines()])
        if [r.get("body") for r in records or []] != ["reattach-nonce"]:
            return [f"{what}: the notification never reached the new session bus: records {records!r}"]
        return []

    def stop(self):
        """stop rhizo-deskd and the relays"""
        for proc, _log in self.relays:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(BOUND_S)
        if self.deskd is not None and self.deskd.poll() is None:
            self.deskd.terminate()
            self.deskd.wait(BOUND_S)


def reattached(rig, what, bus, display):
    """return the failures of a reattach to bus and display"""
    bad = []
    if not wait_until(lambda: rig.log().count("session bus attached") == 2):
        bad.append(f"{what}: rhizo-deskd did not attach the new session bus {bus.address}")
    if not wait_until(lambda: [s[1] for s in rig.wl_starts()] == ["wayland-1", display]):
        bad.append(f"{what}: rhizo-deskd did not start rhizo-wlbridge in WAYLAND_DISPLAY={display}: "
                   f"starts {rig.wl_starts()}")
    if not bad:
        bad += rig.delivers(what, bus)
    bad += rig.alive(what)
    return bad + ([f"{what}: log tail {rig.log().strip()[-600:]!r}"] if bad else [])


def end_then_write(tmp, rig, made):
    """end the session, then write the new one"""
    bus1 = made(Bus(tmp, "b1"))
    if not rig.start(bus1):
        return [f"end then write: rhizo-deskd never attached its first session: {rig.log()[-400:]!r}"]
    rig.end_session(bus1)
    os.unlink(rig.session_env)
    if not rig.wait_log("session bus closed", "rhizo-wlbridge exited"):
        return [f"end then write: rhizo-deskd never saw the first session end: {rig.log()[-400:]!r}"]
    bus2 = made(Bus(tmp, "b2"))
    rig.relay(bus2)
    if not rig.wait_log("waits for"):
        return [f"end then write: rhizo-deskd did not hold the new relay for session.env: {rig.log()[-400:]!r}"]
    rig.write(bus2.address, "wayland-2")
    return reattached(rig, "end then write", bus2, "wayland-2")


def write_then_end(tmp, rig, made):
    """write the new session, then end the old one"""
    bus1 = made(Bus(tmp, "b1"))
    if not rig.start(bus1):
        return [f"write then end: rhizo-deskd never attached its first session: {rig.log()[-400:]!r}"]
    bus2 = made(Bus(tmp, "b2"))
    rig.write(bus2.address, "wayland-2")
    if not rig.wait_log("desktop session written"):
        return [f"write then end: rhizo-deskd never read the new session.env: {rig.log()[-400:]!r}"]
    first, _log = rig.relays[0]
    rig.relay(bus2)
    if wait_until(lambda: first.poll() is not None) and first.returncode != 3:
        return [f"write then end: the replaced relay exited {first.returncode}, want 3 (refused)"]
    rig.end_session(bus1)
    return reattached(rig, "write then end", bus2, "wayland-2")


def refused_bus(reply, what):
    """return a case whose new bus answers SASL with reply"""
    def case(tmp, rig, made):
        """end the session, write a refusing bus, then a live one"""
        bus1 = made(Bus(tmp, "b1"))
        if not rig.start(bus1):
            return [f"{what}: rhizo-deskd never attached its first session: {rig.log()[-400:]!r}"]
        rig.end_session(bus1)
        if not rig.wait_log("session bus closed", "rhizo-wlbridge exited"):
            return [f"{what}: rhizo-deskd never saw the first session end: {rig.log()[-400:]!r}"]
        fake = made(FakeBus(tmp, "fake-bus", reply))
        proc, log = rig.relay(fake)
        proc.wait(BOUND_S)
        if proc.returncode != 1 or "not attached" not in read(log):
            return [f"{what}: the relay on the refusing bus exited {proc.returncode}, want 1 and a 'not attached' "
                    f"line: {read(log)[-400:]!r}"]
        bad = rig.alive(f"{what}, at the refusing bus")
        if bad:
            return bad
        bus3 = made(Bus(tmp, "b3"))
        rig.relay(bus3)
        rig.write(bus3.address, "wayland-2")
        if not wait_until(lambda: rig.log().count("session bus attached") == 2):
            return [f"{what}: the next session.env write did not attach {bus3.address}: {rig.log()[-500:]!r}"]
        return rig.delivers(what, bus3) + rig.alive(what)
    return case


def wlbridge_unstartable(tmp, rig, made):
    """end the session with rhizo-wlbridge unexecutable, then fix it"""
    bus1 = made(Bus(tmp, "b1"))
    if not rig.start(bus1):
        return [f"wlbridge unstartable: rhizo-deskd never attached its first session: {rig.log()[-400:]!r}"]
    rig.end_session(bus1)
    if not rig.wait_log("session bus closed", "rhizo-wlbridge exited"):
        return [f"wlbridge unstartable: rhizo-deskd never saw the first session end: {rig.log()[-400:]!r}"]
    os.chmod(rig.wl, 0o644)
    bus2 = made(Bus(tmp, "b2"))
    rig.relay(bus2)
    rig.write(bus2.address, "wayland-2")
    rig.wait_log("rhizo-wlbridge did not start")
    bad = rig.alive("wlbridge unstartable, at the failed start")
    if bad:
        return bad
    os.chmod(rig.wl, 0o755)
    rig.write(bus2.address, "wayland-3")
    if not wait_until(lambda: [s[1] for s in rig.wl_starts()] == ["wayland-1", "wayland-3"]):
        return [f"wlbridge unstartable: the next session.env write did not start rhizo-wlbridge: "
                f"starts {rig.wl_starts()}, log {rig.log()[-500:]!r}"]
    return rig.delivers("wlbridge unstartable", bus2) + rig.alive("wlbridge unstartable")


CASES = (end_then_write, write_then_end, refused_bus(None, "stalled bus"),
         refused_bus(b"REJECTED EXTERNAL\r\n", "rejected bus"), wlbridge_unstartable)


def main():
    """return the failures"""
    if shutil.which("dbus-daemon") is None:
        return ["no dbus-daemon on this host"]
    bad = []
    for case in CASES:
        with tempfile.TemporaryDirectory() as tmp:
            rig = Rig(tmp)
            made = []
            try:
                bad += case(tmp, rig, lambda thing: made.append(thing) or thing)
            finally:
                rig.stop()
                for thing in made:
                    thing.stop()
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("deskd-session-reattach:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
