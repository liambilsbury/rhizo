#!/usr/bin/env python3
import ast
import contextlib
import io
import json
import os
import sys

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-init-readproc-group")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    import boot as launcher

INIT = "/system/bin/init"
EXECS = ("os.execv", "os.execve", "os.execvp", "os.execvpe")


def init_exec_sites():
    """return each init exec site"""
    sites = []
    for name in sorted(os.listdir(LAUNCHER)):
        if not name.endswith(".py"):
            continue
        tree = ast.parse(open(os.path.join(LAUNCHER, name)).read())
        for fn in ast.walk(tree):
            if not isinstance(fn, ast.FunctionDef):
                continue
            for call in ast.walk(fn):
                if isinstance(call, ast.Call) and ast.unparse(call.func) in EXECS and call.args \
                        and INIT in ast.unparse(call.args[0]):
                    sites.append((name, fn, call))
    return sites


def static_failures():
    """return the init exec sites missing the group"""
    bad = []
    sites = init_exec_sites()
    if not sites:
        bad.append("no exec of /system/bin/init found in src/androidd")
    for name, fn, call in sites:
        lines = [ast.unparse(s) for s in fn.body]
        text = "\n".join(lines)
        at_exec = text.find(ast.unparse(call))
        groups = text.find("os.setgroups([AID_READPROC])")
        caps = text.find("drop_caps()")
        if not 0 <= groups < caps < at_exec:
            bad.append(f"{name}:{fn.name}: the init exec at line {call.lineno} is not preceded by "
                       "os.setgroups([AID_READPROC]) before drop_caps()")
    if getattr(launcher, "AID_READPROC", None) != 3009:
        bad.append(f"AID_READPROC is {getattr(launcher, 'AID_READPROC', None)!r}, not 3009")
    return bad


def run_enter(setgroups_fails, mode="host", policy_loaded=False):
    """run enter_sandbox_init in a fork"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)

        def note(*event):
            """send an event to the parent"""
            os.write(w, (json.dumps(event) + "\n").encode())

        def setgroups(groups):
            """record the groups or fail them"""
            note("setgroups", list(groups))
            if setgroups_fails:
                raise PermissionError(1, "Operation not permitted")

        def execv(path, argv):
            """record the exec and end the fork"""
            note("execv", path, argv)
            os._exit(0)

        os.environ["RHIZO_SELINUX_MODE"] = mode
        launcher.policy_is_loaded = lambda: policy_loaded
        launcher.selinux_ns.state = lambda: {"unshared": mode == "namespace"}
        launcher.selinux_ns.host_context = lambda: "kernel"
        launcher.selinux_ns.join_landlock_domain = lambda: None
        launcher.cap_pid_namespace_pid_max = lambda: True
        launcher.install_handle_filter = lambda *a, **k: True
        launcher.drop_caps = lambda: note("drop_caps")
        launcher.phase = lambda *a: None
        launcher.kmsg = lambda m: note("kmsg", m)
        launcher.core.uinput_filtered = lambda: False
        launcher.core.input_supervisor = lambda: None
        os.setgroups, os.execv = setgroups, execv
        try:
            launcher.enter_sandbox_init("selinux_setup", own_proc_sys=False)
        except BaseException as e:
            note("raised", repr(e))
        os._exit(3)
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


def behavior_failures():
    """return the exec order findings"""
    bad = []
    want = [["setgroups", [3009]], ["drop_caps"], ["execv", INIT, [INIT, "selinux_setup"]]]
    for label, mode, loaded in (("a namespace-mode init", "namespace", False),
                                ("a host-mode init before the policy load", "host", False)):
        code, events = run_enter(False, mode, loaded)
        if code != 0 or [e for e in events if e[0] != "kmsg"] != want:
            bad.append(f"{label}: want {want} and exit 0; got {code}, {events}")
    code, events = run_enter(False, "host", True)
    if code != 0 or [e[0] for e in events if e[0] != "kmsg"] != ["drop_caps", "execv"] \
            or not any(e[0] == "kmsg" and "init_groups=skipped reason=host-policy-loaded" in e[1] for e in events):
        bad.append(f"a host-mode init under a loaded policy: want the skip named and the exec; got {code}, {events}")
    code, events = run_enter(True)
    names = [e[0] for e in events]
    if code != 1 or "execv" in names or "drop_caps" in names \
            or not any(e[0] == "kmsg" and "selinuxns=refused reason=init-groups" in e[1] for e in events):
        bad.append(f"a failed setgroups: want exit 1, no exec and the refusal named; got {code}, {events}")
    return bad


def main():
    """return the failures"""
    return static_failures() + behavior_failures()


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("init-readproc-group:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
