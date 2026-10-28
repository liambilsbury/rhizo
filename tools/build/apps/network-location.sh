#!/bin/bash
# build RhizoNetworkLocation.apk
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="$(cd "src/android/apps/network-location" && pwd)"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "[build-network-location] aapt2 link"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 31 --target-sdk-version 34

echo "[build-network-location] javac (with @SystemApi stubs) + d8 (without them)"
mkdir -p "$WORK/classes"
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" $(find "$SRC/src" "$SRC/stubs" -name '*.java')
"$D8" --release --min-api 31 --output "$WORK" $(find "$WORK/classes/com/rhizo" -name '*.class')

echo "[build-network-location] packing dex, aligning, signing"
cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

defined=$("$(dirname "$D8")/dexdump" "$WORK/classes.dex" | sed -n "s/^ *Class descriptor *: '\(.*\)'$/\1/p")
if [[ -z "$defined" ]] || grep -qv '^Lcom/rhizo/networklocation/' <<<"$defined"; then
  echo "[build-network-location] FAIL: the dex defines classes outside com.rhizo.networklocation (a stub leaked?): $defined" >&2
  exit 1
fi

out="$SHARE/RhizoNetworkLocation.apk"
cp --remove-destination "$WORK/signed.apk" "$out"
badging=$("$AAPT2" dump badging "$out")
pkg=$(grep -m1 "^package:" <<<"$badging" | sed "s/^package: name='\([^']*\)'.*/\1/")
[[ "$pkg" == "com.rhizo.networklocation" ]] || {
  echo "[build-network-location] FAIL: unexpected package '$pkg'" >&2; exit 1; }
for perm in ACCESS_FINE_LOCATION ACCESS_BACKGROUND_LOCATION; do
  grep -q "^uses-permission: name='android.permission.$perm'" <<<"$badging" || {
    echo "[build-network-location] FAIL: $out does not request android.permission.$perm" >&2; exit 1; }
done
"$AAPT2" dump xmltree --file AndroidManifest.xml "$out" | grep -A1 '="serviceVersion"' \
  | grep -q 'android:value(0x01010024)=[0-9][0-9]*$' || {
  echo "[build-network-location] FAIL: serviceVersion is not an integer, so the framework would read Integer.MIN_VALUE" >&2
  exit 1; }
echo "[build-network-location] OK -> var/share/RhizoNetworkLocation.apk ($pkg)"

./tools/build/stamps.py stamp RhizoNetworkLocation.apk
