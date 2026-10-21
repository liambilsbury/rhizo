#!/bin/bash
# build wlr-inject into var/share
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="test/system/inject/wlr-inject.c"
OUT="var/share/wlr-inject"
PTR_XML="src/services/deskbridge/protocols/wlr-virtual-pointer-unstable-v1.xml"
KBD_XML="src/services/deskbridge/protocols/virtual-keyboard-unstable-v1.xml"

pkg-config --exists wayland-client || {
  echo "[build-wlr-inject] wayland-client dev files missing (apt-get install libwayland-dev)" >&2
  exit 1
}
pkg-config --exists xkbcommon || {
  echo "[build-wlr-inject] xkbcommon dev files missing (apt-get install libxkbcommon-dev)" >&2
  exit 1
}
command -v wayland-scanner >/dev/null || {
  echo "[build-wlr-inject] wayland-scanner missing (apt-get install libwayland-bin)" >&2
  exit 1
}
[[ -f "$SRC" ]] || { echo "[build-wlr-inject] missing $SRC" >&2; exit 1; }

GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT

wayland-scanner client-header "$PTR_XML" \
  "$GEN/wlr-virtual-pointer-unstable-v1-client-protocol.h"
wayland-scanner private-code "$PTR_XML" \
  "$GEN/wlr-virtual-pointer-unstable-v1-protocol.c"
wayland-scanner client-header "$KBD_XML" \
  "$GEN/virtual-keyboard-unstable-v1-client-protocol.h"
wayland-scanner private-code "$KBD_XML" \
  "$GEN/virtual-keyboard-unstable-v1-protocol.c"

mkdir -p var/share
# shellcheck disable=SC2046
gcc -O2 -Wall -Wextra -Werror -I"$GEN" -o "$OUT" "$SRC" \
  "$GEN/wlr-virtual-pointer-unstable-v1-protocol.c" \
  "$GEN/virtual-keyboard-unstable-v1-protocol.c" \
  $(pkg-config --cflags --libs wayland-client xkbcommon)
chmod 0755 "$OUT"

./tools/build/stamps.py stamp wlr-inject

echo "[build-wlr-inject] OK -> var/share/wlr-inject ($(pkg-config --modversion wayland-client), xkbcommon $(pkg-config --modversion xkbcommon))"
