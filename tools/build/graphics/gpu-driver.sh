#!/bin/bash
# build the Mesa virgl and llvmpipe drivers
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../../test/vm/common.sh
REPO_ROOT="$(cd "$(dirname "$SELF")/../../.." && pwd)"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
SHARE_ROOT="$VAR_DIR/share"
MESA_SRC="$REPO_ROOT/mesa-src"
NDK="$REPO_ROOT/toolchain/ndk_extract/android-ndk-r27c"
MESA_VERSION=25.2.8
LLVM_VERSION=18.1.8
MESON_MIN=1.4.0
ARCHES=(x86_64 x86)

# print the stage folder name for an arch
stage_dir_for() { [[ "$1" == x86_64 ]] && echo gpu_driver || echo gpu_driver_32; }
# print the gsi_libs folder for an arch
gsi_libs_for()  { [[ "$1" == x86_64 ]] && echo "$SHARE_ROOT/gsi_libs" || echo "$SHARE_ROOT/gsi_libs_32"; }

# print the support library NAME=PATH lines
support_libs_for() {
  local g; g=$(gsi_libs_for "$1")
  echo "libcutils.so=$g/libcutils.so"
  echo "libz.so=$g/libz.so"
  if [[ "$1" == x86_64 ]]; then echo "libhardware.so=@BUILD@/src/android_stub/libhardware.so"
  else echo "libhardware.so=$g/libhardware.so"; fi
}

# check that the installed meson is at least MESON_MIN
meson_new_enough() {
  local v; v=$(meson --version 2>/dev/null) || { log "meson is not installed"; return 1; }
  [[ "$(printf '%s\n%s\n' "$MESON_MIN" "$v" | sort -V | head -1)" == "$MESON_MIN" ]] \
    || { log "meson $v is older than $MESON_MIN, which Mesa $MESA_VERSION needs (pip install --user meson)"; return 1; }
}

# check the build inputs
preflight() {
  "$REPO_ROOT/tools/fetch/build-inputs.sh" --only mesa --only libdrm --check >/dev/null 2>&1 \
    || { log "mesa-src is not the pinned, patched tree -- run tools/fetch/build-inputs.sh --only mesa --only libdrm"; return 1; }
  [[ -x "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android35-clang" ]] \
    || { log "no NDK at $NDK -- run tools/fetch/build-inputs.sh --only ndk"; return 1; }
  meson_new_enough || return 1
  command -v patchelf >/dev/null || { log "patchelf is not installed"; return 1; }
  local a g n
  for a in "${ARCHES[@]}"; do
    g=$(gsi_libs_for "$a")
    for n in libcutils.so libz.so libbase.so libc++.so; do
      [[ -f "$g/$n" ]] || { log "no $n in $g -- run tools/build/image/extract-gsi-libs.sh"; return 1; }
    done
  done
  [[ -f "$SHARE_ROOT/gsi_libs_32/libhardware.so" ]] || { log "no libhardware.so in gsi_libs_32 -- run tools/build/image/extract-gsi-libs.sh"; return 1; }
}

# build and stage the aarch64 Mesa driver
build_aarch64() {
  local g="$SHARE_ROOT/gsi_libs_arm64" out="$SHARE_ROOT/gpu_driver_arm64" args=() build
  local clangxx="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang++"
  [[ -x "$clangxx" ]] || { log "no NDK at $clangxx -- run tools/fetch/build-inputs.sh --only ndk"; return 1; }
  [[ -f "$REPO_ROOT/tools/mesa/mesa-cross-aarch64-android" ]] || { log "no cross file at $REPO_ROOT/tools/mesa/mesa-cross-aarch64-android"; return 1; }
  meson_new_enough || return 1
  "$REPO_ROOT/tools/fetch/build-inputs.sh" --only mesa --only libdrm --check >/dev/null 2>&1 \
    || { log "mesa-src is not the pinned, patched tree -- run tools/fetch/build-inputs.sh --only mesa --only libdrm"; return 1; }
  local n; for n in libcutils.so libz.so libbase.so libc++.so; do
    [[ -f "$g/$n" ]] || { log "no $n in $g -- run tools/build/image/extract-gsi-libs.sh --arch aarch64"; return 1; }
  done
  args=(--support-lib "libcutils.so=$g/libcutils.so" --support-lib "libz.so=$g/libz.so" \
        --support-lib "libhardware.so=@BUILD@/src/android_stub/libhardware.so")
  log "softpipe+zink for aarch64 -> ${out#$REPO_ROOT/}"
  RHIZO_SHARE_ROOT="$SHARE_ROOT" "$REPO_ROOT/tools/build/graphics/mesa.sh" --variant zink --gallium-drivers=softpipe,zink \
      --arch aarch64 --stage gpu_driver_arm64 "${args[@]}" \
    || { log "mesa.sh failed for aarch64"; return 1; }
  cp --remove-destination "$g/libbase.so" "$g/libc++.so" "$out/lib/" || return 1
  verify_staged "$out" 64 aarch64 || return 1
  build="$MESA_SRC/build-android-aarch64-zink"
  mkdir -p "$SHARE_ROOT/gfx_hal_arm64"
  cp --remove-destination "$out/lib/libgallium_dri.so" "$out/lib/libgbm_mesa.so" "$out/lib/libdrm.so" "$SHARE_ROOT/gfx_hal_arm64/" || return 1
  cp --remove-destination "$build/src/gbm/backends/dri/dri_gbm.so" "$SHARE_ROOT/gfx_hal_arm64/dri_gbm.so" || { log "no dri_gbm.so in $build"; return 1; }
  cp --remove-destination "$g/libcutils.so" "$SHARE_ROOT/gfx_hal_arm64/libcutils_real.so" || return 1
  cp --remove-destination "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$SHARE_ROOT/gfx_hal_arm64/libc++_shared.so" || return 1
  cp --remove-destination "$out/lib/libgbm_mesa.so" "$g/libgbm_mesa.so" || return 1
  log "staged gfx_hal_arm64/: 5 driver-independent files + gpu_driver_arm64/ ($(du -sh "$out" | cut -f1) stripped)"
}

# check whether `file -b` output names a want-bit x86 ELF
x86_elf_ok() {
  case "$1:$2" in
    64:ELF\ 64-bit*x86-64*|32:ELF\ 32-bit*Intel\ 80386*|32:ELF\ 32-bit*Intel\ i386*) return 0 ;;
  esac
  return 1
}

# check the staged .so files in a directory
verify_staged() {
  local dir="$1" want="$2" mach="${3:-x86}" f hdr so needed ver
  for f in "$dir"/egl/*.so "$dir"/lib/*.so; do
    [[ -f "$f" ]] || { log "no .so files under $dir"; return 1; }
    hdr=$(file -b "$f")
    if [[ "$mach" == aarch64 ]]; then
      case "$want:$hdr" in
        64:ELF\ 64-bit*ARM\ aarch64*) ;;
        *) log "$f is not a ${want}-bit aarch64 ELF: $hdr"; return 1 ;;
      esac
    else
      x86_elf_ok "$want" "$hdr" || { log "$f is not a ${want}-bit x86 ELF: $hdr"; return 1; }
    fi
  done
  for f in "$dir"/egl/*.so; do
    so=$(patchelf --print-soname "$f")
    [[ "$so" == "$(basename "$f")" ]] || { log "$f has SONAME '$so', the loader wants $(basename "$f")"; return 1; }
  done
  needed=$(patchelf --print-needed "$dir/lib/libgallium_dri.so")
  [[ "$needed" == *libz.so* && "$needed" != *libz.so.1* ]] || { log "$dir/lib/libgallium_dri.so must need libz.so, not libz.so.1: $needed"; return 1; }
  ver=$(strings -n 8 "$dir/lib/libgallium_dri.so" | grep -oE 'Mesa [0-9]+\.[0-9]+\.[0-9]+' | sort -u)
  [[ "$ver" == "Mesa $MESA_VERSION" ]] || { log "$dir/lib/libgallium_dri.so reports '$ver', wanted Mesa $MESA_VERSION"; return 1; }
}

# build and stage the virgl driver
build_arch() {
  local a="$1" stage g out args=() line
  stage=$(stage_dir_for "$a"); g=$(gsi_libs_for "$a"); out="$SHARE_ROOT/$stage"
  while IFS= read -r line; do args+=(--support-lib "$line"); done < <(support_libs_for "$a")
  log "virgl for $a -> ${out#$REPO_ROOT/}"
  RHIZO_SHARE_ROOT="$SHARE_ROOT" "$REPO_ROOT/tools/build/graphics/mesa.sh" --variant virgl --arch "$a" --stage "$stage" "${args[@]}" \
    || { log "mesa.sh failed for $a"; return 1; }
  cp --remove-destination "$g/libbase.so" "$g/libc++.so" "$out/lib/" || return 1
  verify_staged "$out" "$([[ "$a" == x86_64 ]] && echo 64 || echo 32)" || return 1
  if [[ "$a" == x86_64 ]]; then
    mkdir -p "$SHARE_ROOT/gfx_hal"
    cp --remove-destination "$out/lib/libgallium_dri.so" "$out/lib/libgbm_mesa.so" "$out/lib/libdrm.so" "$out/lib/dri_gbm.so" "$SHARE_ROOT/gfx_hal/" || return 1
    cp --remove-destination "$g/libcutils.so" "$SHARE_ROOT/gfx_hal/libcutils_real.so" || return 1
    cp --remove-destination "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/libc++_shared.so" "$SHARE_ROOT/gfx_hal/libc++_shared.so" || return 1
    cp --remove-destination "$out/lib/libgbm_mesa.so" "$g/libgbm_mesa.so" || return 1
  fi
}

# build and stage the llvmpipe driver set
build_software() {
  local out="$SHARE_ROOT/gpu_driver_software" g; g=$(gsi_libs_for x86_64)
  log "llvmpipe for x86_64 -> ${out#$REPO_ROOT/}"
  bash "$REPO_ROOT/tools/build/toolchain/llvm-android.sh" || return 1
  RHIZO_SHARE_ROOT="$SHARE_ROOT" "$REPO_ROOT/tools/build/graphics/mesa.sh" --variant software --arch x86_64 \
    || { log "mesa.sh failed for the software set"; return 1; }
  cp --remove-destination "$g/libbase.so" "$g/libc++.so" "$out/lib/" || return 1
  verify_staged "$out" 64
}

# print the driver sets' sources and staged files
provenance_text() {
  local f d dir tarball="$CACHE/mesa/mesa-$MESA_VERSION.tar.xz" llvm_tar="$CACHE/llvm/llvm-project-$LLVM_VERSION.src.tar.xz" src
  src="mesa-src/ (VERSION $(cat "$MESA_SRC/VERSION" 2>/dev/null))"
  [[ -f "$tarball" ]] && src="mesa-$MESA_VERSION.tar.xz sha256 $(sha256sum "$tarball" | cut -d' ' -f1)"
  echo "gpu_driver and gpu_driver_32: Mesa $MESA_VERSION virgl for x86_64 and x86, built by tools/build/graphics/gpu-driver.sh"
  echo "gpu_driver_software: Mesa $MESA_VERSION llvmpipe for x86_64 with LLVM $LLVM_VERSION (Apache-2.0 WITH LLVM-exception), built by tools/build/graphics/gpu-driver.sh"
  echo "license: MIT; support libraries per NOTICE and debian/copyright"
  echo "mesa-source: $src"
  [[ -f "$llvm_tar" ]] && echo "llvm-source: llvm-project-$LLVM_VERSION.src.tar.xz sha256 $(sha256sum "$llvm_tar" | cut -d' ' -f1)"
  echo "ndk: $(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties" 2>/dev/null) at $NDK"
  for f in "$REPO_ROOT"/tools/patches/mesa/*.patch; do echo "patch: $(basename "$f") sha256 $(sha256sum "$f" | cut -d' ' -f1)"; done
  for d in $(stage_dir_for x86_64) $(stage_dir_for x86) gpu_driver_software; do
    dir="$SHARE_ROOT/$d"
    for f in "$dir"/egl/*.so "$dir"/lib/*.so; do
      [[ -f "$f" ]] || continue
      echo "file: $d/${f#$dir/} sha256 $(sha256sum "$f" | cut -d' ' -f1) soname $(patchelf --print-soname "$f" 2>/dev/null || echo -)"
    done
  done
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# write and stamp gpu_driver.PROVENANCE
write_provenance() {
  local p="$SHARE_ROOT/gpu_driver.PROVENANCE"
  provenance_text > "$p.part" && mv "$p.part" "$p"
  python3 "$REPO_ROOT"/tools/build/stamps.py stamp gpu_driver.PROVENANCE || return 1
  log "provenance -> ${p#$REPO_ROOT/}"
}

# test the driver staging helpers
selftest() {
  local fail=0 out tmp
  out=$(support_libs_for x86_64)
  [[ "$out" == *"libhardware.so=@BUILD@/src/android_stub/libhardware.so"* ]] || { echo "SELFTEST FAILED: x86_64 must take libhardware from the Mesa build -- got: $out"; fail=1; }
  out=$(support_libs_for x86)
  [[ "$out" == *"libhardware.so=$SHARE_ROOT/gsi_libs_32/libhardware.so"* ]] || { echo "SELFTEST FAILED: x86 must take libhardware from the GSI -- got: $out"; fail=1; }
  [[ "$(stage_dir_for x86)" == gpu_driver_32 && "$(stage_dir_for x86_64)" == gpu_driver ]] || { echo "SELFTEST FAILED: stage dirs changed"; fail=1; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN; mkdir -p "$tmp/egl" "$tmp/lib"
  if cc -shared -fPIC -Wl,-soname,libEGL_rhizo.so -o "$tmp/egl/libEGL_rhizo.so" -x c /dev/null 2>/dev/null \
     && cc -shared -fPIC -Wl,-soname,libgallium_dri.so -Wl,--no-as-needed -lz -o "$tmp/lib/libgallium_dri.so" -x c - <<<'const char v[] = "Mesa 25.2.8 (fixture)";' 2>/dev/null; then
    out=$(verify_staged "$tmp" 64 2>&1)
    [[ $? -ne 0 && "$out" == *"must need libz.so, not libz.so.1"* ]] || { echo "SELFTEST FAILED: a driver needing the host's libz.so.1 was not refused -- got: $out"; fail=1; }
    patchelf --replace-needed libz.so.1 libz.so "$tmp/lib/libgallium_dri.so"
    verify_staged "$tmp" 64 >/dev/null 2>&1 || { echo "SELFTEST FAILED: a well-formed fixture tree was refused: $(verify_staged "$tmp" 64 2>&1)"; fail=1; }
    patchelf --set-soname wrong.so "$tmp/egl/libEGL_rhizo.so"
    out=$(verify_staged "$tmp" 64 2>&1)
    [[ $? -ne 0 && "$out" == *"has SONAME 'wrong.so'"* ]] || { echo "SELFTEST FAILED: a wrong SONAME was not refused -- got: $out"; fail=1; }
    patchelf --set-soname libEGL_rhizo.so "$tmp/egl/libEGL_rhizo.so"
    cc -shared -fPIC -Wl,-soname,libgallium_dri.so -Wl,--no-as-needed -lz -o "$tmp/lib/libgallium_dri.so" -x c - <<<'const char v[] = "Mesa 24.0.0 (fixture)";' 2>/dev/null
    patchelf --replace-needed libz.so.1 libz.so "$tmp/lib/libgallium_dri.so"
    out=$(verify_staged "$tmp" 64 2>&1)
    [[ $? -ne 0 && "$out" == *"reports 'Mesa 24.0.0', wanted Mesa $MESA_VERSION"* ]] || { echo "SELFTEST FAILED: another Mesa version was not refused -- got: $out"; fail=1; }
    out=$(verify_staged "$tmp" 32 2>&1)
    [[ $? -ne 0 && "$out" == *"not a 32-bit x86 ELF"* ]] || { echo "SELFTEST FAILED: a 64-bit tree passed as 32-bit -- got: $out"; fail=1; }
  else
    echo "SELFTEST SKIPPED: no host cc with zlib to build the fixture driver"
  fi
  rm -rf "$tmp"
  x86_elf_ok 32 "ELF 32-bit LSB shared object, Intel 80386, version 1 (SYSV), dynamically linked" \
    || { echo "SELFTEST FAILED: file's Intel 80386 wording was not read as 32-bit x86"; fail=1; }
  x86_elf_ok 32 "ELF 32-bit LSB shared object, Intel i386, version 1 (SYSV), dynamically linked" \
    || { echo "SELFTEST FAILED: file 5.46 and later's Intel i386 wording was not read as 32-bit x86"; fail=1; }
  x86_elf_ok 32 "ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked" \
    && { echo "SELFTEST FAILED: a 64-bit ELF was read as 32-bit x86"; fail=1; }
  grep -q 'gpu_driver_software: Mesa' <(provenance_text) \
    || { echo "SELFTEST FAILED: the provenance does not name gpu_driver_software"; fail=1; }
  "$SELF" --arch arm64 >/dev/null 2>&1 && { echo "SELFTEST FAILED: --arch arm64 was accepted"; fail=1; }
  [[ -f "$REPO_ROOT/tools/mesa/mesa-cross-aarch64-android" ]] || { echo "SELFTEST FAILED: no tools/mesa/mesa-cross-aarch64-android cross file at repo root"; fail=1; }
  grep -q "cpu_family = 'aarch64'" "$REPO_ROOT/tools/mesa/mesa-cross-aarch64-android" 2>/dev/null \
    || { echo "SELFTEST FAILED: tools/mesa/mesa-cross-aarch64-android does not declare cpu_family aarch64"; fail=1; }
  if (( fail )); then echo "gpu-driver.sh selftest: FAILED"; return 1; fi
  echo "gpu-driver.sh selftest: ok"
}

WANT=both
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) WANT="$2"; shift 2 ;;
    --share-root) SHARE_ROOT="$2"; shift 2 ;;
    --selftest) selftest; exit $? ;;
    *) echo "usage: $0 [--arch x86_64|x86|aarch64|both] [--share-root DIR] [--selftest]" >&2; exit 2 ;;
  esac
done
case "$WANT" in
  both) ;;
  x86_64|x86) ARCHES=("$WANT") ;;
  aarch64) build_aarch64; exit $? ;;
  *) log "--arch wants x86_64, x86, aarch64 or both, got '$WANT'"; exit 2 ;;
esac
preflight || exit 1
for a in "${ARCHES[@]}"; do build_arch "$a" || exit 1; done
if [[ " ${ARCHES[*]} " == *" x86_64 "* ]]; then build_software || exit 1; fi
[[ "$WANT" == both ]] && { write_provenance || exit 1; }
exit 0
