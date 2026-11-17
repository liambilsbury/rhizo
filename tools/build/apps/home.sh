#!/bin/bash
# var/share/RhizoHome.apk RHIZO_ANDROID_SDK=
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/home" && pwd)"
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
  -d "$WORK/classes" $(find "$SRC/src" -name '*.java')
"$D8" --release --min-api 26 --output "$WORK" $(find "$WORK/classes" -name '*.class')
cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoHome.apk"
badging=$("$AAPT2" dump badging "$SHARE/RhizoHome.apk")
pkg=$(grep -m1 "^package:" <<<"$badging" | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.home" ]] || { echo "package name is '$pkg', expected com.rhizo.home" >&2; exit 1; }
manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$SHARE/RhizoHome.apk")
grep -q 'android.intent.category.HOME' <<<"$manifest" \
  || { echo "AndroidManifest.xml has no android.intent.category.HOME" >&2; exit 1; }
grep -q 'priority.*=1' <<<"$manifest" \
  || { echo "AndroidManifest.xml has no priority=1" >&2; exit 1; }
echo "wrote var/share/RhizoHome.apk ($pkg)"
./tools/build/stamps.py stamp RhizoHome.apk
