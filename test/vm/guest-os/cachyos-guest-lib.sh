#!/bin/bash
# define functions to start and stop a guest
cachyos_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
qemu_pid=""
qemu_exit=""
ssh_port=""
qmp_sock=""
boot_ssh_bound="${boot_ssh_bound:-600}"

for t in qemu-system-x86_64 qemu-img ssh ss python3 sha256sum flock git; do
  command -v "$t" >/dev/null || { echo "$t is required and not installed" >&2; exit 1; }
done
# shellcheck source=../rig/hooks.sh
source "$cachyos_lib_dir/../rig/hooks.sh" || exit 2
RIG_VCPUS="${RHIZO_RIG_VCPUS:-4}"
RIG_MEM_G="${RHIZO_RIG_MEM_G:-8}"

# lock var/cachyos-dl/build.lock
cachyos_build_lock() {
  mkdir -p var/cachyos-dl
  exec {cachyos_lock_fd}>var/cachyos-dl/build.lock
  flock -n "$cachyos_lock_fd" || { echo "another cachyos image build holds var/cachyos-dl/build.lock" >&2; exit 1; }
}

# exit on any vm disk overlaying base $1
refuse_vm_overlays() {
  local base key wt img real chain hit checkouts seen=" " found=()
  local in_chain='import json, os, sys
chain = json.load(sys.stdin)
print("yes" if any(os.path.realpath(i["filename"]) == sys.argv[1] for i in chain[1:]) else "no")'
  base=$(realpath -m "$1")
  checkouts=$(git -C "$cachyos_lib_dir" worktree list --porcelain 2>&1) \
    || { echo "git worktree list failed: $checkouts" >&2; exit 1; }
  while read -r key wt; do
    [[ "$key" == worktree ]] || continue
    for img in "$wt"/var/*.qcow2; do
      [[ -f "$img" ]] || continue
      real=$(realpath "$img")
      [[ "$seen" == *" $real "* ]] && continue
      seen+="$real "
      chain=$(qemu-img info -U --backing-chain --output=json "$real") \
        || { echo "qemu-img info could not read the backing chain of $real" >&2; exit 1; }
      hit=$(python3 -c "$in_chain" "$base" <<<"$chain")
      [[ "$hit" == yes ]] && found+=("$img (checkout $wt)")
    done
  done <<<"$checkouts"
  (( ${#found[@]} == 0 )) || {
    echo "these vm disks overlay $1; reap their vms and delete them first:" >&2
    printf '  %s\n' "${found[@]}" >&2
    exit 1
  }
}

# print the kernel release of bzImage $1
kernel_release() {
  python3 - "$1" <<'PY_RELEASE'
import struct, sys
with open(sys.argv[1], "rb") as f:
    data = f.read(65536)
if data[0x202:0x206] != b"HdrS":
    sys.exit("%s is not a bzImage: no HdrS header" % sys.argv[1])
off = struct.unpack_from("<H", data, 0x20E)[0] + 0x200
print(data[off:data.index(b"\0", off)].decode().split()[0])
PY_RELEASE
}

# start qemu under the rig hook's wrapper
start_guest() {
  local comm wrapper wrap=()
  wrapper=$(rig_qemu_wrapper cachyos-guest-lib.sh) || { echo "the rig hook refused to start the guest" >&2; exit 1; }
  [[ -z "$wrapper" ]] || mapfile -t wrap <<<"$wrapper"
  ${wrap[@]+"${wrap[@]}"} qemu-system-x86_64 \
    -enable-kvm -cpu "${RIG_GUEST_CPU:-host}" -smp "$RIG_VCPUS" -m "${RIG_MEM_G}G" -display none -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd "$@" &
  qemu_pid=$!
  while read -r comm < "/proc/$qemu_pid/comm" && [[ "$comm" != qemu-system-x86 ]]; do
    sleep 1
  done
  [[ "$comm" == qemu-system-x86 ]] || { echo "qemu did not start, pid $qemu_pid is gone" >&2; return 1; }
}

# kill the guest qemu process
stop_guest() {
  if [[ -n "$qemu_pid" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid"
    wait "$qemu_pid" || echo "stopped qemu pid $qemu_pid, rc=$?" >&2
  fi
}

# print the last 60 log lines and exit
fail_log() {
  echo "$1; last 60 lines of $2:" >&2
  tr -d '\r' < "$2" | tail -n 60 >&2
  exit 1
}

# wait for the guest qemu to exit
wait_qemu_exit() {
  local deadline=$((SECONDS + $1)) rc=0
  while kill -0 "$qemu_pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      qemu_exit="qemu pid $qemu_pid still running after $1s"
      return 1
    fi
    sleep 5
  done
  wait "$qemu_pid" || rc=$?
  qemu_pid=""
  qemu_exit="qemu exited rc=$rc"
  return "$rc"
}

# run a command on the guest over ssh
guest() {
  timeout "$1" ssh -i var/vm_key -p "$ssh_port" -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@127.0.0.1 "${@:2}"
}

# run a guest command and exit on failure
guest_step() {
  local rc=0
  guest "$@" || rc=$?
  (( rc == 0 )) || { echo "'${*:2}' on the guest exited rc $rc (124 is the ${1}s bound, 255 is ssh)" >&2; exit 1; }
}

# check a guest command output against $1
expect() {
  local want="$1" out rc=0
  out=$(guest 60 "${@:2}" 2>&1) || rc=$?
  [[ "$out" == "$want" ]] || {
    echo "'${*:2}' printed '$(tr '\n' ' ' <<<"$out")' (rc $rc), want '$(tr '\n' ' ' <<<"$want")'" >&2
    exit 1
  }
}

# return an error for an overlong socket path
require_socket_path() {
  local len
  len=$(printf %s "$1" | wc -c)
  (( len <= 107 )) || { echo "the socket path $1 is $len bytes, over 107" >&2; return 1; }
}

# print the guest state and save its screen
capture_guest() {
  local rc=0
  rm -f "$1.screen.png"
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    echo "qemu pid $qemu_pid is gone" >&2
    return 0
  fi
  python3 "$cachyos_lib_dir/qmp.py" --sock "$qmp_sock" --screen "$1.screen.png" --pid "$qemu_pid" >&2 || rc=$?
  (( rc == 0 )) || echo "the state capture exited $rc" >&2
}

# capture the guest state and fail with $1
fail_boot() {
  capture_guest "$2"
  if [[ -f "$2.screen.png" ]]; then
    fail_log "$1; screen saved to $2.screen.png" "$2"
  else
    fail_log "$1; no screen was saved" "$2"
  fi
}

# boot a disk overlay and wait for ssh
boot_overlay() {
  local disk="$1" vars="$2" dir="$3" boot_log="$4" t0 listeners state
  shift 4
  mkdir -p "$dir/share"
  qemu-img create -q -f qcow2 -b "$(realpath "$disk")" -F qcow2 "$dir/overlay.qcow2"
  cp "$vars" "$dir/overlay.OVMF_VARS.fd"
  : > "$boot_log"
  rm -f "$boot_log.screen.png"
  qmp_sock="@rhizo-qmp.$$.$(basename "$dir")"
  start_guest \
    -drive if=pflash,format=raw,file="$dir/overlay.OVMF_VARS.fd" \
    -drive file="$dir/overlay.qcow2",if=virtio,format=qcow2 \
    -virtfs local,path="$dir/share",mount_tag=share9p,security_model=none \
    -nic "user,model=virtio,hostfwd=tcp:127.0.0.1:0-:22" \
    -chardev "socket,id=qmp0,path=${qmp_sock#@},abstract=on,server=on,wait=off" -mon chardev=qmp0,mode=control \
    -serial file:"$boot_log" "$@"
  t0=$SECONDS
  while :; do
    listeners=$(ss -Hltnp) || fail_log "ss -Hltnp exited $?" "$boot_log"
    ssh_port=$(sed -n "s/.* 127\.0\.0\.1:\([0-9]*\) .*pid=$qemu_pid,.*/\1/p" <<<"$listeners")
    [[ -z "$ssh_port" ]] || break
    kill -0 "$qemu_pid" 2>/dev/null || fail_log "qemu exited before binding its ssh forward" "$boot_log"
    (( SECONDS - t0 < 60 )) || fail_log "qemu pid $qemu_pid bound no loopback port in 60s" "$boot_log"
    sleep 1
  done
  echo "booting $disk, qemu pid $qemu_pid, ssh port $ssh_port"

  t0=$SECONDS
  until guest 15 true; do
    kill -0 "$qemu_pid" 2>/dev/null || fail_boot "qemu exited before ssh answered" "$boot_log"
    (( SECONDS - t0 < boot_ssh_bound )) || fail_boot "ssh on port $ssh_port did not answer in ${boot_ssh_bound}s" "$boot_log"
    sleep 3
  done
  kill -0 "$qemu_pid" 2>/dev/null || fail_log "ssh answered on port $ssh_port but qemu pid $qemu_pid is gone" "$boot_log"
  echo "ssh answered after $((SECONDS - t0))s"

  state=$(guest 300 systemctl is-system-running --wait) || [[ "$state" == degraded ]] \
    || { echo "the guest's boot did not finish: systemctl is-system-running printed '$state'" >&2; exit 1; }
  echo "guest boot finished: $state"
}

# record guest command output and exit status
record_facts() {
  local out="$1" c o rc
  shift
  : > "$out"
  for c in "$@"; do
    rc=0
    o=$(guest 60 "$c" 2>&1) || rc=$?
    (( rc != 124 && rc != 255 )) || { echo "ssh failed running '$c', rc=$rc: $o" >&2; exit 1; }
    printf '$ %s\n%s\nrc=%d\n\n' "$c" "$o" "$rc" >> "$out"
  done
  echo "recorded $# facts"
}

guest_poweroff() {
  local rc=0
  guest 30 systemctl poweroff --no-block || rc=$?
  if wait_qemu_exit 300; then
    echo "$qemu_exit"
  else
    echo "systemctl poweroff over ssh exited rc $rc, then $qemu_exit" >&2
    exit 1
  fi
}
