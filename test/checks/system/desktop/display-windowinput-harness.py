#!/usr/bin/env python3
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.normpath(os.path.join(HERE, "..", "..", "..", "..", "src", "androidd", "guest", "bin", "layerstack-guard.sh"))
DISPLAY = "display.sh"
WINDOW = "window-input.sh"

SF_FIXTURE = """\
Display 4619827259835644672 (HWC display 0): port=0 pnpId=RHZ displayName="rhizo"
Display 4619827259835644673 (HWC display 2): port=1 pnpId=RHZ displayName="rhizo"

Display 4619827259835644672 (physical, "rhizo")
   Composition Display State:
   isEnabled=true isSecure=true usesDeviceComposition=true
   usesClientComposition=false flipClientTarget=false reusedClientComposition=false
   layerFilter={layerStack=0 toInternalDisplay=true skipScreenshot=false }
Display 4619827259835644673 (physical, "rhizo")
   Composition Display State:
   isEnabled=true isSecure=true usesDeviceComposition=false
   usesClientComposition=false flipClientTarget=false reusedClientComposition=false
   layerFilter={layerStack=4294967295 toInternalDisplay=false skipScreenshot=false }
"""

DMS_FIXTURE = """\
Display Devices: size=2
  DisplayDeviceInfo{"Built-in Screen": uniqueId="local:4619827259835644672", 1920 x 1080}
    mAdapter=LocalDisplayAdapter
    mUniqueId=local:4619827259835644672
    mDisplayToken=android.os.BinderProxy@8a1c2f3
    mCurrentLayerStack=0
    mCurrentFlags=1
  DisplayDeviceInfo{"HDMI Screen": uniqueId="local:4619827259835644673", 960 x 1080}
    mAdapter=LocalDisplayAdapter
    mUniqueId=local:4619827259835644673
    mDisplayToken=android.os.BinderProxy@5d02e19
    mCurrentLayerStack=2
    mCurrentFlags=1
"""

PARSER_CASES = [
    ("sf_layerstack_of", "2", SF_FIXTURE, "4619827259835644673 4294967295"),
    ("sf_layerstack_of", "0", SF_FIXTURE, "4619827259835644672 0"),
    ("sf_layerstack_of", "9", SF_FIXTURE, ""),
    ("dms_layerstack_of", "4619827259835644673", DMS_FIXTURE, "2"),
    ("dms_layerstack_of", "4619827259835644672", DMS_FIXTURE, "0"),
]
PARSER_OF_GUARD = {"sf_layerstack_of": "sf_layerstack", "dms_layerstack_of": "dms_layerstack"}

EXITS_RE = re.compile(r"(^|[\s;&|({])(fail|bail|exit)\b")
POWERS_RE = re.compile(r"\bcmd display power-")


def system_test_file(tools, name):
    """return the file of the named system test"""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "system", "run"))
    import system_tests
    return system_tests.test_path(name, tools) or os.path.join(tools, name)


def is_comment(line):
    """return whether a line is a comment"""
    return line.lstrip().startswith("#")


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


def code(fn):
    """return the non-comment lines of a function"""
    return [l for l in fn.split("\n") if not is_comment(l)]


def awk_program(fn):
    """return the lines of the awk program in a function, or None"""
    start, end = fn.find("'"), fn.rfind("'")
    if start < 0 or end <= start:
        return None
    return [l.strip() for l in fn[start + 1:end].split("\n") if l.strip()]


def first_index(lines, pattern, start=0):
    """return the index of the first matching non-comment line"""
    rx = re.compile(pattern)
    for i in range(start, len(lines)):
        if not is_comment(lines[i]) and rx.search(lines[i]):
            return i
    return None


def check_stay_awake(text):
    """return the problems when the window test does not keep the device awake"""
    name = WINDOW
    problems = []
    lines = text.split("\n")
    init_i = first_index(lines, r'^INIT=\$\(guest_init_pid ')
    step1_i = first_index(lines, r'^step "1\.')
    if init_i is None or step1_i is None:
        return ["%s: cannot find the INIT lookup and step 1 to place the stay-awake between" % name]
    pos = init_i
    for pat, what in ((r'android_sh "\$INIT" "cmd battery set ac 1"', "cmd battery set ac 1"),
                      (r'android_sh "\$INIT" "settings put global stay_on_while_plugged_in 7"',
                       "settings put global stay_on_while_plugged_in 7"),
                      (r'android_sh "\$INIT" "input keyevent 224"', "input keyevent 224")):
        found = first_index(lines[:step1_i], pat, pos + 1)
        if found is None:
            problems.append("%s never runs `%s` between its INIT lookup (line %d) and step 1 (line %d), "
                            "after the stay-awake lines before it" % (name, what, init_i + 1, step1_i + 1))
            break
        pos = found
    for i, l in enumerate(lines):
        if not is_comment(l) and re.search(r"stay_on_while_plugged_in 0|battery (unplug|reset)|"
                                           r"svc power stayon false|input keyevent 223", l):
            problems.append("%s:%d releases the stay-awake the run depends on" % (name, i + 1))
    return problems


def check_product_launch(text):
    """return the problems when the display test does not launch through the product"""
    name = DISPLAY
    problems = []
    fn = extract_function(text, "launch_on_display")
    if fn is None:
        problems.append("%s defines no launch_on_display()" % name)
    elif not any("rhizo-launch.sh" in l for l in code(fn)):
        problems.append("%s: launch_on_display() does not run rhizo-launch.sh" % name)
    forbidden = [
        (r'rhizo_ctl\s+"\$INIT"\s+display\s+add\b', "adds a display by hand"),
        (r"\benable-display\b", "enables a display by hand"),
        (r"\bam start\b.*--display", "am-starts onto a display by hand"),
        (r'rhizo_ctl\s+"\$INIT"\s+display\s+remove\b', "removes a display by hand"),
        (r"rhizo-layerstack-guard\.sh", "starts the layer-stack guard itself"),
        (POWERS_RE.pattern, "powers a display by hand"),
    ]
    for i, l in enumerate(text.split("\n")):
        if is_comment(l):
            continue
        for pat, what in forbidden:
            if re.search(pat, l):
                problems.append("%s:%d %s" % (name, i + 1, what))
    for app in ("APP1", "APP2"):
        if first_index(text.split("\n"), r'launch_on_display "\$%s"' % app) is None:
            problems.append("%s never launches $%s through launch_on_display()" % (name, app))
    return problems


def run_bash(script, stdin=""):
    """run a bash script and return its exit code and output"""
    r = subprocess.run(["bash", "-c", script], input=stdin, capture_output=True, text=True, timeout=30)
    return r.returncode, r.stdout.strip()


def check_capture_only(name, fn_name, fn):
    """return the problems when an evidence function fails, exits or powers anything"""
    problems = []
    for l in code(fn):
        if EXITS_RE.search(l.split("#")[0]):
            problems.append("%s: %s() fails or exits (`%s`)" % (name, fn_name, l.strip()))
        if POWERS_RE.search(l):
            problems.append("%s: %s() powers a display (`%s`)" % (name, fn_name, l.strip()))
    return problems


def check_cause_a(text):
    """return the problems in the cause A evidence function of the window test"""
    name = WINDOW
    problems = []
    lines = text.split("\n")
    fn = extract_function(text, "cause_a_evidence")
    if fn is None:
        return ["%s defines no cause_a_evidence()" % name]
    body = "\n".join(code(fn))
    for need in ("dumpsys activity activities", "dumpsys window displays", "mTopFocusedDisplayId",
                 "dumpsys SurfaceFlinger --display-id", "layerFilter", "rhizo_ctl_display_list",
                 "rhizo-layerstack-guard.log"):
        if need not in body:
            problems.append("%s: cause_a_evidence() captures no `%s`" % (name, need))
    problems += check_capture_only(name, "cause_a_evidence", fn)
    painted = first_index(lines, r'^assert_window_painted winapp2 ')
    step3 = first_index(lines, r'^step "3\. ')
    if painted is None or step3 is None:
        problems.append("%s: cannot find step 2's last assert_window_painted and step 3" % name)
    elif first_index(lines[:step3], r'^cause_a_evidence \S+', painted + 1) is None:
        problems.append("%s has no cause_a_evidence call between step 2's last "
                        "assert_window_painted (line %d) and step 3 (line %d)" % (name, painted + 1, step3 + 1))
    s3b = first_index(lines, r'^step "3b\.')
    s4 = first_index(lines, r'^step "4\.')
    if s3b is None or s4 is None:
        problems.append("%s: cannot find steps 3b and 4" % name)
        return problems
    calls = [i for i in range(s3b, s4) if not is_comment(lines[i])
             and re.search(r'^\s*cause_a_evidence \S+ full\s*$', lines[i])]
    if not calls:
        problems.append("%s: step 3b never calls `cause_a_evidence <tag> full` when it fails" % name)
    for c in calls:
        above = [l for l in lines[max(s3b, c - 3):c] if not is_comment(l)]
        if not any(re.match(r"\s*fail\b", l) for l in above):
            problems.append("%s:%d calls cause_a_evidence outside a failure branch (no fail within "
                            "3 lines above it)" % (name, c + 1))
    return problems


def check_h(text, guard_text):
    """return the problems in the layer stack evidence of the display test"""
    name = DISPLAY
    problems = []
    lines = text.split("\n")
    fns = {}
    for fn_name, needs in (("layerstack_evidence", ("dumpsys SurfaceFlinger", "dumpsys display",
                                                    "sf_layerstack_of", "dms_layerstack_of",
                                                    "composer_display_stats", "guard_verdict_lines")),
                           ("composer_display_stats", ("display stats",)),
                           ("guard_verdict_lines", ("rhizo-layerstack-guard.log",))):
        fn = extract_function(text, fn_name)
        if fn is None:
            problems.append("%s defines no %s()" % (name, fn_name))
            continue
        fns[fn_name] = fn
        body = "\n".join(code(fn))
        for need in needs:
            if need not in body:
                problems.append("%s: %s() captures no `%s`" % (name, fn_name, need))
        problems += check_capture_only(name, fn_name, fn)
    launch = extract_function(text, "launch_on_display")
    if launch is not None:
        ll = launch.split("\n")
        before = first_index(ll, r"\blayerstack_evidence\b.*before")
        mapped = first_index(ll, r"\bdesktop_mapped_window_rect\b")
        after = first_index(ll, r"\blayerstack_evidence\b.*after")
        if None in (before, mapped, after) or not before < mapped < after:
            problems.append("%s: launch_on_display() must capture layerstack_evidence ... before, then "
                            "wait on desktop_mapped_window_rect, then capture ... after (found lines "
                            "%s, %s, %s of the function)" % (name, before, mapped, after))
    if first_index(lines, r'launch_on_display "\$APP1" "[^"]*" \S+') is None:
        problems.append("%s: app A's launch_on_display call passes no evidence tag" % name)
    for parser, guard_fn_name in PARSER_OF_GUARD.items():
        fn = extract_function(text, parser)
        if fn is None:
            problems.append("%s defines no %s()" % (name, parser))
            continue
        gfn = extract_function(guard_text, guard_fn_name)
        if gfn is None or awk_program(gfn) is None:
            problems.append("rhizo-layerstack-guard.sh no longer defines %s() with an awk program" % guard_fn_name)
        elif awk_program(fn) != awk_program(gfn):
            problems.append("%s: %s()'s awk program differs from rhizo-layerstack-guard.sh's %s()"
                            % (name, parser, guard_fn_name))
        for p, arg, stdin, want in PARSER_CASES:
            if p != parser:
                continue
            rc, out = run_bash(fn + "\n%s %s" % (parser, arg), stdin)
            if out != want:
                problems.append("%s: %s %s on the Class X fixture printed %r, expected %r"
                                % (name, parser, arg, out, want))
    return problems


def check(texts, guard_text):
    """return the problems from every harness check"""
    problems = []
    if WINDOW not in texts:
        problems.append("%s: not found" % WINDOW)
    else:
        problems += check_stay_awake(texts[WINDOW]) + check_cause_a(texts[WINDOW])
    if DISPLAY not in texts:
        problems.append("%s: not found" % DISPLAY)
    else:
        problems += check_product_launch(texts[DISPLAY]) + check_h(texts[DISPLAY], guard_text)
    return problems


GOOD_WINDOW = r'''#!/bin/bash
cause_a_evidence() {
  local tag="$1" full="${2:-}"
  android_sh "$INIT" "dumpsys activity activities" > "$EV/causeA-$tag-activities.txt" 2>&1
  android_sh "$INIT" "dumpsys window displays" > "$EV/causeA-$tag-window-displays.txt" 2>&1
  android_sh "$INIT" "dumpsys window" 2>/dev/null | grep -aE 'mTopFocusedDisplayId=' > "$EV/f.txt"
  [[ "$full" == full ]] || return 0
  android_sh "$INIT" "dumpsys SurfaceFlinger --display-id" > "$EV/id.txt" 2>&1
  android_sh "$INIT" "dumpsys SurfaceFlinger" 2>/dev/null | grep -aE 'layerFilter=' > "$EV/lf.txt"
  rhizo_ctl_display_list "$INIT" > "$EV/dl.txt" 2>&1
  android_sh "$INIT" "cat /data/local/tmp/rhizo-layerstack-guard.log" > "$EV/g.txt" 2>&1
}
INIT=$(guest_init_pid 10)
android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
step "1. install the two test apps"
step "2. launch both apps, each on its own display"
assert_window_painted winapp2 "$D2" || { window_map_evidence winapp2 "$D2"; exit 1; }
cause_a_evidence after-step2
step "3. identity"
step "3b. a touch"
if [[ -z "$tline" ]]; then
  fail "a touch reached no MotionEvent"
  cause_a_evidence step3b-no-touch full
fi
step "4. fullscreen"
'''

GOOD_DISPLAY_TEMPLATE = r'''#!/bin/bash
guard_verdict_lines() {
  android_sh "$INIT" "cat /data/local/tmp/rhizo-layerstack-guard.log" 2>/dev/null | grep -a ' verdict='
}
composer_display_stats() {
  rhizo_ctl "$INIT" display stats "$1" >/dev/null 2>&1
  rhizo_ctl_out "$INIT" | grep "^display stats id=$1 " | tail -1
}
SF_PARSER
DMS_PARSER
layerstack_evidence() {
  local phase="$1" cdisp="$2"
  dumps=$(android_sh "$INIT" "dumpsys SurfaceFlinger; echo RHIZO_SPLIT_DMS; dumpsys display" 2>/dev/null)
  read -r physid sf_stack <<<"$(sf_layerstack_of "$cdisp" <<<"$dumps")"
  dms_stack=$(dms_layerstack_of "$physid" <<<"$dumps")
  stats=$(composer_display_stats "$cdisp")
  guard=$(guard_verdict_lines | tail -3)
  log "    [$phase] $sf_stack $dms_stack $stats $guard"
}
launch_on_display() {
  local pkg_act="$1" label="$2" tag="${3:-}"
  ssh_vm -t 150 "/usr/lib/rhizo/tools/rhizo-launch.sh $pkg $act > /tmp/o 2>&1" >/dev/null 2>&1
  [[ -n "$tag" ]] && layerstack_evidence "$tag-before" "$cdisp" "$lid"
  desktop_mapped_window_rect "$cdisp" 20 >/dev/null && mapped=1
  [[ -n "$tag" ]] && layerstack_evidence "$tag-after" "$cdisp" "$lid"
  echo "$cdisp $lid"
}
launched=$(launch_on_display "$APP1" "app A" first-launch) || fail "app A's window never mapped"
launched=$(launch_on_display "$APP2" "app B") || fail "app B's window never mapped"
'''

PRE_FIX_DISPLAY = r'''#!/bin/bash
launch_on_display() {
  local w="$1" h="$2" pkg_act="$3" label="$4"
  rhizo_ctl "$INIT" display add "$w" "$h" >/dev/null
  android_sh "$INIT" "cmd display enable-display $lid" >/dev/null
  android_sh "$INIT" "am start --display $lid -n $pkg_act" >/dev/null
  display_window_mapped "$id" 20 && { echo "$id $lid"; return 0; }
  rhizo_ctl "$INIT" display remove "$id" >/dev/null
}
launched=$(launch_on_display 960 1080 "$APP1" "app A") || fail "app A's window never mapped"
launched=$(launch_on_display 960 1080 "$APP2" "app B") || fail "app B's window never mapped"
'''


def good_display(guard_text):
    """return the good display test with the guard parsers filled in"""
    sf = extract_function(guard_text, "sf_layerstack").replace("sf_layerstack() {", "sf_layerstack_of() {", 1)
    dms = extract_function(guard_text, "dms_layerstack").replace("dms_layerstack() {", "dms_layerstack_of() {", 1)
    return GOOD_DISPLAY_TEMPLATE.replace("SF_PARSER", sf).replace("DMS_PARSER", dms)


def selftest():
    """check the fixed shape and each planted-defect copy"""
    with open(GUARD) as f:
        guard_text = f.read()
    good = {WINDOW: GOOD_WINDOW, DISPLAY: good_display(guard_text)}
    got = check(good, guard_text)
    if got:
        print("selftest FAIL: the fixed shape was refused:\n  " + "\n  ".join(got))
        return 1
    gd = good[DISPLAY]
    pre_fix_window = re.sub(r'android_sh "\$INIT" "(cmd battery set ac 1|settings put global '
                            r'stay_on_while_plugged_in 7|input keyevent 224)" >/dev/null\n', "", GOOD_WINDOW)
    pre_fix_window = pre_fix_window.replace("cause_a_evidence after-step2\n", "").replace(
        "  cause_a_evidence step3b-no-touch full\n", "")
    pre_fix_window = pre_fix_window[:pre_fix_window.index("cause_a_evidence() {")] + \
        pre_fix_window[pre_fix_window.index("INIT=$("):]
    mutations = [
        ("test-window-input as it was: no stay-awake, no captures", {WINDOW: pre_fix_window, DISPLAY: gd},
         ["never runs `cmd battery set ac 1`", "defines no cause_a_evidence()"]),
        ("test-display as it was: hand-built add, no captures",
         {WINDOW: GOOD_WINDOW, DISPLAY: PRE_FIX_DISPLAY},
         ["does not run rhizo-launch.sh", "adds a display by hand", "enables a display by hand",
          "am-starts onto a display by hand", "removes a display by hand", "defines no layerstack_evidence()",
          "passes no evidence tag", "defines no sf_layerstack_of()"]),
        ("stay-awake placed after step 1",
         {WINDOW: GOOD_WINDOW.replace('android_sh "$INIT" "input keyevent 224" >/dev/null\n', "").replace(
             'step "1. install the two test apps"\n',
             'step "1. install the two test apps"\nandroid_sh "$INIT" "input keyevent 224" >/dev/null\n'),
          DISPLAY: gd},
         ["never runs `input keyevent 224`"]),
        ("stay-awake released later",
         {WINDOW: GOOD_WINDOW + 'android_sh "$INIT" "settings put global stay_on_while_plugged_in 0"\n',
          DISPLAY: gd},
         ["releases the stay-awake"]),
        ("the system test starts the guard itself",
         {WINDOW: GOOD_WINDOW, DISPLAY: gd.replace(
             '  [[ -n "$tag" ]] && layerstack_evidence "$tag-before"',
             '  android_sh "$INIT" "sh /system_ext/bin/rhizo-layerstack-guard.sh $lid $cdisp system test &"\n'
             '  [[ -n "$tag" ]] && layerstack_evidence "$tag-before"')},
         ["starts the layer-stack guard itself"]),
        ("cause_a_evidence without SurfaceFlinger",
         {WINDOW: GOOD_WINDOW.replace('"dumpsys SurfaceFlinger --display-id"', '"dumpsys display"'), DISPLAY: gd},
         ["captures no `dumpsys SurfaceFlinger --display-id`"]),
        ("cause_a_evidence fails the run",
         {WINDOW: GOOD_WINDOW.replace('  [[ "$full" == full ]] || return 0\n',
                                      '  [[ "$full" == full ]] || return 0\n  fail "no focus"\n'),
          DISPLAY: gd},
         ["cause_a_evidence() fails or exits"]),
        ("no capture after step 2",
         {WINDOW: GOOD_WINDOW.replace("cause_a_evidence after-step2\n", ""), DISPLAY: gd},
         ["no cause_a_evidence call between"]),
        ("3b capture outside a failure branch",
         {WINDOW: GOOD_WINDOW.replace('  fail "a touch reached no MotionEvent"\n', '  log "x"\n'),
          DISPLAY: gd},
         ["outside a failure branch"]),
        ("layerstack_evidence repairs what it measures",
         {WINDOW: GOOD_WINDOW, DISPLAY: gd.replace('  stats=$(composer_display_stats "$cdisp")\n',
                                                  '  stats=$(composer_display_stats "$cdisp")\n'
                                                  '  android_sh "$INIT" "cmd display power-reset 2"\n')},
         ["powers a display", "layerstack_evidence() powers a display"]),
        ("after-capture taken before the map wait",
         {WINDOW: GOOD_WINDOW, DISPLAY: gd.replace(
             '  desktop_mapped_window_rect "$cdisp" 20 >/dev/null && mapped=1\n  [[ -n "$tag" ]] && layerstack_evidence "$tag-after" "$cdisp" "$lid"\n',
             '  [[ -n "$tag" ]] && layerstack_evidence "$tag-after" "$cdisp" "$lid"\n  desktop_mapped_window_rect "$cdisp" 20 >/dev/null && mapped=1\n')},
         ["must capture layerstack_evidence ... before"]),
        ("app A launched with no evidence tag",
         {WINDOW: GOOD_WINDOW, DISPLAY: gd.replace('"app A" first-launch)', '"app A")')},
         ["passes no evidence tag"]),
        ("SurfaceFlinger parser drifted from the guard's",
         {WINDOW: GOOD_WINDOW, DISPLAY: gd.replace("grab = 6; in_block = 1", "grab = 3; in_block = 1", 1)},
         ["sf_layerstack_of()'s awk program differs"]),
        ("DisplayManager parser reads the wrong field",
         {WINDOW: GOOD_WINDOW, DISPLAY: gd.replace("mCurrentLayerStack=-?[0-9]+", "mCurrentFlags=-?[0-9]+", 1)},
         ["dms_layerstack_of()'s awk program differs", "dms_layerstack_of 4619827259835644673 on the Class X fixture"]),
    ]
    bad = 0
    for label, texts, expects in mutations:
        got = check(texts, guard_text)
        for e in expects:
            if not any(e in p for p in got):
                print("selftest FAIL: %s -- expected a problem containing %r, got:\n  %s"
                      % (label, e, "\n  ".join(got) or "(none)"))
                bad = 1
    if bad:
        return 1
    print("selftest ok: the fixed shapes pass; %d broken shapes are each refused by name" % len(mutations))
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    tools = os.path.join(HERE, "..", "..", "..", "system")
    if "--tools" in sys.argv:
        tools = sys.argv[sys.argv.index("--tools") + 1]
    texts = {}
    for g in (DISPLAY, WINDOW):
        p = system_test_file(tools, g)
        if os.path.exists(p):
            with open(p) as f:
                texts[g] = f.read()
    with open(GUARD) as f:
        guard_text = f.read()
    problems = check(texts, guard_text)
    if problems:
        for p in problems:
            print("FAIL: " + p)
        return 1
    print("ok: test-window-input stays awake and captures cause A; test-display launches through "
          "rhizo-launch.sh and captures hypothesis H with the guard's own parsers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
