#!/bin/bash
# test rhizo-deskd authentication order
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit
TOOLS="$(cd "test/checks" && pwd)"
BRIDGE_DIR="${RHIZO_DESKD_DIR:-$(pwd)/src/services/deskbridge}"

WORK=$(mktemp -d)
# kill the deskd process and remove the work directory
cleanup() {
  [[ -n "${DESKD_PID:-}" ]] && kill "$DESKD_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/fake-wlbridge.py" <<'EOF'
#!/usr/bin/env python3
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

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
"$BRIDGE_DIR/deskd.py" --port "$PORT" --token checktoken \
  --bridge "$WORK/fake-wlbridge.py" --bind 127.0.0.1 > "$WORK/deskd.log" 2>&1 &
DESKD_PID=$!
for _ in $(seq 1 40); do grep -q "listening on" "$WORK/deskd.log" 2>/dev/null && break; sleep 0.25; done
grep -q "listening on" "$WORK/deskd.log" 2>/dev/null || {
  echo "check-deskd-auth-order: rhizo-deskd never came up"; cat "$WORK/deskd.log"; exit 1; }

python3 "$TOOLS/services/deskbridge/deskd-auth-order.py" "$PORT"
rc=$?
if (( rc != 0 )); then
  cat "$WORK/deskd.log"
fi
exit $rc
