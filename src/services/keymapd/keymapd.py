#!/usr/bin/env python3

import base64
import ctypes
import os
import select
import sys
import time

_here = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [_here, os.path.join(_here, ".."), os.path.join(_here, "..", "common")]
import control_open  # noqa: E402


def _instanced(base, sandbox_id, sep="-"):
    """return base for sandbox_id 0, else base, sep and sandbox_id"""
    return base if sandbox_id == 0 else "%s%s%d" % (base, sep, sandbox_id)


SANDBOX_ID = int(os.environ.get("RHIZO_SANDBOX_ID", "0"))
SANDBOX_DATA = "/data/"
HOST_DATA = _instanced("/run/rhizo", SANDBOX_ID) + "/data/"
CONTROL_DIR = HOST_DATA + "rhizo_control"
CONTROL_OUT = CONTROL_DIR + "/control.out"
CONTROL_FIFO = CONTROL_DIR + "/control"

IN_CREATE = 0x00000100


def log(msg):
    """write a timestamped message to stderr"""
    sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()



def read_from(fd, offset=0):
    """read fd from offset to EOF and close fd"""
    try:
        chunks = []
        while True:
            chunk = os.pread(fd, 65536, offset)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
            offset += len(chunk)
    finally:
        os.close(fd)


def fnv1a32(data):
    """return the FNV-1a 32-bit hash of data"""
    h = 2166136261
    for b in data:
        h ^= b
        h = (h * 16777619) & 0xFFFFFFFF
    return h


class Xkb:
    """ctypes binding for libxkbcommon"""

    FORMAT_TEXT_V1 = 1
    MASK_SHIFT = 1 << 0
    MASK_ALTGR = 1 << 7

    def __init__(self):
        """load libxkbcommon and set the ctypes signatures"""
        lib = ctypes.CDLL("libxkbcommon.so.0")
        lib.xkb_context_new.restype = ctypes.c_void_p
        lib.xkb_keymap_new_from_string.restype = ctypes.c_void_p
        lib.xkb_keymap_new_from_string.argtypes = [
            ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
        lib.xkb_state_new.restype = ctypes.c_void_p
        lib.xkb_state_new.argtypes = [ctypes.c_void_p]
        lib.xkb_state_update_mask.argtypes = [ctypes.c_void_p] + [ctypes.c_uint32] * 6
        lib.xkb_state_key_get_utf8.restype = ctypes.c_int
        lib.xkb_state_key_get_utf8.argtypes = [
            ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]
        lib.xkb_keymap_min_keycode.restype = ctypes.c_uint32
        lib.xkb_keymap_min_keycode.argtypes = [ctypes.c_void_p]
        lib.xkb_keymap_max_keycode.restype = ctypes.c_uint32
        lib.xkb_keymap_max_keycode.argtypes = [ctypes.c_void_p]
        lib.xkb_keymap_unref.argtypes = [ctypes.c_void_p]
        lib.xkb_state_unref.argtypes = [ctypes.c_void_p]
        self.lib = lib
        self.ctx = lib.xkb_context_new(0)
        if not self.ctx:
            raise RuntimeError("xkb_context_new failed")

    def resolve(self, keymap_text):
        """return the four level strings of each evdev code in keymap_text"""
        km = self.lib.xkb_keymap_new_from_string(
            self.ctx, keymap_text.encode("utf-8"), self.FORMAT_TEXT_V1, 0)
        if not km:
            raise ValueError("xkb_keymap_new_from_string failed")
        state = self.lib.xkb_state_new(km)
        buf = ctypes.create_string_buffer(32)

        def get(xkbcode, mask):
            """return the UTF-8 text of xkbcode under mask"""
            self.lib.xkb_state_update_mask(state, mask, 0, 0, 0, 0, 0)
            n = self.lib.xkb_state_key_get_utf8(state, xkbcode, buf, len(buf))
            s = buf.raw[:n].decode("utf-8", "replace") if n > 0 else ""
            if len(s) == 1 and (ord(s) < 0x20 or ord(s) == 0x7F):
                return ""
            return s

        entries = {}
        for xkbcode in range(self.lib.xkb_keymap_min_keycode(km),
                              self.lib.xkb_keymap_max_keycode(km) + 1):
            evdev = xkbcode - 8
            if evdev < 0 or evdev > 0xFFFF:
                continue
            levels = [get(xkbcode, 0), get(xkbcode, self.MASK_SHIFT),
                      get(xkbcode, self.MASK_ALTGR), get(xkbcode, self.MASK_SHIFT | self.MASK_ALTGR)]
            if any(levels):
                entries[evdev] = levels
        self.lib.xkb_state_unref(state)
        self.lib.xkb_keymap_unref(km)
        return entries


def encode_table(entries):
    """pack scancode entries for the control channel"""
    buf = bytearray()
    for code, levels in entries.items():
        buf += code.to_bytes(2, "little")
        for s in levels:
            b = s.encode("utf-8")
            buf += bytes([len(b)]) + b
    return bytes(buf)


class KeymapWatch:
    """inotify watch on CONTROL_DIR and offset into CONTROL_OUT"""

    def __init__(self):
        """add an IN_CREATE inotify watch on CONTROL_DIR"""
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.fd = self.libc.inotify_init1(0o4000)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        self.offset = 0
        try:
            dirfd = control_open.open_dir(HOST_DATA, CONTROL_DIR)
        except OSError as exc:
            log("failed to open %s (%s)" % (CONTROL_DIR, exc))
            return
        try:
            wd = self.libc.inotify_add_watch(self.fd, control_open.watch_path(dirfd).encode(), IN_CREATE)
        finally:
            os.close(dirfd)
        if wd < 0:
            log("inotify_add_watch %s failed (%s)" % (CONTROL_DIR, os.strerror(ctypes.get_errno())))

    def fileno(self):
        """return the inotify file descriptor"""
        return self.fd

    def drain(self):
        """read and discard pending bytes"""
        try:
            os.read(self.fd, 65536)
        except BlockingIOError:
            pass

    def new_lines(self):
        """return the lines of CONTROL_OUT past self.offset"""
        try:
            fd = control_open.open_reply(HOST_DATA, CONTROL_OUT)
        except FileNotFoundError:
            return []
        except OSError as exc:
            control_open.refused_once(CONTROL_OUT, exc, log)
            return []
        if os.fstat(fd).st_size < self.offset:
            self.offset = 0
        data = read_from(fd, self.offset)
        self.offset += len(data)
        return data.decode("utf-8", "replace").splitlines()


def parse_keymap_ready(line):
    """parse a keymap ready line into (digest, path), or None"""
    if not line.startswith("keymap ready "):
        return None
    fields = dict(t.split("=", 1) for t in line.split(" ") if "=" in t)
    try:
        return int(fields["digest"]), fields["path"]
    except (KeyError, ValueError):
        return None


def sandbox_to_host(path):
    """return the host path of a sandbox /data/ path, or None"""
    if not path.startswith(SANDBOX_DATA):
        return None
    return HOST_DATA + path[len(SANDBOX_DATA):]


def send_table(digest, table_bytes):
    """write a keymap table line to CONTROL_FIFO"""
    line = "keymap table %d %s\n" % (digest, base64.b64encode(table_bytes).decode("ascii"))
    fd = control_open.open_fifo(HOST_DATA, CONTROL_FIFO, os.O_WRONLY)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)


def resolve_and_send(xkb, digest, sandbox_path):
    """write the resolved table of a keymap file to CONTROL_FIFO"""
    host_path = sandbox_to_host(sandbox_path)
    if host_path is None:
        log("keymap path %s is not under %s" % (sandbox_path, SANDBOX_DATA))
        return
    raw = read_from(control_open.open_payload(HOST_DATA, host_path))
    if fnv1a32(raw) != digest:
        log("keymap %s does not match digest" % host_path)
        return
    entries = xkb.resolve(raw.decode("utf-8"))
    send_table(digest, encode_table(entries))
    log("wrote %d entries for keymap digest %d" % (len(entries), digest))


def main():
    """write a resolved keymap table for each keymap ready line"""
    xkb = Xkb()
    watch = KeymapWatch()
    resolved_digest = [None]

    def handle(line):
        """resolve and write the keymap of a keymap ready line"""
        parsed = parse_keymap_ready(line)
        if not parsed or parsed[0] == resolved_digest[0]:
            return
        try:
            resolve_and_send(xkb, *parsed)
            resolved_digest[0] = parsed[0]
        except (OSError, ValueError) as e:
            log("failed to resolve keymap digest %d (%s)" % (parsed[0], e))

    latest = None
    for line in watch.new_lines():
        if parse_keymap_ready(line):
            latest = line
    if latest:
        handle(latest)

    log("watching %s for keymap ready lines" % CONTROL_OUT)
    while True:
        r, _, _ = select.select([watch], [], [], 5.0)
        if r:
            watch.drain()
        for line in watch.new_lines():
            handle(line)


if __name__ == "__main__":
    main()
