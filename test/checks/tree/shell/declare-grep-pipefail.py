#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from tree_dirs import test_dirs, tool_dirs  # noqa: E402
TOOL_DIRS = tool_dirs(REPO)
TEST_DIRS = test_dirs(REPO)
SCAN_DIRS = (*TEST_DIRS, *TOOL_DIRS, "src/androidd", "src/services")
SCAN_FILES = ("src/install/prepare/derive-patches.sh", "src/install/prepare/detect-gpu-driver.sh",
              "src/install/prepare/data-template.sh")
MIN_SCANNED = 330
PIPE = re.compile(r"declare -f [^|\n]*\|\s*grep\b[^|\n]*\s-[A-Za-z]*q")
PIPEFAIL = re.compile(r"set -[a-z]*o pipefail|set -o pipefail|shopt -so pipefail")


def scan(paths):
    """return the problems for grep results assigned in declarations under pipefail"""
    bad = []
    for path in paths:
        text = open(path, errors="replace").read()
        if not PIPEFAIL.search(text):
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if PIPE.search(line):
                bad.append("%s:%d: %s" % (os.path.relpath(path, REPO), n, line.strip()[:140]))
    return bad


def selftest():
    """test scan on pipefail sample scripts"""
    body = "f() { " + "; ".join("x%d=%d" % (i, i) for i in range(60000)) + "; }\n"
    probe = body + "set -o pipefail\ndeclare -f f | grep -q x1=1; echo $?\ngrep -q x1=1 <<<\"$(declare -f f)\"; echo $?\n"
    out = subprocess.run(["bash"], input=probe, capture_output=True, text=True).stdout.split()
    if out != ["141", "0"]:
        print("SELFTEST FAILED: expected the pipe to read 141 and the here-string 0, got %r" % out)
        return 1
    with tempfile.TemporaryDirectory() as d:
        cases = [("bad-pipefail.sh", "set -uo pipefail\nif declare -f g | grep -q x; then :; fi\n", True),
                 ("bad-qE.sh", "set -o pipefail\n! declare -f g | grep -qE 'a|b'\n", True),
                 ("good-herestring.sh", "set -uo pipefail\ngrep -q x <<<\"$(declare -f g)\"\n", False),
                 ("no-pipefail.sh", "declare -f g | grep -q x\n", False),
                 ("comment.sh", "set -o pipefail\n# declare -f g | grep -q x\n", False)]
        for name, text, want in cases:
            p = os.path.join(d, name)
            with open(p, "w") as fh:
                fh.write(text)
            if bool(scan([p])) != want:
                print("SELFTEST FAILED: %s: wanted %s" % (name, "flagged" if want else "clean"))
                return 1
    print("selftest ok: the pipe reads 141 under pipefail, and every case is flagged or passed as it should be")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    paths = [os.path.join(REPO, f) for f in SCAN_FILES]
    for d in SCAN_DIRS:
        paths += sorted(os.path.join(REPO, d, f) for f in os.listdir(os.path.join(REPO, d)) if f.endswith(".sh"))
    if len(paths) < MIN_SCANNED:
        print("FAIL: check-declare-grep-pipefail: scanned %d scripts, expected at least %d"
              % (len(paths), MIN_SCANNED))
        return 1
    bad = scan(paths)
    for b in bad:
        print("FAIL: check-declare-grep-pipefail: %s; "
              "use grep -q PAT <<<\"$(declare -f F)\"" % b)
    if bad:
        return 1
    print("check-declare-grep-pipefail: OK (no declare -f | grep -q in a pipefail script)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
