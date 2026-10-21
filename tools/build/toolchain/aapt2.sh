#!/bin/bash
# build aapt2 from AOSP into var/share
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit
ROOT="$(cd "." && pwd)"
AOSP_DIR="$ROOT/aosp-android16-qpr2"
NINJA="$AOSP_DIR/prebuilts/build-tools/linux-x86/bin/ninja"
COMBINED_NINJA="out/combined-aosp_x86_64.ninja"
TARGET_REL="out/host/linux-x86/bin/aapt2"
BIN_SRC="$AOSP_DIR/$TARGET_REL"
OUT_BIN="$ROOT/var/share/aapt2"
PROV="$ROOT/var/share/aapt2.PROVENANCE"
FIXTURE="$ROOT/var/share/rhizo-test-fixture.apk"
EV_DIR="$ROOT/var/scratch/aapt2-build"
J="${RHIZO_BUILD_J:-18}"
PROJECT_COUNT=0
STRIP_BIN=""

# print a prefixed progress line
log() { echo "[build-aapt2] $*"; }

STAGE_ONLY=0
case "${1:-}" in
  "") ;;
  --stage-only) STAGE_ONLY=1 ;;
  *) log "ERROR: unknown argument: $1"; exit 2 ;;
esac

if [[ ! -d "$AOSP_DIR" ]]; then
  log "ERROR: $AOSP_DIR not found -- run make inputs"
  exit 1
fi

# list the ninja inputs of the aapt2 binary
ninja_inputs() {
  [[ -x "$NINJA" ]] || { log "ERROR: no ninja at $NINJA"; return 1; }
  [[ -f "$AOSP_DIR/$COMBINED_NINJA" ]] \
    || { log "ERROR: no $COMBINED_NINJA in $AOSP_DIR -- run without --stage-only"; return 1; }
  "$NINJA" -C "$AOSP_DIR" -f "$COMBINED_NINJA" -t inputs "$TARGET_REL" \
    || { log "ERROR: ninja could not list the inputs of $TARGET_REL"; return 1; }
}

# check each source git project for changes
assert_stock_sources() {
  local d root p st dirty=0
  declare -A seen=()
  while IFS= read -r d; do
    root="$d"
    while [[ -n "$root" ]]; do
      [[ -e "$AOSP_DIR/$root/.git" ]] && break
      [[ "$root" == */* ]] || { root=""; break; }
      root="${root%/*}"
    done
    if [[ -z "$root" ]]; then
      log "ERROR: build input $d is under no git project"
      return 1
    fi
    seen["$root"]=1
  done < <(grep -v '^out/' <<<"$1" | sed 's|/[^/]*$||' | sort -u)
  PROJECT_COUNT=${#seen[@]}
  (( PROJECT_COUNT > 0 )) || { log "ERROR: $TARGET_REL names no source input at all"; return 1; }
  for p in "${!seen[@]}"; do
    st=$(git -C "$AOSP_DIR/$p" status --short 2>&1)
    if [[ -n "$st" ]]; then
      log "ERROR: aapt2 is built from $p, and it is modified:"
      head -20 <<<"$st" | sed 's/^/    /'
      dirty=1
    fi
  done
  (( dirty == 0 )) || {
    log "ERROR: revert those before building."
    return 1
  }
  log "source projects: $PROJECT_COUNT, all clean"
}

# find llvm-strip in the clang release
resolve_strip_tool() {
  local clang
  clang=$(grep -o 'prebuilts/clang/host/linux-x86/clang-[^/]*' <<<"$1" | sort -u)
  if [[ -z "$clang" || $(wc -l <<<"$clang") -ne 1 ]]; then
    log "ERROR: the inputs of $TARGET_REL name $(wc -l <<<"$clang") clang releases, expected one:"
    sed 's/^/    /' <<<"$clang"
    return 1
  fi
  STRIP_BIN="$AOSP_DIR/$clang/bin/llvm-strip"
  [[ -x "$STRIP_BIN" ]] || { log "ERROR: no llvm-strip at $STRIP_BIN"; return 1; }
}

# run the staged aapt2 on the fixture APK
verify_binary() {
  local ver label
  ver=$("$OUT_BIN" version 2>&1) || { log "ERROR: $OUT_BIN version: $ver"; return 1; }
  log "$ver"
  if [[ ! -f "$FIXTURE" ]]; then
    log "ERROR: no APK at $FIXTURE."
    log "  Run tools/fetch/test-apk.sh, then this script again."
    return 1
  fi
  local badging
  badging=$("$OUT_BIN" dump badging "$FIXTURE" 2>&1) \
    || { log "ERROR: $OUT_BIN dump badging $FIXTURE failed: $badging"; return 1; }
  label=$(grep -m1 '^application-label' <<<"$badging") \
    || { log "ERROR: no application-label out of $FIXTURE"; return 1; }
  log "$label"
}

# write the provenance record beside the binary
write_provenance() {
  local sha unstripped_sha manifest_rev manifest_commit build_id fb_commit f
  sha=$(sha256sum "$OUT_BIN" | cut -d' ' -f1)
  unstripped_sha=$(sha256sum "$BIN_SRC" | cut -d' ' -f1)
  manifest_rev=$(sed -n 's/.*<default[^>]*revision="\([^"]*\)".*/\1/p' \
    "$AOSP_DIR/.repo/manifests/default.xml" | head -1)
  manifest_commit=$(git -C "$AOSP_DIR/.repo/manifests" rev-parse HEAD)
  build_id=$(sed -n 's/^BUILD_ID=//p' "$AOSP_DIR/build/make/core/build_id.mk")
  fb_commit=$(git -C "$AOSP_DIR/frameworks/base" rev-parse HEAD)
  for f in "$sha" "$unstripped_sha" "$manifest_rev" "$manifest_commit" "$build_id" "$fb_commit"; do
    [[ -n "$f" ]] || { log "ERROR: could not read the tree's own pin -- provenance refused"; return 1; }
  done
  cat > "$PROV" <<EOF
aapt2, built from AOSP source -- not the Android SDK build-tools binary
binary: var/share/aapt2, packaged as /usr/lib/rhizo/tools/aapt2
license: Apache-2.0 and Apache-2.0 WITH LLVM-exception and BSD-3-Clause and MIT and Zlib and libpng-2.0 (debian/copyright, Files: usr/lib/rhizo/tools/aapt2)
soong-target: aapt2 (cc_binary_host, frameworks/base/tools/aapt2/Android.bp)
lunch: aosp_x86_64 bp2a userdebug
manifest-branch: $manifest_rev
manifest-commit: $manifest_commit
build-id: $build_id
frameworks/base-commit: $fb_commit
source-projects: $PROJECT_COUNT git projects in the binary's ninja input set, every one clean at build time
built: $(date -u -d "@$(stat -c %Y "$BIN_SRC")" +%Y-%m-%dT%H:%M:%SZ)
built-by: tools/build/toolchain/aapt2.sh
stripped-with: ${STRIP_BIN#$AOSP_DIR/}
unstripped-sha256: $unstripped_sha
sha256: $sha
EOF
}

if (( ! STAGE_ONLY )); then
  mkdir -p "$EV_DIR" || exit 1
  log "building aapt2 (lunch aosp_x86_64 bp2a userdebug, -j$J) ..."
  if ! { ( set +u
           cd "$AOSP_DIR"
           source build/envsetup.sh
           lunch aosp_x86_64 bp2a userdebug
           m -j"$J" aapt2
         ) 2>&1 | tee "$EV_DIR/build.log"; }; then
    log "ERROR: build failed -- see $EV_DIR/build.log"
    exit 1
  fi
fi

[[ -f "$BIN_SRC" ]] || {
  log "ERROR: no host binary at $BIN_SRC -- re-run without --stage-only"
  exit 1
}
INPUTS=$(ninja_inputs) || exit 1
assert_stock_sources "$INPUTS" || exit 1
resolve_strip_tool "$INPUTS" || exit 1

mkdir -p "$ROOT/var/share" || exit 1
cp --remove-destination "$BIN_SRC" "$OUT_BIN.part" || { log "ERROR: could not copy $BIN_SRC into var/share"; exit 1; }
"$STRIP_BIN" "$OUT_BIN.part" || { log "ERROR: $STRIP_BIN could not strip the copy"; exit 1; }
chmod 0755 "$OUT_BIN.part" || exit 1
mv "$OUT_BIN.part" "$OUT_BIN" || { log "ERROR: could not rename into place"; exit 1; }
log "staged -> $OUT_BIN ($(stat -c%s "$OUT_BIN") bytes, from $(stat -c%s "$BIN_SRC") unstripped)"

verify_binary || exit 1
write_provenance || exit 1
log "provenance -> $PROV"
