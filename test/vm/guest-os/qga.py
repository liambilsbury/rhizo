#!/usr/bin/env python3
import argparse
import base64
import contextlib
import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time


# exception for a qemu-ga failure
class AgentError(Exception):
    pass


def alive(pid):
    """return true for a live pid"""
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except FileNotFoundError:
        return False


# connection to qemu-ga in a guest
class Agent:
    def __init__(self, sock, timeout=10):
        """connect to the qemu-ga socket"""
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(timeout)
        self.s.connect(sock)
        self.buf = b""

    def reply(self):
        """read a reply from qemu-ga"""
        while b"\n" not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError("guest agent socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line.rsplit(b"\xff", 1)[-1])

    def sync(self):
        """send a sync request and read its reply"""
        token = int(time.time() * 1000) % 2**31
        req = {"execute": "guest-sync-delimited", "arguments": {"id": token}}
        self.s.sendall(b"\xff" + json.dumps(req).encode() + b"\n")
        while self.reply().get("return") != token:
            pass

    def call(self, cmd, **args):
        """send a command and return its result"""
        self.s.sendall(json.dumps({"execute": cmd, "arguments": args}).encode() + b"\n")
        r = self.reply()
        if isinstance(r, dict) and "error" in r:
            raise AgentError(f"{cmd} failed: {r['error']}")
        return need(r, "return", cmd)


def need(reply, key, what):
    """return reply[key] or raise AgentError"""
    if not isinstance(reply, dict) or key not in reply:
        raise AgentError(f"{what} reply has no {key}: {reply!r}")
    return reply[key]


def wait_for_agent(sock, pid, timeout, retry=3):
    """return a connection to qemu-ga"""
    t0 = time.monotonic()
    while True:
        if not alive(pid):
            raise AgentError(f"qemu pid {pid} exited before the guest agent answered")
        try:
            agent = Agent(sock)
            agent.sync()
            return agent
        except (OSError, EOFError, ValueError) as e:
            if time.monotonic() - t0 > timeout:
                raise AgentError(f"guest agent on {sock} did not answer in {timeout}s, last error: {e!r}")
            time.sleep(retry)


def run(agent, argv, timeout):
    """run argv and return its guest exit status"""
    pid = need(agent.call("guest-exec", path=argv[0], arg=argv[1:]), "pid", "guest-exec")
    t0 = time.monotonic()
    while not need(st := agent.call("guest-exec-status", pid=pid), "exited", "guest-exec-status"):
        if time.monotonic() - t0 > timeout:
            raise AgentError(f"{' '.join(argv)} still running in the guest after {timeout}s")
        time.sleep(0.2)
    return st.get("exitcode")


def put(agent, src, dst):
    """copy a host file into the guest"""
    with open(src, "rb") as f:
        data = f.read()
    h = agent.call("guest-file-open", path=dst, mode="w")
    n = need(agent.call("guest-file-write", handle=h, **{"buf-b64": base64.b64encode(data).decode()}), "count", "guest-file-write")
    agent.call("guest-file-close", handle=h)
    if n != len(data):
        raise AgentError(f"wrote {n} of {len(data)} bytes to {dst}")
    return n


def start(agent, argv):
    """start argv and return its guest pid"""
    return need(agent.call("guest-exec", path=argv[0], arg=argv[1:]), "pid", "guest-exec")


# scripted qemu-ga for the selftest
class FakeAgent(threading.Thread):
    def __init__(self, path, exitcode, close_on=None, bare_on=None):
        """listen on the unix socket path"""
        super().__init__(daemon=True)
        self.srv = socket.socket(socket.AF_UNIX)
        self.srv.bind(path)
        self.srv.listen(1)
        self.exitcode = exitcode
        self.close_on = close_on
        self.bare_on = bare_on
        self.files = {}
        self.execs = []
        self.handles = {}

    def answer(self, req):
        """build the reply line for a request"""
        cmd, args = req["execute"], req.get("arguments", {})
        if cmd == self.bare_on:
            return json.dumps({"oops": cmd}).encode()
        if cmd == "guest-sync-delimited":
            return b"\xff" + json.dumps({"return": args["id"]}).encode()
        if cmd == "guest-ping" or cmd == "guest-file-close":
            ret = {}
        elif cmd == "guest-exec":
            self.execs.append([args["path"]] + args.get("arg", []))
            ret = {"pid": len(self.execs)}
        elif cmd == "guest-exec-status":
            if self.exitcode == "no-exited":
                ret = {"exitcode": 0}
            elif self.exitcode is None:
                ret = {"exited": False}
            else:
                ret = {"exited": True, "exitcode": self.exitcode}
        elif cmd == "guest-file-open":
            self.handles[len(self.handles) + 1] = args["path"]
            self.files[args["path"]] = b""
            ret = len(self.handles)
        elif cmd == "guest-file-write":
            data = base64.b64decode(args["buf-b64"])
            self.files[self.handles[args["handle"]]] += data
            ret = {"count": len(data), "eof": False}
        else:
            return json.dumps({"error": {"class": "CommandNotFound", "desc": cmd}}).encode()
        return json.dumps({"return": ret}).encode()

    def run(self):
        """serve connections on the socket"""
        while True:
            conn, _ = self.srv.accept()
            conn.sendall(json.dumps({"return": 7}).encode() + b"\n")
            self.serve(conn)
            conn.close()

    def serve(self, conn):
        """reply to each request read from conn"""
        buf = b""
        while chunk := conn.recv(65536):
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                req = json.loads(line.lstrip(b"\xff"))
                if req["execute"] == self.close_on:
                    conn.sendall(b'{"retu')
                    return
                conn.sendall(self.answer(req) + b"\n")


def selftest():
    """run the qga cases against FakeAgent"""
    failures = []

    def check(name, ok):
        """print the verdict of a case"""
        print(f"{'ok' if ok else 'FAIL'}  {name}")
        if not ok:
            failures.append(name)

    def raises(fn):
        """return the AgentError text fn raises"""
        try:
            fn()
        except AgentError as e:
            return str(e)
        return None

    def main_err(argv):
        """run main and return its status and stderr"""
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            rc = main(argv)
        return rc, err.getvalue()

    me = os.getpid()
    dead = subprocess.Popen(["true"])
    dead.wait()
    with tempfile.TemporaryDirectory() as d:
        clean = os.path.join(d, "clean.sock")
        fake = FakeAgent(clean, exitcode=0)
        fake.start()
        agent = wait_for_agent(clean, me, timeout=5)
        check("sync skips a queued reply and ping answers", agent.call("guest-ping") == {})
        check("exec returns the guest's exit status 0", run(agent, ["/bin/true"], timeout=5) == 0)
        fake.exitcode = 3
        check("exec returns the guest's exit status 3", run(agent, ["/bin/false"], timeout=5) == 3)
        src = os.path.join(d, "payload")
        with open(src, "wb") as f:
            f.write(b"key\x00\xffbytes\n")
        put(agent, src, "/run/x/payload")
        check("a file write lands byte for byte", fake.files.get("/run/x/payload") == b"key\x00\xffbytes\n")
        fake.exitcode = None
        err = raises(lambda: run(agent, ["/bin/mkdir", "-p", "/run/x"], timeout=0.5))
        check("an exec that never exits fails naming its command", err is not None and "/bin/mkdir -p /run/x" in err)
        fake.exitcode = 0
        check("an exec that exits does not fail on a zero timeout", raises(lambda: run(agent, ["/bin/true"], timeout=0)) is None)
        check("start returns the guest pid without waiting", start(agent, ["/bin/sleep", "60"]) == len(fake.execs))
        err = raises(lambda: agent.call("guest-no-such-command"))
        check("an agent error reply fails naming the command", err is not None and "guest-no-such-command" in err)
        fake.exitcode = "no-exited"
        err = raises(lambda: run(agent, ["/bin/true"], timeout=5))
        check("an exec status with no exited fails naming the reply", err is not None and "guest-exec-status reply has no exited: {'exitcode': 0}" in err)
        fake.exitcode = 0
        fake.bare_on = "guest-ping"
        err = raises(lambda: agent.call("guest-ping"))
        check("a reply with no return fails naming the reply", err is not None and "guest-ping reply has no return: {'oops': 'guest-ping'}" in err)
        fake.bare_on = None
        agent.s.close()
        rc, err = main_err(["--sock", clean, "--qemu-pid", str(me), "--put", src, "/run/x/payload", "--start", "/bin/true"])
        check("a run that copies and starts exits 0 with nothing on stderr", rc == 0 and err == "")
        missing = os.path.join(d, "missing")
        rc, err = main_err(["--sock", clean, "--qemu-pid", str(me), "--put", missing, "/run/x/m", "--start", "/bin/true"])
        check("a missing --put source exits 1 with one line naming the copy", rc == 1 and err.count("\n") == 1 and f"copying {missing}" in err)
        err = raises(lambda: wait_for_agent(clean, dead.pid, timeout=5))
        check("a dead qemu pid fails the wait at once", err is not None and str(dead.pid) in err)
        err = raises(lambda: wait_for_agent(os.path.join(d, "silent.sock"), me, timeout=0.3, retry=0.1))
        check("an agent that never answers fails the wait past its timeout", err is not None and "did not answer" in err)
        closing = os.path.join(d, "closing.sock")
        FakeAgent(closing, exitcode=0, close_on="guest-file-write").start()
        rc, err = main_err(["--sock", closing, "--qemu-pid", str(me), "--put", src, "/run/x/payload", "--start", "/bin/true"])
        check("an agent that closes mid-reply exits 1 with one line naming the copy", rc == 1 and err.count("\n") == 1 and "copying" in err and "closed" in err)
    return 1 if failures else 0


def main(argv=None):
    """copy the --put files and start --start"""
    p = argparse.ArgumentParser(description="copy files into a guest and start a command through qemu-ga")
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--sock")
    p.add_argument("--qemu-pid", type=int)
    p.add_argument("--wait", type=float, default=600, help="seconds to wait for the agent")
    p.add_argument("--timeout", type=float, default=600, help="seconds a guest command may run")
    p.add_argument("--put", nargs=2, action="append", default=[], metavar=("SRC", "DST"))
    p.add_argument("--start", nargs=argparse.REMAINDER, help="argv to start in the guest, last")
    a = p.parse_args(argv)
    if a.selftest:
        return selftest()
    if not (a.sock and a.qemu_pid and a.start):
        p.error("--sock, --qemu-pid and --start are required")
    step = f"waiting for the guest agent on {a.sock}"
    try:
        t0 = time.monotonic()
        agent = wait_for_agent(a.sock, a.qemu_pid, a.wait)
        print(f"guest agent answered after {time.monotonic() - t0:.0f}s")
        for d in sorted({os.path.dirname(dst) for _, dst in a.put}):
            step = f"mkdir -p {d} in the guest"
            rc = run(agent, ["/bin/mkdir", "-p", d], a.timeout)
            if rc != 0:
                raise AgentError(f"exited {rc}")
        for src, dst in a.put:
            step = f"copying {src} to {dst} in the guest"
            print(f"wrote {dst}, {put(agent, src, dst)} bytes")
        step = f"starting {' '.join(a.start)} in the guest"
        print(f"started {' '.join(a.start)}, guest pid {start(agent, a.start)}")
    except (AgentError, OSError, EOFError, ValueError) as e:
        print(f"{step}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
