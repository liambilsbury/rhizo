#!/bin/bash
# stage the AOSP rhizo-keymint-service build
set -euo pipefail
USAGE="usage: keymint.sh [--rebuild] [--patch-only] [--arch=aarch64 | aarch64] [-h | --help]"
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(cd "." && pwd)"
AOSP_DIR="$ROOT/aosp-android16-qpr2"
ARCH=x86_64
LUNCH_PRODUCT=aosp_x86_64
SOONG_VARIANT=x86_64
STAGE_SUFFIX=""

REBUILD=0
PATCH_ONLY=0
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=1 ;;
    --patch-only) PATCH_ONLY=1 ;;
    --arch=aarch64|aarch64) ARCH=aarch64; LUNCH_PRODUCT=aosp_arm64; SOONG_VARIANT=arm64_armv8-a; STAGE_SUFFIX="_arm64" ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "[build-keymint] ERROR: unknown argument: $a" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$AOSP_DIR" ]]; then
  echo "[build-keymint] ERROR: $AOSP_DIR not found -- run make inputs" >&2
  exit 1
fi

exec 9>"$AOSP_DIR/.rhizo-aosp.lock"
flock -n 9 || { echo "[build-keymint] ERROR: another build holds $AOSP_DIR/.rhizo-aosp.lock" >&2; exit 1; }

# apply each keymint patch to the aosp checkout
apply_patches() {
  local patches=("$ROOT"/tools/patches/keymint/*.patch) pf p clean err
  if [[ ! -f "${patches[0]}" ]]; then
    echo "[build-keymint] ERROR: no tools/patches/keymint/*.patch under $ROOT" >&2
    exit 1
  fi
  PATCH_WORK=$(mktemp -d)
  trap 'rm -rf "$PATCH_WORK"' EXIT
  for pf in "${patches[@]}"; do
    p=$(basename "$pf")
    clean="$PATCH_WORK/$p"
    awk '/^--- a\// {c=1} c' "$pf" > "$clean"
    if [[ ! -s "$clean" ]]; then
      echo "[build-keymint] ERROR: $p carries no '--- a/' diff to apply." >&2
      exit 1
    fi
    if err=$(cd "$AOSP_DIR" && git apply --check "$clean" 2>&1); then
      (cd "$AOSP_DIR" && git apply "$clean")
      echo "[build-keymint] applied $p"
    elif (cd "$AOSP_DIR" && git apply --check --reverse "$clean" >/dev/null 2>&1); then
      echo "[build-keymint] $p already applied"
    else
      echo "[build-keymint] ERROR: $p conflicts with $AOSP_DIR: it neither applies nor reverses cleanly." >&2
      echo "  Re-derive it against the checkout; after editing an applied patch, reverse-apply its old" >&2
      echo "  version first (git show HEAD:tools/patches/keymint/$p, header stripped). git apply --check said:" >&2
      printf '%s\n' "$err" | sed 's/^/    /' >&2
      exit 1
    fi
  done
}

apply_patches
if [[ "$PATCH_ONLY" == "1" ]]; then
  echo "[build-keymint] --patch-only: every keymint patch is applied, nothing built"
  exit 0
fi

if [[ "$REBUILD" == "1" ]]; then
  echo "[build-keymint] --rebuild: running the real AOSP build (this can take a while)"
  (
    set +u
    cd "$AOSP_DIR"
    source build/envsetup.sh
    lunch "$LUNCH_PRODUCT" bp2a userdebug
    m android.hardware.security.keymint-service llndk.libraries.txt
  )
fi

SVC_RSP="$AOSP_DIR/out/soong/.intermediates/hardware/interfaces/security/keymint/aidl/default/android.hardware.security.keymint-service/android_vendor_${SOONG_VARIANT}_cfi/unstripped/android.hardware.security.keymint-service.rsp"
if [[ ! -f "$SVC_RSP" ]]; then
  echo "[build-keymint] ERROR: missing build artifact: $SVC_RSP" >&2
  echo "  Re-run with --rebuild, or build manually: cd $AOSP_DIR && source build/envsetup.sh &&" >&2
  echo "  lunch $LUNCH_PRODUCT bp2a userdebug && m android.hardware.security.keymint-service llndk.libraries.txt" >&2
  exit 1
fi

STAGE_DIR="var/share/gfx_hal$STAGE_SUFFIX"
mkdir -p "$STAGE_DIR"

SVC_OUT="var/bin/rhizo-keymint-service$STAGE_SUFFIX"
mkdir -p "$ROOT/var/bin" "$STAGE_DIR"
python3 tools/build/hal/relink-keymint-static.py "$AOSP_DIR" "$ROOT/$SVC_OUT" "$ARCH"
cp --remove-destination "$SVC_OUT" "$STAGE_DIR/rhizo-keymint-service"
chmod 755 "$SVC_OUT" "$STAGE_DIR/rhizo-keymint-service"
rm -f "$STAGE_DIR/libkeymint.so" "$STAGE_DIR/libkeymint.so.srchash" \
      "$STAGE_DIR/lib_android_keymaster_keymint_utils.so"

if [[ -z "$STAGE_SUFFIX" ]]; then
  cp --remove-destination "$SVC_OUT" "var/share/rhizo-keymint-service"
  chmod 755 "var/share/rhizo-keymint-service"
  (cd "$ROOT" && python3 tools/build/stamps.py stamp rhizo-keymint-service) || exit 1
fi

echo "[build-keymint] staged real AOSP KeyMint port ($ARCH), self-contained:"
echo "  $SVC_OUT         ($(sha256sum "$SVC_OUT" | cut -c1-16)...)"
