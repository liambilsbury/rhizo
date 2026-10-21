#!/bin/bash
# test the power HAL's rhizo-rtd link
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
g++ -std=c++17 -Wall -Werror -I src/android/hal/power/src -o "$tmp/rtd_link_test" \
  src/android/hal/power/tests/rtd_link_test.cpp || { echo "FAIL: rtd_link_test.cpp did not build"; exit 1; }
"$tmp/rtd_link_test" || exit 1
for call in 'if (!rtd_.TryConnect()) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);' \
            'out->usesSessions = rtd_.TryConnect();'; do
  grep -qF "$call" src/android/hal/power/src/power.cpp \
    || { echo "FAIL: power.cpp does not call '$call'"; exit 1; }
done
[[ $(grep -cF 'if (!rtd_.TryConnect()) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);' \
  src/android/hal/power/src/power.cpp) == 2 ]] \
  || { echo "FAIL: createHintSession and createHintSessionWithConfig do not both try the link before refusing"; exit 1; }
! grep -qE '\bConnected\(\)|->Send\(|rtd_\.Send\(' src/android/hal/power/src/power.cpp \
  || { echo "FAIL: power.cpp still reads the link state or sends past RtdLink's session calls"; exit 1; }
echo "ok   power.cpp tries the link in both session creators and getSupportInfo, and sends only through RtdLink's session calls"
