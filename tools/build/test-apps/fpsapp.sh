#!/bin/bash
# build the fps app APK
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(cd "." && pwd)"
SRC="test/apps/fpsapp"
SHARE="$ROOT/var/share"
NDK="$ROOT/toolchain/ndk_extract/android-ndk-r27c"
CLANG="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android26-clang"
GLUE="$NDK/sources/android/native_app_glue"
[[ -x "$CLANG" ]] || { echo "NDK clang not found at $CLANG" >&2; exit 1; }
source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1
android_debug_keystore || exit 1
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib/x86_64"
"$CLANG" -O2 -fPIC -shared -Wall -I"$GLUE" -o "$WORK/lib/x86_64/librhizofps.so" \
  "$GLUE/android_native_app_glue.c" "$SRC/jni/fps.c" \
  -u ANativeActivity_onCreate -lEGL -lGLESv2 -landroid -llog -lm
"$AAPT2" link -o "$WORK/base.apk" --manifest "$SRC/AndroidManifest.xml" \
  -I "$ANDROID_JAR" --min-sdk-version 26 --target-sdk-version 34
(cd "$WORK" && zip -q -0 base.apk lib/x86_64/librhizofps.so)
"$ZIPALIGN" -p -f 4 "$WORK/base.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$SHARE/rhizo-fps.apk" "$WORK/aligned.apk"
echo "[build-fpsapp] $SHARE/rhizo-fps.apk ($(stat -c %s "$SHARE/rhizo-fps.apk") bytes)"

./tools/build/stamps.py stamp rhizo-fps.apk
