#!/bin/bash
# run makepkg in each build directory as uid 1000
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: run-makepkg.sh <packager>" >&2; exit 2; }
packager=$1
src=/root/share/arch-build
user=$(getent passwd 1000 | cut -d: -f1)
home=$(getent passwd 1000 | cut -d: -f6)
[[ -n "$user" && -d "$home" ]] || { echo "no uid 1000 with a home directory to run makepkg as" >&2; exit 1; }
work="$home/rhizo-arch-build"
trap 'rm -rf "$work"' EXIT
rm -rf "$work" "$src/out"
install -d -o "$user" -g "$user" "$work"
mkdir "$src/out"
for d in "$src"/*/; do
  name=$(basename "$d")
  [[ "$name" == out ]] || cp -r "$d" "$work/$name"
done
chown -R "$user:$user" "$work"
for d in "$work"/*/; do
  epoch=$(cat "$d/SOURCE_DATE_EPOCH")
  echo "== makepkg in $d, SOURCE_DATE_EPOCH=$epoch"
  runuser -u "$user" -- env -C "$d" SOURCE_DATE_EPOCH="$epoch" PKGDEST="$d" PACKAGER="$packager" \
    makepkg -f -d --noconfirm
  cp "$d"/*.pkg.tar.zst "$src/out/"
done
