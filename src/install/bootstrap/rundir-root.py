#!/usr/bin/env python3
import errno
import os
import stat
import struct
import sys

PROG = "rhizo-rundir-root"
ACL_XATTR = "system.posix_acl_access"
ACL_VERSION = 2
ACL_USER_OBJ, ACL_USER, ACL_GROUP_OBJ, ACL_GROUP, ACL_MASK, ACL_OTHER = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
ACL_UNDEFINED_ID = 0xFFFFFFFF
HEADER = struct.Struct("<I")
ENTRY = struct.Struct("<HHI")
RWX = 0o7
X = 0o1


def parse_acl(blob):
    """parse the posix_acl_access xattr into entries"""
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
    """build the ACL entries for a file mode"""
    return [(ACL_USER_OBJ, (mode >> 6) & 7, ACL_UNDEFINED_ID),
            (ACL_GROUP_OBJ, (mode >> 3) & 7, ACL_UNDEFINED_ID),
            (ACL_OTHER, mode & 7, ACL_UNDEFINED_ID)]


def pack_acl(entries):
    """encode the ACL entries into an xattr"""
    ordered = sorted(entries, key=lambda e: (e[0], e[2] if e[0] in (ACL_USER, ACL_GROUP) else 0))
    return HEADER.pack(ACL_VERSION) + b"".join(ENTRY.pack(*e) for e in ordered)


def with_root(entries, perm):
    """return the entries with a uid 0 entry"""
    kept = [e for e in entries if e[0] != ACL_MASK and not (e[0] == ACL_USER and e[2] == 0)]
    kept.append((ACL_USER, perm, 0))
    mask = 0
    for tag, perm, _ in kept:
        if tag in (ACL_USER, ACL_GROUP_OBJ, ACL_GROUP):
            mask |= perm
    kept.append((ACL_MASK, mask, ACL_UNDEFINED_ID))
    return kept


def with_root_rwx(entries):
    """return the entries with uid 0 rwx entry"""
    return with_root(entries, RWX)


def root_perm(entries):
    """return the permission bits of uid 0"""
    named = [p for t, p, i in entries if t == ACL_USER and i == 0]
    if not named:
        return next(p for t, p, _ in entries if t == ACL_OTHER)
    masks = [p for t, p, _ in entries if t == ACL_MASK]
    return named[0] & (masks[0] if masks else 7)


def grant(path, uid, perm=RWX):
    """add a uid 0 entry to a directory"""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        return "absent"
    except NotADirectoryError:
        return "not-a-dir"
    except OSError as e:
        if e.errno == errno.ELOOP:
            return "not-a-dir"
        raise
    try:
        st = os.fstat(fd)
        if st.st_uid != uid:
            return "not-owner"
        try:
            entries = parse_acl(os.getxattr(fd, ACL_XATTR))
        except OSError as e:
            if e.errno != errno.ENODATA:
                raise
            entries = mode_acl(stat.S_IMODE(st.st_mode))
        if root_perm(entries) & perm == perm:
            return "already"
        os.setxattr(fd, ACL_XATTR, pack_acl(with_root(entries, perm)))
        return "granted"
    finally:
        os.close(fd)


def own_runtime_dir():
    """return the runtime directory of this uid"""
    return "/run/user/%d" % os.getuid()


def own_portal_doc():
    """create the document portal mountpoint directory"""
    path = os.path.join(own_runtime_dir(), "doc")
    try:
        os.mkdir(path, 0o700)
    except FileExistsError:
        pass
    return path


def main(argv):
    """grant uid 0 access to a directory"""
    if len(argv) != 2:
        print("usage: %s DIR|--own-runtime-dir|--own-portal-doc" % PROG, file=sys.stderr)
        return 2
    perm, why = RWX, "the unit's stop leaves it behind"
    try:
        if argv[1] == "--own-runtime-dir":
            argv = [argv[0], own_runtime_dir()]
        elif argv[1] == "--own-portal-doc":
            perm, why = X, "fusermount3 cannot mount the document portal there"
            argv = [argv[0], own_portal_doc()]
        done = grant(argv[1], os.getuid(), perm)
    except (OSError, ValueError) as e:
        print("%s: could not give root access to %s, so %s: %s" % (PROG, argv[1], why, e), file=sys.stderr)
        return 1
    if done not in ("granted", "already"):
        print("%s: %s is %s for uid %d, so root gets no entry on it" % (PROG, argv[1], done, os.getuid()),
              file=sys.stderr)
        return 1
    print("%s: %s: %s" % (PROG, argv[1], done))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
