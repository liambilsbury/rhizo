#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "host", "launch-app.sh")

WRITE_RE = re.compile(r'>>\s*"\$(?:LOG|LAUNCH_LOG)"')
STAGE_RE = re.compile(r"event=stage")
STAGE_FIELD_ORDER_RE = re.compile(r"event=stage pid=\$\$ name=")
TRAP_RE = re.compile(r"\btrap\b")
BACKGROUND_RE = re.compile(r"&\s*$")


def find_writes(lines):
    """return the numbered log write lines"""
    return [(n, line) for n, line in enumerate(lines, 1) if WRITE_RE.search(line)]


def find_summary(writes):
    """return the final summary write"""
    candidates = [(n, t) for n, t in writes if "display=" in t and "event=" not in t]
    return candidates[-1] if candidates else None


def check(text):
    """return the rule failures found in the text"""
    lines = text.splitlines()
    writes = find_writes(lines)
    failures = []

    summary = find_summary(writes)
    if summary is None:
        return [("NO-SUMMARY", 0, "no write matches the final summary format "
                                    "(display= present, event= absent)")]
    summary_line, summary_text = summary

    for n, text_line in writes:
        if n == summary_line:
            continue
        if n >= summary_line:
            failures.append(("ORDER", n, text_line.strip()))
        if STAGE_RE.search(text_line) and not STAGE_FIELD_ORDER_RE.search(text_line):
            failures.append(("FIELD-ORDER", n, text_line.strip()))
        if n >= summary_line and "pkg=" in text_line:
            failures.append(("POST-SUMMARY-PKG", n, text_line.strip()))

    for n, line in enumerate(lines, 1):
        has_trap = TRAP_RE.search(line)
        has_bg = BACKGROUND_RE.search(line.rstrip())
        if (has_trap or has_bg) and WRITE_RE.search(line):
            failures.append(("ASYNC-WRITE", n, line.strip()))

    return failures


SELFTEST_GOOD = """#!/bin/sh
LOG=/tmp/x
LAUNCH_LOG=/tmp/x
echo "$(date +%s.%N) event=invocation pid=$$ pkg=$PKG activity=$ACT" >> "$LAUNCH_LOG"
echo "$(date +%s.%N) event=stage pid=$$ name=unfreeze" >> "$LAUNCH_LOG"
echo "$(date +%s.%N) event=stage pid=$$ name=am-start" >> "$LAUNCH_LOG"
echo "$(date +%s.%N) event=am_start_return pid=$$ pkg=$PKG activity=$ACT display=$logid" >> "$LAUNCH_LOG"
echo "$(date +%s.%N) pkg=$PKG activity=$ACT display=$logid bus=$bus" >> "$LOG"
"""

SELFTEST_ORDER_BAD = SELFTEST_GOOD + (
    'echo "$(date +%s.%N) event=stage pid=$$ name=late" >> "$LAUNCH_LOG"\n'
)

SELFTEST_FIELD_ORDER_BAD = SELFTEST_GOOD.replace(
    'echo "$(date +%s.%N) event=stage pid=$$ name=unfreeze" >> "$LAUNCH_LOG"',
    'echo "$(date +%s.%N) event=stage name=unfreeze pid=$$" >> "$LAUNCH_LOG"',
)

SELFTEST_POST_SUMMARY_PKG_BAD = SELFTEST_GOOD + (
    'echo "$(date +%s.%N) audio pkg=$PKG bus=$bus -> ok" >> "$LOG"\n'
)

SELFTEST_ASYNC_BAD = SELFTEST_GOOD + (
    'trap \'echo "$(date +%s.%N) event=stage pid=$$ name=cleanup" >> "$LAUNCH_LOG"\' EXIT\n'
)


def selftest():
    """check the well-formed sample and each planted-defect sample"""
    good = check(SELFTEST_GOOD)
    if good:
        print("SELFTEST FAILED: the well-formed control case was flagged: %s" % good,
              file=sys.stderr)
        return 1

    cases = [
        ("ORDER", SELFTEST_ORDER_BAD),
        ("FIELD-ORDER", SELFTEST_FIELD_ORDER_BAD),
        ("POST-SUMMARY-PKG", SELFTEST_POST_SUMMARY_PKG_BAD),
        ("ASYNC-WRITE", SELFTEST_ASYNC_BAD),
    ]
    for want, fixture in cases:
        got = {rule for rule, _n, _d in check(fixture)}
        if want not in got:
            print("SELFTEST FAILED: '%s' fixture did not fire the '%s' rule "
                  "(fired: %s)"
                  % (want, want, sorted(got) or "nothing"), file=sys.stderr)
            return 1

    print("selftest ok: detects ORDER, FIELD-ORDER, POST-SUMMARY-PKG and "
          "ASYNC-WRITE by name, and passes a well-formed file")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    with open(TARGET) as f:
        text = f.read()
    failures = check(text)
    if failures:
        print("rhizo-launch.sh log writes are not safely ordered:", file=sys.stderr)
        for rule, n, detail in failures:
            print("  %s:%d [%s] %s" % (os.path.relpath(TARGET), n, rule, detail),
                  file=sys.stderr)
        return 1
    print("every rhizo-launch.sh log write stays ordered before the summary line")
    return 0


if __name__ == "__main__":
    sys.exit(main())
