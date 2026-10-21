#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = ("display.sh", "window-input.sh")
FUNC = "logcat_capture_read"

REAL_LINE = ("09-12 13:29:10.240   248   295 I PowerManagerService: Going to sleep due to timeout "
             "(uid 1000, screenOffTimeout=60000, activityTimeoutWM=-1, maxDimRatio=0.20000005, "
             "maxDimDur=7000)...\n")
TIME_FORMAT_ERROR = "logcat: -t '09-12' not in time format.\n"

CASES = [
    ("a real threadtime line", REAL_LINE, True),
    ("a buffer header then a real line", "--------- beginning of main\n" + REAL_LINE, True),
    ("logcat's own time-format error", TIME_FORMAT_ERROR, False),
    ("an empty capture", "", False),
    ("an exec failure", "nsenter: failed to execute /system/bin/toybox: Permission denied\n", False),
    ("a bare buffer header", "--------- beginning of main\n", False),
]

COUNT_RE = re.compile(r'grep\s+-c[a-zA-Z]*E[a-zA-Z]*\s+"\$TEST_FATAL_RE"\s+(.*)$')
READ_RE = re.compile(r'^\s*if\s+!\s+%s\s+("[^"]+")\s*;\s*then\s*$' % FUNC)


def system_test_file(tools, name):
    """return the file of the named system test"""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "system", "run"))
    import system_tests
    return system_tests.test_path(name, tools) or os.path.join(tools, name)


def extract_function(text, name):
    """return the text of a shell function, or None"""
    lines = text.split("\n")
    for i, l in enumerate(lines):
        if re.match(r"^%s\(\)\s*\{" % re.escape(name), l):
            for j in range(i + 1, len(lines)):
                if lines[j] == "}":
                    return "\n".join(lines[i:j + 1])
            return None
    return None


def check_behavior(name, fn):
    """return the problems when the function gives a wrong answer in any case"""
    problems = []
    for label, content, want in CASES:
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write(content)
            path = f.name
        try:
            r = subprocess.run(["bash", "-c", fn + '\n%s "$1"' % FUNC, "x", path],
                               capture_output=True, text=True, timeout=30)
        finally:
            os.unlink(path)
        if (r.returncode == 0) != want:
            problems.append("%s: %s() on %s returned %d, expected %s"
                            % (name, FUNC, label, r.returncode, "true" if want else "false"))
    return problems


def check_sweeps(name, text):
    """find unguarded fatal-line counts in a test"""
    problems = []
    lines = text.split("\n")
    counts = 0
    for i, l in enumerate(lines):
        if l.lstrip().startswith("#"):
            continue
        m = COUNT_RE.search(l)
        if not m:
            continue
        counts += 1
        src = m.group(1).split(")")[0].split("|")[0].strip()
        if src.startswith("<<<"):
            problems.append("%s:%d counts fatal lines in a here-string; "
                            "capture to a file and check it with %s()"
                            % (name, i + 1, FUNC))
            continue
        guarded = False
        for j in range(i - 1, -1, -1):
            r = READ_RE.match(lines[j])
            if r and r.group(1) == src:
                between = [x.strip() for x in lines[j + 1:i]]
                has_fail = any(re.match(r"fail\b", x) for x in between)
                else_at = [k for k, x in enumerate(between) if x == "else"]
                fi_before_else = else_at and any(x == "fi" for x in between[:else_at[0]])
                closed_after_else = else_at and any(x == "fi" for x in between[else_at[0]:])
                guarded = bool(has_fail and else_at and not fi_before_else and not closed_after_else)
                break
        if not guarded:
            problems.append("%s:%d counts fatal lines in %s without first failing when "
                            "%s() says it holds no logcat (if ! %s %s; then fail ...; else <count>)"
                            % (name, i + 1, src, FUNC, FUNC, src))
    if counts == 0:
        problems.append("%s has no fatal sweep (grep -cE \"$TEST_FATAL_RE\" <file>) to check" % name)
    return problems


def check(texts):
    """return the problems in the logcat sweep of each test"""
    problems = []
    fns = {}
    for name in TESTS:
        text = texts.get(name)
        if text is None:
            problems.append("%s: not found" % name)
            continue
        fn = extract_function(text, FUNC)
        if fn is None:
            problems.append("%s defines no %s()" % (name, FUNC))
        else:
            fns[name] = fn
            problems += check_behavior(name, fn)
        problems += check_sweeps(name, text)
    if len(fns) == len(TESTS) and len(set(fns.values())) != 1:
        problems.append("%s() differs between %s" % (FUNC, " and ".join(TESTS)))
    return problems


GOOD_FN = r'''logcat_capture_read() {
  grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' "$1"
}'''

GOOD_SWEEP = '''
logcat_vm "$INIT" -d -t "$TEST_SINCE" 2>/dev/null > "$EV/logcat-since-start.txt"
if ! logcat_capture_read "$EV/logcat-since-start.txt"; then
  fail "the fatal sweep read no logcat"
else
  bad=$(grep -cE "$TEST_FATAL_RE" "$EV/logcat-since-start.txt")
  log "    fatal/watchdog lines in logcat: $bad"
fi
'''

PRE_FIX_DISPLAY = '''
logcat_vm "$INIT" -d -t "$TEST_SINCE" 2>/dev/null > "$EV/logcat-since-start.txt"
bad=$(grep -cE "$TEST_FATAL_RE" "$EV/logcat-since-start.txt")
log "    fatal/watchdog lines in logcat: $bad"
'''

PRE_FIX_WINDOW = '''
logcat_out=$(android_sh "$INIT" "logcat -d -b all -t 8000" 2>/dev/null)
bad=$(grep -cE "$TEST_FATAL_RE" <<<"$logcat_out" || true)
'''


def selftest():
    """check the fixed shape and each planted-defect copy"""
    def tests(fn, sweep):
        """return test texts holding a function and a sweep"""
        return {g: "#!/bin/bash\n" + (fn + "\n" if fn else "") + sweep for g in TESTS}

    got = check(tests(GOOD_FN, GOOD_SWEEP))
    if got:
        print("selftest FAIL: the fixed shape was refused:\n  " + "\n  ".join(got))
        return 1
    mutations = [
        ("test-display's pre-fix sweep", tests(None, PRE_FIX_DISPLAY),
         ["defines no logcat_capture_read()", "without first failing"]),
        ("test-window-input's pre-fix sweep", tests(None, PRE_FIX_WINDOW),
         ["counts fatal lines in a here-string"]),
        ("a size test instead of a threadtime line",
         tests("logcat_capture_read() {\n  [ -s \"$1\" ]\n}", GOOD_SWEEP),
         ["on logcat's own time-format error returned 0", "on an exec failure returned 0"]),
        ("the count sits after the fi",
         tests(GOOD_FN, GOOD_SWEEP.replace("else\n  bad=", "fi\nbad=").replace(
             '"$bad"\nfi\n', '"$bad"\n')),
         ["without first failing"]),
        ("read check with no fail",
         tests(GOOD_FN, GOOD_SWEEP.replace('fail "the fatal sweep read no logcat"', 'log "x"')),
         ["without first failing"]),
        ("read check on a different file",
         tests(GOOD_FN, GOOD_SWEEP.replace('if ! logcat_capture_read "$EV/logcat-since-start.txt"',
                                           'if ! logcat_capture_read "$EV/other.txt"')),
         ["without first failing"]),
        ("one copy drifted",
         {TESTS[0]: "#!/bin/bash\n" + GOOD_FN + "\n" + GOOD_SWEEP,
          TESTS[1]: "#!/bin/bash\n" + GOOD_FN.replace("[VDIWEFA]", "[VDIWEF]") + "\n" + GOOD_SWEEP},
         ["differs between"]),
    ]
    bad = 0
    for label, texts, expects in mutations:
        got = check(texts)
        for e in expects:
            if not any(e in p for p in got):
                print("selftest FAIL: %s -- expected a problem containing %r, got:\n  %s"
                      % (label, e, "\n  ".join(got) or "(none)"))
                bad = 1
    if bad:
        return 1
    print("selftest ok: the fixed shape passes; %d broken shapes are each refused by name" % len(mutations))
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    tools = os.path.join(HERE, "..", "..", "..", "system")
    if "--tools" in sys.argv:
        tools = sys.argv[sys.argv.index("--tools") + 1]
    texts = {}
    for g in TESTS:
        p = system_test_file(tools, g)
        if os.path.exists(p):
            with open(p) as f:
                texts[g] = f.read()
    problems = check(texts)
    if problems:
        for p in problems:
            print("FAIL: " + p)
        return 1
    print("ok: both system tests fail a fatal sweep over a capture that holds no logcat, with one identical read check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
