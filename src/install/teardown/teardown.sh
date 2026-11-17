#!/bin/bash
# host teardown for rhizo
set -uo pipefail

PROG=rhizo-host-teardown
log() { echo "[$PROG] $*" >&2; }
# print a refusal line and exit 1
refuse() { local token="$1"; shift; log "$*"; echo "RHIZO_TEARDOWN_REFUSED reason=$token"; exit 1; }
# print a failure line and exit 1
failstop() { local token="$1"; shift; log "$*"; echo "RHIZO_TEARDOWN_FAILED reason=$token"; exit 1; }
# print the usage text
usage() {
  cat <<'EOF'
teardown.sh [--verify | --stop-payload-processes | --clear-host-labels | --list-host-labels] [--purge]
            [-h | --help]
EOF
}
# record and log a removal
mark_change() { ANY_CHANGE=1; log "  removed $*"; }

MODE=apply
PURGE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) MODE=verify; shift ;;
    --purge) PURGE=1; shift ;;
    --stop-payload-processes) MODE=stop-payload; shift ;;
    --clear-host-labels) MODE=clear-host-labels; shift ;;
    --list-host-labels) MODE=list-host-labels; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[$PROG] unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# shellcheck source=teardown-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/teardown-lib.sh"
# shellcheck source=host-flavor.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/host-flavor.sh" \
  || failstop "library-unreadable" "failed to source host-flavor.sh beside $0"
# shellcheck source=bootloader.sh
source "$(dirname "${BASH_SOURCE[0]}")/../bootstrap/bootloader.sh" \
  || failstop "library-unreadable" "failed to source bootloader.sh beside $0"

FLAVOR=$(host_flavor)
TEARDOWN_SELINUX_ENFORCE=/sys/fs/selinux/enforce
TEARDOWN_ATTR_CURRENT=/proc/self/attr/current
TEARDOWN_UNLABELED_CONTEXT=/sys/fs/selinux/initial_contexts/unlabeled
TEARDOWN_SELINUX_MODE_FILE=/run/rhizo-selinux-mode
TEARDOWN_ANDROIDD_ENV="${RHIZO_ANDROIDD_ENV:-/etc/rhizo/androidd.env}"
SWAP_FSTAB_LINE="/swapfile none swap sw 0 0"
MODULES_LOAD_CONF=/etc/modules-load.d/rhizo.conf
PREPARED_ROOT="$RHIZO_TEARDOWN_LIB_PREPARED_ROOT"
TEMPLATES_ROOT="$RHIZO_TEARDOWN_LIB_TEMPLATES_ROOT"
UPDATE_ROOT="$RHIZO_TEARDOWN_LIB_UPDATE_ROOT"
DERIVED_ROOT="$RHIZO_TEARDOWN_LIB_DERIVED_ROOT"
PREPARED_SENTINEL="$RHIZO_TEARDOWN_LIB_PREPARED_SENTINEL"
DATA_IMG="$RHIZO_TEARDOWN_LIB_DATA_IMG"
VAR_CACHE="$RHIZO_TEARDOWN_LIB_VAR_CACHE"
VAR_LOG="$RHIZO_TEARDOWN_LIB_VAR_LOG"
STATE_ROOT="$RHIZO_TEARDOWN_LIB_STATE_ROOT"
UPGRADE_FROM="$RHIZO_TEARDOWN_LIB_UPGRADE_FROM"
LOOP_UDEV_RULE="$RHIZO_TEARDOWN_LIB_LOOP_UDEV_RULE"
LAUNCH_DIRS=("${RHIZO_TEARDOWN_LIB_LAUNCH_DIRS[@]}")
ROOT_STATE=("${RHIZO_TEARDOWN_LIB_ROOT_STATE[@]}")
PREPARE_BOOT_LOG=/root/boot.log
PREPARE_ANDROIDD_ENV=/root/androidd.env
ETC_RHIZO="$RHIZO_TEARDOWN_LIB_ETC_RHIZO"
APPWATCH_BIN="$RHIZO_TEARDOWN_LIB_APPWATCH_BIN"
UNITS=(androidd.service androidd@.service rhizo-prepare.service rhizo-kernel-refresh.service
       rhizo-policy.service rhizo-selinuxfs.service rhizo-selinux-mode.service rhizo-host-labels.service
       rhizo-hostfs.service
       rhizo-app-events.service rhizo-resync.path rhizo-resync.service
       rhizo-remove-entries.path rhizo-remove-entries.service rhizo-desktop-attach.path rhizo-desktop-attach.service
       rhizo-session-start.path rhizo-session-start.service
       rhizo-resync-rearm.service rhizo-brokerd.socket rhizo-brokerd@.service
       rhizo-display-pool.path rhizo-display-pool.service rhizo-display-pool-release.service
       rhizo-update-begin.service rhizo-update-confirm.service
       rhizo-server-idle.service rhizo-server-idle@.service
       rhizo-api.socket rhizo-api@.service
       rhizo-streamd.socket rhizo-streamd.service
       rhizo-stream-capability.path rhizo-stream-capability.service
       rhizo-deskd.service rhizo-desk-token.service rhizo-audiod.service rhizo-camerad.service
       rhizo-displayd.service rhizo-keymapd.service rhizo-user-prep@.service
       rhizo-session-vt@.service rhizo-inputd@.service rhizo-inputd-uhid@.service
       rhizo-rtd.service rhizo-delayd.service rhizo-headroomd.service rhizo-btd.service
       rhizo-locationd.service)
UNIT_DROPINS=(run-rhizo.mount.d/rhizo-resync-rearm.conf
              run-rhizo-data.mount.d/rhizo-resync-rearm.conf)
USER_UNITS=(rhizo-desktop-session.path rhizo-desktop-session.service rhizo-desk-notify.path rhizo-desk-notify.service)
USER_UNIT_DIR=/etc/systemd/user
DESKTOP_SESSION_DIR=/run/rhizo-desktop
APPLICATIONS_DIR=/usr/share/applications
SYSTEM_MIMEAPPS="$APPLICATIONS_DIR/mimeapps.list"
KDE_MIMEAPPS=/etc/xdg/kde-mimeapps.list
METAINFO_DIR=/usr/share/metainfo
APK_HANDLER_ENTRY="$APPLICATIONS_DIR/rhizo-apk-installer.desktop"
ICON_THEME_ROOT=/usr/share/icons/hicolor
BROKER_RUNTIME_DIR=/run/rhizo-broker
SELINUXNS_RECORDS_DIR="${RHIZO_TEARDOWN_SELINUXNS_RECORDS_DIR:-/run/rhizo-selinuxns}"
INSTALL_RECORD="$RHIZO_TEARDOWN_LIB_INSTALL_RECORD"
# print the path of rhizo-selinux-mode
teardown_mode_helper() {
  local here
  here=$(dirname "${BASH_SOURCE[0]}")
  if [[ -n "${RHIZO_SELINUX_MODE_HELPER:-}" ]]; then
    printf '%s\n' "$RHIZO_SELINUX_MODE_HELPER"
  elif [[ -f "$here/rhizo-selinux-mode" ]]; then
    printf '%s\n' "$here/rhizo-selinux-mode"
  elif [[ -f "$here/../../rhizo-selinux-mode" ]]; then
    printf '%s\n' "$here/../../rhizo-selinux-mode"
  else
    log "no rhizo-selinux-mode in $here or $here/../.."
    return 1
  fi
}
# run the rhizo-selinux-mode helper
teardown_helper_run() {
  local helper=$1; shift
  if [[ -n "${RHIZO_SELINUX_MODE_HELPER:-}" ]]; then
    "$helper" "$@"
  else
    python3 "$helper" "$@"
  fi
}
# print the SELinux mode
teardown_selinux_mode() {
  local m="" helper
  if [[ -e "$TEARDOWN_SELINUX_MODE_FILE" ]]; then
    m=$(cat "$TEARDOWN_SELINUX_MODE_FILE") || { log "failed to read $TEARDOWN_SELINUX_MODE_FILE"; return 1; }
  fi
  if [[ -z "$m" ]]; then
    helper=$(teardown_mode_helper) || return 1
    m=$(teardown_helper_run "$helper" --env-file "$TEARDOWN_ANDROIDD_ENV" --configured) \
      || { log "$helper --configured failed"; return 1; }
  fi
  case "$m" in
    host|namespace) printf '%s\n' "$m" ;;
    *) log "SELinux mode '$m', expected host or namespace"; return 1 ;;
  esac
}
# return whether the install is in namespace mode
namespace_install() {
  local m
  grep -qx 'selinux-mode namespace' "$INSTALL_RECORD" 2>/dev/null && return 0
  m=$(teardown_selinux_mode) || failstop "selinux-mode-unreadable" "failed to read the SELinux mode"
  [[ "$m" == namespace ]]
}
# print /proc/self/attr/current
teardown_own_context() {
  tr -d '\0' < "$TEARDOWN_ATTR_CURRENT" 2>/dev/null
}
# print the host-wide SELinux policy state
teardown_host_policy_state() {
  [[ "$(teardown_own_context)" == *:* ]] || { echo none; return 0; }
  case "$(cat "$TEARDOWN_SELINUX_ENFORCE" 2>/dev/null)" in
    0) echo permissive ;;
    1) echo enforcing ;;
    *) echo unknown ;;
  esac
}
# return whether Android's policy is loaded host-wide
teardown_android_policy_loaded() {
  [[ "$(teardown_own_context)" == u:r:* ]]
}
TEARDOWN_NS_INSTALL=0
namespace_install && TEARDOWN_NS_INSTALL=1
BROKER_GROUP=rhizo
APPWATCH_ACCOUNT="$RHIZO_TEARDOWN_LIB_APPWATCH_ACCOUNT"
NETBRIDGED_ACCOUNT="$RHIZO_TEARDOWN_LIB_NETBRIDGED_ACCOUNT"
UHID_ACCOUNT="$RHIZO_TEARDOWN_LIB_UHID_ACCOUNT"

# print all of the instances' existing SELinux namespace records dirs
selinuxns_records_dirs() {
  local d
  for d in "$SELINUXNS_RECORDS_DIR" "$SELINUXNS_RECORDS_DIR"-*; do
    [[ -d "$d" ]] && echo "$d"
  done
  true
}
# remove all of the SELinux namespace records directories
remove_selinuxns_records() {
  local d
  while IFS= read -r d; do
    rm -rf "$d" || failstop "selinuxns-records-rm-failed" "failed to remove $d"
    mark_change "$d"
  done < <(selinuxns_records_dirs)
}
# log the SELinux namespace records directories left
report_selinuxns_records() {
  local left
  left=$(selinuxns_records_dirs)
  if [[ -n "$left" ]]; then
    log "  ${SELINUXNS_RECORDS_DIR}[-<id>] exists ($(tr '\n' ' ' <<<"$left"))"
    return 1
  fi
  log "  no ${SELINUXNS_RECORDS_DIR}[-<id>]"
}

# print the existing /root/.rhizo_* state paths
root_state_present() {
  local p g
  for p in "${ROOT_STATE[@]}"; do
    for g in $p; do
      [[ -e "$g" || -L "$g" ]] && echo "$g"
    done
  done
  true
}

DSH_STATE=/var/lib/systemd/deb-systemd-helper-enabled
DSH_USER_STATE=/var/lib/systemd/deb-systemd-user-helper-enabled
# print the unit enablement symlinks
unit_enable_links() {
  local u name l
  shopt -s nullglob
  for u in "${USER_UNITS[@]}"; do
    for l in "$USER_UNIT_DIR"/*.wants/$u "$USER_UNIT_DIR"/*.requires/$u; do
      [[ -L "$l" ]] || continue
      [[ "$1" == foreign && -e "$DSH_USER_STATE/${l#"$USER_UNIT_DIR"/}" ]] && continue
      echo "$l"
    done
  done
  for u in "${UNITS[@]}"; do
    name="$u"
    [[ "$u" == *@.* ]] && name="${u/@./@*.}"
    for l in /etc/systemd/system/*.wants/$name /etc/systemd/system/*.requires/$name; do
      [[ -L "$l" ]] || continue
      [[ "$1" == foreign && -e "$DSH_STATE/${l#/etc/systemd/system/}" ]] && continue
      echo "$l"
    done
  done
  shopt -u nullglob
  true
}

# print the rhizo desktop entry paths
rhizo_desktop_entries() {
  local f
  shopt -s nullglob
  for f in "$APPLICATIONS_DIR"/rhizo-*.desktop; do
    [[ "$f" == "$APK_HANDLER_ENTRY" ]] && { echo "$f"; continue; }
    grep -q '^X-Rhizo-Package=' "$f" && echo "$f"
  done
  shopt -u nullglob
  true
}

# print the AppStream metainfo appsync wrote
rhizo_metainfo() {
  shopt -s nullglob
  local f
  for f in "$METAINFO_DIR"/rhizo-*.metainfo.xml; do
    echo "$f"
  done
  shopt -u nullglob
  true
}

# print the rhizo icon files
rhizo_icons() {
  shopt -s nullglob
  local f
  for f in "$ICON_THEME_ROOT"/*/apps/rhizo-*.png "$ICON_THEME_ROOT"/*/apps/rhizo.png; do
    echo "$f"
  done
  shopt -u nullglob
  true
}

# print the instance units of a template unit
instance_units_of() {
  command -v systemctl >/dev/null 2>&1 || return 0
  local pattern="${1/@./@*.}"
  { systemctl list-units --all --no-legend --plain "$pattern" 2>/dev/null
    systemctl list-unit-files --no-legend --plain "$pattern" 2>/dev/null
  } | awk '{print $1}' | sort -u | grep -vxF "$1" || true
}

# print the live instances of templated units
live_instance_units() {
  local u
  for u in "${UNITS[@]}"; do
    [[ "$u" == *@.* ]] || continue
    instance_units_of "$u"
  done
}

# remove rhizo entries from a mimeapps.list file
strip_mimeapps_defaults() {
  python3 - "$1" "$2" <<'PYEOF'
import re, sys
path, mode = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    lines = fh.read().split(b"\n")
out, section, dropped = [], b"", 0
for line in lines:
    bare = line.strip()
    if bare.startswith(b"[") and bare.endswith(b"]"):
        section = bare
    elif section == b"[Default Applications]" and b"=" in line:
        key, value = line.split(b"=", 1)
        kept = [v for v in value.split(b";") if v.strip()
                and not re.fullmatch(rb"rhizo-.*\.desktop", v.strip())]
        if len(kept) != len([v for v in value.split(b";") if v.strip()]):
            dropped += 1
            if not kept:
                continue
            line = key + b"=" + b";".join(kept) + b";"
    out.append(line)
if dropped and mode == "apply":
    if any(b"=" in l for l in out):
        with open(path, "wb") as fh:
            fh.write(b"\n".join(out))
    else:
        import os
        os.unlink(path)
print(dropped)
PYEOF
}

HOST_EXEC_CONTEXT="$RHIZO_TEARDOWN_LIB_HOST_EXEC_CONTEXT"
HOST_EXEC_PATHS=(/usr/lib/systemd/systemd /usr/sbin/sshd /usr/bin/bash
                  /usr/bin/dash /usr/bin/systemctl /usr/bin/python3
                  /usr/sbin/modprobe)
HOST_MODULE_CONTEXT="$RHIZO_TEARDOWN_LIB_HOST_MODULE_CONTEXT"
HOST_MODULE_ROOT="$RHIZO_TEARDOWN_LIB_HOST_MODULE_ROOT"
HOST_LABELS_PENDING="$RHIZO_TEARDOWN_LIB_HOST_LABELS_PENDING"
HOST_MODE_KEPT="$RHIZO_TEARDOWN_LIB_HOST_MODE_KEPT"
RUNTIME_ENV="${RHIZO_RUNTIME_ENV:-/var/lib/rhizo/androidd-runtime.env}"

# print the kernel's active LSM list
lsm_active() { cat /sys/kernel/security/lsm 2>/dev/null || echo ""; }
# return whether the install is host mode and the active LSM list contains selinux
reboot_needed_for_lsm() { [[ "${TEARDOWN_NS_INSTALL:-0}" != 1 && ",$(lsm_active)," == *",selinux,"* ]]; }

# print the installed Rhizo kernel packages
rhizo_kernel_packages() {
  local out rc=0 line
  case "$FLAVOR" in
    ubuntu)
      command -v dpkg-query >/dev/null 2>&1 || { echo "no dpkg-query" >&2; return 2; }
      # shellcheck disable=SC2016
      out=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 'linux-image-*rhizo' 'linux-headers-*rhizo' 2>/dev/null) \
        || rc=$?
      (( rc <= 1 )) || { echo "dpkg-query failed with exit status $rc" >&2; return 2; }
      while IFS= read -r line; do
        case "${line:0:3}" in
          "ii ") echo "${line:4}" ;;
        esac
      done <<<"$out" ;;
    cachyos)
      command -v pacman >/dev/null 2>&1 || { echo "no pacman" >&2; return 2; }
      out=$(pacman -Qq linux-rhizo linux-rhizo-headers 2>/dev/null) || rc=$?
      (( rc <= 1 )) || { echo "pacman -Qq failed with exit status $rc" >&2; return 2; }
      [[ -z "$out" ]] || printf '%s\n' "$out" ;;
  esac
}

# log the running Rhizo kernel and the installed Rhizo kernel packages
rhizo_kernel_note() {
  local pkgs running rc=0
  running=$(uname -r)
  pkgs=$(rhizo_kernel_packages) || rc=$?
  if (( rc )); then
    log "failed to list the Rhizo kernel packages"
    return 0
  fi
  pkgs=$(tr '\n' ' ' <<<"$pkgs"); pkgs=${pkgs% }
  if [[ "$running" != *-rhizo && -z "$pkgs" ]]; then
    return 1
  fi
  [[ "$running" != *-rhizo ]] || log "the running kernel is the Rhizo kernel $running"
  [[ -z "$pkgs" ]] || log "the installed Rhizo kernel packages are $pkgs"
  return 0
}

# restore the default boot entry
restore_default_entry() {
  local kind out
  grep -q '^rhizo-kernel-default ' "$INSTALL_RECORD" 2>/dev/null || return 0
  kind=$(bootloader_kind 2>&1) \
    || failstop "default-entry-unknown" "bootloader_kind failed ($kind)"
  out=$(bootloader_restore_default "$kind" "$INSTALL_RECORD") \
    || failstop "default-entry-restore-failed" "failed to restore the default boot entry"
  case "$out" in
    kept\ *)     log "  default boot entry ${out#kept } is not the Rhizo kernel" ;;
    restored\ -) mark_change "the Rhizo kernel as the default boot entry" ;;
    restored\ *) mark_change "the Rhizo kernel as the default boot entry, default ${out#restored }" ;;
  esac
}

# print rhizo's bootloader config file or block
contribution() {
  if [[ "$1" == grub-dropin ]]; then
    bootloader_config_file "$1"
  else
    echo "rhizo's block in $(bootloader_config_file "$1")"
  fi
}

# print the bootloader regeneration labels or commands
regen_choices() {
  local k out="" target cmd
  target=$(bootloader_target "$1")
  for k in $BL_KINDS; do
    [[ "$(bootloader_target "$k")" == "$target" ]] || continue
    if [[ "$2" == name ]]; then
      out+=" or $(bootloader_regen_label "$k")"
    elif cmd=$(bootloader_regen_host_cmd "$k" 2>&1); then
      out+=" or $cmd"
    else
      out+=" or $(bootloader_regen_cmd "$k")"
    fi
  done
  echo "${out# or }"
}

# log the rhizo tokens left in a generated config
report_left_tokens() {
  local gen
  if ! gen=$(bootloader_generated "$2" 2>&1); then
    [[ $'\n'"${5:-}" == *$'\n'"$gen"$'\n'* ]] || echo "$gen" >&2
    gen="the config $(bootloader_regen_label "$2") writes"
  fi
  if [[ -n "$3" && "$(bootloader_target "$3")" != "$(bootloader_target "$2")" ]]; then
    if [[ "$1" == verify ]]; then
      log "  rhizo tokens left in $gen ($4), detected bootloader $3"
    else
      log "  left $gen ($4), detected bootloader $3"
    fi
    return 0
  fi
  if [[ "$1" == verify ]]; then
    log "  rhizo tokens in $gen ($4), no $(regen_choices "$2" name)"
  else
    log "  $gen ($4), no $(regen_choices "$2" name)"
    [[ "$4" == "failed to read the cmdlines" ]] || LEFT_CONFIGS+=("$gen"$'\t'"$2")
  fi
  return 1
}

# log the rhizo tokens on configs without a regeneration command
report_stranded_tokens() {
  local kind target seen=" $3 " reported="${4:-}" tokens found=0 unread=0 rc
  for kind in $BL_KINDS; do
    target=$(bootloader_target "$kind")
    [[ "$seen" != *" $target "* ]] || continue
    seen+="$target "
    ! bootloader_regenerator "$kind" >/dev/null || continue
    rc=0; tokens=$(bootloader_android_tokens "$kind" 2>&1) || rc=$?
    if (( rc == 2 )) && [[ "$1" == verify ]]; then
      if [[ -z "$2" || "$(bootloader_target "$2")" == "$target" ]]; then
        if [[ $'\n'"$reported"$'\n' != *$'\n'"$tokens"$'\n'* ]]; then
          log "  failed to read the bootloader config ($tokens)"
          reported+="$tokens"$'\n'
        fi
        unread=1
      fi
      continue
    fi
    if (( rc != 0 )); then
      [[ -z "$tokens" ]] || { echo "$tokens" >&2; reported+="$tokens"$'\n'; }
      tokens="failed to read the cmdlines"
    elif [[ -n "$tokens" ]]; then
      tokens="tokens$(awk '{printf " %s", $0}' <<<"$tokens")"
    else
      continue
    fi
    report_left_tokens "$1" "$kind" "$2" "$tokens" "$reported" || found=1
  done
  (( ! unread )) || return 2
  return $found
}

# list the bootloader configs with rhizo tokens
list_cmdline_tokens() {
  local holders kind detected targets="" rc=0 kind_rc=0 holders_rc=0 stranded=0 unread=0 reported=""
  detected=$(bootloader_kind 2>&1) || kind_rc=$?
  if (( kind_rc == 2 )); then
    log "  failed to read the bootloader config ($detected)"
    reported=$detected$'\n' unread=1
  fi
  (( kind_rc == 0 )) || detected=""
  holders=$(bootloader_holders 2>&1) || holders_rc=$?
  case $holders_rc in
    0) ;;
    2) [[ $'\n'"$reported" == *$'\n'"$holders"$'\n'* ]] \
         || log "  failed to read the bootloader config ($holders)"
       return 2 ;;
    *) echo "$holders" >&2
       log "  bootloader_holders failed"; return 1 ;;
  esac
  for kind in $holders; do
    if [[ "$kind" == grub-dropin ]]; then
      log "  grub drop-in $(bootloader_config_file "$kind") exists"
    else
      log "  rhizo tokens in $(bootloader_config_file "$kind")"
    fi
    targets+=" $(bootloader_target "$kind")"
  done
  if [[ -n "$holders" ]]; then
    rc=1
  elif [[ "$FLAVOR" != cachyos ]]; then
    log "  no grub drop-in"
  else
    log "  no rhizo bootloader tokens"
  fi
  report_stranded_tokens verify "$detected" "$targets" "$reported" || stranded=$?
  case $stranded in
    0) ;;
    2) unread=1 ;;
    *) rc=1 ;;
  esac
  (( ! unread )) || return 2
  return $rc
}

# remove rhizo's tokens from the bootloader files
remove_cmdline_tokens() {
  local holders kind detected why="" file out target targets="" own
  local -a members
  local -A own_of=() target_of=()
  detected=$(bootloader_kind 2>&1) || { why=$detected; detected=""; }
  DETECTED_KIND=$detected REMOVED_TOKENS=""
  holders=$(bootloader_holders) \
    || failstop "bootloader-config-unreadable" \
                "failed to read the bootloader files"
  if [[ -z "$holders" ]]; then
    if [[ "$FLAVOR" != cachyos ]]; then
      log "no grub drop-in $(bootloader_config_file grub-dropin)"
    else
      log "no rhizo bootloader tokens${detected:+ in $(bootloader_config_file "$detected")}"
    fi
  else
    [[ -z "$why" ]] || log "  bootloader_kind failed ($why)"
  fi
  for kind in $holders; do
    file=$(bootloader_config_file "$kind")
    [[ -z "$detected" || "$kind" == "$detected" ]] \
      || log "  rhizo tokens in $file, detected bootloader $detected"
    own_of[$kind]=$(bootloader_own_tokens "$kind") \
      || failstop "bootloader-tokens-unreadable" "failed to read the rhizo tokens in $file"
    REMOVED_TOKENS+=" ${own_of[$kind]//$'\n'/ }"
    if ! out=$(bootloader_strip "$kind" 2>&1); then
      [[ -z "$out" ]] || echo "$out" >&2
      [[ "$kind" != grub-dropin ]] || failstop "grub-dropin-rm-failed" "failed to remove $file"
      failstop "bootloader-block-rm-failed" "failed to remove the rhizo block from $file"
    fi
    target_of[$kind]=$(bootloader_target "$kind")
    [[ " $targets " == *" ${target_of[$kind]} "* ]] || targets+=" ${target_of[$kind]}"
  done
  for target in $targets; do
    members=() own=""
    for kind in $holders; do
      [[ "${target_of[$kind]}" == "$target" ]] || continue
      members+=("$kind")
      own+="${own_of[$kind]}"$'\n'
    done
    regenerate_holders "$detected" "$own" "${members[@]}"
  done
  report_stranded_tokens apply "$detected" "$targets"
}

# print the host's selinux lsm= setting
host_lsm_keeps_selinux() {
  local - lines line w kept host last=""
  lines=$(bl_next_cmdlines "$1") || return 2
  [[ -n "$lines" ]] || return 1
  host=$(bootloader_host_tokens "$1") || return 2
  set -f
  while IFS= read -r line; do
    kept=""
    for w in $line; do
      [[ $'\n'"$host"$'\n' != *$'\n'"$w"$'\n'* && ( " $2 " == *" $w "* || "$w" == lsm=* ) ]] || kept+=" $w"
    done
    last=$(bl_last_setting lsm "$kept") && bl_lsm_selinux_major "${last#lsm=}" || return 1
  done <<<"$lines"
  echo "$last"
}

# print the rhizo tokens in each bootloader config
rhizo_tokens_carried() {
  local - kind target left android tok words seen=" "
  set -f
  for kind in ${1:-$BL_KINDS}; do
    target=$(bootloader_target "$kind")
    [[ "$seen" != *" $target "* ]] || continue
    seen+="$target "
    left=$(bootloader_leftover "$kind" "$2") || return 2
    android=$(bootloader_android_tokens "$kind") || return 2
    words=""
    for tok in $left $android; do [[ "$words " == *" $tok "* ]] || words+=" $tok"; done
    [[ -z "$words" ]] || printf '%s\t%s\n' "$kind" "$words"
  done
}

# regenerate the bootloader config for the given kinds
regenerate_holders() {
  local detected="$1" own="$2" regen label later gen out still warning what="" kind rc=0 reported=""
  shift 2
  for kind; do what+="${what:+ and }$(contribution "$kind")"; done
  if ! regen=$(bootloader_regenerator "$1" "$detected"); then
    rc=0; gen=$(bootloader_generated "$1" 2>&1) || rc=$?
    if (( rc == 2 )); then
      echo "$gen" >&2; reported=$gen$'\n'
    else
      rc=0; still=$(bootloader_leftover "$1" "$own") || rc=$?
    fi
    case $rc in
      0) if [[ -z "$still" ]]; then
           log "  no $(regen_choices "$1" name) and no rhizo tokens on the $1 cmdlines"
         else
           report_left_tokens apply "$1" "$detected" "tokens$still"
         fi ;;
      1|2) report_left_tokens apply "$1" "$detected" "failed to read the cmdlines" "$reported" ;;
      *) report_left_tokens apply "$1" "$detected" \
           "tokens$still" ;;
    esac
    for kind; do mark_change "$(contribution "$kind")"; done
    return 0
  fi
  label=$(bootloader_regen_label "$regen")
  later="$label runs on the next boot"
  [[ "$regen" != grub-dropin ]] || later="update-grub runs on the next boot"
  log "argv=$label"
  if ! out=$(bootloader_regen "$regen"); then
    echo "$out" >&2
    log "  $label failed after removing $what"
    REGEN_DEFERRED+=("$regen")
    for kind; do mark_change "$(contribution "$kind") ($later)"; done
    return 0
  fi
  [[ -z "$out" ]] || echo "$out" | sed "s/^/[$PROG]   /"
  if ! gen=$(bootloader_generated "$regen" 2>&1); then
    warning="$gen"
  else
    still=$(bootloader_leftover "$regen" "$own") || rc=$?
    case $rc in
      0) if [[ -z "$still" ]]; then
           for kind; do mark_change "$(contribution "$kind"), and regenerated $gen"; done
           return 0
         fi
         warning="$gen has rhizo tokens$still after $label" ;;
      1|2) warning="failed to read the cmdlines in $gen after $label" ;;
      *) warning="$gen has rhizo tokens$still after $label" ;;
    esac
  fi
  log "  $warning"
  REGEN_DEFERRED+=("$regen")
  for kind; do mark_change "$(contribution "$kind") ($later)"; done
}

# list, verify or clear the rhizo selinux labels
selinux_xattr_report() {
  python3 - "$1" "$HOST_EXEC_CONTEXT" "$HOST_MODULE_CONTEXT" "$HOST_MODULE_ROOT" "$TEARDOWN_UNLABELED_CONTEXT" \
    "${HOST_EXEC_PATHS[@]}" <<'PYEOF'
import os, sys
mode, ctx, mod_ctx, mod_root, unlabeled_file = sys.argv[1:6]
paths = sys.argv[6:]
mod_root = os.path.realpath(mod_root)
try:
    unlabeled = open(unlabeled_file).read().rstrip("\0\n")
except OSError:
    unlabeled = None
for _line in open("/proc/self/maps"):
    _head, _sep, _p = _line.rstrip("\n").partition(" /")
    if not _sep:
        continue
    _p = "/" + _p.strip()
    if os.path.basename(_p).startswith("ld-") and ".so" in os.path.basename(_p):
        paths = paths + [_p]
        break
try:
    _w = open("/proc/sys/kernel/core_pattern").read().split()
except OSError:
    _w = []
if _w and _w[0].startswith("|/"):
    paths = paths + [_w[0][1:]]


def module_marked(want):
    # return the module paths whose security.selinux is in want
    out = []
    for d, _dirs, files in os.walk(mod_root):
        for p in [d] + [os.path.join(d, f) for f in files]:
            if os.path.islink(p):
                continue
            try:
                v = os.getxattr(p, "security.selinux", follow_symlinks=False)
            except OSError:
                continue
            if v.decode(errors="replace").rstrip("\0") in want:
                out.append(p)
    return out


if mode == "modlabeled":
    print(len(module_marked({mod_ctx})))
    sys.exit(0)
if mode == "list":
    labels = {ctx, unlabeled} - {None}
    for p in dict.fromkeys(os.path.realpath(p) for p in paths):
        try:
            current = os.getxattr(p, "security.selinux").decode(errors="replace").rstrip("\0")
        except OSError:
            continue
        if current in labels:
            print("labeled: %s" % p)
    n = len(module_marked({mod_ctx, unlabeled} - {None}))
    if n:
        print("labeled-modules: %d %s" % (n, mod_root))
    sys.exit(0)
seen = set()
for p in paths:
    real = os.path.realpath(p)
    if real in seen:
        continue
    seen.add(real)
    if not os.path.exists(real):
        if mode != "labeled":
            print("absent: %s" % real)
        continue
    try:
        current = os.getxattr(real, "security.selinux").decode().rstrip("\0")
    except OSError:
        current = None
    if mode == "verify":
        print("%-34s %s" % (current or "<none>", real))
        continue
    if mode == "labeled":
        if current == ctx:
            print(real)
        continue
    if current != ctx:
        print("already clear: %s (xattr=%r)" % (real, current))
        continue
    try:
        os.removexattr(real, "security.selinux")
        print("cleared: %s" % real)
    except OSError as e:
        print("FAILED: %s (%s)" % (real, e))
        sys.exit(1)
if mode == "labeled":
    sys.exit(0)
marked = module_marked({mod_ctx})
if mode == "verify":
    print("%-34s %d under %s" % (mod_ctx if marked else "<none>", len(marked), mod_root))
    sys.exit(0)
for p in marked:
    try:
        os.removexattr(p, "security.selinux", follow_symlinks=False)
    except OSError as e:
        print("FAILED: %s (%s)" % (p, e))
        sys.exit(1)
if marked:
    print("cleared: %d module-tree labels under %s" % (len(marked), mod_root))
PYEOF
}

# write the label removal's state and sentence
host_labels_record() {
  if ! { printf '%s %s\n%s\n' "$1" "$2" "$3" > "$HOST_LABELS_PENDING.new" \
         && mv "$HOST_LABELS_PENDING.new" "$HOST_LABELS_PENDING"; }; then
    log "failed to write '$1 $2' to $HOST_LABELS_PENDING"
  fi
}
# parse a label scan
host_labels_parse() {
  local line
  LABELED_FILES="" LABELED_MODULES=0 LABELED_MODULE_ROOT=""
  while IFS= read -r line; do
    case "$line" in
      "labeled: "*) LABELED_FILES+="${LABELED_FILES:+ }${line#labeled: }" ;;
      "labeled-modules: "*) line=${line#labeled-modules: }; LABELED_MODULES=${line%% *}; LABELED_MODULE_ROOT=${line#* } ;;
    esac
  done <<<"$1"
}
# print the files of a label scan
host_labels_named() {
  local modules=""
  host_labels_parse "$1"
  [[ -n "$LABELED_MODULE_ROOT" ]] && modules="$LABELED_MODULES files under $LABELED_MODULE_ROOT"
  printf '%s\n' "$LABELED_FILES${LABELED_FILES:+${modules:+ and }}$modules"
}
# record and print the label removal's refusal
host_labels_stop() {
  local state=refused sentence="${*:3}"
  [[ "$1" == FAILED ]] && state=failed
  host_labels_record "$state" "$2" "$sentence"
  log "$sentence"
  echo "RHIZO_TEARDOWN_HOST_LABELS_$1 reason=$2"
  return 1
}
# remove host mode's labels from host files
clear_host_labels() {
  local m state out rc=0 failed labels
  if ! m=$(teardown_selinux_mode); then
    host_labels_stop FAILED selinux-mode-unreadable "failed to read the SELinux mode"
    return
  fi
  if [[ "$m" == host ]]; then
    host_labels_stop REFUSED host-mode "the SELinux mode is host"
    return
  fi
  state=$(teardown_host_policy_state)
  if [[ "$state" != none ]] && teardown_android_policy_loaded; then
    host_labels_stop REFUSED android-policy-loaded "Android's policy is loaded host-wide on the current boot"
    return
  fi
  case "$state" in
    none)
      out=$(selinux_xattr_report clear) || rc=$?
      grep -E '^(cleared|FAILED):' <<<"$out" | sed "s/^/[$PROG]   /" >&2
      if (( rc != 0 )); then
        failed=$(grep -m1 '^FAILED:' <<<"$out")
        if [[ -n "$failed" ]]; then
          host_labels_stop FAILED host-labels-clear-failed "failed to remove security.selinux from ${failed#FAILED: }"
        else
          host_labels_stop FAILED host-labels-clear-failed "selinux_xattr_report clear failed with exit status $rc"
        fi
        return
      fi ;;
    permissive|enforcing)
      if ! labels=$(selinux_xattr_report list); then
        host_labels_stop FAILED label-scan-failed "selinux_xattr_report list failed"
        return
      fi
      if [[ -n "$labels" ]]; then
        host_labels_stop REFUSED host-policy-loaded "the host SELinux policy is $state and host mode's label is on" \
          "$(host_labels_named "$labels")"
        return
      fi
      log "no host file has host mode's label" ;;
    *)
      host_labels_stop FAILED host-state-unknown "a policy is loaded and $TEARDOWN_SELINUX_ENFORCE contains" \
        "'$(cat "$TEARDOWN_SELINUX_ENFORCE" 2>&1)'"
      return ;;
  esac
  if ! rm -f "$HOST_LABELS_PENDING"; then
    host_labels_stop FAILED record-remove-failed "failed to remove $HOST_LABELS_PENDING"
    return
  fi
  echo "RHIZO_TEARDOWN_HOST_LABELS_CLEARED=1"
}

# list the host files with host mode's label
print_host_labels() {
  local labels
  labels=$(selinux_xattr_report list) || failstop "label-scan-failed" "selinux_xattr_report list failed"
  if [[ -z "$labels" ]]; then
    echo "RHIZO_TEARDOWN_HOST_LABELS labeled=0"
    return 0
  fi
  printf '%s\n' "$labels"
  echo "files: $(host_labels_named "$labels")"
  echo "RHIZO_TEARDOWN_HOST_LABELS labeled=1"
}

if [[ "$MODE" == clear-host-labels ]]; then
  [[ $EUID -eq 0 ]] || refuse "not-root" "EUID $EUID is not 0"
  clear_host_labels
  exit
fi
if [[ "$MODE" == list-host-labels ]]; then
  print_host_labels
  exit 0
fi

if [[ "$MODE" == verify ]]; then
  found=0

  cmdline_rc=0
  list_cmdline_tokens || cmdline_rc=$?
  (( cmdline_rc != 1 )) || found=1
  default_line=$(grep -m1 '^rhizo-kernel-default ' "$INSTALL_RECORD" 2>/dev/null)
  if [[ -n "$default_line" ]]; then
    log "  $INSTALL_RECORD has rhizo-kernel-default ${default_line#rhizo-kernel-default }"; found=1
  else
    log "  no rhizo-kernel-default in $INSTALL_RECORD"
  fi
  if grep -qx host-mode-links "$INSTALL_RECORD" 2>/dev/null; then
    log "  $INSTALL_RECORD has host-mode-links"; found=1
  else
    log "  no host-mode links"
  fi

  swap_owned=$(teardown_swap_owned "$INSTALL_RECORD" /swapfile)
  if [[ "$swap_owned" == *fstab* ]] && grep -qxF "$SWAP_FSTAB_LINE" /etc/fstab 2>/dev/null; then
    log "  /etc/fstab has the bootstrap swap line"; found=1
  else
    log "  no bootstrap swap line in /etc/fstab"
  fi
  if [[ "$swap_owned" == *file* ]]; then
    log "  /swapfile exists, created by the bootstrap"; found=1
  elif [[ -e /swapfile ]]; then
    log "  /swapfile exists, not created by the bootstrap"
  fi

  [[ -e "$MODULES_LOAD_CONF" ]] && { log "  $MODULES_LOAD_CONF exists"; found=1; } \
    || log "  no $MODULES_LOAD_CONF"

  log "  selinux host xattrs"
  xattr_out="$(selinux_xattr_report verify)"
  echo "$xattr_out" | sed 's/^/    /' >&2
  grep -q "^$HOST_EXEC_CONTEXT " <<<"$xattr_out" && found=1
  grep -q "^$HOST_MODULE_CONTEXT " <<<"$xattr_out" && found=1
  for f in "$HOST_LABELS_PENDING" "$HOST_MODE_KEPT"; do
    if [[ -e "$f" ]]; then
      log "  $f exists ($(head -1 "$f" 2>&1))"; found=1
    else
      log "  no $f"
    fi
  done

  if (( PURGE )); then
    if [[ -e "$RUNTIME_ENV" ]]; then log "  $RUNTIME_ENV exists"; found=1; else log "  no $RUNTIME_ENV"; fi
  fi
  for d in "$PREPARED_ROOT" "$TEMPLATES_ROOT" "$DERIVED_ROOT" "$VAR_CACHE" "$VAR_LOG" "${LAUNCH_DIRS[@]}"; do
    if [[ -e "$d" || -L "$d" ]]; then log "  $d exists"; found=1; else log "  no $d"; fi
  done
  for f in "$PREPARE_BOOT_LOG" "$PREPARE_ANDROIDD_ENV" "$PREPARED_SENTINEL" "$UPGRADE_FROM" "$LOOP_UDEV_RULE"; do
    if [[ -e "$f" ]]; then log "  $f exists"; found=1; else log "  no $f"; fi
  done
  root_left=$(root_state_present)
  if [[ -n "$root_left" ]]; then
    log "  /root/.rhizo_* state exists ($(tr '\n' ' ' <<<"$root_left"))"; found=1
  else
    log "  no /root/.rhizo_* state"
  fi

  present_units=()
  for u in "${UNITS[@]}"; do
    [[ -e "/etc/systemd/system/$u" ]] && present_units+=("$u")
  done
  for d in "${UNIT_DROPINS[@]}"; do
    [[ -e "/etc/systemd/system/$d" ]] && present_units+=("$d")
  done
  for u in "${USER_UNITS[@]}"; do
    [[ -e "$USER_UNIT_DIR/$u" || -L "$USER_UNIT_DIR/$u" ]] && present_units+=("$USER_UNIT_DIR/$u")
  done
  while IFS= read -r inst; do
    [[ -n "$inst" ]] && present_units+=("$inst")
  done < <(live_instance_units)
  if (( ${#present_units[@]} )); then
    log "  ${#present_units[@]} systemd units exist (${present_units[*]})"; found=1
  else
    log "  no rhizo systemd units"
  fi
  [[ -e "$APPWATCH_BIN" ]] && { log "  $APPWATCH_BIN exists"; found=1; } \
    || log "  no $APPWATCH_BIN"

  entries=$(rhizo_desktop_entries | wc -l)
  icons=$(rhizo_icons | wc -l)
  if (( entries || icons )); then
    log "  $entries desktop entries and $icons hicolor icons exist"; found=1
  else
    log "  no rhizo desktop entries or hicolor icons"
  fi
  for list in "$SYSTEM_MIMEAPPS" "$KDE_MIMEAPPS"; do
    if [[ -f "$list" ]]; then
      defaults=$(strip_mimeapps_defaults "$list" count)
      if (( defaults )); then
        log "  $list has $defaults rhizo defaults"; found=1
      else
        log "  $list has no rhizo defaults"
      fi
    else
      log "  no $list"
    fi
  done
  metainfo=$(rhizo_metainfo | wc -l)
  if (( metainfo )); then
    log "  $METAINFO_DIR has $metainfo rhizo metainfo files"; found=1
  else
    log "  no rhizo metainfo in $METAINFO_DIR"
  fi
  [[ -d "$BROKER_RUNTIME_DIR" ]] && { log "  $BROKER_RUNTIME_DIR exists"; found=1; } \
    || log "  no $BROKER_RUNTIME_DIR"
  [[ -d "$DESKTOP_SESSION_DIR" ]] && { log "  $DESKTOP_SESSION_DIR exists"; found=1; } \
    || log "  no $DESKTOP_SESSION_DIR"
  report_selinuxns_records || found=1
  if [[ -f "$INSTALL_RECORD" ]] && grep -qx "group:$BROKER_GROUP" "$INSTALL_RECORD"; then
    log "  $INSTALL_RECORD has group:$BROKER_GROUP"; found=1
  else
    log "  no group:$BROKER_GROUP in $INSTALL_RECORD"
  fi
  for acct in "$APPWATCH_ACCOUNT" "$NETBRIDGED_ACCOUNT" "$UHID_ACCOUNT"; do
    if [[ -f "$INSTALL_RECORD" ]] && grep -qxE "(user|group):$acct" "$INSTALL_RECORD"; then
      log "  $INSTALL_RECORD has user or group $acct"; found=1
    else
      log "  no user or group $acct in $INSTALL_RECORD"
    fi
  done

  if [[ -d "$ETC_RHIZO" ]]; then
    log "  $ETC_RHIZO exists"
  else
    log "  no $ETC_RHIZO"
  fi

  if (( cmdline_rc == 2 )); then
    failstop "verify-cannot-read" "uid $EUID failed to read the next boot cmdlines"
  fi
  if (( found )); then
    failstop "not-clean" "Rhizo host changes found"
  fi
  log "no Rhizo host changes found"
  echo "RHIZO_TEARDOWN_VERIFIED=1"
  exit 0
fi

STOPPED_INSTANCES=()
if command -v systemctl >/dev/null 2>&1; then
  if [[ "$(systemctl is-active androidd.service 2>/dev/null)" == active ]]; then
    systemctl stop androidd.service 2>/dev/null || true
    for _ in $(seq 1 30); do
      [[ "$(systemctl is-active androidd.service 2>/dev/null)" == active ]] || break
      sleep 1
    done
  fi

  while IFS= read -r inst; do
    [[ -n "$inst" ]] && STOPPED_INSTANCES+=("$inst")
  done < <(live_instance_units)
  for inst in "${STOPPED_INSTANCES[@]}"; do
    systemctl stop "$inst" 2>/dev/null || true
  done
  for _ in $(seq 1 30); do
    any_active=0
    for inst in "${STOPPED_INSTANCES[@]}"; do
      [[ "$(systemctl is-active "$inst" 2>/dev/null)" == active ]] && { any_active=1; break; }
    done
    (( any_active )) || break
    sleep 1
  done

  while IFS= read -r nb; do
    [[ -n "$nb" ]] || continue
    systemctl stop "$nb" 2>/dev/null || log "  systemctl stop $nb failed"
  done < <(teardown_netbridged_units)
fi

# stop the rhizo payload processes
stop_payload_processes() {
  local -a markers=(/run/rhizo-host-primer.py /usr/lib/rhizo/rhizo-avc-capture.sh /root/rhizo-avc-capture.sh /usr/lib/rhizo/launcher3.py /root/launcher3.py)
  local -a pids argv
  local sig d pid m st pgrp p alive stopped=""
  for sig in TERM KILL; do
    pids=()
    for d in /proc/[0-9]*; do
      pid=${d#/proc/}
      [[ "$pid" == "$$" ]] && continue
      mapfile -d '' -n 2 argv 2>/dev/null < "$d/cmdline" || continue
      for m in "${markers[@]}"; do
        [[ "${argv[0]:-}" == "$m" || "${argv[1]:-}" == "$m" ]] && { pids+=("$pid"); break; }
      done
    done
    (( ${#pids[@]} )) || break
    [[ "$sig" == TERM ]] && stopped="${pids[*]}"
    for pid in "${pids[@]}"; do
      st=$(cat "/proc/$pid/stat" 2>/dev/null) || continue
      read -r _ _ pgrp _ <<<"${st##*) }"
      [[ "$pgrp" == "$pid" ]] && kill -s "$sig" -- "-$pid" 2>/dev/null
      kill -s "$sig" "$pid" 2>/dev/null
    done
    for _ in $(seq 1 50); do
      alive=0
      for p in "${pids[@]}"; do
        st=$(cat "/proc/$p/stat" 2>/dev/null) || continue
        [[ "${st##*) }" == Z* ]] || { alive=1; break; }
      done
      (( alive )) || break
      sleep 0.1
    done
  done
  [[ -n "$stopped" ]] || return 0
  mark_change "$(wc -w <<<"$stopped") processes outside the rhizo units ($stopped)"
  for p in $stopped; do
    st=$(cat "/proc/$p/stat" 2>/dev/null) || continue
    [[ "${st##*) }" == Z* ]] && continue
    log "  pid $p is running after SIGKILL"
    return 1
  done
  return 0
}
stop_payload_processes_rc=0
stop_payload_processes || stop_payload_processes_rc=$?
if [[ "$MODE" == stop-payload ]]; then
  if (( stop_payload_processes_rc == 0 )); then
    echo "RHIZO_TEARDOWN_STOP_PAYLOAD_OK=1"
    exit 0
  fi
  log "a sandbox process is running after SIGKILL"
  echo "RHIZO_TEARDOWN_STOP_PAYLOAD_FAILED=1"
  exit 1
fi
(( stop_payload_processes_rc == 0 )) || log "stop_payload_processes failed"

# unmount the mounts under /var/lib/rhizo and /run/rhizo
unmount_rhizo_trees() {
  local m n=0
  while read -r m; do
    [[ -n "$m" ]] || continue
    teardown_detach_mount "$m" 2 && n=$((n + 1))
  done < <(awk '{print $2}' /proc/self/mounts \
             | grep -E '^/(var/lib/rhizo|run/rhizo)' | sort -r)
  (( n )) && log "unmounted $n mounts under /var/lib/rhizo and /run/rhizo"
  return 0
}
unmount_rhizo_trees

# rm -rf the paths, or set DEFERRED_REMOVALS on failure
rm_or_defer() {
  local out
  out=$(rm -rf -- "$@" 2>&1) && return 0
  if (( TEARDOWN_NS_INSTALL )); then
    log "  deferring $* to rhizo-final-cleanup.service, rm -rf failed with $(grep -c . <<<"$out") errors ($(head -1 <<<"$out"))"
  else
    log "  deferring $* to rhizo-final-cleanup.service, rm -rf failed with $(grep -c . <<<"$out") errors ($(head -1 <<<"$out"))"
  fi
  DEFERRED_REMOVALS=1
}

# return whether a mount is at or under a path
mounted_under() {
  awk -v p="$1" '$2 == p || index($2, p "/") == 1 { found = 1 } END { exit !found }' /proc/self/mounts
}

XATTRS_DEFERRED=0
MODULE_LABELS_DEFERRED=0
DEFERRED_REMOVALS=0
REGEN_DEFERRED=()
LEFT_CONFIGS=()
SWAPFILE_DEFERRED=0
ACCOUNT_DEFERRED=""
LABELED=()
# log the SELinux mode and host policy state
note_enforcing_deferrals() {
  local m state
  m=$(teardown_selinux_mode) || failstop "selinux-mode-unreadable" "failed to read the SELinux mode"
  if [[ "$m" == namespace ]]; then
    state=$(teardown_host_policy_state)
    if [[ "$state" != none ]] && teardown_android_policy_loaded; then
      log "selinux mode namespace, Android's policy loaded host-wide"
      return 0
    fi
    case "$state" in
      none) log "selinux mode namespace, no host policy" ;;
      permissive) log "selinux mode namespace, host policy permissive" ;;
      enforcing) log "selinux mode namespace, host policy enforcing" ;;
      *) log "selinux mode namespace, unknown host SELinux state ($TEARDOWN_SELINUX_ENFORCE" \
             "is '$(cat "$TEARDOWN_SELINUX_ENFORCE" 2>&1)')" ;;
    esac
  elif [[ "$(cat "$TEARDOWN_SELINUX_ENFORCE" 2>/dev/null)" == 1 ]]; then
    log "selinux is enforcing"
  fi
}
note_enforcing_deferrals

[[ $EUID -eq 0 ]] || refuse "not-root" "EUID $EUID is not 0"

ANY_CHANGE=0

restore_default_entry
remove_cmdline_tokens

swap_out=$(teardown_swap "$INSTALL_RECORD" /swapfile "$SWAP_FSTAB_LINE" /etc/fstab /proc/swaps) \
  || failstop "swap-teardown-failed" "$(tail -1 <<<"$swap_out")"
while IFS= read -r line; do
  case "$line" in
    removed-fstab) mark_change "/swapfile's /etc/fstab line" ;;
    removed-file)  mark_change "/swapfile" ;;
    deferred-file\ *)
      log "  ${line#deferred-file }"
      SWAPFILE_DEFERRED=1
      mark_change "/swapfile at the next boot" ;;
    kept-file) log "/swapfile is not in $INSTALL_RECORD" ;;
  esac
done <<<"$swap_out"

if [[ -e "$MODULES_LOAD_CONF" ]]; then
  rm -f "$MODULES_LOAD_CONF" || failstop "modules-load-conf-rm-failed" "failed to remove $MODULES_LOAD_CONF"
  mark_change "$MODULES_LOAD_CONF"
fi

if [[ "$(teardown_host_policy_state)" != none ]] && ! teardown_android_policy_loaded; then
  xattr_out=""
  labels=$(selinux_xattr_report list) || failstop "label-scan-failed" "selinux_xattr_report list failed"
  if [[ -n "$labels" ]]; then
    log "  host mode label on $(host_labels_named "$labels") under the host SELinux policy"
  fi
else
  xattr_out="$(selinux_xattr_report clear)" || {
    log "  selinux_xattr_report clear failed"
    XATTRS_DEFERRED=1
  }
  echo "$xattr_out" | sed "s/^/[$PROG]   /" >&2
fi
if [[ -e "$HOST_LABELS_PENDING" ]]; then
  rm -f "$HOST_LABELS_PENDING" || failstop "host-labels-record-rm-failed" "failed to remove $HOST_LABELS_PENDING"
  mark_change "$HOST_LABELS_PENDING"
fi
if [[ -e "$HOST_MODE_KEPT" ]]; then
  rm -f "$HOST_MODE_KEPT" || failstop "host-mode-kept-rm-failed" "failed to remove $HOST_MODE_KEPT"
  mark_change "$HOST_MODE_KEPT"
fi
if grep -q '^cleared:' <<<"$xattr_out"; then
  mark_change "the selinux host-entrypoint xattrs ($(grep -c '^cleared:' <<<"$xattr_out") of ${#HOST_EXEC_PATHS[@]})"
fi
if (( XATTRS_DEFERRED )); then
  mapfile -t LABELED < <(selinux_xattr_report labeled)
  log "  scheduling ${#LABELED[@]} labels for the next boot (${LABELED[*]:-<none>})"
  n_modlabels=$(selinux_xattr_report modlabeled)
  if [[ "$n_modlabels" =~ ^[0-9]+$ ]] && (( n_modlabels > 0 )); then
    # shellcheck disable=SC2034
    MODULE_LABELS_DEFERRED=1
    log "  scheduling $n_modlabels module-tree labels under $HOST_MODULE_ROOT for the next boot"
  fi
fi

launch_trees=()
for p in "${RHIZO_TEARDOWN_LIB_LAUNCH_TREES[@]}"; do
  for g in $p; do
    [[ -e "$g" ]] && launch_trees+=("$g")
  done
done
for d in "$PREPARED_ROOT" "$TEMPLATES_ROOT" "$DERIVED_ROOT" "${launch_trees[@]}"; do
  if [[ -e "$d" ]]; then
    if mounted_under "$d"; then
      log "  deferring $d to rhizo-final-cleanup.service, a mount under $d is still mounted"
      DEFERRED_REMOVALS=1
    else
      rm_or_defer "$d"
    fi
    mark_change "$d"
  fi
done

if [[ -e "$VAR_CACHE" ]]; then
  rm_or_defer "$VAR_CACHE"
  mark_change "$VAR_CACHE"
fi
for d in "${LAUNCH_DIRS[@]}"; do
  [[ -e "$d" || -L "$d" ]] || continue
  if busy_mount=$(teardown_unmount_reaching "$d"); then
    rm_or_defer "$d"
  else
    log "  deferring $d to rhizo-final-cleanup.service, $busy_mount is still mounted"
    DEFERRED_REMOVALS=1
  fi
  mark_change "$d"
done
if [[ -e "$VAR_LOG" ]]; then
  rm_or_defer "$VAR_LOG"
  mark_change "$VAR_LOG"
fi
for f in "$PREPARE_BOOT_LOG" "$PREPARE_ANDROIDD_ENV" "$PREPARED_SENTINEL"; do
  if [[ -e "$f" ]]; then
    rm -f "$f" || { log "  deferring $f to rhizo-final-cleanup.service, rm failed"; DEFERRED_REMOVALS=1; }
    mark_change "$f"
  fi
done
removed_root_state=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if rm -rf "$f"; then
    removed_root_state+=("$f")
  else
    log "  deferring $f to rhizo-final-cleanup.service, rm failed"
    DEFERRED_REMOVALS=1
  fi
done < <(root_state_present)
(( ${#removed_root_state[@]} )) && mark_change "${#removed_root_state[@]} /root/.rhizo_* state files (${removed_root_state[*]})"
if [[ -e "$LOOP_UDEV_RULE" ]]; then
  if rm -f "$LOOP_UDEV_RULE"; then
    command -v udevadm >/dev/null 2>&1 && udevadm control --reload 2>/dev/null
    mark_change "$LOOP_UDEV_RULE"
  else
    log "  deferring $LOOP_UDEV_RULE to rhizo-final-cleanup.service, rm failed"
    DEFERRED_REMOVALS=1
  fi
fi
if [[ -e "$UPGRADE_FROM" ]]; then
  rm -f "$UPGRADE_FROM" && mark_change "$UPGRADE_FROM"
fi

removed_units=()
for u in "${UNITS[@]}"; do
  [[ -e "/etc/systemd/system/$u" ]] || continue
  case "$u" in
    *.service) systemctl stop "$u" >/dev/null 2>&1 ;;
    *.path)    systemctl stop "$u" >/dev/null 2>&1 ;;
  esac
  systemctl disable "$u" >/dev/null 2>&1
  rm -f "/etc/systemd/system/$u" || failstop "unit-rm-failed" "failed to remove /etc/systemd/system/$u"
  removed_units+=("$u")
done
for d in "${UNIT_DROPINS[@]}"; do
  [[ -e "/etc/systemd/system/$d" ]] || continue
  rm -f "/etc/systemd/system/$d" || failstop "unit-rm-failed" "failed to remove /etc/systemd/system/$d"
  rmdir "$(dirname "/etc/systemd/system/$d")" 2>/dev/null
  removed_units+=("$d")
done
desk_owner=$(cat "$ETC_RHIZO/desktop-user" 2>/dev/null)
if [[ -n "$desk_owner" && "$(systemctl is-active user@1000.service 2>/dev/null)" == active ]]; then
  runuser -u "$desk_owner" -- env XDG_RUNTIME_DIR=/run/user/1000 \
    systemctl --user stop "${USER_UNITS[@]}" >/dev/null 2>&1
fi
for u in "${USER_UNITS[@]}"; do
  [[ -e "$USER_UNIT_DIR/$u" || -L "$USER_UNIT_DIR/$u" ]] || continue
  rm -f "$USER_UNIT_DIR/$u" || failstop "unit-rm-failed" "failed to remove $USER_UNIT_DIR/$u"
  removed_units+=("$USER_UNIT_DIR/$u")
done
if (( ${#removed_units[@]} )); then
  systemctl daemon-reload >/dev/null 2>&1
  mark_change "${#removed_units[@]} systemd units (${removed_units[*]})"
fi
if (( ${#STOPPED_INSTANCES[@]} )); then
  for inst in "${STOPPED_INSTANCES[@]}"; do
    systemctl disable "$inst" >/dev/null 2>&1
  done
  systemctl daemon-reload >/dev/null 2>&1
  mark_change "${#STOPPED_INSTANCES[@]} per-instance units (${STOPPED_INSTANCES[*]})"
fi
if [[ -e "$APPWATCH_BIN" ]]; then
  rm -f "$APPWATCH_BIN" || { log "  deferring $APPWATCH_BIN to rhizo-final-cleanup.service, rm failed"; DEFERRED_REMOVALS=1; }
  mark_change "$APPWATCH_BIN"
fi

removed_entries=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rm -f "$f" || failstop "desktop-entry-rm-failed" "failed to remove $f"
  removed_entries+=("$(basename "$f")")
done < <(rhizo_desktop_entries)
(( ${#removed_entries[@]} )) && mark_change "${#removed_entries[@]} desktop entries (${removed_entries[*]})"

removed_icons=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rm -f "$f" || failstop "icon-rm-failed" "failed to remove $f"
  removed_icons=$((removed_icons + 1))
done < <(rhizo_icons)
(( removed_icons )) && mark_change "$removed_icons icons under $ICON_THEME_ROOT"

for list in "$SYSTEM_MIMEAPPS" "$KDE_MIMEAPPS"; do
  [[ -f "$list" ]] || continue
  dropped=$(strip_mimeapps_defaults "$list" apply)
  (( dropped )) && mark_change "$dropped rhizo default applications in $list"
done

removed_metainfo=0
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  rm -f "$f" || failstop "metainfo-rm-failed" "failed to remove $f"
  removed_metainfo=$((removed_metainfo + 1))
done < <(rhizo_metainfo)
(( removed_metainfo )) && mark_change "$removed_metainfo AppStream metainfo files under $METAINFO_DIR"

if (( ${#removed_entries[@]} || removed_icons )); then
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPLICATIONS_DIR" \
      || failstop "update-desktop-database-failed" "update-desktop-database $APPLICATIONS_DIR failed"
  else
    log "  no update-desktop-database"
  fi
fi

if [[ -d "$BROKER_RUNTIME_DIR" ]]; then
  rm -rf "$BROKER_RUNTIME_DIR" || failstop "broker-dir-rm-failed" "failed to remove $BROKER_RUNTIME_DIR"
  mark_change "$BROKER_RUNTIME_DIR"
fi
if [[ -d "$DESKTOP_SESSION_DIR" ]]; then
  rm -rf "$DESKTOP_SESSION_DIR" || failstop "desktop-session-dir-rm-failed" "failed to remove $DESKTOP_SESSION_DIR"
  mark_change "$DESKTOP_SESSION_DIR"
fi
remove_selinuxns_records

if [[ -f "$INSTALL_RECORD" ]] && grep -qx pacman-downloaduser "$INSTALL_RECORD"; then
  if (
    # shellcheck source=pkg-lib.sh
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/pkg-lib.sh" \
      && RHIZO_INSTALL_RECORD="$INSTALL_RECORD" pkg_pacman_downloaduser_restore
  ); then
    mark_change "the '# rhizo' DownloadUser comment in /etc/pacman.conf"
    sed -i '/^pacman-downloaduser$/d' "$INSTALL_RECORD" \
      || failstop "install-record-edit-failed" "failed to remove pacman-downloaduser from $INSTALL_RECORD"
  else
    log "  pkg_pacman_downloaduser_restore failed"
  fi
fi

if [[ -f "$INSTALL_RECORD" ]] && grep -qx login-defs-tty "$INSTALL_RECORD"; then
  if (
    # shellcheck source=pkg-lib.sh
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/pkg-lib.sh" \
      && RHIZO_INSTALL_RECORD="$INSTALL_RECORD" pkg_login_tty_restore
  ); then
    mark_change "the rhizo TTYGROUP and TTYPERM lines in /etc/login.defs"
    sed -i '/^login-defs-tty$/d' "$INSTALL_RECORD" \
      || failstop "install-record-edit-failed" "failed to remove login-defs-tty from $INSTALL_RECORD"
  else
    log "  pkg_login_tty_restore failed"
  fi
fi

if [[ -f "$INSTALL_RECORD" ]] && grep -qx host-mode-links "$INSTALL_RECORD"; then
  if (
    # shellcheck source=pkg-lib.sh
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/pkg-lib.sh" \
      && RHIZO_INSTALL_RECORD="$INSTALL_RECORD" pkg_host_mode_unlink
  ); then
    systemctl daemon-reload >/dev/null 2>&1
    mark_change "the host-mode links"
  else
    log "  pkg_host_mode_unlink failed"
  fi
fi

if [[ -f "$INSTALL_RECORD" ]] && grep -qx "group:$BROKER_GROUP" "$INSTALL_RECORD"; then
  if getent group "$BROKER_GROUP" >/dev/null; then
    groupdel "$BROKER_GROUP" || failstop "groupdel-failed" "groupdel $BROKER_GROUP failed"
    mark_change "group $BROKER_GROUP"
  fi
  sed -i "\#^group:$BROKER_GROUP\$#d" "$INSTALL_RECORD" \
    || failstop "install-record-edit-failed" "failed to remove group:$BROKER_GROUP from $INSTALL_RECORD"
  [[ -s "$INSTALL_RECORD" ]] || rm -f "$INSTALL_RECORD"
fi

# log the result of removing an account
report_account() {
  local line
  while IFS= read -r line; do
    case "$line" in
      removed-user\ *)  mark_change "system account ${line#removed-user }" ;;
      removed-group\ *) mark_change "group ${line#removed-group }" ;;
      kept-user\ *)     log "  account ${line#kept-user }" ;;
      failed\ *)        log "  ${line#failed } failed for $1" ;;
    esac
  done <<<"$2"
}
account_out=$(teardown_remove_appwatch_account "$INSTALL_RECORD"); account_rc=$?
report_account "uid 1000" "$account_out"
(( account_rc )) && ACCOUNT_DEFERRED="$APPWATCH_ACCOUNT"
netbridged_out=$(teardown_remove_netbridged_account "$INSTALL_RECORD"); netbridged_rc=$?
report_account "$NETBRIDGED_ACCOUNT" "$netbridged_out"
(( netbridged_rc )) && ACCOUNT_DEFERRED+="${ACCOUNT_DEFERRED:+ }$NETBRIDGED_ACCOUNT"
uhid_out=$(teardown_remove_recorded_account "$INSTALL_RECORD" "$UHID_ACCOUNT"); uhid_rc=$?
report_account "$UHID_ACCOUNT" "$uhid_out"
(( uhid_rc )) && ACCOUNT_DEFERRED+="${ACCOUNT_DEFERRED:+ }$UHID_ACCOUNT"
for f in "$RHIZO_TEARDOWN_LIB_DESKTOP_USER" "$RHIZO_TEARDOWN_LIB_INSTALL_FAILED"; do
  [[ -e "$f" ]] || continue
  rm -f "$f" \
    || { log "  deferring $f to rhizo-final-cleanup.service, rm failed"; DEFERRED_REMOVALS=1; }
  mark_change "$f"
done

removed_links=()
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  rm -f "$l" && removed_links+=("$l")
  rmdir "$(dirname "$l")" 2>/dev/null
done < <(unit_enable_links "$( (( PURGE )) && echo all || echo foreign)")
if (( ${#removed_links[@]} )); then
  systemctl daemon-reload >/dev/null 2>&1
  mark_change "${#removed_links[@]} unit enablement links (${removed_links[*]})"
fi

if (( PURGE )); then
  if [[ -e "$DATA_IMG" ]]; then
    rm -f "$DATA_IMG" "$DATA_IMG.meta" || { log "  deferring $DATA_IMG to rhizo-final-cleanup.service, rm failed"; DEFERRED_REMOVALS=1; }
    mark_change "$DATA_IMG"
  fi
  if [[ -e "$UPDATE_ROOT" ]]; then
    rm_or_defer "$UPDATE_ROOT"
    mark_change "$UPDATE_ROOT"
  fi
  if [[ -d "$ETC_RHIZO" ]]; then
    rm_or_defer "$ETC_RHIZO"
    mark_change "$ETC_RHIZO"
  fi
  shopt -s nullglob
  gsi_trees=(/srv/rhizo/gsi_system*)
  shopt -u nullglob
  if (( ${#gsi_trees[@]} )); then
    rm_or_defer "${gsi_trees[@]}"
    mark_change "${#gsi_trees[@]} GSI trees under /srv/rhizo"
  fi
  rmdir /srv/rhizo 2>/dev/null && mark_change "/srv/rhizo"
  if [[ -d "$STATE_ROOT" ]]; then
    if mounted_under "$STATE_ROOT"; then
      log "  deferring $STATE_ROOT to rhizo-final-cleanup.service, a mount under $STATE_ROOT is still mounted"
      DEFERRED_REMOVALS=1
    elif rm -rf "$STATE_ROOT" && [[ ! -e "$STATE_ROOT" ]]; then
      mark_change "$STATE_ROOT"
    else
      log "  deferring $STATE_ROOT to rhizo-final-cleanup.service, rm -rf failed"
      DEFERRED_REMOVALS=1
    fi
  fi
else
  if [[ -e "$DATA_IMG" ]]; then
    log "$DATA_IMG exists without --purge"
  fi
  shopt -s nullglob
  gsi_trees=(/srv/rhizo/gsi_system*)
  shopt -u nullglob
  (( ${#gsi_trees[@]} )) && log "${#gsi_trees[@]} GSI trees under /srv/rhizo exist without --purge"
fi

if [[ -f "$INSTALL_RECORD" ]] && grep -qx 'selinux-mode namespace' "$INSTALL_RECORD"; then
  sed -i '/^selinux-mode namespace$/d' "$INSTALL_RECORD" \
    || failstop "install-record-edit-failed" "failed to remove selinux-mode namespace from $INSTALL_RECORD"
  [[ -s "$INSTALL_RECORD" ]] || rm -f "$INSTALL_RECORD"
fi

DEFERRED=()
teardown_deferred_paths "$PURGE"
# print the DEFERRED paths that exist
deferred_paths_present() {
  local p g
  for p in "${DEFERRED[@]}"; do
    for g in $p; do
      [[ -e "$g" ]] && echo "$g"
    done
  done
  true
}
if [[ -n "$(deferred_paths_present)" || -n "$ACCOUNT_DEFERRED" ]] \
   || (( XATTRS_DEFERRED || DEFERRED_REMOVALS || ${#REGEN_DEFERRED[@]} || SWAPFILE_DEFERRED )); then
  cleanup_unit_text=$(teardown_final_cleanup_unit "$PURGE") \
    || failstop "cleanup-unit-render-failed" "teardown_final_cleanup_unit failed"
  cat > /etc/systemd/system/rhizo-final-cleanup.service <<<"$cleanup_unit_text" \
    || failstop "cleanup-unit-write-failed" "failed to write /etc/systemd/system/rhizo-final-cleanup.service"
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable rhizo-final-cleanup.service >/dev/null 2>&1 || true
  ANY_CHANGE=1
  regen_names=""
  for kind in "${REGEN_DEFERRED[@]}"; do
    regen_names+=", $(bootloader_regen_label "$kind")"
  done
  log "scheduled rhizo-final-cleanup.service for the next boot (${DEFERRED[*]}${LABELED[*]:+, the labels on ${LABELED[*]}}$regen_names$( (( SWAPFILE_DEFERRED )) && echo ', /swapfile')${ACCOUNT_DEFERRED:+, accounts $ACCOUNT_DEFERRED})"
fi

if (( ! ANY_CHANGE )); then
  log "nothing found to remove"
  if rhizo_kernel_note; then
    echo "RHIZO_TEARDOWN_REBOOT_REQUIRED=1"
    exit 0
  fi
  echo "RHIZO_TEARDOWN_ALREADY_CLEAN=1"
  exit 0
fi

if reboot_needed_for_lsm; then
  log "selinux is in the active LSM list"
  if [[ "$FLAVOR" == cachyos ]]; then
    keeps=1 unread=0 carried=""
    if [[ -n "${DETECTED_KIND:-}" ]]; then
      keeps=0; host_lsm=$(host_lsm_keeps_selinux "$DETECTED_KIND" "${REMOVED_TOKENS:-}") || keeps=$?
    fi
    (( keeps != 2 )) || unread=1
    if (( keeps == 0 )); then
      log "the host $host_lsm on the next boot cmdline has selinux as the major LSM"
    elif (( ${#LEFT_CONFIGS[@]} )); then
      for left in "${LEFT_CONFIGS[@]}"; do
        log "${left%%$'\t'*} has the rhizo tokens, no $(regen_choices "${left#*$'\t'}" name)"
      done
    elif (( ${#REGEN_DEFERRED[@]} && ! unread )); then
      log "rhizo-final-cleanup.service regenerates the bootloader config at the next boot"
    elif (( ${#REGEN_DEFERRED[@]} )); then
      log "rhizo-final-cleanup.service regenerates the bootloader config at the next boot, failed to read the cmdlines"
    else
      (( unread )) || carried=$(rhizo_tokens_carried "${DETECTED_KIND:-}" "${REMOVED_TOKENS:-}") || unread=1
      if (( unread )); then
        log "failed to read the next boot cmdlines"
      elif [[ -n "$carried" ]]; then
        while IFS=$'\t' read -r kind tokens; do
          log "$(bootloader_generated "$kind") has rhizo tokens$tokens"
        done <<<"$carried"
      else
        log "no next boot cmdline has the rhizo selinux tokens"
      fi
    fi
  else
    log "the kernel loads AppArmor at the next boot"
  fi
  rhizo_kernel_note
  echo "RHIZO_TEARDOWN_REBOOT_REQUIRED=1"
  exit 0
fi

if rhizo_kernel_note; then
  echo "RHIZO_TEARDOWN_REBOOT_REQUIRED=1"
  exit 0
fi
if (( ${TEARDOWN_NS_INSTALL:-0} )); then
  log "selinux mode namespace, no reboot required"
else
  log "no reboot required"
fi
echo "RHIZO_TEARDOWN_OK removed=1"
