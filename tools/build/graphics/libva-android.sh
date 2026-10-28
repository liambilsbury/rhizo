#!/bin/bash
# build libva and libva-drm for x86_64 Android
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

# print an ELF's sorted NEEDED names on one line
needed_of() { readelf -dW "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | tr '\n' ' ' | sed 's/ $//'; }

# check an ELF's soname and NEEDED set
check_elf() {
  local f="$1" soname="$2" want="$3" have got
  have=$(readelf -dW "$f" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
  [[ "$have" == "$soname" ]] || { log "$f has SONAME '$have', want $soname"; return 1; }
  got=$(needed_of "$f"); want=$(tr ' ' '\n' <<<"$want" | sort | tr '\n' ' ' | sed 's/ $//')
  [[ "$got" == "$want" ]] || { log "$f needs [$got], want [$want]"; return 1; }
}

# check the built libva tree
check_tree() {
  local root="$1" lib="$1/vendor/lib64" f
  check_elf "$lib/libva.so" libva.so "$LIBVA_NEEDED" || return 1
  check_elf "$lib/libva-drm.so" libva-drm.so "$LIBVA_DRM_NEEDED" || return 1
  file -b "$lib/libva.so" | grep 'ELF 64-bit.*x86-64' >/dev/null || { log "$lib/libva.so is not an x86-64 ELF"; return 1; }
  strings -n 8 "$lib/libva.so" | grep -x "$DRIVER_DIR" >/dev/null || { log "$lib/libva.so does not carry the driver path $DRIVER_DIR"; return 1; }
  for f in libva-android.so libva-x11.so libva-glx.so libva-wayland.so; do
    [[ ! -e "$lib/$f" ]] || { log "$lib/$f was built; only libva and libva-drm may be"; return 1; }
  done
  grep -q '^Version: 1\.22\.0$' "$lib/pkgconfig/libva.pc" || { log "$lib/pkgconfig/libva.pc is not VA-API 1.22.0"; return 1; }
  [[ -f "$root/vendor/include/va/va_drm.h" ]] || { log "no va/va_drm.h under $root/vendor/include"; return 1; }
}

# build libdrm, libva and libva-drm
build_all() {
  local work rc=0
  own_output "$(dirname "$OUT")" || return 1
  [[ -f "$CROSS_FILE" ]] || { log "no meson cross file at $CROSS_FILE"; return 1; }
  "$REPO_ROOT/tools/fetch/build-inputs.sh" --only libva --only libdrm --check >/dev/null 2>&1 \
    || { log "libva or libdrm is not the pinned source -- run tools/fetch/build-inputs.sh --only mesa --only libdrm --only libva"; return 1; }
  [[ -f "$LIBVA_TARBALL" && -f "$LIBDRM_TARBALL" ]] || { log "no $LIBVA_TARBALL or $LIBDRM_TARBALL"; return 1; }
  command -v meson >/dev/null && command -v ninja >/dev/null || { log "meson and ninja are needed"; return 1; }
  work=$(mktemp -d "$REPO_ROOT/toolchain/libva-android.build.XXXXXX") || return 1
  tar -xf "$LIBDRM_TARBALL" -C "$work" && tar -xf "$LIBVA_TARBALL" -C "$work" || { log "cannot unpack the libdrm and libva sources"; rm -rf "$work"; return 1; }

  log "libdrm $LIBDRM_VERSION for x86_64-linux-android (to link libva-drm against; Mesa's copy ships)"
  ( PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH='' meson setup "$work/drm-build" "$work/libdrm-$LIBDRM_VERSION" \
      --cross-file "$CROSS_FILE" --prefix="$work/drm-prefix" --libdir=lib --buildtype=release \
      -Dintel=disabled -Damdgpu=disabled -Dradeon=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
      -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled \
      -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dinstall-test-programs=false \
      -Dudev=false && ninja -C "$work/drm-build" install ) > "$work/libdrm.log" 2>&1 \
    || { log "libdrm build failed -- see $work/libdrm.log"; return 1; }

  log "libva $LIBVA_VERSION + libva-drm for x86_64-linux-android, drivers from $DRIVER_DIR"
  ( PKG_CONFIG_LIBDIR="$work/drm-prefix/lib/pkgconfig" PKG_CONFIG_PATH='' \
      meson setup "$work/va-build" "$work/libva-$LIBVA_VERSION" \
      --cross-file "$CROSS_FILE" --prefix=/vendor --libdir=lib64 --sysconfdir=etc --buildtype=release \
      -Ddriverdir="$DRIVER_DIR" -Ddisable_drm=false -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no \
      -Denable_docs=false && DESTDIR="$work/stage" ninja -C "$work/va-build" install ) > "$work/libva.log" 2>&1 \
    || { log "libva build failed -- see $work/libva.log"; return 1; }
  check_tree "$work/stage" || { log "the built libva failed its checks -- $work kept"; return 1; }

  rm -rf "$OUT.part" && mv "$work/stage" "$OUT.part" || rc=1
  printf 'libva %s from %s sha256 %s, libdrm %s for linking from %s sha256 %s, by %s\n' \
    "$LIBVA_VERSION" "${LIBVA_TARBALL##*/}" "$(sha256sum "$LIBVA_TARBALL" | cut -d' ' -f1)" \
    "$LIBDRM_VERSION" "${LIBDRM_TARBALL##*/}" "$(sha256sum "$LIBDRM_TARBALL" | cut -d' ' -f1)" \
    "tools/build/graphics/libva-android.sh" > "$OUT.part/SOURCE" || rc=1
  (( rc == 0 )) && rm -rf "$OUT" && mv "$OUT.part" "$OUT" || { log "cannot place $OUT"; return 1; }
  rm -rf "$work"
  log "staged ${OUT#"$REPO_ROOT"/}: vendor/lib64/{libva.so,libva-drm.so} ($(needed_of "$OUT/vendor/lib64/libva-drm.so")), headers, pkg-config"
}

# test the ELF checks
selftest() {
  local fail=0 t out
  t=$(mktemp -d)
  if command -v cc >/dev/null; then
    cc -shared -fPIC -Wl,-soname,libva.so -o "$t/libva.so" -x c /dev/null 2>/dev/null
    cc -shared -fPIC -Wl,-soname,libother.so -o "$t/libother.so" -x c /dev/null 2>/dev/null
    out=$(check_elf "$t/libother.so" libva.so "libc.so" 2>&1)
    [[ $? -ne 0 && "$out" == *"has SONAME 'libother.so', want libva.so"* ]] || { echo "SELFTEST FAILED: a wrong SONAME was not refused -- got: $out"; fail=1; }
    out=$(check_elf "$t/libva.so" libva.so "libdl.so libc.so" 2>&1)
    [[ $? -ne 0 && "$out" == *"want [libc.so libdl.so]"* ]] || { echo "SELFTEST FAILED: a NEEDED set other than the wanted one was not refused -- got: $out"; fail=1; }
  else
    echo "SELFTEST SKIPPED: no host cc for the ELF fixtures"
  fi
  out=$(RHIZO_INPUT_CACHE="$t/no-cache" "$SELF" 2>&1)
  [[ $? -ne 0 && "$out" == *"is not the pinned source"* ]] || { echo "SELFTEST FAILED: a cache without the pinned libva was not refused -- got: $out"; fail=1; }
  grep -q -- '-Ddriverdir=/vendor/lib64/dri\|DRIVER_DIR=/vendor/lib64/dri' "$SELF" || { echo "SELFTEST FAILED: the driver dir is no longer /vendor/lib64/dri"; fail=1; }
  rm -rf "$t"
  if (( fail )); then echo "libva-android.sh selftest: FAILED"; return 1; fi
  echo "libva-android.sh selftest: ok"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") build_all; exit $? ;;
  *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac
