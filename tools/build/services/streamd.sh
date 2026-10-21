#!/bin/bash
# build rhizo-streamd into var/share
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/streamd/streamd.c"
OUT_DIR="var/share"
CC=gcc
ARCH_SUFFIX=""
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  ARCH_SUFFIX="-aarch64"
  command -v "$CC" >/dev/null || { echo "[build-streamd] no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=/
elif [[ -n "${1:-}" ]]; then
  OUT_DIR="$1"
fi
OUT="$OUT_DIR/rhizo-streamd$ARCH_SUFFIX"

pkg-config --exists libva libva-drm || {
  echo "[build-streamd] libva-dev missing${ARCH_SUFFIX:+ for arm64 -- dpkg --add-architecture arm64 && apt-get install libva-dev:arm64 libva-drm2:arm64} (apt-get install libva-dev)" >&2
  exit 1
}

VA_FLAGS=$(pkg-config --cflags --libs libva libva-drm)

"$CC" -O2 -Wall -Wextra -o "$OUT" "$SRC" \
  -I./src/android/hal/common/include \
  $VA_FLAGS -lpthread

if [[ -n "$ARCH_SUFFIX" ]]; then
  echo "[build-streamd] OK -> $OUT ($(pkg-config --modversion libva)) -- arm64 daemon only"
  exit 0
fi

gcc -O2 -Wall -Wextra -o "$OUT_DIR/rhizo-stream-export-test" \
  "./src/services/streamd/stream-export-test.c" \
  -I./src/android/hal/common/include \
  $VA_FLAGS

pkg-config --exists gbm || {
  echo "[build-streamd] libgbm-dev missing (apt-get install libgbm-dev)" >&2
  exit 1
}
# shellcheck disable=SC2046
gcc -O2 -Wall -Wextra -o "$OUT_DIR/rhizo-stream-export-verify" \
  "./src/services/streamd/stream-export-verify.c" \
  -I./src/android/hal/common/include \
  $(pkg-config --cflags --libs gbm)

echo "[build-streamd] OK -> $OUT, $OUT_DIR/rhizo-stream-export-test and $OUT_DIR/rhizo-stream-export-verify ($(pkg-config --modversion libva))"

if [[ "$OUT_DIR" == var/share ]]; then
  ./tools/build/stamps.py stamp rhizo-streamd
  ./tools/build/stamps.py stamp rhizo-stream-export-test
  ./tools/build/stamps.py stamp rhizo-stream-export-verify
fi
