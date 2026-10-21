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
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from desk_hello import android_hello, send  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
DESKD = os.path.join(ROOT, "src", "services", "deskbridge", "deskd.py")
RELAY = os.path.join(ROOT, "src", "services", "deskbridge", "desk-notify.py")
SINK = os.path.join(ROOT, "test", "system", "guest", "notify-sink.py")
FOREIGN_FILE = "/etc/hostname"
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
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return ""


class Desk:
    """bus, sink, deskd and relay"""

    def __init__(self, tmp, session_env):
        """start a dbus-daemon with a sink and rhizo-deskd"""
        self.tmp = tmp
        out = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"],
                             capture_output=True, text=True, timeout=BOUND_S)
        self.address, pid = out.stdout.split("\n")[:2]
        self.pidfd = os.pidfd_open(int(pid))
        self.record = os.path.join(tmp, "record.jsonl")
        os.mkdir(os.path.join(tmp, "icons"))
        self.sink = subprocess.Popen([sys.executable, SINK, "--record", self.record, "--icon-dir",
                                      os.path.join(tmp, "icons")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True,
                                     env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=self.address))
        self.sink.stdout.readline()
        wl = os.path.join(tmp, "fake-wlbridge.py")
        with open(wl, "w") as f:
            f.write(FAKE_WLBRIDGE)
        os.chmod(wl, 0o755)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.socket = os.path.join(tmp, "notify.sock")
        self.log_path = os.path.join(tmp, "deskd.log")
        env = dict(os.environ, RHIZO_DESKTOP_SESSION_ENV=session_env, RHIZO_POLICY_CONF=os.path.join(tmp, "none"))
        env.pop("DBUS_SESSION_BUS_ADDRESS", None)
        with open(self.log_path, "w") as out:
            self.deskd = subprocess.Popen([sys.executable, DESKD, "--port", str(self.port), "--token", "checktoken",
                                           "--bridge", wl, "--bind", "127.0.0.1", "--notify-socket", self.socket],
                                          stdout=out, stderr=subprocess.STDOUT, env=env)
        self.bound = wait_until(lambda: "notification socket" in self.log() or self.deskd.poll() is not None)
        self.relay_log = os.path.join(tmp, "relay.log")
        self.relay = None

    def log(self):
        """return rhizo-deskd's log"""
        return read(self.log_path)

    def start_relay(self):
        """start rhizo-desk-notify on the bus"""
        with open(self.relay_log, "w") as out:
            self.relay = subprocess.Popen([sys.executable, RELAY, "--socket", self.socket], stdout=out,
                                          stderr=subprocess.STDOUT,
                                          env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=self.address))

    def notify(self, body):
        """send an android app notification through rhizo-deskd"""
        with socket.create_connection(("127.0.0.1", self.port), timeout=BOUND_S) as sock:
            stream, hello = android_hello(sock, "checktoken")
            if not hello or hello.get("t") != "hello_ok":
                return False
            send(stream, {"t": "notify", "key": "k1", "pkg": "com.example.poster", "title": "relay", "body": body})
            wait_until(lambda: "notification k1 ->" in self.log() or "dropped" in self.log())
        return True

    def records(self):
        """return the bodies the sink recorded"""
        return [json.loads(line).get("body") for line in read(self.record).splitlines()]

    def clean(self, what):
        """return the failure when a program exited early or raised"""
        if self.deskd.poll() is not None or "Traceback" in self.log() + read(self.relay_log):
            return [f"{what}: rhizo-deskd exited ({self.deskd.poll()}) or a program raised; deskd log "
                    f"{self.log()[-400:]!r}, relay log {read(self.relay_log)[-300:]!r}"]
        return []

    def stop(self):
        """stop every process"""
        for proc in (self.relay, self.deskd):
            if proc is not None and proc.poll() is None:
                proc.terminate()
                proc.wait(BOUND_S)
        self.sink.stdin.close()
        self.sink.wait(BOUND_S)
        if not select.select([self.pidfd], [], [], 0)[0]:
            signal.pidfd_send_signal(self.pidfd, signal.SIGTERM)
            select.select([self.pidfd], [], [], BOUND_S)
        os.close(self.pidfd)


def held_until_written(tmp):
    """return the failures of a relay that connects before session.env"""
    session_env = os.path.join(tmp, "session.env")
    desk = Desk(tmp, session_env)
    try:
        if "notification socket" not in desk.log():
            return [f"no session.env yet: rhizo-deskd bound no notification socket: {desk.log()[-400:]!r}"]
        desk.start_relay()
        if not wait_until(lambda: "waits for" in desk.log()):
            return [f"no session.env yet: rhizo-deskd did not hold the relay: {desk.log()[-400:]!r}"]
        if "session bus attached" in desk.log():
            return ["no session.env yet: rhizo-deskd attached the relay's bus before session.env named its owner"]
        with open(session_env + ".tmp", "w") as f:
            f.write("WAYLAND_DISPLAY=wayland-0\n")
        os.rename(session_env + ".tmp", session_env)
        if not wait_until(lambda: "session bus attached" in desk.log()):
            return [f"session.env written: rhizo-deskd did not admit the held relay: {desk.log()[-400:]!r}"]
        bad = [] if desk.notify("held-nonce") else ["session.env written: rhizo-deskd refused the android app hello"]
        if not wait_until(lambda: desk.records() == ["held-nonce"]):
            bad.append(f"session.env written: the notification never reached the bus: {desk.records()!r}, "
                       f"log {desk.log()[-400:]!r}")
        return bad + desk.clean("held relay")
    finally:
        desk.stop()


def foreign_owner(tmp):
    """return the failures of a relay whose uid does not own session.env"""
    if os.stat(FOREIGN_FILE).st_uid == os.getuid():
        return [f"{FOREIGN_FILE} is owned by this uid"]
    desk = Desk(tmp, FOREIGN_FILE)
    try:
        if "notification socket" not in desk.log():
            return [f"foreign owner: rhizo-deskd bound no notification socket: {desk.log()[-400:]!r}"]
        desk.start_relay()
        try:
            rc = desk.relay.wait(BOUND_S)
        except subprocess.TimeoutExpired:
            return [f"foreign owner: rhizo-desk-notify was not refused: {desk.log()[-400:]!r}"]
        bad = []
        if rc != 3 or "refused" not in read(desk.relay_log) or "refused" not in desk.log():
            bad.append(f"foreign owner: want the relay refused and exiting 3; got {rc}, deskd log "
                       f"{desk.log()[-300:]!r}, relay log {read(desk.relay_log)[-300:]!r}")
        if "session bus attached" in desk.log():
            bad.append("foreign owner: rhizo-deskd attached the bus of a relay from another uid")
        desk.notify("foreign-nonce")
        if desk.records():
            bad.append(f"foreign owner: a notification crossed: {desk.records()!r}")
        return bad + desk.clean("foreign owner")
    finally:
        desk.stop()


def main():
    """return the failures"""
    if shutil.which("dbus-daemon") is None:
        return ["no dbus-daemon on this host"]
    bad = []
    for case in (held_until_written, foreign_owner):
        with tempfile.TemporaryDirectory() as tmp:
            bad += case(tmp)
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("deskd-notify-relay:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
