#!/bin/bash
# build rhizo-thermal-service into gfx_hal
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")

tools/build/hal/hal.sh rhizo-thermal-service src/android/hal/thermal/src/thermal.cpp \
  --aidl-src toolchain/gen/thermal/ndk \
  --extra-inc toolchain/gen/thermal/header \
  --extra-inc src/android/hal/common/include \
  "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"

if [[ -z "${RHIZO_HAL_ABI:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-thermal-service || exit 1
fi
