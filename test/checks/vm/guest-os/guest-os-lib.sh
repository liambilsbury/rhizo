#!/bin/bash
# test guest-os-lib.sh names for ubuntu and cachyos
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "${1:-}" == --selftest ]] || { echo "usage: $0 --selftest" >&2; exit 2; }
unset RHIZO_CACHYOS_BASE
source "$HERE/../vm/guest-os/guest-os-lib.sh"
FAILED=0 CASES=0
# compare the two values and record a mismatch
check() {
  CASES=$((CASES + 1))
  [[ "$2" == "$3" ]] && return 0
  echo "got '$2' want '$3' for: $1"; FAILED=1
}
check "ubuntu vm 0 disk"      "$(guest_disk ubuntu direct '')"   "vm.qcow2"
check "ubuntu vm 3 disk"      "$(guest_disk ubuntu direct -3)"   "vm-3.qcow2"
check "ubuntu pristine disk"    "$(guest_disk ubuntu grub -3)"     "vm-pristine-3.qcow2"
check "ubuntu pristine base"    "$(guest_base ubuntu grub)"        "pristine-dl/noble-server-cloudimg-amd64.img"
check "ubuntu seed"             "$(guest_seed_src ubuntu direct)"  "config/cloud-init.yaml"
check "ubuntu pristine seed"    "$(guest_seed_src ubuntu grub)"    "config/cloud-init-pristine.yaml"
check "ubuntu firmware"         "$(guest_firmware ubuntu)"         "bios"
check "ubuntu root"             "$(guest_root_arg ubuntu direct)"  "root=LABEL=cloudimg-rootfs ro"
check "cachyos vm disk"       "$(guest_disk cachyos direct -2)"  "vm-cachyos-2.qcow2"
check "cachyos pristine disk"   "$(guest_disk cachyos grub -2)"    "vm-cachyos-pristine-2.qcow2"
check "cachyos dev base"        "$(guest_base cachyos direct)"     "cachyos-dl/cachyos-dev.qcow2"
check "cachyos stock base"      "$(guest_base cachyos grub)"       "cachyos-dl/cachyos-stock.qcow2"
check "cachyos has no seed"     "$(guest_seed_src cachyos grub)"   ""
check "cachyos firmware"        "$(guest_firmware cachyos)"        "uefi"
check "cachyos lsm list"        "$(guest_lsm_arg cachyos)"         "lsm=landlock,lockdown,yama,integrity,selinux,bpf"
guest_os_valid fedora; check "fedora rejected" "$?" "1"

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
mkdir "$SCRATCH/cachyos-dl"
DEV_UUID=0123abcd-0000-4000-8000-00000000d001 STOCK_UUID=0123abcd-0000-4000-8000-00000000c001
# check the cachyos root argument
root_case() {
  local out rc
  out=$(cd "$SCRATCH" && guest_root_arg cachyos "$2" 2>"$SCRATCH/err"); rc=$?
  check "$1: rc" "$rc" "$3"
  check "$1: argument" "$out" "$4"
  [[ -z "$5" ]] || check "$1: names the file and its build" "$(grep -cE "$5" "$SCRATCH/err")" "1"
}
root_case "direct, no uuid file" direct 1 "" "no cachyos-dl/cachyos-dev.root-uuid -- run tools/build/vm/cachyos-dev.sh"
root_case "grub, no uuid file" grub 1 "" "no cachyos-dl/cachyos-stock.root-uuid -- run tools/build/vm/cachyos-base.sh"
echo "$STOCK_UUID" > "$SCRATCH/cachyos-dl/cachyos-stock.root-uuid"
root_case "grub, stock uuid only" grub 0 "root=UUID=$STOCK_UUID rootflags=subvol=/@ rw" ""
root_case "direct, stock uuid only" direct 1 "" "no cachyos-dl/cachyos-dev.root-uuid -- run tools/build/vm/cachyos-dev.sh"
: > "$SCRATCH/cachyos-dl/cachyos-dev.root-uuid"
root_case "direct, empty uuid file" direct 1 "" "cachyos-dl/cachyos-dev.root-uuid is empty -- run tools/build/vm/cachyos-dev.sh"
echo "$DEV_UUID" > "$SCRATCH/cachyos-dl/cachyos-dev.root-uuid"
root_case "direct, both uuid files" direct 0 "root=UUID=$DEV_UUID rootflags=subvol=/@ rw" ""
root_case "grub, both uuid files" grub 0 "root=UUID=$STOCK_UUID rootflags=subvol=/@ rw" ""
: > "$SCRATCH/cachyos-dl/cachyos-stock.root-uuid"
root_case "grub, empty uuid file" grub 1 "" "cachyos-dl/cachyos-stock.root-uuid is empty -- run tools/build/vm/cachyos-base.sh"
K="$SCRATCH/kernel" A=$(uname -m)
mkdir -p "$K/kernel" "$K/pkgs"
rhizo_kernel_revision "$K" 2>/dev/null; check "no kernel/VERSION: refused" "$?" "1"
echo forty > "$K/kernel/VERSION"
check "a kernel/VERSION that is not a number: refused by name" "$(rhizo_kernel_revision "$K" 2>&1)" "$K/kernel/VERSION holds 'forty', not a revision number"
echo 43 > "$K/kernel/VERSION"
check "kernel/VERSION's revision" "$(rhizo_kernel_revision "$K")" "43"
check "ubuntu kernel builder" "$(rhizo_kernel_builder ubuntu)" "make kernel-inputs kernel-deb"
check "cachyos kernel builder" "$(rhizo_kernel_builder cachyos)" "make kernel-inputs kernel-arch"
for f in linux-image-7.1.0-rc1-rhizo_7.1.0-rc1-rhizo-42_amd64.deb linux-image-rhizo_7.1.0-rc1-rhizo-42_amd64.deb \
         linux-image-7.1.0-rc1-rhizo-dbg_7.1.0-rc1-rhizo-43_amd64.deb linux-headers-7.1.0-rc1-rhizo_7.1.0-rc1-rhizo-43_amd64.deb \
         linux-image-7.1.0-rc1-rhizo_7.1.0-rc1-rhizo-43_amd64.deb \
         linux-rhizo-headers-7.1.0_rc1_rhizo-43-$A.pkg.tar.zst linux-rhizo-7.1.0_rc1_rhizo-42-$A.pkg.tar.zst; do
  : > "$K/pkgs/$f"
done
rhizo_kernel_packages ubuntu "$K/pkgs" 43 >/dev/null; check "ubuntu image without its meta package: none" "$?" "1"
rhizo_kernel_packages cachyos "$K/pkgs" 43 >/dev/null; check "cachyos headers only: none" "$?" "1"
: > "$K/pkgs/linux-image-rhizo_7.1.0-rc1-rhizo-43_amd64.deb"
: > "$K/pkgs/linux-rhizo-7.1.0_rc1_rhizo-43-$A.pkg.tar.zst"
check "ubuntu packages of revision 43: the image, then its meta package" "$(rhizo_kernel_packages ubuntu "$K/pkgs" 43 | tr '\n' ' ')" \
  "$K/pkgs/linux-image-7.1.0-rc1-rhizo_7.1.0-rc1-rhizo-43_amd64.deb $K/pkgs/linux-image-rhizo_7.1.0-rc1-rhizo-43_amd64.deb "
check "cachyos package of revision 43" "$(rhizo_kernel_packages cachyos "$K/pkgs" 43)" "$K/pkgs/linux-rhizo-7.1.0_rc1_rhizo-43-$A.pkg.tar.zst"
rhizo_kernel_packages ubuntu "$K/pkgs" 44 >/dev/null; check "no package of revision 44" "$?" "1"
check "ubuntu kernel release" "$(rhizo_kernel_release "$K/pkgs/linux-image-7.1.0-rc1-rhizo_7.1.0-rc1-rhizo-43_amd64.deb")" "7.1.0-rc1-rhizo"
check "cachyos kernel release" "$(rhizo_kernel_release "$K/pkgs/linux-rhizo-7.1.0_rc1_rhizo-43-$A.pkg.tar.zst")" "7.1.0-rc1-rhizo"
mkdir "$K/real"
ln -s "$K/real/vm-2.qcow2" "$K/vm-2.qcow2"
check "a linked disk's kernel dir sits beside its real file" "$(vm_kernel_dir "$K/vm-2.qcow2")" "$(realpath -m "$K/real")/vm-2.rhizo-kernel"
D="$K/real/vm-2.rhizo-kernel"
mkdir -p "$D"
vm_kernel_current "$D" 43; check "an empty kernel dir is not current" "$?" "1"
echo kernel > "$D/vmlinuz"; echo initrd > "$D/initrd.img"; echo 42 > "$D/revision"
vm_kernel_current "$D" 43; check "a kernel dir at revision 42 is not current for 43" "$?" "1"
echo 43 > "$D/revision"
vm_kernel_current "$D" 43; check "a kernel dir at revision 43 is current" "$?" "0"
: > "$D/initrd.img"
vm_kernel_current "$D" 43; check "a kernel dir with an empty initrd is not current" "$?" "1"
check "cachyos builder, direct" "$(cachyos_builder direct)" "tools/build/vm/cachyos-dev.sh"
check "cachyos builder, grub" "$(cachyos_builder grub)" "tools/build/vm/cachyos-base.sh"

check "cachyos base default" "$RHIZO_CACHYOS_BASE" "cachyos-stock"
check "cachyos base from the environment" \
  "$(env RHIZO_CACHYOS_BASE=cachyos-grub bash -c 'source "$1" && guest_base cachyos grub' _ "$HERE/../vm/guest-os/guest-os-lib.sh")" \
  "cachyos-dl/cachyos-grub.qcow2"
echo "$STOCK_UUID" > "$SCRATCH/cachyos-dl/cachyos-stock.root-uuid"
SDBOOT_UUID=0123abcd-0000-4000-8000-00000000e001 GRUB_UUID=0123abcd-0000-4000-8000-00000000f001
RHIZO_CACHYOS_BASE=cachyos-sdboot
check "sdboot base disk" "$(guest_base cachyos grub)" "cachyos-dl/cachyos-sdboot.qcow2"
check "sdboot base, direct boot" "$(guest_base cachyos direct)" "cachyos-dl/cachyos-dev.qcow2"
check "sdboot base builder" "$(cachyos_builder grub)" "tools/build/vm/cachyos-base.sh --bootloader systemd-boot --name cachyos-sdboot"
root_case "sdboot base, no uuid file" grub 1 "" \
  "no cachyos-dl/cachyos-sdboot.root-uuid -- run tools/build/vm/cachyos-base.sh --bootloader systemd-boot --name cachyos-sdboot first"
echo "$SDBOOT_UUID" > "$SCRATCH/cachyos-dl/cachyos-sdboot.root-uuid"
root_case "sdboot base uuid" grub 0 "root=UUID=$SDBOOT_UUID rootflags=subvol=/@ rw" ""
RHIZO_CACHYOS_BASE=cachyos-grub
check "grub base disk" "$(guest_base cachyos grub)" "cachyos-dl/cachyos-grub.qcow2"
check "grub base builder" "$(cachyos_builder grub)" "tools/build/vm/cachyos-base.sh --bootloader grub --name cachyos-grub"
echo "$GRUB_UUID" > "$SCRATCH/cachyos-dl/cachyos-grub.root-uuid"
root_case "grub base uuid" grub 0 "root=UUID=$GRUB_UUID rootflags=subvol=/@ rw" ""
for bad in cachyos-foo cachyos-dev ../cachyos-stock 'cachyos-stock.qcow2'; do
  RHIZO_CACHYOS_BASE=$bad
  out=$(guest_base cachyos grub 2>"$SCRATCH/err"); rc=$?
  check "base '$bad': rc" "$rc" "1"
  check "base '$bad': no disk" "$out" ""
  check "base '$bad': named" "$(grep -cF "RHIZO_CACHYOS_BASE is '$bad', which names no pristine cachyos base" "$SCRATCH/err")" "1"
  root_case "base '$bad', root" grub 1 "" "RHIZO_CACHYOS_BASE is '$bad', which names no pristine cachyos base"
done
RHIZO_CACHYOS_BASE=cachyos-stock

check "ubuntu has no vars"           "$(guest_vars ubuntu grub -3)"        ""
check "cachyos pristine vars"        "$(guest_vars cachyos grub -3)"       "OVMF_VARS-cachyos-pristine-3.fd"
check "cachyos direct vars"          "$(guest_vars cachyos direct -3)"     "OVMF_VARS-cachyos-3.fd"
check "cachyos direct vars source"   "$(guest_vars_base cachyos direct)"   "cachyos-dl/cachyos-stock.OVMF_VARS.fd"
for base in cachyos-stock cachyos-sdboot cachyos-grub; do
  check "$base vars source" "$(RHIZO_CACHYOS_BASE=$base guest_vars_base cachyos grub)" "cachyos-dl/$base.OVMF_VARS.fd"
  check "$base direct vars source" "$(RHIZO_CACHYOS_BASE=$base guest_vars_base cachyos direct)" "cachyos-dl/cachyos-stock.OVMF_VARS.fd"
done
RHIZO_CACHYOS_BASE=cachyos-foo
out=$(guest_vars_base cachyos grub 2>/dev/null); check "no vars source for an unknown base: rc" "$?" "1"
check "no vars source for an unknown base: output" "$out" ""
RHIZO_CACHYOS_BASE=cachyos-stock

mkdir "$SCRATCH/disks"
qemu-img create -q -f qcow2 "$SCRATCH/disks/base-a.qcow2" 1M && qemu-img create -q -f qcow2 "$SCRATCH/disks/base-b.qcow2" 1M \
  && (cd "$SCRATCH/disks" && qemu-img create -q -f qcow2 -b base-a.qcow2 -F qcow2 vm.qcow2) || { echo "qemu-img could not make the fixture disks"; exit 1; }
check "disk backing: a vm disk"  "$(guest_disk_backing "$SCRATCH/disks/vm.qcow2")"   "base-a.qcow2"
check "disk backing: a base"       "$(guest_disk_backing "$SCRATCH/disks/base-b.qcow2")" ""
out=$(guest_disk_backing "$SCRATCH/disks/absent.qcow2" 2>/dev/null); check "disk backing: no disk: rc" "$?" "1"
check "disk backing: no disk: output" "$out" ""

check "limine files"       "$(cachyos_bootloader_files limine)"       "limine /etc/default/limine /boot/limine.conf"
check "systemd-boot files" "$(cachyos_bootloader_files systemd-boot)" "sdboot /etc/sdboot-manage.conf /boot/loader/entries"
check "grub files"         "$(cachyos_bootloader_files grub)"         "grub-inline /etc/default/grub /boot/grub/grub.cfg"
cachyos_bootloader_files refind >/dev/null 2>&1; check "an unknown bootloader is refused" "$?" "1"

# run a probe text under the scratch directory
run_probe() {
  sed -e "s|/sys/kernel/security/lsm|$SCRATCH/g/lsm|g" -e "s|/sys/fs/selinux/enforce|$SCRATCH/g/enforce|g" \
      -e "s|/proc/cmdline|$SCRATCH/g/cmdline|g" -e "s|/etc/default/limine|$SCRATCH/g/limine|g" \
      -e "s|/boot/|$SCRATCH/g/boot/|g" <<<"$1" | bash
}
# check the stock-state probe over the fixture
stock_case() {
  local out rc
  out=$(run_probe "$(cachyos_stock_probe /etc/default/limine)" | cachyos_stock_mismatches /etc/default/limine); rc=$?
  check "$1: rc" "$rc" "$2"
  check "$1: lines" "$(grep -c . <<<"$out")" "$3"
  [[ -z "$4" ]] || check "$1: names it" "$(grep -cF -- "$4" <<<"$out")" "1"
}
mkdir -p "$SCRATCH/g/boot/loader/entries" "$SCRATCH/g/boot/grub"
STOCK_CMDLINE="splash quiet zswap.enabled=0 nowatchdog rw rootflags=subvol=/@ root=UUID=22222222-2222-4222-8222-222222222222"
# write fixture files for a stock kernel
stock_fixture() {
  printf 'capability,landlock,lockdown,yama,bpf' > "$SCRATCH/g/lsm"
  rm -f "$SCRATCH/g/enforce"
  echo "$STOCK_CMDLINE" > "$SCRATCH/g/cmdline"
  printf 'ESP_PATH="/boot"\nKERNEL_CMDLINE[default]="%s"\n' "$STOCK_CMDLINE" > "$SCRATCH/g/limine"
}
stock_fixture; stock_case "stock cachyos" 0 0 ""
stock_fixture; printf 'capability,landlock,lockdown,yama,selinux,bpf' > "$SCRATCH/g/lsm"
stock_case "selinux active" 1 1 "selinux is already an active LSM before the bootstrap ran (lsm=capability,landlock,lockdown,yama,selinux,bpf)"
stock_fixture; printf 'capability,landlock,lockdown,yama,apparmor,bpf' > "$SCRATCH/g/lsm"
stock_case "apparmor active" 1 1 "apparmor is an active LSM, which stock cachyos does not start (lsm=capability,landlock,lockdown,yama,apparmor,bpf)"
stock_fixture; rm -f "$SCRATCH/g/lsm"
stock_case "no lsm file" 1 1 "/sys/kernel/security/lsm did not read as an LSM list: 'cat: "
stock_fixture; : > "$SCRATCH/g/enforce"
stock_case "selinuxfs mounted" 1 1 "/sys/fs/selinux/enforce already exists before the bootstrap ran"
for tok in security=selinux lsm=landlock,yama,selinux androidboot.hardware=rhizo; do
  stock_fixture; echo "$STOCK_CMDLINE $tok" > "$SCRATCH/g/cmdline"
  stock_case "cmdline carries $tok" 1 1 "/proc/cmdline already carries $tok"
done
stock_fixture; echo "$STOCK_CMDLINE security=apparmor xlsm=1 androidboot" > "$SCRATCH/g/cmdline"
stock_case "lookalike words on the cmdline" 0 0 ""
stock_fixture; : > "$SCRATCH/g/cmdline"
stock_case "empty cmdline" 1 1 "/proc/cmdline read empty"
stock_fixture; printf '# >>> rhizo\nKERNEL_CMDLINE[default]+=" security=selinux"\n# <<< rhizo\n' >> "$SCRATCH/g/limine"
stock_case "a rhizo block" 1 1 "/etc/default/limine already carries 1 '# >>> rhizo' line(s)"
stock_fixture; rm -f "$SCRATCH/g/limine"
stock_case "no config file" 1 1 "cannot count '# >>> rhizo' lines in /etc/default/limine: read 'grep: "
stock_fixture
out=$(run_probe "$(cachyos_stock_probe /etc/default/limine)" | grep -v '^probe=done$' | cachyos_stock_mismatches /etc/default/limine); rc=$?
check "a probe cut short: rc" "$rc" "1"
check "a probe cut short: named" "$(grep -c 'did not run to its end' <<<"$out")" "1"

TOKS="security=selinux loop.max_loop=64 androidboot.hardware=rhizo"
# check the next-boot cmdline probe over the fixture
cmd_case() {
  local out rc
  out=$(run_probe "$(cachyos_cmdlines_probe "$2")" | cmdlines_missing_tokens "$TOKS"); rc=$?
  check "$1: rc" "$rc" "$3"
  check "$1: lines" "$(grep -c . <<<"$out")" "$4"
  [[ -z "$5" ]] || check "$1: names it" "$(grep -cF -- "$5" <<<"$out")" "1"
}
# print a limine.conf with two cmdlines
limine_conf() {
  printf '/+CachyOS\ncomment: machine-id=2dd5 order-priority=50 \n  //linux-cachyos\n  protocol: linux\n  cmdline: %s\n\n' "$1"
  printf '     //Snapshots\n     ///2 \xe2\x94\x82 2026-10-03\n     ////linux-cachyos\n     cmdline: %s\n\n' "$2"
  printf '/EFI fallback\nprotocol: efi\npath: boot():/EFI/BOOT/BOOTX64.EFI\n'
}
SNAP="rw rootflags=subvol=/@/.snapshots/2/snapshot root=UUID=d399"
limine_conf "$TOKS rw rootflags=subvol=/@ root=UUID=d399" "$SNAP" > "$SCRATCH/g/boot/limine.conf"
cmd_case "limine, tokens on the kernel entry, none on a snapshot" limine 0 0 ""
limine_conf "rw rootflags=subvol=/@ root=UUID=d399" "$SNAP" > "$SCRATCH/g/boot/limine.conf"
cmd_case "limine, no tokens" limine 1 1 "lacks: security=selinux loop.max_loop=64 androidboot.hardware=rhizo"
limine_conf "$TOKS rw rootflags=subvol=/@" "$SNAP" > "$SCRATCH/g/boot/limine.conf"
cmd_case "limine, no root=" limine 1 1 "lacks: root="
limine_conf "security=selinux androidboot.hardware=rhizo root=UUID=d399" "$SNAP" > "$SCRATCH/g/boot/limine.conf"
cmd_case "limine, one token short" limine 1 1 "lacks: loop.max_loop=64"
printf '/EFI fallback\nprotocol: efi\n' > "$SCRATCH/g/boot/limine.conf"
cmd_case "limine, no kernel entry" limine 1 1 "no next-boot cmdline was read"
rm -f "$SCRATCH/g/boot/limine.conf"
cmd_case "limine, no generated file" limine 1 1 "no next-boot cmdline was read" 2>/dev/null
printf 'title Linux CachyOS\noptions root=UUID=36c6 rw rootflags=subvol=/@ nowatchdog %s\nlinux /vmlinuz-linux-cachyos\n' "$TOKS" \
  > "$SCRATCH/g/boot/loader/entries/linux-cachyos.conf"
cmd_case "sdboot, tokens" sdboot 0 0 ""
printf 'title Other\noptions root=UUID=0000 rw\n' > "$SCRATCH/g/boot/loader/entries/other.conf"
cmd_case "sdboot, a second entry without them" sdboot 1 1 "next-boot cmdline 'root=UUID=0000 rw' lacks: $TOKS"
GRUB_LINE="root=UUID=86ab rw rootflags=subvol=@ $TOKS splash quiet"
printf "menuentry 'Arch Linux' {\n\tlinux\t/vmlinuz-linux-cachyos %s\n}\nsubmenu 'Advanced' {\n\t\tlinux\t/vmlinuz-linux-cachyos %s\n}\nmenuentry 'UEFI Firmware Settings' {\n\tfwsetup\n}\n" \
  "$GRUB_LINE" "$GRUB_LINE" > "$SCRATCH/g/boot/grub/grub.cfg"
cmd_case "grub, both 10_linux entries" grub-inline 0 0 ""
printf "submenu 'snapshots' {\n\tlinux\t/vmlinuz-linux-cachyos root=UUID=86ab rw rootflags=subvol=@/.snapshots/2/snapshot\n}\n" >> "$SCRATCH/g/boot/grub/grub.cfg"
cmd_case "grub, a snapshot entry left out" grub-inline 0 0 ""
printf "menuentry 'recovery' {\n\tlinux\t/vmlinuz-linux-cachyos root=UUID=86ab rw single\n}\n" >> "$SCRATCH/g/boot/grub/grub.cfg"
cmd_case "grub, a recovery entry without them" grub-inline 1 1 "next-boot cmdline 'root=UUID=86ab rw single' lacks: $TOKS"
out=$(run_probe "$(cachyos_cmdlines_probe grub-inline)" | grep -v '^probe=done$' | cmdlines_missing_tokens "$TOKS"); rc=$?
check "cmdline probe cut short: rc" "$rc" "1"
check "cmdline probe cut short: named" "$(grep -c 'did not run to its end' <<<"$out")" "1"
cachyos_cmdlines_probe grub-dropin >/dev/null 2>&1; check "no cmdline reader for ubuntu's kind" "$?" "1"

RSV="$SCRATCH/rsv"
mkdir -p "$RSV/test/vm/guest-os" "$RSV/test/vm/rig" "$RSV/src/install/prepare" "$RSV/var/cachyos-dl" "$RSV/var/share" "$RSV/sys/renderD128/device/drm/card0"
cp "$HERE/../vm/run-vm.sh" "$RSV/test/vm/" || { echo "cannot copy run-vm.sh"; exit 1; }
cp "$HERE/../vm/guest-os/guest-os-lib.sh" "$RSV/test/vm/guest-os/" || { echo "cannot copy guest-os-lib.sh"; exit 1; }
cp "$HERE/../../src/install/prepare/detect-gpu-driver.sh" "$RSV/src/install/prepare/" || { echo "cannot copy detect-gpu-driver.sh"; exit 1; }
echo DRIVER=amdgpu > "$RSV/sys/renderD128/device/uevent"
cp "$HERE/../vm/rig/hooks.sh" "$RSV/test/vm/rig/" || { echo "cannot copy hooks.sh"; exit 1; }
printf '%s\n' 'rig_boot_guard() { echo "run-vm.sh: refusing to boot vm $1 at the fixture guard" >&2; return 1; }' > "$RSV/guard-hook.sh"
for base in cachyos-stock cachyos-sdboot cachyos-grub; do
  qemu-img create -q -f qcow2 "$RSV/var/cachyos-dl/$base.qcow2" 1M || { echo "qemu-img could not make $base"; exit 1; }
  echo "vars of $base" > "$RSV/var/cachyos-dl/$base.OVMF_VARS.fd"
done
VM_DISK="$RSV/var/vm-cachyos-pristine-3.qcow2" VM_VARS="$RSV/var/OVMF_VARS-cachyos-pristine-3.fd"
# run the copied run-vm.sh for vm 3
rsv() {
  env -i PATH="$PATH" HOME="$HOME" RHIZO_VM=3 RHIZO_GUEST_OS=cachyos RHIZO_BOOT=grub RHIZO_CACHYOS_BASE="$1" \
    RHIZO_VM_HOOK="$RSV/guard-hook.sh" RHIZO_SYS_CLASS_DRM="$RSV/sys" bash "$RSV/test/vm/run-vm.sh" > "$RSV/out" 2>&1
  RSV_RC=$?
}
# count the boot guard's refusals
at_guard() { grep -c 'refusing to boot vm 3 at the fixture guard' "$RSV/out"; }
rsv cachyos-sdboot
check "vm on sdboot: reaches the boot guard" "$RSV_RC:$(at_guard)" "1:1"
check "vm on sdboot: disk backed by sdboot" "$(guest_disk_backing "$VM_DISK")" "cachyos-dl/cachyos-sdboot.qcow2"
check "vm on sdboot: vars are sdboot's" "$(cat "$VM_VARS")" "vars of cachyos-sdboot"
echo "written by firmware" >> "$VM_VARS"
rsv cachyos-sdboot
check "vm on sdboot again: its own vars kept" "$RSV_RC:$(at_guard):$(tail -1 "$VM_VARS")" "1:1:written by firmware"
rsv cachyos-grub
check "vm on sdboot asked for grub: refused before the boot guard" "$RSV_RC:$(at_guard)" "1:0"
check "vm on sdboot asked for grub: names both" \
  "$(grep -cF "is backed by 'cachyos-dl/cachyos-sdboot.qcow2', not cachyos-dl/cachyos-grub.qcow2" "$RSV/out")" "1"
check "vm on sdboot asked for grub: disk kept" "$(guest_disk_backing "$VM_DISK")" "cachyos-dl/cachyos-sdboot.qcow2"
rm -f "$VM_VARS"
rsv cachyos-sdboot
check "vm on sdboot with no vars: sdboot's copied" "$RSV_RC:$(at_guard):$(cat "$VM_VARS")" "1:1:vars of cachyos-sdboot"
echo "written by firmware" >> "$VM_VARS"
rm -f "$VM_DISK"
rsv cachyos-grub
check "a new disk on grub: backed by grub" "$(guest_disk_backing "$VM_DISK")" "cachyos-dl/cachyos-grub.qcow2"
check "a new disk on grub: grub's vars over the old ones" "$RSV_RC:$(at_guard):$(cat "$VM_VARS")" "1:1:vars of cachyos-grub"

check "cachyos pristine disk slot" "$(guest_disk_slot cachyos grub)" "0x5"
check "cachyos direct disk slot"   "$(guest_disk_slot cachyos direct)" ""
check "ubuntu pristine disk slot"  "$(guest_disk_slot ubuntu grub)" ""
# print the qemu argv of the copied run-vm.sh
argv() {
  env -i PATH="$PATH" HOME="$HOME" RHIZO_PRINT_ARGV=1 RHIZO_VM=3 RHIZO_GUEST_OS="$1" RHIZO_BOOT="$2" \
    RHIZO_SYS_CLASS_DRM="$RSV/sys" bash "$RSV/test/vm/run-vm.sh" 2>/dev/null | tr '\n' ' '
}
check "cachyos pristine argv: the disk at slot 5" \
  "$(argv cachyos grub | grep -c -- '-drive file=vm-cachyos-pristine-3.qcow2,if=none,id=disk0,backing.file.locking=off -device virtio-blk-pci,drive=disk0,addr=0x5 ')" "1"
check "ubuntu pristine argv: the disk where qemu puts it" \
  "$(argv ubuntu grub | grep -c -- '-drive file=vm-pristine-3.qcow2,if=virtio,backing.file.locking=off ')" "1"
check "ubuntu pristine argv: no slot" "$(argv ubuntu grub | grep -c 'addr=')" "0"

(( FAILED )) && exit 1
echo "the guest os lib passed $CASES cases"
