#!/usr/bin/env python3
import ast, contextlib, io, json, os, re, shutil, signal, subprocess, sys, tempfile, time
NAME = "handoff-joiner"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..")
if "--root" in sys.argv[1:]:
    ROOT = sys.argv[sys.argv.index("--root") + 1]
LAUNCHER = os.path.join(ROOT, "src", "androidd")
MUTANTS = (
    ("unshare moved before the fork", "src/androidd/boot.py",
     "        child = os.fork()\n        if child == 0:\n",
     "        if ns_mode:\n            selinux_ns.unshare_namespace(state_file=None)\n"
     "        child = os.fork()\n        if child == 0:\n", "pid 1 unshares in its own branch"),
    ("the decoy row naming begin_handoff_namespace's unshare", "test/checks/data/host-copy-ops-allow.tsv",
     "in Android's fresh SELinux namespace, unshared before it by gg's root build or the handoff joiner's pid 1,",
     "in the fresh SELinux namespace begin_handoff_namespace unshares before it,", "decoy row"),
    ("/proc mounted before the unshare", "src/androidd/boot.py",
     "            if ns_mode:\n                selinux_ns.unshare_namespace(state_file=None)\n"
     "            if not mount(\"proc\", \"/proc\", \"proc\", 0, f\"hidepid=2,gid={AID_READPROC}\"):\n"
     "                print(\"handoff: pid 1 could not mount its own /proc\", flush=True)\n",
     "            if not mount(\"proc\", \"/proc\", \"proc\", 0, f\"hidepid=2,gid={AID_READPROC}\"):\n"
     "                print(\"handoff: pid 1 could not mount its own /proc\", flush=True)\n"
     "            if ns_mode:\n                selinux_ns.unshare_namespace(state_file=None)\n",
     "the joiner unshares before it mounts /proc"),
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
            shutil.copytree(os.path.join(ROOT, "test", "checks", "data"), os.path.join(tmp, "test", "checks", "data"))
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
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-handoff-joiner")
with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
from sandbox import selinux_ns as ns

bad = []
ns.kmsg = lambda m: None
bind_decoy_enforce = ns.bind_decoy_enforce


def init_like(code=None, sig=None, after=0.2, done_w=-1, byte=None):
    """fork a stand-in init holding done_w"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(r)
            if byte:
                os.write(done_w, byte)
            time.sleep(after)
            os.write(w, repr(time.monotonic()).encode())
            if sig:
                os.kill(os.getpid(), sig)
        finally:
            os._exit(code or 0)
    os.close(w)
    return pid, r


def relabeller_like(done_w, after):
    """fork a stand-in relabeller holding done_w"""
    pid = os.fork()
    if pid == 0:
        try:
            time.sleep(after)
        finally:
            os._exit(1)
    return pid


KILLED = ("SIGKILL", lambda st: os.WIFSIGNALED(st) and os.WTERMSIG(st) == signal.SIGKILL)
for label, writer, byte, code, sig, life, deadline_s, want, status_ok in (
    ("flip then exit 0", "init", ns.DONE_ENFORCED, 0, None, 1, 30, "enforced", None),
    ("permissive then exit 0", "init", ns.DONE_PERMISSIVE, 0, None, 1, 30, "permissive", None),
    ("relabeller failed", "init", ns.DONE_FAILED, 0, None, 5, 30, "refused:relabeller-failed", KILLED),
    ("relabeller failed with a reason", "init", b"fenforce-failed:err=OSError_22_\n", 0, None, 5, 30,
     "refused:relabeller-enforce-failed:err=OSError_22_", KILLED),
    ("late failure byte: init exits at once with it waiting", "init", b"fenforce-failed:late\n", 1, None, 0.0, 30,
     "refused:relabeller-enforce-failed:late", None),
    ("a relabeller whose capabilities would not drop", "init", b"fcaps-failed:capbset-drop:16:1\n", 1, None, 0.0,
     30, "refused:relabeller-caps-failed:capbset-drop:16:1", None),
    ("a verb refusal carrying its own prefix", "init", b"frelabeller-verb-namespace-unknown\n", 1, None, 0.0, 30,
     "refused:relabeller-verb-namespace-unknown", None),
    ("init exits 1 before the flip", "init", None, 1, None, 0.2, 30, "refused:init-exited-before-flip-status-1", None),
    ("init killed by a signal before the flip", "init", None, None, signal.SIGTERM, 0.2, 30,
     "refused:init-killed-before-flip-signal-15", None),
    ("deadline", "init", None, 0, None, 5, 0.1, "refused:relabeller-timeout", KILLED),
    ("relabeller dies while init lives", "relabeller", None, 0, None, 15, 30, "refused:relabeller-eof", KILLED),
):
    if writer == "init":
        r, w = os.pipe()
        pid, exit_r = init_like(code, sig, life, w, byte)
        relabeller = None
    else:
        pid, exit_r = init_like(code, sig, life)
        r, w = os.pipe()
        relabeller = relabeller_like(w, 0.2)
    os.close(w)
    calls = []
    got, status = ns.watch_handed_off_init(pid, r, time.time() + deadline_s,
                                           lambda v: calls.append((v, time.monotonic())))
    exited = os.read(exit_r, 64)
    for fd in (exit_r, r):
        os.close(fd)
    if relabeller:
        os.waitpid(relabeller, 0)
    if got != want:
        bad.append(("watch_handed_off_init", label, want, got))
    if [c[0] for c in calls] != [want]:
        bad.append(("on_verdict called once with the verdict", label, want, calls))
    if byte in (ns.DONE_ENFORCED, ns.DONE_PERMISSIVE) and not (calls and exited and calls[0][1] < float(exited)):
        bad.append(("on_verdict before init exits", label, calls, exited))
    if status_ok and not status_ok[1](status):
        bad.append(("init's end", label, status_ok[0], status))

_g_src = open(os.path.join(LAUNCHER, "boot.py")).read()
if 'f"relabeller-{_fail_reasons' in _g_src or "relabeller_refusal(_fail_reasons[0])" not in _g_src:
    bad.append(("g's relabeller refusal", "named through relabeller_refusal"))

with tempfile.TemporaryDirectory() as proc:
    for pid, comm, ppid in ((50, "python3", 40), (51, "rhizo-mntview", 40), (52, "rhizo-mntview", 41)):
        os.makedirs(f"{proc}/{pid}")
        open(f"{proc}/{pid}/stat", "w").write(f"{pid} ({comm}) S {ppid} 1 1 0 -1\n")
    if ns.find_view_keeper(40, proc) != 51 or ns.find_view_keeper(42, proc) is not None:
        bad.append(("find_view_keeper", 51, ns.find_view_keeper(40, proc)))


class RelabellerLibc:
    """libc whose setns and prctl answer set codes"""
    setns_rc = 0
    prctl_rc = 0
    setns = staticmethod(lambda fd, flag: RelabellerLibc.setns_rc)
    unshare = staticmethod(lambda flag: 0)
    prctl = staticmethod(lambda *a: RelabellerLibc.prctl_rc)
    capget = staticmethod(lambda header, sets: 0)
    capset = staticmethod(lambda header, sets: 0)


def handoff_relabeller(setns_rc, exec_fails, prctl_rc=0):
    """call start_handoff_relabeller under a stub libc and execve"""
    done_r, done_w = os.pipe()
    view = os.open("/dev/null", os.O_RDONLY)
    saved = (ns.libc, os.execve)
    RelabellerLibc.setns_rc, RelabellerLibc.prctl_rc = setns_rc, prctl_rc

    kr, kw = os.pipe()
    saved_kmsg = (ns.kmsg, ns.core._kmsg_fd)
    ns.kmsg = lambda m: os.write(kw, (m + "\n").encode())
    ns.core._kmsg_fd = lambda: kw

    def execve(path, argv, env):
        """write the exec's details to the done pipe"""
        if exec_fails:
            raise FileNotFoundError(2, "No such file or directory")
        fds = [int(argv[3]), int(argv[4])]
        text_env = {k.decode(): v.decode() for k, v in env.items()}
        os.write(fds[1], json.dumps([path, argv[:3], text_env, [os.get_inheritable(fd) for fd in fds],
                                     argv[5:]]).encode())
        os._exit(0)

    ns.libc, os.execve = RelabellerLibc, execve
    try:
        pid = ns.start_handoff_relabeller(view, done_w, {b"RHIZO_SANDBOX_ID": b"2"}, "/l.py", "/py", 4242)
    finally:
        ns.libc, os.execve = saved
        ns.kmsg, ns.core._kmsg_fd = saved_kmsg
        os.close(view)
        os.close(kw)
        os.close(done_w)
    _, status = os.waitpid(-1, 0)
    data = b""
    while True:
        chunk = os.read(done_r, 65536)
        if not chunk:
            break
        data += chunk
    os.close(done_r)
    marks = b""
    while True:
        chunk = os.read(kr, 65536)
        if not chunk:
            break
        marks += chunk
    os.close(kr)
    handoff_relabeller.marks = marks.decode()
    return pid, os.waitstatus_to_exitcode(status), data


pid, code, data = handoff_relabeller(0, False)
want = ["/py", ["/py", "/l.py", "selinuxns-relabeller"], {"RHIZO_SANDBOX_ID": "2"}, [True, True], ["4242"]]
try:
    seen = json.loads(data)
except ValueError:
    seen = data
if pid is None or code != 0 or seen != want:
    bad.append(("start_handoff_relabeller exec", want, pid, code, seen))
for label, setns_rc, exec_fails, prctl_rc, want_pid in (("view refused", -1, False, 0, False),
                                                      ("exec fails", 0, True, 0, True)):
    pid, code, data = handoff_relabeller(setns_rc, exec_fails, prctl_rc)
    if (pid is not None) != want_pid or code != 1 or data != ns.DONE_FAILED:
        bad.append(("start_handoff_relabeller", label, want_pid, pid, code, data))
pid, code, data = handoff_relabeller(0, False, -1)
if pid is not None or code != 1 or not re.fullmatch(rb"fcaps-failed:capbset-drop:16:-?\d+\n", data) \
        or "relabeller-view-failed" in handoff_relabeller.marks:
    bad.append(("start_handoff_relabeller", "capabilities that will not drop", pid, code, data,
                handoff_relabeller.marks))

events = []
ns.unshare_namespace = lambda state_file=ns.ANDROID_ENFORCE_FILE: events.append(("unshare", state_file))
ns.mount_own_selinuxfs = lambda t: events.append(("selinuxfs", t))
ns.bind_decoy_enforce = lambda node, scratch: events.append(("decoy", node)) or True
ns.start_handoff_relabeller = lambda *a: events.append(("relabeller",)) or 4242
ns.wait_relabeller_ready = lambda pid: events.append(("ready", pid)) or True
ns.kmsg = lambda m: events.append(("kmsg", m))
ns.begin_handoff_namespace(7, 8, {}, "/l.py", "/py", 9)
if ([e[0] for e in events] != ["unshare", "kmsg", "selinuxfs", "decoy", "relabeller", "ready"]
        or events[0][1] is not None
        or events[1][1] != "RHIZO_MARKER selinuxns=unshared path=handoff"):
    bad.append(("begin_handoff_namespace order", events))
ns.kmsg = lambda m: None


def begin_refused(decoy_ok, relabeller_pid):
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
        ns.bind_decoy_enforce = lambda node, scratch: note("decoy") or decoy_ok
        ns.start_handoff_relabeller = lambda *a: note("relabeller") or relabeller_pid
        ns.wait_relabeller_ready = lambda pid: note("ready", pid) or True
        try:
            ns.begin_handoff_namespace(7, 8, {}, "/l.py", "/py", 9)
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


for decoy_ok, relabeller_pid, want in (
        (False, 4242, (1, [["unshare"], ["kmsg", "RHIZO_MARKER selinuxns=unshared path=handoff"], ["selinuxfs"],
                           ["decoy"], ["kmsg", "RHIZO_MARKER selinuxns=refused reason=decoy-bind-failed"]])),
        (True, None, (1, [["unshare"], ["kmsg", "RHIZO_MARKER selinuxns=unshared path=handoff"], ["selinuxfs"],
                          ["decoy"], ["relabeller"],
                          ["kmsg", "RHIZO_MARKER selinuxns=refused reason=relabeller-not-ready"]]))):
    got = begin_refused(decoy_ok, relabeller_pid)
    if got != want:
        bad.append(("begin_handoff_namespace refusal", want, got))

tree = ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read())
join = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_join_and_exec_init")
src = ast.unparse(join)
for needle in ("begin_handoff_namespace", "watch_handed_off_init", "find_view_keeper", "record_verdict"):
    if needle not in src:
        bad.append(("joiner calls", needle))
if src.find("begin_handoff_namespace") > src.find("enter_sandbox_init"):
    bad.append(("namespace begins before enter_sandbox_init",))
if not (0 <= src.find("open_host_selinuxfs()") < src.find("os.fork()") and "refused:host-selinuxfs" in src
        and "host_selinuxfs_dev)" in src[src.find("begin_handoff_namespace"):src.find("enter_sandbox_init")]):
    bad.append(("the joiner's host selinuxfs", "opened before the fork, refused by name, its device number passed to "
                "begin_handoff_namespace"))
_child = [n for n in ast.walk(join) if isinstance(n, ast.If) and ast.unparse(n.test) == "child == 0"]
_verdict_fn = [n for n in ast.walk(join) if isinstance(n, ast.FunctionDef) and n.name == "on_verdict"]
if len(_child) != 1 or ast.unparse(_child[0].body[0]) != "if ns_mode:\n    release_host_selinuxfs()":
    bad.append(("init's fork", "closes the host selinuxfs handle before anything else",
                ast.unparse(_child[0].body[0]) if _child else None))
if len(_verdict_fn) != 1 or "release_host_selinuxfs()" not in ast.unparse(_verdict_fn[0]):
    bad.append(("the joiner's verdict", "closes the host selinuxfs handle"))
_allow = open(os.path.join(ROOT, "test", "checks", "data", "host-copy-ops-allow.tsv")).read()
if ("begin_handoff_namespace unshares" in _allow
        and 0 <= src.find("selinux_ns.unshare_namespace(") < src.find("begin_handoff_namespace")):
    bad.append(("host-copy-ops-allow.tsv's decoy row", "names the unshare begin_handoff_namespace no longer makes"))

_fork = next((n for n in ast.walk(join) if isinstance(n, ast.Assign) and ast.unparse(n.value) == "os.fork()"), None)
_child = next((n for n in ast.walk(join) if isinstance(n, ast.If) and _fork is not None
               and ast.unparse(n.test) == f"{ast.unparse(_fork.targets[0])} == 0"), None)
_unshares = [n for n in ast.walk(join)
             if isinstance(n, ast.Call) and ast.unparse(n.func) == "selinux_ns.unshare_namespace"]
_in_child = [n for n in ast.walk(_child) if n in _unshares] if _child is not None else []
if _child is None or len(_unshares) != 1 or len(_in_child) != 1:
    bad.append(("pid 1 unshares in its own branch of the fork", len(_unshares), len(_in_child)))
if not 0 <= src.find("selinux_ns.unshare_namespace(") < src.find("mount('proc', '/proc', 'proc'"):
    bad.append(("the joiner unshares before it mounts /proc",))
opens = [ast.unparse(c) for c in ast.walk(join) if isinstance(c, ast.Call)
         and ast.unparse(c.func) == "selinux_ns.open_records_dir"]
want_open = "selinux_ns.open_records_dir(core.paths_for(instance_id).records_dir)"
if opens != [want_open] or ".run_root" in src:
    bad.append(("joiner opens the instance's records dir", [want_open], opens, ".run_root named" if ".run_root" in src
                else "no .run_root"))
gated = [n for n in ast.walk(join) if isinstance(n, ast.If) and "host_selinux_mode" in ast.unparse(n.test) or
         isinstance(n, ast.If) and isinstance(n.test, ast.Name) and n.test.id == "ns_mode"]
if not gated:
    bad.append(("namespace steps sit under a mode gate",))


def mode_gate(test):
    """return whether an if test is a namespace-mode gate"""
    return (ast.unparse(test) in ("ns_mode", "keeper_fd >= 0") or isinstance(test, ast.BoolOp)
            and isinstance(test.op, ast.And) and ast.unparse(test.values[0]) == "ns_mode")


inside = {id(c) for g in ast.walk(join) if isinstance(g, ast.If) and mode_gate(g.test) for c in ast.walk(g)}
loose = [ast.unparse(c) for c in ast.walk(join) if isinstance(c, ast.Call)
         and ast.unparse(c.func).startswith("selinux_ns.") and id(c) not in inside]
if loose:
    bad.append(("selinux_ns calls outside the mode gate", loose))

tries = [t for t in ast.walk(join) if isinstance(t, ast.Try)
         and "selinux_ns.kill_view_keeper(keeper_fd)" in "\n".join(ast.unparse(s) for s in t.finalbody)]
found = [c.lineno for c in ast.walk(join)
         if isinstance(c, ast.Call) and ast.unparse(c.func).endswith("find_view_keeper")]
if len(tries) != 1 or len(found) != 1:
    bad.append(("keeper killed in a finally", "one try/finally and one find_view_keeper", len(tries), found))
else:
    body = {id(n) for s in tries[0].body for n in ast.walk(s)}
    text = "\n".join(ast.unparse(s) for s in tries[0].body)
    late = [r.lineno for r in ast.walk(join) if isinstance(r, ast.Return) and r.lineno > found[0] and id(r) not in body]
    if late or "os.fork()" not in text or "watch_handed_off_init" not in text:
        bad.append(("keeper killed in a finally", "every return after find_view_keeper, the fork and the watch inside",
                    late))

verdicts = [n for n in ast.walk(join) if isinstance(n, ast.FunctionDef) and n.name == "on_verdict"]
if len(verdicts) != 1:
    bad.append(("on_verdict", "one nested definition", len(verdicts)))
else:
    seen = []

    class VerdictNs:
        """selinux_ns stand-in recording what on_verdict calls"""
        record_verdict = staticmethod(lambda v, d: seen.append(("record_verdict", v, d)))
        record_android_enforce = staticmethod(lambda v, d: seen.append(("record_android_enforce", v, d)))
        kill_view_keeper = staticmethod(lambda fd: seen.append(("kill_view_keeper", fd)))

    scope = {"selinux_ns": VerdictNs, "records_fd": 5, "keeper_fd": 9, "kmsg": lambda m: seen.append(("kmsg", m)),
             "print": lambda *a, **k: seen.append(("print",) + a), "verdicts": [],
             "release_host_selinuxfs": lambda: seen.append(("release_host_selinuxfs",))}
    exec(compile(ast.Module(body=verdicts, type_ignores=[]), "boot.py", "exec"), scope)
    for v in ("enforced", "permissive", "refused:relabeller-timeout", "stopped"):
        seen.clear()
        try:
            scope["on_verdict"](v)
        except NameError as e:
            seen.append(("raised", repr(e)))
        want = ([("release_host_selinuxfs",), ("record_verdict", v, 5)]
                + ([("record_android_enforce", "1", 5)] if v == "enforced" else [])
                + [("kmsg", f"RHIZO_MARKER selinuxns=handoff-verdict {v}"),
                   ("print", f"handoff: namespace verdict {v}"), ("kill_view_keeper", 9)])
        if seen != want or scope["verdicts"][-1:] != [v]:
            bad.append(("on_verdict", v, want, list(seen), scope["verdicts"]))

start = next(n.lineno for n in ast.walk(join) if isinstance(n, ast.Assign) and ast.unparse(n.targets[0]) == "ns_mode")
unnamed = []
for block in (getattr(n, f, None) for n in ast.walk(join) for f in ("body", "orelse", "finalbody")):
    if not isinstance(block, list):
        continue
    for i, stmt in enumerate(block):
        if (isinstance(stmt, ast.Return) and stmt.lineno > start and ast.unparse(stmt.value) == "_JOIN_FAILED"
                and not any("record_verdict(" in ast.unparse(e) for e in block[:i])):
            unnamed.append(stmt.lineno)
if unnamed:
    bad.append(("namespace-mode refusals record a verdict", "every return _JOIN_FAILED", unnamed))
refusals = sorted(c.args[0].value if isinstance(c.args[0], ast.Constant) else ast.unparse(c.args[0])
                  for c in ast.walk(join) if isinstance(c, ast.Call) and ast.unparse(c.func).endswith("record_verdict")
                  and c.args and "refused:" in ast.unparse(c.args[0]))
want = ["f'refused:join-setns-{name}'", "refused:host-selinuxfs", "refused:join-inputs", "refused:join-open-namespaces",
        "refused:join-unshare-pid", "refused:no-view-keeper", "refused:relabeller-watcher-raised"]
if refusals != want:
    bad.append(("joiner refusal names", want, refusals))

waits = [h for t in ast.walk(join) if isinstance(t, ast.Try) and "watch_handed_off_init" in ast.unparse(t.body[0])
         for h in t.handlers]
if len(waits) != 1:
    bad.append(("watch handler", "one handler on the try around the watch", len(waits)))
elif ast.unparse(waits[0].type) != "Exception":
    bad.append(("watch handler", "catches Exception", ast.unparse(waits[0].type)))
else:
    handler = ast.FunctionDef(name="handler", args=ast.arguments(posonlyargs=[], args=[], kwonlyargs=[], kw_defaults=[],
                                                                defaults=[]),
                              body=waits[0].body + ast.parse("return st").body, decorator_list=[], returns=None,
                              type_params=[])
    code = compile(ast.fix_missing_locations(ast.Module(body=[handler], type_ignores=[])), "boot.py", "exec")
    refuse = [("kill", 4242, signal.SIGKILL),
              ("kmsg", "RHIZO_MARKER selinuxns=refused reason=relabeller-watcher-raised"),
              ("record_verdict", "refused:relabeller-watcher-raised", 5)]
    boom = "RHIZO_MARKER selinuxns=watch-raised-after-verdict verdict=%s err=RuntimeError('boom')"
    wait = ("waitpid", 4242, 0)
    for label, exc, ns_mode, verdicts, reaped, want, want_got in (
            ("no verdict yet, OSError", OSError(9, "Bad file descriptor"), True, [], 77, refuse, 0),
            ("no verdict yet, not an OSError", RuntimeError("boom"), True, [], 77, refuse, 0),
            ("after a verdict, init is waited for and its end recorded", RuntimeError("boom"), True, ["enforced"], 77,
             [("kmsg", boom % "enforced"), wait, ("record_start_end", "enforced", 5)], 77),
            ("after a verdict, init already reaped, the end is still recorded", RuntimeError("boom"), True,
             ["enforced"], None, [("kmsg", boom % "enforced"), wait, ("record_start_end", "enforced", 5)], 0),
            ("after a refusal, init already reaped, no end record", RuntimeError("boom"), True,
             ["refused:relabeller-timeout"], None, [("kmsg", boom % "refused:relabeller-timeout"), wait], 0),
            ("host mode", OSError(9, "Bad file descriptor"), False, [], 77, [], 0)):
        seen = []

        class HandlerOs:
            """os stand-in recording kills and waits"""
            kill = staticmethod(lambda p, s: seen.append(("kill", p, s)))

            @staticmethod
            def waitpid(p, flags):
                """record the wait and answer the case's status, or raise ECHILD"""
                seen.append(("waitpid", p, flags))
                if reaped is None:
                    raise ChildProcessError(10, "No child processes")
                return p, reaped

        class HandlerNs:
            """selinux_ns stand-in recording verdicts"""
            record_verdict = staticmethod(lambda v, d: seen.append(("record_verdict", v, d)))
            record_start_end = staticmethod(lambda v, d: seen.append(("record_start_end", v, d)))

        scope = {"e": exc, "child": 4242, "ns_mode": ns_mode, "verdicts": verdicts,
                 "release_host_selinuxfs": lambda: None,
                 "records_fd": 5, "os": HandlerOs, "signal": signal, "selinux_ns": HandlerNs,
                 "kmsg": lambda m: seen.append(("kmsg", m)), "print": lambda *a, **k: None}
        exec(code, scope)
        try:
            got = scope["handler"]()
        except NameError as e:
            got = repr(e)
        if seen != want or got != want_got:
            bad.append(("watch handler", label, want, seen, got))


def read_records(dfd):
    """return the records dir's verdict, enforce state and inodes"""
    names = [os.path.basename(p) for p in (ns.VERDICT_FILE, ns.ANDROID_ENFORCE_FILE)]
    return ([open(f"/proc/self/fd/{dfd}/{n}").read().strip() for n in names],
            [os.stat(n, dir_fd=dfd).st_ino for n in names])


watch_trys = [t for t in ast.walk(join) if isinstance(t, ast.Try) and "watch_handed_off_init" in ast.unparse(t.body[0])]
if len(watch_trys) != 1:
    bad.append(("joiner's end record", "one try opening with the watch", len(watch_trys)))
else:
    no_args = ast.arguments(posonlyargs=[], args=[], kwonlyargs=[], kw_defaults=[], defaults=[])
    watch_fn = ast.FunctionDef(name="joiner_watch", args=no_args, body=watch_trys + ast.parse("return 'ended'").body,
                               decorator_list=[], returns=None, type_params=[])
    watch = compile(ast.fix_missing_locations(ast.Module(body=[watch_fn], type_ignores=[])), "boot.py", "exec")
    saved_watch = ns.watch_handed_off_init
    try:
        for verdict, seed, want in (("enforced", ("enforced", "1"), ("stopped", "0")),
                                    ("permissive", ("permissive", "0"), ("stopped", "0")),
                                    ("refused:relabeller-timeout", ("refused:relabeller-timeout", "0"), None),
                                    ("refused:init-exited-before-flip-status-0",
                                     ("refused:init-exited-before-flip-status-0", "0"), None),
                                    ("stopped", ("stopped", "0"), None)):
            ns.watch_handed_off_init = lambda *a, v=verdict, **kw: (v, 0)
            with tempfile.TemporaryDirectory() as tmp:
                dfd = os.open(tmp, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    ns.record_verdict(seed[0], dfd)
                    ns.write_android_enforce(seed[1], ns.ANDROID_ENFORCE_FILE, dir_fd=dfd)
                    before = read_records(dfd)
                    scope = {"ns_mode": True, "selinux_ns": ns, "child": 4242, "done_r": 5, "time": time,
                             "on_verdict": lambda v: None, "records_fd": dfd, "os": os, "holder_fd": -1,
                             "release_host_selinuxfs": lambda: None}
                    try:
                        exec(watch, scope)
                        scope["joiner_watch"]()
                    except BaseException as e:
                        bad.append(("joiner's end record", verdict, "raised", repr(e)))
                    after = read_records(dfd)
                finally:
                    os.close(dfd)
            if (want is None and after != before) or (want is not None and after[0] != list(want)):
                bad.append(("joiner's end record", verdict, want or "records untouched", after[0],
                            "rewritten" if after[1] != before[1] else "same inodes"))
    finally:
        ns.watch_handed_off_init = saved_watch

    ends = []

    def raising_end(v, d):
        """count the end record and raise as a programming error would"""
        ends.append(v)
        raise RuntimeError("end record")

    class NoChild:
        """os stand-in whose init was already reaped"""
        @staticmethod
        def waitpid(p, flags):
            """raise ECHILD as for a reaped init"""
            raise ChildProcessError(10, "No child processes")

    end_ns = type("EndNs", (), {"watch_handed_off_init": staticmethod(lambda *a, **kw: ("enforced", 0)),
                                "record_start_end": staticmethod(raising_end),
                                "record_verdict": staticmethod(lambda v, d: None),
                                "RELABELLER_DEADLINE_S": ns.RELABELLER_DEADLINE_S})
    scope = {"ns_mode": True, "selinux_ns": end_ns, "child": 4242, "done_r": 5, "time": time,
             "on_verdict": lambda v: None, "records_fd": 7, "os": NoChild, "verdicts": ["enforced"], "holder_fd": -1,
             "kmsg": lambda m: None, "print": lambda *a, **k: None, "signal": signal,
             "release_host_selinuxfs": lambda: None}
    exec(watch, scope)
    try:
        got = scope["joiner_watch"]()
    except RuntimeError as e:
        got = repr(e)
    if ends != ["enforced"] or got != "RuntimeError('end record')":
        bad.append(("joiner's end record raising", "one write, its error raised", ends, got))

sup = next(n for n in ast.parse(open(os.path.join(LAUNCHER, "boot.py")).read()).body
           if isinstance(n, ast.FunctionDef) and n.name == "run_kernel_domain_supervisor")
forks = [n for n in ast.walk(sup) if isinstance(n, ast.If) and ast.unparse(n.test) == "joiner_pid == 0"]
if len(forks) != 1:
    bad.append(("the joiner fork", "one if joiner_pid == 0", len(forks)))
else:
    fork_code = compile(ast.Module(body=forks[0].body, type_ignores=[]), "boot.py", "exec")
    for label, joined, want_code, want_mark in (("a raising joiner", RuntimeError("boom"), 1, "joiner-raised"),
                                                ("a joiner returning 0", 0, 0, None)):
        exits, marks = [], []

        def joiner(pid1, hentry, instance_id, joined=joined):
            """raise or return the case's answer"""
            if isinstance(joined, BaseException):
                raise joined
            return joined

        class ForkOs:
            """os stand-in recording _exit and the closes"""
            _exit = staticmethod(exits.append)
            close = staticmethod(lambda fd: marks.append(f"close {fd}"))

        scope = dict(vars(launcher), os=ForkOs, kmsg=marks.append, _join_and_exec_init=joiner,
                     joiner_pid=0, pid1=4242, hentry="second_stage", instance_id=3, holder_fd=9)
        try:
            exec(fork_code, scope)
        except BaseException as e:
            exits.append(repr(e))
        if exits != [want_code] or (want_mark is not None and not any(
                want_mark in m and "instance=3" in m for m in marks)):
            bad.append(("the joiner fork", label, want_code, want_mark, exits, marks))

for label, umount_rc, want_dir, want_mark in (("detach fails", -1, True, "decoy-scratch-umount-failed"),
                                              ("rmdir fails", 0, True, "decoy-scratch-rmdir-failed")):
    logs = []

    class DecoyLibc:
        """libc whose umount2 answers the case's code"""
        umount2 = staticmethod(lambda path, flags: umount_rc)

    saved = (ns.libc, ns.mount, ns.kmsg)
    ns.libc, ns.mount, ns.kmsg = DecoyLibc, lambda *a: True, logs.append
    with tempfile.TemporaryDirectory() as tmp:
        scratch = f"{tmp}/scratch"
        try:
            got = bind_decoy_enforce(f"{tmp}/enforce", scratch)
        except BaseException as e:
            got = repr(e)
        finally:
            ns.libc, ns.mount, ns.kmsg = saved
        left = os.path.isdir(scratch)
    if got is not True or left != want_dir or not any(f"selinuxns={want_mark}" in l for l in logs):
        bad.append(("bind_decoy_enforce", label, True, want_mark, got, left, logs))

primer = [c for c in ast.walk(join) if isinstance(c, ast.Call) and ast.unparse(c) == "write_primer_script()"]
init_fork = [n.lineno for n in ast.walk(join) if isinstance(n, ast.Assign) and ast.unparse(n) == "child = os.fork()"]
if len(primer) != 1 or id(primer[0]) not in inside or not init_fork or primer[0].lineno > init_fork[0]:
    bad.append(("the joiner writes the primer", "once, under ns_mode, before init's fork", len(primer), init_fork))
else:
    guard = [t for t in ast.walk(join) if isinstance(t, ast.Try)
             and [ast.unparse(x) for x in t.body] == ["write_primer_script()"]]
    marks = []

    def broken_writer():
        """fail the primer write"""
        raise PermissionError(13, "Permission denied")

    try:
        exec(compile(ast.Module(body=guard, type_ignores=[]), "boot.py", "exec"),
             {"write_primer_script": broken_writer, "kmsg": marks.append})
    except BaseException as e:
        marks.append(f"raised {e!r}")
    failed_mark = "RHIZO_MARKER selinuxns=pass-failed name=write-primer-script"
    if len(guard) != 1 or not marks or not marks[0].startswith(failed_mark):
        bad.append(("a failed joiner primer write", "logged by name", marks))

mod_if = next(n for n in tree.body if isinstance(n, ast.If) and "__main__" in ast.unparse(n.test))
mod = ast.unparse(mod_if)
if "selinuxns-relabeller" not in mod or mod.find("selinuxns-relabeller") > mod.find("main()"):
    bad.append(("relabeller verb before main()",))
verb = [n for n in mod_if.body if isinstance(n, ast.If) and "selinuxns-relabeller" in ast.unparse(n.test)]
if len(verb) != 1:
    bad.append(("relabeller verb", "one dispatch", len(verb)))
else:
    ran = []

    class VerbNs:
        """selinux_ns stand-in recording which relabeller runs"""
        run_relabeller = staticmethod(lambda *a: ran.append(("run_relabeller",) + a) or 1)
        run_handoff_relabeller = staticmethod(lambda *a: ran.append(("run_handoff_relabeller",) + a) or 1)

    class VerbSys:
        """sys stand-in with the verb's argv"""
        argv = []
        exit = staticmethod(lambda code: ran.append(("sys.exit", code)))

    class VerbOs:
        """os stand-in recording the exit"""
        _exit = staticmethod(lambda code: ran.append(("os._exit", code)))

    for argv, host_fd in ((["boot.py", "selinuxns-relabeller", "5", "6", "9"], 9),
                          (["boot.py", "selinuxns-relabeller", "5", "6"], -1)):
        ran.clear()
        VerbSys.argv = argv
        exec(compile(ast.Module(body=verb, type_ignores=[]), "boot.py", "exec"),
             {"sys": VerbSys, "os": VerbOs, "selinux_ns": VerbNs, "NEWROOT": launcher.NEWROOT,
              "write_primer_script": "writer", "coldboot_primer_spec": lambda: ["spec"]})
        want = [("run_handoff_relabeller", launcher.NEWROOT, ["spec"], 5, 6, host_fd), ("os._exit", 1)]
        if ran != want:
            bad.append(("relabeller verb", want, ran))

for b in bad:
    print("FAIL", b)
print("ok" if not bad else "FAIL")
sys.exit(1 if bad else 0)
