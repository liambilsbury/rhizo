#!/bin/bash
# test wait_for_nonempty on a slow probe
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

source ../vm/common.sh

if (( SELFTEST )); then
  wait_for_nonempty() { shift; "$@" 2>/dev/null; }
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
bad=0

echo 0 > "$WORK/flaky_calls"
# count a probe call and print READY from the third call on
flaky_probe() {
  local n; n=$(( $(< "$WORK/flaky_calls") + 1 ))
  echo "$n" > "$WORK/flaky_calls"
  (( n >= 3 )) && echo READY
}
out=$(wait_for_nonempty 10 flaky_probe); rc=$?
if (( rc != 0 )) || [[ "$out" != READY ]]; then
  echo "check-net-wait: a condition appearing on poll 3 was never picked up (rc=$rc, out='$out')"
  bad=1
fi

never_probe() { return 1; }
start=$(date +%s)
wait_for_nonempty 2 never_probe >/dev/null 2>&1
rc=$?
waited=$(( $(date +%s) - start ))
if (( rc == 0 )); then
  echo "check-net-wait: a probe that never went ready still returned success"
  bad=1
elif (( waited < 2 || waited > 6 )); then
  echo "check-net-wait: gave up after ${waited}s against a 2s bound"
  bad=1
fi

ready_probe() { echo READY; }
start=$(date +%s)
out=$(wait_for_nonempty 10 ready_probe); rc=$?
waited=$(( $(date +%s) - start ))
if (( rc != 0 )) || [[ "$out" != READY ]] || (( waited > 1 )); then
  echo "check-net-wait: a probe ready on the first look took ${waited}s / rc=$rc to return"
  bad=1
fi

if (( SELFTEST )); then
  (( bad )) && { echo "check-net-wait --selftest: a single-shot probe was caught"; exit 0; }
  echo "check-net-wait --selftest: a single-shot probe passed the assertions"
  exit 1
fi

grep -q 'wait_for_nonempty .*sandbox_eth0_ip' ../vm/boot/adb-tunnel.sh \
  || { echo "check-net-wait: adb-tunnel.sh no longer waits on sandbox_eth0_ip through wait_for_nonempty"; bad=1; }
grep -q 'FAIL: sandbox eth0 has no DHCP-leased address yet' ../vm/boot/adb-tunnel.sh \
  || { echo "check-net-wait: adb-tunnel.sh's original DHCP-lease failure message is gone"; bad=1; }
grep -q 'wait_for_nonempty .*veth_addr_ready' ../vm/start/start-netserv.sh \
  || { echo "check-net-wait: start-netserv.sh no longer waits on the veth address through wait_for_nonempty"; bad=1; }

(( bad )) && exit 1
echo "check-net-wait: wait_for_nonempty polls a slow condition, respects its bound, and both call sites still fail by name"
exit 0
