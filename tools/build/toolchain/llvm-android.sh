#!/bin/bash
# build LLVM 18.1.8 libraries for Android x86_64
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../../test/vm/common.sh

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

# check all LLVM libraries exist in a build directory
all_present() {
  local f
  for f in "${LLVM_LIBS[@]}"; do
    [[ -f "$1/lib/lib${f}.a" ]] || return 1
  done
}

# print the inputs a build records in its directory
build_marker() {
  echo "llvm-source: llvm-project-$LLVM_VERSION.src.tar.xz sha256 $1"
  echo "script: sha256 $(sha256sum "$SELF" | cut -d' ' -f1)"
  echo "ndk: $(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties" 2>/dev/null)"
  echo "tblgen: $("$HOST_TBLGEN" --version 2>/dev/null | sed -n 's/.*LLVM version //p' | head -1)"
  echo "cmake: ${CMAKE_ARGS[*]}"
}

# check a build directory is complete and current
build_current() {
  all_present "$1" && [[ -f "$1/$MARKER" && "$(cat "$1/$MARKER")" == "$2" ]]
}

# move a finished directory into place
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

# extract the pinned source tree
place_source() {
  local sha="$1" part="$SRC_TAR.part.$$" tmp
  [[ "$(cat "$SRC_DIR/.rhizo-input" 2>/dev/null)" == "$sha" ]] && return 0
  { cp "$CACHE_TAR" "$part" && mv "$part" "$SRC_TAR"; } || { rm -f "$part"; log "no pinned LLVM source at $CACHE_TAR: make inputs"; return 1; }
  tmp=$(mktemp -d "$DL_DIR/extract.XXXXXX") || return 1
  log "extracting llvm/ and cmake/ (skipping clang, lld, every other component this build never uses)"
  if ! tar xf "$SRC_TAR" -C "$tmp" "llvm-project-$LLVM_VERSION.src/llvm" "llvm-project-$LLVM_VERSION.src/cmake"; then
    rm -rf "$tmp"; log "extract failed"; return 1
  fi
  printf '%s\n' "$sha" > "$tmp/llvm-project-$LLVM_VERSION.src/.rhizo-input"
  swap_into_place "$tmp/llvm-project-$LLVM_VERSION.src" "$SRC_DIR" || { rm -rf "$tmp"; return 1; }
  rmdir "$tmp"
}

# make a new build directory beside BUILD_DIR
new_build_dir() {
  local new
  new=$(mktemp -d "$BUILD_DIR.new.XXXXXX") || return 1
  chmod 0755 "$new" || { rmdir "$new"; return 1; }
  printf '%s\n' "$new"
}

# build into a new directory and move it into place
build_in_new_dir() {
  local marker="$1" new
  new=$(new_build_dir) || return 1
  log "configuring the cross build in ${new##*/} (NDK toolchain, host tblgen, X86-only target, host triple x86_64-none-linux-android$API)"
  cmake -G Ninja "$SRC_DIR/llvm" -B "$new" "${CMAKE_ARGS[@]}" || { rm -rf "$new"; log "cmake configure failed"; return 1; }
  if (( CONFIGURE_ONLY )); then
    rm -rf "$new"; log "--configure-only: the configure succeeded; nothing was built or replaced"; return 0
  fi
  log "building ${#LLVM_LIBS[@]} named LLVM static libraries, not the default 'all' target"
  ninja -C "$new" -j"$(nproc)" "${LLVM_LIBS[@]}" || { rm -rf "$new"; log "ninja failed"; return 1; }
  all_present "$new" || { rm -rf "$new"; log "build finished but a library is still missing -- check the LLVM_LIBS list"; return 1; }
  printf '%s\n' "$marker" > "$new/$MARKER"
  swap_into_place "$new" "$BUILD_DIR" || { rm -rf "$new"; log "could not move the finished build into $BUILD_DIR"; return 1; }
  log "LLVM cross build for Android/bionic x86_64 complete: ${#LLVM_LIBS[@]} libraries under $BUILD_DIR/lib"
}

# test the build helpers on fixtures
selftest() {
  local fail=0 tmp out want f fixture sha
  tmp=$(mktemp -d)
  out=$(build_marker abc123)
  for want in "llvm-source: llvm-project-$LLVM_VERSION.src.tar.xz sha256 abc123" "script: sha256 " "ndk: " "tblgen: " "-DLLVM_HOST_TRIPLE=x86_64-none-linux-android$API"; do
    [[ "$out" == *"$want"* ]] || { echo "SELFTEST FAILED: the build marker lacks '$want' -- got: $out"; fail=1; }
  done
  grep -q "x86_64-linux-android${API}-clang'" "$REPO_ROOT/tools/mesa/mesa-cross-x86_64-android" \
    || { echo "SELFTEST FAILED: tools/mesa/mesa-cross-x86_64-android does not build for android$API, the API level the host triple names"; fail=1; }
  mkdir -p "$tmp/b/lib"
  for f in "${LLVM_LIBS[@]}"; do : > "$tmp/b/lib/lib$f.a"; done
  printf '%s\n' "$out" > "$tmp/b/$MARKER"
  build_current "$tmp/b" "$out" || { echo "SELFTEST FAILED: a complete build with the same marker was not read as current"; fail=1; }
  build_current "$tmp/b" "$(build_marker def456)" && { echo "SELFTEST FAILED: a build from another source tarball was read as current"; fail=1; }
  rm "$tmp/b/lib/libLLVMCore.a"
  build_current "$tmp/b" "$out" && { echo "SELFTEST FAILED: a build missing libLLVMCore.a was read as current"; fail=1; }
  : > "$tmp/b/lib/libLLVMCore.a"; rm "$tmp/b/$MARKER"
  build_current "$tmp/b" "$out" && { echo "SELFTEST FAILED: a build with no marker was read as current"; fail=1; }
  mkdir -p "$tmp/dest" "$tmp/new"; echo old > "$tmp/dest/f"; echo old > "$tmp/dest/only-old"; echo new > "$tmp/new/f"
  swap_into_place "$tmp/new" "$tmp/dest" || { echo "SELFTEST FAILED: swap_into_place refused a plain swap"; fail=1; }
  [[ "$(cat "$tmp/dest/f" 2>/dev/null)" == new && ! -e "$tmp/dest/only-old" && ! -e "$tmp/new" ]] \
    || { echo "SELFTEST FAILED: the swap did not leave exactly the new tree in place"; fail=1; }
  compgen -G "$tmp/dest.old.*" >/dev/null && { echo "SELFTEST FAILED: the swap left the replaced tree behind"; fail=1; }
  mkdir "$tmp/n2"; echo x > "$tmp/n2/f"
  swap_into_place "$tmp/n2" "$tmp/absent" && [[ -f "$tmp/absent/f" ]] || { echo "SELFTEST FAILED: a swap into an absent path failed"; fail=1; }
  f=$(BUILD_DIR="$tmp/bd" new_build_dir) && [[ "$(stat -c %a "$f")" == 755 && "$f" == "$tmp/bd.new."* ]] \
    || { echo "SELFTEST FAILED: a new build directory is not 0755 beside BUILD_DIR, as its siblings are -- got: $f $(stat -c %a "$f" 2>/dev/null)"; fail=1; }
  out=$(CACHE_TAR="$tmp/missing.tar.xz" SRC_TAR="$tmp/s.tar.xz" SRC_DIR="$tmp/src" DL_DIR="$tmp" place_source abc 2>&1)
  [[ $? -ne 0 && ! -e "$tmp/s.tar.xz" ]] && ! compgen -G "$tmp/s.tar.xz.part*" >/dev/null \
    || { echo "SELFTEST FAILED: a failed copy of the source left a tarball behind -- got: $out"; fail=1; }
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
    || { echo "SELFTEST FAILED: place_source did not extract once per tarball digest and clean up (step $?)"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "llvm-android.sh selftest: FAILED"; return 1; fi
  echo "llvm-android.sh selftest: ok"
}

FORCE=0 CONFIGURE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --configure-only) CONFIGURE_ONLY=1; shift ;;
    --selftest) selftest; exit $? ;;
    -h|--help) echo "usage: $0 [--force] [--configure-only] [--selftest]" >&2; exit 0 ;;
    *) log "unknown option: $1"; exit 2 ;;
  esac
done

[[ -f "$CACHE_TAR" ]] || { log "no pinned LLVM source at $CACHE_TAR: make inputs"; exit 1; }
mkdir -p "$DL_DIR"
exec 9>"$DL_DIR/.build.lock"
flock -w 3600 9 || { log "another LLVM build held $DL_DIR/.build.lock for an hour"; exit 1; }
TAR_SHA=$(sha256sum "$CACHE_TAR" | cut -d' ' -f1)
WANT=$(build_marker "$TAR_SHA")
if (( ! FORCE && ! CONFIGURE_ONLY )) && build_current "$BUILD_DIR" "$WANT"; then
  log "all ${#LLVM_LIBS[@]} LLVM libraries under $BUILD_DIR/lib were built from these inputs -- nothing to do (--force to rebuild)"
  exit 0
fi
[[ -x "$HOST_TBLGEN" ]] || { log "no host llvm-tblgen at $HOST_TBLGEN (apt install llvm-18)"; exit 1; }
[[ -d "$NDK" ]] || { log "no NDK at $NDK -- run tools/fetch/build-inputs.sh --only ndk"; exit 1; }
place_source "$TAR_SHA" || exit 1
build_in_new_dir "$WANT" || exit 1
