#!/usr/bin/env python3
import ctypes
import os
import struct
import sys
import time

IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_MOVED_FROM = 0x00000040
IN_MOVED_TO = 0x00000080
IN_DELETE_SELF = 0x00000400
IN_MOVE_SELF = 0x00000800
MASK = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_DELETE_SELF | IN_MOVE_SELF

EVENT_HDR = struct.Struct("iIII")


def log(msg):
    """print a message with the service name prefix"""
    print(f"[rhizo-app-events] {msg}", flush=True)


class Inotify:
    def __init__(self):
        """open an inotify descriptor"""
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self.fd = self.libc.inotify_init()
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init failed")

    def add(self, path):
        """add an inotify watch on a path"""
        wd = self.libc.inotify_add_watch(self.fd, path.encode(), MASK)
        if wd < 0:
            err = ctypes.get_errno()
            raise OSError(err, f"inotify_add_watch({path}) failed: {os.strerror(err)}"
                               + (" -- not running as the directory's owner" if err == 13 else ""))
        return wd

    def read_events(self):
        """read the pending inotify events"""
        buf = os.read(self.fd, 8192)
        off = 0
        while off + EVENT_HDR.size <= len(buf):
            _wd, mask, _cookie, nlen = EVENT_HDR.unpack_from(buf, off)
            name = buf[off + EVENT_HDR.size:off + EVENT_HDR.size + nlen].rstrip(b"\0")
            off += EVENT_HDR.size + nlen
            yield mask, name


def touch(path):
    """write the time to the trigger file"""
    with open(path, "w") as fh:
        fh.write(f"{time.time()}\n")
        fh.flush()
        os.fsync(fh.fileno())


def enqueue(queue, name):
    """append a directory name to the queue file"""
    if not name or b"\n" in name or b"/" in name:
        return
    fd = os.open(queue, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, name + b"\n")
    finally:
        os.close(fd)


def main():
    """watch /data/app and touch the trigger file"""
    watch_dir = sys.argv[1] if len(sys.argv) > 1 else "/run/rhizo/data/app"
    trigger = sys.argv[2] if len(sys.argv) > 2 else "/run/rhizo-app-events/trigger"
    queue = os.path.join(os.path.dirname(trigger), "queue")

    log(f"uid={os.getuid()} watching {watch_dir} -> {trigger}")
    os.makedirs(os.path.dirname(trigger), exist_ok=True)

    while True:
        if not os.path.isdir(watch_dir):
            time.sleep(1)
            continue
        try:
            ino = Inotify()
            wd = ino.add(watch_dir)
        except OSError as e:
            log(f"could not watch {watch_dir}: {e}; retrying in 2s")
            time.sleep(2)
            continue

        log(f"watch established on {watch_dir} (wd={wd}, ino={os.stat(watch_dir).st_ino})")
        touch(trigger)

        try:
            while True:
                for mask, name in ino.read_events():
                    if mask & (IN_DELETE_SELF | IN_MOVE_SELF):
                        raise StopIteration
                    if mask & (IN_CREATE | IN_MOVED_TO):
                        enqueue(queue, name)
                    touch(trigger)
        except StopIteration:
            log(f"{watch_dir} was replaced (new mount?); re-arming")
        except OSError as e:
            log(f"read error on the watch: {e}; re-arming")
        finally:
            try:
                os.close(ino.fd)
            except OSError:
                pass


if __name__ == "__main__":
    main()
