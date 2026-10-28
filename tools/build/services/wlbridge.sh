#!/bin/bash
# build rhizo-wlbridge into var/share
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
SRC="./src/services/deskbridge/wlbridge.c"
CC=gcc
ARCH_SUFFIX=""
OUT="var/share/rhizo-wlbridge"
if [[ "${1:-}" == --arch && "${2:-}" == aarch64 ]]; then
  CC=aarch64-linux-gnu-gcc
  ARCH_SUFFIX="-aarch64"
  OUT="var/share/rhizo-wlbridge$ARCH_SUFFIX"
  command -v "$CC" >/dev/null || { echo "[build-wlbridge] no $CC -- apt install gcc-aarch64-linux-gnu" >&2; exit 1; }
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=/
elif [[ -n "${1:-}" ]]; then
  OUT="$1"
fi
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
WLPROTOCOLS_TAR="$CACHE/wlprotocols/wayland-protocols-1.45.tar.xz"
WLPROTOCOLS_SHA=$(sed -n 's/^SHA256\[wlprotocols\]=//p' tools/fetch/build-inputs.sh)
[[ -f "$WLPROTOCOLS_TAR" ]] || {
  echo "[build-wlbridge] no $WLPROTOCOLS_TAR -- run tools/fetch/build-inputs.sh --only wlprotocols" >&2
  exit 1
}
[[ -n "$WLPROTOCOLS_SHA" && "$(sha256sum "$WLPROTOCOLS_TAR" | cut -d' ' -f1)" == "$WLPROTOCOLS_SHA" ]] || {
  echo "[build-wlbridge] $WLPROTOCOLS_TAR does not match the sha256 tools/fetch/build-inputs.sh pins" >&2
  exit 1
}

pkg-config --exists wayland-client || {
  echo "[build-wlbridge] wayland-client dev files missing${ARCH_SUFFIX:+ for arm64 -- dpkg --add-architecture arm64 && apt-get install libwayland-dev:arm64} (apt-get install libwayland-dev)" >&2
  exit 1
}
WLR_PROTOCOLS_DIR=$(env -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR pkg-config --variable=pkgdatadir wayland-protocols 2>/dev/null || true)
if [[ -z "$WLR_PROTOCOLS_DIR" ]]; then
  echo "[build-wlbridge] wayland-protocols missing (apt-get install wayland-protocols)" >&2
  exit 1
fi
command -v wayland-scanner >/dev/null || {
  echo "[build-wlbridge] wayland-scanner missing (apt-get install libwayland-bin)" >&2
  exit 1
}
[[ -f "$SRC" ]] || { echo "[build-wlbridge] missing $SRC" >&2; exit 1; }

XDG_SHELL_XML="$WLR_PROTOCOLS_DIR/stable/xdg-shell/xdg-shell.xml"
[[ -f "$XDG_SHELL_XML" ]] || {
  echo "[build-wlbridge] missing $XDG_SHELL_XML" >&2
  exit 1
}

GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT

tar -xJf "$WLPROTOCOLS_TAR" -C "$GEN" --strip-components=3 \
  wayland-protocols-1.45/staging/ext-data-control/ext-data-control-v1.xml
PROTO_XMLS=(
  "src/services/deskbridge/protocols/wlr-data-control-unstable-v1.xml"
  "$GEN/ext-data-control-v1.xml"
  "src/services/deskbridge/protocols/wlr-layer-shell-unstable-v1.xml"
  "src/services/deskbridge/protocols/wlr-virtual-pointer-unstable-v1.xml"
)

XDG_OUTPUT_XML="$WLR_PROTOCOLS_DIR/unstable/xdg-output/xdg-output-unstable-v1.xml"
[[ -f "$XDG_OUTPUT_XML" ]] || {
  echo "[build-wlbridge] missing $XDG_OUTPUT_XML" >&2
  exit 1
}

GEN_SOURCES=()
for xml in "${PROTO_XMLS[@]}" "$XDG_SHELL_XML" "$XDG_OUTPUT_XML"; do
  base="$(basename "$xml" .xml)"
  wayland-scanner client-header "$xml" "$GEN/$base-client-protocol.h"
  wayland-scanner private-code "$xml" "$GEN/$base-protocol.c"
  GEN_SOURCES+=("$GEN/$base-protocol.c")
done

mkdir -p var/share
# shellcheck disable=SC2046
"$CC" -O2 -Wall -Wextra -Werror -I"$GEN" -o "$OUT" "$SRC" \
  "${GEN_SOURCES[@]}" \
  $(pkg-config --cflags --libs wayland-client)
chmod 0755 "$OUT"

echo "[build-wlbridge] OK -> $OUT ($(pkg-config --modversion wayland-client))"

if [[ -n "$ARCH_SUFFIX" ]]; then
  echo "[build-wlbridge] arm64 build -- not stamped"
  exit 0
fi

if [[ "$OUT" == var/share/rhizo-wlbridge ]]; then ./tools/build/stamps.py stamp rhizo-wlbridge; fi
