#!/bin/bash
# var/share/virtual-device/RhizoVirtualDevice.apk RHIZO_ANDROID_SDK=
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/virtual-device" && pwd)"
SHARE="$(pwd)/var/share"
OUT_DIR="$SHARE/virtual-device"
mkdir -p "$OUT_DIR"

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 34 --target-sdk-version 36

mkdir -p "$WORK/classes"
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" $(find "$SRC/src" "$SRC/stubs" -name '*.java')
"$D8" --release --min-api 34 --output "$WORK" $(find "$WORK/classes/com/rhizo" -name '*.class')

cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

pkg=$("$AAPT2" dump badging "$WORK/signed.apk" | grep -m1 "^package:" \
  | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.virtualdevice" ]] || {
  echo "package name is '$pkg', expected com.rhizo.virtualdevice" >&2; exit 1; }
"$AAPT2" dump permissions "$WORK/signed.apk" | grep -q "android.permission.REQUEST_COMPANION_SELF_MANAGED" || {
  echo "signed.apk has no uses-permission android.permission.REQUEST_COMPANION_SELF_MANAGED" >&2; exit 1; }
"$AAPT2" dump permissions "$WORK/signed.apk" | grep -q "CREATE_VIRTUAL_DEVICE" && {
  echo "signed.apk has uses-permission CREATE_VIRTUAL_DEVICE" >&2; exit 1; }

DEXDUMP="$(dirname "$APKSIGNER")/dexdump"
unzip -p "$WORK/signed.apk" classes.dex > "$WORK/classes.dex"
leaked=$("$DEXDUMP" -l xml "$WORK/classes.dex" 2>/dev/null | grep -o '<package name="[^"]*"' \
  | sed 's/<package name="//;s/"//' | grep -v '^com\.rhizo\.virtualdevice$' || true)
[[ -z "$leaked" ]] || {
  echo "classes.dex has packages outside com.rhizo.virtualdevice ($leaked)" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$OUT_DIR/RhizoVirtualDevice.apk"
echo "wrote $OUT_DIR/RhizoVirtualDevice.apk ($pkg)"
./tools/build/stamps.py stamp virtual-device/RhizoVirtualDevice.apk
