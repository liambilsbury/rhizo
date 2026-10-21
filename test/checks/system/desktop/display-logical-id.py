#!/usr/bin/env python3
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

COMPOSER_ID_ASSIGN_RE = re.compile(r"^\s*(?:local\s+)?(\w+)=.*display added id=")
COMPOSER_HELPER_ASSIGN_RE = re.compile(r"^\s*(?:local\s+)?(\w+)=\$\((add_display|last_added_id)\b")
COMPOSER_READ_RE = re.compile(r'^\s*read\s+-r\s+(\w+)(?:\s+\w+)*\s+<<<"\$\((add_display|last_added_id)\b')
FRAMEWORK_USE_RE = re.compile(r"(?:enable-display|--display)\s+\$\{?(\w+)\}?")


def composer_id_vars(lines):
    """return the variables holding a composer display id"""
    found = set()
    for line in lines:
        for rx in (COMPOSER_ID_ASSIGN_RE, COMPOSER_HELPER_ASSIGN_RE, COMPOSER_READ_RE):
            m = rx.match(line)
            if m:
                found.add(m.group(1))
    return found


def check_text(text):
    """return the lines that pass a composer display id to the framework"""
    lines = text.split("\n")
    tainted = composer_id_vars(lines)
    hits = []
    for n, line in enumerate(lines, 1):
        for m in FRAMEWORK_USE_RE.finditer(line):
            if m.group(1) in tainted:
                hits.append((n, m.group(1), line.strip()))
    return hits


PATHSPECS = ["test/*.sh", "tools/*.sh", ":(glob)src/androidd/*.sh", "src/androidd/guest/*.sh",
             ":(glob)src/services/*/*.sh", "src/androidd/host/kernel-check.sh",
             "src/androidd/sandbox/capability-allowed.sh", "src/install/prepare/derive-patches.sh",
             "src/install/prepare/detect-gpu-driver.sh", "src/install/prepare/data-template.sh"]
MIN_SCANNED = 347


def tracked_scripts():
    """return the existing tracked script paths"""
    out = subprocess.run(["git", "-C", REPO, "ls-files"] + PATHSPECS,
                         capture_output=True, text=True, check=True).stdout.split()
    if len(out) < MIN_SCANNED:
        raise SystemExit("scanned %d scripts, expected at least %d" % (len(out), MIN_SCANNED))
    return [p for p in (os.path.join(REPO, q) for q in out) if os.path.exists(p)]


def selftest():
    """check that the bad sample is flagged and the good one is not"""
    bad = 'id=$(rhizo_ctl_out "$INIT" | grep -o "display added id=[0-9]*" | cut -d= -f2)\n' \
          'android_sh "$INIT" "cmd display enable-display $id"\n'
    good = 'read -r id port <<<"$(add_display 960 1080)"\nlid=$(resolve_logical_id "$port")\n' \
           'android_sh "$INIT" "cmd display enable-display $lid"\n' \
           'android_sh "$INIT" "am start --display $lid -n x/y"\n'
    if not check_text(bad):
        print("selftest FAIL: a composer id handed to enable-display was not flagged")
        return 1
    if check_text(good):
        print("selftest FAIL: a resolved logical id was flagged")
        return 1
    print("selftest ok")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    rc = 0
    for path in tracked_scripts():
        with open(path) as f:
            for n, var, line in check_text(f.read()):
                print(f"{os.path.relpath(path, REPO)}:{n}: ${var} comes from the composer's 'display added id=' "
                      f"reply but is handed to a framework command that takes the logical id: {line}")
                rc = 1
    if rc == 0:
        print("every enable-display and am start --display argument is resolved, never the composer's id")
    return rc


if __name__ == "__main__":
    sys.exit(main())
