#!/bin/bash
# build rhizo-audiod and rhizo-audiod-loadclient
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/audiod/audiod.c"
OUT_DIR="var/share"
CC=gcc
ARCH_SUFFIX=""
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  ARCH_SUFFIX="-aarch64"
  command -v "$CC" >/dev/null || { echo "[build-audiod] no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=/
elif [[ -n "${1:-}" ]]; then
  OUT_DIR="$1"
fi
OUT="$OUT_DIR/rhizo-audiod$ARCH_SUFFIX"
CLIENT_SRC="./src/services/audiod/loadclient.c"
CLIENT_OUT="$OUT_DIR/rhizo-audiod-loadclient"

pkg-config --exists libpipewire-0.3 || {
  echo "[build-audiod] libpipewire-0.3 dev files missing${ARCH_SUFFIX:+ for arm64 -- dpkg --add-architecture arm64 && apt-get install libpipewire-0.3-dev:arm64} (apt-get install libpipewire-0.3-dev)" >&2
  exit 1
}

# shellcheck disable=SC2046
"$CC" -O2 -Wall -Wextra -o "$OUT" "$SRC" \
  $(pkg-config --cflags --libs libpipewire-0.3) -lpthread

echo "[build-audiod] OK -> $OUT ($(pkg-config --modversion libpipewire-0.3))"

if [[ -n "$ARCH_SUFFIX" ]]; then
  echo "[build-audiod] arm64 daemon only"
  exit 0
fi

if [[ "$OUT_DIR" == var/share ]]; then ./tools/build/stamps.py stamp rhizo-audiod; fi

gcc -O2 -Wall -Wextra -o "$CLIENT_OUT" "$CLIENT_SRC"
echo "[build-audiod] OK -> $CLIENT_OUT"
