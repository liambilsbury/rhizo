#!/bin/bash
# build rhizo-headroomd into var/share
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/headroomd/headroomd.c"
CC=gcc
OUT="var/share/rhizo-headroomd"
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  OUT="var/share/rhizo-headroomd-aarch64"
  command -v "$CC" >/dev/null || { echo "[build-headroomd] no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
elif [[ -n "${1:-}" ]]; then
  OUT="$1"
fi
[[ -f "$SRC" ]] || { echo "[build-headroomd] missing $SRC" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
"$CC" -std=gnu11 -O2 -Wall -Wextra -Werror -o "$OUT" "$SRC"
chmod 0755 "$OUT"
echo "[build-headroomd] OK -> $OUT ($(stat -c%s "$OUT") bytes)"

if [[ "$OUT" == var/share/rhizo-headroomd ]]; then ./tools/build/stamps.py stamp rhizo-headroomd; fi
