#!/bin/bash
# build rhizo-audio-core-service and stage it
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(cd "." && pwd)"
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")
STAGE="${RHIZO_HAL_STAGE:-gfx_hal}"

tools/build/hal/hal.sh rhizo-audio-core-service \
  src/android/hal/audio-core/src/audio_core.cpp \
  "${ABI_ARGS[@]}" \
  --aidl-src toolchain/gen/audio_core/ndk \
  --aidl-src toolchain/gen/audio_common_hal/ndk \
  --aidl-src toolchain/gen/audio_common_types/ndk \
  --aidl-src toolchain/gen/audio_effect/ndk \
  --aidl-src toolchain/gen/audio_eraser/ndk \
  --aidl-src toolchain/gen/fmq/ndk \
  --aidl-src toolchain/gen/hw_common/ndk \
  --extra-inc toolchain/gen/audio_core/header \
  --extra-inc toolchain/gen/audio_common_hal/header \
  --extra-inc toolchain/gen/audio_common_types/header \
  --extra-inc toolchain/gen/audio_effect/header \
  --extra-inc toolchain/gen/audio_eraser/header \
  --extra-inc toolchain/gen/fmq/header \
  --extra-inc toolchain/gen/hw_common/header \
  --extra-inc src/android/hal/common/libfmq/include \
  --extra-inc src/android/hal/common/libfmq/base \
  --extra-src src/android/hal/common/libfmq/EventFlag.cpp \
  --extra-src src/android/hal/common/fmq_liblog.cpp

OUT_SUB=""; [[ "${RHIZO_HAL_ABI:-}" == arm64-v8a ]] && OUT_SUB="arm64/"
install -D -m 0755 "$ROOT/toolchain/out/${OUT_SUB}rhizo-audio-core-service" \
  "$ROOT/var/share/$STAGE/rhizo-audio-core-service"
echo "[build-audio] staged -> var/share/$STAGE/rhizo-audio-core-service"

if [[ -z "${RHIZO_HAL_ABI:-}" && -z "${RHIZO_HAL_STAGE:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-audio-core-service || exit 1
fi
