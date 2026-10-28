#!/bin/bash
# fetch and verify the pinned build inputs
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../env.sh
source ./gsi-pins.sh
REPO_ROOT="$(cd "$(dirname "$SELF")/../.." && pwd)"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
AOSP_DIR="${RHIZO_AOSP_DIR:-$CACHE/aosp/android16-qpr2}"
INPUTS_TSV="$REPO_ROOT/.rhizo-inputs.tsv"
PATCH_DIR="$(cd "$(dirname "$SELF")/../patches/mesa" && pwd)"

declare -A URL SHA256 SHA1 SIZE FILE
FILE[ndk]=android-ndk-r27c-linux.zip
URL[ndk]=https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
SHA256[ndk]=59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc
SHA1[ndk]=090e8083a715fdb1a3e402d0763c388abb03fb4e
SIZE[ndk]=663987688
NDK_REVISION=27.2.12479018

FILE[mesa]=mesa-25.2.8.tar.xz
URL[mesa]=https://archive.mesa3d.org/mesa-25.2.8.tar.xz
SHA256[mesa]=097842f3e49d996868b38688db87b006f7d4541e93ce86d2f341d8b3e7be7c93
SIZE[mesa]=43813260
MESA_VERSION=25.2.8

FILE[llvm]=llvm-project-18.1.8.src.tar.xz
URL[llvm]=https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz
SHA256[llvm]=0b58557a6d32ceee97c8d533a59b9212d87e0fc4d2833924eb6c611247db2f2a
SIZE[llvm]=132067260

FILE[libdrm]=libdrm-2.4.123.tar.xz
URL[libdrm]=https://dri.freedesktop.org/libdrm/libdrm-2.4.123.tar.xz
SHA256[libdrm]=a2b98567a149a74b0f50e91e825f9c0315d86e7be9b74394dae8b298caadb79e

FILE[libva]=libva-2.22.0.tar.bz2
URL[libva]=https://github.com/intel/libva/releases/download/2.22.0/libva-2.22.0.tar.bz2
SHA256[libva]=e3da2250654c8d52b3f59f8cb3f3d8e7fb1a2ee64378dbc400fbc5663de7edb8
SIZE[libva]=565488

FILE[gsi]="$(basename "${GSI_URL[a16]}")"
URL[gsi]="${GSI_URL[a16]}"
SHA256[gsi]="${GSI_SHA[a16]}"

FILE[wayland]=wayland-1.22.0.tar.xz
URL[wayland]=https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.22.0/downloads/wayland-1.22.0.tar.xz
SHA256[wayland]=1540af1ea698a471c2d8e9d288332c7e0fd360c8f1d12936ebb7e7cbc2425842
SIZE[wayland]=229544

FILE[libffi]=libffi-3.4.6.tar.gz
URL[libffi]=https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
SHA256[libffi]=b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e
SIZE[libffi]=1391684

FILE[wlprotocols]=wayland-protocols-1.45.tar.xz
URL[wlprotocols]=https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.45/downloads/wayland-protocols-1.45.tar.xz
SHA256[wlprotocols]=4d2b2a9e3e099d017dc8107bf1c334d27bb87d9e4aff19a0c8d856d17cd41ef0
SIZE[wlprotocols]=130040

FILE[perfetto]=perfetto-v58.2-linux-amd64.zip
URL[perfetto]=https://github.com/google/perfetto/releases/download/v58.2/linux-amd64.zip
SHA256[perfetto]=32c739f71b2d39721afd294c0b038f2499a44a71b5b6bcdd85b83faca0b240b9
SIZE[perfetto]=14123443

FILE[sdk_buildtools]=build-tools_r34-linux.zip
URL[sdk_buildtools]=https://dl.google.com/android/repository/build-tools_r34-linux.zip
SHA256[sdk_buildtools]=e858c4b60069d0431051b225d384413b1643e1289b00a4825aed347f25bd510f
SHA1[sdk_buildtools]=d6d58e0c6925a9e4d9a541e84cd1f405c2f9d2a9
SIZE[sdk_buildtools]=61224257
FILE[sdk_platform]=platform-34-ext7_r03.zip
URL[sdk_platform]=https://dl.google.com/android/repository/platform-34-ext7_r03.zip
SHA256[sdk_platform]=16fdb74c55e59ae3ef52def135aec713508467bd56d7dabcd8c9be31fa8b20f3
SHA1[sdk_platform]=1f2e9478d6a7601425ceaa553311dc43191f103d
SIZE[sdk_platform]=63180081
SDK_BUILD_TOOLS_VERSION=34.0.0
SDK_PLATFORM=android-34

FILE[testapk]=com.jeffliu.balancetheball_4.apk
URL[testapk]=https://f-droid.org/repo/com.jeffliu.balancetheball_4.apk
SHA256[testapk]=6180534b151e4d50365b21483f3719e32f207a42675dee20227de449c875c1e2
SIZE[testapk]=42170

AOSP_MANIFEST_URL=https://android.googlesource.com/platform/manifest
AOSP_MANIFEST_BRANCH=android16-qpr2-release
AOSP_MANIFEST_COMMIT=ee1f70e8abb9a6ef756469c3bbdea490e0a656cd
AOSP_BUILD_ID=BP4A.251205.006

ALL_INPUTS=(ndk mesa libdrm libva llvm gsi wayland libffi wlprotocols perfetto sdk testapk aosp)
declare -A ROW
CHECK_ONLY=0 ACCEPT_SDK_LICENSE=0 SYNC_AOSP=0
MODE="" ELAPSED=0

# print a file's sha256
sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# check an archive's size and digests
verify_digest() {
  local name="$1" f="$2" have
  if [[ -n "${SIZE[$name]:-}" ]]; then
    have=$(stat -c%s "$f")
    [[ "$have" == "${SIZE[$name]}" ]] || { log "$name: $f is $have bytes, pinned ${SIZE[$name]}"; return 1; }
  fi
  have=$(sha256_of "$f")
  [[ "$have" == "${SHA256[$name]}" ]] || { log "$name: sha256 of $f is $have, pinned ${SHA256[$name]}"; return 1; }
  if [[ -n "${SHA1[$name]:-}" ]]; then
    have=$(sha1sum "$f" | cut -d' ' -f1)
    [[ "$have" == "${SHA1[$name]}" ]] || { log "$name: sha1 of $f is $have, pinned ${SHA1[$name]}"; return 1; }
  fi
}

# download the pinned archive into the cache
fetch_pinned() {
  local name="$1" dir="$CACHE/$1" f t0
  f="$dir/${FILE[$name]}"
  mkdir -p "$dir"
  if [[ -f "$f" ]]; then
    if verify_digest "$name" "$f"; then MODE=cached; ELAPSED=0; return 0; fi
    log "$name: the cached archive failed verification, refetching"
    rm -f "$f"
  fi
  (( CHECK_ONLY )) && { log "$name: not in the cache: $f"; return 1; }
  t0=$SECONDS
  log "$name: downloading ${URL[$name]}"
  curl -fsS -L --retry 3 --retry-delay 5 -o "$f.part" "${URL[$name]}" \
    || { rm -f "$f.part"; log "$name: download failed: ${URL[$name]}"; return 1; }
  verify_digest "$name" "$f.part" || { rm -f "$f.part"; return 1; }
  mv "$f.part" "$f"
  MODE=fetched; ELAPSED=$((SECONDS - t0))
}

# extract an archive to a stamped directory
extract_stamped() {
  local name="$1" archive="$2" dest="$3" stamp tmp root
  stamp=$(sha256_of "$archive")
  if [[ -f "$dest/.rhizo-input" && "$(cat "$dest/.rhizo-input")" == "$stamp" ]]; then MODE=reused; return 0; fi
  (( CHECK_ONLY )) && { log "$name: no extracted tree at $dest"; return 1; }
  rm -rf "$dest" "$dest.part"
  tmp="$dest.part"; mkdir -p "$tmp"
  case "$archive" in
    *.zip) unzip -q "$archive" -d "$tmp" || { log "$name: unzip failed on $archive"; return 1; } ;;
    *) tar -xf "$archive" -C "$tmp" || { log "$name: tar failed on $archive"; return 1; } ;;
  esac
  root=$(ls -A "$tmp")
  [[ $(wc -l <<<"$root") -eq 1 && -d "$tmp/$root" ]] \
    || { log "$name: $archive does not unpack to one directory, got: $root"; return 1; }
  mkdir -p "$(dirname "$dest")"
  mv "$tmp/$root" "$dest" && rmdir "$tmp"
  printf '%s\n' "$stamp" > "$dest/.rhizo-input"
}

# symlink a checkout path to a cache tree
link_into_tree() {
  local target="$1" link="$2"
  if [[ -L "$link" ]]; then
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]] && return 0
    log "$link is a symlink to $(readlink "$link"), not to $target"; return 1
  fi
  [[ -e "$link" ]] && { log "$link exists and is not a symlink; refusing to replace it"; return 1; }
  mkdir -p "$(dirname "$link")"
  ln -s "$target" "$link"
}

# apply each patch in a directory
apply_patch_dir() {
  local tree="$1" dir="$2" p
  for p in "$dir"/*.patch; do
    [[ -f "$p" ]] || { log "no patches in $dir"; return 1; }
    if patch -p1 -d "$tree" --forward --dry-run -s < "$p" >/dev/null 2>&1; then
      patch -p1 -d "$tree" --forward -s < "$p" || { log "$(basename "$p") failed to apply to $tree"; return 1; }
      log "applied $(basename "$p")"
    elif patch -p1 -d "$tree" --reverse --dry-run -s < "$p" >/dev/null 2>&1; then
      log "$(basename "$p") already applied"
    else
      log "$(basename "$p") neither applies to nor is present in $tree; the source drifted, re-derive the patch"
      return 1
    fi
  done
}

# check the mesa tree holds the patches
mesa_patches_present() {
  local t="$1"
  grep -q '\*module = NULL;' "$t/src/android_stub/hardware_stub.cpp" || { log "mesa: $t lacks the hw_get_module patch"; return 1; }
  grep -q 'DRM_CLOEXEC | DRM_RDWR' "$t/src/gallium/winsys/virgl/drm/virgl_drm_winsys.c" || { log "mesa: $t lacks the DRM_RDWR patch"; return 1; }
  grep -q '^libdrm_amdgpu = ext_libdrm_amdgpu$' "$t/subprojects/libdrm.wrap" || { log "mesa: $t lacks the libdrm.wrap provide patch"; return 1; }
  grep -q 'dep_libdrm_amdgpu' "$t/src/amd/vulkan/meson.build" || { log "mesa: $t lacks the radv libdrm_amdgpu patch"; return 1; }
  grep -q '^elif with_gallium_radeonsi and amd_with_llvm$' "$t/meson.build" || { log "mesa: $t lacks the radeonsi libelf patch"; return 1; }
  grep -q 'virgl_video_profile_to_wire(cdc->base.profile)' "$t/src/gallium/drivers/virgl/virgl_encode.c" || { log "mesa: $t lacks the virgl video wire-profile patch"; return 1; }
  grep -q 'vh265->pps.st_rps_bits = h265->NumShortTermPictureSliceHeaderBits;' "$t/src/gallium/drivers/virgl/virgl_video.c" || { log "mesa: $t lacks the virgl HEVC st_rps_bits patch"; return 1; }
  grep -q '^static void virgl_clear_surface_template(' "$t/src/gallium/drivers/virgl/virgl_context.c" || { log "mesa: $t lacks the virgl clear template-surface patch"; return 1; }
  grep -q '^static void virgl_emit_inline_ubo0(' "$t/src/gallium/drivers/virgl/virgl_context.c" || { log "mesa: $t lacks the virgl inline constant-slot-0 patch"; return 1; }
  grep -q '!pipe->screen->caps.prefer_compute_for_multimedia)$' "$t/src/gallium/auxiliary/vl/vl_video_buffer.c" || { log "mesa: $t lacks the vl component-view 2D-array patch"; return 1; }
  grep -q '^   res->clean_mask = 0;$' "$t/src/gallium/drivers/virgl/virgl_resource.c" || { log "mesa: $t lacks the virgl exported-texture readback patch"; return 1; }
  grep -q '^   {.type = U_GRALLOC_TYPE_RHIZO, .create = u_gralloc_rhizo_create},$' "$t/src/util/u_gralloc/u_gralloc.c" && grep -q '^   gr->base.ops.get_buffer_color_info = rhizo_get_color_info;$' "$t/src/util/u_gralloc/u_gralloc_rhizo.c" 2>/dev/null || { log "mesa: $t lacks the u_gralloc Rhizo handle patch"; return 1; }
  grep -q '^      if (plane_offset == 0)$' "$t/src/gallium/drivers/virgl/virgl_resource.c" || { log "mesa: $t lacks the virgl own-plane-resource patch"; return 1; }
  grep -q '^        vh264->quant_i_frames = h264->quant_p_frames;$' "$t/src/gallium/drivers/virgl/virgl_video.c" && grep -q '^        vh265->rc.quant_i_frames = h265->rc\[0\].quant_p_frames;$' "$t/src/gallium/drivers/virgl/virgl_video.c" || { log "mesa: $t lacks the virgl encode picture-QP patch"; return 1; }
  grep -q '^   util_set_vertex_buffers_count(vctx->vertex_buffer, &vctx->num_vertex_buffers,$' "$t/src/gallium/drivers/virgl/virgl_context.c" && grep -q '^   ctx->screen->fence_reference(ctx->screen, fence, NULL);$' "$t/src/gallium/drivers/virgl/virgl_context.c" && grep -q '^      fd = virgl_drm_winsys(screen->vws)->fd;$' "$t/src/gallium/winsys/virgl/drm/virgl_drm_winsys.c" || { log "mesa: $t lacks the virgl teardown-leaks patch"; return 1; }
  grep -q '^void vl_csc_get_ycbcr_to_rgb_matrix(double kr, double kb,$' "$t/src/gallium/auxiliary/vl/vl_csc.c" && grep -q 'weighted = (is_explicit || mc != 1) && vlVaLumaWeights(mc, &kr, &kb);$' "$t/src/gallium/frontends/va/postproc.c" || { log "mesa: $t lacks the VA VPP luma-weight matrix patch"; return 1; }
  grep -q '^calc_plane_clamp(struct vl_compositor_layer \*layer)$' "$t/src/gallium/auxiliary/vl/vl_compositor.c" && grep -q 'ureg_DECL_constant(shader, VL_COMPOSITOR_GFX_CLAMP_SLOT + i);$' "$t/src/gallium/auxiliary/vl/vl_compositor_gfx.c" || { log "mesa: $t lacks the vl graphics-compositor source-rect clamp patch"; return 1; }
}

# store the row for an input
record() {
  ROW[$1]=$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6")
}

# check or fetch the NDK
do_ndk() {
  local link="$REPO_ROOT/toolchain/ndk_extract/android-ndk-r27c" tree="$CACHE/ndk/android-ndk-r27c" rev
  if [[ -e "$link" && ! -L "$link" || -L "$link" && "$(readlink -f "$link")" != "$(readlink -f "$tree")" ]]; then
    rev=$(sed -n 's/^Pkg.Revision *= *//p' "$link/source.properties" 2>/dev/null)
    [[ "$rev" == "$NDK_REVISION" ]] || { log "ndk: $link is present but its Pkg.Revision is '$rev', not $NDK_REVISION"; return 1; }
    record ndk provided "revision $rev" 0 0 "$link"; return 0
  fi
  fetch_pinned ndk || return 1
  local amode="$MODE" asec="$ELAPSED"
  extract_stamped ndk "$CACHE/ndk/${FILE[ndk]}" "$tree" || return 1
  [[ "$MODE" == reused && "$amode" == cached ]] && amode=reused
  link_into_tree "$tree" "$link" || return 1
  record ndk "$amode" "${SHA256[ndk]}" "${SIZE[ndk]}" "$asec" "${URL[ndk]}"
}

# check or fetch the mesa tree
do_mesa() {
  local tree="$REPO_ROOT/mesa-src" ver
  if [[ -e "$tree" ]]; then
    ver=$(cat "$tree/VERSION" 2>/dev/null)
    [[ "$ver" == "$MESA_VERSION" ]] || { log "mesa: $tree is present but its VERSION is '$ver', not $MESA_VERSION"; return 1; }
    (( CHECK_ONLY )) || apply_patch_dir "$tree" "$PATCH_DIR" || return 1
    mesa_patches_present "$tree" || return 1
    record mesa provided "VERSION $ver + $(ls "$PATCH_DIR"/*.patch | wc -l) patches" 0 0 "$tree"; return 0
  fi
  fetch_pinned mesa || return 1
  local amode="$MODE" asec="$ELAPSED"
  (( CHECK_ONLY )) && { log "mesa: no tree at $tree"; return 1; }
  rm -rf "$tree.part"; mkdir -p "$tree.part"
  tar -xJf "$CACHE/mesa/${FILE[mesa]}" -C "$tree.part" --strip-components=1 || { log "mesa: tar failed"; return 1; }
  [[ "$(cat "$tree.part/VERSION")" == "$MESA_VERSION" ]] || { log "mesa: the tarball's VERSION is not $MESA_VERSION"; return 1; }
  apply_patch_dir "$tree.part" "$PATCH_DIR" || return 1
  mesa_patches_present "$tree.part" || return 1
  mv "$tree.part" "$tree"
  record mesa "$amode" "${SHA256[mesa]}" "${SIZE[mesa]}" "$asec" "${URL[mesa]}"
}

# copy the pinned libdrm tarball into mesa's package cache
do_libdrm() {
  local wrap="$REPO_ROOT/mesa-src/subprojects/libdrm.wrap" want cache="$REPO_ROOT/mesa-src/subprojects/packagecache"
  [[ -f "$wrap" ]] || { log "libdrm: no $wrap; mesa first"; return 1; }
  want=$(sed -n 's/^source_hash = //p' "$wrap")
  [[ "$want" == "${SHA256[libdrm]}" ]] || { log "libdrm: the wrap's source_hash is $want, this script pins ${SHA256[libdrm]}"; return 1; }
  if [[ -f "$cache/${FILE[libdrm]}" ]] && [[ "$(sha256_of "$cache/${FILE[libdrm]}")" == "$want" ]]; then
    record libdrm provided "$want" "$(stat -c%s "$cache/${FILE[libdrm]}")" 0 "$cache"; return 0
  fi
  fetch_pinned libdrm || return 1
  mkdir -p "$cache"
  cp "$CACHE/libdrm/${FILE[libdrm]}" "$cache/${FILE[libdrm]}"
  record libdrm "$MODE" "${SHA256[libdrm]}" "$(stat -c%s "$cache/${FILE[libdrm]}")" "$ELAPSED" "${URL[libdrm]}"
}

# fetch and extract the GSI image
do_gsi() {
  local zip="$CACHE/gsi/${FILE[gsi]}" tree="$CACHE/gsi/${FILE[gsi]%.zip}" seed stamp tmp
  seed=$(gsi_seed_path "$VAR_DIR" a16)
  if [[ ! -f "$zip" && -f "$seed" ]] && [[ "$(sha256_of "$seed")" == "${SHA256[gsi]}" ]]; then
    mkdir -p "$CACHE/gsi"; ln "$seed" "$zip" 2>/dev/null || cp "$seed" "$zip"
    log "gsi: seeded the cache from $seed"
  fi
  fetch_pinned gsi || return 1
  local amode="$MODE" asec="$ELAPSED"
  stamp="${SHA256[gsi]}"
  if [[ -f "$tree/.rhizo-input" && "$(cat "$tree/.rhizo-input")" == "$stamp" && -f "$tree/system.img" ]]; then
    [[ "$amode" == cached ]] && amode=reused
  else
    (( CHECK_ONLY )) && { log "gsi: no extracted image at $tree/system.img"; return 1; }
    rm -rf "$tree" "$tree.part"; tmp="$tree.part"; mkdir -p "$tmp"
    unzip -q -o "$zip" system.img build.prop -d "$tmp" || { log "gsi: unzip failed on $zip"; return 1; }
    sha256_of "$tmp/system.img" > "$tmp/system.img.sha256"
    printf '%s\n' "$stamp" > "$tmp/.rhizo-input"
    mv "$tmp" "$tree"
  fi
  record gsi "$amode" "$stamp" "$(stat -c%s "$zip")" "$asec" "${URL[gsi]}"
}

# fetch the pinned libva source into the cache
do_libva()   { fetch_pinned libva   || return 1; record libva   "$MODE" "${SHA256[libva]}"   "${SIZE[libva]}"   "$ELAPSED" "${URL[libva]}"; }
# fetch the pinned LLVM source into the cache
do_llvm()    { fetch_pinned llvm    || return 1; record llvm    "$MODE" "${SHA256[llvm]}"    "${SIZE[llvm]}"    "$ELAPSED" "${URL[llvm]}"; }
# fetch the pinned wayland source into the cache
do_wayland() { fetch_pinned wayland || return 1; record wayland "$MODE" "${SHA256[wayland]}" "${SIZE[wayland]}" "$ELAPSED" "${URL[wayland]}"; }
# fetch the pinned libffi source into the cache
do_libffi()  { fetch_pinned libffi  || return 1; record libffi  "$MODE" "${SHA256[libffi]}"  "${SIZE[libffi]}"  "$ELAPSED" "${URL[libffi]}"; }
# fetch the pinned wayland-protocols source into the cache
do_wlprotocols() { fetch_pinned wlprotocols || return 1; record wlprotocols "$MODE" "${SHA256[wlprotocols]}" "${SIZE[wlprotocols]}" "$ELAPSED" "${URL[wlprotocols]}"; }

# fetch Perfetto's release tools
do_perfetto() {
  local tree="$CACHE/perfetto/v58.2-linux-amd64"
  fetch_pinned perfetto || return 1
  local amode="$MODE" asec="$ELAPSED"
  extract_stamped perfetto "$CACHE/perfetto/${FILE[perfetto]}" "$tree" || return 1
  chmod +x "$tree/trace_processor_shell" || return 1
  [[ "$MODE" == reused && "$amode" == cached ]] && amode=reused
  link_into_tree "$tree" "$REPO_ROOT/toolchain/perfetto" || return 1
  record perfetto "$amode" "${SHA256[perfetto]}" "${SIZE[perfetto]}" "$asec" "${URL[perfetto]}"
}

# fetch and extract the pinned SDK build tools and platform
do_sdk() {
  local bt="$CACHE/android-sdk/build-tools/$SDK_BUILD_TOOLS_VERSION" plat="$CACHE/android-sdk/platforms/$SDK_PLATFORM"
  local need=0 n
  for n in sdk_buildtools sdk_platform; do
    [[ -f "$CACHE/$n/${FILE[$n]}" ]] && verify_digest "$n" "$CACHE/$n/${FILE[$n]}" >/dev/null 2>&1 || need=1
  done
  if (( need && ! ACCEPT_SDK_LICENSE && ! CHECK_ONLY )); then
    log "sdk: the build tools and platform jar are Google's, under https://developer.android.com/studio/terms;"
    log "  pass --accept-android-sdk-license to download them"
    return 1
  fi
  local worst=reused secs=0
  fetch_pinned sdk_buildtools || return 1; [[ "$MODE" == fetched ]] && worst=fetched; secs=$((secs + ELAPSED))
  extract_stamped sdk_buildtools "$CACHE/sdk_buildtools/${FILE[sdk_buildtools]}" "$bt" || return 1
  [[ "$MODE" != reused && "$worst" == reused ]] && worst=cached
  fetch_pinned sdk_platform || return 1; [[ "$MODE" == fetched ]] && worst=fetched; secs=$((secs + ELAPSED))
  extract_stamped sdk_platform "$CACHE/sdk_platform/${FILE[sdk_platform]}" "$plat" || return 1
  [[ "$MODE" != reused && "$worst" == reused ]] && worst=cached
  for n in d8 zipalign apksigner; do [[ -x "$bt/$n" ]] || { log "sdk: no $n in $bt after extraction"; return 1; }; done
  [[ -f "$plat/android.jar" ]] || { log "sdk: no android.jar in $plat after extraction"; return 1; }
  record sdk "$worst" "${SHA256[sdk_buildtools]} ${SHA256[sdk_platform]}" "$(( ${SIZE[sdk_buildtools]} + ${SIZE[sdk_platform]} ))" "$secs" "${URL[sdk_buildtools]} ${URL[sdk_platform]}"
}

# fetch the test fixture APK
do_testapk() {
  local dst="$VAR_DIR/share/rhizo-test-fixture.apk" meta="$VAR_DIR/share/rhizo-test-fixture.json"
  if [[ -f "$dst" && "$(sha256_of "$dst")" == "${SHA256[testapk]}" && -f "$meta" ]]; then
    record testapk provided "${SHA256[testapk]}" "${SIZE[testapk]}" 0 "$dst"
    python3 ../build/stamps.py stamp rhizo-test-fixture.apk
    return 0
  fi
  fetch_pinned testapk || return 1
  (( CHECK_ONLY )) && { log "testapk: not staged at $dst"; return 1; }
  mkdir -p "$VAR_DIR/share"
  cp --remove-destination "$CACHE/testapk/${FILE[testapk]}" "$dst"
  cat > "$meta" <<EOF
{
  "package": "com.jeffliu.balancetheball",
  "activity": "com.jeffliu.balancetheball.GameActivity",
  "label": "Balance the Ball",
  "sha256": "${SHA256[testapk]}",
  "source_url": "${URL[testapk]}",
  "size": ${SIZE[testapk]},
  "target_sdk": 30,
  "selected_at": "pinned by tools/fetch/build-inputs.sh"
}
EOF
  record testapk "$MODE" "${SHA256[testapk]}" "${SIZE[testapk]}" "$ELAPSED" "${URL[testapk]}"
  python3 ../build/stamps.py stamp rhizo-test-fixture.apk
}

# check the AOSP checkout branch and build id
validate_aosp() {
  local d="$1" rev commit id
  [[ -d "$d/.repo/manifests" ]] || { log "aosp: $d has no .repo/manifests"; return 1; }
  rev=$(sed -n 's/.*<default[^>]*revision="\([^"]*\)".*/\1/p' "$d/.repo/manifests/default.xml" | head -1)
  [[ "$rev" == "$AOSP_MANIFEST_BRANCH" ]] || { log "aosp: $d's manifest default revision is '$rev', not $AOSP_MANIFEST_BRANCH"; return 1; }
  commit=$(git -C "$d/.repo/manifests" rev-parse HEAD 2>/dev/null)
  [[ "$commit" == "$AOSP_MANIFEST_COMMIT" ]] || { log "aosp: $d's manifest commit is '$commit', not $AOSP_MANIFEST_COMMIT"; return 1; }
  id=$(sed -n 's/^BUILD_ID=//p' "$d/build/make/core/build_id.mk")
  [[ "$id" == "$AOSP_BUILD_ID" ]] || { log "aosp: $d's BUILD_ID is '$id', not $AOSP_BUILD_ID"; return 1; }
}

# validate or set up the AOSP checkout
do_aosp() {
  local link="$REPO_ROOT/aosp-android16-qpr2"
  if [[ -e "$link" ]]; then
    validate_aosp "$link" || return 1
    record aosp provided "manifest $AOSP_MANIFEST_COMMIT" 0 0 "$(readlink -f "$link")"; return 0
  fi
  local started="$AOSP_DIR/.rhizo-sync-started" done="$AOSP_DIR/.rhizo-input"
  if [[ ! -d "$AOSP_DIR/.repo" || ( -f "$started" && ! -f "$done" ) ]]; then
    (( SYNC_AOSP )) || {
      log "aosp: no checkout at $AOSP_DIR; point RHIZO_AOSP_DIR at one, or pass --sync-aosp to repo init/sync"
      log "  $AOSP_MANIFEST_BRANCH at manifest commit $AOSP_MANIFEST_COMMIT there (about 140 GB, hours)"
      return 1
    }
    (( CHECK_ONLY )) && { log "aosp: no complete checkout at $AOSP_DIR"; return 1; }
    mkdir -p "$AOSP_DIR" && : > "$started"
    log "aosp: syncing $AOSP_MANIFEST_BRANCH into $AOSP_DIR (about 140 GB, hours; a rerun resumes)"
    ( cd "$AOSP_DIR" && repo init -q --repo-rev=v2.69 -u "$AOSP_MANIFEST_URL" -b "$AOSP_MANIFEST_COMMIT" --partial-clone --clone-filter=blob:none </dev/null \
        && { repo sync -q -c -j8 </dev/null \
             || { log "aosp: some projects did not check out; syncing again at -j2"; repo sync -q -c -j2 </dev/null; }; } ) \
      || { log "aosp: repo init/sync failed in $AOSP_DIR; run make inputs again to resume"; return 1; }
    validate_aosp "$AOSP_DIR" || return 1
    printf '%s\n' "$AOSP_MANIFEST_COMMIT" > "$done"
  fi
  validate_aosp "$AOSP_DIR" || return 1
  link_into_tree "$AOSP_DIR" "$link" || return 1
  record aosp provided "manifest $AOSP_MANIFEST_COMMIT" 0 0 "$AOSP_DIR"
}

# write the .rhizo-inputs.tsv record
write_inputs_tsv() {
  local n
  { printf '# input\tmode\tdigest\tbytes\tseconds\tsource\n'
    for n in "${ALL_INPUTS[@]}"; do
      if [[ -n "${ROW[$n]:-}" ]]; then printf '%s\n' "${ROW[$n]}"; fi
    done
  } > "$INPUTS_TSV.part" && mv "$INPUTS_TSV.part" "$INPUTS_TSV"
}

# read each row of the inputs record into ROW by input name
read_inputs_tsv() {
  local line n
  [[ -f "$INPUTS_TSV" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == \#* || -z "$line" ]] && continue
    n="${line%%$'\t'*}"; ROW[$n]="$line"
  done < "$INPUTS_TSV"
}

# reject a cache inside a git work tree
assert_cache_outside_worktrees() {
  local real
  mkdir -p "$CACHE"
  real=$(readlink -f "$CACHE")
  if env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C "$real" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "the input cache $real is inside a git work tree; set RHIZO_INPUT_CACHE outside every checkout"
    return 1
  fi
}

# test the build-inputs.sh functions
selftest() {
  local fail=0 tmp out
  tmp=$(mktemp -d)
  printf 'x' > "$tmp/f"
  SHA256[fixture]=$(printf 'y' | sha256sum | cut -d' ' -f1)
  out=$(verify_digest fixture "$tmp/f" 2>&1)
  [[ $? -ne 0 && "$out" == *"fixture: sha256 of"* ]] || { echo "SELFTEST FAILED: a wrong sha256 was not refused by name -- got: $out"; fail=1; }
  SIZE[fixture]=1; SHA256[fixture]=$(printf 'x' | sha256sum | cut -d' ' -f1)
  verify_digest fixture "$tmp/f" >/dev/null 2>&1 || { echo "SELFTEST FAILED: a correct size and sha256 was refused"; fail=1; }
  SIZE[fixture]=2
  out=$(verify_digest fixture "$tmp/f" 2>&1)
  [[ $? -ne 0 && "$out" == *"is 1 bytes, pinned 2"* ]] || { echo "SELFTEST FAILED: a wrong size was not refused -- got: $out"; fail=1; }
  mkdir -p "$tmp/real" "$tmp/target"
  out=$(link_into_tree "$tmp/target" "$tmp/real" 2>&1)
  [[ $? -ne 0 && "$out" == *"refusing to replace"* ]] || { echo "SELFTEST FAILED: a real directory was replaced by a link -- got: $out"; fail=1; }
  link_into_tree "$tmp/target" "$tmp/link" && link_into_tree "$tmp/target" "$tmp/link" \
    || { echo "SELFTEST FAILED: a matching link was not accepted twice"; fail=1; }
  out=$(link_into_tree "$tmp/real" "$tmp/link" 2>&1)
  [[ $? -ne 0 && "$out" == *"not to $tmp/real"* ]] || { echo "SELFTEST FAILED: a link to the wrong target was accepted -- got: $out"; fail=1; }
  mkdir -p "$tmp/tree" "$tmp/patches" "$tmp/pristine"
  printf 'hello\n' > "$tmp/pristine/a.txt"; printf 'world\n' > "$tmp/tree/a.txt"
  ( cd "$tmp" && diff -u pristine/a.txt tree/a.txt | sed '1s|^--- .*|--- a/a.txt|; 2s|^+++ .*|+++ b/a.txt|' > patches/0001-fixture.patch )
  printf 'hello\n' > "$tmp/tree/a.txt"
  apply_patch_dir "$tmp/tree" "$tmp/patches" >/dev/null 2>&1 && [[ "$(cat "$tmp/tree/a.txt")" == world ]] \
    || { echo "SELFTEST FAILED: the fixture patch did not apply"; fail=1; }
  out=$(apply_patch_dir "$tmp/tree" "$tmp/patches" 2>&1)
  [[ $? -eq 0 && "$out" == *"already applied"* ]] || { echo "SELFTEST FAILED: an applied patch was not read as present -- got: $out"; fail=1; }
  printf 'other\n' > "$tmp/tree/a.txt"
  out=$(apply_patch_dir "$tmp/tree" "$tmp/patches" 2>&1)
  [[ $? -ne 0 && "$out" == *"0001-fixture.patch neither applies"* ]] || { echo "SELFTEST FAILED: a drifted tree was not refused by patch name -- got: $out"; fail=1; }
  mkdir -p "$tmp/var/gsi-dl"
  : > "$tmp/var/gsi-dl/gsi_a16.zip"
  out=$(gsi_seed_path "$tmp/var" a16)
  [[ "$out" == "$tmp/var/gsi-dl/gsi_a16.zip" ]] || { echo "SELFTEST FAILED: the label-named seed is the fallback -- got: $out"; fail=1; }
  : > "$tmp/var/gsi-dl/${GSI_URL[a16]##*/}"
  out=$(gsi_seed_path "$tmp/var" a16)
  [[ "$out" == "$tmp/var/gsi-dl/${GSI_URL[a16]##*/}" ]] || { echo "SELFTEST FAILED: the seed named for the pinned file wins -- got: $out"; fail=1; }
  out=$(gsi_pin_row a15)
  [[ "$out" == "a15"$'\t'"${GSI_URL[a15]}"$'\t'"${GSI_SHA[a15]}"$'\t'"${GSI_DESC[a15]}" ]] || { echo "SELFTEST FAILED: a release's pins-file row is its four tab-separated fields -- got: $out"; fail=1; }
  gsi_pin_row nosuch >/dev/null && { echo "SELFTEST FAILED: an unpinned release has no row"; fail=1; }
  local inst_url inst_sha
  inst_url=$(sed -n 's/^GSI_URL\[a16\]="\(.*\)"$/\1/p' "$REPO_ROOT/src/install/prepare/fetch-gsi.sh")
  inst_sha=$(sed -n 's/^GSI_SHA\[a16\]="\(.*\)"$/\1/p' "$REPO_ROOT/src/install/prepare/fetch-gsi.sh")
  [[ "$inst_url" == "${GSI_URL[a16]}" && "$inst_sha" == "${GSI_SHA[a16]}" ]] \
    || { echo "SELFTEST FAILED: src/install/prepare/fetch-gsi.sh's a16 pin differs from tools/fetch/gsi-pins.sh"; fail=1; }
  local p n=0
  for p in "$PATCH_DIR"/*.patch; do n=$((n + 1)); done
  [[ $n -eq 16 ]] || { echo "SELFTEST FAILED: expected 16 patches in $PATCH_DIR, found $n"; fail=1; }
  mkdir -p "$tmp/bin"
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && printf partial > "$2"; shift; done\nexit 7\n' > "$tmp/bin/curl"
  chmod +x "$tmp/bin/curl"
  out=$(PATH="$tmp/bin:$PATH" RHIZO_INPUT_CACHE="$tmp/cache" "$SELF" --only wayland 2>&1)
  [[ $? -ne 0 && "$out" == *"wayland: download failed: ${URL[wayland]}"* ]] \
    || { echo "SELFTEST FAILED: a failed download did not fail naming wayland and its URL -- got: $out"; fail=1; }
  [[ ! -e "$tmp/cache/wayland/${FILE[wayland]}.part" ]] || { echo "SELFTEST FAILED: a failed download left its .part behind"; fail=1; }
  (
    INPUTS_TSV="$tmp/inputs.tsv"
    ROW=()
    ROW[${ALL_INPUTS[0]}]="${ALL_INPUTS[0]}	provided	fixture	0	0	-"
    write_inputs_tsv
  )
  [[ -f "$tmp/inputs.tsv" && ! -e "$tmp/inputs.tsv.part" ]] \
    || { echo "SELFTEST FAILED: a record whose last input has no row was left as $tmp/inputs.tsv.part"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "build-inputs.sh selftest: FAILED"; return 1; fi
  echo "build-inputs.sh selftest: ok"
}

ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY+=("$2"); shift 2 ;;
    --accept-android-sdk-license) ACCEPT_SDK_LICENSE=1; shift ;;
    --sync-aosp) SYNC_AOSP=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    --selftest) selftest; exit $? ;;
    *) echo "usage: $0 [--only NAME]... [--accept-android-sdk-license] [--sync-aosp] [--check] [--selftest]" >&2; exit 2 ;;
  esac
done
[[ ${#ONLY[@]} -gt 0 ]] || ONLY=("${ALL_INPUTS[@]}")
for n in "${ONLY[@]}"; do
  case " ${ALL_INPUTS[*]} " in *" $n "*) ;; *) log "unknown input '$n' (want: ${ALL_INPUTS[*]})"; exit 2 ;; esac
done

assert_cache_outside_worktrees || exit 1
read_inputs_tsv
rc=0
for n in "${ONLY[@]}"; do
  if "do_$n"; then
    log "$n: ${ROW[$n]#*$'\t'}" | cut -f1-2
  else
    log "$n: FAILED"; rc=1; break
  fi
done
(( CHECK_ONLY || ${#ROW[@]} == 0 )) || write_inputs_tsv
exit $rc
