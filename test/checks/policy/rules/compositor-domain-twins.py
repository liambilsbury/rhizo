#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
CIL = os.path.join(REPO, "src", "androidd", "guest", "sepolicy", "policy.cil")
PEERS = ("rhizo_gralloc_allocator", "rhizo_composer", "hal_graphics_composer_server_tmpfs",
         "rhizo_render_device")

RECEIVE_FROM = ("rhizo_host",)
RECEIVE = {"read", "write", "getattr", "map"}


def grants(text):
    """return the allow grants of a CIL policy"""
    found = {}
    for m in re.finditer(r"^\(allow\s+(\S+)\s+(\S+)\s+\((\S+)\s+\(([^()]*)\)\)\)", text, re.M):
        found.setdefault((m.group(1), m.group(2), m.group(3)), set()).update(m.group(4).split())
    return found


def missing(text):
    """return the kernel peer grants missing for rhizo_host"""
    g = grants(text)
    peer = [(k, v) for k, v in sorted(g.items()) if k[0] == "kernel" and k[1] in PEERS]
    lacks = []
    for (_src, tgt, cls), perms in peer:
        lack = perms - g.get(("rhizo_host", tgt, cls), set())
        if lack:
            lacks.append("%s %s: %s" % (tgt, cls, " ".join(sorted(lack))))
    return len(peer), lacks


def tmpfs_file_label(text, domain):
    """return the tmpfs file label of a domain"""
    m = re.search(r"^\(typetransition\s+%s\s+tmpfs\s+file\s+(\S+)\)" % re.escape(domain), text, re.M)
    return m.group(1) if m else "tmpfs"


def receive_lacks(text):
    """return the missing composer receive grants"""
    g = grants(text)
    lacks = []
    for dom in RECEIVE_FROM:
        if "use" not in g.get(("rhizo_composer", dom, "fd"), set()):
            lacks.append("%s fd (a %s compositor's): use" % (dom, dom))
        label = tmpfs_file_label(text, dom)
        lack = RECEIVE - g.get(("rhizo_composer", label, "file"), set())
        if lack:
            lacks.append("%s file (a %s compositor's shm/memfd): %s" % (label, dom, " ".join(sorted(lack))))
    return lacks


PIPE_OWNERS = ("rhizo_host", "kernel")


def append_lacks(text):
    """return the fifo_file owners granted write without append"""
    g = grants(text)
    return ["%s fifo_file" % owner for owner in PIPE_OWNERS
            if "write" in g.get(("rhizo_host", owner, "fifo_file"), set())
            and "append" not in g.get(("rhizo_host", owner, "fifo_file"), set())]


GOOD = """\
; a comment naming (allow kernel rhizo_composer (fd (use))) is not a rule
(allow kernel rhizo_gralloc_allocator (fd (use)))
(allow rhizo_host rhizo_gralloc_allocator (fd (use)))
(allow kernel rhizo_render_device (chr_file (ioctl map read write)))
(allow rhizo_host rhizo_render_device (chr_file (getattr unlink relabelto)))
(allow rhizo_host rhizo_render_device (chr_file (ioctl map open
    read write)))
(allow kernel unlabeled (file (write ioctl)))
(allow rhizo_composer rhizo_host (fd (use)))
(allow rhizo_composer tmpfs (file (read write getattr map)))
(allow rhizo_host rhizo_host (fifo_file (getattr open read write)))
(allow rhizo_host rhizo_host (fifo_file (append)))
(allow rhizo_host kernel (fifo_file (getattr open read write lock append)))
"""


def selftest():
    """check the twinned sample and each planted-defect sample"""
    count, lacks = missing(GOOD)
    if count != 2 or lacks:
        print("SELFTEST FAILED: the twinned fixture read as %d peer grant(s) lacking %s" % (count, lacks),
              file=sys.stderr)
        return 1
    print("selftest ok: twins split across rules and lines pass, and a non-peer kernel grant is out of scope")
    for gone, want in (("(allow rhizo_host rhizo_gralloc_allocator (fd (use)))\n",
                        "rhizo_gralloc_allocator fd: use"),
                       ("(allow rhizo_host rhizo_render_device (chr_file (ioctl map open\n    read write)))\n",
                        "rhizo_render_device chr_file: ioctl map read write")):
        _count, lacks = missing(GOOD.replace(gone, ""))
        if want not in lacks:
            print("SELFTEST FAILED: dropping rhizo_host's twin did not report '%s' (got %s)" % (want, lacks),
                  file=sys.stderr)
            return 1
    print("selftest ok: catches rhizo_host missing the allocator's fd use and the render node's I/O")
    if missing(GOOD.replace("(allow kernel", "(allow kernelx"))[0] != 0:
        print("SELFTEST FAILED: a policy with no kernel peer grant still counted one", file=sys.stderr)
        return 1
    print("selftest ok: a policy with no kernel grant on a compositor peer counts none")
    if receive_lacks(GOOD):
        print("SELFTEST FAILED: the composer's tmpfs grant read as lacking %s" % receive_lacks(GOOD),
              file=sys.stderr)
        return 1
    lacks = receive_lacks(GOOD.replace("(allow rhizo_composer tmpfs (file (read write getattr map)))\n", ""))
    if "tmpfs file (a rhizo_host compositor's shm/memfd): getattr map read write" not in lacks:
        print("SELFTEST FAILED: no composer tmpfs grant did not report the rhizo_host compositor's files "
              "(got %s)" % lacks, file=sys.stderr)
        return 1
    lacks = receive_lacks(GOOD.replace("(file (read write getattr map))", "(file (read getattr map))"))
    if "tmpfs file (a rhizo_host compositor's shm/memfd): write" not in lacks:
        print("SELFTEST FAILED: a read-only composer grant did not report the missing write mutter's O_RDWR "
              "memfd needs (got %s)" % lacks, file=sys.stderr)
        return 1
    lacks = receive_lacks(GOOD.replace("(allow rhizo_composer rhizo_host (fd (use)))\n", ""))
    if lacks != ["rhizo_host fd (a rhizo_host compositor's): use"]:
        print("SELFTEST FAILED: no fd use of rhizo_host's fds did not report exactly that (got %s)" % lacks,
              file=sys.stderr)
        return 1
    moved = GOOD + "(typetransition rhizo_host tmpfs file rhizo_host_tmpfs)\n"
    if "rhizo_host_tmpfs file (a rhizo_host compositor's shm/memfd): getattr map read write" not in receive_lacks(moved):
        print("SELFTEST FAILED: a rhizo_host tmpfs transition did not move the required label (got %s)"
              % receive_lacks(moved), file=sys.stderr)
        return 1
    print("selftest ok: catches the composer unable to receive a compositor's shm/memfd, a read-only grant, "
          "no fd use, and follows a type transition to the label the file really gets")
    if append_lacks(GOOD):
        print("SELFTEST FAILED: append granted in a separate rule read as lacking %s" % append_lacks(GOOD),
              file=sys.stderr)
        return 1
    for gone, want in (("(allow rhizo_host kernel (fifo_file (getattr open read write lock append)))",
                        "kernel fifo_file"),
                       ("(allow rhizo_host rhizo_host (fifo_file (append)))\n", "rhizo_host fifo_file")):
        lacks = append_lacks(GOOD.replace(gone, gone.replace(" append", "") if "lock" in gone else ""))
        if lacks != [want]:
            print("SELFTEST FAILED: a writable %s with no append did not report exactly that (got %s)"
                  % (want, lacks), file=sys.stderr)
            return 1
    print("selftest ok: catches a pipe rhizo_host may write but not append to, its own or kernel's")
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    path = argv[1] if len(argv) > 1 else CIL
    count, lacks = missing(open(path, encoding="utf-8").read())
    if count == 0:
        print("check-compositor-domain-twins: %s holds no kernel grant on %s" % (path, ", ".join(PEERS)))
        return 1
    if lacks:
        print("check-compositor-domain-twins: a compositor started after enforcement runs as rhizo_host, "
              "which lacks what kernel holds on:")
        for line in lacks:
            print("  " + line)
        return 1
    back = receive_lacks(open(path, encoding="utf-8").read())
    if back:
        print("check-compositor-domain-twins: the composer cannot receive what a compositor sends it:")
        for line in back:
            print("  rhizo_composer " + line)
        return 1
    pipes = append_lacks(open(path, encoding="utf-8").read())
    if pipes:
        print("check-compositor-domain-twins: rhizo_host may write these pipes but not append to them:")
        for line in pipes:
            print("  rhizo_host " + line)
        return 1
    print("check-compositor-domain-twins: rhizo_host holds all %d of kernel's compositor-peer grants, the "
          "composer can receive a rhizo_host compositor's shm/memfd fds, and every pipe rhizo_host writes "
          "it may append to" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
