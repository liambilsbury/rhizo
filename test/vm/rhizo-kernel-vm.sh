#!/bin/bash
# boot a disposable cachyos or ubuntu guest on its disks, put the rhizo kernel in it, and reach it over ssh
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=rig/hooks.sh
source "$SELF_DIR/rig/hooks.sh" || exit 2
MAIN="$(cd "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)/.." && pwd)"
SOURCE_VAR="${RHIZO_KERNEL_VM_SOURCE_VAR:-$MAIN/var}"
KERNEL_RELEASE="${RHIZO_KERNEL_RELEASE:-7.1.0-rc1-rhizo}"
LIMINE_ENTRY=linux-rhizo
LIMINE_GUID=513ee0d0-6e43-cb05-b272-f146a2fcb88a
KEY="${RHIZO_KERNEL_VM_KEY:-$SOURCE_VAR/vm_key}"
SSHOPTS=(-i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null)

# print the usage text
usage() {
  cat >&2 <<'EOF'
usage: RHIZO_VM=<2|3|4> test/vm/rhizo-kernel-vm.sh <cachyos|ubuntu> <verb> [args]
  make-base                      reflink-copy the base disk (and firmware vars or seed) into the distro's dir, read-only
  start [--keep]                 boot vm RHIZO_VM on a fresh overlay on the base (--keep: the last one), RHIZO_KERNEL_VM_START_WAIT s for a slot (300)
                                 offering the vm's 9p share dir under var/ (cachyos mounts it at /root/share, ubuntu does
                                 not) and a virtio-gpu; RHIZO_KERNEL_VM_PRINT_ARGV=1 prints the guest's qemu device argv
                                 and exits without booting. RHIZO_KERNEL_VM_SPICE=<socket> adds a viewer
                                 socket for remote-viewer and sizes the guest for interactive use (12 vcpus, 16G)
  wait [S]                       wait up to S seconds (default 600) for ssh
  sh '<cmd>'                     run a command in the guest as root
  put <src> <dst> | get <src> <dst>
  install-kernel <pkgdir> [--no-reboot]
                                 install the rhizo kernel packages in pkgdir, make it the default entry, reboot,
                                 and check uname -r (--no-reboot stops after the default entry is set)
  install-rhizo <pkgdir>         install rhizo's own packages from pkgdir, building them first when pkgdir has none
  adb-port                       print the host port forwarded to the guest's :5555
  reboot [--setup]               reboot the guest and wait for ssh, RHIZO_KERNEL_VM_SSH_WAIT s (600). --setup: the boot runs
                                 first-boot setup (ordered before sshd, downloads the GSI), so ssh also waits for it, up to
                                 RHIZO_KERNEL_VM_SETUP_WAIT s more (2400)
  stop                           power the guest off
  release                        tell the rig hooks this tool is done with vm RHIZO_VM
  usb-attach <vid:pid>           hand a host USB device to the running guest (QMP hot-plug);
                                 the host loses it until usb-detach. RHIZO_KERNEL_VM_USB_HOST=<vid:pid>[,...] does it at start
  usb-detach <vid:pid>           give it back to the host
EOF
}

# print an error and exit 1
die() { echo "rhizo-kernel-vm: $*" >&2; exit 1; }

DISTRO="${1:-}" VERB="${2:-}"
(( $# >= 2 )) || { usage; exit 2; }
shift 2
case "$DISTRO" in cachyos|ubuntu) ;; *) usage; exit 2 ;; esac
case "${RHIZO_VM:-}" in
  2|3|4) ;;
  1) die "RHIZO_VM=1 is the rig's own vm; use 2, 3 or 4" ;;
  *) die "set RHIZO_VM to 2, 3 or 4 (got '${RHIZO_VM:-}')" ;;
esac
DIR="${RHIZO_KERNEL_VM_DIR:-$HOME/src/rhizo-kernel/vm}/$DISTRO"
BASE="$DIR/base.qcow2"
BASE_VARS="$DIR/base.OVMF_VARS.fd"
SEED="$DIR/seed.iso"
PIDFILE="$DIR/qemu.pid"
QMP_SOCK="$DIR/qmp.sock"
SSH_PORT=$((2222 + RHIZO_VM))
ADB_PORT=$((5555 + RHIZO_VM))
NAME="rhizo-kernel-$DISTRO-vm$RHIZO_VM"

# print the qemu pid when this distro's guest runs
live_pid() {
  local pid
  [[ -f "$PIDFILE" ]] || return 1
  pid=$(<"$PIDFILE")
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == qemu-system-x86 ]] \
    || return 1
  echo "$pid"
}

# print the pid of the qemu named NAME, read from /proc
find_qemu() {
  local d
  for d in /proc/[0-9]*; do
    [[ "$(cat "$d/comm" 2>/dev/null)" == qemu-system-x86 ]] || continue
    tr '\0' '\n' < "$d/cmdline" 2>/dev/null | grep -qxF "$NAME" && { echo "${d#/proc/}"; return 0; }
  done
  return 1
}

# run a command in the guest as root
gssh() {
  local t="$1"; shift
  timeout "$t" ssh "${SSHOPTS[@]}" -p "$SSH_PORT" root@127.0.0.1 "$@"
}

# wait until ssh answers
wait_ssh() {
  local bound="${1:-600}" t0=$SECONDS
  until gssh 10 true 2>/dev/null; do
    live_pid >/dev/null || { echo "rhizo-kernel-vm: qemu exited before ssh answered" >&2; return 1; }
    (( SECONDS - t0 < bound )) || { echo "rhizo-kernel-vm: ssh did not answer in ${bound}s" >&2; return 1; }
    sleep 3
  done
  echo "ssh answered after $((SECONDS - t0))s"
}

# copy a source file to a read-only destination
copy_source() {
  local src="$1" dst="$2"
  [[ -f "$dst" ]] && { echo "kept $dst"; return 0; }
  [[ -f "$src" ]] || die "no $src to copy"
  timeout 300 cp --reflink=auto "$src" "$dst.new" || die "cp $src failed"
  chmod 444 "$dst.new" && mv "$dst.new" "$dst" && echo "made $dst from $src"
}

# copy this distro's base disk into DIR
make_base() {
  mkdir -p "$DIR" || die "cannot make $DIR"
  case "$DISTRO" in
    cachyos)
      copy_source "${RHIZO_KERNEL_VM_CACHYOS_DISK:-$SOURCE_VAR/scratch/t21/mirror.qcow2}" "$BASE"
      copy_source "${RHIZO_KERNEL_VM_CACHYOS_VARS:-$SOURCE_VAR/scratch/t21/mirror.OVMF_VARS.fd}" "$BASE_VARS" ;;
    ubuntu)
      copy_source "${RHIZO_KERNEL_VM_UBUNTU_DISK:-$SOURCE_VAR/pristine-dl/noble-server-cloudimg-amd64.img}" "$BASE"
      copy_source "${RHIZO_KERNEL_VM_UBUNTU_SEED:-$SOURCE_VAR/seed-pristine-1.iso}" "$SEED" ;;
  esac
}

# tell the rig hooks this tool is about to use vm RHIZO_VM
use_vm() {
  rig_using_vm "$RHIZO_VM" "rhizo kernel guest ($DISTRO): own disks in $DIR, ssh $SSH_PORT"
}

# write a fresh overlay on the base disk
fresh_overlay() {
  local name="$1"
  case "$DISTRO" in
    cachyos)
      qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$DIR/$name.qcow2.new" || return 1
      cp "$BASE_VARS" "$DIR/$name.OVMF_VARS.fd.new" && chmod 644 "$DIR/$name.OVMF_VARS.fd.new" || return 1
      mv -f "$DIR/$name.OVMF_VARS.fd.new" "$DIR/$name.OVMF_VARS.fd" ;;
    ubuntu)
      qemu-img create -q -f qcow2 -b "$BASE" -F qcow2 "$DIR/$name.qcow2.new" 20G || return 1 ;;
  esac
  mv -f "$DIR/$name.qcow2.new" "$DIR/$name.qcow2"
}

# set the vm's vcpu count and memory
load_envelopes() {
  local wrapper
  RIG_VCPUS="${RHIZO_RIG_VCPUS:-4}"
  RIG_MEM_G="${RHIZO_RIG_MEM_G:-8}"
  QEMU_WRAPPER=()
  wrapper=$(rig_qemu_wrapper rhizo-kernel-vm.sh) || die "the rig hook refused to start the vm"
  [[ -z "$wrapper" ]] || mapfile -t QEMU_WRAPPER <<<"$wrapper"
  if [[ -n "${RHIZO_KERNEL_VM_SPICE:-}${RHIZO_KERNEL_VM_WINDOW:-}" ]]; then
    RIG_VCPUS="${RHIZO_KERNEL_VM_VCPUS:-12}"
    RIG_MEM_G="${RHIZO_KERNEL_VM_MEM_G:-16}"
  else
    RIG_VCPUS="${RHIZO_KERNEL_VM_VCPUS:-$RIG_VCPUS}"
    RIG_MEM_G="${RHIZO_KERNEL_VM_MEM_G:-$RIG_MEM_G}"
  fi
}

# set GUEST_ARGS to the distro's disks, display, gpu and 9p share for the overlay of the given name
# shellcheck disable=SC2054
guest_args() {
  local name="$1" node="${RHIZO_KERNEL_VM_RENDER_NODE:-}"
  if [[ -z "$node" ]]; then
    node=$(bash "$ROOT/src/install/prepare/detect-gpu-driver.sh" --node 2>/dev/null) || die "no host render node for virgl"
    node="${node%% *}"
  fi
  local display=(-display "egl-headless,rendernode=$node")
  case "${RHIZO_KERNEL_VM_WINDOW:-}" in
    sdl) display=(-display "sdl,gl=on") ;;
    gtk) display=(-display "gtk,gl=on,zoom-to-fit=off,window-close=off") ;;
    "") ;;
    *) die "RHIZO_KERNEL_VM_WINDOW is '$RHIZO_KERNEL_VM_WINDOW', not sdl or gtk" ;;
  esac
  if [[ -n "${RHIZO_KERNEL_VM_SPICE:-}" ]]; then
    display+=(-spice "unix=on,addr=$RHIZO_KERNEL_VM_SPICE,disable-ticketing=on"
      -device virtio-serial-pci -chardev spicevmc,id=vdagent,name=vdagent
      -device virtserialport,chardev=vdagent,name=com.redhat.spice.0)
  fi
  GUEST_ARGS=("${display[@]}" -device virtio-gpu-gl-pci -vga none
    -virtfs local,path="$ROOT/var/$(rig_share_dir "$RHIZO_VM")",mount_tag=share9p,security_model=none)
  if [[ -n "${RHIZO_KERNEL_VM_USB_HOST:-}" ]]; then
    local id
    GUEST_ARGS+=(-device qemu-xhci,id=xhci)
    for id in ${RHIZO_KERNEL_VM_USB_HOST//,/ }; do
      [[ "${RHIZO_KERNEL_VM_PRINT_ARGV:-0}" == 1 ]] || usb_check_access "$id"
      GUEST_ARGS+=(-device "usb-host,bus=xhci.0,vendorid=0x${id%%:*},productid=0x${id##*:},id=$(usb_dev_id "$id")")
    done
  fi
  case "$DISTRO" in
    cachyos)
      GUEST_ARGS+=(-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
        -drive if=pflash,format=raw,file="$DIR/$name.OVMF_VARS.fd"
        -drive file="$DIR/$name.qcow2",if=none,id=disk0,format=qcow2 -device virtio-blk-pci,drive=disk0,addr=0x5
        -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 -usb -device usb-tablet) ;;
    ubuntu)
      GUEST_ARGS+=(-drive file="$DIR/$name.qcow2",if=virtio,format=qcow2
        -drive file="$SEED",if=virtio,format=raw,readonly=on) ;;
  esac
}

# boot the overlay of the given name detached, through the rig's slot and cpuset, in its scope unit
boot_overlay() {
  local name="$1" pid serial t0 unit share
  live_pid >/dev/null && die "a $DISTRO guest already runs as pid $(live_pid)"
  ss -ltn | grep -qE "127\.0\.0\.1:($SSH_PORT|$ADB_PORT) " && die "port $SSH_PORT or $ADB_PORT is taken"
  load_envelopes
  guest_args "$name"
  share="$ROOT/var/$(rig_share_dir "$RHIZO_VM")"
  mkdir -p "$share" || die "cannot make $share"
  mkdir -p "$DIR/logs"
  serial="$DIR/logs/serial-$name-$(date +%Y%m%d-%H%M%S).log"
  rm -f "$QMP_SOCK"
  unit="$NAME-$(date +%s%N)"
  (cd "$DIR" && setsid -f \
    systemd-run --user --scope --unit="$unit" --quiet --collect -p MemoryMax=$((RIG_MEM_G + 4))G -p TasksMax=4096 \
    ${QEMU_WRAPPER[@]+"${QEMU_WRAPPER[@]}"} qemu-system-x86_64 \
    -name "$NAME" -enable-kvm -cpu host -smp "$RIG_VCPUS" -m "${RIG_MEM_G}G" \
    "${GUEST_ARGS[@]}" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22,hostfwd=tcp:127.0.0.1:$ADB_PORT-:5555" \
    -device virtio-net-pci,netdev=n0 \
    -qmp "unix:$QMP_SOCK,server,nowait" -serial file:"$serial" -monitor none \
    </dev/null >"$serial.qemu" 2>&1)
  t0=$SECONDS
  until pid=$(find_qemu); do
    if (( SECONDS - t0 >= ${RHIZO_KERNEL_VM_START_WAIT:-300} )); then
      timeout 30 systemctl --user stop "$unit.scope" 2>/dev/null
      die "qemu did not start in ${RHIZO_KERNEL_VM_START_WAIT:-300}s; stopped scope $unit: $(tail -3 "$serial.qemu")"
    fi
    sleep 2
  done
  echo "$pid" > "$PIDFILE"
  echo "booting $DISTRO overlay $name as pid $pid (serial $serial)"
}

# boot a fresh overlay, or the last one with --keep
start_guest() {
  [[ -f "$BASE" ]] || die "no $BASE -- run make-base first"
  live_pid >/dev/null && die "a $DISTRO guest already runs as pid $(live_pid)"
  use_vm || return 1
  if [[ "${1:-}" != --keep || ! -f "$DIR/overlay.qcow2" ]]; then
    fresh_overlay overlay || die "could not write a fresh overlay in $DIR"
  fi
  boot_overlay overlay
}

# send a QMP command to the guest's monitor
qmp() {
  { echo '{"execute":"qmp_capabilities"}'; echo "{\"execute\":\"$1\"}"; sleep 0.5; } \
    | timeout 8 socat - "UNIX-CONNECT:$QMP_SOCK" >/dev/null 2>&1
}

# send a QMP command given as JSON and print the monitor's replies
qmp_json() {
  { echo '{"execute":"qmp_capabilities"}'; echo "$1"; sleep 0.5; } | timeout 8 socat - "UNIX-CONNECT:$QMP_SOCK" 2>&1
}

# print the /dev/bus/usb node of a host USB device
usb_node() {
  local vid="${1%%:*}" pid="${1##*:}" d
  [[ "$1" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || die "expected a USB id as vid:pid, got '$1'"
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && "$(<"$d/idVendor")" == "${vid,,}" && "$(<"$d/idProduct")" == "${pid,,}" ]] || continue
    printf '/dev/bus/usb/%03d/%03d\n' "$(<"$d/busnum")" "$(<"$d/devnum")"
    return 0
  done
  die "no host USB device $1"
}

# check this user can write the usb device node
usb_check_access() {
  local node
  node=$(usb_node "$1") || exit 1
  [[ -w "$node" ]] || die "$node ($1) is not writable by $(id -un). Once, as root:
  echo 'SUBSYSTEM==\"usb\", ATTR{idVendor}==\"${1%%:*}\", ATTR{idProduct}==\"${1##*:}\", TAG+=\"uaccess\"' > /etc/udev/rules.d/70-rhizo-usb-passthrough.rules && udevadm control --reload && udevadm trigger --action=add --attr-match=idVendor=${1%%:*} --attr-match=idProduct=${1##*:}"
}

# print the qemu id of the usb-host device for vid:pid
usb_dev_id() { echo "usbhost-${1/:/-}"; }

# hot-plug a host USB device into the guest
usb_attach() {
  local out
  live_pid >/dev/null || die "no $DISTRO guest running"
  usb_check_access "$1"
  qmp_json '{"execute":"device_add","arguments":{"driver":"qemu-xhci","id":"xhci"}}' >/dev/null
  out=$(qmp_json "{\"execute\":\"device_add\",\"arguments\":{\"driver\":\"usb-host\",\"bus\":\"xhci.0\",\"vendorid\":$((16#${1%%:*})),\"productid\":$((16#${1##*:})),\"id\":\"$(usb_dev_id "$1")\"}}")
  grep -q '"error"' <<<"$out" && die "device_add usb-host $1 failed: $(grep -o '"desc": *"[^"]*"' <<<"$out" | tail -1)"
  echo "attached $1 to the $DISTRO guest; the host has lost it until: usb-detach $1"
}

# unplug a host usb device from the guest
usb_detach() {
  local out
  live_pid >/dev/null || die "no $DISTRO guest running"
  out=$(qmp_json "{\"execute\":\"device_del\",\"arguments\":{\"id\":\"$(usb_dev_id "$1")\"}}")
  grep -q '"error"' <<<"$out" && die "device_del $1 failed: $(grep -o '"desc": *"[^"]*"' <<<"$out" | tail -1)"
  echo "detached $1 from the $DISTRO guest"
}

# power the guest off and wait for its qemu to exit
stop_guest() {
  local pid t0
  pid=$(live_pid) || { echo "no $DISTRO guest running"; rm -f "$PIDFILE"; return 0; }
  gssh 20 'sync; systemctl poweroff' >/dev/null 2>&1
  t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null && (( SECONDS - t0 < 150 )); do sleep 2; done
  if kill -0 "$pid" 2>/dev/null; then
    qmp quit
    sleep 5
  fi
  kill -0 "$pid" 2>/dev/null && [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == qemu-system-x86 ]] && kill "$pid"
  rm -f "$PIDFILE"
  echo "$DISTRO guest stopped (was pid $pid)"
}

# tell the rig hooks this tool is done with vm RHIZO_VM
release_vm() {
  live_pid >/dev/null && die "stop the $DISTRO guest first"
  rig_done_with_vm "$RHIZO_VM"
}

# reboot the guest and wait for ssh
reboot_guest() {
  local before after t0 ssh_wait="${RHIZO_KERNEL_VM_SSH_WAIT:-600}" setup_wait="${RHIZO_KERNEL_VM_SETUP_WAIT:-2400}" budget why
  budget=$ssh_wait
  why="ssh did not answer within RHIZO_KERNEL_VM_SSH_WAIT=${ssh_wait}s of the reboot"
  if [[ "${1:-}" == --setup ]]; then
    budget=$((ssh_wait + setup_wait))
    why="ssh did not answer within RHIZO_KERNEL_VM_SSH_WAIT=${ssh_wait}s + RHIZO_KERNEL_VM_SETUP_WAIT=${setup_wait}s of the reboot; raise RHIZO_KERNEL_VM_SETUP_WAIT"
  fi
  before=$(gssh 20 cat /proc/sys/kernel/random/boot_id) || die "the guest does not answer ssh"
  gssh 20 'systemctl reboot' >/dev/null 2>&1
  t0=$SECONDS
  while :; do
    (( SECONDS - t0 < budget )) || die "$why"
    live_pid >/dev/null || die "qemu exited during the reboot"
    sleep 5
    after=$(gssh 10 cat /proc/sys/kernel/random/boot_id 2>/dev/null) || continue
    [[ "$after" != "$before" ]] && break
  done
  echo "rebooted in $((SECONDS - t0))s"
}

# copy files into a guest directory, made first
put_files() {
  local dst="$1"; shift
  gssh 30 mkdir -p "$dst" || return 1
  timeout 900 scp "${SSHOPTS[@]}" -P "$SSH_PORT" "$@" "root@127.0.0.1:$dst/"
}

# print the newest kernel package files in pkgdir
kernel_packages() {
  local pkgdir="$1" pattern patterns=()
  case "$DISTRO" in
    cachyos) patterns=('linux-rhizo-[0-9]*.pkg.tar.zst' 'linux-rhizo-headers-[0-9]*.pkg.tar.zst') ;;
    ubuntu) patterns=("linux-image-${KERNEL_RELEASE}_*.deb" "linux-headers-${KERNEL_RELEASE}_*.deb"
      'linux-image-rhizo_*.deb' 'linux-headers-rhizo_*.deb') ;;
  esac
  for pattern in "${patterns[@]}"; do
    find "$pkgdir" -maxdepth 1 -name "$pattern" | sort -V | tail -1
  done
}

# make the rhizo kernel Limine's default entry
set_limine_default() {
  gssh 60 bash -s -- "$LIMINE_ENTRY" "$LIMINE_GUID" <<'GUEST'
set -u
entry=$1 guid=$2 conf=/boot/limine.conf
grep -q '^remember_last_entry: *yes' "$conf" || { echo "$conf does not remember the last entry"; exit 1; }
os=$(grep -m1 '^/' "$conf" | sed -e 's|^/||' -e 's|^+||')
grep -qx "  //$entry" "$conf" || { echo "$conf has no //$entry entry under /$os"; exit 1; }
var=$(ls /sys/firmware/efi/efivars/LimineLastBootedEntry-* 2>/dev/null | head -1)
[ -n "$var" ] || var=/sys/firmware/efi/efivars/LimineLastBootedEntry-$guid
[ -e "$var" ] && chattr -i "$var"
printf '\007\000\000\000%s\000' "$os/$entry" > /tmp/limine-entry.bin
dd if=/tmp/limine-entry.bin of="$var" bs=4096 status=none || { echo "cannot write $var"; exit 1; }
echo "Limine default: $(tail -c +5 "$var" | tr -d '\0')"
GUEST
}

# make the rhizo kernel GRUB's saved default entry
set_grub_default() {
  gssh 300 bash -s -- "$KERNEL_RELEASE" <<'GUEST'
set -u
rel=$1 root=${RHIZO_GRUB_ROOT:-}
own=$root/etc/default/grub.d/99-rhizo-kernel-vm.cfg
# print the effective GRUB_DEFAULT value
effective() { cat "$root/etc/default/grub" "$@" 2>/dev/null | sed -n 's/^GRUB_DEFAULT=//p' | tail -1; }
dropins=$(ls "$root"/etc/default/grub.d/*.cfg 2>/dev/null | LC_ALL=C sort)
if [ "$(effective $dropins)" != saved ]; then
  # refuse a later drop-in that sets GRUB_DEFAULT
  for f in $dropins; do
    if [ "$f" \> "$own" ] && grep -q '^GRUB_DEFAULT=' "$f"; then
      echo "$f sorts after $own and sets $(sed -n 's/^GRUB_DEFAULT=//p' "$f" | tail -1)"; exit 1
    fi
  done
  printf 'GRUB_DEFAULT=saved\n' > "$own" || { echo "cannot write $own"; exit 1; }
fi
update-grub >/dev/null 2>&1 || { echo "update-grub failed"; exit 1; }
sub=$(grep -o "gnulinux-advanced-[0-9a-f-]*" "$root/boot/grub/grub.cfg" | head -1)
ent=$(grep -o "gnulinux-$rel-advanced-[0-9a-f-]*" "$root/boot/grub/grub.cfg" | head -1)
[ -n "$sub" ] && [ -n "$ent" ] || { echo "grub.cfg has no entry for $rel"; exit 1; }
grub-set-default "$sub>$ent" && grub-editenv list
GUEST
}

# install the rhizo kernel and reboot into it
install_kernel() {
  local pkgdir="${1:-}" noreboot=0 files=() names=() f got
  [[ -d "$pkgdir" ]] || die "install-kernel takes the directory of the kernel packages"
  [[ "${2:-}" == --no-reboot ]] && noreboot=1
  mapfile -t files < <(kernel_packages "$pkgdir")
  case "$DISTRO" in
    cachyos) (( ${#files[@]} == 2 )) || die "want linux-rhizo and linux-rhizo-headers in $pkgdir, found ${#files[@]}" ;;
    ubuntu) (( ${#files[@]} == 4 )) || die "want the image, headers and their two meta debs in $pkgdir, found ${#files[@]}" ;;
  esac
  for f in "${files[@]}"; do names+=("/root/rhizo-kernel-pkgs/${f##*/}"); done
  put_files /root/rhizo-kernel-pkgs "${files[@]}" || die "cannot copy the kernel packages into the guest"
  case "$DISTRO" in
    cachyos)
      gssh 1200 pacman -U --noconfirm "${names[@]}" || die "pacman -U of the kernel failed"
      set_limine_default || die "cannot make $LIMINE_ENTRY the Limine default" ;;
    ubuntu)
      gssh 1200 env DEBIAN_FRONTEND=noninteractive dpkg -i "${names[@]}" || die "dpkg -i of the kernel failed"
      set_grub_default || die "cannot make $KERNEL_RELEASE the GRUB default" ;;
  esac
  gssh 60 rm -rf /root/rhizo-kernel-pkgs || die "cannot remove the kernel package copies from the guest"
  (( noreboot )) && return 0
  reboot_guest
  got=$(gssh 20 uname -r) || die "no uname -r after the reboot"
  [[ "$got" == "$KERNEL_RELEASE" ]] || die "uname -r is $got, not $KERNEL_RELEASE"
  echo "running $got"
}

# print rhizo's package files in pkgdir
rhizo_packages() {
  case "$DISTRO" in
    cachyos) find "$1" -maxdepth 1 -name 'rhizo*.pkg.tar.zst' | sort ;;
    ubuntu) find "$1" -maxdepth 1 -name 'rhizo*.deb' | sort ;;
  esac
}

# build rhizo's packages from this tree into pkgdir
build_rhizo_packages() {
  local pkgdir="$1" was_live=0 rc
  mkdir -p "$pkgdir" || return 1
  (cd "$ROOT" && make env-deb) || { echo "rhizo-kernel-vm: make env-deb failed" >&2; return 1; }
  if [[ "$DISTRO" == ubuntu ]]; then
    cp "$ROOT"/var/debs/rhizo_*.deb "$pkgdir"/
    return
  fi
  (cd "$ROOT" && make arch) || { echo "rhizo-kernel-vm: make arch failed" >&2; return 1; }
  live_pid >/dev/null && { was_live=1; stop_guest; }
  fresh_overlay build && boot_overlay build || return 1
  wait_ssh 600 || { stop_guest; return 1; }
  (cd "$ROOT" && timeout 1500 tools/build/packaging/arch/arch-pkgs.sh) > "$DIR/logs/arch-pkgs.log" 2>&1
  rc=$?
  stop_guest
  (( rc == 0 )) && cp "$ROOT"/var/share/arch-pkgs/*.pkg.tar.zst "$pkgdir"/
  (( was_live )) && { boot_overlay overlay && wait_ssh 600 || return 1; }
  (( rc == 0 )) || echo "rhizo-kernel-vm: arch-pkgs.sh failed, see $DIR/logs/arch-pkgs.log" >&2
  return "$rc"
}

# install rhizo's packages in the guest
install_rhizo() {
  local pkgdir="${1:-}" files=() names=() f
  [[ -n "$pkgdir" ]] || die "install-rhizo takes a package directory"
  live_pid >/dev/null || die "no $DISTRO guest runs to install into -- start one first"
  mapfile -t files < <([[ -d "$pkgdir" ]] && rhizo_packages "$pkgdir")
  if (( ${#files[@]} == 0 )); then
    build_rhizo_packages "$pkgdir" || die "could not build rhizo's packages"
    mapfile -t files < <(rhizo_packages "$pkgdir")
    (( ${#files[@]} )) || die "the build left no rhizo packages in $pkgdir"
  fi
  for f in "${files[@]}"; do names+=("/root/rhizo-pkgs/${f##*/}"); done
  put_files /root/rhizo-pkgs "${files[@]}" || die "cannot copy rhizo's packages into the guest"
  case "$DISTRO" in
    cachyos) gssh 1800 pacman -U --noconfirm "${names[@]}" ;;
    ubuntu)
      gssh 600 env DEBIAN_FRONTEND=noninteractive apt-get update || die "apt-get update in the guest failed"
      gssh 1800 env DEBIAN_FRONTEND=noninteractive apt-get install -y "${names[@]}" ;;
  esac || return
  gssh 60 rm -rf /root/rhizo-pkgs || die "cannot remove rhizo's package copies from the guest"
}

if [[ "${RHIZO_KERNEL_VM_PRINT_ARGV:-0}" == 1 && "$VERB" == start ]]; then
  guest_args overlay
  printf '%s\n' "${GUEST_ARGS[@]}"
  exit 0
fi
case "$VERB" in
  wait|sh|put|get|install-kernel|install-rhizo|reboot) use_vm || die "the rig hooks refused vm $RHIZO_VM" ;;
esac
case "$VERB" in
  make-base) make_base ;;
  start) start_guest "$@" ;;
  wait) wait_ssh "${1:-600}" ;;
  sh) (( $# )) || die "sh takes a command"; gssh "${RHIZO_KERNEL_VM_SSH_TIMEOUT:-600}" "$@" ;;
  put) (( $# == 2 )) || die "put takes <src> <dst>"; timeout 900 scp "${SSHOPTS[@]}" -P "$SSH_PORT" -r "$1" "root@127.0.0.1:$2" ;;
  get) (( $# == 2 )) || die "get takes <src> <dst>"; timeout 900 scp "${SSHOPTS[@]}" -P "$SSH_PORT" -r "root@127.0.0.1:$1" "$2" ;;
  install-kernel) install_kernel "$@" ;;
  install-rhizo) install_rhizo "$@" ;;
  adb-port) echo "$ADB_PORT" ;;
  reboot) reboot_guest "${1:-}" ;;
  stop) stop_guest ;;
  release) release_vm ;;
  usb-attach) (( $# == 1 )) || die "usb-attach takes <vid:pid>"; usb_attach "$1" ;;
  usb-detach) (( $# == 1 )) || die "usb-detach takes <vid:pid>"; usb_detach "$1" ;;
  *) usage; exit 2 ;;
esac
