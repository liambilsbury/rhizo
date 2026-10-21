#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile

LAUNCHER = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..",
                                         "src", "androidd", "boot.py"))
CHILD = r'''
import importlib.util, sys
sys.path.insert(0, sys.argv[2])
spec = importlib.util.spec_from_file_location("launcher_under_check", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod._enter_compiled_policy_namespace = lambda policy, helper: print("helper=" + helper, flush=True)
mod.kmsg = lambda m: None
print("before-fork", end="")


def raise_spaced():
    """raise an error whose message has spaces"""
    raise ValueError("a message with spaces")


print("\nreason=" + str(mod._in_policy_namespace("/p", raise_spaced, "relabel")[1]))
print("ok=" + repr(mod._in_policy_namespace("/p", lambda: ([["a", "b"]], None), "relabel")))
'''


def run(launcher_path):
    """return _in_policy_namespace's output from a launcher file"""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out")
        with open(out, "w") as f:
            subprocess.run([sys.executable, "-c", CHILD, launcher_path, os.path.dirname(LAUNCHER)], stdout=f,
                           stderr=subprocess.DEVNULL, timeout=120, env={**os.environ, "RHIZO_GSI": "/nonexistent-gsi"})
        return open(out).read()


def check(launcher_path):
    """return the findings for a launcher file"""
    out = run(launcher_path)
    bad = []
    if out.count("before-fork") != 1:
        bad.append(f"output buffered before the fork prints {out.count('before-fork')} times, not once")
    reason = next((line[len("reason="):] for line in out.splitlines() if line.startswith("reason=")), None)
    if reason is None:
        bad.append(f"no reason from a raising child: {out!r}")
    elif reason != "staging-child-raised:ValueError":
        bad.append(f"a raising child's reason is {reason!r}, not 'staging-child-raised:ValueError'")
    if out.count("helper=relabel") != 2:
        bad.append(f"the child entered as relabel {out.count('helper=relabel')} times, not twice: {out!r}")
    if "ok=([['a', 'b']], None)" not in out:
        bad.append(f"a child's result does not come back: {out!r}")
    return bad


def selftest():
    """flag each mutant and pass the real launcher"""
    src = open(LAUNCHER).read()
    cases = (("fork over unflushed output", "    sys.stdout.flush()\n    sys.stderr.flush()\n    r, w = os.pipe()\n",
              "    r, w = os.pipe()\n", "times, not once"),
             ("reason carrying the message", 'result = (None, f"staging-child-raised:{type(e).__name__}")',
              'result = (None, f"staging-child-raised:{type(e).__name__}:{e}")', "not 'staging-child-raised:ValueError'"),
             ("child entering as another helper", "why = _enter_compiled_policy_namespace(policy, helper)",
              'why = _enter_compiled_policy_namespace(policy, "label")', "as relabel"))
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        for n, (label, old, new, needle) in enumerate(cases):
            if src.count(old) != 1:
                return [f"the {label} mutant found {src.count(old)} anchors"]
            path = os.path.join(tmp, f"launcher_m{n}.py")
            with open(path, "w") as f:
                f.write(src.replace(old, new))
            got = check(path)
            if not any(needle in g for g in got):
                bad.append(f"the {label} mutant was not flagged: {got}")
    real = check(LAUNCHER)
    if real:
        bad.append(f"the real launcher has findings: {real}")
    return bad


def main():
    """run the check or its selftest"""
    bad = selftest() if "--selftest" in sys.argv[1:] else check(LAUNCHER)
    for b in bad:
        print("FAIL", b)
    print("PASS" if not bad else "FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
