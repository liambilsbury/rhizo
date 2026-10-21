#!/bin/bash
# build the CachyOS kernel packages in an Arch container
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cache=$(cd "${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}" && pwd)
out=${1:?usage: build-cachyos-in-container.sh <outdir> [distro-config]} cfg=${2:-$cache/config-cachyos}
cfg=$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")
mkdir -p "$out"; out=$(cd "$out" && pwd)
mounts=(-v "$root:$root:ro" -v "$cache:$cache" -v "$out:$out")
[[ "$(dirname "$cfg")" == "$cache" ]] || mounts+=(-v "$(dirname "$cfg"):$(dirname "$cfg"):ro")
podman run --rm --userns=keep-id --user 0 "${mounts[@]}" \
  -e RHIZO_KERNEL_CACHE="$cache" docker.io/library/archlinux:latest bash -c '
    set -euo pipefail
    pacman -Syu --noconfirm -q base-devel bc cpio pahole python git zstd libelf kmod inetutils rsync xz openssl perl \
      gettext bison flex >/dev/null
    user=$(getent passwd "$3" | cut -d: -f1 || true)
    [[ -n "$user" ]] || { useradd -m -u "$3" build; user=build; }
    runuser -u "$user" -- env HOME=/tmp GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="*" \
      "$0/build.sh" cachyos "$2" "$1"' "$here" "$cfg" "$out" "$(id -u)"
