#!/bin/bash
# build the shipping payload in a new clone
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")/.." || exit
source ../vm/common.sh
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
MIN_FREE_KB=$((20 * 1024 * 1024))
SCRATCH="" KEEP=0 REF_SHARE="$VAR_DIR/share"
CLONE=""
T0=$SECONDS

ISOLATION_PATHS=(mesa-src toolchain aosp-android16-qpr2 var/share var/share-1 var/gsi var/gsi-dl .rhizo-inputs.tsv)
ATTRIBUTED_GFX_HAL=(libgallium_dri.so libgbm_mesa.so libdrm.so dri_gbm.so libc++_shared.so libcutils_real.so)
NEVER_SHIPPED=(adbkey.pub rhizo-test-fixture m2_gate_test rhizo-adbd-debug-shim.so)

fail() { log "FAIL: $*"; return 1; }

# reject a scratch directory inside the source tree
scratch_allowed() {
  local real_scratch real_src
  real_src=$(readlink -f "$SRC_ROOT"); real_scratch=$(readlink -f "$(dirname "$1")")/$(basename "$1")
  [[ "$real_scratch" != "$real_src"/* && "$real_scratch" != *"/.worktrees/"* ]] \
    || { fail "the scratch dir $1 is inside the source tree or a worktree"; return 1; }
}

# check the source tree and scratch directory
preflight() {
  git -C "$SRC_ROOT" diff --quiet && git -C "$SRC_ROOT" diff --cached --quiet \
    || { fail "the source tree has uncommitted changes"; return 1; }
  [[ -n "$SCRATCH" ]] || SCRATCH="${TMPDIR:-/var/tmp}/rhizo-clean-clone.$$"
  scratch_allowed "$SCRATCH" || return 1
  [[ ! -e "$SCRATCH" ]] || { fail "the scratch dir $SCRATCH already exists"; return 1; }
  local free_kb; free_kb=$(df -k --output=avail "$(dirname "$SCRATCH")" | tail -1 | tr -d ' ')
  (( free_kb >= MIN_FREE_KB )) \
    || { fail "only $((free_kb / 1024 / 1024))G free under $(dirname "$SCRATCH"); want $((MIN_FREE_KB / 1024 / 1024))G"; return 1; }
  if [[ -z "${RHIZO_AOSP_DIR:-}" && -e "$SRC_ROOT/aosp-android16-qpr2" ]]; then
    export RHIZO_AOSP_DIR; RHIZO_AOSP_DIR=$(readlink -f "$SRC_ROOT/aosp-android16-qpr2")
  fi
  export RHIZO_INPUT_CACHE="$CACHE"
  [[ -d "$REF_SHARE/gpu_driver" && -d "$REF_SHARE/gpu_driver_32" ]] \
    || { fail "the reference share $REF_SHARE has no gpu_driver and gpu_driver_32 to compare against"; return 1; }
}

# clone the current branch into the scratch directory
clone_branch() {
  local branch head
  branch=$(git -C "$SRC_ROOT" branch --show-current)
  [[ -n "$branch" ]] || { fail "the source tree is not on a branch"; return 1; }
  git clone --quiet --branch "$branch" --single-branch "$SRC_ROOT" "$SCRATCH" || { fail "git clone failed"; return 1; }
  CLONE="$SCRATCH"
  head=$(git -C "$CLONE" rev-parse HEAD)
  [[ "$head" == "$(git -C "$SRC_ROOT" rev-parse HEAD)" ]] || { fail "the clone's HEAD $head is not the source's"; return 1; }
  log "cloned $branch ($head) into $CLONE"
}

# check the clone for build outputs
assert_isolated() {
  local c="$1" p f
  for p in "${ISOLATION_PATHS[@]}"; do
    [[ ! -e "$c/$p" && ! -L "$c/$p" ]] || { fail "the clone is not clean: $p exists"; return 1; }
  done
  for f in tools/mesa/mesa-cross-x86_64-android tools/mesa/mesa-cross-x86-android; do
    [[ -f "$c/$f" && ! -L "$c/$f" ]] || { fail "$f is not a regular file in the clone"; return 1; }
    grep -q '@DIRNAME@' "$c/$f" || { fail "$f does not locate the NDK relative to itself"; return 1; }
    ! grep -q '/home/' "$c/$f" || { fail "$f names a home directory"; return 1; }
  done
  log "the clone starts clean: none of ${ISOLATION_PATHS[*]}"
}

# check the symlinks in the clone
audit_symlinks() {
  local c="$1" l target real_clone real_cache real_aosp="" bad=0
  real_clone=$(readlink -f "$c"); real_cache=$(readlink -f "$CACHE")
  [[ -n "${RHIZO_AOSP_DIR:-}" ]] && real_aosp=$(readlink -f "$RHIZO_AOSP_DIR")
  while IFS= read -r l; do
    target=$(readlink -f "$l")
    if [[ "$target" == "$real_clone"/* || "$target" == "$real_cache" || "$target" == "$real_cache"/* \
          || ( -n "$real_aosp" && ( "$target" == "$real_aosp" || "$target" == "$real_aosp"/* ) ) ]]; then
      continue
    fi
    log "symlink ${l#$c/} -> $target points outside the input cache and the AOSP checkout"; bad=1
  done < <(find "$c" -path "$c/.git" -prune -o -type l -print)
  (( bad == 0 )) || { fail "the clone reaches this machine's trees through a symlink"; return 1; }
  log "every symlink in the clone resolves into $real_cache or ${real_aosp:-<no aosp>}"
}

# compare two gpu driver trees
compare_driver() {
  local a="$1" b="$2" fa fb la lb f sa sb na nb va vb
  la=$(cd "$a" && find . -type f | sort); lb=$(cd "$b" && find . -type f | sort)
  [[ "$la" == "$lb" ]] || { log "file sets differ:"; diff <(echo "$lb") <(echo "$la") | sed 's/^/    /'; return 1; }
  while IFS= read -r f; do
    fa="$a/$f"; fb="$b/$f"
    [[ "$(file -b "$fa" | cut -d, -f1-2)" == "$(file -b "$fb" | cut -d, -f1-2)" ]] || { log "$f: ELF class differs: $(file -b "$fa" | cut -d, -f1-2) vs $(file -b "$fb" | cut -d, -f1-2)"; return 1; }
    sa=$(patchelf --print-soname "$fa" 2>/dev/null || echo -); sb=$(patchelf --print-soname "$fb" 2>/dev/null || echo -)
    [[ "$sa" == "$sb" ]] || { log "$f: SONAME differs: '$sa' vs '$sb'"; return 1; }
    na=$(patchelf --print-needed "$fa" | sort | tr '\n' ' '); nb=$(patchelf --print-needed "$fb" | sort | tr '\n' ' ')
    [[ "$na" == "$nb" ]] || { log "$f: NEEDED differs: [$na] vs [$nb]"; return 1; }
    case "$f" in ./lib/libgallium_dri.so)
      va=$(strings -n 8 "$fa" | grep -oE 'Mesa [0-9]+\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')
      vb=$(strings -n 8 "$fb" | grep -oE 'Mesa [0-9]+\.[0-9]+\.[0-9]+' | sort -u | tr '\n' ' ')
      [[ -n "$va" && "$va" == "$vb" ]] || { log "$f: Mesa version differs: '$va' vs '$vb'"; return 1; } ;;
    esac
    local same=no; cmp -s "$fa" "$fb" && same=yes
    log "  ${f#./}: soname=$sa needed=$(wc -w <<<"$na") same-bytes=$same"
  done <<<"$la"
}

# check packaged paths against debian/copyright
assert_attributed() {
  local listing="$1" copyright="$2" paths p bad=0
  paths=$(awk '/^Files:/{f=1; sub(/^Files:[ \t]*/,""); if ($0!="") print; next} f && /^ /{sub(/^ +/,""); print; next} {f=0}' "$copyright")
  while IFS= read -r p; do
    p="${p#./}"
    case "$p" in
      usr/lib/rhizo/gpu_driver/*|usr/lib/rhizo/gpu_driver_32/*|usr/lib/rhizo/gpu_driver_software/*|usr/lib/rhizo/tools/aapt2|usr/lib/rhizo/rhizo-keymint-service) ;;
      usr/lib/rhizo/gfx_hal/*) [[ " ${ATTRIBUTED_GFX_HAL[*]} " == *" $(basename "$p") "* ]] || continue ;;
      *) continue ;;
    esac
    [[ "$p" == */ ]] && continue
    grep -qx "$p" <<<"$paths" || { log "$p ships with no Files: stanza in debian/copyright"; bad=1; }
  done < <(awk '{print $6}' "$listing")
  (( bad == 0 )) || { fail "the package ships third-party files debian/copyright does not name"; return 1; }
}

# build the rhizo package in the clone and check its contents
package_and_check() {
  local deb listing
  ( cd "$CLONE" && tools/build/packaging/deb/debs.sh ) || { fail "debs.sh failed in the clone"; return 1; }
  deb=$(ls "$CLONE"/var/debs/rhizo_*.deb 2>/dev/null | head -1)
  [[ -f "$deb" ]] || { fail "no rhizo_*.deb under $CLONE/var/debs"; return 1; }
  listing="$CLONE/var/debs/rhizo.deb.list"
  dpkg-deb -c "$deb" > "$listing" || { fail "dpkg-deb -c failed on $deb"; return 1; }
  local want p
  for want in usr/lib/rhizo/gpu_driver/egl/libEGL_rhizo.so usr/lib/rhizo/gpu_driver_32/egl/libEGL_rhizo.so usr/lib/rhizo/gpu_driver_software/lib/libgallium_dri.so usr/share/doc/rhizo/gpu_driver.PROVENANCE usr/lib/rhizo/gfx_hal/rhizo-composer usr/lib/rhizo/tools/aapt2 usr/lib/rhizo/RhizoDesktop.apk; do
    grep -q " \./$want\$" "$listing" || { fail "the package does not carry $want"; return 1; }
  done
  for p in "${NEVER_SHIPPED[@]}"; do
    ! grep -q "$p" "$listing" || { fail "the package carries $p, which is rig-only"; return 1; }
  done
  assert_attributed "$listing" "$CLONE/debian/copyright" || return 1
  DEB="$deb"
  log "package: $(basename "$deb") sha256 $(sha256sum "$deb" | cut -d' ' -f1), $(wc -l < "$listing") entries, none of ${NEVER_SHIPPED[*]}"
}

# log the signer certificate of the built apk
print_signers() {
  local apksigner="$CACHE/android-sdk/build-tools/34.0.0/apksigner" apk="$CLONE/var/share/RhizoAudioRouter.apk"
  log "signer of $(basename "$apk"): $("$apksigner" verify --print-certs "$apk" 2>/dev/null | grep -m1 'SHA-256' | sed 's/.*: //') (the build host's debug keystore)"
}

# log how each build input was satisfied
report() {
  local fetched cached reused provided
  fetched=$(grep -c $'\tfetched\t' "$CLONE/.rhizo-inputs.tsv"); cached=$(grep -c $'\tcached\t' "$CLONE/.rhizo-inputs.tsv")
  reused=$(grep -c $'\treused\t' "$CLONE/.rhizo-inputs.tsv"); provided=$(grep -c $'\tprovided\t' "$CLONE/.rhizo-inputs.tsv")
  log "inputs of this run (mode is how each was satisfied):"
  column -t -s $'\t' "$CLONE/.rhizo-inputs.tsv" | sed 's/^/    /' >&2
  log "inputs: fetched=$fetched cached=$cached reused=$reused provided=$provided"
  log "the AOSP checkout was supplied at ${RHIZO_AOSP_DIR:-$CACHE/aosp/android16-qpr2} and its manifest asserted"
  log "CLEAN_CLONE_BUILD PASSED clone=$CLONE deb=$DEB elapsed=$((SECONDS - T0))s (aosp supplied, not synced)"
}

# run the whole clean-clone build
run() {
  preflight || return 1
  log "df at start: $(df -h "$(dirname "$SCRATCH")" | tail -1)"
  clone_branch || return 1
  assert_isolated "$CLONE" || return 1
  ( cd "$CLONE" && tools/fetch/build-inputs.sh --accept-android-sdk-license ) || { fail "build-inputs.sh failed in the clone"; return 1; }
  audit_symlinks "$CLONE" || return 1
  ( cd "$CLONE" && tools/build/payload.sh ) || { fail "payload.sh failed in the clone"; return 1; }
  "$CLONE/test/checks/build/build-set.sh" --share "$CLONE/var/share" || { fail "build-set.sh failed on the clone's share"; return 1; }
  package_and_check || return 1
  log "comparing gpu_driver against $REF_SHARE/gpu_driver"
  compare_driver "$CLONE/var/share/gpu_driver" "$REF_SHARE/gpu_driver" || { fail "gpu_driver differs from the reference"; return 1; }
  log "comparing gpu_driver_32 against $REF_SHARE/gpu_driver_32"
  compare_driver "$CLONE/var/share/gpu_driver_32" "$REF_SHARE/gpu_driver_32" || { fail "gpu_driver_32 differs from the reference"; return 1; }
  print_signers
  log "df at end: $(df -h "$(dirname "$SCRATCH")" | tail -1)"
  report
}

# remove the clone unless it is kept
cleanup() {
  [[ -n "$CLONE" && -d "$CLONE" ]] || return 0
  if (( KEEP )); then log "kept $CLONE"; else rm -rf "$CLONE"; fi
}

# run the checker functions on fixtures
selftest() {
  local fail=0 tmp out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/c1/var/share/gpu_driver" "$tmp/c1/tools/mesa"; printf '@DIRNAME@\n' > "$tmp/c1/tools/mesa/mesa-cross-x86_64-android"; cp "$tmp/c1/tools/mesa/mesa-cross-x86_64-android" "$tmp/c1/tools/mesa/mesa-cross-x86-android"
  out=$(assert_isolated "$tmp/c1" 2>&1)
  [[ $? -ne 0 && "$out" == *"not clean: var/share exists"* ]] || { echo "SELFTEST FAILED: a seeded var/share was not refused -- got: $out"; fail=1; }
  rm -rf "$tmp/c1/var"; ln -s /tmp "$tmp/c1/mesa-src"
  out=$(assert_isolated "$tmp/c1" 2>&1)
  [[ $? -ne 0 && "$out" == *"not clean: mesa-src exists"* ]] || { echo "SELFTEST FAILED: a mesa-src symlink was not refused -- got: $out"; fail=1; }
  rm "$tmp/c1/mesa-src"; printf '/home/someone/ndk\n' > "$tmp/c1/tools/mesa/mesa-cross-x86-android"
  out=$(assert_isolated "$tmp/c1" 2>&1)
  [[ $? -ne 0 && "$out" == *"does not locate the NDK relative to itself"* ]] || { echo "SELFTEST FAILED: a cross file naming a home dir was not refused -- got: $out"; fail=1; }
  mkdir -p "$tmp/cache" "$tmp/c2/inner" "$tmp/elsewhere"; ln -s "$tmp/cache" "$tmp/c2/ok"; ln -s "$tmp/elsewhere" "$tmp/c2/bad"
  ln -s ../inner "$tmp/c2/inner/self"; : > "$tmp/c2/inner/file"; ln -s file "$tmp/c2/inner/relative"
  out=$(CACHE="$tmp/cache" RHIZO_AOSP_DIR='' audit_symlinks "$tmp/c2" 2>&1)
  [[ $? -ne 0 && "$out" == *"symlink bad ->"* && "$out" != *"symlink ok ->"* && "$out" != *"inner/"* ]] \
    || { echo "SELFTEST FAILED: the symlink audit did not refuse exactly the outside link -- got: $out"; fail=1; }
  mkdir -p "$tmp/ra/egl" "$tmp/ra/lib"
  if cc -shared -fPIC -Wl,-soname,libEGL_rhizo.so -o "$tmp/ra/egl/libEGL_rhizo.so" -x c - <<<'const char v[] = "Mesa 25.2.8 (fixture)";' 2>/dev/null \
     && cc -shared -fPIC -Wl,-soname,libgallium_dri.so -o "$tmp/ra/lib/libgallium_dri.so" -x c - <<<'const char v[] = "Mesa 25.2.8 (fixture)";' 2>/dev/null; then
    cp -r "$tmp/ra" "$tmp/rb"
    compare_driver "$tmp/ra" "$tmp/rb" >/dev/null 2>&1 || { echo "SELFTEST FAILED: identical fixture trees did not compare equal"; fail=1; }
    : > "$tmp/rb/lib/extra.so"
    out=$(compare_driver "$tmp/ra" "$tmp/rb" 2>&1)
    [[ $? -ne 0 && "$out" == *"file sets differ"* && "$out" == *"extra.so"* ]] || { echo "SELFTEST FAILED: an extra file was not refused by name -- got: $out"; fail=1; }
    rm "$tmp/rb/lib/extra.so"; patchelf --set-soname wrong.so "$tmp/rb/egl/libEGL_rhizo.so"
    out=$(compare_driver "$tmp/ra" "$tmp/rb" 2>&1)
    [[ $? -ne 0 && "$out" == *"SONAME differs"* ]] || { echo "SELFTEST FAILED: a SONAME mismatch was not refused -- got: $out"; fail=1; }
    patchelf --set-soname libEGL_rhizo.so "$tmp/rb/egl/libEGL_rhizo.so"
    cc -shared -fPIC -Wl,-soname,libgallium_dri.so -o "$tmp/rb/lib/libgallium_dri.so" -x c - <<<'const char v[] = "Mesa 24.1.0 (fixture)";' 2>/dev/null
    out=$(compare_driver "$tmp/ra" "$tmp/rb" 2>&1)
    [[ $? -ne 0 && "$out" == *"Mesa version differs"* ]] || { echo "SELFTEST FAILED: another Mesa version was not refused -- got: $out"; fail=1; }
  else
    echo "SELFTEST SKIPPED: no host cc to build the fixture trees"
  fi
  printf 'Files: usr/lib/rhizo/gpu_driver/lib/libz.so\n usr/lib/rhizo/tools/aapt2\nLicense: X\n' > "$tmp/copyright"
  printf -- '-rw-r--r-- root/root 1 2026-01-01 00:00 ./usr/lib/rhizo/gpu_driver/lib/libz.so\n-rw-r--r-- root/root 1 2026-01-01 00:00 ./usr/lib/rhizo/gpu_driver/lib/libbase.so\n-rw-r--r-- root/root 1 2026-01-01 00:00 ./usr/lib/rhizo/gpu_driver_software/lib/libgallium_dri.so\n-rw-r--r-- root/root 1 2026-01-01 00:00 ./usr/lib/rhizo/gfx_hal/rhizo-composer\n' > "$tmp/listing"
  out=$(assert_attributed "$tmp/listing" "$tmp/copyright" 2>&1)
  [[ $? -ne 0 && "$out" == *"gpu_driver/lib/libbase.so ships with no Files: stanza"* && "$out" == *"gpu_driver_software/lib/libgallium_dri.so ships with no Files: stanza"* && "$out" != *"rhizo-composer"* ]] \
    || { echo "SELFTEST FAILED: the attribution check did not refuse exactly the unnamed third-party file -- got: $out"; fail=1; }
  out=$(scratch_allowed "$SRC_ROOT/scratch-fixture" 2>&1)
  [[ $? -ne 0 && "$out" == *"inside the source tree"* ]] || { echo "SELFTEST FAILED: a scratch dir under the source tree was not refused -- got: $out"; fail=1; }
  scratch_allowed /var/tmp/rhizo-clean-clone.fixture >/dev/null 2>&1 || { echo "SELFTEST FAILED: a scratch dir under /var/tmp was refused"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "clean-clone-build.sh selftest: FAILED"; return 1; fi
  echo "clean-clone-build.sh selftest: ok"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scratch) SCRATCH="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --reference-share) REF_SHARE="$2"; shift 2 ;;
    --selftest) selftest; exit $? ;;
    *) echo "usage: $0 [--scratch DIR] [--keep] [--reference-share DIR] [--selftest]" >&2; exit 2 ;;
  esac
done
trap cleanup EXIT
DEB=""
if run; then exit 0; fi
log "CLEAN_CLONE_BUILD FAILED after $((SECONDS - T0))s; the clone is kept at ${CLONE:-<none>} for inspection"
KEEP=1
exit 1
