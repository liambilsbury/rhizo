# shellcheck shell=bash
# the vm rig's extension points, redefined by a RHIZO_VM_HOOK file

# refuse a boot of vm $1 by returning nonzero, after saying why on stderr
rig_boot_guard() { :; }

# note that vm $1's qemu is about to start
rig_boot_started() { :; }

# note the outcome of vm $1's newest boot
rig_boot_outcome() { :; }

# print why vm $1 cannot boot now
rig_vm_busy() { :; }

# note that a tool other than run-vm.sh is about to use vm $1
rig_using_vm() { :; }

# note that the tool that called rig_using_vm is done with vm $1
rig_done_with_vm() { :; }

# print the vm this caller works on, or nothing
rig_current_vm() { [[ -n "${RHIZO_VM:-}" ]] && echo "$RHIZO_VM"; return 0; }

# print the dir under var/ that vm $1 mounts as its 9p share
rig_share_dir() { echo share; }

# print the other share dirs sync.sh mirrors var/share into
rig_other_shares() { :; }

# print the words that go before qemu's argv
rig_qemu_wrapper() { :; }

# wait for vm $RHIZO_VM's launcher to start qemu
rig_await_launch() { :; }

# refuse kill_vm with no vm named
rig_kill_guard() { :; }

# record facts about vm $1
rig_vm_record() { :; }

# record the outcome of vm $1's newest boot
rig_vm_record_boot() { :; }

# print a field of vm $1's newest recorded boot
rig_vm_recorded() { return 1; }

_rig_hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_rig_hooks_root="$(cd "$_rig_hooks_dir/../../.." && pwd)"

# note the start of a system test run
rig_test_started() { :; }

# write the verdict file $1
rig_verdict_write() {
  { echo "$2"
    [[ -z "${4:-}" ]] || { echo; echo "$4"; }
  } > "$1"
}

# print the path a run writes result file $1 to
rig_result_path() { echo "$1"; }

# keep the result file $1 a passing run wrote
rig_result_keep() { :; }

# note the verdict recorded in $EV
rig_test_recorded() { :; }

# write what this run was measured on to the file $1
rig_run_identity() { :; }

# print the earlier PASS of system test $1 that covers this run
rig_earlier_pass() { echo "no earlier PASS is recorded, so $1 runs" >&2; return 1; }

# set CYCLE_ID for the profile $1's cycle, nonzero refusing the cycle after saying why on stderr
# shellcheck disable=SC2034
rig_cycle_started() { CYCLE_ID=""; }

# record the profile $1's finished cycle $2, started at epoch $3
rig_cycle_finished() { :; }

# print the recorded verdict of the profile $1's cycle $2
rig_cycle_verdict() { return 1; }

if [[ -n "${RHIZO_VM_HOOK:-}" ]]; then
  _rig_hook_file="$RHIZO_VM_HOOK"
  [[ "$_rig_hook_file" == /* ]] || _rig_hook_file="$_rig_hooks_root/$_rig_hook_file"
  if [[ ! -f "$_rig_hook_file" ]]; then
    echo "hooks.sh: RHIZO_VM_HOOK names $_rig_hook_file, which does not exist" >&2
    return 2 2>/dev/null || exit 2
  fi
  # shellcheck source=/dev/null
  source "$_rig_hook_file" || { echo "hooks.sh: $_rig_hook_file failed to load" >&2; return 2 2>/dev/null || exit 2; }
fi
unset _rig_hook_file
