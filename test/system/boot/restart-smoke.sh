#!/bin/bash
# test restarting androidd.service and androidd@1.service
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: none
# test-records-metrics: no
# test-verdict-params: -
# test-requires: none
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }

SELFTEST=0
for arg in "$@"; do
  case "$arg" in
    --selftest) SELFTEST=1 ;;
    *) echo "unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

SUPERVISOR_LOG=/var/log/rhizo/supervisor.log
G_PID_FILE=/root/.rhizo_g_pid

# print the systemd unit name for an id
unit_for()             { [[ "$1" == 0 ]] && echo androidd.service || echo "androidd@$1.service"; }
# print the cgroup root file of an id
cgroup_root_file_for() { [[ "$1" == 0 ]] && echo /root/.rhizo_cgroup_root || echo "/root/.rhizo_cgroup_root-$1"; }
# print the invocation record path for an id
cgroup_invocation_file_for() { [[ "$1" == 0 ]] && echo /root/.rhizo_cgroup_invocation || echo "/root/.rhizo_cgroup_invocation-$1"; }
# print the androidd unit name of an id
unit_for() { [[ "$1" == 0 ]] && echo androidd.service || echo "androidd@$1.service"; }
# print the boot log path of an id
boot_log_for()         { [[ "$1" == 0 ]] && echo /root/boot.log || echo "/root/boot-$1.log"; }

LOOP_BUDGET_INSTANCES=2

if (( SELFTEST )); then
  SELFTEST_EV="${TMPDIR:-/tmp}/test-restart-smoke-selftest${SUFFIX}"
  rm -rf "$SELFTEST_EV"
  test_init restart-smoke --no-vm --evidence-root "$SELFTEST_EV" || exit 1
else
  test_init restart-smoke || exit 1
fi

GR_OUT=""
GR_RC=0
# run a guest command and save its output
guest_read() {
  local name="$1" tmo="$2" err; shift 2
  err=$(mktemp)
  GR_OUT=$(ssh_vm -t "$tmo" "$@" 2>"$err"); GR_RC=$?
  local retried=""
  if (( GR_RC == 255 )); then
    sleep 2
    GR_OUT=$(ssh_vm -t "$tmo" "$@" 2>>"$err"); GR_RC=$?; retried=" retried=1"
  fi
  printf 'rc=%d%s\n%s\nstderr: %s\n' "$GR_RC" "$retried" "${GR_OUT:-<none>}" "$(tr '\n' ' ' <"$err")" >"$EV/$name"
  rm -f "$err"
}

ASSERT_LOG="$EV/assertions.tsv"
: > "$ASSERT_LOG"
eval "test_lib_pass() $(declare -f pass | tail -n +2)"
eval "test_lib_fail() $(declare -f fail | tail -n +2)"
# print the label key from a message
_log_key() {
  local first="${1%%$'\n'*}"
  printf '%s.' "${first%%.*}"
}
# log a keyed PASS line and pass
pass() { printf 'PASS\t%s\n' "$(_log_key "$1")" >>"$ASSERT_LOG"; test_lib_pass "$@"; }
# log a keyed FAIL line and fail
fail() { printf 'FAIL\t%s\n' "$(_log_key "$1")" >>"$ASSERT_LOG"; test_lib_fail "$@"; }

REQUIRED_ASSERTIONS=(
  0a. 0b. 0c. 0d. 0e. 0f.
  0g. 0h. 0i. 0j. 0k.
  1a. 1b. 1c. 1d. 1e. 1f. 1g.
  2a. 2b. 2c. 2d. 2e. 2f. 2g. 2h. 2i. 2j.
  3a. 3b. 3c. 3d. 3e. 3f. 3g.
)

# check the log for each label verdict
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

CGROUP_LIB_SH='
cgroup_pids() {  # print the pids in a cgroup tree
  find "$1" -name cgroup.procs -exec cat {} + 2>/dev/null | grep -xE "[0-9]+" | sort -nu
  return 0
}
cgroup_record() {  # print the cgroup root record
  [ -n "$3" ] && [ "$(cat "$2" 2>/dev/null)" = "$3" ] || return 0
  cat "$1" 2>/dev/null
  return 0
}
cgroup_init_pid() {  # print the init pid in a cgroup tree
  local p
  for p in $(cgroup_pids "$1"); do
    if [ "$(cat "${2:-/proc}/$p/comm" 2>/dev/null)" = init ]; then echo "$p"; return 0; fi
  done
  return 0
}
'

read -r -d '' MARKER_LIB_SH <<'EOF' || true
boot_completed_seen() {  # check dmesg for a boot_completed marker
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

CGROUP_RECORD_SH='cgroup_record "$1" "$2" "$(systemctl show -p InvocationID --value "$3" 2>/dev/null)"'

INIT_CHANGED_SH='
cg=$1; old=$2; tries=$3; i=0
while [ "$i" -lt "$tries" ]; do
  i=$((i + 1))
  p=$(cgroup_init_pid "$cg")
  if [ -n "$p" ] && [ "$p" != "$old" ]; then echo "$p"; exit 0; fi
  sleep 1
done
'

# encode shell text for the guest
cgroup_sh_cmd() {
  local text="$1"; shift
  local b64 args="" a
  b64=$(printf '%s\n%s\n%s\n' "$CGROUP_LIB_SH" "$MARKER_LIB_SH" "$text" | base64 -w0)
  for a in "$@"; do args+=" '$a'"; done
  printf 'echo %s | base64 -d | bash -s%s' "$b64" "$args"
}
# run boot_completed_seen on supplied dmesg text
boot_completed_seen_local() {
  bash -c "$MARKER_LIB_SH"'; boot_completed_seen "$1" "$2"' _ "$1" "$2" <<<"$3"
}
# run shell text on the guest
cgroup_sh_remote() {
  local name="$1" tmo="$2"; shift 2
  guest_read "$name" "$tmo" "$(cgroup_sh_cmd "$@")"
}

# run cgroup_pids on a local tree
cgroup_pids_from_tree() {
  printf '%s\ncgroup_pids "$1"\n' "$CGROUP_LIB_SH" | bash -s "$1"
}
# run cgroup_record on local record files
cgroup_record_from_files() {
  printf '%s\ncgroup_record "$1" "$2" "$3"\n' "$CGROUP_LIB_SH" | bash -s "$1" "$2" "$3"
}
# run cgroup_init_pid on a local tree
cgroup_init_pid_from_tree() {
  printf '%s\ncgroup_init_pid "$1" "$2"\n' "$CGROUP_LIB_SH" | bash -s "$1" "$2"
}

# print the dmesg lines past a timestamp
dmesg_since() {
  awk -v m="$1" '
    match($0, /^\[[ ]*[0-9]+\.[0-9]+\]/) {
      t = substr($0, RSTART + 1, RLENGTH - 2) + 0
      if (t > m) print
    }' <<<"$2"
}

# print python3 avc denials from dmesg text
denials_in() {
  grep -aE 'avc: +denied' <<<"$1" | grep -E 'scontext=u:r:(kernel|rhizo_host):s0' \
    | grep -E 'comm="python3"' | grep -vE 'ioctlcmd=0x5401' \
    | grep -vE '(name="kmsg"|path="/dev/kmsg") .*tcontext=u:object_r:device:s0'
}

# check the instance's sys.boot_completed value
assert_boot_completed_id() {
  local label="$1" id="$2" v="$3"
  [[ "$v" == "1" ]] || { fail "$label: instance $id sys.boot_completed='${v:-<empty>}', wanted 1"; return 1; }
  pass "$label: instance $id sys.boot_completed=1"
}

# check an instance's recorded cgroup root
assert_cgroup_record() {
  local label="$1" id="$2" cg="$3"
  cg="${cg//[[:space:]]/}"
  [[ -n "$cg" ]] \
    || { fail "$label: instance $id's $(cgroup_root_file_for "$id") is empty or unreadable"; return 1; }
  [[ "$cg" == /sys/fs/cgroup/* ]] \
    || { fail "$label: instance $id recorded cgroup root '$cg', not under /sys/fs/cgroup"; return 1; }
  pass "$label: instance $id's own recorded cgroup root is $cg"
}

# reject duplicate and nested cgroup roots
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

# check an instance's init pid
assert_init_pid() {
  local label="$1" id="$2" pid="$3"
  pid="${pid//[[:space:]]/}"
  [[ "$pid" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance $id's init pid read '${pid:-<empty>}' out of its own cgroup tree, not a pid"; return 1; }
  pass "$label: instance $id's init is host pid $pid, resolved from its own cgroup tree"
}

# check the init pid changed
assert_init_pid_changed() {
  local label="$1" id="$2" before="$3" after="$4"
  before="${before//[[:space:]]/}"; after="${after//[[:space:]]/}"
  [[ "$before" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance $id's init pid BEFORE the restart is '${before:-<empty>}'"; return 1; }
  [[ "$after" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance $id's init pid AFTER the restart is '${after:-<empty>}' -- no init appeared in its own cgroup tree within the wait"; return 1; }
  [[ "$before" != "$after" ]] \
    || { fail "$label: instance $id's init is still host pid $after after the restart"; return 1; }
  pass "$label: instance $id's init went from pid $before to pid $after"
}

# check a unit's ActiveState
assert_unit_state() {
  local label="$1" unit="$2" got="$3" want="$4"
  got="${got//[[:space:]]/}"
  [[ -n "$got" ]] \
    || { fail "$label: systemd reported no ActiveState at all for $unit"; return 1; }
  [[ "$got" == "$want" ]] || { fail "$label: $unit ActiveState=$got, wanted $want"; return 1; }
  pass "$label: $unit is $want"
}

# check the SELinux enforce node
assert_enforcing() {
  local label="$1" v="$2"
  v="${v//[[:space:]]/}"
  [[ "$v" == "1" ]] \
    || { fail "$label: /sys/fs/selinux/enforce reads '${v:-<empty>}', wanted 1"; return 1; }
  pass "$label: the guest is enforcing"
}
# wait for SELinux enforcing mode
wait_enforcing() {
  local name="$1" deadline=$(( SECONDS + $2 ))
  ENFORCE=""
  while :; do
    guest_read "$name" 10 "cat /sys/fs/selinux/enforce"
    ENFORCE="${GR_OUT//[[:space:]]/}"
    [[ "$ENFORCE" == "1" || $SECONDS -ge $deadline ]] && break
    sleep 2
  done
}

# check the contents of G_PID_FILE
assert_supervisor_pid() {
  local label="$1" record="$2" pid boot code extra
  read -r pid boot code extra <<<"${record//$'\r'/}"
  [[ "$pid" =~ ^[0-9]+$ && -z "$extra" ]] \
    || { fail "$label: $G_PID_FILE holds '${record:-<empty>}' -- no supervisor recorded itself on this boot"; return 1; }
  pass "$label: the resident supervisor recorded itself as pid $pid${boot:+ in boot $boot}${code:+ running code $code}"
}

# grep the log text for two supervisor lines
assert_supervisor_took_handoff() {
  local label="$1" id="$2" mark="$3" rc="$4" delta="$5"
  [[ "$mark" =~ ^[0-9]+$ ]] \
    || { fail "$label: no byte marker was taken on $SUPERVISOR_LOG before this action (got '${mark:-<empty>}')"; return 1; }
  (( rc == 0 )) \
    || { fail "$label: reading $SUPERVISOR_LOG past byte $mark exited $rc"; return 1; }
  [[ -n "${delta//[[:space:]]/}" ]] \
    || { fail "$label: $SUPERVISOR_LOG gained nothing at all after byte $mark"; return 1; }
  grep -qE "taking the handoff from [0-9]+ for instance $id\$" <<<"$delta" \
    || { fail "$label: the supervisor wrote $(wc -l <<<"$delta") line(s) since byte $mark but none of them is 'taking the handoff from <pid> for instance $id' (last line: $(tail -1 <<<"$delta"))"; return 1; }
  grep -qE "forked joiner [0-9]+ for instance $id's handoff from [0-9]+\$" <<<"$delta" \
    || { fail "$label: the supervisor claimed instance $id's handoff but never wrote 'forked joiner <pid> for instance $id' (last line: $(tail -1 <<<"$delta"))"; return 1; }
  pass "$label: the resident supervisor claimed instance $id's handoff and forked a joiner for it"
}

# check the log for the pivoted namespaces line
assert_launcher_handed_off() {
  local label="$1" id="$2" mark="$3" rc="$4" delta="$5"
  [[ "$mark" =~ ^[0-9]+$ ]] \
    || { fail "$label: no byte marker was taken on $SUPERVISOR_LOG before this action (got '${mark:-<empty>}')"; return 1; }
  (( rc == 0 )) \
    || { fail "$label: reading $SUPERVISOR_LOG past byte $mark exited $rc"; return 1; }
  [[ -n "${delta//[[:space:]]/}" ]] \
    || { fail "$label: $SUPERVISOR_LOG gained nothing after byte $mark"; return 1; }
  grep -qE "handed the pivoted namespaces \(pid1=[0-9]+\) to supervisor [0-9]+ for instance $id\$" <<<"$delta" \
    || { fail "$label: instance $id's launcher never wrote 'handed the pivoted namespaces (pid1=<pid>) to supervisor <pid> for instance $id' since byte $mark. Its own last line: $(tail -1 <<<"$delta")"; return 1; }
  pass "$label: instance $id's launcher published its handoff entry and signaled the supervisor"
}

# fail on SELinux denials in the dmesg window
assert_no_domain_denials() {
  local label="$1" what="$2" rc="$3" window="$4" denials="$5"
  (( rc == 0 )) \
    || { fail "$label: the guest's dmesg read for $what exited $rc"; return 1; }
  [[ -n "${window//[[:space:]]/}" ]] \
    || { fail "$label: the kernel logged nothing at all during $what"; return 1; }
  [[ -z "${denials//[[:space:]]/}" ]] \
    || { fail "$label: $(grep -c '' <<<"$denials") SELinux denial(s) in the kernel/rhizo_host domains during $what: $(head -1 <<<"$denials")"; return 1; }
  pass "$label: no avc denial with scontext kernel or rhizo_host during $what ($(grep -c '' <<<"$window") kernel log line(s) in the window)"
}

# check an init pid against a peer tree
assert_init_cgroup_scoped() {
  local label="$1" id="$2" pid="$3" peer="$4" peer_pids="$5"
  pid="${pid//[[:space:]]/}"
  [[ "$pid" =~ ^[0-9]+$ ]] \
    || { fail "$label: instance $id's init pid is '${pid:-<empty>}'"; return 1; }
  [[ -n "${peer_pids//[[:space:]]/}" ]] \
    || { fail "$label: instance $peer's own cgroup tree listed no process at all"; return 1; }
  grep -qx "$pid" <<<"$peer_pids" \
    && { fail "$label: instance $id's init (pid $pid) is inside instance $peer's cgroup tree"; return 1; }
  pass "$label: instance $id's init (pid $pid) is outside instance $peer's cgroup tree"
}

# grep both outputs for RHIZO_PROFILE profile=server
assert_profile_applied() {
  local label="$1" applied="$2" shown="$3"
  grep -qx 'RHIZO_PROFILE profile=server' <<<"$applied" \
    || { fail "$label: no 'RHIZO_PROFILE profile=server' line from 'rhizo profile server' (got '$(tail -2 <<<"${applied:-<empty>}")')"; return 1; }
  grep -qx 'RHIZO_PROFILE profile=server' <<<"$shown" \
    || { fail "$label: 'rhizo profile show' does not report profile=server (got '${shown:-<empty>}')"; return 1; }
  pass "$label: the guest reports the server profile"
}

# check policy.conf for idle_stop_s = 0
assert_idle_stop_off() {
  local label="$1" conf="$2"
  grep -q '^\[server\]' <<<"$conf" \
    || { fail "$label: the policy file has no [server] section (read: '${conf:-<empty>}')"; return 1; }
  grep -qE '^idle_stop_s *= *0$' <<<"$conf" \
    || { fail "$label: the policy file does not carry idle_stop_s = 0 (read: '${conf:-<empty>}')"; return 1; }
  pass "$label: idle_stop_s = 0"
}

# check androidd.env for the resident knobs
assert_resident_knobs() {
  local label="$1" conf="$2" want miss=""
  for want in RHIZO_RESIDENT_G=1 RHIZO_RESIDENT_DISPATCH=1; do
    grep -qxF "$want" <<<"$conf" || miss+="'$want' "
  done
  [[ -z "$miss" ]] \
    || { fail "$label: /root/androidd.env is missing $miss-- without them only one boot per instance can exec init and every restart below fails for an unrelated reason (read: '${conf:-<empty>}')"; return 1; }
  pass "$label: both resident knobs are in /root/androidd.env"
}

# check for configured instances above 0
assert_vm_instances_clear() {
  local label="$1" listing="$2" left
  [[ "$listing" == *UNREACHABLE* ]] \
    && { fail "$label: /etc/rhizo/instances could not be read at all"; return 1; }
  left=$(grep -oE '^[0-9]+$' <<<"$listing" | grep -vx 0 | tr '\n' ' ')
  [[ -z "${left// /}" ]] \
    || { fail "$label: instance id(s) ${left}still configured after the reset"; return 1; }
  pass "$label: no instance above 0 is configured"
}

# check the output of rhizo instance add
assert_instance_added() {
  local label="$1" id="$2" out="$3"
  grep -qE 'FAIL|refused|error' <<<"$out" \
    && { fail "$label: 'rhizo instance add $id' refused: $(tail -2 <<<"$out")"; return 1; }
  [[ -n "${out//[[:space:]]/}" ]] \
    || { fail "$label: 'rhizo instance add $id' printed nothing at all"; return 1; }
  pass "$label: instance $id configured ($(tail -1 <<<"$out"))"
}

# compare loop.max_loop with release-map.sh's ceiling
assert_loop_max_sized() {
  local label="$1" got="$2" want="$3"
  got="${got//[[:space:]]/}"
  [[ "$got" =~ ^[0-9]+$ ]] \
    || { fail "$label: loop.max_loop='${got:-<empty>}' is not numeric"; return 1; }
  [[ "$want" =~ ^[0-9]+$ ]] \
    || { fail "$label: release-map.sh computed no numeric ceiling ('$want')"; return 1; }
  (( got >= want )) \
    || { fail "$label: loop.max_loop=$got, below the $want release-map.sh sizes for $LOOP_BUDGET_INSTANCES instances"; return 1; }
  pass "$label: loop.max_loop=$got, at or above the $want this system test's own boot asked for"
}

# list the configured instance ids
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

# run rhizo profile desktop on the vm
vm_revert_profile() {
  local tag="$1" out rc
  out=$(ssh_vm -t 60 "rhizo profile desktop" 2>&1)
  rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/profile-desktop-$tag.log"
  (( rc == 0 )) || log "WARNING: 'rhizo profile desktop' ($tag) exited $rc; see $EV/profile-desktop-$tag.log"
  return $rc
}

# reset the vm to a desktop instance
vm_reset_instances() {
  vm_revert_profile "$1"
  local id ids
  ids=$(vm_configured_ids)
  if [[ "$ids" == UNREACHABLE ]]; then
    log "WARNING: vm_reset_instances ($1): /etc/rhizo/instances could not be listed"
    return 1
  fi
  for id in $ids; do
    ssh_vm -t 300 "rhizo instance remove $id" >"$EV/instance-remove-$id.log" 2>&1
  done
}

# save the supervisor log and instance logs
capture_instance_evidence() {
  local id out rc unit
  out=$(ssh_vm -t 30 "cat $SUPERVISOR_LOG" 2>&1); rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/supervisor.log"
  for id in 0 1; do
    unit=$(unit_for "$id")
    out=$(ssh_vm -t 30 "journalctl -u $unit -b --no-pager 2>&1 | tail -400" 2>&1); rc=$?
    printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/journal-$id.log"
    out=$(ssh_vm -t 30 "cat $(boot_log_for "$id")" 2>&1); rc=$?
    printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/boot-full-$id.log"
  done
}

# stop instance 1 and reset the vm
cleanup_vm_state() {
  (( TEST_NO_VM )) && return 0
  capture_instance_evidence
  local out rc
  out=$(ssh_vm -t 180 "systemctl stop androidd@1.service" 2>&1); rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/stop-1.log"
  vm_reset_instances cleanup
  ssh_vm -t 10 "rm -f /etc/rhizo/policy.conf" >/dev/null 2>&1
}
# shellcheck disable=SC2034
(( SELFTEST )) || TEST_EXTRA_CLEANUP=cleanup_vm_state

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

  check_fails "boot_completed=0 is caught" assert_boot_completed_id x 0 "0"
  check_fails "an empty boot_completed is caught" assert_boot_completed_id x 0 ""
  check_passes "boot_completed=1 is accepted" assert_boot_completed_id x 0 "1"

  check_fails "an instance with no recorded cgroup root is caught" assert_cgroup_record x 1 ""
  check_fails "a recorded cgroup root outside /sys/fs/cgroup is caught" assert_cgroup_record x 1 "/run/rhizo-1"
  check_passes "a real recorded cgroup root is accepted" assert_cgroup_record x 1 \
    "/sys/fs/cgroup/system.slice/system-androidd.slice/androidd@1.service"

  check_fails "two instances recording one cgroup root is caught" assert_cgroups_distinct x \
    /sys/fs/cgroup/rhizo /sys/fs/cgroup/rhizo
  check_fails "an empty recorded root among them is caught" assert_cgroups_distinct x \
    /sys/fs/cgroup/rhizo ""
  check_fails "an empty root in the FIRST position is caught" assert_cgroups_distinct x \
    "" /sys/fs/cgroup/rhizo-1
  check_fails "one root written twice, once with a trailing slash, is caught" assert_cgroups_distinct x \
    /sys/fs/cgroup/rhizo /sys/fs/cgroup/rhizo/
  check_fails "one instance's root nested INSIDE another's is caught" assert_cgroups_distinct x \
    /sys/fs/cgroup/rhizo /sys/fs/cgroup/rhizo/1
  check_fails "fewer than two roots is caught" assert_cgroups_distinct x /sys/fs/cgroup/rhizo
  check_passes "roots that merely share a prefix are beside each other, and accepted" \
    assert_cgroups_distinct x /sys/fs/cgroup/rhizo /sys/fs/cgroup/rhizo-1

  check_fails "an empty init pid is caught" assert_init_pid x 0 ""
  check_fails "a non-numeric init pid is caught" assert_init_pid x 0 "no such process"
  check_passes "a real init pid is accepted" assert_init_pid x 0 "4711"

  check_fails "an init pid that did not change across a restart is caught" \
    assert_init_pid_changed x 0 4711 4711
  check_fails "no init at all after the restart is caught" assert_init_pid_changed x 0 4711 ""
  check_fails "no recorded init before the restart is caught" assert_init_pid_changed x 0 "" 4712
  check_passes "a replaced init is accepted" assert_init_pid_changed x 0 4711 4712

  check_fails "a unit in the wrong state is caught" assert_unit_state x androidd.service failed active
  check_fails "a unit whose state never answered is caught" assert_unit_state x androidd.service "" active
  check_passes "a unit in the wanted state is accepted" assert_unit_state x androidd.service active active

  check_fails "a permissive guest is caught before a leg" assert_enforcing x 0
  check_fails "an enforce node that never answered is caught" assert_enforcing x ""
  check_fails "an enforce node that answered an error is caught" assert_enforcing x "cat: /sys/fs/selinux/enforce: No such file"
  check_passes "an enforcing guest is accepted" assert_enforcing x 1

  check_fails "no recorded supervisor pid is caught" assert_supervisor_pid x ""
  check_fails "a non-numeric supervisor pid is caught" assert_supervisor_pid x "cat: no such file"
  check_passes "a recorded supervisor pid is accepted" assert_supervisor_pid x "901"
  check_passes "a supervisor pid recorded with its boot id is accepted" \
    assert_supervisor_pid x "901 304d6b10-1958-4a48-89e0-7903d44b68e3"
  check_fails "a non-numeric pid ahead of a boot id is caught" \
    assert_supervisor_pid x "x901 304d6b10-1958-4a48-89e0-7903d44b68e3"
  check_passes "a record with a code identity after the boot id is accepted" \
    assert_supervisor_pid x "901 304d6b10-1958-4a48-89e0-7903d44b68e3 4d7103b2e51b93fd"
  check_fails "a record with a field past the code identity is caught" \
    assert_supervisor_pid x "901 304d6b10 4d7103b2e51b93fd extra"

  SUP_GOOD_0=$'[sup 901 1758290000.100] parked sigblk=...\n[sup 901 1758290001.200] woke on signal 10\n[sup 901 1758290001.300] taking the handoff from 4712 for instance 0\n[sup 901 1758290001.400] forked joiner 4800 for instance 0\'s handoff from 4712'
  SUP_GOOD_1=$'[sup 901 1758290100.100] woke on signal 10\n[sup 901 1758290100.200] taking the handoff from 5100 for instance 1\n[sup 901 1758290100.300] forked joiner 5200 for instance 1\'s handoff from 5100'
  SUP_WOKE_ONLY=$'[sup 901 1758290001.200] woke on signal 10\n[sup 901 1758290001.300] no new handoff this wake'
  SUP_CLAIMED_ONLY=$'[sup 901 1758290001.300] taking the handoff from 4712 for instance 0'
  check_passes "a supervisor that claimed and forked for instance 0 is accepted" \
    assert_supervisor_took_handoff x 0 4096 0 "$SUP_GOOD_0"
  check_passes "the same, for instance 1" \
    assert_supervisor_took_handoff x 1 4096 0 "$SUP_GOOD_1"
  check_fails "a supervisor that woke and claimed nothing is caught" \
    assert_supervisor_took_handoff x 0 4096 0 "$SUP_WOKE_ONLY"
  check_fails "a supervisor that claimed but never forked a joiner is caught" \
    assert_supervisor_took_handoff x 0 4096 0 "$SUP_CLAIMED_ONLY"
  check_fails "a supervisor that wrote nothing at all since the marker is caught" \
    assert_supervisor_took_handoff x 0 4096 0 ""
  check_fails "a failed read of the supervisor log is caught, not read as silence" \
    assert_supervisor_took_handoff x 0 4096 1 ""
  check_fails "an unscoped read (no byte marker) is caught" \
    assert_supervisor_took_handoff x 0 "" 0 "$SUP_GOOD_0"
  check_fails "another instance's handoff does not satisfy this one" \
    assert_supervisor_took_handoff x 0 4096 0 "$SUP_GOOD_1"

  BOOT_GOOD_0='[l3] handed the pivoted namespaces (pid1=4712) to supervisor 901 for instance 0'
  BOOT_GOOD_1='[l3] handed the pivoted namespaces (pid1=5100) to supervisor 901 for instance 1'
  BOOT_REFUSED=$'[l3] supervisor 901 is parked -- staging here, handing off at the pivot\n[l3] handoff to supervisor 901 FAILED to publish entry: [Errno 2] No such file or directory'
  check_passes "a published handoff for instance 0 is accepted" \
    assert_launcher_handed_off x 0 8192 0 "$BOOT_GOOD_0"
  check_passes "the same, for instance 1" \
    assert_launcher_handed_off x 1 8192 0 "$BOOT_GOOD_1"
  check_fails "a launcher that failed to publish its entry is caught" \
    assert_launcher_handed_off x 0 8192 0 "$BOOT_REFUSED"
  check_fails "a boot log that gained nothing is caught" \
    assert_launcher_handed_off x 0 8192 0 ""
  check_fails "a failed boot-log read is caught, not read as silence" \
    assert_launcher_handed_off x 0 8192 1 ""
  check_fails "an unscoped boot-log read is caught" \
    assert_launcher_handed_off x 0 "" 0 "$BOOT_GOOD_0"
  check_fails "another instance's handoff line does not satisfy this one" \
    assert_launcher_handed_off x 0 8192 0 "$BOOT_GOOD_1"

  DMESG_CLEAN=$'[  100.000000] rhizo: veth up\n[  100.500000] L3: pivoted'
  DMESG_KERNEL_DENIAL=$'[  100.000000] rhizo: veth up\n[  100.400000] audit: type=1400 audit(1758290001.3:99): avc:  denied  { remove_name } for  pid=901 comm="python3" name="0" dev="vda1" ino=5 scontext=u:r:kernel:s0 tcontext=u:object_r:unlabeled:s0 tclass=dir permissive=0'
  DMESG_HOST_DENIAL=$'[  100.400000] audit: type=1400 audit(1758290001.3:99): avc:  denied  { write } for  pid=4712 comm="python3" path="/dev/kmsg" scontext=u:r:rhizo_host:s0 tcontext=u:object_r:kmsg_device:s0 tclass=chr_file permissive=0'
  DMESG_OTHER_DENIAL=$'[  100.400000] audit: type=1400 audit(1758290001.3:99): avc:  denied  { read } for  pid=2200 comm="init" scontext=u:r:init:s0 tcontext=u:object_r:unlabeled:s0 tclass=file permissive=0'
  check_passes "a clean window is accepted" \
    assert_no_domain_denials x "the restart" 0 "$DMESG_CLEAN" "$(denials_in "$DMESG_CLEAN")"
  check_fails "a kernel-domain denial in the window is caught" \
    assert_no_domain_denials x "the restart" 0 "$DMESG_KERNEL_DENIAL" "$(denials_in "$DMESG_KERNEL_DENIAL")"
  check_fails "an rhizo_host-domain denial in the window is caught" \
    assert_no_domain_denials x "the restart" 0 "$DMESG_HOST_DENIAL" "$(denials_in "$DMESG_HOST_DENIAL")"
  check_passes "a denial in some other domain is not this system test's to fail on" \
    assert_no_domain_denials x "the restart" 0 "$DMESG_OTHER_DENIAL" "$(denials_in "$DMESG_OTHER_DENIAL")"
  check_fails "an empty window is caught rather than read as an absence" \
    assert_no_domain_denials x "the restart" 0 "" ""
  check_fails "a failed dmesg read is caught" \
    assert_no_domain_denials x "the restart" 1 "" ""

  assert_delta_is() {
    local got; got=$(dmesg_since "$2" "$3")
    [[ "$got" == "$4" ]] || { fail "$1: dmesg_since $2 returned '$got', wanted '$4'"; return 1; }
    pass "$1: dmesg_since $2 returned exactly the lines after the mark"
  }
  DMESG_SPAN=$'[   10.000000] before\n[  100.000000] after\ncontinuation with no timestamp'
  check_passes "the window keeps only lines the mark precedes" \
    assert_delta_is x 50 "$DMESG_SPAN" '[  100.000000] after'
  check_passes "a mark past everything leaves an empty window" \
    assert_delta_is x 1000 "$DMESG_SPAN" ''
  check_fails "a wrong expectation about the window is reported" \
    assert_delta_is x 50 "$DMESG_SPAN" '[   10.000000] before'

  SELFTEST_TREE=$(mktemp -d "${TMPDIR:-/tmp}/test-restart-smoke-tree.XXXXXX") || exit 1
  mkdir -p "$SELFTEST_TREE/cg0/init" "$SELFTEST_TREE/cg1/init" "$SELFTEST_TREE/proc/4711" "$SELFTEST_TREE/proc/5100"
  printf '4711\n' >"$SELFTEST_TREE/cg0/init/cgroup.procs"
  printf '5100\n' >"$SELFTEST_TREE/cg1/init/cgroup.procs"
  printf 'init\n' >"$SELFTEST_TREE/proc/4711/comm"
  printf 'init\n' >"$SELFTEST_TREE/proc/5100/comm"
  CG0_PIDS=$(cgroup_pids_from_tree "$SELFTEST_TREE/cg0")
  CG1_INIT=$(cgroup_init_pid_from_tree "$SELFTEST_TREE/cg1" "$SELFTEST_TREE/proc")
  check_passes "an init outside the peer's tree is accepted" \
    assert_init_cgroup_scoped x 1 "$CG1_INIT" 0 "$CG0_PIDS"
  check_fails "an init sitting in the peer's tree is caught" \
    assert_init_cgroup_scoped x 1 "$CG0_PIDS" 0 "$CG0_PIDS"
  check_fails "an empty init pid is caught" assert_init_cgroup_scoped x 1 "" 0 "$CG0_PIDS"
  check_fails "a peer tree that listed nothing is caught" \
    assert_init_cgroup_scoped x 1 "$CG1_INIT" 0 ""
  check_passes "the cgroup resolver finds an init by comm in its own tree" \
    assert_init_pid x 1 "$CG1_INIT"
  rm -rf "$SELFTEST_TREE"

  assert_record_read() {
    [[ "$2" == "$3" ]] || { fail "$1: the record read gave '${2:-<empty>}', wanted '${3:-<empty>}'"; return 1; }
    pass "$1: the record read gave '${2:-<empty>}'"
  }
  REC_TREE=$(mktemp -d "${TMPDIR:-/tmp}/test-restart-smoke-rec.XXXXXX") || exit 1
  printf '/sys/fs/cgroup/rhizo-1' >"$REC_TREE/root"
  printf 'aaaa\n' >"$REC_TREE/inv"
  check_passes "an earlier invocation's record reads as nothing yet" \
    assert_record_read x "$(cgroup_record_from_files "$REC_TREE/root" "$REC_TREE/inv" bbbb)" ""
  check_passes "a record with no invocation reads as nothing yet" \
    assert_record_read x "$(cgroup_record_from_files "$REC_TREE/root" "$REC_TREE/none" bbbb)" ""
  check_passes "no invocation from systemd reads as nothing" \
    assert_record_read x "$(cgroup_record_from_files "$REC_TREE/root" "$REC_TREE/inv" "")" ""
  check_passes "no invocation from systemd and none recorded reads as nothing" \
    assert_record_read x "$(cgroup_record_from_files "$REC_TREE/root" "$REC_TREE/none" "")" ""
  printf 'bbbb\n' >"$REC_TREE/inv"
  check_passes "this invocation's record reads its root" \
    assert_record_read x "$(cgroup_record_from_files "$REC_TREE/root" "$REC_TREE/inv" bbbb)" /sys/fs/cgroup/rhizo-1
  rm -rf "$REC_TREE"
  assert_record_reads_keyed() {
    local bare keyed
    bare=$(grep -c '^  guest_read cgroup-root-' <<<"$2")
    keyed=$(grep -c '^  cgroup_sh_remote cgroup-root-[01].txt 10 "$CGROUP_RECORD_SH"' <<<"$2")
    (( bare == 0 && keyed == 2 )) \
      || { fail "$1: $bare bare read(s) of the cgroup record and $keyed keyed on the invocation, wanted 0 and 2"; return 1; }
    pass "$1: both cgroup record waits are keyed on the unit's invocation"
  }
  TEST_SRC=$(cat "$(basename "${BASH_SOURCE[0]}")")
  check_passes "this system test's own record waits are keyed" assert_record_reads_keyed x "$TEST_SRC"
  check_fails "a bare read of the record is caught" assert_record_reads_keyed x \
    "${TEST_SRC/cgroup_sh_remote cgroup-root-0.txt 10 \"\$CGROUP_RECORD_SH\"/guest_read cgroup-root-0.txt 10 \"cat \$(cgroup_root_file_for 0)\"}"

  MK=$'[   10.500000] L3: RHIZO_MARKER launch_start sandbox=1\n[   20.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=1\n[   21.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=10'
  if boot_completed_seen_local 1 15 "$MK"; then log "  selftest OK: a marker after the mark is this action's boot"
  else fail "selftest: instance 1's marker after the mark was not seen"; fi
  if boot_completed_seen_local 1 20.5 "$MK"; then fail "selftest: a marker BEFORE the mark counted as this action's boot"
  else log "  selftest OK: a marker before the mark is an earlier boot's"; fi
  if boot_completed_seen_local 0 15 "$MK"; then fail "selftest: instance 1's and 10's markers satisfied instance 0"
  else log "  selftest OK: another instance's marker does not count (sandbox=1 and =10 for id 0)"; fi
  if boot_completed_seen_local 1 15 $'[   30.0] init: nothing here'; then fail "selftest: a log with no marker read as boot completed"
  else log "  selftest OK: no marker, no boot"; fi

  check_fails "a profile apply that printed no contract line is caught" assert_profile_applied x "" "RHIZO_PROFILE profile=server"
  check_fails "a host that does not report the server profile is caught" \
    assert_profile_applied x "RHIZO_PROFILE profile=server" "RHIZO_PROFILE profile=desktop"
  check_passes "an applied and confirmed server profile is accepted" \
    assert_profile_applied x "RHIZO_PROFILE profile=server" "RHIZO_PROFILE profile=server"

  check_fails "a policy file with no [server] section is caught" assert_idle_stop_off x "[rhizo]"
  check_fails "a policy file that leaves the idle detector on is caught" \
    assert_idle_stop_off x $'[rhizo]\nprofile = server\n[server]\nidle_stop_s = 600'
  check_passes "idle_stop_s = 0 is accepted" \
    assert_idle_stop_off x $'[rhizo]\nprofile = server\n[server]\nidle_stop_s = 0'

  check_fails "a missing resident knob is caught" assert_resident_knobs x "RHIZO_RESIDENT_G=1"
  check_fails "an empty androidd.env is caught" assert_resident_knobs x ""
  check_passes "both resident knobs are accepted" \
    assert_resident_knobs x $'RHIZO_RESIDENT_G=1\nRHIZO_RESIDENT_DISPATCH=1'

  check_fails "an unreadable instance listing is caught" assert_vm_instances_clear x UNREACHABLE
  check_fails "a leftover instance is caught" assert_vm_instances_clear x $'1\n2'
  check_passes "an empty listing is accepted" assert_vm_instances_clear x ""

  check_fails "a refused instance add is caught" assert_instance_added x 1 "FAIL: instance add 1 refused: rhizo.profile is desktop"
  check_fails "an instance add that printed nothing is caught" assert_instance_added x 1 ""
  check_passes "a real instance add is accepted" assert_instance_added x 1 "RHIZO_INSTANCE_ADDED id=1"

  check_fails "a vm under the computed loop ceiling is caught" assert_loop_max_sized x 64 142
  check_fails "a non-numeric loop.max_loop is caught" assert_loop_max_sized x "" 142
  check_fails "a ceiling release-map.sh could not compute is caught" assert_loop_max_sized x 142 ""
  check_passes "a vm at the computed loop ceiling is accepted" assert_loop_max_sized x 142 142

  assert_key_is() {
    local got; got=$(_log_key "$2")
    [[ "$got" == "$3" ]] || { fail "$1: _log_key '$2' = '$got', wanted '$3'"; return 1; }
    pass "$1: _log_key '$2' = '$got'"
  }
  check_passes "a bare label keys on its dot, not on the colon after it" \
    assert_key_is x "1c.: androidd.service is active" "1c."
  check_passes "a label carrying its own text keys the same way" \
    assert_key_is x "2a. androidd@1.service: instance 1's own recorded cgroup root is /sys/fs/cgroup/rhizo-1" "2a."
  check_passes "a message quoting a multi-line artifact still keys on one line" \
    assert_key_is x "$(printf '0d. the idle detector: read back\n[rhizo]\nprofile = server')" "0d."

  LOG_FULL=$'PASS\t0a.\nFAIL\t0b.\nPASS\t1a.\nPASS\t2a.'
  LOG_MISSING_1A=$'PASS\t0a.\nFAIL\t0b.\nPASS\t2a.'
  check_passes "a log carrying every required label is accepted" \
    assert_all_steps_asserted x "$LOG_FULL" 0a. 0b. 1a. 2a.
  check_fails "an assertion that decided nothing at all is caught" \
    assert_all_steps_asserted x "$LOG_MISSING_1A" 0a. 0b. 1a. 2a.
  check_fails "an empty log is caught" assert_all_steps_asserted x "" 0a. 0b. 1a. 2a.
  check_passes "a FAIL counts as having decided, exactly like a PASS" \
    assert_all_steps_asserted x $'FAIL\t1a.' 1a.
  check_fails "a longer label does not satisfy a shorter required one" \
    assert_all_steps_asserted x $'PASS\t1a.b' 1a.
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

  if (( FAILED )); then
    log "test-restart-smoke --selftest: FAILED with $FAILED failure(s)"
    exit 1
  fi
  log "test-restart-smoke --selftest: PASSED"
  exit 0
fi

if (( SELFTEST )); then
  fail "0. --selftest fell through its own block instead of exiting"
  test_record_verdict FAILED
  exit 1
fi

if [[ "${RHIZO_SKIP_BOOT:-0}" == 1 ]]; then
  fail "0. RHIZO_SKIP_BOOT=1, but this system test is cold-required"
  test_record_verdict FAILED
  exit 1
fi

RELEASE="${RHIZO_RELEASE:-a16}"
LOOP_MAX_WANT=$(loop_max_loop_for_instances "$RELEASE" "$LOOP_BUDGET_INSTANCES")
export RHIZO_LOOP_MAX_LOOP="$LOOP_MAX_WANT"

test_boot --skip-graphics-preflight --release "$RELEASE" \
  || { fail "0. boot failed"; test_record_verdict FAILED; exit 1; }

EV_NAMES=(
  redeploy-stage.log vm-instances.txt loop-max.txt
  profile-server.log profile-show.log policy-conf.txt androidd-env.txt instance-add-1.log
  start-0.log cgroup-root-0.txt bootcompleted-0-start.txt initpid-0-start.txt supervisor-pid.txt
  enforce-0.txt
  enforce-restart0.txt restart-0.log initpid-0-after.txt bootcompleted-0-restart.txt unitstate-0-restart.txt
  enforce-start1.txt start-1.log cgroup-root-1.txt bootcompleted-1-start.txt initpid-1-start.txt
  unitstate-1-start.txt cgroup-pids-0.txt cgroup-roots.txt
  enforce-restart1.txt restart-1.log initpid-1-after.txt bootcompleted-1-restart.txt unitstate-1-restart.txt
  supervisor.log journal-0.log journal-1.log boot-full-0.log boot-full-1.log
  stop-1.log instance-remove-1.log
  profile-desktop-prestage.log profile-desktop-0pre.log profile-desktop-cleanup.log
)
for _tag in restart0 start1 restart1; do
  EV_NAMES+=("mark-$_tag.txt" "supervisor-delta-$_tag.txt" "bootlog-delta-$_tag.txt"
             "dmesg-$_tag.txt" "dmesg-delta-$_tag.txt" "denials-$_tag.txt")
done
for _ev_name in "${EV_NAMES[@]}"; do
  printf '%s\n' "<not reached: this run never got to the step that writes $_ev_name>" >"$EV/$_ev_name"
done
unset _ev_name _tag

vm_reset_instances prestage

../../vm/sync.sh >/dev/null || { fail "0. sync.sh failed"; test_record_verdict FAILED; exit 1; }
STAGE_LOG="$EV/redeploy-stage.log"
if ! ../../vm/redeploy.sh --skip-kill --no-launch > "$STAGE_LOG" 2>&1; then
  fail "0. redeploy.sh --no-launch failed -- look for STAGED_OK in $STAGE_LOG"
  test_record_verdict FAILED
  exit 1
fi

step "0pre. a clean vm, and the host contract the restarts below need"
vm_reset_instances 0pre
VM_IDS=$(vm_configured_ids)
printf '%s\n' "${VM_IDS:-<none>}" >"$EV/vm-instances.txt"
assert_vm_instances_clear "0a. the vm this run starts from" "$VM_IDS"

guest_read loop-max.txt 15 "$GUEST_LOOP_MAX_READ"
assert_loop_max_sized "0b. this vm's loop ceiling" "$GR_OUT" "$LOOP_MAX_WANT"

guest_read profile-server.log 120 "rhizo profile server"
PROFILE_OUT="$GR_OUT"
guest_read profile-show.log 30 "rhizo profile show"
assert_profile_applied "0c. rhizo profile server" "$PROFILE_OUT" "$GR_OUT"

POLICY_CMD="install -d -m 0755 /etc/rhizo"
POLICY_CMD+=$'\n'": > /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"echo '[rhizo]' >> /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"echo 'profile = server' >> /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"echo '[server]' >> /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"echo 'idle_stop_s = 0' >> /etc/rhizo/policy.conf"
POLICY_CMD+=$'\n'"cat /etc/rhizo/policy.conf"
guest_read policy-conf.txt 30 "$POLICY_CMD"
assert_idle_stop_off "0d. the idle detector the server profile enables" "$GR_OUT"

ANDROIDD_ENV_CMD="grep -Ev '^(RHIZO_RESIDENT_G|RHIZO_RESIDENT_DISPATCH)=' /root/androidd.env > /root/androidd.env.test-tmp 2>/dev/null || : > /root/androidd.env.test-tmp"
ANDROIDD_ENV_CMD+=$'\n'"echo 'RHIZO_RESIDENT_G=1' >> /root/androidd.env.test-tmp"
ANDROIDD_ENV_CMD+=$'\n'"echo 'RHIZO_RESIDENT_DISPATCH=1' >> /root/androidd.env.test-tmp"
ANDROIDD_ENV_CMD+=$'\n'"mv /root/androidd.env.test-tmp /root/androidd.env || echo RHIZO_ENV_MV_FAILED"
ANDROIDD_ENV_CMD+=$'\n'"cat /root/androidd.env"
guest_read androidd-env.txt 30 "$ANDROIDD_ENV_CMD"
assert_resident_knobs "0e. the unit path's resident knobs" "$GR_OUT"

guest_read instance-add-1.log 60 "rhizo instance add 1"
assert_instance_added "0f. instance 1" 1 "$GR_OUT"

SUP_MARK="" BOOTLOG_MARK="" KMSG_MARK=""
# record the log sizes and kernel clock
take_marks() {
  local tag="$1" id="$2"
  SUP_MARK="" BOOTLOG_MARK="" KMSG_MARK=""
  guest_read "mark-$tag.txt" 25 \
    "if [ -s $SUPERVISOR_LOG ]; then wc -c < $SUPERVISOR_LOG; else echo 0; fi
     if [ -s $(boot_log_for "$id") ]; then wc -c < $(boot_log_for "$id"); else echo 0; fi
     cut -d' ' -f1 /proc/uptime
     echo RHIZO_MARK_DONE"
  [[ "$GR_RC" == 0 && "$GR_OUT" == *RHIZO_MARK_DONE* ]] || return 0
  SUP_MARK=$(sed -n '1p' <<<"$GR_OUT" | tr -dc '0-9')
  BOOTLOG_MARK=$(sed -n '2p' <<<"$GR_OUT" | tr -dc '0-9')
  KMSG_MARK=$(sed -n '3p' <<<"$GR_OUT" | tr -dc '0-9.')
}

SUP_DELTA="" SUP_DELTA_RC=1
DM_ALL="" DM_RC=1 DM_DELTA="" DENIALS=""
# read the guest logs at the recorded offsets
read_deltas() {
  local tag="$1" id="$2"
  if [[ "$SUP_MARK" =~ ^[0-9]+$ ]]; then
    guest_read "supervisor-delta-$tag.txt" 30 "tail -c +$(( SUP_MARK + 1 )) $SUPERVISOR_LOG"
    SUP_DELTA="$GR_OUT"; SUP_DELTA_RC="$GR_RC"
  else
    SUP_DELTA=""; SUP_DELTA_RC=1
    printf '%s\n' "<none: no byte marker was taken on $SUPERVISOR_LOG before this action>" >"$EV/supervisor-delta-$tag.txt"
  fi
  if [[ "$BOOTLOG_MARK" =~ ^[0-9]+$ ]]; then
    guest_read "bootlog-delta-$tag.txt" 30 "tail -c +$(( BOOTLOG_MARK + 1 )) $(boot_log_for "$id")"
  else
    printf '%s\n' "<none: no byte marker was taken on $(boot_log_for "$id") before this action>" >"$EV/bootlog-delta-$tag.txt"
  fi
  guest_read "dmesg-$tag.txt" 40 'dmesg'
  DM_ALL="$GR_OUT"; DM_RC="$GR_RC"
  DM_DELTA=""
  if [[ "$KMSG_MARK" =~ ^[0-9]+(\.[0-9]+)?$ && "$DM_RC" == 0 && -n "$DM_ALL" ]]; then
    DM_DELTA=$(dmesg_since "$KMSG_MARK" "$DM_ALL")
  fi
  printf '%s\n' "${DM_DELTA:-<none>}" >"$EV/dmesg-delta-$tag.txt"
  DENIALS=$(denials_in "$DM_DELTA")
  printf '%s\n' "${DENIALS:-<none>}" >"$EV/denials-$tag.txt"
}

step "0. start instance 0, and record what a restart has to change"
take_marks start0 0
guest_read start-0.log 300 "systemctl start androidd.service"

declare -A CG=() INITPID=()
CG0=""
DEADLINE=$(( SECONDS + 120 ))
while (( SECONDS < DEADLINE )); do
  cgroup_sh_remote cgroup-root-0.txt 10 "$CGROUP_RECORD_SH" "$(cgroup_root_file_for 0)" \
    "$(cgroup_invocation_file_for 0)" "$(unit_for 0)"
  CG0="${GR_OUT//[[:space:]]/}"
  CG0="${CG0%/}"
  [[ "$CG0" == /sys/fs/cgroup/* ]] && break
  sleep 2
done
assert_cgroup_record "0g. androidd.service" 0 "$CG0"
CG[0]="$CG0"

cgroup_sh_remote bootcompleted-0-start.txt 300 "$BOOT_COMPLETED_SH" 0 "${KMSG_MARK:-999999}" 180
assert_boot_completed_id "0h. androidd.service" 0 "${GR_OUT//[[:space:]]/}"

cgroup_sh_remote initpid-0-start.txt 20 'cgroup_init_pid "$1"' "${CG[0]:-/nonexistent}"
INITPID[0]="${GR_OUT//[[:space:]]/}"
assert_init_pid "0i. androidd.service" 0 "${INITPID[0]}"

guest_read supervisor-pid.txt 15 "cat $G_PID_FILE"
assert_supervisor_pid "0j. the resident supervisor this system test's restarts hand off to" "$GR_OUT"

wait_enforcing enforce-0.txt 180
assert_enforcing "0k. after instance 0's first boot" "$ENFORCE"

step "1. systemctl restart androidd.service -- the restart with handoff of instance 0"
guest_read enforce-restart0.txt 10 "cat /sys/fs/selinux/enforce"
assert_enforcing "1g. before instance 0's restart" "$GR_OUT"
take_marks restart0 0
guest_read restart-0.log 300 "systemctl restart androidd.service"

cgroup_sh_remote initpid-0-after.txt 150 "$INIT_CHANGED_SH" "${CG[0]:-/nonexistent}" "${INITPID[0]:-0}" 90
INITPID_0_AFTER="${GR_OUT//[[:space:]]/}"
assert_init_pid_changed "1a. instance 0 across the restart" 0 "${INITPID[0]}" "$INITPID_0_AFTER"

cgroup_sh_remote bootcompleted-0-restart.txt 300 "$BOOT_COMPLETED_SH" 0 "${KMSG_MARK:-999999}" 180
assert_boot_completed_id "1b. instance 0 after the restart" 0 "${GR_OUT//[[:space:]]/}"

guest_read unitstate-0-restart.txt 15 "systemctl show -p ActiveState --value androidd.service"
assert_unit_state "1c. after the restart" androidd.service "$GR_OUT" active

read_deltas restart0 0
assert_supervisor_took_handoff "1d. instance 0's restart" 0 "$SUP_MARK" "$SUP_DELTA_RC" "$SUP_DELTA"
assert_launcher_handed_off "1e. instance 0's restart" 0 "$SUP_MARK" "$SUP_DELTA_RC" "$SUP_DELTA"
assert_no_domain_denials "1f. instance 0's restart" "instance 0's restart" "$DM_RC" "$DM_DELTA" "$DENIALS"

step "2. the first start of androidd@1.service -- a handoff for an instance the supervisor was not born in"
guest_read enforce-start1.txt 10 "cat /sys/fs/selinux/enforce"
assert_enforcing "2j. before instance 1's first start" "$GR_OUT"
take_marks start1 1
guest_read start-1.log 300 "systemctl start androidd@1.service"

CG1=""
DEADLINE=$(( SECONDS + 120 ))
while (( SECONDS < DEADLINE )); do
  cgroup_sh_remote cgroup-root-1.txt 10 "$CGROUP_RECORD_SH" "$(cgroup_root_file_for 1)" \
    "$(cgroup_invocation_file_for 1)" "$(unit_for 1)"
  CG1="${GR_OUT//[[:space:]]/}"
  CG1="${CG1%/}"
  [[ "$CG1" == /sys/fs/cgroup/* ]] && break
  sleep 2
done
assert_cgroup_record "2a. androidd@1.service" 1 "$CG1"
CG[1]="$CG1"

cgroup_sh_remote bootcompleted-1-start.txt 300 "$BOOT_COMPLETED_SH" 1 "${KMSG_MARK:-999999}" 180
assert_boot_completed_id "2b. androidd@1.service" 1 "${GR_OUT//[[:space:]]/}"

cgroup_sh_remote initpid-1-start.txt 20 'cgroup_init_pid "$1"' "${CG[1]:-/nonexistent}"
INITPID[1]="${GR_OUT//[[:space:]]/}"
assert_init_pid "2c. androidd@1.service" 1 "${INITPID[1]}"

printf '%s\n%s\n' "${CG[0]:-<none>}" "${CG[1]:-<none>}" >"$EV/cgroup-roots.txt"
assert_cgroups_distinct "2d. the two recorded cgroup roots" "${CG[0]:-}" "${CG[1]:-}"

cgroup_sh_remote cgroup-pids-0.txt 30 'cgroup_pids "$1"' "${CG[0]:-/nonexistent}"
assert_init_cgroup_scoped "2e. instance 1's init placement" 1 "${INITPID[1]}" 0 "$GR_OUT"

guest_read unitstate-1-start.txt 15 "systemctl show -p ActiveState --value androidd@1.service"
assert_unit_state "2f. after the first start" androidd@1.service "$GR_OUT" active

read_deltas start1 1
assert_supervisor_took_handoff "2g. instance 1's first start" 1 "$SUP_MARK" "$SUP_DELTA_RC" "$SUP_DELTA"
assert_launcher_handed_off "2h. instance 1's first start" 1 "$SUP_MARK" "$SUP_DELTA_RC" "$SUP_DELTA"
assert_no_domain_denials "2i. instance 1's first start" "instance 1's first start" "$DM_RC" "$DM_DELTA" "$DENIALS"

step "3. systemctl restart androidd@1.service -- the templated unit's own restart with handoff"
guest_read enforce-restart1.txt 10 "cat /sys/fs/selinux/enforce"
assert_enforcing "3g. before instance 1's restart" "$GR_OUT"
take_marks restart1 1
guest_read restart-1.log 300 "systemctl restart androidd@1.service"

cgroup_sh_remote initpid-1-after.txt 150 "$INIT_CHANGED_SH" "${CG[1]:-/nonexistent}" "${INITPID[1]:-0}" 90
INITPID_1_AFTER="${GR_OUT//[[:space:]]/}"
assert_init_pid_changed "3a. instance 1 across the restart" 1 "${INITPID[1]}" "$INITPID_1_AFTER"

cgroup_sh_remote bootcompleted-1-restart.txt 300 "$BOOT_COMPLETED_SH" 1 "${KMSG_MARK:-999999}" 180
assert_boot_completed_id "3b. instance 1 after the restart" 1 "${GR_OUT//[[:space:]]/}"

guest_read unitstate-1-restart.txt 15 "systemctl show -p ActiveState --value androidd@1.service"
assert_unit_state "3c. after the restart" androidd@1.service "$GR_OUT" active

read_deltas restart1 1
assert_supervisor_took_handoff "3d. instance 1's restart" 1 "$SUP_MARK" "$SUP_DELTA_RC" "$SUP_DELTA"
assert_launcher_handed_off "3e. instance 1's restart" 1 "$SUP_MARK" "$SUP_DELTA_RC" "$SUP_DELTA"
assert_no_domain_denials "3f. instance 1's restart" "instance 1's restart" "$DM_RC" "$DM_DELTA" "$DENIALS"

step "4. the assertion log"
assert_all_steps_asserted "4a. the assertion log" "$(cat "$ASSERT_LOG" 2>/dev/null)" "${REQUIRED_ASSERTIONS[@]}"

if (( FAILED )); then
  log "test-restart-smoke: FAILED with $FAILED failure(s) -- evidence in $EV"
  test_record_verdict FAILED
  exit 1
fi
log "test-restart-smoke: PASSED -- evidence in $EV"
test_record_verdict PASSED
