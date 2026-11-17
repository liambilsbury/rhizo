#!/bin/bash
# var/share/rhizo-streamd var/share/rhizo-stream-export-test
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/streamd/streamd.c"
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
OUT="$OUT_DIR/rhizo-streamd$ARCH_SUFFIX"

pkg-config --exists libva libva-drm || {
  echo "pkg-config --exists libva libva-drm failed${ARCH_SUFFIX:+ for arm64}" >&2
  exit 1
}

VA_FLAGS=$(pkg-config --cflags --libs libva libva-drm)

"$CC" -O2 -Wall -Wextra -o "$OUT" "$SRC" \
  -I./src/android/hal/common/include \
  $VA_FLAGS -lpthread

if [[ -n "$ARCH_SUFFIX" ]]; then
  echo "wrote $OUT (libva $(pkg-config --modversion libva))"
  exit 0
fi

gcc -O2 -Wall -Wextra -o "$OUT_DIR/rhizo-stream-export-test" \
  "./src/services/streamd/stream-export-test.c" \
  -I./src/android/hal/common/include \
  $VA_FLAGS

echo "wrote $OUT and $OUT_DIR/rhizo-stream-export-test (libva $(pkg-config --modversion libva))"

if [[ "$OUT_DIR" == var/share ]]; then
  ./tools/build/stamps.py stamp rhizo-streamd
  ./tools/build/stamps.py stamp rhizo-stream-export-test
fi
