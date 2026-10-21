#!/bin/bash
# build rt-victim and rt-load
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
mkdir -p var/share
gcc -O2 -Wall -Wextra -Werror -o var/share/rt-victim test/system/src/rt-victim.c
gcc -O2 -Wall -Wextra -Werror -o var/share/rt-load test/system/src/rt-load.c
chmod 0755 var/share/rt-victim var/share/rt-load

./tools/build/stamps.py stamp rt-victim
./tools/build/stamps.py stamp rt-load

echo "[build-rt-tools] OK -> var/share/rt-victim, var/share/rt-load"
