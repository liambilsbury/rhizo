#!/bin/bash
# Secure Boot sbsign of a Rhizo kernel image
set -euo pipefail
img=$1 key=$2 cert=$3
trap 'rm -f "$img.signed"' EXIT
sbsign --key "$key" --cert "$cert" --output "$img.signed" "$img"
sbverify --cert "$cert" "$img.signed"
mv "$img.signed" "$img"
