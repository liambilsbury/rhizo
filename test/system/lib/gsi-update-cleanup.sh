#!/bin/bash
# define the gsi-update vm cleanup functions
# shellcheck disable=SC2034

GSI_UPDATE_OWNED_ENV_KEYS='RHIZO_GSI|RHIZO_RELEASE|RHIZO_DATA_IMG|RHIZO_RELEASE_SWITCH'

# restore the vm to its pre-test state
gsi_update_cleanup_body() {
  local timeout_s="${1:-90}" expected="${2:-}"
  ssh_vm -t "$timeout_s" '
    systemctl stop androidd.service
    rm -rf /var/lib/rhizo/update
    rm -f /var/lib/rhizo/.rhizo_release_switch_pending
    sed -i -E "/^('"$GSI_UPDATE_OWNED_ENV_KEYS"')=/d" /root/androidd.env /var/lib/rhizo/androidd-runtime.env 2>/dev/null
    if [ -s /var/lib/rhizo/test-gsi-update-backup.img ]; then
      restore_ok=1
      expected="'"$expected"'"
      if [ -n "$expected" ]; then
        sentinel=$(cat /var/lib/rhizo/test-gsi-update-backup.img.taken 2>/dev/null)
        [ "$sentinel" = "$expected" ] || restore_ok=0
      fi
      if [ "$restore_ok" = 1 ]; then
        if mv -f /var/lib/rhizo/test-gsi-update-backup.img /var/lib/rhizo/data.img; then
          if [ -f /var/lib/rhizo/test-gsi-update-backup.img.meta ]; then
            mv -f /var/lib/rhizo/test-gsi-update-backup.img.meta /var/lib/rhizo/data.img.meta
          else
            rm -f /var/lib/rhizo/data.img.meta
          fi
          rm -f /var/lib/rhizo/test-gsi-update-backup.img.taken
        fi
      fi
    elif [ -e /var/lib/rhizo/test-gsi-update-backup.img.absent ]; then
      restore_ok=1
      expected="'"$expected"'"
      if [ -n "$expected" ]; then
        sentinel=$(cat /var/lib/rhizo/test-gsi-update-backup.img.taken 2>/dev/null)
        [ "$sentinel" = "$expected" ] || restore_ok=0
      fi
      if [ "$restore_ok" = 1 ]; then
        if rm -f /var/lib/rhizo/data.img; then
          if [ -f /var/lib/rhizo/test-gsi-update-backup.img.meta ]; then
            mv -f /var/lib/rhizo/test-gsi-update-backup.img.meta /var/lib/rhizo/data.img.meta
          else
            rm -f /var/lib/rhizo/data.img.meta
          fi
          rm -f /var/lib/rhizo/test-gsi-update-backup.img.absent /var/lib/rhizo/test-gsi-update-backup.img.taken
        fi
      fi
    else
      rm -f /var/lib/rhizo/test-gsi-update-backup.img /var/lib/rhizo/test-gsi-update-backup.img.meta
    fi
    sync
  '
}

# check the vm for cleanup leftovers
gsi_update_cleanup_verify() {
  local timeout_s="${1:-30}" expected="${2:-}" out rc line
  local sentinel="" have_sentinel=0 backup_present=0 foreign=0
  local -a left=()
  out=$(ssh_vm -t "$timeout_s" '
    systemctl is-active --quiet androidd.service && echo "androidd-still-active"
    [ -e /var/lib/rhizo/update ] && echo "update-dir-present"
    [ -s /var/lib/rhizo/test-gsi-update-backup.img ] && echo "backup-img-present"
    [ -e /var/lib/rhizo/test-gsi-update-backup.img.absent ] && echo "backup-absent-present"
    [ -f /var/lib/rhizo/test-gsi-update-backup.img.meta ] && echo "backup-meta-present"
    [ -e /var/lib/rhizo/.rhizo_release_switch_pending ] && echo "release-switch-pending-present"
    [ -e /var/lib/rhizo/test-gsi-update-backup.img.taken ] && echo "restore-not-performed"
    [ -e /var/lib/rhizo/test-gsi-update-backup.img.taken ] && echo "sentinel-run-id=$(cat /var/lib/rhizo/test-gsi-update-backup.img.taken 2>/dev/null | tr -d "\r\n")"
    grep -Eq "^('"$GSI_UPDATE_OWNED_ENV_KEYS"')=" /root/androidd.env /var/lib/rhizo/androidd-runtime.env 2>/dev/null && echo "owned-env-keys-present"
    exit 0
  ')
  rc=$?
  GSI_UPDATE_CLEANUP_VERIFY_MSG=""
  GSI_UPDATE_CLEANUP_FOREIGN_MSG=""
  if (( rc != 0 )); then
    GSI_UPDATE_CLEANUP_VERIFY_MSG="could not verify -- ssh_vm itself failed (rc=$rc), the vm may be unreachable"
    return 1
  fi

  while IFS= read -r line; do
    case "$line" in
      sentinel-run-id=*)     sentinel="${line#sentinel-run-id=}" ;;
      restore-not-performed) have_sentinel=1 ;;
      backup-img-present|backup-absent-present) backup_present=1 ;;
    esac
  done <<<"$out"

  if (( backup_present || have_sentinel )) && [[ -n "$expected" && -n "$sentinel" && "$sentinel" != "$expected" ]]; then
    foreign=1
    GSI_UPDATE_CLEANUP_FOREIGN_MSG="FOREIGN_BACKUP_LEFT: $sentinel -- run test/system/manual/gsi-update-vm-reset.sh ${RHIZO_VM:-<vm>}"
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      sentinel-run-id=*) continue ;;
      backup-img-present|backup-absent-present|backup-meta-present|restore-not-performed)
        (( foreign )) && continue ;;
    esac
    left+=("$line")
  done <<<"$out"

  if (( ${#left[@]} > 0 )); then
    GSI_UPDATE_CLEANUP_VERIFY_MSG="left behind: ${left[*]}"
    return 1
  fi
  return 0
}

# check the vm for gsi-update residue
gsi_update_vm_has_residue() {
  local timeout_s="${1:-30}" out rc
  out=$(ssh_vm -t "$timeout_s" '
    [ -e /var/lib/rhizo/update ] && echo "update-dir-present"
    [ -s /var/lib/rhizo/test-gsi-update-backup.img ] && echo "backup-img-present"
    [ -e /var/lib/rhizo/test-gsi-update-backup.img.absent ] && echo "backup-absent-present"
    [ -f /var/lib/rhizo/test-gsi-update-backup.img.meta ] && echo "backup-meta-present"
    [ -e /var/lib/rhizo/.rhizo_release_switch_pending ] && echo "release-switch-pending-present"
    [ -e /var/lib/rhizo/test-gsi-update-backup.img.taken ] && echo "restore-not-performed"
    exit 0
  ')
  rc=$?
  GSI_UPDATE_RESIDUE_MSG=""
  if (( rc != 0 )); then
    GSI_UPDATE_RESIDUE_MSG="could not check -- ssh_vm itself failed (rc=$rc), the vm may be unreachable"
    return 1
  fi
  if [[ -n "$out" ]]; then
    GSI_UPDATE_RESIDUE_MSG="residue found: $(tr '\n' ' ' <<<"$out" | sed 's/ *$//')"
    return 0
  fi
  GSI_UPDATE_RESIDUE_MSG="no gsi-update residue found"
  return 1
}
