#!/usr/bin/env bash
# build rhizo_netbpfload_preload for netbpfload
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$ROOT/src/android/hal/netbpfload-preload/src/netbpfload_preload.c"
NDK="$ROOT/toolchain/ndk_extract/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64"
CLANG="$NDK/bin/clang"
OUT="$ROOT/toolchain/out/netbpfload_preload/rhizo_netbpfload_preload"

[ -f "$SRC" ] || { echo "source missing: $SRC" >&2; exit 1; }
[ -x "$CLANG" ] || { echo "NDK clang missing: $CLANG" >&2; exit 1; }

TARGET=x86_64-linux-android31 STAGE="$ROOT/var/share/gfx_hal/rhizo_netbpfload_preload"
if [[ "${RHIZO_HAL_ABI:-}" == arm64-v8a ]]; then
  TARGET=aarch64-linux-android31
  OUT="$ROOT/toolchain/out/arm64/netbpfload_preload/rhizo_netbpfload_preload"
  STAGE="$ROOT/var/share/${RHIZO_HAL_STAGE:-gfx_hal}/rhizo_netbpfload_preload"
fi
mkdir -p "$(dirname "$OUT")"

"$CLANG" --target="$TARGET" -fPIE -pie -O2 -o "$OUT" "$SRC"

install -D -m 0755 "$OUT" "$STAGE"
echo "built and staged $STAGE ($(stat -c %s "$OUT") bytes)"
