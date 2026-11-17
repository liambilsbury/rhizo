# shellcheck shell=bash
# libva header and library lookup for the codec2 builds

_libva_first_with() {
  local want="$1" d; shift
  for d in "$@"; do [[ -n "$d" && -f "$d/$want" ]] && { echo "$d"; return 0; }; done
  return 1
}

# set LIBVA_INC and copy libva into var/share/gsi_libs
libva_inputs() {
  local share=var/share lib inc n
  inc=$(_libva_first_with va/va_version.h "${RHIZO_LIBVA_INC:-}" toolchain/libva-android/vendor/include) || {
    echo "no va/va_version.h in RHIZO_LIBVA_INC or toolchain/libva-android/vendor/include" >&2
    return 1
  }
  lib=$(_libva_first_with libva-drm.so "${RHIZO_LIBVA_LIB:-}" "$share/gpu_driver/lib" \
    toolchain/libva-android/vendor/lib64) || {
    echo "no libva-drm.so in RHIZO_LIBVA_LIB, $share/gpu_driver/lib or toolchain/libva-android/vendor/lib64" >&2
    return 1
  }
  for n in libva.so libva-drm.so; do
    [[ -f "$lib/$n" ]] || { echo "$lib has no $n" >&2; return 1; }
    cmp -s "$lib/$n" "$share/gsi_libs/$n" || cp --remove-destination "$lib/$n" "$share/gsi_libs/$n" || return 1
  done
  LIBVA_INC="$(cd "$inc" && pwd)"
  export LIBVA_INC
}
