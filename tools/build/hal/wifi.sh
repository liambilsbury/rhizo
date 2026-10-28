#!/bin/bash
# build rhizo-wifi-service and rhizo-wifi-supplicant into gfx_hal
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")
ONLY="${1:-all}"
case "$ONLY" in all|service|supplicant) ;; *) echo "usage: $0 [all|service|supplicant]" >&2; exit 2 ;; esac

if [[ "$ONLY" != supplicant ]]; then
  tools/build/hal/hal.sh rhizo-wifi-service src/android/hal/wifi/src/wifi.cpp \
    --aidl-src toolchain/gen/wifi/ndk \
    --aidl-src toolchain/gen/wifi_common/ndk \
    --extra-inc toolchain/gen/wifi/header \
    --extra-inc toolchain/gen/wifi_common/header \
    --extra-inc src/android/hal/wifi/include \
    --extra-inc src/android/hal/common/include \
    "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"
fi

if [[ "$ONLY" != service ]]; then
  tools/build/hal/hal.sh rhizo-wifi-supplicant src/android/hal/wifi-supplicant/src/supplicant.cpp \
    --extra-src src/android/hal/wifi-supplicant/src/sta_iface.cpp \
    --aidl-src toolchain/gen/wifi_supplicant/ndk \
    --aidl-src toolchain/gen/wifi_common_v1/ndk \
    --extra-inc toolchain/gen/wifi_supplicant/header \
    --extra-inc toolchain/gen/wifi_common_v1/header \
    --extra-inc src/android/hal/wifi-supplicant/src \
    --extra-inc src/android/hal/wifi/include \
    --extra-inc src/android/hal/wifi/include/rhizo \
    --extra-inc src/android/hal/common/include \
    --extra-inc src/android/hal/common/include/rhizo \
    "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"
fi

if [[ -z "${RHIZO_HAL_ABI:-}" ]]; then
  [[ "$ONLY" != supplicant ]] && { python3 tools/build/stamps.py stamp gfx_hal/rhizo-wifi-service || exit 1; }
  [[ "$ONLY" != service ]] && { python3 tools/build/stamps.py stamp gfx_hal/rhizo-wifi-supplicant || exit 1; }
fi
exit 0
