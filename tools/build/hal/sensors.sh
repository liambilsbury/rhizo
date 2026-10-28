#!/bin/bash
# build rhizo-sensors-service into gfx_hal
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")
SRC=src/android/hal/sensors

tools/build/hal/hal.sh rhizo-sensors-service "$SRC/src/main.cpp" \
  --extra-src "$SRC/src/Sensors.cpp" \
  --extra-src "$SRC/src/Sensor.cpp" \
  --extra-src "$SRC/src/conf.cpp" \
  --extra-src "$SRC/src/iio_reader.cpp" \
  --extra-src "$SRC/src/iio_sensor.cpp" \
  --extra-src "$SRC/src/log.cpp" \
  --extra-src src/android/hal/common/libfmq/EventFlag.cpp \
  --extra-src src/android/hal/common/fmq_liblog.cpp \
  --aidl-src toolchain/gen/sensors/ndk \
  --aidl-src toolchain/gen/hw_common/ndk \
  --aidl-src toolchain/gen/fmq/ndk \
  --extra-inc toolchain/gen/sensors/header \
  --extra-inc toolchain/gen/hw_common/header \
  --extra-inc toolchain/gen/fmq/header \
  --extra-inc src/android/hal/common/libfmq/include \
  --extra-inc src/android/hal/common/libfmq/base \
  --extra-inc "$SRC/src" \
  "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"

if [[ -z "${RHIZO_HAL_ABI:-}" ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-sensors-service || exit 1
fi
