#!/bin/bash
# shellcheck source=/dev/null
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_SRC="$HERE/../system/install/gsi-update.sh"
LIB_SRC="$HERE/../system/lib/gsi-update-cleanup.sh"
RESET_SRC="$HERE/../system/manual/gsi-update-vm-reset.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# print a function from a file
extract_func() {
  local f="$1" name="$2" start end
  start=$(grep -n "^${name}() {" "$f" | tail -1 | cut -d: -f1)
  [[ -n "$start" ]] || return 1
  end=$(awk -v s="$start" 'NR > s && /^}/ { print NR; exit }' "$f")
  [[ -n "$end" ]] || return 1
  sed -n "${start},${end}p" "$f"
}

# print the step zero block of a file
extract_step0() {
  local f="$1" start end
  start=$(grep -n '^step "0\.' "$f" | head -1 | cut -d: -f1)
  end=$(grep -n '^step "1\.' "$f" | head -1 | cut -d: -f1)
  [[ -n "$start" && -n "$end" ]] || return 1
  sed -n "${start},$((end - 1))p" "$f"
}

# print the snapshot and sentinel block
extract_leg1_snapshot() {
  local f="$1" start end
  start=$(grep -n '^data_img=' "$f" | head -1 | cut -d: -f1)
  [[ -n "$start" ]] || return 1
  end=$(awk -v s="$start" 'NR > s && /^RHIZO_WIPE_DATA=1 RHIZO_RELEASE_SWITCH=1 / { print NR - 1; exit }' "$f")
  [[ -n "$end" ]] || return 1
  sed -n "${start},${end}p" "$f"
}

FAILURES=()
fail_check() { FAILURES+=("$1"); }

# record a failure for a bad extraction
assert_extraction_ok() {
  (( $2 == 0 )) || fail_check "$1: extraction failed: an anchor no longer matches"
}

# write a systemctl shim into the guest root
write_systemctl_shim() {
  local root="$1" stop_ok="$2"
  mkdir -p "$root/bin"
  cat > "$root/bin/systemctl" <<EOF
#!/bin/bash
STATE="$root/.androidd-active"
sub="\$1"
case "\$sub" in
  stop)
    if [[ "$stop_ok" == 1 ]]; then rm -f "\$STATE"; exit 0; else exit 1; fi
    ;;
  is-active)
    if [[ -e "\$STATE" ]]; then exit 0; else exit 3; fi
    ;;
esac
exit 0
EOF
  chmod +x "$root/bin/systemctl"
}

# write a failing mv shim
write_mv_fails_shim() {
  mkdir -p "$1/bin"
  printf '#!/bin/bash\nexit 1\n' > "$1/bin/mv"
  chmod +x "$1/bin/mv"
}

# write a failing cp shim
write_cp_fails_shim() {
  mkdir -p "$1/bin"
  printf '#!/bin/bash\nexit 1\n' > "$1/bin/cp"
  chmod +x "$1/bin/cp"
}

GUEST_ITEMS=(update backup-img backup-meta env pending androidd restore-sentinel)
# create a guest root with the named items
make_guest() {
  local root="$1"; shift
  mkdir -p "$root/var/lib/rhizo"
  echo "CURRENT-DATA" > "$root/var/lib/rhizo/data.img"
  printf 'OTHER=keep\n' > "$root/androidd.env"
  write_systemctl_shim "$root" 1
  local item
  for item in "$@"; do
    case "$item" in
      update)           mkdir -p "$root/var/lib/rhizo/update"; echo "good_release=a16" > "$root/var/lib/rhizo/update/state" ;;
      backup-img)       echo "BASELINE-DATA" > "$root/var/lib/rhizo/test-gsi-update-backup.img" ;;
      backup-meta)      echo "BASELINE-META" > "$root/var/lib/rhizo/test-gsi-update-backup.img.meta" ;;
      env)              printf 'RHIZO_GSI=/srv/rhizo/gsi_system_a17\nRHIZO_RELEASE=a17\nOTHER=keep\n' > "$root/androidd.env"
                        printf 'RHIZO_GSI=/srv/rhizo/gsi_system_a17\nRHIZO_DATA_IMG=/var/lib/rhizo/update/trial-data.img\nOTHER=keep\n' > "$root/var/lib/rhizo/androidd-runtime.env" ;;
      pending)          touch "$root/var/lib/rhizo/.rhizo_release_switch_pending" ;;
      androidd)         touch "$root/.androidd-active" ;;
      restore-sentinel) touch "$root/var/lib/rhizo/test-gsi-update-backup.img.taken" ;;
      *) echo "make_guest: unknown item $item" >&2; return 1 ;;
    esac
  done
}

# create a provisioned guest root
make_provisioned_guest() {
  local root="$1"
  mkdir -p "$root/var/lib/rhizo"
  echo "CURRENT-DATA" > "$root/var/lib/rhizo/data.img"
  printf 'RHIZO_GSI=/srv/rhizo/gsi_system\nRHIZO_RELEASE=a16\nOTHER=keep\n' > "$root/androidd.env"
  write_systemctl_shim "$root" 1
  touch "$root/.androidd-active"
}

# run a command against the fixture root
in_fixture() {
  local root="$1" lib="$2"; shift 2
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      script="${script//\/root\/androidd.env/$FIXTURE_ROOT/androidd.env}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    source "$lib"
    "$@"
  )
}

# run the cleanup body and verify
run_body_then_verify() {
  local lib="$1" root="$2"
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      script="${script//\/root\/androidd.env/$FIXTURE_ROOT/androidd.env}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    source "$lib"
    gsi_update_cleanup_body 90 > "$root/body.out" 2>&1
    echo "BODY_RC=$?"
    if gsi_update_cleanup_verify; then
      echo "VERIFY=OK"
    else
      echo "VERIFY=INCOMPLETE"
      echo "MSG=$GSI_UPDATE_CLEANUP_VERIFY_MSG"
    fi
  ) > "$WORK/result" 2>&1
}

# run gsi_update_cleanup_verify and print its result
run_verify_only() {
  local lib="$1" root="$2"
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      script="${script//\/root\/androidd.env/$FIXTURE_ROOT/androidd.env}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    source "$lib"
    if gsi_update_cleanup_verify; then
      echo "VERIFY=OK"
    else
      echo "VERIFY=INCOMPLETE"
      echo "MSG=$GSI_UPDATE_CLEANUP_VERIFY_MSG"
    fi
  ) > "$WORK/vresult" 2>&1
}

# check cleanup restores a dirty guest
check_full_clean_cycle() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" "${GUEST_ITEMS[@]}"
  run_body_then_verify "$lib" "$root"
  grep -q '^VERIFY=OK$' "$WORK/result" \
    || fail_check "a full body+verify cycle on an all-dirty guest did not end VERIFY=OK: $(cat "$WORK/result")"
  [[ ! -e "$root/var/lib/rhizo/update" ]] \
    || fail_check "the update dir is still on disk after a clean body+verify cycle"
  [[ ! -e "$root/.androidd-active" ]] \
    || fail_check "androidd is still 'active' after a clean body+verify cycle"
  [[ "$(cat "$root/var/lib/rhizo/data.img" 2>/dev/null)" == "BASELINE-DATA" ]] \
    || fail_check "data.img does not hold the restored baseline content after a clean cycle: $(cat "$root/var/lib/rhizo/data.img" 2>/dev/null)"
  [[ ! -e "$root/var/lib/rhizo/test-gsi-update-backup.img.taken" ]] \
    || fail_check "the restore-taken sentinel is still on disk after a clean, successful restore"
  grep -qx 'OTHER=keep' "$root/androidd.env" 2>/dev/null \
    || fail_check "androidd.env lost an UNRELATED key (OTHER=keep) during the env strip: $(cat "$root/androidd.env" 2>/dev/null)"
  grep -qx 'OTHER=keep' "$root/var/lib/rhizo/androidd-runtime.env" 2>/dev/null \
    || fail_check "the runtime state file lost an UNRELATED key (OTHER=keep) or was never stripped: $(cat "$root/var/lib/rhizo/androidd-runtime.env" 2>/dev/null)"
  ! grep -Eq '^(RHIZO_GSI|RHIZO_DATA_IMG)=' "$root/var/lib/rhizo/androidd-runtime.env" 2>/dev/null \
    || fail_check "the runtime state file still carries owned keys (RHIZO_GSI, RHIZO_DATA_IMG naming the trial image) after the cleanup: $(cat "$root/var/lib/rhizo/androidd-runtime.env" 2>/dev/null)"
  rm -rf "$root"
}

# check a failed restore reports incomplete
check_mv_fails_leaves_backup_and_reports_incomplete() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" "${GUEST_ITEMS[@]}"
  write_mv_fails_shim "$root"
  run_body_then_verify "$lib" "$root"
  grep -q '^VERIFY=INCOMPLETE$' "$WORK/result" \
    || fail_check "a guest whose restore mv fails still verified CLEANUP_OK: $(cat "$WORK/result")"
  grep -q 'backup-img-present' "$WORK/result" \
    || fail_check "verify did not name backup-img-present when the restore mv failed: $(cat "$WORK/result")"
  [[ -e "$root/var/lib/rhizo/test-gsi-update-backup.img" ]] \
    || fail_check "test-gsi-update-backup.img is gone after a failed restore mv"
  [[ "$(cat "$root/var/lib/rhizo/test-gsi-update-backup.img" 2>/dev/null)" == "BASELINE-DATA" ]] \
    || fail_check "test-gsi-update-backup.img survived but its content changed: $(cat "$root/var/lib/rhizo/test-gsi-update-backup.img" 2>/dev/null)"
  [[ "$(cat "$root/var/lib/rhizo/data.img" 2>/dev/null)" == "CURRENT-DATA" ]] \
    || fail_check "data.img was overwritten even though the restore mv reported failure: $(cat "$root/var/lib/rhizo/data.img" 2>/dev/null)"
  rm -rf "$root"
}

# check a failed androidd stop reports incomplete
check_androidd_stop_fails_reports_incomplete() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" "${GUEST_ITEMS[@]}"
  write_systemctl_shim "$root" 0
  run_body_then_verify "$lib" "$root"
  grep -q '^VERIFY=INCOMPLETE$' "$WORK/result" \
    || fail_check "a guest whose systemctl stop fails still verified CLEANUP_OK: $(cat "$WORK/result")"
  grep -q 'androidd-still-active' "$WORK/result" \
    || fail_check "verify did not name androidd-still-active when the stop failed: $(cat "$WORK/result")"
  rm -rf "$root"
}

# check cleanup ignores a 0-byte backup image
check_empty_backup_is_not_treated_as_present() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" update env pending androidd
  : > "$root/var/lib/rhizo/test-gsi-update-backup.img"
  run_body_then_verify "$lib" "$root"
  grep -q '^VERIFY=OK$' "$WORK/result" \
    || fail_check "a 0-byte backup img (an unchecked snapshot cp's own leftover) was read as a leftover baseline: $(cat "$WORK/result")"
  [[ ! -e "$root/var/lib/rhizo/test-gsi-update-backup.img" ]] \
    || fail_check "the body did not clean up a 0-byte backup img"
  rm -rf "$root"
}

# check verify flags a missing backup with sentinel
check_no_backup_with_sentinel_is_incomplete() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" update env pending androidd restore-sentinel
  run_verify_only "$lib" "$root"
  rm -rf "$root"
  grep -q '^VERIFY=OK$' "$WORK/vresult" \
    && fail_check "verify read CLEANUP_OK on a guest with the restore-taken sentinel present but no backup img at all (the 'no backup' shape): $(cat "$WORK/vresult")"
  grep -q 'restore-not-performed' "$WORK/vresult" \
    || fail_check "verify did not name restore-not-performed on the 'no backup' shape: $(cat "$WORK/vresult")"
}

# check verify flags a leftover backup with sentinel
check_leftover_backup_with_sentinel_is_incomplete() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" update env pending androidd restore-sentinel backup-img backup-meta
  run_verify_only "$lib" "$root"
  rm -rf "$root"
  grep -q '^VERIFY=OK$' "$WORK/vresult" \
    && fail_check "verify read CLEANUP_OK on a guest carrying a lingering backup img with its own sentinel still present (the 'leftover backup' shape): $(cat "$WORK/vresult")"
  grep -q 'restore-not-performed' "$WORK/vresult" \
    || fail_check "verify did not name restore-not-performed on the 'leftover backup' shape: $(cat "$WORK/vresult")"
  grep -q 'backup-img-present' "$WORK/vresult" \
    || fail_check "verify did not name backup-img-present on the 'leftover backup' shape: $(cat "$WORK/vresult")"
}

# check verify fails on an unreachable vm
check_verify_unreachable_is_not_clean() {
  local lib="$1"
  (
    set -uo pipefail
    ssh_vm() { shift 2; PATH="/nonexistent" bash -c "$*"; }
    source "$lib"
    if gsi_update_cleanup_verify; then echo VERIFY=OK; else echo "VERIFY=INCOMPLETE MSG=$GSI_UPDATE_CLEANUP_VERIFY_MSG"; fi
  ) > "$WORK/vu.out" 2>&1
  grep -q '^VERIFY=INCOMPLETE' "$WORK/vu.out" \
    || fail_check "an unreachable vm (ssh_vm itself unable to run) was read as clean: $(cat "$WORK/vu.out")"
  grep -qi 'could not verify' "$WORK/vu.out" \
    || fail_check "an unreachable vm's own INCOMPLETE message does not name 'could not verify': $(cat "$WORK/vu.out")"
}

# run the cleanup body and verify
run_body_with_id() {
  local lib="$1" root="$2" expected="$3"
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    RHIZO_VM=7
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      script="${script//\/root\/androidd.env/$FIXTURE_ROOT/androidd.env}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    source "$lib"
    gsi_update_cleanup_body 90 "$expected" > "$root/body.out" 2>&1
    echo "BODY_RC=$?"
    if gsi_update_cleanup_verify 30 "$expected"; then
      echo "VERIFY=OK"
    else
      echo "VERIFY=INCOMPLETE"
      echo "MSG=$GSI_UPDATE_CLEANUP_VERIFY_MSG"
    fi
    echo "FOREIGN=$GSI_UPDATE_CLEANUP_FOREIGN_MSG"
  ) > "$WORK/result" 2>&1
}

# check cleanup skips another run's backup
check_foreign_run_backup_is_not_restored() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" backup-img backup-meta
  echo "FOREIGN-RUN-99" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  run_body_with_id "$lib" "$root" "CURRENT-RUN-1"
  local data_after; data_after=$(cat "$root/var/lib/rhizo/data.img" 2>/dev/null)
  rm -rf "$root"
  [[ "$data_after" == "CURRENT-DATA" ]] \
    || fail_check "data.img was overwritten by a FOREIGN run's own backup content -- got '$data_after', want the untouched original 'CURRENT-DATA'"
  grep -q '^VERIFY=OK$' "$WORK/result" \
    || fail_check "a backup whose sentinel names a DIFFERENT run ('FOREIGN-RUN-99') was reported as THIS run's own incomplete cleanup: $(cat "$WORK/result")"
  grep -q '^FOREIGN=FOREIGN_BACKUP_LEFT: FOREIGN-RUN-99 ' "$WORK/result" \
    || fail_check "verify did not report a FOREIGN_BACKUP_LEFT line naming the run that owns the leftover ('FOREIGN-RUN-99'): $(cat "$WORK/result")"
  grep -q '^FOREIGN=.*gsi-update-vm-reset\.sh 7$' "$WORK/result" \
    || fail_check "the FOREIGN_BACKUP_LEFT line does not name test/system/manual/gsi-update-vm-reset.sh and the vm to run it on: $(cat "$WORK/result")"
}

# check verify flags this run's unrestored backup
check_own_run_backup_failure_is_incomplete() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" "${GUEST_ITEMS[@]}"
  echo "CURRENT-RUN-1" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  write_mv_fails_shim "$root"
  run_body_with_id "$lib" "$root" "CURRENT-RUN-1"
  rm -rf "$root"
  grep -q '^VERIFY=INCOMPLETE$' "$WORK/result" \
    || fail_check "a backup whose sentinel names THIS run ('CURRENT-RUN-1'), left behind by a failed restore, did not verify CLEANUP_INCOMPLETE under that same id: $(cat "$WORK/result")"
  grep -q 'backup-img-present' "$WORK/result" \
    || fail_check "verify did not name backup-img-present for THIS run's own unrestored backup: $(cat "$WORK/result")"
  grep -q 'restore-not-performed' "$WORK/result" \
    || fail_check "verify did not name restore-not-performed for THIS run's own unrestored backup: $(cat "$WORK/result")"
  grep -q '^FOREIGN=$' "$WORK/result" \
    || fail_check "verify reported a FOREIGN_BACKUP_LEFT line for a backup whose sentinel names THIS run: $(cat "$WORK/result")"
}

# check verify flags a backup with empty sentinel
check_unowned_backup_is_this_runs_problem() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" "${GUEST_ITEMS[@]}"
  write_mv_fails_shim "$root"
  run_body_with_id "$lib" "$root" "CURRENT-RUN-1"
  rm -rf "$root"
  grep -q '^VERIFY=INCOMPLETE$' "$WORK/result" \
    || fail_check "a surviving backup whose sentinel is EMPTY was excused as a foreign run's leftover instead of this run's incomplete cleanup: $(cat "$WORK/result")"
  grep -q '^FOREIGN=$' "$WORK/result" \
    || fail_check "a backup with an empty sentinel was attributed to another run: $(cat "$WORK/result")"
}
# check verify flags a backup missing its sentinel
check_backup_with_no_sentinel_is_this_runs_problem() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" update backup-img backup-meta env pending androidd
  run_body_with_id "$lib" "$root" "CURRENT-RUN-1"
  rm -rf "$root"
  grep -q '^VERIFY=INCOMPLETE$' "$WORK/result" \
    || fail_check "a surviving backup with NO sentinel was excused as a foreign run's leftover instead of this run's incomplete cleanup: $(cat "$WORK/result")"
  grep -q '^FOREIGN=$' "$WORK/result" \
    || fail_check "a backup with no sentinel was attributed to another run: $(cat "$WORK/result")"
}

# check cleanup restores this run's backup
check_same_run_backup_is_restored() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" backup-img backup-meta
  echo "CURRENT-RUN-1" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  run_body_with_id "$lib" "$root" "CURRENT-RUN-1"
  local data_after; data_after=$(cat "$root/var/lib/rhizo/data.img" 2>/dev/null)
  rm -rf "$root"
  grep -q '^VERIFY=OK$' "$WORK/result" \
    || fail_check "a backup whose sentinel names THIS run ('CURRENT-RUN-1') was not restored/verified clean: $(cat "$WORK/result")"
  [[ "$data_after" == "BASELINE-DATA" ]] \
    || fail_check "data.img was not actually restored from a same-run-id backup -- got '$data_after', want 'BASELINE-DATA'"
}

# check the snapshot and sentinel block
check_leg1_snapshot_block() {
  local f="$1" ok block root log rc
  block="$(extract_leg1_snapshot "$f")"; ok=$?
  assert_extraction_ok "leg1-snapshot" "$ok"; (( ok == 0 )) || return

  root=$(mktemp -d); mkdir -p "$root/var/lib/rhizo"
  echo "LEFTOVER-BACKUP-DATA" > "$root/var/lib/rhizo/test-gsi-update-backup.img"
  echo "OLD-RUN-ID" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  log="$WORK/leg1-nobackup.log"; : > "$log"
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    GSI_UPDATE_RUN_ID="TESTRUN-LEG1"
    CALL_LOG="$log"
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    pass() { echo "PASS $*" >> "$CALL_LOG"; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    test_record_verdict() { echo "VERDICT $*" >> "$CALL_LOG"; }
    eval "$block"
    echo BLOCK_END >> "$CALL_LOG"
  ) >> "$log" 2>&1
  rc=$?
  local foreign_sentinel_after; foreign_sentinel_after=$(cat "$root/var/lib/rhizo/test-gsi-update-backup.img.taken" 2>/dev/null)
  rm -rf "$root"
  (( rc != 0 )) \
    || fail_check "leg1 snapshot block: exited 0 on a guest with no data.img and a foreign run's backup -- must be terminal"
  [[ "$foreign_sentinel_after" == "OLD-RUN-ID" ]] \
    || fail_check "leg1 snapshot block stamped over a foreign run's sentinel on a guest with no data.img -- got '$foreign_sentinel_after', want the untouched 'OLD-RUN-ID'"
  grep -q '^VERDICT FAILED$' "$log" \
    || fail_check "leg1 snapshot block did not call test_record_verdict FAILED on a guest with no backup possible: $(cat "$log")"
  grep -q 'BLOCK_END' "$log" \
    && fail_check "leg1 snapshot block fell through past its own end on a guest with no backup possible: $(cat "$log")"

  root=$(mktemp -d); mkdir -p "$root/var/lib/rhizo"; echo "CURRENT-DATA" > "$root/var/lib/rhizo/data.img"
  log="$WORK/leg1-backup.log"; : > "$log"
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    GSI_UPDATE_RUN_ID="TESTRUN-LEG1"
    CALL_LOG="$log"
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    pass() { echo "PASS $*" >> "$CALL_LOG"; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    test_record_verdict() { echo "VERDICT $*" >> "$CALL_LOG"; }
    eval "$block"
    echo BLOCK_END >> "$CALL_LOG"
  ) >> "$log" 2>&1
  local backup_content; backup_content=$(cat "$root/var/lib/rhizo/test-gsi-update-backup.img.taken" 2>/dev/null)
  rm -rf "$root"
  grep -q '^PASS ' "$log" \
    || fail_check "leg1 snapshot block did not pass() on a guest with a real backup: $(cat "$log")"
  grep -q 'BLOCK_END' "$log" \
    || fail_check "leg1 snapshot block did not reach its own end on a guest with a real backup: $(cat "$log")"
  [[ -n "$backup_content" ]] \
    || fail_check "leg1 snapshot block did not write the restore-taken sentinel on a guest with a real backup"
  [[ "$backup_content" == "TESTRUN-LEG1" ]] \
    || fail_check "leg1 snapshot block's own sentinel does not carry this run's own id -- got '$backup_content', want 'TESTRUN-LEG1'"

  root=$(mktemp -d); mkdir -p "$root/var/lib/rhizo"
  echo "CURRENT-DATA" > "$root/var/lib/rhizo/data.img"
  echo "LEFTOVER-BACKUP-DATA" > "$root/var/lib/rhizo/test-gsi-update-backup.img"
  echo "OLD-RUN-ID" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  write_cp_fails_shim "$root"
  log="$WORK/leg1-uncopyable-leftover.log"; : > "$log"
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    GSI_UPDATE_RUN_ID="TESTRUN-LEG1-C"
    CALL_LOG="$log"
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    pass() { echo "PASS $*" >> "$CALL_LOG"; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    test_record_verdict() { echo "VERDICT $*" >> "$CALL_LOG"; }
    eval "$block"
    echo BLOCK_END >> "$CALL_LOG"
  ) >> "$log" 2>&1
  rc=$?
  local leftover_backup_after leftover_sentinel_after
  leftover_backup_after=$(cat "$root/var/lib/rhizo/test-gsi-update-backup.img" 2>/dev/null)
  leftover_sentinel_after=$(cat "$root/var/lib/rhizo/test-gsi-update-backup.img.taken" 2>/dev/null)
  rm -rf "$root"
  (( rc != 0 )) \
    || fail_check "leg1 snapshot block: exited 0 on a guest whose data.img is uncopyable but which carries a LEFTOVER backup from an earlier run -- must be terminal"
  grep -q '^VERDICT FAILED$' "$log" \
    || fail_check "leg1 snapshot block did not call test_record_verdict FAILED on an uncopyable-data.img guest with a leftover backup: $(cat "$log")"
  grep -q 'BLOCK_END' "$log" \
    && fail_check "leg1 snapshot block fell through past its own end on an uncopyable-data.img guest with a leftover backup: $(cat "$log")"
  [[ "$leftover_backup_after" == "LEFTOVER-BACKUP-DATA" ]] \
    || fail_check "the leftover backup's own content changed after a failed snapshot cp -- got '$leftover_backup_after', want the untouched 'LEFTOVER-BACKUP-DATA'"
  [[ "$leftover_sentinel_after" == "OLD-RUN-ID" ]] \
    || fail_check "the leftover sentinel was clobbered by a failed snapshot attempt instead of being left alone -- got '$leftover_sentinel_after', want the untouched 'OLD-RUN-ID'"

  root=$(mktemp -d); mkdir -p "$root/var/lib/rhizo"
  log="$WORK/leg1-absent.log"; : > "$log"
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    GSI_UPDATE_RUN_ID="TESTRUN-LEG1-D"
    CALL_LOG="$log"
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    pass() { echo "PASS $*" >> "$CALL_LOG"; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    test_record_verdict() { echo "VERDICT $*" >> "$CALL_LOG"; }
    eval "$block"
    echo BLOCK_END >> "$CALL_LOG"
  ) >> "$log" 2>&1
  local absent_sentinel absent_marker=0 made_data=0
  absent_sentinel=$(cat "$root/var/lib/rhizo/test-gsi-update-backup.img.taken" 2>/dev/null)
  [[ -e "$root/var/lib/rhizo/test-gsi-update-backup.img.absent" ]] && absent_marker=1
  [[ -e "$root/var/lib/rhizo/data.img" ]] && made_data=1
  rm -rf "$root"
  grep -q '^PASS ' "$log" && grep -q 'BLOCK_END' "$log" && ! grep -q '^FAIL ' "$log" \
    || fail_check "leg1 snapshot block refused a vm whose baseline is no data.img at all: $(cat "$log")"
  (( absent_marker )) \
    || fail_check "leg1 snapshot block did not record the absent baseline (test-gsi-update-backup.img.absent) for the cleanup trap to restore"
  [[ "$absent_sentinel" == "TESTRUN-LEG1-D" ]] \
    || fail_check "leg1 snapshot block's absent-baseline sentinel does not carry this run's own id -- got '$absent_sentinel', want 'TESTRUN-LEG1-D'"
  (( made_data == 0 )) \
    || fail_check "leg1 snapshot block created a data.img on a vm that had none"

  root=$(mktemp -d); mkdir -p "$root/var/lib/rhizo"
  echo "CURRENT-DATA" > "$root/var/lib/rhizo/data.img"
  touch "$root/var/lib/rhizo/test-gsi-update-backup.img.absent"
  echo "OLD-RUN-ID" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  log="$WORK/leg1-present-leftover-absent.log"; : > "$log"
  (
    set -uo pipefail
    FIXTURE_ROOT="$root"
    GSI_UPDATE_RUN_ID="TESTRUN-LEG1-E"
    CALL_LOG="$log"
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    pass() { echo "PASS $*" >> "$CALL_LOG"; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    test_record_verdict() { echo "VERDICT $*" >> "$CALL_LOG"; }
    eval "$block"
    echo BLOCK_END >> "$CALL_LOG"
  ) >> "$log" 2>&1
  rc=$?
  local e_sentinel e_marker=0 e_backup=0
  e_sentinel=$(cat "$root/var/lib/rhizo/test-gsi-update-backup.img.taken" 2>/dev/null)
  [[ -e "$root/var/lib/rhizo/test-gsi-update-backup.img.absent" ]] && e_marker=1
  [[ -e "$root/var/lib/rhizo/test-gsi-update-backup.img" ]] && e_backup=1
  rm -rf "$root"
  (( rc != 0 )) && grep -q '^VERDICT FAILED$' "$log" && ! grep -q 'BLOCK_END' "$log" \
    || fail_check "leg1 snapshot block went on over a dead run's absent marker with data.img present -- must be terminal: $(cat "$log")"
  [[ "$e_sentinel" == "OLD-RUN-ID" ]] && (( e_marker == 1 && e_backup == 0 )) \
    || fail_check "leg1 snapshot block touched a dead run's absent marker or sentinel (sentinel '$e_sentinel', marker=$e_marker, backup=$e_backup)"
}

# check cleanup removes a data.img this run created
check_absent_baseline_restored() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root" update env pending androidd
  echo "TRIAL-META" > "$root/var/lib/rhizo/data.img.meta"
  touch "$root/var/lib/rhizo/test-gsi-update-backup.img.absent"
  echo "CURRENT-RUN-1" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  run_body_with_id "$lib" "$root" "CURRENT-RUN-1"
  local left=""
  for f in data.img data.img.meta test-gsi-update-backup.img.absent test-gsi-update-backup.img.taken; do
    [[ -e "$root/var/lib/rhizo/$f" ]] && left+=" $f"
  done
  rm -rf "$root"
  grep -q '^VERIFY=OK$' "$WORK/result" \
    || fail_check "an absent baseline this run recorded did not restore and verify clean: $(cat "$WORK/result")"
  [[ -z "$left" ]] \
    || fail_check "restoring an absent baseline left${left} on the vm"
}

# check cleanup keeps data.img for a foreign marker
check_foreign_absent_baseline_left() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root"
  touch "$root/var/lib/rhizo/test-gsi-update-backup.img.absent"
  echo "FOREIGN-RUN-99" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  run_body_with_id "$lib" "$root" "CURRENT-RUN-1"
  local data_after; data_after=$(cat "$root/var/lib/rhizo/data.img" 2>/dev/null)
  rm -rf "$root"
  [[ "$data_after" == "CURRENT-DATA" ]] \
    || fail_check "a FOREIGN run's absent marker removed this vm's data.img -- got '$data_after', want 'CURRENT-DATA'"
  grep -q '^VERIFY=OK$' "$WORK/result" && grep -q '^FOREIGN=FOREIGN_BACKUP_LEFT: FOREIGN-RUN-99 ' "$WORK/result" \
    || fail_check "a foreign run's absent marker was not reported as a non-failing FOREIGN_BACKUP_LEFT: $(cat "$WORK/result")"
}

# check verify reports the absent marker
check_absent_marker_is_seen() {
  local lib="$1" root
  root=$(mktemp -d)
  make_guest "$root"
  touch "$root/var/lib/rhizo/test-gsi-update-backup.img.absent"
  run_verify_only "$lib" "$root"
  in_fixture "$root" "$lib" gsi_update_vm_has_residue > /dev/null 2>&1
  local residue_rc=$?
  rm -rf "$root"
  grep -q 'backup-absent-present' "$WORK/vresult" \
    || fail_check "verify did not name backup-absent-present for an absent marker left on the vm: $(cat "$WORK/vresult")"
  (( residue_rc == 0 )) \
    || fail_check "gsi_update_vm_has_residue read a vm carrying only an absent marker as clean"
}

TEST_CLEANUP_RUN_ID="TESTRUN-1"

# run gsi_update_cleanup against a fixture guest
run_test_cleanup() {
  local gf="$1" lf="$2" root="$3" entry_rc="$4" log_file="$5" testtext
  testtext="$(extract_func "$gf" gsi_update_cleanup)" || { echo 127 > "$WORK/fn.rc"; : > "$log_file"; return; }
  : > "$log_file"
  (
    set -uo pipefail
    CALL_LOG="$log_file"
    FIXTURE_ROOT="$root"
    # shellcheck disable=SC2034
    GSI_UPDATE_RUN_ID="$TEST_CLEANUP_RUN_ID"
    EV="$WORK/ev" RHIZO_VM=7
    mkdir -p "$EV"; : > "$EV/failures.log"
    capture_units() { :; }
    test_scratch_log() { echo "$root/scratch-cleanup-body.log"; }
    log() { echo "LOG $*" >> "$CALL_LOG"; }
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      script="${script//\/root\/androidd.env/$FIXTURE_ROOT/androidd.env}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    source "$lf"
    eval "$testtext"
    ( exit "$entry_rc" )
    gsi_update_cleanup
    echo $? > "$WORK/fn.rc"
  ) >/dev/null 2>&1
}

# check gsi_update_cleanup logs results and returns status
check_test_cleanup_ok_and_incomplete_and_rc() {
  local gf="$1" ok root data_after
  extract_func "$gf" gsi_update_cleanup >/dev/null; ok=$?
  assert_extraction_ok "test-cleanup" "$ok"; (( ok == 0 )) || return

  root=$(mktemp -d); make_guest "$root" "${GUEST_ITEMS[@]}"
  echo "$TEST_CLEANUP_RUN_ID" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  run_test_cleanup "$gf" "$LIB_SRC" "$root" 0 "$WORK/ok.log"
  [[ "$(cat "$WORK/fn.rc" 2>/dev/null)" == "0" ]] \
    || fail_check "gsi_update_cleanup returned $(cat "$WORK/fn.rc" 2>/dev/null) for a PASSING system test on a clean-after-cleanup guest, want 0"
  grep -q '^LOG CLEANUP_OK' "$WORK/ok.log" \
    || fail_check "gsi_update_cleanup did not log CLEANUP_OK on a guest that verified clean after cleanup: $(cat "$WORK/ok.log")"
  rm -rf "$root"

  root=$(mktemp -d); make_guest "$root" "${GUEST_ITEMS[@]}"; write_mv_fails_shim "$root"
  echo "$TEST_CLEANUP_RUN_ID" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  run_test_cleanup "$gf" "$LIB_SRC" "$root" 7 "$WORK/bad.log"
  [[ "$(cat "$WORK/fn.rc" 2>/dev/null)" == "7" ]] \
    || fail_check "gsi_update_cleanup returned $(cat "$WORK/fn.rc" 2>/dev/null) for a FAILED system test (entry rc=7) on a guest cleanup could not fully clear, want 7 (the system test's own status, not cleanup's)"
  grep -q 'CLEANUP_INCOMPLETE' "$WORK/bad.log" \
    || fail_check "gsi_update_cleanup did not log CLEANUP_INCOMPLETE on a guest whose restore mv failed: $(cat "$WORK/bad.log")"
  grep -q 'gsi-update-vm-reset\.sh' "$WORK/bad.log" \
    || fail_check "gsi_update_cleanup's own CLEANUP_INCOMPLETE line does not name test/system/manual/gsi-update-vm-reset.sh: $(cat "$WORK/bad.log")"
  [[ -s "$WORK/ev/CLEANUP-INCOMPLETE" ]] \
    || fail_check "gsi_update_cleanup did not write \$EV/CLEANUP-INCOMPLETE for a reader of banked evidence to see"
  rm -rf "$root"

  root=$(mktemp -d); make_guest "$root" "${GUEST_ITEMS[@]}"
  echo "FOREIGN-RUN-99" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  run_test_cleanup "$gf" "$LIB_SRC" "$root" 0 "$WORK/foreign.log"
  data_after=$(cat "$root/var/lib/rhizo/data.img" 2>/dev/null)
  [[ "$data_after" == "CURRENT-DATA" ]] \
    || fail_check "the system test's own gsi_update_cleanup call restored a FOREIGN-run backup over data.img -- got '$data_after', want 'CURRENT-DATA'"
  grep -q 'LOG FOREIGN_BACKUP_LEFT: FOREIGN-RUN-99 ' "$WORK/foreign.log" \
    || fail_check "gsi_update_cleanup did not log a FOREIGN_BACKUP_LEFT line naming the run that owns the leftover, through the system test's own call site: $(cat "$WORK/foreign.log")"
  grep -q 'CLEANUP_INCOMPLETE' "$WORK/foreign.log" \
    && fail_check "gsi_update_cleanup blamed THIS run for a backup its own body is forbidden to remove: $(cat "$WORK/foreign.log")"
  [[ -s "$WORK/ev/FOREIGN-BACKUP-LEFT" ]] \
    || fail_check "gsi_update_cleanup did not write \$EV/FOREIGN-BACKUP-LEFT for a reader of banked evidence to see"
  rm -rf "$root"

  root=$(mktemp -d); make_guest "$root" "${GUEST_ITEMS[@]}"
  echo "$TEST_CLEANUP_RUN_ID" > "$root/var/lib/rhizo/test-gsi-update-backup.img.taken"
  run_test_cleanup "$gf" "$LIB_SRC" "$root" 0 "$WORK/foreign-cleared.log"
  [[ -e "$WORK/ev/FOREIGN-BACKUP-LEFT" ]] \
    && fail_check "a leftover \$EV/FOREIGN-BACKUP-LEFT from an earlier run survived a run that found no foreign leftover at all: $(cat "$WORK/foreign-cleared.log")"
  rm -rf "$root"
}

# check the refusal names gsi-update-vm-reset.sh
check_step0_names_reset_tool() {
  local f="$1" ok block rc log root
  block="$(extract_step0 "$f")"; ok=$?
  assert_extraction_ok "step0" "$ok"; (( ok == 0 )) || return
  root=$(mktemp -d); make_guest "$root" update
  rc="$WORK/step0.rc"; log="$WORK/step0.log"
  : > "$log"
  (
    set -uo pipefail
    CALL_LOG="$log"
    # shellcheck disable=SC2034
    RHIZO_VM=7
    FIXTURE_ROOT="$root"
    test_boot() { echo "TEST_BOOT" >> "$CALL_LOG"; return 0; }
    ssh_vm() {
      shift 2
      local script="$*"
      script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
      PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
    }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    pass() { echo "PASS $*" >> "$CALL_LOG"; }
    test_record_verdict() { echo "VERDICT $*" >> "$CALL_LOG"; }
    eval "$block"
    echo BLOCK_END >> "$CALL_LOG"
  ) >/dev/null 2>&1
  echo $? > "$rc"
  rm -rf "$root"
  grep -q '^TEST_BOOT$' "$log" \
    || fail_check "step 0: test_boot was never called"
  grep -q '^FAIL ' "$log" \
    || fail_check "step 0 did not fail() on a vm with a real, on-disk /var/lib/rhizo/update: $(cat "$log")"
  grep -q 'gsi-update-vm-reset\.sh' "$log" \
    || fail_check "step 0's own refusal does not name test/system/manual/gsi-update-vm-reset.sh: $(cat "$log")"
}

# run the reset script against a fixture
run_reset_tool_whole() {
  local reset="$1" lib="$2" root="$3" out="$4" dir
  dir=$(mktemp -d)
  mkdir -p "$dir/system/manual" "$dir/system/lib" "$dir/vm"
  cp "$reset" "$dir/system/manual/gsi-update-vm-reset.sh"; chmod +x "$dir/system/manual/gsi-update-vm-reset.sh"
  cp "$lib" "$dir/system/lib/gsi-update-cleanup.sh"
  cat > "$dir/vm/common.sh" <<'FAKECOMMON'
ssh_vm() {
  shift 2
  local script="$*"
  script="${script//\/var\/lib\/rhizo/$FIXTURE_ROOT/var/lib/rhizo}"
  script="${script//\/root\/androidd.env/$FIXTURE_ROOT/androidd.env}"
  PATH="$FIXTURE_ROOT/bin:$PATH" bash -c "$script"
}
FAKECOMMON
  FIXTURE_ROOT="$root" bash "$dir/system/manual/gsi-update-vm-reset.sh" 7 --yes > "$out" 2>&1
  local rc=$?
  rm -rf "$dir"
  return $rc
}

# check the reset script end to end
check_reset_tool_whole_script() {
  local reset="$1" lib="$2" root before_stamp after_stamp androidd_after rc

  root=$(mktemp -d); make_guest "$root" "${GUEST_ITEMS[@]}"; write_mv_fails_shim "$root"
  run_reset_tool_whole "$reset" "$lib" "$root" "$WORK/reset-dirty.log"
  rc=$?
  rm -rf "$root"
  [[ "$rc" != "0" ]] \
    || fail_check "whole-script run: exited 0 on a guest whose restore mv failed: $(cat "$WORK/reset-dirty.log")"
  grep -q 'RHIZO_VM_RESET incomplete' "$WORK/reset-dirty.log" \
    || fail_check "whole-script run: did not report RHIZO_VM_RESET incomplete on a guest still dirty after its own cleanup: $(cat "$WORK/reset-dirty.log")"

  root=$(mktemp -d); make_provisioned_guest "$root"
  before_stamp=$(stat -c %Y "$root/var/lib/rhizo/data.img")
  run_reset_tool_whole "$reset" "$lib" "$root" "$WORK/reset-clean.log"
  rc=$?
  [[ -e "$root/.androidd-active" ]] && androidd_after=active || androidd_after=inactive
  after_stamp=$(stat -c %Y "$root/var/lib/rhizo/data.img" 2>/dev/null)
  rm -rf "$root"
  [[ "$rc" == "0" ]] \
    || fail_check "whole-script run: did not exit 0 on a provisioned vm that gsi-update never touched: $(cat "$WORK/reset-clean.log")"
  grep -qi 'nothing to clear' "$WORK/reset-clean.log" \
    || fail_check "whole-script run: did not report a no-op on a provisioned vm that gsi-update never touched: $(cat "$WORK/reset-clean.log")"
  [[ "$androidd_after" == active ]] \
    || fail_check "whole-script run: androidd is no longer active after running on a provisioned vm that gsi-update never touched"
  [[ "$after_stamp" == "$before_stamp" ]] \
    || fail_check "whole-script run: touched data.img on a provisioned vm that gsi-update never touched"
}

ITEM_NAMES=(stop update-dir pending env backup-restore backup-cleanup restore-sentinel)

# print the cleanup body line that carries a step
body_anchor_for() {
  case "$1" in
    stop)             printf '    systemctl stop androidd.service\n' ;;
    update-dir)       printf '    rm -rf /var/lib/rhizo/update\n' ;;
    pending)          printf '    rm -f /var/lib/rhizo/.rhizo_release_switch_pending\n' ;;
    env)              printf '    sed -i -E "/^('"'"'"$GSI_UPDATE_OWNED_ENV_KEYS"'"'"')=/d" /root/androidd.env /var/lib/rhizo/androidd-runtime.env 2>/dev/null\n' ;;
    backup-restore)   printf '        if mv -f /var/lib/rhizo/test-gsi-update-backup.img /var/lib/rhizo/data.img; then\n' ;;
    backup-cleanup)   printf '      rm -f /var/lib/rhizo/test-gsi-update-backup.img /var/lib/rhizo/test-gsi-update-backup.img.meta\n' ;;
    restore-sentinel) printf '          rm -f /var/lib/rhizo/test-gsi-update-backup.img.taken\n' ;;
  esac
}
# print the replacement body line that disables a step
body_mutant_for() {
  case "$1" in
    stop)             printf '    : MUTANT-stop\n' ;;
    update-dir)       printf '    : MUTANT-update-dir\n' ;;
    pending)          printf '    : MUTANT-pending\n' ;;
    env)              printf '    : MUTANT-env\n' ;;
    backup-restore)   printf '        if true; then  # MUTANT-backup-restore, mv never actually runs\n' ;;
    backup-cleanup)   printf '      : MUTANT-backup-cleanup\n' ;;
    restore-sentinel) printf '          : MUTANT-restore-sentinel\n' ;;
  esac
}
# print the verify line that checks a step
verify_anchor_for() {
  case "$1" in
    stop)             printf '    systemctl is-active --quiet androidd.service && echo "androidd-still-active"\n' ;;
    update-dir)       printf '    [ -e /var/lib/rhizo/update ] && echo "update-dir-present"\n' ;;
    pending)          printf '    [ -e /var/lib/rhizo/.rhizo_release_switch_pending ] && echo "release-switch-pending-present"\n' ;;
    env)              printf '    grep -Eq "^('"'"'"$GSI_UPDATE_OWNED_ENV_KEYS"'"'"')=" /root/androidd.env /var/lib/rhizo/androidd-runtime.env 2>/dev/null && echo "owned-env-keys-present"\n' ;;
    backup-restore)   printf '    [ -s /var/lib/rhizo/test-gsi-update-backup.img ] && echo "backup-img-present"\n' ;;
    backup-cleanup)   printf '    [ -f /var/lib/rhizo/test-gsi-update-backup.img.meta ] && echo "backup-meta-present"\n' ;;
    restore-sentinel) printf '    [ -e /var/lib/rhizo/test-gsi-update-backup.img.taken ] && echo "restore-not-performed"\n' ;;
  esac
}
# print the replacement verify line that disables a check
verify_mutant_for() {
  case "$1" in
    stop)             printf '    : MUTANT-verify-stop\n' ;;
    update-dir)       printf '    : MUTANT-verify-update-dir\n' ;;
    pending)          printf '    : MUTANT-verify-pending\n' ;;
    env)              printf '    : MUTANT-verify-env\n' ;;
    backup-restore)   printf '    : MUTANT-verify-backup-img\n' ;;
    backup-cleanup)   printf '    : MUTANT-verify-backup-meta\n' ;;
    restore-sentinel) printf '    : MUTANT-verify-restore-sentinel\n' ;;
  esac
}
# map a verify item to its guest tag
dirty_tag_for() {
  case "$1" in
    stop)             echo androidd ;;
    update-dir)       echo update ;;
    pending)          echo pending ;;
    env)              echo env ;;
    backup-restore)   echo backup-img ;;
    backup-cleanup)   echo backup-meta ;;
    restore-sentinel) echo restore-sentinel ;;
  esac
}

# check verify flags a dirty item
check_verify_item_required() {
  local item="$1" lib="${2:-$LIB_SRC}" root
  root=$(mktemp -d)
  make_guest "$root" "$(dirty_tag_for "$item")"
  in_fixture "$root" "$lib" gsi_update_cleanup_verify > "$WORK/vi.out" 2>&1
  local rc=$?
  rm -rf "$root"
  (( rc != 0 )) \
    || fail_check "verify reported clean on a guest dirty ONLY in '$item'"
}

# check cleanup and verify end with VERIFY=OK
check_cycle_ends_ok() {
  local lib="$1"; shift
  local root
  root=$(mktemp -d)
  make_guest "$root" "$@"
  run_body_then_verify "$lib" "$root"
  grep -q '^VERIFY=OK$' "$WORK/result" \
    || fail_check "a body+verify cycle on a guest dirty in {$*} did not end VERIFY=OK: $(cat "$WORK/result")"
  rm -rf "$root"
}

# list the dirty items for a body check
body_test_items_for() {
  case "$1" in
    backup-cleanup) echo update backup-meta env pending androidd ;;
    *)              echo "${GUEST_ITEMS[@]}" ;;
  esac
}

# run the cleanup checks
run_all_checks() {
  FAILURES=()
  check_full_clean_cycle "$2"
  check_mv_fails_leaves_backup_and_reports_incomplete "$2"
  check_androidd_stop_fails_reports_incomplete "$2"
  check_empty_backup_is_not_treated_as_present "$2"
  check_no_backup_with_sentinel_is_incomplete "$2"
  check_leftover_backup_with_sentinel_is_incomplete "$2"
  check_verify_unreachable_is_not_clean "$2"
  check_foreign_run_backup_is_not_restored "$2"
  check_own_run_backup_failure_is_incomplete "$2"
  check_unowned_backup_is_this_runs_problem "$2"
  check_backup_with_no_sentinel_is_this_runs_problem "$2"
  check_same_run_backup_is_restored "$2"
  check_absent_baseline_restored "$2"
  check_foreign_absent_baseline_left "$2"
  check_absent_marker_is_seen "$2"
  check_leg1_snapshot_block "$1"
  check_test_cleanup_ok_and_incomplete_and_rc "$1"
  check_step0_names_reset_tool "$1"
  check_reset_tool_whole_script "$3" "$2"
  local item
  for item in "${ITEM_NAMES[@]}"; do
    check_verify_item_required "$item"
  done
}

if (( ! SELFTEST )); then
  [[ -r "$TEST_SRC" ]]  || { echo "FAIL: cannot read $TEST_SRC"; exit 1; }
  [[ -r "$LIB_SRC" ]]   || { echo "FAIL: cannot read $LIB_SRC"; exit 1; }
  [[ -r "$RESET_SRC" ]] || { echo "FAIL: cannot read $RESET_SRC"; exit 1; }
  run_all_checks "$TEST_SRC" "$LIB_SRC" "$RESET_SRC"
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}"
    exit 1
  fi
  echo "ok: gsi_update_cleanup_body/_verify checked against a real filesystem fixture for all 7 body steps; unreachable vm, foreign backups, CLEANUP_OK/CLEANUP_INCOMPLETE, \$EV markers, step 0 remedy and the reset tool's precondition checked"
  exit 0
fi

# print a selftest failure and exit 1
selftest_fail() { echo "SELFTEST FAIL: $1"; exit 1; }

copy="$WORK/m1.sh"; cp "$TEST_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '  if gsi_update_cleanup_verify 30 "$GSI_UPDATE_RUN_ID"; then'
new = "  if (( body_rc == 0 )); then  # MUTANT m1: decide on body's own rc\n    GSI_UPDATE_CLEANUP_VERIFY_MSG=unused\n    GSI_UPDATE_CLEANUP_FOREIGN_MSG="
if old not in s: sys.exit("m1 anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "m1 mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "m1 copy is not valid bash"
FAILURES=()
check_mv_fails_leaves_backup_and_reports_incomplete "$LIB_SRC"
check_test_cleanup_ok_and_incomplete_and_rc "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi_update_cleanup that decides on body_rc instead of calling gsi_update_cleanup_verify"
echo "selftest ok (m1, decide on body_rc): detected -- ${FAILURES[0]}"

copy="$WORK/m2.sh"; cp "$LIB_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''  if (( rc != 0 )); then
    GSI_UPDATE_CLEANUP_VERIFY_MSG="could not verify -- ssh_vm itself failed (rc=$rc), the vm may be unreachable"
    return 1
  fi'''
new = '''  if (( rc != 0 )); then
    :
  fi'''
if old not in s: sys.exit("m2 anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "m2 mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "m2 copy is not valid bash"
FAILURES=()
check_verify_unreachable_is_not_clean "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of verify with its rc!=0 (unreachable) branch mutated away"
echo "selftest ok (m2, unreachable vm read as clean): detected -- ${FAILURES[0]}"

copy="$WORK/m3.sh"; cp "$LIB_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
for frag in ['    [ -s /var/lib/rhizo/test-gsi-update-backup.img ] && echo "backup-img-present"\n',
             '    [ -f /var/lib/rhizo/test-gsi-update-backup.img.meta ] && echo "backup-meta-present"\n']:
    if frag not in s: sys.exit("m3 anchor not found: %r" % frag)
    s = s.replace(frag, "")
open(p, "w").write(s)
PY
(( $? == 0 )) || selftest_fail "m3 mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "m3 copy is not valid bash"
root=$(mktemp -d); make_guest "$root" backup-img backup-meta
in_fixture "$root" "$copy" gsi_update_cleanup_verify > "$WORK/m3.out" 2>&1
rc=$?
rm -rf "$root"
FAILURES=()
[[ "$rc" == "0" ]] \
  && fail_check "m3: verify with both backup probes removed reported clean on a guest whose backup img and meta were both left behind"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of verify with its backup-img/backup-meta probes removed"
echo "selftest ok (m3, verify checks a strict subset): detected -- ${FAILURES[0]}"

copy="$WORK/m4.sh"; cp "$LIB_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    rm -rf /var/lib/rhizo/update\n"
new = "    : MUTANT m4\n"
if old not in s: sys.exit("m4 anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "m4 mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "m4 copy is not valid bash"
FAILURES=()
check_full_clean_cycle "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of the body that never removes /var/lib/rhizo/update"
echo "selftest ok (m4, body drops the update-dir removal): detected -- ${FAILURES[0]}"

for item in "${ITEM_NAMES[@]}"; do
  copy="$WORK/verify-mutant-$item.sh"; cp "$LIB_SRC" "$copy"
  anchor="$(verify_anchor_for "$item")"; mutant="$(verify_mutant_for "$item")"
  python3 - "$copy" "$anchor" "$mutant" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if old not in s: sys.exit("anchor not found for %s: %r" % (p, old))
open(p, "w").write(s.replace(old, new, 1))
PY
  (( $? == 0 )) || selftest_fail "verify-mutant-$item mutation script itself failed to apply"
  bash -n "$copy" || selftest_fail "verify-mutant-$item copy is not valid bash"
  FAILURES=()
  check_verify_item_required "$item" "$copy"
  (( ${#FAILURES[@]} > 0 )) \
    || selftest_fail "the checker passed a copy of verify with its '$item' probe removed"
  echo "selftest ok (verify drops the '$item' probe): detected -- ${FAILURES[0]}"
done

for item in "${ITEM_NAMES[@]}"; do
  copy="$WORK/body-mutant-$item.sh"; cp "$LIB_SRC" "$copy"
  anchor="$(body_anchor_for "$item")"; mutant="$(body_mutant_for "$item")"
  python3 - "$copy" "$anchor" "$mutant" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if old not in s: sys.exit("anchor not found for %s: %r" % (p, old))
open(p, "w").write(s.replace(old, new, 1))
PY
  (( $? == 0 )) || selftest_fail "body-mutant-$item mutation script itself failed to apply"
  bash -n "$copy" || selftest_fail "body-mutant-$item copy is not valid bash"
  FAILURES=()
  # shellcheck disable=SC2046
  check_cycle_ends_ok "$copy" $(body_test_items_for "$item")
  (( ${#FAILURES[@]} > 0 )) \
    || selftest_fail "the checker passed a copy of the body that no longer performs its '$item' step"
  echo "selftest ok (body drops the '$item' step): detected -- ${FAILURES[0]}"
done

copy="$WORK/defect-remedy-removed.sh"; cp "$TEST_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '-- test/system/manual/gsi-update-vm-reset.sh $RHIZO_VM clears it by hand"'
new = '"'
if old not in s: sys.exit("remedy text anchor not found")
open(p, "w").write(s.replace(old, new))
PY
(( $? == 0 )) || selftest_fail "remedy-removed mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "remedy-removed copy is not valid bash"
FAILURES=()
check_test_cleanup_ok_and_incomplete_and_rc "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy whose CLEANUP_INCOMPLETE line no longer names test/system/manual/gsi-update-vm-reset.sh"
echo "selftest ok (remedy text removed): detected -- ${FAILURES[0]}"

copy="$WORK/defect-step0-remedy-removed.sh"; cp "$TEST_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "; if it does not report CLEANUP_OK, run test/system/manual/gsi-update-vm-reset.sh $RHIZO_VM by hand before retrying"
new = ""
if old not in s: sys.exit("step0 remedy text anchor not found")
open(p, "w").write(s.replace(old, new))
PY
(( $? == 0 )) || selftest_fail "step0-remedy-removed mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "step0-remedy-removed copy is not valid bash"
FAILURES=()
check_step0_names_reset_tool "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy whose step-0 refusal no longer names test/system/manual/gsi-update-vm-reset.sh"
echo "selftest ok (step0 remedy text removed): detected -- ${FAILURES[0]}"

copy="$WORK/defect-reset-precondition-bypassed.sh"; cp "$RESET_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''if ! gsi_update_vm_has_residue; then
  if [[ "$GSI_UPDATE_RESIDUE_MSG" == could\\ not\\ check* ]]; then
    echo "gsi-update-vm-reset: could not check vm $RHIZO_VM for residue ($GSI_UPDATE_RESIDUE_MSG) -- proceeding with the real cleanup rather than silently claiming clean" >&2
  else
    echo "RHIZO_VM_RESET clean vm=$RHIZO_VM -- nothing to clear on vm $RHIZO_VM ($GSI_UPDATE_RESIDUE_MSG)"
    exit 0
  fi
fi'''
new = 'GSI_UPDATE_RESIDUE_MSG="(precondition removed)"  # MUTANT: always proceeds'
if old not in s: sys.exit("reset-tool precondition anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "reset-precondition-bypassed mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "reset-precondition-bypassed copy is not valid bash"
FAILURES=()
check_reset_tool_whole_script "$copy" "$LIB_SRC"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi-update-vm-reset.sh whose precondition block was removed entirely"
echo "selftest ok (reset tool bypasses its own precondition): detected -- ${FAILURES[0]}"

copy="$WORK/defect-reset-body-before-anchor.sh"; cp "$RESET_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "if ! gsi_update_vm_has_residue; then"
new = "gsi_update_cleanup_body 90 >/dev/null 2>&1  # MUTANT: destructive call above the precondition anchor\nif ! gsi_update_vm_has_residue; then"
if old not in s: sys.exit("reset-tool precondition if-line anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "reset-body-before-anchor mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "reset-body-before-anchor copy is not valid bash"
FAILURES=()
check_reset_tool_whole_script "$copy" "$LIB_SRC"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi-update-vm-reset.sh with a destructive call spliced in above its own precondition check"
echo "selftest ok (destructive call above the precondition anchor): detected -- ${FAILURES[0]}"

copy="$WORK/defect-leg1-reverted.sh"; cp "$TEST_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''if ssh_vm -t 60 "cp -a /var/lib/rhizo/data.img /var/lib/rhizo/test-gsi-update-backup.img && { cp -a /var/lib/rhizo/data.img.meta /var/lib/rhizo/test-gsi-update-backup.img.meta 2>/dev/null || rm -f /var/lib/rhizo/test-gsi-update-backup.img.meta; } && [ -s /var/lib/rhizo/test-gsi-update-backup.img ] && echo '$GSI_UPDATE_RUN_ID' > /var/lib/rhizo/test-gsi-update-backup.img.taken"; then
  pass "pre-test data.img snapshotted to test-gsi-update-backup.img for the cleanup trap to restore (run $GSI_UPDATE_RUN_ID)"
else
  fail "the snapshot cp of data.img failed, or the backup is missing/empty afterward, or the sentinel write itself failed"
  test_record_verdict FAILED
  exit 1
fi'''
new = '''if ssh_vm -t 60 "cp -a /var/lib/rhizo/data.img /var/lib/rhizo/test-gsi-update-backup.img && { cp -a /var/lib/rhizo/data.img.meta /var/lib/rhizo/test-gsi-update-backup.img.meta 2>/dev/null || rm -f /var/lib/rhizo/test-gsi-update-backup.img.meta; } && [ -s /var/lib/rhizo/test-gsi-update-backup.img ] && touch /var/lib/rhizo/test-gsi-update-backup.img.taken"; then
  pass "pre-test data.img snapshotted to test-gsi-update-backup.img for the cleanup trap to restore"
else
  fail "test-gsi-update-backup.img is missing or empty after the snapshot cp -- MUTANT: reverted to a soft fail, no exit"
fi'''
if old not in s: sys.exit("leg1 revert anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "leg1-reverted mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "leg1-reverted copy is not valid bash"
FAILURES=()
check_leg1_snapshot_block "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi-update.sh whose leg-1 snapshot block was reverted to a soft fail with a bare, content-less sentinel touch"
echo "selftest ok (leg1 snapshot block reverted to a soft fail): detected -- ${FAILURES[0]}"

copy="$WORK/defect-leg1-split-fold.sh"; cp "$TEST_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''elif ssh_vm -t 60 "cp -a /var/lib/rhizo/data.img /var/lib/rhizo/test-gsi-update-backup.img && { cp -a /var/lib/rhizo/data.img.meta /var/lib/rhizo/test-gsi-update-backup.img.meta 2>/dev/null || rm -f /var/lib/rhizo/test-gsi-update-backup.img.meta; } && [ -s /var/lib/rhizo/test-gsi-update-backup.img ] && echo '$GSI_UPDATE_RUN_ID' > /var/lib/rhizo/test-gsi-update-backup.img.taken"; then
  pass "pre-test data.img snapshotted to test-gsi-update-backup.img for the cleanup trap to restore (run $GSI_UPDATE_RUN_ID)"
else
  fail "the snapshot cp of data.img failed, or the backup is missing/empty afterward, or the sentinel write itself failed"
  test_record_verdict FAILED
  exit 1
fi'''
new = '''elif ssh_vm -t 60 "cp -a /var/lib/rhizo/data.img /var/lib/rhizo/test-gsi-update-backup.img 2>/dev/null; cp -a /var/lib/rhizo/data.img.meta /var/lib/rhizo/test-gsi-update-backup.img.meta 2>/dev/null; true" >/dev/null 2>&1 \\
    && ssh_vm -t 15 "[ -s /var/lib/rhizo/test-gsi-update-backup.img ] && echo '$GSI_UPDATE_RUN_ID' > /var/lib/rhizo/test-gsi-update-backup.img.taken"; then
  pass "pre-test data.img snapshotted to test-gsi-update-backup.img for the cleanup trap to restore (run $GSI_UPDATE_RUN_ID)"
else
  fail "test-gsi-update-backup.img is missing or empty after the snapshot cp, or the sentinel write itself failed"
  test_record_verdict FAILED
  exit 1
fi'''
if old not in s: sys.exit("leg1 fold anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "leg1-split-fold mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "leg1-split-fold copy is not valid bash"
FAILURES=()
check_leg1_snapshot_block "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi-update.sh whose leg-1 fold (cp + probe + sentinel write) was split back apart"
echo "selftest ok (leg1 fold split back into unchecked cp + separate probe): detected -- ${FAILURES[0]}"

copy="$WORK/defect-no-run-id-test.sh"; cp "$LIB_SRC" "$copy"
run_id_test_anchor="$(printf '      restore_ok=1\n      expected="'"'"'"$expected"'"'"'"\n      if [ -n "$expected" ]; then\n        sentinel=$(cat /var/lib/rhizo/test-gsi-update-backup.img.taken 2>/dev/null)\n        [ "$sentinel" = "$expected" ] || restore_ok=0\n      fi\n      if [ "$restore_ok" = 1 ]; then')"
grep -qF "$run_id_test_anchor" "$copy" || selftest_fail "run-id-test anchor built by printf does not match the real file -- fix the anchor text"
python3 - "$copy" "$run_id_test_anchor" <<'PY'
import sys
p, old = sys.argv[1], sys.argv[2]
s = open(p).read()
new = '      if true; then  # MUTANT: run-id system test removed, always restores'
if old not in s: sys.exit("run-id system test anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "no-run-id-test mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "no-run-id-test copy is not valid bash"
FAILURES=()
check_foreign_run_backup_is_not_restored "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi_update_cleanup_body whose run-id system test was removed"
echo "selftest ok (run-id system test removed from the body): detected -- ${FAILURES[0]}"

copy="$WORK/defect-callsite-no-run-id.sh"; cp "$TEST_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'gsi_update_cleanup_body 90 "$GSI_UPDATE_RUN_ID" > "$out" 2>&1'
new = 'gsi_update_cleanup_body 90 > "$out" 2>&1  # MUTANT: call site dropped its own run id'
if old not in s: sys.exit("call-site run-id anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "callsite-no-run-id mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "callsite-no-run-id copy is not valid bash"
FAILURES=()
check_test_cleanup_ok_and_incomplete_and_rc "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi-update.sh whose gsi_update_cleanup call site dropped its own \$GSI_UPDATE_RUN_ID argument"
echo "selftest ok (call site dropped its own run-id argument): detected -- ${FAILURES[0]}"

copy="$WORK/defect-no-foreign-classification.sh"; cp "$LIB_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''  if (( backup_present || have_sentinel )) && [[ -n "$expected" && -n "$sentinel" && "$sentinel" != "$expected" ]]; then\n'''
new = '''  if false; then  # MUTANT: foreign classification removed, every surviving backup is blamed on this run\n'''
if old not in s: sys.exit("foreign-classification anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "no-foreign-classification mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "no-foreign-classification copy is not valid bash"
FAILURES=()
check_foreign_run_backup_is_not_restored "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi_update_cleanup_verify that reports an EARLIER run's leftover backup as THIS run's own CLEANUP_INCOMPLETE"
echo "selftest ok (verify blames this run for a foreign leftover): detected -- ${FAILURES[0]}"

copy="$WORK/defect-all-backups-foreign.sh"; cp "$LIB_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''  if (( backup_present || have_sentinel )) && [[ -n "$expected" && -n "$sentinel" && "$sentinel" != "$expected" ]]; then\n'''
new = '''  if (( backup_present || have_sentinel )); then  # MUTANT: every surviving backup excused as foreign\n'''
if old not in s: sys.exit("foreign-classification anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "all-backups-foreign mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "all-backups-foreign copy is not valid bash"
FAILURES=()
check_own_run_backup_failure_is_incomplete "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi_update_cleanup_verify that excuses THIS run's own unrestored backup as somebody else's leftover"
echo "selftest ok (verify excuses its own unrestored backup as foreign): detected -- ${FAILURES[0]}"

copy="$WORK/defect-unowned-as-foreign.sh"; cp "$LIB_SRC" "$copy"
python3 - "$copy" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '''  if (( backup_present || have_sentinel )) && [[ -n "$expected" && -n "$sentinel" && "$sentinel" != "$expected" ]]; then\n'''
new = '''  if (( backup_present || have_sentinel )) && [[ -n "$expected" && "$sentinel" != "$expected" ]]; then  # MUTANT: an empty sentinel counts as another run\n'''
if old not in s: sys.exit("foreign-classification anchor not found")
open(p, "w").write(s.replace(old, new, 1))
PY
(( $? == 0 )) || selftest_fail "unowned-as-foreign mutation script itself failed to apply"
bash -n "$copy" || selftest_fail "unowned-as-foreign copy is not valid bash"
FAILURES=()
check_unowned_backup_is_this_runs_problem "$copy"
check_backup_with_no_sentinel_is_this_runs_problem "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy of gsi_update_cleanup_verify that excuses a backup with an EMPTY or ABSENT sentinel as a foreign run's leftover -- CLEANUP_OK over an image nobody owns"
echo "selftest ok (verify excuses an unowned backup as foreign): detected -- ${FAILURES[0]}"

# write a copy with a string replaced
absent_mutant() {
  local copy="$WORK/defect-absent-$1.sh"
  cp "$2" "$copy"
  OLD="$3" NEW="$4" python3 - "$copy" <<'PY'
import os, sys
p = sys.argv[1]; s = open(p).read()
old, new = os.environ["OLD"], os.environ["NEW"]
if old not in s: sys.exit("absent anchor not found: " + old[:80])
open(p, "w").write(s.replace(old, new))
PY
  (( $? == 0 )) || selftest_fail "absent-$1 mutation script itself failed to apply"
  bash -n "$copy" || selftest_fail "absent-$1 copy is not valid bash"
  printf '%s' "$copy"
}
copy=$(absent_mutant body-restore "$LIB_SRC" 'if rm -f /var/lib/rhizo/data.img; then' 'if true; then  # MUTANT') || exit 1
FAILURES=(); check_absent_baseline_restored "$copy"
(( ${#FAILURES[@]} > 0 )) || selftest_fail "the checker passed a body that never removes the data.img an absent baseline says the vm did not have"
echo "selftest ok (absent baseline never restored): detected -- ${FAILURES[0]}"
copy=$(absent_mutant verify-probe "$LIB_SRC" '[ -e /var/lib/rhizo/test-gsi-update-backup.img.absent ] && echo "backup-absent-present"' ': MUTANT') || exit 1
FAILURES=(); check_absent_marker_is_seen "$copy"
(( ${#FAILURES[@]} > 0 )) || selftest_fail "the checker passed a verify and residue probe that never look for an absent marker"
echo "selftest ok (absent marker unprobed): detected -- ${FAILURES[0]}"
copy=$(absent_mutant leg1 "$TEST_SRC" 'if [[ "$data_img" == ABSENT ]]; then' 'if false; then  # MUTANT') || exit 1
FAILURES=(); check_leg1_snapshot_block "$copy"
(( ${#FAILURES[@]} > 0 )) || selftest_fail "the checker passed a leg 1 that refuses a vm with no data.img"
echo "selftest ok (leg 1 refuses an absent baseline): detected -- ${FAILURES[0]}"
copy=$(absent_mutant leg1-foreign "$TEST_SRC" '[ ! -e /var/lib/rhizo/test-gsi-update-backup.img ] && [ ! -e /var/lib/rhizo/test-gsi-update-backup.img.taken ] && [ ! -e /var/lib/rhizo/test-gsi-update-backup.img.absent ] && ' '') || exit 1
FAILURES=(); check_leg1_snapshot_block "$copy"
(( ${#FAILURES[@]} > 0 )) || selftest_fail "the checker passed a leg 1 that records an absent baseline over a foreign run's sentinel"
echo "selftest ok (absent baseline stamped over a foreign sentinel): detected -- ${FAILURES[0]}"

copy=$(absent_mutant leg1-leftover "$TEST_SRC" 'if [[ "$data_img" == LEFTOVER ]]; then' 'if false; then  # MUTANT') || exit 1
FAILURES=(); check_leg1_snapshot_block "$copy"
(( ${#FAILURES[@]} > 0 )) || selftest_fail "the checker passed a leg 1 that snapshots over a dead run's absent marker"
echo "selftest ok (snapshot over a dead run's absent marker): detected -- ${FAILURES[0]}"

run_all_checks "$TEST_SRC" "$LIB_SRC" "$RESET_SRC"
if (( ${#FAILURES[@]} > 0 )); then
  printf 'SELFTEST FAIL (clean): the real fixed files failed their own checker: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "selftest ok (clean): the real fixed gsi-update.sh, gsi-update-cleanup.sh and gsi-update-vm-reset.sh pass every assertion"
exit 0
