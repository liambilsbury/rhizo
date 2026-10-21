#!/bin/bash
# check rhizo-kernel-vm.sh's copy_source
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fn=$(sed -n '/^copy_source() {/,/^}/p' "$ROOT/test/vm/rhizo-kernel-vm.sh")
[ -n "$fn" ] || { echo "FAIL: copy_source not found in rhizo-kernel-vm.sh"; exit 1; }
head -c 65536 /dev/urandom > "$T/src.img"
out=$(bash -c "die() { echo \"die: \$*\"; exit 9; }; $fn; copy_source $T/src.img $T/dst.img; copy_source $T/src.img $T/dst.img"); rc=$?
[ "$rc" = 0 ] || { echo "FAIL: copy_source exited $rc: $out"; exit 1; }
[[ "$out" == "made $T/dst.img from $T/src.img"$'\n'"kept $T/dst.img" ]] || { echo "FAIL: copy_source printed '$out'"; exit 1; }
cmp -s "$T/src.img" "$T/dst.img" || { echo "FAIL: the copy differs from the source"; exit 1; }
[ "$(stat -c %a "$T/dst.img")" = 444 ] || { echo "FAIL: the copy's mode is $(stat -c %a "$T/dst.img"), not 444"; exit 1; }
[ ! -e "$T/dst.img.new" ] || { echo "FAIL: the .new file was left behind"; exit 1; }
echo "PASS: copy_source made a read-only byte-identical copy on $(stat -f -c %T "$T") and kept it on the second call"
