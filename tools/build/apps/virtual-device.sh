#!/bin/bash
# build the virtual-device APK
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

echo "[build-virtual-device] aapt2 link"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 34 --target-sdk-version 36

echo "[build-virtual-device] javac (with @SystemApi stubs) + d8 (without them)"
mkdir -p "$WORK/classes"
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" $(find "$SRC/src" "$SRC/stubs" -name '*.java')
"$D8" --release --min-api 34 --output "$WORK" $(find "$WORK/classes/com/rhizo" -name '*.class')

echo "[build-virtual-device] packing dex, aligning, signing"
cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

pkg=$("$AAPT2" dump badging "$WORK/signed.apk" | grep -m1 "^package:" \
  | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.virtualdevice" ]] || {
  echo "[build-virtual-device] FAIL: unexpected package '$pkg'" >&2; exit 1; }
"$AAPT2" dump permissions "$WORK/signed.apk" | grep -q "android.permission.REQUEST_COMPANION_SELF_MANAGED" || {
  echo "[build-virtual-device] FAIL: the APK does not request REQUEST_COMPANION_SELF_MANAGED" >&2; exit 1; }
"$AAPT2" dump permissions "$WORK/signed.apk" | grep -q "CREATE_VIRTUAL_DEVICE" && {
  echo "[build-virtual-device] FAIL: the manifest must not request CREATE_VIRTUAL_DEVICE directly" >&2; exit 1; }

DEXDUMP="$(dirname "$APKSIGNER")/dexdump"
unzip -p "$WORK/signed.apk" classes.dex > "$WORK/classes.dex"
leaked=$("$DEXDUMP" -l xml "$WORK/classes.dex" 2>/dev/null | grep -o '<package name="[^"]*"' \
  | sed 's/<package name="//;s/"//' | grep -v '^com\.rhizo\.virtualdevice$' || true)
[[ -z "$leaked" ]] || {
  echo "[build-virtual-device] FAIL: stub classes leaked into the dex: $leaked" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$OUT_DIR/RhizoVirtualDevice.apk"
echo "[build-virtual-device] OK -> $OUT_DIR/RhizoVirtualDevice.apk ($pkg)"
./tools/build/stamps.py stamp virtual-device/RhizoVirtualDevice.apk
