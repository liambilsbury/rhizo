#!/bin/bash
# download the pinned cachyos desktop iso
set -euo pipefail
ISO_DATE=260809
ISO_SHA=959f6577f45e25ee9fd8c220fd221b08e4ea79412c7315c0f922dd6d86d5e33c
ISO_NAME="cachyos-desktop-linux-$ISO_DATE.iso"
ISO_URL="https://mirror.cachyos.org/ISO/desktop/$ISO_DATE/$ISO_NAME"
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
mkdir -p var/cachyos-dl
dest="var/cachyos-dl/$ISO_NAME"
have=""
[[ -f "$dest" ]] && have=$(sha256sum "$dest" | cut -d' ' -f1)
if [[ "$have" != "$ISO_SHA" ]]; then
  curl --fail --location --continue-at - --output "$dest.part" "$ISO_URL"
  got=$(sha256sum "$dest.part" | cut -d' ' -f1)
  if [[ "$got" != "$ISO_SHA" ]]; then
    rm -f "$dest.part"
    echo "sha256 of $ISO_URL is $got, pinned $ISO_SHA" >&2
    exit 1
  fi
  mv "$dest.part" "$dest"
fi
echo "$dest"
