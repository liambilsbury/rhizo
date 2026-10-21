#!/bin/bash
# build rhizo-gatekeeper-service into var/share/gfx_hal
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")

tools/build/hal/hal.sh rhizo-gatekeeper-service src/android/hal/gatekeeper/src/gatekeeper.cpp \
  --aidl-src toolchain/gen/gatekeeper/ndk \
  --aidl-src toolchain/gen/ndk \
  --aidl-src toolchain/gen/hw_common/ndk \
  --aidl-src toolchain/gen/sharedsecret/ndk \
  --extra-inc toolchain/gen/gatekeeper/header \
  --extra-inc toolchain/gen/hw_common/header \
  --extra-inc toolchain/gen/sharedsecret/header \
  --extra-inc toolchain/boringssl_include \
  --so crypto \
  "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"

if [[ -z "${RHIZO_HAL_ABI:-}" && -z "${RHIZO_HAL_STAGE:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-gatekeeper-service || exit 1
fi
