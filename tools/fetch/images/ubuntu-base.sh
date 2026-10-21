#!/bin/bash
# fetch the pinned Ubuntu 24.04 base image
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit

BASE_RELEASE="release-20260801"
BASE_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
BASE_URL="https://cloud-images.ubuntu.com/releases/noble/${BASE_RELEASE}/${BASE_NAME}"
BASE_SHA="0533b0655c32e68b31d792ecd6ccfca95abdbc536c4446874fe0513bd4140ffe"

DEST_DIR="var/pristine-dl"
DEST="$DEST_DIR/noble-server-cloudimg-amd64.img"

# print a prefixed progress line
log() { echo "[fetch-ubuntu-base] $*"; }

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

log "pin: noble/${BASE_RELEASE}/${BASE_NAME}"
log "     sha256 $BASE_SHA"
mkdir -p "$DEST_DIR" || { log "FAIL: cannot create $DEST_DIR"; exit 1; }

if [[ -f "$DEST" ]] && (( ! FORCE )); then
  have=$(sha256sum "$DEST" | cut -d' ' -f1)
  if [[ "$have" == "$BASE_SHA" ]]; then
    log "already present and sha256 matches -- nothing to do"
    log "BASE_IMAGE=$DEST"
    exit 0
  fi
  log "present but sha256 mismatch (have $have) -- refetching"
fi

if [[ -f var/noble-server-cloudimg-amd64.img ]]; then
  have=$(sha256sum var/noble-server-cloudimg-amd64.img | cut -d' ' -f1)
  if [[ "$have" == "$BASE_SHA" ]]; then
    log "var/noble-server-cloudimg-amd64.img is byte-identical to the pin -- reflinking"
    cp --reflink=auto var/noble-server-cloudimg-amd64.img "$DEST.part" || {
      log "FAIL: cannot copy the local image"; exit 1; }
    mv -f "$DEST.part" "$DEST"
    log "BASE_IMAGE=$DEST"
    exit 0
  fi
fi

log "downloading $BASE_URL"
curl -sS -L --retry 3 --retry-delay 5 -o "$DEST.part" "$BASE_URL" || {
  log "FAIL: download failed"; exit 1; }
have=$(sha256sum "$DEST.part" | cut -d' ' -f1)
if [[ "$have" != "$BASE_SHA" ]]; then
  log "FAIL: sha256 mismatch after download"
  log "  expected $BASE_SHA"
  log "  got      $have"
  rm -f "$DEST.part"
  exit 1
fi
mv -f "$DEST.part" "$DEST"
log "verified sha256 -- BASE_IMAGE=$DEST"
