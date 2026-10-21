#!/bin/bash
# build rhizo-power-service-a15
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(cd "." && pwd)"

[[ -d "$ROOT/toolchain/gen_a15/power/ndk" ]] || {
  echo "[build-power-a15] toolchain/gen_a15/power/ndk missing -- regenerate the" >&2
  echo "  AIDL glue first (see this script's header comment for the command)." >&2
  exit 1
}

tools/build/hal/hal.sh rhizo-power-service-a15 src/android/hal/power/src/power_a15.cpp \
  --aidl-src toolchain/gen_a15/power/ndk \
  --aidl-src toolchain/gen/fmq/ndk \
  --aidl-src toolchain/gen/hw_common/ndk \
  --extra-inc toolchain/gen_a15/power/header \
  --extra-inc toolchain/gen/fmq/header \
  --extra-inc toolchain/gen/hw_common/header

mkdir -p "$ROOT/var/share/rel/a15"
install -m 0755 "$ROOT/toolchain/out/rhizo-power-service-a15" \
  "$ROOT/var/share/rel/a15/rhizo-power-service"
echo "[build-power-a15] staged -> var/share/rel/a15/rhizo-power-service"
echo "[build-power-a15] (the a16 baseline's var/share/gfx_hal/rhizo-power-service is untouched)"

python3 tools/build/stamps.py stamp rel/a15/rhizo-power-service || exit 1
