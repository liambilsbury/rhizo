#!/bin/bash
# test the composer's mapping of Android pointer types to host cursor shapes
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
if ! g++ -std=c++17 -Wall -Werror -I src/android/hal/graphics-composer/src/input \
    -o "$tmp/pointer_icon_test" src/android/hal/graphics-composer/tests/pointer_icon_test.cpp; then
  echo "FAIL: pointer_icon_test.cpp did not build"
  exit 1
fi
"$tmp/pointer_icon_test"
