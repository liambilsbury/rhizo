#!/bin/bash
# shared helpers for the VM tooling
_VM_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VAR_DIR="$REPO/var"
# shellcheck source=rig/hooks.sh
source "$_VM_COMMON_DIR/rig/hooks.sh" || return 2

RHIZO_GSI_STAGE_SPACE_KB="${RHIZO_GSI_STAGE_SPACE_KB:-3500000}"
SSH_KEY="$VAR_DIR/vm_key"

RHIZO_VM_NAMED=1
[[ -n "${RHIZO_VM:-}" ]] || RHIZO_VM_NAMED=0
RHIZO_VM="${RHIZO_VM:-0}"
export RHIZO_INSTANCE="$RHIZO_VM"
SUFFIX=""
[[ "$RHIZO_VM" != 0 ]] && SUFFIX="-$RHIZO_VM"
SSH_PORT=$((2222 + RHIZO_VM + ${RHIZO_PORT_OFFSET:-0}))
# shellcheck disable=SC2034
ADB_PORT=$((5555 + RHIZO_VM + ${RHIZO_PORT_OFFSET:-0}))
export ANDROID_ADB_SERVER_PORT=$((5137 + RHIZO_VM + ${RHIZO_PORT_OFFSET:-0}))
export ADB_LOCAL_TRANSPORT_MAX_PORT=5554
QMP_SOCK="$VAR_DIR/qmp${SUFFIX}.sock"
VM_PIDFILE="$VAR_DIR/vm${SUFFIX}.pid"
RHIZO_BOOT_REFUSAL=""
SSH_TARGET="root@127.0.0.1"

# check a dir can hold the ssh control socket
_ssh_control_dir_usable() {
  local probe
  mkdir -p "$1" 2>/dev/null || return 1
  probe="$1/.writable.$$"
  : > "$probe" 2>/dev/null || return 1
  rm -f "$probe"
}
RHIZO_SSH_CONTROL_DIR_NOTE=""
_ssh_cd=""
_ssh_cands=()
[[ -n "${XDG_RUNTIME_DIR:-}" ]] && _ssh_cands+=("$XDG_RUNTIME_DIR")
_ssh_cands+=(/tmp)
for _ssh_cand in "${_ssh_cands[@]}"; do
  _ssh_try="$_ssh_cand/rhizo-ssh-$(id -u)"
  _ssh_why=""
  if (( ${#_ssh_try} + ${#SUFFIX} + 8 > 91 )); then
    _ssh_why="ControlPath there would be over 91 bytes"
  elif ! _ssh_control_dir_usable "$_ssh_try"; then
    _ssh_why="not creatable or not writable by $(id -un)"
  fi
  [[ -z "$_ssh_why" ]] && { _ssh_cd="$_ssh_try"; break; }
  RHIZO_SSH_CONTROL_DIR_NOTE+="${RHIZO_SSH_CONTROL_DIR_NOTE:+; }$_ssh_try: $_ssh_why"
done
unset _ssh_cand _ssh_cands _ssh_try _ssh_why
SSH_CONTROL_DIR="$_ssh_cd"
if [[ -z "$SSH_CONTROL_DIR" ]]; then
  echo "common.sh: no usable SSH ControlMaster directory ($RHIZO_SSH_CONTROL_DIR_NOTE)." >&2
  echo "  Set XDG_RUNTIME_DIR to a directory you own." >&2
  exit 1
fi
SSH_CONTROL_SOCK="$SSH_CONTROL_DIR/cm${SSH_PORT}.sock"
if (( ${#SSH_CONTROL_SOCK} > 91 )); then
  echo "common.sh: ControlPath '$SSH_CONTROL_SOCK' is ${#SSH_CONTROL_SOCK} bytes;" \
       "the limit is 91. Set XDG_RUNTIME_DIR shorter." >&2
  exit 1
fi
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
          -o "ControlMaster=auto" -o "ControlPersist=600" -o "ControlPath=$SSH_CONTROL_SOCK")

PROBE_SOCK="$VAR_DIR/probe${SUFFIX}.sock"
PROBE_REMOTE_SOCK="/run/rhizo/data/local/tmp/rhizo-probe.sock"

PROBE_FWD_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
                -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
                -o "ControlMaster=no" -o "ControlPath=none")

SHARE_DIR="$VAR_DIR/$(rig_share_dir "$RHIZO_VM")"

# mount this vm's SHARE_DIR on the guest
guest_mount_share() {
  local out
  out=$(ssh_vm -t "${1:-30}" 'mkdir -p /root/share
{ modprobe 9pnet_virtio 2>/dev/null; modprobe 9p 2>/dev/null; } || true
mountpoint -q /root/share || mount -t 9p -o trans=virtio,version=9p2000.L,msize=1048576 share9p /root/share
mountpoint -q /root/share && echo RHIZO_SHARE_MOUNTED' 2>&1)
  case "$out" in
    *RHIZO_SHARE_MOUNTED*) return 0 ;;
  esac
  log "guest_mount_share: /root/share is not mounted on vm $RHIZO_VM (host side: $SHARE_DIR)"
  log "  the guest said: ${out:-nothing at all}"
  return 1
}

# print the guest's os-release ID
guest_os_id() {
  local out rc
  out=$(ssh_vm -t 15 '. /etc/os-release && echo "$ID"')
  rc=$?
  (( rc == 0 )) || return "$rc"
  tr -d '[:space:]' <<<"$out"
}

# refuse a guest package install once SELinux enforces
guest_refuse_install_if_enforcing() {
  local state
  state=$(ssh_vm -t 10 'if [ -e /sys/fs/selinux/enforce ]; then cat /sys/fs/selinux/enforce; else echo absent; fi' | tr -d '[:space:]')
  case "$state" in
    0|absent) return 0 ;;
    1)
      log "FAIL: $1 is not installed and vm $RHIZO_VM is enforcing"
      log "  install it on a boot without Android: $2"
      return 1
      ;;
    *)
      log "FAIL: could not read /sys/fs/selinux/enforce on vm $RHIZO_VM before installing $1 (read '$state')"
      return 1
      ;;
  esac
}

# stage a file into a share dir
stage_to_share() {
  local src="$1" dst="$2"
  shift 2
  cmp -s -- "$src" "$dst" && return 0
  cp --remove-destination "$@" -- "$src" "$dst"
}

STAGE_DIR_NAMES="gpu_driver gpu_driver_32 gpu_driver_intel gpu_driver_amd gpu_driver_zink gpu_driver_lavapipe gpu_driver_software gfx_hal gfx_hal_32 guest sandbox netbridged"

# check each STAGE_DIR_NAMES entry has a directory
check_stage_dirs() {
  local dir="$1" d
  for d in $STAGE_DIR_NAMES; do
    [[ -d "$dir/$d" ]] && continue
    echo "REFUSING to stage -- STAGE_DIR_NAMES names '$d' but $dir/$d does not exist" >&2
    return 1
  done
}

# print the command to run a GSI binary on the guest
gsi_bootstrap_cmd() {
  local tree="$1" bin="$2"; shift 2
  printf 'LD_LIBRARY_PATH=%s/lib64/bootstrap:%s/lib64 %s/bin/bootstrap/linker64 %s/%s %s' \
    "$tree" "$tree" "$tree" "$tree" "$bin" "$*"
}

# run a command on the guest over ssh
ssh_vm() {
  local timeout_s=20
  if [[ "${1:-}" == "-t" ]]; then timeout_s="$2"; shift 2; fi
  timeout "$timeout_s" ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_TARGET" "$@"
}

# print the vm's SSH banner
ssh_port_banner() {
  python3 -c '
import socket, sys
port, tmo = int(sys.argv[1]), float(sys.argv[2])
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=tmo)
    s.settimeout(tmo)
    b = s.recv(256)
    s.close()
except Exception:
    sys.exit(1)
sys.stdout.write(b.decode("utf-8", "replace").strip())
sys.exit(0 if b.startswith(b"SSH-") else 1)
' "$SSH_PORT" "${1:-5}" 2>/dev/null
}

# print the stderr of a plain ssh call to the guest
ssh_vm_error() {
  timeout 10 ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_TARGET" true 2>&1 >/dev/null \
    | tr '\n' ' ' | cut -c1-300
}

# report a host-side ssh client fault
report_ssh_client_fault() {
  local banner
  banner=$(ssh_port_banner 5) || return 1
  [[ -n "$banner" ]] || return 1
  log "$1, but port $SSH_PORT answers \"$banner\" -- the host ssh client failed:"
  log "  ssh says: $(ssh_vm_error)"
  [[ -n "${RHIZO_SSH_CONTROL_DIR_NOTE:-}" ]] \
    && log "  ControlMaster directory fallbacks taken: $RHIZO_SSH_CONTROL_DIR_NOTE"
  return 0
}

# print a timestamped message to stderr
log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# give a comparator vm a 2G swapfile
provision_comparator_swap() {
  ssh_vm -t 300 '
    set -e
    if ! swapon --show=NAME --noheadings | grep -q .; then
      if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile
        chmod 0600 /swapfile
        mkswap /swapfile > /dev/null
      fi
      swapon /swapfile
    fi
    swapon --show=NAME --noheadings | grep -q .
  ' >/dev/null 2>&1
}

# check a pidfile names a pid that is not ours
_boot_refused_via() {
  local pid
  [[ -f "$1" ]] || return 1
  pid=$(cat "$1" 2>/dev/null)
  [[ -n "$pid" ]] && ! vm_pid_is_ours "$pid"
}

# wait for ssh_vm to answer
wait_for_ssh() {
  local deadline_s="${1:-180}"
  local start slept=0 client_fault=0
  start=$(date +%s)
  while true; do
    if ssh_vm -t 5 'echo ok' >/dev/null 2>&1; then
      log "SSH is up"
      return 0
    fi
    if (( slept )) && ssh_port_banner 3 >/dev/null; then
      if (( ++client_fault >= 3 )); then
        report_ssh_client_fault "SSH did not come up after $(( $(date +%s) - start ))s"
        return 1
      fi
    else
      client_fault=0
    fi
    if (( slept )) && _boot_refused_via "$VAR_DIR/vm-boot${SUFFIX}.pid"; then
      RHIZO_BOOT_REFUSAL="run-vm.sh exited before qemu started"
      log "the VM was never launched -- $(tail -3 "$VAR_DIR/vm-boot${SUFFIX}.log" 2>/dev/null | tr '\n' ' ')"
      return 1
    fi
    if (( slept )) && _boot_refused_via "$VM_PIDFILE"; then
      log "the VM was never launched -- $(tail -3 "$VAR_DIR/vm-boot${SUFFIX}.log" 2>/dev/null | tr '\n' ' ')"
      return 1
    fi
    if (( $(date +%s) - start > deadline_s )); then
      report_ssh_client_fault "SSH did not come up within ${deadline_s}s" || true
      log "SSH did not come up within ${deadline_s}s"
      return 1
    fi
    sleep 1
    slept=1
  done
}

# wait for this vm's launcher to start qemu
wait_for_boot_slot() { rig_await_launch "$@"; }


# succeed when a pid is this instance's launcher or qemu
vm_pid_is_ours() {
  local pid="$1" argv
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  argv=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
  [[ "$argv" == *"hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"* ]] && return 0
  [[ "$argv" == *run-vm.sh* ]] || return 1
  [[ "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" == "$(readlink -f "$VAR_DIR")" ]]
}

# print the pids listening on this instance's SSH port
ssh_port_holders() {
  command -v lsof >/dev/null 2>&1 || {
    log "lsof is not installed; cannot list what holds SSH port $SSH_PORT"
    return 2
  }
  lsof -t -i ":$SSH_PORT" -sTCP:LISTEN 2>/dev/null
  return 0
}

# refuse a rig boot or kill while RHIZO_TEST_INSTALLED=1 names a guest running the installed product
refuse_installed_guest() {
  [[ "${RHIZO_TEST_INSTALLED:-0}" == 1 ]] || return 0
  log "REFUSED: $1 under RHIZO_TEST_INSTALLED=1: vm $RHIZO_VM runs the installed package"
  return 1
}

# kill this instance's qemu and remove its sockets
kill_vm() {
  refuse_installed_guest kill_vm || return 2
  if (( RHIZO_VM_NAMED == 0 )); then
    rig_kill_guard || return 2
  fi
  log "killing instance $RHIZO_VM's VM"
  rm -f "$VAR_DIR/vm-boot${SUFFIX}.pid"
  local rc=0
  if [[ -f "$VM_PIDFILE" ]]; then
    local pid; pid=$(cat "$VM_PIDFILE" 2>/dev/null)
    if vm_pid_is_ours "$pid"; then
      if ! timeout 45 ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_TARGET" 'sync' >/dev/null 2>&1; then
        log "kill_vm: the guest's sync did not complete within 45s"
      fi
      kill -9 "$pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        log "WARNING: qemu pid $pid still alive after kill -9"
        rc=1
      else
        rm -f "$VM_PIDFILE"
      fi
    else
      log "removing leftover $VM_PIDFILE: pid '${pid:-none}' is not instance $RHIZO_VM's qemu"
      rm -f "$VM_PIDFILE"
    fi
  fi
  local holders p
  if ! holders=$(ssh_port_holders); then
    rc=1
  else
    for p in $holders; do
      log "WARNING: pid $p is bound to instance $RHIZO_VM's SSH port $SSH_PORT -- killing it directly"
      kill -9 "$p" 2>/dev/null || true
    done
    [[ -n "$holders" ]] && sleep 1
  fi
  timeout 8 ssh -o "ControlPath=$SSH_CONTROL_SOCK" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true
  rm -f "$SSH_CONTROL_SOCK" "$PROBE_SOCK"
  if [[ -f "$VAR_DIR/probe-fwd${SUFFIX}.pid" ]]; then
    kill -9 "$(cat "$VAR_DIR/probe-fwd${SUFFIX}.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$VAR_DIR/probe-fwd${SUFFIX}.pid"
  fi
  if (( rc != 0 )) && [[ -f "$VM_PIDFILE" ]]; then
    local left; left=$(cat "$VM_PIDFILE" 2>/dev/null)
    if [[ -z "$left" ]] || ! kill -0 "$left" 2>/dev/null; then
      rm -f "$VM_PIDFILE"
      rc=0
    fi
  fi
  local left_over
  if ! left_over=$(ssh_port_holders); then
    log "VM (instance $RHIZO_VM) teardown ran, but nothing can confirm SSH port $SSH_PORT is free"
    return 1
  fi
  if [[ -n "$left_over" ]]; then
    log "VM (instance $RHIZO_VM) teardown ran, but pid ${left_over//$'\n'/ } still holds SSH port $SSH_PORT"
    return 1
  fi
  if (( rc != 0 )); then
    log "VM (instance $RHIZO_VM) teardown ran, but a qemu process survived kill -9"
    return "$rc"
  fi
  log "VM (instance $RHIZO_VM) confirmed dead"
  return 0
}


# start run-vm.sh detached for this instance
boot_vm() {
  refuse_installed_guest boot_vm || return 2
  local boot_log="$VAR_DIR/vm-boot${SUFFIX}.log"
  if [[ -z "${RHIZO_KERNEL:-}" && "${RHIZO_BOOT:-direct}" == direct && -x "$_VM_COMMON_DIR/image/install-kernel.sh" ]]; then
    RHIZO_VM="$RHIZO_VM" RHIZO_GUEST_OS="${RHIZO_GUEST_OS:-ubuntu}" "$_VM_COMMON_DIR/image/install-kernel.sh" \
      || log "vm $RHIZO_VM's disk did not get the Rhizo kernel"
  fi
  if [[ -s "$boot_log" ]]; then mv -f "$boot_log" "${boot_log%.log}.prev.log"; fi
  # shellcheck disable=SC2034
  RHIZO_BOOT_REFUSAL=""
  rm -f "$VAR_DIR/vm-boot${SUFFIX}.pid"
  ( cd "$(dirname "${BASH_SOURCE[0]}")" && RHIZO_VM="$RHIZO_VM" RHIZO_BOOT="${RHIZO_BOOT:-direct}" RHIZO_GUEST_OS="${RHIZO_GUEST_OS:-}" setsid --fork "$_VM_COMMON_DIR/run-vm.sh" \
      > "$boot_log" 2>&1 < /dev/null & disown; exit 0 ) >/dev/null 2>&1 </dev/null
  log "VM launch requested for instance $RHIZO_VM (setsid --fork, log at $boot_log)"
}

RHIZO_INIT_SCAN_BODY='for d in "${RHIZO_PROC_ROOT:-/proc}"/[0-9]*; do case "$(tr "\0" " " 2>/dev/null < "$d/cmdline")" in *"init second_stage"*) ;; *) continue ;; esac; case "$(sed -n "s|^0::||p" "$d/cgroup" 2>/dev/null)" in /rhizo/*|/system.slice/androidd.service/android/*) echo "${d##*/}" ;; esac; done | sort -n'

# print all of the pids of instance 0's Android init
guest_init_pids() {
  ssh_vm -t "${1:-10}" "$RHIZO_INIT_SCAN_BODY" 2>/dev/null | tr -d '\r'
}

# print instance 0's Android init pid on the guest, or nothing
guest_init_pid() {
  guest_init_pids "${1:-10}" | head -1
}

# wait for init second_stage and print its pid
wait_for_init() {
  local deadline_s="${1:-120}"
  local start pid
  start=$(date +%s)
  while true; do
    pid=$(guest_init_pid 8)
    if [[ -n "$pid" ]]; then
      echo "$pid"
      return 0
    fi
    if (( $(date +%s) - start > deadline_s )); then
      log "init second_stage did not appear within ${deadline_s}s"
      return 1
    fi
    sleep 1
  done
}

# run a probe until it prints something
wait_for_nonempty() {
  local timeout_s="$1"; shift
  local start out
  start=$(date +%s)
  out=$("$@" 2>/dev/null)
  while [[ -z "$out" ]]; do
    (( $(date +%s) - start >= timeout_s )) && return 1
    sleep 1
    out=$("$@" 2>/dev/null)
  done
  local waited=$(( $(date +%s) - start ))
  (( waited > 0 )) && log "wait_for_nonempty: '$*' took ${waited}s to become ready"
  printf '%s' "$out"
  return 0
}

# print 1 when this run's boot_completed marker is in kmsg
boot_completed_marker() {
  ssh_vm -t 8 'dmesg | awk "/L3: START entry=/{s=NR} /RHIZO_MARKER sys.boot_completed=1 sandbox=0/{m=NR} END{if (s>0 && m>s) print 1}"' 2>/dev/null \
    | tr -d '\r\n '
}

# forward the sandbox's rhizo-probed socket over ssh
probe_up() {
  local deadline_s="${1:-60}"
  local probe_out
  if [[ -S "$PROBE_SOCK" ]]; then
    probe_out=$("$VAR_DIR/share/rhizo-probe-client" "$PROBE_SOCK" 3 'echo RHIZO_PROBE_READY' 2>/dev/null)
    grep -q RHIZO_PROBE_READY <<<"$probe_out" && return 0
  fi
  rm -f "$PROBE_SOCK"
  if ! timeout 20 ssh "${PROBE_FWD_OPTS[@]}" -o ExitOnForwardFailure=yes -p "$SSH_PORT" -f -N \
      -L "$PROBE_SOCK:$PROBE_REMOTE_SOCK" "$SSH_TARGET" 2>/dev/null; then
    log "probe_up: the probe-forward ssh failed or hung past 20s"
    return 1
  fi
  pgrep -f "L $PROBE_SOCK:$PROBE_REMOTE_SOCK" | head -1 > "$VAR_DIR/probe-fwd${SUFFIX}.pid" 2>/dev/null
  local start; start=$(date +%s)
  while (( $(date +%s) - start < deadline_s )); do
    if [[ -S "$PROBE_SOCK" ]]; then
      probe_out=$("$VAR_DIR/share/rhizo-probe-client" "$PROBE_SOCK" 3 'echo RHIZO_PROBE_READY' 2>/dev/null)
      grep -q RHIZO_PROBE_READY <<<"$probe_out" && return 0
    fi
    sleep 1
  done
  log "probe_up: rhizo-probed NOT reachable within ${deadline_s}s"
  return 1
}

# run a command in the sandbox through rhizo-probed
probe_cmd() {
  local timeout_s="$1"; shift
  local body="$*" nbytes
  nbytes=$(LC_ALL=C; echo "${#body}")
  if (( nbytes > 48000 )); then
    log "probe_cmd: body is $nbytes bytes, over the 48000 limit"
    return 96
  fi
  if [[ "$body" == *$'\n'* ]]; then
    body="s=\$(echo $(printf '%s' "$body" | base64 -w0) | base64 -d) && [ -n \"\$s\" ] || { echo RHIZO_PROBE_DECODE_FAILED; exit 95; }; sh -c \"\$s\""
  fi
  probe_up "$timeout_s" >/dev/null || return 97
  local out rc
  out=$("$VAR_DIR/share/rhizo-probe-client" "$PROBE_SOCK" "$timeout_s" "$body")
  rc=$?
  if [[ -z "$out" && "$rc" == 127 ]]; then
    log "probe_cmd: rhizo-probed's fork+exec was denied -- cannot observe: $*"
  fi
  printf '%s' "$out"
  return "$rc"
}

# run ssh_vm with stderr discarded
_ssh_vm_out() {
  local timeout_s="$1"; shift
  local out rc
  out=$(ssh_vm -t "$timeout_s" "$@" 2>/dev/null)
  rc=$?
  if (( rc == 124 )); then
    log "_ssh_vm_out: TIMED OUT after ${timeout_s}s (rc=124): $*"
  fi
  printf '%s' "$out"
  return "$rc"
}

# print a sandbox property
getprop_vm() {
  local init_pid="$1" prop="$2"
  local v rc
  v=$(_ssh_vm_out 8 "nsenter -a -t $init_pid -- /system/bin/getprop $prop" | tr -d '\r'); rc=$?
  if [[ -z "$v" && "$prop" == "sys.boot_completed" ]]; then
    v=$(boot_completed_marker)
  fi
  if [[ -z "$v" && "$prop" != "sys.boot_completed" ]]; then
    v=$(probe_cmd 8 "/system/bin/getprop $prop")
  fi
  printf '%s' "$v"
}

# print a property as Android holds it now
getprop_live() {
  local init_pid="$1" prop="$2"
  local v rc
  v=$(_ssh_vm_out 8 "nsenter -a -t $init_pid -- /system/bin/getprop $prop" | tr -d '\r\n')
  if [[ -n "$v" ]]; then
    printf '%s' "$v"
    return 0
  fi
  ssh_vm -t 8 "[ -d /proc/$init_pid ]" >/dev/null 2>&1 || return 96
  v=$(probe_cmd 30 "/system/bin/getprop $prop"); rc=$?
  v=$(printf '%s' "$v" | tr -d '\r\n')
  (( rc == 0 )) || return "$rc"
  [[ -n "$v" ]] || return 95
  printf '%s' "$v"
}

# print the lowest guest pid matching an argv[0] basename
_host_proc_pid_by_argv0() {
  local pids
  pids=$(ssh_vm -t 10 "for p in /proc/[0-9]*; do a0=\$(head -z -n1 \"\$p/cmdline\" 2>/dev/null | tr -d '\\0'); \
    [ \"\${a0##*/}\" = \"$1\" ] && basename \"\$p\"; done" 2>/dev/null)
  sort -n <<<"$pids" | head -1
}

# print system_server's root-namespace pid
system_server_pid() {
  local init_pid="$1"
  local pid out
  pid=$(_host_proc_pid_by_argv0 system_server)
  [[ -n "$pid" ]] && { printf '%s' "$pid"; return 0; }
  out=$(_ssh_vm_out 8 "nsenter -a -t $init_pid -- /system/bin/toybox ps -A -o PID,ARGS")
  [[ -z "$out" ]] && out=$(probe_cmd 8 "/system/bin/toybox ps -A -o PID,ARGS")
  local ns_pid
  ns_pid=$(awk '$2 ~ /system_server$/{print $1}' <<<"$out" | sort -n | head -1)
  [[ -n "$ns_pid" ]] || return 0
  _root_pid_for_ns_pid "$ns_pid"
}

# print the root-namespace pid of a sandbox pid
_root_pid_for_ns_pid() {
  local ns_pid="$1"
  [[ -n "$ns_pid" ]] || return 1
  ssh_vm -t 10 "awk -v want=$ns_pid '/^NSpid:/ { if (\$NF == want) { split(FILENAME, a, \"/\"); print a[3]; exit } }' /proc/[0-9]*/status 2>/dev/null" 2>/dev/null
}

# succeed when an earlier-seen pid is still alive
host_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  [[ "$(_ssh_vm_out 8 "[ -d /proc/$pid ] && echo ALIVE || echo GONE")" == *ALIVE* ]]
}

# print surfaceflinger's pid
surfaceflinger_pid() {
  local init_pid="$1"
  local pid out
  pid=$(_host_proc_pid_by_argv0 surfaceflinger)
  [[ -n "$pid" ]] && { printf '%s' "$pid"; return 0; }
  out=$(_ssh_vm_out 8 "nsenter -a -t $init_pid -- /system/bin/toybox ps -A -o PID,ARGS")
  [[ -z "$out" ]] && out=$(probe_cmd 8 "/system/bin/toybox ps -A -o PID,ARGS")
  printf '%s' "$out" | awk '$2 ~ /surfaceflinger$/{print $1}'
}

GUEST_MODE_READ='if [ -e /run/rhizo-selinux-mode ]; then m=$(cat /run/rhizo-selinux-mode 2>/dev/null) || m="<unreadable>"; [ -n "$m" ] || m="<empty>"; else m="<absent>"; fi'

# print the guest's recorded SELinux mode, host or namespace; anything else returns 1
guest_selinux_mode() {
  local out
  out=$(ssh_vm -t 10 "$GUEST_MODE_READ"'; echo "RHIZO_MODE=$m"' 2>/dev/null | tr -d '\r')
  out=$(sed -n 's/^RHIZO_MODE=//p' <<<"$out")
  case "$out" in
    host|namespace) printf '%s\n' "$out" ;;
    *) printf '<mode record /run/rhizo-selinux-mode reads %s>\n' "${out:-nothing: ssh did not answer}"; return 1 ;;
  esac
}

# print Android's enforce state from the record the guest's SELinux mode names
guest_android_enforce() {
  local out mode
  out=$(ssh_vm -t 10 "$GUEST_MODE_READ"'
case "$m" in
  namespace) f=/run/rhizo-selinuxns/android-enforce ;;
  host) f=/sys/fs/selinux/enforce ;;
  *) echo "RHIZO_MODE=$m"; exit 3 ;;
esac
echo "RHIZO_MODE=$m"; echo "RHIZO_ENFORCE=$(cat "$f" 2>&1)"' 2>/dev/null | tr -d '\r')
  mode=$(sed -n 's/^RHIZO_MODE=//p' <<<"$out")
  case "$mode" in
    host|namespace) printf '%s\n' "$(sed -n 's/^RHIZO_ENFORCE=//p' <<<"$out")" ;;
    "<absent>") printf '<no mode record /run/rhizo-selinux-mode: Android has not started this boot>\n'; return 2 ;;
    *) printf '<mode record /run/rhizo-selinux-mode reads %s>\n' "${mode:-nothing: ssh did not answer}"; return 1 ;;
  esac
}

# reboot the installed guest and wait for sys.boot_completed
installed_reboot() {
  local deadline_s="${1:-600}" before after t0 init="" bc=""
  before=$(ssh_vm -t 10 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]')
  [[ -n "$before" ]] || { log "installed_reboot: the guest did not answer before the reboot"; return 1; }
  ssh_vm -t 20 'sync; systemctl reboot' >/dev/null 2>&1
  timeout 8 ssh -o "ControlPath=$SSH_CONTROL_SOCK" -O exit "$SSH_TARGET" >/dev/null 2>&1
  t0=$(date +%s)
  while :; do
    sleep 5
    after=$(ssh_vm -t 8 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]')
    [[ -n "$after" && "$after" != "$before" ]] && break
    (( $(date +%s) - t0 < deadline_s )) || { log "installed_reboot: no new boot answered ssh within ${deadline_s}s"; return 1; }
  done
  log "installed_reboot: boot_id $before -> $after after $(( $(date +%s) - t0 ))s"
  while :; do
    init=$(guest_init_pid 8)
    if [[ -n "$init" ]]; then
      bc=$(getprop_live "$init" sys.boot_completed 2>/dev/null)
      [[ "$bc" == 1 ]] && break
    fi
    (( $(date +%s) - t0 < deadline_s )) \
      || { log "installed_reboot: no sys.boot_completed=1 within ${deadline_s}s of the reboot (init=${init:-none})"; return 1; }
    sleep 3
  done
  log "installed_reboot: Android (init $init) booted $(( $(date +%s) - t0 ))s after the reboot"
}

# succeed when the guest runs Android in namespace SELinux mode
guest_namespace_mode() { [[ "$(guest_selinux_mode 2>/dev/null)" == namespace ]]; }

# print the sandbox's logcat
logcat_vm() {
  local init_pid="$1"; shift
  local out rc args
  args=$(printf ' %q' "$@")
  if guest_namespace_mode; then
    probe_cmd "${LOGCAT_VM_TIMEOUT:-45}" "/system/bin/logcat$args"
    return
  fi
  out=$(_ssh_vm_out "${LOGCAT_VM_TIMEOUT:-45}" \
    "nsenter -a -t $init_pid -- /system/bin/toybox runcon u:r:shell:s0 /system/bin/logcat$args"); rc=$?
  if [[ -z "$out" ]] || (( rc == 124 )); then
    out=$(probe_cmd "${LOGCAT_VM_TIMEOUT:-45}" "/system/bin/logcat$args")
  fi
  printf '%s' "$out"
}

# print the guest's current time in logcat -t format
logcat_since_marker() {
  android_sh "$1" "date +'%m-%d %H:%M:%S.000'" 2>/dev/null | tr -d '\r' | tail -1
}

# run a command in the sandbox's shell domain
runcon_shell() {
  local init_pid="$1"; shift
  local out rc
  if guest_namespace_mode; then
    probe_cmd 30 "$*"
    return
  fi
  out=$(_ssh_vm_out 30 "nsenter -a -t $init_pid -- /system/bin/toybox runcon u:r:shell:s0 $*"); rc=$?
  { [[ -z "$out" ]] || (( rc == 124 )); } && out=$(probe_cmd 30 "$*")
  printf '%s' "$out"
}

# print qemu's status from its QMP socket
qmp_status() {
  local sock="$QMP_SOCK"
  [[ -S "$sock" ]] || { log "no QMP socket at $sock"; return 1; }
  { echo '{"execute":"qmp_capabilities"}'; echo '{"execute":"query-status"}'; sleep 0.3; } \
    | timeout 8 socat - "UNIX-CONNECT:$sock" 2>&1
}

# run a command line in the sandbox's shell domain with PATH set
android_sh() {
  local init_pid="$1"; shift
  if (( $# != 1 )); then
    echo "android_sh: takes <init pid> <one body>, got $# body argument(s): $* -- set ANDROID_SH_TIMEOUT for a timeout" >&2
    return 96
  fi
  local body="export PATH=/system/bin:/system/xbin:/vendor/bin; $*"
  local out
  local dead_marker="${TMPDIR:-/tmp}/rhizo-nsenter-dead.${RHIZO_VM:-0}.${init_pid}"
  local boot_id="" marked="" ns=0
  guest_namespace_mode && ns=1
  if (( ! ns )) && [[ -e "$dead_marker" ]]; then
    boot_id=$(ssh_vm -t 8 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]')
    read -r marked < "$dead_marker"
    [[ -n "$boot_id" && "$marked" == "$boot_id" ]] || rm -f "$dead_marker"
  fi
  if (( ! ns )) && [[ ! -e "$dead_marker" ]]; then
    out=$(ssh_vm -t "${ANDROID_SH_TIMEOUT:-30}" \
      "nsenter -a -t $init_pid -- /system/bin/toybox runcon u:r:shell:s0 /system/bin/sh -c '$body; echo RHIZO_SH_DONE=\$?'" 2>&1)
    if [[ "$out" == *RHIZO_SH_DONE=* ]]; then
      out="${out%RHIZO_SH_DONE=*}"
      printf '%s' "${out%$'\n'}"
      return 0
    fi
    [[ -n "$boot_id" ]] || boot_id=$(ssh_vm -t 8 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]')
    printf '%s\n' "$boot_id" > "$dead_marker" 2>/dev/null
    [[ -n "$out" ]] && log "android_sh: no completion trailer (nsenter/runcon channel marked dead for init_pid=$init_pid, using rhizo-probed): ${out%%$'\n'*}"
  fi
  out=$(probe_cmd "${ANDROID_SH_TIMEOUT:-30}" "$body")
  local rc=$?
  if (( rc >= 95 && rc <= 98 )); then
    if (( ns )); then
      log "android_sh: rhizo-probed did not run the body in namespace mode (rc=$rc) -- cannot observe: $*"
    else
      log "android_sh: nsenter unreachable AND rhizo-probed did not run the body (rc=$rc) -- cannot observe: $*"
    fi
    printf '%s' "$out"
    return "$rc"
  fi
  printf '%s' "$out"
}

# wait for dumpsys power to report Awake
wait_device_awake() {
  local init_pid="$1" timeout_s="${2:-15}" waited=0 awake=""
  while (( waited < timeout_s )); do
    awake=$(grep -m1 -o "mWakefulness=[A-Za-z]*" <<<"$(android_sh "$init_pid" "dumpsys power")")
    if [[ "$awake" == "mWakefulness=Awake" ]]; then
      printf '%s' "$awake"
      return 0
    fi
    sleep 1
    (( waited++ ))
  done
  printf '%s' "$awake"
  return 1
}

# wake the display and keep it on
android_stay_awake() {
  local init_pid="$1" prior
  android_sh "$init_pid" "input keyevent 224" >/dev/null
  android_sh "$init_pid" "svc power stayon true" >/dev/null
  prior=$(android_sh "$init_pid" "settings get system screen_off_timeout" | tr -d '\r\n')
  [[ "$prior" =~ ^[0-9]+$ ]] && printf '%s\n' "$prior" > "$(_stay_awake_saved "$init_pid")"
  android_sh "$init_pid" "settings put system screen_off_timeout 2147483647" >/dev/null
  local power
  power=$(android_sh "$init_pid" "dumpsys power")
  grep -m1 mWakefulness <<<"$power"
}
# print the file the prior screen_off_timeout is saved in
_stay_awake_saved() { echo "${TMPDIR:-/tmp}/rhizo-screen-off-timeout.${RHIZO_VM:-0}.$1"; }

# undo android_stay_awake
android_release_stay_awake() {
  local init_pid="$1" saved
  saved="$(_stay_awake_saved "$init_pid")"
  android_sh "$init_pid" "svc power stayon false" >/dev/null
  android_sh "$init_pid" "settings put global stay_on_while_plugged_in 0" >/dev/null
  if [[ ! -f "$saved" ]]; then
    log "android_release_stay_awake: no saved screen_off_timeout for init_pid=$init_pid -- screen_off_timeout stays 2147483647"
    return 1
  fi
  android_sh "$init_pid" "settings put system screen_off_timeout $(cat "$saved")" >/dev/null
  rm -f "$saved"
}

# write a line to the composer HAL's control FIFO
rhizo_ctl() {
  local init_pid="$1"; shift
  local rc
  ssh_vm -t 10 "nsenter -a -t $init_pid -- /system/bin/sh -c \"echo $* > /data/rhizo_control/control\""
  rc=$?
  if (( rc != 0 )); then
    log "rhizo_ctl: nsenter path returned rc=$rc for '$*', re-sending through rhizo-probed"
    probe_cmd 10 "echo $* > /data/rhizo_control/control" >/dev/null
    rc=$?
    (( rc == 97 || rc == 98 )) && log "rhizo_ctl: nsenter failed AND rhizo-probed unreachable for: $*"
  fi
  return "$rc"
}

# print the HAL's control replies so far
rhizo_ctl_out() {
  local out
  out=$(_ssh_vm_out 10 "nsenter -a -t $1 -- /system/bin/toybox cat /data/rhizo_control/control.out")
  [[ -z "$out" ]] && out=$(probe_cmd 10 "/system/bin/toybox cat /data/rhizo_control/control.out")
  printf '%s' "$out"
}

. "$REPO/src/androidd/host/parse-display-list.sh"

# print the display list reply from the HAL
rhizo_ctl_display_list() {
  local before out n deadline
  before=$(rhizo_ctl_out "$1" | grep -c '^display list')
  rhizo_ctl "$1" display list >/dev/null || return 1
  deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    out=$(rhizo_ctl_out "$1")
    n=$(grep -c '^display list' <<<"$out")
    (( n > before )) && { grep '^display list' <<<"$out" | tail -1; return 0; }
    sleep 0.5
  done
  return 1
}

# print the logical display id for a composer port
resolve_logical_id() {
  android_sh "$INIT" "dumpsys display" 2>/dev/null \
    | grep -o 'mViewports=.*' \
    | sed 's/DisplayViewport{/\n&/g' \
    | grep "physicalPort=$1," \
    | grep -o 'displayId=[0-9]*' \
    | head -1 \
    | cut -d= -f2
}
