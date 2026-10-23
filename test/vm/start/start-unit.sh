#!/bin/bash
# start one of rhizo's host daemons in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

UNITS=$(cat <<'TABLE'
displayd	rhizo-displayd.service	watching .*for scale changes	-	displayd host side up, watching for the composer's scale announcements
keymapd	rhizo-keymapd.service	watching .*for host keymap changes	libxkbcommon.so.0	keymapd host side up, watching for the composer's keymap announcements
TABLE
)

NAME="${1:-}"
ROW=$(awk -F'\t' -v n="$NAME" '$1 == n' <<<"$UNITS")
[[ -n "$NAME" && -n "$ROW" ]] || { echo "usage: start-unit.sh <$(cut -f1 <<<"$UNITS" | paste -sd'|')>" >&2; exit 2; }
IFS=$'\t' read -r _ UNIT READY NEEDS UP_LINE <<<"$ROW"
LOG=/var/log/rhizo/rhizo-$NAME.log

SANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"
if [[ "$SANDBOX_ID" != 0 ]]; then
  log "FAIL: RHIZO_SANDBOX_ID=$SANDBOX_ID -- $UNIT is instance-0-only: nothing started"
  exit 1
fi

wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }

if [[ "$NEEDS" != - ]]; then
  ssh_vm -t 10 "python3 -c \"import ctypes; ctypes.CDLL('$NEEDS')\"" \
    || { log "FAIL: $NEEDS not loadable in the guest"; exit 1; }
fi

if [[ "${RHIZO_TEST_INSTALLED:-0}" == 1 ]]; then
  log "RHIZO_TEST_INSTALLED=1: restarting the installed $UNIT as packaged, staging nothing from this tree"
else
  timeout 20 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "../../../src/services/$NAME/$NAME.py" "$SSH_TARGET:/root/" \
    || { log "FAIL: could not copy $NAME.py into the guest"; exit 1; }
  ssh_vm -t 10 "install -d -m 0755 /usr/lib/rhizo/$NAME && install -m 0755 /root/$NAME.py /usr/lib/rhizo/$NAME/$NAME.py" \
    || { log "FAIL: could not stage rhizo-$NAME at its packaged path"; exit 1; }

  ssh_vm -t 10 "install -m 0644 /root/share/$UNIT /etc/systemd/system/$UNIT" \
    || { log "FAIL: could not install $UNIT -- run test/vm/sync.sh first"; exit 1; }
fi

log "Starting $UNIT..."
start_cmd="mkdir -p /var/log/rhizo
systemctl daemon-reload
systemctl stop $UNIT 2>/dev/null
systemctl reset-failed $UNIT 2>/dev/null || true
: > $LOG
systemctl restart $UNIT
for i in 1 2 3 4 5 6 7 8 9 10; do
  grep -q \"$READY\" $LOG && break
  sleep 1
done
grep -q \"$READY\" $LOG && echo UNIT_UP
[ \"\$(systemctl is-active $UNIT)\" = active ] && echo UNIT_ACTIVE"
out=$(ssh_vm -t 25 "$start_cmd" 2>&1); echo "$out"
if ! grep -q UNIT_UP <<<"$out"; then
  log "FAIL: rhizo-$NAME did not reach its watch loop"
  ssh_vm -t 8 "tail -30 $LOG" >&2
  exit 1
fi
if ! grep -q UNIT_ACTIVE <<<"$out"; then
  log "FAIL: rhizo-$NAME logged its watch loop but $UNIT is not active"
  ssh_vm -t 8 "systemctl status $UNIT --no-pager -l" >&2
  exit 1
fi
log "$UP_LINE"
