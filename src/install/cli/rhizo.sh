#!/bin/bash
# run rhizo's install, status, app and device commands
set -uo pipefail

PROG=rhizo
log() { echo "[$PROG] $*" >&2; }
die() { echo "[$PROG] FAIL: $*" >&2; exit 1; }
app_fail() { echo "RHIZO_FAIL $*"; exit 1; }
# print the usage text
usage() {
  cat <<'EOF'
Usage: rhizo [-i <id>] <command> [options]
  -i <id>                  sandbox instance 0-99; default RHIZO_SANDBOX_ID, else 0
  -v | --version | version print the installed package version
  install [--profile desktop|server]
                           run bootstrap.sh and apply the profile
  profile [show|desktop|server]
                           print or set the profile (root)
  gpu [show|on|off]        print or set devices.dri; a change applies after a reboot (root)
  reset                    recreate data.img from the release template and boot Android
  shell -- <command...>    run a command inside the sandbox (root)
  adb-key add <file|->     register an adb public key in /etc/rhizo/adb_keys
  adb-key list             list the registered keys
  adb-key remove <fpr>     remove the key with that fingerprint
  prepare [options]        run prepare.sh, at the next boot on an enforcing host
  upgrade [options]        reinstall from the files on disk; setup runs at the next boot
  gsi <update|rollback|abort|status> [options]
                           run gsi-update.sh to change the Android release
  uninstall [--purge]      remove the rhizo packages; --purge also deletes data.img and /etc/rhizo
  status [--json|--adb]    print the sandbox, GSI, data and boot state
  doctor                   check this host for Rhizo's requirements
  start                    start androidd.service and wait for Android to boot
  stop                     stop androidd.service (root)
  launch <package> [arg]   open an app, with a URL or a shared file as <arg>
  app list                 list the installed packages
  app install <file.apk>   install an APK
  app remove <package>     uninstall a third-party package
  snapshot -i <id> <name>  save instance <id>'s data.img as a template (root)
  instance add <id> [--from <name>]
                           add instance <id>, from a snapshot with --from (root)
  instance remove <id> [--keep-data]
                           delete instance <id> and its data (root)
  instance allocate        unfreeze a pool member and print its adb endpoint (root)
  pool set <K>             keep K booted, frozen instances (root)
  pool reconcile           resize the pool to its K (root)
  device set battery <pct> <charging|discharging>
  device set thermal <celsius>
  device set gps <lat> <lon> [alt]
  device set sensor <accel|gyro|light> <values...>
  device set camera <image>
                           set a reading in /var/lib/rhizo/device-state; sensor and camera need devices.virtual

A non-root call goes through /run/rhizo-broker/broker.sock (group rhizo).

Environment:
  RHIZO_LIB_DIR            payload directory (default /usr/lib/rhizo)
  RHIZO_DATA_IMG           data image (default /var/lib/rhizo/data.img)
  RHIZO_STATE_DIR          state directory (default /var/lib/rhizo)
  RHIZO_SANDBOX_ID         default instance (default 0)
  RHIZO_DEVICE_STATE_DIR   device-state directory under RHIZO_STATE_DIR
  RHIZO_ASSUME_YES=1       skip the uninstall --purge confirmation
  RHIZO_ETC_DIR, RHIZO_VAR_CACHE, RHIZO_VAR_LOG, RHIZO_SYSTEMD_ETC_DIR, RHIZO_GSI_ROOT,
  RHIZO_RUN_MOUNT, RHIZO_INIT_PID_BASE, RHIZO_SELINUX_ENFORCE, RHIZO_SELINUX_MODE_FILE,
  RHIZO_CLI_TEST_NO_ROOT=1 test overrides

Output lines:
  RHIZO_STATUS running=<0|1> unit=<state> data=<present|absent>
    setup=<done|pending|pending-reboot|refused|helper-failed>
  RHIZO_STATUS --json: one JSON object (profile, unit, boot_completed, adb, release, prepared, setup, adb_keys)
  RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=<enforcing|setup-at-boot|rhizo-kernel>
  RHIZO_DOCTOR_OK warnings=<n>
  RHIZO_DOCTOR_ISSUES issues=<n> warnings=<n>
  RHIZO_PROFILE profile=<desktop|server>
  RHIZO_GPU dri=<on|off> driver=<gpu_driver|gpu_driver_software> [loaded=<on|off>]
  RHIZO_GPU_REBOOT_REQUIRED=1 dri=<on|off> loaded=<on|off|unknown>
  RHIZO_RESET ok
  RHIZO_ADBKEY added=<n> | list=<n> | removed=<n>
  RHIZO_SANDBOX starting=1
  RHIZO_LAUNCHED pkg=<p> display=<n> cdisplay=<n>
  RHIZO_APP list=<n>
  RHIZO_APP installed=<pkg> label=<base64>
  RHIZO_APP removed=<pkg>
  RHIZO_FAIL <reason>
EOF
}

SELF="${BASH_SOURCE[0]}"
LIB_DIR="${RHIZO_LIB_DIR:-/usr/lib/rhizo}"
VERSION_FILE="$LIB_DIR/VERSION"
rhizo_version() { [[ -r "$VERSION_FILE" ]] && tr -d '[:space:]' < "$VERSION_FILE" || printf unknown; echo; }
INSTALL_DIR="$LIB_DIR/install"
TOOLS_DIR="$LIB_DIR/tools"
BROKER_CLIENT="$LIB_DIR/broker/broker-client.py"
PROBE_CLIENT="$LIB_DIR/probe-client.py"
INBOX_SANDBOX_DIR=/data/rhizo_inbox
INBOX_LABEL="u:object_r:rhizo_inbox_file:s0"
DEVICE_STATE_LABEL="u:object_r:rhizo_device_state_file:s0"
ENTRY_DIR=/usr/share/applications
STATE_DIR="${RHIZO_STATE_DIR:-/var/lib/rhizo}"
PREPARED_ROOT="$STATE_DIR/prepared"
TEMPLATES_ROOT="$STATE_DIR/templates"
INSTALL_RECORD="$STATE_DIR/.created-by-install"
VAR_CACHE="${RHIZO_VAR_CACHE:-/var/cache/rhizo}"
VAR_LOG="${RHIZO_VAR_LOG:-/var/log/rhizo}"
ETC_RHIZO="${RHIZO_ETC_DIR:-/etc/rhizo}"
INSTANCES_ENV_DIR="$ETC_RHIZO/instances"
POOL_CONF="$ETC_RHIZO/pool.conf"
POOL_MEMBERS="$STATE_DIR/pool-members"
POOL_PENDING="$STATE_DIR/pool-pending"
POOL_LOCK_FILE="$STATE_DIR/pool.lock"
POOL_INSTANCE_FLOOR_BYTES=$(( 5265 * 1024 * 1024 / 10 ))
SYSTEMD_ETC_DIR="${RHIZO_SYSTEMD_ETC_DIR:-/etc/systemd/system}"
GSI_ROOT="${RHIZO_GSI_ROOT:-/srv/rhizo}"
RUN_MOUNT="${RHIZO_RUN_MOUNT:-/run}"
INIT_PID_BASE="${RHIZO_INIT_PID_BASE:-/root/.rhizo_init_pid}"
PROC_ROOT="${RHIZO_PROC_ROOT:-/proc}"
INSTANCE0_STACK_CGROUPS=(/rhizo /system.slice/androidd.service/android)
PREPARED_MARKER="$STATE_DIR/.prepared"
INSTALL_FAILED="$ETC_RHIZO/install-failed"
CONFIGURE_PENDING="$STATE_DIR/.configure-pending"
PACMAN_DB_LOCK="${RHIZO_PACMAN_DB_LOCK:-/var/lib/pacman/db.lck}"
PREPARE_REQUEST="$STATE_DIR/prepare-request"
HOST_LABELS_PENDING="$STATE_DIR/.host-labels-pending"
HOST_MODE_KEPT="$STATE_DIR/host-mode-kept.env"
SELINUX_CONFIG="${RHIZO_SELINUX_CONFIG:-/etc/selinux/config}"
REBOOT_REQUIRED_FILE="$RUN_MOUNT/reboot-required"
SELINUX_ENFORCE_FILE="${RHIZO_SELINUX_ENFORCE:-/sys/fs/selinux/enforce}"
SELINUX_MODE_FILE="${RHIZO_SELINUX_MODE_FILE:-$RUN_MOUNT/rhizo-selinux-mode}"
POLICY_REFUSED_FILE=/run/rhizo-policy-refused
PROC_NET_UNIX="${RHIZO_PROC_NET_UNIX:-/proc/net/unix}"
PROC_MOUNTINFO=/proc/self/mountinfo
PROC_SWAPS=/proc/swaps
GPU_RESOLVER="$LIB_DIR/detect-gpu-driver.sh"
[[ -r "$GPU_RESOLVER" ]] || GPU_RESOLVER="$(dirname "$SELF")/detect-gpu-driver.sh"
KERNEL_MODULES_ROOT=/lib/modules
POLICY_CONF="$ETC_RHIZO/policy.conf"
POLICY_MODE_FILE="$RUN_MOUNT/rhizo-policy-mode"
ADB_KEYS_FILE="$ETC_RHIZO/adb_keys"
SERVER_MASKED_UNITS=(rhizo-display-pool.path rhizo-display-pool.service rhizo-display-pool-release.service
                      rhizo-app-events.service rhizo-resync.path rhizo-resync.service
                      rhizo-resync-rearm.service rhizo-remove-entries.path rhizo-remove-entries.service
                      rhizo-desktop-attach.path rhizo-desktop-attach.service
                      rhizo-session-start.path rhizo-session-start.service
                      rhizo-hostfs.service
                      rhizo-deskd.service rhizo-desk-token.service rhizo-audiod.service
                      rhizo-displayd.service rhizo-keymapd.service)
SERVER_MASKED_USER_UNITS=(rhizo-desktop-session.path rhizo-desktop-session.service
                          rhizo-desk-notify.path rhizo-desk-notify.service)
DESKTOP_USER_PATH_UNITS=(rhizo-desktop-session.path rhizo-desk-notify.path)
DESKTOP_UID=1000
DESK_BRIDGE_CAPABILITIES="desktop.clipboard desktop.notifications desktop.drag desktop.open_uri"
DESKTOP_ATTACH_UNIT=rhizo-desktop-attach.path
DESKTOP_SESSION_ENV=${RHIZO_DESKTOP_SESSION_ENV:-/run/rhizo-desktop/session.env}
DESKTOP_SESSION_ENV_WAIT_S=${RHIZO_DESKTOP_SESSION_ENV_WAIT_S:-15}
SERVER_IDLE_UNIT=rhizo-server-idle.service
SERVER_API_UNIT=rhizo-api.socket

# succeed for root or an offline test
cli_root_ok() {
  [[ $EUID -eq 0 ]] && return 0
  [[ "${RHIZO_CLI_TEST_NO_ROOT:-0}" == 1 ]] || return 1
  [[ "$ETC_RHIZO" != /etc/rhizo && "$STATE_DIR" != /var/lib/rhizo ]]
}

# source host-flavor.sh and bootloader.sh
load_host_libs() {
  local lib dir
  for lib in lib/host-flavor.sh bootstrap/bootloader.sh; do
    dir="$INSTALL_DIR"
    [[ -r "$dir/$lib" ]] || dir=$(dirname "$SELF")/..
    # shellcheck source=/dev/null
    . "$dir/$lib" || die "cannot read $lib in $INSTALL_DIR or beside $SELF"
  done
}

# print an instance id in base 10
canon_id() {
  echo $((10#$1))
}
# print the state dir of an instance
instance_dir() {
  local id; id=$(canon_id "$1")
  (( id == 0 )) && return 0
  echo "$STATE_DIR/instances/$id"
}
# print an instance's data.img path
instance_data_img() {
  local id dir; id=$(canon_id "$1"); dir=$(instance_dir "$id")
  if [[ -z "$dir" ]]; then echo "$STATE_DIR/data.img"; else echo "$dir/data.img"; fi
}
# print an instance's androidd unit name
instance_unit() {
  local id; id=$(canon_id "$1")
  if (( id == 0 )); then echo "androidd.service"; else echo "androidd@$id.service"; fi
}
# print an instance's runtime tree root
instance_run_root() {
  local id root
  id=$(canon_id "$1")
  root="$RUN_MOUNT/rhizo"
  (( id == 0 )) || root="$RUN_MOUNT/rhizo-$id"
  printf '%s\n' "$root"
}
# print an instance's SELinux namespace records dir
instance_records_dir() {
  local id root
  id=$(canon_id "$1")
  root="$RUN_MOUNT/rhizo-selinuxns"
  (( id == 0 )) || root="$RUN_MOUNT/rhizo-selinuxns-$id"
  printf '%s\n' "$root"
}
# print an instance's probe socket path
instance_probe_sock() {
  printf '%s/data/local/tmp/rhizo-probe.sock\n' "$(instance_run_root "$1")"
}
# print the recorded or configured SELinux mode
selinux_mode() {
  local m=""
  if [[ -e "$SELINUX_MODE_FILE" ]]; then
    m=$(cat "$SELINUX_MODE_FILE") || { log "cannot read $SELINUX_MODE_FILE"; return 1; }
  fi
  [[ -n "$m" ]] || m=$(configured_selinux_mode) || return 1
  case "$m" in
    host|namespace) printf '%s\n' "$m" ;;
    *) log "the SELinux mode reads '$m', not host or namespace"; return 1 ;;
  esac
}
# check the SELinux mode against a mode
selinux_mode_is() {
  local m
  m=$(selinux_mode) || die "cannot read the SELinux mode (see above)"
  [[ "$m" == "$1" ]]
}
# print the boot's SELinux mode for labeling
label_write_mode() {
  local m
  m=$(cat "$SELINUX_MODE_FILE") && [[ "$m" == host || "$m" == namespace ]] \
    || { log "cannot read the SELinux mode from $SELINUX_MODE_FILE"; return 1; }
  printf '%s\n' "$m"
}
# check for a host-loaded SELinux policy
host_policy_loaded() {
  local attr="${RHIZO_ATTR_CURRENT:-/proc/self/attr/current}" ctx
  [[ -e "$attr" ]] || return 1
  if ! ctx=$(LC_ALL=C tr -d '\0' < "$attr" 2>&1); then
    [[ "$ctx" == *"Invalid argument"* ]] && return 1
    log "cannot read $attr: $ctx"
    return 2
  fi
  [[ "$ctx" == *:* ]]
}
# write the selinux label of a host-created file
label_android_file() {
  local m got
  m=$(label_write_mode) || return 1
  [[ "$m" == namespace ]] || return 0
  host_policy_loaded
  case $? in
    0)
      got=$(/usr/bin/python3 "${RHIZO_LAUNCHER:-$LIB_DIR/launcher3.py}" in-android-policy label "$1" "$2") \
        || { log "in-android-policy could not label $1 $2: ${got:-no output}"; return 1; }
      [[ "${got##*$'\n'}" == "$2" ]] || { log "$1 reads ${got##*$'\n'} after labeling it $2"; return 1; }
      return 0 ;;
    1) ;;
    *) return 1 ;;
  esac
  /usr/bin/python3 -c '
import os, sys
path, want = sys.argv[1], sys.argv[2]
try:
    os.setxattr(path, "security.selinux", want.encode() + b"\0", follow_symlinks=False)
    got = os.getxattr(path, "security.selinux", follow_symlinks=False).rstrip(b"\0").decode(errors="replace")
except OSError as e:
    sys.exit(f"cannot write security.selinux on {path}: {e}")
if got != want:
    sys.exit(f"{path} reads {got} after labeling it {want}")
' "$1" "$2"
}
# print the configured SELinux mode
configured_selinux_mode() {
  local helper="${RHIZO_SELINUX_MODE_HELPER:-$LIB_DIR/rhizo-selinux-mode}" m
  if ! m=$("$helper" --env-file "$ETC_RHIZO/androidd.env" --configured); then
    log "cannot read the configured SELinux mode from $helper"
    return 1
  fi
  case "$m" in
    host|namespace) printf '%s\n' "$m" ;;
    *) log "$helper --configured printed '$m', not host or namespace"; return 1 ;;
  esac
}
# check for host-mode install marks
host_mode_install_found() {
  local kind own m
  grep -qxE 'pacman-downloaduser|login-defs-tty|host-mode-links' "$INSTALL_RECORD" 2>/dev/null && return 0
  if [[ -e "$SELINUX_MODE_FILE" ]]; then
    if m=$(cat "$SELINUX_MODE_FILE"); then
      [[ "$m" == host ]] && return 0
    else
      log "cannot read $SELINUX_MODE_FILE; looking for host mode's other marks"
    fi
  fi
  kind=$(bootloader_kind 2>/dev/null) || return 1
  own=$(bootloader_own_tokens "$kind" 2>/dev/null) || return 1
  grep -qxE 'enforcing=0|security=selinux|lsm=.*' <<<"$own"
}
# undo the host-wide edits of a host-mode install
leave_host_mode() {
  local lib="$INSTALL_DIR/lib/pkg-lib.sh" was_host=0
  [[ -r "$lib" ]] || die "no $lib"
  if host_mode_install_found; then
    was_host=1
    log "switching this host from host mode to SELinux namespace mode, in effect after a reboot;" \
        "set RHIZO_SELINUX_MODE=host in $ETC_RHIZO/androidd.env and run 'rhizo install' to stay in host mode"
  fi
  # shellcheck source=pkg-lib.sh
  if ! ( export RHIZO_INSTALL_RECORD="$INSTALL_RECORD"; . "$lib" && pkg_leave_host_mode ); then
    log "kept the host-mode edit named above and its token in $INSTALL_RECORD"
  fi
  systemctl daemon-reload || die "systemctl daemon-reload failed after the host-mode drop-ins were removed"
  (( was_host )) && record_host_labels_pending
  rm -f "$HOST_MODE_KEPT" || log "could not remove $HOST_MODE_KEPT"
  return 0
}
# print the host's boot SELinux policy config
host_policy_config() {
  local mode type
  [[ -e "$SELINUX_CONFIG" ]] || return 1
  [[ -r "$SELINUX_CONFIG" ]] || { echo "an unreadable $SELINUX_CONFIG"; return 0; }
  mode=$(sed -n 's/^[[:space:]]*SELINUX=[[:space:]]*\([A-Za-z]*\).*/\1/p' "$SELINUX_CONFIG" | tail -1)
  type=$(sed -n 's/^[[:space:]]*SELINUXTYPE=[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$SELINUX_CONFIG" | tail -1)
  case "$mode" in
    enforcing|permissive) [[ -n "$type" ]] || return 1 ;;
    *) return 1 ;;
  esac
  if ! compgen -G "${SELINUX_CONFIG%/*}/$type/policy/policy.*" > /dev/null; then
    log "no ${SELINUX_CONFIG%/*}/$type/policy/policy.* for SELINUXTYPE=$type in $SELINUX_CONFIG:" \
        "the next boot removes host mode's labels from host files"
    return 1
  fi
  echo "SELINUX=$mode SELINUXTYPE=$type in $SELINUX_CONFIG"
}
# scan host files for host mode labels
host_policy_meets_labels() {
  local teardown="$INSTALL_DIR/teardown/teardown.sh"
  LABEL_SCAN=""
  LABEL_CONFIG=$(host_policy_config) || return 1
  LABEL_SCAN=$(bash "$teardown" --list-host-labels)
  [[ "$(tail -1 <<<"$LABEL_SCAN")" != "RHIZO_TEARDOWN_HOST_LABELS labeled=0" ]]
}
# refuse a start mid host-mode switch
refuse_start_mid_switch() {
  [[ -e "$HOST_MODE_KEPT" ]] || return 0
  host_policy_meets_labels && return 0
  app_fail "host mode is kept and no host file has host mode's label: run 'sudo rhizo install' to switch" \
           "to namespace mode"
}
# drop the kept host mode record
release_kept_host_mode() {
  [[ -e "$HOST_MODE_KEPT" ]] || return 1
  host_policy_meets_labels && return 1
  rm -f "$HOST_MODE_KEPT" || die "could not remove $HOST_MODE_KEPT"
  log "no host file has host mode's label: removed $HOST_MODE_KEPT"
}
# keep host mode under a host SELinux policy
keep_host_mode_for_host_policy() {
  local files cmd steps sentence teardown="$INSTALL_DIR/teardown/teardown.sh"
  host_mode_install_found || return 1
  host_policy_meets_labels || return 1
  case "$(tail -1 <<<"$LABEL_SCAN")" in
    "RHIZO_TEARDOWN_HOST_LABELS labeled=1")
      files=$(sed -n 's/^files: //p' <<<"$LABEL_SCAN")
      cmd="'$(sed -n 's/^command: //p' <<<"$LABEL_SCAN")'" ;;
    *)
      files="the host files host mode labeled (the label scan printed '${LABEL_SCAN:-nothing}')"
      cmd="restorecon on the files 'sudo bash $teardown --list-host-labels' lists" ;;
  esac
  steps="1. reboot; 2. run 'sudo rhizo stop' and keep Android stopped; 3. run $cmd; 4. run 'sudo rhizo install'"
  sentence="this host loads its own SELinux policy ($LABEL_CONFIG) and host mode's label is on $files."
  sentence+=" To switch to namespace mode: $steps"
  if ! { printf '# %s\nRHIZO_SELINUX_MODE=host\n' "$sentence" > "$HOST_MODE_KEPT.new" \
         && mv "$HOST_MODE_KEPT.new" "$HOST_MODE_KEPT"; }; then
    log "could not write $HOST_MODE_KEPT: write 'RHIZO_SELINUX_MODE=host' to it as root"
    export RHIZO_SELINUX_MODE=host
  fi
  log "$sentence"
  return 0
}
# apply host mode's host files and edits
enter_host_mode() {
  local lib="$INSTALL_DIR/lib/pkg-lib.sh"
  [[ -r "$lib" ]] || die "no $lib"
  # shellcheck source=pkg-lib.sh
  ( export RHIZO_INSTALL_RECORD="$INSTALL_RECORD"; . "$lib" && pkg_enter_host_mode ) \
    || die "could not apply host mode's pacman.conf, login.defs or file links (see above)"
  systemctl daemon-reload || die "systemctl daemon-reload failed after the host-mode drop-ins were linked"
  drop_host_labels_pending
}
# drop a pending removal of host mode's labels
drop_host_labels_pending() {
  [[ -e "$HOST_LABELS_PENDING" ]] || return 0
  rm -f "$HOST_LABELS_PENDING" \
    || die "could not remove $HOST_LABELS_PENDING"
  log "host mode labels stay on host files: removed $HOST_LABELS_PENDING"
}
# record the pending removal of host mode's labels
record_host_labels_pending() {
  [[ -e "$HOST_LABELS_PENDING" ]] && return 0
  if ! echo pending > "$HOST_LABELS_PENDING"; then
    log "could not write $HOST_LABELS_PENDING: write 'pending' to it as root to remove host mode's labels at the" \
        "next boot"
    return 0
  fi
  log "the next boot removes host mode's SELinux labels from host files (rhizo-host-labels.service)"
}
# print Android's enforce state for an instance
android_enforce_state() {
  local m
  m=$(selinux_mode) || return 2
  if [[ "$m" == namespace ]]; then
    cat "$(instance_records_dir "${1:-$RHIZO_SANDBOX_ID}")/android-enforce" 2>/dev/null
  else
    cat "$SELINUX_ENFORCE_FILE" 2>/dev/null
  fi
  return 0
}
# print an instance's SELinux namespace verdict
selinuxns_verdict() {
  local m
  m=$(selinux_mode) || return 2
  [[ "$m" == namespace ]] || return 0
  cat "$(instance_records_dir "${1:-$RHIZO_SANDBOX_ID}")/selinuxns-verdict" 2>/dev/null
  return 0
}
# print the verdict this start wrote
start_verdict() {
  local m want dir verdict
  m=$(selinux_mode) || return 2
  [[ "$m" == namespace ]] || return 0
  want=$(systemctl show -p InvocationID --value "$1" 2>/dev/null)
  [[ -n "$want" ]] || return 0
  dir=$(instance_records_dir "${2:-$RHIZO_SANDBOX_ID}")
  [[ "$(cat "$dir/start-id" 2>/dev/null)" == "$want" ]] || return 0
  verdict=$(cat "$dir/selinuxns-verdict" 2>/dev/null)
  [[ "$(cat "$dir/start-id" 2>/dev/null)" == "$want" ]] || return 0
  printf '%s\n' "$verdict"
}
# print an instance's init pid file path
instance_init_pid_file() {
  local id base="$INIT_PID_BASE"
  id=$(canon_id "$1")
  if (( id == 0 )); then printf '%s\n' "$base"; else printf '%s-%s\n' "$base" "$id"; fi
}
# print an instance's boot log path
instance_boot_log() {
  local id; id=$(canon_id "$1")
  if (( id == 0 )); then printf '%s/boot.log\n' "$VAR_LOG"; else printf '%s/boot-%s.log\n' "$VAR_LOG" "$id"; fi
}

# refuse an id outside 0-99
validate_sandbox_id() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 <= 99 )) \
    || die "RHIZO_SANDBOX_ID=$1 refused: NET_SUBNET below needs a single id 0-99, two free octet digits and no sign"
}

# set all of the per-instance paths for an id
set_instance_vars() {
  local id run_mount="$RUN_MOUNT"
  validate_sandbox_id "$1"
  id=$(canon_id "$1")
  export RHIZO_SANDBOX_ID="$id"
  INIT_PID_FILE=$(instance_init_pid_file "$id")
  RUN_ROOT=$(instance_run_root "$id")
  if (( id == 0 )); then
    LAUNCH_LOG="$run_mount/rhizo-launch/rhizo-launch.log"
    DEVICE_DIR="${RHIZO_DEVICE_STATE_DIR:-$STATE_DIR/device-state}"
  else
    LAUNCH_LOG="$run_mount/rhizo-launch-$id/rhizo-launch.log"
    DEVICE_DIR="${RHIZO_DEVICE_STATE_DIR:-$STATE_DIR/device-state-$id}"
  fi
  PROBE_SOCK=$(instance_probe_sock "$id")
  LIVE_ADB_KEYS="$RUN_ROOT/data/misc/adb/adb_keys"
  INBOX_HOST_DIR="$RUN_ROOT/data/rhizo_inbox"
  DATA_IMG="${RHIZO_DATA_IMG:-$(instance_data_img "$id")}"
}
set_instance_vars "${RHIZO_SANDBOX_ID:-0}"

# print an instance's live init pid
sandbox_init_pid() {
  local id="${1:-$RHIZO_SANDBOX_ID}" pidfile="$INIT_PID_FILE" pid cmdline
  (( $# >= 1 )) && pidfile=$(instance_init_pid_file "$id")
  if [[ -e "$pidfile" ]]; then
    pid=$(cat "$pidfile" 2>/dev/null)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    cmdline=$(tr '\0' ' ' 2>/dev/null < "$PROC_ROOT/$pid/cmdline")
    case "$cmdline" in *"init second_stage"*) printf '%s\n' "$pid" ;; esac
    return 0
  fi
  (( $(canon_id "$id") == 0 )) || return 0
  local d cg root best=""
  for d in "$PROC_ROOT"/[0-9]*; do
    cmdline=$(tr '\0' ' ' 2>/dev/null < "$d/cmdline") || continue
    case "$cmdline" in *"init second_stage"*) ;; *) continue ;; esac
    cg=$(sed -n 's|^0::||p' "$d/cgroup" 2>/dev/null)
    for root in "${INSTANCE0_STACK_CGROUPS[@]}"; do
      [[ "$cg" == "$root"/* ]] && { [[ -z "$best" ]] || (( ${d##*/} < best )); } && best=${d##*/}
    done
  done
  [[ -z "$best" ]] || printf '%s\n' "$best"
  return 0
}

TAKE_DASH_I_VALUE=""
TAKE_DASH_I_ARGS=()
# split the first -i <id> from the args
take_dash_i() {
  TAKE_DASH_I_VALUE=""
  TAKE_DASH_I_ARGS=()
  local found=0
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-i" && $found -eq 0 ]]; then
      [[ $# -ge 2 ]] || die "-i needs an instance id"
      TAKE_DASH_I_VALUE="$2"
      found=1
      shift 2
      continue
    fi
    TAKE_DASH_I_ARGS+=("$1")
    shift
  done
}

GLOBAL_INSTANCE_ID=""
RESOLVED_ARGS=()
# set the instance paths from -i
resolve_instance_selector() {
  take_dash_i "$@"
  RESOLVED_ARGS=("${TAKE_DASH_I_ARGS[@]}")
  local id="${TAKE_DASH_I_VALUE:-$GLOBAL_INSTANCE_ID}"
  [[ -n "$id" ]] && set_instance_vars "$id"
}

# check the args for a read-only flag
is_readonly_arg() {
  local a
  for a in "$@"; do
    case "$a" in --verify|--show|-h|--help) return 0 ;; esac
  done
  return 1
}

# append a token to the install record
record_install_token() {
  mkdir -p "$(dirname "$INSTALL_RECORD")" || die "cannot create $(dirname "$INSTALL_RECORD")"
  grep -qx "$1" "$INSTALL_RECORD" 2>/dev/null && return 0
  echo "$1" >> "$INSTALL_RECORD" || die "cannot record $1 in $INSTALL_RECORD"
}
# find or create the uid 1000 account
resolve_uid1000() {
  local name had_group=1
  name=$(getent passwd 1000 2>/dev/null | cut -d: -f1)
  if [[ -z "$name" ]]; then
    log "uid 1000 is free: creating the system account rhizo-appwatch"
    getent group rhizo-appwatch >/dev/null 2>&1 || had_group=0
    if [[ "$(host_flavor)" == cachyos ]]; then
      host_sys_account_add rhizo-appwatch 1000 || die "useradd of rhizo-appwatch at uid 1000 failed"
      [[ "$(getent passwd 1000 2>/dev/null | cut -d: -f1)" == rhizo-appwatch ]] \
        || die "rhizo-appwatch exists at a uid other than 1000: remove or rename it, then run 'rhizo install'"
    else
      adduser --uid 1000 --system --no-create-home --group rhizo-appwatch \
        || die "adduser --uid 1000 --system --no-create-home --group rhizo-appwatch failed"
    fi
    name=rhizo-appwatch
    record_install_token user:rhizo-appwatch
    (( had_group )) || record_install_token group:rhizo-appwatch
  elif [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "$name" ]]; then
    die "uid 1000 is '$name', not '$SUDO_USER': resolve the uid collision, then run 'rhizo install'"
  else
    log "using uid 1000 '$name' for desktop integration"
  fi
  mkdir -p "$ETC_RHIZO" || die "cannot create $ETC_RHIZO"
  if [[ ! -f "$ETC_RHIZO/desktop-user" ]]; then
    echo "$name" > "$ETC_RHIZO/desktop-user" || die "cannot write $ETC_RHIZO/desktop-user"
    log "recorded uid 1000's account as '$name' in $ETC_RHIZO/desktop-user"
  elif [[ "$(cat "$ETC_RHIZO/desktop-user")" != "$name" ]]; then
    log "uid 1000 is '$name', not '$(cat "$ETC_RHIZO/desktop-user")': rewriting $ETC_RHIZO/desktop-user"
    echo "$name" > "$ETC_RHIZO/desktop-user" || die "cannot write $ETC_RHIZO/desktop-user"
  fi
}

# create group rhizo and add the desktop user
ensure_broker_group() {
  local owner had_group=1
  owner=$(cat "$ETC_RHIZO/desktop-user" 2>/dev/null)
  [[ -n "$owner" ]] || die "no $ETC_RHIZO/desktop-user"
  getent group rhizo >/dev/null || had_group=0
  groupadd -f rhizo || die "groupadd -f rhizo failed"
  if (( had_group == 0 )); then
    mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
    echo "group:rhizo" >> "$INSTALL_RECORD" || die "cannot record group:rhizo in $INSTALL_RECORD"
  fi
  usermod -aG rhizo "$owner" || die "usermod -aG rhizo $owner failed"
  log "added '$owner' to group rhizo"
}

# register rhizo as the .apk handler
seed_apk_handler() {
  [[ -r "$TOOLS_DIR/appsync.py" ]] \
    || die "no $TOOLS_DIR/appsync.py"
  /usr/bin/python3 "$TOOLS_DIR/appsync.py" --mimeapps-only \
    || die "appsync.py --mimeapps-only failed"
}

# print a capability's value through capabilities
read_capability() {
  local out rc
  out=$(PYTHONPATH="$LIB_DIR" /usr/bin/python3 -c '
import sys
from sandbox import capabilities as rc
print(rc.policy_or_deny(log=lambda m: print(m, file=sys.stderr)).scope(sys.argv[1]))
' "$1"); rc=$?
  (( rc == 0 )) || return 1
  printf '%s\n' "$out"
}

# print the host policy's devices.dri
read_dri() {
  PYTHONPATH="$LIB_DIR" /usr/bin/python3 -c '
from sandbox import capabilities as rc
policy, err = rc.read_policy()
print("Error: %s" % err if policy is None else policy.scope("devices.dri"))
'
}

# print a policy.conf parse error
policy_parse_error() {
  PYTHONPATH="$LIB_DIR" /usr/bin/python3 -c '
import sys
from sandbox import capabilities as rc
_, err = rc.read_policy(sys.argv[1])
print(err or "")
' "$1"
}

# set a key in a policy.conf section
write_policy_key() {
  local section="$1" key="$2" value="$3" tmp err
  err=$(policy_parse_error "$POLICY_CONF") || die "could not run the policy parser on $POLICY_CONF"
  [[ -z "$err" ]] || die "$err: fix $POLICY_CONF, then set $section.$key again"
  mkdir -p "$ETC_RHIZO" || die "cannot create $ETC_RHIZO"
  [[ -f "$POLICY_CONF" ]] || : > "$POLICY_CONF"
  tmp=$(mktemp "$POLICY_CONF.XXXXXX") || die "cannot create a temp file beside $POLICY_CONF"
  awk -v section="[$section]" -v key="$key" -v value="$value" '
    /^\[/ {
      if (in_section && !wrote) { print key " = " value; wrote = 1 }
      header = $0
      sub(/[ \t]+$/, "", header)
      in_section = (header == section)
      if (in_section) seen = 1
      print
      next
    }
    {
      if (in_section && tolower($0) ~ ("^" key "[ \t]*[=:]")) { print key " = " value; wrote = 1; next }
      print
    }
    END {
      if (in_section && !wrote) print key " = " value
      if (!seen) printf "[%s]\n%s = %s\n", substr(section, 2, length(section) - 2), key, value
    }
  ' "$POLICY_CONF" > "$tmp" || { rm -f "$tmp"; die "could not rewrite $POLICY_CONF"; }
  err=$(policy_parse_error "$tmp") || { rm -f "$tmp"; die "could not run the policy parser on the rewrite of $POLICY_CONF"; }
  [[ -z "$err" ]] || { rm -f "$tmp"; die "setting $section.$key makes $POLICY_CONF unparseable: $err"; }
  mv "$tmp" "$POLICY_CONF" || die "could not replace $POLICY_CONF"
  chmod 0644 "$POLICY_CONF"
}

# set the [rhizo] profile key
write_profile_key() {
  local value="$1" err
  err=$(policy_parse_error "$POLICY_CONF") || die "could not run the policy parser on $POLICY_CONF"
  if [[ -n "$err" ]]; then
    [[ "$value" == desktop ]] || die "profile $value refused: $err: fix it, then set the profile again"
    log "$err: applying desktop to the units only"
    return 0
  fi
  write_policy_key rhizo profile "$value"
}

# remove regular files at unit override paths
clear_leftover_mask_targets() {
  local u
  for u in "$@"; do
    [[ -f "$SYSTEMD_ETC_DIR/$u" && ! -L "$SYSTEMD_ETC_DIR/$u" ]] \
      && rm -f "$SYSTEMD_ETC_DIR/$u"
  done
}

# enable or disable the control API socket
set_api_socket() {
  if ! systemctl cat "$SERVER_API_UNIT" >/dev/null 2>&1; then
    log "warning: $SERVER_API_UNIT is not installed"
    return 0
  fi
  if [[ "$1" == enable ]]; then
    systemctl enable --now "$SERVER_API_UNIT" || die "systemctl enable --now $SERVER_API_UNIT failed"
  else
    systemctl disable --now "$SERVER_API_UNIT" || die "systemctl disable --now $SERVER_API_UNIT failed"
  fi
}

# run systemctl --user as the desktop user
desktop_user_systemctl() {
  [[ "$(systemctl is-active "user@$DESKTOP_UID.service" 2>/dev/null)" == active ]] || return 0
  local owner
  owner=$(getent passwd "$DESKTOP_UID" 2>/dev/null | cut -d: -f1)
  [[ -n "$owner" ]] || { log "user@$DESKTOP_UID.service is running with no account at uid $DESKTOP_UID"; return 1; }
  runuser -u "$owner" -- env XDG_RUNTIME_DIR="/run/user/$DESKTOP_UID" systemctl --user "$@"
}

# start the desktop-only units after an unmask
start_desktop_units() {
  local u wants watch=() daemons=() waited=0
  case "$(systemctl is-active androidd.service 2>/dev/null)" in active | activating) ;; *) return 0 ;; esac
  wants=" $(systemctl show -p Wants --value androidd.service 2>/dev/null | tr '\n' ' ') "
  for u in "${SERVER_MASKED_UNITS[@]}"; do
    [[ "$u" == "$DESKTOP_ATTACH_UNIT" ]] && continue
    if [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == enabled ]]; then watch+=("$u")
    elif [[ "$wants" == *" $u "* ]]; then daemons+=("$u"); fi
  done
  (( ${#watch[@]} == 0 )) || systemctl start "${watch[@]}" || return 1
  until [[ -e "$DESKTOP_SESSION_ENV" ]]; do
    (( waited < DESKTOP_SESSION_ENV_WAIT_S * 5 )) || { echo "no desktop session within ${DESKTOP_SESSION_ENV_WAIT_S}s ($DESKTOP_SESSION_ENV absent): $DESKTOP_ATTACH_UNIT starts the daemons when it arrives"; return 0; }
    sleep 0.2; waited=$((waited + 1))
  done
  (( ${#daemons[@]} == 0 )) || systemctl start --no-block "${daemons[@]}"
}

# apply a profile's unit masks
apply_profile() {
  local profile="$1"
  if [[ "$profile" == server ]]; then
    clear_leftover_mask_targets "${SERVER_MASKED_UNITS[@]}"
    systemctl mask --now "${SERVER_MASKED_UNITS[@]}" \
      || die "systemctl mask --now failed for the desktop-only units"
    systemctl --global mask "${SERVER_MASKED_USER_UNITS[@]}" \
      || die "systemctl --global mask failed for the desktop-only user units"
    desktop_user_systemctl stop "${SERVER_MASKED_USER_UNITS[@]}" \
      || die "could not stop ${SERVER_MASKED_USER_UNITS[*]} in the desktop user's running manager"
    systemctl unmask "$SERVER_IDLE_UNIT" \
      || die "systemctl unmask $SERVER_IDLE_UNIT failed"
    systemctl enable "$SERVER_IDLE_UNIT" \
      || die "systemctl enable $SERVER_IDLE_UNIT failed"
    set_api_socket enable
  else
    systemctl unmask "${SERVER_MASKED_UNITS[@]}" \
      || die "systemctl unmask failed for the desktop-only units"
    systemctl --global unmask "${SERVER_MASKED_USER_UNITS[@]}" \
      || die "systemctl --global unmask failed for the desktop-only user units"
    systemctl --global enable "${DESKTOP_USER_PATH_UNITS[@]}" \
      || die "systemctl --global enable failed for ${DESKTOP_USER_PATH_UNITS[*]}"
    systemctl disable "$SERVER_IDLE_UNIT" >/dev/null 2>&1
    clear_leftover_mask_targets "$SERVER_IDLE_UNIT"
    systemctl mask "$SERVER_IDLE_UNIT" \
      || die "systemctl mask $SERVER_IDLE_UNIT failed"
    set_api_socket disable
    systemctl start "$DESKTOP_ATTACH_UNIT" \
      || die "systemctl start $DESKTOP_ATTACH_UNIT failed"
    { desktop_user_systemctl daemon-reload && desktop_user_systemctl start "${DESKTOP_USER_PATH_UNITS[@]}"; } \
      || die "could not start ${DESKTOP_USER_PATH_UNITS[*]} in the desktop user's running manager"
    start_desktop_units \
      || die "systemctl start failed for the desktop-only units"
  fi
  echo "RHIZO_PROFILE profile=$profile"
}

# show or set the profile
cmd_profile() {
  local sub="${1:-show}"
  case "$sub" in
    show)
      local profile
      profile=$(read_capability rhizo.profile) || profile="unknown ($POLICY_CONF unreadable, or rhizo.profile is not a registered capability)"
      echo "RHIZO_PROFILE profile=$profile"
      ;;
    desktop|server)
      cli_root_ok || die "profile $sub must run as root"
      write_profile_key "$sub"
      apply_profile "$sub"
      ;;
    *) die "profile takes show, desktop or server, not '$sub'" ;;
  esac
}

# check pid 1 for a Rhizo policy context
rhizo_policy_loaded() {
  [[ "$(tr -d '\0' 2>/dev/null < "$PROC_ROOT/1/attr/current")" =~ ^u:r:(kernel|rhizo_host):s0$ ]]
}

# print the loaded policy's devices.dri
loaded_policy_dri() {
  rhizo_policy_loaded || return 0
  sed -n 's/^dri=\(on\|off\)$/\1/p' "$POLICY_MODE_FILE" 2>/dev/null | tail -1
}

# print the RHIZO_GPU line for a mode
gpu_line() {
  if [[ "$1" == off ]]; then echo "RHIZO_GPU dri=off driver=gpu_driver_software"; else echo "RHIZO_GPU dri=on driver=gpu_driver"; fi
}

# show or set GPU rendering
cmd_gpu() {
  local sub="${1:-show}" dri mode loaded line
  case "$sub" in
    show)
      dri=$(read_dri) || die "could not read devices.dri through $LIB_DIR/sandbox/capabilities.py"
      [[ "$dri" == Error:* ]] && die "cannot read devices.dri: ${dri#Error: }"
      if [[ "$dri" == False ]]; then mode=off; else mode=on; fi
      line=$(gpu_line "$mode")
      loaded=$(loaded_policy_dri)
      if [[ -n "$loaded" && "$loaded" != "$mode" ]]; then
        log "devices.dri = $mode applies after a host reboot (this boot's policy is for dri = $loaded)"
        line+=" loaded=$loaded"
      fi
      echo "$line"
      ;;
    on|off)
      cli_root_ok || die "gpu $sub must run as root"
      write_policy_key devices dri "$sub"
      if ! rhizo_policy_loaded; then
        log "devices.dri = $sub: rebuilding the prepared tree"
        ( prepare_now ) >&2 || log "prepare failed: each start copies until 'sudo rhizo prepare' succeeds"
        gpu_line "$sub"
        return 0
      fi
      loaded=$(loaded_policy_dri)
      if [[ "$loaded" == "$sub" ]]; then
        log "devices.dri = $sub: the next start uses it"
        gpu_line "$sub"
        return 0
      fi
      ( mark_setup_pending "rebuild the prepared tree for devices.dri = $sub" "gpu $sub" ) \
        || log "the next boot will not rebuild the prepared tree: each start copies until 'sudo rhizo prepare' succeeds"
      if [[ -n "$loaded" ]]; then
        log "devices.dri = $sub applies after a host reboot (this boot's policy is for dri = $loaded)"
      else
        log "devices.dri = $sub applies after a host reboot"
      fi
      echo "RHIZO_GPU_REBOOT_REQUIRED=1 dri=$sub loaded=${loaded:-unknown}"
      ;;
    *) die "gpu takes show, on or off, not '$sub'" ;;
  esac
}

# print where fetch-gsi.sh stages a release
release_tree() {
  case "$1" in
    a16) echo "$GSI_ROOT/gsi_system" ;;
    *)   echo "$GSI_ROOT/gsi_system_$1" ;;
  esac
}

# reset the selected instance's /data
cmd_reset() {
  cli_root_ok || die "reset must run as root"
  resolve_instance_selector "$@"
  set -- "${RESOLVED_ARGS[@]}"
  [[ $# -eq 0 ]] || die "reset takes no arguments"
  do_reset
}

# rebuild data.img and wait for boot
do_reset() {
  [[ -x "$INSTALL_DIR/prepare/prepare.sh" ]] \
    || die "no $INSTALL_DIR/prepare/prepare.sh"
  local await="$INSTALL_DIR/prepare/await-boot-completed.py"
  [[ -r "$await" ]] || die "no $await"
  local unit; unit=$(instance_unit "$RHIZO_SANDBOX_ID")

  local release=a16 variant=user
  if [[ -s "$DATA_IMG.meta" ]]; then
    local m; m=$(sed -n 's/^release=//p' "$DATA_IMG.meta" | tail -1); [[ -n "$m" ]] && release="$m"
    m=$(sed -n 's/^variant=//p' "$DATA_IMG.meta" | tail -1); [[ -n "$m" ]] && variant="$m"
  fi

  local enforce; enforce=$(android_enforce_state "$RHIZO_SANDBOX_ID") || die "cannot read the SELinux mode (see above)"
  log "stopping $unit"
  systemctl stop "$unit" || die "systemctl stop $unit failed"

  log "re-instantiating $DATA_IMG from the $release/$variant template"
  local out rc mode_args ok_marker
  if [[ "$enforce" == 1 ]]; then
    mode_args=(--data-only)
    ok_marker='^RHIZO_PREPARE_DATA_ONLY='
  else
    mode_args=(--wipe-data --skip-setup-boot)
    ok_marker='^RHIZO_PREPARE_OK '
  fi
  out=$(RHIZO_DATA_IMG="$DATA_IMG" "$INSTALL_DIR/prepare/prepare.sh" \
        --sandbox-id "$RHIZO_SANDBOX_ID" --release "$release" --variant "$variant" \
        --gsi "$(release_tree "$release")" "${mode_args[@]}" 2>&1)
  rc=$?
  printf '%s\n' "$out" >&2
  [[ $rc -eq 0 ]] || die "prepare.sh ${mode_args[0]} failed (rc=$rc): data.img not replaced"
  grep -qE "$ok_marker" <<<"$out" \
    || die "prepare.sh printed no success marker: data.img not replaced"

  log "starting $unit"
  systemctl start "$unit" || die "systemctl start $unit failed"
  log "waiting for sys.boot_completed (bounded 300s)"
  /usr/bin/python3 "$await" --instance "$RHIZO_SANDBOX_ID" --timeout 300 \
    || die "no sys.boot_completed within 300s of the reset"
  wait_boot_completed "$RHIZO_SANDBOX_ID" 300 \
    || die "$unit started and instance $RHIZO_SANDBOX_ID reported no sys.boot_completed=1 over its probe socket within 300s"

  echo "RHIZO_RESET ok"
}

# poll sys.boot_completed over an instance's probe socket
wait_boot_completed() {
  local id="$1" timeout="$2" sock bc deadline
  [[ -r "$PROBE_CLIENT" ]] \
    || { log "no $PROBE_CLIENT: cannot read instance $id's sys.boot_completed"; return 1; }
  sock=$(instance_probe_sock "$id")
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if [[ -n "$(sandbox_init_pid "$id")" ]]; then
      bc=$(android_sh "getprop sys.boot_completed" 10 "$sock" 2>/dev/null)
      [[ "${bc//[[:space:]]/}" == 1 ]] && return 0
    fi
    sleep 2
  done
  return 1
}

# remove old data templates
gc_templates() {
  local cur_key="$1" keep_prev="" f
  [[ -n "$cur_key" && -d "$TEMPLATES_ROOT" ]] || return 0
  keep_prev=$(find "$TEMPLATES_ROOT" -maxdepth 1 -name 'data-template.*.img' ! -name "data-template.$cur_key.img" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  for f in "$TEMPLATES_ROOT"/data-template.*.img; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$TEMPLATES_ROOT/data-template.$cur_key.img" || "$f" == "$keep_prev" ]] && continue
    rm -f "$f" && log "removed old data template $(basename "$f")"
  done
}
# remove old precompiled_sepolicy files
gc_cache() {
  [[ -d "$VAR_CACHE" ]] || return 0
  local f
  while IFS= read -r f; do
    rm -f "$f" && log "removed old cache entry $(basename "$f")"
  done < <(find "$VAR_CACHE" -maxdepth 1 -type f -name 'precompiled_sepolicy.*' -printf '%T@ %p\n' \
    | sort -rn | tail -n +5 | cut -d' ' -f2-)
}

# set up the host and run bootstrap.sh
cmd_install() {
  [[ -x "$INSTALL_DIR/bootstrap/bootstrap.sh" ]] \
    || die "no $INSTALL_DIR/bootstrap/bootstrap.sh"
  if is_readonly_arg "$@"; then
    exec "$INSTALL_DIR/bootstrap/bootstrap.sh" "$@"
  fi
  cli_root_ok || die "install must run as root"

  local profile="" args=() mode
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="${2:-}"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if [[ -n "$profile" ]]; then
    case "$profile" in
      desktop|server) : ;;
      *) die "--profile takes desktop or server, not '$profile'" ;;
    esac
  elif ! profile=$(read_capability rhizo.profile); then
    log "could not read the current profile: using desktop"
    profile=desktop
  fi

  load_host_libs
  mode=$(configured_selinux_mode) || die "install needs the configured SELinux mode (see above)"
  if release_kept_host_mode; then
    mode=$(configured_selinux_mode) || die "install needs the configured SELinux mode (see above)"
  fi
  resolve_uid1000
  ensure_broker_group
  seed_apk_handler
  systemctl enable --now rhizo-brokerd.socket \
    || die "systemctl enable --now rhizo-brokerd.socket failed"
  write_profile_key "$profile"
  apply_profile "$profile"
  if [[ "$mode" == namespace ]] && ! grep -qx 'selinux-mode namespace' "$INSTALL_RECORD" 2>/dev/null; then
    if keep_host_mode_for_host_policy; then mode=host; else leave_host_mode; fi
  fi
  [[ "$mode" == host ]] && enter_host_mode
  exec "$INSTALL_DIR/bootstrap/bootstrap.sh" "${args[@]}"
}

# run the prepare verb
cmd_prepare() {
  [[ -x "$INSTALL_DIR/prepare/prepare.sh" ]] \
    || die "no $INSTALL_DIR/prepare/prepare.sh"
  if is_readonly_arg "$@"; then
    exec "$INSTALL_DIR/prepare/prepare.sh" "$@"
  fi
  prepare_now "$@"
  exit $?
}

# run prepare.sh and prune old files
prepare_now() {
  [[ -x "$INSTALL_DIR/prepare/prepare.sh" ]] \
    || die "no $INSTALL_DIR/prepare/prepare.sh"
  if ! selinux_mode_is namespace && [[ "$(cat "$SELINUX_ENFORCE_FILE" 2>/dev/null)" == 1 ]]; then
    defer_prepare_request "$@"
    return
  fi
  local args=("$@")
  [[ " $* " == *" --payload "* ]] || args=(--payload "$LIB_DIR" "${args[@]}")
  local out rc
  out=$("$INSTALL_DIR/prepare/prepare.sh" "${args[@]}"); rc=$?
  printf '%s\n' "$out"
  if (( rc == 0 )); then
    local template_key; template_key=$(sed -n 's/.*template=\([0-9a-f]*\).*/\1/p' <<<"$out" | tail -1)
    gc_templates "$template_key"
    gc_cache
  fi
  return "$rc"
}

# run gsi-update.sh
cmd_gsi() {
  [[ -x "$INSTALL_DIR/update/gsi-update.sh" ]] \
    || die "no $INSTALL_DIR/update/gsi-update.sh"
  exec "$INSTALL_DIR/update/gsi-update.sh" "$@"
}

# print the mode helper's refusal reason and sentence
mode_refusal() {
  local helper="$LIB_DIR/rhizo-selinux-mode" env=(--env-file "$ETC_RHIZO/androidd.env") out mode why rc=0
  out=$("$helper" "${env[@]}" --mode-and-why) || rc=$?
  if (( rc != 0 )); then printf '%s exited %d reading this boot'"'"'s SELinux mode\n' "$helper" "$rc"; return 2; fi
  IFS=$'\t' read -r mode why <<<"$out"
  [[ "$mode" == refuse:* ]] || return 1
  printf '%s\n%s\n' "${mode#refuse:}" "${why:-$helper gave no reason}"
}

# print the pending Rhizo kernel release
pending_rhizo_kernel() {
  local flavor out rel line rc=0 rels=()
  declare -F host_flavor >/dev/null || load_host_libs
  flavor=$(host_flavor 2>&1) || { echo "the host flavor probe failed ($flavor)"; return 2; }
  case "$flavor" in
    ubuntu)
      command -v dpkg-query >/dev/null 2>&1 || { echo "no dpkg-query to list the installed kernels"; return 2; }
      out=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-image-*-rhizo' 2>&1) || rc=$?
      (( rc <= 1 )) || { echo "dpkg-query exited $rc listing the Rhizo kernel packages: $(tail -1 <<<"$out")"; return 2; }
      while IFS= read -r line; do
        case "${line:0:3}" in
          "ii ") [[ "${line:4}" =~ ^linux-image-([0-9].*-rhizo)$ ]] && rels+=("${BASH_REMATCH[1]}") ;;
        esac
      done <<<"$out"
      rel=$(printf '%s\n' "${rels[@]}" | sort -V | tail -1) ;;
    cachyos)
      command -v pacman >/dev/null 2>&1 || { echo "no pacman to list the installed kernels"; return 2; }
      out=$(pacman -Q linux-rhizo 2>&1) || rc=$?
      (( rc <= 1 )) || { echo "pacman exited $rc listing the Rhizo kernel packages: $(tail -1 <<<"$out")"; return 2; }
      rel=$(sed -n 's/^linux-rhizo \(.*\)-[0-9][0-9]*$/\1/p' <<<"$out" | tr _ -) ;;
    *) return 1 ;;
  esac
  [[ -n "$rel" && "$rel" != "$(uname -r)" ]] && echo "$rel"
}

# load the setup state and its reason
load_setup_state() {
  local out rc=0 kernel krc
  SETUP_REASON="" SETUP_SENTENCE=""
  if [[ -s "$INSTALL_FAILED" ]]; then
    SETUP_STATE=install-failed
  elif [[ -e "$CONFIGURE_PENDING" && -e "$PACMAN_DB_LOCK" ]]; then
    SETUP_STATE=configuring
  elif [[ -e "$CONFIGURE_PENDING" ]]; then
    SETUP_STATE=install-failed
  elif [[ -e "$PREPARED_MARKER" ]]; then
    SETUP_STATE="done"
  elif [[ "$(systemctl is-active rhizo-prepare.service 2>/dev/null)" == activating ]]; then
    SETUP_STATE=pending
  else
    out=$(mode_refusal) || rc=$?
    case $rc in
      0) SETUP_REASON=$(sed -n 1p <<<"$out"); SETUP_SENTENCE=$(sed -n 2p <<<"$out")
         SETUP_STATE=refused
         if [[ "$SETUP_REASON" == kernel-has-no-selinux-namespaces ]]; then
           krc=0; kernel=$(pending_rhizo_kernel) || krc=$?
           if (( krc == 0 )); then
             SETUP_STATE=pending-reboot; SETUP_REASON=""
             SETUP_SENTENCE="reboot into the Rhizo kernel, $kernel, to run setup"
           elif (( krc == 2 )); then
             SETUP_SENTENCE="$SETUP_SENTENCE ($kernel)"
           fi
         fi ;;
      2) SETUP_STATE="helper-failed"; SETUP_SENTENCE=$out ;;
      *) SETUP_STATE=pending-reboot ;;
    esac
  fi
}

# print the setup state
setup_state() {
  load_setup_state
  echo "$SETUP_STATE"
}

# print the note for the configuring state
configuring_note() {
  echo "pacman is running rhizo's configure: wait for it, or with no pacman running remove $PACMAN_DB_LOCK and run" \
       "'sudo /usr/share/libalpm/scripts/rhizo-configure'"
}

# print the note for a failed install
install_failed_note() {
  local step rc
  if [[ ! -s "$INSTALL_FAILED" ]]; then
    echo "pacman's configure hook did not finish ($CONFIGURE_PENDING exists): run" \
         "'sudo /usr/share/libalpm/scripts/rhizo-configure', or install the same packages again"
    return 0
  fi
  read -r step rc < "$INSTALL_FAILED"
  echo "the install failed at ${step:-an unnamed step} (exit ${rc:-?}): fix that step, then install the same packages again"
}

defer_prepare_to_next_boot() {
  local enforcing="$1" mode="${2:-host}"
  mark_setup_pending "finish the upgrade" upgrade
  log "reboot to finish the upgrade"
  if [[ "$mode" == namespace && "$(uname -r)" != *-rhizo ]]; then
    log "reboot into the Rhizo kernel to run setup; apps and data are kept"
    echo "RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=rhizo-kernel"
  elif [[ "$mode" == namespace ]]; then
    log "rhizo-prepare.service runs setup at the next boot; apps and data are kept"
    echo "RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=setup-at-boot"
  elif [[ "$enforcing" == 1 ]]; then
    log "SELinux is enforcing: rhizo-prepare.service runs setup at the next boot; apps and data are kept"
    echo "RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=enforcing"
  else
    log "rhizo-prepare.service runs setup at the next boot; apps and data are kept"
    echo "RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=setup-at-boot"
  fi
}

# mark setup pending for the next boot
mark_setup_pending() {
  local enabled err
  enabled=$(systemctl is-enabled rhizo-prepare.service 2>/dev/null)
  case "$enabled" in
    enabled|enabled-runtime) : ;;
    *) die "rhizo-prepare.service is '${enabled:-not installed}': run 'systemctl enable rhizo-prepare.service', then 'rhizo $2'" ;;
  esac
  rm -f "$PREPARED_MARKER" \
    || die "could not clear $PREPARED_MARKER"
  if ! err=$( { : > "$REBOOT_REQUIRED_FILE"; } 2>&1 ); then
    log "could not write $REBOOT_REQUIRED_FILE: $err"
  fi
}

# record a prepare request for the next boot
defer_prepare_request() {
  cli_root_ok || die "prepare must run as root"
  local release=current variant="" wipe=0 status current candidate out reason tree
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release) release="${2:-}"; shift 2 ;;
      --variant) variant="${2:-}"; shift 2 ;;
      --wipe-data) wipe=1; shift ;;
      --payload) shift 2 ;;
      *) die "SELinux is enforcing: a prepare at the next boot takes --release, --variant and --wipe-data, not '$1'" ;;
    esac
  done
  [[ -s "$PREPARE_REQUEST" ]] \
    && die "a prepare of $(sed -n 's/^release=//p' "$PREPARE_REQUEST" | tail -1) is already pending for the next boot: reboot first"
  status=$("$INSTALL_DIR/update/gsi-update.sh" status 2>/dev/null | tail -1)
  current=$(sed -n 's/.* current=\([^ ]*\) .*/\1/p' <<<"$status")
  candidate=$(sed -n 's/.* candidate=\([^ ]*\) .*/\1/p' <<<"$status")
  [[ -n "$current" && -n "$candidate" ]] || die "rhizo gsi status named no current release: '$status'"
  [[ "$release" == current ]] && release="$current"
  [[ "$candidate" == - ]] \
    || die "a rhizo gsi trial of $candidate is armed: wait for it or run 'rhizo gsi abort', then prepare $release"
  [[ "$release" == "$current" || "$wipe" == 1 ]] \
    || die "preparing $release in place of $current needs --wipe-data; 'rhizo gsi update --release $release' keeps /data"
  out=$("$INSTALL_DIR/update/gsi-update.sh" kernel-check --release "$release" 2>&1)
  if [[ "$(tail -1 <<<"$out")" != "RHIZO_GSI_KERNEL_OK release=$release" ]]; then
    printf '%s\n' "$out" | grep -v '^RHIZO_' >&2
    reason=$(sed -n 's/.*reason=\([^ ]*\).*/\1/p' <<<"$(tail -1 <<<"$out")")
    echo "RHIZO_PREPARE_REFUSED reason=${reason:-kernel-check}"
    exit 1
  fi
  tree=$(release_tree "$release")
  if [[ ! -s "$tree/bin/init" ]]; then
    out=$("$INSTALL_DIR/prepare/fetch-gsi.sh" --release "$release" --fetch-only 2>&1)
    if [[ "$(tail -1 <<<"$out")" != RHIZO_GSI_FETCHED* ]]; then
      printf '%s\n' "$out" >&2
      die "could not fetch $release's image for the next boot's prepare"
    fi
  fi
  mkdir -p "$(dirname "$PREPARE_REQUEST")"
  { printf 'release=%s\nvariant=%s\nwipe_data=%s\n' "$release" "$variant" "$wipe" > "$PREPARE_REQUEST.tmp" \
      && mv "$PREPARE_REQUEST.tmp" "$PREPARE_REQUEST"; } || die "could not write $PREPARE_REQUEST"
  mark_setup_pending "prepare $release" prepare
  log "rhizo-prepare.service prepares $release$( ((wipe)) && echo " on a new /data") at the next boot: reboot to run it"
  echo "RHIZO_PREPARE_REBOOT_REQUIRED=1 reason=enforcing release=$release"
}

# re-run the bootstrap and the prepare
cmd_upgrade() {
  [[ -x "$INSTALL_DIR/bootstrap/bootstrap.sh" && -x "$INSTALL_DIR/prepare/prepare.sh" ]] \
    || die "install/bootstrap/bootstrap.sh or install/prepare/prepare.sh missing under $LIB_DIR"
  local enforcing=0 mode
  mode=$(configured_selinux_mode) || die "upgrade needs the configured SELinux mode (see above)"
  if [[ "$mode" == namespace ]] && is_readonly_arg "$@"; then
    cmd_prepare "$@"
    return
  fi
  if [[ -e "$HOST_MODE_KEPT" ]] && ! is_readonly_arg "$@"; then
    cli_root_ok || die "upgrade over a kept host mode must run as root"
    if release_kept_host_mode; then
      mode=$(configured_selinux_mode) || die "upgrade needs the configured SELinux mode (see above)"
    fi
  fi
  if [[ "$mode" == namespace ]] && ! grep -qx 'selinux-mode namespace' "$INSTALL_RECORD" 2>/dev/null; then
    cli_root_ok || die "upgrade from a host-mode install must run as root"
    load_host_libs
    if keep_host_mode_for_host_policy; then mode=host; enter_host_mode; else leave_host_mode; fi
  fi
  [[ "$mode" == host ]] && ! selinux_mode_is namespace && [[ "$(cat "$SELINUX_ENFORCE_FILE" 2>/dev/null)" == 1 ]] \
    && enforcing=1
  if [[ "$mode" == namespace ]]; then
    log "re-applying the boot line, bootloader and swap bootstrap"
  else
    log "re-applying the LSM, GRUB and swap bootstrap"
  fi
  "$INSTALL_DIR/bootstrap/bootstrap.sh" >&2 || die "the bootstrap step failed during upgrade"
  if is_readonly_arg "$@"; then
    cmd_prepare "$@"
    return
  fi
  defer_prepare_to_next_boot "$enforcing" "$mode"
}

# confirm the purge with a typed yes
confirm_purge() {
  [[ "${RHIZO_ASSUME_YES:-0}" == 1 ]] && return 0
  log "--purge removes, IRREVERSIBLY:"
  log "  every installed app and its data ($DATA_IMG)"
  log "  $ETC_RHIZO in full, including hostfs.conf if you edited it"
  log "  the uid-1000 system account this installer created, if it created one"
  [[ -t 0 ]] || die "purge needs a terminal to confirm on, or RHIZO_ASSUME_YES=1"
  local reply
  read -r -p "[$PROG] type 'yes' to purge: " reply
  [[ "$reply" == yes ]] || die "purge not confirmed: typed '${reply:-<empty>}', not 'yes'; nothing removed"
}

# test whether a package is installed
uninstall_holds() {
  local err rc=0
  err=$(host_pkg_installed "$1" 2>&1) || rc=$?
  case $rc in
    0|1) return "$rc" ;;
    *)   die "cannot tell whether $1 is installed: nothing removed${err:+ ($err)}" ;;
  esac
}

# print the apt packages Rhizo's install added
rhizo_added_packages() {
  local dir="${RHIZO_APT_HISTORY_DIR:-/var/log/apt}" logdir="${RHIZO_DPKG_LOG_DIR:-/var/log}" f arch out rc=0 sim
  local line name pkg start end old
  local -a files=() dfiles=() list=() keep=() outside=()
  local -A ours=([rhizo]=1) want=() auto=() drop=() how=()
  for f in "$dir"/history.log.*.gz; do [[ -e "$f" ]] && files+=("$f"); done
  mapfile -t files < <(printf '%s\n' "${files[@]}" | sed -n 's/.*\.\([0-9]\+\)\.gz$/\1 &/p' | sort -rn | cut -d' ' -f2-)
  [[ -e "$dir/history.log" ]] && files+=("$dir/history.log")
  (( ${#files[@]} )) || { echo "no apt history in $dir, so the packages Rhizo's install added cannot be named"; return 2; }
  for f in "${files[@]}"; do
    [[ -r "$f" ]] || { echo "cannot read $f as uid $EUID, so the packages Rhizo's install added cannot be named"; return 2; }
  done
  arch=$(dpkg --print-architecture) || { echo "dpkg --print-architecture failed"; return 2; }
  out=$(zcat -f -- "${files[@]}" | awk '
         /^Start-Date: / {start = substr($0, 13); gsub(/ +/, " ", start); inst = ""; upg = ""}
         /^Install: / {inst = substr($0, 10)}
         /^Upgrade: / {upg = substr($0, 10)}
         /^End-Date: / {
           end = substr($0, 11); gsub(/ +/, " ", end)
           if (inst ~ /(^|, )rhizo:[a-z0-9]+ \(/) n = 0
           if (inst ~ /(^|, )rhizo:[a-z0-9]+ \(/ || (seen && upg ~ /(^|, )rhizo:[a-z0-9]+ \(/)) {
             seen = 1; t[++n] = start "\t" end "\t" inst
           }
         }
         END {for (i = 1; i <= n; i++) print t[i]}') \
    || { echo "zcat could not read apt's history in $dir"; return 2; }
  [[ -n "$out" ]] || { echo "apt's history in $dir holds no transaction that installed rhizo, so the packages it added cannot be named"; return 2; }
  while IFS=$'\t' read -r start end line; do
    while IFS= read -r pkg; do
      [[ "$pkg" =~ ^([^:\ ]+):([^\ ]+)\ \([^\)]*,\ automatic\)$ ]] || continue
      name=${BASH_REMATCH[1]}
      [[ "${BASH_REMATCH[2]}" == "$arch" || "${BASH_REMATCH[2]}" == all ]] || name+=":${BASH_REMATCH[2]}"
      [[ -n "${ours[$name]:-}" ]] || want[$name]="$start"$'\t'"$end"
    done < <(sed 's/), /)\n/g' <<<"$line")
  done <<<"$out"
  (( ${#want[@]} )) || return 0
  for f in "$logdir"/dpkg.log.*.gz; do [[ -e "$f" ]] && dfiles+=("$f"); done
  mapfile -t dfiles < <(printf '%s\n' "${dfiles[@]}" | sed -n 's/.*\.\([0-9]\+\)\.gz$/\1 &/p' | sort -rn | cut -d' ' -f2-)
  [[ -e "$logdir/dpkg.log.1" ]] && dfiles+=("$logdir/dpkg.log.1")
  [[ -e "$logdir/dpkg.log" ]] && dfiles+=("$logdir/dpkg.log")
  (( ${#dfiles[@]} )) || { echo "no dpkg log in $logdir, so the packages Rhizo's install added cannot be named"; return 2; }
  for f in "${dfiles[@]}"; do
    [[ -r "$f" ]] || { echo "cannot read $f as uid $EUID, so the packages Rhizo's install added cannot be named"; return 2; }
  done
  out=$(zcat -f -- "${dfiles[@]}") || { echo "zcat could not read dpkg's log in $logdir"; return 2; }
  for name in "${!want[@]}"; do
    IFS=$'\t' read -r start end <<<"${want[$name]}"
    old=$(awk -v s="$start" -v e="$end" -v n="$name" -v a="$arch" '
            $3 == "install" && ($4 == n || $4 == n ":" a || $4 == n ":all") && ($1 " " $2) >= s && ($1 " " $2) <= e {o = $5}
            END {print o}' <<<"$out")
    [[ -n "$old" ]] || { echo "dpkg's log in $logdir holds no install of $name between $start and $end, so whether it had configuration files before Rhizo cannot be told"; return 2; }
    if [[ "$old" == "<none>" ]]; then how[$name]=purge; else how[$name]=remove; fi
  done
  # shellcheck disable=SC2016
  out=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}:${Architecture}\n' "${!want[@]}" 2>&1) || rc=$?
  (( rc <= 1 )) || { echo "dpkg-query exited $rc listing the packages Rhizo's install added: $(grep '^dpkg-query:' <<<"$out" | tail -1)"; return 2; }
  while IFS= read -r line; do
    case "${line:0:3}" in
      "ii ") name=${line:4}; name=${name%:"$arch"}; name=${name%:all}
             [[ -z "${want[$name]:-}" ]] || list+=("$name") ;;
    esac
  done <<<"$out"
  (( ${#list[@]} )) || return 0
  out=$(apt-mark showauto "${list[@]}") || { echo "apt-mark showauto failed"; return 2; }
  while IFS= read -r pkg; do auto[${pkg%:"$arch"}]=1; done <<<"$out"
  for name in "${list[@]}"; do [[ -n "${auto[$name]:-}" ]] && keep+=("$name"); done
  list=("${keep[@]}")
  while (( ${#list[@]} )); do
    sim=$(apt-get -s purge "${list[@]}" 2>&1) || { echo "apt-get -s purge of the packages Rhizo's install added failed: $(tail -1 <<<"$sim")"; return 2; }
    outside=()
    declare -A inl=(); for name in "${list[@]}"; do inl[$name]=1; done
    while read -r _ pkg _; do
      [[ -n "${inl[$pkg]:-}" || -n "${ours[$pkg]:-}" ]] || outside+=("$pkg")
    done < <(grep -E '^(Purg|Remv) ' <<<"$sim")
    (( ${#outside[@]} )) || break
    drop=()
    while IFS= read -r pkg; do [[ "$pkg" == " "* ]] || drop[$pkg]=1; done \
      < <(apt-cache depends --installed --recurse --no-recommends --no-suggests --no-conflicts --no-breaks \
            --no-replaces --no-enhances "${outside[@]}")
    keep=(); for name in "${list[@]}"; do [[ -n "${drop[$name]:-}" ]] || keep+=("$name"); done
    (( ${#keep[@]} < ${#list[@]} )) || { echo "purging the packages Rhizo's install added would remove ${outside[*]}, and none of them depends on one"; return 2; }
    list=("${keep[@]}")
    unset inl
  done
  for name in "${list[@]}"; do printf '%s\t%s\n' "${how[$name]}" "$name"; done | sort
  return 0
}

# print the pacman packages Rhizo's install added
rhizo_pacman_added() {
  local log="${RHIZO_PACMAN_LOG:-/var/log/pacman.log}" out name field value changed line rc=0
  local -a list=() keep=()
  local -A ours=([rhizo]=1) inl=() reason=() needs=()
  [[ -e "$log" ]] || { echo "no pacman log at $log, so the packages Rhizo's install added cannot be named"; return 2; }
  [[ -r "$log" ]] || { echo "cannot read $log as uid $EUID, so the packages Rhizo's install added cannot be named"; return 2; }
  out=$(awk '
         / \[ALPM\] transaction started$/ {n = 0; r = 0; u = 0}
         $2 == "[ALPM]" && $3 == "installed" {t[++n] = $4; if ($4 == "rhizo") r = 1}
         $2 == "[ALPM]" && $3 == "upgraded" && $4 == "rhizo" {u = 1}
         / \[ALPM\] transaction completed$/ {
           if (r) m = 0
           if (r || (seen && u)) { seen = 1; for (i = 1; i <= n; i++) k[++m] = t[i] }
         }
         END {if (seen) print "#rhizo"; for (i = 1; i <= m; i++) print k[i]}' "$log") \
    || { echo "awk could not read $log"; return 2; }
  [[ "$out" == "#rhizo"* ]] || { echo "$log holds no transaction that installed rhizo, so the packages it added cannot be named"; return 2; }
  while IFS= read -r name; do
    [[ "$name" == "#rhizo" || -n "${ours[$name]:-}" ]] || inl[$name]=1
  done <<<"$out"
  (( ${#inl[@]} )) || return 0
  out=$(pacman -Qq "${!inl[@]}" 2>&1) || rc=$?
  (( rc <= 1 )) || { echo "pacman -Qq exited $rc listing the packages Rhizo's install added: $(tail -1 <<<"$out")"; return 2; }
  mapfile -t keep < <(grep -v '^error: ' <<<"$out" | grep .)
  (( ${#keep[@]} )) || return 0
  out=$(pacman -Qi "${keep[@]}" 2>&1) || { echo "pacman -Qi failed on the packages Rhizo's install added: $(tail -1 <<<"$out")"; return 2; }
  while IFS= read -r line; do
    field=${line%%:*}; field=${field%"${field##*[![:space:]]}"}; value=${line#*: }
    case "$field" in
      Name) name=$value ;;
      "Required By") [[ "$value" == None ]] || needs[$name]=$value ;;
      "Install Reason") reason[$name]=$value ;;
    esac
  done <<<"$out"
  for name in "${!reason[@]}"; do
    [[ "${reason[$name]}" == "Installed as a dependency for another package" && -n "${inl[$name]:-}" ]] && list+=("$name")
  done
  changed=1
  while (( changed )); do
    changed=0; keep=(); inl=()
    for name in "${list[@]}"; do inl[$name]=1; done
    for name in "${list[@]}"; do
      for value in ${needs[$name]:-}; do
        [[ -n "${inl[$value]:-}" || -n "${ours[$value]:-}" ]] || { changed=1; continue 2; }
      done
      keep+=("$name")
    done
    list=("${keep[@]}")
  done
  (( ${#list[@]} )) && printf '%s\n' "${list[@]}" | sort
  return 0
}

# remove rhizo
cmd_uninstall() {
  local purge=0 args=() manager rhizo_held=0
  for a in "$@"; do
    case "$a" in
      --purge) purge=1 ;;
      *) args+=("$a") ;;
    esac
  done
  if ! is_readonly_arg "${args[@]:-}"; then
    load_host_libs
    manager=$(host_pkg_manager 2>&1) || die "$manager: nothing removed"
    if uninstall_holds rhizo; then rhizo_held=1; fi
  fi
  if is_readonly_arg "${args[@]:-}" || (( ! rhizo_held )); then
    [[ -x "$INSTALL_DIR/teardown/teardown.sh" ]] \
      || die "no $INSTALL_DIR/teardown/teardown.sh"
    if (( ! purge )) || is_readonly_arg "${args[@]:-}"; then
      (( purge )) && args+=(--purge)
      exec "$INSTALL_DIR/teardown/teardown.sh" "${args[@]}"
    fi
    confirm_purge
    exec "$INSTALL_DIR/teardown/teardown.sh" --purge "${args[@]}"
  fi
  (( ${#args[@]} == 0 )) \
    || die "uninstall on a $manager install takes only --purge or --verify, got: ${args[*]}"
  if [[ "$manager" == pacman ]]; then
    local pkgs=(rhizo) pm=(-R) added rc=0
    if (( purge )); then
      confirm_purge; pm=(-Rn); export RHIZO_TEARDOWN_PURGE=1
    else
      unset RHIZO_TEARDOWN_PURGE
    fi
    [[ "${RHIZO_ASSUME_YES:-0}" == 1 ]] && pm+=(--noconfirm)
    added=$(rhizo_pacman_added) || rc=$?
    log "pacman ${pm[*]} removes ${pkgs[*]} and the packages Rhizo's install added:"
    if (( rc )); then
      log "  none named: $added"
    elif [[ -z "$added" ]]; then
      log "  none: every package it added is gone, kept by hand, or needed by another installed package"
    else
      log "  $(tr '\n' ' ' <<<"$added" | sed 's/ $//')"
      mapfile -t -O "${#pkgs[@]}" pkgs <<<"$added"
    fi
    exec pacman "${pm[@]}" "${pkgs[@]}"
  fi
  local yes=() added rc=0
  [[ "${RHIZO_ASSUME_YES:-0}" == 1 ]] && yes=(-y)
  (( ! purge )) || confirm_purge
  added=$(rhizo_added_packages) || rc=$?
  if (( purge )); then
    log "apt-get purge rhizo; then purge the Rhizo kernel's packages; then the packages Rhizo's install added:"
  else
    log "apt-get remove rhizo; then remove the Rhizo kernel's packages; then the packages Rhizo's install added:"
  fi
  if (( rc )); then
    log "  none named: $added"
  elif [[ -z "$added" ]]; then
    log "  none: every package it added is gone, kept by hand, or needed by another installed package"
  elif (( purge )); then
    [[ "$added" != *purge$'\t'* ]] || log "  sudo apt purge $(sed -n 's/^purge\t//p' <<<"$added" | tr '\n' ' ' | sed 's/ $//')"
    [[ "$added" != *remove$'\t'* ]] || log "  sudo apt remove $(sed -n 's/^remove\t//p' <<<"$added" | tr '\n' ' ' | sed 's/ $//')" \
      "(keeps their configuration files)"
  else
    log "  sudo apt remove $(cut -f2 <<<"$added" | tr '\n' ' ' | sed 's/ $//')"
  fi
  (( purge )) && exec apt-get -y purge rhizo
  exec apt-get "${yes[@]}" remove rhizo
}

# print this boot's policy refusal reason
policy_refusal_reason() {
  [[ -r "$POLICY_REFUSED_FILE" ]] || return 0
  sed -n 's/^reason=//p' "$POLICY_REFUSED_FILE" | head -1
}

# print the policy refusal sentence
policy_refusal_note() {
  local why verdict
  why=$(policy_refusal_reason)
  [[ -n "$why" ]] && printf "Android's policy was refused on this boot: %s. " "$why"
  if [[ -n "${1:-}" ]]; then
    verdict=$(start_verdict "$1") || { printf "The SELinux mode could not be read. "; return 0; }
  else
    verdict=$(selinuxns_verdict "$RHIZO_SANDBOX_ID") || { printf "The SELinux mode could not be read. "; return 0; }
  fi
  [[ "$verdict" == refused:* ]] && printf "Android's SELinux namespace start was refused: %s. " "${verdict#refused:}"
  return 0
}
# print Android's SELinux namespace state
selinuxns_status() {
  local verdict unit_state="${1:-}"
  verdict=$(selinuxns_verdict "$RHIZO_SANDBOX_ID") || { echo "SELinux mode unreadable"; return; }
  case "$verdict" in
    enforced)           echo "Android enforcing" ;;
    pending|handed-off)
      case "$unit_state" in
        active|activating) echo "Android starting" ;;
        "")                echo "Android verdict '$verdict' (unit state unknown)" ;;
        *)                 echo "Android start ended with no verdict (recorded '$verdict', unit $unit_state)" ;;
      esac ;;
    refused:*)          echo "Android refused: ${verdict#refused:}" ;;
    permissive)         echo "Android permissive (RHIZO_PERMISSIVE=1)" ;;
    stopped)            echo "Android stopped" ;;
    "")                 echo "Android not started on this boot" ;;
    *)                  echo "Android verdict '$verdict'" ;;
  esac
}

# print this boot's Android policy state
policy_status_line() {
  local refused
  refused=$(policy_refusal_reason)
  if [[ -n "$refused" ]]; then
    echo "pending-reboot (refused: $refused)"
    return
  fi
  if ! rhizo_policy_loaded; then
    echo "not loaded"
    return
  fi
  if [[ -r /run/rhizo-policy-loaded ]]; then
    local loaded_at sha by
    loaded_at=$(sed -n 's/^loaded_at=//p' /run/rhizo-policy-loaded | head -1)
    sha=$(sed -n 's/^sha256=//p' /run/rhizo-policy-loaded | head -1)
    by=$(sed -n 's/^loaded_by=//p' /run/rhizo-policy-loaded | head -1)
    if [[ -n "$by" && "$by" != rhizo-policy.service ]]; then
      echo "loaded-at-boot by $by, verified by rhizo-policy.service ${loaded_at:-?}"
      return
    fi
    echo "loaded-at-boot by rhizo-policy.service ${loaded_at:-?} sha=${sha:0:12}"
    return
  fi
  echo "loaded (source unknown: no state file)"
}

# print the last start's prepared-tree refusal
prepared_refusal_status() {
  local record="$PREPARED_ROOT/refusal" reason outcome failed error
  local fix="run 'sudo rhizo prepare'"
  [[ -s "$record" ]] || return 0
  reason=$(sed -n 's/^reason=//p' "$record" | tail -1)
  outcome=$(sed -n 's/^outcome=//p' "$record" | tail -1)
  failed=$(sed -n 's/^failed=//p' "$record" | tail -1)
  error=$(sed -n 's/^error=//p' "$record" | tail -1)
  if [[ -s "$PREPARE_REQUEST" ]]; then
    echo "refused ($reason) at the last start; a re-prepare is pending for the next boot"
  elif [[ "$outcome" == rebuild-failed ]]; then
    echo "refused ($reason) at the last start; its rebuild at boot failed ($failed): $fix"
  elif [[ "$outcome" == unit-query-failed ]]; then
    echo "refused ($reason) at the last start; cannot read whether rhizo-prepare.service is enabled ($error): $fix"
  elif [[ "$outcome" == repeated ]]; then
    echo "refused ($reason) again after its rebuild at the last start: $fix"
  elif [[ "$outcome" == no-prepare-unit ]]; then
    echo "refused ($reason) at the last start; rhizo-prepare.service is not enabled: $fix"
  else
    echo "refused ($reason) at the last start; the next start checks the rebuilt tree"
  fi
}

# print this boot's start refusal
boot_refusal_status() {
  local out rc=0
  out=$(mode_refusal) || rc=$?
  case $rc in
    0) echo "refused ($(sed -n 1p <<<"$out")): $(sed -n 2p <<<"$out")" ;;
    2) echo "unknown: $out" ;;
  esac
}
# print the state of host mode's label removal
host_labels_status() {
  local head state reason sentence
  [[ -e "$HOST_LABELS_PENDING" ]] || return 0
  if ! head=$(head -1 "$HOST_LABELS_PENDING"); then
    echo "unknown: cannot read $HOST_LABELS_PENDING"
    return 0
  fi
  sentence=$(sed -n 2p "$HOST_LABELS_PENDING")
  read -r state reason <<<"$head"
  case "$state" in
    pending)
      if [[ "$(systemctl is-failed rhizo-host-labels.service 2>/dev/null)" == failed ]]; then
        echo "failed on this boot (journalctl -b -u rhizo-host-labels.service); the next boot retries"
      else
        echo "pending: the next boot removes host mode's labels (rhizo-host-labels.service)"
      fi ;;
    refused|failed) echo "$state ($reason): $sentence" ;;
    *) echo "unknown: $HOST_LABELS_PENDING reads '$head'" ;;
  esac
}

# print an instance's status
cmd_status() {
  resolve_instance_selector "$@"
  set -- "${RESOLVED_ARGS[@]}"
  local init="" running=0 unit=""
  init=$(sandbox_init_pid)
  [[ -n "$init" ]] && running=1
  command -v systemctl >/dev/null 2>&1 && unit=$(systemctl is-active "$(instance_unit "$RHIZO_SANDBOX_ID")" 2>/dev/null)

  if [[ "${1:-}" == --json ]]; then
    status_json "$running" "$unit"
    return 0
  fi
  if [[ "${1:-}" == --adb ]]; then
    (( running )) && sandbox_adb_endpoint
    return 0
  fi

  log "version      : $(rhizo_version)"
  log "sandbox      : $([[ $running == 1 ]] && echo "running (init pid $init)" || echo "not running")"
  [[ -n "$unit" ]] && log "$(instance_unit "$RHIZO_SANDBOX_ID") : $unit"
  if selinux_mode_is namespace; then
    log "selinux      : namespace, $(selinuxns_status "$unit")"
  else
    log "policy       : $(policy_status_line) enforce=$(cat "$SELINUX_ENFORCE_FILE" 2>/dev/null || echo '?')"
  fi

  shopt -s nullglob
  local trees=("$GSI_ROOT"/gsi_system*)
  shopt -u nullglob
  if (( ${#trees[@]} )); then
    log "gsi trees    : ${trees[*]}"
  else
    log "gsi trees    : none under $GSI_ROOT"
  fi

  local data=absent
  if [[ -s "$DATA_IMG" ]]; then
    data=present
    log "data.img     : present ($(du -h --apparent-size "$DATA_IMG" 2>/dev/null | cut -f1))"
    [[ -f "$DATA_IMG.meta" ]] && log "data.img.meta: $(tr '\n' ' ' < "$DATA_IMG.meta")"
  else
    log "data.img     : absent ($DATA_IMG)"
  fi

  if [[ -L "$PREPARED_ROOT/current" ]]; then
    log "prepared     : current key $(readlink "$PREPARED_ROOT/current")"
  else
    log "prepared     : no $PREPARED_ROOT/current; run 'rhizo prepare'"
  fi
  local refusal; refusal=$(prepared_refusal_status)
  [[ -n "$refusal" ]] && log "prepared     : $refusal"
  local setup; load_setup_state; setup=$SETUP_STATE
  case "$setup" in
    done)           log "setup        : done ($(tr '\n' ' ' < "$PREPARED_MARKER" 2>/dev/null))" ;;
    pending)        log "setup        : pending; see systemctl status rhizo-prepare.service" ;;
    pending-reboot)
      [[ -n "$SETUP_SENTENCE" ]] || SETUP_SENTENCE="reboot to finish the install or upgrade"
      log "setup        : pending-reboot; $SETUP_SENTENCE" ;;
    refused)        log "setup        : refused ($SETUP_REASON); $SETUP_SENTENCE" ;;
    helper-failed)  log "setup        : unknown; $SETUP_SENTENCE" ;;
    install-failed) log "setup        : install-failed; $(install_failed_note)" ;;
    configuring)    log "setup        : configuring; $(configuring_note)" ;;
  esac
  local labels; labels=$(host_labels_status)
  [[ -n "$labels" ]] && log "host labels  : $labels"
  [[ -s "$HOST_MODE_KEPT" ]] && log "host mode    : kept; $(sed -n '1s/^# //p' "$HOST_MODE_KEPT")"
  local refusal_now=""
  case "$setup" in
    refused|helper-failed|pending-reboot) ;;
    *) refusal_now=$(boot_refusal_status) ;;
  esac
  [[ -n "$refusal_now" ]] && log "this boot    : $refusal_now"

  if (( ! running )); then
    log "boot         : not running; last boot log $(instance_boot_log "$RHIZO_SANDBOX_ID")"
  elif [[ ! -r "$PROBE_CLIENT" ]]; then
    log "boot         : no $PROBE_CLIENT"
  else
    local bc; bc=$(android_sh "getprop sys.boot_completed" 10 2>&1)
    bc="${bc//$'\n'/ }"
    if [[ "${bc//[[:space:]]/}" == 1 ]]; then
      log "boot         : sys.boot_completed=1"
    else
      log "boot         : sys.boot_completed reads '${bc:0:200}', not 1"
    fi
  fi

  echo "RHIZO_STATUS running=$running unit=${unit:-unknown} data=$data setup=$setup"
}

# print an instance's adb endpoint
sandbox_adb_endpoint() {
  local id="${1:-$RHIZO_SANDBOX_ID}" sock="$PROBE_SOCK"
  (( $# >= 1 )) && sock=$(instance_probe_sock "$id")
  [[ -n "$(sandbox_init_pid "$id")" ]] || return 0
  local reach
  reach=$(read_capability server.adb_reach 2>/dev/null) || reach=host
  if [[ "$reach" == lan && $(canon_id "$id") -eq 0 ]]; then
    local uplink_if uplink_ip
    uplink_if=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1)
    if [[ -n "$uplink_if" ]]; then
      uplink_ip=$(ip -4 -o addr show dev "$uplink_if" 2>/dev/null \
        | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
    fi
    if [[ -n "$uplink_ip" ]]; then
      printf '%s:5555\n' "$uplink_ip"
      return 0
    fi
  fi
  [[ -r "$PROBE_CLIENT" ]] || return 0
  local ip
  ip=$(android_sh "ip -4 -o addr show eth0" 10 "$sock" 2>/dev/null \
       | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
  [[ -n "$ip" ]] && printf '%s:5555\n' "$ip"
}

# print rhizo status as JSON
status_json() {
  local running="$1" unit="$2"
  local profile bc="" adb="" release="" prepared="" keys=0 version
  version=$(rhizo_version)
  profile=$(read_capability rhizo.profile 2>/dev/null) || profile=""
  if (( running )); then
    bc=$(android_sh "getprop sys.boot_completed" 10 2>/dev/null | tr -d '[:space:]')
    adb=$(sandbox_adb_endpoint)
  fi
  [[ -s "$DATA_IMG.meta" ]] && release=$(sed -n 's/^release=//p' "$DATA_IMG.meta" | tail -1)
  [[ -L "$PREPARED_ROOT/current" ]] && prepared=$(readlink "$PREPARED_ROOT/current")
  [[ -r "$ADB_KEYS_FILE" ]] && keys=$(grep -cv '^[[:space:]]*$' "$ADB_KEYS_FILE" 2>/dev/null)
  /usr/bin/python3 -c '
import json, sys
version, profile, unit, bc, adb, release, prepared, setup, keys = sys.argv[1:10]
print(json.dumps({
    "version": version or None,
    "profile": profile or None,
    "unit": unit or None,
    "boot_completed": bc or None,
    "adb": adb or None,
    "release": release or None,
    "prepared": prepared or None,
    "setup": setup,
    "adb_keys": int(keys or 0),
}))
' "$version" "$profile" "${unit:-unknown}" "$bc" "$adb" "$release" "$prepared" "$(setup_state)" "${keys:-0}"
}

DOCTOR_ISSUES=0
DOCTOR_WARNINGS=0
# test whether a unix socket path listens
unix_socket_listening() {
  awk -v p="$1" 'NR > 1 && $4 == "00010000" && $8 == p { found = 1 } END { exit !found }' "$PROC_NET_UNIX"
}

# log and count a doctor result
report() {
  local name="$1" status="$2"; shift 2
  case "$status" in
    fail) DOCTOR_ISSUES=$((DOCTOR_ISSUES + 1)) ;;
    warn) DOCTOR_WARNINGS=$((DOCTOR_WARNINGS + 1)) ;;
  esac
  log "  $name: $status -- $*"
}

# report the host flavor and architecture
check_platform() {
  local ubuntu_on="x86_64 aarch64" cachyos_on="x86_64" flavor arch
  arch=$(uname -m)
  flavor=$(host_flavor)
  if [[ "$flavor" == ubuntu && " $ubuntu_on " == *" $arch "* ]]; then
    report platform ok "Ubuntu 24.04 $arch"
  elif [[ "$flavor" == cachyos && " $cachyos_on " == *" $arch "* ]]; then
    report platform ok "CachyOS $arch"
  elif [[ "$flavor" == ubuntu ]]; then
    report platform fail "ubuntu 24.04 $arch is unsupported; Rhizo targets Ubuntu 24.04 on ${ubuntu_on/ / or }"
  else
    report platform fail "${flavor#unsupported:} $arch is unsupported; Rhizo targets Ubuntu 24.04 on" \
      "${ubuntu_on/ / or } and CachyOS on $cachyos_on"
  fi
}
# report whether the kernel config sets CONFIG_SECURITY_SELINUX=y
check_selinux_kconfig() {
  local src err rc=0
  if ! src=$(host_kconfig_source 2>&1); then
    report selinux-kconfig fail "$src: cannot confirm CONFIG_SECURITY_SELINUX=y"
    return
  fi
  err=$(host_kconfig_has SECURITY_SELINUX 2>&1) || rc=$?
  case $rc in
    0) report selinux-kconfig ok "CONFIG_SECURITY_SELINUX=y in $src" ;;
    1) report selinux-kconfig fail "$src does not set CONFIG_SECURITY_SELINUX=y" ;;
    *) report selinux-kconfig fail "cannot read $src${err:+ (${err//$'\n'/; })}" ;;
  esac
}
# report whether selinuxfs is mounted
check_selinuxfs() {
  local mode
  mode=$(selinux_mode) || { report selinuxfs fail "cannot read the SELinux mode (see above)"; return; }
  if [[ "$mode" == namespace ]]; then
    report selinuxfs skip "namespace mode: Android mounts selinuxfs in its namespace"
    return
  fi
  local lsm; lsm=$(cat "$RHIZO_LSM_FILE" 2>/dev/null)
  [[ ",$lsm," == *",selinux,"* ]] || return 0
  if [[ -e "$SELINUX_ENFORCE_FILE" ]]; then report selinuxfs ok "mounted at /sys/fs/selinux"
  else report selinuxfs fail "selinux is an active LSM and /sys/fs/selinux is not mounted:" \
         "see systemctl status rhizo-selinuxfs.service"; fi
}
# report the host render node
check_render_node() {
  local line why dri
  local tail_why=("devices.dri is on and needs a render node: install a GPU driver, or run 'sudo rhizo gpu off'")
  dri=$(read_dri 2>/dev/null) || dri=True
  if [[ "$dri" == Error:* ]]; then
    report render-node fail "cannot read devices.dri: ${dri#Error: }; every start is refused (gpu_driver_refused=host-policy-error)"
    return
  fi
  if [[ "$dri" == False ]]; then
    report render-node skip "devices.dri is off: Android renders in software"
    return
  fi
  if ! line=$(bash "$GPU_RESOLVER" --node --env-file "$ETC_RHIZO/androidd.env" 2>/dev/null); then
    why=$(bash "$GPU_RESOLVER" --node --env-file "$ETC_RHIZO/androidd.env" 2>&1 >/dev/null | tail -1)
    report render-node fail "${why#*detect-gpu-driver: };" "${tail_why[@]}"
  elif [[ -c "${line%% *}" ]]; then report render-node ok "${line%% *} (${line##* })"
  else report render-node fail "no ${line%% *};" "${tail_why[@]}"; fi
}
# report stream.enabled with devices.dri off
check_stream_gpu() {
  local dri stream
  dri=$(read_dri 2>/dev/null) || return 0
  [[ "$dri" == False ]] || return 0
  stream=$(read_capability stream.enabled 2>/dev/null) || return 0
  [[ "$stream" == True ]] || return 0
  report stream warn "stream.enabled is on and devices.dri is off: each start withholds the stream (stream_refused=devices-dri-off)"
}
# report the first swap device
check_swap() {
  local dev
  if ! dev=$(awk 'NR > 1 {print $1; exit}' "$PROC_SWAPS" 2>&1); then
    report swap warn "cannot read $PROC_SWAPS: $dev"
  elif [[ -n "$dev" ]]; then report swap ok "$dev"
  else report swap warn "no swap device"; fi
}
# report a bootloader read failure
bootloader_unread() {
  local why="${2//$'\n'/; }"
  if (( $1 == 2 && EUID != 0 )); then
    report bootloader warn "$why: run 'sudo rhizo doctor' to check the bootloader config"
  else
    report bootloader fail "$why"
  fi
}
# report the bootloader's rhizo cmdline tokens
check_bootloader() {
  local kind own gen missing over rtok eff src why=""
  kind=$(bootloader_kind 2>&1) || { bootloader_unread $? "$kind"; return; }
  own=$(bootloader_own_tokens "$kind" 2>&1) || { bootloader_unread $? "$own"; return; }
  if [[ -z "$own" ]]; then
    report bootloader warn "rhizo's cmdline tokens are not configured: run 'rhizo install'"
    return
  fi
  gen=$(bootloader_generated "$kind" 2>&1) || { bootloader_unread $? "$gen"; return; }
  missing=$(bootloader_missing "$kind" "${own//$'\n'/ }" 2>&1) || { bootloader_unread $? "$missing"; return; }
  if [[ -n "$missing" ]]; then report bootloader warn "$kind: $gen lacks:$missing; run 'rhizo install'"; return; fi
  if [[ "$(host_flavor)" != ubuntu ]]; then
    over=$(bootloader_overridden "$kind" "${own//$'\n'/ }" 2>&1) || { bootloader_unread $? "$over"; return; }
    while read -r rtok eff; do
      [[ -n "$rtok" ]] || continue
      src=$(bootloader_token_source "$kind" "$eff" 2>&1) || { bootloader_unread $? "$src"; return; }
      [[ -n "$src" ]] || src="the host's own configuration"
      why+="${why:+; }$(bl_override_why "$rtok" "$eff" "$src")"
    done <<<"$over"
  fi
  if [[ -z "$why" ]]; then report bootloader ok "$kind: $gen carries every token"
  else report bootloader warn "$kind: $gen carries every token, but ${why//$'\n'/ and }"; fi
}
# report whether SELinux is active
check_selinux_active() {
  local mode
  mode=$(selinux_mode) || { report selinux-active fail "cannot read the SELinux mode (see above)"; return; }
  if [[ "$mode" == namespace ]]; then
    check_selinux_namespace
    return
  fi
  local lsm; lsm=$(cat "$RHIZO_LSM_FILE" 2>/dev/null)
  if [[ ",$lsm," != *",selinux,"* ]]; then
    report selinux-active warn "selinux is not the active LSM (lsm=${lsm:-<securityfs not mounted>}): run 'rhizo install' and reboot"
  elif [[ "$(host_flavor)" != ubuntu ]] && bl_lsm_bpf_first "$lsm"; then
    report selinux-active fail "bpf precedes selinux in the active LSM list ($lsm): run 'rhizo install' and reboot"
  else
    report selinux-active ok "selinux is the active LSM (lsm=$lsm, enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null || echo '?'))"
  fi
}

# report the SELinux namespace mode state
check_selinux_namespace() {
  local helper="$LIB_DIR/rhizo-selinux-mode" env=(--env-file "$ETC_RHIZO/androidd.env") mode why
  IFS=$'\t' read -r mode why <<<"$("$helper" "${env[@]}" --mode-and-why)"
  case "$mode" in
    namespace)
      report selinux-active ok "SELinux namespace mode: kernel $(uname -r), Landlock ABI $("$helper" --landlock-abi)"
      local host_state host_rc=0
      host_state=$("$helper" --host-state) || host_rc=$?
      if [[ $host_rc -eq 0 && -n "$host_state" ]]; then
        report host-selinux ok "host SELinux $host_state: Rhizo leaves it as found"
      else
        report host-selinux warn "$helper --host-state exited $host_rc${host_state:+ printing '$host_state'}"
      fi ;;
    refuse:kernel-has-no-selinux-namespaces)
      report selinux-active warn "$why ($mode)" ;;
    *)
      report selinux-active fail "${why:-$helper named no reason} (${mode:-no answer from $helper})" ;;
  esac
}

# report rhizo-policy.service's state
check_policy_unit() {
  local mode
  mode=$(selinux_mode) || { report policy-unit fail "cannot read the SELinux mode (see above)"; return; }
  if [[ "$mode" == namespace ]]; then
    report policy-unit skip "namespace mode: the host loads no policy"
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    report policy-unit warn "no systemctl: cannot read rhizo-policy.service's state"
    return
  fi
  local enabled; enabled=$(systemctl is-enabled rhizo-policy.service 2>/dev/null)
  case "$enabled" in
    ""|not-found)
      report policy-unit warn "rhizo-policy.service is not installed: run 'rhizo install'"
      return
      ;;
    masked|masked-runtime)
      report policy-unit warn "rhizo-policy.service is $enabled ('$(policy_status_line)', enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null || echo '?')): run 'systemctl unmask rhizo-policy.service' and reboot"
      return
      ;;
  esac
  if [[ ! -e "$SELINUX_ENFORCE_FILE" ]]; then
    report policy-unit warn "SELinux is not the active LSM on this boot (no $SELINUX_ENFORCE_FILE): rhizo-policy.service skipped"
    return
  fi
  local state; state=$(systemctl is-active rhizo-policy.service 2>/dev/null)
  case "$state" in
    active)
      local pline enforce
      pline=$(policy_status_line)
      enforce=$(cat "$SELINUX_ENFORCE_FILE" 2>/dev/null || echo '?')
      if grep -qs '^RHIZO_PERMISSIVE=1' /etc/rhizo/androidd.env 2>/dev/null; then
        report policy-unit ok "rhizo-policy.service is active under RHIZO_PERMISSIVE=1 ('$pline', enforce=$enforce)"
      elif [[ "$pline" == loaded-at-boot* && "$enforce" == 1 ]]; then
        report policy-unit ok "rhizo-policy.service is active: $pline, enforce=$enforce"
      else
        report policy-unit fail "rhizo-policy.service is active and loaded no verified policy this boot ('$pline', enforce=$enforce): see /var/log/rhizo/policy.log"
      fi
      ;;
    failed)
      report policy-unit fail "rhizo-policy.service failed: no Android policy loaded at boot; see /var/log/rhizo/policy.log"
      ;;
    *)
      report policy-unit fail "rhizo-policy.service is '$state' and '$enabled', not active"
      ;;
  esac
}

# report the account with uid 1000
check_uid1000() {
  local name; name=$(getent passwd 1000 2>/dev/null | cut -d: -f1)
  if [[ -z "$name" ]]; then
    report uid-1000 ok "free: 'rhizo install' creates a system account"
  else
    report uid-1000 ok "'$name' runs rhizo-app-events.service"
  fi
}
# report free space on /
check_disk_space() {
  local free_kb free_gb; free_kb=$(df -Pk / | awk 'NR==2{print $4}')
  free_gb=$((free_kb / 1024 / 1024))
  if (( free_kb >= 8 * 1024 * 1024 )); then
    report disk-space ok "${free_gb}GiB free on /"
  else
    report disk-space warn "${free_gb}GiB free on /; the GSI, prepared tree and data template need 8GiB"
  fi
}
# report the GSI trees under GSI_ROOT
check_gsi_tree() {
  shopt -s nullglob
  local trees=("$GSI_ROOT"/gsi_system*)
  shopt -u nullglob
  if (( ${#trees[@]} )); then
    report gsi-tree ok "${#trees[@]} tree(s) under $GSI_ROOT: ${trees[*]}"
  else
    report gsi-tree warn "no GSI tree under $GSI_ROOT: run 'rhizo prepare'"
  fi
}
# report what the running kernel lacks
check_kernel() {
  local out
  if out=$("$TOOLS_DIR/kernel-check.sh" 2>&1); then
    report kernel ok "$(uname -r) has built-in binder, /dev/ashmem and /proc/config.gz"
  else
    report kernel warn "${out:-kernel-check.sh failed with no message}"
  fi
}
# report whether the running kernel's module tree exists
check_kernel_modules_tree() {
  local kver; kver=$(uname -r)
  if [[ -d "$KERNEL_MODULES_ROOT/$kver" ]]; then report kernel-modules-tree ok "$KERNEL_MODULES_ROOT/$kver"
  else report kernel-modules-tree warn "no $KERNEL_MODULES_ROOT/$kver: reboot into the installed kernel"; fi
}
# report the payload setup state
check_setup() {
  load_setup_state
  case "$SETUP_STATE" in
    done)           report setup ok "rhizo-prepare.service finished this payload's setup ($(tr '\n' ' ' < "$PREPARED_MARKER" 2>/dev/null))" ;;
    pending)        report setup warn "setup has not finished; see systemctl status rhizo-prepare.service" ;;
    pending-reboot) report setup warn "reboot to finish the install or upgrade" ;;
    refused)        report setup warn "refused ($SETUP_REASON): $SETUP_SENTENCE" ;;
    helper-failed)  report setup fail "$SETUP_SENTENCE" ;;
    install-failed) report setup fail "$(install_failed_note)" ;;
    configuring)    report setup warn "$(configuring_note)" ;;
  esac
}

# report package database and apt timer health
check_apt_health() {
  if [[ "$(host_flavor)" == cachyos ]]; then
    local out rc
    out=$(pacman -Dk 2>&1); rc=$?
    if (( rc == 0 )); then report pkg-health ok "pacman -Dk reports a consistent package database"
    else report pkg-health fail "pacman -Dk: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"; fi
    return
  fi
  if command -v dpkg >/dev/null 2>&1; then
    local audit audit_err audit_rc
    audit_err=$(mktemp)
    audit=$(dpkg --audit 2>"$audit_err"); audit_rc=$?
    local audit_stderr; audit_stderr=$(cat "$audit_err" 2>/dev/null)
    rm -f "$audit_err"
    if (( audit_rc > 1 )) || [[ -n "$audit_stderr" ]]; then
      report apt-health fail "dpkg --audit could not be trusted (rc=$audit_rc stderr='$(tr '\n' ' ' <<<"$audit_stderr" | cut -c1-200)')"
    elif [[ -z "$audit" ]]; then
      report apt-health ok "dpkg --audit reports nothing (no half-installed or unconfigured packages)"
    else
      report apt-health fail "dpkg --audit is not empty: $(tr '\n' ' ' <<<"$audit" | cut -c1-200)"
    fi
  else
    report apt-health warn "no dpkg in PATH"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    local timer state masked=()
    for timer in apt-daily.timer apt-daily-upgrade.timer; do
      state=$(systemctl is-enabled "$timer" 2>/dev/null)
      case "$state" in
        masked|masked-runtime) masked+=("$timer") ;;
      esac
    done
    if (( ${#masked[@]} )); then
      report apt-timers warn "${masked[*]} masked: security updates are off"
    else
      report apt-timers ok "apt-daily.timer and apt-daily-upgrade.timer are not masked"
    fi
  else
    report apt-timers warn "no systemctl: cannot read apt-daily*.timer state"
  fi
}

# report rhizo-server-idle.service state
check_idle_detector() {
  local idle_stop_s
  idle_stop_s=$(read_capability server.idle_stop_s 2>/dev/null) || idle_stop_s=600
  if [[ "$idle_stop_s" == 0 ]]; then
    report idle-detector ok "server.idle_stop_s=0: idle stop is off"
    return
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    report idle-detector warn "no systemctl: cannot read $SERVER_IDLE_UNIT's state"
    return
  fi
  if [[ "$(systemctl is-active androidd.service 2>/dev/null)" != active ]]; then
    report idle-detector warn "androidd.service is not running: $SERVER_IDLE_UNIT not checked"
    return
  fi
  local idle_state; idle_state=$(systemctl is-active "$SERVER_IDLE_UNIT" 2>/dev/null)
  if [[ "$idle_state" == active ]]; then
    report idle-detector ok "$SERVER_IDLE_UNIT is active: idle_stop_s=$idle_stop_s"
  else
    report idle-detector fail "$SERVER_IDLE_UNIT is '${idle_state:-<none>}', not active, with androidd.service running: check nf_conntrack_netlink, then run 'systemctl restart $SERVER_IDLE_UNIT'"
  fi
}

# report each desktop service state
check_desktop_daemons() {
  if ! command -v systemctl >/dev/null 2>&1; then
    report desktop-daemons warn "no systemctl: cannot read the desktop services' state"
    return
  fi
  local androidd_active=0
  [[ "$(systemctl is-active androidd.service 2>/dev/null)" == active ]] && androidd_active=1
  local profile; profile=$(read_capability rhizo.profile 2>/dev/null) || profile=""
  local audiod_active=0
  local unit state
  for unit in rhizo-deskd.service rhizo-audiod.service rhizo-displayd.service rhizo-keymapd.service; do
    state=$(systemctl is-enabled "$unit" 2>/dev/null)
    case "$state" in
      masked|masked-runtime)
        if [[ "$profile" == server ]]; then
          report "$unit" ok "masked by the server profile (rhizo.profile=server)"
        else
          report "$unit" fail "is masked under rhizo.profile=${profile:-<unreadable>}, not server"
        fi
        continue
        ;;
    esac
    if [[ "$unit" == rhizo-audiod.service ]]; then
      local audio_out; audio_out=$(read_capability audio.out 2>/dev/null) || audio_out=True
      if [[ "$audio_out" != True ]]; then
        report "$unit" ok "audio.out is off: the unit's ExecCondition skips it"
        continue
      fi
    fi
    if [[ "$unit" == rhizo-deskd.service ]]; then
      local gate_rc=0
      "$TOOLS_DIR/capability-allowed.sh" --any $DESK_BRIDGE_CAPABILITIES >/dev/null 2>&1 || gate_rc=$?
      if (( gate_rc == 1 )); then
        report "$unit" ok "$DESK_BRIDGE_CAPABILITIES are all off: the unit's ExecCondition skips it"
        continue
      elif (( gate_rc != 0 )); then
        report "$unit" fail "$TOOLS_DIR/capability-allowed.sh --any $DESK_BRIDGE_CAPABILITIES exited $gate_rc"
        continue
      fi
    fi
    if (( ! androidd_active )); then
      report "$unit" warn "androidd.service is not running: $unit not checked"
      continue
    fi
    local unit_state; unit_state=$(systemctl is-active "$unit" 2>/dev/null)
    if [[ "$unit_state" == active ]]; then
      report "$unit" ok "active"
      [[ "$unit" == rhizo-audiod.service ]] && audiod_active=1
    else
      report "$unit" fail "is '${unit_state:-<none>}', not active, with androidd.service running"
    fi
  done
  local owner uid
  owner=$(cat "$ETC_RHIZO/desktop-user" 2>/dev/null || true)
  if [[ -z "$owner" ]]; then
    report pipewire-socket warn "no $ETC_RHIZO/desktop-user: PipeWire socket not checked"
    return
  fi
  uid=$(id -u "$owner" 2>/dev/null || true)
  if [[ -z "$uid" ]]; then
    report pipewire-socket warn "'$owner' has no uid: PipeWire socket not checked"
    return
  fi
  if unix_socket_listening "/run/user/$uid/pipewire-0"; then
    report pipewire-socket ok "/run/user/$uid/pipewire-0 present for '$owner'"
  elif (( audiod_active )); then
    report pipewire-socket fail "/run/user/$uid/pipewire-0 absent for '$owner' with rhizo-audiod.service active"
  else
    report pipewire-socket warn "/run/user/$uid/pipewire-0 absent for '$owner'; rhizo-audiod.service is not active"
  fi
}

# report a policy.conf parse error
check_policy_parse() {
  local out rc
  out=$(policy_parse_error "$POLICY_CONF"); rc=$?
  if (( rc != 0 )); then
    report policy-parse fail "the policy parser exited $rc (see above)"
    return
  fi
  if [[ -n "$out" ]]; then
    report policy-parse fail "$out: every optional capability is off"
  else
    report policy-parse ok "$POLICY_CONF parses or is absent"
  fi
}

# run the preflight checks and print counts
cmd_doctor() {
  log "checking this host for Rhizo's requirements"
  load_host_libs
  check_platform
  check_policy_parse
  check_selinux_kconfig
  check_selinux_active
  check_bootloader
  check_selinuxfs
  check_swap
  check_render_node
  check_stream_gpu
  check_policy_unit
  check_uid1000
  check_disk_space
  check_gsi_tree
  check_kernel
  check_kernel_modules_tree
  check_setup
  check_apt_health
  local profile; profile=$(read_capability rhizo.profile 2>/dev/null) || profile=desktop
  if [[ "$profile" == server ]]; then
    check_idle_detector
    local keys=0 adb
    [[ -r "$ADB_KEYS_FILE" ]] && keys=$(grep -cv '^[[:space:]]*$' "$ADB_KEYS_FILE" 2>/dev/null)
    adb=$(sandbox_adb_endpoint)
    log "  adb endpoint: ${adb:-not running}"
    log "  registered adb keys: ${keys:-0}"
  fi
  check_desktop_daemons
  if (( DOCTOR_ISSUES > 0 )); then
    echo "RHIZO_DOCTOR_ISSUES issues=$DOCTOR_ISSUES warnings=$DOCTOR_WARNINGS"
  else
    echo "RHIZO_DOCTOR_OK warnings=$DOCTOR_WARNINGS"
  fi
}

# run a command in the sandbox with rhizo-probed
android_sh() {
  /usr/bin/python3 "$PROBE_CLIENT" "${3:-$PROBE_SOCK}" "${2:-30}" \
    "export PATH=/system/bin:/system/xbin:/vendor/bin; $1"
}

require_probe_client() {
  [[ -r "$PROBE_CLIENT" ]] \
    || app_fail "no $PROBE_CLIENT"
}

# run a command line in the sandbox
cmd_shell() {
  cli_root_ok \
    || die "shell must run as root"
  resolve_instance_selector "$@"
  set -- "${RESOLVED_ARGS[@]}"
  [[ "${1:-}" == "--" ]] || die "shell takes -- <command...>"
  shift
  [[ $# -ge 1 ]] || die "shell takes a command after --"
  require_probe_client
  /usr/bin/python3 "$PROBE_CLIENT" "$PROBE_SOCK" 60 \
    "export PATH=/system/bin:/system/xbin:/vendor/bin; $*"
}

PKG_LIST=""
# load pm's package list into PKG_LIST
load_package_list() {
  local flag="${1:-}" out rc noise
  out=$(android_sh "pm list packages $flag" 30); rc=$?
  (( rc == 0 )) || app_fail "pm list packages $flag exited $rc over $PROBE_SOCK: ${out:0:200}"
  noise=$(grep -v '^package:' <<<"$out" | grep -v '^[[:space:]]*$')
  [[ -z "$noise" ]] || app_fail "pm list packages $flag printed non-package output: ${noise:0:200}"
  PKG_LIST=$(grep '^package:' <<<"$out" | sed 's/^package://' | sort)
}

# print the Name= of a package's desktop entry
entry_label() {
  local f="$ENTRY_DIR/rhizo-$1.desktop"
  [[ -r "$f" ]] || return 0
  sed -n 's/^Name=//p' "$f" | head -1
}

check_package_name() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.]*$ ]] || app_fail "'$1' is not a package name"
}

BADGING=""
# read an APK's badging with aapt2 into BADGING
load_badging() {
  local rc
  [[ -x "$TOOLS_DIR/aapt2" ]] \
    || app_fail "no executable $TOOLS_DIR/aapt2"
  BADGING=$("$TOOLS_DIR/aapt2" dump badging "$1" 2>&1); rc=$?
  (( rc == 0 )) || app_fail "aapt2 dump badging $1 exited $rc: ${BADGING:0:300}"
}

# refuse a start before setup completes
refuse_start_without_setup() {
  local state; load_setup_state; state=$SETUP_STATE
  [[ "$state" == install-failed ]] && app_fail "$(install_failed_note)"
  [[ "$state" == configuring ]] && app_fail "$(configuring_note)"
  [[ "$state" == refused ]] && app_fail "setup refused on this boot (refuse:$SETUP_REASON): $SETUP_SENTENCE"
  [[ "$state" == helper-failed ]] && app_fail "setup state unknown: $SETUP_SENTENCE"
  [[ "$state" == pending-reboot ]] || return 0
  if selinux_mode_is namespace; then
    app_fail "setup is pending a reboot: reboot into the Rhizo kernel to finish the install or upgrade"
  fi
  if [[ "$(cat "$SELINUX_ENFORCE_FILE" 2>/dev/null)" == 1 ]]; then
    app_fail "setup is pending a reboot: reboot to finish the upgrade"
  fi
  app_fail "setup is pending a reboot: reboot to finish the install"
}

# check the SELinux mode helper result
refuse_start_without_mode() {
  local helper="$LIB_DIR/rhizo-selinux-mode" env=(--env-file "$ETC_RHIZO/androidd.env") out mode why
  out=$("$helper" "${env[@]}" --mode-and-why) || app_fail "cannot read this boot's SELinux mode from $helper (exit $?, see above)"
  IFS=$'\t' read -r mode why <<<"$out"
  [[ "$mode" == refuse:* ]] || return 0
  app_fail "${why:-$helper refused this boot} ($mode)"
}

# print RHIZO_PERMISSIVE from the instance env files
configured_permissive() {
  local f v value="" files=("$ETC_RHIZO/androidd.env")
  (( RHIZO_SANDBOX_ID == 0 )) || files+=("$INSTANCES_ENV_DIR/$RHIZO_SANDBOX_ID.env")
  for f in "${files[@]}"; do
    [[ -r "$f" ]] || continue
    v=$(sed -n "s/^RHIZO_PERMISSIVE=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}\$/\1/p" "$f" | tail -1)
    [[ -n "$v" ]] && value="$v"
  done
  printf '%s\n' "$value"
}
# test a start verdict against RHIZO_PERMISSIVE
start_verdict_ok() {
  [[ "$1" == enforced ]] && return 0
  [[ "$1" == permissive && "$(configured_permissive)" == 1 ]]
}

# start the instance unit and wait for boot
start_sandbox() {
  local state t0 deadline init="" bc="" out="" unit ns=0 verdict="" note=""
  require_probe_client
  unit=$(instance_unit "$RHIZO_SANDBOX_ID")
  selinux_mode_is namespace && ns=1
  if [[ -z "$(sandbox_init_pid)" ]]; then
    state=$(systemctl is-active "$unit" 2>/dev/null)
    if [[ "$state" == activating ]]; then
      log "$unit is already starting: waiting for it"
    else
      refuse_start_without_setup
      refuse_start_without_mode
      refuse_start_mid_switch
      systemctl start "$unit" \
        || app_fail "$(policy_refusal_note "$unit")systemctl start $unit failed (unit state: $(systemctl is-active "$unit" 2>/dev/null))"
    fi
  fi
  t0=$(date +%s)
  deadline=$(( t0 + 300 ))
  log "waiting up to 300s for sys.boot_completed=1 from $unit over $PROBE_SOCK"
  while (( $(date +%s) < deadline )); do
    if (( ns )); then
      verdict=$(start_verdict "$unit") || app_fail "cannot read the SELinux mode while waiting for $unit"
      [[ "$verdict" == refused:* ]] \
        && app_fail "Android's SELinux namespace start was refused: ${verdict#refused:} ($unit is $(systemctl is-active "$unit" 2>/dev/null))"
      note=", SELinux namespace verdict ${verdict:-not yet written}"
    fi
    init=$(sandbox_init_pid)
    if [[ -n "$init" ]]; then
      out=$(android_sh "getprop sys.boot_completed" 10 2>&1)
      bc="${out//[[:space:]]/}"
      if [[ "$bc" == 1 ]] && { (( ! ns )) || start_verdict_ok "$verdict"; }; then
        log "$unit reported sys.boot_completed=1 after $(( $(date +%s) - t0 ))s$note"
        return 0
      fi
    else
      state=$(systemctl is-active "$unit" 2>/dev/null)
      [[ "$state" == inactive || "$state" == failed ]] \
        && app_fail "$(policy_refusal_note "$unit")$unit went $state with no 'init second_stage': see journalctl -u $unit and /var/log/rhizo/supervisor.log"
    fi
    sleep 1
  done
  [[ -n "$init" ]] \
    || app_fail "$(policy_refusal_note "$unit")no 'init second_stage' 300s after the start ($unit is $(systemctl is-active "$unit" 2>/dev/null))"
  (( ns )) && [[ "$bc" == 1 ]] \
    && app_fail "Android reported sys.boot_completed=1 with SELinux namespace verdict '${verdict:-<none>}', not enforced, after 300s ($unit is $(systemctl is-active "$unit" 2>/dev/null))"
  out="${out//$'\n'/ }"
  out="${out:-<none>}"
  app_fail "init second_stage is running but sys.boot_completed never read 1 within 300s (last read '${out:0:200}', $unit is $(systemctl is-active "$unit" 2>/dev/null))"
}

# start the selected instance and wait for boot
cmd_start() {
  resolve_instance_selector "$@"
  start_sandbox
  log "the sandbox is up and sys.boot_completed is 1"
}

# stop the selected instance unit
cmd_stop() {
  cli_root_ok || die "stop must run as root"
  resolve_instance_selector "$@"
  set -- "${RESOLVED_ARGS[@]}"
  [[ $# -eq 0 ]] || die "stop takes no arguments but -i <id>"
  local unit state
  unit=$(instance_unit "$RHIZO_SANDBOX_ID")
  if (( RHIZO_SANDBOX_ID != 0 )) && [[ ! -s "$ETC_RHIZO/instances/$RHIZO_SANDBOX_ID.env" ]]; then
    state=$(systemctl is-active "$unit" 2>/dev/null)
    case "$state" in
      ""|inactive|failed)
        die "instance $RHIZO_SANDBOX_ID is not configured: no $ETC_RHIZO/instances/$RHIZO_SANDBOX_ID.env ('rhizo" \
            "instance add $RHIZO_SANDBOX_ID' makes one)" ;;
    esac
    log "$unit is $state with no $ETC_RHIZO/instances/$RHIZO_SANDBOX_ID.env"
  fi
  log "stopping $unit"
  systemctl stop "$unit" || die "systemctl stop $unit failed (unit state: $(systemctl is-active "$unit" 2>/dev/null))"
  state=$(systemctl is-active "$unit" 2>/dev/null)
  [[ "$state" == inactive || "$state" == failed ]] \
    || die "systemctl stop $unit returned 0 but the unit is '${state:-<none>}', not inactive"
  log "$unit is $state"
}

# print each package with label and third_party flag
cmd_app_list() {
  local third all pkg label n=0
  require_probe_client
  load_package_list -3; third="$PKG_LIST"
  load_package_list;    all="$PKG_LIST"
  [[ -n "$all" ]] || app_fail "pm list packages named no package at all"
  while IFS= read -r pkg; do
    [[ -n "$pkg" ]] || continue
    label=$(entry_label "$pkg")
    [[ -n "$label" ]] || label="$pkg"
    if grep -qxF "$pkg" <<<"$third"; then
      printf '%s\t%s\tthird_party=1\n' "$pkg" "$label"
    else
      printf '%s\t%s\tthird_party=0\n' "$pkg" "$label"
    fi
    n=$((n + 1))
  done <<<"$all"
  echo "RHIZO_APP list=$n"
}

INBOX_FILE=""
INBOX_SANDBOX_FILE=""
# remove the staged inbox APK
remove_inbox_file() {
  [[ -n "$INBOX_FILE" ]] || return 0
  rm -f "$INBOX_FILE"
  INBOX_FILE=""
}

# copy an APK into the sandbox inbox
stage_into_inbox() {
  local src="$1" nonce label mode
  [[ -r "$src" ]] || app_fail "cannot read $src"
  [[ -d "$INBOX_HOST_DIR" ]] \
    || app_fail "no $INBOX_HOST_DIR: the sandbox has not booted"
  nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  [[ ${#nonce} == 16 ]] || app_fail "could not read 8 random bytes for an inbox name"
  mode=$(label_write_mode) || app_fail "cannot tell whether $src needs an inbox label"
  label=-
  [[ "$mode" == namespace ]] && label="$INBOX_LABEL"
  /usr/bin/python3 "$LIB_DIR/inbox_stage.py" "$RUN_ROOT" "$nonce.apk" "$src" "$label" "$(stat -L -c %s -- "$src")" \
    || app_fail "cannot stage $src into $INBOX_HOST_DIR/$nonce.apk"
  INBOX_FILE="$INBOX_HOST_DIR/$nonce.apk"
  INBOX_SANDBOX_FILE="$INBOX_SANDBOX_DIR/$nonce.apk"
}

# install an APK with pm
cmd_app_install() {
  require_probe_client
  trap remove_inbox_file EXIT
  case "${1:-}" in
    --from-inbox)
      INBOX_SANDBOX_FILE="${2:-}"
      [[ "$INBOX_SANDBOX_FILE" =~ ^/data/rhizo_inbox/[0-9a-f]{16}\.apk$ ]] \
        || app_fail "--from-inbox takes a path the broker wrote, not '${2:-<empty>}'"
      INBOX_FILE="$INBOX_HOST_DIR/$(basename "$INBOX_SANDBOX_FILE")"
      [[ -r "$INBOX_FILE" ]] || app_fail "no $INBOX_FILE"
      ;;
    "")
      app_fail "app install takes an .apk file" ;;
    *)
      stage_into_inbox "$1" ;;
  esac

  load_badging "$INBOX_FILE"
  local pkg label
  pkg=$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$BADGING" | head -1)
  [[ -n "$pkg" ]] || app_fail "aapt2 dump badging named no package in $INBOX_FILE"
  check_package_name "$pkg"

  load_package_list; local before="$PKG_LIST"
  local out rc
  out=$(android_sh "pm install -r --user 0 $INBOX_SANDBOX_FILE" 300); rc=$?
  (( rc == 0 )) || app_fail "pm install exited $rc over $PROBE_SOCK: ${out:0:300}"
  grep -qx 'Success' <<<"$out" || app_fail "pm install did not print a literal Success line: ${out:0:300}"
  load_package_list; local after="$PKG_LIST"
  grep -qxF "$pkg" <<<"$after" \
    || app_fail "pm install printed Success but $pkg is not in pm list packages afterwards"
  if grep -qxF "$pkg" <<<"$before"; then
    log "replaced the installed $pkg"
  else
    log "newly present packages: $(comm -13 <(echo "$before") <(echo "$after") | tr '\n' ' ')"
  fi

  label=$(entry_label "$pkg")
  [[ -n "$label" ]] || label=$(sed -n "s/^application-label:'\(.*\)'\$/\1/p" <<<"$BADGING" | head -1)
  [[ -n "$label" ]] || label="$pkg"
  echo "RHIZO_APP installed=$pkg label=$(printf '%s' "$label" | base64 -w0)"
}

# uninstall a third-party package with pm
cmd_app_remove() {
  local pkg="${1:-}" out rc
  require_probe_client
  [[ -n "$pkg" ]] || app_fail "app remove takes a package name"
  check_package_name "$pkg"
  load_package_list -3
  grep -qxF "$pkg" <<<"$PKG_LIST" || app_fail "$pkg is not a third-party package"
  out=$(android_sh "pm uninstall --user 0 $pkg" 120); rc=$?
  (( rc == 0 )) || app_fail "pm uninstall exited $rc over $PROBE_SOCK: ${out:0:300}"
  grep -qx 'Success' <<<"$out" || app_fail "pm uninstall did not print a literal Success line: ${out:0:300}"
  load_package_list
  if grep -qxF "$pkg" <<<"$PKG_LIST"; then
    app_fail "pm uninstall printed Success and $pkg is in pm list packages"
  fi
  echo "RHIZO_APP removed=$pkg"
}

# dispatch an app subcommand
cmd_app() {
  resolve_instance_selector "$@"
  set -- "${RESOLVED_ARGS[@]}"
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)    cmd_app_list "$@" ;;
    install) cmd_app_install "$@" ;;
    remove)  cmd_app_remove "$@" ;;
    *)       app_fail "app takes list, install or remove, not '${sub:-<nothing>}'" ;;
  esac
}

# check the device-state directory
require_device_dir() {
  local real root
  [[ -L "$DEVICE_DIR" ]] \
    && die "RHIZO_DEVICE_STATE_DIR=$DEVICE_DIR is a symlink"
  real=$(realpath -m -- "$DEVICE_DIR") && root=$(realpath -m -- "$STATE_DIR") \
    || die "cannot resolve RHIZO_DEVICE_STATE_DIR=$DEVICE_DIR or $STATE_DIR"
  [[ "${real%/*}" == "$root" && "${real##*/}" =~ ^device-state(-[0-9]+)?$ ]] \
    || die "RHIZO_DEVICE_STATE_DIR=$DEVICE_DIR is not a device-state directory directly under $STATE_DIR"
}
# merge readings into device-state.conf
set_device_state() {
  local state="$DEVICE_DIR/device-state.conf"
  local existing=() line key out=()
  [[ -f "$state" ]] && while IFS= read -r line; do existing+=("$line"); done < "$state"
  local -A newkv=()
  while [[ $# -gt 0 ]]; do newkv["$1"]="$2"; shift 2; done
  for line in "${existing[@]}"; do
    key="${line%%=*}"
    [[ -n "${newkv[$key]+x}" ]] && continue
    out+=("$line")
  done
  for key in "${!newkv[@]}"; do [[ -n "${newkv[$key]}" ]] && out+=("$key=${newkv[$key]}"); done
  require_device_dir
  mkdir -p "$DEVICE_DIR" || die "cannot create $DEVICE_DIR"
  local tmp; tmp=$(mktemp "$DEVICE_DIR/.device-state.XXXXXX") || die "cannot create a temp file under $DEVICE_DIR"
  printf '%s\n' "${out[@]}" > "$tmp" || die "cannot write $tmp"
  label_android_file "$tmp" "$DEVICE_STATE_LABEL" || { rm -f "$tmp"; die "cannot label $tmp $DEVICE_STATE_LABEL"; }
  chmod 0644 "$tmp" && mv -f "$tmp" "$state" || die "cannot install $tmp as $state"
}
# check a value against a number range
require_float_range() {
  /usr/bin/python3 -c '
import sys
try:
    v = float(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if float(sys.argv[2]) <= v <= float(sys.argv[3]) else 1)
' "$1" "$2" "$3" >/dev/null 2>&1 || die "$4 must be a number between $2 and $3, not '$1'"
}
# write a device reading file
device_bridge_write() {
  require_device_dir
  mkdir -p "$DEVICE_DIR" || die "cannot create $DEVICE_DIR"
  local tmp
  tmp=$(mktemp "$DEVICE_DIR/.$1.XXXXXX") || die "cannot create a temp file under $DEVICE_DIR"
  printf '%s' "$2" > "$tmp" || { rm -f "$tmp"; die "cannot write $DEVICE_DIR/$1"; }
  label_android_file "$tmp" "$DEVICE_STATE_LABEL" || { rm -f "$tmp"; die "cannot label $tmp $DEVICE_STATE_LABEL"; }
  chmod 0644 "$tmp" && mv -f "$tmp" "$DEVICE_DIR/$1" || { rm -f "$tmp"; die "cannot install $DEVICE_DIR/$1"; }
}
# write a sensor reading
cmd_device_set_sensor() {
  local which="${1:?device set sensor requires accel, gyro or light}"; shift
  case "$which" in
    accel|gyro)
      local x="${1:?$which requires <x> <y> <z>}" y="${2:?$which requires <x> <y> <z>}" \
            z="${3:?$which requires <x> <y> <z>}"
      require_float_range "$x" -1000 1000 "$which x"
      require_float_range "$y" -1000 1000 "$which y"
      require_float_range "$z" -1000 1000 "$which z"
      device_bridge_write "sensor-$which.conf" "x=$x
y=$y
z=$z
"
      log "$which x=$x y=$y z=$z written to $DEVICE_DIR/sensor-$which.conf"
      ;;
    light)
      local lux="${1:?light requires <lux>}"
      require_float_range "$lux" 0 200000 "light lux"
      device_bridge_write "sensor-light.conf" "lux=$lux
"
      log "light lux=$lux written to $DEVICE_DIR/sensor-light.conf"
      ;;
    *) die "device set sensor takes accel, gyro or light, not '$which'" ;;
  esac
}
# install an image as the device camera frame
cmd_device_set_camera() {
  local image="${1:?device set camera requires a path to an image file}"
  [[ -r "$image" ]] || die "cannot read $image"
  require_device_dir
  mkdir -p "$DEVICE_DIR" || die "cannot create $DEVICE_DIR"
  local tmp
  tmp=$(mktemp "$DEVICE_DIR/.camera.frame.XXXXXX") || die "cannot create a temp file under $DEVICE_DIR"
  cp -- "$image" "$tmp" || { rm -f "$tmp"; die "cannot copy $image"; }
  label_android_file "$tmp" "$DEVICE_STATE_LABEL" || { rm -f "$tmp"; die "cannot label $tmp $DEVICE_STATE_LABEL"; }
  chmod 0644 "$tmp" && mv -f "$tmp" "$DEVICE_DIR/camera.frame" || { rm -f "$tmp"; die "cannot install $DEVICE_DIR/camera.frame"; }
  log "camera frame $image written to $DEVICE_DIR/camera.frame"
}
# set a device reading
cmd_device_set() {
  local what="${1:?device set requires battery, thermal, gps, sensor or camera}"; shift
  case "$what" in
    battery)
      local pct="${1:?battery requires <pct> <charging|discharging>}"
      local state="${2:?battery requires <pct> <charging|discharging>}"
      [[ "$pct" =~ ^[0-9]+$ && "$pct" -le 100 ]] || die "battery level must be an integer 0-100, not '$pct'"
      case "$state" in
        charging|discharging) ;;
        *) die "battery state must be 'charging' or 'discharging', not '$state'" ;;
      esac
      set_device_state battery_level "$pct" battery_charging "$state"
      log "battery_level=$pct battery_charging=$state written to $DEVICE_DIR/device-state.conf"
      ;;
    thermal)
      local c="${1:?thermal requires <celsius>}"
      require_float_range "$c" -40 150 "thermal value"
      set_device_state skin_temp_c "$c"
      log "skin_temp_c=$c written to $DEVICE_DIR/device-state.conf"
      ;;
    gps)
      (( $# <= 3 )) || die "gps takes <lat> <lon> [alt], not '$*'"
      local lat="${1:?gps requires <lat> <lon> [alt]}" lon="${2:?gps requires <lat> <lon> [alt]}" alt="${3:-}"
      require_float_range "$lat" -90 90 "gps latitude"
      require_float_range "$lon" -180 180 "gps longitude"
      [[ -z "$alt" ]] || require_float_range "$alt" -1000 30000 "gps altitude"
      set_device_state gnss_lat "$lat" gnss_lon "$lon" gnss_alt "$alt"
      log "gnss_lat=$lat gnss_lon=$lon gnss_alt=${alt:-none} written to $DEVICE_DIR/device-state.conf"
      ;;
    sensor) cmd_device_set_sensor "$@" ;;
    camera) cmd_device_set_camera "$@" ;;
    *) die "device set takes battery, thermal, gps, sensor or camera, not '$what'" ;;
  esac
}
# dispatch device set for the selected instance
cmd_device() {
  resolve_instance_selector "$@"
  set -- "${RESOLVED_ARGS[@]}"
  local sub="${1:?device requires a subcommand (set)}"; shift
  case "$sub" in
    set) cmd_device_set "$@" ;;
    *)   die "device takes 'set', not '$sub'" ;;
  esac
}


# test a line for an adb public key
is_valid_adb_pubkey_line() {
  local key; key=$(awk '{print $1}' <<<"$1")
  [[ "$key" == QAAA* ]] || return 1
  [[ "$key" =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
  (( ${#key} >= 200 )) || return 1
  return 0
}

# print a key's adb MD5 fingerprint
fingerprint_adb_key() {
  printf '%s' "$1" | base64 -d 2>/dev/null | md5sum | awk '{print $1}' \
    | sed 's/\(..\)/\1:/g; s/:$//' | tr 'a-f' 'A-F'
}

# register adb keys from a file or stdin
cmd_adbkey_add() {
  local src="${1:-}" tmp added=0 line key
  [[ -n "$src" ]] || app_fail "adb-key add takes a file path or -"
  if [[ "$src" == "-" ]]; then
    tmp=$(mktemp) || app_fail "cannot create a temp file to read stdin into"
    cat > "$tmp" || app_fail "cannot read stdin"
  else
    [[ -r "$src" ]] || app_fail "cannot read $src"
    tmp="$src"
  fi
  mkdir -p "$ETC_RHIZO" || app_fail "cannot create $ETC_RHIZO"
  if [[ ! -f "$ADB_KEYS_FILE" ]]; then
    : > "$ADB_KEYS_FILE" || app_fail "cannot create $ADB_KEYS_FILE"
    chown root:root "$ADB_KEYS_FILE" 2>/dev/null
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line// }" ]] || continue
    is_valid_adb_pubkey_line "$line" \
      || app_fail "not an adb public key (expected a QAAA... base64 blob, optionally followed by a comment): ${line:0:40}"
    key=$(awk '{print $1}' <<<"$line")
    if grep -qF "$key" "$ADB_KEYS_FILE" 2>/dev/null; then
      log "already registered, skipping $(fingerprint_adb_key "$key")"
      continue
    fi
    printf '%s\n' "$line" >> "$ADB_KEYS_FILE" || app_fail "cannot write to $ADB_KEYS_FILE"
    added=$((added + 1))
    log "registered $(fingerprint_adb_key "$key")"
  done < "$tmp"
  [[ "$src" == "-" ]] && rm -f "$tmp"
  chmod 0640 "$ADB_KEYS_FILE"
  echo "RHIZO_ADBKEY added=$added"
}

# print each registered key's fingerprint and comment
cmd_adbkey_list() {
  local n=0 line key comment
  if [[ -r "$ADB_KEYS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "${line// }" ]] || continue
      key=$(awk '{print $1}' <<<"$line")
      comment=$(cut -sd' ' -f2- <<<"$line")
      printf '%s\t%s\n' "$(fingerprint_adb_key "$key")" "$comment"
      n=$((n + 1))
    done < "$ADB_KEYS_FILE"
  fi
  echo "RHIZO_ADBKEY list=$n"
}

# remove an adb key by fingerprint
cmd_adbkey_remove() {
  local target="${1:-}" line key removed=0 tmp
  [[ -n "$target" ]] || app_fail "adb-key remove takes a fingerprint"
  [[ -r "$ADB_KEYS_FILE" ]] || app_fail "no $ADB_KEYS_FILE: no key registered"
  tmp=$(mktemp) || app_fail "cannot create a temp file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line// }" ]] || continue
    key=$(awk '{print $1}' <<<"$line")
    if [[ "$(fingerprint_adb_key "$key")" == "${target^^}" ]]; then
      removed=$((removed + 1))
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$ADB_KEYS_FILE"
  if (( removed == 0 )); then
    rm -f "$tmp"
    app_fail "no registered key has fingerprint $target"
  fi
  cat "$tmp" > "$ADB_KEYS_FILE" || app_fail "cannot write to $ADB_KEYS_FILE"
  rm -f "$tmp"
  chmod 0640 "$ADB_KEYS_FILE"
  revoke_live_adb_key "$target"
  revoke_system_adb_key "$target"
  echo "RHIZO_ADBKEY removed=$removed"
}

# restore the live adb directory permissions
lock_live_adb_keys() {
  [[ -f "$LIVE_ADB_KEYS" ]] && { chown 1000:2000 "$LIVE_ADB_KEYS"; chmod 0640 "$LIVE_ADB_KEYS"; }
  chown 1000:2000 "$1" && chmod 02750 "$1"
}

# remove a key from /adb_keys and restart adbd
revoke_system_adb_key() {
  local target="${1^^}" init live tmp line key stripped=0 ns p killed=0
  init=$(sandbox_init_pid)
  [[ -n "$init" ]] || return 0
  live="$PROC_ROOT/$init/root/adb_keys"
  [[ -f "$live" ]] || return 0
  tmp=$(mktemp) || { log "no temp file: the running sandbox accepts $target until its next start"; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line// }" ]] || continue
    key=$(awk '{print $1}' <<<"$line")
    if [[ "$(fingerprint_adb_key "$key")" == "$target" ]]; then
      stripped=$((stripped + 1))
      continue
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$live"
  if (( stripped == 0 )); then
    rm -f "$tmp"
    return 0
  fi
  if ! cat "$tmp" > "$live"; then
    rm -f "$tmp"
    log "could not rewrite $live: the running sandbox accepts $target until its next start"
    return 1
  fi
  rm -f "$tmp"
  ns=$(readlink "$PROC_ROOT/$init/ns/pid" 2>/dev/null)
  for p in "$PROC_ROOT"/[0-9]*; do
    [[ "$(cat "$p/comm" 2>/dev/null)" == adbd && -n "$ns" && "$(readlink "$p/ns/pid" 2>/dev/null)" == "$ns" ]] || continue
    kill -KILL "${p##*/}" && killed=$((killed + 1))
  done
  if (( killed == 0 )); then
    log "revoked $target from the running sandbox's /adb_keys; no adbd to restart"
    return 1
  fi
  log "revoked $target from the running sandbox's /adb_keys and restarted adbd"
}

# remove a key from /data/misc/adb/adb_keys
revoke_live_adb_key() {
  local target="${1^^}" line key live_tmp stripped=0 dir
  dir=$(dirname "$LIVE_ADB_KEYS")
  [[ -d "$dir" ]] || return 0
  if ! chown 0:0 "$dir" || ! chmod 0700 "$dir"; then
    log "cannot open $dir: the running sandbox accepts $target until its next start"
    return 1
  fi
  if [[ ! -f "$LIVE_ADB_KEYS" ]]; then
    lock_live_adb_keys "$dir"
    return 0
  fi
  if ! chown 0:0 "$LIVE_ADB_KEYS" || ! chmod 0600 "$LIVE_ADB_KEYS" \
     || ! live_tmp=$(mktemp); then
    lock_live_adb_keys "$dir"
    log "cannot open $LIVE_ADB_KEYS: the running sandbox accepts $target until its next start"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line// }" ]] || continue
    key=$(awk '{print $1}' <<<"$line")
    if [[ "$(fingerprint_adb_key "$key")" == "$target" ]]; then
      stripped=$((stripped + 1))
      continue
    fi
    printf '%s\n' "$line" >> "$live_tmp"
  done < "$LIVE_ADB_KEYS"
  if (( stripped > 0 )); then
    if cat "$live_tmp" > "$LIVE_ADB_KEYS"; then
      log "revoked $target from the running sandbox's /data/misc/adb/adb_keys"
    else
      log "could not rewrite $LIVE_ADB_KEYS: the running sandbox accepts $target until its next start"
    fi
  fi
  rm -f "$live_tmp"
  lock_live_adb_keys "$dir"
}

# dispatch the adb-key subcommands
cmd_adbkey() {
  resolve_instance_selector "$@"
  set -- "${RESOLVED_ARGS[@]}"
  local sub="${1:-}"; shift || true
  case "$sub" in
    add|list|remove) cli_root_ok || app_fail "adb-key $sub must run as root" ;;
    *) app_fail "adb-key takes add, list or remove, not '${sub:-<nothing>}'" ;;
  esac
  case "$sub" in
    add)    cmd_adbkey_add "$@" ;;
    list)   cmd_adbkey_list "$@" ;;
    remove) cmd_adbkey_remove "$@" ;;
  esac
}

# print a percent-decoded argument
urldecode() {
  /usr/bin/python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "$1"
}

# print python's mimetypes guess for a path
host_mime_guess() {
  /usr/bin/python3 -c 'import mimetypes,sys;print(mimetypes.guess_type(sys.argv[1])[0] or "")' "$1"
}

# print the share row for a host path
share_row() {
  /usr/bin/python3 "$INSTALL_DIR/cli/print-share-row.py" "$1" "$2"
}

VIEW_URI=""
VIEW_MIME=""
# set VIEW_URI for a shared host path
translate_share() {
  local json row
  [[ -r "$TOOLS_DIR/hostfs.py" ]] \
    || app_fail "no $TOOLS_DIR/hostfs.py"
  json=$(/usr/bin/python3 "$TOOLS_DIR/hostfs.py" status --json --config /etc/rhizo/hostfs.conf)
  [[ -n "$json" ]] \
    || app_fail "hostfs.py status --json printed nothing: no folder is shared or the sandbox is down"
  row=$(share_row "$json" "$1")
  case "$row" in
    ERR\ *) app_fail "${row#ERR }" ;;
    "")     app_fail "$1 is not inside any shared folder; add it in /etc/rhizo/hostfs.conf" ;;
  esac
  VIEW_URI=$(cut -f3 <<<"$row")
}

# set VIEW_URI and VIEW_MIME for a host file
resolve_host_file() {
  local path raw="$1"
  [[ "${raw,,}" == file://* ]] && raw="${raw:7}"
  path=$(urldecode "$raw")
  path=$(realpath -- "$path")
  [[ -n "$path" && -e "$path" ]] || app_fail "$1 does not name a file on this host"
  translate_share "$path"
  VIEW_MIME=""
  if command -v xdg-mime >/dev/null 2>&1; then
    VIEW_MIME=$(xdg-mime query filetype "$path")
    VIEW_MIME="${VIEW_MIME%%;*}"
    VIEW_MIME="${VIEW_MIME//[[:space:]]/}"
  fi
  if [[ -z "$VIEW_MIME" ]]; then
    VIEW_MIME=$(host_mime_guess "$path")
    VIEW_MIME="${VIEW_MIME//[[:space:]]/}"
  fi
  [[ -n "$VIEW_MIME" ]] \
    || app_fail "neither xdg-mime nor python's mimetypes named a type for $path"
}

VIEW_ACT=""
# print the resolve-activity command for a link
resolve_activity_body() {
  local uri_b64 mime_b64 sel
  uri_b64=$(printf '%s' "$2" | base64 -w0)
  if [[ -n "${3:-}" ]]; then
    mime_b64=$(printf '%s' "$3" | base64 -w0)
    sel='-t "$(echo '"$mime_b64"' | toybox base64 -d)"'
  else
    sel='-c android.intent.category.BROWSABLE'
  fi
  printf 'cmd package resolve-activity --brief --user 0 -a android.intent.action.VIEW %s -d "$(echo %s | toybox base64 -d)" -p %s' \
    "$sel" "$uri_b64" "$1"
}

# set VIEW_ACT to the package's view activity
resolve_view_activity() {
  local pkg="$1" out rc comp
  require_probe_client
  out=$(android_sh "$(resolve_activity_body "$@")" 60); rc=$?
  (( rc == 0 )) || app_fail "cmd package resolve-activity exited $rc over $PROBE_SOCK: ${out:0:300}"
  comp=$(grep -oE "^${pkg//./\\.}/[^[:space:]]+" <<<"$out" | head -1)
  [[ -n "$comp" ]] || app_fail "$pkg declares no activity for ${3:-$2} (resolve-activity said: ${out:0:200})"
  VIEW_ACT="${comp#*/}"
}

# set VIEW_ACT to the package's launcher activity
resolve_launcher_activity() {
  local pkg="$1" out rc comp
  require_probe_client
  out=$(android_sh "cmd package resolve-activity --brief --user 0 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p $pkg" 60); rc=$?
  (( rc == 0 )) || app_fail "cmd package resolve-activity exited $rc over $PROBE_SOCK: ${out:0:300}"
  comp=$(grep -oE "^${pkg//./\\.}/[^[:space:]]+" <<<"$out" | head -1)
  [[ -n "$comp" ]] || app_fail "$pkg has no launcher activity, or is not installed (resolve-activity said: ${out:0:200})"
  VIEW_ACT="${comp#*/}"
}

# print uri or path for a launch argument
launch_arg_kind() {
  if [[ "$1" =~ ^[A-Za-z][A-Za-z0-9+.-]*: && "${1,,}" != file:* ]]; then
    echo uri
  else
    echo path
  fi
}

# launch a package and print RHIZO_LAUNCHED
cmd_launch() {
  resolve_instance_selector "$@"
  set -- "${RESOLVED_ARGS[@]}"
  local pkg="${1:?package required}"
  shift
  local arg="" mime=""
  if [[ $# -gt 0 && "$1" != --* ]]; then arg="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mime)
        mime="${2:-}"
        [[ -n "$mime" ]] || app_fail "--mime takes a type"
        shift 2
        ;;
      *) app_fail "launch takes <package> [<url>|<path>] [--mime <type>], not '$1'" ;;
    esac
  done
  check_package_name "$pkg"
  local desktop="" cand act="" ask_android=0
  for cand in "$ENTRY_DIR/rhizo-$pkg.desktop" \
              "${XDG_DATA_HOME:-${HOME:-/root}/.local/share}/applications/rhizo-$pkg.desktop"; do
    if [[ -r "$cand" ]]; then desktop="$cand"; break; fi
  done
  if [[ -n "$desktop" ]]; then
    grep -q '^X-Rhizo-Activity=' "$desktop" \
      || app_fail "$desktop has no X-Rhizo-Activity= line"
    act=$(sed -n 's/^X-Rhizo-Activity=//p' "$desktop" | head -1)
    [[ -n "$act" || -n "$arg" ]] \
      || app_fail "$pkg has no launcher activity; it opens files and links only"
  elif [[ "$(read_capability rhizo.profile 2>/dev/null)" == server ]]; then
    ask_android=1
  else
    app_fail "no rhizo-$pkg.desktop under $ENTRY_DIR or \${XDG_DATA_HOME:-\$HOME/.local/share}/applications: run appsync.py, or install '$pkg'"
  fi
  [[ -x "$TOOLS_DIR/rhizo-launch.sh" ]] || app_fail "no $TOOLS_DIR/rhizo-launch.sh"

  if [[ -z "$(sandbox_init_pid)" ]]; then
    echo "RHIZO_SANDBOX starting=1"
    start_sandbox
  fi

  if [[ -n "$arg" ]]; then
    if [[ "$(launch_arg_kind "$arg")" == uri ]]; then
      [[ -z "$mime" ]] || app_fail "--mime applies to a host file, not the URL $arg"
      VIEW_URI="$arg"
    elif [[ -n "$mime" ]]; then
      VIEW_MIME="$mime"
      translate_share "$arg"
    else
      resolve_host_file "$arg"
    fi
    resolve_view_activity "$pkg" "$VIEW_URI" "$VIEW_MIME"
    act="$VIEW_ACT"
  elif (( ask_android )); then
    resolve_launcher_activity "$pkg"
    act="$VIEW_ACT"
  fi

  local before=0
  [[ -f "$LAUNCH_LOG" ]] && before=$(stat -c %s "$LAUNCH_LOG")
  "$TOOLS_DIR/rhizo-launch.sh" "$pkg" "$act" "$VIEW_URI" "$VIEW_MIME" &
  local child=$! rc
  wait "$child"; rc=$?
  (( rc == 3 )) && app_fail "reason=not-on-top pkg=$pkg -- $act is not the resumed activity on its display; see $LAUNCH_LOG"
  (( rc == 4 )) && app_fail "reason=launch-error pkg=$pkg -- am start failed for $act; see $LAUNCH_LOG"
  (( rc == 5 )) && app_fail "reason=process-died pkg=$pkg -- the process died before $act reached the top; see $LAUNCH_LOG"
  (( rc == 0 )) || app_fail "rhizo-launch.sh exited $rc for $pkg: see $LAUNCH_LOG"
  local line
  line=$(tail -c "+$((before + 1))" "$LAUNCH_LOG" \
         | grep -F "event=am_start_return pid=$child " | tail -1)
  [[ -n "$line" ]] \
    || app_fail "rhizo-launch.sh exited 0 but appended no am_start_return line for pid $child to $LAUNCH_LOG"
  echo "RHIZO_LAUNCHED pkg=$pkg display=$(sed -n 's/.* display=\([0-9]*\).*/\1/p' <<<"$line") cdisplay=$(sed -n 's/.* cdisplay=\([0-9]*\).*/\1/p' <<<"$line")"
}

check_template_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "'$1' is not a valid template name (letters, digits, '.', '_', '-' only, starting with a letter or digit)"
}
check_instance_id() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "instance id must be a number, got '$1'"
  (( 10#$1 >= 1 && 10#$1 <= 99 )) || die "instance id must be 1-99, not $1"
}
# print the newest template image for a name
find_template() {
  local f
  f=$(ls -t "$TEMPLATES_ROOT"/data-template."$1".*.img 2>/dev/null | head -1)
  echo "$f"
}

# snapshot an instance to a template
cmd_snapshot() {
  cli_root_ok || die "snapshot must run as root"
  take_dash_i "$@"
  local id="${TAKE_DASH_I_VALUE:-$GLOBAL_INSTANCE_ID}"
  set -- "${TAKE_DASH_I_ARGS[@]}"
  [[ -n "$id" ]] || die "snapshot needs -i <instance id>"
  validate_sandbox_id "$id"
  id=$(canon_id "$id")
  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) die "snapshot: unknown option '$1'" ;;
      *) [[ -z "$name" ]] || die "snapshot takes a name, got an extra argument '$1'"; name="$1"; shift ;;
    esac
  done
  [[ -n "$name" ]] || die "snapshot needs a template name: rhizo snapshot -i <id> <name>"
  check_template_name "$name"
  do_snapshot "$id" "$name"
}

# restore an instance's pre-snapshot state
restore_snapshot_state() {
  local id="$1" unit="$2" was_active="$3" was_frozen="$4" was_member="${5:-0}"
  if (( ! was_active )); then
    (( was_member )) && pool_member_add "$id"
    return 0
  fi
  systemctl start "$unit" \
    || die "systemctl start $unit failed after the snapshot"
  if (( was_frozen )); then
    wait_probe_socket "$id" 120 \
      || die "$unit restarted after the snapshot with no probe socket within 120s: see systemctl status $unit"
    wait_boot_completed "$id" 300 \
      || die "$unit restarted after the snapshot with no sys.boot_completed=1 within 300s: see systemctl status $unit"
    systemctl freeze "$unit" \
      || die "systemctl freeze $unit failed after the snapshot"
  fi
  (( was_member )) && pool_member_add "$id"
  return 0
}

SNAPSHOT_RESTORE_ARGS=()
# run the pending snapshot restore
snapshot_restore_trap() {
  (( ${#SNAPSHOT_RESTORE_ARGS[@]} )) || return 0
  local args=("${SNAPSHOT_RESTORE_ARGS[@]}")
  SNAPSHOT_RESTORE_ARGS=()
  log "restoring instance ${args[0]} to its state before the snapshot"
  restore_snapshot_state "${args[@]}"
}

# copy an instance's data.img to a template
do_snapshot() {
  local id name unit img
  id=$(canon_id "$1"); name="$2"
  unit=$(instance_unit "$id")
  img=$(instance_data_img "$id")
  [[ -s "$img" ]] || die "no data.img for instance $id at $img"

  local was_member=0
  pool_member_claim "$id" && was_member=1

  local was_active=0 was_frozen=0 freezer="" state=""
  state=$(systemctl is-active "$unit" 2>/dev/null)
  case "$state" in
    ""|inactive|failed) : ;;
    *) was_active=1 ;;
  esac
  trap snapshot_restore_trap EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  SNAPSHOT_RESTORE_ARGS=("$id" "$unit" "$was_active" 0 "$was_member")
  if (( was_active )); then
    freezer=$(systemctl show -p FreezerState --value "$unit" 2>/dev/null)
    if [[ "$freezer" == frozen ]]; then
      was_frozen=1
      SNAPSHOT_RESTORE_ARGS=("$id" "$unit" "$was_active" 1 "$was_member")
      log "unfreezing pool member $unit"
      systemctl thaw "$unit" || die "systemctl thaw $unit failed: data.img not copied"
    fi
    log "stopping $unit (state $state)"
    systemctl stop "$unit" || die "systemctl stop $unit failed: data.img not copied"
  fi
  sync -f -- "$img" || die "sync -f $img failed: data.img not copied"

  local key key12 out meta rc=0
  key=$(sha256sum "$img" | cut -d' ' -f1) || rc=$?
  (( rc == 0 )) || die "sha256sum $img failed"
  key12="${key:0:12}"
  mkdir -p "$TEMPLATES_ROOT" || die "cannot create $TEMPLATES_ROOT"
  out="$TEMPLATES_ROOT/data-template.$name.$key12.img"
  meta="$out.meta"

  if [[ -s "$out" && -f "$meta" ]] && grep -q "\"key\": \"$key12\"" "$meta"; then
    log "$out exists with a matching .meta"
  else
    cp --remove-destination --reflink=auto "$img" "$out.part" || die "cannot copy $img to $out.part"
    mv "$out.part" "$out" || die "cannot install $out"
    local release=a16 variant=user
    if [[ -s "$img.meta" ]]; then
      local m; m=$(sed -n 's/^release=//p' "$img.meta" | tail -1); [[ -n "$m" ]] && release="$m"
      m=$(sed -n 's/^variant=//p' "$img.meta" | tail -1); [[ -n "$m" ]] && variant="$m"
    fi
    printf '{"key": "%s", "name": "%s", "source_instance": "%s", "release": "%s", "variant": "%s"}\n' \
      "$key12" "$name" "$id" "$release" "$variant" > "$meta.part"
    mv "$meta.part" "$meta" || die "cannot install $meta"
    log "wrote $out (key=$key12)"
  fi

  snapshot_restore_trap
  trap - EXIT INT TERM HUP
  echo "RHIZO_SNAPSHOT name=$name key=$key12 path=$out"
}

# require the server profile above instance 0
check_server_profile_for_instance() {
  (( $(canon_id "$1") == 0 )) && return 0
  local profile
  profile=$(read_capability rhizo.profile) \
    || profile="unreadable ($POLICY_CONF, or rhizo.profile is not a registered capability)"
  [[ "$profile" == server ]] && return 0
  die "instance add $1 refused: rhizo.profile is $profile, not server; the server profile masks ${SERVER_MASKED_UNITS[*]}; run 'rhizo profile server' first"
}

cmd_instance_add() {
  cli_root_ok || die "instance add must run as root"
  [[ $# -ge 1 ]] || die "instance add needs an instance id: rhizo instance add <id> [--from <name>]"
  local id from=""
  check_instance_id "$1"
  id=$(canon_id "$1")
  shift
  check_server_profile_for_instance "$id"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="${2:-}"; [[ -n "$from" ]] || die "--from needs a template name"; shift 2 ;;
      *) die "instance add: unknown argument '$1'" ;;
    esac
  done
  [[ -z "$from" ]] || check_template_name "$from"
  do_instance_add "$id" "$from"
}

# write an instance's env file and data.img
do_instance_add() {
  local id from="$2" env_file img src
  id=$(canon_id "$1")
  env_file="$ETC_RHIZO/instances/$id.env"
  img=$(instance_data_img "$id")
  [[ -s "$env_file" ]] && die "instance $id is already configured: $env_file exists"

  src=""
  if [[ -n "$from" ]]; then
    src=$(find_template "$from")
    [[ -n "$src" ]] || die "no snapshot template '$from' under $TEMPLATES_ROOT: run 'rhizo snapshot -i <source-id> $from' first"
  fi

  mkdir -p "$ETC_RHIZO/instances" "$(dirname "$img")" || die "cannot create instance $id's directories"

  if [[ -n "$src" ]]; then
    log "copying $src to $img"
    cp --remove-destination --reflink=auto "$src" "$img.part" || die "cannot copy $src to $img.part"
    mv "$img.part" "$img" || die "cannot install $img"
    [[ -f "$src.meta" ]] && cp "$src.meta" "$img.meta"
  fi

  printf 'RHIZO_SANDBOX_ID=%s\n' "$id" > "$env_file.part" || die "cannot write $env_file.part"
  mv "$env_file.part" "$env_file" || die "cannot install $env_file"
  chmod 0644 "$env_file"

  echo "RHIZO_INSTANCE_ADDED id=$id env=$env_file data=$img from=${from:-none}"
}

# dispatch the instance subcommands
cmd_instance() {
  local sub="${1:-}"
  [[ -n "$sub" ]] || die "instance needs a subcommand: add, remove, allocate, release"
  shift
  case "$sub" in
    add)      cmd_instance_add "$@" ;;
    remove)   cmd_instance_remove "$@" ;;
    allocate) cmd_instance_allocate "$@" ;;
    release)  cmd_instance_release "$@" ;;
    *) die "instance takes add, remove, allocate or release, not '$sub'" ;;
  esac
}

cmd_instance_remove() {
  cli_root_ok || die "instance remove must run as root"
  [[ $# -ge 1 ]] || die "instance remove needs an instance id: rhizo instance remove <id> [--keep-data]"
  local id keep_data=0
  check_instance_id "$1"
  id=$(canon_id "$1")
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-data) keep_data=1; shift ;;
      *) die "instance remove: unknown argument '$1'" ;;
    esac
  done
  do_instance_remove "$id" "$keep_data"
}

# print the mounts inside a directory
mounts_reaching() {
  local dir; dir=$(realpath -m -- "$1")
  awk -v dir="$dir" '
    function unesc(s) { gsub(/\\040/, " ", s); gsub(/\\011/, "\t", s); gsub(/\\012/, "\n", s); gsub(/\\134/, "\\", s); return s }
    function within(p, d) { return p == d || index(p, d == "/" ? "/" : d "/") == 1 }
    function rel(p, m) { return p == m ? "" : m == "/" ? substr(p, 2) : substr(p, length(m) + 2) }
    function join(a, r) { return r == "" ? a : a == "/" ? "/" r : a "/" r }
    { n++; id[n] = $1; par[$1] = $2; dev[$1] = $3; root[$1] = unesc($4); mp[$1] = unesc($5) }
    END {
      for (i = 1; i <= n; i++) {
        m = id[i]
        if (within(dir, mp[m]) && (best == "" || length(mp[m]) >= length(mp[best]))) best = m
      }
      if (best == "") exit
      fs = join(root[best], rel(dir, mp[best]))
      for (i = 1; i <= n; i++) {
        m = id[i]; p = par[m]
        if (m == best) continue
        if ((dev[m] == dev[best] && within(root[m], fs)) ||
            ((p in mp) && dev[p] == dev[best] && within(join(root[p], rel(mp[m], mp[p])), fs))) {
          t = mp[m]; print gsub(/\//, "/", t) "\t" mp[m]
        }
      }
    }' "$PROC_MOUNTINFO" | sort -t $'\t' -k1,1nr | cut -f2-
}

# delete an instance
do_instance_remove() {
  local id keep_data="$2" env_file img dir unit data=absent env_state=absent staged=absent
  id=$(canon_id "$1")
  env_file="$ETC_RHIZO/instances/$id.env"
  img=$(instance_data_img "$id")
  dir=$(instance_dir "$id")
  unit=$(instance_unit "$id")

  pool_member_claim "$id" && log "removed instance $id from $POOL_MEMBERS"

  log "stopping $unit"
  systemctl thaw "$unit" 2>/dev/null
  systemctl stop "$unit" || die "systemctl stop $unit failed: instance $id not removed"

  if [[ -e "$env_file" ]]; then
    rm -f "$env_file" || die "cannot remove $env_file"
    env_state=removed
  fi
  if (( keep_data )); then
    [[ -e "$img" ]] && data=kept
  elif [[ -e "$img" ]]; then
    rm -f "$img" "$img.meta" || die "cannot remove $img"
    data=removed
  fi
  if [[ -n "$dir" && -d "$dir" ]]; then
    while read -r m; do
      [[ -n "$m" ]] || continue
      python3 "${RHIZO_HOSTOPS:-$LIB_DIR/hostops.py}" umount -b "$m" \
        || die "cannot unmount $m under instance $id's directory: instance $id not removed"
      log "unmounted $m under instance $id's directory"
    done < <(mounts_reaching "$dir")
  fi
  if [[ -n "$dir" && -e "$dir" ]]; then
    [[ -e "$dir/vendor" || -e "$dir/apex_override" ]] && staged=removed
    if (( keep_data )); then
      rm -rf "$dir/vendor" "$dir/apex_override" || die "cannot remove instance $id's staged trees under $dir"
    else
      rm -rf "$dir" || die "cannot remove $dir"
    fi
  fi

  echo "RHIZO_INSTANCE_REMOVED id=$id env=$env_state data=$data trees=$staged"
}

# print the host memory headroom in bytes
pool_host_headroom_bytes() {
  if [[ -n "${RHIZO_POOL_HEADROOM_BYTES:-}" ]]; then
    echo "$RHIZO_POOL_HEADROOM_BYTES"
    return 0
  fi
  PYTHONPATH="$LIB_DIR" /usr/bin/python3 -c '
from sandbox import core
print(max(core._host_mem_total_bytes() - core._MEM_RESERVE_BYTES, 0))
' 2>/dev/null
}

# print the refusal for an oversized pool
pool_refusal() {
  local k="$1" headroom="$2" need
  need=$(( k * POOL_INSTANCE_FLOOR_BYTES ))
  if (( need > headroom )); then
    printf 'pool size %d needs %d MB (footprint.deep-asleep-floor x %d) and this host has %d MB of headroom' \
      "$k" $(( need / 1024 / 1024 )) "$k" $(( headroom / 1024 / 1024 ))
  fi
}

# print the number of pool members
pool_member_count() {
  [[ -s "$POOL_MEMBERS" ]] || { echo 0; return 0; }
  grep -cve '^[[:space:]]*$' "$POOL_MEMBERS"
}
# print the number of reserved ids
pool_pending_count() {
  [[ -s "$POOL_PENDING" ]] || { echo 0; return 0; }
  grep -cve '^[[:space:]]*$' "$POOL_PENDING"
}

# print the lowest free instance id
pool_next_free_id() {
  local id
  for id in $(seq 1 99); do
    [[ -s "$ETC_RHIZO/instances/$id.env" ]] && continue
    if [[ -s "$POOL_MEMBERS" ]] && grep -qx "$id" "$POOL_MEMBERS"; then continue; fi
    if [[ -s "$POOL_PENDING" ]] && grep -qx "$id" "$POOL_PENDING"; then continue; fi
    echo "$id"
    return 0
  done
  return 1
}

# add an id to the pool members
pool_member_add() {
  local id; id=$(canon_id "$1")
  pool_lock
  [[ -f "$POOL_MEMBERS" ]] || : > "$POOL_MEMBERS"
  grep -qx "$id" "$POOL_MEMBERS" || echo "$id" >> "$POOL_MEMBERS"
  pool_unlock
}
# remove an id from the pool members
pool_member_claim() {
  local id rc=1; id=$(canon_id "$1")
  pool_lock
  if [[ -s "$POOL_MEMBERS" ]] && grep -qx "$id" "$POOL_MEMBERS"; then
    sed -i "\%^$id\$%d" "$POOL_MEMBERS"
    rc=0
  fi
  pool_unlock
  return "$rc"
}
# reserve an id in the pending file
pool_pending_add() {
  local id; id=$(canon_id "$1")
  [[ -f "$POOL_PENDING" ]] || : > "$POOL_PENDING"
  grep -qx "$id" "$POOL_PENDING" || echo "$id" >> "$POOL_PENDING"
}
# drop an id from the pending file
pool_pending_drop() {
  local id; id=$(canon_id "$1")
  [[ -s "$POOL_PENDING" ]] && sed -i "\%^$id\$%d" "$POOL_PENDING"
  return 0
}

# dispatch the pool subcommands
cmd_pool() {
  local sub="${1:-}"
  [[ -n "$sub" ]] || die "pool needs a subcommand: set, status, reconcile"
  shift
  case "$sub" in
    set)       cmd_pool_set "$@" ;;
    status)    cmd_pool_status "$@" ;;
    reconcile) cmd_pool_reconcile "$@" ;;
    *) die "pool takes set, status or reconcile, not '$sub'" ;;
  esac
}

# resize the pool to its configured size
cmd_pool_reconcile() {
  cli_root_ok || die "pool reconcile must run as root"
  [[ $# -eq 0 ]] || die "pool reconcile takes no arguments"
  local target; target=$(pool_target_k)
  reconcile_pool "$target"
  echo "RHIZO_POOL k=$target members=$(pool_member_count)"
}

# print the configured pool size
pool_target_k() {
  local k=""
  [[ -f "$POOL_CONF" ]] && k=$(sed -n 's/^K=//p' "$POOL_CONF" | tail -1)
  [[ "$k" =~ ^[0-9]+$ ]] || k=0
  echo "$k"
}

# set the pool size
cmd_pool_set() {
  cli_root_ok || die "pool set must run as root"
  [[ $# -eq 1 ]] || die "pool set takes exactly one argument: the target pool size"
  local k="$1"
  [[ "$k" =~ ^[0-9]+$ ]] || die "pool size must be a non-negative integer, got '$k'"
  do_pool_set "$k"
}

# print the pool status line
cmd_pool_status() {
  [[ $# -eq 0 ]] || die "pool status takes no arguments"
  echo "RHIZO_POOL k=$(pool_target_k) members=$(pool_member_count) pending=$(pool_pending_count)"
}

# create the etc and state dirs
ensure_pool_state_dirs() {
  mkdir -p "$ETC_RHIZO" "$STATE_DIR" || die "cannot create $ETC_RHIZO or $STATE_DIR"
}

# apply a pool size
do_pool_set() {
  local k="$1" headroom reason
  headroom=$(pool_host_headroom_bytes)
  [[ "$headroom" =~ ^[0-9]+$ ]] || die "could not measure host memory headroom: got '$headroom'"
  reason=$(pool_refusal "$k" "$headroom")
  [[ -z "$reason" ]] || die "$reason"

  ensure_pool_state_dirs
  printf 'K=%s\n' "$k" > "$POOL_CONF.part" || die "cannot write $POOL_CONF.part"
  mv "$POOL_CONF.part" "$POOL_CONF" || die "cannot install $POOL_CONF"
  [[ -f "$POOL_MEMBERS" ]] || : > "$POOL_MEMBERS"
  [[ -f "$POOL_PENDING" ]] || : > "$POOL_PENDING"

  reconcile_pool "$k"
  echo "RHIZO_POOL k=$k members=$(pool_member_count)"
}

# wait for an instance's probe socket
wait_probe_socket() {
  local timeout="$2" sock deadline
  sock=$(instance_probe_sock "$1")
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    [[ -S "$sock" ]] && return 0
    sleep 1
  done
  return 1
}

# take the pool lock on fd 9
pool_lock() {
  ensure_pool_state_dirs
  exec 9>"$POOL_LOCK_FILE" || die "cannot open $POOL_LOCK_FILE"
  flock 9 || die "cannot lock $POOL_LOCK_FILE"
}
pool_unlock() {
  flock -u 9 2>/dev/null
  exec 9>&-
}

# resize the pool to a target size
reconcile_pool() {
  local target="$1" have id unit
  while :; do
    pool_lock
    have=$(( $(pool_member_count) + $(pool_pending_count) ))
    if (( have >= target )); then pool_unlock; break; fi
    id=$(pool_next_free_id)
    if [[ -z "$id" ]]; then
      pool_unlock
      log "no free instance id 1-99: pool at $have of $target"
      break
    fi
    check_server_profile_for_instance "$id"
    unit=$(instance_unit "$id")
    log "adding instance $id to the pool (target $target)"
    [[ -s "$ETC_RHIZO/instances/$id.env" ]] || do_instance_add "$id" "" >&2
    pool_pending_add "$id"
    pool_unlock

    if ! systemctl start "$unit"; then
      log "instance $id failed to start: left out of the pool"
      pool_reservation_drop "$id"; break
    fi
    if ! wait_probe_socket "$id" 120; then
      log "instance $id has no probe socket: stopped, left out of the pool"
      systemctl stop "$unit"
      pool_reservation_drop "$id"; break
    fi
    if ! wait_boot_completed "$id" 300; then
      log "instance $id reported no sys.boot_completed=1: stopped, left out of the pool"
      systemctl stop "$unit"
      pool_reservation_drop "$id"; break
    fi
    if ! systemctl freeze "$unit"; then
      log "instance $id did not freeze: left running, out of the pool"
      pool_reservation_drop "$id"; break
    fi
    pool_lock
    pool_pending_drop "$id"
    [[ -f "$POOL_MEMBERS" ]] || : > "$POOL_MEMBERS"
    grep -qx "$id" "$POOL_MEMBERS" || echo "$id" >> "$POOL_MEMBERS"
    pool_unlock
  done
  while :; do
    pool_lock
    have=$(pool_member_count)
    if (( have <= target )); then pool_unlock; break; fi
    id=$(grep -ve '^[[:space:]]*$' "$POOL_MEMBERS" 2>/dev/null | tail -1)
    if [[ -z "$id" ]]; then pool_unlock; break; fi
    sed -i "\%^$id\$%d" "$POOL_MEMBERS"
    pool_unlock
    unit=$(instance_unit "$id")
    log "releasing instance $id from the pool (target $target)"
    systemctl thaw "$unit" 2>/dev/null
    systemctl stop "$unit" || log "instance $id did not stop cleanly"
  done
}
pool_reservation_drop() {
  pool_lock
  pool_pending_drop "$1"
  pool_unlock
}

# allocate an instance pool member
cmd_instance_allocate() {
  cli_root_ok || die "instance allocate must run as root"
  [[ $# -eq 0 ]] || die "instance allocate takes no arguments"
  do_instance_allocate
}

# allocate the first instance pool member
do_instance_allocate() {
  local id unit addr
  pool_lock
  id=$(head -1 "$POOL_MEMBERS" 2>/dev/null)
  if [[ -z "$id" ]]; then
    pool_unlock
    die "the instance pool is empty: nothing to allocate"
  fi
  sed -i "\%^$id\$%d" "$POOL_MEMBERS"
  pool_unlock

  unit=$(instance_unit "$id")
  log "unfreezing $unit"
  systemctl thaw "$unit" || die "systemctl thaw $unit failed"
  wait_probe_socket "$id" 60 || die "instance $id unfrozen with no probe socket within 60s"
  addr=$(sandbox_adb_endpoint "$id")
  [[ -n "$addr" ]] \
    || log "instance $id allocated with no address over $(instance_probe_sock "$id"): no endpoint printed"

  mkdir -p "$VAR_LOG"
  if ! systemd-run --collect --quiet --unit="rhizo-pool-replace-$id" \
        --description="rhizo instance-pool replacement after allocating instance $id" \
        --setenv=RHIZO_LIB_DIR="$LIB_DIR" --setenv=RHIZO_STATE_DIR="$STATE_DIR" \
        /bin/bash "$SELF" pool reconcile; then
    log "could not start the pool refill unit: run 'rhizo pool reconcile'"
  fi

  echo "RHIZO_ALLOCATED id=$id adb=$addr"
}

cmd_instance_release() {
  cli_root_ok || die "instance release must run as root"
  [[ $# -eq 1 ]] || die "instance release takes exactly one instance id"
  check_instance_id "$1"
  do_instance_release "$(canon_id "$1")"
}

# stop a released instance
do_instance_release() {
  local id unit
  id=$(canon_id "$1")
  unit=$(instance_unit "$id")
  log "stopping $unit"
  systemctl stop "$unit" || die "systemctl stop $unit failed"
  reconcile_pool "$(pool_target_k)"
  echo "RHIZO_RELEASED id=$id"
}

[[ "${RHIZO_CLI_SOURCE_ONLY:-0}" == 1 ]] && return 0

[[ $# -ge 1 ]] || { usage; exit 2; }

if [[ "$1" == "-i" ]]; then
  [[ $# -ge 2 ]] || die "-i needs an instance id"
  GLOBAL_INSTANCE_ID="$2"
  shift 2
fi

if [[ $EUID -ne 0 ]]; then
  case "$1" in
    launch|app|start|status)
      [[ -r "$BROKER_CLIENT" ]] \
        || app_fail "no $BROKER_CLIENT"
      [[ -n "$GLOBAL_INSTANCE_ID" ]] && export RHIZO_SANDBOX_ID="$GLOBAL_INSTANCE_ID"
      exec /usr/bin/python3 "$BROKER_CLIENT" "$@"
      ;;
  esac
fi

CMD="$1"; shift
case "$CMD" in
  -h|--help|help) usage; exit 0 ;;
  -v|--version|version) rhizo_version; exit 0 ;;
  install)        cmd_install "$@" ;;
  prepare)        cmd_prepare "$@" ;;
  upgrade)        cmd_upgrade "$@" ;;
  gsi)            cmd_gsi "$@" ;;
  uninstall)      cmd_uninstall "$@" ;;
  status)         cmd_status "$@" ;;
  doctor)         cmd_doctor "$@" ;;
  profile)        cmd_profile "$@" ;;
  gpu)            cmd_gpu "$@" ;;
  reset)          cmd_reset "$@" ;;
  shell)          cmd_shell "$@" ;;
  start)          cmd_start "$@" ;;
  stop)           cmd_stop "$@" ;;
  launch)         cmd_launch "$@" ;;
  app)            cmd_app "$@" ;;
  device)         cmd_device "$@" ;;
  adb-key)        cmd_adbkey "$@" ;;
  snapshot)       cmd_snapshot "$@" ;;
  instance)       cmd_instance "$@" ;;
  pool)           cmd_pool "$@" ;;
  *) echo "[$PROG] FAIL: unknown command '$CMD': run 'rhizo --help'" >&2; exit 2 ;;
esac
