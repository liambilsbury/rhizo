#!/usr/bin/env python3
# rhizo's confined-privileged launcher
import ctypes, os, re, sys, time, fcntl, struct, hashlib, subprocess, socket, signal, select, json, errno, tempfile, stat

from sandbox import battery
from sandbox import capabilities
from sandbox import hostlock
from sandbox import selinux_policy
from sandbox import selinux_ns
from sandbox import guest_files
from sandbox import sensors
from sandbox import uplinks
from sandbox import wifi
from sandbox import codec2

from sandbox.core import (AID_READPROC, CGROUP_INVOCATION_FILE, CGROUP_ROOT, CGROUP_ROOT_FILE,
    CLONE_NEWCGROUP, CLONE_NEWIPC, CLONE_NEWNET, CLONE_NEWNS, CLONE_NEWPID, CLONE_NEWUTS,
    DEVICE_STATE_LINK, DEVICE_STATE_MOUNT, DROP_CAPS, GSI, GSI_DEBUGGABLE, GSI_FINGERPRINT,
    G_PID_FILE, HANDOFF_DIR, HOST_ARCH, HOST_ARCH_AMD64, HOST_PRIMER_PATH, INIT_PID_FILE, MS_BIND,
    MS_RDONLY, MS_REMOUNT, NETBRIDGED_LOG, NETBRIDGED_RUNTIME_DIR, NETBRIDGED_UNIT, NET_GUEST_MAC,
    NET_HOST_ADDR, NET_POOL_END, NET_POOL_START, NET_SUBNET, NEWROOT, PREPARED_BINDS, PREPARED_ROOT,
    PR_CAPBSET_DROP, PR_SET_MEMORY_MERGE, RHIZO_ADB_ROOT, RHIZO_APEX_DIR, RHIZO_CACHE_DIR,
    RHIZO_DATA_IMG, RHIZO_DATA_TEMPLATE, RHIZO_DEBUG_PERMISSIVE_DOMAIN, RHIZO_DEBUG_PROC_READ,
    RHIZO_ENFORCING, RHIZO_LOG_DIR, RHIZO_MEM_MAX_BYTES, RHIZO_PERMISSIVE, RHIZO_PERSIST_DATA,
    RHIZO_PIDS_MAX, RHIZO_RELEASE, RHIZO_RESIDENT_DISPATCH, RHIZO_RESIDENT_G,
    RHIZO_SEPOLICY_NODONTAUDIT, RHIZO_UNDER_UNIT, RHIZO_VENDOR_DIR, RUN_ROOT, SANDBOX_ID,
    SELINUXNS_RECORDS_DIR, SUPERVISOR_CGROUP, SUPERVISOR_LOG, SUPERVISOR_STATE, VETH_HOST_IF,
    WAYLAND_RUN_DIR, beside, cgroup_write, gsi_bootstrap_cmd, host_selinux_mode,
    input_port_associations_xml, kmsg, libc, mount, own_domain, phase, route_stdio_through_pipe,
    unshare)
from sandbox import core
from sandbox.hals import gpu_mode_or_exit, stage_hals, stage_virtual_device, stage_aurora, stage_gapps, stage_desktop_bridge, stage_host_delay, stage_software_rro, vendor_manifest_xml, bluetooth_armed, stage_camera, network_location_armed, stage_sensors
from sandbox.rootfs import build_root_and_pivot, setup_net_core_sysctls, harden_proc_sys, cap_pid_namespace_pid_max
from sandbox.rootfs import withheld_device_majors, device_allowlist, allowlist_admits
from sandbox.rootfs import DeviceFilterMap, DEVICE_MAP_KEY, FENCE_MINORS
from sandbox.rootfs import coldboot_primer_spec, start_fence_or_kill, open_fence_registry, fence_wait_step, relay_step
from sandbox.rootfs import open_label_service, host_boot_id
from sandbox.rootfs import connect_input_supervisor, install_uinput_filter, start_input_units, install_handle_filter
from sandbox.rootfs import check_data_release_marker, migrate_keystore_for_keymint_persistence
from sandbox.rootfs import sync_release_switch_marker
from sandbox.selinux_labels import label_host_binaries, check_policy_load, write_policy_refusal

_MY_SUPERVISOR_PID = None
_CGROUP_ROOT = None
_APEX_OVERRIDE_PREPARED = False
VBMETA_LOOP_FILE = ("/run/rhizo-vbmeta-loop" if SANDBOX_ID == 0
                    else f"/run/rhizo-vbmeta-loop-{SANDBOX_ID}")

MARKER_LAUNCH_START_TEXT = "RHIZO_MARKER launch_start sandbox=%d" % SANDBOX_ID
MARKER_BOOT_COMPLETED_TEXT = "RHIZO_MARKER sys.boot_completed=1 sandbox=%d" % SANDBOX_ID
MARKER_LAUNCH_START = re.compile(re.escape(MARKER_LAUNCH_START_TEXT.encode()) + rb"(?![0-9])")
MARKER_BOOT_COMPLETED = re.compile(re.escape(MARKER_BOOT_COMPLETED_TEXT.encode()) + rb"(?![0-9])")


def detach_own_vbmeta_loop():
    """detach the vbmeta.img loop device in VBMETA_LOOP_FILE"""
    release_own_vbmeta_loop(who="vbmeta.img")




HOST_PRIMER_SRC = r"""
import ctypes, errno, glob, os, pwd, re, signal, subprocess, sys, time
# host primer for the kernel domain exit and the enforce flip
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM, signal.SIGUSR1})
def ctx():
    try:
        with open("/proc/self/attr/current") as f: return f.read().strip("\0").strip()
    except OSError: return ""

def log(m):
    try:
        os.makedirs("@RHIZO_LOG_DIR@", exist_ok=True)
        with open("@RHIZO_LOG_DIR@/rhizo-primer.log","a") as f:
            f.write("%.3f %s\n" % (time.time(), m)); f.flush()
    except OSError: pass
    try:
        with open("/dev/kmsg","w") as f: f.write("<5>L3-primer: %s\n" % m)
    except OSError: pass

# return the argument after flag, or exit 2
def _primer_arg(flag):
    try:
        return sys.argv[sys.argv.index(flag) + 1]
    except (ValueError, IndexError):
        log("%s <value> is missing" % flag)
        sys.exit(2)

_RUN_ROOT = _primer_arg("--run-root")
_AFTER_FLIP = "--after-flip" in sys.argv
_INIT_PID_FILE = "" if _AFTER_FLIP else _primer_arg("--init-pid-file")
_SANDBOX_ID_ARG = _primer_arg("--sandbox-id")
if not _SANDBOX_ID_ARG.isdigit():
    log("--sandbox-id %r is not a number" % _SANDBOX_ID_ARG)
    sys.exit(2)
_SANDBOX_ID = int(_SANDBOX_ID_ARG)
_NO_SANDBOX = "--no-sandbox" in sys.argv
_CALLER_UNIT = sys.argv[sys.argv.index("--caller-unit") + 1] \
    if "--caller-unit" in sys.argv[:-1] else ""

# --- relabel scope guard, identical in sandbox/selinux_labels.py and the host primer
import re as _guard_re


def _mount_serving(path, mountinfo):
    best = None
    for line in mountinfo.splitlines():
        f = line.split()
        if len(f) < 6:
            continue
        dev, root, mnt = f[2], f[3].replace("\\040", " "), f[4].replace("\\040", " ")
        if path == mnt or path.startswith(mnt.rstrip("/") + "/"):
            if best is None or len(mnt) > len(best[0]):
                best = (mnt, root, dev)
    return best


IMAGE_ROOTS = ("/var/lib/rhizo/prepared/",)


def _gsi_backed(path, mountinfo, gsi):
    if path == gsi or path.startswith(gsi + "/"):
        return True
    if path.startswith(IMAGE_ROOTS):
        return True
    served = _mount_serving(path, mountinfo)
    if served is None:
        return False
    if served[1].rstrip("/").startswith(tuple(r.rstrip("/") for r in IMAGE_ROOTS)):
        return True
    home = _mount_serving(gsi, mountinfo)
    if home is None:
        return False
    gsi_root = (home[1].rstrip("/") + "/" + gsi[len(home[0]):].lstrip("/")).rstrip("/") or "/"
    under = served[1] == gsi_root or served[1].startswith(gsi_root + "/")
    if gsi_root == "/":
        return served[2] == home[2]
    if home[0] != "/":
        return under and served[2] == home[2]
    return under




def inode_is_ours(path):
    probe = (os.path.dirname(path) or ".") if os.path.islink(path) else path
    try:
        if os.statvfs(probe).f_flag & os.ST_RDONLY:
            return False
    except OSError:
        return False
    m = _guard_re.match(r"(/proc/\d+)/root(/.*)?$", probe)
    table = (m.group(1) + "/mountinfo") if m else "/proc/self/mountinfo"
    inner = os.path.normpath(m.group(2) or "/") if m else os.path.normpath(probe)
    try:
        mountinfo = open(table).read()
    except OSError:
        return False
    gsi = os.environ.get("RHIZO_GSI", "/srv/rhizo/gsi_system").rstrip("/")
    return not _gsi_backed(inner, mountinfo, gsi)


def label_write(path, want, follow_symlinks=True, skipped=None):
    if not inode_is_ours(path):
        if skipped is not None:
            skipped.append(path)
        return False
    os.setxattr(path, "security.selinux", want, follow_symlinks=follow_symlinks)
    return True
# --- end relabel scope guard


_STAGED_ROOTS = [
    ("/system_ext/", _RUN_ROOT + "/system_ext_flat/"),
    ("/product/", _RUN_ROOT + "/product_flat/"),
    ("/system/", _RUN_ROOT + "/system_flat/"),
    ("/vendor/", _RUN_ROOT + "/vendor/"),
]
_UPPER_TREES = [(_RUN_ROOT + "/system_flat", _RUN_ROOT + "/system_upper"),
                (_RUN_ROOT + "/system_ext_flat", _RUN_ROOT + "/system_ext_upper"),
                (_RUN_ROOT + "/product_flat", _RUN_ROOT + "/product_upper")]


# map each staged flat-tree path to the upper-tree file
def staged_uppers():
    found = {}
    for _flat, _upper in _UPPER_TREES:
        for _dp, _dn, _fn in os.walk(_upper):
            for _n in _fn:
                _p = os.path.join(_dp, _n)
                if os.path.isfile(_p) and not os.path.islink(_p):
                    found[_flat + _p[len(_upper):]] = _p
    return found


def relabel_staged_files():
    _entries = []
    _srcs = ["@RHIZO_CACHE_DIR@/plat_file_contexts",
             "@RHIZO_CACHE_DIR@/system_ext_file_contexts",
             "@RHIZO_CACHE_DIR@/product_file_contexts",
             _RUN_ROOT + "/vendor/etc/selinux/vendor_file_contexts"]
    for _fc in _srcs:
        try:
            _lines = open(_fc, errors="replace").read().splitlines()
        except OSError as _e:
            log("failed to read %s (%s)" % (_fc, _e))
            continue
        for _ln in _lines:
            _ln = _ln.strip()
            if not _ln or _ln.startswith("#"):
                continue
            _parts = _ln.split()
            if len(_parts) < 2:
                continue
            _pat, _lbl = _parts[0], _parts[-1]
            _m = re.search(r"[.\[\](){}*+?|^$\\]", _pat)
            _stem = len(_pat) if _m is None else _m.start()
            try:
                _rx = re.compile(_pat + r"\Z")
            except re.error:
                continue
            _entries.append((_rx, _stem, _lbl))
    if not _entries:
        log("0 file_contexts entries loaded")
        return

    def _expected(_sp):
        _best = None
        for _i, (_rx, _stem, _lbl) in enumerate(_entries):
            if _rx.match(_sp):
                if _best is None or (_stem, _i) > _best[0]:
                    _best = ((_stem, _i), _lbl)
        return _best[1] if _best else None

    _named = 0
    _failed = []
    _foreign = []
    _retry = []
    _uppers = staged_uppers()
    for _rx, _stem, _lbl in _entries:
        _pat = _rx.pattern[:-2]
        _lit = re.sub(r"\\(.)", r"\1", _pat)
        if re.search(r"[.\[\](){}*+?|^$]", _lit):
            continue
        _host = None
        for _hroot2, _sroot2 in ((_RUN_ROOT + "/vendor", "/vendor"),
                                 (_RUN_ROOT + "/system_flat", "/system"),
                                 (_RUN_ROOT + "/system_ext_flat", "/system_ext"),
                                 (_RUN_ROOT + "/product_flat", "/product")):
            if _lit.startswith(_sroot2 + "/"):
                _host = _hroot2 + _lit[len(_sroot2):]
                _host = _uppers.get(_host, _host)
                break
        if _host is None or not os.path.lexists(_host):
            continue
        _lnk = os.path.islink(_host)
        try:
            _cur = os.getxattr(_host, "security.selinux",
                               follow_symlinks=not _lnk).decode(
                                   errors="replace").rstrip("\x00")
            if _cur == _lbl:
                continue
            if label_write(_host, _lbl.encode() + b"\x00",
                           follow_symlinks=not _lnk, skipped=_foreign):
                _named += 1
        except OSError as _e:
            if _e.errno == errno.EOPNOTSUPP:
                _retry.append((_host, _lit, _lbl, not _lnk))
            elif _e.errno != 30 and len(_failed) < 12:
                _failed.append("%s -> %s (%s)" % (_lit, _lbl, _e))

    _applied = 0
    _correct = 0
    _norule = 0
    _pairs = [(_RUN_ROOT + "/system_apex_flat", "/system/apex"),
              (_RUN_ROOT + "/system_flat", "/system"),
              (_RUN_ROOT + "/system_ext_flat", "/system_ext"),
              (_RUN_ROOT + "/product_flat", "/product"),
              (_RUN_ROOT + "/vendor", "/vendor")]
    _todo = []
    for _hroot, _sroot in _pairs:
        if os.path.isdir(_hroot):
            _todo.append((_hroot, _sroot))
        for _fp, _up in sorted(_uppers.items()):
            if _fp.startswith(_hroot + "/"):
                _todo.append((_up, _sroot + _fp[len(_hroot):]))
        for _dp, _dn, _fn in os.walk(_hroot):
            for _n in _dn + _fn:
                _p = os.path.join(_dp, _n)
                if _p in _uppers:
                    continue
                _lnk = os.path.islink(_p)
                if not _lnk and os.path.isfile(_p):
                    try:
                        if os.lstat(_p).st_size == 0:
                            continue
                    except OSError:
                        continue
                _todo.append((_p, _sroot + _p[len(_hroot):]))
    for _p, _sp in _todo:
        _want = _expected(_sp)
        if _want is None:
            _norule += 1
            continue
        try:
            _cur = os.getxattr(_p, "security.selinux",
                               follow_symlinks=False).decode(
                                   errors="replace").rstrip("\x00")
        except OSError:
            _cur = ""
        if _cur == _want:
            _correct += 1
            continue
        try:
            if label_write(_p, _want.encode() + b"\x00",
                           follow_symlinks=False, skipped=_foreign):
                _applied += 1
        except OSError as _e:
            if _e.errno == 30:
                _correct += 1
                continue
            if _e.errno == errno.EOPNOTSUPP:
                _retry.append((_p, _sp, _want, False))
                continue
            if len(_failed) < 12:
                _failed.append("%s -> %s (%s)" % (_sp, _want, _e))
    _waited, _late = time.time(), 0
    while _retry and time.time() - _waited < 10:
        time.sleep(0.05)
        _left = []
        for _p, _sp, _want, _follow in _retry:
            try:
                if label_write(_p, _want.encode() + b"\x00", follow_symlinks=_follow, skipped=_foreign):
                    _late += 1
            except OSError as _e:
                if _e.errno == errno.EOPNOTSUPP:
                    _left.append((_p, _sp, _want, _follow))
                elif len(_failed) < 12:
                    _failed.append("%s -> %s (%s)" % (_sp, _want, _e))
        _retry = _left
    for _p, _sp, _want, _follow in _retry[:max(0, 12 - len(_failed))]:
        _failed.append("%s -> %s (EOPNOTSUPP after 10s)" % (_sp, _want))
    log("staged-file relabel by_name=%d relabeled=%d after_retry=%d correct=%d no_rule=%d gsi_backed=%d "
        "uppers=%d%s%s"
        % (_named, _applied, _late, _correct, _norule, len(_foreign), len(_uppers),
           (" first_gsi_backed=" + "; ".join(_foreign[:4])) if _foreign else "",
           (" failures=" + "; ".join(_failed)) if _failed else ""))
    _DB_LABELS = {
        "vendor_file_contexts":     "u:object_r:file_contexts_file:s0",
        "vendor_service_contexts":  "u:object_r:vendor_service_contexts_file:s0",
        "vendor_property_contexts": "u:object_r:property_contexts_file:s0",
        "vendor_seapp_contexts":    "u:object_r:seapp_contexts_file:s0",
        "vendor_hwservice_contexts": "u:object_r:hwservice_contexts_file:s0",
    }
    for _db, _lbl in _DB_LABELS.items():
        _p = _RUN_ROOT + "/vendor/etc/selinux/" + _db
        try:
            _cur = os.getxattr(_p, "security.selinux").decode(
                errors="replace").rstrip("\x00")
            if _cur != _lbl and not label_write(_p, _lbl.encode() + b"\x00"):
                log("skipped GSI-backed %s" % _db)
                continue
            _got = os.getxattr(_p, "security.selinux").decode(
                errors="replace").rstrip("\x00")
            log("%s was=%s got=%s" % (_db, _cur, _got))
        except OSError as _e:
            log("failed to label %s (%s)" % (_db, _e))


def relabel_flat_trees():
    _FLAT_LINK_LABEL = b"u:object_r:system_file:s0\x00"
    try:
        _relabeled = 0
        _dirs_relabeled = 0
        _relabel_failed = []
        _flat_foreign = []
        _uppers = staged_uppers()
        _fbase = _RUN_ROOT
        for _froot in sorted(os.path.join(_fbase, _d) for _d in os.listdir(_fbase)
                             if _d.endswith("_flat") and os.path.isdir(os.path.join(_fbase, _d))):
            for _fdir, _fsubs, _ffiles in os.walk(_froot):
                if _fdir != _froot:
                    try:
                        _dcur = os.getxattr(_fdir, "security.selinux", follow_symlinks=False)
                    except OSError:
                        _dcur = b""
                    if _dcur.decode(errors="replace").rstrip("\x00") == "u:object_r:tmpfs:s0":
                        try:
                            if label_write(_fdir, _FLAT_LINK_LABEL,
                                           follow_symlinks=False,
                                           skipped=_flat_foreign):
                                _dirs_relabeled += 1
                        except OSError as _e:
                            if len(_relabel_failed) < 5:
                                _relabel_failed.append("%s (%s)" % (_fdir, _e))
                for _fn in _ffiles + _fsubs:
                    _fp = os.path.join(_fdir, _fn)
                    _fp = _uppers.get(_fp, _fp)
                    if not (os.path.islink(_fp) or os.path.isfile(_fp)):
                        continue
                    try:
                        _cur = os.getxattr(_fp, "security.selinux", follow_symlinks=False)
                    except OSError:
                        _cur = b""
                    if _cur.decode(errors="replace").rstrip("\x00") != "u:object_r:tmpfs:s0":
                        continue
                    try:
                        if label_write(_fp, _FLAT_LINK_LABEL,
                                       follow_symlinks=False,
                                       skipped=_flat_foreign):
                            _relabeled += 1
                    except OSError as _e:
                        if len(_relabel_failed) < 5:
                            _relabel_failed.append("%s (%s)" % (_fp, _e))
        log("flat-tree relabel tmpfs->system_file symlinks=%d dirs=%d gsi_backed=%d%s"
            % (_relabeled, _dirs_relabeled, len(_flat_foreign),
               (" failures=" + "; ".join(_relabel_failed)) if _relabel_failed else ""))
    except Exception as _e:
        log("flat-tree relabel failed (%s)" % _e)


if "--relabel-flat" in sys.argv:
    relabel_staged_files()
    relabel_flat_trees()
    sys.exit(0)


_MARKER_LAUNCH_START = re.compile(
    rb"RHIZO_MARKER launch_start sandbox=%d(?![0-9])" % _SANDBOX_ID)
_MARKER_BOOT_COMPLETED = re.compile(
    rb"RHIZO_MARKER sys\.boot_completed=1 sandbox=%d(?![0-9])" % _SANDBOX_ID)

# /dev/kmsg reader for the launch_start and boot_completed markers
class _KmsgWatch:
    def __init__(self, read=None, path="/dev/kmsg", batch=16384):
        self._read, self._path, self._batch = read, path, batch
        self._fd = None
        self.anchored = False
        self._completed = False
        self.done = False

    def _next(self):
        if self._read is not None:
            try:
                return self._read(65536) or None
            except BlockingIOError:
                return None
        if self._fd is None:
            self._fd = os.open(self._path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        while True:
            try:
                return os.read(self._fd, 65536) or None
            except BlockingIOError:
                return None
            except OSError as e:
                if e.errno != errno.EPIPE:
                    raise

    def seen(self):
        if self.done:
            return True
        for _ in range(self._batch):
            rec = self._next()
            if rec is None:
                self.done = self._completed
                break
            starts = [m.end() for m in _MARKER_LAUNCH_START.finditer(rec)]
            if starts:
                self.anchored, self._completed = True, False
            if self.anchored and _MARKER_BOOT_COMPLETED.search(rec, starts[-1] if starts else 0):
                self._completed = True
        return self.done

_boot_watch = _KmsgWatch()

def _boot_marker_seen():
    try:
        return _boot_watch.seen()
    except OSError as e:
        log("failed to read /dev/kmsg (%s)" % e)
        return False


# grant com.rhizo.networklocation the location permissions
def _grant_network_location(client, sock, at_s=(0, 10, 30, 60, 120, 180)):
    perms = ("ACCESS_COARSE_LOCATION", "ACCESS_FINE_LOCATION", "ACCESS_BACKGROUND_LOCATION")
    script = ("export PATH=/system/bin; p=com.rhizo.networklocation; d=$(dumpsys package $p); "
              "for x in %s; do l=$(echo \"$d\" | grep -m1 \" android.permission.$x: granted=\"); "
              "case \"$l\" in '') pm grant $p android.permission.$x >/dev/null 2>&1 "
              "&& s=granted-now:unlisted || s=no-line;; *granted=true*) s=granted;; "
              "*USER_SET*|*USER_FIXED*) s=user-set;; *POLICY_FIXED*) s=policy-fixed;; "
              "*) pm grant $p android.permission.$x >/dev/null 2>&1 && s=granted-now || s=grant-failed:$?;; "
              "esac; echo nl:$x=$s; done" % " ".join(perms))
    t0 = time.time()
    for i, at in enumerate(at_s):
        time.sleep(max(0.0, t0 + at - time.time()))
        seen = {}
        try:
            r = subprocess.run(["/usr/bin/python3", client, sock, "60", script],
                               timeout=120, check=False, capture_output=True, text=True)
            seen = dict(w[3:].split("=", 1) for w in (r.stdout or "").split() if w.startswith("nl:") and "=" in w)
            err = "rc=%s err=%r" % (r.returncode, (r.stderr or "").strip()[-160:])
        except Exception as e:
            err = repr(e)
        listed = (" ".join("%s=%s" % (x.split("_")[1], seen.get(x, "?")) for x in perms) if seen
                else "0 nl: lines (%s)" % err)
        if all(seen.get(x) in ("granted", "user-set", "policy-fixed") for x in perms):
            log("network location grants at +%ds %s, settled" % (at, listed))
            return True
        log("network location grants at +%ds %s, %s" % (
            at, listed, "retry at +%ds" % at_s[i + 1] if i + 1 < len(at_s) else "not settled after the last retry"))
    return False


# start rhizo-display-pool.service and write the Android settings
def after_flip_jobs():
    _pw_deadline = time.time() + 300
    _pw_seen = False
    if os.environ.get("RHIZO_POLICY_ONLY") == "1":
        log("skipped the display pool wait with RHIZO_POLICY_ONLY=1")
    else:
        while time.time() < _pw_deadline:
            if _boot_marker_seen():
                _pw_seen = True
                break
            time.sleep(0.5)
    if _SANDBOX_ID != 0:
        log("skipped the display pool prime for instance %d" % _SANDBOX_ID)
    elif _pw_seen:
        try:
            subprocess.run(["systemctl", "reset-failed", "rhizo-display-pool.service", "rhizo-display-pool.path"],
                           timeout=15, check=False, capture_output=True)
            subprocess.run(["systemctl", "restart", "rhizo-display-pool.path"],
                           timeout=15, check=False, capture_output=True)
            _pw = subprocess.run(["systemctl", "start", "--no-block", "rhizo-display-pool.service"],
                                 timeout=15, check=False, capture_output=True, text=True)
            log("started rhizo-display-pool.service rc=%s%s" %
                (_pw.returncode, (" err=%r" % _pw.stderr[:200]) if _pw.returncode != 0 else ""))
        except Exception as e:
            log("failed to start rhizo-display-pool.service (%r)" % e)
    else:
        log("skipped the display pool prime with no sys.boot_completed marker in 300s")

    _so_ms = "@RHIZO_SCREEN_OFF_MS@"
    _so_client = "@RHIZO_PROBE_CLIENT@"
    _so_sock = _RUN_ROOT + "/data/local/tmp/rhizo-probe.sock"
    if not _pw_seen:
        if _so_ms not in ("", "0"):
            log("skipped screen_off_timeout with no boot_completed marker")
    elif _so_ms in ("", "0"):
        pass
    elif not os.path.exists(_so_client):
        log("skipped screen_off_timeout with no probe client at %s" % _so_client)
    else:
        try:
            _so = subprocess.run(
                ["/usr/bin/python3", _so_client, _so_sock, "30",
                 "export PATH=/system/bin:/system/xbin:/vendor/bin; "
                 "settings put system screen_off_timeout %s" % _so_ms],
                timeout=90, check=False, capture_output=True, text=True)
            _rb = subprocess.run(
                ["/usr/bin/python3", _so_client, _so_sock, "30",
                 "export PATH=/system/bin:/system/xbin:/vendor/bin; "
                 "settings get system screen_off_timeout"],
                timeout=90, check=False, capture_output=True, text=True)
            _got = (_rb.stdout or "").strip().splitlines()
            _got = _got[-1].strip() if _got else ""
            if _got == _so_ms:
                log("set screen_off_timeout to %sms" % _so_ms)
            else:
                log("screen_off_timeout expected=%s got=%r put_rc=%s put_err=%r" % (_so_ms, _got, _so.returncode,
                                                                                    (_so.stderr or "")[:200]))
        except Exception as e:
            log("failed to set screen_off_timeout (%r)" % e)
    if _pw_seen and os.path.exists(_so_client) and "@RHIZO_FREEFORM@" == "1":
        try:
            subprocess.run(["/usr/bin/python3", _so_client, _so_sock, "30",
                            "export PATH=/system/bin; settings put global force_resizable_activities 1; "
                            "settings put global enable_freeform_support 1"],
                           timeout=90, check=False, capture_output=True, text=True)
        except Exception as e:
            log("failed to set the freeform settings (%r)" % e)
    if _pw_seen and os.path.exists(_so_client):
        try:
            _dn = subprocess.run(
                ["/usr/bin/python3", _so_client, _so_sock, "30",
                 "export PATH=/system/bin:/system/xbin:/vendor/bin; "
                 "[ \"$(settings get global device_name)\" = 'AOSP on x86_64' ] "
                 "&& settings put global device_name \"$(getprop ro.product.model)\" && echo renamed"],
                timeout=90, check=False, capture_output=True, text=True)
            if "renamed" in (_dn.stdout or ""):
                log("set device_name to ro.product.model")
        except Exception as e:
            log("failed to set device_name (%r)" % e)
    if _pw_seen and os.path.exists(_so_client) and "@RHIZO_BLUETOOTH_ARMED@" == "0":
        try:
            _bt = subprocess.run(
                ["/usr/bin/python3", _so_client, _so_sock, "30",
                 "export PATH=/system/bin; [ \"$(settings get global bluetooth_on)\" = 0 ] "
                 "|| { settings put global bluetooth_on 0 && echo turned-off; }"],
                timeout=90, check=False, capture_output=True, text=True)
            if "turned-off" in (_bt.stdout or ""):
                log("set bluetooth_on to 0")
        except Exception as e:
            log("failed to set bluetooth_on (%r)" % e)
    if _pw_seen and os.path.exists(_so_client) and "@RHIZO_NETWORK_LOCATION@" == "1":
        try:
            _nl_pid = os.fork()
        except OSError as e:
            _nl_pid = -1
            log("fork failed (%s)" % e)
        if _nl_pid == 0:
            try:
                _nl_null = os.open(os.devnull, os.O_RDWR)
                for _fd in (0, 1, 2):
                    os.dup2(_nl_null, _fd)
                _grant_network_location(_so_client, _so_sock)
            except Exception as e:
                log("failed to grant the network location permissions (%r)" % e)
            finally:
                os._exit(0)


if _AFTER_FLIP:
    after_flip_jobs()
    sys.exit(0)


try:
    os.makedirs("/sys/fs/cgroup/rhizo-host", exist_ok=True)
    with open("/sys/fs/cgroup/rhizo-host/cgroup.procs", "w") as _f:
        _f.write(str(os.getpid()))
    log("moved the primer to /sys/fs/cgroup/rhizo-host")
except OSError as e:
    log("failed to move the primer to /sys/fs/cgroup/rhizo-host (%s)" % e)

_first_boot = ctx() != "u:r:rhizo_host:s0"
if _first_boot:
    log("ctx=%r before policy load" % ctx())
    deadline = time.time() + 180
    while time.time() < deadline:
        c = ctx()
        if c.startswith("u:r:") and c != "u:r:rhizo_host:s0":
            log("policy loaded ctx=%r, exec --policy-loaded" % c)
            try:
                os.execv(sys.executable, [sys.executable, __file__] + sys.argv[1:] + ["--policy-loaded"])
            except OSError as e:
                log("execv failed (%s)" % e); sys.exit(1)
        if c == "u:r:rhizo_host:s0": break
        time.sleep(0.05)
    else:
        log("no policy load in 180s"); sys.exit(1)

log("primer ctx=%s" % ctx())

# wait for getxattr on path to return a label other than unlabeled
def _wait_labelable(path, limit=10):
    t0 = time.time()
    while time.time() - t0 < limit:
        try:
            cur = os.getxattr(path, "security.selinux")
            if cur.rstrip(b"\0") != b"u:object_r:unlabeled:s0":
                if not label_write(path, cur):
                    return "label_write returned False"
                return "ok after %.2fs" % (time.time() - t0)
        except OSError as e:
            if e.errno != errno.EOPNOTSUPP:
                return "<%s>" % e.strerror
        time.sleep(0.02)
    return "timeout after %ds" % limit


if "--policy-loaded" in sys.argv and not _NO_SANDBOX:
    log("_wait_labelable returned %s" % _wait_labelable(_RUN_ROOT))
    relabel_staged_files()
if "--relabel-only" in sys.argv:
    sys.exit(0)

HOST_KMSG = "/dev/kmsg"
HOST_KMSG_CONTEXT = "u:object_r:rhizo_host_kmsg_device:s0"


def relabel_host_kmsg():
    def label():
        return os.getxattr(HOST_KMSG, "security.selinux").decode().rstrip("\0")
    try:
        was = label()
    except OSError as e:
        log("failed to read the label of %s (%s)" % (HOST_KMSG, e)); return
    if was == HOST_KMSG_CONTEXT:
        log("/dev/kmsg is already %s" % was); return
    try:
        if not label_write(HOST_KMSG, (HOST_KMSG_CONTEXT + "\0").encode()):
            log("label_write returned False for %s, label is %s" % (HOST_KMSG, was))
            return
        now = label()
    except OSError as e:
        log("failed to label /dev/kmsg (%s), label is %s" % (e, was))
        return
    log("relabeled /dev/kmsg %s -> %s%s" % (was, now, "" if now == HOST_KMSG_CONTEXT
                                         else ", not the written label"))


relabel_host_kmsg()

HOST_INPUT_NODES = (("/dev/cuse", "u:object_r:rhizo_cuse_host_device:s0"),
                    ("/dev/uhid", "u:object_r:rhizo_uhid_host_device:s0"))


def relabel_host_input_nodes():
    for path, want in HOST_INPUT_NODES:
        try:
            was = os.getxattr(path, "security.selinux").decode().rstrip("\0")
        except FileNotFoundError:
            log("%s is absent" % path); continue
        except OSError as e:
            log("failed to read the label of %s (%s)" % (path, e)); continue
        if was == want:
            log("%s is already %s" % (path, was)); continue
        try:
            if not label_write(path, (want + "\0").encode()):
                log("label_write returned False for %s, label is %s" % (path, was))
                continue
            now = os.getxattr(path, "security.selinux").decode().rstrip("\0")
        except OSError as e:
            log("failed to label %s (%s), label is %s" % (path, e, was))
            continue
        log("relabeled %s %s -> %s%s" % (path, was, now, "" if now == want
                                                     else ", not the written label"))


relabel_host_input_nodes()

# return /proc/1/attr/current, or "" on OSError
def _pid1_ctx():
    try:
        with open("/proc/1/attr/current") as f:
            return f.read().strip("\0").strip()
    except OSError:
        return ""


# return the system.slice services with a process in the kernel domain
def _units_still_kernel(cg_root="/sys/fs/cgroup/system.slice", proc="/proc"):
    def _members(path):
        try:
            with open(os.path.join(path, "cgroup.procs")) as f:
                return f.read().split()
        except OSError:
            return []
    stuck = {}
    for dirpath, dirnames, _files in os.walk(cg_root):
        if not dirpath.endswith(".service"):
            continue
        children = sorted(dirnames)
        dirnames[:] = []
        unit = os.path.basename(dirpath)
        pids = _members(dirpath)
        if not pids and not unit.startswith("androidd"):
            for c in children:
                pids += _members(os.path.join(dirpath, c))
        for e in pids:
            try:
                with open("%s/%s/attr/current" % (proc, e)) as f:
                    c = f.read().strip("\0").strip()
            except OSError:
                continue
            if c in ("kernel", "u:r:kernel:s0"):
                stuck.setdefault(unit, e)
                break
    return stuck


_SELF_UNITS = ("androidd.service", "rhizo-policy.service")
_SELF_FAMILIES = ("androidd@", "rhizo-host-primer.")
_SESSION_UNITS = ("gdm.service", "gdm3.service", "lightdm.service", "sddm.service",
                  "greetd.service", "plasmalogin.service")
_SESSION_FAMILIES = ("user@", "user-runtime-dir@", "session-")


def _restart_class(unit, caller_unit="", dm_unit=""):
    if unit == caller_unit or unit in _SELF_UNITS or unit.startswith(_SELF_FAMILIES):
        return "self"
    if unit == dm_unit or unit in _SESSION_UNITS or unit.startswith(_SESSION_FAMILIES):
        return "session"
    return "restart"


# return the units in stuck whose _restart_class is not self
def _leftovers(stuck, caller_unit="", dm_unit=""):
    return sorted(u for u in stuck if _restart_class(u, caller_unit, dm_unit) != "self")


# return the Id of display-manager.service
def _display_manager_unit():
    try:
        r = subprocess.run(["systemctl", "show", "-p", "Id", "--value", "display-manager.service"],
                           timeout=10, check=False, capture_output=True, text=True)
    except (OSError, subprocess.TimeoutExpired) as e:
        log("failed to resolve display-manager.service (%s)" % e)
        return ""
    dm = r.stdout.strip()
    return dm if dm.endswith(".service") and dm != "display-manager.service" else ""
# return /proc/<_init_pid>/root + rel
def _ns_path(rel):
    if _init_pid is None:
        raise _NoSandboxInit("_init_pid is None for %s" % rel)
    return "/proc/%d/root%s" % (_init_pid, rel)

# exception for _ns_path with _init_pid None
class _NoSandboxInit(Exception):
    pass

# return why pid is not the sandbox init, or None
def _init_pid_refusal(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            argv = [a for a in f.read().split(b"\0") if a]
    except OSError as e:
        return "failed to read cmdline (%s)" % e
    if not argv:
        return "cmdline is empty"
    if os.path.basename(argv[0].decode(errors="replace")) != "init":
        return "argv[0] is %r, not init" % argv[0].decode(errors="replace")
    if b"second_stage" not in argv:
        return "second_stage is not in argv %r" % [a.decode(errors="replace") for a in argv]
    try:
        cand = os.stat("/proc/%d/root" % pid)
        host = os.stat("/proc/1/root")
    except OSError as e:
        return "failed to stat root (%s)" % e
    if (cand.st_dev, cand.st_ino) == (host.st_dev, host.st_ino):
        return "root is the root of /proc/1"
    return None

_init_pid = None
_refused = {}
if _NO_SANDBOX:
    log("skipped the sandbox init wait and the /proc/<pid>/root relabels with --no-sandbox")
else:
    _deadline = time.time() + 60
    while time.time() < _deadline:
        try:
            with open(_INIT_PID_FILE) as f: _cand = int(f.read().strip())
        except (OSError, ValueError):
            time.sleep(0.1)
            continue
        _why = _init_pid_refusal(_cand)
        if _why is None:
            _init_pid = _cand
            break
        if _refused.get(_cand) != _why:
            _refused[_cand] = _why
            log("pid %d is not the sandbox init (%s)" % (_cand, _why))
        time.sleep(0.1)
if _init_pid is None:
    log("no sandbox init in %s after 60s, skipped the /proc/<pid>/root relabels (refusals %s)"
        % (_INIT_PID_FILE, _refused))
else:
    log("sandbox init pid=%d" % _init_pid)
    _RELABEL_SPEC = [
        ("/sys/fs/selinux/enforce",          "u:object_r:rhizo_enforce_shadow:s0"),
        ("/vendor/manifest.xml",             "u:object_r:vendor_configs_file:s0"),
        ("/vendor/compatibility_matrix.xml", "u:object_r:vendor_configs_file:s0"),
        ("/system/apex",                     "u:object_r:system_file:s0"),
        ("/system_ext/overlay",              "u:object_r:vendor_overlay_file:s0"),
        ("/product/etc/permissions",         "u:object_r:system_file:s0"),
        ("/dev/dri/renderD128",              "u:object_r:gpu_device:s0"),
        ("/dev/dri/card0",                   "u:object_r:gpu_device:s0"),
        ("/dev/tun",                         "u:object_r:tun_device:s0"),
        ("/dev/uinput",                      "u:object_r:uhid_device:s0"),
        ("/dev/uhid",                        "u:object_r:uhid_device:s0"),
        ("/sys/power/state",                 "u:object_r:rhizo_power_shadow:s0"),
        ("/sys/kernel/wakeup_reasons",                    "u:object_r:rhizo_wakeup_reasons_shadow:s0"),
        ("/sys/kernel/wakeup_reasons/last_resume_reason", "u:object_r:rhizo_wakeup_reasons_shadow:s0"),
        ("/sys/kernel/wakeup_reasons/last_suspend_time",  "u:object_r:rhizo_wakeup_reasons_shadow:s0"),
        ("/",                                "u:object_r:rootfs:s0"),
        ("/etc",                             "u:object_r:rootfs:s0"),
        ("/sdcard",                          "u:object_r:rootfs:s0"),
        ("/bin",                             "u:object_r:rootfs:s0"),
        ("/proc",                            "u:object_r:rootfs:s0"),
        ("/dev/ptmx",                        "u:object_r:ptmx_device:s0"),
        ("/adb_keys",                        "u:object_r:system_file:s0"),
        ("/dev/rhizo_iio",                   "u:object_r:rhizo_iio_dir:s0"),
    ]
    _RELABEL_SPEC += [tuple(_e.split("=", 1)) for _e in "@RHIZO_COLDBOOT_RELABEL@".split(",")
                      if "=" in _e]
    _dri_dir = _ns_path("/dev/dri")
    _RELABEL_SPEC += [("/dev/dri/" + _n, "u:object_r:gpu_device:s0")
                      for _n in (sorted(os.listdir(_dri_dir)) if os.path.isdir(_dri_dir) else ())
                      if "/dev/dri/" + _n not in dict(_RELABEL_SPEC)]
    _spec_foreign = []
    for _rel, _want in _RELABEL_SPEC:
        _p = _ns_path(_rel)
        if not os.path.lexists(_p):
            log("skipped absent %s" % _rel); continue
        _lnk = os.path.islink(_p)
        try:
            _cur = os.getxattr(_p, "security.selinux",
                               follow_symlinks=not _lnk).decode().rstrip("\0")
            if _cur == _want:
                log("%s is already %s" % (_rel, _want))
                continue
        except OSError:
            pass
        try:
            if not label_write(_p, (_want + "\0").encode(),
                               follow_symlinks=not _lnk, skipped=_spec_foreign):
                log("skipped GSI-backed %s" % _rel); continue
        except OSError as e:
            log("failed to relabel %s (%s)" % (_rel, e)); continue
        try:
            _got = os.getxattr(_p, "security.selinux",
                               follow_symlinks=not _lnk).decode().rstrip("\0")
        except OSError as e:
            _got = "<unreadable:%s>" % e.errno
        if _got == _want:
            log("relabeled %s -> %s" % (_rel, _want))
        else:
            log("%s expected=%s got=%s" % (_rel, _want, _got))
    log("relabel spec gsi_backed=%d %s"
        % (len(_spec_foreign), _spec_foreign[:4]))
    relabel_staged_files()
try:
    subprocess.Popen(["/bin/sh", "@RHIZO_PAYLOAD_DIR@/rhizo-avc-capture.sh", "@RHIZO_LOG_DIR@/rhizo-avc.log"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL, start_new_session=True)
    log("started rhizo-avc-capture.sh -> @RHIZO_LOG_DIR@/rhizo-avc.log")
except Exception as e:
    log("failed to start rhizo-avc-capture.sh (%r)" % e)
_pid1_before = _pid1_ctx()
if _pid1_before != "u:r:rhizo_host:s0":
    r = subprocess.run(["systemctl", "daemon-reexec"], timeout=60, check=False,
                       capture_output=True, text=True)
    log("pid1 ctx=%s, systemctl daemon-reexec rc=%s err=%r"
        % (_pid1_before, r.returncode, (r.stderr or "")[:200]))
    _deadline = time.time() + 30
    _p1 = ""
    while time.time() < _deadline:
        _p1 = _pid1_ctx()
        if _p1 == "u:r:rhizo_host:s0": break
        time.sleep(0.1)
    log("pid1 ctx=%s deadline_hit=%s" % (_p1, time.time() >= _deadline))
else:
    log("pid1 is already %s" % _pid1_before)

if _init_pid is not None:
    _deadline = time.time() + 60
    _init_ctx = ""
    while time.time() < _deadline:
        try:
            with open("/proc/%d/attr/current" % _init_pid) as f: _init_ctx = f.read().strip("\0").strip()
        except OSError as e:
            log("failed to read /proc/%d/attr/current (%s)" % (_init_pid, e)); break
        if _init_ctx and _init_ctx != "kernel" and _init_ctx != "u:r:kernel:s0": break
        time.sleep(0.2)
    log("sandbox init ctx=%r deadline_hit=%s" % (_init_ctx, time.time() >= _deadline))



_DM_UNIT = _display_manager_unit()
_stuck_units = _units_still_kernel()
_BUS_UNITS = ("dbus-broker.service", "dbus.service")


# return the sort key with the bus units first and ssh units last
def _restart_order(unit):
    return (unit.startswith("ssh"), unit not in _BUS_UNITS, unit)


# restart the BoundBy units of bus
def _restart_bus_dependents(bus):
    try:
        deadline = time.time() + 15
        while True:
            st = subprocess.run(["systemctl", "show", bus, "-p", "Job", "-p", "ActiveState"], timeout=10,
                                check=False, capture_output=True, text=True).stdout.split()
            if "Job=" in st and "ActiveState=active" in st:
                break
            if time.time() >= deadline:
                log("%s is still restarting after 15s (%s)" % (bus, " ".join(st)))
                break
            time.sleep(0.2)
        bound = subprocess.run(["systemctl", "show", bus, "-p", "BoundBy", "--value"], timeout=10,
                               check=False, capture_output=True, text=True).stdout.split()
        for b in bound:
            if b in _stuck_units:
                continue
            log("restart %s bound_to=%s" % (b, bus))
            subprocess.run(["systemctl", "restart", "--no-block", "--job-mode=ignore-dependencies", b],
                           timeout=20, check=False, capture_output=True, text=True)
    except subprocess.TimeoutExpired as e:
        log("failed to restart the BoundBy units of %s (%s)" % (bus, e))


# restart the system.slice services in the kernel domain
def _restart_pass():
    if _stuck_units:
        log("host services in the kernel domain %s (caller=%s display-manager=%s)"
            % (" ".join("%s(pid %s)" % kv for kv in sorted(_stuck_units.items())),
               _CALLER_UNIT or "-", _DM_UNIT or "-"))
        for u in sorted(_stuck_units, key=_restart_order):
            if _restart_class(u, _CALLER_UNIT, _DM_UNIT) != "restart": continue
            log("restart %s" % u)
            try:
                rr = subprocess.run(["systemctl", "restart", "--no-block", "--job-mode=ignore-dependencies", u],
                                    timeout=20, check=False,
                                    capture_output=True, text=True)
            except subprocess.TimeoutExpired:
                log("systemctl restart %s timed out after 20s" % u)
                continue
            if rr.returncode != 0: log("restart %s rc=%s err=%r" % (u, rr.returncode, (rr.stderr or "")[:120]))
            if u in _BUS_UNITS:
                _restart_bus_dependents(u)
        _left = _units_still_kernel()
        _deadline = time.time() + 20
        while any(_restart_class(u, _CALLER_UNIT, _DM_UNIT) == "restart" for u in _left) \
                and time.time() < _deadline:
            time.sleep(1)
            _left = _units_still_kernel()
        log("restart pass pid1=%s kernel_domain=%s exempt=%s"
            % (_pid1_ctx(), " ".join(_leftovers(_left, _CALLER_UNIT, _DM_UNIT)) or "none",
               " ".join(sorted(set(_left) - set(_leftovers(_left, _CALLER_UNIT, _DM_UNIT)))) or "none"))
    else:
        log("0 host services in the kernel domain")



# return the user@ units whose systemd process is in the kernel domain
def _user_managers_still_kernel(cg_root="/sys/fs/cgroup/user.slice", proc="/proc"):
    stuck = {}
    for unit_dir in sorted(glob.glob(os.path.join(cg_root, "user-*.slice", "user@*.service"))):
        pids = []
        for sub in ("init.scope", ""):
            try:
                with open(os.path.join(unit_dir, sub, "cgroup.procs")) as f:
                    pids += f.read().split()
            except OSError:
                pass
        for pid in pids:
            try:
                with open("%s/%s/comm" % (proc, pid)) as f:
                    if f.read().strip() != "systemd":
                        continue
                with open("%s/%s/attr/current" % (proc, pid)) as f:
                    domain = f.read().strip("\0").strip()
            except OSError:
                continue
            if domain in ("kernel", "u:r:kernel:s0"):
                stuck[os.path.basename(unit_dir)] = pid
            break
    return stuck


# return the version systemctl --version prints, or 0
def _systemd_version():
    try:
        out = subprocess.run(["systemctl", "--version"], timeout=10, check=False,
                             capture_output=True, text=True).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0
    m = re.match(r"systemd (\d+)", out)
    return int(m.group(1)) if m else 0


# return whether systemctl --user is-system-running prints running or degraded
def _user_manager_answers(unit):
    uid = unit[len("user@"):-len(".service")]
    try:
        name = pwd.getpwuid(int(uid)).pw_name
        r = subprocess.run(["runuser", "-u", name, "--", "env", "XDG_RUNTIME_DIR=/run/user/%s" % uid,
                            "systemctl", "--user", "is-system-running"], timeout=5, check=False,
                           capture_output=True, text=True)
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        return False
    return r.stdout.strip() in ("running", "degraded")


# os.kill each user manager in stuck with SIGRTMIN+25 and return the units left
def _reexec_user_managers(stuck, wait_s=10):
    for unit, pid in sorted(stuck.items()):
        log("re-exec %s (pid %s) with SIGRTMIN+25" % (unit, pid))
        try:
            os.kill(int(pid), signal.SIGRTMIN + 25)
        except (OSError, ValueError) as e:
            log("failed to signal %s (%s)" % (unit, e))
    deadline = time.time() + wait_s
    left = dict(stuck)
    while left:
        kernel = _user_managers_still_kernel()
        left = {u: p for u, p in left.items() if u in kernel or not _user_manager_answers(u)}
        if not left or time.time() >= deadline:
            break
        time.sleep(0.2)
    log("user managers left=%s"
        % (" ".join("%s(pid %s)" % kv for kv in sorted(left.items())) or "none"))
    return left


# return /sys/fs/selinux/enforce, or "" on OSError
def _enforce_value():
    try:
        with open("/sys/fs/selinux/enforce") as f:
            return f.read().strip()
    except OSError:
        return ""


# re-exec the kernel-domain user managers and return the units left
def _clear_user_managers():
    stuck = _user_managers_still_kernel()
    if not stuck:
        return stuck
    if _enforce_value() != "0":
        log("enforce is not 0, skipped the re-exec of %s" % " ".join(sorted(stuck)))
        return stuck
    version = _systemd_version()
    if version < 250:
        log("systemd %d is below 250, skipped the SIGRTMIN+25 re-exec of %s"
            % (version, " ".join(sorted(stuck))))
        return stuck
    return _reexec_user_managers(stuck)


_POLICY_REFUSED = "/run/rhizo-policy-refused"
_FLIP_MARKER = "/run/rhizo-primer-flipped"


# write text to path through a temp file and os.replace
def _write_state(path, text):
    tmp = os.path.join(os.path.dirname(path), ".%s.tmp" % os.path.basename(path))
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


# write the refusal records, kill the sandbox init and exit 1
def _refuse_flip(left):
    reason = "%s still in the kernel domain" % ", ".join(sorted(left))
    log("refused the enforce flip (%s)" % reason)
    try:
        _write_state(_POLICY_REFUSED, "refused_by=rhizo-host-primer\nreason=%s\n" % reason)
        if _NO_SANDBOX:
            _write_state(_FLIP_MARKER, "enforce=%s\nstill_in_kernel_domain=%s\n"
                         % (_enforce_value() or "?", ",".join(sorted(left))))
    except OSError as e:
        log("failed to write the refusal (%s)" % e)
    if _init_pid is not None:
        try:
            os.kill(_init_pid, signal.SIGKILL)
            log("killed sandbox init pid=%d" % _init_pid)
        except OSError as e:
            log("failed to kill sandbox init pid=%d (%s)" % (_init_pid, e))
    sys.exit(1)


# return /proc/<pid>/attr/current, or "" on OSError
def _pid_domain(pid, proc="/proc"):
    try:
        with open("%s/%s/attr/current" % (proc, pid)) as f:
            return f.read().strip("\0").strip()
    except OSError:
        return ""


# return the loginctl Class of session sid
def _session_class(sid):
    try:
        return subprocess.run(["loginctl", "show-session", sid, "-p", "Class", "--value"], timeout=10,
                              check=False, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


# return the session scopes with a kernel-domain process and a user Class
def _kernel_logins(cg_root="/sys/fs/cgroup/user.slice", proc="/proc"):
    names = []
    for scope in sorted(glob.glob(os.path.join(cg_root, "user-*.slice", "session-*.scope"))):
        try:
            with open(os.path.join(scope, "cgroup.procs")) as f:
                pids = f.read().split()
        except OSError:
            continue
        if not any(_pid_domain(p, proc) in ("kernel", "u:r:kernel:s0") for p in pids):
            continue
        sid = os.path.basename(scope)[len("session-"):-len(".scope")]
        if _session_class(sid) in ("background", "background-light", "manager", "manager-early", "none"):
            continue
        names.append("session %s (uid %s)" % (sid, os.path.basename(os.path.dirname(scope))[len("user-"):-len(".slice")]))
    return names


# return _kernel_logins(), or [] with RHIZO_RIG_LOAD_UNDER_LOGIN=1
def _logins_refusing_flip():
    if os.environ.get("RHIZO_RIG_LOAD_UNDER_LOGIN") == "1":
        return []
    return _kernel_logins()


_logins_left = _logins_refusing_flip()
if _logins_left:
    _refuse_flip(_logins_left)
_user_managers_left = _clear_user_managers()
if _user_managers_left:
    _refuse_flip(_user_managers_left)
_restart_pass()

try:
    open(_ns_path("/sys/fs/selinux/enforce"), "w").write("1")
    log("wrote 1 to the sandbox /sys/fs/selinux/enforce")
except _NoSandboxInit as e:
    log(("skipped the sandbox /sys/fs/selinux/enforce with --no-sandbox" if _NO_SANDBOX
         else "failed to write the sandbox /sys/fs/selinux/enforce (%s)" % e))
except OSError as e:
    log("failed to write the sandbox /sys/fs/selinux/enforce (%s)" % e)

try:
    _census = []
    for _e in (sorted(os.listdir("/proc")) if _first_boot else []):
        if not _e.isdigit(): continue
        try:
            with open("/proc/%s/attr/current" % _e) as _f:
                _c = _f.read().strip("\0").strip()
            with open("/proc/%s/comm" % _e) as _f:
                _cm = _f.read().strip()
            with open("/proc/%s/stat" % _e) as _f:
                _fields = _f.read().rsplit(")", 1)[1].split()
            _ppid = _fields[1]
            _stt = _fields[19] if len(_fields) > 19 else "?"
        except (OSError, IndexError):
            continue
        _census.append("%s(ppid %s,start %s) %s = %s" % (_e, _ppid, _stt, _cm, _c))
    if _first_boot:
        log("pre-flip processes (%d)\n    %s" % (len(_census), "\n    ".join(_census)))
    else:
        log("skipped the pre-flip process census with ctx u:r:rhizo_host:s0")
except OSError as e:
    log("pre-flip process census failed (%s)" % e)

_RESIDUE_ROOTS = ("/system_ext","/product","/vendor","/dev",
                   "/system/apex","/system/bin","/sys/fs/selinux",
                   "/linkerconfig","/metadata")
_RESIDUE_BAD = ("u:object_r:tmpfs:s0", "u:object_r:unlabeled:s0")

if not _NO_SANDBOX:
    relabel_staged_files()
relabel_flat_trees()
try:
    _residue_enforcing = open("/sys/fs/selinux/enforce").read().strip() == "1"
except OSError:
    _residue_enforcing = False
try:
    _residue = []
    _unreadable = []
    _rchecked = 0
    _nsprefix = _ns_path("")
    if _residue_enforcing:
        log("skipped the pre-flip residue check with enforce 1")
    for _rroot in ([] if _residue_enforcing else _RESIDUE_ROOTS):
        _rbase = _ns_path(_rroot)
        if not os.path.exists(_rbase): continue
        try: _rbase_dev = os.lstat(_rbase).st_dev
        except OSError: continue
        _rstack = [_rbase]
        while _rstack:
            _rp = _rstack.pop()
            _rchecked += 1
            try:
                _rlb = os.getxattr(_rp, "security.selinux", follow_symlinks=False).decode().rstrip("\0")
            except OSError as e:
                _rlb = None
                _unreadable.append("%s getxattr failed (%s)" %
                                    (_rp[len(_nsprefix):], errno.errorcode.get(e.errno, e.errno)))
            if _rlb in _RESIDUE_BAD:
                _residue.append("%s = %s" % (_rp[len(_nsprefix):], _rlb))
            if os.path.islink(_rp) or not os.path.isdir(_rp): continue
            try:
                if os.lstat(_rp).st_dev != _rbase_dev: continue
                for _rname in os.listdir(_rp): _rstack.append(os.path.join(_rp, _rname))
            except OSError as e:
                _unreadable.append("%s listdir failed (%s)" %
                                    (_rp[len(_nsprefix):], errno.errorcode.get(e.errno, e.errno)))
    if _residue:
        log("%d of %d objects are tmpfs or unlabeled\n    %s" %
            (len(_residue), _rchecked, "\n    ".join(sorted(_residue))))
    if _unreadable:
        log("getxattr or listdir failed on %d of %d objects\n    %s" %
            (len(_unreadable), _rchecked, "\n    ".join(sorted(_unreadable))))
    if not _residue and not _unreadable and not _residue_enforcing:
        log("0 of %d objects are tmpfs or unlabeled" % _rchecked)
except _NoSandboxInit as e:
    log(("skipped the pre-flip residue check with --no-sandbox" if _NO_SANDBOX
         else "pre-flip residue check failed (%s)" % e))
except OSError as e:
    log("pre-flip residue check failed (%s)" % e)


try:
    _already_enforcing = open("/sys/fs/selinux/enforce").read().strip() == "1"
except OSError:
    _already_enforcing = False
if _already_enforcing:
    log("/sys/fs/selinux/enforce is already 1")
elif os.environ.get("RHIZO_FLIP_EARLY") != "1":
    _deadline = time.time() + 300
    _found = False
    while time.time() < _deadline:
        if _boot_marker_seen():
            _found = True
            break
        time.sleep(0.5)
    log("sys.boot_completed marker %s" % ("found" if _found else "missing after 300s"))

_post_restart_stuck = _leftovers(_units_still_kernel(), _CALLER_UNIT, _DM_UNIT)

if not _already_enforcing:
    _user_managers_left = _clear_user_managers()
    if _user_managers_left:
        _refuse_flip(_user_managers_left)
    _logins_left = _logins_refusing_flip()
    if _logins_left:
        _refuse_flip(_logins_left)
    try:
        open("/sys/fs/selinux/enforce","w").write("1")
        log("wrote 1 to /sys/fs/selinux/enforce enforce=%s" %
            open("/sys/fs/selinux/enforce").read().strip())
    except OSError as e:
        log("failed to write /sys/fs/selinux/enforce (%s)" % e)
    if _enforce_value() == "1":
        try:
            os.unlink(_POLICY_REFUSED)
        except OSError:
            pass

if _NO_SANDBOX:
    try:
        _flip_enforce_now = open("/sys/fs/selinux/enforce").read().strip()
    except OSError as _e:
        _flip_enforce_now = "?"
    try:
        _ftmp = "/run/.rhizo-primer-flipped.tmp"
        with open(_ftmp, "w") as _ff:
            _ff.write("enforce=%s\n" % _flip_enforce_now)
            _ff.write("still_in_kernel_domain=%s\n" % ",".join(sorted(_post_restart_stuck)))
        os.replace(_ftmp, "/run/rhizo-primer-flipped")
        log("wrote /run/rhizo-primer-flipped enforce=%s still_in_kernel_domain=%s"
            % (_flip_enforce_now, ",".join(sorted(_post_restart_stuck)) or "none"))
    except OSError as e:
        log("failed to write /run/rhizo-primer-flipped (%s)" % e)

if _already_enforcing or os.environ.get("RHIZO_WATCH_POSTFLIP") != "1":
    _watch_pid = -1
    log("skipped the post-flip watch, %s" % ("enforce was already 1" if _already_enforcing
        else "RHIZO_WATCH_POSTFLIP is not 1"))
else:
    try:
        _watch_pid = os.fork()
    except OSError as e:
        _watch_pid = -1
        log("fork failed (%s)" % e)
if _watch_pid == 0:
    def _raw_read(_path, _n=256):
        _fd = os.open(_path, os.O_RDONLY)
        try:
            return os.read(_fd, _n)
        finally:
            os.close(_fd)
    def _stat_fields(_pid):
        try:
            _fields = _raw_read("/proc/%s/stat" % _pid, 4096).decode().rsplit(")", 1)[1].split()
            return (_fields[1], _fields[19])
        except (OSError, IndexError):
            return ("?", "?")
    _init_pid_s = str(_init_pid) if _init_pid is not None else None
    _seen = {}
    _denied = set()
    _t_start = time.time()
    while _init_pid_s and time.time() - _t_start < 20.0:
        _now = time.time()
        _pids = {_init_pid_s}
        try:
            _pids.update(_raw_read("/proc/%s/task/%s/children" %
                                   (_init_pid_s, _init_pid_s), 65536).decode().split())
        except OSError:
            pass
        if not os.path.exists("/proc/%s" % _init_pid_s):
            log("sandbox init exited t=%.4f (+%.4fs)" % (_now, _now - _t_start))
            break
        for _pid in sorted(_pids, key=lambda p: int(p)):
            if _pid in _denied: continue
            try:
                _ctx = _raw_read("/proc/%s/attr/current" % _pid).decode().strip("\0").strip()
            except OSError as _e:
                _denied.add(_pid)
                log("failed to read /proc/%s/attr/current (%s)" % (_pid, _e))
                continue
            _ppid, _st = _stat_fields(_pid)
            _sig = (_ctx, _ppid, _st)
            if _seen.get(_pid) != _sig:
                _seen[_pid] = _sig
                log("post-flip pid=%s ppid=%s starttime=%s ctx=%s t=%.4f (+%.4fs)" %
                    (_pid, _ppid, _st, _ctx, _now, _now - _t_start))
        time.sleep(0.2)
    os._exit(0)
try:
    subprocess.Popen(["/bin/sh", "@RHIZO_PAYLOAD_DIR@/rhizo-avc-capture.sh", "@RHIZO_LOG_DIR@/rhizo-avc.log"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL, start_new_session=True)
    log("started rhizo-avc-capture.sh -> @RHIZO_LOG_DIR@/rhizo-avc.log")
except Exception as e:
    log("failed to start rhizo-avc-capture.sh (%r)" % e)

after_flip_jobs()
"""

def desktop_profile():
    """return whether the rhizo.profile scope is desktop"""
    try:
        return capabilities.policy_or_deny(log=kmsg).scope("rhizo.profile") == "desktop"
    except Exception as e:
        kmsg(f"failed to read rhizo.profile ({e})")
        return False


def primer_screen_off_ms():
    """return the screen-off timeout in ms"""
    ms = "0"
    try:
        policy = capabilities.policy_or_deny(log=kmsg)
        if policy.scope("rhizo.profile") == "desktop":
            ms = "2147483647"
        elif policy.scope("rhizo.profile") == "server":
            seconds = policy.scope("server.screen_off_s")
            ms = "2147483647" if seconds == 0 else str(int(seconds) * 1000)
    except Exception as e:
        kmsg(f"failed to read the screen-off timeout from the policy ({e})")
    return ms

def write_primer_script(screen_off_ms=None):
    """write the host primer script"""
    if screen_off_ms is None:
        screen_off_ms = primer_screen_off_ms()
    tmp = f"{HOST_PRIMER_PATH}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        f.write(HOST_PRIMER_SRC.replace("@RHIZO_LOG_DIR@", RHIZO_LOG_DIR)
                               .replace("@RHIZO_CACHE_DIR@", RHIZO_CACHE_DIR)
                               .replace("@RHIZO_SCREEN_OFF_MS@", screen_off_ms)
                               .replace("@RHIZO_FREEFORM@", "1" if desktop_profile() else "0")
                               .replace("@RHIZO_BLUETOOTH_ARMED@", "1" if bluetooth_armed() else "0")
                               .replace("@RHIZO_NETWORK_LOCATION@", "1" if network_location_armed() else "0")
                               .replace("@RHIZO_COLDBOOT_RELABEL@",
                                        ",".join(f"{p}={lbl}" for p, lbl in coldboot_primer_spec()))
                               .replace("@RHIZO_PROBE_CLIENT@", beside("probe-client.py"))
                               .replace("@RHIZO_PAYLOAD_DIR@/rhizo-avc-capture.sh",
                                        beside("rhizo-avc-capture.sh")))
    os.replace(tmp, HOST_PRIMER_PATH)

def spawn_host_primer():
    """write the host primer and start the primer in the rhizo-host-primer scope"""
    if not host_selinux_mode():
        kmsg("RHIZO_MARKER selinuxns=host-primer-skipped")
        return
    if os.environ.get("RHIZO_NO_HOST_PRIME") == "1":
        kmsg("skipped the host primer with RHIZO_NO_HOST_PRIME=1")
        return
    try:
        _so_ms = primer_screen_off_ms()
        write_primer_script(_so_ms)
        import subprocess as _sp
        _cmd = [sys.executable, HOST_PRIMER_PATH, "--sandbox-id", str(SANDBOX_ID),
                "--run-root", RUN_ROOT, "--init-pid-file", INIT_PID_FILE]
        if os.environ.get("RHIZO_POLICY_ONLY") == "1":
            _cmd.append("--no-sandbox")
        if not RHIZO_ENFORCING:
            _cmd.append("--relabel-only")
        if os.environ.get("RHIZO_CALLER_UNIT"):
            _cmd += ["--caller-unit", os.environ["RHIZO_CALLER_UNIT"]]
        if RHIZO_UNDER_UNIT:
            _cmd = ["systemd-run", "--scope", "--collect",
                    "--unit=rhizo-host-primer", "--quiet"] + _cmd
            _scope = next(a.split("=", 1)[1] for a in _cmd
                          if a.startswith("--unit=")) + ".scope"
            _state = _sp.run(["systemctl", "show", "-p", "ActiveState", "--value", _scope],
                             capture_output=True, text=True, timeout=15, check=False)
            if _state.stdout.strip() in ("active", "activating"):
                kmsg(f"{_scope} is already {_state.stdout.strip()}")
                return
        _sp.Popen(_cmd, start_new_session=True,
                  stdin=_sp.DEVNULL, stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
        kmsg("started the host primer")
    except Exception as e:
        kmsg(f"failed to start the host primer ({e})")

AFTER_FLIP_DEADLINE_S = 240 + selinux_ns.RELABELLER_DEADLINE_S + 120

def run_after_flip_jobs():
    """run the host primer --after-flip if wait_for_enforce returns enforced"""
    got = hostlock.wait_for_enforce(AFTER_FLIP_DEADLINE_S)
    if got != "enforced":
        kmsg(f"RHIZO_MARKER after_flip=skipped reason={got or f'deadline-{AFTER_FLIP_DEADLINE_S}s'}")
        return 1
    r = subprocess.run([sys.executable, HOST_PRIMER_PATH, "--after-flip", "--sandbox-id", str(SANDBOX_ID),
                        "--run-root", RUN_ROOT], capture_output=True, text=True, timeout=600)
    kmsg(f"RHIZO_MARKER after_flip=ran rc={r.returncode}"
         + (f" err={r.stderr.strip()[-200:]!r}" if r.returncode != 0 else ""))
    return 0 if r.returncode == 0 else 1

def arm_after_flip_jobs():
    """fork a detached process that runs the after-flip jobs"""
    if os.environ.get("RHIZO_NO_HOST_PRIME") == "1":
        kmsg("skipped the after-flip jobs with RHIZO_NO_HOST_PRIME=1")
        return
    mid = os.fork()
    if mid == 0:
        jobs = os.fork()
        if jobs == 0:
            os.setsid()
            code = 1
            try:
                code = run_after_flip_jobs()
            except BaseException as e:
                kmsg(f"RHIZO_MARKER after_flip=failed err={e!r}")
            os._exit(code)
        os._exit(0)
    os.waitpid(mid, 0)

def reclaim_cgroup_root(path, log):
    """chown path and path/cgroup.procs to uid 0"""
    procs = f"{path}/cgroup.procs"
    try:
        d, f = os.stat(path), os.stat(procs)
    except OSError as e:
        log(f"failed to stat {path} ({e})")
        return False
    log(f"cgroup root {path} dir={d.st_uid}:{d.st_gid} {d.st_mode & 0o7777:o} "
        f"cgroup.procs={f.st_uid}:{f.st_gid} {f.st_mode & 0o7777:o} "
        f"uid={os.getuid()} euid={os.geteuid()}")
    if d.st_uid == os.geteuid() and f.st_uid == os.geteuid():
        log(f"cgroup root {path} uid is already euid")
        return False
    try:
        os.chown(path, 0, d.st_gid)
        os.chown(procs, 0, f.st_gid)
    except OSError as e:
        log(f"failed to chown {path} to uid 0 ({e})")
        return False
    log(f"chowned {path} from uid {f.st_uid} to uid 0")
    return True


def cgroup_tree_pids(root, skip=(), depth=None):
    """return the pids under root and not in skip, or None on OSError"""
    found = []

    def _raise(err):
        """raise the os.walk error"""
        raise err

    try:
        if not os.path.isdir(root):
            return None
        for d, dirs, files in os.walk(root, onerror=_raise):
            if depth == 0:
                dirs[:] = []
            if "cgroup.procs" not in files:
                continue
            for line in open(f"{d}/cgroup.procs"):
                if line.strip() and int(line) not in skip:
                    found.append(int(line))
    except (OSError, ValueError):
        return None
    return found


def clear_delegated_controllers(root, log, skip=()):
    """clear cgroup.subtree_control in root and the descendants of root"""
    live = cgroup_tree_pids(root, skip=tuple(skip) + (os.getpid(), recorded_pid()))
    if live is None:
        log(f"failed to read the cgroup tree under {root}")
        return False
    if live:
        log(f"{len(live)} processes are still under {root} ({live[:8]})")
        return False
    def _raise(err):
        """raise the os.walk error"""
        raise err

    try:
        paths = [d for d, _dirs, _files in os.walk(root, topdown=False, onerror=_raise)]
    except OSError as e:
        log(f"failed to walk {root} ({e})")
        return False
    cleared, failed = 0, []
    for d in paths:
        path = f"{d}/cgroup.subtree_control"
        try:
            if not open(path).read().strip():
                continue
            cgroup_write(path, "-memory -cpu")
            cleared += 1
        except OSError as e:
            failed.append(f"{path} ({e})")
    if failed:
        log(f"cgroup.subtree_control under {root} cleared={cleared} failed={len(failed)} "
            f"({'; '.join(failed[:3])})")
        return False
    log(f"cgroup.subtree_control under {root} cleared={cleared} cgroups={len(paths)}")
    return True


def join_cgroup(path, pid, log):
    """put pid into the cgroup at path"""
    try:
        _owner = os.stat(f"{path}/cgroup.procs").st_uid
    except OSError:
        _owner = os.geteuid()
    if _owner != os.geteuid() and not reclaim_cgroup_root(path, log):
        return False
    try:
        cgroup_write(f"{path}/cgroup.procs", str(pid))
        return True
    except OSError as e:
        log(f"failed to move {pid} into {path} ({e})")
    if not reclaim_cgroup_root(path, log):
        return False
    try:
        cgroup_write(f"{path}/cgroup.procs", str(pid))
        log(f"moved {pid} into {path} after the chown to uid 0")
        return True
    except OSError as e:
        log(f"failed to move {pid} into {path} after the chown to uid 0 ({e})")
        return False


CGROUP_FS = "/sys/fs/cgroup"
CGROUP_INIT_LEAF = "init"


def instance_init_cgroup(cgroup_root, cgroup_fs=CGROUP_FS):
    """return the init leaf under cgroup_root, or None"""
    root = cgroup_root.strip().rstrip("/")
    if not root or not root.startswith(cgroup_fs + "/"):
        return None
    return f"{root}/{CGROUP_INIT_LEAF}"


class LogPipeStream:
    """line stream over a log pipe fd"""

    def __init__(self, fd):
        self.fd = fd
        self.pending = ""

    def write(self, text):
        """buffer text and write the complete lines"""
        self.pending += text
        cut = self.pending.rfind("\n") + 1
        if cut:
            self._send(self.pending[:cut])
            self.pending = self.pending[cut:]
        return len(text)

    def flush(self):
        """write the pending partial line"""
        if self.pending:
            self._send(self.pending)
            self.pending = ""

    def _send(self, text):
        """write text to the fd"""
        data = text.encode(errors="replace")
        while data:
            try:
                data = data[os.write(self.fd, data):]
            except OSError as e:
                report_log_pipe_failure(self.fd, e)
                break

    def fileno(self):
        """return self.fd"""
        return self.fd


_DROPPED_LOG_FDS = set()


def report_log_pipe_failure(fd, err):
    """write a log pipe write failure to kmsg"""
    if err.errno == errno.EPIPE:
        if fd in _DROPPED_LOG_FDS:
            return
        what = "EPIPE, dup2 of /dev/null over the fd"
        try:
            null = os.open(os.devnull, os.O_WRONLY)
        except OSError as e:
            _DROPPED_LOG_FDS.add(fd)
            what = f"EPIPE, failed to open {os.devnull} ({errno.errorcode.get(e.errno, e.errno)})"
        else:
            os.dup2(null, fd)
            os.close(null)
    else:
        what = f"write failed ({errno.errorcode.get(err.errno, err.errno)})"
    try:
        os.write(core._kmsg_fd(), f"<4>L3: supervisor log fd {fd} {what}\n".encode())
    except OSError:
        pass


def ensure_supervisor_cgroup(log):
    """create SUPERVISOR_CGROUP"""
    try:
        os.makedirs(SUPERVISOR_CGROUP, exist_ok=True)
    except OSError as e:
        log(f"failed to create {SUPERVISOR_CGROUP} ({e})")
        return False
    return True


def route_supervisor_log(log_path, log):
    """route stdio to log_path through a parked pump"""
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    sys.stdout, sys.stderr = LogPipeStream(1), LogPipeStream(2)
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        pumps = route_stdio_through_pipe(log_path)
    except OSError as e:
        core.stdio_to_null()
        log(f"RHIZO_MARKER supervisor_log=unusable path={log_path} err={e!r}")
        return []
    for pump in pumps:
        # cgroup-clear-exempt: SUPERVISOR_CGROUP has no controllers
        if not ensure_supervisor_cgroup(log) or not join_cgroup(SUPERVISOR_CGROUP, pump, log):
            log(f"failed to move supervisor log pump {pump} into {SUPERVISOR_CGROUP}")
    return pumps


def park_supervisor_in_host_cgroup(log):
    """move the supervisor into SUPERVISOR_CGROUP"""
    if not os.path.isdir(SUPERVISOR_CGROUP):
        log(f"{SUPERVISOR_CGROUP} does not exist")
        return False
    # cgroup-clear-exempt: SUPERVISOR_CGROUP has no controllers
    if not join_cgroup(SUPERVISOR_CGROUP, os.getpid(), log):
        log(f"failed to move the supervisor into {SUPERVISOR_CGROUP}")
        return False
    log(f"moved the supervisor into {SUPERVISOR_CGROUP}")
    return True


def join_instance_init_cgroup(instance_id, pid, log, root_file=None,
                              cgroup_fs=CGROUP_FS):
    """put pid in instance_id's init leaf"""
    path = root_file or core.paths_for(instance_id).cgroup_root_file
    try:
        root = open(path).read()
    except OSError as e:
        log(f"failed to read instance {instance_id} cgroup record {path} ({e})")
        return False
    target = instance_init_cgroup(root, cgroup_fs)
    if target is None:
        log(f"instance {instance_id} cgroup record {path} is {root.strip()!r}, not a cgroup under {cgroup_fs}")
        return False
    if not os.path.isdir(target):
        log(f"{target} is not a directory")
        return False
    # cgroup-clear-exempt: target is an init leaf under a cleared root
    return join_cgroup(target, pid, log)


def _confirm_ceiling(path, wrote):
    """read path and raise OSError unless the value matches wrote"""
    with open(path) as f:
        got = f.read().strip()
    wrote, name = str(wrote).strip(), os.path.basename(path)
    if got == wrote:
        return
    if name == "cpu.max" and wrote == "max" and got.split()[:1] == ["max"]:
        return
    if name == "memory.max" and wrote != "max" and got.isdigit() and wrote.isdigit():
        if 0 <= int(wrote) - int(got) < os.sysconf("SC_PAGE_SIZE"):
            return
    raise OSError(f"read {got!r}, wrote {wrote!r}")


def write_cgroup_ceilings(ceiling_root, mem_max, pids_max, cpu_max=None, log=kmsg):
    """write the cgroup ceilings on ceiling_root"""
    try:
        with open(f"{ceiling_root}/cgroup.controllers") as f:
            available = set(f.read().split())
    except OSError as e:
        log(f"failed to read {ceiling_root}/cgroup.controllers ({e})")
        return False
    required = {"memory", "pids"} | ({"cpu"} if cpu_max is not None else set())
    missing = required - available
    if missing:
        log(f"{ceiling_root}/cgroup.controllers={sorted(available)} is missing {sorted(missing)}")
        return False
    ceilings = [("memory.max", mem_max), ("pids.max", pids_max)]
    if cpu_max is not None:
        ceilings.append(("cpu.max", cpu_max))
    ok = True
    for _cg_f, _cg_v in ceilings:
        try:
            cgroup_write(f"{ceiling_root}/{_cg_f}", str(_cg_v))
            _confirm_ceiling(f"{ceiling_root}/{_cg_f}", _cg_v)
            log(f"cgroup {ceiling_root}/{_cg_f}={_cg_v}")
        except OSError as e:
            log(f"failed to write {_cg_f} ({e}) at {ceiling_root}")
            ok = False
    return ok


def _kconfig_has(line, path="/proc/config.gz"):
    """return whether /proc/config.gz contains line"""
    import gzip
    try:
        with gzip.open(path, "rt") as f:
            return any(entry.rstrip("\n") == line for entry in f)
    except FileNotFoundError:
        return False
    except (OSError, EOFError) as e:
        kmsg(f"failed to read {path} ({e!r}) for {line}")
        return False


def _probe_data_tier():
    """return the /data tier the host kernel supports"""
    try:
        quota_module = core.module_entry("quota_v2") is not None
    except FileNotFoundError:
        quota_module = False
    except OSError as e:
        kmsg(f"failed to read modules.dep ({e!r})")
        quota_module = False
    ok = quota_module or os.path.exists("/sys/module/quota_v2") or _kconfig_has("CONFIG_QFMT_V2=y")
    return "quota" if ok else "plain"


_SYS_BPF = 321
_BPF_MAP_CREATE = 0
_BPF_PROG_LOAD = 5
_BPF_PROG_ATTACH = 8
_BPF_PROG_DETACH = 9
_BPF_LINK_CREATE = 28
_BPF_PROG_TYPE_CGROUP_DEVICE = 15
_BPF_CGROUP_DEVICE = 6
_BPF_MAP_TYPE_HASH = 1
_BPF_PSEUDO_MAP_FD = 1
_BPF_FUNC_MAP_LOOKUP_ELEM = 1
DEVICE_MAP_ENTRIES = 1024


def _bpf(cmd, attr):
    """call bpf(2) with cmd and a packed bpf_attr"""
    buf = ctypes.create_string_buffer(attr, len(attr))
    return libc.syscall(_SYS_BPF, cmd, ctypes.byref(buf), len(attr))


_ALU64, _JMP = 0x07, 0x05
_MOV, _JNE, _EXIT = 0xb0, 0x50, 0x90
_AND, _JEQ, _ADD = 0x50, 0x10, 0x00
_K, _X = 0x00, 0x08
_LD, _LDX, _STX, _MEM, _W, _DW, _IMM = 0x00, 0x01, 0x03, 0x60, 0x00, 0x18, 0x00
_CALL = 0x80
_DEVCG_TYPE = {"b": 1, "c": 2}
UHID_ALLOW_WAIT_S = 10


def _insn(code, dst=0, src=0, off=0, imm=0):
    """pack an eBPF instruction"""
    return struct.pack("<BBhi", code, (src << 4) | dst, off, imm)


def _mov64_imm(dst, imm):
    """return the instruction moving imm into register dst"""
    return _insn(_ALU64 | _MOV | _K, dst=dst, imm=imm)


def _ldx_w(dst, src, off):
    """return the instruction loading the 32-bit word at src+off into dst"""
    return _insn(_LDX | _MEM | _W, dst=dst, src=src, off=off)


def _jne_imm(reg, imm, off):
    """return the instruction jumping off when reg is not imm"""
    return _insn(_JMP | _JNE | _K, dst=reg, imm=imm, off=off)


def _jeq_imm(reg, imm, off):
    """return the instruction jumping off when reg is imm"""
    return _insn(_JMP | _JEQ | _K, dst=reg, imm=imm, off=off)


def _and64_imm(dst, imm):
    """return the instruction masking register dst with imm"""
    return _insn(_ALU64 | _AND | _K, dst=dst, imm=imm)


def _bpf_exit():
    """return the exit instruction"""
    return _insn(_JMP | _EXIT)


def _stx_w(dst, src, off):
    """return the instruction storing the low 32 bits of src at dst+off"""
    return _insn(_STX | _MEM | _W, dst=dst, src=src, off=off)


def _mov64_reg(dst, src):
    """return the instruction copying register src into dst"""
    return _insn(_ALU64 | _MOV | _X, dst=dst, src=src)


def _add64_imm(dst, imm):
    """return the instruction adding imm to register dst"""
    return _insn(_ALU64 | _ADD | _K, dst=dst, imm=imm)


def _ld_map_fd(dst, fd):
    """return the two-slot instruction loading the map behind fd into dst"""
    return _insn(_LD | _DW | _IMM, dst=dst, src=_BPF_PSEUDO_MAP_FD, imm=fd) + _insn(0)


def _call(func):
    """return the instruction calling helper func"""
    return _insn(_JMP | _CALL, imm=func)


def _map_lookup_body(map_fd):
    """return the instructions allowing the device when map_fd has the (type, major, minor) key"""
    body = _stx_w(10, 6, -12) + _stx_w(10, 7, -8) + _stx_w(10, 8, -4)
    body += _mov64_reg(2, 10) + _add64_imm(2, -DEVICE_MAP_KEY.size) + _ld_map_fd(1, map_fd)
    body += _call(_BPF_FUNC_MAP_LOOKUP_ELEM) + _jeq_imm(0, 0, 2)
    return body + _mov64_imm(0, 1) + _bpf_exit()


def build_device_allowlist_program(allowed, map_fd=None):
    """return the cgroup device program allowing allowed, FENCE_MINORS entries by map_fd lookup, and denying the rest"""
    prog = _mov64_imm(0, 0)
    prog += _ldx_w(6, 1, 0)
    prog += _and64_imm(6, 0xffff)
    prog += _ldx_w(7, 1, 4)
    prog += _ldx_w(8, 1, 8)
    for kind, major, minor, *excluded in allowed:
        guards = [(_jne_imm, 6, _DEVCG_TYPE[kind]), (_jne_imm, 7, major)]
        if minor == FENCE_MINORS:
            if map_fd is None:
                raise ValueError(f"{kind} {major}:{minor} is FENCE_MINORS and map_fd is None")
            body = _map_lookup_body(map_fd)
        else:
            if minor is not None:
                guards.append((_jne_imm, 8, minor))
            else:
                guards += [(_jeq_imm, 8, m) for m in (excluded[0] if excluded else ())]
            body = _mov64_imm(0, 1) + _bpf_exit()
        for i, (jump, reg, imm) in enumerate(guards):
            prog += jump(reg, imm, len(guards) - i - 1 + len(body) // 8)
        prog += body
    prog += _bpf_exit()
    return prog


def open_device_filter_map(bpf_fn=_bpf, log=kmsg):
    """create a BPF_MAP_TYPE_HASH map and return a DeviceFilterMap for the map fd, or None"""
    attr = struct.pack("<IIIIIII16s", _BPF_MAP_TYPE_HASH, DEVICE_MAP_KEY.size, 4, DEVICE_MAP_ENTRIES, 0, 0, 0,
                       b"rhizo_devmap\0")
    fd = bpf_fn(_BPF_MAP_CREATE, attr)
    if fd < 0:
        log(f"BPF_MAP_CREATE failed ({os.strerror(ctypes.get_errno())})")
        return None
    return DeviceFilterMap(fd, bpf_fn)


def drop_device_filter_map():
    """close and clear core.device_filter_map()"""
    devmap = core.device_filter_map()
    if devmap is not None:
        devmap.close()
    core.set_device_filter_map(None)


def describe_allowlist(allowed):
    """return the allow-list as kind major:minor words"""
    words = []
    for kind, major, minor, *excluded in allowed:
        word = f"{kind} {major}:{'*' if minor is None else minor}"
        if excluded and excluded[0]:
            word += " less " + "/".join(str(m) for m in excluded[0])
        words.append(word)
    return ", ".join(words)


def install_device_cgroup_filter(cgroup_dir, policy, log=kmsg, bpf_fn=_bpf,
                                  paths=None, stat_fn=os.stat, sys_root="/sys", proc_root="/proc",
                                  sandbox_id=None, uhid_wait_s=0, devmap=None):
    """attach the default-deny device allow-list program to cgroup_dir with BPF_LINK_CREATE"""
    withheld = withheld_device_majors(policy, log=log, paths=paths, stat_fn=stat_fn)
    if withheld is None:
        return False
    allowed = device_allowlist(policy, log=log, paths=paths, stat_fn=stat_fn, sys_root=sys_root,
                               proc_root=proc_root, sandbox_id=SANDBOX_ID if sandbox_id is None else sandbox_id,
                               uhid_wait_s=uhid_wait_s)
    if allowed is None:
        return False
    shadowed = [w for w in withheld if allowlist_admits(allowed, "c", *w)]
    if shadowed:
        log(f"allowlist_admits is True for the withheld devices {shadowed}")
        return False
    if devmap is None and any(dev[2] == FENCE_MINORS for dev in allowed):
        log("devices.uinput is on and devmap is None")
        return False
    prog = build_device_allowlist_program(allowed, None if devmap is None else devmap.fd)
    prog_buf = ctypes.create_string_buffer(prog, len(prog))
    lic_buf = ctypes.create_string_buffer(b"Rhizo-device-filter")
    name_buf = b"rhizo_devfilt\0"
    load_attr = struct.pack(
        "<IIQQIIQII16sII",
        _BPF_PROG_TYPE_CGROUP_DEVICE, len(prog) // 8,
        ctypes.addressof(prog_buf), ctypes.addressof(lic_buf),
        0, 0, 0, 0, 0, name_buf, 0, 0)
    prog_fd = bpf_fn(_BPF_PROG_LOAD, load_attr)
    if prog_fd < 0:
        log(f"BPF_PROG_LOAD failed ({os.strerror(ctypes.get_errno())})")
        return False
    try:
        try:
            cgroup_fd = os.open(cgroup_dir, os.O_RDONLY | os.O_DIRECTORY)
        except OSError as e:
            log(f"failed to open {cgroup_dir} ({e})")
            return False
        try:
            # BPF_PROG_DETACH does not detach a BPF_LINK_CREATE link
            link_attr = struct.pack("<IIII", prog_fd, cgroup_fd, _BPF_CGROUP_DEVICE, 0) + b"\0" * 32
            link_fd = bpf_fn(_BPF_LINK_CREATE, link_attr)
            if link_fd < 0:
                log(f"BPF_LINK_CREATE on {cgroup_dir} failed ({os.strerror(ctypes.get_errno())})")
                return False
            core.set_device_filter_link(link_fd)
        finally:
            os.close(cgroup_fd)
    finally:
        os.close(prog_fd)
    described = ", ".join(
        ("major %d" % m) if n is None else ("major %d minor %d" % (m, n))
        for m, n in withheld) or "none"
    mapped = "devmap=None" if devmap is None else f"devmap_fd={devmap.fd} admitted={len(devmap.admitted)}"
    log(f"attached the device cgroup filter to {cgroup_dir} allowed={len(allowed)} "
        f"({describe_allowlist(allowed)}) withheld={len(withheld)} ({described}) {mapped}")
    return True


def require_rhizo_kernel():
    """refuse the boot on a non-rhizo kernel"""
    lacks = core.kernel_lacks()
    if lacks:
        marker = "RHIZO_MARKER kernel_refused=" + ",".join(
            {"built-in binder": "no-binder"}.get(x, "no-" + os.path.basename(x)) for x in lacks)
        kmsg(f"{marker} {os.uname().release} has no {', '.join(lacks)}")
        raise SystemExit(marker)
    try:
        with open(core.BINDER_DEVICES_FILE) as f:
            cur = f.read().strip()
    except OSError as e:
        marker = "RHIZO_MARKER binder_refused=builtin-devices-unreadable"
        kmsg(f"{marker} failed to read {core.BINDER_DEVICES_FILE} ({e.strerror})")
        raise SystemExit(marker)
    if cur != core.BINDER_DEVICES:
        marker = "RHIZO_MARKER binder_refused=builtin-devices"
        kmsg(f"{marker} {core.BINDER_DEVICES_FILE} is {cur!r}, expected {core.BINDER_DEVICES!r}")
        raise SystemExit(marker)
    kmsg(f"binder devices={cur!r}")


def prepare_host_and_data():
    """set up the host and /data"""
    phase("B", "prepare_host_and_data")
    _kmsg_mode_err = None
    try: os.chmod("/dev/kmsg", 0o666)
    except OSError as e: _kmsg_mode_err = e
    kmsg(MARKER_LAUNCH_START_TEXT)
    if _kmsg_mode_err is not None:
        kmsg(f"failed to chmod /dev/kmsg 0666 ({_kmsg_mode_err})")
    require_rhizo_kernel()
    raw_unit_cgroup = None
    _keeps_literal = keeps_literal_cgroup_root(RHIZO_RESIDENT_G, own_domain(), os.path.isdir(CGROUP_ROOT))
    if RHIZO_RESIDENT_G and RHIZO_UNDER_UNIT and not _keeps_literal:
        kmsg(f"RHIZO_RESIDENT_G is set, keeps_literal_cgroup_root returned False for {CGROUP_ROOT}")
    if RHIZO_UNDER_UNIT and not _keeps_literal:
        try:
            cg_rel = open("/proc/self/cgroup").read().strip().split(":")[-1]
        except OSError as e:
            kmsg(f"failed to read /proc/self/cgroup ({e}), using {CGROUP_ROOT}")
            cg_rel = None
        if cg_rel:
            raw_unit_cgroup = f"/sys/fs/cgroup{cg_rel}"
            cgroup_root = f"{raw_unit_cgroup}/android"
            os.makedirs(cgroup_root, exist_ok=True)
            clear_delegated_controllers(cgroup_root, kmsg)
            kmsg(f"launcher cgroup -> {cg_rel}/android")
        else:
            os.makedirs(CGROUP_ROOT, exist_ok=True)
            clear_delegated_controllers(CGROUP_ROOT, kmsg)
            join_cgroup(CGROUP_ROOT, os.getpid(), kmsg)
            cgroup_root = CGROUP_ROOT
    else:
        os.makedirs(CGROUP_ROOT, exist_ok=True)
        clear_delegated_controllers(CGROUP_ROOT, kmsg)
        join_cgroup(CGROUP_ROOT, os.getpid(), kmsg)
        cgroup_root = CGROUP_ROOT
    _ceiling_policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    _cpu_max = _ceiling_policy.scope("instance.cpu_max")
    _mem_max = _ceiling_policy.scope("instance.memory_max") or RHIZO_MEM_MAX_BYTES
    ceiling_root = raw_unit_cgroup or cgroup_root
    if not write_cgroup_ceilings(ceiling_root, _mem_max, RHIZO_PIDS_MAX,
                                  cpu_max=_cpu_max, log=kmsg):
        kmsg(f"failed to write the cgroup ceilings on {ceiling_root}")
        os._exit(1)
    core.set_device_filter_map(open_device_filter_map(log=kmsg))
    if not install_device_cgroup_filter(cgroup_root, _ceiling_policy, log=kmsg, devmap=core.device_filter_map()):
        kmsg(f"failed to install the device cgroup filter on {cgroup_root}")
        os._exit(1)
    global _CGROUP_ROOT
    _CGROUP_ROOT = cgroup_root
    try:
        write_cgroup_record(cgroup_root)
    except OSError as e:
        kmsg(f"failed to write the cgroup record ({e})")
    os.makedirs(f"{cgroup_root}/launcher", exist_ok=True)
    try:
        cgroup_write(f"{cgroup_root}/launcher/cgroup.procs", str(os.getpid()))
        moved = open("/proc/self/cgroup").read().strip()
        kmsg(f"launcher cgroup -> {moved.split(':')[-1]}")
    except OSError as e:
        kmsg(f"failed to move the launcher into the launcher leaf ({e})")
    os.makedirs(f"{cgroup_root}/system", exist_ok=True)
    detach_own_vbmeta_loop()
    _run_root_why = clear_run_root()
    if _run_root_why:
        refuse_start_by_name(_run_root_why)
    os.makedirs(RUN_ROOT, exist_ok=True)
    mount("tmpfs",RUN_ROOT,"tmpfs",0,"mode=0755")
    _vendor_staged_on_disk = False
    try:
        import shutil as _sh_v
        if os.path.isdir(RHIZO_VENDOR_DIR):
            if core.unmount_under(RHIZO_VENDOR_DIR) < 0:
                raise OSError(f"failed to unmount the mounts under {RHIZO_VENDOR_DIR}")
            _sh_v.rmtree(RHIZO_VENDOR_DIR)
        os.makedirs(RHIZO_VENDOR_DIR, mode=0o755, exist_ok=True)
        os.makedirs(f"{RUN_ROOT}/vendor", exist_ok=True)
        _vendor_staged_on_disk = core.bind_private(RHIZO_VENDOR_DIR, f"{RUN_ROOT}/vendor")
    except OSError as e:
        kmsg(f"failed to set up {RHIZO_VENDOR_DIR} ({e})")
    kmsg(f"/vendor staging on {'real disk ' + RHIZO_VENDOR_DIR if _vendor_staged_on_disk else 'tmpfs'}")
    _prepared_key, _prepared_reason = core.validate_prepared()
    if _prepared_key:
        _prepared_bound = []
        _prepared_ok = True
        for _sub in PREPARED_BINDS:
            _target = f"{RUN_ROOT}/{_sub}"
            os.makedirs(_target, exist_ok=True)
            _src = f"{PREPARED_ROOT}/{_prepared_key}/{_sub}"
            if not (core.bind_private(_src, _target)
                    and mount(None, _target, None, MS_BIND | MS_REMOUNT | MS_RDONLY)):
                _prepared_ok = False
                break
            _prepared_bound.append(_target)
        if _prepared_ok:
            core.set_prepared(_prepared_key)
            kmsg(f"RHIZO_MARKER prepared={_prepared_key}")
            if not host_selinux_mode():
                try:
                    core.clear_prepared_refusal()
                except OSError as e:
                    kmsg(f"failed to clear the prepared refusal record ({e!r})")
        else:
            _left = [f for _target in _prepared_bound for f in core.umount_tree(_target)]
            if _left:
                raise OSError(f"umount_tree left mounts {_left}")
            kmsg("RHIZO_MARKER prepared_refused=bind-failed")
    else:
        kmsg(f"RHIZO_MARKER prepared_refused={_prepared_reason}")
        if not host_selinux_mode():
            try:
                core.request_reprepare(_prepared_reason)
            except OSError as e:
                kmsg(f"RHIZO_MARKER prepared_reprepare=failed reason={_prepared_reason} err={e!r}")
    _data_img = RHIZO_DATA_IMG
    os.makedirs(os.path.dirname(_data_img) or "/", exist_ok=True)
    os.makedirs(f"{RUN_ROOT}/data", exist_ok=True)

    sync_release_switch_marker(_data_img, os.environ.get("RHIZO_RELEASE_SWITCH") == "1")

    _DATA_TEMPLATES_DIR = "/var/lib/rhizo/templates"

    def _instantiate_data_template(use_quota):
        """copy the RHIZO_DATA_TEMPLATE image to _data_img"""
        if not RHIZO_DATA_TEMPLATE:
            return False
        key = RHIZO_DATA_TEMPLATE
        img = f"{_DATA_TEMPLATES_DIR}/data-template.{key}.img"
        meta_path = f"{img}.meta"
        try:
            with open(meta_path) as f:
                meta = json.load(f)
        except (OSError, ValueError) as e:
            kmsg(f"failed to read /data template {key} .meta ({e})")
            kmsg("RHIZO_MARKER data_template_fallback=meta-unreadable")
            return False
        want_format = "quota" if use_quota else "plain"
        if meta.get("format") != want_format:
            kmsg(f"/data template {key} format={meta.get('format')!r}, expected {want_format}")
            kmsg("RHIZO_MARKER data_template_fallback=format-mismatch")
            return False
        if not GSI_FINGERPRINT or meta.get("gsi_fingerprint") != GSI_FINGERPRINT:
            kmsg(f"/data template {key} gsi_fingerprint={meta.get('gsi_fingerprint')!r}, "
                 f"expected {GSI_FINGERPRINT!r}")
            kmsg("RHIZO_MARKER data_template_fallback=fingerprint-mismatch")
            return False
        if not os.path.exists(img) or os.path.getsize(img) == 0:
            kmsg(f"/data template {key} image {img} is missing or empty")
            kmsg("RHIZO_MARKER data_template_fallback=artifact-missing")
            return False
        part = f"{_data_img}.template-part"
        try:
            subprocess.run(["cp", "--sparse=always", img, part], check=True, capture_output=True)
            os.rename(part, _data_img)
        except Exception as e:
            kmsg(f"failed to copy /data template {key} ({e})")
            try: os.unlink(part)
            except OSError: pass
            kmsg("RHIZO_MARKER data_template_fallback=copy-failed")
            return False
        kmsg(f"RHIZO_MARKER data_template={key}")
        return True

    def _mount_data_tier(use_quota, reuse_existing):
        """create, attach and mount the /data image"""
        loop = None
        try:
            if reuse_existing and os.path.exists(_data_img) and os.path.getsize(_data_img) > 0:
                pass
            else:
                if os.path.exists(_data_img):
                    os.unlink(_data_img)
                    try: os.unlink(_data_img + ".meta")
                    except FileNotFoundError: pass
                if not _instantiate_data_template(use_quota):
                    mkfs_args = ["mkfs.ext4", "-q", "-F"]
                    if use_quota:
                        mkfs_args += ["-O", "quota,project"]
                    mkfs_args += [_data_img, "4G"]
                    subprocess.run(mkfs_args, check=True, capture_output=True)
            loop, loop_fd = core.loop_attach(_data_img)
            try:
                mount_data = "prjquota" if use_quota else None
                if not mount(loop, f"{RUN_ROOT}/data", "ext4", 0, mount_data):
                    raise OSError("mount(2) of the ext4 loop device failed")
            finally:
                os.close(loop_fd)
            return loop
        except Exception as e:
            kmsg(f"/data tier quota={use_quota} reuse={reuse_existing} failed ({e})")
            if loop:
                _rc, _out, _err = _losetup(["-d", loop])
                if _rc:
                    kmsg(f"failed to detach {loop} ({_err})")
            return None

    _quota_probably_available = _probe_data_tier() == "quota"

    _data_loop = None
    _quota_active = False
    if _quota_probably_available:
        if RHIZO_PERSIST_DATA:
            _data_loop = _mount_data_tier(use_quota=True, reuse_existing=True)
            if _data_loop is None:
                _data_loop = _mount_data_tier(use_quota=True, reuse_existing=False)
        else:
            _data_loop = _mount_data_tier(use_quota=True, reuse_existing=False)
        _quota_active = _data_loop is not None
    else:
        kmsg("_probe_data_tier returned plain, skipped the quota tier")
    if _data_loop is None:
        _data_loop = _mount_data_tier(use_quota=False, reuse_existing=RHIZO_PERSIST_DATA)

    if _data_loop:
        kmsg(f"mounted /data ext4 from {_data_loop} on {_data_img} "
             f"project-quota={'on' if _quota_active else 'off'} "
             f"RHIZO_PERSIST_DATA={'1' if RHIZO_PERSIST_DATA else '0'}")
    else:
        kmsg("failed to mount /data ext4 on the quota and plain tiers")
        try: os.unlink(_data_img)
        except OSError: pass

    _release_change = os.environ.get("RHIZO_DATA_RELEASE_CHANGE") == "1"
    if not check_data_release_marker(f"{RUN_ROOT}/data", RHIZO_RELEASE, not RHIZO_PERSIST_DATA, _release_change):
        os._exit(1)

    migrate_keystore_for_keymint_persistence(f"{RUN_ROOT}/data")

    if os.environ.get("RHIZO_FAULT_NO_READY") == "1":
        if os.environ.get("RHIZO_POLICY_ONLY") != "1":
            kmsg("RHIZO_MARKER fault_no_ready=armed")
            kmsg("RHIZO_FAULT_NO_READY=1, exit 1")
            os._exit(1)
        kmsg("skipped RHIZO_FAULT_NO_READY=1 with RHIZO_POLICY_ONLY=1")


def touch_cache_entry(path):
    """refresh the mtime of path"""
    try:
        os.utime(path)
    except OSError as e:
        kmsg(f"failed to utime sepolicy cache entry {path} ({errno.errorcode.get(e.errno, e.errno)} {e.strerror})")


def policy_wakeup_genfs(cils):
    """return the host's wakeup genfscons in namespace mode"""
    if host_selinux_mode():
        return ""
    return selinux_policy.host_wakeup_genfs(cils, kmsg)


def prepared_wakeup_path():
    """return the path of prepared-wakeup-genfs.cil"""
    return os.path.join(RHIZO_CACHE_DIR, "prepared-wakeup-genfs.cil")


def launched_wakeup_path():
    """return the path of launched-wakeup-genfs.cil"""
    return os.path.join(SELINUXNS_RECORDS_DIR, "launched-wakeup-genfs.cil")


def record_launched_wakeup(wakeup_genfs):
    """write the wakeup genfscons to launched_wakeup_path()"""
    path = launched_wakeup_path()
    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        with open(tmp, "w") as f:
            f.write(wakeup_genfs)
        os.replace(tmp, path)
    except OSError as e:
        kmsg(f"failed to write {path} ({e})")


def compile_precompiled_sepolicy(pc, rhizo_cil, wakeup_genfs=None):
    """compile the gsi's cils and rhizo's fragments into pc"""
    CIL_PARTS = [
        (f"{GSI}/etc/selinux/plat_sepolicy.cil", "plat_sepolicy_and_mapping.sha256"),
        (f"{GSI}/system_ext/etc/selinux/system_ext_sepolicy.cil", "system_ext_sepolicy_and_mapping.sha256"),
        (f"{GSI}/product/etc/selinux/product_sepolicy.cil", "product_sepolicy_and_mapping.sha256"),
    ]
    cils = [c for c,_ in CIL_PARTS if os.path.exists(c)]
    os.makedirs(os.path.dirname(rhizo_cil), exist_ok=True)
    if wakeup_genfs is None:
        wakeup_genfs = policy_wakeup_genfs(cils)
    rhizo_cil_content = selinux_policy.build(cils, ftrace=capabilities.ftrace_allowed(log=kmsg),
                                           namespace=not host_selinux_mode(), wakeup_genfs=wakeup_genfs)
    open(rhizo_cil, "w").write(rhizo_cil_content)
    cils.append(rhizo_cil)
    for software_cil in selinux_policy.software_cils(core.software_rendering()):
        cils.append(software_cil)
        rhizo_cil_content += open(software_cil).read()
        kmsg(f"devices.dri off, added {os.path.basename(software_cil)} to the policy")
    if RHIZO_DEBUG_PERMISSIVE_DOMAIN:
        debug_cil = os.path.join(os.path.dirname(rhizo_cil), "rhizo_debug_permissive.cil")
        open(debug_cil, "w").write(
            f"(typepermissive {RHIZO_DEBUG_PERMISSIVE_DOMAIN})\n")
        cils.append(debug_cil)
        kmsg(f"RHIZO_DEBUG_PERMISSIVE_DOMAIN={RHIZO_DEBUG_PERMISSIVE_DOMAIN}, staged rhizo_debug_permissive.cil")
    if RHIZO_DEBUG_PROC_READ:
        cils.append(guest_files.path("sepolicy/policy-debug-proc.cil"))
        kmsg("RHIZO_DEBUG_PROC_READ=1, staged policy-debug-proc.cil")
    plat_dir = tempfile.mkdtemp(prefix="rhizo-compile-cils-")
    compile_cils = [selinux_policy.compile_input(c, plat_dir) for c in cils]
    if compile_cils != cils:
        kmsg("compile_input rewrote the platform cils without the ashmem neverallow rules")
    if RHIZO_SEPOLICY_NODONTAUDIT:
        kmsg("RHIZO_SEPOLICY_NODONTAUDIT=1, secilc -D without the cache")
        rc = os.system(gsi_bootstrap_cmd(
            "bin/secilc",
            f"-m -M true -G -c 30 -D {' '.join(compile_cils)} -o {pc} -f /dev/null 2>/tmp/secilc.err"))
    else:
        cache_dir = RHIZO_CACHE_DIR
        cache_path = None
        try:
            os.makedirs(cache_dir, exist_ok=True)
            h = hashlib.sha256()
            for c in cils:
                h.update(open(c, "rb").read())
            cache_path = f"{cache_dir}/precompiled_sepolicy.{h.hexdigest()}"
        except OSError as e:
            kmsg(f"failed to hash the sepolicy cache key ({e})")

        force_recompile = os.environ.get("RHIZO_SEPOLICY_FORCE_RECOMPILE") == "1"
        if force_recompile:
            kmsg("RHIZO_SEPOLICY_FORCE_RECOMPILE=1, secilc without the cache")
        if (not force_recompile) and cache_path and os.path.exists(cache_path) and os.path.getsize(cache_path) > 0:
            import shutil as _shsepol
            _shsepol.copy(cache_path, pc)
            touch_cache_entry(cache_path)
            rc = 0
            kmsg(f"precompiled policy cache hit ({os.path.getsize(pc)} bytes)")
        else:
            if (not force_recompile) and cache_path and os.path.exists(cache_path):
                kmsg(f"precompiled policy cache entry {cache_path} is empty")
            rc=os.system(gsi_bootstrap_cmd(
                "bin/secilc",
                f"-m -M true -G -c 30 {' '.join(compile_cils)} -o {pc} -f /dev/null 2>/tmp/secilc.err"))
            if rc==0 and os.path.exists(pc) and cache_path:
                try:
                    import shutil as _shsepol2
                    _tmp_cache = f"{cache_path}.tmp.{os.getpid()}"
                    _shsepol2.copy(pc, _tmp_cache)
                    os.rename(_tmp_cache, cache_path)
                    kmsg("precompiled policy cache miss, wrote the cache entry")
                except OSError as e:
                    kmsg(f"failed to write the sepolicy cache entry ({e})")
    for c in compile_cils:
        if c not in cils:
            os.unlink(c)
    os.rmdir(plat_dir)
    if rc == 0 and os.path.exists(pc):
        for src_cil, sha in CIL_PARTS:
            sha_src = f"{os.path.dirname(src_cil)}/{sha}"
            if os.path.exists(sha_src):
                try: open(f"{pc}.{sha}","wb").write(open(sha_src,"rb").read())
                except OSError: pass
        return rc, cils, rhizo_cil_content, None
    err = ""
    try:
        err = open("/tmp/secilc.err").read()[:200]
    except OSError:
        pass
    return rc, cils, rhizo_cil_content, err


def _stage_vendor_scaffold():
    """create the vendor directories and the vendor contexts stubs"""
    os.makedirs(f"{RUN_ROOT}/vendor/etc/selinux", exist_ok=True)
    os.makedirs(f"{RUN_ROOT}/vendor/bin/hw", exist_ok=True)
    os.makedirs(f"{RUN_ROOT}/vendor/etc/init", exist_ok=True)
    for f in ("vendor_file_contexts","vendor_hwservice_contexts","vendor_seapp_contexts"):
        open(f"{RUN_ROOT}/vendor/etc/selinux/{f}","w").close()
    with open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_property_contexts", "w") as f:
        f.write(selinux_policy.vendor_property_contexts(not host_selinux_mode()))
    open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
        "/vendor/etc/selinux/vendor_file_contexts u:object_r:file_contexts_file:s0\n"
        "/vendor/etc/selinux/vendor_service_contexts u:object_r:vendor_service_contexts_file:s0\n"
        "/vendor/etc/selinux/vendor_property_contexts u:object_r:property_contexts_file:s0\n"
        "/vendor/etc/selinux/vendor_seapp_contexts u:object_r:seapp_contexts_file:s0\n"
        "/vendor/etc/selinux/vendor_hwservice_contexts u:object_r:hwservice_contexts_file:s0\n")
    if not os.path.lexists(RUN_ROOT + DEVICE_STATE_LINK):
        os.symlink(DEVICE_STATE_MOUNT, RUN_ROOT + DEVICE_STATE_LINK)
        if host_selinux_mode() and not policy_is_loaded():
            os.setxattr(RUN_ROOT + DEVICE_STATE_LINK, "security.selinux", b"u:object_r:vendor_configs_file:s0\0",
                        follow_symlinks=False)


def compile_sepolicy():
    """compile the GSI cils and rhizo_vendor_sepolicy.cil into precompiled_sepolicy"""
    phase("B", "compile_sepolicy")
    os.makedirs(f"{RUN_ROOT}/net_core_snapshot", exist_ok=True)
    try:
        for name in os.listdir("/proc/sys/net/core"):
            try:
                val = open(f"/proc/sys/net/core/{name}").read()
                open(f"{RUN_ROOT}/net_core_snapshot/{name}","w").write(val)
            except OSError: continue
    except OSError as e: kmsg(f"failed to snapshot /proc/sys/net/core ({e})")
    for p in ("vendor","apex","linkerconfig","mnt","mnt/vendor","data/local/tmp","metadata"):
        os.makedirs(f"{RUN_ROOT}/{p}", exist_ok=True)
    audio_policy_xml_src = beside("audio_policy_configuration.xml")
    if core.release_skips("audio_policy_configuration.xml"):
        kmsg(f"skipped audio_policy_configuration.xml for release {RHIZO_RELEASE}")
    elif os.path.exists(audio_policy_xml_src):
        os.makedirs(f"{RUN_ROOT}/vendor/etc", exist_ok=True)
        import shutil as _sh_apc
        _sh_apc.copy(audio_policy_xml_src, f"{RUN_ROOT}/vendor/etc/audio_policy_configuration.xml")
        kmsg("audio_policy_configuration.xml staged at /vendor/etc")
    else:
        kmsg(f"audio_policy_configuration.xml is missing at {audio_policy_xml_src}")
    _stage_vendor_scaffold()
    open(f"{RUN_ROOT}/vendor/etc/selinux/plat_sepolicy_vers.txt","w").write("202504\n")
    open(f"{RUN_ROOT}/vendor/manifest.xml","w").write(vendor_manifest_xml())
    open(f"{RUN_ROOT}/vendor/compatibility_matrix.xml","w").write(
        '<compatibility-matrix version="1.0" type="device">\n'
        "</compatibility-matrix>\n"
    )
    pc = f"{RUN_ROOT}/vendor/etc/selinux/precompiled_sepolicy"
    rhizo_cil = f"{RUN_ROOT}/vendor/etc/selinux/rhizo_vendor_sepolicy.cil"
    wakeup_genfs = policy_wakeup_genfs(_gsi_policy_cils())
    rc, cils, rhizo_cil_content, err = compile_precompiled_sepolicy(pc, rhizo_cil, wakeup_genfs=wakeup_genfs)
    if rc == 0 and os.path.exists(pc):
        kmsg(f"precompiled policy staged ({os.path.getsize(pc)} bytes) from {len(cils)} CIL parts")
        if not host_selinux_mode():
            record_launched_wakeup(wakeup_genfs)
        if not (host_selinux_mode() and policy_is_loaded()):
            core.record_policy_mode()
        label_host_binaries()
        try:
            os.unlink(INIT_PID_FILE)
        except FileNotFoundError:
            pass
        except OSError as e:
            kmsg(f"failed to unlink the init pid file ({e})")
        spawn_host_primer()
    else:
        kmsg(f"secilc failed rc={rc} ({err})")
        os._exit(1)
    return rhizo_cil_content


def stage_selinux_contexts(rhizo_cil_content):
    """stage the selinux contexts databases and labels"""
    phase("B", "stage_selinux_contexts")
    _ppv_src = selinux_policy.public_cil_path()
    vendor_sepolicy_cil_content = selinux_policy.cts_vendor_adapt(rhizo_cil_content, [_ppv_src])
    open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_sepolicy.cil", "w").write(vendor_sepolicy_cil_content)
    import shutil as _shppv
    _shppv.copy(_ppv_src, f"{RUN_ROOT}/vendor/etc/selinux/plat_pub_versioned.cil")
    kmsg(f"staged vendor_sepolicy.cil and plat_pub_versioned.cil ({os.path.getsize(f'{RUN_ROOT}/vendor/etc/selinux/vendor_sepolicy.cil')}, {os.path.getsize(_ppv_src)} bytes)")
    open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
        "/dev/socket/rhizo_wayland(/.*)? u:object_r:rhizo_wayland_socket:s0\n"
        "/dev/socket/rhizo_audio(/.*)? u:object_r:rhizo_audio_socket:s0\n"
        "/dev/socket/rhizo_stream(/.*)? u:object_r:rhizo_stream_socket:s0\n"
        "/dev/dri(/.*)? u:object_r:gpu_device:s0\n"
        "/data/rhizo_inbox(/.*)? u:object_r:rhizo_inbox_file:s0\n"
        "/data/rhizo_keymint(/.*)? u:object_r:rhizo_keymint_data_file:s0\n"
    )
    os.makedirs(f"{RUN_ROOT}/system_ext_upper/etc/init", exist_ok=True)
    _marker_svcs = sorted(set(re.findall(r"service (vendor\.rhizo-[A-Za-z0-9_-]+)", open(__file__).read())))
    _marker_svcs += ["keystore2", "zygote", "surfaceflinger", "netd", "servicemanager"]
    if core.camera_armed():
        _marker_svcs += ["vendor.rhizo-camera-provider", "cameraserver"]
    if core.sensors_armed():
        _marker_svcs += ["vendor.rhizo-sensors"]
    if core.codec2_armed():
        _marker_svcs += ["vendor.rhizo-codec2"]
    _marker_rc = ["on property:sys.boot_completed=1",
                  "    write /dev/kmsg \"%s\"" % MARKER_BOOT_COMPLETED_TEXT,
                  ""]
    for _svc in sorted(set(_marker_svcs)):
        for _st in ("running", "restarting", "stopped"):
            _marker_rc.append("on property:init.svc.%s=%s" % (_svc, _st))
            _marker_rc.append("    write /dev/kmsg \"RHIZO_SVC %s=%s\"" % (_svc, _st))
            _marker_rc.append("")
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-bootmarker.rc","w").write(
        "\n".join(_marker_rc) + "\n")
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-wayland-socket.rc","w").write(
        guest_files.read("init/wayland-socket.rc"))
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-inbox.rc","w").write(
        guest_files.read("init/inbox.rc"))
    open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-keymint-data.rc","w").write(
        guest_files.read("init/keymint-data.rc"))
    if RHIZO_ENFORCING:
        open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-enforcing-restorecon.rc","w").write(
                guest_files.read("init/enforcing-restorecon.rc"))
        kmsg("RHIZO_ENFORCING=1, staged rhizo-enforcing-restorecon.rc for /vendor,/data,/system_ext,/product,/system/apex")
    GPU_DRIVER_DIR = core.gpu_driver_dir()
    VULKAN_DRIVER_DIR = os.environ.get("RHIZO_VULKAN_DRIVER_DIR", GPU_DRIVER_DIR)
    vulkan_src = os.path.join(beside(VULKAN_DRIVER_DIR), "hw", "vulkan.rhizo.so")
    vulkan_available = os.path.isfile(vulkan_src)
    EGL_DRIVER = os.environ.get("RHIZO_EGL_DRIVER", "rhizo")
    egl_prop = f"ro.hardware.egl={EGL_DRIVER}\n"
    if vulkan_available:
        egl_prop += "ro.hardware.vulkan=rhizo\n"
    RELEASE = os.environ.get("RHIZO_RELEASE", "a16")
    if RELEASE == "a15" or os.environ.get("RHIZO_ABI32") != "1":
        zygote_prop = "ro.zygote=zygote64\nro.vendor.product.cpu.abilist32=\n"
    else:
        abi32 = "x86" if HOST_ARCH == HOST_ARCH_AMD64 else "armeabi-v7a"
        zygote_prop = "ro.zygote=zygote64_32\nro.vendor.product.cpu.abilist32=%s\n" % abi32
    apexd_threads = str(max(2, min(os.cpu_count() or 2, 8)))
    apexd_activation_threads = os.environ.get("RHIZO_APEXD_ACTIVATION_THREADS", apexd_threads)
    apexd_open_threads = os.environ.get("RHIZO_APEXD_OPEN_THREADS", apexd_threads)
    apexd_config = (
        (f"apexd.config.boot_activation.threads={apexd_activation_threads}\n"
         if apexd_activation_threads else "") +
        (f"apexd.config.loopback.readahead={os.environ['RHIZO_APEXD_LOOP_READAHEAD']}\n"
         if os.environ.get("RHIZO_APEXD_LOOP_READAHEAD") else "") +
        (f"apexd.config.apex_file_open.threads={apexd_open_threads}\n"
         if apexd_open_threads else "")
    )
    bootanim_prop = "" if os.environ.get("RHIZO_BOOTANIM") == "1" else "debug.sf.nobootanimation=1\n"
    freeform = desktop_profile()
    if freeform:
        os.makedirs(f"{RUN_ROOT}/vendor/etc/permissions", exist_ok=True)
        with open(f"{RUN_ROOT}/vendor/etc/permissions/rhizo-freeform.xml", "w") as f:
            f.write('<?xml version="1.0" encoding="utf-8"?>\n<permissions>\n'
                    '    <feature name="android.software.freeform_window_management" />\n</permissions>\n')
    open(f"{RUN_ROOT}/vendor/build.prop","w").write(guest_files.render(
        guest_files.read("vendor/build.prop"),
        whole={"zygote_prop": zygote_prop,
               "apexd_config": apexd_config,
               "bootanim_prop": bootanim_prop,
               "egl_prop": egl_prop,
               "ro_debuggable": "ro.debuggable=1\n" if RHIZO_ADB_ROOT else ""},
        comment_prefix="#"))
    os.makedirs(f"{RUN_ROOT}/system_upper/etc", exist_ok=True)


_VENDOR_LINKER_CONFIG_PB = (
    b'"\x0clibbinder.so"\x0blibutils.so"\nlibbase.so'
    b'"\x0clibcutils.so"\x0clibcrypto.so'
)
_SYSTEM_LINKER_CONFIG_PB = (
    b'\x1a\x0clibbinder.so\x1a\x0blibutils.so\x1a\nlibbase.so'
    b'\x1a\x0clibcutils.so\x1a\x0clibcrypto.so'
)


def stage_vendor_tree():
    """stage the vendor partition"""
    phase("B", "stage_vendor_tree")
    GPU_DRIVER_DIR = core.gpu_driver_dir()
    VULKAN_DRIVER_DIR = os.environ.get("RHIZO_VULKAN_DRIVER_DIR", GPU_DRIVER_DIR)
    gpu_src = beside(GPU_DRIVER_DIR)
    vulkan_src = os.path.join(beside(VULKAN_DRIVER_DIR), "hw", "vulkan.rhizo.so")
    vulkan_available = os.path.isfile(vulkan_src)
    if not host_selinux_mode() or not policy_is_loaded():
        open(f"{RUN_ROOT}/vendor/build.prop","a").write("ro.vendor.rhizo.first_boot=1\n")
        if host_selinux_mode():
            kmsg("ro.vendor.rhizo.first_boot=1")
        else:
            kmsg("RHIZO_MARKER selinuxns=first-boot-restorecon")
        import shutil as _shfc
        os.makedirs(RHIZO_CACHE_DIR, exist_ok=True)
        for _src, _name in ((f"{GSI}/etc/selinux/plat_file_contexts", "plat_file_contexts"),
                            (f"{GSI}/system_ext/etc/selinux/system_ext_file_contexts", "system_ext_file_contexts"),
                            (f"{GSI}/product/etc/selinux/product_file_contexts", "product_file_contexts")):
            try:
                _shfc.copy(_src, f"{RHIZO_CACHE_DIR}/{_name}")
            except OSError as _e:
                kmsg(f"failed to cache {_name} ({_e})")
    else:
        kmsg("ro.vendor.rhizo.first_boot is not set")
    open(f"{RUN_ROOT}/vendor/etc/linker.config.pb","wb").write(_VENDOR_LINKER_CONFIG_PB)
    open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
        "/vendor/etc/linker\\.config\\.pb u:object_r:vendor_configs_file:s0\n")
    open(f"{RUN_ROOT}/vendor/etc/cgroups.json","w").write(
        guest_files.read("vendor/cgroups.json"))
    open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
        "/vendor/etc/cgroups\\.json u:object_r:vendor_cgroup_desc_file:s0\n")
    open(f"{RUN_ROOT}/system_ext_upper/etc/linker.config.pb","wb").write(_SYSTEM_LINKER_CONFIG_PB)
    kmsg("linker.config.pb staged on /vendor/etc and /system_ext/etc")
    if os.path.isdir(gpu_src):
        os.makedirs(f"{RUN_ROOT}/vendor/lib64/egl", exist_ok=True)
        for f in os.listdir(f"{gpu_src}/egl"):
            core.stage_bulk(f"{gpu_src}/egl/{f}", f"{RUN_ROOT}/vendor/lib64/egl/{f}", 0o644)
        for f in os.listdir(f"{gpu_src}/lib"):
            if not os.path.isfile(f"{gpu_src}/lib/{f}") or f in codec2.VA_LIBS:
                continue
            core.stage_bulk(f"{gpu_src}/lib/{f}", f"{RUN_ROOT}/vendor/lib64/{f}", 0o644)
        va_drivers = codec2.stage_va_driver(gpu_src, f"{RUN_ROOT}/vendor/lib64") if core.codec2_release() else []
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
                guest_files.read("sepolicy/vendor_file_contexts"))
        kmsg(f"Mesa GPU driver staged from {GPU_DRIVER_DIR}/ egl={len(os.listdir(gpu_src+'/egl'))} "
             f"libs={len(os.listdir(gpu_src+'/lib'))} va_drivers={','.join(va_drivers) or 'none'}")
        if vulkan_available:
            os.makedirs(f"{RUN_ROOT}/vendor/lib64/hw", exist_ok=True)
            core.stage_bulk(vulkan_src, f"{RUN_ROOT}/vendor/lib64/hw/vulkan.rhizo.so", 0o644)
            kmsg("Vulkan ICD staged at /vendor/lib64/hw/vulkan.rhizo.so, ro.hardware.vulkan=rhizo")
    else:
        kmsg(f"GPU driver is missing at {gpu_src}")
    GPU_DRIVER_32_DIR = core.gpu_driver_32_dir()
    gpu_src_32 = beside(GPU_DRIVER_32_DIR)
    if os.path.isdir(gpu_src_32):
        os.makedirs(f"{RUN_ROOT}/vendor/lib/egl", exist_ok=True)
        for f in os.listdir(f"{gpu_src_32}/egl"):
            core.stage_bulk(f"{gpu_src_32}/egl/{f}", f"{RUN_ROOT}/vendor/lib/egl/{f}", 0o644)
        for f in os.listdir(f"{gpu_src_32}/lib"):
            core.stage_bulk(f"{gpu_src_32}/lib/{f}", f"{RUN_ROOT}/vendor/lib/{f}", 0o644)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/lib/egl(/.*)?          u:object_r:same_process_hal_file:s0\n"
            "/vendor/lib/libgallium_dri\\.so u:object_r:same_process_hal_file:s0\n"
            "/vendor/lib/libdrm\\.so         u:object_r:same_process_hal_file:s0\n"
            "/vendor/lib/libgbm_mesa\\.so    u:object_r:same_process_hal_file:s0\n"
            "/vendor/lib/libcutils\\.so      u:object_r:same_process_hal_file:s0\n"
            "/vendor/lib/libhardware\\.so    u:object_r:same_process_hal_file:s0\n"
            "/vendor/lib/libz\\.so           u:object_r:same_process_hal_file:s0\n"
            "/vendor/lib/libbase\\.so        u:object_r:same_process_hal_file:s0\n"
            "/vendor/lib/libc\\+\\+\\.so      u:object_r:same_process_hal_file:s0\n"
        )
        if os.path.exists(f"{gpu_src_32}/lib/libdrm_amdgpu.so"):
            open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
                "/vendor/lib/libdrm_amdgpu\\.so  u:object_r:same_process_hal_file:s0\n")
        kmsg(f"32-bit Mesa GPU driver staged egl={len(os.listdir(gpu_src_32+'/egl'))} "
             f"libs={len(os.listdir(gpu_src_32+'/lib'))}")
    else:
        kmsg(f"32-bit GPU driver is missing at {gpu_src_32}")
    gfx_src_32 = beside("gfx_hal_32")
    if os.path.isdir(gfx_src_32):
        os.makedirs(f"{RUN_ROOT}/vendor/lib/hw", exist_ok=True)
        mapper_src_32 = f"{gfx_src_32}/mapper.rhizo.so"
        if os.path.exists(mapper_src_32):
            core.stage_bulk(mapper_src_32, f"{RUN_ROOT}/vendor/lib/hw/mapper.rhizo.so", 0o644)
            open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
                "/vendor/lib/hw/mapper\\.rhizo\\.so u:object_r:same_process_hal_file:s0\n"
            )
            kmsg("32-bit mapper.rhizo.so staged at /vendor/lib/hw")
        else:
            kmsg(f"32-bit mapper.rhizo.so is missing at {mapper_src_32}")
    else:
        kmsg(f"gfx_hal_32 is missing at {gfx_src_32}")
    os.makedirs(f"{RUN_ROOT}/system_ext_upper/bin/hw", exist_ok=True)
    os.makedirs(f"{RUN_ROOT}/system_ext_upper/etc/init", exist_ok=True)
    os.makedirs(f"{RUN_ROOT}/vendor/etc", exist_ok=True)
    _input_policy = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    open(f"{RUN_ROOT}/vendor/etc/input-port-associations.xml", "w").write(
        input_port_associations_xml(SANDBOX_ID, _input_policy.scope("rhizo.profile") == "server")
    )
    os.makedirs(f"{RUN_ROOT}/vendor/usr/idc", exist_ok=True)
    for n in range(1, 9):
        internal = "device.internal = 1\n" if n == 1 else ""
        open(f"{RUN_ROOT}/vendor/usr/idc/rhizo-touch-{n}.idc", "w").write(
            "touch.deviceType = touchScreen\ntouch.orientationAware = 0\n" + internal
        )
        open(f"{RUN_ROOT}/vendor/usr/idc/rhizo-keyboard-{n}.idc", "w").write(
            "keyboard.layout = Generic\n" + ("keyboard.builtIn = 1\n" if n == 1 else "")
        )
    os.makedirs(f"{RUN_ROOT}/product_upper/etc/permissions", exist_ok=True)
    open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-secondary-displays.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<permissions>\n"
        '    <feature name="android.software.activities_on_secondary_displays" />\n'
        "</permissions>\n"
    )
    if GSI_DEBUGGABLE:
        open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-device-admin.xml", "w").write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            "<permissions>\n"
            '    <feature name="android.software.device_admin" />\n'
            "</permissions>\n"
        )
    open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-keystore-app-attest-key.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<permissions>\n"
        '    <feature name="android.hardware.keystore.app_attest_key" />\n'
        "</permissions>\n"
    )
    open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-hardware-keystore.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<permissions>\n"
        '    <feature name="android.hardware.hardware_keystore" version="400" />\n'
        "</permissions>\n"
    )
    open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-security-model-compatible.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<permissions>\n"
        '    <feature name="android.hardware.security.model.compatible" />\n'
        "</permissions>\n"
    )
    open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-unavailable-features.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<permissions>\n"
        '    <unavailable-feature name="android.software.live_wallpaper" />\n'
        "</permissions>\n"
    )
    open(f"{RUN_ROOT}/product_upper/etc/permissions/rhizo-hardware-features.xml", "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<permissions>\n"
        '    <feature name="android.hardware.opengles.aep" />\n'
        '    <feature name="android.hardware.audio.output" />\n'
        '    <feature name="android.hardware.microphone" />\n'
        '    <feature name="android.hardware.faketouch" />\n'
        '    <feature name="android.hardware.screen.landscape" />\n'
        '    <feature name="android.hardware.screen.portrait" />\n'
        "</permissions>\n"
    )
    km_src = beside("rhizo-keymint-service")
    km_dst = f"{RUN_ROOT}/vendor/bin/hw/rhizo-keymint-service"
    if os.path.exists(km_src):
        core.stage_bulk(km_src, km_dst, 0o755)
        open(f"{RUN_ROOT}/vendor/etc/init/rhizo-keymint.rc","w").write(
            core.early_init_restorecon("/vendor/bin/hw/rhizo-keymint-service") +
            "\n"
            "service vendor.rhizo-keymint /vendor/bin/hw/rhizo-keymint-service\n"
            "    class early_hal\n"
            "    user nobody\n"
            "    stdio_to_kmsg\n"
        )
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/vendor/bin/hw/rhizo-keymint-service u:object_r:rhizo_keymint_exec:s0\n"
        )
        kmsg("rhizo-keymint-service staged on /vendor/bin/hw")
    else:
        kmsg(f"rhizo-keymint-service is missing at {km_src}")
    probed_src = beside("rhizo-probed")
    probed_dst = f"{RUN_ROOT}/system_ext_upper/bin/hw/rhizo-probed"
    if os.path.exists(probed_src):
        import shutil as _shprobed
        os.makedirs(os.path.dirname(probed_dst), exist_ok=True)
        _shprobed.copy(probed_src, probed_dst)
        os.chmod(probed_dst, 0o755)
        _probed_rc = guest_files.read("init/probed.rc")
        if os.environ.get("RHIZO_ESCAPE_PROBE") == "1":
            _probed_rc = _probed_rc.replace("    user shell\n", "    user root\n")
            kmsg("RHIZO_MARKER escape_probe=armed")
        open(f"{RUN_ROOT}/system_ext_upper/etc/init/rhizo-probed.rc","w").write(_probed_rc)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts", "a").write(
            "/system_ext/bin/hw/rhizo-probed u:object_r:rhizo_probed_exec:s0\n"
        )
        kmsg("rhizo-probed staged on /system_ext/bin/hw")
    else:
        kmsg(f"rhizo-probed is missing at {probed_src}")
    os.makedirs(f"{RUN_ROOT}/system_ext_upper/lib64", exist_ok=True)
    os.makedirs(f"{RUN_ROOT}/vendor/lib64/hw", exist_ok=True)


def setup_loop_and_netfilter():
    """load the kernel modules and attach vbmeta.img to a loop"""
    phase("B", "setup_loop_and_netfilter")
    os.makedirs(NEWROOT, exist_ok=True)
    os.system("modprobe loop 2>/dev/null; modprobe dm-mod 2>/dev/null; modprobe dm-verity 2>/dev/null")
    core.load_needed_modules()
    _nf_mod_dir = f"/lib/modules/{os.uname().release}/kernel/net"
    _nf_mods = set()
    for _sub in ("netfilter", "ipv4/netfilter", "ipv6/netfilter", "xfrm", "key"):
        _d = f"{_nf_mod_dir}/{_sub}"
        if os.path.isdir(_d):
            for _f in os.listdir(_d):
                if _f.endswith(".ko") or ".ko." in _f:
                    _nf_mods.add(_f.split(".ko")[0])
    if _nf_mods:
        _nf_resident = lambda m: os.path.isdir(f"/sys/module/{m.replace('-', '_')}")
        _nf_missing = sorted(m for m in _nf_mods if not _nf_resident(m))
        if _nf_missing:
            subprocess.run(["modprobe", "-a"] + _nf_missing, capture_output=True)
        kmsg(f"netfilter modules resident={len(_nf_mods) - len(_nf_missing)} loaded={len(_nf_missing)}")
    else:
        kmsg(f"0 netfilter .ko files under {_nf_mod_dir}")
    for i in range(16):
        os.system(f"[ -e /dev/loop{i} ] || mknod /dev/loop{i} b 7 {i} 2>/dev/null")
    vbmeta_src = beside("vbmeta.img")
    if os.environ.get("RHIZO_POLICY_ONLY") == "1":
        kmsg("skipped vbmeta.img with RHIZO_POLICY_ONLY=1")
    elif os.path.exists(vbmeta_src):
        try:
            _vb_dev, _vb_fd = core.loop_attach(vbmeta_src)
            os.close(_vb_fd)
            core.set_vbmeta_loop_dev(_vb_dev)
            kmsg(f"vbmeta.img loop-attached at {core.VBMETA_LOOP_DEV}")
        except Exception as e:
            kmsg(f"failed to attach vbmeta.img ({e})")
        if core.VBMETA_LOOP_DEV:
            ident = vbmeta_loop_identity(core.VBMETA_LOOP_DEV)
            try:
                if ident is None:
                    raise OSError(f"failed to read the diskseq of {core.VBMETA_LOOP_DEV}")
                with open(VBMETA_LOOP_FILE, "w") as f:
                    f.write(ident)
            except OSError as e:
                kmsg(f"failed to write {VBMETA_LOOP_FILE} ({e})")
    else:
        kmsg("vbmeta.img is missing")
    os.makedirs(f"{RUN_ROOT}/apex_override", exist_ok=True)
    _apex_staged_on_disk = False
    global _APEX_OVERRIDE_PREPARED
    _APEX_OVERRIDE_PREPARED = False
    _prepared = core.prepared_key()
    if _prepared:
        _apex_src = f"{PREPARED_ROOT}/{_prepared}/apex_override"
        if (core.bind_private(_apex_src, f"{RUN_ROOT}/apex_override")
                and mount(None, f"{RUN_ROOT}/apex_override", None, MS_BIND | MS_REMOUNT | MS_RDONLY)):
            _APEX_OVERRIDE_PREPARED = True
            kmsg(f"bound apex_override read-only from prepared tree {_prepared}")
        else:
            kmsg("failed to bind the prepared apex_override")
    if not _APEX_OVERRIDE_PREPARED:
        try:
            import shutil as _sh_a
            if core.unmount_under(RHIZO_APEX_DIR) < 0:
                raise OSError(f"failed to unmount the mounts under {RHIZO_APEX_DIR}")
            _sh_a.rmtree(RHIZO_APEX_DIR, ignore_errors=True)
            os.makedirs(RHIZO_APEX_DIR, mode=0o755, exist_ok=True)
            _apex_staged_on_disk = core.bind_private(RHIZO_APEX_DIR, f"{RUN_ROOT}/apex_override")
        except OSError as e:
            kmsg(f"failed to set up {RHIZO_APEX_DIR} ({e})")
        kmsg(f"apex_override staging on "
             f"{'real disk ' + RHIZO_APEX_DIR if _apex_staged_on_disk else 'tmpfs'}")


def host_refuses_android_labels():
    """return whether selinux_ns.host_context() contains a colon in namespace mode"""
    return not host_selinux_mode() and ":" in selinux_ns.host_context()


def _stage_tethering_apex(dest_file, try_align=True, label=True):
    """stage the patched tethering apex to dest_file"""
    apex_src = beside("com.android.tethering.apex")
    if not os.path.exists(apex_src):
        return False, False
    import shutil as _sh3
    aligned = False
    if try_align:
        _aligner = beside("align-apex.py")
        if os.path.exists(_aligner):
            _r = subprocess.run([sys.executable, _aligner, apex_src, dest_file],
                                capture_output=True, text=True)
            aligned = _r.returncode == 0
            if not aligned:
                kmsg(f"align-apex.py failed rc={_r.returncode} ({_r.stderr.strip()[:200]})")
    if not aligned:
        _sh3.copy(apex_src, dest_file)
    try:
        if label:
            os.setxattr(dest_file, "security.selinux", b"u:object_r:system_file:s0\0")
    except OSError as e:
        kmsg(f"setxattr failed on the tethering apex ({e})")
    return True, aligned


ORIGINAL_APEX_ENTRY = "original_apex"


def _stage_decompressed_apexes(apex_dir, dest_dir, log=kmsg, label=True):
    """extract each .capex's original_apex into dest_dir"""
    import shutil as _sh_d
    import zipfile
    staged, failed = [], []
    try:
        names = sorted(os.listdir(apex_dir))
    except OSError as e:
        return staged, [f"{apex_dir} ({e})"]
    for name in names:
        if not name.endswith(".capex"):
            continue
        dest = os.path.join(dest_dir, name[:-len(".capex")] + ".apex")
        if os.path.exists(dest):
            continue
        src = os.path.join(apex_dir, name)
        part = dest + ".part"
        try:
            with zipfile.ZipFile(src) as zf, zf.open(ORIGINAL_APEX_ENTRY) as entry, \
                    open(part, "wb") as out:
                _sh_d.copyfileobj(entry, out, 1 << 20)
            os.chmod(part, 0o644)
            os.utime(part, (0, 0))
            os.replace(part, dest)
        except (OSError, KeyError, zipfile.BadZipFile) as e:
            failed.append(f"{name} ({e})")
            try:
                os.unlink(part)
            except OSError:
                pass
            continue
        try:
            if label:
                os.setxattr(dest, "security.selinux", b"u:object_r:system_file:s0\0")
        except OSError as e:
            log(f"setxattr failed on {os.path.basename(dest)} ({e})")
        core.record_prepare_input(src, dest)
        staged.append(os.path.basename(dest))
    return staged, failed


def stage_apex_and_patches():
    """stage rhizo's patches over the stock gsi content"""
    phase("B", "stage_apex_and_patches")
    _labels_refused = host_refuses_android_labels()
    if _APEX_OVERRIDE_PREPARED:
        kmsg("skipped the tethering apex with the prepared apex_override")
    elif os.path.exists(beside("com.android.tethering.apex")):
        _apex_dest = f"{RUN_ROOT}/apex_override/com.android.tethering.apex"
        staged, aligned = _stage_tethering_apex(_apex_dest, label=not _labels_refused)
        if not aligned:
            _apex_left = core.umount_tree(f"{RUN_ROOT}/apex_override")
            os.makedirs(f"{RUN_ROOT}/apex_override", exist_ok=True)
            if _apex_left or core.is_mount_point(f"{RUN_ROOT}/apex_override"):
                kmsg("failed to unmount apex_override after the align failure")
            staged, aligned = _stage_tethering_apex(_apex_dest, try_align=False, label=not _labels_refused)
        kmsg(f"tethering apex staged "
             f"{'4096-aligned on disk' if aligned else 'unaligned on tmpfs'}")
    else:
        kmsg("com.android.tethering.apex is missing")
    if not _APEX_OVERRIDE_PREPARED:
        _t_apex = time.monotonic()
        _staged, _failed = _stage_decompressed_apexes(f"{GSI}/apex", f"{RUN_ROOT}/apex_override",
                                                      label=not _labels_refused)
        kmsg(f"extracted {len(_staged)} .capex payloads in {time.monotonic() - _t_apex:.1f}s"
             + (f", failed on {len(_failed)} {_failed}" if _failed else ""))
    phase("B", "stage_apex_and_patches.audioserver_and_rc")
    os.makedirs(f"{RUN_ROOT}/system_upper/etc/init/hw", exist_ok=True)
    mydir = os.path.dirname(os.path.abspath(__file__))
    _camera = core.camera_armed()
    for rel_name in ("etc/init/netd.rc", "etc/init/surfaceflinger.rc",
                      "etc/init/hw/init.zygote64_32.rc", "etc/init/hw/init.zygote64.rc",
                      "etc/init/vold.rc",
                      "etc/init/audioserver.rc", "etc/init/mediametrics.rc",
                      "etc/init/cameraserver.rc",
                      "system_ext/etc/gsi/init.vndk-nodef.rc"):
        if _camera and rel_name == "etc/init/cameraserver.rc":
            kmsg("devices.camera is on, skipped the cameraserver.rc patch")
            continue
        _base = os.path.basename(rel_name)
        _patches = core.stock_patches_dir()
        src = os.path.join(_patches, _base) if _patches else ""
        if not os.path.exists(src):
            src = os.path.join(mydir, _base)
        dst = f"{RUN_ROOT}/system_upper/{rel_name}"
        if os.path.exists(src):
            import shutil as _sh4
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            _sh4.copy(src, dst)
            kmsg(f"patched {rel_name} staged")
        else:
            kmsg(f"patched {rel_name} is missing at {src}")
    phase("B", "stage_apex_and_patches.apks_and_scripts")
    os.makedirs(f"{RUN_ROOT}/system_ext_upper/etc/permissions", exist_ok=True)
    open(f"{RUN_ROOT}/system_ext_upper/etc/permissions/android.software.app_widgets.xml",
         "w").write(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<permissions>\n'
        '    <feature name="android.software.app_widgets" />\n'
        '</permissions>\n'
    )
    router_apk_src = beside("RhizoAudioRouter.apk")
    if core.release_skips("RhizoAudioRouter.apk"):
        kmsg(f"skipped RhizoAudioRouter.apk for release {RHIZO_RELEASE}")
    elif os.path.exists(router_apk_src):
        import shutil as _shar
        os.makedirs(f"{RUN_ROOT}/system_ext_upper/priv-app/RhizoAudioRouter", exist_ok=True)
        _shar.copy(router_apk_src,
                   f"{RUN_ROOT}/system_ext_upper/priv-app/RhizoAudioRouter/RhizoAudioRouter.apk")
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/system_ext/priv-app/RhizoAudioRouter/RhizoAudioRouter\\.apk u:object_r:system_file:s0\n"
            "/data/rhizo_audio_map(/.*)? u:object_r:rhizo_audiomap_file:s0\n")
        open(f"{RUN_ROOT}/system_ext_upper/etc/permissions/privapp-permissions-rhizo.xml",
             "w").write(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<permissions>\n'
            '    <privapp-permissions package="com.rhizo.audiorouter">\n'
            '        <permission name="android.permission.MODIFY_AUDIO_ROUTING"/>\n'
            '    </privapp-permissions>\n'
            '</permissions>\n'
        )
        kmsg("RhizoAudioRouter staged on system_ext priv-app with privapp-permissions-rhizo.xml")
    else:
        kmsg(f"RhizoAudioRouter.apk is missing at {router_apk_src}")
    boot_rro_src = beside("RhizoBootRro.apk")
    if os.path.exists(boot_rro_src):
        import shutil as _shbo
        os.makedirs(f"{RUN_ROOT}/system_ext_upper/overlay", exist_ok=True)
        _shbo.copy(boot_rro_src, f"{RUN_ROOT}/system_ext_upper/overlay/RhizoBootRro.apk")
        os.chmod(f"{RUN_ROOT}/system_ext_upper/overlay/RhizoBootRro.apk", 0o644)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/system_ext/overlay/RhizoBootRro\\.apk u:object_r:vendor_overlay_file:s0\n")
        kmsg("RhizoBootRro.apk staged on system_ext overlay")
    else:
        kmsg(f"RhizoBootRro.apk is missing at {boot_rro_src}")
    settings_rro_src = beside("RhizoSettingsRro.apk")
    if os.path.exists(settings_rro_src):
        os.makedirs(f"{RUN_ROOT}/system_ext_upper/overlay", exist_ok=True)
        core.stage_bulk(settings_rro_src, f"{RUN_ROOT}/system_ext_upper/overlay/RhizoSettingsRro.apk", 0o644)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/system_ext/overlay/RhizoSettingsRro\\.apk u:object_r:vendor_overlay_file:s0\n")
        kmsg("RhizoSettingsRro.apk staged on system_ext overlay")
    else:
        kmsg(f"RhizoSettingsRro.apk is missing at {settings_rro_src}")
    settingsprovider_rro_src = beside("RhizoSettingsProviderRro.apk")
    if os.path.exists(settingsprovider_rro_src):
        os.makedirs(f"{RUN_ROOT}/system_ext_upper/overlay", exist_ok=True)
        core.stage_bulk(settingsprovider_rro_src,
                             f"{RUN_ROOT}/system_ext_upper/overlay/RhizoSettingsProviderRro.apk", 0o644)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/system_ext/overlay/RhizoSettingsProviderRro\\.apk u:object_r:vendor_overlay_file:s0\n")
        kmsg("RhizoSettingsProviderRro.apk staged on system_ext overlay")
    else:
        kmsg(f"RhizoSettingsProviderRro.apk is missing at {settingsprovider_rro_src}")
    stage_software_rro()
    home_apk_src = beside("RhizoHome.apk")
    if os.path.exists(home_apk_src):
        import shutil as _shho
        os.makedirs(f"{RUN_ROOT}/system_ext_upper/priv-app/RhizoHome", exist_ok=True)
        _shho.copy(home_apk_src, f"{RUN_ROOT}/system_ext_upper/priv-app/RhizoHome/RhizoHome.apk")
        os.chmod(f"{RUN_ROOT}/system_ext_upper/priv-app/RhizoHome/RhizoHome.apk", 0o644)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/system_ext/priv-app/RhizoHome/RhizoHome\\.apk u:object_r:system_file:s0\n")
        kmsg("RhizoHome.apk staged on system_ext priv-app")
    else:
        kmsg(f"RhizoHome.apk is missing at {home_apk_src}")
    overlay_apk_src = beside("RhizoLockIconOverlay.apk")
    if os.environ.get("RHIZO_STAGE_ICON_OVERLAY") == "1" and os.path.exists(overlay_apk_src):
        import shutil as _shro
        os.makedirs(f"{RUN_ROOT}/system_ext_upper/overlay", exist_ok=True)
        _shro.copy(overlay_apk_src, f"{RUN_ROOT}/system_ext_upper/overlay/RhizoLockIconOverlay.apk")
        os.chmod(f"{RUN_ROOT}/system_ext_upper/overlay/RhizoLockIconOverlay.apk", 0o644)
        open(f"{RUN_ROOT}/vendor/etc/selinux/vendor_file_contexts","a").write(
            "/system_ext/overlay/RhizoLockIconOverlay\\.apk u:object_r:vendor_overlay_file:s0\n")
        kmsg("RhizoLockIconOverlay.apk staged on system_ext overlay")
    import shutil as _shli
    guest_src = guest_files.path("bin/launch-app.sh")
    guest_dst = f"{RUN_ROOT}/system_ext_upper/bin/rhizo-launch-app.sh"
    os.makedirs(os.path.dirname(guest_dst), exist_ok=True)
    _shli.copy(guest_src, guest_dst)
    kmsg("rhizo-launch-app.sh staged on system_ext")
    guest_src2 = guest_files.path("bin/add-pool-display.sh")
    guest_dst2 = f"{RUN_ROOT}/system_ext_upper/bin/rhizo-add-pool-display.sh"
    _shli.copy(guest_src2, guest_dst2)
    kmsg("rhizo-add-pool-display.sh staged on system_ext")
    guest_src3 = guest_files.path("bin/layerstack-guard.sh")
    guest_dst3 = f"{RUN_ROOT}/system_ext_upper/bin/rhizo-layerstack-guard.sh"
    _shli.copy(guest_src3, guest_dst3)
    kmsg("rhizo-layerstack-guard.sh staged on system_ext")
    _shli.copy(guest_files.path("bin/task-bounds.sh"), f"{RUN_ROOT}/system_ext_upper/bin/rhizo-task-bounds.sh")
    kmsg("rhizo-task-bounds.sh staged on system_ext")


def stage_loop_unbound_udev_rule():
    """stage the loop udev rule and reload udev"""
    import shutil as _shloop
    os.makedirs("/etc/udev/rules.d", exist_ok=True)
    _shloop.copy(beside("rhizo-loop-unbound.rules"),
                 "/etc/udev/rules.d/59-rhizo-loop-unbound.rules")
    subprocess.run(["udevadm", "control", "--reload"], check=False)


def privileged_setup():
    """build the sandbox's filesystem and policy as root"""
    stage_loop_unbound_udev_rule()
    prepare_host_and_data()
    codec2.plan()
    sensors.plan()
    wifi.plan()
    stage_selinux_contexts(compile_sepolicy())
    stage_vendor_tree()
    stage_hals()
    stage_camera()
    stage_sensors()
    stage_virtual_device()
    if os.environ.get("RHIZO_POLICY_ONLY") == "1":
        kmsg("skipped aurora and gapps with RHIZO_POLICY_ONLY=1")
    else:
        stage_aurora()
        gapps_refused = stage_gapps()
        if gapps_refused:
            refuse_start_by_name(gapps_refused)
    stage_desktop_bridge()
    stage_host_delay()
    setup_loop_and_netfilter()
    stage_apex_and_patches()
    wifi.apply_shape()
    codec2.apply_shape()












def drop_caps():
    """drop the DROP_CAPS capabilities from the bounding set"""
    for c in DROP_CAPS:
        libc.prctl(PR_CAPBSET_DROP, c, 0, 0, 0)

NET_ULA_PREFIX = os.environ.get(
    "RHIZO_ULA_PREFIX",
    "fd00:12ab:cd34::" if SANDBOX_ID == 0 else f"fd00:12ab:cd34:{SANDBOX_ID:x}::")

def rule_add_args(chain, spec, top=None):
    """return the iptables arguments adding spec to chain"""
    if top is None:
        return ["-A", chain, *spec]
    pos = top.get(chain, 1)
    top[chain] = pos + 1
    return ["-I", chain, str(pos), *spec]


DUMMY0_STEP_TIMEOUT_S = 30


def add_android_dummy0(netns_pid, run=subprocess.run):
    """create dummy0 in the sandbox's netns"""
    for reason, cmd in (("modprobe", ["modprobe", "dummy", "numdummies=0"]),
                        ("link-add", ["nsenter", "-t", str(netns_pid), "-n", "ip", "link", "add", "dummy0",
                                      "type", "dummy"])):
        try:
            r = run(cmd, capture_output=True, text=True, timeout=DUMMY0_STEP_TIMEOUT_S)
            err = f"rc={r.returncode} {r.stderr.strip()}" if r.returncode != 0 else ""
        except subprocess.TimeoutExpired:
            err = f"timeout after {DUMMY0_STEP_TIMEOUT_S}s"
        except OSError as e:
            err = repr(e)
        if err:
            kmsg(f"RHIZO_MARKER dummy0=failed reason={reason} {err}")
            return False
    kmsg(f"RHIZO_MARKER dummy0=created netns_pid={netns_pid}")
    return True


def setup_veth_and_nat(netns_pid):
    """set up the sandbox's veth or wireless pair and NAT"""
    POLICY = capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID)
    if not POLICY.allows("network.enabled"):
        kmsg("network.enabled is off")
        return
    HOST_IF=VETH_HOST_IF; GUEST_IF="eth0"
    HOST_ADDR=NET_HOST_ADDR; SUBNET=NET_SUBNET
    POOL_START=NET_POOL_START; POOL_END=NET_POOL_END
    GUEST_MAC=NET_GUEST_MAC
    ULA_PREFIX=NET_ULA_PREFIX
    NETBRIDGED_MAIN = wifi.netbridged_main()
    NETBRIDGED_USER = "rhizo-netbridged"
    NETBRIDGED_EXTRA_ARGS=[a for a in os.environ.get("RHIZO_NETBRIDGED_ARGS", "").split(",") if a]
    for mod in ("veth","nf_tables","nf_nat","x_tables","ip_tables","iptable_nat","iptable_filter",
                "nf_conntrack","xt_state","xt_conntrack","xt_MASQUERADE","xt_bpf",
                "ip6_tables","ip6table_nat","ip6table_filter","tun"):
        subprocess.run(["modprobe", mod], capture_output=True)
    UPLINK = None
    _route = subprocess.run(["ip", "-4", "route", "show", "default"],
                             capture_output=True, text=True)
    for _line in _route.stdout.splitlines():
        _parts = _line.split()
        if "dev" in _parts:
            UPLINK = _parts[_parts.index("dev") + 1]
            break
    if UPLINK is None:
        kmsg("no default route")
    def run(*args, check=True):
        """run a command and log a failure"""
        r = subprocess.run(list(args), capture_output=True, text=True)
        if r.returncode != 0:
            kmsg(f"{' '.join(args)} failed rc={r.returncode} ({r.stderr.strip()})")
            if check: raise RuntimeError(args)
        return r
    def ufw_chains(binary):
        """return whether ufw's before-input chain exists"""
        name = "ufw-before-input" if binary == "iptables" else "ufw6-before-input"
        return subprocess.run([binary, "-S", name], capture_output=True).returncode == 0
    tops = {b: ({} if ufw_chains(b) else None) for b in ("iptables", "ip6tables")}
    if tops["iptables"] is not None or tops["ip6tables"] is not None:
        kmsg("ufw-before-input exists")
    def add_once(binary, table, chain, *spec):
        """add an iptables rule unless iptables -C matches the rule"""
        args = [binary] + (["-t", table] if table else [])
        top = tops[binary] if table is None else None
        if run(*args, "-C", chain, *spec, check=False).returncode != 0:
            run(*args, *rule_add_args(chain, spec, top), check=False)
        elif top is not None:
            rule_add_args(chain, spec, top)
    def drop_uplink_forms(binary, source):
        """delete an older launch's NAT and FORWARD rules"""
        for table, chain in (("nat", "POSTROUTING"), (None, "FORWARD")):
            args = [binary] + (["-t", table] if table else [])
            for _line in run(*args, "-S", chain, check=False).stdout.splitlines():
                _rule = _line.split()
                if uplinks.stale_nat_rule(_rule, HOST_IF, source):
                    run(*args, "-D", *_rule[1:], check=False)
    try:
        wifi.destroy_pair(HOST_IF)
        run("ip","link","del",HOST_IF, check=False)
        TMP_GUEST_IF = f"rhzg{SANDBOX_ID}"
        run("ip","link","del",TMP_GUEST_IF, check=False)
        _pair_why = wifi.create_pair(HOST_IF, GUEST_MAC, netns_pid, NETBRIDGED_USER) if core.wifi_armed() else None
        if core.wifi_armed() and _pair_why is None:
            GUEST_IF = wifi.GUEST_WLAN_IF
        else:
            if _pair_why:
                wifi.disarm(_pair_why)
                if not wifi.clear_pair(HOST_IF):
                    kmsg(f"RHIZO_MARKER wifi_pair_stuck={HOST_IF}")
            run("ip","link","add",TMP_GUEST_IF,"address",GUEST_MAC,"type","veth","peer","name",HOST_IF)
            run("ip","link","set",TMP_GUEST_IF,"netns",str(netns_pid),"name",GUEST_IF)
        run("ip","addr","add",HOST_ADDR,"dev",HOST_IF)
        run("ip","link","set",HOST_IF,"up")
        run("nsenter","-t",str(netns_pid),"-n","ip","link","set","lo","up", check=False)
        run("sysctl","-w","net.ipv4.ip_forward=1")
        drop_uplink_forms("iptables", SUBNET)
        uplinks.ensure_chains(run, "iptables")
        uplinks.fill_chains(run, "iptables", uplinks.default_route_ifaces("-4"))
        add_once("iptables","nat","POSTROUTING","-s",SUBNET,"-j",uplinks.NAT_CHAIN)
        add_once("iptables",None,"FORWARD","-i",HOST_IF,"-j",uplinks.FWD_CHAIN)
        add_once("iptables",None,"FORWARD","-o",HOST_IF,"-m","state",
                    "--state","ESTABLISHED,RELATED","-j","ACCEPT")

        ADB_REACH = POLICY.scope("server.adb_reach")
        PROFILE = POLICY.scope("rhizo.profile")
        has_key = capabilities.has_adb_key((capabilities.OPERATOR_ADB_KEYS,))
        arm_lan = (ADB_REACH == "lan" and SANDBOX_ID == 0 and PROFILE == "server"
                   and not GSI_DEBUGGABLE
                   and not RHIZO_ADB_ROOT and not RHIZO_PERMISSIVE
                   and UPLINK is not None and has_key)
        if ADB_REACH == "lan" and not arm_lan:
            reasons = []
            if SANDBOX_ID != 0:
                reasons.append(f"RHIZO_SANDBOX_ID={SANDBOX_ID} is not 0")
                kmsg("RHIZO_MARKER adb_lan_refused=instance_above_zero")
            if PROFILE != "server":
                reasons.append(f"rhizo.profile={PROFILE} is not server")
            if GSI_DEBUGGABLE:
                reasons.append("the GSI is debuggable")
            if RHIZO_ADB_ROOT:
                reasons.append("RHIZO_ADB_ROOT is set")
            if RHIZO_PERMISSIVE:
                reasons.append("RHIZO_PERMISSIVE is set")
            if UPLINK is None:
                reasons.append("no default route")
            if not has_key:
                reasons.append(f"no operator key at {capabilities.OPERATOR_ADB_KEYS}")
            kmsg("server.adb_reach=lan refused (" + "; ".join(reasons) + ")")
        DNAT_ARGS = DNAT_FWD_ARGS = None
        if UPLINK is not None:
            DNAT_ARGS = ["-i", UPLINK, "-p", "tcp", "--dport", "5555",
                         "-j", "DNAT", "--to-destination", f"{POOL_START}:5555"]
            DNAT_FWD_ARGS = ["-i", UPLINK, "-o", HOST_IF, "-p", "tcp", "-d", POOL_START,
                             "--dport", "5555", "-j", "ACCEPT"]
        if arm_lan:
            add_once("iptables", "nat", "PREROUTING", *DNAT_ARGS)
            add_once("iptables", None, "FORWARD", *DNAT_FWD_ARGS)
            kmsg(f"server.adb_reach=lan armed DNAT {UPLINK}:5555 -> {POOL_START}:5555")
        elif DNAT_ARGS is not None:
            run("iptables", "-t", "nat", "-D", "PREROUTING", *DNAT_ARGS, check=False)
            run("iptables", "-D", "FORWARD", *DNAT_FWD_ARGS, check=False)

        NB_SERVICES = sorted(POLICY.scope("network.services"))
        PROXY_PORT = 8118
        for _nb_i, _nb_a in enumerate(NETBRIDGED_EXTRA_ARGS):
            if _nb_a == "--proxy-port" and _nb_i + 1 < len(NETBRIDGED_EXTRA_ARGS):
                try:
                    PROXY_PORT = int(NETBRIDGED_EXTRA_ARGS[_nb_i + 1])
                except ValueError:
                    pass
        DESKD_PORT = int(os.environ.get("RHIZO_DESKD_PORT", "47100"))

        def _input_allow(proto, port):
            """add an ACCEPT rule for proto traffic to port on HOST_IF"""
            spec = ["-i", HOST_IF, "-p", proto, "--dport", str(port), "-j", "ACCEPT"]
            add_once("iptables", None, "INPUT", *spec)
            add_once("ip6tables", None, "INPUT", *spec)

        for _bin in ("iptables", "ip6tables"):
            for _line in run(_bin, "-S", "INPUT", check=False).stdout.splitlines():
                _rule = _line.split()
                if _rule[:4] == ["-A", "INPUT", "-i", HOST_IF]:
                    run(_bin, "-D", *_rule[1:], check=False)

        _est_spec = ["-i", HOST_IF, "-m", "state", "--state",
                     "ESTABLISHED,RELATED", "-j", "ACCEPT"]
        add_once("iptables", None, "INPUT", *_est_spec)
        add_once("ip6tables", None, "INPUT", *_est_spec)

        for _proto, _port in capabilities.sandbox_input_ports(
                NB_SERVICES, PROXY_PORT, DESKD_PORT):
            _input_allow(_proto, _port)
        for _spec in os.environ.get("RHIZO_GATE_EXTRA_INPUT_PORTS", "").split(","):
            _spec = _spec.strip()
            if not _spec:
                continue
            _xproto, _, _xport = _spec.partition(":")
            if _xproto in ("tcp", "udp") and _xport.isdigit():
                _input_allow(_xproto, int(_xport))
        for _nd in ("router-solicitation", "neighbour-solicitation", "neighbour-advertisement"):
            add_once("ip6tables", None, "INPUT", "-i", HOST_IF, "-p", "ipv6-icmp", "--icmpv6-type", _nd,
                     "-j", "ACCEPT")
        _deny_spec = ["-i", HOST_IF, "-j", "DROP"]
        add_once("iptables", None, "INPUT", *_deny_spec)
        add_once("ip6tables", None, "INPUT", *_deny_spec)

        run("sysctl","-w","net.ipv6.conf.all.forwarding=1", check=False)
        run("sysctl","-w",f"net.ipv6.conf.{HOST_IF}.disable_ipv6=0", check=False)
        run("ip","-6","addr","add",f"{ULA_PREFIX}1/64","dev",HOST_IF, check=False)
        drop_uplink_forms("ip6tables", f"{ULA_PREFIX}/64")
        uplinks.ensure_chains(run, "ip6tables")
        uplinks.fill_chains(run, "ip6tables", uplinks.default_route_ifaces("-6"))
        add_once("ip6tables","nat","POSTROUTING","-s",f"{ULA_PREFIX}/64","-j",uplinks.NAT_CHAIN)
        add_once("ip6tables",None,"FORWARD","-i",HOST_IF,"-j",uplinks.FWD_CHAIN)
        add_once("ip6tables",None,"FORWARD","-o",HOST_IF,"-m","state",
                    "--state","ESTABLISHED,RELATED","-j","ACCEPT")

        try:
            run("systemctl", "stop", f"{NETBRIDGED_UNIT}.service", check=False)
            run("systemctl", "reset-failed", f"{NETBRIDGED_UNIT}.service", check=False)
            try:
                os.unlink(NETBRIDGED_LOG)
            except FileNotFoundError:
                pass
            uplinks.stop_unit(run)
            try:
                uplinks.start_unit(run)
            except Exception as e:
                kmsg(f"RHIZO_MARKER nat_uplinks_start_failed=1 ({e})")
            wifi.stop_push_unit(run)
            if core.wifi_armed():
                try:
                    wifi.start_push_unit(run)
                except Exception as e:
                    kmsg(f"RHIZO_MARKER wifi_push_start_failed=1 ({e})")
            run("systemd-run", f"--unit={NETBRIDGED_UNIT}", "--collect",
                "-p", f"RuntimeDirectory={NETBRIDGED_RUNTIME_DIR}",
                "-p", f"User={NETBRIDGED_USER}",
                "-p", "CapabilityBoundingSet=CAP_NET_RAW CAP_NET_BIND_SERVICE",
                "-p", "AmbientCapabilities=CAP_NET_RAW CAP_NET_BIND_SERVICE",
                "-p", "NoNewPrivileges=yes",
                "-p", f"StandardOutput=file:{NETBRIDGED_LOG}",
                "-p", f"StandardError=file:{NETBRIDGED_LOG}",
                "python3", NETBRIDGED_MAIN,
                "--veth-if", HOST_IF, "--veth-addr", HOST_ADDR.split("/")[0],
                "--subnet", SUBNET, "--uplink", UPLINK or "",
                "--pool-start", POOL_START, "--pool-end", POOL_END,
                "--ula-prefix", ULA_PREFIX,
                "--services", ",".join(NB_SERVICES),
                "--proxy-connect-policy", POLICY.scope("network.proxy_connect"),
                "--state-dir", f"/run/{NETBRIDGED_RUNTIME_DIR}",
                *wifi.netbridged_args(POLICY),
                *NETBRIDGED_EXTRA_ARGS,
                check=True)
        except Exception as e:
            kmsg(f"RHIZO_MARKER netbridged_start_failed=1 ({e})")
        kmsg(f"{'wireless pair' if core.wifi_armed() else 'veth'} {GUEST_IF} netns_pid={netns_pid} "
             f"{HOST_IF}={HOST_ADDR} nat={uplinks.FWD_CHAIN}/{uplinks.NAT_CHAIN} "
             f"default_route={UPLINK or '<none>'} ula={ULA_PREFIX}/64")
        return True
    except Exception as e:
        kmsg(f"RHIZO_MARKER veth_setup_failed=1 ({e})")
        return False

def report_netbridged_liveness():
    """log the NB_READY line from NETBRIDGED_LOG"""
    deadline = time.time() + 2.0
    ready = ""
    while time.time() < deadline:
        try:
            with open(NETBRIDGED_LOG) as f:
                for line in f:
                    if "NB_READY " in line:
                        ready = line.strip()
                        break
        except OSError:
            pass
        if ready:
            break
        time.sleep(0.1)
    if ready:
        kmsg(f"netbridged {ready}")
    else:
        kmsg(f"no NB_READY line in {NETBRIDGED_LOG}")

_NOTIFY_SOCK = None

def connect_notify_socket():
    """connect $NOTIFY_SOCKET in the host mount namespace"""
    global _NOTIFY_SOCK
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr[0] == "@": addr = "\0" + addr[1:]
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.connect(addr)
        _NOTIFY_SOCK = s
    except OSError as e:
        kmsg(f"failed to connect {addr!r} ({e})")

def sd_notify(msg):
    """write msg to $NOTIFY_SOCKET with sendall"""
    if _NOTIFY_SOCK is not None:
        try:
            _NOTIFY_SOCK.sendall(msg.encode())
            return True
        except OSError as e:
            kmsg(f"sendall {msg!r} failed on the connected notify socket ({e})")
            return False
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr: return False
    if addr[0] == "@": addr = "\0" + addr[1:]
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        s.connect(addr)
        s.sendall(msg.encode())
        s.close()
        return True
    except OSError as e:
        kmsg(f"sendall {msg!r} failed ({e})")
        return False

class BootMarkerWatch:
    """/dev/kmsg reader for the launch_start and boot_completed markers"""

    def __init__(self, read=None, path="/dev/kmsg", batch=16384):
        """store the record source, path and batch size"""
        self._read, self._path, self._batch = read, path, batch
        self._fd = None
        self.anchored = False
        self._completed = False
        self.done = False

    def _next(self):
        """return a /dev/kmsg record, or None on EAGAIN"""
        if self._read is not None:
            try:
                return self._read(65536) or None
            except BlockingIOError:
                return None
        if self._fd is None:
            self._fd = os.open(self._path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
        while True:
            try:
                return os.read(self._fd, 65536) or None
            except BlockingIOError:
                return None
            except OSError as e:
                if e.errno != errno.EPIPE:
                    raise

    def seen(self):
        """return whether MARKER_BOOT_COMPLETED follows the last MARKER_LAUNCH_START"""
        if self.done:
            return True
        try:
            for _ in range(self._batch):
                rec = self._next()
                if rec is None:
                    self.done = self._completed
                    break
                starts = [m.end() for m in MARKER_LAUNCH_START.finditer(rec)]
                if starts:
                    self.anchored, self._completed = True, False
                if self.anchored and MARKER_BOOT_COMPLETED.search(rec, starts[-1] if starts else 0):
                    self._completed = True
        except OSError:
            return False
        return self.done


def _relabel_prepared_vendor(vendor_root):
    """label the bin, lib and lib64 files under vendor_root from the file_contexts files"""
    fc_paths = [f"{GSI}/etc/selinux/plat_file_contexts",
                f"{GSI}/system_ext/etc/selinux/system_ext_file_contexts",
                f"{GSI}/product/etc/selinux/product_file_contexts",
                os.path.join(vendor_root, "etc", "selinux", "vendor_file_contexts")]
    entries = []
    lines = []
    for fc_path in fc_paths:
        try:
            lines += open(fc_path, errors="replace").read().splitlines()
        except OSError as e:
            kmsg(f"failed to read {fc_path} ({e})")
            return 0, 0, 1
    for ln in lines:
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        parts = ln.split()
        if len(parts) < 2:
            continue
        pat, lbl = parts[0], parts[-1]
        m = re.search(r"[.\[\](){}*+?|^$\\]", pat)
        stem = len(pat) if m is None else m.start()
        try:
            rx = re.compile(pat + r"\Z")
        except re.error:
            continue
        entries.append((rx, stem, lbl))

    def expected(android_path):
        """return the label of the longest matching entry"""
        best = None
        for i, (rx, stem, lbl) in enumerate(entries):
            if rx.match(android_path):
                if best is None or (stem, i) > best[0]:
                    best = ((stem, i), lbl)
        return best[1] if best else None

    labeled, unmatched, failed = 0, 0, 0
    for sub in ("bin", "lib", "lib64"):
        root = os.path.join(vendor_root, sub)
        if not os.path.isdir(root):
            continue
        hosts = [root] + [os.path.join(dp, n)
                           for dp, dns, fns in os.walk(root) for n in dns + fns]
        for host in hosts:
            android_path = "/vendor" + host[len(vendor_root):]
            lbl = expected(android_path)
            if lbl is None:
                unmatched += 1
                continue
            want = (lbl + "\0").encode()
            follow = not os.path.islink(host)
            try:
                cur = os.getxattr(host, "security.selinux", follow_symlinks=follow)
            except OSError:
                cur = None
            if cur == want:
                continue
            try:
                os.setxattr(host, "security.selinux", want, follow_symlinks=follow)
                labeled += 1
            except OSError as e:
                kmsg(f"setxattr failed on {host} ({e})")
                failed += 1
    return labeled, unmatched, failed


def _build_prepared_manifest(tree_part, recorded_inputs):
    """return the manifest.json prepare-tree writes"""
    inputs = {}
    for src, _dst in recorded_inputs:
        if src in inputs:
            continue
        try:
            inputs[src] = core.input_meta(src)
        except OSError as e:
            kmsg(f"failed to read input {src} ({e})")

    outputs = {}
    for sub in ("bin", "lib", "lib64"):
        root = os.path.join(tree_part, "vendor", sub)
        if not os.path.isdir(root):
            continue
        paths = [root] + [os.path.join(dp, n)
                           for dp, dns, fns in os.walk(root) for n in dns + fns]
        for path in paths:
            outputs[os.path.relpath(path, tree_part)] = core.output_meta(path)
    apex_override_dir = os.path.join(tree_part, "apex_override")
    if os.path.isdir(apex_override_dir):
        for name in sorted(os.listdir(apex_override_dir)):
            outputs[f"apex_override/{name}"] = core.output_meta(
                os.path.join(apex_override_dir, name))

    key_material = [core.PREPARED_LAYOUT_VERSION, GSI_FINGERPRINT,
                     os.uname().release]
    key_material += sorted(f"{src} {meta['sha256']}" for src, meta in inputs.items())
    key = hashlib.sha256("\n".join(key_material).encode()).hexdigest()[:12]

    return {
        "key": key,
        "layout_version": core.PREPARED_LAYOUT_VERSION,
        "gsi_fingerprint": GSI_FINGERPRINT,
        "kernel": os.uname().release,
        "gpu_driver": core.gpu_driver_dir(),
        "inputs": inputs,
        "outputs": outputs,
        "created_at": time.time(),
    }


def _sandbox_is_live():
    """return whether the INIT_PID_FILE pid exists"""
    try:
        pid = int(open(INIT_PID_FILE).read().strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return True
    return True


UNMOUNT_TREE_TRIES = 8
RUN_ROOT_UNMOUNT_TRIES = 64


def _remove_tree(path):
    """remove the tree at path"""
    import shutil
    try:
        shutil.rmtree(path)
    except FileNotFoundError:
        return None
    except OSError as e:
        kmsg(f"failed to remove {path} ({e})")
        return f"remove:{path}"
    return None


def fd_mount_id(fd):
    """return the mount id of fd"""
    with open(f"/proc/self/fdinfo/{fd}") as f:
        for line in f:
            if line.startswith("mnt_id:"):
                return int(line.split()[1])
    raise OSError(errno.ENOENT, f"/proc/self/fdinfo/{fd} has no mnt_id")


DIR_OPEN_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def _empty_dir(path):
    """remove the contents of path"""
    try:
        fd = os.open(path, DIR_OPEN_FLAGS)
    except FileNotFoundError:
        return None
    except OSError as e:
        kmsg(f"failed to open {path} as a directory ({e})")
        return f"not-a-directory:{path}"
    try:
        return _remove_under(path, path, fd, fd_mount_id(fd))
    except OSError as e:
        kmsg(f"failed to empty {path} ({e})")
        return f"remove:{path}"
    finally:
        os.close(fd)


def _remove_under(top, path, dir_fd, mount_id):
    """remove the contents of dir_fd on mount mount_id"""
    import stat
    try:
        names = os.listdir(dir_fd)
    except OSError as e:
        kmsg(f"failed to list {path} ({e})")
        return f"remove:{top}"
    for name in names:
        child = os.path.join(path, name)
        try:
            st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        except OSError as e:
            kmsg(f"failed to stat {child} ({e})")
            return f"remove:{top}"
        try:
            if stat.S_ISDIR(st.st_mode):
                child_fd = os.open(name, DIR_OPEN_FLAGS, dir_fd=dir_fd)
                try:
                    child_mount = fd_mount_id(child_fd)
                    if child_mount != mount_id:
                        kmsg(f"{child} is on mount {child_mount}, {top} is on mount {mount_id}")
                        return f"mounted:{child}"
                    why = _remove_under(top, child, child_fd, mount_id)
                finally:
                    os.close(child_fd)
                if why:
                    return why
                os.rmdir(name, dir_fd=dir_fd)
            else:
                os.unlink(name, dir_fd=dir_fd)
        except FileNotFoundError:
            continue
        except OSError as e:
            kmsg(f"removing {child}: {e}")
            return f"remove:{top}"
    return None


def clear_run_root(losetup=None, in_use=None, wait_s=5.0):
    """unmount, detach and empty RUN_ROOT"""
    losetup = losetup or _losetup
    if not _unmount_tree(RUN_ROOT, RUN_ROOT_UNMOUNT_TRIES):
        return f"unmount:{RUN_ROOT}"
    why = release_unused_data_loops(losetup, in_use or _loop_in_use, wait_s)
    if why:
        return why
    return _empty_dir(RUN_ROOT)


def _loop_in_use(dev, table="/proc/self/mountinfo", sysblock="/sys/block", opener=os.open):
    """return where dev is mounted or why dev is busy, or None"""
    try:
        with open(f"{sysblock}/{os.path.basename(dev)}/dev") as f:
            dev_number = f.read().strip()
    except FileNotFoundError:
        return None
    except OSError as e:
        return f"failed to read the device number ({e})"
    rows = core.read_mountinfo(table)
    if rows is None:
        return f"failed to read {table}"
    mounted = [row[4] for row in rows if row[2] == dev_number]
    if mounted:
        return f"mounted at {' '.join(mounted)}"
    try:
        fd = opener(dev, os.O_RDONLY | os.O_EXCL | os.O_CLOEXEC)
    except OSError as e:
        if e.errno != errno.EBUSY:
            return f"failed to open with O_EXCL ({e})"
        holders = _loop_holders(dev, sysblock=sysblock)
        return "claimed by a filesystem" + (f" mounted by pids {' '.join(holders)}" if holders else "")
    os.close(fd)
    return None


def release_unused_data_loops(losetup, in_use, wait_s):
    """detach the unused loops of data.img"""
    stale = _loops_backing(RHIZO_DATA_IMG, losetup)
    if stale is None:
        kmsg(f"failed to list the loop devices of {RHIZO_DATA_IMG}")
        return "data-img-loops-unknown"
    for dev in stale:
        use = in_use(dev)
        if use:
            kmsg(f"{RHIZO_DATA_IMG} is still attached at {dev}, {use}")
            return f"data-img-busy:{dev}"
        rc, _out, err = losetup(["-d", dev])
        if rc:
            kmsg(f"failed to detach data.img loop {dev} ({err})")
        else:
            kmsg(f"RHIZO_MARKER data_img_loop_detached dev={dev}")
    left, deadline = stale, time.time() + wait_s
    while left:
        left = _loops_backing(RHIZO_DATA_IMG, losetup)
        if left is None:
            return "data-img-loops-unknown"
        if not left or time.time() >= deadline:
            break
        time.sleep(0.1)
    if left:
        kmsg(f"{RHIZO_DATA_IMG} is still attached at {' '.join(left)} after losetup -d")
        return f"data-img-busy:{left[0]}"
    return None


def refuse_start_by_name(reason):
    """log, record and refuse the start"""
    kmsg(f"RHIZO_MARKER start_refused={reason}")
    if not host_selinux_mode():
        record_refusal_unless_final(reason)
    refuse_start()


def _unmount_tree(path, tries=UNMOUNT_TREE_TRIES):
    """unmount the mounts under path and return whether path has no mounts"""
    real = os.path.realpath(path)
    for unmounted in range(tries + 1):
        rows = core.read_mountinfo()
        if rows is None:
            kmsg(f"failed to read the mount table for {path}")
            return False
        reaching = set(core.mounts_reaching(real, rows))
        below = real.rstrip("/") + "/"
        held = [row[4] for row in rows if row[0] in reaching or row[4] == real or row[4].startswith(below)]
        if not held:
            return True
        if unmounted == tries:
            break
        target = max(held, key=lambda p: p.count("/"))
        if libc.umount2(target.encode(), 0) != 0:
            kmsg(f"umount {target} failed ({os.strerror(ctypes.get_errno())})")
            return False
    kmsg(f"{path} is still mounted at {held} after {tries} unmounts")
    return False


def _stage_prepared_tree(tree_part):
    """stage, relabel and prune the prepared tree"""
    import shutil
    for sub in ("system_upper/etc/init/hw", "system_upper/bin",
                "system_ext_upper/etc/init", "system_ext_upper/etc/permissions",
                "system_ext_upper/bin/hw", "system_ext_upper/lib64",
                "system_ext_upper/priv-app", "system_ext_upper/app",
                "system_ext_upper/overlay", "product_upper/etc/permissions"):
        os.makedirs(f"{RUN_ROOT}/{sub}", exist_ok=True)
    _stage_vendor_scaffold()

    core.set_prepare_recording(True)
    stage_vendor_tree()
    stage_hals()
    os.makedirs(os.path.join(tree_part, "apex_override"), exist_ok=True)
    _stage_tethering_apex(os.path.join(tree_part, "apex_override", "com.android.tethering.apex"))
    _apex_staged, _apex_failed = _stage_decompressed_apexes(
        f"{GSI}/apex", os.path.join(tree_part, "apex_override"))
    if _apex_failed:
        return None, f"apex-decompress failed={_apex_failed}"
    kmsg(f"extracted {len(_apex_staged)} .capex payloads into apex_override")
    recorded = core.recorded_copies()
    core.set_prepare_recording(False)

    labeled, unmatched, failed = _relabel_prepared_vendor(os.path.join(tree_part, "vendor"))
    kmsg(f"prepare-tree relabel labeled={labeled} unmatched={unmatched} failed={failed}")
    if failed:
        return None, f"relabel-failed failed={failed}"

    vendor_root = os.path.join(tree_part, "vendor")
    for entry in os.listdir(vendor_root):
        if entry in ("bin", "lib", "lib64"):
            continue
        path = os.path.join(vendor_root, entry)
        if os.path.isdir(path) and not os.path.islink(path):
            shutil.rmtree(path, ignore_errors=True)
        else:
            try:
                os.unlink(path)
            except OSError:
                pass
    return recorded, None


def _in_policy_namespace(policy, work, helper):
    """run work in a policy namespace child"""
    sys.stdout.flush()
    sys.stderr.flush()
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        try:
            why = _enter_compiled_policy_namespace(policy, helper)
            result = (None, why) if why else work()
        except BaseException as e:
            kmsg(f"policy namespace child raised {type(e).__name__} ({e})")
            result = (None, f"staging-child-raised:{type(e).__name__}")
        try:
            sys.stdout.flush()
            with os.fdopen(w, "wb") as f:
                f.write(json.dumps(result).encode())
        finally:
            os._exit(0)
    os.close(w)
    with os.fdopen(r, "rb") as f:
        data = f.read()
    _pid, status = os.waitpid(pid, 0)
    if status != 0 or not data:
        return None, f"staging-child-status={status}"
    return tuple(json.loads(data))


def prepare_tree_verb(dest, gpu_driver_dir=None):
    """build the prepared tree at dest with the boot's stagers"""
    if os.geteuid() != 0:
        print("PREPARE_TREE_FAILED reason=not-root")
        return 1
    if host_selinux_mode():
        try:
            os.stat(os.path.dirname(SELINUX_ENFORCE_NODE))
            selinuxfs = True
        except FileNotFoundError:
            selinuxfs = False
        except OSError as e:
            kmsg(f"failed to stat {os.path.dirname(SELINUX_ENFORCE_NODE)} ({e})")
            print("PREPARE_TREE_FAILED reason=enforce-unreadable")
            return 1
        if selinuxfs:
            try:
                with open(SELINUX_ENFORCE_NODE) as f:
                    enforce = f.read().strip()
            except OSError as e:
                kmsg(f"failed to read {SELINUX_ENFORCE_NODE} ({e})")
                print("PREPARE_TREE_FAILED reason=enforce-unreadable")
                return 1
            if enforce == "1":
                print("PREPARE_TREE_REFUSED reason=enforcing")
                return 1
    if _sandbox_is_live():
        print("PREPARE_TREE_REFUSED reason=sandbox-live")
        return 1
    in_policy_ns = host_has_own_policy()
    ns_policy = compiled_policy_path() if in_policy_ns else None

    for k in list(os.environ):
        if k.startswith("RHIZO_") and k != "RHIZO_SELINUX_MODE":
            del os.environ[k]
    if gpu_driver_dir:
        os.environ["RHIZO_GPU_DRIVER_DIR"] = gpu_driver_dir

    if not _unmount_tree(RUN_ROOT):
        print(f"PREPARE_TREE_FAILED reason=unmount:{RUN_ROOT}")
        return 1
    why = _empty_dir(RUN_ROOT)
    if why:
        print(f"PREPARE_TREE_FAILED reason={why}")
        return 1
    os.makedirs(RUN_ROOT, exist_ok=True)
    mount("tmpfs", RUN_ROOT, "tmpfs", 0, "mode=0755")
    try:
        os.makedirs(dest, exist_ok=True)
        tree_part = os.path.join(dest, "build.part")
        if not _unmount_tree(tree_part):
            print(f"PREPARE_TREE_FAILED reason=unmount:{tree_part}")
            return 1
        why = _remove_tree(tree_part)
        if why:
            print(f"PREPARE_TREE_FAILED reason={why}")
            return 1
        os.makedirs(os.path.join(tree_part, "vendor"), mode=0o755, exist_ok=True)
        os.makedirs(f"{RUN_ROOT}/vendor", exist_ok=True)
        if not mount(os.path.join(tree_part, "vendor"), f"{RUN_ROOT}/vendor", None, MS_BIND):
            print("PREPARE_TREE_FAILED reason=vendor-bind")
            return 1
        if in_policy_ns:
            recorded, why = _in_policy_namespace(ns_policy, lambda: _stage_prepared_tree(tree_part), "relabel")
        else:
            recorded, why = _stage_prepared_tree(tree_part)
        if why:
            print(f"PREPARE_TREE_FAILED reason={why}")
            return 1
        recorded = [tuple(pair) for pair in recorded]

        manifest = _build_prepared_manifest(tree_part, recorded)
        with open(os.path.join(tree_part, "manifest.json"), "w") as f:
            json.dump(manifest, f)

        if not _unmount_tree(f"{RUN_ROOT}/vendor"):
            print(f"PREPARE_TREE_FAILED reason=unmount:{RUN_ROOT}/vendor")
            return 1
        if not _unmount_tree(RUN_ROOT):
            print(f"PREPARE_TREE_FAILED reason=unmount:{RUN_ROOT}")
            return 1
        why = _empty_dir(RUN_ROOT)
        if why:
            print(f"PREPARE_TREE_FAILED reason={why}")
            return 1

        os.sync()
        key = manifest["key"]
        final_tree = os.path.join(dest, key)
        why = _remove_tree(final_tree)
        if why:
            print(f"PREPARE_TREE_FAILED reason={why}")
            return 1
        os.rename(tree_part, final_tree)
        current_tmp = os.path.join(dest, "current.tmp")
        try:
            os.unlink(current_tmp)
        except FileNotFoundError:
            pass
        os.symlink(key, current_tmp)
        os.replace(current_tmp, os.path.join(dest, "current"))
        os.sync()

        print(f"PREPARE_TREE_OK key={key} inputs={len(manifest['inputs'])} outputs={len(manifest['outputs'])}")
        return 0
    finally:
        if _unmount_tree(RUN_ROOT):
            _empty_dir(RUN_ROOT)


def _sepolicy_cache_for(gsi_cils, rhizo_cil, wakeup_genfs):
    """return the cache path and hit for a render"""
    with open(rhizo_cil, "w") as f:
        f.write(selinux_policy.build(gsi_cils, ftrace=capabilities.ftrace_allowed(log=kmsg),
                                   namespace=not host_selinux_mode(), wakeup_genfs=wakeup_genfs))
    h = hashlib.sha256()
    for c in gsi_cils + [rhizo_cil] + selinux_policy.software_cils(core.software_rendering()):
        h.update(open(c, "rb").read())
    cache_path = f"{RHIZO_CACHE_DIR}/precompiled_sepolicy.{h.hexdigest()}"
    return cache_path, os.path.exists(cache_path) and os.path.getsize(cache_path) > 0


def _read_prepared_wakeup():
    """return prepare's recorded wakeup genfscons, or None"""
    try:
        with open(prepared_wakeup_path()) as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        kmsg(f"failed to read {prepared_wakeup_path()} ({e})")
        return None


def _gsi_policy_cils():
    """return the GSI plat, system_ext and product cil paths that exist"""
    return [c for c in (f"{GSI}/etc/selinux/plat_sepolicy.cil",
                        f"{GSI}/system_ext/etc/selinux/system_ext_sepolicy.cil",
                        f"{GSI}/product/etc/selinux/product_sepolicy.cil") if os.path.exists(c)]


def _cached_policy(gsi_cils, rhizo_cil, live):
    """return the policy cache path, the cache hit and the wakeup note"""
    cache_path, hit = _sepolicy_cache_for(gsi_cils, rhizo_cil, live)
    note = ""
    recorded = None if hit else _read_prepared_wakeup()
    if recorded is not None and recorded != live:
        prepared_path, hit = _sepolicy_cache_for(gsi_cils, rhizo_cil, recorded)
        if hit:
            cache_path, note = prepared_path, " wakeup=changed"
    return cache_path, hit, note


def _read_launched_wakeup():
    """return the launched_wakeup_path() text, or None"""
    try:
        with open(launched_wakeup_path()) as f:
            return f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        kmsg(f"failed to read {launched_wakeup_path()} ({e})")
        return None


def compiled_policy_path():
    """return the cached compiled policy path, or None"""
    tmp = tempfile.mkdtemp(prefix="rhizo-compiled-policy-")
    try:
        gsi_cils = _gsi_policy_cils()
        rhizo_cil = os.path.join(tmp, "rhizo_vendor_sepolicy.cil")
        path, hit, _note = _cached_policy(gsi_cils, rhizo_cil, policy_wakeup_genfs(gsi_cils))
        launched = None if hit else _read_launched_wakeup()
        if launched is not None:
            path, hit = _sepolicy_cache_for(gsi_cils, rhizo_cil, launched)
        return path if hit else None
    finally:
        import shutil as _sh_cp
        _sh_cp.rmtree(tmp, ignore_errors=True)


def host_has_own_policy():
    """return whether host_policy_state() is not none in namespace mode"""
    return not host_selinux_mode() and selinux_ns.host_policy_state() != "none"


def _enter_compiled_policy_namespace(policy, helper):
    """enter a child SELinux namespace with policy loaded"""
    if policy is None:
        return "no-compiled-policy"
    return selinux_ns.enter_policy_namespace(policy, helper)


def unit_env_files(sandbox_id):
    """return the env files androidd's unit reads for an instance"""
    files = [os.environ.get("RHIZO_ANDROIDD_ENV", "/etc/rhizo/androidd.env"),
             os.environ.get("RHIZO_RUNTIME_ENV", "/var/lib/rhizo/androidd-runtime.env"),
             os.environ.get("RHIZO_HOST_MODE_KEPT_FILE", "/var/lib/rhizo/host-mode-kept.env")]
    if sandbox_id:
        files.append(os.path.join(os.environ.get("RHIZO_INSTANCE_ENV_DIR", "/etc/rhizo/instances"), f"{sandbox_id}.env"))
    return files


def unit_env(files):
    """return the KEY=value settings of the env files"""
    env = {}
    for path in files:
        try:
            with open(path) as f:
                lines = f.read().splitlines()
        except FileNotFoundError:
            continue
        for line in lines:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip("\"'")
    return env


IN_ANDROID_POLICY_CAPS = {"label": [], "label-fd": [], "materialize-data-template": [0, 1, 2, 3],
                          "hostfs-label-lower": [1, 2, 3, 6, 7, 18, 19, 21]}
IN_ANDROID_POLICY_HELPER = {"label": "label", "label-fd": "label", "hostfs-label-lower": "label",
                            "materialize-data-template": "relabel"}
IN_ANDROID_POLICY_SCRIPTS = {"materialize-data-template": ("materialize-data-template.py", None),
                             "hostfs-label-lower": ("hostfs.py", "label-lower")}


def in_android_policy_argv_ok(argv):
    """return whether argv is a fixed verb"""
    if not argv or argv[0] not in IN_ANDROID_POLICY_CAPS:
        return False
    if argv[0] in ("label", "label-fd"):
        return len(argv) == 3 and (argv[0] == "label" or argv[1].isdigit())
    name, first = IN_ANDROID_POLICY_SCRIPTS[argv[0]]
    if len(argv) < 2 or os.path.basename(argv[1]) != name or (first is not None and argv[2:3] != [first]):
        return False
    try:
        st = os.stat(argv[1])
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022


def label_in_namespace(target, context):
    """label a path or fd and print the getxattr result"""
    follow = not isinstance(target, str)
    os.setxattr(target, "security.selinux", context.encode() + b"\0", follow_symlinks=follow)
    print(os.getxattr(target, "security.selinux", follow_symlinks=follow).rstrip(b"\0").decode(errors="replace"))


def load_hostfs_label_lower(script, args):
    """return the hostfs label-lower verb as a function"""
    import runpy
    functions = runpy.run_path(script, run_name="rhizo_hostfs")
    parsed = functions["build_parser"]().parse_args(args)
    return lambda: functions["cmd_label_lower"](parsed)


def in_android_policy_verb(argv):
    """run a fixed verb under Android's compiled policy"""
    if os.geteuid() != 0:
        print("IN_ANDROID_POLICY_FAILED reason=not-root")
        return 1
    if not in_android_policy_argv_ok(argv):
        print(f"IN_ANDROID_POLICY_FAILED reason=unknown-verb argv={argv[:3]}")
        return 1
    if os.environ.get("RHIZO_UNIT_ENV_READ") != "1":
        env = dict(os.environ, RHIZO_UNIT_ENV_READ="1")
        for key, value in unit_env(unit_env_files(SANDBOX_ID)).items():
            env.setdefault(key, value)
        os.execve(sys.executable, [sys.executable, os.path.abspath(__file__), "in-android-policy", *argv], env)
    with open("/proc/sys/kernel/cap_last_cap") as f:
        last_cap = int(f.read())
    verb = argv[0]
    hostfs_label_lower = None
    if verb == "hostfs-label-lower":
        try:
            hostfs_label_lower = load_hostfs_label_lower(argv[1], argv[2:])
        except (Exception, SystemExit) as e:
            print(f"IN_ANDROID_POLICY_FAILED reason=hostfs-script:{e!r}")
            return 1
    why = _enter_compiled_policy_namespace(compiled_policy_path(), IN_ANDROID_POLICY_HELPER[verb])
    if why:
        print(f"IN_ANDROID_POLICY_FAILED reason={why} gsi={GSI}")
        return 1
    if verb in ("label", "label-fd"):
        why = selinux_ns._drop_privileges(last_cap)
        if why:
            print(f"IN_ANDROID_POLICY_FAILED reason=caps:{why}")
            return 1
        try:
            label_in_namespace(argv[1] if verb == "label" else int(argv[1]), argv[2])
        except OSError as e:
            print(f"IN_ANDROID_POLICY_FAILED reason=label:{e.strerror}")
            return 1
        return 0
    why = selinux_ns.keep_only_caps(set(IN_ANDROID_POLICY_CAPS[verb]), last_cap)
    if why:
        print(f"IN_ANDROID_POLICY_FAILED reason=caps:{why}")
        return 1
    if hostfs_label_lower is not None:
        return hostfs_label_lower()
    os.execv(sys.executable, [sys.executable, *argv[1:]])


def prepare_sepolicy_verb(check_only):
    """compile the policy into the boot's cache"""
    if os.geteuid() != 0:
        print("PREPARE_SEPOLICY_FAILED reason=not-root")
        return 1
    tmp = tempfile.mkdtemp(prefix="rhizo-prepare-sepolicy-")
    try:
        rhizo_cil = os.path.join(tmp, "rhizo_vendor_sepolicy.cil")
        gsi_cils = _gsi_policy_cils()
        live = policy_wakeup_genfs(gsi_cils)
        if check_only:
            cache_path, hit, note = _cached_policy(gsi_cils, rhizo_cil, live)
            if hit:
                touch_cache_entry(cache_path)
            print(f"PREPARE_SEPOLICY_CHECK cache={cache_path} hit={'1' if hit else '0'}{note}")
            return 0 if hit else 1
        pc = os.path.join(tmp, "precompiled_sepolicy")
        rc, cils, _content, err = compile_precompiled_sepolicy(pc, rhizo_cil, wakeup_genfs=live)
        if rc != 0:
            print(f"PREPARE_SEPOLICY_FAILED reason=secilc rc={rc} {err}")
            return 1
        h = hashlib.sha256()
        for c in cils:
            h.update(open(c, "rb").read())
        cache_path = f"{RHIZO_CACHE_DIR}/precompiled_sepolicy.{h.hexdigest()}"
        record_tmp = f"{prepared_wakeup_path()}.{os.getpid()}.tmp"
        with open(record_tmp, "w") as f:
            f.write(live)
        os.replace(record_tmp, prepared_wakeup_path())
        print(f"PREPARE_SEPOLICY_OK cache={cache_path}")
        return 0
    finally:
        import shutil as _sh_ps
        _sh_ps.rmtree(tmp, ignore_errors=True)


def gsi_derived_check_verb():
    """print the missing GSI-derived files"""
    missing = core.gsi_derived_missing()
    if missing:
        print(f"GSI_DERIVED_MISSING dir={core.gsi_libs_dir()} missing={','.join(os.path.basename(m) for m in missing)}")
        return 1
    mismatch = core.gsi_derived_mismatch()
    if mismatch:
        print(f"GSI_DERIVED_MISMATCH dir={core.gsi_libs_dir()} why={mismatch}")
        return 1
    print(f"GSI_DERIVED_OK dir={core.gsi_libs_dir()} n={len(core.KEYMINT_GSI_LIBS)}")
    return 0


def data_tier_verb():
    """print the _probe_data_tier() result"""
    print(_probe_data_tier())
    return 0


def _staging_mounts(root, reach, table="/proc/self/mountinfo"):
    """return the leaf staging mounts under root and the mount count"""
    rows = core.read_mountinfo(table)
    if rows is None:
        return None
    prefix = root + "/"
    ids = {r[0] for r in rows if r[4] == root or r[4].startswith(prefix)}
    for d in reach:
        ids.update(core.mounts_reaching(d, rows))
    parents = {r[1] for r in rows}
    leaves = [(r[0], r[4]) for r in rows if r[0] in ids and r[0] not in parents]
    return leaves, len(ids)


def _losetup(args, sysblock="/sys/block"):
    """run losetup -j or -d in-process"""
    if len(args) == 2 and args[0] == "-j":
        try:
            devs = core.loops_backed_by(args[1], sysblock)
        except OSError as e:
            return 1, "", f"failed to list {sysblock} ({e.strerror})"
        return 0, "".join(f"{d}: []: ({args[1]})\n" for d in devs), ""
    if len(args) == 2 and args[0] == "-d":
        try:
            core.loop_detach(args[1])
        except OSError as e:
            return 1, "", f"failed to detach {args[1]} ({e.strerror})"
        return 0, "", ""
    return 2, "", f"unsupported losetup arguments {args}"


def _umount2(path, flags):
    """return 0, or the errno umount2(2) failed with"""
    return 0 if libc.umount2(path.encode(), flags) == 0 else (ctypes.get_errno() or errno.EIO)


def _loops_backing(img, losetup, sysblock="/sys/block"):
    """return the loop devices backing img"""
    real = os.path.realpath(img)
    names = {img, real, img + " (deleted)", real + " (deleted)"}
    devs = []
    if os.path.exists(real):
        rc, out, _err = losetup(["-j", real])
        if rc != 0:
            return None
        devs = [line.split(":", 1)[0] for line in out.splitlines() if line.strip()]
    try:
        entries = sorted(os.listdir(sysblock))
    except OSError:
        return None
    for name in entries:
        bf = os.path.join(sysblock, name, "loop", "backing_file")
        if not os.path.lexists(bf):
            continue
        try:
            with open(bf) as f:
                backing = f.read().rstrip("\n")
        except FileNotFoundError:
            continue
        except OSError as e:
            if e.errno != errno.ENXIO:
                return None
            continue
        if backing in names and f"/dev/{name}" not in devs:
            devs.append(f"/dev/{name}")
    return devs


def vbmeta_loop_identity(dev, sysblock="/sys/block"):
    """return the <dev> <diskseq> record of an attach"""
    try:
        with open(f"{sysblock}/{os.path.basename(dev)}/diskseq") as f:
            seq = f.read().strip()
    except OSError:
        return None
    return f"{dev} {seq}" if seq.isdigit() else None


def release_own_vbmeta_loop(record=None, img=None, losetup=None, sysblock="/sys/block", log=kmsg,
                            who="androidd-stop"):
    """detach the vbmeta.img loop in the loop record"""
    record = VBMETA_LOOP_FILE if record is None else record
    img = beside("vbmeta.img") if img is None else img
    losetup = losetup or _losetup

    def drop():
        """remove the loop record"""
        try:
            os.unlink(record)
        except FileNotFoundError:
            pass
        except OSError as e:
            log(f"{who} failed to remove {record} ({e})")
            return False
        return True

    try:
        with open(record) as f:
            text = f.read().strip()
    except FileNotFoundError:
        return True
    except OSError as e:
        log(f"{who} failed to read {record} ({e})")
        return False
    parts = text.split()
    if len(parts) != 2 or not parts[1].isdigit():
        log(f"{who} {record} is {text or '<empty>'!r}, not <dev> <diskseq>")
        return drop()
    dev, seq = parts
    joined = _loops_backing(img, losetup, sysblock)
    if joined is None:
        log(f"{who} failed to list the loop devices of {img}")
        return False
    if dev not in joined:
        log(f"{who} {dev} is not a vbmeta.img loop")
        return drop()
    try:
        with open(f"{sysblock}/{os.path.basename(dev)}/diskseq") as f:
            cur = f.read().strip()
    except FileNotFoundError:
        cur = None
    except OSError as e:
        log(f"{who} failed to read the diskseq of {dev} ({e})")
        return False
    if cur != seq:
        log(f"{who} {dev} diskseq is {cur}, recorded {seq}")
        return drop()
    rc, _out, err = losetup(["-d", dev])
    if rc != 0:
        log(f"{who} losetup -d {dev} failed ({err or f'rc={rc}'})")
        return False
    if not drop():
        return False
    left = _loops_backing(img, losetup, sysblock)
    if left is None or dev in left:
        log(f"{who} vbmeta.img is still attached at {dev} after losetup -d")
        return False
    log(f"{who} detached vbmeta.img loop {dev}")
    return True


def _loop_holders(dev, proc="/proc", sysblock="/sys/block"):
    """return the pids whose mountinfo contains the maj:min of dev"""
    try:
        mm = open(f"{sysblock}/{os.path.basename(dev)}/dev").read().strip()
    except OSError:
        return []
    pids = []
    for d in os.listdir(proc):
        if not d.isdigit():
            continue
        try:
            with open(f"{proc}/{d}/mountinfo") as f:
                if any(line.split()[2:3] == [mm] for line in f):
                    pids.append(d)
        except OSError:
            continue
    return pids


def release_host_staging(run_root=None, data_img=None, log=kmsg, table="/proc/self/mountinfo",
                         umount2=_umount2, losetup=_losetup, wait_s=5.0, who="androidd-stop",
                         sysblock="/sys/block", reach=None, domain=None,
                         vbmeta_record=VBMETA_LOOP_FILE, vbmeta_img=None):
    """unmount the instance host staging and detach the data.img loops"""
    domain = own_domain() if domain is None else domain
    if domain.startswith("u:r:kernel:"):
        log(f"{who} skipped the host staging release in domain {domain}")
        return False
    run_root = (run_root or RUN_ROOT).rstrip("/")
    data_img = data_img or RHIZO_DATA_IMG
    reach = (RHIZO_VENDOR_DIR, RHIZO_APEX_DIR) if reach is None else tuple(reach)
    unmounted, lazy, stuck = 0, [], None
    for _ in range(64):
        found = _staging_mounts(run_root, reach, table)
        if found is None:
            stuck = f"failed to read {table}"
            break
        leaves, total = found
        if not total:
            break
        if not leaves:
            stuck = f"{total} staging mounts under {run_root} have child mounts outside the staging"
            break
        leaves = sorted({mp for _mid, mp in leaves})
        refused = {}
        for mp in leaves:
            err = umount2(mp, 0)
            if err == 0:
                unmounted += 1
            else:
                refused[mp] = err
        if len(refused) < len(leaves):
            continue
        for mp, err in refused.items():
            lerr = umount2(mp, 2)
            if lerr != 0:
                stuck = f"failed to unmount {mp} ({os.strerror(err)}, MNT_DETACH {os.strerror(lerr)})"
                break
            unmounted += 1
            lazy.append(f"{mp} ({os.strerror(err)})")
        if stuck:
            break
    else:
        stuck = f"{run_root} is still mounted after 64 passes"

    devs = _loops_backing(data_img, losetup, sysblock)
    detach_failed = []
    for dev in devs or []:
        rc, _out, err = losetup(["-d", dev])
        if rc != 0:
            detach_failed.append(f"{dev} ({err or f'rc={rc}'})")
    left = devs
    deadline = time.time() + wait_s
    while left:
        left = _loops_backing(data_img, losetup, sysblock)
        if not left or time.time() >= deadline:
            break
        time.sleep(0.1)

    if lazy:
        log(f"{who} detached lazily {', '.join(lazy)}")
    if stuck:
        log(f"{who} failed to release the host staging ({stuck})")
    if detach_failed:
        log(f"{who} losetup -d failed for {', '.join(detach_failed)}")
    if devs is None or left is None:
        log(f"{who} failed to list the loop devices of {data_img}")
    elif left:
        holders = {d: _loop_holders(d, sysblock=sysblock) for d in left}
        log(f"{who} {data_img} is still attached at {' '.join(left)} after losetup -d (holders {holders})")
    vbmeta_ok = vbmeta_record is None or release_own_vbmeta_loop(
        vbmeta_record, vbmeta_img, losetup, sysblock, log, who)
    ok = not stuck and devs is not None and left == [] and vbmeta_ok
    if ok:
        log(f"{who} host staging released unmounted={unmounted} root={run_root} "
            f"reach={' '.join(reach) or 'none'} data.img loop {' '.join(devs) if devs else 'none'} detached")
    return ok


def clear_earlier_cgroup_record(root_file=None, inv_file=None, invocation=None):
    """remove a cgroup-root record another start wrote"""
    root_file = root_file or CGROUP_ROOT_FILE
    inv_file = inv_file or CGROUP_INVOCATION_FILE
    if invocation is None:
        invocation = os.environ.get("INVOCATION_ID", "")
    try:
        with open(inv_file) as f:
            recorded = f.read().strip()
    except OSError:
        recorded = None
    if invocation and recorded == invocation:
        return False
    removed = False
    for path in (inv_file, root_file):
        try:
            os.unlink(path)
            removed = True
        except FileNotFoundError:
            pass
        except OSError as e:
            kmsg(f"failed to remove the cgroup record {path} ({e})")
    if removed:
        kmsg(f"removed the cgroup record of invocation {recorded or '<none>'}, "
             f"INVOCATION_ID={invocation or '<no unit>'}")
    return removed


def write_cgroup_record(cgroup_root, root_file=None, inv_file=None, invocation=None):
    """write the cgroup root and INVOCATION_ID records"""
    root_file = root_file or CGROUP_ROOT_FILE
    inv_file = inv_file or CGROUP_INVOCATION_FILE
    if invocation is None:
        invocation = os.environ.get("INVOCATION_ID", "")
    with open(root_file, "w") as f:
        f.write(cgroup_root)
    if invocation:
        with open(inv_file, "w") as f:
            f.write(invocation + "\n")


def stack_cgroup():
    """return the stack's real cgroup root"""
    try:
        return open(CGROUP_ROOT_FILE).read().strip() or None
    except OSError:
        pass
    try:
        cg_rel = open("/proc/self/cgroup").read().strip().split(":")[-1]
    except OSError:
        return None
    if cg_rel.endswith("/.control"):
        return f"/sys/fs/cgroup{cg_rel[:-len('/.control')]}/android"
    return f"/sys/fs/cgroup{cg_rel}"


def stack_cgroup_populated():
    """return whether the stack cgroup has a pid other than recorded_pid() and os.getpid()"""
    _cg = stack_cgroup()
    if _cg is None:
        return None
    if not os.path.isdir(_cg):
        return None
    sup = recorded_pid()
    try:
        for root, _dirs, files in os.walk(_cg):
            if "cgroup.procs" not in files:
                continue
            for line in open(f"{root}/cgroup.procs"):
                if line.strip() and int(line) not in (sup, os.getpid()):
                    return True
        return False
    except (OSError, ValueError):
        return None


def kill_cgroup_tree(root, keep, log):
    """SIGKILL the processes under root except keep"""
    held = cgroup_tree_pids(root, skip=())
    if held is None:
        log(f"failed to read the cgroup tree under {root}")
        return False
    if not set(held) & set(keep):
        try:
            cgroup_write(f"{root}/cgroup.kill", "1")
            return True
        except OSError as e:
            log(f"failed to write {root}/cgroup.kill ({e})")
            return False
    ok = True
    for pid in cgroup_tree_pids(root, skip=keep, depth=0) or []:
        try:
            fd = os.pidfd_open(pid)
        except ProcessLookupError:
            continue
        try:
            signal.pidfd_send_signal(fd, signal.SIGKILL)
        except ProcessLookupError:
            pass
        finally:
            os.close(fd)
    for child in sorted(e.path for e in os.scandir(root) if e.is_dir(follow_symlinks=False)):
        ok = kill_cgroup_tree(child, keep, log) and ok
    return ok


SANDBOX_SWEEP_WAIT_S = 10


def sweep_sandbox_cgroups(log, wait_s=None):
    """kill the sandbox cgroups and return the pids left"""
    root = stack_cgroup()
    if root is None or not os.path.isdir(root):
        log(f"no stack cgroup to sweep ({root})")
        return None
    keep = tuple(p for p in (recorded_pid(), os.getpid()) if p)
    left = cgroup_tree_pids(root, skip=keep)
    if left:
        log(f"kill {len(left)} sandbox processes in {root} ({left[:8]})")
        kill_cgroup_tree(root, keep, log)
    deadline = time.time() + (SANDBOX_SWEEP_WAIT_S if wait_s is None else wait_s)
    while left and time.time() < deadline:
        time.sleep(0.1)
        left = cgroup_tree_pids(root, skip=keep)
    return left


def companion_stop_units(sandbox_id):
    """return the companion units of a sandbox"""
    if sandbox_id != 0:
        return [f"rhizo-inputd@{sandbox_id}.service", f"rhizo-inputd-uhid@{sandbox_id}.service",
                f"rhizo-server-idle@{sandbox_id}.service"]
    return ["rhizo-inputd@0.service", "rhizo-inputd-uhid@0.service", "rhizo-server-idle.service",
            "rhizo-hostfs.service", "rhizo-audiod.service", "rhizo-camerad.service", "rhizo-keymapd.service",
            "rhizo-deskd.service", "rhizo-displayd.service", "rhizo-rtd.service", "rhizo-delayd.service",
            "rhizo-headroomd.service", "rhizo-btd.service", "rhizo-locationd.service"]


COMPANION_STOP_BUDGET_S = 10
START_JOB_TYPES = ("start", "restart", "reload-or-start", "verify-active")


def companions_left_running(units, run=subprocess.run, timeout=30):
    """return the jobless running units"""
    r = run(["systemctl", "show", "--property=Id", "--property=ActiveState", "--property=Job", "--"] + units,
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise OSError(f"systemctl show rc={r.returncode} {r.stderr.strip()[:200]}")
    running = []
    for block in r.stdout.strip().split("\n\n"):
        props = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        job = props.get("Job", "").strip()
        if props.get("ActiveState") not in ("inactive", "failed", "deactivating", None) \
                and not (job.isdigit() and int(job) > 0):
            running.append(props.get("Id", ""))
    return [u for u in running if u in units]


def start_queued(unit, run=subprocess.run, timeout=30):
    """return whether a start job is queued on unit"""
    if not unit:
        return False
    r = run(["systemctl", "list-jobs", "--no-legend", "--", unit], stdin=subprocess.DEVNULL, capture_output=True,
            text=True, timeout=timeout)
    if r.returncode != 0:
        raise OSError(f"systemctl list-jobs rc={r.returncode} {r.stderr.strip()[:200]}")
    return any(len(f) >= 4 and f[1] == unit and f[2] in START_JOB_TYPES and f[3] == "waiting"
               for f in map(str.split, r.stdout.splitlines()))


def stop_companion_units(sandbox_id, log, run=subprocess.run, unit=None, budget_s=COMPANION_STOP_BUDGET_S):
    """stop or restart the sandbox's companion units"""
    units = companion_stop_units(sandbox_id)
    unit = own_service_unit() if unit is None else unit
    deadline = time.monotonic() + budget_s

    def remaining():
        """return the seconds left of the budget"""
        left_s = deadline - time.monotonic()
        if left_s <= 0:
            raise subprocess.TimeoutExpired("systemctl", budget_s)
        return left_s

    try:
        targets = companions_left_running(units, run, remaining())
        if not targets:
            return True
        verb = "restart" if start_queued(unit, run, remaining()) else "stop"
        r = run(["systemctl", verb, "--no-block", "--job-mode=fail", "--"] + targets, stdin=subprocess.DEVNULL,
                capture_output=True, text=True, timeout=remaining())
        left = companions_left_running(targets, run, remaining()) if r.returncode != 0 else []
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"failed to stop the companions {' '.join(units)} within {budget_s}s ({e})")
        return False
    if left:
        log(f"refused:companions-left {' '.join(left)} systemctl {verb} rc={r.returncode} {r.stderr.strip()[:200]}")
        return False
    log(f"{verb} queued for {' '.join(targets)}"
        + (f", start queued for {unit}" if verb == "restart" else ""))
    return True


_STOP_START_LOCK = []


def stop_owns_instance(log, records_dir=SELINUXNS_RECORDS_DIR):
    """return whether the stop takes the instance start lock, or None on OSError"""
    if host_selinux_mode():
        return True
    try:
        fd = take_start_lock(records_dir)
    except OSError as e:
        log(f"refused:stop-owner-unknown instance {SANDBOX_ID} start lock in {records_dir} ({e})")
        return None
    if fd is None:
        log(f"instance {SANDBOX_ID} start lock in {records_dir} is taken, "
            f"INVOCATION_ID={os.environ.get('INVOCATION_ID') or '<none>'}")
        return False
    _STOP_START_LOCK.append(fd)
    return True


def release_staging_verb():
    """kill the sandbox and release the host staging"""
    if os.geteuid() != 0:
        kmsg("androidd-stop-post euid is not 0")
        return 1
    owns = stop_owns_instance(kmsg)
    if owns is None:
        return 1
    if not owns:
        return 0
    left = sweep_sandbox_cgroups(kmsg)
    stopped = stop_companion_units(SANDBOX_ID, kmsg)
    if stack_cgroup_populated() is False:
        wifi.release_instance()
        uplinks.release(VETH_HOST_IF, (NET_SUBNET, f"{NET_ULA_PREFIX}/64"))
        release_host_staging(who="androidd-stop-post")
        return 0 if stopped else 1
    kmsg(f"stack cgroup {stack_cgroup()} still has {left}")
    return 1


def system_is_shutting_down(run=subprocess.run):
    """return whether the host is shutting down"""
    try:
        out = run(["systemctl", "is-system-running"], stdin=subprocess.DEVNULL,
                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired) as e:
        kmsg(f"systemctl is-system-running failed ({e})")
        return False
    if isinstance(out, bytes):
        out = out.decode(errors="replace")
    return out.strip() == "stopping"


def reap_resident_supervisor_if_shutting_down(shutting_down=system_is_shutting_down):
    """SIGKILL the recorded resident supervisor at shutdown"""
    if not RHIZO_RESIDENT_G:
        return
    if not shutting_down():
        return
    sup = recorded_pid()
    if sup is None:
        kmsg("system is stopping, no resident supervisor recorded")
        return
    if not pid_is_live(sup, kmsg):
        kmsg(f"system is stopping, recorded supervisor {sup} is not live")
        return
    try:
        os.kill(sup, signal.SIGKILL)
        kmsg(f"killed resident supervisor {sup} at shutdown")
    except OSError as e:
        kmsg(f"failed to SIGKILL resident supervisor {sup} ({e})")


def policy_stop_verb():
    """run rhizo-policy.service's ExecStop"""
    if os.geteuid() != 0:
        kmsg("policy-stop euid is not 0")
        return 1
    reap_resident_supervisor_if_shutting_down()
    return 0


def androidd_stop():
    """stop the sandbox through sys.powerctl=shutdown"""
    if os.geteuid() != 0:
        kmsg("androidd-stop euid is not 0")
        return 1
    def sig(p):
        """return the comm and start time of pid p"""
        try:
            raw = open(f"/proc/{p}/stat").read()
            comm = raw[raw.index("(")+1:raw.rindex(")")]
            starttime = raw[raw.rindex(")")+2:].split()[19]
            return comm, starttime
        except (OSError, ValueError, IndexError):
            return None

    def _android_cgroup():
        """return the stack's recorded cgroup root"""
        return stack_cgroup()

    def _cgroup_populated():
        """return stack_cgroup_populated()"""
        return stack_cgroup_populated()

    _reset_outcome = []

    def _reset_delegated_controllers():
        """clear the stack root controllers unless _reset_outcome is set"""
        if _reset_outcome:
            return _reset_outcome[0]
        _cg = _android_cgroup()
        if _cg is None:
            kmsg("no stack cgroup root")
            _reset_outcome.append(False)
            return False
        ok = clear_delegated_controllers(_cg, kmsg, skip=(recorded_pid(),))
        _reset_outcome.append(ok)
        return ok

    _confirmed_empty = []

    def _wait_cgroup_empty(budget):
        """wait up to budget seconds for the stack cgroup to empty"""
        _confirmed_empty.clear()
        cg_deadline = time.time() + budget
        while time.time() < cg_deadline:
            populated = _cgroup_populated()
            if populated is False:
                _confirmed_empty.append(True)
                return True
            if populated is None:
                kmsg("failed to read the stack cgroup")
                return True
            time.sleep(0.5)
        return False

    def _cgroup_pid_count():
        """return the line count of the stack cgroup.procs, or None"""
        _cg = _android_cgroup()
        if _cg is None:
            return None
        try:
            return sum(1 for _ in open(f"{_cg}/cgroup.procs"))
        except OSError:
            return None

    def _settle():
        """wait for the supervisor to finish parking"""
        if not RHIZO_RESIDENT_DISPATCH:
            return
        for _ in range(120):
            if resident_g_pid():
                kmsg("androidd-stop: supervisor parked, stack is stopped")
                return
            time.sleep(0.25)
        kmsg("androidd-stop: supervisor never parked within 30s")

    try:
        kmsg(f"androidd-stop pid={os.getpid()}")
        try:
            with open(INIT_PID_FILE) as f: pid = int(f.read().strip())
        except (OSError, ValueError):
            kmsg(f"no init pid in {INIT_PID_FILE}")
            pid = None
        if RHIZO_RESIDENT_G:
            try:
                sup = recorded_pid()
                if sup is None:
                    raise ValueError("recorded_pid() returned None")
                sup_cg = open(f"/proc/{sup}/cgroup").read().strip().split(":")[-1]
                root_rel = CGROUP_ROOT[len("/sys/fs/cgroup"):]
                if sup_cg != root_rel and not sup_cg.startswith(root_rel + "/"):
                    kmsg(f"supervisor {sup} is in {sup_cg}, outside {CGROUP_ROOT}")
                else:
                    reclaim_cgroup_root(CGROUP_ROOT, kmsg)
                    os.makedirs(f"{CGROUP_ROOT}/supervisor", exist_ok=True)
                    with open(f"{CGROUP_ROOT}/supervisor/cgroup.procs", "w") as f:
                        f.write(str(sup))
                    moved = open(f"/proc/{sup}/cgroup").read().strip().split(":")[-1]
                    kmsg(f"moved supervisor {sup} to {moved}")
            except (OSError, ValueError) as e:
                kmsg(f"failed to move the supervisor out of the sandbox cgroup ({e})")

        orig_sig = sig(pid) if pid is not None else None
        stack_up = orig_sig is not None and orig_sig[0] == "init"
        if pid is not None and not stack_up:
            kmsg(f"pid={pid} from {INIT_PID_FILE} is not init (sig={orig_sig})")
        if stack_up:
            kmsg(f"setprop sys.powerctl=shutdown for init pid={pid} sig={orig_sig} through "
                 + ("nsenter" if host_selinux_mode() else "rhizo-probed"))
        timeout = float(os.environ.get("RHIZO_STOP_TIMEOUT", "30"))
        if not host_selinux_mode():
            deadline = time.time() + timeout
            r = None
            if stack_up:
                selinux_ns.record_stop_request()
                try:
                    r = subprocess.run(["/usr/bin/python3", beside("probe-client.py"),
                                        f"{RUN_ROOT}/data/local/tmp/rhizo-probe.sock", "10",
                                        "/system/bin/setprop sys.powerctl shutdown"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.PIPE, text=True, timeout=15)
                except subprocess.TimeoutExpired:
                    kmsg("probe setprop sys.powerctl=shutdown timed out after 15s")
            if r is not None:
                kmsg(f"probe setprop sys.powerctl=shutdown rc={r.returncode}"
                     + (f" ({r.stderr.strip()[-200:]})" if r.returncode != 0 else ""))
        else:
            deadline = None
            r = subprocess.run(["nsenter", "-a", "-t", str(pid), "--",
                                "/system/bin/setprop", "sys.powerctl", "shutdown"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL) if stack_up else None
            if r is not None and r.returncode != 0:
                kmsg(f"nsenter setprop sys.powerctl=shutdown rc={r.returncode}")
        if not stack_up:
            _settle()
            return 0
        kmsg(f"sandbox cgroup pids={_cgroup_pid_count()} at setprop")
        if deadline is None:
            deadline = time.time() + timeout
        while time.time() < deadline:
            if sig(pid) != orig_sig:
                kmsg(f"init pid={pid} exited, sandbox cgroup pids={_cgroup_pid_count()}")
                if _wait_cgroup_empty(min(10.0, deadline - time.time())):
                    kmsg(f"init pid={pid} exited, "
                         + ("cgroup is empty" if _confirmed_empty
                            else "failed to read the cgroup"))
                    _settle()
                    return 0
                kmsg(f"init pid={pid} exited, cgroup is still populated after 10s")
                break
            time.sleep(1)
        kmsg(f"SIGKILL init pid={pid} after {timeout:.0f}s")
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError as e:
            kmsg(f"failed to SIGKILL pid={pid} ({e})")
            return 1
        fallback_deadline = time.time() + 10
        while time.time() < fallback_deadline:
            if sig(pid) != orig_sig:
                if _wait_cgroup_empty(min(10.0, fallback_deadline - time.time() + 5)):
                    kmsg(f"init pid={pid} exited after SIGKILL, "
                         + ("cgroup is empty" if _confirmed_empty
                            else "failed to read the cgroup"))
                    _settle()
                    return 0
                kmsg(f"init pid={pid} exited after SIGKILL, cgroup is still populated")
                return 1
            time.sleep(0.5)
        kmsg(f"init pid={pid} is still running 10s after SIGKILL")
        return 1
    finally:
        if _cgroup_populated() is False:
            release_host_staging()
        else:
            kmsg(f"stack cgroup is not empty, host staging at {RUN_ROOT} is still mounted")
        if not _reset_delegated_controllers():
            kmsg("failed to clear the stack root controllers")

def pid_is_live(pid, log=None):
    """return whether pid exists and is not a zombie"""
    try:
        os.stat(f"/proc/{pid}")
    except FileNotFoundError:
        return False
    except OSError as e:
        if log:
            log(f"failed to stat /proc/{pid} ({e})")
        return True
    try:
        with open(f"/proc/{pid}/stat") as f:
            if f.read().rsplit(")", 1)[1].split()[0] == "Z":
                if log:
                    log(f"{pid} is a zombie")
                return False
    except (OSError, IndexError):
        pass
    return True


def launcher_must_reexec(policy_loaded, domain, already_reexeced):
    """return whether policy_loaded, not already_reexeced and domain is kernel"""
    if not policy_loaded or already_reexeced:
        return False
    return domain == "kernel" or domain.startswith("u:r:kernel:")


def keeps_literal_cgroup_root(resident_g, domain, literal_root_exists):
    """return whether the launcher uses the literal cgroup root"""
    if not resident_g:
        return False
    if domain == "kernel" or domain.startswith("u:r:kernel:"):
        return True
    return literal_root_exists


SELINUX_ENFORCE_NODE = "/sys/fs/selinux/enforce"
PID1_ATTR = "/proc/1/attr/current"
POLICY_LOADED_STATE = "/run/rhizo-policy-loaded"


def own_service_unit(cgroup_file="/proc/self/cgroup"):
    """return the innermost .service in /proc/self/cgroup"""
    try:
        with open(cgroup_file) as f:
            lines = f.read().splitlines()
    except OSError:
        return ""
    for line in lines:
        if line.startswith("0::"):
            units = [c for c in line[3:].split("/") if c.endswith(".service")]
            return units[-1] if units else ""
    return ""


def policy_is_loaded():
    """return whether a policy is loaded"""
    try:
        with open("/proc/self/attr/current") as f:
            return ":" in f.read().strip("\0").strip()
    except OSError:
        return False


def resident_g_pid():
    """return the parked supervisor's pid"""
    pid = recorded_pid()
    if pid is None:
        return None
    if not host_selinux_mode() and not runs_this_launcher(pid):
        return None
    try:
        blk = [l.split()[1] for l in open(f"/proc/{pid}/status") if l.startswith("SigBlk:")]
    except OSError:
        return None
    if not blk:
        return None
    m = int(blk[0], 16)
    usr1 = 1 << (signal.SIGUSR1 - 1)
    term = 1 << (signal.SIGTERM - 1)
    return pid if (m & term) and not (m & usr1) else None


def _supervisor_exit_status(sup):
    """reap an ended supervisor without blocking"""
    try:
        pid, status = os.waitpid(sup, os.WNOHANG)
    except (ChildProcessError, OSError):
        return None
    return status if pid == sup else None


def supervisor_refused(status):
    """return whether a supervisor's wait status is the refusal exit"""
    return (status is not None and os.WIFEXITED(status)
            and os.WEXITSTATUS(status) == selinux_ns.RELABELLER_REFUSED_EXIT)


def _supervisor_exit_note(status):
    """return the exit note for a supervisor's wait status"""
    if status is None:
        return ""
    if os.WIFEXITED(status):
        code = os.WEXITSTATUS(status)
        return " (exit %d, log %s)" % (code, SUPERVISOR_LOG) if code else " (exit 0)"
    if os.WIFSIGNALED(status):
        return " (killed by signal %d)" % os.WTERMSIG(status)
    return " (status %d)" % status


def i_am_recorded_supervisor():
    """return whether recorded_pid() is os.getpid()"""
    return recorded_pid() == os.getpid()


def recorded_g_alive():
    """return whether the recorded supervisor pid is still a live launcher"""
    pid = recorded_pid()
    if pid is None:
        return False
    try:
        is_python = open(f"/proc/{pid}/comm").read().strip().startswith("python")
    except OSError:
        return False
    return is_python and (host_selinux_mode() or runs_this_launcher(pid))


def runs_this_launcher(pid):
    """return whether pid runs sys.argv[0]"""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            argv = f.read().split(b"\0")
    except OSError:
        return False
    if len(argv) < 2:
        return False
    script = os.path.join(f"/proc/{pid}/cwd", os.fsdecode(argv[1]))
    return os.path.realpath(script) == os.path.realpath(sys.argv[0])


def boot_started_at():
    """return the /proc/stat btime"""
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("btime "):
                return int(line.split()[1])
    raise OSError("/proc/stat has no btime line")


def launcher_code_identity(script=__file__):
    """return a hash of the launcher's code files"""
    script = os.path.realpath(script)
    directory = os.path.dirname(script)
    digest = hashlib.sha256()
    try:
        modules = sorted(n for n in os.listdir(directory) if n.startswith("rhizo_") and n.endswith(".py"))
        for path in [script] + [os.path.join(directory, n) for n in modules]:
            with open(path, "rb") as f:
                digest.update(os.path.basename(path).encode() + b"\0" + hashlib.sha256(f.read()).digest())
    except OSError as e:
        return f"unreadable-{errno.errorcode.get(e.errno, e.errno)}"
    return digest.hexdigest()[:16]


LOADED_CODE_ID = launcher_code_identity()


def read_supervisor_record():
    """return the supervisor record fields of G_PID_FILE"""
    with open(G_PID_FILE) as f:
        fields = f.read().split()
    if not 1 <= len(fields) <= 4:
        raise ValueError(f"{G_PID_FILE} is {fields!r}, expected <pid> [<boot id> [<code id> [<start time>]]]")
    fields += [""] * (4 - len(fields))
    return int(fields[0]), fields[1], fields[2], fields[3]


def process_start_time(pid):
    """return pid's start time in clock ticks after boot"""
    try:
        fd = os.open(f"/proc/{pid}/stat", os.O_RDONLY)
        try:
            raw = os.read(fd, 4096).decode(errors="replace")
        finally:
            os.close(fd)
        return int(raw[raw.rindex(")") + 2:].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def supervisor_record(pid):
    """return the G_PID_FILE text for pid"""
    if host_selinux_mode():
        return str(pid)
    start = process_start_time(pid)
    if start is None:
        raise OSError(f"failed to read the start time of {pid}")
    return f"{pid} {host_boot_id()} {LOADED_CODE_ID} {start}"


def record_supervisor_pid():
    """write the supervisor record of os.getpid() to G_PID_FILE"""
    record = supervisor_record(os.getpid())
    with open(G_PID_FILE, "w") as f:
        f.write(record)


RECORD_WITHOUT_START_TIME = "the record has no start time"


def supervisor_record_refusal(record):
    """return why a supervisor record is not a process of the current boot, or None"""
    pid, boot, _code, start = record
    try:
        this_boot = host_boot_id()
    except OSError as e:
        return f"failed to read the boot id ({e})"
    if boot != this_boot:
        return f"boot id is {boot or '<none>'}, expected {this_boot}"
    if not start:
        return RECORD_WITHOUT_START_TIME
    now = process_start_time(pid)
    if now is None:
        return f"pid {pid} is not running"
    if str(now) != start:
        return f"pid {pid} start time is {now}, recorded {start}"
    return None


def supervisor_state():
    """return the recorded supervisor's state file text"""
    with open(SUPERVISOR_STATE) as f:
        return f.read().strip()


def code_identity_matches(recorded):
    """return whether recorded is LOADED_CODE_ID and LOADED_CODE_ID is readable"""
    return recorded == LOADED_CODE_ID and not LOADED_CODE_ID.startswith("unreadable")


def supervisor_busy(pid, handoff_dir=None):
    """return why a parked supervisor is busy, or None"""
    handoff_dir = handoff_dir or HANDOFF_DIR
    try:
        entries = [n for n in os.listdir(handoff_dir) if not n.startswith(".")]
    except FileNotFoundError:
        entries = []
    except OSError as e:
        return f"failed to list the handoff dir ({e})"
    if entries:
        return f"pending handoff entries {' '.join(sorted(entries))}"
    try:
        with open(f"/proc/{pid}/status") as f:
            pending = [l.split()[1] for l in f if l.startswith(("SigPnd:", "ShdPnd:"))]
    except OSError as e:
        return f"failed to read /proc/{pid}/status ({e})"
    usr1 = 1 << (signal.SIGUSR1 - 1)
    if len(pending) != 2 or any(int(m, 16) & usr1 for m in pending):
        return f"a wake is pending ({' '.join(pending) or 'no mask'})"
    return None


def release_stale_supervisor(pid, code, log, handoff_dir=None):
    """end a parked supervisor running other code"""
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        log(f"stale supervisor {pid} is not running")
        return False
    try:
        if not runs_this_launcher(pid):
            log(f"stale supervisor {pid} does not run {os.path.basename(sys.argv[0])}")
            return False
        try:
            state = supervisor_state()
        except OSError as e:
            state = f"unreadable:{e.errno}"
        busy = None if state != "parked" else supervisor_busy(pid, handoff_dir)
        if state != "parked" or busy:
            log(f"RHIZO_MARKER selinuxns=supervisor-stale pid={pid} recorded={code or '<none>'} "
                f"installed={LOADED_CODE_ID} state={state} sigkill=0 ({busy or 'not parked'})")
            return False
        signal.pidfd_send_signal(fd, signal.SIGKILL)
        select.select([fd], [], [], 5)
    finally:
        os.close(fd)
    try:
        if read_recorded_pid() == pid:
            os.unlink(G_PID_FILE)
    except (OSError, ValueError) as e:
        log(f"failed to remove {G_PID_FILE} ({e})")
    log(f"RHIZO_MARKER selinuxns=supervisor-stale pid={pid} recorded={code or '<none>'} "
        f"installed={LOADED_CODE_ID} state=parked sigkill=1")
    return True


def read_recorded_pid():
    """return the pid field of G_PID_FILE"""
    return read_supervisor_record()[0]


def recorded_pid():
    """return the pid field of G_PID_FILE for the current boot, or None"""
    try:
        record = read_supervisor_record()
    except (OSError, ValueError):
        return None
    if not host_selinux_mode() and supervisor_record_refusal(record):
        return None
    return record[0]


def may_record_supervisor(dom, recorded, recorded_alive, parent_pid):
    """return whether the supervisor writes G_PID_FILE"""
    if host_selinux_mode():
        return dom == "kernel" or dom.startswith("u:r:kernel:")
    return not recorded_alive or recorded == parent_pid


def record_refusal_unless_final(reason, records_dir=SELINUXNS_RECORDS_DIR, keep=hostlock.is_final_verdict):
    """record a refusal over an unfinished verdict"""
    try:
        records_fd = selinux_ns.open_records_dir(records_dir)
    except OSError as e:
        selinux_ns.report_record_write_failure(records_dir, f"refused:{reason}", e)
        return False
    try:
        if not selinux_ns.record_verdict(f"refused:{reason}", records_fd, keep=keep):
            return False
        kmsg(f"RHIZO_MARKER selinuxns=refused reason={reason}")
        selinux_ns.record_android_enforce("0", records_fd)
        return True
    finally:
        os.close(records_fd)


def wait_status_word(status):
    """return a wait status as a word"""
    if status is None:
        return "gone"
    if os.WIFEXITED(status):
        return f"exit-{os.WEXITSTATUS(status)}"
    return f"signal-{os.WTERMSIG(status)}" if os.WIFSIGNALED(status) else f"status-{status}"


def start_exit_reason(e):
    """return the refusal reason for exception e"""
    if not isinstance(e, SystemExit):
        return f"launcher-raised-{e.__class__.__name__}"
    if isinstance(e.code, str):
        words = e.code.split()
        if len(words) > 1 and words[0] == "RHIZO_MARKER":
            return selinux_ns.clean_reason(words[1].encode())
        return "launcher-refused"
    return f"launcher-exit-{e.code}"


def run_sandbox_or_refuse(entry, records_dir=SELINUXNS_RECORDS_DIR):
    """run the sandbox and record a refusal on an early end"""
    caller = os.getpid()
    try:
        return run_sandbox(entry)
    except BaseException as e:
        if host_selinux_mode() or os.getpid() != caller or (isinstance(e, SystemExit) and not e.code):
            raise
        record_refusal_unless_final(start_exit_reason(e), records_dir)
        refuse_start()


def start_refused(records_dir=SELINUXNS_RECORDS_DIR):
    """return whether the start's verdict is a refusal"""
    try:
        records_fd = selinux_ns.open_records_dir(records_dir)
        try:
            return selinux_ns.read_verdict(records_fd).startswith("refused:")
        finally:
            os.close(records_fd)
    except OSError as e:
        kmsg(f"failed to read the verdict in {records_dir} ({e!r})")
        return True


def supervisor_end_fails_unit(status, records_dir=SELINUXNS_RECORDS_DIR):
    """return whether the supervisor's end fails the unit"""
    if host_selinux_mode():
        return supervisor_refused(status)
    left_unfinished = record_refusal_unless_final(f"supervisor-{wait_status_word(status)}", records_dir)
    return supervisor_refused(status) or left_unfinished or start_refused(records_dir)


def start_ended(current):
    """return whether current is a start's end verdict"""
    return selinux_ns.keep_refusal(current) or current == "stopped"


def sandbox_end_fails_unit(status, records_dir=SELINUXNS_RECORDS_DIR):
    """record a refusal for a nonzero status and return start_refused(records_dir)"""
    if status is None or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        record_refusal_unless_final(f"g-{wait_status_word(status)}", records_dir, keep=start_ended)
    return start_refused(records_dir)


def read_sandbox_end(end_fd):
    """read the wait status from end_fd"""
    raw = os.read(end_fd, 32).decode(errors="replace").strip()
    os.close(end_fd)
    return int(raw) if raw.lstrip("-").isdigit() else None


def report_sandbox_end(end_fd, status, log):
    """write the first sandbox's wait status to MainPID"""
    try:
        os.write(end_fd, str(status).encode())
    except OSError as e:
        log(f"failed to write status={status} to end_fd ({e})")
    os.close(end_fd)


_START_RECORDS_OWNER = {"pid": None, "dir": None}


def close_out_owned_start(e):
    """record the ended start of os.getpid() as refused"""
    if _START_RECORDS_OWNER["pid"] != os.getpid() or (isinstance(e, SystemExit) and not e.code):
        return
    record_refusal_unless_final(start_exit_reason(e), _START_RECORDS_OWNER["dir"])


def exit_g_refused(reason, records_fd):
    """record g's refusal and exit"""
    if records_fd < 0:
        os._exit(1)
    kmsg(f"RHIZO_MARKER selinuxns=refused reason={reason}")
    selinux_ns.record_start_end(f"refused:{reason}", records_fd)
    os._exit(selinux_ns.RELABELLER_REFUSED_EXIT)


def refuse_handoff(gg, reason, records_fd):
    """record a failed handoff and kill gg"""
    kmsg(f"RHIZO_MARKER selinuxns=refused reason={reason}")
    selinux_ns.record_start_end(f"refused:{reason}", records_fd)
    try:
        os.kill(gg, signal.SIGKILL)
    except ProcessLookupError:
        kmsg(f"namespace holder {gg} is not running")


def refuse_start_before_init(g, reason, records_dir=SELINUXNS_RECORDS_DIR):
    """kill g, record the refusal, refuse"""
    kmsg(f"RHIZO_MARKER selinuxns=refused reason={reason}")
    os.kill(g, signal.SIGKILL)
    os.waitpid(g, 0)
    try:
        records_fd = selinux_ns.open_records_dir(records_dir)
    except OSError as e:
        selinux_ns.report_record_write_failure(records_dir, f"refused:{reason}", e)
    else:
        selinux_ns.record_start_end(f"refused:{reason}", records_fd)
        os.close(records_fd)
    refuse_start()


def open_records_or_refuse(records_dir):
    """open the namespace records dir or refuse the start"""
    try:
        return selinux_ns.open_records_dir(records_dir)
    except OSError as e:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=records-dir-failed errno={e.errno} path={records_dir}")
        refuse_start()


def refuse_start():
    """end a refused namespace-mode start"""
    if i_am_recorded_supervisor():
        try:
            os.unlink(G_PID_FILE)
        except OSError as e:
            kmsg(f"failed to remove {G_PID_FILE} ({e})")
    sys.exit(selinux_ns.RELABELLER_REFUSED_EXIT if _MY_SUPERVISOR_PID == os.getpid() else 1)


def release_host_lock_permissive(fd, deadline_s=60, poll_s=0.25):
    """release the host lock after a permissive boot"""
    deadline = time.time() + deadline_s
    loaded = sup = False
    while time.time() < deadline:
        if host_selinux_mode():
            loaded = policy_is_loaded()
        else:
            verdict = hostlock.selinuxns_verdict()
            if hostlock.is_final_verdict(verdict) and verdict != "permissive":
                hostlock.release_host_lock(fd)
                kmsg(f"host lock released permissive verdict={verdict}")
                return
            loaded = verdict == "permissive"
        sup = recorded_g_alive()
        if loaded and sup:
            break
        time.sleep(poll_s)
    if not (loaded and sup):
        kmsg(f"policy_loaded={loaded} supervisor_seen={sup} after {deadline_s}s")
    hostlock.release_host_lock(fd)
    kmsg(f"host lock released permissive policy_loaded={loaded} supervisor_seen={sup}")


def await_resident_g(seconds=60):
    """wait for the parked supervisor and return the supervisor pid, or None"""
    try:
        record = read_supervisor_record()
    except (OSError, ValueError) as e:
        kmsg(f"no supervisor recorded ({e.__class__.__name__})")
        return None
    pid = record[0]
    refusal = None if host_selinux_mode() else supervisor_record_refusal(record)
    if refusal and refusal != RECORD_WITHOUT_START_TIME:
        kmsg(f"recorded supervisor {pid} refused ({refusal})")
        return None
    if not pid_is_live(pid, kmsg):
        kmsg(f"recorded supervisor {pid} is not running")
        return None
    if not host_selinux_mode() and not runs_this_launcher(pid):
        kmsg(f"recorded supervisor {pid} does not run {os.path.basename(sys.argv[0])}")
        return None
    if pid == _MY_SUPERVISOR_PID:
        kmsg(f"recorded supervisor {pid} is _MY_SUPERVISOR_PID")
        return None
    if not host_selinux_mode():
        try:
            code = read_supervisor_record()[2]
        except (OSError, ValueError) as e:
            code = f"unreadable:{e!r}"
        if not code_identity_matches(code):
            release_stale_supervisor(pid, code, kmsg)
            return None
    if refusal:
        kmsg(f"recorded supervisor {pid} refused ({refusal})")
        return None
    kmsg(f"waiting for supervisor {pid} to park")
    for _ in range(seconds * 4):
        rg = resident_g_pid()
        if rg:
            return rg
        if not pid_is_live(pid, kmsg):
            kmsg(f"supervisor {pid} exited before parking")
            return None
        time.sleep(0.25)
    kmsg(f"supervisor {pid} did not park in {seconds}s")
    return None


def drain_handoffs(handoff_dir, active_ids, pid_is_live=pid_is_live, log=lambda *_: None):
    """claim the handoff entries not in active_ids"""
    claimed = []
    try:
        names = os.listdir(handoff_dir)
    except OSError as e:
        log(f"failed to list the handoff dir ({e})")
        return claimed
    for name in names:
        if name.startswith("."):
            continue
        if not name.isdigit():
            log(f"skipped handoff dir entry {name!r}")
            continue
        instance_id = int(name)
        if instance_id in active_ids:
            continue
        path = os.path.join(handoff_dir, name)
        try:
            raw = open(path).read().split()
        except OSError as e:
            log(f"failed to read handoff entry {name} ({e})")
            continue
        try:
            os.unlink(path)
        except OSError as e:
            log(f"failed to unlink claimed handoff entry {name} ({e})")
        if len(raw) != 2 or not raw[0].isdigit():
            log(f"handoff entry {name} is malformed ({raw!r})")
            continue
        pid1, entry = int(raw[0]), raw[1]
        if not pid_is_live(pid1, log):
            log(f"dropped handoff entry {name}, pid1={pid1} is not live")
            continue
        claimed.append((instance_id, pid1, entry))
    return claimed


def sandbox_init_pids():
    """return the host pids of the /system/bin/init processes"""
    found = set()
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            argv = open(f"/proc/{d}/cmdline", "rb").read().split(b"\0")
        except OSError:
            continue
        if argv and argv[0] == b"/system/bin/init":
            found.add(int(d))
    return found




_JOIN_FAILED = 126


def release_namespace_holder(holder_fd, pid, log):
    """SIGKILL the namespace holder through holder_fd"""
    try:
        signal.pidfd_send_signal(holder_fd, signal.SIGKILL)
        log(f"killed the namespace holder {pid}")
    except ProcessLookupError:
        log(f"namespace holder {pid} is already reaped")
    except OSError as e:
        log(f"failed to kill the namespace holder {pid} ({e})")
    finally:
        os.close(holder_fd)


def refuse_unwatchable_holder(instance_id, pid, err, log, kill=os.kill, records_dir=None):
    """refuse a handoff when pidfd_open fails on the holder"""
    reason = f"holder-pidfd-{errno.errorcode.get(err.errno, err.errno)}"
    log(f"pidfd_open failed on namespace holder {pid} of instance {instance_id} ({err}), refused as {reason}")
    if not host_selinux_mode():
        record_refusal_unless_final(reason, records_dir or core.paths_for(instance_id).records_dir)
    try:
        kill(pid, signal.SIGKILL)
        log(f"killed the namespace holder {pid} by pid")
    except ProcessLookupError:
        log(f"namespace holder {pid} is not running")
    except OSError as e:
        log(f"failed to kill the namespace holder {pid} ({e})")


def wait_init_under_holder(init_pid, holder_fd):
    """wait for init and SIGKILL init when holder_fd exits first"""
    init_fd = os.pidfd_open(init_pid)
    try:
        ready, _, _ = select.select([init_fd, holder_fd], [], [])
        if holder_fd in ready and init_fd not in ready:
            print(f"namespace holder exited before init {init_pid}, SIGKILL init",
                  flush=True)
            signal.pidfd_send_signal(init_fd, signal.SIGKILL)
    finally:
        os.close(init_fd)
    return os.waitpid(init_pid, 0)[1]


def _join_and_exec_init(pid, entry, instance_id):
    """enter pid's namespaces and fork the sandbox init"""
    if not join_instance_init_cgroup(instance_id, os.getpid(),
                                     lambda m: print(m, flush=True)):
        print(f"join_instance_init_cgroup failed for instance {instance_id}",
              flush=True)
        return _JOIN_FAILED
    try:
        holder_fd = os.pidfd_open(pid)
    except OSError as e:
        print(f"pidfd_open failed on namespace holder {pid} ({e})", flush=True)
        return _JOIN_FAILED
    init_pid_file = core.paths_for(instance_id).init_pid_file
    try:
        pidfd = os.open(init_pid_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    except OSError as e:
        print(f"failed to open the init pid file ({e})", flush=True)
        pidfd = -1
    ns_mode = not host_selinux_mode()
    keeper_fd = records_fd = -1
    try:
        if ns_mode:
            try:
                records_fd = selinux_ns.open_records_dir(core.paths_for(instance_id).records_dir)
                selinux_ns.record_verdict("pending", records_fd)
                selinux_ns.record_android_enforce("0", records_fd)
                try:
                    write_primer_script()
                except OSError as e:
                    kmsg(f"RHIZO_MARKER selinuxns=pass-failed name=write-primer-script err={e!r}")
                keeper = selinux_ns.find_view_keeper(pid)
                if keeper is not None:
                    keeper_fd = os.pidfd_open(keeper)
                    view_fd = os.open(f"/proc/{keeper}/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
                    relabel_env = selinux_ns.holder_environ(pid)
                    launcher_path = os.path.realpath(__file__)
                    done_r, done_w = os.pipe2(os.O_CLOEXEC)
            except OSError as e:
                print(f"failed to open the namespace handoff inputs ({e})", flush=True)
                if records_fd >= 0:
                    selinux_ns.record_verdict("refused:join-inputs", records_fd)
                if pidfd >= 0:
                    os.close(pidfd)
                return _JOIN_FAILED
            if keeper is None:
                selinux_ns.record_verdict("refused:no-view-keeper", records_fd)
                print("find_view_keeper returned None", flush=True)
                if pidfd >= 0:
                    os.close(pidfd)
                return _JOIN_FAILED
            host_selinuxfs = []
            try:
                host_selinuxfs.append(selinux_ns.open_host_selinuxfs())
                host_selinuxfs_dev = os.fstat(host_selinuxfs[0]).st_dev
            except OSError as e:
                for fd in host_selinuxfs:
                    os.close(fd)
                selinux_ns.record_verdict("refused:host-selinuxfs", records_fd)
                print(f"failed to open the host selinuxfs ({e})", flush=True)
                if pidfd >= 0:
                    os.close(pidfd)
                return _JOIN_FAILED

            def release_host_selinuxfs():
                """close the joiner's host selinuxfs handle"""
                while host_selinuxfs:
                    os.close(host_selinuxfs.pop())

            verdicts = []

            def on_verdict(verdict):
                """record and log a namespace verdict and kill the view keeper"""
                release_host_selinuxfs()
                verdicts.append(verdict)
                selinux_ns.record_verdict(verdict, records_fd)
                if verdict == "enforced":
                    selinux_ns.record_android_enforce("1", records_fd)
                kmsg(f"RHIZO_MARKER selinuxns=handoff-verdict {verdict}")
                print(f"namespace verdict {verdict}", flush=True)
                selinux_ns.kill_view_keeper(keeper_fd)
        order = ["mnt", "net", "ipc", "uts", "cgroup"]
        fds, failed = {}, []
        if capabilities.policy_or_deny(log=kmsg).allows("devices.uinput"):
            start_input_units(instance_id)
            core.set_uinput_filtered(True)
            core.set_input_supervisor(connect_input_supervisor(instance_id))
        for name in order:
            try:
                fds[name] = os.open(f"/proc/{pid}/ns/{name}", os.O_RDONLY)
            except OSError as e:
                failed.append(f"open({name}) failed ({e})")
        if failed:
            for f in fds.values():
                os.close(f)
            if pidfd >= 0:
                os.close(pidfd)
            print(f"failed to open {len(failed)} of {len(order)} namespaces of {pid} "
                  + "; ".join(failed), flush=True)
            if ns_mode:
                selinux_ns.record_verdict("refused:join-open-namespaces", records_fd)
            return _JOIN_FAILED
        for name in order:
            if libc.setns(fds[name], 0) != 0:
                print(f"setns({name}) failed errno={ctypes.get_errno()}", flush=True)
                for f2 in fds.values():
                    try:
                        os.close(f2)
                    except OSError:
                        pass
                if pidfd >= 0:
                    os.close(pidfd)
                if ns_mode:
                    selinux_ns.record_verdict(f"refused:join-setns-{name}", records_fd)
                return _JOIN_FAILED
            os.close(fds[name])
        print(f"joined {len(order)} namespaces of {pid}", flush=True)
        if libc.unshare(CLONE_NEWPID) != 0:
            print(f"unshare(CLONE_NEWPID) failed errno={ctypes.get_errno()}", flush=True)
            if pidfd >= 0:
                os.close(pidfd)
            if ns_mode:
                selinux_ns.record_verdict("refused:join-unshare-pid", records_fd)
            return _JOIN_FAILED
        child = os.fork()
        if child == 0:
            if ns_mode:
                release_host_selinuxfs()
            for _p in ("/proc/self/stat", "/apex"):
                try:
                    if _p.startswith("/proc"):
                        print(f"sandbox /proc/self/stat pid "
                              f"{open(_p).read().split()[0]}", flush=True)
                    else:
                        print(f"sandbox {_p} "
                              f"{sorted(os.listdir(_p))[:14]}", flush=True)
                except OSError as e:
                    print(f"failed to read sandbox {_p} ({e})", flush=True)
            if ns_mode:
                selinux_ns.unshare_namespace(state_file=None)
            if not mount("proc", "/proc", "proc", 0, f"hidepid=2,gid={AID_READPROC}"):
                print("failed to mount /proc in pid 1", flush=True)
            try:
                if ns_mode:
                    os.close(done_r)
                    selinux_ns.begin_handoff_namespace(view_fd, done_w, relabel_env, launcher_path,
                                                            sys.executable, host_selinuxfs_dev)
                    os.close(done_w)
                enter_sandbox_init(entry, own_proc_sys=False)
            except BaseException as e:
                print(f"exec of init failed ({e})", flush=True)
            os._exit(127)
        print(f"forked init {child} into the namespaces of {pid}", flush=True)
        if ns_mode:
            os.close(done_w)
            os.close(view_fd)
        if pidfd >= 0:
            try:
                os.write(pidfd, str(child).encode())
            except OSError as e:
                print(f"failed to write init pid {child} ({e})", flush=True)
            os.close(pidfd)
        _t0 = time.time()
        try:
            if ns_mode:
                verdict, st = selinux_ns.watch_handed_off_init(
                    child, done_r, time.time() + selinux_ns.RELABELLER_DEADLINE_S, on_verdict,
                    stop_requested=lambda: selinux_ns.stop_requested(records_fd), holder_fd=holder_fd)
            else:
                st = wait_init_under_holder(child, holder_fd)
        except Exception as e:
            print(f"watch of init {child} raised {e!r}", flush=True)
            if ns_mode:
                release_host_selinuxfs()
            if ns_mode and not verdicts:
                try:
                    os.kill(child, signal.SIGKILL)
                except OSError as ke:
                    print(f"failed to kill init {child} ({ke!r})", flush=True)
                kmsg("RHIZO_MARKER selinuxns=refused reason=relabeller-watcher-raised")
                selinux_ns.record_verdict("refused:relabeller-watcher-raised", records_fd)
                return 0
            if not ns_mode:
                return 0
            kmsg(f"RHIZO_MARKER selinuxns=watch-raised-after-verdict verdict={verdicts[-1]} err={e!r}")
            try:
                _, st = os.waitpid(child, 0)
            except OSError as we:
                print(f"waitpid failed on init {child} ({we!r})", flush=True)
                st = None
            if ns_mode and verdicts[-1] in ("enforced", "permissive"):
                selinux_ns.record_start_end(verdicts[-1], records_fd)
            if st is None:
                return 0
        else:
            if ns_mode:
                release_host_selinuxfs()
            if ns_mode and verdict in ("enforced", "permissive"):
                selinux_ns.record_start_end(verdict, records_fd)
        _lived = time.time() - _t0
        if os.WIFSIGNALED(st):
            print(f"init {child} killed by signal {os.WTERMSIG(st)} "
                  f"after {_lived:.1f}s", flush=True)
        elif os.WIFEXITED(st):
            print(f"init {child} exited status={os.WEXITSTATUS(st)} "
                  f"after {_lived:.1f}s", flush=True)
        else:
            print(f"init {child} ended status={st} after {_lived:.1f}s", flush=True)
        return 0
    finally:
        os.close(holder_fd)
        if keeper_fd >= 0:
            selinux_ns.kill_view_keeper(keeper_fd)


def open_handoff_entry(instance_id):
    """open a temp handoff entry and HANDOFF_DIR"""
    tmp_name = f".{instance_id}.{os.getpid()}.tmp"
    try:
        dir_fd = os.open(HANDOFF_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    except OSError as e:
        kmsg(f"failed to open the handoff dir ({e})")
        return -1, -1, None
    try:
        fd = os.open(tmp_name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600, dir_fd=dir_fd)
    except OSError as e:
        kmsg(f"failed to open the handoff entry ({e})")
        os.close(dir_fd)
        return -1, -1, None
    return fd, dir_fd, tmp_name


def ensure_init_pid_file():
    """create INIT_PID_FILE"""
    try:
        os.close(os.open(INIT_PID_FILE, os.O_WRONLY | os.O_CREAT, 0o600))
    except OSError as e:
        kmsg(f"failed to create the init pid file ({e})")


def handoff_wire_format(pid1, entry):
    """return the handoff entry bytes"""
    return f"{pid1} {entry}".encode()


def hand_off_to_supervisor(sup, fd, dir_fd, tmp_name, pid1, entry, instance_id, why=None):
    """write the handoff entry and signal the supervisor"""
    why = [] if why is None else why
    try:
        if fd < 0 or dir_fd < 0:
            kmsg(f"handoff to supervisor {sup} failed, no pre-pivot descriptor")
            why.append("no-descriptor")
            return False
        try:
            os.write(fd, handoff_wire_format(pid1, entry))
        except OSError as e:
            kmsg(f"failed to write the handoff entry for supervisor {sup} ({e})")
            why.append(f"record-{errno.errorcode.get(e.errno, e.errno)}")
            return False
        finally:
            try: os.close(fd)
            except OSError: pass
        try:
            os.rename(tmp_name, str(instance_id), src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        except OSError as e:
            kmsg(f"failed to rename the handoff entry for supervisor {sup} ({e})")
            why.append(f"publish-{errno.errorcode.get(e.errno, e.errno)}")
            return False
        try:
            os.kill(sup, signal.SIGUSR1)
        except OSError as e:
            kmsg(f"failed to signal supervisor {sup} ({e})")
            why.append(f"signal-{errno.errorcode.get(e.errno, e.errno)}")
            try:
                os.unlink(str(instance_id), dir_fd=dir_fd)
            except FileNotFoundError:
                kmsg(f"handoff entry {instance_id} is already claimed")
            except OSError as ue:
                kmsg(f"failed to unlink handoff entry {instance_id} ({ue})")
            return False
        kmsg(f"handed the pivoted namespaces (pid1={pid1}) to supervisor {sup} for instance {instance_id}")
        return True
    finally:
        if dir_fd >= 0:
            try: os.close(dir_fd)
            except OSError: pass


def describe_sandbox_cgroups():
    """log the mode, owner and label of the sandbox cgroup paths"""
    for p in ("/sys/fs/cgroup", "/sys/fs/cgroup/apps", "/sys/fs/cgroup/system"):
        try:
            st = os.stat(p)
            kmsg("sandbox %s mode=%o uid=%d gid=%d entries=%s"
                 % (p, st.st_mode & 0o7777, st.st_uid, st.st_gid,
                    sorted(os.listdir(p))))
        except OSError as e:
            kmsg(f"failed to stat sandbox {p} ({e})")
    for p in ("/etc", "/etc/cgroups.json", "/dev/cgroup_info"):
        try:
            lst = os.lstat(p)
            what = "symlink -> " + os.readlink(p) if os.path.islink(p) else "mode=%o" % (lst.st_mode & 0o7777)
            try:
                lbl = os.getxattr(p, "security.selinux", follow_symlinks=False).decode().rstrip("\x00")
            except OSError as e:
                lbl = f"<no label errno={e.errno}>"
            kmsg(f"sandbox {p} {what} uid={lst.st_uid} label={lbl}")
        except OSError as e:
            kmsg(f"failed to stat sandbox {p} ({e})")


def hold_pid_namespace_open(fatal_child=None):
    """wait on SIGCHLD and reap orphans in the sandbox pid namespace"""
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGCHLD})
    while True:
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if pid == 0:
                break
            if pid == fatal_child and status != 0:
                kmsg(f"hardening fork {pid} exited {status}")
                os._exit(1)
        signal.sigwait({signal.SIGCHLD})


def enter_sandbox_init(entry, own_proc_sys=True):
    """drop caps and exec the sandbox init"""
    if not host_selinux_mode():
        _refusal = ("init-outside-namespace" if not selinux_ns.state()["unshared"] else
                    "namespace-policy-loaded" if ":" in selinux_ns.host_context() else None)
        if _refusal:
            kmsg(f"RHIZO_MARKER selinuxns=refused reason={_refusal}")
            os._exit(1)
        if not cap_pid_namespace_pid_max():
            kmsg("RHIZO_MARKER selinuxns=refused reason=pid-max-unset")
            os._exit(1)
    if own_proc_sys:
        setup_net_core_sysctls()
    _sup = core.input_supervisor()
    if core.uinput_filtered():
        _filter = install_uinput_filter(_sup)
        if _sup is not None:
            _sup.close()
            core.set_input_supervisor(None)
        if not _filter:
            kmsg("failed to install the uinput filter")
            os._exit(1)
        kmsg(f"RHIZO_MARKER input_owner=filter-installed mode={_filter}")
    if not install_handle_filter():
        kmsg("failed to install the open_by_handle_at filter")
        os._exit(1)
    if host_selinux_mode() and policy_is_loaded():
        kmsg("RHIZO_MARKER init_groups=skipped reason=host-policy-loaded")
    else:
        try:
            os.setgroups([AID_READPROC])
        except OSError as e:
            kmsg(f"RHIZO_MARKER selinuxns=refused reason=init-groups err={e!r}")
            os._exit(1)
    drop_caps()
    os.environ.clear()
    os.environ["PATH"]="/system/bin:/system/xbin"
    os.environ["ANDROID_ROOT"]="/system"
    os.environ["ANDROID_DATA"]="/data"
    os.environ["ANDROID_STORAGE"]="/storage"
    os.environ["ANDROID_ART_ROOT"]="/apex/com.android.art"
    os.environ["ANDROID_I18N_ROOT"]="/apex/com.android.i18n"
    os.environ["ANDROID_TZDATA_ROOT"]="/apex/com.android.tzdata"
    os.environ["ANDROID_RUNTIME_ROOT"]="/apex/com.android.runtime"
    os.environ["ASEC_MOUNTPOINT"]="/mnt/asec"
    os.environ["EXTERNAL_STORAGE"]="/sdcard"
    if selinux_ns.state()["unshared"]:
        selinux_ns.join_landlock_domain()
    phase("C", "exec_init")
    core.stdio_to_null()
    try:
        os.execv("/system/bin/init", ["/system/bin/init", entry])
    except OSError as e:
        kmsg(f"exec of init failed ({e})")
    os._exit(127)


def _policy_only_load(slog):
    """load the staged precompiled policy"""
    try:
        privileged_setup()
    except SystemExit:
        raise
    except Exception as e:
        slog(f"privileged_setup() raised {e!r}")
        return False, None, None
    release_host_staging(run_root=f"{RUN_ROOT}/data", reach=(), who="--policy-only", vbmeta_record=None)
    pc = f"{RUN_ROOT}/vendor/etc/selinux/precompiled_sepolicy"
    if not os.path.exists(pc):
        slog(f"privileged_setup() did not stage {pc}")
        return False, None, None
    if policy_is_loaded():
        slog(f"a policy is already loaded ctx={own_domain()!r} after privileged_setup()")
        return False, None, None
    try:
        policy_bytes = open(pc, "rb").read()
    except OSError as e:
        slog(f"failed to read {pc} ({e})")
        return False, None, None
    try:
        _load_fd = os.open("/sys/fs/selinux/load", os.O_WRONLY)
        try:
            _n = os.write(_load_fd, policy_bytes)
        finally:
            os.close(_load_fd)
        if _n != len(policy_bytes):
            slog(f"short write to /sys/fs/selinux/load ({_n} of {len(policy_bytes)} bytes)")
            return False, None, None
    except OSError as e:
        slog(f"failed to write /sys/fs/selinux/load ({e})")
        return False, None, None
    if not policy_is_loaded():
        slog("policy_is_loaded() returned False after the write to /sys/fs/selinux/load")
        return False, None, None
    digest = hashlib.sha256(policy_bytes).hexdigest()
    slog(f"loaded the policy bytes={len(policy_bytes)} sha256={digest}")
    return True, digest, len(policy_bytes)


def _wait_for_primer_flip(slog, deadline_s=500):
    """wait for /run/rhizo-primer-flipped with enforce=1"""
    marker = "/run/rhizo-primer-flipped"
    deadline = time.time() + deadline_s
    while time.time() < deadline:
        if os.path.exists(marker):
            break
        time.sleep(0.5)
    else:
        return False, f"no {marker} after {deadline_s}s"
    try:
        fields = {}
        for line in open(marker):
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                fields[k] = v
    except OSError as e:
        return False, f"failed to read {marker} ({e})"
    enforce = fields.get("enforce", "?")
    stuck = fields.get("still_in_kernel_domain", "")
    if enforce != "1":
        return False, f"{marker} enforce={enforce}, expected 1"
    if stuck:
        return False, f"{marker} still_in_kernel_domain={stuck}"
    return True, f"enforce={enforce} still_in_kernel_domain=none"


_POLICY_STATE_WRITER = """\
import os, sys
path, text = sys.argv[1:3]
tmp = os.path.join(os.path.dirname(path), ".%s.tmp" % os.path.basename(path))
with open(tmp, "w") as f:
    f.write(text)
os.replace(tmp, path)
"""


def _write_policy_loaded_state(digest, byte_count, loaded_by="rhizo-policy.service"):
    """write /run/rhizo-policy-loaded"""
    state_lines = (
        "# written by --policy-only\n"
        f"loaded_at={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n"
        f"loaded_by={loaded_by}\n"
        f"sha256={digest or ''}\n"
        f"bytes={byte_count or ''}\n"
        f"release={os.environ.get('RHIZO_RELEASE', '')}\n"
        f"pid={os.getpid()}\n"
    )
    domain = own_domain()
    if policy_is_loaded() and (domain == "kernel" or domain.startswith("u:r:kernel:")):
        try:
            r = subprocess.run([sys.executable, "-I", "-c", _POLICY_STATE_WRITER,
                                POLICY_LOADED_STATE, state_lines],
                               input="", capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as e:
            kmsg(f"failed to run the {POLICY_LOADED_STATE} writer ({e})")
            return False
        if r.returncode != 0:
            why = (r.stderr.strip().splitlines() or ["no output"])[-1]
            kmsg(f"{POLICY_LOADED_STATE} writer exited {r.returncode} ({why})")
            return False
        return True
    try:
        tmp = os.path.join(os.path.dirname(POLICY_LOADED_STATE),
                           ".%s.tmp" % os.path.basename(POLICY_LOADED_STATE))
        with open(tmp, "w") as f:
            f.write(state_lines)
        os.replace(tmp, POLICY_LOADED_STATE)
        return True
    except OSError as e:
        kmsg(f"failed to write {POLICY_LOADED_STATE} ({e})")
        return False


def _read_node(path):
    """return a stripped sysfs or procfs value"""
    try:
        with open(path) as f:
            return f.read().strip("\0").strip()
    except OSError:
        return ""


def _verify_earlier_load(deadline_s=30, poll_s=0.5):
    """wait for an earlier start's policy load to finish"""
    deadline = time.time() + deadline_s
    while True:
        pid1 = _read_node(PID1_ATTR)
        enforce = _read_node(SELINUX_ENFORCE_NODE)
        missing = []
        if pid1 != "u:r:rhizo_host:s0":
            missing.append(f"pid 1 is {pid1!r}, not u:r:rhizo_host:s0")
        if enforce != "1":
            missing.append(f"enforce is {enforce!r}, not 1")
        if not missing or time.time() >= deadline:
            break
        time.sleep(poll_s)
    if missing:
        kmsg(f"--policy-only failed after {deadline_s}s ({'; '.join(missing)})")
        return 1
    sup = "alive" if recorded_g_alive() else "none"
    if os.path.exists(POLICY_LOADED_STATE):
        kmsg(f"--policy-only policy is already recorded in {POLICY_LOADED_STATE}, "
             f"pid1=u:r:rhizo_host:s0 enforce=1 supervisor={sup}")
        return 0
    if not _write_policy_loaded_state(None, None, loaded_by="first-androidd-start"):
        return 1
    kmsg(f"--policy-only wrote {POLICY_LOADED_STATE} for the first androidd start, "
         f"pid1=u:r:rhizo_host:s0 enforce=1 supervisor={sup}")
    return 0


def policy_only_must_park(load_ok, policy_loaded):
    """return whether load_ok or policy_loaded"""
    return load_ok or policy_loaded


def run_kernel_domain_supervisor(entry, build_sandbox=True, ready_fd=None, end_fd=-1):
    """run the supervisor and fork a joiner per handoff"""
    os.setsid()
    signal.signal(signal.SIGUSR1, lambda *_: None)
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1, signal.SIGTERM, signal.SIGCHLD})
    try:
        _dom0 = open("/proc/self/attr/current").read().strip("\0\n")
    except OSError:
        _dom0 = "unknown"
    recorded = may_record_supervisor(_dom0, recorded_pid(), recorded_g_alive(), os.getppid())
    if recorded:
        try:
            open(SUPERVISOR_STATE, "w").write("starting")
        except OSError as e:
            kmsg(f"failed to write the supervisor state file ({e})")
    route_supervisor_log(SUPERVISOR_LOG, kmsg)
    try:
        blk0 = [l.split()[1] for l in open("/proc/self/status") if l.startswith("SigBlk:")][0]
    except (OSError, IndexError):
        blk0 = "?"
    kmsg(f"supervisor {os.getpid()} masked signals, sigblk={blk0}")
    dom = _dom0
    if not recorded:
        kmsg(f"skipped the supervisor record, domain {dom} is not kernel" if host_selinux_mode()
             else f"skipped the supervisor record, supervisor {recorded_pid()} is alive")
    else:
        try:
            record_supervisor_pid()
            kmsg(f"recorded supervisor pid={os.getpid()} domain={dom}")
        except OSError as e:
            kmsg(f"failed to write the supervisor pid ({e})")

    def _state(v):
        """write v to the supervisor state file"""
        if not recorded:
            return
        try:
            open(SUPERVISOR_STATE, "w").write(v)
        except OSError as e:
            kmsg(f"failed to write supervisor state {v} ({e})")

    global _MY_SUPERVISOR_PID
    _MY_SUPERVISOR_PID = os.getpid()
    def slog(msg):
        """print a supervisor log line with os.getpid() and a timestamp"""
        print(f"[sup {os.getpid()} {time.time():.3f}] {msg}", flush=True)

    active = {}
    ran_once = False
    first_g = None
    in_host_cgroup = False
    while True:
        if not ran_once:
            if build_sandbox:
                try:
                    first_g = run_sandbox_or_refuse(entry)
                except SystemExit:
                    if not host_selinux_mode():
                        _state("refused")
                    raise
            else:
                ok, digest, byte_count = _policy_only_load(slog)
                detail = f"sha256={digest} bytes={byte_count}" if ok else "_policy_only_load failed"
                if ok:
                    ok, flip_detail = _wait_for_primer_flip(slog)
                    detail = f"{detail} {flip_detail}" if ok else flip_detail
                    if ok:
                        _write_policy_loaded_state(digest, byte_count)
                if ready_fd is not None:
                    try:
                        os.write(ready_fd, (("ok " if ok else "fail ") + detail).encode()[:4096])
                    except OSError:
                        pass
                    try:
                        os.close(ready_fd)
                    except OSError:
                        pass
                    ready_fd = None
                if not ok and policy_only_must_park(ok, policy_is_loaded()):
                    slog(f"--policy-only failed after the load ({detail})")
                elif not ok:
                    slog(f"--policy-only load failed ({detail})")
                    if recorded:
                        try:
                            os.unlink(G_PID_FILE)
                        except OSError:
                            pass
                    os._exit(1)
            ran_once = True
            if not recorded:
                slog(("sandbox ended" if build_sandbox else "policy load finished") +
                     ", supervisor is not the recorded one")
                os._exit(0)
            in_host_cgroup = park_supervisor_in_host_cgroup(slog)
        _state("parked" if not active else
               "active:" + ",".join(str(i) for i, *_ in active.values()))
        try:
            blk = [l.split()[1] for l in open("/proc/self/status") if l.startswith("SigBlk:")][0]
        except (OSError, IndexError):
            blk = "?"
        slog(f"parked sigblk={blk}")
        sig = signal.sigwait({signal.SIGUSR1, signal.SIGCHLD})
        _state("waking")
        slog(f"woke on signal {sig}")

        while True:
            try:
                reaped_pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if reaped_pid == 0:
                break
            reaped = active.pop(reaped_pid, None)
            if reaped is None:
                slog(f"reaped {reaped_pid} (status={status}), not a tracked joiner")
                if reaped_pid == first_g and end_fd >= 0:
                    report_sandbox_end(end_fd, status, slog)
                    end_fd = -1
                continue
            instance_id, gg_pid, gg_fd = reaped
            slog(f"joiner {reaped_pid} for instance {instance_id} exited (status={status})")
            if not host_selinux_mode() and not (os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0):
                record_refusal_unless_final(f"joiner-{wait_status_word(status)}",
                                            core.paths_for(instance_id).records_dir, keep=start_ended)
            release_namespace_holder(gg_fd, gg_pid, slog)

        if not in_host_cgroup:
            in_host_cgroup = park_supervisor_in_host_cgroup(slog)
        claimed = drain_handoffs(HANDOFF_DIR, {i for i, *_ in active.values()}, log=slog)
        for instance_id, pid1, hentry in claimed:
            slog(f"taking the handoff from {pid1} for instance {instance_id}")
            try:
                holder_fd = os.pidfd_open(pid1)
            except ProcessLookupError as e:
                slog(f"namespace holder {pid1} of instance {instance_id} is not running ({e})")
                continue
            except OSError as e:
                refuse_unwatchable_holder(instance_id, pid1, e, slog)
                continue
            joiner_pid = os.fork()
            if joiner_pid == 0:
                os.close(holder_fd)
                try:
                    code = _join_and_exec_init(pid1, hentry, instance_id)
                except BaseException as e:
                    kmsg(f"RHIZO_MARKER selinuxns=joiner-raised instance={instance_id} err={e!r}"[:900])
                    code = 1
                os._exit(code)
            active[joiner_pid] = (instance_id, pid1, holder_fd)
            slog(f"forked joiner {joiner_pid} for instance {instance_id}'s "
                 f"handoff from {pid1}")
        if not claimed:
            slog("0 handoff entries claimed")


def policy_only_verb():
    """load the policy, flip enforcement and park a supervisor"""
    if os.geteuid() != 0:
        sys.exit("root")
    if not host_selinux_mode():
        kmsg("RHIZO_MARKER selinuxns=policy-only-skipped")
        return 0
    kmsg(f"START entry=selinux_setup --policy-only pid={os.getpid()}")
    os.environ["RHIZO_POLICY_ONLY"] = "1"
    if not os.path.exists(SELINUX_ENFORCE_NODE):
        kmsg(f"SELinux is not the active LSM, no {SELINUX_ENFORCE_NODE}, "
             f"lsm={_read_node('/sys/kernel/security/lsm') or '?'}")
        return 0
    if RHIZO_PERMISSIVE:
        kmsg("--policy-only skipped the load with RHIZO_PERMISSIVE=1")
        return 0
    os.environ.setdefault("RHIZO_CALLER_UNIT", own_service_unit())
    _own_dom = own_domain()
    if _own_dom in ("u:r:kernel:s0", "u:r:rhizo_host:s0"):
        kmsg("--policy-only policy is already loaded ctx=%r" % _own_dom)
    elif _own_dom != "kernel":
        kmsg(f"context {_own_dom!r} is not kernel, u:r:kernel:s0 or u:r:rhizo_host:s0")
        return 1
    _host_lock_fd = acquire_host_global_phase()
    if _host_lock_fd is None:
        return _verify_earlier_load()
    arm_host_lock_releaser(_host_lock_fd)
    r, w = os.pipe()
    sup = os.fork()
    if sup == 0:
        os.close(r)
        run_kernel_domain_supervisor("selinux_setup", build_sandbox=False, ready_fd=w)
        os._exit(0)
    os.close(w)
    kmsg(f"--policy-only supervisor forked as {sup}")
    ready = b""
    try:
        rl, _, _ = select.select([r], [], [], 560)
        if rl:
            ready = os.read(r, 4096)
    finally:
        try:
            os.close(r)
        except OSError:
            pass
    if ready.startswith(b"ok "):
        kmsg(f"--policy-only {ready.decode(errors='replace').strip()}, supervisor {sup} parked")
        return 0
    detail = ready.decode(errors="replace").strip() or \
        "no result from the supervisor after 560s"
    kmsg(f"--policy-only failed ({detail})")
    return 1


def prepare_handoff_host_state(handoff_dir=HANDOFF_DIR, supervisor_cgroup=SUPERVISOR_CGROUP, boot_time=boot_started_at):
    """create the handoff dir and the supervisor cgroup"""
    try:
        os.makedirs(handoff_dir, mode=0o700, exist_ok=True)
    except OSError as e:
        kmsg(f"failed to create {handoff_dir} ({e})")
    else:
        try:
            btime = boot_time()
            with os.scandir(handoff_dir) as it:
                entries = list(it)
        except (OSError, ValueError) as e:
            kmsg(f"failed to list {handoff_dir} ({e})")
            entries = []
        for entry in entries:
            try:
                if not entry.is_file(follow_symlinks=False):
                    continue
                mtime = entry.stat(follow_symlinks=False).st_mtime
            except OSError as e:
                kmsg(f"failed to stat {entry.path} ({e})")
                continue
            if mtime >= btime:
                continue
            try:
                os.unlink(entry.path)
                kmsg(f"removed {entry.path} mtime={mtime:.0f} btime={btime}")
            except OSError as e:
                kmsg(f"failed to remove {entry.path} ({e})")
    try:
        os.makedirs(supervisor_cgroup, exist_ok=True)
    except OSError as e:
        kmsg(f"failed to create {supervisor_cgroup} ({e})")


def acquire_host_global_phase():
    """take the host lock and run the host bootstrap phase"""
    host_lock_fd = hostlock.acquire_host_lock()
    if not host_selinux_mode():
        kmsg("RHIZO_MARKER selinuxns=host-phase-skipped")
        prepare_handoff_host_state()
        return host_lock_fd
    if policy_is_loaded():
        if launcher_must_reexec(True, own_domain(), os.environ.get("RHIZO_REEXECED") == "1"):
            kmsg("policy is loaded and the launcher is in the kernel domain, execv into rhizo_host")
            os.close(host_lock_fd)
            os.environ["RHIZO_REEXECED"] = "1"
            os.execv(sys.executable, [sys.executable] + sys.argv)
        hostlock.release_host_lock(host_lock_fd)
        return None
    refusal = check_policy_load()
    if refusal:
        write_policy_refusal(refusal)
        hostlock.release_host_lock(host_lock_fd)
        kmsg(f"refused to load Android's policy ({refusal})")
        sys.exit(f"refused to load Android's policy ({refusal})")
    write_policy_refusal(None)
    try:
        import shutil as _sh_hoff
        _sh_hoff.rmtree(HANDOFF_DIR, ignore_errors=True)
        os.makedirs(HANDOFF_DIR, mode=0o700)
    except OSError as e:
        kmsg(f"failed to recreate {HANDOFF_DIR} ({e})")
    return host_lock_fd


START_LOCK_NAME = "start.lock"


def take_start_lock(records_dir=SELINUXNS_RECORDS_DIR):
    """return an fd with the instance start lock, or None when the lock is taken"""
    dir_fd = selinux_ns.open_records_dir(records_dir)
    try:
        fd = os.open(START_LOCK_NAME, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600, dir_fd=dir_fd)
    finally:
        os.close(dir_fd)
    try:
        fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        os.close(fd)
        if e.errno in (errno.EACCES, errno.EAGAIN):
            return None
        raise
    return fd


def hold_start_lock_or_refuse(records_dir=SELINUXNS_RECORDS_DIR):
    """take the instance start lock or refuse the start"""
    try:
        fd = take_start_lock(records_dir)
    except OSError as e:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=start-lock-failed errno={e.errno} path={records_dir}")
        sys.exit(1)
    if fd is None:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=instance-already-starting path={records_dir}")
        kmsg(f"{records_dir}/{START_LOCK_NAME} is locked, instance {SANDBOX_ID} is already starting")
        sys.exit(1)
    return fd


def reset_namespace_start_records(records_dir=SELINUXNS_RECORDS_DIR):
    """reset the start records in records_dir"""
    enforce_path = os.path.join(records_dir, os.path.basename(selinux_ns.ANDROID_ENFORCE_FILE))
    try:
        records_fd = selinux_ns.open_records_dir(records_dir)
    except OSError as e:
        kmsg(f"RHIZO_MARKER selinuxns=refused reason=records-dir-unopenable path={records_dir} err={e!r}")
        sys.exit(1)
    try:
        try:
            selinux_ns.write_android_enforce("0", selinux_ns.ANDROID_ENFORCE_FILE, dir_fd=records_fd)
            kmsg(f"wrote 0 to {enforce_path}")
        except OSError as e:
            kmsg(f"failed to write 0 to {enforce_path} ({e})")
        if not selinux_ns.record_verdict("pending", records_fd, keep=lambda current: False):
            kmsg(f"RHIZO_MARKER selinuxns=refused reason=records-reset-failed path={records_dir}")
            sys.exit(1)
        selinux_ns.record_start_id(os.environ.get("INVOCATION_ID", ""), records_fd)
        _START_RECORDS_OWNER.update(pid=os.getpid(), dir=records_dir)
        try:
            selinux_ns.clear_stop_request(records_fd)
        except OSError as e:
            kmsg(f"failed to clear the stop record in {records_dir} ({e})")
    finally:
        os.close(records_fd)


def arm_host_lock_releaser(host_lock_fd):
    """fork a host lock releaser"""
    _lock_releaser_mid = os.fork()
    if _lock_releaser_mid == 0:
        _lock_releaser = os.fork()
        if _lock_releaser == 0:
            os.setsid()
            if RHIZO_ENFORCING:
                hostlock.release_when_ready(host_lock_fd, recorded_g_alive, kmsg)
            else:
                release_host_lock_permissive(host_lock_fd)
            os._exit(0)
        os._exit(0)
    os.waitpid(_lock_releaser_mid, 0)
    os.close(host_lock_fd)


def main():
    """start a sandbox and wait as MainPID"""
    if os.geteuid()!=0: sys.exit("root")
    entry=sys.argv[1] if len(sys.argv)>1 else "second_stage"
    kmsg(f"START entry={entry} pid={os.getpid()}")
    if RHIZO_UNDER_UNIT:
        core.share_run_dir(WAYLAND_RUN_DIR)
    os.environ.setdefault("RHIZO_CALLER_UNIT", own_service_unit())
    phase("B", "launcher_start")
    core.set_write_primer_script(write_primer_script)
    mode = selinux_ns.selinux_mode()
    if mode.startswith("refuse:"):
        reason = mode[len("refuse:"):]
        kmsg(f"RHIZO_MARKER selinuxns=refused reason={reason}")
        kmsg(f"{selinux_ns.refusal_text(reason)}")
        try: os.unlink(selinux_ns.MODE_FILE)
        except FileNotFoundError: pass
        sys.exit(1)
    selinux_ns.write_mode_file(mode)
    if not host_selinux_mode():
        hold_start_lock_or_refuse()
        reset_namespace_start_records()
        arm_after_flip_jobs()
    _host_lock_fd = acquire_host_global_phase()
    if _host_lock_fd is not None:
        arm_host_lock_releaser(_host_lock_fd)
    clear_earlier_cgroup_record()
    if not host_selinux_mode():
        try:
            _recorded_boot, _boot = read_supervisor_record()[1], host_boot_id()
            if _recorded_boot != _boot:
                os.unlink(G_PID_FILE)
                kmsg(f"removed {G_PID_FILE}, boot id {_recorded_boot or '<none>'} is not {_boot}")
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as e:
            kmsg(f"failed to read {G_PID_FILE} ({e})")
    if RHIZO_RESIDENT_DISPATCH:
        rg = await_resident_g()
        if rg:
            kmsg(f"supervisor {rg} is parked")
        if not recorded_g_alive():
            try:
                os.unlink(G_PID_FILE)
                kmsg("removed the G_PID_FILE of a dead supervisor")
            except FileNotFoundError:
                pass
            except OSError as e:
                kmsg(f"failed to remove {G_PID_FILE} ({e})")
    if RHIZO_RESIDENT_G:
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1, signal.SIGTERM})
        if not recorded_g_alive():
            try:
                dom = open("/proc/self/attr/current").read().strip("\0\n")
            except OSError:
                dom = "unknown"
            if dom == "kernel" or dom.startswith("u:r:kernel:"):
                try:
                    record_supervisor_pid()
                    kmsg(f"recorded supervisor pid={os.getpid()} domain={dom}")
                except OSError as e:
                    kmsg(f"failed to write the supervisor pid ({e})")
            else:
                kmsg(f"skipped the supervisor record, domain {dom} is not kernel")

    if not RHIZO_RESIDENT_G:
        run_sandbox_or_refuse(entry)
        return

    end_r, end_w = os.pipe2(os.O_CLOEXEC) if not host_selinux_mode() else (-1, -1)
    sup = os.fork()
    if sup == 0:
        if end_r >= 0:
            os.close(end_r)
        try:
            run_kernel_domain_supervisor(entry, end_fd=end_w)
        except SystemExit as e:
            if isinstance(e.code, str):
                print(e.code, file=sys.stderr, flush=True)
            os._exit(e.code if isinstance(e.code, int) else 1)
        os._exit(0)

    if end_w >= 0:
        os.close(end_w)
    kmsg(f"supervisor forked as {sup}")
    _stopping = {"ran": False}

    def _on_term(_sig, _frm):
        """run the stop sequence on SIGTERM"""
        if _stopping["ran"]:
            return
        _stopping["ran"] = True
        kmsg("MainPID caught SIGTERM, run androidd_stop")
        try:
            androidd_stop()
        except Exception as e:
            kmsg(f"androidd_stop raised {e}")
        os._exit(0)

    signal.signal(signal.SIGTERM, _on_term)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
    try:
        pfd = os.pidfd_open(sup)
    except OSError as e:
        kmsg(f"pidfd_open({sup}) failed ({e}), poll every 5s")
        pfd = -1
    if pfd >= 0:
        ready, _, _ = select.select([pfd] + ([end_r] if end_r >= 0 else []), [], [])
        if pfd not in ready:
            if sandbox_end_fails_unit(read_sandbox_end(end_r)):
                sys.exit(1)
            return
        status = _supervisor_exit_status(sup)
        kmsg(f"supervisor {sup} exited{_supervisor_exit_note(status)}")
        if supervisor_end_fails_unit(status):
            sys.exit(1)
        return
    while True:
        if end_r >= 0 and select.select([end_r], [], [], 0)[0] and pid_is_live(sup, kmsg):
            if sandbox_end_fails_unit(read_sandbox_end(end_r)):
                sys.exit(1)
            return
        if not pid_is_live(sup, kmsg):
            status = _supervisor_exit_status(sup)
            kmsg(f"supervisor {sup} exited{_supervisor_exit_note(status)}")
            if supervisor_end_fails_unit(status):
                sys.exit(1)
            return
        time.sleep(5)


def run_sandbox(entry):
    """build the sandbox and wait for the sandbox init to exit"""
    gpu_mode_or_exit(host_selinux_mode() and policy_is_loaded())
    privileged_setup()
    net_r, net_w = os.pipe()
    veth_r, veth_w = os.pipe()
    _input_registry = None
    _input_labels = None
    if capabilities.policy_or_deny(log=kmsg).allows("devices.uinput"):
        start_input_units(SANDBOX_ID)
        _input_registry = open_fence_registry(SANDBOX_ID)
        if not host_selinux_mode():
            _input_labels = open_label_service(SANDBOX_ID)
        core.set_uinput_filtered(True)
        _input_supervisor = connect_input_supervisor(SANDBOX_ID)
        core.set_input_supervisor(_input_supervisor)
        if not install_device_cgroup_filter(_CGROUP_ROOT, capabilities.policy_or_deny(log=kmsg, instance_id=SANDBOX_ID),
                                            log=kmsg, devmap=core.device_filter_map(),
                                            uhid_wait_s=UHID_ALLOW_WAIT_S if _input_supervisor is not None else 0):
            kmsg(f"failed to install the device cgroup filter with /dev/uhid on {_CGROUP_ROOT}")
            os._exit(1)
    _first_r, _first_w = (os.pipe2(os.O_CLOEXEC) if not host_selinux_mode() and RHIZO_RESIDENT_DISPATCH
                          and i_am_recorded_supervisor() else (-1, -1))
    _verdict_dir = open_records_or_refuse(SELINUXNS_RECORDS_DIR) if not host_selinux_mode() else -1
    if _verdict_dir >= 0:
        selinux_ns.record_verdict("pending", _verdict_dir)
    g=os.fork()
    if g==0:
        if _first_r >= 0: os.close(_first_r)
        os.close(net_r); os.close(veth_w)
        if RHIZO_RESIDENT_G:
            signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGUSR1, signal.SIGTERM})
        if RHIZO_RESIDENT_G and not recorded_g_alive():
            try:
                dom = open("/proc/self/attr/current").read().strip("\0\n")
            except OSError:
                dom = "unknown"
            if dom == "kernel" or dom.startswith("u:r:kernel:"):
                try:
                    record_supervisor_pid()
                    kmsg(f"recorded supervisor pid={os.getpid()} domain={dom}")
                except OSError as e:
                    kmsg(f"failed to write the supervisor pid ({e})")
            else:
                kmsg(f"skipped the supervisor record, domain {dom} is not kernel")
        if RHIZO_UNDER_UNIT:
            connect_notify_socket()
        # opened in the host's mount and network namespaces
        try:
            _battery = battery.arm(core.staged_battery_source(), host_mode=host_selinux_mode(), domain=own_domain())
        except Exception as _be:
            _battery = None
            kmsg(f"RHIZO_MARKER battery_relay=failed reason=arm:{_be.__class__.__name__}")
        _shutdown = battery.ShutdownReason(f"{RUN_ROOT}/metadata")
        if not _CGROUP_ROOT:
            kmsg("_CGROUP_ROOT is unset")
            exit_g_refused("cgroup-root-unset", _verdict_dir)
        # cgroup-clear-exempt: prepare_host_and_data() cleared this root
        if not join_cgroup(_CGROUP_ROOT, os.getpid(), kmsg):
            kmsg(f"failed to move g into {_CGROUP_ROOT}")
            exit_g_refused("cgroup-root-join-failed", _verdict_dir)
        try:
            _g_cg = open("/proc/self/cgroup").read().strip()
        except OSError as _e:
            _g_cg = f"unreadable ({_e})"
        kmsg(f"g cgroup={_g_cg} root={_CGROUP_ROOT} subtree_control="
             f"{open(f'{_CGROUP_ROOT}/cgroup.subtree_control').read().strip()!r}")
        # kernel patch 0031 creates /sys/kernel/security/rhizo/bpf_load_seal
        _bpf_seal_fd = -1
        if os.environ.get("RHIZO_BPFLOAD_SEAL", "on") != "off":
            try:
                _bpf_seal_fd = os.open("/sys/kernel/security/rhizo/bpf_load_seal",
                                       os.O_WRONLY | os.O_CLOEXEC)
            except OSError as _e:
                kmsg("RHIZO_MARKER bpf_seal=unavailable err=%r" % (_e,))
        unshare(CLONE_NEWNS|CLONE_NEWPID|CLONE_NEWCGROUP|CLONE_NEWIPC|CLONE_NEWUTS|CLONE_NEWNET)
        os.makedirs(f"{_CGROUP_ROOT}/{CGROUP_INIT_LEAF}", exist_ok=True)
        try:
            cgroup_write(f"{_CGROUP_ROOT}/{CGROUP_INIT_LEAF}/cgroup.procs", str(os.getpid()))
        except OSError as e:
            kmsg(f"failed to move g into {_CGROUP_ROOT}/{CGROUP_INIT_LEAF} ({e})")
        libc.sethostname(b"localhost", 9)
        os.write(net_w, b"1"); os.close(net_w)
        os.read(veth_r, 1); os.close(veth_r)
        piv_r, piv_w = os.pipe()
        try:
            if libc.prctl(PR_SET_MEMORY_MERGE, 1, 0, 0, 0) != 0:
                kmsg(f"prctl PR_SET_MEMORY_MERGE failed errno={ctypes.get_errno()}")
            else:
                kmsg("set PR_SET_MEMORY_MERGE")
        except Exception as e:
            kmsg(f"prctl PR_SET_MEMORY_MERGE raised {e}")
        _handoff_to = await_resident_g(240) if RHIZO_RESIDENT_DISPATCH else None
        if _handoff_to and _handoff_to == _MY_SUPERVISOR_PID:
            kmsg(f"skipped the handoff, {_handoff_to} is _MY_SUPERVISOR_PID")
            _handoff_to = None
        if RHIZO_RESIDENT_DISPATCH and not _handoff_to and host_selinux_mode() and policy_is_loaded():
            kmsg("no resident supervisor and a policy is already loaded")
            os._exit(1)
        _ns_handoff = bool(_handoff_to) and not host_selinux_mode()
        _why, _fail_reasons = "", []
        if _ns_handoff:
            selinux_ns.record_verdict("handed-off", _verdict_dir)
        _hoff_fd, _hoff_dfd, _hoff_tmp = open_handoff_entry(SANDBOX_ID) if _handoff_to else (-1, -1, None)
        if _handoff_to:
            ensure_init_pid_file()

        _done_r, _done_w = os.pipe2(os.O_CLOEXEC) if not host_selinux_mode() and not _handoff_to else (-1, -1)
        core.set_relabeller_done_fd(_done_w)
        gg=os.fork()
        if gg==0:
            if _battery is not None:
                _battery.close()
            _shutdown.close()
            if _first_w >= 0: os.close(_first_w)
            if _verdict_dir >= 0: os.close(_verdict_dir)
            os.close(piv_r)
            if _done_r >= 0:
                os.close(_done_r)
            drop_device_filter_map()
            core.drop_device_filter_link()
            if not host_selinux_mode():
                if _input_registry is not None:
                    _input_registry.close()
                if _input_labels is not None:
                    _input_labels.close()
            build_root_and_pivot(mount_proc=not _handoff_to, handoff=bool(_handoff_to))
            try: os.write(piv_w, b"1")
            except OSError: pass
            os.close(piv_w)
            describe_sandbox_cgroups()
            if _handoff_to:
                _ncm = os.fork()
                if _ncm == 0:
                    _deadline = time.time() + 60
                    while not os.path.isdir("/proc/sys") and time.time() < _deadline:
                        time.sleep(0.005)
                    ro_ok = harden_proc_sys()
                    if not ro_ok:
                        kmsg("harden_proc_sys() failed, SIGKILL -1")
                        try:
                            os.kill(-1, signal.SIGKILL)
                        except OSError as _ke:
                            kmsg(f"failed to SIGKILL the sandbox ({_ke})")
                        os._exit(1)
                    setup_net_core_sysctls()
                    try:
                        _bje = open("/proc/sys/net/core/bpf_jit_enable").read().strip()
                    except OSError as _e:
                        _bje = None
                        kmsg(f"failed to read bpf_jit_enable after harden_proc_sys() ({_e})")
                    if not _bje:
                        kmsg("bpf_jit_enable is empty after harden_proc_sys()")
                    else:
                        kmsg(f"post-harden bpf_jit_enable={_bje!r} ro={ro_ok}")
                    os._exit(0)
                hold_pid_namespace_open(fatal_child=_ncm)
            enter_sandbox_init(entry)
        if not _handoff_to:
            try: open(INIT_PID_FILE,"w").write(str(gg))
            except OSError as e: kmsg(f"failed to write the init pid file ({e})")
        os.close(piv_w)
        if _done_w >= 0:
            os.close(_done_w)
        _gg_exited = False
        _sandbox_kills = []
        _relabel = "pending" if _done_r >= 0 else "none"
        try:
            _piv_ready, _, _ = select.select([piv_r], [], [], 30)
            _piv_signal = os.read(piv_r, 1) if _piv_ready else b""
            _done_deadline = time.time() + selinux_ns.RELABELLER_DEADLINE_S
            if _piv_ready and not _piv_signal:
                _relabel = "none"
            if _piv_signal:
                _new_fd = -1
                for _attempt in range(5):
                    try:
                        _new_fd = os.open("/dev/kmsg", os.O_WRONLY | os.O_CLOEXEC)
                        break
                    except OSError as e:
                        kmsg(f"failed to reopen /dev/kmsg after the pivot, attempt {_attempt} ({e})")
                        time.sleep(0.2)
                if _new_fd >= 0:
                    _old_fd = core.swap_kmsg_fd(_new_fd)
                    kmsg(f"post-pivot kmsg fd swapped ({_old_fd} -> {_new_fd})")
                    try:
                        _lbl = os.getxattr("/dev/kmsg", "security.selinux").decode()
                        kmsg(f"post-pivot /dev/kmsg label={_lbl}")
                    except OSError as e:
                        kmsg(f"post-pivot /dev/kmsg getxattr failed ({e})")
                    if _old_fd is not None:
                        try: os.close(_old_fd)
                        except OSError: pass
                else:
                    kmsg("failed to reopen /dev/kmsg after 5 attempts")
                if _handoff_to:
                    _hoff_why = []
                    if not hand_off_to_supervisor(_handoff_to, _hoff_fd, _hoff_dfd, _hoff_tmp, gg,
                                                  entry if not host_selinux_mode() else "second_stage", SANDBOX_ID,
                                                  why=_hoff_why) and _ns_handoff:
                        refuse_handoff(gg, f"handoff-{_hoff_why[0] if _hoff_why else 'failed'}", _verdict_dir)
            elif _piv_ready:
                kmsg("gg exited before the pivot")
                if _handoff_to:
                    kmsg(f"skipped the handoff to {_handoff_to}, gg exited before the pivot")
                    if _ns_handoff:
                        selinux_ns.record_verdict("refused:holder-exited-before-handoff", _verdict_dir)
                    if _hoff_fd >= 0:
                        try: os.close(_hoff_fd)
                        except OSError: pass
                    if _hoff_dfd >= 0:
                        if _hoff_tmp:
                            try: os.unlink(_hoff_tmp, dir_fd=_hoff_dfd)
                            except OSError: pass
                        try: os.close(_hoff_dfd)
                        except OSError: pass
            else:
                kmsg("no pivot signal after 30s")
                if _handoff_to:
                    kmsg(f"skipped the handoff to {_handoff_to}, no pivot signal from gg")
                    if _ns_handoff:
                        refuse_handoff(gg, "holder-never-pivoted", _verdict_dir)
                    if _hoff_fd >= 0:
                        try: os.close(_hoff_fd)
                        except OSError: pass
                    if _hoff_dfd >= 0:
                        if _hoff_tmp:
                            try: os.unlink(_hoff_tmp, dir_fd=_hoff_dfd)
                            except OSError: pass
                        try: os.close(_hoff_dfd)
                        except OSError: pass
            os.close(piv_r)
            import signal as _signal
            _gg_fd = os.pidfd_open(gg)

            def _kill_for_fence():
                """record the fence refusal and kill gg"""
                _sandbox_kills.append("input-fence")
                if _verdict_dir >= 0:
                    selinux_ns.record_start_end("refused:input-fence", _verdict_dir)
                _signal.pidfd_send_signal(_gg_fd, _signal.SIGKILL)

            _fence = (start_fence_or_kill(_input_registry, _kill_for_fence, labels=_input_labels,
                                          devmap=core.device_filter_map())
                      if _piv_signal else None)
            kmsg("RHIZO_POSTFLIP_KMSG_SELFTEST")
            notified = not RHIZO_UNDER_UNIT
            watched = "the namespace holder" if _handoff_to else "init(pid1)"
            _boot_watch = BootMarkerWatch()
            _booted = False
            _last_alive_log = 0.0
            _relay = _battery if _piv_signal and relay_step(_battery, "begin", default=False) else None
            while True:
                if fence_wait_step(_gg_fd, _fence, None if _booted and _relabel != "pending" else 0.5,
                                   _kill_for_fence, relay=_relay):
                    d=os.waitpid(gg,0)
                    _gg_exited = True
                    kmsg(f"{watched} exited status={d[1]}"); break
                if _relabel == "pending":
                    _relabel = selinux_ns.check_relabeller_done(
                        _done_r, _done_deadline, lambda: _signal.pidfd_send_signal(_gg_fd, _signal.SIGKILL),
                        init_exiting=lambda: selinux_ns.wait_pidfd_exit(_gg_fd), reasons=_fail_reasons)
                    if _relabel in ("enforced", "permissive"):
                        selinux_ns.record_verdict(_relabel, _verdict_dir)
                        if _relabel == "enforced":
                            selinux_ns.record_android_enforce("1", _verdict_dir)
                        if _first_w >= 0:
                            try:
                                os.write(_first_w, b"1")
                            except OSError as e:
                                kmsg(f"failed to write the first-flip byte ({e!r})")
                            os.close(_first_w)
                            _first_w = -1
                if not _booted and _boot_watch.seen():
                    _booted = True
                    # BPF_PROG_LOAD returns EPERM in the pid namespace of a pid written to bpf_load_seal
                    if _bpf_seal_fd >= 0:
                        try:
                            os.write(_bpf_seal_fd, str(gg).encode())
                            kmsg("RHIZO_MARKER bpf_seal=sealed holder_pid=%d" % gg)
                        except OSError as _e:
                            if _e.errno in (errno.EACCES, errno.EPERM):
                                kmsg("RHIZO_MARKER bpf_seal=deferred reason=host-selinux-enforcing-governs-bpf "
                                     "holder_pid=%d" % gg)
                            else:
                                kmsg("RHIZO_MARKER bpf_seal=failed holder_pid=%d err=%r" % (gg, _e))
                        finally:
                            try:
                                os.close(_bpf_seal_fd)
                            except OSError:
                                pass
                            _bpf_seal_fd = -1
                    if not notified:
                        notified = True
                        if sd_notify("READY=1\n"):
                            kmsg("sd_notify READY=1 returned True")
                        else:
                            kmsg("sd_notify READY=1 returned False")
                    kmsg(f"{watched} alive, boot completed")
                    continue
                if not _booted and time.time() - _last_alive_log >= 5:
                    kmsg(f"{watched} alive"); _last_alive_log = time.time()
            if _battery is not None:
                _battery.close()
            try:
                _shutdown.report()
            except OSError as _se:
                kmsg(f"failed to read the shutdown reason ({_se!r})")
            _shutdown.close()
            if _relabel == "pending":
                _relabel = selinux_ns.read_done_now(_done_r, _fail_reasons)
            if _relabel == "failed" and _fail_reasons:
                _why = selinux_ns.relabeller_refusal(_fail_reasons[0])
            if _done_r >= 0 and _relabel in ("none", "pending"):
                _exit_why = selinux_ns.init_exit_refusal(d[1], selinux_ns.stop_requested(_verdict_dir))
                if _exit_why:
                    _relabel, _why = "failed", _exit_why
            if _sandbox_kills and _verdict_dir >= 0:
                _relabel, _why = "failed", _sandbox_kills[0]
            if _ns_handoff:
                _joiner_verdict = selinux_ns.read_verdict(_verdict_dir)
                _holder_why = selinux_ns.handoff_refusal(_joiner_verdict)
                if _holder_why and selinux_ns.stop_requested(_verdict_dir):
                    _joiner_verdict = selinux_ns.await_joiner_end(_verdict_dir)
                    _holder_why = None
                    if selinux_ns.handoff_refusal(_joiner_verdict):
                        selinux_ns.record_start_end("stopped", _verdict_dir)
                if _holder_why:
                    selinux_ns.record_start_end(f"refused:{_holder_why}", _verdict_dir)
                _joiner_verdict = selinux_ns.read_verdict(_verdict_dir)
                _relabel = selinux_ns.handoff_outcome(_joiner_verdict)
        except BaseException as _e:
            kmsg(f"g died post-pivot {_e.__class__.__name__} ({_e})")
            if _relabel == "pending" or (_relabel == "none" and _done_r >= 0 and not _ns_handoff):
                _why = "relabeller-watcher-raised" if _relabel == "pending" else f"g-raised-{_e.__class__.__name__}"
                _relabel = "failed"
                try:
                    if "_gg_fd" in locals():
                        signal.pidfd_send_signal(_gg_fd, signal.SIGKILL)
                    else:
                        os.kill(gg, signal.SIGKILL)
                except OSError as _ke:
                    kmsg(f"failed to kill the sandbox after g raised ({_ke!r})")
                kmsg(f"RHIZO_MARKER selinuxns=refused reason={_why}")
            elif _relabel in ("enforced", "permissive") and not _gg_exited:
                try:
                    signal.pidfd_send_signal(_gg_fd, signal.SIGKILL)
                except OSError as _ke:
                    kmsg(f"failed to kill the flipped sandbox after g raised ({_ke!r})")
                try:
                    os.waitpid(gg, 0)
                except ChildProcessError as _we:
                    kmsg(f"flipped sandbox {gg} is already reaped ({_we!r})")
                _gg_exited = True
        if _verdict_dir >= 0 and not _ns_handoff and (_gg_exited or _relabel not in ("enforced", "permissive")):
            selinux_ns.record_start_end(selinux_ns.verdict_for(_relabel, _why), _verdict_dir)
        os._exit(selinux_ns.RELABELLER_REFUSED_EXIT if _relabel in ("eof", "timeout", "failed") else 0)
    if _first_w >= 0: os.close(_first_w)
    if _verdict_dir >= 0: os.close(_verdict_dir)
    drop_device_filter_map()
    os.close(net_w); os.close(veth_r)
    _g_signaled = bool(os.read(net_r, 1))
    os.close(net_r)
    if not _g_signaled:
        kmsg("g exited before the netns signal")
        os.close(veth_w)
    else:
        if not host_selinux_mode() and not add_android_dummy0(g):
            refuse_start_before_init(g, "dummy0-failed")
        net_ok = setup_veth_and_nat(g)
        try:
            os.write(veth_w, b"1")
        except BrokenPipeError:
            kmsg("g exited during the veth setup")
            net_ok = False
        os.close(veth_w)
        if net_ok:
            report_netbridged_liveness()
    if RHIZO_RESIDENT_DISPATCH and i_am_recorded_supervisor():
        _g_why = []
        if _first_r >= 0 and selinux_ns.wait_first_flip(_first_r, g, reasons=_g_why) == "refused":
            record_refusal_unless_final(_g_why[0])
            refuse_start()
        kmsg(f"sandbox up, holder {g}")
        return g
    _, _g_status = os.waitpid(g,0)
    if ((os.WIFEXITED(_g_status) and os.WEXITSTATUS(_g_status) == selinux_ns.RELABELLER_REFUSED_EXIT)
            or (not host_selinux_mode() and not (os.WIFEXITED(_g_status) and os.WEXITSTATUS(_g_status) == 0))):
        if not host_selinux_mode():
            record_refusal_unless_final(f"g-{wait_status_word(_g_status)}")
        refuse_start()

if __name__=="__main__":
    route_stdio_through_pipe()
    if len(sys.argv) > 1 and sys.argv[1] == "androidd-stop":
        sys.exit(androidd_stop())
    if len(sys.argv) > 1 and sys.argv[1] == "release-staging":
        sys.exit(release_staging_verb())
    if len(sys.argv) > 3 and sys.argv[1] == "selinuxns-relabeller":
        os._exit(selinux_ns.run_handoff_relabeller(NEWROOT, coldboot_primer_spec(), int(sys.argv[2]),
                                                        int(sys.argv[3]),
                                                        int(sys.argv[4]) if len(sys.argv) > 4 else -1))
    if len(sys.argv) > 2 and sys.argv[1] == "prepare-tree":
        gpu_driver_arg = None
        if "--gpu-driver" in sys.argv[3:]:
            gpu_driver_arg = sys.argv[sys.argv.index("--gpu-driver") + 1]
        missing = core.gsi_derived_missing()
        if missing:
            print(f"PREPARE_TREE_FAILED reason=gsi-derived-missing missing={','.join(missing)}")
            sys.exit(1)
        mismatch = core.gsi_derived_mismatch()
        if mismatch:
            print(f"PREPARE_TREE_FAILED reason=gsi-derived-mismatch why={mismatch}")
            sys.exit(1)
        sys.exit(prepare_tree_verb(sys.argv[2], gpu_driver_arg))
    if len(sys.argv) > 1 and sys.argv[1] == "prepare-sepolicy":
        sys.exit(prepare_sepolicy_verb("--check" in sys.argv[2:]))
    if len(sys.argv) > 2 and sys.argv[1] == "in-android-policy":
        sys.exit(in_android_policy_verb(sys.argv[2:]))
    if len(sys.argv) > 4 and sys.argv[1] == "stage-gsi-labeled":
        _sgl_why = selinux_ns.stage_gsi_labeled(sys.argv[2], sys.argv[3], sys.argv[4], os.path.abspath(__file__))
        print("STAGE_GSI_LABELED_OK" if _sgl_why is None else f"STAGE_GSI_LABELED_FAILED reason={_sgl_why}")
        sys.exit(0 if _sgl_why is None else 1)
    if len(sys.argv) > 1 and sys.argv[1] == "data-tier":
        sys.exit(data_tier_verb())
    if len(sys.argv) > 1 and sys.argv[1] == "needed-modules":
        print("\n".join(core.ANDROID_NEEDED_MODULES))
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "gsi-derived-check":
        sys.exit(gsi_derived_check_verb())
    if len(sys.argv) > 1 and sys.argv[1] == "prepared-rekey-kernel":
        _rk_key, _rk_result = core.rekey_prepared_kernel()
        if _rk_key:
            print(f"PREPARED_REKEY result={_rk_result} key={_rk_key} kernel={os.uname().release}")
            sys.exit(0)
        print(f"PREPARED_REKEY_REFUSED reason={_rk_result}")
        sys.exit(1)
    if len(sys.argv) > 1 and sys.argv[1] == "selinux_setup" and "--policy-only" in sys.argv[2:]:
        sys.exit(policy_only_verb())
    if len(sys.argv) > 1 and sys.argv[1] == "policy-stop":
        sys.exit(policy_stop_verb())
    try:
        main()
    except BaseException as _main_end:
        close_out_owned_start(_main_end)
        raise
