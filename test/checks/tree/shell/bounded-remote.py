#!/usr/bin/env python3

import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import test_dirs, tool_dirs  # noqa: E402
TOOL_DIRS = tool_dirs(REPO)
TEST_DIRS = test_dirs(REPO)
DIRS = [os.path.join(REPO, d) for d in (
    *TEST_DIRS, *TOOL_DIRS,
    "src/androidd", "src/services", "src/install")]
MIN_SCANNED = 330

CMD = re.compile(
    r"(?:^|[;&|(){}!]|\$\(|\b(?:if|then|else|elif|do|while|until|time)\b)"
    r"\s*!?\s*(ssh|scp)\s")


def strip_noise(line):
    """return the line without comments and quoted text"""
    out, quote, i = [], None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
            out.append(" ")
        elif c in "\"'":
            quote = c
            out.append(" ")
        elif c == "#" and (not out or out[-1].isspace()):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def main():
    """scan scripts for unbounded ssh and scp calls"""
    failed = 0
    seen = set()
    for d in DIRS:
        if not os.path.isdir(d):
            print("FAIL: scan directory missing: %s" % os.path.relpath(d, REPO))
            failed = 1
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(".sh"):
                continue
            path = os.path.join(d, name)
            if path in seen or not os.path.isfile(path):
                continue
            seen.add(path)
            for n, raw in enumerate(open(path, errors="replace"), 1):
                line = strip_noise(raw.rstrip("\n"))
                m = CMD.search(line)
                if not m:
                    continue
                if re.search(r"\bssh_vm\b|\b_ssh_vm", line):
                    continue
                if "timeout " in line:
                    continue
                print("FAIL: %s:%d unbounded %s call"
                      % (os.path.relpath(path, REPO), n, m.group(1)))
                print("      " + raw.strip())
                failed = 1
    if len(seen) < MIN_SCANNED:
        print("FAIL: scanned %d scripts, expected at least %d" % (len(seen), MIN_SCANNED))
        failed = 1
    if failed:
        print()
        print("Wrap each in 'timeout <seconds>'. ConnectTimeout bounds the "
              "handshake only; a session that connects and then goes quiet "
              "needs an external timeout.")
        return 1
    print("every ssh/scp call in this project's scripts is externally bounded")
    return 0


if __name__ == "__main__":
    sys.exit(main())
