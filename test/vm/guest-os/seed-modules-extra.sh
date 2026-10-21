#!/bin/bash
# unpack linux-modules-extra into the guest kernel tree
set -uo pipefail
DEB="${RHIZO_MODULES_EXTRA_DEB:-/root/share/modules-extra.deb}"
K=$(uname -r)
modprobe -n uhid >/dev/null 2>&1 && modprobe -n quota_v2 >/dev/null 2>&1 && exit 0
if [ "$(dpkg-deb -f "$DEB" Package 2>/dev/null)" != "linux-modules-extra-$K" ]; then
  echo "RHIZO_MODULES_EXTRA=absent kernel=$K"
  exit 0
fi
rm -rf /tmp/rhizo-mx && mkdir -p /tmp/rhizo-mx
dpkg-deb -x "$DEB" /tmp/rhizo-mx || { echo "RHIZO_MODULES_EXTRA=failed step=unpack kernel=$K"; exit 1; }
cp -a "/tmp/rhizo-mx/lib/modules/$K/." "/lib/modules/$K/" || { echo "RHIZO_MODULES_EXTRA=failed step=copy kernel=$K"; exit 1; }
rm -rf /tmp/rhizo-mx
depmod -a "$K" || { echo "RHIZO_MODULES_EXTRA=failed step=depmod kernel=$K"; exit 1; }
echo "RHIZO_MODULES_EXTRA=seeded kernel=$K"
