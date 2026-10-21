#!/usr/bin/env python3
import argparse
import ast
import base64
import binascii
import contextlib
import errno
import fcntl
import functools
import hashlib
import importlib.util
import io
import json
import math
import os
import re
import select
import shlex
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
import zlib

_HERE = os.path.dirname(os.path.abspath(__file__))
_CHECKOUT = os.path.isdir(os.path.join(_HERE, "..", "..", "androidd"))
BASE_DIR = os.path.normpath(os.path.join(_HERE, *(("..", "..") if _CHECKOUT else ("..",))))
LAUNCHER_DIR = os.path.join(BASE_DIR, "androidd") if _CHECKOUT else BASE_DIR
VAR_DIR = os.path.normpath(os.path.join(BASE_DIR, "..", "var")) if _CHECKOUT else BASE_DIR
SSH_KEY = os.path.join(VAR_DIR, "vm_key")

sys.path[:0] = [os.path.dirname(os.path.abspath(__file__)), LAUNCHER_DIR]
from sandbox import capabilities
_INSTANCE = os.environ.get("RHIZO_INSTANCE") or "0"
SSH_PORT = str(2222 + int(_INSTANCE) + int(os.environ.get("RHIZO_PORT_OFFSET") or "0"))
SSH_TARGET = "root@127.0.0.1"
def _pick_ssh_control_dir():
    """return a writable rhizo-ssh-<uid> directory"""
    for base in (os.environ.get("XDG_RUNTIME_DIR"), "/tmp"):
        if not base:
            continue
        cand = os.path.join(base, f"rhizo-ssh-{os.getuid()}")
        try:
            os.makedirs(cand, exist_ok=True)
            probe = os.path.join(cand, f".writable.{os.getpid()}")
            with open(probe, "w"):
                pass
            os.unlink(probe)
        except OSError:
            continue
        return cand
    raise SystemExit(
        "rhizo-appsync: no usable SSH ControlMaster directory. Set XDG_RUNTIME_DIR to a "
        "directory you own.")


_SSH_CONTROL_DIR = _pick_ssh_control_dir()
_SSH_CONTROL_SOCK = os.path.join(_SSH_CONTROL_DIR, f"cm{SSH_PORT}.sock")


@functools.lru_cache(maxsize=1)
def ssh_opts():
    """return the ssh and scp options"""
    if len(_SSH_CONTROL_SOCK) > 91:
        raise SystemExit(
            f"rhizo-appsync: ControlPath {_SSH_CONTROL_SOCK!r} is "
            f"{len(_SSH_CONTROL_SOCK)} bytes; ssh's temp suffix needs it at 91 or "
            f"under. Set XDG_RUNTIME_DIR shorter.")
    os.makedirs(_SSH_CONTROL_DIR, exist_ok=True)
    return ["-i", SSH_KEY, "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=auto", "-o", "ControlPersist=600",
            "-o", f"ControlPath={_SSH_CONTROL_SOCK}"]


GSI_GUEST = os.environ.get("RHIZO_GSI", "/srv/rhizo/gsi_system")
DATA_GUEST = "/run/rhizo/data"

_CACHE_DIR = "/var/cache/rhizo-appsync"
CACHE_PATH = (os.path.join(_CACHE_DIR, "cache.json") if os.path.isdir(_CACHE_DIR)
              else "/tmp/rhizo-appsync-cache.json")
CLAIMS_PATH = (os.path.join(_CACHE_DIR, "default-claims.json") if os.path.isdir(_CACHE_DIR)
               else "/tmp/rhizo-appsync-default-claims.json")

AAPT2_CANDIDATES = [
    "/usr/lib/rhizo/tools/aapt2",
    os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                  *(("..", "..", "..", "var") if _CHECKOUT else ("..",)), "share", "aapt2")),
]
DENSITY_RANK = {"xxxhdpi": 6, "xxhdpi": 5, "xhdpi": 4, "hdpi": 3, "mdpi": 2, "ldpi": 1}
SCHEME_PROBES = ("http", "https", "mailto", "tel", "geo", "rhizo-test")
MIME_PROBES = ("application/pdf", "text/plain", "text/html", "image/png",
               "image/jpeg", "audio/mpeg", "video/mp4", "application/zip")
MIME_PROBE_URI = "file:///storage/emulated/0/probe"
COMPONENT_RE = re.compile(r"^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$")
CHOOSER_RE = re.compile(r"(ResolverActivity|ChooserActivity)$")
PKG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.]*$")

PUSH_BATCH_OK = "RHIZO_PUSH_BATCH_OK"

DEFAULT_PREFIX = "/usr/share"
STANDARD_ICON_SIZES = (16, 22, 24, 32, 36, 48, 64, 72, 96, 128, 192, 256, 512)
GENERIC_ICON = "rhizo"
GENERIC_ICON_SIZE = 256
ICON_GEN = (os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tools", "build", "packaging", "deb", "gen-rhizo-icon.py"))
            if _CHECKOUT else
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "gen-rhizo-icon.py"))
APK_MIME = "application/vnd.android.package-archive"
APK_HANDLER = "rhizo-apk-installer.desktop"

PROBE_SOCK = "/run/rhizo/data/local/tmp/rhizo-probe.sock"
PROBE_CLIENT_GUEST_CANDIDATES = (
    "/root/share/rhizo-probe-client",
    "/root/share/probe-client.py",
    "/usr/lib/rhizo/rhizo-probe-client",
    "/usr/lib/rhizo/probe-client.py",
)

QUERY_ACTIVITIES_CMD = (
    "cmd package query-activities --brief -a android.intent.action.MAIN "
    "-c android.intent.category.LAUNCHER"
)
HIDDEN_PACKAGES = {"com.android.inputmethod.latin", "org.chromium.webview_shell", "com.rhizo.desktop"}


def log(msg):
    """print a message to stderr with the rhizo-appsync prefix"""
    print(f"[rhizo-appsync] {msg}", file=sys.stderr, flush=True)


SELINUX_MODE_FILE = "/run/rhizo-selinux-mode"
SELINUX_MODE_HELPER = "/usr/lib/rhizo/rhizo-selinux-mode"
ANDROIDD_ENV = "/etc/rhizo/androidd.env"
SELINUX_MODES = ("host", "namespace")


def configured_selinux_mode():
    """return the mode helper's configured SELinux mode"""
    helper = os.environ.get("RHIZO_SELINUX_MODE_HELPER", SELINUX_MODE_HELPER)
    env_file = os.environ.get("RHIZO_ANDROIDD_ENV", ANDROIDD_ENV)
    try:
        r = subprocess.run([helper, "--env-file", env_file, "--configured"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"running the SELinux mode helper {helper} failed: {e}") from e
    mode = r.stdout.strip()
    if r.returncode != 0 or mode not in SELINUX_MODES:
        raise RuntimeError(f"the SELinux mode helper {helper} exited {r.returncode} with {mode!r}: {r.stderr.strip()[:200]}")
    return mode


def read_selinux_mode():
    """return the recorded or configured SELinux mode"""
    path = os.environ.get("RHIZO_SELINUX_MODE_FILE", SELINUX_MODE_FILE)
    try:
        with open(path) as f:
            mode = f.read().rstrip("\n")
    except FileNotFoundError:
        mode = ""
    except OSError as e:
        raise RuntimeError(f"reading the SELinux mode file {path} failed: {e}") from e
    if not mode:
        return configured_selinux_mode()
    if mode not in SELINUX_MODES:
        raise RuntimeError(f"the SELinux mode file {path} holds {mode!r}, not host or namespace")
    return mode


def find_aapt2():
    """return the path of the aapt2 binary"""
    override = os.environ.get("RHIZO_AAPT2")
    if override:
        if not os.access(override, os.X_OK):
            log(f"FAIL: RHIZO_AAPT2={override} is not an executable file")
            sys.exit(1)
        return override
    for c in AAPT2_CANDIDATES:
        if os.access(c, os.X_OK):
            return c
    log("FAIL: no aapt2 at " + ", nor at ".join(AAPT2_CANDIDATES)
        + ". Build one with tools/build/toolchain/aapt2.sh, or name one in RHIZO_AAPT2.")
    sys.exit(1)


@functools.lru_cache(maxsize=1)
def icon_generator():
    """load gen-rhizo-icon.py"""
    if not os.path.isfile(ICON_GEN):
        return None
    spec = importlib.util.spec_from_file_location("rhizo_gen_icon", ICON_GEN)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _extract_rc_marker(out, marker):
    """extract the marker line value"""
    for line in out.splitlines():
        if line.startswith(marker):
            return line[len(marker):].strip()
    return None


# paths for system-wide desktop entries
class Dest:
    def __init__(self, prefix):
        """store the prefix and the paths under it"""
        self.prefix = prefix
        self.applications = os.path.join(prefix, "applications")
        self.icons = os.path.join(prefix, "icons", "hicolor")
        self.mimeapps = os.path.join(self.applications, "mimeapps.list")

    def entry(self, pkg):
        """return the path of a package's rhizo-<pkg>.desktop entry"""
        return os.path.join(self.applications, f"rhizo-{pkg}.desktop")

    def icon(self, name, size):
        """return the path of a named icon of a size in the hicolor theme"""
        return os.path.join(self.icons, f"{size}x{size}", "apps", f"{name}.png")


PULL_CHUNK_BYTES = 8 << 20


class HostBackend:
    """command backend for the sandbox"""

    poll_s = 1.5

    def __init__(self, local, init_pid):
        """store whether to run locally and the sandbox's init pid"""
        self.local = local
        self.init_pid = init_pid
        self._aapt2 = None
        self._mode = None

    def aapt2(self):
        """return the aapt2 path, found on the first call"""
        if self._aapt2 is None:
            self._aapt2 = find_aapt2()
        return self._aapt2

    def host_run(self, cmd, timeout=30):
        """run a command on the host and return its status and combined output"""
        if self.local:
            full = ["/bin/sh", "-c", cmd]
        else:
            full = ["ssh"] + ssh_opts() + ["-p", SSH_PORT, SSH_TARGET, cmd]
        r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")

    def host_sh(self, cmd, timeout=30):
        """run a command on the host"""
        return self.host_run(cmd, timeout)[1]

    def selinux_mode(self):
        """return the SELinux mode of the command host"""
        if self._mode is None:
            self._mode = self._read_mode()
        return self._mode

    def _read_mode(self):
        """read the SELinux mode"""
        if self.local:
            return read_selinux_mode()
        path = shlex.quote(SELINUX_MODE_FILE)
        helper = f"{shlex.quote(SELINUX_MODE_HELPER)} --env-file {shlex.quote(ANDROIDD_ENV)} --configured"
        cmd = (f"m=; if [ -e {path} ]; then m=$(cat {path}) || exit 1; fi; "
               f"if [ -z \"$m\" ]; then {helper}; else echo \"$m\"; fi")
        rc, out = self.host_run(cmd)
        if rc != 0 or out.strip() not in SELINUX_MODES:
            raise RuntimeError(f"reading the guest's SELinux mode failed: {cmd!r} exited {rc}, output {out[:200]!r}")
        return out.strip()

    def android_sh(self, cmd, timeout=30):
        """run a command inside the sandbox"""
        if self.selinux_mode() == "namespace":
            return self.probe_sh(cmd, timeout)
        body = f"export PATH=/system/bin:/system/xbin:/vendor/bin; {cmd}"
        DONE = "RHIZO_SH_DONE="
        wrapped = (
            f"nsenter -a -t {self.init_pid} -- /system/bin/toybox runcon u:r:shell:s0 "
            f"/system/bin/sh -c '{body}; echo {DONE}$?'"
        )
        out = self.host_sh(wrapped, timeout=timeout)
        if out and DONE in out:
            return out[: out.rindex(DONE)].rstrip("\n")
        return self.probe_sh(cmd, timeout)

    def probe_sh(self, cmd, timeout=30):
        """run a command inside the sandbox through rhizo-probed"""
        body = f"export PATH=/system/bin:/system/xbin:/vendor/bin; {cmd}"
        escaped = body.replace("'", "'\\''")
        client = self.probe_client()
        probe_wrapped = f"{client} {PROBE_SOCK} {timeout} '{escaped}'"
        return self.host_sh(probe_wrapped, timeout=timeout + 5)

    def probe_client(self):
        """return the rhizo-probe-client path"""
        if getattr(self, "_probe_client", None):
            return self._probe_client
        tests = " || ".join(f'[ -r {p} ] && echo {p}' for p in PROBE_CLIENT_GUEST_CANDIDATES)
        found = (self.host_sh(f"{tests} || true", timeout=15) or "").strip().split("\n")[0].strip()
        if not found:
            raise RuntimeError(
                "no rhizo-probe-client on the guest; tried "
                + ", ".join(PROBE_CLIENT_GUEST_CANDIDATES))
        self._probe_client = found
        return found

    def pull_via_shell(self, sandbox_path, local_path, timeout=60):
        """copy a sandbox file through the shell"""
        size_out = self.android_sh(f"stat -c %s {sandbox_path}", timeout=timeout).strip()
        if not size_out.isdigit():
            return False, f"could not read the size of {sandbox_path!r}: {size_out[:200]!r}"
        size = int(size_out)
        parts = []
        for index in range(-(-size // PULL_CHUNK_BYTES)):
            want = min(PULL_CHUNK_BYTES, size - index * PULL_CHUNK_BYTES)
            out = self.android_sh(
                f"dd if={sandbox_path} bs={PULL_CHUNK_BYTES} skip={index} count=1 2>/dev/null | base64",
                timeout=timeout)
            if not out or out.startswith("nsenter: failed to execute"):
                return False, (f"android_sh produced no usable output for {sandbox_path!r} "
                               f"chunk {index}: {out[:200]!r}")
            try:
                chunk = base64.b64decode("".join(out.split()), validate=True)
            except (binascii.Error, ValueError):
                return False, (
                    f"base64 output for {sandbox_path!r} chunk {index} was not valid base64 "
                    f"({len(out)} char(s) received, decoding to ~{len(out) * 3 // 4} "
                    f"byte(s)); the text starts {out[:120]!r}")
            if len(chunk) != want:
                return False, (f"chunk {index} of {sandbox_path!r} decoded to {len(chunk)} byte(s), "
                               f"{want} expected -- the transfer was cut short")
            parts.append(chunk)
        data = b"".join(parts)
        if len(data) < 1024 or data[:2] != b"PK":
            return False, f"decoded {len(data)} byte(s) for {sandbox_path!r}, does not look like an APK (starts {data[:16]!r})"
        with open(local_path, "wb") as f:
            f.write(data)
        return True, None

    def pull(self, guest_path, local_path, timeout=60, sandbox_path=None):
        """copy a guest file to a local path"""
        if self.local:
            try:
                shutil.copyfile(guest_path, local_path)
                return True, None
            except OSError as e:
                copy_err = str(e)
            if self.init_pid is not None:
                return self.pull_via_shell(sandbox_path or guest_path, local_path, timeout=timeout)
            return False, f"shutil.copyfile({guest_path!r}) failed ({copy_err}) and no init_pid for the android_sh fallback"
        _gsi_root = GSI_GUEST.rstrip("/") + "/"
        if sandbox_path and self.init_pid is not None and not guest_path.startswith(_gsi_root):
            return self.pull_via_shell(sandbox_path, local_path, timeout=timeout)
        full = ["scp", "-q"] + ssh_opts() + ["-P", SSH_PORT,
                                             f"{SSH_TARGET}:{guest_path}", local_path]
        r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
        if r.returncode == 0:
            return True, None
        return False, f"scp {guest_path!r} exit {r.returncode}: {r.stderr.strip()[:200]}"

    def push(self, local_path, guest_path, timeout=60):
        """copy a local file to the guest"""
        if self.local:
            try:
                shutil.copyfile(local_path, guest_path)
                shutil.copymode(local_path, guest_path)
                return True
            except OSError as e:
                log(f"  copy to {guest_path} failed: {e}")
                return False
        full = ["scp", "-q"] + ssh_opts() + ["-P", SSH_PORT, local_path,
                                             f"{SSH_TARGET}:{guest_path}"]
        r = subprocess.run(full, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0

    def push_batch(self, items, work, timeout=180):
        """write several files to the guest"""
        if not items:
            return []
        dirs = sorted({os.path.dirname(p) for p, _ in items})
        if self.local:
            for d in dirs:
                os.makedirs(d, exist_ok=True)
            return [p for i, (p, data) in enumerate(items)
                    if put_file(self, work, f"{i}-{os.path.basename(p)}", data, p)]
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tf:
            for path, data in items:
                info = tarfile.TarInfo(os.path.relpath(path, "/"))
                info.size = len(data)
                info.mode = 0o644
                tf.addfile(info, io.BytesIO(data))
        cmd = (f"mkdir -p {' '.join(shlex.quote(d) for d in dirs)} && "
               f"base64 -d | tar -x --no-same-owner --no-same-permissions -C / -f - "
               f"&& echo {PUSH_BATCH_OK}")
        full = ["ssh"] + ssh_opts() + ["-p", SSH_PORT, SSH_TARGET, cmd]
        r = subprocess.run(full, input=base64.b64encode(buf.getvalue()),
                           capture_output=True, timeout=timeout)
        out = ((r.stdout or b"") + (r.stderr or b"")).decode("utf-8", "replace")
        if PUSH_BATCH_OK not in out:
            log(f"  FAIL: writing {len(items)} file(s) under {dirs} exited "
                f"{r.returncode}: {' '.join(out.split())[:200] or '<no output>'}")
            return []
        return [p for p, _ in items]

    def badging(self, local_apk):
        """run aapt2 dump badging on the APK"""
        try:
            proc = subprocess.run([self.aapt2(), "dump", "badging", local_apk],
                                  capture_output=True, text=True, timeout=30)
        except subprocess.SubprocessError as e:
            return 127, "", f"aapt2 dump badging failed: {e}"
        return proc.returncode, proc.stdout, proc.stderr

    def refresh_desktop_db(self, app_dir):
        """rebuild mimeinfo.cache with update-desktop-database"""
        q = shlex.quote(app_dir)
        out = self.host_sh(
            f"if command -v update-desktop-database >/dev/null; then "
            f"update-desktop-database {q}; echo RHIZO_UDD_RC=$?; "
            f"else echo RHIZO_UDD_MISSING; fi")
        if "RHIZO_UDD_MISSING" in out:
            return False, ("update-desktop-database is not installed -- "
                           "desktop-file-utils is a Depends of the rhizo package")
        rc = _extract_rc_marker(out, "RHIZO_UDD_RC=")
        if rc != "0":
            return False, f"update-desktop-database exited {rc}: {' '.join(out.split())[:200]}"
        return True, f"update-desktop-database rebuilt mimeinfo.cache in {app_dir}"

    def bump_icon_theme(self, theme_root):
        """bump the icon theme directory mtime"""
        q = shlex.quote(theme_root)
        if self.local:
            os.utime(theme_root, None)
        else:
            self.host_sh(f"touch {q}")
        out = self.host_sh(
            f"if command -v gtk-update-icon-cache >/dev/null; then "
            f"gtk-update-icon-cache -f -t {q}; echo RHIZO_GUIC_RC=$?; "
            f"else echo RHIZO_GUIC_ABSENT; fi")
        if "RHIZO_GUIC_ABSENT" in out:
            return f"bumped {theme_root}; no gtk-update-icon-cache here"
        rc = _extract_rc_marker(out, "RHIZO_GUIC_RC=")
        if rc != "0":
            return f"bumped {theme_root}; FAIL: gtk-update-icon-cache exited {rc}: {' '.join(out.split())[:200]}"
        return f"bumped {theme_root} and refreshed its gtk icon cache"


def verdict_code(aapt2=None):
    """hash this file with aapt2 and ICON_GEN"""
    h = hashlib.sha256()
    for part in (os.path.abspath(__file__), aapt2, ICON_GEN):
        h.update(b"\0" + (part or "").encode() + b"\0")
        try:
            with open(part, "rb") as fh:
                h.update(hashlib.sha256(fh.read()).digest())
        except (OSError, TypeError):
            h.update(b"absent")
    return h.hexdigest()[:16]


def load_cache(path, fingerprint, prefix, code=None):
    """read the verdict cache file"""
    code = verdict_code() if code is None else code
    try:
        with open(path) as fh:
            c = json.load(fh)
        if not isinstance(c.get("entries"), dict):
            log(f"cache at {path} has no entries object: starting empty")
        elif c.get("fingerprint") != fingerprint:
            log(f"cache at {path} is for fingerprint {c.get('fingerprint')!r}, "
                f"not {fingerprint!r}: starting empty")
        elif c.get("code") != code:
            log(f"cache at {path} holds verdicts from appsync.py {c.get('code')!r}, "
                f"not {code!r}: starting empty")
        elif c.get("prefix") != prefix:
            log(f"cache at {path} was written for prefix {c.get('prefix')!r}, "
                f"not {prefix!r}: starting empty")
        else:
            return c["entries"]
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as e:
        log(f"cache at {path} unreadable ({e}): starting empty")
    return {}


def save_cache(path, fingerprint, prefix, entries, code=None):
    """write the cache json"""
    code = verdict_code() if code is None else code
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump({"fingerprint": fingerprint, "code": code, "prefix": prefix, "entries": entries}, fh)
    os.replace(tmp, path)


def brief_components(raw):
    """return the pkg/activity pairs from query-activities output"""
    pairs = []
    for line in raw.splitlines():
        line = line.strip()
        if "/" not in line or line.startswith(("Activity #", "package:", "priority=")):
            continue
        pkg, sep, act = line.partition("/")
        if sep and pkg and act and " " not in line:
            pairs.append((pkg, act))
    return pairs


def disabled_activities(be, pkg):
    """return the disabled activities of a package"""
    out = be.android_sh(f"dumpsys package {pkg}")
    disabled = set()
    in_block = False
    for line in out.splitlines():
        if line.strip() == "disabledComponents:":
            in_block = True
            continue
        if in_block:
            s = line.strip()
            if not s.startswith(pkg):
                break
            disabled.add(s)
    return disabled


def settled_query_activities_raw(be, deadline_s=180, stable_rounds_needed=2):
    """return the settled query-activities output"""
    start = time.monotonic()
    prev_pkgs = None
    prev_missing = None
    raw = be.android_sh(QUERY_ACTIVITIES_CMD)
    stable_rounds = 0
    while time.monotonic() - start < deadline_s:
        third_party = be.android_sh("pm list packages -3")
        pkgs = {
            line.strip()[len("package:"):]
            for line in third_party.splitlines()
            if line.strip().startswith("package:")
        }
        raw = be.android_sh(QUERY_ACTIVITIES_CMD)
        if "Failure calling service" in raw or "Can't find service" in raw:
            log(f"  query-activities returned a service error ({raw.strip()!r}) -- re-checking")
            stable_rounds = 0
            prev_pkgs = pkgs
            prev_missing = None
            time.sleep(be.poll_s)
            continue
        missing = sorted(p for p in pkgs if f"{p}/" not in raw)
        if pkgs == prev_pkgs and missing == prev_missing:
            stable_rounds += 1
            if stable_rounds >= stable_rounds_needed:
                if missing:
                    log(f"  {len(missing)} third-party package(s) never appear in query-activities ({missing}) "
                        f"-- no launchable activity")
                return raw, True
        else:
            if stable_rounds:
                log("  third-party package set or its query-activities reflection changed again -- resetting the stability count")
            stable_rounds = 0
            if missing != prev_missing:
                log(f"  {len(missing)} third-party package(s) not yet reflected in live query-activities ({missing}) -- re-checking")
            elif pkgs != prev_pkgs:
                log(f"  third-party package set changed since the last read ({sorted(prev_pkgs or [])} -> {sorted(pkgs)}) -- re-checking")
        prev_pkgs = pkgs
        prev_missing = missing
        time.sleep(be.poll_s)
    log(f"  settle deadline ({deadline_s}s) reached without {stable_rounds_needed} consecutive stable reads -- proceeding with the last one, deleting nothing")
    return raw, False


def enumerate_launchable(be):
    """return the launchable activities of installed packages"""
    raw, settled = settled_query_activities_raw(be)
    pairs = brief_components(raw)
    by_pkg = {}
    for pkg, act in pairs:
        by_pkg.setdefault(pkg, disabled_activities(be, pkg))
    filtered = []
    for pkg, act in pairs:
        fq = pkg + act if act.startswith(".") else act
        if fq in by_pkg[pkg]:
            log(f"  drop {pkg}/{act}: in {pkg}'s own disabledComponents ({fq})")
            continue
        filtered.append((pkg, act))
    return filtered, raw, settled


def pm_list(be, flag):
    """return package names for a pm list flag"""
    raw = be.android_sh(("pm list packages " + flag).strip())
    if "Failure calling service" in raw or "Can't find service" in raw:
        log(f"  'pm list packages {flag}' returned a service error ({raw.strip()!r})")
        return None
    return {line.strip()[len("package:"):] for line in raw.splitlines()
            if line.strip().startswith("package:")}


def installed_packages(be):
    """return all packages and the third-party packages"""
    every = pm_list(be, "")
    if not every:
        log("  'pm list packages' named no packages -- treating the read as failed")
        return None, None
    third = pm_list(be, "-3")
    if third is None:
        return None, None
    return every, third


def query_handlers(be, probe_args):
    """return the packages for an intent"""
    raw = be.android_sh("cmd package query-activities --brief " + probe_args)
    return {pkg for pkg, _ in brief_components(raw)}


def resolve_winner(be, probe_args, label):
    """return the default package for an intent"""
    raw = be.android_sh("cmd package resolve-activity --brief " + probe_args)
    for line in raw.splitlines():
        line = line.strip()
        if not COMPONENT_RE.match(line):
            continue
        if CHOOSER_RE.search(line):
            log(f"  {label}: the resolver answers with a chooser ({line}) -- no default written")
            return None
        return line.split("/", 1)[0]
    return None


def scheme_probe_args(scheme):
    """return the am arguments that resolve a VIEW of a browsable scheme"""
    return (f"-a android.intent.action.VIEW "
            f"-c android.intent.category.BROWSABLE -d '{scheme}:'")


def mime_probe_args(mime):
    """return the am arguments that resolve a VIEW of a mime type"""
    return f"-a android.intent.action.VIEW -t {mime} -d '{MIME_PROBE_URI}'"


def desktop_value(text):
    """escape a value for a desktop entry"""
    return text.replace("\\", "\\\\").replace("\r", " ").replace("\n", " ")


def desktop_entry_text(label, icon_name, pkg, act, mime_types, third_party):
    """return the .desktop text for an app"""
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        f"Name={desktop_value(label)}",
        f"Icon={icon_name}",
        f"Exec=rhizo launch {pkg} %u",
        f"StartupWMClass=rhizo-{pkg}",
        "StartupNotify=true",
    ]
    if mime_types:
        lines.append("MimeType=" + "".join(f"{m};" for m in mime_types))
    lines += [
        f"X-Rhizo-Package={pkg}",
        f"X-Rhizo-Activity={act}",
        "Categories=X-Rhizo;",
        "NoDisplay=" + ("false" if act else "true"),
    ]
    if third_party:
        lines += ["Actions=Uninstall;", "",
                  "[Desktop Action Uninstall]",
                  "Name=Uninstall",
                  f"Exec=rhizo app remove {pkg}"]
    return "\n".join(lines) + "\n"


def host_defaults(winners, synthesized, policy, log):
    """return the .apk default and each resolver winner's entry"""
    defaults = {APK_MIME: APK_HANDLER}
    if not policy.allows("desktop.default_handler"):
        if winners:
            log(f"  desktop.default_handler is off: {len(winners)} resolver "
                f"winner(s) claim no host default")
        return defaults
    for key in sorted(winners):
        winner = winners[key]
        if winner in synthesized:
            defaults[key] = f"rhizo-{winner}.desktop"
        else:
            log(f"  {key}: resolver winner {winner} has no synthesized entry -- no default written")
    return {k: defaults[k] for k in sorted(defaults)}


def merge_mimeapps(existing_text, defaults, ours=()):
    """merge defaults into a mimeapps.list text"""
    lines = existing_text.splitlines() if existing_text else []
    out = []
    section = None
    handled = set()
    have_default_section = False

    def flush_missing():
        """append each default not yet written to the output lines"""
        for mt, desktop in defaults.items():
            if mt not in handled:
                out.append(f"{mt}={desktop}")
                handled.add(mt)

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if section == "Default Applications":
                flush_missing()
            section = stripped[1:-1]
            if section == "Default Applications":
                have_default_section = True
            out.append(line)
            continue
        if section == "Default Applications" and "=" in stripped and not stripped.startswith("#"):
            key, _, value = stripped.partition("=")
            key = key.strip()
            if key in defaults:
                out.append(f"{key}={defaults[key]}")
                handled.add(key)
                continue
            parts = [p.strip() for p in value.split(";") if p.strip()]
            rest = [p for p in parts if p not in ours]
            if len(rest) != len(parts):
                if rest:
                    out.append(f"{key}=" + ";".join(rest) + (";" if value.rstrip().endswith(";") else ""))
                continue
        out.append(line)

    if section == "Default Applications":
        flush_missing()
    if not have_default_section:
        if out and out[-1].strip():
            out.append("")
        out.append("[Default Applications]")
        flush_missing()

    return "\n".join(out) + "\n"


def strip_mimeapps_entries(text, desktop_names):
    """remove associations to the given desktop entries"""
    kept, dropped = [], []
    for line in text.splitlines():
        s = line.strip()
        if "=" in s and not s.startswith(("#", "[")):
            key, _, value = s.partition("=")
            parts = [p for p in value.split(";") if p.strip()]
            rest = [p for p in parts if p.strip() not in desktop_names]
            if len(rest) != len(parts):
                dropped.append(s)
                if rest:
                    kept.append(f"{key}=" + ";".join(rest) + ";")
                continue
        kept.append(line)
    return ("\n".join(kept) + "\n" if kept else ""), dropped


def png_square_size(data):
    """return the pixel size from a PNG header"""
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None, "not a PNG (no IHDR at byte 12)"
    width, height = struct.unpack(">II", data[16:24])
    if width != height:
        return None, f"{width}x{height} is not square"
    if width == 0:
        return None, "IHDR width is 0"
    return width, None


def hicolor_size(pixels):
    """return the largest standard icon size"""
    fit = [s for s in STANDARD_ICON_SIZES if s <= pixels]
    return max(fit) if fit else None


def density_of(name):
    """return the rank of the first density named in a file name, or 0"""
    for d, rank in DENSITY_RANK.items():
        if d in name:
            return rank
    return 0


def decode_png_rgba(data):
    """decode an 8-bit RGB or RGBA PNG"""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, idat, w, h, bpp = 8, b"", None, 0, 4
    while pos + 8 <= len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                return None
            bpp = 4 if ctype == 6 else 3
        elif tag == b"IDAT":
            idat += body
        pos += 12 + length
    if w is None:
        return None
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 0xFF
            elif f == 2:
                line[i] = (line[i] + b) & 0xFF
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 0xFF
        prev = line
        rows.append(bytes(line) if bpp == 4
                    else b"".join(bytes(line[i:i + 3]) + b"\xff" for i in range(0, stride, 3)))
    return w, h, rows


def fill_icon(data, fill=0.92):
    """scale an icon's visible content up to fill the square"""
    try:
        decoded = decode_png_rgba(data)
    except (zlib.error, struct.error, IndexError, ValueError):
        return data
    gen = icon_generator()
    if decoded is None or gen is None:
        return data
    w, h, rows = decoded
    if w != h:
        return data
    ys = [y for y, row in enumerate(rows) if any(row[4 * x + 3] > 8 for x in range(w))]
    xs = [x for x in range(w) if any(row[4 * x + 3] > 8 for row in rows)]
    if not xs or not ys:
        return data
    left, right, top, bottom = min(xs), max(xs) + 1, min(ys), max(ys) + 1
    side = max(right - left, bottom - top)
    if side >= fill * w:
        return data
    scale = side / (fill * w)
    cx, cy = (left + right) / 2.0, (top + bottom) / 2.0
    out = []
    for y in range(h):
        sy = int(cy + (y - h / 2.0 + 0.5) * scale)
        line = bytearray()
        for x in range(w):
            sx = int(cx + (x - w / 2.0 + 0.5) * scale)
            line += rows[sy][4 * sx:4 * sx + 4] if 0 <= sx < w and 0 <= sy < h else b"\x00\x00\x00\x00"
        out.append(bytes(line))
    return gen.encode_png(w, h, out)


ADAPTIVE_FALLBACK_BG = (26, 115, 232, 255)


def adaptive_layers(be, apk_path, badging_text):
    """return the layers of an adaptive launcher icon"""
    path = ""
    for line in badging_text.splitlines():
        if line.startswith("application:") and "icon='" in line:
            path = line.split("icon='", 1)[1].split("'", 1)[0]
    if not path.endswith(".xml"):
        return None
    try:
        tree = subprocess.run([be.aapt2(), "dump", "xmltree", "--file", path, apk_path],
                              capture_output=True, text=True, timeout=30).stdout
        res = subprocess.run([be.aapt2(), "dump", "resources", apk_path],
                             capture_output=True, text=True, timeout=60).stdout
    except (OSError, TypeError, subprocess.SubprocessError):
        return None
    if "E: adaptive-icon" not in tree:
        return None
    refs = {}
    for layer in ("background", "foreground"):
        m = re.search(r"E: %s.*?drawable\(0x01010199\)=@0x([0-9a-f]{8})" % layer, tree, re.S)
        if not m:
            return None
        refs[layer] = m.group(1)
    bg = re.search(r"resource 0x%s color/\S+\n\s+\(\) (#[0-9a-f]{8}|@0x[0-9a-f]{8})" % refs["background"], res)
    if not bg:
        return None
    v = bg.group(1)
    color = ADAPTIVE_FALLBACK_BG if v.startswith("@") else tuple(int(v[i:i + 2], 16) for i in (3, 5, 7, 1))
    block = re.search(r"resource 0x%s \S+\n((?:\s+\(.*\n)+)" % refs["foreground"], res)
    if not block:
        return None
    pngs = re.findall(r"\(file\) (\S+\.png) type=PNG", block.group(1))
    if not pngs:
        return None
    with zipfile.ZipFile(apk_path) as z:
        return color, [(n, z.read(n)) for n in pngs]


def compose_adaptive(fg_data, bg):
    """draw an adaptive icon as the android launcher shows it"""
    try:
        decoded = decode_png_rgba(fg_data)
    except (zlib.error, struct.error, IndexError, ValueError):
        return None
    gen = icon_generator()
    if decoded is None or gen is None or decoded[0] != decoded[1]:
        return None
    n, _, rows = decoded
    r, inset, span = n / 2.0, 18.0 / 108.0, 72.0 / 108.0
    out = []
    for y in range(n):
        line = bytearray()
        for x in range(n):
            cov = max(0.0, min(1.0, r - math.hypot(x + 0.5 - r, y + 0.5 - r) + 0.5))
            if cov <= 0.0:
                line += b"\x00\x00\x00\x00"
                continue
            sx = min(n - 1, int((inset + (x + 0.5) / n * span) * n))
            sy = min(n - 1, int((inset + (y + 0.5) / n * span) * n))
            fr, fg, fb, fa = rows[sy][4 * sx:4 * sx + 4]
            a = fa / 255.0
            line += bytes((round(fr * a + bg[0] * (1 - a)), round(fg * a + bg[1] * (1 - a)),
                           round(fb * a + bg[2] * (1 - a)), round(255 * cov)))
        out.append(bytes(line))
    return gen.encode_png(n, n, out)


def collect_icon_rasters(apk_path, badging_text):
    """return the APK icon PNGs per size"""
    icon_lines = []
    for line in badging_text.splitlines():
        if line.startswith("application-icon-"):
            try:
                dpi = int(line.split("application-icon-", 1)[1].split(":", 1)[0])
            except ValueError:
                continue
            path = line.split(":", 1)[1].strip().strip("'")
            icon_lines.append((dpi, path))
    icon_lines.sort(reverse=True)

    if not icon_lines:
        for line in badging_text.splitlines():
            if line.startswith("application:") and "icon='" in line:
                path = line.split("icon='", 1)[1].split("'", 1)[0]
                if path:
                    icon_lines = [(0, path)]
        if not icon_lines:
            return {}, ["no application-icon line in badging output"]

    notes = []
    chosen = {}
    with zipfile.ZipFile(apk_path) as z:
        names = set(z.namelist())
        candidates = []
        for dpi, path in icon_lines:
            if path.endswith(".png") and path in names:
                candidates.append(path)
                continue
            base = os.path.splitext(os.path.basename(path))[0]
            same_base = sorted(n for n in names
                               if n.endswith(f"/{base}.png") and ("mipmap" in n or "drawable" in n))
            if not same_base:
                notes.append(f"'{path}' has no raster form in this APK")
            candidates.extend(same_base)

        seen = set()
        for name in candidates:
            if name in seen:
                continue
            seen.add(name)
            data = fill_icon(z.read(name))
            pixels, why = png_square_size(data)
            if pixels is None:
                notes.append(f"refused {name}: {why}")
                continue
            size = hicolor_size(pixels)
            if size is None:
                notes.append(f"refused {name}: {pixels}px is below the smallest theme size")
                continue
            rank = (density_of(name), pixels)
            if size in chosen and chosen[size][0] >= rank:
                continue
            chosen[size] = (rank, data, name)

    if chosen:
        notes.insert(0, "; ".join(f"{s}x{s} from {chosen[s][2]}" for s in sorted(chosen)))
    return {s: (data, name) for s, (_, data, name) in chosen.items()}, notes


@contextlib.contextmanager
def mimeapps_lock(be, dest):
    """lock the applications directory with flock"""
    if not be.local or not os.path.isdir(dest.applications):
        yield
        return
    fd = os.open(dest.applications, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def load_claims(path, prefix):
    """return the recorded mimeapps claims for a prefix"""
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (FileNotFoundError, ValueError, OSError):
        return {}
    if not isinstance(data, dict) or data.get("prefix") != prefix:
        return {}
    claims = data.get("claims")
    return claims if isinstance(claims, dict) else {}


def save_claims(path, prefix, claims):
    """write the claims json"""
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump({"prefix": prefix, "claims": claims}, fh, indent=1, sort_keys=True)
    os.replace(tmp, path)


def write_defaults(be, dest, work, defaults, ours, claims_path, probed_at):
    """merge defaults into mimeapps.list"""
    with mimeapps_lock(be, dest):
        claims = load_claims(claims_path, dest.prefix)
        newer = {k: c["desktop"] for k, c in claims.items()
                 if isinstance(c, dict) and c.get("t", 0) > probed_at
                 and k in defaults and c.get("desktop") != defaults[k]}
        for k, v in sorted(newer.items()):
            log(f"  {k}: {v} was claimed from a newer resolver read than this pass's -- left as it is")
        mine = {k: v for k, v in defaults.items() if k not in newer}
        existing, read_ok = read_mimeapps(be, dest)
        if not read_ok:
            return False
        keep_ours = set(ours) - set(newer.values())
        if not write_mimeapps(be, dest, work, merge_mimeapps(existing, mine, keep_ours)):
            log(f"  FAIL: could not write {dest.mimeapps}")
            return False
        for k, v in mine.items():
            claims[k] = {"desktop": v, "t": probed_at}
        try:
            save_claims(claims_path, dest.prefix, claims)
        except OSError as e:
            log(f"  FAIL: could not record the defaults this pass claimed in {claims_path}: {e}")
            return False
    log(f"  {dest.mimeapps} defaults: {mine}")
    return True


def read_mimeapps(be, dest):
    """read mimeapps.list and create its directory"""
    q = shlex.quote(dest.mimeapps)
    out = be.host_sh(f"mkdir -p {shlex.quote(dest.applications)}; "
                     f"if [ -f {q} ]; then printf RHIZO_MIMEAPPS_BEGIN; cat {q}; "
                     f"else printf RHIZO_MIMEAPPS_ABSENT; fi")
    if "RHIZO_MIMEAPPS_BEGIN" in out:
        return out.split("RHIZO_MIMEAPPS_BEGIN", 1)[1], True
    if "RHIZO_MIMEAPPS_ABSENT" in out:
        return "", True
    log(f"  FAIL: reading {dest.mimeapps} produced no marker, so this is not its content: {out[:200]!r}")
    return "", False


def put_file(be, work, name, data, guest_path):
    """write bytes to a file and push it"""
    local = os.path.join(work, name)
    with open(local, "wb") as fh:
        fh.write(data)
    os.chmod(local, 0o644)
    return be.push(local, guest_path)


def write_mimeapps(be, dest, work, text):
    """push a mimeapps.list text to the destination"""
    return put_file(be, work, "mimeapps.list", text.encode(), dest.mimeapps)


def ensure_generic_icon(be, dest, work):
    """write the generic icon file"""
    target = dest.icon(GENERIC_ICON, GENERIC_ICON_SIZE)
    probe = be.host_sh(f"mkdir -p {shlex.quote(os.path.dirname(target))}; "
                       f"if [ -f {shlex.quote(target)} ]; then echo RHIZO_ICON_PRESENT; fi")
    if "RHIZO_ICON_PRESENT" in probe:
        return True
    gen = icon_generator()
    if gen is None:
        log(f"  FAIL: {target} is gone and there is no {ICON_GEN} beside this script to "
            f"write it")
        return False
    if put_file(be, work, "rhizo.png", gen.mark_png(), target):
        log(f"  wrote the generic icon {target}")
        return True
    log(f"  FAIL: could not write the generic icon {target}")
    return False


def seed_apk_default(be, dest, work):
    """write the .apk default into mimeapps.list"""
    existing, ok = read_mimeapps(be, dest)
    if not ok:
        return False
    text = merge_mimeapps(existing, {APK_MIME: APK_HANDLER})
    if write_mimeapps(be, dest, work, text):
        log(f"  {dest.mimeapps}: {APK_MIME}={APK_HANDLER}")
        return True
    log(f"  FAIL: could not write {dest.mimeapps}")
    return False


def reconcile_only(be, dest):
    """remove entries of packages the device lacks"""
    every, _ = installed_packages(be)
    if every is None:
        log("reconcile-only: the package list could not be read -- nothing removed")
        return 0
    with tempfile.TemporaryDirectory() as work:
        removed = reconcile_entries(be, dest, every, True, work)
    if removed:
        ok, detail = be.refresh_desktop_db(dest.applications)
        log("  " + detail if detail else "  desktop database refreshed")
        log("  " + be.bump_icon_theme(dest.icons))
        if not ok:
            return 1
    log("reconcile-only: %d package(s) removed" % len(removed))
    return 0


def reconcile_entries(be, dest, live_pkgs, settled, work):
    """remove entries of packages missing from the device"""
    if not settled:
        log("  enumeration never settled -- nothing removed")
        return []
    if not live_pkgs:
        log("  no live package list -- nothing removed")
        return []
    listing = be.host_sh(
        f"for f in {shlex.quote(dest.applications)}/rhizo-*.desktop; do "
        "[ -f \"$f\" ] || continue; "
        "printf '%s\\t%s\\n' \"$f\" \"$(sed -n 's/^X-Rhizo-Package=//p' \"$f\" | head -1)\"; "
        "done")
    gone_pkgs, unmarked = {}, 0
    for line in listing.splitlines():
        path, tab, pkg = line.partition("\t")
        if not tab or not path.endswith(".desktop"):
            continue
        pkg = pkg.strip()
        if not pkg:
            unmarked += 1
            continue
        if not PKG_RE.match(pkg):
            log(f"  {path}: X-Rhizo-Package={pkg!r} is not a package name -- left alone")
            continue
        if pkg not in live_pkgs or pkg in HIDDEN_PACKAGES:
            gone_pkgs[pkg] = path
    if unmarked:
        log(f"  {unmarked} rhizo-*.desktop file(s) carry no X-Rhizo-Package= -- not ours, left alone")
    if not gone_pkgs:
        return []

    globs = " ".join(f"{shlex.quote(path)} {shlex.quote(dest.icons)}/*/apps/rhizo-{pkg}.png"
                     for pkg, path in sorted(gone_pkgs.items()))
    gone = be.host_sh(f"for f in {globs}; do [ -f \"$f\" ] || continue; "
                      "rm -f \"$f\" && printf '%s\\n' \"$f\"; done")
    for path in gone.splitlines():
        if path.strip():
            log(f"  removed {path.strip()}")

    names = {f"rhizo-{pkg}.desktop" for pkg in gone_pkgs}
    with mimeapps_lock(be, dest):
        existing, ok = read_mimeapps(be, dest)
        if not ok:
            log(f"  FAIL: {sorted(names)} still named in {dest.mimeapps}, which could not be read")
            return sorted(gone_pkgs)
        text, dropped = strip_mimeapps_entries(existing, names)
        if dropped:
            if write_mimeapps(be, dest, work, text):
                for line in dropped:
                    log(f"  removed {dest.mimeapps} line {line!r}")
            else:
                log(f"  FAIL: could not rewrite {dest.mimeapps} without {sorted(names)}")
    return sorted(gone_pkgs)


def resolve_apk_all(be):
    """return the APK path of every installed package"""
    out = {}
    raw = be.android_sh("pm list packages -f")
    for line in raw.splitlines():
        line = line.strip()
        if not line.startswith("package:") or "=" not in line:
            continue
        body = line[len("package:"):]
        path, _, pkg = body.rpartition("=")
        if path and pkg:
            out[pkg] = path
    return out


def resolve_apk(be, pkg):
    """return the device path of a package's APK"""
    raw = be.android_sh(f"pm path {pkg}")
    for _ in range(5):
        if "Can't find service: package" not in raw:
            break
        time.sleep(1)
        raw = be.android_sh(f"pm path {pkg}")
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("package:"):
            return line[len("package:"):], None
    return None, f"pm path returned no APK path ({raw.strip()!r})"


def apk_candidates(devpath):
    """return the candidate paths of an APK"""
    candidates = []
    if devpath.startswith("/data/"):
        candidates.append(DATA_GUEST + devpath[len("/data"):])
    candidates.append(GSI_GUEST + devpath)
    if devpath.startswith("/system/"):
        candidates.append(GSI_GUEST + devpath[len("/system"):])
    return candidates


APPLICATION_LABEL_RE = re.compile(r"^application: label='(.*)' icon='[^']*'")


def badging_label(badging):
    """return the app label from badging output"""
    for line in badging.splitlines():
        if line.startswith("application-label:"):
            return line.split("application-label:", 1)[1].strip().strip("'")
    for line in badging.splitlines():
        m = APPLICATION_LABEL_RE.match(line)
        if m and m.group(1):
            return m.group(1)
    return None


def probe_mime_associations(be):
    """query the resolver for every probed type"""
    handlers, winners = {}, {}
    for scheme in SCHEME_PROBES:
        key = f"x-scheme-handler/{scheme}"
        handlers[key] = query_handlers(be, scheme_probe_args(scheme))
        winner = resolve_winner(be, scheme_probe_args(scheme), scheme)
        if winner:
            winners[key] = winner
        elif not handlers[key]:
            log(f"  {scheme}: no Android app resolves this scheme")
    for mime in MIME_PROBES:
        handlers[mime] = query_handlers(be, mime_probe_args(mime))
        winner = resolve_winner(be, mime_probe_args(mime), mime)
        if winner:
            winners[mime] = winner
        elif not handlers[mime]:
            log(f"  {mime}: no Android app resolves this type")
    log(f"  resolver named handlers for {sorted(k for k, v in handlers.items() if v)}")
    return handlers, winners


def mime_types_for(pkg, handlers):
    """return the MimeType list for a package"""
    schemes = sorted(k for k, v in handlers.items()
                     if k.startswith("x-scheme-handler/") and pkg in v)
    content = sorted(k for k, v in handlers.items()
                     if not k.startswith("x-scheme-handler/") and pkg in v)
    return schemes + content


def synthesize_entry(be, dest, work, pkg, act, mime_types, is_third_party, devpath, cache):
    """write the desktop entry and icons"""
    cached = cache.get(pkg)
    if cached and cached.get("devpath") == devpath and cached.get("activity") == act:
        if cached.get("result") == "skip":
            log(f"  skip {pkg}: {cached.get('reason')} (cached verdict)")
            return None, True
        entry = cached.get("app") or {}
        wanted = [entry.get("desktop_guest_path", "")]
        wanted += [dest.icon(f"rhizo-{pkg}", s) for s in entry.get("icon_sizes", [])]
        probe = "".join(f"[ -e {shlex.quote(p)} ] && " for p in wanted if p)
        present = bool(wanted[0]) and "RHIZO_PRESENT" in be.host_sh(probe + "echo RHIZO_PRESENT")
        unchanged = (entry.get("mime_types") == mime_types
                     and entry.get("third_party") == is_third_party)
        if cached.get("result") == "ok" and present and unchanged:
            log(f"  reused rhizo-{pkg}.desktop (cached verdict, files present)")
            return entry, True

    local_apk = os.path.join(work, f"{pkg}.apk")
    guest_apk_path = None
    pull_fail_reasons = []
    for cand in apk_candidates(devpath):
        ok, reason = be.pull(cand, local_apk, sandbox_path=devpath)
        if ok:
            guest_apk_path = cand
            break
        pull_fail_reasons.append(f"{cand} -> {reason}")
    if guest_apk_path is None:
        log(f"  skip {pkg}: could not pull a valid APK: " + "; ".join(pull_fail_reasons))
        return None, False

    rc, badging, stderr = be.badging(local_apk)
    if rc != 0:
        try:
            st = os.stat(local_apk)
            with open(local_apk, "rb") as fh:
                magic = fh.read(4)
            shape = f"{st.st_size}B magic={magic!r}"
        except OSError as e:
            shape = f"unstattable: {e}"
        reason = (f"aapt2 dump badging exited {rc} on the pulled APK "
                  f"({shape}): {' '.join(stderr.split())[:300] or '<no stderr>'}")
        log(f"  skip {pkg}: {reason}")
        return None, False

    label = badging_label(badging)
    if not label:
        reason = (f"aapt2 exited 0 but its badging output carries no "
                  f"application-label: line ({len(badging.splitlines())} line(s) of badging)")
        log(f"  skip {pkg}: {reason}")
        cache[pkg] = {"devpath": devpath, "activity": act, "result": "skip", "reason": reason}
        return None, False

    rasters, icon_notes = collect_icon_rasters(local_apk, badging)
    layers = adaptive_layers(be, local_apk, badging)
    if layers:
        composed = {}
        for name, fg in layers[1]:
            out = compose_adaptive(fg, layers[0])
            px = png_square_size(out)[0] if out else None
            size = hicolor_size(px) if px else None
            if size and (size not in composed or px > composed[size][2]):
                composed[size] = (out, "adaptive " + name, px)
        if composed:
            rasters = {s: (out, name) for s, (out, name, _) in composed.items()}
            icon_notes.append("composited the adaptive icon at " + ", ".join(f"{s}x{s}" for s in sorted(composed)))
    icon_sizes = []
    if rasters:
        sizes = sorted(rasters)
        targets = [(dest.icon(f"rhizo-{pkg}", s), rasters[s][0]) for s in sizes]
        written = set(be.push_batch(targets, work))
        for size, (target, _) in zip(sizes, targets):
            if target in written:
                icon_sizes.append(size)
            else:
                icon_notes.append(
                    f"could not write {target} (from {rasters[size][1]})")
    icon_name = f"rhizo-{pkg}" if icon_sizes else GENERIC_ICON
    icon_note = "; ".join(icon_notes)

    text = desktop_entry_text(label, icon_name, pkg, act, mime_types, is_third_party)
    entry_path = dest.entry(pkg)
    if not put_file(be, work, f"rhizo-{pkg}.desktop", text.encode(), entry_path):
        log(f"  skip {pkg}: could not write {entry_path}")
        return None, False

    log(f"  synthesized {entry_path}: Name='{label}' Icon={icon_name} "
        f"mime={mime_types or 'none'} third_party={int(is_third_party)} "
        f"no_display={int(not act)} icons={icon_sizes or 'none'} ({icon_note})")

    entry = {
        "package": pkg,
        "activity": act,
        "label": label,
        "label_source": "aapt2 dump badging application-label",
        "apk_device_path": devpath,
        "apk_guest_path": guest_apk_path,
        "icon_name": icon_name,
        "icon_sizes": icon_sizes,
        "icon_guest_path": dest.icon(f"rhizo-{pkg}", max(icon_sizes)) if icon_sizes else "",
        "icon_note": icon_note,
        "desktop_guest_path": entry_path,
        "mime_types": mime_types,
        "third_party": is_third_party,
        "no_display": not act,
    }
    cache[pkg] = {"devpath": devpath, "activity": act, "result": "ok", "app": entry}
    return entry, False

def sync_apps(be, dest, manifest_path, min_apps, cache_path=CACHE_PATH, claims_path=CLAIMS_PATH):
    """write desktop entries for the installed packages"""
    log(f"using aapt2: {be.aapt2()} (local={be.local}) prefix={dest.prefix}")
    failures = 0

    fingerprint = be.android_sh("getprop ro.build.fingerprint").strip()
    code = verdict_code(be.aapt2())
    cache = load_cache(cache_path, fingerprint, dest.prefix, code=code) if fingerprint else {}
    cache_hits = 0
    log(f"fingerprint {fingerprint!r}: {len(cache)} cached package verdict(s)")

    pairs, raw, settled = enumerate_launchable(be)
    log(f"query-activities raw output:\n{raw}")
    pairs = [p for p in pairs if p[0] not in HIDDEN_PACKAGES]
    if not pairs:
        log("FAIL: no launchable pkg/activity pairs found on the live sandbox")
        return {}, False
    if not settled:
        log("FAIL: query-activities enumeration never settled -- synthesizing from a partial read")
        failures += 1
    log(f"found {len(pairs)} launchable activities: {pairs}")

    apk_paths = resolve_apk_all(be)
    log(f"  resolved {len(apk_paths)} APK path(s) in one pm list packages -f")

    every_pkg, third_party = installed_packages(be)
    probed_at = time.time()
    handlers, winners = probe_mime_associations(be)

    launchable = {pkg for pkg, _ in pairs}
    handler_only = set()
    for key, pkgs in handlers.items():
        for pkg in pkgs:
            if pkg in launchable or pkg in HIDDEN_PACKAGES:
                continue
            if every_pkg is not None and pkg not in every_pkg:
                log(f"  {key}: resolver named {pkg}, which pm does not list as installed -- no entry")
                continue
            handler_only.add(pkg)
    if handler_only:
        log(f"  handler-only packages (no launcher activity): {sorted(handler_only)}")
    targets = list(pairs) + [(pkg, "") for pkg in sorted(handler_only)]

    if third_party is None:
        log("  the installed-package read failed -- no Uninstall actions, nothing removed")

    apps = []
    with tempfile.TemporaryDirectory() as work:
        be.host_sh(f"mkdir -p {shlex.quote(dest.applications)}")
        for pkg, act in targets:
            mime_types = mime_types_for(pkg, handlers)
            is_third_party = bool(third_party) and pkg in third_party
            devpath = apk_paths.get(pkg)
            why = None
            if not devpath:
                devpath, why = resolve_apk(be, pkg)
            if not devpath:
                log(f"  skip {pkg}: {why}")
                continue

            entry, from_cache = synthesize_entry(be, dest, work, pkg, act, mime_types,
                                                 is_third_party, devpath, cache)
            cache_hits += 1 if from_cache else 0
            if entry is not None:
                apps.append(entry)

        failures += 0 if ensure_generic_icon(be, dest, work) else 1

        synthesized = {a["package"] for a in apps}
        defaults = host_defaults(winners, synthesized,
                                 capabilities.policy_or_deny(log=log), log)
        if not write_defaults(be, dest, work, defaults, {f"rhizo-{p}.desktop" for p in synthesized},
                              claims_path, probed_at):
            failures += 1

        live_now = installed_packages(be)[0] if every_pkg is not None else None
        removed = reconcile_entries(be, dest, live_now, settled, work)

        ok, detail = be.refresh_desktop_db(dest.applications)
        log(("  " if ok else "  FAIL: ") + detail)
        failures += 0 if ok else 1
        log("  " + be.bump_icon_theme(dest.icons))

    manifest = {
        "apps": apps,
        "query_activities_raw": raw,
        "settled": settled,
        "mimeapps_defaults": defaults,
        "removed": removed,
    }
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    log(f"wrote manifest: {manifest_path} ({len(apps)} app(s), {cache_hits} from cache, "
        f"{len(removed)} removed)")
    if fingerprint:
        try:
            save_cache(cache_path, fingerprint, dest.prefix, cache, code=code)
        except OSError as e:
            log(f"could not write {cache_path}: {e}")

    if len(apps) < min_apps:
        log(f"FAIL: only {len(apps)} .desktop entries synthesized, need >= {min_apps}")
        failures += 1
    return manifest, failures == 0


QUEUE_DIR_RE = re.compile(r"^[A-Za-z0-9~=_.+-]{1,255}$")
PACKAGE_MAP_DEADLINE_S = 60


def packages_for_dirs(be, dirs):
    """return the package for each queued directory"""
    found = {}
    for pkg, path in resolve_apk_all(be).items():
        if not PKG_RE.match(pkg) or not path.startswith("/data/app/"):
            continue
        top = path[len("/data/app/"):].split("/", 1)[0]
        if top in dirs:
            found[top] = pkg
    return found


def launcher_activities(be, pkg, deadline_s):
    """return the launcher activities of a package"""
    deadline = time.monotonic() + deadline_s
    while True:
        raw = be.android_sh(f"{QUERY_ACTIVITIES_CMD} {pkg}")
        pairs = [(p, a) for p, a in brief_components(raw) if p == pkg]
        if pairs or time.monotonic() >= deadline:
            break
        time.sleep(be.poll_s)
    disabled = disabled_activities(be, pkg) if pairs else set()
    return [(p, a) for p, a in pairs if (p + a if a.startswith(".") else a) not in disabled]


def sync_package(be, dest, pkg, deadline_s=PACKAGE_MAP_DEADLINE_S, claims_path=CLAIMS_PATH):
    """write the entry and defaults for a package"""
    every, third = installed_packages(be)
    if every is None or pkg not in every:
        log(f"  package {pkg}: pm does not list it installed -- nothing written")
        return False
    pairs = launcher_activities(be, pkg, deadline_s)
    probed_at = time.time()
    handlers, winners = probe_mime_associations(be)
    mime_types = mime_types_for(pkg, handlers)
    act = pairs[-1][1] if pairs else ""
    if not act and not mime_types:
        log(f"  package {pkg}: no launcher activity and no handled type -- no entry")
        return False
    devpath = resolve_apk_all(be).get(pkg)
    why = None
    if not devpath:
        devpath, why = resolve_apk(be, pkg)
    if not devpath:
        log(f"  skip {pkg}: {why}")
        return False
    with tempfile.TemporaryDirectory() as work:
        be.host_sh(f"mkdir -p {shlex.quote(dest.applications)}")
        entry, _ = synthesize_entry(be, dest, work, pkg, act, mime_types,
                                    bool(third) and pkg in third, devpath, {})
        if entry is None:
            return False
        ok = ensure_generic_icon(be, dest, work)
        own = {k: v for k, v in winners.items() if v == pkg}
        defaults = host_defaults(own, {pkg}, capabilities.policy_or_deny(log=log), log)
        if not write_defaults(be, dest, work, defaults, {f"rhizo-{pkg}.desktop"}, claims_path, probed_at):
            log(f"  FAIL: could not merge {pkg}'s defaults into {dest.mimeapps}")
            ok = False
        db_ok, detail = be.refresh_desktop_db(dest.applications)
        log(("  " if db_ok else "  FAIL: ") + detail)
        log("  " + be.bump_icon_theme(dest.icons))
    if not (ok and db_ok):
        log(f"package {pkg}: FAIL: entry {dest.entry(pkg)} written but its defaults or the desktop "
            f"database were not")
        return False
    log(f"package {pkg}: entry {dest.entry(pkg)} written, defaults {defaults}")
    return True


QUEUE_MAX_BYTES = 1 << 20


def read_queue(queue_path, offset):
    """read the complete lines past an offset"""
    try:
        fd = os.open(queue_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return [], 0
    except OSError as e:
        raise OSError(e.errno, f"refusing {queue_path}: {e.strerror} (a symlink reads ELOOP)") from e
    with os.fdopen(fd, "rb") as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_size > QUEUE_MAX_BYTES:
            raise OSError(errno.EINVAL, f"refusing {queue_path}: mode {st.st_mode:o}, "
                                        f"{st.st_size} bytes, want a regular file of at most {QUEUE_MAX_BYTES}")
        data = fh.read(QUEUE_MAX_BYTES)
    if len(data) < offset:
        offset = 0
    chunk = data[offset:]
    end = chunk.rfind(b"\n") + 1
    lines = [raw.decode("utf-8", "replace") for raw in chunk[:end].split(b"\n") if raw]
    return lines, offset + end


def drain_queue(be, dest, queue_path, state_path, alive, wait,
                map_deadline_s=PACKAGE_MAP_DEADLINE_S):
    """sync each package in the appwatch queue"""
    try:
        with open(state_path) as fh:
            offset = int(fh.read().strip() or 0)
    except (FileNotFoundError, ValueError):
        offset = 0
    pending, synced, ignored, failed = {}, [], [], []
    while True:
        lines, offset = read_queue(queue_path, offset)
        for name in lines:
            if not QUEUE_DIR_RE.match(name) or name in (".", ".."):
                log(f"queue: a {len(name)}-character line is not a /data/app entry name -- ignored")
                ignored.append(name)
            elif name not in pending:
                pending[name] = time.monotonic()
        if pending:
            for d, pkg in sorted(packages_for_dirs(be, set(pending)).items()):
                del pending[d]
                log(f"queue: {d} is {pkg}'s directory, per pm list packages -f")
                if sync_package(be, dest, pkg, map_deadline_s):
                    synced.append(pkg)
                else:
                    log(f"queue: FAIL: {pkg}'s entry was not written")
                    failed.append(pkg)
            for d, t0 in list(pending.items()):
                if time.monotonic() - t0 >= map_deadline_s:
                    log(f"queue: pm names no package under {d} after {map_deadline_s:.0f}s -- ignored")
                    ignored.append(d)
                    del pending[d]
        if not pending:
            with open(state_path + ".tmp", "w") as fh:
                fh.write(f"{offset}\n")
            os.replace(state_path + ".tmp", state_path)
            if not alive():
                more, _ = read_queue(queue_path, offset)
                if not more:
                    return synced, ignored, failed
                continue
        wait(be.poll_s if pending else 1.0)


def sleep_wait(s):
    """sleep s seconds"""
    time.sleep(s)


def pid_waiter(pid):
    """return poll and wait functions for a pid"""
    try:
        pidfd = os.pidfd_open(pid)
    except ProcessLookupError:
        return (lambda: False), sleep_wait

    def alive():
        """return whether the pid has not exited"""
        return not select.select([pidfd], [], [], 0)[0]

    def wait(s):
        """wait for the pid's exit or s seconds"""
        if alive():
            select.select([pidfd], [], [], s)
        else:
            sleep_wait(s)
    return alive, wait


def drain_waiter(while_pid):
    """return poll and wait functions for the drain's optional watched pid"""
    return pid_waiter(while_pid) if while_pid else ((lambda: False), sleep_wait)


FIXTURE_PACKAGES = {
    "com.fixture.alpha": {
        "label": "Alpha's Ball", "activity": ".MainActivity",
        "third_party": True, "apk": "raster",
    },
    "com.fixture.beta": {
        "label": "Beta Board", "activity": ".Main",
        "third_party": True, "apk": "raster",
    },
    "com.fixture.gamma": {
        "label": "Gamma Tools", "activity": ".Launch",
        "third_party": True, "apk": "vector",
    },
    "com.android.htmlviewer": {
        "label": "HTML Viewer", "activity": None,
        "third_party": False, "apk": "vector",
    },
    "com.fixture.contentonly": {
        "label": "Content Only", "activity": None,
        "third_party": False, "apk": "vector", "view_schemes": ("content",),
    },
}
FIXTURE_HANDLERS = {
    "x-scheme-handler/https": ["com.fixture.alpha"],
    "x-scheme-handler/rhizo-test": ["com.fixture.beta"],
    "text/plain": ["com.fixture.alpha", "com.fixture.gamma", "com.fixture.contentonly"],
    "text/html": ["com.android.htmlviewer"],
    "image/png": ["com.fixture.alpha"],
}
FIXTURE_WINNERS = {
    "x-scheme-handler/https": "com.fixture.alpha/.MainActivity",
    "x-scheme-handler/rhizo-test": "com.fixture.beta/.Main",
    "text/plain": "android/com.android.internal.app.ResolverActivity",
    "text/html": "com.android.htmlviewer/.HTMLViewerActivity",
    "image/png": "com.fixture.alpha/.MainActivity",
    "x-scheme-handler/mailto": "com.fixture.delta/.Compose",
}
FIXTURE_ICONS = {
    "res/mipmap-xxxhdpi-v4/ic.png": (192, (10, 20, 30, 255)),
    "res/mipmap-hdpi-v4/ic.png": (48, (40, 50, 60, 255)),
    "res/mipmap-mdpi-v4/ic.png": (48, (70, 80, 90, 255)),
}
FIXTURE_MIMEAPPS = """[Default Applications]
# a comment nothing may touch
text/csv=libreoffice-calc.desktop

[Added Associations]
image/png=eog.desktop;
"""


@functools.lru_cache(maxsize=2)
def fixture_apk(kind):
    """return a fixture APK zip"""
    gen = icon_generator()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("AndroidManifest.xml", b"\x03\x00\x08\x00fixture")
        z.writestr("resources.arsc", b"\x02\x00\x0c\x00fixture")
        if kind == "raster":
            for name, (size, rgba) in sorted(FIXTURE_ICONS.items()):
                z.writestr(name, gen.solid_png(size, rgba))
        else:
            z.writestr("res/mipmap-anydpi-v4/ic.xml", b"<adaptive-icon/>")
    return buf.getvalue()


def fixture_badging(pkg):
    """return the badging text for a fixture package"""
    spec = FIXTURE_PACKAGES[pkg]
    lines = [f"package: name='{pkg}' versionCode='1' versionName='1.0'",
             f"application-label:'{spec['label']}'"]
    if spec["apk"] == "raster":
        for name, dpi in (("res/mipmap-xxxhdpi-v4/ic.png", 640),
                          ("res/mipmap-hdpi-v4/ic.png", 240),
                          ("res/mipmap-mdpi-v4/ic.png", 65535)):
            lines.append(f"application-icon-{dpi}:'{name}'")
        top = "res/mipmap-xxxhdpi-v4/ic.png"
    else:
        lines.append("application-icon-65534:'res/mipmap-anydpi-v4/ic.xml'")
        top = "res/mipmap-anydpi-v4/ic.xml"
    lines.append(f"application: label='{spec['label']}' icon='{top}'")
    return "\n".join(lines) + "\n"


# fake Android sandbox for selftest
class FixtureWorld:
    def __init__(self, present):
        """store the installed fixture packages"""
        self.present = list(present)

    def topdir(self, pkg):
        """return the fixture /data/app directory name of a package"""
        return f"~~fx-{pkg}=="

    def devpath(self, pkg):
        """return the fixture base.apk path of a package"""
        return f"/data/app/{self.topdir(pkg)}/{pkg}-1/base.apk"

    def pkg_of(self, devpath):
        """return the package installed at devpath"""
        for pkg in self.present:
            if self.devpath(pkg) == devpath:
                return pkg
        return None

    def answer(self, cmd):
        """return the canned output for a command"""
        if "getprop ro.build.fingerprint" in cmd:
            return "rhizo/fixture/selftest:16/AP4A/1:user/release-keys\n"
        if cmd.startswith("pm list packages -f"):
            return "".join(f"package:{self.devpath(p)}={p}\n" for p in self.present)
        if cmd.startswith("pm list packages -3"):
            return "".join(f"package:{p}\n" for p in self.present
                           if FIXTURE_PACKAGES[p]["third_party"])
        if cmd.startswith("pm list packages"):
            return "".join(f"package:{p}\n" for p in self.present)
        if cmd.startswith("dumpsys package "):
            return "Packages:\n"
        if cmd.startswith("pm path "):
            pkg = cmd.split()[-1]
            return f"package:{self.devpath(pkg)}\n" if pkg in self.present else ""
        key = self.probe_key(cmd)
        if "resolve-activity" in cmd:
            winner = FIXTURE_WINNERS.get(key)
            return f"{winner}\n" if winner else "No activity found\n"
        if "android.intent.action.MAIN" in cmd:
            out = []
            last = cmd.split()[-1]
            scope = [last] if last in FIXTURE_PACKAGES else None
            for i, pkg in enumerate(self.present):
                if scope is not None and pkg not in scope:
                    continue
                act = FIXTURE_PACKAGES[pkg]["activity"]
                if not act:
                    continue
                out.append(f"Activity #{i}:\n  priority=0 preferredOrder=0 isDefault=false\n  {pkg}/{act}\n")
            return "".join(out)
        mo = re.search(r"-d '([A-Za-z][\w+.-]*):", cmd)
        scheme = mo.group(1) if mo else ""
        handlers = [p for p in FIXTURE_HANDLERS.get(key, []) if p in self.present
                    and (key.startswith("x-scheme-handler/")
                         or scheme in FIXTURE_PACKAGES[p].get("view_schemes", ("content", "file")))]
        return "".join(
            f"Activity #{i}:\n  priority=0 preferredOrder=0 isDefault=false\n"
            f"  {p}/{FIXTURE_PACKAGES[p]['activity'] or '.ViewActivity'}\n"
            for i, p in enumerate(handlers))

    def probe_key(self, cmd):
        """return the key a probe command asks about"""
        mo = re.search(r"-t (\S+)", cmd)
        if mo:
            return mo.group(1)
        mo = re.search(r"-d '([^:]+):'", cmd)
        return f"x-scheme-handler/{mo.group(1)}" if mo else ""


class FixtureBackend(HostBackend):
    """backend with canned sandbox output"""

    poll_s = 0.0

    def __init__(self, world):
        """make a local backend over a fixture world"""
        super().__init__(local=True, init_pid="0")
        self.world = world
        self.refreshed = []
        self.bumped = []

    def aapt2(self):
        """return the fixture aapt2 name"""
        return "fixture-aapt2"

    def android_sh(self, cmd, timeout=30):
        """return the fixture world's canned output for a command"""
        return self.world.answer(cmd)

    def pull(self, guest_path, local_path, timeout=60, sandbox_path=None):
        """write the fixture APK of the package at a path"""
        pkg = self.world.pkg_of(sandbox_path or guest_path)
        if pkg is None:
            return False, f"no fixture APK for {sandbox_path or guest_path!r}"
        with open(local_path, "wb") as fh:
            fh.write(fixture_apk(FIXTURE_PACKAGES[pkg]["apk"]))
        return True, None

    def badging(self, local_apk):
        """return the badging text for a fixture APK"""
        pkg = os.path.basename(local_apk)[: -len(".apk")]
        return 0, fixture_badging(pkg), ""

    def refresh_desktop_db(self, app_dir):
        """record a desktop database refresh of a directory"""
        self.refreshed.append(app_dir)
        return True, f"fixture recorded update-desktop-database {app_dir}"

    def bump_icon_theme(self, theme_root):
        """record an icon theme bump of a theme root"""
        self.bumped.append(theme_root)
        return f"fixture recorded a theme bump of {theme_root}"


def corrupt_value(v):
    """return a changed copy of a value"""
    if isinstance(v, bool):
        return not v
    if isinstance(v, str):
        return "selftest-corrupted-" + v
    if isinstance(v, bytes):
        return b"selftest-corrupted-" + v
    if isinstance(v, int):
        return v + 100000
    if isinstance(v, list):
        return v + ["selftest-corrupted"]
    if isinstance(v, set):
        return v | {"selftest-corrupted"}
    if isinstance(v, dict):
        return dict(v, **{"selftest-corrupted": True})
    if v is None:
        return "selftest-corrupted-none"
    raise TypeError(f"no corruption defined for a {type(v).__name__} expectation")


# assertions for the selftest
class Expectations:
    def __init__(self, corrupt):
        """store whether to corrupt expected values"""
        self.corrupt = corrupt
        self.names = []
        self.failed = []

    def check(self, name, actual, expected):
        """record a check and a failure on a mismatch"""
        self.names.append(name)
        if self.corrupt:
            expected = corrupt_value(expected)
        if actual != expected:
            self.failed.append((name, actual, expected))

    def survivors(self):
        """return the checked names that did not fail"""
        return [n for n in self.names if n not in {f[0] for f in self.failed}]


ALPHA_ENTRY = """[Desktop Entry]
Type=Application
Name=Alpha's Ball
Icon=rhizo-com.fixture.alpha
Exec=rhizo launch com.fixture.alpha %u
StartupWMClass=rhizo-com.fixture.alpha
StartupNotify=true
MimeType=x-scheme-handler/https;image/png;text/plain;
X-Rhizo-Package=com.fixture.alpha
X-Rhizo-Activity=.MainActivity
Categories=X-Rhizo;
NoDisplay=false
Actions=Uninstall;

[Desktop Action Uninstall]
Name=Uninstall
Exec=rhizo app remove com.fixture.alpha
"""
HTMLVIEWER_ENTRY = """[Desktop Entry]
Type=Application
Name=HTML Viewer
Icon=rhizo
Exec=rhizo launch com.android.htmlviewer %u
StartupWMClass=rhizo-com.android.htmlviewer
StartupNotify=true
MimeType=text/html;
X-Rhizo-Package=com.android.htmlviewer
X-Rhizo-Activity=
Categories=X-Rhizo;
NoDisplay=true
"""
MERGED_MIMEAPPS = """[Default Applications]
# a comment nothing may touch
text/csv=libreoffice-calc.desktop

application/vnd.android.package-archive=rhizo-apk-installer.desktop
image/png=rhizo-com.fixture.alpha.desktop
text/html=rhizo-com.android.htmlviewer.desktop
x-scheme-handler/https=rhizo-com.fixture.alpha.desktop
x-scheme-handler/rhizo-test=rhizo-com.fixture.beta.desktop
[Added Associations]
image/png=eog.desktop;
"""


def read_text(path):
    """return the file text or a marker"""
    if not os.path.isfile(path):
        return f"RHIZO_ABSENT {path}"
    with open(path) as fh:
        return fh.read()


def read_bytes(path):
    """return a file's bytes, or RHIZO_ABSENT when it is not a file"""
    if not os.path.isfile(path):
        return b"RHIZO_ABSENT"
    with open(path, "rb") as fh:
        return fh.read()


def icon_dirs_holding(icons_root, name):
    """list the theme size dirs for an icon"""
    found = []
    for d in sorted(os.listdir(icons_root)) if os.path.isdir(icons_root) else []:
        if os.path.isfile(os.path.join(icons_root, d, "apps", f"{name}.png")):
            found.append(int(d.split("x", 1)[0]))
    return sorted(found)


def run_fixture(corrupt):
    """run the synthesis checks against a fixture tree"""
    exp = Expectations(corrupt)
    gen = icon_generator()
    if gen is None:
        raise SystemExit(f"the selftest builds its fixture rasters with {ICON_GEN}, which is absent")
    with tempfile.TemporaryDirectory() as root:
        dest = Dest(os.path.join(root, "usr", "share"))
        os.makedirs(dest.applications)
        os.makedirs(os.path.join(dest.icons, "48x48", "apps"))
        policy_conf = os.path.join(root, "policy.conf")
        with open(policy_conf, "w") as fh:
            fh.write("[desktop]\ndefault_handler = yes\n")
        os.environ[capabilities.PATH_ENV] = policy_conf
        cache_path = os.path.join(root, "cache.json")
        manifest_path = os.path.join(root, "apps.json")
        with open(os.path.join(dest.applications, "foo.desktop"), "w") as fh:
            fh.write("[Desktop Entry]\nType=Application\nName=Foo\nExec=foo\n")
        shipped_handler = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       *(("..", "units", "applications", "apk-installer.desktop") if _CHECKOUT
                                         else (APK_HANDLER,)))
        shutil.copyfile(shipped_handler, os.path.join(dest.applications, APK_HANDLER))
        lookalike = os.path.join(dest.applications, "rhizo-com.notours.stub.desktop")
        with open(lookalike, "w") as fh:
            fh.write("[Desktop Entry]\nType=Application\nName=Not Ours\nExec=stub\n")
        with open(os.path.join(dest.icons, "48x48", "apps", "other-app.png"), "wb") as fh:
            fh.write(gen.solid_png(48, (1, 2, 3, 255)))
        with open(dest.mimeapps, "w") as fh:
            fh.write(FIXTURE_MIMEAPPS)

        world = FixtureWorld(FIXTURE_PACKAGES)
        be = FixtureBackend(world)
        m1, ok1 = sync_apps(be, dest, manifest_path, min_apps=1, cache_path=cache_path)
        exp.check("round1-ok", ok1, True)
        exp.check("entry-text-alpha", read_text(dest.entry("com.fixture.alpha")), ALPHA_ENTRY)
        exp.check("entry-text-handler-only",
                  read_text(dest.entry("com.android.htmlviewer")), HTMLVIEWER_ENTRY)
        exp.check("icon-sizes-alpha",
                  icon_dirs_holding(dest.icons, "rhizo-com.fixture.alpha"), [48, 192])
        exp.check("icon-192-is-192",
                  png_square_size(read_bytes(dest.icon("rhizo-com.fixture.alpha", 192)))[0], 192)
        exp.check("icon-48-is-48",
                  png_square_size(read_bytes(dest.icon("rhizo-com.fixture.alpha", 48)))[0], 48)
        exp.check("icon-density-collision",
                  read_bytes(dest.icon("rhizo-com.fixture.alpha", 48)),
                  gen.solid_png(48, FIXTURE_ICONS["res/mipmap-hdpi-v4/ic.png"][1]))
        exp.check("generic-icon-written",
                  read_bytes(dest.icon(GENERIC_ICON, 256)), gen.mark_png())
        exp.check("generic-icon-named-when-no-raster",
                  [line for line in read_text(dest.entry("com.fixture.gamma")).splitlines()
                   if line.startswith("Icon=")], ["Icon=rhizo"])
        exp.check("no-icon-for-vector-only",
                  icon_dirs_holding(dest.icons, "rhizo-com.fixture.gamma"), [])
        merged = read_text(dest.mimeapps)
        exp.check("mimeapps-merged-text", merged, MERGED_MIMEAPPS)
        exp.check("mimeapps-apk-default",
                  f"{APK_MIME}={APK_HANDLER}" in merged.splitlines(), True)
        exp.check("mimeapps-single-winner",
                  "x-scheme-handler/https=rhizo-com.fixture.alpha.desktop" in merged.splitlines(),
                  True)
        exp.check("mimeapps-chooser-no-default",
                  any(line.startswith("text/plain=") for line in merged.splitlines()), False)
        off = host_defaults({"x-scheme-handler/https": "com.fixture.alpha"},
                            {"com.fixture.alpha"},
                            capabilities.deny_all(), lambda _m: None)
        exp.check("default-handler-off-claims-nothing", off, {APK_MIME: APK_HANDLER})
        on = host_defaults({"x-scheme-handler/https": "com.fixture.alpha"},
                           {"com.fixture.alpha"},
                           capabilities.defaults(), lambda _m: None)
        exp.check("default-handler-off-by-default", on, {APK_MIME: APK_HANDLER})
        granted = host_defaults(
            {"x-scheme-handler/https": "com.fixture.alpha"}, {"com.fixture.alpha"},
            capabilities.read_policy(policy_conf)[0], lambda _m: None)
        exp.check("default-handler-on-claims-the-winner", granted,
                  {APK_MIME: APK_HANDLER,
                   "x-scheme-handler/https": "rhizo-com.fixture.alpha.desktop"})
        exp.check("mimeapps-preserves-foreign",
                  all(line in merged.splitlines() for line in
                      ("# a comment nothing may touch", "text/csv=libreoffice-calc.desktop",
                       "[Added Associations]", "image/png=eog.desktop;")), True)
        exp.check("manifest-fields-alpha",
                  {k: v for k, v in next(a for a in m1["apps"]
                                         if a["package"] == "com.fixture.alpha").items()
                   if k in ("icon_sizes", "mime_types", "third_party", "no_display")},
                  {"icon_sizes": [48, 192],
                   "mime_types": ["x-scheme-handler/https", "image/png", "text/plain"],
                   "third_party": True, "no_display": False})
        exp.check("manifest-fields-handler-only",
                  {k: v for k, v in next(a for a in m1["apps"]
                                         if a["package"] == "com.android.htmlviewer").items()
                   if k in ("icon_sizes", "mime_types", "third_party", "no_display")},
                  {"icon_sizes": [], "mime_types": ["text/html"],
                   "third_party": False, "no_display": True})
        exp.check("content-only-filter-offered-nothing",
                  [os.path.exists(dest.entry("com.fixture.contentonly"))]
                  + [a["package"] for a in m1["apps"] if a["package"] == "com.fixture.contentonly"],
                  [False])
        share_row = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                 *(("..", "..", "install", "cli") if _CHECKOUT else ("..", "..", "install", "cli")),
                                 "print-share-row.py")
        mo = re.search(r'print\("%s\\t%s\\t([a-z]+:[^%"]*)%s"', read_text(share_row) if os.path.exists(share_row) else "")
        exp.check("mime-probe-is-the-uri-rhizo-launch-delivers",
                  bool(mo and mo.group(1) and MIME_PROBE_URI.startswith(mo.group(1))), True)
        off_root = os.path.join(root, "turned-off")
        off_dest = Dest(os.path.join(off_root, "share"))
        os.makedirs(off_dest.applications)
        os.makedirs(os.path.join(off_dest.icons, "48x48", "apps"))
        with open(off_dest.mimeapps, "w") as fh:
            fh.write(merged)
        with open(policy_conf, "w") as fh:
            fh.write("[desktop]\ndefault_handler = no\n")
        try:
            sync_apps(FixtureBackend(FixtureWorld(FIXTURE_PACKAGES)), off_dest,
                      os.path.join(off_root, "apps.json"), min_apps=1,
                      cache_path=os.path.join(off_root, "cache.json"))
        finally:
            with open(policy_conf, "w") as fh:
                fh.write("[desktop]\ndefault_handler = yes\n")
        exp.check("default-handler-off-withdraws-earlier-claims", read_text(off_dest.mimeapps),
                  "".join(line + "\n" for line in MERGED_MIMEAPPS.splitlines()
                          if "=rhizo-com." not in line))
        exp.check("round1-removed-nothing", m1["removed"], [])
        exp.check("desktop-db-refreshed", be.refreshed, [dest.applications])
        exp.check("icon-theme-bumped", be.bumped, [dest.icons])

        before = sorted(os.listdir(dest.applications))
        exp.check("reconcile-unsettled-noop",
                  reconcile_entries(be, dest, {"com.fixture.alpha"}, False, root), [])
        exp.check("reconcile-unsettled-kept-files", sorted(os.listdir(dest.applications)), before)
        exp.check("reconcile-empty-list-noop", reconcile_entries(be, dest, set(), True, root), [])
        exp.check("reconcile-empty-list-kept-files",
                  sorted(os.listdir(dest.applications)), before)

        class NeverSettlesBackend(FixtureBackend):
            def __init__(self, world):
                """make a fixture backend with a churn count of zero"""
                super().__init__(world)
                self.churn = 0

            def android_sh(self, cmd, timeout=30):
                """add a ghost package to each third-party package list"""
                if cmd.startswith("pm list packages -3"):
                    self.churn += 1
                    return super().android_sh(cmd) + f"package:com.fixture.ghost{self.churn}\n"
                return super().android_sh(cmd)

        global settled_query_activities_raw
        real_settle = settled_query_activities_raw
        def short_deadline_settle(be, deadline_s=0.2, stable_rounds_needed=2):
            """call the real settle with a 0.2 second deadline"""
            return real_settle(be, deadline_s=deadline_s, stable_rounds_needed=stable_rounds_needed)
        settled_query_activities_raw = short_deadline_settle
        try:
            unsettled_root = os.path.join(root, "unsettled")
            unsettled_dest = Dest(os.path.join(unsettled_root, "share"))
            os.makedirs(unsettled_dest.applications)
            os.makedirs(os.path.join(unsettled_dest.icons, "48x48", "apps"))
            m_unsettled, ok_unsettled = sync_apps(
                NeverSettlesBackend(FixtureWorld(FIXTURE_PACKAGES)), unsettled_dest,
                os.path.join(unsettled_root, "apps.json"), min_apps=2,
                cache_path=os.path.join(root, "unsettled-cache.json"))
        finally:
            settled_query_activities_raw = real_settle
        exp.check("sync-unsettled-not-ok", ok_unsettled, False)
        exp.check("sync-unsettled-apps-count", len(m_unsettled.get("apps", [])), 4)

        world.present = [p for p in FIXTURE_PACKAGES if p != "com.fixture.beta"]
        m2, ok2 = sync_apps(be, dest, manifest_path, min_apps=1, cache_path=cache_path)
        exp.check("round2-ok", ok2, True)
        exp.check("reconcile-removed-manifest", m2["removed"], ["com.fixture.beta"])
        exp.check("reconcile-removed-entry",
                  os.path.exists(dest.entry("com.fixture.beta")), False)
        exp.check("reconcile-removed-icons",
                  icon_dirs_holding(dest.icons, "rhizo-com.fixture.beta"), [])
        exp.check("reconcile-removed-mimeapps-line",
                  read_text(dest.mimeapps),
                  MERGED_MIMEAPPS.replace(
                      "x-scheme-handler/rhizo-test=rhizo-com.fixture.beta.desktop\n", ""))
        exp.check("reconcile-kept-foreign-entry",
                  read_text(os.path.join(dest.applications, "foo.desktop")),
                  "[Desktop Entry]\nType=Application\nName=Foo\nExec=foo\n")
        exp.check("reconcile-kept-unmarked-rhizo-entry",
                  read_text(os.path.join(dest.applications, APK_HANDLER)),
                  read_text(shipped_handler))
        exp.check("reconcile-kept-unmarked-lookalike",
                  read_text(lookalike),
                  "[Desktop Entry]\nType=Application\nName=Not Ours\nExec=stub\n")
        exp.check("reconcile-final-listing", sorted(os.listdir(dest.applications)),
                  ["foo.desktop", "mimeapps.list", APK_HANDLER,
                   "rhizo-com.android.htmlviewer.desktop", "rhizo-com.fixture.alpha.desktop",
                   "rhizo-com.fixture.gamma.desktop", "rhizo-com.notours.stub.desktop"])
        exp.check("reconcile-kept-live-entry",
                  read_text(dest.entry("com.fixture.alpha")), ALPHA_ENTRY)
        exp.check("reconcile-kept-live-icons",
                  icon_dirs_holding(dest.icons, "rhizo-com.fixture.alpha"), [48, 192])
        exp.check("reconcile-kept-foreign-icon",
                  icon_dirs_holding(dest.icons, "other-app"), [48])

        class DeniedOnce(FixtureBackend):
            def __init__(self, world, victim):
                """make a fixture backend that denies a package's first badging read"""
                super().__init__(world)
                self.victim = victim
                self.denied = 0
            def badging(self, local_apk):
                """fail the victim's first badging read with a permission error"""
                pkg = os.path.basename(local_apk)[: -len(".apk")]
                if pkg == self.victim and self.denied == 0:
                    self.denied += 1
                    return 1, "", "failed to map central directory: Permission denied"
                return super().badging(local_apk)
        denied_root = os.path.join(root, "denied")
        denied_dest = Dest(os.path.join(denied_root, "share"))
        os.makedirs(denied_dest.applications)
        os.makedirs(os.path.join(denied_dest.icons, "48x48", "apps"))
        denied_cache = os.path.join(root, "denied-cache.json")
        victim = "com.fixture.alpha"
        world.present = list(FIXTURE_PACKAGES)
        be_denied = DeniedOnce(world, victim)
        sync_apps(be_denied, denied_dest, os.path.join(root, "denied1.json"),
                  min_apps=1, cache_path=denied_cache)
        exp.check("read-failure-skipped-the-package",
                  os.path.exists(denied_dest.entry(victim)), False)
        exp.check("read-failure-not-cached",
                  victim in json.load(open(denied_cache)).get("entries", {}), False)
        sync_apps(be_denied, denied_dest, os.path.join(root, "denied2.json"),
                  min_apps=1, cache_path=denied_cache)
        exp.check("read-failure-retried-next-run",
                  os.path.exists(denied_dest.entry(victim)), True)

        keyed = os.path.join(root, "keyed-cache.json")
        save_cache(keyed, "fp-A", "/usr/share", {"com.fixture.alpha": {"result": "ok"}})
        exp.check("cache-reused-for-its-own-build-and-prefix",
                  load_cache(keyed, "fp-A", "/usr/share"),
                  {"com.fixture.alpha": {"result": "ok"}})
        exp.check("cache-refused-for-another-prefix",
                  load_cache(keyed, "fp-A", "/root/.local/share"), {})
        exp.check("cache-refused-for-another-build",
                  load_cache(keyed, "fp-B", "/usr/share"), {})
        save_cache(keyed, "fp-A", "/usr/share", {"com.fixture.alpha": {"result": "skip"}}, code="old-appsync")
        exp.check("cache-refused-for-another-appsync",
                  load_cache(keyed, "fp-A", "/usr/share"), {})
        exp.check("cache-reused-for-its-own-appsync",
                  load_cache(keyed, "fp-A", "/usr/share", code="old-appsync"),
                  {"com.fixture.alpha": {"result": "skip"}})
        aapt_a, aapt_b = os.path.join(root, "aapt2-a"), os.path.join(root, "aapt2-b")
        for path, body in ((aapt_a, b"aapt2 build 1"), (aapt_b, b"aapt2 build 2")):
            with open(path, "wb") as fh:
                fh.write(body)
        exp.check("verdict-code-moves-with-aapt2",
                  verdict_code(aapt_a) != verdict_code(aapt_b), True)
        exp.check("verdict-code-same-for-same-aapt2",
                  verdict_code(aapt_a) == verdict_code(aapt_a), True)
        real_gen = ICON_GEN
        other_gen = os.path.join(root, "gen-rhizo-icon.py")
        with open(other_gen, "w") as fh:
            fh.write("# another generator\n")
        before = verdict_code(aapt_a)
        globals()["ICON_GEN"] = other_gen
        try:
            exp.check("verdict-code-moves-with-icon-generator", verdict_code(aapt_a) != before, True)
        finally:
            globals()["ICON_GEN"] = real_gen

        empty = Dest(os.path.join(root, "empty", "share"))
        seed_apk_default(FixtureBackend(FixtureWorld([])), empty, root)
        exp.check("mimeapps-only-seeds-apk-handler", read_text(empty.mimeapps),
                  f"[Default Applications]\n{APK_MIME}={APK_HANDLER}\n")
    return exp


def _selftest_rc_marker():
    """test _extract_rc_marker on sample outputs"""
    cases = [
        ("clean marker, nothing after", "RHIZO_UDD_RC=0\n", "0"),
        ("marker then unrelated stderr noise (the real bug)",
         "RHIZO_UDD_RC=0\n"
         'Could not parse file "/usr/share/applications/x.desktop": '
         "Key file does not have group [Desktop Entry]\n", "0"),
        ("a genuine non-zero exit, still isolated correctly", "RHIZO_UDD_RC=1\n", "1"),
        ("marker never printed at all", "something else entirely\n", None),
    ]
    failed = [name for name, out, want in cases
              if _extract_rc_marker(out, "RHIZO_UDD_RC=") != want]
    if failed:
        print(f"rc-marker selftest FAILED: {failed}")
        return False
    print(f"rc-marker selftest ok: all {len(cases)} cases parse correctly")
    return True


def _selftest_package_queue():
    """test drain_queue against the fixture sandbox"""
    import threading
    failed = []

    def expect(name, ok, detail=""):
        """record a failure with its detail when ok is false"""
        if not ok:
            failed.append(f"{name}: {detail}")

    with tempfile.TemporaryDirectory() as root:
        dest = Dest(os.path.join(root, "usr", "share"))
        os.makedirs(dest.applications)
        policy_conf = os.path.join(root, "policy.conf")
        with open(policy_conf, "w") as fh:
            fh.write("[desktop]\ndefault_handler = yes\n")
        saved_policy = os.environ.get(capabilities.PATH_ENV)
        os.environ[capabilities.PATH_ENV] = policy_conf
        try:
            world = FixtureWorld(["com.fixture.beta"])
            be = FixtureBackend(world)
            queue = os.path.join(root, "queue")
            state = os.path.join(root, "queue.offset")
            open(queue, "w").close()
            full_pass_done = threading.Event()
            result = {}

            def drain():
                """run drain_queue until the full pass is done"""
                result["out"] = drain_queue(
                    be, dest, queue, state, alive=lambda: not full_pass_done.is_set(),
                    wait=lambda s: full_pass_done.wait(min(s, 0.05)), map_deadline_s=1.0)

            t = threading.Thread(target=drain, daemon=True)
            t.start()
            world.present.append("com.fixture.alpha")
            with open(queue, "a") as fh:
                fh.write(world.topdir("com.fixture.alpha") + "\n~~forged-not-installed==\n../../etc\n")
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and not os.path.exists(dest.entry("com.fixture.alpha")):
                time.sleep(0.02)
            expect("entry-before-full-pass-ends", os.path.exists(dest.entry("com.fixture.alpha"))
                   and not full_pass_done.is_set(), "no rhizo-com.fixture.alpha.desktop while the pass ran")
            full_pass_done.set()
            t.join(20)
            expect("drain-returns-once-pass-ends", not t.is_alive(), "drain_queue still running")
            synced, ignored, failed_syncs = result.get("out", ([], [], None))
            expect("synced-the-mapped-package", synced == ["com.fixture.alpha"], repr(synced))
            expect("no-failed-sync", failed_syncs == [], repr(failed_syncs))
            expect("forged-directory-ignored", "~~forged-not-installed==" in ignored, repr(ignored))
            expect("path-entry-rejected", "../../etc" in ignored, repr(ignored))
            expect("nothing-for-forged", sorted(f for f in os.listdir(dest.applications)
                                                if f.startswith("rhizo-")) == ["rhizo-com.fixture.alpha.desktop"],
                   repr(sorted(os.listdir(dest.applications))))
            expect("entry-text", read_text(dest.entry("com.fixture.alpha")) == ALPHA_ENTRY,
                   read_text(dest.entry("com.fixture.alpha")))
            expect("icons-written", icon_dirs_holding(dest.icons, "rhizo-com.fixture.alpha") != [],
                   "no rhizo-com.fixture.alpha.png")
            mime = read_text(dest.mimeapps)
            expect("default-handler-on-claims", "x-scheme-handler/https=rhizo-com.fixture.alpha.desktop" in mime
                   and f"{APK_MIME}={APK_HANDLER}" in mime, mime)
            expect("no-default-for-others", "rhizo-com.fixture.beta" not in mime, mime)
            with open(queue) as fh:
                size = len(fh.read().encode())
            expect("state-at-queue-end", read_text(state).strip() == str(size), read_text(state))
            expect("desktop-db-refreshed", be.refreshed == [dest.applications], repr(be.refreshed))

            with open(policy_conf, "w") as fh:
                fh.write("[desktop]\ndefault_handler = no\n")
            os.remove(dest.mimeapps)
            expect("sync-package-off", sync_package(be, dest, "com.fixture.alpha", 1.0), "sync_package failed")
            mime = read_text(dest.mimeapps)
            expect("default-handler-off-claims-nothing", "rhizo-com.fixture.alpha" not in mime
                   and f"{APK_MIME}={APK_HANDLER}" in mime, mime)
            expect("unlisted-package-refused", not sync_package(be, dest, "com.fixture.gamma", 0.2),
                   "synced a package the sandbox does not have")
            expect("unlisted-package-no-entry", not os.path.exists(dest.entry("com.fixture.gamma")), "")

            real_sync = globals()["sync_package"]
            globals()["sync_package"] = lambda *a, **k: False
            try:
                with open(queue, "a") as fh:
                    fh.write(world.topdir("com.fixture.alpha") + "\n")
                out = drain_queue(be, dest, queue, state, alive=lambda: False,
                                  wait=lambda s: None, map_deadline_s=1.0)
            finally:
                globals()["sync_package"] = real_sync
            expect("failed-sync-reported", out[2] == ["com.fixture.alpha"], repr(out))

            secret = os.path.join(root, "secret")
            with open(secret, "w") as fh:
                fh.write("root:SECRETHASH:19000::\n")
            linked = os.path.join(root, "linked-queue")
            os.symlink(secret, linked)
            caught = io.StringIO()
            refused = False
            with contextlib.redirect_stderr(caught), contextlib.redirect_stdout(caught):
                try:
                    drain_queue(be, dest, linked, os.path.join(root, "linked.offset"),
                                alive=lambda: False, wait=lambda s: None, map_deadline_s=0.1)
                except OSError:
                    refused = True
            expect("queue-symlink-refused", refused and "SECRETHASH" not in caught.getvalue(),
                   caught.getvalue())

            def waits(waiter, secs):
                """return the sleeps a waiter's wait made, with sleep stubbed"""
                slept, real_sleep = [], time.sleep
                time.sleep = slept.append
                try:
                    waiter(secs)
                finally:
                    time.sleep = real_sleep
                return slept

            exited = subprocess.Popen([sys.executable, "-c", "pass"])
            os.waitid(os.P_PID, exited.pid, os.WEXITED | os.WNOWAIT)
            exited_alive, exited_wait = pid_waiter(exited.pid)
            slept = waits(exited_wait, 0.2)
            exited.wait()
            expect("exited-pid-wait-sleeps", not exited_alive() and slept == [0.2], f"slept {slept}")
            reaped_alive, reaped_wait = pid_waiter(exited.pid)
            slept = waits(reaped_wait, 0.2)
            expect("reaped-pid-wait-sleeps", not reaped_alive() and slept == [0.2], f"slept {slept}")
            none_alive, none_wait = drain_waiter(None)
            slept = waits(none_wait, 0.2)
            expect("no-pid-drain-wait-sleeps", not none_alive() and slept == [0.2], f"slept {slept}")
            live = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(0.1)"])
            live_alive, live_wait = pid_waiter(live.pid)
            was_alive = live_alive()
            slept = waits(live_wait, 5)
            live_exited = not live_alive()
            live.wait()
            expect("live-pid-wait-returns-on-exit", was_alive and live_exited and slept == [],
                   f"alive before {was_alive}, exited after {live_exited}, slept {slept}")

            with open(os.path.abspath(__file__)) as src_file:
                main_fn = next(n for n in ast.parse(src_file.read()).body
                               if isinstance(n, ast.FunctionDef) and n.name == "main")
            called = [getattr(n.func, "id", "") for n in ast.walk(main_fn) if isinstance(n, ast.Call)]
            lambdas = [n for n in ast.walk(main_fn) if isinstance(n, ast.Lambda)]
            expect("main-drains-through-drain-waiter",
                   called.count("drain_waiter") == 1 and "pid_waiter" not in called and not lambdas,
                   f"drain_waiter calls {called.count('drain_waiter')}, pid_waiter in main {'pid_waiter' in called}, "
                   f"lambdas {len(lambdas)}")
        except Exception as e:
            failed.append(f"raised {type(e).__name__}: {e}")
        finally:
            if saved_policy is None:
                os.environ.pop(capabilities.PATH_ENV, None)
            else:
                os.environ[capabilities.PATH_ENV] = saved_policy
    if failed:
        print("package-queue selftest FAILED:\n  " + "\n  ".join(failed))
        return False
    print("package-queue selftest ok: a mid-pass install synced before the pass ended, "
          "forged and path entries ignored, default-handler gate held")
    return True


class _SlowMimeappsBackend(FixtureBackend):
    """backend with slow mimeapps.list writes"""

    def push(self, local_path, guest_path, timeout=60):
        """push a file, sleeping 0.4 seconds first for mimeapps.list"""
        if guest_path.endswith("/mimeapps.list"):
            time.sleep(0.4)
        return super().push(local_path, guest_path, timeout)


def _selftest_full_pass_beside_drain():
    """test the full pass beside drain_queue"""
    import threading
    failed = []

    def expect(name, ok, detail=""):
        """record a failure with its detail when ok is false"""
        if not ok:
            failed.append(f"{name}: {detail}")

    saved_winner = FIXTURE_WINNERS["x-scheme-handler/https"]
    saved_handlers = FIXTURE_HANDLERS["x-scheme-handler/https"]
    saved_policy = os.environ.get(capabilities.PATH_ENV)
    real_icon = globals()["ensure_generic_icon"]
    with tempfile.TemporaryDirectory() as root:
        policy_conf = os.path.join(root, "policy.conf")
        with open(policy_conf, "w") as fh:
            fh.write("[desktop]\ndefault_handler = yes\n")
        os.environ[capabilities.PATH_ENV] = policy_conf
        try:
            dest = Dest(os.path.join(root, "lock", "share"))
            os.makedirs(dest.applications)
            be = _SlowMimeappsBackend(FixtureWorld([]))
            claims = os.path.join(root, "lock-claims.json")
            results = []

            def writer(key, value):
                """write a default to mimeapps.list and record whether it worked"""
                with tempfile.TemporaryDirectory() as work:
                    results.append(write_defaults(be, dest, work, {key: value}, set(),
                                                  claims, time.time()))
            ts = [threading.Thread(target=writer, args=("text/x-one", "rhizo-one.desktop")),
                  threading.Thread(target=writer, args=("text/x-two", "rhizo-two.desktop"))]
            for t in ts:
                t.start()
            for t in ts:
                t.join(20)
            mime = read_text(dest.mimeapps)
            expect("concurrent-writers-both-kept", results == [True, True]
                   and "text/x-one=rhizo-one.desktop" in mime and "text/x-two=rhizo-two.desktop" in mime,
                   f"results={results} mimeapps={mime!r}")

            dest = Dest(os.path.join(root, "overlap", "share"))
            os.makedirs(dest.applications)
            world = FixtureWorld(["com.fixture.alpha", "com.android.htmlviewer"])
            be = FixtureBackend(world)
            claims = os.path.join(root, "overlap-claims.json")
            drained = []

            def drain_mid_pass(b, d, w):
                """sync com.fixture.beta as the new https winner"""
                globals()["ensure_generic_icon"] = real_icon
                world.present.append("com.fixture.beta")
                FIXTURE_WINNERS["x-scheme-handler/https"] = "com.fixture.beta/.Main"
                FIXTURE_HANDLERS["x-scheme-handler/https"] = ["com.fixture.beta"]
                drained.append(sync_package(FixtureBackend(world), dest, "com.fixture.beta", 1.0,
                                            claims_path=claims))
                return real_icon(b, d, w)
            globals()["ensure_generic_icon"] = drain_mid_pass
            try:
                sync_apps(be, dest, os.path.join(root, "apps.json"), min_apps=1,
                          cache_path=os.path.join(root, "cache.json"), claims_path=claims)
            finally:
                globals()["ensure_generic_icon"] = real_icon
            expect("drain-ran-mid-pass", drained == [True], repr(drained))
            expect("mid-pass-install-keeps-its-entry", os.path.exists(dest.entry("com.fixture.beta")),
                   "the full pass's reconcile removed rhizo-com.fixture.beta.desktop")
            mime = read_text(dest.mimeapps)
            expect("newer-drain-default-kept",
                   "x-scheme-handler/https=rhizo-com.fixture.beta.desktop" in mime, mime)
            FIXTURE_WINNERS["x-scheme-handler/https"] = "com.fixture.alpha/.MainActivity"
            FIXTURE_HANDLERS["x-scheme-handler/https"] = ["com.fixture.alpha"]
            sync_apps(FixtureBackend(world), dest, os.path.join(root, "apps2.json"), min_apps=1,
                      cache_path=os.path.join(root, "cache.json"), claims_path=claims)
            mime = read_text(dest.mimeapps)
            expect("newer-full-pass-default-wins",
                   "x-scheme-handler/https=rhizo-com.fixture.alpha.desktop" in mime, mime)
        except Exception as e:
            failed.append(f"raised {type(e).__name__}: {e}")
        finally:
            globals()["ensure_generic_icon"] = real_icon
            FIXTURE_WINNERS["x-scheme-handler/https"] = saved_winner
            FIXTURE_HANDLERS["x-scheme-handler/https"] = saved_handlers
            if saved_policy is None:
                os.environ.pop(capabilities.PATH_ENV, None)
            else:
                os.environ[capabilities.PATH_ENV] = saved_policy
    if failed:
        print("full-pass-beside-drain selftest FAILED:\n  " + "\n  ".join(failed))
        return False
    print("full-pass-beside-drain selftest ok: concurrent writers keep both defaults, a mid-pass "
          "install keeps its entry, and the newer resolver read's default stands")
    return True


def _selftest_badging_label():
    """test badging_label on sample badging output"""
    literal = ("package: name='com.rhizo.audiotest.a' versionCode='' versionName='' "
               "platformBuildVersionName='14' platformBuildVersionCode='34' compileSdkVersion='34' "
               "compileSdkVersionCodename='14'\n"
               "minSdkVersion:'26'\ntargetSdkVersion:'34'\n"
               "application: label='Rhizo Tone a' icon=''\n"
               "launchable-activity: name='com.rhizo.audiotest.MainActivity'  label='Rhizo Tone a' icon=''\n")
    cases = [
        ("a literal android:label (rhizo-audiotest-a.apk's own badging)", literal, "Rhizo Tone a"),
        ("a resource label: application-label: wins", fixture_badging("com.fixture.alpha"), "Alpha's Ball"),
        ("a literal label carrying an apostrophe", "application: label='Tom's Tone' icon=''\n", "Tom's Tone"),
        ("no label at all", "application: label='' icon=''\n", None),
        ("no application line", "package: name='x'\n", None),
    ]
    failed = [f"{name}: got {badging_label(text)!r}, want {want!r}"
              for name, text, want in cases if badging_label(text) != want]
    if failed:
        print("badging-label selftest FAILED:\n  " + "\n  ".join(failed))
        return False
    print(f"badging-label selftest ok: all {len(cases)} badging shapes read")
    return True


def selftest():
    """run the selftests and return an exit code"""
    if not _selftest_rc_marker():
        return 1
    if not _selftest_badging_label():
        return 1
    quiet = open(os.devnull, "w")
    real_stderr = sys.stderr
    sys.stderr = quiet
    try:
        queue_ok = _selftest_package_queue()
        overlap_ok = _selftest_full_pass_beside_drain()
    finally:
        sys.stderr = real_stderr
        quiet.close()
    if not (queue_ok and overlap_ok):
        return 1
    quiet = open(os.devnull, "w")
    real_stderr = sys.stderr
    try:
        sys.stderr = quiet
        clean = run_fixture(False)
        corrupted = run_fixture(True)
    finally:
        sys.stderr = real_stderr
        quiet.close()

    if clean.failed:
        print(f"pass 1 FAILED: {len(clean.failed)} of {len(clean.names)} assertions do not hold")
        for name, actual, expected in clean.failed:
            print(f"  {name}\n    got      {actual!r}\n    expected {expected!r}")
        return 1
    print(f"pass 1 ok: all {len(clean.names)} assertions hold on the fixture tree")
    survived = corrupted.survivors()
    if survived or corrupted.names != clean.names:
        print(f"pass 2 FAILED: {len(survived)} of {len(corrupted.names)} assertions still "
              f"passed with their expected value corrupted, so they cannot fail:")
        for name in survived:
            print(f"  {name}")
        missing = [n for n in clean.names if n not in corrupted.names]
        for name in missing:
            print(f"  {name} did not run at all in pass 2")
        return 1
    print(f"pass 2 ok: each of the {len(clean.names)} assertions fails by name when its "
          f"expected value is corrupted")
    return 0


def main():
    """parse the arguments and run appsync"""
    ap = argparse.ArgumentParser()
    ap.add_argument("init_pid", nargs="?")
    ap.add_argument("--manifest", default="/tmp/rhizo-apps.json")
    ap.add_argument("--min-apps", type=int, default=2)
    ap.add_argument("--prefix", default=DEFAULT_PREFIX,
                    help="rebase the /usr/share root the entries, icons and mimeapps.list go under")
    ap.add_argument("--local", action="store_true",
                    help="run guest-side: no ssh hop, direct filesystem access")
    ap.add_argument("--reconcile-only", action="store_true",
                    help="prune entries whose package is gone and stop -- the cheap half of a sync, "
                         "for reflecting an uninstall promptly without a full re-enumeration")
    ap.add_argument("--package", metavar="P",
                    help="sync only package P's entry, icons and mimeapps defaults, if pm lists it")
    ap.add_argument("--drain-queue", metavar="QUEUE",
                    help="sync each package whose /data/app directory rhizo-app-events queued in QUEUE, "
                         "until --while-pid exits; needs --queue-state")
    ap.add_argument("--queue-state", metavar="FILE",
                    help="where --drain-queue records the queue offset it has dealt with")
    ap.add_argument("--while-pid", type=int, metavar="PID",
                    help="keep draining while this process (the full pass) runs")
    ap.add_argument("--mimeapps-only", action="store_true",
                    help="write only the .apk handler default, on this machine, with no sandbox")
    ap.add_argument("--selftest", action="store_true",
                    help="exercise entry text, icons, mimeapps merge and reconcile on a fixture tree")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    dest = Dest(args.prefix)
    if args.mimeapps_only:
        with tempfile.TemporaryDirectory() as work:
            return 0 if seed_apk_default(HostBackend(local=True, init_pid=None), dest, work) else 1
    if not args.init_pid:
        ap.error("init_pid is required unless --mimeapps-only or --selftest is given")
    be = HostBackend(local=args.local, init_pid=args.init_pid)
    if args.reconcile_only:
        return reconcile_only(be, dest)
    if args.package:
        if not PKG_RE.match(args.package):
            ap.error(f"--package {args.package!r} is not a package name")
        return 0 if sync_package(be, dest, args.package) else 1
    if args.drain_queue:
        if not args.queue_state:
            ap.error("--drain-queue needs --queue-state")
        alive, wait = drain_waiter(args.while_pid)
        synced, ignored, failed = drain_queue(be, dest, args.drain_queue, args.queue_state, alive, wait)
        log(f"queue drained: {len(synced)} package(s) synced {synced}, {len(ignored)} line(s) ignored, "
            f"{len(failed)} failed {failed}")
        return 1 if failed else 0
    _, ok = sync_apps(be, dest, args.manifest, args.min_apps)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
