#!/bin/bash
# build rhizo-graphics-allocator and stage it
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")

tools/build/hal/hal.sh rhizo-graphics-allocator src/android/hal/graphics-allocator/src/allocator.cpp \
  --aidl-src toolchain/gen/allocator/ndk \
  --aidl-src toolchain/gen/gfx_common/ndk \
  --aidl-src toolchain/gen/hw_common/ndk \
  --extra-inc src/android/hal/common/include \
  --extra-inc toolchain/gen/allocator/header \
  --extra-inc toolchain/gen/gfx_common/header \
  --extra-inc toolchain/gen/hw_common/header \
  --extra-inc mesa-src/src/gbm/main \
  --so drm \
  --exact-so libgbm_mesa.so \
  "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"

if [[ -z "${RHIZO_HAL_ABI:-}" && -z "${RHIZO_HAL_STAGE:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-graphics-allocator || exit 1
fi
