#!/bin/bash
# test sync.sh drops a vm's leftover whole-set files
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "${1:-}" == --selftest ]] || { echo "usage: $0 --selftest" >&2; exit 2; }
SYNC="$HERE/../vm/sync.sh"
FAILED=0 CASES=0
# compare $2 with $3
check() {
  CASES=$((CASES + 1))
  [[ "$2" == "$3" ]] && return 0
  echo "got '$2' want '$3' for: $1"; FAILED=1
}
# search $3 for $2
has() {
  CASES=$((CASES + 1))
  [[ "$3" == *"$2"* ]] && return 0
  echo "'$3' does not contain '$2' for: $1"; FAILED=1
}
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# print function $2 from file $1
extract() {
  sed -n "/^$2() {/,/^}/p" "$1"
}

# write the sync.sh functions to fns.sh
write_fns() {
  { echo "$1"
    for f in tree_listing vm_differs vm_extras stray_temps mirror_vm verify_vm; do extract "$SYNC" "$f"; done
  } > "$WORK/fns.sh"
}

# build the share and share-1 fixture trees
fixture() {
  rm -rf "$WORK/fx"
  mkdir -p "$WORK/fx/var/share/arch-pool" "$WORK/fx/var/share/other-pool" "$WORK/fx/var/share-1/arch-pool" "$WORK/fx/var/share-1/other-pool" \
    "$WORK/fx/var/share/arch-pkgs" "$WORK/fx/var/share-1/arch-pkgs"
  echo new > "$WORK/fx/var/share/arch-pool/new-2-1-any.pkg.tar.zst"
  echo new > "$WORK/fx/var/share/arch-pkgs/rhizo-0.1.5-1-any.pkg.tar.zst"
  echo old > "$WORK/fx/var/share-1/arch-pkgs/rhizo-0.1.4-1-any.pkg.tar.zst"
  echo kept > "$WORK/fx/var/share/other-pool/kept"
  echo old > "$WORK/fx/var/share-1/arch-pool/old-1-1-any.pkg.tar.zst"
  echo vm > "$WORK/fx/var/share-1/other-pool/vm-only"
}

# run the sync.sh vm step in the fixture
vm_step() {
  (cd "$WORK/fx" && bash -c '
    set -uo pipefail; CHECK=0
    sync_one() { cp -p "$1" "$2"; }
    source "'"$WORK/fns.sh"'"
    verify_vm var/share-1/ 2>&1; echo "before=$?"
    mirror_vm var/share-1/ 2>&1
    verify_vm var/share-1/ 2>&1; echo "after=$?"')
}

WHOLE_SET_LINE=$(grep '^WHOLE_SET_DIRS=' "$SYNC")
check "sync.sh has one WHOLE_SET_DIRS line" "$(grep -c '^WHOLE_SET_DIRS=' "$SYNC")" 1
check "sync.sh lists arch-pool as a whole-set directory" "$(grep -cw arch-pool <<<"$WHOLE_SET_LINE")" 1
check "sync.sh lists arch-pkgs as a whole-set directory" "$(grep -cw arch-pkgs <<<"$WHOLE_SET_LINE")" 1

write_fns "$WHOLE_SET_LINE"
fixture
out=$(vm_step)
has "a vm's stray package fails the check before the mirror" "before=1" "$out"
has "the failing check names the stray and says why" "var/share-1/arch-pool/old-1-1-any.pkg.tar.zst is not in var/share/, and its directory is checked as a whole set" "$out"
has "the check passes after the mirror" "after=0" "$out"
check "the mirror removes the stray package from arch-pool" "$(ls "$WORK/fx/var/share-1/arch-pool")" "new-2-1-any.pkg.tar.zst"
check "the mirror names the file it removed" "$(grep -c 'removed arch-pool/old-1-1-any.pkg.tar.zst' <<<"$out")" 1
check "the mirror keeps a vm-only file in a directory that is not a whole set" "$(cat "$WORK/fx/var/share-1/other-pool/vm-only")" "vm"
check "the mirror removes an older package from arch-pkgs" "$(ls "$WORK/fx/var/share-1/arch-pkgs")" "rhizo-0.1.5-1-any.pkg.tar.zst"

write_fns "WHOLE_SET_DIRS=(runtime-debs)"
fixture
out=$(vm_step)
check "without arch-pool in the line the stray stays in the vm" "$(LC_ALL=C ls "$WORK/fx/var/share-1/arch-pool" | tr '\n' ' ')" "new-2-1-any.pkg.tar.zst old-1-1-any.pkg.tar.zst "
check "without arch-pkgs in the line the older package stays in the vm" "$(LC_ALL=C ls "$WORK/fx/var/share-1/arch-pkgs" | tr '\n' ' ')" "rhizo-0.1.4-1-any.pkg.tar.zst rhizo-0.1.5-1-any.pkg.tar.zst "

(( FAILED )) && exit 1
echo "sync.sh whole-set directories passed $CASES cases"
