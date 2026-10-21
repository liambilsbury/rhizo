#!/usr/bin/env python3
import ast, contextlib, errno, io, os, signal, subprocess, sys, tempfile, time
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-supervisor-record")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
from sandbox import selinux_ns as ns

bad = []


for mode, args, want in (
    ("host", ("kernel", None, False, 10), True),
    ("host", ("u:r:rhizo_host:s0", None, False, 10), False),
    ("namespace", ("kernel", None, False, 10), True),
    ("namespace", ("kernel", 77, True, 10), False),
    ("namespace", ("kernel", 10, True, 10), True),
):
    os.environ["RHIZO_SELINUX_MODE"] = mode
    if launcher.may_record_supervisor(*args) != want:
        bad.append(("may_record_supervisor", mode, args, want))
os.environ.pop("RHIZO_SELINUX_MODE", None)

tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
fns = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
if "may_record_supervisor" not in ast.unparse(fns["run_kernel_domain_supervisor"]):
    bad.append(("supervisor records through may_record_supervisor", "call", "absent"))
refused_ifs = [n for n in ast.walk(fns["main"]) if isinstance(n, ast.If)
               and ast.unparse(n.test) == "supervisor_end_fails_unit(status)"
               and [ast.unparse(s) for s in n.body] == ["sys.exit(1)"]]
if len(refused_ifs) != 2 or "RELABELLER_REFUSED_EXIT" in ast.unparse(fns["main"]):
    bad.append(("main's refusal test", "two `if supervisor_end_fails_unit(status): sys.exit(1)` and no inline test",
                len(refused_ifs)))
direct = [n for n in fns["main"].body if isinstance(n, ast.If) and ast.unparse(n.test) == "not RHIZO_RESIDENT_G"]
if len(direct) != 1 or [ast.unparse(s) for s in direct[0].body] != ["run_sandbox_or_refuse(entry)", "return"]:
    bad.append(("main's non-resident start", "run_sandbox_or_refuse(entry)", [ast.unparse(n) for n in direct]))
first_pass = [n for n in ast.walk(fns["run_kernel_domain_supervisor"]) if isinstance(n, ast.Try)
              and [ast.unparse(s) for s in n.body] == ["first_g = run_sandbox_or_refuse(entry)"]]
if len(first_pass) != 1:
    bad.append(("the supervisor's first pass", "one try around first_g = run_sandbox_or_refuse(entry)",
                len(first_pass)))
else:
    first_pass_code = compile(ast.Module(body=first_pass, type_ignores=[]), "boot.py", "exec")
    for mode, outcome, want_states in (("namespace", SystemExit(3), ["refused"]), ("host", SystemExit(3), []),
                                       ("namespace", None, [])):
        states = []

        def first_run_sandbox(entry, outcome=outcome):
            """raise the case's exit or return"""
            if outcome is not None:
                raise outcome

        scope = {"run_sandbox_or_refuse": first_run_sandbox, "entry": "selinux_setup", "_state": states.append,
                 "host_selinux_mode": lambda mode=mode: mode == "host"}
        try:
            exec(first_pass_code, scope)
            raised = None
        except SystemExit as e:
            raised = e.code
        if states != want_states or raised != (None if outcome is None else outcome.code):
            bad.append(("the supervisor's first pass", mode, repr(outcome), want_states, states, raised))
pid_opens = [(f.name, ast.unparse(c.args[1]) if len(c.args) > 1 else "'r'") for f in ast.walk(tree)
             if isinstance(f, ast.FunctionDef) for c in ast.walk(f)
             if isinstance(c, ast.Call) and ast.unparse(c.func) == "open" and c.args
             and ast.unparse(c.args[0]) == "G_PID_FILE"]
pid_readers = sorted({name for name, how in pid_opens if how in ("'r'", "'rb'")})
pid_writers = sorted({name for name, how in pid_opens if how not in ("'r'", "'rb'")})
if pid_readers != ["read_supervisor_record"] or pid_writers != ["record_supervisor_pid"]:
    bad.append(("G_PID_FILE readers and writers", ["read_supervisor_record"], ["record_supervisor_pid"],
                pid_readers, pid_writers))


def child_exit(code):
    """fork a child that exits with code and return its pid"""
    pid = os.fork()
    if pid == 0:
        os._exit(code)
    return pid


def child_status(code, sig=None):
    """fork a child and return its wait status"""
    pid = os.fork()
    if pid == 0:
        if sig:
            os.kill(os.getpid(), sig)
        os._exit(code)
    return os.waitpid(pid, 0)[1]


for label, status, want in (("refusal exit", child_status(ns.RELABELLER_REFUSED_EXIT), True),
                            ("clean exit", child_status(0), False), ("exit 1", child_status(1), False),
                            ("killed", child_status(0, signal.SIGKILL), False), ("no status", None, False)):
    got = getattr(launcher, "supervisor_refused", lambda s: "absent")(status)
    if got is not want:
        bad.append(("supervisor_refused", label, want, got))

for label, write, code, want, want_why in (("flip byte", b"1", 0, "flipped", []),
                                           ("refused", b"", 3, "refused", ["g-exit-3"]),
                                           ("g's own early exit", b"", 1, "refused", ["g-exit-1"]),
                                           ("g killed by a signal", b"", -signal.SIGKILL, "refused", ["g-signal-9"]),
                                           ("ended", b"", 0, "ended", [])):
    r, w = os.pipe()
    g = child_exit(code) if code >= 0 else os.fork()
    if g == 0:
        os.kill(os.getpid(), -code)
        os._exit(0)
    if write:
        os.write(w, write)
    os.close(w)
    why, reaped = [], False
    try:
        got = ns.wait_first_flip(r, g, reasons=why)
        reaped = not write
    except TypeError as e:
        got = repr(e)
        os.close(r)
    if not reaped:
        os.waitpid(g, 0)
    if got != want or why != want_why:
        bad.append(("wait_first_flip", label, want, want_why, got, why))


SCRATCH = tempfile.TemporaryDirectory()


def records_with(verdict):
    """return a scratch records dir holding verdict"""
    d = tempfile.mkdtemp(dir=SCRATCH.name)
    if verdict is not None:
        with open(os.path.join(d, os.path.basename(ns.VERDICT_FILE)), "w") as f:
            f.write(verdict + "\n")
    return d


def verdict_in(d):
    """return the verdict a scratch records dir holds"""
    dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
    try:
        return ns.read_verdict(dfd)
    finally:
        os.close(dfd)


saved_kmsg = (launcher.kmsg, ns.kmsg)
launcher.kmsg = ns.kmsg = lambda m: None
try:
    for label, seed, value, keep, want, want_written in (
            ("a stop after a refusal", "refused:joiner-left-pending", "stopped", None, "refused:joiner-left-pending",
             False),
            ("an enforced verdict after a refusal", "refused:supervisor-exit-1", "enforced", None,
             "refused:supervisor-exit-1", False),
            ("a second refusal", "refused:handoff-signal-ESRCH", "refused:holder-ended", None,
             "refused:handoff-signal-ESRCH", False),
            ("a stop after an enforced verdict", "enforced", "stopped", None, "stopped", True),
            ("a start's reset after a refusal", "refused:input-fence", "pending", lambda current: False, "pending",
             True)):
        d = records_with(seed)
        dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
        try:
            written = ns.record_verdict(value, dfd) if keep is None else ns.record_verdict(value, dfd, keep=keep)
        except TypeError as e:
            written = repr(e)
        finally:
            os.close(dfd)
        if verdict_in(d) != want or written is not want_written:
            bad.append(("record_verdict", label, want, want_written, verdict_in(d), written))
    record_fn = next(n for n in ast.parse(open(ns.__file__).read()).body
                     if isinstance(n, ast.FunctionDef) and n.name == "record_verdict")
    record_text = ast.unparse(record_fn)
    lock_at = record_text.find("fcntl.flock(dir_fd, fcntl.LOCK_EX)")
    if not 0 <= lock_at < record_text.find("read_verdict(dir_fd)") < record_text.find("write_android_enforce("):
        bad.append(("record_verdict", "reads and writes the verdict under an exclusive flock on the records dir"))
    d = records_with("stopped")
    if launcher.record_refusal_unless_final("supervisor-exit-1", d) or verdict_in(d) != "stopped":
        bad.append(("record_refusal_unless_final", "a final verdict kept", verdict_in(d)))

    end_fn = getattr(launcher, "supervisor_end_fails_unit", None)
    for mode, verdict, status, want_fail, want_after in (
            ("namespace", "pending", child_status(1), True, "refused:supervisor-exit-1"),
            ("namespace", "pending", child_status(3), True, "refused:supervisor-exit-3"),
            ("namespace", "handed-off", child_status(0), True, "refused:supervisor-exit-0"),
            ("namespace", "pending", child_status(0, signal.SIGKILL), True, "refused:supervisor-signal-9"),
            ("namespace", "pending", None, True, "refused:supervisor-gone"),
            ("namespace", "refused:gpu_driver_refused=no-render-node", child_status(3), True,
             "refused:gpu_driver_refused=no-render-node"),
            ("namespace", "stopped", child_status(0), False, "stopped"),
            ("namespace", "refused:holder-ended", child_status(0), True, "refused:holder-ended"),
            ("host", "pending", child_status(3), True, "pending"),
            ("host", "pending", child_status(1), False, "pending")):
        os.environ["RHIZO_SELINUX_MODE"] = mode
        d = records_with(verdict)
        if end_fn is None:
            failed, after = ("supervisor_refused" in dir(launcher) and launcher.supervisor_refused(status)), verdict
        else:
            failed, after = end_fn(status, records_dir=d), verdict_in(d)
        if failed != want_fail or after != want_after:
            bad.append(("MainPID's supervisor end", mode, verdict, want_fail, want_after, failed, after))
    os.environ.pop("RHIZO_SELINUX_MODE", None)

    class Refused(Exception):
        """raised in place of refuse_start"""

    def refuse_stub():
        """raise in place of refusing the start"""
        raise Refused()

    wrap = getattr(launcher, "run_sandbox_or_refuse", None)
    for mode, verdict, raised, want_refused, want_after in (
            ("namespace", "pending", SystemExit("RHIZO_MARKER gpu_driver_refused=no-render-node dir=/x"), True,
             "refused:gpu_driver_refused=no-render-node"),
            ("namespace", "pending", SystemExit("RHIZO_MARKER gpu_driver_refused=host-policy-error (bad line 3)"),
             True, "refused:gpu_driver_refused=host-policy-error"),
            ("namespace", "pending", OSError(5, "Input/output error"), True, "refused:launcher-raised-OSError"),
            ("namespace", "refused:dummy0-failed", SystemExit(3), True, "refused:dummy0-failed"),
            ("namespace", "pending", None, False, "pending"),
            ("host", "pending", SystemExit("RHIZO_MARKER gpu_driver_refused=no-render-node"), False, "pending")):
        os.environ["RHIZO_SELINUX_MODE"] = mode
        d = records_with(verdict)

        def stub_run_sandbox(entry, raised=raised):
            """raise the case's end or return"""
            if raised is not None:
                raise raised

        saved = (launcher.run_sandbox, launcher.refuse_start)
        launcher.run_sandbox, launcher.refuse_start = stub_run_sandbox, refuse_stub
        try:
            if wrap is None:
                got = "absent"
            else:
                wrap("selinux_setup", records_dir=d)
                got = "returned"
        except Refused:
            got = "refused"
        except BaseException as e:
            got = "re-raised" if e is raised else repr(e)
        finally:
            launcher.run_sandbox, launcher.refuse_start = saved
        want = "refused" if want_refused else "returned" if raised is None else "re-raised"
        if got != want or verdict_in(d) != want_after:
            bad.append(("run_sandbox_or_refuse", mode, repr(raised), want, want_after, got, verdict_in(d)))
    os.environ.pop("RHIZO_SELINUX_MODE", None)

    close = getattr(launcher, "close_out_owned_start", None)
    for label, owner_is_me, raised, want_after in (
            ("MainPID raised", True, RuntimeError("fork failed"), "refused:launcher-raised-RuntimeError"),
            ("MainPID exited 1", True, SystemExit(1), "refused:launcher-exit-1"),
            ("MainPID exited 0", True, SystemExit(0), "pending"),
            ("a forked child raised", False, OSError(5, "Input/output error"), "pending")):
        d = records_with(None)
        launcher.reset_namespace_start_records(d)
        reset_owner = dict(launcher._START_RECORDS_OWNER) if hasattr(launcher, "_START_RECORDS_OWNER") else {}
        if reset_owner != {"pid": os.getpid(), "dir": d}:
            bad.append(("reset_namespace_start_records owns the start's close-out", os.getpid(), d, reset_owner))
        if not owner_is_me and hasattr(launcher, "_START_RECORDS_OWNER"):
            launcher._START_RECORDS_OWNER["pid"] = os.getpid() + 1
        if close is not None:
            close(raised)
        if verdict_in(d) != want_after:
            bad.append(("close_out_owned_start", label, want_after, verdict_in(d)))
    d = records_with("refused:input-fence")
    saved_record, marks = ns.record_verdict, []
    ns.record_verdict = lambda value, dfd, keep=None: False
    saved_kmsg_reset, launcher.kmsg = launcher.kmsg, marks.append
    try:
        launcher.reset_namespace_start_records(d)
        reset = "returned"
    except SystemExit as e:
        reset = f"exit {e.code}"
    finally:
        ns.record_verdict, launcher.kmsg = saved_record, saved_kmsg_reset
    if reset != "exit 1" or not any("reason=records-reset-failed" in m for m in marks):
        bad.append(("a reset that cannot write pending", "exit 1 named records-reset-failed", reset, marks))
    marks = []
    saved_kmsg_reset, launcher.kmsg = launcher.kmsg, marks.append
    try:
        with tempfile.NamedTemporaryFile() as not_a_dir:
            launcher.reset_namespace_start_records(os.path.join(not_a_dir.name, "records"))
        reset = "returned"
    except SystemExit as e:
        reset = f"exit {e.code}"
    finally:
        launcher.kmsg = saved_kmsg_reset
    if reset != "exit 1" or not any("reason=records-dir-unopenable" in m for m in marks):
        bad.append(("a reset that cannot open the records dir", "exit 1 named records-dir-unopenable", reset, marks))
    main_call = [n for n in tree.body if isinstance(n, ast.If) and "__main__" in ast.unparse(n.test)]
    wrapped = [t for t in ast.walk(main_call[0]) if isinstance(t, ast.Try)
               and [ast.unparse(x) for x in t.body] == ["main()"]
               and any("close_out_owned_start" in ast.unparse(h) for h in t.handlers)] if main_call else []
    if len(wrapped) != 1:
        bad.append(("__main__ closes out the start main() ends", "one try around main()", len(wrapped)))
finally:
    launcher.kmsg, ns.kmsg = saved_kmsg

r, w = os.pipe()
if ns.read_done_now(r) != "pending":
    bad.append(("read_done_now empty", "pending"))
os.write(w, ns.DONE_ENFORCED)
if ns.read_done_now(r) != "enforced":
    bad.append(("read_done_now byte", "enforced"))
os.close(w)
if ns.read_done_now(r) != "pending":
    bad.append(("read_done_now eof", "pending"))

for relabel, why, want in (("enforced", "", "enforced"), ("permissive", "", "permissive"),
                           ("eof", "", "refused:relabeller-eof"), ("timeout", "", "refused:relabeller-timeout"),
                           ("failed", "init-exited-before-flip", "refused:init-exited-before-flip"),
                           ("failed", "", "refused:relabeller-failed"), ("none", "", "stopped"),
                           ("pending", "", "stopped")):
    if ns.verdict_for(relabel, why) != want:
        bad.append(("verdict_for", relabel, why, want, ns.verdict_for(relabel, why)))



def start_ticks(pid):
    """return the pid's start time in clock ticks"""
    with open(f"/proc/{pid}/stat") as f:
        raw = f.read()
    return int(raw[raw.rindex(")") + 2:].split()[19])


def parked_child(tmp, script_name, relative=False, block_usr1=False):
    """start a parked-supervisor stand-in running script_name"""
    path = os.path.join(tmp, script_name)
    blocked = "{signal.SIGTERM, signal.SIGUSR1}" if block_usr1 else "{signal.SIGTERM}"
    with open(path, "w") as f:
        f.write(f"import signal, time\nsignal.pthread_sigmask(signal.SIG_BLOCK, {blocked})\n"
                "print('up', flush=True)\ntime.sleep(60)\n")
    child = subprocess.Popen([sys.executable, script_name if relative else path], stdout=subprocess.PIPE, text=True,
                             cwd=tmp)
    child.stdout.readline()
    return child


_sup_lines = [l.strip() for l in ast.unparse(fns["run_kernel_domain_supervisor"]).splitlines()]
_woke = [i for i, l in enumerate(_sup_lines) if "signal.sigwait(" in l]
if len(_woke) != 1 or _sup_lines[_woke[0] + 1:_woke[0] + 2] != ["_state('waking')"]:
    bad.append(("the supervisor's wake", "writes waking right after sigwait", [_sup_lines[i + 1] for i in _woke]))

with open("/proc/stat") as f:
    btime = int(next(l for l in f if l.startswith("btime ")).split()[1])
with open("/proc/sys/kernel/random/boot_id") as f:
    boot_id = f.read().strip()
stale_clear = [n for n in fns["main"].body if isinstance(n, ast.If) and "host_boot_id" in ast.unparse(n)]
if len(stale_clear) != 1:
    bad.append(("main's earlier-boot supervisor pid clear", "one block", len(stale_clear)))
logs = []
saved = (launcher.G_PID_FILE, launcher.kmsg)
launcher.kmsg = logs.append
with tempfile.TemporaryDirectory() as tmp:
    other = parked_child(tmp, "rhizo-other-service.py")
    same = parked_child(tmp, os.path.basename(sys.argv[0]))
    relative = parked_child(tmp, os.path.basename(sys.argv[0]), relative=True)
    os.mkdir(os.path.join(tmp, "twin"))
    twin = parked_child(os.path.join(tmp, "twin"), os.path.basename(sys.argv[0]))
    spawned = []
    saved_argv0 = sys.argv[0]
    saved_state = getattr(launcher, "SUPERVISOR_STATE", None)
    saved_handoff = getattr(launcher, "HANDOFF_DIR", None)
    sys.argv[0] = same.args[1]
    try:
        pid_file = launcher.G_PID_FILE = os.path.join(tmp, "g_pid")

        def record(pid, boot=None, dated_before_boot=False, code=None, start=None):
            """write a supervisor record to the pid file"""
            with open(pid_file, "w") as f:
                f.write(" ".join(str(v) for v in (pid, boot, code, start) if v is not None))
            if dated_before_boot:
                os.utime(pid_file, (btime - 100, btime - 100))

        for mode, boot, dated, want_kept in (("namespace", "another-boot", False, False),
                                             ("namespace", None, False, False),
                                             ("namespace", boot_id, False, True),
                                             ("namespace", boot_id, True, True),
                                             ("host", None, True, True)):
            os.environ["RHIZO_SELINUX_MODE"] = mode
            record(other.pid, boot, dated)
            logs.clear()
            if stale_clear:
                exec(compile(ast.Module(body=stale_clear, type_ignores=[]), "boot.py", "exec"),
                     dict(vars(launcher), G_PID_FILE=pid_file, kmsg=logs.append))
            cleared = any("not this boot" in l for l in logs)
            if os.path.exists(pid_file) != want_kept or cleared == want_kept:
                bad.append(("earlier-boot pid file", mode, boot, "mtime before boot" if dated else "mtime now",
                            "kept" if want_kept else "cleared", os.path.exists(pid_file), logs[:]))

        for mode, want in (("host", str(os.getpid())),
                           ("namespace", f"{os.getpid()} {boot_id} {getattr(launcher, 'LOADED_CODE_ID', '<none>')} "
                                         f"{start_ticks(os.getpid())}")):
            os.environ["RHIZO_SELINUX_MODE"] = mode
            try:
                launcher.record_supervisor_pid()
                got = open(pid_file).read()
            except (AttributeError, OSError) as e:
                got = repr(e)
            if got != want or launcher.recorded_pid() != os.getpid():
                bad.append(("supervisor record", mode, want, got, launcher.recorded_pid()))

        for mode, child, want_alive in (("namespace", other, False), ("namespace", same, True),
                                        ("namespace", relative, True), ("namespace", twin, False),
                                        ("host", other, True)):
            os.environ["RHIZO_SELINUX_MODE"] = mode
            record(child.pid, boot_id, code=launcher.LOADED_CODE_ID, start=start_ticks(child.pid))
            got = (launcher.recorded_g_alive(), launcher.resident_g_pid())
            if got != (want_alive, child.pid if want_alive else None):
                bad.append(("recorded supervisor liveness", mode, child.args[1], want_alive, got))

        for mode, want in (("namespace", None), ("host", other.pid)):
            os.environ["RHIZO_SELINUX_MODE"] = mode
            record(other.pid, boot_id)
            logs.clear()
            t0 = time.monotonic()
            got = launcher.await_resident_g(5)
            if got != want or time.monotonic() - t0 > 2:
                bad.append(("await_resident_g on another script", mode, want, got, logs[:]))

        launcher.SUPERVISOR_STATE = os.path.join(tmp, "state")
        launcher.HANDOFF_DIR = os.path.join(tmp, "handoff.d")
        os.makedirs(launcher.HANDOFF_DIR)
        loaded = getattr(launcher, "LOADED_CODE_ID", "<none>")
        for label, mode, code, state, entry, loaded_id, want_handoff, want_alive, want_note in (
                ("the same code", "namespace", loaded, "parked", None, None, True, True, None),
                ("an old two-field record", "namespace", None, "parked", None, None, False, False, "released"),
                ("other code", "namespace", "0123456789abcdef", "parked", None, None, False, False, "released"),
                ("other code serving a sandbox", "namespace", "0123456789abcdef", "active:3", None, None, False, True,
                 "left running"),
                ("other code woken for a handoff", "namespace", "0123456789abcdef", "waking", None, None, False,
                 True, "left running"),
                ("other code with a handoff entry pending", "namespace", "0123456789abcdef", "parked", "3", None,
                 False, True, "handoff entries pending: 3"),
                ("other code with a wake pending", "namespace", "0123456789abcdef", "parked", "wake", None,
                 False, True, "a wake is pending"),
                ("two unreadable code identities", "namespace", "unreadable-EACCES", "parked", None,
                 "unreadable-EACCES", False, False, "released"),
                ("host mode", "host", None, "parked", None, None, True, True, None)):
            os.environ["RHIZO_SELINUX_MODE"] = mode
            sup = parked_child(tmp, os.path.basename(sys.argv[0]), block_usr1=entry == "wake")
            spawned.append(sup)
            if entry == "wake":
                os.kill(sup.pid, signal.SIGUSR1)
            record(sup.pid, boot_id if mode == "namespace" else None, code=code if mode == "namespace" else None,
                   start=start_ticks(sup.pid) if mode == "namespace" and code else None)
            with open(launcher.SUPERVISOR_STATE, "w") as f:
                f.write(state)
            for name in os.listdir(launcher.HANDOFF_DIR):
                os.unlink(os.path.join(launcher.HANDOFF_DIR, name))
            if entry and entry != "wake":
                with open(os.path.join(launcher.HANDOFF_DIR, entry), "w") as f:
                    f.write("1234 selinux_setup")
            saved_loaded = getattr(launcher, "LOADED_CODE_ID", None)
            if loaded_id:
                launcher.LOADED_CODE_ID = loaded_id
            logs.clear()
            try:
                got = launcher.await_resident_g(5)
            finally:
                launcher.LOADED_CODE_ID = saved_loaded
            alive = sup.poll() is None
            stale = [l for l in logs if "selinuxns=supervisor-stale" in l]
            if ((got == sup.pid) != want_handoff or alive != want_alive or os.path.exists(pid_file) != want_alive
                    or (want_note is None) != (not stale) or (want_note and want_note not in stale[0])):
                bad.append(("a supervisor's code against the installed code", label,
                            ("handoff" if want_handoff else "cold start", "alive" if want_alive else "released"),
                            (got, alive, os.path.exists(pid_file)), logs[:]))

        os.environ["RHIZO_SELINUX_MODE"] = "namespace"
        with open(launcher.SUPERVISOR_STATE, "w") as f:
            f.write("parked")
        sup = parked_child(tmp, os.path.basename(sys.argv[0]))
        spawned.append(sup)
        for label, boot, start, want in (
                ("this boot and its start time", boot_id, start_ticks(sup.pid), sup.pid),
                ("another boot", "another-boot", start_ticks(sup.pid), None),
                ("this boot and another start time", boot_id, start_ticks(sup.pid) - 1, None)):
            record(sup.pid, boot, code=launcher.LOADED_CODE_ID, start=start)
            logs.clear()
            got = (launcher.recorded_pid(), launcher.recorded_g_alive(), launcher.resident_g_pid(),
                   launcher.i_am_recorded_supervisor(), launcher.await_resident_g(3))
            waited = any("waiting for supervisor" in l for l in logs)
            if got != (want, want is not None, want, False, want) or waited != (want is not None) \
                    or (want is None and not any("refused" in l for l in logs)) or sup.poll() is not None:
                bad.append(("a supervisor record trusted only by its boot id and start time", label,
                            (want, want is not None, want, False, want), got, logs[:]))
        saved_resident = launcher.RHIZO_RESIDENT_G
        launcher.RHIZO_RESIDENT_G = True
        try:
            for label, boot, offset, want_killed in (("another boot", "another-boot", 0, False),
                                                     ("another start time", boot_id, -1, False),
                                                     ("this boot and its start time", boot_id, 0, True)):
                victim = subprocess.Popen(["sleep", "60"])
                spawned.append(victim)
                record(victim.pid, boot, code=launcher.LOADED_CODE_ID, start=start_ticks(victim.pid) + offset)
                launcher.reap_resident_supervisor_if_shutting_down(shutting_down=lambda: True)
                try:
                    victim.wait(timeout=2 if want_killed else 0.5)
                except subprocess.TimeoutExpired:
                    pass
                if (victim.poll() is not None) != want_killed:
                    bad.append(("the shutdown reap kills only a supervisor of this boot with its recorded start time",
                                label, want_killed, victim.poll()))
        finally:
            launcher.RHIZO_RESIDENT_G = saved_resident
    finally:
        for child in [other, same, relative, twin] + spawned:
            child.kill()
            child.wait()
        sys.argv[0] = saved_argv0
        launcher.SUPERVISOR_STATE, launcher.HANDOFF_DIR = saved_state, saved_handoff
        launcher.G_PID_FILE, launcher.kmsg = saved
        os.environ.pop("RHIZO_SELINUX_MODE", None)

run_sandbox = fns["run_sandbox"]


def run_in_child(code, scope):
    """exec code in a forked child and return its exit code"""
    pid = os.fork()
    if pid == 0:
        try:
            exec(code, scope)
        except BaseException:
            os._exit(98)
        os._exit(0)
    return os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])


early = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If)
         and ast.unparse(n.test) in ("not _CGROUP_ROOT", "not join_cgroup(_CGROUP_ROOT, os.getpid(), kmsg)")]
if len(early) != 2:
    bad.append(("g's early exits", "the _CGROUP_ROOT and join_cgroup refusals", [ast.unparse(n.test) for n in early]))
for block in early:
    code = compile(ast.Module(body=[block], type_ignores=[]), "boot.py", "exec")
    reason = "cgroup-root-unset" if "join_cgroup" not in ast.unparse(block.test) else "cgroup-root-join-failed"
    for mode, want_code, want_after in (("namespace", ns.RELABELLER_REFUSED_EXIT, f"refused:{reason}"),
                                        ("host", 1, "pending")):
        d = records_with("pending")
        dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
        scope = dict(vars(launcher), _CGROUP_ROOT="" if reason == "cgroup-root-unset" else "/nonexistent-cg",
                     _verdict_dir=dfd if mode == "namespace" else -1, kmsg=lambda m: None,
                     join_cgroup=lambda root, pid, log: False)
        try:
            got = run_in_child(code, scope)
        finally:
            os.close(dfd)
        if got != want_code or verdict_in(d) != want_after:
            bad.append(("g's early exit", reason, mode, want_code, want_after, got, verdict_in(d)))

waits = [i for i, n in enumerate(run_sandbox.body) if ast.unparse(n) == "_, _g_status = os.waitpid(g, 0)"]
if len(waits) != 1 or len(run_sandbox.body) != waits[0] + 2:
    bad.append(("the supervisor's wait on g", "a waitpid then its refusal test, last in run_sandbox", waits))
else:
    gwait = compile(ast.Module(body=run_sandbox.body[waits[0]:], type_ignores=[]), "boot.py", "exec")
    for mode, code, verdict, want_refused, want_after in (
            ("namespace", 1, "pending", True, "refused:g-exit-1"),
            ("namespace", -signal.SIGKILL, "pending", True, "refused:g-signal-9"),
            ("namespace", -signal.SIGKILL, "enforced", True, "enforced"),
            ("host", -signal.SIGKILL, "pending", False, "pending"),
            ("namespace", 3, "refused:relabeller-timeout", True, "refused:relabeller-timeout"),
            ("namespace", 0, "stopped", False, "stopped"),
            ("host", 3, "pending", True, "pending"),
            ("host", 1, "pending", False, "pending")):
        os.environ["RHIZO_SELINUX_MODE"] = mode
        d = records_with(verdict)
        g = child_exit(code) if code >= 0 else os.fork()
        if g == 0:
            os.kill(os.getpid(), -code)
            os._exit(0)
        refused = []
        scope = dict(vars(launcher), g=g, refuse_start=lambda: refused.append(True),
                     record_refusal_unless_final=lambda reason, d=d: launcher.record_refusal_unless_final(reason, d))
        try:
            exec(gwait, scope)
        except BaseException as e:
            refused.append(repr(e))
        if refused != ([True] if want_refused else []) or verdict_in(d) != want_after:
            bad.append(("the supervisor's wait on g", mode, code, verdict, want_refused, want_after, refused,
                        verdict_in(d)))
    os.environ.pop("RHIZO_SELINUX_MODE", None)

flips = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If)
         and ast.unparse(n.test) == "_relabel in ('enforced', 'permissive')"]
if len(flips) != 1:
    bad.append(("g's first-flip report", "one block", len(flips)))
else:
    flip = compile(ast.Module(body=flips, type_ignores=[]), "boot.py", "exec")
    verdicts = []
    stub = type("Ns", (), {"record_verdict": staticmethod(lambda v, d: verdicts.append(v)),
                           "record_android_enforce": staticmethod(lambda v, d: verdicts.append(f"android-enforce={v}"))})
    for label, reader_open in (("supervisor waiting", True), ("supervisor gone", False)):
        r, w = os.pipe()
        if not reader_open:
            os.close(r)
        logs = []
        scope = {"_relabel": "enforced", "_verdict_dir": 9, "_first_w": w, "os": os, "kmsg": logs.append,
                 "selinux_ns": stub}
        try:
            exec(flip, scope)
        except BaseException as e:
            scope["raised"] = repr(e)
        try:
            os.fstat(w)
            closed = False
            os.close(w)
        except OSError:
            closed = True
        got_byte = os.read(r, 1) if reader_open else None
        if reader_open:
            os.close(r)
        if ("raised" in scope or scope["_first_w"] != -1 or not closed
                or got_byte != (b"1" if reader_open else None)
                or any("first-flip byte" in l for l in logs) == reader_open):
            bad.append(("g's first-flip report", label, scope.get("raised"), scope["_first_w"], closed, got_byte, logs))
    if verdicts != ["enforced", "android-enforce=1"] * 2:
        bad.append(("g records the flip's verdict and Android's enforce state", verdicts))

body = run_sandbox.body
at = {}
for i, n in enumerate(body):
    text = ast.unparse(n)
    if isinstance(n, ast.Assign) and text.startswith("_verdict_dir ="):
        at["open"] = i
    elif isinstance(n, ast.If) and "record_verdict('pending'" in text:
        at["pending"] = i
    elif isinstance(n, ast.Assign) and text == "g = os.fork()":
        at["fork"] = i
if sorted(at) != ["fork", "open", "pending"] or not at["open"] < at["pending"] < at["fork"]:
    bad.append(("pending verdict before g's fork", "open < pending < fork", at))
else:
    mark = compile(ast.Module(body=[body[at["open"]], body[at["pending"]]], type_ignores=[]), "boot.py", "exec")
    for mode, want in (("namespace", "pending"), ("host", "enforced")):
        with tempfile.TemporaryDirectory() as tmp:
            records, run_root = os.path.join(tmp, "rhizo-selinuxns"), os.path.join(tmp, "rhizo")
            for d in (records, run_root):
                os.mkdir(d)
                with open(os.path.join(d, os.path.basename(ns.VERDICT_FILE)), "w") as f:
                    f.write("enforced\n")
            scope = {"SELINUXNS_RECORDS_DIR": records, "RUN_ROOT": run_root, "os": os,
                     "host_selinux_mode": lambda: mode == "host", "selinux_ns": ns,
                     "open_records_or_refuse": getattr(launcher, "open_records_or_refuse", None)}
            exec(mark, scope)
            got = []
            for d in (records, run_root):
                dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
                got.append(ns.read_verdict(dfd))
                os.close(dfd)
            if scope["_verdict_dir"] >= 0:
                os.close(scope["_verdict_dir"])
            if got != [want, "enforced"]:
                bad.append(("verdict before g's fork in the records dir, never the run root", mode,
                            [want, "enforced"], got))

    class Refused(Exception):
        """raised in place of refuse_start"""

    def refuse_stub():
        """raise in place of refusing the start"""
        raise Refused()

    with tempfile.TemporaryDirectory() as tmp:
        blocker = os.path.join(tmp, "not-a-dir")
        open(blocker, "w").close()
        logs = []
        saved_refuse = (launcher.refuse_start, launcher.kmsg)
        launcher.refuse_start, launcher.kmsg = refuse_stub, logs.append
        scope = {"SELINUXNS_RECORDS_DIR": os.path.join(blocker, "rhizo-selinuxns"), "os": os,
                 "host_selinux_mode": lambda: False, "selinux_ns": ns,
                 "open_records_or_refuse": getattr(launcher, "open_records_or_refuse", None)}
        try:
            exec(compile(ast.Module(body=[body[at["open"]]], type_ignores=[]), "boot.py", "exec"), scope)
            got = ("opened", scope.get("_verdict_dir"))
        except Refused:
            got = ("refused",)
        except Exception as e:
            got = ("raised", repr(e))
        finally:
            launcher.refuse_start, launcher.kmsg = saved_refuse
        marker = "RHIZO_MARKER selinuxns=refused reason=records-dir-failed errno=%d" % errno.ENOTDIR
        if got != ("refused",) or not any(l.startswith(marker) for l in logs):
            bad.append(("an unopenable records dir", "refused with " + marker, got, logs))


def read_records(dfd):
    """return the records dir's verdict, enforce state and inodes"""
    names = [os.path.basename(p) for p in (ns.VERDICT_FILE, ns.ANDROID_ENFORCE_FILE)]
    return ([open(f"/proc/self/fd/{dfd}/{n}").read().strip() for n in names],
            [os.stat(n, dir_fd=dfd).st_ino for n in names])


ends = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If)
        and ast.unparse(n.test).startswith("_verdict_dir >= 0 and (not _ns_handoff)")]
if len(ends) != 1:
    bad.append(("g's end record", "one if _verdict_dir >= 0 and not _ns_handoff", len(ends)))
else:
    end = compile(ast.Module(body=ends, type_ignores=[]), "boot.py", "exec")
    saved_kmsg = ns.kmsg
    ns.kmsg = lambda m: None
    try:
        for label, relabel, why, exited, handoff, seed, want in (
                ("init exited after an enforced flip", "enforced", "", True, False, ("enforced", "1"), ("stopped", "0")),
                ("init exited after a permissive start", "permissive", "", True, False, ("permissive", "0"),
                 ("stopped", "0")),
                ("init still running after an enforced flip", "enforced", "", False, False, ("enforced", "1"), None),
                ("relabeller timeout", "timeout", "", False, False, ("pending", "0"),
                 ("refused:relabeller-timeout", "0")),
                ("init exited before the flip", "failed", "init-exited-before-flip", True, False, ("pending", "0"),
                 ("refused:init-exited-before-flip", "0")),
                ("init stopped before the flip", "pending", "", True, False, ("pending", "0"), ("stopped", "0")),
                ("handoff after the joiner's flip", "enforced", "", True, True, ("enforced", "1"), None)):
            with tempfile.TemporaryDirectory() as tmp:
                dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    ns.record_verdict(seed[0], dfd)
                    ns.write_android_enforce(seed[1], ns.ANDROID_ENFORCE_FILE, dir_fd=dfd)
                    before = read_records(dfd)
                    scope = {"_verdict_dir": dfd, "_ns_handoff": handoff, "_relabel": relabel, "_why": why,
                             "_gg_exited": exited, "selinux_ns": ns}
                    try:
                        exec(end, scope)
                    except BaseException as e:
                        bad.append(("g's end record", label, "raised", repr(e)))
                    after = read_records(dfd)
                finally:
                    os.close(dfd)
            if (want is None and after != before) or (want is not None and after[0] != list(want)):
                bad.append(("g's end record", label, want or "records untouched", after[0],
                            "rewritten" if after[1] != before[1] else "same inodes"))
        try:
            exec(end, {"_verdict_dir": -1, "_ns_handoff": False, "_relabel": "enforced", "_why": "",
                       "_gg_exited": True, "selinux_ns": None})
        except BaseException as e:
            bad.append(("g's end record", "host mode", "records nothing", repr(e)))
    finally:
        ns.kmsg = saved_kmsg

saved_kmsg = (launcher.kmsg, ns.kmsg)
launcher.kmsg = ns.kmsg = lambda m: None
try:
    end_fn = getattr(launcher, "sandbox_end_fails_unit", None)
    for label, status, verdict, want_fail, want_after in (
            ("a stopped sandbox", child_status(0), "stopped", False, "stopped"),
            ("a refused sandbox", child_status(3), "refused:input-fence", True, "refused:input-fence"),
            ("a killed sandbox", child_status(0, signal.SIGKILL), "enforced", True, "refused:g-signal-9"),
            ("a stopped sandbox whose verdict is a refusal", child_status(0), "refused:holder-ended", True,
             "refused:holder-ended"),
            ("an unreadable report", None, "enforced", True, "refused:g-gone")):
        d = records_with(verdict)
        got = "absent" if end_fn is None else end_fn(status, records_dir=d)
        if got != want_fail or verdict_in(d) != want_after:
            bad.append(("sandbox_end_fails_unit", label, want_fail, want_after, got, verdict_in(d)))
    r, w = os.pipe()
    report, read_end = getattr(launcher, "report_sandbox_end", None), getattr(launcher, "read_sandbox_end", None)
    if report is None or read_end is None:
        bad.append(("the sandbox end report", "report_sandbox_end and read_sandbox_end", "absent"))
        os.close(w)
        os.close(r)
    else:
        report(w, child_status(0, signal.SIGKILL), lambda m: None)
        if read_end(r) != signal.SIGKILL:
            bad.append(("the sandbox end report", "the wait status round-trips"))
    sup_fn = fns["run_kernel_domain_supervisor"]
    reaps = [n for n in ast.walk(sup_fn) if isinstance(n, ast.While)
             and "active.pop(reaped_pid, None)" in ast.unparse(n)]
    reaps = [n for n in reaps if not any(m is not n and m in ast.walk(n) for m in reaps)]
    if len(reaps) != 1:
        bad.append(("the park loop's reaping", "one loop", len(reaps)))
    else:
        reap_code = compile(ast.Module(body=reaps, type_ignores=[]), "boot.py", "exec")
        r, w = os.pipe()
        killed = child_status(0, signal.SIGKILL)
        waits = [(4242, killed), (5151, 0)]

        class ReapOs:
            """os stand-in answering two reaps, then no child"""
            WNOHANG = os.WNOHANG

            @staticmethod
            def waitpid(pid, flags):
                """answer the next reap"""
                if not waits:
                    raise ChildProcessError(10, "No child processes")
                return waits.pop(0)

        scope = {"os": ReapOs, "active": {}, "first_g": 4242, "end_fd": w, "slog": lambda m: None,
                 "report_sandbox_end": getattr(launcher, "report_sandbox_end", lambda fd, st, log: os.close(fd)),
                 "release_namespace_holder": lambda pid, log: None}
        exec(reap_code, scope)
        if scope.get("end_fd") != -1:
            os.close(w)
        got = os.read(r, 32)
        os.close(r)
        if got != str(killed).encode():
            bad.append(("the park loop's reaping", "the first sandbox's wait status on the end pipe", got))
    if len(reaps) == 1:
        for label, joiner_status, want_records in (
                ("a joiner the OOM killer ended", child_status(0, signal.SIGKILL),
                 [("joiner-signal-9", "start_ended")]),
                ("a joiner that raised", child_status(1), [("joiner-exit-1", "start_ended")]),
                ("a joiner that saw init's end", child_status(0), [])):
            events, waits = [], [(777, joiner_status)]

            class JoinerReapOs:
                """os stand-in answering a joiner's reap, then no child"""
                WNOHANG = os.WNOHANG
                WIFEXITED, WEXITSTATUS = staticmethod(os.WIFEXITED), staticmethod(os.WEXITSTATUS)

                @staticmethod
                def waitpid(pid, flags):
                    """answer the joiner's reap"""
                    if not waits:
                        raise ChildProcessError(10, "No child processes")
                    return waits.pop(0)

            paths = type("Paths", (), {"records_dir": "/run/rhizo-selinuxns-3"})
            scope = dict(vars(launcher), os=JoinerReapOs, active={777: (3, 4242, 55)}, first_g=None, end_fd=-1,
                         slog=lambda m: None, host_selinux_mode=lambda: False,
                         core=type("Env", (), {"paths_for": staticmethod(lambda i: paths)}),
                         record_refusal_unless_final=lambda reason, d, keep=None: events.append(
                             ("record", reason, d, getattr(keep, "__name__", keep))),
                         release_namespace_holder=lambda fd, pid, log: events.append(("release", fd, pid)))
            try:
                exec(reap_code, scope)
            except Exception as e:
                events.append(("raised", repr(e)))
            want = ([("record", r, "/run/rhizo-selinuxns-3", k) for r, k in want_records]
                    + [("release", 55, 4242)])
            if events != want:
                bad.append(("the park loop's joiner reap", label, want, events))
    release = getattr(launcher, "release_namespace_holder")
    live = os.fork()
    if live == 0:
        signal.pause()
        os._exit(0)
    gone = child_exit(0)
    live_fd, gone_fd = os.pidfd_open(live), os.pidfd_open(gone)
    os.waitpid(gone, 0)
    sent, saved_kill = [], os.kill
    os.kill = lambda pid, sig: sent.append(pid)
    try:
        release(live_fd, live, lambda m: None)
        release(gone_fd, gone, lambda m: None)
    except TypeError as e:
        sent.append(repr(e))
    finally:
        os.kill = saved_kill
    if sent:
        os.kill(live, signal.SIGKILL)
    killed = os.waitpid(live, 0)[1]
    if sent or not (os.WIFSIGNALED(killed) and os.WTERMSIG(killed) == signal.SIGKILL):
        bad.append(("release_namespace_holder", "a SIGKILL through the pidfd and no kill by pid", sent, killed))
    for fd in (live_fd, gone_fd):
        try:
            os.fstat(fd)
            bad.append(("release_namespace_holder", "closes the holder's pidfd", fd))
            os.close(fd)
        except OSError:
            pass
    main_text = ast.unparse(fns["main"])
    for needle in ("end_r, end_w = os.pipe2(os.O_CLOEXEC)", "run_kernel_domain_supervisor(entry, end_fd=end_w)",
                   "if sandbox_end_fails_unit(read_sandbox_end(end_r)):"):
        if needle not in main_text:
            bad.append(("MainPID ends the unit with the parked supervisor's first sandbox", needle))
    if "return g" not in ast.unparse(fns["run_sandbox"]):
        bad.append(("run_sandbox hands the parked supervisor its sandbox", "return g"))
    first_pairs = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.Assign)
                   and ast.unparse(n.targets[0]).strip("()") == "_first_r, _first_w"]
    first_text = ast.unparse(first_pairs[0].value) if len(first_pairs) == 1 else ""
    for needle in ("not host_selinux_mode()", "RHIZO_RESIDENT_DISPATCH", "i_am_recorded_supervisor()",
                   "os.pipe2(os.O_CLOEXEC)", "(-1, -1)"):
        if needle not in first_text:
            bad.append(("_first_r exists only for the recorded supervisor in namespace mode, close-on-exec",
                        needle, first_text))
    waits = "_first_r >= 0 and selinux_ns.wait_first_flip(_first_r, g, reasons=_g_why) == 'refused'"
    parks = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If) and ast.unparse(n.test) == waits]
    if len(parks) != 1 or [ast.unparse(x) for x in parks[0].body] != [
            "record_refusal_unless_final(_g_why[0])", "refuse_start()"]:
        bad.append(("the parked supervisor waits for the first flip on _first_r and refuses a g that failed before it",
                    "wait_first_flip(_first_r, g, ...) == 'refused', then the recorded reason and refuse_start()",
                    [ast.unparse(n.test) for n in parks]))
    park_branch = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If) and parks
                   and ast.unparse(n.test) == "RHIZO_RESIDENT_DISPATCH and i_am_recorded_supervisor()"
                   and parks[0] in ast.walk(n)]
    if parks and not park_branch:
        bad.append(("the first-flip wait runs only in the recorded supervisor's park branch",))
    first_writes = [ast.unparse(c) for c in ast.walk(run_sandbox) if isinstance(c, ast.Call)
                    and ast.unparse(c.func) == "os.write" and ast.unparse(c.args[0]) == "_first_w"]
    if first_writes != ["os.write(_first_w, b'1')"]:
        bad.append(("g writes the first-flip byte to _first_w once", ["os.write(_first_w, b'1')"], first_writes))
    g_closes_r = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.If) and ast.unparse(n.test) == "_first_r >= 0"
                  and [ast.unparse(x) for x in n.body] == ["os.close(_first_r)"]]
    if len(g_closes_r) != 1:
        bad.append(("g closes its copy of _first_r", 1, len(g_closes_r)))
finally:
    launcher.kmsg, ns.kmsg = saved_kmsg

for b in bad:
    print("FAIL", b)
print("ok" if not bad else "FAIL")
sys.exit(1 if bad else 0)
