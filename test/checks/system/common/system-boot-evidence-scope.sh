#!/bin/bash
# test RHIZO_BOOT_EVIDENCE_DIR scoping in test_boot
# shellcheck disable=SC2034
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$HERE/../system/lib/lib.sh"
[[ -r "$SRC" ]] || { echo "FAIL: cannot read $SRC"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# print the body of test_boot
extract_test_boot() {
  local f="$1" start end
  start=$(grep -n '^test_boot() {' "$f" | head -1 | cut -d: -f1)
  [[ -n "$start" ]] || return 1
  end=$(awk -v s="$start" 'NR > s && /^}/ { print NR; exit }' "$f")
  [[ -n "$end" ]] || return 1
  sed -n "${start},${end}p" "$f"
}

FAILURES=()
fail() { FAILURES+=("$1"); }

# run test_boot and print RHIZO_BOOT_EVIDENCE_DIR
run_test_boot() {
  local f="$1" ev="$2" out="$3" body
  body="$(extract_test_boot "$f")" || { echo "MISSING test_boot() in $f" > "$out"; return 1; }
  (
    set -uo pipefail
    test_require_staged() { return 0; }
    wait_for_ssh() { return 0; }
    log() { :; }
    fail() { :; }
    if [[ -n "$ev" ]]; then EV="$ev"; else unset EV; fi
    RHIZO_VM=1 RHIZO_SKIP_BOOT=1
    eval "$body"
    test_boot || exit 1
    bash -c 'echo "${RHIZO_BOOT_EVIDENCE_DIR:-UNSET}"'
  ) > "$out" 2>&1
}

# check test_boot scopes RHIZO_BOOT_EVIDENCE_DIR per EV
check_scoped_and_distinct() {
  local f="$1" outA outB gotA gotB
  outA="$WORK/testA.out"; outB="$WORK/testB.out"
  run_test_boot "$f" "$WORK/testA-evidence" "$outA"
  run_test_boot "$f" "$WORK/testB-evidence" "$outB"
  gotA=$(tail -1 "$outA"); gotB=$(tail -1 "$outB")
  [[ "$gotA" == "$WORK/testA-evidence/boot-failure" ]] \
    || fail "system test A did not scope RHIZO_BOOT_EVIDENCE_DIR under its own EV (got '$gotA'): $(cat "$outA")"
  [[ "$gotB" == "$WORK/testB-evidence/boot-failure" ]] \
    || fail "system test B did not scope RHIZO_BOOT_EVIDENCE_DIR under its own EV (got '$gotB'): $(cat "$outB")"
  [[ "$gotA" != "$gotB" ]] \
    || fail "two system tests with different EV dirs got the same RHIZO_BOOT_EVIDENCE_DIR: $gotA"
}

# check test_boot leaves RHIZO_BOOT_EVIDENCE_DIR unset
check_unset_ev_leaves_fallback() {
  local f="$1" out got
  out="$WORK/noev.out"
  run_test_boot "$f" "" "$out"
  got=$(tail -1 "$out")
  [[ "$got" == "UNSET" ]] \
    || fail "test_boot exported RHIZO_BOOT_EVIDENCE_DIR with no EV set (got '$got'): $(cat "$out")"
}

run_all_checks() {
  FAILURES=()
  check_scoped_and_distinct "$1"
  check_unset_ev_leaves_fallback "$1"
}

if (( ! SELFTEST )); then
  run_all_checks "$SRC"
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}"
    exit 1
  fi
  echo "ok: test_boot scopes RHIZO_BOOT_EVIDENCE_DIR under the system test's own EV dir, distinct system tests land in distinct dirs, and a caller with no EV keeps the per-vm fallback"
  exit 0
fi

# remove the RHIZO_BOOT_EVIDENCE_DIR export from the copy
inject_export_removed() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
line = '  [[ -n "${EV:-}" ]] && export RHIZO_BOOT_EVIDENCE_DIR="$EV/boot-failure"\n'
if line not in s:
    sys.exit("SELFTEST SETUP FAIL: export line not found in test_boot()")
s = s.replace(line, "", 1)
open(p, "w").write(s)
PY
}

# run the checks on a mutated copy
selftest_case() {
  local name="$1" inject="$2" copy
  copy="$WORK/defect-$name.sh"
  cp "$SRC" "$copy"
  "$inject" "$copy" || { echo "SELFTEST SETUP FAIL ($name)"; exit 1; }
  bash -n "$copy" || { echo "SELFTEST SETUP FAIL ($name): mutated copy is not valid bash"; exit 1; }
  run_all_checks "$copy"
  if (( ${#FAILURES[@]} == 0 )); then
    echo "SELFTEST FAIL ($name): the checker passed a copy with the $name defect reintroduced"
    exit 1
  fi
  echo "selftest ok ($name): detected -- ${FAILURES[0]}"
}

selftest_case export-removed inject_export_removed

run_all_checks "$SRC"
if (( ${#FAILURES[@]} > 0 )); then
  printf 'SELFTEST FAIL (clean): the real lib.sh failed its own checker: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "selftest ok (clean): the real lib.sh passes every assertion"
exit 0
