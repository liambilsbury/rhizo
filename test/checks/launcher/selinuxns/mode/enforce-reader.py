#!/usr/bin/env python3
import ast, contextlib, inspect, io, os, shutil, subprocess, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-enforce-reader")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
    from sandbox import hostlock as hl

bad = []
tmp = tempfile.TemporaryDirectory()


def path(name, text=None):
    """return a path in the scratch directory, writing text there when given"""
    p = os.path.join(tmp.name, name)
    if text is not None:
        with open(p, "w") as f:
            f.write(text)
    elif os.path.exists(p):
        os.unlink(p)
    return p


def state(mode, android, node):
    """return android_enforce_state over fixture files"""
    return hl.android_enforce_state(mode_file=path("mode", mode), state_file=path("android-enforce", android),
                                    host_node=path("enforce", node))


def verdict(mode, value):
    """return selinuxns_verdict over a mode file and a verdict file"""
    return hl.selinuxns_verdict(mode_file=path("mode", mode), verdict_file=path("verdict", value))


for args, want in (
        (("namespace\n", "1\n", "0\n"), "1"),
        (("namespace\n", "0\n", "1\n"), "0"),
        (("namespace\n", None, "1\n"), ""),
        (("host\n", "1\n", "0\n"), "0"),
        (("host\n", "0\n", "1\n"), "1"),
        ((None, "1\n", "0\n"), ""),
        (("permissive\n", "1\n", "0\n"), ""),
        ((None, "0\n", None), "")):
    got = state(*args)
    if got != want:
        bad.append(("android_enforce_state", args, want, got))

for args, want in (
        (("namespace\n", "enforced\n"), "enforced"),
        (("namespace\n", "refused:relabeller-eof\n"), "refused:relabeller-eof"),
        (("namespace\n", None), ""),
        (("host\n", "refused:relabeller-eof\n"), ""),
        ((None, "enforced\n"), "refused:selinux-mode-unreadable"),
        (("permissive\n", "enforced\n"), "refused:selinux-mode-unreadable")):
    got = verdict(*args)
    if got != want:
        bad.append(("selinuxns_verdict", args, want, got))

PROBE = ("import inspect\nfrom sandbox import core, selinux_ns as ns, hostlock as hl\n"
         "default = lambda fn, name: inspect.signature(fn).parameters[name].default\n"
         "print(core.RUN_ROOT, core.SELINUXNS_RECORDS_DIR, ns.ANDROID_ENFORCE_FILE, ns.VERDICT_FILE,\n"
         "      default(hl.android_enforce_state, 'state_file'), default(hl.selinuxns_verdict, 'verdict_file'))")
for sid, want_dir in ((0, "/run/rhizo-selinuxns"), (3, "/run/rhizo-selinuxns-3")):
    got_dir = getattr(launcher.core.paths_for(sid), "records_dir", None)
    if got_dir != want_dir:
        bad.append(("paths_for records_dir", sid, want_dir, got_dir))
    r = subprocess.run([sys.executable, "-c", PROBE], capture_output=True, text=True,
                       env=dict(os.environ, RHIZO_SANDBOX_ID=str(sid), PYTHONPATH=LAUNCHER))
    if r.returncode != 0:
        bad.append(("records paths for instance", sid, "importable", r.stderr.strip().splitlines()[-1:]))
        continue
    run_root, records, enforce_file, verdict_file, hl_state, hl_verdict = r.stdout.strip().splitlines()[-1].split()
    want = (want_dir, f"{want_dir}/android-enforce", f"{want_dir}/selinuxns-verdict",
            f"{want_dir}/android-enforce", f"{want_dir}/selinuxns-verdict")
    got = (records, enforce_file, verdict_file, hl_state, hl_verdict)
    if got != want or any(p.startswith(run_root + "/") for p in got):
        bad.append(("records paths for instance", sid, want, got, "run root " + run_root))


def release_run_root(host, run_root):
    """release run_root through a stub mount table"""
    table = os.path.join(host, "mountinfo")
    sysblock = os.path.join(host, "sys-block")
    os.makedirs(sysblock, exist_ok=True)
    with open(table, "w") as f:
        f.write(f"900 1 0:90 / {run_root} rw - tmpfs tmpfs rw\n")

    def umount2(mount_point, flags):
        """empty mount_point and the mount table"""
        shutil.rmtree(mount_point)
        os.mkdir(mount_point)
        open(table, "w").close()
        return 0
    return launcher.release_host_staging(run_root=run_root, data_img=os.path.join(host, "no-data.img"),
                                         log=lambda m: None, table=table, umount2=umount2,
                                         losetup=lambda a: (0, "", ""), wait_s=0, who="check", sysblock=sysblock,
                                         reach=(), domain="u:r:unconfined:s0", vbmeta_record=None)


host = tempfile.mkdtemp(dir=tmp.name)
ns = launcher.selinux_ns
run_root = host + launcher.RUN_ROOT
records = host + os.path.dirname(ns.VERDICT_FILE)
os.makedirs(f"{run_root}/data")
saved = (launcher.kmsg, ns.kmsg)
launcher.kmsg = ns.kmsg = lambda m: None
try:
    launcher.reset_namespace_start_records(records_dir=records)
    fd = ns.open_records_dir(records)
    try:
        ns.record_verdict("refused:relabeller-timeout", fd)
        ns.record_android_enforce("1", fd)
    finally:
        os.close(fd)
    released = release_run_root(host, run_root)
except Exception as e:
    released = repr(e)
finally:
    launcher.kmsg, ns.kmsg = saved
mode_file = path("mode", "namespace\n")
got = (released, os.listdir(run_root) if os.path.isdir(run_root) else None,
       hl.android_enforce_state(mode_file=mode_file,
                                state_file=os.path.join(records, os.path.basename(ns.ANDROID_ENFORCE_FILE))),
       hl.selinuxns_verdict(mode_file=mode_file,
                            verdict_file=os.path.join(records, os.path.basename(ns.VERDICT_FILE))))
if got != (True, [], "1", "refused:relabeller-timeout"):
    bad.append(("records after the run root's release", (True, [], "1", "refused:relabeller-timeout"), got))

missing = os.path.join(host, "run", "rhizo-selinuxns-7")
old_umask = os.umask(0o022)
try:
    fd = ns.open_records_dir(missing)
    os.close(fd)
    mode = oct(os.stat(missing).st_mode & 0o777)
except Exception as e:
    mode = repr(e)
finally:
    os.umask(old_umask)
if mode != "0o755":
    bad.append(("a missing records dir is created", "0o755", mode))

for fn in (hl.wait_for_enforce, hl.release_when_ready):
    params = list(inspect.signature(fn).parameters)
    if "enforce_node" in params:
        bad.append((fn.__name__ + " parameters", "no enforce_node", params))


@contextlib.contextmanager
def answers(android, verdict_value):
    """make the enforce and verdict readers answer fixed values"""
    calls = {"state": 0, "verdict": 0}
    saved = hl.android_enforce_state, hl.selinuxns_verdict

    def fake_state():
        """return the fixed enforce state"""
        calls["state"] += 1
        return android

    def fake_verdict():
        """return the fixed verdict"""
        calls["verdict"] += 1
        return verdict_value
    hl.android_enforce_state, hl.selinuxns_verdict = fake_state, fake_verdict
    try:
        yield calls
    finally:
        hl.android_enforce_state, hl.selinuxns_verdict = saved


with answers("1", "") as calls:
    got = hl.wait_for_enforce(deadline_s=5)
    if got != "enforced" or calls["state"] != 1:
        bad.append(("wait_for_enforce on a state of 1", "enforced at the first poll", (got, calls)))
with answers("", "refused:relabeller-eof") as calls:
    got = hl.wait_for_enforce(deadline_s=5)
    if got != "refused:relabeller-eof" or calls["state"] != 1:
        bad.append(("wait_for_enforce on a refused verdict", "the verdict at the first poll", (got, calls)))
with answers("0", "pending") as calls:
    got = hl.wait_for_enforce(deadline_s=0.3)
    if got != "":
        bad.append(("wait_for_enforce past its deadline", "", got))


def release(android, verdict_value, supervisor, deadline_s=5):
    """run release_when_ready on a scratch fd"""
    fd = os.open(path("lock", ""), os.O_RDWR)
    logged = []
    with answers(android, verdict_value):
        hl.release_when_ready(fd, supervisor, logged.append, deadline_s=deadline_s)
    try:
        os.fstat(fd)
        os.close(fd)
        closed = False
    except OSError:
        closed = True
    return logged, closed


logged, closed = release("1", "", lambda: True)
if not closed or logged != ["host lock released (enforce_seen=True supervisor_seen=True)"]:
    bad.append(("release_when_ready once enforce reads 1 and the supervisor is seen", "one released line",
                (logged, closed)))
seen = []
logged, closed = release("", "refused:relabeller-eof", lambda: seen.append(1) or False)
if not closed or seen or any("releasing anyway" in m for m in logged) or \
        not any("refused:relabeller-eof" in m and "host lock released" in m for m in logged):
    bad.append(("release_when_ready on a refused verdict", "released at once, no supervisor wait",
                (logged, closed, len(seen))))
for final in ("stopped", "permissive"):
    seen = []
    logged, closed = release("0", final, lambda: seen.append(1) or False)
    if not closed or seen or logged != [f"host lock released (Android's start {final}, no supervisor wait)"]:
        bad.append((f"release_when_ready on a {final} verdict", "released at once, no supervisor wait",
                    (logged, closed, len(seen))))
for waiting in ("pending", "handed-off", ""):
    logged, closed = release("0", waiting, lambda: True, deadline_s=0.3)
    if not closed or "host lock releaser: enforce=1 not observed within 0.3s -- releasing anyway" not in logged:
        bad.append((f"release_when_ready on a verdict of {waiting!r}", "released at the deadline with the loud line",
                    (logged, closed)))
logged, closed = release("0", "", lambda: True, deadline_s=0.3)
if not closed or "host lock releaser: enforce=1 not observed within 0.3s -- releasing anyway" not in logged:
    bad.append(("release_when_ready past its deadline", "released with the loud line", (logged, closed)))


def permissive(mode, loaded, verdict_value, supervisor):
    """run release_host_lock_permissive under mode with stubbed readers"""
    out = []
    saved = (launcher.policy_is_loaded, launcher.recorded_g_alive, launcher.kmsg, hl.release_host_lock,
             hl.selinuxns_verdict, os.environ.get("RHIZO_SELINUX_MODE"))
    os.environ["RHIZO_SELINUX_MODE"] = mode
    launcher.policy_is_loaded = lambda: loaded
    launcher.recorded_g_alive = lambda: supervisor
    launcher.kmsg = lambda m: out.append("kmsg:" + m)
    hl.release_host_lock = lambda fd: out.append("released")
    hl.selinuxns_verdict = lambda: (out.append("verdict-read"), verdict_value)[1]
    try:
        launcher.release_host_lock_permissive(-1, deadline_s=0.3, poll_s=0.01)
    finally:
        (launcher.policy_is_loaded, launcher.recorded_g_alive, launcher.kmsg, hl.release_host_lock,
         hl.selinuxns_verdict) = saved[:5]
        if saved[5] is None:
            os.environ.pop("RHIZO_SELINUX_MODE", None)
        else:
            os.environ["RHIZO_SELINUX_MODE"] = saved[5]
    return out


out = permissive("namespace", False, "permissive", True)
if "released" not in out or any("releasing anyway" in m for m in out):
    bad.append(("namespace permissive release on a permissive verdict", "released, no loud line", out))
out = permissive("namespace", False, "refused:relabeller-timeout", False)
if "released" not in out or any("releasing anyway" in m for m in out) or \
        not any("refused:relabeller-timeout" in m for m in out):
    bad.append(("namespace permissive release on a refused verdict", "released naming the refusal", out))
for final in ("stopped", "enforced"):
    out = permissive("namespace", False, final, False)
    if "released" not in out or any("releasing anyway" in m for m in out) or \
            f"kmsg:host lock released (permissive, Android's start {final}, no supervisor wait)" not in out:
        bad.append((f"namespace permissive release on a {final} verdict", "released naming the verdict", out))
out = permissive("namespace", True, "pending", True)
if not any("releasing anyway" in m for m in out):
    bad.append(("namespace permissive release ignores the host's own context", "loud line at the deadline", out))
out = permissive("host", True, "permissive", True)
if "released" not in out or "verdict-read" in out or \
        "kmsg:host lock released (permissive, policy_loaded=True supervisor_seen=True)" not in out:
    bad.append(("host permissive release reads policy_is_loaded and no verdict", "as before", out))

tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
fns = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}

src = ast.unparse(fns["stage_vendor_tree"])
fb = [n for n in ast.walk(fns["stage_vendor_tree"])
      if isinstance(n, ast.If) and ".write('ro.vendor.rhizo.first_boot=1" in ast.unparse(n.body[0])]
if len(fb) != 1 or ast.unparse(fb[0].test) != "not host_selinux_mode() or not policy_is_loaded()":
    bad.append(("stage_vendor_tree's first_boot gate", "not host_selinux_mode() or not policy_is_loaded()",
                [ast.unparse(n.test) for n in fb]))
for needle in ("RHIZO_MARKER selinuxns=first-boot-restorecon", "first boot: ro.vendor.rhizo.first_boot=1"):
    if needle not in src:
        bad.append(("stage_vendor_tree logs", needle, "absent"))

ns = launcher.selinux_ns
marks = []
saved_marks = ns.kmsg
ns.kmsg = marks.append
try:
    with tempfile.TemporaryDirectory() as rec:
        os.chmod(rec, 0o500)
        fd = os.open(rec, os.O_RDONLY | os.O_DIRECTORY)
        try:
            ns.record_verdict("pending", fd)
            ns.record_start_id("abc", fd)
            ns.record_android_enforce("1", fd)
        finally:
            os.close(fd)
            os.chmod(rec, 0o700)
finally:
    ns.kmsg = saved_marks
for name, value in (("selinuxns-verdict", "pending"), ("start-id", "abc"), ("android-enforce", "1")):
    if not any(m.startswith(f"RHIZO_MARKER selinuxns=record-write-failed file={name} value={value} err=")
               for m in marks):
        bad.append(("a failed record write", f"record-write-failed file={name}", marks))
for module in ("sandbox/selinux_ns.py", "boot.py"):
    text = open(os.path.join(LAUNCHER, module)).read()
    for old_form in ("verdict-write-failed", "start-id-failed", "state-file-failed"):
        if old_form in text:
            bad.append((module, "logs a failed record write as", old_form))

tmp.cleanup()
if bad:
    for b in bad:
        print("FAIL:", b)
    sys.exit(1)
print("ok")
