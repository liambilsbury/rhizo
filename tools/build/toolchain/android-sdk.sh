#!/bin/bash
# Android SDK build-tools, android.jar and aapt2 lookup
# shellcheck disable=SC2034

ANDROID_SDK_BUILD_TOOLS_VERSION=34.0.0
ANDROID_SDK_PLATFORM=android-34

# print RHIZO_ANDROID_SDK or the android-sdk input cache path
android_sdk_root() {
  echo "${RHIZO_ANDROID_SDK:-${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}/android-sdk}"
}

# set D8, ZIPALIGN, APKSIGNER, ANDROID_JAR and AAPT2
android_sdk_resolve() {
  local sdk bt tool
  sdk="$(android_sdk_root)"
  bt="$sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION"
  for tool in d8 zipalign apksigner; do
    [[ -x "$bt/$tool" ]] || { echo "no $tool in $bt" >&2; return 1; }
  done
  D8="$bt/d8"; ZIPALIGN="$bt/zipalign"; APKSIGNER="$bt/apksigner"
  ANDROID_JAR="$sdk/platforms/$ANDROID_SDK_PLATFORM/android.jar"
  [[ -f "$ANDROID_JAR" ]] || { echo "no $ANDROID_JAR" >&2; return 1; }
  [[ -n "${SHARE:-}" ]] || { echo "SHARE is unset" >&2; return 1; }
  AAPT2="$SHARE/aapt2"
  [[ -x "$AAPT2" ]] || { echo "no $AAPT2" >&2; return 1; }
  return 0
}

# create $SHARE/rhizo-testapp-debug.keystore with keytool
android_debug_keystore() {
  [[ -n "${SHARE:-}" ]] || { echo "SHARE is unset" >&2; return 1; }
  KS="$SHARE/rhizo-testapp-debug.keystore"
  [[ -f "$KS" ]] && return 0
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
  [[ $? -ne 0 && "$out" == *"no zipalign"* && "$out" == *"build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION"* ]] \
    || { echo "FAIL android_sdk_resolve without zipalign prints no zipalign ($out)"; fail=1; }
  printf '#!/bin/sh\n' > "$tmp/sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION/zipalign"
  chmod +x "$tmp/sdk/build-tools/$ANDROID_SDK_BUILD_TOOLS_VERSION/zipalign"
  out=$(RHIZO_ANDROID_SDK="$tmp/sdk" SHARE="$tmp/share" android_sdk_resolve 2>&1)
  [[ $? -ne 0 && "$out" == *"no $tmp/share/aapt2"* ]] \
    || { echo "FAIL android_sdk_resolve without share/aapt2 prints no $tmp/share/aapt2 ($out)"; fail=1; }
  printf '#!/bin/sh\n' > "$tmp/share/aapt2"; chmod +x "$tmp/share/aapt2"
  if RHIZO_ANDROID_SDK="$tmp/sdk" SHARE="$tmp/share" android_sdk_resolve; then
    [[ "$AAPT2" == "$tmp/share/aapt2" && "$ANDROID_JAR" == "$tmp/sdk/platforms/$ANDROID_SDK_PLATFORM/android.jar" ]] \
      || { echo "FAIL AAPT2 == $tmp/share/aapt2 and ANDROID_JAR == the fixture android.jar (AAPT2=$AAPT2 ANDROID_JAR=$ANDROID_JAR)"; fail=1; }
  else
    echo "FAIL android_sdk_resolve with a complete fixture SDK returns 0"; fail=1
  fi
  out=$(RHIZO_ANDROID_SDK="$tmp/sdk" SHARE='' android_sdk_resolve 2>&1)
  [[ $? -ne 0 && "$out" == *"SHARE is unset"* ]] \
    || { echo "FAIL android_sdk_resolve with SHARE='' prints SHARE is unset ($out)"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "FAIL android-sdk.sh --selftest"; return 1; fi
  echo "ok android-sdk.sh --selftest"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --selftest) android_sdk_selftest; exit $? ;;
    *) echo "source tools/build/toolchain/android-sdk.sh | bash tools/build/toolchain/android-sdk.sh --selftest" >&2; exit 2 ;;
  esac
fi
