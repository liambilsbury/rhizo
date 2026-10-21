#!/usr/bin/env python3
import errno
import os
import re
import stat
import struct
import subprocess
import sys

PROG = "rhizo-console-vt"
ACL_XATTR = "system.posix_acl_access"
ACL_VERSION = 2
ACL_USER_OBJ, ACL_USER, ACL_GROUP_OBJ, ACL_GROUP, ACL_MASK, ACL_OTHER = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
ACL_UNDEFINED_ID = 0xFFFFFFFF
HEADER = struct.Struct("<I")
ENTRY = struct.Struct("<HHI")
RW = 0o6
TTY_MAJOR = 4
MAX_VT = 63
SESSION_ID = re.compile(r"[A-Za-z0-9]+")


def parse_acl(blob):
    """parse the entries of an ACL xattr"""
    if len(blob) < HEADER.size or (len(blob) - HEADER.size) % ENTRY.size:
        raise ValueError("ACL xattr of %d bytes is not a header plus whole entries" % len(blob))
    (version,) = HEADER.unpack_from(blob)
    if version != ACL_VERSION:
        raise ValueError("ACL xattr version is %d, not %d" % (version, ACL_VERSION))
    entries = [ENTRY.unpack_from(blob, off) for off in range(HEADER.size, len(blob), ENTRY.size)]
    for tag in (ACL_USER_OBJ, ACL_GROUP_OBJ, ACL_OTHER):
        n = sum(1 for e in entries if e[0] == tag)
        if n != 1:
            raise ValueError("ACL xattr carries tag 0x%02x %d times, not once" % (tag, n))
    return entries


def mode_acl(mode):
    """return the minimal ACL for a mode"""
    return [(ACL_USER_OBJ, (mode >> 6) & 7, ACL_UNDEFINED_ID),
            (ACL_GROUP_OBJ, (mode >> 3) & 7, ACL_UNDEFINED_ID),
            (ACL_OTHER, mode & 7, ACL_UNDEFINED_ID)]


def pack_acl(entries):
    """encode entries into an ACL xattr"""
    ordered = sorted(entries, key=lambda e: (e[0], e[2] if e[0] in (ACL_USER, ACL_GROUP) else 0))
    return HEADER.pack(ACL_VERSION) + b"".join(ENTRY.pack(*e) for e in ordered)


def with_root_rw(entries):
    """return entries with root granted rw"""
    kept = [e for e in entries if e[0] != ACL_MASK and not (e[0] == ACL_USER and e[2] == 0)]
    root = [e for e in entries if e[0] == ACL_USER and e[2] == 0]
    perm = (root[0][1] if root else 0) | RW
    kept.append((ACL_USER, perm, 0))
    mask = 0
    for tag, p, _ in kept:
        if tag in (ACL_USER, ACL_GROUP_OBJ, ACL_GROUP):
            mask |= p
    kept.append((ACL_MASK, mask, ACL_UNDEFINED_ID))
    return kept


def root_perm(entries, owner):
    """return the permission bits for uid 0"""
    if owner == 0:
        return next(p for t, p, _ in entries if t == ACL_USER_OBJ)
    named = [p for t, p, i in entries if t == ACL_USER and i == 0]
    if not named:
        return next(p for t, p, _ in entries if t == ACL_OTHER)
    masks = [p for t, p, _ in entries if t == ACL_MASK]
    return named[0] & (masks[0] if masks else 7)


def read_acl(path, st):
    """return the ACL entries of a path"""
    try:
        return parse_acl(os.getxattr(path, ACL_XATTR, follow_symlinks=False))
    except OSError as e:
        if e.errno != errno.ENODATA:
            raise
    return mode_acl(st.st_mode)


def is_vt(st):
    """check for a VT device node"""
    return (stat.S_ISCHR(st.st_mode) and os.major(st.st_rdev) == TTY_MAJOR
            and 1 <= os.minor(st.st_rdev) <= MAX_VT)


def grant_root(path, uid):
    """add the root entry to a node"""
    st = os.lstat(path)
    if st.st_uid != uid:
        return "not-owner"
    entries = read_acl(path, st)
    if root_perm(entries, st.st_uid) & RW == RW:
        return "already"
    os.setxattr(path, ACL_XATTR, pack_acl(with_root_rw(entries)), follow_symlinks=False)
    return "granted"


def grant_vt(path, uid):
    """grant root rw on a VT"""
    if not is_vt(os.lstat(path)):
        return "not-a-vt"
    return grant_root(path, uid)


def root_keeps_rw(entries):
    """check uid 0 for rw access"""
    return root_perm(entries, ACL_UNDEFINED_ID) & RW == RW


def grant_root_named(path):
    """add the root entry to a node"""
    st = os.lstat(path)
    entries = read_acl(path, st)
    if root_keeps_rw(entries):
        return "already"
    blob = pack_acl(with_root_rw(entries))
    os.setxattr(path, ACL_XATTR, blob, follow_symlinks=False)
    return "granted"


def vt_path(vtnr):
    """return the /dev/ttyN path for a VTNr"""
    text = vtnr.strip()
    if not re.fullmatch(r"[0-9]+", text) or not 1 <= int(text) <= MAX_VT:
        return None
    return "/dev/tty%d" % int(text)


def session_vtnr(session_id):
    """read a session's VTNr from loginctl"""
    r = subprocess.run(["loginctl", "show-session", session_id, "-p", "VTNr", "--value"],
                       capture_output=True, text=True, timeout=5)
    if r.returncode != 0:
        raise OSError("loginctl show-session %s exited %d: %s" % (session_id, r.returncode,
                                                                  r.stderr.strip()))
    return r.stdout


def grant_session(session_id, vtnr_of=session_vtnr):
    """grant root rw on a session's VT"""
    if not SESSION_ID.fullmatch(session_id):
        raise ValueError("%r is not a logind session id" % session_id)
    path = vt_path(vtnr_of(session_id))
    if path is None:
        return None, "no-vt"
    if not is_vt(os.lstat(path)):
        return path, "not-a-vt"
    return path, grant_root_named(path)


def main_session(session_id):
    """grant root rw on a session's VT"""
    try:
        path, done = grant_session(session_id)
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        print("%s: could not give root access to the VT of session %s: %s" % (PROG, session_id, e),
              file=sys.stderr)
        return 1
    if path is not None:
        print("%s: %s of session %s: %s" % (PROG, path, session_id, done))
    return 1 if done == "not-a-vt" else 0


def main(argv):
    """open the console VT or session for root access and report failure"""
    if len(argv) == 3 and argv[1] == "--session":
        return main_session(argv[2])
    if len(argv) != 2 or argv[1].startswith("-"):
        print("usage: %s /dev/ttyN | --session ID" % PROG, file=sys.stderr)
        return 2
    try:
        grant_vt(argv[1], os.getuid())
    except (OSError, ValueError) as e:
        print("%s: could not give root access to %s: %s" % (PROG, argv[1], e), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
