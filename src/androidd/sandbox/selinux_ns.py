"""Android's policy in its SELinux namespace"""
import contextlib
import ctypes
import errno
import fcntl
import os
import re
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import time

from sandbox import core
from sandbox import selinux_labels
from sandbox.core import (CLONE_NEWNS, DROP_CAPS, MS_BIND, MS_NODEV, MS_NOEXEC, MS_NOSUID,
    MS_PRIVATE, MS_RDONLY, MS_REC, PR_CAPBSET_DROP, PR_SET_NAME, RHIZO_CACHE_DIR, RHIZO_ENFORCING,
    SANDBOX_ID, SELINUXNS_RECORDS_DIR, kmsg, libc, mount)

NR_LSM_GET_SELF_ATTR = 459
NR_LSM_SET_SELF_ATTR = 460
NR_FSOPEN, NR_FSCONFIG, NR_FSMOUNT = 430, 431, 432
FSOPEN_CLOEXEC = FSMOUNT_CLOEXEC = 1
FSCONFIG_CMD_CREATE = 6
LSM_ATTR_CURRENT = 100
LSM_ATTR_UNSHARE = 106
LSM_ID_SELINUX = 101
MODE_FILE = "/run/rhizo-selinux-mode"
HOST_ENFORCE_NODE = "/sys/fs/selinux/enforce"
ANDROID_ENFORCE_FILE = f"{SELINUXNS_RECORDS_DIR}/android-enforce"
VERDICT_FILE = f"{SELINUXNS_RECORDS_DIR}/selinuxns-verdict"
STOP_REQUEST_FILE = f"{SELINUXNS_RECORDS_DIR}/stop-requested"
START_ID_FILE = f"{SELINUXNS_RECORDS_DIR}/start-id"
NR_LANDLOCK_CREATE_RULESET = 444
NR_LANDLOCK_RESTRICT_SELF = 446
NR_FCHMODAT2 = 452
AT_EMPTY_PATH = 0x1000
PROC_SUPER_MAGIC = 0x9fa0
LANDLOCK_CREATE_RULESET_VERSION = 1 << 0
LANDLOCK_SCOPE_SIGNAL = 1 << 1
LANDLOCK_MIN_ABI = 6
SELINUX_MAGIC = 0xf97cff8c
DEVPTS_SUPER_MAGIC = 0x1cd1
RELABELLER_CONTEXTS = ("kernel", "u:r:kernel:s0")
PRIVATE_SELINUXFS = "/mnt"
HOST_SELINUXFS = "/sys/fs/selinux"
MNT_DETACH = 2
PASSES_LIMIT_S = 20
RELABELLER_DEADLINE_S = 180
RELABELLER_REFUSED_EXIT = 3
DONE_ENFORCED = b"1"
DONE_PERMISSIVE = b"p"
DONE_FAILED = b"f"
REASON_MAX = 200
REASON_WAIT_S = 0.25
_DONE_SENT = []
_REASON_BAD = re.compile(rb"[^A-Za-z0-9_.:=,/@-]")
RELABEL_PASSES = ("flat", "root-objects", "sysctl-shadows", "dev-file-contexts")
TMPFS_LABEL = "u:object_r:tmpfs:s0"
LABEL_REQUEST_MAX = 512
CAP_LAST_CAP = "/proc/sys/kernel/cap_last_cap"
PR_SET_NO_NEW_PRIVS = 38
PR_CAP_AMBIENT = 47
PR_CAP_AMBIENT_CLEAR_ALL = 4
LINUX_CAPABILITY_VERSION_3 = 0x20080522
_EVENT_NODE = re.compile(rb"/dev/input/event[0-9]{1,6}")
_HIDRAW_NODE = re.compile(rb"/dev/hidraw[0-9]{1,6}")
HIDRAW_LABEL = b"u:object_r:hidraw_device:s0"
LABEL_SERVICE_CONTEXT = b"u:r:rhizo_input_label:s0"
HELPER_CONTEXTS = {"stage": b"u:r:rhizo_ns_stage:s0", "relabel": b"u:r:rhizo_ns_relabel:s0",
                   "label": b"u:r:rhizo_ns_label:s0"}
_DEV_AND_INODE = re.compile(rb"([0-9]{1,4}):([0-9]{1,7}) ([0-9]{1,20})")
_FC_KINDS = {"-b": stat.S_ISBLK, "-c": stat.S_ISCHR, "-d": stat.S_ISDIR, "--": stat.S_ISREG,
             "-l": stat.S_ISLNK, "-s": stat.S_ISSOCK, "-p": stat.S_ISFIFO}
_libc = ctypes.CDLL(None, use_errno=True)


def host_context():
    """return this task's SELinux context"""
    try:
        with open("/proc/self/attr/current") as f:
            return f.read().strip("\0\n")
    except FileNotFoundError:
        return "kernel"
    except OSError as e:
        if e.errno != errno.EINVAL:
            raise
        return "kernel"


def host_policy_state(node=HOST_ENFORCE_NODE):
    """return the state of the host's policy"""
    if ":" not in host_context():
        return "none"
    try:
        with open(node) as f:
            return "permissive" if f.read().strip() == "0" else "enforcing"
    except OSError:
        return "unknown"


def namespace_supported():
    """return whether the kernel answers LSM_ATTR_UNSHARE for SELinux"""
    buf = ctypes.create_string_buffer(64)
    size = ctypes.c_uint32(64)
    rc = _libc.syscall(ctypes.c_long(NR_LSM_GET_SELF_ATTR), ctypes.c_long(LSM_ATTR_UNSHARE), buf,
                       ctypes.byref(size), ctypes.c_long(0))
    return rc >= 0


def landlock_version():
    """return the Landlock ABI query's result and errno"""
    abi = _libc.syscall(ctypes.c_long(NR_LANDLOCK_CREATE_RULESET), None, ctypes.c_size_t(0),
                        ctypes.c_uint32(LANDLOCK_CREATE_RULESET_VERSION))
    return abi, ctypes.get_errno() if abi < 0 else 0


def landlock_abi():
    """return the running kernel's Landlock ABI version"""
    return max(landlock_version()[0], 0)


def selinux_mode(env=os.environ):
    """return namespace, host, or refuse:<reason> for this start"""
    mode = env.get("RHIZO_SELINUX_MODE", "namespace")
    if mode == "host":
        return "host"
    if mode != "namespace":
        return f"refuse:unknown-mode-{mode}"
    if not namespace_supported():
        return "refuse:kernel-has-no-selinux-namespaces"
    if landlock_abi() < LANDLOCK_MIN_ABI:
        return "refuse:kernel-has-no-landlock"
    return "namespace"


def refusal_text(reason):
    """return the fix sentence for a refusal reason"""
    if reason == "kernel-has-no-selinux-namespaces":
        return "boot the Rhizo kernel (uname -r ends in -rhizo) to start Android"
    if reason == "kernel-has-no-landlock":
        return "the Rhizo kernel runs without Landlock ABI 6; remove lsm= from its boot line or add landlock to it"
    if reason.startswith("unknown-mode-"):
        return f"RHIZO_SELINUX_MODE={reason[len('unknown-mode-'):]} is not namespace or host"
    return reason


def write_mode_file(mode, path=MODE_FILE):
    """record the chosen mode for host-side readers"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w") as f:
            f.write(mode + "\n")
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


_STATE = {"unshared": False}


def state():
    """return the namespace state of this launcher process"""
    return _STATE


def unshare_namespace(state_file=ANDROID_ENFORCE_FILE):
    """give this task a new SELinux namespace with no policy"""
    ctx = ctypes.create_string_buffer(struct.pack("<QQQQ", LSM_ID_SELINUX, 0, 32, 0), 32)
    rc = _libc.syscall(ctypes.c_long(NR_LSM_SET_SELF_ATTR), ctypes.c_long(LSM_ATTR_UNSHARE), ctx,
                       ctypes.c_long(32), ctypes.c_long(0))
    if rc != 0:
        err = ctypes.get_errno()
        kmsg(f"RHIZO_MARKER selinuxns=unshare-failed errno={err} ({os.strerror(err)})")
        os._exit(1)
    _STATE["unshared"] = True
    if state_file is not None:
        try:
            os.makedirs(os.path.dirname(state_file), mode=0o755, exist_ok=True)
            write_android_enforce("0", state_file)
        except OSError as e:
            report_record_write_failure(state_file, "0", e)


def clear_selinuxfs_mounts(target):
    """detach up to 8 mounts stacked at target"""
    for _ in range(8):
        if libc.umount2(target.encode(), 2) != 0:
            break


def mount_own_selinuxfs(target):
    """mount this task's SELinux namespace's selinuxfs at target"""
    os.makedirs(target, exist_ok=True)
    clear_selinuxfs_mounts(target)
    if not mount("selinuxfs", target, "selinuxfs", MS_NOSUID | MS_NOEXEC):
        kmsg(f"RHIZO_MARKER selinuxns=selinuxfs-mount-failed target={target}")
        os._exit(1)
    try:
        with open(target + "/enforce") as f:
            enforce = f.read().strip()
    except OSError as e:
        enforce = f"<{e}>"
    kmsg(f"RHIZO_MARKER selinuxns=selinuxfs enforce={enforce}")


def _mount_image(image, target):
    """mount image read-only at target through a loop device"""
    os.makedirs(target, exist_ok=True)
    try:
        dev, fd = core.loop_attach(image, read_only=True, autoclear=True)
    except OSError as e:
        return f"loop-attach:{e.errno}"
    try:
        return None if mount(dev, target, "ext4", MS_RDONLY) else f"mount:{target}"
    finally:
        os.close(fd)


def stage_gsi_labeled(image, dest, work, launcher, python=sys.executable, run=subprocess.run):
    """copy image's system tree to dest under Android's policy"""
    os.unshare(os.CLONE_NEWNS)
    if not mount(None, "/", None, MS_REC | MS_PRIVATE):
        return "private-mounts"
    compile_mnt, copy_mnt = f"{work}/compile", f"{work}/copy"
    why = _mount_image(image, compile_mnt) or _mount_image(image, copy_mnt)
    if why:
        return why
    if not os.path.isdir(f"{compile_mnt}/system"):
        return "no-system-dir"
    out = run([python, launcher, "prepare-sepolicy"], env=dict(os.environ, RHIZO_GSI=f"{compile_mnt}/system"),
              capture_output=True, text=True)
    m = re.search(r"^PREPARE_SEPOLICY_OK cache=(\S+)$", out.stdout, re.M)
    if not m:
        last = ((out.stdout + out.stderr).strip().splitlines() or [f"rc={out.returncode}"])[-1]
        return "policy-compile:" + clean_reason(last.encode())
    why = enter_policy_namespace(m.group(1), "stage")
    if why:
        return why
    cp = run(["cp", "-a", f"{copy_mnt}/system", dest])
    return None if cp.returncode == 0 else f"cp-rc={cp.returncode}"


def load_namespace_policy(policy):
    """load policy into this task's SELinux namespace"""
    fds = []
    try:
        fd = _libc.syscall(ctypes.c_long(NR_FSOPEN), b"selinuxfs", ctypes.c_long(FSOPEN_CLOEXEC))
        if fd < 0:
            return f"fsopen:{ctypes.get_errno()}"
        fds.append(fd)
        if _libc.syscall(ctypes.c_long(NR_FSCONFIG), ctypes.c_long(fd), ctypes.c_long(FSCONFIG_CMD_CREATE),
                         None, None, ctypes.c_long(0)) != 0:
            return f"fsconfig:{ctypes.get_errno()}"
        mnt = _libc.syscall(ctypes.c_long(NR_FSMOUNT), ctypes.c_long(fd), ctypes.c_long(FSMOUNT_CLOEXEC),
                            ctypes.c_long(0))
        if mnt < 0:
            return f"fsmount:{ctypes.get_errno()}"
        fds.append(mnt)
        with open(policy, "rb") as src:
            data = src.read()
        fds.append(os.open("load", os.O_WRONLY | os.O_CLOEXEC, dir_fd=mnt))
        if os.write(fds[-1], data) != len(data):
            return "policy-load:short-write"
    except OSError as e:
        return f"policy-load:{e.errno}"
    finally:
        for f in fds:
            os.close(f)
    return None


def enter_policy_namespace(policy, helper):
    """enter a helper domain in a child policy namespace"""
    context = HELPER_CONTEXTS[helper]
    request = setcon_request(context)
    in_domain = not core.host_selinux_mode()
    unshare_namespace(state_file=None)
    why = load_namespace_policy(policy)
    if why or not in_domain:
        return why
    why = enter_helper_domain(request, context)
    if not why and helper == "relabel":
        label_host_devices()
    return f"helper-domain:{why}" if why else None


def write_android_enforce(value, path, dir_fd=None):
    """write value to Android's enforce state file"""
    name = os.path.basename(path) if dir_fd is not None else path
    tmp = f"{name}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_CLOEXEC, 0o644, dir_fd=dir_fd)
    try:
        os.write(fd, f"{value}\n".encode())
    finally:
        os.close(fd)
    os.replace(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)


_FC_META = re.compile(r"[.\[\](){}*+?|^$\\]")


def file_contexts_matcher(fc_paths, under):
    """return the label lookup for paths under a root"""
    entries, unusable = [], []
    for fc in fc_paths:
        try:
            with open(fc, errors="replace") as f:
                lines = f.read().splitlines()
        except OSError as e:
            kmsg(f"file_contexts for {under}: cannot read {fc}: {e.strerror}")
            continue
        for ln in lines:
            parts = ln.split()
            if len(parts) < 2 or parts[0].startswith("#"):
                continue
            pat = parts[0]
            m = _FC_META.search(pat)
            prefix = pat if m is None else pat[:m.start()]
            if not (under.startswith(prefix) or prefix.startswith(under)):
                continue
            try:
                rx = re.compile(pat + r"\Z")
            except re.error:
                unusable.append(pat)
                continue
            entries.append((rx, (m is None, len(prefix)), parts[-1],
                            _FC_KINDS.get(parts[1]) if len(parts) == 3 else None))

    def label_of(apath, mode):
        """return the exact, then longest-stem, matching label"""
        best = None
        for i, (rx, stem, lbl, kind) in enumerate(entries):
            if (kind is None or kind(mode)) and rx.match(apath) and (best is None or (stem, i) > best[0]):
                best = ((stem, i), lbl)
        return best[1] if best else None
    return label_of, unusable


def label_by_file_contexts(host_root, under, fc_paths, relabel=lambda cur: True, fixed=(), prune=lambda p: False):
    """label the tree at host_root as Android's under"""
    label_of, unusable = file_contexts_matcher(fc_paths, under)
    fixed = dict(fixed)
    todo = [host_root]
    for dp, dns, fns in os.walk(host_root):
        dns[:] = [d for d in dns if not prune(os.path.join(dp, d))]
        todo += [p for p in (os.path.join(dp, n) for n in dns + fns) if not prune(p)]
    counts = {"labeled": 0, "kept": 0, "unmatched": 0, "refused": 0, "failed": 0, "gone": 0,
              "unusable": len(unusable)}
    errors, refused, gone = [], [], []
    for host in todo:
        apath = under + host[len(host_root):]
        try:
            mode = os.lstat(host).st_mode
        except FileNotFoundError:
            gone.append(apath)
            continue
        except OSError as e:
            counts["failed"] += 1
            errors.append(f"{apath}: {e.strerror}")
            continue
        want = fixed.get(apath) or label_of(apath, mode)
        if want is None:
            counts["unmatched"] += 1
            continue
        lnk = stat.S_ISLNK(mode)
        try:
            cur = os.getxattr(host, "security.selinux", follow_symlinks=not lnk).decode(errors="replace").rstrip("\0")
        except FileNotFoundError:
            gone.append(apath)
            continue
        except OSError as e:
            if e.errno not in (errno.ENODATA, errno.EOPNOTSUPP):
                counts["failed"] += 1
                errors.append(f"{apath}: read label: {e.strerror}")
                continue
            cur = ""
        if cur == want or not relabel(cur):
            counts["kept"] += 1
            continue
        try:
            if selinux_labels.label_write(host, (want + "\0").encode(), follow_symlinks=not lnk, skipped=refused):
                counts["labeled"] += 1
        except FileNotFoundError:
            gone.append(apath)
        except OSError as e:
            counts["failed"] += 1
            errors.append(f"{apath}: {e.strerror}")
    counts["refused"], counts["gone"] = len(refused), len(gone)
    counts["errors"] = (errors + [f"refused: {under}{p[len(host_root):]}" for p in refused] +
                        [f"gone: {p}" for p in gone] + [f"unusable: {p}" for p in unusable])[:6]
    return counts


def dev_pass_skips(newroot):
    """return the /dev skip test"""
    from sandbox import rootfs
    sink = newroot + rootfs.UEVENT_SINK_DIR

    def skip(path):
        """skip the read-only uevent sink and devpts"""
        return path == sink or fs_type(path) == DEVPTS_SUPER_MAGIC
    return skip


def label_dev_by_file_contexts(newroot, fc_paths):
    """label raw /dev nodes by file_contexts"""
    return label_by_file_contexts(f"{newroot}/dev", "/dev", fc_paths, relabel=lambda cur: cur == TMPFS_LABEL,
                                  prune=dev_pass_skips(newroot))


def dev_file_contexts(newroot):
    """return the plat and vendor file_contexts paths the /dev pass reads"""
    return [f"{RHIZO_CACHE_DIR}/plat_file_contexts", f"{newroot}/vendor/etc/selinux/vendor_file_contexts"]


def label_sysctl_shadows(newroot):
    """give each sysctl shadow Android's proc label"""
    from sandbox import rootfs
    done = []
    for path, label in rootfs.sysctl_shadow_spec():
        dst = newroot + path
        if os.path.exists(dst) and selinux_labels.label_write(dst, (label + "\0").encode()):
            done.append(label)
    return done


def label_net_core(path="/proc/sys/net/core"):
    """label the net.core nodes"""
    done = kept = 0
    failed = []
    try:
        names = [""] + os.listdir(path)
    except OSError as e:
        return done, kept, [f"list: {e.strerror}"]
    for nm in names:
        p = path + (f"/{nm}" if nm else "")
        try:
            if os.getxattr(p, "security.selinux").rstrip(b"\0") != TMPFS_LABEL.encode():
                kept += 1
                continue
            want = b"u:object_r:proc_bpf:s0\0" if nm.startswith("bpf_") else b"u:object_r:proc_net:s0\0"
            if selinux_labels.label_write(p, want):
                done += 1
            else:
                kept += 1
        except OSError as e:
            if len(failed) < 4:
                failed.append(f"{nm}: {e.strerror}")
    return done, kept, failed


def _real_passes():
    """return the relabel passes the host primer runs"""
    return {
        "flat": lambda newroot, staged: selinux_labels.relabel_flat_trees_now(),
        "root-objects": lambda newroot, staged: selinux_labels.relabel_root_objects_now(newroot, staged=staged),
        "sysctl-shadows": lambda newroot, staged: label_sysctl_shadows(newroot),
        "dev-file-contexts": lambda newroot, staged: label_dev_by_file_contexts(newroot, dev_file_contexts(newroot)),
    }


def _write_enforce(fd):
    """write 1 through an enforce node fd"""
    before = os.pread(fd, 16, 0).decode(errors="replace").strip()
    os.pwrite(fd, b"1", 0)
    after = os.pread(fd, 16, 0).decode(errors="replace").strip()
    return before, after


def fs_type(path):
    """return the filesystem magic statfs reports for path, or -1"""
    buf = ctypes.create_string_buffer(120)
    if libc.statfs(path.encode(), buf) != 0:
        return -1
    return struct.unpack_from("<Q", buf.raw, 0)[0]


def fd_fs_type(fd):
    """return the filesystem magic fstatfs reports for fd"""
    buf = ctypes.create_string_buffer(120)
    if _libc.fstatfs(ctypes.c_int(fd), buf) != 0:
        raise _errno_error()
    return struct.unpack_from("<Q", buf.raw, 0)[0]


def selinuxfs_mount_fd():
    """return a detached mount of this namespace's selinuxfs"""
    fd = _libc.syscall(ctypes.c_long(NR_FSOPEN), b"selinuxfs", ctypes.c_long(FSOPEN_CLOEXEC))
    if fd < 0:
        raise OSError(ctypes.get_errno(), "fsopen selinuxfs")
    try:
        if _libc.syscall(ctypes.c_long(NR_FSCONFIG), ctypes.c_long(fd), ctypes.c_long(FSCONFIG_CMD_CREATE),
                         None, None, ctypes.c_long(0)) != 0:
            raise OSError(ctypes.get_errno(), "fsconfig selinuxfs")
        mnt = _libc.syscall(ctypes.c_long(NR_FSMOUNT), ctypes.c_long(fd), ctypes.c_long(FSMOUNT_CLOEXEC),
                            ctypes.c_long(0))
        if mnt < 0:
            raise OSError(ctypes.get_errno(), "fsmount selinuxfs")
        return mnt
    finally:
        os.close(fd)


def open_host_selinuxfs(path=HOST_SELINUXFS):
    """return an fd on this namespace's selinuxfs"""
    try:
        fd = os.open(path, os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
    except FileNotFoundError:
        return selinuxfs_mount_fd()
    try:
        magic = fd_fs_type(fd)
    except OSError:
        os.close(fd)
        raise
    if magic == SELINUX_MAGIC:
        return fd
    os.close(fd)
    return selinuxfs_mount_fd()


def _open_private_enforce(target=PRIVATE_SELINUXFS):
    """mount selinuxfs privately and open its enforce node"""
    if not mount("selinuxfs", target, "selinuxfs", MS_NOSUID | MS_NOEXEC):
        return -1
    try:
        return os.open(f"{target}/enforce", os.O_RDWR | os.O_CLOEXEC)
    except OSError as e:
        kmsg(f"selinuxns: cannot open {target}/enforce: {e!r}")
        return -1


def _unmount_copy_enforce(node="/sys/fs/selinux/enforce"):
    """detach the mounts bound over the enforce node"""
    n = 0
    for _ in range(8):
        if fs_type(node) == SELINUX_MAGIC:
            return n, True
        libc.umount2(node.encode(), 2)
        n += 1
    return n, fs_type(node) == SELINUX_MAGIC


def _wait_dev_labelable(newroot, sleep):
    """wait up to 60s for newroot/dev to take a label"""
    t1 = time.time()
    while time.time() - t1 < 60:
        try:
            cur = os.getxattr(f"{newroot}/dev", "security.selinux")
            return "ok" if selinux_labels.label_write(f"{newroot}/dev", cur) else "refused"
        except OSError as e:
            if e.errno != errno.EOPNOTSUPP:
                return f"<{e.strerror}>"
            sleep(0.05)
    return "timeout"


class PassesCut(BaseException):
    """raised by the passes timer"""


_PASSES_CUT_ARMED = {"on": False}


def _cut_passes(signum, frame):
    """stop the armed relabel passes"""
    if _PASSES_CUT_ARMED["on"]:
        _PASSES_CUT_ARMED["on"] = False
        raise PassesCut()


def _run_passes(newroot, staged, sleep, passes):
    """run each relabel pass"""
    t1 = time.time()
    ready = _wait_dev_labelable(newroot, sleep)
    kmsg(f"RHIZO_MARKER selinuxns=dev-labelable state={ready} t={time.time() - t1:.2f}s")
    table = _real_passes() if passes is None else passes
    for name in RELABEL_PASSES:
        try:
            result = table[name](newroot, staged)
        except Exception as e:
            kmsg(f"RHIZO_MARKER selinuxns=pass-failed name={name} err={e!r}"[:900])
            continue
        kmsg((f"RHIZO_MARKER selinuxns={name}" + ("" if result is None else f" result={result!r}"))[:900])


def _flip(mntns_fd, enforce_fd, writer, t0):
    """join the sandbox's mount namespace and enforce"""
    if libc.setns(mntns_fd, CLONE_NEWNS) != 0:
        errno_ = ctypes.get_errno()
        kmsg(f"RHIZO_MARKER selinuxns=setns-failed errno={errno_}")
        return f"setns-failed:errno={errno_}"
    n, reached = _unmount_copy_enforce()
    kmsg(f"RHIZO_MARKER selinuxns=unmount-copy-enforce unmounts={n} real-node={reached} net-core={label_net_core()}")
    if not reached:
        kmsg("RHIZO_MARKER selinuxns=enforce-failed reason=copy-node-still-mounted")
        return "enforce-failed:copy-node-still-mounted"
    kmsg(f"RHIZO_MARKER selinuxns=enforce-write t={time.time() - t0:.2f}s")
    try:
        before, after = writer(enforce_fd)
    except OSError as e:
        return f"enforce-failed:err={e!r}"
    if after != "1":
        return f"enforce-failed:before={before},after={after}"
    return ""


def current_context():
    """return this task's SELinux context"""
    return own_context().decode(errors="replace")


def _relabel_after_load(newroot, staged, mntns_fd, write_primer_script, attr_reader=current_context, sleep=time.sleep,
                        passes=None, enforce_writer=None, on_load=None):
    """run the post-load relabels and enforce"""
    t0 = time.time()
    if write_primer_script is not None:
        try:
            write_primer_script()
        except Exception as e:
            kmsg(f"RHIZO_MARKER selinuxns=pass-failed name=write-primer-script err={e!r}")
    ctx = ""
    while time.time() - t0 < 180:
        ctx = attr_reader()
        if ":" in ctx:
            break
        sleep(0.01)
    else:
        kmsg(f"RHIZO_MARKER selinuxns=no-policy-load ctx={ctx!r} after 180s")
        return DONE_FAILED
    if on_load is not None:
        why = on_load()
        if why:
            return failed(why)
    kmsg(f"RHIZO_MARKER selinuxns=wait-load ctx={ctx!r} t={time.time() - t0:.2f}s")
    old = signal.signal(signal.SIGALRM, _cut_passes)
    _PASSES_CUT_ARMED["on"] = True
    signal.setitimer(signal.ITIMER_REAL, PASSES_LIMIT_S)
    try:
        _run_passes(newroot, staged, sleep, passes)
        _PASSES_CUT_ARMED["on"] = False
    except PassesCut:
        kmsg(f"RHIZO_MARKER selinuxns=passes-cut after={PASSES_LIMIT_S}s")
    finally:
        _PASSES_CUT_ARMED["on"] = False
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old)
    if not RHIZO_ENFORCING:
        kmsg("RHIZO_MARKER selinuxns=permissive-kept (RHIZO_PERMISSIVE=1)")
        return DONE_PERMISSIVE
    enforce_fd = _open_private_enforce()
    if enforce_fd < 0:
        kmsg("RHIZO_MARKER selinuxns=enforce-failed reason=no-private-selinuxfs")
        return DONE_FAILED
    try:
        why = _flip(mntns_fd, enforce_fd, _write_enforce if enforce_writer is None else enforce_writer, t0)
        if why:
            return failed(why)
    finally:
        os.close(enforce_fd)
    return DONE_ENFORCED


def _close_inherited_fds(keep):
    """close every inherited fd except stdio and keep"""
    lo = 3
    for fd in sorted(k for k in keep if k >= 3):
        os.closerange(lo, fd)
        lo = fd + 1
    os.closerange(lo, os.sysconf("SC_OPEN_MAX"))


class DoneFailed(bytes):
    """the failure done byte with the reason line written after it"""
    reason = ""


def failed(reason):
    """return the failure done byte carrying reason"""
    done = DoneFailed(DONE_FAILED)
    done.reason = reason
    return done


def clean_reason(raw):
    """return the cleaned first line of raw"""
    return _REASON_BAD.sub(b"_", raw.split(b"\n")[0][:REASON_MAX]).decode()


def read_failure_reason(done_fd, reasons=None):
    """read and log the reason line after a failure byte"""
    ready, _, _ = select.select([done_fd], [], [], REASON_WAIT_S)
    why = clean_reason(os.read(done_fd, REASON_MAX + 1)) if ready else ""
    if why:
        kmsg(f"RHIZO_MARKER selinuxns=relabeller-error reason={why}")
        if reasons is not None:
            reasons.append(why)
    return why


def _write_done(done_fd, byte):
    """write byte and its reason line to the done pipe"""
    reason = getattr(byte, "reason", "")
    _DONE_SENT.append(bytes(byte))
    if done_fd >= 0:
        try:
            os.write(done_fd, bytes(byte) + (clean_reason(reason.encode()).encode() + b"\n" if reason else b""))
        except OSError:
            pass


def namespace_is_host(host_selinuxfs_dev):
    """return whether this namespace's selinuxfs is host_selinuxfs_dev"""
    if not isinstance(host_selinuxfs_dev, int) or host_selinuxfs_dev <= 0:
        raise OSError(errno.EINVAL, f"no host selinuxfs device number: {host_selinuxfs_dev!r}")
    own = selinuxfs_mount_fd()
    try:
        return os.fstat(own).st_dev == host_selinuxfs_dev
    finally:
        os.close(own)


def _refuse_verb(done_fd, reason, detail):
    """refuse the relabeller verb by name"""
    kmsg(f"RHIZO_MARKER selinuxns=refused reason={reason} {detail}")
    _write_done(done_fd, failed(reason))
    return 1


def run_handoff_relabeller(newroot, staged, mntns_fd, done_fd, host_selinuxfs_dev, attr_reader=host_context,
                           namespace_is_host=namespace_is_host):
    """run the relabeller verb in Android's namespace"""
    ctx = attr_reader()
    if ctx not in RELABELLER_CONTEXTS:
        return _refuse_verb(done_fd, "relabeller-verb-domain", f"ctx={ctx!r}")
    try:
        host = namespace_is_host(host_selinuxfs_dev)
    except OSError as e:
        return _refuse_verb(done_fd, "relabeller-verb-namespace-unknown", f"err={e!r}")
    if host:
        return _refuse_verb(done_fd, "relabeller-verb-host-namespace", f"ctx={ctx!r}")
    return run_relabeller(newroot, staged, mntns_fd, None, done_fd)


RELABELLER_READY_COMM = b"rhizo-relabel"
RELABELLER_READY_WAIT_S = 10
RELABELLER_READY = "ready"
RELABELLER_GONE = "gone"
RELABELLER_TIMEOUT = "timeout"


def announce_relabeller_ready():
    """set this task's name to the ready name"""
    if libc.prctl(PR_SET_NAME, RELABELLER_READY_COMM, 0, 0, 0) != 0:
        kmsg(f"RHIZO_MARKER selinuxns=relabeller-announce-failed errno={ctypes.get_errno()}")


def wait_relabeller_ready(pid, proc="/proc", timeout=RELABELLER_READY_WAIT_S):
    """wait for the relabeller's ready name"""
    want = RELABELLER_READY_COMM.decode()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            reaped, status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError as e:
            kmsg(f"RHIZO_MARKER selinuxns=relabeller-gone-before-ready pid={pid} err={e!r}")
            return RELABELLER_GONE
        if reaped:
            kmsg(f"RHIZO_MARKER selinuxns=relabeller-gone-before-ready pid={pid} status={status}")
            return RELABELLER_GONE
        try:
            with open(f"{proc}/{pid}/comm") as f:
                if f.read().strip() == want:
                    return RELABELLER_READY
        except OSError as e:
            kmsg(f"RHIZO_MARKER selinuxns=relabeller-gone-before-ready pid={pid} err={e!r}")
            return RELABELLER_GONE
        time.sleep(0.002)
    kmsg(f"RHIZO_MARKER selinuxns=relabeller-ready-timeout pid={pid} after={timeout}s")
    return RELABELLER_TIMEOUT


HOST_DEVICE_LABEL = b"u:object_r:rhizo_host_device:s0"
HOST_DEVICE_CONTEXTS = (("/dev/kmsg", b"u:object_r:rhizo_host_kmsg_device:s0"),
                        ("/dev/null", b"u:object_r:null_device:s0"))


def label_host_devices(nodes=HOST_DEVICE_CONTEXTS):
    """relabel the host's kmsg and null nodes"""
    failures = []
    for path, context in nodes:
        try:
            if os.getxattr(path, "security.selinux").rstrip(b"\0") != HOST_DEVICE_LABEL:
                continue
            if not selinux_labels.label_write(path, context + b"\0"):
                failures.append(f"{path}:refused")
        except OSError as e:
            failures.append(f"{path}:errno-{e.errno}")
    if failures:
        kmsg(f"RHIZO_MARKER selinuxns=host-device-label-failed why={failures}")
    return failures


def run_relabeller(newroot, staged, mntns_fd, write_primer_script, done_fd):
    """run the relabels and the flip"""
    del _DONE_SENT[:]
    core._kmsg_fd()
    labels = connect_label_service()
    announce_relabeller_ready()
    release = socket.socketpair() if labels is not None else None
    request = setcon_request(HELPER_CONTEXTS["relabel"])

    def on_load():
        """fork the label service and enter the relabeller domain"""
        nonlocal release
        if labels is not None:
            try:
                start_label_service(labels[0], mntns_fd, labels[1], release)
            except OSError as e:
                _send_label_error(labels[0], f"fork:{e.errno}")
                release[0].close()
                release[1].close()
                release = None
        why = enter_helper_domain(request, HELPER_CONTEXTS["relabel"])
        if why:
            return f"helper-domain:{why}"
        label_host_devices()
        return None

    result = DONE_FAILED
    try:
        result = _relabel_after_load(newroot, staged, mntns_fd, write_primer_script, on_load=on_load)
    except BaseException as e:
        result = failed(f"raised:{e!r}")
    _write_done(done_fd, result)
    if release is not None:
        _release_label_service(release[0], result != DONE_FAILED)
    if labels is not None:
        labels[0].close()
    return 0 if result != DONE_FAILED else 1


def _release_label_service(writer, serve):
    """send the release byte"""
    if serve:
        try:
            writer.send(b"1")
        except OSError:
            pass
    writer.close()


def connect_label_service():
    """connect to the fence's label socket"""
    from sandbox import rootfs
    path = rootfs.label_socket_path(SANDBOX_ID)
    sock = None
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        sock.connect(path)
    except OSError as e:
        if sock is not None:
            sock.close()
        kmsg(f"no input label socket at {path} ({e.strerror})")
        return None
    try:
        with open(CAP_LAST_CAP) as f:
            last_cap = int(f.read())
    except (OSError, ValueError) as e:
        _send_label_error(sock, f"cap_last_cap:{e!r}")
        sock.close()
        return None
    kmsg(f"RHIZO_MARKER selinuxns=label-service state=connected path={path}")
    return sock, last_cap


def _send_label_error(sock, why):
    """send an error line to g over the label socket"""
    try:
        sock.send(f"error:{why}".encode()[:LABEL_REQUEST_MAX])
    except OSError:
        pass


def answer_label_request(msg, ops=os):
    """return the reply to a label request"""
    node, _, rest = msg.partition(b" ")
    if not _EVENT_NODE.fullmatch(node):
        return b"refused:path"
    m = _DEV_AND_INODE.fullmatch(rest)
    if m is None:
        return b"refused:request"
    path = node.decode()
    want = (os.makedev(int(m.group(1)), int(m.group(2))), int(m.group(3)))
    try:
        st = ops.lstat(path)
        if not stat.S_ISCHR(st.st_mode) or (st.st_rdev, st.st_ino) != want:
            return b"refused:not-the-node"
        label = ops.getxattr(path, "security.selinux", follow_symlinks=False)
        again = ops.lstat(path)
    except OSError as e:
        return f"failed:{e.errno}".encode()
    if (again.st_mode, again.st_rdev, again.st_ino) != (st.st_mode, st.st_rdev, st.st_ino):
        return b"refused:not-the-node"
    return b"label " + label.rstrip(b"\0")


def _errno_error():
    """return an OSError for ctypes' saved errno"""
    err = ctypes.get_errno()
    return OSError(err, os.strerror(err))


class NodeFd:
    """O_PATH node operations for namespace mode"""

    def open_path(self, path):
        """open path O_PATH without following a link"""
        return os.open(path, os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC)

    def fstat(self, fd):
        """return the stat of fd's inode"""
        return os.fstat(fd)

    def stat(self, path):
        """return the stat of path's link target"""
        return os.stat(path)

    def statfs_type(self, path):
        """return the filesystem magic of path"""
        buf = ctypes.create_string_buffer(256)
        if _libc.statfs(path.encode(), buf) != 0:
            raise _errno_error()
        return struct.unpack_from("l", buf)[0]

    def setxattr(self, path, name, value):
        """set an xattr of path's link target"""
        os.setxattr(path, name, value)

    def getxattr(self, path, name):
        """return an xattr of path's link target"""
        return os.getxattr(path, name)

    def fchown(self, fd, uid, gid):
        """chown fd's inode through fchownat"""
        if _libc.fchownat(ctypes.c_int(fd), b"", ctypes.c_uint(uid), ctypes.c_uint(gid),
                          ctypes.c_int(AT_EMPTY_PATH)) != 0:
            raise _errno_error()

    def fchmod(self, fd, mode):
        """chmod fd's inode through fchmodat2"""
        if _libc.syscall(ctypes.c_long(NR_FCHMODAT2), ctypes.c_int(fd), b"", ctypes.c_uint(mode),
                         ctypes.c_uint(AT_EMPTY_PATH)) != 0:
            raise _errno_error()

    def close(self, fd):
        """close fd"""
        os.close(fd)


NODE_FD = NodeFd()


class _Refused(Exception):
    """Refused set request"""


def _identity(st):
    """return the inode identity in a stat"""
    return st.st_dev, st.st_ino, st.st_rdev, stat.S_IFMT(st.st_mode)


def set_xattr_through_fd(fd_ops, fd, st, name, value):
    """set and read back an xattr through /proc/self/fd"""
    link = f"/proc/self/fd/{fd}"
    try:
        magic = fd_ops.statfs_type("/proc")
    except OSError as e:
        raise _Refused(f"no-proc:{e.errno}")
    if magic != PROC_SUPER_MAGIC:
        raise _Refused("no-proc")
    seen = fd_ops.stat(link)
    if _identity(seen) != _identity(st):
        raise _Refused("not-the-node")
    fd_ops.setxattr(link, name, value)
    got = fd_ops.getxattr(link, name)
    if _identity(fd_ops.stat(link)) != _identity(st):
        raise _Refused("not-the-node")
    return got


def answer_set_request(msg, fd_ops=NODE_FD):
    """set and read back a hidraw node's label"""
    node, _, rest = msg.partition(b" ")
    if not _HIDRAW_NODE.fullmatch(node):
        return b"refused:path"
    m = _DEV_AND_INODE.fullmatch(rest)
    if m is None:
        return b"refused:request"
    want = (os.makedev(int(m.group(1)), int(m.group(2))), int(m.group(3)))
    try:
        fd = fd_ops.open_path(node.decode())
    except OSError as e:
        return f"failed:{e.errno}".encode()
    try:
        st = fd_ops.fstat(fd)
        if not stat.S_ISCHR(st.st_mode) or (st.st_rdev, st.st_ino) != want:
            return b"refused:not-the-node"
        label = set_xattr_through_fd(fd_ops, fd, st, "security.selinux", HIDRAW_LABEL + b"\0")
    except _Refused as r:
        return f"refused:{r}".encode()
    except OSError as e:
        return f"failed:{e.errno}".encode()
    finally:
        fd_ops.close(fd)
    return b"label " + label.rstrip(b"\0")


def answer_service_request(msg, ops=os, fd_ops=NODE_FD):
    """return the reply to a set or read request"""
    verb, _, rest = msg.partition(b" ")
    if verb == b"set":
        return answer_set_request(rest, fd_ops)
    return answer_label_request(msg, ops)


def _drop_privileges(last_cap):
    """drop every capability and set no_new_privs"""
    for cap in range(last_cap + 1):
        if libc.prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0:
            return f"capbset-drop:{cap}:{ctypes.get_errno()}"
    if libc.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0:
        return f"ambient-clear:{ctypes.get_errno()}"
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        return f"no-new-privs:{ctypes.get_errno()}"
    header = ctypes.create_string_buffer(struct.pack("<Ii", LINUX_CAPABILITY_VERSION_3, 0), 8)
    sets = ctypes.create_string_buffer(24)
    if libc.capset(header, sets) != 0:
        return f"capset:{ctypes.get_errno()}"
    return ""


def keep_only_caps(keep, last_cap):
    """drop every capability outside keep"""
    for cap in range(last_cap + 1):
        if cap not in keep and libc.prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0:
            return f"capbset-drop:{cap}:{ctypes.get_errno()}"
    if libc.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0:
        return f"ambient-clear:{ctypes.get_errno()}"
    header = ctypes.create_string_buffer(struct.pack("<Ii", LINUX_CAPABILITY_VERSION_3, 0), 8)
    sets = ctypes.create_string_buffer(24)
    if libc.capget(header, sets) != 0:
        return f"capget:{ctypes.get_errno()}"
    mask = sum(1 << cap for cap in keep)
    words = struct.unpack("<6I", sets.raw)
    kept = [0 if i % 3 == 2 else w & (mask >> (32 * (i // 3))) & 0xFFFFFFFF for i, w in enumerate(words)]
    if libc.capset(header, ctypes.create_string_buffer(struct.pack("<6I", *kept), 24)) != 0:
        return f"capset:{ctypes.get_errno()}"
    return ""


def drop_to_init_caps():
    """drop the capabilities init lacks"""
    for cap in DROP_CAPS:
        if libc.prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0:
            return f"capbset-drop:{cap}:{ctypes.get_errno()}"
    if libc.prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0:
        return f"ambient-clear:{ctypes.get_errno()}"
    header = ctypes.create_string_buffer(struct.pack("<Ii", LINUX_CAPABILITY_VERSION_3, 0), 8)
    sets = ctypes.create_string_buffer(24)
    if libc.capget(header, sets) != 0:
        return f"capget:{ctypes.get_errno()}"
    mask = sum(1 << cap for cap in DROP_CAPS)
    words = struct.unpack("<6I", sets.raw)
    kept = [w & ~(mask >> (32 * (i // 3))) & 0xFFFFFFFF for i, w in enumerate(words)]
    if libc.capset(header, ctypes.create_string_buffer(struct.pack("<6I", *kept), 24)) != 0:
        return f"capset:{ctypes.get_errno()}"
    return ""


def _lsm_ctx(context):
    """return context as a SELinux lsm_ctx struct"""
    ctx = context + b"\0"
    return struct.pack("<QQQQ", LSM_ID_SELINUX, 0, 32 + len(ctx), len(ctx)) + ctx


def own_context():
    """return this task's SELinux context"""
    buf = ctypes.create_string_buffer(LABEL_REQUEST_MAX)
    size = ctypes.c_uint32(LABEL_REQUEST_MAX)
    n = _libc.syscall(ctypes.c_long(NR_LSM_GET_SELF_ATTR), ctypes.c_long(LSM_ATTR_CURRENT), buf,
                      ctypes.byref(size), ctypes.c_long(0))
    if n < 0:
        raise _errno_error()
    raw, off = buf.raw[:size.value], 0
    for _ in range(n):
        lsm_id, _flags, length, ctx_len = struct.unpack_from("<QQQQ", raw, off)
        if lsm_id == LSM_ID_SELINUX:
            return raw[off + 32:off + 32 + ctx_len].rstrip(b"\0")
        off += length
    return b""


def setcon_request(context):
    """return context as an lsm_set_self_attr buffer"""
    data = _lsm_ctx(context)
    return ctypes.create_string_buffer(data, len(data))


def enter_helper_domain(request, context):
    """set this task's context from request and read it back"""
    if _libc.syscall(ctypes.c_long(NR_LSM_SET_SELF_ATTR), ctypes.c_long(LSM_ATTR_CURRENT), request,
                     ctypes.c_long(ctypes.sizeof(request)), ctypes.c_long(0)) != 0:
        return f"setcon:{ctypes.get_errno()}"
    try:
        got = own_context()
    except OSError as e:
        return f"setcon-readback:errno-{e.errno}"
    if got != context:
        return "setcon-readback:" + got.decode(errors="replace")
    return ""


def enter_label_domain():
    """set and read back the label service's context"""
    return enter_helper_domain(setcon_request(LABEL_SERVICE_CONTEXT), LABEL_SERVICE_CONTEXT)


def _serve_labels(sock, mntns_fd, last_cap, release):
    """serve label requests"""
    if libc.setns(mntns_fd, CLONE_NEWNS) != 0:
        _send_label_error(sock, f"setns:{ctypes.get_errno()}")
        return 1
    low = 0
    for keep in sorted({sock.fileno(), release.fileno()}):
        os.closerange(low, keep)
        low = keep + 1
    os.closerange(low, os.sysconf("SC_OPEN_MAX"))
    failed = _drop_privileges(last_cap) or enter_label_domain()
    if failed:
        _send_label_error(sock, failed)
        return 1
    if not release.recv(1):
        return 1
    sock.send(b"ready")
    while True:
        msg = sock.recv(LABEL_REQUEST_MAX)
        if not msg:
            return 0
        sock.send(answer_service_request(msg))


def start_label_service(sock, mntns_fd, last_cap, release):
    """fork the label service and close this copy of sock"""
    pid = os.fork()
    if pid == 0:
        code = 1
        try:
            release[0].close()
            code = _serve_labels(sock, mntns_fd, last_cap, release[1])
        except BaseException as e:
            _send_label_error(sock, f"raised:{e!r}")
        os._exit(code)
    sock.close()
    release[1].close()
    return pid


def start_relabeller(newroot, staged, write_primer_script, done_fd=-1):
    """fork the in-namespace relabeller"""
    if write_primer_script is None:
        kmsg("RHIZO_MARKER selinuxns=refused reason=no-primer-writer")
        os._exit(1)
    mntns_fd = os.open("/proc/self/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        del _DONE_SENT[:]
        why = ""
        try:
            _close_inherited_fds({core._kmsg_fd(), mntns_fd, w, done_fd})
            core.stdio_to_null()
            why = drop_to_init_caps()
            if why:
                why = f"caps-failed:{why}"
            elif libc.unshare(CLONE_NEWNS) != 0:
                why = f"unshare-failed:errno={ctypes.get_errno()}"
            else:
                os.write(w, b"1")
                os.close(w)
                os._exit(run_relabeller(newroot, staged, mntns_fd, write_primer_script, done_fd))
        except BaseException as e:
            why = f"raised:{e!r}"
        if not _DONE_SENT:
            _write_done(done_fd, failed(why))
        os._exit(1)
    os.close(w)
    ready = os.read(r, 1) == b"1"
    os.close(r)
    os.close(mntns_fd)
    kmsg(f"RHIZO_MARKER selinuxns=relabeller-started pid={pid} ready={ready}")
    return pid


VIEW_KEEPER_COMM = b"rhizo-mntview"


def start_view_keeper():
    """fork a process holding a copy of the pre-pivot mounts"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            _close_inherited_fds({core._kmsg_fd(), w})
            core.stdio_to_null()
            ok = libc.unshare(CLONE_NEWNS) == 0 and libc.prctl(PR_SET_NAME, VIEW_KEEPER_COMM, 0, 0, 0) == 0
            os.write(w, b"1" if ok else b"f")
            os.close(w)
            while ok:
                signal.pause()
        except BaseException as e:
            kmsg(f"RHIZO_MARKER selinuxns=view-keeper-raised err={e!r}")
        os._exit(1)
    os.close(w)
    ready = os.read(r, 1) == b"1"
    os.close(r)
    kmsg(f"RHIZO_MARKER selinuxns=view-keeper pid={pid} ready={ready}")
    if not ready:
        kmsg("RHIZO_MARKER selinuxns=refused reason=view-keeper")
        os._exit(1)
    return pid


def find_view_keeper(holder, proc="/proc"):
    """return the pid of the holder's view keeper child"""
    want = VIEW_KEEPER_COMM.decode()
    for d in os.listdir(proc):
        if not d.isdigit():
            continue
        try:
            with open(f"{proc}/{d}/stat") as f:
                line = f.read()
        except (FileNotFoundError, ProcessLookupError):
            continue
        comm = line[line.index("(") + 1:line.rindex(")")]
        ppid = int(line[line.rindex(")") + 2:].split()[1])
        if ppid == holder and comm == want:
            return int(d)
    return None


def kill_view_keeper(pidfd):
    """SIGKILL the view keeper through its pidfd"""
    try:
        signal.pidfd_send_signal(pidfd, signal.SIGKILL)
    except ProcessLookupError:
        pass


def holder_environ(holder):
    """return the staging launcher's environment"""
    with open(f"/proc/{holder}/environ", "rb") as f:
        raw = f.read()
    return dict(kv.split(b"=", 1) for kv in raw.split(b"\0") if b"=" in kv)


DECOY_SCRATCH = "/dev/.rhizo_decoy"


def bind_decoy_enforce(node, scratch):
    """bind a writable decoy file over node"""
    os.makedirs(scratch, exist_ok=True)
    if not mount("tmpfs", scratch, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=0700,size=16k"):
        return False
    try:
        decoy = f"{scratch}/enforce"
        with open(decoy, "w") as f:
            f.write("0")
        os.chmod(decoy, 0o644)
        try:
            os.setxattr(decoy, "security.selinux", b"u:object_r:rhizo_enforce_shadow:s0\0")
        except OSError as e:
            kmsg(f"decoy enforce node setxattr: {e}")
        return mount(decoy, node, None, MS_BIND)
    finally:
        if libc.umount2(scratch.encode(), 2) != 0:
            kmsg(f"RHIZO_MARKER selinuxns=decoy-scratch-umount-failed errno={ctypes.get_errno()}")
        else:
            try:
                os.rmdir(scratch)
            except OSError as e:
                kmsg(f"RHIZO_MARKER selinuxns=decoy-scratch-rmdir-failed err={e!r}")


def start_handoff_relabeller(view_fd, done_w, env, launcher_path, python, host_selinuxfs_dev):
    """fork a relabeller into the keeper's pre-pivot mounts"""
    sandbox = os.open("/proc/self/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        done = DONE_FAILED
        try:
            _close_inherited_fds({core._kmsg_fd(), view_fd, sandbox, w, done_w})
            core.stdio_to_null()
            caps_why = drop_to_init_caps()
            if caps_why:
                kmsg(f"RHIZO_MARKER selinuxns=relabeller-caps-failed reason={caps_why}")
                done = failed(f"caps-failed:{caps_why}")
            ok = not caps_why and libc.setns(view_fd, CLONE_NEWNS) == 0 and libc.unshare(CLONE_NEWNS) == 0
            os.write(w, b"1" if ok else b"f")
            os.close(w)
            if ok:
                os.set_inheritable(sandbox, True)
                os.set_inheritable(done_w, True)
                try:
                    os.execve(python, [python, launcher_path, "selinuxns-relabeller", str(sandbox), str(done_w),
                                       str(host_selinuxfs_dev)], env)
                except OSError as e:
                    kmsg(f"RHIZO_MARKER selinuxns=relabeller-exec-failed err={e!r}")
            elif not caps_why:
                kmsg(f"RHIZO_MARKER selinuxns=relabeller-view-failed errno={ctypes.get_errno()}")
        except BaseException as e:
            kmsg(f"RHIZO_MARKER selinuxns=relabeller-raised err={e!r}")
        _write_done(done_w, done)
        os._exit(1)
    os.close(w)
    os.close(sandbox)
    ready = os.read(r, 1) == b"1"
    os.close(r)
    kmsg(f"RHIZO_MARKER selinuxns=relabeller-started pid={pid} ready={ready} path=handoff")
    return pid if ready else None


def begin_handoff_namespace(view_fd, done_w, env, launcher_path, python, host_selinuxfs_dev):
    """unshare a fresh SELinux namespace and start the relabeller"""
    if not state()["unshared"]:
        unshare_namespace(state_file=None)
    kmsg("RHIZO_MARKER selinuxns=unshared path=handoff")
    mount_own_selinuxfs("/sys/fs/selinux")
    if not bind_decoy_enforce("/sys/fs/selinux/enforce", DECOY_SCRATCH):
        kmsg("RHIZO_MARKER selinuxns=refused reason=decoy-bind-failed")
        os._exit(1)
    relabeller = start_handoff_relabeller(view_fd, done_w, env, launcher_path, python, host_selinuxfs_dev)
    if relabeller is None:
        kmsg("RHIZO_MARKER selinuxns=refused reason=relabeller-not-ready")
        os._exit(1)
    if wait_relabeller_ready(relabeller) == RELABELLER_TIMEOUT:
        kmsg("RHIZO_MARKER selinuxns=refused reason=relabeller-ready-timeout")
        os._exit(1)


def handoff_refusal(verdict):
    """return the holder's end refusal of a verdict"""
    if verdict == "stopped" or verdict.startswith("refused:"):
        return None
    return "holder-ended"


JOINER_END_WAIT_S = 30


def await_joiner_end(dir_fd):
    """wait for the joiner's end verdict"""
    deadline = time.time() + JOINER_END_WAIT_S
    verdict = read_verdict(dir_fd)
    while verdict in ("enforced", "permissive") and time.time() < deadline:
        time.sleep(0.1)
        verdict = read_verdict(dir_fd)
    return verdict


def handoff_outcome(verdict):
    """map a handoff joiner's verdict to g's relabel state"""
    if verdict in ("enforced", "permissive"):
        return verdict
    if verdict == "stopped":
        return "none"
    reason = verdict[len("refused:"):] if verdict.startswith("refused:") else handoff_refusal(verdict)
    kmsg(f"RHIZO_MARKER selinuxns=refused reason={reason}")
    return "failed"


INIT_EXIT_WAIT_S = 10


def wait_pidfd_exit(pidfd, timeout=INIT_EXIT_WAIT_S):
    """wait up to timeout seconds for pidfd's process to exit"""
    ready, _, _ = select.select([pidfd], [], [], timeout)
    return bool(ready)


def check_relabeller_done(done_fd, deadline, kill, now=time.time, init_exiting=lambda: False, reasons=None):
    """read the done byte without blocking"""
    ready, _, _ = select.select([done_fd], [], [], 0)
    if ready:
        got = os.read(done_fd, 1)
        if got == DONE_ENFORCED:
            return "enforced"
        if got == DONE_PERMISSIVE:
            return "permissive"
        if got == b"" and init_exiting():
            return "pending"
        reason = "eof" if got == b"" else "failed"
        if got == DONE_FAILED:
            read_failure_reason(done_fd, reasons)
    elif now() >= deadline:
        reason = "timeout"
    else:
        return "pending"
    try:
        kill()
    except OSError as e:
        kmsg(f"selinuxns: killing the sandbox after a relabeller refusal raised {e!r}")
    kmsg(f"RHIZO_MARKER selinuxns=refused reason=relabeller-{reason}")
    return reason


def open_records_dir(path=SELINUXNS_RECORDS_DIR):
    """create and open an instance's namespace records directory"""
    os.makedirs(path, mode=0o755, exist_ok=True)
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)


def keep_refusal(current):
    """return whether current is a refusal"""
    return current.startswith("refused:")


def report_record_write_failure(name, value, err):
    """log a failed record write naming its file"""
    kmsg(f"RHIZO_MARKER selinuxns=record-write-failed file={name} value={value} err={err!r}")


def record_verdict(value, dir_fd, keep=keep_refusal):
    """write the verdict under the records lock"""
    try:
        fcntl.flock(dir_fd, fcntl.LOCK_EX)
        try:
            current = read_verdict(dir_fd)
            if current != value and keep(current):
                if keep_refusal(current):
                    kmsg(f"RHIZO_MARKER selinuxns=verdict-kept value={current} dropped={value}")
                return False
            write_android_enforce(value, VERDICT_FILE, dir_fd=dir_fd)
            return True
        finally:
            fcntl.flock(dir_fd, fcntl.LOCK_UN)
    except OSError as e:
        report_record_write_failure(os.path.basename(VERDICT_FILE), value, e)
        return False


def record_start_id(value, dir_fd):
    """record the unit invocation owning the start records"""
    try:
        write_android_enforce(value, START_ID_FILE, dir_fd=dir_fd)
    except OSError as e:
        report_record_write_failure(os.path.basename(START_ID_FILE), value, e)


def record_android_enforce(value, dir_fd):
    """write Android's enforce state through the records fd"""
    try:
        write_android_enforce(value, ANDROID_ENFORCE_FILE, dir_fd=dir_fd)
    except OSError as e:
        report_record_write_failure(os.path.basename(ANDROID_ENFORCE_FILE), value, e)
        return
    kmsg(f"RHIZO_MARKER selinuxns=android-enforce value={value}")


def record_start_end(verdict, dir_fd):
    """record a start's end verdict and enforce state 0"""
    record_verdict("stopped" if verdict in ("enforced", "permissive") else verdict, dir_fd)
    record_android_enforce("0", dir_fd)


def record_stop_request(records_dir=SELINUXNS_RECORDS_DIR):
    """write the stop request file"""
    try:
        dir_fd = open_records_dir(records_dir)
    except OSError as e:
        kmsg(f"RHIZO_MARKER selinuxns=stop-request-failed dir={records_dir} err={e!r}")
        return
    try:
        write_android_enforce("1", STOP_REQUEST_FILE, dir_fd=dir_fd)
    except OSError as e:
        kmsg(f"RHIZO_MARKER selinuxns=stop-request-failed dir={records_dir} err={e!r}")
    finally:
        os.close(dir_fd)


def stop_requested(dir_fd):
    """return whether a stop request is recorded"""
    if dir_fd < 0:
        return False
    try:
        fd = os.open(os.path.basename(STOP_REQUEST_FILE), os.O_RDONLY | os.O_CLOEXEC, dir_fd=dir_fd)
    except FileNotFoundError:
        return False
    try:
        return os.read(fd, 8).strip() == b"1"
    finally:
        os.close(fd)


def clear_stop_request(dir_fd):
    """remove the recorded stop request"""
    try:
        os.unlink(os.path.basename(STOP_REQUEST_FILE), dir_fd=dir_fd)
    except FileNotFoundError:
        pass


def init_exit_refusal(status, stop_requested):
    """return the refusal reason of init's wait status, or None"""
    if os.WIFSIGNALED(status) and not stop_requested:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=init-killed-before-flip signal={os.WTERMSIG(status)}")
        return f"init-killed-before-flip-signal-{os.WTERMSIG(status)}"
    if not os.WIFEXITED(status) or (os.WEXITSTATUS(status) == 0 and stop_requested):
        return None
    kmsg(f"RHIZO_MARKER selinuxns=refused reason=init-exited-before-flip status={os.WEXITSTATUS(status)}")
    return f"init-exited-before-flip-status-{os.WEXITSTATUS(status)}"


def read_verdict(dir_fd):
    """return this start's recorded namespace verdict"""
    try:
        fd = os.open(os.path.basename(VERDICT_FILE), os.O_RDONLY | os.O_CLOEXEC, dir_fd=dir_fd)
    except FileNotFoundError:
        return ""
    try:
        return os.read(fd, 256).decode(errors="replace").strip()
    finally:
        os.close(fd)


def relabeller_refusal(reason):
    """return reason with a relabeller- prefix"""
    return reason if reason.startswith("relabeller-") else f"relabeller-{reason}"


def verdict_for(relabel, why=""):
    """return the verdict for a relabel state and the refusal it named"""
    if relabel in ("enforced", "permissive"):
        return relabel
    if relabel in ("eof", "timeout"):
        return f"refused:relabeller-{relabel}"
    if relabel == "failed":
        return f"refused:{why or 'relabeller-failed'}"
    return "stopped"


def read_done_now(done_fd, reasons=None):
    """read the relabeller's done byte if one is waiting"""
    ready, _, _ = select.select([done_fd], [], [], 0)
    if not ready:
        return "pending"
    got = os.read(done_fd, 1)
    if got == DONE_FAILED:
        read_failure_reason(done_fd, reasons)
        return "failed"
    return {DONE_ENFORCED: "enforced", DONE_PERMISSIVE: "permissive"}.get(got, "pending")


def holder_ended_first(init_fd, holder_fd, timeout=None):
    """return whether init's holder exits first"""
    ready, _, _ = select.select([init_fd] + ([holder_fd] if holder_fd >= 0 else []), [], [], timeout)
    return holder_fd >= 0 and holder_fd in ready and init_fd not in ready


def end_init_with_holder(kill, on_verdict, stop_requested):
    """kill init and return its refusal"""
    refusal = None if stop_requested() else "refused:holder-ended"
    if refusal:
        on_verdict(refusal)
    kill()
    return refusal


def watch_handed_off_init(init_pid, done_r, deadline, on_verdict, now=time.time, stop_requested=lambda: False,
                          holder_fd=-1):
    """watch a handed-off init and its holder"""
    pidfd = os.pidfd_open(init_pid)
    state, reasons, holder_ended = "pending", [], False
    try:
        kill = lambda: signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        exiting = lambda: wait_pidfd_exit(pidfd)
        while state == "pending":
            watched = [pidfd, done_r] + ([holder_fd] if holder_fd >= 0 else [])
            ready, _, _ = select.select(watched, [], [], max(0.0, deadline - now()))
            if holder_fd >= 0 and holder_fd in ready and pidfd not in ready:
                holder_ended = True
                break
            if pidfd in ready and done_r not in ready:
                state = read_done_now(done_r, reasons)
                break
            state = check_relabeller_done(done_r, deadline, kill, now, exiting, reasons)
            if state == "pending" and wait_pidfd_exit(pidfd, 0):
                break
        verdict = None if state == "pending" else verdict_for(state, relabeller_refusal(reasons[0]) if reasons else "")
        if verdict:
            on_verdict(verdict)
        if holder_ended or holder_ended_first(pidfd, holder_fd):
            verdict = end_init_with_holder(kill, on_verdict, stop_requested) or verdict
        _, status = os.waitpid(init_pid, 0)
    finally:
        os.close(pidfd)
    if verdict:
        return verdict, status
    why = init_exit_refusal(status, stop_requested())
    verdict = f"refused:{why}" if why else "stopped"
    on_verdict(verdict)
    return verdict, status


def wait_first_flip(fd, g, waitpid=os.waitpid, reasons=None):
    """wait for g's verified flip or exit"""
    got = os.read(fd, 1)
    os.close(fd)
    if got == b"1":
        return "flipped"
    _, status = waitpid(g, 0)
    if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
        return "ended"
    if reasons is not None:
        reasons.append(f"g-exit-{os.WEXITSTATUS(status)}" if os.WIFEXITED(status)
                       else f"g-signal-{os.WTERMSIG(status)}")
    return "refused"


def join_landlock_domain():
    """join a Landlock domain scoping signals"""
    abi, err = landlock_version()
    if abi < LANDLOCK_MIN_ABI:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=landlock-abi errno={err} abi={abi}")
        os._exit(1)
    attr = ctypes.create_string_buffer(struct.pack("<QQQ", 0, 0, LANDLOCK_SCOPE_SIGNAL), 24)
    fd = _libc.syscall(ctypes.c_long(NR_LANDLOCK_CREATE_RULESET), attr, ctypes.c_size_t(24), ctypes.c_uint32(0))
    if fd < 0:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=landlock-create errno={ctypes.get_errno()}")
        os._exit(1)
    rc = _libc.syscall(ctypes.c_long(NR_LANDLOCK_RESTRICT_SELF), ctypes.c_long(fd), ctypes.c_uint32(0))
    err = ctypes.get_errno()
    os.close(fd)
    if rc != 0:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=landlock-restrict errno={err}")
        os._exit(1)
    kmsg(f"RHIZO_MARKER selinuxns=landlock-domain abi={abi}")
