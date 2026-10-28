#!/bin/bash
# build rhizo_wlan.ko and the patched cfg80211.ko out of tree
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cache=${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}
base=$(sed -n 's/^base_tag=//p' "$root/kernel/SOURCE")

declare -A paths=(
  [0026-cfg80211-wiphy-no-rfkill]="include/net/cfg80211.h net/wireless/core.c"
  [0027-nl80211-regulatory-init-net]="net/wireless/nl80211.c"
  [0028-cfg80211-self-managed-idle]="net/wireless/sme.c"
  [0029-rhizo-wlan]="drivers/net/wireless/Kconfig drivers/net/wireless/Makefile drivers/net/wireless/rhizo
    include/uapi/linux/rhizo_wlan.h"
)
order=(0026-cfg80211-wiphy-no-rfkill 0027-nl80211-regulatory-init-net 0028-cfg80211-self-managed-idle
  0029-rhizo-wlan)

die() { echo "wlan-oot.sh: $*" >&2; exit 1; }

# lay out the patched base tree in <dir>/src
make_tree() {
  local src=$1/src p
  [[ ! -e "$src" ]] || die "$src exists -- move it away first"
  git -C "$cache/linux" cat-file -e "$base:net/wireless/core.c" 2>/dev/null \
    || die "no $base tree in $cache/linux (run make kernel-inputs)"
  mkdir -p "$src"
  # shellcheck disable=SC2086
  git -C "$cache/linux" archive "$base" net/wireless include/net/cfg80211.h \
    drivers/net/wireless/Kconfig drivers/net/wireless/Makefile | tar -x -C "$src"
  git -C "$src" init -q
  git -C "$src" add -A
  git -C "$src" -c user.name=rhizo-kernel -c user.email=kernel@localhost commit -q -m "$base"
  for p in "${order[@]}"; do
    git -C "$src" apply "$root/kernel/patches/$p.patch" || die "$p.patch does not apply to $base"
  done
  echo "$src"
}

# build <dir>/src's modules in the build container
build() {
  local dir=$1 hdr=$2 out=$1/build image
  [[ -f "$hdr/Module.symvers" && -f "$hdr/include/config/auto.conf" ]] || die "$hdr is not a kernel headers tree"
  [[ -d "$dir/src/net/wireless" ]] || die "no $dir/src -- run: wlan-oot.sh tree $dir"
  mkdir -p "$out/cfg80211" "$out/rhizo" "$out/include/net" "$out/include/uapi/linux"
  cp -r "$dir"/src/net/wireless/*.[ch] "$dir/src/net/wireless/certs" "$out/cfg80211/"
  cp "$dir"/src/drivers/net/wireless/rhizo/*.c "$out/rhizo/"
  cp "$dir/src/include/net/cfg80211.h" "$out/include/net/"
  cp "$dir/src/include/uapi/linux/rhizo_wlan.h" "$out/include/uapi/linux/"
  echo 'obj-m += cfg80211/ rhizo/' > "$out/Kbuild"
  sed -n '/^cfg80211-/p; /^CFLAGS_/p; /^\$(obj)\/shipped-certs.c:/,/^$/p' "$dir/src/net/wireless/Makefile" \
    | sed '/extra-certs/d' > "$out/cfg80211/Kbuild"
  # kbuild puts NOSTDINC_FLAGS ahead of the tree's include paths
  printf '%s\n' 'obj-m := cfg80211.o' 'NOSTDINC_FLAGS += -I$(M)/include' >> "$out/cfg80211/Kbuild"
  printf '%s\n' 'obj-m := rhizo_wlan.o' 'NOSTDINC_FLAGS += -I$(M)/include' > "$out/rhizo/Kbuild"
  image=$("$root/tools/build/env/run.sh" --image)
  podman run --rm -v "$hdr:/usr/src/${hdr##*/}:ro,z" -v "$out:/m:z" "$image" \
    make -C "/usr/src/${hdr##*/}" M=/m modules
  ls -l "$out"/cfg80211/cfg80211.ko "$out"/rhizo/rhizo_wlan.ko
}

# write each patch from the working tree of <dir>/src
export_patches() {
  local src=$1/src p
  git -C "$src" add -A
  for p in "${order[@]}"; do
    # shellcheck disable=SC2086
    git -C "$src" diff --cached --abbrev=11 -- ${paths[$p]} > "$root/kernel/patches/$p.patch"
    echo "kernel/patches/$p.patch"
  done
}

case "${1:-}" in
  tree) (( $# == 2 )) || die "usage: wlan-oot.sh tree <dir>"; make_tree "$2" ;;
  build) (( $# == 3 )) || die "usage: wlan-oot.sh build <dir> <headers>"; build "$2" "$(cd "$3" && pwd)" ;;
  export) (( $# == 2 )) || die "usage: wlan-oot.sh export <dir>"; export_patches "$2" ;;
  *) die "usage: wlan-oot.sh tree <dir> | build <dir> <headers> | export <dir>" ;;
esac
