#!/bin/bash
# check boot_and_start and its call sites on refusal
# shellcheck disable=SC2034
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FILE="$HERE/../../../system/install/gsi-update.sh"
LIB_FILE="$HERE/../../../system/lib/gsi-update-lib.sh"
[[ -r "$TEST_FILE" ]] || { echo "FAIL: cannot read $TEST_FILE"; exit 1; }
[[ -r "$LIB_FILE" ]] || { echo "FAIL: cannot read $LIB_FILE"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SRC="$WORK/combined-test-gsi-update.sh"
cat "$TEST_FILE" "$LIB_FILE" > "$SRC"

# print a named function's last definition
extract_func() {
  local f="$1" name="$2" start end
  start=$(grep -n "^${name}() {" "$f" | tail -1 | cut -d: -f1)
  [[ -n "$start" ]] || return 1
  end=$(awk -v s="$start" 'NR > s && /^}/ { print NR; exit }' "$f")
  [[ -n "$end" ]] || return 1
  sed -n "${start},${end}p" "$f"
}

# print a call site's block
extract_block() {
  local f="$1" pattern="$2"
  shift 2
  python3 - "$f" "$pattern" "$@" <<'PY'
import re, sys
path, pattern = sys.argv[1], sys.argv[2]
stop_patterns = sys.argv[3:]
lines = open(path).read().splitlines()
rx = re.compile(pattern)
start = next((i for i, l in enumerate(lines) if rx.search(l)), None)
if start is None:
    sys.exit(1)
open_kw = re.compile(r'^(if|for|while|until|case)\b')
close_kw = re.compile(r'^(fi|done|esac)$')
depth = 0
seen_open = False
end = None
for i in range(start, len(lines)):
    stripped = lines[i].strip()
    if open_kw.match(stripped):
        depth += 1
        seen_open = True
    elif close_kw.match(stripped):
        depth -= 1
    if seen_open and depth == 0:
        end = i
        break
if end is None:
    sys.exit(1)
step_rx = re.compile(r'^step\b')
stop_rxs = [re.compile(p) for p in stop_patterns]
for j in range(end + 1, len(lines)):
    line = lines[j]
    stripped = line.strip()
    if step_rx.match(stripped):
        end = j - 1
        break
    if any(r.search(line) for r in stop_rxs):
        end = j - 1
        break
else:
    end = len(lines) - 1
print("\n".join(lines[start:end + 1]))
PY
}

FAILURES=()
fail_check() { FAILURES+=("$1"); }

# run the extracted boot_and_start against logging stubs
run_boot_and_start() {
  local f="$1" preceding="$2" rc_file="$3" log_file="$4" kill_vm_rc="${5:-0}" wait_for_ssh_rc="${6:-0}" body mline
  mline="$(extract_func "$f" marker_line)" || { echo 127 > "$rc_file"; : > "$log_file"; return; }
  body="$(extract_func "$f" boot_and_start)" || { echo 127 > "$rc_file"; : > "$log_file"; return; }
  : > "$log_file"
  (
    set -uo pipefail
    CALL_LOG="$log_file"
    RHIZO_BOOT_REFUSAL=""
    ssh_vm() { echo "SSH_VM $*" >> "$CALL_LOG"; }
    kill_vm() { echo "KILL_VM" >> "$CALL_LOG"; return "$kill_vm_rc"; }
    boot_vm() { echo "BOOT_VM" >> "$CALL_LOG"; }
    wait_for_boot_slot() { return 0; }
    wait_for_ssh() { echo "WAIT_FOR_SSH" >> "$CALL_LOG"; return "$wait_for_ssh_rc"; }
    wait_for_guest_ready() { echo "WAIT_FOR_GUEST_READY" >> "$CALL_LOG"; }
    stage_release() { echo "STAGE_RELEASE $*" >> "$CALL_LOG"; }
    log() { :; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    test_scratch_log() { echo "$WORK/scratch-$RANDOM.log"; }
    eval "$mline"
    eval "$body"
    boot_and_start leg3-rollback a16 "$preceding"
    bc_rc=$?
    echo "REFUSED_BY=$BOOT_REFUSED_BY" >> "$CALL_LOG"
    exit "$bc_rc"
  ) >/dev/null 2>&1
  echo $? > "$rc_file"
}

REFUSED_TEXT=$'[rhizo-gsi-update] REFUSED: a trial of a17 is armed -- run abort first, or let it spend its tries\nRHIZO_GSI_UPDATE_REFUSED reason=trial-in-flight'
FAILED_TEXT=$'[rhizo-gsi-update] FAILED: could not stage the a17 image\nRHIZO_GSI_UPDATE_FAILED reason=fetch'
SUCCESS_TEXT=$'[rhizo-gsi-update] rolled back to a16 with the /data it last wrote\nRHIZO_GSI_UPDATE current=a16 candidate=- tries=- previous=-'

CALLSITE_ANCHORS=(
  'boot_and_start "\$\{label_prefix\}-trial" "\$to_rel"'
  'boot_and_start "\$\{label_prefix\}-rollback" "\$from_rel"'
  'for try in \$\(seq 1 "\$tries"\); do'
  'boot_and_start "\$\{label_prefix\}-final" "\$from_rel"'
)

FIXTURE_ADB=adb-fixture
FIXTURE_INIT=1
FIXTURE_UPDATE_SH=u
FIXTURE_DESKAPP_PKG=com.rhizo.deskapp

declare -A FIXTURE_GSI_DIR=([a16]=x [a17]=y)

# check a REFUSED sentinel stops boot_and_start
check_refusal_blocks_reboot() {
  local f="$1" rc log
  rc="$WORK/refused.rc"; log="$WORK/refused.log"
  run_boot_and_start "$f" "$REFUSED_TEXT" "$rc" "$log"
  [[ "$(cat "$rc")" != "0" ]] || fail_check "boot_and_start returned success after a RHIZO_GSI_UPDATE_REFUSED sentinel"
  grep -q '^KILL_VM$' "$log" && fail_check "boot_and_start called kill_vm after a refusal sentinel: $(cat "$log")"
  grep -q '^BOOT_VM$' "$log" && fail_check "boot_and_start called boot_vm after a refusal sentinel: $(cat "$log")"
  grep -q '^FAIL .*trial-in-flight' "$log" || fail_check "boot_and_start did not report the refusal's own reason: $(cat "$log")"
  grep -qx 'REFUSED_BY=product' "$log" \
    || fail_check "boot_and_start did not set BOOT_REFUSED_BY=product on a sentinel refusal: $(cat "$log")"
}

# check a FAILED sentinel stops boot_and_start
check_failed_blocks_reboot() {
  local f="$1" rc log
  rc="$WORK/failed.rc"; log="$WORK/failed.log"
  run_boot_and_start "$f" "$FAILED_TEXT" "$rc" "$log"
  [[ "$(cat "$rc")" != "0" ]] || fail_check "boot_and_start returned success after a RHIZO_GSI_UPDATE_FAILED sentinel"
  grep -q '^KILL_VM$' "$log" && fail_check "boot_and_start called kill_vm after a failed sentinel: $(cat "$log")"
  grep -qx 'REFUSED_BY=product' "$log" \
    || fail_check "boot_and_start did not set BOOT_REFUSED_BY=product on a failed-fetch sentinel: $(cat "$log")"
}

# check a success line reboots the guest
check_success_still_boots() {
  local f="$1" rc log
  rc="$WORK/success.rc"; log="$WORK/success.log"
  run_boot_and_start "$f" "$SUCCESS_TEXT" "$rc" "$log"
  [[ "$(cat "$rc")" == "0" ]] || fail_check "boot_and_start refused a real success line: $(cat "$log")"
  grep -q '^KILL_VM$' "$log" || fail_check "boot_and_start never called kill_vm on a real success line: $(cat "$log")"
  grep -q '^BOOT_VM$' "$log" || fail_check "boot_and_start never called boot_vm on a real success line: $(cat "$log")"
  local sline kline
  sline=$(grep -n 'systemctl stop androidd.service' "$log" | head -1 | cut -d: -f1)
  kline=$(grep -n '^KILL_VM$' "$log" | head -1 | cut -d: -f1)
  [[ -n "$sline" ]] || fail_check "boot_and_start never asked the guest to stop androidd.service before a reboot: $(cat "$log")"
  [[ -n "$sline" && -n "$kline" ]] && (( sline > kline )) \
    && fail_check "boot_and_start stopped androidd.service AFTER kill_vm, too late to flush a live boot's /data: $(cat "$log")"
}

# check boot_and_start reboots when given no preceding output
check_empty_preceding_still_boots() {
  local f="$1" rc log
  rc="$WORK/empty.rc"; log="$WORK/empty.log"
  run_boot_and_start "$f" "" "$rc" "$log"
  [[ "$(cat "$rc")" == "0" ]] || fail_check "boot_and_start refused a call with no preceding command output: $(cat "$log")"
  grep -q '^KILL_VM$' "$log" || fail_check "boot_and_start never booted when given no preceding output: $(cat "$log")"
}

# check boot_and_start stops on a kill_vm failure
check_kill_vm_failure_stops_boot() {
  local f="$1" rc log
  rc="$WORK/killvm.rc"; log="$WORK/killvm.log"
  run_boot_and_start "$f" "$SUCCESS_TEXT" "$rc" "$log" 1
  [[ "$(cat "$rc")" != "0" ]] \
    || fail_check "boot_and_start returned success even though kill_vm could not confirm the old guest was torn down: $(cat "$log")"
  grep -q '^BOOT_VM$' "$log" \
    && fail_check "boot_and_start booted a new guest without confirming kill_vm tore down the old one first: $(cat "$log")"
  grep -q '^FAIL .*kill_vm' "$log" \
    || fail_check "boot_and_start did not report the kill_vm failure: $(cat "$log")"
  grep -qx 'REFUSED_BY=vm' "$log" \
    || fail_check "boot_and_start did not set BOOT_REFUSED_BY=vm when kill_vm could not confirm teardown: $(cat "$log")"
}

# check an ssh timeout after the reboot sets BOOT_REFUSED_BY=vm
check_wait_for_ssh_failure_is_vm() {
  local f="$1" rc log
  rc="$WORK/waitssh.rc"; log="$WORK/waitssh.log"
  run_boot_and_start "$f" "$SUCCESS_TEXT" "$rc" "$log" 0 1
  [[ "$(cat "$rc")" != "0" ]] \
    || fail_check "boot_and_start returned success even though wait_for_ssh never came up after the reboot"
  grep -q '^FAIL .*ssh never came up' "$log" \
    || fail_check "boot_and_start did not report the ssh-never-came-up refusal: $(cat "$log")"
  grep -qx 'REFUSED_BY=vm' "$log" \
    || fail_check "boot_and_start did not set BOOT_REFUSED_BY=vm when ssh never came up after the reboot: $(cat "$log")"
}

# run an extracted call site against logging stubs
run_callsite() {
  local f="$1" pattern="$2" preassign="$3" mode="$4" rc_file="$5" log_file="$6" mline bstart block
  mline="$(extract_func "$f" marker_line)" || { echo 127 > "$rc_file"; : > "$log_file"; return; }
  bstart="$(extract_func "$f" boot_and_start)" || { echo 127 > "$rc_file"; : > "$log_file"; return; }
  block="$(extract_block "$f" "$pattern" "${CALLSITE_ANCHORS[@]}")" || { echo 126 > "$rc_file"; : > "$log_file"; return; }
  : > "$log_file"
  (
    set -uo pipefail
    CALL_LOG="$log_file"
    BOOT_REFUSED_BY=""
    RHIZO_BOOT_REFUSAL=""
    # shellcheck disable=SC2034
    EXHAUST_TRIES=1
    # shellcheck disable=SC2034
    label_prefix=fixture-leg to_rel=a17 from_rel=a16 tries=1 stage_fn=stage_release
    # shellcheck disable=SC2034
    ADB="$FIXTURE_ADB" INIT="$FIXTURE_INIT" UPDATE_SH="$FIXTURE_UPDATE_SH" DESKAPP_PKG="$FIXTURE_DESKAPP_PKG"
    # shellcheck disable=SC2034
    DMESG_READ="" USER0_STATE=""
    # shellcheck disable=SC2034
    declare -A GSI_DIR=([a16]="${FIXTURE_GSI_DIR[a16]}" [a17]="${FIXTURE_GSI_DIR[a17]}")
    command_not_found_handle() { echo "UNKNOWN_CMD $*" >> "$CALL_LOG"; return 127; }
    ssh_vm() { echo "SSH_VM $*" >> "$CALL_LOG"; }
    kill_vm() { echo "KILL_VM" >> "$CALL_LOG"; }
    boot_vm() { echo "BOOT_VM" >> "$CALL_LOG"; }
    wait_for_boot_slot() { return 0; }
    if [[ "$mode" == success ]]; then
      wait_for_ssh() { echo "WAIT_FOR_SSH" >> "$CALL_LOG"; return 0; }
      # shellcheck disable=SC2034
      poll_boot_completed() { echo "POLL_BOOT_COMPLETED $*" >> "$CALL_LOG"; BC=1; return 0; }
    elif [[ "$mode" == refused ]]; then
      wait_for_ssh() { echo "WAIT_FOR_SSH" >> "$CALL_LOG"; RHIZO_BOOT_REFUSAL="refusing to boot vm 3 at the boot guard"; return 1; }
      # shellcheck disable=SC2034
      poll_boot_completed() { echo "POLL_BOOT_COMPLETED $*" >> "$CALL_LOG"; BC=""; return 1; }
    else
      wait_for_ssh() { echo "WAIT_FOR_SSH" >> "$CALL_LOG"; return 1; }
      # shellcheck disable=SC2034
      poll_boot_completed() { echo "POLL_BOOT_COMPLETED $*" >> "$CALL_LOG"; BC=""; return 1; }
    fi
    wait_for_guest_ready() { echo "WAIT_FOR_GUEST_READY" >> "$CALL_LOG"; return 0; }
    stage_release() { echo "STAGE_RELEASE $*" >> "$CALL_LOG"; }
    log() { :; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    pass() { echo "PASS $*" >> "$CALL_LOG"; }
    capture_units() { echo "CAPTURE_UNITS $*" >> "$CALL_LOG"; }
    boot_dmesg_has() { echo "BOOT_DMESG_HAS $*" >> "$CALL_LOG"; return 1; }
    test_collect_boot_evidence() { echo "TEST_COLLECT_BOOT_EVIDENCE $*" >> "$CALL_LOG"; }
    test_scratch_log() { echo "$WORK/scratch-$RANDOM.log"; }
    eval "$mline"
    eval "$bstart"
    eval "$preassign"
    eval "$block"
    echo "TEST_BOOT_NO_ROW=[${TEST_BOOT_NO_ROW:-}]" >> "$CALL_LOG"
    echo "TEST_BOOTED=[${TEST_BOOTED:-}]" >> "$CALL_LOG"
    echo BLOCK_END >> "$CALL_LOG"
  ) >/dev/null 2>&1
  echo $? > "$rc_file"
}

# fail when an extraction exited 126 or 127
assert_extraction_ok() {
  local name="$1" rc; rc="$(cat "$2" 2>/dev/null)"
  [[ "$rc" != "126" && "$rc" != "127" ]] \
    || fail_check "$name: extraction failed (rc=$rc): a block_pattern or function anchor no longer matches"
}

# fail when the log shows a boot-completed poll
assert_no_poll_after_refusal() {
  grep -q '^POLL_BOOT_COMPLETED' "$2" \
    && fail_check "$1: polled for boot completion after boot_and_start itself had already failed: $(cat "$2")"
}

# fail when the log shows an unstubbed command
assert_no_unknown_command() {
  grep -q '^UNKNOWN_CMD' "$2" \
    && fail_check "$1: called something this checker does not stub once boot_and_start itself had already failed, possibly a poll or an ssh_vm hidden behind another name: $(cat "$2")"
}

# fail when the log lacks BLOCK_END
assert_block_end() {
  grep -qx 'BLOCK_END' "$2" \
    || fail_check "$1: the eval'd block never reached BLOCK_END: $(cat "$2")"
}

# fail when ssh_vm runs after the anchor line
assert_no_ssh_after() {
  local name="$1" log="$2" anchor="$3" aline line ok a
  shift 3
  aline=$(grep -n -E "$anchor" "$log" | head -1 | cut -d: -f1)
  [[ -n "$aline" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ok=0
    for a in "$@"; do
      [[ "$line" == "$a" ]] && { ok=1; break; }
    done
    (( ok )) \
      || fail_check "$name: something drove the guest through ssh_vm after '$anchor', and it is not one of this leg's own known calls: '$line' -- full log: $(cat "$log")"
  done < <(awk -v w="$aline" 'NR > w && /^SSH_VM /' "$log")
}

# fail when ssh_vm runs after the failed WAIT_FOR_SSH line
assert_no_ssh_after_wait_for_ssh() {
  local name="$1" log="$2"
  shift 2
  assert_no_ssh_after "$name" "$log" '^WAIT_FOR_SSH$' "$@"
}

# fail on unwanted TEST_BOOT_NO_ROW or TEST_BOOTED values
assert_boot_state() {
  local name="$1" log="$2" want_no_row="$3" want_booted="$4" got_no_row got_booted
  got_no_row=$(grep -o '^TEST_BOOT_NO_ROW=\[.*\]$' "$log" | tail -1)
  got_booted=$(grep -o '^TEST_BOOTED=\[.*\]$' "$log" | tail -1)
  if [[ "$want_no_row" == 1 ]]; then
    [[ "$got_no_row" == "TEST_BOOT_NO_ROW=[1]" ]] \
      || fail_check "$name: TEST_BOOT_NO_ROW was not left set to 1 ($got_no_row): $(cat "$log")"
  else
    [[ "$got_no_row" == "TEST_BOOT_NO_ROW=[]" ]] \
      || fail_check "$name: TEST_BOOT_NO_ROW was set ($got_no_row) on a leg that never refused before a boot in this process: $(cat "$log")"
  fi
  if [[ "$want_booted" == 1 ]]; then
    [[ "$got_booted" == "TEST_BOOTED=[1]" ]] \
      || fail_check "$name: TEST_BOOTED was not set to 1 ($got_booted) after this leg's own boot came back up: $(cat "$log")"
  else
    [[ "$got_booted" == "TEST_BOOTED=[]" ]] \
      || fail_check "$name: TEST_BOOTED was set ($got_booted) on a leg that never got the guest back: $(cat "$log")"
  fi
}

# assert a vm refusal
assert_vm_refusal() {
  local name="$1" log="$2" rc_file="$3"
  shift 3
  assert_extraction_ok "$name" "$rc_file"
  assert_block_end "$name" "$log"
  assert_no_poll_after_refusal "$name" "$log"
  assert_no_unknown_command "$name" "$log"
  assert_no_ssh_after_wait_for_ssh "$name" "$log" "$@"
  grep -q '^FAIL .*ssh never came up' "$log" \
    || fail_check "$name: no fail line naming the ssh-never-came-up refusal: $(cat "$log")"
  grep -q "^FAIL .*not run -- boot_and_start failed" "$log" \
    || fail_check "$name: no fail line naming the skipped leg: $(cat "$log")"
  grep -qx 'TEST_COLLECT_BOOT_EVIDENCE test-vm-never-came-up' "$log" \
    || fail_check "$name: boot evidence not collected under 'test-vm-never-came-up': $(cat "$log")"
  assert_boot_state "$name" "$log" 0 0
}

# assert a run-vm.sh refusal
assert_refused() {
  local name="$1" log="$2" rc_file="$3"
  shift 3
  assert_extraction_ok "$name" "$rc_file"
  assert_block_end "$name" "$log"
  assert_no_poll_after_refusal "$name" "$log"
  assert_no_unknown_command "$name" "$log"
  assert_no_ssh_after_wait_for_ssh "$name" "$log" "$@"
  grep -q '^FAIL .*refused before any guest launched' "$log" \
    || fail_check "$name: no fail line naming the refusal: $(cat "$log")"
  grep -q "^FAIL .*not run -- boot_and_start failed" "$log" \
    || fail_check "$name: no fail line naming the skipped leg: $(cat "$log")"
  grep -qx 'TEST_COLLECT_BOOT_EVIDENCE test-vm-refused' "$log" \
    || fail_check "$name: boot evidence not collected under 'test-vm-refused': $(cat "$log")"
  grep -qx 'TEST_COLLECT_BOOT_EVIDENCE test-vm-never-came-up' "$log" \
    && fail_check "$name: ALSO collected under the old 'test-vm-never-came-up' label: $(cat "$log")"
  assert_boot_state "$name" "$log" 1 0
}

# assert a sentinel refusal
assert_sentinel_refusal() {
  local name="$1" log="$2" rc_file="$3"
  shift 3
  assert_extraction_ok "$name" "$rc_file"
  assert_block_end "$name" "$log"
  assert_no_poll_after_refusal "$name" "$log"
  assert_no_unknown_command "$name" "$log"
  assert_no_ssh_after "$name" "$log" '^FAIL .*refusing to reboot' "$@"
  grep -q '^FAIL .*refusing to reboot' "$log" \
    || fail_check "$name: no fail line naming the sentinel refusal: $(cat "$log")"
  grep -q "^FAIL .*not run -- boot_and_start failed" "$log" \
    || fail_check "$name: no fail line naming the skipped leg: $(cat "$log")"
  grep -q '^TEST_COLLECT_BOOT_EVIDENCE' "$log" \
    && fail_check "$name: the product's own refusal was filed as boot evidence: $(cat "$log")"
  assert_boot_state "$name" "$log" 0 0
}

# assert a real boot polls and stages the release once
assert_success_path() {
  local name="$1" log="$2" rc_file="$3" expected="$4"
  assert_extraction_ok "$name" "$rc_file"
  assert_block_end "$name" "$log"
  grep -q '^POLL_BOOT_COMPLETED' "$log" \
    || fail_check "$name: a real boot never polled for sys.boot_completed: $(cat "$log")"
  grep -q '^TEST_COLLECT_BOOT_EVIDENCE' "$log" \
    && fail_check "$name: a real boot filed vm-fault boot evidence anyway: $(cat "$log")"
  local stage_count stage_line rel
  stage_count=$(grep -c '^STAGE_RELEASE ' "$log")
  if (( stage_count != 1 )); then
    fail_check "$name: this leg's own call site invoked stage_release $stage_count times, want exactly 1: $(cat "$log")"
  else
    stage_line=$(grep '^STAGE_RELEASE ' "$log")
    rel="${stage_line#STAGE_RELEASE }"
    [[ "$rel" == "$expected" ]] \
      || fail_check "$name: this leg's own call site passed boot_and_start release=$rel, want $expected: $stage_line"
  fi
  assert_boot_state "$name" "$log" 0 1
}

# check leg 2's call site under each refusal
check_leg2_skips_poll_on_boot_refusal() {
  local f="$1" rc log
  rc="$WORK/leg2-vm.rc"; log="$WORK/leg2-vm.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-trial" "\$to_rel"' 'update_out=$SUCCESS_TEXT' vm "$rc" "$log"
  assert_vm_refusal "leg 2 (a17 trial), vm refusal" "$log" "$rc" "SSH_VM -t 20 $FIXTURE_UPDATE_SH status"

  rc="$WORK/leg2-refused.rc"; log="$WORK/leg2-refused.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-trial" "\$to_rel"' 'update_out=$SUCCESS_TEXT' refused "$rc" "$log"
  assert_refused "leg 2 (a17 trial), run-vm.sh refusal" "$log" "$rc" "SSH_VM -t 20 $FIXTURE_UPDATE_SH status"

  rc="$WORK/leg2-sentinel.rc"; log="$WORK/leg2-sentinel.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-trial" "\$to_rel"' 'update_out=$REFUSED_TEXT' sentinel "$rc" "$log"
  assert_sentinel_refusal "leg 2 (a17 trial), sentinel refusal" "$log" "$rc" "SSH_VM -t 20 $FIXTURE_UPDATE_SH status"

  check_leg2_callsite_release "$f"
}

# check leg 2's call site stages a17 on a real boot
check_leg2_callsite_release() {
  local f="$1" rc="$WORK/leg2-success.rc" log="$WORK/leg2-success.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-trial" "\$to_rel"' 'update_out=$SUCCESS_TEXT' success "$rc" "$log"
  assert_success_path "leg 2 (a17 trial), real boot" "$log" "$rc" a17
}

# check leg 3's call site under each refusal
check_leg3_skips_poll_on_boot_refusal() {
  local f="$1" rc log
  rc="$WORK/leg3-vm.rc"; log="$WORK/leg3-vm.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-rollback" "\$from_rel"' 'rollback_out=$SUCCESS_TEXT' vm "$rc" "$log"
  assert_vm_refusal "leg 3 (manual rollback), vm refusal" "$log" "$rc"

  rc="$WORK/leg3-refused.rc"; log="$WORK/leg3-refused.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-rollback" "\$from_rel"' 'rollback_out=$SUCCESS_TEXT' refused "$rc" "$log"
  assert_refused "leg 3 (manual rollback), run-vm.sh refusal" "$log" "$rc"

  rc="$WORK/leg3-sentinel.rc"; log="$WORK/leg3-sentinel.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-rollback" "\$from_rel"' 'rollback_out=$REFUSED_TEXT' sentinel "$rc" "$log"
  assert_sentinel_refusal "leg 3 (manual rollback), sentinel refusal" "$log" "$rc"

  check_leg3_callsite_release "$f"
}

# check leg 3's call site stages a16 on a real boot
check_leg3_callsite_release() {
  local f="$1" rc="$WORK/leg3-success.rc" log="$WORK/leg3-success.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-rollback" "\$from_rel"' 'rollback_out=$SUCCESS_TEXT' success "$rc" "$log"
  assert_success_path "leg 3 (manual rollback), real boot" "$log" "$rc" a16
}

# check leg 4's per-try loop under each refusal
check_leg4_try_skips_poll_on_boot_refusal() {
  local f="$1" rc log
  rc="$WORK/leg4try-vm.rc"; log="$WORK/leg4try-vm.log"
  run_callsite "$f" 'for try in \$\(seq 1 "\$tries"\); do' '' vm "$rc" "$log"
  assert_vm_refusal "leg 4 (per-try loop), vm refusal" "$log" "$rc" \
    "SSH_VM -t 90 systemctl stop androidd.service" \
    "SSH_VM -t 20 $FIXTURE_UPDATE_SH status" \
    "SSH_VM -t 20 sed -i '/^RHIZO_FAULT_NO_READY=/d' /root/androidd.env"

  rc="$WORK/leg4try-refused.rc"; log="$WORK/leg4try-refused.log"
  run_callsite "$f" 'for try in \$\(seq 1 "\$tries"\); do' '' refused "$rc" "$log"
  assert_refused "leg 4 (per-try loop), run-vm.sh refusal" "$log" "$rc" \
    "SSH_VM -t 90 systemctl stop androidd.service" \
    "SSH_VM -t 20 $FIXTURE_UPDATE_SH status" \
    "SSH_VM -t 20 sed -i '/^RHIZO_FAULT_NO_READY=/d' /root/androidd.env"

  check_leg4_try_callsite_release "$f"
}

# check leg 4's per-try call site stages a17 on a real boot
check_leg4_try_callsite_release() {
  local f="$1" rc="$WORK/leg4try-success.rc" log="$WORK/leg4try-success.log"
  run_callsite "$f" 'for try in \$\(seq 1 "\$tries"\); do' '' success "$rc" "$log"
  assert_success_path "leg 4 (per-try loop), real boot" "$log" "$rc" a17
}

# check leg 4-final's call site under each refusal
check_leg4_final_skips_poll_on_boot_refusal() {
  local f="$1" rc log
  rc="$WORK/leg4final-vm.rc"; log="$WORK/leg4final-vm.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-final" "\$from_rel"' '' vm "$rc" "$log"
  assert_vm_refusal "leg 4 (try-exhaustion rollback), vm refusal" "$log" "$rc"

  rc="$WORK/leg4final-refused.rc"; log="$WORK/leg4final-refused.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-final" "\$from_rel"' '' refused "$rc" "$log"
  assert_refused "leg 4 (try-exhaustion rollback), run-vm.sh refusal" "$log" "$rc"

  check_leg4_final_callsite_release "$f"
}

# check leg 4-final's call site stages a16 on a real boot
check_leg4_final_callsite_release() {
  local f="$1" rc="$WORK/leg4final-success.rc" log="$WORK/leg4final-success.log"
  run_callsite "$f" 'boot_and_start "\$\{label_prefix\}-final" "\$from_rel"' '' success "$rc" "$log"
  assert_success_path "leg 4 (try-exhaustion rollback), real boot" "$log" "$rc" a16
}

# check all of the call sites stage their release on a real boot
check_callsite_releases() {
  local f="$1"
  check_leg2_callsite_release "$f"
  check_leg3_callsite_release "$f"
  check_leg4_try_callsite_release "$f"
  check_leg4_final_callsite_release "$f"
}

STAGING_SITES=(
  "leg2-trial (a17 trial)|leg2-trial|a17"
  "leg3-rollback (manual rollback)|leg3-rollback|a16"
  "leg4-try (per-try loop)|leg4-try-1|a17"
  "leg4-final (try-exhaustion rollback)|leg4-final|a16"
)

# write a redeploy.sh stub that logs its arguments
stub_redeploy() {
  mkdir -p "$1"
  cat > "$1/redeploy.sh" <<STUB
#!/bin/bash
echo "REDEPLOY_CALL RHIZO_GSI=\${RHIZO_GSI:-} \$*" >> "$2"
exit 0
STUB
  chmod +x "$1/redeploy.sh"
}

# print PASS or FAIL for a leg's staging trace from its call log
verify_staging_log() {
  local name="$1" logf="$2" expected="$3"
  local kill_ln boot_ln wait_ln start_ln redeploy_ln redeploy_line rel_count rel
  local -a redeploy_lns

  grep -q '^UNKNOWN_CMD' "$logf" \
    && { echo "FAIL staging order, $name: called something this trace does not stub: $(cat "$logf")"; return; }

  kill_ln=$(grep -n '^KILL_VM$' "$logf" | head -1 | cut -d: -f1)
  boot_ln=$(grep -n '^BOOT_VM$' "$logf" | head -1 | cut -d: -f1)
  wait_ln=$(grep -n '^WAIT_FOR_SSH$' "$logf" | head -1 | cut -d: -f1)
  start_ln=$(grep -n "^SSH_VM -t 60 systemctl start androidd.service$" "$logf" | head -1 | cut -d: -f1)
  mapfile -t redeploy_lns < <(grep -n '^REDEPLOY_CALL ' "$logf" | cut -d: -f1)

  [[ -n "$kill_ln" ]] || { echo "FAIL staging order, $name: kill_vm never ran: $(cat "$logf")"; return; }
  [[ -n "$boot_ln" ]] || { echo "FAIL staging order, $name: boot_vm never ran: $(cat "$logf")"; return; }
  [[ -n "$wait_ln" ]] || { echo "FAIL staging order, $name: wait_for_ssh never ran: $(cat "$logf")"; return; }
  [[ -n "$start_ln" ]] || { echo "FAIL staging order, $name: androidd was never started over ssh (want: ssh_vm -t 60 'systemctl start androidd.service'): $(cat "$logf")"; return; }

  if (( ${#redeploy_lns[@]} != 1 )); then
    echo "FAIL staging order, $name: stage_release ran redeploy.sh ${#redeploy_lns[@]} times, want 1: $(cat "$logf")"
    return
  fi
  redeploy_ln="${redeploy_lns[0]}"

  local early_start
  early_start=$(awk -v w="$redeploy_ln" 'NR < w && /^SSH_VM / && /systemctl[ \t]+(re)?start[ \t]+androidd/' "$logf" | head -1)
  [[ -z "$early_start" ]] \
    || { echo "FAIL staging order, $name: androidd was started over ssh before stage_release ran: $early_start"; return; }

  if ! (( kill_ln < boot_ln && boot_ln < wait_ln && wait_ln < redeploy_ln && redeploy_ln < start_ln )); then
    echo "FAIL staging order, $name: call order was kill_vm=$kill_ln boot_vm=$boot_ln wait_for_ssh=$wait_ln stage_release=$redeploy_ln androidd_start=$start_ln -- want kill_vm < boot_vm < wait_for_ssh < stage_release < androidd start"
    return
  fi

  redeploy_line="$(sed -n "${redeploy_ln}p" "$logf")"
  rel_count=$(grep -o -- '--release' <<<"$redeploy_line" | wc -l)
  if (( rel_count != 1 )); then
    echo "FAIL staging order, $name: redeploy.sh's own args carry $rel_count --release tokens, want exactly 1: $redeploy_line"
    return
  fi
  rel="$(sed -E 's/.*--release +([^ ]+).*/\1/' <<<"$redeploy_line")"
  if [[ "$rel" != "$expected" ]]; then
    echo "FAIL staging order, $name: redeploy.sh staged --release $rel, want $expected: $redeploy_line"
    return
  fi

  local gsi_count gsi_val
  gsi_count=$(grep -o -- '--gsi' <<<"$redeploy_line" | wc -l)
  if [[ "$expected" == a16 ]]; then
    if (( gsi_count != 0 )); then
      echo "FAIL staging order, $name: redeploy.sh staged with --gsi on the a16 leg, want none: $redeploy_line"
      return
    fi
  else
    if (( gsi_count != 1 )); then
      echo "FAIL staging order, $name: redeploy.sh's own args carry $gsi_count --gsi tokens, want exactly 1 for $expected: $redeploy_line"
      return
    fi
    gsi_val="$(sed -E 's/.*--gsi +([^ ]+).*/\1/' <<<"$redeploy_line")"
    if [[ "$gsi_val" != "${FIXTURE_GSI_DIR[$expected]}" ]]; then
      echo "FAIL staging order, $name: redeploy.sh staged --gsi $gsi_val, want ${FIXTURE_GSI_DIR[$expected]} ($expected's own tree): $redeploy_line"
      return
    fi
  fi

  local rhizo_gsi_val
  rhizo_gsi_val="$(sed -E 's/^REDEPLOY_CALL RHIZO_GSI=([^ ]*) .*/\1/' <<<"$redeploy_line")"
  [[ -z "$rhizo_gsi_val" ]] \
    || { echo "FAIL staging order, $name: RHIZO_GSI=$rhizo_gsi_val was set in redeploy.sh's own environment, want empty: $redeploy_line"; return; }

  echo "PASS staging order, $name: kill_vm, boot_vm, wait_for_ssh, stage_release (redeploy.sh --release $expected once), then the androidd start -- all in order"
}

# run a leg's staging against stubs and verify its trace
run_staging_site() {
  local f="$1" name="$2" label="$3" release="$4"
  local bstart sr mline rundir logf

  bstart="$(extract_func "$f" boot_and_start)" \
    || { echo "FAIL staging order, $name: boot_and_start() is not defined in this file"; return; }
  sr="$(extract_func "$f" stage_release)" \
    || { echo "FAIL staging order, $name: stage_release() is not defined in this file"; return; }
  if ! grep -q 'rel="$2"' <<<"$bstart"; then
    echo "FAIL staging order, $name: boot_and_start's own body never binds a release from \$2"
    return
  fi
  mline="$(extract_func "$f" marker_line || true)"

  rundir="$WORK/redeploy-$label/system/lib"
  logf="$WORK/staging-$label.log"
  : > "$logf"
  mkdir -p "$rundir"
  stub_redeploy "$WORK/redeploy-$label/vm" "$logf"

  (
    cd "$rundir" || exit 125
    set -uo pipefail
    _GSI_UPDATE_LIB_DIR="$rundir"
    unset RHIZO_GSI
    CALL_LOG="$logf"
    # shellcheck disable=SC2034
    declare -A GSI_DIR=([a16]="${FIXTURE_GSI_DIR[a16]}" [a17]="${FIXTURE_GSI_DIR[a17]}")
    command_not_found_handle() { echo "UNKNOWN_CMD $*" >> "$CALL_LOG"; return 127; }
    ssh_vm() { echo "SSH_VM $*" >> "$CALL_LOG"; }
    kill_vm() { echo "KILL_VM" >> "$CALL_LOG"; }
    boot_vm() { echo "BOOT_VM" >> "$CALL_LOG"; }
    wait_for_boot_slot() { return 0; }
    wait_for_ssh() { echo "WAIT_FOR_SSH" >> "$CALL_LOG"; return 0; }
    wait_for_guest_ready() { echo "WAIT_FOR_GUEST_READY" >> "$CALL_LOG"; return 0; }
    log() { :; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    test_scratch_log() { echo "$WORK/scratch-$RANDOM.log"; }
    [[ -n "$mline" ]] && eval "$mline"
    eval "$sr"
    eval "$bstart"
    boot_and_start "$label" "$release" ""
    echo BLOCK_END >> "$CALL_LOG"
  ) >/dev/null 2>&1

  verify_staging_log "$name" "$logf" "$release"
}

# print a PASS or FAIL line per leg
staging_trace_report() {
  local f="$1" ok=0 entry name label release line
  for entry in "${STAGING_SITES[@]}"; do
    IFS='|' read -r name label release <<<"$entry"
    line="$(run_staging_site "$f" "$name" "$label" "$release")"
    echo "$line"
    [[ "$line" == PASS\ * ]] || ok=1
  done
  return "$ok"
}

# record each FAIL line of the staging trace
check_staging_order() {
  local f="$1" out rc line saw_fail
  out="$(staging_trace_report "$f")"
  rc=$?
  STAGING_ANALYSIS_OUT="$out"
  printf '%s\n' "$out"
  saw_fail=0
  while IFS= read -r line; do
    if [[ "$line" == FAIL\ * ]]; then
      fail_check "${line#FAIL }"
      saw_fail=1
    fi
  done <<< "$out"
  if (( rc != 0 )) && (( ! saw_fail )); then
    fail_check "staging-order analysis exited $rc with no verdict"
  fi
  return "$rc"
}

# check the boot state globals across legs
check_gsi_no_row_and_booted_state_across_legs() {
  local f="$1" mline bstart leg2_block leg3_block log
  mline="$(extract_func "$f" marker_line)" || { fail_check "no-row/booted across legs: could not extract marker_line"; return; }
  bstart="$(extract_func "$f" boot_and_start)" || { fail_check "no-row/booted across legs: could not extract boot_and_start"; return; }
  leg2_block="$(extract_block "$f" 'boot_and_start "\$\{label_prefix\}-trial" "\$to_rel"' "${CALLSITE_ANCHORS[@]}")" \
    || { fail_check "no-row/booted across legs: could not extract leg2's call site"; return; }
  leg3_block="$(extract_block "$f" 'boot_and_start "\$\{label_prefix\}-rollback" "\$from_rel"' "${CALLSITE_ANCHORS[@]}")" \
    || { fail_check "no-row/booted across legs: could not extract leg3's call site"; return; }
  log="$WORK/norow-booted-$RANDOM.log"
  : > "$log"
  (
    set -uo pipefail
    CALL_LOG="$log"
    BOOT_REFUSED_BY=""
    RHIZO_BOOT_REFUSAL=""
    # shellcheck disable=SC2034
    ADB="$FIXTURE_ADB" INIT="$FIXTURE_INIT" UPDATE_SH="$FIXTURE_UPDATE_SH" DESKAPP_PKG="$FIXTURE_DESKAPP_PKG"
    # shellcheck disable=SC2034
    DMESG_READ="" USER0_STATE=""
    # shellcheck disable=SC2034
    declare -A GSI_DIR=([a16]="${FIXTURE_GSI_DIR[a16]}" [a17]="${FIXTURE_GSI_DIR[a17]}")
    # shellcheck disable=SC2034
    label_prefix=fixture-leg to_rel=a17 from_rel=a16 tries=1 stage_fn=stage_release
    command_not_found_handle() { echo "UNKNOWN_CMD $*" >> "$CALL_LOG"; return 127; }
    ssh_vm() { echo "SSH_VM $*" >> "$CALL_LOG"; }
    kill_vm() { echo "KILL_VM" >> "$CALL_LOG"; }
    boot_vm() { echo "BOOT_VM" >> "$CALL_LOG"; }
    wait_for_boot_slot() { return 0; }
    wait_for_guest_ready() { echo "WAIT_FOR_GUEST_READY" >> "$CALL_LOG"; return 0; }
    stage_release() { echo "STAGE_RELEASE $*" >> "$CALL_LOG"; }
    log() { :; }
    fail() { echo "FAIL $*" >> "$CALL_LOG"; }
    pass() { echo "PASS $*" >> "$CALL_LOG"; }
    capture_units() { echo "CAPTURE_UNITS $*" >> "$CALL_LOG"; }
    boot_dmesg_has() { echo "BOOT_DMESG_HAS $*" >> "$CALL_LOG"; return 1; }
    test_collect_boot_evidence() { echo "TEST_COLLECT_BOOT_EVIDENCE $*" >> "$CALL_LOG"; }
    test_scratch_log() { echo "$WORK/scratch-$RANDOM.log"; }
    eval "$mline"
    eval "$bstart"

    wait_for_ssh() { echo "WAIT_FOR_SSH" >> "$CALL_LOG"; RHIZO_BOOT_REFUSAL="refusing to boot vm 3 at the boot guard"; return 1; }
    poll_boot_completed() { echo "POLL_BOOT_COMPLETED $*" >> "$CALL_LOG"; BC=""; return 1; }
    update_out=$SUCCESS_TEXT
    eval "$leg2_block" || true
    echo "CALL1 NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}]" >> "$CALL_LOG"

    wait_for_ssh() { echo "WAIT_FOR_SSH" >> "$CALL_LOG"; return 0; }
    poll_boot_completed() { echo "POLL_BOOT_COMPLETED $*" >> "$CALL_LOG"; BC=1; return 0; }
    rollback_out=$SUCCESS_TEXT
    eval "$leg3_block" || true
    echo "CALL2 NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}]" >> "$CALL_LOG"

    wait_for_ssh() { echo "WAIT_FOR_SSH" >> "$CALL_LOG"; RHIZO_BOOT_REFUSAL="refusing to boot vm 3 at the boot guard"; return 1; }
    poll_boot_completed() { echo "POLL_BOOT_COMPLETED $*" >> "$CALL_LOG"; BC=""; return 1; }
    update_out=$SUCCESS_TEXT
    eval "$leg2_block" || true
    echo "CALL3 NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}]" >> "$CALL_LOG"
    echo BLOCK_END >> "$CALL_LOG"
  ) >/dev/null 2>&1
  grep -qx 'BLOCK_END' "$log" \
    || { fail_check "no-row/booted across legs: the eval'd sequence never reached BLOCK_END: $(cat "$log")"; return; }
  grep -q '^CALL1 NO_ROW=\[1\] BOOTED=\[\]$' "$log" \
    || fail_check "no-row/booted across legs: call 1 (refused, nothing booted yet) did not read NO_ROW=1 BOOTED=[]: $(grep '^CALL1' "$log")"
  grep -q '^CALL2 NO_ROW=\[\] BOOTED=\[1\]$' "$log" \
    || fail_check "no-row/booted across legs: call 2 (a real boot) did not reset NO_ROW to empty and set BOOTED=1: $(grep '^CALL2' "$log")"
  grep -q '^CALL3 NO_ROW=\[\] BOOTED=\[1\]$' "$log" \
    || fail_check "no-row/booted across legs: call 3 (refused, after something already booted) set NO_ROW when it must not: $(grep '^CALL3' "$log")"
}

# run all of the checks against a gsi-update copy
run_all_checks() {
  FAILURES=()
  check_refusal_blocks_reboot "$1"
  check_failed_blocks_reboot "$1"
  check_success_still_boots "$1"
  check_empty_preceding_still_boots "$1"
  check_kill_vm_failure_stops_boot "$1"
  check_wait_for_ssh_failure_is_vm "$1"
  check_leg2_skips_poll_on_boot_refusal "$1"
  check_leg3_skips_poll_on_boot_refusal "$1"
  check_leg4_try_skips_poll_on_boot_refusal "$1"
  check_leg4_final_skips_poll_on_boot_refusal "$1"
  check_staging_order "$1" >/dev/null
  check_gsi_no_row_and_booted_state_across_legs "$1"
}

if [[ "${1:-}" == --staging-only ]]; then
  STAGING_FILE="${2:-}"
  [[ -n "$STAGING_FILE" && -r "$STAGING_FILE" ]] \
    || { echo "FAIL: --staging-only needs a readable system test file, got '${STAGING_FILE:-<none>}'"; exit 1; }
  FAILURES=()
  STAGING_ANALYSIS_OUT=""
  check_staging_order "$STAGING_FILE"
  check_callsite_releases "$STAGING_FILE"
  pass_count=$(grep -c '^PASS ' <<<"$STAGING_ANALYSIS_OUT")
  if (( ${#FAILURES[@]} > 0 )) || (( pass_count != 4 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}"
    exit 1
  fi
  exit 0
fi

if (( ! SELFTEST )); then
  run_all_checks "$SRC"
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}"
    exit 1
  fi
  echo "ok: boot_and_start refuses to reboot on a RHIZO_GSI_UPDATE_REFUSED/_FAILED sentinel, refuses to boot a new guest when kill_vm cannot confirm the old one died, still boots on a real status line or no preceding output, stops androidd.service before kill_vm, and every call site stops polling on a boot_and_start failure"
  exit 0
fi

# restore boot_and_start's old shape in a copy
inject_old_shape() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.find("boot_and_start() {")
if i == -1:
    sys.exit("SELFTEST SETUP FAIL: boot_and_start() not found")
j = s.find("\n}\n", i)
if j == -1:
    sys.exit("SELFTEST SETUP FAIL: could not find the end of boot_and_start()")
j += len("\n}\n")
old = '''boot_and_start() {  # boot_and_start <label> <release>
  local label="$1" rel="$2"
  log "  rebooting the guest for $label, the way an armed update takes effect"
  kill_vm >/dev/null 2>&1
  boot_vm > "$(test_scratch_log "boot-$label")" 2>&1
  wait_for_ssh 300 || { fail "$label: ssh never came up after the reboot"; return 1; }
  wait_for_guest_ready 120 || log "  $label: guest not fully ready, staging anyway"
  stage_release "$rel"
  ssh_vm -t 60 'systemctl start androidd.service' > "$(test_scratch_log "start-$label")" 2>&1
  log "  $label: androidd start returned"
}
'''
open(p, "w").write(s[:i] + old + s[j:])
PY
}

# drop a call site's rc check in a copy
strip_rc_check() {
  python3 - "$1" "$2" <<'PY'
import re, sys
path, pattern = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
rx = re.compile(pattern)
start = next((i for i, l in enumerate(lines) if rx.search(l)), None)
if start is None:
    sys.exit("SELFTEST SETUP FAIL: start pattern not found: " + pattern)
if not re.match(r'^\s*if\b.*;\s*then\s*$', lines[start]):
    sys.exit("SELFTEST SETUP FAIL: start line is not an 'if ...; then': " + lines[start])
open_kw = re.compile(r'^(if|for|while|until|case)\b')
close_kw = re.compile(r'^(fi|done|esac)$')
depth = 1
else_idx = None
fi_idx = None
for i in range(start + 1, len(lines)):
    stripped = lines[i].strip()
    if stripped == 'else' and depth == 1 and else_idx is None:
        else_idx = i
        continue
    if open_kw.match(stripped):
        depth += 1
    elif close_kw.match(stripped):
        depth -= 1
        if depth == 0:
            fi_idx = i
            break
if else_idx is None or fi_idx is None:
    sys.exit("SELFTEST SETUP FAIL: could not find this site's else/fi")
new_start = re.sub(r'^(\s*)if\s+(.*);\s*then\s*$', r'\1\2', lines[start])
def dedent(l):
    return l[2:] if l.startswith('  ') else l
body = [dedent(l) for l in lines[start + 1:else_idx]]
out = lines[:start] + [new_start] + body + lines[fi_idx + 1:]
open(path, "w").write("\n".join(out) + "\n")
PY
}

# replace a call site's then body with a no-op in a copy
empty_then_body() {
  python3 - "$1" "$2" <<'PY'
import re, sys
path, pattern = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
rx = re.compile(pattern)
start = next((i for i, l in enumerate(lines) if rx.search(l)), None)
if start is None:
    sys.exit("SELFTEST SETUP FAIL: start pattern not found: " + pattern)
if not re.match(r'^\s*if\b.*;\s*then\s*$', lines[start]):
    sys.exit("SELFTEST SETUP FAIL: start line is not an 'if ...; then': " + lines[start])
open_kw = re.compile(r'^(if|for|while|until|case)\b')
close_kw = re.compile(r'^(fi|done|esac)$')
depth = 1
else_idx = None
for i in range(start + 1, len(lines)):
    stripped = lines[i].strip()
    if stripped == 'else' and depth == 1 and else_idx is None:
        else_idx = i
        break
    if open_kw.match(stripped):
        depth += 1
    elif close_kw.match(stripped):
        depth -= 1
if else_idx is None:
    sys.exit("SELFTEST SETUP FAIL: could not find this site's else")
indent = re.match(r'^(\s*)', lines[start]).group(1)
out = lines[:start + 1] + [indent + "  :"] + lines[else_idx:]
open(path, "w").write("\n".join(out) + "\n")
PY
}

# add a stray poll_boot_completed call in a copy
inject_stray_poll() {
  python3 - "$1" "$2" <<'PY'
import sys
path, anchor = sys.argv[1], sys.argv[2]
s = open(path).read()
i = s.find(anchor)
if i == -1:
    sys.exit("SELFTEST SETUP FAIL: anchor not found: " + anchor)
call = 'test_collect_boot_evidence "test-vm-never-came-up"'
j = s.rfind(call, 0, i)
if j == -1 or s.count("\n", j, i) != 1:
    sys.exit("SELFTEST SETUP FAIL: no test_collect_boot_evidence call on the line above the anchor")
line_start = s.rfind("\n", 0, j) + 1
indent = s[line_start:j][:len(s[line_start:j]) - len(s[line_start:j].lstrip())]
k = j + len(call)
open(path, "w").write(s[:k] + "\n" + indent + "poll_boot_completed 1" + s[k:])
PY
}

# drop the rc check on boot_and_start's kill_vm call in a copy
strip_kill_vm_check() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'kill_vm >/dev/null 2>&1 || { fail "$label: kill_vm could not confirm the old guest was torn down"; return 1; }'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: kill_vm rc check not found")
s = s.replace(old, "kill_vm >/dev/null 2>&1", 1)
open(p, "w").write(s)
PY
}

# move BOOT_REFUSED_BY=vm to just before boot_vm in a copy
move_vm_after_kill_vm() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "  BOOT_REFUSED_BY=vm\n"
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: BOOT_REFUSED_BY=vm not found exactly once")
s = s.replace(old, "", 1)
anchor = '  boot_vm > "$(test_scratch_log "boot-$label")" 2>&1\n'
if anchor not in s:
    sys.exit("SELFTEST SETUP FAIL: boot_vm call not found")
s = s.replace(anchor, "  BOOT_REFUSED_BY=vm\n" + anchor, 1)
open(p, "w").write(s)
PY
}

# set BOOT_REFUSED_BY=product on the kill_vm failure branch in a copy
mislabel_kill_vm_failure_as_product() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '|| { fail "$label: kill_vm could not confirm'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: kill_vm failure branch not found")
s = s.replace(old, '|| { BOOT_REFUSED_BY=product; fail "$label: kill_vm could not confirm', 1)
open(p, "w").write(s)
PY
}

# add a poll after a call site's block in a copy
inject_toplevel_if_poll() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
path, pattern, deadline = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
rx = re.compile(pattern)
start = next((i for i, l in enumerate(lines) if rx.search(l)), None)
if start is None:
    sys.exit("SELFTEST SETUP FAIL: start pattern not found: " + pattern)
open_kw = re.compile(r'^(if|for|while|until|case)\b')
close_kw = re.compile(r'^(fi|done|esac)$')
depth = 0
seen_open = False
end = None
for i in range(start, len(lines)):
    stripped = lines[i].strip()
    if open_kw.match(stripped):
        depth += 1
        seen_open = True
    elif close_kw.match(stripped):
        depth -= 1
    if seen_open and depth == 0:
        end = i
        break
if end is None:
    sys.exit("SELFTEST SETUP FAIL: could not find this site's own block end")
insert = ["if true; then", "  :", "fi",
          'poll_boot_completed %s || fail "unexpected late poll"' % deadline]
out = lines[:end + 1] + insert + lines[end + 1:]
open(path, "w").write("\n".join(out) + "\n")
PY
}

# add an unset variable reference to a call site in a copy
inject_unset_var_seed() {
  python3 - "$1" "$2" <<'PY'
import re, sys
path, pattern = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
rx = re.compile(pattern)
start = next((i for i, l in enumerate(lines) if rx.search(l)), None)
if start is None:
    sys.exit("SELFTEST SETUP FAIL: start pattern not found: " + pattern)
if not re.match(r'^\s*if\b.*;\s*then\s*$', lines[start]):
    sys.exit("SELFTEST SETUP FAIL: start line is not an 'if ...; then': " + lines[start])
indent = re.match(r'^(\s*)', lines[start]).group(1)
out = lines[:start + 1] + [indent + '  echo "$RHIZO_UNSET_SEED_PROBE" >/dev/null'] + lines[start + 1:]
open(path, "w").write("\n".join(out) + "\n")
PY
}

# remove boot_and_start's stage_fn call in a copy
remove_stage_release_call() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  "$stage_fn" "$rel"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: \"$stage_fn\" \"$rel\" not found exactly once in boot_and_start")
s = s.replace(old, "", 1)
open(p, "w").write(s)
PY
}

# make leg 2's call site pass the release a17x in a copy
callsite_release_token_glued() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if boot_and_start "${label_prefix}-trial" "$to_rel" "$update_out" RHIZO_RELEASE_SWITCH=1 "$stage_fn"; then'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: leg2-trial call site not found exactly once")
s = s.replace(old, 'if boot_and_start "${label_prefix}-trial" "$to_rel"x "$update_out" RHIZO_RELEASE_SWITCH=1 "$stage_fn"; then', 1)
open(p, "w").write(s)
PY
}

# move the stage_fn call to after the androidd start in a copy
move_stage_release_after_start() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  "$stage_fn" "$rel"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release \"$rel\" not found exactly once")
s = s.replace(old, "", 1)
anchor = '  log "  $label: androidd start returned"\n'
if s.count(anchor) != 1:
    sys.exit("SELFTEST SETUP FAIL: androidd start log line not found exactly once")
s = s.replace(anchor, '  "$stage_fn" "$rel"\n' + anchor, 1)
open(p, "w").write(s)
PY
}

# add a second stage_fn call right after the first in a copy
add_second_stage_release_before_start() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  "$stage_fn" "$rel"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release \"$rel\" not found exactly once")
s = s.replace(old, old + "  stage_release a16\n", 1)
open(p, "w").write(s)
PY
}

# add a second stage_release call after the androidd start in a copy
add_second_stage_release_after_start() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '  log "  $label: androidd start returned"\n'
if s.count(anchor) != 1:
    sys.exit("SELFTEST SETUP FAIL: androidd start log line not found exactly once")
s = s.replace(anchor, '  stage_release a16\n' + anchor, 1)
open(p, "w").write(s)
PY
}

# reassign rel right before the stage_fn call in a copy
reassign_rel_before_stage() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  "$stage_fn" "$rel"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release \"$rel\" not found exactly once")
s = s.replace(old, '  rel=a16\n' + old, 1)
open(p, "w").write(s)
PY
}

# hardcode stage_release's --release argument in a copy
hardcode_stage_release_arg() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'local args=(--skip-kill --no-launch --release "$label")'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release args line not found exactly once")
s = s.replace(old, 'local args=(--skip-kill --no-launch --release a16)', 1)
open(p, "w").write(s)
PY
}

# append a second --release to stage_release's args in a copy
stage_release_extra_release_token() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'local args=(--skip-kill --no-launch --release "$label")\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release args line not found exactly once")
s = s.replace(old, old + '  args+=(--release a16)\n', 1)
open(p, "w").write(s)
PY
}

# make stage_release return before redeploy.sh on a16 in a copy
stage_release_early_return_a16() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'local args=(--skip-kill --no-launch --release "$label")\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release args line not found exactly once")
s = s.replace(old, old + '  [[ "$label" == a16 ]] && return 0\n', 1)
open(p, "w").write(s)
PY
}

# drop the args array from stage_release's redeploy.sh call in a copy
stage_release_redeploy_drops_args() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '"$_GSI_UPDATE_LIB_DIR/../../vm/redeploy.sh" "${args[@]}" > "$(test_scratch_log "stage-release-$label")" 2>&1'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: redeploy.sh call not found exactly once")
new = '"$_GSI_UPDATE_LIB_DIR/../../vm/redeploy.sh" --skip-kill --no-launch > "$(test_scratch_log "stage-release-$label")" 2>&1'
s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
}

# reassign stage_release's label to a16 in a copy
stage_release_label_hardcoded() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'local label="$1"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release's own local label=\"$1\" not found exactly once")
s = s.replace(old, old + '  label=a16\n', 1)
open(p, "w").write(s)
PY
}

# flip stage_release's --gsi condition to only a16 in a copy
flip_gsi_condition() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  [[ "$label" == a16 ]] || args+=(--gsi "${GSI_DIR[$label]}")\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: --gsi condition line not found exactly once")
new = '  [[ "$label" == a16 ]] && args+=(--gsi "${GSI_DIR[$label]}")\n'
s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
}

# hardcode the --gsi argument to a16's tree in a copy
hardcode_gsi_tree_a16() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'args+=(--gsi "${GSI_DIR[$label]}")'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: --gsi args line not found exactly once")
new = 'args+=(--gsi "${GSI_DIR[a16]}")'
s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
}

# make leg 4's per-try call site pass a16 instead of a17 in a copy
callsite_leg4try_release_wrong() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if boot_and_start "${label_prefix}-try-$try" "$to_rel" "" "RHIZO_FAULT_NO_READY=1 RHIZO_RELEASE_SWITCH=1" "$stage_fn"; then'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: leg4-try call site not found exactly once")
new = 'if boot_and_start "${label_prefix}-try-$try" a16 "" "RHIZO_FAULT_NO_READY=1 RHIZO_RELEASE_SWITCH=1" "$stage_fn"; then'
s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
}

# add a second stage_release definition before marker_line in a copy
add_duplicate_stage_release_definition() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = 'marker_line() {'
if s.count(anchor) != 1:
    sys.exit("SELFTEST SETUP FAIL: marker_line() definition not found exactly once")
dup = ('stage_release() {  # a later, hardcoded redefinition\n'
       '  local label="$1"\n'
       '  ../../vm/redeploy.sh --skip-kill --no-launch --release a16 '
       '> "$(test_scratch_log "stage-release-$label")" 2>&1 || fail "staging failed"\n'
       '}\n\n')
s = s.replace(anchor, dup + anchor, 1)
open(p, "w").write(s)
PY
}

# add an androidd start before the stage_fn call in a copy
insert_early_androidd_start() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  "$stage_fn" "$rel"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release \"$rel\" not found exactly once")
new = "  ssh_vm 'systemctl restart androidd' >/dev/null 2>&1\n" + old
s = s.replace(old, new, 1)
open(p, "w").write(s)
PY
}

# add a wait_for_ssh and stage_fn call before kill_vm in a copy
stage_release_before_kill_vm() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
stage_line = '  "$stage_fn" "$rel"\n'
if s.count(stage_line) != 1:
    sys.exit("SELFTEST SETUP FAIL: stage_release \"$rel\" not found exactly once")
s = s.replace(stage_line, "", 1)
anchor = '  kill_vm >/dev/null 2>&1 || { fail "$label: kill_vm could not confirm'
if s.count(anchor) != 1:
    sys.exit("SELFTEST SETUP FAIL: boot_and_start's own kill_vm line not found exactly once")
s = s.replace(
    anchor,
    '  wait_for_ssh 5 >/dev/null 2>&1 || true\n' + stage_line + anchor,
    1,
)
open(p, "w").write(s)
PY
}

# remove boot_and_start's wait_for_ssh call in a copy
strip_wait_for_ssh_call() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines(keepends=True)
start = next((i for i, l in enumerate(lines) if l == '  if ! wait_for_ssh 300; then\n'), None)
if start is None:
    sys.exit("SELFTEST SETUP FAIL: wait_for_ssh call not found exactly once")
depth = 0
end = None
for i in range(start, len(lines)):
    stripped = lines[i].strip()
    if stripped.startswith('if '):
        depth += 1
    elif stripped == 'fi':
        depth -= 1
        if depth == 0:
            end = i
            break
if end is None:
    sys.exit("SELFTEST SETUP FAIL: wait_for_ssh if-block has no matching fi")
del lines[start:end + 1]
open(p, "w").write("".join(lines))
PY
}

# remove boot_and_start's kill_vm call in a copy
strip_kill_vm_call() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  kill_vm >/dev/null 2>&1 || { fail "$label: kill_vm could not confirm the old guest was torn down"; return 1; }\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: kill_vm call not found exactly once")
s = s.replace(old, "", 1)
open(p, "w").write(s)
PY
}

# remove boot_and_start's boot_vm call in a copy
strip_boot_vm_call() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  boot_vm > "$(test_scratch_log "boot-$label")" 2>&1\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: boot_vm call not found exactly once")
s = s.replace(old, "", 1)
open(p, "w").write(s)
PY
}

# remove boot_and_start's androidd start in a copy
strip_androidd_start_call() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  ssh_vm -t 60 \'systemctl start androidd.service\' > "$(test_scratch_log "start-$label")" 2>&1\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: androidd start call not found exactly once")
s = s.replace(old, "", 1)
open(p, "w").write(s)
PY
}

# rename boot_and_start in a copy
rename_boot_and_start() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '\nboot_and_start() {\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: boot_and_start() definition not found exactly once")
s = s.replace(old, '\nboot_and_start_renamed() {\n', 1)
open(p, "w").write(s)
PY
}

# add an ssh poll on BOOT_REFUSED_BY=product to leg 2's else branch in a copy
inject_sentinel_only_ssh_poll_leg2() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '    fail "${label_prefix}-trial: not run -- boot_and_start failed ($BOOT_REFUSED_BY)"\n  fi\n'
if s.count(anchor) != 1:
    sys.exit("SELFTEST SETUP FAIL: leg2-trial else/fi not found exactly once")
s = s.replace(
    anchor,
    '    fail "${label_prefix}-trial: not run -- boot_and_start failed ($BOOT_REFUSED_BY)"\n'
    '  [[ "$BOOT_REFUSED_BY" == product ]] && ssh_vm -t 600 "getprop sys.boot_completed"\n'
    '  fi\n',
    1,
)
open(p, "w").write(s)
PY
}

# add a poll through an unstubbed wrapper to leg 2's else branch in a copy
inject_sentinel_wrapper_poll_leg2() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '    fail "${label_prefix}-trial: not run -- boot_and_start failed ($BOOT_REFUSED_BY)"\n  fi\n'
if s.count(anchor) != 1:
    sys.exit("SELFTEST SETUP FAIL: leg2-trial else/fi not found exactly once")
s = s.replace(
    anchor,
    '    fail "${label_prefix}-trial: not run -- boot_and_start failed ($BOOT_REFUSED_BY)"\n'
    '  [[ "$BOOT_REFUSED_BY" == product ]] && wait_boot 600\n'
    '  fi\n',
    1,
)
if s.count('poll_boot_completed() {') != 1:
    sys.exit("SELFTEST SETUP FAIL: poll_boot_completed() not found exactly once")
s = s.replace(
    'poll_boot_completed() {',
    'wait_boot() { poll_boot_completed "$@"; }\npoll_boot_completed() {',
    1,
)
open(p, "w").write(s)
PY
}

SITES=(
  'leg2|boot_and_start "\$\{label_prefix\}-trial" "\$to_rel"|fail "${label_prefix}-trial: not run -- boot_and_start failed'
  'leg3|boot_and_start "\$\{label_prefix\}-rollback" "\$from_rel"|fail "${label_prefix}-rollback: not run -- boot_and_start failed'
  'leg4try|boot_and_start "\$\{label_prefix\}-try-\$try" "\$to_rel"|fail "${label_prefix}-try-$try: not run -- boot_and_start failed'
  'leg4final|boot_and_start "\$\{label_prefix\}-final" "\$from_rel"|fail "${label_prefix}-final: not run -- boot_and_start failed'
)
CHECK_FN=(
  check_leg2_skips_poll_on_boot_refusal
  check_leg3_skips_poll_on_boot_refusal
  check_leg4_try_skips_poll_on_boot_refusal
  check_leg4_final_skips_poll_on_boot_refusal
)

# print a selftest failure and exit 1
selftest_fail() { echo "SELFTEST FAIL: $1"; exit 1; }

copy="$WORK/defect-old-shape.sh"
cp "$SRC" "$copy"
inject_old_shape "$copy" || selftest_fail "could not set up the old-boot_and_start-shape fixture"
bash -n "$copy" || selftest_fail "old-boot_and_start-shape copy is not valid bash"
run_all_checks "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with boot_and_start's pre-fix shape (no refusal check, no graceful stop, no kill_vm check)"
echo "selftest ok: detected -- ${FAILURES[0]}"

for idx in "${!SITES[@]}"; do
  IFS='|' read -r name pattern anchor <<<"${SITES[$idx]}"
  fn="${CHECK_FN[$idx]}"

  copy="$WORK/defect-$name-no-rc-check.sh"
  cp "$SRC" "$copy"
  strip_rc_check "$copy" "$pattern" || selftest_fail "$name: could not set up the rc-check-removed fixture"
  bash -n "$copy" || selftest_fail "$name: rc-check-removed copy is not valid bash"
  FAILURES=(); "$fn" "$copy"
  (( ${#FAILURES[@]} > 0 )) \
    || selftest_fail "$name: the checker passed a copy with its rc check removed"
  echo "selftest ok ($name, rc check removed): detected -- ${FAILURES[0]}"

  copy="$WORK/defect-$name-poll-anyway.sh"
  cp "$SRC" "$copy"
  inject_stray_poll "$copy" "$anchor" || selftest_fail "$name: could not set up the poll-anyway fixture"
  bash -n "$copy" || selftest_fail "$name: poll-anyway copy is not valid bash"
  FAILURES=(); "$fn" "$copy"
  (( ${#FAILURES[@]} > 0 )) \
    || selftest_fail "$name: the checker passed a copy whose rc check is present but still polls in the failure branch"
  echo "selftest ok ($name, poll happens anyway): detected -- ${FAILURES[0]}"

  copy="$WORK/defect-$name-empty-then.sh"
  cp "$SRC" "$copy"
  empty_then_body "$copy" "$pattern" || selftest_fail "$name: could not set up the empty-then-body fixture"
  bash -n "$copy" || selftest_fail "$name: empty-then-body copy is not valid bash"
  FAILURES=(); "$fn" "$copy"
  (( ${#FAILURES[@]} > 0 )) \
    || selftest_fail "$name: the checker passed a copy whose real boot never polled for sys.boot_completed"
  echo "selftest ok ($name, then-body emptied): detected -- ${FAILURES[0]}"

  copy="$WORK/defect-$name-toplevel-if-poll.sh"
  cp "$SRC" "$copy"
  inject_toplevel_if_poll "$copy" "${CALLSITE_ANCHORS[$idx]}" 1 \
    || selftest_fail "$name: could not set up the toplevel-if-poll fixture"
  bash -n "$copy" || selftest_fail "$name: toplevel-if-poll copy is not valid bash"
  FAILURES=(); "$fn" "$copy"
  (( ${#FAILURES[@]} > 0 )) \
    || selftest_fail "$name: the checker passed a copy with a poll after a new top-level if in this leg's own trailing region"
  echo "selftest ok ($name, poll after a new top-level if): detected -- ${FAILURES[0]}"

  copy="$WORK/defect-$name-unset-var-top.sh"
  cp "$SRC" "$copy"
  inject_unset_var_seed "$copy" "$pattern" \
    || selftest_fail "$name: could not set up the unset-var-top fixture"
  bash -n "$copy" || selftest_fail "$name: unset-var-top copy is not valid bash"
  FAILURES=(); "$fn" "$copy"
  (( ${#FAILURES[@]} > 0 )) \
    || selftest_fail "$name: the checker passed a copy with a new unset variable reference at the top of the block"
  echo "selftest ok ($name, unset var at top of block): detected -- ${FAILURES[0]}"
done

copy="$WORK/defect-kill-vm-rc-ignored.sh"
cp "$SRC" "$copy"
strip_kill_vm_check "$copy" || selftest_fail "could not set up the kill_vm-rc-ignored fixture"
bash -n "$copy" || selftest_fail "kill_vm-rc-ignored copy is not valid bash"
FAILURES=(); check_kill_vm_failure_stops_boot "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where boot_and_start ignores kill_vm's own failure"
echo "selftest ok (kill_vm rc ignored): detected -- ${FAILURES[0]}"

copy="$WORK/defect-kill-vm-boot-refused-by-unset.sh"
cp "$SRC" "$copy"
move_vm_after_kill_vm "$copy" || selftest_fail "could not set up the kill_vm BOOT_REFUSED_BY-unset fixture"
bash -n "$copy" || selftest_fail "kill_vm BOOT_REFUSED_BY-unset copy is not valid bash"
FAILURES=(); check_kill_vm_failure_stops_boot "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where BOOT_REFUSED_BY is never set to vm on the kill_vm failure path"
echo "selftest ok (kill_vm BOOT_REFUSED_BY unset): detected -- ${FAILURES[0]}"

copy="$WORK/defect-kill-vm-boot-refused-by-product.sh"
cp "$SRC" "$copy"
mislabel_kill_vm_failure_as_product "$copy" || selftest_fail "could not set up the kill_vm BOOT_REFUSED_BY=product fixture"
bash -n "$copy" || selftest_fail "kill_vm BOOT_REFUSED_BY=product copy is not valid bash"
FAILURES=(); check_kill_vm_failure_stops_boot "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where a vm fault (kill_vm) is mislabeled BOOT_REFUSED_BY=product"
echo "selftest ok (kill_vm BOOT_REFUSED_BY mislabeled product): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-removed.sh"
cp "$SRC" "$copy"
remove_stage_release_call "$copy" || selftest_fail "could not set up the stage_release-removed fixture"
bash -n "$copy" || selftest_fail "stage_release-removed copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with boot_and_start's own stage_release call removed"
echo "selftest ok (stage_release call removed): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-after-start.sh"
cp "$SRC" "$copy"
move_stage_release_after_start "$copy" || selftest_fail "could not set up the stage_release-after-start fixture"
bash -n "$copy" || selftest_fail "stage_release-after-start copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with stage_release moved after the androidd start"
echo "selftest ok (stage_release moved after the androidd start): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-before-kill-vm.sh"
cp "$SRC" "$copy"
stage_release_before_kill_vm "$copy" || selftest_fail "could not set up the stage_release-before-kill_vm fixture"
bash -n "$copy" || selftest_fail "stage_release-before-kill_vm copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with a pre-teardown wait_for_ssh probe and stage_release moved before kill_vm"
echo "selftest ok (stage_release moved before kill_vm): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-wait-for-ssh-skipped.sh"
cp "$SRC" "$copy"
strip_wait_for_ssh_call "$copy" || selftest_fail "could not set up the wait_for_ssh-skipped fixture"
bash -n "$copy" || selftest_fail "wait_for_ssh-skipped copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with boot_and_start's own wait_for_ssh call removed"
echo "selftest ok (wait_for_ssh skipped): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-kill-vm-skipped.sh"
cp "$SRC" "$copy"
strip_kill_vm_call "$copy" || selftest_fail "could not set up the kill_vm-skipped fixture"
bash -n "$copy" || selftest_fail "kill_vm-skipped copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with boot_and_start's own kill_vm call removed"
echo "selftest ok (kill_vm skipped): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-boot-vm-skipped.sh"
cp "$SRC" "$copy"
strip_boot_vm_call "$copy" || selftest_fail "could not set up the boot_vm-skipped fixture"
bash -n "$copy" || selftest_fail "boot_vm-skipped copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with boot_and_start's own boot_vm call removed"
echo "selftest ok (boot_vm skipped): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-androidd-start-skipped.sh"
cp "$SRC" "$copy"
strip_androidd_start_call "$copy" || selftest_fail "could not set up the androidd-start-skipped fixture"
bash -n "$copy" || selftest_fail "androidd-start-skipped copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with boot_and_start's own androidd start removed"
echo "selftest ok (androidd start skipped): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-boot-and-start-renamed.sh"
cp "$SRC" "$copy"
rename_boot_and_start "$copy" || selftest_fail "could not set up the boot_and_start-renamed fixture"
bash -n "$copy" || selftest_fail "boot_and_start-renamed copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where boot_and_start() itself is not defined under its own name"
echo "selftest ok (boot_and_start renamed): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-second-call-before-start.sh"
cp "$SRC" "$copy"
add_second_stage_release_before_start "$copy" || selftest_fail "could not set up the second-stage_release-before-start fixture"
bash -n "$copy" || selftest_fail "second-stage_release-before-start copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with a second stage_release call added before the androidd start"
echo "selftest ok (second stage_release call before the start): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-second-call-after-start.sh"
cp "$SRC" "$copy"
add_second_stage_release_after_start "$copy" || selftest_fail "could not set up the second-stage_release-after-start fixture"
bash -n "$copy" || selftest_fail "second-stage_release-after-start copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with a second stage_release call added after the androidd start"
echo "selftest ok (second stage_release call after the start): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-rel-reassigned.sh"
cp "$SRC" "$copy"
reassign_rel_before_stage "$copy" || selftest_fail "could not set up the rel-reassigned fixture"
bash -n "$copy" || selftest_fail "rel-reassigned copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where rel is reassigned right before the stage_release call"
echo "selftest ok (rel reassigned before stage_release): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-hardcoded-release.sh"
cp "$SRC" "$copy"
hardcode_stage_release_arg "$copy" || selftest_fail "could not set up the hardcoded-release fixture"
bash -n "$copy" || selftest_fail "hardcoded-release copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where stage_release hardcodes --release a16 instead of passing its own \$label"
echo "selftest ok (stage_release ignores its own argument): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-extra-release-token.sh"
cp "$SRC" "$copy"
stage_release_extra_release_token "$copy" || selftest_fail "could not set up the extra-release-token fixture"
bash -n "$copy" || selftest_fail "extra-release-token copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where stage_release's own redeploy.sh call carries two --release tokens"
echo "selftest ok (a second --release token on the redeploy.sh call): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-early-return-a16.sh"
cp "$SRC" "$copy"
stage_release_early_return_a16 "$copy" || selftest_fail "could not set up the early-return-a16 fixture"
bash -n "$copy" || selftest_fail "early-return-a16 copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where stage_release returns before redeploy.sh on the a16 leg"
echo "selftest ok (stage_release returns early on a16): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-redeploy-drops-args.sh"
cp "$SRC" "$copy"
stage_release_redeploy_drops_args "$copy" || selftest_fail "could not set up the redeploy-drops-args fixture"
bash -n "$copy" || selftest_fail "redeploy-drops-args copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where stage_release's own redeploy.sh call carries no --release at all"
echo "selftest ok (redeploy.sh call dropped its args): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-label-hardcoded.sh"
cp "$SRC" "$copy"
stage_release_label_hardcoded "$copy" || selftest_fail "could not set up the label-hardcoded fixture"
bash -n "$copy" || selftest_fail "label-hardcoded copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where stage_release reassigns label=a16 right after binding it from \$1"
echo "selftest ok (stage_release's own label reassigned to a16): detected -- ${FAILURES[0]}"

copy="$WORK/defect-callsite-release-token-glued.sh"
cp "$SRC" "$copy"
callsite_release_token_glued "$copy" || selftest_fail "could not set up the callsite-release-token-glued fixture"
bash -n "$copy" || selftest_fail "callsite-release-token-glued copy is not valid bash"
FAILURES=(); check_leg2_skips_poll_on_boot_refusal "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy whose leg2-trial call site passes a17x instead of a17"
echo "selftest ok (call-site release token glued): detected -- ${FAILURES[0]}"

copy="$WORK/defect-callsite-leg4try-release-wrong.sh"
cp "$SRC" "$copy"
callsite_leg4try_release_wrong "$copy" || selftest_fail "could not set up the callsite-leg4try-release-wrong fixture"
bash -n "$copy" || selftest_fail "callsite-leg4try-release-wrong copy is not valid bash"
FAILURES=(); check_callsite_releases "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy whose leg4-try call site passes a16 instead of a17"
echo "selftest ok (call-site leg4-try release wrong): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-gsi-condition-flipped.sh"
cp "$SRC" "$copy"
flip_gsi_condition "$copy" || selftest_fail "could not set up the gsi-condition-flipped fixture"
bash -n "$copy" || selftest_fail "gsi-condition-flipped copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where stage_release's own --gsi condition is flipped"
echo "selftest ok (gsi condition flipped): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-gsi-hardcoded-a16.sh"
cp "$SRC" "$copy"
hardcode_gsi_tree_a16 "$copy" || selftest_fail "could not set up the gsi-hardcoded-a16 fixture"
bash -n "$copy" || selftest_fail "gsi-hardcoded-a16 copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where --gsi is hardcoded to a16's own tree regardless of which release is staging"
echo "selftest ok (gsi hardcoded to a16's tree): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-duplicate-stage-release.sh"
cp "$SRC" "$copy"
add_duplicate_stage_release_definition "$copy" || selftest_fail "could not set up the duplicate-stage_release-definition fixture"
bash -n "$copy" || selftest_fail "duplicate-stage_release-definition copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with a second stage_release() definition later in the file"
echo "selftest ok (duplicate stage_release definition, bash runs the last one): detected -- ${FAILURES[0]}"

copy="$WORK/defect-staging-early-androidd-start.sh"
cp "$SRC" "$copy"
insert_early_androidd_start "$copy" || selftest_fail "could not set up the early-androidd-start fixture"
bash -n "$copy" || selftest_fail "early-androidd-start copy is not valid bash"
FAILURES=(); check_staging_order "$copy" >/dev/null
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy with androidd restarted over ssh before stage_release ran"
echo "selftest ok (androidd started early, differently shaped): detected -- ${FAILURES[0]}"

copy="$WORK/defect-leg2-sentinel-only-ssh-poll.sh"
cp "$SRC" "$copy"
inject_sentinel_only_ssh_poll_leg2 "$copy" || selftest_fail "could not set up the leg2 sentinel-only-ssh-poll fixture"
bash -n "$copy" || selftest_fail "leg2 sentinel-only-ssh-poll copy is not valid bash"
FAILURES=(); check_leg2_skips_poll_on_boot_refusal "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where leg2's own sentinel-refusal else branch polls the guest through ssh_vm when BOOT_REFUSED_BY==product"
echo "selftest ok (leg2 sentinel refusal, stray ssh poll): detected -- ${FAILURES[0]}"

copy="$WORK/defect-leg2-sentinel-wrapper-poll.sh"
cp "$SRC" "$copy"
inject_sentinel_wrapper_poll_leg2 "$copy" || selftest_fail "could not set up the leg2 sentinel-wrapper-poll fixture"
bash -n "$copy" || selftest_fail "leg2 sentinel-wrapper-poll copy is not valid bash"
FAILURES=(); check_leg2_skips_poll_on_boot_refusal "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where leg2's own sentinel-refusal else branch calls an unstubbed wrapper around a poll"
echo "selftest ok (leg2 sentinel refusal, wrapper poll): detected -- ${FAILURES[0]}"

copy="$WORK/defect-norow-never-reset.sh"
cp "$SRC" "$copy"
python3 - "$copy" <<'PY' || selftest_fail "could not set up the NO_ROW-never-reset fixture"
import sys
p = sys.argv[1]
s = open(p).read()
old = '  TEST_BOOT_NO_ROW=""\n  refusal=$(marker_line'
new = '  refusal=$(marker_line'
n = s.count(old)
if n != 1:
    sys.exit("pattern count %d" % n)
open(p, "w").write(s.replace(old, new, 1))
PY
bash -n "$copy" || selftest_fail "NO_ROW-never-reset copy is not valid bash"
FAILURES=(); check_gsi_no_row_and_booted_state_across_legs "$copy"
(( ${#FAILURES[@]} > 0 )) \
  || selftest_fail "the checker passed a copy where boot_and_start never resets TEST_BOOT_NO_ROW at its own top"
echo "selftest ok (TEST_BOOT_NO_ROW never reset): detected -- ${FAILURES[0]}"

run_all_checks "$SRC"
if (( ${#FAILURES[@]} > 0 )); then
  printf 'SELFTEST FAIL (clean): the real gsi-update.sh failed its own checker: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "selftest ok (clean): the real gsi-update.sh passes every assertion"
exit 0
