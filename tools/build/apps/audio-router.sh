#!/bin/bash
# build RhizoAudioRouter.apk
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/audio-router" && pwd)"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "[build-audio-router] aapt2 link"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 34

echo "[build-audio-router] javac (with @SystemApi stubs) + d8 (without them)"
mkdir -p "$WORK/classes"
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" $(find "$SRC/src" "$SRC/stubs" -name '*.java')
"$D8" --release --min-api 26 --output "$WORK" $(find "$WORK/classes/com/rhizo" -name '*.class')

echo "[build-audio-router] packing dex, aligning, signing"
cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

dex_strings=$(unzip -p "$WORK/signed.apk" classes.dex | strings)
if grep -q "Landroid/media/audiopolicy/AudioPolicy;.*stub" <<<"$dex_strings"; then
  echo "[build-audio-router] FAIL: stub classes leaked into the dex" >&2
  exit 1
fi

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoAudioRouter.apk"
pkg=$("$AAPT2" dump badging "$SHARE/RhizoAudioRouter.apk" | grep -m1 "^package:" \
  | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.audiorouter" ]] || {
  echo "[build-audio-router] FAIL: unexpected package '$pkg'" >&2; exit 1; }
echo "[build-audio-router] OK -> var/share/RhizoAudioRouter.apk ($pkg)"

./tools/build/stamps.py stamp RhizoAudioRouter.apk
