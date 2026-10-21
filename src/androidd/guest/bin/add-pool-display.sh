#!/system/bin/sh
# add and enable a spare pool display
export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH

W="$1"
H="$2"

CTL=/data/rhizo_control/control
CTLOUT=/data/rhizo_control/control.out

POLL_TICK_S=0.05
POLL_FAST_TICK_S=0.01
ADD_FAST_ITERS=100
ADD_ITERS=580
ID_RESOLVE_FAST_ITERS=100
ID_RESOLVE_ITERS=180
POWER_CONFIRM_FAST_ITERS=100
POWER_CONFIRM_ITERS=100

# sleep the fast or slow poll tick
poll_sleep() {
  if [ "$1" -lt "$2" ]; then sleep "$POLL_FAST_TICK_S"; else sleep "$POLL_TICK_S"; fi
}

before=$(toybox grep -c 'display pooled id=' "$CTLOUT" 2>/dev/null); before=${before:-0}
refused_before=$(toybox grep -c 'display add-failed' "$CTLOUT" 2>/dev/null); refused_before=${refused_before:-0}
echo display pool-add "$W" "$H" > "$CTL"
newid=""
newport=""
i=0
while [ "$i" -lt $((ADD_FAST_ITERS + ADD_ITERS)) ]; do
  after=$(toybox grep -c 'display pooled id=' "$CTLOUT" 2>/dev/null); after=${after:-0}
  if [ "$after" -gt "$before" ]; then
    reply=$(toybox grep -n 'display pooled id=' "$CTLOUT" | tail -1)
    reply_lineno=${reply%%:*}
    reply=${reply#*:}
    newid=$(printf '%s\n' "$reply" | grep -o 'id=[0-9]*' | head -1 | cut -d= -f2)
    newport=$(printf '%s\n' "$reply" | grep -o 'port=[0-9]*' | head -1 | cut -d= -f2)
    [ -n "$newid" ] && break
  fi
  refused_now=$(toybox grep -c 'display add-failed' "$CTLOUT" 2>/dev/null); refused_now=${refused_now:-0}
  if [ "$refused_now" -gt "$refused_before" ]; then
    echo "stage=fail reason=display-add-refused-no-free-port"
    exit 1
  fi
  poll_sleep "$i" "$ADD_FAST_ITERS"
  i=$((i + 1))
done
if [ -z "$newid" ]; then echo "stage=fail reason=pool-timeout"; exit 1; fi
if [ -z "$newport" ]; then echo "stage=fail reason=control-reply-missing-port reply=$reply"; exit 1; fi
case "$reply_lineno" in
  ''|*[!0-9]*) echo "stage=fail reason=control-reply-missing-lineno reply=$reply"; exit 1 ;;
esac

logid=""
i=0
while [ "$i" -lt $((ID_RESOLVE_FAST_ITERS + ID_RESOLVE_ITERS)) ]; do
  logid=$(dumpsys display 2>/dev/null | awk -v want="physicalPort=$newport," '
    /mViewports=/ {
      n = split($0, rec, /DisplayViewport\{/)
      for (r = 1; r <= n; r++) {
        if (index(rec[r], want) && match(rec[r], /displayId=[0-9]+/)) {
          print substr(rec[r], RSTART + 10, RLENGTH - 10)
          exit
        }
      }
    }')
  [ -n "$logid" ] && break
  poll_sleep "$i" "$ID_RESOLVE_FAST_ITERS"
  i=$((i + 1))
done
if [ -z "$logid" ]; then echo "stage=fail reason=id-resolve-timeout newid=$newid newport=$newport"; exit 1; fi

power=$(dumpsys power 2>/dev/null)
awake=$(printf '%s\n' "$power" | grep -o 'mWakefulness=[A-Za-z]*' | head -1)
if [ "$awake" = "mWakefulness=Awake" ]; then
  echo "stage=wake awake=was-Awake"
else
  input keyevent 224
  echo "stage=wake awake=woke"
fi
cmd display enable-display "$logid"

committed=timeout
i=0
waited_ms=0
while [ "$i" -lt $((POWER_CONFIRM_FAST_ITERS + POWER_CONFIRM_ITERS)) ]; do
  powered_now=$(awk -v want="display powered id=$newid port=$newport" -v from="$reply_lineno" \
    'NR > from && index($0, want) { n = 1; exit } END { print n + 0 }' "$CTLOUT" 2>/dev/null)
  if [ "${powered_now:-0}" -gt 0 ]; then committed=ON; break; fi
  poll_sleep "$i" "$POWER_CONFIRM_FAST_ITERS"
  i=$((i + 1))
  if [ "$i" -le "$POWER_CONFIRM_FAST_ITERS" ]; then waited_ms=$((waited_ms + 10)); else waited_ms=$((waited_ms + 50)); fi
  if [ $((waited_ms % 2000)) -eq 0 ]; then
    cmd display enable-display "$logid"
  fi
done
if [ "$committed" != ON ]; then
  echo display remove "$newid" > "$CTL"
  echo "stage=fail reason=power-confirm-timeout id=$newid logid=$logid port=$newport removed=1"
  exit 1
fi

( sh /system_ext/bin/rhizo-layerstack-guard.sh "$logid" "$newid" pool ) >/dev/null 2>&1 &

echo "stage=done id=$newid logid=$logid port=$newport w=$W h=$H"
