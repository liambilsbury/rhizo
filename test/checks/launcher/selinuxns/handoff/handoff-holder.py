#!/usr/bin/env python3
import ast, contextlib, errno, io, os, re, shutil, signal, subprocess, sys, tempfile
NAME = "handoff-holder"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..")
if "--root" in sys.argv[1:]:
    ROOT = sys.argv[sys.argv.index("--root") + 1]
LAUNCHER = os.path.join(ROOT, "src", "androidd")
MUTANTS = (
    ("gg's call dropping the handoff", "src/androidd/boot.py",
     "build_root_and_pivot(mount_proc=not _handoff_to, handoff=bool(_handoff_to))",
     "build_root_and_pivot(mount_proc=not _handoff_to, handoff=False)", "gg's build_root_and_pivot call"),
    ("a done pipe made on a handoff", "src/androidd/boot.py",
     "if not host_selinux_mode() and not _handoff_to else (-1, -1)", "if not host_selinux_mode() else (-1, -1)",
     "g's done pipe"),
)

def run_check(root):
    """run this check over a source tree"""
    r = subprocess.run([sys.executable, os.path.abspath(__file__), "--root", root], capture_output=True, text=True,
                       timeout=600)
    return r.returncode, r.stdout + r.stderr


def selftest():
    """flag each mutant and pass the real tree"""
    failed = []
    for label, rel, old, new, needle in MUTANTS:
        with tempfile.TemporaryDirectory() as tmp:
            shutil.copytree(os.path.join(ROOT, "src"), os.path.join(tmp, "src"), symlinks=True,
                            ignore=shutil.ignore_patterns("__pycache__"))
            path = os.path.join(tmp, rel)
            text = open(path).read()
            if text.count(old) != 1:
                failed.append(f"the {label} mutant found {text.count(old)} anchors")
                continue
            with open(path, "w") as f:
                f.write(text.replace(old, new))
            rc, out = run_check(tmp)
        if rc == 0 or needle not in out:
            failed.append(f"the {label} mutant was not flagged: rc={rc} {out[-300:]!r}")
    rc, out = run_check(ROOT)
    if rc != 0:
        failed.append(f"the real tree has findings: {out[-500:]!r}")
    for f in failed:
        print("FAIL", f)
    print("%s: selftest ok" % NAME if not failed else "%s: selftest FAIL" % NAME)
    return 1 if failed else 0


if __name__ == "__main__" and "--selftest" in sys.argv[1:]:
    sys.exit(selftest())

sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-handoff-holder")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs as m
    from sandbox import selinux_ns as ns

bad = []
NR = "/check-newroot"

mtree = ast.parse(open(os.path.join(LAUNCHER, "sandbox/rootfs.py")).read())
setup = next(n for n in mtree.body if isinstance(n, ast.FunctionDef) and n.name == "_setup_cgroups_and_selinuxfs")
params = [a.arg for a in setup.args.args]
defaults = [ast.unparse(d) for d in setup.args.defaults]
if params != ["handoff"] or defaults != ["False"]:
    bad.append(("_setup_cgroups_and_selinuxfs parameters", "handoff=False", params, defaults))

starts = [i for i, n in enumerate(setup.body)
          if (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "holder" for t in n.targets))
          or "mount_sandbox_selinuxfs" in ast.unparse(n)]
piv = [i for i, n in enumerate(setup.body) if isinstance(n, ast.If) and "pivot_root(" in ast.unparse(n.test)]
if not starts or len(piv) != 1:
    bad.append(("selinuxfs tail", "a selinuxfs step and one pivot_root", starts, piv))
    tail = None
else:
    tail = compile(ast.Module(body=setup.body[min(starts):piv[0] + 1], type_ignores=[]), "sandbox/rootfs.py", "exec")


def run_tail(mode, handoff):
    """exec the selinuxfs tail under stand-ins"""
    events = []

    class FakeNs:
        """stand-in for selinux_ns"""
        unshared = False

        @staticmethod
        def selinux_mode():
            """answer the case's mode"""
            return mode

        @staticmethod
        def state():
            """answer whether the stand-in selinuxfs mount unshared"""
            return {"unshared": FakeNs.unshared}

        @staticmethod
        def clear_selinuxfs_mounts(target):
            """record the clear"""
            events.append(("clear_selinuxfs_mounts", target))

        @staticmethod
        def start_view_keeper():
            """record the view keeper start"""
            events.append(("start_view_keeper",))
            return 4242

        @staticmethod
        def start_relabeller(*a):
            """record the relabeller start"""
            events.append(("start_relabeller",) + a)
            return 4243

    FakeNs.unshared = mode == "namespace"

    def mount_selinuxfs(got_mode):
        """record the selinuxfs mount"""
        events.append(("mount_sandbox_selinuxfs", got_mode))
        if got_mode == "namespace":
            FakeNs.unshared = True

    class FakePath:
        """os.path stand-in finding nothing"""
        exists = staticmethod(lambda p: False)

    class FakeOs:
        """os stand-in touching nothing"""
        path = FakePath
        makedirs = staticmethod(lambda p, exist_ok=False: None)
        chmod = staticmethod(lambda p, mode: None)
        setxattr = staticmethod(lambda *a: None)

    class FakeEnv:
        """stand-in for core"""
        WRITE_PRIMER_SCRIPT = "writer"
        RELABELLER_DONE_FD = 42
        is_mount_point = staticmethod(lambda path: False)

    scope = {"selinux_ns": FakeNs, "core": FakeEnv, "NEWROOT": NR, "handoff": handoff,
             "host_selinux_mode": lambda: mode == "host", "mount_sandbox_selinuxfs": mount_selinuxfs,
             "mount": lambda s, t, fs, fl, d=None: (events.append(("mount", s, t, fs, fl)), True)[1],
             "open": lambda *a, **k: io.StringIO(), "os": FakeOs, "kmsg": lambda msg: None,
             "label_before_policy": lambda *a, **k: None,
             "RHIZO_ENFORCING": True, "MS_BIND": m.MS_BIND, "MS_REMOUNT": m.MS_REMOUNT, "MS_RDONLY": m.MS_RDONLY,
             "shadow_host_seat_uevents": lambda r: None, "relabel_root_objects_now": lambda r, staged=None: None,
             "coldboot_primer_spec": lambda: ["spec"], "DEVICE_STATE_MOUNT": m.DEVICE_STATE_MOUNT,
             "pivot_root": lambda new, old: (events.append(("pivot_root", new, old)), True)[1]}
    try:
        exec(tail, scope)
    except BaseException as e:
        events.append(("raised", repr(e)))
    return [e for e in events if e[0] != "mount" or "/sys/fs/selinux" in e[2]]


DECOY = ("mount", "/rhizoroot/tmp_enforce", f"{NR}/sys/fs/selinux/enforce", None, m.MS_BIND)
PIVOT = ("pivot_root", NR, f"{NR}/oldroot")
TODAY = {"namespace": [("mount_sandbox_selinuxfs", "namespace"), DECOY,
                       ("start_relabeller", NR, ["spec"], "writer", 42), PIVOT],
         "host": [("mount_sandbox_selinuxfs", "host"), DECOY, PIVOT]}
if tail is not None:
    want = [("clear_selinuxfs_mounts", f"{NR}/sys/fs/selinux"), ("start_view_keeper",), PIVOT]
    got = run_tail("namespace", True)
    if got != want:
        bad.append(("namespace handoff holder", want, got))
    for mode, handoff in (("host", True), ("host", False), ("namespace", False)):
        got = run_tail(mode, handoff)
        if got != TODAY[mode]:
            bad.append((f"{mode} mode, handoff={handoff}", TODAY[mode], got))

phases = ("phase", "_build_flat_trees", "_mount_extra_partitions", "_make_dev_nodes", "_bind_sockets_and_shadows",
          "mount_marker", "_setup_cgroups_and_selinuxfs", "_pivot_and_harden")
saved = {n: getattr(m, n) for n in phases}
seen = []
m.phase = lambda *a: None
m._build_flat_trees = lambda: "snapshot"
m._mount_extra_partitions = lambda snap: None
m._make_dev_nodes = lambda: None
m._bind_sockets_and_shadows = lambda mount_proc: None
m.mount_marker = lambda: None
m._setup_cgroups_and_selinuxfs = lambda handoff=False: seen.append(("setup", handoff))
m._pivot_and_harden = lambda mount_proc=True: seen.append(("pivot", mount_proc))
try:
    for kwargs, want in (({}, [("setup", False), ("pivot", True)]),
                         ({"mount_proc": False, "handoff": True}, [("setup", True), ("pivot", False)])):
        seen.clear()
        try:
            m.build_root_and_pivot(**kwargs)
        except TypeError as e:
            seen.append(("raised", str(e)))
        if seen != want:
            bad.append(("build_root_and_pivot", kwargs, want, list(seen)))
finally:
    for n, v in saved.items():
        setattr(m, n, v)

logs = []
saved_kmsg = ns.kmsg
ns.kmsg = logs.append
try:
    for verdict, want, reason in (("enforced", "enforced", None), ("permissive", "permissive", None),
                                  ("stopped", "none", None), ("refused:relabeller-timeout", "failed", "relabeller-timeout"),
                                  ("", "failed", "holder-ended"), ("pending", "failed", "holder-ended"),
                                  ("handed-off", "failed", "holder-ended")):
        logs.clear()
        try:
            got = ns.handoff_outcome(verdict)
        except AttributeError as e:
            got = repr(e)
        if got != want:
            bad.append(("handoff_outcome", verdict, want, got))
        marks = [l for l in logs if "selinuxns=refused" in l]
        if marks != ([f"RHIZO_MARKER selinuxns=refused reason={reason}"] if reason else []):
            bad.append(("handoff_outcome marker", verdict, reason, marks))
finally:
    ns.kmsg = saved_kmsg

for verdict, want in (("stopped", None), ("refused:join-setns-mnt", None), ("enforced", "holder-ended"),
                      ("permissive", "holder-ended"), ("", "holder-ended"), ("pending", "holder-ended"),
                      ("handed-off", "holder-ended"), ("half written\nrest", "holder-ended")):
    got = getattr(ns, "handoff_refusal", lambda v: "absent")(verdict)
    if got != want:
        bad.append(("handoff_refusal", verdict, want, got))


REAL_PRCTL = ns.libc.prctl


class ViewLibc:
    """libc stand-in with a set unshare code"""
    rc = 0
    prctl_fails = False
    unshare = staticmethod(lambda flags: ViewLibc.rc)
    prctl = staticmethod(lambda *a: -1 if ViewLibc.prctl_fails else REAL_PRCTL(*a))


def keeper(rc):
    """call start_view_keeper with unshare answering rc"""
    saved_libc, saved_kmsg = ns.libc, ns.kmsg
    logs, raised, pid, me = [], None, None, os.getpid()
    ViewLibc.rc = rc
    ns.libc, ns.kmsg = ViewLibc, logs.append
    try:
        pid = ns.start_view_keeper()
    except BaseException as e:
        raised = repr(e)
    finally:
        if os.getpid() != me:
            os._exit(99)
        ns.libc, ns.kmsg = saved_libc, saved_kmsg
    return pid, logs, raised


pid, logs, raised = keeper(0)
if raised or not pid:
    bad.append(("view keeper", "a pid", pid, raised))
else:
    alive = os.waitpid(pid, os.WNOHANG) == (0, 0)
    try:
        comm = open(f"/proc/{pid}/comm").read().strip()
    except OSError as e:
        comm = repr(e)
    os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    killed = os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL
    if not alive or not killed or comm != ns.VIEW_KEEPER_COMM.decode():
        bad.append(("view keeper lifetime", "alive, named, killed by SIGKILL", alive, comm, status))
    if logs != [f"RHIZO_MARKER selinuxns=view-keeper pid={pid} ready=True"]:
        bad.append(("view keeper marker", "ready=True", logs))


def keeper_refusal(unshare_rc, prctl_fails):
    """call start_view_keeper in a fork with a failing unshare or rename"""
    r, w = os.pipe()
    tester = os.fork()
    if tester == 0:
        os.close(r)
        ViewLibc.rc, ViewLibc.prctl_fails = unshare_rc, prctl_fails
        ns.libc, ns.kmsg = ViewLibc, lambda msg: os.write(w, (msg + "\n").encode())
        try:
            os.kill(ns.start_view_keeper(), signal.SIGKILL)
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
    _, status = os.waitpid(tester, 0)
    return os.waitstatus_to_exitcode(status), [re.sub(r" pid=\d+", "", l) for l in data.decode().splitlines()]


want = (1, ["RHIZO_MARKER selinuxns=view-keeper ready=False", "RHIZO_MARKER selinuxns=refused reason=view-keeper"])
for label, unshare_rc, prctl_fails in (("unshare fails", -1, False), ("rename fails", 0, True)):
    got = keeper_refusal(unshare_rc, prctl_fails)
    if got != want:
        bad.append(("view keeper refusal", label, want, got))

ltree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
run_sandbox = next(n for n in ltree.body if isinstance(n, ast.FunctionDef) and n.name == "run_sandbox")
brp = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.Call) and ast.unparse(n.func) == "build_root_and_pivot"]
kw = {k.arg: k.value for k in brp[0].keywords} if len(brp) == 1 else {}
if sorted(kw) != ["handoff", "mount_proc"]:
    bad.append(("gg's build_root_and_pivot call", "mount_proc and handoff", [ast.unparse(c) for c in brp]))
else:
    for to, want in ((None, (True, False)), (4242, (False, True))):
        got = tuple(eval(compile(ast.Expression(body=kw[k]), "boot.py", "eval"), {"_handoff_to": to})
                    for k in ("mount_proc", "handoff"))
        if got != want:
            bad.append(("gg's build_root_and_pivot call", f"_handoff_to={to}", want, got))
pipes = [n for n in ast.walk(run_sandbox) if isinstance(n, ast.Assign) and ast.unparse(n.targets[0]) == "(_done_r, _done_w)"]
if len(pipes) != 1:
    bad.append(("g's done pipe", "one assignment", len(pipes)))
else:
    expr = compile(ast.Expression(body=pipes[0].value), "boot.py", "eval")
    for mode, to, want in (("namespace", None, True), ("namespace", 4242, False), ("host", None, False),
                           ("host", 4242, False)):
        fds = eval(expr, {"os": os, "host_selinux_mode": lambda: mode == "host", "_handoff_to": to})
        made = fds[0] >= 0
        for fd in fds:
            if fd >= 0:
                os.close(fd)
        if made != want:
            bad.append(("g's done pipe", mode, f"_handoff_to={to}", want, fds))



def outcome(fn, *a):
    """return fn's result or the class of what it raised"""
    try:
        return fn(*a)
    except Exception as e:
        return e.__class__.__name__


with tempfile.TemporaryDirectory() as tmp:
    records, broken = os.path.join(tmp, "records"), os.path.join(tmp, "broken")
    os.makedirs(records)
    os.makedirs(broken)
    os.symlink(os.path.basename(ns.VERDICT_FILE), os.path.join(broken, os.path.basename(ns.VERDICT_FILE)))
    for label, d, want in (("no verdict yet", records, ""), ("a verdict path that cannot be opened", broken,
                                                             "OSError")):
        dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
        try:
            got = outcome(ns.read_verdict, dfd)
        finally:
            os.close(dfd)
        if got != want:
            bad.append(("read_verdict", label, want, got))
    proc = os.path.join(tmp, "proc")
    os.makedirs(os.path.join(proc, "4242"))
    with open(os.path.join(proc, "4242", "stat"), "w") as f:
        f.write("4242 (rhizo-mntview) S 77 1 1\n")
    os.makedirs(os.path.join(proc, "5000"))
    for label, extra, holder_pid, want in (("a process gone before its stat is read", None, 77, 4242),
                                           ("a stat that cannot be read", "stat", 88, "IsADirectoryError")):
        if extra:
            os.makedirs(os.path.join(proc, "5000", extra))
        got = outcome(ns.find_view_keeper, holder_pid, proc)
        if got != want:
            bad.append(("find_view_keeper", label, want, got))


def attr_open(err):
    """return an open stand-in failing the attr read with err"""
    def fake(path, *a, **k):
        """fail the read"""
        raise err
    return fake


for label, err, want in (("no attr file", FileNotFoundError(2, "No such file or directory"), "kernel"),
                         ("no LSM serves the attribute", OSError(errno.EINVAL, "Invalid argument"), "kernel"),
                         ("a denied read", PermissionError(13, "Permission denied"), "PermissionError")):
    ns.open = attr_open(err)
    try:
        got = outcome(ns.host_context)
    finally:
        del ns.open
    if got != want:
        bad.append(("host_context", label, want, got))

if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
