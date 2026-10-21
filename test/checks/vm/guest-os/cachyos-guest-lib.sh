#!/bin/bash
# test the functions in cachyos-guest-lib.sh
# shellcheck disable=SC2034
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "${1:-}" == --selftest ]] || { echo "usage: $0 --selftest" >&2; exit 2; }
# shellcheck source=../vm/guest-os/cachyos-guest-lib.sh
source "$HERE/../vm/guest-os/cachyos-guest-lib.sh"
FAILED=0 CASES=0
# compare two values and record a mismatch
check() {
  CASES=$((CASES + 1))
  [[ "$2" == "$3" ]] && return 0
  echo "got '$2' want '$3' for: $1"; FAILED=1
}
# check a string contains a substring
has() {
  CASES=$((CASES + 1))
  [[ "$3" == *"$2"* ]] && return 0
  echo "'$3' does not name '$2' for: $1"; FAILED=1
}

unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
MAIN="$SCRATCH/main" SECOND="$SCRATCH/second"
git init -q "$MAIN"
git -C "$MAIN" -c user.name=selftest -c user.email=selftest@invalid commit -q --allow-empty -m fixture
git -C "$MAIN" worktree add -q "$SECOND" -b second
MAIN=$(cd "$MAIN" && pwd -P) SECOND=$(cd "$SECOND" && pwd -P)

mkdir -p "$MAIN/var/cachyos-dl" "$SECOND/var"
ln -s "$MAIN/var/cachyos-dl" "$SECOND/var/cachyos-dl"
BASE="$MAIN/var/cachyos-dl/base.qcow2" OTHER="$MAIN/var/cachyos-dl/other.qcow2"
qemu-img create -q -f qcow2 "$BASE" 1M
qemu-img create -q -f qcow2 "$OTHER" 1M
qemu-img create -q -f qcow2 -b "$SECOND/var/cachyos-dl/base.qcow2" -F qcow2 "$MAIN/var/mid.qcow2"
qemu-img create -q -f qcow2 -b "$MAIN/var/mid.qcow2" -F qcow2 "$SECOND/var/vm.qcow2"

# run refuse_vm_overlays on a base image
guard() {
  guard_err=$( (cachyos_lib_dir="$MAIN"; refuse_vm_overlays "$1") 2>&1 >/dev/null)
  guard_rc=$?
}

guard "$BASE"
check "overlaid base: refused" "$guard_rc" 1
has "overlaid base: names the overlay" "$MAIN/var/mid.qcow2 (checkout $MAIN)" "$guard_err"
has "overlaid base: names the chained overlay" "$SECOND/var/vm.qcow2 (checkout $SECOND)" "$guard_err"
has "overlaid base: names the base" "overlay $BASE" "$guard_err"
guard "$OTHER"
check "unrelated base: passes" "$guard_rc" 0
check "unrelated base: silent" "$guard_err" ""
rm "$SECOND/var/vm.qcow2"
guard "$BASE"
has "one overlay left: still refused" "$MAIN/var/mid.qcow2 (checkout $MAIN)" "$guard_err"
check "one overlay left: the deleted one is not named" "$(grep -c vm.qcow2 <<<"$guard_err")" 0
rm "$MAIN/var/mid.qcow2"
guard "$BASE"
check "no overlay left: passes" "$guard_rc" 0
check "no overlay left: silent" "$guard_err" ""

qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$MAIN/var/vm.qcow2"
guard_err=$( (export GIT_DIR="$SCRATCH/no-such-repo"; cachyos_lib_dir="$MAIN"; refuse_vm_overlays "$BASE") 2>&1 >/dev/null)
guard_rc=$?
check "git worktree list fails: refused" "$guard_rc" 1
has "git worktree list fails: names the command" "git worktree list failed" "$guard_err"
has "git worktree list fails: names git's error" "not a git repository" "$guard_err"

check "the ssh bound defaults to 600" "$(env -u boot_ssh_bound bash -c 'source "$1" && echo "$boot_ssh_bound"' _ "$HERE/../vm/guest-os/cachyos-guest-lib.sh")" 600
check "the ssh bound takes the caller's value" "$(boot_ssh_bound=45 bash -c 'source "$1" && echo "$boot_ssh_bound"' _ "$HERE/../vm/guest-os/cachyos-guest-lib.sh")" 45

QMP_OK="rhizo-qmp-selftest-ok.$$" QMP_NO_SCREEN="rhizo-qmp-selftest-noscreen.$$"
python3 - "$HERE/../vm/guest-os" "$QMP_OK" "$QMP_NO_SCREEN" <<'FAKE_EOF' &
import sys, time
sys.path.insert(0, sys.argv[1])
import qmp
qmp.FakeQmp("@" + sys.argv[2]).start()
qmp.FakeQmp("@" + sys.argv[3], screen_error="no display").start()
time.sleep(300)
FAKE_EOF
FAKE_PID=$!
trap 'kill "$FAKE_PID" 2>/dev/null; rm -rf "$SCRATCH"' EXIT
for name in "$QMP_OK" "$QMP_NO_SCREEN"; do
  until ss -xlH | grep -q "@$name"; do
    kill -0 "$FAKE_PID" 2>/dev/null || { echo "the fake QMP server exited before listening on @$name"; exit 1; }
    sleep 0.2
  done
done
BOOT_LOG="$SCRATCH/boot.log"
echo console > "$BOOT_LOG"
# run fail_boot and capture its output
boot_failure() {
  boot_err=$( (qemu_pid=$1 qmp_sock=$2; fail_boot "ssh did not answer in 5s" "$BOOT_LOG") 2>&1 >/dev/null)
  boot_rc=$?
}
boot_failure $$ "@$QMP_OK"
check "a failed boot with a live guest: rc" "$boot_rc" 1
has "a failed boot names the screen it saved" "ssh did not answer in 5s; screen saved to $BOOT_LOG.screen.png" "$boot_err"
check "a failed boot leaves the screen" "$(test -f "$BOOT_LOG.screen.png" && echo 0 || echo 1)" 0
has "a failed boot prints the run state" "qemu status: running" "$boot_err"
has "a failed boot prints each vCPU" "vcpu 1: rip=0xffffffff81e5f0a2 running" "$boot_err"
has "a failed boot prints the console tail after the capture" "last 60 lines of $BOOT_LOG" "$boot_err"
echo old > "$BOOT_LOG.screen.png"
boot_failure $$ "@$QMP_NO_SCREEN"
check "a refused screendump leaves the original failure: rc" "$boot_rc" 1
has "a refused screendump is reported" "the screendump step failed" "$boot_err"
has "a refused screendump says what the capture exited" "the state capture exited 1" "$boot_err"
has "a refused screendump leaves the original failure line" "ssh did not answer in 5s; no screen was saved" "$boot_err"
check "a refused screendump removes the old screen" "$(test -e "$BOOT_LOG.screen.png" && echo 0 || echo 1)" 1
echo old > "$BOOT_LOG.screen.png"
boot_failure $$ "@no-such-qmp.$$"
check "an absent QMP socket leaves the original failure: rc" "$boot_rc" 1
has "an absent QMP socket is reported" "connecting to @no-such-qmp.$$ failed" "$boot_err"
has "an absent QMP socket leaves the original failure line" "ssh did not answer in 5s; no screen was saved" "$boot_err"
check "an absent QMP socket removes the old screen" "$(test -e "$BOOT_LOG.screen.png" && echo 0 || echo 1)" 1
echo old > "$BOOT_LOG.screen.png"
sleep 0 & GONE=$!
wait "$GONE"
boot_failure "$GONE" "@$QMP_OK"
check "a gone qemu: rc" "$boot_rc" 1
has "a gone qemu says there is nothing to read" "qemu pid $GONE is gone" "$boot_err"
has "a gone qemu leaves the original failure line" "ssh did not answer in 5s; no screen was saved" "$boot_err"

check "a gone qemu removes the old screen" "$(test -e "$BOOT_LOG.screen.png" && echo 0 || echo 1)" 1

# run require_socket_path and capture its output
require() {
  socket_err=$(require_socket_path "$1" 2>&1); socket_rc=$?
}
require "$(printf 'x%.0s' $(seq 107))"
check "a 107 byte socket path passes: rc" "$socket_rc" 0
check "a 107 byte socket path passes: silent" "$socket_err" ""
long="$(printf 'x%.0s' $(seq 108))"
require "$long"
check "a 108 byte socket path fails: rc" "$socket_rc" 1
has "a 108 byte socket path fails: names the path" "the socket path $long is 108 bytes" "$socket_err"
require "$(printf 'é%.0s' $(seq 54))"
check "54 two-byte characters are 108 bytes and fail: rc" "$socket_rc" 1
has "54 two-byte characters are 108 bytes and fail: names the length" "is 108 bytes" "$socket_err"

# print the arguments start_guest hands to qemu
guest_args() {
  mkdir -p "$SCRATCH/stub"
  printf '%s\n' '#!/bin/bash' 'echo "$@" > "$STUB_OUT"' > "$SCRATCH/stub/wrapper.sh"
  chmod +x "$SCRATCH/stub/wrapper.sh"
  (rig_qemu_wrapper() { echo "$SCRATCH/stub/wrapper.sh"; }; STUB_OUT="$SCRATCH/args"; export STUB_OUT; start_guest >/dev/null 2>&1)
  cat "$SCRATCH/args"
}
has "the guest cpu defaults to host" "-cpu host -smp" "$(unset RIG_GUEST_CPU; guest_args)"
has "RIG_GUEST_CPU sets the guest cpu" "-cpu host,-avx512f -smp" "$(RIG_GUEST_CPU=host,-avx512f guest_args)"

mkdir -p "$SCRATCH/lockdir"
(cd "$SCRATCH/lockdir" && cachyos_build_lock && [[ -f var/cachyos-dl/build.lock ]] && echo locked-in-var) > "$SCRATCH/lock.out" 2>&1
check "the build lock lives in var/cachyos-dl" "$(cat "$SCRATCH/lock.out")" "locked-in-var"

mkdir -p "$SCRATCH/sshbin"
printf '%s\n' '#!/bin/bash' 'echo "$@" > "$STUB_OUT"' > "$SCRATCH/sshbin/ssh"
chmod +x "$SCRATCH/sshbin/ssh"
(PATH="$SCRATCH/sshbin:$PATH" STUB_OUT="$SCRATCH/ssh.args" ssh_port=22 guest 5 true)
has "guest reads the key from var/vm_key" "-i var/vm_key " "$(cat "$SCRATCH/ssh.args")"

(( FAILED )) && exit 1
echo "the vm-overlay guard, the boot failure capture, the socket path check, the guest cpu, the build lock path and the ssh key path passed $CASES cases"
