#!/bin/bash
# var/share/RhizoSettingsProviderRro.apk RHIZO_ANDROID_SDK=
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/settingsprovider-rro" && pwd)"
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
"$AAPT2" compile -o "$WORK/compiled" "$SRC/res/values/strings.xml"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 36 \
  --no-resource-deduping --no-resource-removal "$WORK"/compiled/*.flat
"$ZIPALIGN" -p 4 "$WORK/base.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --key "$KEYDIR/testkey.pk8" --cert "$KEYDIR/testkey.x509.pem" \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$WORK/signed.apk")
grep -q 'targetPackage.*="com.android.providers.settings"' <<<"$manifest" \
  || { echo "<overlay> targetPackage is not com.android.providers.settings" >&2; exit 1; }
grep -q 'isStatic.*=true' <<<"$manifest" || { echo "<overlay> isStatic is not true" >&2; exit 1; }
resources=$("$AAPT2" dump resources "$WORK/signed.apk")
for r in def_bluetooth_on def_networks_available_notification_on; do
  grep -A1 "bool/$r" <<<"$resources" | grep -q 'false' \
    || { echo "bool/$r is not false" >&2; exit 1; }
done
grep -A1 "bool/def_wifi_on" <<<"$resources" | grep -q 'true' \
  || { echo "bool/def_wifi_on is not true" >&2; exit 1; }
grep -A1 "string/def_airplane_mode_radios" <<<"$resources" | grep -qF '"cell,bluetooth,uwb,wimax"' \
  || { echo "string/def_airplane_mode_radios is not \"cell,bluetooth,uwb,wimax\"" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoSettingsProviderRro.apk"
echo "wrote var/share/RhizoSettingsProviderRro.apk"
./tools/build/stamps.py stamp RhizoSettingsProviderRro.apk
