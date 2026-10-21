#!/usr/bin/env python3
import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCHER_DIR = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "src", "androidd"))
sys.path.insert(0, LAUNCHER_DIR)

from sandbox import rootfs  # noqa: E402

RELEASES = (("7.1.0-rc1-rhizo", True), ("6.14.0", True), ("6.13.12-arch1-1", False),
            ("6.12.99-rhizo", False), ("6.8.0-45-generic", False), ("rhizo", False))


def gated_calls(tree):
    """return the cap calls in enter_sandbox_init, split by namespace gate"""
    inside, outside = 0, 0
    for fn in ast.walk(tree):
        if not (isinstance(fn, ast.FunctionDef) and fn.name == "enter_sandbox_init"):
            continue
        gated = set()
        for node in ast.walk(fn):
            if (isinstance(node, ast.If) and isinstance(node.test, ast.UnaryOp)
                    and isinstance(node.test.op, ast.Not) and isinstance(node.test.operand, ast.Call)
                    and getattr(node.test.operand.func, "id", "") == "host_selinux_mode"):
                gated.update(id(n) for stmt in node.body for n in ast.walk(stmt))
        for node in ast.walk(fn):
            if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "cap_pid_namespace_pid_max":
                if id(node) in gated:
                    inside += 1
                else:
                    outside += 1
    return inside, outside


def refusal_guards(tree):
    """return how many ifs refuse with pid-max-unset"""
    found = 0
    for node in ast.walk(tree):
        test = node.test if isinstance(node, ast.If) else None
        if not (isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not) and isinstance(test.operand, ast.Call)
                and getattr(test.operand.func, "id", "") == "cap_pid_namespace_pid_max"):
            continue
        body = [n for stmt in node.body for n in ast.walk(stmt)]
        marker = any(isinstance(n, ast.Constant) and isinstance(n.value, str)
                     and "selinuxns=refused reason=pid-max-unset" in n.value for n in body)
        exits = any(isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "_exit"
                    and n.args and isinstance(n.args[0], ast.Constant) and n.args[0].value == 1 for n in body)
        found += marker and exits
    return found


def caps_failure_findings():
    """run the pid_max child with capabilities that will not drop"""
    r, w = os.pipe()
    real = (os.uname, rootfs.kmsg, rootfs.unshare, rootfs.selinux_ns.drop_to_init_caps)
    os.uname = lambda: os.uname_result(("Linux", "host", "7.1.0-rc1-rhizo", "#1", real[0]().machine))
    rootfs.kmsg = lambda m: os.write(w, (m + "\n").encode())
    rootfs.unshare = lambda flags: os.write(w, b"unshare\n")
    rootfs.selinux_ns.drop_to_init_caps = lambda: "capbset-drop:16:1"
    try:
        ok = rootfs.cap_pid_namespace_pid_max()
    finally:
        os.uname, rootfs.kmsg, rootfs.unshare, rootfs.selinux_ns.drop_to_init_caps = real
        os.close(w)
    lines = os.read(r, 65536).decode().splitlines()
    os.close(r)
    want = "RHIZO_MARKER pid_max=unset reason=caps-failed:capbset-drop:16:1"
    if ok is not False or lines != [want]:
        return [f"a pid_max child whose capabilities will not drop: want False and only {want!r}; got {ok}, {lines}"]
    return []


def main():
    """run the pid-max checks"""
    bad = []
    for release, want in RELEASES:
        got = rootfs.pid_max_is_per_namespace(release)
        if got != want:
            bad.append(f"pid_max_is_per_namespace({release!r}) is {got}, want {want}")
    forks = []
    real_uname, real_fork, real_kmsg = os.uname, os.fork, rootfs.kmsg
    os.uname = lambda: os.uname_result(("Linux", "host", "6.8.0-45-generic", "#1", real_uname().machine))
    os.fork = lambda: forks.append(1) or (_ for _ in ()).throw(AssertionError("forked"))
    rootfs.kmsg = lambda m: None
    ok = None
    try:
        ok = rootfs.cap_pid_namespace_pid_max()
    except AssertionError:
        pass
    finally:
        os.uname, os.fork, rootfs.kmsg = real_uname, real_fork, real_kmsg
    if ok or forks:
        bad.append(f"a 6.8 kernel's global pid_max was written: returned {ok}, forked {len(forks)}")
    bad += caps_failure_findings()
    if rootfs.ANDROID_PID_MAX != 32768:
        bad.append(f"ANDROID_PID_MAX is {rootfs.ANDROID_PID_MAX}, want 32768")
    with open(os.path.join(LAUNCHER_DIR, "boot.py")) as f:
        launcher_tree = ast.parse(f.read())
    inside, outside = gated_calls(launcher_tree)
    if inside != 1 or outside != 0:
        bad.append(f"enter_sandbox_init calls cap_pid_namespace_pid_max {inside} time(s) under "
                   f"'if not host_selinux_mode()' and {outside} outside it, want 1 and 0")
    if refusal_guards(launcher_tree) != 1:
        bad.append("enter_sandbox_init does not refuse with 'selinuxns=refused reason=pid-max-unset' and exit 1 "
                   "when cap_pid_namespace_pid_max() returns false")
    for b in bad:
        print(f"FAIL: check-pid-max: {b}")
    if not bad:
        print("check-pid-max: ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
