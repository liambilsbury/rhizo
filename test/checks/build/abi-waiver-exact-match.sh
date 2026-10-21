#!/bin/bash
# test the waiver lookup in abi.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_RELEASE="${BUILD_RELEASE_OVERRIDE:-$HERE/../../tools/build/release.sh}"
CHECK_ABI="${CHECK_ABI_OVERRIDE:-$HERE/build/abi.sh}"
fail() { echo "check-abi-waiver-exact-match: $*" >&2; exit 1; }

[[ -r "$BUILD_RELEASE" ]] || fail "cannot read $BUILD_RELEASE"
[[ -r "$CHECK_ABI" ]] || fail "cannot read $CHECK_ABI"

if [[ "${1:-}" != "--selftest" ]]; then
  bash -n "$BUILD_RELEASE" || fail "release.sh does not parse"

  if grep -qE 'grep.*abi-waivers\.tsv' "$BUILD_RELEASE"; then
    fail "release.sh reads abi-waivers.tsv itself"
  fi

  grep -q '^waivers = {}$' "$CHECK_ABI" \
    || fail "lost the waivers dict build in abi.sh"
  grep -q '^    return waivers.get((target, name, thing))$' "$CHECK_ABI" \
    || fail "waiver_for() no longer does an exact dict lookup"

  echo "check-abi-waiver-exact-match: wiring intact"
  exit 0
fi

SNIPPET=$(sed -n '/^waivers = {}/,/^    return waivers.get/p' "$CHECK_ABI")
[[ -n "$SNIPPET" ]] || fail "could not extract the waiver_for() snippet from $CHECK_ABI"

FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT
mkdir -p "$FIXTURE_DIR/test/checks/data"
cat > "$FIXTURE_DIR/test/checks/data/abi-waivers.tsv" <<'EOF'
# release	binary	symbol	reason
a17	gfx_hal/keymintXso	somesymbol	fixture row for a different binary that only looks similar under a BRE
a17	gfx_hal/libgralloc.so	_ZN3fooE	fixture row for the exact binary under test
EOF

OUT=$(python3 - "$FIXTURE_DIR" <<PY
import os, sys
repo = sys.argv[1]
target = "a17"

$SNIPPET

bug = waiver_for("gfx_hal/keymint.so", "somesymbol")
print("BUG-CASE:", "MATCHED (WRONG)" if bug else "no match (correct)")

exact = waiver_for("gfx_hal/libgralloc.so", "_ZN3fooE")
print("EXACT-CASE:", "matched (correct)" if exact else "NO MATCH (WRONG)")
PY
)
echo "$OUT"

assertions=0
# count an assertion and fail unless the output contains a line
check_line() {
  assertions=$((assertions + 1))
  [[ "$OUT" == *"$1"* ]] || fail "expected output to contain '$1', got:
$OUT"
}
check_line "BUG-CASE: no match (correct)"
check_line "EXACT-CASE: matched (correct)"

echo "check-abi-waiver-exact-match selftest: $assertions assertions passed"
