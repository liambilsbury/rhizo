#!/bin/bash
# build rhizo-host-delay against libperfetto_c.so
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC=src/android/native/host-delay
PERFETTO_INC=aosp-android16-qpr2/external/perfetto/include
[[ -f var/share/gsi_libs/libperfetto_c.so ]] || { echo "[build-host-delay] no gsi_libs/libperfetto_c.so -- run tools/build/image/extract-gsi-libs.sh" >&2; exit 1; }
[[ -d "$PERFETTO_INC/perfetto/public" ]] || { echo "[build-host-delay] no $PERFETTO_INC -- run tools/fetch/build-inputs.sh" >&2; exit 1; }
ARGS=(rhizo-host-delay "$SRC/host_delay.c"
      --extra-src "$SRC/hd_core.c" --extra-src "$SRC/hd_pb.c"
      --extra-inc "$PERFETTO_INC"
      --so perfetto_c)
if [[ -n "${RHIZO_HAL_ABI:-}" ]]; then
  tools/build/hal/hal.sh "${ARGS[@]}" --abi "$RHIZO_HAL_ABI"
  install -D -m 0755 toolchain/out/arm64/rhizo-host-delay "var/share/rhizo-host-delay-${RHIZO_HAL_ABI}"
  echo "[build-host-delay] staged -> var/share/rhizo-host-delay-${RHIZO_HAL_ABI}"
else
  tools/build/hal/hal.sh "${ARGS[@]}"
  tools/build/stamps.py stamp rhizo-host-delay
fi
