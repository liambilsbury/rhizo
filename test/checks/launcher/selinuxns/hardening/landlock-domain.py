#!/usr/bin/env python3
import ast, contextlib, ctypes, io, os, struct, sys
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-landlock-domain")
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_ns as ns

bad = []
calls, logs, exits = [], [], []


class Exited(Exception):
    """raised in place of os._exit"""


def fake_exit(code):
    """record the exit code and stop the call"""
    exits.append(code)
    raise Exited(code)


def value(a):
    """return a ctypes argument as plain data"""
    if a is None:
        return None
    if hasattr(a, "raw"):
        return bytes(a.raw)
    return a.value


def run(abi=9, create_fd=7, restrict_rc=0):
    """call join_landlock_domain under a stubbed syscall and return what it did"""
    calls.clear(); logs.clear(); exits.clear()

    def fake_syscall(nr, *args):
        """record the syscall and answer the case's values"""
        call = (value(nr),) + tuple(value(a) for a in args)
        calls.append(call)
        if call[0] == 444 and call[3] == 1:
            if abi < 0:
                ctypes.set_errno(95)
            return abi
        if call[0] == 444:
            if create_fd < 0:
                ctypes.set_errno(22)
            return create_fd
        if restrict_rc != 0:
            ctypes.set_errno(1)
        return restrict_rc

    class FakeLibc:
        """stand-in for the libc handle"""
        syscall = staticmethod(fake_syscall)

    saved = (ns._libc, ns.kmsg, os._exit, os.close)
    ns._libc, ns.kmsg, os._exit = FakeLibc, logs.append, fake_exit
    os.close = lambda fd: calls.append(("close", fd))
    try:
        ns.join_landlock_domain()
    except Exited:
        pass
    finally:
        ns._libc, ns.kmsg, os._exit, os.close = saved
    return list(calls)


attr = struct.pack("<QQQ", 0, 0, 1 << 1)
want = [(444, None, 0, 1), (444, attr, 24, 0), (446, 7, 0), ("close", 7)]
got = run()
if got != want or exits:
    bad.append(("domain joined", want, got, exits))
if not any("RHIZO_MARKER selinuxns=landlock-domain abi=9" in l for l in logs):
    bad.append(("success marker", "landlock-domain abi=9", list(logs)))

got = run(abi=5)
if got != [(444, None, 0, 1)] or exits != [1] or not any("selinuxns=refused reason=landlock-abi" in l for l in logs):
    bad.append(("ABI 5", "refused landlock-abi, exit 1, no ruleset", got, exits, list(logs)))

got = run(abi=-1)
if exits != [1] or not any("reason=landlock-abi errno=95" in l for l in logs):
    bad.append(("no Landlock", "refused landlock-abi errno=95", got, exits, list(logs)))

got = run(create_fd=-1)
if exits != [1] or any(c[0] == 446 for c in got) or not any("reason=landlock-create errno=22" in l for l in logs):
    bad.append(("create error", "refused landlock-create, no restrict", got, exits, list(logs)))

got = run(restrict_rc=-1)
if exits != [1] or not any("reason=landlock-restrict errno=1" in l for l in logs):
    bad.append(("restrict error", "refused landlock-restrict errno=1", got, exits, list(logs)))

saved_version = getattr(ns, "landlock_version", None)
ns.landlock_version = lambda: (5, 0)
try:
    got = run(abi=9)
finally:
    if saved_version is not None:
        ns.landlock_version = saved_version
if any(c[0] == 444 and c[3] == 1 for c in got) or exits != [1] \
        or not any("reason=landlock-abi errno=0 abi=5" in l for l in logs):
    bad.append(("one ABI probe", "landlock_version's ABI 5 refused, no version syscall of its own", got, exits,
                list(logs)))
if ns.landlock_abi.__code__.co_names.count("landlock_version") != 1:
    bad.append(("one ABI probe", "landlock_abi reads landlock_version", ns.landlock_abi.__code__.co_names))

tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
fn = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "enter_sandbox_init")
guard = [n for n in fn.body if isinstance(n, ast.If) and ast.unparse(n.test) == "selinux_ns.state()['unshared']"
         and any(ast.unparse(c) == "selinux_ns.join_landlock_domain()" for c in ast.walk(n))]
line_of = {}
for n in ast.walk(fn):
    if isinstance(n, ast.Call):
        line_of.setdefault(ast.unparse(n.func), n.lineno)
joins = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and ast.unparse(n.func) == "selinux_ns.join_landlock_domain"]
if len(guard) != 1 or len(joins) != 1:
    bad.append(("guarded call", "one join_landlock_domain() under if state()['unshared']", len(guard), len(joins)))
elif not (line_of.get("drop_caps", 10**9) < guard[0].lineno < line_of.get("os.execv", -1)):
    bad.append(("call order", "drop_caps < join_landlock_domain < os.execv", line_of.get("drop_caps"),
                guard[0].lineno, line_of.get("os.execv")))
if "NO_NEW_PRIVS" in ast.unparse(fn) or "NO_NEW_PRIVS" in ast.unparse(next(
        n for n in ast.walk(ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read()))
        if isinstance(n, ast.FunctionDef) and n.name == "join_landlock_domain")):
    bad.append(("no_new_privs", "never set on init's path",
                "NO_NEW_PRIVS in enter_sandbox_init or join_landlock_domain"))
ns_tree = ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read())
setters = {f.name for f in ast.walk(ns_tree) if isinstance(f, ast.FunctionDef) and "PR_SET_NO_NEW_PRIVS" in ast.unparse(f)}
callers = {f.name for f in ast.walk(ns_tree) if isinstance(f, ast.FunctionDef)
           and any(isinstance(c, ast.Call) and ast.unparse(c.func) == "_drop_privileges" for c in ast.walk(f))}
if setters != {"_drop_privileges"} or callers != {"_serve_labels"}:
    bad.append(("no_new_privs setters", "_drop_privileges, called by _serve_labels alone", setters, callers))

if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
