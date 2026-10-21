#!/bin/sh
# sync launcher entries with appsync.py
set -eu

_here=$(dirname "$0")
# print the pid of the sandbox init
stack_init_pid() {
  _sip_pid=""
  for _sip_d in "${RHIZO_PROC_ROOT:-/proc}"/[0-9]*; do
    case "$(tr '\0' ' ' 2>/dev/null < "$_sip_d/cmdline")" in *"init second_stage"*) ;; *) continue ;; esac
    case "$(sed -n 's|^0::||p' "$_sip_d/cgroup" 2>/dev/null)" in
      /rhizo/*|/system.slice/androidd.service/android/*)
        [ -z "$_sip_pid" ] || [ "${_sip_d##*/}" -lt "$_sip_pid" ] && _sip_pid=${_sip_d##*/} ;;
    esac
  done
  [ -z "$_sip_pid" ] || echo "$_sip_pid"
}
TRIGGER=${RHIZO_RESYNC_TRIGGER:-/run/rhizo-app-events/trigger}
SYNCED=${RHIZO_RESYNC_SYNCED:-/run/rhizo-resync/synced}
# print the trigger value, or none when it cannot be read
trigger_now() {
  _tn=""
  { IFS= read -r _tn < "$TRIGGER"; } 2>/dev/null || true
  echo "${_tn:-none}"
}
# write the line to the synced file
stamp() {
  { printf '%s\n' "$1" > "$SYNCED.tmp" && mv -f "$SYNCED.tmp" "$SYNCED"; } 2>/dev/null && return 0
  echo "[rhizo-resync] could not record '$1' in $SYNCED" >&2
  exit 1
}

# wait for the sandbox's sys.boot_completed
wait_for_boot() {
  AWAIT="$_here/../install/prepare/await-boot-completed.py"
  [ -r "$AWAIT" ] || AWAIT="$_here/../../install/prepare/await-boot-completed.py"
  [ -r "$AWAIT" ] || { echo "[rhizo-resync] no $AWAIT to wait for the sandbox's boot with" >&2; exit 1; }
  python3 "$AWAIT" --instance 0 --timeout 900 \
    || { echo "[rhizo-resync] the sandbox's boot did not complete; nothing synced" >&2; exit 1; }
}
# wait for the sandbox boot to finish
wait_for_init() {
  systemctl is-active --quiet androidd.service || { stamp "nosandbox trigger=$(trigger_now)"; exit 0; }
  wait_for_boot
  INIT=$(stack_init_pid)
  [ -n "$INIT" ] || { stamp "nosandbox trigger=$(trigger_now)"; exit 0; }
}
INIT=$(stack_init_pid)
if [ -z "$INIT" ]; then
  wait_for_init
else
  wait_for_boot
fi

APPSYNC="$_here/appsync.py"
[ -r "$APPSYNC" ] || { echo "[rhizo-resync] no appsync.py beside $_here" >&2; exit 1; }
[ -e /root/appsync.py ] && \
  echo "[rhizo-resync] ignoring the leftover /root/appsync.py -- $APPSYNC is the deployed one" >&2

QUEUE=/run/rhizo-app-events/queue
QUEUE_STATE=/run/rhizo-resync/queue.offset

for pass in 1 2 3 4 5 6; do
  drain_rc=0
  before=$(trigger_now)
  python3 "$APPSYNC" --local --reconcile-only "$INIT" || true
  python3 "$APPSYNC" --local "$INIT" &
  full=$!
  python3 "$APPSYNC" --local --drain-queue "$QUEUE" --queue-state "$QUEUE_STATE" --while-pid "$full" "$INIT" \
    || { drain_rc=$?; echo "[rhizo-resync] the queue drain exited $drain_rc; the full pass still syncs every package" >&2; }
  full_rc=0
  wait "$full" || full_rc=$?
  after=$(trigger_now)
  now_init=$(stack_init_pid)
  if [ "$now_init" != "$INIT" ]; then
    echo "[rhizo-resync] init $INIT is no longer the sandbox's (now ${now_init:-none}); syncing again"
    INIT=$now_init
    [ -n "$INIT" ] || wait_for_init
    continue
  fi
  if [ "$before" = "$after" ]; then
    [ "$full_rc" -eq 0 ] || exit "$full_rc"
    [ "$drain_rc" -eq 0 ] || exit 1
    stamp "init=$INIT trigger=$after"
    echo "[rhizo-resync] synced init $INIT"
    exit 0
  fi
  echo "[rhizo-resync] /data/app changed during pass $pass; syncing again"
done
echo "[rhizo-resync] /data/app still changing after 6 passes" >&2
exit 1
