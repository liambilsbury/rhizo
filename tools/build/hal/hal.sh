#!/bin/bash
# builds a HAL binary with the NDK
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
ROOT="$(cd "." && pwd)"

OUT_NAME="$1"; SRC="$2"; shift 2
AIDL_NAMES=()
AIDL_SRC_DIRS=()
EXTRA_INC=()
EXTRA_SRC=()
SO_LIBS=()
EXACT_SO=()
EXTRA_CXXFLAGS=()
EXTRA_CFLAGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --aidl) AIDL_NAMES+=("$2"); shift 2 ;;
    --aidl-src) AIDL_SRC_DIRS+=("$2"); shift 2 ;;
    --extra-inc) EXTRA_INC+=("$2"); shift 2 ;;
    --extra-src) EXTRA_SRC+=("$2"); shift 2 ;;
    --so) SO_LIBS+=("$2"); shift 2 ;;
    --exact-so) EXACT_SO+=("$2"); shift 2 ;;
    --cxxflag) EXTRA_CXXFLAGS+=("$2"); shift 2 ;;
    --cflag) EXTRA_CFLAGS+=("$2"); shift 2 ;;
    --shared) SHARED=1; shift ;;
    --no-default-libs) NO_DEFAULT_LIBS=1; shift ;;
    --stage) STAGE_DIR="$2"; shift 2 ;;
    --abi) ABI="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
SHARED="${SHARED:-0}"
STAGE_DIR="${STAGE_DIR:-}"
ABI="${ABI:-$(uname -m)}"

NDK="$ROOT/toolchain/ndk_extract/android-ndk-r27c"
GEN_HDR="$ROOT/toolchain/gen/header"
INC_PLAT="$ROOT/toolchain/include_platform"
case "$ABI" in
  x86_64)
    CLANGXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android35-clang++"
    LIBDIR="$ROOT/var/share/gsi_libs"
    OUT_DIR="$ROOT/toolchain/out"
    ;;
  x86)
    CLANGXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/i686-linux-android35-clang++"
    LIBDIR="$ROOT/var/share/gsi_libs_32"
    OUT_DIR="$ROOT/toolchain/out/x86"
    ;;
  arm64-v8a)
    CLANGXX="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android35-clang++"
    LIBDIR="$ROOT/var/share/gsi_libs_arm64"
    OUT_DIR="$ROOT/toolchain/out/arm64"
    ;;
  *) echo "unknown --abi: $ABI (expected x86_64, x86 or arm64-v8a)" >&2; exit 2 ;;
esac
mkdir -p "$OUT_DIR/gen_${OUT_NAME}"

[[ -x "$CLANGXX" ]] || { echo "NDK clang++ not found at $CLANGXX" >&2; exit 1; }

INC_ARGS=(-I "$GEN_HDR" -I "$INC_PLAT")
for d in "${EXTRA_INC[@]}"; do INC_ARGS+=(-I "$d"); done

PIC_FLAGS=(); [[ "$SHARED" == 1 ]] && PIC_FLAGS+=(-fPIC)
CXX_FLAGS=(-std=c++17 -O2 -fno-rtti -static-libstdc++ -DBINDER_STABILITY_SUPPORT "${PIC_FLAGS[@]}" "${EXTRA_CXXFLAGS[@]}")
C_FLAGS=(-std=c11 -O2 -Wall -Wextra -DBINDER_STABILITY_SUPPORT "${PIC_FLAGS[@]}" "${EXTRA_CFLAGS[@]}")
CLANG="${CLANGXX%++}"
# compile a source file to an object
compile_one() {
  if [[ "$1" == *.c ]]; then
    "$CLANG" -c "${C_FLAGS[@]}" "${INC_ARGS[@]}" -o "$2" "$1"
  else
    "$CLANGXX" -c "${CXX_FLAGS[@]}" "${INC_ARGS[@]}" -o "$2" "$1"
  fi
}

echo "[build-hal] compiling $SRC -> ${OUT_NAME}.o"
compile_one "$SRC" "$OUT_DIR/gen_${OUT_NAME}/${OUT_NAME}.o"

# hash a source file with its headers
src_key() {
  local cpp="$1" d f
  local files=("$cpp")
  d="$(dirname "$cpp")"
  for f in "$d"/*.h "$d"/*.hpp; do [[ -f "$f" ]] && files+=("$f"); done
  for d in "${EXTRA_INC[@]}"; do
    for f in "$d"/*.h "$d"/*.hpp; do [[ -f "$f" ]] && files+=("$f"); done
  done
  { readlink -f "$CLANGXX"; printf '%s\n' "${CXX_FLAGS[@]}"
    [[ "$cpp" == *.c ]] && printf '%s\n' "${C_FLAGS[@]}"
    cat "${files[@]}"; } | sha256sum | cut -c1-12
}

GEN_OBJS=()
if [[ ${#EXTRA_SRC[@]} -gt 0 ]]; then
  extra_dir="$OUT_DIR/gen_${OUT_NAME}/extra"
  mkdir -p "$extra_dir"
  n_compiled=0; n_cached=0
  for cpp in "${EXTRA_SRC[@]}"; do
    [[ -f "$cpp" ]] || { echo "[build-hal] --extra-src not found: $cpp" >&2; exit 1; }
    obj="$extra_dir/$(echo "${cpp#"$ROOT/"}" | sed 's/\//_/g').$(src_key "$cpp").o"
    if [[ -f "$obj" ]]; then
      n_cached=$((n_cached+1))
    else
      compile_one "$cpp" "$obj" || exit 1
      n_compiled=$((n_compiled+1))
    fi
    GEN_OBJS+=("$obj")
  done
  echo "[build-hal] --extra-src: $n_compiled compiled, $n_cached cached"
fi
for name in "${AIDL_NAMES[@]}"; do
  while IFS= read -r f; do GEN_OBJS+=("$f"); done < <(find "$OUT_DIR/gen" -iname "*${name}*.cpp.o")
done
if [[ ${#AIDL_NAMES[@]} -gt 0 && ${#GEN_OBJS[@]} -eq 0 ]]; then
  echo "[build-hal] WARNING: --aidl given but no matching *.cpp.o found under toolchain/out/gen/" >&2
fi

for src_dir in "${AIDL_SRC_DIRS[@]}"; do
  base="$(basename "$src_dir")_$(basename "$(dirname "$src_dir")")"
  cache_dir="$OUT_DIR/gen_aidl_src/$base"
  mkdir -p "$cache_dir"
  n_compiled=0; n_cached=0
  while IFS= read -r cpp; do
    obj="$cache_dir/$(echo "$cpp" | sed 's/\//_/g').$(src_key "$cpp").o"
    if [[ -f "$obj" ]]; then
      n_cached=$((n_cached+1))
    else
      "$CLANGXX" -c "${CXX_FLAGS[@]}" "${INC_ARGS[@]}" -o "$obj" "$cpp" || exit 1
      n_compiled=$((n_compiled+1))
    fi
    GEN_OBJS+=("$obj")
  done < <(find "$src_dir" -iname "*.cpp")
  echo "[build-hal] --aidl-src $src_dir: $n_compiled compiled, $n_cached cached"
done

if [[ "$SHARED" == 1 || "${NO_DEFAULT_LIBS:-0}" == 1 ]]; then
  LINK_LIBS=()
else
  LINK_LIBS=(-lbinder_ndk -lbase -lbinder -lutils -lcutils -llog -lc -ldl -lm)
fi
for s in "${SO_LIBS[@]}"; do LINK_LIBS+=(-l"$s"); done
for f in "${EXACT_SO[@]}"; do LINK_LIBS+=(-l:"$f"); done

SHARED_FLAGS=(); [[ "$SHARED" == 1 ]] && SHARED_FLAGS+=(-shared -fPIC)

echo "[build-hal] linking ${OUT_NAME} (${#GEN_OBJS[@]} AIDL glue objects, ${#LINK_LIBS[@]} link flags)"
"$CLANGXX" -static-libstdc++ "${SHARED_FLAGS[@]}" \
  "$OUT_DIR/gen_${OUT_NAME}/${OUT_NAME}.o" "${GEN_OBJS[@]}" \
  -L "$LIBDIR" "${LINK_LIBS[@]}" \
  -o "$OUT_DIR/${OUT_NAME}"

if [[ "$SHARED" == 1 ]]; then
  if [[ -n "$STAGE_DIR" ]]; then
    echo "[build-hal] OK -> ${OUT_DIR#"$ROOT/"}/${OUT_NAME}"
  else
    echo "[build-hal] OK -> ${OUT_DIR#"$ROOT/"}/${OUT_NAME} (pass --stage gfx_hal / gpu_driver, or stage it yourself)"
  fi
elif [[ "$ABI" == x86 || "$ABI" == arm64-v8a ]]; then
  if [[ -n "$STAGE_DIR" ]]; then
    echo "[build-hal] OK -> ${OUT_DIR#"$ROOT/"}/${OUT_NAME} (--abi $ABI executable)"
  else
    echo "[build-hal] OK -> ${OUT_DIR#"$ROOT/"}/${OUT_NAME} (--abi $ABI executable, pass --stage or stage it yourself)"
  fi
else
  mkdir -p "$ROOT/var/bin"
  cp --remove-destination "$OUT_DIR/${OUT_NAME}" "$ROOT/var/bin/${OUT_NAME}"
  cp --remove-destination "$OUT_DIR/${OUT_NAME}" "$ROOT/var/share/${OUT_NAME}"
  echo "[build-hal] OK -> var/bin/${OUT_NAME} and var/share/${OUT_NAME}"
fi
if [[ -n "$STAGE_DIR" ]]; then
  install -D -m 0755 "$OUT_DIR/${OUT_NAME}" "$ROOT/var/share/${STAGE_DIR}/${OUT_NAME}"
  echo "[build-hal] staged -> var/share/${STAGE_DIR}/${OUT_NAME}"
fi
readelf -d "$OUT_DIR/${OUT_NAME}" | grep NEEDED
