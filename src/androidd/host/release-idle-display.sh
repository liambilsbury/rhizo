#!/bin/sh
# release the idle spare display
set -eu

MARK='RHIZO_MARKER pool_idle_armed release_at='
PROBE_SOCK=/run/rhizo/data/local/tmp/rhizo-probe.sock
PROBE_CLIENT=""
for _pc in /root/share/rhizo-probe-client "$(dirname "$0")/rhizo-probe-client"; do
  [ -x "$_pc" ] && { PROBE_CLIENT="$_pc"; break; }
done
[ -n "$PROBE_CLIENT" ] || { logger -t rhizo-display-pool-release "no rhizo-probe-client in /root/share or $(dirname "$0") -- refusing to watch"; exit 1; }
HOSTOPS=""
for _h in "$(dirname "$0")/hostops.py" /usr/lib/rhizo/hostops.py; do
  [ -s "$_h" ] && { HOSTOPS="$_h"; break; }
done
[ -n "$HOSTOPS" ] || { logger -t rhizo-display-pool-release "no hostops.py beside $0 or in /usr/lib/rhizo -- refusing to watch"; exit 1; }
for _dl_lib in /root/rhizo-display-list.sh /root/share/rhizo-display-list.sh "$(dirname "$0")/tools/rhizo-display-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_dl_lib" ] && { . "$_dl_lib"; break; }
done
command -v rhizo_dl_spares >/dev/null 2>&1 || { logger -t rhizo-display-pool-release "no rhizo-display-list.sh in $(dirname "$0")/tools or /root -- refusing to read the pool"; exit 1; }
DEADLINE_FILE=/run/rhizo-display-pool-release.deadline

# send a shell command to rhizo-probed
probe() {
  "$PROBE_CLIENT" "$PROBE_SOCK" "$1" \
    "export PATH=/system/bin:/system/xbin:/vendor/bin; $2" 2>/dev/null || true
}

# release the unclaimed spare display
release_one() {
  now=$(date +%s)
  wait_s=$(( $1 - now ))
  [ "$wait_s" -gt 0 ] && sleep "$wait_s"
  [ "$(cat "$DEADLINE_FILE" 2>/dev/null || true)" = "$1" ] || return 0

  before=$(probe 5 'toybox grep -c "^display list" /data/rhizo_control/control.out 2>/dev/null'); before=${before:-0}
  probe 5 'echo display list > /data/rhizo_control/control' >/dev/null
  dlist=""
  j=0
  while [ "$j" -lt 20 ]; do
    after=$(probe 5 'toybox grep -c "^display list" /data/rhizo_control/control.out 2>/dev/null'); after=${after:-0}
    if [ "$after" -gt "$before" ] 2>/dev/null; then
      dlist=$(probe 5 'toybox grep "^display list" /data/rhizo_control/control.out | tail -1')
      break
    fi
    sleep 1
    j=$((j + 1))
  done

  claimed_apps=$(rhizo_dl_claimed "$dlist" | grep -vc '^1$' || true)
  [ "${claimed_apps:-0}" -eq 0 ] || return 0

  spare_id=$(rhizo_dl_spares "$dlist" | head -1)
  [ -n "$spare_id" ] || return 0

  rm -f /run/rhizo-display-pool/ready

  probe 5 "echo display release-spare $spare_id > /data/rhizo_control/control" >/dev/null
}

python3 "$HOSTOPS" kmsg-follow | while IFS= read -r line; do
  case "$line" in
    *"$MARK"*)
      release_at=$(printf '%s\n' "$line" | sed -n "s/.*${MARK}\\([0-9]*\\).*/\\1/p")
      [ -n "$release_at" ] || continue
      printf '%s\n' "$release_at" > "$DEADLINE_FILE"
      release_one "$release_at" &
      ;;
  esac
done
