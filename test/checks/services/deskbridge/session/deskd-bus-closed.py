#!/usr/bin/env python3
import os
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
DESKD = os.path.join(ROOT, "src", "services", "deskbridge", "deskd.py")
RELAY = os.path.join(ROOT, "src", "services", "deskbridge", "desk-notify.py")
BOUND_S = 15
FAKE_WLBRIDGE = """#!/usr/bin/env python3
import sys
print("ready", flush=True)
for line in sys.stdin:
    if line.startswith("get "):
        print("nodata %s" % line.split(" ", 1)[1].strip(), flush=True)
"""


def free_port():
    """return a free loopback tcp port"""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def read_log_until(path, marker, proc):
    """return the log once it holds marker or proc exits"""
    deadline = time.monotonic() + BOUND_S
    while True:
        with open(path) as f:
            text = f.read()
        if marker in text or proc.poll() is not None or time.monotonic() > deadline:
            return text
        time.sleep(0.1)


def start_deskd(tmp, name):
    """start rhizo-deskd on a fresh port and notification socket"""
    wl = os.path.join(tmp, "fake-wlbridge.py")
    if not os.path.exists(wl):
        with open(wl, "w") as f:
            f.write(FAKE_WLBRIDGE)
        os.chmod(wl, 0o755)
    session_env = os.path.join(tmp, "session.env")
    open(session_env, "a").close()
    port = free_port()
    log = os.path.join(tmp, name + ".log")
    env = dict(os.environ, RHIZO_POLICY_CONF=os.path.join(tmp, "no-policy.conf"), RHIZO_DESKTOP_SESSION_ENV=session_env)
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    with open(log, "w") as out:
        proc = subprocess.Popen([sys.executable, DESKD, "--port", str(port), "--token", "checktoken", "--bridge", wl,
                                 "--bind", "127.0.0.1", "--notify-socket", os.path.join(tmp, name + ".sock")],
                                stdout=out, stderr=subprocess.STDOUT, env=env)
    read_log_until(log, "notification socket", proc)
    return proc, port, log


def start_relay(tmp, name, bus_address):
    """start rhizo-desk-notify on bus_address"""
    log = os.path.join(tmp, name + "-relay.log")
    with open(log, "w") as out:
        proc = subprocess.Popen([sys.executable, RELAY, "--socket", os.path.join(tmp, name + ".sock")], stdout=out,
                                stderr=subprocess.STDOUT, env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=bus_address))
    return proc, log


def relay_verdict(what, proc, log, want_rc, want_line):
    """return the failure for a relay's exit, or None"""
    try:
        proc.wait(BOUND_S)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(BOUND_S)
    with open(log) as f:
        text = f.read()
    if proc.returncode == want_rc and want_line in text and "Traceback" not in text:
        return None
    return (f"{what}: want rhizo-desk-notify to exit {want_rc} with {want_line!r} and no traceback; got "
            f"returncode {proc.returncode}, log tail {text.strip()[-400:]!r}")


def listener_accepts(port):
    """return whether the tcp port accepts a connection"""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=BOUND_S):
            return True
    except OSError:
        return False


def verdict(what, proc, port, text):
    """return the failure for a case, or None"""
    alive = proc.poll() is None
    accepts = alive and listener_accepts(port)
    if alive and accepts and "Traceback" not in text:
        return None
    return (f"{what}: want rhizo-deskd running, listening and no traceback; got returncode {proc.poll()}, "
            f"listener {'accepts' if accepts else 'closed'}, log tail {text.strip()[-400:]!r}")


def stop(proc):
    """stop rhizo-deskd and wait for it"""
    if proc.poll() is None:
        proc.terminate()
        proc.wait(BOUND_S)


def main():
    """return the failures"""
    if shutil.which("dbus-daemon") is None:
        return ["no dbus-daemon on this host"]
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        out = subprocess.run(["dbus-daemon", "--session", "--fork", "--print-address=1", "--print-pid=1"],
                             capture_output=True, text=True, timeout=BOUND_S)
        address, bus_pid = out.stdout.split("\n")[0], int(out.stdout.split("\n")[1])
        bus_fd = os.pidfd_open(bus_pid)
        proc, port, log = start_deskd(tmp, "closed")
        relay, relay_log = start_relay(tmp, "closed", address)
        try:
            text = read_log_until(log, "session bus attached", proc)
            if "session bus attached" not in text:
                bad.append(f"rhizo-deskd never attached the session bus: {text.strip()[-400:]!r}")
            else:
                signal.pidfd_send_signal(bus_fd, signal.SIGTERM)
                select.select([bus_fd], [], [], BOUND_S)
                text = read_log_until(log, "session bus closed", proc)
                for failure in (verdict("the session bus closing under a running rhizo-deskd", proc, port, text),
                                relay_verdict("the session bus closing", relay, relay_log, 0, "closed")):
                    if failure:
                        bad.append(failure)
        finally:
            if relay.poll() is None:
                relay.kill()
                relay.wait(BOUND_S)
            stop(proc)
            if not select.select([bus_fd], [], [], 0)[0]:
                signal.pidfd_send_signal(bus_fd, signal.SIGKILL)
            os.close(bus_fd)

        proc, port, log = start_deskd(tmp, "gone")
        relay, relay_log = start_relay(tmp, "gone", "unix:path=" + os.path.join(tmp, "gone-bus"))
        try:
            failure = relay_verdict("a session bus that is gone", relay, relay_log, 1, "not attached")
            if failure:
                bad.append(failure)
            with open(log) as f:
                text = f.read()
            failure = verdict("rhizo-deskd beside a relay whose session bus is gone", proc, port, text)
            if failure:
                bad.append(failure)
        finally:
            stop(proc)
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("deskd-bus-closed:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
