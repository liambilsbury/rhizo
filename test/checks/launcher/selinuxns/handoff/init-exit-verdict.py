#!/usr/bin/env python3
import ast, contextlib, io, os, signal, sys, tempfile, time
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-init-exit-verdict")
os.environ.pop("RHIZO_SELINUX_MODE", None)
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
from sandbox import selinux_ns as ns

bad = []
logs = []
ns.kmsg = logs.append
launcher.kmsg = logs.append


def records(dfd):
    """return the records dir's verdict and Android's enforce state"""
    names = [os.path.basename(p) for p in (ns.VERDICT_FILE, ns.ANDROID_ENFORCE_FILE)]
    out = []
    for n in names:
        try:
            out.append(open(f"/proc/self/fd/{dfd}/{n}").read().strip())
        except OSError:
            out.append(None)
    return out


for label, code, sig, stopping, want in (
        ("init exits 0 before the flip (InitFatalReboot, no CAP_SYS_BOOT)", 0, None, False,
         "refused:init-exited-before-flip-status-0"),
        ("init exits 3 before the flip", 3, None, False, "refused:init-exited-before-flip-status-3"),
        ("the handoff's pid 1 refusing init-groups exits 1 before the exec", 1, None, False,
         "refused:init-exited-before-flip-status-1"),
        ("init killed by SIGKILL before the flip with no stop requested", None, signal.SIGKILL, False,
         "refused:init-killed-before-flip-signal-9"),
        ("init killed by SIGKILL before the flip after a recorded stop request (the stop's fallback)", None,
         signal.SIGKILL, True, "stopped"),
        ("init exits 0 before the flip after a recorded stop request", 0, None, True, "stopped"),
        ("init exits 2 before the flip after a recorded stop request", 2, None, True,
         "refused:init-exited-before-flip-status-2")):
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(r)
            time.sleep(0.2)
            if sig:
                os.kill(os.getpid(), sig)
        finally:
            os._exit(code or 0)
    os.close(w)
    calls = []
    try:
        extra = {"stop_requested": lambda: True} if stopping else {}
        got, _status = ns.watch_handed_off_init(pid, r, time.time() + 30, calls.append, **extra)
    except TypeError as e:
        os.waitpid(pid, 0)
        got = f"<{e}>"
    os.close(r)
    if got != want or (not got.startswith("<") and calls != [want]):
        bad.append(("watch_handed_off_init", label, want, got, calls))

missing = [n for n in ("record_stop_request", "stop_requested", "clear_stop_request", "init_exit_refusal")
           if not callable(getattr(ns, n, None))]
if missing:
    bad.append(("selinux_ns helpers missing", missing))
else:
    with tempfile.TemporaryDirectory() as tmp:
        dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
        try:
            if ns.stop_requested(dfd) or ns.stop_requested(-1):
                bad.append(("stop_requested with no record", False, True))
            ns.record_stop_request(tmp)
            if not ns.stop_requested(dfd):
                bad.append(("stop_requested after record_stop_request", True, False))
            launcher.reset_namespace_start_records(tmp)
            if ns.stop_requested(dfd):
                bad.append(("a start's reset clears the stop request", False, True))
            if records(dfd) != ["pending", "0"]:
                bad.append(("a start's reset", ["pending", "0"], records(dfd)))
            ns.record_start_end(ns.verdict_for("failed", ns.init_exit_refusal(0, False)), dfd)
            if records(dfd) != ["refused:init-exited-before-flip-status-0", "0"]:
                bad.append(("end record of an init exit 0 before the flip",
                            ["refused:init-exited-before-flip-status-0", "0"], records(dfd)))
        finally:
            os.close(dfd)

ltree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
funcs = {n.name: n for n in ltree.body if isinstance(n, ast.FunctionDef)}
run_sandbox = funcs["run_sandbox"]
tries = [t for t in ast.walk(run_sandbox) if isinstance(t, ast.Try)
         and any("g died post-pivot" in ast.unparse(h) for h in t.handlers)]
exits = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.Expr) and "RELABELLER_REFUSED_EXIT" in ast.unparse(n)]
if len(tries) != 1 or len(exits) != 1:
    bad.append(("g's wait", "one 'g died post-pivot' try and one refusal exit", len(tries), len(exits)))
else:
    gtry = tries[0]
    loop = next(i for i, n in enumerate(gtry.body) if isinstance(n, ast.While))
    tail = compile(ast.Module(body=gtry.body[loop + 1:], type_ignores=[]), "boot.py", "exec")
    exit_expr = compile(ast.Expression(body=exits[0].value.args[0]), "boot.py", "eval")

    class WaitOs:
        """os stand-in answering the status helpers"""
        WIFEXITED, WEXITSTATUS = staticmethod(os.WIFEXITED), staticmethod(os.WEXITSTATUS)
        WIFSIGNALED, WTERMSIG = staticmethod(os.WIFSIGNALED), staticmethod(os.WTERMSIG)

    for label, status, stopping, want_relabel, want_why, want_code in (
            ("gg exits 0 before the flip", 0, False, "failed", "init-exited-before-flip-status-0", 3),
            ("gg exits 1 before the flip, as an init-groups refusal does", 1 << 8, False, "failed",
             "init-exited-before-flip-status-1", 3),
            ("gg killed by SIGKILL before the flip with no stop requested", signal.SIGKILL, False, "failed",
             "init-killed-before-flip-signal-9", 3),
            ("gg killed by SIGKILL before the flip after a recorded stop request", signal.SIGKILL, True, "pending", "",
             0),
            ("gg exits 0 before the flip after a recorded stop request", 0, True, "pending", "", 0)):
        with tempfile.TemporaryDirectory() as tmp:
            dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
            try:
                if stopping:
                    try:
                        ns.record_stop_request(tmp)
                    except AttributeError as e:
                        bad.append(("g's wait", label, f"<{e}>"))
                logs.clear()

                class LateNs:
                    """selinux_ns stand-in with no done byte waiting"""
                    read_done_now = staticmethod(lambda fd, reasons=None: "pending")
                    stop_requested = staticmethod(getattr(ns, "stop_requested", lambda fd: False))
                    init_exit_refusal = staticmethod(getattr(ns, "init_exit_refusal", lambda status, stop: "<missing>"))

                scope = {"_done_r": 5, "_relabel": "pending", "_why": "", "_fail_reasons": [], "_ns_handoff": False,
                         "_sandbox_kills": [], "d": (4242, status),
                         "_verdict_dir": dfd, "os": WaitOs, "selinux_ns": LateNs, "kmsg": logs.append}
                try:
                    exec(tail, scope)
                except Exception as e:
                    bad.append(("g's wait", label, "raised", repr(e)))
                    continue
            finally:
                os.close(dfd)
        code = eval(exit_expr, {"_relabel": scope["_relabel"], "selinux_ns": ns})
        mark = ("selinuxns=refused reason=" + (f"init-exited-before-flip status={os.WEXITSTATUS(status)}"
                                                if os.WIFEXITED(status)
                                                else f"init-killed-before-flip signal={os.WTERMSIG(status)}"))
        marked = any(mark in l for l in logs)
        if (scope["_relabel"], scope["_why"], code) != (want_relabel, want_why, want_code) \
                or marked != (want_code == 3):
            bad.append(("g's wait", label, (want_relabel, want_why, want_code), (scope["_relabel"], scope["_why"], code),
                        list(logs)))

stop = funcs["androidd_stop"]
ns_branch = [n for n in ast.walk(stop) if isinstance(n, ast.If) and ast.unparse(n.test) == "not host_selinux_mode()"
             and "probe-client.py" in ast.unparse(n)]
if len(ns_branch) != 1:
    bad.append(("androidd_stop", "one namespace-mode branch sending the probe's setprop", len(ns_branch)))
else:
    text = ast.unparse(ns_branch[0])
    rec, probe = text.find("record_stop_request("), text.find("probe-client.py")
    if rec < 0 or rec > probe:
        bad.append(("androidd_stop records the stop request before the probe's setprop sys.powerctl", rec, probe))
    if "record_stop_request" in ast.unparse(stop.body) and "record_stop_request" not in text:
        bad.append(("androidd_stop records the stop request outside namespace mode",))

joins = [n for n in ast.walk(ltree) if isinstance(n, ast.Call) and ast.unparse(n.func).endswith("watch_handed_off_init")]
if len(joins) != 1 or not any(k.arg == "stop_requested" and "records_fd" in ast.unparse(k.value)
                              for k in joins[0].keywords):
    bad.append(("the joiner passes stop_requested over records_fd to watch_handed_off_init",
                [ast.unparse(j) for j in joins]))

for b in bad:
    print("FAIL", b)
if bad:
    sys.exit(1)
print("ok: an init exit or kill before any verdict refuses the start naming its status or signal on both paths; a "
      "recorded stop request keeps a graceful exit or the stop's kill stopped, and each start clears the request")
