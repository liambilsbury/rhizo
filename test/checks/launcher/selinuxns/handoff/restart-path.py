#!/usr/bin/env python3
import re
import ast, contextlib, inspect, io, json, os, signal, subprocess, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-restart-path")
os.environ.pop("RHIZO_SELINUX_MODE", None)
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
from sandbox import rootfs
from sandbox import selinux_ns as ns

bad = []


def knobs(mode):
    """return core's resident knobs under mode"""
    env = {k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"}
    env.update(RHIZO_RESIDENT_G="1", RHIZO_RESIDENT_DISPATCH="1")
    if mode is not None:
        env["RHIZO_SELINUX_MODE"] = mode
    code = "import sys; sys.path.insert(0, sys.argv[1]); from sandbox import core as e; print('KNOBS', e.RHIZO_RESIDENT_G, e.RHIZO_RESIDENT_DISPATCH)"
    out = subprocess.run([sys.executable, "-c", code, LAUNCHER], env=env, capture_output=True, text=True, timeout=60)
    lines = [l for l in out.stdout.splitlines() if l.startswith("KNOBS ")]
    return lines[-1][6:] if lines else f"<rc={out.returncode} {out.stderr.strip()[-300:]}>"


for mode, want in ((None, "True True"), ("namespace", "True True"), ("host", "True True")):
    got = knobs(mode)
    if got != want:
        bad.append((f"resident knobs, RHIZO_SELINUX_MODE={mode}", want, got))

mtree = ast.parse(open(os.path.join(LAUNCHER, "sandbox/rootfs.py")).read())
setup = next(n for n in mtree.body if isinstance(n, ast.FunctionDef) and n.name == "_setup_cgroups_and_selinuxfs")
guards = [n for n in setup.body if isinstance(n, ast.If) and "start_relabeller" in ast.unparse(n)]
if len(guards) != 1:
    bad.append(("relabeller guard", "one start_relabeller guard in _setup_cgroups_and_selinuxfs", len(guards)))
guard = compile(ast.Module(body=guards[:1], type_ignores=[]), "sandbox/rootfs.py", "exec")


def start_once(mode, unshare_first, tmp, context="kernel", pid_max_ok=True):
    """fork a stand-in gg and run its namespace steps under stubs"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        rc = 2
        try:
            def note(*ev):
                """send an event to the parent"""
                os.write(w, (json.dumps(ev) + "\n").encode())

            def unshare(state_file=None):
                """record the unshare and mark this process unshared"""
                note("unshare_namespace")
                ns._STATE["unshared"] = True

            def execv(path, argv):
                """record the exec and leave as a successful exec would"""
                note("execv", path, argv[1])
                os._exit(0)

            os.environ["RHIZO_SELINUX_MODE"] = mode
            ns.unshare_namespace = unshare
            ns.host_context = lambda: context
            ns.kmsg = lambda m: note("kmsg", m)
            ns.mount = lambda *a: True
            ns.join_landlock_domain = lambda: note("join_landlock_domain")
            ns.start_relabeller = lambda *a: note("start_relabeller", a[0], a[2], a[3])

            class FakeLibc:
                """umount2 that finds nothing mounted"""
                umount2 = staticmethod(lambda *a: -1)

            ns.libc = FakeLibc
            rootfs.NEWROOT = tmp
            launcher.kmsg = lambda m: note("kmsg", m)
            launcher.cap_pid_namespace_pid_max = lambda: note("cap_pid_namespace_pid_max") or pid_max_ok
            launcher.setup_net_core_sysctls = lambda: note("setup_net_core_sysctls")
            launcher.install_handle_filter = lambda: note("install_handle_filter") or True
            launcher.drop_caps = lambda: note("drop_caps")
            launcher.phase = lambda *a: None
            launcher.policy_is_loaded = lambda: False
            os.setgroups = lambda groups: note("setgroups", list(groups))
            os.execv = execv
            env_stub = type("E", (), {"WRITE_PRIMER_SCRIPT": "writer", "RELABELLER_DONE_FD": 9})
            if unshare_first:
                rootfs.unshare_root_namespace(mode, False)
                rootfs.mount_sandbox_selinuxfs(mode)
                exec(guard, {"selinux_ns": ns, "core": env_stub, "NEWROOT": tmp, "holder": False,
                             "coldboot_primer_spec": lambda: ["spec"]})
            launcher.enter_sandbox_init("second_stage", own_proc_sys=unshare_first)
        except BaseException as e:
            os.write(w, (json.dumps(["raised", repr(e)]) + "\n").encode())
        os._exit(rc)
    os.close(w)
    data = b""
    while True:
        chunk = os.read(r, 65536)
        if not chunk:
            break
        data += chunk
    os.close(r)
    _, status = os.waitpid(pid, 0)
    events = [json.loads(l) for l in data.decode().splitlines()]
    return events, os.waitstatus_to_exitcode(status)


def calls(events):
    """return the event names and selinuxns markers"""
    out = []
    for ev in events:
        if ev[0] == "kmsg":
            if "selinuxns=refused" in ev[1] or "selinuxns=selinuxfs" in ev[1]:
                out.append(ev[1].split(" ", 1)[1].split(" enforce=")[0])
            continue
        out.append(ev[0])
    return out


with tempfile.TemporaryDirectory() as tmp:
    want = ["unshare_namespace", "selinuxns=selinuxfs", "start_relabeller", "cap_pid_namespace_pid_max",
            "setup_net_core_sysctls", "install_handle_filter", "setgroups", "drop_caps", "join_landlock_domain",
            "execv"]
    events, rc = start_once("namespace", True, tmp)
    if calls(events) != want or rc != 0:
        bad.append(("namespace start", want, calls(events), rc))
    rel = [e for e in events if e[0] == "start_relabeller"]
    if rel != [["start_relabeller", tmp, "writer", 9]]:
        bad.append(("namespace start relabeller args", tmp, rel))

    events, rc = start_once("namespace", True, tmp, context="u:r:kernel:s0")
    want = ["unshare_namespace", "selinuxns=selinuxfs", "start_relabeller", "selinuxns=refused reason=namespace-policy-loaded"]
    if calls(events) != want or rc != 1:
        bad.append(("namespace policy already loaded", want, calls(events), rc))

    events, rc = start_once("namespace", True, tmp, pid_max_ok=False)
    want = ["unshare_namespace", "selinuxns=selinuxfs", "start_relabeller", "cap_pid_namespace_pid_max",
            "selinuxns=refused reason=pid-max-unset"]
    if calls(events) != want or rc != 1:
        bad.append(("namespace pid_max unset", want, calls(events), rc))

    events, rc = start_once("namespace", False, tmp)
    want = ["selinuxns=refused reason=init-outside-namespace"]
    if calls(events) != want or rc != 1:
        bad.append(("namespace init never unshared", want, calls(events), rc))

    events, rc = start_once("host", False, tmp)
    want = ["install_handle_filter", "setgroups", "drop_caps", "execv"]
    if calls(events) != want or rc != 0:
        bad.append(("host handoff init", want, calls(events), rc))

ltree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
run_sandbox = next(n for n in ltree.body if isinstance(n, ast.FunctionDef) and n.name == "run_sandbox")
handlers = [h for t in ast.walk(run_sandbox) if isinstance(t, ast.Try) for h in t.handlers
            if "g died post-pivot" in ast.unparse(h)]
exits = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.Expr) and "RELABELLER_REFUSED_EXIT" in ast.unparse(n)]
if len(handlers) != 1 or len(exits) != 1:
    bad.append(("g exception path", "one 'g died post-pivot' handler and one refusal exit", len(handlers), len(exits)))
else:
    body = compile(ast.Module(body=handlers[0].body, type_ignores=[]), "boot.py", "exec")
    exit_expr = compile(ast.Expression(body=exits[0].value.args[0]), "boot.py", "eval")
    ends = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If)
            and ast.unparse(n.test).startswith("_verdict_dir >= 0 and (not _ns_handoff)")]
    end_code = compile(ast.Module(body=ends[:1], type_ignores=[]), "boot.py", "exec")
    for relabel, gg_fd, gg_exited, done_r, ns_handoff, want_sent, want_why, want_end in (
            ("pending", 7, False, 5, False, [("pidfd", 7)], "relabeller-watcher-raised",
             ["refused:relabeller-watcher-raised"]),
            ("pending", None, False, 5, False, [("kill", 4242)], "relabeller-watcher-raised",
             ["refused:relabeller-watcher-raised"]),
            ("none", 7, False, 5, False, [("pidfd", 7)], "g-raised-RuntimeError", ["refused:g-raised-RuntimeError"]),
            ("none", 7, False, -1, False, [], "", ["stopped"]),
            ("none", 7, False, 5, True, [], "", []),
            ("enforced", 7, False, 5, False, [("pidfd", 7), ("wait", 4242)], "", ["enforced"]),
            ("permissive", 7, False, 5, False, [("pidfd", 7), ("wait", 4242)], "", ["permissive"]),
            ("enforced", 7, True, 5, False, [], "", ["enforced"])):
        sent, logs, recorded = [], [], []

        class FakeSignal:
            """signal stand-in recording what is sent"""
            SIGKILL = signal.SIGKILL
            pidfd_send_signal = staticmethod(lambda fd, s: sent.append(("pidfd", fd)))

        class FakeOs:
            """os stand-in recording kills and waits"""
            kill = staticmethod(lambda p, s: sent.append(("kill", p)))

            @staticmethod
            def waitpid(p, flags):
                """record the wait and answer a killed status"""
                sent.append(("wait", p))
                return p, signal.SIGKILL

        class EndNs:
            """selinux_ns stand-in recording the end record"""
            verdict_for = staticmethod(ns.verdict_for)
            record_start_end = staticmethod(lambda v, d: recorded.append(v))

        scope = {"kmsg": logs.append, "_e": RuntimeError("boom"), "_relabel": relabel, "gg": 4242, "_why": "",
                 "_gg_exited": gg_exited, "signal": FakeSignal, "_signal": FakeSignal, "os": FakeOs,
                 "selinux_ns": ns, "_done_r": done_r, "_ns_handoff": ns_handoff}
        if gg_fd is not None:
            scope["_gg_fd"] = gg_fd
        exec(body, scope)
        code = eval(exit_expr, {"_relabel": scope["_relabel"], "selinux_ns": ns})
        refused = any(f"selinuxns=refused reason={want_why}" in l for l in logs) if want_why else \
            not any("selinuxns=refused" in l for l in logs)
        why = scope.get("_why")
        exec(end_code, dict(scope, _verdict_dir=5, selinux_ns=EndNs))
        want_code = ns.RELABELLER_REFUSED_EXIT if want_why else 0
        if sent != want_sent or not refused or code != want_code or recorded != want_end or why != want_why:
            bad.append((f"g raised, relabel={relabel} gg_fd={gg_fd} gg_exited={gg_exited} done_r={done_r} "
                        f"ns_handoff={ns_handoff}", want_sent, want_why, want_end, sent, logs, code, why, recorded))


def parked_looking_child(tmp):
    """start a stand-in parked boot.py supervisor"""
    path = os.path.join(tmp, "boot.py")
    with open(path, "w") as f:
        f.write("import signal, time\nsignal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM})\n"
                "print('up', flush=True)\ntime.sleep(60)\n")
    child = subprocess.Popen([sys.executable, path], stdout=subprocess.PIPE, text=True)
    child.stdout.readline()
    return child


def handoff_target(mode, pid_file, script):
    """evaluate g's _handoff_to expression in a fresh launcher run as script"""
    env = {k: v for k, v in os.environ.items() if k != "RHIZO_SELINUX_MODE"}
    env.update(RHIZO_RESIDENT_G="1", RHIZO_RESIDENT_DISPATCH="1", RHIZO_SELINUX_MODE=mode)
    code = r"""
import ast, contextlib, io, os, sys
sys.path.insert(0, sys.argv[1])
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
src = open(os.path.join(sys.argv[1], "boot.py")).read()
sys.argv[0] = sys.argv[3]
fn = next(n for n in ast.parse(src).body if isinstance(n, ast.FunctionDef) and n.name == "run_sandbox")
exprs = [n.value for n in ast.walk(fn) if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "_handoff_to" for t in n.targets) and "await_resident_g" in ast.unparse(n.value)]
assert len(exprs) == 1, len(exprs)
launcher.G_PID_FILE = sys.argv[2]
launcher.kmsg = lambda m: None
launcher.time.sleep = lambda s: None
print("HANDOFF", eval(compile(ast.Expression(body=exprs[0]), "boot.py", "eval"), vars(launcher)))
"""
    out = subprocess.run([sys.executable, "-c", code, LAUNCHER, pid_file, script], env=env, capture_output=True,
                         text=True, timeout=60)
    lines = [l for l in out.stdout.splitlines() if l.startswith("HANDOFF ")]
    return lines[-1][8:] if lines else f"<rc={out.returncode} {out.stderr.strip()[-300:]}>"


with tempfile.TemporaryDirectory() as tmp:
    child = parked_looking_child(tmp)
    try:
        pid_file = os.path.join(tmp, "g_pid")
        for mode, want in (("namespace", str(child.pid)), ("host", str(child.pid))):
            saved_mode = os.environ.get("RHIZO_SELINUX_MODE")
            os.environ["RHIZO_SELINUX_MODE"] = mode
            try:
                with open(pid_file, "w") as f:
                    f.write(launcher.supervisor_record(child.pid))
            finally:
                if saved_mode is None:
                    os.environ.pop("RHIZO_SELINUX_MODE", None)
                else:
                    os.environ["RHIZO_SELINUX_MODE"] = saved_mode
            got = handoff_target(mode, pid_file, child.args[1])
            if got != want:
                bad.append((f"restart's handoff target, {mode} mode", want, got))
    finally:
        child.kill()
        child.wait()

handoffs = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.Call) and ast.unparse(n.func) == "hand_off_to_supervisor"]
entry_at = list(inspect.signature(launcher.hand_off_to_supervisor).parameters).index("entry")
rebound = [n.lineno for n in ast.walk(run_sandbox) if isinstance(n, ast.Name) and n.id == "entry" and isinstance(n.ctx, ast.Store)]
if len(handoffs) != 1 or [a.arg for a in run_sandbox.args.args] != ["entry"] or rebound:
    bad.append(("run_sandbox's handoff call", "one hand_off_to_supervisor call and run_sandbox's entry never rebound",
                len(handoffs), [a.arg for a in run_sandbox.args.args], rebound))
else:
    call = handoffs[0]
    arg = call.args[entry_at] if len(call.args) > entry_at else {k.arg: k.value for k in call.keywords}.get("entry")
    entry_expr = compile(ast.Expression(body=arg), "boot.py", "eval")
    saved_mode = os.environ.pop("RHIZO_SELINUX_MODE", None)
    try:
        for mode, start_entry, want in ((None, "selinux_setup", "selinux_setup"),
                                        ("namespace", "selinux_setup", "selinux_setup"),
                                        ("host", "selinux_setup", "second_stage")):
            if mode is None:
                os.environ.pop("RHIZO_SELINUX_MODE", None)
            else:
                os.environ["RHIZO_SELINUX_MODE"] = mode
            got = eval(entry_expr, dict(vars(launcher), entry=start_entry))
            if got != want:
                bad.append((f"handoff entry, RHIZO_SELINUX_MODE={mode}, start entry {start_entry}", want, got,
                            ast.unparse(arg)))
    finally:
        os.environ.pop("RHIZO_SELINUX_MODE", None)
        if saved_mode is not None:
            os.environ["RHIZO_SELINUX_MODE"] = saved_mode

tries = [t for t in ast.walk(run_sandbox) if isinstance(t, ast.Try)
         and any("g died post-pivot" in ast.unparse(h) for h in t.handlers)]
parents = [lst for n in ast.walk(run_sandbox) for lst in (getattr(n, "body", None), getattr(n, "orelse", None))
           if isinstance(lst, list) and tries and tries[0] in lst]
if len(tries) != 1 or len(parents) != 1:
    bad.append(("g's wait", "one try with the 'g died post-pivot' handler", len(tries), len(parents)))
else:
    gtry = tries[0]
    init = parents[0][parents[0].index(gtry) - 1]
    cut = next(i for i, n in enumerate(gtry.body) if isinstance(n, ast.If) and ast.unparse(n.test) == "_piv_signal")
    loop = next(i for i, n in enumerate(gtry.body) if isinstance(n, ast.While))
    head = compile(ast.Module(body=[init] + gtry.body[:cut], type_ignores=[]), "boot.py", "exec")
    tail = compile(ast.Module(body=gtry.body[loop + 1:], type_ignores=[]), "boot.py", "exec")
    for label, done_r, piv, status, after_loop, late, want_code, want_mark in (
            ("namespace, gg exits 1 before the pivot", 5, b"", 1 << 8, None, "pending", 3, True),
            ("namespace, gg exits 1 after the pivot, before the flip", 5, b"1", 1 << 8, None, "pending", 3, True),
            ("namespace, gg exits 1 with a done byte waiting", 5, b"1", 1 << 8, None, "enforced", 0, False),
            ("namespace, gg exits 1 with a failure byte and its reason waiting", 5, b"1", 1 << 8, None, "failed", 3, False),
            ("namespace, gg killed by a signal after the pivot", 5, b"1", signal.SIGKILL, None, "pending", 3, True),
            ("namespace, gg exits 1 after a verified flip", 5, b"1", 1 << 8, "enforced", "pending", 0, False),
            ("host, gg exits 1 before the pivot", -1, b"", 1 << 8, None, "pending", 0, False),
            ("host, gg exits 1 after the pivot", -1, b"1", 1 << 8, None, "pending", 0, False)):
        logs = []

        class FakeSelect:
            """select stand-in whose pivot pipe is always readable"""
            select = staticmethod(lambda r, w, x, t: (r, [], []))

        class WaitOs:
            """os stand-in answering the pivot pipe read and the status helpers"""
            read = staticmethod(lambda fd, n: piv)
            WIFEXITED, WEXITSTATUS = staticmethod(os.WIFEXITED), staticmethod(os.WEXITSTATUS)

        class LateNs:
            """selinux_ns stand-in whose done pipe holds the late byte"""
            RELABELLER_DEADLINE_S = ns.RELABELLER_DEADLINE_S
            read_done_now = staticmethod(lambda fd, reasons=None: (reasons.append("enforce-failed:x") if late == "failed" else 0, late)[1])
            stop_requested = staticmethod(lambda fd: False)
            init_exit_refusal = staticmethod(ns.init_exit_refusal)
            relabeller_refusal = staticmethod(ns.relabeller_refusal)

        scope = {"_done_r": done_r, "select": FakeSelect, "os": WaitOs, "piv_r": 3, "time": __import__("time"),
                 "selinux_ns": LateNs, "kmsg": logs.append, "_why": "", "_fail_reasons": [], "_ns_handoff": False,
                 "_sandbox_kills": [],
                 "_verdict_dir": -1}
        exec(head, scope)
        if after_loop:
            scope["_relabel"] = after_loop
        scope["d"] = (4242, status)
        saved_ns_kmsg, ns.kmsg = ns.kmsg, logs.append
        try:
            exec(tail, scope)
        finally:
            ns.kmsg = saved_ns_kmsg
        code = eval(exit_expr, {"_relabel": scope["_relabel"], "selinux_ns": ns})
        exit_mark = ("init-exited-before-flip status=1" if os.WIFEXITED(status)
                     else f"init-killed-before-flip signal={os.WTERMSIG(status)}")
        marked = any(f"selinuxns=refused reason={exit_mark}" in l for l in logs)
        exit_why = ("init-exited-before-flip-status-1" if os.WIFEXITED(status)
                    else f"init-killed-before-flip-signal-{os.WTERMSIG(status)}")
        why = exit_why if want_mark else "relabeller-enforce-failed:x" if late == "failed" else ""
        if code != want_code or marked != want_mark or scope["_why"] != why:
            bad.append((f"g's wait, {label}", want_code, want_mark, why, code, scope["_why"], logs))
    fence_kills = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.FunctionDef) and n.name == "_kill_for_fence"]
    if len(fence_kills) != 1:
        bad.append(("g's fence kill", "one nested _kill_for_fence", len(fence_kills)))
    else:
        fence_code = compile(ast.Module(body=fence_kills, type_ignores=[]), "boot.py", "exec")
        with tempfile.TemporaryDirectory() as tmp:
            dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
            try:
                ns.record_verdict("enforced", dfd)
                sent = []

                class FenceSignal:
                    """signal stand-in recording the kill and the verdict at its time"""
                    SIGKILL = signal.SIGKILL
                    pidfd_send_signal = staticmethod(lambda fd, sig: sent.append((fd, sig, ns.read_verdict(dfd))))

                scope = {"_sandbox_kills": [], "_verdict_dir": dfd, "selinux_ns": ns, "_signal": FenceSignal,
                         "_gg_fd": 7}
                saved_kmsg, ns.kmsg = ns.kmsg, lambda m: None
                try:
                    exec(fence_code, scope)
                    scope["_kill_for_fence"]()
                finally:
                    ns.kmsg = saved_kmsg
            finally:
                os.close(dfd)
        if sent != [(7, signal.SIGKILL, "refused:input-fence")] or scope["_sandbox_kills"] != ["input-fence"]:
            bad.append(("g's fence kill", "refused:input-fence recorded before the SIGKILL to gg", sent,
                        scope["_sandbox_kills"]))
        scope = {"_done_r": 5, "select": FakeSelect, "os": WaitOs, "piv_r": 3, "time": __import__("time"),
                 "selinux_ns": ns, "kmsg": lambda m: None, "_why": "", "_fail_reasons": [], "_ns_handoff": False,
                 "_verdict_dir": 5, "_sandbox_kills": ["input-fence"], "_relabel": "enforced", "d": (4242, 0)}
        saved_rdn, ns.read_done_now = ns.read_done_now, lambda fd, reasons=None: "pending"
        try:
            exec(tail, scope)
        finally:
            ns.read_done_now = saved_rdn
        code = eval(exit_expr, {"_relabel": scope["_relabel"], "selinux_ns": ns})
        if (scope["_relabel"], scope["_why"], code) != ("failed", "input-fence", ns.RELABELLER_REFUSED_EXIT):
            bad.append(("g's end after its fence kill", ("failed", "input-fence", 3),
                        (scope["_relabel"], scope["_why"], code)))
    saved_kmsg, saved_wait = ns.kmsg, getattr(ns, "JOINER_END_WAIT_S", None)
    ns.JOINER_END_WAIT_S = 0
    for verdict, stopping, want_relabel, want_code, want_after in (
            ("enforced", False, "failed", 3, "refused:holder-ended"),
            ("permissive", False, "failed", 3, "refused:holder-ended"),
            ("stopped", False, "none", 0, "stopped"),
            ("refused:init-outside-namespace", False, "failed", 3, "refused:init-outside-namespace"),
            ("handed-off", False, "failed", 3, "refused:holder-ended"),
            ("pending", False, "failed", 3, "refused:holder-ended"), (None, False, "failed", 3, "refused:holder-ended"),
            ("enforced", True, "none", 0, "stopped"), ("pending", True, "none", 0, "stopped")):
        logs = []
        ns.kmsg = logs.append
        with tempfile.TemporaryDirectory() as tmp:
            if verdict is not None:
                with open(os.path.join(tmp, os.path.basename(ns.VERDICT_FILE)), "w") as f:
                    f.write(verdict + "\n")
            if stopping:
                ns.record_stop_request(tmp)
            dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
            scope = {"_done_r": -1, "select": FakeSelect, "os": WaitOs, "piv_r": 3, "time": __import__("time"),
                     "selinux_ns": ns, "kmsg": logs.append, "_why": "", "_ns_handoff": True, "_sandbox_kills": [],
                     "_verdict_dir": dfd}
            try:
                exec(head, scope)
                scope["d"] = (4242, 0)
                exec(tail, scope)
                after = ns.read_verdict(dfd)
            finally:
                os.close(dfd)
                ns.kmsg = saved_kmsg
        code = eval(exit_expr, {"_relabel": scope["_relabel"], "selinux_ns": ns})
        refused = any("selinuxns=refused" in l for l in logs)
        if (scope["_relabel"] != want_relabel or code != want_code or refused != (want_code != 0)
                or after != want_after):
            bad.append((f"g's wait, handoff verdict {verdict!r}, stop requested {stopping}", want_relabel, want_code,
                        want_after, scope["_relabel"], code, after, logs))
    ns.JOINER_END_WAIT_S = saved_wait

    class JoinerClock:
        """time stand-in whose first sleep lands the joiner's refusal"""
        now = 0.0
        dir_fd = -1

        @staticmethod
        def time():
            """return the stand-in clock"""
            return JoinerClock.now

        @staticmethod
        def sleep(seconds):
            """advance the clock and land the joiner's refusal once"""
            JoinerClock.now += seconds
            if ns.read_verdict(JoinerClock.dir_fd) == "enforced":
                ns.record_verdict("refused:holder-ended", JoinerClock.dir_fd)

    logs = []
    ns.kmsg = logs.append
    with tempfile.TemporaryDirectory() as tmp:
        dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
        saved_time = ns.time
        try:
            ns.record_verdict("enforced", dfd)
            JoinerClock.dir_fd, ns.time = dfd, JoinerClock
            scope = {"_done_r": -1, "select": FakeSelect, "os": WaitOs, "piv_r": 3, "time": __import__("time"),
                     "selinux_ns": ns, "kmsg": logs.append, "_why": "", "_ns_handoff": True, "_sandbox_kills": [],
                     "_verdict_dir": dfd}
            exec(head, scope)
            scope["d"] = (4242, signal.SIGKILL)
            exec(tail, scope)
            after = ns.read_verdict(dfd)
        finally:
            ns.time, ns.kmsg = saved_time, saved_kmsg
            os.close(dfd)
    code = eval(exit_expr, {"_relabel": scope["_relabel"], "selinux_ns": ns})
    if (scope["_relabel"], code, after) != ("failed", ns.RELABELLER_REFUSED_EXIT, "refused:holder-ended"):
        bad.append(("g's wait, the joiner's refusal landing after the holder's death",
                    ("failed", 3, "refused:holder-ended"), (scope["_relabel"], code, after), logs))

    def holder():
        """fork a stand-in namespace holder that waits to be killed"""
        pid = os.fork()
        if pid == 0:
            signal.pause()
            os._exit(0)
        return pid

    def holder_killed(pid):
        """end the stand-in holder with SIGTERM and return whether SIGKILL ended it first"""
        os.kill(pid, signal.SIGTERM)
        status = os.waitpid(pid, 0)[1]
        return os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL

    class PivotOs:
        """os stand-in whose /dev/kmsg reopen fails at once"""
        O_WRONLY, O_CLOEXEC = os.O_WRONLY, os.O_CLOEXEC
        close, unlink, kill = staticmethod(os.close), staticmethod(os.unlink), staticmethod(os.kill)

        @staticmethod
        def open(*a, **k):
            """refuse the /dev/kmsg reopen"""
            raise PermissionError(1, "Operation not permitted")

    piv_if = compile(ast.Module(body=[gtry.body[cut]], type_ignores=[]), "boot.py", "exec")
    for label, sig, ready, ns_handoff, handed, want, want_killed in (
            ("gg exited before pivoting", b"", True, True, None, "refused:holder-exited-before-handoff", False),
            ("gg never signaled its pivot", b"", False, True, None, "refused:holder-never-pivoted", True),
            ("host mode, gg never signaled its pivot", b"", False, False, None, "", False),
            ("the supervisor gone before the signal", b"1", True, True, ["signal-ESRCH"],
             "refused:handoff-signal-ESRCH", True),
            ("no pre-pivot descriptor", b"1", True, True, ["no-descriptor"], "refused:handoff-no-descriptor", True),
            ("the handoff taken", b"1", True, True, [], "", False),
            ("host mode, the supervisor gone before the signal", b"1", True, False, ["signal-ESRCH"], "", False)):
        logs, gg = [], holder()

        def hand_off(*a, why=None, handed=handed):
            """answer the case's handoff and name why it failed"""
            if why is not None:
                why.extend(handed or [])
            return not handed

        try:
            with tempfile.TemporaryDirectory() as tmp:
                dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
                scope = {"_piv_signal": sig, "_piv_ready": ready, "_handoff_to": 4242, "_ns_handoff": ns_handoff,
                         "_verdict_dir": dfd, "_hoff_fd": -1, "_hoff_dfd": -1, "_hoff_tmp": None,
                         "kmsg": logs.append, "selinux_ns": ns, "os": PivotOs, "gg": gg,
                         "refuse_handoff": getattr(launcher, "refuse_handoff", None),
                         "hand_off_to_supervisor": hand_off, "entry": "selinux_setup", "SANDBOX_ID": 0,
                         "host_selinux_mode": lambda ns_handoff=ns_handoff: not ns_handoff,
                         "time": type("T", (), {"sleep": staticmethod(lambda s: None)}), "core": None}
                saved = (launcher.kmsg, ns.kmsg)
                launcher.kmsg = ns.kmsg = logs.append
                try:
                    exec(piv_if, scope)
                    got = ns.read_verdict(dfd)
                except BaseException as e:
                    got = repr(e)
                finally:
                    launcher.kmsg, ns.kmsg = saved
                    os.close(dfd)
        finally:
            killed = holder_killed(gg)
        if got != want or killed != want_killed:
            bad.append((f"holder never handed off, {label}", want, f"killed={want_killed}", got, f"killed={killed}",
                        logs))
    saved_kmsg, logs = ns.kmsg, []
    ns.kmsg = logs.append
    try:
        outcome = ns.handoff_outcome("refused:holder-never-pivoted")
    finally:
        ns.kmsg = saved_kmsg
    if outcome != "failed" or logs != ["RHIZO_MARKER selinuxns=refused reason=holder-never-pivoted"]:
        bad.append(("holder never handed off, g's outcome", "failed with its reason", outcome, logs))
    for done_r, want in ((5, "pending"), (-1, "none")):
        scope = {"_done_r": done_r}
        exec(compile(ast.Module(body=[init], type_ignores=[]), "boot.py", "exec"), scope)
        if scope["_relabel"] != want:
            bad.append(("g's state before the pivot select", f"_done_r={done_r}", want, scope["_relabel"]))


def relabeller_run(after_load, with_done=True):
    """call run_relabeller with a stubbed relabel"""
    saved = (ns._relabel_after_load, ns.kmsg)
    logs, args = [], []

    def relabel(*a, **k):
        """record the arguments and run the case's relabel"""
        args.append(a[:3])
        return after_load(*a)

    ns._relabel_after_load, ns.kmsg = relabel, logs.append
    dr, dw = os.pipe()
    try:
        code = ns.run_relabeller("/nonexistent-newroot", ["spec"], 7, lambda: None, dw if with_done else -1)
    finally:
        ns._relabel_after_load, ns.kmsg = saved
        os.close(dw)
    got = os.read(dr, 400)
    os.close(dr)
    return got, code, args, [l.split(" err=")[0] for l in logs if "RHIZO_MARKER" in l]


def raise_after_load(*a, **k):
    """stand in for a relabel that raises"""
    raise RuntimeError("relabel raised")


relabel_args = [("/nonexistent-newroot", ["spec"], 7)]
for label, after_load, with_done, want in (
        ("relabel raises", raise_after_load, True,
         (b"fraised:RuntimeError__relabel_raised__\n", 1, relabel_args, [])),
        ("relabel fails", lambda *a: ns.DONE_FAILED, True, (ns.DONE_FAILED, 1, relabel_args, [])),
        ("relabel fails with a reason", lambda *a: ns.failed("enforce-failed:before=0,after=0"), True,
         (b"fenforce-failed:before=0,after=0\n", 1, relabel_args, [])),
        ("enforced", lambda *a: ns.DONE_ENFORCED, True, (ns.DONE_ENFORCED, 0, relabel_args, [])),
        ("permissive", lambda *a: ns.DONE_PERMISSIVE, True, (ns.DONE_PERMISSIVE, 0, relabel_args, [])),
        ("enforced with no done pipe", lambda *a: ns.DONE_ENFORCED, False, (b"", 0, relabel_args, []))):
    got = relabeller_run(after_load, with_done)
    if got != want:
        bad.append((f"run_relabeller, {label}", want, got))


def relabeller_child(unshare_rc, after_load, prctl_rc=0):
    """run start_relabeller with stubbed unshare and load wait"""
    saved = (ns.libc, ns._relabel_after_load, ns.kmsg, ns.run_relabeller)
    logs = []
    if callable(getattr(after_load, "whole", None)):
        ns.run_relabeller = after_load.whole

    class FakeLibc:
        """libc answering unshare_rc and prctl_rc"""
        unshare = staticmethod(lambda flags: unshare_rc)
        prctl = staticmethod(lambda *a: prctl_rc)
        capget = staticmethod(lambda header, sets: 0)
        capset = staticmethod(lambda header, sets: 0)

    ns.libc, ns._relabel_after_load, ns.kmsg = FakeLibc, after_load, logs.append
    dr, dw = os.pipe()
    try:
        pid = ns.start_relabeller("/nonexistent-newroot", [], lambda: None, dw)
    finally:
        ns.libc, ns._relabel_after_load, ns.kmsg, ns.run_relabeller = saved
        os.close(dw)
    got = re.sub(rb"(errno=|capbset-drop:16:)-?\d+", rb"\1N", os.read(dr, 400))
    os.close(dr)
    _, status = os.waitpid(pid, 0)
    ready = [l for l in logs if "relabeller-started" in l]
    return got, os.waitstatus_to_exitcode(status), ready[0].rsplit(" ", 1)[-1] if ready else None


def raise_after_done(newroot, staged, mntns_fd, write_primer_script, done_fd):
    """stand in for a run_relabeller that wrote its done byte and then raised"""
    ns._write_done(done_fd, ns.DONE_ENFORCED)
    raise RuntimeError("after the flip")


raise_after_load_done = lambda *a, **k: None
raise_after_load_done.whole = raise_after_done
for label, unshare_rc, after_load, want in (
        ("capabilities that will not drop", "caps", lambda *a, **k: ns.DONE_ENFORCED,
         (b"fcaps-failed:capbset-drop:16:N\n", 1, "ready=False")),
        ("unshare fails", -1, lambda *a, **k: ns.DONE_ENFORCED, (b"funshare-failed:errno=N\n", 1, "ready=False")),
        ("relabel raises", 0, raise_after_load, (b"fraised:RuntimeError__relabel_raised__\n", 1, "ready=True")),
        ("raises after the done byte: no second byte, no kmsg", 0, raise_after_load_done, (b"1", 1, "ready=True")),
        ("enforced", 0, lambda *a, **k: ns.DONE_ENFORCED, (ns.DONE_ENFORCED, 0, "ready=True"))):
    got = relabeller_child(0, after_load, prctl_rc=-1) if unshare_rc == "caps" else relabeller_child(unshare_rc,
                                                                                                    after_load)
    if got != want:
        bad.append((f"relabeller child, {label}", want, got))


def relabeller_without_writer():
    """call start_relabeller in a fork with no primer-script writer"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        ns.kmsg = lambda m: os.write(w, (m + "\n").encode())
        try:
            ns.start_relabeller("/nonexistent-newroot", [], None, -1)
        except BaseException as e:
            os.write(w, f"raised {e!r}\n".encode())
        os._exit(0)
    os.close(w)
    data = b""
    while True:
        chunk = os.read(r, 65536)
        if not chunk:
            break
        data += chunk
    os.close(r)
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status), data.decode().splitlines()


got = relabeller_without_writer()
if got != (1, ["RHIZO_MARKER selinuxns=refused reason=no-primer-writer"]):
    bad.append(("relabeller with no primer-script writer", "exit 1 with the refusal marker", got))

if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
