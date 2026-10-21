#!/bin/bash
# build rhizo-hostfsd into var/share
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit
SRC="./src/services/hostfs/hostfsd.c"
CC=gcc
OUT="var/share/rhizo-hostfsd"
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  OUT="var/share/rhizo-hostfsd-aarch64"
  command -v "$CC" >/dev/null || { echo "build-hostfsd: no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
elif [[ -n "${1:-}" ]]; then
  OUT="$1"
fi

[[ -f "$SRC" ]] || { echo "build-hostfsd: missing $SRC" >&2; exit 1; }

[[ -f /usr/include/linux/fuse.h ]] || {
  echo "build-hostfsd: /usr/include/linux/fuse.h not found -- need the kernel FUSE UAPI header" >&2
  exit 1
}

mkdir -p "$(dirname "$OUT")"

"$CC" -std=c11 -O2 -Wall -Wextra -o "$OUT" "$SRC"
rc=$?
if [[ $rc -ne 0 ]]; then
  echo "build-hostfsd: compile failed (gcc exit $rc)" >&2
  exit 1
fi

chmod 0755 "$OUT"
echo "built $OUT ($(stat -c%s "$OUT") bytes)"
file -b "$OUT"

fuse_minor=$(awk '/#define FUSE_KERNEL_MINOR_VERSION/ {print $3}' /usr/include/linux/fuse.h)
fuse_major=$(awk '/#define FUSE_KERNEL_VERSION/ {print $3}' /usr/include/linux/fuse.h)
echo "build host's /usr/include/linux/fuse.h: FUSE_KERNEL_VERSION=$fuse_major FUSE_KERNEL_MINOR_VERSION=$fuse_minor"
