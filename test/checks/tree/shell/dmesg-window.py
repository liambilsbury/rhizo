#!/usr/bin/env python3

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import test_dirs, tool_dirs  # noqa: E402
TOOL_DIRS = tool_dirs(REPO)
TEST_DIRS = test_dirs(REPO)
SCANNED_DIRS = [*TEST_DIRS, *TOOL_DIRS, "src/install", "src/androidd", "src/services"]
MIN_SCANNED = 330
SCANNED_EXT = (".sh",)

REBOOTS = re.compile(r"\b(boot_vm|kill_vm|boot_and_start)\b")
COUNTS = re.compile(r"dmesg\s*\|\s*wc\s+-l")
SLICES = re.compile(r"dmesg\b[^|]*\|\s*tail\s+-n\s*\+")


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def code_lines(text):
    """yield the numbered non-comment lines"""
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield n, line


def check(sources):
    """return a failure per dmesg offset slice"""
    fails = []
    for rel, text in sorted(sources.items()):
        reboots = any(REBOOTS.search(line) for _, line in code_lines(text))
        if not reboots:
            continue
        for n, line in code_lines(text):
            hit = COUNTS.search(line) or SLICES.search(line)
            if not hit:
                continue
            fails.append(
                "%s:%d slices dmesg by a line-count offset, but this script reboots the "
                "guest; read the whole of dmesg: %s" % (rel, n, line.strip()))
    return fails


def scan_repo():
    """return the text of every scanned source"""
    sources = {}
    for d in SCANNED_DIRS:
        root = os.path.join(REPO, d)
        if not os.path.isdir(root):
            raise SystemExit("scan directory missing: %s" % d)
        for name in sorted(os.listdir(root)):
            if not name.endswith(SCANNED_EXT):
                continue
            sources[os.path.join(d, name)] = read(os.path.join(root, name))
    if len(sources) < MIN_SCANNED:
        raise SystemExit("scanned %d scripts, expected at least %d" % (len(sources), MIN_SCANNED))
    return sources


def selftest():
    """check the real tree and each planted-defect source"""
    if check(scan_repo()):
        print("SELFTEST FAIL: the real tree does not pass its own check")
        return 1
    bad = 0
    cases = [
        ("a system test takes the offset before its own reboot",
         "boot_and_start leg4 a17\nd0=$(ssh_vm -t 15 'dmesg | wc -l')\n"),
        ("a system test consumes an offset as a tail window",
         "kill_vm\nssh_vm -t 15 \"dmesg | tail -n +$((d0 + 1))\" | grep -q MARKER\n"),
        ("boot_vm alone is enough to scope the rule",
         "boot_vm\nn=$(ssh_vm 'dmesg | wc -l')\n"),
    ]
    for name, text in cases:
        if not check({"fixture.sh": text}):
            print("SELFTEST FAIL: %s was not detected" % name)
            bad += 1
        else:
            print("ok   selftest: %s" % name)
    passes = [
        ("a script that never reboots may slice by offset (the restart trace)",
         "dmesg_lines() { ssh_vm -t 20 'dmesg | wc -l'; }\n"
         "ssh_vm -t 20 \"dmesg | tail -n +$((d0 + 1))\"\n"),
        ("reading the whole buffer after a reboot is the fix",
         "boot_and_start leg2 a17\nssh_vm -t 15 'dmesg' | grep -q MARKER\n"),
        ("a comment describing the trap is not the trap",
         "boot_and_start leg2 a17\n"
         "# this used to be `dmesg | wc -l` then `dmesg | tail -n +$((d0 + 1))`\n"),
    ]
    for name, text in passes:
        if check({"fixture.sh": text}):
            print("SELFTEST FAIL: %s was flagged" % name)
            bad += 1
        else:
            print("ok   selftest: %s" % name)
    if bad:
        return 1
    print("check-dmesg-window selftest: every fixture answered as it should")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    fails = check(scan_repo())
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-dmesg-window: no dmesg line-count offset spans a reboot")
    return 0


if __name__ == "__main__":
    sys.exit(main())
