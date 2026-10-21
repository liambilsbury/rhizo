#!/bin/bash
# build kde-inject against plasma-wayland-protocols
set -euo pipefail
src="${1:-/root/share/kde-inject.c}" out="${2:-/usr/local/bin/kde-inject}"
xml=/usr/share/plasma-wayland-protocols/fake-input.xml
[[ -r "$xml" ]] || { echo "no $xml -- install plasma-wayland-protocols" >&2; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
wayland-scanner client-header "$xml" "$work/fake-input-client-protocol.h"
wayland-scanner private-code "$xml" "$work/fake-input-protocol.c"
# shellcheck disable=SC2046
cc -O2 -Wall -Werror -I"$work" -o "$work/kde-inject" "$src" "$work/fake-input-protocol.c" $(pkg-config --cflags --libs wayland-client)
install -m 0755 "$work/kde-inject" "$out"
