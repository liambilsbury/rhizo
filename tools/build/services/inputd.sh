#!/bin/bash
# build rhizo-inputd into var/share
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit
SRC="./src/services/inputd/inputd.c"
CC=gcc
OUT="var/share/rhizo-inputd"
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  OUT="var/share/rhizo-inputd-aarch64"
  command -v "$CC" >/dev/null || { echo "build-inputd: no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
elif [[ -n "${1:-}" ]]; then
  OUT="$1"
fi
[[ -f "$SRC" ]] || { echo "build-inputd: missing $SRC" >&2; exit 1; }
for h in linux/fuse.h linux/uinput.h linux/uhid.h linux/seccomp.h; do
  [[ -f "/usr/include/$h" ]] || { echo "build-inputd: /usr/include/$h not found -- need the kernel UAPI headers" >&2; exit 1; }
done
mkdir -p "$(dirname "$OUT")"
if ! "$CC" -std=c11 -O2 -Wall -Wextra -Werror -o "$OUT" "$SRC"; then
  echo "build-inputd: compile failed" >&2
  exit 1
fi
chmod 0755 "$OUT"
echo "built $OUT ($(stat -c%s "$OUT") bytes)"
