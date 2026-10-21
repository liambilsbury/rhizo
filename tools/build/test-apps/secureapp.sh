#!/bin/bash
# build rhizo-secureapp.apk into var/share
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="test/apps/secureapp"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

"$AAPT2" compile --dir "$SRC/res" -o "$WORK/res.zip"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" -R "$WORK/res.zip" --auto-add-overlay \
  --min-sdk-version 26 --target-sdk-version 34
mkdir -p "$WORK/classes"
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" $(find "$SRC/src" -name '*.java')
"$D8" --release --min-api 26 --output "$WORK" $(find "$WORK/classes" -name '*.class')
cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$SHARE/rhizo-secureapp.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$SHARE/rhizo-secureapp.apk"
echo "[build-secureapp] $SHARE/rhizo-secureapp.apk ($(stat -c %s "$SHARE/rhizo-secureapp.apk") bytes)"

./tools/build/stamps.py stamp rhizo-secureapp.apk
