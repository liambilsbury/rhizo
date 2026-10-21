#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEM_DIR = os.path.join(HERE, "..", "..", "..", "system")
sys.path.insert(0, os.path.join(SYSTEM_DIR, "run"))
import system_tests  # noqa: E402

FATAL_RE = re.compile(r"FATAL EXCEPTION|Watchdog.*killing|SIGABRT|SIGSEGV|TEST_FATAL_RE|TEST_WATCHDOG_KILL_RE")
BARE_COUNT_RE = re.compile(r"logcat_vm\s+\S+\s+(?:-d\s+)?(?:-[a-z]+\s+\S+\s+)*-t\s+(\d+)")
VAR_T_RE = re.compile(r"logcat_vm\s+\S+\s+(?:-d\s+)?(?:-[a-z]+\s+\S+\s+)*-t\s+\"?\$")
SAFE_RE = re.compile(r"#\s*test-log-window:\s*safe\s*--\s*\S")


def scan(text):
    """return the unsafe bare-count logcat_vm lines"""
    lines = text.split("\n")
    hits = []
    for i, line in enumerate(lines):
        if not BARE_COUNT_RE.search(line) or VAR_T_RE.search(line):
            continue
        window = "\n".join(lines[i:i + 3])
        if not FATAL_RE.search(window):
            continue
        preceding = "\n".join(lines[max(0, i - 5):i])
        if SAFE_RE.search(preceding) or SAFE_RE.search(line):
            continue
        hits.append((i + 1, line.strip()))
    return hits


def check_file(path):
    """return the hits found in a file"""
    with open(path) as f:
        return scan(f.read())


def run(tools_dir):
    """check every system test and print the hits"""
    failed = False
    for path in system_tests.system_test_paths(tools_dir):
        base = os.path.basename(path)
        if base == "lib.sh":
            continue
        for lineno, line in check_file(path):
            failed = True
            print(f"FAIL: {base}:{lineno} scans for a fatal/watchdog signature over a "
                  f"bare line count -- {line}")
            print("      either scope it with logcat_since_marker (see network.sh "
                  "for the pattern) or explain why the ring is already clean with a "
                  "'# test-log-window: safe --' comment")
    return failed


def selftest():
    """check the scan against good and planted-defect texts"""
    bad = []

    def want(name, text, should_fail):
        """record a failure unless the scan fails exactly when it should"""
        hits = scan(text)
        got_fail = bool(hits)
        if got_fail != should_fail:
            bad.append(f"{name}: expected {'a FAIL' if should_fail else 'no FAIL'}, "
                       f"got {hits!r}")

    want("bare count feeding a fatal grep",
         'logcat_vm "$INIT" -d -t 8000 2>/dev/null | grep -cE "FATAL EXCEPTION|SIGABRT"\n',
         True)
    want("bare count captured then grepped a few lines later",
         'logcat_vm "$INIT" -d -t 8000 > "$EV/logcat.txt" 2>/dev/null\n'
         'bad=$(grep -cE "FATAL EXCEPTION|Watchdog.*killing" "$EV/logcat.txt")\n',
         True)
    want("bare count feeding the shared TEST_FATAL_RE, not an inline pattern",
         'logcat_vm "$INIT" -d -t 8000 > "$EV/logcat.txt" 2>/dev/null\n'
         'bad=$(grep -cE "$TEST_FATAL_RE" "$EV/logcat.txt")\n',
         True)
    want("scoped by a variable",
         'logcat_vm "$INIT" -d -t "$TEST_SINCE" 2>/dev/null | grep -cE "FATAL EXCEPTION"\n',
         False)
    want("bare count with a safe annotation above it",
         '# test-log-window: safe -- ring cleared with logcat_vm "$INIT" -c above\n'
         'crashes=$(logcat_vm "$INIT" -d -t 4000 2>/dev/null | grep -cE "FATAL EXCEPTION")\n',
         False)
    want("bare count with no fatal grep nearby",
         'logcat_vm "$init_pid" -d -b all -t 8000 > "$dir/logcat.txt" 2>&1\n',
         False)
    want("an empty comment cannot stand in for a real reason",
         '# test-log-window: safe\n'
         'crashes=$(logcat_vm "$INIT" -d -t 4000 2>/dev/null | grep -cE "FATAL EXCEPTION")\n',
         True)

    if bad:
        print("SELFTEST FAILED:")
        for b in bad:
            print(f"  {b}")
        return 1
    print("selftest ok: catches a bare-count fatal scan piped or captured-then-grepped, "
          "and an empty safe-comment; clears a scoped read, an annotated one, and a "
          "debug dump with no assertion")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(1 if run(SYSTEM_DIR) else 0)
