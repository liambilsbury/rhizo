#!/bin/bash
# relabel the guest render node
set -uo pipefail
_RENDER_NODE_RELABEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# bind a relabeled alias over the render node
render_node_relabel() {
  local uid="${1:?render_node_relabel needs the session uid}" label_out node present
  if [[ "${RHIZO_VM_GPU:-on}" == off ]]; then
    present=$(ssh_vm -t 10 'ls /sys/class/drm 2>/dev/null | grep -m1 "^renderD"' 2>/dev/null </dev/null)
    if [[ -z "$present" ]]; then
      log "no render node to relabel: RHIZO_VM_GPU=off boots the vm with no gpu device and the guest has none"
      return 0
    fi
    log "RHIZO_VM_GPU=off, but the guest has /dev/dri/$present -- relabeling it as on a vm with a gpu"
  fi
  node=$(ssh_vm -t 10 "bash -s -- --node 2>/dev/null" < "$_RENDER_NODE_RELABEL_DIR/../../../src/install/prepare/detect-gpu-driver.sh" \
    2>/dev/null | cut -d' ' -f1)
  [[ "$node" =~ ^/dev/dri/renderD[0-9]+$ ]] \
    || { log "FAIL: the guest's gpu resolver named no render node (got '$node')"; return 1; }
  label_out=$(ssh_vm -t 10 "python3 -c \"
import os, stat, subprocess
node = '$node'
st = os.stat(node)
alias = '/root/rhizo-render-node'
for _ in range(20):
    mounted = any(l.split()[4] == node
                  for l in open('/proc/self/mountinfo') if len(l.split()) > 4)
    if not mounted: break
    if subprocess.run(['umount', node]).returncode != 0: break
try: os.remove(alias)
except FileNotFoundError: pass
os.mknod(alias, stat.S_IFCHR | 0o666, st.st_rdev)
os.chown(alias, $uid, $uid)
os.chmod(alias, 0o660)
os.setxattr(alias, 'security.selinux', b'u:object_r:rhizo_render_device:s0\\\\0')
subprocess.run(['mount', '--bind', alias, node], check=True)
print('render-node bind-mount OK:', node, os.getxattr(node, 'security.selinux', follow_symlinks=False))
\"" 2>&1)
  echo "$label_out"
  [[ "$label_out" == *"bind-mount OK"* ]] || { log "FAIL: render-node relabel bind-mount did not confirm -- see output above"; return 1; }
  return 0
}
