#!/bin/bash
# var/share/RhizoAudioRouter.apk RHIZO_ANDROID_SDK=
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

"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 34

mkdir -p "$WORK/classes"
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" $(find "$SRC/src" "$SRC/stubs" -name '*.java')
"$D8" --release --min-api 26 --output "$WORK" $(find "$WORK/classes/com/rhizo" -name '*.class')

cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

dex_strings=$(unzip -p "$WORK/signed.apk" classes.dex | strings)
if grep -q "Landroid/media/audiopolicy/AudioPolicy;.*stub" <<<"$dex_strings"; then
  echo "classes.dex has an AudioPolicy stub string" >&2
  exit 1
fi

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoAudioRouter.apk"
pkg=$("$AAPT2" dump badging "$SHARE/RhizoAudioRouter.apk" | grep -m1 "^package:" \
  | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.audiorouter" ]] || {
  echo "package name is '$pkg', expected com.rhizo.audiorouter" >&2; exit 1; }
echo "wrote var/share/RhizoAudioRouter.apk ($pkg)"

./tools/build/stamps.py stamp RhizoAudioRouter.apk
