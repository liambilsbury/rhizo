#!/bin/bash
# test the scope of teardown-stops-payload.sh's stop
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FX=$(mktemp -d) || exit 1
pids=()
cleanup() { kill -KILL "${pids[@]}" 2>/dev/null; rm -rf "$FX"; }
trap cleanup EXIT
bad=""
scoped=$("$HERE/install/teardown/teardown-stops-payload.sh" --print-scoped) || bad+=" --print-scoped failed;"
[[ "$scoped" == *'for d in "${TRIAL_PROCS[@]}"; do'* ]] || bad+=" the scoped stop does not walk TRIAL_PROCS;"
[[ "$scoped" != *'/proc/[0-9]*'* ]] || bad+=" the scoped stop still walks every /proc entry;"
for _ in 1 2; do
  bash -c 'exec -a /usr/lib/rhizo/launcher3.py sleep 300' & pids+=($!)
  disown $!
done
own=${pids[0]} other=${pids[1]}
for p in "$own" "$other"; do
  for _ in $(seq 1 100); do
    [[ "$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | head -1)" == /usr/lib/rhizo/launcher3.py ]] && break
    sleep 0.05
  done
done
(
  log() { :; }
  mark_change() { :; }
  kill() { printf '%s\n' "$*" >> "$FX/signaled"; }
  sleep() { :; }
  # shellcheck disable=SC2034
  TRIAL_PROCS=("/proc/$own")
  eval "$scoped"
  stop_payload_processes >/dev/null 2>&1
)
grep -qw -- "$other" "$FX/signaled" 2>/dev/null \
  && bad+=" the scoped stop signaled pid $other, which its list never named: $(tr '\n' '|' < "$FX/signaled");"
if [[ -n "$bad" ]]; then
  echo "check-teardown-check-scope: FAIL:$bad"
  exit 1
fi
echo "check-teardown-check-scope: the teardown check's stop signals only the processes its trial hands it"
