#!/bin/bash
# fetch and verify Ubuntu 24.04's selinux-policy-default into var/host-policy
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE=selinux-policy-default_2.20240202-1_all.deb
URL="http://archive.ubuntu.com/ubuntu/pool/universe/r/refpolicy/$FILE"
SHA256=793526d8270d6283438fb93b3924d4536e49c767886b85ce75b8447f547f7cef
DEST="$REPO/var/host-policy/$FILE"

if [[ -f "$DEST" ]] && sha256sum -c --status <<<"$SHA256  $DEST"; then
  echo "host-policy: $DEST is present and matches"
  exit 0
fi
mkdir -p "$(dirname "$DEST")" || exit 1
if ! timeout 300 curl -fsSL -o "$DEST.part" "$URL"; then
  echo "host-policy: could not download $URL" >&2
  exit 1
fi
if ! sha256sum -c --status <<<"$SHA256  $DEST.part"; then
  echo "host-policy: $URL does not match its pinned sha256 $SHA256" >&2
  mv "$DEST.part" "$DEST.rejected"
  exit 1
fi
mv "$DEST.part" "$DEST" && echo "host-policy: fetched $DEST"
