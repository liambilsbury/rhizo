"""launcher constants, syscall wrappers and the kmsg channel"""
import collections, ctypes, errno, fcntl, hashlib, json, os, platform, signal, stat, struct, subprocess, sys

HOST_ARCH = platform.machine()
HOST_ARCH_AMD64 = "x86_64"

MAX_SANDBOX_ID = 99
SANDBOX_ID = int(os.environ.get("RHIZO_SANDBOX_ID", "0"))
if not 0 <= SANDBOX_ID <= MAX_SANDBOX_ID:
    raise SystemExit(f"RHIZO_SANDBOX_ID={SANDBOX_ID} refused: NET_SUBNET below "
                      "needs a single id 0-99, two free octet digits and no sign")


def _instanced_for(base, sandbox_id, sep="-"):
    """return base suffixed with an explicit sandbox id"""
    return base if sandbox_id == 0 else f"{base}{sep}{sandbox_id}"


def _instanced(base, sep="-"):
    """return base suffixed with this launcher's sandbox id"""
    return _instanced_for(base, SANDBOX_ID, sep)


AID_READPROC = 3009

INPUT_PORTS = range(0, 9)
FENCED_DISPLAY_PORT = 255


def input_phys_prefix(sandbox_id):
    """return the evdev phys prefix of a sandbox's uinput devices"""
    return _instanced_for("rhizo", sandbox_id) + "-port-"


def input_port_associations_xml(sandbox_id, fence_others):
    """return the input-port-associations.xml text for a sandbox"""
    rows = [(input_phys_prefix(sandbox_id) + str(n), n) for n in INPUT_PORTS]
    if fence_others:
        rows += [(input_phys_prefix(other) + str(n), FENCED_DISPLAY_PORT)
                 for other in range(MAX_SANDBOX_ID + 1) if other != sandbox_id
                 for n in INPUT_PORTS]
    return ('<?xml version="1.0" encoding="utf-8"?>\n<ports>\n'
            + "".join(f'    <port display="{d}" input="{p}" />\n' for p, d in rows)
            + "</ports>\n")


RUN_ROOT = _instanced("/run/rhizo")
WAYLAND_RUN_DIR = _instanced("/run/rhizo-wayland")
SELINUXNS_RECORDS_DIR = _instanced("/run/rhizo-selinuxns")
SYSTEM_ADB_KEYS = f"{RUN_ROOT}/adb_keys"
CGROUP_ROOT = _instanced("/sys/fs/cgroup/rhizo")
INIT_PID_FILE = _instanced("/root/.rhizo_init_pid")
G_PID_FILE = "/root/.rhizo_g_pid"
SUPERVISOR_CGROUP = "/sys/fs/cgroup/rhizo-host"
CGROUP_ROOT_FILE = _instanced("/root/.rhizo_cgroup_root")
CGROUP_INVOCATION_FILE = _instanced("/root/.rhizo_cgroup_invocation")
VETH_HOST_IF = f"vethrhz{SANDBOX_ID}"
NET_OCTET3 = 100 + SANDBOX_ID
NET_SUBNET = f"192.168.{NET_OCTET3}.0/24"
NET_HOST_ADDR = f"192.168.{NET_OCTET3}.1/24"
NET_POOL_START = f"192.168.{NET_OCTET3}.50"
NET_POOL_END = f"192.168.{NET_OCTET3}.100"

NET_GUEST_MAC = "02:52:48:5a:00:%02x" % (SANDBOX_ID + 1)

NETBRIDGED_UNIT = _instanced("rhizo-netbridged")
NETBRIDGED_RUNTIME_DIR = _instanced("rhizo-netbridged")
NETBRIDGED_LOG = f"/tmp/{NETBRIDGED_UNIT}.log"

InstancePaths = collections.namedtuple("InstancePaths", (
    "run_root", "records_dir", "cgroup_root", "init_pid_file", "cgroup_root_file",
    "veth_host_if", "net_subnet", "net_host_addr"))


def paths_for(sandbox_id):
    """return the per-instance paths for an arbitrary sandbox id"""
    return InstancePaths(
        run_root=_instanced_for("/run/rhizo", sandbox_id),
        records_dir=_instanced_for("/run/rhizo-selinuxns", sandbox_id),
        cgroup_root=_instanced_for("/sys/fs/cgroup/rhizo", sandbox_id),
        init_pid_file=_instanced_for("/root/.rhizo_init_pid", sandbox_id),
        cgroup_root_file=_instanced_for("/root/.rhizo_cgroup_root", sandbox_id),
        veth_host_if=f"vethrhz{sandbox_id}",
        net_subnet=f"192.168.{100 + sandbox_id}.0/24",
        net_host_addr=f"192.168.{100 + sandbox_id}.1/24",
    )



CLONE_NEWNS=0x00020000; CLONE_NEWCGROUP=0x02000000; CLONE_NEWUTS=0x04000000
CLONE_NEWIPC=0x08000000; CLONE_NEWPID=0x20000000; CLONE_NEWNET=0x40000000
MS_REC=16384; MS_PRIVATE=1<<18; MS_BIND=4096; MS_RDONLY=1; MS_REMOUNT=32; MS_SHARED=1<<20
MS_SLAVE=1<<19
MS_NOSUID=2; MS_NODEV=4; MS_NOEXEC=8

PR_CAPBSET_DROP=24
PR_SET_MEMORY_MERGE=67
PR_GET_DUMPABLE=3
PR_SET_DUMPABLE=4
PR_SET_NAME=15
GSI=os.environ.get("RHIZO_GSI","/srv/rhizo/gsi_system"); NEWROOT="/rhizoroot"

def _gsi_is_debuggable():
    """return whether the GSI's build.prop sets ro.debuggable=1"""
    try:
        with open(f"{GSI}/build.prop") as f:
            for line in f:
                if line.strip() == "ro.debuggable=1":
                    return True
    except OSError as e:
        print(f"L3: WARNING: cannot read {GSI}/build.prop ({e}) -- assuming "
              "the GSI is not natively debuggable", file=sys.stderr, flush=True)
    return False
GSI_DEBUGGABLE = _gsi_is_debuggable()

def _gsi_fingerprint():
    """return the GSI build.prop's build fingerprint"""
    try:
        with open(f"{GSI}/build.prop") as f:
            props = dict(
                l.strip().split("=", 1) for l in f
                if "=" in l and not l.lstrip().startswith("#")
            )
    except OSError as e:
        print(f"L3: WARNING: cannot read {GSI}/build.prop for gsi_fingerprint ({e})", file=sys.stderr, flush=True)
        return ""
    return props.get("ro.system.build.fingerprint") or props.get("ro.build.fingerprint") or ""
GSI_FINGERPRINT = _gsi_fingerprint()

RHIZO_ADB_ROOT = bool(os.environ.get("RHIZO_ADB_ROOT")) and not GSI_DEBUGGABLE
if os.environ.get("RHIZO_ADB_ROOT") and GSI_DEBUGGABLE:
    print(f"L3: RHIZO_ADB_ROOT ignored -- {GSI} sets ro.debuggable=1 itself",
          file=sys.stderr, flush=True)
RHIZO_PERMISSIVE = os.environ.get("RHIZO_PERMISSIVE") == "1"
RHIZO_ENFORCING = not RHIZO_PERMISSIVE
RHIZO_SELINUX_MODE = os.environ.get("RHIZO_SELINUX_MODE", "namespace")


def host_selinux_mode():
    """return True when the policy loads host-wide"""
    return os.environ.get("RHIZO_SELINUX_MODE", "namespace") == "host"


RHIZO_SEPOLICY_NODONTAUDIT = os.environ.get("RHIZO_SEPOLICY_NODONTAUDIT") == "1"
RHIZO_DEBUG_PERMISSIVE_DOMAIN = os.environ.get("RHIZO_DEBUG_PERMISSIVE_DOMAIN", "")
RHIZO_DEBUG_PROC_READ = os.environ.get("RHIZO_DEBUG_PROC_READ") == "1"
def _default_data_img():
    """return the data.img path"""
    return ("/var/lib/rhizo/data.img" if SANDBOX_ID == 0
            else f"/var/lib/rhizo/instances/{SANDBOX_ID}/data.img")
RHIZO_DATA_IMG = os.environ.get("RHIZO_DATA_IMG", _default_data_img())
RHIZO_PERSIST_DATA = os.environ.get("RHIZO_WIPE_DATA") != "1"
RHIZO_FLAT_DIR_BINDS = os.environ.get("RHIZO_FLAT_DIR_BINDS", "1") == "1"
RHIZO_APEX_DIR_BIND = os.environ.get("RHIZO_APEX_DIR_BIND", "1") == "1"
RHIZO_SYSKERNEL_SUBSET = os.environ.get("RHIZO_SYSKERNEL_SUBSET", "1") == "1"
_NETBPFLOAD_PRELOAD_DIRS = (("/system_ext/bin/hw", "system_ext_upper/bin/hw") if RHIZO_FLAT_DIR_BINDS
              else ("/system/bin", "system_upper/bin"))
NETBPFLOAD_PRELOAD_PATH = _NETBPFLOAD_PRELOAD_DIRS[0] + "/rhizo_netbpfload_preload"
NETBPFLOAD_PRELOAD_STAGE = RUN_ROOT + "/" + _NETBPFLOAD_PRELOAD_DIRS[1] + "/rhizo_netbpfload_preload"

RHIZO_SF_ACQUIRED_BUFFERS = os.environ.get("RHIZO_SF_ACQUIRED_BUFFERS", "3")

def _default_vendor_dir():
    """return the vendor tree path"""
    return ("/var/lib/rhizo/vendor" if SANDBOX_ID == 0
            else f"/var/lib/rhizo/instances/{SANDBOX_ID}/vendor")
RHIZO_VENDOR_DIR = os.environ.get("RHIZO_VENDOR_DIR", _default_vendor_dir())
def _default_apex_dir():
    """return the apex override path"""
    return ("/var/lib/rhizo/apex_override" if SANDBOX_ID == 0
            else f"/var/lib/rhizo/instances/{SANDBOX_ID}/apex_override")
RHIZO_APEX_DIR = os.environ.get("RHIZO_APEX_DIR", _default_apex_dir())
RHIZO_DEVICE_STATE_DIR = os.environ.get("RHIZO_DEVICE_STATE_DIR", _instanced("/var/lib/rhizo/device-state"))
RHIZO_STATE_DIR = os.environ.get("RHIZO_STATE_DIR", "/var/lib/rhizo")
DEVICE_STATE_MOUNT = "/rhizo-device-state"
DEVICE_STATE_LINK = "/vendor/etc/rhizo-device-state"
DEVICE_STATE_LABEL = "u:object_r:rhizo_device_state_file:s0"
RHIZO_DATA_TEMPLATE = os.environ.get("RHIZO_DATA_TEMPLATE", "")
RHIZO_RELEASE = os.environ.get("RHIZO_RELEASE", "a16")
PREPARED_ROOT = "/var/lib/rhizo/prepared"
PREPARED_LAYOUT_VERSION = "10"
PREPARED_BINDS = ("vendor/bin", "vendor/lib", "vendor/lib64")
RHIZO_UNDER_UNIT = "NOTIFY_SOCKET" in os.environ
RHIZO_RESIDENT_G = os.environ.get("RHIZO_RESIDENT_G") == "1"
RHIZO_RESIDENT_DISPATCH = os.environ.get("RHIZO_RESIDENT_DISPATCH") == "1"
RHIZO_LOG_DIR = os.environ.get("RHIZO_LOG_DIR", "/var/log/rhizo")
RHIZO_DERIVED_DIR = os.environ.get("RHIZO_DERIVED_DIR", "/var/lib/rhizo/derived")
RHIZO_CACHE_DIR = os.environ.get("RHIZO_CACHE_DIR", "/var/cache/rhizo")
PRIMER_LOG = f"{RHIZO_LOG_DIR}/rhizo-primer.log"
AVC_LOG = f"{RHIZO_LOG_DIR}/rhizo-avc.log"

SUPERVISOR_STATE = "/root/.rhizo_supervisor_state"
SUPERVISOR_LOG = f"{RHIZO_LOG_DIR}/supervisor.log"
HANDOFF_DIR = "/root/.rhizo_handoff.d"
HOST_LOCK_FILE = "/run/rhizo-host.lock"
DROP_CAPS=[16,17,25,20,31,22,32]
libc=ctypes.CDLL("libc.so.6", use_errno=True)

_KMSG_FD = None
def _kmsg_fd():
    """open /dev/kmsg for writing once and return its fd"""
    global _KMSG_FD
    if _KMSG_FD is None:
        try:
            _KMSG_FD = os.open("/dev/kmsg", os.O_WRONLY | os.O_CLOEXEC)
        except OSError:
            _KMSG_FD = -1
    return _KMSG_FD

def gsi_bootstrap_cmd(binary, args=""):
    """return the bootstrap-linker command for a GSI binary"""
    return ("LD_LIBRARY_PATH=%s/lib64/bootstrap:%s/lib64 "
            "%s/bin/bootstrap/linker64 %s/%s %s" % (GSI, GSI, GSI, GSI, binary, args))


def kmsg(m):
    """write a message to /dev/kmsg and print it"""
    fd = _kmsg_fd()
    if fd >= 0:
        try: os.write(fd, f"<5>L3: {m}\n".encode())
        except OSError: pass
    try: print(f"[l3] {m}", flush=True)
    except OSError: pass
LOG_PIPE_CHUNK_BYTES = 65536
KMSG_PATH = "/dev/kmsg"


def _report_log_pump(kmsg_fd, message):
    """write a log pump message to kmsg"""
    if kmsg_fd < 0:
        return
    try:
        os.write(kmsg_fd, f"<4>L3: log pump {message}\n".encode())
    except OSError:
        pass


def _copy_pipe_to_file(pipe_read_fd, file_fd, kmsg_fd):
    """copy the pipe into the file"""
    dropped = 0
    while chunk := os.read(pipe_read_fd, LOG_PIPE_CHUNK_BYTES):
        view = memoryview(chunk)
        while view:
            try:
                view = view[os.write(file_fd, view):]
            except OSError as e:
                if not dropped:
                    _report_log_pump(kmsg_fd, f"write to fd {file_fd} failed: {e}")
                dropped += len(view)
                break
    if dropped:
        _report_log_pump(kmsg_fd, f"dropped {dropped} bytes")


def _close_all_fds_except(keep):
    """close all descriptors except keep"""
    for name in os.listdir("/proc/self/fd"):
        fd = int(name)
        if fd in keep:
            continue
        try:
            os.close(fd)
        except OSError as e:
            if e.errno != errno.EBADF:
                raise


def _drop_all_capabilities():
    """clear the effective, permitted and inheritable sets"""
    header = ctypes.create_string_buffer(struct.pack("<Ii", 0x20080522, 0), 8)
    if libc.capset(header, ctypes.create_string_buffer(24)) != 0:
        raise OSError(ctypes.get_errno(), "capset failed")


def _run_log_pump(pipe_read_fd, file_fd, kmsg_fd, ready_fd):
    """run the log pump and end the process"""
    status = 1
    try:
        for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(number, signal.SIG_IGN)
        _close_all_fds_except({pipe_read_fd, file_fd, kmsg_fd, ready_fd})
        _drop_all_capabilities()
        os.write(ready_fd, b"r")
        os.close(ready_fd)
        _copy_pipe_to_file(pipe_read_fd, file_fd, kmsg_fd)
        status = 0
    except BaseException as e:
        _report_log_pump(kmsg_fd, f"stopped: {e!r}")
    finally:
        os._exit(status)


def stdio_to_null():
    """point stdout and stderr at /dev/null"""
    fd = os.open("/dev/null", os.O_WRONLY)
    for target in (1, 2):
        os.dup2(fd, target)
    if fd > 2:
        os.close(fd)


def route_stdio_through_pipe(log_path=None):
    """point stdout and stderr at a log pipe"""
    groups = {}
    pumps = []
    for fd in (1, 2):
        if log_path is not None:
            groups.setdefault(log_path, []).append(fd)
            continue
        info = os.fstat(fd)
        if stat.S_ISREG(info.st_mode):
            groups.setdefault((info.st_dev, info.st_ino), []).append(fd)
    for fds in groups.values():
        if log_path is not None:
            file_fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        else:
            file_fd = os.dup(fds[0])
        pipe_read_fd, pipe_write_fd = os.pipe()
        ready_read_fd, ready_write_fd = os.pipe()
        try:
            kmsg_fd = os.open(KMSG_PATH, os.O_WRONLY | os.O_APPEND)
        except OSError:
            kmsg_fd = -1
        pump = os.fork()
        if pump == 0:
            os.close(ready_read_fd)
            _run_log_pump(pipe_read_fd, file_fd, kmsg_fd, ready_write_fd)
        os.close(ready_write_fd)
        started = os.read(ready_read_fd, 1)
        os.close(ready_read_fd)
        if kmsg_fd >= 0:
            os.close(kmsg_fd)
        if started != b"r":
            _, wait_status = os.waitpid(pump, 0)
            for fd in (pipe_read_fd, pipe_write_fd, file_fd):
                os.close(fd)
            raise OSError(errno.EPIPE, f"the log pump {pump} ended at start with wait status {wait_status}")
        pumps.append(pump)
        os.close(pipe_read_fd)
        os.close(file_fd)
        for fd in fds:
            os.dup2(pipe_write_fd, fd)
        os.close(pipe_write_fd)
    return pumps


def phase(layer, name):
    """write the RHIZO_PHASE marker opening a boot phase"""
    assert layer in ("A", "B", "C"), layer
    kmsg(f"RHIZO_PHASE {layer}:{name}")
def unshare(f):
    """unshare the given namespaces"""
    if libc.unshare(f)!=0:
        kmsg(f"unshare FAIL {os.strerror(ctypes.get_errno())}"); os._exit(1)
def mount(s,t,fs,fl,d=None):
    """call mount(2) and log a failure"""
    if libc.mount(s.encode() if s else None,t.encode(),fs.encode() if fs else None,fl,
                  d.encode() if d else None)!=0:
        kmsg(f"mount {t}: {os.strerror(ctypes.get_errno())}"); return False
    return True
def pivot_root(new,old): return libc.syscall(155,new.encode(),old.encode())==0

LOOP_CTL_GET_FREE = 0x4C82
LOOP_CONFIGURE = 0x4C0A
LOOP_CLR_FD = 0x4C01
LOOP_GET_STATUS64 = 0x4C05
LO_FLAGS_READ_ONLY = 1
LO_FLAGS_AUTOCLEAR = 4
LOOP_ATTACH_TRIES = 8


def loop_config(backing_fd, flags):
    """return the struct loop_config bytes for backing_fd"""
    info = struct.pack("=5Q4I64s64s32s2Q", 0, 0, 0, 0, 0, 0, 0, 0, flags, b"", b"", b"", 0, 0)
    return struct.pack("=II", backing_fd, 0) + info + bytes(64)


def loop_attach(path, read_only=False, autoclear=False, ctl="/dev/loop-control"):
    """attach path to a free loop device"""
    mode = os.O_RDONLY if read_only else os.O_RDWR
    flags = (LO_FLAGS_READ_ONLY if read_only else 0) | (LO_FLAGS_AUTOCLEAR if autoclear else 0)
    backing = os.open(path, mode | os.O_CLOEXEC)
    try:
        ctl_fd = os.open(ctl, os.O_RDWR | os.O_CLOEXEC)
        try:
            for _ in range(LOOP_ATTACH_TRIES):
                dev = f"/dev/loop{fcntl.ioctl(ctl_fd, LOOP_CTL_GET_FREE)}"
                fd = os.open(dev, mode | os.O_CLOEXEC)
                try:
                    fcntl.ioctl(fd, LOOP_CONFIGURE, loop_config(backing, flags))
                except OSError as e:
                    os.close(fd)
                    if e.errno != errno.EBUSY:
                        raise
                    continue
                return dev, fd
        finally:
            os.close(ctl_fd)
    finally:
        os.close(backing)
    raise OSError(errno.EBUSY, f"no free loop device for {path} after {LOOP_ATTACH_TRIES} tries")


def loop_detach(dev):
    """detach the loop device dev"""
    fd = os.open(dev, os.O_RDONLY | os.O_CLOEXEC)
    try:
        fcntl.ioctl(fd, LOOP_CLR_FD)
    finally:
        os.close(fd)


def loop_backing_id(dev):
    """return dev's backing file device and inode"""
    fd = os.open(dev, os.O_RDONLY | os.O_CLOEXEC)
    try:
        info = fcntl.ioctl(fd, LOOP_GET_STATUS64, bytes(struct.calcsize("=5Q4I64s64s32s2Q")))
    finally:
        os.close(fd)
    return struct.unpack_from("=QQ", info)


def loops_backed_by(path, sysblock="/sys/block", backing_id=loop_backing_id):
    """find the loops backing path"""
    try:
        st = os.stat(path)
        want = (st.st_dev, st.st_ino)
    except FileNotFoundError:
        want = None
    devs = []
    for name in sorted(os.listdir(sysblock)):
        try:
            with open(os.path.join(sysblock, name, "loop", "backing_file")) as f:
                backing = f.read().rstrip("\n")
        except FileNotFoundError:
            continue
        if backing == path:
            devs.append(f"/dev/{name}")
            continue
        if want is None:
            continue
        try:
            if backing_id(f"/dev/{name}") == want:
                devs.append(f"/dev/{name}")
        except OSError as e:
            if e.errno not in (errno.ENXIO, errno.ENOENT):
                raise
    return devs


def _kmsg_read(fd):
    """return fd's next kernel log record"""
    while True:
        try:
            return os.read(fd, 8192)
        except BlockingIOError:
            return b""
        except BrokenPipeError:
            continue


def _kmsg_parse(rec):
    """return a kernel log record's microseconds and message"""
    head, _, body = rec.decode(errors="replace").partition(";")
    return int(head.split(",")[2]), body.split("\n", 1)[0]


def kmsg_records(follow=False, backlog=None, path="/dev/kmsg"):
    """yield the ring's last records, then new ones"""
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)
    try:
        ring = None if backlog is None else collections.deque(maxlen=backlog)
        while rec := _kmsg_read(fd):
            if ring is None:
                yield _kmsg_parse(rec)
            else:
                ring.append(_kmsg_parse(rec))
        if ring is not None:
            yield from ring
        if not follow:
            return
        fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK)
        while rec := _kmsg_read(fd):
            yield _kmsg_parse(rec)
    finally:
        os.close(fd)


MODULE_SUFFIXES = (".ko", ".ko.zst", ".ko.xz", ".ko.gz")


def module_name(path):
    """return the module name of a module file path"""
    base = os.path.basename(path)
    for suffix in MODULE_SUFFIXES:
        if base.endswith(suffix):
            base = base[:-len(suffix)]
            break
    return base.replace("-", "_")


def module_entry(name, kver=None, root="/lib/modules"):
    """return name's file and dependency paths from modules.dep"""
    base = f"{root}/{kver or os.uname().release}"
    want = name.replace("-", "_")
    with open(f"{base}/modules.dep") as f:
        for line in f:
            mod, _, deps = line.partition(":")
            if module_name(mod) == want:
                return os.path.join(base, mod), [os.path.join(base, d) for d in deps.split()]
    try:
        with open(f"{base}/modules.builtin") as f:
            if any(module_name(b) == want for b in f.read().split()):
                return "(builtin)", []
    except FileNotFoundError:
        pass
    return None


def _current_fsuid():
    """return this thread's filesystem uid"""
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith("Uid:"):
                    return int(line.split()[4])
    except (OSError, IndexError, ValueError):
        pass
    return None

def set_fsuid(uid, log=kmsg):
    """switch this thread's fsuid and verify it"""
    prev = libc.setfsuid(uid)
    now = _current_fsuid()
    if now != uid:
        log(f"setfsuid({uid}) did not take (still {now}, was {prev}) -- "
            "CAP_SETUID missing or refused")
        return None
    return prev

def get_dumpable():
    """return this process's dumpable flag from prctl(PR_GET_DUMPABLE)"""
    return libc.prctl(PR_GET_DUMPABLE, 0, 0, 0, 0)

def restore_dumpable(was, log=kmsg):
    """restore the dumpable flag an fsuid switch changed"""
    if was not in (0, 1) or get_dumpable() == was:
        return
    if libc.prctl(PR_SET_DUMPABLE, was, 0, 0, 0) != 0:
        log(f"prctl(PR_SET_DUMPABLE, {was}) failed: {os.strerror(ctypes.get_errno())}")

def _dirname_owner(path):
    """return the uid owning path's parent directory"""
    try:
        return os.stat(os.path.dirname(path) or "/").st_uid
    except OSError:
        return None

def stat_as_owner(path, log=kmsg):
    """stat path as its parent directory's owner"""
    try:
        return os.stat(path)
    except PermissionError:
        pass
    except OSError:
        return None
    owner = _dirname_owner(path)
    if owner is None:
        return None
    dumpable = get_dumpable()
    prev = set_fsuid(owner, log)
    if prev is None:
        return None
    try:
        return os.stat(path)
    except OSError:
        return None
    finally:
        set_fsuid(prev, log)
        restore_dumpable(dumpable, log)

def bind_as_owner(src, dst, log=kmsg):
    """bind-mount src onto dst as src's directory owner"""
    owner = _dirname_owner(src)
    if owner is None:
        log(f"{src}: cannot learn its own directory's owner, binding as-is")
        return mount(src, dst, None, MS_BIND)
    dumpable = get_dumpable()
    prev = set_fsuid(owner, log)
    if prev is None:
        return mount(src, dst, None, MS_BIND)
    try:
        return mount(src, dst, None, MS_BIND)
    finally:
        set_fsuid(prev, log)
        restore_dumpable(dumpable, log)


ANDROID_NEEDED_MODULES = ("uinput", "inet_diag", "tcp_diag", "udp_diag", "vsock", "vmw_vsock_virtio_transport",
                          "vsock_loopback", "sch_ingress", "nfnetlink_log")


def load_needed_modules(run=subprocess.run):
    """modprobe each ANDROID_NEEDED_MODULES entry"""
    for mod in ANDROID_NEEDED_MODULES:
        r = run(["modprobe", mod], capture_output=True, text=True)
        if r.returncode:
            kmsg(f"WARNING: module {mod} not loaded ({(r.stderr or '').strip() or 'modprobe failed'})"
                 f" -- Android's policy refuses its autoload")



def product_build_prop_source():
    """return the patched product build.prop"""
    if not os.path.isdir(f"{GSI}/product"):
        return None
    patches = stock_patches_dir()
    for src in ((os.path.join(patches, "product-build.prop"),) if patches else ()) + (beside("product-build.prop"),):
        if os.path.exists(src):
            return src
    return None


def beside(*parts):
    """return a path next to the launcher, from name or path segments"""
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), *parts)


def release_hal_bin(gfx_src, name, release=None, exists=os.path.exists):
    """return the HAL binary a boot of release stages for name"""
    if (RHIZO_RELEASE if release is None else release) == "a15" and name == "rhizo-power-service":
        own = beside("rel", "a15", "rhizo-power-service")
        if exists(own):
            return own
    return os.path.join(gfx_src, name)


A16_ONLY_PAYLOAD = ("audio_policy_configuration.xml", "RhizoAudioRouter.apk")
AUDIO_SET_RELEASES = ("a16", "a17", "a15")


def release_skips(name, release=None):
    """return whether a boot of release leaves the shipped file name out"""
    return (RHIZO_RELEASE if release is None else release) not in AUDIO_SET_RELEASES and name in A16_ONLY_PAYLOAD


KEYMINT_GSI_LIBS = (
    "android.hardware.security.rkp-V3-ndk.so",
    "android.hardware.security.sharedsecret-V1-ndk.so",
    "android.hardware.security.secureclock-V1-ndk.so",
    "libcppbor.so",
    "libcppcose_rkp.so",
    "libsoft_attestation_cert.so",
    "libkeymaster_messages.so",
    "libhidlbase.so",
    "libhardware.so",
    "libvndksupport.so",
    "libkeymaster_portable.so",
    "libc++.so",
    "libbase.so",
)


GSI_LIBS_SOURCE = "source"


def gsi_libs_dir():
    """return the GSI-derived library set directory"""
    root = os.path.join(RHIZO_DERIVED_DIR, "gsi_libs")
    derived = os.path.join(root, os.path.basename(os.path.normpath(GSI)))
    return derived if os.path.isdir(derived) else beside("share", "gsi_libs")


def stock_patches_dir():
    """return this GSI tree's host-derived stock patches directory"""
    root = os.path.join(RHIZO_DERIVED_DIR, "patches")
    d = os.path.join(root, os.path.basename(os.path.normpath(GSI)))
    return d if os.path.isdir(d) else None


def gsi_derived_missing():
    """return every GSI-derived file a boot links and cannot find"""
    d = gsi_libs_dir()
    return [os.path.join(d, n) for n in KEYMINT_GSI_LIBS if not os.path.isfile(os.path.join(d, n))]


def gsi_derived_mismatch():
    """return why the derived library set was not copied from the booting tree"""
    d = gsi_libs_dir()
    if os.path.dirname(d) != os.path.join(RHIZO_DERIVED_DIR, "gsi_libs"):
        return None
    if not GSI_FINGERPRINT:
        return (f"{GSI} carries no ro.system.build.fingerprint or ro.build.fingerprint, so {d} "
                f"cannot be shown to be copied from it")
    try:
        with open(os.path.join(d, GSI_LIBS_SOURCE)) as f:
            stamp = dict(l.rstrip("\n").split("=", 1) for l in f if "=" in l)
    except OSError:
        return f"{d} has no {GSI_LIBS_SOURCE} stamp, so its copy never finished"
    if stamp.get("fingerprint", "") != GSI_FINGERPRINT:
        return (f"{d} was copied from {stamp.get('tree', '?')} ({stamp.get('fingerprint', '')!r}), "
                f"not from {GSI} ({GSI_FINGERPRINT!r})")
    return None

HOST_PRIMER_PATH = "/run/rhizo-host-primer.py"

VBMETA_LOOP_DEV = None


def set_vbmeta_loop_dev(dev):
    """record the loop device vbmeta.img is attached to"""
    global VBMETA_LOOP_DEV
    VBMETA_LOOP_DEV = dev


WRITE_PRIMER_SCRIPT = None


def set_write_primer_script(fn):
    """record the function that writes the host primer script"""
    global WRITE_PRIMER_SCRIPT
    WRITE_PRIMER_SCRIPT = fn


RELABELLER_DONE_FD = -1


def set_relabeller_done_fd(fd):
    """record the write end of the relabeller's done pipe"""
    global RELABELLER_DONE_FD
    RELABELLER_DONE_FD = fd


def swap_kmsg_fd(new_fd):
    """point kmsg() at a new /dev/kmsg fd and return the old one"""
    global _KMSG_FD
    old, _KMSG_FD = _KMSG_FD, new_fd
    return old

_INPUT_SUPERVISOR = [None]


_UINPUT_FILTERED = [False]


def set_input_supervisor(sock):
    """hold the socket to this instance's rhizo-inputd supervisor"""
    _INPUT_SUPERVISOR[0] = sock


def set_uinput_filtered(flag):
    """record whether init's process must filter UI_DEV_CREATE"""
    _UINPUT_FILTERED[0] = bool(flag)


def uinput_filtered():
    """return the flag set_uinput_filtered() holds"""
    return _UINPUT_FILTERED[0]


def input_supervisor():
    """return the socket set_input_supervisor() holds, or None"""
    return _INPUT_SUPERVISOR[0]

def cgroup_write(path, value):
    """write a value to a cgroup file through an unbuffered fd"""
    fd = os.open(path, os.O_WRONLY)
    try:
        os.write(fd, value.encode())
    finally:
        os.close(fd)


def _host_mem_total_bytes():
    """return this host's total ram in bytes"""
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) * 1024
    except (OSError, ValueError) as e:
        kmsg(f"WARNING: cannot read /proc/meminfo for memory.max ({e}) -- using the floor")
    return 0


def _host_threads_max():
    """return /proc/sys/kernel/threads-max"""
    try:
        return int(open("/proc/sys/kernel/threads-max").read().strip())
    except (OSError, ValueError) as e:
        kmsg(f"WARNING: cannot read /proc/sys/kernel/threads-max for pids.max ({e}) -- using the floor")
        return 0


_MEM_RESERVE_BYTES = 2 * 1024 * 1024 * 1024
_MEM_FLOOR_BYTES = 512 * 1024 * 1024
_mem_total = _host_mem_total_bytes()
_MEM_MAX_DEFAULT = max(_mem_total - _MEM_RESERVE_BYTES, _MEM_FLOOR_BYTES) if _mem_total else _MEM_FLOOR_BYTES
RHIZO_MEM_MAX_BYTES = int(os.environ.get("RHIZO_MEM_MAX_BYTES", str(_MEM_MAX_DEFAULT)))

_PIDS_FLOOR = 1024
_threads_max = _host_threads_max()
_PIDS_MAX_DEFAULT = max(_threads_max // 4, _PIDS_FLOOR) if _threads_max else _PIDS_FLOOR
RHIZO_PIDS_MAX = int(os.environ.get("RHIZO_PIDS_MAX", str(_PIDS_MAX_DEFAULT)))


_PREPARED_KEY = None
_PREPARE_RECORDING = False
_RECORDED_COPIES = []


def set_prepared(key):
    """record the accepted prepared tree's key for this launch"""
    global _PREPARED_KEY
    _PREPARED_KEY = key


def prepared_key():
    """return the accepted prepared tree's key, or None on the copy path"""
    return _PREPARED_KEY


def restorecon_line(exe_path):
    """return the restorecon line for a HAL executable"""
    if prepared_key() is not None:
        return ""
    return f"    restorecon {exe_path}\n"


def early_init_restorecon(exe_path):
    """return the early-init trigger holding restorecon_line()"""
    line = restorecon_line(exe_path)
    return f"on early-init\n{line}" if line else ""


def set_prepare_recording(on):
    """turn recording of staged copies on or off"""
    global _PREPARE_RECORDING, _RECORDED_COPIES
    _PREPARE_RECORDING = on
    if on:
        _RECORDED_COPIES = []


def recorded_copies():
    """return a copy of the recorded (src, dst) pairs"""
    return list(_RECORDED_COPIES)


def is_prepared_bind_path(dst):
    """return whether dst lies under a prepared bind subtree"""
    if not _PREPARED_KEY:
        return False
    for sub in PREPARED_BINDS:
        base = f"{RUN_ROOT}/{sub}"
        if dst == base or dst.startswith(base + "/"):
            return True
    return False


def record_prepare_input(src, dst):
    """append a (src, dst) pair to the recorded copies"""
    if _PREPARE_RECORDING:
        _RECORDED_COPIES.append((src, dst))


def stage_bulk(src, dst, mode):
    """copy src to dst and chmod it"""
    if is_prepared_bind_path(dst):
        assert os.path.exists(dst), f"stage_bulk: prepared bind is missing {dst}"
        return
    import shutil
    shutil.copy(src, dst)
    os.chmod(dst, mode)
    record_prepare_input(src, dst)


def own_domain():
    """return this process's selinux context"""
    try:
        with open("/proc/self/attr/current") as f:
            return f.read().strip("\0").strip()
    except OSError:
        return ""


def bind_private(src, dst, log=kmsg):
    """bind src onto dst and make the bind private"""
    if not mount(src, dst, None, MS_BIND):
        return False
    if not mount(None, dst, None, MS_PRIVATE):
        log(f"bind of {src} at {dst}: could not make it private")
    return True


def mounts_under(path):
    """return every mount point below path, deepest first"""
    prefix = path.rstrip("/") + "/"
    found = []
    try:
        with open("/proc/self/mountinfo") as f:
            for line in f:
                fields = line.split()
                if len(fields) > 4 and fields[4].startswith(prefix):
                    found.append(fields[4].replace("\\040", " "))
    except OSError:
        return []
    return sorted(set(found), key=lambda p: -p.count("/"))


def _mountinfo_unescape(s):
    """decode the octal escapes in a mountinfo field"""
    return (s.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n")
            .replace("\\134", "\\"))


def read_mountinfo(table="/proc/self/mountinfo"):
    """return the rows of mountinfo"""
    rows = []
    try:
        with open(table) as f:
            for line in f:
                fields = line.split()
                if len(fields) >= 5:
                    rows.append((fields[0], fields[1], fields[2],
                                 _mountinfo_unescape(fields[3]), _mountinfo_unescape(fields[4])))
    except OSError:
        return None
    return rows


def mounts_reaching(path, rows):
    """return the mount ids whose mount point or root is inside path"""
    path = os.path.realpath(path)

    def within(p, d):
        """return whether path p is d or lies under it"""
        return p == d or p.startswith(d if d == "/" else d + "/")

    def rel(p, m):
        """return p relative to mount point m, empty when they are equal"""
        return "" if p == m else p[1:] if m == "/" else p[len(m) + 1:]

    def join(a, r):
        """join path a with relative path r, giving a when r is empty"""
        return a if r == "" else "/" + r if a == "/" else a + "/" + r

    by_id = {r[0]: r for r in rows}
    best = None
    for r in rows:
        if within(path, r[4]) and (best is None or len(r[4]) >= len(best[4])):
            best = r
    if best is None:
        return []
    fs = join(best[3], rel(path, best[4]))
    found = []
    for mid, parent, dev, root, mp in rows:
        if mid == best[0]:
            continue
        p = by_id.get(parent)
        if ((dev == best[2] and within(root, fs))
                or (p is not None and p[2] == best[2] and within(join(p[3], rel(mp, p[4])), fs))):
            found.append(mid)
    return found


def mount_points_at_or_under(path, rows):
    """return mount points at or below path"""
    below = [r[4] for r in rows if r[4] == path or r[4].startswith(path.rstrip("/") + "/")]
    return sorted(below, key=len, reverse=True)


def umount_tree(path, log=kmsg):
    """unmount path and its submounts, returning failures"""
    rows = read_mountinfo()
    if rows is None:
        return [f"{path}: /proc/self/mountinfo is unreadable"]
    failed = []
    for point in mount_points_at_or_under(path, rows):
        if libc.umount2(point.encode(), 0) != 0:
            failed.append(f"{point}: {os.strerror(ctypes.get_errno())}")
    for line in failed:
        log(f"umount {line}")
    return failed


def is_mount_point(path):
    """return whether mountinfo lists path as a mount point"""
    rows = read_mountinfo()
    if rows is None:
        raise OSError(errno.EIO, "/proc/self/mountinfo is unreadable")
    real = os.path.realpath(path)
    return any(row[4] == real for row in rows)


def share_run_dir(path):
    """make path a shared mount point"""
    if not is_mount_point(path) and not mount(path, path, None, MS_BIND | MS_REC):
        raise OSError(ctypes.get_errno(), f"bind of {path} onto itself failed")
    if not mount(None, path, None, MS_SHARED):
        raise OSError(ctypes.get_errno(), f"making {path} shared failed")


def unmount_under(path, log=kmsg):
    """unmount every mount below path and return how many went"""
    n = 0
    for m in mounts_under(path):
        if libc.umount2(m.encode(), 0) == 0 or libc.umount2(m.encode(), 2) == 0:
            n += 1
        else:
            log(f"{path}: a mount at {m} would not unmount -- refusing to remove through it")
            return -1
    if n:
        log(f"{path}: {n} mount(s) unmounted before removal")
    return n


def _selinux_label(path):
    """return path's security.selinux xattr without following symlinks"""
    try:
        raw = os.getxattr(path, "security.selinux", follow_symlinks=False)
    except OSError:
        return None
    return raw.decode(errors="replace").rstrip("\0")


def _hash_file(path):
    """return the sha256 hex digest of a file"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def input_meta(path):
    """return the manifest record of a prepared-tree input"""
    st = os.lstat(path)
    return {"sha256": _hash_file(path), "size": st.st_size,
            "mtime_ns": st.st_mtime_ns, "ino": st.st_ino}


def output_meta(path):
    """return the manifest record of a prepared-tree output"""
    st = os.lstat(path)
    is_dir = os.path.isdir(path) and not os.path.islink(path)
    is_lnk = os.path.islink(path)
    meta = {"kind": "dir" if is_dir else "file", "size": st.st_size,
            "ino": st.st_ino, "ctime_ns": int(st.st_ctime_ns),
            "mode": st.st_mode & 0o777, "label": _selinux_label(path)}
    if not is_dir and not is_lnk:
        meta["sha256"] = _hash_file(path)
    return meta


def _check_input(path, meta):
    """check a prepared-tree input against its record"""
    try:
        st = os.lstat(path)
    except OSError:
        return f"input-changed:{path}"
    if (st.st_size == meta.get("size") and st.st_ino == meta.get("ino")
            and st.st_mtime_ns == meta.get("mtime_ns")):
        return None
    try:
        digest = _hash_file(path)
    except OSError:
        return f"input-changed:{path}"
    if digest == meta.get("sha256"):
        return None
    return f"input-changed:{path}"


def _check_output(tree, rel, meta):
    """check a prepared-tree output against its record"""
    path = os.path.join(tree, rel)
    try:
        st = os.lstat(path)
    except OSError:
        return f"output-tampered:{rel}"
    if (st.st_size != meta.get("size") or st.st_ino != meta.get("ino")
            or int(st.st_ctime_ns) != meta.get("ctime_ns")):
        return f"output-tampered:{rel}"
    if _selinux_label(path) != meta.get("label"):
        return f"output-tampered:{rel}"
    return None


_SOFTWARE_RENDERING = {}


def _file_version(path):
    """return a path with its mtime and size"""
    try:
        st = os.stat(path)
    except OSError:
        return (path, None)
    return (path, st.st_mtime_ns, st.st_size)


def software_rendering():
    """tell whether the host policy turns devices.dri off"""
    from sandbox import capabilities
    key = _file_version(capabilities.config_path())
    if key not in _SOFTWARE_RENDERING:
        policy, err = capabilities.read_policy()
        if policy is None:
            kmsg(f"{err} -- devices.dri cannot be read")
        _SOFTWARE_RENDERING[key] = policy is not None and not policy.allows("devices.dri")
    return _SOFTWARE_RENDERING[key]


def host_policy_refusal():
    """name why the host policy file stops a launch"""
    from sandbox import capabilities
    err = capabilities.read_policy()[1]
    if err is None:
        return None
    return (f"host-policy-error ({err}; devices.dri cannot be read: "
            "fix /etc/rhizo/policy.conf, whose error rhizo doctor names)")


def instance_overlay_error():
    """return why this instance's policy overlay is refused"""
    from sandbox import capabilities
    overlay = capabilities.instance_config_path(SANDBOX_ID)
    if overlay is None or capabilities.read_policy()[0] is None:
        return None
    return capabilities.read_policy(None, overlay)[1]


def gpu_driver_dir():
    """get the share/ directory of the GPU driver set this launch stages"""
    return os.environ.get("RHIZO_GPU_DRIVER_DIR") or ("gpu_driver_software" if software_rendering() else "gpu_driver")


POLICY_MODE_STATE = "/run/rhizo-policy-mode"


def record_policy_mode():
    """write dri=on or dri=off"""
    mode = "off" if software_rendering() else "on"
    tmp = os.path.join(os.path.dirname(POLICY_MODE_STATE), ".%s.tmp" % os.path.basename(POLICY_MODE_STATE))
    try:
        with open(tmp, "w") as f:
            f.write("dri=%s\n" % mode)
        os.replace(tmp, POLICY_MODE_STATE)
    except OSError as e:
        kmsg(f"could not record the policy's devices.dri in {POLICY_MODE_STATE}: {e}")
        return False
    kmsg(f"RHIZO_MARKER policy_dri={mode}")
    return True


def loaded_policy_dri():
    """return the dri mode recorded for the loaded policy"""
    try:
        with open(POLICY_MODE_STATE) as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    for line in lines:
        if line in ("dri=on", "dri=off"):
            return line[len("dri="):]
    return None


def gpu_refusal(render_node_found, loaded_dri=None):
    """name why this launch cannot render"""
    host_err = host_policy_refusal()
    if host_err:
        return host_err
    wanted = "off" if software_rendering() else "on"
    if loaded_dri is not None and loaded_dri != wanted:
        return (f"policy-reload-needed (devices.dri is {wanted}, but the policy loaded this host boot is for dri = "
                f"{loaded_dri}; reboot the host to switch)")
    if software_rendering():
        if os.environ.get("RHIZO_ABI32") == "1":
            return "software-abi32 (the software driver set is 64-bit only; unset RHIZO_ABI32 or set [devices] dri = on)"
        return None
    overlay_err = instance_overlay_error()
    if overlay_err:
        return (f"instance-policy-error ({overlay_err}; a refused overlay denies this instance every optional "
                "capability, its render node among them)")
    if not render_node_found:
        return ("no-render-node (devices.dri is on and the host has no render node; set [devices] dri = off "
                "in /etc/rhizo/policy.conf to render in software)")
    return None


def validate_prepared():
    """validate the prepared tree for this boot"""
    try:
        key = os.path.basename(os.readlink(f"{PREPARED_ROOT}/current"))
        with open(f"{PREPARED_ROOT}/{key}/manifest.json") as f:
            manifest = json.load(f)
    except (OSError, ValueError):
        return None, "manifest-unreadable"
    if str(manifest.get("layout_version")) != PREPARED_LAYOUT_VERSION:
        return None, "layout-version"
    if manifest.get("gsi_fingerprint") != GSI_FINGERPRINT:
        return None, "gsi-fingerprint"
    if manifest.get("kernel") != os.uname().release:
        return None, "kernel"
    if manifest.get("gpu_driver") != gpu_driver_dir():
        return None, "gpu-driver"
    for path, meta in manifest.get("inputs", {}).items():
        reason = _check_input(path, meta)
        if reason:
            return None, reason
    tree = f"{PREPARED_ROOT}/{key}"
    for rel, meta in manifest.get("outputs", {}).items():
        reason = _check_output(tree, rel, meta)
        if reason:
            return None, reason
    return key, None


PREPARE_REQUEST = "/var/lib/rhizo/prepare-request"
PREPARED_REFUSAL_NAME = "refusal"
REPREPARE_REASONS = ("manifest-unreadable", "layout-version", "gsi-fingerprint", "kernel", "gpu-driver",
                     "input-changed", "output-tampered")


def prepare_unit_enabled():
    """return whether systemctl reports rhizo-prepare.service enabled"""
    r = subprocess.run(["systemctl", "is-enabled", "rhizo-prepare.service"], capture_output=True, text=True,
                       timeout=30)
    return r.stdout.strip() in ("enabled", "enabled-runtime")


def _replace_file(path, text):
    """write text beside path and rename it over path"""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def request_reprepare(reason, prepared_root=PREPARED_ROOT, request=PREPARE_REQUEST,
                      unit_enabled=prepare_unit_enabled):
    """record a refused prepared tree and request a rebuild"""
    kind = reason.split(":", 1)[0]
    if kind not in REPREPARE_REASONS:
        return "not-repairable"
    try:
        key = os.path.basename(os.readlink(f"{prepared_root}/current"))
    except OSError:
        key = ""
    record = os.path.join(prepared_root, PREPARED_REFUSAL_NAME)
    try:
        with open(record) as f:
            prior = dict(l.split("=", 1) for l in f.read().splitlines() if "=" in l)
    except FileNotFoundError:
        prior = {}
    same = prior.get("key") == key and prior.get("reason", "").split(":", 1)[0] == kind
    extra = ""
    if os.path.exists(request):
        outcome = "pending"
    elif same and prior.get("outcome") == "rebuild-failed":
        outcome, extra = "rebuild-failed", f"failed={prior.get('failed', '')}\n"
    elif same and prior.get("outcome") in ("requested", "pending", "repeated"):
        outcome = "repeated"
    else:
        try:
            enabled = unit_enabled()
        except (OSError, subprocess.TimeoutExpired) as e:
            enabled, outcome, extra = None, "unit-query-failed", f"error={e!r}\n"
        if enabled is False:
            outcome = "no-prepare-unit"
        elif enabled:
            _replace_file(request, "release=current\nvariant=\nwipe_data=0\norigin=prepared-refused\n"
                                   f"reason=prepared-refused:{reason}\n")
            outcome = "requested"
    if os.path.isdir(prepared_root):
        _replace_file(record, f"key={key}\nreason={reason}\noutcome={outcome}\n{extra}")
    kmsg(f"RHIZO_MARKER prepared_reprepare={outcome} reason={reason}")
    return outcome


def clear_prepared_refusal(prepared_root=PREPARED_ROOT):
    """remove the refused prepared tree's record"""
    try:
        os.unlink(os.path.join(prepared_root, PREPARED_REFUSAL_NAME))
    except FileNotFoundError:
        pass


BINDER_DEVICES_FILE = os.environ.get("RHIZO_BINDER_DEVICES_FILE", "/sys/module/binder/parameters/devices")
ASHMEM_DEVICE = os.environ.get("RHIZO_ASHMEM_DEVICE", "/dev/ashmem")
PROC_CONFIG = os.environ.get("RHIZO_PROC_CONFIG", "/proc/config.gz")
BINDER_DEVICES = "binder,hwbinder,vndbinder"


def kernel_lacks():
    """return what the running kernel lacks"""
    lacks = []
    if not os.path.exists(BINDER_DEVICES_FILE):
        lacks.append("built-in binder")
    try:
        if not stat.S_ISCHR(os.stat(ASHMEM_DEVICE).st_mode):
            lacks.append(ASHMEM_DEVICE)
    except OSError:
        lacks.append(ASHMEM_DEVICE)
    if not os.path.exists(PROC_CONFIG):
        lacks.append(PROC_CONFIG)
    return lacks


def _write_manifest(path, text):
    """replace manifest.json whole"""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    dfd = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)


def rekey_prepared_kernel():
    """move the prepared tree onto this boot's kernel"""
    try:
        key = os.path.basename(os.readlink(f"{PREPARED_ROOT}/current"))
        path = f"{PREPARED_ROOT}/{key}/manifest.json"
        with open(path) as f:
            before = f.read()
        manifest = json.loads(before)
    except (OSError, ValueError):
        return None, "manifest-unreadable"
    kernel = os.uname().release
    was = manifest.get("kernel")
    if was == kernel:
        got, reason = validate_prepared()
        return (got, "unchanged") if got else (None, reason)
    manifest["kernel"] = kernel
    manifest["kernel_history"] = list(manifest.get("kernel_history", [])) + [was]
    _write_manifest(path, json.dumps(manifest))
    got, reason = validate_prepared()
    if got:
        return got, "rekeyed"
    _write_manifest(path, before)
    return None, reason
