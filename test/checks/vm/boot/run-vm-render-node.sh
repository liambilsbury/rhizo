#!/bin/bash
# check that run-vm.sh passes qemu the chosen render node
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ "${1:-}" == --selftest ]] || { echo "usage: $0 --selftest" >&2; exit 2; }
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
FAILED=0
# compare the two values and record a mismatch
check() { [[ "$2" == "$3" ]] || { echo "got '$2' want '$3' for: $1"; FAILED=1; }; }
mkdir -p "$T/tree/test/vm/guest-os" "$T/tree/test/vm/rig" "$T/tree/src/install/prepare" "$T/tree/var/share" "$T/dev/by-path" "$T/empty"
cp "$HERE/../vm/run-vm.sh" "$T/tree/test/vm/"
cp "$HERE/../vm/guest-os/guest-os-lib.sh" "$T/tree/test/vm/guest-os/"
cp "$HERE/../vm/rig/hooks.sh" "$T/tree/test/vm/rig/"
cp "$HERE/../../src/install/prepare/detect-gpu-driver.sh" "$T/tree/src/install/prepare/"
for row in "renderD128 2147483648 card0" "renderD129 17095983104 card1"; do
  read -r name vram card <<<"$row"
  mkdir -p "$T/sys/$name/device/drm/$card"
  echo DRIVER=amdgpu > "$T/sys/$name/device/uevent"
  echo "$vram" > "$T/sys/$name/device/mem_info_vram_total"
done
ln -s ../renderD128 "$T/dev/by-path/pci-0000:12:00.0-render"
# print run-vm.sh's qemu argv against a fixture sysfs
argv() {
  local sys="$1"; shift
  env -i PATH="$PATH" HOME="$HOME" RHIZO_PRINT_ARGV=1 RHIZO_VM=0 RHIZO_GUEST_OS=ubuntu RHIZO_BOOT=direct \
    RHIZO_SYS_CLASS_DRM="$sys" RHIZO_DEV_DRI="$T/dev" "$@" bash "$T/tree/test/vm/run-vm.sh" 2>&1
  echo "rc=$?"
}
check "qemu renders on the larger-VRAM node" \
  "$(argv "$T/sys" | grep -cx -e "egl-headless,rendernode=$T/dev/renderD129" -e rc=0)" 2
check "an override by by-path wins" \
  "$(argv "$T/sys" RHIZO_RENDER_NODE="$T/dev/by-path/pci-0000:12:00.0-render" \
     | grep -cx -e "egl-headless,rendernode=$T/dev/renderD128" -e rc=0)" 2
out=$(argv "$T/empty")
check "a host with no render node refuses the boot by name" \
  "$(grep -c "run-vm.sh: no host render node for the vm's virgl" <<<"$out"):$(tail -1 <<<"$out")" "1:rc=1"
out=$(argv "$T/empty" RHIZO_VM_GPU=off)
check "RHIZO_VM_GPU=off boots without a host render node" "$(tail -1 <<<"$out")" "rc=0"
check "RHIZO_VM_GPU=off passes -display none" "$(grep -A1 -x -- '-display' <<<"$out" | tail -1)" "none"
check "RHIZO_VM_GPU=off adds no virtio-gpu device and opens no render node" \
  "$(grep -c -e virtio-gpu -e egl-headless <<<"$out")" 0
out=$(argv "$T/sys" RHIZO_VM_GPU=maybe)
check "RHIZO_VM_GPU=maybe is refused by name" \
  "$(grep -c "RHIZO_VM_GPU is 'maybe'" <<<"$out"):$(tail -1 <<<"$out")" "1:rc=1"
check "RHIZO_VM_GPU is a host knob on redeploy's deny list" \
  "$(sed -n '/^LAUNCH_ENV_DENY=/,/"$/p' "$HERE/../vm/redeploy.sh" | grep -cw RHIZO_VM_GPU)" 1
# run the dri policy script and print its result
dri() { printf '%s\n' "$1" > "$T/pol"; python3 "$HERE/../vm/image/guest-policy-dri.py" "$2" "$T/pol" >/dev/null 2>&1; echo "rc=$? $(tr '\n' ' ' < "$T/pol")"; }
check "guest policy: off writes dri = off into an empty file" "$(dri '' off)" "rc=0 [devices] dri = off  "
check "guest policy: on turns dri = off into on" "$(dri $'[devices]\ndri = off' on)" "rc=0 [devices] dri = on  "
for spelling in no false 0 NO Off; do
  check "guest policy: on turns dri = $spelling, a false spelling the parser accepts, into on" \
    "$(dri $'[devices]\ndri = '"$spelling" on)" "rc=0 [devices] dri = on  "
done
check "guest policy: off leaves dri = no, already off, as it is" "$(dri $'[devices]\ndri = no' off)" "rc=0 [devices] dri = no "
check "guest policy: on leaves dri = yes as it is" "$(dri $'[devices]\ndri = yes' on)" "rc=0 [devices] dri = yes "
check "guest policy: on leaves an absent key absent" "$(dri $'[devices]\nuinput = no' on)" "rc=0 [devices] uinput = no "
check "guest policy: on leaves an absent file section alone" "$(dri '' on)" "rc=0  "
python3 "$HERE/../vm/image/guest-policy-dri.py" on "$T/missing" >/dev/null 2>&1
check "guest policy: on with no policy file creates none" "$(test -e "$T/missing" && echo 0 || echo 1)" 1
check "guest policy: an unparseable file fails" "$(dri 'garbage' off | cut -d' ' -f1)" "rc=1"
# print prepare-tree's argv for a RHIZO_VM_GPU mode
tree_argv() {
  local line
  line=$(grep -m1 'prepare-tree /var/lib/rhizo/prepared' "$HERE/../vm/redeploy.sh")
  # shellcheck disable=SC2034
  ( gpu_mode="$1"
    ssh_vm() { shift 2; bash -c 'bash() { echo amd; }; python3() { echo "$*"; }; '"$1"; }
    eval "$line"
    printf '%s\n' "$out" )
}
check "redeploy's tree rebuild stages the guest's amd set with RHIZO_VM_GPU=on" \
  "$(tree_argv on)" "/root/launcher3.py prepare-tree /var/lib/rhizo/prepared --gpu-driver gpu_driver_amd"
check "redeploy's tree rebuild passes no gpu driver with RHIZO_VM_GPU=off" \
  "$(tree_argv off)" "/root/launcher3.py prepare-tree /var/lib/rhizo/prepared"
(( FAILED )) && { echo "run-vm-render-node: FAILED"; exit 1; }
echo "run-vm-render-node: qemu renders on the resolver's node, an override by by-path wins, no node refuses, RHIZO_VM_GPU=off boots with no gpu device, and redeploy's tree rebuild passes --gpu-driver with RHIZO_VM_GPU=on and none with it off"
