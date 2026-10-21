#!/bin/sh
# create a spare pooled display
set -eu

POOL_DIR=/run/rhizo-display-pool
READY="$POOL_DIR/ready"
CONSUMED="$POOL_DIR/consumed"
DISP_W=960
DISP_H=1080

boot_prime=""
[ -e "$READY" ] || [ -e "$CONSUMED" ] || boot_prime=1

claiming_id=""
[ -e "$CONSUMED" ] && claiming_id=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' "$CONSUMED" 2>/dev/null || true)

rm -f "$CONSUMED" 2>/dev/null || true

# print the pid of instance 0's init
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
INIT=""
_init_wait_i=0
while [ "$_init_wait_i" -lt 20 ]; do
  INIT=$(stack_init_pid)
  [ -n "$INIT" ] && break
  sleep 1
  _init_wait_i=$((_init_wait_i + 1))
done
[ -n "$INIT" ] || exit 0

_here=$(dirname "$0")
for _unfreeze_lib in /root/rhizo-cgroup-unfreeze.sh /root/share/rhizo-cgroup-unfreeze.sh "$_here/tools/rhizo-cgroup-unfreeze.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_unfreeze_lib" ] && { . "$_unfreeze_lib"; break; }
done
for _dl_lib in /root/rhizo-display-list.sh /root/share/rhizo-display-list.sh "$_here/tools/rhizo-display-list.sh"; do
  # shellcheck source=/dev/null
  [ -r "$_dl_lib" ] && { . "$_dl_lib"; break; }
done
command -v rhizo_dl_spares >/dev/null 2>&1 || { logger -t rhizo-display-pool "no rhizo-display-list.sh beside $0 -- refusing to read the pool"; exit 1; }
_cg=$(rhizo_stack_cgroup "$INIT") || exit 0
rhizo_stack_frozen "$_cg" && exit 0

PROBE_SOCK=/run/rhizo/data/local/tmp/rhizo-probe.sock
PROBE_CLIENT=""
for _pc in /root/share/rhizo-probe-client "$_here/rhizo-probe-client" "$_here/probe-client.py"; do
  [ -r "$_pc" ] && { PROBE_CLIENT="$_pc"; break; }
done
[ -n "$PROBE_CLIENT" ] || { echo "rhizo-display-pool: no probe client beside $_here or in /root/share" >&2; exit 1; }

# send a shell command to rhizo-probed
probe() {
  "$PROBE_CLIENT" "$PROBE_SOCK" "$1" \
    "export PATH=/system/bin:/system/xbin:/vendor/bin; $2" 2>/dev/null || true
}

BOOT_WAIT_ITERS=60
i=0
bc=""
while [ "$i" -lt "$BOOT_WAIT_ITERS" ]; do
  bc=$(probe 5 'getprop sys.boot_completed')
  [ "$bc" = "1" ] && break
  sleep 1
  i=$((i + 1))
done
[ "$bc" = "1" ] || exit 0

before_n=$(probe 5 'toybox grep -c "^display list" /data/rhizo_control/control.out 2>/dev/null'); before_n=${before_n:-0}
probe 5 'echo display list > /data/rhizo_control/control' >/dev/null
dlist=""
j=0
while [ "$j" -lt 20 ]; do
  after_n=$(probe 5 'toybox grep -c "^display list" /data/rhizo_control/control.out 2>/dev/null'); after_n=${after_n:-0}
  if [ "$after_n" -gt "$before_n" ] 2>/dev/null; then
    dlist=$(probe 5 'toybox grep "^display list" /data/rhizo_control/control.out | tail -1')
    break
  fi
  sleep 1
  j=$((j + 1))
done
dlist_eff="$dlist"
if [ -n "$claiming_id" ]; then
  dlist_eff=$(printf '%s\n' "$dlist" | sed "s/ ${claiming_id}([^)]*)//g")
fi
if [ -e "$READY" ] && [ -n "$dlist" ]; then
  ready_id=$(sed -n 's/.* id=\([0-9]*\).*/\1/p' "$READY" 2>/dev/null || true)
  if [ -z "$ready_id" ] || ! rhizo_dl_spares "$dlist_eff" | grep -qx "$ready_id"; then
    logger -t rhizo-display-pool "ready names spare ${ready_id:-?}, which is not live -- discarding it"
    rm -f "$READY"
    boot_prime=1
  fi
fi
already_spare=$(rhizo_dl_spares "$dlist_eff" | grep -c . || true)
if [ "${already_spare:-0}" -gt 0 ]; then
  [ -e "$READY" ] && exit 0
  for spare in $(rhizo_dl_spares "$dlist_eff"); do
    logger -t rhizo-display-pool "removing spare $spare: no ready file names it"
    probe 5 "echo display remove $spare > /data/rhizo_control/control" >/dev/null
  done
fi

[ -z "$claiming_id" ] || boot_prime=1

if [ -z "$boot_prime" ]; then
  live=$(rhizo_dl_claimed "$dlist" | grep -vc '^1$' || true)
  [ "${live:-0}" -gt 0 ] || exit 0
fi

QUIET_S=3
QUIET_MAX=60
# print a checksum of the app process directories
app_procs() { find "$_cg/apps" "$_cg/system" -mindepth 2 -maxdepth 2 -name 'pid_*' 2>/dev/null | sort | cksum; }
q_last=$(app_procs)
q_same=0
q_waited=0
while [ "$q_same" -lt "$QUIET_S" ] && [ "$q_waited" -lt "$QUIET_MAX" ]; do
  sleep 1
  q_waited=$((q_waited + 1))
  q_now=$(app_procs)
  if [ "$q_now" = "$q_last" ]; then q_same=$((q_same + 1)); else q_same=0; q_last=$q_now; fi
done
[ "$q_same" -ge "$QUIET_S" ] \
  || logger -t rhizo-display-pool "app processes were still starting after ${QUIET_MAX}s; hotplugging the spare now"
out=$(probe 30 "sh /system_ext/bin/rhizo-add-pool-display.sh $DISP_W $DISP_H")
logger -t rhizo-display-pool "guest: $(printf '%s' "$out" | tr '\n' ' ')"

case "$out" in
  *'reason=display-add-refused-no-free-port'*) exit 0 ;;
  *'stage=done '*) ;;
  *) exit 0 ;;
esac

done_line=$(printf '%s\n' "$out" | grep '^stage=done ' | tail -1)
newid=$(printf '%s\n' "$done_line" | sed -n 's/.*\bid=\([0-9]*\).*/\1/p')
logid=$(printf '%s\n' "$done_line" | sed -n 's/.*logid=\([0-9]*\).*/\1/p')
port=$(printf '%s\n' "$done_line" | sed -n 's/.*port=\([0-9]*\).*/\1/p')
[ -n "$newid" ] && [ -n "$logid" ] && [ -n "$port" ] || exit 0

tmp=$(mktemp -p "$POOL_DIR" ready.XXXXXX)
printf 'logid=%s id=%s port=%s w=%s h=%s\n' "$logid" "$newid" "$port" "$DISP_W" "$DISP_H" > "$tmp"
mv "$tmp" "$READY"
