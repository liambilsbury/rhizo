#!/bin/bash
# derive a GSI tree's libraries and stock patches on the guest
set -uo pipefail
TREE="${1:-}"
TREE="${TREE%/}"
[[ "$TREE" == /* ]] || { echo "usage: bash -s -- ABSOLUTE_TREE_PATH" >&2; exit 2; }
BASE="${TREE##*/}"
DERIVED="${RHIZO_DERIVED_DIR:-/var/lib/rhizo/derived}"
FETCH="${RHIZO_FETCH_GSI:-/usr/lib/rhizo/install/prepare/fetch-gsi.sh}"
LAUNCHER_DIR="${RHIZO_LAUNCHER_DIR:-/root}"

# print the failure and exit
die() { echo "RHIZO_TREE_DERIVE_FAILED $*"; exit 1; }

[[ -s "$TREE/bin/init" ]] || die "no staged tree at $TREE"
mkdir -p "$DERIVED" || die "cannot create $DERIVED"
WORK=$(mktemp -d "$DERIVED/.derive-tree.XXXXXX") || die "cannot create a work directory in $DERIVED"
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/root" || die "cannot create $WORK/root"
ln -s "$TREE" "$WORK/root/gsi_system" || die "cannot link $TREE into $WORK/root"
out=$(RHIZO_GSI_ROOT="$WORK/root" RHIZO_DERIVED_DIR="$WORK/derived" bash "$FETCH" --release a16 --derive-only </dev/null 2>&1)
case "${out##*$'\n'}" in
  RHIZO_GSI_DERIVED*) ;;
  *) die "$FETCH --derive-only on $TREE: $(tail -3 <<<"$out" | tr '\n' ' ')" ;;
esac

for kind in gsi_libs patches; do
  mkdir -p "$DERIVED/$kind" || die "cannot create $DERIVED/$kind"
  if [[ -e "$DERIVED/$kind/$BASE" ]]; then
    mv "$DERIVED/$kind/$BASE" "$WORK/replaced-$kind" || die "cannot move $DERIVED/$kind/$BASE aside"
  fi
  mv "$WORK/derived/$kind/gsi_system" "$DERIVED/$kind/$BASE" || die "cannot move the derived $kind to $DERIVED/$kind/$BASE"
done

CHECK=$(cat <<'PYEOF'
import sys
from sandbox import core

libs, patches = sys.argv[1:3]
bad = []
if core.gsi_libs_dir() != libs:
    bad.append(f"the launcher reads libraries from {core.gsi_libs_dir()}")
if core.stock_patches_dir() != patches:
    bad.append(f"the launcher reads stock patches from {core.stock_patches_dir()}")
if core.gsi_derived_missing():
    bad.append("the libraries lack " + " ".join(core.gsi_derived_missing()))
if core.gsi_derived_mismatch():
    bad.append(core.gsi_derived_mismatch())
if bad:
    print("; ".join(bad))
    sys.exit(1)
PYEOF
)
seen=$(cd "$LAUNCHER_DIR" && RHIZO_GSI="$TREE" RHIZO_DERIVED_DIR="$DERIVED" python3 -c "$CHECK" "$DERIVED/gsi_libs/$BASE" "$DERIVED/patches/$BASE" </dev/null 2>&1) \
  || die "after the derive, $seen"
echo "RHIZO_TREE_DERIVED tree=$TREE libs=$DERIVED/gsi_libs/$BASE patches=$DERIVED/patches/$BASE"
