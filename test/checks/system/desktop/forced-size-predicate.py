#!/usr/bin/env python3
import os
import re
import subprocess
import sys

HERE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))), "system")
TESTS = ("display.sh", "window-input.sh")
FUNC = "forced_size_displays"

REAL = """\
  Display: mDisplayId=0 (organized)
    init=1280x800 213dpi mMinSizeOfResizeableTaskDp=220 cur=1280x800 app=1280x800 rng=800x800-1280x1280
    deferred=false mLayoutNeeded=false
  Display: mDisplayId=13 (organized)
    init=960x1080 546dpi mMinSizeOfResizeableTaskDp=220 cur=960x1080 app=960x1080 rng=960x960-1080x1080
    deferred=false mLayoutNeeded=false
"""

FORCED = """\
  Display: mDisplayId=0 (organized)
    init=1920x1080 213dpi mMinSizeOfResizeableTaskDp=220 cur=1920x1080 app=1920x1080 rng=1080x1080-1920x1920
    deferred=false mLayoutNeeded=false
  Display: mDisplayId=2 (organized)
    init=640x480 546dpi mMinSizeOfResizeableTaskDp=220 base=960x1080 546dpi cur=960x1080 app=960x1080 rng=960x960-1080x1080
    deferred=false mLayoutNeeded=false
  Display: mDisplayId=3 (organized)
    init=960x1080 546dpi mMinSizeOfResizeableTaskDp=220 cur=960x1080 app=960x1080 rng=960x960-1080x1080
    deferred=false mLayoutNeeded=false
"""

FORCED_NOSCALE = """\
  Display: mDisplayId=0 (organized)
    init=1920x1080 213dpi mMinSizeOfResizeableTaskDp=220 cur=1920x1080 app=1920x1080 rng=1080x1080-1920x1920
    deferred=false mLayoutNeeded=false
  Display: mDisplayId=5 (organized)
    init=1920x1080 546dpi mMinSizeOfResizeableTaskDp=220 base=960x1080 546dpi noscale
 cur=960x1080 app=960x1080 rng=960x960-1080x1080
    deferred=false mLayoutNeeded=false
  Display: mDisplayId=7 (organized)
    init=640x480 546dpi mMinSizeOfResizeableTaskDp=220 base=1280x720 546dpi cur=1280x720 app=1280x720 rng=720x720-1280x1280
    deferred=false mLayoutNeeded=false
"""

DENSITY_ONLY = """\
  Display: mDisplayId=2 (organized)
    init=960x1080 546dpi mMinSizeOfResizeableTaskDp=220 base=960x1080 1092dpi cur=960x1080 app=960x1080 rng=960x960-1080x1080
    deferred=false mLayoutNeeded=false
"""

UNREADABLE = "runcon: exec /system/bin/sh: Permission denied\n"

CASES = [
    ("real dump text, nothing forced", REAL, []),
    ("forced display 2 after a resize", FORCED, ["2"]),
    ("forced displays 5 (noscale) and 7", FORCED_NOSCALE, ["5", "7"]),
    ("density override at the same size", DENSITY_ONLY, []),
    ("empty dumpsys", "", None),
    ("exec failure text instead of a dump", UNREADABLE, None),
]

CALL_RE = re.compile(r'^\s*(\w+)=\$\(%s <<<"\$(\w+)"\); (\w+)=\$\?\s*$' % FUNC)
SIZEFORCED_GREP_RE = re.compile(r"\bgrep\b.*SizeForced")


def system_test_file(tools, name):
    """return the file of the named system test"""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "system", "run"))
    import system_tests
    return system_tests.test_path(name, tools) or os.path.join(tools, name)


def code(line):
    """return an empty string for a comment line"""
    return "" if line.lstrip().startswith("#") else line


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


def run_function(fn, stdin):
    """run a function with stdin and return its exit code and output lines"""
    r = subprocess.run(["bash", "-c", fn + "\n" + FUNC], input=stdin,
                       capture_output=True, text=True, timeout=30)
    return r.returncode, [l for l in r.stdout.split("\n") if l.strip()]


def check_behavior(name, fn):
    """return the problems when the function gives a wrong answer in any case"""
    problems = []
    for label, stdin, want in CASES:
        rc, ids = run_function(fn, stdin)
        if want is None:
            if rc == 0:
                problems.append("%s: %s() returned 0 on %s (printed %s)" % (name, FUNC, label, ids or "nothing"))
        elif rc != 0 or ids != want:
            problems.append("%s: %s() on %s gave rc=%d ids=%s, expected rc=0 ids=%s"
                            % (name, FUNC, label, rc, ids, want))
    return problems


def check_callers(name, text):
    """return the problems in the predicate's callers"""
    problems = []
    lines = text.split("\n")
    calls = 0
    for i, l in enumerate(lines):
        if SIZEFORCED_GREP_RE.search(code(l)):
            problems.append("%s:%d greps for SizeForced, a string DisplayContent.dump() never "
                            "prints" % (name, i + 1))
        m = CALL_RE.match(l)
        if not m:
            continue
        calls += 1
        out_var, dump_var, rc_var = m.groups()
        dump_re = re.compile(r'^\s*%s=\$\(android_sh "\$INIT" "dumpsys window displays"\)\s*$'
                             % re.escape(dump_var))
        if not any(dump_re.match(x) for x in lines[:i]):
            problems.append("%s:%d feeds %s() $%s, which is never assigned from "
                            "android_sh \"$INIT\" \"dumpsys window displays\" above it"
                            % (name, i + 1, FUNC, dump_var))
        after = "\n".join(lines[i + 1:i + 9])
        if not re.search(r'\(\(\s*%s\s*==\s*0\s*\)\)\s*\|\|\s*fail\b' % re.escape(rc_var), after):
            problems.append("%s:%d never fails on %s()'s nonzero rc ($%s) within 8 lines"
                            % (name, i + 1, FUNC, rc_var))
        if not re.search(r'\[\[\s*-z\s*"\$%s"\s*\]\]\s*\|\|\s*fail\b' % re.escape(out_var), after):
            problems.append("%s:%d never fails on a display id %s() printed ($%s) within 8 lines"
                            % (name, i + 1, FUNC, out_var))
    if calls == 0:
        problems.append("%s never calls %s() the way the guard must: "
                        "VAR=$(%s <<<\"$DUMP\"); RC=$?" % (name, FUNC, FUNC))
    return problems


def check(texts):
    """return the problems in the system tests"""
    problems = []
    fns = {}
    for name in TESTS:
        text = texts.get(name)
        if text is None:
            problems.append("%s: not found" % name)
            continue
        fn = extract_function(text, FUNC)
        if fn is None:
            problems.append("%s defines no %s() closed by a column-0 }" % (name, FUNC))
        else:
            fns[name] = fn
            problems += check_behavior(name, fn)
        problems += check_callers(name, text)
    if len(fns) == len(TESTS) and len(set(fns.values())) != 1:
        problems.append("%s() differs between %s" % (FUNC, " and ".join(TESTS)))
    return problems


GOOD_FN = r'''forced_size_displays() {
  awk '
    /^[[:space:]]*Display: mDisplayId=[0-9]+/ {
      seen = 1
      id = $0; sub(/.*mDisplayId=/, "", id); sub(/[^0-9].*/, "", id)
      next
    }
    id != "" && /^[[:space:]]*init=[0-9]+x[0-9]+ / {
      init = $0; sub(/^[[:space:]]*init=/, "", init); sub(/ .*/, "", init)
      if (match($0, / base=[0-9]+x[0-9]+ /) && substr($0, RSTART + 6, RLENGTH - 7) != init) print id
      id = ""
    }
    END { if (!seen) exit 2 }
  '
}'''

GOOD_CALLER = '''
wm_displays=$(android_sh "$INIT" "dumpsys window displays")
forced=$(forced_size_displays <<<"$wm_displays"); forced_rc=$?
(( forced_rc == 0 )) || fail "could not read dumpsys window displays"
[[ -z "$forced" ]] || fail "displays $forced are at a forced size"
'''

PRE_FIX_CALLER = '''
forced=$(android_sh "$INIT" "dumpsys window displays" | grep -c "mIsSizeForced=true")
[[ "$forced" == "0" ]] || fail "a display is using a forced size"
'''


def test_text(fn, caller):
    """return a test script text with a function and a caller"""
    return "#!/bin/bash\n" + (fn + "\n" if fn else "") + caller


def selftest():
    """check the fixed shape and each planted-defect copy"""
    good = {g: test_text(GOOD_FN, GOOD_CALLER) for g in TESTS}
    got = check(good)
    if got:
        print("selftest FAIL: the fixed shape was refused:\n  " + "\n  ".join(got))
        return 1
    mutations = [
        ("pre-fix guard (grep mIsSizeForced, no predicate)",
         {g: test_text(None, PRE_FIX_CALLER) for g in TESTS},
         ["greps for SizeForced", "defines no forced_size_displays()"]),
        ("one copy drifted by a byte",
         {TESTS[0]: test_text(GOOD_FN, GOOD_CALLER),
          TESTS[1]: test_text(GOOD_FN.replace("id = \"\"", "id = \"\" "), GOOD_CALLER)},
         ["differs between"]),
        ("compares the whole base token, density included",
         {g: test_text(GOOD_FN.replace("RLENGTH - 7) != init", "RLENGTH - 7) \"\" != init \" 546dpi\"")
                       .replace(r"/ base=[0-9]+x[0-9]+ /", r"/ base=[0-9]+x[0-9]+ [0-9]+dpi/"), GOOD_CALLER)
          for g in TESTS},
         ["density override at the same size"]),
        ("reads nothing and returns 0",
         {g: test_text(GOOD_FN.replace("END { if (!seen) exit 2 }", ""), GOOD_CALLER) for g in TESTS},
         ["returned 0 on empty dumpsys", "returned 0 on exec failure text"]),
        ("prints ids but the caller never fails on them",
         {g: test_text(GOOD_FN, GOOD_CALLER.replace('[[ -z "$forced" ]] || fail', 'log')) for g in TESTS},
         ["never fails on a display id"]),
        ("caller ignores the rc",
         {g: test_text(GOOD_FN, GOOD_CALLER.replace('(( forced_rc == 0 )) || fail', 'log')) for g in TESTS},
         ["never fails on forced_size_displays()'s nonzero rc"]),
        ("fed something other than dumpsys window displays",
         {g: test_text(GOOD_FN, GOOD_CALLER.replace('"dumpsys window displays"', '"dumpsys display"'))
          for g in TESTS},
         ["never assigned from"]),
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
    tools = HERE
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
    print("ok: both system tests judge a forced display size by base= against init=, with one identical body")
    return 0


if __name__ == "__main__":
    sys.exit(main())
