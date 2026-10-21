#!/bin/bash
# fetch CTS and build VTS test suites
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../../test/vm/common.sh

SUITES_DIR="$VAR_DIR/suites"
mkdir -p "$SUITES_DIR"

CTS_URL="https://dl.google.com/dl/android/cts/android-cts-16.1_r4-linux_x86-x86.zip"
CTS_DESC="CTS 16.1 R4 (Android 16 / API 36), linux_x86-x86"

# print the pin file path for a downloaded file
pin_file_for() { echo "$SUITES_DIR/$(basename "$1").sha256"; }

# verify or record a file's sha256 pin
verify_or_pin() {
  local file="$1" pin_file have want
  pin_file=$(pin_file_for "$file")
  have=$(sha256sum "$file" | cut -d' ' -f1)
  if [[ -f "$pin_file" ]]; then
    want=$(cat "$pin_file")
    if [[ "$have" != "$want" ]]; then
      log "FAIL: $file sha256 mismatch vs recorded pin"
      log "  pinned $want"; log "  got    $have"
      return 1
    fi
    log "$(basename "$file") sha256 verified against recorded pin ($have)"
  else
    echo "$have" > "$pin_file"
    log "$(basename "$file"): first-observed sha256 pinned: $have"
  fi
  return 0
}

# download the CTS zip and verify its pin
fetch_cts() {
  local zip="$SUITES_DIR/android-cts-16.1_r4-linux_x86-x86.zip"
  log "=== CTS: $CTS_DESC"
  if [[ -f "$zip" ]] && verify_or_pin "$zip"; then
    log "zip already present, pin verified"
  else
    log "downloading $(basename "$CTS_URL") (22.1 GiB, this takes a while) ..."
    curl -sS -L -C - --retry 3 --retry-delay 5 -o "$zip.part" "$CTS_URL" || {
      log "FAIL: download failed"; exit 1; }
    mv "$zip.part" "$zip"
    verify_or_pin "$zip" || { rm -f "$zip"; exit 1; }
    log "downloaded, sha256 pinned"
  fi
  if [[ ! -x "$SUITES_DIR/android-cts/tools/cts-tradefed" ]]; then
    log "extracting android-cts/ (large archive, extraction takes a while) ..."
    rm -rf "$SUITES_DIR/android-cts"
    unzip -o -q "$zip" -d "$SUITES_DIR" || { log "FAIL: unzip failed"; exit 1; }
    chmod +x "$SUITES_DIR/android-cts/tools/cts-tradefed" 2>/dev/null || true
  fi
  test -f "$SUITES_DIR/android-cts/tools/cts-tradefed" || {
    log "FAIL: android-cts/tools/cts-tradefed missing after extract"; exit 1; }
  log "=== CTS ready at $SUITES_DIR/android-cts"
}

# build the VTS zip if missing and verify its pin
fetch_vts() {
  local zip="$SUITES_DIR/android-vts.zip"
  log "=== VTS: source build at android16-release (no prebuilt exists)"
  if [[ ! -f "$zip" ]]; then
    "$REPO/tools/build/test-tools/vts.sh" || { log "FAIL: vts.sh failed"; exit 1; }
  fi
  test -f "$zip" || { log "FAIL: $zip still missing after vts.sh"; exit 1; }
  verify_or_pin "$zip" || exit 1
  if [[ ! -d "$SUITES_DIR/android-vts" ]]; then
    log "extracting android-vts/ ..."
    rm -rf "$SUITES_DIR/android-vts"
    unzip -o -q "$zip" -d "$SUITES_DIR" || { log "FAIL: unzip failed"; exit 1; }
  fi
  test -f "$SUITES_DIR/android-vts/tools/vts-tradefed" || {
    log "FAIL: android-vts/tools/vts-tradefed missing after extract"; exit 1; }
  log "=== VTS ready at $SUITES_DIR/android-vts"
}

case "${1:-}" in
  cts) fetch_cts ;;
  vts) fetch_vts ;;
  *) echo "usage: $0 <cts|vts>" >&2; exit 2 ;;
esac
