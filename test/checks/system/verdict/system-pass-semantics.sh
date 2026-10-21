#!/bin/bash
# test lib.sh's pass and fail counting
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

source ../vm/common.sh
source ../system/lib/lib.sh
EV=$(mktemp -d)
trap 'rm -rf "$EV"' EXIT
# shellcheck disable=SC2034
TEST_NAME=check
FAILED=0
STEP_MARK=0

if (( SELFTEST )); then
  fail() { log "FAIL: $*"; FAILED=1; return 0; }
  pass() { (( FAILED == STEP_MARK )) && log "  ok: $*"; return 0; }
fi

LOG="$EV/out.txt"
# return success when the log has an ok line for a text
said() { grep -q "ok: $1" "$LOG"; }
# return success when the log has a FAIL line for a text
said_fail() { grep -q "FAIL: $1" "$LOG"; }

bad=0

step "one" 2>/dev/null
pass "clean step" > "$LOG" 2>&1
said "clean step" || { echo "check-test-pass-semantics: a clean step printed no ok line"; bad=1; }

step "two" 2>/dev/null
fail "deliberate" 2>/dev/null
pass "same step after a failure" > "$LOG" 2>&1
said "same step after a failure" \
  || { echo "check-test-pass-semantics: pass was silent in a step that had already failed"; bad=1; }

step "three" 2>/dev/null
pass "later step after an earlier failure" > "$LOG" 2>&1
said "later step after an earlier failure" \
  || { echo "check-test-pass-semantics: a clean step after an earlier failure printed no ok line"; bad=1; }

step "four" 2>/dev/null
fail "second failure" 2>/dev/null
pass "second failing step" > "$LOG" 2>&1
said "second failing step" \
  || { echo "check-test-pass-semantics: pass was silent in the second failing step"; bad=1; }

step "five" 2>/dev/null
fail "third failure" 2>/dev/null
fail "fourth failure" 2>/dev/null
(( FAILED >= 4 )) \
  || { echo "check-test-pass-semantics: FAILED is $FAILED after four failures"; bad=1; }

step "six" 2>/dev/null
[[ "$FAILED" == "$STEP_MARK" ]] \
  || { echo "check-test-pass-semantics: a clean step does not compare equal to its own STEP_MARK"; bad=1; }

step "seven" 2>/dev/null
: > "$LOG"
true && pass "predicate true" >> "$LOG" 2>&1 || fail "must not appear" >> "$LOG" 2>&1
said "predicate true" || { echo "check-test-pass-semantics: a true predicate printed no ok line"; bad=1; }
said_fail "must not appear" && { echo "check-test-pass-semantics: a true predicate also ran the fail branch"; bad=1; }

if (( SELFTEST )); then
  (( bad )) && { echo "check-test-pass-semantics --selftest: the flag-shaped fail() and guarded pass() were caught"; exit 0; }
  echo "check-test-pass-semantics --selftest: a flag-shaped fail() and a guarded pass() passed the assertions"
  exit 1
fi
(( bad )) && exit 1
echo "check-test-pass-semantics: pass always speaks, returns 0, and FAILED counts"
exit 0
