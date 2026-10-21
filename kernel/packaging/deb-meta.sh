#!/bin/bash
# build the linux-image-rhizo and linux-headers-rhizo packages
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=$1
img=$(cd "$out" && ls linux-image-*-rhizo_*.deb | head -1)
rel=${img#linux-image-}; rel=${rel%%_*}; ver=$(dpkg-deb -f "$out/$img" Version)
for kind in image headers; do
  d=$(mktemp -d); mkdir -p "$d/DEBIAN" "$d/usr/share/doc/linux-$kind-rhizo"
  install -m 0644 "$here/copyright" "$d/usr/share/doc/linux-$kind-rhizo/copyright"
  printf 'Package: linux-%s-rhizo\nVersion: %s\nArchitecture: amd64\nMaintainer: Liam Bilsbury <liam.bilsbury@proton.me>\nDepends: linux-%s-%s (= %s)\nDescription: Rhizo kernel with SELinux namespaces (%s)\n' \
    "$kind" "$ver" "$kind" "$rel" "$ver" "$kind" > "$d/DEBIAN/control"
  dpkg-deb --build --root-owner-group "$d" "$out/linux-$kind-rhizo_${ver}_amd64.deb"
  rm -r "$d"
done
