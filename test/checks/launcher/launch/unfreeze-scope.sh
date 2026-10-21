#!/bin/bash
# test the unfreeze scope of rhizo-cgroup-unfreeze.sh
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNFREEZE="${RHIZO_CHECK_UNFREEZE:-$HERE/../../src/androidd/host/unfreeze-cgroup.sh}"

FAILED=0
# print a failure line and mark the check failed
bad() { echo "FAIL: unfreeze-scope: $*"; FAILED=1; }

# print a function body from a file
func_body() {
  awk -v fn="$2" '
    $0 ~ "^"fn"\\(\\)" { f=1 }
    f { print }
    f && /^}$/ { exit }
  ' "$1"
}

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' EXIT

  write_good() {
    cat > "$t/rhizo-cgroup-unfreeze.sh" <<'UNFREEZEEOF'
# shellcheck shell=sh
rhizo_is_stock_freeze_leaf() {  # return 0 for a uid_*/pid_* path
  _leaf="${1##*/}"
  _parent="${1%/*}"
  _parent_leaf="${_parent##*/}"
  case "$_leaf" in
    pid_*) case "$_parent_leaf" in uid_*) return 0 ;; esac ;;
  esac
  return 1
}

rhizo_foreign_frozen() {  # print the foreign frozen cgroups
  _root="$1"
  for _p1 in "$_root"/*/ "$_root"/*/*/ "$_root"/*/*/*/ "$_root"/*/*/*/*/ "$_root"/*/*/*/*/*/ "$_root"/*/*/*/*/*/*/; do
    [ -d "$_p1" ] || continue
    _cgp="${_p1%/}"
    [ -f "$_cgp/cgroup.freeze" ] || continue
    rhizo_is_stock_freeze_leaf "$_cgp" && continue
    [ "$(cat "$_cgp/cgroup.freeze" 2>/dev/null)" = "1" ] && printf '%s\n' "$_cgp"
  done
}

rhizo_unfreeze() {  # unfreeze the cgroup
  _cg="$1"; _deadline="${2:-30}"
  _unit=""
  case "$_cg" in
    */system.slice/*.service) _unit="${_cg##*/}" ;;
    */system.slice/*.service/*) _unit="${_cg%/*}"; _unit="${_unit##*/}" ;;
  esac
  if [ -n "$_unit" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl thaw "$_unit" >/dev/null 2>&1 || echo 0 > "$_cg/cgroup.freeze" 2>/dev/null
  else
    echo 0 > "$_cg/cgroup.freeze" 2>/dev/null
  fi
  return 0
}

rhizo_unfreeze_gate() {  # unfreeze the stack cgroup and foreign frozen cgroups
  _cg=$(rhizo_stack_cgroup "$1") || return 0
  rhizo_stack_frozen "$_cg" || return 0
  rhizo_unfreeze "$_cg" 30 || return 1
  rhizo_wait_servicemanager 20 || return 1
  for _fcg in $(rhizo_foreign_frozen "$_cg"); do
    rhizo_unfreeze "$_fcg" 10 || { echo "rhizo_unfreeze_gate: $_fcg would not unfreeze" >&2; return 1; }
  done
  return 0
}
UNFREEZEEOF
  }

  check_case() {
    local name="$1" want="$2" out
    out=$(RHIZO_CHECK_UNFREEZE="$t/rhizo-cgroup-unfreeze.sh" "$SELF" 2>&1)
    if ! grep -qF "$want" <<<"$out"; then
      echo "SELFTEST FAILED ($name): expected to see:" >&2
      echo "  $want" >&2
      echo "the check produced:" >&2
      sed 's/^/    /' <<<"$out" >&2
      exit 1
    fi
  }

  write_good
  sed -i '/^rhizo_is_stock_freeze_leaf()/,/^}$/d' "$t/rhizo-cgroup-unfreeze.sh"
  check_case "classifier missing" "no rhizo_is_stock_freeze_leaf() classifier"

  write_good
  sed -i '/^rhizo_foreign_frozen()/,/^}$/d' "$t/rhizo-cgroup-unfreeze.sh"
  check_case "walk missing" "no rhizo_foreign_frozen() walk"

  write_good
  python3 - "$t/rhizo-cgroup-unfreeze.sh" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
  '  for _fcg in $(rhizo_foreign_frozen "$_cg"); do\n'
  '    rhizo_unfreeze "$_fcg" 10 || { echo "rhizo_unfreeze_gate: $_fcg would not unfreeze" >&2; return 1; }\n'
  '  done\n', '')
open(p, 'w').write(s)
PYEOF
  check_case "walk unwired" "rhizo_unfreeze_gate() never calls it"

  write_good
  python3 - "$t/rhizo-cgroup-unfreeze.sh" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
  '  case "$_cg" in\n'
  '    */system.slice/*.service) _unit="${_cg##*/}" ;;\n'
  '    */system.slice/*.service/*) _unit="${_cg%/*}"; _unit="${_unit##*/}" ;;\n'
  '  esac\n',
  '  case "$_cg" in\n'
  '    */system.slice/*.service) _unit="${_cg##*/}" ;;\n'
  '  esac\n')
open(p, 'w').write(s)
PYEOF
  check_case "single unit shape" "rhizo_unfreeze() only matches one unit-cgroup shape"

  write_good
  out=$(RHIZO_CHECK_UNFREEZE="$t/rhizo-cgroup-unfreeze.sh" "$SELF" 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "SELFTEST FAILED (unmutated): a fully-fixed tree still failed:" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  write_good
  table_fail=0
  run_classify() {
    sh -c '. "$1"; rhizo_is_stock_freeze_leaf "$2"' _ "$t/rhizo-cgroup-unfreeze.sh" "$1"
  }
  assert_leaf() {
    local path="$1" want="$2" got
    run_classify "$path"; got=$?
    [[ "$got" == "$want" ]] || { echo "SELFTEST FAILED (classifier table): $path -> rc=$got, wanted $want" >&2; table_fail=1; }
  }
  assert_leaf "/sys/fs/cgroup/androidd.service/android/apps/uid_10123/pid_5566" 0
  assert_leaf "/sys/fs/cgroup/androidd.service/android/system/uid_1000/pid_412" 0
  assert_leaf "/sys/fs/cgroup/androidd.service/android" 1
  assert_leaf "/sys/fs/cgroup/androidd.service/android/system" 1
  assert_leaf "/sys/fs/cgroup/androidd.service/android/apps/uid_10123" 1
  assert_leaf "/sys/fs/cgroup/androidd.service/android/apps/uid_10123/pid_5566/extra" 1
  (( table_fail )) && exit 1

  cg=$(mktemp -d)/android
  mkdir -p "$cg/system" "$cg/apps/uid_10123/pid_5566" "$cg/apps/uid_555/pid_9"
  echo 0 > "$cg/cgroup.freeze"
  echo 0 > "$cg/system/cgroup.freeze"
  echo 1 > "$cg/apps/uid_10123/pid_5566/cgroup.freeze"
  echo 0 > "$cg/apps/uid_555/pid_9/cgroup.freeze"
  mkdir -p "$cg/apps/uid_777"
  echo 1 > "$cg/apps/uid_777/cgroup.freeze"
  got=$(sh -c '. "$1"; rhizo_foreign_frozen "$2"' _ "$t/rhizo-cgroup-unfreeze.sh" "$cg" | sort)
  want="$cg/apps/uid_777"
  if [[ "$got" != "$want" ]]; then
    echo "SELFTEST FAILED (walk): got [$got], wanted [$want]" >&2
    exit 1
  fi

  echo "selftest ok: detects all four defects, table-tests the classifier, walks a fabricated tree correctly, passes a fixed tree clean"
  exit 0
fi

if [[ ! -f "$UNFREEZE" ]]; then
  bad "$UNFREEZE is missing"
  echo "unfreeze scope is not fenced" >&2
  exit 1
fi

if ! grep -qE '^rhizo_is_stock_freeze_leaf\(\)' "$UNFREEZE"; then
  bad "no rhizo_is_stock_freeze_leaf() classifier in $UNFREEZE"
fi

have_walk=0
if grep -qE '^rhizo_foreign_frozen\(\)' "$UNFREEZE"; then
  have_walk=1
else
  bad "no rhizo_foreign_frozen() walk in $UNFREEZE"
fi

test_body=$(func_body "$UNFREEZE" rhizo_unfreeze_gate)
if [[ -z "$test_body" ]]; then
  bad "no rhizo_unfreeze_gate() in $UNFREEZE"
elif (( have_walk )); then
  if ! grep -q 'rhizo_foreign_frozen' <<<"$test_body"; then
    bad "rhizo_foreign_frozen() exists but rhizo_unfreeze_gate() never calls it"
  fi
fi

if grep -qF '*/system.slice/*.service)' "$UNFREEZE" && ! grep -qF '*/system.slice/*.service/*)' "$UNFREEZE"; then
  bad "rhizo_unfreeze() only matches one unit-cgroup shape (*/system.slice/*.service)"
elif ! grep -qF '*/system.slice/*.service/*)' "$UNFREEZE"; then
  bad "rhizo_unfreeze()'s unit-cgroup case has neither shape sleep.sh's stack_cgroup() matches"
fi

if (( FAILED )); then
  echo "unfreeze scope is not fenced"
  exit 1
fi
echo "unfreeze-scope: classifier and walk present, system test wires them, both unit shapes matched"
exit 0
