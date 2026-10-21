#!/bin/bash
# define what a teardown may remove

RHIZO_TEARDOWN_LIB_STATE_ROOT=/var/lib/rhizo
RHIZO_TEARDOWN_LIB_PREPARED_ROOT=/var/lib/rhizo/prepared
RHIZO_TEARDOWN_LIB_TEMPLATES_ROOT=/var/lib/rhizo/templates
RHIZO_TEARDOWN_LIB_DERIVED_ROOT=/var/lib/rhizo/derived
RHIZO_TEARDOWN_LIB_PREPARED_SENTINEL=/var/lib/rhizo/.prepared
RHIZO_TEARDOWN_LIB_VAR_CACHE=/var/cache/rhizo
RHIZO_TEARDOWN_LIB_VAR_LOG=/var/log/rhizo
RHIZO_TEARDOWN_LIB_APPWATCH_BIN=/usr/lib/rhizo/tools/app-events.py
RHIZO_TEARDOWN_LIB_DATA_IMG="${RHIZO_DATA_IMG:-/var/lib/rhizo/data.img}"
RHIZO_TEARDOWN_LIB_UPDATE_ROOT=/var/lib/rhizo/update
RHIZO_TEARDOWN_LIB_ETC_RHIZO=/etc/rhizo
RHIZO_TEARDOWN_LIB_DESKTOP_USER=/etc/rhizo/desktop-user
RHIZO_TEARDOWN_LIB_INSTALL_FAILED=/etc/rhizo/install-failed
RHIZO_TEARDOWN_LIB_LAUNCH_TREES=(
  /var/lib/rhizo/vendor /var/lib/rhizo/apex_override
  "/var/lib/rhizo/instances/*/vendor" "/var/lib/rhizo/instances/*/apex_override"
)
RHIZO_TEARDOWN_LIB_GSI_GLOB="/srv/rhizo/gsi_system*"
RHIZO_TEARDOWN_LIB_UPGRADE_FROM=/var/lib/rhizo/.upgrade-from
RHIZO_TEARDOWN_LIB_INSTALL_RECORD=/var/lib/rhizo/.created-by-install
RHIZO_TEARDOWN_LIB_APPWATCH_ACCOUNT=rhizo-appwatch
RHIZO_TEARDOWN_LIB_NETBRIDGED_ACCOUNT=rhizo-netbridged
RHIZO_TEARDOWN_LIB_UHID_ACCOUNT=rhizo-uhid
RHIZO_TEARDOWN_LIB_ACCOUNTS=("$RHIZO_TEARDOWN_LIB_APPWATCH_ACCOUNT" "$RHIZO_TEARDOWN_LIB_NETBRIDGED_ACCOUNT"
                            "$RHIZO_TEARDOWN_LIB_UHID_ACCOUNT")
RHIZO_TEARDOWN_LIB_LOOP_UDEV_RULE=/etc/udev/rules.d/59-rhizo-loop-unbound.rules
RHIZO_TEARDOWN_LIB_LAUNCH_DIRS=(/rhizoroot /mnt/rhizo-template-build /var/cache/rhizo-appsync)
RHIZO_TEARDOWN_LIB_ROOT_STATE=(
  /root/.rhizo_init_pid "/root/.rhizo_init_pid-*"
  /root/.rhizo_cgroup_root "/root/.rhizo_cgroup_root-*"
  /root/.rhizo_cgroup_invocation "/root/.rhizo_cgroup_invocation-*"
  /run/rhizo-vbmeta-loop "/run/rhizo-vbmeta-loop-*"
  "/run/udev/rhizo-input-*.sock"
  /root/.rhizo_vbmeta_loop "/root/.rhizo_vbmeta_loop-*"
  /root/.rhizo_prepare_resume "/root/.rhizo_prepare_resume-*"
  /root/.rhizo_g_pid
  /root/.rhizo_supervisor_state
  /root/.rhizo_handoff.d
  /root/.rhizo_cache
)
RHIZO_TEARDOWN_LIB_STATE_PURGE=(
  /var/lib/rhizo/instances
  /var/lib/rhizo/device-state "/var/lib/rhizo/device-state-*"
  /var/lib/rhizo/pool-members /var/lib/rhizo/pool-pending /var/lib/rhizo/pool.lock
  /var/lib/rhizo/captures
  "$RHIZO_TEARDOWN_LIB_UPGRADE_FROM" "$RHIZO_TEARDOWN_LIB_INSTALL_RECORD"
  /var/lib/rhizo/rhizo-host-teardown.sh /var/lib/rhizo/rhizo-teardown-lib.sh
)
RHIZO_TEARDOWN_LIB_HOST_EXEC_CONTEXT="u:object_r:rhizo_host_exec:s0"
RHIZO_TEARDOWN_LIB_HOST_MODULE_CONTEXT="u:object_r:rhizo_host_module_file:s0"
RHIZO_TEARDOWN_LIB_HOST_MODULE_ROOT=/lib/modules
# shellcheck disable=SC2034
RHIZO_TEARDOWN_LIB_HOST_LABELS_PENDING=/var/lib/rhizo/.host-labels-pending
# shellcheck disable=SC2034
RHIZO_TEARDOWN_LIB_HOST_MODE_KEPT=/var/lib/rhizo/host-mode-kept.env

# set DEFERRED to the allowed cleanup paths
teardown_deferred_paths() {
  local purge="${1:-0}"
  DEFERRED=(
    "$RHIZO_TEARDOWN_LIB_PREPARED_ROOT"
    "$RHIZO_TEARDOWN_LIB_TEMPLATES_ROOT"
    "$RHIZO_TEARDOWN_LIB_DERIVED_ROOT"
    "$RHIZO_TEARDOWN_LIB_PREPARED_SENTINEL"
    "$RHIZO_TEARDOWN_LIB_VAR_CACHE"
    "$RHIZO_TEARDOWN_LIB_VAR_LOG"
    "$RHIZO_TEARDOWN_LIB_APPWATCH_BIN"
    "$RHIZO_TEARDOWN_LIB_LOOP_UDEV_RULE"
    "$RHIZO_TEARDOWN_LIB_DESKTOP_USER"
    "$RHIZO_TEARDOWN_LIB_INSTALL_FAILED"
    "${RHIZO_TEARDOWN_LIB_LAUNCH_TREES[@]}"
    "${RHIZO_TEARDOWN_LIB_LAUNCH_DIRS[@]}"
    "${RHIZO_TEARDOWN_LIB_ROOT_STATE[@]}"
  )
  if [[ "$purge" == 1 ]]; then
    DEFERRED+=(
      "$RHIZO_TEARDOWN_LIB_DATA_IMG"
      "$RHIZO_TEARDOWN_LIB_DATA_IMG.meta"
      "$RHIZO_TEARDOWN_LIB_UPDATE_ROOT"
      "$RHIZO_TEARDOWN_LIB_ETC_RHIZO"
      "$RHIZO_TEARDOWN_LIB_GSI_GLOB"
      "${RHIZO_TEARDOWN_LIB_STATE_PURGE[@]}"
    )
  fi
}

# print the mounts reaching a dir, deepest first
teardown_mounts_reaching() {
  local dir
  dir=$(realpath -m -- "$1")
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
    }' "${2:-/proc/self/mountinfo}" | sort -t $'\t' -k1,1nr | cut -f2-
}

# unmount a mount
teardown_detach_mount() {
  python3 -c 'import ctypes, sys; sys.exit(0 if ctypes.CDLL(None, use_errno=True).umount2(sys.argv[1].encode(), int(sys.argv[2])) == 0 else 1)' "$1" "$2"
}

# unmount all of the mounts reaching a dir
teardown_unmount_reaching() {
  local m
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    teardown_detach_mount "$m" 0 || teardown_detach_mount "$m" 2 || { echo "$m"; return 1; }
  done < <(teardown_mounts_reaching "$1" "${2:-/proc/self/mountinfo}")
  m=$(teardown_mounts_reaching "$1" "${2:-/proc/self/mountinfo}" | head -1)
  [[ -z "$m" ]] || { echo "$m"; return 1; }
}

# print the rhizo-final-cleanup.service unit text
teardown_final_cleanup_unit() {
  local purge="${1:-0}" unit
  unit=$(cat <<'UNIT'
[Unit]
Description=Rhizo leftover uninstall cleanup
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'rm -rf __RHIZO_TEARDOWN_DEFERRED__ /etc/modules-load.d/rhizo.conf'
__RHIZO_TEARDOWN_SWAPFILE_LINE__
__RHIZO_TEARDOWN_LABEL_LINE__
__RHIZO_TEARDOWN_MODULE_LABEL_LINE__
__RHIZO_TEARDOWN_ACCOUNT_LINE__
__RHIZO_TEARDOWN_REGEN_LINE__
__RHIZO_TEARDOWN_RMDIR_LINE__
ExecStart=/bin/sh -c 'systemctl disable rhizo-final-cleanup.service; rm -f /etc/systemd/system/rhizo-final-cleanup.service; systemctl daemon-reload'

[Install]
WantedBy=multi-user.target
UNIT
)
  local drop=__RHIZO_TEARDOWN_DROP__
  local label_line=$drop module_line=$drop rmdir_line=$drop swap_line=$drop account_line=$drop regen_line=$drop
  local account="${ACCOUNT_DEFERRED:-}" kind cmd
  if [[ -n "${LABELED[*]:-}" ]]; then
    label_line="ExecStart=/usr/bin/python3 -c \"import os,sys;a,c=sys.argv[1],sys.argv[2].encode();[os.removexattr(p,a) or print('cleared',p) for p in sys.argv[3:] if os.path.exists(p) and a in os.listxattr(p) and os.getxattr(p,a).rstrip(bytes(1))==c]\" security.selinux $RHIZO_TEARDOWN_LIB_HOST_EXEC_CONTEXT ${LABELED[*]:-}"
  fi
  if [[ "${MODULE_LABELS_DEFERRED:-0}" == 1 ]]; then
    module_line="ExecStart=/usr/bin/python3 -c \"import os,sys;a,c,r=sys.argv[1],sys.argv[2].encode(),sys.argv[3];[os.removexattr(p,a,follow_symlinks=False) for d,_,fs in os.walk(r) for p in [d]+[os.path.join(d,f) for f in fs] if not os.path.islink(p) and a in os.listxattr(p,follow_symlinks=False) and os.getxattr(p,a,follow_symlinks=False).rstrip(bytes(1))==c]\" security.selinux $RHIZO_TEARDOWN_LIB_HOST_MODULE_CONTEXT $RHIZO_TEARDOWN_LIB_HOST_MODULE_ROOT"
  fi
  if [[ "${SWAPFILE_DEFERRED:-0}" == 1 ]]; then
    swap_line="ExecStart=/bin/rm -f /swapfile"
  fi
  local name known lines=""
  for name in $account; do
    for known in "${RHIZO_TEARDOWN_LIB_ACCOUNTS[@]}"; do
      [[ "$name" == "$known" ]] || continue
      lines+="${lines:+$'\n'}ExecStart=/bin/sh -c 'getent passwd $name >/dev/null && { userdel $name || exit 1; }; getent group $name >/dev/null && { groupdel $name || exit 1; }; exit 0'"
    done
  done
  [[ -n "$lines" ]] && account_line=$lines
  lines=""
  for kind in ${REGEN_DEFERRED[@]+"${REGEN_DEFERRED[@]}"}; do
    cmd=$(bootloader_regen_host_cmd "$kind") || return 1
    lines+="${lines:+$'\n'}ExecStart=$cmd"
  done
  [[ -n "$lines" ]] && regen_line=$lines
  if [[ "$purge" == 1 ]]; then
    rmdir_line="ExecStart=-/bin/rmdir $RHIZO_TEARDOWN_LIB_STATE_ROOT /srv/rhizo"
  fi
  unit=${unit//__RHIZO_TEARDOWN_DEFERRED__/"${DEFERRED[*]}"}
  unit=${unit//__RHIZO_TEARDOWN_SWAPFILE_LINE__/"$swap_line"}
  unit=${unit//__RHIZO_TEARDOWN_LABEL_LINE__/"$label_line"}
  unit=${unit//__RHIZO_TEARDOWN_MODULE_LABEL_LINE__/"$module_line"}
  unit=${unit//__RHIZO_TEARDOWN_ACCOUNT_LINE__/"$account_line"}
  unit=${unit//__RHIZO_TEARDOWN_REGEN_LINE__/"$regen_line"}
  unit=${unit//__RHIZO_TEARDOWN_RMDIR_LINE__/"$rmdir_line"}
  printf '%s\n' "$unit" | grep -vx "$drop"
}

# print the swapfile identity string
teardown_swap_id() {
  local st uuid
  st=$(stat -c '%d:%i' "$1" 2>/dev/null) && uuid=$(blkid -o value -s UUID "$1" 2>/dev/null) \
    && [[ -n "$st" && -n "$uuid" ]] && echo "$st:$uuid"
}

# print fstab or file for the recorded swapfile
teardown_swap_owned() {
  local record="$1" swapfile="$2" id
  [[ -f "$record" ]] || return 0
  grep -qx swapfile-fstab "$record" && echo fstab
  id=$(teardown_swap_id "$swapfile")
  [[ -n "$id" ]] && grep -qxF "swapfile:$id" "$record" && echo file
  return 0
}

# remove the swap line from fstab
teardown_strip_fstab_line() {
  local record="$1" line="$2" fstab="$3" appended size tail_text
  local LC_ALL=C
  appended="$line"$'\n'
  grep -qx swapfile-fstab-eol "$record" && appended=$'\n'"$appended"
  size=$(stat -c %s "$fstab") || return 1
  tail_text=$(tail -c "${#appended}" "$fstab" && echo x) || return 1
  if [[ "$tail_text" == "${appended}x" ]]; then
    truncate -s $((size - ${#appended})) "$fstab"
  else
    sed -i "\#^${line//#/\\#}\$#d" "$fstab"
  fi
}

# remove the recorded swapfile and its fstab line
teardown_swap() {
  local record="$1" swapfile="$2" line="$3" fstab="$4" proc_swaps="$5" owned strip='/^swapfile-fstab$/d; /^swapfile-fstab-eol$/d; /^swapfile:/d'
  owned=$(teardown_swap_owned "$record" "$swapfile")
  if [[ "$owned" == *fstab* ]] && grep -qxF "$line" "$fstab" 2>/dev/null; then
    teardown_strip_fstab_line "$record" "$line" "$fstab" || { echo "failed strip '$line' from $fstab"; return 1; }
    echo removed-fstab
  fi
  if [[ "$owned" == *file* ]]; then
    if awk -v f="$swapfile" '$1 == f { on = 1 } END { exit !on }' "$proc_swaps" 2>/dev/null \
       && ! swapoff "$swapfile"; then
      echo "deferred-file swapoff $swapfile failed"
      strip='/^swapfile-fstab$/d; /^swapfile-fstab-eol$/d'
    elif ! rm -f "$swapfile"; then
      echo "deferred-file could not remove $swapfile"
      strip='/^swapfile-fstab$/d; /^swapfile-fstab-eol$/d'
    else
      echo removed-file
    fi
  elif [[ -e "$swapfile" || -L "$swapfile" ]]; then
    echo kept-file
  fi
  if [[ -f "$record" ]]; then
    sed -i "$strip" "$record" || { echo "failed strip the swap tokens from $record"; return 1; }
    [[ -s "$record" ]] || rm -f "$record"
  fi
  return 0
}

# delete the recorded system account and group
teardown_remove_recorded_account() {
  local record="$1" name="$2" want_uid="${3:-}" rc=0 uid
  [[ -f "$record" ]] || return 0
  if grep -qx "user:$name" "$record"; then
    uid=$(getent passwd "$name" | cut -d: -f3)
    if [[ -z "$uid" ]]; then
      sed -i "\#^user:$name\$#d" "$record"
    elif [[ -n "$want_uid" && "$uid" != "$want_uid" ]]; then
      echo "kept-user $name has uid $uid now, not the $want_uid this install created it with"
    elif userdel "$name"; then
      sed -i "\#^user:$name\$#d" "$record"
      echo "removed-user $name"
    else
      echo "failed userdel $name"
      rc=1
    fi
  fi
  if grep -qx "group:$name" "$record" && ! grep -qx "user:$name" "$record"; then
    if ! getent group "$name" >/dev/null; then
      sed -i "\#^group:$name\$#d" "$record"
    elif groupdel "$name"; then
      sed -i "\#^group:$name\$#d" "$record"
      echo "removed-group $name"
    else
      echo "failed groupdel $name"
      rc=1
    fi
  fi
  [[ -s "$record" ]] || rm -f "$record"
  return "$rc"
}

# remove the recorded appwatch account
teardown_remove_appwatch_account() {
  teardown_remove_recorded_account "$1" "$RHIZO_TEARDOWN_LIB_APPWATCH_ACCOUNT" 1000
}

# remove the recorded netbridged account
teardown_remove_netbridged_account() {
  teardown_remove_recorded_account "$1" "$RHIZO_TEARDOWN_LIB_NETBRIDGED_ACCOUNT"
}

# list the rhizo-netbridged service units
teardown_netbridged_units() {
  systemctl list-units --all --plain --no-legend --type=service 'rhizo-netbridged*' 2>/dev/null \
    | awk '$1 ~ /^rhizo-netbridged(-[0-9]+)?\.service$/ { print $1 }'
}
