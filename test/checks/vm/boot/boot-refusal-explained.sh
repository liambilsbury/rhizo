#!/bin/bash
# check explain-boot.sh detects a boot refusal
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXPLAIN="$HERE/../vm/boot/explain-boot.sh"
COMMON="$HERE/../vm/common.sh"
[[ -r "$EXPLAIN" && -r "$COMMON" ]] || { echo "FAIL: cannot read explain-boot.sh or common.sh"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SRC="$EXPLAIN"
if (( SELFTEST )); then
  SRC="$TMP/explain-boot.sh"
  python3 - "$EXPLAIN" "$SRC" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
new, n = re.subn(
    r'\n  if _boot_refused_via "\$VAR_DIR/vm-boot\$\{SUFFIX\}\.pid"; then\n.*?\n  fi\n',
    '\n', s, count=1, flags=re.S)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: could not drop the BOOT_REFUSED branch")
open(sys.argv[2], "w").write(new)
PY
  (( $? == 0 )) || exit 1
fi

start=$(grep -n '^qpid=""$' "$SRC" | cut -d: -f1)
end=$(grep -n '^CPU_NOTE=""$' "$SRC" | cut -d: -f1)
[[ -n "$start" && -n "$end" ]] || { echo "FAIL: could not find section 3's bounds in $SRC"; exit 1; }
BLOCK=$(sed -n "${start},$((end - 1))p" "$SRC")
[[ -n "$BLOCK" ]] || { echo "FAIL: section 3 extracted empty"; exit 1; }

( : ) & DEADPID=$!
wait "$DEADPID" 2>/dev/null

# print the cause and message for console text
run_case() {
  printf '%s\n' "$2" > "$TMP/vm-boot-97.log"
  rm -f "$TMP/vm-boot-97.pid"
  (( $1 )) && echo "$DEADPID" > "$TMP/vm-boot-97.pid"
  RHIZO_VM=97 bash -c '
    source "$1" >/dev/null 2>&1
    VAR_DIR="$2"; SUFFIX="-97"
    SSH_PORT=2319
    VM_PIDFILE="$2/vm-97.pid"
    CONSOLE="$2/vm-boot-97.log"
    verdict() { printf "%s\t%s\n" "$1" "$2"; exit 0; }
    eval "$3"
    printf "FELL_THROUGH\t\n"
  ' _ "$COMMON" "$TMP" "$BLOCK"
}

FAILED=0
# print a failure line and mark the check failed
note() { echo "FAIL: $*"; FAILED=1; }

KVM_TEXT='run-vm.sh: /dev/kvm is not readable+writable by tester
  the personal container needs the host to grant it: setfacl -m u:tester:rw /dev/kvm,
  or --device /dev/kvm in the container'"'"'s own run configuration.'
PORT_TEXT='run-vm.sh: instance 97 already has a guest on port 2319
  a second qemu would lose the port bind, share the disk, and clobber the pidfile.
  kill the existing guest first, or set RHIZO_VM to a free vm.'
GUARD_TEXT='run-vm.sh: refusing to boot vm 97 while the rig is reserved -- wait for the reservation to end'
LIVE_TEXT='[    3.9] systemd[1]: Reached target multi-user.target - Multi-User System.
rhizo-vm login:'

# check the BOOT_REFUSED cause and message text
check_refused() {
  local out cause msg
  out=$(run_case 1 "$2")
  cause=${out%%$'\t'*}; msg=${out#*$'\t'}
  if (( SELFTEST )); then
    [[ "$cause" == BOOT_REFUSED ]] && { echo "SELFTEST FAIL: the reverted defect still explained '$1' as BOOT_REFUSED"; exit 1; }
    return
  fi
  [[ "$cause" == BOOT_REFUSED ]] \
    || note "a refused boot ($1) was explained '$cause', not BOOT_REFUSED"
  [[ "$msg" == *"$3"* ]] \
    || note "BOOT_REFUSED for '$1' did not carry the actionable text '$3' -- it said: $msg"
}

check_refused "no kvm"       "$KVM_TEXT"   'setfacl -m u:tester:rw /dev/kvm'
check_refused "port held"    "$PORT_TEXT"  'set RHIZO_VM to a free vm'
check_refused "boot guard"   "$GUARD_TEXT" 'wait for the reservation to end'

out=$(run_case 0 "$LIVE_TEXT")
cause=${out%%$'\t'*}
if (( SELFTEST )); then
  [[ "$cause" == QEMU_NOT_RUNNING ]] \
    || { echo "SELFTEST FAIL: with the branch reverted the dead-qemu case answered '$cause'"; exit 1; }
  echo "selftest ok: with the BOOT_REFUSED branch dropped, all three refusals fall back to '$cause' and are not detected"
  exit 0
fi
[[ "$cause" == QEMU_NOT_RUNNING ]] \
  || note "a boot whose qemu started and died was explained '$cause', not QEMU_NOT_RUNNING"

(( FAILED )) && exit 1
echo "ok: a refused boot is explained as BOOT_REFUSED and carries the command that fixes it, and a genuinely dead qemu is still QEMU_NOT_RUNNING"
