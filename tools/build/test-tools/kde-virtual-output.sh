#!/bin/bash
# build kde-virtual-output against plasma-wayland-protocols
set -euo pipefail
src="${1:-/root/share/kde-virtual-output.c}" out="${2:-/usr/local/bin/kde-virtual-output}"
xml=/usr/share/plasma-wayland-protocols/zkde-screencast-unstable-v1.xml
[[ -r "$xml" ]] || { echo "no $xml -- install plasma-wayland-protocols" >&2; exit 1; }
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
wayland-scanner client-header "$xml" "$work/zkde-screencast-unstable-v1-client-protocol.h"
wayland-scanner private-code "$xml" "$work/zkde-screencast-unstable-v1-protocol.c"
# shellcheck disable=SC2046
cc -O2 -Wall -Werror -I"$work" -o "$work/kde-virtual-output" "$src" "$work/zkde-screencast-unstable-v1-protocol.c" $(pkg-config --cflags --libs wayland-client)
install -m 0755 "$work/kde-virtual-output" "$out"
