#!/bin/bash
# build mapper.rhizo.so for ABIs
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

COMMON_ARGS=(
  src/android/hal/gralloc-mapper/src/mapper.cpp
  --extra-inc src/android/hal/common/include
  --extra-inc toolchain/gfx_aidl_src/mapper/stable-c/include
  --extra-inc toolchain/gfx_aidl_src/mapper/stable-c/implutils/include
  --shared
  --so cutils --so log
)

if [[ -n "${RHIZO_HAL_ABI:-}" ]]; then
  tools/build/hal/hal.sh mapper.rhizo.so "${COMMON_ARGS[@]}" --abi "$RHIZO_HAL_ABI" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"
  echo "[build-mapper] --abi $RHIZO_HAL_ABI set -- skipping the 32-bit (x86) companion"
else
  tools/build/hal/hal.sh mapper.rhizo.so "${COMMON_ARGS[@]}" --stage gfx_hal
  tools/build/hal/hal.sh mapper.rhizo.so "${COMMON_ARGS[@]}" --abi x86 --stage gfx_hal_32
fi

if [[ -z "${RHIZO_HAL_ABI:-}" && -z "${RHIZO_HAL_STAGE:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/mapper.rhizo.so || exit 1
  python3 tools/build/stamps.py stamp gfx_hal_32/mapper.rhizo.so || exit 1
fi
