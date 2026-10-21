#!/bin/bash
# write the kernel cmdline tokens rhizo needs
set -uo pipefail

PROG=rhizo-host-bootstrap
log() { echo "[$PROG] $*"; }
die() { echo "[$PROG] FAIL: $*" >&2; exit 1; }
# print the usage text
usage() {
  cat <<'EOF'
Usage: src/install/bootstrap/bootstrap.sh [options]
  (no options)      write the cmdline tokens; ends with RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1 or ..._ALREADY_APPLIED=1
  --verify          check the result after the reboot, ending with RHIZO_BOOTSTRAP_VERIFIED=1; changes nothing
  --lsm-list        in host mode on Ubuntu, write an explicit lsm= list instead of security=selinux
  --vbmeta-digest X set the androidboot.vbmeta.digest value (default: the pinned GSI's)
  --show            print the cmdline tokens that would be written, then exit; changes nothing
EOF
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-flavor.sh
. "$HERE/../lib/host-flavor.sh" || die "cannot read $HERE/../lib/host-flavor.sh"
# shellcheck source=bootloader.sh
. "$HERE/bootloader.sh" || die "cannot read $HERE/bootloader.sh"
FLAVOR=$(host_flavor)
CMDLINE_FILE="${RHIZO_BOOTSTRAP_CMDLINE:-/proc/cmdline}"
PROC_SWAPS="${RHIZO_BOOTSTRAP_SWAPS:-/proc/swaps}"
MEMINFO="${RHIZO_BOOTSTRAP_MEMINFO:-/proc/meminfo}"
SELINUXFS="${RHIZO_BOOTSTRAP_SELINUXFS:-/sys/fs/selinux}"
ZSWAP_ENABLED="${RHIZO_BOOTSTRAP_ZSWAP:-/sys/module/zswap/parameters/enabled}"
ATTR_CURRENT="${RHIZO_BOOTSTRAP_ATTR_CURRENT:-/proc/self/attr/current}"
BINDER_DEVICES_FILE="${RHIZO_BINDER_DEVICES_FILE:-/sys/module/binder/parameters/devices}"
BINDER_DEVICES_WANT="binder,hwbinder,vndbinder"
cmdline_has() { [[ " $(cat "$CMDLINE_FILE") " == *" $1"* ]]; }

MODE=apply
LSM_STYLE=security
VBMETA_DIGEST="095fdab58d1f3bf532d502403738752341bedbbcd73c38ec1349105d54728b4e"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) MODE=verify; shift ;;
    --show) MODE=show; shift ;;
    --lsm-list) LSM_STYLE=list; shift ;;
    --vbmeta-digest) VBMETA_DIGEST="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

SELINUX_MODE_HELPER="${RHIZO_SELINUX_MODE_HELPER:-/usr/lib/rhizo/rhizo-selinux-mode}"
SELINUX_MODE_ENV=(--env-file "${RHIZO_ANDROIDD_ENV:-/etc/rhizo/androidd.env}")
SELINUX_MODE=$("$SELINUX_MODE_HELPER" "${SELINUX_MODE_ENV[@]}" --configured) \
  || die "cannot read the configured SELinux mode from $SELINUX_MODE_HELPER"
case "$SELINUX_MODE" in
  host) ;;
  namespace)
    [[ "$LSM_STYLE" != list ]] || die "--lsm-list writes an lsm= list, which selinux namespace mode never writes" ;;
  *) die "$SELINUX_MODE_HELPER --configured printed '$SELINUX_MODE', which is neither host nor namespace" ;;
esac
# shellcheck disable=SC2034
BL_SAVED_DEFAULT=1

# set LSM_TOKENS to the LSM list with selinux
lsm_list_tokens() {
  if ! LSM_TOKENS=$(host_lsm_list_with_selinux 2>&1); then
    [[ "$LSM_STYLE" == list ]] \
      && die "--lsm-list builds its list from the active one, but $RHIZO_LSM_FILE cannot be read: ${LSM_TOKENS##*: }"
    die "off Ubuntu rhizo's lsm= list is the active one with selinux ahead of bpf, but $RHIZO_LSM_FILE cannot be read:" \
        "${LSM_TOKENS##*: }"
  fi
}
LSM_FROM_HOST_LINE=0
LSM_TOKENS=""
SELINUX_TOKENS="enforcing=0"
if [[ "$SELINUX_MODE" == namespace ]]; then
  SELINUX_TOKENS=""
elif [[ "$FLAVOR" == ubuntu ]]; then
  if [[ "$LSM_STYLE" == security ]]; then
    LSM_TOKENS="security=selinux"
  else
    LSM_TOKENS="lsm=lockdown,capability,landlock,yama,integrity,selinux,bpf"
  fi
elif [[ "$LSM_STYLE" == list ]]; then
  lsm_list_tokens
else
  LSM_FROM_HOST_LINE=1
  lsm_list_tokens
fi

ANDROIDBOOT_TOKENS="androidboot.hardware=rhizo androidboot.selinux=permissive androidboot.use_memfd=1 androidboot.first_stage_console=0 androidboot.verifiedbootstate=orange androidboot.veritymode=disabled androidboot.vbmeta.digest=${VBMETA_DIGEST}"

DEBUG_TOKENS="loglevel=8 log_buf_len=16M audit_backlog_limit=32768 systemd.unified_cgroup_hierarchy=1"

LOOP_TOKENS="loop.max_loop=${RHIZO_LOOP_MAX_LOOP:-64}"

swap_on_zram() { awk 'NR > 1 && $1 ~ /^\/dev\/zram/ {found = 1} END {exit !found}' "$PROC_SWAPS"; }
ZSWAP_TOKENS="zswap.enabled=1"
if [[ "$FLAVOR" != ubuntu ]] && swap_on_zram; then
  ZSWAP_TOKENS=""
fi

BINDER_TOKENS=""
if [[ "$FLAVOR" != ubuntu && -r "$BINDER_DEVICES_FILE" ]] \
   && { [[ "$(cat "$BINDER_DEVICES_FILE")" != "$BINDER_DEVICES_WANT" ]] || cmdline_has "binder.devices=$BINDER_DEVICES_WANT "; }; then
  BINDER_TOKENS="binder.devices=$BINDER_DEVICES_WANT"
fi

# join the token lists into ALL_TOKENS
all_tokens() {
  ALL_TOKENS="${LSM_TOKENS:+$LSM_TOKENS }${SELINUX_TOKENS:+$SELINUX_TOKENS }$DEBUG_TOKENS $LOOP_TOKENS${ZSWAP_TOKENS:+ $ZSWAP_TOKENS}"
  ALL_TOKENS+="${BINDER_TOKENS:+ $BINDER_TOKENS} $ANDROIDBOOT_TOKENS"
}
# print the lsm= setting from the bootloader lines
host_line_lsm() {
  local line last list="" rc
  local -a lines=()
  mapfile -t lines < <(bl_host_lines "$1"; echo "rc=$?")
  rc=${lines[-1]#rc=}; unset 'lines[-1]'
  (( rc == 0 )) || return "$rc"
  (( ${#lines[@]} )) || return 0
  for line in "${lines[@]}"; do
    last=$(bl_last_setting lsm "$line") || return 0
    bl_lsm_selinux_usable "${last#*=}" || return 0
    [[ -n "$list" ]] || list=$last
  done
  echo "$list"
}
all_tokens

if [[ "$MODE" == show ]]; then
  if (( LSM_FROM_HOST_LINE )); then
    rc=0; show_kind=$(bootloader_kind 2>&1) || rc=$?
    why=$show_kind
    (( rc != 0 )) || { why=$(bl_host_lines "$show_kind" 2>&1 >/dev/null) || rc=$?; }
    if (( rc == 0 )); then
      host_lsm=$(host_line_lsm "$show_kind") \
        || die "cannot read the host's own cmdline settings for $show_kind (see above)"
      if [[ -n "$host_lsm" ]]; then LSM_TOKENS=$host_lsm; all_tokens; fi
    elif (( rc == 2 )); then
      echo "[$PROG] the LSM token shown is the running cmdline's: the bootstrap, run as root, chooses it from this" \
           "host's own configured line, which this caller cannot read (${why//$'\n'/; })" >&2
    else
      echo "[$PROG] the LSM token shown is the running cmdline's, as the bootstrap would stop on this host:" \
           "${why//$'\n'/; }" >&2
    fi
  fi
  echo "$ALL_TOKENS"
  exit 0
fi

lsm_active() { cat "$RHIZO_LSM_FILE" 2>/dev/null || echo ""; }
selinux_present() { [[ -e "$SELINUXFS/enforce" ]]; }
# mount selinuxfs at $SELINUXFS
mount_selinuxfs() {
  [[ ",$(lsm_active)," == *",selinux,"* && -d "$SELINUXFS" ]] && ! selinux_present || return 0
  mount -t selinuxfs selinuxfs "$SELINUXFS" \
    || die "selinux is an active LSM but selinuxfs cannot be mounted at $SELINUXFS"
}
judges_overrides() { [[ "$FLAVOR" != ubuntu ]]; }
# print the selinux LSM token from a cmdline
rhizo_lsm_before_last() {
  local i last=-1 found=""
  local -a w
  read -ra w <<<"$1"
  for i in "${!w[@]}"; do [[ "${w[i]}" != lsm=* ]] || last=$i; done
  for i in "${!w[@]}"; do
    if [[ "${w[i]}" == security=selinux ]] \
       || { (( i < last )) && [[ "${w[i]}" == lsm=* && ",${w[i]#lsm=}," == *",selinux,"* ]]; }; then
      found=${w[i]}
    fi
  done
  [[ -n "$found" ]] && echo "$found"
}
zswap_on() { [[ "$(cat "$ZSWAP_ENABLED" 2>/dev/null)" == "Y" ]]; }

# print the active LSM list and SELinux state
report_state() {
  local active; active="$(lsm_active)"
  log "  $RHIZO_LSM_FILE : ${active:-<securityfs not mounted>}"
  log "  $SELINUXFS          : $(selinux_present && echo present || echo absent)"
  if selinux_present; then
    log "  $SELINUXFS/enforce  : $(cat "$SELINUXFS/enforce" 2>/dev/null || echo '<unreadable>')"
  fi
  log "  $CMDLINE_FILE            : $(tr -s ' ' < "$CMDLINE_FILE")"
}

# check zswap and swap after the reboot
verify_swap() {
  ZSWAP_VERIFIED=0
  if [[ "$FLAVOR" == ubuntu ]] || cmdline_has "zswap.enabled=1 "; then
    zswap_on || die "zswap.enabled=1 was written to the cmdline but $ZSWAP_ENABLED is not 'Y' after reboot"
    log "  zswap                    : active"
    ZSWAP_VERIFIED=1
  elif swap_on_zram; then
    log "  zswap                    : not requested (swap is on zram)"
  else
    log "  zswap                    : not on the cmdline, and no zram swap is active"
  fi
  swap_up=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [[ "$(wc -l < "$PROC_SWAPS")" -ge 2 ]]; then swap_up=1; break; fi
    sleep 1
  done
  if [[ "$swap_up" == 1 ]]; then
    log "  swap                     : active ($(grep ^SwapTotal "$MEMINFO" | tr -s ' '))"
  else
    log "  swap                     : NONE after a 10s wait for swap.target -- no swapfile was provisioned, or systemd failed to activate $(systemctl is-failed swapfile.swap 2>/dev/null || echo swapfile.swap)"
  fi
}

if [[ "$MODE" == verify && "$SELINUX_MODE" == namespace ]]; then
  log "post-reboot verification"
  report_state
  BL_KIND=$(bootloader_kind 2>&1) || die "$BL_KIND"
  default_entry=$(bootloader_default_entry "$BL_KIND") || die "cannot read the default boot entry of $BL_KIND (see above)"
  bl_rhizo_entry "$default_entry" \
    || die "the default boot entry is '${default_entry:-the first entry}', not the Rhizo kernel -- choose the Rhizo kernel in the boot menu, or run the bootstrap again"
  log "  default boot entry       : $default_entry"
  running_out=$("$SELINUX_MODE_HELPER" "${SELINUX_MODE_ENV[@]}" --mode-and-why) || die "$SELINUX_MODE_HELPER cannot tell the SELinux mode this boot starts Android in"
  IFS=$'\t' read -r running_mode running_why <<<"$running_out"
  [[ "$running_mode" == namespace ]] \
    || die "this boot cannot start Android in selinux namespace mode: ${running_why:-$SELINUX_MODE_HELPER named no reason} ($running_mode)"
  log "  selinux mode             : namespace"
  verify_swap
  verified="the Rhizo kernel is the default boot entry and runs Android in selinux namespace mode"
  (( ! ZSWAP_VERIFIED )) || verified+=", and zswap is active"
  log "VERIFIED: $verified"
  log "RHIZO_BOOTSTRAP_VERIFIED=1"
  exit 0
fi

if [[ "$MODE" == verify ]]; then
  log "post-reboot verification"
  mount_selinuxfs
  report_state
  active="$(lsm_active)"
  if [[ ",$active," != *",selinux,"* ]] || { judges_overrides && bl_lsm_bpf_first "$active"; }; then
    head="selinux is not in the active LSM list"
    if [[ ",$active," == *",selinux,"* ]]; then
      head="bpf comes before selinux in the active LSM list ($active), so /proc/<pid>/attr answers EINVAL and no"
      head+=" SELinux context can be read or set"
    fi
    cmdline=$(cat "$CMDLINE_FILE")
    if judges_overrides && last=$(bl_last_setting lsm "$cmdline") && ! bl_lsm_selinux_usable "${last#lsm=}" \
       && rtok=$(rhizo_lsm_before_last "$cmdline"); then
      { IFS= read -r what; IFS= read -r fix; } <<<"$(bl_lsm_fault "${last#lsm=}")"
      if [[ "$rtok" == security=* ]]; then
        why="$CMDLINE_FILE carries $last, which voids rhizo's $rtok, as the kernel ignores security= beside any"
        why+=" lsm=, and"
      else
        why="$CMDLINE_FILE's last lsm=, $last, comes after rhizo's and"
      fi
      die "$head -- $why $what; remove that lsm= from the host's own line, or $fix, then run the bootstrap again"
    fi
    [[ ",$active," != *",selinux,"* ]] \
      || die "$head -- run the bootstrap again, which writes an lsm= list with selinux ahead of bpf, and reboot"
    die "selinux is not in the active LSM list -- the reboot did not take effect, or the cmdline did not carry it"
  fi
  selinux_present || die "selinux is an active LSM but $SELINUXFS is not mounted"
  [[ -r "$SELINUXFS/enforce" ]] || die "$SELINUXFS/enforce is not readable -- SELinux is not usable"
  if [[ ",$active," == *",apparmor,"* ]]; then
    die "apparmor is ALSO active"
  fi
  if judges_overrides; then
    ctx=$(cat "$ATTR_CURRENT" 2>&1) \
      || die "selinux is active but $ATTR_CURRENT cannot be read (${ctx##*: }), so no SELinux context can be read or" \
             "set through /proc/<pid>/attr"
    log "  $ATTR_CURRENT : $ctx"
  fi
  verify_swap
  if (( ZSWAP_VERIFIED )); then
    verified="SELinux is the active exclusive LSM, selinuxfs is mounted, and zswap is active"
  else
    verified="SELinux is the active exclusive LSM and selinuxfs is mounted"
  fi
  log "VERIFIED: $verified"
  log "RHIZO_BOOTSTRAP_VERIFIED=1"
  exit 0
fi

[[ $EUID -eq 0 ]] || die "must run as root (it edits the bootloader configuration)"

[[ "$FLAVOR" == ubuntu || "$FLAVOR" == cachyos ]] \
  || die "this host is '${FLAVOR#unsupported:}' -- Rhizo supports Ubuntu 24.04 and CachyOS"

arch="$(uname -m)"
[[ "$arch" == x86_64 || "$arch" == aarch64 ]] || die "this host is $arch, neither x86_64 nor aarch64 -- out of scope"

# require CONFIG_<sym>=y in the kernel config
need_kconfig() {
  local err rc=0
  err=$(host_kconfig_has "$1" 2>&1) || rc=$?
  case $rc in
    0) return 0 ;;
    1) die "$(host_kconfig_source) does not set CONFIG_$1=y -- $2" ;;
  esac
  die "$err -- cannot confirm this kernel has CONFIG_$1=y"
}
if [[ "$SELINUX_MODE" == host ]]; then
  need_kconfig SECURITY_SELINUX "this kernel cannot do SELinux at all, and no cmdline can change that"
  if [[ "$FLAVOR" != ubuntu ]]; then
    need_kconfig SECURITY_SELINUX_DEVELOP "enforcing=0 has no effect on this kernel, so the host's own boot would run enforcing under a policy that is not loaded yet"
  fi
fi

BL_KIND=$(bootloader_kind 2>&1) || die "$BL_KIND"
if (( LSM_FROM_HOST_LINE )); then
  host_lsm=$(host_line_lsm "$BL_KIND") || die "cannot read the host's own cmdline settings for $BL_KIND (see above)"
  if [[ -n "$host_lsm" ]]; then LSM_TOKENS=$host_lsm; all_tokens; fi
fi
DROPIN=$(bootloader_config_file "$BL_KIND")
GRUBCFG=$(bootloader_generated "$BL_KIND" 2>&1) || die "$GRUBCFG"
REGEN=$(bootloader_regen_label "$BL_KIND")

SWAPFILE="${RHIZO_BOOTSTRAP_SWAPFILE:-/swapfile}"
FSTAB="${RHIZO_BOOTSTRAP_FSTAB:-/etc/fstab}"
INSTALL_RECORD="${RHIZO_STATE_DIR:-/var/lib/rhizo}/.created-by-install"
UPGRADE_FROM="${RHIZO_STATE_DIR:-/var/lib/rhizo}/.upgrade-from"
SWAP_FSTAB_LINE="$SWAPFILE none swap sw 0 0"

# print the fstab lines for the swapfile
swapfile_fstab_entries() {
  local uuid="" label=""
  if [[ -f "$SWAPFILE" ]]; then
    uuid=$(blkid -o value -s UUID "$SWAPFILE" 2>/dev/null)
    label=$(blkid -o value -s LABEL "$SWAPFILE" 2>/dev/null)
  fi
  [[ -r "$FSTAB" ]] || return 0
  awk -v path="$SWAPFILE" -v uuid="$uuid" -v label="$label" '
    { src = $0; sub(/^[[:space:]]*#*[[:space:]]*/, "", src); sub(/[[:space:]].*$/, "", src); gsub(/"/, "", src) }
    src == path || (uuid != "" && src == "UUID=" uuid) || (label != "" && src == "LABEL=" label) { print }
  ' "$FSTAB"
}

# print the swapfile device:inode:uuid
swapfile_id() {
  local st uuid
  st=$(stat -c '%d:%i' "$SWAPFILE" 2>/dev/null) && uuid=$(blkid -o value -s UUID "$SWAPFILE" 2>/dev/null) \
    && [[ -n "$st" && -n "$uuid" ]] && echo "$st:$uuid"
}
record_has() { grep -qxF "$1" "$INSTALL_RECORD" 2>/dev/null; }
# add a token to the install record
record_add() {
  record_has "$1" && return 0
  mkdir -p "$(dirname "$INSTALL_RECORD")" && echo "$1" >> "$INSTALL_RECORD"
}
# remove a token from the install record
record_drop() {
  local kept rc=0
  record_has "$1" || return 0
  kept=$(grep -vxF -- "$1" "$INSTALL_RECORD") || rc=$?
  (( rc <= 1 )) || return 1
  if [[ -n "$kept" ]]; then printf '%s\n' "$kept" > "$INSTALL_RECORD"; else : > "$INSTALL_RECORD"; fi
}

if ! grep -q '^rhizo-kernel-default ' "$INSTALL_RECORD" 2>/dev/null; then
  bootloader_rhizo_default_preflight "$BL_KIND" || die "cannot make the Rhizo kernel the default boot entry (see above)"
fi
if [[ "$SELINUX_MODE" == host ]]; then
  record_drop "selinux-mode namespace" || die "cannot drop selinux-mode namespace from $INSTALL_RECORD"
fi

# check the swapfile id against the install record
swapfile_is_ours() {
  local id; id=$(swapfile_id)
  [[ -n "$id" ]] && record_has "swapfile:$id"
}

# record the fstab swap line and swapfile
adopt_legacy_swap() {
  local from entries id
  [[ "$FLAVOR" == ubuntu ]] || return 0
  from=$(cat "$UPGRADE_FROM" 2>/dev/null)
  [[ -n "$from" ]] && dpkg --compare-versions "$from" lt 0.1.1 || return 0
  record_has swapfile-fstab && return 0
  entries=$(swapfile_fstab_entries)
  grep -qxF "$SWAP_FSTAB_LINE" <<<"$entries" || return 0
  record_add swapfile-fstab || return 1
  log "recorded $FSTAB's '$SWAP_FSTAB_LINE' as this install's own: Rhizo $from wrote it before installs recorded that"
  if [[ "$entries" == "$SWAP_FSTAB_LINE" && -f "$SWAPFILE" ]] && id=$(swapfile_id); then
    record_add "swapfile:$id" || return 1
    log "recorded $SWAPFILE ($id) as this install's own: that line is the only entry naming it"
  fi
}

root_fstype() { stat -f -c %T /; }

# append the swap line to fstab
append_swap_fstab_line() {
  local lead=""
  [[ -s "$FSTAB" && -n "$(LC_ALL=C tail -c1 "$FSTAB")" ]] && lead=$'\n'
  record_add swapfile-fstab || { log "WARNING: could not record the fstab line in $INSTALL_RECORD -- not writing it"; return 1; }
  if [[ -n "$lead" ]]; then
    record_add swapfile-fstab-eol || { log "WARNING: could not record the fstab newline in $INSTALL_RECORD -- not writing it"; return 1; }
  fi
  printf '%s%s\n' "$lead" "$SWAP_FSTAB_LINE" >> "$FSTAB"
}

# create and enable the swapfile
provision_swap() {
  adopt_legacy_swap || log "WARNING: could not write $INSTALL_RECORD"
  if [[ "$(wc -l < "$PROC_SWAPS")" -ge 2 ]]; then
    log "swap already configured: $(grep -v '^Filename' "$PROC_SWAPS" | tr -s ' ')"
    return 0
  fi
  if [[ "$FLAVOR" != ubuntu && "$(root_fstype)" == btrfs ]]; then
    log "no swap is active and / is btrfs -- provisioning no swapfile"
    return 1
  fi
  local entries id
  entries=$(swapfile_fstab_entries)
  if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
    swapfile_is_ours || {
      log "$SWAPFILE exists and this install did not make it -- leaving it, and swap, off"
      return 1
    }
  elif [[ -n "$entries" ]] && ! record_has swapfile-fstab; then
    log "$FSTAB already names $SWAPFILE ('$(head -1 <<<"$entries")') -- leaving it, and swap, off"
    return 1
  fi
  local want_kb=$((2 * 1024 * 1024)) margin_kb=$((1024 * 1024)) free_kb
  free_kb="$(df -Pk / | awk 'NR==2{print $4}')"
  if (( free_kb < want_kb + margin_kb )); then
    if (( free_kb > 512 * 1024 + margin_kb )); then
      want_kb=$(( free_kb - margin_kb ))
      log "only ${free_kb}KB free on / -- sizing swap down to ${want_kb}KB instead of the usual 2G"
    else
      log "WARNING: only ${free_kb}KB free on / -- skipping swap"
      return 1
    fi
  fi
  if [[ ! -f "$SWAPFILE" ]]; then
    log "provisioning $SWAPFILE (${want_kb}KB)"
    if ! fallocate -l "${want_kb}K" "$SWAPFILE" 2>/dev/null \
       && ! dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((want_kb / 1024)) status=none; then
      log "WARNING: could not allocate $SWAPFILE"
      rm -f "$SWAPFILE"
      return 1
    fi
    chmod 0600 "$SWAPFILE"
    if ! mkswap_out=$(mkswap "$SWAPFILE" 2>&1); then
      log "WARNING: mkswap failed: $mkswap_out"
      rm -f "$SWAPFILE"
      return 1
    fi
    if ! id=$(swapfile_id) || ! record_add "swapfile:$id"; then
      log "WARNING: could not record $SWAPFILE in $INSTALL_RECORD -- removing it"
      rm -f "$SWAPFILE"
      return 1
    fi
  fi
  if ! swapon_out=$(swapon "$SWAPFILE" 2>&1); then
    log "WARNING: swapon failed: $swapon_out"
    return 1
  fi
  log "swap active: $(grep ^SwapTotal "$MEMINFO" | tr -s ' ')"
  if [[ -z "$(swapfile_fstab_entries)" ]]; then
    append_swap_fstab_line || return 1
  fi
}
provision_swap || true

# check the running zswap state
zswap_live() { [[ -z "$ZSWAP_TOKENS" ]] || zswap_on; }
# print the tokens missing from the running cmdline
cmdline_lacks() {
  local - tok running
  [[ "$FLAVOR" != ubuntu ]] || return 0
  set -f
  running=" $(cat "$CMDLINE_FILE") "
  for tok in $ALL_TOKENS; do
    [[ "$running" == *" $tok "* ]] || printf ' %s' "$tok"
  done
}
# return success when all of the bootstrap changes are live
live_applied() {
  local active
  if [[ "$SELINUX_MODE" == namespace ]]; then
    [[ "$(uname -r)" == *-rhizo ]] && zswap_live && [[ -z "$(cmdline_lacks)" ]]
    return
  fi
  active="$(lsm_active)"
  [[ "$(uname -r)" == *-rhizo ]] && [[ ",$active," == *",selinux,"* ]] && selinux_present && zswap_live && [[ -z "$(cmdline_lacks)" ]] \
    && ! { judges_overrides && bl_lsm_bpf_first "$active"; }
}
# check the cmdline and bootloader config
bootstrap_already_applied() {
  local missing overridden
  live_applied && bootloader_config_current "$BL_KIND" "$ALL_TOKENS" || return 1
  grep -q '^rhizo-kernel-default ' "$INSTALL_RECORD" 2>/dev/null || return 1
  if [[ "$SELINUX_MODE" == namespace ]]; then
    record_has "selinux-mode namespace" || return 1
  fi
  missing=$(bootloader_missing "$BL_KIND" "$ALL_TOKENS") || die "cannot check $GRUBCFG for the tokens"
  [[ -z "$missing" ]] || return 1
  judges_overrides || return 0
  overridden=$(bootloader_overridden "$BL_KIND" "$ALL_TOKENS") || die "cannot check $GRUBCFG for the tokens"
  [[ -z "$overridden" ]]
}
if [[ -n "$ZSWAP_TOKENS" ]]; then LIVE_NAMES="selinux and zswap" LIVE_PRONOUN=them; else LIVE_NAMES=selinux LIVE_PRONOUN=it; fi
[[ "$SELINUX_MODE" == host ]] || LIVE_NAMES="the Rhizo kernel${ZSWAP_TOKENS:+ and zswap}"

[[ "$SELINUX_MODE" == namespace ]] || mount_selinuxfs
log "current state:"
report_state

APPLIED_STATE="selinux is already an active LSM, selinuxfs is mounted,"
[[ "$SELINUX_MODE" == host ]] || APPLIED_STATE="the Rhizo kernel runs,"
if bootstrap_already_applied; then
  log "$APPLIED_STATE${ZSWAP_TOKENS:+ zswap is active,} and $DROPIN and $GRUBCFG carry every token -- nothing to do"
  log "RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"
  exit 0
fi
# print the bootloader config mismatch
next_boot_gap() {
  local missing over rtok eff
  if ! bootloader_config_current "$BL_KIND" "$ALL_TOKENS"; then echo "$DROPIN is absent or differs"; return; fi
  missing=$(bootloader_missing "$BL_KIND" "$ALL_TOKENS") || die "cannot check $GRUBCFG for the tokens"
  if [[ -n "$missing" ]]; then echo "$GRUBCFG lacks:$missing"; return; fi
  over=$(bootloader_overridden "$BL_KIND" "$ALL_TOKENS") || die "cannot check $GRUBCFG for the tokens"
  read -r rtok eff <<<"$over"
  echo "the host's own $eff overrides rhizo's $rtok in $GRUBCFG"
}
LIVE_APPLIED=0
if live_applied; then
  LIVE_APPLIED=1
  log "this boot already runs $LIVE_NAMES, but the next boot's configuration does not carry" \
      "$LIVE_PRONOUN ($(next_boot_gap)) -- restoring it"
elif [[ "$SELINUX_MODE" == host && ",$(lsm_active)," == *",selinux,"* ]] && selinux_present; then
  if ! zswap_live; then
    part="the drop-in"
    [[ "$BL_KIND" == grub-dropin ]] || part="rhizo's block in $DROPIN"
    log "selinux already applied, but zswap.enabled=1 is missing from a prior bootstrap -- rewriting $part to add it"
  fi
  lacks=$(cmdline_lacks)
  [[ -z "$lacks" ]] || log "selinux already applied, but this boot's cmdline lacks:$lacks -- writing them, which take effect at the next boot"
  if judges_overrides && bl_lsm_bpf_first "$(lsm_active)"; then
    log "selinux is active, but behind bpf ($(lsm_active)) -- the next boot takes the order in rhizo's lsm= list"
  fi
fi

# print the lines absent from <drop>
lines_without() {
  local l
  while IFS= read -r l; do
    [[ -z "$l" || $'\n'"$2"$'\n' == *$'\n'"$l"$'\n'* ]] || echo "$l"
  done <<<"$1"
}

umask 022
if [[ "$BL_KIND" != grub-dropin ]]; then
  BEFORE=$(bootloader_cmdline_tokens "$BL_KIND") || die "cannot read the cmdlines in $GRUBCFG"
  OWN_TOKENS=$(bootloader_own_tokens "$BL_KIND") || die "cannot read rhizo's tokens in $DROPIN"
  BEFORE=$(lines_without "$BEFORE" "$OWN_TOKENS")
fi
bootloader_write "$BL_KIND" "$ALL_TOKENS" || die "cannot write $DROPIN"
log "wrote $DROPIN"
log "  tokens: $ALL_TOKENS"

# restore the bootloader config and fail
regen_failed() {
  local out still now state=still
  if [[ "$BL_KIND" == grub-dropin ]]; then
    if ! out=$(bootloader_restore "$BL_KIND" 2>&1); then
      out="could not put $DROPIN back as it was before this run (${out//$'\n'/; }) -- it keeps this run's tokens"
    elif (( BL_SAVED_HAD )); then
      out="put $DROPIN back as it was before this run"
    else
      out="removed $DROPIN, which this run wrote"
    fi
    echo "[$PROG] FAIL: $1" >&2
    echo "[$PROG]   $out" >&2
    exit 1
  fi
  if out=$(bootloader_rollback "$BL_KIND" 2>&1); then
    [[ -z "$out" ]] || echo "$out" | sed "s/^/[$PROG]   /"
    if still=$(bootloader_lost "$BL_KIND" "$BEFORE") && [[ -z "$still" ]]; then
      die "$1 -- put $DROPIN back as it was and ran $REGEN again"
    fi
    die "$1 -- put $DROPIN back as it was and ran $REGEN again, but the next boot still lacks:${still:- <cannot read $GRUBCFG>}"
  fi
  echo "$out" >&2
  bootloader_config_current "$BL_KIND" "$ALL_TOKENS" || state="no longer"
  if ! now=$(bootloader_lost "$BL_KIND" "$BEFORE"); then
    now="cannot be read"
  elif [[ -n "$now" ]]; then
    now="lacks:$now"
  else
    now="has every token besides rhizo's own that the next boot had before this run"
  fi
  die "$1 -- and putting $DROPIN back did not finish (see above): $DROPIN $state carries this run's tokens, and $GRUBCFG $now"
}

log "running $REGEN"
if ! out=$(bootloader_regen "$BL_KIND" 2>&1); then
  echo "$out" >&2
  regen_failed "$REGEN failed"
fi
[[ -z "$out" ]] || echo "$out" | sed "s/^/[$PROG]   /"

[[ -r "$GRUBCFG" ]] || regen_failed "no readable $GRUBCFG after $REGEN"
missing=$(bootloader_missing "$BL_KIND" "$ALL_TOKENS") || regen_failed "cannot check $GRUBCFG for the tokens"
lost=""
if [[ "$BL_KIND" != grub-dropin ]]; then
  lost=$(bootloader_lost "$BL_KIND" "$BEFORE") || regen_failed "cannot read the cmdlines in $GRUBCFG"
fi
if [[ -n "$missing$lost" ]]; then
  if [[ -n "$missing" && ( "$BL_KIND" == limine || "$BL_KIND" == sdboot ) ]]; then
    lacking=$(bootloader_missing_entries "$BL_KIND" "$ALL_TOKENS") \
      || regen_failed "cannot check $GRUBCFG for the tokens"
    why="$REGEN ran but" sep=""
    while IFS=$'\t' read -r where toks; do why+="$sep $where is missing:$toks" sep=" and"; done <<<"$lacking"
    [[ -z "$lost" ]] || why+=" and $GRUBCFG lost:$lost"
  else
    why="$REGEN ran but $GRUBCFG"
    [[ -z "$missing" ]] || why+=" is missing:$missing"
    [[ -z "$lost" ]] || why+="${missing:+ and} lost:$lost"
  fi
  regen_failed "$why"
fi
# print the override reason for each token
overridden_why() {
  local rtok eff src out="" sep=""
  while read -r rtok eff; do
    if ! src=$(bootloader_token_source "$BL_KIND" "$eff" 2>&1); then src="a file that cannot be read: $src"
    elif [[ -z "$src" ]]; then src="the host's own configuration"
    else src=${src//$'\n'/ and }; fi
    out+="$sep $(bl_override_why "$rtok" "$eff" "$src")"
    sep=";"
  done <<<"$1"
  echo "$out"
}
if judges_overrides; then
  overridden=$(bootloader_overridden "$BL_KIND" "$ALL_TOKENS") || regen_failed "cannot check $GRUBCFG for the tokens"
  [[ -z "$overridden" ]] || regen_failed "$REGEN ran, but$(overridden_why "$overridden")"
fi
log "confirmed all $(echo "$ALL_TOKENS" | wc -w) tokens present in $GRUBCFG"

if ! grep -q '^rhizo-kernel-default ' "$INSTALL_RECORD" 2>/dev/null; then
  entry=$(bootloader_make_rhizo_default "$BL_KIND" "$INSTALL_RECORD") \
    || die "cannot make the Rhizo kernel the default boot entry (see above)"
  log "made $entry the default boot entry; $INSTALL_RECORD keeps the previous one for the uninstall"
fi
if [[ "$SELINUX_MODE" == namespace ]]; then
  record_add "selinux-mode namespace" || die "cannot record selinux-mode namespace in $INSTALL_RECORD"
fi

if (( LIVE_APPLIED )); then
  if [[ "$SELINUX_MODE" == namespace ]]; then
    log "this boot already runs $LIVE_NAMES, so no reboot is needed; the next boot keeps $LIVE_PRONOUN"
  else
    log "the running kernel already has $LIVE_NAMES, so no reboot is needed for $LIVE_PRONOUN; the next boot keeps $LIVE_PRONOUN"
  fi
  log "RHIZO_BOOTSTRAP_CONFIG_RESTORED=1"
  exit 0
fi

if [[ "$SELINUX_MODE" == namespace ]]; then
  log ""
  log "Android runs only on the Rhizo kernel, the default boot entry now, and"
  log "its cmdline takes effect when that kernel boots: reboot into it."
  log "After rebooting, confirm with: $0 --verify"
  log "RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
  exit 0
fi

log ""
log "An LSM list is a boot-time kernel parameter. There is no live-reconfigure"
log "path, so this does not take effect until the machine reboots."
log "After rebooting, confirm with: $0 --verify"
log "RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
