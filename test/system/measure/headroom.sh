#!/bin/bash
# test power.cpu_headroom on and off
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-requires: share:rt-load share:rhizo-headroomprobe.apk
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }
source ../lib/install-lib.sh

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
SELFTEST=0
for arg in "$@"; do
  case "$arg" in
    --skip-boot) SKIP_BOOT=1 ;;
    --selftest) SELFTEST=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

export RHIZO_USE_UNIT=1
test_init headroom
SELFTEST_STEPS=()
# record the step name instead of running steps in selftest mode
# shellcheck disable=SC2034
step() { TEST_STEP="$*"; SELFTEST_STEPS+=("$*"); log "=== $*"; }

HEADROOM_IDLE_MIN=80
HEADROOM_HALF_LO=40
HEADROOM_HALF_HI=60
HEADROOM_ALL_MAX=15
HEADROOM_MIN_SAMPLES=20
SAMPLE_S=360
SAMPLE_MORE_S=120
SAMPLE_MORE_RUNS=3
SAMPLE_LOAD_S=45
SETTLE_S=5
ADV_SLACK_S=10
PROBE_WINDOW_MS=1000
PROBE_TYPE=average

POLICY_CONF=/etc/rhizo/policy.conf
POLICY_SAVED=/etc/rhizo/policy.conf.headroom-test
POLICY_SNAPSHOT=0
RT_LOAD_STAGED=0
PROBE_INSTALLED=0
ADV_ON=0
SOCK_DIR=/dev/socket/rhizo_headroom
PROBE_PKG=org.rhizo.headroomprobe
PROBE_ACT=$PROBE_PKG/.Probe
PROBE_APK=$VAR_DIR/share/rhizo-headroomprobe.apk
PROBE_DIR=/sdcard/Android/media/$PROBE_PKG
ADB=~/Android/Sdk/platform-tools/adb

MORE_TAGS=()
for (( r = 2; r <= SAMPLE_MORE_RUNS + 1; r++ )); do MORE_TAGS+=("quiet-$r" "rtquiet-$r"); done
for t in A quiet half all rtall rtquiet G "${MORE_TAGS[@]}"; do
  for f in "$t-probe.txt" "$t-logcat.txt" "$t-dumpsys.txt" "$t-am-start.txt" "$t-android-tids.txt" "$t-stats.txt"; do
    echo "<none: leg for $t not reached>" >"$EV/$f"
  done
done
for f in rt-load-host-pids.txt rt-load-adv.txt socket-dir.txt d-report.txt b-report.txt c-report.txt e-report.txt \
         logcat-all.txt kmsg-since-start.txt avc-feature.txt A-off-state.txt G-off-state.txt install.txt on-state.txt; do
  echo "<none: not reached>" >"$EV/$f"
done

# restore policy.conf and stop rt-load
restore_policy_conf() {
  local got
  (( TEST_NO_VM )) && return 0
  if (( PROBE_INSTALLED )); then
    ANDROID_SH_TIMEOUT=60 android_sh "$(guest_init_pid 10)" "am force-stop $PROBE_PKG; pm uninstall $PROBE_PKG" >"$EV/uninstall.txt" 2>&1
  fi
  (( POLICY_SNAPSHOT )) || return 0
  got=$(ssh_vm -t 40 "pkill -x rt-load 2>/dev/null
    if [ -e $POLICY_SAVED ]; then mv -f $POLICY_SAVED $POLICY_CONF; else rm -f $POLICY_CONF; fi
    systemctl stop rhizo-headroomd.service rhizo-delayd.service rhizo-rtd.service
    if [ $RT_LOAD_STAGED = 1 ]; then rm -f /usr/local/bin/rt-load /root/rt-load-adv-*.txt; fi
    echo conf=\$(test -e $POLICY_CONF && echo present || echo absent) saved=\$(test -e $POLICY_SAVED && echo present || echo absent) \
headroomd=\$(systemctl is-active rhizo-headroomd.service) load=\$(pgrep -cx rt-load)" 2>&1 | tr -d '\r' | tr '\n' ' ')
  case "$got" in
    *"saved=absent"*"headroomd=inactive"*"load=0"*) log "CLEANUP_OK: policy.conf restored, rhizo-headroomd stopped, no rt-load ($got)" ;;
    *) log "CLEANUP_INCOMPLETE: policy.conf, rhizo-headroomd or rt-load ($got)" ;;
  esac
}
# shellcheck disable=SC2034
TEST_EXTRA_CLEANUP=restore_policy_conf

# print the received or the selftest value
seen() { if (( SELFTEST )); then echo "$2"; else echo "$1"; fi; }

# compare two floats with an operator
num_cmp() {
  python3 -c '
import operator, sys
ops = {"ge": operator.ge, "le": operator.le, "gt": operator.gt, "lt": operator.lt}
try:
    a, b = float(sys.argv[1]), float(sys.argv[3])
except ValueError:
    sys.exit(1)
sys.exit(0 if ops[sys.argv[2]](a, b) else 1)' "$1" "$2" "$3"
}

# print a key's value from a line
field() {
  grep -o -E "(^| )$2=[^ ]*" <<<"$1" | head -1 | sed 's/^ //; s/^[^=]*=//'
}

# summarize the java samples of a level's runs
hr_stats() {
  python3 - "$@" <<'PY'
import re, statistics, sys
t_from, paths = int(sys.argv[1]), sys.argv[2:]
pat = re.compile(r"^RHIZO_HEADROOM api=java t_ns=(\d+) type=(\w+) window=(\d+) value=(\S+)$")
n = nan = err = unsup = 0
vals = []
for path in paths:
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        continue
    for line in lines:
        m = pat.match(line.rstrip("\r"))
        if not m or int(m.group(1)) < t_from:
            continue
        n += 1
        v = m.group(4)
        if v == "NaN":
            nan += 1
        elif v == "unsupported":
            unsup += 1
        elif v.startswith("error:"):
            err += 1
        else:
            vals.append(float(v))
med = "%.2f" % statistics.median(vals) if vals else "none"
print("n=%d ok=%d nan=%d err=%d unsup=%d median=%s min=%s max=%s runs=%d" % (
    n, len(vals), nan, err, unsup, med,
    "%.2f" % min(vals) if vals else "none", "%.2f" % max(vals) if vals else "none", len(paths)))
PY
}

# print the guest CPU ticks and rhizo-headroomd request counts
guest_counts() {
  ssh_vm -t 15 "echo hz=\$(getconf CLK_TCK) \$(awk '/^cpu / { print \"ticks=\" \$2 + \$3; exit }' /proc/stat) \$(sed -n 's/.*\"requests\":\([0-9]*\).*/requests=\1/p' /run/rhizo-headroomd/status.json 2>/dev/null)" | tr -d '\r'
}

# print how far the guest counts grew between two reads
counts_grown() {
  local hz t0 t1 q0 q1 ms=unknown req=unknown
  hz=$(field "$2" hz); t0=$(field "$1" ticks); t1=$(field "$2" ticks); q0=$(field "$1" requests); q1=$(field "$2" requests)
  [[ "$hz" =~ ^[1-9][0-9]*$ && "$t0" =~ ^[0-9]+$ && "$t1" =~ ^[0-9]+$ ]] && ms=$(( (t1 - t0) * 1000 / hz ))
  [[ "$q0" =~ ^[0-9]+$ && "$q1" =~ ^[0-9]+$ ]] && req=$(( q1 - q0 ))
  echo "user_nice_ms=$ms hal_requests=$req"
}

# print what answered the NaN java samples
nan_reason() {
  local q m
  q=$(field "$1" hal_requests); m=$(field "$1" user_nice_ms)
  echo "rhizo-headroomd served ${q:-unknown} requests while the guest's user and nice time grew ${m:-unknown} ms; HintManagerService answers an ordinary app NaN without asking the HAL until that time grows 100 ms past the app's last answer"
}

# count host pids found in the files
hr_collisions() {
  python3 - "$@" <<'PY'
import re, sys
host = {int(l) for l in open(sys.argv[1]) if l.strip().isdigit()}
snap = {int(x) for l in open(sys.argv[2]) for x in l.split() if x.isdigit()}
tok = re.compile(r"(?<![\d.])\d+(?![\d.])")
seen = set()
for path in sys.argv[3:]:
    seen |= {int(t) for t in tok.findall(open(path, errors="replace").read())}
print(len((seen & host) - snap))
PY
}

TEST_RUN_ID="$(date +%s).$$"
# write a numbered mark line to the guest kernel log
kmsg_mark() { ssh_vm -t 10 "echo 'headroom-test mark $1/$TEST_RUN_ID.' > /dev/kmsg"; }
# print the guest kernel log after a mark
dmesg_after() {
  ssh_vm -t 20 "dmesg | awk -v m='headroom-test mark $1/$TEST_RUN_ID.' 'f; index(\$0, m) { f = 1 } END { if (!f) print \"NO_MARK\" }'; echo KMSG_END" | tr -d '\r'
}

boottime_ns_cmd="python3 -c 'import time; print(\"BT=%d\" % time.clock_gettime_ns(time.CLOCK_BOOTTIME))'"
# start rt-load on the given vCPUs
adversary_start() {
  local out k="$1"
  out=$(ssh_vm -t 60 "for c in \$(seq 0 $(( k - 1 ))); do
      setsid taskset -c \$c /usr/local/bin/rt-load \$c 1000 990 3600 99 >/root/rt-load-adv-\$c.txt 2>&1 </dev/null & disown
    done
    $boottime_ns_cmd
    sleep 0.5
    echo PIDS=\$(ps -eLo tid=,comm= | awk '\$2==\"rt-load\"{print \$1}' | tr '\n' ' ')" | tr -d '\r')
  ADV_T0=$(sed -n 's/^BT=\([0-9]*\)$/\1/p' <<<"$out")
  sed -n 's/^PIDS=//p' <<<"$out" | tr ' ' '\n' | grep -E '^[0-9]+$' >>"$EV/rt-load-host-pids.txt"
  ADV_ON=1
  [[ "$ADV_T0" =~ ^[0-9]+$ ]] || { fail "no BOOTTIME stamp after starting rt-load: $out"; return 1; }
  [[ -n "$(sed -n 's/^PIDS=//p' <<<"$out")" ]] || { fail "no rt-load process after starting it: $out"; return 1; }
}

# stop rt-load on the guest
adversary_stop() {
  local out
  out=$(ssh_vm -t 60 "$boottime_ns_cmd
    echo PIDS=\$(ps -eLo tid=,comm= | awk '\$2==\"rt-load\"{print \$1}' | tr '\n' ' ')
    pkill -x rt-load; sleep 0.3; echo LEFT=\$(pgrep -cx rt-load)" | tr -d '\r')
  ADV_T1=$(sed -n 's/^BT=\([0-9]*\)$/\1/p' <<<"$out")
  sed -n 's/^PIDS=//p' <<<"$out" | tr ' ' '\n' | grep -E '^[0-9]+$' >>"$EV/rt-load-host-pids.txt"
  sort -un "$EV/rt-load-host-pids.txt" -o "$EV/rt-load-host-pids.txt"
  ADV_ON=0
  [[ "$ADV_T1" =~ ^[0-9]+$ ]] || { fail "no BOOTTIME stamp before stopping rt-load: $out"; return 1; }
  grep -qx 'LEFT=0' <<<"$out" || { fail "rt-load still runs after pkill: $out"; return 1; }
}

# record Android's pid and tid list
snap_android_tids() {
  ANDROID_SH_TIMEOUT=120 android_sh "$INIT" "for t in /proc/[0-9]*/task/*; do p=\${t#/proc/}; echo \${p%%/*} \${t##*/}; done" \
    | tr -d '\r' | grep -E '^[0-9]+ [0-9]+$' >>"$EV/$1-android-tids.txt"
}

# start the probe app on the guest
probe_start() {
  local tag="$1" out
  ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "am force-stop $PROBE_PKG; rm -f $PROBE_DIR/$tag.txt" >"$EV/$tag-am-start.txt" 2>&1 \
    || { fail "could not stop the probe and clear $PROBE_DIR/$tag.txt ($EV/$tag-am-start.txt)"; return 1; }
  PROBE_MARK=$(logcat_since_marker "$INIT")
  out=$(ANDROID_SH_TIMEOUT=180 android_sh "$INIT" "am start -W -n $PROBE_ACT --ei duration_s $2 --es type $PROBE_TYPE --ei window_ms $PROBE_WINDOW_MS --es out $tag.txt" | tr -d '\r')
  printf '%s\n' "$out" >"$EV/$tag-am-start.txt"
  grep -q '^Status: ok' <<<"$out" || { fail "am start -W of the probe did not report Status: ok ($EV/$tag-am-start.txt)"; return 1; }
}

# read the probe's file into POLL_READ
probe_read_done() {
  POLL_READ=$(ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "cat $PROBE_DIR/$1.txt" | tr -d '\r')
  grep -q '^RHIZO_HEADROOM_DONE ' <<<"$POLL_READ"
}

# save the probe file and logcat lines
probe_finish() {
  local tag="$1"
  poll_until $(( $2 + 120 )) 3 probe_read_done "$tag"
  local rc=$?
  printf '%s\n' "${POLL_READ:-<empty read>}" >"$EV/$tag-probe.txt"
  logcat_vm "$INIT" -d -s RhizoHeadroom:I -t "$PROBE_MARK" | tr -d '\r' >"$EV/$tag-logcat.txt"
  (( rc == 0 )) || { fail "the probe's $tag run wrote no RHIZO_HEADROOM_DONE within $(( $2 + 120 )) s ($EV/$tag-probe.txt)"; return 1; }
}

# force-stop the probe package
probe_stop() { ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "am force-stop $PROBE_PKG" >/dev/null 2>&1; }

# save dumpsys performance_hint to a file
dump_hint() {
  ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "dumpsys performance_hint" | tr -d '\r' >"$EV/$1-dumpsys.txt"
}

# run the probe again with no load
run_more() {
  local tag="$1" r=1 rc=0 files=("$EV/$1-probe.txt")
  while (( $(field "$RL_STATS" ok) < HEADROOM_MIN_SAMPLES && r <= SAMPLE_MORE_RUNS )); do
    r=$(( r + 1 ))
    log "    $(field "$RL_STATS" ok) non-NaN java samples, under $HEADROOM_MIN_SAMPLES: probe run $r of at most $(( SAMPLE_MORE_RUNS + 1 )), $SAMPLE_MORE_S s"
    probe_start "$tag-$r" "$SAMPLE_MORE_S" && probe_finish "$tag-$r" "$SAMPLE_MORE_S"
    rc=$?
    probe_stop
    RL_TAGS+=("$tag-$r"); files+=("$EV/$tag-$r-probe.txt")
    RL_STATS=$(hr_stats 0 "${files[@]}")
    (( rc == 0 )) || return 1
  done
}

# run the probe with rt-load on k vCPUs
run_level() {
  local tag="$1" k="$2" dur from=0 ok=1 before
  dur=$(( (k > 0 ? SAMPLE_LOAD_S : SAMPLE_S) + SETTLE_S + ADV_SLACK_S ))
  RL_STATS="n=0 ok=0 nan=0 err=0 unsup=0 median=none min=none max=none runs=0"
  RL_TAGS=("$tag")
  ADV_T0=""
  : >"$EV/$tag-android-tids.txt"
  before=$(guest_counts)
  probe_start "$tag" "$dur" || { probe_stop; return 1; }
  if (( k > 0 )); then
    adversary_start "$k" || ok=0
    (( ok )) && snap_android_tids "$tag"
    from=$(( ${ADV_T0:-0} + SETTLE_S * 1000000000 ))
  fi
  (( ok )) && { probe_finish "$tag" "$dur" || ok=0; }
  if (( ok && k > 0 )); then snap_android_tids "$tag"; fi
  (( ok )) && dump_hint "$tag"
  (( ADV_ON )) && adversary_stop
  probe_stop
  (( ok )) || return 1
  RL_STATS=$(hr_stats "$from" "$EV/$tag-probe.txt")
  (( k == 0 )) && run_more "$tag"
  RL_STATS="$RL_STATS $(counts_grown "$before" "$(guest_counts)")"
  printf 'k=%s from_ns=%s %s\n' "$k" "$from" "$RL_STATS" >"$EV/$tag-stats.txt"
}

# count the off-state lines in a probe file
probe_off_counts() {
  local f="$EV/$1-probe.txt"
  echo "$(grep -c '^RHIZO_HEADROOM_INFO supported=0$' "$f") $(grep -c -E '^RHIZO_HEADROOM api=java .* value=unsupported$' "$f") $(grep -c -E '^RHIZO_HEADROOM api=ndk .* rc=[0-9]+ value=unsupported$' "$f") $(grep -c -E '^RHIZO_HEADROOM_DONE samples=1 nan=0$' "$f")"
}

# count java samples in the probe files and the logcat files of runs
probe_logcat_agrees() {
  local t a b n=0 l=0
  for t in "$@"; do
    a=$(grep -c '^RHIZO_HEADROOM api=java ' "$EV/$t-probe.txt" 2>/dev/null)
    b=$(grep -c 'RHIZO_HEADROOM api=java ' "$EV/$t-logcat.txt" 2>/dev/null)
    n=$(( n + ${a:-0} )); l=$(( l + ${b:-0} ))
  done
  echo "$n $l"
}

# restart the units and the stack
restart_under_policy() {
  local tag="$1"; shift
  local u
  for u in "$@"; do
    ssh_vm -t 30 "systemctl restart $u" >"$EV/$tag-$u-restart.txt" 2>&1 || { fail "$u did not start ($EV/$tag-$u-restart.txt)"; return 1; }
  done
  test_publish_session_env || { fail "could not publish the desktop session env"; return 1; }
  test_restart_stack "$EV/$tag-restart.log" || { fail "the stack did not come back ($EV/$tag-restart.log)"; return 1; }
  INIT=$(guest_init_pid 10)
  wait_device_awake "$INIT" 20 >/dev/null
  android_stay_awake "$INIT" >/dev/null
}

# check the capability off posture
assert_off_posture() {
  local label="$1" mark="$2" v state d1 d2 sock hproc kl hal lsw c dump
  v=$(seen "$(ssh_vm -t 15 "echo \$(systemctl is-active rhizo-headroomd.service) \$(test -e /run/rhizo-headroom && echo present || echo absent) \
\$(test -e /run/rhizo-headroomd && echo present || echo absent) \$(test -e /proc/$INIT/root$SOCK_DIR && echo present || echo absent) \
\$(pgrep -cx rhizo-headroomd)" | tr -d '\r')" "active present present present 1")
  read -r state d1 d2 sock hproc <<<"$v"
  [[ "$state" != active && "$state" != "" && "$d1" == absent && "$d2" == absent && "$sock" == absent && "$hproc" == 0 ]] \
    && pass "$label: rhizo-headroomd $state, no /run/rhizo-headroom, no /run/rhizo-headroomd, no $SOCK_DIR in the sandbox, no rhizo-headroomd process on the host" \
    || fail "$label: off left something: unit '$state', /run/rhizo-headroom $d1, /run/rhizo-headroomd $d2, sandbox socket dir $sock, host processes $hproc"
  printf '%s\n' "$v" >"$EV/$label-off-state.txt"
  if [[ -n "$mark" ]]; then kl=$(dmesg_after "$mark"); else kl=$(ssh_vm -t 20 "dmesg; echo KMSG_END" | tr -d '\r'); fi
  grep -qx KMSG_END <<<"$kl" || fail "$label: the kernel log could not be read whole"
  hal=$(grep -a -o 'RHIZO_MARKER power_headroom=[a-z]* reason=[a-z]*' <<<"$kl" | tail -1)
  lsw=$(grep -a -o 'RHIZO_MARKER headroom_socket=[a-z]*' <<<"$kl" | tail -1)
  v=$(seen "$hal" "RHIZO_MARKER power_headroom=on reason=none")
  [[ "$v" == "RHIZO_MARKER power_headroom=off reason=absent" ]] && pass "$label: the power HAL marked power_headroom=off reason=absent" \
    || fail "$label: the power HAL's last headroom marker is '$v'"
  v=$(seen "$lsw" "RHIZO_MARKER headroom_socket=bound")
  [[ "$v" == "RHIZO_MARKER headroom_socket=withheld" ]] && pass "$label: the launcher marked headroom_socket=withheld" \
    || fail "$label: the launcher's last headroom_socket marker is '$v'"
  probe_start "$label" 0 && probe_finish "$label" 0
  probe_stop
  c=$(seen "$(probe_off_counts "$label")" "0 0 0 0")
  [[ "$c" == "1 1 1 1" ]] && pass "$label: the probe reports supported=0, java value=unsupported, ndk value=unsupported, one sample" \
    || fail "$label: probe counts (info java ndk done) '$c', want '1 1 1 1' ($EV/$label-probe.txt)"
  c=$(seen "$(probe_logcat_agrees "$label")" "1 0")
  [[ "$c" =~ ^([0-9]+)\ ([0-9]+)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" && "${BASH_REMATCH[1]}" -gt 0 ]] \
    && pass "$label: the probe's file and its logcat tag both hold the java sample" \
    || fail "$label: java samples in the file and in logcat '$c' ($EV/$label-probe.txt, $EV/$label-logcat.txt)"
  dump_hint "$label"
  dump=$(cat "$EV/$label-dumpsys.txt")
  v=$(seen "$(grep -c '^CPU Headroom Supported: false$' <<<"$dump")" 0)
  c=$(grep -c '^Hint Session Support: ' <<<"$dump")
  [[ "$v" == 1 && "$c" == 1 ]] && pass "$label: dumpsys performance_hint says 'CPU Headroom Supported: false' (control: its Hint Session Support line)" \
    || fail "$label: dumpsys performance_hint: 'Supported: false' lines $v, Hint Session lines $c ($EV/$label-dumpsys.txt)"
  v=$(seen "$(grep -c '^CPU Headroom Interval: ' <<<"$dump")" 1)
  [[ "$v" == 0 ]] && pass "$label: dumpsys performance_hint prints no headroom interval" || fail "$label: dumpsys prints a headroom interval ($v lines)"
}

# check the on-state performance_hint dump
assert_on_dump() {
  local v
  v=$(seen "$(grep -c '^CPU Headroom Supported: true$' "$2")" 0)
  [[ "$v" == 1 ]] && pass "$1: dumpsys performance_hint says 'CPU Headroom Supported: true'" \
    || fail "$1: dumpsys performance_hint: 'Supported: true' lines '$v' ($2)"
  v=$(seen "$(grep -c -x -e 'CPU Headroom Interval: 100' -e 'CPU Headroom Calculation Window Range: \[100, 10000\]' "$2")" 0)
  [[ "$v" == 2 ]] && pass "$1: the HAL's interval (100 ms) and window range ([100, 10000] ms) reach the framework" \
    || fail "$1: interval and window range lines '$v' of 2 ($2)"
}

# check the probe's on-state samples over a level's runs
assert_sampling() {
  local label="$1" stats="$2" ok err info=0 ndk=0 runs t a b v
  shift 2
  ok=$(field "$stats" ok); err=$(field "$stats" err); runs=$#
  for t in "$@"; do
    a=$(grep -c -x 'RHIZO_HEADROOM_INFO supported=1 min_interval_ms=100 window_min=100 window_max=10000' "$EV/$t-probe.txt" 2>/dev/null)
    b=$(grep -c -E '^RHIZO_HEADROOM api=ndk .* rc=0 value=(NaN|[0-9.]+)$' "$EV/$t-probe.txt" 2>/dev/null)
    info=$(( info + ${a:-0} )); ndk=$(( ndk + ${b:-0} ))
  done
  v=$(seen "$info" 0)
  [[ "$v" == "$runs" ]] && pass "$label: each of the $runs probe run(s) has its info line saying supported=1, interval 100 ms, window [100, 10000]" \
    || fail "$label: $v probe info line(s) for $runs run(s) ($EV/$1-probe.txt)"
  v=$(seen "$ndk" 0)
  [[ "$v" == "$runs" ]] && pass "$label: each probe run's NDK sample returned rc=0 and a value or NaN" \
    || fail "$label: $v NDK sample line(s) with rc=0 for $runs run(s) ($EV/$1-probe.txt)"
  v=$(seen "$err" 3)
  [[ "$v" == 0 ]] && pass "$label: no java sample reported error:<exception>" || fail "$label: $v java sample(s) reported error:<exception> ($EV/$1-probe.txt)"
  v=$(seen "$ok" 0)
  num_cmp "$v" ge "$HEADROOM_MIN_SAMPLES" \
    && pass "$label: $v non-NaN java samples in $runs probe run(s) (>= $HEADROOM_MIN_SAMPLES; $(field "$stats" nan) NaN: $(nan_reason "$stats"))" \
    || fail "$label: $v non-NaN java samples in $runs probe run(s), want at least $HEADROOM_MIN_SAMPLES ($(field "$stats" nan) NaN: $(nan_reason "$stats"); $EV/$1-stats.txt)"
}

test_require_staged rt-load rhizo-headroomprobe.apk || exit 1
if (( SKIP_BOOT == 0 )); then
  step "0. boot the guest, the desktop session and the stack with power.cpu_headroom at its default"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up >"$EV/sway.log" 2>&1 || { fail "the desktop session did not start (see $EV/sway.log)"; exit 1; }
  ../../vm/sync.sh >"$EV/sync.log" 2>&1 || { fail "sync.sh failed (see $EV/sync.log)"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 240 >"$EV/redeploy.log" 2>&1 \
    || { fail "redeploy.sh failed (see $EV/redeploy.log)"; exit 1; }
fi
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
wait_device_awake "$INIT" 20 >/dev/null
android_stay_awake "$INIT" >/dev/null
kmsg_mark start || { fail "could not write a mark into the kernel log"; exit 1; }
ssh_vm -t 15 "rm -f $POLICY_SAVED; if [ -e $POLICY_CONF ]; then cp -a $POLICY_CONF $POLICY_SAVED; fi" \
  || { fail "could not snapshot $POLICY_CONF"; exit 1; }
POLICY_SNAPSHOT=1
ssh_vm -t 15 "awk '/^\[/ { s = \$0 } s == \"[power]\" && /^[ \t]*cpu_headroom[ \t]*=/ { f = 1 } END { exit !f }' $POLICY_CONF 2>/dev/null" \
  && { fail "$POLICY_CONF already sets [power] cpu_headroom; the off leg needs the default"; exit 1; }
NPROC=$(ssh_vm -t 10 "nproc" | tr -d '\r')
[[ "$NPROC" =~ ^[1-9][0-9]*$ ]] || { fail "could not read the guest's CPU count ('$NPROC')"; exit 1; }
(( NPROC >= 2 )) || { fail "the half-held level needs at least 2 vCPUs, the guest has $NPROC"; exit 1; }
HALF=$(( NPROC / 2 ))
ssh_vm -t 20 "cat > /usr/local/bin/rt-load && chmod 755 /usr/local/bin/rt-load" <../../../var/share/rt-load \
  || { fail "could not stage rt-load"; exit 1; }
RT_LOAD_STAGED=1
: >"$EV/rt-load-host-pids.txt"
../../vm/boot/adb-tunnel.sh up >"$EV/adb-tunnel.log" 2>&1 || { fail "adb-tunnel.sh up failed (see $EV/adb-tunnel.log)"; exit 1; }
timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$PROBE_APK" /data/local/tmp/rhizo-headroomprobe.apk >"$EV/install.txt" 2>&1 \
  || { fail "adb push of the probe failed ($EV/install.txt)"; exit 1; }
PROBE_INSTALLED=1
out=$(ANDROID_SH_TIMEOUT=180 android_sh "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/rhizo-headroomprobe.apk" | tr -d '\r')
printf '%s\n' "$out" >>"$EV/install.txt"
grep -qx Success <<<"$out" || { fail "pm install of the probe did not print Success: $out"; exit 1; }

step "A. capability off: nothing host-side, unsupported through the HAL and through the app API"
assert_off_posture A ""

step "B. power.cpu_headroom on, no load: high headroom through the app API"
kmsg_mark B || fail "could not write a mark into the kernel log"
ssh_vm -t 20 "mkdir -p /etc/rhizo; printf '[power]\ncpu_headroom = on\n' > $POLICY_CONF" || fail "could not write $POLICY_CONF"
restart_under_policy B rhizo-headroomd.service
v=$(seen "$(ssh_vm -t 15 "echo \$(systemctl is-active rhizo-headroomd.service) \$(test -S /proc/$INIT/root$SOCK_DIR/headroomd && echo socket || echo none) \$(test -d /run/rhizo-headroomd && echo present || echo absent)" | tr -d '\r')" "inactive none absent")
[[ "$v" == "active socket present" ]] && pass "rhizo-headroomd active, the sandbox sees $SOCK_DIR/headroomd, /run/rhizo-headroomd present" \
  || fail "after switching on: '$v' (want 'active socket present')"
ssh_vm -t 15 "cat /run/rhizo-headroomd/status.json" >"$EV/on-state.txt" 2>&1
kl=$(dmesg_after B)
v=$(seen "$(grep -a -o 'RHIZO_MARKER power_headroom=on socket=[^ ]*' <<<"$kl" | tail -1)" "RHIZO_MARKER power_headroom=off reason=absent")
[[ "$v" == "RHIZO_MARKER power_headroom=on socket=$SOCK_DIR/headroomd" ]] && pass "the power HAL marked power_headroom=on with its socket" \
  || fail "power HAL marker since this leg's restart: '$v'"
v=$(seen "$(grep -a -o 'RHIZO_MARKER headroom_socket=[a-z]*' <<<"$kl" | tail -1)" "RHIZO_MARKER headroom_socket=withheld")
[[ "$v" == "RHIZO_MARKER headroom_socket=bound" ]] && pass "the launcher marked headroom_socket=bound" || fail "launcher marker since this leg's restart: '$v'"
await_entry_sync_idle "B. the entry sync after the stack restart"
run_level quiet 0
log "    no load: $RL_STATS"
printf '%s\n' "$RL_STATS" >"$EV/b-report.txt"
assert_on_dump B "$EV/quiet-dumpsys.txt"
assert_sampling B "$RL_STATS" "${RL_TAGS[@]}"
v=$(seen "$(field "$RL_STATS" median)" 0)
num_cmp "$v" ge "$HEADROOM_IDLE_MIN" && pass "median of the non-NaN samples with no load is $v (>= $HEADROOM_IDLE_MIN; $(field "$RL_STATS" nan) NaN of $(field "$RL_STATS" n))" \
  || fail "median headroom with no load is '$v', want at least $HEADROOM_IDLE_MIN ($EV/quiet-probe.txt)"
c=$(seen "$(probe_logcat_agrees "${RL_TAGS[@]}")" "1 0")
[[ "$c" =~ ^([0-9]+)\ ([0-9]+)$ && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" && "${BASH_REMATCH[1]}" -gt 0 ]] \
  && pass "every java sample of the ${#RL_TAGS[@]} probe run(s) is in both the probe's file and its logcat tag (${BASH_REMATCH[1]})" \
  || fail "java samples in the files and in logcat of ${RL_TAGS[*]} '$c' ($EV/quiet-probe.txt, $EV/quiet-logcat.txt)"
QUIET_MEDIAN=$(field "$RL_STATS" median)

step "C. on, rt-load holding $HALF then $NPROC of $NPROC vCPUs: the median falls with each level"
: >"$EV/c-report.txt"
prev=$QUIET_MEDIAN; prev_name="no load"
for lvl in "half $HALF" "all $NPROC"; do
  read -r tag k <<<"$lvl"
  run_level "$tag" "$k"
  log "    $k held: $RL_STATS"
  printf '%s k=%s %s\n' "$tag" "$k" "$RL_STATS" >>"$EV/c-report.txt"
  assert_sampling "C $tag" "$RL_STATS" "${RL_TAGS[@]}"
  med=$(field "$RL_STATS" median)
  v=$(seen "$med" 100)
  if [[ "$tag" == half ]]; then
    num_cmp "$v" ge "$HEADROOM_HALF_LO" && num_cmp "$v" le "$HEADROOM_HALF_HI" \
      && pass "median with $k of $NPROC vCPUs held is $v (within [$HEADROOM_HALF_LO, $HEADROOM_HALF_HI])" \
      || fail "median with $k of $NPROC vCPUs held is '$v', want within [$HEADROOM_HALF_LO, $HEADROOM_HALF_HI] ($EV/$tag-probe.txt)"
  else
    num_cmp "$v" le "$HEADROOM_ALL_MAX" && pass "median with all $k vCPUs held is $v (<= $HEADROOM_ALL_MAX)" \
      || fail "median with all $k vCPUs held is '$v', want at most $HEADROOM_ALL_MAX ($EV/$tag-probe.txt)"
  fi
  v=$(seen "$med" "$prev")
  num_cmp "$v" lt "$prev" && pass "median with $k held ($v) is below the one with $prev_name ($prev)" \
    || fail "median with $k held is '$v', not below the one with $prev_name ('$prev')"
  prev=$med; prev_name="$k held"
done

step "D. nothing Android can read names a host task or pid, judged against Android's own tid snapshot"
: >"$EV/d-report.txt"
ANDROID_SH_TIMEOUT=120 android_sh "$INIT" "logcat -d -b all" | tr -d '\r' >"$EV/logcat-all.txt"
v=$(seen "$(grep -c . "$EV/logcat-all.txt") $(grep -c rt-load "$EV/logcat-all.txt")" "0 1")
[[ "$v" =~ ^([0-9]+)\ 0$ && "${BASH_REMATCH[1]:-0}" -gt 0 ]] && pass "Android's whole logcat (${BASH_REMATCH[1]} lines) holds no rt-load" \
  || fail "logcat -d -b all, lines and rt-load hits: '$v' ($EV/logcat-all.txt)"
for t in quiet half all; do
  for f in "$t-dumpsys.txt" "$t-probe.txt"; do
    n=$(grep -a -c rt-load "$EV/$f" 2>/dev/null); ctl=$(grep -a -c -e 'CPU Headroom' -e 'RHIZO_HEADROOM' "$EV/$f" 2>/dev/null)
    echo "$f rt-load=$n control=$ctl" >>"$EV/d-report.txt"
    v=$(seen "$n" 2)
    [[ "$v" == 0 && "$ctl" -gt 0 ]] && pass "no rt-load in $f (control: $ctl headroom lines)" || fail "$f: rt-load appears $v time(s), control hits $ctl"
  done
done
ssh_vm -t 15 "ls -A /proc/$INIT/root$SOCK_DIR" | tr -d '\r' >"$EV/socket-dir.txt" 2>&1
v=$(seen "$(cat "$EV/socket-dir.txt")" "headroomd status.json")
[[ "$v" == headroomd ]] && pass "$SOCK_DIR holds only the socket (headroomd)" || fail "$SOCK_DIR holds '$v' ($EV/socket-dir.txt)"
for t in half all; do
  sort -u "$EV/$t-android-tids.txt" -o "$EV/$t-android-tids.txt"
  nsnap=$(grep -c -E '^[0-9]+ [0-9]+$' "$EV/$t-android-tids.txt")
  ncoll=$(hr_collisions "$EV/rt-load-host-pids.txt" "$EV/$t-android-tids.txt" "$EV/$t-probe.txt" "$EV/$t-dumpsys.txt" "$EV/$t-logcat.txt")
  echo "$t android-snapshot-lines=$nsnap rt-load-numbers-in-probe-dumpsys-logcat-not-in-snapshot=$ncoll" >>"$EV/d-report.txt"
  v=$(seen "$nsnap" 0)
  num_cmp "$v" gt 0 && pass "control: Android's own tid snapshot for the $t run holds $v threads" \
    || fail "control: Android's tid snapshot for the $t run is empty ($EV/$t-android-tids.txt)"
  v=$(seen "$ncoll" 7)
  [[ "$v" == 0 ]] && pass "$t: no rt-load host pid or tid appears in the probe file, the dumpsys or the probe's logcat unless Android's own snapshot holds that number" \
    || fail "$t: $v rt-load host number(s) appear in what Android can read and not in its own snapshot ($EV/$t-probe.txt, $EV/$t-dumpsys.txt, $EV/rt-load-host-pids.txt)"
done
v=$(seen "$(grep -c -E '^[0-9]+$' "$EV/rt-load-host-pids.txt")" 0)
(( v >= NPROC )) && pass "control: $v rt-load host pids and tids recorded" || fail "control: only $v rt-load host pid(s) recorded for $NPROC vCPUs"

step "E. rt.budgets, rt.contain and trace.host_delay on beside power.cpu_headroom: the answers still hold"
kmsg_mark E || fail "could not write a mark into the kernel log"
ssh_vm -t 20 "mkdir -p /etc/rhizo; printf '[power]\ncpu_headroom = on\n[rt]\nbudgets = on\ncontain = on\n[trace]\nhost_delay = on\n' > $POLICY_CONF" || fail "could not write $POLICY_CONF"
restart_under_policy E rhizo-headroomd.service rhizo-rtd.service rhizo-delayd.service
v=$(seen "$(ssh_vm -t 10 "echo \$(systemctl is-active rhizo-headroomd.service) \$(systemctl is-active rhizo-rtd.service) \$(systemctl is-active rhizo-delayd.service)" | tr -d '\r')" "active inactive active")
[[ "$v" == "active active active" ]] && pass "rhizo-headroomd, rhizo-rtd and rhizo-delayd all active" || fail "units after switching all four on: '$v'"
v=$(seen "$(dmesg_after E | grep -a -o 'RHIZO_MARKER power_headroom=[a-z]*' | tail -1)" "RHIZO_MARKER power_headroom=off")
[[ "$v" == "RHIZO_MARKER power_headroom=on" ]] && pass "the power HAL marked power_headroom=on beside the others" || fail "power HAL marker in leg E: '$v'"
await_entry_sync_idle "E. the entry sync after the stack restart"
run_level rtquiet 0
printf 'rtquiet %s\n' "$RL_STATS" >"$EV/e-report.txt"
assert_sampling "E no load" "$RL_STATS" "${RL_TAGS[@]}"
v=$(seen "$(field "$RL_STATS" median)" 0)
num_cmp "$v" ge "$HEADROOM_IDLE_MIN" && pass "median with no load and all four on is $v (>= $HEADROOM_IDLE_MIN)" \
  || fail "median with no load and all four on is '$v', want at least $HEADROOM_IDLE_MIN ($EV/rtquiet-probe.txt)"
run_level rtall "$NPROC"
printf 'rtall %s\n' "$RL_STATS" >>"$EV/e-report.txt"
assert_sampling "E all held" "$RL_STATS" "${RL_TAGS[@]}"
v=$(seen "$(field "$RL_STATS" median)" 100)
num_cmp "$v" le "$HEADROOM_ALL_MAX" && pass "median with all $NPROC vCPUs held and all four on is $v (<= $HEADROOM_ALL_MAX)" \
  || fail "median with all vCPUs held and all four on is '$v', want at most $HEADROOM_ALL_MAX ($EV/rtall-probe.txt)"

step "G. off after on is unreachable again: the default policy back, the units stopped, the stack restarted"
kmsg_mark G || fail "could not write a mark into the kernel log"
ssh_vm -t 30 "if [ -e $POLICY_SAVED ]; then cp -a $POLICY_SAVED $POLICY_CONF; else rm -f $POLICY_CONF; fi
  systemctl stop rhizo-headroomd.service rhizo-rtd.service rhizo-delayd.service" >"$EV/G-stop.txt" 2>&1 || fail "could not put the default policy back and stop the daemons ($EV/G-stop.txt)"
restart_under_policy G
assert_off_posture G G

step "F. enforce=1, and no denial naming the capability's types since the system test started"
v=$(seen "$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce' | tr -d '\r')" 0)
[[ "$v" == 1 ]] && pass "enforcing at the end" || fail "enforce=$v at the end"
dmesg_after start >"$EV/kmsg-since-start.txt"
grep -qx KMSG_END "$EV/kmsg-since-start.txt" && ! grep -qx NO_MARK "$EV/kmsg-since-start.txt" \
  || fail "the kernel log since the system test's start mark could not be read whole ($EV/kmsg-since-start.txt)"
grep -a 'avc:  denied' "$EV/kmsg-since-start.txt" \
  | grep -a -E 'rhizo_headroomd|rhizo_headroom_socket' >"$EV/avc-feature.txt"
v=$(seen "$(grep -c . "$EV/avc-feature.txt")" 1)
[[ "$v" == 0 ]] && pass "no denial naming rhizo_headroomd or rhizo_headroom_socket" \
  || fail "$v feature denial(s): $EV/avc-feature.txt"

if (( SELFTEST )); then
  failed_steps=$(cut -f2 "$EV/failures.log" 2>/dev/null | sed 's/^step=//' | sort -u)
  survived=()
  for st in "${SELFTEST_STEPS[@]}"; do
    [[ "$st" == 0.* ]] && continue
    grep -Fxq "$st" <<<"$failed_steps" || survived+=("$st")
  done
  if (( ${#survived[@]} )); then
    printf 'FAILED selftest: legs passed on a corrupted value:\n%s\n' "$(printf '  %s\n' "${survived[@]}")" > "$EV/selftest-verdict.txt"
    test_record_verdict FAILED "selftest=1"; log "HEADROOM SYSTEM TEST SELFTEST FAILED"; exit 1
  fi
  echo "PASSED selftest: every asserting leg failed on a corrupted value" > "$EV/selftest-verdict.txt"
  test_record_verdict PASSED "selftest=1"; log "HEADROOM SYSTEM TEST SELFTEST PASSED"; exit 0
fi
if (( FAILED )); then test_record_verdict FAILED; log "HEADROOM SYSTEM TEST FAILED"; exit 1; fi
test_record_verdict PASSED
log "HEADROOM SYSTEM TEST PASSED -- evidence in $EV"
