#!/bin/bash
# toolchain/libva-android RHIZO_INPUT_CACHE=
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../env.sh
source ../toolchain/own-output-lib.sh
REPO_ROOT="$(cd "$(dirname "$SELF")/../../.." && pwd)"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
LIBVA_VERSION=2.22.0
LIBDRM_VERSION=2.4.123
LIBVA_TARBALL="$CACHE/libva/libva-$LIBVA_VERSION.tar.bz2"
LIBDRM_TARBALL="$REPO_ROOT/mesa-src/subprojects/packagecache/libdrm-$LIBDRM_VERSION.tar.xz"
CROSS_FILE="$REPO_ROOT/tools/mesa/mesa-cross-x86_64-android"
OUT="$REPO_ROOT/toolchain/libva-android"
DRIVER_DIR=/vendor/lib64/dri
LIBVA_NEEDED="libdl.so libc.so"
LIBVA_DRM_NEEDED="libva.so libdrm.so libc.so"

# print the sorted NEEDED entries of an ELF on one line
needed_of() { readelf -dW "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | tr '\n' ' ' | sed 's/ $//'; }

# check an ELF's soname and NEEDED set
check_elf() {
  local f="$1" soname="$2" want="$3" have got
  have=$(readelf -dW "$f" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
  [[ "$have" == "$soname" ]] || { log "$f has SONAME '$have', expected $soname"; return 1; }
  got=$(needed_of "$f"); want=$(tr ' ' '\n' <<<"$want" | sort | tr '\n' ' ' | sed 's/ $//')
  [[ "$got" == "$want" ]] || { log "$f NEEDED is [$got], expected [$want]"; return 1; }
}

# check the built libva tree
check_tree() {
  local root="$1" lib="$1/vendor/lib64" f
  check_elf "$lib/libva.so" libva.so "$LIBVA_NEEDED" || return 1
  check_elf "$lib/libva-drm.so" libva-drm.so "$LIBVA_DRM_NEEDED" || return 1
  file -b "$lib/libva.so" | grep 'ELF 64-bit.*x86-64' >/dev/null || { log "$lib/libva.so is not an x86-64 ELF"; return 1; }
  strings -n 8 "$lib/libva.so" | grep -x "$DRIVER_DIR" >/dev/null || { log "strings $lib/libva.so has no $DRIVER_DIR"; return 1; }
  for f in libva-android.so libva-x11.so libva-glx.so libva-wayland.so; do
    [[ ! -e "$lib/$f" ]] || { log "$lib/$f exists"; return 1; }
  done
  grep -q '^Version: 1\.22\.0$' "$lib/pkgconfig/libva.pc" || { log "$lib/pkgconfig/libva.pc Version is not 1.22.0"; return 1; }
  [[ -f "$root/vendor/include/va/va_drm.h" ]] || { log "no $root/vendor/include/va/va_drm.h"; return 1; }
}

# build libdrm, libva and libva-drm
build_all() {
  local work rc=0
  own_output "$(dirname "$OUT")" || return 1
  [[ -f "$CROSS_FILE" ]] || { log "no $CROSS_FILE"; return 1; }
  "$REPO_ROOT/tools/fetch/build-inputs.sh" --only libva --only libdrm --check >/dev/null 2>&1 \
    || { log "tools/fetch/build-inputs.sh --only libva --only libdrm --check failed"; return 1; }
  [[ -f "$LIBVA_TARBALL" && -f "$LIBDRM_TARBALL" ]] || { log "no $LIBVA_TARBALL or $LIBDRM_TARBALL"; return 1; }
  command -v meson >/dev/null && command -v ninja >/dev/null || { log "no meson or ninja in PATH"; return 1; }
  work=$(mktemp -d "$REPO_ROOT/toolchain/libva-android.build.XXXXXX") || return 1
  tar -xf "$LIBDRM_TARBALL" -C "$work" && tar -xf "$LIBVA_TARBALL" -C "$work" || { log "failed to extract $LIBDRM_TARBALL and $LIBVA_TARBALL"; rm -rf "$work"; return 1; }

  ( PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH='' meson setup "$work/drm-build" "$work/libdrm-$LIBDRM_VERSION" \
      --cross-file "$CROSS_FILE" --prefix="$work/drm-prefix" --libdir=lib --buildtype=release \
      -Dintel=disabled -Damdgpu=disabled -Dradeon=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
      -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled \
      -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dinstall-test-programs=false \
      -Dudev=false && ninja -C "$work/drm-build" install ) > "$work/libdrm.log" 2>&1 \
    || { log "libdrm build failed (log $work/libdrm.log)"; return 1; }

  ( PKG_CONFIG_LIBDIR="$work/drm-prefix/lib/pkgconfig" PKG_CONFIG_PATH='' \
      meson setup "$work/va-build" "$work/libva-$LIBVA_VERSION" \
      --cross-file "$CROSS_FILE" --prefix=/vendor --libdir=lib64 --sysconfdir=etc --buildtype=release \
      -Ddriverdir="$DRIVER_DIR" -Ddisable_drm=false -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no \
      -Denable_docs=false && DESTDIR="$work/stage" ninja -C "$work/va-build" install ) > "$work/libva.log" 2>&1 \
    || { log "libva build failed (log $work/libva.log)"; return 1; }
  check_tree "$work/stage" || { log "check_tree $work/stage failed"; return 1; }

  rm -rf "$OUT.part" && mv "$work/stage" "$OUT.part" || rc=1
  printf 'libva %s from %s sha256 %s, libdrm %s for linking from %s sha256 %s, by %s\n' \
    "$LIBVA_VERSION" "${LIBVA_TARBALL##*/}" "$(sha256sum "$LIBVA_TARBALL" | cut -d' ' -f1)" \
    "$LIBDRM_VERSION" "${LIBDRM_TARBALL##*/}" "$(sha256sum "$LIBDRM_TARBALL" | cut -d' ' -f1)" \
    "tools/build/graphics/libva-android.sh" > "$OUT.part/SOURCE" || rc=1
  (( rc == 0 )) && rm -rf "$OUT" && mv "$OUT.part" "$OUT" || { log "failed to rename $OUT.part to $OUT"; return 1; }
  rm -rf "$work"
  log "staged ${OUT#"$REPO_ROOT"/}/vendor/lib64/libva.so and libva-drm.so ($(needed_of "$OUT/vendor/lib64/libva-drm.so"))"
}

# test the ELF checks
selftest() {
  local fail=0 t out
  t=$(mktemp -d)
  if command -v cc >/dev/null; then
    cc -shared -fPIC -Wl,-soname,libva.so -o "$t/libva.so" -x c /dev/null 2>/dev/null
    cc -shared -fPIC -Wl,-soname,libother.so -o "$t/libother.so" -x c /dev/null 2>/dev/null
    out=$(check_elf "$t/libother.so" libva.so "libc.so" 2>&1)
    [[ $? -ne 0 && "$out" == *"has SONAME 'libother.so', expected libva.so"* ]] || { echo "FAIL check_elf libother.so libva.so returns 1 ($out)"; fail=1; }
    out=$(check_elf "$t/libva.so" libva.so "libdl.so libc.so" 2>&1)
    [[ $? -ne 0 && "$out" == *"expected [libc.so libdl.so]"* ]] || { echo "FAIL check_elf libva.so with NEEDED libdl.so libc.so returns 1 ($out)"; fail=1; }
  else
    echo "SKIP check_elf without cc in PATH"
  fi
  out=$(RHIZO_INPUT_CACHE="$t/no-cache" "$SELF" 2>&1)
  [[ $? -ne 0 && "$out" == *"--check failed"* ]] || { echo "FAIL libva-android.sh with RHIZO_INPUT_CACHE=no-cache exits 1 ($out)"; fail=1; }
  grep -q -- '-Ddriverdir=/vendor/lib64/dri\|DRIVER_DIR=/vendor/lib64/dri' "$SELF" || { echo "FAIL libva-android.sh has DRIVER_DIR=/vendor/lib64/dri"; fail=1; }
  rm -rf "$t"
  if (( fail )); then echo "FAIL libva-android.sh --selftest"; return 1; fi
  echo "ok libva-android.sh --selftest"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") build_all; exit $? ;;
  *) echo "$0 [--selftest]" >&2; exit 2 ;;
esac
