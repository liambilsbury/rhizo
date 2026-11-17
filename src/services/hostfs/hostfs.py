#!/usr/bin/env python3

import argparse
import configparser
import ctypes
import json
import os
import pwd
import re
import stat as stat_module
import subprocess
import sys
import time

CLONE_NEWNS = 0x00020000
MS_NOSUID, MS_NODEV, MS_NOEXEC = 2, 4, 8
MS_NOATIME, MS_LAZYTIME = 1024, 1 << 25

MODES = ("over", "under")
DEFAULT_MODE = "over"


def _default_daemon_path():
    """return the rhizo-hostfsd path in var/share, ../share or ../host"""
    here = os.path.dirname(os.path.abspath(__file__))
    if os.path.isdir(os.path.join(here, "..", "..", "androidd")):
        share = ("..", "..", "..", "var", "share")
    else:
        share = ("..", "share")
    for sibling in (share, ("..", "host")):
        candidate = os.path.normpath(os.path.join(here, *sibling, "rhizo-hostfsd"))
        if os.path.exists(candidate):
            return candidate
    return os.path.normpath(os.path.join(here, *share, "rhizo-hostfsd"))


DEFAULT_DAEMON = _default_daemon_path()
DEFAULT_DAEMON_LOG = "/tmp/rhizo-hostfsd.log"

AID_MEDIA_RW = 1023
AID_EVERYBODY = 9997
DEFAULT_NAME = "Host"
LOWER_ROOT = "/data/media/0"
LAUNCHER3 = os.environ.get("RHIZO_LAUNCHER", "/usr/lib/rhizo/launcher3.py")
SHARE_NAME_RE = r"[A-Za-z0-9][A-Za-z0-9._-]*"
ATTR_CURRENT = "/proc/self/attr/current"
MEDIA_RW_LABEL = b"u:object_r:media_rw_data_file:s0"
SELINUX_MODE_FILE = os.environ.get("RHIZO_SELINUX_MODE_FILE", "/run/rhizo-selinux-mode")
OVER_ROOT = "/mnt/user/0/emulated/0"

libc = ctypes.CDLL(None, use_errno=True)
libc.setns.argtypes = [ctypes.c_int, ctypes.c_int]
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                       ctypes.c_ulong, ctypes.c_void_p]
libc.umount2.argtypes = [ctypes.c_char_p, ctypes.c_int]
libc.setfsuid.argtypes = [ctypes.c_uint]
libc.setfsgid.argtypes = [ctypes.c_uint]


def read_selinux_mode(path=SELINUX_MODE_FILE):
    """return the path text, or "unreadable ({e})" on OSError"""
    try:
        with open(path) as f:
            return f.read().rstrip("\n")
    except OSError as e:
        return f"unreadable ({e})"


def label_android_file(path, label, mode):
    """set security.selinux on path and return an error string or None"""
    if mode == "host":
        return None
    if mode != "namespace":
        return f"the SELinux mode is {mode}"
    try:
        os.setxattr(path, "security.selinux", label + b"\0", follow_symlinks=False)
        got = os.getxattr(path, "security.selinux", follow_symlinks=False).rstrip(b"\0")
    except OSError as e:
        return str(e)
    return None if got == label else f"security.selinux is {got!r}"


def _errno_msg(prefix):
    """return prefix, errno and strerror"""
    e = ctypes.get_errno()
    return f"{prefix} failed errno={e} ({os.strerror(e)})"


def enter_sandbox_ns(init_pid):
    """join the sandbox mount namespace as media_rw"""
    try:
        nsfd = os.open(f"/proc/{init_pid}/ns/mnt", os.O_RDONLY)
    except OSError as e:
        return f"failed to open /proc/{init_pid}/ns/mnt ({e})"
    if libc.setns(nsfd, CLONE_NEWNS) != 0:
        os.close(nsfd)
        return _errno_msg("setns(CLONE_NEWNS)")
    os.close(nsfd)
    try:
        os.setgroups([AID_EVERYBODY, AID_MEDIA_RW])
    except OSError as e:
        return f"setgroups({AID_EVERYBODY},{AID_MEDIA_RW}) failed ({e})"
    libc.setfsgid(AID_MEDIA_RW)
    libc.setfsuid(AID_MEDIA_RW)
    if libc.setfsuid(AID_MEDIA_RW) != AID_MEDIA_RW:
        return "setfsuid(AID_MEDIA_RW) failed"
    return None


def host_policy_loaded(attr=ATTR_CURRENT):
    """return whether the attr context contains a colon"""
    try:
        with open(attr) as f:
            ctx = f.read().strip("\0\n")
    except FileNotFoundError:
        return False
    return ":" in ctx


def label_in_policy_namespace(init_pid, name, lower, run=subprocess.run):
    """run hostfs-label-lower under the Android policy and return ok and the log lines"""
    argv = [sys.executable, LAUNCHER3, "in-android-policy", "hostfs-label-lower", os.path.abspath(__file__),
            "label-lower", "--init-pid", str(init_pid), "--name", name, "--path", lower]
    try:
        r = run(argv, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, [f"[{name}] failed to run hostfs-label-lower for {lower} ({e})"]
    last = (r.stdout.strip().splitlines() or [""])[-1]
    try:
        rep = json.loads(last)
    except ValueError:
        return False, [f"[{name}] hostfs-label-lower for {lower} failed with exit status {r.returncode} "
                       f"({last or r.stderr.strip()[-200:]})"]
    return bool(rep.get("ok")), rep.get("log", [])


def cmd_label_lower(args):
    """prepare a mount point in the sandbox namespace"""
    if not re.fullmatch(SHARE_NAME_RE, args.name) or args.path != f"{LOWER_ROOT}/{args.name}":
        print(json.dumps({"ok": False, "log": [f"--path {args.path!r} is not {LOWER_ROOT}/<--name> for "
                                               f"--name {args.name!r}"]}))
        return 2
    lines = []
    why = enter_sandbox_ns(args.init_pid)
    ok = not why and prepare_mount_point(args.name, args.path, "namespace", lines)
    print(json.dumps({"ok": bool(ok), "log": lines + ([why] if why else [])}))
    return 0 if ok else 1


def _in_sandbox(init_pid, fn, keep_fds=()):
    """run fn in the sandbox mount namespace"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        for fd in keep_fds:
            os.set_inheritable(fd, True)
        lines = []

        why = enter_sandbox_ns(init_pid)
        if why:
            os.write(w, json.dumps({"ok": False, "log": lines + [why]}).encode())
            os._exit(1)
        try:
            ok = fn(lines)
        except Exception as e:                    # noqa: BLE001
            ok = False
            lines.append(f"unhandled {type(e).__name__} ({e})")
        os.write(w, json.dumps({"ok": bool(ok), "log": lines}).encode())
        os._exit(0 if ok else 1)
    os.close(w)
    with os.fdopen(r, "rb") as f:
        raw = f.read()
    _, st = os.waitpid(pid, 0)
    try:
        return json.loads(raw.decode() or "{}")
    except ValueError:
        return {"ok": False, "log": [f"the forked child wrote no JSON (status {st})"]}


def _as_user(uid, gid, fn):
    """run fn in a forked child with setfsuid"""
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(r)
        lines = []
        try:
            os.setgroups([gid])
        except OSError:
            pass
        libc.setfsgid(gid)
        libc.setfsuid(uid)
        if libc.setfsuid(uid) != uid:
            os.write(w, json.dumps({"ok": False, "log": [f"setfsuid({uid}) failed"]}).encode())
            os._exit(1)
        try:
            ok = fn(lines)
        except Exception as e:                    # noqa: BLE001
            ok = False
            lines.append(f"unhandled {type(e).__name__} ({e})")
        os.write(w, json.dumps({"ok": bool(ok), "log": lines}).encode())
        os._exit(0 if ok else 1)
    os.close(w)
    with os.fdopen(r, "rb") as f:
        raw = f.read()
    os.waitpid(pid, 0)
    try:
        return json.loads(raw.decode() or "{}")
    except ValueError:
        return {"ok": False, "log": ["the forked child wrote no JSON"]}


def resolve_owner(host_dir, as_user):
    """return the share owner uid, gid and an error string"""
    if as_user is not None:
        try:
            ent = pwd.getpwuid(int(as_user)) if str(as_user).isdigit() else pwd.getpwnam(as_user)
        except (KeyError, ValueError):
            return None, None, f"no such user {as_user!r}"
        return ent.pw_uid, ent.pw_gid, None
    try:
        st = os.stat(host_dir)
        return st.st_uid, st.st_gid, None
    except PermissionError:
        return _owner_through_ancestor(host_dir)
    except OSError as e:
        return None, None, f"failed to stat {host_dir} ({e})"


def _owner_through_ancestor(host_dir):
    """return the host_dir uid and gid with the fsuid of the first stat-able ancestor owner"""
    anc = os.path.dirname(host_dir)
    while True:
        try:
            ast = os.stat(anc)
            break
        except PermissionError:
            if anc == os.path.dirname(anc):
                return None, None, f"failed to stat each directory above {host_dir} as root"
            anc = os.path.dirname(anc)
        except OSError as e:
            return None, None, f"failed to stat {anc} ({e})"

    def probe(lines):
        """append the host_dir uid and gid to lines"""
        st = os.stat(host_dir)
        lines.append(f"{st.st_uid} {st.st_gid}")
        return True

    rep = _as_user(ast.st_uid, ast.st_gid, probe)
    log = rep.get("log", [])
    if rep.get("ok") and log:
        uid, gid = (int(x) for x in log[-1].split())
        return uid, gid, None
    why = log[-1] if log else "no log line"
    return None, None, (f"failed to stat {host_dir} as root or as uid {ast.st_uid} ({why})")


def mounted_shares(init_pid):
    """return the fuse shares mounted in the sandbox"""
    found = []
    try:
        with open(f"/proc/{init_pid}/mountinfo") as f:
            lines = f.readlines()
    except OSError:
        return found
    for line in lines:
        parts = line.split()
        try:
            mp, fstype = parts[4], parts[parts.index("-") + 1]
        except (IndexError, ValueError):
            continue
        if fstype != "fuse":
            continue
        for root, mode in ((OVER_ROOT, "over"), (LOWER_ROOT, "under")):
            if mp.startswith(root + "/") and "/" not in mp[len(root) + 1:]:
                found.append(Share(mp[len(root) + 1:], "/", mode))
                break
    return found


def sandbox_mount_line(init_pid, target):
    """return the sandbox mountinfo line for target"""
    try:
        with open(f"/proc/{init_pid}/mountinfo") as f:
            for line in f:
                parts = line.split()
                if len(parts) > 4 and parts[4] == target:
                    return line.rstrip("\n")
    except OSError:
        return None
    return None


def start_daemon(daemon, fuse_fd, host_dir, uid, gid, android_uid, android_gid, log_path):
    """fork and exec rhizo-hostfsd"""
    daemon_fd = os.open(daemon, os.O_RDONLY | os.O_CLOEXEC)
    pid = os.fork()
    if pid != 0:
        os.close(daemon_fd)
        return pid
    os.setsid()
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    if fd > 2:
        os.close(fd)
    os.set_inheritable(fuse_fd, True)
    if os.getuid() == 0 and uid != 0:
        try:
            os.initgroups(pwd.getpwuid(uid).pw_name, gid)
        except (KeyError, OSError):
            os.setgroups([gid])
        os.setgid(gid)
        os.setuid(uid)
    os.set_inheritable(daemon_fd, True)
    os.execve(daemon_fd, [daemon, "--fd", str(fuse_fd), "--root", host_dir,
                          "--uid", str(android_uid), "--gid", str(android_gid),
                          "--foreground"], os.environ)
    os._exit(127)


class Share:
    """host directory shared with the sandbox"""

    def __init__(self, name, host_dir, mode=DEFAULT_MODE, as_user=None,
                 daemon=None):
        """set the share name and host directory"""
        self.name = name
        self.host_dir = os.path.abspath(host_dir)
        self.mode = mode
        self.as_user = as_user
        self.daemon = daemon

    @property
    def target(self):
        """return the mount point path"""
        return (f"{OVER_ROOT}/{self.name}" if self.mode == "over"
                else f"{LOWER_ROOT}/{self.name}")

    @property
    def lower(self):
        """return the directory under /data/media/0"""
        return f"{LOWER_ROOT}/{self.name}"


def _shares_allowed():
    """return capabilities.shares_enabled for the policy"""
    here = os.path.dirname(os.path.abspath(__file__))
    up = os.path.join(here, "..")
    if os.path.isdir(os.path.join(up, "..", "androidd")):
        up = os.path.join(up, "..", "androidd")
    for d in (here, up):
        if d not in sys.path:
            sys.path.insert(0, d)
    from sandbox import capabilities
    return capabilities.shares_enabled(capabilities.policy_or_deny())


def read_config(path):
    """read shares from an ini file"""
    if not _shares_allowed():
        return None, f"skipped {path} with host shares disabled"
    cp = configparser.ConfigParser()
    try:
        with open(path) as f:
            cp.read_file(f)
    except OSError as e:
        return None, f"failed to read {path} ({e})"
    except configparser.Error as e:
        return None, f"failed to parse {path} ({e})"
    shares, seen = [], {}
    for name in cp.sections():
        if not re.fullmatch(SHARE_NAME_RE, name):
            return None, f"{path} section [{name}] does not match SHARE_NAME_RE"
        sec = cp[name]
        host_dir = sec.get("dir", "").strip()
        if not host_dir:
            return None, f"{path} section [{name}] has no dir="
        mode = sec.get("mode", DEFAULT_MODE).strip()
        daemon = (sec.get("daemon") or "").strip() or None
        if mode not in MODES:
            return None, f"{path} section [{name}] mode={mode!r}, expected one of {'/'.join(MODES)}"
        if host_dir in seen:
            return None, f"{path} sections [{name}] and [{seen[host_dir]}] have dir={host_dir}"
        seen[host_dir] = name
        shares.append(Share(name, host_dir, mode, sec.get("user") or None, daemon))
    if not shares:
        return None, f"{path} has no sections"
    return shares, None


XDG_DEFAULTS = (
    ("Download", "XDG_DOWNLOAD_DIR", "Downloads"),
    ("Documents", "XDG_DOCUMENTS_DIR", "Documents"),
    ("Pictures", "XDG_PICTURES_DIR", "Pictures"),
    ("Music", "XDG_MUSIC_DIR", "Music"),
    ("Movies", "XDG_VIDEOS_DIR", "Videos"),
)
USER_DIRS = ".config/user-dirs.dirs"


def xdg_share_dirs(home, user_dirs_text):
    """return the collection and host directory pairs"""
    named = {}
    for line in (user_dirs_text or "").splitlines():
        m = re.match(r'^\s*(XDG_[A-Z]+_DIR)="(.*)"\s*$', line)
        if not m:
            continue
        value = m.group(2).replace('\\"', '"')
        if value == "$HOME" or value.startswith("$HOME/"):
            value = home + value[len("$HOME"):]
        elif not value.startswith("/"):
            continue
        named[m.group(1)] = os.path.normpath(value)
    out = []
    for collection, key, default in XDG_DEFAULTS:
        host_dir = named.get(key, os.path.join(home, default))
        if host_dir != os.path.normpath(home):
            out.append((collection, host_dir))
    return out


def wait_for_storage(init_pid, timeout, targets=(OVER_ROOT,)):
    """wait for the emulated storage mount points"""
    deadline = time.time() + timeout

    def probe(lines):
        """return whether os.stat succeeds on each target"""
        for path in targets:
            try:
                os.stat(path)
            except OSError as e:
                lines.append(str(e))
                return False
        return True

    last = ""
    while time.time() < deadline:
        rep = _in_sandbox(init_pid, probe)
        if rep.get("ok"):
            return True, ""
        last = "; ".join(rep.get("log", [])) or "no log line"
        time.sleep(1)
    return False, f"failed to stat {OVER_ROOT} within {timeout}s ({last})"


def _is_foreign_namespace_member(proc_root, d):
    """return whether the pid d NSpid has a nested pid other than 1"""
    try:
        with open(f"{proc_root}/{d}/status") as f:
            for line in f:
                if line.startswith("NSpid:"):
                    ns = line.split()[1:]
                    return len(ns) >= 2 and ns[-1] != "1"
    except OSError:
        pass
    return False


_RHIZO_STACK_RE = re.compile(
    r"^/(rhizo(-[0-9]+)?|system\.slice/(system-androidd\.slice/)?androidd(@[0-9]+)?\.service/android)/")


def _in_rhizo_stack(proc_root, d):
    """return whether the pid d cgroup matches _RHIZO_STACK_RE"""
    try:
        lines = open(f"{proc_root}/{d}/cgroup").read().splitlines()
    except OSError:
        return False
    return any(line.startswith("0::") and _RHIZO_STACK_RE.match(line[3:]) for line in lines)


def find_init_pid(proc_root="/proc"):
    """return the sandbox init pid and an error string"""
    found = []
    for d in os.listdir(proc_root):
        if not d.isdigit():
            continue
        try:
            argv = open(f"{proc_root}/{d}/cmdline", "rb").read().split(b"\0")
        except OSError:
            continue
        if len(argv) >= 2 and argv[0] == b"/system/bin/init" and argv[1] == b"second_stage":
            if not _in_rhizo_stack(proc_root, d):
                continue
            if _is_foreign_namespace_member(proc_root, d):
                continue
            found.append(int(d))
    if not found:
        return None, "no `/system/bin/init second_stage` process is running"
    if len(found) > 1:
        return None, ("more than one sandbox is running (" +
                      ", ".join(str(p) for p in sorted(found)) +
                      ")")
    return found[0], None


def read_label(path):
    """return path's security.selinux label, or None"""
    try:
        return os.getxattr(path, "security.selinux", follow_symlinks=False).rstrip(b"\0")
    except OSError:
        return None


def prepare_mount_point(name, lower, mode, lines):
    """create the mount point and set security.selinux to media_rw_data_file"""
    created = False
    try:
        os.mkdir(lower, 0o770)
        created = True
        lines.append(f"[{name}] created the mount point {lower}")
    except FileExistsError:
        pass
    except OSError as e:
        lines.append(f"[{name}] failed to create {lower} ({e})")
        return False
    current = None if created else read_label(lower)
    if current and current.split(b":")[:3] == MEDIA_RW_LABEL.split(b":")[:3]:
        return True
    why = label_android_file(lower, MEDIA_RW_LABEL, mode)
    if why:
        lines.append(f"[{name}] failed to label {lower} {MEDIA_RW_LABEL.decode()} ({why})")
        if created:
            try:
                os.rmdir(lower)
            except OSError as e:
                lines.append(f"[{name}] failed to remove {lower} ({e})")
        return False
    return True


def open_fuse():
    """open /dev/fuse for a mount"""
    return os.open("/dev/fuse", os.O_RDWR | os.O_CLOEXEC)


def attach_one(init_pid, share, daemon, daemon_log, android_uid, android_gid):
    """mount the share and start rhizo-hostfsd"""
    out = []
    uid, gid, err = resolve_owner(share.host_dir, share.as_user)
    if err:
        return False, [err]

    def check(lines):
        """return whether share.host_dir is a directory"""
        try:
            st = os.stat(share.host_dir)
        except OSError as e:
            lines.append(f"failed to stat {share.host_dir} ({e})")
            return False
        if not stat_module.S_ISDIR(st.st_mode):
            lines.append(f"{share.host_dir} is not a directory")
            return False
        lines.append(f"[{share.name}] host_dir={share.host_dir} uid={uid} gid={gid} mode={share.mode}")
        return True

    rep0 = _as_user(uid, gid, check)
    out += rep0.get("log", [])
    if not rep0.get("ok"):
        return False, out
    daemon = share.daemon or daemon
    if not os.access(daemon, os.X_OK):
        return False, out + [f"[{share.name}] {daemon} is not executable"]

    target, lower = share.target, share.lower
    mode = read_selinux_mode()
    if sandbox_mount_line(init_pid, target):
        return False, out + [f"{target} is still mounted"]

    try:
        fuse_fd = open_fuse()
    except OSError as e:
        return False, out + [f"failed to open /dev/fuse ({e})"]
    os.set_inheritable(fuse_fd, True)
    opts = f"fd={fuse_fd},rootmode=40000,allow_other,user_id=0,group_id=0".encode()
    flags = MS_NOSUID | MS_NODEV | MS_NOEXEC | MS_NOATIME | MS_LAZYTIME

    try:
        prepared = mode == "namespace" and host_policy_loaded()
    except OSError as e:
        os.close(fuse_fd)
        return False, out + [f"[{share.name}] failed to read /proc/self/attr/current ({e})"]
    if prepared:
        ok, lines = label_in_policy_namespace(init_pid, share.name, lower)
        out += lines
        if not ok:
            os.close(fuse_fd)
            return False, out

    def do(lines):
        """create, label and mount the mount point"""
        if not prepared and not prepare_mount_point(share.name, lower, mode, lines):
            return False
        try:
            os.stat(target)
        except OSError as e:
            lines.append(f"[{share.name}] failed to stat {target} ({e})")
            return False
        if libc.mount(b"/dev/fuse", target.encode(), b"fuse", flags, opts) != 0:
            lines.append(_errno_msg(f"[{share.name}] mount fuse at {target}"))
            return False
        lines.append(f"[{share.name}] mounted at {target}")
        return True

    rep = _in_sandbox(init_pid, do, keep_fds=(fuse_fd,))
    out += rep.get("log", [])
    if not rep.get("ok"):
        os.close(fuse_fd)
        return False, out
    dpid = start_daemon(daemon, fuse_fd, share.host_dir, uid, gid,
                        android_uid, android_gid, daemon_log)
    os.close(fuse_fd)

    def readback(lines):
        """list the shared directory through the mount"""
        deadline = time.time() + 15
        last = ""
        while time.time() < deadline:
            try:
                names = sorted(os.listdir(target))
                lines.append(f"[{share.name}] read back through the mount "
                             f"entries={len(names)}"
                             + (f" ({', '.join(names[:12])})" if names else ""))
                return True
            except OSError as e:
                last = str(e)
                time.sleep(0.3)
        lines.append(f"[{share.name}] failed to list the mount "
                     f"within 15s ({last})")
        return False

    chk = _in_sandbox(init_pid, readback)
    out += chk.get("log", [])
    if not chk.get("ok"):
        def undo(lines):
            """unmount the target"""
            ctypes.set_errno(0)
            if libc.umount2(target.encode(), 0) != 0:
                lines.append(_errno_msg(f"[{share.name}] umount2({target})"))
                return False
            lines.append(f"[{share.name}] unmounted the target")
            return True

        out += _in_sandbox(init_pid, undo).get("log", [])
        return False, out + [f"[{share.name}] rhizo-hostfsd pid {dpid} is not "
                             f"serving log={daemon_log}"]
    out.append(f"[{share.name}] rhizo-hostfsd pid {dpid} serving {share.host_dir}")
    return True, out


def detach_one(init_pid, share):
    """unmount a share's target in the mount namespace"""
    target = share.target

    def do(lines):
        """unmount the target and log the result"""
        ctypes.set_errno(0)
        if libc.umount2(target.encode(), 0) != 0:
            lines.append(_errno_msg(f"[{share.name}] umount2({target})"))
            return False
        lines.append(f"[{share.name}] detached {target}")
        return True

    rep = _in_sandbox(init_pid, do)
    return bool(rep.get("ok")), rep.get("log", [])


def _shares_for(args):
    """return the shares from --config or the flags"""
    if getattr(args, "config", None):
        return read_config(args.config)
    if not getattr(args, "host_dir", None):
        return [], f"{args.verb} without --config or --host-dir"
    return [Share(args.name, args.host_dir, getattr(args, "mode", DEFAULT_MODE),
                  getattr(args, "as_user", None),
                  getattr(args, "daemon_override", None))], None


def cmd_attach(args):
    """attach the shares in the sandbox"""
    shares, err = _shares_for(args)
    if err:
        print(f"{err}", file=sys.stderr)
        return 2
    if args.wait_for_storage > 0:
        ok, why = wait_for_storage(args.init_pid, args.wait_for_storage,
                                   [OVER_ROOT] + [s.target for s in shares])
        if not ok:
            print(f"{why}", file=sys.stderr)
            return 1
    results = []
    for share in shares:
        ok, lines = attach_one(args.init_pid, share, args.daemon,
                               args.daemon_log, args.android_uid, args.android_gid)
        for line in lines:
            print(f"{line}")
        results.append((share, ok))
    bad = [s.name for s, ok in results if not ok]
    if args.json:
        print(json.dumps({"ok": not bad,
                          "attached": [s.name for s, ok in results if ok],
                          "failed": bad}))
    if bad:
        print(f"{len(bad)} of {len(results)} shares failed "
              + ", ".join(bad), file=sys.stderr)
        return 1
    print(f"{len(results)} shares attached")
    return 0


def cmd_detach(args):
    """detach the shares in the config or flags, or each mounted share with --all"""
    if args.all:
        shares, err = mounted_shares(args.init_pid), None
        if not shares:
            print("0 shares mounted")
            return 0
    else:
        shares, err = _shares_for(args)
    if err:
        print(f"{err}", file=sys.stderr)
        return 2
    bad = []
    for share in shares:
        ok, lines = detach_one(args.init_pid, share)
        for line in lines:
            print(f"{line}")
        if not ok:
            bad.append(share.name)
    return 1 if bad else 0


def cmd_status(args):
    """print the status of each share"""
    shares, err = _shares_for(args)
    if err:
        print(f"{err}", file=sys.stderr)
        return 2
    rows, missing = [], 0
    for share in shares:
        line = sandbox_mount_line(args.init_pid, share.target)
        rows.append({"name": share.name, "attached": line is not None,
                     "target": share.target, "mode": share.mode,
                     "host_dir": share.host_dir, "mountinfo": line})
        if line is None:
            missing += 1
        if not args.json:
            print(f"[{share.name}] {share.target} is "
                  + ("attached" if line else "not attached")
                  + f" mode={share.mode} host_dir={share.host_dir}")
    if args.json:
        print(json.dumps({"shares": rows, "all_attached": missing == 0}))
    return 0 if missing == 0 else 1


def cmd_default_config(args):
    """print a config for the XDG user directories that exist"""
    try:
        ent = (pwd.getpwuid(int(args.as_user)) if str(args.as_user).isdigit()
               else pwd.getpwnam(args.as_user))
    except (KeyError, ValueError):
        print(f"no such user {args.as_user!r}", file=sys.stderr)
        return 2
    body = ["# Written by hostfs.py default-config.",
            "# a section is a directory under /storage/emulated/0",
            "# default mode=over mounts at /mnt/user/0/emulated/0/<section>",
            "# mode=under mounts at /data/media/0/<section>", ""]
    found = 0

    def read_user_dirs(lines):
        """append the user-dirs.dirs text to lines"""
        try:
            with open(os.path.join(ent.pw_dir, USER_DIRS)) as f:
                lines.append(f.read())
        except FileNotFoundError:
            pass
        return True
    rep = _as_user(ent.pw_uid, ent.pw_gid, read_user_dirs)
    if not rep.get("ok"):
        print(f"failed to read {ent.pw_dir}/{USER_DIRS} (" + "; ".join(rep.get("log", [])) + ")",
              file=sys.stderr)
        return 1
    dirs = xdg_share_dirs(ent.pw_dir, "".join(rep.get("log", [])))
    for android_name, host_dir in dirs:

        def exists(lines):
            """return whether the host directory exists"""
            return os.path.isdir(host_dir)

        if not _as_user(ent.pw_uid, ent.pw_gid, exists).get("ok"):
            continue
        found += 1
        body += [f"[{android_name}]", f"dir = {host_dir}",
                 f"user = {ent.pw_name}", ""]
    if not found:
        print(f"{ent.pw_dir} has no XDG user directory "
              "(" + ", ".join(d for _, d in dirs) + ")",
              file=sys.stderr)
        return 1
    text = "\n".join(body)
    if args.out:
        os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
        with open(args.out, "w") as f:
            f.write(text)
        print(f"wrote {found} shares to {args.out}")
    else:
        sys.stdout.write(text)
    return 0


def build_parser():
    """return the argument parser"""
    p = argparse.ArgumentParser(prog="hostfs.py")
    sub = p.add_subparsers(dest="verb", required=True)
    for verb in ("attach", "detach", "status"):
        s = sub.add_parser(verb)
        s.add_argument("--init-pid", type=int, default=None,
                       help="sandbox init pid, default from /proc")
        s.add_argument("--config", default=None,
                       help="ini file of shares")
        s.add_argument("--name", default=DEFAULT_NAME)
        s.add_argument("--host-dir", default=None)
        s.add_argument("--mode", choices=MODES, default=DEFAULT_MODE)
        s.add_argument("--as-user", default=None,
                       help="share owner name or uid")
        s.add_argument("--json", action="store_true")
        if verb == "detach":
            s.add_argument("--all", action="store_true",
                           help="detach each fuse share in the sandbox mountinfo")
        if verb == "attach":
            s.add_argument("--daemon", default=DEFAULT_DAEMON)
            s.add_argument("--daemon-log", default=DEFAULT_DAEMON_LOG)
            s.add_argument("--wait-for-storage", type=int, default=0,
                           metavar="SECONDS",
                           help="wait at most SECONDS for the emulated storage mount points")
            s.add_argument("--android-uid", type=int, default=AID_MEDIA_RW)
            s.add_argument("--android-gid", type=int, default=AID_MEDIA_RW)
    lab = sub.add_parser("label-lower")
    lab.add_argument("--init-pid", type=int, required=True)
    lab.add_argument("--name", required=True)
    lab.add_argument("--path", required=True)
    d = sub.add_parser("default-config")
    d.add_argument("--as-user", required=True)
    d.add_argument("--out", default=None)
    return p


def main():
    """parse the arguments and run the verb"""
    args = build_parser().parse_args()

    if args.verb == "default-config":
        return cmd_default_config(args)
    if args.verb == "label-lower":
        return cmd_label_lower(args)
    if not args.config and not args.host_dir and args.verb == "attach":
        print("attach without --host-dir or --config", file=sys.stderr)
        return 2
    if args.init_pid is None:
        args.init_pid, why = find_init_pid()
        wait_budget = getattr(args, "wait_for_storage", 0) or 0
        if args.init_pid is None and args.verb == "attach" and wait_budget > 0:
            deadline = time.time() + wait_budget
            while args.init_pid is None and time.time() < deadline:
                time.sleep(1)
                args.init_pid, why = find_init_pid()
            args.wait_for_storage = max(1, int(deadline - time.time()))
        if args.init_pid is None:
            print(f"{why}", file=sys.stderr)
            return 2
    elif not os.path.isdir(f"/proc/{args.init_pid}"):
        print(f"no process {args.init_pid}", file=sys.stderr)
        return 2
    return {"attach": cmd_attach, "detach": cmd_detach,
            "status": cmd_status}[args.verb](args)


if __name__ == "__main__":
    sys.exit(main())
