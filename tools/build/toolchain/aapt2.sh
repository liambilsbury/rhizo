#!/bin/bash
# var/share/aapt2 var/share/aapt2.PROVENANCE RHIZO_BUILD_J=
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

# print a [build-aapt2] line to stdout
log() { echo "[build-aapt2] $*"; }

STAGE_ONLY=0
case "${1:-}" in
  "") ;;
  --stage-only) STAGE_ONLY=1 ;;
  *) log "unknown argument $1"; exit 2 ;;
esac

if [[ ! -d "$AOSP_DIR" ]]; then
  log "no $AOSP_DIR"
  exit 1
fi

# list the ninja inputs of the aapt2 binary
ninja_inputs() {
  [[ -x "$NINJA" ]] || { log "no $NINJA"; return 1; }
  [[ -f "$AOSP_DIR/$COMBINED_NINJA" ]] \
    || { log "no $COMBINED_NINJA in $AOSP_DIR"; return 1; }
  "$NINJA" -C "$AOSP_DIR" -f "$COMBINED_NINJA" -t inputs "$TARGET_REL" \
    || { log "ninja -t inputs $TARGET_REL failed"; return 1; }
}

# run git status --short in each source project of the ninja inputs
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
      log "no git project contains build input $d"
      return 1
    fi
    seen["$root"]=1
  done < <(grep -v '^out/' <<<"$1" | sed 's|/[^/]*$||' | sort -u)
  PROJECT_COUNT=${#seen[@]}
  (( PROJECT_COUNT > 0 )) || { log "ninja -t inputs $TARGET_REL has no source input"; return 1; }
  for p in "${!seen[@]}"; do
    st=$(git -C "$AOSP_DIR/$p" status --short 2>&1)
    if [[ -n "$st" ]]; then
      log "git -C $p status --short is not empty"
      head -20 <<<"$st" | sed 's/^/    /'
      dirty=1
    fi
  done
  (( dirty == 0 )) || return 1
  log "source_projects=$PROJECT_COUNT dirty=0"
}

# find llvm-strip in the clang release
resolve_strip_tool() {
  local clang
  clang=$(grep -o 'prebuilts/clang/host/linux-x86/clang-[^/]*' <<<"$1" | sort -u)
  if [[ -z "$clang" || $(wc -l <<<"$clang") -ne 1 ]]; then
    log "ninja -t inputs $TARGET_REL has $(wc -l <<<"$clang") clang releases, expected 1"
    sed 's/^/    /' <<<"$clang"
    return 1
  fi
  STRIP_BIN="$AOSP_DIR/$clang/bin/llvm-strip"
  [[ -x "$STRIP_BIN" ]] || { log "no $STRIP_BIN"; return 1; }
}

# run the staged aapt2 on the fixture APK
verify_binary() {
  local ver label
  ver=$("$OUT_BIN" version 2>&1) || { log "$OUT_BIN version failed ($ver)"; return 1; }
  log "$ver"
  if [[ ! -f "$FIXTURE" ]]; then
    log "no $FIXTURE"
    return 1
  fi
  local badging
  badging=$("$OUT_BIN" dump badging "$FIXTURE" 2>&1) \
    || { log "$OUT_BIN dump badging $FIXTURE failed ($badging)"; return 1; }
  label=$(grep -m1 '^application-label' <<<"$badging") \
    || { log "$OUT_BIN dump badging $FIXTURE has no application-label"; return 1; }
  log "$label"
}

# write $PROV
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
    [[ -n "$f" ]] || { log "failed to read the provenance fields"; return 1; }
  done
  cat > "$PROV" <<EOF
aapt2 built from AOSP source, not the Android SDK build-tools binary
binary: var/share/aapt2, packaged as /usr/lib/rhizo/tools/aapt2
license: Apache-2.0 and Apache-2.0 WITH LLVM-exception and BSD-3-Clause and MIT and Zlib and libpng-2.0 (debian/copyright, Files: usr/lib/rhizo/tools/aapt2)
soong-target: aapt2 (cc_binary_host, frameworks/base/tools/aapt2/Android.bp)
lunch: aosp_x86_64 bp2a userdebug
manifest-branch: $manifest_rev
manifest-commit: $manifest_commit
build-id: $build_id
frameworks/base-commit: $fb_commit
source-projects: $PROJECT_COUNT git projects in the aapt2 ninja input set, git status clean at build time
built: $(date -u -d "@$(stat -c %Y "$BIN_SRC")" +%Y-%m-%dT%H:%M:%SZ)
built-by: tools/build/toolchain/aapt2.sh
stripped-with: ${STRIP_BIN#$AOSP_DIR/}
unstripped-sha256: $unstripped_sha
sha256: $sha
EOF
}

if (( ! STAGE_ONLY )); then
  mkdir -p "$EV_DIR" || exit 1
  if ! { ( set +u
           cd "$AOSP_DIR"
           source build/envsetup.sh
           lunch aosp_x86_64 bp2a userdebug
           m -j"$J" aapt2
         ) 2>&1 | tee "$EV_DIR/build.log"; }; then
    log "m -j$J aapt2 failed (log $EV_DIR/build.log)"
    exit 1
  fi
fi

[[ -f "$BIN_SRC" ]] || {
  log "no $BIN_SRC"
  exit 1
}
INPUTS=$(ninja_inputs) || exit 1
assert_stock_sources "$INPUTS" || exit 1
resolve_strip_tool "$INPUTS" || exit 1

mkdir -p "$ROOT/var/share" || exit 1
cp --remove-destination "$BIN_SRC" "$OUT_BIN.part" || { log "failed to copy $BIN_SRC to $OUT_BIN.part"; exit 1; }
"$STRIP_BIN" "$OUT_BIN.part" || { log "$STRIP_BIN $OUT_BIN.part failed"; exit 1; }
chmod 0755 "$OUT_BIN.part" || exit 1
mv "$OUT_BIN.part" "$OUT_BIN" || { log "failed to rename $OUT_BIN.part to $OUT_BIN"; exit 1; }
log "staged $OUT_BIN bytes=$(stat -c%s "$OUT_BIN") unstripped_bytes=$(stat -c%s "$BIN_SRC")"

verify_binary || exit 1
write_provenance || exit 1
log "wrote $PROV"
