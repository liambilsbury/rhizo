#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "host", "launch-app.sh")

CALL_RE = re.compile(r"rhizo-fill-display-pool\.sh")


def strip_comments(text):
    """return the text without comment lines"""
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("#"))


def check_launch_script(text):
    """return the problems when the launch script invokes the pool fill script"""
    code = strip_comments(text)
    if CALL_RE.search(code):
        return ["rhizo-launch.sh invokes rhizo-fill-display-pool.sh"]
    return []


SELFTEST_FOREGROUND = """
PKG="${1:?package required}"
sh /root/rhizo-fill-display-pool.sh
am start -n "$PKG/$ACT"
"""

SELFTEST_BACKGROUNDED = """
PKG="${1:?package required}"
/root/rhizo-fill-display-pool.sh &
am start -n "$PKG/$ACT"
"""

SELFTEST_COMMENT_ONLY = """
# the pool is topped up out of band by rhizo-fill-display-pool.sh
PKG="${1:?package required}"
am start -n "$PKG/$ACT"
"""


def selftest():
    """check the real script and each sample"""
    real = open(TARGET).read() if os.path.exists(TARGET) else ""
    cases = [
        ("the real rhizo-launch.sh", real, False),
        ("a foreground call", SELFTEST_FOREGROUND, True),
        ("a backgrounded call", SELFTEST_BACKGROUNDED, True),
        ("only a comment mentions it", SELFTEST_COMMENT_ONLY, False),
    ]
    for label, text, want_fail in cases:
        got_fail = bool(check_launch_script(text))
        if got_fail != want_fail:
            print("SELFTEST FAILED: %s -- wanted fail=%s, got fail=%s"
                  % (label, want_fail, got_fail), file=sys.stderr)
            return 1
    print("selftest ok: the real rhizo-launch.sh passes, a foreground or backgrounded call "
          "to rhizo-fill-display-pool.sh fails, a bare comment mentioning it does not")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    if not os.path.exists(TARGET):
        print("display-pool-off-launch-path.py: %s not found" % TARGET, file=sys.stderr)
        return 1
    failures = check_launch_script(open(TARGET).read())
    if failures:
        for f in failures:
            print(f, file=sys.stderr)
        return 1
    print("rhizo-launch.sh never calls rhizo-fill-display-pool.sh")
    return 0


if __name__ == "__main__":
    sys.exit(main())
