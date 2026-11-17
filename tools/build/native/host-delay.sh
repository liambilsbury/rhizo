#!/bin/bash
# var/share/rhizo-host-delay RHIZO_HAL_ABI=
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC=src/android/native/host-delay
PERFETTO_INC=aosp-android16-qpr2/external/perfetto/include
[[ -f var/share/gsi_libs/libperfetto_c.so ]] || { echo "no var/share/gsi_libs/libperfetto_c.so" >&2; exit 1; }
[[ -d "$PERFETTO_INC/perfetto/public" ]] || { echo "no $PERFETTO_INC/perfetto/public" >&2; exit 1; }
ARGS=(rhizo-host-delay "$SRC/host_delay.c"
      --extra-src "$SRC/hd_core.c" --extra-src "$SRC/hd_pb.c"
      --extra-inc "$PERFETTO_INC"
      --so perfetto_c)
if [[ -n "${RHIZO_HAL_ABI:-}" ]]; then
  tools/build/hal/hal.sh "${ARGS[@]}" --abi "$RHIZO_HAL_ABI"
  install -D -m 0755 toolchain/out/arm64/rhizo-host-delay "var/share/rhizo-host-delay-${RHIZO_HAL_ABI}"
  echo "staged var/share/rhizo-host-delay-${RHIZO_HAL_ABI}"
else
  tools/build/hal/hal.sh "${ARGS[@]}"
  tools/build/stamps.py stamp rhizo-host-delay
fi
