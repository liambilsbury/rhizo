#!/usr/bin/env bash
# var/share/gfx_hal/rhizo_bpf_preload.so RHIZO_HAL_ABI= RHIZO_HAL_STAGE=
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$ROOT/src/android/hal/bpf-preload/src/bpf_preload.c"
NDK="$ROOT/toolchain/ndk_extract/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64"
CLANG="$NDK/bin/clang"

[ -f "$SRC" ] || { echo "no $SRC" >&2; exit 1; }
[ -x "$CLANG" ] || { echo "no $CLANG" >&2; exit 1; }

TARGET=x86_64-linux-android31 STAGE="$ROOT/var/share/gfx_hal/rhizo_bpf_preload.so" OUT_SUB=""
if [[ "${RHIZO_HAL_ABI:-}" == arm64-v8a ]]; then
  TARGET=aarch64-linux-android31
  STAGE="$ROOT/var/share/${RHIZO_HAL_STAGE:-gfx_hal}/rhizo_bpf_preload.so"
  OUT_SUB="arm64/"
fi

mkdir -p "$ROOT/toolchain/out/${OUT_SUB}bpf_preload"
"$CLANG" --target="$TARGET" -shared -fPIC -O2 \
  -o "$ROOT/toolchain/out/${OUT_SUB}bpf_preload/rhizo_bpf_preload.so" "$SRC"

install -D -m 0755 "$ROOT/toolchain/out/${OUT_SUB}bpf_preload/rhizo_bpf_preload.so" "$STAGE"

echo "staged $STAGE bytes=$(stat -c %s "$STAGE")"
