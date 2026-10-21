#!/usr/bin/env python3
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))

AWK_TOPLEVEL_RE = re.compile(r'\$2\s*==\s*"Rhizo"')
AWK_VAR_RE = re.compile(r'-v\s+\w+="\$(\w+)"')
TITLE_RE = re.compile(r'Rhizo display \$(\w+)')
RHIZO_CTL_DISPLAY_RE = re.compile(r'rhizo_ctl\s+"\$\w+"\s+display\s+\S+\s+"\$(\w+)"')
HELPER_ARG1_RE = re.compile(r'\b(?:mapped_window_rect|display_selector)\s+"\$(\w+)"')
ASSERT_WINDOW_PAINTED_RE = re.compile(r'\bassert_window_painted\s+\S+\s+"\$(\w+)"')
LOGID_PARSE_RE = re.compile(
    r"^\s*(\w+)=.*grep\s+-oE?\s+'(\(\^\|\[\[:space:\]\]\))?display=\[0-9\][*+]'")
UNANCHORED_DISPLAY_GREP_RE = re.compile(r"grep\s+-oE?\s+'display=\[0-9\][*+]'")
def _brace_depth(line, quote=None):
    """return the brace depth change and open quote"""
    depth = 0
    escaped = False
    for i, ch in enumerate(line):
        if quote:
            if escaped:
                escaped = False
            elif ch == "\\" and quote == '"':
                escaped = True
            elif ch == quote:
                quote = None
            continue
        if ch == "#" and (i == 0 or line[i - 1].isspace()):
            break
        if ch in ("'", '"'):
            quote = ch
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
    return depth, quote


CDISPLAY_PARSE_RE = re.compile(r"^\s*(\w+)=.*grep\s+-o\s+'cdisplay=\[0-9\]\*'")
FALLBACK_RE = re.compile(r"^\s*(\w+)=\$\{(\w+):-\$(\w+)\}")
CDISP_NAME_RE = re.compile(r"(?i:cdisp)|RESUME_DISP|RELAUNCH_DISP")
FUNC_DEF_RE = re.compile(r"^\s*(\w+)\s*\(\)\s*\{")
CAPTURE_READ_RE = re.compile(r'read\s+-r\s+([\w ]+)\s*<<<"\$\((\w+)[^)]*\)"')
CAPTURE_ASSIGN_RE = re.compile(r"^\s*(\w+)=\$\((\w+)[^)]*\)\s*$")
CALL_FIRST_ARG_RE = re.compile(r'(\w+)\s+"\$(\w+)"')


def toplevel_vars(line):
    """return the shell variable names in a line"""
    out = []
    if AWK_TOPLEVEL_RE.search(line):
        out += AWK_VAR_RE.findall(line)
    m = TITLE_RE.search(line)
    if m:
        out.append(m.group(1))
    m = RHIZO_CTL_DISPLAY_RE.search(line)
    if m:
        out.append(m.group(1))
    m = HELPER_ARG1_RE.search(line)
    if m:
        out.append(m.group(1))
    m = ASSERT_WINDOW_PAINTED_RE.search(line)
    if m:
        out.append(m.group(1))
    return out


def function_regions(lines):
    """return the start and end of each function"""
    regions = {}
    for i, l in enumerate(lines):
        m = FUNC_DEF_RE.match(l)
        if not m:
            continue
        depth, quote = _brace_depth(l)
        j = i
        while (depth > 0 or quote) and j + 1 < len(lines):
            j += 1
            step, quote = _brace_depth(lines[j], quote)
            depth += step
        regions[m.group(1)] = (i, j + 1)
    return regions


def unanchored_findings(name, text):
    """return findings for unanchored display= greps"""
    out = []
    for i, l in enumerate(text.splitlines(), 1):
        if l.lstrip().startswith("#"):
            continue
        if UNANCHORED_DISPLAY_GREP_RE.search(l):
            out.append(
                "%s:%d: unanchored `grep -o 'display=[0-9]*'`"
                % (name, i))
    return out


def check_script(name, text):
    """return findings for toplevel and rhizo_ctl lines"""
    findings = unanchored_findings(name, text)
    lines = text.splitlines()
    regions = function_regions(lines)

    cdisplay_funcs = set()
    positional_match_funcs = set()
    for fname, (start, end) in regions.items():
        body = lines[start:end]
        if any(CDISPLAY_PARSE_RE.match(l) for l in body):
            cdisplay_funcs.add(fname)
        for l in body:
            if l.strip().startswith("#"):
                continue
            if any(v.isdigit() for v in toplevel_vars(l)):
                positional_match_funcs.add(fname)

    state = {}
    for lineno, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue

        m = LOGID_PARSE_RE.match(line)
        if m:
            state[m.group(1)] = "logid_only"
        m = CDISPLAY_PARSE_RE.match(line)
        if m:
            state[m.group(1)] = "cdisp"
        m = FALLBACK_RE.match(line)
        if m and state.get(m.group(2)) == "cdisp" or (m and state.get(m.group(3)) == "cdisp"):
            state[m.group(1)] = "cdisp"

        m = CAPTURE_READ_RE.search(line)
        if m:
            callee = m.group(2)
            capture_vars = m.group(1).split()
            if callee in cdisplay_funcs and capture_vars:
                last = capture_vars[-1]
                if not CDISP_NAME_RE.search(last):
                    findings.append(
                        "%s:%d captures %s()'s return (which parses cdisplay=) into "
                        "'%s', a name that does not mark it as the composer's id"
                        % (name, lineno, callee, last))
        m = CAPTURE_ASSIGN_RE.match(line)
        if m and m.group(2) in cdisplay_funcs:
            var = m.group(1)
            if not CDISP_NAME_RE.search(var):
                findings.append(
                    "%s:%d captures %s()'s return (which parses cdisplay=) into "
                    "'%s', a name that does not mark it as the composer's id"
                    % (name, lineno, m.group(2), var))

        m = CALL_FIRST_ARG_RE.search(line)
        if m and m.group(1) in positional_match_funcs:
            arg = m.group(2)
            if not CDISP_NAME_RE.search(arg):
                findings.append(
                    "%s:%d calls %s() with '%s', "
                    "a name that does not mark it as the composer's id" % (name, lineno, m.group(1), arg))

        for var in toplevel_vars(line):
            if state.get(var) == "logid_only":
                findings.append(
                    "%s:%d matches a Wayland toplevel or issues a rhizo_ctl display "
                    "command keyed on '%s', parsed off display= "
                    "and never reconciled with cdisplay=" % (name, lineno, var))

    return findings


def consumer_scripts():
    """return the rhizo-launch.log script paths and text"""
    names = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", "HEAD", "--", "tools", "bench"],
        cwd=REPO, capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    names = [n for n in names if n.endswith(".sh")]
    out = []
    for rel in sorted(names):
        if os.path.basename(rel) == "rhizo-launch.sh":
            continue
        full = os.path.join(REPO, rel)
        if not os.path.exists(full):
            continue
        with open(full) as f:
            text = f.read()
        if "rhizo-launch.log" in text:
            out.append((rel, text))
    return out


SELFTEST_GOOD = """#!/bin/bash
line=$(tail -1 /tmp/rhizo-launch.log)
disp=$(echo "$line" | grep -oE '(^|[[:space:]])display=[0-9]+' | cut -d= -f2)
cdisp=$(echo "$line" | grep -o 'cdisplay=[0-9]*' | cut -d= -f2)
cdisp=${cdisp:-$disp}
resumed=$(resumed_on "$INIT" "$disp")
read -r WX WY WW WH <<<"$(sway_windows | awk -v want="$cdisp" '$2=="Rhizo" && $3=="display" && $4==want {print $5,$6,$7,$8}')"  # toplevel-literal-ok: a fixture for THIS check's own rule (cdisplay= vs display=); the title it matches is incidental
rhizo_ctl "$INIT" display remove "$cdisp" >/dev/null 2>&1

launch_app() {  # launch_app <index> -> prints "<pkg> <act> <composer display id>"
  local idx="$1" line disp cdisp
  line=$(ssh_vm -t 10 "tail -1 /tmp/rhizo-launch.log")
  disp=$(echo "$line" | grep -oE '(^|[[:space:]])display=[0-9]+' | cut -d= -f2)
  cdisp=$(echo "$line" | grep -o 'cdisplay=[0-9]*' | cut -d= -f2)
  cdisp=${cdisp:-$disp}
  echo "app act $cdisp"
}
read -r PKG1 ACT1 CDISP1 <<<"$(launch_app 0)"
for d in "$CDISP1"; do
  gcmd "swaymsg '[title=\\"Rhizo display $d\\"] kill' >/dev/null" 5
done

cleanup_display() {  # cleanup_display <composer display id>
  rhizo_ctl "$INIT" display remove "$1" >/dev/null 2>&1
}
cleanup_display "$cdisp"
rect=$(mapped_window_rect "$cdisp")
"""

SELFTEST_DIRECT_BAD = SELFTEST_GOOD.replace(
    'awk -v want="$cdisp"', 'awk -v want="$disp"')

SELFTEST_CAPTURE_BAD = SELFTEST_GOOD.replace(
    'read -r PKG1 ACT1 CDISP1 <<<"$(launch_app 0)"',
    'read -r PKG1 ACT1 DISP1 <<<"$(launch_app 0)"',
).replace('for d in "$CDISP1"; do', 'for d in "$DISP1"; do')

SELFTEST_POSITIONAL_BAD = SELFTEST_GOOD.replace(
    'cleanup_display "$cdisp"', 'cleanup_display "$disp"')

SELFTEST_HELPER_BAD = SELFTEST_GOOD.replace(
    'mapped_window_rect "$cdisp"', 'mapped_window_rect "$disp"')

SELFTEST_UNANCHORED_BAD = SELFTEST_GOOD.replace(
    """grep -oE '(^|[[:space:]])display=[0-9]+'""",
    """grep -o 'display=[0-9]*'""", 1)


SELFTEST_REGIONS = """parse_stack() {
  awk '
    /layerFilter=\\{layerStack=/ { print }
  ' "$1"
}
note() {
  # don't let an apostrophe here open a quote
  echo ok
}
after() {
  echo last
}
"""


def selftest():
    """check the function regions and each planted-defect script"""
    regions = function_regions(SELFTEST_REGIONS.splitlines())
    want = {"parse_stack": (0, 5), "note": (5, 9), "after": (9, 12)}
    if regions != want:
        print("SELFTEST FAILED: function regions across a multi-line quote and a commented apostrophe "
              "were %s, wanted %s" % (regions, want), file=sys.stderr)
        return 1
    good = check_script("fixture", SELFTEST_GOOD)
    if good:
        print("SELFTEST FAILED: the well-formed fixture was flagged: %s" % good,
              file=sys.stderr)
        return 1

    cases = [
        ("direct toplevel match keyed on display=", SELFTEST_DIRECT_BAD,
         "'disp'"),
        ("cross-function capture into a bare name", SELFTEST_CAPTURE_BAD,
         "'DISP1'"),
        ("positional-arg helper called with a bare name", SELFTEST_POSITIONAL_BAD,
         "'disp'"),
        ("reconciled but with an unanchored display= parse", SELFTEST_UNANCHORED_BAD,
         "unanchored"),
        ("a sway-lib.sh display helper called with a bare name", SELFTEST_HELPER_BAD,
         "'disp'"),
    ]
    for label, fixture, want_needle in cases:
        found = check_script("fixture", fixture)
        if not any(want_needle in f for f in found):
            print("SELFTEST FAILED: '%s' fixture did not produce a finding naming %s "
                  "(found: %s)"
                  % (label, want_needle, found), file=sys.stderr)
            return 1

    print("selftest ok: catches an unanchored display= parse, a direct "
          "display=-keyed match, a cross-function "
          "capture into a bare name, a positional-arg helper called with a bare "
          "name, a sway-lib.sh display helper called with a bare name, and "
          "passes a well-formed file")
    return 0


def main():
    """run the check or its selftest"""
    if "--selftest" in sys.argv:
        return selftest()
    bad = []
    for name, text in consumer_scripts():
        bad += check_script(name, text)
    if bad:
        for b in bad:
            print(b, file=sys.stderr)
        return 1
    print("every Wayland toplevel match and rhizo_ctl display command keys on cdisplay=")
    return 0


if __name__ == "__main__":
    sys.exit(main())
