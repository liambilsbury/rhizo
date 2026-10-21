#!/usr/bin/env python3
import ast, contextlib, io, json, os, shutil, signal, subprocess, sys, tempfile, threading
NAME = "relabeller-ready"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..")
if "--root" in sys.argv[1:]:
    ROOT = sys.argv[sys.argv.index("--root") + 1]
LAUNCHER = os.path.join(ROOT, "src", "androidd")
WAIT_CALL = "    if wait_relabeller_ready(relabeller) == RELABELLER_TIMEOUT:\n"
MUTANTS = (
    ("the wait skipped", "src/androidd/sandbox/selinux_ns.py",
     WAIT_CALL + '        kmsg("RHIZO_MARKER selinuxns=refused reason=relabeller-ready-timeout")\n        os._exit(1)\n',
     "", "begin_handoff_namespace order"),
    ("the wait before the relabeller starts", "src/androidd/sandbox/selinux_ns.py",
     "    relabeller = start_handoff_relabeller(view_fd, done_w, env, launcher_path, python, host_selinuxfs_dev)\n",
     "    wait_relabeller_ready(os.getpid())\n"
     "    relabeller = start_handoff_relabeller(view_fd, done_w, env, launcher_path, python, host_selinuxfs_dev)\n",
     "begin_handoff_namespace order"),
    ("a timeout that goes on", "src/androidd/sandbox/selinux_ns.py",
     '        kmsg("RHIZO_MARKER selinuxns=refused reason=relabeller-ready-timeout")\n        os._exit(1)\n',
     "        pass\n", "begin_handoff_namespace timeout"),
    ("a refusal without its marker", "src/androidd/sandbox/selinux_ns.py",
     '        kmsg("RHIZO_MARKER selinuxns=refused reason=relabeller-ready-timeout")\n        os._exit(1)\n',
     "        os._exit(1)\n", "begin_handoff_namespace timeout"),
    ("a wait without waitpid", "src/androidd/sandbox/selinux_ns.py",
     "reaped, status = os.waitpid(pid, os.WNOHANG)", "reaped, status = 0, 0", "wait_relabeller_ready reaped child"),
    ("a wait that treats a foreign pid as alive", "src/androidd/sandbox/selinux_ns.py",
     "        except ChildProcessError as e:\n"
     "            kmsg(f\"RHIZO_MARKER selinuxns=relabeller-gone-before-ready pid={pid} err={e!r}\")\n"
     "            return RELABELLER_GONE\n",
     "        except ChildProcessError:\n            reaped, status = 0, 0\n", "wait_relabeller_ready foreign pid"),
    ("a wait that ignores the name", "src/androidd/sandbox/selinux_ns.py",
     "if f.read().strip() == want:", "if f.read():", "wait_relabeller_ready timeout"),
    ("a wait that never times out as a timeout", "src/androidd/sandbox/selinux_ns.py",
     "    return RELABELLER_TIMEOUT\n", "    return RELABELLER_GONE\n", "wait_relabeller_ready timeout"),
    ("a wait on the wall clock", "src/androidd/sandbox/selinux_ns.py",
     "deadline = time.monotonic() + timeout\n    while time.monotonic() < deadline:",
     "deadline = time.time() + timeout\n    while time.time() < deadline:", "wait_relabeller_ready clock"),
    ("an announce that does not set the name", "src/androidd/sandbox/selinux_ns.py",
     "    if libc.prctl(PR_SET_NAME, RELABELLER_READY_COMM, 0, 0, 0) != 0:",
     "    if libc.prctl(PR_SET_NAME, b\"python3\", 0, 0, 0) != 0:", "announce_relabeller_ready prctl"),
    ("an announce that does not log", "src/androidd/sandbox/selinux_ns.py",
     '        kmsg(f"RHIZO_MARKER selinuxns=relabeller-announce-failed errno={ctypes.get_errno()}")\n',
     "        pass\n", "announce_relabeller_ready failure"),
    ("an announce that is not called", "src/androidd/sandbox/selinux_ns.py",
     "    announce_relabeller_ready()\n", "", "run_relabeller announce"),
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
            shutil.copytree(os.path.join(ROOT, "src", "androidd"), os.path.join(tmp, "src", "androidd"), symlinks=True,
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
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-relabeller-ready")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_ns as ns

bad = []
marks = []
ns.kmsg = lambda m: marks.append(m)


def child_that(action):
    """fork a child that sleeps or exits at once"""
    pid = os.fork()
    if pid == 0:
        try:
            if action == "sleep":
                signal.pause()
        finally:
            os._exit(0)
    return pid


def stop(pid):
    """kill and reap a child"""
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def wait_on(pid, comm, timeout, flip_to=None):
    """call wait_relabeller_ready over a fake proc directory"""
    with tempfile.TemporaryDirectory() as proc:
        if comm is not None:
            os.makedirs(f"{proc}/{pid}")
            open(f"{proc}/{pid}/comm", "w").write(comm + "\n")
        timer = None
        if flip_to is not None:
            timer = threading.Timer(0.05, lambda: open(f"{proc}/{pid}/comm", "w").write(flip_to + "\n"))
            timer.start()
        del marks[:]
        try:
            got = ns.wait_relabeller_ready(pid, proc, timeout)
        finally:
            if timer is not None:
                timer.join()
        return got, list(marks)


pid = child_that("sleep")
try:
    got, _ = wait_on(pid, "python3", 10, flip_to="rhizo-relabel")
    if got != ns.RELABELLER_READY:
        bad.append(("wait_relabeller_ready poll", ns.RELABELLER_READY, got))
    got, seen = wait_on(pid, "python3", 0.3)
    if got != ns.RELABELLER_TIMEOUT or not any("relabeller-ready-timeout" in m for m in seen):
        bad.append(("wait_relabeller_ready timeout", ns.RELABELLER_TIMEOUT, got, seen))
    got, seen = wait_on(pid, None, 10)
    if got != ns.RELABELLER_GONE or not any("relabeller-gone-before-ready" in m for m in seen):
        bad.append(("wait_relabeller_ready no proc entry", ns.RELABELLER_GONE, got, seen))
finally:
    stop(pid)

pid = child_that("exit")
got, seen = wait_on(pid, "python3", 1)
if got != ns.RELABELLER_GONE or not any("relabeller-gone-before-ready" in m for m in seen):
    bad.append(("wait_relabeller_ready reaped child", ns.RELABELLER_GONE, got, seen))
try:
    os.waitpid(pid, os.WNOHANG)
except ChildProcessError:
    pass
else:
    bad.append(("wait_relabeller_ready reaped child", "the wait reaps the child", pid))
    stop(pid)

got, seen = wait_on(os.getppid(), "python3", 1)
if got != ns.RELABELLER_GONE:
    bad.append(("wait_relabeller_ready foreign pid", ns.RELABELLER_GONE, got, seen))

wait_source = ast.unparse(next(n for n in ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read()).body
                               if isinstance(n, ast.FunctionDef) and n.name == "wait_relabeller_ready"))
if "time.time()" in wait_source or "time.monotonic()" not in wait_source:
    bad.append(("wait_relabeller_ready clock", "time.monotonic and no time.time"))


def begin(wait_answer):
    """call begin_handoff_namespace in a fork with stubbed steps"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)

        def note(*ev):
            """send an event to the parent"""
            os.write(w, (json.dumps(ev) + "\n").encode())

        ns.kmsg = lambda m: note("kmsg", m)
        ns.unshare_namespace = lambda state_file=None: note("unshare")
        ns.mount_own_selinuxfs = lambda t: note("selinuxfs")
        ns.bind_decoy_enforce = lambda node, scratch: note("decoy") or True
        ns.start_handoff_relabeller = lambda *a: note("relabeller") or 4242
        ns.wait_relabeller_ready = lambda pid: note("ready", pid) or wait_answer
        try:
            ns.begin_handoff_namespace(7, 8, {}, "/l.py", "/py", 9)
            note("returned")
        except BaseException as e:
            note("raised", repr(e))
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
    return os.waitstatus_to_exitcode(status), [json.loads(l) for l in data.decode().splitlines()]


steps = [["unshare"], ["kmsg", "RHIZO_MARKER selinuxns=unshared path=handoff"], ["selinuxfs"], ["decoy"],
         ["relabeller"], ["ready", 4242]]
refusal = ["kmsg", "RHIZO_MARKER selinuxns=refused reason=relabeller-ready-timeout"]
for answer, want in ((ns.RELABELLER_READY, (0, steps + [["returned"]])),
                     (ns.RELABELLER_GONE, (0, steps + [["returned"]])),
                     (ns.RELABELLER_TIMEOUT, (1, steps + [refusal]))):
    got = begin(answer)
    if got != want:
        bad.append(("begin_handoff_namespace order" if answer == ns.RELABELLER_READY else
                    "begin_handoff_namespace timeout" if answer == ns.RELABELLER_TIMEOUT else
                    "begin_handoff_namespace order", answer, want, got))


class PrctlLibc:
    """libc whose prctl records its arguments and answers a set code"""
    calls = []
    rc = 0
    prctl = staticmethod(lambda *a: PrctlLibc.calls.append(a) or PrctlLibc.rc)


saved = ns.libc
ns.libc = PrctlLibc
try:
    for rc, want_marks in ((0, False), (-1, True)):
        PrctlLibc.calls, PrctlLibc.rc = [], rc
        del marks[:]
        ns.announce_relabeller_ready()
        if PrctlLibc.calls != [(ns.PR_SET_NAME, b"rhizo-relabel", 0, 0, 0)]:
            bad.append(("announce_relabeller_ready prctl", PrctlLibc.calls))
        logged = [m for m in marks if m.startswith("RHIZO_MARKER selinuxns=relabeller-announce-failed errno=")]
        if bool(logged) != want_marks or len(marks) != len(logged):
            bad.append(("announce_relabeller_ready failure", rc, marks))
finally:
    ns.libc = saved

run_source = ast.unparse(next(n for n in ast.parse(open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read()).body
                              if isinstance(n, ast.FunctionDef) and n.name == "run_relabeller"))
if not 0 <= run_source.find("announce_relabeller_ready()") < run_source.find("_relabel_after_load("):
    bad.append(("run_relabeller announce", "announce_relabeller_ready() before _relabel_after_load("))

if bad:
    for item in bad:
        print("FAIL", item)
    print("FAIL")
    sys.exit(1)
print("ok")
