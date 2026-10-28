#!/bin/bash
# set REPO, VAR_DIR and log()
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034
VAR_DIR="$REPO/var"

# print a timestamped message to stderr
log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }
