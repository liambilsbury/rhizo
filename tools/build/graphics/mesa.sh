#!/bin/bash
# Mesa driver variant build into var/share/<stage>
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../env.sh

REPO_ROOT="$(cd "$(dirname "$SELF")/../../.." && pwd)"
MESA_SRC="$REPO_ROOT/mesa-src"
NATIVE_CLC_DIR="$REPO_ROOT/toolchain/native-clc"
LIBVA_ROOT="$REPO_ROOT/toolchain/libva-android"
VIDEO_CODECS=h264dec,h264enc,h265dec,h265enc,vp9dec,av1dec,av1enc

# check the drivers against the mesa_clc list
needs_clc_tools() {
  local gallium="$1" vulkan="$2"
  case ",$gallium," in *,iris,*|*,asahi,*|*,panfrost,*) return 0 ;; esac
  case ",$vulkan," in *,intel,*|*,asahi,*|*,panfrost,*|*,nouveau,*) return 0 ;; esac
  return 1
}

# set the driver lists for a variant
variant_defaults() {
  case "$1" in
    virgl)     GALLIUM=virgl;    VULKAN=;       STAGE_DEFAULT=gpu_driver ;;
    intel)     GALLIUM=iris;     VULKAN=intel;  STAGE_DEFAULT=gpu_driver_intel ;;
    amd)       GALLIUM=radeonsi; VULKAN=amd;    STAGE_DEFAULT=gpu_driver_amd ;;
    zink)      GALLIUM=zink;     VULKAN=;       STAGE_DEFAULT=gpu_driver_zink ;;
    lavapipe)  GALLIUM=llvmpipe; VULKAN=swrast; STAGE_DEFAULT=gpu_driver_lavapipe ;;
    software)  GALLIUM=llvmpipe; VULKAN=;       STAGE_DEFAULT=gpu_driver_software ;;
    *) log "unknown variant $1, expected virgl|intel|amd|zink|lavapipe|software"; return 1 ;;
  esac
}

# print the libdrm submodules for the drivers
libdrm_submodules() {
  local gallium="$1" vulkan="$2" mods=""
  case ",$gallium,$vulkan," in *,radeonsi,*|*,amd,*|*,r600,*) mods+=",libdrm_amdgpu" ;; esac
  echo "${mods#,}"
}

# check the two amdgpu patches in mesa-src
verify_amd_mesa_patches() {
  grep -q '^libdrm_amdgpu = ext_libdrm_amdgpu$' "$MESA_SRC/subprojects/libdrm.wrap" \
    || { log "$MESA_SRC/subprojects/libdrm.wrap has no libdrm_amdgpu = ext_libdrm_amdgpu"; return 1; }
  grep -q 'dep_libdrm_amdgpu' "$MESA_SRC/src/amd/vulkan/meson.build" \
    || { log "$MESA_SRC/src/amd/vulkan/meson.build has no dep_libdrm_amdgpu"; return 1; }
}

# check the radeonsi build-without-libelf patch
verify_radeonsi_libelf_patch() {
  grep -q '^elif with_gallium_radeonsi and amd_with_llvm$' "$MESA_SRC/meson.build" \
    || { log "$MESA_SRC/meson.build has no elif with_gallium_radeonsi and amd_with_llvm (tools/patches/mesa/0005)"; return 1; }
}

# return whether gallium $1 on arch $2 builds the Mesa VA-API driver
wants_va() {
  [[ "$2" == x86_64 ]] || return 1
  case ",$1," in *,virgl,*|*,radeonsi,*) return 0 ;; esac
  return 1
}

# check for the llvmpipe or swrast driver
needs_target_llvm() {
  case ",$1,$2," in *,llvmpipe,*|*,swrast,*) return 0 ;; esac
  return 1
}

# check the cross file and llvm-config shim
verify_llvm_android_patches() {
  grep -q "^llvm-config = " "$REPO_ROOT/tools/mesa/mesa-cross-x86_64-android" \
    || { log "tools/mesa/mesa-cross-x86_64-android has no llvm-config entry"; return 1; }
  local shim="$REPO_ROOT/tools/mesa/mesa-llvm-config-android-shim"
  [[ -x "$shim" ]] \
    || { log "$shim is not executable"; return 1; }
}

# build the meson arguments
build_meson_args() {
  local gallium="$2" vulkan="$3" sdk="$4" arch="${5:-x86_64}"
  local force_names="libdrm"
  local drm_sub; drm_sub=$(libdrm_submodules "$gallium" "$vulkan")
  [[ -n "$drm_sub" ]] && force_names="libdrm,$drm_sub"
  local gl_state=enabled
  [[ -z "$gallium" ]] && gl_state=disabled
  local llvm_state=disabled
  needs_target_llvm "$gallium" "$vulkan" && llvm_state=enabled
  MESON_ARGS=(
    --buildtype=release
    -Dplatforms=android -Dplatform-sdk-version="$sdk"
    -Dandroid-stub=true -Dandroid-libbacktrace=disabled
    -Dgallium-drivers="$gallium" -Dvulkan-drivers="$vulkan"
    -Dllvm="$llvm_state" -Dgbm="$gl_state" -Degl="$gl_state"
    -Dgles1="$gl_state" -Dgles2="$gl_state" -Dshared-glapi="$gl_state"
    -Dzstd=disabled -Dglvnd=disabled
    -Dallow-fallback-for=libdrm --force-fallback-for="$force_names"
  )
  case ",$gallium,$vulkan," in *,radeonsi,*|*,amd,*) MESON_ARGS+=(-Damd-use-llvm=false) ;; esac
  if wants_va "$gallium" "$arch"; then
    MESON_ARGS+=(-Dgallium-va=enabled -Dvideo-codecs="$VIDEO_CODECS")
  else
    MESON_ARGS+=(-Dgallium-va=disabled)
  fi
  if needs_clc_tools "$gallium" "$vulkan"; then
    MESON_ARGS+=(-Dmesa-clc=system)
  fi
  if needs_target_llvm "$gallium" "$vulkan"; then
    MESON_ARGS+=(-Dshared-llvm=disabled -Ddraw-use-llvm=true -Dcpp_rtti=false)
  fi
}

# build mesa_clc and vtn_bindgen2
build_native_clc_tools() {
  [[ -x "$NATIVE_CLC_DIR/mesa_clc" && -x "$NATIVE_CLC_DIR/vtn_bindgen2" ]] && return 0
  local d; d=$(mktemp -d)
  meson setup "$d" "$MESA_SRC" \
    -Dinstall-mesa-clc=true -Dmesa-clc=enabled -Dgallium-drivers= -Dvulkan-drivers= \
    -Dllvm=enabled -Dglx=disabled -Dplatforms= -Degl=disabled -Dgbm=disabled \
    || { rm -rf "$d"; return 1; }
  ninja -C "$d" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 || { rm -rf "$d"; return 1; }
  mkdir -p "$NATIVE_CLC_DIR"
  install -m0755 "$d/src/compiler/clc/mesa_clc" "$NATIVE_CLC_DIR/mesa_clc"
  install -m0755 "$d/src/compiler/spirv/vtn_bindgen2" "$NATIVE_CLC_DIR/vtn_bindgen2"
  rm -rf "$d"
}

# strip the built .so files in a directory
strip_staged_output() {
  local dir="$1" f
  while IFS= read -r -d '' f; do
    strip --strip-unneeded "$f"
  done < <(find "$dir" -type f -name '*.so' ! -name libcutils.so ! -name libhardware.so ! -name libz.so -print0)
}

# check the arch against the gallium driver
stage_arch_allowed() { [[ "$1" != x86 || "$2" == virgl || "$2" == radeonsi ]]; }

# stage libva and the VA driver links Mesa's install made
stage_va() {
  local install_dir="$1" out="$2" f link n=0
  for f in libva.so libva-drm.so; do
    [[ -f "$LIBVA_ROOT/vendor/lib64/$f" ]] || { log "no $LIBVA_ROOT/vendor/lib64/$f"; return 1; }
    cp --remove-destination "$LIBVA_ROOT/vendor/lib64/$f" "$out/lib/$f"
  done
  mkdir -p "$out/dri"
  for link in "$install_dir"/usr/local/lib/dri/*_drv_video.so; do
    [[ -L "$link" ]] || { log "no *_drv_video.so link in $install_dir/usr/local/lib/dri"; return 1; }
    [[ "$(readlink "$link")" == ../libgallium_dri.so ]] \
      || { log "$link -> $(readlink "$link"), expected ../libgallium_dri.so"; return 1; }
    ln -s ../libgallium_dri.so "$out/dri/$(basename "$link")"
    n=$((n + 1))
  done
  log "staged libva.so, libva-drm.so and dri links=$n"
}

# stage a variant's install tree into var/share
stage_variant() {
  local install_dir="$1" stage_dir="$2" arch="$3" vulkan="$4" gallium="$5"
  stage_arch_allowed "$arch" "$gallium" || { log "--arch $arch is not supported for gallium $gallium"; return 1; }
  local out="${RHIZO_SHARE_ROOT:-$VAR_DIR/share}/$stage_dir"
  rm -rf "$out"; mkdir -p "$out/egl" "$out/lib" "$out/hw"
  local install_lib="$install_dir/usr/local/lib"

  if [[ -n "$gallium" ]]; then
    for src_name in libEGL libGLESv2 libGLESv1_CM; do
      local dst="$out/egl/${src_name}_rhizo.so"
      cp --remove-destination "$install_lib/$src_name.so" "$dst"
      patchelf --set-soname "${src_name}_rhizo.so" "$dst"
    done
    cp --remove-destination "$install_lib/libgallium_dri.so" "$out/lib/libgallium_dri.so"
    cp --remove-destination "$install_lib/libgbm_mesa.so" "$out/lib/libgbm_mesa.so"
    cp --remove-destination "$BUILD_DIR/src/gbm/backends/dri/dri_gbm.so" "$out/lib/dri_gbm.so" \
      || { log "no $BUILD_DIR/src/gbm/backends/dri/dri_gbm.so"; return 1; }
    if patchelf --print-needed "$out/lib/libgallium_dri.so" | grep -qx 'libz.so.1'; then
      patchelf --replace-needed libz.so.1 libz.so "$out/lib/libgallium_dri.so"
    fi
    grep -q '\*module = NULL;' "$MESA_SRC/src/android_stub/hardware_stub.cpp" \
      || { log "mesa-src/src/android_stub/hardware_stub.cpp has no *module = NULL;"; return 1; }
  else
    rmdir "$out/egl" 2>/dev/null || true
  fi

  cp --remove-destination "$install_lib/libdrm.so" "$out/lib/libdrm.so"
  local sub
  for sub in $(libdrm_submodules "$gallium" "$vulkan" | tr ',' ' '); do
    [[ -f "$install_lib/$sub.so" ]] || { log "no $install_lib/$sub.so for $vulkan/$gallium"; return 1; }
    cp --remove-destination "$install_lib/$sub.so" "$out/lib/$sub.so"
  done
  local common="${RHIZO_SHARE_ROOT:-$VAR_DIR/share}/gpu_driver/lib" src
  for f in libcutils.so libhardware.so libz.so; do
    if [[ -n "${SUPPORT_LIB[$f]:-}" ]]; then
      src="${SUPPORT_LIB[$f]//@BUILD@/$BUILD_DIR}"
      [[ -f "$src" ]] || { log "--support-lib $f path $src does not exist"; return 1; }
    else
      src="$common/$f"
      [[ -f "$src" ]] || { log "no $common/$f"; return 1; }
    fi
    cp --remove-destination "$src" "$out/lib/$f"
  done

  if [[ -n "$vulkan" ]]; then
    local icd; icd=$(find "$install_lib" -maxdepth 1 -iname 'libvulkan_*.so' | head -1)
    [[ -n "$icd" ]] || { log "no libvulkan_*.so in $install_lib for vulkan-drivers=$vulkan"; return 1; }
    cp --remove-destination "$icd" "$out/hw/vulkan.rhizo.so"
    patchelf --set-soname vulkan.rhizo.so "$out/hw/vulkan.rhizo.so"
  fi
  rmdir "$out/hw" 2>/dev/null || true
  if wants_va "$gallium" "$arch"; then
    stage_va "$install_dir" "$out" || return 1
  fi
  strip_staged_output "$out"

  local egl_count=0
  [[ -d "$out/egl" ]] && egl_count=$(ls "$out/egl" | wc -l)
  log "staged $stage_dir egl=$egl_count lib=$(ls "$out/lib" | wc -l)$( [[ -d "$out/hw" ]] && echo " vulkan_icd=1" )$( [[ -d "$out/dri" ]] && echo " dri_links=$(ls "$out/dri" | wc -l)" ) size=$(du -sh "$out" | cut -f1)"
}

usage() { echo "mesa.sh --variant <virgl|intel|amd|zink|lavapipe|software> [--gallium-drivers=CSV] [--vulkan-drivers=CSV]
        [--arch x86_64|x86|aarch64] [--support-lib NAME=PATH]... [--stage DIR] [--configure-only]
        [--build-dir DIR] [--print-args] [-h | --help]
mesa.sh --selftest" >&2; }

# check the argument construction and staging functions
selftest() {
  local fail=0
  variant_defaults intel || { log "FAIL variant_defaults intel returns 0"; fail=1; }
  [[ "$GALLIUM" == iris && "$VULKAN" == intel ]] || { log "FAIL variant_defaults intel sets GALLIUM=iris VULKAN=intel (gallium=$GALLIUM vulkan=$VULKAN)"; fail=1; }
  variant_defaults bogus 2>/dev/null && { log "FAIL variant_defaults bogus returns 1"; fail=1; }

  build_meson_args intel iris intel 35
  local args=" ${MESON_ARGS[*]} "
  for flag in ' --buildtype=release ' ' --force-fallback-for=libdrm ' ' -Dallow-fallback-for=libdrm ' ' -Dandroid-stub=true ' ' -Dmesa-clc=system '; do
    [[ "$args" == *"$flag"* ]] || { log "FAIL build_meson_args intel has $flag ($args)"; fail=1; }
  done
  local saved_args=("${MESON_ARGS[@]}")
  MESON_ARGS=("${MESON_ARGS[@]/-Dallow-fallback-for=libdrm}")
  local stripped=" ${MESON_ARGS[*]} "
  [[ "$stripped" == *' -Dallow-fallback-for=libdrm '* ]] && { log "FAIL MESON_ARGS without -Dallow-fallback-for=libdrm has no -Dallow-fallback-for=libdrm"; fail=1; }
  MESON_ARGS=("${saved_args[@]}")

  build_meson_args virgl virgl "" 35
  args=" ${MESON_ARGS[*]} "
  [[ "$args" == *' -Dmesa-clc=system '* ]] && { log "FAIL build_meson_args virgl has no -Dmesa-clc=system"; fail=1; }
  [[ "$args" == *" -Dgallium-va=enabled -Dvideo-codecs=$VIDEO_CODECS "* ]] || { log "FAIL build_meson_args virgl has -Dgallium-va=enabled -Dvideo-codecs=$VIDEO_CODECS ($args)"; fail=1; }
  [[ "$VIDEO_CODECS" != *all* && "$VIDEO_CODECS" != *vc1dec* ]] || { log "FAIL VIDEO_CODECS has no all or vc1dec ($VIDEO_CODECS)"; fail=1; }
  build_meson_args virgl virgl "" 35 x86
  args=" ${MESON_ARGS[*]} "
  [[ "$args" == *' -Dgallium-va=disabled '* && "$args" != *' -Dvideo-codecs='* ]] || { log "FAIL build_meson_args virgl x86 has -Dgallium-va=disabled and no -Dvideo-codecs ($args)"; fail=1; }

  build_meson_args amd radeonsi amd 35
  args=" ${MESON_ARGS[*]} "
  [[ "$args" == *' -Damd-use-llvm=false '* ]] || { log "FAIL build_meson_args amd has -Damd-use-llvm=false"; fail=1; }
  [[ "$args" == *' -Dgallium-va=enabled '* ]] || { log "FAIL build_meson_args amd has -Dgallium-va=enabled ($args)"; fail=1; }
  build_meson_args amd radeonsi amd 35 x86
  args=" ${MESON_ARGS[*]} "
  [[ "$args" == *' -Dgallium-va=disabled '* ]] || { log "FAIL build_meson_args amd x86 has -Dgallium-va=disabled ($args)"; fail=1; }
  build_meson_args software llvmpipe "" 35
  args=" ${MESON_ARGS[*]} "
  [[ "$args" == *' -Dgallium-va=disabled '* ]] || { log "FAIL build_meson_args software has -Dgallium-va=disabled ($args)"; fail=1; }
  verify_radeonsi_libelf_patch || { log "FAIL verify_radeonsi_libelf_patch returns 0 for mesa-src"; fail=1; }
  [[ "$args" == *' -Dmesa-clc=system '* ]] && { log "FAIL build_meson_args software has no -Dmesa-clc=system"; fail=1; }

  needs_clc_tools iris "" || { log "FAIL needs_clc_tools iris returns 0"; fail=1; }
  needs_clc_tools radeonsi amd && { log "FAIL needs_clc_tools radeonsi amd returns 1"; fail=1; }

  local printed; printed=$("$SELF" --variant amd --gallium-drivers= --print-args)
  grep -qx -- '-Dgallium-drivers=' <<<"$printed" \
    || { log "FAIL mesa.sh --variant amd --gallium-drivers= --print-args has -Dgallium-drivers= ($printed)"; fail=1; }

  verify_amd_mesa_patches \
    || { log "FAIL verify_amd_mesa_patches returns 0 for mesa-src"; fail=1; }
  local fixture; fixture=$(mktemp -d)
  mkdir -p "$fixture/subprojects" "$fixture/src/amd/vulkan"
  printf '[wrap-file]\n' > "$fixture/subprojects/libdrm.wrap"
  printf 'dependencies : [dep_llvm],\n' > "$fixture/src/amd/vulkan/meson.build"
  ( MESA_SRC="$fixture" verify_amd_mesa_patches ) 2>/dev/null \
    && { log "FAIL verify_amd_mesa_patches returns 1 for a fixture without both patches"; fail=1; }
  rm -rf "$fixture"

  variant_defaults lavapipe || { log "FAIL variant_defaults lavapipe returns 0"; fail=1; }
  [[ "$GALLIUM" == llvmpipe && "$VULKAN" == swrast ]] || { log "FAIL variant_defaults lavapipe sets GALLIUM=llvmpipe VULKAN=swrast (gallium=$GALLIUM vulkan=$VULKAN)"; fail=1; }
  needs_target_llvm llvmpipe swrast || { log "FAIL needs_target_llvm llvmpipe swrast returns 0"; fail=1; }
  needs_target_llvm iris intel && { log "FAIL needs_target_llvm iris intel returns 1"; fail=1; }
  needs_target_llvm radeonsi amd && { log "FAIL needs_target_llvm radeonsi amd returns 1"; fail=1; }
  build_meson_args lavapipe llvmpipe swrast 35
  args=" ${MESON_ARGS[*]} "
  [[ "$args" == *' -Dllvm=enabled '* ]] || { log "FAIL build_meson_args lavapipe has -Dllvm=enabled ($args)"; fail=1; }
  [[ "$args" == *' -Dshared-llvm=disabled '* ]] || { log "FAIL build_meson_args lavapipe has -Dshared-llvm=disabled ($args)"; fail=1; }
  [[ "$args" == *' -Dcpp_rtti=false '* ]] || { log "FAIL build_meson_args lavapipe has -Dcpp_rtti=false ($args)"; fail=1; }
  args=$("$SELF" --variant software --print-args)
  args=" $(tr '\n' ' ' <<<"$args")"
  [[ "$args" == *' -Dgallium-drivers=llvmpipe '* ]] || { log "FAIL mesa.sh --variant software --print-args has -Dgallium-drivers=llvmpipe ($args)"; fail=1; }
  [[ "$args" == *' -Dvulkan-drivers= '* ]] || { log "FAIL mesa.sh --variant software --print-args has -Dvulkan-drivers= ($args)"; fail=1; }
  [[ "$args" == *' -Dllvm=enabled '* ]] || { log "FAIL mesa.sh --variant software --print-args has -Dllvm=enabled ($args)"; fail=1; }
  stage_arch_allowed x86 llvmpipe && { log "FAIL stage_arch_allowed x86 llvmpipe returns 1"; fail=1; }
  build_meson_args virgl virgl "" 35
  args=" ${MESON_ARGS[*]} "
  [[ "$args" == *' -Dllvm=disabled '* ]] || { log "FAIL build_meson_args virgl has -Dllvm=disabled ($args)"; fail=1; }
  verify_llvm_android_patches \
    || { log "FAIL verify_llvm_android_patches returns 0 for the tree"; fail=1; }
  fixture=$(mktemp -d)
  printf 'x' > "$fixture/meson.build"
  ( MESA_SRC="$fixture" REPO_ROOT="$fixture" verify_llvm_android_patches ) 2>/dev/null \
    && { log "FAIL verify_llvm_android_patches returns 1 for a fixture without both patches"; fail=1; }
  rm -rf "$fixture"

  stage_arch_allowed x86 virgl || { log "FAIL stage_arch_allowed x86 virgl returns 0"; fail=1; }
  stage_arch_allowed x86 iris && { log "FAIL stage_arch_allowed x86 iris returns 1"; fail=1; }
  stage_arch_allowed x86 radeonsi || { log "FAIL stage_arch_allowed x86 radeonsi returns 0"; fail=1; }
  stage_arch_allowed x86_64 iris || { log "FAIL stage_arch_allowed x86_64 iris returns 0"; fail=1; }
  printed=$("$SELF" --variant virgl --support-lib libz.so=/from/here --support-lib libhardware.so=@BUILD@/src/android_stub/libhardware.so --print-args)
  grep -qx -- 'support-lib libz.so=/from/here' <<<"$printed" \
    || { log "FAIL mesa.sh --print-args has support-lib libz.so=/from/here ($printed)"; fail=1; }
  grep -qx -- 'support-lib libhardware.so=@BUILD@/src/android_stub/libhardware.so' <<<"$printed" \
    || { log "FAIL mesa.sh --print-args has support-lib libhardware.so=@BUILD@/src/android_stub/libhardware.so ($printed)"; fail=1; }
  "$SELF" --variant virgl --support-lib nonsense --print-args >/dev/null 2>&1 \
    && { log "FAIL mesa.sh --support-lib nonsense exits nonzero"; fail=1; }

  fixture=$(mktemp -d)
  cp "$(dirname "$SELF")/fixtures/strip-fixture.c" "$fixture/f.c"
  if cc -g -O0 -shared -fPIC -o "$fixture/libfixture.so" "$fixture/f.c" 2>/dev/null; then
    local before_size after_size
    before_size=$(stat -c%s "$fixture/libfixture.so")
    strip_staged_output "$fixture"
    after_size=$(stat -c%s "$fixture/libfixture.so")
    (( after_size < before_size )) \
      || { log "FAIL strip_staged_output shrinks libfixture.so ($before_size -> $after_size)"; fail=1; }
    readelf --dyn-syms -W "$fixture/libfixture.so" 2>/dev/null | grep -q rhizo_selftest_exported_symbol \
      || { log "FAIL libfixture.so after strip_staged_output exports rhizo_selftest_exported_symbol"; fail=1; }
    mkdir -p "$fixture/dri" && ln -s ../libgallium_dri.so "$fixture/dri/virtio_gpu_drv_video.so"
    strip_staged_output "$fixture" 2>/dev/null \
      && [[ "$(readlink "$fixture/dri/virtio_gpu_drv_video.so")" == ../libgallium_dri.so ]] \
      || { log "FAIL dri/virtio_gpu_drv_video.so -> ../libgallium_dri.so after strip_staged_output"; fail=1; }
  else
    log "SKIP strip_staged_output without cc"
  fi
  rm -rf "$fixture"

  local aarch64_out aarch64_rc
  aarch64_out="$($SELF --variant lavapipe --arch aarch64 --configure-only 2>&1)"; aarch64_rc=$?
  [[ $aarch64_rc -ne 0 && "$aarch64_out" == *"no Android-target LLVM cross build for --arch aarch64"* ]] \
    || { log "FAIL mesa.sh --variant lavapipe --arch aarch64 --configure-only exits nonzero before llvm-android.sh (rc=$aarch64_rc $aarch64_out)"; fail=1; }
  if (( fail )); then log "FAIL mesa.sh --selftest"; return 1; fi
  log "ok mesa.sh --selftest"
}

VARIANT="" ARCH=x86_64 STAGE="" CONFIGURE_ONLY=0 BUILD_DIR="" PRINT_ARGS=0
GALLIUM_SET=0 VULKAN_SET=0 GALLIUM_OVERRIDE="" VULKAN_OVERRIDE=""
declare -A SUPPORT_LIB
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest) selftest; exit $? ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --support-lib)
      [[ "$2" == *=* ]] || { log "--support-lib is '$2', expected NAME=PATH"; exit 2; }
      SUPPORT_LIB["${2%%=*}"]="${2#*=}"; shift 2 ;;
    --gallium-drivers=*) GALLIUM_OVERRIDE="${1#*=}"; GALLIUM_SET=1; shift ;;
    --vulkan-drivers=*) VULKAN_OVERRIDE="${1#*=}"; VULKAN_SET=1; shift ;;
    --arch) ARCH="$2"; shift 2 ;;
    --stage) STAGE="$2"; shift 2 ;;
    --configure-only) CONFIGURE_ONLY=1; shift ;;
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    --print-args) PRINT_ARGS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log "unknown option $1"; usage; exit 2 ;;
  esac
done
[[ -n "$VARIANT" ]] || { usage; exit 2; }
variant_defaults "$VARIANT" || exit 1
(( GALLIUM_SET )) && GALLIUM="$GALLIUM_OVERRIDE"
(( VULKAN_SET )) && VULKAN="$VULKAN_OVERRIDE"
[[ -n "$STAGE" ]] || STAGE="$STAGE_DEFAULT"
[[ -n "$BUILD_DIR" ]] || BUILD_DIR="$MESA_SRC/build-android-$ARCH-$VARIANT"

SDK=35
build_meson_args "$VARIANT" "$GALLIUM" "$VULKAN" "$SDK" "$ARCH"

if (( PRINT_ARGS )); then
  printf '%s\n' "${MESON_ARGS[@]}"
  for f in "${!SUPPORT_LIB[@]}"; do printf 'support-lib %s=%s\n' "$f" "${SUPPORT_LIB[$f]}"; done
  exit 0
fi

CROSS_FILE="$REPO_ROOT/tools/mesa/mesa-cross-$ARCH-android"
[[ -f "$CROSS_FILE" ]] || { log "no $CROSS_FILE"; exit 1; }

if needs_clc_tools "$GALLIUM" "$VULKAN"; then
  build_native_clc_tools || { log "native mesa_clc/vtn_bindgen2 build failed"; exit 1; }
  export PATH="$NATIVE_CLC_DIR:$PATH"
fi
if [[ -n "$(libdrm_submodules "$GALLIUM" "$VULKAN")" ]]; then
  verify_amd_mesa_patches || exit 1
fi
case ",$GALLIUM," in *,radeonsi,*) verify_radeonsi_libelf_patch || exit 1 ;; esac
PC_ENV=(PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH='' PKG_CONFIG_SYSROOT_DIR=/nonexistent)
if wants_va "$GALLIUM" "$ARCH"; then
  [[ -f "$LIBVA_ROOT/vendor/lib64/pkgconfig/libva.pc" ]] \
    || { log "no ${LIBVA_ROOT#"$REPO_ROOT"/}/vendor/lib64/pkgconfig/libva.pc"; exit 1; }
  PC_ENV=(PKG_CONFIG_LIBDIR="$LIBVA_ROOT/vendor/lib64/pkgconfig" PKG_CONFIG_PATH='' PKG_CONFIG_SYSROOT_DIR="$LIBVA_ROOT")
fi
if needs_target_llvm "$GALLIUM" "$VULKAN"; then
  [[ "$ARCH" == x86_64 ]] || { log "no Android-target LLVM cross build for --arch $ARCH"; exit 1; }
  verify_llvm_android_patches || exit 1
  "$REPO_ROOT/tools/build/toolchain/llvm-android.sh" || { log "llvm-android.sh failed"; exit 1; }
fi

rm -rf "$BUILD_DIR"
env "${PC_ENV[@]}" meson setup "$BUILD_DIR" "$MESA_SRC" \
  --cross-file "$CROSS_FILE" --wrap-mode=nodownload "${MESON_ARGS[@]}" \
  || { log "meson setup failed for $VARIANT"; exit 1; }

(( CONFIGURE_ONLY )) && { log "meson setup succeeded"; exit 0; }

ninja -C "$BUILD_DIR" || { log "ninja failed for $VARIANT"; exit 1; }

INSTALL_DIR=$(mktemp -d)
DESTDIR="$INSTALL_DIR" ninja -C "$BUILD_DIR" install >/dev/null \
  || { log "ninja install failed for $VARIANT"; rm -rf "$INSTALL_DIR"; exit 1; }
stage_variant "$INSTALL_DIR" "$STAGE" "$ARCH" "$VULKAN" "$GALLIUM"
rc=$?
rm -rf "$INSTALL_DIR"
exit $rc
