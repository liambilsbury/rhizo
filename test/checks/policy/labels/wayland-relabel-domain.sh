#!/bin/bash
# check the start-sway.sh wayland socket relabel
set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SWAY_SCRIPT="${RHIZO_CHECK_SWAY:-$TOOLS_DIR/../vm/start/start-sway.sh}"
POLICY_CIL="${RHIZO_CHECK_CIL:-$(cd "$TOOLS_DIR/../.." && pwd)/src/androidd/guest/sepolicy/policy.cil}"
GRANT='(allow rhizo_host kernel (sock_file (relabelfrom)))'
TMPFS_GRANT='(allow rhizo_host tmpfs (sock_file (relabelfrom)))'

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' EXIT

  cat > "$t/good-sway.sh" <<'EOF'
wayland_label_out=$(ssh_vm -t 10 "python3 -c \"
import os
sock = '/run/user/0/wayland-1'
os.setxattr(sock, 'security.selinux', b'u:object_r:rhizo_wayland_socket:s0\\\\0')
\"" 2>&1)
EOF
  cat > "$t/good.cil" <<EOF
(allow rhizo_host rhizo_wayland_socket (sock_file (relabelto)))
$GRANT
$TMPFS_GRANT
EOF

  out=$(RHIZO_CHECK_SWAY="$t/good-sway.sh" RHIZO_CHECK_CIL="$t/good.cil" "$SELF" 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "SELFTEST FAILED: the good fixture (python3 setxattr + CIL grant) was reported as broken" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  cat > "$t/chcon-sway.sh" <<'EOF'
ssh_vm -t 10 "chcon u:object_r:rhizo_wayland_socket:s0 /run/user/0/$real_sock" \
  || { log "FAIL: could not label /run/user/0/$real_sock rhizo_wayland_socket"; exit 1; }
EOF
  out=$(RHIZO_CHECK_SWAY="$t/chcon-sway.sh" RHIZO_CHECK_CIL="$t/good.cil" "$SELF" 2>&1); rc=$?
  if [[ $rc -eq 0 ]] || ! grep -q 'shells out to chcon' <<<"$out"; then
    echo "SELFTEST FAILED: a chcon-based relabel of rhizo_wayland_socket was not caught" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  cat > "$t/no-grant.cil" <<'EOF'
(allow rhizo_host rhizo_wayland_socket (sock_file (relabelto)))
EOF
  out=$(RHIZO_CHECK_SWAY="$t/good-sway.sh" RHIZO_CHECK_CIL="$t/no-grant.cil" "$SELF" 2>&1); rc=$?
  if [[ $rc -eq 0 ]] || ! grep -qF "$GRANT" <<<"$out"; then
    echo "SELFTEST FAILED: a missing relabelfrom-on-kernel grant was not caught" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  printf '%s\n%s\n' '(allow rhizo_host rhizo_wayland_socket (sock_file (relabelto)))' "$GRANT" > "$t/no-tmpfs-grant.cil"
  out=$(RHIZO_CHECK_SWAY="$t/good-sway.sh" RHIZO_CHECK_CIL="$t/no-tmpfs-grant.cil" "$SELF" 2>&1); rc=$?
  if [[ $rc -eq 0 ]] || ! grep -qF "$TMPFS_GRANT" <<<"$out"; then
    echo "SELFTEST FAILED: a missing relabelfrom-on-tmpfs grant was not caught" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  cat > "$t/blank-sway.sh" <<'EOF'
echo "no relabel happens here"
EOF
  out=$(RHIZO_CHECK_SWAY="$t/blank-sway.sh" RHIZO_CHECK_CIL="$t/good.cil" "$SELF" 2>&1); rc=$?
  if [[ $rc -eq 0 ]] || ! grep -q 'no python3 setxattr' <<<"$out"; then
    echo "SELFTEST FAILED: a script with no relabel step at all was not caught" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  echo "selftest ok: catches a chcon-based wayland-socket relabel, a missing rhizo_host relabelfrom grant on kernel or on tmpfs, and a script with no relabel step"
  exit 0
fi

FAILED=0

if grep -nE 'chcon[^|&;]*rhizo_wayland_socket' "$SWAY_SCRIPT" >/dev/null; then
  echo "FAIL: $SWAY_SCRIPT shells out to chcon to label rhizo_wayland_socket"
  FAILED=1
fi

if ! grep -B5 'rhizo_wayland_socket' "$SWAY_SCRIPT" | grep -q 'setxattr('; then
  echo "FAIL: $SWAY_SCRIPT has no python3 setxattr relabeling rhizo_wayland_socket"
  FAILED=1
fi

if ! grep -qF "$GRANT" "$POLICY_CIL"; then
  echo "FAIL: $POLICY_CIL is missing $GRANT"
  FAILED=1
fi

if ! grep -qF "$TMPFS_GRANT" "$POLICY_CIL"; then
  echo "FAIL: $POLICY_CIL is missing $TMPFS_GRANT"
  FAILED=1
fi

(( FAILED )) && exit 1
echo "wayland socket relabel stays off chcon, CIL grants present for a kernel- or tmpfs-typed socket"
exit 0
