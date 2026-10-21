#!/bin/bash
# build the two audio test APKs
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="test/apps/audiotestapp"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1

# build an audio test APK
build_variant() {
  local suffix="$1" freq="$2" bg="$3"
  local pkg="com.rhizo.audiotest.$suffix"
  local out="$SHARE/rhizo-audiotest-$suffix.apk"
  local work
  work=$(mktemp -d); trap 'rm -rf "$work"' RETURN

  mkdir -p "$work/src/com/rhizo/audiotest"
  cp "$SRC/src/com/rhizo/audiotest/MainActivity.java" "$work/src/com/rhizo/audiotest/"
  sed -e "s/@FREQ@/$freq/" -e "s/@BG@/$bg/" \
    "$SRC/src/com/rhizo/audiotest/Config.java.in" > "$work/src/com/rhizo/audiotest/Config.java"
  sed -e "s/@PKG@/$pkg/" -e "s/@LABEL@/Rhizo Tone $suffix/" \
    "$SRC/AndroidManifest.xml.in" > "$work/AndroidManifest.xml"

  "$AAPT2" link -o "$work/base.apk" --manifest "$work/AndroidManifest.xml" \
    -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 34
  mkdir -p "$work/classes"
  javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
    -d "$work/classes" $(find "$work/src" -name '*.java')
  "$D8" --release --min-api 26 --output "$work" $(find "$work/classes" -name '*.class')
  cp "$work/base.apk" "$work/unsigned.apk"
  ( cd "$work" && zip -q unsigned.apk classes.dex )
  "$ZIPALIGN" -p 4 "$work/unsigned.apk" "$work/aligned.apk"
  "$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --out "$work/signed.apk" "$work/aligned.apk"
  "$ZIPALIGN" -c 4 "$work/signed.apk"
  cp --remove-destination "$work/signed.apk" "$out"

  local badging act sha
  badging=$("$AAPT2" dump badging "$out")
  act=$(echo "$badging" | grep -m1 "^launchable-activity:" | sed "s/^launchable-activity: name='\([^']*\)'.*/\1/")
  [[ -n "$act" ]] || { echo "[build-audiotestapp] FAIL: no launchable activity in $out" >&2; exit 1; }
  sha=$(sha256sum "$out" | cut -d' ' -f1)
  cat > "${out%.apk}.json" <<EOF
{"package":"$pkg","activity":"$act","tone_hz":$freq,"sha256":"$sha"}
EOF
  rm -rf "$work"
  echo "[build-audiotestapp] OK -> ${out#$SHARE/} ($pkg, $freq Hz, $act)"
}

build_variant a 440 0xFF102040
build_variant b 880 0xFF402010

./tools/build/stamps.py stamp rhizo-audiotest-a.apk
./tools/build/stamps.py stamp rhizo-audiotest-b.apk
