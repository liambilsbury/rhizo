#!/bin/bash
# remove gsi-update state from a vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

# print the usage line and exit
usage() { echo "usage: gsi-update-vm-reset.sh <instance> [--yes]" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
INSTANCE="$1"; shift
[[ "$INSTANCE" =~ ^[0-9]+$ ]] || usage
CONFIRM=1
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRM=0 ;;
    *) usage ;;
  esac
done

export RHIZO_VM="$INSTANCE"
source ../../vm/common.sh
source ../lib/gsi-update-cleanup.sh

if ! gsi_update_vm_has_residue; then
  if [[ "$GSI_UPDATE_RESIDUE_MSG" == could\ not\ check* ]]; then
    echo "gsi-update-vm-reset: could not check vm $RHIZO_VM for residue ($GSI_UPDATE_RESIDUE_MSG) -- proceeding with the real cleanup rather than silently claiming clean" >&2
  else
    echo "RHIZO_VM_RESET clean vm=$RHIZO_VM -- nothing to clear on vm $RHIZO_VM ($GSI_UPDATE_RESIDUE_MSG)"
    exit 0
  fi
fi
echo "gsi-update-vm-reset: vm $RHIZO_VM is not clean ($GSI_UPDATE_RESIDUE_MSG) -- about to stop androidd.service, remove /var/lib/rhizo/update, strip gsi-update.sh's own owned keys from androidd.env and the runtime state file, and restore data.img from its backup if one is still there." >&2
echo "Capture the evidence first if the state was left on purpose (var/scratch/gsi-update$INSTANCE/, /var/lib/rhizo/update)." >&2
if (( CONFIRM )); then
  read -r -p "type the vm number ($RHIZO_VM) to confirm: " ans
  [[ "$ans" == "$RHIZO_VM" ]] || { echo "aborted, nothing touched" >&2; exit 1; }
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT
gsi_update_cleanup_body 90 > "$OUT" 2>&1
BODY_RC=$?

if gsi_update_cleanup_verify; then
  echo "RHIZO_VM_RESET ok vm=$RHIZO_VM body_rc=$BODY_RC"
  exit 0
fi
echo "RHIZO_VM_RESET incomplete vm=$RHIZO_VM body_rc=$BODY_RC reason=\"$GSI_UPDATE_CLEANUP_VERIFY_MSG\"" >&2
echo "cleanup body's own remote output:" >&2
cat "$OUT" >&2
exit 1
