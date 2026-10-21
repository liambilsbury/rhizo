#!/usr/bin/env python3

import ast
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")


def _host_primer_src(module_src):
    """return the HOST_PRIMER_SRC string literal"""
    tree = ast.parse(module_src)
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(t, ast.Name) and t.id == "HOST_PRIMER_SRC" for t in node.targets):
            continue
        if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
            return node.value.value
    return None


def _is_systemctl_restart_call(node):
    """check for a systemctl restart call"""
    if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "run"):
        return False
    if not node.args or not isinstance(node.args[0], ast.List):
        return False
    strs = [e.value for e in node.args[0].elts
            if isinstance(e, ast.Constant) and isinstance(e.value, str)]
    return "systemctl" in strs and "restart" in strs


def _is_log_call(node):
    """return whether a node is a call to log"""
    return (isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
            and isinstance(node.value.func, ast.Name) and node.value.func.id == "log")


def check(primer_src):
    """return the problems found in the primer source"""
    try:
        tree = ast.parse(primer_src)
    except SyntaxError as e:
        return ["could not parse primer source: %s" % e]

    target = None
    for node in ast.walk(tree):
        if not (isinstance(node, ast.For) and isinstance(node.iter, ast.Call)
                and isinstance(node.iter.func, ast.Name) and node.iter.func.id == "sorted"):
            continue
        args = node.iter.args
        if args and isinstance(args[0], ast.Name) and args[0].id == "_stuck_units":
            target = node
            break
    if target is None:
        return ["no `for u in sorted(_stuck_units):` loop found"]

    restart_stmt = None
    restart_index = None
    for i, stmt in enumerate(target.body):
        if any(_is_systemctl_restart_call(sub) for sub in ast.walk(stmt)):
            restart_stmt = stmt
            restart_index = i
    if restart_stmt is None:
        return ["no `subprocess.run([\"systemctl\",\"restart\",...])` call found inside "
                "the stuck-units loop"]

    problems = []
    if not isinstance(restart_stmt, ast.Try):
        problems.append(
            "the systemctl-restart call is not wrapped in a try/except at the loop-body "
            "level")

    has_prior_log = any(
        any(_is_log_call(sub) for sub in ast.walk(target.body[j]))
        for j in range(restart_index)
    )
    if not has_prior_log:
        problems.append(
            "no log(...) call before the systemctl-restart call inside the loop")
    return problems


def _fixture(before_log, before_try):
    """build a stand-in for the restart loop"""
    body = []
    if before_log:
        body.append('    log("restarting %s (still in kernel domain)" % u)')
    call = ('rr = subprocess.run(["systemctl", "restart", u], timeout=90, '
            'check=False, capture_output=True, text=True)')
    if before_try:
        body.append("    try:")
        body.append("        " + call)
        body.append("    except subprocess.TimeoutExpired:")
        body.append('        log("restart %s TIMED OUT after 90s" % u)')
        body.append("        continue")
    else:
        body.append("    " + call)
    body.append('    if rr.returncode != 0: log("restart %s rc=%s" % (u, rr.returncode))')
    return "\n".join([
        "for u in sorted(_stuck_units):",
        '    if u.startswith("ssh"): continue',
        '    if u.startswith("androidd") or u.startswith("rhizo-host-primer"): continue',
    ] + body) + "\n"


def selftest():
    """test check on fixture primer sources"""
    bad = 0

    before = _fixture(before_log=False, before_try=False)
    problems = check(before)
    print("--- seeded regression (bare call, the pre-fix shape) ---")
    for p in problems:
        print("FAIL: %s" % p)
    if len(problems) != 2:
        print("SELFTEST FAIL: expected 2 problems on the bare shape, got %d" % len(problems))
        bad += 1
    else:
        print("ok   selftest: bare call is flagged on both counts")

    guard_only = _fixture(before_log=False, before_try=True)
    problems = check(guard_only)
    if problems != ["no log(...) call before the systemctl-restart call inside the loop"]:
        print("SELFTEST FAIL: guard-only fixture did not flag the missing log call on its "
              "own: %r" % (problems,))
        bad += 1
    else:
        print("ok   selftest: try/except alone still flags the missing log call")

    log_only = _fixture(before_log=True, before_try=False)
    problems = check(log_only)
    if problems != ["the systemctl-restart call is not wrapped in a try/except at the "
                    "loop-body level"]:
        print("SELFTEST FAIL: log-only fixture did not flag the missing try/except on "
              "its own: %r" % (problems,))
        bad += 1
    else:
        print("ok   selftest: a prior log call alone still flags the missing try/except")

    fixed = _fixture(before_log=True, before_try=True)
    problems = check(fixed)
    print("--- fixed shape (log before, try/except around) ---")
    if problems:
        print("SELFTEST FAIL: fixed shape still flagged: %r" % (problems,))
        bad += 1
    else:
        print("ok   selftest: fixed shape (log before, try/except around) is clean")

    problems = check("x = 1\n")
    if not problems or "loop found" not in problems[0]:
        print("SELFTEST FAIL: source with no stuck-units loop at all did not report a "
              "unmatched anchor: %r" % (problems,))
        bad += 1
    else:
        print("ok   selftest: a missing loop reports an unmatched anchor, not a false clean")

    if bad:
        print("check-primer-restart-safety selftest: %d failure(s)" % bad)
        return 1
    print("check-primer-restart-safety selftest: seeded regression caught, fixed shape "
          "clean, both guards independently load-bearing")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    try:
        with open(LAUNCHER) as f:
            module_src = f.read()
    except OSError as e:
        print("FAIL: could not read %s: %s" % (LAUNCHER, e))
        return 1
    primer_src = _host_primer_src(module_src)
    if primer_src is None:
        print("FAIL: no `HOST_PRIMER_SRC = \"\"\"...\"\"\"` module-level string assignment "
              "found in %s" % LAUNCHER)
        return 1
    problems = check(primer_src)
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        return 1
    print("check-primer-restart-safety: the pre-flip restart loop logs before, and is "
          "exception-guarded around, each systemctl restart")
    return 0


if __name__ == "__main__":
    sys.exit(main())
