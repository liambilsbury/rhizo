#!/usr/bin/env python3
import os
import re
import subprocess
import sys


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import layout_paths as layout

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

MOUNT = re.compile(r"\bmount\s+-t\s+9p\b")

ALLOWED = {
    "test/vm/common.sh",
    "test/checks/vm/image/share-mount.py",
}


def offenders(files, read):
    """return the 9p share mount lines"""
    out = []
    for path in sorted(files):
        if path in ALLOWED:
            continue
        for n, line in enumerate(read(path).split("\n"), 1):
            if MOUNT.search(line):
                out.append("%s:%d mounts the 9p share itself -- "
                           "call common.sh's guest_mount_share instead" % (path, n))
    return out


def tracked_scripts():
    """return the tracked shell and python files"""
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z"],
                         capture_output=True, text=True, check=True).stdout
    return [p for p in out.split("\0")
            if (p.endswith(".sh") or p.endswith(".py")) and not layout.outside_layout(p)]


def selftest():
    """run the checker on fixture scripts"""
    n = 0
    files = tracked_scripts()
    assert files, "git ls-files returned nothing"
    n += 1
    real = offenders(files, lambda p: open(os.path.join(ROOT, p),
                                           encoding="utf-8", errors="replace").read())
    assert real == [], "the tree already has copies: %s" % real
    n += 1
    fixture = {"tools/pretend.sh":
               "mountpoint -q /root/share || mount -t 9p -o trans=virtio,"
               "version=9p2000.L,msize=1048576 share9p /root/share\n"}
    found = offenders(["tools/pretend.sh"], lambda p: fixture[p])
    assert len(found) == 1 and "pretend.sh:1" in found[0], found
    n += 1
    fixture = {"x.sh": "  mount -t 9p -o trans=virtio,msize=262144 share9p /root/share\n"}
    assert len(offenders(["x.sh"], lambda p: fixture[p])) == 1
    n += 1
    fixture = {"x.sh": "# -virtfs local,path=share,mount_tag=share9p\n"
                       "  guest_mount_share || exit 1\n"}
    assert offenders(["x.sh"], lambda p: fixture[p]) == [], "prose must not trip this"
    n += 1
    fixture = {"test/vm/common.sh":
               "mount -t 9p -o trans=virtio share9p /root/share\n"}
    assert offenders(["test/vm/common.sh"], lambda p: fixture[p]) == []
    n += 1
    print("check-share-mount selftest: %d assertions passed" % n)


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    findings = offenders(
        tracked_scripts(),
        lambda p: open(os.path.join(ROOT, p), encoding="utf-8", errors="replace").read())
    for f in findings:
        print("check-share-mount: " + f)
    sys.exit(1 if findings else 0)
