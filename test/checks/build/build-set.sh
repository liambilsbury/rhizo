#!/bin/bash
# check the common build set artifacts
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit
source ../vm/common.sh

SHARE="$SHARE_DIR"
[[ "${1:-}" == "--share" ]] && { SHARE="$2"; shift 2; }

HAL64=(rhizo-audio-core-service rhizo-audio-effect-service rhizo-bootcontrol-service
       rhizo-composer rhizo-gatekeeper-service rhizo-graphics-allocator
       rhizo-health-service rhizo-power-service rhizo-thermal-service rhizo-bluetooth-service rhizo-gnss-service
       mapper.rhizo.so libcutils_real.so libc++_shared.so)
TOP64=(rhizo-keymint-service rhizo-probed)
HAL32=(mapper.rhizo.so)

fail=0
note() { printf '  %s\n' "$*" >&2; }

# check the ELF header of a file
check_elf() {
  local f="$1" want="$2" label="$3" hdr
  if [[ ! -e "$f" ]]; then
    note "MISSING  $label: $f"; fail=1; return
  fi
  if [[ ! -s "$f" ]]; then
    note "EMPTY    $label: $f (a killed build leaves a zero-length file that every presence check passes)"
    fail=1; return
  fi
  hdr=$(file -b "$f" 2>/dev/null)
  case "$hdr" in
    ELF*) ;;
    *) note "NOT ELF  $label: $f is '$hdr'"; fail=1; return ;;
  esac
  case "$want:$hdr" in
    64:*x86-64*|32:*Intel\ 80386*|32:*Intel\ i386*) ;;
    *) note "WRONG ARCH $label: $f wanted ${want}-bit x86, got '$hdr'"; fail=1; return ;;
  esac
}

for b in "${HAL64[@]}"; do check_elf "$SHARE/gfx_hal/$b" 64 "gfx_hal"; done
for b in "${TOP64[@]}"; do check_elf "$SHARE/$b" 64 "share"; done
for b in "${HAL32[@]}"; do check_elf "$SHARE/gfx_hal_32/$b" 32 "gfx_hal_32"; done
check_elf "$SHARE/rel/a15/rhizo-power-service" 64 "rel/a15"

if (( fail )); then
  echo "check-build-set: the common build set is not ready -- rebuild with tools/build/hal/hal.sh" >&2
  exit 1
fi
echo "check-build-set: ${#HAL64[@]} 64-bit HAL artifacts, ${#TOP64[@]} top-level, ${#HAL32[@]} 32-bit, a15's power HAL -- all present and well-formed"
