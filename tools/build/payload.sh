#!/bin/bash
# build the shipping payload
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit
case "${1:-}" in
  "") make payload && test/checks/build/build-set.sh ;;
  --list-products) python3 tools/build/stamps.py products ;;
  *) echo "usage: $0 [--list-products]" >&2; exit 2 ;;
esac
