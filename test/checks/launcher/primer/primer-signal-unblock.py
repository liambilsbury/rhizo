#!/usr/bin/env python3
import ast
import os
import signal
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
LAUNCHER = os.path.join(REPO, "src", "androidd", "boot.py")

UNBLOCK_RE = "pthread_sigmask(signal.SIG_UNBLOCK"
POPEN_RE = "subprocess.Popen("


def host_primer_src():
    """return the HOST_PRIMER_SRC string from the launcher, or None"""
    tree = ast.parse(open(LAUNCHER).read())
    for node in ast.walk(tree):
        if (isinstance(node, ast.Assign) and len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "HOST_PRIMER_SRC"
                and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str)):
            return node.value.value
    return None


def unblock_line(src):
    """return the line holding the signal unblock, or None"""
    i = src.find(UNBLOCK_RE)
    if i < 0:
        return None
    start = src.rfind("\n", 0, i) + 1
    end = src.find("\n", i)
    return src[start:end if end >= 0 else len(src)]


def behavioral_probe(line):
    """run a line and return the child SigBlk"""
    script = (
        "import signal\n"
        "%s\n"
        "with open('/proc/self/status') as f:\n"
        "    for ln in f:\n"
        "        if ln.startswith('SigBlk:'):\n"
        "            print(ln.split()[1].strip())\n"
    ) % line
    old = signal.pthread_sigmask(signal.SIG_SETMASK, set())
    signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGUSR1})
    try:
        out = subprocess.run([sys.executable, "-c", script], capture_output=True,
                             text=True, timeout=10)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old)
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def main():
    """run the check on the primer source and print the result"""
    bad = []
    src = host_primer_src()
    if src is None:
        print("FAIL: HOST_PRIMER_SRC not found as a string constant in %s" % LAUNCHER)
        return 1

    unblock_idx = src.find(UNBLOCK_RE)
    if unblock_idx < 0:
        bad.append("HOST_PRIMER_SRC never unblocks SIGTERM/SIGUSR1 (no %r)" % UNBLOCK_RE)
    else:
        first_popen = src.find(POPEN_RE)
        if first_popen >= 0 and unblock_idx > first_popen:
            bad.append("HOST_PRIMER_SRC's signal unblock comes after its first subprocess.Popen(")

    if not bad:
        line = unblock_line(src)
        mask = behavioral_probe(line)
        if mask is None:
            bad.append("the behavioral probe of the extracted unblock line did not run")
        else:
            m = int(mask, 16)
            term_bit = 1 << (signal.SIGTERM - 1)
            usr1_bit = 1 << (signal.SIGUSR1 - 1)
            if m & term_bit:
                bad.append("a child running the primer's own unblock line still has SIGTERM "
                          "blocked (SigBlk=%s)" % mask)
            if m & usr1_bit:
                bad.append("a child running the primer's own unblock line still has SIGUSR1 "
                          "blocked (SigBlk=%s)" % mask)

    for b in bad:
        print("FAIL: %s" % b)
    if not bad:
        print("check-primer-signal-unblock: HOST_PRIMER_SRC clears SIGTERM/SIGUSR1 before its "
              "first Popen, and running that exact line really clears an inherited block")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
