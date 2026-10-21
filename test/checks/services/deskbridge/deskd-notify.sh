#!/bin/bash
# test the desktop bridge notification path
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit
TOOLS="$(cd "test/checks" && pwd)"
BRIDGE_DIR="$(cd "src/services/deskbridge" && pwd)"

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

for need in dbus-daemon python3; do
  command -v "$need" >/dev/null || { echo "check-deskd-notify: no $need on this host"; exit 1; }
done

WORK=$(mktemp -d)
# kill the test processes and remove the work directory
cleanup() {
  [[ -n "${SINK_PID:-}" ]] && kill "$SINK_PID" 2>/dev/null
  [[ -n "${RELAY_PID:-}" ]] && kill "$RELAY_PID" 2>/dev/null
  [[ -n "${DESKD_PID:-}" ]] && kill "$DESKD_PID" 2>/dev/null
  [[ -n "${FEED_PID:-}" ]] && kill "$FEED_PID" 2>/dev/null
  [[ -n "${BUS_PID:-}" ]] && kill "$BUS_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/fake-wlbridge.py" <<'EOF'
#!/usr/bin/env python3
"""stand in for the Wayland client"""
import sys
print("ready", flush=True)
for line in sys.stdin:
    line = line.strip()
    if line == "quit":
        break
    if line.startswith("get "):
        print("nodata %s" % line.split(" ", 1)[1], flush=True)
EOF
chmod +x "$WORK/fake-wlbridge.py"

busout=$(dbus-daemon --session --fork --print-address=1 --print-pid=1) || {
  echo "check-deskd-notify: dbus-daemon would not start"; exit 1; }
DBUS_SESSION_BUS_ADDRESS=$(printf '%s\n' "$busout" | head -1)
BUS_PID=$(printf '%s\n' "$busout" | tail -1)
export DBUS_SESSION_BUS_ADDRESS

mkfifo "$WORK/sinkin"
sleep 120 > "$WORK/sinkin" &
FEED_PID=$!
"$TOOLS/../system/guest/notify-sink.py" --record "$WORK/notif.jsonl" --icon-dir "$WORK/icons" \
  > "$WORK/sink.out" 2>"$WORK/sink.err" < "$WORK/sinkin" &
SINK_PID=$!
for _ in $(seq 1 40); do grep -q ready "$WORK/sink.out" 2>/dev/null && break; sleep 0.25; done
grep -q ready "$WORK/sink.out" 2>/dev/null || {
  echo "check-deskd-notify: the notification sink never owned the name"; cat "$WORK/sink.err"; exit 1; }

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
touch "$WORK/session.env"
export RHIZO_DESKTOP_SESSION_ENV="$WORK/session.env"
env -u DBUS_SESSION_BUS_ADDRESS "$BRIDGE_DIR/deskd.py" --port "$PORT" --token checktoken \
  --bridge "$WORK/fake-wlbridge.py" --bind 127.0.0.1 --notify-socket "$WORK/notify.sock" > "$WORK/deskd.log" 2>&1 &
DESKD_PID=$!
for _ in $(seq 1 40); do grep -q "notification socket .* bound" "$WORK/deskd.log" 2>/dev/null && break; sleep 0.25; done
"$BRIDGE_DIR/desk-notify.py" --socket "$WORK/notify.sock" > "$WORK/relay.log" 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 40); do grep -q "session bus attached" "$WORK/deskd.log" 2>/dev/null && break; sleep 0.25; done
grep -q "session bus attached" "$WORK/deskd.log" 2>/dev/null || {
  echo "check-deskd-notify: rhizo-deskd did not attach the session bus through rhizo-desk-notify"
  cat "$WORK/deskd.log" "$WORK/relay.log"; exit 1; }

python3 "$TOOLS/services/deskbridge/deskd-notify.py" "$PORT" "$WORK" "$SELFTEST"
rc=$?

if (( SELFTEST )); then
  if (( rc == 0 )); then
    echo "check-deskd-notify --selftest: the comparison PASSED on a corrupted icon"
    exit 1
  fi
  echo "check-deskd-notify --selftest: a corrupted icon fails the comparison"
  exit 0
fi
if (( rc != 0 )); then
  cat "$WORK/deskd.log"
  exit 1
fi

kill "$DESKD_PID" 2>/dev/null; wait "$DESKD_PID" 2>/dev/null
printf '[desktop]\nnotifications = no\n' > "$WORK/policy-off.conf"
OFFPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
RHIZO_POLICY_CONF="$WORK/policy-off.conf" "$BRIDGE_DIR/deskd.py" \
  --port "$OFFPORT" --token checktoken --bridge "$WORK/fake-wlbridge.py" \
  --bind 127.0.0.1 --notify-socket "$WORK/notify-off.sock" > "$WORK/deskd-off.log" 2>&1 &
OFF_PID=$!
for _ in $(seq 1 40); do grep -q "listening on" "$WORK/deskd-off.log" 2>/dev/null && break; sleep 0.25; done
kill "$OFF_PID" 2>/dev/null; wait "$OFF_PID" 2>/dev/null
if ! grep -q "listening on" "$WORK/deskd-off.log"; then
  echo "check-deskd-notify: the withheld-notifications run never started"
  cat "$WORK/deskd-off.log"; exit 1
fi
if grep -q "session bus attached" "$WORK/deskd-off.log"; then
  echo "check-deskd-notify: desktop.notifications was off and the session bus was STILL attached"
  cat "$WORK/deskd-off.log"; exit 1
fi
grep -q "desktop.notifications is off" "$WORK/deskd-off.log" || {
  echo "check-deskd-notify: notifications off but the daemon never said so"
  cat "$WORK/deskd-off.log"; exit 1; }
if [[ -e "$WORK/notify-off.sock" ]]; then
  echo "check-deskd-notify: desktop.notifications was off and the notification socket was STILL bound"
  exit 1
fi
echo "check-deskd-notify: desktop.notifications withheld binds no notification socket and attaches no session bus"
exit 0
