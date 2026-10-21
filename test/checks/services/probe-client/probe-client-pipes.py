#!/usr/bin/env python3
import os
import select
import socket
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
CLIENT = os.path.join(ROOT, "src", "services", "probe-client", "probe-client.py")
TRAILER = b"\x00RHIZO_PROBE_RC=0\x00"
BOUND_S = 30


def serve_once(path, handler):
    """serve a unix socket connection with handler"""
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)

    def run():
        """accept a connection and run handler"""
        conn, _ = srv.accept()
        try:
            handler(conn)
        finally:
            conn.close()
            srv.close()
    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


def answers_megabyte(conn):
    """answer 1 MiB and the trailer"""
    conn.recv(4096)
    conn.sendall(b"x" * (1 << 20) + TRAILER)


def holds_without_trailer(conn):
    """answer a line and hold the connection"""
    conn.recv(4096)
    conn.sendall(b"partial\n")
    select.select([conn], [], [], BOUND_S)


def drops_unread(conn):
    """close the connection unread"""
    select.select([conn], [], [], BOUND_S)


def closes_at_once(conn):
    """close the connection"""


def client(sock, timeout_s, command=("logcat -d -b all",), **kw):
    """start the client against sock"""
    return subprocess.Popen([sys.executable, CLIENT, sock, str(timeout_s), *command], **kw)


def main():
    """return the failures"""
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        sock = os.path.join(tmp, "a.sock")
        t = serve_once(sock, answers_megabyte)
        p = client(sock, BOUND_S, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        p.stdout.read(1)
        p.stdout.close()
        err = p.stderr.read().decode(errors="replace")
        rc = p.wait(BOUND_S)
        t.join(BOUND_S)
        if rc != 0 or "Traceback" in err:
            bad.append(f"a reader leaving after one byte: want the command's rc 0 and no traceback; got rc {rc}, "
                       f"stderr {err.strip()[-300:]!r}")

        sock = os.path.join(tmp, "b.sock")
        t = serve_once(sock, holds_without_trailer)
        p = client(sock, 1, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        p.stdout.close()
        rc = p.wait(BOUND_S)
        if rc != 98:
            bad.append(f"a timeout whose stdout and stderr reader already left: want rc 98; got {rc}")

        sock = os.path.join(tmp, "c.sock")
        t = serve_once(sock, drops_unread)
        p = client(sock, BOUND_S, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = p.communicate(timeout=BOUND_S)
        t.join(BOUND_S)
        err = err.decode(errors="replace")
        if p.returncode != 98 or "Traceback" in err or "RHIZO_PROBE_" not in err:
            bad.append(f"rhizo-probed closing the connection with the command unread: want rc 98 and a RHIZO_PROBE_ "
                       f"line, no traceback; got rc {p.returncode}, stderr {err.strip()[-300:]!r}")

        sock = os.path.join(tmp, "d.sock")
        t = serve_once(sock, closes_at_once)
        p = client(sock, BOUND_S, command=["y" * 100000] * 8, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = p.communicate(timeout=BOUND_S)
        t.join(BOUND_S)
        err = err.decode(errors="replace")
        if p.returncode != 98 or "Traceback" in err or "RHIZO_PROBE_" not in err:
            bad.append(f"rhizo-probed closing the connection while an 800 kB command is being sent: want rc 98 and a "
                       f"RHIZO_PROBE_ line, no traceback; got rc {p.returncode}, stderr {err.strip()[-300:]!r}")
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("probe-client-pipes:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
