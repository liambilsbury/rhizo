#!/bin/bash
# test cachyos-base.sh refusals of bad arguments
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "${1:-}" == --selftest ]] || { echo "usage: $0 --selftest" >&2; exit 2; }
FAILED=0 CASES=0
# compare two values and record a mismatch
check() {
  CASES=$((CASES + 1))
  [[ "$2" == "$3" ]] && return 0
  echo "got '$2' want '$3' for: $1"; FAILED=1
}

SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
ROOT="$SCRATCH/root"
mkdir -p "$ROOT/tools/build/vm" "$ROOT/test/vm/guest-os"
cp "$HERE/../../tools/build/vm/cachyos-base.sh" "$ROOT/tools/build/vm/"
cp "$HERE/../vm/guest-os/guest-os-lib.sh" "$ROOT/test/vm/guest-os/"
printf '%s\n' '#!/bin/bash' '# marks that the builder got past its argument checks' \
  ': > reached' 'exit 97' > "$ROOT/test/vm/guest-os/cachyos-guest-lib.sh"

# run cachyos-base.sh and check its status and output
args_case() {
  local name="$1" want="$2" why="$3" rc=0
  shift 3
  rm -f "$ROOT/reached"
  "$ROOT/tools/build/vm/cachyos-base.sh" "$@" > "$SCRATCH/out" 2>&1 || rc=$?
  check "$name: rc" "$rc" "$want"
  if [[ "$want" == 2 ]]; then
    check "$name: writes nothing" "$(LC_ALL=C ls -A "$ROOT" | tr '\n' ' ')" "test tools "
  else
    check "$name: reaches the guest lib" "$(LC_ALL=C ls -A "$ROOT" | tr '\n' ' ')" "reached test tools "
  fi
  [[ -z "$why" ]] || check "$name: says why" "$(grep -cF -- "$why" "$SCRATCH/out")" "1"
}
USAGE="usage: cachyos-base.sh"
NONE="which names no pristine cachyos base"

args_case "empty --name in a build" 2 "$USAGE" --bootloader systemd-boot --name ''
args_case "empty --bootloader in a build" 2 "$USAGE" --bootloader '' --name cachyos-sdboot
args_case "empty --name alone" 2 "$USAGE" --name ''
args_case "empty --bootloader alone" 2 "$USAGE" --bootloader ''
args_case "empty --name in a check" 2 "$USAGE" --check-only --name ''
args_case "a missing value" 2 "$USAGE" --name
args_case "an unknown option" 2 "$USAGE" --frob
args_case "a build naming the base alone" 2 "$USAGE" --name cachyos-grub
args_case "a check naming the bootloader alone" 2 "$USAGE" --check-only --bootloader grub
args_case "the stock name with another bootloader" 2 "--name cachyos-stock is the limine base, not one for --bootloader grub" \
  --bootloader grub --name cachyos-stock
args_case "a base with another base's bootloader" 2 "--name cachyos-sdboot is the systemd-boot base, not one for --bootloader grub" \
  --bootloader grub --name cachyos-sdboot
args_case "a bootloader no base has" 2 "--name cachyos-grub is the grub base, not one for --bootloader refind" \
  --bootloader refind --name cachyos-grub
args_case "a path" 2 "--name is '../x', $NONE" --check-only --name ../x
args_case "a file suffix" 2 "--name is 'cachyos-sdboot.qcow2', $NONE" --bootloader systemd-boot --name cachyos-sdboot.qcow2
args_case "the dev base" 2 "--name is 'cachyos-dev', $NONE" --check-only --name cachyos-dev
args_case "no options" 97 ""
args_case "the stock base by name" 97 "" --bootloader limine --name cachyos-stock
args_case "the sdboot base" 97 "" --bootloader systemd-boot --name cachyos-sdboot
args_case "the grub base" 97 "" --name cachyos-grub --bootloader grub
args_case "a check of the stock base" 97 "" --check-only
args_case "a check by name" 97 "" --check-only --name cachyos-grub
args_case "a check by name and bootloader" 97 "" --check-only --bootloader systemd-boot --name cachyos-sdboot

ROOT2="$SCRATCH/root2"
mkdir -p "$ROOT2/tools/build/vm" "$ROOT2/tools/fetch/images" "$ROOT2/test/vm/guest-os"
cp "$HERE/../../tools/build/vm/cachyos-base.sh" "$ROOT2/tools/build/vm/"
cp "$HERE/../vm/guest-os/guest-os-lib.sh" "$ROOT2/test/vm/guest-os/"
printf '%s\n' '#!/bin/bash' 'RIG_VCPUS=1 RIG_MEM_G=1' 'cachyos_build_lock() { :; }' 'refuse_vm_overlays() { :; }' 'stop_guest() { :; }' \
  'boot_overlay() { echo "${RIG_GUEST_CPU-unset}" > "$CPU_OUT"; exit 97; }' \
  > "$ROOT2/test/vm/guest-os/cachyos-guest-lib.sh"
printf '%s\n' '#!/bin/bash' 'echo "${RIG_GUEST_CPU-unset}" > "$CPU_OUT"' 'exit 97' > "$ROOT2/tools/fetch/images/cachyos-iso.sh"
chmod +x "$ROOT2/tools/fetch/images/cachyos-iso.sh"
mkdir -p "$ROOT2/var/cachyos-dl"
echo disk > "$ROOT2/var/cachyos-dl/cachyos-stock.qcow2"
(cd "$ROOT2/var/cachyos-dl" && sha256sum cachyos-stock.qcow2 > cachyos-stock.sha256)

# print the guest cpu cachyos-base.sh sets
cpu_case() {
  rm -f "$SCRATCH/cpu"
  env -u RIG_GUEST_CPU CPU_OUT="$SCRATCH/cpu" "$ROOT2/tools/build/vm/cachyos-base.sh" "$@" > /dev/null 2>&1
  cat "$SCRATCH/cpu" 2>/dev/null || echo not-reached
}
if /lib64/ld-linux-x86-64.so.2 --help | grep -q 'x86-64-v3 (supported'; then
  cpu=$(cpu_case)
  check "a build masks avx512 and presents a zen 2 cpu" "$cpu" "host,family=23,model=49,stepping=0,-avx512f,-avx512dq,-avx512cd,-avx512bw,-avx512vl"
fi
check "a check-only run boots with the guest cpu unset" "$(cpu_case --check-only)" "unset"

(( FAILED )) && exit 1
echo "cachyos-base.sh's arguments passed $CASES cases"
