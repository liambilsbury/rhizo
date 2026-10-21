#!/usr/bin/env python3
import os
import re
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
TEARDOWN = "src/install/teardown/teardown.sh"
LIB = "src/install/lib/pkg-lib.sh"
RESTORE_DEF = re.compile(r"^(pkg_\w+_restore)\(\)\s*\{", re.M)
VERIFY_OPEN = re.compile(r'^if \[\[ "\$MODE" == verify \]\]; then$')


def verify_span(lines):
    """return the line span of the teardown's --verify block"""
    for i, line in enumerate(lines):
        if VERIFY_OPEN.match(line):
            for j in range(i + 1, len(lines)):
                if lines[j] == "fi":
                    return i, j
    return None


def problems(lib_text, teardown_text):
    """return each restore the teardown misses or runs inside --verify"""
    lines = teardown_text.splitlines()
    span = verify_span(lines)
    if span is None:
        return ["%s: no `if [[ \"$MODE\" == verify ]]; then` block to tell the removal path from" % TEARDOWN]
    bad = []
    for name in RESTORE_DEF.findall(lib_text):
        calls = [i for i, line in enumerate(lines) if re.search(r"\b%s\b" % name, line)]
        if not [i for i in calls if not span[0] <= i <= span[1]]:
            bad.append("%s: %s is never called on the removal path"
                       % (TEARDOWN, name))
        for i in calls:
            if span[0] <= i <= span[1]:
                bad.append("%s:%d: %s runs inside --verify" % (TEARDOWN, i + 1, name))
    return bad


def selftest():
    """check that misplaced and missing restores are flagged"""
    lib = "pkg_a_restore() {\n  :\n}\npkg_b_restore() {\n  :\n}\n"
    good = ('if [[ "$MODE" == verify ]]; then\n  echo report\n  exit 0\nfi\n'
            "pkg_a_restore\npkg_b_restore\n")
    in_verify = ('if [[ "$MODE" == verify ]]; then\n  echo report\npkg_b_restore\n  exit 0\nfi\npkg_a_restore\n')
    missing = 'if [[ "$MODE" == verify ]]; then\n  exit 0\nfi\npkg_a_restore\n'
    rc = 0
    if problems(lib, good):
        print("FAIL the removal-path calls were flagged: %s" % problems(lib, good))
        rc = 1
    got = problems(lib, in_verify)
    if not any("pkg_b_restore runs inside --verify" in g for g in got) or \
            not any("pkg_b_restore is never called" in g for g in got):
        print("FAIL a restore inside --verify was not flagged both ways: %s" % got)
        rc = 1
    if not any("pkg_b_restore is never called" in g for g in problems(lib, missing)):
        print("FAIL a missing restore was not flagged")
        rc = 1
    if rc == 0:
        print("teardown config restores selftest: ok (3 cases)")
    return rc


def main():
    """check the teardown or run the selftest"""
    if "--selftest" in sys.argv[1:] and selftest():
        return 1
    with open(os.path.join(REPO, LIB)) as f:
        lib = f.read()
    with open(os.path.join(REPO, TEARDOWN)) as f:
        teardown = f.read()
    bad = problems(lib, teardown)
    for b in bad:
        print("FAIL %s" % b)
    if not bad:
        print("teardown config restores: ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
