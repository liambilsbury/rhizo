#!/bin/bash
# test stop_payload_processes against stand-in processes
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEARDOWN="$HERE/../../src/install/teardown/teardown.sh"

# print the stop_payload_processes function text
extract() {
  sed -n '/^stop_payload_processes() {/,/^}/p' "$1"
}

# scope the stop text to the trial processes
scope_to_trial() {
  sed 's#for d in /proc/\[0-9\]\*; do#for d in "${TRIAL_PROCS[@]}"; do#' <<<"$1"
}

# run the stop against stand-in processes
trial() {
  local fn="$1" tmp primer sup lead child control pids
  tmp=$(mktemp -d)
  bash -c 'exec -a /run/rhizo-host-primer.py sleep 300' & primer=$!
  bash -c 'trap "" TERM; exec -a /usr/lib/rhizo/launcher3.py sleep 300' & sup=$!
  setsid bash -c 'sleep 300 & echo $! > "$1/child"; echo $$ > "$1/lead"; exec -a /usr/lib/rhizo/rhizo-avc-capture.sh sleep 300' _ "$tmp" &
  python3 -c 'import time; time.sleep(300)' /usr/lib/rhizo/launcher3.py & namer=$!
  sleep 300 & control=$!
  for _ in $(seq 1 50); do [[ -s "$tmp/lead" && -s "$tmp/child" ]] && break; sleep 0.1; done
  lead=$(cat "$tmp/lead" 2>/dev/null); child=$(cat "$tmp/child" 2>/dev/null)
  local want p
  for want in "$primer:/run/rhizo-host-primer.py" "$sup:/usr/lib/rhizo/launcher3.py" \
              "${lead:-0}:/usr/lib/rhizo/rhizo-avc-capture.sh"; do
    p=${want%%:*}
    for _ in $(seq 1 100); do
      [[ "$(tr '\0' '\n' 2>/dev/null < "/proc/$p/cmdline" | head -1)" == "${want#*:}" ]] && break
      sleep 0.05
    done
  done
  local -a own=("/proc/$primer" "/proc/$sup" "/proc/${lead:-0}" "/proc/${child:-0}" "/proc/$namer" "/proc/$control")
  local scoped
  scoped=$(scope_to_trial "$fn")
  if [[ "$scoped" == "$fn" ]]; then
    echo "stop_payload_processes no longer walks /proc/[0-9]*"
    kill -KILL "$primer" "$sup" "${lead:-}" "${child:-}" "$control" "$namer" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$tmp"
    return
  fi
  (
    log() { :; }
    mark_change() { :; }
    # shellcheck disable=SC2034
    TRIAL_PROCS=("${own[@]}")
    eval "$scoped"
    declare -F stop_payload_processes >/dev/null || { echo "the teardown defines no stop_payload_processes"; exit 0; }
    stop_payload_processes >/dev/null 2>&1 || echo "stop_payload_processes returned non-zero"
  )
  for pids in "primer:$primer" "supervisor-ignoring-SIGTERM:$sup" "capture-loop:${lead:-?}" "capture-child:${child:-?}"; do
    [[ -e "/proc/${pids#*:}" && "${pids#*:}" != "?" ]] && [[ "$(cat "/proc/${pids#*:}/stat" 2>/dev/null | cut -d' ' -f3)" != Z ]] \
      && echo "${pids%%:*} (pid ${pids#*:}) still runs after the stop"
  done
  [[ -e "/proc/$control" ]] || echo "an unrelated process (pid $control) was killed"
  [[ -e "/proc/$namer" ]] || echo "a process that only names a marker in its arguments (pid $namer) was killed"
  kill -KILL "$primer" "$sup" "${lead:-}" "${child:-}" "$control" "$namer" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$tmp"
}

if [[ "${1:-}" == --print-scoped ]]; then
  scope_to_trial "$(extract "$TEARDOWN")"
  exit 0
fi

if [[ "${1:-}" == --selftest ]]; then
  fn=$(extract "$TEARDOWN")
  [[ -n "$fn" ]] || { echo "FAIL selftest: no stop_payload_processes in $TEARDOWN to mutate"; exit 1; }
  broken=$(sed 's#^\(\s*local -a markers=\).*#\1(/nothing-matches-this)#' <<<"$fn")
  [[ "$broken" != "$fn" ]] || { echo "FAIL selftest: could not find the markers line to mutate"; exit 1; }
  out=$(trial "$broken")
  grep -q '^primer ' <<<"$out" && grep -q '^capture-loop ' <<<"$out" \
    || { echo "FAIL selftest: a stop that matches nothing was not flagged: $out"; exit 1; }
  termonly=$(sed 's#for sig in TERM KILL#for sig in TERM#' <<<"$fn")
  [[ "$termonly" != "$fn" ]] || { echo "FAIL selftest: could not find the signal loop to mutate"; exit 1; }
  out=$(trial "$termonly")
  grep -q '^supervisor-ignoring-SIGTERM ' <<<"$out" \
    || { echo "FAIL selftest: a TERM-only stop was not flagged for the supervisor: $out"; exit 1; }
  out=$(trial "$fn")
  [[ -z "$out" ]] || { echo "FAIL selftest: the real stop was flagged: $out"; exit 1; }
  echo "check-teardown-stops-payload selftest: 3 trials passed"
  exit 0
fi

out=$(trial "$(extract "$TEARDOWN")")
if [[ -n "$out" ]]; then
  while IFS= read -r l; do echo "FAIL: teardown stop: $l"; done <<<"$out"
  exit 1
fi
echo "teardown stops the primer, the capture loops and a SIGTERM-ignoring supervisor, and nothing else"
