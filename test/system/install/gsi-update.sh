#!/bin/bash
# test the GSI update and rollback trials
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-verdict-params: exhaust_tries=2
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../../vm/image/release-map.sh
source ../lib/gsi-update-cleanup.sh
source ../lib/gsi-update-lib.sh

FAST=0
EXHAUST_TRIES=2
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1; EXHAUST_TRIES=1 ;;
    *) echo "usage: gsi-update.sh [--fast]" >&2; exit 2 ;;
  esac
done

test_require_staged rhizo-deskapp.apk || exit 1

test_init gsi-update

GSI_UPDATE_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

export RHIZO_USE_UNIT=1

export RHIZO_LOOP_MAX_LOOP=64

UPDATE_SH="/usr/lib/rhizo/install/update/gsi-update.sh"
DESKAPP_APK="$VAR_DIR/share/rhizo-deskapp.apk"
DESKAPP_PKG="com.rhizo.deskapp"
# shellcheck disable=SC2034
DESKAPP_ACT="com.rhizo.deskapp.MainActivity"
ADB=~/Android/Sdk/platform-tools/adb

# stop the sandbox and clear the update state
gsi_update_cleanup() {
  local rc=$? out body_rc
  capture_units cleanup 2>/dev/null || true
  out="$(test_scratch_log cleanup-body)"
  gsi_update_cleanup_body 90 "$GSI_UPDATE_RUN_ID" > "$out" 2>&1
  body_rc=$?
  if gsi_update_cleanup_verify 30 "$GSI_UPDATE_RUN_ID"; then
    if [[ -n "${GSI_UPDATE_CLEANUP_FOREIGN_MSG:-}" ]]; then
      log "CLEANUP_OK: this run's own update state and androidd.env keys are cleared; an EARLIER run's backup is still on vm $RHIZO_VM (next line)"
    else
      log "CLEANUP_OK: leftover update state cleared, this run's own androidd.env keys stripped -- vm $RHIZO_VM is clean"
    fi
    [[ -n "${EV:-}" ]] && rm -f "$EV/CLEANUP-INCOMPLETE"
  else
    log "CLEANUP_INCOMPLETE: $GSI_UPDATE_CLEANUP_VERIFY_MSG (cleanup body rc=$body_rc, see $out) -- test/system/manual/gsi-update-vm-reset.sh $RHIZO_VM clears it by hand"
    if [[ -n "${EV:-}" ]]; then
      printf '%s\tstep=cleanup\tCLEANUP_INCOMPLETE: %s (cleanup body rc=%s, see %s)\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GSI_UPDATE_CLEANUP_VERIFY_MSG" "$body_rc" "$out" >> "$EV/failures.log" 2>/dev/null
      printf 'CLEANUP_INCOMPLETE: %s (cleanup body rc=%s, see %s) -- test/system/manual/gsi-update-vm-reset.sh %s clears it by hand\n' \
        "$GSI_UPDATE_CLEANUP_VERIFY_MSG" "$body_rc" "$out" "$RHIZO_VM" > "$EV/CLEANUP-INCOMPLETE" 2>/dev/null
    fi
  fi
  if [[ -n "${GSI_UPDATE_CLEANUP_FOREIGN_MSG:-}" ]]; then
    log "$GSI_UPDATE_CLEANUP_FOREIGN_MSG"
    [[ -n "${EV:-}" ]] && printf '%s\n' "$GSI_UPDATE_CLEANUP_FOREIGN_MSG" > "$EV/FOREIGN-BACKUP-LEFT" 2>/dev/null
  else
    [[ -n "${EV:-}" ]] && rm -f "$EV/FOREIGN-BACKUP-LEFT"
  fi
  return $rc
}
trap 'gsi_update_cleanup; test_cleanup' EXIT

step "0. vm reachable, no leftover update state, a15 tree staged before enforcement flips"
test_boot --skip-graphics-preflight || { test_record_verdict FAILED; exit 1; }

update_state=$(ssh_vm -t 15 "[ -e /var/lib/rhizo/update ] && echo PRESENT || echo ABSENT" | tr -d '\r')
if [[ "$update_state" != ABSENT ]]; then
  fail "a previous run left /var/lib/rhizo/update on this vm, and this run's cleanup is about to remove it; if it does not report CLEANUP_OK, run test/system/manual/gsi-update-vm-reset.sh $RHIZO_VM by hand before retrying"
  test_record_verdict FAILED
  exit 1
fi
pass "no leftover /var/lib/rhizo/update on this vm"

../../vm/image/stage-gsi-trees.sh a15 > "$(test_scratch_log stage-a15)" 2>&1 \
  || { fail "stage-gsi-trees.sh a15 failed, see $(test_scratch_log stage-a15)"; test_record_verdict FAILED; exit 1; }
pass "a15 tree staged at ${GSI_DIR[a15]} while the guest is still permissive"

step "1. a15 baseline: real boot, a real APK installed for /data to carry, gsi status reads clean"
../../vm/sync.sh > "$(test_scratch_log sync)" 2>&1 || fail "sync.sh failed, see $(test_scratch_log sync)"

data_img=$(ssh_vm -t 15 "if [ -e /var/lib/rhizo/test-gsi-update-backup.img.absent ]; then echo LEFTOVER; elif [ -e /var/lib/rhizo/data.img ]; then echo PRESENT; else echo ABSENT; fi" | tr -d '\r')
if [[ "$data_img" == LEFTOVER ]]; then
  fail "an earlier run's absent-baseline marker (test-gsi-update-backup.img.absent) is still on this vm -- left untouched; test/system/manual/gsi-update-vm-reset.sh ${RHIZO_VM:-<vm>} clears it"
  test_record_verdict FAILED
  exit 1
fi
if [[ "$data_img" == ABSENT ]]; then
  if ssh_vm -t 60 "[ ! -e /var/lib/rhizo/test-gsi-update-backup.img ] && [ ! -e /var/lib/rhizo/test-gsi-update-backup.img.taken ] && [ ! -e /var/lib/rhizo/test-gsi-update-backup.img.absent ] && { cp -a /var/lib/rhizo/data.img.meta /var/lib/rhizo/test-gsi-update-backup.img.meta 2>/dev/null || rm -f /var/lib/rhizo/test-gsi-update-backup.img.meta; } && touch /var/lib/rhizo/test-gsi-update-backup.img.absent && echo '$GSI_UPDATE_RUN_ID' > /var/lib/rhizo/test-gsi-update-backup.img.taken"; then
    pass "no data.img on this vm before the test: that absence recorded for the cleanup trap to restore (run $GSI_UPDATE_RUN_ID)"
  else
    fail "no data.img on this vm, and recording that absence failed or an earlier run's backup or sentinel is still here"
    test_record_verdict FAILED
    exit 1
  fi
elif ssh_vm -t 60 "cp -a /var/lib/rhizo/data.img /var/lib/rhizo/test-gsi-update-backup.img && { cp -a /var/lib/rhizo/data.img.meta /var/lib/rhizo/test-gsi-update-backup.img.meta 2>/dev/null || rm -f /var/lib/rhizo/test-gsi-update-backup.img.meta; } && [ -s /var/lib/rhizo/test-gsi-update-backup.img ] && echo '$GSI_UPDATE_RUN_ID' > /var/lib/rhizo/test-gsi-update-backup.img.taken"; then
  pass "pre-test data.img snapshotted to test-gsi-update-backup.img for the cleanup trap to restore (run $GSI_UPDATE_RUN_ID)"
else
  fail "the snapshot cp of data.img failed, or the backup is missing/empty afterward, or the sentinel write itself failed"
  test_record_verdict FAILED
  exit 1
fi

RHIZO_WIPE_DATA=1 RHIZO_RELEASE_SWITCH=1 ../../vm/redeploy.sh --boot-wait 300 --gsi "${GSI_DIR[a15]}" --release a15 > "$(test_scratch_log baseline-redeploy)" 2>&1
rdrc=$?
INIT=$(guest_init_pid 15)
if [[ -z "$INIT" ]]; then
  fail "a15 baseline: init second_stage never started (redeploy rc=$rdrc, see $(test_scratch_log baseline-redeploy))"
  test_collect_boot_evidence "gsi-update-baseline-no-init"
else
  bc=$(getprop_live "$INIT" sys.boot_completed) || bc="<unreadable rc=$?>"
  if [[ "$bc" == "1" ]]; then
    pass "a15 baseline: sys.boot_completed=1"
    if poll_user0_unlocked 120; then
      pass "a15 baseline: user 0 reached RUNNING_UNLOCKED"
    else
      fail "a15 baseline: user 0 never reached RUNNING_UNLOCKED within 120s of sys.boot_completed (last am get-started-user-state 0 answer: '$USER0_STATE')"
    fi
  else
    fail "a15 baseline: sys.boot_completed='$bc'"
    test_collect_boot_evidence "gsi-update-baseline-no-boot"
  fi
fi

missing=""
for f in update/gsi-update.sh prepare/await-boot-completed.py prepare/prepare.sh prepare/fetch-gsi.sh; do
  ssh_vm -t 15 "[ -x /usr/lib/rhizo/install/$f ]" || missing+="$f "
done
[[ -z "$missing" ]] \
  && pass "all four src/install/ scripts are staged at /usr/lib/rhizo/install/" \
  || fail "missing from /usr/lib/rhizo/install/ after redeploy.sh: $missing"

../../vm/boot/adb-tunnel.sh up > "$(test_scratch_log adb-tunnel)" 2>&1 || fail "adb-tunnel.sh up failed"
timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$DESKAPP_APK" /data/local/tmp/rhizo-deskapp.apk \
  > "$(test_scratch_log push-deskapp)" 2>&1 || fail "adb push of rhizo-deskapp.apk failed, built by tools/build/test-apps/deskapp.sh"
inst=$(ANDROID_SH_TIMEOUT=180 android_sh "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/rhizo-deskapp.apk" | tr -d '\r')
grep -qx "Success" <<<"$inst" || fail "pm install of rhizo-deskapp.apk did not print Success: $inst"
pkg_installed leg1-baseline "$INIT" "$DESKAPP_PKG" \
  && pass "installed $DESKAPP_PKG" \
  || fail "$DESKAPP_PKG missing from pm list packages after a reported install"

status_out=$(ssh_vm -t 20 "$UPDATE_SH status" 2>&1)
echo "$status_out" > "$(test_scratch_log baseline-status)"
last=$(marker_line "$status_out" "RHIZO_GSI_UPDATE ")
[[ "$last" == "RHIZO_GSI_UPDATE current=a15 candidate=- tries=- previous=-" ]] \
  && pass "gsi status reads a clean a15 baseline" \
  || fail "gsi status baseline line is '$last', want 'RHIZO_GSI_UPDATE current=a15 candidate=- tries=- previous=-'"

gsi_leg_update leg2 "$UPDATE_SH" a15 a16 3

gsi_leg_manual_rollback leg3 "$UPDATE_SH" a15 a16

gsi_leg_exhaustion leg4 "$UPDATE_SH" a15 a16 "$EXHAUST_TRIES"

step "5. a fetch that fails refuses the update cleanly and leaves state untouched"
ssh_vm -t 90 'systemctl stop androidd.service' > "$(test_scratch_log leg5-stop)" 2>&1

before_status=$(ssh_vm -t 20 "$UPDATE_SH status" 2>&1)
before_last=$(marker_line "$before_status" "RHIZO_GSI_UPDATE ")

ssh_vm -t 20 "printf '%s\n' '#!/bin/bash' \
  'echo \"[fetch-stub] refusing on purpose (gsi-update.sh leg 5)\" >&2' 'exit 1' \
  > /root/rhizo-fetch-stub.sh && chmod 0755 /root/rhizo-fetch-stub.sh"

fail_out=$(ssh_vm -t 60 "RHIZO_FETCH_GSI=/root/rhizo-fetch-stub.sh $UPDATE_SH update --release a16 --tries 3" 2>&1)
echo "$fail_out" > "$(test_scratch_log leg5-update)"
last=$(marker_line "$fail_out" "RHIZO_GSI_UPDATE_FAILED")
[[ "$last" == "RHIZO_GSI_UPDATE_FAILED reason=fetch" ]] \
  && pass "update refused cleanly when the fetch script failed (reason=fetch)" \
  || fail "update with a failing fetch printed '$last', want RHIZO_GSI_UPDATE_FAILED reason=fetch"

after_status=$(ssh_vm -t 20 "$UPDATE_SH status" 2>&1)
after_last=$(marker_line "$after_status" "RHIZO_GSI_UPDATE ")
[[ -n "$before_last" && "$after_last" == "$before_last" ]] \
  && pass "gsi status is unchanged by the failed fetch ($after_last)" \
  || fail "gsi status changed after a failed fetch: before='$before_last' after='$after_last'"

ssh_vm -t 15 'rm -f /root/rhizo-fetch-stub.sh' >/dev/null 2>&1

log "==================================================================="
verdict_params="exhaust_tries=$EXHAUST_TRIES"
(( FAST )) && verdict_params+=" fast=1"
if (( FAILED )); then
  test_record_verdict FAILED "$verdict_params"
  log "GSI-UPDATE SYSTEM TEST FAILED -- evidence in $EV"
  exit 1
fi
test_record_verdict PASSED "$verdict_params"
log "GSI-UPDATE SYSTEM TEST PASSED -- evidence in $EV"
log "src/install/update/gsi-update.sh's whole trial lifecycle -- arm, confirm, manual rollback, try-exhaustion rollback, fetch refusal"
exit 0
