#!/bin/bash
# build RhizoSettingsProviderRro.apk
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/settingsprovider-rro" && pwd)"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"
source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
KEYDIR="$(pwd)/aosp-android16-qpr2/build/make/target/product/security"
[[ -f "$KEYDIR/testkey.pk8" && -f "$KEYDIR/testkey.x509.pem" ]] \
  || { echo "missing AOSP testkey under $KEYDIR" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "[build-settingsprovider-rro] aapt2 compile + link"
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
  || { echo "[build-settingsprovider-rro] FAIL: overlay does not target com.android.providers.settings" >&2; exit 1; }
grep -q 'isStatic.*=true' <<<"$manifest" || { echo "[build-settingsprovider-rro] FAIL: overlay is not static" >&2; exit 1; }
resources=$("$AAPT2" dump resources "$WORK/signed.apk")
for r in def_bluetooth_on def_networks_available_notification_on; do
  grep -A1 "bool/$r" <<<"$resources" | grep -q 'false' \
    || { echo "[build-settingsprovider-rro] FAIL: $r is not a false bool in the overlay" >&2; exit 1; }
done
grep -A1 "bool/def_wifi_on" <<<"$resources" | grep -q 'true' \
  || { echo "[build-settingsprovider-rro] FAIL: def_wifi_on is not a true bool in the overlay (a fresh android would boot with Wi-Fi off)" >&2; exit 1; }
grep -A1 "string/def_airplane_mode_radios" <<<"$resources" | grep -qF '"cell,bluetooth,uwb,wimax"' \
  || { echo "[build-settingsprovider-rro] FAIL: def_airplane_mode_radios is not cell,bluetooth,uwb,wimax (airplane mode would turn the mirrored Wi-Fi off)" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoSettingsProviderRro.apk"
echo "[build-settingsprovider-rro] OK -> var/share/RhizoSettingsProviderRro.apk"
./tools/build/stamps.py stamp RhizoSettingsProviderRro.apk
