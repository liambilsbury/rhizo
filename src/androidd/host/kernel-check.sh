#!/bin/sh
# running kernel check for built-in binder, ashmem and /proc/config.gz
set -u

PROG=rhizo-kernel-check
DEVICES_FILE="${RHIZO_BINDER_DEVICES_FILE:-/sys/module/binder/parameters/devices}"
ASHMEM="${RHIZO_ASHMEM_DEVICE:-/dev/ashmem}"
PROC_CONFIG="${RHIZO_PROC_CONFIG:-/proc/config.gz}"
lacks=""
[ -e "$DEVICES_FILE" ] || lacks="built-in binder"
[ -c "$ASHMEM" ] || lacks="${lacks:+$lacks, }$ASHMEM"
[ -e "$PROC_CONFIG" ] || lacks="${lacks:+$lacks, }$PROC_CONFIG"
if [ -n "$lacks" ]; then
  echo "[$PROG] $(uname -r) has no $lacks" >&2
  exit 1
fi
if ! devices=$(cat "$DEVICES_FILE"); then
  echo "[$PROG] failed to read $DEVICES_FILE" >&2
  exit 1
fi
if [ "$devices" != "binder,hwbinder,vndbinder" ]; then
  echo "[$PROG] $DEVICES_FILE is '$devices', expected binder,hwbinder,vndbinder" >&2
  exit 1
fi
exit 0
