#!/bin/bash
# build rhizo-headroomprobe.apk into var/share
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(cd "." && pwd)"
SRC="test/apps/headroomprobe"
OUT_BASE="rhizo-headroomprobe"
SHARE="$ROOT/var/share"
AOSP="$ROOT/aosp-android16-qpr2"
SDK36_JAR="$AOSP/prebuilts/sdk/36/public/android.jar"
SYSROOT="$AOSP/out/soong/ndk/sysroot"
LIBANDROID="$SYSROOT/usr/lib/x86_64-linux-android/36/libandroid.so"
CLANG="$ROOT/toolchain/ndk_extract/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
mkdir -p "$SHARE"

if [[ ! -e "$LIBANDROID" && -d "$AOSP/build" ]]; then
  echo "building the NDK sysroot in $AOSP (m ndk)"
  ( set +u; cd "$AOSP" && source build/envsetup.sh && lunch aosp_x86_64 bp2a userdebug && m ndk )
fi

for f in "$SDK36_JAR" "$LIBANDROID" "$CLANG"; do
  [[ -e "$f" ]] || { echo "missing $f" >&2; exit 1; }
done

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "jni library"
mkdir -p "$WORK/lib/x86_64"
"$CLANG" --target=x86_64-linux-android26 -O2 -fPIC -shared -Wall -Wextra -Werror \
  -D__ANDROID_UNAVAILABLE_SYMBOLS_ARE_WEAK__ -idirafter "$SYSROOT/usr/include" \
  -o "$WORK/lib/x86_64/libheadroomprobe.so" "$SRC/jni/headroomprobe.c" "$LIBANDROID" -lm

echo "aapt2 compile+link"
"$AAPT2" compile --dir "$SRC/res" -o "$WORK/res.zip"
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$SDK36_JAR" -R "$WORK/res.zip" --auto-add-overlay \
  --min-sdk-version 36 --target-sdk-version 36

echo "javac + d8"
mkdir -p "$WORK/classes"
mapfile -t JAVA_SRCS < <(find "$SRC/src" -name '*.java')
javac -source 8 -target 8 -nowarn -Xlint:none -bootclasspath "$SDK36_JAR" \
  -d "$WORK/classes" "${JAVA_SRCS[@]}"
mapfile -t CLASSES < <(find "$WORK/classes" -name '*.class')
"$D8" --release --min-api 26 --lib "$SDK36_JAR" --output "$WORK" "${CLASSES[@]}"

echo "packing dex and library, aligning, signing"
cp "$WORK/base.apk" "$WORK/unsigned.apk"
( cd "$WORK" && zip -q unsigned.apk classes.dex && zip -q -0 unsigned.apk lib/x86_64/libheadroomprobe.so )
"$ZIPALIGN" -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$WORK/signed.apk" "$WORK/aligned.apk"
"$ZIPALIGN" -c 4 "$WORK/signed.apk"

cp --remove-destination "$WORK/signed.apk" "$SHARE/$OUT_BASE.apk"
badging=$("$AAPT2" dump badging "$SHARE/$OUT_BASE.apk")
pkg=$(echo "$badging" | grep -m1 "^package:" | sed "s/^package: name='\([^']*\)'.*/\1/")
act=$(echo "$badging" | grep -m1 "^launchable-activity:" | sed "s/^launchable-activity: name='\([^']*\)'.*/\1/")
[[ -n "$pkg" && -n "$act" ]] || { echo "aapt2 badging did not report package/launchable-activity" >&2; exit 1; }
grep -qx "native-code: 'x86_64'" <<<"$(grep '^native-code:' <<<"$badging")" \
  || { echo "badging does not say native-code: 'x86_64'" >&2; exit 1; }
sha=$(sha256sum "$SHARE/$OUT_BASE.apk" | cut -d' ' -f1)
cat > "$SHARE/$OUT_BASE.json" <<EOF
{"package":"$pkg","activity":"$act","sha256":"$sha"}
EOF
./tools/build/stamps.py stamp "$OUT_BASE.apk"
echo "OK -> $SHARE/$OUT_BASE.apk ($pkg/$act)"
