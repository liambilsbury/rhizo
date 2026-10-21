#!/bin/bash
# install the container engine the build environment runs in
set -euo pipefail
if command -v podman >/dev/null || command -v docker >/dev/null; then
  echo "setup-host: $(command -v podman || command -v docker) is already installed"
  exit 0
fi
. /etc/os-release
case " ${ID:-} ${ID_LIKE:-} " in
  *" arch "*) sudo pacman -S --needed --noconfirm podman ;;
  *" ubuntu "*|*" debian "*) sudo apt-get install -y podman ;;
  *" fedora "*) sudo dnf install -y podman ;;
  *) echo "setup-host: install podman with this system's package manager, then run make setup again" >&2; exit 1 ;;
esac
if ! grep -q "^$(id -un):" /etc/subuid; then
  echo "setup-host: rootless podman needs a subuid range for $(id -un) -- add one with:" >&2
  echo "  sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $(id -un)" >&2
  exit 1
fi
echo "setup-host: podman installed"
