#!/bin/bash
# build RhizoSoftwareRro.apk
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/software-rro" && pwd)"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"
source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
KEYDIR="$(pwd)/aosp-android16-qpr2/build/make/target/product/security"
[[ -f "$KEYDIR/testkey.pk8" && -f "$KEYDIR/testkey.x509.pem" ]] \
  || { echo "missing AOSP testkey under $KEYDIR" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "[build-software-rro] aapt2 compile + link"
mkdir -p "$WORK/compiled"
"$AAPT2" compile -o "$WORK/compiled" "$SRC/res/values/bools.xml"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 36 \
  --no-resource-deduping --no-resource-removal "$WORK"/compiled/*.flat
"$ZIPALIGN" -p 4 "$WORK/base.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --key "$KEYDIR/testkey.pk8" --cert "$KEYDIR/testkey.x509.pem" \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$WORK/signed.apk")
grep -q 'E: overlay' <<<"$manifest" || { echo "[build-software-rro] FAIL: no <overlay> element" >&2; exit 1; }
grep -q 'targetPackage.*="android"' <<<"$manifest" || { echo "[build-software-rro] FAIL: overlay does not target android" >&2; exit 1; }
grep -q 'isStatic.*=true' <<<"$manifest" || { echo "[build-software-rro] FAIL: overlay is not static" >&2; exit 1; }
resources=$("$AAPT2" dump resources "$WORK/signed.apk")
for r in config_displayColorFadeDisabled config_avoidGfxAccel config_disableTaskSnapshots; do
  grep -A1 "bool/$r" <<<"$resources" | grep -q 'true' \
    || { echo "[build-software-rro] FAIL: $r is not a true bool in the overlay" >&2; exit 1; }
done

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoSoftwareRro.apk"
pkg=$("$AAPT2" dump badging "$SHARE/RhizoSoftwareRro.apk" | grep -m1 "^package:" \
  | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.overlay.software" ]] || { echo "[build-software-rro] FAIL: unexpected package '$pkg'" >&2; exit 1; }
"$AAPT2" dump badging "$SHARE/RhizoSoftwareRro.apk" | grep -q "^targetSdkVersion:'36'" \
  || { echo "[build-software-rro] FAIL: the overlay does not target SDK 36, which Android 16 requires of a system overlay" >&2; exit 1; }
echo "[build-software-rro] OK -> var/share/RhizoSoftwareRro.apk ($pkg)"
./tools/build/stamps.py stamp RhizoSoftwareRro.apk
