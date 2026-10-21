#!/bin/bash
# enable or disable rhizo-streamd.socket to match stream.enabled
set -euo pipefail

LIB_DIR="${RHIZO_LIB_DIR:-/usr/lib/rhizo}"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# print enable or disable according to the stream.enabled capability
decide() {
  PYTHONPATH="$LIB_DIR" /usr/bin/python3 -c '
import sys
from sandbox import capabilities as rc
print("enable" if rc.policy_or_deny().allows("stream.enabled") else "disable")
'
}

decision=$(decide)
if (( CHECK_ONLY )); then
  printf '%s\n' "$decision"
  exit 0
fi

systemctl "$decision" --now rhizo-streamd.socket
echo "rhizo-stream-capability-sync: rhizo-streamd.socket $decision""d (stream.enabled)"
again=$(decide)
if [[ "$again" != "$decision" ]]; then
  systemctl "$again" --now rhizo-streamd.socket
  echo "rhizo-stream-capability-sync: policy changed while syncing -- rhizo-streamd.socket $again""d (stream.enabled)"
fi
