#!/bin/bash
# var/share/sys-kernel-readers.txt
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
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

[[ -d "$TREE/frameworks" && -d "$TREE/system" && -d "$TREE/hardware" ]] || {
  echo "no frameworks, system and hardware in $TREE" >&2
  exit 1; }

HEADER="# /sys/kernel children in \"/sys/kernel/ literals of aosp-android16-qpr2 frameworks, system and hardware without sepolicy, and in genfscon sysfs /kernel of plat sepolicy, from tools/build/image/scan-sys-kernel-readers.sh, Apache-2.0-derived data"

# print the top-level /sys/kernel children in the source tree
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
  echo "scan printed $(grep -cv '^#' "$TMP") entries, expected 8 or more" >&2
  exit 1; }

if (( SELFTEST )); then
  for want in wakeup_reasons btf debug tracing; do
    grep -qx "$want" "$TMP" || {
      echo "FAIL scan has $want" >&2; exit 1; }
  done
  LIST=$(mktemp) BROKEN=$(mktemp) || exit 1
  trap 'rm -f "$TMP" "$LIST" "$BROKEN"' EXIT
  "$HERE/scan-sys-kernel-readers.sh" --tree "$TREE" --list "$LIST" >/dev/null || {
    echo "FAIL scan-sys-kernel-readers.sh --list exits 0" >&2; exit 1; }
  "$HERE/scan-sys-kernel-readers.sh" --tree "$TREE" --check --list "$LIST" >/dev/null 2>&1 || {
    echo "FAIL --check on a written list exits 0" >&2; exit 1; }
  grep -v '^btf$' "$LIST" > "$BROKEN"
  if "$HERE/scan-sys-kernel-readers.sh" --tree "$TREE" --check --list "$BROKEN" >/dev/null 2>&1; then
    echo "FAIL --check on a list without btf exits 1" >&2
    exit 1
  fi
  if [[ "$(printf 'dma_heap\ndmabuf\n' | LC_ALL=en_US.UTF-8 sort 2>/dev/null | head -1)" == dmabuf ]]; then
    LC_ALL=en_US.UTF-8 "$HERE/scan-sys-kernel-readers.sh" --tree "$TREE" --check --list "$LIST" >/dev/null 2>&1 || {
      echo "FAIL --check with LC_ALL=en_US.UTF-8 exits 0" >&2; exit 1; }
  else
    echo "SKIP --check with LC_ALL=en_US.UTF-8 without en_US.UTF-8 collation"
  fi
  echo "ok scan-sys-kernel-readers.sh --selftest"
  exit 0
fi

if (( CHECK )); then
  if diff -u "$OUT" "$TMP" >/dev/null 2>&1; then
    echo "$(basename "$OUT") matches scan"
    exit 0
  fi
  echo "$OUT differs from scan" >&2
  diff -u "$OUT" "$TMP" >&2
  exit 1
fi
mkdir -p "$(dirname "$OUT")"
cp --remove-destination "$TMP" "$OUT" && chmod 0644 "$OUT"
echo "wrote $(grep -cv '^#' "$OUT") entries to $OUT"
