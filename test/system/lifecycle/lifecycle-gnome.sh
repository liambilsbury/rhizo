#!/bin/bash
# test the gnome profile lifecycle cycle
# RHIZO_LIFECYCLE_KEEP_VM=1 leaves the guest up at the end and prints how to resume it
# RHIZO_LIFECYCLE_FROM_STEP=<id> resumes the cycle at that step on the guest a kept run left up
# RHIZO_LIFECYCLE_TO_STEP=<id> stops after that step; all of the later claims read not_run
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-verdict-params: -
# test-requires: deb:rhizo deb:rhizo-kernel prev-debs:rhizo vm-dir:sway-debs vm-dir:gnome-debs vm-dir:runtime-debs pool-checked:runtime-debs vm-dir:pipewire-debs vm-dir:ubuntu-update-debs vm-dir:probe-debs gsi:gsi_a16.zip gsi:gsi_a15.zip
set -uo pipefail

PROFILE=gnome

export RHIZO_BOOT=grub RHIZO_DESKTOP_PROFILE="$PROFILE"
source "$(dirname "${BASH_SOURCE[0]}")/../cycle/entry.sh"
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
lifecycle_entry_start
if lifecycle_keep_vm; then
  test_init "lifecycle-$PROFILE"
else
  test_init "lifecycle-$PROFILE" --teardown
fi
lifecycle_entry_cycle
if lifecycle_entry_clean; then
  test_record_verdict PASSED "-" "${CYCLE_ID:+cycle_id=$CYCLE_ID}"
  lifecycle_entry_end 0
fi
test_record_verdict FAILED "-" "${CYCLE_ID:+cycle_id=$CYCLE_ID }verdict=${cycle_verdict:-unknown} FAILED=$FAILED"
lifecycle_entry_end 1
