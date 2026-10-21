#!/bin/bash
# test three concurrent androidd instances on a vm
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: none
# test-records-metrics: no
# test-verdict-params: -
# test-requires: share:rhizo-fps.apk
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
[[ "${RHIZO_DESKTOP_PROFILE:-sway}" == sway ]] \
  || { fail "this system test only runs under the sway desktop profile (got RHIZO_DESKTOP_PROFILE=$RHIZO_DESKTOP_PROFILE)"; exit 1; }

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
SELFTEST=0
for arg in "$@"; do
  case "$arg" in
    --skip-boot) SKIP_BOOT=1 ;;
    --selftest) SELFTEST=1 ;;
    --fast) ;;
    *) echo "unknown argument '$arg'" >&2; exit 2 ;;
  esac
done
# print no verdict parameters
verdict_params() { :; }


ADB=~/Android/Sdk/platform-tools/adb
ADB_TARGET_0="127.0.0.1:$ADB_PORT"
# run adb against instance 0
adbx0() { "$ADB" -s "$ADB_TARGET_0" "$@"; }

FIXTURE_PKG=com.rhizo.fps
FIXTURE_ACT="$FIXTURE_PKG/android.app.NativeActivity"
declare -A SCENE_FOR=([0]=pattern [1]=pattern [2]=pattern)

SWAY_WINDOW_W=960
SWAY_WINDOW_H=1080
SWAY_OUTPUT_SIZE="$(( 960 * 3 ))x1080"

POOL_MEMBERS_FILE=/var/lib/rhizo/pool-members
POOL_PENDING_FILE=/var/lib/rhizo/pool-pending
POOL_REPLACE_TIMEOUT_S=300

IDS=(0 1 2)
# print the androidd unit name of an instance
unit_for()  { [[ "$1" == 0 ]] && echo androidd.service || echo "androidd@$1.service"; }
# print the third address octet of an instance's subnet
subnet_for() { echo "$(( 100 + $1 ))"; }
# print the adb address of an instance
adb_ep_for() { echo "192.168.$(subnet_for "$1").50:5555"; }
# print the run directory of an instance
run_root_for() { [[ "$1" == 0 ]] && echo /run/rhizo || echo "/run/rhizo-$1"; }
# print the cgroup root file of an instance
cgroup_root_file_for() { [[ "$1" == 0 ]] && echo /root/.rhizo_cgroup_root || echo "/root/.rhizo_cgroup_root-$1"; }
# print the boot log path of an instance
boot_log_for()         { [[ "$1" == 0 ]] && echo /root/boot.log || echo "/root/boot-$1.log"; }

LOOP_BUDGET_INSTANCES=6

if (( SELFTEST )); then
  SELFTEST_EV="${TMPDIR:-/tmp}/test-multi-instance-selftest${SUFFIX}"
  rm -rf "$SELFTEST_EV"
  test_init multi-instance --no-vm --evidence-root "$SELFTEST_EV" || exit 1
else
  test_init multi-instance --teardown || exit 1
fi

# list the configured instance ids above 0
vm_configured_ids() {
  local out rc
  out=$(ssh_vm -t 20 "ls /etc/rhizo/instances/ 2>/dev/null; echo RHIZO_LS_DONE" 2>/dev/null); rc=$?
  if (( rc != 0 )) || [[ "$out" != *RHIZO_LS_DONE* ]]; then
    echo UNREACHABLE
    return 1
  fi
  sed 's/\.env$//' <<<"$out" | grep -oE '^[0-9]+$' | grep -vx 0
  return 0
}

# switch the vm to the desktop profile
vm_revert_profile() {
  local tag="$1" out rc
  out=$(ssh_vm -t 60 "rhizo profile desktop" 2>&1)
  rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/profile-desktop-$tag.log"
  (( rc == 0 )) || log "WARNING: 'rhizo profile desktop' ($tag) exited $rc; see $EV/profile-desktop-$tag.log"
  return $rc
}

# remove the instances and set the desktop profile
vm_reset_instances() {
  vm_revert_profile "$1"
  ssh_vm -t 600 "rhizo pool set 0" >/dev/null 2>&1
  local id ids
  ids=$(vm_configured_ids)
  if [[ "$ids" == UNREACHABLE ]]; then
    log "WARNING: vm_reset_instances ($1): /etc/rhizo/instances could not be listed"
    return 1
  fi
  for id in $ids; do
    ssh_vm -t 300 "rhizo instance remove $id" >/dev/null 2>&1
  done
}

INSTANCE_EVIDENCE_IDS=(0 1 2 9)
# write the evidence files for each instance
capture_instance_evidence() {
  local id out rc unit configured
  out=$(ssh_vm -t 30 "cat /var/log/rhizo/supervisor.log" 2>&1); rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/supervisor.log"
  out=$(ssh_vm -t 30 "tail -3000 /tmp/sway.log" 2>&1); rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/sway.log"
  local ids=("${INSTANCE_EVIDENCE_IDS[@]}")
  configured=$(vm_configured_ids)
  if [[ "$configured" != UNREACHABLE ]]; then
    while read -r id; do [[ -n "$id" ]] && ids+=("$id"); done <<<"$configured"
  fi
  [[ -n "${ALLOC_ID:-}" ]] && ids+=("$ALLOC_ID")
  mapfile -t ids < <(printf '%s\n' "${ids[@]}" | sort -un)
  for id in "${ids[@]}"; do
    unit=$(unit_for "$id")
    out=$(ssh_vm -t 30 "journalctl -u $unit -b --no-pager 2>&1 | tail -400" 2>&1); rc=$?
    printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/journal-$id.log"
    out=$(ssh_vm -t 30 "cat $(boot_log_for "$id")" 2>&1); rc=$?
    printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/boot-full-$id.log"
    if [[ -n "${INITPID[$id]:-}" && "$(ssh_vm -t 15 "systemctl is-active $unit" 2>/dev/null | tr -d '[:space:]')" != active ]]; then
      printf '%s\n' "<none: $unit is not running at capture time, and its logcat went with it>" >"$EV/logcat-$id.log"
    elif [[ -n "${INITPID[$id]:-}" ]]; then
      out=$(ssh_vm -t 30 "timeout 15 adb -s $(adb_ep_for "$id") logcat -d -v threadtime -t 3000" 2>&1); rc=$?
      printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/logcat-$id.log"
    else
      printf '%s\n' "<none: no init pid was recorded for instance $id this run>" >"$EV/logcat-$id.log"
    fi
  done
}

# capture evidence and reset the instances
cleanup_vm_state() {
  (( TEST_NO_VM )) && return 0
  capture_instance_evidence
  vm_reset_instances cleanup
  ssh_vm -t 10 "rm -f /etc/rhizo/policy.conf" >/dev/null 2>&1
}
# shellcheck disable=SC2034
(( SELFTEST )) || TEST_EXTRA_CLEANUP=cleanup_vm_state

ASSERT_LOG="$EV/assertions.tsv"
: > "$ASSERT_LOG"
eval "test_lib_pass() $(declare -f pass | tail -n +2)"
eval "test_lib_fail() $(declare -f fail | tail -n +2)"
# print the label prefix through the first dot
_log_key() {
  local first="${1%%$'\n'*}"
  printf '%s.' "${first%%.*}"
}
# log a keyed PASS line and pass
pass() { printf 'PASS\t%s\n' "$(_log_key "$1")" >>"$ASSERT_LOG"; test_lib_pass "$@"; }
# log a keyed FAIL line and fail
fail() { printf 'FAIL\t%s\n' "$(_log_key "$1")" >>"$ASSERT_LOG"; test_lib_fail "$@"; }

REQUIRED_ASSERTIONS=(
  0pre0. 0pre1. 0pre2. 0pre3. 0pre4. 0pre5. 0a. 0b. 0b1. 0b2. 0c. 0d. 0e. 0f. 0g.
  1a.
  2a. 2b.
  3a. 3b. 3c. 3d. 3e. 3f. 3g. 3h. 3i. 3j. 3k. 3l.
  4a.
  5a0. 5a. 5b. 5c. 5d.
  6a. 6b.
  7a0. 7a. 7b. 7c. 7d. 7e.
  8a0. 8a. 8b.
)

# require a verdict for each required label
assert_all_steps_asserted() {
  local label="$1" log_text="$2"; shift 2
  local want missing=()
  for want in "$@"; do
    grep -qP "^(PASS|FAIL)\t\Q$want\E$" <<<"$log_text" || missing+=("$want")
  done
  if (( ${#missing[@]} )); then
    fail "$label: ${#missing[@]} assertion(s) reached no verdict at all -- ${missing[*]}"
    return 1
  fi
  pass "$label: every one of the $# assertions this run owes decided a verdict"
}

WINDOW_RECT_PY='
import json, sys
want = {int(p) for p in sys.argv[1].split(",") if p}
def walk(n, layout):
    for key in ("nodes", "floating_nodes"):
        for c in n.get(key, []):
            if c.get("pid") in want:
                r = c.get("rect") or {}
                print(c.get("id", 0), r.get("x", 0), r.get("y", 0),
                      r.get("width", 0), r.get("height", 0),
                      "floating" if key == "floating_nodes" else "tiled",
                      layout)
                sys.exit(0)
            walk(c, c.get("layout") or layout)
walk(json.load(sys.stdin), "none")
'

# print the window rectangle for the pids
window_rect_from_tree() {
  printf '%s' "$2" | python3 -c "$WINDOW_RECT_PY" "$1" 2>/dev/null
}

CGROUP_LIB_SH='
cgroup_pids() {
  find "$1" -name cgroup.procs -exec cat {} + 2>/dev/null | grep -xE "[0-9]+" | sort -nu
  return 0
}
cgroup_init_pid() {
  local p
  for p in $(cgroup_pids "$1"); do
    if [ "$(cat "${2:-/proc}/$p/comm" 2>/dev/null)" = init ]; then echo "$p"; return 0; fi
  done
  return 0
}
'

read -r -d '' MARKER_LIB_SH <<'EOF' || true
boot_completed_seen() {
  awk -v m="$2" 'match($0, /^\[[ ]*[0-9]+\.[0-9]+\]/) { t = substr($0, RSTART + 1, RLENGTH - 2) + 0; if (t > m) print }' \
    | grep -qE "RHIZO_MARKER sys\.boot_completed=1 sandbox=$1([^0-9]|$)"
}
EOF
BOOT_COMPLETED_SH='
id=$1; mark=$2; tries=$3; i=0
while [ "$i" -lt "$tries" ]; do
  i=$((i + 1))
  if dmesg 2>/dev/null | boot_completed_seen "$id" "$mark"; then echo 1; exit 0; fi
  sleep 1
done
echo 0
'

# print the pids under a cgroup root
cgroup_pids_from_tree() {
  printf '%s\ncgroup_pids "$1"\n' "$CGROUP_LIB_SH" | bash -s "$1"
}
# print the init pid of a cgroup root
cgroup_init_pid_from_tree() {
  printf '%s\ncgroup_init_pid "$1" "$2"\n' "$CGROUP_LIB_SH" | bash -s "$1" "$2"
}

# build a guest command line from shell text
cgroup_sh_cmd() {
  local text="$1"; shift
  local b64 args="" a
  b64=$(printf '%s\n%s\n%s\n' "$CGROUP_LIB_SH" "$MARKER_LIB_SH" "$text" | base64 -w0)
  for a in "$@"; do args+=" '$a'"; done
  printf 'echo %s | base64 -d | bash -s%s' "$b64" "$args"
}
# run the boot-completed check on dmesg text
boot_completed_seen_local() {
  bash -c "$MARKER_LIB_SH"'; boot_completed_seen "$1" "$2"' _ "$1" "$2" <<<"$3"
}
# run shell text on the vm over ssh
cgroup_sh_remote() {
  local timeout="$1"; shift
  ssh_vm -t "$timeout" "$(cgroup_sh_cmd "$@")"
}

BOOT_READ_NOTE=""
# read the boot-completed value for an instance
boot_completed_read() {
  local id="$1" mark="$2" tries="$3" out rc
  BOOT_READ_NOTE=""
  out=$(cgroup_sh_remote 420 "$BOOT_COMPLETED_SH" "$id" "$mark" "$tries" 2>/dev/null | tr -d '[:space:]')
  rc=$?
  if [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  log "    instance $id: the boot-completed read came back empty (ssh rc=$rc) -- asking once more"
  out=$(cgroup_sh_remote 420 "$BOOT_COMPLETED_SH" "$id" "$mark" "$tries" 2>/dev/null | tr -d '[:space:]')
  rc=$?
  if [[ -z "$out" ]]; then
    BOOT_READ_NOTE=" (both attempts came back empty, last ssh rc=$rc)"
  fi
  printf '%s' "$out"
}

# require sys.boot_completed to equal 1
assert_boot_completed_id() {
  local label="$1" id="$2" v="$3" note="${4:-}"
  [[ "$v" == "1" ]] || { fail "$label: instance $id sys.boot_completed='${v:-<empty>}', wanted 1${note}"; return 1; }
  pass "$label: instance $id sys.boot_completed=1"
}

# require distinct veth addresses across instances
assert_distinct_veth() {
  local label="$1"; shift
  local a n=0
  for a in "$@"; do
    n=$((n + 1))
    [[ "$a" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
      fail "$label: address $n of $# is '${a:-<empty>}', not an IPv4 address (got: $*)"
      return 1
    }
  done
  (( n >= 2 )) || { fail "$label: $n address(es) given, need at least two"; return 1; }

  local -A seen=()
  local dup=""
  for a in "$@"; do
    if [[ -n "${seen[$a]:-}" ]]; then dup="$a"; fi
    seen["$a"]=1
  done
  if [[ -n "$dup" ]]; then
    fail "$label: veth address $dup is shared by more than one instance ($*)"
    return 1
  fi
  if (( ${#seen[@]} != $# )); then
    fail "$label: expected $# distinct addresses, got $*"
    return 1
  fi
  pass "$label: all instance veth addresses distinct ($*)"
}

# require distinct, non-nested cgroup roots
assert_cgroups_distinct() {
  local label="$1"; shift
  local cg n=0
  for cg in "$@"; do
    n=$((n + 1))
    [[ -n "${cg//[[:space:]]/}" ]] || { fail "$label: recorded cgroup root $n of $# is empty"; return 1; }
  done
  (( n >= 2 )) || { fail "$label: $n cgroup root(s) given, need at least two"; return 1; }
  local -A seen=()
  local dup="" key
  for cg in "$@"; do
    key="${cg%/}"
    if [[ -n "${seen[$key]:-}" ]]; then dup="$cg"; fi
    seen["$key"]=1
  done
  [[ -z "$dup" ]] || { fail "$label: cgroup root $dup is recorded by more than one instance ($*)"; return 1; }
  local outer inner
  for outer in "$@"; do
    for inner in "$@"; do
      [[ "$inner" == "$outer"/* ]] || continue
      fail "$label: recorded cgroup root $inner is INSIDE $outer, not beside it ($*)"
      return 1
    done
  done
  pass "$label: all $# recorded cgroup roots distinct, and none inside another"
}

# check adb connect reported connected
assert_adb_connected() {
  local label="$1" id="$2" out="$3"
  if grep -qE '(connected to|already connected to)' <<<"$out"; then
    pass "$label: instance $id's adb endpoint connected"
    return 0
  fi
  fail "$label: instance $id's adb connect did not report connected: $(tail -1 <<<"$out")"
  return 1
}

# require Status ok from am start
assert_launch_ok() {
  local label="$1" id="$2" out="$3"
  grep -q 'Status: ok' <<<"$out" \
    || { fail "$label: instance $id's am start -W did not report Status: ok: $(tail -3 <<<"$out")"; return 1; }
  pass "$label: instance $id's fixture app launched"
}

# check loop.max_loop reaches the computed ceiling
assert_loop_max_sized() {
  local label="$1" got="$2" want="$3"
  [[ "$got" =~ ^[0-9]+$ ]] \
    || { fail "$label: loop.max_loop='${got:-<empty>}' is not numeric"; return 1; }
  [[ "$want" =~ ^[0-9]+$ ]] \
    || { fail "$label: release-map.sh computed no numeric ceiling ('$want')"; return 1; }
  (( got >= want )) \
    || { fail "$label: loop.max_loop=$got, below the $want release-map.sh sizes for the $LOOP_BUDGET_INSTANCES instances this run can configure"; return 1; }
  pass "$label: loop.max_loop=$got, at or above the $want this system test's own boot asked for"
}

# require a recorded cgroup root under /sys/fs/cgroup
assert_cgroup_record() {
  local label="$1" id="$2" read="$3" start="$4" mtime cg
  read -r mtime cg <<<"$read"
  [[ -n "$read" ]] \
    || { fail "$label: instance $id's $(cgroup_root_file_for "$id") is empty or unreadable"; return 1; }
  [[ "$start" =~ ^[0-9]+$ ]] \
    || { fail "$label: no guest clock was read before the starts"; return 1; }
  [[ "$mtime" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance $id's record read '$read' carries no mtime"; return 1; }
  (( mtime >= start )) \
    || { fail "$label: instance $id's $(cgroup_root_file_for "$id") ($cg) was written at $mtime, before this run's starts at $start"; return 1; }
  cg="${cg//[[:space:]]/}"
  [[ "$cg" == /sys/fs/cgroup/* ]] \
    || { fail "$label: instance $id recorded cgroup root '$cg', not under /sys/fs/cgroup"; return 1; }
  pass "$label: instance $id's own recorded cgroup root is $cg"
}

# require profile=server in both command outputs
assert_profile_applied() {
  local label="$1" applied="$2" shown="$3"
  grep -qx 'RHIZO_PROFILE profile=server' <<<"$applied" \
    || { fail "$label: no 'RHIZO_PROFILE profile=server' line from 'rhizo profile server' (got '$(tail -2 <<<"${applied:-<empty>}")')"; return 1; }
  grep -qx 'RHIZO_PROFILE profile=server' <<<"$shown" \
    || { fail "$label: 'rhizo profile show' does not report profile=server (got '${shown:-<empty>}')"; return 1; }
  pass "$label: the guest reports the server profile"
}

# check the policy file sets idle_stop_s to 0
assert_idle_stop_off() {
  local label="$1" conf="$2"
  grep -q '^\[server\]' <<<"$conf" \
    || { fail "$label: the policy file has no [server] section (read: '${conf:-<empty>}')"; return 1; }
  grep -qE '^idle_stop_s *= *0$' <<<"$conf" \
    || { fail "$label: the policy file does not carry idle_stop_s = 0 (read: '${conf:-<empty>}')"; return 1; }
  pass "$label: idle_stop_s = 0"
}

# require a registered guest adb key
assert_adb_key_registered() {
  local label="$1" add="$2" list="$3" n
  grep -qE 'added=[1-9]|already registered' <<<"$add" \
    || { fail "$label: 'rhizo adb-key add' neither added a key nor found one already registered (got '$(tail -2 <<<"${add:-<empty>}")')"; return 1; }
  n=$(grep -oE 'list=[0-9]+' <<<"$list" | tail -1 | cut -d= -f2)
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )) \
    || { fail "$label: 'rhizo adb-key list' reports ${n:-<no list= line>} registered key(s), wanted at least 1"; return 1; }
  pass "$label: the guest adb server's own key is registered ($n key(s) on file)"
}

# require an empty instance list above 0
assert_vm_instances_clear() {
  local label="$1" listing="$2" left
  [[ "$listing" == *UNREACHABLE* ]] \
    && { fail "$label: /etc/rhizo/instances could not be read at all"; return 1; }
  left=$(grep -oE '^[0-9]+$' <<<"$listing" | grep -vx 0 | tr '\n' ' ')
  [[ -z "${left// /}" ]] \
    || { fail "$label: instance id(s) ${left}still configured after the reset"; return 1; }
  pass "$label: no instance above 0 is configured"
}

# scan rhizo instance add output for failure
assert_instance_added() {
  local label="$1" id="$2" out="$3"
  grep -qE 'FAIL|refused|error' <<<"$out" \
    && { fail "$label: 'rhizo instance add $id' refused: $(tail -2 <<<"$out")"; return 1; }
  [[ -n "${out//[[:space:]]/}" ]] \
    || { fail "$label: 'rhizo instance add $id' printed nothing at all"; return 1; }
  pass "$label: instance $id configured ($(tail -1 <<<"$out"))"
}

# require adb devices output from the guest
assert_guest_adb_server() {
  local label="$1" devices="$2" server="$3"
  grep -q 'u:r:kernel:s0' <<<"$server" \
    && { fail "$label: the guest's adb server is running in the kernel domain ($(tail -1 <<<"$server"))"; return 1; }
  grep -q 'List of devices attached' <<<"$devices" \
    || { fail "$label: the guest's adb server did not answer 'adb devices' (got '$(tail -2 <<<"${devices:-<empty>}")'). Listener and process state: ${server:-<none>}"; return 1; }
  pass "$label: the guest's adb server answers ($(tail -1 <<<"$server"))"
}

# check androidd.env sets both resident knobs
assert_resident_knobs() {
  local label="$1" conf="$2" want miss=""
  for want in RHIZO_RESIDENT_G=1 RHIZO_RESIDENT_DISPATCH=1; do
    grep -qxF "$want" <<<"$conf" || miss+="'$want' "
  done
  [[ -z "$miss" ]] \
    || { fail "$label: /root/androidd.env is missing $miss(read: '${conf:-<empty>}')"; return 1; }
  pass "$label: both resident knobs are in /root/androidd.env"
}

# require output width to fit the windows
assert_output_fits() {
  local label="$1" got="$2" n="$3" w="$4" want
  [[ "$got" =~ ^[0-9]+$ ]] \
    || { fail "$label: the compositor reported no numeric output width ('${got:-<empty>}')"; return 1; }
  [[ "$n" =~ ^[0-9]+$ && "$w" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance count '$n' or window width '$w' is not numeric"; return 1; }
  want=$(( n * w ))
  (( got >= want )) \
    || { fail "$label: the output is ${got}px wide, under the ${want}px $n windows of ${w}px need"; return 1; }
  pass "$label: ${got}px wide, enough for $n windows of ${w}px"
}

# require identical rectangles in both layout reads
assert_layout_stable() {
  local label="$1" before="$2" after="$3"
  [[ -n "${before//[[:space:]]/}" && -n "${after//[[:space:]]/}" ]] \
    || { fail "$label: the layout could not be read on both sides of the grab (before='${before:-<empty>}' after='${after:-<empty>}')"; return 1; }
  [[ "$before" == "$after" ]] \
    || { fail "$label: the compositor layout changed under the grab. Before: $before. After: $after"; return 1; }
  pass "$label: the layout held still across the grab ($before)"
}

CAPTURE_TEST_OPEN=0
CAPTURE_GRABS=0

# take a screen grab and count it
take_screen_grab() {
  CAPTURE_GRABS=$(( CAPTURE_GRABS + 1 ))
  (( CAPTURE_TEST_OPEN )) || return 2
  shot "$1" || return 1
  pull "$1" "$2" 90 >/dev/null 2>&1
  return 0
}

# check the grab count against the phase state
assert_capture_count() {
  local label="$1" n="$2" open="$3"
  [[ "$n" =~ ^[0-9]+$ ]] \
    || { fail "$label: the grab counter reads '${n:-<empty>}', not a count"; return 1; }
  if (( open )); then
    (( n == 1 )) \
      || { fail "$label: $n screen grabs taken with the capture phase open, wanted exactly 1"; return 1; }
    pass "$label: exactly one grab, taken with the phase open"
    return 0
  fi
  (( n == 0 )) \
    || { fail "$label: $n screen grab(s) taken with the capture phase CLOSED"; return 1; }
  pass "$label: no grab taken with the phase closed"
}

# require a single take_screen_grab call
assert_capture_gated() {
  local label="$1" src="$2" test_ln shot_n shot_ln score_before
  test_ln=$(grep -n 'assert_regions_disjoint "3e\.' <<<"$src" | head -1 | cut -d: -f1)
  [[ -n "$test_ln" ]] \
    || { fail "$label: no 'assert_regions_disjoint \"3e.' call found at all"; return 1; }
  shot_n=$(grep -c '^\s*take_screen_grab ' <<<"$src")
  (( shot_n == 1 )) \
    || { fail "$label: $shot_n take_screen_grab call sites, wanted exactly 1"; return 1; }
  shot_ln=$(grep -n '^\s*take_screen_grab ' <<<"$src" | head -1 | cut -d: -f1)
  (( shot_ln > test_ln )) \
    || { fail "$label: the grab is at line $shot_ln, before the disjointness system test at line $test_ln"; return 1; }
  score_before=$(head -n "$test_ln" <<<"$src" | grep -c 'pngstat\.py')
  (( score_before == 0 )) \
    || { fail "$label: $score_before pngstat.py call(s) run before the disjointness system test at line $test_ln"; return 1; }
  pass "$label: one grab, after the system test at line $test_ln, with nothing scored before it"
}

# print the default display mScreenState
screen_state_of() {
  grep -m1 -oE 'mScreenState=[A-Z_]+' <<<"$1" | cut -d= -f2
}
# print the mScreenState of an instance display
display_screen_state() {
  screen_state_of "$(ssh_vm -t 20 "adb -s $(adb_ep_for "$1") shell dumpsys display" 2>/dev/null)"
}
# send the wake keyevent and print mScreenState
wake_display() {
  local st="" deadline=$(( SECONDS + 20 ))
  ssh_vm -t 20 "adb -s $(adb_ep_for "$1") shell input keyevent 224" >/dev/null 2>&1
  while (( SECONDS < deadline )); do
    st=$(display_screen_state "$1")
    [[ "$st" == ON ]] && { echo ON; return 0; }
    sleep 1
  done
  echo "${st:-<unread>}"
  return 1
}
# require mScreenState to read ON
assert_display_on() {
  local label="$1" id="$2" st="$3"
  [[ "$st" == ON ]] \
    || { fail "$label: instance $id's display reads mScreenState=${st:-<unread>}, not ON"; return 1; }
  pass "$label: instance $id's display is requested ON"
}
# require the display wake to precede the grab
assert_grab_after_wake() {
  local label="$1" src="$2" test_ln wake_ln shot_ln
  test_ln=$(grep -n '^\s*CAPTURE_TEST_OPEN=1' <<<"$src" | head -1 | cut -d: -f1)
  wake_ln=$(grep -n 'assert_display_on "3k\.' <<<"$src" | head -1 | cut -d: -f1)
  shot_ln=$(grep -n '^\s*take_screen_grab ' <<<"$src" | head -1 | cut -d: -f1)
  [[ -n "$wake_ln" && -n "$shot_ln" && -n "$test_ln" ]] \
    || { fail "$label: step 3 has no 3k. display wake between its capture system test and its grab (system test=${test_ln:-none} wake=${wake_ln:-none} grab=${shot_ln:-none})"; return 1; }
  (( test_ln < wake_ln && wake_ln < shot_ln )) \
    || { fail "$label: the 3k. wake is at line $wake_ln, not between the system test at $test_ln and the grab at $shot_ln"; return 1; }
  local call ln
  for call in 'assert_display_on "3k\.' 'assert_display_on "3l\.'; do
    ln=$(grep -n "$call" <<<"$src" | head -1 | cut -d: -f1)
    [[ -n "$ln" ]] && (( ln > 1 )) \
      || { fail "$label: step 3 has no ${call#assert_display_on \"} display read"; return 1; }
    sed -n "$(( ln - 1 ))p" <<<"$src" | grep -q '^\s*for id in "${IDS\[@\]}"; do$' \
      || { fail "$label: the ${call#assert_display_on \"} read at line $ln does not run for every id in IDS"; return 1; }
  done
  ln=$(grep -n 'assert_display_on "3l\.' <<<"$src" | head -1 | cut -d: -f1)
  (( ln > shot_ln )) \
    || { fail "$label: the 3l. re-read is at line $ln, not after the grab at $shot_ln"; return 1; }
  pass "$label: every display is woken and read ON after the system test at line $test_ln, before the grab at line $shot_ln"
}

# require a nonzero window rectangle
assert_window_rect() {
  local label="$1" id="$2" rect="$3" x y w h
  read -r x y w h <<<"$rect"
  [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance $id has no mapped toplevel of its own (got '${rect:-<none>}')"; return 1; }
  (( w > 0 && h > 0 )) \
    || { fail "$label: instance $id's toplevel is mapped at ${w}x${h}"; return 1; }
  pass "$label: instance $id's own toplevel is ${w}x${h}+${x}+${y}"
}

NONBLACK_FLOOR_PCT=50
DISTINCT_FLOOR=8

# require valid PNG region pixel statistics
assert_marker_captured() {
  local label="$1" id="$2" bytes="$3" rect="$4" stats="$5"
  [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > 0 )) \
    || { fail "$label: instance $id's composer capture wrote no PNG (${bytes:-<none>} bytes)"; return 1; }
  [[ -n "${stats//[[:space:]]/}" ]] \
    || { fail "$label: instance $id's PNG is $bytes bytes but pngstat.py printed nothing"; return 1; }

  local x y w h size iw ih pixels nonblack distinct
  read -r x y w h <<<"$rect"
  size=$(grep -m1 '^size=' <<<"$stats" | cut -d= -f2)
  iw=${size%%x*}; ih=${size##*x}
  local f
  for f in "$x" "$y" "$w" "$h" "$iw" "$ih"; do
    [[ "$f" =~ ^[0-9]+$ ]] \
      || { fail "$label: instance $id's rect '$rect' or image size '${size:-<none>}' has a non-numeric field ('${f:-<empty>}')"; return 1; }
  done
  (( w > 0 && h > 0 )) \
    || { fail "$label: instance $id's region is ${w}x${h}"; return 1; }
  (( x + w <= iw && y + h <= ih )) \
    || { fail "$label: instance $id's region ${w}x${h}+${x}+${y} does not fit inside the ${iw}x${ih} capture"; return 1; }

  pixels=$(grep -m1 '^pixels=' <<<"$stats" | cut -d= -f2)
  nonblack=$(grep -m1 '^nonblack_pct=' <<<"$stats" | cut -d= -f2)
  distinct=$(grep -m1 '^distinct=' <<<"$stats" | cut -d= -f2)
  [[ "$pixels" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance $id's stats carry no numeric pixels= (got '${pixels:-<none>}')"; return 1; }
  (( pixels > 0 )) \
    || { fail "$label: instance $id's sample summed 0 pixels"; return 1; }
  [[ "$nonblack" =~ ^[0-9.]+$ && "$distinct" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance $id's stats carry no numeric nonblack_pct=/distinct= (got '${nonblack:-<none>}'/'${distinct:-<none>}')"; return 1; }
  awk -v v="$nonblack" -v f="$NONBLACK_FLOOR_PCT" 'BEGIN { exit !(v + 0 > f) }' \
    || { fail "$label: instance $id's region is only ${nonblack}% non-black over $pixels pixels, under the ${NONBLACK_FLOOR_PCT}% floor"; return 1; }
  (( distinct >= DISTINCT_FLOOR )) \
    || { fail "$label: instance $id's region has $distinct distinct color(s) over $pixels pixels, under the $DISTINCT_FLOOR floor"; return 1; }
  pass "$label: instance $id's capture is $bytes bytes, ${w}x${h}+${x}+${y} inside ${iw}x${ih}, $pixels pixels, ${nonblack}% non-black, $distinct colors"
}

# check the window identity differs from the others
assert_marker_distinct() {
  local label="$1" id="$2" mine="$3"; shift 3
  [[ -n "${mine//[[:space:]]/}" ]] \
    || { fail "$label: instance $id produced no window identity at all"; return 1; }
  local other
  for other in "$@"; do
    if [[ "$other" == "$mine" ]]; then
      fail "$label: instance $id's toplevel (sway con_id $mine) is the same window another instance claims"
      return 1
    fi
  done
  pass "$label: instance $id's toplevel (sway con_id $mine) distinct from the others"
}

# return success for two overlapping rectangles
rects_overlap() {
  local ax ay aw ah bx by bw bh
  read -r ax ay aw ah <<<"$1"
  read -r bx by bw bh <<<"$2"
  (( ax + aw <= bx )) && return 1
  (( bx + bw <= ax )) && return 1
  (( ay + ah <= by )) && return 1
  (( by + bh <= ay )) && return 1
  return 0
}

# require pairwise disjoint regions
assert_regions_disjoint() {
  local label="$1" note="$2"; shift 2
  local n=0 e
  for e in "$@"; do
    n=$((n + 1))
    [[ "${e#*:}" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] \
      || { fail "$label: region $n of $# is '${e:-<empty>}', not '<id>:<x y w h>'"; return 1; }
  done
  (( n >= 2 )) || { fail "$label: $n region(s) given, need at least two"; return 1; }
  local i j a b
  for (( i = 1; i <= $#; i++ )); do
    for (( j = i + 1; j <= $#; j++ )); do
      a="${!i}"; b="${!j}"
      if rects_overlap "${a#*:}" "${b#*:}"; then
        fail "$label: instance ${a%%:*}'s region (${a#*:}) overlaps instance ${b%%:*}'s (${b#*:}). Compositor state: $note"
        return 1
      fi
    done
  done
  pass "$label: all $# scored regions pairwise disjoint"
}

# require the property to differ across instances
assert_property_isolated() {
  local label="$1" written="$2" own="$3" cross="$4" liveness="$5"
  [[ "$own" == "$written" ]] \
    || { fail "$label: instance 1's OWN readback of what it just set is '$own', wanted '$written'"; return 1; }
  [[ -n "${liveness//[[:space:]]/}" ]] \
    || { fail "$label: instance 2's getprop channel answered empty even for a known-present property"; return 1; }
  if [[ "$cross" == "$written" ]]; then
    fail "$label: instance 2 read instance 1's own marker property ('$written') -- property/binder namespaces are NOT isolated"
    return 1
  fi
  pass "$label: instance 1's write took ($own), instance 2's channel is live ($liveness), and instance 2 could not read instance 1's marker (read '${cross:-<empty>}')"
}

# compare a unit ActiveState to a given state
assert_unit_state() {
  local label="$1" unit="$2" got="$3" want="$4"
  [[ "$got" == "$want" ]] || { fail "$label: $unit ActiveState=$got, wanted $want"; return 1; }
  pass "$label: $unit is $want"
}

# require matching cgroup.freeze reads
assert_freeze_state_unchanged() {
  local label="$1" id="$2" before="$3" after="$4"
  [[ -n "${before//[[:space:]]/}" ]] \
    || { fail "$label: instance $id's cgroup.freeze read empty BEFORE the peer stopped"; return 1; }
  [[ -n "${after//[[:space:]]/}" ]] \
    || { fail "$label: instance $id's cgroup.freeze read empty AFTER the peer stopped"; return 1; }
  [[ "$before" == "$after" ]] \
    || { fail "$label: instance $id's cgroup.freeze read '$before' before, '$after' after a peer stopped"; return 1; }
  pass "$label: instance $id's cgroup.freeze state unchanged ($before)"
}

# check the pool reached its target size
assert_pool_replacement_observed() {
  local label="$1" timed_out="$2" timeout_s="$3" target="$4" members="$5"
  if [[ "$timed_out" != 0 ]]; then
    fail "$label: pool-members never reached $target member(s) without the allocated id within ${timeout_s}s (last read: $(tr '\n' ' ' <<<"${members:-<empty>}"))"
    return 1
  fi
  pass "$label: pool-members settled at $target member(s) within ${timeout_s}s"
}

# check allocation replaced the instance in the pool
assert_pool_allocate_replaced() {
  local label="$1" allocated="$2" members_after="$3" pending_after="$4" id both=""
  if grep -qx "$allocated" <<<"$members_after"; then
    fail "$label: the allocated instance $allocated is STILL listed as a pool member"
    return 1
  fi
  while read -r id; do
    [[ -n "${id//[[:space:]]/}" ]] || continue
    grep -qx "$id" <<<"$pending_after" && both="$id"
  done <<<"$members_after"
  if [[ -n "$both" ]]; then
    fail "$label: instance $both is listed in BOTH $POOL_MEMBERS_FILE and $POOL_PENDING_FILE"
    return 1
  fi
  if [[ -z "${members_after//[[:space:]]/}" ]]; then
    if [[ -n "${pending_after//[[:space:]]/}" ]]; then
      fail "$label: the pool holds no member, only the reservation(s) $(tr '\n' ' ' <<<"$pending_after")"
      return 1
    fi
    fail "$label: the pool has no member after the background replacement should have filled it"
    return 1
  fi
  pass "$label: instance $allocated left the pool, a replacement was promoted into it ($(tr '\n' ' ' <<<"$members_after"))"
}

# require zero pending pool reservations
assert_pool_reservation_drained() {
  local label="$1" status="$2" pending="$3" count
  count=$(sed -n 's/.*[[:space:]]pending=\([0-9][0-9]*\).*/\1/p' <<<"$status" | tail -1)
  if [[ -z "$count" ]]; then
    fail "$label: 'rhizo pool status' reported no pending= count (read: $(tr '\n' ' ' <<<"${status:-<empty>}"))"
    return 1
  fi
  if (( count != 0 )); then
    fail "$label: $count reservation(s) still held after the replacement settled"
    return 1
  fi
  if [[ -n "${pending//[[:space:]]/}" ]]; then
    fail "$label: pool status says pending=0 while $POOL_PENDING_FILE still lists $(tr '\n' ' ' <<<"$pending")"
    return 1
  fi
  pass "$label: pending=0 and $POOL_PENDING_FILE is empty"
}

# require a systemd-run unit for the replacement
assert_pool_replacement_unit() {
  local label="$1" allocated="$2" listed="$3" journal="$4" since="$5"
  local unit="rhizo-pool-replace-$allocated.service"
  if grep -qF "$unit" <<<"$listed"; then
    pass "$label: the replacement ran as $unit, listed live while the pool refilled"
    return 0
  fi
  [[ -n "${since//[[:space:]]/}" ]] \
    || { fail "$label: the journal read carried no --since stamp"; return 1; }
  if grep -qF "$unit" <<<"$journal"; then
    pass "$label: the replacement ran as $unit (journal lines naming it since $since)"
    return 0
  fi
  fail "$label: $unit was not listed while the pool refilled and the journal since $since has no line naming it"
  return 1
}

# require pool k and members to match
assert_pool_configured() {
  local label="$1" rc="$2" status="$3" want="$4" k members
  [[ "$rc" == 0 ]] \
    || { fail "$label: 'rhizo pool set $want' exited $rc"; return 1; }
  grep -q '^RHIZO_POOL ' <<<"$status" \
    || { fail "$label: 'rhizo pool status' printed no RHIZO_POOL line (got '${status:-<empty>}')"; return 1; }
  k=$(grep -oE '(^| )k=[0-9]+' <<<"$status" | tail -1 | cut -d= -f2)
  members=$(grep -oE '(^| )members=[0-9]+' <<<"$status" | tail -1 | cut -d= -f2)
  [[ "$k" =~ ^[0-9]+$ && "$members" =~ ^[0-9]+$ ]] \
    || { fail "$label: 'rhizo pool status' carries no numeric k=/members= (k='${k:-<none>}' members='${members:-<none>}')"; return 1; }
  [[ "$k" == "$want" ]] \
    || { fail "$label: the guest reports k=$k, not the $want this system test asked for"; return 1; }
  [[ "$members" == "$want" ]] \
    || { fail "$label: the guest reports members=$members against k=$want"; return 1; }
  pass "$label: the guest's own answer is k=$k members=$members"
}

# require the fixture package in pm list
assert_clone_has_app() {
  local label="$1" out="$2"
  grep -qxF "package:$FIXTURE_PKG" <<<"$out" \
    || { fail "$label: the clone's own pm list packages does not carry $FIXTURE_PKG"; return 1; }
  pass "$label: the clone booted with $FIXTURE_PKG present, from the snapshot alone"
}

# require a nonempty value
assert_present() {
  local label="$1" what="$2" value="$3"
  [[ -n "${value//[[:space:]]/}" ]] || { fail "$label: $what"; return 1; }
  pass "$label: $value"
}

if (( SELFTEST )); then
  step "selftest: every assertion above must be able to fail, by name"

  _log_lines() { wc -l <"$ASSERT_LOG" 2>/dev/null || echo 0; }
  _verdicts_since() {
    local n=$(( $(_log_lines) - $1 ))
    (( n > 0 )) || return 1
    tail -n "$n" "$ASSERT_LOG" | cut -f1 | sort -u | tr '\n' ',' | sed 's/,$//'
  }
  check_fails() {
    local what="$1" fn="$2"; shift 2
    local before verdicts
    before=$(_log_lines)
    ( "$fn" "$@" ) >/dev/null 2>&1
    : > "$EV/failures.log"
    if ! verdicts=$(_verdicts_since "$before"); then
      fail "selftest: $what reached NO verdict at all"
      return
    fi
    case "$verdicts" in
      FAIL) log "  selftest OK: $what" ;;
      PASS) fail "selftest: $what did NOT fail" ;;
      *)    fail "selftest: $what reached more than one verdict ($verdicts)" ;;
    esac
  }
  check_passes() {
    local what="$1" fn="$2"; shift 2
    local before verdicts
    before=$(_log_lines)
    ( "$fn" "$@" ) >/dev/null 2>&1
    : > "$EV/failures.log"
    if ! verdicts=$(_verdicts_since "$before"); then
      fail "selftest: $what reached NO verdict at all on a genuinely good input"
      return
    fi
    case "$verdicts" in
      PASS) log "  selftest OK: $what" ;;
      FAIL) fail "selftest: $what fired on a genuinely good input" ;;
      *)    fail "selftest: $what reached more than one verdict ($verdicts)" ;;
    esac
  }

  canary_aborts() {
    local -A seen=()
    seen["$1"]=1
    pass "canary: reached a verdict"
  }
  canary_silent() { return 1; }
  canary_double() { fail "canary: first verdict"; pass "canary: second verdict"; }

  canary_check() {
    local what="$1" driver="$2"; shift 2
    local before=$FAILED
    "$driver" "$what" "$@" >/dev/null 2>&1
    if (( FAILED > before )); then
      log "  selftest OK: $driver reports it (\"$what\")"
      FAILED=$before
      : > "$EV/failures.log"
    else
      fail "selftest: $driver did NOT report \"$what\""
    fi
  }
  canary_check "an aborting helper reaches no verdict" check_fails canary_aborts ""
  canary_check "an aborting helper reaches no verdict" check_passes canary_aborts ""
  canary_check "a silent helper reaches no verdict" check_fails canary_silent x
  canary_check "a silent helper reaches no verdict" check_passes canary_silent x
  canary_check "a helper that decides twice is caught" check_fails canary_double x
  check_fails "a canary that really fails is reported as failing" fail "canary: a real failure"
  check_passes "a canary that really passes is reported as passing" pass "canary: a real pass"

  check_fails "boot_completed=0 is caught" assert_boot_completed_id x 1 "0"
  check_fails "an empty boot_completed is caught" assert_boot_completed_id x 1 ""
  check_passes "boot_completed=1 is accepted" assert_boot_completed_id x 1 "1"

  check_fails "two identical veth addresses is caught" assert_distinct_veth x \
    192.168.100.1 192.168.101.1 192.168.101.1
  check_passes "three distinct veth addresses is accepted" assert_distinct_veth x \
    192.168.100.1 192.168.101.1 192.168.102.1
  check_fails "an empty veth address in the first position is caught" assert_distinct_veth x \
    "" 192.168.101.1 192.168.102.1
  check_fails "an empty veth address in the middle is caught" assert_distinct_veth x \
    192.168.100.1 "" 192.168.102.1
  check_fails "an empty veth address in the last position is caught" assert_distinct_veth x \
    192.168.100.1 192.168.101.1 ""
  check_fails "two empty veth addresses are caught" assert_distinct_veth x \
    192.168.100.1 "" ""
  check_fails "a non-address string is caught" assert_distinct_veth x \
    192.168.100.1 192.168.101.1 "no such device"
  check_fails "fewer than two addresses is caught" assert_distinct_veth x 192.168.100.1

  check_fails "two instances recording one cgroup root is caught" assert_cgroups_distinct x \
    /sys/fs/cgroup/rhizo /sys/fs/cgroup/rhizo /sys/fs/cgroup/androidd-2
  check_fails "an empty recorded root among them is caught" assert_cgroups_distinct x \
    /sys/fs/cgroup/rhizo "" /sys/fs/cgroup/androidd-2
  check_passes "three distinct recorded roots are accepted" assert_cgroups_distinct x \
    /sys/fs/cgroup/rhizo /sys/fs/cgroup/androidd-1 /sys/fs/cgroup/androidd-2
  check_fails "one cgroup root written twice, once with a trailing slash, is caught" \
    assert_cgroups_distinct x /sys/fs/cgroup/rhizo /sys/fs/cgroup/rhizo/ /sys/fs/cgroup/androidd-2
  check_fails "one instance's root nested INSIDE another's is caught" assert_cgroups_distinct x \
    /sys/fs/cgroup/rhizo /sys/fs/cgroup/rhizo/1 /sys/fs/cgroup/rhizo/2
  check_passes "roots that merely share a prefix are beside each other, and accepted" \
    assert_cgroups_distinct x /sys/fs/cgroup/rhizo /sys/fs/cgroup/rhizo-1 /sys/fs/cgroup/rhizo-2

  check_fails "an adb connect failure is caught" assert_adb_connected x 1 "failed to connect to 192.168.101.50:5555"
  check_passes "a real adb connect is accepted" assert_adb_connected x 1 "connected to 192.168.101.50:5555"
  check_passes "an already-connected reply is accepted too" assert_adb_connected x 1 \
    "already connected to 192.168.101.50:5555"

  check_fails "am start without Status: ok is caught" assert_launch_ok x 1 "Error: Activity not started"
  check_passes "am start with Status: ok is accepted" assert_launch_ok x 1 $'Starting: Intent\nStatus: ok\nActivity: com.rhizo.fps/.MainActivity'

  check_fails "a vm under the computed loop ceiling is caught" assert_loop_max_sized x 64 426
  check_fails "a non-numeric loop.max_loop is caught" assert_loop_max_sized x "" 426
  check_fails "a ceiling release-map.sh could not compute is caught" assert_loop_max_sized x 426 ""
  check_passes "a vm at the computed loop ceiling is accepted" assert_loop_max_sized x 426 426

  check_fails "an instance with no recorded cgroup root is caught" assert_cgroup_record x 1 "" 1000
  check_fails "a recorded cgroup root outside /sys/fs/cgroup is caught" assert_cgroup_record x 1 "1001 /run/rhizo-1" 1000
  check_fails "a record an earlier launch wrote is caught" assert_cgroup_record x 0 "999 /sys/fs/cgroup/rhizo" 1000
  check_fails "a record with no mtime is caught" assert_cgroup_record x 0 "/sys/fs/cgroup/rhizo" 1000
  check_fails "no start mark to judge a record by is caught" assert_cgroup_record x 0 "1001 /sys/fs/cgroup/rhizo" ""
  check_passes "a real recorded cgroup root is accepted" assert_cgroup_record x 1 \
    "1001 /sys/fs/cgroup/system.slice/system-androidd.slice/androidd@1.service" 1000
  check_passes "a record written in the start mark's own second is accepted" assert_cgroup_record x 0 \
    "1000 /sys/fs/cgroup/system.slice/androidd.service/android" 1000
  grep -q 'assert_cgroup_record "0c. $unit" "$id" "$cg_read" "$CG_START_EPOCH"' <<<"$(sed -n '/^CONCURRENT_BOOT_START=/,$p' "$(basename "${BASH_SOURCE[0]}")")" \
    || fail "selftest: the real run's 0c no longer judges the cgroup record against this run's start mark"

  check_fails "an instance with no toplevel of its own is caught" assert_window_rect x 1 ""
  check_fails "a zero-area toplevel is caught" assert_window_rect x 1 "0 0 0 0"
  check_passes "a real toplevel rect is accepted" assert_window_rect x 1 "0 0 1280 800"

  PNGSTAT_PAINTED=$'size=1920x1080\npixels=921600\nmean_r=101.36\nmean_g=98.20\nmean_b=112.44\nnonblack=910000\nnonblack_pct=98.740\ndistinct=281'
  PNGSTAT_ZERO_PIXELS=$'size=1920x1080\npixels=0\nmean_r=0.00\nmean_g=0.00\nmean_b=0.00\nnonblack=0\nnonblack_pct=0.000\ndistinct=0'
  PNGSTAT_BLACK=$'size=1920x1080\npixels=921600\nmean_r=0.00\nmean_g=0.00\nmean_b=0.00\nnonblack=0\nnonblack_pct=0.000\ndistinct=1'
  PNGSTAT_FLAT_NONBLACK=$'size=1920x1080\npixels=921600\nmean_r=64.00\nmean_g=64.00\nmean_b=64.00\nnonblack=921600\nnonblack_pct=100.000\ndistinct=1'
  PNGSTAT_PATTERN=$'size=1920x1080\npixels=921600\nmean_r=96.00\nmean_g=96.00\nmean_b=60.00\nnonblack=921600\nnonblack_pct=100.000\ndistinct=16'
  GOOD_RECT="0 0 1280 720"

  check_fails "a capture that wrote no PNG is caught" \
    assert_marker_captured x 1 0 "$GOOD_RECT" "$PNGSTAT_PAINTED"
  check_fails "a PNG pngstat.py could not read is caught" \
    assert_marker_captured x 1 40960 "$GOOD_RECT" ""
  check_fails "a region that scored ZERO pixels is caught" \
    assert_marker_captured x 1 40960 "$GOOD_RECT" "$PNGSTAT_ZERO_PIXELS"
  check_fails "a solid-black window is caught" \
    assert_marker_captured x 1 40960 "$GOOD_RECT" "$PNGSTAT_BLACK"
  check_fails "a window painted one flat NON-black color is caught" \
    assert_marker_captured x 1 40960 "$GOOD_RECT" "$PNGSTAT_FLAT_NONBLACK"
  check_fails "a region hanging far outside the captured image is caught" \
    assert_marker_captured x 1 40960 "9000 9000 640 480" "$PNGSTAT_PAINTED"
  check_fails "a region that only just overhangs the image is caught" \
    assert_marker_captured x 1 40960 "1900 0 640 480" "$PNGSTAT_PAINTED"
  check_fails "a zero-area region is caught" \
    assert_marker_captured x 1 40960 "0 0 0 0" "$PNGSTAT_PAINTED"
  check_fails "a partially numeric rect is caught" \
    assert_marker_captured x 1 40960 "1" "$PNGSTAT_PAINTED"
  check_passes "a real painted capture inside the image is accepted" \
    assert_marker_captured x 1 40960 "$GOOD_RECT" "$PNGSTAT_PAINTED"
  check_passes "the fixture's own pattern scene clears the content floors" \
    assert_marker_captured x 1 40960 "$GOOD_RECT" "$PNGSTAT_PATTERN"

  check_fails "two instances claiming one scored region is caught" \
    assert_marker_distinct x 1 "0 0 640 720" "640 0 640 720" "0 0 640 720"
  check_fails "an instance with no scored region at all is caught" \
    assert_marker_distinct x 1 "" "640 0 640 720" "0 0 640 720"
  check_passes "three distinct scored regions are accepted" \
    assert_marker_distinct x 1 "0 0 640 720" "640 0 640 720" "1280 0 640 720"

  TREE_TWO_INSTANCES='{"layout":"splith","nodes":[{"layout":"splith","nodes":[],"floating_nodes":[
    {"id":5,"pid":100,"app_id":"rhizo","name":"Rhizo","rect":{"x":0,"y":0,"width":960,"height":1080},"nodes":[],"floating_nodes":[]},
    {"id":7,"pid":200,"app_id":"rhizo","name":"Rhizo","rect":{"x":960,"y":0,"width":960,"height":1080},"nodes":[],"floating_nodes":[]}
  ]}],"floating_nodes":[]}'
  TREE_ZERO_AREA='{"layout":"splith","nodes":[{"layout":"splith","nodes":[],"floating_nodes":[
    {"id":9,"pid":200,"app_id":"rhizo","name":"Rhizo","rect":{"x":0,"y":0,"width":0,"height":0},"nodes":[],"floating_nodes":[]}
  ]}],"floating_nodes":[]}'
  TREE_TABBED='{"layout":"splith","nodes":[{"layout":"tabbed","nodes":[
    {"id":11,"pid":100,"app_id":"rhizo","name":"Rhizo","rect":{"x":0,"y":0,"width":1920,"height":1080},"nodes":[],"floating_nodes":[]},
    {"id":13,"pid":200,"app_id":"rhizo","name":"Rhizo","rect":{"x":0,"y":0,"width":1920,"height":1080},"nodes":[],"floating_nodes":[]}
  ],"floating_nodes":[]}],"floating_nodes":[]}'
  assert_resolver() {
    local got; got=$(window_rect_from_tree "$2" "$3")
    [[ "$got" == "$4" ]] || { fail "$1: resolver returned '${got:-<empty>}', wanted '${4:-<empty>}'"; return 1; }
    pass "$1: resolver returned '${got:-<empty>}'"
  }
  check_passes "the resolver picks the toplevel whose pid is in THIS instance's cgroup" \
    assert_resolver x "200,201" "$TREE_TWO_INSTANCES" "7 960 0 960 1080 floating splith"
  check_passes "the resolver picks the other instance's toplevel for the other pid set" \
    assert_resolver x "100" "$TREE_TWO_INSTANCES" "5 0 0 960 1080 floating splith"
  check_passes "the resolver returns nothing when no pid matches" \
    assert_resolver x "999" "$TREE_TWO_INSTANCES" ""
  check_passes "the resolver reports a zero-area window instead of hiding it" \
    assert_resolver x "200" "$TREE_ZERO_AREA" "9 0 0 0 0 floating splith"
  check_passes "the resolver names a tabbed container it found a window in" \
    assert_resolver x "200" "$TREE_TABBED" "13 0 0 1920 1080 tiled tabbed"

  check_fails "two regions differing by ONE PIXEL are caught as overlapping" \
    assert_regions_disjoint x "note" "0:0 0 960 1080" "1:1 0 960 1080"
  check_fails "two identical regions are caught" \
    assert_regions_disjoint x "note" "0:0 0 960 1080" "1:0 0 960 1080"
  check_fails "a region contained inside another is caught" \
    assert_regions_disjoint x "note" "0:0 0 960 1080" "1:100 100 200 200"
  check_fails "a third region overlapping the first is caught" \
    assert_regions_disjoint x "note" "0:0 0 960 1080" "1:960 0 960 1080" "2:900 0 960 1080"
  check_fails "an unreadable region is caught" \
    assert_regions_disjoint x "note" "0:0 0 960 1080" "1:"
  check_fails "fewer than two regions is caught" \
    assert_regions_disjoint x "note" "0:0 0 960 1080"
  check_passes "three side-by-side regions are accepted" \
    assert_regions_disjoint x "note" "0:0 0 960 1080" "1:960 0 960 1080" "2:1920 0 960 1080"
  check_passes "regions separated on y are accepted" \
    assert_regions_disjoint x "note" "0:0 0 960 540" "1:0 540 960 540"

  check_fails "a layout that moved under the grab is caught" assert_layout_stable x \
    "instance 0: con=5 at 0,0 960x1080" "instance 0: con=5 at 960,0 960x1080"
  check_fails "a layout unreadable after the grab is caught" assert_layout_stable x \
    "instance 0: con=5 at 0,0 960x1080" ""
  check_fails "a layout unreadable before the grab is caught" assert_layout_stable x \
    "" "instance 0: con=5 at 0,0 960x1080"
  check_passes "a layout that held still is accepted" assert_layout_stable x \
    "instance 0: con=5 at 0,0 960x1080" "instance 0: con=5 at 0,0 960x1080"

  SRC_GOOD=$'step 3\nmove windows\nassert_regions_disjoint "3e. the three scored regions" x\n  take_screen_grab /tmp/one.png out\n  pngstat.py --region\n'
  SRC_INTERLEAVED=$'step 3\n  take_screen_grab /tmp/a.png out\n  pngstat.py --region\nassert_regions_disjoint "3e. the three scored regions" x\n'
  SRC_THREE_GRABS=$'assert_regions_disjoint "3e. the three scored regions" x\n  take_screen_grab /tmp/a.png out\n  take_screen_grab /tmp/b.png out\n  take_screen_grab /tmp/c.png out\n'
  SRC_NO_TEST=$'step 3\n  take_screen_grab /tmp/one.png out\n  pngstat.py --region\n'
  check_fails "a grab taken with the capture phase CLOSED is caught" \
    assert_capture_count x 1 0
  check_fails "three grabs behind a per-instance helper are caught" \
    assert_capture_count x 3 1
  check_fails "two grabs are caught" \
    assert_capture_count x 2 1
  check_fails "no grab at all with the phase OPEN is caught" \
    assert_capture_count x 0 1
  check_fails "a broken counter is caught" \
    assert_capture_count x "" 1
  check_passes "exactly one grab with the phase open is accepted" \
    assert_capture_count x 1 1
  check_passes "no grab with the phase closed is accepted" \
    assert_capture_count x 0 0

  assert_grab_refused() {
    local before="$CAPTURE_GRABS" rc
    CAPTURE_TEST_OPEN=0
    take_screen_grab /tmp/rhizo-selftest-never "$EV/never.png"; rc=$?
    (( rc == 2 )) || { fail "$1: take_screen_grab returned $rc with the phase closed, wanted 2 (refused)"; return 1; }
    (( CAPTURE_GRABS == before + 1 )) || { fail "$1: a refused grab did not count itself"; return 1; }
    pass "$1: take_screen_grab refused with the phase closed, and counted the attempt"
  }
  check_passes "the only grab helper refuses when the phase is closed" assert_grab_refused x
  CAPTURE_GRABS=0
  CAPTURE_TEST_OPEN=0

  check_fails "captures interleaved with the moves are caught" \
    assert_capture_gated x "$SRC_INTERLEAVED"
  check_fails "three separate grabs are caught" \
    assert_capture_gated x "$SRC_THREE_GRABS"
  check_fails "captures with no disjointness system test at all are caught" \
    assert_capture_gated x "$SRC_NO_TEST"
  check_passes "one grab, after the system test, with nothing scored before it, is accepted" \
    assert_capture_gated x "$SRC_GOOD"
  check_fails "a display still off after the wake is caught" assert_display_on x 0 OFF
  check_fails "a display state that never read is caught" assert_display_on x 0 ""
  check_fails "a dozing display is caught" assert_display_on x 0 DOZE
  assert_screen_state_parse() {
    local got; got=$(screen_state_of "$2")
    [[ "$got" == "$3" ]] || { fail "$1: parsed mScreenState '$got', wanted '$3'"; return 1; }
    pass "$1: parsed mScreenState '$got'"
  }
  DUMP_TWO=$'Display Power Controller Locked State:\n  mScreenState=OFF\nDisplay 2:\n  mScreenState=ON'
  check_passes "the default display's state is the one read" assert_screen_state_parse x "$DUMP_TWO" OFF
  check_fails "another display's ON is not read as the default's" assert_screen_state_parse x "$DUMP_TWO" ON
  check_passes "a display read ON is accepted" assert_display_on x 0 ON
  SRC_WAKE=$'step 3\nassert_regions_disjoint "3e. x" x\n  CAPTURE_TEST_OPEN=1\n  for id in "${IDS[@]}"; do\n  assert_display_on "3k. instance 0" 0 ON\n  done\n  take_screen_grab /tmp/one.png out\n  for id in "${IDS[@]}"; do\n  assert_display_on "3l. instance 0" 0 ON\n  done\n'
  check_fails "a wake for one instance only is caught" assert_grab_after_wake x \
    $'step 3\n  CAPTURE_TEST_OPEN=1\n  for id in 0; do\n  assert_display_on "3k. instance 0" 0 ON\n  done\n  take_screen_grab /tmp/one.png out\n  for id in "${IDS[@]}"; do\n  assert_display_on "3l. instance 0" 0 ON\n  done\n'
  check_fails "a grab with no re-read after it is caught" assert_grab_after_wake x \
    "$(grep -v '3l\.' <<<"$SRC_WAKE")"
  check_passes "a wake between the system test and the grab is accepted" assert_grab_after_wake x "$SRC_WAKE"
  check_fails "a grab with no wake before it is caught" assert_grab_after_wake x \
    "$(grep -v 'assert_display_on' <<<"$SRC_WAKE")"
  check_fails "a wake after the grab is caught" assert_grab_after_wake x \
    $'step 3\n  CAPTURE_TEST_OPEN=1\n  take_screen_grab /tmp/one.png out\n  for id in "${IDS[@]}"; do\n  assert_display_on "3k. instance 0" 0 ON\n'
  check_passes "this system test's own step 3 wakes every display before its grab" \
    assert_grab_after_wake x "$(awk '/^step "3\./,/^step "4\./' "./$(basename "${BASH_SOURCE[0]}")")"

  check_passes "this system test's own step 3 system tests its captures" \
    assert_capture_gated x "$(awk '/^step "3\./,/^step "4\./' "./$(basename "${BASH_SOURCE[0]}")")"

  check_fails "an androidd.env missing both resident knobs is caught" \
    assert_resident_knobs x ""
  check_fails "an androidd.env missing only the dispatch knob is caught" \
    assert_resident_knobs x "RHIZO_RESIDENT_G=1"
  check_fails "a knob set to 0 is caught" \
    assert_resident_knobs x $'RHIZO_RESIDENT_G=0\nRHIZO_RESIDENT_DISPATCH=1'
  check_passes "both resident knobs present is accepted" \
    assert_resident_knobs x $'RHIZO_RESIDENT_G=1\nRHIZO_RESIDENT_DISPATCH=1'

  check_fails "a unit still deactivating when the peers are read is caught" \
    assert_unit_state x androidd@1.service deactivating inactive
  check_fails "a unit left failed by an overrun stop is caught" \
    assert_unit_state x androidd@1.service failed inactive
  check_fails "a stop whose state could not be read at all is caught" \
    assert_unit_state x androidd@1.service "" inactive

  check_fails "an instance left configured by an earlier run is caught" \
    assert_vm_instances_clear x $'1'
  check_fails "several left configured are caught" \
    assert_vm_instances_clear x $'1\n2\n9'
  check_passes "a vm with only instance 0 is accepted" \
    assert_vm_instances_clear x $'0'
  check_passes "a vm with nothing configured at all is accepted" \
    assert_vm_instances_clear x ""

  check_fails "the 'already configured' refusal is caught at the add" \
    assert_instance_added x 1 "[rhizo] FAIL: instance 1 is already configured: /etc/rhizo/instances/1.env exists"
  check_fails "the profile refusal is caught at the add" \
    assert_instance_added x 1 "[rhizo] FAIL: instance add 1 refused: rhizo.profile is desktop, not server;"
  check_fails "an add that printed nothing is caught" assert_instance_added x 1 ""
  check_passes "a real add is accepted" assert_instance_added x 1 "RHIZO_VM added=1"

  check_fails "the protocol fault a bound-but-dead server answers with is caught" \
    assert_guest_adb_server x "error: protocol fault (couldn't read status): Success" "LISTEN 0 4096 127.0.0.1:5037"
  check_fails "a server that answered nothing is caught" \
    assert_guest_adb_server x "" "no listener"
  check_passes "a server listing no devices still counts as answering" \
    assert_guest_adb_server x "List of devices attached" "LISTEN 0 4096 127.0.0.1:5037"
  check_passes "a server listing a device is accepted" \
    assert_guest_adb_server x $'List of devices attached\n192.168.100.50:5555\tdevice' "adb 1.0.41"

  check_fails "a profile apply that printed nothing is caught" \
    assert_profile_applied x "" "RHIZO_PROFILE profile=server"
  check_fails "the desktop profile reported by the apply path is caught" \
    assert_profile_applied x "RHIZO_PROFILE profile=desktop" "RHIZO_PROFILE profile=server"
  check_fails "an apply that claims server while show still says desktop is caught" \
    assert_profile_applied x "RHIZO_PROFILE profile=server" "RHIZO_PROFILE profile=desktop"
  check_fails "a show that answered nothing is caught" \
    assert_profile_applied x "RHIZO_PROFILE profile=server" ""
  check_passes "both halves reporting server is accepted" \
    assert_profile_applied x "RHIZO_PROFILE profile=server" "RHIZO_PROFILE profile=server"

  check_fails "a policy file with no [server] section is caught" \
    assert_idle_stop_off x $'[rhizo]\nprofile = server'
  check_fails "the server profile's default 600s detector left armed is caught" \
    assert_idle_stop_off x $'[rhizo]\nprofile = server\n[server]\nidle_stop_s = 600'
  check_fails "an unparseable policy file is caught" \
    assert_idle_stop_off x "idle_stop_s = 0"
  check_fails "an empty policy read is caught" assert_idle_stop_off x ""
  check_passes "idle_stop_s = 0 is accepted" \
    assert_idle_stop_off x $'[rhizo]\nprofile = server\n[server]\nidle_stop_s = 0'

  check_fails "an adb-key add that registered nothing is caught" \
    assert_adb_key_registered x "RHIZO_ADBKEY added=0" "RHIZO_ADBKEY list=1"
  check_passes "a key this run did not add but an earlier one did is accepted" \
    assert_adb_key_registered x "[rhizo] already registered, skipping 37:37:78:6C
RHIZO_ADBKEY added=0" "RHIZO_ADBKEY list=2"
  check_fails "an already-registered claim with nothing on file is caught" \
    assert_adb_key_registered x "[rhizo] already registered, skipping 37:37:78:6C
RHIZO_ADBKEY added=0" "RHIZO_ADBKEY list=0"
  check_fails "an adb-key add that failed outright is caught" \
    assert_adb_key_registered x "cannot read /root/.android/adbkey.pub" "RHIZO_ADBKEY list=0"
  check_fails "an empty key list after a claimed add is caught" \
    assert_adb_key_registered x "RHIZO_ADBKEY added=1" "RHIZO_ADBKEY list=0"
  check_fails "a list that answered nothing is caught" \
    assert_adb_key_registered x "RHIZO_ADBKEY added=1" ""
  check_passes "one added and one registered key is accepted" \
    assert_adb_key_registered x "RHIZO_ADBKEY added=1" "RHIZO_ADBKEY list=1"

  check_fails "an output too narrow for one window per instance is caught" \
    assert_output_fits x 1920 3 960
  check_fails "an output width the compositor never reported is caught" \
    assert_output_fits x "" 3 960
  check_passes "an output wide enough for three windows is accepted" \
    assert_output_fits x 2880 3 960

  check_fails "instance 1's own write never taking is caught" \
    assert_property_isolated x "instance1-marker-abc123" "" "" "1"
  check_fails "instance 2's dead getprop channel is caught (empty liveness read)" \
    assert_property_isolated x "instance1-marker-abc123" "instance1-marker-abc123" "" ""
  check_fails "instance 2 reading instance 1's own property is caught" \
    assert_property_isolated x "instance1-marker-abc123" "instance1-marker-abc123" "instance1-marker-abc123" "16"
  check_passes "instance 1's write took, instance 2's channel is live, and it read nothing of instance 1's" \
    assert_property_isolated x "instance1-marker-abc123" "instance1-marker-abc123" "" "16"

  check_fails "a unit not in the wanted state is caught" assert_unit_state x androidd.service failed active
  check_passes "a unit in the wanted state is accepted" assert_unit_state x androidd.service active active
  check_fails "a peer that did not actually stop is caught" assert_unit_state x androidd@1.service active inactive
  check_passes "a peer that really stopped is accepted" assert_unit_state x androidd@1.service inactive inactive

  check_fails "a changed freeze bit is caught" assert_freeze_state_unchanged x 2 1 0
  check_passes "an unchanged freeze bit is accepted" assert_freeze_state_unchanged x 2 1 1

  check_fails "a replacement that never landed inside the poll's deadline is caught" \
    assert_pool_replacement_observed x 1 "$POOL_REPLACE_TIMEOUT_S" 1 ""
  check_passes "a replacement observed inside the deadline is accepted" \
    assert_pool_replacement_observed x 0 "$POOL_REPLACE_TIMEOUT_S" 1 $'7'

  check_fails "an allocated id still listed as a member is caught" \
    assert_pool_allocate_replaced x 3 $'3\n7' ""
  check_fails "no replacement filling the pool is caught" \
    assert_pool_allocate_replaced x 3 "" ""
  check_fails "a replacement still only reserved is not read as a member" \
    assert_pool_allocate_replaced x 3 "" $'7'
  check_fails "an id listed as both a member and a reservation is caught" \
    assert_pool_allocate_replaced x 3 $'7' $'7'
  check_passes "the allocated id gone, a replacement promoted, is accepted" \
    assert_pool_allocate_replaced x 3 $'7' ""

  check_fails "a pool status with no pending= count at all is caught" \
    assert_pool_reservation_drained x "RHIZO_POOL k=1 members=1" ""
  check_fails "an empty pool status is caught" \
    assert_pool_reservation_drained x "" ""
  check_fails "a reservation still held after the replacement settled is caught" \
    assert_pool_reservation_drained x "RHIZO_POOL k=1 members=1 pending=1" $'7'
  check_fails "a pending= count that disagrees with the file is caught" \
    assert_pool_reservation_drained x "RHIZO_POOL k=1 members=1 pending=0" $'7'
  check_passes "pending=0 and an empty reservation file is accepted" \
    assert_pool_reservation_drained x "RHIZO_POOL k=1 members=1 pending=0" ""

  check_fails "a replacement that ran as no unit at all is caught" \
    assert_pool_replacement_unit x 3 "" "" "2026-09-19 04:00:00"
  check_fails "another instance's replacement unit does not stand in for this one" \
    assert_pool_replacement_unit x 3 "rhizo-pool-replace-9.service loaded active running" "" "2026-09-19 04:00:00"
  check_passes "the replacement unit seen live is accepted" \
    assert_pool_replacement_unit x 3 "rhizo-pool-replace-3.service loaded active running" "" "2026-09-19 04:00:00"
  check_passes "the replacement unit is accepted on a journal line NAMING it" \
    assert_pool_replacement_unit x 3 "" "Started rhizo-pool-replace-3.service." "2026-09-19 04:00:00"
  check_fails "journalctl's own \"-- No entries --\" is not a replacement unit" \
    assert_pool_replacement_unit x 3 "" "-- No entries --" "2026-09-19 04:00:00"
  check_fails "a journal carrying another unit's lines is not this one's" \
    assert_pool_replacement_unit x 3 "" "Started rhizo-pool-replace-9.service." "2026-09-19 04:00:00"
  check_fails "an unbounded journal read is caught, however full it is" \
    assert_pool_replacement_unit x 3 "" "Started rhizo-pool-replace-3.service." ""

  check_fails "a clone with no fixture package is caught" assert_clone_has_app x "package:com.android.settings"
  check_passes "a clone carrying the fixture package is accepted" assert_clone_has_app x \
    $'package:com.android.settings\npackage:com.rhizo.fps'

  check_fails "a missing value is caught" assert_present x "no answer from the guest" ""
  check_passes "a present value is accepted" assert_present x "no answer from the guest" "64"

  CG_FIXTURE_DIR=$(mktemp -d)
  CG_FIX="$CG_FIXTURE_DIR/rhizo-1"
  mkdir -p "$CG_FIX/launcher" "$CG_FIX/init" "$CG_FIX/system" "$CG_FIX/apps/uid_10100/pid_4002"
  : >"$CG_FIX/cgroup.procs"
  echo 900 >"$CG_FIX/launcher/cgroup.procs"
  printf '940\n941\n' >"$CG_FIX/init/cgroup.procs"
  : >"$CG_FIX/system/cgroup.procs"
  echo 4002 >"$CG_FIX/apps/uid_10100/pid_4002/cgroup.procs"
  PROC_FIX="$CG_FIXTURE_DIR/proc"
  mkdir -p "$PROC_FIX/900" "$PROC_FIX/940" "$PROC_FIX/941" "$PROC_FIX/4002"
  echo python3 >"$PROC_FIX/900/comm"
  echo python3 >"$PROC_FIX/940/comm"
  echo init    >"$PROC_FIX/941/comm"
  echo rhizo-composer >"$PROC_FIX/4002/comm"
  PROC_FIX_NO_INIT="$CG_FIXTURE_DIR/proc-no-init"
  mkdir -p "$PROC_FIX_NO_INIT/900" "$PROC_FIX_NO_INIT/940" "$PROC_FIX_NO_INIT/941"
  echo python3 >"$PROC_FIX_NO_INIT/900/comm"
  echo python3 >"$PROC_FIX_NO_INIT/940/comm"
  echo python3 >"$PROC_FIX_NO_INIT/941/comm"

  assert_cgroup_pids_read() {
    local got; got=$(cgroup_pids_from_tree "$2" | tr '\n' ',')
    [[ "$got" == "$3" ]] || { fail "$1: the pid read returned '${got:-<empty>}', wanted '${3:-<empty>}'"; return 1; }
    pass "$1: the pid read returned '${got:-<empty>}'"
  }
  assert_root_only_read() {
    local got; got=$(cat "$2/cgroup.procs" 2>/dev/null | tr '\n' ',')
    [[ "$got" == "$3" ]] || { fail "$1: the root-only read returned '${got:-<empty>}', wanted '${3:-<empty>}'"; return 1; }
    pass "$1: the root-only read returned '${got:-<empty>}'"
  }
  assert_cgroup_init_pid() {
    local got; got=$(cgroup_init_pid_from_tree "$2" "$3")
    [[ "$got" == "$4" ]] || { fail "$1: init resolved to '${got:-<empty>}', wanted '${4:-<empty>}'"; return 1; }
    pass "$1: init resolved to '${got:-<empty>}'"
  }

  check_passes "the pid read finds every pid under the stack root, at every depth" \
    assert_cgroup_pids_read x "$CG_FIX" "900,940,941,4002,"
  check_fails "a pid read that missed the deeper leaves is caught" \
    assert_cgroup_pids_read x "$CG_FIX" "900,940,941,"
  check_passes "the read this replaced finds NOTHING on that same tree -- for instance 0 first" \
    assert_root_only_read x "$CG_FIX" ""
  check_fails "the root-only driver is a real comparison, not a tautology" \
    assert_root_only_read x "$CG_FIX" "900,"
  check_passes "a cgroup root that is not there reads as nothing, never as a stray pid" \
    assert_cgroup_pids_read x "$CG_FIXTURE_DIR/never" ""
  check_passes "init is resolved by comm, out of this instance's own tree" \
    assert_cgroup_init_pid x "$CG_FIX" "$PROC_FIX" "941"
  check_fails "resolving init as the LOWEST pid in the tree is caught -- that is the launcher" \
    assert_cgroup_init_pid x "$CG_FIX" "$PROC_FIX" "900"
  check_passes "a tree whose Android init has not appeared yet resolves to nothing" \
    assert_cgroup_init_pid x "$CG_FIX" "$PROC_FIX_NO_INIT" ""
  assert_cgroup_sh_cmd() {
    local label="$1" want="$2"; shift 2
    local got; got=$(bash -c "$(cgroup_sh_cmd "$@")")
    [[ "$got" == "$want" ]] || { fail "$label: the guest command line returned '${got:-<empty>}', wanted '${want:-<empty>}'"; return 1; }
    pass "$label: the guest command line returned '${got:-<empty>}'"
  }
  check_passes "the command line sent to the guest carries the program and its arguments intact" \
    assert_cgroup_sh_cmd x "941" 'cgroup_init_pid "$1" "$2"' "$CG_FIX" "$PROC_FIX"
  rm -rf "$CG_FIXTURE_DIR"

  MK=$'[   10.500000] L3: RHIZO_MARKER launch_start sandbox=1\n[   20.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=1\n[   21.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=10'
  if boot_completed_seen_local 1 15 "$MK"; then log "  selftest OK: a marker after the mark is this run's boot"
  else fail "selftest: instance 1's marker after the mark was not seen"; fi
  if boot_completed_seen_local 1 20.5 "$MK"; then fail "selftest: a marker BEFORE the mark counted as this run's boot"
  else log "  selftest OK: a marker before the mark is an earlier boot's"; fi
  if boot_completed_seen_local 0 15 "$MK"; then fail "selftest: instance 1's and 10's markers satisfied instance 0"
  else log "  selftest OK: another instance's marker does not count (sandbox=1 and =10 for id 0)"; fi
  if boot_completed_seen_local 1 15 $'[   30.0] init: nothing here'; then fail "selftest: a log with no marker read as boot completed"
  else log "  selftest OK: no marker, no boot"; fi

  assert_live_writer_keys_match() {
    local saved="$ASSERT_LOG" tmp lab rc
    tmp=$(mktemp)
    ASSERT_LOG="$tmp"
    for lab in "${REQUIRED_ASSERTIONS[@]}"; do
      case "$2" in
        bare)     pass "$lab: the shape 0b./5c./5d./7b./7c./7d./7e./8b. use" >/dev/null ;;
        suffixed) pass "$lab androidd@1.service: the shape 0c./3g. use" >/dev/null ;;
      esac
    done
    ASSERT_LOG="$saved"
    assert_all_steps_asserted "$1" "$(cat "$tmp")" "${REQUIRED_ASSERTIONS[@]}"
    rc=$?
    rm -f "$tmp"
    return "$rc"
  }
  check_passes "every required label written BARE by the real pass() is matched by the real log check" \
    assert_live_writer_keys_match x bare
  check_passes "every required label written with its own text by the real pass() is matched too" \
    assert_live_writer_keys_match x suffixed

  assert_live_writer_missing_one() {
    local saved="$ASSERT_LOG" tmp lab rc
    tmp=$(mktemp)
    ASSERT_LOG="$tmp"
    for lab in "${REQUIRED_ASSERTIONS[@]:1}"; do
      pass "$lab: a bare label" >/dev/null
    done
    ASSERT_LOG="$saved"
    assert_all_steps_asserted "$1" "$(cat "$tmp")" "${REQUIRED_ASSERTIONS[@]}"
    rc=$?
    rm -f "$tmp"
    return "$rc"
  }
  check_fails "a required label the run never wrote is caught, on the real labels" \
    assert_live_writer_missing_one x

  assert_key_is() {
    local got; got=$(_log_key "$2")
    [[ "$got" == "$3" ]] || { fail "$1: _log_key '$2' = '$got', wanted '$3'"; return 1; }
    pass "$1: _log_key '$2' = '$got'"
  }
  check_passes "a bare label keys on its dot, not on the colon after it" \
    assert_key_is x "5c.: instance 0's cgroup.freeze state unchanged (1)" "5c."
  check_passes "a label carrying its own text keys the same way" \
    assert_key_is x "0c. androidd@1.service: instance 1's own recorded cgroup root is /sys/fs/cgroup/x" "0c."
  check_passes "a two-character step number keys whole" \
    assert_key_is x "10a. the assertion log: every assertion decided" "10a."
  check_passes "a sub-lettered label keys whole" \
    assert_key_is x "0b2. the compositor output: 2880px wide" "0b2."
  check_passes "a message quoting a multi-line artifact still keys on one line" \
    assert_key_is x "$(printf '0pre2. the idle detector: read back\n[rhizo]\nprofile = server')" "0pre2."
  assert_key_is_single_line() {
    local got n
    got=$(_log_key "$2")
    n=$(printf '%s' "$got" | grep -c '' )
    (( n <= 1 )) || { fail "$1: the key spans $n lines ('$got')"; return 1; }
    pass "$1: the key is one line ('$got')"
  }
  check_passes "even a label with no dot at all keys to one line" \
    assert_key_is_single_line x "$(printf 'no dot here\nsecond line. with a dot')"

  LOG_FULL=$'PASS\t0a.\nFAIL\t0b.\nPASS\t1a.\nPASS\t2a.'
  LOG_MISSING_1A=$'PASS\t0a.\nFAIL\t0b.\nPASS\t2a.'
  check_passes "a log carrying every required label is accepted" \
    assert_all_steps_asserted x "$LOG_FULL" 0a. 0b. 1a. 2a.
  check_fails "an assertion that decided nothing at all is caught" \
    assert_all_steps_asserted x "$LOG_MISSING_1A" 0a. 0b. 1a. 2a.
  check_fails "an empty log is caught" \
    assert_all_steps_asserted x "" 0a. 0b. 1a. 2a.
  check_passes "a FAIL counts as having decided, exactly like a PASS" \
    assert_all_steps_asserted x $'FAIL\t1a.' 1a.
  check_fails "a longer label does not satisfy a shorter required one" \
    assert_all_steps_asserted x $'PASS\t1a.b' 1a.

  if (( FAILED )); then
    log "test-multi-instance --selftest: FAILED with $FAILED failure(s)"
    exit 1
  fi
  log "test-multi-instance --selftest: PASSED"
  exit 0
fi

if (( SELFTEST )); then
  fail "0. --selftest fell through its own block instead of exiting"
  test_record_verdict FAILED
  exit 1
fi

RELEASE="${RHIZO_RELEASE:-a16}"
LOOP_MAX_WANT=$(loop_max_loop_for_instances "$RELEASE" "$LOOP_BUDGET_INSTANCES")
export RHIZO_LOOP_MAX_LOOP="$LOOP_MAX_WANT"

if (( ! SKIP_BOOT )); then
  test_boot --release "$RELEASE" || { fail "boot failed"; test_record_verdict FAILED; exit 1; }
fi
printf '%s\n' '<not reached>' >"$EV/profile-desktop-0pre.log"
printf '%s\n' '<not reached>' >"$EV/profile-desktop-cleanup.log"
rm -f "$EV"/journal-*.log "$EV"/boot-full-*.log "$EV"/logcat-*.log
printf '%s\n' '<not reached>' >"$EV/supervisor.log"
printf '%s\n' '<not reached>' >"$EV/sway.log"
for _id in "${INSTANCE_EVIDENCE_IDS[@]}"; do
  printf '%s\n' '<not reached>' >"$EV/journal-$_id.log"
  printf '%s\n' '<not reached>' >"$EV/boot-full-$_id.log"
  printf '%s\n' '<not reached>' >"$EV/logcat-$_id.log"
done
vm_reset_instances prestage

../../vm/sync.sh >/dev/null || { fail "0. sync.sh failed"; test_record_verdict FAILED; exit 1; }
STAGE_LOG="$EV/redeploy-stage.log"
WAYLAND_RENDEZVOUS="${RHIZO_WAYLAND_HOST_DIR:-/run/rhizo-wayland}/wayland-0"
if ! RHIZO_WAYLAND_HOST_SOCKET="$WAYLAND_RENDEZVOUS" ../../vm/redeploy.sh --skip-kill --no-launch > "$STAGE_LOG" 2>&1; then
  fail "0. redeploy.sh --no-launch failed -- see $STAGE_LOG"
  test_record_verdict FAILED
  exit 1
fi
test_require_staged rhizo-fps.apk || exit 1

step "0pre. a clean vm, then the host contract instances 1 and 2 need"
vm_reset_instances 0pre
assert_vm_instances_clear "0pre0. the vm this run starts from" "$(vm_configured_ids)"
PROFILE_OUT=$(ssh_vm -t 120 "rhizo profile server" 2>&1)
printf '%s\n' "${PROFILE_OUT:-<none>}" >"$EV/profile-server.log"
PROFILE_SHOW=$(ssh_vm -t 30 "rhizo profile show" 2>&1)
printf '%s\n' "${PROFILE_SHOW:-<none>}" >"$EV/profile-show.log"
assert_profile_applied "0pre1. rhizo profile server" "$PROFILE_OUT" "$PROFILE_SHOW"

POLICY_CMD="install -d -m 0755 /etc/rhizo"
POLICY_CMD+=$'\n'": > /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"echo '[rhizo]' >> /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"echo 'profile = server' >> /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"echo '[server]' >> /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"echo 'idle_stop_s = 0' >> /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"cat /etc/rhizo/policy.conf"
POLICY_TEXT=$(ssh_vm -t 30 "$POLICY_CMD" 2>&1)
printf '%s\n' "${POLICY_TEXT:-<none>}" >"$EV/policy-conf.txt"
assert_idle_stop_off "0pre2. the idle detector the server profile enables" "$POLICY_TEXT"

ADBKEY_OUT=$(ssh_vm -t 60 "mkdir -p /root/.android; [ -s /root/.android/adbkey.pub ] || adb keygen /root/.android/adbkey >/dev/null 2>&1; rhizo adb-key add /root/.android/adbkey.pub" 2>&1)
ADBKEY_LIST=$(ssh_vm -t 30 "rhizo adb-key list" 2>&1)
printf '%s\n%s\n' "${ADBKEY_OUT:-<none>}" "${ADBKEY_LIST:-<none>}" >"$EV/adb-key.log"
assert_adb_key_registered "0pre3. the guest adb server's own key" "$ADBKEY_OUT" "$ADBKEY_LIST"

ANDROIDD_ENV_CMD="grep -Ev '^(RHIZO_RESIDENT_G|RHIZO_RESIDENT_DISPATCH)=' /root/androidd.env > /root/androidd.env.test-tmp 2>/dev/null || : > /root/androidd.env.test-tmp"
ANDROIDD_ENV_CMD+=$'\n'"echo 'RHIZO_RESIDENT_G=1' >> /root/androidd.env.test-tmp"
ANDROIDD_ENV_CMD+=$'\n'"echo 'RHIZO_RESIDENT_DISPATCH=1' >> /root/androidd.env.test-tmp"
ANDROIDD_ENV_CMD+=$'\n'"mv /root/androidd.env.test-tmp /root/androidd.env || echo RHIZO_ENV_MV_FAILED"
ANDROIDD_ENV_CMD+=$'\n'"cat /root/androidd.env"
ANDROIDD_ENV_TEXT=$(ssh_vm -t 30 "$ANDROIDD_ENV_CMD" 2>&1)
printf '%s\n' "${ANDROIDD_ENV_TEXT:-<none>}" >"$EV/androidd-env.txt"
assert_resident_knobs "0pre5. the unit path's resident knobs" "$ANDROIDD_ENV_TEXT"
if grep -q 'RHIZO_ENV_MV_FAILED' <<<"$ANDROIDD_ENV_TEXT"; then
  fail "0pre5b. the environment file was published, not left as the old one: the mv failed"
elif grep -q '^RHIZO_WIPE_DATA=' <<<"$ANDROIDD_ENV_TEXT"; then
  pass "0pre5b. redeploy.sh's own record survived the merge"
else
  fail "0pre5b. redeploy.sh's own record survived the merge: no RHIZO_WIPE_DATA= line"
fi
if grep -qx "RHIZO_WAYLAND_HOST_SOCKET=$WAYLAND_RENDEZVOUS" <<<"$ANDROIDD_ENV_TEXT"; then
  pass "0pre5c. every instance's launcher is told the compositor socket"
else
  fail "0pre5c. /root/androidd.env carries no RHIZO_WAYLAND_HOST_SOCKET=$WAYLAND_RENDEZVOUS"
fi

ssh_vm -t 60 "setsid adb start-server </dev/null >/dev/null 2>&1" >/dev/null 2>&1
ADB_DEVICES=$(ssh_vm -t 30 "adb devices" 2>&1)
ADB_SERVER=$(ssh_vm -t 20 "ss -lntp 'sport = :5037' 2>/dev/null | tail -2; pgrep -a adb 2>/dev/null | head -3; adb --version 2>&1 | head -1" 2>&1)
printf '%s\n---\n%s\n' "${ADB_DEVICES:-<none>}" "${ADB_SERVER:-<none>}" >"$EV/adb-server.log"
assert_guest_adb_server "0pre4. the guest adb server every step below speaks through" "$ADB_DEVICES" "$ADB_SERVER"

step "0. size loop.max_loop for the $LOOP_BUDGET_INSTANCES instances this run can configure, then start the three under test"
LOOP_MAX=$(ssh_vm -t 10 "$GUEST_LOOP_MAX_READ" 2>/dev/null | tr -d '[:space:]')
assert_present "0a. /sys/module/loop/parameters/max_loop is readable" \
  "no answer from the guest" "$LOOP_MAX"
assert_loop_max_sized "0b." "$LOOP_MAX" "$LOOP_MAX_WANT"

SWAY_PROBE='_u=$(cat /etc/rhizo/desktop-user 2>/dev/null || echo ubuntu); _rd=/run/user/$(id -u "$_u" 2>/dev/null || echo 1000); XDG_RUNTIME_DIR=$_rd SWAYSOCK=$(ls $_rd/sway-ipc.* 2>/dev/null | head -1) swaymsg -t get_version'
if ssh_vm -t 10 "$SWAY_PROBE" >/dev/null 2>&1; then
  pass "0b1. the compositor is already up on this vm"
else
  SWAY_INSTANCE_ARGS=()
  for id in "${IDS[@]}"; do
    [[ "$id" == 0 ]] || SWAY_INSTANCE_ARGS+=(--instance "$id")
  done
  ../../vm/start/start-sway.sh --size "$SWAY_OUTPUT_SIZE" "${SWAY_INSTANCE_ARGS[@]}" >"$EV/start-sway.log" 2>&1
  SWAY_VERSION=$(ssh_vm -t 10 "$SWAY_PROBE" 2>/dev/null)
  assert_present "0b1. the compositor answers after start-sway.sh" \
    "sway did not start -- see $EV/start-sway.log" \
    "$SWAY_VERSION"
fi
SWAY_OUTPUT_W=$(gcmd_user "swaymsg -t get_outputs" 20 2>/dev/null \
  | python3 -c "import json,sys
try: o=json.load(sys.stdin)
except Exception: raise SystemExit
for d in o:
    r=d.get('rect') or {}
    print(r.get('width',0)); break" 2>/dev/null)
echo "${SWAY_OUTPUT_W:-<none>}" >"$EV/sway-output-width.txt"
assert_output_fits "0b2. the compositor output" "$SWAY_OUTPUT_W" "${#IDS[@]}" "$SWAY_WINDOW_W"

for id in 1 2; do
  ADD_OUT=$(ssh_vm -t 60 "rhizo instance add $id" 2>&1)
  printf '%s\n' "${ADD_OUT:-<none>}" >"$EV/instance-add-$id.log"
  assert_instance_added "0f. instance $id" "$id" "$ADD_OUT"
done
KMSG_MARK0=$(ssh_vm -t 10 "cut -d' ' -f1 /proc/uptime" 2>/dev/null | tr -dc '0-9.')
CG_START_EPOCH=$(ssh_vm -t 10 "date +%s" 2>/dev/null | tr -dc '0-9')
printf '%s\n' "${KMSG_MARK0:-<none>}" >"$EV/kmsg-mark-start.txt"
ssh_vm -t 300 "systemctl start androidd.service" >"$EV/start-0.log" 2>&1
ssh_vm -t 300 "systemctl start androidd@1.service" >"$EV/start-1.log" 2>&1
ssh_vm -t 300 "systemctl start androidd@2.service" >"$EV/start-2.log" 2>&1

declare -A BC=() BCNOTE=() CG=() INITPID=()
for id in "${IDS[@]}"; do
  unit=$(unit_for "$id")
  cg="" cg_read=""
  DEADLINE=$(( SECONDS + 120 ))
  while (( SECONDS < DEADLINE )); do
    cg_read=$(ssh_vm -t 10 "f=$(cgroup_root_file_for "$id"); [ -s \$f ] && echo \$(stat -c %Y \$f) \$(cat \$f)" 2>/dev/null | tr -d '\r')
    read -r _mt cg <<<"$cg_read"
    cg="${cg%/}"
    [[ -n "$cg" && "$_mt" =~ ^[0-9]+$ && "$CG_START_EPOCH" =~ ^[0-9]+$ ]] && (( _mt >= CG_START_EPOCH )) && break
    sleep 2
  done
  assert_cgroup_record "0c. $unit" "$id" "$cg_read" "$CG_START_EPOCH" || continue
  CG[$id]="$cg"
  bc=$(boot_completed_read "$id" "${KMSG_MARK0:-999999}" 300)
  BC[$id]="$bc"
  BCNOTE[$id]="$BOOT_READ_NOTE"
  INITPID[$id]=$(cgroup_sh_remote 10 'cgroup_init_pid "$1"' "$cg" 2>/dev/null | tr -d '[:space:]')
  ssh_vm -t 20 "tail -120 $(boot_log_for "$id") 2>/dev/null" >"$EV/boot-$id.log" 2>&1
  assert_boot_completed_id "0d. $unit" "$id" "${BC[$id]}" "${BCNOTE[$id]:-}"
done

ssh_vm -t 30 "
  pkill -f '[a]db -L tcp:5037' >/dev/null 2>&1
  for _i in \$(seq 1 20); do
    ss -lnt 'sport = :5037' 2>/dev/null | grep -q ':5037' || break
    sleep 0.5
  done
  pkill -9 -f '[a]db -L tcp:5037' >/dev/null 2>&1
  setsid adb start-server </dev/null >/dev/null 2>&1
" >/dev/null 2>&1
ADB_DEVICES_POST=$(ssh_vm -t 30 "adb devices" 2>&1)
ADB_SERVER_POST=$(ssh_vm -t 20 "ss -lntp 'sport = :5037' 2>/dev/null | tail -2; pgrep -a adb 2>/dev/null | head -3; ps -o label= -C adb 2>/dev/null | head -1" 2>&1)
printf '%s\n---\n%s\n' "${ADB_DEVICES_POST:-<none>}" "${ADB_SERVER_POST:-<none>}" >"$EV/adb-server-postflip.log"
assert_guest_adb_server "0g. the guest adb server restarted after the enforcement flip" "$ADB_DEVICES_POST" "$ADB_SERVER_POST"

CG_LIST=()
for id in "${IDS[@]}"; do CG_LIST+=("${CG[$id]:-}"); done
printf '%s\n' "${CG_LIST[@]}" >"$EV/cgroup-roots.txt"
if ! assert_cgroups_distinct "0e. the three recorded cgroup roots" "${CG_LIST[@]}"; then
  log "  the recorded roots are in $EV/cgroup-roots.txt"
fi

step "1. distinct network identity per instance"
# print the IPv4 address of an instance veth
veth_addr() {
  ssh_vm -t 10 "ip -4 -o addr show vethrhz$1" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1
}
V0=""; V1=""; V2=""
veth_started=$SECONDS
while (( SECONDS - veth_started < 120 )); do
  [[ -z "$V0" ]] && V0=$(veth_addr 0)
  [[ -z "$V1" ]] && V1=$(veth_addr 1)
  [[ -z "$V2" ]] && V2=$(veth_addr 2)
  [[ -n "$V0" && -n "$V1" && -n "$V2" ]] && break
  sleep 5
done
log "    veth addresses after $(( SECONDS - veth_started ))s: 0='${V0:-<none>}' 1='${V1:-<none>}' 2='${V2:-<none>}'"
printf 'vethrhz0=%s\nvethrhz1=%s\nvethrhz2=%s\n' "${V0:-<none>}" "${V1:-<none>}" "${V2:-<none>}" \
  >"$EV/veth-addresses.txt"
if ! assert_distinct_veth "1a. host veth addresses" "$V0" "$V1" "$V2"; then
  log "  step 1's addresses are in $EV/veth-addresses.txt"
fi

step "2. adb connect to all three, launch the fixture in each"
for id in "${IDS[@]}"; do
  ep=$(adb_ep_for "$id")
  out=$(ssh_vm -t 20 "adb connect $ep" 2>&1)
  assert_adb_connected "2a. instance $id" "$id" "$out"
  ssh_vm -t 60 "adb -s $ep install -r -g /root/share/rhizo-fps.apk" >"$EV/install-$id.log" 2>&1
  launch_out=$(ssh_vm -t 30 "adb -s $ep shell am start -W -n $FIXTURE_ACT -e scene ${SCENE_FOR[$id]}" 2>&1)
  assert_launch_ok "2b. instance $id (scene ${SCENE_FOR[$id]})" "$id" "$launch_out"
done

step "3. a per-instance marker via each instance's OWN composer client target (never screencap)"
# print the sway rectangle for a cgroup root
instance_window_rect() {
  local cg="$1" pids b64
  pids=$(cgroup_sh_remote 10 'cgroup_pids "$1"' "$cg" 2>/dev/null | tr -d ' ' | tr '\n' ',')
  [[ "$pids" =~ ^[0-9,]+$ ]] || return 1
  b64=$(printf '%s' "$WINDOW_RECT_PY" | base64 -w0)
  gcmd_user "swaymsg -t get_tree | python3 -c \"import base64;exec(base64.b64decode('$b64').decode())\" $pids" 20
}

declare -A MARKER=() REGION=() LAYOUT_NOTE=() RECT_OF=()

for id in "${IDS[@]}"; do
  assert_display_on "3j. instance $id" "$id" "$(wake_display "$id")"
done

SLOT=0
for id in "${IDS[@]}"; do
  echo "<none>" >"$EV/composer-$id-pngstat.txt"
  echo "<none>" >"$EV/composer-$id-pngstat-stderr.txt"
  echo "<none>" >"$EV/composer-$id-rect.txt"
  rm -f "$EV/composer-$id.png"
  MARKER[$id]=""
  REGION[$id]=""
  RECT_OF[$id]=""
  LAYOUT_NOTE[$id]="instance $id: <not resolved>"
  [[ -n "${CG[$id]:-}" ]] || { fail "3a. instance $id: no recorded cgroup root"; SLOT=$(( SLOT + 1 )); continue; }
  FOUND=""
  DEADLINE=$(( SECONDS + 60 ))
  while (( SECONDS < DEADLINE )); do
    FOUND=$(instance_window_rect "${CG[$id]}") && [[ -n "$FOUND" ]] && break
    FOUND=""
    sleep 2
  done
  read -r CON _RX _RY _RW _RH FLOATSTATE PLAYOUT <<<"${FOUND:-}"
  if [[ "$CON" =~ ^[0-9]+$ ]] && (( CON > 0 )); then
    if [[ "${_RW:-}x${_RH:-}" != "${SWAY_WINDOW_W}x${SWAY_WINDOW_H}" ]]; then
      log "    3a0. instance $id: mapped at ${_RW:-?}x${_RH:-?}, not ${SWAY_WINDOW_W}x${SWAY_WINDOW_H} -- resizing it once"
      gcmd_user "swaymsg '[con_id=$CON] resize set $SWAY_WINDOW_W $SWAY_WINDOW_H'" 15 >/dev/null 2>&1
      sleep 0.3
    fi
    gcmd_user "swaymsg '[con_id=$CON] move position $(( SLOT * SWAY_WINDOW_W )) 0'" 15 >/dev/null 2>&1
    sleep 0.3
  fi
  MARKER[$id]="${CON:-}"
  SLOT=$(( SLOT + 1 ))
done

for id in "${IDS[@]}"; do
  [[ -n "${CG[$id]:-}" ]] || continue
  FOUND=$(instance_window_rect "${CG[$id]}")
  read -r CON RX RY RW RH FLOATSTATE PLAYOUT <<<"${FOUND:-}"
  LAYOUT_NOTE[$id]="instance $id: con=${CON:-none} ${FLOATSTATE:-?} in a ${PLAYOUT:-?} container at ${RX:-?},${RY:-?} ${RW:-?}x${RH:-?}"
  echo "${FOUND:-<none>}" >"$EV/composer-$id-rect.txt"
  RECT_OF[$id]=""
  [[ -n "${FOUND:-}" ]] && RECT_OF[$id]="$RX $RY $RW $RH"
  assert_window_rect "3a. instance $id" "$id" "${RECT_OF[$id]}" || continue
  MARKER[$id]="${CON:-}"
  REGION[$id]="$id:${RECT_OF[$id]}"
done

assert_marker_distinct "3b. instance 0" 0 "${MARKER[0]}" "${MARKER[1]}" "${MARKER[2]}"
assert_marker_distinct "3c. instance 1" 1 "${MARKER[1]}" "${MARKER[0]}" "${MARKER[2]}"
assert_marker_distinct "3d. instance 2" 2 "${MARKER[2]}" "${MARKER[0]}" "${MARKER[1]}"

SWAY_NOTE="${LAYOUT_NOTE[0]}; ${LAYOUT_NOTE[1]}; ${LAYOUT_NOTE[2]}"
printf '%s\n' "$SWAY_NOTE" >"$EV/sway-layout.txt"
if assert_regions_disjoint "3e. the three scored regions" "$SWAY_NOTE" \
     "${REGION[0]}" "${REGION[1]}" "${REGION[2]}"; then

  CAPTURE_TEST_OPEN=1

  for id in "${IDS[@]}"; do
    assert_display_on "3k. instance $id" "$id" "$(wake_display "$id")"
  done

  rm -f "$EV/composer.png"
  take_screen_grab "/tmp/rhizo-multi-instance-composer.png" "$EV/composer.png"
  GRAB_RC=$?
  for id in "${IDS[@]}"; do
    assert_display_on "3l. instance $id" "$id" "$(display_screen_state "$id")"
  done
  if (( GRAB_RC == 2 )); then
    fail "3f. a screen grab was taken with the capture phase closed"
  elif (( GRAB_RC != 0 )); then
    fail "3f. grim produced no screenshot of the compositor output all three composers present into"
  else
    PNG_BYTES=$(stat -c %s "$EV/composer.png" 2>/dev/null || echo 0)
    assert_present "3f. the single screen grab all three regions are scored from" \
      "grim wrote nothing to $EV/composer.png" \
      "$(( PNG_BYTES > 0 ? PNG_BYTES : 0 ))"
    SWAY_NOTE_AFTER=""
    for id in "${IDS[@]}"; do
      [[ -n "${CG[$id]:-}" ]] || { SWAY_NOTE_AFTER+="instance $id: <not resolved>; "; continue; }
      FOUND=$(instance_window_rect "${CG[$id]}")
      read -r CON RX RY RW RH FLOATSTATE PLAYOUT <<<"${FOUND:-}"
      SWAY_NOTE_AFTER+="instance $id: con=${CON:-none} ${FLOATSTATE:-?} in a ${PLAYOUT:-?} container at ${RX:-?},${RY:-?} ${RW:-?}x${RH:-?}; "
    done
    SWAY_NOTE_AFTER="${SWAY_NOTE_AFTER%; }"
    printf '%s\n' "$SWAY_NOTE_AFTER" >"$EV/sway-layout-after-grab.txt"
    assert_layout_stable "3h. the layout across the grab" "$SWAY_NOTE" "$SWAY_NOTE_AFTER"

    for id in "${IDS[@]}"; do
      [[ -n "${RECT_OF[$id]}" ]] || { fail "3g. instance $id: no settled rect"; continue; }
      read -r RX RY RW RH <<<"${RECT_OF[$id]}"
      STATS=$(python3 ../tools/pngstat.py "$EV/composer.png" --region "$RX,$RY,$RW,$RH" 2>"$EV/composer-$id-pngstat-stderr.txt")
      [[ -s "$EV/composer-$id-pngstat-stderr.txt" ]] \
        && log "    pngstat.py on instance $id's region: $(tr '\n' ' ' <"$EV/composer-$id-pngstat-stderr.txt")"
      printf '%s\n' "${STATS:-<none>}" >"$EV/composer-$id-pngstat.txt"
      assert_marker_captured "3g. instance $id" "$id" "$PNG_BYTES" "${RECT_OF[$id]}" "$STATS"
    done
  fi
else
  fail "3f. no screen grab taken"
  fail "3h. the layout across the grab: no grab was taken"
  for id in "${IDS[@]}"; do
    fail "3g. instance $id: not scored -- see 3e"
  done
fi
assert_capture_count "3i. screen grabs taken" "$CAPTURE_GRABS" "$CAPTURE_TEST_OPEN"

step "4. binder/property-domain isolation: instance 1's own marker is not visible from instance 2"
MARK="instance1-marker-$$"
ssh_vm -t 15 "adb -s $(adb_ep_for 1) shell setprop debug.rhizo.testmarker $MARK" >/dev/null 2>&1
OWN_READBACK=$(ssh_vm -t 15 "adb -s $(adb_ep_for 1) shell getprop debug.rhizo.testmarker" 2>/dev/null | tr -d '[:space:]')
CROSS_READBACK=$(ssh_vm -t 15 "adb -s $(adb_ep_for 2) shell getprop debug.rhizo.testmarker" 2>/dev/null | tr -d '[:space:]')
LIVENESS_READBACK=$(ssh_vm -t 15 "adb -s $(adb_ep_for 2) shell getprop ro.build.version.sdk" 2>/dev/null | tr -d '[:space:]')
assert_property_isolated "4a. instance 2 cannot read instance 1's property" \
  "$MARK" "$OWN_READBACK" "$CROSS_READBACK" "$LIVENESS_READBACK"

step "5. stopping @1 leaves 0/@2 running with their cgroup.freeze state untouched"
CG0_BEFORE=$(ssh_vm -t 10 "cat ${CG[0]:-/nonexistent}/cgroup.freeze" 2>/dev/null | tr -d '[:space:]')
CG2_BEFORE=$(ssh_vm -t 10 "cat ${CG[2]:-/nonexistent}/cgroup.freeze" 2>/dev/null | tr -d '[:space:]')
ssh_vm -t 180 "systemctl stop androidd@1.service" >"$EV/stop-1.log" 2>&1
ST1=$(ssh_vm -t 10 "systemctl show -p ActiveState --value androidd@1.service" 2>/dev/null | tr -d '[:space:]')
CG0_AFTER=$(ssh_vm -t 10 "cat ${CG[0]:-/nonexistent}/cgroup.freeze" 2>/dev/null | tr -d '[:space:]')
CG2_AFTER=$(ssh_vm -t 10 "cat ${CG[2]:-/nonexistent}/cgroup.freeze" 2>/dev/null | tr -d '[:space:]')
ST0=$(ssh_vm -t 10 "systemctl show -p ActiveState --value androidd.service" 2>/dev/null | tr -d '[:space:]')
ST2=$(ssh_vm -t 10 "systemctl show -p ActiveState --value androidd@2.service" 2>/dev/null | tr -d '[:space:]')
assert_unit_state "5a0. the instance this step stops" androidd@1.service "$ST1" inactive
assert_unit_state "5a. instance 0" androidd.service "$ST0" active
assert_unit_state "5b. instance 2" androidd@2.service "$ST2" active
assert_freeze_state_unchanged "5c." 0 "$CG0_BEFORE" "$CG0_AFTER"
assert_freeze_state_unchanged "5d." 2 "$CG2_BEFORE" "$CG2_AFTER"

step "6. restart @1"
KMSG_MARK6=$(ssh_vm -t 10 "cut -d' ' -f1 /proc/uptime" 2>/dev/null | tr -dc '0-9.')
printf '%s\n' "${KMSG_MARK6:-<none>}" >"$EV/kmsg-mark-restart1.txt"
ssh_vm -t 300 "systemctl start androidd@1.service" >"$EV/restart-1.log" 2>&1
BC1_RESTART=$(ssh_vm -t 420 "for i in \$(seq 1 300); do v=\$(adb -s $(adb_ep_for 1) shell getprop sys.boot_completed 2>/dev/null | tr -d '[:space:]'); [ \"\$v\" = 1 ] && { echo 1; exit 0; }; sleep 1; done; echo 0" 2>/dev/null)
BC1_RESTART=$(boot_completed_read 1 "${KMSG_MARK6:-999999}" 300)
assert_boot_completed_id "6a. instance 1 after restart" 1 "$BC1_RESTART" "$BOOT_READ_NOTE"

for id in 1 2; do
  ssh_vm -t 120 "systemctl stop $(unit_for "$id")" >"$EV/stop-after-step6-$id.log" 2>&1
  ST=$(ssh_vm -t 10 "systemctl show -p ActiveState --value $(unit_for "$id")" 2>/dev/null | tr -d '[:space:]')
  assert_unit_state "6b. instance $id stopped before the pool and clone legs" "$(unit_for "$id")" "$ST" inactive
done

step "7. a pool of one allocates and is replaced"
POOL_TARGET=1
POOL_SET_RC=0
ssh_vm -t 300 "rhizo pool set $POOL_TARGET" >"$EV/pool-set.log" 2>&1 || POOL_SET_RC=$?
POOL_STATUS_BEFORE=$(ssh_vm -t 15 "rhizo pool status" 2>&1 | tr -d '\r')
printf '%s\n' "${POOL_STATUS_BEFORE:-<none>}" >"$EV/pool-status-before.txt"
assert_pool_configured "7a0. the pool step 7 rests on" "$POOL_SET_RC" "$POOL_STATUS_BEFORE" "$POOL_TARGET"
POOL_SINCE=$(ssh_vm -t 10 'date "+%Y-%m-%d %H:%M:%S"' 2>/dev/null | tr -d '\r')
ALLOC_OUT=$(ssh_vm -t 90 "rhizo instance allocate" 2>&1)
ALLOC_ID=$(sed -n 's/.*RHIZO_ALLOCATED id=\([0-9]*\).*/\1/p' <<<"$ALLOC_OUT" | head -1)
assert_present "7a. allocate reported an id" "no RHIZO_ALLOCATED line: $(tail -3 <<<"$ALLOC_OUT")" "$ALLOC_ID"
POOL_TIMED_OUT=1
MEMBERS_AFTER=""
PENDING_AFTER=""
REPLACE_UNITS_SEEN=""
POOL_DEADLINE=$(( SECONDS + POOL_REPLACE_TIMEOUT_S ))
while (( SECONDS < POOL_DEADLINE )); do
  POOL_SNAP=$(ssh_vm -t 15 "sed 's/^/M /' $POOL_MEMBERS_FILE 2>/dev/null; sed 's/^/P /' $POOL_PENDING_FILE 2>/dev/null; systemctl list-units --all --no-legend 'rhizo-pool-replace-*' 2>/dev/null | sed 's/^/U /'" 2>/dev/null)
  MEMBERS_AFTER=$(sed -n 's/^M //p' <<<"$POOL_SNAP")
  PENDING_AFTER=$(sed -n 's/^P //p' <<<"$POOL_SNAP")
  REPLACE_UNITS_SEEN+=$(sed -n 's/^U //p' <<<"$POOL_SNAP")$'\n'
  if (( $(grep -c . <<<"$MEMBERS_AFTER") >= POOL_TARGET )) && ! grep -qx "${ALLOC_ID:-__none__}" <<<"$MEMBERS_AFTER"; then
    POOL_TIMED_OUT=0
    break
  fi
  sleep 2
done
PENDING_AFTER=$(ssh_vm -t 10 "cat $POOL_PENDING_FILE 2>/dev/null" 2>/dev/null)
POOL_STATUS_AFTER=$(ssh_vm -t 15 "rhizo pool status" 2>&1 | tr -d '\r')
REPLACE_UNIT_JOURNAL=$(ssh_vm -t 20 "journalctl -u rhizo-pool-replace-${ALLOC_ID:-none}.service --no-pager -o cat -n 200 --since '${POOL_SINCE:-@0}'" 2>/dev/null)
printf '%s\n' "${MEMBERS_AFTER:-<none>}" >"$EV/pool-members-after.txt"
printf '%s\n' "${PENDING_AFTER:-<none>}" >"$EV/pool-pending-after.txt"
printf '%s\n' "${POOL_STATUS_AFTER:-<none>}" >"$EV/pool-status-after.txt"
printf '%s\n' "${REPLACE_UNITS_SEEN:-<none>}" >"$EV/pool-replace-units-seen.txt"
printf '%s\n' "${REPLACE_UNIT_JOURNAL:-<none>}" >"$EV/pool-replace-unit-journal.txt"
assert_pool_replacement_observed "7b." "$POOL_TIMED_OUT" "$POOL_REPLACE_TIMEOUT_S" "$POOL_TARGET" "$MEMBERS_AFTER"
assert_pool_allocate_replaced "7c." "$ALLOC_ID" "$MEMBERS_AFTER" "$PENDING_AFTER"
assert_pool_reservation_drained "7d." "$POOL_STATUS_AFTER" "$PENDING_AFTER"
assert_pool_replacement_unit "7e." "$ALLOC_ID" "$REPLACE_UNITS_SEEN" "$REPLACE_UNIT_JOURNAL" "$POOL_SINCE"

step "8. a clone boots with the snapshot's app present"
ssh_vm -t 600 "rhizo snapshot -i 0 test-clone-src" >"$EV/snapshot.log" 2>&1
CLONE_ADD_OUT=$(ssh_vm -t 600 "rhizo instance add 9 --from test-clone-src" 2>&1)
printf '%s\n' "${CLONE_ADD_OUT:-<none>}" >"$EV/clone-add.log"
assert_instance_added "8a0. the clone's own instance" 9 "$CLONE_ADD_OUT"
ssh_vm -t 600 "systemctl start androidd@9.service" >"$EV/clone-start.log" 2>&1
CLONE_EP=$(adb_ep_for 9)
CLONE_BC=$(ssh_vm -t 420 "for i in \$(seq 1 300); do adb connect $CLONE_EP >/dev/null 2>&1; v=\$(adb -s $CLONE_EP shell getprop sys.boot_completed 2>/dev/null | tr -d '[:space:]'); [ \"\$v\" = 1 ] && { echo 1; exit 0; }; sleep 1; done; echo 0" 2>/dev/null)
assert_boot_completed_id "8a. instance 9 came up (a new instance would too)" 9 "$CLONE_BC"
CLONE_PKGS=$(ssh_vm -t 30 "adb -s $CLONE_EP shell pm list packages" 2>/dev/null)
assert_clone_has_app "8b. the snapshot, not a new instance" "$CLONE_PKGS"

assert_all_steps_asserted "10a. the assertion log" "$(cat "$ASSERT_LOG" 2>/dev/null)" "${REQUIRED_ASSERTIONS[@]}"

if (( FAILED )); then
  log "test-multi-instance: FAILED with $FAILED failure(s)"
  test_record_verdict FAILED
  exit 1
fi
log "test-multi-instance: PASSED"
test_record_verdict PASSED "$(verdict_params)"
