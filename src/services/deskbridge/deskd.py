#!/usr/bin/env python3

import argparse
import base64
import binascii
import collections
import ctypes
import hashlib
import hmac
import importlib.util
import json
import os
import re
import selectors
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

_LAUNCHER_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "androidd"))
sys.path[:0] = [os.path.dirname(os.path.abspath(__file__)), os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."),
                os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"), _LAUNCHER_DIR]
from sandbox import capabilities
import control_open  # noqa: E402

_BROKERD_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "broker", "brokerd.py")
_brokerd_spec = importlib.util.spec_from_file_location("rhizo_brokerd_grammar", _BROKERD_PATH)
_brokerd = importlib.util.module_from_spec(_brokerd_spec)
_brokerd_spec.loader.exec_module(_brokerd)
URI_RE = _brokerd.URI_RE
MIME_RE = _brokerd.MIME_RE
PKG_RE = _brokerd.PKG_RE
ACTIVATION_TOKEN_RE = _brokerd.ACTIVATION_TOKEN_RE

TEXT_MIMES = ("text/plain;charset=utf-8", "text/plain", "UTF8_STRING")
IMAGE_MIMES = ("image/png",)
PASSWORD_HINT_MIME = "x-kde-passwordManagerHint"

MAX_PAYLOAD = 8 * 1024 * 1024
MIME_LIMIT = 255

MAX_URI_LEN = 4096
OPEN_RATE_LIMIT = 5
IP_FREEBIND = getattr(socket, "IP_FREEBIND", 15)
OPEN_RATE_WINDOW = 10.0


def wlbridge_caps(policy):
    """return the --caps set for rhizo-wlbridge"""
    caps = set()
    if policy.scope("desktop.clipboard") != "off":
        caps.add("clipboard")
    if policy.allows("desktop.drag"):
        caps.add("drag")
    if resolve_pointer_enabled(policy):
        caps.add("pointer")
    return caps


def resolve_pointer_enabled(policy):
    """return whether policy allows desktop.pointer"""
    return policy.allows("desktop.pointer")

ICON_POOL_SIZE = 16
ICON_MAX = 2 * 1024 * 1024

NOTIF_MAX = 256

RELAY_QUEUE_MAX = 1 << 20
RELAY_LINE_MAX = 64 * 1024
NOTIFY_TITLE_MAX = 256
NOTIFY_BODY_MAX = 4096
NOTIFY_KEY_MAX = 1024
SYSTEM_NOISE_IDS = {"19"}
SYSTEM_NOISE_TAG = "com.android.server.wm.AlertWindowNotification"
NOTIFY_ACTION_MAX = 255
RELAY_REFUSAL_TIMEOUT_S = 1.0
PEERCRED = struct.Struct("3i")

PENDING_AUTH_TIMEOUT = 5.0

NONCE_HEX_CHARS = 32
HEX_DIGITS = frozenset("0123456789abcdef")


def desk_proof(token, role, android_nonce, host_nonce):
    """return the HMAC-SHA256 of the role and nonces"""
    msg = ("rhizo-desk %s\n%s\n%s" % (role, android_nonce, host_nonce)).encode("ascii")
    return hmac.new(token.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def is_nonce(value):
    """return whether a value is a hex string of the nonce length"""
    return isinstance(value, str) and len(value) == NONCE_HEX_CHARS and set(value) <= HEX_DIGITS

SANDBOX_DATA = "/data/"


def _instanced(base, sandbox_id, sep="-"):
    """return base for sandbox_id 0, else base, sep and sandbox_id"""
    return base if sandbox_id == 0 else "%s%s%d" % (base, sep, sandbox_id)


SANDBOX_ID = int(os.environ.get("RHIZO_SANDBOX_ID", "0"))
HOST_DATA = _instanced("/run/rhizo", SANDBOX_ID) + "/data/"
CONTROL_DIR = HOST_DATA + "rhizo_control"
CONTROL_OUT = CONTROL_DIR + "/control.out"
CONTROL_FIFO = CONTROL_DIR + "/control"
LAUNCH_LOG = _instanced("/run/rhizo-launch", SANDBOX_ID) + "/rhizo-launch.log"
SESSION_ENV = os.environ.get("RHIZO_DESKTOP_SESSION_ENV", "/run/rhizo-desktop/session.env")
ENV_NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")

IN_MODIFY = 0x00000002
IN_CLOSE_WRITE = 0x00000008
INOTIFY_EVENT = struct.Struct("iIII")
AWAITED_PAYLOADS = ("clip-", "drop-")
AWAIT_WAKES = 120
IN_CREATE = 0x00000100
IN_MOVED_TO = 0x00000080
IN_IGNORED = 0x00008000


def read_raw(path, offset=0, limit=None):
    """read a range of a file with pread"""
    return read_range(os.open(path, os.O_RDONLY | os.O_CLOEXEC), offset, limit)


def read_range(fd, offset=0, limit=None):
    """read a range of fd with pread and close fd"""
    try:
        chunks, got = [], 0
        while limit is None or got < limit:
            want = 65536 if limit is None else min(65536, limit - got)
            chunk = os.pread(fd, want, offset + got)
            if not chunk:
                break
            chunks.append(chunk)
            got += len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


def require_mime(mime):
    """raise ValueError unless mime is at most MIME_LIMIT characters and matches MIME_RE"""
    if len(mime) > MIME_LIMIT:
        raise ValueError("mime type is %d characters, limit is %d" % (len(mime), MIME_LIMIT))
    if not MIME_RE.match(mime):
        raise ValueError("%r is not a lowercase type/subtype" % mime[:120])


def decode_b64_strict(b64):
    """decode base64 and reject invalid bytes"""
    try:
        return base64.b64decode(b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("invalid base64 (%s)" % exc)


def resolve_drop_path(path):
    """return the normpath under HOST_DATA of a /data/ path, or None"""
    if not path.startswith(SANDBOX_DATA):
        return None
    host_path = os.path.normpath(HOST_DATA + path[len(SANDBOX_DATA):])
    root = os.path.normpath(HOST_DATA)
    if host_path != root and not host_path.startswith(root + os.sep):
        return None
    return host_path


def read_payload(host_path, limit):
    """read up to limit bytes of host_path from control_open.open_payload"""
    return read_range(control_open.open_payload(HOST_DATA, host_path), 0, limit)


class IconPool:
    """pool of icon file paths"""

    def __init__(self, directory, pool_size=ICON_POOL_SIZE):
        """start an empty pool of icon slots in a directory"""
        self.directory = directory
        self.pool_size = pool_size
        self.slot_by_key = {}
        self.key_by_slot = {}
        self.next_slot = 0

    def path_for(self, key):
        """return the icon file of a key"""
        slot = self.slot_by_key.get(key)
        if slot is None:
            slot = self.next_slot % self.pool_size
            self.next_slot += 1
            evicted = self.key_by_slot.get(slot)
            if evicted is not None:
                self.slot_by_key.pop(evicted, None)
            self.key_by_slot[slot] = key
            self.slot_by_key[key] = slot
        return os.path.join(self.directory, "icon-%d.png" % slot)

    def forget(self, key):
        """free the icon slot of a key"""
        slot = self.slot_by_key.pop(key, None)
        if slot is not None:
            self.key_by_slot.pop(slot, None)


class NotifTable:
    """notification key and id table"""

    def __init__(self, capacity=NOTIF_MAX):
        """start an empty key to notification id map with a capacity"""
        self.capacity = capacity
        self.id_by_key = collections.OrderedDict()
        self.key_by_id = {}

    def get_id(self, key, default=0):
        """return the notification id of a key, or the default"""
        return self.id_by_key.get(key, default)

    def get_key(self, nid):
        """return the key of a notification id"""
        return self.key_by_id.get(nid)

    def put(self, key, nid):
        """map a key to a notification id"""
        old = self.id_by_key.pop(key, None)
        if old is not None:
            self.key_by_id.pop(old, None)
        elif len(self.id_by_key) >= self.capacity:
            evict_key, evict_id = self.id_by_key.popitem(last=False)
            self.key_by_id.pop(evict_id, None)
        self.id_by_key[key] = nid
        self.key_by_id[nid] = key

    def pop_by_key(self, key):
        """remove key and return the notification id of key"""
        nid = self.id_by_key.pop(key, None)
        if nid is not None:
            self.key_by_id.pop(nid, None)
        return nid

    def pop_by_id(self, nid):
        """remove nid and return the key of nid"""
        key = self.key_by_id.pop(nid, None)
        if key is not None:
            self.id_by_key.pop(key, None)
        return key

    def __len__(self):
        """return the number of mapped notifications"""
        return len(self.id_by_key)


def log(msg):
    """write a timestamped message to stderr"""
    sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()



class LineReader:
    """line buffer for a byte stream"""

    def __init__(self, limit):
        """start an empty line buffer with a length limit"""
        self.buf = bytearray()
        self.limit = limit

    def feed(self, data):
        """add bytes and yield each complete line"""
        self.buf.extend(data)
        while True:
            nl = self.buf.find(b"\n")
            if nl < 0:
                if len(self.buf) > self.limit:
                    raise ValueError("line over %d bytes with no newline" % self.limit)
                return
            line = bytes(self.buf[:nl])
            del self.buf[: nl + 1]
            yield line


class ControlWatch:
    """inotify watch on control.out"""

    def __init__(self):
        """create the inotify descriptor and call arm"""
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.fd = self.libc.inotify_init1(0o4000)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        self.offset = 0
        self.wd = -1
        self.armed = False
        self.dir_id = None
        self.reset_awaited()
        self.arm()

    def reply_size(self):
        """return the st_size of CONTROL_OUT, or 0 on OSError"""
        try:
            fd = control_open.open_reply(HOST_DATA, CONTROL_OUT)
        except FileNotFoundError:
            return 0
        except OSError as exc:
            control_open.refused_once(CONTROL_OUT, exc, log)
            return 0
        try:
            return os.fstat(fd).st_size
        finally:
            os.close(fd)

    def reset_awaited(self):
        """clear the awaited payload files"""
        self.awaited = set()
        self.out_wd = -1
        self.await_wakes = 0

    def arm(self):
        """add an inotify watch on the control directory"""
        try:
            dirfd = control_open.open_dir(HOST_DATA, CONTROL_DIR)
        except OSError as exc:
            log("failed to open %s (%s)"
                % (CONTROL_DIR, exc.strerror))
            return False
        try:
            st = os.fstat(dirfd)
            wd = self.libc.inotify_add_watch(
                self.fd, control_open.watch_path(dirfd).encode(), IN_CREATE | IN_MOVED_TO)
        finally:
            os.close(dirfd)
        if wd < 0:
            log("inotify_add_watch %s failed (%s)"
                % (CONTROL_DIR, os.strerror(ctypes.get_errno())))
            return False
        self.watch_appends(False)
        self.reset_awaited()
        self.wd = wd
        self.armed = True
        self.dir_id = (st.st_dev, st.st_ino)
        self.offset = self.reply_size()
        log("watching %s for clip and drop lines" % CONTROL_OUT)
        return True

    def rearm(self):
        """call arm unless dir_id matches the st_dev and st_ino of CONTROL_DIR"""
        self.drain_events()
        try:
            dirfd = control_open.open_dir(HOST_DATA, CONTROL_DIR)
        except OSError:
            return self.arm()
        try:
            st = os.fstat(dirfd)
        finally:
            os.close(dirfd)
        if self.armed and self.dir_id == (st.st_dev, st.st_ino):
            return True
        return self.arm()

    def fileno(self):
        """return the inotify descriptor"""
        return self.fd

    def drain_events(self):
        """read the inotify events and add created clip- and drop- files to awaited"""
        while True:
            try:
                buf = os.read(self.fd, 65536)
            except BlockingIOError:
                return
            if not buf:
                return
            off = 0
            while off + INOTIFY_EVENT.size <= len(buf):
                wd, mask, _cookie, length = INOTIFY_EVENT.unpack_from(buf, off)
                name = buf[off + INOTIFY_EVENT.size:off + INOTIFY_EVENT.size + length]
                off += INOTIFY_EVENT.size + length
                name = name.split(b"\0", 1)[0].decode("utf-8", "replace")
                if wd == self.wd and mask & (IN_CREATE | IN_MOVED_TO) and name.startswith(AWAITED_PAYLOADS):
                    self.awaited.add(name)
                if mask & IN_IGNORED:
                    if wd == self.wd:
                        self.wd, self.armed, self.dir_id = -1, False, None
                    if wd == self.out_wd:
                        self.out_wd = -1

    def watch_appends(self, on):
        """add or remove the control.out watch"""
        if on and self.out_wd < 0:
            try:
                outfd = control_open.open_reply(HOST_DATA, CONTROL_OUT)
            except OSError as exc:
                log("failed to open %s (%s)" % (CONTROL_OUT, exc))
                return
            try:
                wd = self.libc.inotify_add_watch(self.fd, control_open.watch_path(outfd).encode(), IN_MODIFY)
            finally:
                os.close(outfd)
            if wd < 0:
                log("inotify_add_watch %s failed (%s)"
                    % (CONTROL_OUT, os.strerror(ctypes.get_errno())))
                return
            self.out_wd = wd
        elif not on and self.out_wd >= 0:
            self.libc.inotify_rm_watch(self.fd, self.out_wd)
            self.out_wd = -1

    def new_lines(self):
        """return the control.out lines past self.offset"""
        self.drain_events()
        lines = self.read_complete_lines()
        if self.awaited:
            self.await_wakes += 1
            if self.await_wakes > AWAIT_WAKES:
                log("no control.out line for %s after AWAIT_WAKES wakes" % " ".join(sorted(self.awaited)))
                self.awaited.clear()
        if not self.awaited:
            self.await_wakes = 0
        if self.awaited and self.out_wd < 0:
            self.watch_appends(True)
            lines += self.read_complete_lines()
        self.watch_appends(bool(self.awaited))
        return lines

    def read_complete_lines(self):
        """return the newline-terminated lines of control.out past self.offset"""
        try:
            fd = control_open.open_reply(HOST_DATA, CONTROL_OUT)
        except FileNotFoundError:
            return []
        except OSError as exc:
            control_open.refused_once(CONTROL_OUT, exc, log)
            return []
        if os.fstat(fd).st_size < self.offset:
            self.offset = 0
        data = read_range(fd, self.offset)
        complete = data[:data.rfind(b"\n") + 1]
        self.offset += len(complete)
        lines = complete.decode("utf-8", "replace").splitlines()
        for line in lines:
            for word in line.split():
                if word.startswith("path="):
                    self.awaited.discard(os.path.basename(word[len("path="):]))
        return lines


def read_session_env(path):
    """return the variables a session.env file sets"""
    env = {}
    for line in read_raw(path).decode("utf-8", "replace").splitlines():
        name, eq, value = line.partition("=")
        if eq and ENV_NAME_RE.match(name):
            env[name] = value
    return env


def is_system_noise(key):
    """return whether key matches SYSTEM_NOISE_IDS or SYSTEM_NOISE_TAG"""
    parts = key.split("|")
    return len(parts) >= 4 and (parts[2] in SYSTEM_NOISE_IDS or parts[3].startswith(SYSTEM_NOISE_TAG))


def notification_id(value):
    """return value as a desktop notification id"""
    if type(value) is not int or not 0 < value < 1 << 32:
        raise ValueError("notification id %r is not a uint32 above 0" % (value,))
    return value


def bounded_text(value, cap):
    """return value as a string of at most cap characters"""
    if not isinstance(value, str) or len(value) > cap:
        raise ValueError("%r is not a string of at most %d characters" % (str(value)[:80], cap))
    return value


def clip_text(value, cap):
    """return notification text cut to cap characters"""
    text = value or ""
    if not isinstance(text, str):
        raise ValueError("notification text %r is not a string" % (text,))
    text = text.encode("utf-8", "replace").decode("utf-8").replace("\x00", "\ufffd")
    return text if len(text) <= cap else text[: cap - 1] + "\u2026"


def session_env_owner():
    """return the uid owning session.env, or None"""
    try:
        return os.stat(SESSION_ENV).st_uid
    except FileNotFoundError:
        return None


class Relay:
    """connection from rhizo-desk-notify"""

    def __init__(self, conn):
        """read the SO_PEERCRED pid and uid of conn"""
        self.conn = conn
        self.pid, self.uid, _gid = PEERCRED.unpack(
            conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, PEERCRED.size))
        self.reader = LineReader(RELAY_LINE_MAX)
        self.out = OutQueue()
        self.bus = None


class SessionWatch:
    """inotify watch on session.env"""

    def __init__(self, path):
        """add an inotify watch on the directory of session.env"""
        self.name = os.path.basename(path).encode()
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.fd = self.libc.inotify_init1(0o4000 | 0o2000000)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        if self.libc.inotify_add_watch(self.fd, os.path.dirname(path).encode(), IN_CLOSE_WRITE | IN_MOVED_TO) < 0:
            err = ctypes.get_errno()
            os.close(self.fd)
            raise OSError(err, os.strerror(err))

    def fileno(self):
        """return the inotify descriptor"""
        return self.fd

    def written(self):
        """return whether session.env was written"""
        written = False
        while True:
            try:
                buf = os.read(self.fd, 65536)
            except BlockingIOError:
                return written
            pos = 0
            while pos + INOTIFY_EVENT.size <= len(buf):
                _wd, _mask, _cookie, nlen = INOTIFY_EVENT.unpack_from(buf, pos)
                name = buf[pos + INOTIFY_EVENT.size:pos + INOTIFY_EVENT.size + nlen].split(b"\0", 1)[0]
                written = written or name == self.name
                pos += INOTIFY_EVENT.size + nlen


def parse_launch_record(line):
    """parse an am_start_return line from rhizo-launch.sh"""
    if " event=am_start_return " not in " %s " % line:
        return None
    fields = {}
    for word in line.split():
        key, eq, value = word.partition("=")
        if eq:
            fields[key] = value
    display, cdisplay = fields.get("display", ""), fields.get("cdisplay", "")
    if not (display.isdigit() and cdisplay.isdigit()):
        return None
    init = fields.get("init", "")
    return {"pkg": fields.get("pkg", ""), "display": int(display), "cdisplay": cdisplay,
            "init": init if init.isdigit() else ""}


_RHIZO_STACK_RE = re.compile(
    r"^/(rhizo(-[0-9]+)?|system\.slice/(system-androidd\.slice/)?androidd(@[0-9]+)?\.service/android)/")


def _in_rhizo_stack(pid):
    """return whether the cgroup of pid matches _RHIZO_STACK_RE"""
    try:
        lines = read_raw("/proc/%s/cgroup" % pid).decode("utf-8", "replace").splitlines()
    except OSError:
        return False
    return any(line.startswith("0::") and _RHIZO_STACK_RE.match(line[3:]) for line in lines)


def init_running(pid):
    """return whether pid is init second_stage in a Rhizo stack cgroup"""
    try:
        cmdline = read_raw("/proc/%s/cmdline" % pid).split(b"\0")
    except OSError:
        return False
    return (len(cmdline) > 1 and cmdline[0].endswith(b"init") and cmdline[1] == b"second_stage"
            and _in_rhizo_stack(pid))


class LaunchWatch:
    """inotify watch on the launch log"""

    def __init__(self, path=None):
        """create the inotify descriptor and call arm"""
        self.path = path or LAUNCH_LOG
        self.dir = os.path.dirname(self.path)
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.fd = self.libc.inotify_init1(0o4000 | 0o2000000)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        self.dir_wd = -1
        self.parent_wd = -1
        self.offset = self._size()
        self.arm()

    def _size(self):
        """return the size of the watched file"""
        try:
            return os.stat(self.path).st_size
        except OSError:
            return 0

    def arm(self):
        """add an inotify watch on the launch directory, or on the parent directory"""
        wd = self.libc.inotify_add_watch(
            self.fd, self.dir.encode(), IN_MODIFY | IN_CREATE | IN_MOVED_TO)
        if wd >= 0:
            self.dir_wd = wd
            if self.parent_wd >= 0:
                self.libc.inotify_rm_watch(self.fd, self.parent_wd)
                self.parent_wd = -1
            log("watching %s for app launches" % self.dir)
            return True
        if self.parent_wd < 0:
            pwd = self.libc.inotify_add_watch(
                self.fd, os.path.dirname(self.dir).encode(), IN_CREATE | IN_MOVED_TO)
            if pwd < 0:
                log("inotify_add_watch failed for %s and the parent directory (%s)"
                    % (self.dir, os.strerror(ctypes.get_errno())))
                return False
            self.parent_wd = pwd
        return False

    def fileno(self):
        """return the inotify descriptor"""
        return self.fd

    def _events(self):
        """return the queued inotify events"""
        out = []
        while True:
            try:
                buf = os.read(self.fd, 65536)
            except BlockingIOError:
                return out
            pos = 0
            while pos + 16 <= len(buf):
                wd, _mask, _cookie, nlen = struct.unpack_from("iIII", buf, pos)
                name = buf[pos + 16:pos + 16 + nlen].split(b"\0", 1)[0].decode("utf-8", "replace")
                out.append((wd, name))
                pos += 16 + nlen

    def new_records(self):
        """return the launch records past self.offset"""
        base = os.path.basename(self.dir)
        for wd, name in self._events():
            if wd == self.parent_wd and name == base:
                self.arm()
        size = self._size()
        if size < self.offset:
            self.offset = 0
        if size == self.offset:
            return []
        try:
            data = read_raw(self.path, self.offset)
        except OSError:
            return []
        complete = data[:data.rfind(b"\n") + 1]
        self.offset += len(complete)
        records = []
        for line in complete.decode("utf-8", "replace").splitlines():
            rec = parse_launch_record(line)
            if rec is not None:
                records.append(rec)
        return records

    def latest_per_display(self):
        """return the newest launch record per display"""
        try:
            lines = read_raw(self.path).decode("utf-8", "replace").splitlines()
        except OSError:
            return []
        newest = {}
        alive = {}
        for line in lines:
            rec = parse_launch_record(line)
            if rec is None or not rec["init"]:
                continue
            if rec["init"] not in alive:
                alive[rec["init"]] = init_running(rec["init"])
            if alive[rec["init"]]:
                newest.pop(rec["display"], None)
                newest[rec["display"]] = rec
        return list(newest.values())


class OutQueue:
    """write queue for a nonblocking descriptor"""

    def __init__(self):
        """start an empty output buffer"""
        self.buf = bytearray()

    def push(self, data):
        """append bytes to the output buffer"""
        self.buf.extend(data)

    def flush(self, fd):
        """write buffered bytes to fd until BlockingIOError"""
        while self.buf:
            try:
                n = os.write(fd, self.buf[:65536])
            except BlockingIOError:
                return
            del self.buf[:n]

    def pending(self):
        """return whether buf is non-empty"""
        return bool(self.buf)


class WlBridge:
    """pipe connection to rhizo-wlbridge"""

    def __init__(self, path, caps):
        """start rhizo-wlbridge with --caps caps"""
        argv = [path, "--caps", ",".join(sorted(caps))]
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=None,
            bufsize=0,
        )
        os.set_blocking(self.proc.stdin.fileno(), False)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.reader = LineReader(MAX_PAYLOAD * 2)
        self.out = OutQueue()
        self.ready = False
        self.reaped = False
        self.pidfd = None

    def fileno(self):
        """return the descriptor of wlbridge's stdout"""
        return self.proc.stdout.fileno()

    def infileno(self):
        """return the descriptor of wlbridge's stdin"""
        return self.proc.stdin.fileno()

    def send(self, line):
        """queue a command line for wlbridge"""
        self.out.push(line.encode("utf-8") + b"\n")

    def get(self, mime, tag):
        """queue a get line for mime and tag"""
        self.send("get %s %d" % (mime, tag))

    def set(self, mime, b64):
        """queue a set line for mime and b64"""
        self.send("set %s %s" % (mime, b64))


class Deskd:
    """desktop bridge for rhizo-deskd"""
    def __init__(self, args):
        """set up the policy and the listener"""
        self.args = args
        self.policy = capabilities.policy_or_deny(log=log, instance_id=SANDBOX_ID)
        self.uri_schemes = self.policy.scope("desktop.open_uri")
        self.clip_mode = self.policy.scope("desktop.clipboard")
        self.notifications_enabled = self.policy.allows("desktop.notifications")
        self.drag_enabled = self.policy.allows("desktop.drag")
        self.pointer_enabled = resolve_pointer_enabled(self.policy)
        self.sel = selectors.DefaultSelector()
        self.android = None
        self.android_reader = None
        self.android_ok = False
        self.pending = None
        self.pending_reader = None
        self.pending_deadline = None
        self.pending_challenge = None
        self.init_clip_state()
        self.notifs = NotifTable()
        self.notif_pkg = {}
        self.activation_tokens = {}
        self.icon_dir = tempfile.mkdtemp(prefix="rhizo-notif-icons.")
        self.icons = IconPool(self.icon_dir)
        self.openers = []
        self.open_times = []
        self.drop = None
        self.dragout = None
        self.cid_by_display = {}
        self.pads = {}
        self.pending_up = None
        self.pad_press = None
        self.payload_seq = 0
        self.relay_listener = None
        self.relay = None
        self.relay_pending = None
        self.session_writes = 0
        self.wl_session_write = 0

        self.wl = WlBridge(args.bridge, wlbridge_caps(self.policy))
        self.sel.register(self.wl.fileno(), selectors.EVENT_READ, self.on_wl)
        self.wl_write_armed = False
        self.wl_dead = False
        self.wl_clipboard = True
        self.android_out = OutQueue()

        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
        self.listener.bind((args.bind, args.port))
        self.listener.listen(1)
        self.sel.register(self.listener, selectors.EVENT_READ, self.on_accept)
        log("listening on %s:%d" % (args.bind, args.port))
        self.connect_notify_socket()
        self.connect_control()
        self.connect_launches()
        self.connect_session_watch()

    def connect_session_watch(self):
        """watch session.env for a desktop session write"""
        try:
            self.session_watch = SessionWatch(SESSION_ENV)
        except OSError as exc:
            self.session_watch = None
            log("failed to watch %s (%s)"
                % (SESSION_ENV, exc))
            return
        self.sel.register(self.session_watch.fileno(), selectors.EVENT_READ, self.on_session)

    def on_session(self, _key, _mask=0):
        """update os.environ from session.env and call check_relay and restart_wlbridge"""
        if not self.session_watch.written():
            return
        try:
            env = read_session_env(SESSION_ENV)
        except OSError as exc:
            log("failed to read %s (%s)" % (SESSION_ENV, exc))
            return
        os.environ.update(env)
        self.session_writes += 1
        log("desktop session written to %s WAYLAND_DISPLAY=%s" % (SESSION_ENV, env.get("WAYLAND_DISPLAY")))
        if self.relay_pending is not None:
            self.check_relay()
        if self.wl_dead:
            self.restart_wlbridge()

    def restart_wlbridge(self):
        """start rhizo-wlbridge in the session.env desktop session"""
        if not self.wl.reaped:
            self.wl.proc.kill()
            self.wl.proc.wait()
            self.reap_wlbridge()
        self.wl_gets.clear()
        self.pending_get = None
        self.pending_get_deadline = None
        try:
            wl = WlBridge(self.args.bridge, wlbridge_caps(self.policy))
        except OSError as exc:
            log("rhizo-wlbridge did not start for WAYLAND_DISPLAY=%s (%s %s)"
                % (os.environ.get("WAYLAND_DISPLAY"), type(exc).__name__, exc))
            return
        self.wl = wl
        self.wl_session_write = self.session_writes
        self.sel.register(self.wl.fileno(), selectors.EVENT_READ, self.on_wl)
        self.wl_dead = False
        self.wl_clipboard = True
        log("rhizo-wlbridge started for WAYLAND_DISPLAY=%s" % os.environ.get("WAYLAND_DISPLAY"))

    def connect_control(self):
        """watch control.out with inotify"""
        self.control = ControlWatch()
        self.sel.register(self.control.fileno(), selectors.EVENT_READ, self.on_control)

    def connect_launches(self):
        """watch the launch log for app launches"""
        self.launches = None
        if not self.drag_enabled:
            return
        try:
            self.launches = LaunchWatch()
        except OSError as exc:
            log("failed to watch app launches (%s)" % exc)
            return
        self.sel.register(self.launches.fileno(), selectors.EVENT_READ, self.on_launch)

    def on_launch(self, _key, _mask=0):
        """arm a drag watch for each launch record from new_records"""
        for rec in self.launches.new_records():
            self.arm_dragwatch(rec["cdisplay"], rec["display"])

    def rearm_dragwatch(self):
        """call arm_dragwatch for each latest_per_display record"""
        if self.launches is None:
            return
        for rec in self.launches.latest_per_display():
            self.arm_dragwatch(rec["cdisplay"], rec["display"])

    def init_clip_state(self):
        """set the initial clipboard state"""
        self.android_clip_sha256 = None
        self.host_clip_sha256 = None
        self.android_clip = None
        self.clip_cid_seq = 0
        self.wl_host_gen = 0
        self.wl_get_seq = 0
        self.wl_gets = {}
        self.pending_get = None
        self.pending_get_deadline = None
        self.held_composer_line = None

    def wlbridge_reports_host(self):
        """return whether wl.ready and wl_clipboard are set and wl_dead is clear"""
        return self.wl.ready and self.wl_clipboard and not self.wl_dead

    def on_control(self, _key, _mask=0):
        """handle the control.out lines from new_lines"""
        for line in self.control.new_lines():
            if line == "clip none" or line.startswith("clip id="):
                if not self.wl.ready and self.wl_clipboard and not self.wl_dead:
                    self.held_composer_line = line
                    continue
                if self.wlbridge_reports_host():
                    log("dropped a composer clip line with wlbridge_reports_host() true")
                    continue
            self.on_control_line(line)

    def replay_held_composer_line(self):
        """clear held_composer_line and call on_control_line with the held line"""
        line, self.held_composer_line = self.held_composer_line, None
        if line is not None:
            self.on_control_line(line)

    def on_control_line(self, line):
        """parse a composer control line"""
        if line == "clip none":
            self.host_clip_sha256 = None
            log("composer clip none")
            return
        if line.startswith("clip id="):
            try:
                self.on_composer_clip(line)
            except (ValueError, KeyError, OSError) as exc:
                log("failed to handle composer clip line %r (%s)" % (line, exc))
            return
        if not line.startswith("drop id="):
            return
        try:
            self.on_composer_drop(line)
        except (ValueError, KeyError, OSError) as exc:
            log("failed to handle composer drop line %r (%s)" % (line, exc))

    def arm_dragwatch(self, cid, logical):
        """queue a dragwatch message for a display"""
        if self.android is None or not self.android_ok:
            log("no authenticated android app for android display %s (composer %s)" % (logical, cid))
            return
        self.cid_by_display[int(logical)] = cid
        self.to_android({"t": "dragwatch", "display": int(logical)})
        log("queued dragwatch for android display %s" % logical)

    def logical_display_for(self, cdisplay):
        """return the logical display for a composer display"""
        try:
            lines = read_raw(LAUNCH_LOG).decode("utf-8", "replace").splitlines()
        except OSError:
            return None
        for line in reversed(lines):
            if "cdisplay=%s " % cdisplay in line + " ":
                for field in line.split():
                    if field.startswith("display="):
                        return field.split("=", 1)[1]
        return None

    def composer_display_for_package(self, pkg):
        """return the composer display for a package"""
        try:
            lines = read_raw(LAUNCH_LOG).decode("utf-8", "replace").splitlines()
        except OSError:
            return None
        for line in reversed(lines):
            if "pkg=%s " % pkg in line + " ":
                for field in line.split():
                    if field.startswith("cdisplay="):
                        return field.split("=", 1)[1]
        return None

    def on_composer_drop(self, line):
        """queue the dropped file for android"""
        fields = {}
        for field in line.split():
            if "=" in field:
                key, value = field.split("=", 1)
                fields[key] = value
        path = fields.get("path")
        if not path:
            log("composer drop line has no path= (%s)" % line)
            return
        real_path = resolve_drop_path(path)
        if real_path is None:
            log("drop path %r resolves outside %s" % (path, HOST_DATA))
            return
        try:
            raw = read_payload(real_path, MAX_PAYLOAD + 1)
        except OSError as exc:
            log("failed to read drop payload %s (%s)" % (real_path, exc))
            return
        if len(raw) > MAX_PAYLOAD:
            log("drop payload %s exceeds %d bytes" % (real_path, MAX_PAYLOAD))
            return
        logical = self.logical_display_for(fields.get("id", ""))
        if logical is None:
            log("no launch record maps composer display %s to an Android display"
                % fields.get("id"))
            return
        self.drop = {"cid": fields.get("id"), "x": fields.get("x", "0"),
                     "y": fields.get("y", "0")}
        if self.pad_press is not None:
            self.to_composer("inject touch up %s" % self.pad_press[0])
            self.pad_press = None
        self.to_android({
            "t": "drop",
            "mime": fields.get("mime", "application/octet-stream"),
            "name": os.path.basename(path),
            "b64": base64.b64encode(raw).decode("ascii"),
            "display": int(logical),
            "x": int(float(self.drop["x"])),
            "y": int(float(self.drop["y"])),
        })
        log("drop of %d bytes on composer display %s -> android display %s"
            % (len(raw), self.drop["cid"], logical))

    def on_composer_clip(self, line):
        """relay a composer clip line to android"""
        fields = {}
        for field in line.split():
            if "=" in field:
                key, value = field.split("=", 1)
                fields[key] = value
        path = fields.get("path")
        mime = fields.get("mime")
        sha256 = fields.get("sha256")
        if not path or not mime or not sha256:
            log("composer clip line lacks path=, mime= or sha256= (%s)" % line)
            return
        if sha256 == self.android_clip_sha256:
            self.host_clip_sha256 = sha256
            return
        real_path = resolve_drop_path(path)
        if real_path is None:
            log("clip path %r resolves outside %s" % (path, HOST_DATA))
            return
        try:
            raw = read_payload(real_path, MAX_PAYLOAD + 1)
        except OSError as exc:
            log("failed to read clip payload %s (%s)" % (real_path, exc))
            return
        if len(raw) > MAX_PAYLOAD:
            log("clip payload %s exceeds %d bytes" % (real_path, MAX_PAYLOAD))
            return
        if hashlib.sha256(raw).hexdigest() != sha256:
            log("clip payload %s does not match sha256=" % real_path)
            return
        self.host_selected("composer", mime, raw)

    def host_selected(self, leg, mime, raw):
        """queue the host selection for android"""
        sha256 = hashlib.sha256(raw).hexdigest()
        self.host_clip_sha256 = sha256
        if sha256 == self.android_clip_sha256:
            return
        wire_mime = "text/plain" if mime in TEXT_MIMES else mime
        if not self.to_android({"t": "clip_set", "mime": wire_mime,
                              "b64": base64.b64encode(raw).decode("ascii")}):
            log("clip %s -> android dropped with no android app (%s, %d bytes)"
                % (leg, wire_mime, len(raw)))
            return
        self.android_clip_sha256 = sha256
        self.android_clip = (wire_mime, base64.b64encode(raw).decode("ascii"))
        log("clip %s -> android %s %d bytes" % (leg, wire_mime, len(raw)))

    def to_composer(self, command):
        """write a command to the composer control fifo"""
        try:
            fd = control_open.open_fifo(HOST_DATA, CONTROL_FIFO, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as exc:
            log("failed to open the control fifo (%s)" % exc)
            return False
        try:
            os.write(fd, (command + "\n").encode("utf-8"))
        finally:
            os.close(fd)
        return True

    def connect_notify_socket(self):
        """bind the socket rhizo-desk-notify connects to"""
        if not self.notifications_enabled:
            log("desktop.notifications is off")
            return
        path = self.args.notify_socket
        if path is None:
            log("--notify-socket is unset")
            return
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        staging = path + ".new"
        try:
            if os.path.lexists(staging):
                os.unlink(staging)
            listener.bind(staging)
            os.chmod(staging, 0o600)
            listener.listen(2)
            os.rename(staging, path)
        except OSError as exc:
            listener.close()
            log("failed to bind notification socket %s (%s %s)"
                % (path, type(exc).__name__, exc))
            return
        listener.setblocking(False)
        self.relay_listener = listener
        self.sel.register(listener, selectors.EVENT_READ, self.on_relay_accept)
        log("notification socket %s bound for rhizo-desk-notify" % path)

    def on_relay_accept(self, _key, _mask=0):
        """accept a rhizo-desk-notify connection"""
        conn, _ = self.relay_listener.accept()
        try:
            relay = Relay(conn)
        except OSError as exc:
            conn.close()
            log("SO_PEERCRED failed for a rhizo-desk-notify connection (%s)" % exc)
            return
        if self.relay_pending is not None:
            self.refuse_relay(self.relay_pending, "replaced by rhizo-desk-notify pid %d before %s existed"
                              % (relay.pid, SESSION_ENV))
        self.relay_pending = relay
        self.check_relay()

    def check_relay(self):
        """register relay_pending when relay.uid is the session.env owner uid"""
        relay = self.relay_pending
        owner = session_env_owner()
        if owner is None:
            log("rhizo-desk-notify pid %d uid %d waits for %s"
                % (relay.pid, relay.uid, SESSION_ENV))
            return
        self.relay_pending = None
        if relay.uid != owner:
            self.refuse_relay(relay, "uid %d is not %s's owner uid %d" % (relay.uid, SESSION_ENV, owner))
            return
        if self.relay is not None:
            old, self.relay = self.relay, None
            self.sel.unregister(old.conn)
            self.refuse_relay(old, "replaced by rhizo-desk-notify pid %d" % relay.pid)
        relay.conn.setblocking(False)
        self.relay = relay
        self.sel.register(relay.conn, selectors.EVENT_READ, self.on_relay_dispatch)
        log("rhizo-desk-notify pid %d uid %d registered" % (relay.pid, relay.uid))

    def refuse_relay(self, relay, reason):
        """write a refused line to relay.conn and close relay.conn"""
        try:
            relay.conn.settimeout(RELAY_REFUSAL_TIMEOUT_S)
            relay.conn.sendall(json.dumps({"t": "refused", "reason": reason}).encode("utf-8") + b"\n")
        except OSError as exc:
            log("failed to write the refused line to rhizo-desk-notify pid %d (%s)" % (relay.pid, exc))
        relay.conn.close()
        log("refused rhizo-desk-notify pid %d (%s)" % (relay.pid, reason))

    def on_relay_dispatch(self, _key, mask=0):
        """flush to or read from rhizo-desk-notify"""
        if mask & selectors.EVENT_WRITE:
            try:
                self.relay.out.flush(self.relay.conn.fileno())
            except OSError as exc:
                self.detach_relay("write failed (%s)" % exc)
                return
        if mask & selectors.EVENT_READ and self.relay is not None:
            self.on_relay()

    def on_relay(self):
        """recv from rhizo-desk-notify and call handle_relay_line for each line"""
        try:
            data = self.relay.conn.recv(65536)
        except OSError as exc:
            self.detach_relay("read failed (%s)" % exc)
            return
        if not data:
            self.detach_relay("recv returned EOF from rhizo-desk-notify pid %d" % self.relay.pid)
            return
        try:
            for line in self.relay.reader.feed(data):
                self.handle_relay_line(json.loads(line.decode("utf-8")))
        except (ValueError, KeyError, TypeError, UnicodeDecodeError, RecursionError) as exc:
            self.detach_relay("bad message from rhizo-desk-notify (%s %s)" % (type(exc).__name__, exc))

    def handle_relay_line(self, msg):
        """parse a line from rhizo-desk-notify and dispatch on msg["t"]"""
        kind = msg["t"]
        if kind == "hello":
            self.relay.bus = bounded_text(msg["bus"], MAX_URI_LEN)
            log("session bus attached bus=%s pid=%d"
                % (self.relay.bus, self.relay.pid))
        elif kind == "notified":
            nid = notification_id(msg["id"])
            key = bounded_text(msg["key"], NOTIFY_KEY_MAX)
            self.notifs.put(key, nid)
            log("notification %s -> desktop id %d" % (key, nid))
        elif kind == "notify_failed":
            log("Notify failed for %s (%s)"
                % (bounded_text(msg["key"], NOTIFY_KEY_MAX), bounded_text(msg["error"], NOTIFY_BODY_MAX)))
        elif kind == "action":
            self.on_notification_action(notification_id(msg["id"]), bounded_text(msg["action"], NOTIFY_ACTION_MAX))
        elif kind == "closed":
            self.on_notification_closed(notification_id(msg["id"]))
        elif kind == "token":
            self.on_activation_token(notification_id(msg["id"]), msg["token"])
        else:
            raise ValueError("unknown message type %r" % kind)

    def on_notification_action(self, nid, action):
        """queue notif_action for the android app and activate the composer display of the package"""
        key = self.notifs.get_key(nid)
        if key is None:
            return
        self.to_android({"t": "notif_action", "key": key, "action": action})
        log("notification %d activated (%s)" % (nid, action))
        token = self.activation_tokens.pop(nid, None)
        if token:
            pkg = self.notif_pkg.get(key)
            cid = self.composer_display_for_package(pkg) if pkg else None
            if cid is None:
                log("dropped the activation token for notification %d with no composer display for pkg=%s" % (nid, pkg))
            else:
                self.to_composer("display activate %s %s" % (cid, token))
                log("activated composer display %s (pkg=%s) with a host token" % (cid, pkg))

    def on_notification_closed(self, nid):
        """forget a closed notification and queue notif_close for the android app"""
        self.activation_tokens.pop(nid, None)
        key = self.notifs.pop_by_id(nid)
        if key is not None:
            self.icons.forget(key)
            self.notif_pkg.pop(key, None)
            self.to_android({"t": "notif_close", "key": key})

    def on_activation_token(self, nid, token):
        """store the activation token of nid"""
        if not token:
            return
        if not isinstance(token, str) or not ACTIVATION_TOKEN_RE.fullmatch(token):
            log("activation token %r for notification %d does not match ACTIVATION_TOKEN_RE"
                % (str(token)[:80], nid))
            return
        self.activation_tokens[nid] = token
        if len(self.activation_tokens) > NOTIF_MAX:
            self.activation_tokens.pop(next(iter(self.activation_tokens)))

    def detach_relay(self, why):
        """close the rhizo-desk-notify connection"""
        self.sel.unregister(self.relay.conn)
        self.relay.conn.close()
        self.relay = None
        log("session bus closed (%s)" % why)

    def to_relay(self, obj, what):
        """queue a line for rhizo-desk-notify"""
        if self.relay is None or self.relay.bus is None:
            log("%s dropped with no session bus" % what)
            return
        if len(self.relay.out.buf) > RELAY_QUEUE_MAX:
            log("desktop notification queue is over %d bytes, dropped %s" % (RELAY_QUEUE_MAX, what))
            return
        self.relay.out.push(json.dumps(obj, separators=(",", ":")).encode("utf-8") + b"\n")

    def notify_desktop(self, msg):
        """queue Notify for an android app notification"""
        key = bounded_text(msg["key"], NOTIFY_KEY_MAX)
        pkg = msg.get("pkg")
        if pkg == "android" and is_system_noise(key):
            return
        if self.relay is None or self.relay.bus is None:
            log("notification from %s dropped with no session bus" % pkg)
            return
        hints = {}
        icon_b64 = msg.get("icon_b64")
        if icon_b64:
            icon_raw = decode_b64_strict(icon_b64)
            if len(icon_raw) > ICON_MAX:
                log("dropped the icon for %s at %d bytes over ICON_MAX %d"
                    % (pkg, len(icon_raw), ICON_MAX))
            else:
                path = self.icons.path_for(key)
                with open(path, "wb") as f:
                    f.write(icon_raw)
                hints["image-path"] = path
        if pkg and PKG_RE.match(pkg):
            hints["desktop-entry"] = "rhizo-%s" % pkg
            self.notif_pkg[key] = pkg
        self.to_relay({"t": "notify", "key": key, "replaces": self.notifs.get_id(key),
                       "title": clip_text(msg.get("title"), NOTIFY_TITLE_MAX),
                       "body": clip_text(msg.get("body"), NOTIFY_BODY_MAX),
                       "actions": ["default", "Open"], "hints": hints}, "Notify for %s" % pkg)

    def close_desktop_notification(self, key):
        """forget a notification and queue CloseNotification"""
        nid = self.notifs.pop_by_key(key)
        self.icons.forget(key)
        self.notif_pkg.pop(key, None)
        if nid is not None:
            self.activation_tokens.pop(nid, None)
        if nid is None or self.relay is None:
            return
        self.to_relay({"t": "close", "id": nid}, "CloseNotification for id %d" % nid)

    def on_accept(self, _key, _mask=0):
        """accept a connection on the socket"""
        conn, addr = self.listener.accept()
        if self.pending is not None:
            self.drop_pending("replaced by a later connection")
        conn.setblocking(False)
        self.pending = conn
        self.pending_reader = LineReader(MAX_PAYLOAD * 2)
        self.pending_deadline = time.monotonic() + PENDING_AUTH_TIMEOUT
        self.pending_challenge = None
        self.sel.register(conn, selectors.EVENT_READ, self.on_pending)
        log("pending connection from %s:%d" % addr)

    def on_pending(self, _key, _mask=0):
        """read data from the pending connection"""
        try:
            data = self.pending.recv(65536)
        except OSError as exc:
            self.drop_pending("read failed (%s)" % exc)
            return
        if not data:
            self.drop_pending("recv returned EOF before auth")
            return
        try:
            for line in self.pending_reader.feed(data):
                self.handle_pending_line(line)
                if self.pending is None:
                    return
        except (ValueError, KeyError, TypeError, UnicodeDecodeError, OSError, RecursionError) as exc:
            self.drop_pending("bad message (%s)" % exc)

    def handle_pending_line(self, line):
        """verify a line from the pending connection"""
        msg = json.loads(line.decode("utf-8"))
        if self.pending_challenge is None:
            self.challenge_pending(msg)
            return
        if msg.get("t") != "auth":
            self.drop_pending("challenge reply t=%r is not auth" % msg.get("t"))
            return
        token, android_nonce, host_nonce = self.pending_challenge
        got = msg.get("proof")
        if not isinstance(got, str) or not hmac.compare_digest(
                got.encode("utf-8", "surrogateescape"),
                desk_proof(token, "android", android_nonce, host_nonce).encode("ascii")):
            self.drop_pending("bad proof")
            return
        self.promote_pending()

    def challenge_pending(self, msg):
        """write the challenge line to the pending connection"""
        if msg.get("t") != "hello":
            self.drop_pending("first message t is not hello")
            return
        android_nonce = msg.get("nonce")
        if not is_nonce(android_nonce):
            self.drop_pending("hello nonce is not %d hex digits" % NONCE_HEX_CHARS)
            return
        token = self.current_token()
        if token is None:
            self.drop_pending("no token in %s" % self.args.token_file)
            return
        host_nonce = os.urandom(NONCE_HEX_CHARS // 2).hex()
        line = json.dumps({"t": "challenge", "nonce": host_nonce,
                           "proof": desk_proof(token, "host", android_nonce, host_nonce)},
                          separators=(",", ":")).encode("ascii") + b"\n"
        sent = self.pending.send(line)
        if sent != len(line):
            self.drop_pending("challenge write was short (%d of %d bytes)" % (sent, len(line)))
            return
        self.pending_challenge = (token, android_nonce, host_nonce)

    def current_token(self):
        """return the authentication token"""
        if self.args.token is not None:
            return self.args.token
        try:
            token = read_raw(self.args.token_file).decode("utf-8").strip()
        except FileNotFoundError:
            return None
        except OSError as exc:
            log("failed to read token file %s (%s)" % (self.args.token_file, exc))
            return None
        return token or None

    def promote_pending(self):
        """set the pending connection as the android connection and queue hello_ok"""
        conn = self.pending
        self.sel.unregister(conn)
        self.pending = None
        self.pending_reader = None
        self.pending_deadline = None
        self.pending_challenge = None
        if self.android is not None:
            self.sel.unregister(self.android)
            self.android.close()
        self.android = conn
        self.android_reader = LineReader(MAX_PAYLOAD * 2)
        self.android_out = OutQueue()
        self.android_ok = True
        self.android_clip_sha256 = None
        self.android_clip = None
        self.sel.register(conn, selectors.EVENT_READ, self.on_android)
        self.to_android({"t": "hello_ok"})
        log("android app authenticated")
        self.control.rearm()
        self.rearm_dragwatch()

    def drop_pending(self, why):
        """unregister and close the pending connection and log why"""
        if self.pending is None:
            return
        log("pending connection dropped (%s)" % why)
        self.sel.unregister(self.pending)
        self.pending.close()
        self.pending = None
        self.pending_reader = None
        self.pending_deadline = None
        self.pending_challenge = None

    def expire_pending(self):
        """drop timed-out pending gets and connections"""
        if self.pending_get_deadline is not None and time.monotonic() >= self.pending_get_deadline:
            log("no wayland bridge data line for the pending get %s" % self.pending_get)
            self.wl_gets.clear()
            self.pending_get = None
            self.pending_get_deadline = None
        if self.pending is None or self.pending_deadline is None:
            return
        if time.monotonic() >= self.pending_deadline:
            self.drop_pending("no auth within %.0fs" % PENDING_AUTH_TIMEOUT)

    def drop_android(self, why):
        """close the com.rhizo.desktop connection"""
        log("android app disconnected (%s)" % why)
        self.sel.unregister(self.android)
        self.android.close()
        self.android = None
        self.android_ok = False
        self.dragout = None

    def to_android(self, obj):
        """queue a message for com.rhizo.desktop"""
        if self.android is None or not self.android_ok:
            return False
        self.android_out.push(json.dumps(obj, separators=(",", ":")).encode("utf-8") + b"\n")
        return True

    def on_android_writable(self, _key, _mask=0):
        """flush buffered output to the android app"""
        self.android_out.flush(self.android.fileno())

    def on_wl_writable(self, _key, _mask=0):
        """flush buffered output to wlbridge"""
        self.wl.out.flush(self.wl.infileno())

    def arm_wl_write(self):
        """register or unregister wlbridge write events"""
        if self.wl_dead:
            return
        want = self.wl.out.pending()
        if want and not self.wl_write_armed:
            self.sel.register(self.wl.infileno(), selectors.EVENT_WRITE, self.on_wl_writable)
            self.wl_write_armed = True
        elif not want and self.wl_write_armed:
            self.sel.unregister(self.wl.infileno())
            self.wl_write_armed = False

    def on_android(self, _key, _mask=0):
        """read data from com.rhizo.desktop"""
        try:
            data = self.android.recv(65536)
        except OSError as exc:
            self.drop_android(str(exc))
            return
        if not data:
            self.drop_android("recv returned EOF")
            return
        try:
            for line in self.android_reader.feed(data):
                self.handle_android_line(line)
        except (ValueError, KeyError, TypeError, UnicodeDecodeError, OSError, RecursionError) as exc:
            self.drop_android("bad message (%s)" % exc)

    def handle_android_line(self, line):
        """parse a message from com.rhizo.desktop"""
        msg = json.loads(line.decode("utf-8"))
        kind = msg.get("t")
        if kind == "clip_set":
            self.clip_from_android(msg)
        elif kind == "open":
            self.open_on_host(msg)
        elif kind == "notify":
            self.notify_desktop(msg)
        elif kind == "notif_gone":
            self.close_desktop_notification(msg["key"])
        elif kind == "drop_pad":
            self.press_on_pad(msg)
        elif kind == "drag_armed":
            self.pad_press = None
            self.finish_drag()
        elif kind == "dragwatch_ready":
            if not all(k in msg for k in ("display", "x", "y")):
                log("dragwatch_ready without display, x or y (%r)" % (msg,))
            else:
                self.pads[int(msg["display"])] = (int(float(msg["x"])), int(float(msg["y"])))
                log("drag-out pad ready on android display %s at %s,%s"
                    % (msg["display"], msg["x"], msg["y"]))
        elif kind == "dragwatch_error":
            log("dragwatch_error on android display %s (%s)" % (msg.get("display"), msg.get("reason")))
            self.pads.pop(msg.get("display"), None)
            self.cid_by_display.pop(msg.get("display"), None)
        elif kind == "drag_started":
            self.on_android_drag_started(msg)
        elif kind == "drag_data":
            self.on_android_drag_data(msg)
        elif kind == "drag_ended":
            log("android drag ended (result=%s)" % msg.get("result"))
            ended = [msg["display"]] if "display" in msg else list((self.dragout or {}).get("cids", ()))
            self.dragout = None
            for ended_on in ended:
                if ended_on in self.cid_by_display:
                    self.to_android({"t": "dragwatch", "display": ended_on})
        elif kind == "drag_data_error":
            log("drag_data_error (%s)" % msg.get("reason"))
        elif kind == "drop_error":
            log("drop_error (%s)" % msg.get("reason"))
            self.drop = None
        elif kind == "ping":
            self.to_android({"t": "pong"})
        else:
            log("unknown android message type %r" % kind)

    def clip_from_android(self, msg):
        """set the host clipboard from a clip_set"""
        mime = msg["mime"]
        b64 = msg["b64"]
        require_mime(mime)
        raw = decode_b64_strict(b64)
        if len(raw) > MAX_PAYLOAD:
            log("clip from android is %d bytes, over MAX_PAYLOAD" % len(raw))
            return
        sha256 = hashlib.sha256(raw).hexdigest()
        self.android_clip_sha256 = sha256
        self.android_clip = (mime, b64)
        if sha256 == self.host_clip_sha256:
            return
        self.host_clip_sha256 = sha256
        if self.wl_dead:
            log("clip android -> host on the composer leg with rhizo-wlbridge exited")
        elif not self.wl_clipboard:
            log("clip android -> host %s %d bytes on the composer leg" % (mime, len(raw)))
        else:
            self.wl_host_gen += 1
            self.wl.set(mime, b64)
            log("clip android -> host %s %d bytes" % (mime, len(raw)))
        self.clip_cid_seq += 1
        self.to_composer("clip set %d %s %s" % (self.clip_cid_seq, mime, b64))

    def open_failed(self, uri, why):
        """queue open_failed for com.rhizo.desktop"""
        self.to_android({"t": "open_failed", "uri": uri[:MAX_URI_LEN], "why": why})

    def open_on_host(self, msg):
        """open a link with xdg-open"""
        uri = msg["uri"]
        if len(uri) > MAX_URI_LEN:
            log("open uri is %d characters, over MAX_URI_LEN %d"
                % (len(uri), MAX_URI_LEN))
            self.open_failed(uri, "the link is over %d characters" % MAX_URI_LEN)
            return
        m = URI_RE.match(uri)
        scheme = m.group(0)[:-1].lower() if m else None
        if scheme not in self.uri_schemes:
            log("open uri scheme %r is not in the allowlist %s (%s)"
                % (scheme, sorted(self.uri_schemes), uri[:120]))
            self.open_failed(uri, "scheme %s is not in desktop.open_uri" % (scheme or "scheme-less"))
            return
        now = time.monotonic()
        self.open_times = [t for t in self.open_times if now - t < OPEN_RATE_WINDOW]
        if len(self.open_times) >= OPEN_RATE_LIMIT:
            log("open rate-limited (%d in %.0fs), refused %s"
                % (len(self.open_times), OPEN_RATE_WINDOW, uri[:120]))
            self.open_failed(uri, "rate-limited")
            return
        self.open_times.append(now)
        opener = shutil.which("xdg-open")
        if opener is None:
            log("no xdg-open in PATH for %s" % uri)
            self.open_failed(uri, "no xdg-open in PATH")
            return
        child = subprocess.Popen(
            [opener, uri],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.openers.append((child, uri))
        log("open android -> host %s" % uri)

    def repress_when_due(self):
        """press the drag pad again when due"""
        if self.pad_press is None:
            return
        cid, x, y, attempts, when = self.pad_press
        if time.monotonic() < when:
            return
        if attempts >= 5:
            log("no drag_armed after %d presses" % attempts)
            self.pad_press = None
            return
        self.to_composer("inject touch up %s" % cid)
        self.to_composer("inject touch down %s %s %s" % (cid, x, y))
        self.pad_press = (cid, x, y, attempts + 1, time.monotonic() + 0.4)

    def lift_when_due(self):
        """lift the pending touches when due"""
        if self.pending_up is None:
            return
        cids, when = self.pending_up
        if time.monotonic() < when:
            return
        self.pending_up = None
        for cid in cids:
            self.to_composer("inject touch up %s" % cid)
        log("inject touch up on composer displays %s" % ", ".join(cids))

    def reap_openers(self):
        """collect finished xdg-open children"""
        still = []
        for child, uri in self.openers:
            rc = child.poll()
            if rc is None:
                still.append((child, uri))
                continue
            if rc != 0:
                err = child.stderr.read().decode("utf-8", "replace").strip()
                log("xdg-open failed for %s rc=%d %s" % (uri, rc, err))
                self.open_failed(uri, err or "xdg-open failed with exit status %d" % rc)
            else:
                log("xdg-open opened %s" % uri)
            child.stderr.close()
        self.openers = still

    def press_on_pad(self, msg):
        """press the drop pad through the composer"""
        if self.drop is None:
            log("drop_pad with no drop in flight")
            return
        x = int(float(msg["x"]))
        y = int(float(msg["y"]))
        if self.pad_press is not None and self.pad_press[:3] == (self.drop["cid"], x, y):
            log("drop_pad repeated with the pad press in flight")
            return
        self.to_composer("inject touch down %s %s %s" % (self.drop["cid"], x, y))
        self.pad_press = (self.drop["cid"], x, y, 0, time.monotonic() + 0.4)

    def finish_drag(self):
        """move the touch to the drop point and schedule the touch up"""
        if self.drop is None:
            return
        self.to_composer("inject touch move %s %s %s"
                         % (self.drop["cid"], self.drop["x"], self.drop["y"]))
        self.pending_up = ((self.drop["cid"],), time.monotonic() + 0.35)
        log("inject touch move to %s,%s on composer display %s"
            % (self.drop["x"], self.drop["y"], self.drop["cid"]))
        self.drop = None

    def on_android_drag_started(self, msg):
        """move the composer touch to the drag pad"""
        reported = msg.get("display")
        cid = self.cid_by_display.get(reported)
        pad = self.pads.get(reported)
        if cid is None or pad is None:
            log("drag_started on display %s with no %s"
                % (reported, "composer display" if cid is None else "drag-out pad"))
            return
        if self.dragout is None:
            self.dragout = {"cids": {}, "mimes": msg.get("mimes") or []}
        self.dragout["cids"][reported] = cid
        self.to_composer("inject touch move %s %s %s" % (cid, pad[0], pad[1]))
        due = self.pending_up[0] if self.pending_up else ()
        cids = tuple(dict.fromkeys(due + tuple(self.dragout["cids"].values())))
        self.pending_up = (cids, time.monotonic() + 0.35)

    def on_android_drag_data(self, msg):
        """write the dragged payload to the composer"""
        mime = msg["mime"]
        b64 = msg["b64"]
        require_mime(mime)
        raw = decode_b64_strict(b64)
        cid = self.cid_by_display.get(msg.get("display"))
        if cid is None:
            cids = set((self.dragout or {}).get("cids", {}).values())
            cid = cids.pop() if len(cids) == 1 else None
        if cid is None:
            log("drag_data with no composer display")
            return
        if len(raw) > MAX_PAYLOAD:
            log("drag payload of %d bytes exceeds MAX_PAYLOAD" % len(raw))
            return
        self.to_composer("drag start %s %s %s" % (cid, mime, b64))
        log("drag android -> host %s %d bytes" % (mime, len(raw)))

    def on_wl(self, _key, _mask=0):
        """read data from rhizo-wlbridge"""
        data = os.read(self.wl.fileno(), 65536)
        if not data:
            log("rhizo-wlbridge exited")
            self.sel.unregister(self.wl.fileno())
            if self.wl_write_armed:
                self.sel.unregister(self.wl.infileno())
                self.wl_write_armed = False
            self.wl_dead = True
            self.replay_held_composer_line()
            self.hand_clip_to_composer()
            self.reap_wlbridge()
            if not self.wl.reaped:
                self.watch_wlbridge_exit()
            if self.wl_session_write != self.session_writes:
                self.restart_wlbridge()
            return
        for line in self.wl.reader.feed(data):
            self.handle_wl_line(line.decode("utf-8", "replace"))

    def hand_clip_to_composer(self):
        """write the android app clip to the composer"""
        if not self.wl_clipboard:
            log("composer leg has the android clip with wl_clipboard false")
            return
        if self.android_clip is None or self.host_clip_sha256 != self.android_clip_sha256:
            log("no android clip for the composer leg, host_clip_sha256 differs")
            return
        mime, b64 = self.android_clip
        self.clip_cid_seq += 1
        self.to_composer("clip set %d %s %s" % (self.clip_cid_seq, mime, b64))
        log("clip set %s on the composer leg" % mime)

    def watch_wlbridge_exit(self):
        """open a pidfd for the rhizo-wlbridge process"""
        try:
            self.wl.pidfd = os.pidfd_open(self.wl.proc.pid)
        except OSError as e:
            log("pidfd_open failed for rhizo-wlbridge (%s)" % e)
            return
        self.sel.register(self.wl.pidfd, selectors.EVENT_READ, self.on_wl_exit)

    def on_wl_exit(self, _key, _mask=0):
        """reap the exited wlbridge"""
        self.reap_wlbridge()

    def reap_wlbridge(self):
        """reap the exited rhizo-wlbridge process"""
        if not self.wl_dead or self.wl.reaped:
            return
        rc = self.wl.proc.poll()
        if rc is None:
            return
        self.wl.reaped = True
        if self.wl.pidfd is not None:
            self.sel.unregister(self.wl.pidfd)
            os.close(self.wl.pidfd)
            self.wl.pidfd = None
        for pipe in (self.wl.proc.stdin, self.wl.proc.stdout):
            try:
                pipe.close()
            except OSError:
                pass
        log("rhizo-wlbridge reaped rc=%d" % rc)

    def handle_wl_line(self, line):
        """parse a line from rhizo-wlbridge"""
        word, _, rest = line.partition(" ")
        if word == "ready":
            self.wl.ready = True
            log("wayland bridge ready")
            if not self.wl_clipboard:
                self.replay_held_composer_line()
            elif self.held_composer_line is not None:
                self.held_composer_line = None
                log("dropped held_composer_line")
        elif word == "noclipboard":
            self.wl_clipboard = False
            log("wayland bridge noclipboard (%s)" % rest)
        elif word == "selection":
            self.wl_host_gen += 1
            self.on_selection(rest.split())
        elif word == "data":
            fields = rest.split(" ")
            if len(fields) != 3:
                log("dropped a rhizo-wlbridge data line without a tag")
                return
            mime, b64, tag = fields
            asked = self.wl_get_answered(tag)
            if asked is None:
                log("dropped a rhizo-wlbridge data line for %s with a tag not in wl_gets" % mime)
            elif asked != self.wl_host_gen:
                log("dropped a rhizo-wlbridge data line for %s from a replaced selection" % mime)
            else:
                self.clip_to_android(mime, b64)
        elif word == "nodata":
            log("rhizo-wlbridge nodata %s" % rest)
            fields = rest.split(" ")
            if len(fields) == 2:
                self.wl_get_answered(fields[1])
        elif word == "error":
            log("wayland bridge error %s" % rest)
            fields = rest.split(" ", 2)
            if len(fields) >= 2 and fields[0] == "get":
                self.wl_get_answered(fields[1])

    def wl_get_answered(self, tag):
        """pop tag from wl_gets and return the wl_host_gen value of tag"""
        asked = self.wl_gets.pop(tag, None)
        if not self.wl_gets:
            self.pending_get = None
            self.pending_get_deadline = None
        return asked

    def on_selection(self, mimes):
        """queue a get for the host selection"""
        if mimes == ["none"]:
            self.host_clip_sha256 = None
            return
        if PASSWORD_HINT_MIME in mimes:
            self.host_clip_sha256 = None
            log("host selection offers %s, dropped" % PASSWORD_HINT_MIME)
            return
        want = self.pick_mime(mimes)
        if want is None:
            self.host_clip_sha256 = None
            log("host selection offers no TEXT_MIMES or IMAGE_MIMES type (%s)" % " ".join(mimes))
            return
        self.pending_get = want
        self.wl_get_seq += 1
        self.wl_gets[str(self.wl_get_seq)] = self.wl_host_gen
        self.pending_get_deadline = time.monotonic() + 65
        self.wl.get(want, self.wl_get_seq)

    def pick_mime(self, mimes):
        """return the first supported mime type offered"""
        for m in TEXT_MIMES + IMAGE_MIMES:
            if m in mimes:
                return m
        return None

    def clip_to_android(self, mime, b64):
        """call host_selected with the decoded host clipboard data"""
        self.host_selected("host", mime, base64.b64decode(b64))

    def run(self):
        """run the event loop"""
        while True:
            self.arm_wl_write()
            if self.relay is not None:
                self.sel.modify(
                    self.relay.conn,
                    selectors.EVENT_READ | (selectors.EVENT_WRITE if self.relay.out.pending() else 0),
                    self.on_relay_dispatch,
                )
            if self.android is not None:
                self.sel.modify(
                    self.android,
                    selectors.EVENT_READ
                    | (selectors.EVENT_WRITE if self.android_out.pending() else 0),
                    self.on_android_dispatch,
                )
            timeout = None
            if self.openers or (self.wl_dead and not self.wl.reaped and self.wl.pidfd is None):
                timeout = 1
            for due_pair in (self.pending_up, self.pad_press):
                if due_pair is not None:
                    due = max(0.0, due_pair[-1] - time.monotonic())
                    timeout = due if timeout is None else min(timeout, due)
            for due_at in (self.pending_deadline, self.pending_get_deadline):
                if due_at is not None:
                    due = max(0.0, due_at - time.monotonic())
                    timeout = due if timeout is None else min(timeout, due)
            for key, mask in self.sel.select(timeout):
                key.data(key, mask)
            self.reap_openers()
            self.reap_wlbridge()
            self.lift_when_due()
            self.repress_when_due()
            self.expire_pending()

    def on_android_dispatch(self, key, mask=0):
        """flush to or read from the android app"""
        if mask & selectors.EVENT_WRITE:
            self.on_android_writable(key)
        if mask & selectors.EVENT_READ and self.android is not None:
            self.on_android(key)


def main():
    """parse arguments and run Deskd"""
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    tok = ap.add_mutually_exclusive_group(required=True)
    tok.add_argument("--token")
    tok.add_argument("--token-file")
    ap.add_argument("--bridge", required=True)
    ap.add_argument("--bind", default="192.168.%d.1" % (100 + SANDBOX_ID))
    ap.add_argument("--notify-socket")
    args = ap.parse_args()
    Deskd(args).run()


if __name__ == "__main__":
    main()
