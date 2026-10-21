#!/bin/bash
# boot a chosen Android release on a vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ./common.sh
source ./image/release-map.sh

# print the usage line to stderr
usage() {
  echo "boot-release.sh: usage: test/vm/boot-release.sh <a15|a16>" \
       "[--variant user|userdebug] [--no-wipe|--wipe] [--allow-unwaived]" \
       "[redeploy.sh args...]" >&2
}

# check for a boot-failure bundle written since the start
_boot_evidence_since_start() {
  local d="$1" since="$2" sub mtime
  [[ -d "$d" ]] || return 1
  for sub in "$d"/*/; do
    [[ -d "$sub" ]] || continue
    mtime=$(stat -c %Y "$sub" 2>/dev/null) || continue
    (( mtime >= since )) && return 0
  done
  return 1
}

LABEL="${1:-}"
if ! release_known "$LABEL"; then
  usage
  echo "  unknown or missing release label: '${LABEL:-<none>}' -- known: ${RELEASE_LABELS[*]}" >&2
  exit 2
fi
shift

VARIANT=user
WIPE=auto
ALLOW_UNWAIVED_ARGS=()
extra_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --no-wipe) WIPE=0; shift ;;
    --wipe) WIPE=1; shift ;;
    --allow-unwaived) ALLOW_UNWAIVED_ARGS+=(--allow-unwaived); shift ;;
    *) extra_args+=("$1"); shift ;;
  esac
done

case "$VARIANT" in
  user) gsi_dir="${GSI_DIR[$LABEL]}" ;;
  userdebug)
    if ! userdebug_known "$LABEL"; then
      usage
      echo "  no userdebug GSI exists for release '$LABEL' -- only: ${!GSI_DIR_USERDEBUG[*]}" >&2
      exit 2
    fi
    gsi_dir="${GSI_DIR_USERDEBUG[$LABEL]}"
    ;;
  *) usage; echo "  unknown --variant '$VARIANT' (expected user|userdebug)" >&2; exit 2 ;;
esac

export RHIZO_KERNEL="${GSI_KERNEL[$LABEL]}"
RHIZO_LOOP_MAX_LOOP="$(loop_max_loop "$LABEL")"; export RHIZO_LOOP_MAX_LOOP

if ! ../../tools/build/release.sh "$LABEL" "${ALLOW_UNWAIVED_ARGS[@]}" >&2; then
  log "boot-release: $LABEL needs something built first -- see the command named above"
  exit 1
fi
if [[ "$WIPE" == auto ]]; then
  WIPE=1
  last_release=$(rig_vm_recorded "$RHIZO_VM" release) || last_release=""
  last_variant=$(rig_vm_recorded "$RHIZO_VM" variant) || last_variant=""
  last_rc=$(rig_vm_recorded "$RHIZO_VM" rc) || last_rc=""
  if [[ "$last_release" == "$LABEL" && "$last_variant" == "$VARIANT" && "$last_rc" == 0 ]]; then
    WIPE=0
    log "  vm ${RHIZO_VM:-0} last booted $LABEL/$VARIANT cleanly -- keeping /data (pass --wipe to force a first boot)"
  fi
fi

DATA_STATE="preserved"
if [[ "$WIPE" == 1 ]]; then
  DATA_STATE="wiped"
  TEMPLATE_KEY=$(resolve_data_template "$LABEL" "$VARIANT") && [[ -n "$TEMPLATE_KEY" ]] || TEMPLATE_KEY=""
  if [[ -n "$TEMPLATE_KEY" ]]; then
    export RHIZO_DATA_TEMPLATE="$TEMPLATE_KEY"
    DATA_STATE="template@$TEMPLATE_KEY"
    log "  data template resolved: key=$TEMPLATE_KEY (format=${GSI_DATA_FORMAT[$LABEL]:-unknown})"
  else
    unset RHIZO_DATA_TEMPLATE
  fi
fi

log "boot-release.sh: $LABEL/$VARIANT -- ${GSI_DESC[$LABEL]}"
log "  gsi=$gsi_dir RHIZO_KERNEL=${RHIZO_KERNEL:-<default>} RHIZO_WIPE_DATA=$WIPE data_state=$DATA_STATE"

redeploy_args=(--boot-wait 300 --release "$LABEL")
if [[ "$LABEL" != "a16" || "$VARIANT" != "user" ]]; then
  redeploy_args+=(--gsi "$gsi_dir")
fi
redeploy_args+=("${extra_args[@]}")

if ssh_vm -t 8 true >/dev/null 2>&1; then
  if ! RHIZO_GSI="$gsi_dir" ./boot/preflight.sh --quiet; then
    log "boot-release: vm $RHIZO_VM failed preflight, not booting onto a broken vm"
    log "  fix what it named above, or re-derive the vm by deleting vm${SUFFIX}.qcow2"
    exit 1
  fi
fi

boot_start_epoch=$(date +%s)
RHIZO_BOOT_EXPLAINED_BY="boot-release.sh" RHIZO_WIPE_DATA="$WIPE" ./redeploy.sh "${redeploy_args[@]}"
rc=$?

cause=""
if (( rc != 0 )); then
  log "boot-release: the boot did not complete, explaining"
  explained=$(./boot/explain-boot.sh 2>&1)
  cause=$(sed -n 's/^CAUSE=//p' <<<"$explained")
  if [[ "$cause" == ANDROID_NOT_BOOTED ]]; then
    procs=$(sed -n 's/^STAGE=procs:\([^ ]*\).*/\1/p' <<<"$explained")
    [[ -n "$procs" ]] && cause="$cause:$procs"
  fi
  echo "$explained" >&2
fi
rig_vm_record_boot "$RHIZO_VM" "rc=$rc" "release=$LABEL" \
  "variant=$VARIANT" "wiped=$WIPE" "data_state=$DATA_STATE" ${cause:+"cause=$cause"}
if [[ -z "${TEST_NAME:-}" ]]; then
  if (( rc != 0 )); then
    ev_dir="${RHIZO_BOOT_EVIDENCE_DIR:-$VAR_DIR/scratch/boot-failure$SUFFIX}"
    if _boot_evidence_since_start "$ev_dir" "$boot_start_epoch"; then
      log "boot-release: a boot-failure bundle for this boot already sits under $ev_dir, not collecting a second"
    else
      ./boot/collect-boot-evidence.sh "$ev_dir" "$cause" >/dev/null
    fi
  fi
  rig_boot_outcome "$RHIZO_VM" "$( (( rc == 0 )) && echo PASSED || echo FAILED )" \
    ${cause:+"cause=$cause"} >/dev/null || echo "boot-release: boot record not updated" >&2
fi
exit $rc
