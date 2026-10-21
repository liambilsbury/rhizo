#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEM_DIR = os.path.join(HERE, "..", "..", "..", "system")
TARGETS = ["desktop.sh"]

TRIGGER = r"[^\s\"'|;&]*rhizo-app-events/trigger"
WRITE_RE = re.compile(r">>?\s*\$?\{?[\"']?%s|tee\s+[^|;&]*%s|dd\s+[^|;&]*of=[^\s]*%s"
                       % (TRIGGER, TRIGGER, TRIGGER))


def system_test_file(tools, name):
    """return the file of the named system test"""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "system", "run"))
    import system_tests
    return system_tests.test_path(name, tools) or os.path.join(tools, name)


def strip_comments(text):
    """return the text without comment lines"""
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))


def find_direct_writes(text):
    """return the lines that write the trigger file directly"""
    code = strip_comments(text)
    return [ln.strip() for ln in code.split("\n") if WRITE_RE.search(ln)]


def check_file(path):
    """return the problems for direct trigger writes in a system test"""
    if not os.path.exists(path):
        return ["%s: system test to scan is missing" % os.path.basename(path)]
    return ["%s: %s" % (os.path.basename(path), h) for h in find_direct_writes(open(path).read())]


SELFTEST_BAD_REDIRECT = """
gcmd "mkdir -p /run/rhizo-app-events && date +%s%N > /run/rhizo-app-events/trigger" 15
"""

SELFTEST_BAD_TEE = """
gcmd "echo hi | tee /run/rhizo-app-events/trigger" 15
"""

SELFTEST_GOOD = """
gcmd "systemctl restart rhizo-app-events.service" 15 \\
  || fail "could not restart rhizo-app-events.service to re-arm its trigger"
"""

SELFTEST_COMMENT_ONLY = """
# the old approach poked /run/rhizo-app-events/trigger directly; do not do that
gcmd "systemctl restart rhizo-app-events.service" 15
"""


def selftest():
    """check the real test and each sample against whether it must be flagged"""
    real = open(system_test_file(SYSTEM_DIR, "desktop.sh")).read()
    cases = [
        ("the real desktop.sh", real, False),
        ("a raw redirect into the trigger", SELFTEST_BAD_REDIRECT, True),
        ("a tee into the trigger", SELFTEST_BAD_TEE, True),
        ("the systemctl restart form", SELFTEST_GOOD, False),
        ("only a comment mentions the old path", SELFTEST_COMMENT_ONLY, False),
    ]
    ok = True
    for label, text, want_fail in cases:
        got_fail = bool(find_direct_writes(text))
        print("  %-38s wanted fail=%-5s got fail=%-5s %s"
              % (label, want_fail, got_fail, "ok" if got_fail == want_fail else "WRONG"))
        ok = ok and (got_fail == want_fail)
    if not ok:
        print("SELFTEST FAILED", file=sys.stderr)
        return 1
    print("selftest ok: a direct write into the appwatch trigger fails, "
          "systemctl restart (and the real desktop.sh) do not")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    failures = []
    for name in TARGETS:
        failures += check_file(system_test_file(SYSTEM_DIR, name))
    if failures:
        for f in failures:
            print("FAIL: %s" % f, file=sys.stderr)
        print(file=sys.stderr)
        print("restart the service that owns the trigger "
              "('systemctl restart rhizo-app-events.service') instead of "
              "writing it directly", file=sys.stderr)
        return 1
    print("no system test writes the appwatch trigger directly over ssh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
