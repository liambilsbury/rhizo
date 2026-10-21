#!/bin/bash
# run prepare.sh in a newly booted guest
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

RELEASE=a16
VARIANT=user
WIPE_DATA=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wipe-data) WIPE_DATA=1; shift ;;
    --release) RELEASE="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

PRODUCT="$REPO/src/install/prepare/prepare.sh"
[[ -f "$PRODUCT" ]] || { log "FAIL: no $PRODUCT"; exit 1; }

# copy the payload files to the guest
stage_payload() {
  timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$PRODUCT" "$SSH_TARGET:/root/prepare.sh" \
    || { log "FAIL: could not stage $PRODUCT"; return 1; }
  local lib libs
  libs=$(sed -n 's/^\. "\$HERE\/\([^"]*\)".*/\1/p' "$PRODUCT")
  [[ -n "$libs" ]] || { log "FAIL: found no \`. \"\$HERE/<lib>\"\` line in $PRODUCT"; return 1; }
  for lib in $libs; do
    timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "${PRODUCT%/*}/$lib" "$SSH_TARGET:/root/$lib" \
      || { log "FAIL: could not stage $lib"; return 1; }
  done
  local f
  for f in src/services/probe-client/probe-client.py src/install/prepare/materialize-data-template.py src/install/prepare/data-template.sh src/install/prepare/detect-gpu-driver.sh src/install/prepare/verify-prepared-tree.py; do
    [[ -f "$REPO/$f" ]] || { log "FAIL: no $REPO/$f to stage"; return 1; }
    timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$REPO/$f" "$SSH_TARGET:/root/${f##*/}" \
      || { log "FAIL: could not stage ${f##*/}"; return 1; }
  done
  return 0
}

# run prepare.sh in the guest
run_product() {
  local wipe_flag="" st
  (( WIPE_DATA )) && wipe_flag=" --wipe-data"
  ssh_vm -t 30 "rm -f /root/rhizo-prepare.log; systemctl reset-failed rhizo-prepare.service 2>/dev/null; systemd-run --quiet --unit=rhizo-prepare --collect -p StandardOutput=append:/root/rhizo-prepare.log -p StandardError=append:/root/rhizo-prepare.log bash /root/prepare.sh --payload /root --gsi /srv/rhizo/gsi_system --release $RELEASE --variant $VARIANT$wipe_flag" \
    || { echo "RHIZO_PREPARE_FAILED reason=unit-start"; return 1; }
  local deadline=$((SECONDS + 2700))
  while (( SECONDS < deadline )); do
    st=$(ssh_vm -t 15 'systemctl is-active rhizo-prepare.service 2>/dev/null' | tr -d '\r')
    case "$st" in
      active|activating|deactivating|"") sleep 10 ;;
      *) break ;;
    esac
  done
  ssh_vm -t 30 'cat /root/rhizo-prepare.log 2>/dev/null'
}

log "=== boot a new guest"
kill_vm
boot_vm
wait_for_boot_slot || { log "FAIL: this vm's boot never got a qemu slot"; exit 1; }
wait_for_ssh 180 || { log "FAIL: the new boot never came up"; exit 1; }
enforce=$(ssh_vm -t 15 'cat /sys/fs/selinux/enforce 2>/dev/null')
[[ "$enforce" == 0 ]] || log "note: /sys/fs/selinux/enforce='$enforce' on the new boot"

log "=== stage: redeploy.sh --no-launch (guest inputs, unit file, 9p)"
if ! RHIZO_USE_UNIT=1 ../redeploy.sh --skip-kill --no-launch; then
  log "FAIL: redeploy.sh --no-launch could not stage the guest"
  exit 1
fi

log "=== stage: the product script and its payload companions"
stage_payload || exit 1

# stop androidd.service in the guest
stop_stack() {
  local st
  for _ in $(seq 1 30); do
    st=$(ssh_vm -t 120 'systemctl stop androidd.service 2>/dev/null; systemctl is-active androidd.service 2>/dev/null' | tr -d '\r' | tail -1)
    case "$st" in inactive|failed|unknown) break ;; esac
    sleep 2
  done
  case "$st" in inactive|failed|unknown) ;; *) log "FAIL: androidd.service still '$st' after 60s"; return 1 ;; esac
  local ip
  for _ in $(seq 1 45); do
    ip=$(ssh_vm -t 15 "$RHIZO_INIT_SCAN_BODY | head -1; echo RHIZO_PGREP_OK" | tr -d '\r')
    case "$ip" in
      *RHIZO_PGREP_OK*) [[ "$(grep -v RHIZO_PGREP_OK <<<"$ip" | head -1)" == "" ]] && return 0 ;;
    esac
    sleep 2
  done
  log "FAIL: the sandbox's init is still running 90s after the stop"
  return 1
}
ssh_vm -t 60 'systemctl stop rhizo-resync.path rhizo-display-pool.path rhizo-app-events.service rhizo-resync.service 2>/dev/null; true' >/dev/null
stop_stack || { echo "RHIZO_PREPARE_RIG_FAILED reason=stack-would-not-stop"; exit 1; }
log "=== run: src/install/prepare/prepare.sh --release $RELEASE --variant $VARIANT$( ((WIPE_DATA)) && echo ' --wipe-data')"
out=$(run_product 2>&1)
echo "$out" | sed 's/^/  /'

key=$(sed -n 's/^RHIZO_PREPARE_OK key=\([0-9a-f]*\).*/\1/p' <<<"$out" | tail -1)
if grep -q 'RHIZO_PREPARE_ALREADY_PREPARED=1' <<<"$out"; then
  log "=== already prepared"
elif [[ -n "$key" ]]; then
  log "=== prepared: key=$key"
else
  log "FAIL: the product script did not report RHIZO_PREPARE_OK or RHIZO_PREPARE_ALREADY_PREPARED"
  echo "RHIZO_PREPARE_RIG_FAILED reason=product-script-did-not-confirm"
  exit 1
fi

log "=== verify"
verify_out=$(ssh_vm -t 120 'bash /root/prepare.sh --verify' 2>&1)
echo "$verify_out" | sed 's/^/  /'
grep -q 'RHIZO_PREPARE_VERIFIED=1' <<<"$verify_out" || { log "FAIL: --verify did not confirm"; echo "RHIZO_PREPARE_RIG_FAILED reason=verify-failed"; exit 1; }

log "=== flushing every write to disk before returning"
ssh_vm -t 60 'sync; sync' >/dev/null 2>&1 || { log "FAIL: could not sync the guest"; exit 1; }

[[ -n "$key" ]] && rig_vm_record "$RHIZO_VM" prepared="$key" prepared_release="$RELEASE" \
  prepared_variant="$VARIANT"

log "RHIZO_PREPARE_RIG_OK key=${key:-<already-prepared, no new key reported>}"
echo "RHIZO_PREPARE_RIG_OK"
