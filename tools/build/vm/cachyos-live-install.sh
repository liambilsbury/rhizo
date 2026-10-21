#!/bin/bash
# install cachyos from the live iso and power off
exec >/dev/virtio-ports/org.rhizo.install 2>&1
stop() { echo "RHIZO_LIVE_FAIL=$1"; poweroff; exit 1; }
cd /run/rhizo-install || stop "no /run/rhizo-install"
chmod +x cachyos-post-install.sh || stop "chmod cachyos-post-install.sh exited $?"
echo "live system boot: $(systemctl is-system-running --wait)"
nm-online -q -t 120 || stop "nm-online found no network connection in 120s, rc=$?"
cp /etc/pacman-more.conf /etc/pacman.conf || stop "cp /etc/pacman-more.conf exited $?"
/etc/calamares/scripts/detect-architecture /etc/pacman.conf || stop "detect-architecture exited $?"
sed -i 's/^\(\[[^]]*\]\) *$/\1/' /etc/pacman.conf || stop "sed on /etc/pacman.conf exited $?"
echo "live repos: $(grep '^\[' /etc/pacman.conf | tr '\n' ' ')"
cachyos-installer --config settings.json
echo "RHIZO_INSTALL_RC=$?"
echo "RHIZO_POST_INSTALL_RC=$(cat post-install.rc)"
cat post-install.log
poweroff
