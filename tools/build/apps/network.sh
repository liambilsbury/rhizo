#!/bin/bash
# var/share/RhizoNetwork.apk RHIZO_ANDROID_SDK=
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/network" && pwd)"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 33 --target-sdk-version 36

mkdir -p "$WORK/classes"
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" $(find "$SRC/src" -name '*.java')
"$D8" --release --min-api 33 --output "$WORK" $(find "$WORK/classes/com/rhizo" -name '*.class')

cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

badging=$("$AAPT2" dump badging "$WORK/signed.apk")
pkg=$(grep -m1 "^package:" <<<"$badging" | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.network" ]] || {
  echo "package name is '$pkg', expected com.rhizo.network" >&2; exit 1; }
grep -q "^application: label='Rhizo'" <<<"$badging" || {
  echo "application label is not Rhizo" >&2; exit 1; }
perms=$("$AAPT2" dump permissions "$WORK/signed.apk")
for p in ACCESS_WIFI_STATE CHANGE_WIFI_STATE NETWORK_CARRIER_PROVISIONING; do
  grep -q "uses-permission: name='android.permission.$p'" <<<"$perms" || {
    echo "signed.apk has no uses-permission android.permission.$p" >&2; exit 1; }
done
grep -q "OVERRIDE_WIFI_CONFIG" <<<"$perms" && {
  echo "signed.apk has uses-permission OVERRIDE_WIFI_CONFIG" >&2; exit 1; }
manifest=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$WORK/signed.apk")
grep -A4 'E: receiver' <<<"$manifest" | grep -q 'permission.*="android.permission.NETWORK_SETTINGS"' || {
  echo "<receiver> permission is not android.permission.NETWORK_SETTINGS" >&2; exit 1; }
grep -q 'allowBackup.*=false' <<<"$manifest" || {
  echo "allowBackup is not false" >&2; exit 1; }

DEXDUMP="$(dirname "$APKSIGNER")/dexdump"
unzip -p "$WORK/signed.apk" classes.dex > "$WORK/classes.dex"
leaked=$("$DEXDUMP" -l xml "$WORK/classes.dex" 2>/dev/null | grep -o '<package name="[^"]*"' \
  | sed 's/<package name="//;s/"//' | grep -v '^com\.rhizo\.network$' || true)
[[ -z "$leaked" ]] || {
  echo "classes.dex has packages outside com.rhizo.network ($leaked)" >&2; exit 1; }

cp --remove-destination "$WORK/signed.apk" "$SHARE/RhizoNetwork.apk"
echo "wrote var/share/RhizoNetwork.apk ($pkg)"
./tools/build/stamps.py stamp RhizoNetwork.apk
