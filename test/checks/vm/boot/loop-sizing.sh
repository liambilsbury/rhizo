#!/bin/bash
# check the multi-instance loop sizing in release-map.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MAP="$REPO/test/vm/image/release-map.sh"
APEXD_LOOP="$REPO/aosp-android16-qpr2/system/apex/apexd/apexd_loop.cpp"
RC=0
# print a failure message to stderr and mark the check failed
fail() { echo "check-loop-sizing: $*" >&2; RC=1; }

# shellcheck source=/dev/null
source "$MAP" || { echo "check-loop-sizing: cannot read $MAP" >&2; exit 1; }

# check the apexd loop source the sizing rests on
check_premise() {
  [[ -f "$APEXD_LOOP" ]] || { fail "$APEXD_LOOP not found"; return; }
  grep -q "create the device node in userspace" "$APEXD_LOOP" \
    || fail "$APEXD_LOOP no longer names the ueventd dependency this sizing rests on"
  grep -q "LOOP_CTL_GET_FREE" "$APEXD_LOOP" \
    || fail "$APEXD_LOOP no longer uses LOOP_CTL_GET_FREE"
  grep -q "LOOP_CTL_ADD" "$APEXD_LOOP" \
    || fail "$APEXD_LOOP no longer uses LOOP_CTL_ADD"
}

# check three instances need three times the loops of one
check_sum_not_shared() {
  local one three
  one=$(loop_max_loop_for_instances a16 1)
  three=$(loop_max_loop_for_instances a16 3)
  if (( three != one * 3 )); then
    fail "loop_max_loop_for_instances(a16, 3)=$three, want exactly 3x loop_max_loop_for_instances(a16, 1)=$one"
  fi
}

# check the loop ceiling for two a17 instances
check_known_values() {
  local got want=148
  (( ${LOOP_MAX_LOOP[a17]} == 54 && LOOP_HEADROOM_PER_INSTANCE == 20 )) \
    || fail "check_known_values' own hand-computed 148 assumes LOOP_MAX_LOOP[a17]=54 and LOOP_HEADROOM_PER_INSTANCE=20, which release-map.sh no longer has -- update this literal"
  got=$(loop_max_loop_for_instances a17 2)
  [[ "$got" == "$want" ]] || fail "loop_max_loop_for_instances(a17, 2)=$got, want $want"
}

# check the loop ceiling for an unknown release
check_unknown_release_falls_back_to_default() {
  local got want=168
  (( LOOP_MAX_LOOP_DEFAULT == 64 && LOOP_HEADROOM_PER_INSTANCE == 20 )) \
    || fail "check_unknown_release_falls_back_to_default's own hand-computed 168 assumes LOOP_MAX_LOOP_DEFAULT=64 and LOOP_HEADROOM_PER_INSTANCE=20 -- update this literal"
  got=$(loop_max_loop_for_instances nope 2)
  [[ "$got" == "$want" ]] || fail "loop_max_loop_for_instances(nope, 2)=$got, want the default-based $want"
}

# run all of the loop sizing checks
check() {
  check_premise
  check_sum_not_shared
  check_known_values
  check_unknown_release_falls_back_to_default
}

# check loop_budget_ok and check_premise on fixtures
selftest() {
  local n=0 tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  echo 213 > "$tmp/max_loop_ok"
  if ! loop_budget_ok a16 2 "$tmp/max_loop_ok" >/dev/null; then
    echo "check-loop-sizing --selftest: loop_budget_ok wrongly refused a ceiling that covers the need" >&2
    return 1
  fi
  n=$((n+1))

  echo 8 > "$tmp/max_loop_low"
  if loop_budget_ok a16 2 "$tmp/max_loop_low" >/dev/null; then
    echo "check-loop-sizing --selftest: loop_budget_ok wrongly accepted a ceiling below the need" >&2
    return 1
  fi
  n=$((n+1))

  if loop_budget_ok a16 0 "$tmp/does-not-exist" >/dev/null; then
    echo "check-loop-sizing --selftest: loop_budget_ok wrongly accepted an unreadable ceiling" >&2
    return 1
  fi
  n=$((n+1))

  RC=0
  check
  if (( RC != 0 )); then
    echo "check-loop-sizing --selftest: the live tree must pass check()" >&2
    return 1
  fi
  n=$((n+1))

  local fake_apexd="$tmp/apexd_loop.cpp"
  echo "// no ueventd dependency here, no LOOP_CTL_GET_FREE, no LOOP_CTL_ADD" > "$fake_apexd"
  APEXD_LOOP="$fake_apexd" RC=0
  check_premise
  if (( RC == 0 )); then
    echo "check-loop-sizing --selftest: check_premise did not fail against a mutated apexd_loop.cpp" >&2
    return 1
  fi
  n=$((n+1))
  APEXD_LOOP="$REPO/aosp-android16-qpr2/system/apex/apexd/apexd_loop.cpp"

  echo "check-loop-sizing --selftest: $n assertions passed"
}

if [[ "${1:-}" == "--selftest" ]]; then
  selftest
  exit $?
fi

check
if (( RC == 0 )); then
  echo "check-loop-sizing: N-instance loop sizing sums correctly and its AOSP premise still holds"
fi
exit $RC
