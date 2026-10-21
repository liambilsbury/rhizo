#!/bin/bash
# add ssh and the share mount
set -euo pipefail
exec > /run/rhizo-install/post-install.log 2>&1
trap 'echo $? > /run/rhizo-install/post-install.rc' EXIT
part="$1" bootloader="$2"
mount -o subvol=/@ "$part" /mnt
mount --fstab /mnt/etc/fstab --target-prefix /mnt /root
mount --fstab /mnt/etc/fstab --target-prefix /mnt /boot
install -d -m 0700 /mnt/root/.ssh
install -m 0600 /run/rhizo-install/vm_key.pub /mnt/root/.ssh/authorized_keys
systemctl --root=/mnt enable sshd.service
arch-chroot /mnt ufw allow 22/tcp
install -d /mnt/root/share
echo 'share9p /root/share 9p trans=virtio,version=9p2000.L,msize=1048576,nofail 0 0' >> /mnt/etc/fstab
if [[ "$bootloader" == limine ]]; then
  os=$(grep -m 1 -oP '^/\+\K.*' /mnt/boot/limine.conf) || { echo "no os entry in limine.conf"; exit 1; }
  kernel=$(grep -m 1 -oP '^ *//\K.*' /mnt/boot/limine.conf) || { echo "no kernel entry in limine.conf"; exit 1; }
  printf '\x07\x00\x00\x00%s/%s\x00' "$os" "$kernel" \
    > /sys/firmware/efi/efivars/LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a
  echo "limine entry $os/$kernel"
fi
umount -R /mnt
