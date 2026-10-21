#!/bin/bash
# check the meta packages deb-meta.sh builds
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
tmp=$(mktemp -d); trap 'rm -r "$tmp"' EXIT
failed=0
# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; failed=1; fi
}

kr=7.1.0-rc1-rhizo ver=7.1.0-rc1-rhizo-40
mkdir -p "$tmp/img/DEBIAN" "$tmp/out"
printf 'Package: linux-image-%s\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@t>\nDescription: t\n' "$kr" "$ver" \
  > "$tmp/img/DEBIAN/control"
dpkg-deb --build --root-owner-group "$tmp/img" "$tmp/out/linux-image-${kr}_${ver}_amd64.deb" >/dev/null
"$root/kernel/packaging/deb-meta.sh" "$tmp/out" >/dev/null 2>&1; rc=$?
check "deb-meta.sh exits 0" "$rc" 0
for kind in image headers; do
  deb=$tmp/out/linux-$kind-rhizo_${ver}_amd64.deb
  check "linux-$kind-rhizo depends on linux-$kind-$kr at $ver" "$(dpkg-deb -f "$deb" Depends 2>&1)" "linux-$kind-$kr (= $ver)"
  dpkg-deb -x "$deb" "$tmp/x-$kind" 2>/dev/null
  check "linux-$kind-rhizo carries kernel/packaging/copyright" \
    "$(cmp -s "$tmp/x-$kind/usr/share/doc/linux-$kind-rhizo/copyright" "$root/kernel/packaging/copyright"; echo $?)" 0
done
exit "$failed"
