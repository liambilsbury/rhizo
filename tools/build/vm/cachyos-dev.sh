#!/bin/bash
# build cachyos-dev.qcow2 and its kernel pair
set -euo pipefail
tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$tools/../../.."
[[ $# -eq 0 ]] || { echo "usage: cachyos-dev.sh" >&2; exit 2; }
# shellcheck source=../../../test/vm/guest-os/cachyos-guest-lib.sh
source "$tools/../../../test/vm/guest-os/cachyos-guest-lib.sh"

DEV_PKGS=(base-devel android-tools conntrack-tools dash iptables
          sway foot grim wtype wl-clipboard qt6-tools plasma-wayland-protocols)
KERNEL_PAIR=(vmlinuz-linux-cachyos initramfs-linux-cachyos.img)
dl=var/cachyos-dl
stock="$dl/cachyos-stock"
dev="$dl/cachyos-dev"
cachyos_build_lock
refuse_vm_overlays "$dev.qcow2"
scratch=$(mktemp -d)

# stop the guest and delete scratch files
cleanup() {
  local rc=$? f
  stop_guest
  if (( rc != 0 )); then
    rm -f "$dev".*.new
    for f in "${KERNEL_PAIR[@]}"; do rm -f "var/share/$f.new"; done
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

(cd "$dl" && sha256sum -c cachyos-stock.sha256)
stock_sha=$(sed -n 's/  cachyos-stock\.qcow2$//p' "$stock.sha256")
[[ "$stock_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "$stock.sha256 has no cachyos-stock.qcow2 line" >&2; exit 1; }
boot_overlay "$stock.qcow2" "$stock.OVMF_VARS.fd" "$scratch" "$dl/devboot.log"
expect 9p findmnt -no FSTYPE /root/share

guest_step 3600 pacman -Syu --noconfirm
guest_step 1800 pacman -S --noconfirm --needed "${DEV_PKGS[@]}"
expect "$(printf '%s\n' "${DEV_PKGS[@]}")" pacman -Qq "${DEV_PKGS[@]}"
uuid=$(guest_step 30 findmnt -no UUID /)
[[ "$uuid" =~ ^[0-9a-f-]{36}$ ]] || { echo "root filesystem uuid reads '$uuid'" >&2; exit 1; }
guest_step 120 "cp /boot/${KERNEL_PAIR[0]} /boot/${KERNEL_PAIR[1]} /root/share/ && pacman -Q > /root/share/cachyos-dev.manifest"
record_facts "$scratch/guest.facts" \
  "pacman -Q ${DEV_PKGS[*]}" \
  "grep -E '^(MODULES|HOOKS)=' /etc/mkinitcpio.conf" \
  'df -h /'
guest_poweroff
release=$(kernel_release "$scratch/share/${KERNEL_PAIR[0]}")
qemu-img convert -O qcow2 "$scratch/overlay.qcow2" "$dev.qcow2.new"

boot_overlay "$dev.qcow2.new" "$stock.OVMF_VARS.fd" "$scratch/direct" "$dl/devdirect.log" \
  -kernel "$scratch/share/${KERNEL_PAIR[0]}" -initrd "$scratch/share/${KERNEL_PAIR[1]}" \
  -append "root=UUID=$uuid rootflags=subvol=/@ rw console=ttyS0"
expect "$release" uname -r
expect "$uuid" findmnt -no UUID /
guest_poweroff

diff_rc=0
diff "$stock.manifest" "$scratch/share/cachyos-dev.manifest" > "$scratch/manifest.diff" || diff_rc=$?
(( diff_rc <= 1 )) || { echo "diff of the stock and dev manifests exited $diff_rc" >&2; exit 1; }
{
  echo "built $(date -u +%Y-%m-%dT%H:%M:%SZ) from cachyos-stock.qcow2 sha256 $stock_sha"
  echo "root uuid $uuid"
  echo "kernel release $release, booted directly from var/share/${KERNEL_PAIR[0]}"
  echo
  cat "$scratch/guest.facts"
  echo "$ diff cachyos-stock.manifest cachyos-dev.manifest"
  cat "$scratch/manifest.diff"
} > "$dev.facts.new"
echo "$uuid" > "$dev.root-uuid.new"
cp "$scratch/share/cachyos-dev.manifest" "$dev.manifest.new"
for f in "${KERNEL_PAIR[@]}"; do install -m 0644 "$scratch/share/$f" "var/share/$f.new"; done
for f in qcow2 manifest facts root-uuid; do mv "$dev.$f.new" "$dev.$f"; done
for f in "${KERNEL_PAIR[@]}"; do mv "var/share/$f.new" "var/share/$f"; done
(cd "$dl" && sha256sum cachyos-dev.qcow2 > cachyos-dev.sha256)
cat "$dev.sha256"
echo "$(wc -l < "$dev.manifest") packages, root uuid $uuid, kernel $release, $(grep -c '^[<>]' "$scratch/manifest.diff") manifest lines changed from stock"
ls -l "$dev".* "${KERNEL_PAIR[@]/#/var/share/}"
