#!/bin/bash
# build rhizo-keystoreprobe.apk into var/share
# shellcheck disable=SC2046
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="test/apps/keystoreprobe"
OUT_BASE="rhizo-keystoreprobe"
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "[build-keystoreprobe] aapt2 compile+link"
"$AAPT2" compile --dir "$SRC/res" -o "$WORK/res.zip"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" -R "$WORK/res.zip" --auto-add-overlay \
  --min-sdk-version 26 --target-sdk-version 34

echo "[build-keystoreprobe] javac + d8"
mkdir -p "$WORK/classes"
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$ANDROID_JAR" \
  -d "$WORK/classes" $(find "$SRC/src" -name '*.java')
"$D8" --release --min-api 26 --output "$WORK" $(find "$WORK/classes" -name '*.class')

echo "[build-keystoreprobe] packing dex, aligning, signing"
cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

cp --remove-destination "$WORK/signed.apk" "$SHARE/$OUT_BASE.apk"
badging=$("$AAPT2" dump badging "$SHARE/$OUT_BASE.apk")
pkg=$(echo "$badging" | grep -m1 "^package:" | sed "s/^package: name='\([^']*\)'.*/\1/")
act=$(echo "$badging" | grep -m1 "^launchable-activity:" | sed "s/^launchable-activity: name='\([^']*\)'.*/\1/")
[[ -n "$pkg" && -n "$act" ]] || { echo "[build-keystoreprobe] FAIL: aapt2 badging did not report package/launchable-activity" >&2; exit 1; }
sha=$(sha256sum "$SHARE/$OUT_BASE.apk" | cut -d' ' -f1)
cat > "$SHARE/$OUT_BASE.json" <<EOF
{"package":"$pkg","activity":"$act","sha256":"$sha"}
EOF
./tools/build/stamps.py stamp "$OUT_BASE.apk"
echo "[build-keystoreprobe] OK -> $SHARE/$OUT_BASE.apk ($pkg/$act)"
