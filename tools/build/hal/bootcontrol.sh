#!/bin/bash
# build rhizo-bootcontrol-service and stage it
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")

tools/build/hal/hal.sh rhizo-bootcontrol-service src/android/hal/bootcontrol/src/bootcontrol.cpp \
  --aidl-src toolchain/gen/bootcontrol/ndk \
  --extra-inc toolchain/gen/bootcontrol/header \
  "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"

if [[ -z "${RHIZO_HAL_ABI:-}" && -z "${RHIZO_HAL_STAGE:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-bootcontrol-service || exit 1
fi
