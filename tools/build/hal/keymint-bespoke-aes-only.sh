#!/bin/bash
# build the AES-only rhizo-keymint-service
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

tools/build/hal/hal.sh rhizo-keymint-service src/android/hal/keymint/src/keymint.cpp \
  --aidl-src toolchain/gen/ndk \
  --extra-inc toolchain/boringssl_include \
  --so crypto

echo "[build-keymint-bespoke-aes-only] staged -> var/bin/rhizo-keymint-service and var/share/rhizo-keymint-service"
echo "[build-keymint-bespoke-aes-only] WARNING: this is the AES-only fallback -- RSA/EC/HMAC/private-key-import will UNSUPPORTED_ALGORITHM. Use keymint.sh for the real port."
