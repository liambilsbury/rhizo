#!/bin/sh
# check the capability policy for a unit
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
# print the usage line and exit with status 255
usage() { echo "usage: $0 <capability> | --any <capability>..." >&2; exit 255; }
if [ "${1:-}" = --any ]; then
  shift
  [ $# -ge 1 ] || usage
else
  [ $# -eq 1 ] || usage
fi
CAPS_DIR="$HERE/.."
[ -f "$CAPS_DIR/sandbox/capabilities.py" ] || CAPS_DIR="$HERE"
exec env PYTHONPATH="$CAPS_DIR" python3 -c '
import sys
from sandbox import capabilities as rc
names = sys.argv[1:]
unknown = [n for n in names if n not in rc.CAPABILITIES]
if unknown:
    print("unknown capability %s" % ", ".join(unknown), file=sys.stderr)
    sys.exit(255)
policy = rc.policy_or_deny(log=lambda m: print(m, file=sys.stderr))
sys.exit(0 if any(policy.allows(n) for n in names) else 1)
' "$@"
