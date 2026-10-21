#!/usr/bin/env python3
import builtins, contextlib, ctypes, errno, inspect, io, os, signal, struct, sys, tempfile, time
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-relabel-order")
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_ns as ns

ORDER = ["wait-load", "dev-labelable", "flat", "root-objects", "sysctl-shadows", "dev-file-contexts",
         "unmount-copy-enforce", "enforce-write"]
PASSES = ["flat", "root-objects", "sysctl-shadows", "dev-file-contexts"]
PRIVATE_FD = 999
TMPFS_MAGIC = 0x01021994
bad = []
tmp = tempfile.TemporaryDirectory()
newroot = f"{tmp.name}/root"
os.makedirs(f"{newroot}/dev")
state = f"{tmp.name}/run/rhizo-selinuxns/android-enforce"
os.makedirs(os.path.dirname(state))
staged = [("/dev/loop-control", "u:object_r:loop_control_device:s0")]
calls, logs, sleeps = [], [], []
knobs = {"setns": 0, "copies": 1, "flipped-at": None}


class Clock:
    """a clock the injected sleep advances"""
    now = 1000.0

    @staticmethod
    def time():
        """return the fake time"""
        return Clock.now


class FakeLibc:
    """stand-in for core.libc recording setns and umount2"""

    @staticmethod
    def setns(fd, flag):
        """record the setns and answer the knob"""
        calls.append(("setns", fd, flag))
        return knobs["setns"]

    @staticmethod
    def umount2(path, flag):
        """record the umount2, peel a copy and succeed"""
        calls.append(("umount2", path, flag))
        knobs["copies"] -= 1
        return 0


def fake_fs_type(path):
    """answer tmpfs or selinuxfs for the enforce node"""
    calls.append(("statfs", path))
    return ns.SELINUX_MAGIC if knobs["copies"] <= 0 else TMPFS_MAGIC


def events():
    """return the selinuxns marker names"""
    out = []
    for line in logs:
        if "RHIZO_MARKER selinuxns=" not in line:
            continue
        word = line.split("RHIZO_MARKER selinuxns=", 1)[1].split()[0]
        if word == "pass-failed":
            word = line.split("name=", 1)[1].split()[0]
        out.append(word)
    return out


def recorder(name, raises, nap=0):
    """return a recording stand-in pass"""
    def run(root, spec):
        """record the pass with its arguments"""
        calls.append((name, root, spec))
        if nap:
            time.sleep(nap)
        if raises:
            raise RuntimeError(f"{name} broke")
    return run


def run(answers, raising="root-objects", enforcing=True, writer_raises=False, eopnotsupp=2, setns=0, copies=1,
        nap=None, held=("0", "1"), primer=True, on_load=None):
    """call _relabel_after_load under stubs and return its result"""
    calls.clear(); logs.clear(); sleeps.clear()
    knobs["setns"], knobs["copies"], knobs["flipped-at"] = setns, copies, None
    with open(state, "w") as f:
        f.write("0\n")
    answers = iter(answers)
    left = [eopnotsupp]

    def reader():
        """answer the next context, the last one forever"""
        try:
            reader.last = next(answers)
        except StopIteration:
            pass
        return reader.last
    reader.last = "kernel"

    def sleep(s):
        """record the sleep and advance the clock"""
        sleeps.append(s)
        Clock.now += s

    def writer(fd):
        """record the enforce write"""
        calls.append(("enforce", fd))
        if writer_raises:
            raise OSError(errno.EINVAL, "Invalid argument")
        knobs["flipped-at"] = len(logs)
        return held

    def fake_getxattr(path, name, follow_symlinks=True):
        """answer EOPNOTSUPP or the tmpfs label for /dev"""
        if path == f"{newroot}/dev" and left[0] > 0:
            left[0] -= 1
            raise OSError(errno.EOPNOTSUPP, "Operation not supported")
        return b"u:object_r:tmpfs:s0\0"

    def fake_setxattr(path, name, value, flags=0, follow_symlinks=True):
        """record the label write"""
        calls.append(("setxattr", path))

    passes = {n: recorder(n, n == raising, nap if n == "flat" else 0) for n in PASSES}
    saved = (ns.kmsg, ns.libc, ns.label_net_core, ns.time, ns.RHIZO_ENFORCING, ns.fs_type, ns._open_private_enforce,
             ns.ANDROID_ENFORCE_FILE, os.getxattr, os.setxattr)
    ns.kmsg, ns.libc, ns.time, ns.RHIZO_ENFORCING, ns.fs_type = logs.append, FakeLibc, Clock, enforcing, fake_fs_type
    ns._open_private_enforce = lambda: (calls.append(("open-private-enforce",)), PRIVATE_FD)[1]
    ns.label_net_core = lambda: (calls.append(("net-core",)), (2, 0, []))[1]
    ns.ANDROID_ENFORCE_FILE = state
    os.getxattr, os.setxattr = fake_getxattr, fake_setxattr
    real_close = os.close
    os.close = lambda fd: None if fd == PRIVATE_FD else real_close(fd)
    try:
        return ns._relabel_after_load(newroot, staged, mntns_fd=-1,
                                      write_primer_script=(lambda: calls.append(("write-primer-script",)))
                                      if primer else None,
                                      attr_reader=reader, sleep=sleep, passes=passes, enforce_writer=writer,
                                      on_load=on_load)
    except Exception as e:
        return repr(e)
    finally:
        os.close = real_close
        (ns.kmsg, ns.libc, ns.label_net_core, ns.time, ns.RHIZO_ENFORCING, ns.fs_type, ns._open_private_enforce,
         ns.ANDROID_ENFORCE_FILE, os.getxattr, os.setxattr) = saved


def state_now():
    """return the state file's content"""
    with open(state) as f:
        return f.read()


got = run(["kernel", "kernel", "u:r:init:s0"])
if got != ns.DONE_ENFORCED:
    bad.append(("result", ns.DONE_ENFORCED, got))
if events() != ORDER:
    bad.append(("marker order", ORDER, events()))
if knobs["flipped-at"] is None or logs[knobs["flipped-at"]:]:
    bad.append(("no kmsg once enforcing", [], logs[knobs["flipped-at"] or 0:]))
if not any("selinuxns=pass-failed name=root-objects" in l and "root-objects broke" in l for l in logs):
    bad.append(("raising pass logged", "pass-failed name=root-objects err=...broke", list(logs)))
node = "/sys/fs/selinux/enforce"
want_calls = ([("write-primer-script",), ("setxattr", f"{newroot}/dev")]
              + [(n, newroot, staged) for n in PASSES]
              + [("open-private-enforce",), ("setns", -1, ns.CLONE_NEWNS), ("statfs", node),
                 ("umount2", node.encode(), 2), ("statfs", node), ("net-core",), ("enforce", PRIVATE_FD)])
if calls != want_calls:
    bad.append(("calls", want_calls, list(calls)))
if sleeps != [0.01, 0.01, 0.05, 0.05]:
    bad.append(("waits", [0.01, 0.01, 0.05, 0.05], list(sleeps)))
if state_now() != "0\n" or sorted(os.listdir(os.path.dirname(state))) != ["android-enforce"]:
    bad.append(("state file left to the watcher", "0\n", state_now(), os.listdir(os.path.dirname(state))))

got = run(["u:r:init:s0"], raising=None, eopnotsupp=0, copies=2)
if (got != ns.DONE_ENFORCED or [c for c in calls if c[0] == "umount2"] != [("umount2", node.encode(), 2)] * 2
        or logs[knobs["flipped-at"]:]):
    bad.append(("two copies", "two umount2 then enforced", got, list(calls)))

got = run(["u:r:init:s0"], raising=None, eopnotsupp=0, copies=99)
if (got != ns.DONE_FAILED or any(c[0] == "enforce" for c in calls) or state_now() != "0\n"
        or len([c for c in calls if c[0] == "umount2"]) != 8 or "enforce-write" in events()):
    bad.append(("copy stays", "8 umount2, no enforce, state 0, failed", got, list(calls), events()))

got = run(["u:r:init:s0"], raising=None, eopnotsupp=0, setns=-1)
if got != ns.DONE_FAILED or any(c[0] in ("umount2", "enforce") for c in calls) or state_now() != "0\n":
    bad.append(("setns failure", "failed, nothing flipped", got, list(calls)))
if "setns-failed" not in events():
    bad.append(("setns failure marker", "setns-failed", events()))
if not getattr(got, "reason", "").startswith("setns-failed:errno="):
    bad.append(("setns failure reason", "setns-failed:errno=...", getattr(got, "reason", None)))

got = run(["u:r:init:s0"], raising=None, writer_raises=True, eopnotsupp=0)
if got != ns.DONE_FAILED or knobs["flipped-at"] is not None or state_now() != "0\n":
    bad.append(("enforce failure", "failed, no flip, state 0", got, events(), state_now()))
if not getattr(got, "reason", "").startswith("enforce-failed:err=OSError("):
    bad.append(("enforce failure reason", "enforce-failed:err=OSError(...", getattr(got, "reason", None)))
if any("enforce-failed" in l for l in logs[events().index("enforce-write"):]):
    bad.append(("no kmsg after a failed enforce write", [], list(logs)))

got = run(["u:r:init:s0"], raising=None, eopnotsupp=0, held=("0", "0"))
if got != ns.DONE_FAILED or getattr(got, "reason", None) != "enforce-failed:before=0,after=0" \
        or knobs["flipped-at"] is None or logs[knobs["flipped-at"]:]:
    bad.append(("enforce not held", "failed, enforce-failed:before=0,after=0, no kmsg", got,
                getattr(got, "reason", None), list(logs)))

ns.PASSES_LIMIT_S = 0.3
try:
    got = run(["u:r:init:s0"], raising=None, eopnotsupp=0, nap=3)
finally:
    ns.PASSES_LIMIT_S = 20
if (got != ns.DONE_ENFORCED or events() != ["wait-load", "dev-labelable", "passes-cut"] + ORDER[6:]
        or any(c[0] in PASSES[1:] for c in calls) or logs[knobs["flipped-at"]:]):
    bad.append(("passes cut", "passes-cut then the flip", got, events(), list(calls)))

got = run(["u:r:init:s0"], raising=None, enforcing=False, eopnotsupp=0)
if (got != ns.DONE_PERMISSIVE or any(c[0] in ("setns", "umount2", "enforce", "open-private-enforce") for c in calls)
        or state_now() != "0\n" or events() != ORDER[:6] + ["permissive-kept"]):
    bad.append(("permissive", "passes only, permissive-kept, state 0", got, list(calls), events(), state_now()))

got = run(["kernel"], raising=None, eopnotsupp=0)
if got != ns.DONE_FAILED or events() != ["no-policy-load"] or [c for c in calls if c[0] != "write-primer-script"]:
    bad.append(("no load", "failed, no-policy-load only", got, events(), list(calls)))
if state_now() != "0\n":
    bad.append(("no load state", "0\n", state_now()))

hooks = []
got = run(["kernel", "kernel", "u:r:init:s0"], raising=None, eopnotsupp=0, on_load=lambda: hooks.append(
    (len(logs), len(sleeps), len(calls))))
if hooks != [(0, 2, 1)] or got != ns.DONE_ENFORCED or events() != ORDER:
    bad.append(("the load hook", "once, after two polls, before the first kmsg line and pass", got, hooks, events()))

got = run(["u:r:init:s0"], raising=None, eopnotsupp=0, on_load=lambda: "helper-domain:setcon:13")
if (got != ns.DONE_FAILED or getattr(got, "reason", None) != "helper-domain:setcon:13" or events()
        or [c for c in calls if c[0] != "write-primer-script"]):
    bad.append(("the load hook refusing", "failed, its reason, no marker, no pass", got, getattr(got, "reason", None),
                events(), list(calls)))

hooks.clear()
got = run(["kernel"], raising=None, eopnotsupp=0, on_load=lambda: hooks.append("called"))
if hooks:
    bad.append(("the load hook without a load", "never called", hooks))

class ContextSys:
    """fake lsm_get_self_attr answering a context"""

    def syscall(self, nr, *args):
        """answer the context for the get syscall"""
        attr, buf, size_ref, flags = args
        ctx = b"u:r:kernel:s0\0"
        data = struct.pack("<QQQQ", 101, 0, 32 + len(ctx), len(ctx)) + ctx
        ctypes.memmove(buf, data, len(data))
        size_ref._obj.value = len(data)
        return 1


real_open, real_sys = builtins.open, ns._libc
opened = []
builtins.open = lambda *a, **k: opened.append(a) or real_open(*a, **k)
ns._libc = ContextSys()
try:
    context = inspect.signature(ns._relabel_after_load).parameters["attr_reader"].default()
finally:
    builtins.open, ns._libc = real_open, real_sys
if context != "u:r:kernel:s0" or opened:
    bad.append(("the relabeller's poll", "u:r:kernel:s0 through the syscall, no open", context, opened))

records_dir = getattr(ns, "SELINUXNS_RECORDS_DIR", None)
if ns.ANDROID_ENFORCE_FILE != f"{records_dir}/android-enforce" or ns.ANDROID_ENFORCE_FILE.startswith(ns.core.RUN_ROOT + "/"):
    bad.append(("state path", f"{records_dir}/android-enforce", ns.ANDROID_ENFORCE_FILE))

saved = (ns._relabel_after_load, ns.connect_label_service, ns.kmsg)
done_r, done_w = os.pipe()
logs.clear()
ns._relabel_after_load = lambda *a, **k: ns.DONE_ENFORCED
ns.connect_label_service = lambda: None
ns.kmsg = logs.append
try:
    code = ns.run_relabeller(newroot, staged, -1, lambda: None, done_w)
finally:
    ns._relabel_after_load, ns.connect_label_service, ns.kmsg = saved
    os.close(done_w)
byte = os.read(done_r, 1)
os.close(done_r)
if code != 0 or byte != ns.DONE_ENFORCED or logs:
    bad.append(("run_relabeller after the flip", (0, ns.DONE_ENFORCED, []), (code, byte, list(logs))))



SCAN_MODULES = tuple(sorted(f[:-3] for f in os.listdir(os.path.join(LAUNCHER, "sandbox")) if f.endswith(".py")))
FS_WRITES = {"replace", "rename", "unlink", "remove", "makedirs", "mkdir", "rmdir", "symlink", "link", "chmod", "chown",
             "truncate"}


def post_flip_effects(sources=None):
    """return each kmsg or write a post-flip path reaches"""
    import ast
    texts = {m: open(os.path.join(LAUNCHER, "sandbox", m + ".py")).read() for m in SCAN_MODULES}
    texts.update(sources or {})
    funcs = {(m, n.name): n for m, text in texts.items() for n in ast.parse(text).body
             if isinstance(n, ast.FunctionDef)}
    imports_from = {m: ["core"] for m in SCAN_MODULES if m != "core"}

    def resolve(mod, call):
        """return the function a call names, or None"""
        f = call.func
        if isinstance(f, ast.Name):
            return next(((m, f.id) for m in [mod] + imports_from.get(mod, []) if (m, f.id) in funcs), None)
        if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and (f.value.id, f.attr) in funcs:
            return (f.value.id, f.attr)
        return None

    def effects(nodes, fn=None):
        """return each kmsg or file write inside nodes"""
        out = []
        logs = set()
        if fn is not None:
            args = fn.args.args[len(fn.args.args) - len(fn.args.defaults):] + fn.args.kwonlyargs
            defaults = fn.args.defaults + fn.args.kw_defaults
            logs = {a.arg for a, d in zip(args, defaults) if d is not None and ast.unparse(d) == "kmsg"}
        for c in (n for node in nodes for n in ast.walk(node) if isinstance(n, ast.Call)):
            name = ast.unparse(c.func)
            text = ast.unparse(c)[:100]
            if name in ("kmsg", "core.kmsg") or name in logs:
                out.append(("kmsg", c.lineno, text))
            elif name in ("open", "io.open", "os.fdopen") or (name.endswith(".open") and name != "os.open"):
                at = 1 if name in ("open", "io.open", "os.fdopen") else 0
                mode = c.args[at] if len(c.args) > at else next((k.value for k in c.keywords if k.arg == "mode"), None)
                if mode is not None and set(ast.unparse(mode)) & set("wax+"):
                    out.append(("file write", c.lineno, text))
            elif name.endswith((".write_text", ".write_bytes")):
                out.append(("file write", c.lineno, text))
            elif name == "os.write" and ast.unparse(c.args[0]) != "done_fd":
                out.append(("file write", c.lineno, text))
            elif name == "os.open" and any(f in text for f in ("O_WRONLY", "O_RDWR", "O_CREAT")):
                out.append(("file write", c.lineno, text))
            elif name.startswith("os.") and name[3:] in FS_WRITES or name.startswith("shutil."):
                out.append(("file write", c.lineno, text))
        return out

    def calls(mod, nodes):
        """return the functions calls inside nodes name"""
        return [r for node in nodes for n in ast.walk(node) if isinstance(n, ast.Call) for r in [resolve(mod, n)] if r]

    def after(fn, name, nodes=None):
        """return statements from the first call to name"""
        body = nodes or [funcs[("selinux_ns", fn)]]
        first = min(n.lineno for node in body for n in ast.walk(node)
                    if isinstance(n, ast.Call) and ast.unparse(n.func).split(".")[-1] == name)
        return [n for node in body for n in ast.walk(node) if isinstance(n, ast.stmt) and n.lineno >= first
                and not isinstance(n, (ast.Try, ast.FunctionDef))]

    fork = next(n for n in ast.walk(funcs[("selinux_ns", "start_relabeller")])
                if isinstance(n, ast.If) and ast.unparse(n.test) == "pid == 0")
    roots = [("_flip", after("_flip", "writer")), ("_relabel_after_load", after("_relabel_after_load", "_flip")),
             ("run_relabeller", after("run_relabeller", "_relabel_after_load")),
             ("start_relabeller child", after(None, "run_relabeller", fork.body))]
    found, todo = [], []
    seen = {("selinux_ns", f) for f in ("_flip", "_relabel_after_load", "run_relabeller", "start_relabeller")}
    for owner, nodes in roots:
        found += [(f"selinux_ns.{owner}",) + e for e in effects(nodes)]
        todo += calls("selinux_ns", nodes)
    while todo:
        key = todo.pop()
        if key in seen:
            continue
        seen.add(key)
        found += [(f"{key[0]}.{key[1]}",) + e for e in effects([funcs[key]], funcs[key])]
        todo += calls(key[0], [funcs[key]])
    return sorted(set(found))


for owner, kind, line, text in post_flip_effects():
    bad.append((f"{kind} after the flip", "none", f"{owner} line {line}: {text}"))
flip_src = open(os.path.join(LAUNCHER, "sandbox/selinux_ns.py")).read()
anchor = "        before, after = writer(enforce_fd)\n"
for label, plant, want in (("a helper in core that logs", "        core.unmount_under('/x')\n", "kmsg"),
                           ("a helper in hals that logs", "        hals.stage_software_rro()\n", "kmsg"),
                           ("a host file write", "        open('/run/rhizo-x', 'w').write('1')\n", "file write"),
                           ("a keyword-mode write", "        open('/run/rhizo-x', mode='w').write('1')\n",
                            "file write"),
                           ("an fd write", "        os.write(enforce_fd, b'0')\n", "file write"),
                           ("a pathlib write", "        pathlib.Path('/run/rhizo-x').write_text('1')\n", "file write"),
                           ("a pathlib open", "        pathlib.Path('/run/rhizo-x').open('w')\n", "file write")):
    planted = flip_src.replace(anchor, anchor + plant, 1) if anchor in flip_src else ""
    got = post_flip_effects({"selinux_ns": planted}) if planted else []
    if not any(kind == want for _o, kind, _l, _t in got):
        bad.append(("the post-flip scan finds " + label, want, got))



def done_pipe_after(result):
    """run run_relabeller with a result or a raise"""
    saved = (ns._relabel_after_load, ns.connect_label_service, ns.kmsg)
    out = []
    ns.kmsg = out.append
    ns.connect_label_service = lambda: None
    if isinstance(result, BaseException):
        def after(*a, **k):
            """raise after the flip"""
            raise result
        ns._relabel_after_load = after
    else:
        ns._relabel_after_load = lambda *a, **k: result
    r, w = os.pipe()
    try:
        code = ns.run_relabeller(newroot, staged, -1, lambda: None, w)
    finally:
        ns._relabel_after_load, ns.connect_label_service, ns.kmsg = saved
        os.close(w)
    data = os.read(r, 400)
    os.close(r)
    return data, out, code


for label, result, want_bytes, want_code in (
        ("enforced", ns.DONE_ENFORCED, b"1", 0), ("permissive", ns.DONE_PERMISSIVE, b"p", 0),
        ("failed with no reason", ns.DONE_FAILED, b"f", 1),
        ("failed with a reason", ns.failed("enforce-failed:err=OSError(22)"), b"fenforce-failed:err=OSError_22_\n", 1),
        ("raised after the flip", RuntimeError("boom after"), b"fraised:RuntimeError_'boom_after'_\n", 1)):
    data, out, code = done_pipe_after(result)
    want_bytes = want_bytes.replace(b"'", b"_")
    if data != want_bytes or out or code != want_code:
        bad.append((f"run_relabeller {label}", (want_bytes, [], want_code), (data, out, code)))

import socket
a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
b.close()
a.close()
logs.clear()
saved_kmsg = ns.kmsg
ns.kmsg = logs.append
try:
    ns._send_label_error(a, "setns:1")
finally:
    ns.kmsg = saved_kmsg
if logs:
    bad.append(("label error on a dead socket", [], list(logs)))

got = run(["u:r:init:s0"], raising=None, eopnotsupp=0, primer=False)
if (got != ns.DONE_ENFORCED or any(c[0] == "write-primer-script" for c in calls)
        or any("name=write-primer-script" in l for l in logs)):
    bad.append(("no primer writer", "enforced, no primer write, no pass-failed", got, list(calls), list(logs)))


class FakeSignal:
    """signal stand-in keeping the SIGALRM handler"""
    SIGALRM, ITIMER_REAL = signal.SIGALRM, signal.ITIMER_REAL
    handler = None
    fire_on_disarm = False

    @staticmethod
    def signal(sig, handler):
        """install handler and return the one before"""
        old, FakeSignal.handler = FakeSignal.handler, handler
        return old

    @staticmethod
    def setitimer(which, seconds):
        """fire the installed handler at the disarm when asked"""
        if seconds == 0 and FakeSignal.fire_on_disarm and callable(FakeSignal.handler):
            FakeSignal.handler(signal.SIGALRM, None)


class FiringLogs(list):
    """kmsg lines that fire the handler on the passes-cut line"""

    def append(self, line):
        """keep line and fire the handler after a passes-cut line"""
        super().append(line)
        if "selinuxns=passes-cut" in line and callable(FakeSignal.handler):
            FakeSignal.handler(signal.SIGALRM, None)


def cut_now(*a):
    """fire the installed handler from inside the passes"""
    FakeSignal.handler(signal.SIGALRM, None)


plain_logs = logs
for label, passes_fn, fire_on_disarm, want_cut in (
        ("the timer fires at the disarm after every pass ran", lambda *a: None, True, False),
        ("the timer fires again inside the passes-cut handler", cut_now, False, True)):
    saved_timer = (ns.signal, ns._run_passes)
    FakeSignal.handler, FakeSignal.fire_on_disarm = None, fire_on_disarm
    ns.signal, ns._run_passes, logs = FakeSignal, passes_fn, FiringLogs()
    try:
        got = run(["u:r:init:s0"], raising=None, eopnotsupp=0)
    except BaseException as e:
        got = repr(e)
    finally:
        ns.signal, ns._run_passes = saved_timer
        cut_logs, logs = list(logs), plain_logs
    cut = "passes-cut" in [l.split("selinuxns=", 1)[-1].split()[0] for l in cut_logs]
    if got != ns.DONE_ENFORCED or cut != want_cut:
        bad.append(("late passes timer", label, ns.DONE_ENFORCED, want_cut, got, cut_logs))

def fd_open(fd):
    """return whether fd is open"""
    try:
        os.fstat(fd)
        return True
    except OSError:
        return False


for ctx, want_code, want_done, want_ran in (
        ("kernel", 0, b"", [("/nonexistent-newroot", ["spec"], 7, None)]),
        ("u:r:kernel:s0", 0, b"", [("/nonexistent-newroot", ["spec"], 7, None)]),
        ("u:r:init:s0", 1, b"frelabeller-verb-domain\n", []),
        ("system_u:system_r:initrc_t:s0", 1, b"frelabeller-verb-domain\n", []),
        ("system_u:system_r:unconfined_t:s0", 1, b"frelabeller-verb-domain\n", [])):
    ran, marks = [], []
    saved_verb = (ns.run_relabeller, ns.kmsg)
    ns.run_relabeller = lambda newroot, staged, mntns_fd, writer, done_fd: ran.append((newroot, staged, mntns_fd,
                                                                                        writer)) or 0
    ns.kmsg = marks.append
    dr, dw = os.pipe()
    try:
        verb = getattr(ns, "run_handoff_relabeller", None)
        code = ("absent" if verb is None
                else verb("/nonexistent-newroot", ["spec"], 7, dw, 4242, attr_reader=lambda: ctx,
                          namespace_is_host=lambda dev: False))
    finally:
        ns.run_relabeller, ns.kmsg = saved_verb
        os.close(dw)
    done = os.read(dr, 400)
    os.close(dr)
    refused = any("reason=relabeller-verb-domain" in m and repr(ctx) in m for m in marks)
    if (code, done, ran, refused) != (want_code, want_done, want_ran, want_code == 1):
        bad.append(("relabeller verb entry", ctx, (want_code, want_done, want_ran), (code, done, ran, marks)))

def host_namespace_unknown(dev):
    """raise what a failed selinuxfs mount raises"""
    raise OSError(1, "fsmount selinuxfs: Operation not permitted")


for label, ctx, is_host, want_code, want_done in (
        ("Android's namespace", "u:r:kernel:s0", lambda dev: False, 0, b""),
        ("the host's namespace", "u:r:kernel:s0", lambda dev: True, 1, b"frelabeller-verb-host-namespace\n"),
        ("an unprovable namespace", "u:r:kernel:s0", host_namespace_unknown, 1,
         b"frelabeller-verb-namespace-unknown\n"),
        ("the host's namespace with no policy", "kernel", lambda dev: True, 1, b"frelabeller-verb-host-namespace\n"),
        ("Android's namespace before its policy load", "kernel", lambda dev: False, 0, b"")):
    ran, marks = [], []
    saved_verb = (ns.run_relabeller, ns.kmsg)
    ns.run_relabeller = lambda newroot, staged, mntns_fd, writer, done_fd: ran.append(newroot) or 0
    ns.kmsg = marks.append
    dr, dw = os.pipe()
    try:
        code = ns.run_handoff_relabeller("/nonexistent-newroot", ["spec"], 7, dw, 4242, attr_reader=lambda: ctx,
                                         namespace_is_host=is_host)
    except TypeError as e:
        code = f"no namespace test: {e}"
    finally:
        ns.run_relabeller, ns.kmsg = saved_verb
        os.close(dw)
    done = os.read(dr, 400)
    os.close(dr)
    if (code, done, bool(ran)) != (want_code, want_done, want_code == 0):
        bad.append(("relabeller verb namespace", label, (want_code, want_done), (code, done, ran, marks)))

SYSFS_MAGIC = 0x62656572


def no_mount_table(*a, **k):
    """fail a read of the mount table or a mount"""
    raise AssertionError(f"the namespace proof read a path or mounted: {a!r}")


def namespace_proof(host_dev, own_dev, own_fails=False, verb_ctx=None):
    """run the namespace proof over stand-in mounts"""
    own_fds = []

    def own_mount():
        """open a stand-in for this namespace's detached selinuxfs"""
        if own_fails:
            raise OSError(1, "fsmount selinuxfs: Operation not permitted")
        own_fds.append(os.open("/dev/null", os.O_RDONLY))
        return own_fds[-1]

    real_fstat = os.fstat

    def fstat(fd):
        """return a stand-in stat carrying each mount's device"""
        if fd in own_fds:
            return os.stat_result((0, 0, own_dev, 0, 0, 0, 0, 0, 0, 0))
        return real_fstat(fd)

    saved = (ns.fs_type, ns.mount, ns.fd_fs_type, ns.selinuxfs_mount_fd, os.fstat, os.stat, ns.run_relabeller, ns.kmsg)
    ns.fs_type, ns.mount, os.stat = (lambda p: SYSFS_MAGIC), no_mount_table, no_mount_table
    ns.fd_fs_type = no_mount_table
    ns.selinuxfs_mount_fd, os.fstat = own_mount, fstat
    ran, marks = [], []
    ns.run_relabeller = lambda newroot, staged, mntns_fd, writer, done_fd: ran.append(newroot) or 0
    ns.kmsg = marks.append
    verb = None
    dr, dw = os.pipe()
    try:
        if verb_ctx is None:
            answer = ns.namespace_is_host(host_dev)
        else:
            answer = None
            verb = ns.run_handoff_relabeller("/nonexistent-newroot", ["spec"], 7, dw, host_dev,
                                             attr_reader=lambda: verb_ctx)
    except Exception as e:
        answer = "OSError" if isinstance(e, OSError) else repr(e)
    finally:
        (ns.fs_type, ns.mount, ns.fd_fs_type, ns.selinuxfs_mount_fd, os.fstat, os.stat, ns.run_relabeller,
         ns.kmsg) = saved
        os.close(dw)
    done = os.read(dr, 400)
    os.close(dr)
    left = [fd for fd in own_fds if fd_open(fd)]
    for fd in left:
        os.close(fd)
    return answer, left, (verb, done, bool(ran)) if verb_ctx is not None else None


for label, host_dev, own_dev, own_fails, want in (
        ("the host's instance", 22, 22, False, True),
        ("its own instance", 22, 49, False, False),
        ("no host device number", -1, 49, False, "OSError"),
        ("a host device number that is not a number", "22", 22, False, "OSError"),
        ("an own mount that fails", 22, 49, True, "OSError")):
    got, left, _ = namespace_proof(host_dev, own_dev, own_fails)
    if got != want or left:
        bad.append(("namespace_is_host with no host selinuxfs mounted", label, want, got, "own fds left open", left))

def open_fds():
    """return this process's open fds below 256"""
    return {fd for fd in range(256) if fd_open(fd)}


def host_selinuxfs_branch(path_kind, mount_fails=False):
    """open the host selinuxfs over a stand-in path"""
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "selinux")
        if path_kind != "missing":
            os.mkdir(path)
        mounts = []

        def detached():
            """open a stand-in detached selinuxfs mount"""
            if mount_fails:
                raise OSError(1, "fsmount selinuxfs: Operation not permitted")
            mounts.append(os.open("/dev/null", os.O_RDONLY))
            return mounts[-1]

        saved = (ns.fd_fs_type, ns.selinuxfs_mount_fd)
        ns.fd_fs_type = lambda fd: ns.SELINUX_MAGIC if path_kind == "selinuxfs" else SYSFS_MAGIC
        ns.selinuxfs_mount_fd = detached
        before = open_fds()
        try:
            fd = ns.open_host_selinuxfs(path)
            branch = ("mounted" if os.readlink(f"/proc/self/fd/{fd}") == path
                      else "detached" if fd in mounts else f"fd {fd}")
        except OSError:
            fd, branch = None, "OSError"
        finally:
            ns.fd_fs_type, ns.selinuxfs_mount_fd = saved
        leaked = open_fds() - before - ({fd} if fd is not None else set())
        if fd is not None:
            os.close(fd)
        return branch, len(mounts), sorted(leaked)


for label, path_kind, mount_fails, want in (
        ("a policy host with selinuxfs mounted", "selinuxfs", False, ("mounted", 0, [])),
        ("a host whose /sys/fs/selinux is an empty sysfs dir", "sysfs", False, ("detached", 1, [])),
        ("a host with no /sys/fs/selinux", "missing", False, ("detached", 1, [])),
        ("a detached mount that fails", "sysfs", True, ("OSError", 0, []))):
    got = host_selinuxfs_branch(path_kind, mount_fails)
    if got != want:
        bad.append(("open_host_selinuxfs", label, want, got))

for ctx in ns.RELABELLER_CONTEXTS:
    for label, host_dev, want in (
            ("Android's namespace", 22, (0, b"", True)),
            ("the host's namespace", 49, (1, b"frelabeller-verb-host-namespace\n", False))):
        _, left, got = namespace_proof(host_dev, 49, verb_ctx=ctx)
        if got != want or left:
            bad.append(("handoff relabeller with no host selinuxfs mounted", ctx, label, want, got, left))

tmp.cleanup()
if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
