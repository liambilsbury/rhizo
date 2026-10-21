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
BOUND_S = 30
FLOOD_BODY = "漢" * 180000
FLOODS = 6
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


def main():
    """return the failures"""
    if shutil.which("dbus-daemon") is None:
        return ["no dbus-daemon on this host"]
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
        wl = os.path.join(tmp, "fake-wlbridge.py")
        with open(wl, "w") as f:
            f.write(FAKE_WLBRIDGE)
        os.chmod(wl, 0o755)
        session_env = os.path.join(tmp, "session.env")
        open(session_env, "w").close()
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        sock_path = os.path.join(tmp, "notify.sock")
        log, relay_log = os.path.join(tmp, "deskd.log"), os.path.join(tmp, "relay.log")
        env = dict(os.environ, RHIZO_DESKTOP_SESSION_ENV=session_env, RHIZO_POLICY_CONF=os.path.join(tmp, "none"))
        env.pop("DBUS_SESSION_BUS_ADDRESS", None)
        deskd = relay = None
        try:
            with open(log, "w") as f:
                deskd = subprocess.Popen([sys.executable, DESKD, "--port", str(port), "--token", "checktoken",
                                          "--bridge", wl, "--bind", "127.0.0.1", "--notify-socket", sock_path],
                                         stdout=f, stderr=subprocess.STDOUT, env=env)
            wait_until(lambda: "notification socket" in read(log) or deskd.poll() is not None)
            with open(relay_log, "w") as f:
                relay = subprocess.Popen([sys.executable, RELAY, "--socket", sock_path], stdout=f,
                                         stderr=subprocess.STDOUT, env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=address))
            if not wait_until(lambda: "session bus attached" in read(log)):
                return [f"rhizo-deskd never attached the relay: {read(log)[-400:]!r} {read(relay_log)[-300:]!r}"]
            with socket.create_connection(("127.0.0.1", port), timeout=BOUND_S) as conn:
                stream, hello = android_hello(conn, "checktoken")
                if not hello or hello.get("t") != "hello_ok":
                    return [f"rhizo-deskd refused the android app hello: {hello!r}"]
                for i in range(FLOODS):
                    send(stream, {"t": "notify", "key": "flood-%d" % i, "pkg": "com.example.flood",
                                  "title": "flood %d" % i, "body": FLOOD_BODY})
                send(stream, {"t": "notify", "key": "after", "pkg": "com.example.flood", "title": "after the flood",
                              "body": "after-nonce"})
                records = wait_until(lambda: len(read(record).splitlines()) >= FLOODS + 1 and
                                     [json.loads(line) for line in read(record).splitlines()])
            bad = []
            bodies = [r.get("body", "") for r in records or []]
            floods = [b for b in bodies if b.startswith("漢")]
            if len(floods) != FLOODS or any(len(b) > 8192 or not b.endswith("…") for b in floods):
                bad.append(f"want {FLOODS} flood bodies cut under 8192 characters and ending in the truncation marker; "
                           f"got lengths {[len(b) for b in floods]}, endings {[b[-2:] for b in floods]!r}")
            if "after-nonce" not in bodies:
                bad.append(f"the plain notification after the flood never arrived; sink holds {len(bodies)} records")
            if relay.poll() is not None:
                bad.append(f"rhizo-desk-notify exited {relay.returncode} during the flood: {read(relay_log)[-400:]!r}")
            if deskd.poll() is not None or "Traceback" in read(log) + read(relay_log):
                bad.append(f"rhizo-deskd exited ({deskd.poll()}) or a program raised: {read(log)[-400:]!r} "
                           f"{read(relay_log)[-300:]!r}")
            return bad
        finally:
            for proc in (relay, deskd):
                if proc is not None and proc.poll() is None:
                    proc.terminate()
                    proc.wait(BOUND_S)
            sink.stdin.close()
            sink.wait(BOUND_S)
            if not select.select([bus_fd], [], [], 0)[0]:
                signal.pidfd_send_signal(bus_fd, signal.SIGTERM)
                select.select([bus_fd], [], [], BOUND_S)
            os.close(bus_fd)


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("deskd-notify-flood:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
