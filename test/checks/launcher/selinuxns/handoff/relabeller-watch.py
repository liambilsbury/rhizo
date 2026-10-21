#!/usr/bin/env python3
import ast, contextlib, io, os, select, signal, sys, time
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-relabeller-watch")
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_ns as ns

bad = []
logs = []
ns.kmsg = logs.append


def watch(payload, close_writer, now, deadline=100.0, exiting=None):
    """call check_relabeller_done once on a real pipe"""
    logs.clear()
    kills = []
    r, w = os.pipe()
    if payload:
        os.write(w, payload)
    if close_writer:
        os.close(w)
    try:
        more = {} if exiting is None else {"init_exiting": lambda: exiting}
        got = ns.check_relabeller_done(r, deadline, lambda: kills.append("kill"), now=lambda: now, **more)
    finally:
        os.close(r)
        if not close_writer:
            os.close(w)
    return got, kills, [l for l in logs if "RHIZO_MARKER" in l]


cases = [
    ("byte 1 before the deadline", (b"1", False, 10.0), ("enforced", [], [])),
    ("byte p before the deadline", (b"p", False, 10.0), ("permissive", [], [])),
    ("nothing yet, before the deadline", (b"", False, 10.0), ("pending", [], [])),
    ("eof", (b"", True, 10.0), ("eof", ["kill"], ["RHIZO_MARKER selinuxns=refused reason=relabeller-eof"])),
    ("timeout", (b"", False, 100.0), ("timeout", ["kill"], ["RHIZO_MARKER selinuxns=refused reason=relabeller-timeout"])),
    ("failure byte", (b"f", True, 10.0), ("failed", ["kill"], ["RHIZO_MARKER selinuxns=refused reason=relabeller-failed"])),
    ("unknown byte", (b"x", False, 10.0), ("failed", ["kill"], ["RHIZO_MARKER selinuxns=refused reason=relabeller-failed"])),
    ("byte 1 after the deadline still counts", (b"1", False, 500.0), ("enforced", [], [])),
    ("eof while init is exiting", (b"", True, 10.0, 100.0, True), ("pending", [], [])),
    ("eof while init lives", (b"", True, 10.0, 100.0, False),
     ("eof", ["kill"], ["RHIZO_MARKER selinuxns=refused reason=relabeller-eof"])),
    ("failure byte with a reason", (b"fenforce-failed:before=0,after=0\n", True, 10.0),
     ("failed", ["kill"], ["RHIZO_MARKER selinuxns=relabeller-error reason=enforce-failed:before=0,after=0",
                           "RHIZO_MARKER selinuxns=refused reason=relabeller-failed"])),
    ("failure byte with an unsafe reason", (b"fa b\x1b[0m\"\n", True, 10.0),
     ("failed", ["kill"], ["RHIZO_MARKER selinuxns=relabeller-error reason=a_b__0m_",
                           "RHIZO_MARKER selinuxns=refused reason=relabeller-failed"])),
    ("failure byte with a reason cut at 200 bytes", (b"f" + b"x" * 500, False, 10.0),
     ("failed", ["kill"], ["RHIZO_MARKER selinuxns=relabeller-error reason=" + "x" * 200,
                           "RHIZO_MARKER selinuxns=refused reason=relabeller-failed"])),
    ("failure byte while init is exiting", (b"f", True, 10.0, 100.0, True),
     ("failed", ["kill"], ["RHIZO_MARKER selinuxns=refused reason=relabeller-failed"])),
]
for name, args, want in cases:
    got = watch(*args)
    if got != want:
        bad.append((name, want, got))

for name, payload, want_state, want_reasons in (
        ("nothing waiting", b"", "pending", []), ("byte 1", b"1", "enforced", []), ("byte p", b"p", "permissive", []),
        ("failure byte", b"f", "failed", []), ("failure byte with a reason", b"fraised:X\n", "failed", ["raised:X"]),
        ("unknown byte", b"x", "pending", [])):
    r, w = os.pipe()
    if payload:
        os.write(w, payload)
    reasons = []
    logs.clear()
    got = ns.read_done_now(r, reasons)
    os.close(r)
    os.close(w)
    if (got, reasons) != (want_state, want_reasons):
        bad.append(("read_done_now", name, (want_state, want_reasons), (got, reasons)))

r, w = os.pipe()
os.write(w, b"fenforce-failed:late\n")
reasons = []
logs.clear()
got = ns.read_done_now(r, reasons)
os.close(r)
os.close(w)
if (got, reasons) != ("failed", ["enforce-failed:late"]):
    bad.append(("late failure byte", ("failed", ["enforce-failed:late"]), (got, reasons)))

for name, reason in (("newline and escape", "a\nb\x1b[0m"), ("quotes and spaces", "it's \"x\" y"),
                     ("long", "y" * 500), ("non-ascii", "caf\u00e9 \u2603"), ("safe", "enforce-failed:before=0,after=1")):
    r, w = os.pipe()
    ns._write_done(w, ns.failed(reason))
    os.close(w)
    first = os.read(r, 1)
    reasons = []
    ns.read_failure_reason(r, reasons)
    os.close(r)
    want = ns.clean_reason(reason.encode())
    if first != ns.DONE_FAILED or reasons != ([want] if want else []) or ns.clean_reason(want.encode()) != want \
            or len(want) > ns.REASON_MAX or not all(c.isalnum() or c in "_.:=,/@-" for c in want):
        bad.append(("writer then reader", name, want, reasons))

logs.clear()
r, w = os.pipe()
os.close(w)


def raising_kill():
    """raise as a pidfd signal to a reaped process does"""
    raise ProcessLookupError(3, "No such process")


got = ns.check_relabeller_done(r, 100.0, raising_kill, now=lambda: 0.0)
os.close(r)
if got != "eof" or not any("reason=relabeller-eof" in l for l in logs):
    bad.append(("raising kill", "eof and the marker", got, list(logs)))

src = open(os.path.join(LAUNCHER, "boot.py")).read()
for needle, why in [
    ('_done_r, _done_w = os.pipe2(os.O_CLOEXEC) if not host_selinux_mode() and not _handoff_to else (-1, -1)',
     "close-on-exec pipe, namespace-mode cold start only"),
    ("core.set_relabeller_done_fd(_done_w)", "the write end handed to gg"),
    ("if _done_w >= 0:\n            os.close(_done_w)", "g closes its write end"),
    ('None if _booted and _relabel != "pending" else 0.5', "g keeps polling while the relabeller is pending"),
    ("selinux_ns.check_relabeller_done(", "g polls the done pipe"),
    ('os._exit(selinux_ns.RELABELLER_REFUSED_EXIT if _relabel in ("eof", "timeout", "failed") else 0)',
     "g exits with the refusal code"),
    ("os.WEXITSTATUS(_g_status) == selinux_ns.RELABELLER_REFUSED_EXIT)", "the start is refused"),
    ('record_refusal_unless_final(f"g-{wait_status_word(_g_status)}")\n        refuse_start()', "the start is refused"),
]:
    if needle not in src:
        bad.append(("launcher wiring", why, needle))
run_sandbox = next(n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == "run_sandbox")
polls = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If) and ast.unparse(n.test) == "_relabel == 'pending'"
         and "check_relabeller_done" in ast.unparse(n)]
if len(polls) != 1:
    bad.append(("g's poll", "one if _relabel == 'pending' calling check_relabeller_done", len(polls)))
else:
    poll = compile(ast.Module(body=polls, type_ignores=[]), "boot.py", "exec")
    for answer, want in (("enforced", [("record_verdict", "enforced", 7), ("record_android_enforce", "1", 7)]),
                         ("permissive", [("record_verdict", "permissive", 7)]), ("pending", [])):
        seen = []

        class PollNs:
            """selinux_ns stand-in answering the poll and recording the writes"""
            check_relabeller_done = staticmethod(lambda fd, deadline, kill, init_exiting=None, reasons=None: answer)
            record_verdict = staticmethod(lambda v, d: seen.append(("record_verdict", v, d)))
            record_android_enforce = staticmethod(lambda v, d: seen.append(("record_android_enforce", v, d)))

        scope = {"_relabel": "pending", "selinux_ns": PollNs, "_done_r": 5, "_done_deadline": 0.0,
                 "_verdict_dir": 7, "_first_w": -1, "_gg_fd": 9, "_signal": None, "os": os, "kmsg": logs.append,
                 "_fail_reasons": []}
        exec(poll, scope)
        if seen != want or scope["_relabel"] != answer:
            bad.append(("g's poll", answer, want, seen))


def init_like(sig=None, code=0, after=0.2, done_w=-1):
    """fork a stand-in init that exits or kills itself after a delay"""
    pid = os.fork()
    if pid == 0:
        try:
            time.sleep(after)
            if sig:
                os.kill(os.getpid(), sig)
        finally:
            os._exit(code)
    return pid


if len(polls) == 1:
    for label, sig, code, writer, want, want_end in (
            ("init killed by a signal before the flip", signal.SIGTERM, 0, "init", "pending", ("signal", signal.SIGTERM)),
            ("init exits 1 before the flip", None, 1, "init", "pending", ("exit", 1)),
            ("relabeller dies while init lives", None, 0, "relabeller", "eof", ("signal", signal.SIGKILL))):
        logs.clear()
        if writer == "init":
            r, w = os.pipe()
            gg = init_like(sig, code, 0.2, w)
        else:
            gg = init_like(sig, code, 30)
            r, w = os.pipe()
            relabeller = init_like(None, 1, 0.2, w)
        os.close(w)
        gg_fd = os.pidfd_open(gg)
        select.select([r], [], [], 30)
        scope = {"_relabel": "pending", "selinux_ns": ns, "_done_r": r, "_done_deadline": time.time() + 30,
                 "_verdict_dir": -1, "_first_w": -1, "_gg_fd": gg_fd, "_signal": signal, "os": os, "kmsg": logs.append,
                 "_fail_reasons": []}
        exec(poll, scope)
        _, status = os.waitpid(gg, 0)
        if writer != "init":
            os.waitpid(relabeller, 0)
        os.close(gg_fd)
        os.close(r)
        end = ("signal", os.WTERMSIG(status)) if os.WIFSIGNALED(status) else ("exit", os.WEXITSTATUS(status))
        if scope["_relabel"] != want or end != want_end:
            bad.append(("g's poll on a closed done pipe", label, want, want_end, scope["_relabel"], end, list(logs)))

logs.clear()
r, w = os.pipe()
os.close(w)
slow = init_like(None, 0, 3.0)
slow_fd = os.pidfd_open(slow)
kills = []
got = ns.check_relabeller_done(r, time.time() + 30, lambda: kills.append("kill"),
                               init_exiting=lambda: ns.wait_pidfd_exit(slow_fd))
os.waitpid(slow, 0)
os.close(slow_fd)
os.close(r)
if got != "pending" or kills:
    bad.append(("a 3 s pid-namespace teardown", "pending, init left alive", got, kills, list(logs)))
mounts = open(os.path.join(LAUNCHER, "sandbox/rootfs.py")).read()
if "core.RELABELLER_DONE_FD)" not in mounts:
    bad.append(("rootfs wiring", "start_relabeller gets core.RELABELLER_DONE_FD", ""))

tree = ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read())
start = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == "start_relabeller")
closes = [n for n in ast.walk(start) if isinstance(n, ast.Call) and getattr(n.func, "id", "") == "_close_inherited_fds"]
if not closes or "done_fd" not in ast.unparse(closes[0]):
    bad.append(("relabeller keeps the done fd", "_close_inherited_fds({... done_fd})", [ast.unparse(c) for c in closes]))

r, w = os.pipe()
keep_a, drop_a, drop_b = os.open("/dev/null", os.O_RDONLY), os.open("/dev/null", os.O_RDONLY), os.dup(r)
pid = os.fork()
if pid == 0:
    try:
        ns._close_inherited_fds({keep_a, w})
        alive = []
        for fd in (0, 1, 2, r, keep_a, drop_a, drop_b):
            try:
                os.fstat(fd)
                alive.append(str(fd))
            except OSError:
                pass
        os.write(w, " ".join(alive + [str(w)]).encode())
    finally:
        os._exit(0)
os.close(w)
seen = set(int(x) for x in os.read(r, 4096).decode().split())
os.waitpid(pid, 0)
for fd in (r, keep_a, drop_a, drop_b):
    os.close(fd)
if not {0, 1, 2, keep_a, w} <= seen or seen & {drop_a, drop_b, r}:
    bad.append(("closed inherited fds", f"kept 0-2, {keep_a}, {w}; closed {drop_a}, {drop_b}, {r}", sorted(seen)))

if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
