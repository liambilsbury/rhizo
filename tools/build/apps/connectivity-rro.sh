#!/bin/bash
# build RhizoConnectivityRro.apk
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/connectivity-rro" && pwd)"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"
source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
KEYDIR="$(pwd)/aosp-android16-qpr2/build/make/target/product/security"
[[ -f "$KEYDIR/testkey.pk8" && -f "$KEYDIR/testkey.x509.pem" ]] \
  || { echo "missing AOSP testkey under $KEYDIR" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "[build-connectivity-rro] aapt2 compile + link"
mkdir -p "$WORK/compiled"
"$AAPT2" compile -o "$WORK/compiled" "$SRC/res/values/arrays.xml"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 36 \
  --no-resource-deduping --no-resource-removal "$WORK"/compiled/*.flat
"$ZIPALIGN" -p 4 "$WORK/base.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --key "$KEYDIR/testkey.pk8" --cert "$KEYDIR/testkey.x509.pem" \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$WORK/signed.apk")
grep -q 'E: overlay' <<<"$manifest" || { echo "[build-connectivity-rro] FAIL: no <overlay> element" >&2; exit 1; }
grep -q 'targetPackage.*="com.android.connectivity.resources"' <<<"$manifest" \
  || { echo "[build-connectivity-rro] FAIL: overlay does not target com.android.connectivity.resources" >&2; exit 1; }
grep -q 'targetName.*="ServiceConnectivityResourcesConfig"' <<<"$manifest" \
  || { echo "[build-connectivity-rro] FAIL: overlay does not name the ServiceConnectivityResourcesConfig overlayable, which idmap2 requires" >&2; exit 1; }
grep -q 'isStatic.*=true' <<<"$manifest" || { echo "[build-connectivity-rro] FAIL: overlay is not static" >&2; exit 1; }
resources=$("$AAPT2" dump resources "$WORK/signed.apk")
keepalive=$(grep -A3 "array/config_networkSupportedKeepaliveCount" <<<"$resources")
grep -qF '"1,0"' <<<"$keepalive" \
  || { echo "[build-connectivity-rro] FAIL: config_networkSupportedKeepaliveCount does not give Wi-Fi (transport 1) 0 slots" >&2; exit 1; }
grep -qF '"0,1"' <<<"$keepalive" \
  || { echo "[build-connectivity-rro] FAIL: config_networkSupportedKeepaliveCount dropped AOSP's cellular row" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoConnectivityRro.apk"
pkg=$("$AAPT2" dump badging "$SHARE/RhizoConnectivityRro.apk" | grep -m1 "^package:" \
  | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.overlay.connectivity" ]] || { echo "[build-connectivity-rro] FAIL: unexpected package '$pkg'" >&2; exit 1; }
"$AAPT2" dump badging "$SHARE/RhizoConnectivityRro.apk" | grep -q "^targetSdkVersion:'36'" \
  || { echo "[build-connectivity-rro] FAIL: the overlay does not target SDK 36, which Android 16 requires of a system overlay" >&2; exit 1; }
echo "[build-connectivity-rro] OK -> var/share/RhizoConnectivityRro.apk ($pkg)"
./tools/build/stamps.py stamp RhizoConnectivityRro.apk
