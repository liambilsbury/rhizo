#!/bin/bash
# test the KeyMint service boot calls
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$(cd ../.. && pwd)"
VAR_DIR="$REPO/var"
IMG="${RHIZO_KEYMINT_CHECK_GSI:-$VAR_DIR/gsi/system.img}"
NDK_BIN="$REPO/toolchain/ndk_extract/android-ndk-r27c/toolchains/llvm/prebuilt/linux-x86_64/bin"
CXX="$NDK_BIN/x86_64-linux-android35-clang++"
CALLS=(IKeyMintDevice.getInterfaceVersion IKeyMintDevice.getHardwareInfo
       ISharedSecret.getSharedSecretParameters ISharedSecret.computeSharedSecret
       IKeyMintDevice.earlyBootEnded "IKeyMintDevice.generateKey(AES)"
       "IKeyMintDevice.generateKey(HMAC)")

T=""
trap '[[ -n "$T" ]] && rm -rf "$T"' EXIT

# print the shared libraries an ELF file needs
needed() { readelf -dW "$1" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'; }

WHY=""
# build the fixture tree
prepare() {
  T=$(mktemp -d) || { WHY="mktemp failed"; return 1; }
  WHY=$(prepare_into)
}
# copy the GSI bionic and build libbinder_ndk
prepare_into() {
  mkdir -p "$T/lib"
  [[ -s "$IMG" ]] || { echo "no a16 GSI image at $IMG"; return 1; }
  [[ -x "$CXX" ]] || { echo "no NDK clang at $CXX"; return 1; }
  local t f
  for t in debugfs unzip readelf timeout; do
    command -v "$t" >/dev/null || { echo "$t is not installed"; return 1; }
  done
  debugfs -R "dump /system/apex/com.android.runtime.apex $T/runtime.apex" "$IMG" >/dev/null 2>&1
  unzip -q -o "$T/runtime.apex" apex_payload.img -d "$T" 2>/dev/null \
    || { echo "no runtime APEX payload in $IMG"; return 1; }
  for f in libc.so libm.so libdl.so libdl_android.so; do
    debugfs -R "dump /lib64/bionic/$f $T/lib/$f" "$T/apex_payload.img" >/dev/null 2>&1
    [[ -s "$T/lib/$f" ]] || { echo "the runtime APEX has no lib64/bionic/$f"; return 1; }
  done
  debugfs -R "dump /bin/linker64 $T/linker64" "$T/apex_payload.img" >/dev/null 2>&1
  [[ -s "$T/linker64" ]] || { echo "the runtime APEX has no bin/linker64"; return 1; }
  chmod 755 "$T/linker64"
  "$CXX" -shared -fPIC -O1 -static-libstdc++ -Wl,--version-script=data/keymint-boot-calls/libbinder_ndk.map \
    -Wl,-soname,libbinder_ndk.so -o "$T/lib/libbinder_ndk.so" data/keymint-boot-calls/fake_binder_ndk.cpp \
    2>"$T/cxx.err" || { echo "the stand-in libbinder_ndk did not build: $(head -3 "$T/cxx.err")"; return 1; }
}

# copy a binary's libraries from the GSI
stage_needs() {
  local queue=() n
  mapfile -t queue < <(needed "$1")
  while (( ${#queue[@]} )); do
    n=${queue[0]}
    queue=("${queue[@]:1}")
    [[ -e "$T/lib/$n" ]] && continue
    debugfs -R "dump /system/lib64/$n $T/lib/$n" "$IMG" >/dev/null 2>&1
    [[ -s "$T/lib/$n" ]] || { echo "the GSI's /system/lib64 has no $n, which $(basename "$1") needs"; return 1; }
    mapfile -t -O "${#queue[@]}" queue < <(needed "$T/lib/$n")
  done
}

# run a service binary and check its replies
run_service() {
  local out rc last c
  stage_needs "$1" || return 1
  cp "$1" "$T/service" && chmod 755 "$T/service"
  out=$(cd "$T" && LD_LIBRARY_PATH="$T/lib" timeout 60 "$T/linker64" "$T/service" 2>&1)
  rc=$?
  printf '%s\n' "$out" > "$T/service.log"
  last=$(grep '^FAKEBINDER call ' <<<"$out" | tail -1 | cut -d' ' -f3-)
  if (( rc == 124 )); then
    echo "hung: no exit within 60s, last call ${last:-<none>}"
    return 1
  fi
  if (( rc > 128 )); then
    echo "died on signal $((rc - 128)) during ${last:-startup, before any call}"
    return 1
  fi
  for c in "${CALLS[@]}"; do
    grep -qxF "FAKEBINDER reply $c: transact=0 exception=0 service_specific=0" <<<"$out" \
      || { echo "no OK reply to $c: $(grep -F "reply $c:" <<<"$out" || echo '<none>')"; return 1; }
  done
  grep -qx 'FAKEBINDER done' <<<"$out" && (( rc == 0 )) \
    || { echo "the call sequence did not finish (exit $rc)"; return 1; }
  echo "all ${#CALLS[@]} boot calls answered OK"
}

# build fixture services and check each verdict
selftest() {
  local why fail=0 v flags
  prepare || { echo "SELFTEST FAILED: $WHY"; return 1; }
  for v in ok trap refuse; do
    flags=()
    [[ "$v" == trap ]] && flags=(-DTRAP_IN_COMPUTE_SHARED_SECRET)
    [[ "$v" == refuse ]] && flags=(-DREFUSE_GENERATE_KEY)
    "$CXX" -O1 -static-libstdc++ "${flags[@]}" -o "$T/fixture-$v" data/keymint-boot-calls/fixture_service.cpp \
      -L"$T/lib" -lbinder_ndk 2>"$T/fx.err" \
      || { echo "SELFTEST FAILED: the $v fixture did not build: $(head -3 "$T/fx.err")"; return 1; }
  done
  local cfi=(-O1 -static-libstdc++ -flto -fvisibility=default -fsanitize=cfi-icall -fsanitize-cfi-cross-dso
             -DCFI_FREE data/keymint-boot-calls/fixture_service.cpp)
  "$CXX" -O1 -fPIC -c data/keymint-boot-calls/nocfi.cpp -o "$T/nocfi.o" 2>"$T/fx.err" \
    && "$CXX" -shared -static-libstdc++ -Wl,-soname,libnocfi.so -o "$T/lib/libnocfi.so" "$T/nocfi.o" 2>>"$T/fx.err" \
    && "$CXX" "${cfi[@]}" "$T/nocfi.o" -o "$T/fixture-cfi-static" -L"$T/lib" -lbinder_ndk 2>>"$T/fx.err" \
    && "$CXX" "${cfi[@]}" -o "$T/fixture-cfi-shared" -L"$T/lib" -lnocfi -lbinder_ndk 2>>"$T/fx.err" \
    || { echo "SELFTEST FAILED: the CFI fixtures did not build: $(head -3 "$T/fx.err")"; return 1; }
  why=$(run_service "$T/fixture-cfi-static")
  if [[ $? -eq 0 || "$why" != "died on signal 4 during ISharedSecret.computeSharedSecret" ]]; then
    echo "SELFTEST FAILED: a CFI service freeing through a pointer into a non-CFI function linked into it read '$why'"
    fail=1
  fi
  why=$(run_service "$T/fixture-cfi-shared")
  [[ $? -eq 0 ]] || { echo "SELFTEST FAILED: a CFI service freeing into a non-CFI shared library was refused: $why"; fail=1; }
  why=$(run_service "$T/fixture-ok")
  [[ $? -eq 0 ]] || { echo "SELFTEST FAILED: a service answering every call was refused: $why"; fail=1; }
  why=$(run_service "$T/fixture-trap")
  if [[ $? -eq 0 || "$why" != "died on signal 4 during ISharedSecret.computeSharedSecret" ]]; then
    echo "SELFTEST FAILED: a service trapping in computeSharedSecret read '$why'"
    fail=1
  fi
  why=$(run_service "$T/fixture-refuse")
  if [[ $? -eq 0 || "$why" != "no OK reply to IKeyMintDevice.generateKey(AES):"* ]]; then
    echo "SELFTEST FAILED: a service refusing generateKey but living on read '$why'"
    fail=1
  fi
  (( fail )) || echo "SELFTEST OK"
  return "$fail"
}

if [[ "${1:-}" == "--selftest" ]]; then
  selftest
  exit $?
fi

BIN="${1:-$VAR_DIR/share/rhizo-keymint-service}"
[[ -s "$BIN" ]] || { echo "FAIL: no KeyMint service at $BIN -- tools/build/hal/keymint.sh stages it"; exit 1; }
prepare || { echo "FAIL: $WHY"; exit 1; }
if why=$(run_service "$BIN"); then
  echo "PASS: $(basename "$BIN") $why"
  exit 0
fi
echo "FAIL: $(basename "$BIN") $why (sha256 $(sha256sum "$BIN" | cut -c1-16))"
exit 1
