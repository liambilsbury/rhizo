#!/bin/bash
# build libwayland-client libffi and protocol bindings
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../../test/vm/common.sh
source ./own-output-lib.sh
REPO_ROOT="$(cd "$(dirname "$SELF")/../../.." && pwd)"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
NDK="$REPO_ROOT/toolchain/ndk_extract/android-ndk-r27c"
NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
ARCH="x86_64"
WAYLAND_VERSION=1.22.0
LIBFFI_VERSION=3.4.6
PROTOCOLS_VERSION=1.45
PROTOCOLS=(stable/xdg-shell/xdg-shell stable/linux-dmabuf/linux-dmabuf-v1 stable/viewporter/viewporter stable/presentation-time/presentation-time staging/xdg-activation/xdg-activation-v1 unstable/xdg-decoration/xdg-decoration-unstable-v1 staging/fractional-scale/fractional-scale-v1 staging/cursor-shape/cursor-shape-v1 unstable/tablet/tablet-unstable-v2)

# print the object file name for a generated wayland source
wayland_obj_name() { echo "gen_ndk_wayland_$(basename "$1" | tr '-' '_').cpp.o"; }

# check the cache holds the file
need_input() {
  [[ -f "$CACHE/$1/$2" ]] || { log "no $2 in $CACHE/$1 -- run tools/fetch/build-inputs.sh --only $1"; return 1; }
}

# build the wayland libraries and protocol objects
build_all() {
  local work prefix native CC OUT OBJ_DIR CROSS_FILE CONFIG_HOST GSI_LIBS_DIR TARGET_DESC
  if [[ "$ARCH" == aarch64 ]]; then
    CC="$NDK_BIN/aarch64-linux-android35-clang"
    OUT="$REPO_ROOT/toolchain/wayland-android-arm64"
    OBJ_DIR="$REPO_ROOT/toolchain/out/arm64/gen"
    CROSS_FILE="$REPO_ROOT/tools/mesa/mesa-cross-aarch64-android"
    CONFIG_HOST="aarch64-linux-android"
    GSI_LIBS_DIR="$VAR_DIR/share/gsi_libs_arm64"
    TARGET_DESC="aarch64-linux-android"
  else
    CC="$NDK_BIN/x86_64-linux-android35-clang"
    OUT="$REPO_ROOT/toolchain/wayland-android"
    OBJ_DIR="$REPO_ROOT/toolchain/out/gen"
    CROSS_FILE="$REPO_ROOT/tools/mesa/mesa-cross-x86_64-android"
    CONFIG_HOST="x86_64-linux-android"
    GSI_LIBS_DIR="$VAR_DIR/share/gsi_libs"
    TARGET_DESC="x86_64-linux-android"
  fi
  own_output "$(dirname "$OUT")" "$OBJ_DIR" || return 1
  [[ -x "$CC" ]] || { log "no NDK compiler at $CC -- run tools/fetch/build-inputs.sh --only ndk"; return 1; }
  need_input wayland "wayland-$WAYLAND_VERSION.tar.xz" || return 1
  need_input libffi "libffi-$LIBFFI_VERSION.tar.gz" || return 1
  need_input wlprotocols "wayland-protocols-$PROTOCOLS_VERSION.tar.xz" || return 1
  [[ -f "$CROSS_FILE" ]] || { log "no meson cross file at $CROSS_FILE"; return 1; }
  command -v meson >/dev/null || { log "meson is not installed"; return 1; }
  command -v ninja >/dev/null || { log "ninja is not installed"; return 1; }
  work=$(mktemp -d "$REPO_ROOT/toolchain/wayland-android.build.XXXXXX")
  prefix="$work/prefix"; native="$work/native"
  tar -xf "$CACHE/libffi/libffi-$LIBFFI_VERSION.tar.gz" -C "$work" || return 1
  tar -xf "$CACHE/wayland/wayland-$WAYLAND_VERSION.tar.xz" -C "$work" || return 1
  tar -xf "$CACHE/wlprotocols/wayland-protocols-$PROTOCOLS_VERSION.tar.xz" -C "$work" || return 1

  log "libffi $LIBFFI_VERSION for $TARGET_DESC (static)"
  ( cd "$work/libffi-$LIBFFI_VERSION" \
    && ./configure --quiet --host="$CONFIG_HOST" --disable-shared --enable-static --disable-docs \
         --prefix="$prefix" CC="$CC" AR="$NDK_BIN/llvm-ar" RANLIB="$NDK_BIN/llvm-ranlib" STRIP="$NDK_BIN/llvm-strip" \
    && make -s -j"$(nproc)" && make -s install ) > "$work/libffi.log" 2>&1 \
    || { log "libffi build failed -- see $work/libffi.log"; return 1; }

  log "wayland-scanner $WAYLAND_VERSION for this host"
  ( cd "$work/wayland-$WAYLAND_VERSION" \
    && meson setup "$native" --prefix="$prefix/native" -Dlibraries=false -Dscanner=true -Dtests=false \
         -Ddocumentation=false -Ddtd_validation=false \
    && ninja -C "$native" install ) > "$work/scanner.log" 2>&1 \
    || { log "wayland-scanner build failed (expat headers on this host?) -- see $work/scanner.log"; return 1; }
  local scanner="$prefix/native/bin/wayland-scanner"
  [[ -x "$scanner" ]] || { log "no scanner at $scanner after the native build"; return 1; }

  log "libwayland-client $WAYLAND_VERSION for $TARGET_DESC (static)"
  ( cd "$work/wayland-$WAYLAND_VERSION" \
    && PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH='' \
       PKG_CONFIG_PATH_FOR_BUILD="$prefix/native/lib/x86_64-linux-gnu/pkgconfig:$prefix/native/lib/pkgconfig" \
       meson setup "$work/cross" --cross-file "$CROSS_FILE" --prefix="$prefix" \
         --default-library=static -Dlibraries=true -Dscanner=false -Dtests=false -Ddocumentation=false -Ddtd_validation=false \
    && ninja -C "$work/cross" install ) > "$work/wayland.log" 2>&1 \
    || { log "libwayland-client cross build failed -- see $work/wayland.log"; return 1; }

  rm -rf "$OUT.part"; mkdir -p "$OUT.part/include" "$OUT.part/lib" "$OUT.part/protocol-gen"
  cp "$prefix/lib/libffi.a" "$prefix/lib/libwayland-client.a" "$OUT.part/lib/" || return 1
  cp "$prefix/include/ffi.h" "$prefix/include/ffitarget.h" \
     "$prefix/include/wayland-client.h" "$prefix/include/wayland-client-core.h" "$prefix/include/wayland-client-protocol.h" \
     "$prefix/include/wayland-util.h" "$prefix/include/wayland-version.h" "$OUT.part/include/" || return 1

  log "protocol bindings from wayland-protocols $PROTOCOLS_VERSION"
  local p xml base obj
  mkdir -p "$OBJ_DIR"
  for p in "${PROTOCOLS[@]}"; do
    xml="$work/wayland-protocols-$PROTOCOLS_VERSION/$p.xml"; base=$(basename "$p")
    [[ -f "$xml" ]] || { log "no $xml in the wayland-protocols tarball"; return 1; }
    "$scanner" client-header "$xml" "$OUT.part/protocol-gen/$base-client-protocol.h" || return 1
    "$scanner" private-code "$xml" "$OUT.part/protocol-gen/$base-protocol.c" || return 1
    obj="$OBJ_DIR/$(wayland_obj_name "$base")"
    "$CC" -c -O2 -fPIC -I "$OUT.part/include" -o "$obj.part" "$OUT.part/protocol-gen/$base-protocol.c" || return 1
    mv "$obj.part" "$obj"
  done
  rm -rf "$OUT" && mv "$OUT.part" "$OUT"
  mkdir -p "$GSI_LIBS_DIR"
  cp --remove-destination "$OUT/lib/libffi.a" "$OUT/lib/libwayland-client.a" "$GSI_LIBS_DIR/" || return 1
  rm -rf "$work"
  log "staged ${OUT#$REPO_ROOT/}: $(ls "$OUT/include" | wc -l) headers, 2 static libs, ${#PROTOCOLS[@]} protocols; objects in ${OBJ_DIR#$REPO_ROOT/}"
}

# test the protocol object names and need_input
selftest() {
  local fail=0 p names="" out tmp
  for p in "${PROTOCOLS[@]}"; do names+=" $(wayland_obj_name "$(basename "$p")")"; done
  for p in gen_ndk_wayland_xdg_shell.cpp.o gen_ndk_wayland_linux_dmabuf_v1.cpp.o gen_ndk_wayland_viewporter.cpp.o gen_ndk_wayland_presentation_time.cpp.o gen_ndk_wayland_xdg_activation_v1.cpp.o gen_ndk_wayland_xdg_decoration_unstable_v1.cpp.o; do
    [[ "$names" == *" $p"* ]] || { echo "SELFTEST FAILED: $p is not among the staged object names:$names"; fail=1; }
  done
  grep -q -- '--aidl wayland' "$REPO_ROOT/tools/build/hal/composer.sh" || { echo "SELFTEST FAILED: composer.sh no longer links the wayland objects with --aidl wayland"; fail=1; }
  tmp=$(mktemp -d) || return 1
  mkdir -p "$tmp/main/toolchain/out/gen" "$tmp/wt/own/out/gen"
  ln -s "$tmp/main/toolchain" "$tmp/wt/toolchain"
  out=$(REPO_ROOT="$tmp/wt" own_output "$tmp/wt/toolchain" "$tmp/wt/toolchain/out/gen" 2>&1)
  [[ $? -ne 0 && "$out" == *"toolchain resolves to $tmp/main/toolchain"*"rm toolchain && cp -a --reflink=auto $tmp/main/toolchain toolchain" ]] || { echo "SELFTEST FAILED: a toolchain linked to another checkout was not refused by name -- got: $out"; fail=1; }
  REPO_ROOT="$tmp/wt" own_output "$tmp/wt/own" "$tmp/wt/own/out/gen" >/dev/null 2>&1 || { echo "SELFTEST FAILED: a checkout's own output folders were refused"; fail=1; }
  rm -rf "$tmp"
  out=$(CACHE=/nonexistent need_input wayland "wayland-$WAYLAND_VERSION.tar.xz" 2>&1)
  [[ $? -ne 0 && "$out" == *"build-inputs.sh --only wayland"* ]] || { echo "SELFTEST FAILED: a missing tarball was not refused naming the fetch -- got: $out"; fail=1; }
  if (( fail )); then echo "wayland-android.sh selftest: FAILED"; return 1; fi
  echo "wayland-android.sh selftest: ok"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --selftest) selftest; exit $? ;;
    *) echo "usage: $0 [--arch x86_64|aarch64] [--selftest]" >&2; exit 2 ;;
  esac
done
build_all
