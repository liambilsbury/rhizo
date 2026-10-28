#!/bin/bash
# build rhizo-camera-provider-service into gfx_hal
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")
SRC=src/android/hal/camera-provider
META=aosp-android16-qpr2/system/media
[[ -d "$META/camera" ]] || { echo "camera: no AOSP checkout at $META -- run make inputs" >&2; exit 1; }

tools/build/hal/hal.sh rhizo-camera-provider-service "$SRC/src/camera_provider.cpp" \
  --extra-src "$SRC/src/camera_device.cpp" \
  --extra-src "$SRC/src/camera_registry.cpp" \
  --extra-src "$SRC/src/camerad_client.cpp" \
  --extra-src "$SRC/src/frame_output.cpp" \
  --extra-src "$SRC/src/gralloc.cpp" \
  --extra-src "$SRC/src/image_ops.cpp" \
  --extra-src "$SRC/src/log.cpp" \
  --extra-src "$SRC/src/plane_layout.cpp" \
  --extra-src "$SRC/src/session_policy.cpp" \
  --extra-src "$SRC/src/static_metadata.cpp" \
  --extra-src "$META/camera/src/camera_metadata.c" \
  --extra-src src/android/hal/common/libfmq/EventFlag.cpp \
  --extra-src src/android/hal/common/fmq_liblog.cpp \
  --aidl-src toolchain/gen/camera_provider/ndk \
  --aidl-src toolchain/gen/camera_device/ndk \
  --aidl-src toolchain/gen/camera_common/ndk \
  --aidl-src toolchain/gen/camera_metadata/ndk \
  --aidl-src toolchain/gen/gfx_common/ndk \
  --aidl-src toolchain/gen/hw_common/ndk \
  --aidl-src toolchain/gen/fmq/ndk \
  --extra-inc toolchain/gen/camera_provider/header \
  --extra-inc toolchain/gen/camera_device/header \
  --extra-inc toolchain/gen/camera_common/header \
  --extra-inc toolchain/gen/camera_metadata/header \
  --extra-inc toolchain/gen/gfx_common/header \
  --extra-inc toolchain/gen/hw_common/header \
  --extra-inc toolchain/gen/fmq/header \
  --extra-inc toolchain/gfx_aidl_src/mapper/stable-c/include \
  --extra-inc src/android/hal/common/include \
  --extra-inc src/android/hal/common/libfmq/include \
  --extra-inc src/android/hal/common/libfmq/base \
  --extra-inc "$SRC/src" \
  --extra-inc "$META/camera/include" \
  --extra-inc "$META/private/camera/include" \
  "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"

if [[ -z "${RHIZO_HAL_ABI:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-camera-provider-service || exit 1
fi
