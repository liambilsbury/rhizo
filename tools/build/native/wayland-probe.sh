#!/bin/bash
# var/share/rhizo-wayland-probe RHIZO_HAL_ABI=
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
if [[ -n "${RHIZO_HAL_ABI:-}" ]]; then
  tools/build/hal/hal.sh rhizo-wayland-probe src/android/native/wayland-probe/wayland_probe.cpp --abi "$RHIZO_HAL_ABI"
  install -D -m 0755 toolchain/out/arm64/rhizo-wayland-probe "var/share/rhizo-wayland-probe-${RHIZO_HAL_ABI}"
  echo "staged var/share/rhizo-wayland-probe-${RHIZO_HAL_ABI}"
else
  tools/build/hal/hal.sh rhizo-wayland-probe src/android/native/wayland-probe/wayland_probe.cpp
  tools/build/stamps.py stamp rhizo-wayland-probe
fi
