#!/bin/bash
# check debs.sh --at builds REF's payload
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DEBS="$HERE/../../tools/build/packaging/deb/debs.sh"

# print a function body between its header and the next top-level function
extract_function() {
  awk -v fn="$2" '
    $0 ~ "^" fn "\\(\\) \\{" { p = 1 }
    p { print }
    p && /^}/ { exit }
  ' "$1"
}

# return the problems with stage_prev_payload
check_stage_prev_payload() {
  local body
  body=$(extract_function "$1" stage_prev_payload)
  [[ -n "$body" ]] || { echo "FAIL: no stage_prev_payload() function in $1"; return 1; }
  if grep -qE '(ln[[:space:]]+-s|cp[[:space:]]+-a)[^#]*var/share' <<<"$body"; then
    echo "FAIL: stage_prev_payload() links or copies a var/share"
    return 1
  fi
  if grep -qE 'ln[[:space:]]+-s[^#]*toolchain' <<<"$body" || ! grep -qE 'cp[[:space:]]+-a[^#]*"\$wt/toolchain"' <<<"$body"; then
    echo "FAIL: stage_prev_payload() links the toolchain or does not copy it"
    return 1
  fi
  grep -qE 'cd "\$wt" && tools/fetch/build-inputs.sh' <<<"$body" \
    || { echo "FAIL: stage_prev_payload() no longer runs REF's own build-inputs.sh"; return 1; }
  grep -qE 'cd "\$wt" && tools/build/payload.sh' <<<"$body" \
    || { echo "FAIL: stage_prev_payload() no longer runs REF's own payload.sh"; return 1; }
  grep -qE -- '-d[[:space:]]+"\$wt/var/share"[[:space:]]*&&[[:space:]]*!.*-L' <<<"$body" \
    || { echo "FAIL: stage_prev_payload() no longer asserts REF's var/share is a real directory, not a symlink"; return 1; }
  grep -q 'comm -12' <<<"$body" \
    || { echo "FAIL: stage_prev_payload() no longer checks REF's var/share for a shared inode with this tree's"; return 1; }
}

# check the real debs.sh and each planted-defect copy of it
selftest() {
  local fail=0 tmp out rc

  check_stage_prev_payload "$BUILD_DEBS" \
    || { echo "SELFTEST FAILED: the real debs.sh was flagged"; fail=1; }
  tmp=$(mktemp -d)

  cp "$BUILD_DEBS" "$tmp/regressed.sh"
  python3 - "$tmp/regressed.sh" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
marker = '  if [[ -e "$ROOT/toolchain" && ! -e "$wt/toolchain" ]]; then'
assert marker in t, "fixture: marker line not found"
t = t.replace(marker, '  ln -s "$ROOT/var/share" "$wt/var/share"\n' + marker, 1)
open(p, "w").write(t)
PY
  out=$(check_stage_prev_payload "$tmp/regressed.sh" 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"links or copies a var/share"* ]] \
    || { echo "SELFTEST FAILED: reintroducing the share symlink was not caught -- got: $out"; fail=1; }

  cp "$BUILD_DEBS" "$tmp/linkedtc.sh"
  python3 - "$tmp/linkedtc.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
marker = '  if [[ -e "$ROOT/toolchain" && ! -e "$wt/toolchain" ]]; then'
assert marker in t, "fixture: marker line not found"
t = t.replace(marker, '  ln -s "$(readlink -f "$ROOT/toolchain")" "$wt/toolchain"\n' + marker, 1)
open(p, "w").write(t)
PY
  out=$(check_stage_prev_payload "$tmp/linkedtc.sh" 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"links the toolchain"* ]] \
    || { echo "SELFTEST FAILED: linking the toolchain was not caught -- got: $out"; fail=1; }

  cp "$BUILD_DEBS" "$tmp/noassert.sh"
  python3 - "$tmp/noassert.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).readlines()
out = [l for l in lines if 'var/share" && ! -L' not in l]
assert len(out) < len(lines), "fixture: nothing removed"
open(p, "w").writelines(out)
PY
  out=$(check_stage_prev_payload "$tmp/noassert.sh" 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"real directory"* ]] \
    || { echo "SELFTEST FAILED: removing the real-directory assertion was not caught -- got: $out"; fail=1; }

  cp "$BUILD_DEBS" "$tmp/noinode.sh"
  python3 - "$tmp/noinode.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).readlines()
out = [l for l in lines if 'comm -12' not in l]
assert len(out) < len(lines), "fixture: nothing removed"
open(p, "w").writelines(out)
PY
  out=$(check_stage_prev_payload "$tmp/noinode.sh" 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"shared inode"* ]] \
    || { echo "SELFTEST FAILED: removing the shared-inode check was not caught -- got: $out"; fail=1; }

  cp "$BUILD_DEBS" "$tmp/nofetch.sh"
  sed -i "/tools\/fetch\/build-inputs.sh --accept-android-sdk-license/d" "$tmp/nofetch.sh"
  out=$(check_stage_prev_payload "$tmp/nofetch.sh" 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"build-inputs.sh"* ]] \
    || { echo "SELFTEST FAILED: dropping the build-inputs.sh call was not caught -- got: $out"; fail=1; }

  cp "$BUILD_DEBS" "$tmp/norename.sh"
  sed -i 's/^stage_prev_payload() {/stage_prev_payload_renamed() {/' "$tmp/norename.sh"
  out=$(check_stage_prev_payload "$tmp/norename.sh" 2>&1); rc=$?
  [[ $rc -ne 0 && "$out" == *"no stage_prev_payload() function"* ]] \
    || { echo "SELFTEST FAILED: renaming the function away was not caught -- got: $out"; fail=1; }

  rm -rf "$tmp"
  if (( fail )); then echo "build-debs-at-share.sh selftest: FAILED"; return 1; fi
  echo "build-debs-at-share.sh selftest: ok"
}

if [[ "${1:-}" == --selftest ]]; then
  selftest; exit $?
fi
check_stage_prev_payload "$BUILD_DEBS"
