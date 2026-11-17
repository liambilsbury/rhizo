#!/bin/bash
# podman installer for the build container host
set -euo pipefail
if command -v podman >/dev/null || command -v docker >/dev/null; then
  echo "$(command -v podman || command -v docker) is installed"
  exit 0
fi
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *" arch "*) sudo pacman -S --needed --noconfirm podman ;;
  *" ubuntu "*|*" debian "*) sudo apt-get install -y podman ;;
  *" fedora "*) sudo dnf install -y podman ;;
  *) echo "ID=${ID:-} ID_LIKE=${ID_LIKE:-} is not arch, ubuntu, debian or fedora" >&2; exit 1 ;;
esac
if ! grep -q "^$(id -un):" /etc/subuid; then
  echo "/etc/subuid has no range for $(id -un)" >&2
  exit 1
fi
