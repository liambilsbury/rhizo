#!/usr/bin/env python3

import os
import re
import subprocess
import sys
import tempfile

TOOLS = os.path.dirname(os.path.abspath(__file__))
TEST = os.path.join(TOOLS, "..", "..", "..", "system", "android", "network.sh")
COMMON = os.path.join(TOOLS, "..", "..", "..", "vm", "common.sh")
DEAD = "cannot observe Android"
TEST_FUNCS = ("android_observe", "channel_dead", "poll_never", "expect_android_value",
              "scope_nsenter_markers_to_boot", "settings_dir_mtime", "now_ms", "wait_settings_durable")

PRELUDE = r'''
set -u
FAILED=0 STEP_MARK=0 TEST_STEP=stub EV="$WORK" INIT=1866 RHIZO_VM=1
PORTAL_PROBE=portalprobe.rhizo.test
clock_add() { echo $(( $(cat "$CLOCK") + $1 )) > "$CLOCK"; }
date() {
  case "${1:-}" in
    +%s%N) echo "$(( $(cat "$CLOCK") * 1000000 ))" ;;
    +%s) echo "$(( $(cat "$CLOCK") / 1000 ))" ;;
    *) command date "$@" ;;
  esac
}
sleep() { clock_add "$(awk -v s="$1" 'BEGIN { printf "%d", s * 1000 }')"; }
log() { printf 'LOG %s\n' "$*" >> "$CALLS"; }
fail() { printf 'FAIL %s\n' "${*//$'\n'/ | }" >> "$CALLS"; FAILED=$((FAILED + 1)); }
pass() { :; }
step() { :; }
rename_later() { echo $(( $(cat "$CLOCK") + 200 )) >> "$STATE/renames"; }
settings() {
  [[ "$PROVIDER" == refused ]] && { echo "cmd: Can't find service: settings"; return 255; }
  local f="$STATE/$2.$3"
  case "$1" in
    put) [[ "$PROVIDER" == lost ]] || { printf '%s\n' "$4" > "$f"; rename_later; } ;;
    delete) rm -f "$f"; rename_later ;;
    get) if [[ -f "$f" ]]; then cat "$f"; else echo null; fi ;;
  esac
  return 0
}
device_config() { settings "$1" config "$2.$3" "${4:-}"; }
toybox() {
  local now last=0 t
  now=$(cat "$CLOCK")
  case "$MTIME" in
    denied) echo "stat: '$4': Permission denied"; return 1 ;;
    unrelated) clock_add 1; last=$(cat "$CLOCK") ;;
    renames) [[ -f "$STATE/renames" ]] && while read -r t; do (( t <= now && t > last )) && last=$t; done < "$STATE/renames" ;;
  esac
  printf '2026-09-12 07:%02d:%02d.%03d000000 +0000\n' $(( last / 60000 % 60 )) $(( last / 1000 % 60 )) $(( last % 1000 ))
}
dumpsys() { [[ "${1:-}" == power ]] && echo "  mWakefulness=Awake"; return 0; }
cmd() { :; }
locksettings() { :; }
input() { :; }
wm() { :; }
'''

ANDROID_SH_STUB = r'''
android_sh() {
  printf 'CALL %s %s\n' "$(cat "$CLOCK")" "$2" >> "$CALLS"
  case "$CHANNEL" in
    dead) clock_add 30000; return 0 ;;
    dead97) clock_add 30000; return 97 ;;
    garbage) clock_add 50; echo "runcon: exec /system/bin/sh: Permission denied"; return 0 ;;
    partial98) clock_add 30000; ( eval "$2" ) 2>&1; return 98 ;;
    slow) clock_add 30000 ;;
    *) clock_add 50 ;;
  esac
  ( eval "$2" ) 2>&1
  return 0
}
'''

COMMON_STUBS = r'''
ssh_vm() {
  [[ "${1:-}" == -t ]] && shift 2
  local c="$*" body q="'"
  case "$c" in
    *boot_id*) printf '%s\n' "$BOOT_ID" ;;
    *'"init second_stage"'*) echo 1866 ;;
    *nsenter*)
      printf 'NSENTER %s\n' "$(cat "$CLOCK")" >> "$CALLS"
      [[ "$NSENTER" == alive ]] || { clock_add 30000; return 124; }
      body="${c#*sh -c $q}"; body="${body%$q}"; body="${body#export PATH=*; }"
      clock_add 50
      ( eval "$body" ) 2>&1
      ;;
  esac
}
probe_cmd() { clock_add 30000; return 97; }
getprop_vm() { echo 1; }
getprop_live() { echo 1; }
system_server_pid() { echo 999; }
logcat_since_marker() { :; }
'''


def function_source(text, name):
    """return the source text of a shell function, or None"""
    m = re.search(r"^%s\(\) \{.*?^\}$" % re.escape(name), text, re.S | re.M)
    return m.group(0) if m else None


TEST_VARS = ("ANDROID_RAN_TOKEN", "ANDROID_VALUE", "NSENTER_MARKER_BOOT")


def test_functions(text, names=TEST_FUNCS):
    """return the test variable assignments and the named functions"""
    assigns = [m.group(0) for v in TEST_VARS for m in [re.search(r"^%s=.*$" % v, text, re.M)] if m]
    return "\n".join(assigns + [s for s in (function_source(text, n) for n in names) if s])


def block(text, start_re, end_re):
    """return the lines between a start pattern and an end pattern, or None"""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if re.match(start_re, l)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if re.match(end_re, lines[i])), None)
    return None if end is None else "\n".join(lines[start:end])


def run_stubbed(script, env_extra=None, setup=None):
    """run a script with stubbed commands and return its calls and output"""
    with tempfile.TemporaryDirectory() as work:
        paths = {k: os.path.join(work, k) for k in ("clock", "calls", "state", "tmp")}
        os.mkdir(paths["state"])
        os.mkdir(paths["tmp"])
        with open(paths["clock"], "w") as f:
            f.write("0\n")
        open(paths["calls"], "w").close()
        env = dict(os.environ, WORK=work, CLOCK=paths["clock"], CALLS=paths["calls"], STATE=paths["state"],
                   TMPDIR=paths["tmp"], CHANNEL="alive", PROVIDER="ok", MTIME="renames",
                   NSENTER="alive", BOOT_ID="boot-now")
        env.update(env_extra or {})
        if setup:
            setup(paths["tmp"])
        r = subprocess.run(["bash", "-c", script + "\necho __STUB_DONE__\n"], capture_output=True, text=True,
                           timeout=120, env=env)
        done = r.stdout.endswith("__STUB_DONE__\n")
        stdout = r.stdout[:-len("__STUB_DONE__\n")] if done else r.stdout
        returncode = 0 if done else (r.returncode or 1)
        with open(paths["calls"]) as f:
            calls = f.read().splitlines()
        with open(paths["clock"]) as f:
            clock = int(f.read().strip() or 0)
        left = sorted(os.listdir(paths["tmp"]))
        return returncode, stdout, r.stderr, calls, clock, left


def fails(calls):
    """return the failure messages recorded in the calls"""
    return [c[5:] for c in calls if c.startswith("FAIL ")]


OBSERVE_CASES = (
    ("alive", "settings get global unset_key", 0, "null"),
    ("alive", "printf abc", 0, "abc"),
    ("alive", "true", 0, ""),
    ("alive", "false", 0, ""),
    ("dead", "settings get global unset_key", 97, ""),
    ("dead97", "settings get global unset_key", 97, ""),
    ("garbage", "settings get global unset_key", 97, ""),
    ("partial98", "dumpsys power", 97, ""),
)


def observe_problems(text):
    """check android_observe's answer in each case"""
    if not function_source(text, "android_observe"):
        return ["no android_observe() in the system test"]
    problems = []
    funcs = test_functions(text)
    for channel, command, want_rc, want in OBSERVE_CASES:
        script = (PRELUDE + ANDROID_SH_STUB + funcs +
                  '\nv=$(android_observe 1866 "$CMD"); rc=$?\nprintf "rc=%s\\n%s" "$rc" "$v"\n')
        rc, out, err, _calls, _clock, _left = run_stubbed(script, {"CHANNEL": channel, "CMD": command})
        got_rc, _, got = out.partition("\n")
        case = f"channel={channel} command={command!r}"
        if rc != 0 or not got_rc.startswith("rc="):
            problems.append(f"android_observe did not run with {case}: {err.strip()[:200]}")
        elif int(got_rc[3:]) != want_rc:
            problems.append(f"android_observe returned {got_rc[3:]} with {case}, wanted {want_rc}")
        elif want_rc == 0 and got != want:
            problems.append(f"android_observe printed {got!r} with {case}, wanted {want!r}")
    return problems


MTIME_CASES = (("alive", "frozen", 0), ("dead", "frozen", 97), ("dead97", "frozen", 97), ("alive", "denied", 96))


def mtime_problems(text):
    """check settings_dir_mtime's answer in each case"""
    if not function_source(text, "settings_dir_mtime"):
        return ["no settings_dir_mtime() in the system test"]
    problems = []
    funcs = test_functions(text)
    for channel, model, want in MTIME_CASES:
        script = PRELUDE + ANDROID_SH_STUB + funcs + '\nv=$(settings_dir_mtime 1866 /data/system/users/0); echo "rc=$?"\n'
        rc, out, err, _calls, _clock, _left = run_stubbed(script, {"CHANNEL": channel, "MTIME": model})
        got = re.search(r"rc=(\d+)", out)
        if rc != 0 or not got:
            problems.append(f"settings_dir_mtime did not run with channel={channel} stat={model}: {err.strip()[:200]}")
        elif int(got.group(1)) != want:
            problems.append(f"settings_dir_mtime returned {got.group(1)} with channel={channel} stat={model}, "
                            f"wanted {want}")
    return problems


BASE_MTIME = "2026-09-12 07:00:00.000000000 +0000"
WAIT_CASES = (
    ("a read that never ran", {"CHANNEL": "dead", "MTIME": "frozen"}, 2, 31000, 0, DEAD),
    ("reads that answer after 30s each", {"CHANNEL": "slow", "MTIME": "frozen"}, 1, 41000, 10000, "no rename seen"),
    ("fast reads and no rename", {"CHANNEL": "alive", "MTIME": "frozen"}, 1, 11000, 10000, "no rename seen"),
    ("a rename, then the gap", {"CHANNEL": "alive", "MTIME": "renames"}, 0, 10000, 2500, "07:00:00.200"),
    ("a denied stat", {"CHANNEL": "alive", "MTIME": "denied"}, 2, 31000, 0, "not an mtime"),
)


def wait_problems(text):
    """check wait_settings_durable's answer in each case"""
    if not function_source(text, "wait_settings_durable"):
        return ["no wait_settings_durable() in the system test"]
    problems = []
    funcs = test_functions(text)
    for case, env, want_rc, most_ms, least_ms, carry in WAIT_CASES:
        script = (PRELUDE + ANDROID_SH_STUB + funcs +
                  '\necho 200 > "$STATE/renames"\n'
                  f'm=$(wait_settings_durable "{BASE_MTIME}" 2500 0 10 1 settings_dir_mtime 1866 /data/system/users/0)\n'
                  'rc=$?\nprintf "rc=%s\\n%s" "$rc" "$m"\n')
        rc, out, err, _calls, clock, _left = run_stubbed(script, env)
        got_rc, _, msg = out.partition("\n")
        if rc != 0 or not got_rc.startswith("rc="):
            problems.append(f"wait_settings_durable did not run with {case}: {err.strip()[:200]}")
            continue
        if int(got_rc[3:]) != want_rc:
            problems.append(f"wait_settings_durable returned {got_rc[3:]} with {case}, wanted {want_rc} ({msg[:160]!r})")
        if clock > most_ms:
            problems.append(f"a 10s wait_settings_durable took {clock}ms with {case}, past its deadline plus one read "
                            f"({most_ms}ms)")
        if clock < least_ms:
            problems.append(f"wait_settings_durable gave up after {clock}ms with {case}, before {least_ms}ms")
        if carry not in msg:
            problems.append(f"wait_settings_durable printed {msg[:160]!r} with {case}, which does not carry {carry!r}")
    return problems


VM1 = "rhizo-nsenter-dead.1.1866"
SCOPE_CASES = (
    ((VM1, "rhizo-nsenter-dead.2.1866", "rhizo-nsenter-dead.12.1866"), "boot-old", "boot-now",
     ("rhizo-nsenter-dead.12.1866", "rhizo-nsenter-dead.2.1866"), "boot-now"),
    ((VM1,), "boot-now", "boot-now", (VM1,), "boot-now"),
    ((VM1,), None, "boot-now", (), "boot-now"),
    ((VM1,), "boot-now", "", (), None),
)


def scope_problems(text):
    """check scope_nsenter_markers_to_boot's answer in each case"""
    src = function_source(text, "scope_nsenter_markers_to_boot")
    stamp = re.search(r"^NSENTER_MARKER_BOOT=.*$", text, re.M)
    if not src or not stamp:
        return ["no scope_nsenter_markers_to_boot() and NSENTER_MARKER_BOOT in the system test"]
    problems = []
    for markers, stamped, boot, want_left, want_stamp in SCOPE_CASES:
        def setup(tmp, markers=markers, stamped=stamped):
            """create the marker files and the boot stamp for a case"""
            for m in markers:
                open(os.path.join(tmp, m), "w").close()
            if stamped is not None:
                with open(os.path.join(tmp, "rhizo-nsenter-boot.1"), "w") as f:
                    f.write(stamped + "\n")
        script = (PRELUDE + COMMON_STUBS + stamp.group(0) + "\n" + src +
                  '\nscope_nsenter_markers_to_boot\ncat "$TMPDIR/rhizo-nsenter-boot.1" 2>/dev/null || echo "<none>"\n')
        rc, out, err, _calls, _clock, left = run_stubbed(script, {"BOOT_ID": boot}, setup)
        case = f"markers={list(markers)} stamp={stamped!r} boot_id={boot!r}"
        got_left = tuple(sorted(n for n in left if n.startswith("rhizo-nsenter-dead.")))
        got_stamp = out.strip()
        if rc != 0:
            problems.append(f"scope_nsenter_markers_to_boot did not run with {case}: {err.strip()[:200]}")
            continue
        if got_left != tuple(sorted(want_left)):
            problems.append(f"scope_nsenter_markers_to_boot left {list(got_left)} with {case}, wanted {sorted(want_left)}")
        if got_stamp != (want_stamp or "<none>"):
            problems.append(f"scope_nsenter_markers_to_boot left stamp {got_stamp!r} with {case}, wanted {want_stamp or '<none>'!r}")
    return problems


STEP1B_START = r"^SETTINGS_USERS_DIR="
STEP1B_END = r'^android_sh "\$INIT" "sync"'


def order_after_puts(calls):
    """return the indexes of the last put and the reads that follow it"""
    puts = [i for i, c in enumerate(calls) if c.startswith("CALL ") and "settings put global" in c]
    if not puts:
        return None, None, None
    after = range(puts[-1] + 1, len(calls))
    first_get = next((i for i in after if "settings get global" in calls[i]), None)
    first_stat = next((i for i in after if "toybox stat" in calls[i]), None)
    return puts[-1], first_get, first_stat


def step1b_problems(text):
    """return the problems with the settings write block under stubs"""
    body = block(text, STEP1B_START, STEP1B_END)
    if not body:
        return ['no step 1b settings block (SETTINGS_USERS_DIR= up to android_sh "$INIT" "sync") in the system test']
    problems = []
    script = PRELUDE + ANDROID_SH_STUB + test_functions(text) + "\n" + body + "\n"
    for channel in ("dead", "dead97"):
        rc, _out, err, calls, _clock, _left = run_stubbed(script, {"CHANNEL": channel, "MTIME": "frozen"})
        f = fails(calls)
        case = f"android_sh {'exiting 97' if channel == 'dead97' else 'exiting 0'} with nothing after a 30s timeout"
        if rc != 0:
            problems.append(f"step 1b did not run with {case}: {err.strip()[:200]}")
            continue
        if any("never proved durable" in x for x in f):
            problems.append(f"step 1b with {case} reported a durability failure for writes that never ran: {f}")
        if not any(DEAD in x for x in f):
            problems.append(f"step 1b with {case} never named the dead channel: {f}")
        if len(f) != 1:
            problems.append(f"step 1b with {case} recorded {len(f)} FAIL lines for one dead channel, wanted 1: {f}")
    for provider, model in (("lost", "frozen"), ("refused", "unrelated")):
        rc, _out, err, calls, _clock, _left = run_stubbed(script, {"PROVIDER": provider, "MTIME": model})
        f = fails(calls)
        case = f"a provider that {'drops' if provider == 'lost' else 'refuses'} every put ({model} directory mtime)"
        if rc != 0:
            problems.append(f"step 1b did not run with {case}: {err.strip()[:200]}")
            continue
        last_put, first_get, first_stat = order_after_puts(calls)
        if last_put is None or first_get is None or (first_stat is not None and first_stat < first_get):
            problems.append(f"step 1b with {case} polls the settings directory's mtime before reading the write back, "
                            "so a write that never landed is judged on whether it persisted")
        if any("never proved durable" in x for x in f):
            problems.append(f"step 1b with {case} reported a durability failure for a write that never landed: {f}")
        if not any("did not take" in x for x in f):
            problems.append(f"step 1b with {case} never failed the write as not taken: {f}")
    rc, _out, err, calls, _clock, _left = run_stubbed(script, {"PROVIDER": "ok", "MTIME": "renames"})
    if rc != 0 or fails(calls):
        problems.append(f"step 1b failed writes that landed and persisted: rc={rc} {fails(calls)} {err.strip()[:200]}")
    return problems


STEP0_START = r"""^INIT=\$\(guest_init_pid 10\)"""
STEP0_END = r'^pass "booted, awake, keyguard disabled"'


def step0_problems(text, common_text):
    """return the problems with step zero"""
    body = block(text, STEP0_START, STEP0_END)
    android_sh = function_source(common_text, "android_sh")
    if not body or not android_sh:
        return ["no step 0 body (INIT= up to its pass line) in the system test, or no android_sh() in common.sh"]
    problems = []
    scan = re.search(r"^RHIZO_INIT_SCAN_BODY=.*$", common_text, re.M)
    lookup = [function_source(common_text, f) for f in ("guest_init_pids", "guest_init_pid")]
    if not scan or not all(lookup):
        return ["no RHIZO_INIT_SCAN_BODY, guest_init_pids() or guest_init_pid() in common.sh"]
    script = (PRELUDE + COMMON_STUBS + android_sh + "\n" + scan.group(0) + "\n" + "\n".join(lookup) + "\n"
              + test_functions(text) + "\n" + body + "\n")

    def earlier_boot_marker(tmp):
        """create a dead-channel marker left by an earlier boot"""
        open(os.path.join(tmp, VM1), "w").close()
        with open(os.path.join(tmp, "rhizo-nsenter-boot.1"), "w") as f:
            f.write("boot-old\n")
    rc, _out, err, calls, _clock, _left = run_stubbed(script, {"NSENTER": "alive"}, earlier_boot_marker)
    if rc != 0 or fails(calls):
        problems.append(f"step 0 on a boot whose nsenter answers failed: rc={rc} {fails(calls)} {err.strip()[:200]}")
    rc, _out, err, calls, _clock, _left = run_stubbed(script, {"NSENTER": "timeout"})
    f = fails(calls)
    if rc != 0 or any("is not awake" in x for x in f) or not any(DEAD in x for x in f):
        problems.append("step 0 with nsenter timing out and rhizo-probed unreachable reported "
                        f"{f} (rc={rc}), wanted the dead channel named and no wakefulness verdict")
    return problems


def strip_noise(line):
    """return the line without quoted spans or trailing comment"""
    out, quote, i = [], None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                out.append("  ")
                i += 2
                continue
            if c == quote:
                quote = None
            out.append(" ")
        elif c in "\"'":
            quote = c
            out.append(" ")
        elif c == "#" and (not out or out[-1].isspace()):
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def strip_comment(line):
    """return the line without its trailing comment"""
    quote, i = None, 0
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i]
        i += 1
    return line


def logical_lines(text):
    """return the logical lines with their line numbers"""
    out, buf, start = [], "", None
    for n, raw in enumerate(text.split("\n"), 1):
        code = strip_comment(raw)
        start = start or n
        if code.rstrip().endswith("\\"):
            buf += code.rstrip()[:-1] + " "
            continue
        out.append((start, buf + code))
        buf, start = "", None
    return out


FUNC_RE = re.compile(r"^(\s*)(\w+)\(\) \{(.*)$")


def function_bodies(text):
    """return the line range and body of each function"""
    lines, bodies = text.split("\n"), {}
    for i, l in enumerate(lines):
        m = FUNC_RE.match(l)
        if not m:
            continue
        indent, name, tail = m.groups()
        if strip_comment(tail).rstrip().endswith("}"):
            bodies[name] = (i + 1, i + 1, tail)
            continue
        end = next((j for j in range(i + 1, len(lines)) if lines[j] == indent + "}"), None)
        if end is not None:
            bodies[name] = (i + 1, end + 1, "\n".join(lines[i + 1:end]))
    return bodies


def reader_names(bodies):
    """return the names of the functions that read through android_observe"""
    names = {"android_observe", "wait_settings_durable"}
    grew = True
    while grew:
        grew = False
        for name, (_s, _e, body) in bodies.items():
            if name not in names and re.search(r"\b(?:%s)\b" % "|".join(sorted(names)), body):
                names.add(name)
                grew = True
    return names


SH_CALL = re.compile(r"(?:^|[\s;&|({!]|\$\()(?:\w+=\S*\s+)*android_sh\b")
STDOUT_NULL = re.compile(r"(?:^|[^0-9&>])>\s*/dev/null|&>\s*/dev/null")
EV_FILE = re.compile(r'(?:^|[^0-9&>])>\s*"\$EV/([^"]+)"')
PIPE = re.compile(r"(?<!\|)\|(?!\|)")
WRAPPED_READ = re.compile(r"\$\((?:\w+=\S*\s+)*(logcat_since_marker|wait_device_awake|android_stay_awake)\b")


def bare_read_problems(text):
    """return the problems for bare android_sh reads in the system test"""
    bodies = function_bodies(text)
    observe = bodies.get("android_observe")
    problems = []
    for n, code in logical_lines(text):
        m = SH_CALL.search(code)
        if not m or (observe and observe[0] <= n <= observe[1]):
            continue
        rest = code[m.end():]
        quiet = strip_noise(rest)
        if "$(" not in m.group(0) and not PIPE.search(quiet):
            if STDOUT_NULL.search(quiet):
                continue
            ev = EV_FILE.search(rest)
            if ev and text.count(ev.group(1)) == 1:
                continue
        problems.append(f"line {n} reads Android through a bare android_sh; "
                        f"read through android_observe: {code.strip()[:120]}")
    for n, code in logical_lines(text):
        m = WRAPPED_READ.search(code)
        if m:
            problems.append(f"line {n} reads Android through common.sh's {m.group(1)}; "
                            f"read through android_observe: {code.strip()[:120]}")
    return problems


CAPTURE = re.compile(r"\$\((?:\w+=\S*\s+)*(\w+)\b")


def unconsumed_problems(text):
    """return the problems for reader captures that are never checked"""
    readers = reader_names(function_bodies(text))
    logical = logical_lines(text)
    problems = []
    for k, (n, code) in enumerate(logical):
        for m in CAPTURE.finditer(code):
            if m.group(1) not in readers:
                continue
            after = code[m.end():]
            nxt = next((c for _n, c in logical[k + 1:] if c.strip()), "")
            if re.match(r"\s*local\s", code):
                problems.append(f"line {n} captures {m.group(1)} in a `local` assignment, whose status is local's")
            elif not (re.match(r"\s*(?:if|elif|while|until)\s", code) or "||" in after or "&&" in after
                      or "$?" in after or "$?" in nxt):
                problems.append(f"line {n} captures {m.group(1)} and never consumes its status: {code.strip()[:120]}")
    return problems


INIT_RE = re.compile(r"^\s*INIT=\$\((?:ssh_vm|guest_init_pid)\b")


def scope_call_problems(text):
    """return the problems for INIT lookups that are not scoped to the boot"""
    readers = reader_names(function_bodies(text)) - {"scope_nsenter_markers_to_boot"}
    reach = re.compile(r"\b(?:%s|android_sh|logcat_since_marker)\b" % "|".join(sorted(readers)))
    logical = logical_lines(text)
    problems = []
    for k, (n, code) in enumerate(logical):
        if not INIT_RE.match(code):
            continue
        for n2, code2 in logical[k + 1:]:
            if "scope_nsenter_markers_to_boot" in code2:
                break
            if reach.search(code2):
                problems.append(f"line {n} re-resolves INIT and line {n2} reaches Android before "
                                "scope_nsenter_markers_to_boot")
                break
    return problems


PRECHECK_CASES = (
    ("a connect held until the guest's timeout",
     "RHIZO_NETTEST_RESOLVED ip=10.88.0.2 family=inet\nRHIZO_DIRECT_RC=124", 0, False),
    ("a refused connect",
     "RHIZO_NETTEST_RESOLVED ip=10.88.0.2 family=inet\nRHIZO_NETTEST_FAIL connect errno=113\nRHIZO_DIRECT_RC=1", 0, False),
    ("an origin that answered directly",
     "RHIZO_NETTEST_RESOLVED ip=10.88.0.2 family=inet\nRHIZO_NETTEST_HTTP_STATUS 200\n"
     "RHIZO_NETTEST_BODY RHIZO-NET-OK\nRHIZO_NETTEST_OK\nRHIZO_DIRECT_RC=0", 0, True),
    ("a connection that got a wrong answer",
     "RHIZO_NETTEST_RESOLVED ip=10.88.0.2 family=inet\nRHIZO_NETTEST_FAIL bad-response status=404\nRHIZO_DIRECT_RC=1", 0, True),
    ("no timeout binary", "/system/bin/sh: timeout: inaccessible or not found\nRHIZO_DIRECT_RC=127", 0, True),
    ("no client binary", "timeout: /data/local/tmp/rhizo-nettest: No such file or directory\nRHIZO_DIRECT_RC=127", 0, True),
    ("a dead channel", "", 97, True),
)


def precheck_problems(text):
    """check proxy_origin_direct_check's answer in each case"""
    fn = function_source(text, "proxy_origin_direct_check")
    dead = function_source(text, "channel_dead")
    if fn is None or dead is None:
        return ["network.sh has no proxy_origin_direct_check() or channel_dead()"]
    problems = []
    body = block(text, r'step "13\.', r'step "14\.')
    if body is None or 'proxy_origin_direct_check "$PROXY_ORIGIN"' not in body:
        problems.append("step 13 does not run proxy_origin_direct_check on its origin")
    if not re.search(r'probe="timeout [0-9]+ /data/local/tmp/rhizo-nettest ', fn):
        problems.append("proxy_origin_direct_check runs the direct attempt without a guest-side timeout")
    for name, out, status, must_fail in PRECHECK_CASES:
        script = ("set -u\nINIT=1\nlog() { :; }\nfail() { echo \"FAIL $*\"; }\n"
                  "android_observe() { printf '%%s' \"$OUT\"; return \"$STATUS\"; }\n%s\n%s\n"
                  "proxy_origin_direct_check 10.88.0.2\n" % (dead, fn))
        r = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30,
                           env=dict(os.environ, OUT=out, STATUS=str(status)))
        failed = "FAIL " in r.stdout
        if failed != must_fail:
            problems.append("proxy_origin_direct_check %s for %s: %s"
                            % ("failed" if failed else "passed", name, (r.stdout + r.stderr).strip()[:120]))
    return problems


def check_text(text, common_text):
    """return the problems from every check of the system test text"""
    return (bare_read_problems(text) + unconsumed_problems(text) + scope_call_problems(text)
            + observe_problems(text) + mtime_problems(text) + wait_problems(text) + scope_problems(text)
            + step1b_problems(text) + step0_problems(text, common_text) + precheck_problems(text))


MUTATIONS = (
    ("android_observe takes any output as a reading",
     lambda t: t.replace('[[ "$out" =~ ${ANDROID_RAN_TOKEN}=[0-9]+$ ]] || return 97', '[[ -n "$out" ]] || return 97', 1),
     (("android_observe returned 0 with channel=garbage",),)),
    ("settings_dir_mtime reads through bare android_sh",
     lambda t: t.replace('out=$(android_observe "$init_pid" "toybox stat -c %y $dir") || return 97',
                         'out=$(android_sh "$init_pid" "toybox stat -c %y $dir")', 1),
     (("reads Android through a bare android_sh",), ("settings_dir_mtime returned 96 with channel=dead",))),
    ("step 1b reads the writes back only after the waits",
     lambda t: re.sub(r"(  put_ms=\$\(now_ms\)\n).*?"
                      r'(  await_settings_durable "the captive-portal Settings\.Global write")',
                      r"\1\2", t, count=1, flags=re.S),
     (("polls the settings directory's mtime before reading the write back",),)),
    ("the durability deadline stretches past its bound",
     lambda t: t.replace("end_ms=$(( $(now_ms) + deadline_s * 1000 ))", "end_ms=$(( $(now_ms) + deadline_s * 31000 ))", 1),
     (("past its deadline plus one read",),)),
    ("a failed read counts as no change yet",
     lambda t: t.replace('    if (( rc == 97 )); then\n      printf "cannot observe',
                         '    if (( rc == 997 )); then\n      printf "cannot observe', 1)
                .replace('    elif (( rc != 0 )); then\n      printf "the read',
                         '    elif (( rc == 996 )); then\n      printf "the read', 1),
     (("wait_settings_durable returned", "with a read that never ran"),)),
    ("the portal-probe reboot skips the marker scope",
     lambda t: t.replace('fail "no init second_stage after the portal-probe reboot"\nscope_nsenter_markers_to_boot\n',
                         'fail "no init second_stage after the portal-probe reboot"\n', 1),
     (("re-resolves INIT",),)),
    ("markers survive whatever boot stamped them",
     lambda t: t.replace('[[ -n "$boot_id" && "$stamped" == "$boot_id" ]] && return 0', '[[ -n "$stamped" ]] && return 0', 1),
     (("scope_nsenter_markers_to_boot left ['rhizo-nsenter-dead.1.1866'",),)),
    ("uid_rx reads through bare android_sh",
     lambda t: t.replace('stats=$(android_observe "$INIT" "dumpsys netstats --uid") || return 97',
                         'stats=$(android_sh "$INIT" "dumpsys netstats --uid")', 1),
     (("reads Android through a bare android_sh",),)),
    ("step 0 drops the read's status",
     lambda t: t.replace('if power=$(android_observe "$INIT" "dumpsys power"); then',
                         'power=$(android_observe "$INIT" "dumpsys power")\nif true; then', 1),
     (("never consumes its status",), ("step 0 with nsenter timing out",))),
    ("step 0 takes its logcat start marker from logcat_since_marker again",
     lambda t: re.sub(r'TEST_SINCE=""\nif test_since=\$\(android_observe .*?\nfi\n', 'TEST_SINCE=$(logcat_since_marker "$INIT")\n',
                      t, count=1, flags=re.S),
     (("reads Android through common.sh's logcat_since_marker",),)),
    ("channel_dead stops naming the channel",
     lambda t: t.replace("cannot observe Android: '$1' never ran", "'$1' returned nothing", 1),
     (("never named the dead channel",),)),
    ("the direct pre-check loses its guest-side timeout",
     lambda t: t.replace('probe="timeout 10 /data/local/tmp/rhizo-nettest', 'probe="/data/local/tmp/rhizo-nettest', 1),
     (("without a guest-side timeout",),)),
    ("a direct attempt that never ran counts as refused",
     lambda t: t.replace('    fail "the direct attempt at the proxy-only origin never showed',
                         '    log "the direct attempt at the proxy-only origin never showed', 1),
     (("passed for no timeout binary",), ("passed for no client binary",))),
    ("any exit 1 counts as a refused connect",
     lambda t: t.replace('( "$rc" == 1 && "$out" == *"RHIZO_NETTEST_FAIL connect "* )', '"$rc" == 1', 1),
     (("passed for a connection that got a wrong answer",),)),
)


def unmet(problems, expected):
    """return the expectations that no problem matches"""
    return [e for e in expected if not any(all(s in p for s in e) for p in problems)]


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def selftest():
    """check the live system test and each planted-defect copy"""
    text, common = read(TEST), read(COMMON)
    failed = False
    got = check_text(text, common)
    if got:
        print("SELFTEST FAILED: the live system test was refused:", file=sys.stderr)
        for p in got:
            print(f"    {p}", file=sys.stderr)
        failed = True
    for name, edit, expected in MUTATIONS:
        mutated = edit(text)
        if mutated == text:
            print(f"SELFTEST FAILED: mutation '{name}' matched nothing in network.sh", file=sys.stderr)
            failed = True
            continue
        problems = check_text(mutated, common)
        for e in unmet(problems, expected):
            print(f"SELFTEST FAILED: '{name}' was not refused for {e} (got {problems})", file=sys.stderr)
            failed = True
    if failed:
        return 1
    print(f"selftest ok: passes the live system test and refuses {len(MUTATIONS)} single regressions")
    return 0


def main(argv):
    """run the check or its selftest"""
    if argv[1:2] == ["--selftest"]:
        return selftest()
    path = argv[1] if len(argv) > 1 else TEST
    problems = check_text(read(path), read(COMMON))
    for p in problems:
        print(f"FAIL: {os.path.basename(path)}: {p}")
    if problems:
        return 1
    print("test-network names a dead Android channel instead of judging its empty reads, reads settings back "
          "before waiting on their persist, bounds that wait by wall clock, and scopes nsenter markers to the boot")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
