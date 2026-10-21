#!/bin/bash
# check release loop ceilings against recorded boot needs
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MAP="$REPO/test/vm/image/release-map.sh"
[[ "${1:-}" == "--map" ]] && { MAP="$2"; shift 2; }
[[ "${2:-}" == "--map" ]] && { MAP="$3"; }

declare -A LOOP_NEED=(
  [a16]="45 2"
  [a17]="48 2"
  [a15]="42 2"
)
HEADROOM_MAX=8
RC=0
fail() { echo "check-loop-max: $*" >&2; RC=1; }

# shellcheck source=/dev/null
source "$MAP" || { echo "check-loop-max: cannot read $MAP" >&2; exit 1; }

for rel in "${RELEASE_LABELS[@]}"; do
  ceiling="${LOOP_MAX_LOOP[$rel]:-}"
  [[ -n "$ceiling" ]] || { fail "$rel has no LOOP_MAX_LOOP entry"; continue; }
  read -r need inuse <<<"${LOOP_NEED[$rel]:-}"
  [[ -n "$need" && -n "$inuse" ]] || { fail "$rel has no recorded LOOP_NEED entry"; continue; }
  required=$(( need + inuse ))
  if (( ceiling < required )); then
    fail "$rel ceiling $ceiling is below the $required its own boot needs (${need} apexd + ${inuse} attached)"
  elif (( ceiling > required + HEADROOM_MAX )); then
    fail "$rel ceiling $ceiling is $((ceiling - required)) above the $required it needs"
  fi
done

[[ "$(RHIZO_LOOP_PER_RELEASE='' loop_max_loop a16)" == "$LOOP_MAX_LOOP_DEFAULT" ]] \
  || fail "loop_max_loop returns a per-release ceiling with the knob off"
[[ "$(RHIZO_LOOP_PER_RELEASE=1 loop_max_loop a16)" == "${LOOP_MAX_LOOP[a16]}" ]] \
  || fail "loop_max_loop ignores RHIZO_LOOP_PER_RELEASE=1"
[[ "$(RHIZO_LOOP_PER_RELEASE=1 loop_max_loop nosuch)" == "$LOOP_MAX_LOOP_DEFAULT" ]] \
  || fail "an unknown release does not fall back to the default ceiling"
grep -q 'loop.max_loop=${RHIZO_LOOP_MAX_LOOP:-64}' "$REPO/test/vm/run-vm.sh" \
  || fail "run-vm.sh's cmdline no longer reads RHIZO_LOOP_MAX_LOOP"
grep -q 'LOOP_TOKENS="loop.max_loop=${RHIZO_LOOP_MAX_LOOP:-64}"' "$REPO/src/install/bootstrap/bootstrap.sh" \
  || fail "the installer's cmdline no longer reads RHIZO_LOOP_MAX_LOOP"
grep -q 'RHIZO_LOOP_MAX_LOOP="$(loop_max_loop "$LABEL")"; export RHIZO_LOOP_MAX_LOOP' "$REPO/test/vm/boot-release.sh" \
  || fail "boot-release.sh no longer resolves the ceiling from release-map.sh"

if [[ "${1:-}" == "--selftest" ]]; then
  (( RC == 0 )) || { echo "check-loop-max --selftest: the real map already fails" >&2; exit 1; }
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
  sed 's/\[a17\]=54/[a17]=49/' "$MAP" > "$T/release-map.sh"
  if "$HERE/install/setup/loop-max.sh" --map "$T/release-map.sh" >/dev/null 2>&1; then
    echo "check-loop-max --selftest: a ceiling below the recorded need passed" >&2
    exit 1
  fi
  sed 's/\[a15\]=48/[a15]=64/' "$MAP" > "$T/release-map.sh"
  if "$HERE/install/setup/loop-max.sh" --map "$T/release-map.sh" >/dev/null 2>&1; then
    echo "check-loop-max --selftest: a ceiling with no lever in it passed" >&2
    exit 1
  fi
  echo "check-loop-max: selftest ok"
  exit 0
fi
(( RC == 0 )) && echo "check-loop-max: every release's ceiling covers its own boot"
exit $RC
