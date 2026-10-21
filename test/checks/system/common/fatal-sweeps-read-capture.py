#!/usr/bin/env python3
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEM = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "system")
sys.path.insert(0, os.path.join(SYSTEM, "run"))
import system_tests  # noqa: E402
COUNT = re.compile(r'grep -cE "\$TEST_FATAL_RE"')
READ = re.compile(r"\b(test_)?logcat_capture_read\b")
EXEMPT = {"gsi-update.sh"}
LOOKBACK = 30


def guarded(lines, i):
    """test a capture read for a fail branch"""
    window = range(max(0, i - LOOKBACK), min(len(lines), i + 4))
    for j in window:
        l = lines[j]
        if l.lstrip().startswith("#") or not READ.search(l):
            continue
        if re.search(r"\|\|\s*fail\b", l):
            return True
        nxt = lines[j + 1] if j + 1 < len(lines) else ""
        if l.rstrip().endswith("\\") and re.match(r"^\s*\|\|\s*fail\b", nxt):
            return True
        if re.search(r"\bif !\s", l) and re.match(r"^\s*fail\b", nxt):
            return True
    return False


def check(tools):
    """return the fatal sweeps that do not read the capture"""
    bad = []
    for path in system_tests.system_test_paths(tools):
        name = os.path.basename(path)
        if name == "lib.sh" or name in EXEMPT:
            continue
        lines = open(path).read().splitlines()
        for i, l in enumerate(lines):
            if l.lstrip().startswith("#") or not COUNT.search(l):
                continue
            if not guarded(lines, i):
                bad.append("%s:%d counts fatal lines with no capture read failing the system test first" % (name, i + 1))
    return bad


def selftest():
    """check the live tests and each planted-defect fixture"""
    live = check(SYSTEM)
    assert not live, "the live system tests must pass: %s" % live

    def fixture(body):
        """return the problems for a fixture test with a body"""
        with tempfile.TemporaryDirectory(prefix="fatal-sweep-") as d:
            open(os.path.join(d, "x.sh"), "w").write(system_tests.HEADER + " x\n" + body)
            return check(d)

    guarded_body = ('logcat_vm "$INIT" -d -t "$S" > "$EV/l.txt"\n'
                    'test_logcat_capture_read "$EV/l.txt" \\\n  || fail "no logcat line"\n'
                    'bad=$(grep -cE "$TEST_FATAL_RE" "$EV/l.txt")\n')
    assert not fixture(guarded_body), "a guarded sweep must pass"
    assert not fixture(guarded_body.replace('test_logcat_capture_read "$EV/l.txt" \\\n  || fail "no logcat line"\n',
                                            'if ! logcat_capture_read "$EV/l.txt"; then\n  fail "no logcat line"\nfi\n')), \
        "an if ! ...; then fail guard must pass"
    unguarded = guarded_body.replace('test_logcat_capture_read "$EV/l.txt" \\\n  || fail "no logcat line"\n', "")
    assert fixture(unguarded), "an unguarded sweep must fail"
    logged = guarded_body.replace('  || fail "no logcat line"', '  || log "no logcat line"')
    assert fixture(logged), "a capture read that only logs must fail"

    mutations = [
        ("launcher.sh", 'test_logcat_capture_read "$EV/logcat-since-start.txt" \\\n'
                             '  || fail "$EV/logcat-since-start.txt holds no logcat line"\n', ""),
        ("storage.sh", 'if ! test_logcat_capture_read "$EV/logcat-since-start.txt"; then\n'
                            '  fail "the fatal sweep read no logcat since \'$SINCE\' -- an unreadable log is not a clean one"\n'
                            'elif [[ "$bad" != "0" ]]; then\n', 'if [[ "$bad" != "0" ]]; then\n'),
    ]
    for test, old, new in mutations:
        text = open(system_tests.test_path(test, SYSTEM) or os.path.join(SYSTEM, test)).read()
        assert old in text, "fixture anchor missing in %s" % test
        with tempfile.TemporaryDirectory(prefix="fatal-sweep-mut-") as d:
            open(os.path.join(d, test), "w").write(text.replace(old, new, 1))
            got = check(d)
        assert any(g.startswith(test + ":") for g in got), "%s without its capture read must fail: %s" % (test, got)
    print("check-fatal-sweeps-read-capture selftest: live system tests pass; an unguarded, a log-only and %d real regressions fail"
          % len(mutations))


def main():
    """run the check or its selftest"""
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    tools = sys.argv[1] if len(sys.argv) > 1 else SYSTEM
    bad = check(tools)
    for b in bad:
        print("FAIL: %s" % b)
    if bad:
        return 1
    print("check-fatal-sweeps-read-capture: every fatal-line sweep fails on a capture that holds no logcat line")
    return 0


if __name__ == "__main__":
    sys.exit(main())
