#!/usr/bin/env python3
import os
import subprocess
import sys

LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
WANT = "u:object_r:rhizo_device_state_file:s0"

CHILD = r"""
import ast, errno, os, sys, tempfile
sys.path.insert(0, sys.argv[1])
case = sys.argv[2]
top = tempfile.mkdtemp()
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-device-state-readonly")
os.environ["RHIZO_STATE_DIR"] = top
device_state = {"namespace-override-outside": f"{top}/elsewhere/device-state", "host-override-name": f"{top}/vendor"}
os.environ["RHIZO_DEVICE_STATE_DIR"] = device_state.get(case, f"{top}/device-state")
from sandbox import core
from sandbox import rootfs
if not core.mount("tmpfs", top, "tmpfs", 0):
    sys.exit("tmpfs mount failed")
src, newroot = os.environ["RHIZO_DEVICE_STATE_DIR"], f"{top}/newroot"
dst = newroot + core.DEVICE_STATE_MOUNT
if case == "namespace-override-link":
    os.makedirs(f"{top}/target")
    os.symlink(f"{top}/target", src)
else:
    os.makedirs(src)
os.makedirs(dst)
mode = "host" if case.startswith("host") else "namespace"
rootfs.kmsg = lambda m: print("KMSG", m, flush=True)
rootfs.selinux_ns.selinux_mode = lambda: mode
rootfs.host_selinux_mode = lambda: mode == "host"
rootfs.core.stdio_to_null = lambda: None
rootfs.selinux_ns.drop_to_init_caps = lambda: ""
in_policy = {"ns": False}
real_set, real_get = os.setxattr, os.getxattr


def enter(policy, helper):
    '''fake the child namespace's policy load'''
    in_policy["ns"] = True
    if helper != "relabel":
        return f"wrong-helper:{helper}"
    return "policy-load:22" if case == "namespace-no-policy" else None


def host_set(path, name, value, *a, **k):
    '''reject a host-side Android label with EINVAL'''
    if name == "security.selinux" and value.startswith(b"u:") and not in_policy["ns"]:
        raise OSError(errno.EINVAL, os.strerror(errno.EINVAL))
    return real_set(path, name, value, *a, **k)


def host_get(path, name, *a, **k):
    '''read a host-side Android label as unlabeled_t'''
    value = real_get(path, name, *a, **k)
    if name == "security.selinux" and value.startswith(b"u:") and not in_policy["ns"]:
        return b"system_u:object_r:unlabeled_t:s0\0"
    return value


rootfs.selinux_ns.enter_policy_namespace = enter
if case == "namespace-host-policy":
    os.setxattr, os.getxattr = host_set, host_get
tree = ast.parse(open(os.path.join(sys.argv[1], "sandbox/rootfs.py")).read())
fns = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
scope = dict(vars(rootfs), NEWROOT=newroot, RUN_ROOT=newroot, phase=lambda layer, name: None)


def run_slice(fn, after, before):
    body = fns[fn].body
    start = next(i for i, s in enumerate(body) if after is None or after in ast.unparse(s)) + (after is not None)
    end = next(i for i, s in enumerate(body) if i >= start and ast.unparse(s).startswith(before))
    exec(compile(ast.Module(body=body[start:end], type_ignores=[]), "sandbox/rootfs.py", "exec"), scope)


rootfs.selinux_ns.host_policy_state = lambda: "enforcing" if case == "host-policy-unlabeled" else "none"
if case in ("namespace-label-fails", "host-label-fails") and not (core.mount(src, src, None, core.MS_BIND) and
        core.mount(None, src, None, core.MS_BIND | core.MS_REMOUNT | core.MS_RDONLY)):
    sys.exit("read-only source bind failed")
if case in ("host-labeled", "host-remount-fails"):
    os.setxattr(src, "security.selinux", sys.argv[3].encode() + b"\0")
run_slice("build_root_and_pivot", None, "unshare_root_namespace(")
if not core.mount(src, dst, None, core.MS_BIND):
    sys.exit("bind failed")
if case == "host-remount-fails":
    real_mount = rootfs.mount
    scope["mount"] = lambda s, t, f, flags, data=None: (False if flags & core.MS_REMOUNT
                                                       else real_mount(s, t, f, flags, data))
run_slice("_setup_cgroups_and_selinuxfs", "relabel_root_objects_now(", "if holder")
try:
    label = real_get(dst, "security.selinux").rstrip(b"\0").decode()
except OSError as e:
    label = f"unreadable:{e.strerror}"
opts = [l.split()[5] for l in open("/proc/self/mountinfo") if l.split()[4] == dst]
print("LABEL", label, flush=True)
print("OPTS", opts[-1] if opts else "none", flush=True)
"""


def run(case):
    """run the staging steps for a case in a user and mount namespace"""
    return subprocess.run(["unshare", "-Urm", sys.executable, "-I", "-c", CHILD, os.path.abspath(LAUNCHER), case, WANT],
                          capture_output=True, text=True, timeout=60)


def summary(r):
    """return a run's exit code and output tails"""
    return f"rc={r.returncode} {r.stdout.strip()[-300:]!r} {r.stderr.strip()[-200:]!r}"


def main():
    """return the failures"""
    probe = subprocess.run(["unshare", "-Urm", "true"], capture_output=True, text=True, timeout=30)
    if probe.returncode != 0:
        return [f"unshare -Urm is refused here ({probe.stderr.strip() or probe.returncode})"]
    bad = []
    for case in ("namespace", "namespace-host-policy", "host-labeled", "host-unlabeled"):
        r = run(case)
        if r.returncode != 0 or f"LABEL {WANT}" not in r.stdout or "OPTS ro" not in r.stdout:
            bad.append(f"{case} mode: want the bridge labeled {WANT} and read-only after staging; got {summary(r)}")
    for case, why in (("namespace-label-fails", "device-state-label-failed"), ("namespace-no-policy", "device-state-label-failed"),
                      ("host-label-fails", "device-state-label-failed"), ("host-policy-unlabeled", "device-state-label-failed"),
                      ("host-remount-fails", "device-state-ro-failed"), ("namespace-override-outside", "device-state-dir-refused"),
                      ("host-override-name", "device-state-dir-refused"), ("namespace-override-link", "device-state-dir-refused")):
        r = run(case)
        if r.returncode != 1 or f"reason={why}" not in r.stdout or "OPTS" in r.stdout:
            bad.append(f"{case}: want the start refused as {why}; got {summary(r)}")
    return bad


if __name__ == "__main__":
    out = main()
    for line in out:
        print("FAIL:", line)
    print("device-state-readonly:", "FAIL" if out else "ok")
    sys.exit(1 if out else 0)
