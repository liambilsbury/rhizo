#!/usr/bin/env python3

import datetime
import os
import re
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.join(TOOLS, "..", "..", "..", "system", "install", "gsi-update.sh")
LIB = os.path.join(TOOLS, "..", "..", "..", "system", "lib", "gsi-update-lib.sh")
TEST_LIB = os.path.join(TOOLS, "..", "..", "..", "system", "lib", "lib.sh")
LEG3_LOGCAT = (
    "09-12 07:10:28.295   256   279 I UserController.UserState: User 0 state changed from BOOTING to RUNNING_LOCKED\n"
    "09-12 07:10:28.297   256   279 E AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: android.display\n"
    "09-12 07:10:28.297   256   279 E AndroidRuntime: java.lang.IllegalStateException: display not ready\n"
    "09-12 07:10:28.308   116   116 F zygote64: jni_internal.cc:824] JNI FatalError called: system_server abort\n"
    "09-12 07:10:28.336   116   116 F zygote64: runtime.cc:714] Runtime aborting...\n"
    "09-12 07:10:28.350   116   116 F libc    : Fatal signal 6 (SIGABRT), code -1 (SI_QUEUE) in tid 116 (system_server)\n"
    "09-12 07:10:28.351   790   790 F DEBUG   : *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n"
    "09-12 07:10:28.359   729   729 E AndroidRuntime: FATAL EXCEPTION: main\n"
    "09-12 07:10:28.383   567   567 E AndroidRuntime: FATAL EXCEPTION: main\n"
    "09-12 07:10:28.390   164   164 I ServiceManager: service 'activity' died\n")
LEG3_FATAL_LINES = 7
LOOP_OFFSETS_S = (0, 4.2, 9.2, 14.2, 19.3)

STEP_RE = re.compile(r'^\s*step "(\d+)\.')
IF_OPEN_RE = re.compile(r"^\s*if\b.*;\s*then\s*$")
ELSE_RE = re.compile(r"^\s*(else\s*$|elif\b)")
FI_RE = re.compile(r"^\s*fi\s*$")
FUNC_RE = re.compile(r"^\w+\(\) \{.*?^\}$", re.S | re.M)
LITERAL_ASSIGN_RE = re.compile(r"^[A-Z][A-Z0-9_]*=(\"[^\"$`]*\"|'[^']*'|[0-9]+)\s*(#.*)?$")
TS_RE = re.compile(r"^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d\d\d)", re.M)
BOOT_PASS_RE = re.compile(r'\bpass\s+".*(reached sys\.boot_completed|sys\.boot_completed=1)')
WAIT_RE = re.compile(r"^\s*if\s+(!\s*)?poll_user0_unlocked\s+\d+\s*;\s*then\s*$")

SUCCESS_AMSTART = "Starting: Intent { cmp=com.rhizo.deskapp/.MainActivity (has extras) }\n"
TOKEN = "09-12 07:10:40.001  2001  2001 I RhizoDeskApp: RHIZO_CLIP_EMPTY\n"
BENIGN_LINE = "09-12 07:10:26.148   160   160 D AudioFlinger: onFirstRef: TimerQueue ready"
BENIGN = ("--------- beginning of main\n" + BENIGN_LINE + "\n"
          "09-12 07:10:26.148   164   164 I libc    : malloc_limit: Allocation limit enabled, max size 1650551180 bytes\n")

AMSTART_ERRORS = (
    ("leg 2's locked user 0 (gsi-update-test-evidence-2/leg2-a17-trial-amstart.log)",
     "Starting: Intent { cmp=com.rhizo.deskapp/.MainActivity (has extras) }\nError type 3\n"
     "Error: Activity class {com.rhizo.deskapp/com.rhizo.deskapp.MainActivity} does not exist.",
     "does not exist"),
    ("leg 3's dead system_server (gsi-update-test-evidence-2/leg3-rollback-amstart.log)",
     "cmd: Can't find service: activity", "Can't find service: activity"),
    ("an unobservable guest (gsi-update-test-evidence-1/leg4-exhaust-rollback-amstart.log)",
     "[05:53:04] probe_up: rhizo-probed NOT reachable within 30s -- probe-based observability unavailable this run\n"
     "[05:53:04] android_sh: nsenter unreachable AND rhizo-probed unreachable -- cannot observe (not necessarily "
     "false): am start -n com.rhizo.deskapp/com.rhizo.deskapp.MainActivity --es cmd clip_read",
     "cannot observe"),
    ("no output at all", "", "am start"),
)

UNLOCK_CASES = (
    ("unlocks on the third read", "RUNNING_LOCKED\nRUNNING_UNLOCKING\nRUNNING_UNLOCKED\n", 0),
    ("already unlocked", "RUNNING_UNLOCKED\n", 0),
    ("stays RUNNING_LOCKED, a17's null-return unlock (leg 2)", "RUNNING_LOCKED\n", 1),
    ("stuck RUNNING_UNLOCKING", "RUNNING_UNLOCKING\n", 1),
    ("system_server dead at every read (legs 3 and 4)", "cmd: Can't find service: activity\n", 1),
    ("user 0 never started", "User is not started: 0\n", 1),
    ("no answer", "\n", 1),
)

CHANGED = "[   15.395361] L3: RHIZO_MARKER data_release_changed=a16-to-a17\n"
RELEASE = "[   15.395642] L3: RHIZO_MARKER data_release=a17\n"
PREDATES = ("[   15.396999] L3: /data predates KeyMint master-key persistence: its wrapping key no longer exists "
            "anywhere, so 1 keystore file(s) it wrapped (persistent.sqlite) were already unusable -- removed; "
            "vpnprofilestore.sqlite and everything else under misc/keystore/ left untouched\n")
REMOVED_17B = "[   15.397170] L3: RHIZO_MARKER keymint_migration=removed-1\n"
REMOVED_HEAD = "[   15.330771] L3: RHIZO_MARKER keymint_migration=removed-1 spblob=removed-1 locksettings_db=removed-2\n"
NOT_NEEDED = "[   13.580420] L3: RHIZO_MARKER keymint_migration=not-needed\n"
COMPLETED = "[   74.588636] RHIZO_MARKER sys.boot_completed=1\n"

KEYMINT_CASES = (
    ("leg 2's trial boot swept at 17b6338d", CHANGED + RELEASE + PREDATES + REMOVED_17B + COMPLETED,
     "fail", "keymint_migration=removed-1"),
    ("the sweep HEAD logs on a second boot", RELEASE + PREDATES + REMOVED_HEAD + COMPLETED,
     "fail", "locksettings_db=removed-2"),
    ("the sweep found nothing to remove", RELEASE + NOT_NEEDED + COMPLETED, "pass", None),
    ("the stamp matched and the sweep stayed silent", CHANGED + RELEASE + COMPLETED, "pass", None),
    ("dmesg came back empty", "", "fail", None),
    ("the ring lost the start of the boot", COMPLETED, "fail", None),
    ("the read stopped before boot completion", RELEASE, "fail", None),
    ("leg 2's read at 8919558f, cut mid-record before the completion marker", CHANGED + RELEASE + COMPLETED[:30],
     "fail", "incomplete dmesg read"),
    ("a whole-looking read from an ssh that exited 255", [(CHANGED + RELEASE + COMPLETED, 255)], "fail", "rc=255"),
    ("the completion marker lands after the first read",
     [(CHANGED + RELEASE, 0), (CHANGED + RELEASE + COMPLETED, 0)], "pass", None),
)

STUBS = r'''
set -uo pipefail
FAILED=0 INIT=100
log() { :; }
skip() { printf 'SKIP %s\n' "$*" >> "$CALLS"; }
pass() { printf 'PASS %s\n' "$*" >> "$CALLS"; }
fail() { printf 'FAIL %s\n' "${*//$'\n'/ | }" >> "$CALLS"; FAILED=$((FAILED + 1)); }
test_scratch_log() { printf '%s/%s.log' "$WORK" "$1"; }
date() { cat "$CLOCK"; }
sleep() { echo $(( $(cat "$CLOCK") + ${1%%.*} )) > "$CLOCK"; }
logcat_vm() {
  shift
  printf 'LOGCAT %s\n' "$*" >> "$CALLS"
  case " $* " in
    *" -c "*) : > "$WORK/.ring-cleared" ;;
    *RhizoDeskApp*) [[ -e "$WORK/.ring-cleared" ]] || cat "$STUB_TOKEN" ;;
    *) cat "$STUB_LOGCAT" ;;
  esac
}
android_sh() {
  printf 'ANDROID_SH %s\n' "$2" >> "$CALLS"
  case "$2" in
    "am start"*) rm -f "$WORK/.ring-cleared"; cat "$STUB_AMSTART" ;;
    "am get-started-user-state"*)
      local n; n=$(cat "$STATE_N"); echo $((n + 1)) > "$STATE_N"
      if (( n < $(wc -l < "$STUB_STATES") )); then sed -n "$((n + 1))p" "$STUB_STATES"; else tail -n 1 "$STUB_STATES"; fi ;;
  esac
}
ssh_vm() {
  [[ "${1:-}" == -t ]] && shift 2
  printf 'SSH_VM %s\n' "$*" >> "$CALLS"
  [[ "$*" == dmesg ]] || return 0
  local n; n=$(cat "$DMESG_N"); echo $((n + 1)) > "$DMESG_N"
  [[ -f "$STUB_DMESG.$n" ]] || n=$(cat "$STUB_DMESG.last")
  cat "$STUB_DMESG.$n"
  return "$(cat "$STUB_DMESG.rc.$n")"
}
'''
STUB_FILES = ("STUB_TOKEN", "STUB_LOGCAT", "STUB_AMSTART", "STUB_STATES")


def read(path):
    """return a file's text, replacing undecodable bytes"""
    with open(path, errors="replace") as f:
        return f.read()


def read_test():
    """return the system test and library text"""
    return read(TEST) + "\n" + read(LIB)


def function_source(text, name):
    """return a shell function's text"""
    m = re.search(r"^%s\(\) \{.*?^\}$" % re.escape(name), text, re.S | re.M)
    return m.group(0) if m else None


def is_code(line):
    """return whether a line is code rather than blank or a comment"""
    s = line.strip()
    return bool(s) and not s.startswith("#")


def leg_spans(lines):
    """return each leg's line range"""
    starts = [(i, m.group(1)) for i, l in enumerate(lines) if (m := STEP_RE.match(l))]
    spans = {}
    for n, (i, leg) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
        spans.setdefault(leg, (i, end))
    return spans


def arm_after(lines, i, end):
    """return the later line indexes of the arm"""
    depth, out = 0, []
    for j in range(i + 1, end):
        l = lines[j]
        if IF_OPEN_RE.match(l):
            depth += 1
        elif FI_RE.match(l):
            if depth == 0:
                break
            depth -= 1
        elif ELSE_RE.match(l) and depth == 0:
            break
        out.append(j)
    return out


def if_statement(lines, i, end):
    """return line indexes of a conditional block"""
    depth, out = 0, []
    for j in range(i + 1, end):
        l = lines[j]
        if IF_OPEN_RE.match(l):
            depth += 1
        elif FI_RE.match(l):
            if depth == 0:
                break
            depth -= 1
        out.append(j)
    return out


def fatal_re_line():
    """return lib.sh's TEST_FATAL_RE assignment line"""
    m = re.search(r"^TEST_FATAL_RE='[^']*'$", read(TEST_LIB), re.M)
    if not m:
        raise SystemExit("FAIL: no TEST_FATAL_RE='...' line in lib.sh")
    return m.group(0)


def test_defs(text):
    """return the literal assignments and functions"""
    literals = [l for l in text.split("\n") if LITERAL_ASSIGN_RE.match(l)]
    return "\n".join(literals) + "\n" + "\n".join(m.group(0) for m in FUNC_RE.finditer(text))


def run(text, call, timeout=60, **stubs):
    """run a shell call under the stubs"""
    with tempfile.TemporaryDirectory() as work:
        env = dict(os.environ, WORK=work, CALLS=os.path.join(work, "calls"),
                   CLOCK=os.path.join(work, "clock"), STATE_N=os.path.join(work, "state_n"))
        seeds = {"calls": "", "clock": "1000", "state_n": "0", "dmesg_n": "0"}
        for name in STUB_FILES:
            env[name] = os.path.join(work, name.lower())
            seeds[name.lower()] = stubs.get(name, "")
        reads = stubs.get("STUB_DMESG", "")
        reads = [(reads, 0)] if isinstance(reads, str) else reads
        env["STUB_DMESG"], env["DMESG_N"] = os.path.join(work, "stub_dmesg"), os.path.join(work, "dmesg_n")
        for n, (content, rc) in enumerate(reads):
            seeds["stub_dmesg.%d" % n], seeds["stub_dmesg.rc.%d" % n] = content, str(rc)
        seeds["stub_dmesg.last"] = str(len(reads) - 1)
        for name, content in seeds.items():
            with open(os.path.join(work, name), "w") as f:
                f.write(content)
        script = STUBS + fatal_re_line() + "\n" + test_defs(text) + "\n" + call + '\necho "rc=$?"\n'
        try:
            r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            return {"rc": None, "out": "", "calls": [], "files": {}, "err": f"did not return within {timeout}s"}
        m = re.search(r"rc=(\d+)\s*$", r.stdout)
        return {"rc": int(m.group(1)) if m else None,
                "out": r.stdout[:m.start()] if m else r.stdout,
                "calls": read(env["CALLS"]).splitlines(),
                "files": {n: read(os.path.join(work, n)) for n in os.listdir(work) if n.endswith(".log")},
                "err": r.stderr.strip()[:300]}


def fails(res):
    """return the FAIL lines a stubbed run recorded"""
    return [c[5:] for c in res["calls"] if c.startswith("FAIL ")]


def passes(res):
    """return the PASS lines a stubbed run recorded"""
    return [c[5:] for c in res["calls"] if c.startswith("PASS ")]


LAUNCH = "assert_deskapp_launches leg2-a17-trial"


def full_logcat_problems(text, lines, spans):
    """list problems in the full logcat capture"""
    if not function_source(text, "assert_deskapp_launches"):
        return ["no assert_deskapp_launches() in the system test"]
    problems = []
    res = run(text, LAUNCH, STUB_AMSTART=SUCCESS_AMSTART, STUB_TOKEN=TOKEN, STUB_LOGCAT=BENIGN)
    if res["rc"] is None:
        return [f"assert_deskapp_launches did not run under the stubs: {res['err']}"]
    if fails(res) or not passes(res):
        problems.append(f"assert_deskapp_launches did not pass a clean launch (fails: {fails(res)})")
    logcats = [c[7:] for c in res["calls"] if c.startswith("LOGCAT ")]
    clear = next((n for n, c in enumerate(logcats) if re.search(r"(^| )-c( |$)", c)), len(logcats))
    before = [c for c in logcats[:clear] if re.search(r"(^| )-d( |$)", c) and "RhizoDeskApp" not in c]
    if not before or BENIGN_LINE not in res["files"].get("leg2-a17-trial-full-logcat.log", ""):
        problems.append("assert_deskapp_launches banks no system logcat as <label>-full-logcat before it clears "
                        "the ring")
    res = run(text, LAUNCH, STUB_AMSTART=SUCCESS_AMSTART, STUB_TOKEN=TOKEN, STUB_LOGCAT="")
    if not any("full-logcat" in f for f in fails(res)):
        problems.append("assert_deskapp_launches records no FAIL naming the full-logcat capture when it holds no "
                        "logcat line")
    for leg in ("2", "3", "4"):
        if leg not in spans:
            problems.append(f"no leg {leg} (step \"{leg}. ...\") in the system test")
            continue
        start, end = spans[leg]
        if not any(is_code(lines[i]) and re.match(r"\s*assert_deskapp_launches\s+\S", lines[i])
                   for i in range(start + 1, end)):
            problems.append(f"leg {leg} no longer calls assert_deskapp_launches")
    if "3" in spans:
        start, end = spans["3"]
        launch = [i for i in range(start + 1, end) if is_code(lines[i])
                  and re.match(r"\s*assert_deskapp_launches\s+\S", lines[i])]
        scans = [i for i in range(start + 1, end) if is_code(lines[i])
                 and "Can't downgrade database" in lines[i] and "grep" in lines[i]]
        guards = [i for i in range(start + 1, end) if is_code(lines[i])
                  and re.match(r"\s*if\s+logcat_capture_read\s+\S+\s*;\s*then\s*$", lines[i])]
        guarded = [s for s in scans if any(g < s and s in if_statement(lines, g, end) for g in guards)]
        if not scans or not launch or not guarded or min(guarded) < launch[0]:
            problems.append("leg 3 does not scan the full-logcat capture assert_deskapp_launches banked for "
                            "downgrades, guarded by logcat_capture_read")
    return problems


def shift_ts(content, secs):
    """return logcat text with every timestamp moved by some seconds"""
    def sub(m):
        """return a matched timestamp moved by the seconds"""
        t = datetime.datetime(2026, *(int(g) for g in m.groups()[:5]), int(m.group(6)) * 1000)
        t += datetime.timedelta(seconds=secs)
        return t.strftime("%m-%d %H:%M:%S.") + "%03d" % (t.microsecond // 1000)
    return TS_RE.sub(sub, content)


def crash_event_problems(text, leg3):
    """list problems in crash event counting"""
    if not function_source(text, "count_crash_events"):
        return ["no count_crash_events() in the system test"]
    loop = "".join(shift_ts(LEG3_LOGCAT, secs) for secs in LOOP_OFFSETS_S)
    loop_aborts = loop.count("*** FATAL EXCEPTION IN SYSTEM PROCESS")
    cases = (
        ("an empty capture", "", 0),
        ("a capture with no fatal line", BENIGN, 0),
        ("leg 3's one system_server abort", leg3, 1),
        (f"the restart loop's {loop_aborts} aborts 4-5 s apart", loop, loop_aborts),
        ("one lone F line", "09-12 07:10:28.308   116   116 F zygote64: runtime.cc:714] abort\n", 1),
        ("one fatal line with no timestamp", "*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n", 1),
        ("leg 3's abort twice, 5 s apart", leg3 + shift_ts(leg3, 5), 2),
        ("leg 3's abort twice, 5 s apart, the later copy first", shift_ts(leg3, 5) + leg3, 2),
    )
    problems = []
    for name, content, want in cases:
        res = run(text, 'echo "events=$(count_crash_events "$STUB_LOGCAT") lines=$(grep -cE "$TEST_FATAL_RE" '
                        '"$STUB_LOGCAT")"', STUB_LOGCAT=content)
        m = re.search(r"events=(\d+) lines=(\d+)", res["out"])
        if not m:
            problems.append(f"count_crash_events did not print a count for {name}: {res['out'][:80]!r} {res['err']}")
            continue
        events, fatal = int(m.group(1)), int(m.group(2))
        if name == "leg 3's one system_server abort" and fatal != LEG3_FATAL_LINES:
            problems.append(f"the leg 3 fixture holds {fatal} TEST_FATAL_RE lines, not {LEG3_FATAL_LINES}")
        if events != want:
            problems.append(f"count_crash_events reads {name} ({fatal} fatal lines) as {events} event(s), wanted {want}")
        if fatal and not events:
            problems.append(f"count_crash_events reads {fatal} fatal line(s) in {name} as no crash")
    res = run(text, LAUNCH, STUB_AMSTART=SUCCESS_AMSTART, STUB_TOKEN=TOKEN, STUB_LOGCAT=leg3)
    if not any(re.search(r"\bcrash_events=1\b", f) for f in fails(res)):
        problems.append("assert_deskapp_launches does not fail leg 3's abort as crash_events=1 "
                        f"(got fails: {[f[-120:] for f in fails(res)]}, passes: {len(passes(res))})")
    return problems


def amstart_problems(text):
    """list problems in am start error handling"""
    problems = []
    for name, output, needle in AMSTART_ERRORS:
        res = run(text, LAUNCH, STUB_AMSTART=output, STUB_TOKEN=TOKEN, STUB_LOGCAT=BENIGN)
        if not any(needle in f for f in fails(res)):
            problems.append(f"assert_deskapp_launches does not fail on am start's output for {name} "
                            f"by quoting {needle!r} (fails: {[f[-120:] for f in fails(res)]})")
    return problems


def unlock_problems(text, lines, spans):
    """list problems in the user 0 unlock wait"""
    problems = []
    if not function_source(text, "poll_user0_unlocked"):
        problems.append("no poll_user0_unlocked() in the system test")
    else:
        for name, states, want in UNLOCK_CASES:
            res = run(text, "poll_user0_unlocked 120", timeout=20, STUB_STATES=states)
            reads = sum(1 for c in res["calls"] if "am get-started-user-state 0" in c)
            if res["rc"] is None:
                problems.append(f"poll_user0_unlocked did not return for {name}: {res['err']}")
                continue
            if (res["rc"] == 0) != (want == 0):
                problems.append(f"poll_user0_unlocked returned {res['rc']} for {name}, wanted {want}")
            if not reads:
                problems.append(f"poll_user0_unlocked never asked `am get-started-user-state 0` for {name}")
    for leg in ("1", "2", "3", "4"):
        if leg not in spans:
            problems.append(f"no leg {leg} (step \"{leg}. ...\") in the system test")
            continue
        start, end = spans[leg]
        boots = [i for i in range(start + 1, end) if is_code(lines[i]) and BOOT_PASS_RE.search(lines[i])]
        if not boots:
            problems.append(f"leg {leg} passes no completed boot")
            continue
        for i in boots:
            waits = [j for j in arm_after(lines, i, end) if WAIT_RE.match(lines[j])]
            if not waits:
                problems.append(f"leg {leg} (line {i + 1}) calls a boot complete on sys.boot_completed alone; "
                                "no `if poll_user0_unlocked N; then` "
                                "follows it")
                continue
            body = if_statement(lines, waits[0], end)
            if not any(is_code(lines[j]) and re.search(r"\bfail\b.*RUNNING_UNLOCKED", lines[j]) for j in body):
                problems.append(f"leg {leg} (line {waits[0] + 1}) waits on user 0's unlock but records no fail "
                                "naming RUNNING_UNLOCKED when it never comes")
    return problems


def keymint_problems(text, lines, spans):
    """list problems in the KeyMint sweep check"""
    problems = []
    if not function_source(text, "assert_no_keymint_sweep"):
        problems.append("no assert_no_keymint_sweep() in the system test")
    else:
        for name, dmesg, want, needle in KEYMINT_CASES:
            res = run(text, "assert_no_keymint_sweep leg2-trial", STUB_DMESG=dmesg)
            got_fail, got_pass = fails(res), passes(res)
            if want == "pass" and (got_fail or not got_pass):
                problems.append(f"assert_no_keymint_sweep did not pass {name} (fails: {got_fail})")
            if want == "fail" and (not got_fail or got_pass):
                problems.append(f"assert_no_keymint_sweep did not fail {name} (passes: {got_pass})")
            if want == "fail" and needle and not any(needle in f for f in got_fail):
                problems.append(f"assert_no_keymint_sweep's FAIL for {name} does not quote {needle!r}: {got_fail}")
    for leg in ("2", "3"):
        if leg not in spans:
            problems.append(f"no leg {leg} (step \"{leg}. ...\") in the system test")
            continue
        start, end = spans[leg]
        if not any(is_code(lines[i]) and re.match(r"\s*assert_no_keymint_sweep\s+\S", lines[i])
                   for i in range(start + 1, end)):
            problems.append(f"leg {leg} never asserts its boot carried no RHIZO_MARKER keymint_migration=removed")
    return problems


FAMILIES = ("logcat", "events", "amstart", "unlock", "keymint")


def check_text(text, leg3=None, families=FAMILIES):
    """return the problems each named check family finds in the system test text"""
    lines = text.split("\n")
    spans = leg_spans(lines)
    leg3 = LEG3_LOGCAT if leg3 is None else leg3
    checks = {
        "logcat": lambda: full_logcat_problems(text, lines, spans),
        "events": lambda: crash_event_problems(text, leg3),
        "amstart": lambda: amstart_problems(text),
        "unlock": lambda: unlock_problems(text, lines, spans),
        "keymint": lambda: keymint_problems(text, lines, spans),
    }
    return [p for family in families for p in checks[family]()]


PRE_FIX_ASSERT = r'''assert_deskapp_launches() {  # assert_deskapp_launches <label>
  local label="$1" out="" tok="" deadline crashes
  android_sh "$INIT" "am force-stop $DESKAPP_PKG" >/dev/null 2>&1
  logcat_vm "$INIT" -c >/dev/null 2>&1
  android_sh "$INIT" "am start -n $DESKAPP_PKG/$DESKAPP_ACT --es cmd clip_read" \
    > "$(test_scratch_log "$label-amstart")" 2>&1
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    out=$(logcat_vm "$INIT" -d -s RhizoDeskApp:I 2>/dev/null | tr -d '\r')
    grep -q "RHIZO_CLIP_" <<<"$out" && { tok=1; break; }
    sleep 2
  done
  echo "$out" > "$(test_scratch_log "$label-logcat")"
  # test-log-window: safe -- logcat_vm "$INIT" -c above cleared the ring
  # right before this launch attempt
  crashes=$(logcat_vm "$INIT" -d -t 4000 2>/dev/null | grep -cE "$TEST_FATAL_RE" || true)
  if [[ -n "$tok" ]] && (( crashes == 0 )); then
    pass "$label: $DESKAPP_PKG launched, logcat shows a real RHIZO_CLIP_ token"
  else
    fail "$label: $DESKAPP_PKG did not confirm launch (token-seen=${tok:-0} crashes=$crashes) -- see $(test_scratch_log "$label-logcat")"
  fi
}'''

POLL_FIXED_SLEEP = r'''poll_user0_unlocked() {  # poll_user0_unlocked <deadline_s>
  sleep "$1"
  USER0_STATE=$(android_sh "$INIT" "am get-started-user-state 0" | tr -d '\r')
  grep -qx RUNNING_UNLOCKED <<<"$USER0_STATE"
}'''

COUNT_LINES = r'''count_crash_events() {  # count_crash_events <logcat file>
  grep -cE "$TEST_FATAL_RE" "$1"
}'''

PRE_FIX_KEYMINT = r'''assert_no_keymint_sweep() {  # assert_no_keymint_sweep <label>
  local label="$1" f swept
  f="$(test_scratch_log "dmesg-$label")"
  if ! boot_dmesg_has "$label" "RHIZO_MARKER data_release=" \
      || ! grep -q "RHIZO_MARKER sys.boot_completed=1" "$f"; then
    fail "$label: this boot's dmesg lacks RHIZO_MARKER data_release= or sys.boot_completed=1, so it cannot show whether the KeyMint sweep ran -- see $f"
    return
  fi
  swept=$(grep -m1 "RHIZO_MARKER keymint_migration=removed" "$f")
  if [[ -n "$swept" ]]; then
    fail "$label: the launcher swept keystore state this /data carried: ${swept#*RHIZO_MARKER }"
  else
    pass "$label: no RHIZO_MARKER keymint_migration=removed on this boot, its /data kept its keystore state"
  fi
}'''

ONE_READ_KEYMINT = r'''assert_no_keymint_sweep() {  # assert_no_keymint_sweep <label>
  local label="$1" f swept
  f="$(test_scratch_log "dmesg-$label")"
  ssh_vm -t 30 'dmesg' > "$f" 2>&1
  swept=$(grep -m1 "RHIZO_MARKER keymint_migration=removed" "$f")
  if [[ -n "$swept" ]]; then
    fail "$label: the launcher swept keystore state this /data carried: ${swept#*RHIZO_MARKER }"
  else
    pass "$label: no RHIZO_MARKER keymint_migration=removed on this boot, its /data kept its keystore state"
  fi
}'''


def swap_function(text, name, body):
    """replace a shell function with another body"""
    src = function_source(text, name)
    return text.replace(src, body, 1) if src else text


MUTATIONS = (
    ("the launch as it was when three legs failed",
     lambda t: swap_function(t, "assert_deskapp_launches", PRE_FIX_ASSERT), ("logcat", "events", "amstart"),
     (("banks no system logcat as <label>-full-logcat",), ("does not fail leg 3's abort as crash_events=1",),
      ("for leg 2's locked user 0",), ("for leg 3's dead system_server",), ("for an unobservable guest",),
      ("for no output at all",))),
    ("the launch banks no full logcat",
     lambda t: t.replace('  capture_full_logcat "$label"\n', "", 1), ("logcat",),
     (("banks no system logcat as <label>-full-logcat",), ("records no FAIL naming the full-logcat capture",))),
    ("an empty full logcat is banked as evidence",
     lambda t: t.replace('  logcat_capture_read "$f" && return 0\n  fail "$1: the system logcat capture holds no '
                         'logcat line -- see $f"\n  return 1\n', "  return 0\n", 1), ("logcat",),
     (("records no FAIL naming the full-logcat capture",),)),
    ("leg 3 scans downgrades in an unread capture",
     lambda t: t.replace('  if logcat_capture_read "$full_logcat"; then\n', "  if true; then\n", 1), ("logcat",),
     (("leg 3 does not scan the full-logcat capture",),)),
    ("the verdict counts fatal lines",
     lambda t: t.replace('  events=$(count_crash_events "$since")\n', '  events=$(grep -cE "$TEST_FATAL_RE" "$since")\n', 1),
     ("events",), (("does not fail leg 3's abort as crash_events=1",),)),
    ("count_crash_events counts lines",
     lambda t: swap_function(t, "count_crash_events", COUNT_LINES), ("events",),
     (("reads leg 3's one system_server abort", f"as {LEG3_FATAL_LINES} event(s), wanted 1"),
      ("the restart loop's", "wanted 5"))),
    ("count_crash_events clusters in line order",
     lambda t: t.replace("    | LC_ALL=C sort -n \\\n", "    | cat \\\n", 1), ("events",),
     (("the later copy first", "as 1 event(s), wanted 2"),)),
    ("an untimed fatal line reads as no crash",
     lambda t: t.replace("END { print (n ? n : untimed) + 0 }", "END { print n + 0 }", 1), ("events",),
     (("one fatal line with no timestamp", "as 0 event(s)"),
      ("reads 1 fatal line(s) in one fatal line with no timestamp as no crash",))),
    ("am start's output is never read",
     lambda t: t.replace('  amerr=$(amstart_error "$amstart")\n', '  amerr=""\n', 1), ("amstart",),
     (("for leg 2's locked user 0",), ("for leg 3's dead system_server",), ("for an unobservable guest",),
      ("for no output at all",))),
    ("am start's error lines are not matched",
     lambda t: t.replace('  err=$(grep -E "^Error|^Warning: Activity not started|Can\'t find service|^Exception '
                         'occurred|cannot observe" "$1")\n', '  err=""\n', 1), ("amstart",),
     (("for leg 2's locked user 0",),)),
    ("an am start that printed nothing passes",
     lambda t: re.sub(r"  \[\[ -z \"\$err\" \]\] && ! grep -q '\^Starting: Intent' \"\$1\" \\\n[^\n]*\n", "", t, count=1),
     ("amstart",), (("for no output at all",),)),
    ("the unlock wait reads once after a fixed sleep",
     lambda t: swap_function(t, "poll_user0_unlocked", POLL_FIXED_SLEEP), ("unlock",),
     (("returned 1 for unlocks on the third read",),)),
    ("the unlock wait takes any running state",
     lambda t: t.replace("grep -qx RUNNING_UNLOCKED <<<", "grep -q RUNNING_ <<<", 1), ("unlock",),
     (("returned 0 for stays RUNNING_LOCKED",), ("returned 0 for stuck RUNNING_UNLOCKING",))),
    ("leg 3 calls its boot complete on sys.boot_completed alone",
     lambda t: re.sub(r"\n( *)if poll_user0_unlocked 120; then\n\1  pass \"the rolled-back \$from_rel boot's user 0.*?\n\1fi\n",
                      "\n", t, count=1, flags=re.S), ("unlock",),
     (("leg 3 (line", "sys.boot_completed alone"),)),
    ("leg 1's unlock wait records no fail",
     lambda t: re.sub(r'      fail "a15 baseline: user 0 never reached RUNNING_UNLOCKED[^\n]*\n',
                      '      log "a15 baseline: user 0 still locked"\n', t, count=1), ("unlock",),
     (("leg 1 (line", "records no fail naming RUNNING_UNLOCKED"),)),
    ("leg 2 never asserts the KeyMint sweep",
     lambda t: t.replace("      assert_no_keymint_sweep ${label_prefix}-trial\n", "", 1), ("keymint",),
     (("leg 2 never asserts its boot carried no RHIZO_MARKER keymint_migration=removed",),)),
    ("leg 3 never asserts the KeyMint sweep",
     lambda t: t.replace("      assert_no_keymint_sweep ${label_prefix}-rollback\n", "", 1), ("keymint",),
     (("leg 3 never asserts its boot carried no RHIZO_MARKER keymint_migration=removed",),)),
    ("absence is read off any dmesg",
     lambda t: swap_function(t, "assert_no_keymint_sweep", ONE_READ_KEYMINT), ("keymint",),
     (("did not fail dmesg came back empty",), ("did not fail the ring lost the start of the boot",),
      ("did not fail the read stopped before boot completion",))),
    ("the sweep check as it was when leg 2's read was cut at 8919558f",
     lambda t: swap_function(t, "assert_no_keymint_sweep", PRE_FIX_KEYMINT), ("keymint",),
     (("FAIL for leg 2's read at 8919558f", "does not quote"),
      ("did not fail a whole-looking read from an ssh that exited 255",),
      ("did not pass the completion marker lands after the first read",))),
    ("a dmesg read's exit status is ignored",
     lambda t: t.replace('  (( rc == 0 )) && [[ "$end" == "whole records" ]]\n', '  [[ "$end" == "whole records" ]]\n', 1),
     ("keymint",), (("did not fail a whole-looking read from an ssh that exited 255",),)),
    ("a dmesg read cut mid-record counts as whole",
     lambda t: t.replace('  [[ -s "$f" && -n "$(tail -c1 "$f")" ]] && end="ends mid-record"\n', "", 1),
     ("keymint",), (("FAIL for leg 2's read at 8919558f", "does not quote"),)),
    ("a sweep marker passes",
     lambda t: t.replace('  if [[ -n "$swept" ]]; then\n', '  if [[ -n "$swept" && -z "$swept" ]]; then\n', 1),
     ("keymint",), (("did not fail leg 2's trial boot swept at 17b6338d",), ("did not fail the sweep HEAD logs",))),
)


def unmet(problems, expected):
    """return the unsatisfied expectations"""
    return [e for e in expected if not any(all(s in p for s in e) for p in problems)]


def selftest(verbose):
    """check the real system test and each mutation"""
    failed = False
    text = read_test()
    got = check_text(text)
    if got:
        print("SELFTEST FAILED: the real gsi-update.sh was refused:", file=sys.stderr)
        for p in got:
            print(f"    {p}", file=sys.stderr)
        failed = True
    for name, edit, families, expected in MUTATIONS:
        mutated = edit(text)
        if mutated == text:
            print(f"SELFTEST FAILED: mutation '{name}' matched nothing in gsi-update.sh", file=sys.stderr)
            failed = True
            continue
        problems = check_text(mutated, families=families)
        for e in unmet(problems, expected):
            print(f"SELFTEST FAILED: '{name}' was not refused for {e} (got {problems})", file=sys.stderr)
            failed = True
        if verbose:
            print(f"refused '{name}': {problems}")
    if failed:
        return 1
    print(f"selftest ok: passes the real system test and refuses {len(MUTATIONS)} single reverts of its five fixes")
    return 0


def main(argv):
    """run the check or its selftest"""
    args = argv[1:]
    if args[:1] == ["--selftest"]:
        return selftest("-v" in args)
    leg3 = None
    if "--leg3-logcat" in args:
        i = args.index("--leg3-logcat")
        leg3 = read(args[i + 1])
        del args[i:i + 2]
    path = args[0] if args else None
    text = read(path) if path else read_test()
    problems = check_text(text, leg3)
    for p in problems:
        print(f"FAIL: {os.path.basename(path) if path else 'gsi-update.sh+gsi-update-lib.sh'}: {p}")
    if problems:
        return 1
    print("test-gsi-update banks each leg's system logcat, counts crash events, fails on am start's error, "
          "holds every completed boot to user 0's RUNNING_UNLOCKED and refuses a KeyMint sweep on legs 2 and 3")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
