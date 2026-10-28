#!/usr/bin/env python3
"""run dmesg, loop and mount operations in the caller's SELinux domain"""
import ctypes
import errno
import os
import sys

USAGE = """usage: hostops.py dmesg
       hostops.py kmsg-follow
       hostops.py loop-attach [-r] FILE
       hostops.py loop-find FILE
       hostops.py loop-detach DEV
       hostops.py mount [-r] -t TYPE [-o DATA] SRC DIR
       hostops.py umount [-l | -b] DIR
       hostops.py is-mount DIR
"""

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.join(HERE, "..", "..", "androidd")]
from sandbox import core  # noqa: E402

PROG = "rhizo-hostops"
KMSG_FOLLOW_BACKLOG = 10


def fail(msg, rc=1):
    """print msg to stderr and return rc"""
    print(f"{PROG}: {msg}", file=sys.stderr)
    return rc


def dmesg():
    """print the kernel log in dmesg's format"""
    for usec, msg in core.kmsg_records():
        print(f"[{usec // 1000000:5d}.{usec % 1000000:06d}] {msg}")
    return 0


def kmsg_follow():
    """print the last and each new kernel message"""
    for _usec, msg in core.kmsg_records(follow=True, backlog=KMSG_FOLLOW_BACKLOG):
        print(msg, flush=True)
    return 0


def mount(args):
    """mount SRC at DIR with a filesystem type and optional data"""
    fstype = data = None
    flags = 0
    while len(args) > 2 and args[0] in ("-r", "-t", "-o"):
        if args[0] == "-r":
            flags, args = core.MS_RDONLY, args[1:]
            continue
        if args[0] == "-t":
            fstype = args[1]
        else:
            data = args[1]
        args = args[2:]
    if fstype is None or len(args) != 2:
        return fail("mount takes [-r] -t TYPE [-o DATA] SRC DIR", 2)
    if core.libc.mount(args[0].encode(), args[1].encode(), fstype.encode(), flags,
                            data.encode() if data else None) != 0:
        return fail(f"mount {args[0]} at {args[1]}: {os.strerror(ctypes.get_errno())}")
    return 0


def umount(args):
    """unmount a directory"""
    if not args or len(args) > 2 or (len(args) == 2 and args[0] not in ("-l", "-b")):
        return fail("umount takes [-l|-b] DIR", 2)
    mode = args[0] if len(args) == 2 else ""
    path = args[-1].encode()
    if core.libc.umount2(path, 2 if mode == "-l" else 0) == 0:
        return 0
    err = ctypes.get_errno()
    if mode == "-b" and err == errno.EBUSY and core.libc.umount2(path, 2) == 0:
        return 0
    return fail(f"umount {args[-1]}: {os.strerror(err)}")


def is_mount(args):
    """exit 0 when mountinfo lists the directory as a mount point"""
    if len(args) != 1:
        return fail("is-mount takes DIR", 2)
    return 0 if core.is_mount_point(args[0]) else 1


def main(argv):
    """run an operation"""
    if not argv:
        return fail(USAGE.strip(), 2)
    verb, args = argv[0], argv[1:]
    try:
        if verb == "dmesg" and not args:
            return dmesg()
        if verb == "kmsg-follow" and not args:
            return kmsg_follow()
        if verb == "loop-attach" and (len(args) == 1 or (len(args) == 2 and args[0] == "-r")):
            dev, fd = core.loop_attach(args[-1], read_only=args[0] == "-r")
            os.close(fd)
            print(dev)
            return 0
        if verb == "loop-find" and len(args) == 1:
            for dev in core.loops_backed_by(os.path.realpath(args[0])):
                print(dev)
            return 0
        if verb == "loop-detach" and len(args) == 1:
            core.loop_detach(args[0])
            return 0
        if verb == "mount":
            return mount(args)
        if verb == "umount":
            return umount(args)
        if verb == "is-mount":
            return is_mount(args)
    except (OSError, ValueError) as e:
        return fail(f"{verb} {' '.join(args)}: {e}")
    return fail(f"unknown operation {argv}", 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
