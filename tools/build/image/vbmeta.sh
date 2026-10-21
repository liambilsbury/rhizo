#!/bin/bash
# build vbmeta.img and its digest
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(cd "." && pwd)"

AVBTOOL="$ROOT/aosp-android16-qpr2/external/avb/avbtool.py"
if [[ ! -f "$AVBTOOL" ]]; then
  echo "[build-vbmeta] no $AVBTOOL -- run tools/fetch/build-inputs.sh --only aosp" >&2
  exit 1
fi

mkdir -p "$ROOT/var/share"
OUT="$ROOT/var/share/vbmeta.img"
DIGEST_FILE="$ROOT/var/share/vbmeta.digest"

python3 "$AVBTOOL" make_vbmeta_image \
  --output "$OUT" \
  --algorithm NONE \
  --set_hashtree_disabled_flag \
  --set_verification_disabled_flag \
  --padding_size 4096

DIGEST="$(python3 "$AVBTOOL" calculate_vbmeta_digest --image "$OUT" --hash_algorithm sha256 | tr -d '[:space:]')"
printf '%s' "$DIGEST" > "$DIGEST_FILE"

echo "[build-vbmeta] $OUT ($(stat -c%s "$OUT") bytes), sha256=$DIGEST"
