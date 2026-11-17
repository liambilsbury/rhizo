#!/bin/bash
# var/share/rhizo-delayd
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/delayd/delayd.c"
CC=gcc
OUT="var/share/rhizo-delayd"
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  OUT="var/share/rhizo-delayd-aarch64"
  command -v "$CC" >/dev/null || { echo "no $CC in PATH" >&2; exit 1; }
elif [[ -n "${1:-}" ]]; then
  OUT="$1"
fi
[[ -f "$SRC" ]] || { echo "no $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
"$CC" -std=gnu11 -O2 -Wall -Wextra -Werror -o "$OUT" "$SRC"
chmod 0755 "$OUT"
echo "wrote $OUT bytes=$(stat -c%s "$OUT")"

if [[ "$OUT" == var/share/rhizo-delayd ]]; then ./tools/build/stamps.py stamp rhizo-delayd; fi
