#!/bin/bash
# test the cachyos installer's rig-path scan of the pacman packages
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2034
VAR_DIR="$tmp/var"
# shellcheck source=../../../system/lib/installer-cachyos-lib.sh
source "$HERE/system/lib/installer-cachyos-lib.sh" || { echo "FAIL could not source installer-cachyos-lib.sh"; exit 1; }
fail=0

# write a pacman package holding the given files
make_pkg() {
  local out="$1" d spec; shift
  d=$(mktemp -d "$tmp/pkg.XXXXXX")
  for spec in "$@"; do
    mkdir -p "$d/$(dirname "${spec%%=*}")"
    printf '%s\n' "${spec#*=}" > "$d/${spec%%=*}"
  done
  (cd "$d" && tar --zstd -cf "$out" .)
}

make_pkg "$tmp/clean.pkg.tar.zst" ".BUILDINFO=installed = llvm-libs-23.1.1-3-x86_64_v4" \
  ".PKGINFO=depend = libxxf86vm" "usr/lib/rhizo/VERSION=0.1.3"
make_pkg "$tmp/key.pkg.tar.zst" "usr/lib/rhizo/env=KEY=/home/someone/rhizo/var/vm_key"
make_pkg "$tmp/script.pkg.tar.zst" "usr/lib/rhizo/tools/run-vm.sh=#!/bin/sh"
make_pkg "$tmp/share.pkg.tar.zst" "usr/lib/rhizo/fstab=share /root/share 9p trans=virtio,version=9p2000.L 0 0"

out=$(installer_cachyos_rig_hits "$tmp/clean.pkg.tar.zst")
[[ -z "$out" ]] || { echo "FAIL a package whose build record names llvm-libs and libxxf86vm was read as carrying the rig path:$out"; fail=1; }
out=$(installer_cachyos_rig_hits "$tmp/key.pkg.tar.zst")
[[ "$out" == *"key.pkg.tar.zst:var/vm"* ]] || { echo "FAIL a package naming the rig's var/vm_key was not refused: '$out'"; fail=1; }
out=$(installer_cachyos_rig_hits "$tmp/script.pkg.tar.zst")
[[ "$out" == *"script.pkg.tar.zst:run-vm.sh"* ]] || { echo "FAIL a package shipping run-vm.sh was not refused: '$out'"; fail=1; }
out=$(installer_cachyos_rig_hits "$tmp/share.pkg.tar.zst" "$tmp/clean.pkg.tar.zst")
[[ "$out" == *"share.pkg.tar.zst:trans=virtio"* && "$out" != *clean.pkg* ]] \
  || { echo "FAIL the 9p share mount was not refused by name, or the clean package beside it was named: '$out'"; fail=1; }

FAILS=""
# record a failure message
fail() { FAILS+="$*"$'\n'; return 0; }
# ignore a pass
pass() { :; }
# write a package of .PKGINFO lines
make_info_pkg() {
  local out="$1" d
  shift
  d=$(mktemp -d "$tmp/info.XXXXXX")
  printf '%s\n' "$@" > "$d/.PKGINFO"
  tar --zstd -C "$d" -cf "$out" .PKGINFO
}
SHARE_DIR="$tmp/share"
CACHYOS_KERNEL_PKG_DIR="$tmp/kernel"
mkdir -p "$SHARE_DIR/arch-pool" "$CACHYOS_KERNEL_PKG_DIR"
make_info_pkg "$tmp/rhizo-0.1.3-1-any.pkg.tar.zst" "pkgname = rhizo" "depend = linux-rhizo" "depend = linux-rhizo-headers"
make_info_pkg "$tmp/rhizo-nokernel-1-1-any.pkg.tar.zst" "pkgname = rhizo" "depend = python"
make_info_pkg "$CACHYOS_KERNEL_PKG_DIR/linux-rhizo-7.1.0rc1_rhizo-3-any.pkg.tar.zst" "pkgname = linux-rhizo" "depend = kmod"
make_info_pkg "$CACHYOS_KERNEL_PKG_DIR/linux-rhizo-headers-7.1.0rc1_rhizo-3-any.pkg.tar.zst" "pkgname = linux-rhizo-headers"
printf 'kmod\n' > "$SHARE_DIR/arch-pool/POOL.kernel-depends"
installer_cachyos_kernel_pkgs leg "$tmp/rhizo-0.1.3-1-any.pkg.tar.zst"; rc=$?
[[ "$rc" == 0 && -z "$FAILS" && "${CACHYOS_KERNEL_PKGS[*]##*/}" == "linux-rhizo-7.1.0rc1_rhizo-3-any.pkg.tar.zst linux-rhizo-headers-7.1.0rc1_rhizo-3-any.pkg.tar.zst" ]] \
  || { echo "FAIL rhizo's two Rhizo kernel packages with their depend in the pool resolved rc=$rc to '${CACHYOS_KERNEL_PKGS[*]}': $FAILS"; fail=1; }
FAILS=""
installer_cachyos_kernel_pkgs leg "$tmp/rhizo-nokernel-1-1-any.pkg.tar.zst"; rc=$?
[[ "$rc" == 0 && -z "$FAILS" && ${#CACHYOS_KERNEL_PKGS[@]} == 0 ]] \
  || { echo "FAIL a rhizo package depending on no Rhizo kernel resolved rc=$rc to '${CACHYOS_KERNEL_PKGS[*]}': $FAILS"; fail=1; }
FAILS=""
: > "$SHARE_DIR/arch-pool/POOL.kernel-depends"
installer_cachyos_kernel_pkgs leg "$tmp/rhizo-0.1.3-1-any.pkg.tar.zst"; rc=$?
[[ "$rc" == 1 && "$FAILS" == *"does not carry what the Rhizo kernel packages depend on"*"depends on kmod"* ]] \
  || { echo "FAIL a pool whose record lacks the kernel's kmod was not refused by name: rc=$rc $FAILS"; fail=1; }
FAILS=""
printf 'kmod\n' > "$SHARE_DIR/arch-pool/POOL.kernel-depends"
mv "$CACHYOS_KERNEL_PKG_DIR/linux-rhizo-headers-7.1.0rc1_rhizo-3-any.pkg.tar.zst" "$tmp/"
installer_cachyos_kernel_pkgs leg "$tmp/rhizo-0.1.3-1-any.pkg.tar.zst" 2>/dev/null; rc=$?
[[ "$rc" == 1 && "$FAILS" == *"does not hold one package file of each"* ]] \
  || { echo "FAIL a kernel dir with no linux-rhizo-headers was not refused by name: rc=$rc $FAILS"; fail=1; }

mkdir -p "$tmp/bin"
printf '#!/bin/sh\nif [ "$1" = -Qq ]; then printf "%%b" "$STUB_INSTALLED"; exit 0; fi\necho "pacman $*" >> "%s/pacman-calls"\nexit "$STUB_RC"\n' "$tmp" > "$tmp/bin/pacman"
chmod +x "$tmp/bin/pacman"
# shellcheck disable=SC2034
EV="$tmp"
# run the removal's guest script
ssh_vm() { env PATH="$tmp/bin:$PATH" STUB_INSTALLED="$STUB_INSTALLED" STUB_RC="$STUB_RC" bash -c "${*: -1}"; }
# print the removal's status and pacman calls
remove_case() {
  STUB_INSTALLED="$1" STUB_RC="$2" FAILS=""
  : > "$tmp/pacman-calls"
  installer_cachyos_remove_rhizo_kernel leg "$tmp/remove.log"
  echo "rc=$? calls=$(tr '\n' '|' < "$tmp/pacman-calls")"
}
CACHYOS_KERNEL_PKGS=(x)
out=$(remove_case 'linux-rhizo\nlinux-rhizo-headers\n' 0)
[[ "$out" == "rc=0 calls=pacman -R --noconfirm linux-rhizo linux-rhizo-headers|" ]] \
  || { echo "FAIL the installed Rhizo kernel was not removed with one pacman -R: $out"; fail=1; }
out=$(remove_case 'linux-rhizo\n' 1; echo "$FAILS")
[[ "$out" == "rc=1 calls=pacman -R --noconfirm linux-rhizo|"*"exited 1"* ]] \
  || { echo "FAIL a failed pacman -R was not failed by name: $out"; fail=1; }
out=$(remove_case '' 0; echo "$FAILS")
[[ "$out" == "rc=1 calls="*"no Rhizo kernel package was installed to remove"* ]] \
  || { echo "FAIL a missing Rhizo kernel rhizo depends on was not failed by name: $out"; fail=1; }
CACHYOS_KERNEL_PKGS=()
out=$(remove_case '' 0)
[[ "$out" == "rc=0 calls=" ]] || { echo "FAIL no Rhizo kernel with none depended on was not passed: $out"; fail=1; }

(( fail == 0 )) && echo "installer-cachyos-rig-path: ok"
exit "$fail"
