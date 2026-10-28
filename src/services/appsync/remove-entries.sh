#!/bin/dash
# remove launcher entries of uninstalled packages
set -u
APPSYNC=${RHIZO_PRUNE_APPSYNC:-/usr/lib/rhizo/tools/appsync.py}
TRIGGER=${RHIZO_RESYNC_TRIGGER:-/run/rhizo-app-events/trigger}
SYNCED=${RHIZO_PRUNE_SYNCED:-/run/rhizo-remove-entries/synced}
# print the trigger value, or none when it cannot be read
trigger_now() {
  _tn=""
  { IFS= read -r _tn < "$TRIGGER"; } 2>/dev/null || true
  echo "${_tn:-none}"
}
# write the line to the synced file
stamp() {
  { printf '%s\n' "$1" > "$SYNCED.tmp" && mv -f "$SYNCED.tmp" "$SYNCED"; } 2>/dev/null && return 0
  echo "[rhizo-remove-entries] could not record '$1' in $SYNCED" >&2
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
  echo "[rhizo-remove-entries] no init second_stage -- nothing to reconcile against"
  stamp "nosandbox trigger=$(trigger_now)"
  exit 0
fi
for pass in 1 2 3 4 5 6; do
  before=$(trigger_now)
  rc=0
  python3 "$APPSYNC" --local --reconcile-only "$INIT" || rc=$?
  now_init=$(stack_init_pid)
  if [ "$now_init" != "$INIT" ]; then
    echo "[rhizo-remove-entries] init $INIT is no longer the sandbox's (now ${now_init:-none}); reconciling again"
    INIT=$now_init
    [ -n "$INIT" ] || { stamp "nosandbox trigger=$(trigger_now)"; exit 0; }
    continue
  fi
  if [ "$(trigger_now)" = "$before" ]; then
    [ "$rc" -eq 0 ] || exit 1
    stamp "init=$INIT trigger=$before"
    exit 0
  fi
  echo "[rhizo-remove-entries] /data/app changed during pass $pass; reconciling again"
done
echo "[rhizo-remove-entries] /data/app still changing after 6 passes" >&2
exit 1
