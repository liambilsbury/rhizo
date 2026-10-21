#!/usr/bin/env python3
import argparse
import contextlib
import io
import json
import os
import re
import socket
import sys
import tempfile
import threading


# exception for a QMP failure
class QmpError(Exception):
    pass


# connection to the qemu QMP socket
class Qmp:
    def __init__(self, path, timeout=10):
        """connect to the QMP socket"""
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(timeout)
        self.buf = b""
        self.s.connect("\0" + path[1:] if path.startswith("@") else path)
        greeting = self.reply()
        if "QMP" not in greeting:
            raise QmpError(f"the greeting is not QMP's: {greeting!r}")
        self.call("qmp_capabilities")

    def reply(self):
        """read a JSON line from the socket"""
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise QmpError("the QMP socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, cmd, **args):
        """send a command and return its result"""
        self.s.sendall(json.dumps({"execute": cmd, "arguments": args}).encode() + b"\n")
        while True:
            r = self.reply()
            if "event" in r:
                continue
            if "error" in r:
                raise QmpError(f"qemu answered {cmd} with an error: {r['error'].get('desc', r['error'])}")
            if "return" not in r:
                raise QmpError(f"{cmd} reply has no return: {r!r}")
            return r["return"]

    def hmp(self, line):
        """run an HMP command and return its text"""
        return self.call("human-monitor-command", **{"command-line": line})


def cpu_time(pid):
    """return the cpu time line for qemu pid"""
    with open(f"/proc/{pid}/stat") as f:
        fields = f.read().rsplit(")", 1)[1].split()
    ticks = os.sysconf("SC_CLK_TCK")
    used = (int(fields[11]) + int(fields[12])) / ticks
    with open("/proc/uptime") as f:
        up = float(f.read().split()[0])
    ran = up - int(fields[19]) / ticks
    return f"qemu pid {pid} has used {used:.1f}s of cpu in {ran:.0f}s"


def vcpus(text):
    """return a line per vCPU from info registers"""
    out = []
    for block in re.split(r"^CPU#", text, flags=re.M)[1:]:
        n = block.split("\n", 1)[0].strip()
        rip, hlt, cpl = (re.search(p, block) for p in (r"RIP=([0-9a-f]+)", r"HLT=(\d)", r"CPL=(\d)"))
        if not (rip and hlt and cpl):
            raise QmpError(f"info registers for CPU#{n} has no RIP, HLT and CPL: {block!r}")
        out.append(f"vcpu {n}: rip=0x{rip.group(1)} {'halted' if hlt.group(1) == '1' else 'running'} cpl={cpl.group(1)}")
    if not out:
        raise QmpError(f"info registers -a listed no CPU: {text!r}")
    return out


def capture(path, screen, pid, timeout):
    """print the qemu state read over QMP"""
    failed = 0

    def step(name, fn):
        """run a step and print its lines"""
        nonlocal failed
        try:
            for line in fn():
                print(line)
        except (QmpError, OSError, ValueError) as e:
            print(f"the {name} step failed: {e if isinstance(e, QmpError) else repr(e)}")
            failed += 1

    if pid:
        step("cpu time", lambda: [cpu_time(pid)])
    try:
        q = Qmp(path, timeout)
    except (QmpError, OSError, ValueError) as e:
        print(f"connecting to {path} failed: {e if isinstance(e, QmpError) else repr(e)}")
        return failed + 1
    step("query-status", lambda: [f"qemu status: {q.call('query-status')['status']}"])
    step("info registers", lambda: vcpus(q.hmp("info registers -a")))
    if screen:
        def screen_step():
            """save a screendump and return a line naming it"""
            q.call("screendump", filename=screen, format="png")
            if not os.path.exists(screen):
                raise QmpError(f"screendump reported success and left no {screen}")
            return [f"screen saved to {screen}"]
        step("screendump", screen_step)
    return failed


# scripted QMP socket for the selftest
class FakeQmp(threading.Thread):
    def __init__(self, path, screen_error=None, close_on=None, status="running"):
        """listen on the QMP socket path"""
        super().__init__(daemon=True)
        self.srv = socket.socket(socket.AF_UNIX)
        self.srv.bind("\0" + path[1:] if path.startswith("@") else path)
        self.srv.listen(1)
        self.screen_error = screen_error
        self.close_on = close_on
        self.status = status
        self.regs = ("CPU#0\nRAX=0000000000000000 RIP=000000007e3d5c2a RFL=00000202 [-------] CPL=0 II=0 A20=1 SMM=0 HLT=1\n"
                     "CS =0038 0000000000000000\n"
                     "CPU#1\nRAX=0000000000000000 RIP=ffffffff81e5f0a2 RFL=00000246 [---Z-P-] CPL=0 II=0 A20=1 SMM=0 HLT=0\n")

    def answer(self, req):
        """build the reply line for a request"""
        cmd, args = req["execute"], req.get("arguments", {})
        if cmd == "qmp_capabilities":
            ret = {}
        elif cmd == "query-status":
            ret = {"status": self.status, "running": self.status == "running"}
        elif cmd == "human-monitor-command":
            ret = self.regs.replace("\n", "\r\n") if args["command-line"] == "info registers -a" else ""
        elif cmd == "screendump":
            if self.screen_error:
                return json.dumps({"error": {"class": "GenericError", "desc": self.screen_error}}).encode()
            with open(args["filename"], "wb") as f:
                f.write(b"\x89PNG fake")
            ret = {}
        else:
            return json.dumps({"error": {"class": "CommandNotFound", "desc": cmd}}).encode()
        return json.dumps({"return": ret}).encode()

    def run(self):
        """serve connections on the socket"""
        while True:
            conn, _ = self.srv.accept()
            conn.sendall(json.dumps({"QMP": {"version": {}, "capabilities": []}}).encode() + b"\n")
            self.serve(conn)
            conn.close()

    def serve(self, conn):
        """reply to each request read from conn"""
        buf = b""
        while chunk := conn.recv(65536):
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                req = json.loads(line)
                if req["execute"] == self.close_on:
                    conn.sendall(b'{"retu')
                    return
                conn.sendall(json.dumps({"event": "RTC_CHANGE", "data": {}}).encode() + b"\n")
                conn.sendall(self.answer(req) + b"\n")


def selftest():
    """run capture against FakeQmp sockets"""
    failures = []

    def check(name, ok):
        """print the verdict of a case"""
        print(f"{'ok' if ok else 'FAIL'}  {name}")
        if not ok:
            failures.append(name)

    def run(path, screen, pid=None):
        """run capture and return its failures and output"""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            n = capture(path, screen, pid, timeout=2)
        return n, out.getvalue()

    with tempfile.TemporaryDirectory() as d:
        sock = os.path.join(d, "q.sock")
        FakeQmp(sock).start()
        screen_png = os.path.join(d, "screen.png")
        n, out = run(sock, screen_png, os.getpid())
        check("a healthy capture reports no failure", n == 0)
        check("the run state is printed", "qemu status: running" in out)
        check("a halted vCPU and a running one are told apart", "vcpu 0: rip=0x000000007e3d5c2a halted cpl=0" in out
              and "vcpu 1: rip=0xffffffff81e5f0a2 running cpl=0" in out)
        check("the screen is written where asked and named", os.path.exists(screen_png) and f"screen saved to {screen_png}" in out)
        check("the qemu cpu time is printed", f"qemu pid {os.getpid()} has used" in out)

        abstract = f"@rhizo-qmp-selftest.{os.getpid()}"
        FakeQmp(abstract, status="paused").start()
        n, out = run(abstract, os.path.join(d, "abstract.png"))
        check("an abstract socket is reached", n == 0 and "qemu status: paused" in out)

        refuse = os.path.join(d, "refuse.sock")
        FakeQmp(refuse, screen_error="no display").start()
        n, out = run(refuse, os.path.join(d, "refused.png"))
        check("a refused screendump is named and counted", n == 1 and "the screendump step failed: qemu answered screendump with an error: no display" in out)
        check("the other steps still report after a failed one", "qemu status: running" in out and "vcpu 0:" in out)

        closing = os.path.join(d, "closing.sock")
        FakeQmp(closing, close_on="human-monitor-command").start()
        n, out = run(closing, os.path.join(d, "closing.png"))
        check("a socket that closes mid-reply fails that step", n >= 1 and "the info registers step failed" in out and "closed" in out)

        n, out = run(os.path.join(d, "missing.sock"), os.path.join(d, "none.png"))
        check("a missing socket is one named failure", n == 1 and "connecting to" in out and "missing.sock" in out)
        n, out = run(sock, None, pid=2**22 + 1)
        check("a gone qemu pid fails the cpu time step alone", n == 1 and "the cpu time step failed" in out and "qemu status: running" in out)
    return 1 if failures else 0


def main(argv):
    """capture the qemu state or run the selftest"""
    p = argparse.ArgumentParser(description="read a running qemu's state over QMP")
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--sock", help="the QMP socket; @name is an abstract socket")
    p.add_argument("--screen", help="where to save a png screendump")
    p.add_argument("--pid", type=int, help="the qemu pid, for its cpu time")
    p.add_argument("--timeout", type=float, default=10, help="seconds each QMP read may take")
    args = p.parse_args(argv)
    if args.selftest:
        return selftest()
    if not args.sock:
        p.error("--sock is required")
    return 1 if capture(args.sock, args.screen, args.pid, args.timeout) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
