#!/bin/bash
# toolchain/llvm-android/build-android-x86_64 RHIZO_INPUT_CACHE=
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../env.sh

REPO_ROOT="$(cd "$(dirname "$SELF")/../../.." && pwd)"
LLVM_VERSION=18.1.8
API=35
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
CACHE_TAR="$CACHE/llvm/llvm-project-$LLVM_VERSION.src.tar.xz"
DL_DIR="$REPO_ROOT/toolchain/llvm-android"
SRC_TAR="$DL_DIR/llvm-project-$LLVM_VERSION.src.tar.xz"
SRC_DIR="$DL_DIR/llvm-project-$LLVM_VERSION.src"
BUILD_DIR="$DL_DIR/build-android-x86_64"
MARKER=.rhizo-build
NDK="$(readlink -f "$REPO_ROOT/toolchain/ndk_extract/android-ndk-r27c")"
HOST_TBLGEN=/usr/bin/llvm-tblgen-18

LLVM_LIBS=(
  LLVMAggressiveInstCombine LLVMAnalysis LLVMAsmParser LLVMAsmPrinter
  LLVMBinaryFormat LLVMBitReader LLVMBitWriter LLVMBitstreamReader
  LLVMCFGuard LLVMCodeGen LLVMCodeGenTypes LLVMCore LLVMCoroutines
  LLVMCoverage LLVMDebugInfoBTF LLVMDebugInfoCodeView LLVMDebugInfoDWARF
  LLVMDebugInfoMSF LLVMDebugInfoPDB LLVMDemangle LLVMExecutionEngine
  LLVMExtensions LLVMFileCheck LLVMFrontendOffloading LLVMFrontendOpenACC
  LLVMFrontendOpenMP LLVMGlobalISel LLVMHipStdPar LLVMIRPrinter
  LLVMIRReader LLVMInstCombine LLVMInstrumentation LLVMInterpreter
  LLVMJITLink LLVMLinker LLVMMC LLVMMCA LLVMMCDisassembler LLVMMCJIT
  LLVMMCParser LLVMObjCARCOpts LLVMObject LLVMOption LLVMOrcJIT
  LLVMOrcShared LLVMOrcTargetProcess LLVMPasses LLVMProfileData
  LLVMRemarks LLVMRuntimeDyld LLVMScalarOpts LLVMSelectionDAG LLVMSupport
  LLVMSymbolize LLVMTableGen LLVMTableGenCommon LLVMTableGenGlobalISel
  LLVMTarget LLVMTargetParser LLVMTextAPI LLVMTransformUtils LLVMVectorize
  LLVMWindowsDriver LLVMX86AsmParser LLVMX86CodeGen LLVMX86Desc
  LLVMX86Disassembler LLVMX86Info LLVMX86TargetMCA LLVMipo
)
CMAKE_ARGS=(
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI=x86_64 -DANDROID_PLATFORM="android-$API"
  -DCMAKE_BUILD_TYPE=Release
  -DLLVM_TARGETS_TO_BUILD=X86
  -DLLVM_HOST_TRIPLE="x86_64-none-linux-android$API"
  -DLLVM_TABLEGEN="$HOST_TBLGEN"
  -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF
  -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_BUILD_TOOLS=OFF -DLLVM_BUILD_UTILS=OFF
)

# return whether $1/lib has lib<name>.a for each LLVM_LIBS entry
all_present() {
  local f
  for f in "${LLVM_LIBS[@]}"; do
    [[ -f "$1/lib/lib${f}.a" ]] || return 1
  done
}

# print the $MARKER record for source sha256 $1
build_marker() {
  echo "llvm-source: llvm-project-$LLVM_VERSION.src.tar.xz sha256 $1"
  echo "script: sha256 $(sha256sum "$SELF" | cut -d' ' -f1)"
  echo "ndk: $(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties" 2>/dev/null)"
  echo "tblgen: $("$HOST_TBLGEN" --version 2>/dev/null | sed -n 's/.*LLVM version //p' | head -1)"
  echo "cmake: ${CMAKE_ARGS[*]}"
}

# return whether $1 has each LLVM_LIBS library and a $MARKER equal to $2
build_current() {
  all_present "$1" && [[ -f "$1/$MARKER" && "$(cat "$1/$MARKER")" == "$2" ]]
}

# rename $1 to $2 and delete the replaced $2
swap_into_place() {
  local new="$1" dest="$2" old=""
  if [[ -e "$dest" ]]; then
    old="$dest.old.$$"
    rm -rf "$old"
    mv "$dest" "$old" || return 1
  fi
  if ! mv "$new" "$dest"; then
    [[ -z "$old" ]] || mv "$old" "$dest"
    return 1
  fi
  [[ -z "$old" ]] || rm -rf "$old"
}

# extract llvm/ and cmake/ of the pinned source tarball into SRC_DIR
place_source() {
  local sha="$1" part="$SRC_TAR.part.$$" tmp
  [[ "$(cat "$SRC_DIR/.rhizo-input" 2>/dev/null)" == "$sha" ]] && return 0
  { cp "$CACHE_TAR" "$part" && mv "$part" "$SRC_TAR"; } || { rm -f "$part"; log "no $CACHE_TAR"; return 1; }
  tmp=$(mktemp -d "$DL_DIR/extract.XXXXXX") || return 1
  if ! tar xf "$SRC_TAR" -C "$tmp" "llvm-project-$LLVM_VERSION.src/llvm" "llvm-project-$LLVM_VERSION.src/cmake"; then
    rm -rf "$tmp"; log "tar xf $SRC_TAR failed"; return 1
  fi
  printf '%s\n' "$sha" > "$tmp/llvm-project-$LLVM_VERSION.src/.rhizo-input"
  swap_into_place "$tmp/llvm-project-$LLVM_VERSION.src" "$SRC_DIR" || { rm -rf "$tmp"; return 1; }
  rmdir "$tmp"
}

# create a mode 0755 $BUILD_DIR.new.XXXXXX directory
new_build_dir() {
  local new
  new=$(mktemp -d "$BUILD_DIR.new.XXXXXX") || return 1
  chmod 0755 "$new" || { rmdir "$new"; return 1; }
  printf '%s\n' "$new"
}

# build LLVM_LIBS in a new_build_dir directory and swap_into_place that directory to BUILD_DIR
build_in_new_dir() {
  local marker="$1" new
  new=$(new_build_dir) || return 1
  cmake -G Ninja "$SRC_DIR/llvm" -B "$new" "${CMAKE_ARGS[@]}" || { rm -rf "$new"; log "cmake -G Ninja failed"; return 1; }
  if (( CONFIGURE_ONLY )); then
    rm -rf "$new"; log "cmake -G Ninja succeeded"; return 0
  fi
  ninja -C "$new" -j"$(nproc)" "${LLVM_LIBS[@]}" || { rm -rf "$new"; log "ninja failed"; return 1; }
  all_present "$new" || { rm -rf "$new"; log "$new/lib has no library for an LLVM_LIBS entry"; return 1; }
  printf '%s\n' "$marker" > "$new/$MARKER"
  swap_into_place "$new" "$BUILD_DIR" || { rm -rf "$new"; log "failed to rename $new to $BUILD_DIR"; return 1; }
  log "wrote ${#LLVM_LIBS[@]} libraries to $BUILD_DIR/lib"
}

# test the build helpers on fixtures
selftest() {
  local fail=0 tmp out want f fixture sha
  tmp=$(mktemp -d)
  out=$(build_marker abc123)
  for want in "llvm-source: llvm-project-$LLVM_VERSION.src.tar.xz sha256 abc123" "script: sha256 " "ndk: " "tblgen: " "-DLLVM_HOST_TRIPLE=x86_64-none-linux-android$API"; do
    [[ "$out" == *"$want"* ]] || { echo "FAIL build_marker abc123 contains $want ($out)"; fail=1; }
  done
  grep -q "x86_64-linux-android${API}-clang'" "$REPO_ROOT/tools/mesa/mesa-cross-x86_64-android" \
    || { echo "FAIL tools/mesa/mesa-cross-x86_64-android has x86_64-linux-android${API}-clang"; fail=1; }
  mkdir -p "$tmp/b/lib"
  for f in "${LLVM_LIBS[@]}"; do : > "$tmp/b/lib/lib$f.a"; done
  printf '%s\n' "$out" > "$tmp/b/$MARKER"
  build_current "$tmp/b" "$out" || { echo "FAIL build_current with each library and an equal marker returns 0"; fail=1; }
  build_current "$tmp/b" "$(build_marker def456)" && { echo "FAIL build_current with the def456 marker returns 1"; fail=1; }
  rm "$tmp/b/lib/libLLVMCore.a"
  build_current "$tmp/b" "$out" && { echo "FAIL build_current without libLLVMCore.a returns 1"; fail=1; }
  : > "$tmp/b/lib/libLLVMCore.a"; rm "$tmp/b/$MARKER"
  build_current "$tmp/b" "$out" && { echo "FAIL build_current without $MARKER returns 1"; fail=1; }
  mkdir -p "$tmp/dest" "$tmp/new"; echo old > "$tmp/dest/f"; echo old > "$tmp/dest/only-old"; echo new > "$tmp/new/f"
  swap_into_place "$tmp/new" "$tmp/dest" || { echo "FAIL swap_into_place new dest returns 0"; fail=1; }
  [[ "$(cat "$tmp/dest/f" 2>/dev/null)" == new && ! -e "$tmp/dest/only-old" && ! -e "$tmp/new" ]] \
    || { echo "FAIL dest == new after swap_into_place"; fail=1; }
  compgen -G "$tmp/dest.old.*" >/dev/null && { echo "FAIL swap_into_place deletes dest.old.*"; fail=1; }
  mkdir "$tmp/n2"; echo x > "$tmp/n2/f"
  swap_into_place "$tmp/n2" "$tmp/absent" && [[ -f "$tmp/absent/f" ]] || { echo "FAIL swap_into_place n2 absent creates absent/f"; fail=1; }
  f=$(BUILD_DIR="$tmp/bd" new_build_dir) && [[ "$(stat -c %a "$f")" == 755 && "$f" == "$tmp/bd.new."* ]] \
    || { echo "FAIL new_build_dir creates a mode 755 $BUILD_DIR.new.* directory ($f $(stat -c %a "$f" 2>/dev/null))"; fail=1; }
  out=$(CACHE_TAR="$tmp/missing.tar.xz" SRC_TAR="$tmp/s.tar.xz" SRC_DIR="$tmp/src" DL_DIR="$tmp" place_source abc 2>&1)
  [[ $? -ne 0 && ! -e "$tmp/s.tar.xz" ]] && ! compgen -G "$tmp/s.tar.xz.part*" >/dev/null \
    || { echo "FAIL place_source without CACHE_TAR returns 1 and creates no s.tar.xz ($out)"; fail=1; }
  fixture="$tmp/fx/llvm-project-$LLVM_VERSION.src"; mkdir -p "$fixture/llvm" "$fixture/cmake" "$tmp/dl"
  echo src > "$fixture/llvm/CMakeLists.txt"; echo cm > "$fixture/cmake/x"
  tar cf "$tmp/in.tar.xz" -C "$tmp/fx" "llvm-project-$LLVM_VERSION.src"
  sha=$(sha256sum "$tmp/in.tar.xz" | cut -d' ' -f1)
  ( CACHE_TAR="$tmp/in.tar.xz" SRC_TAR="$tmp/dl/s.tar.xz" SRC_DIR="$tmp/dl/llvm-project-$LLVM_VERSION.src" DL_DIR="$tmp/dl"
    place_source "$sha" >/dev/null 2>&1 || exit 1
    [[ -f "$SRC_DIR/llvm/CMakeLists.txt" && "$(cat "$SRC_DIR/.rhizo-input")" == "$sha" ]] || exit 1
    : > "$SRC_DIR/kept"; rm "$SRC_TAR"
    place_source "$sha" >/dev/null 2>&1 && [[ -e "$SRC_DIR/kept" ]] || exit 2
    place_source other >/dev/null 2>&1 && [[ ! -e "$SRC_DIR/kept" && "$(cat "$SRC_DIR/.rhizo-input")" == other ]] || exit 3
    [[ -z "$(find "$DL_DIR" -maxdepth 1 -name 'extract.*')" ]] || exit 4 ) \
    || { echo "FAIL place_source extracts when .rhizo-input != the tarball sha256 and deletes extract.* (step $?)"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "FAIL llvm-android.sh --selftest"; return 1; fi
  echo "ok llvm-android.sh --selftest"
}

FORCE=0 CONFIGURE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --configure-only) CONFIGURE_ONLY=1; shift ;;
    --selftest) selftest; exit $? ;;
    -h|--help) echo "$0 [--force] [--configure-only] [--selftest]" >&2; exit 0 ;;
    *) log "unknown option $1"; exit 2 ;;
  esac
done

[[ -f "$CACHE_TAR" ]] || { log "no $CACHE_TAR"; exit 1; }
mkdir -p "$DL_DIR"
exec 9>"$DL_DIR/.build.lock"
flock -w 3600 9 || { log "flock -w 3600 $DL_DIR/.build.lock failed"; exit 1; }
TAR_SHA=$(sha256sum "$CACHE_TAR" | cut -d' ' -f1)
WANT=$(build_marker "$TAR_SHA")
if (( ! FORCE && ! CONFIGURE_ONLY )) && build_current "$BUILD_DIR" "$WANT"; then
  log "build_current $BUILD_DIR returned 0"
  exit 0
fi
[[ -x "$HOST_TBLGEN" ]] || { log "no $HOST_TBLGEN"; exit 1; }
[[ -d "$NDK" ]] || { log "no $NDK"; exit 1; }
place_source "$TAR_SHA" || exit 1
build_in_new_dir "$WANT" || exit 1
