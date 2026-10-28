#!/bin/sh
# write the kernel log to a rotating file
set -u
LOG="${1:?usage: rhizo-avc-capture.sh <logfile>}"
exec 9<"$(dirname "$LOG")"
flock -n 9 || exit 0
CAP="${RHIZO_AVC_CAP_BYTES:-268435456}"
EVERY="${RHIZO_AVC_CHECK_LINES:-2000}"

rm -f "$LOG.1"
: > "$LOG"
n=0
dmesg -w 2>&1 | while IFS= read -r line; do
  printf '%s\n' "$line" >> "$LOG"
  n=$((n + 1))
  if [ "$n" -ge "$EVERY" ]; then
    n=0
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    if [ "$sz" -gt "$CAP" ]; then
      mv -f "$LOG" "$LOG.1" 2>/dev/null || : > "$LOG"
      : > "$LOG"
    fi
  fi
done
