#!/usr/bin/env python3
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GUEST = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "bin", "launch-app.sh")
LAUNCH = os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "host", "launch-app.sh")
PKG = "com.rhizo.deskapp"
DISPLAY = 5


def rec(pkg, act="MainActivity", task=9):
    """return an ActivityRecord line for a package, activity and task"""
    return "ActivityRecord{1a2b3c u0 %s/.%s t%d}" % (pkg, act, task)


def display(n, top_pkg):
    """return a Display segment of dumpsys output"""
    body = "Display #%d (activities from top to bottom):\n" % n
    if top_pkg is None:
        return body + "  * Task{7f2b59f #11 type=standard U=0 visible=true sz=1}\n    isSleeping=false\n"
    return body + ("  * Task{7f2b59f #11 type=standard A=10105:%s U=0 visible=true sz=1}\n"
                   "    isSleeping=false\n"
                   "    topResumedActivity=%s\n"
                   "    * Hist  #0: %s\n" % (top_pkg, rec(top_pkg), rec(top_pkg)))


HOME = "com.android.launcher3"
OTHER = "org.example.other"


def covered_display(n, top_pkg, under_pkg):
    """return a segment with a covered top task"""
    return ("Display #%d (activities from top to bottom):\n"
            "  * Task{aaa #12 type=standard A=10106:%s U=0 visible=true sz=1}\n"
            "    isSleeping=false\n"
            "    * Hist  #0: %s\n"
            "  * Task{bbb #11 type=standard A=10105:%s U=0 visible=false sz=1}\n"
            "    topResumedActivity=%s\n" % (n, top_pkg, rec(top_pkg), under_pkg, rec(under_pkg)))


def dump(*segments, global_top=None):
    """return a dumpsys activity text from segments"""
    text = "ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)\n" + "\n".join(segments)
    if global_top:
        text += "\n  ResumedActivity: %s\n  topResumedActivity=%s\n" % (rec(global_top), rec(global_top))
    return text


ALIVE = ["4242"]
CASES = [
    ("Home first, the app on the second read",
     [dump(display(0, HOME), display(DISPLAY, HOME)), dump(display(0, HOME), display(DISPLAY, PKG))], 0),
    ("the app never on its display",
     [dump(display(0, HOME), display(DISPLAY, HOME))], 1),
    ("the app resumed on another display, Home on its own",
     [dump(display(7, PKG), display(DISPLAY, HOME), global_top=PKG)], 1),
    ("another window is the system-wide top, the app tops its own display",
     [dump(display(0, OTHER), display(DISPLAY, PKG), global_top=OTHER)], 0),
    ("the display's line transiently absent, then the app",
     [dump(display(DISPLAY, None)), dump(display(DISPLAY, PKG))], 0),
    ("the app resumed on another display, its own listed last and empty",
     [dump(display(7, PKG), display(DISPLAY, None), global_top=PKG)], 1),
    ("another package's task tops the display, the app's task under it",
     [dump(covered_display(DISPLAY, OTHER, PKG))], 1),
    ("am start reported an error",
     [dump(display(DISPLAY, HOME))], 2, ALIVE,
     "Starting: Intent { cmp=%s/.MainActivity }\nError: Activity class {%s/%s.MainActivity} does not exist.\n"
     % (PKG, PKG, PKG)),
    ("the app's process died before it topped its display",
     [dump(display(DISPLAY, HOME))], 3, ["4242", "4242", ""]),
    ("the app's process never appears",
     [dump(display(DISPLAY, HOME))], 1, [""]),
]
DEADLINE_S = 3
SCOPE_CASES = {"the app resumed on another display, Home on its own"}
EXIT_MUTANTS = [
    ('elif [ -n "$_seen" ]; then return 3; fi', "fi",
     "the app's process died before it topped its display"),
    ('*"Error:"*|*"Exception occurred"*) return 2 ;;', "__never_matches__) return 2 ;;",
     "am start reported an error"),
]
END_MUTANTS = [
    ("inseg && (/^[^ ]/ || /^ *ResumedActivity: / || /Resumed activities/) { exit }\n", "",
     "the app resumed on another display, its own listed last and empty"),
    ("if (ti && i <= ti) exit; ", "",
     "another package's task tops the display, the app's task under it"),
]


def extract(text, name):
    """return the text of a shell function, or None"""
    m = re.search(r"^%s\(\) \{.*?^\}\n" % re.escape(name), text, re.M | re.S)
    return m.group(0) if m else None


def assignments(text, names):
    """return the lines assigning each name, or None when one is missing"""
    out = []
    for n in names:
        m = re.search(r"^%s=\S+" % re.escape(n), text, re.M)
        if not m:
            return None
        out.append(m.group(0))
    return "\n".join(out) + "\n"


def harness(inner_text):
    """return the guest script functions and constants"""
    parts = []
    for fn in ("poll_sleep", "on_top_now", "await_on_top"):
        body = extract(inner_text, fn)
        if body is None:
            return None, "no %s() in rhizo-launch-app.sh" % fn
        parts.append(body)
    consts = assignments(inner_text, ("POLL_TICK_S", "POLL_FAST_TICK_S"))
    if consts is None:
        return None, "POLL_TICK_S or POLL_FAST_TICK_S missing"
    return consts + "POLL_LAST_TICK_MS=0\n" + "".join(parts), None


def scripted(root, bin_, name, answers):
    """write a stub command with scripted output"""
    for i, a in enumerate(answers):
        with open(os.path.join(root, "%s.%d" % (name, i)), "w") as f:
            f.write(a)
    count = os.path.join(root, name + ".n")
    with open(os.path.join(bin_, name), "w") as f:
        f.write('#!/bin/sh\nn=$(cat "%s" 2>/dev/null || echo 0)\n'
                'f="%s/%s.$n"; [ -f "$f" ] || f="%s/%s.%d"\ncat "$f"\n'
                'echo $((n + 1)) > "%s"\n'
                '[ -s "$f" ]\n' % (count, root, name, root, name, len(answers) - 1, count))
    os.chmod(os.path.join(bin_, name), 0o755)
    return count


def run_case(lib, answers, pids=ALIVE, am_out=""):
    """run await_on_top and return the measurements"""
    root = tempfile.mkdtemp(prefix="launch-on-top-")
    try:
        bin_ = os.path.join(root, "bin")
        os.makedirs(bin_)
        reads_file = scripted(root, bin_, "dumpsys", answers)
        scripted(root, bin_, "pidof", [p + "\n" if p else "" for p in pids])
        with open(os.path.join(root, "am_out"), "w") as f:
            f.write(am_out)
        script = lib + ('PKG=%s\nAM_OUT=$(cat %s/am_out)\nt0=$(date +%%s)\n'
                        'await_on_top %d $((t0 + %d))\n' % (PKG, root, DISPLAY, DEADLINE_S))
        env = dict(os.environ, PATH=bin_ + ":" + os.environ.get("PATH", "/usr/bin:/bin"))
        t0 = time.monotonic()
        r = subprocess.run(["/bin/sh", "-c", script], env=env, capture_output=True, text=True, timeout=60)
        took = time.monotonic() - t0
        reads = int(open(reads_file).read().strip() or 0) if os.path.exists(reads_file) else 0
        return r.returncode, reads, took
    finally:
        shutil.rmtree(root, ignore_errors=True)


def check(inner_text):
    """run each case against await_on_top"""
    lib, why = harness(inner_text)
    if lib is None:
        return [why], None
    bad = []
    for case in CASES:
        name, answers, want = case[:3]
        rc, reads, took = run_case(lib, answers, *case[3:])
        if rc != want:
            bad.append("%s: await_on_top returned %d, want %d (%d dumpsys read(s), %.1fs)"
                       % (name, rc, want, reads, took))
        elif want == 0 and reads != len(answers):
            bad.append("%s: returned after %d read(s), want %d"
                       % (name, reads, len(answers)))
        elif want == 1 and took < DEADLINE_S - 1:
            bad.append("%s: gave up after %.1fs, before the %ds deadline it was handed" % (name, took, DEADLINE_S))
        elif want in (2, 3) and took >= DEADLINE_S - 1:
            bad.append("%s: took %.1fs, waiting out the deadline instead of failing at the event" % (name, took))
        elif want == 2 and reads:
            bad.append("%s: read dumpsys %d time(s) after am start already failed" % (name, reads))
    return bad, lib


LIVE = "0\n%d\n7\n" % DISPLAY
ON_DISPLAY_CASES = [
    ("the app tops its own display", dump(display(0, HOME), display(DISPLAY, PKG)), LIVE, 0),
    ("the app's task under another package's on its own display",
     dump(covered_display(DISPLAY, OTHER, PKG)), LIVE, 0),
    ("the app on another display, Home on its own",
     dump(display(7, PKG), display(DISPLAY, HOME), global_top=PKG), LIVE, 1),
    ("its display gone, the app on another", dump(display(0, HOME), display(7, PKG)), "0\n7\n", 1),
    ("the app on another display, its own listed last and empty",
     dump(display(7, PKG), display(DISPLAY, None), global_top=PKG), LIVE, 1),
    ("the app on a display the display manager removed", dump(display(0, HOME), display(DISPLAY, PKG)),
     "0\n7\n", 1),
]
ON_DISPLAY_MUTANTS = [
    ("inseg && index($0, pkg)", "index($0, pkg)", "the app on another display, Home on its own"),
    ("  cmd display get-displays -i 2>/dev/null | toybox grep -qx \"$2\" || return 1\n", "",
     "the app on a display the display manager removed"),
    ("    inseg && (/^[^ ]/ || /^ *ResumedActivity: / || /Resumed activities/) { exit }\n", "",
     "the app on another display, its own listed last and empty"),
]


def check_on_display(inner_text):
    """run each case against on_display_now"""
    body = extract(inner_text, "on_display_now")
    if body is None:
        return ["no on_display_now() in rhizo-launch-app.sh"]
    bad = []
    for name, answer, live, want in ON_DISPLAY_CASES:
        root = tempfile.mkdtemp(prefix="launch-on-display-")
        try:
            bin_ = os.path.join(root, "bin")
            os.makedirs(bin_)
            scripted(root, bin_, "dumpsys", [answer])
            scripted(root, bin_, "cmd", [live])
            with open(os.path.join(bin_, "toybox"), "w") as f:
                f.write('#!/bin/sh\nexec "$@"\n')
            os.chmod(os.path.join(bin_, "toybox"), 0o755)
            env = dict(os.environ, PATH=bin_ + ":" + os.environ.get("PATH", "/usr/bin:/bin"))
            r = subprocess.run(["/bin/sh", "-c", body + "on_display_now %s %d\n" % (PKG, DISPLAY)],
                               env=env, capture_output=True, text=True, timeout=30)
        finally:
            shutil.rmtree(root, ignore_errors=True)
        if r.returncode != want:
            bad.append("%s: on_display_now returned %d, want %d" % (name, r.returncode, want))
    if not re.search(r'^if \[ -n "\$REUSE_CID" \] && ! on_display_now "\$PKG" "\$REUSE_LOGID"; then$',
                     inner_text, re.M):
        bad.append("rhizo-launch-app.sh does not drop the app's own display once on_display_now says it left")
    return bad


OWN_LOG = """1.1 event=am_start_return pid=1 pkg=com.a activity=.M display=3 cdisplay=2 bus=bus0
2.1 event=am_start_return pid=2 pkg=com.a activity=.M display=5 cdisplay=4 bus=bus0 init=100
2.2 event=am_start_return pid=3 pkg=com.b activity=.M display=6 cdisplay=5 bus=bus1 init=100
3.1 event=am_start_return pid=4 pkg=com.a activity=.M display=7 cdisplay=6 bus=bus0 init=200
3.2 event=am_start_return pid=5 pkg=com.ab activity=.M display=9 cdisplay=8 bus=bus2 init=200
1.2 pkg=com.a activity=.M display=11 cdisplay=10 bus=bus0 committed=ON
"""
OWN_CASES = [
    ("the newest record of this package from this sandbox", "com.a", "200", "", "7 6"),
    ("an earlier sandbox's record is not this one's", "com.a", "100", "", "5 4"),
    ("a package whose name extends another's is its own", "com.ab", "200", "", "9 8"),
    ("a package never launched in this sandbox has none", "com.b", "200", "", ""),
    ("a record with no init= is never taken", "com.a", "999", "", ""),
    ("RHIZO_REUSE_DISPLAY set takes no candidate", "com.a", "200", "4", ""),
]


def own_block(launch_text):
    """return the own_logid candidate block of the launch script, or None"""
    m = re.search(r'^own_logid=""\n.*?(?=^pool_logid=""$)', launch_text, re.M | re.S)
    return m.group(0) if m else None


def check_own_candidate(launch_text):
    """return the candidate block problems"""
    block = own_block(launch_text)
    if block is None:
        return ["rhizo-launch.sh has no own_logid candidate block before the pool pop"]
    bad = []
    with tempfile.NamedTemporaryFile("w", suffix=".log") as log:
        log.write(OWN_LOG)
        log.flush()
        for name, pkg, init, reuse, want in OWN_CASES:
            env = dict(os.environ, PKG=pkg, INIT=init, LAUNCH_LOG=log.name)
            env.pop("RHIZO_REUSE_DISPLAY", None)
            if reuse:
                env["RHIZO_REUSE_DISPLAY"] = reuse
            r = subprocess.run(["/bin/sh", "-c", block + 'echo "$own_logid $own_cid"\n'],
                               env=env, capture_output=True, text=True, timeout=30)
            got = r.stdout.strip()
            if got != want:
                bad.append("%s: candidate %r, want %r" % (name, got, want))
    return bad


def main():
    """run the checks and print the result"""
    selftest = "--selftest" in sys.argv[1:]
    name = "check-launch-on-top" + (" --selftest" if selftest else "")
    text = open(GUEST).read()
    launch = open(LAUNCH).read()
    bad, _ = check(text)
    bad += check_on_display(text) + check_own_candidate(launch)
    call = re.search(r'await_on_top "\$logid" "\$ON_TOP_DEADLINE"', text)
    if not call:
        bad.append('rhizo-launch-app.sh does not call await_on_top "$logid" "$ON_TOP_DEADLINE"')
    for rc, reason in ((1, "not-on-top"), (2, "launch-error"), (3, "process-died")):
        if not re.search(r"^\s*%d\) on_top_why=%s ;;" % (rc, reason), text, re.M):
            bad.append("rhizo-launch-app.sh does not report reason=%s for await_on_top's %d" % (reason, rc))
    if bad:
        print("FAIL: %s: %s" % (name, "; ".join(bad)))
        return 1
    if not selftest:
        print("%s: OK (%d cases: a launch returns once its app tops its own display, and only then)"
              % (name, len(CASES)))
        return 0
    body = extract(text, "on_top_now")
    blind = body.replace("inseg && /topResumedActivity=/", "/topResumedActivity=/")
    if blind == body:
        print("%s: FAIL -- on_top_now has no `inseg && ` display scoping to cut out" % name)
        return 1
    mutant_bad, _ = check(text.replace(body, blind))
    caught = {c for c in SCOPE_CASES if any(b.startswith(c + ":") for b in mutant_bad)}
    if caught != SCOPE_CASES:
        print("%s: FAIL -- with the display scoping cut out, %s still passed"
              % (name, sorted(SCOPE_CASES - caught)))
        return 1
    abody = extract(text, "await_on_top")
    for old, new, case in EXIT_MUTANTS:
        cut = abody.replace(old, new)
        if cut == abody:
            print("%s: FAIL -- await_on_top has no %r to cut out" % (name, old))
            return 1
        mutant_bad, _ = check(text.replace(abody, cut))
        if not any(b.startswith(case + ":") for b in mutant_bad):
            print("%s: FAIL -- with %r cut out, %r still passed" % (name, old, case))
            return 1
    for old, new, case in END_MUTANTS:
        cut = body.replace(old, new)
        if cut == body:
            print("%s: FAIL -- on_top_now has no %r to cut out" % (name, old.strip()))
            return 1
        mutant_bad, _ = check(text.replace(body, cut))
        if not any(b.startswith(case + ":") for b in mutant_bad):
            print("%s: FAIL -- with %r cut out, %r still passed" % (name, old.strip(), case))
            return 1
    obody = extract(text, "on_display_now")
    for old, new, case in ON_DISPLAY_MUTANTS:
        cut = obody.replace(old, new)
        if cut == obody:
            print("%s: FAIL -- on_display_now has no %r to cut out" % (name, old.strip()))
            return 1
        if not any(b.startswith(case + ":") for b in check_on_display(text.replace(obody, cut))):
            print("%s: FAIL -- with %r cut out of on_display_now, %r still passed" % (name, old.strip(), case))
            return 1
    scope = '&& index(" " $0 " ", i) '
    if scope not in launch:
        print("%s: FAIL -- the candidate has no init= scoping to cut out" % name)
        return 1
    if not any(b.startswith("an earlier sandbox's record is not this one's:")
               for b in check_own_candidate(launch.replace(scope, "", 1))):
        print("%s: FAIL -- with the candidate's init= scoping cut out, an earlier sandbox's record passed" % name)
        return 1
    print("%s: OK (a parse that accepts any display's top activity, reads past its display's "
          "segment or reads a covered task is caught, and so is a wait that ignores a failed am start "
          "or a dead process, and an own-display check that looks past its display)" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
