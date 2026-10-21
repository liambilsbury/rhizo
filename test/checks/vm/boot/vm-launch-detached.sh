#!/usr/bin/env bash
# test the detached VM launch
set -uo pipefail

# set the placeholder command line
placeholder() { PLACEHOLDER=(bash -c 'sleep 30; :' "$1"); }

# start the placeholder with setsid --fork
launch_detached() {
  placeholder "$1"
  ( setsid --fork "${PLACEHOLDER[@]}" >/dev/null 2>&1 </dev/null & disown; exit 0 ) >/dev/null 2>&1 </dev/null
}

# start the placeholder in the background
launch_attached() {
  placeholder "$1"
  "${PLACEHOLDER[@]}" >/dev/null 2>&1 </dev/null &
}

# test the marked process for detachment
marked_is_detached() {
  local marker="$1" pid="" p under=1 deadline=$((SECONDS + 5))
  while [ -z "$pid" ] && [ $SECONDS -lt $deadline ]; do
    pid=$(pgrep -f "$marker" 2>/dev/null | head -1)
  done
  [ -n "$pid" ] || { echo "no process carrying $marker ever appeared" >&2; return 2; }
  p=$pid
  while [ -n "$p" ] && [ "$p" != "1" ]; do
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    [ "$p" = "$$" ] && { under=0; break; }
  done
  kill "$pid" 2>/dev/null
  [ "$under" = 1 ]
}

if [ "${1:-}" = "--selftest" ]; then
  m="rhizo-probe-attached-$$"
  launch_attached "$m"
  if marked_is_detached "$m"; then
    echo "selftest FAIL: an attached launch was reported as detached" >&2
    exit 1
  fi
  m="rhizo-probe-detached-$$"
  launch_detached "$m"
  if ! marked_is_detached "$m"; then
    echo "selftest FAIL: a detached launch was reported as attached" >&2
    exit 1
  fi
  exit 0
fi

COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../vm" && pwd)/common.sh"
if ! grep -qF 'setsid --fork "$_VM_COMMON_DIR/run-vm.sh"' "$COMMON"; then
  echo "boot_vm no longer launches with 'setsid --fork'" >&2
  echo "  in $COMMON" >&2
  exit 1
fi
m="rhizo-probe-boot-$$"
launch_detached "$m"
if ! marked_is_detached "$m"; then
  echo "a boot_vm-style launch left its process in this shell's tree" >&2
  exit 1
fi
exit 0
