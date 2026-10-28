#!/bin/bash
# packs the source of GSI projects whose license requires sharing it
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

# print a prefixed progress line
log() { echo "[gsi-source] $*" >&2; }
# print the usage text
usage() {
  cat <<'EOF'
usage: gsi-source.sh [--release a16|a17] [--revision N]
       gsi-source.sh --selftest
EOF
}

# print the AOSP projects the share list names
share_projects() { cut -d, -f1 "$1" | sed '/^$/d; /^UPSTREAM$/d' | sort -u; }

# print the upstream components missing a source tarball
missing_upstream() {
  local list="$1" dir="$2" path
  sed -n 's/^UPSTREAM,\([^ ]*\).*/\1/p' "$list" | while read -r path; do
    compgen -G "$dir/${path##*/}.source.tar.*" >/dev/null || echo "$path"
  done
}

# write a tar of all of the projects read from stdin
archive_projects() {
  local aosp="$1" out="$2" p part
  part=$(mktemp)
  rm -f "$out"
  while read -r p; do
    git -C "$aosp/$p" archive --format=tar --prefix="$p/" HEAD > "$part" || { log "git archive failed in $p"; rm -f "$part"; return 1; }
    if [[ -f "$out" ]]; then tar -Af "$out" "$part"; else cp --remove-destination "$part" "$out"; fi
  done
  rm -f "$part"
}

# check the project list and the archive on fixture repos
selftest() {
  local tmp fail=0 p list out
  tmp=$(mktemp -d)
  for p in external/iptables external/e2fsprogs; do
    mkdir -p "$tmp/aosp/$p"
    git -C "$tmp/aosp/$p" init -q
    echo "$p" > "$tmp/aosp/$p/README"
    git -C "$tmp/aosp/$p" add README
    git -C "$tmp/aosp/$p" -c user.name=t -c user.email=t@t commit -q -m base
  done
  printf 'external/iptables,/system/bin/iptables:iptables\nexternal/e2fsprogs,/system/bin/mke2fs:e2fsprogs\nexternal/iptables,/system/bin/ip6tables:iptables\nUPSTREAM,apex:com.x.apex/etc/kernel Linux\n' > "$tmp/share.csv"
  list=$(share_projects "$tmp/share.csv")
  [[ "$list" == $'external/e2fsprogs\nexternal/iptables' ]] || { echo "FAIL projects listed once each, sorted -- got: $list"; fail=1; }
  archive_projects "$tmp/aosp" "$tmp/out.tar" <<< "$list" 2>/dev/null
  [[ "$(tar -tf "$tmp/out.tar" 2>/dev/null | grep -c README)" == 2 ]] || { echo "FAIL both projects archived"; fail=1; }
  tar -tf "$tmp/out.tar" 2>/dev/null | grep -qx 'external/iptables/README' || { echo "FAIL archived under the project path"; fail=1; }
  mkdir -p "$tmp/upstream"
  out=$(missing_upstream "$tmp/share.csv" "$tmp/upstream")
  [[ "$out" == "apex:com.x.apex/etc/kernel" ]] || { echo "FAIL an upstream component with no bundled source is named -- got: $out"; fail=1; }
  touch "$tmp/upstream/kernel.source.tar.zst"
  out=$(missing_upstream "$tmp/share.csv" "$tmp/upstream")
  [[ -z "$out" ]] || { echo "FAIL an upstream component with its source bundled is not named -- got: $out"; fail=1; }
  local self="${BASH_SOURCE[0]}"
  out=$(RHIZO_AOSP_A17_DIR="$tmp/none" "$self" --release a17 2>&1)
  [[ $? -ne 0 && "$out" == *"no $tmp/none/out-gsi-user -- run tools/build/image/gsi.sh --release a17 --variant user first"* ]] \
    || { echo "FAIL an a17 bundle reads the android17 checkout -- got: $out"; fail=1; }
  out=$("$self" --release a18 2>&1)
  [[ $? -eq 2 && "$out" == *"--release must be a16 or a17"* ]] || { echo "FAIL an unknown release is refused -- got: $out"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "gsi-source.sh selftest: FAILED"; return 1; fi
  echo "gsi-source.sh selftest: ok"
}

# print the paths inside an apex, extracting an erofs payload deapexer cannot list
apex_paths() {
  local a="$1" d rc=0
  "$BIN/deapexer" --debugfs_path "$BIN/debugfs" --fsckerofs_path "$BIN/fsck.erofs" list "$a" 2>/dev/null && return 0
  d=$(mktemp -d) || return 1
  if "$BIN/deapexer" --debugfs_path "$BIN/debugfs" --fsckerofs_path "$BIN/fsck.erofs" extract "$a" "$d/x" >/dev/null; then
    (cd "$d/x" && find . -mindepth 1 | sort)
  else
    rc=1
  fi
  rm -rf "$d"
  return $rc
}

[[ "${1:-}" == --selftest ]] && { selftest; exit $?; }

RELEASE=a16 REVISION=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
ROOT="$PWD"
case "$RELEASE" in
  a16) AOSP_DIR="$(readlink -f "${RHIZO_AOSP_DIR:-$ROOT/aosp-android16-qpr2}")" PIN_VAR=AOSP_BUILD_ID PIN_FILE=tools/fetch/build-inputs.sh
       PREBUILT_TABLE=tools/build/image/gsi-prebuilt-licenses.tsv ;;
  a17) AOSP_DIR="$(readlink -f "${RHIZO_AOSP_A17_DIR:-$ROOT/aosp-android17}")" PIN_VAR=AOSP_A17_BUILD_ID PIN_FILE=tools/fetch/aosp-a17.sh
       PREBUILT_TABLE=tools/build/image/gsi-prebuilt-licenses-a17.tsv ;;
  *) log "--release must be a16 or a17"; exit 2 ;;
esac
BUILD_DIR="$ROOT/var/gsi-build"
PIN_ID=$(sed -n "s/^$PIN_VAR=//p" "$ROOT/$PIN_FILE")
[[ -n "$PIN_ID" ]] || { log "no $PIN_VAR in $PIN_FILE"; exit 1; }
OUT_DIR="out-gsi-user"
BASE="$BUILD_DIR/gpl-source-$PIN_ID-$REVISION.tar"
LIST="$BUILD_DIR/gpl-projects-$PIN_ID-$REVISION.txt"
[[ -d "$AOSP_DIR/$OUT_DIR" ]] || { log "no $AOSP_DIR/$OUT_DIR -- run tools/build/image/gsi.sh --release $RELEASE --variant user first"; exit 1; }
PRODUCT_OUT="$OUT_DIR/target/product/generic_x86_64"
BIN="$AOSP_DIR/$OUT_DIR/host/linux-x86/bin"
UPSTREAM_DIR="$BUILD_DIR/upstream"; [[ "$RELEASE" == a16 ]] || UPSTREAM_DIR="$BUILD_DIR/upstream-$RELEASE"
mkdir -p "$UPSTREAM_DIR"
TF="$AOSP_DIR/$OUT_DIR/dist/gsi_x86_64-target_files-rhizo$REVISION.zip"
[[ -f "$TF" ]] || { log "no $TF -- build revision $REVISION first"; exit 1; }
log "listing the image's files and each APEX's contents"
unzip -Z1 "$TF" 'SYSTEM/*' | sed -n 's|^SYSTEM/||p' > "$BUILD_DIR/image.txt" || exit 1
: > "$BUILD_DIR/apex.txt"
t=$(mktemp -d)
for f in "$AOSP_DIR/$PRODUCT_OUT"/system/apex/*.apex "$AOSP_DIR/$PRODUCT_OUT"/system/apex/*.capex; do
  [[ -f "$f" ]] || continue
  a="$f"
  if [[ "$f" == *.capex ]]; then
    unzip -q -o "$f" original_apex -d "$t" || { log "cannot unpack $f"; exit 1; }
    a="$t/original_apex"
  fi
  apex_paths "$a" | sed "s|^\./||; s|^|${f##*/}\t|" >> "$BUILD_DIR/apex.txt" || { log "deapexer cannot list $f"; exit 1; }
done
rm -rf "$t"
log "listing the projects of every GPL-family module and file in the image"
python3 "$ROOT/tools/build/image/gsi-share-list.py" "$AOSP_DIR" "$PRODUCT_OUT" \
  "$AOSP_DIR/$OUT_DIR/soong/compliance-metadata/gsi_x86_64/compliance-metadata.db" "$BUILD_DIR/apex.txt" "$BUILD_DIR/image.txt" \
  "$ROOT/$PREBUILT_TABLE" > "$BUILD_DIR/share.csv" || { log "the share list is incomplete -- see above"; exit 1; }
cp "$BUILD_DIR/share.csv" "$LIST"
share_projects "$BUILD_DIR/share.csv" > "$BUILD_DIR/share.projects"
log "$(wc -l < "$BUILD_DIR/share.projects") projects to share"
rm -f "$BASE" "$BASE.zst" "$BASE.zst."*
archive_projects "$AOSP_DIR" "$BASE" < "$BUILD_DIR/share.projects" || exit 1
zstd -q -f -T0 --rm "$BASE" -o "$BASE.zst" || exit 1
if (( $(stat -c%s "$BASE.zst") > 1900 * 1024 * 1024 )); then
  split -b 1900M -d -a 3 "$BASE.zst" "$BASE.zst." && rm "$BASE.zst"
  parts=("$BASE.zst."*); log "split into ${#parts[@]} parts"
fi
chmod 0644 "$BASE.zst"* "$LIST"
log "wrote $BASE.zst* and $LIST"
missing=$(missing_upstream "$BUILD_DIR/share.csv" "$UPSTREAM_DIR")
if [[ -n "$missing" ]]; then
  log "these GPL prebuilts have no bundled source in $UPSTREAM_DIR (<name>.source.tar.*):"
  printf '  %s\n' $missing >&2
  exit 2
fi
for f in "$UPSTREAM_DIR"/*.source.tar.*; do [[ -f "$f" ]] && cp "$f" "$BUILD_DIR/"; done
