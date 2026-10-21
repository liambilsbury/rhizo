#!/bin/bash
# fetch the Ubuntu 24.04 base image's package manifest
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RELEASE=release-20260801
FILE=ubuntu-24.04-server-cloudimg-amd64.manifest
URL="https://cloud-images.ubuntu.com/releases/noble/$RELEASE/$FILE"
SHA256=6fa20bf5cdab0b64003d2b6587a9f7343ee541234e5119078a7004b0df3d0b6d
DEST="$REPO/var/pristine-dl/$FILE"

if [[ -f "$DEST" ]] && sha256sum -c --status <<<"$SHA256  $DEST"; then
  echo "ubuntu-base-manifest: $DEST is present and matches"
  exit 0
fi
mkdir -p "$(dirname "$DEST")" || exit 1
if ! timeout 120 curl -fsSL -o "$DEST.part" "$URL"; then
  echo "ubuntu-base-manifest: could not download $URL" >&2
  exit 1
fi
if ! sha256sum -c --status <<<"$SHA256  $DEST.part"; then
  echo "ubuntu-base-manifest: $URL does not match its pinned sha256 $SHA256" >&2
  mv "$DEST.part" "$DEST.rejected"
  exit 1
fi
mv "$DEST.part" "$DEST" && echo "ubuntu-base-manifest: fetched $DEST"
