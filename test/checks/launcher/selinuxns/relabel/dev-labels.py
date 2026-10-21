#!/usr/bin/env python3
import contextlib, io, os, stat, sys, tempfile
LAUNCHER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "..", "..", "src", "androidd")
sys.path.insert(0, LAUNCHER)
os.environ.setdefault("RHIZO_GSI", "/nonexistent-gsi-for-check-dev-labels")
with contextlib.redirect_stdout(io.StringIO()):
    from sandbox import selinux_ns as ns

bad = []
tmp = tempfile.TemporaryDirectory()
root = tmp.name
os.makedirs(f"{root}/dev/pts")
os.makedirs(f"{root}/dev/.rhizo_uevent_sink")
chars = {f"{root}/dev/loop-control", f"{root}/dev/null", f"{root}/dev/ashmem", f"{root}/dev/pts/0",
         f"{root}/dev/gone", f"{root}/dev/unreadable", f"{root}/dev/vanished"}
for p in chars:
    open(p, "w").close()
open(f"{root}/dev/.rhizo_uevent_sink/uevent", "w").close()
mounts = {f"{root}/dev/pts": ns.DEVPTS_SUPER_MAGIC if hasattr(ns, "DEVPTS_SUPER_MAGIC") else 0x1cd1,
          f"{root}/dev/.rhizo_uevent_sink": 0x01021994}
fc = f"{root}/plat_file_contexts"
with open(fc, "w") as f:
    f.write("/dev(/.*)?          u:object_r:device:s0\n"
            "/dev/loop-control   -c  u:object_r:loop_control_device:s0\n"
            "/dev/null           -c  u:object_r:null_device:s0\n"
            "/dev/loop-control(/.*)?  u:object_r:regex_after_exact:s0\n"
            "/dev/bad[           u:object_r:never_used:s0\n")
labels = {f"{root}/dev": "u:object_r:tmpfs:s0",
          f"{root}/dev/loop-control": "u:object_r:tmpfs:s0",
          f"{root}/dev/null": "u:object_r:tmpfs:s0",
          f"{root}/dev/ashmem": "u:object_r:ashmem_device:s0",
          f"{root}/dev/pts/0": "u:object_r:tmpfs:s0",
          f"{root}/dev/gone": "u:object_r:tmpfs:s0",
          f"{root}/dev/.rhizo_uevent_sink": "u:object_r:tmpfs:s0",
          f"{root}/dev/.rhizo_uevent_sink/uevent": "u:object_r:tmpfs:s0"}
writes, reads = [], []
real_lstat = os.lstat


def fake_getxattr(path, name, follow_symlinks=True):
    """answer the label the dict holds for path"""
    reads.append(path)
    if path == f"{root}/dev/unreadable":
        raise OSError(5, "Input/output error")
    if path == f"{root}/dev/vanished":
        raise FileNotFoundError(2, "No such file or directory", path)
    if name != "security.selinux" or path not in labels:
        raise OSError(61, "No data available")
    return (labels[path] + "\0").encode()


def fake_setxattr(path, name, value, flags=0, follow_symlinks=True):
    """store the label in the dict and record the write"""
    labels[path] = value.decode().rstrip("\0")
    writes.append(path)


def fake_lstat(path, *a, **k):
    """report the fixture's device nodes as character devices"""
    if path == f"{root}/dev/gone":
        raise FileNotFoundError(2, "No such file or directory", path)
    st = real_lstat(path, *a, **k)
    if path in chars:
        fields = list(st)
        fields[0] = stat.S_IFCHR | 0o600
        return os.stat_result(fields)
    return st


logs = []
saved = (os.getxattr, os.setxattr, os.lstat, ns.kmsg, ns.selinux_labels.inode_is_ours, ns.fs_type, os.path.ismount)
os.getxattr, os.setxattr, os.lstat, ns.kmsg = fake_getxattr, fake_setxattr, fake_lstat, logs.append
ns.selinux_labels.inode_is_ours = lambda p: p != f"{root}/dev/null" and "/.rhizo_uevent_sink" not in p
ns.fs_type = lambda p: mounts.get(p, 0x01021994)
os.path.ismount = lambda p: p in mounts
try:
    got = ns.label_dev_by_file_contexts(root, [fc, f"{root}/absent_file_contexts"])
except Exception as e:
    got = repr(e)
finally:
    os.getxattr, os.setxattr, os.lstat, ns.kmsg, ns.selinux_labels.inode_is_ours, ns.fs_type, os.path.ismount = saved

want = {f"{root}/dev": "u:object_r:device:s0",
        f"{root}/dev/loop-control": "u:object_r:loop_control_device:s0",
        f"{root}/dev/null": "u:object_r:tmpfs:s0",
        f"{root}/dev/ashmem": "u:object_r:ashmem_device:s0"}
want_counts = {"labeled": 2, "kept": 1, "unmatched": 0, "refused": 1, "failed": 1, "gone": 2, "unusable": 1}
if not isinstance(got, dict) or {k: got.get(k) for k in want_counts} != want_counts \
        or not any("/dev/unreadable: read label: Input/output error" in e for e in got.get("errors", [])) \
        or not any("refused" in e and "/dev/null" in e for e in got.get("errors", [])) \
        or "gone: /dev/gone" not in got.get("errors", []) or "gone: /dev/vanished" not in got.get("errors", []):
    bad.append(("result", want_counts, "a refused /dev/null and a gone /dev/gone named in errors", got))
walked = sorted(p[len(root):] for p in reads if "/pts" in p or "/.rhizo_uevent_sink" in p)
if walked:
    bad.append(("devpts and the uevent sink", "not walked", walked))
for p, lbl in want.items():
    if labels.get(p) != lbl:
        bad.append(("label", p, lbl, labels.get(p)))
if f"{root}/dev/ashmem" in writes:
    bad.append(("ashmem written", "untouched", writes))
if not any("absent_file_contexts" in l for l in logs):
    bad.append(("unreadable file_contexts", "logged and skipped", logs))

tmp.cleanup()
if bad:
    for b in bad:
        print("FAIL", *b)
    sys.exit(1)
print("ok")
