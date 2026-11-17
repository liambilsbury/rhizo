"""sandbox root filesystem build and pivot_root"""
import ctypes
import errno
import fcntl
import glob
import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import struct
import subprocess
import tempfile
import time

from sandbox import capabilities
from sandbox import core
from sandbox import selinux_ns
from sandbox import guest_files
from sandbox.core import (AID_READPROC, CLONE_NEWNS, DEVICE_STATE_LABEL, DEVICE_STATE_MOUNT, GSI,
    HOST_ARCH, HOST_ARCH_AMD64, MOUNT_ATTR_NODEV, MOUNT_ATTR_NOEXEC, MOUNT_ATTR_NOSUID,
    MOUNT_ATTR_RDONLY, MS_BIND, MS_NODEV, MS_NOEXEC, MS_NOSUID, MS_PRIVATE, MS_RDONLY,
    MS_REC, MS_REMOUNT, MS_SHARED, NEWROOT, PREPARED_ROOT, RHIZO_APEX_DIR_BIND,
    RHIZO_DEVICE_STATE_DIR, RHIZO_ENFORCING, RHIZO_FLAT_DIR_BINDS, RHIZO_STATE_DIR,
    RHIZO_SYSKERNEL_SUBSET, RHIZO_UNDER_UNIT, RUN_ROOT, SANDBOX_ID, SYSTEM_ADB_KEYS, beside,
    cgroup_write, host_selinux_mode, kmsg, libc, mount, mount_setattr, product_build_prop_source, own_domain, phase, pivot_root, read_mountinfo, unshare)
from sandbox.selinux_labels import relabel_flat_trees_now, relabel_root_objects_now


DEV_NODES=("null","zero","full","random","urandom","tty","kmsg","ashmem")
TOPDIRS=("system","vendor","product","odm","system_ext","apex","linkerconfig","mnt",
         "data","metadata","dev","proc","sys","bootstrap-apex","second_stage_resources",
         "debug_ramdisk","postinstall","oldroot","storage")
MNT_CACHE_BYTES = 384
MNT_NAMESPACES = 42
MOUNT_TALLY = {"mounts": 0, "per_file": 0, "subtree": 0, "dir": 0,
               "overmount": 0, "apex": 0, "syskernel": 0}
RHIZO_SYSFS_RO = os.environ.get("RHIZO_SYSFS_RO", "1") != "0"
RHIZO_PERF_FILTER = os.environ.get("RHIZO_PERF_FILTER", "1") != "0"


def unshare_root_namespace(mode, handoff):
    """unshare a SELinux namespace for gg"""
    if mode == "namespace":
        selinux_ns.unshare_namespace(None if handoff else selinux_ns.ANDROID_ENFORCE_FILE)
        kmsg("RHIZO_MARKER selinuxns=hold-unshared" if handoff else "RHIZO_MARKER selinuxns=unshared")


TMPFS_MAGIC = 0x01021994
DEVICE_STATE_NAME = re.compile(r"device-state(-[0-9]+)?")


def mount_points_below(path, rows):
    """return the mount points strictly below path in mountinfo rows"""
    prefix = path.rstrip("/") + "/"
    return {r[4] for r in rows if r[4].startswith(prefix)}


HELPER_CAPS_EXIT = 3


def stage_host_battery(state_dir, data, log=kmsg, owner=(0, 0)):
    """write the first host-battery bytes and return the host-battery path"""
    path = os.path.join(state_dir, core.HOST_BATTERY_FILE)
    if data is None:
        try:
            os.unlink(path)
            log("deleted host-battery for a battery source other than host")
        except FileNotFoundError:
            pass
        except OSError as e:
            log(f"RHIZO_MARKER battery_relay=stale-unlink-failed err={errno.errorcode.get(e.errno, e.errno)}")
        return None
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o644)
    except OSError as e:
        log(f"RHIZO_MARKER battery_relay=failed reason=create:{errno.errorcode.get(e.errno, e.errno)}")
        _drop_host_battery(path, log)
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            log("RHIZO_MARKER battery_relay=failed reason=create:not-a-regular-file")
            os.close(fd)
            _drop_host_battery(path, log)
            return None
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("flock of host-battery failed with EWOULDBLOCK")
        if owner is not None and (st.st_uid, st.st_gid) != tuple(owner):
            os.fchown(fd, *owner)
        if stat.S_IMODE(st.st_mode) != 0o644:
            os.fchmod(fd, 0o644)
        os.pwrite(fd, data, 0)
        os.ftruncate(fd, len(data))
    except OSError as e:
        log(f"RHIZO_MARKER battery_relay=failed reason=create:{errno.errorcode.get(e.errno, e.errno)}")
        os.close(fd)
        _drop_host_battery(path, log)
        return None
    os.close(fd)
    return path


def _drop_host_battery(path, log=kmsg):
    """unlink host-battery after a failed staging"""
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    except OSError as e:
        log(f"failed to unlink {path} ({e.strerror})")


def settle_host_battery(path, result, log=kmsg):
    """return True for a labelled host-battery and unlink an unlabelled host-battery"""
    if path is None or result == "ok":
        return True
    log(f"RHIZO_MARKER battery_relay=failed reason=label:{result}")
    try:
        os.unlink(path)
    except OSError as e:
        log(f"failed to unlink unlabelled {path} ({e.strerror})")
    return False


def prelabel_vendor_tree(root):
    """label the vendor tree, the device-state directory and host-battery"""
    vendor = f"{root}/vendor"
    on_tmpfs = selinux_ns.fs_type(vendor) == TMPFS_MAGIC
    if on_tmpfs:
        kmsg("RHIZO_MARKER selinuxns=vendor-prelabel skipped=tmpfs")
    os.makedirs(RHIZO_DEVICE_STATE_DIR, exist_ok=True)
    battery_path = stage_host_battery(RHIZO_DEVICE_STATE_DIR, core.host_battery())
    device_r, device_w = os.pipe()
    pid = os.fork()
    if pid == 0:
        code = 1
        try:
            os.close(device_r)
            core.stdio_to_null()
            caps_why = selinux_ns.drop_to_init_caps()
            rows = None if on_tmpfs else read_mountinfo()
            why = (f"caps-failed:{caps_why}" if caps_why else
                   selinux_ns.enter_policy_namespace(f"{vendor}/etc/selinux/precompiled_sepolicy", "relabel"))
            if why:
                os.write(device_w, f"policy-namespace:{why}".encode())
                kmsg(f"RHIZO_MARKER selinuxns=vendor-prelabel skipped={why}")
                code = HELPER_CAPS_EXIT if caps_why else 1
            else:
                battery_state = (label_device_state_dir(battery_path) or "ok") if battery_path else "-"
                os.write(device_w, ((label_device_state_dir(RHIZO_DEVICE_STATE_DIR) or "ok")
                                    + "\n" + battery_state).encode())
                if on_tmpfs:
                    code = 0
                elif rows is None:
                    kmsg("RHIZO_MARKER selinuxns=vendor-prelabel skipped=mountinfo-unreadable")
                else:
                    fcs = [f"{GSI}/etc/selinux/plat_file_contexts",
                           f"{GSI}/system_ext/etc/selinux/system_ext_file_contexts",
                           f"{GSI}/product/etc/selinux/product_file_contexts",
                           f"{vendor}/etc/selinux/vendor_file_contexts"]
                    result = selinux_ns.label_by_file_contexts(vendor, "/vendor", fcs,
                                                                    prune=mount_points_below(vendor, rows).__contains__)
                    kmsg(f"RHIZO_MARKER selinuxns=vendor-prelabel result={result!r}"[:900])
                    code = 2 if result["refused"] or result["failed"] else 0
        except BaseException as e:
            kmsg(f"RHIZO_MARKER selinuxns=vendor-prelabel-failed err={e!r}"[:900])
        finally:
            os._exit(code)
    os.close(device_w)
    with os.fdopen(device_r, "rb") as f:
        device_state, _, battery_state = f.read().decode(errors="replace").partition("\n")
    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status) and os.WEXITSTATUS(status) == HELPER_CAPS_EXIT:
        kmsg("RHIZO_MARKER selinuxns=refused reason=vendor-prelabel-caps-failed")
        os._exit(1)
    if status:
        kmsg(f"RHIZO_MARKER selinuxns=vendor-prelabel-failed status={os.waitstatus_to_exitcode(status)}")
    if device_state != "ok":
        refuse_device_state_label(RHIZO_DEVICE_STATE_DIR, device_state or f"no-output:{os.waitstatus_to_exitcode(status)}")
    settle_host_battery(battery_path, battery_state or "no-output")


def device_state_dir_refusal(path, root):
    """return the reason path is not a device-state directory, or None"""
    if os.path.islink(path):
        return "a-symlink"
    real, real_root = os.path.realpath(path), os.path.realpath(root)
    if os.path.dirname(real) != real_root:
        return "outside-the-state-root"
    if not DEVICE_STATE_NAME.fullmatch(os.path.basename(real)):
        return "not-a-device-state-name"
    return None


def read_label(path):
    """return the label of path or the getxattr error"""
    try:
        return os.getxattr(path, "security.selinux").rstrip(b"\0").decode(errors="replace")
    except OSError as e:
        return f"unreadable:{e.strerror}"


def refuse_device_state_label(path, label):
    """log RHIZO_MARKER selinuxns=refused for a device-state label and exit"""
    kmsg(f"RHIZO_MARKER selinuxns=refused reason=device-state-label-failed path={path} label={label}")
    os._exit(1)


def label_device_state_dir(path):
    """return the error labeling path rhizo_device_state_file"""
    if read_label(path) != DEVICE_STATE_LABEL:
        try:
            os.setxattr(path, "security.selinux", (DEVICE_STATE_LABEL + "\0").encode())
        except OSError as e:
            return f"unwritable:{e.strerror}"
    label = read_label(path)
    return None if label == DEVICE_STATE_LABEL else label


def label_before_policy(path, value, follow_symlinks=True):
    """set the label of path before policy load"""
    if selinux_ns.state()["unshared"]:
        return False
    os.setxattr(path, "security.selinux", value, follow_symlinks=follow_symlinks)
    return True


def mount_sandbox_selinuxfs(mode):
    """mount the sandbox's selinuxfs"""
    os.makedirs(f"{NEWROOT}/sys/fs/selinux", exist_ok=True)
    if mode == "namespace":
        if not selinux_ns.state()["unshared"]:
            kmsg("RHIZO_MARKER selinuxns=refused-at-mount reason=not-unshared")
            os._exit(1)
        selinux_ns.mount_own_selinuxfs(f"{NEWROOT}/sys/fs/selinux")
    elif mode == "host":
        mount("/sys/fs/selinux", f"{NEWROOT}/sys/fs/selinux", None, MS_BIND)
    else:
        kmsg(f"RHIZO_MARKER selinuxns=refused-at-mount mode={mode}")
        os._exit(1)


def _tally(kind, n=1):
    """add n to the tally of kind and to the mount total"""
    MOUNT_TALLY[kind] += n
    MOUNT_TALLY["mounts"] += n


def mount_marker():
    """log the RHIZO_MARKER mount counts by kind"""
    t = MOUNT_TALLY
    kmsg("RHIZO_MARKER mounts=%d per_file=%d subtree=%d apex=%d syskernel=%d"
         % (t["mounts"], t["per_file"], t["subtree"], t["apex"], t["syskernel"]))


SYS_KERNEL_READONLY = frozenset({"uevent_helper"})


def bind_sys_kernel_child(src, dst, name):
    """bind src at dst, remount a SYS_KERNEL_READONLY child read-only and detach dst on a remount failure"""
    if not mount(src, dst, None, MS_BIND | MS_REC):
        return False
    if name in SYS_KERNEL_READONLY and not mount(None, dst, None,
                                                 MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC):
        err = ctypes.get_errno()
        libc.umount2(dst.encode(), 2)
        kmsg(f"RHIZO_MARKER syskernel_ro=failed child={name} errno={err} detached=1")
        return False
    return True


def _sys_kernel_keep():
    """return the /sys/kernel children to bind"""
    try:
        text = guest_files.read("sys-kernel-readers.txt")
    except OSError as e:
        kmsg(f"failed to read sys-kernel-readers.txt ({e})")
        return None
    keep = {l.strip() for l in text.splitlines()
            if l.strip() and not l.startswith("#")}
    return keep or None


def plan_bad_targets(ops, flat):
    """return the plan bind targets outside flat or under the GSI or the prepared tree"""
    flat_root = os.path.normpath(flat)
    forbidden = [os.path.normpath(p) for p in (GSI, PREPARED_ROOT)]
    bad = []
    for op in ops:
        if op["op"] != "bind":
            continue
        dst = os.path.normpath(op["dst"])
        inside = dst == flat_root or dst.startswith(flat_root + "/")
        if not inside or any(dst == f or dst.startswith(f + "/") for f in forbidden):
            bad.append("%s -> %s" % (op["kind"], dst))
    return bad


def plan_flat_tree(lower, upper, flat, readonly_lower=False, dir_binds=False):
    """return the ops, counts and walk errors of the flat tree"""
    ops = []
    counts = {"files": 0, "links": 0, "dirs": 0, "subtrees": 0,
              "dirbinds": 0, "overmounts": 0}
    walk_errors = []
    upper_dirs = {"."}
    upper_rels = []
    if os.path.isdir(upper):
        for dirpath, dirnames, filenames in os.walk(upper, onerror=walk_errors.append):
            rel_dir = os.path.relpath(dirpath, upper)
            links = [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]
            for name in filenames + links:
                upper_rels.append(name if rel_dir == "." else f"{rel_dir}/{name}")
            if not filenames and not links:
                continue
            rel = rel_dir
            while rel not in upper_dirs:
                upper_dirs.add(rel)
                rel = os.path.dirname(rel) or "."

    def _under(rel, d):
        """return whether rel is d or under d"""
        return rel == d or rel.startswith(d + "/")

    def _replaceable(rel):
        """return whether the upper and lower paths of rel are both regular files"""
        src, low = os.path.join(upper, rel), os.path.join(lower, rel)
        return (os.path.isfile(src) and not os.path.islink(src)
                and os.path.isfile(low) and not os.path.islink(low))

    bound_dirs = set()
    if dir_binds:
        for d in sorted(upper_dirs, key=lambda r: (r.count("/"), r)):
            if d == "." or not os.path.isdir(os.path.join(lower, d)):
                continue
            if any(_under(d, b) for b in bound_dirs):
                continue
            if all(_replaceable(r) for r in upper_rels if _under(r, d)):
                bound_dirs.add(d)
    staged = set()

    def _bind(kind, src, dst, rel, ro=False, rec=False):
        """append a bind op to the plan"""
        ops.append({"op": "bind", "kind": kind, "src": src, "dst": dst,
                    "rel": rel, "ro": ro, "rec": rec})

    def _mirror(src_root, is_upper):
        """plan the mounts mirroring a source tree into the flat tree"""
        if not os.path.isdir(src_root):
            return
        for dirpath, dirnames, filenames in os.walk(src_root, onerror=walk_errors.append):
            rel_dir = os.path.relpath(dirpath, src_root)
            dst_dir = flat if rel_dir == "." else os.path.join(flat, rel_dir)
            if is_upper and any(_under(rel_dir, b) for b in bound_dirs):
                dirnames[:] = []
                continue
            if not is_upper and rel_dir not in upper_dirs:
                ops.append({"op": "mkdir", "dst": dst_dir})
                counts["dirs"] += 1
                _bind("subtree", dirpath, dst_dir, rel_dir, ro=readonly_lower, rec=True)
                counts["subtrees"] += 1
                dirnames[:] = []
                continue
            if not is_upper and rel_dir in bound_dirs:
                ops.append({"op": "mkdir", "dst": dst_dir})
                counts["dirs"] += 1
                _bind("dir", dirpath, dst_dir, rel_dir, rec=True)
                counts["dirbinds"] += 1
                for rel in sorted(r for r in upper_rels if _under(r, rel_dir)):
                    _bind("overmount", os.path.join(upper, rel),
                          os.path.join(flat, rel), rel, ro=readonly_lower)
                    counts["overmounts"] += 1
                    staged.add(rel)
                if readonly_lower:
                    ops.append({"op": "remount_ro", "dst": dst_dir})
                dirnames[:] = []
                continue
            ops.append({"op": "mkdir", "dst": dst_dir})
            counts["dirs"] += 1
            for name in filenames:
                rel = name if rel_dir == "." else f"{rel_dir}/{name}"
                if rel in staged:
                    continue
                staged.add(rel)
                src = os.path.join(dirpath, name)
                dst = os.path.join(dst_dir, name)
                if os.path.islink(src):
                    ops.append({"op": "symlink", "target": os.readlink(src), "dst": dst})
                    counts["links"] += 1
                    continue
                if not os.path.isfile(src):
                    continue
                ops.append({"op": "touch", "dst": dst})
                _bind("file", src, dst, rel, ro=readonly_lower)
                counts["files"] += 1
    _mirror(upper, True)
    _mirror(lower, False)
    counts["mounts"] = (counts["files"] + counts["subtrees"]
                        + counts["dirbinds"] + counts["overmounts"])
    return ops, counts, walk_errors


_TALLY_KEY = {"file": "per_file", "subtree": "subtree", "dir": "dir",
              "overmount": "overmount"}


def flatten_tree(lower, upper, flat, readonly_lower=False):
    """build the flat tree from lower and upper"""
    os.makedirs(flat, exist_ok=True)
    os.chmod(flat, 0o755)
    ops, planned, walk_errors = plan_flat_tree(
        lower, upper, flat, readonly_lower, dir_binds=RHIZO_FLAT_DIR_BINDS)
    bad = plan_bad_targets(ops, flat)
    if bad:
        kmsg(f"flatten {flat} has {len(bad)} mount targets outside the staging tree ({bad[:4]})")
        raise RuntimeError(f"flatten_tree({flat}) {len(bad)} mount targets "
                           f"outside the staging tree, first {bad[0]}")
    n = {"files": 0, "links": 0, "dirs": 0, "subtrees": 0,
         "dirbinds": 0, "overmounts": 0}
    failed = []
    for op in ops:
        kind = op["op"]
        if kind == "mkdir":
            os.makedirs(op["dst"], exist_ok=True)
            n["dirs"] += 1
        elif kind == "symlink":
            os.symlink(op["target"], op["dst"])
            n["links"] += 1
        elif kind == "touch":
            open(op["dst"], "w").close()
        elif kind == "remount_ro":
            mount(None, op["dst"], None, MS_BIND | MS_REMOUNT | MS_RDONLY)
        elif mount(op["src"], op["dst"], None, MS_BIND | (MS_REC if op["rec"] else 0)):
            n[{"file": "files", "subtree": "subtrees", "dir": "dirbinds",
               "overmount": "overmounts"}[op["kind"]]] += 1
            _tally(_TALLY_KEY[op["kind"]])
            if op["ro"]:
                mount(None, op["dst"], None, MS_BIND | MS_REMOUNT | MS_RDONLY)
        else:
            failed.append((op["kind"], op["rel"], ctypes.get_errno()))
            kmsg(f"flatten {flat} {op['kind']} bind of {op['rel']} failed "
                 f"({os.strerror(ctypes.get_errno())})")
    try:
        label_before_policy(flat, b"u:object_r:system_file:s0\0")
    except OSError as e:
        kmsg(f"setxattr of {flat} failed ({e})")
    kmsg(f"flatten {flat} files={n['files']} symlinks={n['links']} "
         f"dirs={n['dirs']} subtrees={n['subtrees']} "
         f"dirbinds={n['dirbinds']} overmounts={n['overmounts']}")
    if failed:
        kmsg(f"flatten {flat} {len(failed)} binds failed, first "
             f"{failed[0][0]} {failed[0][1]} ({os.strerror(failed[0][2])})")
        raise RuntimeError(
            f"flatten_tree({flat}) {len(failed)} binds failed, first "
            f"{failed[0][0]} bind of {failed[0][1]} ({os.strerror(failed[0][2])})")
    if walk_errors:
        first = walk_errors[0]
        kmsg(f"flatten {flat} os.walk failed on {len(walk_errors)} paths, first "
             f"{getattr(first, 'filename', '?')} ({first})")
        raise RuntimeError(
            f"flatten_tree({flat}) os.walk failed on {len(walk_errors)} paths, "
            f"first {getattr(first, 'filename', '?')} ({first})")
def apex_override_targets(override_files, gsi_entries):
    """return the GSI apex entry each override replaces"""
    entries = set(gsi_entries)
    targets, unmatched = {}, []
    for name in override_files:
        if not name.endswith(".apex"):
            continue
        stem = name[:-len(".apex")]
        if stem + ".capex" in entries:
            targets[stem + ".capex"] = name
        elif name in entries:
            targets[name] = name
        else:
            unmatched.append(name)
    return targets, unmatched


def _build_flat_trees():
    """build the flat trees for /system and /system/apex"""
    net_core_snapshot = {}
    try:
        for name in os.listdir(f"{RUN_ROOT}/net_core_snapshot"):
            net_core_snapshot[name] = open(f"{RUN_ROOT}/net_core_snapshot/{name}").read()
    except OSError as e: kmsg(f"failed to read the net.core snapshot ({e})")
    if not mount(None,"/",None,MS_PRIVATE|MS_REC):
        kmsg(f"failed to set MS_PRIVATE on / ({os.strerror(ctypes.get_errno())})")
        os._exit(1)
    if not mount("tmpfs",NEWROOT,"tmpfs",MS_NOSUID|MS_NODEV,"mode=0755"):
        kmsg(f"failed to mount tmpfs at {NEWROOT} ({os.strerror(ctypes.get_errno())})")
        os._exit(1)
    for d in TOPDIRS: os.makedirs(f"{NEWROOT}/{d}", exist_ok=True)
    os.makedirs(f"{NEWROOT}/mnt/vendor", exist_ok=True)
    os.makedirs(f"{NEWROOT}/mnt/user/0", exist_ok=True)
    os.makedirs(f"{NEWROOT}/mnt/asec", exist_ok=True)
    try: os.symlink("/storage/self/primary", f"{NEWROOT}/sdcard")
    except OSError: pass
    if os.path.exists(SYSTEM_ADB_KEYS):
        shutil.copyfile(SYSTEM_ADB_KEYS, f"{NEWROOT}/adb_keys")
        os.chmod(f"{NEWROOT}/adb_keys", 0o644)
    flatten_tree(GSI, f"{RUN_ROOT}/system_upper", f"{RUN_ROOT}/system_flat",
                 readonly_lower=True)
    if mount(f"{RUN_ROOT}/system_flat", f"{NEWROOT}/system", None, MS_BIND|MS_REC):
        kmsg("bound system_flat at /system")
    else:
        kmsg("failed to bind system_flat at /system")
    apex_flat = f"{RUN_ROOT}/system_apex_flat"
    os.makedirs(apex_flat, exist_ok=True)
    os.chmod(apex_flat, 0o755)
    apex_lower = f"{GSI}/apex"
    apex_override_dir = f"{RUN_ROOT}/apex_override"
    try:
        apex_entries = os.listdir(apex_lower)
    except OSError as e:
        apex_entries = []
        kmsg(f"failed to list {apex_lower} ({e})")
    try:
        _override_files = sorted(os.listdir(apex_override_dir))
    except OSError:
        _override_files = []
    apex_overrides, _apex_unmatched = apex_override_targets(_override_files, apex_entries)
    for _n in _apex_unmatched:
        kmsg(f"no GSI .capex or .apex for apex override {_n}")
    _apex_expect_size = {}
    for _apex_name in apex_entries:
        if _apex_name in apex_overrides:
            continue
        _apex_expect_size[_apex_name] = os.path.getsize(f"{apex_lower}/{_apex_name}")
    if RHIZO_APEX_DIR_BIND:
        if mount(apex_lower, apex_flat, None, MS_BIND):
            _tally("apex")
        else:
            kmsg(f"failed to bind {apex_lower}")
    else:
        for _apex_name in _apex_expect_size:
            _apex_dst = f"{apex_flat}/{_apex_name}"
            open(_apex_dst, "a").close()
            if mount(f"{apex_lower}/{_apex_name}", _apex_dst, None, MS_BIND):
                _tally("apex")
            else:
                kmsg(f"failed to bind /system/apex/{_apex_name}")
    for _apex_name, _override_file in apex_overrides.items():
        apex_override_src = f"{apex_override_dir}/{_override_file}"
        _apex_dst = f"{apex_flat}/{_apex_name}"
        _apex_expect_size[_apex_name] = os.path.getsize(apex_override_src)
        if not RHIZO_APEX_DIR_BIND:
            open(_apex_dst, "a").close()
        if mount(apex_override_src, _apex_dst, None, MS_BIND):
            _tally("apex")
            _want = b"u:object_r:system_file:s0\0"
            try:
                _cur = os.getxattr(_apex_dst, "security.selinux", follow_symlinks=False)
            except OSError:
                _cur = None
            if _cur != _want:
                try:
                    label_before_policy(_apex_dst, _want)
                except OSError as e:
                    kmsg(f"setxattr of an apex override failed ({e})")
        else:
            kmsg(f"failed to bind apex override {_override_file} over {_apex_name}")
    if RHIZO_APEX_DIR_BIND:
        try:
            _dir_label = os.getxattr(apex_flat, "security.selinux").decode(
                errors="replace").rstrip("\x00")
        except OSError as e:
            _dir_label = f"unreadable ({e})"
        kmsg(f"/system/apex dir bind security.selinux={_dir_label} "
             f"expected=u:object_r:system_file:s0")
    else:
        try:
            label_before_policy(apex_flat, b"u:object_r:system_file:s0\0")
        except OSError as e:
            kmsg(f"setxattr of system_apex_flat failed ({e})")
    if mount(apex_flat, f"{NEWROOT}/system/apex", None, MS_BIND|MS_REC):
        _tally("apex")
        _apex_bad = []
        for _name, _want in _apex_expect_size.items():
            _got_path = f"{NEWROOT}/system/apex/{_name}"
            try:
                _got = os.path.getsize(_got_path)
            except OSError as e:
                _apex_bad.append(f"{_name} stat failed ({e})"); continue
            if _got != _want:
                _apex_bad.append(f"{_name} size={_got} expected={_want}")
        if _apex_bad:
            kmsg(f"/system/apex size mismatch on {len(_apex_bad)}/{len(_apex_expect_size)} "
                 f"entries ({_apex_bad})")
        else:
            kmsg(f"/system/apex entries={len(apex_entries)} "
                 f"overrides={len(apex_overrides)} "
                 f"verified={len(_apex_expect_size)}")
    else:
        kmsg("failed to bind system_apex_flat at /system/apex")
    return net_core_snapshot


def _mount_extra_partitions(net_core_snapshot):
    """bind system_ext and product and remount /system read-only"""
    mount(None,f"{NEWROOT}/system",None,MS_BIND|MS_REMOUNT|MS_RDONLY)
    se_src=f"{GSI}/system_ext"
    if os.path.isdir(se_src):
        flatten_tree(se_src, f"{RUN_ROOT}/system_ext_upper",
                     f"{RUN_ROOT}/system_ext_flat", readonly_lower=True)
        if mount(f"{RUN_ROOT}/system_ext_flat", f"{NEWROOT}/system_ext", None, MS_BIND|MS_REC):
            kmsg("bound system_ext_flat at /system_ext")
        else:
            kmsg("failed to bind system_ext_flat at /system_ext")
    pr_src=f"{GSI}/product"
    if os.path.isdir(pr_src):
        pb_src = product_build_prop_source()
        if pb_src is not None:
            os.makedirs(f"{RUN_ROOT}/product_upper/etc", exist_ok=True)
            import shutil as _sh5
            _sh5.copy(pb_src, f"{RUN_ROOT}/product_upper/etc/build.prop")
            if core.camera_armed():
                dropped = core.drop_prop_line(f"{RUN_ROOT}/product_upper/etc/build.prop", core.CAMERA_SERVICE_DISABLED)
                kmsg(f"deleted {core.CAMERA_SERVICE_DISABLED} from product/etc/build.prop count={dropped}")
        else:
            kmsg(f"no patched product/etc/build.prop at {pb_src}")
        flatten_tree(pr_src, f"{RUN_ROOT}/product_upper", f"{RUN_ROOT}/product_flat",
                     readonly_lower=True)
        if mount(f"{RUN_ROOT}/product_flat", f"{NEWROOT}/product", None, MS_BIND|MS_REC):
            kmsg("bound product_flat at /product")
        else:
            kmsg("failed to bind product_flat at /product")
    relabel_flat_trees_now()
    for p in ("vendor","apex","linkerconfig","mnt","data","metadata"):
        mount(f"{RUN_ROOT}/{p}",f"{NEWROOT}/{p}",None,MS_BIND | (MS_REC if p == "vendor" else 0))
    if not mount("tmpfs",f"{NEWROOT}/dev","tmpfs",MS_NOSUID|MS_NOEXEC,"mode=0755"):
        kmsg(f"failed to mount tmpfs at {NEWROOT}/dev ({os.strerror(ctypes.get_errno())})")
        os._exit(1)
    stage_sysctl_shadows(f"{NEWROOT}/dev")
    try:
        os.makedirs(f"{NEWROOT}/dev/.rhizo_net_core", exist_ok=True)
        for _nm, _vv in net_core_snapshot.items():
            open(f"{NEWROOT}/dev/.rhizo_net_core/{_nm}", "w").write(_vv)
    except OSError as _e:
        kmsg(f"failed to stage the net.core snapshot ({_e})")
    for d in ("pts","shm","socket","binderfs"): os.makedirs(f"{NEWROOT}/dev/{d}",exist_ok=True)
    mount("devpts",f"{NEWROOT}/dev/pts","devpts",0,"newinstance,ptmxmode=0666,mode=0620")
    try: os.symlink("pts/ptmx",f"{NEWROOT}/dev/ptmx")
    except FileExistsError: pass
    mount("tmpfs",f"{NEWROOT}/dev/shm","tmpfs",MS_NOSUID|MS_NODEV|MS_NOEXEC,"mode=1777")


AID_ROOT, AID_SYSTEM, AID_GRAPHICS, AID_VPN = 0, 1000, 1003, 1016
AID_PRNG_SEEDER, AID_UHID = 1092, 3011

STAGED_DEV_PERMS = {
    "/dev/null":        (0o666, AID_ROOT, AID_ROOT, "u:object_r:null_device:s0"),
    "/dev/zero":        (0o666, AID_ROOT, AID_ROOT, "u:object_r:zero_device:s0"),
    "/dev/full":        (0o666, AID_ROOT, AID_ROOT, "u:object_r:device:s0"),
    "/dev/random":      (0o666, AID_ROOT, AID_ROOT, "u:object_r:random_device:s0"),
    "/dev/urandom":     (0o666, AID_ROOT, AID_ROOT, "u:object_r:random_device:s0"),
    "/dev/tty":         (0o666, AID_ROOT, AID_ROOT, "u:object_r:owntty_device:s0"),
    "/dev/kmsg":        (0o600, AID_ROOT, AID_ROOT, "u:object_r:kmsg_device:s0"),
    "/dev/ashmem":      (0o666, AID_ROOT, AID_ROOT, "u:object_r:ashmem_device:s0"),
    "/dev/uinput":      (0o660, AID_UHID, AID_UHID, "u:object_r:uhid_device:s0"),
    "/dev/dri/renderD128": (0o666, AID_ROOT, AID_GRAPHICS, "u:object_r:gpu_device:s0"),
    "/dev/dri/card0":   (0o666, AID_ROOT, AID_GRAPHICS, "u:object_r:gpu_device:s0"),
    "/dev/tun":         (0o660, AID_SYSTEM, AID_VPN, "u:object_r:tun_device:s0"),
    "/dev/loop-control": (0o600, AID_ROOT, AID_ROOT, "u:object_r:loop_control_device:s0"),
    "/dev/device-mapper": (0o600, AID_ROOT, AID_ROOT, "u:object_r:dm_device:s0"),
    "/dev/fuse":        (0o600, AID_ROOT, AID_ROOT, "u:object_r:fuse_device:s0"),
    "/dev/hw_random":   (0o400, AID_PRNG_SEEDER, AID_PRNG_SEEDER, "u:object_r:hw_random_device:s0"),
    "/dev/dma_heap/system": (0o444, AID_SYSTEM, AID_SYSTEM, "u:object_r:dmabuf_system_heap_device:s0"),
    "/dev/dma_heap/system-uncached": (0o444, AID_SYSTEM, AID_SYSTEM,
                                      "u:object_r:dmabuf_system_heap_device:s0"),
    "/dev/block/loop[0-9]*": (0o600, AID_ROOT, AID_ROOT, "u:object_r:loop_device:s0"),
    "/dev/ashmem?*": (0o666, AID_ROOT, AID_ROOT, "u:object_r:ashmem_libcutils_device:s0"),
}
DMA_HEAP_DIR = ("/dev/dma_heap", 0o755, "u:object_r:dmabuf_heap_device:s0")
INIT_RESTORECON = ("/dev/console", "/dev/kmsg", "/dev/null", "/dev/random",
                   "/dev/urandom", "/dev/device-mapper", "/dev/block/loop[0-9]*")


def staged_dev_perms(path):
    """return (mode, uid, gid, label) for a staged node"""
    import fnmatch
    if path in STAGED_DEV_PERMS:
        return STAGED_DEV_PERMS[path]
    for pat, v in STAGED_DEV_PERMS.items():
        if "*" in pat and fnmatch.fnmatchcase(path, pat):
            return v
    raise KeyError(path)


COLDBOOT_MISC = ("loop-control", "device-mapper", "fuse", "hw_random")
COLDBOOT_DMA_HEAPS = ("system", "system-uncached")
COLDBOOT_BOOT_ID_DUPS = ("ashmem",)


def host_boot_id(proc_root="/proc"):
    """return the kernel's boot id"""
    with open(f"{proc_root}/sys/kernel/random/boot_id") as f:
        return f.read().strip()


def _devnum(path):
    """return (major, minor) from a sysfs dev file"""
    try:
        with open(path) as f:
            major, minor = f.read().strip().split(":")
        return int(major), int(minor)
    except (OSError, ValueError):
        return None


def plan_coldboot_nodes(sys_root="/sys", proc_root="/proc"):
    """return (path, type, major, minor) for each cold-boot node"""
    plan = []
    for name in COLDBOOT_MISC:
        dn = _devnum(f"{sys_root}/class/misc/{name}/dev")
        if dn:
            plan.append((f"/dev/{name}", "c") + dn)
    for name in COLDBOOT_BOOT_ID_DUPS:
        dn = _devnum(f"{sys_root}/class/misc/{name}/dev")
        if dn:
            plan.append((f"/dev/{name}{host_boot_id(proc_root)}", "c") + dn)
    for name in COLDBOOT_DMA_HEAPS:
        dn = _devnum(f"{sys_root}/class/dma_heap/{name}/dev")
        if dn:
            plan.append((f"/dev/dma_heap/{name}", "c") + dn)
    try:
        blocks = os.listdir(f"{sys_root}/class/block")
    except OSError:
        blocks = []
    loops = sorted((int(b[4:]), b) for b in blocks
                   if b.startswith("loop") and b[4:].isdigit())
    for _, name in loops:
        dn = _devnum(f"{sys_root}/class/block/{name}/dev")
        if dn:
            plan.append((f"/dev/block/{name}", "b") + dn)
    return plan


def _stage_node(root, rel, kind, major, minor):
    """mknod a node with the STAGED_DEV_PERMS mode, owner and label"""
    mode, uid, gid, label = staged_dev_perms(rel)
    dst = root + rel
    try:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.mknod(dst, (stat.S_IFBLK if kind == "b" else stat.S_IFCHR) | mode,
                 os.makedev(major, minor))
        os.chown(dst, uid, gid)
        os.chmod(dst, mode)
    except OSError as e:
        return f"{rel} ({e})"
    try:
        label_before_policy(dst, (label + "\0").encode())
    except OSError:
        pass
    return None


RAMDISK_PROP = "/second_stage_resources/system/etc/ramdisk/build.prop"
RAMDISK_PROP_TEXT = ("# cold boot /dev nodes staged by the Rhizo first stage\n"
                     "ro.cold_boot_done=true\n")


def _stage_coldboot(sys_root="/sys", proc_root="/proc"):
    """stage the cold boot's nodes"""
    try:
        plan = plan_coldboot_nodes(sys_root, proc_root)
    except OSError as e:
        kmsg(f"RHIZO_MARKER coldboot=failed reason=boot-id:{e.errno}")
        return False
    failed = [e for e in (_stage_node(NEWROOT, rel, kind, major, minor)
                          for rel, kind, major, minor in plan) if e]
    heap_dir = NEWROOT + DMA_HEAP_DIR[0]
    if os.path.isdir(heap_dir):
        try:
            os.chmod(heap_dir, DMA_HEAP_DIR[1])
            label_before_policy(heap_dir, (DMA_HEAP_DIR[2] + "\0").encode())
        except OSError:
            pass
    loops = sum(1 for rel, *_ in plan if rel.startswith("/dev/block/loop"))
    others = [rel for rel, *_ in plan if not rel.startswith("/dev/block/loop")]
    if failed:
        kmsg(f"RHIZO_MARKER coldboot=failed reason=nodes staged={len(plan) - len(failed)} "
             f"failed={failed}")
        return False
    ssr = f"{NEWROOT}/second_stage_resources"
    try:
        os.makedirs(ssr, exist_ok=True)
    except OSError as e:
        kmsg(f"RHIZO_MARKER coldboot=failed reason=ssr-dir:{e.errno}")
        return False
    if not mount("tmpfs", ssr, "tmpfs", MS_NOSUID|MS_NODEV|MS_NOEXEC, "mode=0755"):
        kmsg("RHIZO_MARKER coldboot=failed reason=ssr-tmpfs")
        return False
    try:
        os.makedirs(os.path.dirname(NEWROOT + RAMDISK_PROP), exist_ok=True)
        with open(NEWROOT + RAMDISK_PROP, "w") as f:
            f.write(RAMDISK_PROP_TEXT)
    except OSError as e:
        kmsg(f"RHIZO_MARKER coldboot=failed reason=ramdisk-prop:{e.errno}")
        return False
    kmsg(f"RHIZO_MARKER coldboot=first-stage loops={loops} nodes={others}")
    return True


SYS_DEVICES_SIDE = "/real_sys_devices"
REGEN_DECOY = "virtual/net/lo/uevent"


def plan_sys_devices_shadow(children):
    """return the ops for a tmpfs over /sys/devices"""
    ops = [("tmpfs", None, "/sys/devices")]
    ops += [("bind", name, f"/sys/devices/{name}") for name in sorted(children)]
    ops.append(("bind", REGEN_DECOY, "/sys/devices/uevent"))
    return ops


def _shadow_sys_devices():
    """apply plan_sys_devices_shadow all or nothing"""
    side, top = NEWROOT + SYS_DEVICES_SIDE, f"{NEWROOT}/sys/devices"
    os.makedirs(side, exist_ok=True)
    if not mount(top, side, None, MS_BIND|MS_REC):
        kmsg("RHIZO_MARKER coldboot_shadow=failed reason=side-bind")
        return False
    why = ""
    if not os.path.exists(f"{side}/{REGEN_DECOY}"):
        why = "no-lo-uevent"
    ops = plan_sys_devices_shadow(os.listdir(side)) if not why else []
    covered = False
    for op, src, dst in ops:
        target = NEWROOT + dst
        if op == "tmpfs":
            covered = mount("tmpfs", target, "tmpfs", MS_NOSUID|MS_NODEV|MS_NOEXEC, "mode=0755")
            if not covered:
                why = "tmpfs"
                break
            continue
        source = f"{side}/{src}"
        is_dir = os.path.isdir(source) and not os.path.islink(source)
        try:
            if is_dir:
                os.makedirs(target, exist_ok=True)
            else:
                open(target, "w").close()
        except OSError as e:
            why = f"mountpoint:{dst}:{e.errno}"
            break
        if not mount(source, target, None, MS_BIND | (MS_REC if is_dir else 0)):
            why = f"bind:{dst}"
            break
    if why and covered:
        libc.umount2(top.encode(), 2)
    libc.umount2(side.encode(), 2)
    try:
        os.rmdir(side)
    except OSError:
        pass
    if why:
        kmsg(f"RHIZO_MARKER coldboot_shadow=failed reason={why}")
        return False
    kmsg(f"RHIZO_MARKER coldboot_shadow=ok children={len(ops) - 2} uevent={REGEN_DECOY}")
    return True


UEVENT_SINK_DIR = "/dev/.rhizo_uevent_sink"


def plan_block_uevents(sys_root, devpath=None):
    """return the uevent paths vold's cold boot of /sys/block writes"""
    out = []

    def walk(d, lvl):
        """collect the uevent paths of d and the subdirectories of d"""
        ue = os.path.join(d, "uevent")
        if os.path.isfile(ue):
            out.append(os.path.realpath(ue))
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            return
        for e in entries:
            if e.name.startswith(".") or (lvl > 0 and not e.is_dir(follow_symlinks=False)):
                continue
            if lvl > 0 or os.path.isdir(e.path):
                walk(e.path, lvl + 1)
    if devpath and devpath.startswith("/devices/") and "/../" not in devpath + "/":
        walk(f"{sys_root}{devpath}", 1)
    else:
        walk(f"{sys_root}/block", 0)
    return list(dict.fromkeys(out))


def sink_block_uevents(root, targets):
    """bind the sink over each target without a sink bind"""
    sink = f"{root}{UEVENT_SINK_DIR}/uevent"
    try:
        st = os.stat(sink)
    except OSError as e:
        return 0, f"no-sink:{e.errno}"
    bound = 0
    for t in targets:
        try:
            ts = os.stat(t)
        except FileNotFoundError:
            continue
        except OSError as e:
            return bound, f"stat:{t[len(root):]}:{e.errno}"
        if (ts.st_dev, ts.st_ino) == (st.st_dev, st.st_ino):
            continue
        if not mount(sink, t, None, MS_BIND):
            return bound, f"bind:{t[len(root):]}"
        bound += 1
    return bound, ""


def sink_late_block_uevents(root, log, devpath=None):
    """sink the /sys/block uevents of a late-added device"""
    bound, why = sink_block_uevents(root, plan_block_uevents(f"{root}/sys", devpath))
    if why:
        log(f"RHIZO_MARKER block_sink=failed reason={why} bound={bound}")
    elif bound:
        log(f"RHIZO_MARKER block_sink=late bound={bound}")


def _shadow_block_uevents():
    """overmount each uevent file the vold cold boot writes"""
    sink_dir = NEWROOT + UEVENT_SINK_DIR
    targets = plan_block_uevents(f"{NEWROOT}/sys")
    why, bound, mounted = "", 0, False
    os.makedirs(sink_dir, exist_ok=True)
    if not mount("tmpfs", sink_dir, "tmpfs", MS_NOSUID|MS_NODEV|MS_NOEXEC, "mode=0755,size=4k"):
        why = "sink-tmpfs"
    else:
        mounted = True
        try:
            open(f"{sink_dir}/uevent", "w").close()
        except OSError as e:
            why = f"sink-file:{e.errno}"
        if not why and not mount(None, sink_dir, None,
                                 MS_REMOUNT|MS_RDONLY|MS_NOSUID|MS_NODEV|MS_NOEXEC):
            why = "sink-read-only"
        if not why:
            bound, why = sink_block_uevents(NEWROOT, targets)
    if why and mounted:
        libc.umount2(sink_dir.encode(), 2)
    if why:
        try:
            os.rmdir(sink_dir)
        except OSError:
            pass
        kmsg(f"RHIZO_MARKER coldboot_vold=failed reason={why} bound={bound}/{len(targets)}")
        return False
    kmsg(f"RHIZO_MARKER coldboot_vold=ok uevents={bound}")
    return True


IIO_DEVICE_DIR = re.compile(r"iio:device[0-9]+")


def plan_iio_masks(sys_root, declared):
    """return the declared devices' binds and all IIO device directories"""
    real = os.path.realpath(sys_root)
    bus = os.path.join(sys_root, "bus", "iio", "devices")
    try:
        names = sorted(n for n in os.listdir(bus) if IIO_DEVICE_DIR.fullmatch(n))
    except OSError:
        names = []
    masks = []
    for name in names:
        d = os.path.realpath(os.path.join(bus, name))
        if d.startswith(real + "/devices/") and os.path.isdir(d) and d not in masks:
            masks.append(d)
    binds, seen = [], set()
    for number, devpath in declared:
        if number not in seen:
            seen.add(number)
            src = real + devpath
            binds.append((src, number, src in masks))
    return binds, masks


def _mask_iio_devices():
    """bind declared IIO devices and mask all in sysfs"""
    declared = [(s["iio"], s["devpath"]) for s in core.sensors_plan()]
    binds, masks = plan_iio_masks(f"{NEWROOT}/sys", declared)
    bound, failed = 0, []
    top = NEWROOT + core.SENSORS_GUEST_DIR
    if binds:
        os.makedirs(top, mode=0o755, exist_ok=True)
    for src, number, present in binds:
        dst = f"{top}/{number}"
        if not present:
            failed.append(f"bind:{number}:gone")
            continue
        os.makedirs(dst, exist_ok=True)
        if not mount(src, dst, None, MS_BIND):
            failed.append(f"bind:{number}")
            continue
        if not mount(None, dst, None, MS_REMOUNT | MS_BIND | MS_RDONLY):
            libc.umount2(dst.encode(), 2)
            failed.append(f"bind-read-only:{number}")
            continue
        bound += 1
    masked = 0
    for d in masks:
        if mount("tmpfs", d, "tmpfs", MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=0555,size=4k"):
            masked += 1
        else:
            failed.append(f"mask:{d[len(NEWROOT):]}")
    kmsg(f"RHIZO_MARKER iio_mask={'failed' if failed else 'ok'} masked={masked}/{len(masks)} "
         f"bound={bound}/{len(binds)}" + (f" failed={','.join(failed[:6])}" if failed else ""))
    return not failed


SYSFS_WRITABLE = (
    ("tree", "/sys/devices/virtual/block"),
    ("tree", "/sys/devices/virtual/bdi"),
    ("tree", "/sys/kernel/wakeup_reasons"),
    ("file", "/sys/power/wake_lock"),
    ("file", "/sys/power/wake_unlock"),
    ("file", "/sys/power/wakeup_count"),
    ("file", "/sys/module/dm_bufio/parameters/max_age_seconds"),
    ("file", "/sys/module/dm_verity/parameters/prefetch_cluster"),
)
_SYSFS_SEAL_SET = MOUNT_ATTR_RDONLY | MOUNT_ATTR_NOSUID | MOUNT_ATTR_NODEV | MOUNT_ATTR_NOEXEC


def sysfs_foreign_below(mountinfo_text, sysmp):
    """return (fstype, mountpoint) for each mount at or under sysmp with an fstype other than sysfs and tmpfs"""
    out = []
    prefix = sysmp.rstrip("/") + "/"
    for line in mountinfo_text.splitlines():
        if " - " not in line:
            continue
        left, right = line.split(" - ", 1)
        lf, rf = left.split(), right.split()
        if len(lf) < 5 or not rf:
            continue
        mp, fstype = lf[4], rf[0]
        if (mp == sysmp or mp.startswith(prefix)) and fstype not in ("sysfs", "tmpfs"):
            out.append((fstype, mp))
    return out


def reopen_sysfs_file(path, log=kmsg):
    """bind path at path, clear MOUNT_ATTR_RDONLY and return bound, absent or failed"""
    if not os.path.exists(path):
        return "absent"
    if not mount(path, path, None, MS_BIND):
        log(f"RHIZO_MARKER sysfs_rw=failed path={path} step=bind errno={ctypes.get_errno()}")
        return "failed"
    if not mount_setattr(path, attr_clr=MOUNT_ATTR_RDONLY):
        err = ctypes.get_errno()
        libc.umount2(path.encode(), 2)
        log(f"RHIZO_MARKER sysfs_rw=failed path={path} step=clear errno={err} detached=1")
        return "failed"
    return "bound"


def reopen_sysfs_tree(path, log=kmsg):
    """bind path at path with MS_REC, clear MOUNT_ATTR_RDONLY recursively and return bound, absent or failed"""
    if not os.path.isdir(path):
        return "absent"
    if not mount(path, path, None, MS_BIND | MS_REC):
        log(f"RHIZO_MARKER sysfs_rw=failed path={path} step=bind errno={ctypes.get_errno()}")
        return "failed"
    if not mount_setattr(path, attr_clr=MOUNT_ATTR_RDONLY, recursive=True):
        err = ctypes.get_errno()
        libc.umount2(path.encode(), 2)
        log(f"RHIZO_MARKER sysfs_rw=failed path={path} step=clear errno={err} detached=1")
        return "failed"
    return "bound"


def seal_sysfs(newroot=None, log=None, mountinfo_text=None):
    """set _SYSFS_SEAL_SET recursively on newroot/sys and reopen the SYSFS_WRITABLE paths"""
    newroot = NEWROOT if newroot is None else newroot
    log = log or kmsg
    sysmp = newroot + "/sys"
    if not RHIZO_SYSFS_RO:
        log("RHIZO_MARKER sysfs_ro=off reason=knob")
        return
    text = mountinfo_text
    if text is None:
        try:
            text = open("/proc/self/mountinfo").read()
        except OSError as e:
            log(f"failed to read /proc/self/mountinfo ({e})")
            text = None
    if text is not None:
        foreign = sysfs_foreign_below(text, sysmp)
        if foreign:
            fs, mp = foreign[0]
            log(f"RHIZO_MARKER sysfs_ro=refused reason=foreign-below:{fs}:{mp}")
            os._exit(1)
    if not mount_setattr(sysmp, attr_set=_SYSFS_SEAL_SET, recursive=True):
        log(f"RHIZO_MARKER sysfs_ro=refused reason=seal errno={ctypes.get_errno()}")
        os._exit(1)
    bound, absent, failed = [], [], []
    for kind, rel in SYSFS_WRITABLE:
        path = newroot + rel
        status = (reopen_sysfs_tree if kind == "tree" else reopen_sysfs_file)(path, log)
        if status == "bound":
            bound.append(rel)
        elif status == "absent":
            absent.append(rel)
            log(f"RHIZO_MARKER sysfs_rw=absent path={rel} kind={kind}")
        else:
            failed.append(rel)
            if kind == "tree":
                log(f"RHIZO_MARKER sysfs_ro=refused reason=tree:{rel}")
                os._exit(1)
    log(f"RHIZO_MARKER sysfs_ro=sealed writable={len(bound)} bound={','.join(bound)} "
        f"absent={len(absent)} failed={len(failed)}")


AID_INPUT = 1004
INPUT_NODE_MODE = 0o660
INPUT_NODE_LABEL = "u:object_r:input_device:s0"
HIDRAW_NODE_LABEL = "u:object_r:hidraw_device:s0"
_EVENT_DEVNAME = re.compile(r"input/event[0-9]+")
_HIDRAW_DEVNAME = re.compile(r"hidraw[0-9]+")
_LEGACY_DEVNAME = re.compile(r"input/(mouse|js)[0-9]+")
INPUT_MAJOR = 13
_NODE_KIND = {"evdev": (AID_ROOT, AID_INPUT, INPUT_NODE_LABEL, False),
              "hidraw": (AID_SYSTEM, AID_SYSTEM, HIDRAW_NODE_LABEL, True)}
_STAGE_DIR_OF = {"evdev": selinux_ns.EVDEV_STAGE_DIR, "hidraw": selinux_ns.HIDRAW_STAGE_DIR}
_STAGE_FINAL_DIR = {"evdev": "/dev/input", "hidraw": "/dev"}
STAGE_DIR_MODE = 0o700
_IN_ONLYDIR, _IN_DONT_FOLLOW = 0x01000000, 0x02000000
BPF_MAP_UPDATE_ELEM, BPF_MAP_DELETE_ELEM = 2, 3
DEVICE_MAP_KEY = struct.Struct("<III")
_DEVCG_CHAR = 2


class DeviceFilterMap:
    """cgroup device filter BPF map of admitted input and hidraw devices"""

    def __init__(self, fd, bpf_fn):
        """store the map fd and bpf_fn"""
        self.fd, self.bpf_fn, self.admitted = fd, bpf_fn, set()

    def _elem(self, cmd, dev):
        """call bpf_fn(cmd) on the char key of dev and return 0 or the errno"""
        key = ctypes.create_string_buffer(DEVICE_MAP_KEY.pack(_DEVCG_CHAR, os.major(dev), os.minor(dev)),
                                          DEVICE_MAP_KEY.size)
        value = ctypes.create_string_buffer(struct.pack("<I", 1), 4)
        attr = struct.pack("<IxxxxQQQ", self.fd, ctypes.addressof(key),
                           ctypes.addressof(value) if cmd == BPF_MAP_UPDATE_ELEM else 0, 0)
        return 0 if self.bpf_fn(cmd, attr) == 0 else (ctypes.get_errno() or errno.EIO)

    def admit(self, dev):
        """add dev to the map and return 0 or the errno"""
        err = self._elem(BPF_MAP_UPDATE_ELEM, dev)
        if not err:
            self.admitted.add(dev)
        return err

    def revoke(self, dev):
        """remove dev from the map and return 0 for success or ENOENT, else the errno"""
        err = self._elem(BPF_MAP_DELETE_ELEM, dev)
        if err in (0, errno.ENOENT):
            self.admitted.discard(dev)
            return 0
        return err

    def close(self):
        """close the map fd"""
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1


def parse_uevent(buf):
    """parse a kernel uevent datagram into {key: value}"""
    if not buf or b"@" not in buf.split(b"\0", 1)[0]:
        return None
    head, *fields = buf.split(b"\0")
    ev = {}
    for f in fields:
        k, sep, v = f.partition(b"=")
        if sep:
            ev[k.decode(errors="replace")] = v.decode(errors="replace")
    action, _, devpath = head.decode(errors="replace").partition("@")
    ev.setdefault("ACTION", action)
    ev.setdefault("DEVPATH", devpath)
    return ev


def _under(devpath, owned):
    """return whether devpath is a registered device or under a registered device"""
    return any(devpath == p or devpath.startswith(p + "/") for p in owned)


class InputFence:
    """the publish or withhold decision for a sandbox's uevent stream"""

    def __init__(self, sys_root="/sys", devmap=None):
        """set empty owned, seen and published devices"""
        self.sys_root = sys_root
        self.owned = set()
        self.seen = {}
        self.published = {}
        self.inodes = {}
        self.devmap = devmap
        self.broken = ""
        self.stage = None

    def node_of(self, ev):
        """return (kind, /dev path, dev_t) for an evdev, hidraw, mouse or joystick uevent"""
        name = ev.get("DEVNAME", "")
        if _EVENT_DEVNAME.fullmatch(name) and ev.get("SUBSYSTEM") == "input":
            kind = "evdev"
        elif _HIDRAW_DEVNAME.fullmatch(name) and ev.get("SUBSYSTEM") == "hidraw":
            kind = "hidraw"
        elif (_LEGACY_DEVNAME.fullmatch(name) and ev.get("SUBSYSTEM") == "input"
              and ev.get("MAJOR") == str(INPUT_MAJOR)):
            kind = "legacy"
        else:
            return None
        try:
            dev = os.makedev(int(ev["MAJOR"]), int(ev["MINOR"]))
        except (KeyError, ValueError):
            return None
        return kind, "/dev/" + name, dev

    def decide(self, ev):
        """return the publish, withhold or remove decisions for a kernel uevent"""
        action, devpath = ev.get("ACTION"), ev.get("DEVPATH", "")
        if action == "remove":
            self.owned.discard(devpath)
        node = self.node_of(ev)
        if node is None:
            return []
        kind, path, dev = node
        if action == "remove":
            self.seen.pop(devpath, None)
            return [("remove", kind, path, dev, "")]
        if action != "add":
            return []
        if kind == "evdev" and os.major(dev) != INPUT_MAJOR:
            return [("withhold", kind, path, dev, f"major={os.major(dev)}")]
        self.seen[devpath] = node
        if _under(devpath, self.owned):
            return [("publish", kind, path, dev, "registered", devpath)]
        return [("withhold", kind, path, dev, "unregistered")]

    def register(self, verb, devpath):
        """return the decisions for a registry message"""
        if verb == "add":
            self.owned.add(devpath)
            return [("publish", k, p, d, "registered", dp) for dp, (k, p, d) in self.seen.items()
                    if _under(dp, {devpath})]
        if verb == "del":
            self.owned.discard(devpath)
            return [("withhold", k, p, d, "unregistered") for dp, (k, p, d) in self.seen.items()
                    if _under(dp, {devpath}) and p in self.published]
        return []

    def publishable(self):
        """return a publish decision for each seen registered node"""
        return [("publish", k, p, d, "registered", dp) for dp, (k, p, d) in self.seen.items()
                if _under(dp, self.owned)]

    def vanished(self):
        """return a remove decision for each published node with a sysfs dev value other than dev"""
        gone = []
        for devpath, (kind, path, dev) in list(self.seen.items()):
            if self.published.get(path) != dev:
                continue
            if _devnum(f"{self.sys_root}{devpath}/dev") == (os.major(dev), os.minor(dev)):
                continue
            self.seen.pop(devpath)
            gone.append(("remove", kind, path, dev, "vanished"))
        return gone


def _make_input_node(path, dev, st, ops):
    """mknod path unless path is a char node of dev"""
    for retry in (False, True):
        if st is not None:
            ops.unlink(path)
        old = ops.umask(0)
        try:
            ops.mknod(path, stat.S_IFCHR | INPUT_NODE_MODE, dev)
            return
        except FileExistsError:
            if retry:
                raise
        finally:
            ops.umask(old)
        try:
            st = ops.lstat(path)
        except FileNotFoundError:
            st = None
        if st is not None and stat.S_ISCHR(st.st_mode) and st.st_rdev == dev:
            return


def _admit_device(fence, node, dev, log):
    """return whether fence.devmap is None or fence.devmap.admit(dev) returns 0"""
    if fence.devmap is None:
        return True
    err = fence.devmap.admit(dev)
    if err:
        log(f"RHIZO_MARKER input_fence=failed reason=devfilter:{err} node={node}")
    return not err


def _revoke_device(fence, node, dev, log):
    """call fence.devmap.revoke(dev) and set fence.broken on an error"""
    if fence.devmap is None:
        return
    err = fence.devmap.revoke(dev)
    if err:
        fence.broken = f"devfilter-revoke:{err}"
        log(f"RHIZO_MARKER input_fence=failed reason={fence.broken} node={node}")


class _StageFailed(Exception):
    """exception for a failed step of a staged publish"""


def _break_stage(fence, why, log):
    """set fence.broken to stage:<why> and log RHIZO_MARKER input_fence=failed"""
    fence.broken = f"stage:{why}"
    log(f"RHIZO_MARKER input_fence=failed reason={fence.broken}")


def _stage_intact(stage, kind, ops):
    """return the reason the kind staging directory differs from stage.dirs[kind], or an empty string"""
    final_fd, stage_fd, ident = stage.dirs[kind]
    name = _STAGE_DIR_OF[kind].rsplit("/", 1)[1]
    try:
        named = ops.stat(name, dir_fd=final_fd, follow_symlinks=False)
        held = ops.fstat(stage_fd)
    except OSError as e:
        return f"gone:{e.errno}"
    if (named.st_dev, named.st_ino) != ident or (held.st_dev, held.st_ino) != ident:
        return "replaced"
    if not stat.S_ISDIR(named.st_mode) or (held.st_uid, held.st_gid, stat.S_IMODE(held.st_mode)) != (0, 0, STAGE_DIR_MODE):
        return "changed"
    return ""


def _mknodat_fresh(stage_fd, name, dev, ops):
    """unlink name in stage_fd and mknod name in stage_fd"""
    try:
        ops.unlink(name, dir_fd=stage_fd)
    except FileNotFoundError:
        pass
    old = ops.umask(0)
    try:
        ops.mknod(name, stat.S_IFCHR | INPUT_NODE_MODE, dev, dir_fd=stage_fd)
    finally:
        ops.umask(old)


def _drop_staged(final_fd, stage_fd, name, ino, at, ops):
    """unlink the staged name and the final name with inode ino after a failed publish and return the unlink failures"""
    left = ""
    names = ([(stage_fd, "staged")] if at in ("staged", "linked") else []) + \
            ([(final_fd, "final")] if at == "linked" else [])
    for dir_fd, which in names:
        try:
            if which == "final" and ops.stat(name, dir_fd=dir_fd, follow_symlinks=False).st_ino != ino:
                continue
            ops.unlink(name, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
        except OSError as e:
            left += f" {which}-remove-failed={e.errno}"
    return left


def _replace_same_device(final_fd, name, node, dev, node_fd, log, ops, fd_ops):
    """unlink a char node of dev at the final name and link node_fd at the final name"""
    try:
        there = ops.stat(name, dir_fd=final_fd, follow_symlinks=False)
    except OSError as e:
        raise _StageFailed(f"link:{e.errno}")
    if not stat.S_ISCHR(there.st_mode) or there.st_rdev != dev:
        raise _StageFailed("occupied")
    try:
        ops.unlink(name, dir_fd=final_fd)
    except FileNotFoundError:
        pass
    except OSError as e:
        raise _StageFailed(f"replace:{e.errno}")
    try:
        fd_ops.link_at(node_fd, final_fd, name)
    except FileExistsError:
        raise _StageFailed("occupied")
    except OSError as e:
        raise _StageFailed(f"link:{e.errno}")
    log(f"RHIZO_MARKER input_fence=replaced node={node} dev={os.major(dev)}:{os.minor(dev)}")
    return "linked"


def _make_staged_node(fence, node, kind, dev, st, log, ops, labels, fd_ops):
    """mknod the node in the staging directory, set the label and owner and link the node at the final name"""
    stage = fence.stage if fence is not None else None
    why = "none" if stage is None else _stage_intact(stage, kind, ops)
    if why:
        if fence is not None:
            _break_stage(fence, f"{kind}:{why}", log)
        return False
    final_fd, stage_fd, _ident = stage.dirs[kind]
    uid, gid, label, _host_relabel = _NODE_KIND[kind]
    name = node.rsplit("/", 1)[1]
    staged = f"{_STAGE_DIR_OF[kind]}/{name}"
    node_fd, ino, at = -1, None, ""
    try:
        try:
            _mknodat_fresh(stage_fd, name, dev, ops)
            at = "staged"
            node_fd = fd_ops.open_path_at(stage_fd, name)
            made = fd_ops.fstat(node_fd)
        except OSError as e:
            raise _StageFailed(f"mknod:{e.errno}")
        if not stat.S_ISCHR(made.st_mode) or made.st_rdev != dev or made.st_nlink != 1:
            raise _StageFailed("label:<not-the-node>")
        ino = made.st_ino
        got = labels.set(staged, dev, ino, made.st_dev)
        if got != label:
            raise _StageFailed(f"relabel:{got}")
        try:
            fd_ops.fchown(node_fd, uid, gid)
            fd_ops.fchmod(node_fd, INPUT_NODE_MODE)
        except OSError as e:
            raise _StageFailed(f"chown:{e.errno}")
        try:
            if st is not None:
                ops.unlink(name, dir_fd=final_fd)
            fd_ops.link_at(node_fd, final_fd, name)
            at = "linked"
        except FileExistsError:
            at = _replace_same_device(final_fd, name, node, dev, node_fd, log, ops, fd_ops)
        except OSError as e:
            raise _StageFailed(f"link:{e.errno}")
        try:
            final = ops.stat(name, dir_fd=final_fd, follow_symlinks=False)
        except OSError as e:
            raise _StageFailed(f"final:{e.errno}")
        if not stat.S_ISCHR(final.st_mode) or final.st_rdev != dev or final.st_ino != ino:
            raise _StageFailed("label:<not-the-node>")
        try:
            ops.unlink(name, dir_fd=stage_fd)
        except OSError as e:
            raise _StageFailed(f"stage-unlink:{e.errno}")
        fence.inodes[node] = (final.st_dev, final.st_ino)
    except _StageFailed as f:
        log(f"RHIZO_MARKER input_fence=failed reason={f.args[0]} node={node}"
            f"{_drop_staged(final_fd, stage_fd, name, ino, at, ops)}")
        return False
    finally:
        if node_fd >= 0:
            fd_ops.close(node_fd)
    return True


def _make_and_label_node(node, path, dev, st, kind, log, ops, labels, fd_ops, fence=None):
    """mknod, relabel and chown the node and return whether each step succeeded"""
    if labels is not None:
        if labels.unusable():
            log(f"RHIZO_MARKER input_fence=failed reason=label:{labels.unusable()} node={node}")
            return False
        return _make_staged_node(fence, node, kind, dev, st, log, ops, labels, fd_ops or selinux_ns.NODE_FD)
    uid, gid, label, host_relabel = _NODE_KIND[kind]
    try:
        _make_input_node(path, dev, st, ops)
    except OSError as e:
        log(f"RHIZO_MARKER input_fence=failed reason=mknod:{e.errno} node={node}")
        return False
    try:
        if host_relabel:
            ops.setxattr(path, "security.selinux", (label + "\0").encode())
    except OSError as e:
        try:
            ops.unlink(path)
            gone = ""
        except OSError as u:
            gone = f" remove-failed={u.errno}"
        log(f"RHIZO_MARKER input_fence=failed reason=relabel:{e.errno} node={node}{gone}")
        return False
    try:
        ops.chown(path, uid, gid)
        ops.chmod(path, INPUT_NODE_MODE)
    except OSError as e:
        log(f"RHIZO_MARKER input_fence=failed reason=chown:{e.errno} node={node}")
        return False
    try:
        got = ops.getxattr(path, "security.selinux").decode(errors="replace").rstrip("\0")
    except OSError:
        got = "<unread>"
    if got != label:
        log(f"RHIZO_MARKER input_fence=failed reason=label:{got} node={node}")
        return False
    return True


def apply_input_decision(fence, decision, root="", log=None, ops=os, labels=None, fd_ops=None):
    """make or remove a node under root"""
    log = log or kmsg
    op, kind, node, dev, why, *extra = decision
    devpath = extra[0] if extra else ""
    path = root + node
    try:
        st = ops.lstat(path)
    except OSError:
        st = None
    ours = st is not None and stat.S_ISCHR(st.st_mode) and st.st_rdev == dev
    if op in ("remove", "withhold"):
        gone = ""
        if ours:
            try:
                ops.unlink(path)
                gone = " removed=" + ("device-gone" if op == "remove" else
                                      "published" if node in fence.published else "permissive-window")
            except OSError as e:
                gone = f" remove-failed={e.errno}"
        fence.inodes.pop(node, None)
        fence.published.pop(node, None)
        _revoke_device(fence, node, dev, log)
        if op == "withhold":
            log(f"RHIZO_MARKER input_fence=withheld node={node} "
                f"dev={os.major(dev)}:{os.minor(dev)} {why}{gone}")
        return
    if not _admit_device(fence, node, dev, log):
        return
    if devpath:
        cur = _devnum(f"{fence.sys_root}{devpath}/dev")
        if cur is not None and cur != (os.major(dev), os.minor(dev)):
            _revoke_device(fence, node, dev, log)
            log(f"RHIZO_MARKER input_fence=withheld node={node} "
                f"dev={os.major(dev)}:{os.minor(dev)} reason=sysfs-reused")
            return
    if kind == "legacy":
        fence.published[node] = dev
        log(f"RHIZO_MARKER input_fence=admitted node={node}")
        return
    if ours and (labels is None or fence.inodes.get(node) == (st.st_dev, st.st_ino)):
        fence.published[node] = dev
        return
    if not _make_and_label_node(node, path, dev, st, kind, log, ops, labels, fd_ops, fence):
        _revoke_device(fence, node, dev, log)
        return
    fence.published[node] = dev
    log(f"RHIZO_MARKER input_fence=published node={node}")


def _usb_node_entries(root, ops, fds):
    """return (bus fd, name, node) for the entries of each /dev/bus/usb/<bus> opened with O_NOFOLLOW"""
    out = []
    try:
        fds.append(_open_dir_at(None, root + "/dev/bus", ops, os.O_PATH))
        fds.append(_open_dir_at(fds[-1], "usb", ops))
        buses = ops.listdir(fds[-1])
    except OSError:
        return out
    usb_fd = fds[-1]
    for bus in buses:
        try:
            fds.append(_open_dir_at(usb_fd, bus, ops))
            out += [(fds[-1], n, f"/dev/bus/usb/{bus}/{n}") for n in ops.listdir(fds[-1])]
        except OSError:
            continue
    return out


def _host_node_entries(root, ops, fds):
    """return (directory fd or None, name or path, node) for the input and usb nodes under root"""
    out = []
    for d, pattern in (("/dev/input", r"event[0-9]+"), ("/dev", r"hidraw[0-9]+")):
        try:
            out += [(None, f"{root}{d}/{n}", f"{d}/{n}") for n in ops.listdir(root + d) if re.fullmatch(pattern, n)]
        except OSError:
            pass
    return out + _usb_node_entries(root, ops, fds)


def reconcile_input(fence, root="", log=None, ops=os):
    """remove the input nodes outside fence.published"""
    log = log or kmsg
    fds = []
    try:
        for dir_fd, name, node in _host_node_entries(root, ops, fds):
            try:
                st = ops.lstat(name) if dir_fd is None else ops.stat(name, dir_fd=dir_fd, follow_symlinks=False)
            except OSError:
                continue
            if not stat.S_ISCHR(st.st_mode) or fence.published.get(node) == st.st_rdev:
                continue
            try:
                if dir_fd is None:
                    ops.unlink(name)
                else:
                    ops.unlink(name, dir_fd=dir_fd)
                log(f"RHIZO_MARKER input_fence=withheld node={node} "
                    f"dev={os.major(st.st_rdev)}:{os.minor(st.st_rdev)} removed=reconcile")
            except OSError as e:
                log(f"RHIZO_MARKER input_fence=failed reason=unlink:{e.errno} node={node}")
    finally:
        for fd in fds:
            ops.close(fd)
    if getattr(fence, "stage", None) is not None:
        _sweep_stage(fence, log, ops)
    if getattr(fence, "watch", None) is not None:
        for d in ("/dev/bus", "/dev/bus/usb") + tuple(
                "/dev/bus/usb/" + b for b in _listdir_or_empty(ops, root + "/dev/bus/usb")):
            libc.inotify_add_watch(fence.watch, (root + d).encode(), 0x100 | 0x80 | _IN_ONLYDIR | _IN_DONT_FOLLOW)


class InputStage:
    """staging directory fds and final directory fds of the input fence"""

    def __init__(self):
        """set empty dirs"""
        self.dirs = {}

    def close(self, ops=os):
        """close the fds in dirs"""
        for final_fd, stage_fd, _ident in self.dirs.values():
            for fd in (final_fd, stage_fd):
                if fd >= 0:
                    ops.close(fd)
        self.dirs = {}


def _open_dir_at(dir_fd, name, ops, flags=os.O_RDONLY):
    """open name in dir_fd with O_DIRECTORY and O_NOFOLLOW"""
    return ops.open(name, flags | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)


def _roots_0700(st, final_st):
    """return whether st is a 0700 directory of uid 0 and gid 0 on the final_st device"""
    return (stat.S_ISDIR(st.st_mode) and (st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode)) == (0, 0, STAGE_DIR_MODE)
            and st.st_dev == final_st.st_dev)


def _clear_left_stage(final_fd, name, final_st, ops):
    """unlink the entries of a leftover staging directory and rmdir the directory"""
    fd = _open_dir_at(final_fd, name, ops)
    try:
        if not _roots_0700(ops.fstat(fd), final_st):
            return "left:not-roots-0700"
        for entry in ops.listdir(fd):
            ops.unlink(entry, dir_fd=fd)
    finally:
        ops.close(fd)
    ops.rmdir(name, dir_fd=final_fd)
    return ""


def _prepare_stage_dir(stage, kind, root, ops):
    """create and open the kind staging directory in stage.dirs and return the failure reason, or an empty string"""
    name = _STAGE_DIR_OF[kind].rsplit("/", 1)[1]
    try:
        final_fd = _open_dir_at(None, root + _STAGE_FINAL_DIR[kind], ops, os.O_PATH)
    except OSError as e:
        return f"final:{e.errno}"
    stage.dirs[kind] = (final_fd, -1, None)
    try:
        final_st = ops.fstat(final_fd)
        try:
            left = ops.stat(name, dir_fd=final_fd, follow_symlinks=False)
        except FileNotFoundError:
            left = None
        if left is not None:
            why = "left:not-a-directory" if not stat.S_ISDIR(left.st_mode) else _clear_left_stage(final_fd, name, final_st, ops)
            if why:
                return why
        ops.mkdir(name, STAGE_DIR_MODE, dir_fd=final_fd)
        fd = _open_dir_at(final_fd, name, ops)
        stage.dirs[kind] = (final_fd, fd, None)
        ops.fchown(fd, 0, 0)
        ops.fchmod(fd, STAGE_DIR_MODE)
        st = ops.fstat(fd)
        named = ops.stat(name, dir_fd=final_fd, follow_symlinks=False)
    except OSError as e:
        return f"{e.errno}"
    if not _roots_0700(st, final_st) or (named.st_dev, named.st_ino) != (st.st_dev, st.st_ino):
        return "not-roots-0700"
    stage.dirs[kind] = (final_fd, fd, (st.st_dev, st.st_ino))
    return ""


def prepare_input_stage(root="", log=None, ops=os):
    """return an InputStage of the evdev and hidraw staging directories, or None"""
    log = log or kmsg
    stage = InputStage()
    for kind in ("evdev", "hidraw"):
        why = _prepare_stage_dir(stage, kind, root, ops)
        if why:
            log(f"RHIZO_MARKER input_fence=failed reason=stage:{why} path={_STAGE_DIR_OF[kind]}")
            stage.close(ops)
            return None
    return stage


def _sweep_stage(fence, log, ops):
    """unlink the entries of the staging directories through stage_fd and call _break_stage on a failure"""
    for kind, (_final_fd, stage_fd, _ident) in list(fence.stage.dirs.items()):
        why = _stage_intact(fence.stage, kind, ops)
        if why:
            _break_stage(fence, f"{kind}:{why}", log)
            return
        try:
            entries = ops.listdir(stage_fd)
        except OSError as e:
            _break_stage(fence, f"{kind}:list:{e.errno}", log)
            return
        for entry in entries:
            staged = f"{_STAGE_DIR_OF[kind]}/{entry}"
            try:
                ops.unlink(entry, dir_fd=stage_fd)
            except OSError as e:
                _break_stage(fence, f"{kind}:entry:{e.errno}:{entry}", log)
                return
            log(f"RHIZO_MARKER input_fence=withheld node={staged} removed=reconcile")


def _listdir_or_empty(ops, d):
    """return the entries of d, or an empty list on an error"""
    try:
        return ops.listdir(d)
    except OSError:
        return []


def _peer_uid(conn):
    """return the uid of a unix socket's peer"""
    import socket
    import struct as _struct
    creds = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, _struct.calcsize("3i"))
    return _struct.unpack("3i", creds)[1]


LABEL_REPLY_S = 5
LABEL_MSG_MAX = 512
LABEL_TEXT_MAX = 64


def _marker_text(text, limit):
    """return text cut to limit with whitespace made underscores"""
    return re.sub(r"\s", "_", text[:limit])


def _drop_reason(msg):
    """return a marker-safe reason for an unexpected label service message"""
    if msg is None:
        return "timeout"
    return _marker_text(msg.decode(errors="replace"), 120) if msg else "eof"


class LabelClient:
    """fence connection to the label service"""

    def __init__(self, listener, log=None, gone=""):
        """store the listener, the log and the gone reason"""
        self.listener, self.conn, self.ready, self.gone = listener, None, False, gone
        self.deadline = self.deadline_s = None
        self.log = log or kmsg

    def start_deadline(self, seconds):
        """set the deadline to time.monotonic() + seconds"""
        self.deadline_s = seconds
        self.deadline = time.monotonic() + seconds

    def _expire(self):
        """drop the client after the deadline"""
        if not self.ready and not self.gone and self.deadline is not None and time.monotonic() >= self.deadline:
            self._drop("never-connected" if self.conn is None else "never-ready")

    def wait_s(self):
        """return seconds left to the deadline, or None"""
        if self.ready or self.gone or self.deadline is None:
            return None
        return max(0.0, self.deadline - time.monotonic())

    def fds(self):
        """return the listener or connection to select on"""
        self._expire()
        if self.gone:
            return []
        return [self.listener if self.conn is None else self.conn]

    def pending(self):
        """return whether the label service is neither ready nor gone"""
        self._expire()
        return not self.ready and not self.gone

    def unusable(self):
        """return the label service pending or gone reason, or an empty string"""
        if self.pending():
            return "<label-service-pending>"
        return f"<label-service-{self.gone}>" if self.gone else ""

    def close(self):
        """close the listener and the connection"""
        for s in (self.listener, self.conn):
            if s is not None:
                s.close()

    def _drop(self, why):
        """close the label service sockets and log the reason"""
        self.gone = why
        self.close()
        self.log(f"RHIZO_MARKER input_fence=label-service state=gone reason={why}")

    def handle(self):
        """call accept on the label service listener or read the ready line"""
        try:
            if self.conn is None:
                conn, _ = self.listener.accept()
                uid = _peer_uid(conn)
                if uid != 0:
                    self.log(f"RHIZO_MARKER input_fence=dropped reason=label-peer-uid:{uid}")
                    conn.close()
                    return False
                self.listener.close()
                self.listener, self.conn = None, conn
                if self.deadline_s is not None:
                    self.start_deadline(self.deadline_s)
                return False
            msg = self.conn.recv(LABEL_MSG_MAX)
        except OSError as e:
            self._drop(f"socket:{e.errno}")
            return False
        if msg == b"ready" and not self.ready:
            self.ready = True
            self.log("RHIZO_MARKER input_fence=label-service state=ready")
            return True
        self._drop(_drop_reason(msg))
        return False

    def set(self, node, dev, ino, sdev):
        """write a set line for node to the label service and return the label reply, or <reason>"""
        import select
        try:
            self.conn.send(f"set {node} {os.major(dev)}:{os.minor(dev)} {ino} {sdev}".encode())
            ready, _, _ = select.select([self.conn], [], [], LABEL_REPLY_S)
            reply = self.conn.recv(LABEL_MSG_MAX) if ready else None
        except OSError as e:
            self._drop(f"socket:{e.errno}")
            return self.unusable()
        if reply and reply.startswith(b"label "):
            return _marker_text(reply[len(b"label "):].decode(errors="replace"), LABEL_TEXT_MAX)
        if reply and reply.startswith((b"refused:", b"failed:")):
            return f"<{_marker_text(reply.decode(errors='replace'), LABEL_TEXT_MAX)}>"
        self._drop(_drop_reason(reply))
        return self.unusable()


class FenceLoop:
    """state for a running fence"""

    def __init__(self, fence, sock, root="", log=None, ops=os, watch_fd=None, registry=None,
                 registrar_uid=0, labels=None, fd_ops=None):
        """store the fence loop's state"""
        self.fence, self.sock, self.root, self.ops = fence, sock, root, ops
        self.log = log or kmsg
        self.watch_fd, self.registry, self.registrar_uid = watch_fd, registry, registrar_uid
        self.labels, self.fd_ops = labels, fd_ops
        if labels is not None:
            labels.start_deadline(selinux_ns.RELABELLER_DEADLINE_S)
        self.conns = []
        self.done = False

    def fds(self):
        """return the fds the loop selects on"""
        return [self.sock] + ([self.watch_fd] if self.watch_fd is not None else []) + \
               ([self.registry] if self.registry is not None else []) + self.conns + \
               (self.labels.fds() if self.labels is not None else [])

    def wait_s(self):
        """return seconds left to the label deadline"""
        return self.labels.wait_s() if self.labels is not None else None

    def _apply(self, decisions):
        """apply each fence decision or defer the publish, and set done on fence.broken"""
        if self.fence.broken:
            self.done = True
            return
        for d in decisions:
            if d[0] == "publish" and self.labels is not None and self.labels.pending():
                self.log(f"RHIZO_MARKER input_fence=deferred node={d[2]} reason=label-service-pending")
                continue
            apply_input_decision(self.fence, d, self.root, self.log, self.ops, self.labels, self.fd_ops)
            if self.fence.broken:
                self.done = True
                return

    def handle(self, ready):
        """read uevents and registrations off the ready fds"""
        fence, root, log, ops = self.fence, self.root, self.log, self.ops
        if self.labels is not None and any(f in ready for f in self.labels.fds()) and self.labels.handle():
            self._apply(fence.publishable())
        if self.watch_fd in ready:
            try:
                os.read(self.watch_fd, 65536)
            except BlockingIOError:
                pass
            reconcile_input(fence, root, log, ops)
            if fence.broken:
                self.done = True
                return
        if self.registry is not None and self.registry in ready:
            conn, _ = self.registry.accept()
            if _peer_uid(conn) != self.registrar_uid:
                log(f"RHIZO_MARKER input_fence=dropped reason=registrar-uid:{_peer_uid(conn)}")
                conn.close()
            else:
                self.conns.append(conn)
        for conn in [c for c in self.conns if c in ready]:
            try:
                msg = conn.recv(1024).decode(errors="replace")
            except OSError:
                msg = ""
            if not msg:
                self.conns.remove(conn)
                conn.close()
                continue
            verb, _, devpath = msg.partition(" ")
            self._apply(fence.register(verb, devpath))
        if self.sock not in ready:
            return
        try:
            buf, addr = self.sock.recvfrom(65536)
        except OSError as e:
            if e.errno == errno.ENOBUFS:
                log("RHIZO_MARKER input_fence=failed reason=overrun")
                self._apply(fence.vanished())
                reconcile_input(fence, root, log, ops)
                if fence.broken:
                    self.done = True
                sink_late_block_uevents(root, log)
                return
            log(f"RHIZO_MARKER input_fence=failed reason=recv:{e.errno}")
            self.done = True
            return
        if not buf:
            self.done = True
            return
        if not (isinstance(addr, tuple) and addr and addr[0] == 0):
            log(f"RHIZO_MARKER input_fence=dropped reason=sender:{addr!r}")
            return
        ev = parse_uevent(buf)
        if ev and ev.get("SUBSYSTEM") == "block" and ev.get("ACTION") in ("add", "move"):
            sink_late_block_uevents(root, log, ev.get("DEVPATH"))
        if ev:
            self._apply(fence.decide(ev))

    def fail(self, why):
        """stop the fence and remove the published nodes"""
        self.done = True
        self.log(f"RHIZO_MARKER input_fence=failed reason={why}")
        for node, dev in list(self.fence.published.items()):
            apply_input_decision(self.fence, ("withhold", None, node, dev, "fence-failed"),
                                 self.root, self.log, self.ops)


def relay_step(relay, method, *args, default=None):
    """call getattr(relay, method)(*args) and call relay.stop on an exception"""
    if relay is None or relay.done:
        return default
    try:
        return getattr(relay, method)(*args)
    except Exception as e:
        try:
            relay.stop(f"raised:{e.__class__.__name__}:{e}"[:200])
        except Exception:
            relay.done = True
        return default


def fence_wait_step(holder_fd, loop, timeout, kill_holder, select_fn=None, relay=None):
    """call select on the pidfd, fence and relay descriptors"""
    if select_fn is None:
        import select
        select_fn = select.select
    live = loop is not None and not loop.done
    side = relay_step(relay, "fds", default=[])
    side_wait = relay_step(relay, "wait_s")
    try:
        fds = [holder_fd] + (loop.fds() if live else [])
        label_wait = loop.wait_s() if live else None
        for wait in (label_wait, side_wait):
            if wait is not None and (timeout is None or wait < timeout):
                timeout = wait
        try:
            ready, _, _ = select_fn(fds + side, [], [], timeout)
        except (OSError, ValueError) as e:
            if not side:
                raise
            relay_step(relay, "stop", f"select:{e.__class__.__name__}:{e}"[:200])
            ready, _, _ = select_fn(fds, [], [], timeout)
        if holder_fd in ready:
            return True
        if live and ready:
            loop.handle(ready)
        relay_step(relay, "handle", ready)
    except Exception as e:
        if not live:
            raise
        why = f"raised:{e.__class__.__name__}:{e}"
    else:
        if not (live and loop.done):
            return False
        why = "stopped"
    try:
        loop.fail(why)
    finally:
        kill_holder()
    return False


def start_fence_or_kill(registry, kill_holder, start=None, log=None, labels=None, devmap=None):
    """return the FenceLoop for g's wait"""
    loop = start(registry) if start is not None else start_input_fence(registry, labels=labels, devmap=devmap)
    if loop is None:
        (log or kmsg)("RHIZO_MARKER input_fence=failed reason=start")
        kill_holder()
    return loop


def run_input_fence(fence, sock, root="", log=None, stop=lambda: False, ops=os, watch_fd=None,
                    registry=None, registrar_uid=0):
    """run a FenceLoop until stop() or EOF"""
    import select
    loop = FenceLoop(fence, sock, root, log, ops, watch_fd, registry, registrar_uid)
    while not stop() and not loop.done:
        ready, _, _ = select.select(loop.fds(), [], [], loop.wait_s())
        loop.handle(ready)


UI_DEV_CREATE = 0x5501
SECCOMP_NR = {HOST_ARCH_AMD64: 317, "aarch64": 277}
_SECCOMP_SET_MODE_FILTER, _SECCOMP_FILTER_FLAG_NEW_LISTENER = 1, 1 << 3
_SECCOMP_RET_ALLOW, _SECCOMP_RET_USER_NOTIF, _SECCOMP_RET_ERRNO = 0x7fff0000, 0x7fc00000, 0x00050000
_IOCTL_NR = {0xc000003e: (16, 0x40000000 | 514), 0x40000003: (54,),
             0xc00000b7: (29,), 0x40000028: (54,)}
OPEN_BY_HANDLE_NR = {0xc000003e: (304, 0x40000000 | 304), 0x40000003: (342,),
                     0xc00000b7: (265,), 0x40000028: (371,)}


class _SockFprog(ctypes.Structure):
    """struct sock_fprog {unsigned short len; struct sock_filter *filter;}"""
    _fields_ = [("len", ctypes.c_ushort), ("filter", ctypes.c_void_p)]


def cuse_devnum(name, sys_root="/sys", wait_s=10):
    """return the dev_t of CUSE device name"""
    path = f"{sys_root}/class/cuse/{name}/dev"
    deadline = time.monotonic() + wait_s
    while True:
        try:
            with open(path) as f:
                major, minor = f.read().split(":")
            return os.makedev(int(major), int(minor))
        except (OSError, ValueError):
            if time.monotonic() >= deadline:
                raise OSError(errno.ENOENT, f"no {path} after {wait_s}s")
            time.sleep(0.1)


def input_run_dir(sandbox_id):
    """return the host directory of an instance's input sockets"""
    return f"/run/rhizo-input-{sandbox_id}"


def label_socket_path(sandbox_id):
    """return the host path of an instance's label socket"""
    return f"{input_run_dir(sandbox_id)}/label.sock"


def _assemble_bpf(prog):
    """return the bytes of a labeled ld, jeq and ret program"""
    LD, JEQ, RET = 0x20, 0x15, 0x06
    at, n = {}, 0
    for ins in prog:
        if ins[0] == "label":
            at[ins[1]] = n
        else:
            n += 1
    out, pc = [], 0
    for ins in prog:
        if ins[0] == "label":
            continue
        if ins[0] == "ld":
            out.append(struct.pack("<HBBI", LD, 0, 0, ins[1]))
        elif ins[0] == "ret":
            out.append(struct.pack("<HBBI", RET, 0, 0, ins[1]))
        else:
            out.append(struct.pack("<HBBI", JEQ, at[ins[2]] - pc - 1, at[ins[3]] - pc - 1, ins[1]))
        pc += 1
    return b"".join(out)


def uinput_notify_program(action=_SECCOMP_RET_USER_NOTIF):
    """return the BPF program filtering ioctl(UI_DEV_CREATE)"""
    arches = list(_IOCTL_NR)
    prog = [("ld", 4)]
    for i, arch in enumerate(arches):
        prog += [("label", f"arch{i}"),
                 ("jeq", arch, arch, f"arch{i + 1}" if i + 1 < len(arches) else "allow")]
    for arch, nrs in _IOCTL_NR.items():
        prog += [("label", arch), ("ld", 0)]
        for i, nr in enumerate(nrs):
            prog.append(("jeq", nr, "cmd", "allow" if i == len(nrs) - 1 else f"{arch}{i + 1}"))
            if i < len(nrs) - 1:
                prog.append(("label", f"{arch}{i + 1}"))
    prog += [("label", "cmd"), ("ld", 24), ("jeq", UI_DEV_CREATE, "notify", "allow"),
             ("label", "notify"), ("ret", action),
             ("label", "allow"), ("ret", _SECCOMP_RET_ALLOW)]
    return _assemble_bpf(prog)


BPF_SYSCALL_NR = {0xc000003e: (321, 0x40000000 | 321), 0x40000003: (357,),
                  0xc00000b7: (280,), 0x40000028: (386,)}
BPF_BY_ID_CMDS = (13, 14, 30)


def open_by_handle_program():
    """return the BPF program failing open_by_handle_at with EPERM"""
    prog = [("ld", 4)]
    for i, (arch, nrs) in enumerate(OPEN_BY_HANDLE_NR.items()):
        prog += [("jeq", arch, f"arch{i}", f"next{i}"), ("label", f"arch{i}"), ("ld", 0)]
        for j, nr in enumerate(nrs):
            prog += [("jeq", nr, "deny", f"nr{i}.{j}"), ("label", f"nr{i}.{j}")]
        prog += [("ret", _SECCOMP_RET_ALLOW), ("label", f"next{i}")]
    prog += [("ret", _SECCOMP_RET_ALLOW), ("label", "deny"), ("ret", _SECCOMP_RET_ERRNO | errno.EPERM)]
    return _assemble_bpf(prog)


def bpf_by_id_program():
    """return the BPF program failing a bpf() fd-by-id lookup with EPERM"""
    prog = [("ld", 4)]
    for i, (arch, nrs) in enumerate(BPF_SYSCALL_NR.items()):
        prog += [("jeq", arch, f"arch{i}", f"next{i}"), ("label", f"arch{i}"), ("ld", 0)]
        for j, nr in enumerate(nrs):
            prog += [("jeq", nr, "cmd", f"nr{i}.{j}"), ("label", f"nr{i}.{j}")]
        prog += [("ret", _SECCOMP_RET_ALLOW), ("label", f"next{i}")]
    prog += [("ret", _SECCOMP_RET_ALLOW), ("label", "cmd"), ("ld", 16)]
    for n, cmd in enumerate(BPF_BY_ID_CMDS):
        prog += [("jeq", cmd, "deny", f"cmd{n}"), ("label", f"cmd{n}")]
    prog += [("ret", _SECCOMP_RET_ALLOW), ("label", "deny"), ("ret", _SECCOMP_RET_ERRNO | errno.EPERM)]
    return _assemble_bpf(prog)


MOUNT_SETATTR_SECCOMP_NR = {0xc000003e: (442, 0x40000000 | 442), 0x40000003: (442,),
                            0xc00000b7: (442,), 0x40000028: (442,)}


def mount_setattr_program():
    """return the BPF program failing mount_setattr with EPERM"""
    prog = [("ld", 4)]
    for i, (arch, nrs) in enumerate(MOUNT_SETATTR_SECCOMP_NR.items()):
        prog += [("jeq", arch, f"arch{i}", f"next{i}"), ("label", f"arch{i}"), ("ld", 0)]
        for j, nr in enumerate(nrs):
            prog += [("jeq", nr, "deny", f"nr{i}.{j}"), ("label", f"nr{i}.{j}")]
        prog += [("ret", _SECCOMP_RET_ALLOW), ("label", f"next{i}")]
    prog += [("ret", _SECCOMP_RET_ALLOW), ("label", "deny"), ("ret", _SECCOMP_RET_ERRNO | errno.EPERM)]
    return _assemble_bpf(prog)


PERF_EVENT_OPEN_NR = {0xc000003e: (298, 0x40000000 | 298), 0x40000003: (336,),
                      0xc00000b7: (241,), 0x40000028: (364,)}


def perf_event_open_program():
    """return the BPF program failing perf_event_open with EPERM"""
    prog = [("ld", 4)]
    for i, (arch, nrs) in enumerate(PERF_EVENT_OPEN_NR.items()):
        prog += [("jeq", arch, f"arch{i}", f"next{i}"), ("label", f"arch{i}"), ("ld", 0)]
        for j, nr in enumerate(nrs):
            prog += [("jeq", nr, "deny", f"nr{i}.{j}"), ("label", f"nr{i}.{j}")]
        prog += [("ret", _SECCOMP_RET_ALLOW), ("label", f"next{i}")]
    prog += [("ret", _SECCOMP_RET_ALLOW), ("label", "deny"), ("ret", _SECCOMP_RET_ERRNO | errno.EPERM)]
    return _assemble_bpf(prog)


def install_handle_filter(log=None):
    """install the open_by_handle_at, bpf fd-by-id, perf_event_open and mount_setattr seccomp filters on the calling task"""
    log = log or kmsg
    nr = SECCOMP_NR.get(HOST_ARCH)
    if nr is None:
        log(f"RHIZO_MARKER handle_filter=failed reason=no-seccomp-nr arch={HOST_ARCH}")
        return False
    progs = [(open_by_handle_program(), "open_by_handle_at"), (bpf_by_id_program(), "bpf-by-id")]
    if RHIZO_PERF_FILTER:
        progs.append((perf_event_open_program(), "perf_event_open"))
    if RHIZO_SYSFS_RO:
        progs.append((mount_setattr_program(), "mount_setattr"))
    for prog, rule in progs:
        buf = ctypes.create_string_buffer(prog, len(prog))
        fprog = struct_pack_fprog(len(prog) // 8, ctypes.addressof(buf))
        if libc.syscall(nr, _SECCOMP_SET_MODE_FILTER, 0, fprog) < 0:
            log(f"RHIZO_MARKER handle_filter=failed errno={ctypes.get_errno()} rule={rule}")
            return False
    log(f"RHIZO_MARKER handle_filter=installed perf_filter={'on' if RHIZO_PERF_FILTER else 'off'} "
        f"sysfs_filter={'on' if RHIZO_SYSFS_RO else 'off'}")
    return True


def start_input_units(sandbox_id, log=None):
    """start rhizo-inputd@ and rhizo-inputd-uhid@ for sandbox_id"""
    log = log or kmsg
    units = [f"rhizo-inputd@{sandbox_id}.service", f"rhizo-inputd-uhid@{sandbox_id}.service"]
    try:
        r = subprocess.run(["systemctl", "start", "--no-block"] + units, capture_output=True,
                           text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"RHIZO_MARKER input_owner=failed reason=units:{e}")
        return
    if r.returncode != 0:
        log(f"RHIZO_MARKER input_owner=failed reason=units:{r.returncode} {r.stderr.strip()[:160]}")


def connect_input_supervisor(sandbox_id, log=None, path=None, wait_s=10):
    """connect to the rhizo-inputd supervisor.sock for sandbox_id"""
    import socket
    log = log or kmsg
    path = path or f"{input_run_dir(sandbox_id)}/supervisor.sock"
    deadline = time.monotonic() + wait_s
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        try:
            s.connect(path)
            return s
        except OSError as e:
            s.close()
            if e.errno in (errno.ENOENT, errno.ECONNREFUSED) and time.monotonic() < deadline:
                time.sleep(0.1)
                continue
            log(f"RHIZO_MARKER input_owner=failed reason=supervisor:{e.errno} path={path}")
            return None


def install_uinput_filter(sup, log=None):
    """install the UI_DEV_CREATE seccomp filter and pass the listener fd to the supervisor"""
    import socket
    log = log or kmsg
    notify = sup is not None
    prog = uinput_notify_program(_SECCOMP_RET_USER_NOTIF if notify else _SECCOMP_RET_ERRNO | errno.ENOSYS)
    buf = ctypes.create_string_buffer(prog, len(prog))
    fprog = struct_pack_fprog(len(prog) // 8, ctypes.addressof(buf))
    nr = SECCOMP_NR.get(HOST_ARCH)
    if nr is None:
        log(f"RHIZO_MARKER input_owner=failed reason=seccomp:no-nr-for-{HOST_ARCH}")
        return ""
    rc = libc.syscall(nr, _SECCOMP_SET_MODE_FILTER,
                      _SECCOMP_FILTER_FLAG_NEW_LISTENER if notify else 0, fprog)
    if rc < 0:
        log(f"RHIZO_MARKER input_owner=failed reason=seccomp:{ctypes.get_errno()}")
        return ""
    if not notify:
        log("RHIZO_MARKER input_owner=refusing reason=no-supervisor")
        return "refusing"
    try:
        sup.sendmsg([b"listener"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("i", rc))])
        sup.settimeout(10)
        answer = sup.recv(16)
    except OSError as e:
        answer = f"errno {e.errno}".encode()
    finally:
        os.close(rc)
    if answer == b"ok":
        return "listening"
    log(f"RHIZO_MARKER input_owner=refusing reason=handover:{answer.decode(errors='replace')}")
    return "refusing"


def struct_pack_fprog(count, addr):
    """return a struct sock_fprog {len, filter} as a ctypes buffer"""
    return ctypes.byref(_SockFprog(count, addr))


def start_input_fence(registry, labels=None, devmap=None):
    """listen on kernel uevents and the registry"""
    import socket
    try:
        sock = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, 15)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
        sock.bind((0, 1))
    except OSError as e:
        kmsg(f"RHIZO_MARKER input_fence=failed reason=socket:{e.errno}")
        return None
    stage = prepare_input_stage() if labels is not None else None
    if labels is not None and stage is None:
        sock.close()
        return None
    watch = libc.inotify_init1(0o2000000 | 0o4000)
    watched = [(b"/dev/input", 0x100 | 0x80), (b"/dev", 0x100 | 0x80)] + (
        [(d.encode(), 0x100 | 0x80 | _IN_ONLYDIR | _IN_DONT_FOLLOW) for d in selinux_ns.INPUT_STAGE_DIRS]
        if stage is not None else [])
    if watch < 0 or any(libc.inotify_add_watch(watch, d, mask) < 0 for d, mask in watched):
        kmsg(f"RHIZO_MARKER input_fence=failed reason=watch:{ctypes.get_errno()}")
        watch = None
    fence = InputFence(devmap=devmap)
    fence.watch = watch
    fence.stage = stage
    reconcile_input(fence)
    if fence.broken:
        kmsg(f"RHIZO_MARKER input_fence=failed reason={fence.broken}")
        sock.close()
        if watch is not None:
            os.close(watch)
        if stage is not None:
            stage.close()
        return None
    if registry is None:
        kmsg("RHIZO_MARKER input_fence=failed reason=no-registry")
    sink_late_block_uevents("", kmsg)
    kmsg("RHIZO_MARKER input_fence=listening")
    return FenceLoop(fence, sock, watch_fd=watch, registry=registry, labels=labels)


def _listen_run_socket(path, backlog):
    """bind and listen on a 0600 seqpacket socket at path"""
    import socket
    os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    try:
        s.bind(path)
        os.chmod(path, 0o600)
        s.listen(backlog)
    except OSError:
        s.close()
        raise
    return s


def open_fence_registry(sandbox_id, log=None):
    """bind the registry socket at <input_run_dir>/fence.sock"""
    log = log or kmsg
    path = f"{input_run_dir(sandbox_id)}/fence.sock"
    try:
        return _listen_run_socket(path, 4)
    except OSError as e:
        log(f"RHIZO_MARKER input_fence=failed reason=registry:{e.errno} path={path}")
        return None


def open_label_service(sandbox_id, log=None, path=None):
    """bind the label socket and return a LabelClient"""
    log = log or kmsg
    path = path or label_socket_path(sandbox_id)
    try:
        return LabelClient(_listen_run_socket(path, 1), log)
    except OSError as e:
        log(f"RHIZO_MARKER input_fence=failed reason=label-socket:{e.errno} path={path}")
        return LabelClient(None, log, gone=f"socket:{e.errno}")


def coldboot_primer_spec():
    """return (path, label) for the staged nodes the primer labels"""
    own = ("/dev/dri/renderD128", "/dev/dri/card0", "/dev/tun", "/dev/uinput")
    spec = [(DMA_HEAP_DIR[0], DMA_HEAP_DIR[2])]
    spec += [(p, v[3]) for p, v in STAGED_DEV_PERMS.items()
             if "*" not in p and p not in INIT_RESTORECON and p not in own]
    try:
        boot_id = host_boot_id()
    except OSError:
        return spec
    spec += [(f"/dev/{n}{boot_id}", staged_dev_perms(f"/dev/{n}{boot_id}")[3]) for n in COLDBOOT_BOOT_ID_DUPS]
    return spec


def _make_dev_nodes():
    """mknod the DEV_NODES entries with the STAGED_DEV_PERMS mode, owner and label"""
    import stat as _stdev
    for n in DEV_NODES:
        try:
            st = os.stat(f"/dev/{n}")
        except OSError as e:
            kmsg(f"stat of /dev/{n} failed ({e})"); continue
        err = _stage_node(NEWROOT, f"/dev/{n}", "c", os.major(st.st_rdev), os.minor(st.st_rdev))
        if err:
            kmsg(f"mknod /dev/{n} failed ({err})")
    _stage_coldboot()
    if core.VBMETA_LOOP_DEV:
        os.makedirs(f"{NEWROOT}/dev/block/by-name", exist_ok=True)
        try:
            st = os.stat(core.VBMETA_LOOP_DEV)
            dst = f"{NEWROOT}/dev/block/by-name/vbmeta"
            os.mknod(dst, _stdev.S_IFBLK | 0o600,
                     os.makedev(os.major(st.st_rdev), os.minor(st.st_rdev)))
            os.chmod(dst, 0o600)
        except OSError as e:
            kmsg(f"mknod /dev/block/by-name/vbmeta failed ({e})")
    os.makedirs(f"{NEWROOT}/dev/dri", exist_ok=True)


SESSION_ENV_PATH = "/run/rhizo-desktop/session.env"


def _session_env_wayland_socket():
    """return RHIZO_WAYLAND_HOST_SOCKET from the session env file"""
    try:
        with open(SESSION_ENV_PATH, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("RHIZO_WAYLAND_HOST_SOCKET="):
                    return line.split("=", 1)[1]
    except OSError:
        return None
    return None


def resolve_host_wayland_socket():
    """return the host compositor's socket to bind in"""
    def is_socket(path):
        """return whether path is an AF_UNIX socket"""
        st = core.stat_as_owner(path)
        return st is not None and stat.S_ISSOCK(st.st_mode)

    tried = []
    explicit = os.environ.get("RHIZO_WAYLAND_HOST_SOCKET") or _session_env_wayland_socket()
    if explicit:
        if is_socket(explicit):
            tried.append(explicit)
            return explicit, tried
        tried.append("%s (%s)" % (explicit, "not a socket" if os.path.exists(explicit)
                                  else "absent"))
        return None, tried

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/0"
    display = os.environ.get("WAYLAND_DISPLAY")
    candidates = []
    if display:
        candidates.append(display if display.startswith("/")
                          else os.path.join(runtime_dir, display))
    candidates += [os.path.join(runtime_dir, n)
                   for n in ("wayland-0", "wayland-1", "wayland-rhizo")]
    seen = set()
    for path in candidates:
        if path in seen:
            continue
        seen.add(path)
        if is_socket(path):
            tried.append(path)
            return path, tried
        tried.append("%s (%s)" % (path, "not a socket" if os.path.exists(path)
                                  else "absent"))
    return None, tried


# exception for a withheld node
class _Withheld(Exception):
    pass


DEVICE_NODE_CAPABILITIES = {
    "devices.dri": ("dri/renderD128", "dri/card0"),
    "devices.uinput": ("uinput",),
    "devices.tun": ("tun",),
}


DEVICE_CAPABILITIES_WITHOUT_NODE = {
    "devices.bluetooth": "rhizo-btd socket under /dev/socket with the capability on",
    "devices.camera": "rhizo-camerad socket under /dev/socket with the capability on",
    "devices.location": "rhizo-locationd socket under /dev/socket with the capability on",
    "devices.battery": "host-battery file in the read-only device-state directory, written by g with "
                       "the capability on",
    "devices.sensors": "read-only bind of each declared IIO directory under /dev/rhizo_iio with "
                       "the capability on, and IIO directories masked in the sandbox sysfs",
    "devices.virtual": "RhizoVirtualDevice app on /product with the capability on",
}


HOST_SEAT_UEVENT_CLASSES = ("drm", "graphics")


def shadow_host_seat_uevents(newroot, log=kmsg, mount_fn=None):
    """bind-mount the uevent file of each host display device read-only at the uevent path"""
    mount_fn = mount_fn or mount
    shadowed, failed = [], []
    sys_root = os.path.realpath(f"{newroot}/sys") + "/"
    for cls in HOST_SEAT_UEVENT_CLASSES:
        try:
            names = sorted(os.listdir(f"{newroot}/sys/class/{cls}"))
        except OSError:
            continue
        for name in names:
            dev = os.path.realpath(f"{newroot}/sys/class/{cls}/{name}")
            uevent = f"{dev}/uevent"
            if not os.path.isfile(uevent):
                continue
            if not dev.startswith(sys_root):
                failed.append(name)
                continue
            if mount_fn(uevent, uevent, None, MS_BIND) and \
                    mount_fn(None, uevent, None, MS_BIND | MS_REMOUNT | MS_RDONLY):
                shadowed.append(name)
            else:
                failed.append(name)
    log(f"host seat uevents read-only shadowed={shadowed or 'none'}"
        + (f" failed={failed}" if failed else ""))
    return not failed, shadowed, failed


def withheld_device_nodes(policy):
    """return the /dev paths whose capability is off"""
    return [rel for cap, rels in DEVICE_NODE_CAPABILITIES.items()
            if not policy.allows(cap) for rel in rels]


def enforce_device_node_absence(dev_dir, policy, log=lambda m: None):
    """remove any node under dev_dir whose capability is off"""
    removed = []
    for rel in withheld_device_nodes(policy):
        path = os.path.join(dev_dir, rel)
        try:
            os.remove(path)
            removed.append(rel)
        except FileNotFoundError:
            pass
        except OSError as e:
            log(f"failed to remove withheld device node {rel} ({e})")
    if removed:
        log(f"removed withheld device nodes {removed}")
    return removed


DEVICE_FILTER_HOST_PATHS = {
    "devices.dri": ("/dev/dri/renderD*", True),
    "devices.uinput": ("/dev/uinput", False),
    "devices.tun": ("/dev/net/tun", False),
}


def withheld_device_majors(policy, log=lambda m: None, paths=None, stat_fn=os.stat):
    """return the device numbers to deny per withheld capability"""
    withheld = []
    for capability, (path, whole_major) in sorted((paths or DEVICE_FILTER_HOST_PATHS).items()):
        if policy.allows(capability):
            continue
        if "*" in path:
            hits = sorted(glob.glob(path))
            if not hits:
                continue
            path = hits[0]
        try:
            st = stat_fn(path)
        except FileNotFoundError:
            continue
        except OSError as e:
            log(f"stat of {path} for {capability} failed ({e})")
            return None
        major, minor = os.major(st.st_rdev), os.minor(st.st_rdev)
        withheld.append((major, None if whole_major else minor))
    return withheld


DEVICE_ALLOW_BASE = (
    ("c", "dev", (1, 3), ("/dev/null",)),
    ("c", "dev", (1, 5), ("/dev/zero",)),
    ("c", "dev", (1, 7), ("/dev/full",)),
    ("c", "dev", (1, 8), ("/dev/random",)),
    ("c", "dev", (1, 9), ("/dev/urandom",)),
    ("c", "dev", (1, 11), ("/dev/kmsg",)),
    ("c", "dev", (5, 0), ("/dev/tty",)),
    ("c", "dev", (5, 2), ("/dev/ptmx", "/dev/pts/ptmx")),
    ("c", "major", "pts", ("/dev/pts/[0-9]*",)),
    ("c", "misc", "ashmem", ("/dev/ashmem", "/dev/ashmem?*")),
    ("c", "misc", "loop-control", ("/dev/loop-control",)),
    ("c", "misc", "device-mapper", ("/dev/device-mapper",)),
    ("c", "misc", "fuse", ("/dev/fuse",)),
    ("c", "misc", "hw_random", ("/dev/hw_random",)),
    ("c", "class", "dma_heap/system", ("/dev/dma_heap/system",)),
    ("c", "class", "dma_heap/system-uncached", ("/dev/dma_heap/system-uncached",)),
    ("c", "major", "binder", ("/dev/binderfs/*",)),
    ("b", "major", "loop", ("/dev/block/loop[0-9]*", "/dev/block/by-name/vbmeta")),
    ("b", "major", "device-mapper", ("/dev/block/dm-[0-9]*",)),
)


DEVICE_ALLOW_CAPABILITY_NODES = {
    "devices.uinput": (
        ("c", "cuse", "uhid", ("/dev/uhid",)),
        ("c", "fence", "input", ("/dev/input/event[0-9]*", "/dev/input/mouse[0-9]*")),
        ("c", "fence", "hidraw", ("/dev/hidraw[0-9]*",)),
    ),
}
FENCE_MINORS = "fence"


def proc_device_majors(proc_root="/proc"):
    """return {(kind, name): [major, ...]} from /proc/devices, or None"""
    try:
        with open(f"{proc_root}/devices") as f:
            text = f.read()
    except OSError:
        return None
    majors, kind = {}, None
    for line in text.splitlines():
        if line.startswith("Character devices:"):
            kind = "c"
        elif line.startswith("Block devices:"):
            kind = "b"
        else:
            parts = line.split(None, 1)
            if kind and len(parts) == 2 and parts[0].isdigit():
                majors.setdefault((kind, parts[1].strip()), []).append(int(parts[0]))
    return majors


HOST_DM_UUID_PREFIXES = ("CRYPT-", "LVM-", "mpath-", "part")


def host_owned_dm(name, sys_root="/sys"):
    """return whether dm device name has a non-loop slave or a HOST_DM_UUID_PREFIXES uuid"""
    base = f"{sys_root}/class/block/{name}"
    try:
        slaves = os.listdir(f"{base}/slaves")
    except OSError:
        slaves = []
    try:
        with open(f"{base}/dm/uuid") as f:
            uuid = f.read().strip()
    except OSError:
        uuid = ""
    return any(not re.fullmatch(r"loop[0-9]+", s) for s in slaves) or uuid.startswith(HOST_DM_UUID_PREFIXES)


def host_dm_minors(major, sys_root="/sys"):
    """return the minors of the host-owned device-mapper devices on major"""
    try:
        names = sorted(n for n in os.listdir(f"{sys_root}/class/block") if n.startswith("dm-"))
    except OSError:
        return []
    found = ((_devnum(f"{sys_root}/class/block/{n}/dev"), n) for n in names)
    return sorted(dn[1] for dn, n in found if dn and dn[0] == major and host_owned_dm(n, sys_root))


def _allow_entry_devices(entry, majors, sys_root, sandbox_id, uhid_wait_s, stat_fn, log):
    """return the (kind, major, minor[, excluded minors]) devices of an allow-list entry"""
    kind, how, what, _nodes = entry
    if how == "dev":
        return [(kind,) + tuple(what)]
    if how in ("misc", "class"):
        dn = _devnum(f"{sys_root}/class/{'misc/' if how == 'misc' else ''}{what}/dev")
        return [(kind,) + dn] if dn else []
    if how == "fence":
        return [(kind, major, FENCE_MINORS) for major in majors.get((kind, what), ())]
    if how == "major":
        out = []
        for major in majors.get((kind, what), ()):
            excluded = tuple(host_dm_minors(major, sys_root)) if (kind, what) == ("b", "device-mapper") else ()
            out.append((kind, major, None, excluded) if excluded else (kind, major, None))
        return out
    if how == "cuse":
        name = f"rhizo-{sandbox_id}-{what}"
        try:
            dev = cuse_devnum(name, sys_root=sys_root, wait_s=uhid_wait_s)
        except OSError as e:
            if uhid_wait_s:
                log(f"cuse_devnum({name}) failed ({e})")
            return []
        return [(kind, os.major(dev), os.minor(dev))]
    path, whole_major = what
    if "*" in path:
        hits = sorted(glob.glob(path))
        if not hits:
            return []
        path = hits[0]
    try:
        st = stat_fn(path)
    except FileNotFoundError:
        return []
    except OSError as e:
        log(f"stat of {path} failed ({e})")
        return []
    return [(kind, os.major(st.st_rdev), None if whole_major else os.minor(st.st_rdev))]


def _allow_key(dev):
    """return the sort key of an allow-list device"""
    return dev[0], dev[1], -2 if dev[2] == FENCE_MINORS else -1 if dev[2] is None else dev[2]


def device_allowlist(policy, log=lambda m: None, paths=None, stat_fn=os.stat, sys_root="/sys",
                     proc_root="/proc", sandbox_id=0, uhid_wait_s=0):
    """return the allowed devices as (kind, major, minor[, excluded]), minor None for a whole major or FENCE_MINORS"""
    paths = paths or DEVICE_FILTER_HOST_PATHS
    entries = []
    for capability in sorted(set(paths) | set(DEVICE_ALLOW_CAPABILITY_NODES)):
        if not policy.allows(capability):
            continue
        if capability in paths:
            entries.append(("c", "host", paths[capability], ()))
        entries += DEVICE_ALLOW_CAPABILITY_NODES.get(capability, ())
    devices = set()
    for entry in [e for e in entries if e[1] == "cuse"]:
        devices.update(_allow_entry_devices(entry, {}, sys_root, sandbox_id, uhid_wait_s, stat_fn, log))
    majors = proc_device_majors(proc_root)
    if majors is None:
        log(f"failed to read {proc_root}/devices")
        return None
    absent = []
    for entry in DEVICE_ALLOW_BASE:
        found = _allow_entry_devices(entry, majors, sys_root, sandbox_id, uhid_wait_s, stat_fn, log)
        if not found:
            absent.append(f"{entry[1]}:{entry[2]}")
        devices.update(found)
    for entry in [e for e in entries if e[1] != "cuse"]:
        devices.update(_allow_entry_devices(entry, majors, sys_root, sandbox_id, uhid_wait_s, stat_fn, log))
    if absent:
        log(f"RHIZO_MARKER device_allowlist_absent={','.join(absent)}")
    whole = {(d[0], d[1]) for d in devices if d[2] is None}
    return sorted((d for d in devices if d[2] is None or (d[0], d[1]) not in whole), key=_allow_key)


def allowlist_admits(allowed, kind, major, minor):
    """return whether allowed admits a device, minor None for any minor of major"""
    for dev in allowed:
        if dev[0] != kind or dev[1] != major:
            continue
        if dev[2] == FENCE_MINORS:
            return True
        if dev[2] is None and (minor is None or minor not in (dev[3] if len(dev) > 3 else ())):
            return True
        if dev[2] is not None and (minor is None or dev[2] == minor):
            return True
    return False


_HOST_DRI_SOURCES = []


_HOST_GPU_VARIANT = []


def host_dri_sources(env=None, resolver=None, log=kmsg):
    """map each sandbox dri node to a host device node"""
    if env is None and resolver is None:
        if not _HOST_DRI_SOURCES:
            _HOST_DRI_SOURCES.append(_resolve_dri_sources(None, None, log))
        return dict(_HOST_DRI_SOURCES[0])
    return _resolve_dri_sources(env, resolver, log)


def host_gpu_variant(log=kmsg):
    """return the variant field of detect-gpu-driver.sh --node, or None"""
    host_dri_sources(log=log)
    return _HOST_GPU_VARIANT[0] if _HOST_GPU_VARIANT else None


def _resolve_dri_sources(env, resolver, log):
    """map the detect-gpu-driver.sh --node device to host nodes"""
    try:
        r = subprocess.run(["bash", resolver or beside("detect-gpu-driver.sh"), "--node"],
                           capture_output=True, text=True, timeout=30, env=env)
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"RHIZO_MARKER dri_source=failed reason={e}")
        return {}
    fields = r.stdout.split()
    if r.returncode != 0 or len(fields) != 3:
        why = (r.stderr.strip().splitlines() or ["no output"])[-1]
        log(f"RHIZO_MARKER dri_source=failed rc={r.returncode} reason={why}")
        return {}
    render, card, variant = fields
    log(f"RHIZO_MARKER dri_source=ok render={render} card={card} variant={variant}")
    if env is None and resolver is None:
        _HOST_GPU_VARIANT[:] = [variant]
    sources = {"renderD128": render, os.path.basename(render): render}
    if card != "-":
        sources.update({"card0": card, os.path.basename(card): card})
    return sources


def dri_node_plan(sources, stat_fn=os.stat, log=kmsg):
    """return the sandbox name and device number of each dri node"""
    plan = []
    for name, host in sorted(sources.items()):
        try:
            rdev = stat_fn(host).st_rdev
        except OSError as e:
            log(f"stat of {host} for /dev/dri/{name} failed ({e})")
            continue
        plan.append((name, os.major(rdev), os.minor(rdev)))
    return plan


def _bind_sockets_and_shadows(mount_proc):
    """bind the host sockets and shadows"""
    import stat as _stdri
    policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    enforce_device_node_absence(f"{NEWROOT}/dev", policy, log=kmsg)
    dri_nodes = ("renderD128", "card0") if policy.allows("devices.dri") else ()
    if not dri_nodes:
        kmsg("no /dev/dri/renderD128 or /dev/dri/card0 with devices.dri off")
    for n, major, minor in dri_node_plan(host_dri_sources() if dri_nodes else {}):
        try:
            os.mknod(f"{NEWROOT}/dev/dri/{n}", _stdri.S_IFCHR | 0o666, os.makedev(major, minor))
            os.chown(f"{NEWROOT}/dev/dri/{n}", AID_ROOT, AID_GRAPHICS)
            os.chmod(f"{NEWROOT}/dev/dri/{n}", 0o666)
            label_before_policy(f"{NEWROOT}/dev/dri/{n}", b"u:object_r:gpu_device:s0\0")
        except OSError as e:
            kmsg(f"/dev/dri/{n} mknod failed ({e})")
    _op = "stat of the host node"
    try:
        if not policy.allows("devices.uinput"):
            raise _Withheld("devices.uinput")
        st = os.stat("/dev/uinput")
        _op = "mknod"
        os.mknod(f"{NEWROOT}/dev/uinput", _stdri.S_IFCHR | 0o660,
                 os.makedev(os.major(st.st_rdev), os.minor(st.st_rdev)))
        _op = "chown"
        os.chown(f"{NEWROOT}/dev/uinput", AID_UHID, AID_UHID)
        _op = "chmod"
        os.chmod(f"{NEWROOT}/dev/uinput", 0o660)
    except _Withheld as w:
        kmsg(f"no /dev/uinput with {w} off")
    except OSError as e:
        kmsg(f"{_op} of /dev/uinput failed ({e})")
    _op = "cuse_devnum"
    try:
        if not policy.allows("devices.uinput"):
            raise _Withheld("devices.uinput")
        dev = cuse_devnum(f"rhizo-{SANDBOX_ID}-uhid")
        _op = "mknod"
        os.mknod(f"{NEWROOT}/dev/uhid", _stdri.S_IFCHR | 0o660, dev)
        _op = "chown"
        os.chown(f"{NEWROOT}/dev/uhid", AID_UHID, AID_UHID)
        _op = "chmod"
        os.chmod(f"{NEWROOT}/dev/uhid", 0o660)
        kmsg(f"RHIZO_MARKER input_owner=uhid-node dev={os.major(dev)}:{os.minor(dev)}")
    except _Withheld as w:
        kmsg(f"no /dev/uhid with {w} off")
    except OSError as e:
        kmsg(f"RHIZO_MARKER input_owner=failed reason=uhid-node:{e.errno} op={_op}")
    _op = "stat of the host node"
    try:
        if not policy.allows("devices.tun"):
            raise _Withheld("devices.tun")
        st = os.stat("/dev/net/tun")
        _op = "mknod"
        os.mknod(f"{NEWROOT}/dev/tun", _stdri.S_IFCHR | 0o660,
                 os.makedev(os.major(st.st_rdev), os.minor(st.st_rdev)))
        _op = "chmod"
        os.chmod(f"{NEWROOT}/dev/tun", 0o660)
        _op = "chown"
        os.chown(f"{NEWROOT}/dev/tun", 1000, 1016)
        _op = "setxattr"
        label_before_policy(f"{NEWROOT}/dev/tun", b"u:object_r:tun_device:s0\0")
    except _Withheld as w:
        kmsg(f"no /dev/tun with {w} off")
    except OSError as e:
        kmsg(f"{_op} of /dev/tun failed ({e})")
    os.makedirs(f"{NEWROOT}/dev/input", exist_ok=True)
    mount("tmpfs", f"{NEWROOT}/dev/input", "tmpfs", MS_NOSUID|MS_NOEXEC, "mode=02755,uid=0,gid=1004")
    host_wayland_socket, wayland_tried = resolve_host_wayland_socket()
    os.makedirs(f"{NEWROOT}/dev/socket/rhizo_wayland", exist_ok=True)
    if host_wayland_socket:
        dst = f"{NEWROOT}/dev/socket/rhizo_wayland/wayland-0"
        open(dst, "w").close()
        if core.bind_as_owner(host_wayland_socket, dst):
            kmsg(f"wayland socket bind-mounted {host_wayland_socket} -> /dev/socket/rhizo_wayland/wayland-0")
        else:
            kmsg(f"wayland socket bind mount FAILED {host_wayland_socket}")
    else:
        kmsg(f"wayland socket NOT FOUND in {', '.join(wayland_tried)}")
    host_audio_socket = os.environ.get("RHIZO_AUDIO_HOST_SOCKET", "/run/rhizo-audio/audiod")
    host_audio_dir = os.path.dirname(host_audio_socket)
    os.makedirs(f"{NEWROOT}/dev/socket/rhizo_audio", exist_ok=True)
    if not os.path.isdir(host_audio_dir):
        kmsg(f"no audio socket dir {host_audio_dir}")
    elif mount(host_audio_dir, f"{NEWROOT}/dev/socket/rhizo_audio", None, MS_BIND):
        kmsg(f"audio socket dir bind-mounted {host_audio_dir} -> /dev/socket/rhizo_audio")
    else:
        kmsg(f"failed to bind audio socket dir {host_audio_dir}")
    device_state_dst = NEWROOT + DEVICE_STATE_MOUNT
    os.makedirs(device_state_dst, exist_ok=True)
    os.makedirs(RHIZO_DEVICE_STATE_DIR, exist_ok=True)
    if mount(RHIZO_DEVICE_STATE_DIR, device_state_dst, None, MS_BIND):
        kmsg(f"device-state dir bind-mounted {RHIZO_DEVICE_STATE_DIR} -> {DEVICE_STATE_MOUNT}")
    else:
        kmsg(f"failed to bind device-state dir {RHIZO_DEVICE_STATE_DIR}")
    host_stream_socket = os.environ.get("RHIZO_STREAM_HOST_SOCKET", "/run/rhizo-stream/streamd")
    host_stream_dir = os.path.dirname(host_stream_socket)
    os.makedirs(f"{NEWROOT}/dev/socket/rhizo_stream", exist_ok=True)
    if not os.path.isdir(host_stream_dir):
        kmsg(f"no stream socket dir {host_stream_dir}")
    elif mount(host_stream_dir, f"{NEWROOT}/dev/socket/rhizo_stream", None, MS_BIND):
        kmsg(f"stream socket dir bind-mounted {host_stream_dir} -> /dev/socket/rhizo_stream")
    else:
        kmsg(f"failed to bind stream socket dir {host_stream_dir}")
    host_rt_socket = os.environ.get("RHIZO_RT_HOST_SOCKET", "/run/rhizo-rt/rtd")
    host_rt_dir = os.path.dirname(host_rt_socket)
    rt_mountpoint = f"{NEWROOT}/dev/socket/rhizo_rt"
    if not os.path.isdir(host_rt_dir):
        kmsg(f"no rt socket dir {host_rt_dir}")
    else:
        os.makedirs(rt_mountpoint, exist_ok=True)
        if mount(host_rt_dir, rt_mountpoint, None, MS_BIND):
            kmsg(f"rt socket dir bind-mounted {host_rt_dir} -> /dev/socket/rhizo_rt")
        else:
            kmsg(f"failed to bind rt socket dir {host_rt_dir}")
    if not policy.allows("trace.host_delay"):
        delay_state = "withheld"
    elif not os.path.isdir("/run/rhizo-delay"):
        delay_state = "absent"
    else:
        os.makedirs(f"{NEWROOT}/dev/socket/rhizo_delay", exist_ok=True)
        delay_state = ("bound" if core.bind_private("/run/rhizo-delay",
                                                         f"{NEWROOT}/dev/socket/rhizo_delay", log=kmsg)
                       else "absent")
    kmsg(f"RHIZO_MARKER host_delay_socket={delay_state}")
    if not policy.allows("power.cpu_headroom"):
        headroom_state = "withheld"
    elif not os.path.isdir("/run/rhizo-headroom"):
        headroom_state = "absent"
    else:
        os.makedirs(f"{NEWROOT}/dev/socket/rhizo_headroom", exist_ok=True)
        headroom_state = ("bound" if core.bind_private("/run/rhizo-headroom",
                                                            f"{NEWROOT}/dev/socket/rhizo_headroom", log=kmsg)
                          else "absent")
    kmsg(f"RHIZO_MARKER headroom_socket={headroom_state}")
    if not policy.allows("devices.bluetooth"):
        bluetooth_state = "withheld"
    elif not os.path.isdir("/run/rhizo-bt"):
        bluetooth_state = "absent"
    else:
        os.makedirs(f"{NEWROOT}/dev/socket/rhizo_bluetooth", exist_ok=True)
        bluetooth_state = ("bound" if core.bind_private("/run/rhizo-bt",
                                                             f"{NEWROOT}/dev/socket/rhizo_bluetooth", log=kmsg)
                           else "absent")
    kmsg(f"RHIZO_MARKER bluetooth_socket={bluetooth_state}")
    if not policy.allows("devices.camera"):
        camera_state = "withheld"
    else:
        os.makedirs("/run/rhizo-camera", mode=0o755, exist_ok=True)
        os.makedirs(f"{NEWROOT}/dev/socket/rhizo_camera", exist_ok=True)
        camera_state = ("bound" if core.bind_private("/run/rhizo-camera",
                                                          f"{NEWROOT}/dev/socket/rhizo_camera", log=kmsg)
                        else "absent")
    kmsg(f"RHIZO_MARKER camera_socket={camera_state}")
    if not policy.allows("devices.location"):
        location_state = "withheld"
    elif policy.scope("rhizo.profile") == "server":
        location_state = "withheld"
    elif not os.path.isdir("/run/rhizo-location"):
        location_state = "absent"
    else:
        os.makedirs(f"{NEWROOT}/dev/socket/rhizo_location", exist_ok=True)
        location_state = ("bound" if core.bind_private("/run/rhizo-location",
                                                            f"{NEWROOT}/dev/socket/rhizo_location", log=kmsg)
                          else "absent")
    kmsg(f"RHIZO_MARKER location_socket={location_state}")
    try: os.symlink("/system/etc",f"{NEWROOT}/etc")
    except FileExistsError: pass
    try: os.symlink("/system/bin",f"{NEWROOT}/bin")
    except FileExistsError: pass
    if mount_proc:
        mount("proc",f"{NEWROOT}/proc","proc",0,f"hidepid=2,gid={AID_READPROC}")
    mount("sysfs",f"{NEWROOT}/sys","sysfs",MS_NOSUID|MS_NODEV|MS_NOEXEC)
    _shadow_sys_devices()
    _shadow_block_uevents()
    _mask_iio_devices()
    os.makedirs("/rhizoroot/real_sys_kernel", exist_ok=True)
    _cap_ok = mount(f"{NEWROOT}/sys/kernel", "/rhizoroot/real_sys_kernel", None, MS_BIND|MS_REC)
    _real_kernel_children = os.listdir("/rhizoroot/real_sys_kernel")
    _tmpfs_ok = mount("tmpfs", f"{NEWROOT}/sys/kernel", "tmpfs", 0)
    kmsg(f"wakeup_reasons shadow capture_bind={_cap_ok} children={len(_real_kernel_children)} tmpfs_over={_tmpfs_ok}")
    _child_fail = 0
    _keep = _sys_kernel_keep() if RHIZO_SYSKERNEL_SUBSET else None
    _dropped = []
    _ftrace = capabilities.ftrace_allowed(log=kmsg)
    kmsg(f"RHIZO_MARKER ftrace={'on' if _ftrace else 'off'}")
    for _name in _real_kernel_children:
        if _name == "tracing" and not _ftrace:
            continue
        if _keep is not None and _name not in _keep:
            _dropped.append(_name)
            continue
        _src = f"/rhizoroot/real_sys_kernel/{_name}"
        _dst = f"{NEWROOT}/sys/kernel/{_name}"
        if os.path.isdir(_src):
            os.makedirs(_dst, exist_ok=True)
        else:
            open(_dst, "w").close()
        if not bind_sys_kernel_child(_src, _dst, _name):
            _child_fail += 1
        else:
            _tally("syskernel")
    if _dropped:
        kmsg(f"sys/kernel subset bound={len(_real_kernel_children) - len(_dropped)} "
             f"dropped={len(_dropped)} {sorted(_dropped)}")
    _side_err = 0
    if _cap_ok:
        if libc.umount2(b"/rhizoroot/real_sys_kernel", 2) != 0:
            _side_err = ctypes.get_errno()
        else:
            try:
                os.rmdir("/rhizoroot/real_sys_kernel")
            except OSError:
                pass
    kmsg(f"RHIZO_MARKER sys_kernel_side=detached errno={_side_err} rmdir_left={os.path.exists('/rhizoroot/real_sys_kernel')}")
    if _side_err:
        kmsg(f"RHIZO_MARKER sysfs_ro=refused reason=side-detach errno={_side_err}")
        os._exit(1)
    os.makedirs(f"{NEWROOT}/sys/kernel/wakeup_reasons", exist_ok=True)
    open(f"{NEWROOT}/sys/kernel/wakeup_reasons/last_resume_reason", "w").close()
    open(f"{NEWROOT}/sys/kernel/wakeup_reasons/last_suspend_time", "w").write("0 0.001\n")
    kmsg(f"wakeup_reasons shadow child_binds_failed={_child_fail} "
         f"final_exists={os.path.exists(f'{NEWROOT}/sys/kernel/wakeup_reasons/last_resume_reason')}")
    _debugfs = (not RHIZO_ENFORCING) and _ftrace
    if _debugfs:
        os.makedirs(f"{NEWROOT}/sys/kernel/debug", exist_ok=True)
    seal_sysfs()
    if _debugfs:
        mount("debugfs",f"{NEWROOT}/sys/kernel/debug","debugfs",0)
    os.makedirs(f"{NEWROOT}/sys/fs/cgroup",exist_ok=True); mount("cgroup2",f"{NEWROOT}/sys/fs/cgroup","cgroup2",0)
    os.chmod(f"{NEWROOT}/sys/fs/cgroup", 0o775)


def _setup_cgroups_and_selinuxfs(handoff=False):
    """set up the cgroup2 tree and selinuxfs"""
    os.chown(f"{NEWROOT}/sys/fs/cgroup", 0 if RHIZO_UNDER_UNIT else 1000, 1000)
    os.chown(f"{NEWROOT}/sys/fs/cgroup/cgroup.procs", 1000, 1000)
    try:
        cgroup_write(f"{NEWROOT}/sys/fs/cgroup/cgroup.subtree_control", "+memory +cpu")
    except OSError as e:
        kmsg(f"failed to write +memory +cpu to the cgroup root subtree_control ({e})")
    _cgroot = f"{NEWROOT}/sys/fs/cgroup"
    _borrowed = False
    try:
        _st = os.stat(_cgroot)
        kmsg("cgroup root before apps mkdir mode=%o uid=%d gid=%d writable_by_uid0=%s"
             % (_st.st_mode & 0o7777, _st.st_uid, _st.st_gid,
                os.access(_cgroot, os.W_OK)))
        _borrowed = _st.st_uid != 0
        if _borrowed:
            os.chown(_cgroot, 0, 0)
    except OSError as e:
        _borrowed = False
        kmsg(f"failed to chown the cgroup root ({e})")
    try:
        os.makedirs(f"{NEWROOT}/sys/fs/cgroup/apps", exist_ok=True)
    finally:
        if _borrowed:
            _owner = 0 if RHIZO_UNDER_UNIT else 1000
            os.chown(_cgroot, _owner, 1000)
            os.chmod(_cgroot, 0o775)
    os.chmod(f"{NEWROOT}/sys/fs/cgroup/apps", 0o775)
    os.chown(f"{NEWROOT}/sys/fs/cgroup/apps", 1000, 1000)
    os.chown(f"{NEWROOT}/sys/fs/cgroup/apps/cgroup.procs", 1000, 1000)
    for _cg in ("apps", "system"):
        try:
            cgroup_write(f"{NEWROOT}/sys/fs/cgroup/{_cg}/cgroup.subtree_control", "+memory +cpu")
        except OSError as e:
            kmsg(f"failed to write +memory +cpu to cgroup {_cg} subtree_control ({e})")
    holder = handoff and not host_selinux_mode()
    if holder:
        os.makedirs(f"{NEWROOT}/sys/fs/selinux", exist_ok=True)
        selinux_ns.clear_selinuxfs_mounts(f"{NEWROOT}/sys/fs/selinux")
    else:
        mount_sandbox_selinuxfs(selinux_ns.selinux_mode())
        open("/rhizoroot/tmp_enforce","w").write("0")
        os.chmod("/rhizoroot/tmp_enforce", 0o644)
        try:
            label_before_policy("/rhizoroot/tmp_enforce", b"u:object_r:rhizo_enforce_shadow:s0\0")
        except OSError as e:
            kmsg(f"setxattr of the decoy enforce node failed ({e})")
        mount("/rhizoroot/tmp_enforce", f"{NEWROOT}/sys/fs/selinux/enforce", None, MS_BIND)
        if RHIZO_ENFORCING:
            kmsg("RHIZO_ENFORCING=1 with the decoy enforce node mount")
    open("/rhizoroot/tmp_power_state","w").write("")
    os.chmod("/rhizoroot/tmp_power_state", 0o644)
    mount("/rhizoroot/tmp_power_state", f"{NEWROOT}/sys/power/state", None, MS_BIND)
    if os.path.exists("/sys/block/zram0/reset"):
        open("/rhizoroot/tmp_zram_reset","w").write("")
        os.chmod("/rhizoroot/tmp_zram_reset", 0o644)
        if mount("/rhizoroot/tmp_zram_reset", f"{NEWROOT}/sys/block/zram0/reset", None, MS_BIND):
            kmsg("bound the zram0 reset shadow")
        else:
            kmsg("failed to bind the zram0 reset shadow")
    shadow_host_seat_uevents(NEWROOT)
    relabel_root_objects_now(NEWROOT, staged=coldboot_primer_spec())
    device_state_dst = NEWROOT + DEVICE_STATE_MOUNT
    try:
        device_state_bound = core.is_mount_point(device_state_dst)
    except OSError as e:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=device-state-ro-failed path={device_state_dst} err={e!r}")
        os._exit(1)
    if device_state_bound and host_selinux_mode():
        if selinux_ns.host_policy_state() == "none":
            bad = label_device_state_dir(device_state_dst)
        else:
            label = read_label(device_state_dst)
            bad = None if label == DEVICE_STATE_LABEL else label
        if bad:
            refuse_device_state_label(device_state_dst, bad)
        battery_path = f"{device_state_dst}/{core.HOST_BATTERY_FILE}"
        if core.host_battery() is not None and os.path.isfile(battery_path):
            if selinux_ns.host_policy_state() == "none":
                bad = label_device_state_dir(battery_path)
            else:
                label = read_label(battery_path)
                bad = None if label == DEVICE_STATE_LABEL else label
            settle_host_battery(battery_path, bad or "ok")
    if device_state_bound and not mount(None, device_state_dst, None, MS_BIND | MS_REMOUNT | MS_RDONLY):
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=device-state-ro-failed path={device_state_dst} "
             f"errno={ctypes.get_errno()}")
        os._exit(1)
    if holder:
        selinux_ns.start_view_keeper()
    elif selinux_ns.state()["unshared"]:
        selinux_ns.start_relabeller(NEWROOT, coldboot_primer_spec(), core.WRITE_PRIMER_SCRIPT,
                                         core.RELABELLER_DONE_FD)
    if not pivot_root(NEWROOT,f"{NEWROOT}/oldroot"): kmsg("pivot_root failed"); os._exit(1)


def _detach_if_mounted(path):
    """call umount2(path, MNT_DETACH)"""
    libc.umount2(path.encode(), 2)


SYSCTL_SHADOWS = ("vm/mmap_rnd_bits", "vm/mmap_rnd_compat_bits",
                  "kernel/kptr_restrict", "kernel/unprivileged_bpf_disabled")
SYSRQ_SINK = ".rhizo_sysrq_sink"
ANDROID_PROC_LABELS = {"vm/mmap_rnd_bits": "u:object_r:proc_security:s0",
                       "vm/mmap_rnd_compat_bits": "u:object_r:proc_security:s0",
                       "kernel/kptr_restrict": "u:object_r:proc_security:s0",
                       "kernel/unprivileged_bpf_disabled": "u:object_r:proc_bpf:s0",
                       "sysrq-trigger": "u:object_r:proc_sysrq:s0"}


def sysctl_shadow_spec():
    """return (path, label) for each sysctl shadow"""
    spec = [(f"/dev/.shadow_{s.replace('/', '_')}", ANDROID_PROC_LABELS[s]) for s in SYSCTL_SHADOWS]
    return spec + [(f"/dev/{SYSRQ_SINK}", ANDROID_PROC_LABELS["sysrq-trigger"])]


def _sysctl_shadow_label(real):
    """return the label of real, or the ANDROID_PROC_LABELS label"""
    try:
        return os.getxattr(real, "security.selinux")
    except OSError as e:
        key = real.removeprefix("/proc/sys/") if real.startswith("/proc/sys/") else real.removeprefix("/proc/")
        label = (ANDROID_PROC_LABELS.get(key, "u:object_r:proc_security:s0") + "\0").encode()
        kmsg(f"failed to read the label of {real} ({e}), shadow label {label!r}")
        return label


def _label_of(path):
    """return path's security.selinux xattr, or None"""
    try:
        return os.getxattr(path, "security.selinux")
    except OSError:
        return None


def _label_kept(path, want):
    """return whether the label of path is want"""
    if selinux_ns.state()["unshared"]:
        return os.path.exists(path)
    return _label_of(path) is not None and _label_of(path) == want


def stage_sysctl_shadows(devroot):
    """create and label the sysctl dummies and sysrq sink"""
    n = 0
    for s in SYSCTL_SHADOWS:
        real = f"/proc/sys/{s}"
        try:
            cur = open(real).read().strip()
        except OSError:
            continue
        dummy = f"{devroot}/.shadow_{s.replace('/', '_')}"
        try:
            open(dummy, "w").write(cur + "\n"); os.chmod(dummy, 0o644)
            label_before_policy(dummy, _sysctl_shadow_label(real))
            n += 1
        except OSError as e:
            kmsg(f"failed to stage shadow {s} ({e})")
    sink = f"{devroot}/{SYSRQ_SINK}"
    try:
        open(sink, "w").close(); os.chmod(sink, 0o644)
        label_before_policy(sink, os.getxattr("/proc/sysrq-trigger", "security.selinux"))
        n += 1
    except OSError as e:
        kmsg(f"failed to stage the sysrq sink ({e})")
    kmsg(f"sysctl shadows under {devroot} staged={n} total={len(SYSCTL_SHADOWS) + 1}")


def _mask_sysrq_trigger():
    """bind the read-only sysrq sink over /proc/sysrq-trigger"""
    dst = "/proc/sysrq-trigger"
    sink = f"/dev/{SYSRQ_SINK}"
    try:
        cur, snk = os.stat(dst), os.stat(sink)
        if ((cur.st_dev, cur.st_ino) == (snk.st_dev, snk.st_ino)
                and os.statvfs(dst).f_flag & os.ST_RDONLY):
            kmsg("/proc/sysrq-trigger is already the read-only sysrq sink")
            return True, True
    except OSError:
        pass
    _detach_if_mounted(dst)
    labeled = False
    try:
        if _label_kept(sink, _label_of(dst)):
            labeled = "deferred" if selinux_ns.state()["unshared"] else True
        else:
            open(sink, "w").close()
            os.chmod(sink, 0o644)
            try:
                labeled = label_before_policy(sink, os.getxattr(dst, "security.selinux")) or "deferred"
            except OSError as e:
                kmsg(f"failed to copy the sysrq sink label ({e})")
        if not mount(sink, dst, None, MS_BIND):
            return False, labeled
        return bool(mount(None, dst, None, MS_BIND|MS_REMOUNT|MS_RDONLY)), labeled
    except OSError as e:
        kmsg(f"failed to mask /proc/sysrq-trigger ({e})")
        return False, labeled


def harden_proc_sys():
    """make /proc/sys read-only and mask sysrq"""
    _detach_if_mounted("/proc/sys/net/core")
    _detach_if_mounted("/proc/sys/net")
    ro_ok = False
    if mount("/proc/sys","/proc/sys",None,MS_BIND):
        mount("/proc/sys/net","/proc/sys/net",None,MS_BIND)
        ro_ok = bool(mount(None,"/proc/sys",None,MS_BIND|MS_REMOUNT|MS_RDONLY))
    n_shadow = 0; n_labeled = 0; n_deferred = 0
    for s in SYSCTL_SHADOWS:
        try: cur=open(f"/proc/sys/{s}").read().strip()
        except OSError: continue
        dst=f"/proc/sys/{s}"; dummy=f"/dev/.shadow_{s.replace('/','_')}"
        try:
            _label = _sysctl_shadow_label(dst)
            if _label_kept(dummy, _label):
                deferred = selinux_ns.state()["unshared"]
                n_deferred += deferred
                n_labeled += not deferred
                mount(dummy,dst,None,MS_BIND)
                n_shadow += 1
                continue
            kmsg(f"shadow {s} dummy={'absent' if _label_of(dummy) is None else 'mislabeled'} "
                 f"dev_label={_label_of('/dev')!r}")
            open(dummy,"w").write(cur+"\n"); os.chmod(dummy,0o644)
            try:
                written = label_before_policy(dummy, _label)
                n_labeled += written
                n_deferred += not written
            except OSError as _e:
                kmsg(f"setxattr of shadow {s} failed ({_e})")
            mount(dummy,dst,None,MS_BIND)
            n_shadow += 1
        except OSError as e: kmsg(f"failed to bind shadow {s} ({e})")
    sysrq_ok, sysrq_labeled = _mask_sysrq_trigger()
    kmsg(f"harden_proc_sys ro={'ok' if ro_ok else 'FAIL'} "
         f"shadows={n_shadow} labeled={n_labeled} deferred={n_deferred} sysrq={'ok' if sysrq_ok else 'FAIL'} "
         f"sysrq_labeled={sysrq_labeled}")
    return ro_ok and n_labeled + n_deferred == n_shadow and sysrq_ok


ANDROID_PID_MAX = 32768


def pid_max_is_per_namespace(release):
    """return whether pid_max is per pid namespace"""
    m = re.match(r"(\d+)\.(\d+)", release)
    return bool(m) and (int(m.group(1)), int(m.group(2))) >= (6, 14)


def cap_pid_namespace_pid_max(value=ANDROID_PID_MAX):
    """write pid_max of the calling pid namespace from a child"""
    release = os.uname().release
    if not pid_max_is_per_namespace(release):
        kmsg(f"RHIZO_MARKER pid_max=unset reason=global-on-kernel-{release}")
        return False
    child = os.fork()
    if child == 0:
        ok = False
        step = "unshare"
        try:
            core.stdio_to_null()
            caps_why = selinux_ns.drop_to_init_caps()
            if caps_why:
                kmsg(f"RHIZO_MARKER pid_max=unset reason=caps-failed:{caps_why}")
                os._exit(HELPER_CAPS_EXIT)
            unshare(CLONE_NEWNS)
            step = "make-private"
            if not mount(None, "/", None, MS_REC | MS_PRIVATE):
                kmsg("failed to set MS_PRIVATE on / for pid_max")
            else:
                step = "mount-proc"
                if not mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC):
                    kmsg("failed to mount proc for pid_max")
                else:
                    step = "write"
                    with open("/proc/sys/kernel/pid_max", "w") as f:
                        f.write(f"{value}\n")
                    step = "read-back"
                    with open("/proc/sys/kernel/pid_max") as f:
                        got = f.read().strip()
                    ok = got == str(value)
                    if not ok:
                        kmsg(f"pid_max is {got} after a write of {value}")
        except Exception as e:
            kmsg(f"pid_max {step} failed with {type(e).__name__} ({e})")
        finally:
            os._exit(0 if ok else 1)
    _, status = os.waitpid(child, 0)
    ok = os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
    if not (os.WIFEXITED(status) and os.WEXITSTATUS(status) == HELPER_CAPS_EXIT):
        kmsg(f"RHIZO_MARKER pid_max={value}" if ok else f"RHIZO_MARKER pid_max=unset reason=child-status-{status}")
    return ok


def _pivot_and_harden(mount_proc=True):
    """pivot_root, drop the old root and harden /proc/sys"""
    os.chdir("/"); libc.umount2(b"/oldroot",2)
    if mount_proc and not harden_proc_sys():
        kmsg("harden_proc_sys() failed")
        os._exit(1)


def build_root_and_pivot(mount_proc=True, handoff=False):
    """build the root filesystem for init and call pivot_root"""
    phase("B", "build_root_and_pivot")
    why = device_state_dir_refusal(RHIZO_DEVICE_STATE_DIR, RHIZO_STATE_DIR)
    if why:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=device-state-dir-refused path={RHIZO_DEVICE_STATE_DIR} "
             f"root={RHIZO_STATE_DIR} why={why}")
        os._exit(1)
    if selinux_ns.selinux_mode() == "namespace":
        prelabel_vendor_tree(RUN_ROOT)
    else:
        stage_host_battery(RHIZO_DEVICE_STATE_DIR, core.host_battery())
    unshare_root_namespace(selinux_ns.selinux_mode(), handoff)
    net_core_snapshot = _build_flat_trees()
    _mount_extra_partitions(net_core_snapshot)
    _make_dev_nodes()
    _bind_sockets_and_shadows(mount_proc)
    mount_marker()
    _setup_cgroups_and_selinuxfs(handoff)
    _pivot_and_harden(mount_proc)


def setup_net_core_sysctls():
    """recreate /proc/sys/net/core as a labeled tmpfs"""
    _src = "/dev/.rhizo_net_core"
    _deadline = time.time() + 60
    while not os.path.isdir("/proc/sys/net/core") and time.time() < _deadline:
        time.sleep(0.005)
    if not os.path.isdir("/proc/sys/net/core"):
        kmsg("no /proc/sys/net/core after 60s")
        return
    _detach_if_mounted("/proc/sys/net/core")
    if not mount("tmpfs", "/proc/sys/net/core", "tmpfs", MS_NOSUID|MS_NODEV|MS_NOEXEC, "mode=0755"):
        kmsg("failed to mount tmpfs at /proc/sys/net/core")
        return
    mount(None, "/proc/sys/net/core", None, MS_SHARED)
    try:
        _names = os.listdir(_src)
    except OSError as _e:
        kmsg(f"failed to read the net.core snapshot ({_e})")
        return
    _label_here = host_selinux_mode()
    _n = _n_net = _n_bpf = 0
    for _nm in _names:
        try:
            open(f"/proc/sys/net/core/{_nm}", "w").write(
                open(f"{_src}/{_nm}").read())
            _n += 1
        except OSError:
            continue
        if not _label_here:
            continue
        _label = b"u:object_r:proc_bpf:s0\0" if _nm.startswith("bpf_") else b"u:object_r:proc_net:s0\0"
        try:
            os.setxattr(f"/proc/sys/net/core/{_nm}", "security.selinux", _label)
            if _nm.startswith("bpf_"): _n_bpf += 1
            else: _n_net += 1
        except OSError as _e:
            kmsg(f"setxattr of /proc/sys/net/core/{_nm} failed ({_e})")
    if "bpf_jit_enable" not in _names:
        kmsg("no bpf_jit_enable in the net.core snapshot")
    if not _label_here:
        kmsg(f"net.core files={_n}")
        return
    try:
        os.setxattr("/proc/sys/net/core", "security.selinux",
                     b"u:object_r:proc_net:s0\0")
    except OSError as _e:
        kmsg(f"setxattr of /proc/sys/net/core failed ({_e})")
    kmsg(f"net.core files={_n} proc_net={_n_net} proc_bpf={_n_bpf}")


DATA_RELEASE_MARKER_NAME = ".rhizo_data_release"


def data_root_label(mount_point):
    """return the root inode label of mount_point"""
    try:
        return os.getxattr(mount_point, "security.selinux").decode(
            errors="replace").rstrip("\0")
    except OSError:
        return ""


def data_unreadable_by_this_launch(mount_point):
    """return whether own_domain() is rhizo_host and the mount_point root label is a system data label"""
    return (own_domain() == "u:r:rhizo_host:s0"
            and data_root_label(mount_point) in ("u:object_r:system_data_root_file:s0",
                                                 "u:object_r:system_data_file:s0"))


def check_data_release_marker(mount_point, release, wipe_requested,
                              change_requested=False, log=kmsg):
    """compare the /data release marker with release"""
    marker = os.path.join(mount_point, DATA_RELEASE_MARKER_NAME)
    if data_unreadable_by_this_launch(mount_point):
        log(f"skipped {marker} with own_domain() rhizo_host and a sandbox /data label")
        log(f"RHIZO_MARKER data_release=unverifiable release={release}")
        return True
    try:
        prev = open(marker).read().strip()
    except FileNotFoundError:
        prev = ""
    except PermissionError as e:
        log(f"failed to read {marker} ({e})")
        log(f"RHIZO_MARKER data_release=unverifiable release={release}")
        return True
    except OSError as e:
        log(f"failed to read {marker} ({e})")
        prev = ""
    if prev and prev != release and not wipe_requested:
        if not change_requested:
            instance = os.environ.get("RHIZO_INSTANCE", "?")
            log(f"/data release is {prev}, expected "
                f"{release} on instance {instance} without RHIZO_WIPE_DATA=1")
            log(f"RHIZO_MARKER data_release_refused={prev}-vs-{release}")
            return False
        log(f"RHIZO_MARKER data_release_changed={prev}-to-{release}")
    try:
        with open(marker, "w") as f:
            f.write(release)
    except OSError as e:
        log(f"failed to write the /data release marker ({e})")
    log(f"RHIZO_MARKER data_release={release}")
    return True


RELEASE_SWITCH_PENDING_NAME = ".rhizo_release_switch_pending"


def sync_release_switch_marker(data_img, switching, log=kmsg):
    """arm or apply the release-switch marker"""
    pending = os.path.join(os.path.dirname(data_img) or "/", RELEASE_SWITCH_PENDING_NAME)
    if switching:
        open(pending, "w").close()
        return
    if os.path.exists(pending):
        log(f"RHIZO_MARKER release_switch_pending=found data_img={data_img}")
        for path in (data_img, data_img + ".meta", pending):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


KEYMINT_MIGRATION_MARKER_NAME = ".rhizo_keymint_migrated"

_KEYMINT_WRAPPED_PREFIX = "persistent.sqlite"

_SPBLOB_DIRNAME = "spblob"

_LOCKSETTINGS_DB_PREFIX = "locksettings.db"

_KEYMINT_NO_KEY_STAMP = "no-master-key"


def _keymint_key_generation(master_key_path):
    """return the sha256 of master_key_path"""
    try:
        with open(master_key_path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return _KEYMINT_NO_KEY_STAMP


def _remove_prefixed(directory, prefix, log):
    """remove the entries of directory with prefix"""
    try:
        entries = os.listdir(directory)
    except FileNotFoundError:
        return []
    except OSError as e:
        log(f"failed to list {directory} ({e})")
        return []
    removed = []
    for name in sorted(entries):
        if not name.startswith(prefix):
            continue
        path = os.path.join(directory, name)
        try:
            os.remove(path)
            removed.append(name)
        except OSError as e:
            log(f"failed to remove {path} ({e})")
    return removed


def _remove_spblob_dirs(mount_point, log):
    """remove the spblob directory of each user"""
    system_de = os.path.join(mount_point, "system_de")
    try:
        users = os.listdir(system_de)
    except FileNotFoundError:
        return []
    except OSError as e:
        log(f"failed to list {system_de} ({e})")
        return []
    removed = []
    for user in sorted((u for u in users if u.isdigit()), key=int):
        spblob_dir = os.path.join(system_de, user, _SPBLOB_DIRNAME)
        if not os.path.isdir(spblob_dir):
            continue
        try:
            shutil.rmtree(spblob_dir)
            removed.append(user)
        except OSError as e:
            log(f"failed to remove {spblob_dir} ({e})")
    return removed


_PROTECTOR_KEY_ALIAS_PREFIX = "synthetic_password_"
_SPBLOB_STATE = "spblob"

_KEYENTRY_LIVE = 1


def _keymint_unverifiable(path, err, log):
    """log an unreadable keystore migration store"""
    log(f"failed to read {path} ({err})")
    log("RHIZO_MARKER keymint_migration=unverifiable")


def _live_keystore_aliases(mount_point):
    """return the keyentry aliases with state Live in persistent.sqlite"""
    keystore_dir = os.path.join(mount_point, "misc", "keystore")
    try:
        names = set(os.listdir(keystore_dir))
    except FileNotFoundError:
        return set()
    if "persistent.sqlite" not in names:
        return set()
    scratch = tempfile.mkdtemp(prefix="rhizo-keystore-")
    try:
        for name in ("persistent.sqlite", "persistent.sqlite-wal", "persistent.sqlite-journal"):
            if name in names:
                shutil.copyfile(os.path.join(keystore_dir, name), os.path.join(scratch, name))
        db = sqlite3.connect(os.path.join(scratch, "persistent.sqlite"))
        try:
            rows = db.execute("SELECT alias FROM keyentry WHERE state = ?", (_KEYENTRY_LIVE,)).fetchall()
        finally:
            db.close()
    finally:
        shutil.rmtree(scratch)
    return {a.decode("utf-8", "replace") if isinstance(a, bytes) else a
            for (a,) in rows if a is not None}


def _repair_orphaned_lockstate(mount_point, log):
    """clear LockSettings spblob state with protector aliases missing from keystore2"""
    system_de = os.path.join(mount_point, "system_de")
    protectors = {}
    try:
        for user in sorted((u for u in os.listdir(system_de) if u.isdigit()), key=int):
            try:
                names = os.listdir(os.path.join(system_de, user, _SPBLOB_DIRNAME))
            except FileNotFoundError:
                continue
            ids = set()
            for name in names:
                stem, _, state = name.partition(".")
                if state != _SPBLOB_STATE:
                    continue
                try:
                    protector = int(stem, 16)
                except ValueError:
                    continue
                if protector != 0:
                    ids.add(protector)
            if ids:
                protectors[user] = ids
    except FileNotFoundError:
        return
    except PermissionError as e:
        _keymint_unverifiable(e.filename or system_de, e, log)
        return
    if not protectors:
        return
    try:
        live = _live_keystore_aliases(mount_point)
    except (OSError, sqlite3.Error) as e:
        _keymint_unverifiable(os.path.join(mount_point, "misc", "keystore", "persistent.sqlite"), e, log)
        return
    orphaned, mixed, gone_aliases = [], [], []
    for user, ids in protectors.items():
        gone = sorted(_PROTECTOR_KEY_ALIAS_PREFIX + format(p, "x") for p in ids
                      if _PROTECTOR_KEY_ALIAS_PREFIX + format(p, "x") not in live)
        if not gone:
            continue
        if len(gone) == len(ids):
            orphaned.append(user)
            gone_aliases += gone
        else:
            mixed.append(user)
    if mixed:
        log(f"LockSettings users {', '.join(mixed)} have live and missing protector aliases")
        log(f"RHIZO_MARKER keymint_migration=lockstate-mixed users={','.join(mixed)}")
    if not orphaned:
        return
    cleared = []
    for user in orphaned:
        spblob_dir = os.path.join(system_de, user, _SPBLOB_DIRNAME)
        try:
            shutil.rmtree(spblob_dir)
            cleared.append(user)
        except OSError as e:
            log(f"failed to remove {spblob_dir} ({e})")
    db_removed = _remove_prefixed(os.path.join(mount_point, "system"), _LOCKSETTINGS_DB_PREFIX, log)
    log(f"LockSettings protector aliases missing from keystore2 ({', '.join(gone_aliases)}), "
        f"spblob removed for users {', '.join(cleared) or '(none)'}, locksettings.db "
        f"{'removed (' + ', '.join(db_removed) + ')' if db_removed else 'absent'}")
    log("RHIZO_MARKER keymint_migration=lockstate-repaired spblob=removed-%d locksettings_db=removed-%d"
        % (len(cleared), len(db_removed)))


def migrate_keystore_for_keymint_persistence(mount_point, log=kmsg):
    """remove the keystore and LockSettings state of an old KeyMint key"""
    master_key = os.path.join(mount_point, "rhizo_keymint", "master.key")
    if data_unreadable_by_this_launch(mount_point):
        _keymint_unverifiable(master_key, "own_domain() rhizo_host and a sandbox /data label", log)
        return
    try:
        generation = _keymint_key_generation(master_key)
    except PermissionError as e:
        _keymint_unverifiable(master_key, e, log)
        return
    marker = os.path.join(mount_point, KEYMINT_MIGRATION_MARKER_NAME)
    try:
        stamped = open(marker).read().strip()
    except FileNotFoundError:
        stamped = None
    except OSError as e:
        _keymint_unverifiable(marker, e, log)
        return
    if stamped == generation:
        _repair_orphaned_lockstate(mount_point, log)
        return
    if stamped == _KEYMINT_NO_KEY_STAMP:
        try:
            with open(marker, "w") as f:
                f.write(generation)
        except OSError as e:
            log(f"failed to write the keystore migration marker ({e})")
            log("RHIZO_MARKER keymint_migration=key-record-failed")
        else:
            log("RHIZO_MARKER keymint_migration=key-recorded")
        _repair_orphaned_lockstate(mount_point, log)
        return
    keystore_dir = os.path.join(mount_point, "misc", "keystore")
    removed = _remove_prefixed(keystore_dir, _KEYMINT_WRAPPED_PREFIX, log)
    spblob_removed = _remove_spblob_dirs(mount_point, log)
    locksettings_dir = os.path.join(mount_point, "system")
    locksettings_removed = _remove_prefixed(locksettings_dir, _LOCKSETTINGS_DB_PREFIX, log)
    try:
        with open(marker, "w") as f:
            f.write(generation)
    except OSError as e:
        log(f"failed to write the keystore migration marker ({e})")
    if removed:
        log(f"removed {len(removed)} keystore files "
            f"({', '.join(removed)}) from misc/keystore")
    if spblob_removed or locksettings_removed:
        log("spblob removed for users "
            f"{', '.join(spblob_removed) if spblob_removed else '(none)'}, "
            f"locksettings.db {'removed (' + ', '.join(locksettings_removed) + ')' if locksettings_removed else 'absent'}")
    if removed or spblob_removed or locksettings_removed:
        log("RHIZO_MARKER keymint_migration=removed-%d spblob=removed-%d locksettings_db=removed-%d"
            % (len(removed), len(spblob_removed), len(locksettings_removed)))
    else:
        log("RHIZO_MARKER keymint_migration=not-needed")


def _per_dir_counts(ops):
    """return the bind count per directory of the plan"""
    out = {}
    for op in ops:
        if op["op"] != "bind":
            continue
        key = (op["rel"] if op["kind"] in ("subtree", "dir")
               else (os.path.dirname(op["rel"]) or "."))
        out[key] = out.get(key, 0) + 1
    return out


def _mb(delta, ns):
    """format a mount-count delta in bytes and MB"""
    return "%d x %d ns x %d B = %d B = %.2f MB" % (
        delta, ns, MNT_CACHE_BYTES, delta * ns * MNT_CACHE_BYTES,
        delta * ns * MNT_CACHE_BYTES / 1e6)


def plan_mounts_report(lower, upper, flat, ns, top=20):
    """return the mount count lines and data for each mount lever"""
    off_ops, off, off_err = plan_flat_tree(lower, upper, flat, dir_binds=False)
    on_ops, on, on_err = plan_flat_tree(lower, upper, flat, dir_binds=True)
    lines = ["flat tree %s + %s -> %s" % (lower, upper, flat),
             "  levers_off mounts=%d per_file=%d subtree=%d"
             % (off["mounts"], off["files"], off["subtrees"]),
             "  dir_binds mounts=%d per_file=%d subtree=%d dir=%d overmount=%d"
             % (on["mounts"], on["files"], on["subtrees"], on["dirbinds"], on["overmounts"]),
             "  lever1_flat_dir_binds " + _mb(off["mounts"] - on["mounts"], ns)]
    off_dirs, on_dirs = _per_dir_counts(off_ops), _per_dir_counts(on_ops)
    ranked = sorted(((k, off_dirs.get(k, 0)) for k in set(off_dirs) | set(on_dirs)),
                    key=lambda kv: (-max(kv[1], on_dirs.get(kv[0], 0)), kv[0]))[:top]
    lines.append("  per_directory top=%d columns=off,on" % top)
    for name, n in ranked:
        lines.append("    %-52s %5d %5d" % (name[:52], n, on_dirs.get(name, 0)))
    apex_dir = os.path.join(lower, "apex")
    if os.path.isdir(apex_dir):
        entries = len(os.listdir(apex_dir))
        lines.append("  lever2_apex_dir_bind mounts=%d->3 %s"
                     % (entries + 1, _mb(entries + 1 - 3, ns)))
    keep = _sys_kernel_keep()
    if keep and os.path.isdir("/sys/kernel"):
        children = os.listdir("/sys/kernel")
        kept = [c for c in children if c in keep]
        lines.append("  lever3_sys_kernel_subset "
                     "mounts=%d->%d %s"
                     % (len(children), len(kept), _mb(len(children) - len(kept), ns)))
    for label, errs in (("off", off_err), ("dir binds", on_err)):
        if errs:
            lines.append("  walk_errors lever=%s count=%d first=%s" % (label, len(errs), errs[0]))
    return lines, {"off": off, "dir_binds": on, "ns": ns,
                   "bytes_per_mount_ns": MNT_CACHE_BYTES,
                   "per_dir_off": off_dirs, "per_dir_on": on_dirs,
                   "ops_off": off_ops, "ops_on": on_ops}


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--plan-mounts", nargs=2, metavar=("LOWER", "UPPER"), required=True)
    ap.add_argument("--flat", default=f"{RUN_ROOT}/plan_flat")
    ap.add_argument("--ns", type=int, default=MNT_NAMESPACES)
    ap.add_argument("--bytes", type=int, default=MNT_CACHE_BYTES,
                    help="mnt_cache bytes per mount per namespace")
    ap.add_argument("--json", default="")
    a = ap.parse_args()
    MNT_CACHE_BYTES = a.bytes
    _lines, _data = plan_mounts_report(a.plan_mounts[0], a.plan_mounts[1], a.flat, a.ns)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(_data, f, indent=1)
    print("\n".join(_lines))
