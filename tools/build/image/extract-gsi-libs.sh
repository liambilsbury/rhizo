#!/bin/bash
# var/share/gsi_libs var/share/gsi_libs_32 RHIZO_INPUT_CACHE=
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../env.sh
REPO_ROOT="$(cd "$(dirname "$SELF")/../../.." && pwd)"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
ARCH="x86_64"
# shellcheck source=tools/fetch/gsi-pins.sh
source "$REPO_ROOT/tools/fetch/gsi-pins.sh"
GSI_ZIP="${GSI_URL[a16]##*/}"
IMG="$CACHE/gsi/${GSI_ZIP%.zip}/system.img"
SHARE_ROOT="$VAR_DIR/share"

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
EXTRA64=(libz.so libperfetto_c.so libnativewindow.so libsync.so)
BOOTSTRAP=(libc.so libdl.so libm.so)
LIB32=(libcutils.so liblog.so libbase.so libc++.so libhardware.so libz.so)

# return whether file -b output $2 is a $1-bit x86 ELF
x86_elf_ok() {
  case "$1:$2" in
    64:ELF\ 64-bit*x86-64*|32:ELF\ 32-bit*Intel\ 80386*|32:ELF\ 32-bit*Intel\ i386*) return 0 ;;
  esac
  return 1
}

# copy a library out of the image
dump_lib() {
  local src="$1" dst="$2" want="$3" hdr
  rm -f "$dst"
  debugfs -R "dump $src $dst" "$IMG" >/dev/null 2>&1
  [[ -s "$dst" ]] || { log "$src is not in the image"; return 1; }
  hdr=$(file -b "$dst")
  if [[ "$ARCH" == aarch64 ]]; then
    case "$want:$hdr" in
      64:ELF\ 64-bit*ARM\ aarch64*) ;;
      *) log "$src is not a ${want}-bit aarch64 ELF ($hdr)"; return 1 ;;
    esac
  else
    x86_elf_ok "$want" "$hdr" || { log "$src is not a ${want}-bit x86 ELF ($hdr)"; return 1; }
  fi
}

# compare the sha256 of IMG with IMG.sha256
image_digest_matches() {
  local want have
  want=$(cat "$IMG.sha256" 2>/dev/null)
  if [[ -z "$want" ]]; then
    if [[ "$ARCH" == aarch64 ]]; then
      log "no $IMG.sha256"
      log "$IMG sha256=$(sha256sum "$IMG" | cut -d' ' -f1)"
      return 0
    fi
    log "no $IMG.sha256"; return 1
  fi
  have=$(sha256sum "$IMG" | cut -d' ' -f1)
  [[ "$have" == "$want" ]] || { log "$IMG sha256 $1 extraction is $have, expected $want"; return 1; }
}

# extract the pinned libraries from the image into the share folders
extract_all() {
  if [[ "$ARCH" == aarch64 ]]; then
    local d64="$SHARE_ROOT/gsi_libs_arm64" n
    [[ -f "$IMG" ]] || { log "no $IMG"; return 1; }
    image_digest_matches before || return 1
    mkdir -p "$d64"
    : > "$d64/.manifest"
    for n in "${GSI_LIB_NAMES[@]}" "${EXTRA64[@]}"; do
      dump_lib "/system/lib64/$n" "$d64/$n" 64 || return 1
      printf '%s\t/system/lib64/%s\t%s\n' "$n" "$n" "$(sha256sum "$d64/$n" | cut -d' ' -f1)" >> "$d64/.manifest"
    done
    for n in "${BOOTSTRAP[@]}"; do
      dump_lib "/system/lib64/bootstrap/$n" "$d64/$n" 64 || return 1
      printf '%s\t/system/lib64/bootstrap/%s\t%s\n' "$n" "$n" "$(sha256sum "$d64/$n" | cut -d' ' -f1)" >> "$d64/.manifest"
    done
    image_digest_matches after || return 1
    log "extracted $(( ${#GSI_LIB_NAMES[@]} + ${#EXTRA64[@]} + ${#BOOTSTRAP[@]} )) 64-bit aarch64 files from $IMG"
    return 0
  fi
  local d64="$SHARE_ROOT/gsi_libs" d32="$SHARE_ROOT/gsi_libs_32" n
  [[ -f "$IMG" ]] || { log "no $IMG"; return 1; }
  image_digest_matches before || return 1
  mkdir -p "$d64" "$d32"
  : > "$d64/.manifest"; : > "$d32/.manifest"
  for n in "${GSI_LIB_NAMES[@]}" "${EXTRA64[@]}"; do
    dump_lib "/system/lib64/$n" "$d64/$n" 64 || return 1
    printf '%s\t/system/lib64/%s\t%s\n' "$n" "$n" "$(sha256sum "$d64/$n" | cut -d' ' -f1)" >> "$d64/.manifest"
  done
  for n in "${BOOTSTRAP[@]}"; do
    dump_lib "/system/lib64/bootstrap/$n" "$d64/$n" 64 || return 1
    printf '%s\t/system/lib64/bootstrap/%s\t%s\n' "$n" "$n" "$(sha256sum "$d64/$n" | cut -d' ' -f1)" >> "$d64/.manifest"
  done
  for n in "${LIB32[@]}"; do
    dump_lib "/system/lib/$n" "$d32/$n" 32 || return 1
    printf '%s\t/system/lib/%s\t%s\n' "$n" "$n" "$(sha256sum "$d32/$n" | cut -d' ' -f1)" >> "$d32/.manifest"
  done
  for n in "${BOOTSTRAP[@]}"; do
    dump_lib "/system/lib/bootstrap/$n" "$d32/$n" 32 || return 1
    printf '%s\t/system/lib/bootstrap/%s\t%s\n' "$n" "$n" "$(sha256sum "$d32/$n" | cut -d' ' -f1)" >> "$d32/.manifest"
  done
  image_digest_matches after || return 1
  log "extracted $(( ${#GSI_LIB_NAMES[@]} + ${#EXTRA64[@]} + ${#BOOTSTRAP[@]} )) 64-bit and $(( ${#LIB32[@]} + ${#BOOTSTRAP[@]} )) 32-bit files from $IMG"
}

# test the library dump and digest checks
selftest() {
  local fail=0 tmp inst out
  tmp=$(mktemp -d)
  inst=$(sed -n '/^GSI_LIB_NAMES=(/,/^)/p' "$REPO_ROOT/src/install/prepare/fetch-gsi.sh" | sed '1d;$d' | tr -s ' \n' '\n' | grep -v '^$' | sort)
  [[ "$inst" == "$(printf '%s\n' "${GSI_LIB_NAMES[@]}" | sort)" ]] \
    || { echo "FAIL GSI_LIB_NAMES == GSI_LIB_NAMES of src/install/prepare/fetch-gsi.sh"; fail=1; }
  mkdir -p "$tmp/root/system/lib64/bootstrap"
  cp /bin/true "$tmp/root/system/lib64/fixture.so"
  mke2fs -F -q -d "$tmp/root" "$tmp/img" 8M >/dev/null 2>&1 || { echo "FAIL mke2fs -d root img exits 0"; rm -rf "$tmp"; return 1; }
  sha256sum "$tmp/img" | cut -d' ' -f1 > "$tmp/img.sha256"
  IMG="$tmp/img"
  dump_lib /system/lib64/fixture.so "$tmp/out.so" 64 && cmp -s /bin/true "$tmp/out.so" \
    || { echo "FAIL dump_lib fixture.so == /bin/true"; fail=1; }
  out=$(dump_lib /system/lib64/absent.so "$tmp/absent.so" 64 2>&1)
  [[ $? -ne 0 && "$out" == *"/system/lib64/absent.so is not in the image"* ]] \
    || { echo "FAIL dump_lib absent.so returns 1 ($out)"; fail=1; }
  out=$(dump_lib /system/lib64/fixture.so "$tmp/out32.so" 32 2>&1)
  [[ $? -ne 0 && "$out" == *"not a 32-bit x86 ELF"* ]] \
    || { echo "FAIL dump_lib fixture.so 32 returns 1 ($out)"; fail=1; }
  x86_elf_ok 32 "ELF 32-bit LSB shared object, Intel 80386, version 1 (SYSV), dynamically linked" \
    || { echo "FAIL x86_elf_ok 32 Intel 80386 returns 0"; fail=1; }
  x86_elf_ok 32 "ELF 32-bit LSB shared object, Intel i386, version 1 (SYSV), dynamically linked" \
    || { echo "FAIL x86_elf_ok 32 Intel i386 returns 0"; fail=1; }
  x86_elf_ok 32 "ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked" \
    && { echo "FAIL x86_elf_ok 32 x86-64 returns 1"; fail=1; }
  printf 'x' >> "$tmp/img"
  out=$(image_digest_matches before 2>&1)
  [[ $? -ne 0 && "$out" == *"extraction is"*"expected"* ]] || { echo "FAIL image_digest_matches after a write to img returns 1 ($out)"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "FAIL extract-gsi-libs.sh --selftest"; return 1; fi
  echo "ok extract-gsi-libs.sh --selftest"
}

IMG_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMG="$2"; IMG_SET=1; shift 2 ;;
    --share-root) SHARE_ROOT="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --selftest) selftest; exit $? ;;
    *) echo "$0 [--image PATH] [--share-root DIR] [--arch x86_64|aarch64] [--selftest]" >&2; exit 2 ;;
  esac
done
case "$ARCH" in
  x86_64) ;;
  aarch64) [[ "$IMG_SET" == 1 ]] || IMG="$SHARE_ROOT/gsi_a16-arm64.img" ;;
  *) echo "unknown --arch $ARCH, expected x86_64 or aarch64" >&2; exit 2 ;;
esac
extract_all
