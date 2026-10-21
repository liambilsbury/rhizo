"""live socket assertions against a running rhizo-audiod"""
import socket
import subprocess
import sys
import time

SOCK, LOG, CLIENT_BIN, EXPECT, IDLE_TIMEOUT = sys.argv[1:6]
IDLE_TIMEOUT = int(IDLE_TIMEOUT)
FIXED = (EXPECT == "fixed")

results = []


def record(name, ok, detail=""):
    results.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail and not ok else ''}")


def log_text():
    try:
        return open(LOG).read()
    except FileNotFoundError:
        return ""


holder = subprocess.Popen([CLIENT_BIN, "--socket", SOCK, "--silent", "--seconds", "40"])
time.sleep(0.5)
b = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
b.settimeout(5)
b.connect(SOCK)
b.sendall(b"rhizo-audio/1 port=bus0 rate=48000 channels=2 format=s16le\n")
deadline = time.time() + 5.0
served = False
while time.time() < deadline:
    if "node 'rhizo.bus0' up" in log_text():
        served = True
        break
    time.sleep(0.1)
b.close()
holder.terminate()
holder.wait(timeout=5)
if FIXED:
    record("accept path does not freeze on a silent connection", served,
           "client B was never served while a silent client held the daemon")
else:
    record("accept path freezes on a silent connection (pre-fix defect reproduced)",
           not served, "client B WAS served despite the silent holder")

EVIL = "attacker.controlled.node.name"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5)
s.connect(SOCK)
s.sendall(("rhizo-audio/1 port=%s rate=48000 channels=2 format=s16le\n" % EVIL).encode())
time.sleep(1.0)
text = log_text()
accepted = ("node 'rhizo.%s' up" % EVIL) in text
s.close()
if FIXED:
    record("an arbitrary port= label is refused, not turned into a node identity", not accepted)
else:
    record("an arbitrary port= label is accepted into a node identity (pre-fix defect reproduced)",
           accepted)

if FIXED:
    holder2 = subprocess.Popen([CLIENT_BIN, "--socket", SOCK, "--silent", "--seconds",
                                 str(IDLE_TIMEOUT + 30)])
    deadline = time.time() + IDLE_TIMEOUT + 5
    reaped = False
    while time.time() < deadline:
        if "idle for" in log_text() and "reaping" in log_text():
            reaped = True
            break
        time.sleep(0.2)
    holder2.terminate()
    holder2.wait(timeout=5)
    record("a silently-connected client is reaped by the idle timeout", reaped)
else:
    holder2 = subprocess.Popen([CLIENT_BIN, "--socket", SOCK, "--silent", "--seconds", "8"])
    time.sleep(6)
    reaped = "idle for" in log_text() and "reaping" in log_text()
    holder2.wait(timeout=5)
    record("a silent connection is never reaped (pre-fix defect reproduced)", not reaped)

MAX_CLIENTS = 16
socks = []
ok_conn = True
for i in range(MAX_CLIENTS):
    cs = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    cs.settimeout(3)
    try:
        cs.connect(SOCK)
        cs.sendall(("rhizo-audio/1 port=bus%d rate=48000 channels=2 format=s16le\n" % (i % 4)).encode())
    except OSError:
        ok_conn = False
    socks.append(cs)
time.sleep(1.0)
extra = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
extra.settimeout(3)
extra.connect(SOCK)
extra.sendall(b"rhizo-audio/1 port=bus0 rate=48000 channels=2 format=s16le\n")
time.sleep(0.5)
try:
    data = extra.recv(4096)
    refused = (data == b"")
except socket.timeout:
    refused = False
except ConnectionResetError:
    refused = True
for cs in socks:
    cs.close()
extra.close()
record("the 17th concurrent stream is refused (MAX_CLIENTS enforced)", refused and ok_conn)

import os as _os
STATUS_PATH = _os.path.join(_os.path.dirname(SOCK), "status")


def _streams():
    try:
        with open(STATUS_PATH) as fh:
            line = fh.readline().strip()
    except FileNotFoundError:
        return None
    if line.startswith("streams="):
        return int(line.split("=", 1)[1])
    return None


if FIXED:
    before = None
    deadline = time.time() + 5.0
    while time.time() < deadline:
        n = _streams()
        if n == 0:
            before = n
            break
        time.sleep(0.1)
    holder3 = subprocess.Popen([CLIENT_BIN, "--socket", SOCK, "--seconds", "3"])
    during = None
    deadline = time.time() + 3.0
    while time.time() < deadline:
        n = _streams()
        if n is not None and n >= 1:
            during = n
            break
        time.sleep(0.1)
    holder3.wait(timeout=6)
    after = None
    deadline = time.time() + 3.0
    while time.time() < deadline:
        n = _streams()
        if n == 0:
            after = n
            break
        time.sleep(0.1)
    record("the stream count goes 0 -> 1 -> 0 as a client connects and disconnects",
           before == 0 and during == 1 and after == 0,
           "before=%r during=%r after=%r" % (before, during, after))
else:
    record("no per-connection stream status file (pre-fix defect reproduced)",
           _streams() is None)

if len(results) == 0:
    print("FAIL: no cases were asserted")
    sys.exit(1)

sys.exit(0 if all(ok for _, ok in results) else 1)
