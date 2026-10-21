#!/usr/bin/env python3
import contextlib, ctypes, io, os, struct, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-selinuxfs-mount")
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import rootfs as m
    from sandbox import selinux_ns as ns

bad = []
tmp = tempfile.TemporaryDirectory()
m.NEWROOT = tmp.name
target = f"{tmp.name}/sys/fs/selinux"
os.makedirs(target)
open(f"{target}/enforce", "w").write("0")
ns.ANDROID_ENFORCE_FILE = f"{tmp.name}/run/rhizo-selinuxns/android-enforce"
calls, logs, exits, umounts = [], [], [], []


class Exited(Exception):
    """raised in place of os._exit"""


def fake_exit(code):
    """record the exit code and stop the call"""
    exits.append(code)
    raise Exited(code)


def run(mode, syscall_rc=0, mount_ok=True, umount_rc=-1, unshare=True):
    """call unshare_root_namespace and mount_sandbox_selinuxfs under stubs"""
    calls.clear(); logs.clear(); exits.clear(); umounts.clear()
    ns._STATE["unshared"] = False
    if os.path.exists(ns.ANDROID_ENFORCE_FILE):
        os.unlink(ns.ANDROID_ENFORCE_FILE)

    def fake_syscall(*a):
        """record the syscall and answer syscall_rc"""
        calls.append(("syscall", a[0].value, a[1].value, bytes(a[2].raw), a[3].value, a[4].value))
        if syscall_rc != 0:
            ctypes.set_errno(1)
        return syscall_rc

    def fake_mount(s, t, fs, fl, d=None):
        """record the mount and answer mount_ok"""
        calls.append(("mount", s, t, fs, fl))
        return mount_ok

    class FakeSyscallLib:
        """stand-in for the libc handle"""
        syscall = staticmethod(fake_syscall)

    class FakeLibc:
        """stand-in for core.libc"""
        umount2 = staticmethod(lambda t, f: (umounts.append((t, f)), umount_rc)[1])

    saved = (ns._libc, ns.mount, m.mount, ns.libc, ns.kmsg, m.kmsg, os._exit)
    ns._libc, ns.mount, m.mount, ns.libc = FakeSyscallLib, fake_mount, fake_mount, FakeLibc
    ns.kmsg = m.kmsg = logs.append
    os._exit = fake_exit
    try:
        if unshare:
            m.unshare_root_namespace(mode, False)
        m.mount_sandbox_selinuxfs(mode)
    except Exited:
        pass
    finally:
        ns._libc, ns.mount, m.mount, ns.libc, ns.kmsg, m.kmsg, os._exit = saved
    return list(calls)


ctx = struct.pack("<QQQQ", 101, 0, 32, 0)
want_mount = ("mount", "selinuxfs", target, "selinuxfs", 2 | 8)
got = run("namespace")
if got != [("syscall", 460, 106, ctx, 32, 0), want_mount] or exits:
    bad.append(("namespace calls", [("syscall", 460, 106, ctx, 32, 0), want_mount], got, exits))
if not ns.state()["unshared"]:
    bad.append(("namespace state", True, ns.state()))
if not any("selinuxns=unshared" == l.split("RHIZO_MARKER ", 1)[-1] for l in logs):
    bad.append(("unshare marker", "selinuxns=unshared", logs))
if not any("selinuxns=selinuxfs enforce=0" in l for l in logs):
    bad.append(("namespace marker", "selinuxns=selinuxfs enforce=0", logs))
if not os.path.exists(ns.ANDROID_ENFORCE_FILE) or open(ns.ANDROID_ENFORCE_FILE).read() != "0\n":
    bad.append(("android enforce state after the unshare", "0\n", os.path.exists(ns.ANDROID_ENFORCE_FILE)))
if umounts != [(target.encode(), 2)]:
    bad.append(("umount loop stops at the first failure", [(target.encode(), 2)], list(umounts)))

run("namespace", umount_rc=0)
if len(umounts) != 8 or any(u != (target.encode(), 2) for u in umounts) or exits:
    bad.append(("bounded umount loop", "8 x (target, MNT_DETACH)", list(umounts), exits))

os.unlink(f"{target}/enforce")
run("namespace")
if exits or not any("selinuxns=selinuxfs enforce=<" in l for l in logs):
    bad.append(("unreadable enforce", "marker with <err>, no exit", list(logs), exits))
open(f"{target}/enforce", "w").write("0")

got = run("host")
if got != [("mount", "/sys/fs/selinux", target, None, m.MS_BIND)] or exits or ns.state()["unshared"]:
    bad.append(("host calls", "bind only", got, exits))

got = run("refuse:kernel-has-no-landlock")
if got or exits != [1] or not any("selinuxns=refused-at-mount" in l for l in logs):
    bad.append(("refused mode", "no calls, exit 1, marker", got, exits, logs))

got = run("namespace", syscall_rc=-1)
if exits != [1] or any(c[0] == "mount" for c in got) or not any("selinuxns=unshare-failed" in l for l in logs):
    bad.append(("unshare failure", "exit 1, no mount, unshare-failed marker", got, exits, logs))
if os.path.exists(ns.ANDROID_ENFORCE_FILE):
    bad.append(("android enforce state after a failed unshare", "absent", "present"))

got = run("namespace", unshare=False)
if got or exits != [1] or not any("selinuxns=refused-at-mount reason=not-unshared" in l for l in logs):
    bad.append(("selinuxfs before the unshare", "no calls, exit 1, not-unshared marker", got, exits, logs))

got = run("namespace", mount_ok=False)
if exits != [1] or not any("selinuxns=selinuxfs-mount-failed" in l for l in logs):
    bad.append(("mount failure", "exit 1, selinuxfs-mount-failed marker", got, exits, logs))

tmp.cleanup()
if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
