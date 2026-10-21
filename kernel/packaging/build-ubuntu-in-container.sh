#!/bin/bash
# build the Ubuntu kernel debs in an Ubuntu container
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cache=$(cd "${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}" && pwd)
out=${1:?usage: build-ubuntu-in-container.sh <outdir> [distro-config]} cfg=${2:-$cache/config-ubuntu}
cfg=$(cd "$(dirname "$cfg")" && pwd)/$(basename "$cfg")
mkdir -p "$out"; out=$(cd "$out" && pwd)
mounts=(-v "$root:$root:ro" -v "$cache:$cache" -v "$out:$out")
[[ "$(dirname "$cfg")" == "$cache" ]] || mounts+=(-v "$(dirname "$cfg"):$(dirname "$cfg"):ro")
podman run --rm "${mounts[@]}" \
  -e RHIZO_KERNEL_CACHE="$cache" docker.io/library/ubuntu:24.04 bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential bc bison flex cpio kmod rsync \
      python3 perl dpkg-dev debhelper libelf-dev libdw-dev libssl-dev openssl dwarves zstd xz-utils git >/dev/null
    git config --global --add safe.directory "*"
    "$0/build.sh" ubuntu "$2" "$1"' "$here" "$cfg" "$out"
