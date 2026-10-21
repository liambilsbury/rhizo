#!/bin/bash
# build and stage rhizo-power-service
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")

tools/build/hal/hal.sh rhizo-power-service src/android/hal/power/src/power.cpp \
  --aidl-src toolchain/gen/power/ndk \
  --aidl-src toolchain/gen/fmq/ndk \
  --aidl-src toolchain/gen/hw_common/ndk \
  --extra-inc toolchain/gen/power/header \
  --extra-inc toolchain/gen/fmq/header \
  --extra-inc toolchain/gen/hw_common/header \
  "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"

if [[ -z "${RHIZO_HAL_ABI:-}" && -z "${RHIZO_HAL_STAGE:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-power-service || exit 1
fi
