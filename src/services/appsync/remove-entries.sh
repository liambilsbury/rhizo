#!/bin/dash
# launcher entry removal for uninstalled packages
set -u
APPSYNC=${RHIZO_PRUNE_APPSYNC:-/usr/lib/rhizo/tools/appsync.py}
TRIGGER=${RHIZO_RESYNC_TRIGGER:-/run/rhizo-app-events/trigger}
SYNCED=${RHIZO_PRUNE_SYNCED:-/run/rhizo-remove-entries/synced}
# print the first line of $TRIGGER, or none
trigger_now() {
  _tn=""
  { IFS= read -r _tn < "$TRIGGER"; } 2>/dev/null || true
  echo "${_tn:-none}"
}
# write $1 to $SYNCED
stamp() {
  { printf '%s\n' "$1" > "$SYNCED.tmp" && mv -f "$SYNCED.tmp" "$SYNCED"; } 2>/dev/null && return 0
  echo "[rhizo-remove-entries] failed to write '$1' to $SYNCED" >&2
  exit 1
}
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
INIT=$(stack_init_pid)
if [ -z "$INIT" ]; then
  echo "[rhizo-remove-entries] no init second_stage process"
  stamp "nosandbox trigger=$(trigger_now)"
  exit 0
fi
for pass in 1 2 3 4 5 6; do
  before=$(trigger_now)
  rc=0
  python3 "$APPSYNC" --local --reconcile-only "$INIT" || rc=$?
  now_init=$(stack_init_pid)
  if [ "$now_init" != "$INIT" ]; then
    echo "[rhizo-remove-entries] stack_init_pid printed ${now_init:-none}, not $INIT"
    INIT=$now_init
    [ -n "$INIT" ] || { stamp "nosandbox trigger=$(trigger_now)"; exit 0; }
    continue
  fi
  if [ "$(trigger_now)" = "$before" ]; then
    [ "$rc" -eq 0 ] || exit 1
    stamp "init=$INIT trigger=$before"
    exit 0
  fi
  echo "[rhizo-remove-entries] $TRIGGER changed during pass $pass"
done
echo "[rhizo-remove-entries] $TRIGGER changed in each of 6 passes" >&2
exit 1
