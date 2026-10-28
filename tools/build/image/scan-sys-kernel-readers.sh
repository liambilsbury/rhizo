#!/bin/bash
# list the /sys/kernel names Android reads
set -uo pipefail
export LC_ALL=C
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TREE="$REPO/aosp-android16-qpr2"
OUT="$REPO/var/share/sys-kernel-readers.txt"
CHECK=0 SELFTEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --selftest) SELFTEST=1; CHECK=1; shift ;;
    --list) OUT="$2"; shift 2 ;;
    --tree) TREE="$2"; shift 2 ;;
    *) echo "scan-sys-kernel-readers.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

[[ -d "$TREE/frameworks" && -d "$TREE/system" && -d "$TREE/hardware" ]] || {
  echo "scan-sys-kernel-readers.sh: no AOSP tree at $TREE" >&2
  exit 1; }

HEADER="# /sys/kernel children AOSP names, scanned from aosp-android16-qpr2 by tools/build/image/scan-sys-kernel-readers.sh: \"/sys/kernel/ literals in frameworks,system,hardware (sepolicy sources excluded) plus genfscon sysfs /kernel in plat sepolicy -- Apache-2.0-derived data"

# list the top-level /sys/kernel names the source tree reads
scan() {
  {
    grep -rhoaI '"/sys/kernel/[A-Za-z0-9_./%-]*' \
      "$TREE/frameworks" "$TREE/system" "$TREE/hardware" --exclude-dir=sepolicy 2>/dev/null \
      | sed 's|^"/sys/kernel/||'
    grep -haoE '^genfscon sysfs /kernel/[A-Za-z0-9_./-]+' \
      "$TREE/system/sepolicy/private/genfs_contexts" 2>/dev/null \
      | sed 's|^genfscon sysfs /kernel/||'
  } | cut -d/ -f1 | sed 's/[^A-Za-z0-9_.-].*//' | grep -v '^$' | sort -u
}

TMP=$(mktemp) || exit 1
trap 'rm -f "$TMP"' EXIT
{ echo "$HEADER"; scan; } > "$TMP"
[[ $(grep -cv '^#' "$TMP") -ge 8 ]] || {
  echo "scan-sys-kernel-readers.sh: scan found $(grep -cv '^#' "$TMP") names -- refusing" >&2
  exit 1; }

if (( SELFTEST )); then
  for want in wakeup_reasons btf debug tracing; do
    grep -qx "$want" "$TMP" || {
      echo "scan-sys-kernel-readers.sh --selftest: the scan lost $want" >&2; exit 1; }
  done
  LIST=$(mktemp) BROKEN=$(mktemp) || exit 1
  trap 'rm -f "$TMP" "$LIST" "$BROKEN"' EXIT
  "$HERE/scan-sys-kernel-readers.sh" --tree "$TREE" --list "$LIST" >/dev/null || {
    echo "scan-sys-kernel-readers.sh --selftest: writing a list failed" >&2; exit 1; }
  "$HERE/scan-sys-kernel-readers.sh" --tree "$TREE" --check --list "$LIST" >/dev/null 2>&1 || {
    echo "scan-sys-kernel-readers.sh --selftest: a list just written failed --check" >&2; exit 1; }
  grep -v '^btf$' "$LIST" > "$BROKEN"
  if "$HERE/scan-sys-kernel-readers.sh" --tree "$TREE" --check --list "$BROKEN" >/dev/null 2>&1; then
    echo "scan-sys-kernel-readers.sh --selftest: a list missing a scanned name passed" >&2
    exit 1
  fi
  if [[ "$(printf 'dma_heap\ndmabuf\n' | LC_ALL=en_US.UTF-8 sort 2>/dev/null | head -1)" == dmabuf ]]; then
    LC_ALL=en_US.UTF-8 "$HERE/scan-sys-kernel-readers.sh" --tree "$TREE" --check --list "$LIST" >/dev/null 2>&1 || {
      echo "scan-sys-kernel-readers.sh --selftest: --check fails under LC_ALL=en_US.UTF-8" >&2; exit 1; }
  else
    echo "scan-sys-kernel-readers.sh --selftest: no en_US.UTF-8 collation here, so the caller-locale case is not exercised"
  fi
  echo "scan-sys-kernel-readers.sh: selftest ok"
  exit 0
fi

if (( CHECK )); then
  if diff -u "$OUT" "$TMP" >/dev/null 2>&1; then
    echo "scan-sys-kernel-readers.sh: $(basename "$OUT") matches a new scan"
    exit 0
  fi
  echo "scan-sys-kernel-readers.sh: $OUT is out of date -- rerun without --check" >&2
  diff -u "$OUT" "$TMP" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUT")"
cp --remove-destination "$TMP" "$OUT" && chmod 0644 "$OUT"
echo "scan-sys-kernel-readers.sh: wrote $(grep -cv '^#' "$OUT") names to $OUT"
