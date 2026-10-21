#!/bin/bash
# test the VTS and CTS certified pair
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: launcher.sh
# test-records-metrics: no
# test-verdict-params: variant=user posture=
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
source ../cts/cts-jdk-lib.sh

[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
[[ "${RHIZO_DESKTOP_PROFILE:-sway}" == sway ]] \
  || { fail "this system test only runs under the sway desktop profile (got RHIZO_DESKTOP_PROFILE=$RHIZO_DESKTOP_PROFILE)"; exit 1; }
SKIP_BOOT=0
POSTURE=""
CTS_ABI="${CTS_ABI:-$(uname -m)}"
FULL=0
DEV_MODULE=""
MODULES_FILE=""
RESUME=0
RESUME_SINCE=0
SHARD_COUNT=1
SHARD_INDEX=0
VARIANT=user
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-boot) SKIP_BOOT=1; shift ;;
    --abi) CTS_ABI="$2"; shift 2 ;;
    --posture) POSTURE="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --dev-subset) DEV_MODULE="$2"; shift 2 ;;
    --modules) MODULES_FILE="$2"; shift 2 ;;
    --resume) RESUME=1; shift ;;
    --resume-since) RESUME=1; RESUME_SINCE="$2"; shift 2 ;;
    --shard-count) SHARD_COUNT="$2"; shift 2 ;;
    --shard-index) SHARD_INDEX="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$CTS_ABI" in
  ""|-*|*" "*) echo "--abi needs a single ABI name (got '$CTS_ABI')" >&2; exit 2 ;;
esac
if [[ -n "$POSTURE" && "$POSTURE" != "vts" && "$POSTURE" != "cts" ]]; then
  echo "usage: $0 [--skip-boot] [--posture vts|cts] [--variant user|userdebug] [--full] [--dev-subset MODULE] [--modules FILE] [--resume] [--resume-since EPOCH] [--shard-count N --shard-index I]" >&2
  exit 2
fi
case "$VARIANT" in
  user) VARIANT_GSI="" ;;
  userdebug)
    VARIANT_GSI="/srv/rhizo/gsi_system_userdebug"
    if [[ "$POSTURE" != "vts" ]]; then
      echo "--variant userdebug requires --posture vts; run CTS on the user variant" >&2
      exit 2
    fi
    ;;
  *) echo "unknown --variant '$VARIANT' (expected user|userdebug)" >&2; exit 2 ;;
esac
if [[ -n "$DEV_MODULE" && -n "$MODULES_FILE" ]]; then
  echo "--dev-subset and --modules are mutually exclusive" >&2
  exit 2
fi
if ! [[ "$RESUME_SINCE" =~ ^[0-9]+$ ]]; then
  echo "--resume-since must be a non-negative integer epoch, got '$RESUME_SINCE'" >&2
  exit 2
fi
if ! [[ "$SHARD_COUNT" =~ ^[0-9]+$ ]] || (( SHARD_COUNT < 1 )); then
  echo "--shard-count must be a positive integer, got '$SHARD_COUNT'" >&2
  exit 2
fi
if ! [[ "$SHARD_INDEX" =~ ^[0-9]+$ ]] || (( SHARD_INDEX >= SHARD_COUNT )); then
  echo "--shard-index must be an integer in [0, --shard-count), got '$SHARD_INDEX' with --shard-count $SHARD_COUNT" >&2
  exit 2
fi
if (( FULL )) && { [[ -n "$MODULES_FILE" ]] || (( SHARD_COUNT > 1 )); }; then
  log "WARNING: --full runs the suite's entire plan with no per-module filter -- --modules/--shard-count have no effect here"
fi

ADB_VERIFY_SAVED=""
# save the guest's adb install verification setting
save_adb_verification() {
  [[ -n "$ADB_VERIFY_SAVED" ]] && return 0
  ADB_VERIFY_SAVED="${EV:-/tmp}/verifier-adb-setting-before-cts.txt"
  [[ -f "$ADB_VERIFY_SAVED" ]] && return 0
  android_sh "${INIT:-0}" "settings get global verifier_verify_adb_installs" \
    | tr -d '\r' | head -1 > "$ADB_VERIFY_SAVED" 2>/dev/null || true
  log "saved verifier_verify_adb_installs=$(cat "$ADB_VERIFY_SAVED" 2>/dev/null) before tradefed"
}

# restore the adb verifier setting
restore_adb_verification() {
  [[ -n "$ADB_VERIFY_SAVED" && -f "$ADB_VERIFY_SAVED" ]] || return 0
  local before now
  before=$(tr -d '\r' < "$ADB_VERIFY_SAVED" | head -1)
  now=$(android_sh "${INIT:-0}" "settings get global verifier_verify_adb_installs" 2>/dev/null | tr -d '\r' | head -1)
  [[ "$now" == "$before" ]] && return 0
  if [[ -z "$before" || "$before" == null ]]; then
    android_sh "${INIT:-0}" "settings delete global verifier_verify_adb_installs" >/dev/null 2>&1
    log "restored verifier_verify_adb_installs to ABSENT (was $now after tradefed)"
  else
    android_sh "${INIT:-0}" "settings put global verifier_verify_adb_installs $before" >/dev/null 2>&1
    log "restored verifier_verify_adb_installs=$before (was $now after tradefed)"
  fi
}

FTRACE_MODULES=(CtsPerfettoTestCases CtsProfilingModuleTests)
FTRACE_ARMED=0

# check the cts selection for ftrace modules
cts_needs_ftrace() {
  (( FULL )) && return 0
  local m
  for m in "${FTRACE_MODULES[@]}"; do
    [[ "$DEV_MODULE" == "$m" ]] && return 0
    [[ -n "$MODULES_FILE" ]] && grep -qx "$m" "$MODULES_FILE" && return 0
  done
  return 1
}

# enable trace.ftrace in the vm policy.conf
arm_ftrace() {
  local out
  out=$(ssh_vm -t 15 'if [ -e /etc/rhizo/policy.conf ]; then echo RHIZO_POLICY_PRESENT; else mkdir -p /etc/rhizo && printf "[trace]\nftrace = yes\n" > /etc/rhizo/policy.conf && sync && echo RHIZO_FTRACE_ARMED; fi')
  case "$out" in
    *RHIZO_FTRACE_ARMED*) FTRACE_ARMED=1; log "trace.ftrace armed in /etc/rhizo/policy.conf for this cts boot (${FTRACE_MODULES[*]} trace the kernel)" ;;
    *RHIZO_POLICY_PRESENT*) fail "this cts selection needs trace.ftrace on, and the vm already has an /etc/rhizo/policy.conf this system test will not edit -- remove it, or add [trace] ftrace = yes to it"; return 1 ;;
    *) fail "could not write /etc/rhizo/policy.conf to arm trace.ftrace: $out"; return 1 ;;
  esac
}

# remove policy.conf from the vm
disarm_ftrace() {
  (( FTRACE_ARMED )) || return 0
  ssh_vm -t 15 'rm -f /etc/rhizo/policy.conf && sync' >/dev/null
  local left
  left=$(ssh_vm -t 15 '[ -e /etc/rhizo/policy.conf ] && echo PRESENT || echo GONE')
  case "$left" in
    *GONE*) FTRACE_ARMED=0; log "CLEANUP_OK trace.ftrace disarmed: /etc/rhizo/policy.conf removed" ;;
    *PRESENT*) log "CLEANUP_INCOMPLETE /etc/rhizo/policy.conf (trace.ftrace on) is still on vm $RHIZO_VM -- remove it before the next boot" ;;
    *) log "CLEANUP_UNVERIFIED could not read back /etc/rhizo/policy.conf on vm $RHIZO_VM: $left" ;;
  esac
}

# restore the adb verification setting and disarm ftrace
certified_pair_cleanup() {
  restore_adb_verification
  disarm_ftrace
}
# shellcheck disable=SC2034
TEST_EXTRA_CLEANUP=certified_pair_cleanup

test_init certified-pair --variant "$VARIANT"

SUITES_DIR="$VAR_DIR/suites"
[[ "$RHIZO_VM" != 0 && -d "$VAR_DIR/suites-$RHIZO_VM" ]] && SUITES_DIR="$VAR_DIR/suites-$RHIZO_VM"
CTS_ROOT="$SUITES_DIR/android-cts"
VTS_ROOT="$SUITES_DIR/android-vts"

VTS_MODULES=(
  vts_treble_vintf_vendor_test
  vts_treble_vintf_framework_test
  vts_treble_no_hidl
  vts_treble_sys_prop_test
  VtsAidlKeyMintTargetTest
  VtsAidlSecureClockTargetTest
  VtsAidlSharedSecretTargetTest
  VtsHalRemotelyProvisionedComponentTargetTest
  VtsHalGraphicsAllocatorAidl_TargetTest
  VtsHalGraphicsMapperStableC_TargetTest
  VtsHalGraphicsComposer3_TargetTest
  VtsHalHealthTargetTest
  VtsHalPowerTargetTest
  VtsHalAudioCoreTargetTest
  VtsHalAudioEffectFactoryTargetTest
  VtsHalAudioEffectTargetTest
  VtsHalBootAidlTargetTest
  VtsHalGatekeeperTargetTest
  VtsHalThermalTargetTest
  VtsHalGnssTargetTest
  VtsAidlHalCameraProvider_TargetTest
)
CTS_MODULES=(
  CtsOsTestCases
  CtsGraphicsTestCases
  CtsKeystoreTestCases
  CtsSecurityHostTestCases
  CtsVirtualDevicesSensorTestCases
  CtsVirtualDevicesCameraTestCases
)

if [[ -n "$MODULES_FILE" ]]; then
  [[ -r "$MODULES_FILE" ]] || { echo "--modules file not readable: $MODULES_FILE" >&2; exit 2; }
  mapfile -t FILE_MODULES < <(grep -vE '^[[:space:]]*(#|$)' "$MODULES_FILE")
  (( ${#FILE_MODULES[@]} > 0 )) || { echo "--modules file $MODULES_FILE has no module names in it" >&2; exit 2; }
  VTS_MODULES=("${FILE_MODULES[@]}")
  CTS_MODULES=("${FILE_MODULES[@]}")
fi

if (( SHARD_COUNT > 1 )); then
  shard_of() {
    local i=0 m
    for m in "$@"; do
      (( i % SHARD_COUNT == SHARD_INDEX )) && echo "$m"
      i=$((i+1))
    done
  }
  mapfile -t VTS_MODULES < <(shard_of "${VTS_MODULES[@]}")
  mapfile -t CTS_MODULES < <(shard_of "${CTS_MODULES[@]}")
  log "shard $SHARD_INDEX/$SHARD_COUNT: ${#VTS_MODULES[@]} VTS module(s), ${#CTS_MODULES[@]} CTS module(s) in this shard"
fi

# check for the suite tradefed binary
require_suite() {
  local root="$1" tf="$2" label="$3"
  if [[ ! -x "$root/$tf" ]]; then
    fail "$label not found at $root/$tf -- run tools/fetch/suites/suites.sh ${label,,} first"
    return 1
  fi
  local why
  why=$(suite_java_home "$root" 2>&1 >/dev/null) || { fail "$label: $why"; return 1; }
  return 0
}

# connect adb to the vm
bring_up_adb() {
  ../../vm/boot/adb-tunnel.sh up || { log "    adb-tunnel.sh up failed -- caller decides"; return 1; }
  local state
  state=$(~/Android/Sdk/platform-tools/adb devices | awk -v want="127.0.0.1:$ADB_PORT" '$1==want{print $2}')
  echo "$state" > "$EV/adb-devices-state.txt"
  [[ "$state" == "device" ]] || { fail "adb device state is '$state', not 'device', right after adb-tunnel.sh reported success"; return 1; }
  pass "adb connected: 127.0.0.1:$ADB_PORT state=device"
}

# unroot the device and check the shell uid
ensure_unrooted() {
  local uid
  uid=$(~/Android/Sdk/platform-tools/adb -s 127.0.0.1:$ADB_PORT shell id -u 2>/dev/null | tr -d '\r\n')
  if [[ "$uid" != "2000" ]]; then
    log "    device running as uid=$uid, not shell -- unrooting before regression baseline"
    local attempt
    for attempt in 1 2 3; do
      ~/Android/Sdk/platform-tools/adb -s 127.0.0.1:$ADB_PORT unroot >/dev/null 2>&1
      bring_up_adb || { fail "could not re-authorize adb after unroot (attempt $attempt)"; return 1; }
      local waited=0
      while (( waited < 15 )); do
        uid=$(~/Android/Sdk/platform-tools/adb -s 127.0.0.1:$ADB_PORT shell id -u 2>/dev/null | tr -d '\r\n')
        [[ "$uid" == "2000" ]] && break 2
        sleep 1
        (( waited++ ))
      done
      log "    still uid=$uid after a 15s poll (attempt $attempt/3) -- re-issuing unroot"
    done
    [[ "$uid" == "2000" ]] || { fail "device still not shell uid after 3 unroot+reauth attempts (uid=$uid)"; return 1; }
    pass "unrooted back to shell uid=2000 before regression baseline"
  fi
  return 0
}

# boot the vm for a posture
boot_posture() {
  local posture="$1"
  step "boot ($posture posture)"
  kill_vm
  boot_vm
  wait_for_boot_slot || { fail "vm $RHIZO_VM never got a qemu slot for the $posture boot"; return 1; }
  if ! wait_for_ssh 240; then
    fail "SSH never came up"
    "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV/boot-failure-$posture" "certified-pair-$posture-ssh-never-up"
    return 1
  fi
  ../../vm/start/start-sway.sh >"$EV/certified-pair-sway.log" 2>&1 || { fail "sway did not start"; return 1; }
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; return 1; }
  if [[ "$posture" == cts ]] && cts_needs_ftrace; then
    arm_ftrace || return 1
  else
    disarm_ftrace
  fi
  local -a redeploy_args=(--skip-kill --boot-wait 180)
  [[ -n "$VARIANT_GSI" ]] && redeploy_args+=(--gsi "$VARIANT_GSI")
  if [[ "$posture" == "vts" && "$VARIANT" == "user" ]]; then
    RHIZO_ADB_ROOT=1 ../../vm/redeploy.sh "${redeploy_args[@]}" >"$EV/certified-pair-redeploy.log" 2>&1 \
      || { fail "redeploy.sh failed (see $EV/certified-pair-redeploy.log)"; return 1; }
  else
    ../../vm/redeploy.sh "${redeploy_args[@]}" >"$EV/certified-pair-redeploy.log" 2>&1 \
      || { fail "redeploy.sh failed (see $EV/certified-pair-redeploy.log)"; return 1; }
  fi
  tail -6 "$EV/certified-pair-redeploy.log"
  ssh_vm 'systemctl stop rhizo-resync.path rhizo-resync.service 2>/dev/null' \
    || log "WARNING: could not stop rhizo-resync.path"
}

# run launcher.sh on the booted vm
regression_baseline() {
  local label="$1"
  step "regression baseline ($label): launcher.sh --skip-boot"
  if "$(system_test_file launcher.sh)" --skip-boot > "$EV/test-launcher-baseline-$label.log" 2>&1; then
    pass "launcher.sh clean ($label)"
  else
    fail "launcher.sh FAILED ($label) -- see $EV/test-launcher-baseline-$label.log"
    tail -20 "$EV/test-launcher-baseline-$label.log"
  fi
}

# save guest failure logs to the evidence dir
capture_failure_evidence() {
  local run_ev="$1" reason="$2"
  log "    capturing failure evidence into $run_ev (reason: $reason)"
  local init_pid; init_pid=$(guest_init_pid 8)
  if [[ -z "$init_pid" ]]; then
    echo "no init_pid found (reason: $reason)" \
      > "$run_ev/failure-evidence-FAILED.txt"
    return 0
  fi
  logcat_vm "$init_pid" -b all -d > "$run_ev/failure-logcat.txt" 2>&1
  local tomb_out
  tomb_out=$(android_sh "$init_pid" "ls -t /data/tombstones/; echo RHIZO_TOMBSTONE_LS_OK")
  if [[ "$tomb_out" != *RHIZO_TOMBSTONE_LS_OK* ]]; then
    echo "TOMBSTONE-READ-FAILED: /data/tombstones could not be listed" \
      > "$run_ev/failure-tombstone-list.txt"
  else
    { printf '%s\n' "${tomb_out%%RHIZO_TOMBSTONE_LS_OK*}" | tr -d '\r' | grep '^tombstone' | head -3
      echo "TOMBSTONE-READ-OK"; } > "$run_ev/failure-tombstone-list.txt"
  fi
  local tomb
  tomb=$(grep -m1 '^tombstone' < "$run_ev/failure-tombstone-list.txt")
  if [[ -n "$tomb" ]]; then
    android_sh "$init_pid" "cat /data/tombstones/$tomb" > "$run_ev/failure-tombstone.txt" 2>&1
  fi
  android_sh "$init_pid" "dumpsys activity; echo ===MEMINFO===; dumpsys meminfo" \
    > "$run_ev/failure-dumpsys.txt" 2>&1
  echo "$reason" > "$run_ev/failure-reason.txt"
}

# print the evidence label for a module
sublabel_for() { local label="$1" m="$2"; [[ -n "$m" ]] && echo "$label-$m" || echo "$label"; }

# find the newest finished test_result.xml
find_resumable_xml() {
  local sublabel="$1" d ts xml best="" best_ts=-1
  for d in "$EV/$sublabel"-[0-9]*; do
    [[ -d "$d" ]] || continue
    ts="${d##*-}"
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    (( ts < RESUME_SINCE )) && continue
    xml="$d/test_result.xml"
    [[ -f "$xml" ]] || continue
    grep -q 'done="true"' "$xml" || continue
    (( ts > best_ts )) && { best_ts=$ts; best="$xml"; }
  done
  [[ -n "$best" ]] && echo "$best"
}

# run tradefed for each module
run_tradefed() {
  local root="$1" tf="$2" plan="$3" label="$4"; shift 4
  local modules=("$@")
  (( ${#modules[@]} == 0 )) && modules=("")
  local m xml sublabel resumed any_failed=0
  for m in "${modules[@]}"; do
    if (( RESUME )); then
      sublabel=$(sublabel_for "$label" "$m")
      resumed=$(find_resumable_xml "$sublabel")
      if [[ -n "$resumed" ]]; then
        log "  --resume: $sublabel already has a done=true result at $resumed -- skipping re-run"
        echo "$resumed"
        continue
      fi
    fi
    bring_up_adb || { any_failed=1; continue; }
    xml=$(run_tradefed_one "$root" "$tf" "$plan" "$label" "$m") || { any_failed=1; continue; }
    echo "$xml"
  done
  (( any_failed )) && log "run_tradefed($label): one or more modules failed -- see the per-module FAIL lines above"
  return 0
}

# run tradefed for a module
run_tradefed_one() {
  local root="$1" tf="$2" plan="$3" label="$4" module="$5"
  local sublabel; sublabel=$(sublabel_for "$label" "$module")
  local run_ev; run_ev="$EV/$sublabel-$(date +%s)"
  mkdir -p "$run_ev"
  local mod_args=(); [[ -n "$module" ]] && mod_args=(-m "$module")
  local java_home
  java_home=$(suite_java_home "$root") || { fail "$sublabel: no JDK to run it under"; return 1; }
  log "  $sublabel runs under $java_home"

  local extra_args=()
  [[ "$plan" != "vts" ]] && extra_args+=(--has-server-side-config false)
  save_adb_verification
  local cmd=("$root/$tf" run "$plan" --serial "127.0.0.1:$ADB_PORT" --abi "$CTS_ABI"
             --disable-reboot --skip-preconditions
             "${extra_args[@]}" "${mod_args[@]}")
  printf '%q ' "${cmd[@]}" > "$run_ev/invocation.txt"; echo >> "$run_ev/invocation.txt"
  if grep -qE -- '--include-filter|--exclude-filter|--retry' "$run_ev/invocation.txt"; then
    fail "invocation for $sublabel contains a forbidden filter/retry flag -- refusing to run"
    return 1
  fi

  step "$sublabel: ${cmd[*]}"
  local ring_init; ring_init=$(guest_init_pid 8)
  if [[ -n "$ring_init" ]]; then
    android_sh "$ring_init" "logcat -b all -G ${RHIZO_CTS_LOGCAT_RING:-64M}" >/dev/null 2>&1
    android_sh "$ring_init" "logcat -b all -g" > "$run_ev/logcat-ring-sizes.txt" 2>&1
  else
    echo "no init second_stage" \
      > "$run_ev/logcat-ring-sizes.txt"
  fi
  ( while true; do
      { echo "=== $(date +%H:%M:%S) ==="
        ssh_vm -t 12 'cat /proc/meminfo | head -5; echo ---; top -bn1 2>/dev/null | head -15; echo ---; ps -eL -o pid,tid,stat,wchan:28,time,comm --sort=-time 2>/dev/null | head -25' 2>/dev/null
      } >> "$run_ev/guest-resource-sampler.log"
      sleep 30
    done ) &
  local sampler_pid=$!

  ( export JAVA_HOME="$java_home" PATH="$java_home/bin:$root/tools:$SHARE_DIR:$HOME/Android/Sdk/platform-tools:$PATH"
    export LD_LIBRARY_PATH="$SHARE_DIR/aapt-libs:${LD_LIBRARY_PATH:-}"
    export ANDROID_SERIAL="127.0.0.1:$ADB_PORT"
    export USE_ATS=false
    cd "$run_ev" || exit
    timeout -k 30 3600 setsid "${cmd[@]}" > "$run_ev/console.log" 2>&1 &
    cmdpid=$!
    echo "$cmdpid" > "$run_ev/tradefed.pid"
    wait "$cmdpid"; ec=$?
    if (( ec >= 128 )); then
      echo "SIGNALED signal=$((ec - 128)) ($(kill -l $((ec - 128)) 2>/dev/null))" > "$run_ev/tradefed.exit_reason"
    else
      echo "EXITED code=$ec" > "$run_ev/tradefed.exit_reason"
    fi ) &
  local launcher_pid=$!
  wait "$launcher_pid"
  local tf_pid; tf_pid=$(cat "$run_ev/tradefed.pid" 2>/dev/null)
  [[ -n "$tf_pid" ]] || { kill "$sampler_pid" 2>/dev/null; fail "$sublabel: could not capture tradefed pid"; return 1; }

  local deadline=$(( $(date +%s) + 3600 )) hung=0
  while kill -0 "$tf_pid" 2>/dev/null; do
    if (( $(date +%s) > deadline )); then
      qmp_status > "$run_ev/qmp-status-at-timeout.txt" 2>&1 || true
      if ! timeout 10 ~/Android/Sdk/platform-tools/adb -s 127.0.0.1:$ADB_PORT shell true >/dev/null 2>&1; then
        hung=1
      fi
      break
    fi
    sleep 15
  done
  kill "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null
  if (( hung )); then
    kill "$tf_pid" 2>/dev/null || true
    capture_failure_evidence "$run_ev" "adb unresponsive past deadline"
    fail "$sublabel: guest appears hung (adb unresponsive past deadline) -- killed tradefed by pid, no partial result salvaged"
    return 1
  fi
  log "    $sublabel tradefed process exited ($(cat "$run_ev/tradefed.exit_reason" 2>/dev/null || echo 'exit reason not captured'))"

  local candidates; candidates=$(find "$root" -path "*/results/*/test_result.xml" -newer "$run_ev/tradefed.pid" 2>/dev/null)
  local n_candidates; n_candidates=$(grep -c . <<<"$candidates" 2>/dev/null || echo 0)
  if (( n_candidates > 1 )); then
    capture_failure_evidence "$run_ev" "ambiguous result: $n_candidates candidate test_result.xml files"
    fail "$sublabel: $n_candidates candidate test_result.xml files newer than this run's tradefed.pid -- refusing to guess. Candidates:"$'\n'"$candidates"
    return 1
  fi
  local result_xml="$candidates"
  if [[ -z "$result_xml" ]]; then
    capture_failure_evidence "$run_ev" "no test_result.xml produced"
    fail "$sublabel: no test_result.xml produced -- see $run_ev/console.log"
    return 1
  fi
  cp "$result_xml" "$run_ev/test_result.xml"
  local summary done_n total_n
  summary=$(grep -o '<Summary[^>]*>' "$run_ev/test_result.xml" 2>/dev/null | head -1)
  done_n=$(sed -n 's/.*modules_done="\([0-9]*\)".*/\1/p' <<<"$summary")
  total_n=$(sed -n 's/.*modules_total="\([0-9]*\)".*/\1/p' <<<"$summary")
  if [[ -n "$total_n" && "$total_n" != 0 && "$done_n" == 0 ]]; then
    capture_failure_evidence "$run_ev" "module did not run to completion ($summary)"
  fi
  log "    $sublabel result: $run_ev/test_result.xml"
  echo "$run_ev/test_result.xml"
}

# run tradefed for a posture
do_posture() {
  local posture="$1"
  if (( SKIP_BOOT == 0 )); then
    boot_posture "$posture" || return 1
  elif [[ "$posture" == cts ]] && cts_needs_ftrace; then
    local ft
    ft=$(ssh_vm -t 15 "dmesg | grep -ao 'RHIZO_MARKER ftrace=[a-z]*' | tail -1")
    [[ "$ft" == *ftrace=on ]] || { fail "--skip-boot onto a boot with '${ft:-no ftrace marker}', and this cts selection needs trace.ftrace on -- run without --skip-boot so the system test arms it"; return 1; }
  fi

  regression_baseline "${posture}-start"

  bring_up_adb || { fail "adb-tunnel.sh up failed at ${posture} start"; return 1; }

  local xml=""
  if [[ "$posture" == "vts" ]]; then
    require_suite "$VTS_ROOT" tools/vts-tradefed VTS || return 1
    if [[ -n "$DEV_MODULE" ]]; then
      xml=$(run_tradefed "$VTS_ROOT" tools/vts-tradefed vts "vts-dev" "$DEV_MODULE")
    elif (( FULL )); then
      xml=$(run_tradefed "$VTS_ROOT" tools/vts-tradefed vts "vts-full")
    else
      xml=$(run_tradefed "$VTS_ROOT" tools/vts-tradefed vts "vts" "${VTS_MODULES[@]}")
    fi
  else
    require_suite "$CTS_ROOT" tools/cts-tradefed CTS || return 1
    if [[ -n "$DEV_MODULE" ]]; then
      xml=$(run_tradefed "$CTS_ROOT" tools/cts-tradefed cts-on-gsi "cts-dev" "$DEV_MODULE")
    elif (( FULL )); then
      xml=$(run_tradefed "$CTS_ROOT" tools/cts-tradefed cts-on-gsi "cts-full")
    else
      xml=$(run_tradefed "$CTS_ROOT" tools/cts-tradefed cts-on-gsi "cts" "${CTS_MODULES[@]}")
    fi
  fi
  [[ -n "$xml" ]] || return 1

  ensure_unrooted || return 1
  regression_baseline "${posture}-end"
  return 0
}

RUN_VTS=1; RUN_CTS=1
[[ "$POSTURE" == "vts" ]] && RUN_CTS=0
[[ "$POSTURE" == "cts" ]] && RUN_VTS=0
[[ -n "$DEV_MODULE" ]] && { [[ -z "$POSTURE" ]] && { fail "--dev-subset requires --posture vts|cts"; exit 1; }; }

if (( RUN_VTS )); then do_posture vts || FAILED=1; fi
if (( RUN_CTS )); then do_posture cts || FAILED=1; fi

case "$POSTURE" in
  vts) _verdict_mn=${#VTS_MODULES[@]} ;;
  *)   _verdict_mn=${#CTS_MODULES[@]} ;;
esac
_verdict_meta="variant=$VARIANT posture=$POSTURE abi=$CTS_ABI"
if [[ -n "$MODULES_FILE" ]]; then
  _verdict_meta="$_verdict_meta modules_file=$(basename "$MODULES_FILE") modules_n=$_verdict_mn"
else
  _verdict_meta="$_verdict_meta modules_file=<builtin> modules_n=$_verdict_mn"
fi
if [[ -n "$DEV_MODULE" ]]; then _verdict_meta+=" dev_subset=$DEV_MODULE"; fi
if (( FULL )); then _verdict_meta+=" full=1"; fi
if (( RESUME )); then _verdict_meta+=" resume=1 resume_since=$RESUME_SINCE"; fi
if (( SHARD_COUNT > 1 )) && [[ "${RHIZO_TEST_ARGS:-}" != *--shard-count* ]]; then
  _verdict_meta+=" shard=$SHARD_INDEX/$SHARD_COUNT"
fi
if (( FAILED )); then test_record_verdict FAILED "$_verdict_meta"; log "CERTIFIED-PAIR SYSTEM TEST FAILED"; exit 1; fi
test_record_verdict PASSED "$_verdict_meta"
log "CERTIFIED-PAIR SYSTEM TEST PASSED -- evidence in $EV"
