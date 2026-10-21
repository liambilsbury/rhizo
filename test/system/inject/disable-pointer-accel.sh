#!/bin/bash
# turn off mouse pointer acceleration in the sandbox
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ../../vm/common.sh

INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { log "FAIL: no init second_stage running"; exit 1; }

inputdump=$(android_sh "$INIT" "dumpsys input" 2>/dev/null)
if grep -q "Display with Mouse Pointer Acceleration Disabled:" <<<"$inputdump"; then
  log "pointer acceleration NOT turned off: this release (A15) has no mouse_pointer_acceleration_enabled setting"
  exit 0
fi
grep -q "Display with Mouse Scaling Disabled:" <<<"$inputdump" \
  || { log "FAIL: dumpsys input named neither exemption set"; exit 1; }

android_sh "$INIT" "settings put system mouse_pointer_acceleration_enabled 0" >/dev/null 2>&1

got=$(android_sh "$INIT" "settings get system mouse_pointer_acceleration_enabled" 2>/dev/null | tr -d '\r')
if [[ "$got" != "0" ]]; then
  log "FAIL: mouse_pointer_acceleration_enabled reads '$got', not 0"
  exit 1
fi
log "pointer acceleration off (mouse_pointer_acceleration_enabled=$got)"
