#!/bin/bash
# generate the AIDL NDK glue for the HALs
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
source ../../../test/vm/common.sh
source ./own-output-lib.sh
REPO_ROOT="$(cd "$(dirname "$SELF")/../../.." && pwd)"
AOSP="$REPO_ROOT/aosp-android16-qpr2"
TC="$REPO_ROOT/toolchain"
AIDL="${RHIZO_AIDL:-$AOSP/out/host/linux-x86/bin/aidl}"
AIDL_SDK=36

declare -A PKG VER DIR MIN HASH IMPORTS OUT EXTRA
# record an AIDL package row
row() { PKG[$1]=$2; VER[$1]=$3; DIR[$1]=$4; MIN[$1]=$5; HASH[$1]=$6; IMPORTS[$1]="${7:-}"; }
row hw_common          android.hardware.common               2 hardware/interfaces/common/aidl              31 c32ddfdeb69c6e4a8a45519e6f9a39c4b66fd99f
row fmq                android.hardware.common.fmq           1 hardware/interfaces/common/fmq/aidl          29 12cf0ce8614557cc0efe73bdf011f5193f7a8653 "hw_common"
row gfx_common         android.hardware.graphics.common      6 hardware/interfaces/graphics/common/aidl     29 77f2fb445fe7fefedad217ef45a1151c8e7fdaa8 "hw_common"
row allocator          android.hardware.graphics.allocator   2 hardware/interfaces/graphics/allocator/aidl  29 9499fec09c544e9de5be3c87125721600f8ade66 "gfx_common hw_common"
row drm_common         android.hardware.drm.common           1 hardware/interfaces/drm/common/aidl          29 1b5e9159609b3aa05e2c7158f3a1488fda2250d1
row composer3          android.hardware.graphics.composer3   4 hardware/interfaces/graphics/composer/aidl   29 aba56b3f763c2762a7929fe39b8c6b386b0ccb94 "gfx_common hw_common allocator drm_common"
row power              android.hardware.power                6 hardware/interfaces/power/aidl               29 13171cf98a48de298baf85167633376ea3db4ea0 "hw_common fmq"
row power_a15          android.hardware.power                5 hardware/interfaces/power/aidl               29 d111735ed2b89b6c32443aac9b162b1afbbea3f2 "hw_common fmq"
row thermal            android.hardware.thermal              3 hardware/interfaces/thermal/aidl             29 4c4fc474c40b64963eb8d78b713b1095fecd72f0
row bluetooth          android.hardware.bluetooth            1 hardware/interfaces/bluetooth/aidl           33 f0eb2eb6d3b970cef8fb1b6e22c4ec39a4da5119
row gnss               android.hardware.gnss                 6 hardware/interfaces/gnss/aidl                29 da99c936e327ce4b93e04fdfa4c7770913667f21
row health             android.hardware.health               4 hardware/interfaces/health/aidl              29 c8d014c7bb950af538396f3e5a409c69b7b9335c
row bootcontrol        android.hardware.boot                 1 hardware/interfaces/boot/aidl                29 2400346954240a5de495a1debc81429dd012d7b7
row keymint            android.hardware.security.keymint     4 hardware/interfaces/security/keymint/aidl    29 a05c8079586139db45b0762a528cdd9745ad15ce "secureclock"
row secureclock        android.hardware.security.secureclock 1 hardware/interfaces/security/secureclock/aidl 29 cd55ca9963c6a57fa5f2f120a45c6e0c4fafb423
row gatekeeper         android.hardware.gatekeeper           1 hardware/interfaces/gatekeeper/aidl          29 d877e8a1608a00fd9068bcd7e69ea480a7ea17f0 "keymint secureclock hw_common"
row sharedsecret       android.hardware.security.sharedsecret 1 hardware/interfaces/security/sharedsecret/aidl 29 aea3745b559d2977f0676952e510fb0547a52140
row audio_common_types android.media.audio.common.types      2 system/hardware/interfaces/media             29 79bbabfe33e09450c7fc6120bd45f5339f3c7584
row audio_eraser       android.media.audio.eraser.types      1 system/hardware/interfaces/media             31 d0f24b98624bc07be92c5dc38302f967c522ff14 "audio_common_types hw_common fmq"
row audio_common_hal   android.hardware.audio.common         2 hardware/interfaces/audio/aidl               31 6780ccb29120b4c7d3ed60f55a23c13b0431f3a4 "audio_common_types hw_common fmq"
row audio_core         android.hardware.audio.core           1 hardware/interfaces/audio/aidl               31 1cec1e67515bdd2b896d80d20a64bf899b2470bf "audio_common_hal audio_common_types audio_eraser audio_effect hw_common fmq"
row audio_effect       android.hardware.audio.effect         1 hardware/interfaces/audio/aidl               31 34b618a587cb9977ee0cd13b173e699d2dcdb320 "audio_common_hal audio_common_types audio_eraser audio_core hw_common fmq"
OUT[keymint]=gen
OUT[secureclock]=gen
OUT[power_a15]=gen_a15/power
EXTRA[keymint]="hardware/interfaces/security/secureclock/aidl android.hardware.security.secureclock 1"
EXTRA[audio_core]="hardware/interfaces/audio/aidl android.hardware.audio.core.sounddose 1"
GENS=(hw_common fmq gfx_common allocator drm_common composer3 power power_a15 thermal bluetooth gnss health bootcontrol
      keymint gatekeeper sharedsecret audio_common_types audio_eraser audio_common_hal audio_core audio_effect)

# print the folder of a package's frozen API dump
dump_dir() { echo "$AOSP/${DIR[$1]}/aidl_api/${PKG[$1]}/${VER[$1]}"; }
# print the output folder of a package's generated glue
out_dir() { echo "$TC/${OUT[$1]:-gen/$1}"; }

# check the frozen dump's hash against the pin
assert_hash() {
  local d line have=""
  d=$(dump_dir "$1")
  [[ -d "$d/android" ]] || { log "$1: no frozen dump at $d"; return 1; }
  while IFS= read -r line; do
    have="$have $line"
    [[ "$line" == "${HASH[$1]}" ]] && return 0
  done < "$d/.hash"
  log "$1: ${PKG[$1]} V${VER[$1]}'s frozen hash is '${have# }', pinned ${HASH[$1]}"
  return 1
}

# build the aidl compiler if missing and check its SDK version
ensure_aidl() {
  if [[ ! -x "$AIDL" ]]; then
    log "no aidl at $AIDL, building it (m aidl in $AOSP)"
    ( set +u; cd "$AOSP" && source build/envsetup.sh && lunch aosp_x86_64 bp2a userdebug && m aidl ) \
      || { log "m aidl failed in $AOSP"; return 1; }
  fi
  local banner
  banner=$("$AIDL" --version 2>&1)
  [[ "$banner" == *"platform SDK version $AIDL_SDK"* ]] || { log "$AIDL is not the SDK $AIDL_SDK compiler: $banner"; return 1; }
}

# generate the AIDL glue for a package
generate() {
  local g="$1" d out inc srcs=() i extra
  assert_hash "$g" || return 1
  d=$(dump_dir "$g"); out=$(out_dir "$g")
  inc=(-I "$d")
  for i in ${IMPORTS[$g]}; do assert_hash "$i" || return 1; inc+=(-I "$(dump_dir "$i")"); done
  while IFS= read -r i; do srcs+=("$i"); done < <(find "$d/android" -name '*.aidl' | sort)
  if [[ -n "${EXTRA[$g]:-}" ]]; then
    set -- ${EXTRA[$g]}
    extra="$AOSP/$1/aidl_api/$2/$3"
    [[ -d "$extra/android" ]] || { log "$g: no dump for $2 V$3 at $extra"; return 1; }
    inc+=(-I "$extra")
    while IFS= read -r i; do srcs+=("$i"); done < <(find "$extra/android" -name '*.aidl' | sort)
  fi
  rm -rf "$out/ndk" "$out/header"
  mkdir -p "$out/ndk" "$out/header"
  "$AIDL" --lang=ndk --structured --stability=vintf --version="${VER[$g]}" --min_sdk_version="${MIN[$g]}" \
    --hash="${HASH[$g]}" "${inc[@]}" -o "$out/ndk" -h "$out/header" "${srcs[@]}" \
    || { log "$g: aidl failed"; return 1; }
  log "$g: ${PKG[$g]} V${VER[$g]} ${#srcs[@]} files -> ${out#$REPO_ROOT/}"
}

# copy the platform headers from the checkout
copy_headers() {
  local n="$AOSP/frameworks/native/libs/binder/ndk" p="$TC/include_platform.part" d
  rm -rf "$p"; mkdir -p "$p/android" "$p/private"
  for d in "$n/include_platform/android" "$n/include_ndk/android" "$n/include_cpp/android" "$AOSP/system/logging/liblog/include/android"; do
    cp -rL "$d/." "$p/android/" || return 1
  done
  cp -rL "$AOSP/system/logging/liblog/include/log" "$p/log" || return 1
  cp -rL "$AOSP/system/core/libcutils/include/cutils" "$p/cutils" || return 1
  cp -rL "$AOSP/system/core/libcutils/include/private/." "$p/private/" || return 1
  cp -rL "$AOSP/system/logging/liblog/include/private/." "$p/private/" || return 1
  cp -rL "$AOSP/system/core/libutils/include/utils" "$p/utils" || return 1
  cp -rL "$AOSP/system/libbase/include/android-base" "$p/android-base" || return 1
  rm -rf "$TC/include_platform" && mv "$p" "$TC/include_platform"
  rm -rf "$TC/boringssl_include.part"; mkdir -p "$TC/boringssl_include.part"
  cp -rL "$AOSP/external/boringssl/src/include/openssl" "$TC/boringssl_include.part/" || return 1
  rm -rf "$TC/boringssl_include" && mv "$TC/boringssl_include.part" "$TC/boringssl_include"
  local m="$TC/gfx_aidl_src/mapper/stable-c" s="$AOSP/hardware/interfaces/graphics/mapper/stable-c"
  rm -rf "$m.part"; mkdir -p "$m.part/implutils"
  cp -rL "$s/include" "$m.part/include" && cp -r "$s/implutils/include" "$m.part/implutils/include" || return 1
  rm -rf "$m" && mkdir -p "$(dirname "$m")" && mv "$m.part" "$m"
  log "headers: include_platform, boringssl_include, mapper stable-c copied from the checkout"
}

# check the glue rows against the build scripts
selftest() {
  local fail=0 g refs r tmp out
  refs=$(grep -rhoE --include='*.sh' 'toolchain/gen[a-z0-9_]*/[a-z0-9_]+/(ndk|header)' "$REPO/tools/build" | sed -E 's#/(ndk|header)$##' | sort -u)
  while IFS= read -r r; do
    case "$r" in toolchain/gen) continue ;; esac
    local found=0
    for g in "${GENS[@]}"; do [[ "toolchain/${OUT[$g]:-gen/$g}" == "$r" ]] && found=1; done
    (( found )) || { echo "SELFTEST FAILED: build scripts read $r but no row generates it"; fail=1; }
  done <<<"$refs"
  for g in "${GENS[@]}"; do
    [[ "$g" == secureclock ]] && continue
    r="toolchain/${OUT[$g]:-gen/$g}"
    grep -rq --include='*.sh' "$r/" "$REPO/tools/build" || { echo "SELFTEST FAILED: row $g generates $r, which no build script reads"; fail=1; }
  done
  tmp=$(mktemp -d)
  mkdir -p "$tmp/hardware/interfaces/thermal/aidl/aidl_api/android.hardware.thermal/3/android"
  printf 'deadbeef\n' > "$tmp/hardware/interfaces/thermal/aidl/aidl_api/android.hardware.thermal/3/.hash"
  out=$(AOSP="$tmp" assert_hash thermal 2>&1)
  [[ $? -ne 0 && "$out" == *"android.hardware.thermal V3's frozen hash is 'deadbeef'"* ]] \
    || { echo "SELFTEST FAILED: a drifted hash was not refused by name -- got: $out"; fail=1; }
  out=$(AOSP="$tmp" assert_hash health 2>&1)
  [[ $? -ne 0 && "$out" == *"no frozen dump"* ]] || { echo "SELFTEST FAILED: a missing dump was not refused -- got: $out"; fail=1; }
  mkdir -p "$tmp/main/toolchain/gen" "$tmp/wt"
  ln -s "$tmp/main/toolchain" "$tmp/wt/toolchain"
  out=$(REPO_ROOT="$tmp/wt" own_output "$tmp/wt/toolchain" "$tmp/wt/toolchain/gen" 2>&1)
  [[ $? -ne 0 && "$out" == *"toolchain resolves to $tmp/main/toolchain"*"rm toolchain && cp -a --reflink=auto $tmp/main/toolchain toolchain" ]] || { echo "SELFTEST FAILED: a toolchain linked to another checkout was not refused by name -- got: $out"; fail=1; }
  REPO_ROOT="$tmp/main" own_output "$tmp/main/toolchain" "$tmp/main/toolchain/gen" >/dev/null 2>&1 || { echo "SELFTEST FAILED: a checkout's own toolchain was refused"; fail=1; }
  rm -rf "$tmp"
  if [[ -d "$AOSP/hardware/interfaces" ]]; then
    for g in "${GENS[@]}"; do assert_hash "$g" >/dev/null 2>&1 || { echo "SELFTEST FAILED: the checkout's dump for $g does not carry the pinned hash"; fail=1; }; done
  fi
  if (( fail )); then echo "regen-aidl-glue.sh selftest: FAILED"; return 1; fi
  echo "regen-aidl-glue.sh selftest: ok"
}

ONLY=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY+=("$2"); shift 2 ;;
    --selftest) selftest; exit $? ;;
    *) echo "usage: $0 [--only GEN]... [--selftest]" >&2; exit 2 ;;
  esac
done
[[ ${#ONLY[@]} -gt 0 ]] || ONLY=("${GENS[@]}")
own_output "$TC" "$TC/gen" "$TC/gen_a15" "$TC/gfx_aidl_src" "$TC/out" || exit 1
[[ -d "$AOSP/hardware/interfaces" ]] || { log "no AOSP checkout at $AOSP -- run tools/fetch/build-inputs.sh --only aosp"; exit 1; }
ensure_aidl || exit 1
for g in "${ONLY[@]}"; do
  [[ -n "${PKG[$g]:-}" ]] || { log "unknown glue dir '$g' (want: ${GENS[*]})"; exit 2; }
  generate "$g" || exit 1
done
[[ ${#ONLY[@]} -eq ${#GENS[@]} ]] && { copy_headers || exit 1; }
rm -rf "$TC/out/gen_aidl_src" "$TC/out/x86/gen_aidl_src"
log "removed toolchain/out/gen_aidl_src; rebuild every HAL"
