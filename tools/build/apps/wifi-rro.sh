#!/bin/bash
# var/share/RhizoWifiRro.apk RHIZO_ANDROID_SDK=
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/wifi-rro" && pwd)"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"
source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
KEYDIR="$(pwd)/aosp-android16-qpr2/build/make/target/product/security"
[[ -f "$KEYDIR/testkey.pk8" && -f "$KEYDIR/testkey.x509.pem" ]] \
  || { echo "no testkey.pk8 or testkey.x509.pem in $KEYDIR" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

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
grep -q 'E: overlay' <<<"$manifest" || { echo "AndroidManifest.xml has no <overlay> element" >&2; exit 1; }
grep -q 'targetPackage.*="com.android.wifi.resources"' <<<"$manifest" \
  || { echo "<overlay> targetPackage is not com.android.wifi.resources" >&2; exit 1; }
grep -q 'targetName.*="WifiCustomization"' <<<"$manifest" \
  || { echo "<overlay> targetName is not WifiCustomization" >&2; exit 1; }
grep -q 'isStatic.*=true' <<<"$manifest" || { echo "<overlay> isStatic is not true" >&2; exit 1; }
resources=$("$AAPT2" dump resources "$WORK/signed.apk")
for r in config_wifi_connected_mac_randomization_supported config_wifiSaveFactoryMacToWifiConfigStore; do
  grep -A1 "bool/$r" <<<"$resources" | grep -q 'false' \
    || { echo "bool/$r is not false" >&2; exit 1; }
done
n=$(grep -c ' resource 0x' <<<"$resources")
[[ "$n" == 2 ]] || { echo "signed.apk has $n resources, expected 2" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoWifiRro.apk"
pkg=$("$AAPT2" dump badging "$SHARE/RhizoWifiRro.apk" | grep -m1 "^package:" \
  | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.overlay.wifi" ]] || { echo "package name is '$pkg', expected com.rhizo.overlay.wifi" >&2; exit 1; }
"$AAPT2" dump badging "$SHARE/RhizoWifiRro.apk" | grep -q "^targetSdkVersion:'36'" \
  || { echo "targetSdkVersion is not 36" >&2; exit 1; }
echo "wrote var/share/RhizoWifiRro.apk ($pkg)"
./tools/build/stamps.py stamp RhizoWifiRro.apk
