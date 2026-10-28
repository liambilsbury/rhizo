#!/bin/bash
# unpack a .deb into a pacman package payload
set -euo pipefail
export LC_ALL=C
umask 022

usage='usage: arch-payload.sh <deb> <outdir> [<PKGBUILD.in>]'
# print an error and exit 1
die() { echo "build-arch-payload: $*" >&2; exit 1; }
[[ $# -eq 2 || $# -eq 3 ]] || { echo "$usage" >&2; exit 2; }
for cmd in dpkg-deb tar zstd gzip sha256sum; do
  command -v "$cmd" >/dev/null || die "$cmd is not installed and this script needs it"
done
deb=$(realpath -e -- "$1") || die "no .deb at $1"
out=$(realpath -m -- "$2")
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
pkg=$(dpkg-deb -f "$deb" Package)
ver=$(dpkg-deb -f "$deb" Version)
[[ "$ver" =~ ^[A-Za-z0-9._+~]+$ ]] \
  || die "$pkg's version $ver cannot be a pacman pkgver: it allows no hyphen revision, colon epoch or whitespace"
case "$pkg" in
  rhizo) template=${3:-$here/archlinux/rhizo/PKGBUILD.in} ;;
  *) die "no pacman packaging for $pkg" ;;
esac
[[ -s "$template" ]] || die "no PKGBUILD template at $template"

stage="$out/payload"
rm -rf "$stage" "$out/control"
mkdir -p "$stage" "$out/control"
dpkg-deb -x "$deb" "$stage"
dpkg-deb -e "$deb" "$out/control"
epoch=$(find "$stage" -mindepth 1 -printf '%T@\n' | sort -n | tail -1)
epoch=${epoch%.*}
[[ "$epoch" =~ ^[0-9]+$ ]] || die "$deb holds no file to take an mtime from"

rm -rf "$stage/etc/apt"
doc="$stage/usr/share/doc/$pkg"
licenses="$stage/usr/share/licenses/$pkg"
install -d "$licenses"
case "$pkg" in
  rhizo)
    install -d "$licenses/LICENSES"
    for f in LICENSE NOTICE "$doc"/LICENSES/*; do
      f=${f#"$doc"/}
      f=${f%.gz}
      if [[ -f "$doc/$f.gz" ]]; then
        gzip -dc "$doc/$f.gz" > "$licenses/$f"
        rm "$doc/$f.gz"
      else
        mv "$doc/$f" "$licenses/$f"
      fi
    done
    rmdir "$doc/LICENSES"
    rm "$doc/changelog.gz" "$doc/copyright"
    files="$(cd "$here/archlinux/files" && pwd)"
    untracked=$(git -C "$here" ls-files --others --exclude-standard -- "${files#"$here"/}")
    [[ -z "$untracked" ]] || die "archlinux/files holds files git does not track: ${untracked//$'\n'/ }"
    while IFS= read -r f; do
      rel=${f#archlinux/files/}
      [[ ! -e "$stage/$rel" ]] || die "archlinux/files/$rel would replace the .deb's /$rel"
      mode=0644
      [[ -x "$here/$f" ]] && mode=0755
      install -D -m "$mode" "$here/$f" "$stage/$rel"
    done < <(git -C "$here" ls-files -- "${files#"$here"/}")
    inst="$stage/usr/lib/rhizo/install"
    python3 "$here/tools/build/packaging/deb/deb_unit_lists.py" "$out/control/postinst" "$inst" \
      || die "cannot read the unit lists off $deb's postinst"
    for list in units.enable units.start; do
      [[ -s "$inst/$list" ]] || die "deb_unit_lists.py wrote no $list"
      while IFS= read -r unit; do
        [[ -f "$stage/usr/lib/systemd/system/$unit" ]] || die "$list names $unit, which $deb does not ship"
      done < "$inst/$list"
    done
    ;;
esac
rmdir --ignore-fail-on-non-empty "$doc" "$stage/usr/share/doc"

want=
if [[ -f "$out/control/conffiles" ]]; then
  want=$(sed -n '\|^/etc/apt/|!s|^/||p' "$out/control/conffiles" | sort)
fi
got=$(sed -n "s/^backup=(\(.*\))$/\1/p" "$template" | tr ' ' '\n' | tr -d "'" | sed '/^$/d' | sort)
[[ "$got" == "$want" ]] \
  || die "$template's backup= is [${got//$'\n'/ }], the .deb's conffiles but etc/apt's are [${want//$'\n'/ }]"

tarball="$pkg-payload-$ver.tar.zst"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$epoch" -I 'zstd -6 -T1' \
  -C "$out" -cf "$out/$tarball" payload
sha=$(sha256sum "$out/$tarball")
sha=${sha%% *}
sed -e "s/@VERSION@/$ver/g" -e "s/@PAYLOAD_SHA256@/$sha/g" "$template" > "$out/PKGBUILD"
inst_file=$(sed -n 's/^install=//p' "$out/PKGBUILD")
if [[ -n "$inst_file" ]]; then
  install -m 0644 "$(dirname "$template")/$inst_file" "$out/$inst_file"
fi
echo "$epoch" > "$out/SOURCE_DATE_EPOCH"
rm -rf "$stage" "$out/control"

# shellcheck disable=SC1091,SC2154
(
  source "$out/PKGBUILD"
  [[ "$pkgname" == "$pkg" && "$pkgver" == "$ver" ]] || die "PKGBUILD renders $pkgname $pkgver, the .deb is $pkg $ver"
  [[ "${source[0]}" == "$tarball" && "${sha256sums[0]}" == "$sha" ]] \
    || die "PKGBUILD names ${source[0]} ${sha256sums[0]}, the payload is $tarball $sha"
)
echo "$out"
