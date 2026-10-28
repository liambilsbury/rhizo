#!/bin/bash
# build rhizo-delayd into var/share
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/delayd/delayd.c"
CC=gcc
OUT="var/share/rhizo-delayd"
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  OUT="var/share/rhizo-delayd-aarch64"
  command -v "$CC" >/dev/null || { echo "[build-delayd] no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
elif [[ -n "${1:-}" ]]; then
  OUT="$1"
fi
[[ -f "$SRC" ]] || { echo "[build-delayd] missing $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
"$CC" -std=gnu11 -O2 -Wall -Wextra -Werror -o "$OUT" "$SRC"
chmod 0755 "$OUT"
echo "[build-delayd] OK -> $OUT ($(stat -c%s "$OUT") bytes)"

if [[ "$OUT" == var/share/rhizo-delayd ]]; then ./tools/build/stamps.py stamp rhizo-delayd; fi
