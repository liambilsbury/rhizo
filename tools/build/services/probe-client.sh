#!/bin/bash
# build rhizo-probe-client with gcc
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/probe-client/probe-client.c"
CC=gcc
OUT="var/share/rhizo-probe-client"
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  OUT="var/share/rhizo-probe-client-aarch64"
  command -v "$CC" >/dev/null || { echo "build-probe-client: no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
fi
[[ -f "$SRC" ]] || { echo "build-probe-client: missing $SRC" >&2; exit 1; }
mkdir -p var/share
"$CC" -O2 -Wall -Wextra -Werror -o "$OUT" "$SRC"
chmod 0755 "$OUT"
echo "built $OUT ($(stat -c%s "$OUT") bytes)"
file -b "$OUT"
