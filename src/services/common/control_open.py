"""openat2 opens of the control paths under host_data with RESOLVE_NO_SYMLINKS and RESOLVE_BENEATH"""
import ctypes
import errno
import os
import stat
import struct

ANDROID_SYSTEM_UID = 1000
OPENAT2_SYSCALL = 437
RESOLVE_NO_MAGICLINKS = 0x02
RESOLVE_NO_SYMLINKS = 0x04
RESOLVE_BENEATH = 0x08
DIR_FLAGS = os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC
READ_FLAGS = os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC
_refusals = {}


def refuse(why):
    """return OSError(EPERM, why)"""
    return OSError(errno.EPERM, why)


def openat2_beneath(dirfd, relpath, flags):
    """call openat2 on relpath under dirfd with RESOLVE_NO_SYMLINKS, RESOLVE_NO_MAGICLINKS and RESOLVE_BENEATH"""
    how = ctypes.create_string_buffer(struct.pack(
        "QQQ", flags | os.O_CLOEXEC, 0, RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS | RESOLVE_BENEATH))
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    fd = libc.syscall(ctypes.c_long(OPENAT2_SYSCALL), ctypes.c_long(dirfd), relpath.encode(), how,
                      ctypes.c_size_t(len(how)))
    if fd < 0:
        err = ctypes.get_errno()
        if err in (errno.ELOOP, errno.EXDEV):
            raise OSError(err, "openat2 with RESOLVE_NO_SYMLINKS and RESOLVE_BENEATH failed for %s" % relpath)
        raise OSError(err, os.strerror(err))
    return fd


def open_beneath(host_data, path, flags):
    """open path under host_data with openat2_beneath"""
    rel = os.path.relpath(path, host_data)
    base = os.open(host_data, os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        return openat2_beneath(base, rel, flags)
    finally:
        os.close(base)


def check_fifo(st, uid):
    """raise OSError unless st is a fifo with st_uid == uid and no mode bit outside 0o666"""
    if not stat.S_ISFIFO(st.st_mode):
        raise refuse("the control path is not a fifo")
    if st.st_uid != uid:
        raise refuse("the control fifo st_uid is %d, not %d" % (st.st_uid, uid))
    if stat.S_IMODE(st.st_mode) & ~0o666:
        raise refuse("the control fifo has mode %o" % stat.S_IMODE(st.st_mode))


def check_reply(st, uid):
    """raise OSError unless st is a regular file with st_uid == uid"""
    if not stat.S_ISREG(st.st_mode):
        raise refuse("the control reply path is not a regular file")
    if st.st_uid != uid:
        raise refuse("the control reply file st_uid is %d, not %d" % (st.st_uid, uid))


def check_regular(st, uid):
    """raise OSError unless st is a regular file"""
    if not stat.S_ISREG(st.st_mode):
        raise refuse("the path is not a regular file")


def open_checked(host_data, path, flags, check, uid):
    """open path if check passes on the O_PATH probe and the opened fd, and probe and fd st_dev and st_ino match"""
    probe = open_beneath(host_data, path, os.O_PATH)
    try:
        first = os.fstat(probe)
    finally:
        os.close(probe)
    check(first, uid)
    fd = open_beneath(host_data, path, flags | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        check(st, uid)
        if (st.st_dev, st.st_ino) != (first.st_dev, first.st_ino):
            raise refuse("the opened file st_dev and st_ino differ from the O_PATH probe")
    except OSError:
        os.close(fd)
        raise
    return fd


def open_fifo(host_data, path, flags, uid=None):
    """open the control fifo, and clear O_NONBLOCK on the fd unless flags has O_NONBLOCK"""
    fd = open_checked(host_data, path, flags, check_fifo, ANDROID_SYSTEM_UID if uid is None else uid)
    if not flags & os.O_NONBLOCK:
        os.set_blocking(fd, True)
    return fd


def open_reply(host_data, path, uid=None):
    """open control.out for reading"""
    return open_checked(host_data, path, READ_FLAGS, check_reply, ANDROID_SYSTEM_UID if uid is None else uid)


def open_payload(host_data, path):
    """open a regular file under host_data for reading"""
    return open_checked(host_data, path, READ_FLAGS, check_regular, None)


def open_dir(host_data, path):
    """open a directory under host_data as an O_PATH descriptor"""
    return open_beneath(host_data, path, DIR_FLAGS)


def watch_path(fd):
    """return /proc/self/fd/<fd>"""
    return "/proc/self/fd/%d" % fd


def refused_once(key, exc, log):
    """log key and str(exc) unless _refusals[key] == str(exc)"""
    text = str(exc)
    if _refusals.get(key) != text:
        _refusals[key] = text
        log("failed to open %s (%s)" % (key, text))
