#!/usr/bin/env python3

import os
import re
import shlex
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(TOOLS))))
GUARDED_LEGS = ("7", "8", "9")
GUARD_LINE = "if sandbox_up_for_leg; then"
CAPTURE = "logcat-since-restart.txt"
STEP_RE = re.compile(r'^\s*step "(\d+)\.')
IF_OPEN_RE = re.compile(r"^\s*if\b.*;\s*then\s*$")
FI_RE = re.compile(r"^\s*fi\s*$")
TRAP_EXIT_RE = re.compile(r"^\s*trap\s.*\bEXIT\s*$")
HOSTFS_WRITE_RE = re.compile(r">\s*\"?\$HOSTFS_CONF\b")

LOGCAT_LINE = "09-12 13:57:24.101  1234  1250 I ActivityManager: Start proc 4321:com.rhizo.deskapp"


def function_source(text, name):
    """return the source text of a shell function, or None"""
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


def run_bash(script, env_extra=None):
    """run a bash script with extra environment and return its exit code, output and errors"""
    env = dict(os.environ)
    env.update(env_extra or {})
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60, env=env)
    return r.returncode, r.stdout, r.stderr


def leg_guard_problems(lines, spans):
    """return the problems when legs 7 to 9 do not open with the sandbox guard"""
    problems = []
    for leg in GUARDED_LEGS:
        if leg not in spans:
            problems.append(f"no leg {leg} (step \"{leg}. ...\") in the system test")
            continue
        start, end = spans[leg]
        code = [(i, l) for i, l in enumerate(lines[start + 1:end], start + 1) if is_code(l)]
        if not code or code[0][1].strip() != GUARD_LINE:
            problems.append(f"leg {leg} (line {start + 1}) does not open with `{GUARD_LINE}`")
            continue
        depth = 0
        for n, (i, l) in enumerate(code):
            if IF_OPEN_RE.match(l):
                depth += 1
            elif FI_RE.match(l):
                depth -= 1
            if depth == 0 and n != len(code) - 1:
                problems.append(f"leg {leg}: the guard's block closes at line {i + 1}, "
                                "before the leg's last statement")
                break
        else:
            if depth != 0:
                problems.append(f"leg {leg}: the guard's block is still open at the leg's last line")
    return problems


UP_STUBS = """
set -u
FAILED=0 SELFTEST=1 TEST_STEP='9. leg under test'
SELFTEST_UNRUN=()
log() { :; }
fail() { printf 'FAIL %s\\n' "$*" >> "$CALLS"; FAILED=$((FAILED + 1)); }
ssh_vm() {
  case "${*: -1}" in
    *'"init second_stage"'*) printf '%s\\n' "$STUB_PGREP" ;;
    *is-active*) echo inactive ;;
  esac
}
getprop_vm() { printf '%s' "$STUB_BC"; }
getprop_live() { printf '%s' "$STUB_BC"; }
"""

UP_CASES = (
    ("", "", "", 1),
    ("100", "99\n100", "1", 0),
    ("100", "200", "1", 1),
    ("100", "100", "", 1),
    ("100", "", "1", 1),
    ("10", "100", "1", 1),
)


def sandbox_up_problems(text):
    """return the problems in sandbox_up_for_leg's stubbed states"""
    src = function_source(text, "sandbox_up_for_leg")
    if not src:
        return ["no sandbox_up_for_leg() in the system test"]
    with open(os.path.join(REPO, "test", "vm", "common.sh")) as f:
        common = f.read()
    scan = re.search(r"^RHIZO_INIT_SCAN_BODY=.*$", common, re.M)
    lookup = function_source(common, "guest_init_pids")
    if not scan or not lookup:
        return ["no RHIZO_INIT_SCAN_BODY or guest_init_pids() in common.sh"]
    problems = []
    for init, pgrep, bc, want in UP_CASES:
        with tempfile.NamedTemporaryFile(mode="r") as calls:
            script = (UP_STUBS + scan.group(0) + "\n" + lookup + "\n" + src +
                      f"\nINIT={shlex.quote(init)} STUB_PGREP={shlex.quote(pgrep)} STUB_BC={shlex.quote(bc)}\n"
                      'sandbox_up_for_leg; rc=$?\n'
                      'echo "rc=$rc unrun=${#SELFTEST_UNRUN[@]}"\n')
            rc, out, err = run_bash(script, {"CALLS": calls.name})
            fails = sum(1 for l in calls.read().splitlines() if l.startswith("FAIL "))
        got = re.search(r"rc=(\d+) unrun=(\d+)", out)
        case = f"INIT='{init}' pgrep={pgrep!r} boot_completed='{bc}'"
        if rc != 0 or not got:
            problems.append(f"sandbox_up_for_leg did not run with {case}: rc={rc} {err.strip()[:200]}")
            continue
        got_rc, unrun = int(got.group(1)), int(got.group(2))
        want_fails = 0 if want == 0 else 1
        if (got_rc == 0) != (want == 0):
            problems.append(f"sandbox_up_for_leg returned {got_rc} with {case}, wanted {want}")
        if fails != want_fails:
            problems.append(f"sandbox_up_for_leg recorded {fails} FAIL line(s) with {case}, wanted {want_fails}")
        if unrun != want_fails:
            problems.append(f"sandbox_up_for_leg left {unrun} SELFTEST_UNRUN entr(ies) with {case}, "
                            f"wanted {want_fails}")
    return problems


def selftest_verdict_problems(text):
    """return the problems when the selftest verdict loop does not read SELFTEST_UNRUN"""
    m = re.search(r"for st_step in \"\$\{SELFTEST_STEPS\[@\]\}\"; do(.*?)\n\s*done", text, re.S)
    if not m:
        return ["no selftest verdict loop over SELFTEST_STEPS in the system test"]
    if "SELFTEST_UNRUN" not in m.group(1):
        return ["the selftest verdict loop never reads SELFTEST_UNRUN"]
    return []


CLEANUP_STUBS = """
set -u
log() { :; }
ssh_vm() { printf 'SSH %s\\n' "${*: -1}" >> "$CALLS"; return "$STUB_SSH_RC"; }
test_cleanup() { local rc=$?; printf 'TEST_CLEANUP rc=%s\\n' "$rc" >> "$CALLS"; return $rc; }
HOSTFS_CONF=/etc/rhizo/hostfs.conf
"""

CLEANUP_CASES = ((1, 0, True), (0, 0, False), (1, 255, True))


def hostfs_undo_problems(text, lines):
    """return the problems when the exit trap does not remove hostfs.conf"""
    problems = []
    set_flag = [i for i, l in enumerate(lines) if l.strip() == "HOSTFS_CONF_WRITTEN=1"]
    for i, l in enumerate(lines):
        if is_code(l) and HOSTFS_WRITE_RE.search(l) and not any(s < i for s in set_flag):
            problems.append(f"line {i + 1} writes $HOSTFS_CONF with no HOSTFS_CONF_WRITTEN=1 before it, "
                            "so nothing takes it back off the vm")
    traps = [(i, l) for i, l in enumerate(lines) if TRAP_EXIT_RE.match(l)]
    if len(traps) != 1:
        return problems + [f"the system test sets {len(traps)} EXIT traps, wanted exactly one chaining install_cleanup "
                           "ahead of test_cleanup (a second bare trap replaces test_init's)"]
    trap_i, trap_line = traps[0]
    ic, gc = trap_line.find("install_cleanup"), trap_line.find("test_cleanup")
    if ic < 0 or gc < 0 or ic > gc:
        problems.append(f"line {trap_i + 1}: `{trap_line.strip()}` does not run install_cleanup before test_cleanup")
    init_at = [i for i, l in enumerate(lines) if is_code(l) and l.strip().startswith("test_init ")]
    if not init_at or init_at[0] > trap_i:
        problems.append(f"line {trap_i + 1}: the EXIT trap is set before test_init, whose own trap then "
                        "replaces it")
    init_flag = [i for i, l in enumerate(lines) if l.strip() == "HOSTFS_CONF_WRITTEN=0"]
    if not init_flag or init_flag[0] > trap_i:
        problems.append("HOSTFS_CONF_WRITTEN=0 is not set before the EXIT trap")
    src = function_source(text, "install_cleanup")
    if not src:
        problems.append("no install_cleanup() in the system test")
        return problems
    for written, ssh_rc, want_rm in CLEANUP_CASES:
        with tempfile.NamedTemporaryFile(mode="r") as calls:
            script = (CLEANUP_STUBS + src + "\n" + trap_line.strip() + "\n"
                      f"HOSTFS_CONF_WRITTEN={written}\nexit 3\n")
            rc, _out, err = run_bash(script, {"CALLS": calls.name, "STUB_SSH_RC": str(ssh_rc)})
            seen = calls.read().splitlines()
        case = f"HOSTFS_CONF_WRITTEN={written}, ssh exit {ssh_rc}"
        rm_at = [n for n, l in enumerate(seen) if l.startswith("SSH ") and "rm -f /etc/rhizo/hostfs.conf" in l]
        gc_at = [n for n, l in enumerate(seen) if l.startswith("TEST_CLEANUP ")]
        if rc != 3:
            problems.append(f"exiting 3 through the trap with {case} exited {rc}: "
                            f"{err.strip()[:200]}")
        if not gc_at or seen[gc_at[0]] != "TEST_CLEANUP rc=3":
            problems.append(f"test_cleanup did not see rc=3 with {case} (calls: {seen})")
        if want_rm and not rm_at:
            problems.append(f"install_cleanup did not remove /etc/rhizo/hostfs.conf with {case}")
        if not want_rm and rm_at:
            problems.append(f"install_cleanup removed /etc/rhizo/hostfs.conf with {case}, which this run never wrote")
        if rm_at and gc_at and rm_at[0] > gc_at[0]:
            problems.append(f"install_cleanup ran after test_cleanup with {case}")
    return problems


CAPTURE_CASES = (
    ("", False),
    ("nsenter: failed to execute /system/bin/toybox: Permission denied\n", False),
    ("--------- beginning of main\n", False),
    (LOGCAT_LINE + "\n", True),
    ("--------- beginning of system\n" + LOGCAT_LINE, True),
)


def sweep_read_problems(text, lines, spans):
    """return the problems when the sweep does not read a logcat capture"""
    problems = []
    src = function_source(text, "logcat_capture_read")
    if not src:
        problems.append("no logcat_capture_read() in the system test")
    else:
        for content, want in CAPTURE_CASES:
            with tempfile.NamedTemporaryFile(mode="w") as cap:
                cap.write(content)
                cap.flush()
                rc, _out, err = run_bash(src + f"\nlogcat_capture_read {shlex.quote(cap.name)}\n")
            if (rc == 0) != want:
                problems.append(f"logcat_capture_read returned {rc} for a capture of {content[:60]!r}, "
                                f"wanted {'0' if want else 'non-zero'} {err.strip()[:120]}")
    if "9" not in spans:
        return problems + ["no leg 9 in the system test"]
    start, end = spans["9"]
    body = list(range(start + 1, end))
    writes = [i for i in body if is_code(lines[i]) and re.search(r">\s*\"\$EV/%s\"" % re.escape(CAPTURE), lines[i])]
    sweeps = [i for i in body if is_code(lines[i]) and "TEST_FATAL_RE" in lines[i]]
    reads = [i for i in body if is_code(lines[i]) and "logcat_capture_read" in lines[i] and CAPTURE in lines[i]
             and (re.search(r"\|\|\s*fail\b", lines[i])
                  or (i + 1 < end and re.match(r"^\s*\|\|\s*fail\b", lines[i + 1])))]
    if not writes or not sweeps:
        return problems + ["leg 9 no longer captures logcat-since-restart.txt and sweeps it for TEST_FATAL_RE"]
    if not any(max(writes) < r < min(sweeps) for r in reads):
        problems.append(f"leg 9 (line {start + 1}) sweeps {CAPTURE} for fatal lines without first failing on a "
                        "capture that holds no logcat line")
    return problems


PRIMARY_MARKER = ("09-27 00:40:28.323   113   144 I rhizo-composer: MaybeTeardownOnLastAppDisplayClosed: "
                  "last app display closed -- primary's own surface dropped too, connection going down")
APP_CLOSE = "09-27 00:40:27.575   113   150 I rhizo-wayland-backend: WaylandBackend: display 2 xdg_toplevel.close from compositor"
PRIMARY_CLOSE = "09-27 00:40:27.580   113   150 I rhizo-wayland-backend: WaylandBackend: display 1 xdg_toplevel.close from compositor"
PRIMARY_WIN = '{"app_id": "rhizo", "id": 10, "title": "Rhizo", "x": 0, "y": 0, "w": 960, "h": 1080}'
CRASH_LINE = "09-27 00:40:27.600  1402  1402 F libc    : Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR) in tid 1402 (surfaceflinger)"
APP_WIN = '{"app_id": "rhizo-com.android.calendar", "id": 11, "title": "Calendar", "x": 960, "y": 0, "w": 960, "h": 1080}'

PRIMARY_CASES = (
    ("the primary is still mapped", "10", "11\n12", PRIMARY_WIN, APP_CLOSE, True),
    ("the composer dropped the primary with the last app", "10", "11\n12", "", APP_CLOSE + "\n" + PRIMARY_MARKER, True),
    ("no primary was mapped before the close", "", "11", "", APP_CLOSE, True),
    ("the loop closed the primary's own window", "10", "10\n11", "", APP_CLOSE + "\n" + PRIMARY_MARKER, False),
    ("the compositor closed the primary's toplevel", "10", "11", "",
     APP_CLOSE + "\n" + PRIMARY_CLOSE + "\n" + PRIMARY_MARKER, False),
    ("the primary vanished with no last-app teardown", "10", "11", "", APP_CLOSE, False),
    ("the logcat since the close holds no line", "10", "11", PRIMARY_WIN, "", False),
    ("a primary with another app_id is not the primary", "10", "11",
     PRIMARY_WIN.replace('"app_id": "rhizo"', '"app_id": "rhizo-x"'), APP_CLOSE, False),
    ("the window listing before the close failed", "?", "11", "", APP_CLOSE + "\n" + PRIMARY_MARKER, False),
    ("a crash took the displays down before the teardown", "10", "11", "",
     APP_CLOSE + "\n" + CRASH_LINE + "\n" + PRIMARY_MARKER, False),
    ("the teardown precedes every app display's close", "10", "11", "", PRIMARY_MARKER + "\n" + APP_CLOSE, False),
    ("the teardown with no app display closed at all", "10", "11", "", PRIMARY_MARKER, False),
)


def primary_close_problems(text, lines, spans):
    """return the problems with primary_close_verdict and its call"""
    problems = []
    src = function_source(text, "primary_close_verdict")
    reader = function_source(text, "logcat_capture_read")
    if not src or not reader:
        return ["no primary_close_verdict() in the system test"]
    consts = "".join(m.group(0) + "\n" for m in re.finditer(r"^PRIMARY_[A-Z_]+=.*$", text, re.M))
    with open(os.path.join(TOOLS, "..", "..", "..", "system", "lib", "lib.sh")) as f:
        fatal = re.search(r"^TEST_FATAL_RE=.*$", f.read(), re.M)
    if not fatal:
        return ["no TEST_FATAL_RE in lib.sh"]
    consts += fatal.group(0) + "\n"
    for name, before, closed, after, cap, want in PRIMARY_CASES:
        with tempfile.TemporaryDirectory() as d:
            files = {}
            for key, content in (("closed", closed), ("after", after), ("cap", cap)):
                files[key] = os.path.join(d, key)
                with open(files[key], "w") as f:
                    f.write(content + ("\n" if content else ""))
            rc, out, err = run_bash(consts + reader + "\n" + src + "\nprimary_close_verdict "
                                    + " ".join(shlex.quote(a) for a in (before, files["closed"], files["after"], files["cap"])) + "\n")
        if rc not in (0, 1):
            problems.append(f"primary_close_verdict did not run for '{name}': rc={rc} {err.strip()[:200]}")
        elif (rc == 0) != want:
            problems.append(f"primary_close_verdict {'refused' if want else 'passed'} '{name}' "
                            f"({out.strip()[:160]!r})")
        elif not out.strip():
            problems.append(f"primary_close_verdict gave no reason for '{name}'")
    if "10" not in spans:
        return problems + ["no leg 10 in the system test"]
    start, end = spans["10"]
    if any(is_code(lines[i]) and re.search(r"\bprimary_before=\$\(\s*desk_windows\b[^)]*\|", lines[i])
           for i in range(start + 1, end)):
        problems.append(f"leg 10 (line {start + 1}) pipes desk_windows into the primary_before read")
    calls = [i for i in range(start + 1, end) if is_code(lines[i]) and "primary_close_verdict " in lines[i]]
    if not any(re.search(r"\bthen\b|\|\|\s*fail\b", " ".join(lines[i:i + 3])) for i in calls) \
            or not any(is_code(lines[i]) and re.match(r"^\s*fail\b", lines[i]) for i in range(start + 1, end)):
        problems.append(f"leg 10 (line {start + 1}) never fails on primary_close_verdict's refusal")
    return problems


def check_text(text):
    """return the problems from every leg check of the test text"""
    lines = text.split("\n")
    spans = leg_spans(lines)
    return (hostfs_undo_problems(text, lines)
            + leg_guard_problems(lines, spans)
            + sandbox_up_problems(text)
            + selftest_verdict_problems(text)
            + sweep_read_problems(text, lines, spans))


FIXED_TEST = r'''#!/bin/bash
test_init install
SELFTEST_STEPS=()
SELFTEST_UNRUN=()
HOSTFS_CONF_WRITTEN=0
install_cleanup() {
  local rc=$?
  if (( HOSTFS_CONF_WRITTEN )) && ! ssh_vm -t 20 "rm -f $HOSTFS_CONF" >/dev/null 2>&1; then
    log "    could not remove $HOSTFS_CONF from the guest"
  fi
  return $rc
}
trap 'install_cleanup; test_cleanup' EXIT

sandbox_up_for_leg() {
  local live bc="" unit
  live=$(guest_init_pids 10)
  [[ -n "$INIT" ]] && bc=$(getprop_vm "$INIT" sys.boot_completed)
  if [[ -n "$INIT" ]] && grep -qx "$INIT" <<<"$live" && [[ "$bc" == 1 ]]; then
    return 0
  fi
  unit=$(ssh_vm -t 15 "systemctl is-active androidd.service" | tr -d '\r')
  fail "no running sandbox (androidd.service=$unit init=$INIT boot_completed=$bc)"
  (( SELFTEST )) && SELFTEST_UNRUN+=("$TEST_STEP")
  return 1
}
logcat_capture_read() {
  grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' "$1"
}

step "6. restart"
HOSTFS_CONF_WRITTEN=1
ssh_vm -t 30 "printf 'x' > $HOSTFS_CONF" || fail "could not write $HOSTFS_CONF"

step "7. offered"
if sandbox_up_for_leg; then
if ! poll_until 240 3 cache_lists_deskapp; then
  log "    never listed"
fi
pass "offered"
fi

# ---- 8.
step "8. opened"
if sandbox_up_for_leg; then
[[ "$got" == "$want" ]] || fail "got $got"
pass "opened"
fi

step "9. nothing restarted"
if sandbox_up_for_leg; then
if [[ -n "$RESTART_SINCE" ]]; then
  logcat_vm "$INIT" -d -v threadtime -t "$RESTART_SINCE" 2>/dev/null > "$EV/logcat-since-restart.txt"
else
  logcat_vm "$INIT" -d -v threadtime -t 8000 2>/dev/null > "$EV/logcat-since-restart.txt"
fi
logcat_capture_read "$EV/logcat-since-restart.txt" \
  || fail "no logcat line in the capture"
grep -E -B2 -A6 "$TEST_FATAL_RE" "$EV/logcat-since-restart.txt" > "$EV/fatal-lines.txt"
bad=$(grep -cE "$TEST_FATAL_RE" "$EV/fatal-lines.txt")
pass "no restart"
fi

step "10. close"
if (( SELFTEST )); then
  for st_step in "${SELFTEST_STEPS[@]}"; do
    if printf '%s\n' "${SELFTEST_UNRUN[@]}" | grep -Fxq -- "$st_step"; then
      survived+=("$st_step")
      continue
    fi
    grep -Fxq "$st_step" <<<"$failed_steps" || survived+=("$st_step")
  done
fi
'''

PRE_FIX_TEST = r'''#!/bin/bash
test_init install
SELFTEST_STEPS=()

step "6. restart"
ssh_vm -t 30 "printf 'x' > $HOSTFS_CONF" || fail "could not write $HOSTFS_CONF"

step "7. offered"
if ! poll_until 240 3 cache_lists_deskapp; then
  log "    never listed"
fi
pass "offered"

step "8. opened"
[[ "$got" == "$want" ]] || fail "got $got"
pass "opened"

step "9. nothing restarted"
if [[ -n "$RESTART_SINCE" ]]; then
  logcat_vm "$INIT" -d -t "$RESTART_SINCE" 2>/dev/null > "$EV/logcat-since-restart.txt"
fi
grep -E -B2 -A6 "$TEST_FATAL_RE" "$EV/logcat-since-restart.txt" > "$EV/fatal-lines.txt"
bad=$(grep -cE "$TEST_FATAL_RE" "$EV/fatal-lines.txt")
pass "no restart"

step "10. close"
if (( SELFTEST )); then
  for st_step in "${SELFTEST_STEPS[@]}"; do
    grep -Fxq "$st_step" <<<"$failed_steps" || survived+=("$st_step")
  done
fi
'''

PRE_FIX_EXPECTED = (
    ("writes $HOSTFS_CONF with no HOSTFS_CONF_WRITTEN=1",),
    ("sets 0 EXIT traps",),
    ("leg 7 (line", "does not open with"),
    ("leg 8 (line", "does not open with"),
    ("leg 9 (line", "does not open with"),
    ("no sandbox_up_for_leg() in the system test",),
    ("verdict loop never reads SELFTEST_UNRUN",),
    ("no logcat_capture_read() in the system test",),
    ("sweeps logcat-since-restart.txt for fatal lines without first failing",),
)

MUTATIONS = (
    ("leg 8 loses its guard",
     lambda t: t.replace('step "8. opened"\nif sandbox_up_for_leg; then\n', 'step "8. opened"\n', 1)
               .replace('pass "opened"\nfi\n', 'pass "opened"\n', 1),
     (("leg 8 (line", "does not open with"),)),
    ("leg 7's guard closes before the leg ends",
     lambda t: t.replace('step "7. offered"\nif sandbox_up_for_leg; then\n',
                         'step "7. offered"\nif sandbox_up_for_leg; then\n  :\nfi\nif true; then\n', 1),
     (("leg 7: the guard's block closes at line",),)),
    ("the guard only checks INIT is set",
     lambda t: t.replace('if [[ -n "$INIT" ]] && grep -qx "$INIT" <<<"$live" && [[ "$bc" == 1 ]]; then',
                         'if [[ -n "$INIT" ]]; then', 1),
     (("sandbox_up_for_leg returned 0 with INIT='100' pgrep='200'",),
      ("sandbox_up_for_leg returned 0 with INIT='100' pgrep='100' boot_completed=''",))),
    ("the guard refuses without recording a FAIL",
     lambda t: t.replace('  fail "no running sandbox (androidd.service=$unit init=$INIT boot_completed=$bc)"\n', '', 1),
     (("recorded 0 FAIL line(s) with INIT=''",),)),
    ("the guard forgets the selftest",
     lambda t: t.replace('  (( SELFTEST )) && SELFTEST_UNRUN+=("$TEST_STEP")\n', '', 1),
     (("left 0 SELFTEST_UNRUN entr",),)),
    ("the verdict loop ignores unrun legs",
     lambda t: t.replace('    if printf \'%s\\n\' "${SELFTEST_UNRUN[@]}" | grep -Fxq -- "$st_step"; then\n'
                         '      survived+=("$st_step")\n      continue\n    fi\n', '', 1),
     (("verdict loop never reads SELFTEST_UNRUN",),)),
    ("test_cleanup runs first",
     lambda t: t.replace("trap 'install_cleanup; test_cleanup' EXIT", "trap 'test_cleanup; install_cleanup' EXIT", 1),
     (("does not run install_cleanup before test_cleanup",), ("install_cleanup ran after test_cleanup",))),
    ("a second bare trap replaces the chain",
     lambda t: t.replace('step "6. restart"\n', 'step "6. restart"\ntrap test_cleanup EXIT\n', 1),
     (("sets 2 EXIT traps",),)),
    ("the trap swallows the exit status",
     lambda t: t.replace("trap 'install_cleanup; test_cleanup' EXIT", "trap 'install_cleanup; test_cleanup; exit 0' EXIT", 1),
     (("exiting 3 through the trap with",),)),
    ("install_cleanup drops the exit status",
     lambda t: t.replace("  return $rc\n}\ntrap", "  return 0\n}\ntrap", 1),
     (("test_cleanup did not see rc=3",),)),
    ("install_cleanup never removes the config",
     lambda t: t.replace('ssh_vm -t 20 "rm -f $HOSTFS_CONF"', 'ssh_vm -t 20 "true"', 1),
     (("install_cleanup did not remove /etc/rhizo/hostfs.conf",),)),
    ("install_cleanup removes the config unconditionally",
     lambda t: t.replace("if (( HOSTFS_CONF_WRITTEN )) && ! ssh_vm", "if ! ssh_vm", 1),
     (("which this run never wrote",),)),
    ("the flag is initialized after the trap",
     lambda t: t.replace("HOSTFS_CONF_WRITTEN=0\n", "", 1).replace("trap 'install_cleanup; test_cleanup' EXIT\n",
                                                                  "trap 'install_cleanup; test_cleanup' EXIT\nHOSTFS_CONF_WRITTEN=0\n", 1),
     (("HOSTFS_CONF_WRITTEN=0 is not set before the EXIT trap",),)),
    ("the config is written with no flag set",
     lambda t: t.replace("HOSTFS_CONF_WRITTEN=1\n", "", 1),
     (("writes $HOSTFS_CONF with no HOSTFS_CONF_WRITTEN=1",),)),
    ("the capture check passes anything non-empty",
     lambda t: t.replace("grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' \"$1\"",
                         '[[ -s "$1" ]]', 1),
     (("logcat_capture_read returned 0 for a capture of 'nsenter",),)),
    ("the EXIT trap moves above test_init",
     lambda t: t.replace("trap 'install_cleanup; test_cleanup' EXIT\n", "", 1)
               .replace("test_init install\n", "trap 'install_cleanup; test_cleanup' EXIT\ntest_init install\n", 1),
     (("the EXIT trap is set before test_init",),)),
    ("the guard matches pids by substring",
     lambda t: t.replace('grep -qx "$INIT" <<<"$live"', 'grep -q "$INIT" <<<"$live"', 1),
     (("sandbox_up_for_leg returned 0 with INIT='10' pgrep='100'",),)),
    ("leg 9 only logs an empty capture",
     lambda t: t.replace('  || fail "no logcat line in the capture"\n', '  || log "would fail: no logcat line"\n', 1),
     (("sweeps logcat-since-restart.txt for fatal lines without first failing",),)),
    ("leg 9 sweeps without reading the capture first",
     lambda t: t.replace('logcat_capture_read "$EV/logcat-since-restart.txt" \\\n  || fail "no logcat line in the capture"\n', '', 1),
     (("sweeps logcat-since-restart.txt for fatal lines without first failing",),)),
)


PRIMARY_FIXTURE = r'''#!/bin/bash
logcat_capture_read() {
  grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' "$1"
}

PRIMARY_TEARDOWN="MaybeTeardownOnLastAppDisplayClosed: last app display closed -- primary's own surface dropped too"
PRIMARY_CLOSED_RE='WaylandBackend: display 1 xdg_toplevel\.close from compositor'
PRIMARY_APP_CLOSED_RE='WaylandBackend: display ([02-9]|[1-9][0-9]+) xdg_toplevel\.close from compositor'
# print the verdict on the primary close
primary_close_verdict() {
  local before="$1" closed="$2" after="$3" cap="$4" alive
  if ! logcat_capture_read "$cap"; then
    echo "the logcat since the app close holds no line, so nothing shows what closed the primary"
    return 1
  fi
  if [[ "$before" == "?" ]]; then
    echo "the window listing before the app close never completed, so whether a primary was mapped, and which id it had, is unknown"
    return 1
  fi
  if [[ -n "$before" ]] && grep -Fxq -- "$before" "$closed"; then
    echo "the app-close loop closed window $before, the primary rhizo/Rhizo surface"
    return 1
  fi
  if grep -qE -- "$PRIMARY_CLOSED_RE" "$cap"; then
    echo "the compositor closed the primary's own toplevel (composer display 1) during the app close"
    return 1
  fi
  alive=$(python3 -c "
import json, sys
for l in sys.stdin:
    try:
        win = json.loads(l)
    except ValueError:
        continue
    if win.get('app_id') == 'rhizo' and win.get('title') == 'Rhizo':
        print('alive')
        break
" <"$after")
  if [[ "$alive" == alive ]]; then
    echo "primary rhizo/Rhizo surface still mapped after closing app windows"
    return 0
  fi
  if [[ -z "$before" ]]; then
    echo "no primary surface was mapped before the app close (the composer maps it at boot only), so the close could not touch it"
    return 0
  fi
  if grep -qF -- "$PRIMARY_TEARDOWN" "$cap"; then
    if grep -qE -- "$TEST_FATAL_RE" "$cap"; then
      echo "the composer dropped the primary, but the logcat since the app close holds a fatal line: $(grep -m1 -E -- "$TEST_FATAL_RE" "$cap" | cut -c1-200)"
      return 1
    fi
    if ! awk -v re="$PRIMARY_APP_CLOSED_RE" -v td="$PRIMARY_TEARDOWN" '
        $0 ~ re { app = 1 } index($0, td) { exit !app } END { if (!app) exit 1 }' "$cap"; then
      echo "the composer's last-app teardown is not preceded by any app display's close in this run's logcat, so it did not come from the app-close loop"
      return 1
    fi
    echo "the composer dropped the primary with the last app display, and nothing closed it"
    return 0
  fi
  echo "the primary rhizo/Rhizo surface is gone after closing app windows and the composer logged no last-app teardown -- the app-close loop touched more than app_id rhizo-*"
  return 1
}

step "10. close the app windows this system test opened"
  if why=$(primary_close_verdict "$primary_before" "$EV/app-windows-closed.txt" \
      "$EV/app-windows-after.txt" "$EV/logcat-app-close.txt"); then
    pass "$why"
  else
    fail "$why"
  fi
'''

PRIMARY_MUTATIONS = (
    ("any vanished primary counts as the composer's teardown",
     lambda t: t.replace("grep -qF -- \"$PRIMARY_TEARDOWN\" \"$cap\"", "true", 1),
     (("passed 'the primary vanished with no last-app teardown'",),)),
    ("the compositor closing display 1 goes unread",
     lambda t: t.replace("grep -qE -- \"$PRIMARY_CLOSED_RE\" \"$cap\"", "false", 1),
     (("passed 'the compositor closed the primary's toplevel'",),)),
    ("the closed ids go unread",
     lambda t: t.replace("grep -Fxq -- \"$before\" \"$closed\"", "false", 1),
     (("passed 'the loop closed the primary's own window'",),)),
    ("an empty capture is trusted",
     lambda t: t.replace("if ! logcat_capture_read \"$cap\"; then", "if false; then", 1),
     (("passed 'the logcat since the close holds no line'",),)),
    ("a failed window read before the close passes as no primary",
     lambda t: t.replace('if [[ "$before" == "?" ]]; then', 'if false; then', 1),
     (("passed 'the window listing before the close failed'",),)),
    ("a teardown after a crash is trusted",
     lambda t: t.replace('if grep -qE -- "$TEST_FATAL_RE" "$cap"; then', 'if false; then', 1),
     (("passed 'a crash took the displays down before the teardown'",),)),
    ("a teardown no app display's close led to is trusted",
     lambda t: t.replace("$0 ~ re { app = 1 } index($0, td) { exit !app } END { if (!app) exit 1 }", "{ exit 0 }", 1),
     (("passed 'the teardown precedes every app display's close'",),
      ("passed 'the teardown with no app display closed at all'",))),
    ("the function is gone",
     lambda t: t.replace("primary_close_verdict() {", "primary_close_verdict_gone() {", 1),
     (("no primary_close_verdict() in the system test",),)),
    ("leg 10 only logs the refusal",
     lambda t: t.replace('    fail "$why"\n', '    log "$why"\n', 1),
     (("leg 10 (line", "never fails on primary_close_verdict's refusal"),)),
)


def unmet(problems, expected):
    """return the expectations missing from the problems"""
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
    fl = PRIMARY_FIXTURE.split("\n")
    got = primary_close_problems(PRIMARY_FIXTURE, fl, leg_spans(fl))
    if got:
        print(f"SELFTEST FAILED: the fixed leg 10 was refused: {got}", file=sys.stderr)
        failed = True
    for name, edit, expected in PRIMARY_MUTATIONS:
        mutated = edit(PRIMARY_FIXTURE)
        if mutated == PRIMARY_FIXTURE:
            print(f"SELFTEST FAILED: primary mutation '{name}' matched nothing in the leg 10 fixture", file=sys.stderr)
            failed = True
            continue
        ml = mutated.split("\n")
        problems = primary_close_problems(mutated, ml, leg_spans(ml))
        for e in unmet(problems, expected):
            print(f"SELFTEST FAILED: '{name}' was not refused for {e} (got {problems})", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print(f"selftest ok: passes the fixed shape, refuses the pre-fix shape and {len(MUTATIONS)} single regressions")
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    path = argv[1] if len(argv) > 1 else os.path.join(TOOLS, "..", "..", "..", "system", "install", "install.sh")
    with open(path) as f:
        text = f.read()
    lines = text.split("\n")
    problems = check_text(text) + primary_close_problems(text, lines, leg_spans(lines))
    for p in problems:
        print(f"FAIL: {os.path.basename(path)}: {p}")
    if problems:
        return 1
    print("test-install takes hostfs.conf back on exit, runs legs 7-9 only on a live sandbox, "
          "sweeps only a logcat capture that holds a line, and judges the primary by who closed it")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
