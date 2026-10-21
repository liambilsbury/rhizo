#!/bin/bash
# build rhizo-composer and stage it
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(cd "." && pwd)"
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")
STAGE="${RHIZO_HAL_STAGE:-gfx_hal}"

tools/build/hal/hal.sh rhizo-composer src/android/hal/graphics-composer/src/composer.cpp \
  "${ABI_ARGS[@]}" \
  --aidl-src toolchain/gen/composer3/ndk \
  --aidl-src toolchain/gen/gfx_common/ndk \
  --aidl-src toolchain/gen/hw_common/ndk \
  --aidl-src toolchain/gen/fmq/ndk \
  --aidl-src toolchain/gen/drm_common/ndk \
  --aidl-src src/android/hal/graphics-composer/src/wayland \
  --aidl-src src/android/hal/graphics-composer/src/stream \
  --aidl-src src/android/hal/graphics-composer/src/input \
  --aidl wayland \
  --extra-inc src/android/hal/common/include \
  --extra-inc toolchain/wayland-android/include \
  --extra-inc toolchain/wayland-android/protocol-gen \
  --extra-inc toolchain/gen/composer3/header \
  --extra-inc toolchain/gen/gfx_common/header \
  --extra-inc toolchain/gen/hw_common/header \
  --extra-inc toolchain/gen/fmq/header \
  --extra-inc toolchain/gen/drm_common/header \
  --extra-inc toolchain/boringssl_include \
  --so wayland-client \
  --so ffi \
  --so crypto

OUT_SUB=""; [[ "${RHIZO_HAL_ABI:-}" == arm64-v8a ]] && OUT_SUB="arm64/"
install -D -m 0755 "$ROOT/toolchain/out/${OUT_SUB}rhizo-composer" "$ROOT/var/share/$STAGE/rhizo-composer"
if [[ -z "${RHIZO_HAL_ABI:-}" ]]; then
  (cd "$ROOT" && python3 tools/build/stamps.py stamp gfx_hal/rhizo-composer) || exit 1
fi
echo "[build-composer] staged -> var/share/$STAGE/rhizo-composer"
