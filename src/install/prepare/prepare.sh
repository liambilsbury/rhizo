#!/bin/bash
# prepare the host and run a setup boot
set -uo pipefail

PROG=rhizo-host-prepare
log() { echo "[$PROG] $*" >&2; }
# print the usage text
usage() {
  echo "usage: prepare.sh [--verify] [--sandbox-id N] [--show-paths] [--payload DIR] [--gsi TREE] [--release LABEL] [--variant user|userdebug] [--wipe-data] [--data-only] [--kernel-refresh] [--skip-setup-boot] [--keep-running]"
}
# print a refusal and exit 1
refuse() {
  local token="$1"; shift
  log "REFUSED: $*"; drop_failed_auto_request "$token"; echo "RHIZO_PREPARE_REFUSED reason=$token"; exit 1
}
# record and log a host change
mark_change() { ANY_CHANGE=1; log "  changed: $*"; }
# log a failure and exit 1
failstop() {
  local token="$1"; shift
  log "FAILED: $*"; [[ -z "${RESUME_FILE:-}" ]] || rm -f "$RESUME_FILE"; drop_failed_auto_request "$token"
  echo "RHIZO_PREPARE_FAILED reason=$token"; exit 1
}
AUTO_REQUEST=0
# rewrite the refusal record's outcome
write_rebuild_record() {
  local record="$PREPARED_ROOT/refusal" key="" reason=""
  if [[ -s "$record" ]]; then
    key=$(sed -n 's/^key=//p' "$record" | tail -1)
    reason=$(sed -n 's/^reason=//p' "$record" | tail -1)
  fi
  { mkdir -p "$PREPARED_ROOT" \
      && printf 'key=%s\nreason=%s\noutcome=%s\n%s\n' "$key" "$reason" "$1" "$2" > "$record.tmp" \
      && mv "$record.tmp" "$record"; } || log "could not record the rebuild's $1 ($2) in $record"
}
# drop a launcher-made request whose run ended unfinished
drop_failed_auto_request() {
  (( AUTO_REQUEST )) && [[ -e "$PREPARE_REQUEST" ]] || return 0
  write_rebuild_record rebuild-failed "failed=$1"
  if rm -f "$PREPARE_REQUEST"; then
    log "the rebuild the launcher requested ended unfinished ($1): its request is dropped, and rhizo status names it"
  else
    log "could not remove $PREPARE_REQUEST, so the next boot runs the failed rebuild ($1) again"
  fi
}
# drop a launcher request's run
on_prepare_exit() {
  local rc=$?
  if (( rc )); then drop_failed_auto_request "exit-$rc"
  else drop_failed_auto_request exit-0
  fi
}
# run a launcher request once
arm_auto_request() {
  AUTO_REQUEST=1
  trap on_prepare_exit EXIT
  trap 'exit 143' TERM
  if grep -q '^attempt=' "$PREPARE_REQUEST"; then
    refuse rebuild-killed "the last run of $PREPARE_REQUEST, begun" \
      "$(sed -n 's/^attempt=//p' "$PREPARE_REQUEST" | tail -1), was killed before it ended; it is not run again"
  fi
  printf 'attempt=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PREPARE_REQUEST" \
    || failstop "attempt-unrecorded" "cannot mark $PREPARE_REQUEST attempted"
}
# run a hostops.py operation in this unit's domain
hostops() { python3 "${RHIZO_HOSTOPS:-$PAYLOAD/hostops.py}" "$@"; }
# read the kernel log in this unit's domain
dmesg() { hostops dmesg; }

MODE=apply
PAYLOAD=/root
GSI=/srv/rhizo/gsi_system
GSI_EXPLICIT=0
RELEASE=current
VARIANT=user
WIPE_DATA=0
SKIP_SETUP_BOOT=0
KEEP_RUNNING=0
KEPT_RUNNING=0
PREPARED_ROOT="${RHIZO_PREPARED_ROOT:-/var/lib/rhizo/prepared}"
SANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) MODE=verify; shift ;;
    --data-only) MODE=data-only; WIPE_DATA=1; shift ;;
    --kernel-refresh) MODE=kernel-refresh; shift ;;
    --show-paths) MODE=show-paths; shift ;;
    --sandbox-id) SANDBOX_ID="${2:-}"; shift 2 ;;
    --payload) PAYLOAD="${2:-}"; shift 2 ;;
    --gsi) GSI="${2:-}"; GSI_EXPLICIT=1; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --wipe-data) WIPE_DATA=1; shift ;;
    --skip-setup-boot) SKIP_SETUP_BOOT=1; shift ;;
    --keep-running) KEEP_RUNNING=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[$PROG] FAIL: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

STATE_DIR="${RHIZO_STATE_DIR:-/var/lib/rhizo}"
PREPARE_REQUEST="${RHIZO_PREPARE_REQUEST:-$STATE_DIR/prepare-request}"
if [[ "$MODE" == apply && "$RELEASE" == current && -s "$PREPARE_REQUEST" ]] \
   && [[ "$(sed -n 's/^origin=//p' "$PREPARE_REQUEST" | tail -1)" == prepared-refused ]]; then
  arm_auto_request
fi

[[ "$SANDBOX_ID" =~ ^[0-9]+$ ]] && (( 10#$SANDBOX_ID <= 99 )) \
  || { echo "[$PROG] FAIL: --sandbox-id takes 0-99, got '$SANDBOX_ID'" >&2; exit 2; }
SANDBOX_ID=$(( 10#$SANDBOX_ID ))
export RHIZO_SANDBOX_ID="$SANDBOX_ID"
# set the per-instance paths for SANDBOX_ID
resolve_sandbox_paths() {
  if (( SANDBOX_ID == 0 )); then
    DATA_IMG="${RHIZO_DATA_IMG:-/var/lib/rhizo/data.img}"
    ANDROIDD_UNIT=androidd.service
    RUN_ROOT=/run/rhizo
    INIT_PID_FILE=/root/.rhizo_init_pid
    RESUME_FILE=/root/.rhizo_prepare_resume
  else
    DATA_IMG="${RHIZO_DATA_IMG:-/var/lib/rhizo/instances/$SANDBOX_ID/data.img}"
    ANDROIDD_UNIT="androidd@$SANDBOX_ID.service"
    RUN_ROOT="/run/rhizo-$SANDBOX_ID"
    INIT_PID_FILE="/root/.rhizo_init_pid-$SANDBOX_ID"
    RESUME_FILE="/root/.rhizo_prepare_resume-$SANDBOX_ID"
  fi
  PROBE_SOCK="$RUN_ROOT/data/local/tmp/rhizo-probe.sock"
}
resolve_sandbox_paths

# print the host policy's devices.dri
read_dri() {
  PYTHONPATH="$PAYLOAD" python3 -c '
from sandbox import capabilities as rc
policy, err = rc.read_policy()
print("Error: %s" % err if policy is None else policy.scope("devices.dri"))
'
}

# refuse a host where the gpu resolver chooses no render node
require_render_node() {
  local env_file node why
  local tail_why=("devices.dri is on, so the sandbox's graphics allocator opens the host's render node and no boot" \
    "completes without one: this host needs a GPU driver with a render node (a VM: a virtio-gpu device" \
    "with 3D enabled), or set [devices] dri = off in /etc/rhizo/policy.conf (or run rhizo gpu off) to" \
    "render in software")
  env_file=$(unit_env_file)
  if ! node=$(bash "$PAYLOAD/detect-gpu-driver.sh" --node --env-file "$env_file" 2>/dev/null); then
    why=$(bash "$PAYLOAD/detect-gpu-driver.sh" --node --env-file "$env_file" 2>&1 >/dev/null | tail -1)
    refuse "no-render-node" "${why#*detect-gpu-driver: } --" "${tail_why[@]}"
  fi
  node=${node%% *}
  [[ -c "$node" ]] || refuse "no-render-node" "no $node --" "${tail_why[@]}"
}

PROC_ROOT="${RHIZO_PROC_ROOT:-/proc}"
# print the pid of this instance's init
sandbox_init_alive() {
  local pid cmdline d cg root
  if [[ -e "$INIT_PID_FILE" ]]; then
    pid=$(cat "$INIT_PID_FILE" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    cmdline=$(tr '\0' ' ' 2>/dev/null < "$PROC_ROOT/$pid/cmdline")
    case "$cmdline" in *"init second_stage"*) printf '%s\n' "$pid" ;; esac
    return 0
  fi
  (( SANDBOX_ID == 0 )) || return 0
  local best=""
  for d in "$PROC_ROOT"/[0-9]*; do
    cmdline=$(tr '\0' ' ' 2>/dev/null < "$d/cmdline") || continue
    case "$cmdline" in *"init second_stage"*) ;; *) continue ;; esac
    cg=$(sed -n 's|^0::||p' "$d/cgroup" 2>/dev/null)
    for root in /rhizo /system.slice/androidd.service/android; do
      [[ "$cg" == "$root"/* ]] && { [[ -z "$best" ]] || (( ${d##*/} < best )); } && best=${d##*/}
    done
  done
  [[ -z "$best" ]] || printf '%s\n' "$best"
  return 0
}

if [[ "$MODE" == show-paths ]]; then
  echo "RHIZO_PREPARE_PATHS sandbox_id=$SANDBOX_ID data_img=$DATA_IMG unit=$ANDROIDD_UNIT run_root=$RUN_ROOT init_pid_file=$INIT_PID_FILE resume_file=$RESUME_FILE"
  exit 0
fi

if (( SANDBOX_ID != 0 && ! SKIP_SETUP_BOOT )); then
  refuse "instance-setup-boot" "--sandbox-id $SANDBOX_ID needs --skip-setup-boot"
fi

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR source=host-flavor.sh
. "$HERE/../lib/host-flavor.sh" || refuse "library-unreadable" "cannot read $HERE/../lib/host-flavor.sh"
why=$(host_state_subvolume_check) || refuse "root-snapshot-boot" "$why"
# shellcheck source-path=SCRIPTDIR source=kernel-changed.sh
. "$HERE/kernel-changed.sh" || refuse "library-unreadable" "cannot read $HERE/kernel-changed.sh"

# refuse a kernel that lacks what android needs
require_rhizo_kernel() {
  local lacks devices
  lacks=$(host_kernel_lacks) || refuse "not-rhizo-kernel" "$(host_kernel_refusal "$lacks")"
  devices=$(cat "$RHIZO_BINDER_DEVICES_FILE") \
    || failstop "binder-builtin-unreadable" "cannot read $RHIZO_BINDER_DEVICES_FILE"
  [[ "$devices" == "binder,hwbinder,vndbinder" ]] \
    || refuse "binder-builtin-devices" "this kernel's built-in binder creates devices '$devices' --" \
              "'rhizo install' writes binder.devices=binder,hwbinder,vndbinder to the kernel cmdline;" \
              "reboot once it has"
}
UPDATE_STATE="$STATE_DIR/update/state"
FETCH_GSI="${RHIZO_FETCH_GSI:-$HERE/fetch-gsi.sh}"
GSI_UPDATE="${RHIZO_GSI_UPDATE:-$HERE/../update/gsi-update.sh}"
FROM_REQUEST=0

# print the directory fetch-gsi.sh stages a release in
release_tree() {
  [[ "$1" =~ ^[a-z0-9-]+$ ]] || return 1
  case "$1" in
    a16) echo "${RHIZO_GSI_ROOT:-/srv/rhizo}/gsi_system" ;;
    *)   echo "${RHIZO_GSI_ROOT:-/srv/rhizo}/gsi_system_$1" ;;
  esac
}

RUNTIME_ENV="${RHIZO_RUNTIME_ENV:-/var/lib/rhizo/androidd-runtime.env}"

# print the EnvironmentFile the androidd unit reads
unit_env_file() {
  systemctl cat "$ANDROIDD_UNIT" 2>/dev/null | sed -n 's/^EnvironmentFile=-\?\(.*\)$/\1/p' | grep -vxF -e /var/lib/rhizo/host-mode-kept.env -e /var/lib/rhizo/androidd-runtime.env | tail -1
}

# print the selinux mode androidd.env configures
configured_selinux_mode() {
  "${RHIZO_SELINUX_MODE_HELPER:-/usr/lib/rhizo/rhizo-selinux-mode}" \
    --env-file "${RHIZO_ANDROIDD_ENV:-/etc/rhizo/androidd.env}" --configured
}

resolve_release() {
  local r v
  [[ "$RELEASE" == current ]] || return 0
  if [[ -s "$PREPARE_REQUEST" ]]; then
    FROM_REQUEST=1
    [[ "$(sed -n 's/^wipe_data=//p' "$PREPARE_REQUEST" | tail -1)" == 1 ]] && WIPE_DATA=1
    v=$(sed -n 's/^variant=//p' "$PREPARE_REQUEST" | tail -1)
    [[ -n "$v" ]] && VARIANT="$v"
    r=$(sed -n 's/^release=//p' "$PREPARE_REQUEST" | tail -1)
    [[ -n "$r" && "$r" != current ]] && { RELEASE="$r"; return 0; }
  fi
  local f files=()
  f=$(unit_env_file)
  [[ -z "$f" || ! -f "$f" ]] || files+=("$f")
  [[ ! -f "$RUNTIME_ENV" ]] || files+=("$RUNTIME_ENV")
  (( ${#files[@]} )) && r=$(sed -n 's/^RHIZO_RELEASE=//p' "${files[@]}" | tail -1)
  RELEASE="${r:-a16}"
}
resolve_release
if (( ! GSI_EXPLICIT )); then
  GSI=$(release_tree "$RELEASE") || refuse "unknown-release" "'$RELEASE' names no release"
fi
log "release $RELEASE, tree $GSI$( (( FROM_REQUEST )) && echo ", from $PREPARE_REQUEST")"

export RHIZO_GSI="$GSI" RHIZO_RELEASE="$RELEASE"

# print per-arch dexopt status classes with their counts
dexopt_status_summary() {
  grep -o 'status=[a-zA-Z_-]*' "$1" 2>/dev/null | sort | uniq -c | sort -rn \
    | awk '{printf "%s:%s,", substr($2, 8), $1}' | sed 's/,$//'
}

# check whether the sandbox bound its compositor socket
setup_boot_socket_state() {
  local out rc last
  # shellcheck disable=SC2016
  out=$(python3 "$1" "$2" 20 'p=/dev/socket/rhizo_wayland/wayland-0; if [ -S $p ]; then echo bound; elif [ -e $p ]; then echo not-a-socket; else echo absent; fi' 2>&1); rc=$?
  (( rc == 97 || rc == 98 )) && { echo unknown; return; }
  last=$(tail -1 <<<"$out" | tr -d '[:space:]')
  case "$last" in bound|not-a-socket|absent) echo "$last" ;; *) echo unknown ;; esac
}

# keep or stop the setup sandbox
keep_or_release_setup_boot() {
  local socket_state=""
  if (( KEEP_RUNNING )); then
    socket_state=$(setup_boot_socket_state "$1" "$2")
    log "setup boot socket: $socket_state ($(dmesg 2>/dev/null | awk '/RHIZO_MARKER launch_start sandbox=0/{l=""} /wayland socket (bind-mounted|NOT FOUND|bind mount FAILED)/{l=$0} END{print l}'))"
  fi
  if (( KEEP_RUNNING )) && [[ "$socket_state" == bound ]]; then
    log "leaving $ANDROIDD_UNIT running -- its setup boot bound a compositor socket"
    systemctl start --no-block "$ANDROIDD_UNIT" \
      || log "  WARNING: systemctl start --no-block $ANDROIDD_UNIT did not queue its Wants= units: rc=$?"
    sync; sync
    # shellcheck disable=SC2034
    KEPT_RUNNING=1
  else
    (( KEEP_RUNNING )) && log "releasing the setup boot: socket $socket_state"
    local stop_at
    stop_at=$(cut -d' ' -f1 /proc/uptime)
    log "stopping $ANDROIDD_UNIT"
    systemctl stop "$ANDROIDD_UNIT"
    if [[ -f "$INIT_PID_FILE" ]]; then
      local pid; pid=$(cat "$INIT_PID_FILE" 2>/dev/null)
      if [[ -n "$pid" ]]; then
        local sdeadline=$((SECONDS + 60))
        while [[ -d "/proc/$pid" ]] && (( SECONDS < sdeadline )); do sleep 1; done
        [[ -d "/proc/$pid" ]] && log "  WARNING: pid $pid from $INIT_PID_FILE is still present 60s after the stop"
      fi
    fi
    sync; sync
    if (( KEEP_RUNNING )); then
      local parked
      parked=$(dmesg 2>/dev/null | sed -E 's/^\[[[:space:]]*([0-9.]+)\][[:space:]]*/\1 /' \
        | awk -v t="$stop_at" '$1+0 > t+0 && /androidd-stop: supervisor (parked, stack is stopped|never parked within)/ {l=$0} END{print l}')
      case "$parked" in
        *"supervisor parked, stack is stopped"*) log "resident supervisor parked -- the next start hands off" ;;
        *) failstop "setup-boot-release-unparked" "$ANDROIDD_UNIT stopped but no parked supervisor was reported after uptime $stop_at (${parked:-no androidd-stop line})" ;;
      esac
    fi
  fi
}

# log whether this kernel carries what android needs
verify_kernel() {
  local lacks devices
  if ! lacks=$(host_kernel_lacks); then
    log "  kernel: $(host_kernel_refusal "$lacks")"; return 1
  fi
  devices=$(cat "$RHIZO_BINDER_DEVICES_FILE" 2>/dev/null)
  if [[ "$devices" != "binder,hwbinder,vndbinder" ]]; then
    log "  kernel: built-in binder creates devices '$devices', not binder,hwbinder,vndbinder"; return 1
  fi
  log "  kernel: built-in binder (devices=$devices), $RHIZO_ASHMEM_DEVICE and $RHIZO_PROC_CONFIG present"
}

# print the modules android's policy will not autoload
needed_modules() {
  local out
  out=$(python3 "$PAYLOAD/launcher3.py" needed-modules) || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# check modules-load.d/rhizo.conf for this kernel
verify_modules_load() {
  local names
  local -a want=()
  want=(uinput tun)
  local needed
  if ! needed=$(needed_modules); then
    log "  modules-load.d: $PAYLOAD/launcher3.py needed-modules failed or printed nothing"
    return 1
  fi
  mapfile -t -O "${#want[@]}" want <<<"$needed"
  local m named=0
  if [[ -s /etc/modules-load.d/rhizo.conf ]]; then
    named=1
    for m in "${want[@]}"; do grep -q "^$m\$" /etc/modules-load.d/rhizo.conf || { named=0; break; }; done
  fi
  if (( named )); then
    names=$(printf '%s, ' "${want[@]}")
    log "  modules-load.d: /etc/modules-load.d/rhizo.conf present and names ${names%, }"
    return 0
  fi
  names=$(IFS=/; echo "${want[*]}")
  log "  modules-load.d: /etc/modules-load.d/rhizo.conf missing or does not name $names"
  return 1
}

# check the sepolicy cache for the configured mode
verify_sepolicy() {
  local sp_out sp_cache sp_mode
  if [[ ! -f "$PAYLOAD/launcher3.py" ]]; then
    log "  sepolicy: cannot check -- $PAYLOAD/launcher3.py is missing"; return 1
  fi
  sp_mode=$(configured_selinux_mode) || { log "  sepolicy: cannot read the configured selinux mode"; return 1; }
  sp_out=$(RHIZO_SELINUX_MODE="$sp_mode" python3 "$PAYLOAD/launcher3.py" prepare-sepolicy --check 2>&1)
  sp_cache=$(sed -n 's/^PREPARE_SEPOLICY_\(OK\|CHECK\) cache=\([^ ]*\).*/\2/p' <<<"$sp_out" | tail -1)
  if [[ -z "$sp_cache" || ! -s "$sp_cache" ]]; then
    log "  sepolicy: no non-empty cache file for the current policy inputs (prepare-sepolicy --check: $sp_out)"
    return 1
  fi
  if [[ "$sp_out" == *" wakeup=changed"* ]]; then
    log "  sepolicy: cache for the prepared policy inputs is present ($sp_cache); this host's wakeup sources" \
        "changed since"
  else
    log "  sepolicy: cache for the current policy inputs is present ($sp_cache)"
  fi
}

# verify all of the prepared pieces read-only
run_verify() {
  local bad=0

  verify_kernel || bad=1

  verify_sepolicy || bad=1

  if [[ -L "$PREPARED_ROOT/current" ]]; then
    local tree_out
    tree_out=$(python3 "$HERE/verify-prepared-tree.py" "$PREPARED_ROOT")
    if grep -q '^OK ' <<<"$tree_out"; then
      log "  prepared tree: $tree_out"
    else
      log "  prepared tree: $tree_out"
      bad=1
    fi
  else
    log "  prepared tree: no $PREPARED_ROOT/current symlink"; bad=1
  fi

  if [[ -s "$DATA_IMG" ]]; then
    log "  data.img: present ($DATA_IMG)"
  else
    log "  data.img: missing or empty ($DATA_IMG)"; bad=1
  fi

  local tree_key tree_dir dexopt_ok=0
  tree_key=$(readlink "$PREPARED_ROOT/current" 2>/dev/null)
  if [[ -n "$tree_key" ]]; then
    tree_dir="$PREPARED_ROOT/$tree_key"
    if [[ -s "$tree_dir/dexopt-after.txt" && -f "$tree_dir/dexopt-data-identity.txt" ]]; then
      local recorded live_ino live_crtime
      recorded=$(cat "$tree_dir/dexopt-data-identity.txt" 2>/dev/null)
      live_ino=$(stat -c %i "$DATA_IMG" 2>/dev/null)
      live_crtime=$(stat -c %W "$DATA_IMG" 2>/dev/null)
      if [[ "$recorded" == "ino=$live_ino crtime=$live_crtime" ]]; then
        dexopt_ok=1
        log "  dexopt evidence: present, for this exact data.img (ino=$live_ino crtime=$live_crtime)"
      else
        log "  dexopt evidence: present but for a DIFFERENT data.img than the one on disk now ($recorded vs ino=$live_ino crtime=$live_crtime)"
      fi
    else
      log "  dexopt evidence: absent under $tree_dir"
    fi
  else
    log "  dexopt evidence: no prepared tree to check it against"
  fi
  (( dexopt_ok )) || bad=1

  verify_modules_load || bad=1

  return "$bad"
}

if [[ "$MODE" == verify ]]; then
  log "verifying prepared state (read-only)"
  if run_verify; then
    log "VERIFIED: kernel, sepolicy cache, prepared tree, data.img and dexopt evidence all agree with live state"
    echo "RHIZO_PREPARE_VERIFIED=1"
    exit 0
  fi
  failstop "verify-failed" "one or more checks above did not confirm a prepared state"
fi

if [[ "$MODE" == data-only ]]; then
  [[ $EUID -eq 0 ]] || refuse "not-root" "must run as root"
  meta="$DATA_IMG.meta"
  key=$(sed -n 's/^template=//p' "$meta" 2>/dev/null | head -1)
  if [[ -z "$key" ]]; then
    log "no template provenance for $DATA_IMG ($meta absent or carries no template= line) -- removing the image"
    rm -f "$DATA_IMG" "$meta"
    echo "RHIZO_PREPARE_DATA_ONLY=1 template=none action=removed-for-new-mkfs"
    exit 0
  fi
  template_img="/var/lib/rhizo/templates/data-template.$key.img"
  [[ -s "$template_img" ]] || refuse "no-template-artifact" \
    "$template_img is missing or empty -- run a full prepare"

  active=$(systemctl is-active "$ANDROIDD_UNIT" 2>/dev/null)
  [[ "$active" != active ]] || refuse "androidd-active" \
    "$ANDROIDD_UNIT is active -- stop it before replacing $DATA_IMG"
  sb_init=$(sandbox_init_alive)
  [[ -z "$sb_init" ]] || refuse "sandbox-alive" \
    "instance $SANDBOX_ID's Android init (pid $sb_init) is still running -- stop $ANDROIDD_UNIT and wait for it to exit first"

  if findmnt -rno TARGET,SOURCE 2>/dev/null | grep -q "$DATA_IMG"; then
    refuse "data-mounted" "$DATA_IMG is still mounted -- stop the sandbox and let its mounts go first"
  fi

  rm -f "$DATA_IMG"
  mkdir -p "$(dirname "$DATA_IMG")"
  cp --sparse=always "$template_img" "$DATA_IMG.template-part" \
    || failstop "instantiate-failed" "cp --sparse=always $template_img -> $DATA_IMG.template-part failed"
  mv "$DATA_IMG.template-part" "$DATA_IMG"
  printf 'release=%s\nvariant=%s\ntemplate=%s\nprovenance=instantiated\n' \
    "$RELEASE" "$VARIANT" "$key" > "$meta"
  log "data.img re-instantiated from template $key (data-only: no GSI read, enforcing is irrelevant here)"
  echo "RHIZO_PREPARE_DATA_ONLY=1 template=$key"
  exit 0
fi

# write modules-load.d/rhizo.conf
write_modules_load_conf() {
  local kver; kver=$(uname -r)
  local nf_dir="/lib/modules/$kver/kernel/net"
  local mods=() sub d f name
  for sub in netfilter ipv4/netfilter ipv6/netfilter xfrm key; do
    d="$nf_dir/$sub"
    [[ -d "$d" ]] || continue
    for f in "$d"/*.ko "$d"/*.ko.*; do
      [[ -e "$f" ]] || continue
      name=$(basename "$f")
      name="${name%%.ko*}"
      mods+=("$name")
    done
  done
  local needed
  needed=$(needed_modules) \
    || failstop "needed-modules-empty" "$PAYLOAD/launcher3.py needed-modules failed or printed nothing"
  mapfile -t -O "${#mods[@]}" mods <<<"$needed"
  mods+=(loop dm-mod dm-verity uinput tun)
  local sorted; sorted=$(printf '%s\n' "${mods[@]}" | sort -u)
  local conf=/etc/modules-load.d/rhizo.conf
  local want; want=$(cat <<HEADER
# Written by install/prepare/prepare.sh: modules Rhizo loads at boot
# kernel=$kver
$sorted
HEADER
)
  if [[ "$(cat "$conf" 2>/dev/null)" != "$want" ]]; then
    printf '%s\n' "$want" > "$conf"
    mark_change "modules-load.d set written"
    log "wrote $conf ($(printf '%s\n' "$sorted" | grep -c .) modules, kernel=$kver)"
  fi
}

if [[ "$MODE" == kernel-refresh ]]; then
  [[ $EUID -eq 0 ]] || refuse "not-root" "must run as root"
  kver=$(uname -r)
  if versions=$(payload_changed /var/lib/rhizo/.prepared "$PAYLOAD/VERSION"); then
    read -r marker_version payload_version <<<"$versions"
    rm -f /var/lib/rhizo/.prepared \
      || refuse "kernel-refresh-marker-rm-failed" "could not remove /var/lib/rhizo/.prepared, which names payload" \
           "$marker_version, not $payload_version"
    log "kernel-refresh: /var/lib/rhizo/.prepared names payload $marker_version and $PAYLOAD/VERSION" \
        "$payload_version: removed, so rhizo-prepare.service sets this payload up on this boot"
    echo "RHIZO_PREPARE_KERNEL_REFRESHED=1 kernel=$kver prepared=payload-changed"
    exit 0
  fi
  lacks=$(host_kernel_lacks) || refuse "not-rhizo-kernel" "$(host_kernel_refusal "$lacks")"
  write_modules_load_conf
  if [[ -z "$(ls -A /var/lib/rhizo/prepared 2>/dev/null)" ]]; then
    log "kernel-refresh: modules-load.d reads kernel=$kver; no prepared tree under /var/lib/rhizo/prepared, so the prepared marker is left for rhizo-prepare.service to write"
    echo "RHIZO_PREPARE_KERNEL_REFRESHED=1 kernel=$kver"
    exit 0
  fi
  if [[ -f "$PAYLOAD/launcher3.py" ]]; then
    rekey=$(python3 "$PAYLOAD/launcher3.py" prepared-rekey-kernel 2>&1 | tail -1)
  else
    rekey="PREPARED_REKEY_REFUSED reason=no-launcher:$PAYLOAD/launcher3.py"
  fi
  case "$rekey" in
    "PREPARED_REKEY result="*)
      tree=$(sed -E 's/^PREPARED_REKEY result=([a-z]+) .*/\1/' <<<"$rekey")
      log "kernel-refresh: prepared tree $tree for kernel=$kver (${rekey#PREPARED_REKEY })" ;;
    *)
      tree="refused:$(sed -n 's/^PREPARED_REKEY_REFUSED reason=//p' <<<"$rekey")"
      [[ "$tree" == refused: ]] && tree="refused:${rekey:-no-output}"
      log "kernel-refresh: the prepared tree stays refused on kernel=$kver ($tree); launches take the copy path and name the reason" ;;
  esac
  meta_version=""
  [[ -s /var/lib/rhizo/.prepared ]] && meta_version=$(sed -n 's/^version=//p' /var/lib/rhizo/.prepared | tail -1)
  printf 'kernel=%s\nversion=%s\n' "$kver" "$meta_version" > /var/lib/rhizo/.prepared
  log "kernel-refresh: modules-load.d and the prepared marker now both read kernel=$kver"
  echo "RHIZO_PREPARE_KERNEL_REFRESHED=1 kernel=$kver prepared=$tree"
  exit 0
fi

[[ $EUID -eq 0 ]] || refuse "not-root" "must run as root"
flavor=$(host_flavor) \
  || refuse "unsupported-host" "this host is ${flavor#unsupported:} -- Rhizo supports Ubuntu 24.04 and CachyOS"
arch="$(uname -m)"
[[ "$arch" == x86_64 || "$arch" == aarch64 ]] || refuse "not-supported-arch" "this host is $arch, neither x86_64 nor aarch64"

# refuse a selinux mode that cannot start android
check_selinux_for_setup() {
  local out mode why rc=0 lsm enforce env_file="${RHIZO_ANDROIDD_ENV:-/etc/rhizo/androidd.env}"
  local helper="${RHIZO_SELINUX_MODE_HELPER:-/usr/lib/rhizo/rhizo-selinux-mode}"
  out=$("$helper" --env-file "$env_file" --mode-and-why) || rc=$?
  (( rc == 0 )) || refuse "selinux-mode" "$helper exited $rc reading this boot's SELinux mode${out:+, printing '$out'}"
  IFS=$'\t' read -r mode why <<<"$out"
  case "$mode" in
    namespace) return 0 ;;
    host) ;;
    refuse:*) refuse "selinux-mode" "${why:-$helper named no reason} ($mode)" ;;
    *) refuse "selinux-mode" "$helper printed '$mode', not namespace, host or refuse:<reason>" ;;
  esac
  lsm=$(cat /sys/kernel/security/lsm 2>/dev/null || echo "")
  case ",$lsm," in
    *,selinux,*) : ;;
    *) refuse "selinux-not-active" "selinux is not an active LSM (got '$lsm') -- run install/bootstrap/bootstrap.sh and reboot first" ;;
  esac
  enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null || echo "")
  [[ "$enforce" == 0 ]] \
    || refuse "enforcing" "/sys/fs/selinux/enforce=$enforce -- this step runs only before Android's policy is loaded"
}
check_selinux_for_setup
DRI=$(read_dri)
[[ "$DRI" == Error:* ]] && refuse "host-policy-error" "${DRI#Error: } -- devices.dri cannot be read"
(( SKIP_SETUP_BOOT )) || [[ "$DRI" == False ]] || require_render_node

(( GSI_EXPLICIT )) && [[ ! -s "$GSI/bin/init" ]] \
  && refuse "no-gsi-tree" "no $GSI/bin/init -- stage a GSI tree first"
[[ -f "$PAYLOAD/launcher3.py" ]] || refuse "no-payload" "no $PAYLOAD/launcher3.py -- --payload must name the directory holding launcher3.py"

RESUME=0
active=$(systemctl is-active "$ANDROIDD_UNIT" 2>/dev/null)
if [[ "$active" == active && -f "$RESUME_FILE" ]]; then
  # shellcheck source=/dev/null
  . "$RESUME_FILE"
  RESUME=1
  log "resuming this run's own setup boot after the host primer's restart pass (tree $TREE_DIR)"
elif [[ "$active" != active ]]; then
  rm -f "$RESUME_FILE"
else
  systemctl status --no-pager -o short-monotonic -n 4 "$ANDROIDD_UNIT" 2>/dev/null | tail -n 4 | sed 's/^/  journal: /'
  systemctl show -p ActiveEnterTimestamp -p ExecMainStartTimestamp "$ANDROIDD_UNIT" 2>/dev/null | sed 's/^/  /'
  refuse "androidd-active" "$ANDROIDD_UNIT is active -- stop it first (systemctl stop $ANDROIDD_UNIT)"
fi
sb_init=$(sandbox_init_alive)
[[ -z "$sb_init" || "$RESUME" == 1 ]] || refuse "sandbox-alive" "instance $SANDBOX_ID's Android init (pid $sb_init) is still running -- stop $ANDROIDD_UNIT and wait for it to exit first"
if (( ! SKIP_SETUP_BOOT )); then
  unit_launcher=$(systemctl cat "$ANDROIDD_UNIT" 2>/dev/null | sed -n 's/^ExecStart=.*python3 \([^ ]*launcher3\.py\).*/\1/p' | tail -1)
  if [[ -z "$unit_launcher" ]]; then
    refuse "no-androidd-unit" "$ANDROIDD_UNIT names no launcher3.py in its ExecStart"
  fi
  if [[ "$unit_launcher" != "$PAYLOAD/launcher3.py" ]]; then
    refuse "payload-not-unit-launcher" "$ANDROIDD_UNIT execs $unit_launcher but this run prepares $PAYLOAD -- point --payload at $(dirname "$unit_launcher"), or pass --skip-setup-boot"
  fi
fi

# stage and derive the release
prepare_release_gates() {
  local out good trial
  if [[ -f "$GSI_UPDATE" ]]; then
    out=$(bash "$GSI_UPDATE" kernel-check --release "$RELEASE" 2>&1)
    [[ "$(tail -1 <<<"$out")" == *"reason=kernel-unsupported" ]] \
      && refuse "kernel-unsupported" "$(grep -v '^RHIZO_' <<<"$out" | tail -1)"
  fi
  if [[ -f "$UPDATE_STATE" ]]; then
    good=$(sed -n 's/^good_release=//p' "$UPDATE_STATE" | tail -1)
    trial=$(sed -n 's/^trial_release=//p' "$UPDATE_STATE" | tail -1)
    [[ -n "$trial" && "$good" != "$RELEASE" ]] \
      && refuse "trial-in-flight" "a rhizo gsi trial of $trial is armed on $good -- rhizo gsi abort before preparing $RELEASE"
  fi
  (( GSI_EXPLICIT )) && return 0
  [[ -f "$FETCH_GSI" ]] || refuse "no-fetch-gsi" "no $FETCH_GSI to stage $RELEASE's tree with"
  out=$(bash "$FETCH_GSI" --release "$RELEASE" 2>&1)
  case "$(tail -1 <<<"$out")" in
    RHIZO_GSI_OK*) STAGED_TREE=1 ;;
    RHIZO_GSI_ALREADY_STAGED=1) log "$GSI already staged; its libraries and stock patches derived" ;;
    *) failstop "gsi-stage" "$FETCH_GSI --release $RELEASE: $(tail -3 <<<"$out" | tr '\n' ' ')" ;;
  esac
  [[ -s "$GSI/bin/init" ]] || failstop "no-gsi-tree" "$FETCH_GSI reported $RELEASE staged and $GSI/bin/init is missing"
}
STAGED_TREE=0
(( RESUME )) || prepare_release_gates

# check the GSI's derived libraries
require_gsi_derived() {
  local out rc verdict
  out=$(python3 "$PAYLOAD/launcher3.py" gsi-derived-check 2>&1); rc=$?
  verdict=$(grep '^GSI_DERIVED_' <<<"$out" | tail -1)
  (( rc == 0 )) && [[ "$verdict" == GSI_DERIVED_OK* ]] && return 0
  [[ "$verdict" == GSI_DERIVED_MISMATCH* ]] && failstop "gsi-derived-mismatch" \
    "$verdict -- $PAYLOAD/install/prepare/fetch-gsi.sh --release <this release> --derive-only copies $GSI's own set"
  failstop "gsi-derived-missing" "${verdict:-launcher3.py gsi-derived-check printed no verdict, rc=$rc} -- $PAYLOAD/install/prepare/fetch-gsi.sh copies them out of $GSI"
}
(( RESUME )) || require_gsi_derived

if (( ! RESUME )); then
  ANY_CHANGE=0
  KEY=""
  SEPOLICY_CACHE=""
  TEMPLATE_KEY=""
  DATA_STATE=""
  DEXOPT_BEFORE=""
  DEXOPT_AFTER=""
  (( STAGED_TREE )) && mark_change "$RELEASE's tree staged at $GSI"
fi

(( RESUME )) || require_rhizo_kernel
(( RESUME )) || write_modules_load_conf

# compile the sepolicy cache
prepare_sepolicy() {
  local check_out cache_before mode
  mode=$(configured_selinux_mode) || failstop "selinux-mode" "cannot read the configured selinux mode"
  check_out=$(RHIZO_SELINUX_MODE="$mode" python3 "$PAYLOAD/launcher3.py" prepare-sepolicy --check 2>&1)
  cache_before=$(sed -n 's/^PREPARE_SEPOLICY_\(OK\|CHECK\) cache=\([^ ]*\).*/\2/p' <<<"$check_out" | tail -1)
  local already=0
  [[ -n "$cache_before" && -s "$cache_before" && "$check_out" != *" wakeup=changed"* ]] && already=1

  local out; out=$(RHIZO_INSTANCE='' RHIZO_SELINUX_MODE="$mode" python3 "$PAYLOAD/launcher3.py" prepare-sepolicy 2>&1)
  SEPOLICY_CACHE=$(sed -n 's/^PREPARE_SEPOLICY_OK cache=//p' <<<"$out" | tail -1)
  if [[ -z "$SEPOLICY_CACHE" ]]; then
    failstop "sepolicy-failed" "prepare-sepolicy did not report a cache path: $out"
  fi
  [[ -s "$SEPOLICY_CACHE" ]] || failstop "sepolicy-empty" "prepare-sepolicy reported cache=$SEPOLICY_CACHE but that file is empty or missing"
  if (( ! already )); then
    mark_change "sepolicy cache compiled"
    log "compiled sepolicy cache: $SEPOLICY_CACHE"
  else
    log "sepolicy cache already current: $SEPOLICY_CACHE"
  fi
}
(( RESUME )) || prepare_sepolicy

# remove prepared trees but current and the one kept
prune_prepared() {
  local keep_prev="$1" cur="" d name
  [[ -n "$keep_prev" ]] && keep_prev=$(basename -- "$keep_prev")
  [[ -L "$PREPARED_ROOT/current" ]] && cur=$(basename "$(readlink "$PREPARED_ROOT/current")")
  [[ -n "$cur" ]] || return 0
  if [[ -z "$keep_prev" || "$keep_prev" == "$cur" ]]; then
    keep_prev=""
    while IFS= read -r name; do
      [[ -L "$PREPARED_ROOT/$name" ]] && continue
      [[ -d "$PREPARED_ROOT/$name" ]] || continue
      [[ "$name" =~ ^[0-9a-f]{12}$ ]] || continue
      [[ "$name" == "$cur" ]] && continue
      keep_prev="$name"
      break
    done < <(ls -t "$PREPARED_ROOT" 2>/dev/null)
  fi
  for d in "$PREPARED_ROOT"/*; do
    [[ -L "$d" ]] && continue
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    [[ "$name" =~ ^[0-9a-f]{12}$ ]] || continue
    [[ "$name" == "$cur" || "$name" == "$keep_prev" ]] && continue
    rm -rf "$d" && log "  pruned old prepared tree $name"
  done
}
# build the prepared tree and prune older trees
prepare_tree() {
  local prev_key; prev_key=$(readlink "$PREPARED_ROOT/current" 2>/dev/null)
  local gpu_driver_flag=()
  local gpu_variant
  gpu_variant=$(bash "$PAYLOAD/detect-gpu-driver.sh" --env-file "$(unit_env_file)" 2>/tmp/rhizo-gpu-detect.log)
  if [[ "$gpu_variant" =~ ^(virgl|intel|amd)$ ]]; then
    log "render-node driver detection: $gpu_variant"
    if [[ "$gpu_variant" == virgl ]]; then
      :
    elif [[ -d "$PAYLOAD/gpu_driver_$gpu_variant/egl" && -d "$PAYLOAD/gpu_driver_$gpu_variant/lib" ]]; then
      gpu_driver_flag=(--gpu-driver "gpu_driver_$gpu_variant")
    else
      log "this payload carries no GL driver tree for $gpu_variant ($PAYLOAD/gpu_driver_$gpu_variant/egl) -- staging the default virgl driver"
    fi
  else
    log "render-node driver detection failed -- staging the default virgl driver ($(tail -1 /tmp/rhizo-gpu-detect.log 2>/dev/null))"
  fi
  [[ "$(read_dri)" == False ]] && gpu_driver_flag=()
  local mode; mode=$(configured_selinux_mode) || failstop "selinux-mode" "cannot read the configured selinux mode"
  local out; out=$(RHIZO_SELINUX_MODE="$mode" python3 "$PAYLOAD/launcher3.py" prepare-tree "$PREPARED_ROOT" "${gpu_driver_flag[@]}" 2>&1)
  local rc=$?
  KEY=$(sed -n 's/^PREPARE_TREE_OK key=\([0-9a-f]*\).*/\1/p' <<<"$out" | tail -1)
  if [[ $rc -ne 0 || -z "$KEY" ]]; then
    if grep -qx 'PREPARE_TREE_REFUSED reason=enforcing' <<<"$out"; then
      refuse "enforcing" "prepare-tree refused: $out"
    fi
    failstop "prepare-tree-failed" "prepare-tree did not report success: $out"
  fi
  log "prepared tree: $out"
  [[ "$KEY" != "$prev_key" ]] && mark_change "prepared tree key changed"
  prune_prepared "$prev_key"
}
(( RESUME )) || prepare_tree
TREE_DIR="$PREPARED_ROOT/$KEY"

# build the data template
prepare_template() {
  local tier; tier=$(python3 "$PAYLOAD/launcher3.py" data-tier 2>&1 | tail -1 | tr -d '[:space:]')
  case "$tier" in
    quota|plain) : ;;
    *) failstop "data-tier-failed" "data-tier printed '$tier', expected 'quota' or 'plain'" ;;
  esac

  local template="$PAYLOAD/data-template.sh"
  [[ -f "$template" ]] || failstop "no-data-template-script" "$template missing from the payload"

  local mode; mode=$(configured_selinux_mode) || failstop "selinux-mode" "cannot read the configured selinux mode"
  local out; out=$(RHIZO_SELINUX_MODE="$mode" bash "$template" --apex-dir "$GSI/apex" --format "$tier" --variant "$VARIANT" --seed none 2>&1)
  TEMPLATE_KEY=$(sed -n 's/^TEMPLATE_OK key=\([0-9a-f]*\).*/\1/p' <<<"$out" | tail -1)
  if [[ -z "$TEMPLATE_KEY" ]]; then
    if grep -q '^TEMPLATE_REFUSED' <<<"$out"; then
      refuse "template-refused" "$out"
    fi
    failstop "template-failed" "$out"
  fi
  if grep -q ' new=1' <<<"$out"; then
    mark_change "data template built"
    log "data template built: $out"
  else
    log "data template already current: $out"
  fi
}
(( RESUME )) || prepare_template

# copy the data template to data.img
instantiate_data() {
  local template_img="/var/lib/rhizo/templates/data-template.$TEMPLATE_KEY.img"
  local meta="$DATA_IMG.meta"
  if [[ -s "$DATA_IMG" && "$WIPE_DATA" == 0 ]]; then
    if [[ -s "$meta" ]]; then
      local meta_release meta_variant
      meta_release=$(sed -n 's/^release=//p' "$meta")
      meta_variant=$(sed -n 's/^variant=//p' "$meta")
      if [[ "$meta_release" != "$RELEASE" || "$meta_variant" != "$VARIANT" ]]; then
        refuse "data-release-mismatch" "$DATA_IMG was instantiated for release=$meta_release variant=$meta_variant, this run is release=$RELEASE variant=$VARIANT -- pass --wipe-data to replace it"
      fi
    else
      log "data.img has no $meta sidecar -- recording this run's release=$RELEASE variant=$VARIANT as assumed, not verified"
      printf 'release=%s\nvariant=%s\ntemplate=%s\nprovenance=assumed\n' "$RELEASE" "$VARIANT" "$TEMPLATE_KEY" > "$meta"
      mark_change "data.img.meta sidecar backfilled"
    fi
    DATA_STATE=kept
    log "data.img already exists and --wipe-data was not given -- keeping it"
    log "DATA_STATE=$DATA_STATE"
    return 0
  fi
  [[ -s "$template_img" ]] || failstop "no-template-artifact" "$template_img is missing or empty"
  if [[ -s "$DATA_IMG" && "$WIPE_DATA" == 1 ]]; then
    log "--wipe-data: removing the existing $DATA_IMG"
    rm -f "$DATA_IMG"
  fi
  mkdir -p "$(dirname "$DATA_IMG")"
  cp --sparse=always "$template_img" "$DATA_IMG.template-part" \
    || failstop "instantiate-failed" "cp --sparse=always $template_img -> $DATA_IMG.template-part failed"
  mv "$DATA_IMG.template-part" "$DATA_IMG"
  printf 'release=%s\nvariant=%s\ntemplate=%s\nprovenance=instantiated\n' "$RELEASE" "$VARIANT" "$TEMPLATE_KEY" > "$meta"
  DATA_STATE=instantiated
  mark_change "data.img instantiated from the template"
  log "data.img instantiated from template $TEMPLATE_KEY"
  log "DATA_STATE=$DATA_STATE"
}
(( RESUME )) || instantiate_data

# point the runtime and gsi state at the prepared release
point_at_release() {
  local out
  (( SANDBOX_ID == 0 )) || return 0
  mkdir -p "$(dirname "$RUNTIME_ENV")"
  { [[ ! -f "$RUNTIME_ENV" ]] || grep -Ev '^(RHIZO_GSI|RHIZO_RELEASE)=' "$RUNTIME_ENV" || [[ $? -eq 1 ]]
    printf 'RHIZO_GSI=%s\nRHIZO_RELEASE=%s\n' "$GSI" "$RELEASE"; } > "$RUNTIME_ENV.rhizo-prepare-release.tmp" \
    && mv "$RUNTIME_ENV.rhizo-prepare-release.tmp" "$RUNTIME_ENV" \
    || failstop "env-write" "could not point $RUNTIME_ENV at $RELEASE"
  log "sandbox pointed at release $RELEASE ($GSI) in $RUNTIME_ENV"
  [[ -f "$UPDATE_STATE" && -f "$GSI_UPDATE" ]] || return 0
  out=$(bash "$GSI_UPDATE" adopt --release "$RELEASE" 2>&1)
  [[ "$(tail -1 <<<"$out")" == "RHIZO_GSI_UPDATE current=$RELEASE "* ]] \
    || failstop "gsi-adopt" "rhizo gsi could not record $RELEASE as current: $(tail -2 <<<"$out" | tr '\n' ' ')"
}
(( RESUME )) || point_at_release

# print 1 when a later launch_start has a boot_completed
setup_boot_completed() {
  awk -v before="$1" '/RHIZO_MARKER launch_start sandbox=0/{n++; s=NR} /RHIZO_MARKER sys.boot_completed=1 sandbox=0/{m=NR} END{if (n>before && m>s) print 1}'
}

# run the setup boot and record dexopt
run_setup_boot() {
  local tree="$1"
  local ident_file="$tree/dexopt-data-identity.txt"
  local live_ino live_crtime
  live_ino=$(stat -c %i "$DATA_IMG" 2>/dev/null)
  live_crtime=$(stat -c %W "$DATA_IMG" 2>/dev/null)

  if (( ! RESUME )) && [[ -f "$ident_file" && -s "$tree/dexopt-after.txt" ]]; then
    if [[ "$(cat "$ident_file" 2>/dev/null)" == "ino=$live_ino crtime=$live_crtime" ]]; then
      log "dexopt evidence already exists for this exact data.img (ino=$live_ino crtime=$live_crtime) -- skipping the setup boot"
      DEXOPT_BEFORE=$(dexopt_status_summary "$tree/dexopt-before.txt")
      DEXOPT_AFTER=$(dexopt_status_summary "$tree/dexopt-after.txt")
      return 0
    fi
  fi

  if (( SKIP_SETUP_BOOT && ! RESUME )); then
    log "--skip-setup-boot: not running it -- dexopt evidence will be absent"
    DEXOPT_BEFORE=skipped
    DEXOPT_AFTER=skipped
    return 0
  fi

  if (( ! RESUME )); then
    mark_change "setup boot run"
    local boot_log
    boot_log=$(systemctl cat "$ANDROIDD_UNIT" 2>/dev/null | sed -n 's/^StandardOutput=append:\(.*\)$/\1/p' | tail -1)
    [[ -n "$boot_log" ]] || failstop "no-androidd-log" "$ANDROIDD_UNIT names no StandardOutput=append: path"
    mkdir -p "$(dirname "$boot_log")"
    mkdir -p "$(dirname "$RUNTIME_ENV")"
    if [[ -f "$RUNTIME_ENV" ]]; then
      grep -Ev '^(RHIZO_WIPE_DATA|RHIZO_RESIDENT_G|RHIZO_RESIDENT_DISPATCH)=' "$RUNTIME_ENV" > "$RUNTIME_ENV.rhizo-prepare.tmp" \
        || [[ $? -eq 1 ]] || failstop "env-write" "could not read $RUNTIME_ENV"
    else
      : > "$RUNTIME_ENV.rhizo-prepare.tmp"
    fi
    printf 'RHIZO_WIPE_DATA=0\nRHIZO_RESIDENT_G=1\nRHIZO_RESIDENT_DISPATCH=1\n' >> "$RUNTIME_ENV.rhizo-prepare.tmp"
    mv "$RUNTIME_ENV.rhizo-prepare.tmp" "$RUNTIME_ENV" || failstop "env-write" "could not write the setup boot knobs to $RUNTIME_ENV"
    : > "$boot_log"
    log "setup boot: env=$RUNTIME_ENV log=$boot_log"
    systemctl daemon-reload
    SETUP_STARTS_BEFORE=$(dmesg 2>/dev/null | grep -c 'RHIZO_MARKER launch_start sandbox=0')
    printf 'KEY=%q\nTREE_DIR=%q\nSEPOLICY_CACHE=%q\nTEMPLATE_KEY=%q\nDATA_STATE=%q\nSETUP_STARTS_BEFORE=%q\nANY_CHANGE=1\n' \
      "$KEY" "$tree" "$SEPOLICY_CACHE" "$TEMPLATE_KEY" "$DATA_STATE" "$SETUP_STARTS_BEFORE" > "$RESUME_FILE"
    if ! systemctl start --job-mode=ignore-dependencies "$ANDROIDD_UNIT"; then
      rm -f "$RESUME_FILE"
      failstop "setup-boot-start-failed" "systemctl start $ANDROIDD_UNIT failed -- see $boot_log"
    fi
  fi

  log "waiting for sys.boot_completed (bounded 300s), anchored on this run's own launch_start"
  local deadline=$((SECONDS + 300)) seen=0 completed
  while (( SECONDS < deadline )); do
    completed=$(dmesg 2>/dev/null | setup_boot_completed "${SETUP_STARTS_BEFORE:-0}")
    if [[ "$completed" == 1 ]]; then
      seen=1
      break
    fi
    sleep 3
  done
  (( seen )) || failstop "setup-boot-timeout" "sys.boot_completed never appeared within 300s of this run's own launch_start"
  log "boot_completed reached -- running dexopt through the probe socket"

  local sock="$PROBE_SOCK"
  local probe="$PAYLOAD/probe-client.py"
  [[ -f "$probe" ]] || failstop "no-probe-client" "$probe missing beside launcher3.py"
  local pdeadline=$((SECONDS + 60))
  while [[ ! -S "$sock" ]] && (( SECONDS < pdeadline )); do sleep 1; done
  [[ -S "$sock" ]] || failstop "probe-unreachable" "$sock never appeared within 60s of boot_completed"

  python3 "$probe" "$sock" 120 dumpsys package dexopt > "$tree/dexopt-before.txt" 2>&1
  local before_rc=$?
  (( before_rc == 97 || before_rc == 98 )) \
    && failstop "probe-before-unreachable" "dumpsys package dexopt (before) could not be run over the probe: exit $before_rc"

  log "cmd package compile -m speed-profile -a (bounded 1800s)"
  python3 "$probe" "$sock" 1800 cmd package compile -m speed-profile -a > "$tree/compile.log" 2>&1
  local compile_rc=$?
  (( compile_rc == 97 || compile_rc == 98 )) \
    && failstop "probe-compile-unreachable" "cmd package compile could not be run over the probe: exit $compile_rc"

  python3 "$probe" "$sock" 120 dumpsys package dexopt > "$tree/dexopt-after.txt" 2>&1
  local after_rc=$?
  (( after_rc == 97 || after_rc == 98 )) \
    && failstop "probe-after-unreachable" "dumpsys package dexopt (after) could not be run over the probe: exit $after_rc"

  DEXOPT_BEFORE=$(dexopt_status_summary "$tree/dexopt-before.txt")
  DEXOPT_AFTER=$(dexopt_status_summary "$tree/dexopt-after.txt")
  log "dexopt status entries: before=$DEXOPT_BEFORE after=$DEXOPT_AFTER"

  keep_or_release_setup_boot "$probe" "$sock"

  live_ino=$(stat -c %i "$DATA_IMG" 2>/dev/null)
  live_crtime=$(stat -c %W "$DATA_IMG" 2>/dev/null)
  echo "ino=$live_ino crtime=$live_crtime" > "$ident_file"
  rm -f "$RESUME_FILE"
}
run_setup_boot "$TREE_DIR"

log "verifying the state this run just produced"
if ! run_verify; then
  failstop "post-apply-verify-failed" "the state this run produced does not pass its own verification -- see the checks logged above"
fi
if (( FROM_REQUEST )); then
  rm -f "$PREPARE_REQUEST" || failstop "request-clear" "cannot remove $PREPARE_REQUEST"
  log "the prepare of $RELEASE deferred to this boot is done"
fi

if (( ANY_CHANGE == 0 )); then
  log "every step above was a no-op against live state -- nothing to prepare"
  echo "RHIZO_PREPARE_ALREADY_PREPARED=1"
  exit 0
fi

echo "RHIZO_PREPARE_OK key=$KEY tree=$TREE_DIR sepolicy=$SEPOLICY_CACHE template=$TEMPLATE_KEY data=$DATA_STATE dexopt=$DEXOPT_BEFORE/$DEXOPT_AFTER"
