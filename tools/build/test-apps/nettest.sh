#!/bin/bash
# build and stamp rhizo-nettest
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
REPO="$(cd "../../.." && pwd)"

../hal/hal.sh rhizo-nettest "$REPO/test/apps/testapp/native/nettest.c" || exit 1
python3 ../stamps.py stamp rhizo-nettest || exit 1
echo "[build-nettest] staged and stamped rhizo-nettest"
