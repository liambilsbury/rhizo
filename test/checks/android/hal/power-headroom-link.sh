#!/bin/bash
# test the power HAL's rhizo-headroomd link
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -f "$tmp/headroom_link_test"; rmdir "$tmp"' EXIT
g++ -std=c++17 -Wall -Werror -I src/android/hal/power/src -o "$tmp/headroom_link_test" \
  src/android/hal/power/tests/headroom_link_test.cpp || { echo "FAIL: headroom_link_test.cpp did not build"; exit 1; }
"$tmp/headroom_link_test" || exit 1
for call in 'if (headroom_.Supported()) {' \
            'if (!headroom_.Supported()) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);'; do
  grep -qF "$call" src/android/hal/power/src/power.cpp \
    || { echo "FAIL: power.cpp does not call '$call'"; exit 1; }
done
! grep -qE 'class HeadroomLink|\bEnabled\(\)' src/android/hal/power/src/power.cpp \
  || { echo "FAIL: power.cpp still holds its own headroom link or asks whether it was enabled at start"; exit 1; }
echo "ok   power.cpp asks HeadroomLink whether headroom is supported in getSupportInfo and getCpuHeadroom"
