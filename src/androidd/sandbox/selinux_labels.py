import glob
import os
import re
import subprocess
import sys

from sandbox.core import (DEVICE_STATE_LABEL, DEVICE_STATE_MOUNT, HOST_PRIMER_PATH, INIT_PID_FILE,
    RHIZO_ENFORCING, RUN_ROOT, SANDBOX_ID, host_selinux_mode, kmsg)


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


HOST_EXEC_CONTEXT = "u:object_r:rhizo_host_exec:s0"
HOST_EXEC_PATHS = ("/usr/lib/systemd/systemd", "/usr/sbin/sshd", "/usr/bin/bash",
                   "/usr/bin/dash", "/usr/bin/systemctl", "/usr/bin/python3",
                   "/usr/sbin/modprobe")

HOST_EXEC_PACKAGED = ("/usr/lib/rhizo/rhizo-inputd",
                      "/usr/lib/rhizo/rhizo-delayd",
                      "/usr/lib/rhizo/rhizo-headroomd")

HOST_MODULE_ROOT = "/lib/modules"
HOST_MODULE_CONTEXT = "u:object_r:rhizo_host_module_file:s0"


def host_ld_so(maps_path="/proc/self/maps"):
    """return the ELF interpreter path of this process"""
    try:
        with open(maps_path) as fh:
            for line in fh:
                head, sep, path = line.rstrip("\n").partition(" /")
                if not sep:
                    continue
                path = "/" + path.strip()
                base = os.path.basename(path)
                if base.startswith("ld-") and ".so" in base:
                    return path
    except OSError:
        pass
    return None
def core_pattern_helper(path="/proc/sys/kernel/core_pattern"):
    """return the program path from core_pattern"""
    try:
        with open(path) as fh:
            words = fh.read().strip().split()
    except OSError:
        return None
    if not words or not words[0].startswith("|/"):
        return None
    return words[0][1:]


POLICY_REFUSED_STATE = "/run/rhizo-policy-refused"
RIG_LOAD_UNDER_LOGIN = "RHIZO_RIG_LOAD_UNDER_LOGIN"
EXEMPT_CLASSES = ("background", "background-light", "manager", "manager-early", "none")
SESSION_PROPERTIES = ("Id", "Name", "Remote", "Type", "Class", "Seat", "TTY", "State")
REEXEC_SYSTEMD = 250


def parse_sessions(text):
    """return the session records in `loginctl show-session` output"""
    sessions, cur = [], None
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if not sep:
            cur = None
            continue
        if cur is None or (key == "Id" and "Id" in cur):
            cur = {}
            sessions.append(cur)
        cur[key] = value
    return sessions


def login_sessions(sessions):
    """return the sessions a policy load would strand"""
    return [s for s in sessions if s.get("Class") not in EXEMPT_CLASSES]


def systemd_version(text):
    """return the version from `systemctl --version`"""
    m = re.match(r"systemd (\d+)", text)
    return int(m.group(1)) if m else 0


def session_scopes(cg_root="/sys/fs/cgroup/user.slice"):
    """return the session-*.scope cgroups that hold a process"""
    scopes = []
    for scope in sorted(glob.glob(os.path.join(cg_root, "user-*.slice", "session-*.scope"))):
        try:
            with open(os.path.join(scope, "cgroup.procs")) as f:
                if f.read().split():
                    scopes.append(scope)
        except OSError:
            pass
    return scopes


def read_sessions(run=subprocess.run, cg_root="/sys/fs/cgroup/user.slice"):
    """return every logind session's record"""
    try:
        state = run(["systemctl", "is-active", "systemd-logind.service"], capture_output=True,
                    text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        state = ""
    if state != "active":
        return None if session_scopes(cg_root) else []
    try:
        listed = run(["loginctl", "list-sessions", "--no-legend", "--no-pager"], capture_output=True,
                     text=True, timeout=10)
        if listed.returncode != 0:
            return None
        ids = [line.split()[0] for line in listed.stdout.splitlines() if line.split()]
        if not ids:
            return []
        argv = ["loginctl", "show-session", "--no-pager"] + ids
        for prop in SESSION_PROPERTIES:
            argv += ["-p", prop]
        shown = run(argv, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return parse_sessions(shown.stdout) if shown.returncode == 0 else None


def user_manager_units(cg_root="/sys/fs/cgroup/user.slice"):
    """return the user@<uid>.service units that hold a process"""
    units = []
    for unit_dir in sorted(glob.glob(os.path.join(cg_root, "user-*.slice", "user@*.service"))):
        for sub in ("init.scope", ""):
            try:
                with open(os.path.join(unit_dir, sub, "cgroup.procs")) as f:
                    if f.read().split():
                        units.append(os.path.basename(unit_dir))
                        break
            except OSError:
                pass
    return units


def policy_load_refusal(sessions, version, managers, rig):
    """return why loading Android's policy now must not go ahead"""
    if not rig:
        if sessions is None:
            return ("the login sessions could not be read from systemd-logind -- reboot, and Android's policy loads at boot before any login")
        logins = login_sessions(sessions)
        if logins:
            named = ", ".join("session %s of %s%s%s" % (
                s.get("Id"), s.get("Name"),
                (" on " + "/".join(x for x in (s.get("Seat"), s.get("TTY")) if x)) if (s.get("Seat") or s.get("TTY")) else "",
                " over ssh" if s.get("Remote") == "yes" else "")
                for s in logins)
            return ("%s started before Android's policy was loaded and would stay outside it, "
                    "unable to start programs -- reboot, and the policy loads at "
                    "boot before any login" % named)
    if managers and version < REEXEC_SYSTEMD:
        return ("%s run on systemd %d, which cannot re-execute a user manager into the host's domain "
                "(SIGRTMIN+25 needs systemd %d) -- reboot, and Android's policy loads at boot before any of them starts"
                % (", ".join(managers), version, REEXEC_SYSTEMD))
    return None


def check_policy_load():
    """return why this launch must not load Android's policy"""
    if not host_selinux_mode() or not RHIZO_ENFORCING or not os.path.exists("/sys/fs/selinux/enforce"):
        return None
    try:
        version = systemd_version(subprocess.run(["systemctl", "--version"], capture_output=True,
                                                 text=True, timeout=10).stdout)
    except (OSError, subprocess.TimeoutExpired):
        version = 0
    return policy_load_refusal(read_sessions(), version, user_manager_units(),
                               os.environ.get(RIG_LOAD_UNDER_LOGIN) == "1")


def write_policy_refusal(reason, path=POLICY_REFUSED_STATE):
    """write or remove the refusal record"""
    try:
        if reason is None:
            if os.path.exists(path):
                os.unlink(path)
            return
        tmp = os.path.join(os.path.dirname(path), ".%s.tmp" % os.path.basename(path))
        with open(tmp, "w") as f:
            f.write("refused_by=launcher\nreason=%s\n" % reason)
        os.replace(tmp, path)
    except OSError as e:
        kmsg(f"policy refusal record {path}: {e}")


def label_host_binaries():
    """label the host entrypoint binaries rhizo_host_exec"""
    if not host_selinux_mode() or not RHIZO_ENFORCING: return
    _ldso = host_ld_so()
    _core = core_pattern_helper()
    _packaged = tuple(p for p in HOST_EXEC_PACKAGED if os.path.exists(p))
    for p in HOST_EXEC_PATHS + _packaged + ((_ldso,) if _ldso else ()) + ((_core,) if _core else ()):
        real = os.path.realpath(p)
        try:
            current = os.getxattr(real, "security.selinux").decode().rstrip("\0")
        except OSError:
            current = None
        if current == HOST_EXEC_CONTEXT:
            continue
        try: os.setxattr(real, "security.selinux",
                         (HOST_EXEC_CONTEXT + "\0").encode())
        except OSError as e: kmsg(f"host label {p}: {e}")
    labeled, already, failed = label_host_modules()
    kmsg(f"host module labels: {labeled} set, {already} already {HOST_MODULE_CONTEXT}"
         + (f", {len(failed)} FAILED: {failed[:4]}" if failed else ""))
    try: open("/proc/sys/kernel/printk_ratelimit","w").write("0\n")
    except OSError: pass


def label_host_modules(root=HOST_MODULE_ROOT, ctx=HOST_MODULE_CONTEXT):
    """label the module tree directories and files"""
    want = ctx.encode() + b"\0"
    labeled, already, failed = 0, 0, []
    targets = []
    for dirpath, _dirs, files in os.walk(os.path.realpath(root),
                                         onerror=lambda e: failed.append((e.filename, str(e)))):
        targets.append(dirpath)
        targets.extend(os.path.join(dirpath, f) for f in files)
    for p in targets:
        if os.path.islink(p):
            continue
        try:
            current = os.getxattr(p, "security.selinux", follow_symlinks=False)
        except OSError:
            current = None
        if current is not None and current.rstrip(b"\0") == want.rstrip(b"\0"):
            already += 1
            continue
        try:
            os.setxattr(p, "security.selinux", want, follow_symlinks=False)
            labeled += 1
        except OSError as e:
            failed.append((p, str(e)))
    return labeled, already, failed
PRE_INIT_RELABEL = [
    ("/",         "u:object_r:rootfs:s0"),
    ("/etc",      "u:object_r:rootfs:s0"),
    ("/sdcard",   "u:object_r:rootfs:s0"),
    ("/bin",      "u:object_r:rootfs:s0"),
    ("/proc",     "u:object_r:rootfs:s0"),
    ("/dev/ptmx", "u:object_r:ptmx_device:s0"),
    ("/sys/fs/selinux/enforce", "u:object_r:rhizo_enforce_shadow:s0"),
    ("/sys/power/state",        "u:object_r:rhizo_power_shadow:s0"),
    ("/dev/dri/renderD128",     "u:object_r:gpu_device:s0"),
    ("/dev/dri/card0",          "u:object_r:gpu_device:s0"),
    ("/dev/tun",                "u:object_r:tun_device:s0"),
    ("/dev/uinput",             "u:object_r:uhid_device:s0"),
    ("/dev/uhid",               "u:object_r:uhid_device:s0"),
    ("/sys/kernel/wakeup_reasons",                    "u:object_r:rhizo_wakeup_reasons_shadow:s0"),
    ("/sys/kernel/wakeup_reasons/last_resume_reason", "u:object_r:rhizo_wakeup_reasons_shadow:s0"),
    ("/sys/kernel/wakeup_reasons/last_suspend_time",  "u:object_r:rhizo_wakeup_reasons_shadow:s0"),
    ("/system/apex",            "u:object_r:system_file:s0"),
    ("/system_ext/overlay",     "u:object_r:vendor_overlay_file:s0"),
    ("/product/etc/permissions", "u:object_r:system_file:s0"),
]
PRE_INIT_RELABEL_IF_PRESENT = [
    ("/adb_keys", "u:object_r:system_file:s0"),
]
def relabel_root_objects_now(newroot, staged=()):
    """relabel the sandbox root objects"""
    try:
        with open("/proc/self/attr/current") as f:
            cur = f.read().strip("\0").strip()
    except OSError as e:
        kmsg(f"pre-init relabel: cannot read own context ({e}) -- skipped")
        return
    if ":" not in cur:
        kmsg(f"pre-init relabel: no policy loaded yet (context {cur!r}) -- skipped")
        return
    done, failed, unverifiable, foreign = [], [], [], []
    for rel, want in PRE_INIT_RELABEL + [(p, lbl) for p, lbl in list(staged) + PRE_INIT_RELABEL_IF_PRESENT
                                         if os.path.lexists(newroot + p)]:
        path = newroot + rel if rel != "/" else newroot
        if not os.path.lexists(path):
            failed.append(f"{rel}: absent")
            continue
        lnk = os.path.islink(path)
        try:
            cur = os.getxattr(path, "security.selinux",
                              follow_symlinks=not lnk).decode().rstrip("\x00")
            if cur == want:
                done.append(rel)
                continue
        except OSError:
            pass
        try:
            if not label_write(path, (want + "\0").encode(),
                               follow_symlinks=not lnk, skipped=foreign):
                continue
        except OSError as e:
            failed.append(f"{rel}: {e}")
            continue
        try:
            got = os.getxattr(path, "security.selinux",
                              follow_symlinks=not lnk).decode().rstrip("\x00")
        except PermissionError as e:
            unverifiable.append(f"{rel}: set ok, read-back denied ({e})")
            continue
        except OSError as e:
            failed.append(f"{rel}: read-back {e}")
            continue
        (done if got == want else failed).append(rel if got == want else f"{rel}: got {got}")
    kmsg("pre-init relabel: ok=%s%s%s%s"
         % (done,
            ("; unverifiable " + str(unverifiable)) if unverifiable else "",
            (f"; gsi-backed skipped={len(foreign)} {foreign[:4]}") if foreign else "",
            ("; FAILED " + str(failed)) if failed else ""))

    _dev_dirs = [("/dev/input", "u:object_r:input_device:s0"),
                 ("/dev/dri", "u:object_r:gpu_device:s0"),
                 ("/dev/socket/rhizo_wayland", "u:object_r:rhizo_wayland_socket:s0"),
                 ("/dev/socket/rhizo_audio", "u:object_r:rhizo_audio_socket:s0"),
                 ("/dev/socket/rhizo_stream", "u:object_r:rhizo_stream_socket:s0"),
                 ("/dev/socket/rhizo_rt", "u:object_r:rhizo_rt_socket:s0"),
                 ("/dev/socket/rhizo_delay", "u:object_r:rhizo_delay_socket:s0"),
                 ("/dev/socket/rhizo_headroom", "u:object_r:rhizo_headroom_socket:s0"),
                 ("/dev/socket/rhizo_bluetooth", "u:object_r:rhizo_bluetooth_socket:s0"),
                 (DEVICE_STATE_MOUNT, DEVICE_STATE_LABEL)]
    _dev_done = 0
    _dev_fail = []
    _dev_foreign = []
    for _rel, _want in _dev_dirs:
        _base = newroot + _rel
        if not os.path.lexists(_base):
            continue
        _targets = [_base]
        if os.path.isdir(_base) and not os.path.islink(_base):
            for _dp, _dn, _fn in os.walk(_base):
                _targets += [os.path.join(_dp, _x) for _x in _dn + _fn]
        for _t in _targets:
            _tl = os.path.islink(_t)
            try:
                if os.getxattr(_t, "security.selinux",
                               follow_symlinks=not _tl).decode(
                                   errors="replace").rstrip("\x00") == _want:
                    continue
                if label_write(_t, (_want + "\0").encode(),
                               follow_symlinks=not _tl, skipped=_dev_foreign):
                    _dev_done += 1
            except OSError as _e:
                if len(_dev_fail) < 8:
                    _dev_fail.append("%s: %s" % (_t, _e))
    kmsg("pre-init /dev relabel: %d objects%s%s"
         % (_dev_done,
            (f"; gsi-backed skipped={len(_dev_foreign)} {_dev_foreign[:4]}")
            if _dev_foreign else "",
            ("; FAILED " + str(_dev_fail)) if _dev_fail else ""))
def relabel_flat_trees_now():
    """relabel the staged flat trees"""
    try:
        with open("/proc/self/attr/current") as f:
            cur = f.read().strip("\0").strip()
    except OSError as e:
        kmsg(f"restart relabel: cannot read own context ({e}) -- not relabeling")
        return
    if ":" not in cur:
        kmsg(f"restart relabel: no policy loaded yet (context {cur!r}) -- skipped")
        return
    if not os.path.exists(HOST_PRIMER_PATH):
        kmsg("restart relabel skipped: the primer script is not staged yet")
        return
    try:
        r = subprocess.run([sys.executable, HOST_PRIMER_PATH, "--relabel-flat",
                            "--sandbox-id", str(SANDBOX_ID),
                            "--run-root", RUN_ROOT, "--init-pid-file", INIT_PID_FILE],
                           capture_output=True, text=True, timeout=120)
        kmsg(f"restart flat-tree relabel rc={r.returncode} {r.stderr.strip()[:200]}")
    except Exception as e:
        kmsg(f"restart flat-tree relabel FAILED: {e}")
