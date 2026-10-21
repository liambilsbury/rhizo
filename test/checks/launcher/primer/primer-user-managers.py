#!/usr/bin/env python3
"""check the host primer's user-manager pass and its flip refusal"""
import ast
import glob
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(ROOT, "src", "androidd", "boot.py")
PRIMER_RE = re.compile(r'HOST_PRIMER_SRC = r"""(.*?)\n"""', re.S)
LIFTED = ("_user_managers_still_kernel", "_systemd_version", "_user_manager_answers",
          "_reexec_user_managers", "_clear_user_managers", "_write_state", "_refuse_flip",
          "_pid_domain", "_session_class", "_kernel_logins", "_logins_refusing_flip")
REEXEC = int(signal.SIGRTMIN + 25)

FIXTURE = {
    201: ("user-1000.slice/user@1000.service/init.scope", "(sd-pam)", "kernel", None, None),
    200: ("user-1000.slice/user@1000.service/init.scope", "systemd", "kernel", True, True),
    211: ("user-0.slice/user@0.service/init.scope", "(sd-pam)", "u:r:kernel:s0", None, None),
    210: ("user-0.slice/user@0.service/init.scope", "systemd", "u:r:kernel:s0", True, True),
    220: ("user-1001.slice/user@1001.service/init.scope", "systemd", "u:r:rhizo_host:s0", None, True),
    230: ("user-1002.slice/user@1002.service", "systemd", "kernel", True, True),
    240: ("user-1000.slice/session-3.scope", "sway", "kernel", None, None),
    250: ("user-1003.slice/user@1003.service/init.scope", "systemd", "kernel", False, False),
    260: ("user-1004.slice/user@1004.service/init.scope", "systemd", "kernel", True, False),
    270: ("user-1001.slice/session-4.scope", "bash", "u:r:rhizo_host:s0", None, None),
    280: ("user-0.slice/session-c5.scope", "cron", "kernel", None, None),
    290: ("user-1005.slice/session-6.scope", "sshd", "u:r:kernel:s0", None, None),
}
CLASSES = {"3": "user", "4": "user", "c5": "background", "6": ""}
KERNEL_LOGINS = ["session 3 (uid 1000)", "session 6 (uid 1005)"]
STUCK = {"user@0.service": "210", "user@1000.service": "200", "user@1002.service": "230",
         "user@1003.service": "250", "user@1004.service": "260"}
LEFT = {"user@1003.service": "250", "user@1004.service": "260"}


class _Clock:
    """a time module whose sleep only advances its clock"""

    def __init__(self):
        """start the fake clock at 0"""
        self.now = 0.0

    def time(self):
        """return the fake clock"""
        return self.now

    def sleep(self, s):
        """advance the fake clock"""
        self.now += s


class _Os:
    """the real os with a recording kill"""

    def __init__(self, proc):
        """keep the fixture proc root and an empty kill record"""
        self.proc = proc
        self.kills = []

    def __getattr__(self, name):
        """return the real os attribute"""
        return getattr(os, name)

    def kill(self, pid, sig):
        """record a signal and re-exec the fixture manager it names"""
        self.kills.append((int(pid), int(sig)))
        row = FIXTURE.get(int(pid))
        if int(sig) == REEXEC and row and row[3]:
            with open(os.path.join(self.proc, str(pid), "attr", "current"), "w") as f:
                f.write("u:r:rhizo_host:s0\0")


class _Run:
    """a subprocess module answering systemctl from fixed text"""

    TimeoutExpired = subprocess.TimeoutExpired

    def __init__(self, version="systemd 255 (255.4-1ubuntu8.16)\n+PAM\n", answer=None, raise_=None):
        """keep the version text, the state answer and an exception to raise"""
        self.version, self.answer, self.raise_, self.argvs = version, answer, raise_, []

    def run(self, argv, **_kw):
        """record argv and answer it"""
        self.argvs.append(list(argv))
        if self.raise_ is not None:
            raise self.raise_
        out = self.version if "--version" in argv else (self.answer or "")
        return type("R", (), {"stdout": out, "returncode": 0})()


class _Pwd:
    """a pwd module naming uid 0 root and every other uid u<uid>"""

    @staticmethod
    def getpwuid(uid):
        """return a passwd entry for the uid"""
        return type("P", (), {"pw_name": "root" if uid == 0 else "u%d" % uid})()


def build_fixture(root):
    """write the fixture user.slice and proc trees"""
    cg, proc = os.path.join(root, "user.slice"), os.path.join(root, "proc")
    for pid, (rel, comm, ctx, _flips, _answers) in FIXTURE.items():
        d = os.path.join(cg, rel)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "cgroup.procs"), "a") as f:
            f.write("%d\n" % pid)
        os.makedirs(os.path.join(proc, str(pid), "attr"))
        with open(os.path.join(proc, str(pid), "comm"), "w") as f:
            f.write(comm + "\n")
        with open(os.path.join(proc, str(pid), "attr", "current"), "w") as f:
            f.write(ctx + "\0")
    return cg, proc


def flip_write(n):
    """match open("/sys/fs/selinux/enforce", "w").write(...)"""
    return (isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr == "write"
            and isinstance(n.func.value, ast.Call) and ast.unparse(n.func.value.func) == "open"
            and [ast.unparse(a) for a in n.func.value.args] == ["'/sys/fs/selinux/enforce'", "'w'"])


def calls(stmt, name):
    """return whether a statement calls a plain name"""
    return any(isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == name
               for n in ast.walk(stmt))


def structure(body):
    """check where the pass, the refusal and the verdict sit in the primer"""
    fails = []
    restart = next((i for i, s in enumerate(body) if isinstance(s, ast.Expr) and calls(s, "_restart_pass")), None)
    early = next((i for i, s in enumerate(body) if calls(s, "_clear_user_managers")), None)
    flip = next((i for i, s in enumerate(body) if any(flip_write(n) for n in ast.walk(s))), None)
    gate = next((i for i, s in enumerate(body) if any(isinstance(n, ast.Assign)
                 and ast.unparse(n.targets[0]) == "_already_enforcing" for n in ast.walk(s))), None)
    verdict = next((i for i, s in enumerate(body) if isinstance(s, ast.Assign)
                    and ast.unparse(s.targets[0]) == "_post_restart_stuck"), None)
    if None in (restart, flip, gate, verdict):
        return ["the primer has no _restart_pass() call, _already_enforcing read, _post_restart_stuck "
                "verdict or enforce write"]
    if early is None or early > restart:
        fails.append("the user-manager pass does not run before _restart_pass()")
    elif not any(isinstance(s, ast.If) and calls(s, "_refuse_flip") for s in body[early:restart]):
        fails.append("the early user-manager pass never refuses the flip on what it leaves")
    if not gate < verdict < flip:
        fails.append("the verdict is not taken after the boot-marker wait and right before the flip")
    flip_if = body[flip]
    pre = []
    if isinstance(flip_if, ast.If):
        writes = next((k for k, s in enumerate(flip_if.body) if any(flip_write(n) for n in ast.walk(s))), None)
        pre = flip_if.body[:writes] if writes is not None else []
    if not (any(calls(s, "_clear_user_managers") for s in pre) and any(calls(s, "_refuse_flip") for s in pre)):
        fails.append("the flip does not re-run the user-manager pass and refuse on what it leaves right "
                     "before it writes enforce")
    if not any(calls(s, "_logins_refusing_flip") for s in pre):
        fails.append("the flip does not refuse while a login session still runs in `kernel` right before it "
                     "writes enforce")
    if not any(calls(s, "_logins_refusing_flip") for s in body[:restart]):
        fails.append("no login-session refusal runs before _restart_pass()")
    return fails


def run_clear(ns, cg, proc, enforce="0", run=None, answering=None):
    """run _clear_user_managers on the fixture and return (fake os, left)"""
    fake = _Os(proc)
    run = run or _Run()
    rns = dict(ns, os=fake, time=_Clock(), subprocess=run, _enforce_value=lambda: enforce)
    rns["_user_managers_still_kernel"] = lambda: ns["_user_managers_still_kernel"](cg, proc)
    rns["_user_manager_answers"] = answering or (lambda u: FIXTURE[int(STUCK.get(u, "220"))][4])
    for name in ("_reexec_user_managers", "_clear_user_managers", "_systemd_version"):
        exec(compile(ast.unparse(ast.Module(body=[ns["_defs"][name]], type_ignores=[])),
                     "<primer>", "exec"), rns)
    return fake, rns["_clear_user_managers"]()


def run_refuse(ns, root, no_sandbox, init_pid):
    """run _refuse_flip on the fixture"""
    fake = _Os(root)
    rec, marker = os.path.join(root, "refused"), os.path.join(root, "flipped")
    rns = dict(ns, os=fake, _NO_SANDBOX=no_sandbox, _init_pid=init_pid, _enforce_value=lambda: "0",
               _POLICY_REFUSED=rec, _FLIP_MARKER=marker)
    for name in ("_write_state", "_refuse_flip"):
        exec(compile(ast.unparse(ast.Module(body=[ns["_defs"][name]], type_ignores=[])),
                     "<primer>", "exec"), rns)
    exited = False
    try:
        rns["_refuse_flip"](dict(LEFT))
    except SystemExit:
        exited = True
    read = lambda p: open(p).read() if os.path.exists(p) else ""
    return fake, exited, read(rec), read(marker)


def check(launcher_text):
    """check the primer's user-manager pass and its flip refusal"""
    m = PRIMER_RE.search(launcher_text)
    if not m:
        return ["src/androidd/boot.py has no HOST_PRIMER_SRC string"]
    body = ast.parse(m.group(1)).body
    defs = {n.name: n for n in body if isinstance(n, ast.FunctionDef)}
    missing = [n for n in LIFTED if n not in defs]
    if missing:
        return ["HOST_PRIMER_SRC no longer defines %s" % ", ".join(missing)]
    fails = structure(body)
    ns = {"glob": glob, "os": os, "re": re, "signal": signal, "sys": sys, "pwd": _Pwd,
          "log": lambda _m: None, "_defs": defs}
    exec(compile(ast.unparse(ast.Module(body=[defs["_user_managers_still_kernel"]], type_ignores=[])),
                 "<primer>", "exec"), ns)
    for text, want in (("systemd 255 (255.4-1ubuntu8.16)\n+PAM\n", 255), ("systemd 249 (249.11)\n", 249),
                       ("", 0)):
        vns = dict(ns, subprocess=_Run(version=text))
        exec(compile(ast.unparse(ast.Module(body=[defs["_systemd_version"]], type_ignores=[])),
                     "<primer>", "exec"), vns)
        if vns["_systemd_version"]() != want:
            fails.append("_systemd_version read %r as %r, want %r" % (text, vns["_systemd_version"](), want))
    for answer, raise_, want in (("running\n", None, True), ("degraded\n", None, True),
                                 ("starting\n", None, False), ("", subprocess.TimeoutExpired("x", 5), False)):
        run = _Run(answer=answer, raise_=raise_)
        ans = dict(ns, subprocess=run)
        exec(compile(ast.unparse(ast.Module(body=[defs["_user_manager_answers"]], type_ignores=[])),
                     "<primer>", "exec"), ans)
        got = ans["_user_manager_answers"]("user@0.service")
        if got != want:
            fails.append("_user_manager_answers read %r as %r, want %r" % (answer, got, want))
        argv = run.argvs[-1] if run.argvs else []
        if not (argv[:3] == ["runuser", "-u", "root"] and "XDG_RUNTIME_DIR=/run/user/0" in argv
                and argv[-3:] == ["systemctl", "--user", "is-system-running"]):
            fails.append("_user_manager_answers asked %s, not the manager's own state as its user" % argv)
    root = tempfile.mkdtemp(prefix="check-primer-user-managers.")
    try:
        cg, proc = build_fixture(root)
        got = ns["_user_managers_still_kernel"](cg, proc)
        if got != STUCK:
            fails.append("the scan found %s, want %s" % (sorted(got.items()), sorted(STUCK.items())))
        fake, left = run_clear(ns, cg, proc)
        want = {(int(p), REEXEC) for p in STUCK.values()}
        if set(fake.kills) != want:
            fails.append("the pass sent %s, want %s" % (sorted(fake.kills), sorted(want)))
        if left != LEFT:
            fails.append("the pass left %s, want %s" % (left, LEFT))
    finally:
        shutil.rmtree(root, ignore_errors=True)
    for enforce, version, why in (("1", "systemd 255 (255.4)\n", "a re-exec under enforcement is denied its memfd and exec"),
                                  ("0", "systemd 249 (249.11)\n", "systemd 249 kills a user manager on SIGRTMIN+25")):
        root = tempfile.mkdtemp(prefix="check-primer-user-managers.")
        try:
            cg, proc = build_fixture(root)
            fake, left = run_clear(ns, cg, proc, enforce=enforce, run=_Run(version=version))
            if fake.kills:
                fails.append("with enforce=%s and %s the pass sent %s -- %s"
                             % (enforce, version.split(" (")[0], sorted(fake.kills), why))
            if left != STUCK:
                fails.append("with enforce=%s and %s the pass left %s, want every manager still `kernel`"
                             % (enforce, version.split(" (")[0], left))
        finally:
            shutil.rmtree(root, ignore_errors=True)
    for out, raise_, want in (("user\n", None, "user"), ("", None, ""), ("", OSError("x"), "")):
        run = _Run(answer=out, raise_=raise_)
        cns = dict(ns, subprocess=run)
        exec(compile(ast.unparse(ast.Module(body=[defs["_session_class"]], type_ignores=[])), "<primer>", "exec"), cns)
        if cns["_session_class"]("3") != want:
            fails.append("_session_class read %r as %r, want %r" % (out, cns["_session_class"]("3"), want))
        if run.argvs and run.argvs[-1] != ["loginctl", "show-session", "3", "-p", "Class", "--value"]:
            fails.append("_session_class asked %s" % run.argvs[-1])
    root = tempfile.mkdtemp(prefix="check-primer-user-managers.")
    try:
        cg, proc = build_fixture(root)
        lns = dict(ns, _session_class=lambda sid: CLASSES.get(sid, ""))
        for name in ("_pid_domain", "_kernel_logins", "_logins_refusing_flip"):
            exec(compile(ast.unparse(ast.Module(body=[defs[name]], type_ignores=[])), "<primer>", "exec"), lns)
        got = lns["_kernel_logins"](cg, proc)
        if got != KERNEL_LOGINS:
            fails.append("_kernel_logins chose %s, want %s (a rhizo_host session and a background one left "
                         "out, an unknown class counted)" % (got, KERNEL_LOGINS))
        lns["_kernel_logins"] = lambda: KERNEL_LOGINS
        saved = os.environ.pop("RHIZO_RIG_LOAD_UNDER_LOGIN", None)
        try:
            if lns["_logins_refusing_flip"]() != KERNEL_LOGINS:
                fails.append("_logins_refusing_flip let kernel login sessions through without the rig override")
            os.environ["RHIZO_RIG_LOAD_UNDER_LOGIN"] = "1"
            if lns["_logins_refusing_flip"]() != []:
                fails.append("_logins_refusing_flip ignored the rig override")
        finally:
            os.environ.pop("RHIZO_RIG_LOAD_UNDER_LOGIN", None)
            if saved is not None:
                os.environ["RHIZO_RIG_LOAD_UNDER_LOGIN"] = saved
    finally:
        shutil.rmtree(root, ignore_errors=True)
    for no_sandbox, init_pid in ((False, 4242), (True, None)):
        root = tempfile.mkdtemp(prefix="check-primer-user-managers.")
        try:
            fake, exited, rec, marker = run_refuse(ns, root, no_sandbox, init_pid)
            if not exited:
                fails.append("_refuse_flip returned")
            if "reason=" not in rec or "user@1003.service" not in rec or "reboot" not in rec:
                fails.append("_refuse_flip's record names no unit or no reboot: %r" % rec)
            if not no_sandbox and (4242, int(signal.SIGKILL)) not in fake.kills:
                fails.append("_refuse_flip left the sandbox running on an unenforced host (kills %s)" % fake.kills)
            if no_sandbox and ("enforce=0" not in marker or "user@1004.service" not in marker):
                fails.append("_refuse_flip's --no-sandbox marker does not fail the policy unit: %r" % marker)
        finally:
            shutil.rmtree(root, ignore_errors=True)
    return fails


def selftest():
    """plant defects in the real primer and require each to be flagged"""
    fail = 0
    with open(LAUNCHER, encoding="utf-8") as fh:
        real = fh.read()
    got = check(real)
    if got:
        print("SELFTEST FAILED: the real primer was flagged: %s" % got)
        fail = 1
    cases = [
        ("(sd-pam) taken for the manager", 'if f.read().strip() != "systemd":',
         'if f.read().strip() == "never":', "the scan found"),
        ("a manager with no init.scope missed", 'for sub in ("init.scope", ""):',
         'for sub in ("init.scope",):', "user@1002.service"),
        ("SIGTERM instead of the re-exec signal", "signal.SIGRTMIN + 25", "signal.SIGTERM",
         "the pass sent"),
        ("only the bare initial SID matched", 'if domain in ("kernel", "u:r:kernel:s0"):',
         'if domain == "kernel":', "user@0.service"),
        ("the systemd version gate dropped", "if version < 250:", "if version < 0:", "systemd 249"),
        ("the pass run under enforcement", '    if _enforce_value() != "0":\n', "    if False:\n",
         "a re-exec under enforcement"),
        ("the readiness wait dropped", "if u in kernel or not _user_manager_answers(u)}",
         "if u in kernel}", "the pass left"),
        ("the manager's own state not asked", '"is-system-running"', '"show"', "not the manager's own state"),
        ("the sandbox left running", "            os.kill(_init_pid, signal.SIGKILL)\n",
         "            pass\n", "left the sandbox running"),
        ("the refusal falls through to the flip", "    sys.exit(1)\n", "    return\n", "_refuse_flip returned"),
        ("the rig override ignored at the flip", '    if os.environ.get("RHIZO_RIG_LOAD_UNDER_LOGIN") == "1":\n        return []\n',
         "    if False:\n        return []\n", "ignored the rig override"),
        ("a rhizo_host session counted", '        if not any(_pid_domain(p, proc) in ("kernel", "u:r:kernel:s0") for p in pids):\n',
         "        if False:\n", "_kernel_logins chose"),
        ("a background session counted at the flip", 'if _session_class(sid) in ("background", ',
         'if _session_class(sid) in ("nothing", ', "_kernel_logins chose"),
        ("the pre-flip login refusal dropped",
         "    _logins_left = _logins_refusing_flip()\n    if _logins_left:\n        _refuse_flip(_logins_left)\n    try:\n",
         "    try:\n", "while a login session still runs"),
        ("the pre-flip pass dropped", "    _user_managers_left = _clear_user_managers()\n    if _user_managers_left:\n        _refuse_flip(_user_managers_left)\n    _logins_left",
         "    _logins_left", "right before it writes enforce"),
    ]
    for name, old, new, needle in cases:
        if old not in real:
            print("SELFTEST FAILED: %s: the planted defect no longer matches its source -- %r is gone"
                  % (name, old[:60]))
            fail = 1
            continue
        problems = check(real.replace(old, new, 1))
        if not any(needle in p for p in problems):
            print("SELFTEST FAILED: %s was not flagged with %r (got %s)" % (name, needle, problems))
            fail = 1
    if not check("nothing relevant here at all\n"):
        print("SELFTEST FAILED: a file with no primer was not flagged")
        fail = 1
    print("primer-user-managers.py selftest: %s (%d planted defects)"
          % ("FAILED" if fail else "ok", len(cases)))
    return fail


def main(argv):
    """run the check or its selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: primer-user-managers.py [--selftest]", file=sys.stderr)
        return 2
    with open(LAUNCHER, encoding="utf-8") as fh:
        fails = check(fh.read())
    for f in fails:
        print("primer-user-managers: " + f, file=sys.stderr)
    if fails:
        return 1
    print("primer-user-managers: across %d fixture processes the primer re-executes exactly the %d user "
          "managers still `kernel` before the restart pass, waits until each answers, signals none under "
          "enforcement or on systemd 249, and refuses the flip (sandbox stopped, unit failed) while one stays"
          % (len(FIXTURE), len(STUCK)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
