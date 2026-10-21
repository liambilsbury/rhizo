#!/bin/bash
# run checkpatch on the kernel patches
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
cache=${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}
base=$(sed -n 's/^base_tag=//p' "$root/kernel/SOURCE")
git -C "$cache/linux" cat-file -e "$base:scripts/checkpatch.pl" 2>/dev/null \
  || { echo "SKIP checkpatch-patches.sh: no $base tree in $cache/linux (run make kernel-inputs)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -r "$tmp"' EXIT
for f in checkpatch.pl spelling.txt const_structs.checkpatch; do
  git -C "$cache/linux" show "$base:scripts/$f" > "$tmp/$f" || exit 1
done
failed=0
for p in "$root"/kernel/patches/*.patch; do
  out=$(perl "$tmp/checkpatch.pl" --no-tree -q --ignore COMMIT_LOG_LONG_LINE,UNKNOWN_COMMIT_ID,MISSING_SIGN_OFF,COMMIT_MESSAGE,FILE_PATH_CHANGES - < "$p" 2>&1) \
    || { echo "${p#"$root"/}"; echo "$out"; failed=1; }
done
(( failed == 0 )) && echo "checkpatch-patches.sh: $(ls "$root"/kernel/patches/*.patch | wc -l) patches clean"
exit "$failed"
