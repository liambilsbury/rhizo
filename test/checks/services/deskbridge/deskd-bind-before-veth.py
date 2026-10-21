#!/usr/bin/env python3
import errno
import os
import selectors
import socket
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from desk_hello import android_hello  # noqa: E402

DESKD = os.environ.get(
    "RHIZO_DESKD_PATH", os.path.join(HERE, "..", "..", "..", "..", "src", "services", "deskbridge", "deskd.py"))
ADDR = "10.77.0.1"
TOKEN = "bindcheck-token"
NAME = "check-deskd-bind-before-veth"

FAKE_WLBRIDGE = """#!/usr/bin/env python3
import sys
print("ready", flush=True)
for line in sys.stdin:
    if line.strip() == "quit":
        break
"""


def say(msg):
    """print a message prefixed with the check name"""
    print("%s: %s" % (NAME, msg), flush=True)


def await_line(proc, want, bound_s):
    """read proc output for a matching line"""
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    buf = b""
    deadline = time.monotonic() + bound_s
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            return False, buf.decode("utf-8", "replace")
        if not sel.select(left):
            continue
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            return False, buf.decode("utf-8", "replace")
        buf += chunk
        if want.encode() in buf:
            return True, buf.decode("utf-8", "replace")


def inside():
    """check the bind fails until the namespace has the address"""
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind((ADDR, 0))
        say("FAIL: %s is already local in this namespace" % ADDR)
        return 1
    except OSError as exc:
        if exc.errno != errno.EADDRNOTAVAIL:
            say("FAIL: the control bind of %s failed with %r, not EADDRNOTAVAIL" % (ADDR, exc))
            return 1
    finally:
        probe.close()
    say("control: a plain bind of %s is refused EADDRNOTAVAIL before the address exists" % ADDR)

    work = tempfile.mkdtemp(prefix="rhizo-deskd-bind.")
    bridge = os.path.join(work, "fake-wlbridge.py")
    with open(bridge, "w") as f:
        f.write(FAKE_WLBRIDGE)
    os.chmod(bridge, 0o755)
    port = 47100
    env = dict(os.environ)
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    env["TMPDIR"] = work
    proc = subprocess.Popen(
        [sys.executable, DESKD, "--port", str(port), "--bind", ADDR, "--token", TOKEN,
         "--bridge", bridge],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
    try:
        want = "listening on %s:%d" % (ADDR, port)
        ok, text = await_line(proc, want, 30)
        if not ok:
            say("FAIL: rhizo-deskd never logged '%s' with its address not configured yet "
                "(exit status %r):\n%s" % (want, proc.poll(), text))
            return 1
        say("rhizo-deskd logged '%s' before %s existed" % (want, ADDR))

        subprocess.run(["ip", "addr", "add", ADDR + "/32", "dev", "lo"], check=True)
        sock = socket.create_connection((ADDR, port), timeout=10)
        _, reply = android_hello(sock, TOKEN)
        sock.close()
        if not reply or reply.get("t") != "hello_ok":
            say("FAIL: once %s was added, the android app's hello got %r, not hello_ok" % (ADDR, reply))
            return 1
        say("once %s was added, an android app completed the mutual hello on it" % ADDR)
        return 0
    finally:
        proc.kill()
        proc.wait()
        subprocess.run(["rm", "-rf", work])


def main():
    """run the check in a private network namespace"""
    if sys.argv[1:] == ["--inside"]:
        return 0 if inside() == 0 else 3
    probe = subprocess.run(["unshare", "-rn", "true"], capture_output=True, text=True, timeout=20)
    if probe.returncode != 0:
        print("NOT RUN: unshare -rn is refused here (%s)" % (probe.stderr.strip()[-200:] or probe.returncode))
        return 77
    try:
        rc = subprocess.run(["unshare", "-rn", sys.executable, os.path.abspath(__file__), "--inside"]).returncode
    except OSError as exc:
        say("FAIL: cannot run unshare to get a private network namespace: %s" % exc)
        return 1
    if rc not in (0, 3):
        say("FAIL: the private network namespace did not run the check (unshare -rn exited %d)" % rc)
        return 1
    return 0 if rc == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
