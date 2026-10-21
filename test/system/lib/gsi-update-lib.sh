#!/bin/bash
# define the GSI update assertions
# shellcheck disable=SC2034

_GSI_UPDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# assert that the desk app launches
assert_deskapp_launches() {
  local label="$1" out="" tok="" deadline amstart since amerr events fatal_lines tag token
  case "${DESKAPP_LAUNCH_CONFIRM:-clip}" in
    clip) tag=RhizoDeskApp:I token="RHIZO_CLIP_" ;;
    displayed) tag=ActivityTaskManager:I token="Displayed $DESKAPP_PKG/" ;;
    *) fail "$label: DESKAPP_LAUNCH_CONFIRM='$DESKAPP_LAUNCH_CONFIRM' names no launch confirmation"; return 1 ;;
  esac
  amstart="$(test_scratch_log "$label-amstart")"
  since="$(test_scratch_log "$label-logcat-since-launch")"
  capture_full_logcat "$label"
  android_sh "$INIT" "am force-stop $DESKAPP_PKG" >/dev/null 2>&1
  logcat_vm "$INIT" -c >/dev/null 2>&1
  out=$(logcat_vm "$INIT" -d -s "$tag" 2>/dev/null | tr -d '\r')
  echo "${out:-<none>}" > "$(test_scratch_log "$label-logcat-before-launch")"
  if grep -qF "$token" <<<"$out"; then
    echo '<none>' > "$(test_scratch_log "$label-logcat")"
    echo '<none>' > "$since"
    fail "$label: the ring still holds an earlier '$token' line after logcat -c -- see $(test_scratch_log "$label-logcat-before-launch")"
    return 1
  fi
  out=""
  android_sh "$INIT" "am start -n $DESKAPP_PKG/$DESKAPP_ACT --es cmd clip_read" > "$amstart" 2>&1
  amerr=$(amstart_error "$amstart")
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    out=$(logcat_vm "$INIT" -d -s "$tag" 2>/dev/null | tr -d '\r')
    grep -qF "$token" <<<"$out" && { tok=1; break; }
    sleep 2
  done
  echo "$out" > "$(test_scratch_log "$label-logcat")"
  # test-log-window: safe -- logcat_vm "$INIT" -c above cleared the ring
  logcat_vm "$INIT" -d -v threadtime -t 4000 2>/dev/null > "$since"
  events=$(count_crash_events "$since")
  fatal_lines=$(grep -cE "$TEST_FATAL_RE" "$since")
  if [[ -n "$amerr" ]]; then
    fail "$label: am start did not launch $DESKAPP_PKG: $amerr (crash_events=$events fatal_lines=$fatal_lines) -- see $amstart"
  elif [[ -n "$tok" ]] && (( events == 0 )); then
    pass "$label: $DESKAPP_PKG launched, logcat shows its own '$token' line"
  else
    fail "$label: $DESKAPP_PKG did not confirm launch (token-seen=${tok:-0} crash_events=$events fatal_lines=$fatal_lines) -- see $since"
  fi
}

# return true only when the capture holds a logcat line
logcat_capture_read() {
  grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' "$1"
}

# save the whole boot's system logcat
capture_full_logcat() {
  local f; f="$(test_scratch_log "$1-full-logcat")"
  logcat_vm "$INIT" -d -v threadtime -t 8000 2>/dev/null > "$f"
  logcat_capture_read "$f" && return 0
  fail "$1: the system logcat capture holds no logcat line -- see $f"
  return 1
}

CRASH_EVENT_GAP_S=2
# print the number of crash events in a logcat file
count_crash_events() {
  grep -E "$TEST_FATAL_RE" "$1" \
    | awk '{
        if ($0 ~ /^[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9] /)
          printf "%.3f\n", (substr($0, 1, 2) * 31 + substr($0, 4, 2)) * 86400 \
            + substr($0, 7, 2) * 3600 + substr($0, 10, 2) * 60 + substr($0, 13, 6)
        else
          print "untimed"
      }' \
    | LC_ALL=C sort -n \
    | awk -v gap="$CRASH_EVENT_GAP_S" '
        $1 == "untimed" { untimed = 1; next }
        !n || $1 - last > gap { n++ }
        { last = $1 }
        END { print (n ? n : untimed) + 0 }'
}

# print what am start reported in place of a launch
amstart_error() {
  local err
  err=$(grep -E "^Error|^Warning: Activity not started|Can't find service|^Exception occurred|cannot observe" "$1")
  [[ -z "$err" ]] && ! grep -q '^Starting: Intent' "$1" \
    && err="no 'Starting: Intent' line in am start's output: '$(head -c 200 "$1")'"
  [[ -n "$err" ]] || return 1
  printf '%s' "${err//$'\n'/ | }"
}

# stage a release's coupled files
stage_release() {
  local label="$1"
  local args=(--skip-kill --no-launch --release "$label")
  [[ "$label" == a16 ]] || args+=(--gsi "${GSI_DIR[$label]}")
  log "  staging $label's own coupled files"
  "$_GSI_UPDATE_LIB_DIR/../../vm/redeploy.sh" "${args[@]}" > "$(test_scratch_log "stage-release-$label")" 2>&1 \
    || fail "staging $label failed, see $(test_scratch_log "stage-release-$label")"
}

# assert the running system matches the tree's build.prop
assert_booted_release() {
  local to_rel="$1" tree="$2" rel live want
  rel=$(ssh_vm -t 20 "grep -hE '^ro\.system\.build\.version\.release=|^ro\.build\.version\.sdk=' '$tree/build.prop' 2>/dev/null | sort -u | tr '\n' ' '")
  log "  tree reports: ${rel:-<unreadable>}"
  want="$(sed -n 's/.*ro\.build\.version\.sdk=\([^ ]*\).*/\1/p' <<<"$rel") $(sed -n 's/.*ro\.system\.build\.version\.release=\([^ ]*\).*/\1/p' <<<"$rel")"
  live=$(android_sh "$INIT" "getprop ro.build.version.sdk; getprop ro.system.build.version.release" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
  live="${live% }"
  if [[ "$want" == " " || "$want" == *" " || "$want" == " "* ]]; then
    fail "could not read the $to_rel identity (sdk and release) from $tree/build.prop: '${rel:-<unreadable>}'"
  elif [[ "$live" == "$want" ]]; then
    pass "the running system reports sdk and release '$live', the $to_rel tree's own build.prop values"
  else
    fail "the running system reports sdk and release '${live:-<unreadable>}', the $to_rel tree's build.prop says '$want'"
  fi
}

# reboot the guest and start the sandbox
boot_and_start() {
  local label="$1" rel="$2" preceding="${3:-}" extra_env="${4:-}" stage_fn="${5:-stage_release}" refusal kv
  BOOT_REFUSED_BY=""
  TEST_BOOT_NO_ROW=""
  refusal=$(marker_line "$preceding" "RHIZO_GSI_UPDATE_(REFUSED|FAILED)")
  if [[ -n "$refusal" ]]; then
    BOOT_REFUSED_BY=product
    fail "$label: refusing to reboot: $refusal"
    return 1
  fi
  BOOT_REFUSED_BY=vm
  log "  rebooting the guest for $label, the way an armed update takes effect"
  ssh_vm -t 90 'systemctl stop androidd.service' >/dev/null 2>&1
  local key
  for key in ${GSI_LEG_PER_BOOT_KNOBS:-}; do
    ssh_vm -t 20 "sed -i '/^$key=/d' '${GSI_LEG_ENV_FILE:-/root/androidd.env}'"
  done
  kill_vm >/dev/null 2>&1 || { fail "$label: kill_vm could not confirm the old guest was torn down"; return 1; }
  boot_vm > "$(test_scratch_log "boot-$label")" 2>&1
  if ! wait_for_boot_slot; then
    fail "$label: vm $RHIZO_VM is still queued for a qemu slot"
    return 1
  fi
  if ! wait_for_ssh 300; then
    if [[ -n "$RHIZO_BOOT_REFUSAL" ]]; then
      BOOT_REFUSED_BY=refused
      [[ -z "${TEST_BOOTED:-}" ]] && TEST_BOOT_NO_ROW=1
      fail "$label: refused before any guest launched: $RHIZO_BOOT_REFUSAL"
      return 1
    fi
    fail "$label: ssh never came up after the reboot"
    return 1
  fi
  TEST_BOOTED=1
  wait_for_guest_ready 120 || log "  $label: guest not fully ready, staging anyway"
  if declare -F installer_post_reboot_hook >/dev/null; then
    installer_post_reboot_hook "$label"
  fi
  "$stage_fn" "$rel"
  local env_file="${GSI_LEG_ENV_FILE:-/root/androidd.env}"
  if [[ -n "$extra_env" ]]; then
    for kv in $extra_env; do
      if [[ " ${GSI_LEG_SKIP_KNOBS:-} " == *" ${kv%%=*} "* ]]; then
        log "  $label: not arming ${kv%%=*}, a knob GSI_LEG_SKIP_KNOBS keeps off this caller's host"
        continue
      fi
      log "  $label: arming $kv in $env_file, after staging so redeploy.sh's own truncate-and-rewrite cannot silently wipe it before this boot's own start -- test/checks/system/gsi-update/fault-knob.py and test/checks/system/gsi-update/release-switch-marker.sh both own pieces of this contract"
      ssh_vm -t 20 "grep -q '^${kv%%=*}=' '$env_file' 2>/dev/null \
        && sed -i 's/^${kv%%=*}=.*/${kv}/' '$env_file' \
        || echo '$kv' >> '$env_file'"
    done
  fi
  ssh_vm -t 60 'systemctl start androidd.service' > "$(test_scratch_log "start-$label")" 2>&1
  log "  $label: androidd start returned"
  return 0
}

# print the last line with the given prefix
marker_line() {
  grep -E "^$2" <<<"$1" | tail -1
}

# print the journals and states of the update units
capture_units() {
  local env_file="${GSI_LEG_ENV_FILE:-/root/androidd.env}" out
  out="$(test_scratch_log "units-$1")"
  ssh_vm -t 30 'journalctl -u androidd.service -u rhizo-update-begin.service \
      -u rhizo-update-confirm.service --no-pager -n 300 2>&1
    echo "--- is-active ---"
    systemctl is-active androidd.service rhizo-update-begin.service rhizo-update-confirm.service 2>&1
    echo "--- update state ---"
    cat /var/lib/rhizo/update/state 2>&1' > "$out" 2>&1
  { echo "--- $env_file ---"; ssh_vm -t 15 "cat '$env_file' 2>&1"; } >> "$out" 2>&1
  log "  units journal -> $(test_scratch_log "units-$1")"
}

# read this boot's dmesg into the label's scratch log
capture_boot_dmesg() {
  local f rc end="whole records"
  f="$(test_scratch_log "dmesg-$1")"
  ssh_vm -t 30 'dmesg' > "$f" 2>&1
  rc=$?
  [[ -s "$f" ]] || end="empty"
  [[ -s "$f" && -n "$(tail -c1 "$f")" ]] && end="ends mid-record"
  DMESG_READ="rc=$rc bytes=$(stat -c %s "$f") $end"
  (( rc == 0 )) && [[ "$end" == "whole records" ]]
}

# check the boot's dmesg for a marker
boot_dmesg_has() {
  capture_boot_dmesg "$1"
  grep -q "$2" "$(test_scratch_log "dmesg-$1")"
}

# fail on a keymint_migration=removed marker
assert_no_keymint_sweep() {
  local label="$1" f swept deadline
  f="$(test_scratch_log "dmesg-$label")"
  deadline=$(( $(date +%s) + 60 ))
  while :; do
    if ! capture_boot_dmesg "$label"; then
      fail "$label: incomplete dmesg read ($DMESG_READ) -- see $f"
      return
    fi
    grep -q "RHIZO_MARKER sys.boot_completed=1" "$f" && break
    (( $(date +%s) < deadline )) || break
    sleep 5
  done
  if ! grep -q "RHIZO_MARKER data_release=" "$f" || ! grep -q "RHIZO_MARKER sys.boot_completed=1" "$f"; then
    fail "$label: this boot's whole dmesg lacks RHIZO_MARKER data_release= or sys.boot_completed=1 60s after sys.boot_completed read 1 -- see $f"
    return
  fi
  swept=$(grep -m1 "RHIZO_MARKER keymint_migration=removed" "$f")
  if [[ -n "$swept" ]]; then
    fail "$label: the launcher swept keystore state this /data carried: ${swept#*RHIZO_MARKER } -- see $f"
  else
    pass "$label: no RHIZO_MARKER keymint_migration=removed on this boot, its /data kept its keystore state"
  fi
}

# read the marker from the unit that emitted it
unit_journal_has() {
  local f; f="$(test_scratch_log "journal-$1")"
  ssh_vm -t 30 "journalctl -u $2 --no-pager -n 500 2>&1" > "$f" 2>&1
  grep -q "$3" "$f"
}

# check a package is in the guest's package list
pkg_installed() {
  local f; f="$(test_scratch_log "pkgs-$1")"
  android_sh "$2" "pm list packages" | tr -d '\r' > "$f" 2>&1
  grep -qx "package:$3" "$f"
}

# poll for boot completion
poll_boot_completed() {
  local deadline_s="$1" deadline
  INIT=""; BC=""
  deadline=$(( $(date +%s) + deadline_s ))
  while (( $(date +%s) < deadline )); do
    INIT=$(guest_init_pid 10)
    [[ -n "$INIT" ]] && BC=$(getprop_vm "$INIT" sys.boot_completed)
    [[ "$BC" == "1" ]] && return 0
    sleep 8
  done
  return 1
}

# wait for user 0 to report RUNNING_UNLOCKED
poll_user0_unlocked() {
  local deadline
  USER0_STATE=""
  deadline=$(( $(date +%s) + $1 ))
  while (( $(date +%s) < deadline )); do
    USER0_STATE=$(android_sh "$INIT" "am get-started-user-state 0" | tr -d '\r')
    grep -qx RUNNING_UNLOCKED <<<"$USER0_STATE" && return 0
    sleep 3
  done
  return 1
}

# wait for the primer's enforcement flip
await_enforce_flip() {
  local label="$1" limit="${2:-120}" deadline e=""
  deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) < deadline )); do
    e=$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
    if [[ "$e" == 1 ]]; then
      pass "$label: the host primer flipped enforcement on (/sys/fs/selinux/enforce=1)"
      return 0
    fi
    sleep 2
  done
  fail "$label: /sys/fs/selinux/enforce is still '${e:-<unreadable>}' ${limit}s after user 0 unlocked"
  return 1
}


# run the arm-and-confirm update leg
gsi_leg_update() {
  local label_prefix="$1" update_sh="$2" from_rel="$3" to_rel="$4" tries="$5" stage_fn="${6:-stage_release}"
  local update_out last status_out

  step "2. update $from_rel -> $to_rel: one real confirmed boot, /data really copied, the APK survives"
  ssh_vm -t 90 'systemctl stop androidd.service' > "$(test_scratch_log ${label_prefix}-stop)" 2>&1

  update_out=$(ssh_vm -t 300 "$update_sh update --release $to_rel --tries $tries" 2>&1)
  echo "$update_out" > "$(test_scratch_log ${label_prefix}-update)"
  last=$(marker_line "$update_out" "RHIZO_GSI_UPDATE")
  LC_GSI_ARM_STATUS="$last"
  [[ "$last" == "RHIZO_GSI_UPDATE current=$from_rel candidate=$to_rel tries=$tries previous=-" ]] \
    && pass "armed the $to_rel trial: $last" \
    || fail "arming the $to_rel trial: final line is '$last', want current=$from_rel candidate=$to_rel tries=$tries previous=-"

  ssh_vm -t 15 '[ -s /var/lib/rhizo/update/trial-data.img ]' \
    && pass "trial-data.img exists after arming the $to_rel trial" \
    || fail "/var/lib/rhizo/update/trial-data.img is missing or empty after update --release $to_rel"

  ssh_vm -t 15 "[ -s '${GSI_DIR[$from_rel]}/bin/init' ]" \
    && pass "the $from_rel tree is still staged at ${GSI_DIR[$from_rel]}" \
    || fail "the $from_rel tree at ${GSI_DIR[$from_rel]} is gone after arming the $to_rel trial"

  log "starting androidd"
  if boot_and_start "${label_prefix}-trial" "$to_rel" "$update_out" RHIZO_RELEASE_SWITCH=1 "$stage_fn"; then
    capture_units ${label_prefix}-after-start

    if ! poll_boot_completed 600; then
      fail "the $to_rel trial never reached sys.boot_completed within 600s"
      test_collect_boot_evidence "gsi-update-$to_rel-trial-no-boot"
    else
      pass "the $to_rel trial reached sys.boot_completed"
      if poll_user0_unlocked 120; then
        pass "the $to_rel trial's user 0 reached RUNNING_UNLOCKED"
      else
        fail "the $to_rel trial's user 0 never reached RUNNING_UNLOCKED within 120s of sys.boot_completed (last am get-started-user-state 0 answer: '$USER0_STATE')"
      fi
      await_enforce_flip "the $to_rel trial"

      boot_dmesg_has ${label_prefix}-trial "RHIZO_MARKER data_release_changed=$from_rel-to-$to_rel" \
        && pass "the launcher took the declared-release-change branch, not a refusal" \
        || fail "no RHIZO_MARKER data_release_changed=$from_rel-to-$to_rel in this boot's dmesg ($DMESG_READ)"
      assert_no_keymint_sweep ${label_prefix}-trial

      assert_booted_release "$to_rel" "${GSI_DIR[$to_rel]}"

      pkg_installed ${label_prefix}-trial "$INIT" "$DESKAPP_PKG" \
        && pass "$DESKAPP_PKG survived the $from_rel -> $to_rel /data copy" \
        || fail "$DESKAPP_PKG is gone from pm list packages after the $to_rel trial boot"
      assert_deskapp_launches "${label_prefix}-$to_rel-trial"
    fi
  else
    [[ "$BOOT_REFUSED_BY" == refused ]] && test_collect_boot_evidence "test-vm-refused"
    [[ "$BOOT_REFUSED_BY" == vm ]] && test_collect_boot_evidence "test-vm-never-came-up"
    fail "${label_prefix}-trial: not run -- boot_and_start failed ($BOOT_REFUSED_BY)"
  fi

  status_out=$(ssh_vm -t 20 "$update_sh status" 2>&1); echo "$status_out" > "$(test_scratch_log ${label_prefix}-status)"
  last=$(marker_line "$status_out" "RHIZO_GSI_UPDATE ")
  LC_GSI_CONFIRM_STATUS="$last"
  [[ "$last" == "RHIZO_GSI_UPDATE current=$to_rel candidate=- tries=- previous=$from_rel" ]] \
    && pass "gsi status reflects the promoted $to_rel (previous=$from_rel recorded for rollback)" \
    || fail "gsi status after the confirmed boot is '$last', want current=$to_rel candidate=- tries=- previous=$from_rel"
}

# run the manual rollback leg after gsi_leg_update on the same vm
gsi_leg_manual_rollback() {
  local label_prefix="$1" update_sh="$2" from_rel="$3" to_rel="$4" stage_fn="${5:-stage_release}"
  local rollback_out last full_logcat downgrades

  step "3. manual rollback $to_rel -> $from_rel: the previous /data comes back, no downgrade crash"
  ssh_vm -t 90 'systemctl stop androidd.service' > "$(test_scratch_log ${label_prefix}-stop)" 2>&1

  rollback_out=$(ssh_vm -t 60 "$update_sh rollback" 2>&1)
  echo "$rollback_out" > "$(test_scratch_log ${label_prefix}-rollback)"
  last=$(marker_line "$rollback_out" "RHIZO_GSI_UPDATE ")
  LC_GSI_ROLLBACK_STATUS="$last"
  [[ "$last" == "RHIZO_GSI_UPDATE current=$from_rel candidate=- tries=- previous=-" ]] \
    && pass "rollback's final line reports current=$from_rel: $last" \
    || fail "rollback's final line is '$last', want current=$from_rel candidate=- tries=- previous=-"

  if boot_and_start "${label_prefix}-rollback" "$from_rel" "$rollback_out" RHIZO_RELEASE_SWITCH=1 "$stage_fn"; then
    capture_units ${label_prefix}-after-start
    if ! poll_boot_completed 300; then
      fail "the rolled-back $from_rel boot never reached sys.boot_completed within 300s"
      test_collect_boot_evidence "gsi-update-rollback-no-boot"
    else
      pass "the rolled-back $from_rel boot reached sys.boot_completed"
      if poll_user0_unlocked 120; then
        pass "the rolled-back $from_rel boot's user 0 reached RUNNING_UNLOCKED"
      else
        fail "the rolled-back $from_rel boot's user 0 never reached RUNNING_UNLOCKED within 120s of sys.boot_completed (last am get-started-user-state 0 answer: '$USER0_STATE')"
      fi
      await_enforce_flip "the rolled-back $from_rel boot"
      assert_no_keymint_sweep ${label_prefix}-rollback
      if boot_dmesg_has ${label_prefix}-rollback "RHIZO_MARKER data_release=$from_rel"; then
        local dmesg_f; dmesg_f="$(test_scratch_log "dmesg-${label_prefix}-rollback")"
        if [[ "$DMESG_READ" != *"whole records" ]]; then
          LC_GSI_ROLLBACK_DATA_RELEASE_OK=0
          fail "the rolled-back $from_rel boot's dmesg read is incomplete ($DMESG_READ)"
        elif grep -q "RHIZO_MARKER data_release_changed=" "$dmesg_f"; then
          LC_GSI_ROLLBACK_DATA_RELEASE_OK=0
          fail "the rolled-back $from_rel boot's dmesg carries a data_release_changed= marker"
        elif grep -q "RHIZO_MARKER release_switch_pending=found" "$dmesg_f"; then
          LC_GSI_ROLLBACK_DATA_RELEASE_OK=0
          fail "the rolled-back $from_rel boot's dmesg carries release_switch_pending=found"
        else
          LC_GSI_ROLLBACK_DATA_RELEASE_OK=1
          pass "the launcher read /data's own release marker as $from_rel after the manual rollback, with no data_release_changed=/release_switch_pending=found"
        fi
      else
        LC_GSI_ROLLBACK_DATA_RELEASE_OK=0
        fail "no RHIZO_MARKER data_release=$from_rel in this boot's dmesg ($DMESG_READ)"
      fi
      pkg_installed ${label_prefix}-rollback "$INIT" "$DESKAPP_PKG" \
        && pass "$DESKAPP_PKG survived the rollback's /data restore" \
        || fail "$DESKAPP_PKG is gone from pm list packages after rollback"

      assert_deskapp_launches "${label_prefix}-rollback"

      full_logcat="$(test_scratch_log ${label_prefix}-rollback-full-logcat)"
      if logcat_capture_read "$full_logcat"; then
        downgrades=$(grep -c "Can't downgrade database" "$full_logcat")
        (( downgrades == 0 )) \
          && pass "zero 'Can't downgrade database' lines anywhere in this boot's logcat" \
          || fail "$downgrades 'Can't downgrade database' line(s) in this boot's logcat -- see $full_logcat"
      else
        skip "the downgrade scan: $full_logcat holds no logcat line"
      fi
    fi
  else
    [[ "$BOOT_REFUSED_BY" == refused ]] && test_collect_boot_evidence "test-vm-refused"
    [[ "$BOOT_REFUSED_BY" == vm ]] && test_collect_boot_evidence "test-vm-never-came-up"
    fail "${label_prefix}-rollback: not run -- boot_and_start failed ($BOOT_REFUSED_BY)"
  fi
}

# run the exhaustion rollback leg
gsi_leg_exhaustion() {
  local label_prefix="$1" update_sh="$2" from_rel="$3" to_rel="$4" tries="$5" stage_fn="${6:-stage_release}"
  local update_out last try armed_marker status_out

  step "4. exhaustion: every try fails to reach boot_completed, the last start rolls back on its own"
  ssh_vm -t 90 'systemctl stop androidd.service' > "$(test_scratch_log ${label_prefix}-stop)" 2>&1

  update_out=$(ssh_vm -t 300 "$update_sh update --release $to_rel --tries $tries" 2>&1)
  echo "$update_out" > "$(test_scratch_log ${label_prefix}-update)"
  last=$(marker_line "$update_out" "RHIZO_GSI_UPDATE")
  [[ "$last" == "RHIZO_GSI_UPDATE current=$from_rel candidate=$to_rel tries=$tries previous=-" ]] \
    && pass "armed a $tries-try $to_rel trial for the exhaustion leg" \
    || fail "arming the exhaustion trial: final line is '$last', want current=$from_rel candidate=$to_rel tries=$tries previous=-"

  for try in $(seq 1 "$tries"); do
    log "  try $try: starting androidd"
    if boot_and_start "${label_prefix}-try-$try" "$to_rel" "" "RHIZO_FAULT_NO_READY=1 RHIZO_RELEASE_SWITCH=1" "$stage_fn"; then
      log "  try $try: start returned, polling for a completion that must not come"
      poll_boot_completed 90
      capture_units "${label_prefix}-try-$try"
      armed_marker=0
      boot_dmesg_has "${label_prefix}-try-$try" "RHIZO_MARKER fault_no_ready=armed" && armed_marker=1
      if [[ "$BC" == "1" ]]; then
        fail "try $try of $tries reached sys.boot_completed=1 with the fault knob armed"
      elif (( armed_marker == 0 )); then
        fail "try $try of $tries never reached sys.boot_completed, but dmesg ($DMESG_READ) carries no RHIZO_MARKER fault_no_ready=armed"
        test_collect_boot_evidence "gsi-update-exhaust-try$try-unexplained"
      else
        pass "try $try of $tries failed to boot on purpose (RHIZO_MARKER fault_no_ready=armed seen, sys.boot_completed never reached)"
      fi
    else
      [[ "$BOOT_REFUSED_BY" == refused ]] && test_collect_boot_evidence "test-vm-refused"
      [[ "$BOOT_REFUSED_BY" == vm ]] && test_collect_boot_evidence "test-vm-never-came-up"
      fail "${label_prefix}-try-$try: not run -- boot_and_start failed ($BOOT_REFUSED_BY)"
    fi
    log "  try $try: stopping androidd"
    ssh_vm -t 90 'systemctl stop androidd.service' >/dev/null 2>&1
    log "  try $try: stopped"
  done

  status_out=$(ssh_vm -t 20 "$update_sh status" 2>&1)
  last=$(marker_line "$status_out" "RHIZO_GSI_UPDATE ")
  LC_GSI_EXHAUST_TRIES_STATUS="$last"
  [[ "$last" == "RHIZO_GSI_UPDATE current=$from_rel candidate=$to_rel tries=0 previous=-" ]] \
    && pass "status shows 0 tries left after $tries failed starts" \
    || fail "status after $tries failed starts is '$last', want current=$from_rel candidate=$to_rel tries=0 previous=-"

  log "  starting the try-exhaustion rollback boot"
  if boot_and_start "${label_prefix}-final" "$from_rel" "" RHIZO_RELEASE_SWITCH=1 "$stage_fn"; then
    capture_units ${label_prefix}-after-final-start
    if ! poll_boot_completed 300; then
      fail "the try-exhaustion rollback boot never reached sys.boot_completed within 300s"
      test_collect_boot_evidence "gsi-update-exhaust-rollback-no-boot"
    else
      pass "the try-exhaustion rollback boot reached sys.boot_completed"
      if poll_user0_unlocked 120; then
        pass "the try-exhaustion rollback boot's user 0 reached RUNNING_UNLOCKED"
      else
        fail "the try-exhaustion rollback boot's user 0 never reached RUNNING_UNLOCKED within 120s of sys.boot_completed (last am get-started-user-state 0 answer: '$USER0_STATE')"
      fi
      await_enforce_flip "the try-exhaustion rollback boot"
      if unit_journal_has ${label_prefix}-final rhizo-update-begin.service \
          "RHIZO_MARKER gsi_update_rolled_back=$to_rel-to-$from_rel"; then
        LC_GSI_AUTOROLLBACK_MARKER_SEEN=1
        pass "the begin unit logged RHIZO_MARKER gsi_update_rolled_back=$to_rel-to-$from_rel when the tries ran out"
      else
        LC_GSI_AUTOROLLBACK_MARKER_SEEN=0
        fail "no RHIZO_MARKER gsi_update_rolled_back=$to_rel-to-$from_rel in rhizo-update-begin.service's journal"
      fi

      status_out=$(ssh_vm -t 20 "$update_sh status" 2>&1)
      last=$(marker_line "$status_out" "RHIZO_GSI_UPDATE ")
      LC_GSI_EXHAUST_FINAL_STATUS="$last"
      [[ "$last" == "RHIZO_GSI_UPDATE current=$from_rel candidate=- tries=- previous=-" ]] \
        && pass "status shows current=$from_rel candidate=- after the exhaustion rollback" \
        || fail "status after the exhaustion rollback is '$last', want current=$from_rel candidate=- tries=- previous=-"

      pkg_installed ${label_prefix}-final "$INIT" "$DESKAPP_PKG" \
        && pass "$DESKAPP_PKG survived the exhaustion rollback" \
        || fail "$DESKAPP_PKG is gone from pm list packages after the exhaustion rollback"
      assert_deskapp_launches "${label_prefix}-exhaust-rollback"

      boot_dmesg_has ${label_prefix}-final "RHIZO_MARKER data_release=$from_rel" \
        && pass "the launcher read /data's own release marker as $from_rel after the exhaustion rollback" \
        || fail "no RHIZO_MARKER data_release=$from_rel in this boot's dmesg ($DMESG_READ)"
    fi
  else
    [[ "$BOOT_REFUSED_BY" == refused ]] && test_collect_boot_evidence "test-vm-refused"
    [[ "$BOOT_REFUSED_BY" == vm ]] && test_collect_boot_evidence "test-vm-never-came-up"
    fail "${label_prefix}-final: not run -- boot_and_start failed ($BOOT_REFUSED_BY)"
  fi
}

# run the refused-fetch leg
gsi_leg_refused_fetch() {
  local label_prefix="$1" update_sh="$2" to_rel="$3" tries="${4:-3}"
  local before_status before_last fail_out last after_status after_last

  step "5. a fetch that fails a real sha256 check refuses the update cleanly and leaves state untouched"
  local t0; t0=$(guest_uptime)
  ssh_vm -t 90 'systemctl stop androidd.service' > "$(test_scratch_log ${label_prefix}-stop)" 2>&1

  before_status=$(ssh_vm -t 20 "$update_sh status" 2>&1)
  before_last=$(marker_line "$before_status" "RHIZO_GSI_UPDATE ")
  LC_GSI_REFUSED_STATUS_BEFORE="$before_last"

  ssh_vm -t 20 "dd if=/dev/urandom of=/root/rhizo-lifecycle-tampered-gsi.zip bs=1M count=1 2>/dev/null
    printf '%s\n' '#!/bin/bash' \
      'exec /usr/lib/rhizo/install/prepare/fetch-gsi.sh --from-zip /root/rhizo-lifecycle-tampered-gsi.zip \"\$@\"' \
    > /root/rhizo-lifecycle-fetch-stub.sh && chmod 0755 /root/rhizo-lifecycle-fetch-stub.sh"

  fail_out=$(ssh_vm -t 60 "RHIZO_FETCH_GSI=/root/rhizo-lifecycle-fetch-stub.sh $update_sh update --release $to_rel --tries $tries" 2>&1)
  echo "$fail_out" > "$(test_scratch_log ${label_prefix}-update)"

  local sha_last; sha_last=$(marker_line "$fail_out" "RHIZO_GSI_FAILED")
  LC_GSI_REFUSED_SHA_MISMATCH=0
  [[ "$sha_last" == "RHIZO_GSI_FAILED reason=sha256-mismatch" ]] \
    && { LC_GSI_REFUSED_SHA_MISMATCH=1; pass "the real fetch script's own sha256 check rejected the tampered zip: $sha_last"; } \
    || fail "the tampered-zip fetch printed '$sha_last', want RHIZO_GSI_FAILED reason=sha256-mismatch"

  last=$(marker_line "$fail_out" "RHIZO_GSI_UPDATE_FAILED")
  LC_GSI_REFUSED_LAST="$last"
  [[ "$last" == "RHIZO_GSI_UPDATE_FAILED reason=fetch" ]] \
    && pass "update refused cleanly when the fetch script failed (reason=fetch): $last" \
    || fail "update with a failing fetch printed '$last', want RHIZO_GSI_UPDATE_FAILED reason=fetch"

  after_status=$(ssh_vm -t 20 "$update_sh status" 2>&1)
  after_last=$(marker_line "$after_status" "RHIZO_GSI_UPDATE ")
  LC_GSI_REFUSED_STATUS_AFTER="$after_last"
  [[ -n "$before_last" && "$after_last" == "$before_last" ]] \
    && pass "gsi status is unchanged by the failed fetch ($after_last)" \
    || fail "gsi status changed after a failed fetch: before='$before_last' after='$after_last'"

  ssh_vm -t 15 'rm -f /root/rhizo-lifecycle-fetch-stub.sh /root/rhizo-lifecycle-tampered-gsi.zip' >/dev/null 2>&1

  ssh_vm -t 600 'systemctl start androidd.service' > "$(test_scratch_log "${label_prefix}-restart")" 2>&1
  wait_sandbox_started 420 "$t0" \
    && pass "androidd.service is back up after the refused-fetch leg" \
    || fail "the sandbox never reached boot_completed again after the refused-fetch leg's own stop"
}
