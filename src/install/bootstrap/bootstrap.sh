#!/bin/bash
# kernel cmdline bootstrap for rhizo
set -uo pipefail

PROG=rhizo-host-bootstrap
log() { echo "[$PROG] $*"; }
die() { echo "[$PROG] $*" >&2; exit 1; }
# print the usage text
usage() {
  cat <<'EOF'
bootstrap.sh [--verify | --show] [--lsm-list] [--vbmeta-digest DIGEST] [-h | --help]
EOF
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-flavor.sh
. "$HERE/../lib/host-flavor.sh" || die "failed to source $HERE/../lib/host-flavor.sh"
# shellcheck source=bootloader.sh
. "$HERE/bootloader.sh" || die "failed to source $HERE/bootloader.sh"
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
  || die "$SELINUX_MODE_HELPER --configured failed"
case "$SELINUX_MODE" in
  host) ;;
  namespace)
    [[ "$LSM_STYLE" != list ]] || die "--lsm-list with selinux mode namespace" ;;
  *) die "$SELINUX_MODE_HELPER --configured printed '$SELINUX_MODE', expected host or namespace" ;;
esac
# shellcheck disable=SC2034
BL_SAVED_DEFAULT=1

# set LSM_TOKENS to the LSM list with selinux
lsm_list_tokens() {
  if ! LSM_TOKENS=$(host_lsm_list_with_selinux 2>&1); then
    [[ "$LSM_STYLE" == list ]] \
      && die "failed to read $RHIZO_LSM_FILE for --lsm-list (${LSM_TOKENS##*: })"
    die "failed to read $RHIZO_LSM_FILE (${LSM_TOKENS##*: })"
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
        || die "failed to read the host cmdline settings for $show_kind"
      if [[ -n "$host_lsm" ]]; then LSM_TOKENS=$host_lsm; all_tokens; fi
    elif (( rc == 2 )); then
      echo "[$PROG] failed to read the host bootloader lines, LSM token from $CMDLINE_FILE (${why//$'\n'/; })" >&2
    else
      echo "[$PROG] LSM token from $CMDLINE_FILE (${why//$'\n'/; })" >&2
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
    || die "failed to mount selinuxfs at $SELINUXFS"
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
  log "lsm=${active:-<securityfs not mounted>}"
  log "selinuxfs=$(selinux_present && echo mounted || echo absent)"
  if selinux_present; then
    log "enforce=$(cat "$SELINUXFS/enforce" 2>/dev/null || echo '<unreadable>')"
  fi
  log "cmdline=$(tr -s ' ' < "$CMDLINE_FILE")"
}

# check zswap and swap after the reboot
verify_swap() {
  ZSWAP_VERIFIED=0
  if [[ "$FLAVOR" == ubuntu ]] || cmdline_has "zswap.enabled=1 "; then
    zswap_on || die "$ZSWAP_ENABLED is not Y with zswap.enabled=1 on the cmdline"
    log "zswap=active"
    ZSWAP_VERIFIED=1
  elif swap_on_zram; then
    log "zswap=off swap=zram"
  else
    log "zswap=off"
  fi
  swap_up=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [[ "$(wc -l < "$PROC_SWAPS")" -ge 2 ]]; then swap_up=1; break; fi
    sleep 1
  done
  if [[ "$swap_up" == 1 ]]; then
    log "swap=active ($(grep ^SwapTotal "$MEMINFO" | tr -s ' '))"
  else
    log "swap=none after 10s ($(systemctl is-failed swapfile.swap 2>/dev/null || echo swapfile.swap))"
  fi
}

if [[ "$MODE" == verify && "$SELINUX_MODE" == namespace ]]; then
  report_state
  BL_KIND=$(bootloader_kind 2>&1) || die "$BL_KIND"
  default_entry=$(bootloader_default_entry "$BL_KIND") || die "failed to read the default boot entry of $BL_KIND"
  bl_rhizo_entry "$default_entry" \
    || die "the default boot entry is '${default_entry:-the first entry}', not the Rhizo kernel"
  log "default_entry=$default_entry"
  running_out=$("$SELINUX_MODE_HELPER" "${SELINUX_MODE_ENV[@]}" --mode-and-why) || die "$SELINUX_MODE_HELPER --mode-and-why failed"
  IFS=$'\t' read -r running_mode running_why <<<"$running_out"
  [[ "$running_mode" == namespace ]] \
    || die "selinux mode is $running_mode, expected namespace (${running_why:-$SELINUX_MODE_HELPER printed no reason})"
  log "selinux_mode=namespace"
  verify_swap
  verified="the default boot entry is the Rhizo kernel and the selinux mode is namespace"
  (( ! ZSWAP_VERIFIED )) || verified+=", and zswap is active"
  log "$verified"
  log "RHIZO_BOOTSTRAP_VERIFIED=1"
  exit 0
fi

if [[ "$MODE" == verify ]]; then
  mount_selinuxfs
  report_state
  active="$(lsm_active)"
  if [[ ",$active," != *",selinux,"* ]] || { judges_overrides && bl_lsm_bpf_first "$active"; }; then
    head="selinux is not in the active LSM list"
    if [[ ",$active," == *",selinux,"* ]]; then
      head="bpf is ahead of selinux in the active LSM list ($active)"
    fi
    cmdline=$(cat "$CMDLINE_FILE")
    if judges_overrides && last=$(bl_last_setting lsm "$cmdline") && ! bl_lsm_selinux_usable "${last#lsm=}" \
       && rtok=$(rhizo_lsm_before_last "$cmdline"); then
      { IFS= read -r what; IFS= read -r fix; } <<<"$(bl_lsm_fault "${last#lsm=}")"
      if [[ "$rtok" == security=* ]]; then
        why="$CMDLINE_FILE has $last with rhizo's $rtok, $last"
      else
        why="$CMDLINE_FILE has $last after rhizo's $rtok, $last"
      fi
      die "$head, $why $what, $fix"
    fi
    [[ ",$active," != *",selinux,"* ]] \
      || die "$head"
    die "selinux is not in the active LSM list"
  fi
  selinux_present || die "$SELINUXFS is not mounted"
  [[ -r "$SELINUXFS/enforce" ]] || die "$SELINUXFS/enforce is not readable"
  if [[ ",$active," == *",apparmor,"* ]]; then
    die "apparmor is active"
  fi
  if judges_overrides; then
    ctx=$(cat "$ATTR_CURRENT" 2>&1) \
      || die "failed to read $ATTR_CURRENT (${ctx##*: })"
    log "attr_current=$ctx"
  fi
  verify_swap
  if (( ZSWAP_VERIFIED )); then
    verified="SELinux is the active exclusive LSM, selinuxfs is mounted, and zswap is active"
  else
    verified="SELinux is the active exclusive LSM and selinuxfs is mounted"
  fi
  log "$verified"
  log "RHIZO_BOOTSTRAP_VERIFIED=1"
  exit 0
fi

[[ $EUID -eq 0 ]] || die "EUID $EUID is not 0"

[[ "$FLAVOR" == ubuntu || "$FLAVOR" == cachyos ]] \
  || die "host flavor '${FLAVOR#unsupported:}' is unsupported"

arch="$(uname -m)"
[[ "$arch" == x86_64 || "$arch" == aarch64 ]] || die "uname -m is $arch, expected x86_64 or aarch64"

# require CONFIG_<sym>=y in the kernel config
need_kconfig() {
  local err rc=0
  err=$(host_kconfig_has "$1" 2>&1) || rc=$?
  case $rc in
    0) return 0 ;;
    1) die "$(host_kconfig_source) does not set CONFIG_$1=y for $2" ;;
  esac
  die "failed to read CONFIG_$1 ($err)"
}
if [[ "$SELINUX_MODE" == host ]]; then
  need_kconfig SECURITY_SELINUX "host mode"
  if [[ "$FLAVOR" != ubuntu ]]; then
    need_kconfig SECURITY_SELINUX_DEVELOP "enforcing=0"
  fi
fi

BL_KIND=$(bootloader_kind 2>&1) || die "$BL_KIND"
if (( LSM_FROM_HOST_LINE )); then
  host_lsm=$(host_line_lsm "$BL_KIND") || die "failed to read the host cmdline settings for $BL_KIND"
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
  bootloader_rhizo_default_preflight "$BL_KIND" || die "failed to make the Rhizo kernel the default boot entry"
fi
if [[ "$SELINUX_MODE" == host ]]; then
  record_drop "selinux-mode namespace" || die "failed to remove selinux-mode namespace from $INSTALL_RECORD"
fi

# return whether the install record lists the swapfile id
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
  log "wrote swapfile-fstab to $INSTALL_RECORD"
  if [[ "$entries" == "$SWAP_FSTAB_LINE" && -f "$SWAPFILE" ]] && id=$(swapfile_id); then
    record_add "swapfile:$id" || return 1
    log "wrote swapfile:$id to $INSTALL_RECORD"
  fi
}

root_fstype() { stat -f -c %T /; }

# append the swap line to fstab
append_swap_fstab_line() {
  local lead=""
  [[ -s "$FSTAB" && -n "$(LC_ALL=C tail -c1 "$FSTAB")" ]] && lead=$'\n'
  record_add swapfile-fstab || { log "failed to write swapfile-fstab to $INSTALL_RECORD"; return 1; }
  if [[ -n "$lead" ]]; then
    record_add swapfile-fstab-eol || { log "failed to write swapfile-fstab-eol to $INSTALL_RECORD"; return 1; }
  fi
  printf '%s%s\n' "$lead" "$SWAP_FSTAB_LINE" >> "$FSTAB"
}

# create and enable the swapfile
provision_swap() {
  adopt_legacy_swap || log "failed to write $INSTALL_RECORD"
  if [[ "$(wc -l < "$PROC_SWAPS")" -ge 2 ]]; then
    log "swap active ($(grep -v '^Filename' "$PROC_SWAPS" | tr -s ' '))"
    return 0
  fi
  if [[ "$FLAVOR" != ubuntu && "$(root_fstype)" == btrfs ]]; then
    log "no active swap, / is btrfs"
    return 1
  fi
  local entries id
  entries=$(swapfile_fstab_entries)
  if [[ -e "$SWAPFILE" || -L "$SWAPFILE" ]]; then
    swapfile_is_ours || {
      log "$SWAPFILE exists and is not in $INSTALL_RECORD"
      return 1
    }
  elif [[ -n "$entries" ]] && ! record_has swapfile-fstab; then
    log "$FSTAB contains $SWAPFILE ('$(head -1 <<<"$entries")')"
    return 1
  fi
  local want_kb=$((2 * 1024 * 1024)) margin_kb=$((1024 * 1024)) free_kb
  free_kb="$(df -Pk / | awk 'NR==2{print $4}')"
  if (( free_kb < want_kb + margin_kb )); then
    if (( free_kb > 512 * 1024 + margin_kb )); then
      want_kb=$(( free_kb - margin_kb ))
      log "${free_kb}KB free on /, swapfile size ${want_kb}KB"
    else
      log "${free_kb}KB free on /, no swapfile"
      return 1
    fi
  fi
  if [[ ! -f "$SWAPFILE" ]]; then
    if ! fallocate -l "${want_kb}K" "$SWAPFILE" 2>/dev/null \
       && ! dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((want_kb / 1024)) status=none; then
      log "failed to allocate $SWAPFILE"
      rm -f "$SWAPFILE"
      return 1
    fi
    chmod 0600 "$SWAPFILE"
    if ! mkswap_out=$(mkswap "$SWAPFILE" 2>&1); then
      log "mkswap failed ($mkswap_out)"
      rm -f "$SWAPFILE"
      return 1
    fi
    if ! id=$(swapfile_id) || ! record_add "swapfile:$id"; then
      log "failed to write $SWAPFILE to $INSTALL_RECORD"
      rm -f "$SWAPFILE"
      return 1
    fi
  fi
  if ! swapon_out=$(swapon "$SWAPFILE" 2>&1); then
    log "swapon failed ($swapon_out)"
    return 1
  fi
  log "swap active ($(grep ^SwapTotal "$MEMINFO" | tr -s ' '))"
  if [[ -z "$(swapfile_fstab_entries)" ]]; then
    append_swap_fstab_line || return 1
  fi
}
provision_swap || true

# return whether zswap is on or not in the tokens
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
# return whether the running kernel has all bootstrap changes
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
# return whether the cmdline and bootloader config have all tokens
bootstrap_already_applied() {
  local missing overridden
  live_applied && bootloader_config_current "$BL_KIND" "$ALL_TOKENS" || return 1
  grep -q '^rhizo-kernel-default ' "$INSTALL_RECORD" 2>/dev/null || return 1
  if [[ "$SELINUX_MODE" == namespace ]]; then
    record_has "selinux-mode namespace" || return 1
  fi
  missing=$(bootloader_missing "$BL_KIND" "$ALL_TOKENS") || die "failed to read $GRUBCFG"
  [[ -z "$missing" ]] || return 1
  judges_overrides || return 0
  overridden=$(bootloader_overridden "$BL_KIND" "$ALL_TOKENS") || die "failed to read $GRUBCFG"
  [[ -z "$overridden" ]]
}
if [[ -n "$ZSWAP_TOKENS" ]]; then LIVE_NAMES="selinux and zswap" LIVE_PRONOUN="selinux and zswap"; else LIVE_NAMES=selinux LIVE_PRONOUN=selinux; fi
[[ "$SELINUX_MODE" == host ]] || LIVE_NAMES="the Rhizo kernel${ZSWAP_TOKENS:+ and zswap}"

[[ "$SELINUX_MODE" == namespace ]] || mount_selinuxfs
report_state

APPLIED_STATE="selinux is an active LSM, selinuxfs is mounted,"
[[ "$SELINUX_MODE" == host ]] || APPLIED_STATE="the running kernel is the Rhizo kernel,"
if bootstrap_already_applied; then
  log "$APPLIED_STATE${ZSWAP_TOKENS:+ zswap is active,} and $DROPIN and $GRUBCFG contain all tokens"
  log "RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"
  exit 0
fi
# print the bootloader config mismatch
next_boot_gap() {
  local missing over rtok eff
  if ! bootloader_config_current "$BL_KIND" "$ALL_TOKENS"; then echo "$DROPIN is absent or differs"; return; fi
  missing=$(bootloader_missing "$BL_KIND" "$ALL_TOKENS") || die "failed to read $GRUBCFG"
  if [[ -n "$missing" ]]; then echo "$GRUBCFG has no$missing"; return; fi
  over=$(bootloader_overridden "$BL_KIND" "$ALL_TOKENS") || die "failed to read $GRUBCFG"
  read -r rtok eff <<<"$over"
  echo "the host $eff overrides rhizo's $rtok in $GRUBCFG"
}
LIVE_APPLIED=0
if live_applied; then
  LIVE_APPLIED=1
  log "the running kernel has $LIVE_NAMES, the next boot configuration differs ($(next_boot_gap))"
elif [[ "$SELINUX_MODE" == host && ",$(lsm_active)," == *",selinux,"* ]] && selinux_present; then
  if ! zswap_live; then
    part="the drop-in"
    [[ "$BL_KIND" == grub-dropin ]] || part="rhizo's block in $DROPIN"
    log "zswap.enabled=1 is missing from $part"
  fi
  lacks=$(cmdline_lacks)
  [[ -z "$lacks" ]] || log "$CMDLINE_FILE has no$lacks"
  if judges_overrides && bl_lsm_bpf_first "$(lsm_active)"; then
    log "bpf is ahead of selinux ($(lsm_active))"
  fi
fi

# print the lines of $1 absent from $2
lines_without() {
  local l
  while IFS= read -r l; do
    [[ -z "$l" || $'\n'"$2"$'\n' == *$'\n'"$l"$'\n'* ]] || echo "$l"
  done <<<"$1"
}

umask 022
if [[ "$BL_KIND" != grub-dropin ]]; then
  BEFORE=$(bootloader_cmdline_tokens "$BL_KIND") || die "failed to read the cmdlines in $GRUBCFG"
  OWN_TOKENS=$(bootloader_own_tokens "$BL_KIND") || die "failed to read the rhizo tokens in $DROPIN"
  BEFORE=$(lines_without "$BEFORE" "$OWN_TOKENS")
fi
bootloader_write "$BL_KIND" "$ALL_TOKENS" || die "failed to write $DROPIN"
log "wrote $DROPIN"
log "tokens $ALL_TOKENS"

# restore the bootloader config and fail
regen_failed() {
  local out still now state=contains
  if [[ "$BL_KIND" == grub-dropin ]]; then
    if ! out=$(bootloader_restore "$BL_KIND" 2>&1); then
      out="failed to restore $DROPIN (${out//$'\n'/; })"
    elif (( BL_SAVED_HAD )); then
      out="restored $DROPIN"
    else
      out="removed $DROPIN"
    fi
    echo "[$PROG] $1" >&2
    echo "[$PROG]   $out" >&2
    exit 1
  fi
  if out=$(bootloader_rollback "$BL_KIND" 2>&1); then
    [[ -z "$out" ]] || echo "$out" | sed "s/^/[$PROG]   /"
    if still=$(bootloader_lost "$BL_KIND" "$BEFORE") && [[ -z "$still" ]]; then
      die "$1, restored $DROPIN and ran $REGEN"
    fi
    die "$1, restored $DROPIN and ran $REGEN, $GRUBCFG has no${still:- <failed to read $GRUBCFG>}"
  fi
  echo "$out" >&2
  bootloader_config_current "$BL_KIND" "$ALL_TOKENS" || state="does not contain"
  if ! now=$(bootloader_lost "$BL_KIND" "$BEFORE"); then
    now="is unreadable"
  elif [[ -n "$now" ]]; then
    now="has no$now"
  else
    now="has all non-rhizo tokens"
  fi
  die "$1, failed to restore $DROPIN, $DROPIN $state the written tokens and $GRUBCFG $now"
}

if ! out=$(bootloader_regen "$BL_KIND" 2>&1); then
  echo "$out" >&2
  regen_failed "$REGEN failed"
fi
[[ -z "$out" ]] || echo "$out" | sed "s/^/[$PROG]   /"

[[ -r "$GRUBCFG" ]] || regen_failed "no readable $GRUBCFG after $REGEN"
missing=$(bootloader_missing "$BL_KIND" "$ALL_TOKENS") || regen_failed "failed to read $GRUBCFG"
lost=""
if [[ "$BL_KIND" != grub-dropin ]]; then
  lost=$(bootloader_lost "$BL_KIND" "$BEFORE") || regen_failed "failed to read the cmdlines in $GRUBCFG"
fi
if [[ -n "$missing$lost" ]]; then
  if [[ -n "$missing" && ( "$BL_KIND" == limine || "$BL_KIND" == sdboot ) ]]; then
    lacking=$(bootloader_missing_entries "$BL_KIND" "$ALL_TOKENS") \
      || regen_failed "failed to read $GRUBCFG"
    why="after $REGEN" sep=""
    while IFS=$'\t' read -r where toks; do why+="$sep $where has no$toks" sep=" and"; done <<<"$lacking"
    [[ -z "$lost" ]] || why+=" and $GRUBCFG lost$lost"
  else
    why="after $REGEN $GRUBCFG"
    [[ -z "$missing" ]] || why+=" has no$missing"
    [[ -z "$lost" ]] || why+="${missing:+ and} lost$lost"
  fi
  regen_failed "$why"
fi
# print the override reason for each token
overridden_why() {
  local rtok eff src out="" sep=""
  while read -r rtok eff; do
    if ! src=$(bootloader_token_source "$BL_KIND" "$eff" 2>&1); then src="an unreadable file ($src)"
    elif [[ -z "$src" ]]; then src="the host configuration"
    else src=${src//$'\n'/ and }; fi
    out+="$sep $(bl_override_why "$rtok" "$eff" "$src")"
    sep=" and"
  done <<<"$1"
  echo "$out"
}
if judges_overrides; then
  overridden=$(bootloader_overridden "$BL_KIND" "$ALL_TOKENS") || regen_failed "failed to read $GRUBCFG"
  [[ -z "$overridden" ]] || regen_failed "after $REGEN$(overridden_why "$overridden")"
fi
log "$GRUBCFG contains all $(echo "$ALL_TOKENS" | wc -w) tokens"

if ! grep -q '^rhizo-kernel-default ' "$INSTALL_RECORD" 2>/dev/null; then
  entry=$(bootloader_make_rhizo_default "$BL_KIND" "$INSTALL_RECORD") \
    || die "failed to make the Rhizo kernel the default boot entry"
  log "made $entry the default boot entry"
fi
if [[ "$SELINUX_MODE" == namespace ]]; then
  record_add "selinux-mode namespace" || die "failed to write selinux-mode namespace to $INSTALL_RECORD"
fi

if (( LIVE_APPLIED )); then
  if [[ "$SELINUX_MODE" == namespace ]]; then
    log "the running kernel has $LIVE_NAMES"
  else
    log "the running kernel has $LIVE_PRONOUN"
  fi
  log "RHIZO_BOOTSTRAP_CONFIG_RESTORED=1"
  exit 0
fi

if [[ "$SELINUX_MODE" == namespace ]]; then
  log "the default boot entry is the Rhizo kernel"
  log "RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
  exit 0
fi

log "the kernel reads lsm= at boot"
log "RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
