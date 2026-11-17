#!/bin/bash
# AES-only rhizo-keymint-service build
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

tools/build/hal/hal.sh rhizo-keymint-service src/android/hal/keymint/src/keymint.cpp \
  --aidl-src toolchain/gen/ndk \
  --extra-inc toolchain/boringssl_include \
  --so crypto

echo "rhizo-keymint-service returns UNSUPPORTED_ALGORITHM for RSA, EC, HMAC and private key import"
