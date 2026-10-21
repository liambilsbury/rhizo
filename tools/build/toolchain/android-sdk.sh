#!/bin/bash
# find the Android SDK tools
# shellcheck disable=SC2034

ANDROID_SDK_BUILD_TOOLS_VERSION=34.0.0
ANDROID_SDK_PLATFORM=android-34

# print the Android SDK folder
android_sdk_root() {
  echo "${RHIZO_ANDROID_SDK:-${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}/android-sdk}"
}

# locate the SDK build tools and set their path variables
android_sdk_resolve() {
  local sdk bt tool fetch
  sdk="$(android_sdk_root)"
  bt="$sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION"
  fetch="run tools/fetch/build-inputs.sh --only sdk --accept-android-sdk-license"
  for tool in d8 zipalign apksigner; do
    [[ -x "$bt/$tool" ]] || { echo "android-sdk: no $tool at $bt -- $fetch" >&2; return 1; }
  done
  D8="$bt/d8"; ZIPALIGN="$bt/zipalign"; APKSIGNER="$bt/apksigner"
  ANDROID_JAR="$sdk/platforms/$ANDROID_SDK_PLATFORM/android.jar"
  [[ -f "$ANDROID_JAR" ]] || { echo "android-sdk: no $ANDROID_JAR -- $fetch" >&2; return 1; }
  [[ -n "${SHARE:-}" ]] || { echo "android-sdk: SHARE is unset; set it to the var/share dir before resolving" >&2; return 1; }
  AAPT2="$SHARE/aapt2"
  [[ -x "$AAPT2" ]] || { echo "android-sdk: no $AAPT2 -- run tools/build/toolchain/aapt2.sh" >&2; return 1; }
  return 0
}

# generate the debug keystore
android_debug_keystore() {
  [[ -n "${SHARE:-}" ]] || { echo "android-sdk: SHARE is unset; set it before android_debug_keystore" >&2; return 1; }
  KS="$SHARE/rhizo-testapp-debug.keystore"
  [[ -f "$KS" ]] && return 0
  echo "[android-sdk] generating the debug keystore at $KS (first use only)"
  keytool -genkeypair -v -keystore "$KS" -storepass android -keypass android \
    -alias rhizonettest -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Rhizo NetTest, OU=Rhizo, O=Rhizo, L=NA, S=NA, C=US" >/dev/null
}

# test android_sdk_resolve on a fixture SDK
android_sdk_selftest() {
  local fail=0 tmp out
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION" "$tmp/sdk/platforms/$ANDROID_SDK_PLATFORM" "$tmp/share"
  printf '#!/bin/sh\n' > "$tmp/sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION/d8"
  printf '#!/bin/sh\n' > "$tmp/sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION/apksigner"
  chmod +x "$tmp/sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION"/*
  : > "$tmp/sdk/platforms/$ANDROID_SDK_PLATFORM/android.jar"
  out=$(RHIZO_ANDROID_SDK="$tmp/sdk" SHARE="$tmp/share" android_sdk_resolve 2>&1)
  [[ $? -ne 0 && "$out" == *"no zipalign"* && "$out" == *"build-inputs.sh"* ]] \
    || { echo "SELFTEST FAILED: a missing zipalign was not refused by name -- got: $out"; fail=1; }
  printf '#!/bin/sh\n' > "$tmp/sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION/zipalign"
  chmod +x "$tmp/sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION/zipalign"
  out=$(RHIZO_ANDROID_SDK="$tmp/sdk" SHARE="$tmp/share" android_sdk_resolve 2>&1)
  [[ $? -ne 0 && "$out" == *"aapt2.sh"* ]] \
    || { echo "SELFTEST FAILED: a missing share/aapt2 was not refused naming aapt2.sh -- got: $out"; fail=1; }
  printf '#!/bin/sh\n' > "$tmp/share/aapt2"; chmod +x "$tmp/share/aapt2"
  if RHIZO_ANDROID_SDK="$tmp/sdk" SHARE="$tmp/share" android_sdk_resolve; then
    [[ "$AAPT2" == "$tmp/share/aapt2" && "$ANDROID_JAR" == "$tmp/sdk/platforms/$ANDROID_SDK_PLATFORM/android.jar" ]] \
      || { echo "SELFTEST FAILED: resolved the wrong paths: AAPT2=$AAPT2 ANDROID_JAR=$ANDROID_JAR"; fail=1; }
  else
    echo "SELFTEST FAILED: a complete fixture SDK was refused"; fail=1
  fi
  out=$(RHIZO_ANDROID_SDK="$tmp/sdk" SHARE='' android_sdk_resolve 2>&1)
  [[ $? -ne 0 && "$out" == *"SHARE is unset"* ]] \
    || { echo "SELFTEST FAILED: an unset SHARE was not refused -- got: $out"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "android-sdk.sh selftest: FAILED"; return 1; fi
  echo "android-sdk.sh selftest: ok"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --selftest) android_sdk_selftest; exit $? ;;
    *) echo "usage: source tools/build/toolchain/android-sdk.sh; or: bash tools/build/toolchain/android-sdk.sh --selftest" >&2; exit 2 ;;
  esac
fi
