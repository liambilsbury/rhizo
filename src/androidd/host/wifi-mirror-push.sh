#!/bin/sh
# push netbridged's SSID to RhizoNetwork as a network suggestion
set -eu
export LC_ALL=C

TAG=rhizo-wifi-mirror-push
STATE="${1:?usage: rhizo-wifi-mirror-push STATE_FILE [PROBE_SOCK]}"
SANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"
case "$SANDBOX_ID" in ''|*[!0-9]*) echo "$TAG: RHIZO_SANDBOX_ID '$SANDBOX_ID' is not a number" >&2; exit 2 ;; esac
RUN_ROOT=/run/rhizo
RECORD=/run/rhizo-wifi-mirror-push
if [ "$SANDBOX_ID" != 0 ]; then
  RUN_ROOT="$RUN_ROOT-$SANDBOX_ID"
  RECORD="$RECORD-$SANDBOX_ID"
fi
PROBE_SOCK="${2:-$RUN_ROOT/data/local/tmp/rhizo-probe.sock}"
TRIES=5
ROUNDS=4
TIMEOUT_S="${RHIZO_WIFI_PUSH_TIMEOUT_S:-900}"
case "$TIMEOUT_S" in ''|*[!0-9]*) TIMEOUT_S=900 ;; esac
[ "$TIMEOUT_S" -le 3600 ] || TIMEOUT_S=3600
BOOT_WAIT_S=$((TIMEOUT_S - TRIES * 33 - 15))
[ "$BOOT_WAIT_S" -ge 60 ] || BOOT_WAIT_S=60
DEBUG="${RHIZO_WIFI_MIRROR_DEBUG:-0}"

_here=$(dirname "$(readlink -f "$0")")
PROBE_CLIENT=""
for _pc in "$_here/rhizo-probe-client" /root/share/rhizo-probe-client; do
  [ -x "$_pc" ] && { PROBE_CLIENT="$_pc"; break; }
done
[ -n "$PROBE_CLIENT" ] || { echo "$TAG: no rhizo-probe-client beside $0 or in /root/share" >&2; exit 1; }

# write a line to the log
log() {
  echo "$TAG: $*" >&2
}

# run a command in android as shell
probe() {
  "$PROBE_CLIENT" "$PROBE_SOCK" "$1" "export PATH=/system/bin:/system/xbin:/vendor/bin; $2"
}

# return whether the argument is a non-empty run of digits
is_num() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

# print the state file's seq and hex
read_state() {
  [ -f "$STATE" ] && [ ! -L "$STATE" ] || return 1
  _line=$(head -c 160 "$STATE" | head -n 1) || return 1
  case "$_line" in *" "*) ;; *) return 1 ;; esac
  _seq=${_line%% *}
  _hex=${_line#* }
  is_num "$_seq" || return 1
  case "$_hex" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#_seq}" -le 10 ] && [ "${#_hex}" -le 64 ] && [ $(( ${#_hex} % 2 )) -eq 0 ] || return 1
  echo "$_seq $_hex"
}

# wait for boot and print system_server's start count and time
wait_boot() {
  _deadline=$(( $(date +%s) + BOOT_WAIT_S ))
  while :; do
    _out=$(probe 5 'getprop sys.boot_completed; getprop sys.system_server.start_count; getprop sys.system_server.start_elapsed' 2>/dev/null) || _out=""
    _done=$(printf '%s\n' "$_out" | sed -n 1p)
    _count=$(printf '%s\n' "$_out" | sed -n 2p)
    _since=$(printf '%s\n' "$_out" | sed -n 3p)
    if [ "$_done" = 1 ] && is_num "$_count" && is_num "$_since"; then
      echo "$_count:$_since"
      return 0
    fi
    [ "$(date +%s)" -lt "$_deadline" ] || return 1
    sleep 2
  done
}

# broadcast the SSID until the app applies the suggestion
push() {
  _pseq=$1 _phex=$2
  _extra="" _shown=""
  if [ "$DEBUG" = 1 ]; then
    _extra=" --ez debug true"
    _shown=" ssid_hex=$_phex"
  fi
  _try=1
  while [ "$_try" -le "$TRIES" ]; do
    _rc=0
    _out=$(probe 30 "am broadcast --receiver-foreground --include-stopped-packages -n com.rhizo.network/.Mirror --es ssid_hex $_phex$_extra" 2>&1) || _rc=$?
    _line=$(printf '%s\n' "$_out" | grep -m1 '^Broadcast completed: result=' || true)
    _result=$(printf '%s\n' "$_line" | sed -n 's/^Broadcast completed: result=\(-\{0,1\}[0-9]*\).*/\1/p')
    _data=$(printf '%s\n' "$_line" | sed -n 's/.*, data="\([^"]*\)".*/\1/p')
    case "$_result" in
      -1)
        log "push seq=$_pseq attempt=$_try/$TRIES result=applied ($_data)$_shown"
        return 0 ;;
      1|2)
        log "push seq=$_pseq attempt=$_try/$TRIES result=refused code=$_result ($_data) -- not retried$_shown"
        return 1 ;;
      "")
        _why=$(printf '%s\n' "$_out" | grep -m1 -o 'RHIZO_PROBE_[A-Z_]*' || true)
        log "push seq=$_pseq attempt=$_try/$TRIES result=no-reply probe_rc=$_rc ${_why:-no-broadcast-result}" ;;
      0)
        log "push seq=$_pseq attempt=$_try/$TRIES result=not-received code=0 (no receiver ran)" ;;
      *)
        log "push seq=$_pseq attempt=$_try/$TRIES result=failed code=$_result ($_data)" ;;
    esac
    _try=$((_try + 1))
    if [ "$_try" -le "$TRIES" ]; then sleep 3; fi
  done
  return 1
}

exec 9>"$RECORD.lock"
flock 9

# print the state file's modification time
stamp() {
  stat -c %y "$STATE" 2>/dev/null | tr ' ' _
}

stamp=$(stamp)
state=$(read_state) || { log "no well-formed state in $STATE -- nothing pushed"; exit 0; }
boot=$(wait_boot) || { log "android did not reach sys.boot_completed=1 within ${BOOT_WAIT_S}s -- nothing pushed"; exit 1; }
round=1
last=0
while :; do
  seq=${state%% *}
  hex=${state#* }
  if [ "$(cat "$RECORD.last" 2>/dev/null || true)" = "$boot $seq $stamp" ]; then
    log "seq=$seq at $stamp already pushed to this android boot"
  else
    push "$seq" "$hex" || { log "seq=$seq FAILED: the suggestion was not applied"; exit 1; }
    printf '%s\n' "$boot $seq $stamp" > "$RECORD.last"
  fi
  [ "$last" = 0 ] || exit 0
  stamp=$(stamp)
  next=$(read_state) || exit 0
  [ "$next" != "$state" ] || exit 0
  round=$((round + 1))
  if [ "$round" -ge "$ROUNDS" ]; then
    log "the state kept changing over $ROUNDS rounds -- pushing the newest and stopping"
    last=1
  fi
  state=$next
done
