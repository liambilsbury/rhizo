#!/bin/bash
# test rhizo-deskd open_on_host limits
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit
python3 ./services/deskbridge/deskd-open-uri.py
