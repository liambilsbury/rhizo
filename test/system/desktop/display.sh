#!/bin/bash
# test a click, a resize and a close on app displays on a boot
# RHIZO_RELEASE=a15 targets that release through test_boot; default a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-requires: none
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
[[ "${1:-}" == "--skip-boot" ]] && SKIP_BOOT=1

test_init display

# print the resumed activity for a display from the dumpsys output
resumed_on() {
  android_sh "$1" "dumpsys activity activities" \
    | awk -v want="Display #$2 " '/Display #/ {inseg = index($0, want) > 0}
                                   inseg && /topResumedActivity=/ {print; exit}' \
    | sed 's/.*ActivityRecord{[^ ]* [^ ]* \([^ }]*\).*/\1/'
}

# count rhizo-launch.sh summary lines for a package and activity
launch_summary_count() {
  ssh_vm -t 15 "grep -acF 'pkg=$1 activity=$2 display=' /run/rhizo-launch/rhizo-launch.log 2>/dev/null" | tr -d '\r'
}

# print all of the verdict lines rhizo-layerstack-guard.sh has appended
guard_verdict_lines() {
  android_sh "$INIT" "cat /data/local/tmp/rhizo-layerstack-guard.log" 2>/dev/null | grep -a '^t=.* verdict='
}

# print the composer's display stats reply for a display
composer_display_stats() {
  local cdisp="$1" before deadline
  before=$(rhizo_ctl_out "$INIT" | grep -cE "^display stats(-failed)? id=$cdisp ")
  rhizo_ctl "$INIT" display stats "$cdisp" >/dev/null 2>&1
  deadline=$(( $(date +%s) + 10 ))
  while (( $(date +%s) < deadline )); do
    if (( $(rhizo_ctl_out "$INIT" | grep -cE "^display stats(-failed)? id=$cdisp ") > before )); then
      rhizo_ctl_out "$INIT" | grep -E "^display stats(-failed)? id=$cdisp " | tail -1
      return 0
    fi
    sleep 0.5
  done
  return 1
}

# log the layer-stack readings for a display
layerstack_evidence() {
  local phase="$1" cdisp="$2" lid="$3" guard_before="${4:-0}"
  local dumps physid="" sf_stack="" dms_stack="" stats guard
  dumps=$(android_sh "$INIT" "dumpsys SurfaceFlinger; echo RHIZO_SPLIT_DMS; dumpsys display" 2>/dev/null)
  sed '/^RHIZO_SPLIT_DMS/,$d' <<<"$dumps" > "$EV/$phase-surfaceflinger.txt"
  sed '1,/^RHIZO_SPLIT_DMS/d' <<<"$dumps" > "$EV/$phase-dumpsys-display.txt"
  read -r physid sf_stack <<<"$(sf_layerstack_of "$cdisp" < "$EV/$phase-surfaceflinger.txt")"
  [[ -n "$physid" ]] && dms_stack=$(dms_layerstack_of "$physid" < "$EV/$phase-dumpsys-display.txt")
  stats=$(composer_display_stats "$cdisp")
  guard=$(guard_verdict_lines | tail -n +"$(( guard_before + 1 ))" | grep -a " cid=$cdisp ")
  {
    echo "phase=$phase cdisplay=$cdisp logical=$lid sf_physid=${physid:-none} sf_layerstack=${sf_stack:-none} dms_layerstack=${dms_stack:-none}"
    echo "composer: ${stats:-no display stats reply}"
    echo "guard: ${guard:-no verdict line for cid=$cdisp since the launch}"
  } > "$EV/$phase-summary.txt"
  log "    [$phase] display $cdisp (logical $lid): SurfaceFlinger layerStack=${sf_stack:-none}, DisplayManager mCurrentLayerStack=${dms_stack:-none}, composer $(grep -o 'presents=[0-9]*' <<<"$stats" || echo 'presents=?'), guard: ${guard:-no verdict since the launch}"
}

# launch an app through rhizo-launch.sh and print its display ids
launch_on_display() {
  local pkg_act="$1" label="$2" tag="${3:-}"
  local pkg="${pkg_act%%/*}" act="${pkg_act#*/}"
  local before after line cdisp lid guard_before=0 pid stages="" mapped=0 deadline
  before=$(launch_summary_count "$pkg" "$act")
  if [[ -n "$tag" ]]; then
    rm -f "$EV/$tag"-*
    guard_before=$(guard_verdict_lines | grep -c .)
  fi
  ssh_vm -t 150 "/usr/lib/rhizo/tools/rhizo-launch.sh $pkg $act > /tmp/test-display-launch.out 2>&1" >/dev/null 2>&1
  after=$(launch_summary_count "$pkg" "$act")
  if (( ${after:-0} <= ${before:-0} )); then
    ssh_vm -t 15 "cat /tmp/test-display-launch.out; tail -20 /run/rhizo-launch/rhizo-launch.log" > "$EV/launch-$pkg.out" 2>&1
    log "    $label: rhizo-launch.sh wrote no new summary line for $pkg_act (see $EV/launch-$pkg.out)"
    return 1
  fi
  line=$(ssh_vm -t 15 "grep -aF 'pkg=$pkg activity=$act display=' /run/rhizo-launch/rhizo-launch.log | grep -a 'committed=' | tail -1")
  cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$line" | cut -d= -f2)
  lid=$(grep -oE '(^|[[:space:]])display=[0-9]+' <<<"$line" | tail -1 | cut -d= -f2)
  if [[ -z "$cdisp" || -z "$lid" ]]; then
    log "    $label: rhizo-launch.sh's summary line names no display: ${line:-<none>}"
    return 1
  fi
  if [[ -n "$tag" ]]; then
    ssh_vm -t 15 "tail -200 /run/rhizo-launch/rhizo-launch.log" > "$EV/$tag-launch-log.txt" 2>&1
    pid=$(grep -aF 'event=invocation' "$EV/$tag-launch-log.txt" | grep -aF "pkg=$pkg activity=$act" | tail -1 | sed -n 's/.* pid=\([0-9]*\) .*/\1/p')
    stages=$(grep -a "event=stage pid=${pid:-none} " "$EV/$tag-launch-log.txt" | sed -n 's/.* name=//p' | tr '\n' ' ')
    log "    [$tag] $label's launch took: ${stages:-no stage lines found}"
    layerstack_evidence "$tag-before" "$cdisp" "$lid" "$guard_before"
  fi
  desktop_mapped_window_rect "$cdisp" 20 >/dev/null && mapped=1
  if [[ -n "$tag" ]]; then
    if [[ "$stages" == *display-add* || -z "$stages" ]]; then
      deadline=$(( $(date +%s) + 45 ))
      while (( $(date +%s) < deadline )) \
            && ! guard_verdict_lines | tail -n +"$(( guard_before + 1 ))" | grep -aq " cid=$cdisp "; do
        sleep 1
      done
    fi
    layerstack_evidence "$tag-after" "$cdisp" "$lid" "$guard_before"
  fi
  if (( mapped )); then
    echo "$cdisp $lid"
    return 0
  fi
  log "    $label: display $cdisp (logical $lid) never presented a window within 20s of rhizo-launch.sh returning"
  return 1
}

# print SurfaceFlinger's layer stack for a composer display
sf_layerstack_of() {
  awk -v cid="$1" '
    $0 ~ "\\(HWC display " cid "\\):" { physid = $2 }
    physid != "" && !in_block && $0 ~ ("^Display " physid " \\(physical") { grab = 6; in_block = 1; next }
    in_block && grab > 0 {
      if ($0 ~ /layerFilter=\{layerStack=/) {
        match($0, /layerStack=[0-9]+/)
        print physid" "substr($0, RSTART + 11, RLENGTH - 11)
        found = 1
        exit
      }
      grab--
    }
    END { if (physid != "" && !found) print physid" NA" }
  '
}
# print DisplayManager's layer stack for a physical display
dms_layerstack_of() {
  awk -v physid="$1" '
    $0 ~ ("mUniqueId=local:" physid "$") { grab = 6; next }
    grab > 0 {
      if (match($0, /mCurrentLayerStack=-?[0-9]+/)) {
        print substr($0, RSTART + 19, RLENGTH - 19)
        exit
      }
      grab--
    }
  '
}

APP1="com.android.messaging/.ui.conversationlist.ConversationListActivity"
APP2="com.android.settings/.Settings"

if (( SKIP_BOOT == 0 )); then
  step "0. boot: VM, compositor, Android"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up >$EV/sway.log 2>&1 || { fail "the desktop session did not start (see $EV/sway.log)"; exit 1; }
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 180 >$EV/redeploy.log 2>&1 || { fail "redeploy.sh failed (see $EV/redeploy.log)"; exit 1; }
  tail -3 $EV/redeploy.log
else
  test_ensure_desktop "$EV/chained-sway.log" "$EV/chained-redeploy.log"
fi
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
log "init_pid=$INIT"

boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"
SS_PID_START=$(system_server_pid "$INIT")
log "system_server pid at start: $SS_PID_START"
TEST_SINCE=$(logcat_since_marker "$INIT")

android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "locksettings set-disabled true" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
wait_guest 30 "true" >/dev/null
awake=$(wait_device_awake "$INIT")
[[ "$awake" == "mWakefulness=Awake" ]] || fail "device is not awake ($awake)"
kg="" kg_deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < kg_deadline )); do
  kg=$(android_sh "$INIT" "dumpsys activity activities" | grep -m1 -o 'mKeyguardShowing=[a-z]*')
  [[ "$kg" == "mKeyguardShowing=false" ]] && break
  sleep 2
done
if [[ "$kg" == "mKeyguardShowing=false" ]]; then
  pass "booted, awake, keyguard not showing ($kg)"
else
  fail "the keyguard still shows 30s after locksettings set-disabled and wm dismiss-keyguard (${kg:-no mKeyguardShowing line in dumpsys activity activities})"
fi

rhizo_ctl "$INIT" wl status >/dev/null
wl=$(rhizo_ctl_out "$INIT" | grep "^wl status " | tail -1)
[[ -n "$wl" ]] || fail "composer control FIFO did not answer wl status"
pass "composer debug channel round-tripped: ${wl:0:100}"

primary_id=$(_desktop_window_id_for_identity rhizo Rhizo 20)
[[ -n "$primary_id" ]] && desk_window_op "$primary_id" move 0 1080

# print the Android display ids
display_ids() { android_sh "$INIT" "dumpsys display" | grep -oE "^  Display Id=[0-9]+" | grep -oE "[0-9]+$" | sort -n | tr '\n' ' '; }
# print the display ids listed by dumpsys activity
activity_ids() { android_sh "$INIT" "dumpsys activity activities" | grep -oE "Display #[0-9]+" | grep -oE "[0-9]+$" | sort -nu | tr '\n' ' '; }
# print the sway window id of a composer display
display_window_id() {
  local disp="$1" win
  win=$(_desktop_window_for_display "$disp" 20) || return 1
  python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('id',''))" "$win"
}
WINS_BASE=$(desktop_app_toplevel_count)
IDS_START=$(display_ids)
log "    app windows mapped before this test: $WINS_BASE; displays: [$IDS_START]"

if wait_guest 120 "test -e /run/rhizo-display-pool/ready || journalctl -b -q -t rhizo-display-pool 2>/dev/null | grep -q 'stage=done\|attempt 5'"; then
  log "    boot prime settled: $(gcmd_user 'cat /run/rhizo-display-pool/ready 2>/dev/null || journalctl -b -q -t rhizo-display-pool -o cat | tail -1' 15 | tr -d '\r')"
else
  log "    boot prime reported nothing in 120s -- launching anyway"
fi

step "1. baseline single window"
android_sh "$INIT" "pm grant com.android.messaging android.permission.POST_NOTIFICATIONS" >/dev/null
launched=$(launch_on_display "$APP1" "app A" H-appA) || fail "app A's window never mapped"
read -r D1 L1 <<<"$launched"
log "    app A: composer display $D1, logical display $L1"
d1_id=$(display_window_id "$D1") && desk_window_op "$d1_id" move 0 0
read -r W1X W1Y W1W W1H <<<"$(desktop_window_rect "$D1")"
[[ -n "${W1W:-}" ]] || fail "could not read app A's window rect"
desk_shot /tmp/g1.png >/dev/null && pull /tmp/g1.png "$EV/test-1-baseline.png"
nb=$(python3 ../tools/pngstat.py "$EV/test-1-baseline.png" --region "$W1X,$W1Y,$W1W,$W1H" | grep '^nonblack_pct=' | cut -d= -f2)
log "    baseline nonblack: ${nb}%"
awk -v v="${nb:-0}" 'BEGIN{exit !(v>50)}' || fail "app A's window is not showing real content (${nb}% nonblack)"
pass "app A's window live"

step "2. second display, second app, two live windows"
launched=$(launch_on_display "$APP2" "app B" H-appB) || fail "app B's window never mapped"
read -r D2 L2 <<<"$launched"
log "    app B: composer display $D2, logical display $L2"
desk_windows | sed 's/^/    /'
read -r W2X W2Y W2W W2H <<<"$(desktop_window_rect "$D2")"
if [[ -n "${W2W:-}" && -n "${W1W:-}" ]] \
   && (( W2X < W1X + W1W && W1X < W2X + W2W && W2Y < W1Y + W1H && W1Y < W2Y + W2H )); then
  d2_place_id=$(display_window_id "$D2") || d2_place_id=""
  for _i in $(seq 1 20); do
    [[ -n "$d2_place_id" ]] && desk_window_op "$d2_place_id" move $(( W1X + W1W )) "$W1Y" >/dev/null 2>&1
    read -r W2X W2Y W2W W2H <<<"$(desktop_window_rect "$D2")"
    [[ "${W2X:-}" == "$(( W1X + W1W ))" && "${W2Y:-}" == "$W1Y" ]] && break
    sleep 0.5
  done
fi
[[ -n "${W2W:-}" && -n "${W1W:-}" ]] || fail "could not read both window rects"
log "    window 1 rect: ${W1X},${W1Y} ${W1W}x${W1H}   window 2 rect: ${W2X},${W2Y} ${W2W}x${W2H}"
deadline=$(( $(date +%s) + 20 ))
while true; do
  desk_shot /tmp/g2.png >/dev/null && pull /tmp/g2.png "$EV/test-2-two-windows.png"
  live=0
  for r in "$W1X,$W1Y,$W1W,$W1H:window 1" "$W2X,$W2Y,$W2W,$W2H:window 2"; do
    reg="${r%%:*}"
    pct=$(python3 ../tools/pngstat.py "$EV/test-2-two-windows.png" --region "$reg" | grep '^nonblack_pct=' | cut -d= -f2)
    dis=$(python3 ../tools/pngstat.py "$EV/test-2-two-windows.png" --region "$reg" | grep '^distinct=' | cut -d= -f2)
    awk -v v="${pct:-0}" 'BEGIN{exit !(v>50)}' && [[ "${dis:-0}" -gt 20 ]] && live=$((live + 1))
  done
  (( live == 2 )) && break
  (( $(date +%s) < deadline )) || break
  sleep 1
done
for r in "$W1X,$W1Y,$W1W,$W1H:window 1" "$W2X,$W2Y,$W2W,$W2H:window 2"; do
  reg="${r%%:*}"; name="${r##*:}"
  pct=$(python3 ../tools/pngstat.py "$EV/test-2-two-windows.png" --region "$reg" | grep '^nonblack_pct=' | cut -d= -f2)
  dis=$(python3 ../tools/pngstat.py "$EV/test-2-two-windows.png" --region "$reg" | grep '^distinct=' | cut -d= -f2)
  log "    $name: ${pct}% nonblack, $dis distinct colors"
  awk -v v="${pct:-0}" 'BEGIN{exit !(v>50)}' || fail "$name is not showing real content"
  [[ "${dis:-0}" -gt 20 ]] || fail "$name looks like a flat fill, not app content"
done
d1=$(android_sh "$INIT" "dumpsys activity activities" | grep -c "Display #")
[[ "$d1" -ge 2 ]] || fail "the framework does not have two activity displays"
pass "two live windows, two apps, two activity displays"

step "3. input"
if [[ "${RHIZO_DESKTOP_PROFILE:-sway}" == sway ]]; then
  inject_start || fail "could not start the persistent virtual pointer"
fi
before2=$(resumed_on "$INIT" "$L2")
before1=$(resumed_on "$INIT" "$L1")
log "    before -- window 2 (display $D2): ${before2:-none}"
log "    before -- window 1 (display $D1): ${before1:-none}"
desk_shot /tmp/g3a.png >/dev/null && pull /tmp/g3a.png "$EV/test-3-input-before.png"
TAPX=$(( W2X + 200 )); TAPY=$(( W2Y + 490 ))
log "    tapping ${TAPX},${TAPY} (window 2)"
desktop_inject_click "$TAPX" "$TAPY" || fail "inject failed"
after2=""
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
  after2=$(resumed_on "$INIT" "$L2")
  [[ -n "$after2" && "$after2" != "$before2" ]] && break
  sleep 1
done
after1=$(resumed_on "$INIT" "$L1")
log "    after  -- window 2 (display $D2): ${after2:-none}"
log "    after  -- window 1 (display $D1): ${after1:-none}"
[[ -n "$before2" && -n "$after2" ]] || fail "could not read window 2's resumed activity"
[[ "$after2" != "$before2" ]] || fail "window 2's resumed activity did not change"
[[ "$after1" == "$before1" ]] || fail "window 1's resumed activity changed too -- input leaked across displays"
min_changed=$(( W2W * W2H * 5 / 100 ))
wait_shot_change 15 "$EV/test-3-input-before.png" "$EV/test-3-input-after.png" "$W2X,$W2Y,$W2W,$W2H" "$min_changed" >/dev/null
chg2=$(python3 ../tools/pngstat.py --diff "$EV/test-3-input-before.png" "$EV/test-3-input-after.png" --region "$W2X,$W2Y,$W2W,$W2H" | grep '^changed_pct=' | cut -d= -f2)
chg1=$(python3 ../tools/pngstat.py --diff "$EV/test-3-input-before.png" "$EV/test-3-input-after.png" --region "$W1X,$W1Y,$W1W,$W1H" | grep '^changed_pct=' | cut -d= -f2)
log "    pixels changed: window 2 ${chg2}%, window 1 ${chg1}%"
awk -v v="${chg2:-0}" 'BEGIN{exit !(v>5)}' || fail "window 2's pixels barely moved (${chg2}%)"
awk -v v="${chg1:-100}" 'BEGIN{exit !(v<2)}' || fail "window 1 changed too (${chg1}%) -- input is not display-scoped"
pass "a real click changed on-screen state on display $D2 only"

# print the ids of all of the displays held at a forced size
forced_size_displays() {
  awk '
    /^[[:space:]]*Display: mDisplayId=[0-9]+/ {
      seen = 1
      id = $0; sub(/.*mDisplayId=/, "", id); sub(/[^0-9].*/, "", id)
      next
    }
    id != "" && /^[[:space:]]*init=[0-9]+x[0-9]+ / {
      init = $0; sub(/^[[:space:]]*init=/, "", init); sub(/ .*/, "", init)
      if (match($0, / base=[0-9]+x[0-9]+ /) && substr($0, RSTART + 6, RLENGTH - 7) != init) print id
      id = ""
    }
    END { if (!seen) exit 2 }
  '
}

# print a display's first task as "mode taskWxH configWxH"
task_bounds_on() {
  android_sh "$1" "dumpsys activity activities" | awk -v want="Display #$2 " '
    function wh(s,   p) { sub(/.*Rect\(/, "", s); sub(/\).*/, "", s); split(s, p, /[ ,-]+/); return (p[3] - p[1]) "x" (p[4] - p[2]) }
    /^Display #/ { inseg = index($0, want) == 1; next }
    inseg && !task && /^  \* Task\{/ { task = 1; mode = ($0 ~ / mode=freeform /) ? "freeform" : "not-freeform"; next }
    inseg && task && tb == "" && /^    mBounds=Rect\(/ { tb = wh($0) }
    inseg && task && cb == "" && /CurrentConfiguration=/ && match($0, /winConfig=\{ mBounds=Rect\([^)]*\)/) { cb = wh(substr($0, RSTART, RLENGTH)) }
    END { print (mode == "" ? "none" : mode), (tb == "" ? "none" : tb), (cb == "" ? "none" : cb) }'
}

step "4. resize"
sz_before=$(android_sh "$INIT" "dumpsys window displays" | grep -A1 "mDisplayId=$L2" | grep -m1 -o "init=[0-9]*x[0-9]*")
rhizo_ctl "$INIT" display toplevel "$D2" >/dev/null 2>&1
scale=$(rhizo_ctl_out "$INIT" | grep "^display toplevel id=$D2 " | tail -1 | grep -o ' scale=[0-9.]*' | cut -d= -f2)
[[ -n "$scale" ]] || fail "the composer did not report display $D2's scale"
read -r WANT_W WANT_H <<<"$(awk -v s="${scale:-1}" 'BEGIN { s120 = int(s * 120 + 0.5); printf "%d %d\n", int(640 * s + 0.5), int(480 * s + 0.5) + int((42 * s120 + 60) / 120) }')"
WANT_TASK="freeform ${WANT_W}x${WANT_H} ${WANT_W}x${WANT_H}"
d2_id=$(display_window_id "$D2")
if [[ -n "$d2_id" ]]; then
  desk_window_op "$d2_id" unmaximize
  desk_window_op "$d2_id" resize 640 480
fi
task_after=""
resize_deadline=$(( $(date +%s) + 40 ))
while (( $(date +%s) < resize_deadline )); do
  task_after=$(task_bounds_on "$INIT" "$L2")
  [[ "$task_after" == "$WANT_TASK" ]] && break
  sleep 1
done
[[ "$task_after" == "$WANT_TASK" ]] || fail "display $D2's task never relayouted to 640x480 (want '$WANT_TASK' at scale ${scale:-?}, got '${task_after:-none}')"
sz_after=$(android_sh "$INIT" "dumpsys window displays" | grep -A1 "mDisplayId=$L2" | grep -m1 -o "init=[0-9]*x[0-9]*")
wm_displays=$(android_sh "$INIT" "dumpsys window displays")
forced=$(forced_size_displays <<<"$wm_displays"); forced_rc=$?
log "    display $D2 task: ${task_after:-none} (want $WANT_TASK); display base metrics: $sz_before -> $sz_after (displays at a forced size: [${forced//$'\n'/ }])"
[[ -n "$sz_before" && "$sz_after" == "$sz_before" ]] || fail "display $D2 base metrics moved from ${sz_before:-none} to ${sz_after:-none}"
(( forced_rc == 0 )) || fail "could not read dumpsys window displays"
[[ -z "$forced" ]] || fail "display(s) ${forced//$'\n'/ } are at a forced size (base= differs from init= in dumpsys window displays)"
still=$(resumed_on "$INIT" "$L2")
log "    display $D2 still running: ${still:-nothing}"
[[ -n "$still" ]] || fail "display $D2 lost its activity across the resize"
desk_shot /tmp/g4.png >/dev/null && pull /tmp/g4.png "$EV/test-4-resized.png"
read -r R2X R2Y R2W R2H <<<"$(desktop_window_rect "$D2")"
pct=$(python3 ../tools/pngstat.py "$EV/test-4-resized.png" --region "$R2X,$R2Y,$R2W,$R2H" | grep '^nonblack_pct=' | cut -d= -f2)
dis=$(python3 ../tools/pngstat.py "$EV/test-4-resized.png" --region "$R2X,$R2Y,$R2W,$R2H" | grep '^distinct=' | cut -d= -f2)
log "    resized window rect ${R2X},${R2Y} ${R2W}x${R2H}, ${pct}% nonblack, ${dis} distinct colors"
[[ "${R2W:-}x${R2H:-}" == "640x480" ]] || fail "the resized window is ${R2W:-?}x${R2H:-?}, not 640x480"
awk -v v="${pct:-0}" 'BEGIN{exit !(v>50)}' || fail "the resized window is not showing content"
[[ "${dis:-0}" -gt 20 ]] || fail "the resized window looks like a flat fill, not app content"
pass "compositor resize became a Configuration change of the app's freeform task"

step "5. close"
ids_before=$(display_ids); acts_before=$(activity_ids)
d2_close_id=$(display_window_id "$D2")
[[ -n "$d2_close_id" ]] && desk_window_op "$d2_close_id" close
# succeed when only the closed display id is gone
settled() {
  local before="$1" now="$2" closed="$3" id
  for id in $now; do [[ "$id" == "$closed" ]] && return 1; done
  for id in $before; do
    [[ "$id" == "$closed" ]] && continue
    grep -qw "$id" <<<"$now" || return 1
  done
  return 0
}
wins=0
close_deadline=$(( $(date +%s) + 40 ))
while (( $(date +%s) < close_deadline )); do
  ids_now=$(display_ids); acts_now=$(activity_ids); wins=$(desktop_app_toplevel_count)
  settled "$ids_before" "$ids_now" "$L2" && settled "$acts_before" "$acts_now" "$L2" && (( wins == WINS_BASE + 1 )) && break
  sleep 1
done
new_ids=""; for id in $ids_now; do grep -qw "$id" <<<"$ids_before" || new_ids+="$id "; done
log "    displays [$ids_before] -> [$ids_now], activity displays [$acts_before] -> [$acts_now], app windows now $wins, new since the close: [${new_ids:-none}]"
settled "$ids_before" "$ids_now" "$L2" || fail "logical display $L2 did not leave dumpsys display cleanly (or another display left with it)"
settled "$acts_before" "$acts_now" "$L2" || fail "activity display $L2 did not leave dumpsys activity cleanly (or another display left with it)"
(( wins == WINS_BASE + 1 )) || fail "expected one app window left beyond the $WINS_BASE mapped before this system test, found $wins"
desk_shot /tmp/g5.png >/dev/null && pull /tmp/g5.png "$EV/test-5-after-close.png"
pass "closing the window removed the display and its task"

step "6. regression check"
SS_PID_END=$(system_server_pid "$INIT")
boot_end=$(getprop_live "$INIT" sys.boot_completed) || boot_end="<unreadable rc=$?>"
log "    system_server pid $SS_PID_START -> $SS_PID_END, sys.boot_completed=$boot_end"
[[ "$SS_PID_START" == "$SS_PID_END" ]] || fail "system_server restarted ($SS_PID_START -> $SS_PID_END)"
[[ "$boot_end" == "1" ]] || fail "sys.boot_completed is '$boot_end'"
# return true only when the capture holds a real threadtime line
logcat_capture_read() {
  grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' "$1"
}
logcat_vm "$INIT" -d -t "$TEST_SINCE" 2>/dev/null > "$EV/logcat-since-start.txt"
if ! logcat_capture_read "$EV/logcat-since-start.txt"; then
  fail "the fatal sweep read no logcat since '$TEST_SINCE' (capture starts: $(head -c 120 "$EV/logcat-since-start.txt" | tr '\n' ' '))"
else
  bad=$(grep -cE "$TEST_FATAL_RE" "$EV/logcat-since-start.txt")
  log "    fatal/watchdog lines in logcat: $bad"
  [[ "$bad" == "0" ]] || {
    fail "logcat has $bad fatal/watchdog lines"
    test_fatal_lines "$EV/logcat-since-start.txt"
  }
fi

step "7. close the windows this system test left open"
log "    app windows still mapped: $(desktop_app_toplevel_count)"
desk_windows | sed 's/^/      /'
desktop_close_all_app_windows 40 || log "    desktop_close_all_app_windows did not clear them all"
spare_lid=""
spare_port=""
lists_before=$(rhizo_ctl_out "$INIT" | grep -c '^display list')
rhizo_ctl "$INIT" display list >/dev/null
dlist=""
for _ in $(seq 1 15); do
  if (( $(rhizo_ctl_out "$INIT" | grep -c '^display list') > lists_before )); then
    dlist=$(rhizo_ctl_out "$INIT" | grep '^display list' | tail -1); break
  fi
  sleep 1
done
spare_cid=$(rhizo_dl_spares "$dlist" | head -1)
if [[ -n "$spare_cid" ]]; then
  spare_port=$(rhizo_ctl_out "$INIT" | grep -o "display pooled id=$spare_cid port=[0-9]*" | tail -1 | grep -o 'port=[0-9]*' | cut -d= -f2)
  [[ -n "$spare_port" ]] && spare_lid=$(resolve_logical_id "$spare_port")
fi
# succeed when only the starting displays and the spare remain
clean() {
  local id ids allowed_now
  [[ -n "$spare_port" ]] && spare_lid=$(resolve_logical_id "$spare_port")
  allowed_now="$IDS_START $spare_lid"
  ids=$(display_ids)
  [[ -n "${ids// /}" ]] || return 1
  for id in $ids; do grep -qw "$id" <<<"$allowed_now" || return 1; done
  [[ "$(desktop_app_toplevel_count)" == "$WINS_BASE" ]]
}
ids_end=""
for _ in $(seq 1 20); do
  ids_end=$(display_ids); clean && break
  sleep 1
done
if ! clean; then
  desktop_close_all_app_windows 20 || true
  for _ in $(seq 1 20); do
    ids_end=$(display_ids); clean && break
    sleep 1
  done
fi
if clean; then
  pass "displays [$ids_end] are the starting set [$IDS_START] plus the spare (logical ${spare_lid:-none}), no app window left"
else
  android_sh "$INIT" "dumpsys display" > "$EV/leftover-dumpsys-display.txt" 2>&1
  rhizo_ctl_out "$INIT" > "$EV/leftover-composer-control.txt" 2>&1
  desk_windows > "$EV/leftover-sway-windows.txt" 2>&1
  grep -E "^  Display Id=|mDisplayId=|uniqueId|mDisplayInfo=|name=|physicalPort" "$EV/leftover-dumpsys-display.txt" | head -20 | sed 's/^/      /'
  fail "displays [$ids_end] are not the starting set [$IDS_START] plus the spare (logical ${spare_lid:-none}), or an app window is still mapped (see $EV/leftover-*.txt)"
fi

if (( FAILED )); then test_record_verdict FAILED; log "DISPLAY SYSTEM TEST FAILED"; exit 1; fi
test_record_verdict PASSED
log "DISPLAY SYSTEM TEST PASSED -- evidence in $EV"
