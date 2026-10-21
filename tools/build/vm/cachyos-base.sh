#!/bin/bash
# build a cachyos base image in var/cachyos-dl
set -euo pipefail
tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$tools/../../.."

# print the usage line and exit 2
usage() {
  echo "usage: cachyos-base.sh [--bootloader <limine|systemd-boot|grub> --name <base>] [--check-only [--name <base>]]" >&2
  exit 2
}
mode=build name="" bootloader=""
while (( $# )); do
  case "$1" in
    --check-only) mode=check; shift ;;
    --bootloader|--name)
      (( $# >= 2 )) && [[ -n "$2" ]] || usage
      if [[ "$1" == --name ]]; then name="$2"; else bootloader="$2"; fi
      shift 2 ;;
    *) usage ;;
  esac
done
if [[ "$mode" == build && -n "$name$bootloader" && ( -z "$name" || -z "$bootloader" ) ]]; then usage; fi
[[ -n "$name" || -z "$bootloader" ]] || usage
# shellcheck source=../../../test/vm/guest-os/guest-os-lib.sh
source "$tools/../../../test/vm/guest-os/guest-os-lib.sh"
name=${name:-cachyos-stock}
want=$(cachyos_base_bootloader "$name" --name) || exit 2
bootloader=${bootloader:-$want}
[[ "$bootloader" == "$want" ]] || { echo "--name $name is the $want base, not one for --bootloader $bootloader" >&2; exit 2; }
# shellcheck source=../../../test/vm/guest-os/cachyos-guest-lib.sh
source "$tools/../../../test/vm/guest-os/cachyos-guest-lib.sh"

INSTALL_BUDGET=3600
V3_MSG="cachyos' repo choice for this cpu is not x86-64-v3"
case "$bootloader" in
  limine)
    bl_pkg=limine
    bl_facts=('cat /etc/default/limine') ;;
  systemd-boot)
    bl_pkg=systemd-boot-manager
    bl_facts=('cat /etc/sdboot-manage.conf' 'pacman -Q systemd-boot-manager' 'cat /boot/loader/loader.conf'
              'grep -H . /boot/loader/entries/*.conf' "stat -c '%a %U:%G %n' /boot /boot/loader /boot/loader/entries") ;;
  grub)
    bl_pkg=grub
    bl_facts=('cat /etc/default/grub' 'pacman -Q grub grub-btrfs'
              "grep -nE '^### (BEGIN|END) |^[[:space:]]*(menuentry|submenu|linux) ' /boot/grub/grub.cfg"
              "stat -c '%a %U:%G %n' /boot /boot/grub /boot/grub/grub.cfg") ;;
esac
BASE_PKGS=(plasma-desktop plasma-workspace kwin plasma-login-manager linux-cachyos linux-cachyos-headers "$bl_pkg" snapper)
dl=var/cachyos-dl
base="$dl/$name"
logs="$dl/$name."
[[ "$name" != cachyos-stock ]] || logs="$dl/"
install_log="${logs}install.log"
if [[ "$mode" == build ]]; then
  cachyos_build_lock
  refuse_vm_overlays "$base.qcow2"
fi
scratch=$(mktemp -d)

# stop the guest and delete scratch files
cleanup() {
  local rc=$?
  stop_guest
  if (( rc != 0 )) && [[ "$mode" == build ]]; then rm -f "$base".*.new; fi
  rm -rf "$scratch"
}
trap cleanup EXIT

if [[ "$mode" == build ]]; then
  isa=$(/lib64/ld-linux-x86-64.so.2 --help)
  if [[ "$isa" != *"x86-64-v3 (supported"* ]]; then
    echo "$V3_MSG: $(grep -o 'x86-64-v[234] ([a-z, ]*)' <<<"$isa" | tr '\n' ' ')" >&2
    exit 1
  fi

  export RIG_GUEST_CPU=host,family=23,model=49,stepping=0,-avx512f,-avx512dq,-avx512cd,-avx512bw,-avx512vl
  iso=$("$tools/../../fetch/images/cachyos-iso.sh")
  echo "iso $iso, guests -smp $RIG_VCPUS -m ${RIG_MEM_G}G"
  echo "base $name, bootloader $bootloader"
  qemu-img create -q -f qcow2 "$base.qcow2.new" 40G
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$base.OVMF_VARS.fd.new"
  sed -e 's|@DISK@|/dev/vda|g' -e "s|@BOOTLOADER@|$bootloader|g" "$tools/../../../test/vm/guest-os/config/cachyos-settings.json.in" > "$scratch/settings.json"

  : > "$install_log"

  require_socket_path "$scratch/qga.sock" || exit 1
  start_guest \
    -drive if=pflash,format=raw,file="$base.OVMF_VARS.fd.new" \
    -drive file="$base.qcow2.new",if=virtio,format=qcow2 \
    -cdrom "$iso" \
    -device virtio-serial \
    -chardev socket,path="$scratch/qga.sock",server=on,wait=off,id=qga0 \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -chardev file,id=con,path="$install_log",mux=on -serial chardev:con \
    -device virtserialport,chardev=con,name=org.rhizo.install \
    -nic user,model=virtio
  # shellcheck disable=SC2154
  echo "live iso booting, qemu pid $qemu_pid, console $install_log"

  python3 "$tools/../../../test/vm/guest-os/qga.py" --sock "$scratch/qga.sock" --qemu-pid "$qemu_pid" --timeout "$INSTALL_BUDGET" \
    --put "$scratch/settings.json" /run/rhizo-install/settings.json \
    --put "$tools/../../../test/vm/guest-os/cachyos-post-install.sh" /run/rhizo-install/cachyos-post-install.sh \
    --put var/vm_key.pub /run/rhizo-install/vm_key.pub \
    --put "$tools/cachyos-live-install.sh" /run/rhizo-install/install.sh \
    --start /bin/bash /run/rhizo-install/install.sh \
    || fail_log "the guest agent channel failed" "$install_log"

  qemu_rc=0
  wait_qemu_exit "$INSTALL_BUDGET" || qemu_rc=$?
  # shellcheck disable=SC2154
  echo "$qemu_exit"
  live_fail=$(sed -n 's/^.*RHIZO_LIVE_FAIL=//p' "$install_log" | tail -n 1)
  [[ -z "$live_fail" ]] || fail_log "the live system stopped: $live_fail" "$install_log"
  install_rc=$(sed -n 's/^.*RHIZO_INSTALL_RC=\([0-9]*\).*$/\1/p' "$install_log" | tail -n 1)
  post_rc=$(sed -n 's/^.*RHIZO_POST_INSTALL_RC=\([0-9]*\).*$/\1/p' "$install_log" | tail -n 1)
  echo "installer rc '$install_rc', post-install rc '$post_rc'"
  if [[ "$qemu_rc" != 0 || "$install_rc" != 0 || "$post_rc" != 0 ]]; then
    fail_log "the install did not finish clean" "$install_log"
  fi
  known=(
    'Could not find parent disk for /dev/vda2$|its removable check walks a device list that holds no disks, so it logs this on every install and treats the disk as fixed'
    'Failed to enable ufw firewall: .*ufw allow "KDE Connect"$|kdeconnect names its ufw profile KDEConnect, so this last rule fails on every install, after ufw is enabled with deny incoming'
  )
  unknown=0
  while IFS= read -r line; do
    why=""
    for k in "${known[@]}"; do
      if [[ "$line" =~ ${k%%|*} ]]; then why="${k#*|}"; break; fi
    done
    if [[ -n "$why" ]]; then
      echo "$line -- known: $why"
    else
      echo "$line -- not in the known list" >&2
      unknown=1
    fi
  done < <(grep -a -E '\]\[---[WEC]---\] |install (warning|error):' "$install_log")
  (( unknown == 0 )) || fail_log "the installer logged warnings or errors this build does not know" "$install_log"
  grep -a -q "'cachyos-v3' is already added" "$install_log" || fail_log "$V3_MSG" "$install_log"

  disk="$base.qcow2.new" vars="$base.OVMF_VARS.fd.new" out="$base" new=.new boot_log="${logs}firstboot.log"
else
  (cd "$dl" && sha256sum -c "$name.sha256")
  disk="$base.qcow2" vars="$base.OVMF_VARS.fd" out="$scratch/check" new="" boot_log="$scratch/firstboot.log"
fi

boot_overlay "$disk" "$vars" "$scratch" "$boot_log"
expect "$(printf '%s\n' "${BASE_PKGS[@]}")" pacman -Qq "${BASE_PKGS[@]}"
expect active systemctl is-active plasmalogin.service
expect enabled systemctl is-enabled sshd.service
expect btrfs findmnt -no FSTYPE /
echo "base checks passed: ${BASE_PKGS[*]} installed, plasmalogin active, sshd enabled, / on btrfs"

guest_step 120 pacman -Q > "$out.manifest$new"
uuid=$(guest_step 30 findmnt -no UUID /)
[[ "$uuid" =~ ^[0-9a-f-]{36}$ ]] || { echo "root filesystem uuid reads '$uuid'" >&2; exit 1; }
echo "$uuid" > "$out.root-uuid$new"
echo "$(wc -l < "$out.manifest$new") packages, root uuid $uuid"

facts=(
  'cat /etc/os-release'
  'uname -r'
  'cat /proc/cmdline'
  "${bl_facts[@]}"
  'findmnt -no FSTYPE,OPTIONS /'
  'systemctl is-active plasmalogin.service'
  'cat /sys/kernel/security/lsm'
  'grep -n DownloadUser /etc/pacman.conf'
  "grep -n '^\[' /etc/pacman.conf"
  'swapon --noheadings'
  'cat /sys/module/binder/parameters/devices'
  'getent passwd deskuser'
  'systemctl is-active ufw plasmalogin sshd'
  "systemctl list-unit-files 'plasmalogin*' 'sddm*' --no-legend"
  'pacman -Qq iptables iptables-nft 2>&1'
  'ls /boot'
  'findmnt -no SOURCE,FSTYPE,OPTIONS /boot'
  'btrfs subvolume list /'
  'cat /etc/plasmalogin.conf'
  'findmnt -no SOURCE,FSTYPE,OPTIONS /root/share'
  'ufw status verbose'
)
record_facts "$out.facts$new" "${facts[@]}"
guest_poweroff

if [[ "$mode" == build ]]; then
  for f in qcow2 OVMF_VARS.fd manifest root-uuid facts; do
    mv "$base.$f.new" "$base.$f"
  done
  (cd "$dl" && sha256sum "$name.qcow2" "$name.OVMF_VARS.fd" > "$name.sha256")
  cat "$base.sha256"
  ls -l "$base".*
else
  [[ "$uuid" == "$(cat "$base.root-uuid")" ]] || { echo "root uuid $uuid, $base.root-uuid says $(cat "$base.root-uuid")" >&2; exit 1; }
  if ! diff "$base.facts" "$out.facts"; then echo "the facts above differ from $base.facts"; fi
  echo "$base checks out; nothing under $dl was changed"
fi
