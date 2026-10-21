#!/usr/bin/env python3
import ast
import os
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", ".."))
MODULES = ("src/androidd/sandbox/selinux_ns.py", "src/androidd/host/selinux-mode.py", "src/install/prepare/hostops.py",
           "src/services/broker/inbox_stage.py")
ABSENCE = frozenset(("FileNotFoundError", "ProcessLookupError", "ChildProcessError"))
NAMED_SITES = {
    ("src/androidd/sandbox/selinux_ns.py", "_write_done", "OSError"):
        "after the flip the relabeller may not write kmsg; the reader names a lost byte relabeller-eof or -timeout",
    ("src/androidd/sandbox/selinux_ns.py", "_send_label_error", "OSError"):
        "the label service runs in its own domain with no kmsg; the fence drops a closed socket by its reason",
    ("src/androidd/sandbox/selinux_ns.py", "_release_label_service", "OSError"):
        "a service that already left reported its reason on the label socket, which closes when it exits",
    ("src/androidd/sandbox/selinux_ns.py", "host_policy_state", "OSError"):
        "an unreadable enforce node reads unknown, which every caller takes as a host policy, failing closed",
}


def handlers(tree):
    """yield (function, handler) for every except clause"""
    def walk(node, owner):
        """yield the handlers under node with their function"""
        for child in ast.iter_child_nodes(node):
            name = child.name if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) else owner
            if isinstance(child, ast.ExceptHandler):
                yield owner, child
            yield from walk(child, name)
    yield from walk(tree, "<module>")


def calls_nothing(expr):
    """whether an expression holds no call"""
    return expr is None or not any(isinstance(n, ast.Call) for n in ast.walk(expr))


def silent_stmts(body):
    """whether statements only pass, set or return values"""
    for stmt in body:
        if isinstance(stmt, (ast.Pass, ast.Continue, ast.Break)):
            continue
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant):
            continue
        if isinstance(stmt, (ast.Return, ast.Assign, ast.AnnAssign)) and calls_nothing(stmt.value):
            continue
        if isinstance(stmt, ast.If) and calls_nothing(stmt.test) and silent_stmts(stmt.body) \
                and silent_stmts(stmt.orelse):
            continue
        return False
    return True


def carries(body, name):
    """whether statements pass a bound error onward"""
    for stmt in body:
        if isinstance(stmt, ast.If):
            if carries(stmt.body, name) or carries(stmt.orelse, name):
                return True
        elif any(isinstance(n, ast.Name) and n.id == name for n in ast.walk(stmt)):
            return True
    return False


def silent(handler):
    """whether a handler only passes, sets or returns"""
    if handler.name and carries(handler.body, handler.name):
        return False
    return silent_stmts(handler.body)


def caught(expr):
    """return the caught type names"""
    if isinstance(expr, ast.Tuple):
        return [ast.unparse(e).split(".")[-1] for e in expr.elts]
    return [ast.unparse(expr).split(".")[-1]]


def stopwatch(call):
    """whether a call waits on nothing but time"""
    name = ast.unparse(call.func)
    if name.split(".")[-1] == "sleep":
        return True
    if name in ("select.select", "select") and len(call.args) == 4:
        return all(isinstance(a, (ast.List, ast.Tuple)) and not a.elts for a in call.args[:3])
    return (isinstance(call.func, ast.Attribute) and call.func.attr == "wait" and isinstance(call.func.value, ast.Call)
            and ast.unparse(call.func.value.func).split(".")[-1] == "Event")


def sleeps_outside_loops(tree):
    """yield each sleep call no while loop encloses"""
    def walk(node, in_loop):
        """yield the stopwatch sleeps under node"""
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                yield from walk(child, False)
                continue
            if isinstance(child, ast.Call) and not in_loop and stopwatch(child):
                yield child
            yield from walk(child, in_loop or isinstance(child, ast.While))
    yield from walk(tree, False)


def findings(root):
    """return each silent failure in the namespace-mode modules"""
    bad, seen = [], set()
    for rel in MODULES:
        tree = ast.parse(open(os.path.join(root, rel)).read())
        for owner, h in handlers(tree):
            if h.type is None:
                bad.append("%s:%d (%s): a bare except catches every error" % (rel, h.lineno, owner))
                continue
            if not silent(h):
                continue
            types = caught(h.type)
            if set(types) <= ABSENCE:
                continue
            key = (rel, owner, ast.unparse(h.type))
            if key in NAMED_SITES:
                seen.add(key)
                continue
            bad.append("%s:%d (%s): except %s swallows the error without naming it"
                       % (rel, h.lineno, owner, ast.unparse(h.type)))
        for call in (n for n in ast.walk(tree) if isinstance(n, ast.Call)):
            if ast.unparse(call.func).split(".")[-1] == "suppress" and not set(
                    t for a in call.args for t in caught(a)) <= ABSENCE:
                bad.append("%s:%d: suppress(%s) swallows more than an absence"
                           % (rel, call.lineno, ", ".join(ast.unparse(a) for a in call.args)))
        for call in sleeps_outside_loops(tree):
            bad.append("%s:%d: %s waits on a stopwatch, not inside a loop polling a condition"
                       % (rel, call.lineno, ast.unparse(call)))
    for key in sorted(set(NAMED_SITES) - seen):
        bad.append("NAMED_SITES lists %s:%s except %s, which no longer swallows there" % key)
    return bad


def selftest():
    """plant each silent failure in fixture modules"""
    bad = []
    with tempfile.TemporaryDirectory() as root:
        for rel in MODULES:
            os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
            open(os.path.join(root, rel), "w").write("".join(
                "def %s():\n    try:\n        f()\n    except %s:\n        pass\n\n\n" % (fn, typ)
                for where, fn, typ in NAMED_SITES if where == rel))
        if findings(root):
            bad.append("a fixture holding only the named sites was flagged: %s" % findings(root))
        target = os.path.join(root, MODULES[3])
        base = open(target).read()
        cases = (
            ("def m():\n    try:\n        f()\n    except OSError:\n        pass\n",
             "(m): except OSError swallows", True),
            ("def m():\n    try:\n        f()\n    except (OSError, ValueError):\n        return None\n",
             "(m): except (OSError, ValueError) swallows", True),
            ("def m():\n    try:\n        f()\n    except OSError:\n        return 'kernel'\n",
             "(m): except OSError swallows", True),
            ("def m():\n    try:\n        f()\n    except:\n        raise\n", "(m): a bare except", True),
            ("def m():\n    with contextlib.suppress(OSError):\n        f()\n", "suppress(OSError)", True),
            ("def m():\n    time.sleep(2)\n", "time.sleep(2) waits on a stopwatch", True),
            ("def m():\n    try:\n        f()\n    except FileNotFoundError:\n        pass\n", "(m)", False),
            ("def m():\n    with contextlib.suppress(FileNotFoundError):\n        f()\n", "suppress(", False),
            ("def m():\n    while not ready():\n        time.sleep(0.01)\n", "time.sleep(0.01)", False),
            ("def m():\n    try:\n        f()\n    except OSError:\n        return -1\n", "(m): except OSError", True),
            ("def m():\n    try:\n        f()\n    except OSError:\n        return []\n", "(m): except OSError", True),
            ("def m():\n    try:\n        f()\n    except OSError:\n        return KERNEL\n", "(m): except OSError",
             True),
            ("def m():\n    try:\n        f()\n    except OSError:\n        v = 'kernel'\n", "(m): except OSError",
             True),
            ("def m():\n    try:\n        f()\n    except OSError:\n        ...\n", "(m): except OSError", True),
            ("def m():\n    try:\n        f()\n    except OSError as e:\n        if e.errno:\n            pass\n"
             "        return 'kernel'\n", "(m): except OSError", True),
            ("def m():\n    try:\n        f()\n    except OSError:\n        return describe()\n", "(m)", False),
            ("def m():\n    try:\n        f()\n    except OSError as e:\n        return f'load:{e.errno}'\n", "(m)",
             False),
            ("def m():\n    select.select([], [], [], 2)\n", "select.select([], [], [], 2) waits", True),
            ("def m():\n    threading.Event().wait(2)\n", "threading.Event().wait(2) waits", True),
            ("def m():\n    select.select([fd], [], [], 2)\n", "select.select([fd]", False),
            ("def m():\n    try:\n        f()\n    except OSError as e:\n        log(e)\n", "(m)", False),
        )
        for planted, finding, flagged in cases:
            open(target, "w").write(base + "\n\n" + planted)
            got = any(finding in b for b in findings(root))
            if got != flagged:
                bad.append("%r was %s" % (planted, "missed" if flagged else "flagged"))
        open(target, "w").write(base)
        sel = os.path.join(root, MODULES[0])
        text = open(sel).read()
        open(sel, "w").write(text.replace("def _send_label_error():", "def _send_label_error_renamed():", 1))
        if not any("_send_label_error except OSError, which no longer swallows" in b for b in findings(root)):
            bad.append("a named site that moved away was not reported")
    if bad:
        for b in bad:
            print("FAIL selftest: %s" % b, file=sys.stderr)
        return 1
    print("silent-failures selftest: a swallowing handler, a bare except, a broad suppress and a stopwatch sleep "
          "are flagged; an absence, a logged error and a polling loop pass")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = findings(ROOT)
    for b in bad:
        print("FAIL: %s" % b, file=sys.stderr)
    if bad:
        return 1
    print("silent-failures: the namespace-mode modules swallow no error and wait on no stopwatch")
    return 0


if __name__ == "__main__":
    sys.exit(main())
