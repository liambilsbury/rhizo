#!/bin/bash
# test release.sh reads the abi.sh report
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${BUILD_RELEASE_OVERRIDE:-$HERE/../../tools/build/release.sh}"
fail() { echo "check-build-release: $*" >&2; exit 1; }

[[ -r "$DRIVER" ]] || fail "cannot read $DRIVER"

if [[ "${1:-}" != "--selftest" ]]; then
  bash -n "$DRIVER" || fail "release.sh does not parse"

  grep -qF "grep '\[UNWAIVED'" "$DRIVER" \
    || fail "no longer reads abi.sh's own [UNWAIVED] annotation"
  if grep -qE 'gfx_hal.*: _Z\|: needs' "$DRIVER"; then
    fail "the old gfx_hal-prefixed regex is back"
  fi

  grep -qF 'rc=$?' "$DRIVER" \
    || fail "no longer captures abi.sh's own exit code"
  grep -qF 'abi_report_unwaived "$rc"' "$DRIVER" \
    || fail "captured rc but never passes it to the read of abi.sh's report"

  grep -qF "grep -q '^FAIL:'" "$DRIVER" \
    || fail "no longer refuses a abi.sh run that FAILed outright before it could report"

  grep -qF 'abi_unwaived_test "$rel" "$unwaived" "$ALLOW_UNWAIVED"' "$DRIVER" \
    || fail "abi_report_unwaived's output no longer reaches abi_unwaived_test"

  echo "check-build-release: wiring intact"
  exit 0
fi

# shellcheck source=../../tools/build/release.sh
source "$DRIVER"

assertions=0
# check abi_report_unwaived against a fixture log
check_one() {
  local label="$1" rc="$2" fixture="$3" want="$4" want_sub="${5:-}"
  local logf; logf=$(mktemp)
  printf '%s' "$fixture" > "$logf"
  local out; out=$(abi_report_unwaived "$rc" "$logf"); local got_rc=$?
  rm -f "$logf"
  assertions=$((assertions + 1))
  if [[ "$want" == "REFUSE" ]]; then
    (( got_rc != 0 )) || fail "$label: expected a hard refusal (rc!=0), got rc=0 output='$out'"
  else
    (( got_rc == 0 )) || fail "$label: expected rc=0, got rc=$got_rc output='$out'"
  fi
  [[ -z "$want_sub" || "$out" == *"$want_sub"* ]] \
    || fail "$label: expected output to contain '$want_sub', got '$out'"
}

check_one "non-gfx_hal unwaived gap is reported" 1 \
  $'SYMBOLS EXPORTED BY A16 BUT NOT BY A17 (1):\n  rhizo-keymint-service: _ZN3android19somethingSomethingE  [UNWAIVED]\n\nNOT CLEAN -- 1 unwaived gap(s) above are real load failures' \
  0 "rhizo-keymint-service"

check_one "a gfx_hal unwaived gap is still reported (no regression on the old case)" 1 \
  $'SYMBOLS EXPORTED BY A16 BUT NOT BY A17 (1):\n  gfx_hal/libgralloc.so: _ZN3fooE  [UNWAIVED]\n\nNOT CLEAN -- 1 unwaived gap(s) above are real load failures' \
  0 "gfx_hal/libgralloc.so"

check_one "every gap waived reports empty (rc=1 alone names nothing)" 1 \
  $'SYMBOLS EXPORTED BY A16 BUT NOT BY A17 (1):\n  gfx_hal/libkeymint.so: _ZN7cppcoseE  [WAIVED: boot evidence]\n\nNOT CLEAN by symbol count, but every one of the 1 gap(s) above is WAIVED' \
  0 ""

check_one "rc=0 clean report" 0 \
  'CLEAN: a17 exports everything a16 does that our binaries import,' \
  0 ""

check_one "abi.sh FAILed outright (mount failure) refuses even with zero UNWAIVED lines" 1 \
  'FAIL: cannot mount /srv/rhizo/gsi_system.img' \
  REFUSE "FAIL:"

echo "check-build-release selftest: $assertions assertions passed"
