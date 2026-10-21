#!/bin/bash
# test rhizo-deskd composer drop path containment
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit
python3 ./services/deskbridge/deskd-drop-traversal.py
