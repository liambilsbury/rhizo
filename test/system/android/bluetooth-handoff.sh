#!/bin/bash
# test the devices.bluetooth handoff to Android
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: none
# test-records-metrics: no
# test-verdict-params: -
# test-requires: file:gfx_hal/rhizo-bluetooth-service
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }

POLICY_CONF=/etc/rhizo/policy.conf
BTD_SOCKET=/dev/socket/rhizo_bluetooth/btd

test_init bluetooth-handoff || exit 1

# remove the policy file from the vm
cleanup_policy_conf() {
  ssh_vm -t 10 "rm -f $POLICY_CONF" >/dev/null 2>&1
}
# shellcheck disable=SC2034
TEST_EXTRA_CLEANUP=cleanup_policy_conf

# restart Android and wait for sys.boot_completed
restart_android() {
  ssh_vm -t 300 'rhizo stop >/dev/null 2>&1; rhizo start' > "$EV/$1" 2>&1
}

# check the features, the HAL and the socket inside Android
assert_android_side() {
  local label="$1" want_socket="$2" want_declared="$3" features hal socket
  features=$(android_sh "$INIT" "pm list features" 2>&1)
  printf '%s\n' "$features" > "$EV/$label-features.txt"
  if ! grep -q "^feature:" <<<"$features"; then
    fail "$label: pm list features listed no feature (see $label-features.txt)"
  elif grep -qx "feature:android.hardware.bluetooth" <<<"$features"; then
    [[ "$want_declared" == yes ]] && pass "$label: android.hardware.bluetooth is declared" \
      || fail "$label: android.hardware.bluetooth is declared, wanted absent (see $label-features.txt)"
  else
    [[ "$want_declared" == no ]] && pass "$label: android.hardware.bluetooth is not declared" \
      || fail "$label: android.hardware.bluetooth is missing from pm list features (see $label-features.txt)"
  fi
  hal=$(android_sh "$INIT" "service check android.hardware.bluetooth.IBluetoothHci/default" 2>&1)
  printf '%s\n' "$hal" > "$EV/$label-hal.txt"
  if grep -q ": found" <<<"$hal"; then
    [[ "$want_declared" == yes ]] && pass "$label: IBluetoothHci/default is registered" \
      || fail "$label: IBluetoothHci/default is registered, wanted absent"
  elif grep -q ": not found" <<<"$hal"; then
    [[ "$want_declared" == no ]] && pass "$label: IBluetoothHci/default is not registered" \
      || fail "$label: IBluetoothHci/default is not registered: $hal"
  else
    fail "$label: service check gave no answer: $hal"
  fi
  socket=$(ssh_vm -t 10 "if [ -S /proc/$INIT/root$BTD_SOCKET ]; then echo $BTD_SOCKET; else echo 'no socket'; fi" 2>&1)
  printf '%s\n' "$socket" > "$EV/$label-socket.txt"
  if [[ "$want_socket" == yes && "$socket" == "$BTD_SOCKET" ]]; then
    pass "$label: $BTD_SOCKET is bound into Android"
  elif [[ "$want_socket" == no && "$socket" == "no socket" ]]; then
    pass "$label: $BTD_SOCKET is absent from Android"
  else
    fail "$label: $BTD_SOCKET reads '$socket', wanted present=$want_socket"
  fi
}

# check the Bluetooth stack did not abort on the HAL
assert_no_stack_abort() {
  local label="$1" since="$2" log
  log=$(android_sh "$INIT" "logcat -d -b crash,main -t '$since'" 2>&1)
  printf '%s\n' "$log" > "$EV/$label-logcat.txt"
  if [[ -z "$log" ]]; then
    fail "$label: logcat read nothing"
  elif grep -q "hci_backend_aidl" <<<"$log"; then
    fail "$label: the Bluetooth stack aborted on the HAL (see $label-logcat.txt)"
  else
    pass "$label: no Bluetooth stack abort in logcat"
  fi
}

step "0. boot with the default policy"
test_boot --skip-graphics-preflight || { test_record_verdict FAILED; exit 1; }
../../vm/sync.sh >/dev/null || { fail "0. sync.sh failed"; test_record_verdict FAILED; exit 1; }
../../vm/redeploy.sh --skip-kill --boot-wait 240 > "$EV/redeploy.log" 2>&1 \
  || { fail "0. redeploy.sh failed (see $EV/redeploy.log)"; test_record_verdict FAILED; exit 1; }
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "0. no init second_stage after the boot"; test_record_verdict FAILED; exit 1; }
controller=$(ssh_vm -t 10 "ls /sys/class/bluetooth 2>/dev/null | grep -c '^hci'" 2>&1)
controller=${controller//[^0-9]/}
[[ -n "$controller" ]] || { fail "0. could not read /sys/class/bluetooth on the guest"; test_record_verdict FAILED; exit 1; }
if (( controller > 0 )); then HAS_CONTROLLER=yes; else HAS_CONTROLLER=no; fi
log "    host controllers: $controller (Android declares Bluetooth: $HAS_CONTROLLER)"
echo "$controller" > "$EV/host-controllers.txt"

step "1. devices.bluetooth on: rhizo-btd runs and its socket reaches Android"
btd=$(ssh_vm -t 10 "systemctl is-active rhizo-btd.service" 2>&1)
if [[ "$btd" == active ]]; then
  pass "1. rhizo-btd.service is active"
else
  fail "1. rhizo-btd.service is '$btd'"
fi
assert_android_side 1 yes "$HAS_CONTROLLER"
assert_no_stack_abort 1 "$(ssh_vm -t 10 'date -d "-$(cut -d. -f1 /proc/uptime) sec" +"%m-%d %H:%M:%S.000"' 2>/dev/null)"

step "2. devices.bluetooth off: no rhizo-btd, no socket, no adapter"
ssh_vm -t 20 "printf '[devices]\nbluetooth = no\n' > $POLICY_CONF && systemctl stop rhizo-btd.service"
restart_android restart-off.log || fail "2. restarting Android failed, see restart-off.log"
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "2. no init second_stage after the restart"; test_record_verdict FAILED; exit 1; }
btd=$(ssh_vm -t 10 "systemctl is-active rhizo-btd.service" 2>&1)
if [[ "$btd" != active ]]; then
  pass "2. rhizo-btd.service is '$btd'"
else
  fail "2. rhizo-btd.service is active under devices.bluetooth = no"
fi
assert_android_side 2 no no

if (( FAILED )); then
  test_record_verdict FAILED
  log "test-bluetooth-handoff: FAILED"
  exit 1
fi
test_record_verdict PASSED
log "test-bluetooth-handoff: PASSED -- evidence in $EV"
exit 0
