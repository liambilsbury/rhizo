#!/bin/bash
# test the render-node relabel on gpu and no-gpu vms
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
bad=0
GUEST_NODE=""

# record guest commands and answer as a guest with GUEST_NODE
ssh_vm() {
  printf '%s\n' "$*" >> "$WORK/ssh"
  cat > /dev/null
  case "$*" in
    *"ls /sys/class/drm"*) [[ -n "$GUEST_NODE" ]] && echo "${GUEST_NODE##*/}" ;;
    *"--node"*) [[ -n "$GUEST_NODE" ]] && echo "$GUEST_NODE amdgpu" ;;
    *os.mknod*) echo "render-node bind-mount OK: $GUEST_NODE b'u:object_r:rhizo_render_device:s0\\x00'" ;;
  esac
  return 0
}
# record the helper's log lines
log() { printf '%s\n' "$*" >> "$WORK/log"; }

source ../vm/start/render-node-relabel.sh

# run the relabel with a gpu knob and a guest render node
relabel() {
  : > "$WORK/ssh"; : > "$WORK/log"
  GUEST_NODE="$2" RHIZO_VM_GPU="$1" render_node_relabel 1000 >/dev/null </dev/null; rc=$?
}

relabel off ""
[[ $rc == 0 ]] || { echo "render-node-nogpu: RHIZO_VM_GPU=off with no guest render node failed the session start (rc=$rc): $(cat "$WORK/log")" >&2; bad=1; }
grep -q -- '--node' "$WORK/ssh" && { echo "render-node-nogpu: RHIZO_VM_GPU=off with no guest render node still ran the resolver" >&2; bad=1; }
grep -q 'os.mknod' "$WORK/ssh" && { echo "render-node-nogpu: RHIZO_VM_GPU=off with no guest render node still relabeled something" >&2; bad=1; }
grep -q 'RHIZO_VM_GPU=off' "$WORK/log" || { echo "render-node-nogpu: RHIZO_VM_GPU=off stood down without saying why" >&2; bad=1; }

relabel off /dev/dri/renderD128
[[ $rc == 0 ]] || { echo "render-node-nogpu: RHIZO_VM_GPU=off on a guest with a render node failed (rc=$rc): $(cat "$WORK/log")" >&2; bad=1; }
grep -q 'os.mknod' "$WORK/ssh" \
  || { echo "render-node-nogpu: RHIZO_VM_GPU=off on a guest that has /dev/dri/renderD128 skipped the relabel" >&2; bad=1; }
grep -q 'renders in software' "$WORK/log" \
  && { echo "render-node-nogpu: RHIZO_VM_GPU=off on a guest with a render node logged the software stand-down" >&2; bad=1; }

for mode in on ""; do
  relabel "$mode" ""
  [[ $rc != 0 ]] || { echo "render-node-nogpu: RHIZO_VM_GPU='$mode' passed with no render node" >&2; bad=1; }
  grep -q 'named no render node' "$WORK/log" \
    || { echo "render-node-nogpu: RHIZO_VM_GPU='$mode' did not name the missing render node: $(cat "$WORK/log")" >&2; bad=1; }
done

relabel on /dev/dri/renderD128
[[ $rc == 0 ]] && grep -q 'os.mknod' "$WORK/ssh" \
  || { echo "render-node-nogpu: RHIZO_VM_GPU=on with a render node did not relabel it (rc=$rc)" >&2; bad=1; }

(( bad )) && exit 1
echo "render-node-nogpu: ok"
