#!/bin/bash
# fetch and stage the GSI system image
set -uo pipefail

PROG=rhizo-host-fetch-gsi
log() { echo "[$PROG] $*" >&2; }
# print a refusal reason and exit 1
refuse() { local t="$1"; shift; log "REFUSED: $*"; echo "RHIZO_GSI_REFUSED reason=$t"; exit 1; }
# print a failure reason and exit 1
failstop() { local t="$1"; shift; log "FAILED: $*"; echo "RHIZO_GSI_FAILED reason=$t"; exit 1; }
# print the usage text
usage() {
  cat <<'EOF'
usage: fetch-gsi.sh [--release LABEL] [--from-zip PATH] [--verify | --fetch-only | --derive-only] [--offline]
                    [-h | --help]
EOF
}

declare -A GSI_URL GSI_SHA GSI_DESC
GSI_URL[a16]="https://github.com/liambilsbury/rhizo/releases/download/gsi-a16-BP4A.251205.006-1/rhizo-gsi_x86_64-user-BP4A.251205.006-1.zip"
GSI_SHA[a16]="32d7103f1e54622d47256a32b0dc09400979d7a72b6111adf5340a504021906f"
GSI_DESC[a16]="Android 16 BP4A.251205.006, Rhizo's gsi_x86_64 build"
GSI_URL[a17]="https://github.com/liambilsbury/rhizo/releases/download/gsi-a17-CP2A.260605.016-1/rhizo-gsi_x86_64-user-CP2A.260605.016-1.zip"
GSI_SHA[a17]="302bb7605f62f96a37afedb045ca0b5f955179e1d2d64b2ae6b4bea3ada3e1c9"
GSI_DESC[a17]="Android 17 CP2A.260605.016, Rhizo's gsi_x86_64 build"

# add the release pins a test rig lists in a tab-separated file
load_extra_pins() {
  local f="$1" rel url sha desc
  [[ -f "$f" ]] || return 0
  while IFS=$'\t' read -r rel url sha desc || [[ -n "$rel" ]]; do
    [[ -z "$rel" || "$rel" == \#* ]] && continue
    [[ "$rel" =~ ^[a-z0-9][a-z0-9-]*$ && "$rel" != a16 && "$rel" != a17 && "$sha" =~ ^[0-9a-f]{64}$ && "$url" == https://* ]] \
      || { log "skipping a bad pin row for '$rel' in $f"; continue; }
    GSI_URL[$rel]="$url"; GSI_SHA[$rel]="$sha"; GSI_DESC[$rel]="$desc"
  done < "$f"
}

MODE=apply
RELEASE=a16
FROM_ZIP=""
OFFLINE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="${2:-}"; shift 2 ;;
    --from-zip) FROM_ZIP="${2:-}"; shift 2 ;;
    --verify) MODE=verify; shift ;;
    --fetch-only) MODE=fetch-only; shift ;;
    --derive-only) MODE=derive-only; shift ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[$PROG] FAIL: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
load_extra_pins "${RHIZO_GSI_PINS:-/etc/rhizo/gsi-pins.tsv}"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/host-flavor.sh" \
  || refuse "library-unreadable" "cannot read host-flavor.sh beside $0"
why=$(host_state_subvolume_check) || refuse "root-snapshot-boot" "$why"
# print the current release label
current_release() {
  local f r="" rt="${RHIZO_RUNTIME_ENV:-/var/lib/rhizo/androidd-runtime.env}" files=()
  f="${RHIZO_ANDROIDD_ENV:-}"
  [[ -n "$f" ]] || f=$(systemctl cat androidd.service 2>/dev/null | sed -n 's/^EnvironmentFile=-\?\(.*\)$/\1/p' | grep -vxF -e /var/lib/rhizo/host-mode-kept.env -e /var/lib/rhizo/androidd-runtime.env | tail -1)
  [[ -z "$f" || ! -f "$f" ]] || files+=("$f")
  [[ ! -f "$rt" ]] || files+=("$rt")
  (( ${#files[@]} )) && r=$(sed -n 's/^RHIZO_RELEASE=//p' "${files[@]}" | tail -1)
  if [[ -n "$r" && -n "${GSI_URL[$r]:-}" ]]; then printf '%s' "$r"; else printf 'a16'; fi
}
if [[ "$RELEASE" == current ]]; then
  RELEASE=$(current_release)
  log "the current release is $RELEASE"
fi
[[ -n "${GSI_URL[$RELEASE]:-}" ]] || refuse "unknown-release" "no GSI pin for '$RELEASE' -- known: ${!GSI_URL[*]}"

SRV="${RHIZO_GSI_ROOT:-/srv/rhizo}"
TREE="$SRV/gsi_system"
[[ "$RELEASE" == a16 ]] || TREE="$SRV/gsi_system_$RELEASE"
CACHE="${RHIZO_CACHE_DIR:-/var/cache/rhizo}/gsi"
GSI_LIBS_ROOT="${RHIZO_DERIVED_DIR:-/var/lib/rhizo/derived}/gsi_libs"
GSI_LIBS="$GSI_LIBS_ROOT/${TREE##*/}"
PATCHES_ROOT="${RHIZO_DERIVED_DIR:-/var/lib/rhizo/derived}/patches"
PATCHES="$PATCHES_ROOT/${TREE##*/}"
DERIVE_PATCHES="${RHIZO_DERIVE_PATCHES:-$(dirname "${BASH_SOURCE[0]}")/../../tools/derive-patches.sh}"
ZIP="$CACHE/gsi_$RELEASE.zip"
WANT="${GSI_SHA[$RELEASE]}"

# check whether the GSI tree is staged
staged() { [[ -s "$TREE/bin/init" ]]; }

# check for android's policy loaded on this boot
policy_loaded() {
  local ctx
  ctx=$(tr -d '\0' < "${RHIZO_ATTR_CURRENT:-/proc/self/attr/current}" 2>/dev/null) || return 1
  [[ "$ctx" == u:r:* ]]
}

# remove the cached zip
cleanup_gsi_zip_cache() {
  local zip="$1" from_zip="$2"
  [[ -n "$from_zip" ]] && return 0
  rm -f "$zip"
}

if [[ "$MODE" == verify ]]; then
  if staged; then
    log "staged: $TREE ($(du -sh "$TREE" 2>/dev/null | cut -f1))"
    echo "RHIZO_GSI_VERIFIED=1"; exit 0
  fi
  log "no staged tree at $TREE"
  failstop "not-staged" "$TREE carries no bin/init"
fi

GSI_LIB_NAMES=(
  android.hardware.security.rkp-V3-ndk.so
  android.hardware.security.secureclock-V1-ndk.so
  android.hardware.security.sharedsecret-V1-ndk.so
  libbase.so libbinder.so libbinder_ndk.so libc++.so
  libcppbor.so libcppcose_rkp.so libcrypto.so libcutils.so libdrm.so
  libhardware.so libhidlbase.so libkeymaster_messages.so
  libkeymaster_portable.so liblog.so libsoft_attestation_cert.so
  libutils.so libvndksupport.so
)
GSI_LIBS_SOURCE=source

# print the build fingerprint from build.prop
tree_fingerprint() {
  local key fp=""
  for key in ro.system.build.fingerprint ro.build.fingerprint; do
    fp=$(sed -n "s/^[[:space:]]*${key//./\\.}=//p" "$TREE/build.prop" 2>/dev/null | tail -1)
    fp="${fp%"${fp##*[![:space:]]}"}"
    [[ -n "$fp" ]] && break
  done
  printf '%s' "$fp"
}

# copy the GSI libraries out of the tree
derive_gsi_libs() {
  local name src d copied=0 kept=0 missing="" fp
  fp=$(tree_fingerprint)
  [[ -n "$fp" ]] \
    || failstop "gsi-libs-fingerprint" "$TREE/build.prop carries no ro.system.build.fingerprint or ro.build.fingerprint"
  mkdir -p "$GSI_LIBS" || failstop "gsi-libs-mkdir" "cannot create $GSI_LIBS"
  exec 8>"$GSI_LIBS_ROOT/.lock" || failstop "gsi-libs-lock" "cannot open $GSI_LIBS_ROOT/.lock"
  flock 8 || failstop "gsi-libs-lock" "cannot lock $GSI_LIBS_ROOT/.lock"
  rm -f "$GSI_LIBS/$GSI_LIBS_SOURCE" || failstop "gsi-libs-stamp" "cannot clear $GSI_LIBS/$GSI_LIBS_SOURCE"
  for name in "${GSI_LIB_NAMES[@]}"; do
    src=""
    for d in lib64 system/lib64; do
      [[ -f "$TREE/$d/$name" ]] && { src="$TREE/$d/$name"; break; }
    done
    if [[ -z "$src" ]]; then missing="$missing $name"; continue; fi
    if cmp -s "$src" "$GSI_LIBS/$name"; then kept=$((kept + 1)); continue; fi
    cp "$src" "$GSI_LIBS/$name" || failstop "gsi-libs-copy" "cannot copy $src into $GSI_LIBS"
    copied=$((copied + 1))
  done
  [[ -z "$missing" ]] \
    || failstop "gsi-libs-missing" "this GSI has no:$missing"
  { printf 'tree=%s\nfingerprint=%s\n' "$TREE" "$fp" > "$GSI_LIBS/$GSI_LIBS_SOURCE.tmp" \
      && mv "$GSI_LIBS/$GSI_LIBS_SOURCE.tmp" "$GSI_LIBS/$GSI_LIBS_SOURCE"; } \
    || failstop "gsi-libs-stamp" "cannot write $GSI_LIBS/$GSI_LIBS_SOURCE"
  for name in "${GSI_LIB_NAMES[@]}"; do rm -f "$GSI_LIBS_ROOT/$name"; done
  derive_stock_patches
  exec 8>&-
  log "took $copied of ${#GSI_LIB_NAMES[@]} glue librar(ies) out of $TREE into $GSI_LIBS, $kept already there; stock patches in $PATCHES"
}

STOCK_PATCH_NAMES=(netd.rc surfaceflinger.rc vold.rc init.vndk-nodef.rc cameraserver.rc wificond.rc
                   init.zygote64.rc init.zygote64_32.rc product-build.prop)
# derive the stock patches from the tree
derive_stock_patches() {
  local out name
  [[ -f "$DERIVE_PATCHES" ]] || failstop "stock-patches" "no $DERIVE_PATCHES to derive $TREE's stock patches with"
  rm -rf "$PATCHES.part" || failstop "stock-patches" "cannot clear $PATCHES.part"
  out=$(bash "$DERIVE_PATCHES" "$RELEASE" --from-tree "$TREE" --out "$PATCHES.part" 2>&1) \
    || failstop "stock-patches" "$DERIVE_PATCHES could not derive $TREE's stock patches: $(tail -3 <<<"$out" | tr '\n' ' ')"
  { rm -rf "$PATCHES" && mv "$PATCHES.part" "$PATCHES"; } \
    || failstop "stock-patches" "cannot move $PATCHES.part into place"
  for name in "${STOCK_PATCH_NAMES[@]}"; do rm -f "${PATCHES_ROOT%/patches}/$name"; done
}

[[ $EUID -eq 0 ]] || refuse "not-root" "must run as root (it writes $SRV and mounts the image)"
if [[ -n "$FROM_ZIP" ]]; then
  [[ -f "$FROM_ZIP" ]] || refuse "no-such-zip" "--from-zip '$FROM_ZIP' does not exist"
  have=$(sha256sum "$FROM_ZIP" | cut -d' ' -f1)
  [[ "$have" == "$WANT" ]] || failstop "sha256-mismatch" "$FROM_ZIP is $have, the pin is $WANT"
fi
if [[ "$MODE" == derive-only ]]; then
  staged || failstop "not-staged" "$TREE carries no bin/init"
  derive_gsi_libs
  echo "RHIZO_GSI_DERIVED release=$RELEASE dir=$GSI_LIBS"
  exit 0
fi
staged && { log "$TREE is already staged"; derive_gsi_libs; cleanup_gsi_zip_cache "$ZIP" "$FROM_ZIP"; echo "RHIZO_GSI_ALREADY_STAGED=1"; exit 0; }
[[ "$MODE" == apply ]] && policy_loaded \
  && refuse "policy-loaded" "Android's SELinux policy is loaded host-wide -- $TREE stages on the next boot, before the load; rhizo gsi update arranges that"

command -v python3 >/dev/null 2>&1 || refuse "no-python3" "python3 is required to extract the image"
command -v curl >/dev/null 2>&1 || [[ -n "$FROM_ZIP" ]] || refuse "no-curl" "curl is required to download the image"

mkdir -p "$CACHE" "$SRV" || failstop "mkdir-failed" "cannot create $CACHE and $SRV"

if [[ -n "$FROM_ZIP" ]]; then
  ZIP="$FROM_ZIP"
  log "using $ZIP (its sha256 is still checked against the pin below)"
elif [[ -f "$ZIP" ]] && [[ "$(sha256sum "$ZIP" | cut -d' ' -f1)" == "$WANT" ]]; then
  log "cached zip already matches the pin"
else
  (( OFFLINE )) && failstop "no-cached-zip" "--offline and no cached ${GSI_DESC[$RELEASE]} zip matching the pin"
  log "downloading ${GSI_DESC[$RELEASE]}"
  curl -fsS -L --retry 3 --retry-delay 5 -o "$ZIP.part" "${GSI_URL[$RELEASE]}" \
    || failstop "download-failed" "could not fetch ${GSI_URL[$RELEASE]}"
  mv "$ZIP.part" "$ZIP"
fi

have=$(sha256sum "$ZIP" | cut -d' ' -f1)
[[ "$have" == "$WANT" ]] || failstop "sha256-mismatch" "$ZIP is $have, the pin is $WANT"
log "sha256 verified against the pin"
if [[ "$MODE" == fetch-only ]]; then
  log "keeping the verified zip for the staging to come"
  echo "RHIZO_GSI_FETCHED release=$RELEASE sha256=$WANT"
  exit 0
fi

# check for a policy the host loaded itself
host_policy() {
  local ctx
  ctx=$(tr -d '\0' < "${RHIZO_ATTR_CURRENT:-/proc/self/attr/current}" 2>/dev/null) || return 1
  [[ "$ctx" == *:* ]]
}
LAUNCHER="${RHIZO_LAUNCHER:-$(dirname "${BASH_SOURCE[0]}")/../../launcher3.py}"
# run a hostops.py operation in this script's domain
hostops() { python3 "${RHIZO_HOSTOPS:-$(dirname "${BASH_SOURCE[0]}")/../../hostops.py}" "$@"; }

# copy the image's system tree to $TREE.part with the image's labels
copy_tree() {
  if host_policy; then
    log "the host has its own SELinux policy: copying with the image's labels in a namespace that loads Android's policy"
    python3 "$LAUNCHER" stage-gsi-labeled "$TMP/system.img" "$TREE.part" "$TMP" \
      || failstop "labeled-copy-failed" "could not copy the tree with the image's labels in a namespace that loads Android's policy"
    return 0
  fi
  mkdir -p "$TMP/mnt"
  LOOP=$(hostops loop-attach -r "$TMP/system.img") || failstop "mount-failed" "could not attach the extracted system.img to a loop device"
  hostops mount -r -t ext4 "$LOOP" "$TMP/mnt" || failstop "mount-failed" "could not mount the extracted system.img"
  [[ -d "$TMP/mnt/system" ]] || failstop "no-system-dir" "the image has no system/ directory"
  cp -a "$TMP/mnt/system" "$TREE.part" || failstop "copy-failed" "could not copy the tree out of the image"
  hostops umount "$TMP/mnt"
  hostops loop-detach "$LOOP"
  LOOP=""
}

# print the directory that holds scratch images
scratch_root() { echo "${RHIZO_STATE_DIR:-/var/lib/rhizo}/fetch-scratch"; }

# remove scratch directories an earlier run left
sweep_stale_scratch() {
  local root d loop loops
  root=$(scratch_root)
  [[ -d "$root" ]] || return 0
  while IFS= read -r -d '' d; do
    if hostops is-mount "$d/mnt"; then
      hostops umount "$d/mnt" || { log "leaving $d: its mount would not unmount"; continue; }
    fi
    if ! loops=$(hostops loop-find "$d/system.img"); then
      log "leaving $d: hostops loop-find failed"
      continue
    fi
    while read -r loop; do
      [[ -n "$loop" ]] && { hostops loop-detach "$loop" || { log "leaving $d: $loop would not detach"; continue 2; }; }
    done <<<"$loops"
    rm -rf --one-file-system -- "$d" || log "could not remove $d"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'gsi.*' -user "$(id -u)" -mmin +1440 -print0)
}

# create a scratch directory below the state directory
make_scratch() {
  local root
  root=$(scratch_root)
  # shellcheck disable=SC2174
  mkdir -p -m 0700 "$root" && mktemp -d "$root/gsi.XXXXXX"
}

sweep_stale_scratch
TMP=$(make_scratch) || failstop "mktemp-failed" "cannot create a scratch directory below $(scratch_root)"
LOOP=""
# unmount and remove the scratch directory
cleanup() { hostops is-mount "$TMP/mnt" && hostops umount "$TMP/mnt"; [[ -n "$LOOP" ]] && hostops loop-detach "$LOOP"; rm -rf --one-file-system "$TMP"; rmdir -- "$(scratch_root)" 2>/dev/null; }
trap cleanup EXIT

log "extracting system.img"
python3 - "$ZIP" "$TMP/system.img" <<'PYEOF' || failstop "extract-failed" "system.img is not in the archive"
import shutil, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z, open(sys.argv[2], "wb") as out:
    with z.open("system.img") as src:
        shutil.copyfileobj(src, out, 1024 * 1024)
PYEOF

rm -rf "$TREE.part"
copy_tree
[[ -s "$TREE.part/bin/init" ]] || failstop "no-init" "the copied tree has no bin/init"
rm -rf "$TREE"
mv "$TREE.part" "$TREE" || failstop "rename-failed" "could not move $TREE.part into place"
sync
cleanup_gsi_zip_cache "$ZIP" "$FROM_ZIP"
derive_gsi_libs

log "staged ${GSI_DESC[$RELEASE]} at $TREE"
echo "RHIZO_GSI_OK release=$RELEASE tree=$TREE sha256=$WANT"
