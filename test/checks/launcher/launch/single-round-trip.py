#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "host", "launch-app.sh")

FUNC_START = re.compile(r"^ash_inline\(\)\s*\{")
CALL_RE = re.compile(r'ash_inline "|nsenter -a -t "\$INIT"|"\$PROBE_CLIENT"')


def strip_function_body(lines):
    """remove the ash_inline definition from the lines"""
    out = []
    in_func = False
    for line in lines:
        if not in_func and FUNC_START.match(line):
            in_func = True
            continue
        if in_func:
            if line.strip() == "}":
                in_func = False
            continue
        out.append(line)
    return out


def strip_comments(lines):
    """return the lines without comment lines"""
    return [line for line in lines if not line.strip().startswith("#")]


def count(text):
    """return the number of call sites outside the function body and comments"""
    lines = text.splitlines()
    lines = strip_function_body(lines)
    lines = strip_comments(lines)
    return sum(len(CALL_RE.findall(line)) for line in lines)


SELFTEST_ONE = """#!/bin/sh
ash_inline() {
  out=$(nsenter -a -t "$INIT" -- /system/bin/sh -c "$*") || true
  out=$("$PROBE_CLIENT" "$PROBE_SOCK" 30 "$*")
  printf '%s' "$out"
}
# ash_inline "toybox grep -c 'display added id=' $CTLOUT" is what a comment
# describing an old call looks like -- it must not count.
out=$(ash_inline "sh /system_ext/bin/rhizo-launch-app.sh $PKG $ACT")
"""

SELFTEST_TWO = SELFTEST_ONE + (
    'before=$(ash_inline "toybox grep -c \'display added id=\' $CTLOUT")\n'
)


def selftest():
    """check the one-call and two-call samples"""
    n = count(SELFTEST_ONE)
    if n != 1:
        print("SELFTEST FAILED: the post-collapse fixture (one real call site) "
              "counted %d, expected 1" % n, file=sys.stderr)
        return 1
    n2 = count(SELFTEST_TWO)
    if n2 != 2:
        print("SELFTEST FAILED: the pre-collapse fixture (two call sites) "
              "counted %d, expected 2" % n2, file=sys.stderr)
        return 1
    print("selftest ok: counts 1 call site on the collapsed shape and 2 on "
          "the pre-collapse shape, excluding ash_inline()'s own definition "
          "and comments")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    with open(TARGET) as f:
        text = f.read()
    n = count(text)
    if n != 1:
        print("%s makes %d guest round trips outside ash_inline()'s own "
              "definition, expected exactly 1" % (os.path.relpath(TARGET), n),
              file=sys.stderr)
        return 1
    print("rhizo-launch.sh makes exactly one guest round trip")
    return 0


if __name__ == "__main__":
    sys.exit(main())
