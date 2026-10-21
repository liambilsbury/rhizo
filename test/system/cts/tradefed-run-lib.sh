#!/bin/bash
# run a tradefed module under a time budget and reset adb after a stop

# run a command under a time budget
tradefed_run() {
  local budget=$1 dir=$2 pgid rc t0=$SECONDS t1 kill_after=${RHIZO_TRADEFED_KILL_AFTER:-30}
  shift 2
  (cd "$dir" && exec timeout -k "$kill_after" "$budget" "$@" > console.log 2>&1) &
  pgid=$!
  wait "$pgid"
  rc=$?
  (( rc == 137 && SECONDS - t0 >= budget )) && rc=124
  if (( rc == 124 )); then
    t1=$SECONDS
    while kill -0 -- "-$pgid" 2>/dev/null; do
      (( SECONDS - t1 < kill_after )) || { kill -KILL -- "-$pgid"; break; }
      sleep 1
    done
  fi
  return "$rc"
}

# print the last test count reported
tradefed_progress() {
  local last
  last=$(sed -n 's/.*ModuleListener: \[\([0-9]*\)\/\([0-9]*\)\].*/\1 of \2 tests/p' "$1" | tail -1)
  echo "${last:-no tests}"
}

# reset adb and wait for sys.boot_completed
tradefed_adb_recover() {
  local serial=$1 out boot
  out=$(timeout 30 adb kill-server 2>&1) || { echo "adb kill-server failed with $?: ${out:-no output}" >&2; return 1; }
  out=$(timeout 30 adb connect "$serial" 2>&1)
  [[ "$out" == *"connected to $serial"* ]] || { echo "adb connect $serial said: ${out:-nothing}" >&2; return 1; }
  timeout 120 adb -s "$serial" wait-for-device || { echo "no adb device at $serial after 120 s" >&2; return 1; }
  # shellcheck disable=SC2016
  timeout 300 adb -s "$serial" shell 'until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 1; done' \
    || { echo "$serial did not read sys.boot_completed=1 in 300 s" >&2; return 1; }
  boot=$(timeout 30 adb -s "$serial" shell getprop sys.boot_completed | tr -d '\r')
  [[ "$boot" == 1 ]] || { echo "$serial reads sys.boot_completed='$boot'" >&2; return 1; }
  echo "adb was reset and $serial reads sys.boot_completed=1" >&2
}
