#!/bin/bash
# test wait_for_ssh with an exited pid
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$HERE" || exit

export RHIZO_VM=97
source ../vm/common.sh
mkdir -p "$VAR_DIR"

( : ) & DEADPID=$!
wait "$DEADPID" 2>/dev/null
echo "$DEADPID" > "$VM_PIDFILE"
trap 'rm -f "$VM_PIDFILE"' EXIT

t0=$(date +%s)
wait_for_ssh 60 >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - t0 ))

if (( rc == 0 )); then
  echo "FAIL: wait_for_ssh returned success against a dead VM_PIDFILE pid" >&2
  exit 1
fi
if (( elapsed > 15 )); then
  echo "FAIL: wait_for_ssh took ${elapsed}s against a dead pid instead of failing within one poll" >&2
  exit 1
fi
echo "wait_for_ssh fast-fails on a refused boot in ${elapsed}s instead of waiting out the deadline"
