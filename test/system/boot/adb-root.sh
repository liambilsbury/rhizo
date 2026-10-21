#!/bin/bash
# test adb root and unroot cycles
# test-boot-mode: shared
# test-boots-unit: na
# test-records-metrics: no
# test-requires: none
# test-verdict-params: cycles=3
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh

[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
ADB="$HOME/Android/Sdk/platform-tools/adb"
SERIAL="127.0.0.1:$ADB_PORT"
CYCLES=3
EXPECT_ROOT=1
EXPECT_ROOT_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cycles) CYCLES="$2"; shift 2 ;;
    --expect-root) EXPECT_ROOT=1; EXPECT_ROOT_SET=1; shift ;;
    --expect-no-root) EXPECT_ROOT=0; EXPECT_ROOT_SET=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
VERDICT_REDUCTION=""
if (( EXPECT_ROOT_SET )); then VERDICT_REDUCTION=" expect_root=$EXPECT_ROOT"; fi

test_init adb-root

# print the uid of the adb shell
adb_uid() { "$ADB" -s "$SERIAL" shell id -u 2>/dev/null | tr -d '\r\n'; }
# print the selinux context of the adb shell
adb_ctx() { "$ADB" -s "$SERIAL" shell id -Z 2>/dev/null | tr -d '\r\n'; }

# poll adb for the uid
wait_for_uid() {
  local want="$1" deadline=$(( SECONDS + $2 )) got=""
  while (( SECONDS < deadline )); do
    got=$(adb_uid)
    [[ "$got" == "$want" ]] && { echo "$got"; return 0; }
    ../../vm/boot/adb-tunnel.sh up >/dev/null 2>&1
    sleep 1
  done
  echo "$got"; return 1
}

step "adb bridge"
../../vm/boot/adb-tunnel.sh up > "$EV/adb-tunnel.log" 2>&1 || { fail "adb-tunnel.sh up failed -- see $EV/adb-tunnel.log"; exit 1; }
state=$("$ADB" devices | awk -v want="$SERIAL" '$1==want{print $2}')
[[ "$state" == "device" ]] || { fail "adb state is '$state', not 'device'"; exit 1; }
pass "adb connected: $SERIAL state=device"

if (( ! EXPECT_ROOT_SET )); then
  debuggable=$("$ADB" -s "$SERIAL" shell getprop ro.debuggable 2>/dev/null | tr -d '\r\n ')
  case "$debuggable" in
    1) EXPECT_ROOT=1; pass "guest reports ro.debuggable=1: expecting adb root to reach uid=0" ;;
    0) EXPECT_ROOT=0; pass "guest reports ro.debuggable=0: expecting adb root to be refused" ;;
    *) fail "guest did not answer getprop ro.debuggable (got '${debuggable:-<none>}'); pass --expect-root or --expect-no-root"; exit 1 ;;
  esac
fi

start_uid=$(adb_uid)
if [[ "$start_uid" == "2000" ]]; then
  pass "starting unrooted (uid=2000, AID_SHELL)"
else
  log "  NOTE: device already at uid=$start_uid before any adb root"
fi

step "$CYCLES root/unroot cycles"
for (( c = 1; c <= CYCLES; c++ )); do
  "$ADB" -s "$SERIAL" root > "$EV/adb-root-$c.log" 2>&1
  uid=$(wait_for_uid 0 60)
  if [[ "$uid" != "0" ]]; then
    if (( EXPECT_ROOT )); then
      fail "cycle $c: adb root did not reach uid=0 (got '${uid:-<none>}') -- $(cat "$EV/adb-root-$c.log" 2>/dev/null | head -1)"
    else
      pass "cycle $c: adb root refused, as expected for this variant ($(head -1 "$EV/adb-root-$c.log" 2>/dev/null))"
    fi
    break
  fi
  pass "cycle $c: uid=0"

  if (( c == 1 )); then
    "$ADB" -s "$SERIAL" shell cat /proc/self/status 2>/dev/null \
      | grep -E '^(Cap|Uid|Gid)' > "$EV/root-caps.txt"
    ctx=$(adb_ctx)
    echo "$ctx" > "$EV/root-context.txt"
    log "  root context: ${ctx:-<unavailable>}"
    log "  capabilities recorded -> $EV/root-caps.txt"
    if [[ "$ctx" == *":su:"* ]]; then
      pass "rooted shell is in the su domain, via adbd's own --root_seclabel"
    else
      log "  NOTE: rooted shell context is '${ctx:-<unavailable>}', not u:r:su:s0"
    fi
  fi

  "$ADB" -s "$SERIAL" unroot > "$EV/adb-unroot-$c.log" 2>&1
  uid=$(wait_for_uid 2000 60)
  if [[ "$uid" == "2000" ]]; then
    pass "cycle $c: unrooted back to uid=2000"
  else
    fail "cycle $c: unroot did not reach uid=2000 (got '${uid:-<none>}')"
    break
  fi
done

if (( EXPECT_ROOT )); then
  (( FAILED )) || log "ADB ROOT SYSTEM TEST PASSED -- $CYCLES clean root/unroot cycles, evidence in $EV"
else
  (( FAILED )) || log "ADB ROOT SYSTEM TEST PASSED (--expect-no-root) -- root correctly refused, evidence in $EV"
fi
(( FAILED )) && { test_record_verdict FAILED "cycles=$CYCLES$VERDICT_REDUCTION"; log "ADB ROOT SYSTEM TEST FAILED"; exit 1; }
test_record_verdict PASSED "cycles=$CYCLES$VERDICT_REDUCTION"
exit 0
