#!/bin/bash
# check the window-input click read
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
test=${1:-../system/desktop/window-input.sh}
rc=0
fns=$(awk '/^field\(\) \{/ {print; next} /^wait_app_field\(\) \{/ {on=1} on {print} on && /^\}/ {on=0}' "$test")
if [[ "$fns" != *"wait_app_field()"* || "$fns" != *"field()"* ]]; then
  echo "FAIL: $test defines no field()/wait_app_field() to run"
  exit 1
fi

assign=$(grep -o 'ptr=$(wait_app_field RHIZO_POINTER "$click_nonce" via touch [0-9]*) || ptr=""' "$test" | head -1)

# read the click report from logcat text
run_read() {
  LOGCAT="$1" INIT=1 bash -c "
    android_sh() { printf '%s\n' \"\$LOGCAT\"; }
    sleep() { :; }
    $fns
    click_nonce=n1
    $assign
    echo \"ptr=\$ptr\"
  "
}

HOVERS='RhizoWinApp: RHIZO_POINTER nonce=n1 via=generic action=7 actionName=ACTION_HOVER_MOVE x=636.75 y=-325.75 rawX=636.75 rawY=56.25 source=8194
RhizoWinApp: RHIZO_POINTER nonce=n1 via=generic action=10 actionName=ACTION_HOVER_EXIT x=636.75 y=-325.75 rawX=636.75 rawY=56.25 source=8194'
TOUCH='RhizoWinApp: RHIZO_POINTER nonce=n1 via=touch action=0 actionName=ACTION_DOWN x=320.33 y=169.3 rawX=320.33 rawY=360.3 source=4098
RhizoWinApp: RHIZO_POINTER nonce=n1 via=touch action=1 actionName=ACTION_UP x=320.33 y=169.3 rawX=320.33 rawY=360.3 source=4098'

if [[ -z "$assign" ]]; then
  echo "FAIL: step 6 does not read its click as ptr=\$(wait_app_field RHIZO_POINTER \"\$click_nonce\" via touch N) || ptr=\"\""
  rc=1
else
  got=$(run_read "$HOVERS
$TOUCH")
  if [[ "$got" == "ptr=RHIZO_POINTER nonce=n1 via=touch action=0 "* ]]; then
    echo "ok   the park's hovers then the touch: the read returns the touch's press"
  else
    echo "FAIL: the park's hovers then the touch returned: $got"; rc=1
  fi
  got=$(run_read "$HOVERS")
  if [[ "$got" == "ptr=" ]]; then
    echo "ok   the park's hovers alone: ptr is empty instead of holding a hover for the click"
  else
    echo "FAIL: hovers alone returned: $got"; rc=1
  fi
fi

step6=$(awk '/^step "6\./ {on=1} /^step "7\./ {on=0} on' "$test")
if grep -q 'grep -a -o "RHIZO_POINTER \.\*" | tail -1' <<<"$step6"; then
  echo "FAIL: step 6 still falls back to the newest RHIZO_POINTER of any nonce"
  rc=1
else
  echo "ok   step 6 has no any-nonce newest-pointer fallback"
fi
exit $rc
