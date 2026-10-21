#!/usr/bin/env python3
import contextlib
import io
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
PR_SET_NO_NEW_PRIVS = 38
GATE_REFUSAL = "post-pivot import of "


class ImportGate:
    """import gate for sys.meta_path"""

    def __init__(self):
        """start with the gate open and no refused imports"""
        self.closed = False
        self.attempts = []

    def find_spec(self, name, path=None, target=None):
        """refuse and record any import made while the gate is closed"""
        if not self.closed:
            return None
        self.attempts.append(name)
        raise ModuleNotFoundError(f"{GATE_REFUSAL}{name!r}", name=name)

    @contextlib.contextmanager
    def shut(self):
        """close the gate for a block and yield the modules loaded before it"""
        loaded = set(sys.modules)
        self.closed = True
        try:
            yield loaded
        finally:
            self.closed = False


class Execed(BaseException):
    """exception for an intercepted os.execv"""

    def __init__(self, path, argv):
        """keep the path and arguments of the exec"""
        super().__init__(path)
        self.path, self.argv = path, list(argv)


def fake_supervisor(answer):
    """return a socketpair end and forked pid"""
    mine, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    pid = os.fork()
    if pid == 0:
        mine.close()
        try:
            _, fds, _, _ = socket.recv_fds(theirs, 64, 4)
            for fd in fds:
                os.close(fd)
            theirs.send(answer)
        finally:
            os._exit(0)
    theirs.close()
    return mine, pid


def no_new_privs(env):
    """set PR_SET_NO_NEW_PRIVS on the process"""
    if env.libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        raise OSError("prctl(PR_SET_NO_NEW_PRIVS) failed")


def case_fprog(mods, gate):
    """return the result of packing a socket filter program"""
    with gate.shut() as loaded:
        ref = mods.rootfs.struct_pack_fprog(3, 0)
    return loaded, ("a struct sock_fprog reference" if ref is not None else "None")


def filter_case(answer, want):
    """return a uinput filter case for a fake supervisor answer"""
    def run(mods, gate):
        """install the uinput filter with the gate closed"""
        sup, pid = fake_supervisor(answer) if answer is not None else (None, None)
        no_new_privs(mods.core)
        with gate.shut() as loaded:
            mode = mods.rootfs.install_uinput_filter(sup, log=lambda m: None)
        if pid:
            os.waitpid(pid, 0)
        return loaded, (f"mode {mode!r}" if mode == want else f"mode {mode!r}, not {want!r}")
    return run


def case_handle_filter(mods, gate):
    """install the open_by_handle_at filter with the gate closed"""
    no_new_privs(mods.core)
    with gate.shut() as loaded:
        ok = mods.rootfs.install_handle_filter(log=lambda m: None)
    return loaded, ("installed" if ok else "not installed")


class LandlockLibc:
    """libc stand-in for Landlock syscalls"""

    def __init__(self, real, ns):
        """keep the real libc and the namespace module"""
        self.real, self.ns, self.restricted = real, ns, False

    def syscall(self, nr, *args):
        """return Rhizo kernel results for Landlock syscalls"""
        number = getattr(nr, "value", nr)
        if number == self.ns.NR_LANDLOCK_CREATE_RULESET:
            return self.ns.LANDLOCK_MIN_ABI if args[0] is None else os.open(os.devnull, os.O_RDONLY)
        if number == self.ns.NR_LANDLOCK_RESTRICT_SELF:
            self.restricted = True
            return 0
        return self.real.syscall(nr, *args)


def unshared_stand_in(ns):
    """set up the unshared SELinux namespace stand-ins"""
    ns.state()["unshared"] = True
    real_context = ns.host_context

    def host_context():
        """read the real context and return kernel"""
        real_context()
        return "kernel"
    ns.host_context = host_context
    ns._libc = LandlockLibc(ns._libc, ns)
    return ns._libc


def init_case(own_proc_sys, mode):
    """return a case that runs the init step against a fake supervisor"""
    def run(mods, gate):
        """run the init step with the gate closed"""
        sup, pid = fake_supervisor(b"ok")
        mods.core.set_uinput_filtered(True)
        mods.core.set_input_supervisor(sup)
        no_new_privs(mods.core)
        os.environ["RHIZO_SELINUX_MODE"] = mode
        landlock = unshared_stand_in(mods.selinux_ns) if mode == "namespace" else None
        mods.launcher3.cap_pid_namespace_pid_max = lambda: True

        def execv(path, argv):
            """raise an error carrying the exec path and arguments"""
            raise Execed(path, argv)
        os.execv = execv
        os.setgroups = lambda groups: None
        got = None
        with gate.shut() as loaded:
            try:
                mods.launcher3.enter_sandbox_init("selinux_setup", own_proc_sys=own_proc_sys)
            except Execed as e:
                got = (e.path, e.argv)
        os.waitpid(pid, 0)
        want = ("/system/bin/init", ["/system/bin/init", "selinux_setup"])
        if got != want:
            return loaded, f"exec {got!r}, not {want!r}"
        if landlock is not None and not landlock.restricted:
            return loaded, "exec of init outside a Landlock domain"
        return loaded, "exec of init"
    return run


def case_handoff(mods, gate):
    """run hand_off_to_supervisor on a temp directory"""
    d = tempfile.mkdtemp()
    try:
        dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
        fd = os.open(".0.tmp", os.O_WRONLY | os.O_CREAT, 0o600, dir_fd=dfd)
        signal.signal(signal.SIGUSR1, signal.SIG_IGN)
        with gate.shut() as loaded:
            ok = mods.launcher3.hand_off_to_supervisor(os.getpid(), fd, dfd, ".0.tmp", 4242,
                                                       "second_stage", 0)
        entry = os.path.join(d, "0")
        content = open(entry, "rb").read() if os.path.exists(entry) else None
    finally:
        for name in os.listdir(d):
            os.unlink(os.path.join(d, name))
        os.rmdir(d)
    want = mods.launcher3.handoff_wire_format(4242, "second_stage")
    return loaded, ("entry published" if ok and content == want else f"returned {ok}, entry {content!r}")


def case_cgroups(mods, gate):
    """return the result of describing the sandbox cgroups"""
    with gate.shut() as loaded:
        mods.launcher3.describe_sandbox_cgroups()
    return loaded, "described"


CASES = [
    ("struct_pack_fprog", case_fprog),
    ("install_uinput_filter, the supervisor takes the listener", filter_case(b"ok", "listening")),
    ("install_uinput_filter, the supervisor refuses it", filter_case(b"no", "refusing")),
    ("install_uinput_filter, no supervisor", filter_case(None, "refusing")),
    ("install_handle_filter", case_handle_filter),
    ("enter_sandbox_init, host mode, first boot (it mounts net.core itself)", init_case(True, "host")),
    ("enter_sandbox_init, host mode, the handoff joiner", init_case(False, "host")),
    ("enter_sandbox_init, namespace mode, first boot (it mounts net.core itself)", init_case(True, "namespace")),
    ("enter_sandbox_init, namespace mode, the handoff joiner's init child", init_case(False, "namespace")),
    ("hand_off_to_supervisor", case_handoff),
    ("describe_sandbox_cgroups", case_cgroups),
]


def import_launcher():
    """import launcher3 and its modules"""
    os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-post-pivot-imports")
    sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))
    with contextlib.redirect_stdout(io.StringIO()):
        import boot as launcher3
        from sandbox import core
        from sandbox import rootfs
        from sandbox import selinux_ns

    class Mods:
        pass
    mods = Mods()
    mods.launcher3, mods.core, mods.rootfs = launcher3, core, rootfs
    mods.selinux_ns = selinux_ns
    core.swap_kmsg_fd(os.open(os.devnull, os.O_WRONLY))
    return mods


def run_cases(cases, report):
    """run each case in a forked process"""
    mods = import_launcher()
    gate = ImportGate()
    sys.meta_path.insert(0, gate)
    for name, fn in cases:
        before = set(sys.modules)
        pid = os.fork()
        if pid == 0:
            line = {"case": name}
            try:
                loaded, outcome = fn(mods, gate)
                line["fixture_loaded"] = sorted(loaded - before)
                line["outcome"] = outcome
            except BaseException as e:
                line["error"] = f"{type(e).__name__}: {e}"
            line["imports"] = gate.attempts
            os.write(report, (json.dumps(line) + "\n").encode())
            os._exit(0)
        _, status = os.waitpid(pid, 0)
        if status != 0:
            os.write(report, (json.dumps({"case": name, "died": status}) + "\n").encode())


PASSING = {
    "struct_pack_fprog": "a struct sock_fprog reference",
    "install_uinput_filter, the supervisor takes the listener": "mode 'listening'",
    "install_uinput_filter, the supervisor refuses it": "mode 'refusing'",
    "install_uinput_filter, no supervisor": "mode 'refusing'",
    "install_handle_filter": "installed",
    "enter_sandbox_init, host mode, first boot (it mounts net.core itself)": "exec of init",
    "enter_sandbox_init, host mode, the handoff joiner": "exec of init",
    "enter_sandbox_init, namespace mode, first boot (it mounts net.core itself)": "exec of init",
    "enter_sandbox_init, namespace mode, the handoff joiner's init child": "exec of init",
    "hand_off_to_supervisor": "entry published",
    "describe_sandbox_cgroups": "described",
}


def findings(lines, passing):
    """list the defects in a child report"""
    bad, seen = [], []
    for line in lines:
        name = line["case"]
        seen.append(name)
        if "died" in line:
            bad.append(f"{name}: the case's process died, wait status {line['died']}")
            continue
        if line["imports"]:
            bad.append(f"{name}: imported {', '.join(line['imports'])} after the gate closed")
        if line.get("fixture_loaded"):
            bad.append(f"{name}: its fixture loaded {', '.join(line['fixture_loaded'])} first")
        if "error" in line:
            if not line["error"].startswith(f"ModuleNotFoundError: {GATE_REFUSAL}"):
                bad.append(f"{name}: raised {line['error']}")
        elif line.get("outcome") != passing[name]:
            bad.append(f"{name}: {line.get('outcome')}, not {passing[name]}")
    return bad, seen


def check(python, child_args=()):
    """run the child interpreter and return findings"""
    with tempfile.NamedTemporaryFile("r") as rep:
        proc = subprocess.run([python, os.path.abspath(__file__), "--child", rep.name, *child_args],
                              capture_output=True, text=True, timeout=300)
        lines = [json.loads(x) for x in rep.read().splitlines() if x.strip()]
    if proc.returncode != 0 or not lines:
        sys.stderr.write(proc.stdout + proc.stderr)
        return None
    return findings(lines, {**PASSING, **SELFTEST_PASSING})


def case_lazy_import(mods, gate):
    """import colorsys with ImportGate closed"""
    with gate.shut() as loaded:
        __import__("colorsys")
    return loaded, "imported"


def case_swallowed_import(mods, gate):
    """import colorsys and catch ImportError"""
    with gate.shut() as loaded:
        try:
            __import__("colorsys")
        except ImportError:
            pass
    return loaded, "imported"


def case_fixture_loads(mods, gate):
    """import colorsys outside ImportGate"""
    __import__("colorsys")
    with gate.shut() as loaded:
        pass
    return loaded, "imported"


def case_clean(mods, gate):
    """return the modules loaded by a case that loads nothing"""
    with gate.shut() as loaded:
        os.getpid()
    return loaded, "imported"


def case_wrong_outcome(mods, gate):
    """return the modules loaded by a case with an unexpected outcome"""
    with gate.shut() as loaded:
        pass
    return loaded, "something else"


def case_dies(mods, gate):
    """exit the case process at once"""
    os._exit(3)


SELFTEST_CASES = [
    ("selftest: a lazy import", case_lazy_import),
    ("selftest: an import inside try/except ImportError", case_swallowed_import),
    ("selftest: a fixture that loads the module first", case_fixture_loads),
    ("selftest: no import", case_clean),
    ("selftest: the wrong outcome", case_wrong_outcome),
    ("selftest: a case process that dies", case_dies),
]
SELFTEST_PASSING = {name: "imported" for name, _ in SELFTEST_CASES}


def selftest():
    """check the cases against the failures they must report"""
    got = check(sys.executable, ["--selftest-cases"])
    if got is None:
        print("check-post-pivot-imports selftest: the child printed no report")
        return 2
    bad, seen = got
    want = [
        "selftest: a lazy import: imported colorsys after the gate closed",
        "selftest: an import inside try/except ImportError: imported colorsys after the gate closed",
        "selftest: a fixture that loads the module first: its fixture loaded colorsys first",
        "selftest: the wrong outcome: something else, not imported",
        "selftest: a case process that dies: the case's process died, wait status 768",
    ]
    fails = [f"missing finding: {w}" for w in want if w not in bad]
    fails += [f"unexpected finding: {b}" for b in bad if b not in want]
    fails += [f"case not run: {n}" for n, _ in SELFTEST_CASES if n not in seen]
    for f in fails:
        print(f"FAIL {f}")
    if fails:
        return 1
    print(f"check-post-pivot-imports selftest: ok ({len(want)} findings named, the clean case passed)")
    return 0


def main(argv):
    """run the cases in a child or run the check"""
    if argv[:1] == ["--child"]:
        report = os.open(argv[1], os.O_WRONLY | os.O_APPEND)
        run_cases(SELFTEST_CASES if argv[2:] == ["--selftest-cases"] else CASES, report)
        return 0
    if os.geteuid() == 0:
        print("check-post-pivot-imports: refusing to run as root")
        return 2
    if argv == ["--selftest"]:
        return selftest()
    pythons, args = [], list(argv)
    while args:
        if args[0] == "--python" and len(args) > 1:
            pythons.append(args[1])
            args = args[2:]
        else:
            print(f"usage: post-pivot-imports.py [--python PATH]... [--selftest] (got {args[0]!r})")
            return 2
    rc = 0
    for python in pythons or [sys.executable]:
        version = subprocess.run([python, "-c", "import sys; print(sys.version.split()[0])"],
                                 capture_output=True, text=True).stdout.strip()
        got = check(python)
        if got is None:
            print(f"check-post-pivot-imports: {python} ({version or '?'}) printed no report")
            return 2
        bad, seen = got
        missing = [n for n, _ in CASES if n not in seen]
        for b in bad + [f"case not run: {n}" for n in missing]:
            print(f"FAIL [{version}] {b}")
            rc = 1
        if not bad and not missing:
            print(f"check-post-pivot-imports: ok under {python} {version}: {len(CASES)} post-pivot "
                  "cases reached their outcomes and imported nothing")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
