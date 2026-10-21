#!/usr/bin/env python3
import ast, contextlib, inspect, io, os, signal, sys, tempfile, time
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-host-phase")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
    from sandbox import selinux_labels

bad = []
tmp = tempfile.TemporaryDirectory()
calls = []


def run_phase(mode):
    """run acquire_host_global_phase and label_host_binaries under mode"""
    calls.clear()
    os.environ["RHIZO_SELINUX_MODE"] = mode
    lock = os.open(os.path.join(tmp.name, "lock"), os.O_RDWR | os.O_CREAT)
    handoff = os.path.join(tmp.name, "handoff")
    saved = (launcher.hostlock.acquire_host_lock, launcher.hostlock.release_host_lock, launcher.kmsg,
             launcher.policy_is_loaded, launcher.check_policy_load, launcher.write_policy_refusal,
             launcher.HANDOFF_DIR, os.makedirs, os.setxattr, os.getxattr, selinux_labels.kmsg,
             selinux_labels.label_host_modules, selinux_labels.RHIZO_ENFORCING)
    import shutil
    saved_rmtree = shutil.rmtree
    saved_prepare = getattr(launcher, "prepare_handoff_host_state", None)
    try:
        launcher.prepare_handoff_host_state = lambda *a, **k: calls.append("prepare")
        launcher.hostlock.acquire_host_lock = lambda: (calls.append("lock"), lock)[1]
        launcher.hostlock.release_host_lock = lambda fd: calls.append("unlock")
        launcher.kmsg = lambda m: calls.append("kmsg:" + m)
        selinux_labels.kmsg = lambda m: None
        launcher.policy_is_loaded = lambda: False
        launcher.check_policy_load = lambda: (calls.append("check_policy_load"), None)[1]
        launcher.write_policy_refusal = lambda r: calls.append("write_policy_refusal")
        launcher.HANDOFF_DIR = handoff
        shutil.rmtree = lambda *a, **k: calls.append("rmtree")
        os.makedirs = lambda *a, **k: calls.append("makedirs")
        os.setxattr = lambda *a, **k: calls.append("setxattr")
        os.getxattr = lambda *a, **k: (_ for _ in ()).throw(OSError())
        selinux_labels.label_host_modules = lambda: (0, 0, [])
        selinux_labels.RHIZO_ENFORCING = True
        selinux_labels.open = lambda *a, **k: (_ for _ in ()).throw(OSError())
        got = launcher.acquire_host_global_phase()
        selinux_labels.label_host_binaries()
        pol = selinux_labels.check_policy_load()
    finally:
        (launcher.hostlock.acquire_host_lock, launcher.hostlock.release_host_lock, launcher.kmsg,
         launcher.policy_is_loaded, launcher.check_policy_load, launcher.write_policy_refusal,
         launcher.HANDOFF_DIR, os.makedirs, os.setxattr, os.getxattr, selinux_labels.kmsg,
         selinux_labels.label_host_modules, selinux_labels.RHIZO_ENFORCING) = saved
        shutil.rmtree = saved_rmtree
        if saved_prepare is None:
            del launcher.prepare_handoff_host_state
        else:
            launcher.prepare_handoff_host_state = saved_prepare
        if hasattr(selinux_labels, "open"):
            del selinux_labels.open
        os.close(lock)
    return got, list(calls), pol, lock


got, c, pol, lock = run_phase("namespace")
if got != lock:
    bad.append(("namespace returns the held lock fd", lock, got))
if "lock" not in c:
    bad.append(("namespace takes the host lock", "lock call", c))
if "kmsg:RHIZO_MARKER selinuxns=host-phase-skipped" not in c:
    bad.append(("namespace logs the skipped marker", "marker", c))
for name in ("check_policy_load", "write_policy_refusal", "rmtree", "makedirs", "setxattr", "unlock"):
    if name in c:
        bad.append(("namespace must not call " + name, "absent", c))
if pol is not None:
    bad.append(("namespace check_policy_load", None, pol))
if "prepare" not in c or "lock" not in c or c.index("lock") > c.index("prepare"):
    bad.append(("namespace prepares the handoff host state under the host lock", "lock then prepare", c))

got, c, pol, lock = run_phase("host")
if got != lock:
    bad.append(("host returns the held lock fd", lock, got))
for name in ("lock", "check_policy_load", "write_policy_refusal", "rmtree", "makedirs", "setxattr"):
    if name not in c:
        bad.append(("host must call " + name, "present", c))
if "kmsg:RHIZO_MARKER selinuxns=host-phase-skipped" in c:
    bad.append(("host logs no skipped marker", "absent", c))
if "prepare" in c:
    bad.append(("host must not call prepare_handoff_host_state", "absent", c))


def run_prepare(handoff_dir, cgroup, boot_time):
    """run prepare_handoff_host_state on scratch paths"""
    logged = []
    saved_kmsg = launcher.kmsg
    launcher.kmsg = logged.append
    try:
        launcher.prepare_handoff_host_state(handoff_dir=handoff_dir, supervisor_cgroup=cgroup, boot_time=boot_time)
        raised = None
    except Exception as e:
        raised = e
    finally:
        launcher.kmsg = saved_kmsg
    return logged, raised


def write_file(p, mtime=None):
    """create the file p with an optional mtime"""
    with open(p, "w") as f:
        f.write("1 second_stage\n")
    if mtime is not None:
        os.utime(p, (mtime, mtime))


if not hasattr(launcher, "prepare_handoff_host_state"):
    bad.append(("launcher defines prepare_handoff_host_state", "present", "absent"))
else:
    import stat
    boot = int(time.time()) - 50
    scratch = tempfile.mkdtemp(dir=tmp.name)

    hdir, cg = os.path.join(scratch, "handoff.d"), os.path.join(scratch, "rhizo-host")
    logged, raised = run_prepare(hdir, cg, lambda: boot)
    if raised is not None:
        bad.append(("prepare on missing dirs raises nothing", None, repr(raised)))
    if not os.path.isdir(hdir) or stat.S_IMODE(os.stat(hdir).st_mode) != 0o700:
        bad.append(("missing handoff dir created 0700", "0o700",
                    oct(stat.S_IMODE(os.stat(hdir).st_mode)) if os.path.isdir(hdir) else "absent"))
    if not os.path.isdir(cg):
        bad.append(("missing supervisor cgroup created", "dir", "absent"))

    for name, mtime in (("1", None), (".1.98.tmp", None), ("2", boot - 100), (".2.99.tmp", boot - 100)):
        write_file(os.path.join(hdir, name), mtime)
    os.mkdir(os.path.join(hdir, "olddir"))
    os.utime(os.path.join(hdir, "olddir"), (boot - 100, boot - 100))
    logged, raised = run_prepare(hdir, cg, lambda: boot)
    left = sorted(os.listdir(hdir))
    if raised is not None or left != [".1.98.tmp", "1", "olddir"]:
        bad.append(("this boot's entries kept, older files removed", [".1.98.tmp", "1", "olddir"], left, repr(raised)))
    for name in ("2", ".2.99.tmp"):
        if not any(os.path.join(hdir, name) in m for m in logged):
            bad.append(("removal of an older entry logged with its path", name, logged))

    blocker = os.path.join(scratch, "a-file")
    write_file(blocker)
    bad_hdir, bad_cg = os.path.join(blocker, "handoff.d"), os.path.join(blocker, "rhizo-host")
    logged, raised = run_prepare(bad_hdir, bad_cg, lambda: boot)
    if raised is not None:
        bad.append(("an OSError on either path raises nothing", None, repr(raised)))
    for p in (bad_hdir, bad_cg):
        if not any(p in m for m in logged):
            bad.append(("an OSError is logged with its path", p, logged))
    cg2 = os.path.join(scratch, "rhizo-host-2")
    logged, raised = run_prepare(bad_hdir, cg2, lambda: boot)
    if raised is not None or not os.path.isdir(cg2):
        bad.append(("a handoff dir failure still creates the supervisor cgroup", "dir", logged, repr(raised)))

    write_file(os.path.join(hdir, "3"), boot - 100)

    def no_btime():
        """raise the error a missing btime line raises"""
        raise OSError("/proc/stat has no btime line")
    logged, raised = run_prepare(hdir, cg, no_btime)
    if raised is not None or "3" not in os.listdir(hdir) or not any(hdir in m for m in logged):
        bad.append(("an unreadable boot time is logged with the handoff dir and removes nothing",
                    "kept and logged", sorted(os.listdir(hdir)), logged, repr(raised)))

tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
phase_fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "acquire_host_global_phase")
ns_if = next(n for n in phase_fn.body if isinstance(n, ast.If) and ast.unparse(n.test) == "not host_selinux_mode()")
ns_calls = [ast.unparse(n) for s in ns_if.body for n in ast.walk(s) if isinstance(n, ast.Call)]
if "prepare_handoff_host_state()" not in ns_calls:
    bad.append(("namespace branch calls prepare_handoff_host_state()", "present", ns_calls))
first_actor = ast.unparse(ast.parse(
    "try:\n"
    "    import shutil as _sh_hoff\n"
    "    _sh_hoff.rmtree(HANDOFF_DIR, ignore_errors=True)\n"
    "    os.makedirs(HANDOFF_DIR, mode=0o700)\n"
    "except OSError as e:\n"
    "    kmsg(f'could not recreate {HANDOFF_DIR}: {e}')\n"))
tries = [ast.unparse(n) for n in phase_fn.body if isinstance(n, ast.Try)]
if tries != [first_actor]:
    bad.append(("host mode's first-actor HANDOFF_DIR block unchanged", first_actor, tries))
if "prepare_handoff_host_state" in ast.unparse(ast.Module(body=phase_fn.body[phase_fn.body.index(ns_if) + 1:],
                                                          type_ignores=[])):
    bad.append(("host mode path calls no prepare_handoff_host_state", "absent", "present"))


def run_reset(records_dir):
    """return the reset's kmsg lines and exception"""
    os.environ["INVOCATION_ID"] = "0123456789abcdef0123456789abcdef"
    logged = []
    saved = (launcher.kmsg, launcher.selinux_ns.kmsg)
    launcher.kmsg = launcher.selinux_ns.kmsg = logged.append
    try:
        launcher.reset_namespace_start_records(records_dir=records_dir)
        raised = None
    except (Exception, SystemExit) as e:
        raised = e
    finally:
        launcher.kmsg, launcher.selinux_ns.kmsg = saved
    return logged, raised


if not hasattr(launcher, "reset_namespace_start_records"):
    bad.append(("launcher defines reset_namespace_start_records", "present", "absent"))
else:
    mode_file = os.path.join(tmp.name, "selinux-mode")
    with open(mode_file, "w") as f:
        f.write("namespace\n")
    enforce_name = os.path.basename(launcher.selinux_ns.ANDROID_ENFORCE_FILE)
    verdict_name = os.path.basename(launcher.selinux_ns.VERDICT_FILE)
    for label, prior in (("a previous start's records", ("1\n", "refused:x\n")), ("a missing records dir", None)):
        records_dir = os.path.join(tempfile.mkdtemp(dir=tmp.name), "run-rhizo-selinuxns")
        if prior is not None:
            os.mkdir(records_dir)
            for name, text in zip((enforce_name, verdict_name), prior):
                with open(os.path.join(records_dir, name), "w") as f:
                    f.write(text)
        logged, raised = run_reset(records_dir)
        got = (launcher.hostlock.android_enforce_state(mode_file=mode_file,
                                                              state_file=os.path.join(records_dir, enforce_name)),
               launcher.hostlock.selinuxns_verdict(mode_file=mode_file,
                                                         verdict_file=os.path.join(records_dir, verdict_name)))
        if raised is not None or got != ("0", "pending"):
            bad.append(("reset over " + label + " reads 0 and pending", ("0", "pending"), got, logged, repr(raised)))
        start_id = os.path.join(records_dir, "start-id")
        got_id = open(start_id).read().strip() if os.path.exists(start_id) else None
        if got_id != os.environ.get("INVOCATION_ID", ""):
            bad.append(("reset over " + label + " records this unit invocation's id", os.environ.get("INVOCATION_ID", ""),
                        got_id))
    blocked_dir = os.path.join(tmp.name, "a-run-file", "rhizo-selinuxns")
    write_file(os.path.dirname(blocked_dir))
    logged, raised = run_reset(blocked_dir)
    if not (isinstance(raised, SystemExit) and raised.code == 1) \
            or not any(blocked_dir in m and "reason=records-dir-unopenable" in m for m in logged):
        bad.append(("an unopenable records dir refuses the start with its path", blocked_dir, logged, repr(raised)))
    default = inspect.signature(launcher.reset_namespace_start_records).parameters.get("records_dir")
    if default is None or default.default != launcher.SELINUXNS_RECORDS_DIR:
        bad.append(("reset_namespace_start_records defaults to SELINUXNS_RECORDS_DIR",
                    getattr(launcher, "SELINUXNS_RECORDS_DIR", None), default and default.default))

main_fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "main")


def first_line(call_name, within=main_fn):
    """return the line of the first call to call_name inside within, or None"""
    lines = [n.lineno for n in ast.walk(within) if isinstance(n, ast.Call) and ast.unparse(n.func) == call_name]
    return min(lines) if lines else None


reset_ifs = [n for n in main_fn.body if isinstance(n, ast.If) and first_line("reset_namespace_start_records", n)]
order = [first_line(c) for c in ("selinux_ns.write_mode_file", "reset_namespace_start_records",
                                 "acquire_host_global_phase", "arm_host_lock_releaser")]
if len(reset_ifs) != 1 or ast.unparse(reset_ifs[0].test) != "not host_selinux_mode()" or reset_ifs[0].orelse:
    bad.append(("main calls reset_namespace_start_records in a namespace-mode branch alone",
                "if not host_selinux_mode()", [ast.unparse(n.test) for n in reset_ifs]))
if None in order or order != sorted(order):
    bad.append(("main: write_mode_file, reset, acquire_host_global_phase, arm_host_lock_releaser in order",
                "ascending lines", order))
lock_at = [first_line(c, reset_ifs[0]) if len(reset_ifs) == 1 else None
           for c in ("hold_start_lock_or_refuse", "reset_namespace_start_records")]
if None in lock_at or lock_at != sorted(lock_at):
    bad.append(("main holds the start lock before it resets the records, in the namespace branch", lock_at))


def in_child(fn):
    """run fn in a forked child and return its exit code"""
    pid = os.fork()
    if pid == 0:
        try:
            os._exit(fn())
        except SystemExit as e:
            os._exit(e.code if isinstance(e.code, int) else 98)
        except BaseException:
            os._exit(99)
    return os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])


take = getattr(launcher, "take_start_lock", None)
hold = getattr(launcher, "hold_start_lock_or_refuse", None)
if take is None or hold is None:
    bad.append(("launcher defines take_start_lock and hold_start_lock_or_refuse", "present", "absent"))
else:
    locks = os.path.join(tempfile.mkdtemp(dir=tmp.name), "rhizo-selinuxns")
    held = take(locks)
    elsewhere = in_child(lambda: 0 if take(locks) is None else 1)
    r, w = os.pipe()

    def refused_start():
        """try to hold the lock with kmsg sent to the pipe"""
        launcher.kmsg = lambda m: os.write(w, (m + "\n").encode())
        hold(locks)
        return 0

    refused_code = in_child(refused_start)
    os.close(w)
    refused_log = os.read(r, 4096).decode()
    os.close(r)
    os.close(held)
    free = in_child(lambda: 0 if take(locks) is not None else 1)
    r, w = os.pipe()
    holder = os.fork()
    if holder == 0:
        take(locks)
        kid = os.fork()
        if kid == 0:
            time.sleep(30)
            os._exit(0)
        os.write(w, str(kid).encode())
        os._exit(0)
    os.close(w)
    kid = int(os.read(r, 32) or b"0")
    os.close(r)
    os.waitpid(holder, 0)
    after_holder = in_child(lambda: 0 if take(locks) is not None else 1)
    if kid:
        os.kill(kid, signal.SIGKILL)
    if elsewhere or free or after_holder:
        bad.append(("start lock", "held elsewhere refuses, free after a close, free once its holder exits",
                    elsewhere, free, after_holder))
    if refused_code != 1 or "RHIZO_MARKER selinuxns=refused reason=instance-already-starting" not in refused_log:
        bad.append(("a second start", "exit 1 with instance-already-starting", refused_code, refused_log))
    blocked = os.path.join(tmp.name, "a-lock-file", "rhizo-selinuxns")
    write_file(os.path.dirname(blocked))
    r, w = os.pipe()

    def failed_lock():
        """try to hold a lock under a regular file with kmsg sent to the pipe"""
        launcher.kmsg = lambda m: os.write(w, (m + "\n").encode())
        hold(blocked)
        return 0

    failed_code = in_child(failed_lock)
    os.close(w)
    failed_log = os.read(r, 4096).decode()
    os.close(r)
    if failed_code != 1 or "RHIZO_MARKER selinuxns=refused reason=start-lock-failed errno=20" not in failed_log:
        bad.append(("an unlockable records dir", "exit 1 with start-lock-failed errno=20", failed_code, failed_log))

tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "arm_host_lock_releaser")
rel = [n for n in ast.walk(fn) if isinstance(n, ast.Call) and ast.unparse(n.func) == "hostlock.release_when_ready"]
if len(rel) != 1 or rel[0].keywords or "ENFORCE_NODE" in ast.unparse(rel[0]):
    bad.append(("release_when_ready call passes no enforce node", "3 positional args", [ast.unparse(r) for r in rel]))

tmp.cleanup()
if bad:
    for b in bad:
        print("FAIL:", b)
    sys.exit(1)
print("ok")
