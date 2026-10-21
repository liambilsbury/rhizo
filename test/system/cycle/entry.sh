#!/bin/bash
# set up and run the lifecycle cycle the four lifecycle tests share
# shellcheck disable=SC2034
_LIFECYCLE_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIFECYCLE_ENTRY_DIR/../../vm/common.sh"
source "$_LIFECYCLE_ENTRY_DIR/../lib/lib.sh"
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[1]}"; exit $?; }
source "$_LIFECYCLE_ENTRY_DIR/../lib/desktop-lib.sh"
source "$_LIFECYCLE_ENTRY_DIR/../lib/installer-lib.sh"
INSTALLER_SELINUX_MODE=host
source "$_LIFECYCLE_ENTRY_DIR/../lib/install-lib.sh"
source "$_LIFECYCLE_ENTRY_DIR/../lib/desktop-assert-lib.sh"
source "$_LIFECYCLE_ENTRY_DIR/../lib/server-assert-lib.sh"
source "$_LIFECYCLE_ENTRY_DIR/../lib/gsi-update-lib.sh"
if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then
  source "$_LIFECYCLE_ENTRY_DIR/cachyos-update-leg.sh"
  source "$_LIFECYCLE_ENTRY_DIR/cycle.sh"
  source "$_LIFECYCLE_ENTRY_DIR/cachyos.sh"
else
  source "$_LIFECYCLE_ENTRY_DIR/ubuntu-update-leg.sh"
  source "$_LIFECYCLE_ENTRY_DIR/cycle.sh"
fi

# refuse a bad knob and start the cycle
lifecycle_entry_start() {
  if ! _lc_refusal=$(lifecycle_knob_refusal); then
    echo "test-lifecycle-$PROFILE.sh: $_lc_refusal -- refusing" >&2
    exit 2
  fi
  rig_cycle_started "$PROFILE" || exit 2
}

# run and finish the cycle for PROFILE
lifecycle_entry_cycle() {
  printf 'claim_id\tresult\n' > "$EV/claims.tsv"
  : > "$EV/claims-detail.tsv"
  TEST_FAIL_FAST_SAFE=1
  LIFECYCLE_PROFILE="$PROFILE"
  LIFECYCLE_STARTED=$(date +%s)

  lifecycle_run_cycle "$PROFILE"
  lifecycle_finish_cycle "$PROFILE" "$CYCLE_ID" "$LIFECYCLE_STARTED"
}

# read this cycle's verdict into cycle_verdict
lifecycle_entry_clean() {
  cycle_verdict=$(rig_cycle_verdict "$PROFILE" "$CYCLE_ID") || cycle_verdict=$(lifecycle_claims_verdict "$PROFILE")
  [[ "$cycle_verdict" == CLEAN ]] && (( FAILED == 0 ))
}

# print how to resume a kept vm and exit
lifecycle_entry_end() {
  if lifecycle_keep_vm; then
    lifecycle_print_resume "$PROFILE"
  fi
  exit "$1"
}
