#!/bin/bash
# var/share/gpu_driver* var/share/gfx_hal var/share/gpu_driver.PROVENANCE RHIZO_INPUT_CACHE=
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../env.sh
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
# print the amd stage folder name for an arch
amd_stage_dir_for() { [[ "$1" == x86_64 ]] && echo gpu_driver_amd || echo gpu_driver_amd_32; }
PLATFORM_NEEDED="libc.so libm.so libdl.so liblog.so libsync.so libnativewindow.so libvndksupport.so"
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
  local v; v=$(meson --version 2>/dev/null) || { log "no meson in PATH"; return 1; }
  [[ "$(printf '%s\n%s\n' "$MESON_MIN" "$v" | sort -V | head -1)" == "$MESON_MIN" ]] \
    || { log "meson $v is older than $MESON_MIN"; return 1; }
}

# check the build inputs
preflight() {
  "$REPO_ROOT/tools/fetch/build-inputs.sh" --only mesa --only libdrm --only libva --check >/dev/null 2>&1 \
    || { log "tools/fetch/build-inputs.sh --only mesa --only libdrm --only libva --check failed"; return 1; }
  [[ -x "$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android35-clang" ]] \
    || { log "no x86_64-linux-android35-clang in $NDK"; return 1; }
  meson_new_enough || return 1
  command -v patchelf >/dev/null || { log "no patchelf in PATH"; return 1; }
  local a g n
  for a in "${ARCHES[@]}"; do
    g=$(gsi_libs_for "$a")
    for n in libcutils.so libz.so libbase.so libc++.so; do
      [[ -f "$g/$n" ]] || { log "no $g/$n"; return 1; }
    done
  done
  [[ -f "$SHARE_ROOT/gsi_libs_32/libhardware.so" ]] || { log "no $SHARE_ROOT/gsi_libs_32/libhardware.so"; return 1; }
}

# build and stage the aarch64 Mesa driver
build_aarch64() {
  local g="$SHARE_ROOT/gsi_libs_arm64" out="$SHARE_ROOT/gpu_driver_arm64" args=() build
  local clangxx="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang++"
  [[ -x "$clangxx" ]] || { log "no $clangxx"; return 1; }
  [[ -f "$REPO_ROOT/tools/mesa/mesa-cross-aarch64-android" ]] || { log "no $REPO_ROOT/tools/mesa/mesa-cross-aarch64-android"; return 1; }
  meson_new_enough || return 1
  "$REPO_ROOT/tools/fetch/build-inputs.sh" --only mesa --only libdrm --check >/dev/null 2>&1 \
    || { log "tools/fetch/build-inputs.sh --only mesa --only libdrm --check failed"; return 1; }
  local n; for n in libcutils.so libz.so libbase.so libc++.so; do
    [[ -f "$g/$n" ]] || { log "no $g/$n"; return 1; }
  done
  args=(--support-lib "libcutils.so=$g/libcutils.so" --support-lib "libz.so=$g/libz.so" \
        --support-lib "libhardware.so=@BUILD@/src/android_stub/libhardware.so")
  RHIZO_SHARE_ROOT="$SHARE_ROOT" "$REPO_ROOT/tools/build/graphics/mesa.sh" --variant zink --gallium-drivers=softpipe,zink \
      --arch aarch64 --stage gpu_driver_arm64 "${args[@]}" \
    || { log "mesa.sh failed for aarch64"; return 1; }
  cp --remove-destination "$g/libbase.so" "$g/libc++.so" "$out/lib/" || return 1
  verify_staged "$out" 64 aarch64 || return 1
  build="$MESA_SRC/build-android-aarch64-zink"
  mkdir -p "$SHARE_ROOT/gfx_hal_arm64"
  cp --remove-destination "$out/lib/libgallium_dri.so" "$out/lib/libgbm_mesa.so" "$out/lib/libdrm.so" "$SHARE_ROOT/gfx_hal_arm64/" || return 1
  cp --remove-destination "$build/src/gbm/backends/dri/dri_gbm.so" "$SHARE_ROOT/gfx_hal_arm64/dri_gbm.so" || { log "no $build/src/gbm/backends/dri/dri_gbm.so"; return 1; }
  cp --remove-destination "$g/libcutils.so" "$SHARE_ROOT/gfx_hal_arm64/libcutils_real.so" || return 1
  cp --remove-destination "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$SHARE_ROOT/gfx_hal_arm64/libc++_shared.so" || return 1
  cp --remove-destination "$out/lib/libgbm_mesa.so" "$g/libgbm_mesa.so" || return 1
  log "staged gfx_hal_arm64 files=5 and gpu_driver_arm64 size=$(du -sh "$out" | cut -f1)"
}

# return whether file -b output $2 is a $1-bit x86 ELF
x86_elf_ok() {
  case "$1:$2" in
    64:ELF\ 64-bit*x86-64*|32:ELF\ 32-bit*Intel\ 80386*|32:ELF\ 32-bit*Intel\ i386*) return 0 ;;
  esac
  return 1
}

# print the sorted NEEDED entries of an ELF on one line
needed_sorted() { readelf -dW "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | sort | tr '\n' ' ' | sed 's/ $//'; }

# check the staged ELFs' library dependencies
verify_needed_closed() {
  local dir="$1" f n own
  own=" $PLATFORM_NEEDED $(cd "$dir" && ls lib egl 2>/dev/null | tr '\n' ' ') "
  while IFS= read -r -d '' f; do
    for n in $(needed_sorted "$f"); do
      [[ "$own" == *" $n "* ]] || { log "${f#"$dir"/} NEEDED $n is not in $dir or PLATFORM_NEEDED ($PLATFORM_NEEDED)"; return 1; }
    done
  done < <(find "$dir" -type f -name '*.so' -print0)
}

# check the VA driver link and libva NEEDED entries of a staged tree
verify_va() {
  local dir="$1" name="$2" lib="$1/lib" link="$1/dri/$2_drv_video.so" s
  [[ -L "$link" && "$(readlink "$link")" == ../libgallium_dri.so ]] \
    || { log "$link is not a link to ../libgallium_dri.so"; return 1; }
  [[ "$(ls "$dir/dri")" == "${name}_drv_video.so" ]] || { log "$dir/dri has [$(ls "$dir/dri" | tr '\n' ' ')], expected ${name}_drv_video.so"; return 1; }
  readelf --dyn-syms -W "$lib/libgallium_dri.so" 2>/dev/null | awk '$7 != "UND" {print $8}' | sed 's/@.*//' | grep -x '__vaDriverInit_1_22' >/dev/null \
    || { log "$lib/libgallium_dri.so exports no __vaDriverInit_1_22"; return 1; }
  [[ "$(needed_sorted "$lib/libva.so")" == "libc.so libdl.so" ]] || { log "$lib/libva.so NEEDED is [$(needed_sorted "$lib/libva.so")], expected [libc.so libdl.so]"; return 1; }
  [[ "$(needed_sorted "$lib/libva-drm.so")" == "libc.so libdrm.so libva.so" ]] \
    || { log "$lib/libva-drm.so NEEDED is [$(needed_sorted "$lib/libva-drm.so")], expected [libc.so libdrm.so libva.so]"; return 1; }
  for s in $(readelf --dyn-syms -W "$lib/libva-drm.so" | awk '$7 == "UND" {print $8}' | grep '^drm'); do
    readelf --dyn-syms -W "$lib/libdrm.so" | awk '$7 != "UND" {print $8}' | sed 's/@.*//' | grep -x "$s" >/dev/null \
      || { log "$lib/libdrm.so exports no $s for $lib/libva-drm.so"; return 1; }
  done
}

# check the staged .so files in a directory
verify_staged() {
  local dir="$1" want="$2" mach="${3:-x86}" f hdr so needed ver
  for f in "$dir"/egl/*.so "$dir"/lib/*.so $(find "$dir/hw" -type f -name '*.so' 2>/dev/null); do
    [[ -f "$f" ]] || { log "no .so files in $dir"; return 1; }
    hdr=$(file -b "$f")
    if [[ "$mach" == aarch64 ]]; then
      case "$want:$hdr" in
        64:ELF\ 64-bit*ARM\ aarch64*) ;;
        *) log "$f is not a ${want}-bit aarch64 ELF ($hdr)"; return 1 ;;
      esac
    else
      x86_elf_ok "$want" "$hdr" || { log "$f is not a ${want}-bit x86 ELF ($hdr)"; return 1; }
    fi
  done
  for f in "$dir"/egl/*.so; do
    so=$(patchelf --print-soname "$f")
    [[ "$so" == "$(basename "$f")" ]] || { log "$f has SONAME '$so', expected $(basename "$f")"; return 1; }
  done
  needed=$(patchelf --print-needed "$dir/lib/libgallium_dri.so")
  [[ "$needed" == *libz.so* && "$needed" != *libz.so.1* ]] || { log "$dir/lib/libgallium_dri.so NEEDED has libz.so.1 or no libz.so ($needed)"; return 1; }
  ver=$(strings -n 8 "$dir/lib/libgallium_dri.so" | grep -oE 'Mesa [0-9]+\.[0-9]+\.[0-9]+' | sort -u)
  [[ "$ver" == "Mesa $MESA_VERSION" ]] || { log "strings $dir/lib/libgallium_dri.so has '$ver', expected Mesa $MESA_VERSION"; return 1; }
  verify_needed_closed "$dir"
}

# build and stage the virgl driver
build_arch() {
  local a="$1" stage g out args=() line
  stage=$(stage_dir_for "$a"); g=$(gsi_libs_for "$a"); out="$SHARE_ROOT/$stage"
  while IFS= read -r line; do args+=(--support-lib "$line"); done < <(support_libs_for "$a")
  RHIZO_SHARE_ROOT="$SHARE_ROOT" "$REPO_ROOT/tools/build/graphics/mesa.sh" --variant virgl --arch "$a" --stage "$stage" "${args[@]}" \
    || { log "mesa.sh failed for $a"; return 1; }
  cp --remove-destination "$g/libbase.so" "$g/libc++.so" "$out/lib/" || return 1
  verify_staged "$out" "$([[ "$a" == x86_64 ]] && echo 64 || echo 32)" || return 1
  if [[ "$a" == x86_64 ]]; then
    verify_va "$out" virtio_gpu || return 1
    mkdir -p "$SHARE_ROOT/gfx_hal"
    cp --remove-destination "$out/lib/libgallium_dri.so" "$out/lib/libgbm_mesa.so" "$out/lib/libdrm.so" "$out/lib/dri_gbm.so" "$SHARE_ROOT/gfx_hal/" || return 1
    cp --remove-destination "$g/libcutils.so" "$SHARE_ROOT/gfx_hal/libcutils_real.so" || return 1
    cp --remove-destination "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android/libc++_shared.so" "$SHARE_ROOT/gfx_hal/libc++_shared.so" || return 1
    cp --remove-destination "$out/lib/libgbm_mesa.so" "$g/libgbm_mesa.so" || return 1
  fi
}

# build and stage the radeonsi and radv driver
build_amd() {
  local a="$1" stage g out args=() line
  stage=$(amd_stage_dir_for "$a"); g=$(gsi_libs_for "$a"); out="$SHARE_ROOT/$stage"
  while IFS= read -r line; do args+=(--support-lib "$line"); done < <(support_libs_for "$a")
  RHIZO_SHARE_ROOT="$SHARE_ROOT" "$REPO_ROOT/tools/build/graphics/mesa.sh" --variant amd --arch "$a" --stage "$stage" "${args[@]}" \
    || { log "mesa.sh --variant amd failed for $a"; return 1; }
  cp --remove-destination "$g/libbase.so" "$g/libc++.so" "$out/lib/" || return 1
  [[ -f "$out/lib/libdrm_amdgpu.so" && -f "$out/hw/vulkan.rhizo.so" ]] || { log "no $out/lib/libdrm_amdgpu.so or $out/hw/vulkan.rhizo.so"; return 1; }
  verify_staged "$out" "$([[ "$a" == x86_64 ]] && echo 64 || echo 32)" || return 1
  if [[ "$a" == x86_64 ]]; then verify_va "$out" radeonsi || return 1; fi
}

# build and stage the llvmpipe driver set
build_software() {
  local out="$SHARE_ROOT/gpu_driver_software" g; g=$(gsi_libs_for x86_64)
  bash "$REPO_ROOT/tools/build/toolchain/llvm-android.sh" || return 1
  RHIZO_SHARE_ROOT="$SHARE_ROOT" "$REPO_ROOT/tools/build/graphics/mesa.sh" --variant software --arch x86_64 \
    || { log "mesa.sh --variant software failed"; return 1; }
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
  echo "gpu_driver_amd and gpu_driver_amd_32: Mesa $MESA_VERSION radeonsi and radv for x86_64 and x86, ACO only without LLVM or libelf (tools/patches/mesa/0005), built by tools/build/graphics/gpu-driver.sh"
  echo "video: Mesa's VA-API driver (dri/virtio_gpu_drv_video.so, dri/radeonsi_drv_video.so -> ../libgallium_dri.so) in gpu_driver and gpu_driver_amd, x86_64 only"
  echo "video-codecs: $(sed -n 's/^VIDEO_CODECS=//p' "$REPO_ROOT/tools/build/graphics/mesa.sh") for x86_64 virgl and amd (VA and radv Vulkan Video), Mesa default all_free (av1dec, av1enc, vp9dec) for the other builds"
  echo "libva: $(cat "$REPO_ROOT/toolchain/libva-android/SOURCE" 2>/dev/null || echo 'not built'), driverdir /vendor/lib64/dri, staged as lib/libva.so and lib/libva-drm.so"
  echo "license: MIT, support libraries in NOTICE and debian/copyright"
  echo "mesa-source: $src"
  [[ -f "$llvm_tar" ]] && echo "llvm-source: llvm-project-$LLVM_VERSION.src.tar.xz sha256 $(sha256sum "$llvm_tar" | cut -d' ' -f1)"
  echo "ndk: $(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties" 2>/dev/null) at $NDK"
  for f in "$REPO_ROOT"/tools/patches/mesa/*.patch; do echo "patch: $(basename "$f") sha256 $(sha256sum "$f" | cut -d' ' -f1)"; done
  for d in $(stage_dir_for x86_64) $(stage_dir_for x86) gpu_driver_software $(amd_stage_dir_for x86_64) $(amd_stage_dir_for x86); do
    dir="$SHARE_ROOT/$d"
    for f in "$dir"/egl/*.so "$dir"/lib/*.so "$dir"/hw/*.so; do
      [[ -f "$f" ]] || continue
      echo "file: $d/${f#$dir/} sha256 $(sha256sum "$f" | cut -d' ' -f1) soname $(patchelf --print-soname "$f" 2>/dev/null || echo -)"
    done
    for f in "$dir"/dri/*; do
      [[ -L "$f" ]] || continue
      echo "link: $d/${f#$dir/} -> $(readlink "$f")"
    done
  done
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# write and stamp gpu_driver.PROVENANCE
write_provenance() {
  local p="$SHARE_ROOT/gpu_driver.PROVENANCE"
  provenance_text > "$p.part" && mv "$p.part" "$p"
  python3 "$REPO_ROOT"/tools/build/stamps.py stamp gpu_driver.PROVENANCE || return 1
  log "wrote ${p#$REPO_ROOT/}"
}

# test the driver staging helpers
selftest() {
  local fail=0 out tmp
  out=$(support_libs_for x86_64)
  [[ "$out" == *"libhardware.so=@BUILD@/src/android_stub/libhardware.so"* ]] || { echo "FAIL support_libs_for x86_64 has libhardware.so=@BUILD@/src/android_stub/libhardware.so ($out)"; fail=1; }
  out=$(support_libs_for x86)
  [[ "$out" == *"libhardware.so=$SHARE_ROOT/gsi_libs_32/libhardware.so"* ]] || { echo "FAIL support_libs_for x86 has libhardware.so=$SHARE_ROOT/gsi_libs_32/libhardware.so ($out)"; fail=1; }
  [[ "$(stage_dir_for x86)" == gpu_driver_32 && "$(stage_dir_for x86_64)" == gpu_driver ]] || { echo "FAIL stage_dir_for x86 == gpu_driver_32 and stage_dir_for x86_64 == gpu_driver"; fail=1; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN; mkdir -p "$tmp/egl" "$tmp/lib"
  if cc -shared -fPIC -Wl,-soname,libEGL_rhizo.so -o "$tmp/egl/libEGL_rhizo.so" -x c /dev/null 2>/dev/null \
     && cc -shared -fPIC -Wl,-soname,libgallium_dri.so -Wl,--no-as-needed -lz -o "$tmp/lib/libgallium_dri.so" -x c - <<<'const char v[] = "Mesa 25.2.8 (fixture)";' 2>/dev/null; then
    out=$(verify_staged "$tmp" 64 2>&1)
    [[ $? -ne 0 && "$out" == *"NEEDED has libz.so.1 or no libz.so"* ]] || { echo "FAIL verify_staged with NEEDED libz.so.1 returns 1 ($out)"; fail=1; }
    patchelf --replace-needed libz.so.1 libz.so "$tmp/lib/libgallium_dri.so"
    for f in "$tmp/lib/libgallium_dri.so" "$tmp/egl/libEGL_rhizo.so"; do
      patchelf --replace-needed libc.so.6 libc.so "$f" 2>/dev/null
    done
    cc -shared -fPIC -Wl,-soname,libz.so -nostdlib -o "$tmp/lib/libz.so" -x c /dev/null 2>/dev/null
    verify_staged "$tmp" 64 >/dev/null 2>&1 || { echo "FAIL verify_staged on the fixture tree returns 0 ($(verify_staged "$tmp" 64 2>&1))"; fail=1; }
    patchelf --set-soname wrong.so "$tmp/egl/libEGL_rhizo.so"
    out=$(verify_staged "$tmp" 64 2>&1)
    [[ $? -ne 0 && "$out" == *"has SONAME 'wrong.so'"* ]] || { echo "FAIL verify_staged with SONAME wrong.so returns 1 ($out)"; fail=1; }
    patchelf --set-soname libEGL_rhizo.so "$tmp/egl/libEGL_rhizo.so"
    cc -shared -fPIC -Wl,-soname,libgallium_dri.so -Wl,--no-as-needed -lz -o "$tmp/lib/libgallium_dri.so" -x c - <<<'const char v[] = "Mesa 24.0.0 (fixture)";' 2>/dev/null
    patchelf --replace-needed libz.so.1 libz.so "$tmp/lib/libgallium_dri.so"
    out=$(verify_staged "$tmp" 64 2>&1)
    [[ $? -ne 0 && "$out" == *"has 'Mesa 24.0.0', expected Mesa $MESA_VERSION"* ]] || { echo "FAIL verify_staged with Mesa 24.0.0 returns 1 ($out)"; fail=1; }
    out=$(verify_staged "$tmp" 32 2>&1)
    [[ $? -ne 0 && "$out" == *"not a 32-bit x86 ELF"* ]] || { echo "FAIL verify_staged tmp 32 on a 64-bit tree returns 1 ($out)"; fail=1; }
  else
    echo "SKIP verify_staged without cc and zlib"
  fi
  rm -rf "$tmp"
  x86_elf_ok 32 "ELF 32-bit LSB shared object, Intel 80386, version 1 (SYSV), dynamically linked" \
    || { echo "FAIL x86_elf_ok 32 Intel 80386 returns 0"; fail=1; }
  x86_elf_ok 32 "ELF 32-bit LSB shared object, Intel i386, version 1 (SYSV), dynamically linked" \
    || { echo "FAIL x86_elf_ok 32 Intel i386 returns 0"; fail=1; }
  x86_elf_ok 32 "ELF 64-bit LSB shared object, x86-64, version 1 (SYSV), dynamically linked" \
    && { echo "FAIL x86_elf_ok 32 x86-64 returns 1"; fail=1; }
  grep -q 'gpu_driver_software: Mesa' <(provenance_text) \
    || { echo "FAIL provenance_text has gpu_driver_software: Mesa"; fail=1; }
  grep -q 'gpu_driver_amd and gpu_driver_amd_32: Mesa' <(provenance_text) && grep -q '^video-codecs: h264dec,' <(provenance_text) \
    || { echo "FAIL provenance_text has gpu_driver_amd and gpu_driver_amd_32: Mesa and video-codecs: h264dec,"; fail=1; }
  [[ "$(amd_stage_dir_for x86_64)" == gpu_driver_amd && "$(amd_stage_dir_for x86)" == gpu_driver_amd_32 ]] \
    || { echo "FAIL amd_stage_dir_for x86_64 == gpu_driver_amd and amd_stage_dir_for x86 == gpu_driver_amd_32"; fail=1; }
  tmp=$(mktemp -d); mkdir -p "$tmp/lib" "$tmp/dri"
  ln -s ../wrong.so "$tmp/dri/virtio_gpu_drv_video.so"
  out=$(verify_va "$tmp" virtio_gpu 2>&1)
  [[ $? -ne 0 && "$out" == *"is not a link to ../libgallium_dri.so"* ]] || { echo "FAIL verify_va with dri link ../wrong.so returns 1 ($out)"; fail=1; }
  rm "$tmp/dri/virtio_gpu_drv_video.so"; ln -s ../libgallium_dri.so "$tmp/dri/virtio_gpu_drv_video.so"
  if cc -shared -fPIC -o "$tmp/lib/libgallium_dri.so" -x c - <<<'int not_va(void) { return 0; }' 2>/dev/null; then
    out=$(verify_va "$tmp" virtio_gpu 2>&1)
    [[ $? -ne 0 && "$out" == *"exports no __vaDriverInit_1_22"* ]] || { echo "FAIL verify_va without __vaDriverInit_1_22 returns 1 ($out)"; fail=1; }
    cc -shared -fPIC -o "$tmp/lib/libgallium_dri.so" -x c - <<<'int __vaDriverInit_1_22(void *c) { return c != 0; }' 2>/dev/null
    out=$(verify_va "$tmp" virtio_gpu 2>&1)
    [[ $? -ne 0 && "$out" == *"libva.so NEEDED is"* ]] || { echo "FAIL verify_va without lib/libva.so returns 1 ($out)"; fail=1; }
    cc -shared -fPIC -Wl,--no-as-needed -lz -o "$tmp/lib/libx.so" -x c /dev/null 2>/dev/null
    out=$(verify_needed_closed "$tmp" 2>&1)
    [[ $? -ne 0 && "$out" == *"is not in $tmp or PLATFORM_NEEDED"* ]] || { echo "FAIL verify_needed_closed with NEEDED libz.so.1 returns 1 ($out)"; fail=1; }
  else
    echo "SKIP verify_va without cc"
  fi
  rm -rf "$tmp"
  "$SELF" --arch arm64 >/dev/null 2>&1 && { echo "FAIL gpu-driver.sh --arch arm64 exits nonzero"; fail=1; }
  [[ -f "$REPO_ROOT/tools/mesa/mesa-cross-aarch64-android" ]] || { echo "FAIL tools/mesa/mesa-cross-aarch64-android exists"; fail=1; }
  grep -q "cpu_family = 'aarch64'" "$REPO_ROOT/tools/mesa/mesa-cross-aarch64-android" 2>/dev/null \
    || { echo "FAIL tools/mesa/mesa-cross-aarch64-android has cpu_family = 'aarch64'"; fail=1; }
  if (( fail )); then echo "FAIL gpu-driver.sh --selftest"; return 1; fi
  echo "ok gpu-driver.sh --selftest"
}

WANT=both
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) WANT="$2"; shift 2 ;;
    --share-root) SHARE_ROOT="$2"; shift 2 ;;
    --selftest) selftest; exit $? ;;
    *) echo "$0 [--arch x86_64|x86|aarch64|both] [--share-root DIR] [--selftest]" >&2; exit 2 ;;
  esac
done
case "$WANT" in
  both) ;;
  x86_64|x86) ARCHES=("$WANT") ;;
  aarch64) build_aarch64; exit $? ;;
  *) log "--arch is '$WANT', expected x86_64, x86, aarch64 or both"; exit 2 ;;
esac
preflight || exit 1
if [[ " ${ARCHES[*]} " == *" x86_64 "* ]]; then
  "$REPO_ROOT/tools/build/graphics/libva-android.sh" || { log "libva-android.sh failed"; exit 1; }
fi
for a in "${ARCHES[@]}"; do build_arch "$a" || exit 1; done
for a in "${ARCHES[@]}"; do build_amd "$a" || exit 1; done
if [[ " ${ARCHES[*]} " == *" x86_64 "* ]]; then build_software || exit 1; fi
[[ "$WANT" == both ]] && { write_provenance || exit 1; }
exit 0
