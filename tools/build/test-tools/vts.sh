#!/bin/bash
# build the VTS test suite from AOSP
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../../test/vm/common.sh

AOSP_DIR="${RHIZO_AOSP_DIR:-$HOME/aosp-android16}"
BRANCH="android16-release"
SYNC_ONLY=0
[[ "${1:-}" == "--sync-only" ]] && SYNC_ONLY=1

mkdir -p "$AOSP_DIR"
cd "$AOSP_DIR" || exit

if [[ "${RHIZO_SKIP_APT:-}" != "1" ]]; then
  log "installing AOSP build-environment packages ..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    git-core gnupg flex bison build-essential zip curl zlib1g-dev \
    libncurses-dev libssl-dev libxml2-utils xsltproc unzip fontconfig \
    bc rsync ccache python3 python-is-python3 lib32z1 lib32ncurses6 \
    libgl1-mesa-dev x11proto-core-dev libx11-dev \
    2>&1 | tail -40 || log "WARN: some packages failed to install, continuing"
fi

if [[ ! -d .repo ]]; then
  avail_kb=$(df -k --output=avail . | tail -1 | tr -d ' ')
  if (( avail_kb < 150000000 )); then
    log "FAIL: only $((avail_kb/1024/1024)) GB free at $AOSP_DIR -- need >=150 GB headroom for a shallow AOSP checkout+build"
    exit 1
  fi
  log "repo init -b $BRANCH --depth=1 (avail: $((avail_kb/1024/1024)) GB)"
  repo init -u https://android.googlesource.com/platform/manifest -b "$BRANCH" --depth=1 --no-tags \
    || { log "FAIL: repo init failed"; exit 1; }
else
  log "repo already initialized at $AOSP_DIR"
fi

log "repo sync -c -j$(nproc) --no-tags --optimized-fetch --prune (this is the schedule-dominating step, expect hours) ..."
repo sync -c -j"$(nproc)" --no-tags --optimized-fetch --prune --force-sync \
  || { log "FAIL: repo sync failed"; exit 1; }
log "repo sync complete"

if (( SYNC_ONLY )); then log "--sync-only: stopping before build"; exit 0; fi

log "make vts -j$(nproc) (lunch aosp_x86_64-userdebug) ..."
set +u
source build/envsetup.sh
lunch aosp_x86_64-userdebug
set -u
make vts -j"$(nproc)" 2>&1 | tail -200
BUILD_RC=${PIPESTATUS[0]}
if (( BUILD_RC != 0 )); then
  log "FAIL: make vts exited $BUILD_RC"
  exit 1
fi

OUT_ZIP="$AOSP_DIR/out/host/linux-x86/vts/android-vts.zip"
test -f "$OUT_ZIP" || { log "FAIL: $OUT_ZIP not produced despite a clean exit"; exit 1; }

mkdir -p "$VAR_DIR/suites"
cp -f "$OUT_ZIP" "$VAR_DIR/suites/android-vts.zip"
log "=== VTS built: $VAR_DIR/suites/android-vts.zip ($(du -h "$VAR_DIR/suites/android-vts.zip" | cut -f1))"
log "    source: $BRANCH @ $(git -C build/soong log -1 --format=%H 2>/dev/null || echo unknown)"
