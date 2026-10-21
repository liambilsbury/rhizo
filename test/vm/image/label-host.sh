#!/bin/bash
# label the vm's host binaries for SELinux
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

HOST_EXEC_CONTEXT="u:object_r:rhizo_host_exec:s0"

HOST_EXEC_PATHS_EXTRA=(
  /usr/sbin/sshd
  /usr/bin/bash
  /usr/bin/dash
  /usr/bin/python3
  /usr/bin/sway
  /usr/bin/dbus-daemon
  /usr/bin/systemctl
  /usr/sbin/modprobe
)

usage() {
  cat >&2 <<'EOF'
usage: label-host.sh [apply|verify|clear]

  apply   stamp security.selinux=u:object_r:rhizo_host_exec:s0 on the vm
          VM's own host entrypoint binaries (idempotent)
  verify  report the current security.selinux xattr of each of those paths
  clear   remove the xattr again (returns them to `unlabeled`)

Honors RHIZO_VM to pick which VM to act on.
EOF
  exit 2
}

# run the SELinux label script on the vm
remote_py() {
  local mode="$1"
  ssh_vm -t 90 "python3 - <<'PYEOF'
import os, sys
mode = ${mode@Q}
ctx = ${HOST_EXEC_CONTEXT@Q}
paths = [os.path.realpath('/proc/1/exe')] + '''${HOST_EXEC_PATHS_EXTRA[*]}'''.split()
# add the ELF interpreter path
for _line in open('/proc/self/maps'):
    _head, _sep, _p = _line.rstrip('\n').partition(' /')
    if not _sep:
        continue
    _p = '/' + _p.strip()
    if os.path.basename(_p).startswith('ld-') and '.so' in os.path.basename(_p):
        paths.append(_p)
        break
# add the core dump program path
try:
    _w = open('/proc/sys/kernel/core_pattern').read().split()
except OSError:
    _w = []
if _w and _w[0].startswith('|/'):
    paths.append(_w[0][1:])
rc = 0
seen = set()
for p in paths:
    if not os.path.exists(p):
        print('absent: %s' % p); continue
    real = os.path.realpath(p)
    if real in seen: continue
    seen.add(real)
    if mode == 'apply':
        try:
            os.setxattr(real, 'security.selinux', (ctx + '\\0').encode())
            print('labeled: %s' % real)
        except OSError as e:
            print('FAILED:  %s (%s)' % (real, e)); rc = 1
    elif mode == 'verify':
        try:
            v = os.getxattr(real, 'security.selinux').decode().rstrip('\\0')
        except OSError:
            v = '<none>'
        print('%-34s %s' % (v, real))
    elif mode == 'clear':
        try:
            os.removexattr(real, 'security.selinux'); print('cleared: %s' % real)
        except OSError:
            print('nothing to clear: %s' % real)
sys.exit(rc)
PYEOF"
}

case "${1:-}" in
  apply)  log "labeling host entrypoint binaries on instance $RHIZO_VM"; remote_py apply || { log "label-host: apply FAILED"; exit 1; } ;;
  verify) remote_py verify ;;
  clear)  remote_py clear ;;
  *)      usage ;;
esac
