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

BIG = re.compile(r"\b(?:dmesg|journalctl|logcat_vm|logcat|pm list packages|declare -f)\b")
HOST_PIPE_TO_Q = re.compile(r"\|\s*(?:[a-z][^|\n]*\|\s*)*grep\s+-[A-Za-z]*q")


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def code_lines(text):
    """yield the number and text of each line that is not a comment"""
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        yield n, line


def mask_quoted_pipes(line):
    """blank the pipes inside quotes"""
    out, quote = [], None
    for ch in line:
        if quote:
            out.append(" " if ch == "|" else ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        else:
            out.append(ch)
    return "".join(out)


OPT_OUT = re.compile(r"#\s*pipefail-ok:\s*\S")


def check(sources):
    """return the large-producer pipes into grep -q"""
    fails = []
    for rel, text in sorted(sources.items()):
        raw = text.splitlines()
        for n, line in code_lines(text):
            if OPT_OUT.search(line) or (n >= 2 and OPT_OUT.search(raw[n - 2])):
                continue
            masked = mask_quoted_pipes(line)
            if not HOST_PIPE_TO_Q.search(masked):
                continue
            producer = masked[:HOST_PIPE_TO_Q.search(masked).start()]
            if not BIG.search(producer):
                continue
            fails.append(
                "%s:%d pipes a large producer into `grep -q` under pipefail; "
                "capture to a file or a variable first, or use `grep -c`: %s"
                % (rel, n, line.strip()))
    return fails


def scan_repo():
    """return the text of every scanned source"""
    sources = {}
    for d in SCANNED_DIRS:
        root = os.path.join(REPO, d)
        if not os.path.isdir(root):
            raise SystemExit("scan directory missing: %s" % d)
        for name in sorted(os.listdir(root)):
            if not name.endswith(".sh"):
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
        ("a host-side dmesg piped into grep -q",
         "ssh_vm -t 15 'dmesg' | grep -q RHIZO_MARKER\n"),
        ("a local dmesg piped into grep -qi",
         "if dmesg | grep -qi 'failed to validate module BTF'; then exit 1; fi\n"),
        ("pm list packages through tr and into grep -qx",
         "android_sh \"$INIT\" 'pm list packages' | tr -d '\\r' | grep -qx package:x\n"),
        ("a journalctl read piped into grep -q",
         "ssh_vm -t 30 journalctl -u androidd.service | grep -q MARKER\n"),
        ("a function body piped into grep -q",
         "elif ! declare -f lifecycle_run_cycle | grep -q 'step_claim 2.sandbox-up'; then\n"),
    ]
    for name, text in cases:
        if not check({"fixture.sh": text}):
            print("SELFTEST FAIL: %s was not detected" % name)
            bad += 1
        else:
            print("ok   selftest: %s" % name)
    passes = [
        ("a pipe inside the remote command string runs in the guest's shell",
         "ssh_vm -t 5 \"curl -sf http://$IP/x | grep -q RHIZO-NET-OK\"\n"),
        ("grep -c reads to EOF and is immune",
         "n=$(ssh_vm -t 15 'dmesg' | grep -c RHIZO_MARKER || true)\n"),
        ("capture then grep the file is the fix",
         "ssh_vm -t 30 'dmesg' > \"$f\"\ngrep -q RHIZO_MARKER \"$f\"\n"),
        ("a short producer is out of scope here",
         "ssh_vm -t 30 'systemctl is-active androidd.service' | grep -qx active\n"),
        ("a comment describing the trap is not the trap",
         "# never do `dmesg | grep -q X`: grep -q exits early and SIGPIPEs it\n"),
    ]
    for name, text in passes:
        if check({"fixture.sh": text}):
            print("SELFTEST FAIL: %s was flagged" % name)
            bad += 1
        else:
            print("ok   selftest: %s" % name)
    if bad:
        return 1
    print("check-early-exit-pipe selftest: every fixture answered as it should")
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
    print("check-early-exit-pipe: no large producer feeds an early-exiting grep")
    return 0


if __name__ == "__main__":
    sys.exit(main())
