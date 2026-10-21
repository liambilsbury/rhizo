#!/bin/bash
# test test/vm/rig/hooks.sh
set -uo pipefail
while read -r var; do unset "$var"; done < <(compgen -e | grep -E '^RHIZO_')

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1
HOOKS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../vm/rig" && pwd)/hooks.sh"
[[ -r "$HOOKS_SRC" ]] || { echo "FAIL: cannot read $HOOKS_SRC"; exit 1; }

WORK="$(mktemp -d)"
HOLDERS=()
# stop the fixture's holding runners and remove the fixture
cleanup() {
  local p
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILURES=()
# record a failure
fail() { FAILURES+=("$1"); }

# compare a value to the one wanted and record a mismatch
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', want '$3'"; }

# make a checkout with a hooks file and share dirs
make_root() {
  local root
  root=$(mktemp -d "$WORK/root.XXXX") || return 1
  mkdir -p "$root/test/vm/rig" "$root/var/share" "$root/var/share-2" "$root/var/share-5" "$root/var/share-x"
  cp "$1" "$root/test/vm/rig/hooks.sh"
  echo "$root"
}

# run a command after sourcing a root's hooks
in_hooks() {
  local root="$1" vars=()
  shift
  while [[ "${1:-}" =~ ^[A-Z_]+= ]]; do vars+=("$1"); shift; done
  env -i PATH="$PATH" ${vars[@]+"${vars[@]}"} bash -c 'cd "$1" && source test/vm/rig/hooks.sh && eval "$2"' _ "$root" "$*"
}

# join the input lines with spaces
joined() { tr '\n' ' ' | sed 's/ $//'; }

# check the hooks a plain checkout runs with
check_defaults() {
  local root out rc
  root=$(make_root "$1")
  in_hooks "$root" RHIZO_VM=3 'rig_boot_guard 3'
  check "the default boot guard" "$?" 0
  check "the default current vm" "$(in_hooks "$root" RHIZO_VM=4 rig_current_vm)" 4
  check "the default current vm with no RHIZO_VM" "$(in_hooks "$root" rig_current_vm)" ""
  check "the default share dir of vm 2" "$(in_hooks "$root" 'rig_share_dir 2 boot')" share
  check "the default other share dirs" "$(in_hooks "$root" rig_other_shares | joined)" ""
  check "the default qemu wrapper" "$(in_hooks "$root" 'rig_qemu_wrapper run-vm.sh; echo "rc=$?"')" rc=0
  check "the default vm record" "$(in_hooks "$root" 'rig_vm_recorded 2 release; echo "rc=$?"')" rc=1
  in_hooks "$root" 'rig_verdict_write "$PWD/v.txt" "PASSED head" "other head" "failures=1"'
  check "the default verdict file" "$(cat "$root/v.txt" 2>/dev/null | tr '\n' '|')" "PASSED head||failures=1|"
  in_hooks "$root" 'rig_verdict_write "$PWD/v.txt" "PASSED head" "other head" ""'
  check "the default verdict file with no reasons" "$(cat "$root/v.txt" 2>/dev/null | tr '\n' '|')" "PASSED head|"
  check "the default result path" "$(in_hooks "$root" 'rig_result_path /x/summary.txt')" /x/summary.txt
  out=$(in_hooks "$root" 'rig_earlier_pass boot-smoke.sh tree' 2>&1); rc=$?
  check "the default earlier PASS" "$rc" 1
  [[ "$out" == *"no earlier PASS"* ]] || fail "the default earlier PASS does not say why the test runs: '$out'"
  check "the default cycle verdict" "$(in_hooks "$root" 'rig_cycle_verdict server x; echo "rc=$?"')" rc=1
}

# check RHIZO_VM_HOOK replaces a hook
check_override() {
  local root out rc
  root=$(make_root "$1")
  printf '%s\n' 'rig_current_vm() { echo 9; }' > "$root/current-hook.sh"
  check "rig_current_vm under an absolute RHIZO_VM_HOOK" "$(in_hooks "$root" RHIZO_VM=4 RHIZO_VM_HOOK="$root/current-hook.sh" rig_current_vm)" 9
  check "rig_current_vm under a relative RHIZO_VM_HOOK" "$(in_hooks "$root" RHIZO_VM=4 RHIZO_VM_HOOK=current-hook.sh rig_current_vm)" 9
  out=$(env -i PATH="$PATH" RHIZO_VM_HOOK=current-hook.sh bash -c 'cd "$1/var" && source ../test/vm/rig/hooks.sh && rig_current_vm' _ "$root" 2>&1)
  check "rig_current_vm under a relative RHIZO_VM_HOOK sourced from var/" "$out" 9
  check "rig_result_path under a hook that leaves it" "$(in_hooks "$root" RHIZO_VM=4 RHIZO_VM_HOOK=current-hook.sh 'rig_result_path /x/y')" /x/y
  out=$(env -i PATH="$PATH" RHIZO_VM_HOOK=no-such-hook.sh bash -c 'cd "$1" && source test/vm/rig/hooks.sh; echo "rc=$?"' _ "$root" 2>&1)
  [[ "$out" == *"rc=2"* ]] || fail "sourcing the hooks with RHIZO_VM_HOOK naming no file did not return 2: '$out'"
  [[ "$out" == *"$root/no-such-hook.sh"* ]] || fail "the missing-hook refusal does not name the file: '$out'"
  out=$(env -i PATH="$PATH" RHIZO_VM_HOOK=no-such-hook.sh bash -c 'cd "$1" && bash test/vm/rig/hooks.sh; echo "rc=$?"' _ "$root" 2>&1)
  [[ "$out" == *"rc=2"* ]] || fail "running the hooks with RHIZO_VM_HOOK naming no file did not exit 2: '$out'"
  printf '%s\n' 'return 1' > "$root/broken-hook.sh"
  out=$(env -i PATH="$PATH" RHIZO_VM_HOOK=broken-hook.sh bash -c 'cd "$1" && source test/vm/rig/hooks.sh; echo "rc=$?"' _ "$root" 2>&1)
  [[ "$out" == *"rc=2"* ]] || fail "a RHIZO_VM_HOOK that fails to load did not refuse with 2: '$out'"
}

# run all of the checks against the hooks file $1
run_all_checks() {
  FAILURES=()
  check_defaults "$1"
  check_override "$1"
}

if (( ! SELFTEST )); then
  run_all_checks "$HOOKS_SRC"
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}"
    exit 1
  fi
  echo "rig hooks: the defaults pass the boot guard, work on RHIZO_VM, share var/share with every vm and record none, write the verdict's headline and reasons alone and record no earlier PASS; RHIZO_VM_HOOK replaces a hook and a missing one refuses with 2"
  exit 0
fi

# run the checks on a mutated hooks.sh and expect a failure
selftest_case() {
  local name="$1" copy="$WORK/defect-$1.sh"
  python3 - "$HOOKS_SRC" "$copy" "$2" "$3" <<'PY' || { echo "SELFTEST SETUP FAIL ($name)"; exit 1; }
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: %r found %d times" % (old, s.count(old)))
open(dst, "w").write(s.replace(old, new, 1))
PY
  run_all_checks "$copy"
  if (( ${#FAILURES[@]} == 0 )); then
    echo "SELFTEST FAIL ($name): the checker passed a hooks.sh with that defect"
    exit 1
  fi
  echo "selftest ok ($name): detected -- ${FAILURES[0]}"
}

selftest_case guard-refuses 'rig_boot_guard() { :; }' 'rig_boot_guard() { return 1; }'
selftest_case per-vm-share 'rig_share_dir() { echo share; }' 'rig_share_dir() { echo "share-$1"; }'
selftest_case verdict-no-reasons '[[ -z "${4:-}" ]] || { echo; echo "$4"; }' ':'
selftest_case earlier-pass-covers 'rig_earlier_pass() { echo "no earlier PASS is recorded, so $1 runs" >&2; return 1; }' 'rig_earlier_pass() { return 0; }'
selftest_case relative-from-cwd '[[ "$_rig_hook_file" == /* ]] || _rig_hook_file="$_rig_hooks_root/$_rig_hook_file"' ':'
selftest_case missing-hook-ignored 'return 2 2>/dev/null || exit 2
  fi' 'return 0
  fi'
run_all_checks "$HOOKS_SRC"
if (( ${#FAILURES[@]} > 0 )); then
  printf 'SELFTEST FAIL (clean): the real hooks.sh failed its own checker: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "selftest ok (clean): the real hooks.sh passes every assertion"
exit 0
