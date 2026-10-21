#!/usr/bin/env python3
import ast
import contextlib
import io
import os
import signal
import subprocess
import sys
import tempfile
import time
import types

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
LAUNCHER = os.path.join(REPO, "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-android-dummy0")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    import boot as launcher

MODPROBE = ["modprobe", "dummy", "numdummies=0"]
LINK_ADD = ["nsenter", "-t", "4242", "-n", "ip", "link", "add", "dummy0", "type", "dummy"]


def run_with(fail_cmd, raises=False, hangs=False):
    """run add_android_dummy0 under a stub run"""
    calls, logs = [], []

    def fake_run(cmd, **kw):
        """record cmd and return its stub status"""
        calls.append(list(cmd))
        if not kw.get("timeout"):
            calls.append(["no timeout"])
        if hangs and cmd[:2] == fail_cmd[:2]:
            raise subprocess.TimeoutExpired(cmd, kw.get("timeout"))
        if raises and cmd[:2] == fail_cmd[:2]:
            raise FileNotFoundError(2, "stub refusal", cmd[0])
        return types.SimpleNamespace(returncode=1 if cmd[:2] == fail_cmd[:2] else 0, stdout="",
                                     stderr="stub refusal" if cmd[:2] == fail_cmd[:2] else "")

    saved = launcher.kmsg
    launcher.kmsg = logs.append
    try:
        got = launcher.add_android_dummy0(4242, run=fake_run)
    finally:
        launcher.kmsg = saved
    return got, calls, logs


def refusal_problems():
    """return refuse_start_before_init's problems on a stand-in g"""
    if not callable(getattr(launcher, "refuse_start_before_init", None)):
        return ["launcher has no refuse_start_before_init"]
    g = os.fork()
    if g == 0:
        time.sleep(30)
        os._exit(0)
    logs, refused = [], []

    def fake_refuse_start():
        """record the call and raise SystemExit"""
        refused.append(True)
        raise SystemExit(3)

    saved = launcher.kmsg, launcher.refuse_start, launcher.selinux_ns.kmsg
    launcher.kmsg, launcher.refuse_start, launcher.selinux_ns.kmsg = logs.append, fake_refuse_start, logs.append
    try:
        with tempfile.TemporaryDirectory() as tmp:
            try:
                launcher.refuse_start_before_init(g, "dummy0-failed", records_dir=tmp)
            except SystemExit:
                pass
            verdict = open(os.path.join(tmp, "selinuxns-verdict")).read().strip()
            enforce = open(os.path.join(tmp, "android-enforce")).read().strip()
    finally:
        launcher.kmsg, launcher.refuse_start, launcher.selinux_ns.kmsg = saved
    try:
        os.kill(g, signal.SIGKILL)
        os.waitpid(g, 0)
        reaped = False
    except (ProcessLookupError, ChildProcessError):
        reaped = True
    want = ("refused:dummy0-failed", "0", [True], True)
    got = (verdict, enforce, refused, reaped)
    if got != want or not any("selinuxns=refused reason=dummy0-failed" in m for m in logs):
        return [f"refuse_start_before_init: want verdict, enforce, refuse_start, g reaped {want} and a refused marker; "
                f"got {got}, {logs}"]
    return []


def main():
    """return the failures"""
    fails = []
    if not callable(getattr(launcher, "add_android_dummy0", None)):
        return ["launcher has no add_android_dummy0"]
    got, calls, logs = run_with([])
    if got is not True or calls != [MODPROBE, LINK_ADD] or not any("dummy0=created" in m for m in logs):
        fails.append(f"a good start: want True, {[MODPROBE, LINK_ADD]} and dummy0=created; got {got}, {calls}, {logs}")
    for label, fail_cmd, raises, reason, want_calls in (
            ("modprobe fails", MODPROBE, False, "reason=modprobe", [MODPROBE]),
            ("modprobe is missing", MODPROBE, True, "reason=modprobe", [MODPROBE]),
            ("the link add fails", LINK_ADD, False, "reason=link-add", [MODPROBE, LINK_ADD]),
            ("nsenter is missing", LINK_ADD, True, "reason=link-add", [MODPROBE, LINK_ADD])):
        got, calls, logs = run_with(fail_cmd, raises)
        if got is not False or calls != want_calls or not any("dummy0=failed" in m and reason in m
                                                              and "stub refusal" in m for m in logs):
            fails.append(f"{label}: want False, {want_calls} and a dummy0=failed {reason} marker naming the error; "
                         f"got {got}, {calls}, {logs}")
    for label, fail_cmd, reason, want_calls in (
            ("modprobe hangs", MODPROBE, "reason=modprobe", [MODPROBE]),
            ("the link add hangs", LINK_ADD, "reason=link-add", [MODPROBE, LINK_ADD])):
        try:
            got, calls, logs = run_with(fail_cmd, hangs=True)
        except subprocess.TimeoutExpired as e:
            got, calls, logs = repr(e), [], []
        if got is not False or calls != want_calls or not any("dummy0=failed" in m and reason in m
                                                              and "no answer within" in m for m in logs):
            fails.append(f"{label}: want False, {want_calls} and a dummy0=failed {reason} marker naming the timeout; "
                         f"got {got}, {calls}, {logs}")
    fails += refusal_problems()
    tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
    run_sandbox = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "run_sandbox")
    gated = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If)
             and ast.unparse(n.test) == "not host_selinux_mode() and (not add_android_dummy0(g))"
             and ast.unparse(n.body) == "refuse_start_before_init(g, 'dummy0-failed')"]
    calls_all = [c for c in ast.walk(run_sandbox) if isinstance(c, ast.Call) and ast.unparse(c) == "add_android_dummy0(g)"]
    barrier = [c for c in ast.walk(run_sandbox) if isinstance(c, ast.Call) and ast.unparse(c) == "os.write(veth_w, b'1')"]
    if len(calls_all) != 1 or len(gated) != 1:
        fails.append(f"run_sandbox calls add_android_dummy0(g) once, under not host_selinux_mode(), and refuses the "
                     f"start on its failure: {len(calls_all)} calls, {len(gated)} gated")
    elif len(barrier) != 1 or calls_all[0].lineno > barrier[0].lineno:
        fails.append("add_android_dummy0(g) runs after the veth barrier byte")
    return fails


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("android-dummy0:", "FAIL" if out else "OK")
    sys.exit(1 if out else 0)
