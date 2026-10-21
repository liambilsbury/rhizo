#!/bin/bash
# define the offline pacman pool settings
ARCH_POOL_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARCH_POOL_GUEST_DIR=/root/share/arch-pool
ARCH_POOL_REPO=rhizo-pool
ARCH_POOL_ROOTS=(dash android-tools linux-cachyos-lts linux-cachyos-lts-headers plasma-wayland-protocols foot)
ARCH_POOL_KERNEL_RECORD=POOL.kernel-depends
ARCH_POOL_KERNEL_DEPENDS=()
ARCH_POOL_OPTIONS=(
  "HoldPkg     = pacman glibc"
  "Architecture = auto"
  "Color"
  "ILoveCandy"
  "VerbosePkgLists"
  "DisableDownloadTimeout"
  "ParallelDownloads = 10"
  "DownloadUser = alpm"
  "SigLevel    = Required DatabaseOptional"
  "LocalFileSigLevel = Optional"
)

# write MANIFEST.tsv in the guest's pool directory
arch_pool_manifest() {
  arch_pool_need_guest || return 1
  guest 300 bash -s -- "$ARCH_POOL_GUEST_DIR" <"$ARCH_POOL_LIB_DIR/write-manifest.sh"
}

# write a pacman.conf for the pool
arch_pool_conf() {
  [[ $# -eq 1 ]] || { echo "usage: arch_pool_conf <path>" >&2; return 2; }
  {
    echo "[options]"
    printf '%s\n' "${ARCH_POOL_OPTIONS[@]}"
    printf '\n[%s]\nSigLevel = Required DatabaseOptional\nServer = file://%s\n' "$ARCH_POOL_REPO" "$ARCH_POOL_GUEST_DIR"
  } > "$1"
}

# check the guest function exists
arch_pool_need_guest() {
  declare -F guest >/dev/null || { echo "arch-pool-lib.sh runs commands through guest(), which cachyos-guest-lib.sh defines and this shell has not sourced" >&2; return 1; }
}

# print the root packages and the Rhizo kernel's depends
arch_pool_targets() {
  printf '%s\n' "${ARCH_POOL_ROOTS[@]}" "${ARCH_POOL_KERNEL_DEPENDS[@]}"
}

# print a package file's .PKGINFO
arch_pool_pkginfo() {
  local info
  info=$(tar --zstd -xOf "$1" .PKGINFO 2>&1) || { echo "[arch-pool] cannot read the .PKGINFO of $1: $info" >&2; return 2; }
  printf '%s\n' "$info"
}

# print a package's Rhizo kernel depends
arch_pool_pkg_kernel_names() {
  local info
  info=$(arch_pool_pkginfo "$1") || return 2
  sed -n 's/^depend = \(linux-rhizo[^<>=]*\).*$/\1/p' <<<"$info" | sort -u
}

# print a PKGBUILD's Rhizo kernel depends
arch_pool_pkgbuild_kernel_names() {
  local deps
  deps=$(sed -n '/^depends=(/,/)/p' "$1") || { echo "[arch-pool] cannot read $1" >&2; return 2; }
  [[ -n "$deps" ]] || { echo "[arch-pool] $1 has no depends=( array" >&2; return 2; }
  grep -o "'linux-rhizo[^'<>=]*" <<<"$deps" | tr -d "'" | sort -u
}

# print a file per Rhizo kernel package
arch_pool_kernel_pkgs() {
  local dir="$1" name f info got
  shift
  for name in "$@"; do
    got=()
    for f in "$dir/$name"-[0-9]*.pkg.tar.zst; do
      [[ -f "$f" ]] || continue
      info=$(arch_pool_pkginfo "$f") || return 2
      grep -qx "pkgname = $name" <<<"$info" && got+=("$f")
    done
    if (( ${#got[@]} != 1 )); then
      echo "[arch-pool] $dir holds ${#got[@]} $name package files (${got[*]##*/}), want one: copy there the linux-rhizo packages make kernel-arch builds into var/kernel/cachyos" >&2
      return 2
    fi
    printf '%s\n' "${got[0]}"
  done
}

# print the depends of Rhizo kernel package files
arch_pool_kernel_depends() {
  local f info own="" deps=""
  for f in "$@"; do
    info=$(arch_pool_pkginfo "$f") || return 2
    own+="$(sed -n 's/^pkgname = //p' <<<"$info")"$'\n'
    deps+="$(sed -n 's/^depend = \([^<>=]*\).*$/\1/p' <<<"$info")"$'\n'
  done
  awk 'NR == FNR { if ($0 != "") own[$0] = 1; next } $0 != "" && !($0 in own)' <(printf '%s' "$own") <(printf '%s' "$deps") | sort -u
}

# print the kernel depends the pool record lacks
arch_pool_kernel_problems() {
  local pool="$1" record deps d bad=0
  shift
  record="$pool/$ARCH_POOL_KERNEL_RECORD"
  if [[ ! -f "$record" ]]; then
    echo "$pool has no $ARCH_POOL_KERNEL_RECORD, so it was not built for the Rhizo kernel's depends: run tools/fetch/pools/arch/arch-pool.sh"
    return 1
  fi
  deps=$(arch_pool_kernel_depends "$@") || return 1
  for d in $deps; do
    grep -qxF "$d" "$record" || { echo "the Rhizo kernel depends on $d, which $record does not name: run tools/fetch/pools/arch/arch-pool.sh"; bad=1; }
  done
  return "$bad"
}

# compare the pool and guest pacman options
arch_pool_options_match() {
  local out rc=0
  arch_pool_need_guest || return 1
  out=$(guest 60 bash -s -- "$ARCH_POOL_GUEST_DIR/pacman.conf" <"$ARCH_POOL_LIB_DIR/compare-options.sh" 2>&1) || rc=$?
  (( rc == 0 )) || { echo "the pool's [options] differ from the guest's own (diff rc $rc, < is the guest's):" >&2; echo "$out" >&2; return 1; }
}

# check the guest pool against POOL.sha256
arch_pool_stage() {
  local out rc=0
  arch_pool_need_guest || return 1
  out=$(guest 900 bash -s -- "$ARCH_POOL_GUEST_DIR" "$ARCH_POOL_REPO" <"$ARCH_POOL_LIB_DIR/check-pool.sh" 2>&1) || rc=$?
  echo "$out"
  (( rc == 0 )) || { echo "the pool on the guest failed its check, rc $rc (124 is the 900s bound, 255 is ssh)" >&2; return 1; }
}
