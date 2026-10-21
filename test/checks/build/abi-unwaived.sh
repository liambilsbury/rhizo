#!/bin/bash
# test the abi_unwaived bypass and its marker
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "check-abi-unwaived: $*" >&2; exit 1; }

if [[ "${1:-}" != "--selftest" ]]; then
  bash -n "$HERE/../../tools/build/release.sh" || fail "release.sh does not parse"
  grep -q -- '--allow-unwaived' "$HERE/../../tools/build/release.sh" \
    || fail "lost the --allow-unwaived flag"
  grep -q -- '--allow-unwaived' "$HERE/../vm/boot-release.sh" \
    || fail "boot-release.sh no longer forwards --allow-unwaived"
  echo "check-abi-unwaived: flag, marker and forwarding all present"
  exit 0
fi

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/tools/build" "$SCRATCH/test/vm/image" "$SCRATCH/test/vm/rig" "$SCRATCH/var/share"
cp "$HERE/../vm/common.sh" "$SCRATCH/test/vm/"
cp "$HERE/../vm/rig/hooks.sh" "$SCRATCH/test/vm/rig/"
cp "$HERE/../vm/image/release-map.sh" "$SCRATCH/test/vm/image/"
cp "$HERE/../../tools/build/release.sh" "$SCRATCH/tools/build/"
git -C "$SCRATCH" init -q
git -C "$SCRATCH" -c user.name=t -c user.email=t@t add -A
git -C "$SCRATCH" -c user.name=t -c user.email=t@t commit -q -m scratch

assertions=0

# shellcheck disable=SC2034
RHIZO_VM=0
export RHIZO_ABI_UNWAIVED_MARKER_DIR="$SCRATCH/marker"
mkdir -p "$RHIZO_ABI_UNWAIVED_MARKER_DIR"
(
  cd "$SCRATCH/tools/build" || exit 1
  source ../../test/vm/common.sh
  source ./release.sh

  if abi_unwaived_test a17 "libkeymint.so: needs android.hardware.security.keymint-V4-ndk.so" 0; then
    echo "FAIL: abi_unwaived_test accepted an unwaived gap with allow=0" >&2; exit 1
  fi
  [[ -f "$(abi_unwaived_marker_path a17)" ]] && { echo "FAIL: marker written without allow=1" >&2; exit 1; }

  abi_unwaived_test a17 "libkeymint.so: needs android.hardware.security.keymint-V4-ndk.so" 1 \
    || { echo "FAIL: abi_unwaived_test refused with allow=1" >&2; exit 1; }
  m="$(abi_unwaived_marker_path a17)"
  [[ -f "$m" ]] || { echo "FAIL: no marker written with allow=1" >&2; exit 1; }
  grep -q 'libkeymint.so' "$m" || { echo "FAIL: marker does not name the gap it bypassed" >&2; exit 1; }
  grep -q '^release=a17' "$m" || { echo "FAIL: marker does not name its release" >&2; exit 1; }

  abi_unwaived_test a17 "" 1 || { echo "FAIL: abi_unwaived_test refused a clean check" >&2; exit 1; }
  [[ -f "$m" ]] && { echo "FAIL: a clean re-check left an old unwaived marker behind" >&2; exit 1; }

  abi_check a16 || { echo "FAIL: abi_check a16 (the baseline) must always pass" >&2; exit 1; }
) || fail "abi_unwaived_test scenarios failed"
assertions=$((assertions + 4))

echo "check-abi-unwaived selftest: $assertions assertions passed, the bypass refuses without allow, leaves a marker naming its gap with it, and a clean re-check clears it"
