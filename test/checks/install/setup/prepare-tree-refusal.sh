#!/bin/bash
# check when prepare.sh refuses as enforcing
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE="$HERE/../../../../src/install/prepare/prepare.sh"

# print the failed prepare-tree outcome block
decide_block() {
  awk '/^  if \[\[ \$rc -ne 0 \|\| -z "\$KEY" \]\]; then$/{f=1} f{print} f && /^  fi$/{exit}' <<<"$1"
}

# print the outcome of a prepare-tree output
outcome() {
  local block="$1" out="$2"
  bash -c 'refuse() { echo "refuse:$1"; exit 1; }; failstop() { echo "failstop:$1"; exit 1; }
rc=1 KEY= out=$1
'"$block" _ "$out"
}

# print a finding for each wrong outcome
check_text() {
  local block
  block=$(decide_block "$1")
  [[ -n "$block" ]] || { echo "no prepare-tree outcome block to test"; return; }
  local got
  got=$(outcome "$block" $'L3: RHIZO_ENFORCING: restorecon_recursive trigger staged for /vendor\nPREPARE_TREE_FAILED reason=relabel-failed failed=3')
  [[ "$got" == failstop:prepare-tree-failed ]] || echo "a failure whose log names enforcing ends $got, not failstop:prepare-tree-failed"
  got=$(outcome "$block" $'L3: prepare-tree start\nPREPARE_TREE_REFUSED reason=enforcing')
  [[ "$got" == refuse:enforcing ]] || echo "prepare-tree's enforcing refusal ends $got, not refuse:enforcing"
  got=$(outcome "$block" 'PREPARE_TREE_FAILED reason=vendor-bind')
  [[ "$got" == failstop:prepare-tree-failed ]] || echo "a plain failure ends $got, not failstop:prepare-tree-failed"
}

text=$(cat "$PREPARE") || { echo "prepare-tree-refusal: cannot read $PREPARE" >&2; exit 1; }
if [[ "${1:-}" == --selftest ]]; then
  expect() {
    grep -qF "$2" <<<"$3" || { echo "prepare-tree-refusal: FAIL selftest: $1 was not flagged: ${3:-<no finding>}" >&2; exit 1; }
  }
  anchor="grep -qx 'PREPARE_TREE_REFUSED reason=enforcing' <<<\"\$out\""
  grep -qF "$anchor" <<<"$text" || { echo "prepare-tree-refusal: FAIL selftest: no refusal anchor" >&2; exit 1; }
  expect "a refusal decided by any text naming enforcing" "a failure whose log names enforcing ends refuse:enforcing" \
    "$(check_text "${text/"$anchor"/"grep -qi 'enforc' <<<\"\$out\""}")"
  expect "a refusal that misses the refusal line" "prepare-tree's enforcing refusal ends failstop" \
    "$(check_text "${text/"$anchor"/"grep -qx 'PREPARE_TREE_REFUSED' <<<\"\$out\""}")"
  out=$(check_text "$text")
  [[ -z "$out" ]] || { echo "prepare-tree-refusal: FAIL selftest: the real script has findings: $out" >&2; exit 1; }
  echo "prepare-tree-refusal: selftest ok"
  exit 0
fi
out=$(check_text "$text")
if [[ -n "$out" ]]; then
  echo "prepare-tree-refusal: FAIL"
  while IFS= read -r line; do echo "  $line"; done <<<"$out"
  exit 1
fi
echo "prepare-tree-refusal: ok"
