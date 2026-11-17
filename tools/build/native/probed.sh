#!/bin/bash
# var/share/rhizo-probed RHIZO_HAL_ABI=
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
if [[ -n "${RHIZO_HAL_ABI:-}" ]]; then
  tools/build/hal/hal.sh rhizo-probed src/android/native/probed/probed.cpp --abi "$RHIZO_HAL_ABI"
  install -D -m 0755 toolchain/out/arm64/rhizo-probed "var/share/rhizo-probed-${RHIZO_HAL_ABI}"
  echo "staged var/share/rhizo-probed-${RHIZO_HAL_ABI}"
else
  tools/build/hal/hal.sh rhizo-probed src/android/native/probed/probed.cpp
  tools/build/stamps.py stamp rhizo-probed
fi
