#!/bin/bash
# var/share/rhizo-probe-client
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/probe-client/probe-client.c"
CC=gcc
OUT="var/share/rhizo-probe-client"
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  OUT="var/share/rhizo-probe-client-aarch64"
  command -v "$CC" >/dev/null || { echo "no $CC in PATH" >&2; exit 1; }
fi
[[ -f "$SRC" ]] || { echo "no $SRC" >&2; exit 1; }
mkdir -p var/share
"$CC" -O2 -Wall -Wextra -Werror -o "$OUT" "$SRC"
chmod 0755 "$OUT"
echo "wrote $OUT bytes=$(stat -c%s "$OUT")"
file -b "$OUT"
