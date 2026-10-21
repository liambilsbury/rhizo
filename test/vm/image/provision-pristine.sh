#!/bin/bash
# provision a bare pristine host to run Rhizo
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

[[ $# -eq 0 ]] || { echo "provision-pristine.sh takes no arguments (got '$*')" >&2; exit 2; }
GSI_IMG_GUEST="/root/share/system.img"
GSI_TREE="/srv/rhizo/gsi_system"

# return whether ssh answers within 5 seconds
reachable() { wait_for_ssh 5 >/dev/null 2>&1; }

# wait for ssh on the guest
wait_back() {
  local deadline=$((SECONDS + ${1:-300}))
  while (( SECONDS < deadline )); do
    reachable && return 0
    sleep 5
  done
  return 1
}

log "=== 0. the vm must already be up and bootstrapped"
reachable || { log "FAIL: instance $RHIZO_VM is not reachable -- boot it with RHIZO_BOOT=grub first"; exit 1; }
lsm=$(ssh_vm -t 15 'cat /sys/kernel/security/lsm 2>/dev/null')
case ",$lsm," in
  *,selinux,*) log "  selinux is active: $lsm" ;;
  *) log "FAIL: selinux is not an active LSM (got '$lsm') -- run src/install/bootstrap/bootstrap.sh and reboot first"; exit 1 ;;
esac

# mount the 9p share in the guest
mount_share() {
  guest_mount_share 60 || return 1
  log "  9p share mounted, $(ssh_vm -t 20 'ls /root/share | wc -l' | tr -d '[:space:]') files visible"
}

log "=== 1. 9p share mounted at /root/share"
mount_share || exit 1

running=$(ssh_vm -t 15 'uname -r' 2>/dev/null | tr -d '[:space:]')
log "=== 2. kernel: the distribution's own ($running)"

log "=== 5. the GSI tree at $GSI_TREE"
mount_share || exit 1
if [[ "$(ssh_vm -t 15 'cat /sys/fs/selinux/enforce 2>/dev/null')" == 1 ]]; then
  log "FAIL: vm $RHIZO_VM is already enforcing"
  log "  re-derive the vm (delete its disk) or boot it --no-launch first, then re-run this script"
  exit 1
fi
out=$(ssh_vm -t 900 "
  set -e
  if [ -x $GSI_TREE/bin/init ]; then echo TREE_ALREADY_OK; exit 0; fi
  test -f $GSI_IMG_GUEST || { echo 'NO_IMAGE'; exit 1; }
  avail=\$(df -k --output=avail /srv 2>/dev/null | tail -1 | tr -d ' ')
  [ \"\${avail:-0}\" -ge $RHIZO_GSI_STAGE_SPACE_KB ] || { echo \"LOW_SPACE=\$avail need=$RHIZO_GSI_STAGE_SPACE_KB\"; exit 1; }
  mkdir -p /srv/rhizo /mnt/gsi_src
  mountpoint -q /mnt/gsi_src && umount /mnt/gsi_src
  mount -o ro,loop $GSI_IMG_GUEST /mnt/gsi_src
  rm -rf $GSI_TREE.part
  cp -a /mnt/gsi_src/system $GSI_TREE.part
  umount /mnt/gsi_src
  mv $GSI_TREE.part $GSI_TREE
  test -x $GSI_TREE/bin/init || { echo 'NO_INIT'; exit 1; }
  sync
  echo TREE_STAGED" 2>&1)
if echo "$out" | grep -q TREE_ALREADY_OK; then
  log "  already staged"
elif echo "$out" | grep -q TREE_STAGED; then
  log "  staged from $GSI_IMG_GUEST"
else
  log "FAIL: GSI tree staging failed:"; echo "$out" >&2; exit 1
fi
rel=$(ssh_vm -t 20 "grep -hE '^ro\.build\.(id|version\.release)=' $GSI_TREE/build.prop 2>/dev/null | sort | tr '\n' ' '")
log "  tree reports: $rel"

log "=== 6. host entrypoint labels (label-host.sh apply)"
./label-host.sh apply 2>&1 | sed 's/^/  /' | tail -12
./label-host.sh verify 2>&1 | grep -c "$(printf 'rhizo_host_exec')" >/dev/null 2>&1 || true

log "=== 7. prepare: install-time offload plus the settling boot it contains"
{
  out=$(./prepare-guest.sh --release a16 --variant user 2>&1)
  echo "$out" | tail -60 | sed 's/^/  /'
  if grep -q 'RHIZO_PREPARE_RIG_OK' <<<"$out"; then
    dexopt=$(grep -o 'dexopt=[^ ]*' <<<"$out" | tail -1)
    log "  first boot prepared and settled (${dexopt:-dexopt=<already-prepared>})"
    touch "$VAR_DIR/settled$SUFFIX"
  else
    log "FAIL: prepare-guest.sh did not report RHIZO_PREPARE_RIG_OK"
    exit 1
  fi
}

log "=== flushing every write to disk before returning"
ssh_vm -t 120 'sync; sync' >/dev/null 2>&1 || { log "FAIL: could not sync the guest"; exit 1; }
log "  synced"

log "=== provisioned: instance $RHIZO_VM is ready for boot-smoke.sh"
