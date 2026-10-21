#!/bin/bash
# start rhizo-streamd in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

TCP_PORT=8555
SOCKET=/run/rhizo-stream/streamd
VERIFY_ONLY=0
VERIFY_DIR=/var/tmp/rhizo-stream-verify
REPORT=$VERIFY_DIR/stream-verify.tsv
DUMP=$VERIFY_DIR/stream-verify-frame.raw
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) TCP_PORT="$2"; shift 2 ;;
    --socket) SOCKET="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    --report) REPORT="$2"; shift 2 ;;
    --dump) DUMP="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"
if [[ "$SANDBOX_ID" != 0 ]]; then
  log "FAIL: RHIZO_SANDBOX_ID=$SANDBOX_ID -- the streaming host side is instance-0-only: nothing started"
  exit 1
fi

REPO="$(cd "../../.." && pwd)"
CAPS_DIR="$REPO/src/androidd"
[[ -f "$CAPS_DIR/sandbox/capabilities.py" ]] || CAPS_DIR="$(pwd)"
policy_err=$(python3 -c "
import sys
sys.path.insert(0, '$CAPS_DIR')
from sandbox import capabilities
sys.exit(0 if capabilities.policy_or_deny().allows('stream.enabled') else 1)
" 2>&1)
if (( $? != 0 )); then
  log "stream.enabled is off${policy_err:+ ($policy_err)} -- not starting rhizo-streamd, no socket directory created"
  exit 0
fi

wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }

guest_mount_share || exit 1

ssh_vm -t 20 "systemctl stop rhizo-stream-capability.path rhizo-streamd.service 2>/dev/null; systemctl disable --now rhizo-streamd.socket 2>/dev/null; systemctl reset-failed rhizo-streamd.socket rhizo-streamd.service 2>/dev/null; true" >/dev/null 2>&1

if (( VERIFY_ONLY )); then
  ssh_vm -t 10 "install -m 0755 /root/share/rhizo-stream-export-verify /usr/local/bin/rhizo-stream-export-verify" \
    || { log "FAIL: could not stage rhizo-stream-export-verify (build it with tools/build/services/streamd.sh)"; exit 1; }
  log "(Re)starting rhizo-stream-export-verify on socket=$SOCKET report=$REPORT dump=$DUMP..."
  verify_cmd="systemctl stop rhizo-stream-verify 2>/dev/null; pkill -9 -f '^/usr/local/bin/rhizo-stream-export-verify' 2>/dev/null; sleep 1
install -d -m 0755 $VERIFY_DIR
rm -f $REPORT $DUMP $DUMP.tmp $VERIFY_DIR/stream-verify.log
install -d -m 0755 $(dirname "$SOCKET")
rm -f $SOCKET
systemctl reset-failed rhizo-stream-verify 2>/dev/null || true
systemd-run --unit=rhizo-stream-verify --collect \
  -p NoNewPrivileges=yes \
  -p StandardOutput=append:$VERIFY_DIR/stream-verify.log -p StandardError=append:$VERIFY_DIR/stream-verify.log \
  /usr/local/bin/rhizo-stream-export-verify --socket $SOCKET --report $REPORT --dump $DUMP \
    --readback-every 1 >/dev/null 2>&1
sleep 2
ls -la $SOCKET"
  out=$(ssh_vm -t 20 "$verify_cmd" 2>&1); echo "$out"
  if ! grep -q "$SOCKET" <<<"$out"; then
    log "FAIL: rhizo-stream-export-verify's socket did not appear"
    ssh_vm -t 8 "tail -20 $VERIFY_DIR/stream-verify.log" >&2
    exit 1
  fi
  log "stream verify-only consumer up: $SOCKET (unit rhizo-stream-verify; SIGUSR1 writes $DUMP)"
  exit 0
fi

log "Ensuring libva + a VA-API driver are installed (idempotent)..."
if ! ssh_vm -t 10 "vainfo >/dev/null 2>&1"; then
  ssh_vm -t 60 "DEBIAN_FRONTEND=noninteractive apt-get install -y libva-utils mesa-va-drivers >/tmp/va-install.log 2>&1" \
    || { log "FAIL: could not install libva-utils/mesa-va-drivers, see /tmp/va-install.log on the guest"; exit 1; }
  ssh_vm -t 10 "vainfo >/dev/null 2>&1" \
    || { log "FAIL: vainfo still fails after install"; ssh_vm -t 8 "vainfo" >&2; exit 1; }
fi
log "libva/VA-API driver present"

ssh_vm -t 10 "install -m 0755 /root/share/rhizo-streamd /usr/local/bin/rhizo-streamd" \
  || { log "FAIL: could not stage rhizo-streamd (build it with tools/build/services/streamd.sh)"; exit 1; }

GUEST_RENDER_NODE=$(ssh_vm -t 15 "bash /root/share/detect-gpu-driver.sh --node 2>/dev/null" 2>/dev/null | cut -d' ' -f1)
[[ "$GUEST_RENDER_NODE" =~ ^/dev/dri/renderD[0-9]+$ ]] \
  || { log "FAIL: the guest's gpu resolver named no render node for rhizo-streamd (got '$GUEST_RENDER_NODE')"; exit 1; }
log "(Re)starting rhizo-streamd on socket=$SOCKET port=$TCP_PORT render node=$GUEST_RENDER_NODE..."
start_cmd="pkill -9 rhizo-streamd 2>/dev/null; sleep 1
install -d -m 0755 $(dirname "$SOCKET")
rm -f $SOCKET
systemctl reset-failed rhizo-streamd 2>/dev/null || true
systemd-run --unit=rhizo-streamd --collect \
  -p NoNewPrivileges=yes \
  -p StandardOutput=file:/tmp/streamd.log -p StandardError=file:/tmp/streamd.log \
  /usr/local/bin/rhizo-streamd --socket $SOCKET --port $TCP_PORT --render-node $GUEST_RENDER_NODE >/dev/null 2>&1
sleep 2
ls -la $SOCKET"
out=$(ssh_vm -t 20 "$start_cmd" 2>&1); echo "$out"
if ! grep -q "$SOCKET" <<<"$out"; then
  log "FAIL: rhizo-streamd socket did not appear"
  ssh_vm -t 8 "tail -20 /tmp/streamd.log" >&2
  exit 1
fi
log "stream host side up: $SOCKET, TCP port $TCP_PORT"
