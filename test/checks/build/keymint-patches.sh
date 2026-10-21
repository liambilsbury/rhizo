#!/bin/bash
# test that tools/build/hal/keymint.sh applies all of the keymint patches
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
KEYMINT="$REPO/tools/build/hal/keymint.sh"
MANIFEST="$REPO/tools/build/artifacts.tsv"
HAT=auth-token-verify.patch
OLD_LIST=(unwrap-digest.patch eek-curve.patch
          aes-blob-encrypt.patch)
fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bad() { echo "FAIL $*"; fail=1; }

# write a patch that changes an aosp file
write_patch() {
  printf 'fixture header\n=====\n--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-before\n+after\n' "$2" "$2" > "$1"
}

# build a fixture checkout holding keymint.sh and patches
make_tree() {
  local dir="$1" script="$2" name
  shift 2
  mkdir -p "$dir/tools/build/hal" "$dir/tools/patches/keymint" "$dir/aosp-android16-qpr2/f"
  cp "$script" "$dir/tools/build/hal/keymint.sh"
  for name in "$@"; do
    echo before > "$dir/aosp-android16-qpr2/f/$name.txt"
    write_patch "$dir/tools/patches/keymint/$name" "f/$name.txt"
  done
}

# run a fixture checkout's keymint.sh with arguments
run_keymint() {
  local dir="$1"
  shift
  OUT=$("$dir/tools/build/hal/keymint.sh" "$@" 2>&1)
  RC=$?
}

# run keymint.sh --patch-only in a fixture checkout
run_patch_only() {
  run_keymint "$1" --patch-only
}

# print the patch names keymint.sh left unapplied
unapplied() {
  local script="$1" dir="$2" name
  shift 2
  make_tree "$dir" "$script" "$@"
  run_patch_only "$dir"
  (( RC == 0 )) || { echo "keymint.sh --patch-only exited $RC: $OUT"; return 1; }
  for name in "$@"; do
    [[ "$(cat "$dir/aosp-android16-qpr2/f/$name.txt")" == after ]] || echo "$name"
  done
}

# print the patch names the keymint stamp row omits
unhashed() {
  local manifest="$1" sources name
  shift
  sources=$(awk -F'\t' '$1 == "rhizo-keymint-service" {print $3}' "$manifest")
  [[ -n "$sources" ]] || { echo "no rhizo-keymint-service row in $manifest"; return 1; }
  for name in "$@"; do
    [[ " $sources " == *" tools/patches/keymint/$name "* ]] || echo "$name"
  done
}

# check the real keymint.sh against the real patch names
real_run() {
  local patches=("$REPO"/tools/patches/keymint/*.patch) names=() pf missed
  [[ -f "${patches[0]}" ]] || { bad "no tools/patches/keymint/*.patch in $REPO"; return; }
  for pf in "${patches[@]}"; do names+=("$(basename "$pf")"); done
  missed=$(unapplied "$KEYMINT" "$tmp/real" "${names[@]}") || { bad "$missed"; return; }
  [[ -z "$missed" ]] || bad "keymint.sh does not apply: $(echo "$missed" | tr '\n' ' ')"
  missed=$(unhashed "$MANIFEST" "${names[@]}") || { bad "$missed"; return; }
  [[ -z "$missed" ]] || bad "the rhizo-keymint-service row of artifacts.tsv does not hash: $(echo "$missed" | tr '\n' ' ')"
  (( fail == 0 )) && echo "keymint-patches: keymint.sh applies and the stamp hashes all ${#names[@]} keymint patches"
}

# check each finding on fixtures both ways
selftest() {
  local mutant="$tmp/keymint-old-list.sh" missed list
  missed=$(unapplied "$KEYMINT" "$tmp/good" a.patch b.patch) || bad "$missed"
  [[ -z "$missed" ]] || bad "keymint.sh left a fixture patch unapplied: $missed"

  list=$(printf '%s,' "${OLD_LIST[@]}")
  sed "s|tools/patches/keymint/\*\.patch) pf|tools/patches/keymint/{${list%,}}) pf|" "$KEYMINT" > "$mutant"
  chmod +x "$mutant"
  cmp -s "$mutant" "$KEYMINT" && bad "could not build the hard-coded-list mutant of keymint.sh"
  missed=$(unapplied "$mutant" "$tmp/old" "${OLD_LIST[@]}" "$HAT") || bad "$missed"
  [[ "$missed" == "$HAT" ]] || bad "the hard-coded-list keymint.sh was not flagged for $HAT alone: '$missed'"

  run_patch_only "$tmp/good"
  [[ $RC == 0 && "$OUT" == *"a.patch already applied"* && "$OUT" == *"b.patch already applied"* ]] \
    || bad "a second run on applied patches did not report each as already applied: rc=$RC $OUT"

  make_tree "$tmp/conflict" "$KEYMINT" a.patch c.patch
  echo other > "$tmp/conflict/aosp-android16-qpr2/f/c.patch.txt"
  run_patch_only "$tmp/conflict"
  [[ $RC != 0 && "$OUT" == *"c.patch conflicts"* ]] || bad "a conflicting patch was not refused by name: rc=$RC $OUT"

  make_tree "$tmp/none" "$KEYMINT"
  run_patch_only "$tmp/none"
  [[ $RC != 0 && "$OUT" == *"no tools/patches/keymint/*.patch"* ]] || bad "an empty patch directory was not refused: rc=$RC $OUT"

  make_tree "$tmp/empty" "$KEYMINT" a.patch
  echo "a header and no diff" > "$tmp/empty/tools/patches/keymint/d.patch"
  run_patch_only "$tmp/empty"
  [[ $RC != 0 && "$OUT" == *"d.patch carries no"* ]] || bad "a patch with no diff was not refused by name: rc=$RC $OUT"

  make_tree "$tmp/typo" "$KEYMINT" a.patch
  run_keymint "$tmp/typo" --patch-onlyy
  [[ $RC == 2 && "$OUT" == *"unknown argument: --patch-onlyy"* && "$OUT" == *"usage:"* ]] \
    || bad "an unknown argument was not refused with exit 2 and the usage: rc=$RC $OUT"
  [[ "$(cat "$tmp/typo/aosp-android16-qpr2/f/a.patch.txt")" == before ]] \
    || bad "keymint.sh applied a patch before refusing an unknown argument"
  run_keymint "$tmp/typo" -h
  [[ $RC == 0 && "$OUT" == *--rebuild* && "$OUT" == *--patch-only* && "$OUT" == *--arch=aarch64* ]] \
    || bad "-h did not print a usage naming --rebuild, --patch-only and --arch=aarch64: rc=$RC $OUT"

  printf 'rhizo-keymint-service\tbuild\ttools/patches/keymint/a.patch tools/build/hal/keymint.sh\tpayload\t-\n' > "$tmp/artifacts.tsv"
  missed=$(unhashed "$tmp/artifacts.tsv" a.patch b.patch) || bad "$missed"
  [[ "$missed" == b.patch ]] || bad "a stamp row missing b.patch was not flagged for it alone: '$missed'"
  missed=$(unhashed "$tmp/artifacts.tsv" a.patch) || bad "$missed"
  [[ -z "$missed" ]] || bad "a stamp row hashing every patch was flagged: '$missed'"
  (( fail == 0 )) && echo "keymint-patches selftest: ok"
}

case "${1:-}" in
  --selftest) selftest ;;
  "") real_run ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac
exit "$fail"
