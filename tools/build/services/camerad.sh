#!/bin/bash
# build rhizo-camerad
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/camerad/camerad.c"
OUT_DIR="var/share"
CC=gcc
ARCH_SUFFIX=""
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  ARCH_SUFFIX="-aarch64"
  command -v "$CC" >/dev/null || { echo "[build-camerad] no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=/
elif [[ -n "${1:-}" ]]; then
  OUT_DIR="$1"
fi
OUT="$OUT_DIR/rhizo-camerad$ARCH_SUFFIX"

pkg-config --exists libpipewire-0.3 || {
  echo "[build-camerad] libpipewire-0.3 dev files missing${ARCH_SUFFIX:+ for arm64 -- dpkg --add-architecture arm64 && apt-get install libpipewire-0.3-dev:arm64} (apt-get install libpipewire-0.3-dev)" >&2
  exit 1
}

# shellcheck disable=SC2046
"$CC" -O2 -Wall -Wextra -o "$OUT" "$SRC" ./src/services/camerad/mjpeg.c \
  -I./src/android/hal/common/include \
  $(pkg-config --cflags --libs libpipewire-0.3) -lpthread

echo "[build-camerad] OK -> $OUT ($(pkg-config --modversion libpipewire-0.3))"

if [[ -z "$ARCH_SUFFIX" && "$OUT_DIR" == var/share ]]; then ./tools/build/stamps.py stamp rhizo-camerad; fi
