#!/bin/bash
# test newline injection through rhizo-deskd
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit
TOOLS="$(cd "test/checks" && pwd)"
BRIDGE_DIR="$(cd "src/services/deskbridge" && pwd)"

WORK=$(mktemp -d)
# kill the deskd process and remove the work directory
cleanup() {
  [[ -n "${DESKD_PID:-}" ]] && kill "$DESKD_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/fake-wlbridge.py" <<'EOF'
#!/usr/bin/env python3
"""Stands in for rhizo-wlbridge: records every line handed to it on stdin
(the observation point for a line-protocol injection) into RHIZO_DESKD_RECORD,
then answers the way deskd-notify.sh's fake does for anything it
recognizes."""
import os
import sys

record_path = os.environ["RHIZO_DESKD_RECORD"]
print("ready", flush=True)
with open(record_path, "a") as record:
    for line in sys.stdin:
        line = line.rstrip("\n")
        record.write(line + "\n")
        record.flush()
        if line == "quit":
            break
        if line.startswith("get "):
            print("nodata %s" % line.split(" ", 1)[1], flush=True)
EOF
chmod +x "$WORK/fake-wlbridge.py"

touch "$WORK/wl-lines.log"

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
RHIZO_DESKD_RECORD="$WORK/wl-lines.log" \
"$BRIDGE_DIR/deskd.py" --port "$PORT" --token checktoken \
  --bridge "$WORK/fake-wlbridge.py" --bind 127.0.0.1 > "$WORK/deskd.log" 2>&1 &
DESKD_PID=$!
for _ in $(seq 1 40); do grep -q "listening on" "$WORK/deskd.log" 2>/dev/null && break; sleep 0.25; done
grep -q "listening on" "$WORK/deskd.log" 2>/dev/null || {
  echo "check-deskd-line-injection: rhizo-deskd never came up"; cat "$WORK/deskd.log"; exit 1; }

python3 "$TOOLS/services/deskbridge/deskd-line-injection.py" "$PORT" "$WORK" "$WORK/wl-lines.log"
rc=$?

if (( rc != 0 )); then
  cat "$WORK/deskd.log"
fi
exit $rc
