#!/bin/bash
# build RhizoSettingsRro.apk
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/settings-rro" && pwd)"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"
source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
KEYDIR="$(pwd)/aosp-android16-qpr2/build/make/target/product/security"
[[ -f "$KEYDIR/testkey.pk8" && -f "$KEYDIR/testkey.x509.pem" ]] \
  || { echo "missing AOSP testkey under $KEYDIR" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "[build-settings-rro] aapt2 compile + link"
mkdir -p "$WORK/compiled"
"$AAPT2" compile -o "$WORK/compiled" "$SRC/res/values/strings.xml"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 36 \
  --no-resource-deduping --no-resource-removal "$WORK"/compiled/*.flat
"$ZIPALIGN" -p 4 "$WORK/base.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --key "$KEYDIR/testkey.pk8" --cert "$KEYDIR/testkey.x509.pem" \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$WORK/signed.apk")
grep -q 'targetPackage.*="com.android.settings"' <<<"$manifest" \
  || { echo "[build-settings-rro] FAIL: overlay does not target com.android.settings" >&2; exit 1; }
grep -q 'isStatic.*=true' <<<"$manifest" || { echo "[build-settings-rro] FAIL: overlay is not static" >&2; exit 1; }
grep -A1 "string/about_settings" <<<"$("$AAPT2" dump resources "$WORK/signed.apk")" | grep -qF '"About device"' \
  || { echo "[build-settings-rro] FAIL: about_settings is not \"About device\" in the overlay" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoSettingsRro.apk"
echo "[build-settings-rro] OK -> var/share/RhizoSettingsRro.apk"
./tools/build/stamps.py stamp RhizoSettingsRro.apk
