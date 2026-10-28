#!/bin/bash
# build RhizoAutomotiveProjectionRro.apk
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/automotive-projection-rro" && pwd)"
SHARE="$(pwd)/var/share"
OUT_DIR="$SHARE/virtual-device"
mkdir -p "$OUT_DIR"
source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
KEYDIR="$(pwd)/aosp-android16-qpr2/build/make/target/product/security"
[[ -f "$KEYDIR/testkey.pk8" && -f "$KEYDIR/testkey.x509.pem" ]] \
  || { echo "missing AOSP testkey under $KEYDIR" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "[build-automotive-projection-rro] aapt2 compile + link"
mkdir -p "$WORK/compiled"
"$AAPT2" compile -o "$WORK/compiled" "$SRC/res/values/config.xml"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 36 \
  --no-resource-deduping --no-resource-removal "$WORK"/compiled/*.flat
"$ZIPALIGN" -p 4 "$WORK/base.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --key "$KEYDIR/testkey.pk8" --cert "$KEYDIR/testkey.x509.pem" \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$WORK/signed.apk")
grep -q 'E: overlay' <<<"$manifest" || { echo "[build-automotive-projection-rro] FAIL: no <overlay> element" >&2; exit 1; }
grep -q 'targetPackage.*="android"' <<<"$manifest" || { echo "[build-automotive-projection-rro] FAIL: overlay does not target android" >&2; exit 1; }
grep -q 'isStatic.*=true' <<<"$manifest" || { echo "[build-automotive-projection-rro] FAIL: overlay is not static" >&2; exit 1; }
resources=$("$AAPT2" dump resources "$WORK/signed.apk")
grep -A1 "string/config_systemAutomotiveProjection" <<<"$resources" | grep -qF '"com.rhizo.virtualdevice"' \
  || { echo "[build-automotive-projection-rro] FAIL: config_systemAutomotiveProjection does not name com.rhizo.virtualdevice" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$OUT_DIR/RhizoAutomotiveProjectionRro.apk"
pkg=$("$AAPT2" dump badging "$OUT_DIR/RhizoAutomotiveProjectionRro.apk" | grep -m1 "^package:" \
  | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.overlay.automotiveprojection" ]] || { echo "[build-automotive-projection-rro] FAIL: unexpected package '$pkg'" >&2; exit 1; }
echo "[build-automotive-projection-rro] OK -> $OUT_DIR/RhizoAutomotiveProjectionRro.apk ($pkg)"
./tools/build/stamps.py stamp virtual-device/RhizoAutomotiveProjectionRro.apk
