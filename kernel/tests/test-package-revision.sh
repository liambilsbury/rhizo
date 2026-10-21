#!/bin/bash
# check the package revision of build.sh and the PKGBUILD
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); tmp=$(mktemp -d); trap 'rm -r "$tmp"' EXIT
root=$(cd "$here/../.." && pwd)
failed=0
# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; failed=1; fi
}

check "the revision is what VERSION holds" "$("$root/kernel/packaging/build.sh" --pkgrel 2>&1)" "$(< "$root/kernel/VERSION")"
check "the revision is above 38, the last commit-counted revision" "$(( $(< "$root/kernel/VERSION") > 38 ))" 1

mkdir -p "$tmp/r/kernel/packaging"; cp "$root/kernel/packaging/build.sh" "$tmp/r/kernel/packaging/"
for v in 41 7; do
  echo "$v" > "$tmp/r/kernel/VERSION"
  check "VERSION $v gives revision $v" "$("$tmp/r/kernel/packaging/build.sh" --pkgrel 2>&1)" "$v"
done
for bad in 0 -3 abc 07 "" "5 "; do
  printf '%s\n' "$bad" > "$tmp/r/kernel/VERSION"
  out=$("$tmp/r/kernel/packaging/build.sh" --pkgrel 2>&1); rc=$?
  check "VERSION '$bad': refused, named" "$rc|$out" "1|build.sh: $tmp/r/kernel/VERSION holds '$bad', not a positive integer"
done
rm "$tmp/r/kernel/VERSION"
out=$("$tmp/r/kernel/packaging/build.sh" --pkgrel 2>&1); rc=$?
check "no VERSION: refused" "$rc" 1

mkdir -p "$tmp/tree/scripts/package"
# shellcheck disable=SC2016
printf 'pkgbase=${PACMAN_PKGBASE:-linux-upstream}\npkgver="${KERNELRELEASE//-/_}"\npkgrel="${KBUILD_REVISION}"\n' \
  > "$tmp/tree/scripts/package/PKGBUILD"
out=$("$root/kernel/packaging/build.sh" --pin-pacman-pkgrel "$tmp/tree" 2>&1); rc=$?
# shellcheck disable=SC2016
check "the kernel's PKGBUILD takes pkgrel from RHIZO_PKGREL" "$rc|$out|$(sed -n '/^pkgrel=/p' \
  "$tmp/tree/scripts/package/PKGBUILD")" '0||pkgrel="${RHIZO_PKGREL}"'
printf 'pkgrel=1\n' > "$tmp/tree/scripts/package/PKGBUILD"
out=$("$root/kernel/packaging/build.sh" --pin-pacman-pkgrel "$tmp/tree" 2>&1); rc=$?
check "a PKGBUILD that sets pkgrel another way: refused, named, untouched" \
  "$rc|$out|$(< "$tmp/tree/scripts/package/PKGBUILD")" \
  "1|build.sh: $tmp/tree/scripts/package/PKGBUILD sets pkgrel another way than from KBUILD_REVISION|pkgrel=1"

(( failed )) && { echo "FAIL"; exit 1; }
echo PASS
