#!/bin/bash
# var/share/rhizo-audiod var/share/rhizo-audiod-loadclient
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/audiod/audiod.c"
OUT_DIR="var/share"
CC=gcc
ARCH_SUFFIX=""
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  ARCH_SUFFIX="-aarch64"
  command -v "$CC" >/dev/null || { echo "no $CC in PATH" >&2; exit 1; }
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=/
elif [[ -n "${1:-}" ]]; then
  OUT_DIR="$1"
fi
OUT="$OUT_DIR/rhizo-audiod$ARCH_SUFFIX"
CLIENT_SRC="./src/services/audiod/loadclient.c"
CLIENT_OUT="$OUT_DIR/rhizo-audiod-loadclient"

pkg-config --exists libpipewire-0.3 || {
  echo "pkg-config --exists libpipewire-0.3 failed${ARCH_SUFFIX:+ for arm64}" >&2
  exit 1
}

# shellcheck disable=SC2046
"$CC" -O2 -Wall -Wextra -o "$OUT" "$SRC" \
  $(pkg-config --cflags --libs libpipewire-0.3) -lpthread

echo "wrote $OUT (libpipewire-0.3 $(pkg-config --modversion libpipewire-0.3))"

if [[ -n "$ARCH_SUFFIX" ]]; then
  exit 0
fi

if [[ "$OUT_DIR" == var/share ]]; then ./tools/build/stamps.py stamp rhizo-audiod; fi

gcc -O2 -Wall -Wextra -o "$CLIENT_OUT" "$CLIENT_SRC"
echo "wrote $CLIENT_OUT"
