#!/bin/bash
# build rhizo-codec2-service into gfx_hal
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
USAGE="usage: codec2.sh [--no-va] [-h | --help]"
WITH_VA=1
for a in "$@"; do
  case "$a" in
    --no-va) WITH_VA=0 ;;
    -h|--help) echo "$USAGE"; exit 0 ;;
    *) echo "codec2: unknown argument: $a" >&2; echo "$USAGE" >&2; exit 2 ;;
  esac
done
ABI_ARGS=(); [[ -n "${RHIZO_HAL_ABI:-}" ]] && ABI_ARGS=(--abi "$RHIZO_HAL_ABI")

A=aosp-android16-qpr2
C2="$A/frameworks/av/media/codec2"
OURS=src/android/hal/codec2
HIDL_OUT=toolchain/out/codec2/hidl-headers
GEN_OUT=toolchain/out/codec2/gen
[[ -d "$C2" ]] || { echo "codec2: no AOSP checkout at $A -- run make inputs" >&2; exit 1; }

HIDL_GEN="${RHIZO_HIDL_GEN:-$A/out/host/linux-x86/bin/hidl-gen}"
if [[ ! -x "$HIDL_GEN" ]]; then
  echo "codec2: no hidl-gen at $HIDL_GEN, building it (m hidl-gen in $A)"
  ( set +u; cd "$A" && source build/envsetup.sh && lunch aosp_x86_64 bp2a userdebug && m hidl-gen ) \
    || { echo "codec2: m hidl-gen failed in $A" >&2; exit 1; }
fi
rm -rf "$HIDL_OUT.part"
for v in 1.0 1.1 1.2; do
  "$HIDL_GEN" -o "$HIDL_OUT.part" -L c++-headers -r "android.hardware:$A/hardware/interfaces" \
    -r "android.hidl:$A/system/libhidl/transport" "android.hardware.graphics.common@$v" \
    || { echo "codec2: hidl-gen failed for android.hardware.graphics.common@$v" >&2; exit 1; }
done
rm -rf "$HIDL_OUT" && mv "$HIDL_OUT.part" "$HIDL_OUT"

MJ="$A/external/minijail"
NDKCC="toolchain/ndk_extract/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android35-clang"
rm -rf "$GEN_OUT.part" && mkdir -p "$GEN_OUT.part"
for t in syscalls constants; do
  "$NDKCC" -dD -E -Wall -Werror -Wno-unused-command-line-argument -I "$OURS/aosp/include" "$MJ/gen_$t.c" \
    -o "$GEN_OUT.part/gen_$t.i"
  bash "$MJ/gen_$t.sh" "$GEN_OUT.part/gen_$t.i" "$GEN_OUT.part/lib$t.c"
done
rm -f "$GEN_OUT.part"/*.i
rm -rf "$GEN_OUT" && mv "$GEN_OUT.part" "$GEN_OUT"

AOSP_SRCS=(
  "$C2/core/C2.cpp"
  "$C2/vndk/C2AllocatorBlob.cpp" "$C2/vndk/C2AllocatorGralloc.cpp" "$C2/vndk/C2AllocatorIon.cpp"
  "$C2/vndk/C2Buffer.cpp" "$C2/vndk/C2Config.cpp" "$C2/vndk/C2DmaBufAllocator.cpp" "$C2/vndk/C2Fence.cpp"
  "$C2/vndk/C2PlatformStorePluginLoader.cpp" "$C2/vndk/C2Store.cpp"
  "$C2/vndk/platform/C2IgbaBuffer.cpp" "$C2/vndk/platform/C2SurfaceSyncObj.cpp"
  "$C2/vndk/util/C2Debug.cpp" "$C2/vndk/util/C2InterfaceHelper.cpp" "$C2/vndk/util/C2InterfaceUtils.cpp"
  "$C2/vndk/util/C2ParamUtils.cpp"
  "$C2/hal/common/BufferTypes.cpp" "$C2/hal/common/MultiAccessUnitHelper.cpp" "$C2/hal/common/HalSelection.cpp"
  "$C2/hal/aidl/BufferTypes.cpp" "$C2/hal/aidl/Component.cpp" "$C2/hal/aidl/ComponentInterface.cpp"
  "$C2/hal/aidl/ComponentStore.cpp" "$C2/hal/aidl/Configurable.cpp" "$C2/hal/aidl/InputBufferManager.cpp"
  "$C2/hal/aidl/InputSink.cpp" "$C2/hal/aidl/ParamTypes.cpp"
  "$C2/hal/plugin/DefaultFilterPlugin.cpp" "$C2/hal/plugin/FilterWrapperStub.cpp"
  "$C2/components/base/SimpleC2Component.cpp" "$C2/components/base/SimpleC2Interface.cpp"
  "$C2/sfplugin/utils/Codec2BufferUtils.cpp" "$C2/sfplugin/utils/Codec2CommonUtils.cpp"
)
BP2="$A/hardware/interfaces/media/bufferpool/aidl/default"
for f in Accessor BufferPool BufferPoolClient BufferStatus ClientManager Connection Observer; do
  AOSP_SRCS+=("$BP2/$f.cpp")
done
FOUNDATION="$A/frameworks/av/media/module/foundation"
for f in AAtomizer ABuffer ADebug AHandler ALooper ALooperRoster AMessage AString AStringUtils hexdump MediaDefs \
         ColorUtils ColorUtils_fill; do
  AOSP_SRCS+=("$FOUNDATION/$f.cpp")
done
UI="$A/frameworks/native/libs/ui"
for f in Gralloc GraphicBufferAllocator GraphicBufferMapper Gralloc5 Fence PixelFormat; do AOSP_SRCS+=("$UI/$f.cpp"); done
AOSP_SRCS+=(
  "$A/system/core/libgrallocusage/GrallocUsageConversion.cpp"
  "$A/hardware/interfaces/common/support/NativeHandle.cpp"
  "$A/system/memory/libdmabufheap/BufferAllocator.cpp"
  "$A/system/memory/libion/ion.c"
  "$A/system/libhidl/base/HidlSupport.cpp"
)
# the platform's libbase.so is built on std::__1, not the NDK's std::__ndk1
for f in file logging parsebool properties stringprintf strings threads posix_strerror_r errors_unix; do
  AOSP_SRCS+=("$A/system/libbase/$f.cpp")
done
for f in compare compare_common compare_gcc convert convert_argb convert_from convert_from_argb convert_to_argb \
         convert_to_i420 cpu_id planar_functions rotate rotate_any rotate_argb rotate_common rotate_gcc row_any \
         row_common row_gcc scale scale_any scale_argb scale_common scale_gcc scale_rgb scale_uv video_common; do
  AOSP_SRCS+=("$A/external/libyuv/source/$f.cc")
done

for f in bpf landlock_util libminijail signal_handler syscall_filter syscall_wrapper system util; do
  AOSP_SRCS+=("$MJ/$f.c")
done
AOSP_SRCS+=("$GEN_OUT/libsyscalls.c" "$GEN_OUT/libconstants.c")
AOSP_SRCS+=("$A/frameworks/av/media/module/minijail/minijail.cpp")

OUR_SRCS=(
  "$OURS/store/store.cpp" "$OURS/store/resources.cpp" "$OURS/store/log.cpp" "$OURS/store/sandbox.cpp"
  "$OURS/aosp/bq_pool_stub.cpp" "$OURS/aosp/libcap_stub.c"
  src/android/hal/common/libfmq/EventFlag.cpp src/android/hal/common/fmq_liblog.cpp
)
VA_SRCS=()
VA_INCS=()
VA_LIBS=()
if [[ "$WITH_VA" == 1 ]]; then
  # shellcheck source=../../../src/android/hal/codec2/tools/libva-inputs.sh
  source "$OURS/tools/libva-inputs.sh"
  libva_inputs
  VA_INCS=("$LIBVA_INC")
  while IFS= read -r f; do VA_SRCS+=("$f"); done < <(
    find "$OURS/va" "$OURS/dec" "$OURS/enc" -path '*/tests' -prune -o -type f \( -name '*.cpp' -o -name '*.cc' \) \
      -print | sort)
  VA_SRCS+=("$OURS/store/registry_va.cpp" "$OURS/store/video_decoder.cpp" "$OURS/store/video_encoder.cpp"
            "$OURS/store/codec_map.cpp" "$OURS/store/buffers.cpp" "$C2/sfplugin/utils/Codec2Mapper.cpp")
  VA_LIBS=(--so va-drm --so va)
else
  OUR_SRCS+=("$OURS/store/registry_none.cpp")
fi

INCS=(
  "$OURS/aosp/include" "$OURS" src/android/hal/common/include
  "$HIDL_OUT"
  toolchain/gen/media_c2/header toolchain/gen/bufferpool2/header toolchain/gen/hw_common/header
  toolchain/gen/fmq/header toolchain/gen/gfx_common/header toolchain/gen/allocator/header
  toolchain/gfx_aidl_src/mapper/stable-c/include toolchain/gfx_aidl_src/mapper/stable-c/implutils/include
  src/android/hal/common/libfmq/include src/android/hal/common/libfmq/base
  "$C2/core/include" "$C2/vndk/include" "$C2/vndk/internal" "$C2/hal/common/include" "$C2/hal/aidl/include"
  "$C2/hal/plugin/include" "$C2/hal/plugin/internal" "$C2/components/base/include" "$C2/sfplugin/utils"
  "$FOUNDATION/include" "$FOUNDATION/include/media/stagefright/foundation"
  "$A/frameworks/av/media/libstagefright/include" "$A/frameworks/av/include"
  "$A/frameworks/native/headers/media_plugin" "$A/frameworks/native/headers/media_plugin/media/openmax"
  "$UI/include" "$A/frameworks/native/libs/math/include" "$A/frameworks/native/libs/nativewindow/include"
  "$A/frameworks/native/libs/nativebase/include" "$A/frameworks/native/libs/arect/include"
  "$A/system/core/libgrallocusage/include" "$A/system/core/libsystem/include" "$A/system/core/libsync/include"
  "$A/system/core/libvndksupport/include" "$A/hardware/libhardware/include"
  "$A/hardware/interfaces/common/support/include" "$BP2/include" "$BP2"
  "$A/system/memory/libdmabufheap/include" "$A/system/memory/libion/include" "$A/system/memory/libion/kernel-headers"
  "$A/system/libhidl/base/include" "$A/external/libyuv/include"
  "${VA_INCS[@]}"
  "$A/frameworks/av/media/module/minijail" "$MJ" "$GEN_OUT"
)

# print a digest of the closure's headers
closure_key() {
  find "$OURS" src/android/hal/common/include "$HIDL_OUT" toolchain/gen/media_c2/header toolchain/gen/bufferpool2/header \
    toolchain/gen/hw_common/header toolchain/gen/fmq/header toolchain/gen/gfx_common/header \
    toolchain/gen/allocator/header toolchain/gfx_aidl_src/mapper src/android/hal/common/libfmq "${VA_INCS[@]}" \
    -type f \( -name '*.h' -o -name '*.hpp' \) -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16
}

FLAGS=(
  -std=gnu++20 -D__ANDROID_VNDK__ -D__ANDROID_VENDOR__ -DNO_IMEMORY -DNO_C2_INPUT_SURFACE -DBUFFERPOOL_CLONE_HANDLES
  -DLIBYUV_UNLIMITED_DATA
  -fvisibility=hidden
  -Wno-unused-parameter -Wno-deprecated-declarations
  "-DRHIZO_C2_CLOSURE_KEY=0x$(closure_key)"
)

CFLAGS=(
  -std=gnu11 -D_FILE_OFFSET_BITS=64 -DALLOW_DEBUG_LOGGING -DALLOW_DUPLICATE_SYSCALLS
  '-DDEFAULT_PIVOT_ROOT="/var/empty"' '-DBINDMOUNT_ALLOWED_PREFIXES=""'
  -Wno-unused-parameter
  -fvisibility=hidden
  "-DRHIZO_C2_CLOSURE_KEY=0x$(closure_key)"
)

ARGS=()
for f in "${AOSP_SRCS[@]}" "${OUR_SRCS[@]}" "${VA_SRCS[@]}"; do ARGS+=(--extra-src "$f"); done
for d in "${INCS[@]}"; do ARGS+=(--extra-inc "$d"); done
for f in "${FLAGS[@]}"; do ARGS+=(--cxxflag "$f"); done
for f in "${CFLAGS[@]}"; do ARGS+=(--cflag "$f"); done
for g in media_c2 bufferpool2 hw_common fmq gfx_common allocator; do ARGS+=(--aidl-src "toolchain/gen/$g/ndk"); done

tools/build/hal/hal.sh rhizo-codec2-service "$OURS/store/service.cpp" "${ARGS[@]}" \
  --so nativewindow --so sync --so vndksupport "${VA_LIBS[@]}" \
  "${ABI_ARGS[@]}" --stage "${RHIZO_HAL_STAGE:-gfx_hal}"

install -D -m 0644 "$OURS/store/seccomp/rhizo-codec2-service.x86_64.policy" \
  "var/share/${RHIZO_HAL_STAGE:-gfx_hal}/rhizo-codec2-service.policy"
echo "[build-hal] staged -> var/share/${RHIZO_HAL_STAGE:-gfx_hal}/rhizo-codec2-service.policy"

if [[ -z "${RHIZO_HAL_ABI:-}" && "${RHIZO_HAL_STAGE:-gfx_hal}" == gfx_hal ]]; then
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-codec2-service || exit 1
fi
