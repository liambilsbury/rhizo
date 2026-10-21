#!/bin/bash
# test the common.sh ssh ControlPath length and directory
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMON="$HERE/../vm/common.sh"
HOOKS="$HERE/../vm/rig/hooks.sh"
[[ -r "$COMMON" ]] || { echo "FAIL: cannot read $COMMON"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SHALLOW="$TMP/s/vm"
DEEP="$TMP/d/.worktrees/a-worktree-name-of-ordinary-length/vm"
mkdir -p "$SHALLOW/tools/rig" "$DEEP/tools/rig"
cp "$COMMON" "$SHALLOW/tools/common.sh"
cp "$COMMON" "$DEEP/tools/common.sh"
cp "$HOOKS" "$SHALLOW/tools/rig/hooks.sh"
cp "$HOOKS" "$DEEP/tools/rig/hooks.sh"

if (( SELFTEST )); then
  for f in "$SHALLOW/tools/common.sh" "$DEEP/tools/common.sh"; do
    sed -i 's|^SSH_CONTROL_DIR=.*|SSH_CONTROL_DIR="$VAR_DIR/.ssh-control"|' "$f"
  done
fi

# print SSH_CONTROL_SOCK from a common.sh copy
read_sock() {
  RHIZO_VM=1 bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${SSH_CONTROL_SOCK:-}"' _ "$1"
}

sock_shallow="$(read_sock "$SHALLOW/tools/common.sh")"
sock_deep="$(read_sock "$DEEP/tools/common.sh")"

# print a failure message and exit 1
fail() { echo "FAIL: $*"; exit 1; }

if (( SELFTEST )); then
  if [[ -n "$sock_shallow" && "$sock_shallow" == "$sock_deep" ]]; then
    echo "SELFTEST FAIL: the reverted depth defect still looked clean ($sock_shallow)"
    exit 1
  fi

  NAIVE="$TMP/n/vm"
  mkdir -p "$NAIVE/tools/rig"
  cp "$COMMON" "$NAIVE/tools/common.sh"
  cp "$HOOKS" "$NAIVE/tools/rig/hooks.sh"
  sed -i 's|^SSH_CONTROL_DIR=.*|SSH_CONTROL_DIR="${XDG_RUNTIME_DIR:-/tmp}/rhizo-ssh-$(id -u)"|' \
    "$NAIVE/tools/common.sh"
  HOSTILE="$TMP/selftest-unwritable"
  mkdir -p "$HOSTILE"
  chmod 0500 "$HOSTILE"
  naive_dir="$(RHIZO_VM=1 XDG_RUNTIME_DIR="$HOSTILE" bash -c \
    'source "$1" >/dev/null 2>&1; printf "%s" "${SSH_CONTROL_DIR:-}"' _ "$NAIVE/tools/common.sh")"
  if [[ "$naive_dir" != "$HOSTILE"/* ]]; then
    echo "SELFTEST FAIL: the reverted writability defect still looked clean (chose '$naive_dir', not a path under the unwritable '$HOSTILE')"
    exit 1
  fi

  echo "selftest ok: both defects are detected (depth: shallow='$sock_shallow' deep='$sock_deep'; writability: naive chose '$naive_dir')"
  exit 0
fi

[[ -n "$sock_shallow" ]] || fail "common.sh defined no SSH_CONTROL_SOCK at $SHALLOW"
[[ -n "$sock_deep" ]] || fail "common.sh defined no SSH_CONTROL_SOCK at $DEEP"

[[ "$sock_shallow" == "$sock_deep" ]] || fail \
  "ControlPath varies with the checkout's depth: shallow='$sock_shallow' deep='$sock_deep'"

(( ${#sock_deep} <= 91 )) || fail \
  "ControlPath is ${#sock_deep} bytes, over the 91 ssh's temp suffix leaves of sun_path's 108: '$sock_deep'"

UNWRITABLE="$TMP/unwritable"
mkdir -p "$UNWRITABLE"
chmod 0500 "$UNWRITABLE"

# print SSH_CONTROL_DIR for an XDG_RUNTIME_DIR
read_dir_under_xdg() {
  RHIZO_VM=1 XDG_RUNTIME_DIR="$2" bash -c \
    'source "$1" >/dev/null 2>&1; printf "%s" "${SSH_CONTROL_DIR:-}"' _ "$1"
}

dir_hostile="$(read_dir_under_xdg "$SHALLOW/tools/common.sh" "$UNWRITABLE")"

[[ -n "$dir_hostile" ]] || fail \
  "with XDG_RUNTIME_DIR pointing at an unwritable directory, common.sh chose no ControlMaster directory at all"

[[ "$dir_hostile" != "$UNWRITABLE"/* ]] || fail \
  "common.sh put the ControlMaster socket under an unwritable XDG_RUNTIME_DIR ('$dir_hostile')"

probe="$dir_hostile/.check-ssh-control-path.$$"
( : > "$probe" ) 2>/dev/null || fail \
  "common.sh chose ControlMaster directory '$dir_hostile', which cannot hold a file"
rm -f "$probe"

APPSYNC="$HERE/../../src/services/appsync/appsync.py"
if [[ -r "$APPSYNC" ]]; then
  dir_appsync="$(RHIZO_VM=1 XDG_RUNTIME_DIR="$UNWRITABLE" python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("appsync", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
sys.stdout.write(mod._SSH_CONTROL_DIR)
' "$APPSYNC" 2>/dev/null)"
  [[ -n "$dir_appsync" ]] || fail \
    "appsync.py computed no ControlMaster directory under an unwritable XDG_RUNTIME_DIR"
  [[ "$dir_appsync" == "$dir_hostile" ]] || fail \
    "appsync.py and common.sh disagree about the ControlMaster directory ('$dir_appsync' vs '$dir_hostile')"
fi

echo "ok: ControlPath is checkout-independent, ${#sock_deep} bytes ('$sock_deep'), falls back to a writable directory ('$dir_hostile') when XDG_RUNTIME_DIR is not one${dir_appsync:+, and appsync.py agrees}"
