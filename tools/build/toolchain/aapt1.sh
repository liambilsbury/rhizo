#!/bin/bash
# stage aapt v1 and its libc++ into var/share
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
ROOT="$(pwd)"
SHARE="${RHIZO_SHARE_DIR:-$ROOT/var/share}"
BT="${RHIZO_ANDROID_SDK:-${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}/android-sdk}/build-tools/34.0.0"
FETCH="run tools/fetch/build-inputs.sh --only sdk --accept-android-sdk-license"

# print a prefixed progress line
log() { echo "[aapt1] $*"; }

# copy a file into place by rename
stage_file() {
  local src="$1" dst="$2" mode="$3"
  [[ -f "$src" ]] || { log "ERROR: no $src -- $FETCH"; return 1; }
  mkdir -p "$(dirname "$dst")" || return 1
  cp --remove-destination "$src" "$dst.part" || { log "ERROR: could not copy $src"; return 1; }
  chmod "$mode" "$dst.part" || return 1
  mv "$dst.part" "$dst" || { log "ERROR: could not rename into $dst"; return 1; }
}

pin=$(sed -n 's/^SHA256\[sdk_buildtools\]=//p' tools/fetch/build-inputs.sh)
[[ -n "$pin" ]] || { log "ERROR: no sdk_buildtools pin in tools/fetch/build-inputs.sh"; exit 1; }
[[ "$(cat "$BT/.rhizo-input" 2>/dev/null)" == "$pin" ]] || { log "ERROR: $BT is stale, hand-edited or absent (stamp is not $pin) -- $FETCH"; exit 1; }

stage_file "$BT/aapt" "$SHARE/aapt" 0755 || exit 1
stage_file "$BT/lib64/libc++.so" "$SHARE/aapt-libs/libc++.so" 0644 || exit 1
ver=$(LD_LIBRARY_PATH="$SHARE/aapt-libs" "$SHARE/aapt" version 2>&1) || { log "ERROR: staged aapt does not run: $ver"; exit 1; }
log "$ver -> $SHARE/aapt (from the pinned build-tools 34.0.0; test tooling, never shipped)"
