#!/usr/bin/env python3

import os
import re
import shlex
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
STEP_RE = re.compile(r'^\s*step "(\d+)\.')
TUNNEL_RE = re.compile(r"^\.\./\.\./vm/boot/adb-tunnel\.sh up\b")
ANDROID_SH_RE = re.compile(r'^android_sh "\$INIT" ')
STAY_AWAKE = ("cmd battery set ac 1", "settings put global stay_on_while_plugged_in 7", "input keyevent 224")
FOCUS_DUMPS = ("dumpsys window", "dumpsys window displays", "dumpsys activity activities")
CLIP_LEGS = ("4", "10")
ICON_LEG = "6"
DESK_USER_LIB = os.path.join(TOOLS, "..", "..", "..", "system", "lib", "desk-user-lib.sh")
ROOT_ICON_PULL_RE = re.compile(r'(?<![\w-])pull\s+"?\$\{?icon_path\b')
USER_ICON_PULL_RE = re.compile(r'(?<![\w-])desk_user_pull\s+"\$icon_path"\s')
EV = "/ev"

DENIED = ("09-12 13:27:26.792  1234  1300 E ClipboardService: Denying clipboard access to com.rhizo.deskapp, "
          "application is not in focus nor is it a system service for user 0")
EMPTY = "09-12 13:27:26.792  4321  4321 I RhizoDeskApp: RHIZO_CLIP_EMPTY"
READ_TEXT = "RHIZO_CLIP_READ mime=text/plain b64=cmhpem8="
READ_PNG = "RHIZO_CLIP_READ mime=image/png b64=iVBORw0K"
PAT_TEXT = "RHIZO_CLIP_READ mime=[^ ]* b64=[A-Za-z0-9+/=]*"
PAT_PNG = "RHIZO_CLIP_READ mime=image/png b64=[A-Za-z0-9+/=]*"


def app_line(token):
    """return a logcat line from the desktop app with a token"""
    return "09-12 13:27:27.001  4321  4321 I RhizoDeskApp: " + token


def function_source(text, name):
    """return the text of a shell function, or None"""
    m = re.search(r"^%s\(\) \{.*?^\}$" % re.escape(name), text, re.S | re.M)
    return m.group(0) if m else None


def is_code(line):
    """return whether a line is code rather than blank or a comment"""
    s = line.strip()
    return bool(s) and not s.startswith("#")


def leg_spans(lines):
    """return the line range of each leg"""
    starts = [(i, m.group(1)) for i, l in enumerate(lines) if (m := STEP_RE.match(l))]
    spans = {}
    for n, (i, leg) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
        spans.setdefault(leg, (i, end))
    return spans


def run_bash(script, env_extra, cwd=None):
    """run a bash script with extra environment"""
    env = dict(os.environ)
    env.update(env_extra)
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60, env=env, cwd=cwd)
    return r.returncode, r.stdout, r.stderr


def read_file(path):
    """return the text of a file, or None when it is missing"""
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read()


AWAKE_STUBS = """
set -u
INIT=4242
log() { :; }
fail() { printf 'FAIL %s\\n' "$*" >> "$CALLS"; }
android_sh() { shift; printf 'SH %s\\n' "$*" >> "$CALLS"; }
"""


def stay_awake_problems(lines, spans):
    """return the problems with the stay-awake android_sh lines of leg 2"""
    if "2" not in spans:
        return ['no leg 2 (step "2. ...") in the system test']
    start, end = spans["2"]
    tunnel = next((i for i in range(start + 1, end) if TUNNEL_RE.match(lines[i])), None)
    if tunnel is None:
        return [f"leg 2 (line {start + 1}) runs no top-level `../../vm/boot/adb-tunnel.sh up`"]
    block = [lines[tunnel]]
    for line in lines[tunnel + 1:end]:
        if not is_code(line):
            continue
        if not ANDROID_SH_RE.match(line):
            break
        block.append(line)
    with tempfile.TemporaryDirectory() as d:
        calls = os.path.join(d, "calls")
        os.makedirs(os.path.join(d, "vm", "boot"))
        os.makedirs(os.path.join(d, "system", "desktop"))
        stub = os.path.join(d, "vm", "boot", "adb-tunnel.sh")
        with open(stub, "w") as f:
            f.write("#!/bin/sh\nprintf 'TUNNEL %s\\n' \"$*\" >> \"$CALLS\"\n")
        os.chmod(stub, 0o755)
        rc, _out, err = run_bash(AWAKE_STUBS + "\n".join(block) + "\n", {"CALLS": calls, "EV": d}, cwd=os.path.join(d, "system", "desktop"))
        seen = [l for l in (read_file(calls) or "").splitlines() if not l.startswith("FAIL ")]
    want = ["TUNNEL up"] + ["SH " + c for c in STAY_AWAKE]
    if rc != 0 or seen[:len(want)] != want:
        return [f"leg 2 (line {tunnel + 1}): `../../vm/boot/adb-tunnel.sh up` is followed by {seen[1:]} (rc={rc}), not "
                f"display.sh's stay-awake {list(STAY_AWAKE)}"
                + (f" ({err.strip()[:120]})" if rc else "")]
    return []


CLIP_STUBS = """
set -u
INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=com.rhizo.deskapp.MainActivity
log() { :; }
sleep() { :; }
date() { local t; t=$(( $(cat "$CLOCK") + 1 )); echo "$t" > "$CLOCK"; echo "$t"; }
logcat_since_marker() { printf 'SH logcat_since_marker\\n' >> "$CALLS"; echo '09-26 03:00:00.000'; }
android_sh() {
  shift
  printf 'SH %s\\n' "$*" >> "$CALLS"
  case "$*" in
    "am start "*) : > "$STARTED" ;;
    "logcat -d -b all") if [[ -e "$STARTED" ]]; then cat "$AFTER"; else cat "$BEFORE"; fi ;;
    "logcat -d -b all -t '09-26 03:00:00.000'")
      [[ -e "$STARTED" ]] && tail -n +$(( $(wc -l < "$BEFORE") + 1 )) "$AFTER" ;;
    dumpsys*) printf 'output of %s\\n' "$*" ;;
  esac
}
"""

CLIP_CASES = (
    ("an empty read", "", DENIED + "\n" + EMPTY + "\n", PAT_TEXT, 2, "", True),
    ("a read", "", app_line(READ_TEXT) + "\n", PAT_TEXT, 0, READ_TEXT, False),
    ("an image read after an earlier leg's empty read", EMPTY + "\n", EMPTY + "\n" + app_line(READ_PNG) + "\n",
     PAT_PNG, 0, READ_PNG, False),
    ("only an earlier leg's empty read", EMPTY + "\n", EMPTY + "\n", PAT_PNG, 1, "", False),
    ("no answer", "", "", PAT_TEXT, 1, "", False),
)


def clip_read_problems(text):
    """return the problems when clip_read gives a wrong answer in any logcat case"""
    src = function_source(text, "clip_read")
    if not src:
        return ["no clip_read() in the system test"]
    helper = function_source(text, "clip_focus_snapshot") or ""
    problems = []
    for case, before, after, pat, want_rc, want_out, want_snap in CLIP_CASES:
        with tempfile.TemporaryDirectory() as d:
            p = {k: os.path.join(d, k) for k in ("calls", "clock", "started", "before", "after", "snap", "out")}
            for k, content in (("clock", "1000\n"), ("before", before), ("after", after)):
                with open(p[k], "w") as f:
                    f.write(content)
            script = (CLIP_STUBS + helper + "\n" + src + "\n"
                      f'out=$(clip_read {shlex.quote(pat)} 3 "$SNAP"); rc=$?\n'
                      "printf '%s' \"$out\" > \"$OUT\"\n"
                      "printf 'rc=%s' \"$rc\"\n")
            env = {"CALLS": p["calls"], "CLOCK": p["clock"], "STARTED": p["started"], "BEFORE": p["before"],
                   "AFTER": p["after"], "SNAP": p["snap"], "OUT": p["out"]}
            rc, out, err = run_bash(script, env)
            calls = [l[3:] for l in (read_file(p["calls"]) or "").splitlines() if l.startswith("SH ")]
            got_out = read_file(p["out"]) or ""
            snap = read_file(p["snap"])
        m = re.fullmatch(r"rc=(\d+)", out)
        if rc != 0 or not m:
            problems.append(f"clip_read did not run for {case}: rc={rc} {err.strip()[:200]}")
            continue
        if int(m.group(1)) != want_rc:
            problems.append(f"clip_read returned {m.group(1)} for {case}, wanted {want_rc}")
        if got_out != want_out:
            problems.append(f"clip_read printed {got_out!r} for {case}, wanted {want_out!r}")
        starts = [c for c in calls if c.startswith("am start ")]
        if len(starts) != 1 or "--es cmd clip_read" not in starts[0]:
            problems.append(f"clip_read issued {len(starts)} clip_read am start(s) for {case}, wanted 1")
        else:
            start_at = calls.index(starts[0])
            reads = [c for c in calls[start_at + 1:] if c.startswith("logcat ")]
            if "logcat_since_marker" not in calls[:start_at]:
                problems.append(f"clip_read took no logcat marker before the am start for {case} "
                                f"(calls: {calls[:3]})")
            elif not reads or " -t " not in reads[0]:
                problems.append(f"clip_read polled logcat after the am start without its own -t window for {case} "
                                f"(reads: {reads[:2]})")
        if want_snap and snap is None:
            problems.append(f"an empty read left no focus snapshot ({case})")
        elif want_snap:
            for dump in FOCUS_DUMPS:
                if dump not in calls:
                    problems.append(f"the focus snapshot for {case} never asked for `{dump}`")
                elif f"output of {dump}\n" not in snap:
                    problems.append(f"the focus snapshot for {case} does not hold `{dump}`'s output")
        elif snap is not None:
            problems.append(f"clip_read wrote a focus snapshot for {case}, which was not an empty read")
    return problems


LEG_STUBS = """
set -u
FAILED=0 ROUNDS=3 SELFTEST=0 INIT=4242 APP_PKG=p APP_ACT=a EV=/ev
step() { :; }
log() { :; }
pass() { :; }
fail() { printf 'FAIL %s\\n' "$*" >> "$CALLS"; FAILED=$((FAILED + 1)); }
nonce() { echo 00112233; }
st() { printf '%s' "$1"; }
st_png() { :; }
png_distinct() { echo 99; }
make_png() { : > "$1"; }
clipcmd() { :; }
android_sh() { :; }
app_wait_token() { return 1; }
clip_read() { printf 'CLIP_READ\\t%s\\t%s\\t%s\\n' "$@" >> "$CALLS"; return "$STUB_RC"; }
logcat_since_marker() { echo '09-26 03:00:00.000'; }
clip_wait_applied() { printf 'CLIP_APPLIED\\t%s\\n' "$2" >> "$CALLS"; return "${APPLIED_RC:-0}"; }
"""


def clip_leg_problems(lines, spans):
    """return the problems in both clipboard legs against a stubbed clip_read"""
    problems = []
    for leg in CLIP_LEGS:
        if leg not in spans:
            problems.append(f'no leg {leg} (step "{leg}. ...") in the system test')
            continue
        start, end = spans[leg]
        where = f"leg {leg} (line {start + 1})"
        body = "\n".join(lines[start:end]) + "\necho LEG_DONE\n"
        with tempfile.TemporaryDirectory() as d:
            calls = os.path.join(d, "calls")
            _rc, out, err = run_bash(LEG_STUBS + body, {"CALLS": calls, "STUB_RC": "1", "APPLIED_RC": "1",
                                                     "WORKDIR": d})
            seen = (read_file(calls) or "").splitlines()
        applied = [l for l in seen if l.startswith("CLIP_APPLIED\t")]
        fails = [l[5:] for l in seen if l.startswith("FAIL ")]
        if "LEG_DONE" not in out:
            problems.append(f"{where} did not run to its end when the android app never applied the clip: {err.strip()[:200]}")
        elif not applied or "RHIZO_DESK_CLIP_APPLIED" not in applied[0]:
            problems.append(f"{where} never waits for the android app's RHIZO_DESK_CLIP_APPLIED before the app reads -- "
                            "a read asked for before the host clip crossed reads an empty clipboard")
        elif any(l.startswith("CLIP_READ\t") for l in seen) or len(fails) != 1 or "RHIZO_CLIP_EMPTY" in fails[0]:
            problems.append(f"{where}: a clip the android app never applied recorded {fails} and "
                            f"{sum(l.startswith('CLIP_READ') for l in seen)} read(s), wanted one failure and no read")
        for stub_rc in (2, 1):
            with tempfile.TemporaryDirectory() as d:
                calls = os.path.join(d, "calls")
                _rc, out, err = run_bash(LEG_STUBS + body, {"CALLS": calls, "STUB_RC": str(stub_rc), "WORKDIR": d})
                seen = (read_file(calls) or "").splitlines()
            if "LEG_DONE" not in out:
                problems.append(f"{where} did not run to its end with clip_read returning {stub_rc}: {err.strip()[:200]}")
                continue
            reads = [l.split("\t") for l in seen if l.startswith("CLIP_READ\t")]
            fails = [l[5:] for l in seen if l.startswith("FAIL ")]
            if len(reads) != 1 or len(reads[0]) != 4:
                problems.append(f"{where}: with clip_read returning {stub_rc} the leg called clip_read {len(reads)} "
                                "time(s), wanted 1")
                continue
            _tag, pat, _secs, snap = reads[0]
            if stub_rc == 2:
                if "RHIZO_CLIP_READ" not in pat:
                    problems.append(f"{where} asks clip_read for {pat!r}, not a RHIZO_CLIP_READ token")
                if not snap.startswith(EV + "/"):
                    problems.append(f"{where} banks the focus snapshot at {snap!r}, outside $EV")
                if len(fails) != 1 or "RHIZO_CLIP_EMPTY" not in fails[0] or snap not in fails[0]:
                    problems.append(f"{where}: an empty read (clip_read returning 2) recorded {fails}, wanted one "
                                    f"failure naming RHIZO_CLIP_EMPTY and {snap}")
            elif len(fails) != 1 or "RHIZO_CLIP_EMPTY" in fails[0]:
                problems.append(f"{where}: no answer (clip_read returning 1) recorded {fails}, wanted one failure "
                                "that does not claim an empty read")
    return problems


def icon_leg_problems(lines, spans):
    """return the problems when the icon leg does not read through desk_user_pull"""
    if ICON_LEG not in spans:
        return [f'no leg {ICON_LEG} (step "{ICON_LEG}. ...") in the system test']
    start, end = spans[ICON_LEG]
    where = f"leg {ICON_LEG} (line {start + 1})"
    code = [(i, l) for i, l in enumerate(lines[start:end], start) if is_code(l)]
    problems = [f"{where} reads the notification icon with a root pull at line {i + 1}"
                for i, l in code if ROOT_ICON_PULL_RE.search(l)]
    if not any(USER_ICON_PULL_RE.search(l) for _i, l in code):
        problems.append(f"{where} never reads the notification icon through desk_user_pull \"$icon_path\"")
    return problems


PULL_STUBS = """
set -u
unset DESK_USER_LIB_SOURCED
source "$LIB" || exit 3
desk_user_sh() {
  while [[ "${1:-}" == --* ]]; do shift 2; done
  local out; out=$(bash -c "$2"); local rc=$?
  case "$MODE" in
    whole) printf '%s\\n' "$out"; return $rc ;;
    cut) printf '%s' "${out%%$'\\n'*}" | head -c 40; return 0 ;;
    noise) printf 'not base64 at all!\\nRHIZO_PULL_DONE\\n'; return 0 ;;
    banner) printf 'aGVsbG8=\\n%s\\n' "$out"; return $rc ;;
  esac
}
printf 'old' > "$DST"
desk_user_pull "$SRC" "$DST" 5; echo "rc=$?"
"""

PULL_CASES = (
    ("a whole read", "whole", True, 0),
    ("a missing file", "whole", False, 1),
    ("a read cut off before its end", "cut", True, 1),
    ("a reply that is not base64", "noise", True, 1),
    ("a reply with a line before the payload", "banner", True, 1),
)


def pull_helper_problems(lib_path):
    """return the problems when desk_user_pull gives a wrong answer in any read case"""
    if not os.path.exists(lib_path):
        return [f"no {lib_path}"]
    problems = []
    payload = bytes(range(256)) * 9
    for case, mode, exists, want_rc in PULL_CASES:
        with tempfile.TemporaryDirectory() as d:
            src, dst = os.path.join(d, "icon-0.png"), os.path.join(d, "got.png")
            if exists:
                with open(src, "wb") as f:
                    f.write(payload)
            rc, out, err = run_bash(PULL_STUBS, {"LIB": lib_path, "MODE": mode, "SRC": src, "DST": dst})
            m = re.search(r"rc=(\d+)\s*$", out)
            got = None
            if os.path.exists(dst):
                with open(dst, "rb") as f:
                    got = f.read()
        if rc != 0 or not m:
            problems.append(f"desk_user_pull did not run for {case}: rc={rc} {err.strip()[:200]}")
            continue
        if int(m.group(1)) != want_rc:
            problems.append(f"desk_user_pull returned {m.group(1)} for {case}, wanted {want_rc}")
        if want_rc == 0 and got != payload:
            problems.append(f"desk_user_pull's copy for {case} is not the file byte for byte "
                            f"({'absent' if got is None else f'{len(got)} bytes'})")
        if want_rc != 0 and got is not None:
            problems.append(f"desk_user_pull left a local file behind for {case} ({len(got)} bytes)")
    return problems


SOURCE_RE = re.compile(r"^\s*source\s+((?:\./|\.\./[\w-]+/|\.\./\.\./vm/)[\w.-]+\.sh)", re.M)


def with_sourced_libs(text):
    """return the text plus sourced local libs"""
    out = text
    for lib in SOURCE_RE.findall(text):
        path = os.path.join(TOOLS, "..", "..", "..", "system", "desktop", lib)
        if os.path.exists(path):
            with open(path) as f:
                out += "\n" + f.read()
    return out


def check_text(text):
    """return the problems from every leg check of the test text"""
    lines = text.split("\n")
    spans = leg_spans(lines)
    return (stay_awake_problems(lines, spans) + clip_read_problems(with_sourced_libs(text))
            + clip_leg_problems(lines, spans) + icon_leg_problems(lines, spans))


FIXED_TEST = r'''#!/bin/bash
step "2. connect the bridge"
../../vm/boot/adb-tunnel.sh up >"$EV/desktop-adb.log" 2>&1 || { fail "adb-tunnel.sh up failed"; exit 1; }
# held awake for the whole run
android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
timeout 60 "$ADB" push fixture.apk /data/local/tmp/ || { fail "adb push failed"; exit 1; }

clip_focus_snapshot() {
  {
    echo "=== dumpsys window"
    android_sh "$INIT" "dumpsys window"
    echo "=== dumpsys window displays"
    android_sh "$INIT" "dumpsys window displays"
    echo "=== dumpsys activity activities"
    android_sh "$INIT" "dumpsys activity activities"
  } > "$1" 2>&1
}

clip_read() {
  local pat="$1" secs="$2" snap="$3" since deadline logs hit
  since=$(logcat_since_marker "$INIT")
  [[ "$since" =~ ^[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.000$ ]] || return 1
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_read" >/dev/null 2>&1
  deadline=$(( $(date +%s) + secs ))
  while (( $(date +%s) < deadline )); do
    logs=$(android_sh "$INIT" "logcat -d -b all -t '$since'")
    if grep -a -q 'RHIZO_CLIP_EMPTY' <<<"$logs"; then
      clip_focus_snapshot "$snap"
      return 2
    fi
    hit=$(grep -a -o "$pat" <<<"$logs" | tail -1)
    [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
    sleep 2
  done
  return 1
}

step "3. the test app is a real, painted window"

step "4. clipboard text, host -> Android"
for round in $(seq 1 "$ROUNDS"); do
  want="rhizo-host-clip-$(nonce)"
  set_since=$(logcat_since_marker "$INIT")
  clipcmd "set text/plain $want"
  if ! clip_wait_applied "$set_since" "RHIZO_DESK_CLIP_APPLIED mime=text/[^ ]* sha256=x"; then
    fail "round $round: the android app never applied the host's clip"
    break
  fi
  got=$(clip_read "RHIZO_CLIP_READ mime=[^ ]* b64=[A-Za-z0-9+/=]*" 45 "$EV/focus-at-clip-read-4.txt")
  read_rc=$?
  if (( read_rc == 2 )); then
    fail "round $round: the app read an empty clipboard (RHIZO_CLIP_EMPTY), focus in $EV/focus-at-clip-read-4.txt"
    break
  fi
  if [[ -z "$got" ]]; then
    fail "round $round: the app never reported a clipboard read"
    break
  fi
done
pass "the host selection arrived"

step "5. clipboard text, Android -> host"

step "6. an Android notification reaches the desktop with its own bytes and icon"
icon_path=$(python3 -c 'print("/tmp/rhizo-notif-icons.x/icon-0.png")')
if [[ -z "$icon_path" ]]; then
  fail "the notification carried no icon to the desktop"
elif ! desk_user_pull "$icon_path" "$EV/notification-icon.png" 60; then
  fail "could not read $icon_path as the desktop user"
fi
  step "7. activating the desktop notification brings the Android app forward"

step "10. clipboard image, host -> Android"
make_png "$WORKDIR/host-clip.png" 40 90 200
set_since=$(logcat_since_marker "$INIT")
got="" read_rc=3
if clip_wait_applied "$set_since" "RHIZO_DESK_CLIP_APPLIED mime=image/png"; then
  got=$(clip_read "RHIZO_CLIP_READ mime=image/png b64=[A-Za-z0-9+/=]*" 60 "$EV/focus-at-clip-read-10.txt")
  read_rc=$?
fi
if (( read_rc == 3 )); then
  fail "the android app never applied the host's image clip"
elif (( read_rc == 2 )); then
  fail "the app read an empty image clipboard (RHIZO_CLIP_EMPTY), focus in $EV/focus-at-clip-read-10.txt"
elif [[ -z "$got" ]]; then
  fail "the app never reported reading an image clip"
fi

step "11. clipboard image, Android -> host"
'''

PRE_FIX_TEST = r'''#!/bin/bash
step "2. connect the bridge"
../../vm/boot/adb-tunnel.sh up >"$EV/desktop-adb.log" 2>&1 || { fail "adb-tunnel.sh up failed"; exit 1; }
timeout 60 "$ADB" push fixture.apk /data/local/tmp/ || { fail "adb push failed"; exit 1; }

step "3. the test app is a real, painted window"

step "4. clipboard text, host -> Android"
for round in $(seq 1 "$ROUNDS"); do
  want="rhizo-host-clip-$(nonce)"
  clipcmd "set text/plain $want"
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_read" >/dev/null 2>&1
  got=$(app_wait_token "RHIZO_CLIP_READ mime=[^ ]* b64=[A-Za-z0-9+/=]*" 45)
  if [[ -z "$got" ]]; then
    fail "round $round: the app never reported a clipboard read"
    break
  fi
done
pass "the host selection arrived"

step "5. clipboard text, Android -> host"

step "6. an Android notification reaches the desktop with its own bytes and icon"
icon_path=$(python3 -c 'print("/tmp/rhizo-notif-icons.x/icon-0.png")')
if [[ -z "$icon_path" ]]; then
  fail "the notification carried no icon to the desktop"
else
  pull "$icon_path" "$EV/notification-icon.png" 60 || fail "could not retrieve the icon the desktop was given"
fi
  step "7. activating the desktop notification brings the Android app forward"

step "10. clipboard image, host -> Android"
make_png "$WORKDIR/host-clip.png" 40 90 200
android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_read" >/dev/null 2>&1
got=$(app_wait_token "RHIZO_CLIP_READ mime=image/png b64=[A-Za-z0-9+/=]*" 60)
if [[ -z "$got" ]]; then
  fail "the app never reported reading an image clip"
fi

step "11. clipboard image, Android -> host"
'''

PRE_FIX_EXPECTED = (
    ("leg 2 (line", "not display.sh's stay-awake"),
    ("no clip_read() in the system test",),
    ("leg 4 (line", "called clip_read 0 time"),
    ("leg 10 (line", "called clip_read 0 time"),
    ("leg 4 (line", "never waits for the android app's RHIZO_DESK_CLIP_APPLIED"),
    ("leg 6 (line", "with a root pull"),
    ("leg 6 (line", "never reads the notification icon through desk_user_pull"),
)

AWAKE_BLOCK = ('# held awake for the whole run\n'
               'android_sh "$INIT" "cmd battery set ac 1" >/dev/null\n'
               'android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null\n'
               'android_sh "$INIT" "input keyevent 224" >/dev/null\n')
PUSH_LINE = 'timeout 60 "$ADB" push fixture.apk /data/local/tmp/ || { fail "adb push failed"; exit 1; }\n'
MARKER_LINE = '  since=$(logcat_since_marker "$INIT")\n'
GUARD_LINE = '  [[ "$since" =~ ^[0-9]{2}-[0-9]{2}\\ [0-9]{2}:[0-9]{2}:[0-9]{2}\\.000$ ]] || return 1\n'
START_LINE = '  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_read" >/dev/null 2>&1\n'
POLL_LINE = '    logs=$(android_sh "$INIT" "logcat -d -b all -t \'$since\'")\n'
EMPTY_CHECK = ("    if grep -a -q 'RHIZO_CLIP_EMPTY' <<<\"$logs\"; then\n"
               '      clip_focus_snapshot "$snap"\n'
               "      return 2\n"
               "    fi\n")

MUTATIONS = (
    ("the stay-awake runs after the push instead of right after the tunnel",
     lambda t: t.replace(AWAKE_BLOCK, "", 1).replace(PUSH_LINE, PUSH_LINE + AWAKE_BLOCK, 1),
     (("leg 2 (line", "not display.sh's stay-awake"),)),
    ("the stay-awake drops stay_on_while_plugged_in",
     lambda t: t.replace('android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null\n', "", 1),
     (("leg 2 (line", "not display.sh's stay-awake"),)),
    ("clip_read waits for the read token alone",
     lambda t: t.replace(EMPTY_CHECK, "", 1),
     (("clip_read returned 1 for an empty read, wanted 2",), ("an empty read left no focus snapshot",))),
    ("clip_read polls the whole ring",
     lambda t: t.replace(POLL_LINE, '    logs=$(android_sh "$INIT" "logcat -d -b all")\n', 1),
     (("clip_read returned 2 for only an earlier leg's empty read, wanted 1",),)),
    ("clip_read takes its logcat marker after the am start",
     lambda t: t.replace(MARKER_LINE + GUARD_LINE + START_LINE, START_LINE + MARKER_LINE + GUARD_LINE, 1),
     (("clip_read took no logcat marker before the am start",),)),
    ("clip_read banks no focus snapshot",
     lambda t: t.replace('      clip_focus_snapshot "$snap"\n', "", 1),
     (("an empty read left no focus snapshot",),)),
    ("the focus snapshot drops dumpsys window displays",
     lambda t: t.replace('    echo "=== dumpsys window displays"\n    android_sh "$INIT" "dumpsys window displays"\n', "", 1),
     (("never asked for `dumpsys window displays`",),)),
    ("leg 4 keeps reading after an empty read",
     lambda t: t.replace('focus in $EV/focus-at-clip-read-4.txt"\n    break\n', 'focus in $EV/focus-at-clip-read-4.txt"\n', 1),
     (("leg 4 (line", "an empty read (clip_read returning 2) recorded"),)),
    ("leg 10's empty read fails without naming the token",
     lambda t: t.replace("the app read an empty image clipboard (RHIZO_CLIP_EMPTY), focus", "the app read nothing, focus", 1),
     (("leg 10 (line", "an empty read (clip_read returning 2) recorded"),)),
    ("leg 6 reads the icon with a root pull again",
     lambda t: t.replace('elif ! desk_user_pull "$icon_path" "$EV/notification-icon.png" 60; then',
                         'elif ! pull "$icon_path" "$EV/notification-icon.png" 60; then', 1),
     (("leg 6 (line", "with a root pull"), ("leg 6 (line", "never reads the notification icon through desk_user_pull"))),
    ("leg 4 reads before the android applied the host's clip",
     lambda t: t.replace('  if ! clip_wait_applied "$set_since" "RHIZO_DESK_CLIP_APPLIED mime=text/[^ ]* sha256=x"; then\n'
                         '    fail "round $round: the android app never applied the host\'s clip"\n    break\n  fi\n', "", 1),
     (("leg 4 (line", "never waits for the android app's RHIZO_DESK_CLIP_APPLIED"),)),
    ("leg 10 asks the app to read after the android app never applied the clip",
     lambda t: t.replace('  read_rc=$?\nfi\nif (( read_rc == 3 )); then',
                         '  read_rc=$?\nfi\ngot=$(clip_read "RHIZO_CLIP_READ mime=image/png b64=x" 60 "$EV/f")\n'
                         'if (( read_rc == 3 )); then', 1),
     (("leg 10 (line", "a clip the android app never applied recorded"),)),
    ("leg 10 calls a timeout an empty read",
     lambda t: t.replace('fail "the app never reported reading an image clip"',
                         'fail "the app never reported reading an image clip (RHIZO_CLIP_EMPTY?)"', 1),
     (("leg 10 (line", "no answer (clip_read returning 1) recorded"),)),
)


PULL_PLANTS = (
    ("desk_user_pull trusts a read with no end marker",
     'if [[ "$out" != *$\'\\n\'RHIZO_PULL_DONE ]]; then', 'if false; then',
     "desk_user_pull returned 0 for a read cut off before its end"),
    ("desk_user_pull keeps an old local file",
     '  rm -f "$dst"\n  out=$(desk_user_sh', '  out=$(desk_user_sh',
     "left a local file behind for a missing file"),
    ("desk_user_pull decodes every line that came back",
     "if [[ \"$out\" == *$'\\n'* ]] || ! printf '%s' \"$out\" | base64 -d > \"$dst\" 2>/dev/null; then",
     "if ! printf '%s' \"$out\" | base64 -d > \"$dst\" 2>/dev/null; then",
     "returned 0 for a reply with a line before the payload"),
)


def avc(comm, perm, extra, scon="rhizo_host", tcon="kernel", tclass="fifo_file"):
    """return an audit denial line for a command, permission and contexts"""
    return ('audit: avc:  denied  { %s } for  pid=9 comm="%s" path="pipe:[1]" dev="pipefs" ino=1 %s'
            'scontext=u:r:%s:s0 tcontext=u:r:%s:s0 tclass=%s permissive=0'
            % (perm, comm, extra, scon, tcon, tclass))


STEP14_CASES = (
    ("the harness ssh shell sizing its window on sshd's pipe", [avc("bash", "ioctl", "ioctlcmd=0x5413 ")], False),
    ("a planted bridge write beside it", [avc("bash", "ioctl", "ioctlcmd=0x5413 "),
                                          avc("selftest", "write", "", "kernel", "rhizo_host")], True),
    ("a bridge process sizing a window", [avc("rhizo-deskd", "ioctl", "ioctlcmd=0x5413 ")], True),
    ("a bash reading the pipe", [avc("bash", "read", "")], True),
    ("a bash asking the pipe how much it holds", [avc("bash", "ioctl", "ioctlcmd=0x541b ")], True),
    ("a bash sizing its window the other way", [avc("bash", "ioctl", "ioctlcmd=0x5413 ", "kernel", "rhizo_host")],
     True),
    ("a bash sizing its window on a socket",
     [avc("bash", "ioctl", "ioctlcmd=0x5413 ", tclass="unix_stream_socket")], True),
)
STEP14_START = "  total=$(grep -c -a 'avc: *denied' \"$EV/avc-run.log\")\n"
STEP14_END = '  if [[ -n "$enforced" ]]; then\n'


def step14_filter_problems(text):
    """return the problems in the leg 14 denial filter"""
    start = text.find(STEP14_START)
    end = text.find(STEP14_END, start)
    if start < 0 or end < 0:
        return ["leg 14 has no denial filter block to run (from its total= read to its enforced test)"]
    block = text[start:end]
    problems = []
    for name, lines, counts in STEP14_CASES:
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "avc-run.log"), "w") as f:
                f.write("\n".join(lines) + "\n")
            rc, out, err = run_bash('log() { :; }\n' + block + 'printf "%s" "$enforced"\n', {"EV": d})
        if rc != 0:
            problems.append("leg 14's filter exited %d on '%s': %s" % (rc, name, err.strip()[:160]))
        elif bool(out.strip()) != counts:
            problems.append("leg 14 %s %s" % ("let through" if not counts else "dropped", name))
    return problems


STEP14_MUTATIONS = (
    ("leg 14 counts the harness shell again", "  enforced=$(grep -avE \"$harness_winsz\" <<<\"$enforced\")\n", "",
     "let through the harness ssh shell"),
    ("leg 14 drops every TIOCGWINSZ", "harness_winsz='comm=\"bash\" .* ioctlcmd", "harness_winsz='.* ioctlcmd",
     "dropped a bridge process sizing a window"),
    ("leg 14 drops every bash denial", " .* ioctlcmd=0x5413 scontext=u:r:rhizo_host:s0 tcontext=u:r:kernel:s0 tclass=fifo_file'",
     " .* scontext=u:r:rhizo_host:s0 tcontext=u:r:kernel:s0 tclass=fifo_file'", "dropped a bash reading the pipe"),
    ("leg 14 drops every bash ioctl", "ioctlcmd=0x5413 scontext", "ioctlcmd=0x[0-9a-f]+ scontext",
     "dropped a bash asking the pipe how much it holds"),
    ("leg 14 drops a bash TIOCGWINSZ in either direction",
     "ioctlcmd=0x5413 scontext=u:r:rhizo_host:s0 tcontext=u:r:kernel:s0 tclass=fifo_file'", "ioctlcmd=0x5413'",
     "dropped a bash sizing its window the other way"),
    ("leg 14 drops a bash TIOCGWINSZ on a socket too", "tcontext=u:r:kernel:s0 tclass=fifo_file'",
     "tcontext=u:r:kernel:s0 tclass=(fifo_file|unix_stream_socket)'", "dropped a bash sizing its window on a socket"),
)


def unmet(problems, expected):
    """return the expectations that no problem matches"""
    return [e for e in expected if not any(all(s in p for s in e) for p in problems)]


def selftest():
    """check the fixed shape and each planted-defect copy"""
    failed = False
    got = check_text(FIXED_TEST)
    if got:
        print("SELFTEST FAILED: the fixed shape was refused:", file=sys.stderr)
        for p in got:
            print(f"    {p}", file=sys.stderr)
        failed = True
    pre = check_text(PRE_FIX_TEST)
    for e in unmet(pre, PRE_FIX_EXPECTED):
        print(f"SELFTEST FAILED: the pre-fix shape was not refused for {e} (got {pre})", file=sys.stderr)
        failed = True
    for name, edit, expected in MUTATIONS:
        mutated = edit(FIXED_TEST)
        if mutated == FIXED_TEST:
            print(f"SELFTEST FAILED: mutation '{name}' matched nothing in the fixture", file=sys.stderr)
            failed = True
            continue
        problems = check_text(mutated)
        for e in unmet(problems, expected):
            print(f"SELFTEST FAILED: '{name}' was not refused for {e} (got {problems})", file=sys.stderr)
            failed = True
    got = pull_helper_problems(DESK_USER_LIB)
    if got:
        print("SELFTEST FAILED: the real desk_user_pull was refused:", file=sys.stderr)
        for p in got:
            print(f"    {p}", file=sys.stderr)
        failed = True
    with open(DESK_USER_LIB) as f:
        lib = f.read()
    for name, old, new, want in PULL_PLANTS:
        if old not in lib:
            print(f"SELFTEST FAILED: plant '{name}' no longer finds its anchor in desk-user-lib.sh", file=sys.stderr)
            failed = True
            continue
        with tempfile.TemporaryDirectory() as d:
            planted = os.path.join(d, "desk-user-lib.sh")
            with open(planted, "w") as f:
                f.write(lib.replace(old, new, 1))
            problems = pull_helper_problems(planted)
        if not any(want in p for p in problems):
            print(f"SELFTEST FAILED: '{name}' was not refused for '{want}' (got {problems})", file=sys.stderr)
            failed = True
    with open(os.path.join(TOOLS, "..", "..", "..", "system", "desktop", "desktop.sh")) as f:
        test = f.read()
    got = step14_filter_problems(test)
    if got:
        print("SELFTEST FAILED: the real leg 14 filter was refused: %s" % got, file=sys.stderr)
        failed = True
    for name, old, new, want in STEP14_MUTATIONS:
        if old not in test:
            print(f"SELFTEST FAILED: mutation '{name}' finds no anchor in desktop.sh", file=sys.stderr)
            failed = True
            continue
        problems = step14_filter_problems(test.replace(old, new, 1))
        if not any(want in p for p in problems):
            print(f"SELFTEST FAILED: '{name}' was not refused for '{want}' (got {problems})", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print(f"selftest ok: passes the fixed shape, refuses the pre-fix shape and {len(MUTATIONS)} single regressions, "
          f"desk_user_pull's {len(PULL_PLANTS)} reverted guards and leg 14's {len(STEP14_MUTATIONS)} filter regressions")
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    path = argv[1] if len(argv) > 1 else os.path.join(TOOLS, "..", "..", "..", "system", "desktop", "desktop.sh")
    with open(path) as f:
        text = f.read()
    problems = check_text(text) + step14_filter_problems(text)
    for p in problems:
        print(f"FAIL: {os.path.basename(path)}: {p}")
    if problems:
        return 1
    helper = pull_helper_problems(DESK_USER_LIB)
    for p in helper:
        print(f"FAIL: desk-user-lib.sh: {p}")
    if helper:
        return 1
    print("test-desktop holds Android awake from leg 2, fails a clipboard read the app answered "
          "RHIZO_CLIP_EMPTY at once, banking which window held focus, reads the notification icon "
          "as the desktop user, and counts every leg-14 denial but the harness shell's own window-size probe")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
