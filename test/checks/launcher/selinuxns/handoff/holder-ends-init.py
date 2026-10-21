#!/usr/bin/env python3
import ast
import contextlib
import errno
import io
import json
import os
import select
import signal
import sys
import tempfile
import time

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-holder-ends-init")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    import boot as launcher
from sandbox import selinux_ns as ns

SURVIVAL_WAIT_S = 10


def word(status):
    """return a wait status as a word"""
    return f"exit-{os.WEXITSTATUS(status)}" if os.WIFEXITED(status) else f"signal-{os.WTERMSIG(status)}"


def pause_forever():
    """wait for signals with SIGTERM's default action"""
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.pthread_sigmask(signal.SIG_SETMASK, [])
    while True:
        signal.pause()


def scenario(how, report_w):
    """run a holder and init scenario and return the report"""
    os.unshare(os.CLONE_NEWUSER)
    holder = os.fork()
    if holder == 0:
        os.close(report_w)
        pause_forever()
    alive_r, alive_w = os.pipe()
    go_r, go_w = os.pipe()
    os.unshare(os.CLONE_NEWPID)
    init = os.fork()
    if init == 0:
        os.close(report_w)
        os.close(alive_r)
        os.close(go_w)
        for _ in range(2):
            if os.fork() == 0:
                os.close(go_r)
                pause_forever()
        os.read(go_r, 1)
        os._exit(0)
    os.close(alive_w)
    os.close(go_r)
    holder_fd, init_fd = os.pidfd_open(holder), os.pidfd_open(init)
    report, verdicts, done_r, done_w = {}, [], *os.pipe()
    try:
        if how.startswith("holder"):
            os.kill(holder, signal.SIGKILL)
        else:
            if how == "init-first-after-flip":
                os.write(done_w, ns.DONE_ENFORCED)
            os.write(go_w, b"1")
        if how in ("holder-first-namespace", "holder-first-namespace-stop", "init-first-after-flip"):
            verdict, status = ns.watch_handed_off_init(init, done_r, time.time() + 60, verdicts.append,
                                                       stop_requested=lambda: how.endswith("-stop"),
                                                       holder_fd=holder_fd)
            report["verdict"] = verdict
        else:
            status = launcher.wait_init_under_holder(init, holder_fd)
        report["init"] = word(status)
        report["verdicts"] = verdicts
    except Exception as e:
        report["raised"] = repr(e)
    finally:
        ready, _, _ = select.select([alive_r], [], [], SURVIVAL_WAIT_S)
        report["sandbox_gone"] = bool(ready) and os.read(alive_r, 1) == b""
        report["holder_alive"] = not select.select([holder_fd], [], [], 0)[0]
        for pid, fd in ((init, init_fd), (holder, holder_fd)):
            try:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            except ProcessLookupError:
                continue
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                continue
    return report


def run(how):
    """run a scenario in a forked child"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                out = scenario(how, w)
        except BaseException as e:
            out = {"raised": repr(e)}
        os.write(w, json.dumps(out).encode())
        os._exit(0)
    os.close(w)
    data = b""
    while chunk := os.read(r, 65536):
        data += chunk
    os.close(r)
    os.waitpid(pid, 0)
    return json.loads(data or b"{}")


def unshare_user_works():
    """return whether this host lets a process unshare a user and pid namespace"""
    pid = os.fork()
    if pid == 0:
        try:
            os.unshare(os.CLONE_NEWUSER)
            os.unshare(os.CLONE_NEWPID)
        except OSError:
            os._exit(1)
        os._exit(0)
    return os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]) == 0


def unwatchable_holder_failures():
    """return the failures of a holder whose pidfd will not open"""
    bad = []
    saved_mode, saved_kmsg = os.environ.get("RHIZO_SELINUX_MODE"), launcher.kmsg
    launcher.kmsg = lambda m: None
    try:
        for mode, want_verdict in (("namespace", "refused:holder-pidfd-EMFILE"), ("host", "pending")):
            os.environ["RHIZO_SELINUX_MODE"] = mode
            holder = os.fork()
            if holder == 0:
                pause_forever()
            with tempfile.TemporaryDirectory() as records:
                fd = ns.open_records_dir(records)
                ns.record_verdict("pending", fd)
                logs = []
                launcher.refuse_unwatchable_holder(3, holder, OSError(errno.EMFILE, "Too many open files"),
                                                   logs.append, records_dir=records)
                verdict = ns.read_verdict(fd)
                os.close(fd)
            ended = word(os.waitpid(holder, 0)[1])
            if (verdict, ended) != (want_verdict, "signal-9") or not any("holder-pidfd-EMFILE" in m for m in logs):
                bad.append(f"an unwatchable holder in {mode} mode: want {want_verdict} and the holder killed; got "
                           f"{verdict}, {ended}, {logs}")
    finally:
        launcher.kmsg = saved_kmsg
        if saved_mode is None:
            os.environ.pop("RHIZO_SELINUX_MODE", None)
        else:
            os.environ["RHIZO_SELINUX_MODE"] = saved_mode
    tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
    opens = [t for t in ast.walk(tree) if isinstance(t, ast.Try) and t.body
             and ast.unparse(t.body[0]) == "holder_fd = os.pidfd_open(pid1)"]
    handlers = [(ast.unparse(h.type), ast.unparse(h)) for t in opens for h in t.handlers]
    if [h[0] for h in handlers] != ["ProcessLookupError", "OSError"] or "refuse_unwatchable_holder" not in handlers[1][1]:
        bad.append(f"P's holder pidfd_open: want ESRCH skipped and any other error refused; got {handlers}")
    return bad


def main():
    """return the failures"""
    bad = []
    saved = ns.kmsg
    ns.kmsg = lambda m: None
    try:
        for how, want in () if NOT_RUN else (
                ("holder-first-namespace", {"verdict": "refused:holder-ended", "init": "signal-9",
                                            "verdicts": ["refused:holder-ended"], "sandbox_gone": True}),
                ("holder-first-namespace-stop", {"verdict": "stopped", "init": "signal-9", "verdicts": ["stopped"],
                                                 "sandbox_gone": True}),
                ("holder-first-host", {"init": "signal-9", "sandbox_gone": True}),
                ("init-first-after-flip", {"verdict": "enforced", "init": "exit-0", "verdicts": ["enforced"],
                                           "holder_alive": True}),
                ("init-first-host", {"init": "exit-0", "holder_alive": True})):
            got = run(how)
            if any(got.get(k) != v for k, v in want.items()) or "raised" in got:
                bad.append(f"{how}: want {want}, got {got}")
    finally:
        ns.kmsg = saved
    bad += unwatchable_holder_failures()
    tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
    join = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_join_and_exec_init")
    text = ast.unparse(join)
    opened = text.find("holder_fd = os.pidfd_open(pid)")
    if not 0 <= opened < text.find("child = os.fork()"):
        bad.append("the joiner does not open the holder's pidfd before it forks init")
    if "holder_fd=holder_fd" not in text or "wait_init_under_holder(child, holder_fd)" not in text:
        bad.append("the joiner does not watch the holder in both modes' waits on init")
    finals = [t for t in ast.walk(join) if isinstance(t, ast.Try)
              and "os.close(holder_fd)" in "\n".join(ast.unparse(x) for x in t.finalbody)]
    if len(finals) != 1:
        bad.append("the joiner does not close the holder's pidfd in a finally")
    return bad


if __name__ == "__main__":
    NOT_RUN = [] if unshare_user_works() else ["the process scenarios -- this host refuses a user and pid namespace"]
    out = main()
    for line in out:
        print("FAIL:", line)
    for why in NOT_RUN:
        print(f"NOT RUN: {why}")
    print("holder-ends-init:", "FAIL" if out else "ok (process scenarios NOT RUN)"
          if NOT_RUN else "ok")
    sys.exit(1 if out else 0)
