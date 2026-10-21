#!/bin/bash
# build the pacman packages on the cachyos vm
set -euo pipefail
export LC_ALL=C
TOOLS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TOOLS/../../../.." && pwd)
OUT="$ROOT/var/share/arch-pkgs"
PACKAGER='Liam Bilsbury <liam.bilsbury@proton.me>'

# print an error and exit 1
die() { echo "build-arch-pkgs: $*" >&2; exit 1; }

# print a sha256 over the archlinux files
packaging_digest() {
  (cd "$ROOT" && find archlinux -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

# diff package and payload entry lists
package_list_diff() {
  diff <(tar --zstd -tf "$1" | grep -vx -e '\.BUILDINFO' -e '\.MTREE' -e '\.PKGINFO' -e '\.INSTALL' | sort) \
       <(tar --zstd -tf "$2" | sed -n 's|^payload/\(..*\)|\1|p' | sort)
}

# test package_list_diff on fixture tarballs
selftest() {
  local t rc=0 out
  t=$(mktemp -d)
  mkdir -p "$t/payload/usr/bin" "$t/payload/usr/share/man/man1" "$t/pkg"
  : > "$t/payload/usr/bin/x"; : > "$t/payload/usr/share/man/man1/x.1"
  tar --zstd -C "$t" -cf "$t/payload.tar.zst" payload
  for f in .BUILDINFO .MTREE .PKGINFO .INSTALL; do : > "$t/pkg/$f"; done
  cp -a "$t/payload/." "$t/pkg/"
  (cd "$t/pkg" && tar --zstd -cf "$t/same.pkg.tar.zst" .BUILDINFO .MTREE .PKGINFO .INSTALL usr)
  mv "$t/pkg/usr/share/man/man1/x.1" "$t/pkg/usr/share/man/man1/x.1.gz"
  (cd "$t/pkg" && tar --zstd -cf "$t/zipman.pkg.tar.zst" .BUILDINFO .MTREE .PKGINFO .INSTALL usr)
  rm "$t/pkg/usr/bin/x"
  (cd "$t/pkg" && tar --zstd -cf "$t/stripped.pkg.tar.zst" .BUILDINFO .MTREE .PKGINFO .INSTALL usr)
  if ! out=$(package_list_diff "$t/same.pkg.tar.zst" "$t/payload.tar.zst"); then
    echo "FAIL a package of the payload's own entries differs: $out"; rc=1
  fi
  if out=$(package_list_diff "$t/zipman.pkg.tar.zst" "$t/payload.tar.zst") || [[ "$out" != *"x.1.gz"* ]]; then
    echo "FAIL a man page makepkg compressed is not named: ${out:-no difference}"; rc=1
  fi
  if out=$(package_list_diff "$t/stripped.pkg.tar.zst" "$t/payload.tar.zst") || [[ "$out" != *"> usr/bin/x"* ]]; then
    echo "FAIL a file makepkg removed is not named: ${out:-no difference}"; rc=1
  fi
  rm -rf "$t"
  (( rc == 0 )) && echo "build-arch-pkgs selftest: ok (3 cases)"
  return "$rc"
}

pkgrel=1
while (( $# )); do
  case "$1" in
    --pkgrel) pkgrel="${2:-}"; shift 2 || { echo "--pkgrel takes a number" >&2; exit 2; } ;;
    --selftest) selftest; exit ;;
    --packaging-digest) packaging_digest; exit ;;
    *) echo "usage: tools/build/packaging/arch/arch-pkgs.sh [--pkgrel N] | --selftest" >&2; exit 2 ;;
  esac
done
[[ "$pkgrel" =~ ^[1-9][0-9]*$ ]] || die "--pkgrel '$pkgrel' is not a release number"
(( pkgrel == 1 )) || OUT="$OUT-rel$pkgrel"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

if ! python3 "$TOOLS/../../stamps.py" deb-require > "$scratch/deb-require.log" 2>&1; then
  echo "build-arch-pkgs: $(tail -1 "$scratch/deb-require.log"), so debs.sh rebuilds it"
  "$TOOLS/../deb/debs.sh"
  python3 "$TOOLS/../../stamps.py" deb-require || die "the rebuilt .deb is not this tree's"
fi
shopt -s nullglob
debs=("$ROOT"/var/debs/rhizo_*_amd64.deb)
(( ${#debs[@]} == 1 )) || die "var/debs holds ${#debs[@]} rhizo_*_amd64.deb, not one"
"$TOOLS/arch-payload.sh" "${debs[0]}" "$scratch/build/rhizo" >/dev/null

for d in "$scratch"/build/*/; do
  grep -q '^pkgrel=' "$d/PKGBUILD" || die "$d/PKGBUILD names no pkgrel= line to set"
  sed -i "s/^pkgrel=.*/pkgrel=$pkgrel/" "$d/PKGBUILD"
done

want=()
for d in "$scratch"/build/*/; do
  # shellcheck disable=SC1091,SC2154
  want+=("$(source "$d/PKGBUILD" && echo "$pkgname-$pkgver-$pkgrel-${arch[0]}.pkg.tar.zst")")
done

# shellcheck source=../../../../test/vm/rig/hooks.sh
source "$ROOT/test/vm/rig/hooks.sh" || exit 2
vm=$(rig_current_vm)
[[ "$vm" =~ ^[0-9]+$ ]] || die "no vm to install on (${vm:-none}): set RHIZO_VM to a running cachyos vm"
export RHIZO_VM="$vm" RHIZO_GUEST_OS=cachyos
# shellcheck source=../../../../test/vm/common.sh
source "$ROOT/test/vm/common.sh"
id=$(ssh_vm "sed -n 's/^ID=//p' /etc/os-release") || die "vm $vm's guest does not answer ssh"
[[ "$id" == cachyos ]] || die "vm $vm's guest is ${id:-unnamed}, not cachyos"

cp "$TOOLS/run-makepkg.sh" "$scratch/build/run-makepkg.sh"
rm -rf "$SHARE_DIR/arch-build"
cp -r --remove-destination "$scratch/build" "$SHARE_DIR/arch-build"
t0=$EPOCHSECONDS
ssh_vm -t 900 "bash /root/share/arch-build/run-makepkg.sh '$PACKAGER'" || die "makepkg on vm $vm failed (output above)"
echo "build-arch-pkgs: makepkg on vm $vm took $(( EPOCHSECONDS - t0 ))s"

got=$(cd "$SHARE_DIR/arch-build/out" && printf '%s\n' *.pkg.tar.zst | sort)
expected=$(printf '%s\n' "${want[@]}" | sort)
[[ "$got" == "$expected" ]] || die "makepkg wrote [${got//$'\n'/ }], expected [${expected//$'\n'/ }]"
i=0
for d in "$scratch"/build/*/; do
  payloads=("$d"*-payload-*.tar.zst)
  if (( ${#payloads[@]} )); then
    diffs=$(package_list_diff "$SHARE_DIR/arch-build/out/${want[i]}" "${payloads[0]}") \
      || die "${want[i]} does not hold exactly ${payloads[0]##*/}'s entries:"$'\n'"$diffs"
    n=$(tar --zstd -tf "${payloads[0]}" | grep -c '^payload/.')
    echo "build-arch-pkgs: ${want[i]} holds exactly ${payloads[0]##*/}'s $n entries"
  fi
  i=$((i + 1))
done
rm -rf "$OUT"
mkdir -p "$OUT"
cp --remove-destination "$SHARE_DIR"/arch-build/out/*.pkg.tar.zst "$OUT/"
(cd "$OUT" && sha256sum -- *.pkg.tar.zst > SHA256SUMS)
printf 'deb\t%s\t%s\npackaging\t%s\npkgrel\t%s\n' "$(sha256sum < "${debs[0]}" | cut -d' ' -f1)" \
  "$(basename "${debs[0]}")" "$(packaging_digest)" "$pkgrel" > "$OUT/SOURCE"
rm -rf "$SHARE_DIR/arch-build"
"$ROOT/test/vm/sync.sh" >/dev/null || die "sync.sh failed: test/vm/sync.sh --check names the files"
cat "$OUT/SHA256SUMS"
