#!/usr/bin/env python3
import ast
import contextlib
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")))

import boot as launcher3  # noqa: E402
from sandbox import hostlock  # noqa: E402

PRIMER_RE = re.compile(r'HOST_PRIMER_SRC = r"""(.*?)\n"""', re.S)


class Host:
    """temp stand-ins for launcher3 host calls"""

    def __init__(self, tmp, selinux=True, own="kernel", pid1="u:r:rhizo_host:s0", enforce="1",
                 supervisor=True, state=None, extra_env=None):
        """set up a fake host with the given SELinux, policy and supervisor state"""
        self.tmp = tmp
        self.extra_env = {"RHIZO_SELINUX_MODE": "host", **(extra_env or {})}
        self.reexec_env = None
        self.enforce = os.path.join(tmp, "enforce")
        if selinux:
            with open(self.enforce, "w") as f:
                f.write(enforce + "\n")
        self.pid1 = os.path.join(tmp, "pid1")
        with open(self.pid1, "w") as f:
            f.write(pid1 + "\0")
        self.state = os.path.join(tmp, "rhizo-policy-loaded")
        if state is not None:
            with open(self.state, "w") as f:
                f.write(state)
        self.own, self.supervisor = own, supervisor
        self.calls, self.log = [], []
        self.caller_at_fork = None

    def _fork(self):
        """record the caller unit and fail as if a supervisor were forked"""
        self.caller_at_fork = os.environ.get("RHIZO_CALLER_UNIT")
        raise AssertionError("forked a supervisor")

    def __enter__(self):
        """replace the launcher3 host calls with stand-ins"""
        self.saved = {k: getattr(launcher3, k) for k in (
            "SELINUX_ENFORCE_NODE", "PID1_ATTR", "POLICY_LOADED_STATE", "kmsg", "own_domain",
            "policy_is_loaded", "recorded_g_alive", "RHIZO_PERMISSIVE", "HANDOFF_DIR",
            "arm_host_lock_releaser", "own_service_unit")}
        self.saved_lock = (hostlock.HOST_LOCK_FILE, hostlock.acquire_host_lock)
        self.env = dict(os.environ)
        for k in ("RHIZO_CALLER_UNIT", "RHIZO_REEXECED"):
            os.environ.pop(k, None)
        os.environ.update(self.extra_env)
        launcher3.own_service_unit = lambda: "rhizo-policy.service"
        self.geteuid, self.fork, self.execv = os.geteuid, os.fork, os.execv
        launcher3.SELINUX_ENFORCE_NODE = self.enforce
        launcher3.PID1_ATTR = self.pid1
        launcher3.POLICY_LOADED_STATE = self.state
        launcher3.kmsg = self.log.append
        launcher3.RHIZO_PERMISSIVE = False
        launcher3.HANDOFF_DIR = os.path.join(self.tmp, "handoff")
        launcher3.own_domain = lambda: self.calls.append("own_domain") or self.own
        launcher3.policy_is_loaded = lambda: ":" in self.own
        launcher3.arm_host_lock_releaser = lambda fd: self.calls.append("releaser")
        launcher3.recorded_g_alive = lambda: self.supervisor
        hostlock.HOST_LOCK_FILE = os.path.join(self.tmp, "host.lock")
        real_acquire = self.saved_lock[1]
        hostlock.acquire_host_lock = lambda: self.calls.append("acquire") or real_acquire()
        os.geteuid = lambda: 0
        os.fork = self._fork
        os.execv = self._execv
        return self

    def _execv(self, path, argv):
        """record the re-exec environment and fail as if the launcher re-executed"""
        self.reexec_env = os.environ.get("RHIZO_REEXECED")
        raise AssertionError("re-exec'd")

    def __exit__(self, *exc):
        """restore the replaced launcher and os functions and the environment"""
        for k, v in self.saved.items():
            setattr(launcher3, k, v)
        hostlock.HOST_LOCK_FILE, hostlock.acquire_host_lock = self.saved_lock
        os.geteuid, os.fork, os.execv = self.geteuid, self.fork, self.execv
        os.environ.clear()
        os.environ.update(self.env)
        return False

    def said(self, needle):
        """return whether a log message contains the needle"""
        return any(needle in m for m in self.log)


@contextlib.contextmanager
def refused_creates(directory):
    """fail write-mode opens in a directory"""
    refused = []

    def denying_open(path, mode="r", *a, **kw):
        """refuse writes into the directory and open everything else"""
        if os.path.dirname(os.path.abspath(path)) == directory and set(mode) & set("wax+"):
            refused.append(path)
            raise PermissionError(13, "Permission denied", path)
        return open(path, mode, *a, **kw)
    launcher3.open = denying_open
    try:
        yield refused
    finally:
        del launcher3.open


@contextlib.contextmanager
def refused_devnull():
    """fail the opens of /dev/null"""
    refused = []
    real = subprocess.Popen._get_devnull

    def denying_devnull(self):
        """refuse the null device"""
        refused.append(os.devnull)
        raise PermissionError(13, "Permission denied", os.devnull)
    subprocess.Popen._get_devnull = denying_devnull
    try:
        yield refused
    finally:
        subprocess.Popen._get_devnull = real


def run_verb(host):
    """run the policy-only verb on a fake host"""
    with host:
        try:
            return launcher3.policy_only_verb()
        except AssertionError as e:
            return "raised: %s" % e


def selftest():
    """test the policy-only verb on temp fixtures"""
    fails = []

    def want(name, cond, detail=""):
        """record a failure unless the condition holds"""
        if not cond:
            fails.append(name + (": " + detail if detail else ""))

    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, own="u:r:rhizo_host:s0", extra_env={"RHIZO_SELINUX_MODE": "namespace"})
        rc = run_verb(h)
        want("namespace mode exits 0", rc == 0, "rc=%r" % rc)
        want("namespace mode says it skipped", h.said("RHIZO_MARKER selinuxns=policy-only-skipped"), str(h.log))
        want("namespace mode loads nothing and takes no lock", not h.calls and not os.path.exists(h.state),
             str(h.calls))

    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, selinux=False, own="unconfined")
        rc = run_verb(h)
        want("no selinuxfs exits 0", rc == 0, "rc=%r log=%s" % (rc, h.log))
        want("no selinuxfs says why", h.said("SELinux is not the active LSM"), str(h.log))
        want("no selinuxfs reads no context and takes no lock", not h.calls, str(h.calls))

    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, selinux=True, own="unconfined")
        rc = run_verb(h)
        want("an unexpected context under SELinux still fails", rc == 1, "rc=%r" % rc)
        want("the unexpected context is named", h.said("unexpected own context 'unconfined'"),
             str(h.log))

    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, own="u:r:rhizo_host:s0")
        rc = run_verb(h)
        want("an earlier start's load exits 0", rc == 0, "rc=%r log=%s" % (rc, h.log))
        want("an earlier start's load waits out the host lock", "acquire" in h.calls, str(h.calls))
        body = open(h.state).read() if os.path.exists(h.state) else ""
        want("an earlier start's load is recorded as that", "loaded_by=first-androidd-start" in body,
             body)
        want("an earlier start's load claims no digest", "\nsha256=\n" in body, body)

    with tempfile.TemporaryDirectory() as tmp:
        record = "loaded_at=T\nloaded_by=rhizo-policy.service\nsha256=abc\n"
        h = Host(tmp, own="u:r:rhizo_host:s0", state=record)
        rc = run_verb(h)
        want("a restart of the unit later in the boot exits 0", rc == 0, "rc=%r" % rc)
        want("a restart keeps the load's own record", open(h.state).read() == record,
             open(h.state).read())

    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, own="u:r:kernel:s0")
        rc = run_verb(h)
        want("a still-kernel launcher with a policy loaded re-execs before anything else",
             rc == "raised: re-exec'd" and h.reexec_env == "1", "rc=%r env=%r" % (rc, h.reexec_env))
        want("the re-exec happens before any record is written", not os.path.exists(h.state))
    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, own="u:r:rhizo_host:s0", extra_env={"RHIZO_REEXECED": "1"})
        rc = run_verb(h)
        want("the re-exec'd launcher verifies and records", rc == 0 and os.path.exists(h.state),
             "rc=%r log=%s" % (rc, h.log))

    for name, kw, needle in (
            ("pid 1 still kernel", dict(pid1="u:r:kernel:s0"), "pid 1 is 'u:r:kernel:s0'"),
            ("enforce still 0", dict(enforce="0"), "enforce is '0'")):
        with tempfile.TemporaryDirectory() as tmp:
            h = Host(tmp, own="u:r:rhizo_host:s0", **kw)
            with h:
                rc = launcher3._verify_earlier_load(deadline_s=0.2, poll_s=0.05)
            want("%s fails the verification" % name, rc == 1, "rc=%r" % rc)
            want("%s is named" % name, h.said(needle), str(h.log))
            want("%s writes no record" % name, not os.path.exists(h.state))

    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, own="u:r:rhizo_host:s0", supervisor=False)
        with h:
            rc = launcher3._verify_earlier_load(deadline_s=0.2, poll_s=0.05)
        want("no supervisor is reported, not failed", rc == 0 and h.said("supervisor none"),
             "rc=%r log=%s" % (rc, h.log))

    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, own="u:r:kernel:s0")
        with h, refused_creates(tmp) as refused, refused_devnull() as devnull:
            ok = launcher3._write_policy_loaded_state("ab" * 32, 676384)
        body = open(h.state).read() if os.path.exists(h.state) else ""
        want("a kernel-domain supervisor records its load though it may not create in /run itself",
             ok and "loaded_by=rhizo-policy.service\n" in body and "sha256=" + "ab" * 32 + "\n" in body
             and "bytes=676384\n" in body, "ok=%r body=%r log=%s" % (ok, body, h.log))
        want("the kernel-domain write is not attempted in-process", not refused, repr(refused))
        want("the kernel-domain writer's stdio opens no /dev/null", not devnull, repr(devnull))
        want("the record's pid is the supervisor's", "pid=%d\n" % os.getpid() in body, body)
        want("no temp file is left beside the record", sorted(os.listdir(tmp)).count(
            ".rhizo-policy-loaded.tmp") == 0, str(os.listdir(tmp)))
    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, own="u:r:rhizo_host:s0")
        with h, refused_creates(tmp) as refused:
            ok = launcher3._write_policy_loaded_state(None, None, loaded_by="first-androidd-start")
        want("a rhizo_host writer writes the record itself, in-process", not ok and refused,
             "ok=%r refused=%r" % (ok, refused))
        want("a refused in-process write is named", h.said("could not be written"), str(h.log))

    with tempfile.TemporaryDirectory() as tmp:
        h = Host(tmp, own="kernel")
        rc = run_verb(h)
        want("the true first actor forks its supervisor", rc == "raised: forked a supervisor",
             "rc=%r" % rc)
        want("the true first actor exports its unit for the primer before the fork",
             h.caller_at_fork == "rhizo-policy.service", repr(h.caller_at_fork))

    want("a pass that loaded nothing exits unparked", not launcher3.policy_only_must_park(False, False))
    want("a failed verdict after the load still parks", launcher3.policy_only_must_park(False, True))
    want("a good pass parks", launcher3.policy_only_must_park(True, True))

    src = open(launcher3.__file__).read()
    fn = next(n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef)
              and n.name == "run_kernel_domain_supervisor")
    exits = [n for n in ast.walk(fn) if isinstance(n, ast.If)
             and "policy_only_must_park" in ast.unparse(n.test)
             and any("os._exit(1)" in ast.unparse(s) for s in n.orelse)]
    want("run_kernel_domain_supervisor() exits unparked only past policy_only_must_park()",
         len(exits) == 1, "%d such branches" % len(exits))

    with tempfile.TemporaryDirectory() as tmp:
        for body, unit in (("0::/system.slice/rhizo-policy.service\n", "rhizo-policy.service"),
                           ("0::/system.slice/androidd.service/android/launcher\n", "androidd.service"),
                           ("0::/user.slice/user-1000.slice/session-3.scope\n", ""),
                           ("1:name=systemd:/x.service\n0::/init.scope\n", "")):
            p = os.path.join(tmp, "cgroup")
            with open(p, "w") as f:
                f.write(body)
            got = launcher3.own_service_unit(p)
            want("own_service_unit(%r)" % body.strip(), got == unit, "got %r want %r" % (got, unit))

    m = PRIMER_RE.search(src)
    assign = next((n for n in ast.parse(m.group(1)).body if isinstance(n, ast.Assign)
                   and any(isinstance(t, ast.Name) and t.id == "_CALLER_UNIT" for t in n.targets)),
                  None) if m else None
    want("the primer defines _CALLER_UNIT", assign is not None)
    if assign is not None:
        code = compile(ast.unparse(ast.Module(body=[assign], type_ignores=[])), "<caller>", "exec")
        for argv, unit in ((["p", "--run-root", "/r", "--caller-unit", "rhizo-policy.service"],
                            "rhizo-policy.service"),
                           (["p", "--run-root", "/r"], ""),
                           (["p", "--caller-unit"], "")):
            ns = {"sys": type("S", (), {"argv": argv})}
            exec(code, ns)
            want("_CALLER_UNIT from %r" % argv, ns["_CALLER_UNIT"] == unit, repr(ns["_CALLER_UNIT"]))
    spawn = next(n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef)
                 and n.name == "spawn_host_primer")
    want("spawn_host_primer() passes RHIZO_CALLER_UNIT as --caller-unit",
         '"--caller-unit", os.environ["RHIZO_CALLER_UNIT"]' in ast.unparse(spawn).replace("'", '"'))

    for f in fails:
        print("SELFTEST FAILED: " + f)
    print("policy-only.py selftest: " + ("FAILED" if fails else "ok"))
    return 1 if fails else 0


def main(argv):
    """run the selftest"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    print("usage: policy-only.py --selftest", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
