#!/bin/bash
# test the offline pool config and pool check
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "${1:-}" == --selftest ]] || { echo "usage: $0 --selftest" >&2; exit 2; }
# shellcheck source=../../tools/fetch/pools/arch/arch-pool-lib.sh
source "$HERE/../../tools/fetch/pools/arch/arch-pool-lib.sh"
FAILED=0 CASES=0
# check $2 against $3
check() {
  CASES=$((CASES + 1))
  [[ "$2" == "$3" ]] && return 0
  echo "got '$2' want '$3' for: $1"; FAILED=1
}
# check a string contains another
has() {
  CASES=$((CASES + 1))
  [[ "$3" == *"$2"* ]] && return 0
  echo "'$3' does not contain '$2' for: $1"; FAILED=1
}

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT

# print the problems in the pool conf
conf_problems() {
  awk '
    { sub(/^[ \t]+/, ""); gsub(/[ \t]+/, " ") }
    /^\[/ { section = $0; if ($0 != "[options]") { repos++; if ($0 != "[rhizo-pool]") print "section " $0 } next }
    /^Include/ { print "Include line: " $0 }
    /^Server/ { servers++; if ($0 != "Server = file:///root/share/arch-pool") print "server: " $0 }
    /^SigLevel/ {
      if ($0 != "SigLevel = Required DatabaseOptional") print "loose SigLevel: " $0
      if (section == "[rhizo-pool]") repo_sig++
    }
    /^LocalFileSigLevel/ { if ($0 != "LocalFileSigLevel = Optional") print "loose LocalFileSigLevel: " $0 }
    /^DownloadUser = alpm$/ { if (section == "[options]") download_user++ }
    END {
      if (repos != 1) print "repositories: " repos + 0
      if (servers != 1) print "servers: " servers + 0
      if (repo_sig != 1) print "no explicit SigLevel on the pool repository"
      if (download_user != 1) print "no DownloadUser = alpm in [options]"
    }' "$1"
}

arch_pool_conf "$SCRATCH/pacman.conf"
check "the pool conf has one repository, no Include, an explicit SigLevel on it and the DownloadUser line" "$(conf_problems "$SCRATCH/pacman.conf")" ""
check "the pool conf has the stock's options and the pool repository, line for line" "$(cat "$SCRATCH/pacman.conf")" "$(printf '[options]\n%s\n\n[rhizo-pool]\nSigLevel = Required DatabaseOptional\nServer = file:///root/share/arch-pool\n' "$(printf '%s\n' "${ARCH_POOL_OPTIONS[@]}")")"
# check conf_problems on a sed-edited conf copy
mutate() {
  sed "$3" "$SCRATCH/pacman.conf" > "$SCRATCH/mutated.conf"
  has "$1" "$2" "$(conf_problems "$SCRATCH/mutated.conf")"
}
mutate "an Include is flagged" "Include line" '$a Include = /etc/pacman.d/mirrorlist'
mutate "a second repository is flagged" "section [extra]" '$a [extra]'
mutate "a second repository is counted" "repositories: 2" '$a [extra]'
mutate "a Server outside the pool is flagged" "server: Server = https://example.org" '$a Server = https://example.org'
mutate "a missing repository SigLevel is flagged" "no explicit SigLevel on the pool repository" '/^\[rhizo-pool\]/,${/^SigLevel/d}'
mutate "SigLevel = Never on the repository is flagged" "loose SigLevel" '/^\[rhizo-pool\]/,${s/^SigLevel.*/SigLevel = Never/}'
mutate "TrustAll on the repository is flagged" "loose SigLevel" '/^\[rhizo-pool\]/,${s/^SigLevel.*/SigLevel = Optional TrustAll/}'
mutate "a missing DownloadUser is flagged" "no DownloadUser = alpm in [options]" '/^DownloadUser/d'

ROOTS="${ARCH_POOL_ROOTS[*]} "
check "the targets are the roots alone" "$(arch_pool_targets | tr '\n' ' ')" "$ROOTS"
check "no root is dkms" "$(grep -cw dkms <<<"$ROOTS")" 0
ARCH_POOL_KERNEL_DEPENDS=(kmod)
check "a Rhizo kernel depend: the roots and it" "$(arch_pool_targets | tr '\n' ' ')" "${ROOTS}kmod "
# shellcheck disable=SC2034
ARCH_POOL_KERNEL_DEPENDS=()

# write a package of .PKGINFO lines
pkg() {
  local out="$1" d
  shift
  d=$(mktemp -d "$SCRATCH/pkg.XXXXXX")
  printf '%s\n' "$@" > "$d/.PKGINFO"
  (cd "$d" && tar --zstd -cf "$out" .PKGINFO)
}
KDIR="$SCRATCH/kernel"
mkdir -p "$KDIR"
pkg "$SCRATCH/rhizo-0.1.3-1-any.pkg.tar.zst" "pkgname = rhizo" "depend = linux-rhizo" \
  "depend = linux-rhizo-headers" "depend = python>=3.12"
pkg "$SCRATCH/plain-1-1-any.pkg.tar.zst" "pkgname = plain" "depend = python"
pkg "$KDIR/linux-rhizo-7.1.0rc1_rhizo-3-any.pkg.tar.zst" "pkgname = linux-rhizo" "depend = kmod>=30" "depend = linux-rhizo-headers"
pkg "$KDIR/linux-rhizo-headers-7.1.0rc1_rhizo-3-any.pkg.tar.zst" "pkgname = linux-rhizo-headers" "depend = pahole"
pkg "$KDIR/linux-rhizo-api-headers-7.1.0rc1_rhizo-3-any.pkg.tar.zst" "pkgname = linux-rhizo-api-headers"
check "rhizo's depends name the two Rhizo kernel packages" "$(arch_pool_pkg_kernel_names "$SCRATCH/rhizo-0.1.3-1-any.pkg.tar.zst" | tr '\n' ' ')" "linux-rhizo linux-rhizo-headers "
check "a package depending on no Rhizo kernel names none" "$(arch_pool_pkg_kernel_names "$SCRATCH/plain-1-1-any.pkg.tar.zst")" ""
printf 'not a package\n' > "$SCRATCH/broken.pkg.tar.zst"
out=$(arch_pool_pkg_kernel_names "$SCRATCH/broken.pkg.tar.zst" 2>&1); rc=$?
check "an unreadable package: rc" "$rc" 2
has "an unreadable package: names it" "cannot read the .PKGINFO of $SCRATCH/broken.pkg.tar.zst" "$out"
check "the tree's PKGBUILD depends on the two Rhizo kernel packages" \
  "$(arch_pool_pkgbuild_kernel_names "$HERE/../../archlinux/rhizo/PKGBUILD.in" | tr '\n' ' ')" "linux-rhizo linux-rhizo-headers "
printf "pkgname=x\nsource=(x)\n" > "$SCRATCH/PKGBUILD"
out=$(arch_pool_pkgbuild_kernel_names "$SCRATCH/PKGBUILD" 2>&1); rc=$?
check "a PKGBUILD with no depends: rc" "$rc" 2
has "a PKGBUILD with no depends: says so" "has no depends=( array" "$out"
out=$(arch_pool_kernel_pkgs "$KDIR" linux-rhizo linux-rhizo-headers 2>&1); rc=$?
check "one file of each Rhizo kernel package: rc" "$rc" 0
check "one file of each Rhizo kernel package: the two, the api-headers package left out" "$(tr '\n' ' ' <<<"$out")" \
  "$KDIR/linux-rhizo-7.1.0rc1_rhizo-3-any.pkg.tar.zst $KDIR/linux-rhizo-headers-7.1.0rc1_rhizo-3-any.pkg.tar.zst "
pkg "$KDIR/linux-rhizo-7.1.0rc1_rhizo-4-any.pkg.tar.zst" "pkgname = linux-rhizo"
out=$(arch_pool_kernel_pkgs "$KDIR" linux-rhizo linux-rhizo-headers 2>&1); rc=$?
check "two builds of linux-rhizo: rc" "$rc" 2
has "two builds of linux-rhizo: names both" "holds 2 linux-rhizo package files (linux-rhizo-7.1.0rc1_rhizo-3-any.pkg.tar.zst linux-rhizo-7.1.0rc1_rhizo-4-any.pkg.tar.zst)" "$out"
rm "$KDIR/linux-rhizo-7.1.0rc1_rhizo-4-any.pkg.tar.zst"
out=$(arch_pool_kernel_pkgs "$SCRATCH/no-kernel" linux-rhizo 2>&1); rc=$?
check "no linux-rhizo file: rc" "$rc" 2
has "no linux-rhizo file: names the package" "holds 0 linux-rhizo package files" "$out"
KFILES=("$KDIR/linux-rhizo-7.1.0rc1_rhizo-3-any.pkg.tar.zst" "$KDIR/linux-rhizo-headers-7.1.0rc1_rhizo-3-any.pkg.tar.zst")
check "the Rhizo kernel's depends, each other's left out" "$(arch_pool_kernel_depends "${KFILES[@]}" | tr '\n' ' ')" "kmod pahole "
POOLDIR="$SCRATCH/kpool"
mkdir -p "$POOLDIR"
out=$(arch_pool_kernel_problems "$POOLDIR" "${KFILES[@]}"); rc=$?
check "a pool with no kernel record: rc" "$rc" 1
has "a pool with no kernel record: names the record" "has no POOL.kernel-depends" "$out"
printf 'kmod\n' > "$POOLDIR/POOL.kernel-depends"
out=$(arch_pool_kernel_problems "$POOLDIR" "${KFILES[@]}"); rc=$?
check "a record lacking pahole: rc" "$rc" 1
has "a record lacking pahole: names it" "depends on pahole, which" "$out"
printf 'kmod\npahole\n' > "$POOLDIR/POOL.kernel-depends"
out=$(arch_pool_kernel_problems "$POOLDIR" "${KFILES[@]}"); rc=$?
check "a record naming every depend: rc" "$rc" 0
check "a record naming every depend: says nothing" "$out" ""

(( FAILED )) && exit 1
echo "the pool lib passed $CASES cases"
