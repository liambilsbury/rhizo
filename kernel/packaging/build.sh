#!/bin/bash
# Rhizo kernel package build
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cache=${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}
# print the package revision in kernel/VERSION
pkgrel() {
  local v
  v=$(< "$root/kernel/VERSION") || return 1
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "$root/kernel/VERSION is '$v', expected a positive integer" >&2; return 1; }
  echo "$v"
}

# set pkgrel of the tree PKGBUILD to RHIZO_PKGREL
pin_pacman_pkgrel() {
  local f="$1/scripts/package/PKGBUILD"
  # shellcheck disable=SC2016
  if ! grep -qx 'pkgrel="${KBUILD_REVISION}"' "$f"; then
    echo "$f pkgrel is not KBUILD_REVISION" >&2
    return 1
  fi
  # shellcheck disable=SC2016
  sed -i 's/^pkgrel="${KBUILD_REVISION}"$/pkgrel="${RHIZO_PKGREL}"/' "$f"
}

case "${1:-}" in
  --pkgrel) pkgrel; exit 0 ;;
  --pin-pacman-pkgrel) pin_pacman_pkgrel "$2"; exit ;;
esac
[[ "${1:-}" == cachyos || "${1:-}" == ubuntu ]] && (( $# >= 2 )) \
  || { echo "build.sh <cachyos|ubuntu> <outdir> [distro-config]" >&2; exit 2; }
distro=$1 out=$2
cfg=${3:-$cache/config-$distro}
base=$(sed -n 's/^base_tag=//p' "$root/kernel/SOURCE")
[[ -f "$cfg" ]] || { echo "no $cfg" >&2; exit 1; }
(cd "$root/kernel/series" && sha256sum --quiet -c ../series.sha256) \
  || { echo "kernel/series does not match kernel/series.sha256" >&2; exit 1; }
rel=$(pkgrel)
mkdir -p "$out"; out=$(cd "$out" && pwd)
[[ -z "$(ls -A "$out")" ]] || { echo "$out is not empty" >&2; exit 1; }
git -C "$cache/linux" worktree add -f --detach "$out/tree" "$base"
git -C "$out/tree" -c user.name=rhizo-kernel -c user.email=kernel@localhost am -q "$root"/kernel/series/*.patch
for p in "$root"/kernel/patches/*.patch; do
  git -C "$out/tree" apply "$p" || { echo "git apply ${p##*/} failed" >&2; exit 1; }
done
git -C "$out/tree" add -A
git -C "$out/tree" -c user.name=rhizo-kernel -c user.email=kernel@localhost commit -q -m "rhizo kernel patches"
"$root/kernel/configure.sh" "$out/tree" "$cfg" "$distro"
case $distro in
  cachyos)
    pin_pacman_pkgrel "$out/tree"
    RHIZO_PKGREL=$rel PACMAN_PKGBASE=linux-rhizo nice -n 19 make -C "$out/tree" -j"$(nproc)" LOCALVERSION= pacman-pkg \
      > "$out/build.log" 2>&1
    ver=$(sed 's/-/_/g' "$out/tree/include/config/kernel.release")
    [[ -e "$out/tree/linux-rhizo-$ver-$rel-x86_64.pkg.tar.zst" ]] \
      || { echo "no $out/tree/linux-rhizo-$ver-$rel-x86_64.pkg.tar.zst" >&2; exit 1; }
    mv "$out/tree"/linux-rhizo-*.pkg.tar.zst "$out/" ;;
  ubuntu)
    nice -n 19 make -C "$out/tree" -j"$(nproc)" LOCALVERSION= > "$out/build.log" 2>&1
    kr=$(< "$out/tree/include/config/kernel.release")
    nice -n 19 make -C "$out/tree" -j"$(nproc)" LOCALVERSION= KDEB_PKGVERSION="$kr-$rel" bindeb-pkg >> "$out/build.log" 2>&1
    got=$(dpkg-deb -f "$out/linux-image-${kr}_$kr-${rel}_amd64.deb" Version) \
      || { echo "no $out/linux-image-${kr}_$kr-${rel}_amd64.deb" >&2; exit 1; }
    [[ "$got" == "$kr-$rel" ]] || { echo "linux-image-$kr Version is $got, expected $kr-$rel" >&2; exit 1; }
    "$here/deb-meta.sh" "$out" ;;
esac
cat "$out/tree/include/config/kernel.release"
find "$out" -maxdepth 1 \( -name '*.pkg.tar.zst' -o -name '*.deb' \) -printf '%p %s\n'
