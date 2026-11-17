#!/bin/bash
# pinned kernel base tree, series and distro config fetch into RHIZO_KERNEL_CACHE
set -euo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
root=$(cd "$(dirname "$0")/../.." && pwd)
cache=${1:-${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}}

# print the value of a key in kernel/SOURCE
pin() {
  local v
  v=$(sed -n "s/^$1=//p" "$root/kernel/SOURCE")
  [[ -n "$v" ]] || { echo "kernel/SOURCE has no $1" >&2; exit 1; }
  echo "$v"
}

# print a file's sha256
sum() { sha256sum "$1" | cut -d' ' -f1; }

# fail unless file $1 has sha256 $2
check_sum() {
  local got
  got=$(sum "$1")
  [[ "$got" == "$2" ]] || { echo "sha256 of $1 is $got, expected $2" >&2; exit 1; }
}

mkdir -p "$cache/downloads"
linux=$cache/linux
# run git in the cached tree
git_() { git -C "$linux" -c advice.detachedHead=false "$@"; }

base_tag=$(pin base_tag) base_commit=$(pin base_commit) series_commit=$(pin series_commit)
series_base=$(pin series_base) series_base_commit=$(pin series_base_commit)
[[ -d "$linux/.git" ]] || git init -q "$linux"
if [[ "$(git_ rev-parse -q --verify "refs/tags/$base_tag^{commit}" || true)" != "$base_commit" ]]; then
  git_ fetch --depth 1 "$(pin base_url)" "+refs/tags/$base_tag:refs/tags/$base_tag"
fi
got=$(git_ rev-parse "refs/tags/$base_tag^{commit}")
[[ "$got" == "$base_commit" ]] || { echo "$base_tag is commit $got, expected $base_commit" >&2; exit 1; }
if ! git_ cat-file -e "$series_base_commit^{commit}" 2>/dev/null; then
  git_ fetch --depth 1 "$(pin series_url)" "+refs/tags/$series_base:refs/tags/$series_base"
fi
if ! git_ cat-file -e "$series_commit^{commit}" 2>/dev/null; then
  git_ fetch --shallow-exclude="$series_base" "$(pin series_url)" "$series_commit"
fi
if [[ -n "$(git_ rev-list --parents "$series_base..$series_commit" | awk 'NF < 2')" ]]; then
  git_ fetch --deepen 1 "$(pin series_url)" "$series_commit"
fi
if [[ -n "$(git_ rev-list --parents "$series_base..$series_commit" | awk 'NF < 2')" ]]; then
  echo "a commit in $series_base..$series_commit has no parent in $linux" >&2
  exit 1
fi
got=$(git_ rev-parse "refs/tags/$series_base^{commit}")
[[ "$got" == "$series_base_commit" ]] || { echo "$series_base is commit $got, expected $series_base_commit" >&2; exit 1; }
git_ update-ref refs/rhizo/series "$series_commit"
git_ show "$base_commit:.gitattributes" > "$linux/.git/info/attributes"

new=$(mktemp -d "$root/kernel/series.XXXXXX"); chmod 755 "$new"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git_ -c core.abbrev="$(pin series_abbrev)" format-patch -q \
  --signature="$(pin series_git_version)" -o "$new" "$series_base..$series_commit"
if ! diff <(cd "$new" && sha256sum -- *.patch) "$root/kernel/series.sha256" >&2; then
  echo "sha256sum of $new from $series_commit differs from kernel/series.sha256" >&2
  exit 1
fi
if [[ -d "$root/kernel/series" ]]; then rm -f "$root/kernel/series"/*.patch; rmdir "$root/kernel/series"; fi
mv "$new" "$root/kernel/series"

for distro in ubuntu cachyos; do
  url=$(pin "${distro}_package_url") pkg=$cache/downloads/$(basename "$(pin "${distro}_package_url")")
  if [[ ! -f "$pkg" || "$(sum "$pkg")" != "$(pin "${distro}_package_sha256")" ]]; then
    curl -fsSL --retry 3 -o "$pkg.part" "$url"
    check_sum "$pkg.part" "$(pin "${distro}_package_sha256")"
    mv "$pkg.part" "$pkg"
  fi
  path=$(pin "${distro}_config_path")
  case $distro in
    ubuntu) dpkg-deb --fsys-tarfile "$pkg" | tar -xOf - "./$path" > "$cache/config-$distro.part" ;;
    cachyos) zstd -dcq "$pkg" | tar -xOf - "$path" > "$cache/config-$distro.part" ;;
  esac
  check_sum "$cache/config-$distro.part" "$(pin "${distro}_config_sha256")"
  mv "$cache/config-$distro.part" "$cache/config-$distro"
done
echo "wrote $base_tag, config-ubuntu and config-cachyos to $cache and $(ls "$root/kernel/series" | wc -l) patches to kernel/series"
