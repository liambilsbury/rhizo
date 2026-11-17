#!/bin/bash
# var/share/rhizo-wlbridge RHIZO_INPUT_CACHE=
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
  command -v "$CC" >/dev/null || { echo "no $CC in PATH" >&2; exit 1; }
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig
  export PKG_CONFIG_SYSROOT_DIR=/
elif [[ -n "${1:-}" ]]; then
  OUT="$1"
fi
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
WLPROTOCOLS_TAR="$CACHE/wlprotocols/wayland-protocols-1.45.tar.xz"
WLPROTOCOLS_SHA=$(sed -n 's/^SHA256\[wlprotocols\]=//p' tools/fetch/build-inputs.sh)
[[ -f "$WLPROTOCOLS_TAR" ]] || {
  echo "no $WLPROTOCOLS_TAR" >&2
  exit 1
}
[[ -n "$WLPROTOCOLS_SHA" && "$(sha256sum "$WLPROTOCOLS_TAR" | cut -d' ' -f1)" == "$WLPROTOCOLS_SHA" ]] || {
  echo "sha256 of $WLPROTOCOLS_TAR is not SHA256[wlprotocols] in tools/fetch/build-inputs.sh" >&2
  exit 1
}

pkg-config --exists wayland-client || {
  echo "pkg-config --exists wayland-client failed${ARCH_SUFFIX:+ for arm64}" >&2
  exit 1
}
WLR_PROTOCOLS_DIR=$(env -u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR pkg-config --variable=pkgdatadir wayland-protocols 2>/dev/null || true)
if [[ -z "$WLR_PROTOCOLS_DIR" ]]; then
  echo "pkg-config --variable=pkgdatadir wayland-protocols printed nothing" >&2
  exit 1
fi
command -v wayland-scanner >/dev/null || {
  echo "no wayland-scanner in PATH" >&2
  exit 1
}
[[ -f "$SRC" ]] || { echo "no $SRC" >&2; exit 1; }

XDG_SHELL_XML="$WLR_PROTOCOLS_DIR/stable/xdg-shell/xdg-shell.xml"
[[ -f "$XDG_SHELL_XML" ]] || {
  echo "no $XDG_SHELL_XML" >&2
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
  echo "no $XDG_OUTPUT_XML" >&2
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

echo "wrote $OUT (wayland-client $(pkg-config --modversion wayland-client))"

if [[ -n "$ARCH_SUFFIX" ]]; then
  exit 0
fi

if [[ "$OUT" == var/share/rhizo-wlbridge ]]; then ./tools/build/stamps.py stamp rhizo-wlbridge; fi
