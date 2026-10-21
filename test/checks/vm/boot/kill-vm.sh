#!/bin/bash
# test kill_vm against held ssh ports
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d) || exit 1
HELD=""
# kill the fixture processes and remove the temporary directory
cleanup() {
  local p
  for p in $HELD; do kill -9 "$p" 2>/dev/null; done
  for p in $(lsof -t -i ":${PORT:-0}" -sTCP:LISTEN 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/test/vm/rig" "$TMP/src/androidd/host" "$TMP/var"
cp "$TOOLS/../vm/common.sh" "$TMP/test/vm/common.sh"
cp "$TOOLS/../vm/rig/hooks.sh" "$TMP/test/vm/rig/hooks.sh"
cp "$TOOLS/../../src/androidd/host/parse-display-list.sh" "$TMP/src/androidd/host/parse-display-list.sh"

PORT=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
export XDG_RUNTIME_DIR="$TMP"
export RHIZO_VM=2
export RHIZO_PORT_OFFSET=$((PORT - 2224))
source "$TMP/test/vm/common.sh"

bad=0
# print a failure line and mark the check failed
note() { echo "check-kill-vm: $*"; bad=1; }

[[ "$SSH_PORT" == "$PORT" ]] || { echo "FAIL: fixture is on port $PORT, kill_vm on $SSH_PORT"; exit 1; }
[[ "$REPO" == "$TMP" ]] || { echo "FAIL: REPO is $REPO, not the fixture's"; exit 1; }

if (( SELFTEST )); then
  kill_vm() {
    local pid; pid=$(cat "$VM_PIDFILE" 2>/dev/null)
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
    rm -f "$VM_PIDFILE"
    local one; one=$(lsof -t -i ":$SSH_PORT" -sTCP:LISTEN 2>/dev/null | head -1)
    [[ -n "$one" ]] && kill -9 "$one" 2>/dev/null
    log "VM (instance $RHIZO_VM) confirmed dead"
    return 0
  }
fi

# start a python listener on the ssh port
start_listener() {
  python3 -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(1)
while True:
    c, _ = s.accept()
    c.close()
' "$PORT" "$@" >/dev/null 2>&1 &
  HELD="$HELD $!"
  disown "$!"
  echo "$!"
}

# fork a listener and rebind the port
start_surviving_listener() {
  python3 -c '
import os, socket, sys
port = int(sys.argv[1])
def hold():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(1)
    while True:
        c, _ = s.accept()
        c.close()
if os.fork() == 0:
    hold()
os.wait()
hold()
' "$PORT" >/dev/null 2>&1 &
  HELD="$HELD $!"
  disown "$!"
  echo "$!"
}

# return success when a process listens on the port
port_held() { [[ -n "$(lsof -t -i ":$PORT" -sTCP:LISTEN 2>/dev/null)" ]]; }

# poll the port for held or free
await_port() {
  local want="$1"
  for _ in $(seq 1 50); do
    if [[ "$want" == held ]]; then port_held && return 0; else port_held || return 0; fi
    sleep 0.2
  done
  return 1
}

# return the pid of an exited process
dead_pid() {
  local p
  sh -c 'exit 0' & p=$!
  wait "$p" 2>/dev/null
  echo "$p"
}

# kill the port listeners and fail the check unless the port frees
free_port_or_die() {
  local p
  for p in $(lsof -t -i ":$PORT" -sTCP:LISTEN 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
  await_port free || { echo "FAIL: port $PORT stayed held between cases"; exit 1; }
}

guest=$(start_listener)
await_port held || { echo "FAIL: fixture listener never bound port $PORT"; exit 1; }
echo "$(dead_pid)" > "$VM_PIDFILE"
out=$(kill_vm 2>&1); rc=$?
kill -0 "$guest" 2>/dev/null && note "a leftover pidfile left the vm's live guest ($guest) running"
[[ -f "$VM_PIDFILE" ]] && note "the leftover pidfile survived teardown"
grep -q "removing leftover $VM_PIDFILE" <<<"$out" || note "the leftover pidfile went without being named"
(( rc == 0 )) || note "teardown of a killable guest returned $rc"
free_port_or_die

survivor=$(start_surviving_listener)
await_port held || { echo "FAIL: fixture listener never bound port $PORT"; exit 1; }
echo "$(dead_pid)" > "$VM_PIDFILE"
out=$(kill_vm 2>&1); rc=$?
if port_held; then
  (( rc == 0 )) && note "teardown returned 0 while port $PORT was still held"
  grep -q 'confirmed dead' <<<"$out" && note "teardown reported dead while port $PORT was still held"
else
  note "the fixture's surviving holder is not surviving"
fi
kill -9 "$survivor" 2>/dev/null
free_port_or_die

guest=$(start_listener "hostfwd=tcp:127.0.0.1:$PORT-:22")
await_port held || { echo "FAIL: fixture listener never bound port $PORT"; exit 1; }
echo "$guest" > "$VM_PIDFILE"
out=$(kill_vm 2>&1); rc=$?
kill -0 "$guest" 2>/dev/null && note "a live, correct pidfile's qemu ($guest) survived teardown"
[[ -f "$VM_PIDFILE" ]] && note "a killed guest's pidfile was left behind"
grep -q 'leftover' <<<"$out" && note "a live, correct pidfile was called leftover"
(( rc == 0 )) || note "teardown of a live, correct pidfile returned $rc"
free_port_or_die

sleep 30 & foreign=$!
disown "$foreign"
HELD="$HELD $foreign"
echo "$foreign" > "$VM_PIDFILE"
out=$(kill_vm 2>&1); rc=$?
kill -0 "$foreign" 2>/dev/null || note "teardown killed pid $foreign, which was not this vm's qemu"
[[ -f "$VM_PIDFILE" ]] && note "a pidfile naming somebody else's process survived teardown"
(( rc == 0 )) || note "teardown returned $rc with nothing of this vm's running"
kill -9 "$foreign" 2>/dev/null

sleep 30 & bystander=$!
disown "$bystander"
HELD="$HELD $bystander"
rm -f "$VM_PIDFILE"
out=$(kill_vm 2>&1); rc=$?
(( rc == 0 )) || note "teardown of an empty vm returned $rc"
grep -q 'confirmed dead' <<<"$out" || note "teardown of an empty vm did not report it dead"
kill -0 "$bystander" 2>/dev/null || note "teardown of an empty vm killed pid $bystander"
kill -9 "$bystander" 2>/dev/null

if (( SELFTEST )); then
  (( bad )) && { echo "check-kill-vm --selftest: the pre-fix teardown was caught"; exit 0; }
  echo "check-kill-vm --selftest: teardown that never reads the port back passed the assertions"
  exit 1
fi
(( bad )) && exit 1
echo "check-kill-vm: a leftover pidfile does not hide a live guest, and dead is read off the port"
exit 0
