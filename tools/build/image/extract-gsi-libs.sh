#!/bin/bash
# copy the GSI libraries the HALs link against into var/share
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

# check whether `file -b` output names a want-bit x86 ELF
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
  [[ -s "$dst" ]] || { log "$src is not in the image (debugfs dumped nothing)"; return 1; }
  hdr=$(file -b "$dst")
  if [[ "$ARCH" == aarch64 ]]; then
    case "$want:$hdr" in
      64:ELF\ 64-bit*ARM\ aarch64*) ;;
      *) log "$src is not a ${want}-bit aarch64 ELF: $hdr"; return 1 ;;
    esac
  else
    x86_elf_ok "$want" "$hdr" || { log "$src is not a ${want}-bit x86 ELF: $hdr"; return 1; }
  fi
}

# compare the image digest with its sha256 file
image_digest_matches() {
  local want have
  want=$(cat "$IMG.sha256" 2>/dev/null)
  if [[ -z "$want" ]]; then
    if [[ "$ARCH" == aarch64 ]]; then
      log "no digest beside $IMG"
      log "by hand from gsi-pins.sh's sha256-verified zip; extracting unverified against the raw img, sha256 $(sha256sum "$IMG" | cut -d' ' -f1)"
      return 0
    fi
    log "no digest beside $IMG (build-inputs.sh writes system.img.sha256)"; return 1
  fi
  have=$(sha256sum "$IMG" | cut -d' ' -f1)
  [[ "$have" == "$want" ]] || { log "$IMG digest $1 extraction is $have, recorded $want -- the image changed"; return 1; }
}

# extract the pinned libraries from the image into the share folders
extract_all() {
  if [[ "$ARCH" == aarch64 ]]; then
    local d64="$SHARE_ROOT/gsi_libs_arm64" n
    [[ -f "$IMG" ]] || { log "no image at $IMG -- run src/install/prepare/fetch-gsi.sh --release a16-arm64 or fetch it by hand from gsi-pins.sh's URL"; return 1; }
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
    log "extracted $(( ${#GSI_LIB_NAMES[@]} + ${#EXTRA64[@]} + ${#BOOTSTRAP[@]} )) 64-bit aarch64 files from $IMG (no 32-bit companion)"
    return 0
  fi
  local d64="$SHARE_ROOT/gsi_libs" d32="$SHARE_ROOT/gsi_libs_32" n
  [[ -f "$IMG" ]] || { log "no image at $IMG -- run tools/fetch/build-inputs.sh --only gsi"; return 1; }
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
    || { echo "SELFTEST FAILED: GSI_LIB_NAMES differs from src/install/prepare/fetch-gsi.sh's"; fail=1; }
  mkdir -p "$tmp/root/system/lib64/bootstrap"
  cp /bin/true "$tmp/root/system/lib64/fixture.so"
  mke2fs -F -q -d "$tmp/root" "$tmp/img" 8M >/dev/null 2>&1 || { echo "SELFTEST FAILED: mke2fs -d could not build the fixture image"; rm -rf "$tmp"; return 1; }
  sha256sum "$tmp/img" | cut -d' ' -f1 > "$tmp/img.sha256"
  IMG="$tmp/img"
  dump_lib /system/lib64/fixture.so "$tmp/out.so" 64 && cmp -s /bin/true "$tmp/out.so" \
    || { echo "SELFTEST FAILED: the fixture file did not round-trip through debugfs"; fail=1; }
  out=$(dump_lib /system/lib64/absent.so "$tmp/absent.so" 64 2>&1)
  [[ $? -ne 0 && "$out" == *"/system/lib64/absent.so is not in the image"* ]] \
    || { echo "SELFTEST FAILED: a missing name was not refused by name -- got: $out"; fail=1; }
  out=$(dump_lib /system/lib64/fixture.so "$tmp/out32.so" 32 2>&1)
  [[ $? -ne 0 && "$out" == *"not a 32-bit x86 ELF"* ]] \
    || { echo "SELFTEST FAILED: a 64-bit file passed as 32-bit -- got: $out"; fail=1; }
  x86_elf_ok 32 "ELF 32-bit LSB shared object, Intel 80386, version 1 (SYSV), dynamically linked" \
    || { echo "SELFTEST FAILED: file's Intel 80386 wording was not read as 32-bit x86"; fail=1; }
  x86_elf_ok 32 "ELF 32-bit LSB shared object, Intel i386, version 1 (SYSV), dynamically linked" \
    || { echo "SELFTEST FAILED: file 5.46 and later's Intel i386 wording was not read as 32-bit x86"; fail=1; }
  x86_elf_ok 32 "ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked" \
    && { echo "SELFTEST FAILED: a 64-bit ELF was read as 32-bit x86"; fail=1; }
  printf 'x' >> "$tmp/img"
  out=$(image_digest_matches before 2>&1)
  [[ $? -ne 0 && "$out" == *"the image changed"* ]] || { echo "SELFTEST FAILED: a changed image was not refused -- got: $out"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "extract-gsi-libs.sh selftest: FAILED"; return 1; fi
  echo "extract-gsi-libs.sh selftest: ok"
}

IMG_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMG="$2"; IMG_SET=1; shift 2 ;;
    --share-root) SHARE_ROOT="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --selftest) selftest; exit $? ;;
    *) echo "usage: $0 [--image PATH] [--share-root DIR] [--arch x86_64|aarch64] [--selftest]" >&2; exit 2 ;;
  esac
done
case "$ARCH" in
  x86_64) ;;
  aarch64) [[ "$IMG_SET" == 1 ]] || IMG="$SHARE_ROOT/gsi_a16-arm64.img" ;;
  *) echo "unknown --arch: $ARCH (expected x86_64 or aarch64)" >&2; exit 2 ;;
esac
extract_all
