#!/bin/bash
# build the Rhizo kernel packages
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cache=${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}
# print the package revision kept in kernel/VERSION
pkgrel() {
  local v
  v=$(< "$root/kernel/VERSION") || return 1
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "build.sh: $root/kernel/VERSION holds '$v', not a positive integer" >&2; return 1; }
  echo "$v"
}

# take a tree's pkgrel from RHIZO_PKGREL
pin_pacman_pkgrel() {
  local f="$1/scripts/package/PKGBUILD"
  # shellcheck disable=SC2016
  if ! grep -qx 'pkgrel="${KBUILD_REVISION}"' "$f"; then
    echo "build.sh: $f sets pkgrel another way than from KBUILD_REVISION" >&2
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
  || { echo "usage: build.sh <cachyos|ubuntu> <outdir> [distro-config]" >&2; exit 2; }
distro=$1 out=$2
cfg=${3:-$cache/config-$distro}
base=$(sed -n 's/^base_tag=//p' "$root/kernel/SOURCE")
[[ -f "$cfg" ]] || { echo "build.sh: no distro config at $cfg -- run make kernel-inputs first" >&2; exit 1; }
(cd "$root/kernel/series" && sha256sum --quiet -c ../series.sha256) \
  || { echo "build.sh: kernel/series does not match kernel/series.sha256 -- run make kernel-inputs first" >&2; exit 1; }
rel=$(pkgrel)
mkdir -p "$out"; out=$(cd "$out" && pwd)
[[ -z "$(ls -A "$out")" ]] || { echo "build.sh: $out is not empty -- move the earlier build out of it first" >&2; exit 1; }
git -C "$cache/linux" worktree add -f --detach "$out/tree" "$base"
git -C "$out/tree" -c user.name=rhizo-kernel -c user.email=kernel@localhost am -q "$root"/kernel/series/*.patch
for p in "$root"/kernel/patches/*.patch; do
  git -C "$out/tree" apply "$p" || { echo "build.sh: ${p##*/} does not apply" >&2; exit 1; }
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
      || { echo "build.sh: makepkg left no linux-rhizo-$ver-$rel-x86_64.pkg.tar.zst in $out/tree" >&2; exit 1; }
    mv "$out/tree"/linux-rhizo-*.pkg.tar.zst "$out/" ;;
  ubuntu)
    nice -n 19 make -C "$out/tree" -j"$(nproc)" LOCALVERSION= > "$out/build.log" 2>&1
    kr=$(< "$out/tree/include/config/kernel.release")
    nice -n 19 make -C "$out/tree" -j"$(nproc)" LOCALVERSION= KDEB_PKGVERSION="$kr-$rel" bindeb-pkg >> "$out/build.log" 2>&1
    got=$(dpkg-deb -f "$out/linux-image-${kr}_$kr-${rel}_amd64.deb" Version) \
      || { echo "build.sh: bindeb-pkg left no linux-image-${kr}_$kr-${rel}_amd64.deb in $out" >&2; exit 1; }
    [[ "$got" == "$kr-$rel" ]] || { echo "build.sh: linux-image-$kr is version $got, not $kr-$rel" >&2; exit 1; }
    "$here/deb-meta.sh" "$out" ;;
esac
cat "$out/tree/include/config/kernel.release"
find "$out" -maxdepth 1 \( -name '*.pkg.tar.zst' -o -name '*.deb' \) -printf '%p %s\n'
