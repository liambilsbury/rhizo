#!/bin/bash
# boot the disposable rhizo vm
# shellcheck disable=SC2054
set -euo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$SELF_DIR/../../var"
cd "$SELF_DIR/../../var"

RHIZO_VM="${RHIZO_VM:-0}"
SUFFIX=""
[[ "$RHIZO_VM" != 0 ]] && SUFFIX="-$RHIZO_VM"
PRINT_ARGV="${RHIZO_PRINT_ARGV:-0}"
[[ "$PRINT_ARGV" == 1 ]] || echo $$ > "vm-boot${SUFFIX}.pid"

RHIZO_BOOT="${RHIZO_BOOT:-direct}"
case "$RHIZO_BOOT" in
  direct|grub) ;;
  *) echo "RHIZO_BOOT must be 'direct' or 'grub' (got '$RHIZO_BOOT')" >&2; exit 2 ;;
esac

source "$SELF_DIR/guest-os/guest-os-lib.sh"
guest_os_valid "$RHIZO_GUEST_OS" || { echo "unknown RHIZO_GUEST_OS '$RHIZO_GUEST_OS' (ubuntu or cachyos)" >&2; exit 1; }
# shellcheck source=rig/hooks.sh
source "$SELF_DIR/rig/hooks.sh" || exit 2

SSH_PORT=$((2222 + RHIZO_VM + ${RHIZO_PORT_OFFSET:-0}))
ADB_PORT=$((5555 + RHIZO_VM + ${RHIZO_PORT_OFFSET:-0}))
QMP_SOCK="qmp${SUFFIX}.sock"
PIDFILE="vm${SUFFIX}.pid"

SHARE_PATH="$(rig_share_dir "$RHIZO_VM" boot)" || exit 1

[[ "$PRINT_ARGV" == 1 ]] || echo $$ > "$PIDFILE"

BASE_IMG="$(guest_base "$RHIZO_GUEST_OS" "$RHIZO_BOOT")"

DISK="$(guest_disk "$RHIZO_GUEST_OS" "$RHIZO_BOOT" "$SUFFIX")"
NEW_DISK=0
if [[ "$PRINT_ARGV" == 1 ]]; then
  :
elif [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  if [ ! -f "$BASE_IMG" ]; then
    echo "no $BASE_IMG -- run $(cachyos_builder "$RHIZO_BOOT") first" >&2
    exit 1
  fi
  if [ -f "$DISK" ]; then
    backing=$(guest_disk_backing "$DISK") || { echo "cannot read the backing file of $DISK" >&2; exit 1; }
    if [[ "$backing" != "$BASE_IMG" ]]; then
      echo "$DISK is backed by '$backing', not $BASE_IMG (RHIZO_CACHYOS_BASE=$RHIZO_CACHYOS_BASE)" >&2
      echo "  delete it and $(guest_vars "$RHIZO_GUEST_OS" "$RHIZO_BOOT" "$SUFFIX") to start this vm over from $BASE_IMG" >&2
      exit 1
    fi
  else
    qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$DISK"
    NEW_DISK=1
  fi
elif [[ "$RHIZO_BOOT" == grub ]]; then
  if [ ! -f "$BASE_IMG" ]; then
    echo "no $BASE_IMG -- run tools/fetch/images/ubuntu-base.sh first" >&2
    exit 1
  fi
  if [ ! -f "$DISK" ]; then
    qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$DISK" 20G
  fi
elif [[ "$RHIZO_VM" == 0 ]]; then
  if [ ! -f "$DISK" ]; then
    qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$DISK" 20G
    NEW_DISK=1
  fi
else
  if [ ! -f vm-golden-frozen.qcow2 ]; then
    if [ ! -f vm.qcow2 ]; then
      echo "vm.qcow2 (the golden image) does not exist -- boot instance 0 first" >&2
      exit 1
    fi
    echo "vm-golden-frozen.qcow2 missing -- creating it now" >&2
    qmp_status=$({ echo '{"execute":"qmp_capabilities"}'; echo '{"execute":"query-status"}'; sleep 0.3; } | timeout 8 socat - UNIX-CONNECT:qmp.sock 2>/dev/null) || true
    if [ -S qmp.sock ] && grep -q '"running":true' <<<"$qmp_status"; then
      echo "  instance 0 is live -- pausing for a consistent copy" >&2
      { echo '{"execute":"qmp_capabilities"}'; echo '{"execute":"stop"}'; sleep 0.3; } | timeout 8 socat - UNIX-CONNECT:qmp.sock >/dev/null 2>&1 || true
      cp vm.qcow2 vm-golden-frozen.qcow2.tmp
      { echo '{"execute":"qmp_capabilities"}'; echo '{"execute":"cont"}'; sleep 0.3; } | timeout 8 socat - UNIX-CONNECT:qmp.sock >/dev/null 2>&1 || true
    else
      echo "  instance 0 not running -- plain copy is safe" >&2
      cp vm.qcow2 vm-golden-frozen.qcow2.tmp
    fi
    mv vm-golden-frozen.qcow2.tmp vm-golden-frozen.qcow2
  fi
  disk_info=""
  [ -f "$DISK" ] && disk_info=$(qemu-img info "$DISK" 2>/dev/null)
  if [ -f "$DISK" ] && ! grep -q "^backing file:" <<<"$disk_info"; then
    echo "$DISK exists but has no valid backing-file reference -- recreating" >&2
    rm -f "$DISK"
  fi
  if [ ! -f "$DISK" ]; then
    qemu-img create -f qcow2 -b vm-golden-frozen.qcow2 -F qcow2 "$DISK"
    NEW_DISK=1
  fi
fi
KERNEL_DIR="$(vm_kernel_dir "$DISK")"
[[ "$NEW_DISK" == 1 ]] && rm -f "$KERNEL_DIR/revision"

DISK_LOCK_OPT=""
[[ "$RHIZO_VM" != 0 ]] && DISK_LOCK_OPT=",backing.file.locking=off"
DISK_ARGS=(-drive file="$DISK",if=virtio"${DISK_LOCK_OPT}")
DISK_SLOT="$(guest_disk_slot "$RHIZO_GUEST_OS" "$RHIZO_BOOT")"
if [[ -n "$DISK_SLOT" ]]; then
  DISK_ARGS=(-drive file="$DISK",if=none,id=disk0"${DISK_LOCK_OPT}" -device virtio-blk-pci,drive=disk0,addr="$DISK_SLOT")
fi
if [[ "$PRINT_ARGV" != 1 && ! -f vm_key ]]; then
  rm -f vm_key.pub
  ssh-keygen -q -t ed25519 -N '' -C 'rhizo-vm' -f vm_key
  echo "generated a new vm_key; the seed will be rebuilt from it"
fi
if [[ "$PRINT_ARGV" != 1 && ! -f vm_key.pub ]]; then
  ssh-keygen -y -f vm_key > vm_key.pub
fi
SEED_SRC="$(guest_seed_src "$RHIZO_GUEST_OS" "$RHIZO_BOOT")"
[[ -n "$SEED_SRC" ]] && SEED_SRC="$SELF_DIR/guest-os/$SEED_SRC"
if [[ "$RHIZO_BOOT" == grub ]]; then
  SEED_RENDERED=cloud-init-pristine.rendered.yaml
  SEED_ISO="seed-pristine${SUFFIX}.iso"
  SEED_META="meta-data-pristine${SUFFIX}"
  SEED_HOST=rhizo-pristine
else
  SEED_RENDERED=cloud-init.rendered.yaml
  SEED_ISO=seed.iso
  SEED_META=meta-data
  SEED_HOST=rhizo-vm
fi
if [[ "$PRINT_ARGV" != 1 && -n "$SEED_SRC" ]]; then
  exec 210>"$SEED_ISO.lock"
  flock 210
  seed_id="rhizo-$(sha256sum vm_key.pub | cut -c1-12)"
  printf 'instance-id: %s\nlocal-hostname: %s\n' "$seed_id" "$SEED_HOST" > "$SEED_META.new"
  if [ ! -f "$SEED_ISO" ] || [ vm_key.pub -nt "$SEED_ISO" ] || [ "$SEED_SRC" -nt "$SEED_ISO" ] \
     || ! cmp -s "$SEED_META.new" "$SEED_META"; then
    mv -f "$SEED_META.new" "$SEED_META"
    pubkey=$(cat vm_key.pub) || { echo "cannot read vm_key.pub" >&2; exit 1; }
    sed "s|@VM_PUBKEY@|$pubkey|" "$SEED_SRC" > "$SEED_RENDERED.new"
    mv -f "$SEED_RENDERED.new" "$SEED_RENDERED"
    grep -q '@VM_PUBKEY@' "$SEED_RENDERED" && { echo "pubkey substitution failed" >&2; exit 1; }
    cloud-localds "$SEED_ISO.new" "$SEED_RENDERED" "$SEED_META"
    mv -f "$SEED_ISO.new" "$SEED_ISO"
  else
    rm -f "$SEED_META.new"
  fi
  exec 210>&-
fi
SEED_ARGS=()
if [[ -n "$SEED_SRC" ]]; then
  SEED_ARGS=(-drive file="$SEED_ISO",if=virtio,format=raw,readonly=on)
fi

DEBUG_APPEND=""
if [[ "${RHIZO_ENFORCING:-}" == "1" ]]; then
  DEBUG_APPEND=" hung_task_panic=1 hung_task_timeout_secs=30 softlockup_panic=1 hardlockup_panic=1 nmi_watchdog=1 panic=-1"
fi

if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  case "${RHIZO_KERNEL:-}" in
    "") KERNEL="$KERNEL_DIR/vmlinuz" INITRD="$KERNEL_DIR/initrd.img" ;;
    distro) KERNEL=share/vmlinuz-linux-cachyos INITRD=share/initramfs-linux-cachyos.img ;;
    *) echo "run-vm: RHIZO_KERNEL=$RHIZO_KERNEL names no cachyos vm kernel: unset it for the Rhizo kernel, or set distro for CachyOS's own" >&2; exit 1 ;;
  esac
else
  case "${RHIZO_KERNEL:-}" in
    "") KERNEL="$KERNEL_DIR/vmlinuz" INITRD="$KERNEL_DIR/initrd.img" ;;
    distro) KERNEL=vmlinuz INITRD=initrd.img ;;
    rhizo|6.12)
      echo "run-vm: RHIZO_KERNEL=$RHIZO_KERNEL names a retired 6.12.99 kernel leg; unset it to boot the Rhizo kernel" >&2
      exit 1 ;;
    rhizo-selinuxns)
      echo "run-vm: RHIZO_KERNEL=rhizo-selinuxns is retired: the Rhizo kernel is the default" >&2
      exit 1 ;;
    mainline) KERNEL=share/vmlinuz-mainline INITRD=share/initrd-mainline.img ;;
    mainline-fixed) KERNEL=share/vmlinuz-mainline-fixed INITRD=share/initrd-mainline-fixed.img ;;
    steal) KERNEL=vmlinuz-steal INITRD=initrd.img ;;
    *) echo "run-vm: RHIZO_KERNEL=$RHIZO_KERNEL names no kernel: unset it for the Rhizo kernel, or set distro, mainline, mainline-fixed or steal" >&2; exit 1 ;;
  esac
fi

if [[ "$PRINT_ARGV" != 1 && "$RHIZO_BOOT" == direct && -z "${RHIZO_KERNEL:-}" ]]; then
  KERNEL_REV=$(rhizo_kernel_revision "$SELF_DIR/../..") || exit 1
  if ! vm_kernel_current "$KERNEL_DIR" "$KERNEL_REV"; then
    echo "run-vm: vm $RHIZO_VM's disk $DISK holds no Rhizo kernel at revision $KERNEL_REV (kernel/VERSION; $KERNEL_DIR has '$(cat "$KERNEL_DIR/revision" 2>/dev/null)')" >&2
    echo "  test/vm/image/install-kernel.sh installs it; RHIZO_KERNEL=distro boots the guest's own kernel" >&2
    exit 1
  fi
fi

for _f in "$KERNEL" "$INITRD"; do
  [[ "$RHIZO_BOOT" == grub ]] && continue
  if [[ "$PRINT_ARGV" != 1 && ! -s "$_f" ]]; then
    echo "run-vm: RHIZO_KERNEL=${RHIZO_KERNEL:-<the Rhizo kernel>} needs $_f, which does not exist" >&2
    if [[ "${RHIZO_KERNEL:-}" == mainline* ]]; then
      echo "  build it from kernel-work/mainline outside the repo, stage vmlinuz+initrd here by hand" >&2
    fi
    if [[ "${RHIZO_KERNEL:-}" == steal ]]; then
      echo "  build the steal-accounting kernel and copy its bzImage here as var/vmlinuz-steal" >&2
    fi
    exit 1
  fi
done

VBMETA_DIGEST="095fdab58d1f3bf532d502403738752341bedbbcd73c38ec1349105d54728b4e"
if [[ -f share/vbmeta.digest ]]; then
  VBMETA_DIGEST="$(cat share/vbmeta.digest)"
fi
FW_ARGS=()
if [[ "$(guest_firmware "$RHIZO_GUEST_OS")" == uefi ]]; then
  VARS="$(guest_vars "$RHIZO_GUEST_OS" "$RHIZO_BOOT" "$SUFFIX")"
  if [[ "$PRINT_ARGV" != 1 ]] && [[ ! -f "$VARS" || "$NEW_DISK" == 1 ]]; then
    cp "$(guest_vars_base "$RHIZO_GUEST_OS" "$RHIZO_BOOT")" "$VARS"
  fi
  FW_ARGS=(-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
           -drive if=pflash,format=raw,file="$VARS")
fi
BOOT_ARGS=()
if [[ "$RHIZO_BOOT" == grub ]]; then
  echo "RHIZO_BOOT=grub: no -kernel/-append; the guest's own bootloader supplies the cmdline" >&2
else
  ROOT_ARG="$(guest_root_arg "$RHIZO_GUEST_OS" "$RHIZO_BOOT")"
  LSM_ARG="$(guest_lsm_arg "$RHIZO_GUEST_OS")"
  BOOT_ARGS=(-kernel "$KERNEL" -initrd "$INITRD"
    -append "${ROOT_ARG} console=hvc0 loglevel=8 log_buf_len=16M audit_backlog_limit=32768 loop.max_loop=${RHIZO_LOOP_MAX_LOOP:-64} ${LSM_ARG} enforcing=0 systemd.unified_cgroup_hierarchy=1 androidboot.hardware=rhizo androidboot.selinux=permissive androidboot.use_memfd=1 androidboot.first_stage_console=0 androidboot.verifiedbootstate=orange androidboot.veritymode=disabled androidboot.vbmeta.digest=${VBMETA_DIGEST}${DEBUG_APPEND}")
fi
EGRESS_GUESTFWD=""
if [[ "${RHIZO_ENABLE_PUBLIC_EGRESS:-0}" == "1" ]]; then
  EGRESS_GUESTFWD=",guestfwd=tcp:10.0.2.100:40000-cmd:socat - TCP:10.0.2.2:40000"
fi

case "${RHIZO_VM_GPU:-on}" in
  on)
    GPU_NODE=$(bash "$SELF_DIR/../../src/install/prepare/detect-gpu-driver.sh" --node) \
      || { echo "run-vm.sh: no host render node for the vm's virgl -- detect-gpu-driver.sh says why above (RHIZO_VM_GPU=off boots without one)" >&2; exit 1; }
    read -r RENDER_NODE _ <<<"$GPU_NODE"
    GPU_ARGS=(-display "egl-headless,rendernode=$RENDER_NODE" -device virtio-gpu-gl-pci) ;;
  off) GPU_ARGS=(-display none) ;;
  *) echo "run-vm.sh: RHIZO_VM_GPU is '$RHIZO_VM_GPU', not on or off" >&2; exit 1 ;;
esac

QEMU_ARGV=(qemu-system-x86_64
  -enable-kvm -cpu host -smp "${RHIZO_VM_SMP:-4}" -m "${RHIZO_VM_MEM:-8G}"
  "${GPU_ARGS[@]}"
  -chardev stdio,id=con0,mux=on -mon chardev=con0,mode=readline
  -serial chardev:con0 -device virtio-serial-pci -device virtconsole,chardev=con0 -vga none
  -qmp "unix:${QMP_SOCK},server,nowait"
  "${FW_ARGS[@]}"
  "${BOOT_ARGS[@]}"
  "${DISK_ARGS[@]}"
  "${SEED_ARGS[@]}"
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${ADB_PORT}-:5555${EGRESS_GUESTFWD}" -device virtio-net-pci,netdev=n0
  -virtfs local,path="$SHARE_PATH",mount_tag=share9p,security_model=none)
if [[ "$PRINT_ARGV" == 1 ]]; then
  printf '%s\n' "${QEMU_ARGV[@]}"
  exit 0
fi
rig_boot_guard "$RHIZO_VM" || exit 1
listeners=$(ss -ltn 2>/dev/null)
if grep -q "127.0.0.1:$SSH_PORT " <<<"$listeners"; then
  echo "run-vm.sh: instance $RHIZO_VM already has a guest on port $SSH_PORT" >&2
  echo "  kill the existing guest first, or set RHIZO_VM to a free vm." >&2
  exit 1
fi
if grep -q "127.0.0.1:$ADB_PORT " <<<"$listeners"; then
  echo "run-vm.sh: port $ADB_PORT (instance $RHIZO_VM's adb forward) is already held" >&2
  echo "  by another process -- ss -ltnp | grep :$ADB_PORT names it. Free it, or move" >&2
  echo "  this vm's ports with RHIZO_PORT_OFFSET." >&2
  exit 1
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "run-vm.sh: /dev/kvm is not readable+writable by $(id -un)" >&2
  echo "  the personal container needs the host to grant it: setfacl -m u:$(id -un):rw /dev/kvm," >&2
  echo "  or --device /dev/kvm in the container's own run configuration." >&2
  exit 1
fi
QEMU_WRAPPER=()
wrapper=$(rig_qemu_wrapper run-vm.sh) || exit $?
[[ -z "$wrapper" ]] || mapfile -t QEMU_WRAPPER <<<"$wrapper"
rm -f "vm-boot${SUFFIX}.pid"
rig_boot_started "$RHIZO_VM"

if [[ "${RHIZO_ENABLE_PUBLIC_EGRESS:-0}" == "1" ]]; then
  command -v socat >/dev/null 2>&1 \
    || { echo "run-vm.sh: RHIZO_ENABLE_PUBLIC_EGRESS=1 needs socat, which is not installed" >&2; exit 1; }
  echo "run-vm.sh: public egress ON -- the guest reaches this machine's proxy at http://10.0.2.100:40000"
fi

exec ${QEMU_WRAPPER[@]+"${QEMU_WRAPPER[@]}"} "${QEMU_ARGV[@]}"
