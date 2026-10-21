#!/bin/bash
# fetch a GSI image onto the VM
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../../test/vm/common.sh

source ../gsi-pins.sh

LABEL="${1:-}"
HOST_ONLY=0
FROM_IMAGE=""
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-only) HOST_ONLY=1; shift ;;
    --from-image) FROM_IMAGE="${2:-}"; shift 2 ;;
    *) echo "usage: $0 <a15|a16|a17|userdebug> [--host-only] [--from-image PATH]" >&2; exit 2 ;;
  esac
done
if [[ -z "$LABEL" ]]; then
  echo "usage: $0 <a15|a16|a17|userdebug> [--host-only] [--from-image PATH]" >&2; exit 2
fi
if [[ -z "$FROM_IMAGE" && -z "${GSI_URL[$LABEL]:-}" ]]; then
  echo "no published GSI for label '$LABEL' -- pass --from-image PATH for a locally-built one" >&2
  echo "usage: $0 <a15|a16|a17|userdebug> [--host-only] [--from-image PATH]" >&2; exit 2
fi

DL_DIR="$VAR_DIR/gsi-dl"
ZIP="$DL_DIR/gsi_$LABEL.zip"
IMG_SHARE="$SHARE_DIR/gsi_$LABEL.img"
GUEST_TREE="/srv/rhizo/gsi_system_$LABEL"
mkdir -p "$DL_DIR" "$SHARE_DIR"

log "=== $LABEL: ${GSI_DESC[$LABEL]:-locally built (--from-image $FROM_IMAGE)}"

if [[ -n "$FROM_IMAGE" ]]; then
  [[ -f "$FROM_IMAGE" ]] || { log "FAIL: --from-image '$FROM_IMAGE' does not exist"; exit 1; }
  if [[ "$FROM_IMAGE" -ef "$IMG_SHARE" ]]; then
    log "already staged at $IMG_SHARE (same inode)"
  else
    rm -f "$IMG_SHARE"
    ln "$FROM_IMAGE" "$IMG_SHARE" 2>/dev/null || cp --remove-destination "$FROM_IMAGE" "$IMG_SHARE" || {
      log "FAIL: could not stage $FROM_IMAGE -> $IMG_SHARE"; exit 1; }
    log "staged $FROM_IMAGE -> $IMG_SHARE"
  fi
  ls -l "$IMG_SHARE" >&2
else

need_dl=1
if [[ -f "$ZIP" ]]; then
  have=$(sha256sum "$ZIP" | cut -d' ' -f1)
  if [[ "$have" == "${GSI_SHA[$LABEL]}" ]]; then
    log "zip already present, sha256 verified"; need_dl=0
  else
    log "zip present but sha256 mismatch -- refetching"
  fi
fi
if (( need_dl )); then
  log "downloading $(basename "${GSI_URL[$LABEL]}") ..."
  curl -sS -L --retry 3 --retry-delay 5 -o "$ZIP.part" "${GSI_URL[$LABEL]}" || {
    log "FAIL: download failed"; exit 1; }
  have=$(sha256sum "$ZIP.part" | cut -d' ' -f1)
  if [[ "$have" != "${GSI_SHA[$LABEL]}" ]]; then
    log "FAIL: sha256 mismatch"; log "  want ${GSI_SHA[$LABEL]}"; log "  have $have"
    rm -f "$ZIP.part"; exit 1
  fi
  mv "$ZIP.part" "$ZIP"
  log "downloaded, sha256 verified"
fi

if [[ ! -f "$IMG_SHARE" ]]; then
  log "extracting system.img -> var/share/"
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  unzip -o -q "$ZIP" system.img build.prop -d "$tmp" || { log "FAIL: unzip failed"; exit 1; }
  mv "$tmp/system.img" "$IMG_SHARE"
  [[ -f "$tmp/build.prop" ]] && cp "$tmp/build.prop" "$VAR_DIR/gsi-dl/build.prop.$LABEL"
else
  log "system.img already staged at var/share/gsi_$LABEL.img"
fi
ls -l "$IMG_SHARE" >&2
fi

if (( HOST_ONLY )); then log "--host-only: stopping before guest staging"; exit 0; fi

wait_for_ssh 60 || { log "FAIL: no VM reachable to stage onto"; exit 1; }

avail_kb=$(ssh_vm -t 15 "df -k --output=avail /srv 2>/dev/null | tail -1" | tr -d ' ')
if [[ -n "$avail_kb" ]] && (( avail_kb < RHIZO_GSI_STAGE_SPACE_KB )); then
  log "FAIL: only $((avail_kb/1024)) MB free on the guest /srv -- need ~$((RHIZO_GSI_STAGE_SPACE_KB/1024)) MB headroom"
  exit 1
fi
log "guest free space: $((avail_kb/1024)) MB"

guest_mount_share || { log "FAIL: could not mount the 9p share to stage the GSI"; exit 1; }
prov_cmd="set -e
if [ -x '$GUEST_TREE/bin/init' ]; then echo TREE_ALREADY_OK; exit 0; fi
rm -rf '$GUEST_TREE' /tmp/gsi_mnt_$LABEL
mkdir -p /srv/rhizo /tmp/gsi_mnt_$LABEL
mount -o ro,loop /root/share/gsi_$LABEL.img /tmp/gsi_mnt_$LABEL
cp -a /tmp/gsi_mnt_$LABEL/system '$GUEST_TREE'
umount /tmp/gsi_mnt_$LABEL
rmdir /tmp/gsi_mnt_$LABEL
sync
test -x '$GUEST_TREE/bin/init'
echo TREE_OK"

if [[ "$(ssh_vm -t 15 'cat /sys/fs/selinux/enforce 2>/dev/null')" == 1 ]]; then
  log "FAIL: vm $RHIZO_VM is already enforcing -- SELinux denies rhizo_host under /srv/rhizo"
  log "  stage onto a new, still-permissive guest instead: RHIZO_VM=$RHIZO_VM test/vm/redeploy.sh --no-launch, then re-run this script"
  exit 1
fi

log "staging $GUEST_TREE on the guest (copies ~2 GB, takes a minute) ..."
if ! out=$(ssh_vm -t 600 "$prov_cmd" 2>&1); then
  log "FAIL: guest provisioning failed:"; echo "$out" >&2; exit 1
fi
if grep -q TREE_ALREADY_OK <<<"$out"; then
  log "$GUEST_TREE already staged"
elif grep -q TREE_OK <<<"$out"; then
  log "$GUEST_TREE staged OK"
else
  log "FAIL: provisioning did not confirm:"; echo "$out" >&2; exit 1
fi

ssh_vm -t 20 "grep -hE '^ro\.(build\.version\.(sdk|release)|system\.build\.version\.release)=' \
  '$GUEST_TREE/build.prop' 2>/dev/null | sort -u" >&2
log "=== $LABEL ready at $GUEST_TREE"
