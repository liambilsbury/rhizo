#!/bin/bash
# install the Rhizo kernel into a vm's disk
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh
source ../guest-os/guest-os-lib.sh

CHECK=0
case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) echo "usage: RHIZO_VM=N test/vm/image/install-kernel.sh [--check]" >&2; exit 2 ;;
esac
[[ -z "${RHIZO_KERNEL:-}" ]] || { echo "install-kernel.sh: RHIZO_KERNEL=$RHIZO_KERNEL is set; the Rhizo kernel needs it unset" >&2; exit 2; }

OS="$RHIZO_GUEST_OS"
REV=$(rhizo_kernel_revision "$REPO") || exit 1
DISK="$VAR_DIR/$(guest_disk "$OS" direct "$SUFFIX")"
KDIR=$(vm_kernel_dir "$DISK") || exit 1
if vm_kernel_current "$KDIR" "$REV"; then
  (( CHECK )) && echo "vm $RHIZO_VM's disk holds the Rhizo kernel at revision $REV"
  exit 0
fi
if (( CHECK )); then
  echo "vm $RHIZO_VM's disk $DISK holds no Rhizo kernel at revision $REV ($KDIR has '$(cat "$KDIR/revision" 2>/dev/null)')"
  exit 1
fi

# print the directory of the built kernel packages
package_dir() {
  local main
  if rhizo_kernel_packages "$OS" "$VAR_DIR/kernel/$OS" "$REV" >/dev/null; then echo "$VAR_DIR/kernel/$OS"; return 0; fi
  main=$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  main=$(dirname "$main")
  rhizo_kernel_packages "$OS" "$main/var/kernel/$OS" "$REV" >/dev/null || return 1
  echo "$main/var/kernel/$OS"
}

PKGDIR=$(package_dir) || {
  log "FAIL: the Rhizo kernel at revision $REV (kernel/VERSION) is not built for $OS: no package of it in $VAR_DIR/kernel/$OS"
  log "  $(rhizo_kernel_builder "$OS") builds it"
  exit 1
}
mapfile -t PKGS < <(rhizo_kernel_packages "$OS" "$PKGDIR" "$REV")
KREL=$(rhizo_kernel_release "${PKGS[0]}") || { log "FAIL: cannot read the kernel release from ${PKGS[0]##*/}"; exit 1; }
log "=== vm $RHIZO_VM: install the Rhizo kernel $KREL at revision $REV into $DISK"

export RHIZO_KERNEL=distro
kill_vm || { log "FAIL: vm $RHIZO_VM's guest would not stop"; exit 1; }
boot_vm
wait_for_boot_slot || { log "FAIL: vm $RHIZO_VM's boot on its own kernel never got a qemu slot"; exit 1; }
wait_for_ssh 300 || { log "FAIL: vm $RHIZO_VM did not answer ssh on its own kernel"; exit 1; }

names=()
for f in "${PKGS[@]}"; do names+=("/root/rhizo-kernel/${f##*/}"); done
ssh_vm -t 30 'rm -rf /root/rhizo-kernel && mkdir -p /root/rhizo-kernel' || { log "FAIL: cannot make /root/rhizo-kernel on the guest"; exit 1; }
timeout 600 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "${PKGS[@]}" "$SSH_TARGET:/root/rhizo-kernel/" \
  || { log "FAIL: cannot copy the kernel packages into the guest"; exit 1; }
case "$OS" in
  ubuntu)
    install_cmd="DEBIAN_FRONTEND=noninteractive dpkg -i ${names[*]}"
    check_cmd="dpkg-query -W -f='\${Version}' linux-image-$KREL"
    want="$KREL-$REV"
    guest_kernel="/boot/vmlinuz-$KREL" guest_initrd="/boot/initrd.img-$KREL" ;;
  cachyos)
    install_cmd="pacman -U --noconfirm ${names[*]} && { [ -s /boot/initramfs-linux-rhizo.img ] || mkinitcpio -k $KREL -g /boot/initramfs-linux-rhizo.img; }"
    check_cmd="pacman -Q linux-rhizo | cut -d' ' -f2"
    want="${KREL//-/_}-$REV"
    guest_kernel="/usr/lib/modules/$KREL/vmlinuz" guest_initrd="/boot/initramfs-linux-rhizo.img" ;;
esac
log "  $install_cmd"
out=$(ssh_vm -t 1200 "$install_cmd" 2>&1)
rc=$?
tail -5 <<<"$out" | sed 's/^/    /' >&2
(( rc == 0 )) || { log "FAIL: the install exited $rc on the guest"; exit 1; }
got=$(ssh_vm -t 30 "$check_cmd" | tr -d '\r')
[[ "$got" == "$want" ]] || { log "FAIL: the guest's installed kernel package is '$got', not $want"; exit 1; }
ssh_vm -t 60 "test -s $guest_kernel && test -s $guest_initrd && test -d /lib/modules/$KREL && rm -rf /root/rhizo-kernel && sync" \
  || { log "FAIL: the guest has no $guest_kernel, $guest_initrd or /lib/modules/$KREL after the install"; exit 1; }

mkdir -p "$KDIR" || { log "FAIL: cannot make $KDIR"; exit 1; }
rm -f "$KDIR/revision"
timeout 120 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_TARGET:$guest_kernel" "$KDIR/vmlinuz.new" \
  && timeout 120 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_TARGET:$guest_initrd" "$KDIR/initrd.img.new" \
  || { log "FAIL: cannot copy $guest_kernel and $guest_initrd out of the guest"; exit 1; }
mv -f "$KDIR/vmlinuz.new" "$KDIR/vmlinuz" && mv -f "$KDIR/initrd.img.new" "$KDIR/initrd.img" \
  || { log "FAIL: cannot move the boot pair into $KDIR"; exit 1; }
kill_vm || { log "FAIL: vm $RHIZO_VM's guest would not stop after the install"; exit 1; }
echo "$REV" > "$KDIR/revision"
log "=== vm $RHIZO_VM: the Rhizo kernel $KREL-$REV is installed; its boot pair is in $KDIR"
