#!/bin/bash
# check stage_to_share on an unchanged file
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

fn=$(sed -n '/^stage_to_share() {/,/^}/p' ../vm/common.sh)
[[ -n "$fn" ]] || { echo "FAIL: common.sh defines no stage_to_share"; exit 1; }
eval "$fn"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/share" "$work/src"
printf 'key-one\n' > "$work/src/adbkey.pub"
cp --remove-destination "$work/src/adbkey.pub" "$work/share/adbkey.pub"
cp -al "$work/share" "$work/share-1"

problems=()

if (( SELFTEST )); then
  cp --remove-destination "$work/src/adbkey.pub" "$work/share-1/adbkey.pub"
else
  stage_to_share "$work/src/adbkey.pub" "$work/share-1/adbkey.pub" || problems+=("stage_to_share failed on an identical file")
fi
[[ "$work/share/adbkey.pub" -ef "$work/share-1/adbkey.pub" ]] \
  || problems+=("restaging an unchanged file broke share-1's hardlink to share/")

printf 'key-two\n' > "$work/src/adbkey.pub"
stage_to_share "$work/src/adbkey.pub" "$work/share-1/adbkey.pub" || problems+=("stage_to_share failed on a changed file")
cmp -s "$work/src/adbkey.pub" "$work/share-1/adbkey.pub" \
  || problems+=("a changed file was not staged")
cmp -s "$work/share/adbkey.pub" <(printf 'key-one\n') \
  || problems+=("staging a changed file into share-1 wrote through to share/")

if (( SELFTEST )); then
  if [[ "${problems[*]:-}" == *"broke share-1's hardlink"* ]]; then
    echo "check-stage-to-share: selftest ok -- an unguarded copy is caught breaking the vm's hardlink"
    exit 0
  fi
  echo "FAIL: an unguarded cp --remove-destination kept the hardlink"
  exit 1
fi
if (( ${#problems[@]} )); then
  for p in "${problems[@]}"; do echo "FAIL: $p"; done
  exit 1
fi
echo "check-stage-to-share: an unchanged restage keeps the vm's hardlink, and a changed file still lands"
