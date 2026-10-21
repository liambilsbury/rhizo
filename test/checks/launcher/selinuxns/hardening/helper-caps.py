#!/usr/bin/env python3
import ast
import contextlib
import io
import os
import subprocess
import sys

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-helper-caps")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from sandbox import core

ANDROID_HELPERS = {
    ("sandbox/selinux_ns.py", "start_relabeller"): "drop_to_init_caps()",
    ("sandbox/selinux_ns.py", "start_handoff_relabeller"): "drop_to_init_caps()",
    ("sandbox/rootfs.py", "prelabel_vendor_tree"): "drop_to_init_caps()",
    ("sandbox/rootfs.py", "cap_pid_namespace_pid_max"): "drop_to_init_caps()",
}
DROPS_ALL = {("sandbox/selinux_ns.py", "start_label_service"): "_serve_labels"}
ELSEWHERE = {
    ("sandbox/selinux_ns.py", "start_view_keeper"): (1, "the handoff holder's pid namespace"),
    ("boot.py", "_join_and_exec_init"): (1, "pid 1 itself, which becomes init through enter_sandbox_init"),
    ("boot.py", "run_sandbox"): (3, "g in the supervisor's, gg as pid 1 or the holder, NCM in the holder's"),
    ("boot.py", "run_kernel_domain_supervisor"): (1, "a joiner in the host pid namespace"),
    ("boot.py", "main"): (1, "the supervisor in the host pid namespace"),
    ("boot.py", "policy_only_verb"): (1, "the supervisor in the host pid namespace"),
    ("boot.py", "arm_host_lock_releaser"): (2, "the host lock releaser in the host pid namespace"),
    ("boot.py", "arm_after_flip_jobs"): (2, "the after-flip jobs in the host pid namespace"),
    ("boot.py", "_in_policy_namespace"): (1, "prepare-tree's staging child on the host"),
    ("sandbox/core.py", "route_stdio_through_pipe"): (1, "a log pump on the host with its capabilities cleared"),
}
SPAWN_MODULES = ("sandbox/selinux_ns.py", "sandbox/selinux_labels.py")
SPAWN_CALLS = ("subprocess.run", "subprocess.Popen", "subprocess.check_output", "subprocess.check_call",
               "subprocess.call", "os.execv", "os.execve", "os.execvp", "os.execvpe", "os.system", "os.posix_spawn",
               "run")
SPAWNS = {
    ("sandbox/selinux_ns.py", "stage_gsi_labeled"): (2, "the host: prepare-tree's GSI staging"),
    ("sandbox/selinux_ns.py", "start_handoff_relabeller"): (1, "Android's: the verb, after drop_to_init_caps"),
    ("sandbox/selinux_labels.py", "read_sessions"): (3, "the host: the login-session read before a policy load"),
    ("sandbox/selinux_labels.py", "check_policy_load"): (1, "the host: host mode's policy load check"),
    ("sandbox/selinux_labels.py", "relabel_flat_trees_now"): (1, "Android's: the relabeller's primer run, with its dropped set"),
}
FIRST_STEPS = ("libc.unshare(", "libc.setns(", "os.execve(", "unshare(CLONE_NEWNS)", "enter_policy_namespace(",
               "run_relabeller(", "mount(")


def fork_sites():
    """return each function's fork count"""
    sites = {}
    for name in sorted(os.listdir(LAUNCHER)):
        if not name.endswith(".py"):
            continue
        tree = ast.parse(open(os.path.join(LAUNCHER, name)).read())

        def visit(node, fn):
            """record each fork under its outermost function"""
            for child in ast.iter_child_nodes(node):
                inner = child.name if isinstance(child, ast.FunctionDef) and fn is None else fn
                if isinstance(child, ast.Call) and ast.unparse(child.func) == "os.fork" and fn is not None:
                    sites[(name, fn)] = sites.get((name, fn), 0) + 1
                visit(child, inner)
        visit(tree, None)
    return sites


def function_source(module, name):
    """return a top-level function's source"""
    tree = ast.parse(open(os.path.join(LAUNCHER, module)).read())
    return next((ast.unparse(n) for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == name), "")


def spawn_sites():
    """return each function's process spawn count"""
    sites = {}
    for name in SPAWN_MODULES:
        tree = ast.parse(open(os.path.join(LAUNCHER, name)).read())
        for fn in tree.body:
            if isinstance(fn, ast.FunctionDef):
                n = sum(1 for c in ast.walk(fn) if isinstance(c, ast.Call) and ast.unparse(c.func) in SPAWN_CALLS)
                if n:
                    sites[(name, fn.name)] = n
    return sites


def static_failures():
    """return each unclassified fork or undropped helper"""
    bad = []
    want = {**{k: 1 for k in ANDROID_HELPERS}, **{k: 1 for k in DROPS_ALL},
            **{k: n for k, (n, _) in ELSEWHERE.items()}}
    for site, count in sorted(fork_sites().items()):
        if site not in want:
            bad.append(f"{site[0]}:{site[1]} forks a child no table here classifies")
        elif count != want[site]:
            bad.append(f"{site[0]}:{site[1]} forks {count} children, {want[site]} classified: classify the new one")
    for site, count in sorted(spawn_sites().items()):
        if site not in SPAWNS:
            bad.append(f"{site[0]}:{site[1]} spawns a process no table here classifies")
        elif count != SPAWNS[site][0]:
            bad.append(f"{site[0]}:{site[1]} spawns {count} processes, {SPAWNS[site][0]} classified")
    for (module, name), drop in ANDROID_HELPERS.items():
        src = function_source(module, name)
        at_drop = src.find(drop)
        steps = [i for i in (src.find(s) for s in FIRST_STEPS) if i >= 0]
        if at_drop < 0 or (steps and min(steps) < at_drop):
            bad.append(f"{module}:{name} forks into Android's pid namespace without {drop} before its first "
                       "namespace or exec step")
    for (module, name), server in DROPS_ALL.items():
        if "_drop_privileges(" not in function_source(module, server):
            bad.append(f"{module}:{server} no longer drops every capability for {name}")
    return bad


PROBE = r"""
import contextlib, io, os, sys
sys.path.insert(0, sys.argv[1])
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-helper-caps")
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
    from sandbox import selinux_ns
why = selinux_ns.drop_to_init_caps()
caps = {l.split(":")[0]: l.split()[1] for l in open("/proc/self/status") if l.startswith("Cap")}
print("DROP", why or "ok", caps["CapInh"], caps["CapPrm"], caps["CapEff"], caps["CapBnd"], caps["CapAmb"])
"""


def behavior_failures():
    """return the user-namespace run's findings"""
    probe = subprocess.run(["unshare", "-r", "true"], capture_output=True, text=True, timeout=30)
    if probe.returncode != 0:
        NOT_RUN.append(f"the user-namespace run -- unshare -r refused: {probe.stderr.strip() or probe.returncode}")
        return []
    r = subprocess.run(["unshare", "-r", sys.executable, "-c", PROBE, LAUNCHER], capture_output=True, text=True,
                       timeout=60)
    lines = [l.split() for l in r.stdout.splitlines() if l.startswith("DROP ")]
    if r.returncode != 0 or len(lines) != 1:
        return [f"the user-namespace run did not report: rc={r.returncode} {(r.stdout + r.stderr)[-400:]!r}"]
    why, inh, prm, eff, bnd, amb = lines[0][1:]
    if why != "ok":
        return [f"drop_to_init_caps failed: {why}"]
    dropped = sum(1 << c for c in core.DROP_CAPS)
    full = int(prm, 16) | dropped
    init_set = full & ~dropped
    bad = []
    for label, value in (("inheritable", inh), ("permitted", prm), ("effective", eff), ("bounding", bnd),
                         ("ambient", amb)):
        if int(value, 16) & ~init_set:
            bad.append(f"after drop_to_init_caps the {label} set {value} holds a capability init lacks")
    for cap, cap_name in ((0, "CHOWN"), (3, "FOWNER"), (21, "SYS_ADMIN"), (33, "MAC_ADMIN")):
        if not int(eff, 16) >> cap & 1:
            bad.append(f"after drop_to_init_caps the effective set {eff} lost CAP_{cap_name}, which init keeps")
    return bad


NOT_RUN = []


def main():
    """return the failures"""
    return static_failures() + behavior_failures()


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    for why in NOT_RUN:
        print(f"NOT RUN: {why}")
    print("helper-caps:", "FAIL" if out else "ok (the user-namespace run NOT RUN)" if NOT_RUN else "ok")
    sys.exit(1 if out else 0)
