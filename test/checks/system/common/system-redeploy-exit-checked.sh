#!/bin/bash
# test redeploy.sh exit status checks in system tests
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYS_DIR="${RHIZO_CHECK_SYSTEM:-$HERE/../system}"
source "$HERE/../system/run/system-tests.sh"

# return 0 for a guarded redeploy.sh call
guarded() {
  local i="$1" line="${LINES[$1]}" next j
  [[ "$line" == *'||'* ]] && return 0
  if [[ "$line" == *'\' ]]; then
    next="${LINES[$((i+1))]:-}"
    [[ "$next" =~ ^[[:space:]]*\|\| ]] && return 0
  fi
  for j in 1 2; do
    next="${LINES[$((i+j))]:-}"
    [[ "$next" == *'$?'* ]] && return 0
  done
  return 1
}

# print each unchecked redeploy.sh call site
scan() {
  local dir="$1" f base line
  local map
  map=$(system_test_map "$dir") && [[ -n "$map" ]] || { echo "FAIL: no system test could be listed under $dir"; return 1; }
  while IFS=$'\t' read -r base f; do
    mapfile -t LINES < "$f"
    local i
    for (( i = 0; i < ${#LINES[@]}; i++ )); do
      line="${LINES[$i]}"
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" == *'./redeploy.sh'* ]] || continue
      [[ "$line" =~ 2\>\&1[[:space:]]*\\?[[:space:]]*$ ]] || continue
      [[ "$line" =~ \&[[:space:]]*$ ]] && continue
      guarded "$i" || echo "$base:$((i+1))"
    done
  done <<<"$map"
}

if [[ "${1:-}" == --selftest ]]; then
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' EXIT

  cat > "$t/fixture.sh" <<'EOF'
#!/bin/bash
# test-boot-mode: shared
same_line() {
  ./redeploy.sh --boot-wait 240 > "$EV/redeploy.log" 2>&1 || { fail "x"; exit 1; }
}
continuation() {
  ./redeploy.sh "${args[@]}" > "$log" 2>&1 \
    || fail "staging failed"
}
exit_status_read_back() {
  ./redeploy.sh --skip-kill --boot-wait 240 > "$EV/redeploy.log" 2>&1
  local rc=$?
  tail -3 "$EV/redeploy.log"
  (( rc == 0 )) || fail "bad"
}
backgrounded() {
  ./redeploy.sh --boot-wait 240 > "$REDEPLOY_LOG" 2>&1 &
  REDEPLOY_PID=$!
}
EOF
  out=$(scan "$t")
  if [[ -n "$out" ]]; then
    echo "SELFTEST FAILED (unmutated): a checked call was reported anyway" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  cat >> "$t/fixture.sh" <<'EOF'
unchecked() {
  ./redeploy.sh --skip-kill --boot-wait 240 > "$EV/redeploy.log" 2>&1
  tail -3 "$EV/redeploy.log"
}
EOF
  want_line=$(grep -nF -- './redeploy.sh --skip-kill --boot-wait 240 > "$EV/redeploy.log" 2>&1' "$t/fixture.sh" | tail -1 | cut -d: -f1)
  out=$(scan "$t")
  if [[ "$out" != "fixture.sh:$want_line" ]]; then
    echo "SELFTEST FAILED: an unchecked ./redeploy.sh call was not reported at the right line" >&2
    echo "    got: '$out', wanted line $want_line" >&2
    exit 1
  fi

  echo "selftest ok: passes a same-line ||, a continuation ||, a \$?-read-back and a backgrounded call, catches an unchecked one"
  exit 0
fi

OUT=$(scan "$SYS_DIR")
if [[ -n "$OUT" ]]; then
  while IFS=: read -r base ln; do
    echo "FAIL: $base:$ln: ./redeploy.sh call's exit status is never checked (no ||, no \$? read within 2 lines)"
  done <<<"$OUT"
  exit 1
fi
echo "every system test's ./redeploy.sh call checks its own exit status"
exit 0
