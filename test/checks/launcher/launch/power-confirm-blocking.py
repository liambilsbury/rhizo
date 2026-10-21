#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "bin", "launch-app.sh")

BLOCK_START_RE = re.compile(r'^if \[ -n "\$do_power_confirm" \]; then\s*$', re.M)
BACKGROUND_RE = re.compile(r'\)\s*>\s*/dev/null\s+2>&1\s*&\s*$', re.M)
HARDCODED_RE = re.compile(r'committed=backgrounded')
REAL_TRAILER_RE = re.compile(r'committed=\$committed')
TIMEOUT_REASON_RE = re.compile(r'reason=power-confirm-timeout')
EXIT_RE = re.compile(r'^\s*exit 1\s*$', re.M)


def strip_comments(text):
    """return the text without comment lines"""
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("#"))


def extract_power_confirm_block(text):
    """return the do_power_confirm block text"""
    code = strip_comments(text)
    m = BLOCK_START_RE.search(code)
    if not m:
        return None
    depth = 1
    out = []
    for line in code[m.end():].split("\n"):
        stripped = line.strip()
        if re.match(r"^if\b.*; then$", stripped):
            depth += 1
        elif stripped == "fi":
            depth -= 1
            if depth == 0:
                break
        out.append(line)
    else:
        return None
    return "\n".join(out)


def check(text):
    """return the failure strings for the block"""
    block = extract_power_confirm_block(text)
    if block is None:
        return ["no `if [ -n \"$do_power_confirm\" ]; then ... fi` block found"]
    failures = []
    if BACKGROUND_RE.search(block):
        failures.append("the power-confirm poll ends in `) >/dev/null 2>&1 &`: it is "
                         "dispatched backgrounded")
    if HARDCODED_RE.search(block):
        failures.append("the block hardcodes committed=backgrounded")
    if not REAL_TRAILER_RE.search(block):
        failures.append("the block's own stage=power-confirm line does not print "
                         "committed=$committed")
    if not TIMEOUT_REASON_RE.search(block):
        failures.append("no reason=power-confirm-timeout anywhere in the block")
    elif not EXIT_RE.search(block):
        failures.append("reason=power-confirm-timeout is named but nothing in the block "
                         "actually `exit 1`s")
    return failures


SELFTEST_OLD = '''if [ -n "$do_power_confirm" ]; then
  t8=$(date +%s.%N)
  (
    committed=timeout
    echo "pid=$$ logid=$logid newid=$newid newport=$newport committed=$committed t=$(date +%s.%N)" >> "$POWER_CONFIRM_SINK"
  ) >/dev/null 2>&1 &
  committed=backgrounded
  echo "stage=power-confirm t=$t8 committed=backgrounded"
fi
'''

SELFTEST_NEW = '''if [ -n "$do_power_confirm" ]; then
  t8=$(date +%s.%N)
  committed=timeout
  echo "stage=power-confirm t=$t8 committed=$committed"
  if [ "$committed" != confirmed ]; then
    echo display remove "$newid" > "$CTL"
    echo "stage=fail t=$(date +%s.%N) reason=power-confirm-timeout logid=$logid newid=$newid"
    exit 1
  fi
fi
'''

SELFTEST_NAMED_BUT_NOT_FATAL = '''if [ -n "$do_power_confirm" ]; then
  t8=$(date +%s.%N)
  committed=timeout
  echo "stage=power-confirm t=$t8 committed=$committed"
  if [ "$committed" != confirmed ]; then
    echo "stage=note t=$(date +%s.%N) reason=power-confirm-timeout logid=$logid newid=$newid"
  fi
fi
'''


def selftest():
    """check the backgrounded and fixed samples"""
    old = check(SELFTEST_OLD)
    if not old:
        print("SELFTEST FAILED: the backgrounded form was accepted",
              file=sys.stderr)
        return 1
    old_set = set(old)
    for want in ("dispatched backgrounded", "hardcodes committed=backgrounded"):
        if not any(want in f for f in old_set):
            print("SELFTEST FAILED: the old form was rejected, but not for %r (got: %s)"
                  % (want, old), file=sys.stderr)
            return 1

    named_not_fatal = check(SELFTEST_NAMED_BUT_NOT_FATAL)
    if not any("nothing in the block actually `exit 1`s" in f for f in named_not_fatal):
        print("SELFTEST FAILED: a named-but-not-fatal reason was not rejected by name (got: %s)"
              % named_not_fatal, file=sys.stderr)
        return 1

    new = check(SELFTEST_NEW)
    if new:
        print("SELFTEST FAILED: the fixed, synchronous, fail-loud form was rejected: %s" % new,
              file=sys.stderr)
        return 1

    print("selftest ok: the backgrounded trailer is rejected by name, a named "
          "reason nobody exits on is rejected by name, and the fixed synchronous form passes")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    if not os.path.exists(TARGET):
        print("power-confirm-blocking.py: %s not found" % TARGET, file=sys.stderr)
        return 1
    with open(TARGET) as f:
        failures = check(f.read())
    if failures:
        for f in failures:
            print("FAIL: %s" % f, file=sys.stderr)
        return 1
    print("rhizo-launch-app.sh confirms power synchronously on the display-add path, and "
          "fails the launch loudly, by name, if a display never powers on")
    return 0


if __name__ == "__main__":
    sys.exit(main())
