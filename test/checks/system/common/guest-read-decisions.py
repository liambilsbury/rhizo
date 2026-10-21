#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEM = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "system")
FIXTURE_FILES = {"sway-lib.sh": "lib/sway-lib.sh"}


def function_body(text, name):
    """return the text of a shell function, or None"""
    m = re.search(r"^%s\(\) \{.*?^\}\n" % re.escape(name), text, re.S | re.M)
    return m.group(0) if m else None


def run_bash(script):
    """run a bash script and return its exit code, output and errors"""
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)
    return p.returncode, p.stdout, p.stderr


def check(tools):
    """return the problems in how the system tests decide from guest reads"""
    bad = []
    sway = open(os.path.join(tools, "lib", "sway-lib.sh")).read()
    fn = function_body(sway, "assert_window_painted")
    if fn is None:
        bad.append("sway-lib.sh has no assert_window_painted()")
    else:
        d = tempfile.mkdtemp(prefix="rect-evidence-")
        try:
            rect = os.path.join(d, "appA-window-rect.txt")
            open(rect, "w").write("0 0 960 1080\n")
            script = ('EV=%s\nmapped_window_rect() { return 1; }\ndisplay_toplevel_unmapped_reason() { :; }\n'
                      'sway_windows() { :; }\nfail() { :; }\n%s\nassert_window_painted appA 2\n'
                      % (shlex_quote(d), fn))
            run_bash(script)
            content = open(rect).read().strip() if os.path.exists(rect) else "<missing>"
            if content == "0 0 960 1080":
                bad.append("sway-lib.sh's assert_window_painted leaves the previous run's window rect in place when "
                           "no window maps")
        finally:
            shutil.rmtree(d)
    return bad


def shlex_quote(s):
    """return a text quoted for a shell"""
    return "'" + s.replace("'", "'\"'\"'") + "'"


def selftest():
    """check the live files and each planted-defect copy"""
    live = check(SYSTEM)
    assert not live, "the live files must pass: %s" % live
    cases = [
        ("sway-lib.sh", '    echo "<none>" > "$EV/$label-window-rect.txt"\n', "",
         "leaves the previous run's window rect"),
    ]
    for name, old, new, want in cases:
        d = tempfile.mkdtemp(prefix="guest-read-mut-")
        try:
            for f in FIXTURE_FILES.values():
                os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True)
                shutil.copy(os.path.join(SYSTEM, f), os.path.join(d, f))
            text = open(os.path.join(d, FIXTURE_FILES[name])).read()
            assert old in text, "fixture anchor missing in %s" % name
            open(os.path.join(d, FIXTURE_FILES[name]), "w").write(text.replace(old, new, 1))
            got = check(d)
            assert any(want in g for g in got), "%s mutation: expected a problem naming %r, got %s" % (name, want, got)
        finally:
            shutil.rmtree(d)
    print("check-guest-read-decisions selftest: the live files pass; %d single regressions fail by name" % len(cases))


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
    print("check-guest-read-decisions: a failed paint leaves no leftover rect")
    return 0


if __name__ == "__main__":
    sys.exit(main())
