#!/system/bin/sh
# run an app launch inside the sandbox shell
export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH

# return 0 when the display holds an activity of the package
on_display_now() {
  cmd display get-displays -i 2>/dev/null | toybox grep -qx "$2" || return 1
  dumpsys activity activities 2>/dev/null | awk -v want="Display #$2 " -v pkg=" $1/" '
    /Display #/ { if (inseg) exit; inseg = index($0, want) > 0; next }
    inseg && (/^[^ ]/ || /^ *ResumedActivity: / || /Resumed activities/) { exit }
    inseg && index($0, pkg) { found = 1; exit }
    END { exit !found }'
}

PKG="$1"
ACT="$2"
W="$3"
H="$4"
BUS="$5"
MAP_B64="$6"
REUSE_LOGID="$7"
POOL_LOGID="$8"
POOL_DISPLAY_ID="$9"
IDENT_APPID_B64="${10}"
IDENT_TITLE_B64="${11}"
VIEW_URI=$(echo "${12}" | toybox base64 -d)
VIEW_MIME=$(echo "${13}" | toybox base64 -d)
ON_TOP_DEADLINE="${14}"
ACTIVATION_TOKEN="${15}"
REUSE_CID="${16}"
cid=""

# write the toplevel identity to the control channel
set_toplevel_identity() {
  [ -n "$1" ] || return 0
  [ -n "$IDENT_APPID_B64" ] || return 0
  echo display identity "$1" "$IDENT_APPID_B64" "$IDENT_TITLE_B64" > "$CTL"
}

# stamp the first presented app frame on this display
arm_first_present() {
  [ -n "$1" ] || return 0
  echo display arm-first-present "$1" > "$CTL"
}

CTL=/data/rhizo_control/control
CTLOUT=/data/rhizo_control/control.out
ROUTER_DIR=/data/rhizo_audio_map

POLL_TICK_S=0.05
POLL_FAST_TICK_S=0.01
AUDIO_CONFIRM_FAST_ITERS=50
AUDIO_CONFIRM_ITERS=30
DISPLAY_ADD_FAST_ITERS=100
DISPLAY_ADD_ITERS=580
ID_RESOLVE_FAST_ITERS=100
ID_RESOLVE_ITERS=180
POWER_CONFIRM_FAST_ITERS=100
POWER_CONFIRM_ITERS=100
# shellcheck disable=SC2034
{
AUDIO_CONFIRM_CEILING_S=2
DISPLAY_ADD_CEILING_S=30
ID_RESOLVE_CEILING_S=10
POWER_CONFIRM_CEILING_S=6
}
POWER_CONFIRM_REISSUE_MS=2000

CLAIM_FAST_ITERS=50
CLAIM_ITERS=30
# shellcheck disable=SC2034
CLAIM_CEILING_S=2

POLL_LAST_TICK_MS=0
# sleep the fast or slow poll tick
poll_sleep() {
  if [ "$1" -lt "$2" ]; then
    POLL_LAST_TICK_MS=10
    sleep "$POLL_FAST_TICK_S"
  else
    POLL_LAST_TICK_MS=50
    sleep "$POLL_TICK_S"
  fi
}

# return 0 when the display's top task names the package
on_top_now() {
  dumpsys activity activities 2>/dev/null | awk -v want="Display #$1 " -v pkg=" $PKG/" '
    /Display #/ { if (inseg) exit; inseg = index($0, want) > 0; ti = 0; next }
    inseg && (/^[^ ]/ || /^ *ResumedActivity: / || /Resumed activities/) { exit }
    inseg && /\* Task[{]/ { i = match($0, /[^ ]/); if (ti && i <= ti) exit; if (!ti) ti = i; next }
    inseg && /topResumedActivity=/ { found = index($0, pkg) > 0 || index($0, "permissioncontroller/") > 0; exit }
    END { exit !found }'
}

# wait for the app to top the display
await_on_top() {
  case "$AM_OUT" in
    *"Error:"*|*"Exception occurred"*) return 2 ;;
  esac
  _seen=""
  _i=0
  while :; do
    on_top_now "$1" && return 0
    if pidof "$PKG" >/dev/null 2>&1; then _seen=1
    elif [ -n "$_seen" ]; then return 3; fi
    [ "$(date +%s)" -lt "$2" ] || return 1
    poll_sleep "$_i" 0
    _i=$((_i + 1))
  done
}

write_ok=1
if [ -n "$BUS" ] && [ -n "$MAP_B64" ]; then
  echo "stage=audio-map-write t=$(date +%s.%N)"
  echo "$MAP_B64" | toybox base64 -d > "$ROUTER_DIR/audio_map.tmp" || write_ok=0
  toybox chmod 666 "$ROUTER_DIR/audio_map.tmp" || write_ok=0
  toybox mv "$ROUTER_DIR/audio_map.tmp" "$ROUTER_DIR/audio_map" || write_ok=0
fi

t2=$(date +%s.%N)
if [ -n "$BUS" ]; then
  if [ "$write_ok" -eq 1 ]; then
    state=""
    i=0
    while [ "$i" -lt $((AUDIO_CONFIRM_FAST_ITERS + AUDIO_CONFIRM_ITERS)) ]; do
      state=$(toybox cat "$ROUTER_DIR/audio_map.state" 2>/dev/null)
      case "$state" in
        ok*"->$BUS"*) break ;;
      esac
      state=""
      poll_sleep "$i" "$AUDIO_CONFIRM_FAST_ITERS"
      i=$((i + 1))
    done
    [ -n "$state" ] || state=timeout
  else
    state=write-failed
  fi
  echo "stage=audio-confirm t=$t2 bus=$BUS state=$state"
else
  echo "stage=audio-confirm t=$t2"
fi

t3=$(date +%s.%N)
case "$(service call power 21 2>/dev/null)" in
  *"00000000 00000001"*) awake_result=was-Awake ;;
  *"00000000 00000000"*)
    input keyevent 224
    wm dismiss-keyguard
    awake_result=woke
    ;;
  *)
    power=$(dumpsys power)
    awake=$(printf '%s\n' "$power" | grep -o 'mWakefulness=[A-Za-z]*' | head -1)
    if [ "$awake" = "mWakefulness=Awake" ]; then
      awake_result=was-Awake
    else
      input keyevent 224
      wm dismiss-keyguard
      awake_result=woke
    fi
    ;;
esac
echo "stage=wake t=$t3 awake=$awake_result"

need_display_add=1
if [ -n "$REUSE_CID" ] && ! on_display_now "$PKG" "$REUSE_LOGID"; then
  echo "stage=own-display-gone t=$(date +%s.%N) logid=$REUSE_LOGID cid=$REUSE_CID"
  REUSE_LOGID=""
  REUSE_CID=""
fi
if [ -n "$REUSE_LOGID" ]; then
  echo "stage=reuse-display t=$(date +%s.%N) logid=$REUSE_LOGID cid=$REUSE_CID"
  logid="$REUSE_LOGID"
  cid="$REUSE_CID"
  committed=skipped
  need_display_add=""
elif [ -n "$POOL_LOGID" ] && [ -n "$POOL_DISPLAY_ID" ]; then
  t5c=$(date +%s.%N)
  claimed_before=$(toybox grep -c "display claimed id=$POOL_DISPLAY_ID" "$CTLOUT" 2>/dev/null); claimed_before=${claimed_before:-0}
  claim_failed_before=$(toybox grep -c "display claim-failed id=$POOL_DISPLAY_ID" "$CTLOUT" 2>/dev/null); claim_failed_before=${claim_failed_before:-0}
  echo display claim "$POOL_DISPLAY_ID" > "$CTL"
  claim_ok=""
  i=0
  while [ "$i" -lt $((CLAIM_FAST_ITERS + CLAIM_ITERS)) ]; do
    claimed_now=$(toybox grep -c "display claimed id=$POOL_DISPLAY_ID" "$CTLOUT" 2>/dev/null); claimed_now=${claimed_now:-0}
    if [ "$claimed_now" -gt "$claimed_before" ]; then claim_ok=1; break; fi
    claim_failed_now=$(toybox grep -c "display claim-failed id=$POOL_DISPLAY_ID" "$CTLOUT" 2>/dev/null); claim_failed_now=${claim_failed_now:-0}
    [ "$claim_failed_now" -gt "$claim_failed_before" ] && break
    poll_sleep "$i" "$CLAIM_FAST_ITERS"
    i=$((i + 1))
  done
  if [ -n "$claim_ok" ]; then
    logid="$POOL_LOGID"
    committed=ON
    need_display_add=""
    cid="$POOL_DISPLAY_ID"
    set_toplevel_identity "$cid"
    arm_first_present "$cid"
    echo "stage=pool-claim t=$t5c logid=$logid result=claimed"
  else
    echo "stage=pool-claim t=$t5c logid=$POOL_LOGID result=claim-failed"
  fi
fi
if [ -n "$need_display_add" ]; then
  t5=$(date +%s.%N)
  before=$(toybox grep -c 'display added id=' "$CTLOUT" 2>/dev/null)
  before=${before:-0}
  echo display add "$W" "$H" > "$CTL"
  newid=""
  newport=""
  i=0
  refused_before=$(toybox grep -c 'display add-failed' "$CTLOUT" 2>/dev/null)
  refused_before=${refused_before:-0}
  while [ "$i" -lt $((DISPLAY_ADD_FAST_ITERS + DISPLAY_ADD_ITERS)) ]; do
    after=$(toybox grep -c 'display added id=' "$CTLOUT" 2>/dev/null)
    after=${after:-0}
    if [ "$after" -gt "$before" ]; then
      reply=$(toybox grep -n 'display added id=' "$CTLOUT" | tail -1)
      reply_lineno=${reply%%:*}
      reply=${reply#*:}
      newid=$(printf '%s\n' "$reply" | grep -o 'id=[0-9]*' | head -1 | cut -d= -f2)
      newport=$(printf '%s\n' "$reply" | grep -o 'port=[0-9]*' | head -1 | cut -d= -f2)
      [ -n "$newid" ] && break
    fi
    refused_now=$(toybox grep -c 'display add-failed' "$CTLOUT" 2>/dev/null)
    refused_now=${refused_now:-0}
    if [ "$refused_now" -gt "$refused_before" ]; then
      echo "stage=fail t=$(date +%s.%N) reason=display-add-refused-no-free-port"
      exit 1
    fi
    poll_sleep "$i" "$DISPLAY_ADD_FAST_ITERS"
    i=$((i + 1))
  done
  if [ -z "$newid" ]; then
    echo "stage=fail t=$(date +%s.%N) reason=display-add-timeout"
    exit 1
  fi
  if [ -z "$newport" ]; then
    echo "stage=fail t=$(date +%s.%N) reason=control-reply-missing-port reply=$reply"
    exit 1
  fi
  case "$reply_lineno" in
    ''|*[!0-9]*)
      echo "stage=fail t=$(date +%s.%N) reason=control-reply-missing-lineno reply=$reply"
      exit 1 ;;
  esac
  cid="$newid"
  set_toplevel_identity "$cid"
  arm_first_present "$cid"
  echo "stage=display-add t=$t5 newid=$newid newport=$newport"

  t6=$(date +%s.%N)
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
  if [ -z "$logid" ]; then
    echo "stage=fail t=$(date +%s.%N) reason=id-resolve-timeout"
    exit 1
  fi
  echo "stage=id-resolve t=$t6 logid=$logid"

  t7=$(date +%s.%N)
  cmd display enable-display "$logid"
  ( sh /system_ext/bin/rhizo-layerstack-guard.sh "$logid" "$newid" launch ) >/dev/null 2>&1 &
  echo "stage=enable t=$t7"

  do_power_confirm=1
fi

t9=$(date +%s.%N)
WM=""
[ -e /vendor/etc/permissions/rhizo-freeform.xml ] && WM="--windowingMode 5"
if [ -n "$VIEW_URI" ] && [ -n "$VIEW_MIME" ]; then
  AM_OUT=$(am start $WM --display "$logid" -a android.intent.action.VIEW \
    -d "$VIEW_URI" -t "$VIEW_MIME" \
    -n "$PKG/$ACT" 2>&1)
elif [ -n "$VIEW_URI" ]; then
  AM_OUT=$(am start $WM --display "$logid" -a android.intent.action.VIEW \
    -c android.intent.category.BROWSABLE -d "$VIEW_URI" -n "$PKG/$ACT" 2>&1)
else
  AM_OUT=$(am start $WM --display "$logid" -n "$PKG/$ACT" 2>&1)
fi
rc=$?
echo "stage=am-start t=$t9 rc=$rc"
if [ -n "$WM" ] && [ -n "$cid" ]; then
  TM=/data/local/tmp/rhizo-tasks
  mkdir -p "$TM"
  task=$(dumpsys activity activities | awk -v d="Display #$logid " 'index($0, d) == 1 { on = 1; next }
    /^Display #/ { on = 0 }
    on && match($0, /Task\{[0-9a-f]+ #[0-9]+/) { s = substr($0, RSTART, RLENGTH); sub(/.*#/, "", s); print s; exit }')
  if [ -n "$task" ]; then
    echo "$task" > "$TM/task-$cid"
    echo "$logid" > "$TM/display-$cid"
    rm -f "$TM/last-$cid"
    hp=$(cat "$TM/helper.pid" 2>/dev/null)
    if [ -z "$hp" ] || ! kill -0 "$hp" 2>/dev/null; then
      ( sh /system_ext/bin/rhizo-task-bounds.sh ) >/dev/null 2>&1 &
    fi
    if read -r bw bh < "/data/rhizo_control/task-bounds-$cid" 2>/dev/null; then
      cmd activity task resize "$task" 0 0 "$bw" "$bh" >/dev/null 2>&1 && echo "$bw $bh" > "$TM/last-$cid"
    fi
  fi
  echo "stage=freeform task=$task cid=$cid"
fi
if [ -n "$ACTIVATION_TOKEN" ] && [ -n "$cid" ]; then
  echo display activate "$cid" "$ACTIVATION_TOKEN" > "$CTL"
fi

if [ -n "$do_power_confirm" ]; then
  t8=$(date +%s.%N)
  committed=timeout
  i=0
  waited_ms=0
  while [ "$i" -lt $((POWER_CONFIRM_FAST_ITERS + POWER_CONFIRM_ITERS)) ]; do
    powered_now=$(awk -v want="display powered id=$newid port=$newport" -v from="$reply_lineno" \
      'NR > from && index($0, want) { n = 1; exit } END { print n + 0 }' "$CTLOUT" 2>/dev/null)
    if [ "${powered_now:-0}" -gt 0 ]; then
      committed=confirmed
      break
    fi
    poll_sleep "$i" "$POWER_CONFIRM_FAST_ITERS"
    i=$((i + 1))
    waited_ms=$((waited_ms + POLL_LAST_TICK_MS))
    if [ $((waited_ms % POWER_CONFIRM_REISSUE_MS)) -eq 0 ]; then
      cmd display enable-display "$logid"
    fi
  done
  echo "stage=power-confirm t=$t8 committed=$committed"
  if [ "$committed" != confirmed ]; then
    echo display remove "$newid" > "$CTL"
    echo "stage=fail t=$(date +%s.%N) reason=power-confirm-timeout logid=$logid newid=$newid"
    exit 1
  fi
fi

t10=$(date +%s.%N)
on_top_why=""
await_on_top "$logid" "$ON_TOP_DEADLINE"
case $? in
  0) ;;
  1) on_top_why=not-on-top ;;
  2) on_top_why=launch-error ;;
  3) on_top_why=process-died ;;
esac
t10_end=$(date +%s.%N)
if [ -n "$on_top_why" ]; then
  echo "stage=fail t=$t10_end reason=$on_top_why logid=$logid am=$(echo "$AM_OUT" | grep -m1 -E 'Error|Exception' | tr ' ' '_')"
  exit 1
fi
echo "stage=on-top t=$t10 end=$t10_end"

echo "stage=done logid=$logid cid=${cid:-} bus=${BUS:-none} committed=$committed"
