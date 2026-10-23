#!/bin/bash
# test window identity, resize, scale and move, and keyboard, scroll and cursor input
# RHIZO_RELEASE=a15 targets that release through test_boot; default a16
# RHIZO_WINTEST_LAYOUT=fr the host keyboard layout the keyboard leg asserts
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-requires: share:rhizo-winapp.apk share:rhizo-winapp2.apk share:wlr-inject
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
SELFTEST=0
for arg in "$@"; do
  case "$arg" in
    --skip-boot) SKIP_BOOT=1 ;;
    --selftest) SELFTEST=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

test_init window-input
APPSYNC_EV_FILES=(appsync-journal.txt appsync-units.txt appsync-applications-dir.txt
                  appsync-trigger-stat.txt appsync-data-app.txt)
for _name in "${APPSYNC_EV_FILES[@]}"; do
  echo "<not reached> -- this run ended before the app-sync leg" > "$EV/$_name"
done
if (( SELFTEST )); then
  EV="$EV/selftest"
  mkdir -p "$EV" || exit 1
  : > "$EV/failures.log"
fi
WORKDIR="$TEST_WORKDIR"

# print the received string, corrupted under --selftest
st() {
  if (( SELFTEST )); then printf 'selftest-corrupted-%s' "$1"; else printf '%s' "$1"; fi
}
# corrupt a number by adding 100000
st_num() {
  if (( SELFTEST )); then printf '%s' $(( ${1%%.*} + 100000 )); else printf '%s' "$1"; fi
}
# replace a PNG with a black image of a different size
st_png() {
  (( SELFTEST )) || return 0
  python3 - "$1" <<'STPY'
import struct, sys, zlib
w = h = 16
rows = b"".join(b"\x00" + bytes([0, 0, 0] * w) for _ in range(h))
def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
open(sys.argv[1], "wb").write(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(rows))
    + chunk(b"IEND", b""))
STPY
  return 0
}
# corrupt a value to zero
st_zero() {
  if (( SELFTEST )); then printf '0'; else printf '%s' "$1"; fi
}
# collapse all of the readings to a constant
st_const() {
  if (( SELFTEST )); then printf 'selftest-collapsed'; else printf '%s' "$1"; fi
}
# print a display id that nothing is mapped on
st_disp() {
  if (( SELFTEST )); then printf '%s' 4095; else printf '%s' "$1"; fi
}

SELFTEST_STEPS=()
if (( SELFTEST )); then
  # shellcheck disable=SC2034
  step() { TEST_STEP="$*"; SELFTEST_STEPS+=("$*"); log "=== $*"; }
fi

ADB=~/Android/Sdk/platform-tools/adb
APP_PKG=com.rhizo.winapp
APP_ACT=com.rhizo.winapp.MainActivity
APP2_PKG=com.rhizo.winapp2
APP2_ACT=com.rhizo.winapp.MainActivity
HOST_LAYOUT="${RHIZO_WINTEST_LAYOUT:-fr}"
OUT1=HEADLESS-1
OUT2=HEADLESS-2
SECOND_MODE=2560x1440
PROFILE="${RHIZO_DESKTOP_PROFILE:-sway}"
SESSION_ARGS=()
if [[ "$PROFILE" == plasma ]]; then
  OUT1=Virtual-0
  OUT2=Virtual-1
  SESSION_ARGS=(--monitors "$SECOND_MODE,$SECOND_MODE")
fi

for f in "$VAR_DIR/share/rhizo-winapp.apk" "$VAR_DIR/share/rhizo-winapp2.apk"; do
  [[ -f "$f" ]] || { fail "missing $f"; exit 1; }
done
if [[ "$PROFILE" == sway ]]; then
  sway_injector_staged || { fail "missing the pointer/keyboard injector"; exit 1; }
fi

# press and release each key through the profile's input device
test_type() {
  if [[ "$PROFILE" == sway ]]; then inject_type "$@"; return; fi
  local c
  for c in "$@"; do desk_inject_key "$c" 1 && desk_inject_key "$c" 0 || return 1; done
}
# press a key with the given modifiers held
test_chord() {
  if [[ "$PROFILE" == sway ]]; then inject_chord "$@"; return; fi
  local target="$1" m i; shift
  for m in "$@"; do desk_inject_key "$m" 1 || return 1; done
  desk_inject_key "$target" 1 && desk_inject_key "$target" 0 || return 1
  for (( i=$#; i>=1; i-- )); do desk_inject_key "${!i}" 0 || return 1; done
}

# print a new random nonce for each leg
nonce() { head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# drive the app with a package, activity, nonce and extra args
app_cmd() {
  local pkg="$1" act="$2" n="$3"; shift 3
  android_sh "$INIT" "am start -n $pkg/$act --es nonce $n $*" >/dev/null 2>&1
}

# print the app's last line for this run's nonce
app_token() {
  local token="$1" n="$2" deadline=$(( $(date +%s) + $3 )) logs hit
  while (( $(date +%s) < deadline )); do
    logs=$(android_sh "$INIT" "logcat -d -b all -s RhizoWinApp:I" 2>/dev/null)
    hit=$(grep -a -o "$token nonce=$n.*" <<<"$logs" | tail -1)
    [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
    sleep 1
  done
  return 1
}

# ask the app whether it is alive
app_ping() {
  android_sh "$INIT" "am broadcast -a $1.PING --es nonce $2" >/dev/null 2>&1
}

# print the value of key=... in an app token line
field() { sed -n "s/.*[[:space:]]$2=\([^[:space:]]*\).*/\1/p" <<<"$1" | tr -d '\r'; }

# poll the app's reports for key=expected
wait_app_field() {
  local token="$1" n="$2" key="$3" want="$4" deadline=$(( $(date +%s) + $5 ))
  local logs hit got last="" num='^-?[0-9]+(\.[0-9]+)?$'
  while (( $(date +%s) < deadline )); do
    logs=$(android_sh "$INIT" "logcat -d -b all -s RhizoWinApp:I" 2>/dev/null)
    while read -r hit; do
      [[ -n "$hit" ]] || continue
      last="$hit"
      got=$(field "$hit" "$key")
      if [[ "$got" == "$want" ]] || { [[ "$got" =~ $num && "$want" =~ $num ]] \
           && awk -v a="$got" -v b="$want" 'BEGIN{exit !(a + 0 == b + 0)}'; }; then
        printf '%s' "$hit"; return 0
      fi
    done < <(grep -a -o "$token nonce=$n.*" <<<"$logs")
    sleep 1
  done
  printf '%s' "$last"
  return 1
}

# print a toplevel's node as compact json
win_json() {
  local disp="$1" win
  win=$(_desktop_window_for_display "$disp" 0) || return 1
  python3 -c "
import json, sys
w = json.loads(sys.argv[1])
print(json.dumps({
    'app_id': w.get('app_id'), 'name': w.get('title'),
    'x': w.get('x'), 'y': w.get('y'), 'w': w.get('w'), 'h': w.get('h'),
    'fullscreen_mode': 1 if w.get('fullscreen') else 0,
    'output': w.get('monitor'), 'focused': w.get('focused'),
    'floating': not w.get('maximized'),
    'decoration_h': w.get('decoration_h', 0),
}))
" "$win"
}

# print a field of a composer display's window line
win_field() {
  local j; j=$(win_json "$1") || return 1
  python3 -c "import json,sys; print(json.load(sys.stdin).get('$2',''))" <<<"$j"
}

# print the desk_windows id of a composer display
display_window_id() {
  local disp="$1" win
  win=$(_desktop_window_for_display "$disp" 5) || return 1
  python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('id',''))" "$win"
}

# poll the compositor until the toplevel carries the given size
wait_win_size() {
  local disp="$1" w="$2" h="$3" deadline=$(( $(date +%s) + $4 )) j gw gh
  while (( $(date +%s) < deadline )); do
    if j=$(win_json "$disp" 2>/dev/null); then
      gw=$(python3 -c "import json,sys; print(json.load(sys.stdin)['w'])" <<<"$j")
      gh=$(python3 -c "import json,sys; print(json.load(sys.stdin)['h'])" <<<"$j")
      [[ "$gw" == "$w" && "$gh" == "$h" ]] && { printf '%s %s' "$gw" "$gh"; return 0; }
    fi
    sleep 1
  done
  printf '%s %s' "${gw:-?}" "${gh:-?}"
  return 1
}

# print the first task's bounds on an Android display as WxH
task_size() {
  android_sh "$INIT" "dumpsys activity activities" | awk -v want="Display #$1 " '
    /^Display #/ { on = index($0, want) == 1; next }
    on && /^    mBounds=Rect\(/ { s = $0; sub(/.*Rect\(/, "", s); sub(/\).*/, "", s); split(s, p, /[ ,-]+/)
                                  print (p[3] - p[1]) "x" (p[4] - p[2]); exit }'
}

# poll an Android display's task until its bounds are WxH
wait_task_size() {
  local deadline=$(( $(date +%s) + $3 )) got=""
  while (( $(date +%s) < deadline )); do
    got=$(task_size "$1")
    [[ "$got" == "$2" ]] && break
    sleep 1
  done
  printf '%s' "${got:-none}"
  [[ "$got" == "$2" ]]
}

# print the height of Android's freeform caption in pixels at a composer display's scale
caption_px() {
  local s
  rhizo_ctl "$INIT" display toplevel "$1" >/dev/null 2>&1
  s=$(rhizo_ctl_out "$INIT" | grep "^display toplevel id=$1 " | tail -1 | grep -o ' scale=[0-9.]*' | cut -d= -f2)
  [[ -n "$s" ]] || return 1
  awk -v s="$s" 'BEGIN { s120 = int(s * 120 + 0.5); print int((42 * s120 + 60) / 120) }'
}



if (( SKIP_BOOT == 0 )); then
  step "0. boot the guest, the compositor with a $HOST_LAYOUT keyboard, and the stack"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up --layout "$HOST_LAYOUT" "${SESSION_ARGS[@]}" >"$EV/sway.log" 2>&1 \
    || { fail "the desktop session did not start (see $EV/sway.log)"; exit 1; }
  if [[ "$PROFILE" == plasma ]]; then
    desk_outputs remove "$OUT2" >>"$EV/sway.log" 2>&1 \
      || { fail "could not take $OUT2 out until step 6 adds it (see $EV/sway.log)"; exit 1; }
  fi
  if [[ "$PROFILE" == sway ]]; then
    ../inject/make-xkb-keymap.sh "$HOST_LAYOUT" "$VAR_DIR/share/rhizo-xkb-$HOST_LAYOUT.xkb" >/dev/null \
      || { fail "could not compile an xkb keymap for $HOST_LAYOUT"; exit 1; }
    ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
    guest_mount_share || { fail "could not mount the 9p share to reach the compiled xkb keymap"; exit 1; }
    gcmd_root "cp -f /root/share/rhizo-xkb-$HOST_LAYOUT.xkb /tmp/rhizo-xkb-$HOST_LAYOUT.xkb" 15 \
      || { fail "could not stage the compiled xkb keymap where the injector can reach it"; exit 1; }
    RHIZO_INJECT_KEYMAP="/tmp/rhizo-xkb-$HOST_LAYOUT.xkb" \
      inject_devices_up || { fail "the injector's devices did not come up before the boot"; exit 1; }
  fi
  ../../vm/redeploy.sh --skip-kill --boot-wait 200 >"$EV/redeploy.log" 2>&1 \
    || { fail "redeploy.sh failed (see $EV/redeploy.log)"; exit 1; }
  tail -4 "$EV/redeploy.log"
  if [[ "$PROFILE" == sway ]]; then
    inject_attach || { fail "the injector never took a command channel after the boot"; exit 1; }
  fi
  ../../vm/start/start-unit.sh keymapd >"$EV/keymapd.log" 2>&1 \
    || { fail "the keyboard-layout resolver did not start (see $EV/keymapd.log)"; exit 1; }
  ../../vm/start/start-unit.sh displayd >"$EV/displayd.log" 2>&1 \
    || { fail "the per-display density daemon did not start (see $EV/displayd.log)"; exit 1; }
  ../inject/disable-pointer-accel.sh >"$EV/input-tuning.log" 2>&1 \
    || { fail "could not turn off Android's pointer acceleration (see $EV/input-tuning.log)"; exit 1; }
else
  if [[ "$PROFILE" == sway ]]; then
    inject_attach || { fail "no injector with live devices is running"; exit 1; }
  fi
  if [[ "${RHIZO_TEST_INSTALLED:-0}" == 1 ]]; then
    desk_keyboard_layout "$HOST_LAYOUT" >"$EV/sway.log" 2>&1 \
      || { fail "the installed guest's session did not take the $HOST_LAYOUT layout (see $EV/sway.log)"; exit 1; }
    ../../vm/start/start-unit.sh keymapd >"$EV/keymapd.log" 2>&1 \
      || { fail "the installed keyboard-layout resolver did not restart (see $EV/keymapd.log)"; exit 1; }
    ../../vm/start/start-unit.sh displayd >"$EV/displayd.log" 2>&1 \
      || { fail "the installed per-display density daemon did not restart (see $EV/displayd.log)"; exit 1; }
    ../inject/disable-pointer-accel.sh >"$EV/input-tuning.log" 2>&1 \
      || { fail "could not turn off Android's pointer acceleration (see $EV/input-tuning.log)"; exit 1; }
  fi
fi

desk_windows >/dev/null 2>&1 \
  || { fail "the compositor is not answering after the boot -- see $EV/sway.log and /tmp/sway.log in the guest"; exit 1; }
if [[ "$PROFILE" == gnome ]] || [[ "$PROFILE" == plasma && "$(_plasma_mode 2>/dev/null)" == login ]]; then
  OUT1=$(desk_outputs list | python3 -c "import json,sys; o=json.load(sys.stdin); print(o[0]['name'] if o else '')")
  [[ -n "$OUT1" ]] || { fail "the compositor reports no output"; exit 1; }
fi

INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
enforce=$(guest_android_enforce)
[[ "$enforce" == "1" ]] \
  || { fail "Android's SELinux is not enforcing (enforce=$enforce)"; exit 1; }
boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"
SS_PID_START=$(system_server_pid "$INIT")
android_sh "$INIT" "logcat -c" >/dev/null 2>&1

android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
log "    held awake: $(wait_device_awake "$INIT")"

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

wm_displays=$(android_sh "$INIT" "dumpsys window displays")
forced=$(forced_size_displays <<<"$wm_displays"); forced_rc=$?
(( forced_rc == 0 )) || fail "could not read dumpsys window displays"
[[ -z "$forced" ]] || fail "display(s) $(tr '\n' ' ' <<<"$forced")are at a forced size (base= differs from init= in dumpsys window displays) -- clear it with 'wm size reset -d <id>'"


step "1. install the two test apps"
../../vm/boot/adb-tunnel.sh up >"$EV/adb.log" 2>&1 || { fail "adb-tunnel.sh up failed"; exit 1; }
for apk in rhizo-winapp.apk rhizo-winapp2.apk; do
  timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$VAR_DIR/share/$apk" "/data/local/tmp/$apk" >/dev/null \
    || { fail "adb push of $apk failed"; exit 1; }
  out=$(ANDROID_SH_TIMEOUT=180 android_sh "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/$apk")
  grep -qx "Success" <<<"$out" || { fail "pm install of $apk did not print 'Success': $out"; exit 1; }
done
pkglist=$(android_sh "$INIT" "pm list packages")
grep -qx "package:$APP_PKG" <<<"$pkglist" || { fail "$APP_PKG missing from pm list packages"; exit 1; }
grep -qx "package:$APP2_PKG" <<<"$pkglist" || { fail "$APP2_PKG missing from pm list packages"; exit 1; }
pass "both apps installed"


# launch an app through rhizo-launch.sh
launch_app() {
  ssh_vm -t 150 "/usr/lib/rhizo/tools/rhizo-launch.sh $1 $2 > /tmp/test-window-launch.out 2>&1" >/dev/null 2>&1
  ssh_vm -t 15 "grep -a 'cdisplay=' /run/rhizo-launch/rhizo-launch.log | tail -1"
}

if wait_guest 120 "test -e /run/rhizo-display-pool/ready || journalctl -b -q -t rhizo-display-pool 2>/dev/null | grep -q 'stage=done\|attempt 5'"; then
  log "    boot prime settled: $(gcmd_user 'cat /run/rhizo-display-pool/ready 2>/dev/null || journalctl -b -q -t rhizo-display-pool -o cat | tail -1' 15 | tr -d '\r')"
else
  log "    boot prime reported nothing in 120s -- launching anyway"
fi

step "2. launch both apps, each on its own display"

# save a guest read with its command and status
appsync_guest_read() {
  local name="$1" cmd="$2" timeout_s="${3:-30}" out rc
  out=$(ssh_vm -t "$timeout_s" "$cmd" 2>&1); rc=$?
  [[ -n "${out//[[:space:]]/}" ]] || out="<none>"
  printf '# %s\n# read status: rc=%s\n%s\n' "$cmd" "$rc" "$out" > "$EV/$name"
}

# collect the app-sync failure evidence
appsync_failure_evidence() {
  appsync_guest_read appsync-journal.txt \
    "journalctl -b -u rhizo-app-events.service -u rhizo-resync.path -u rhizo-resync.service -u rhizo-resync-rearm.service -o short-precise --no-pager" 60
  appsync_guest_read appsync-units.txt \
    "systemctl status --no-pager -l rhizo-app-events.service rhizo-resync.path rhizo-resync.service"
  appsync_guest_read appsync-applications-dir.txt "ls -la /usr/share/applications/"
  appsync_guest_read appsync-trigger-stat.txt "stat /run/rhizo-app-events/trigger"
  appsync_guest_read appsync-data-app.txt "ls -la /run/rhizo/data/app"
}

# write the evidence on the passing path too
appsync_evidence_none() {
  local name
  for name in "${APPSYNC_EV_FILES[@]}"; do
    echo "<none> -- both .desktop entries appeared" > "$EV/$name"
  done
}

appsync_failed=0
for pkg in "$APP_PKG" "$APP2_PKG"; do
  wait_guest 120 "test -r /usr/share/applications/rhizo-$pkg.desktop" \
    || { fail "no .desktop entry was ever synthesized for $pkg"; appsync_failed=1; }
done
if (( appsync_failed )); then
  appsync_failure_evidence
  log "    app-sync failure evidence collected: ${APPSYNC_EV_FILES[*]} under $EV"
else
  appsync_evidence_none
fi
l1=$(launch_app "$APP_PKG" "$APP_ACT");  echo "$l1" > "$EV/launch-1.txt"
D1=$(grep -o 'cdisplay=[0-9]*' <<<"$l1" | head -1 | cut -d= -f2)
[[ -n "$D1" ]] || { fail "rhizo-launch.sh reported no composer display for $APP_PKG"; exit 1; }
l2=$(launch_app "$APP2_PKG" "$APP2_ACT"); echo "$l2" > "$EV/launch-2.txt"
D2=$(grep -o 'cdisplay=[0-9]*' <<<"$l2" | head -1 | cut -d= -f2)
[[ -n "$D2" ]] || { fail "rhizo-launch.sh reported no composer display for $APP2_PKG"; exit 1; }
[[ "$D1" != "$D2" ]] || { fail "both apps landed on composer display $D1"; exit 1; }
# collect the views of a window that never mapped
window_map_evidence() {
  rhizo_ctl "$INIT" display toplevel "$2" >/dev/null 2>&1
  rhizo_ctl_out "$INIT" | grep -a "^display toplevel id=$2 " | tail -1 > "$EV/$1-composer-toplevel.txt"
  rhizo_ctl "$INIT" display list >/dev/null 2>&1
  rhizo_ctl_out "$INIT" | grep -a '^display list' | tail -1 >> "$EV/$1-composer-toplevel.txt"
  ssh_vm -t 25 "dmesg | grep -aiE 'never presented|display claim|CreateDisplay FAILED|display add ' | tail -30" \
    > "$EV/$1-composer-klog.txt" 2>&1
  android_sh "$INIT" "dumpsys SurfaceFlinger" 2>/dev/null | head -200 \
    > "$EV/$1-surfaceflinger.txt" 2>&1
  android_sh "$INIT" "dumpsys display" 2>/dev/null \
    > "$EV/$1-dumpsys-display.txt" 2>&1
  android_sh "$INIT" "dumpsys window displays" 2>/dev/null \
    > "$EV/$1-window-displays.txt" 2>&1
  android_sh "$INIT" "dumpsys gfxinfo com.rhizo.$1 2>/dev/null | grep -aiE 'Total frames|Janky|^\\*\\* Graphics'" \
    > "$EV/$1-gfxinfo.txt" 2>&1
  log "      $1 frames rendered: $(grep -aiE 'Total frames' "$EV/$1-gfxinfo.txt" 2>/dev/null | head -1 | tr -s ' ' || echo 'no answer')"
  android_sh "$INIT" "dumpsys SurfaceFlinger --list" 2>/dev/null \
    > "$EV/$1-sf-layers.txt" 2>&1
  android_sh "$INIT" "logcat -d -b all" 2>/dev/null \
    | grep -a "dropping display from outputs" | tail -20 \
    > "$EV/$1-layerstack-drop.txt" 2>&1
  android_sh "$INIT" "dumpsys SurfaceFlinger --scheduler" 2>/dev/null | head -80 \
    > "$EV/$1-sf-scheduler.txt" 2>&1
  if [[ -s "$EV/$1-layerstack-drop.txt" ]]; then
    log "    SurfaceFlinger DROPPED this display for a layer-stack collision: $(tail -1 "$EV/$1-layerstack-drop.txt")"
  else
    log "    no layer-stack collision logged"
  fi
  log "    composer says: $(cat "$EV/$1-composer-toplevel.txt" | head -1)"
  log "    claim/present klog in $EV/$1-composer-klog.txt"
}
# log why an app's task is not visible on its display
cause_a_evidence() {
  local tag="$1" full="${2:-}" pre="$EV/causeA-$1"
  android_sh "$INIT" "dumpsys activity activities" > "$pre-activities.txt" 2>&1
  android_sh "$INIT" "dumpsys window displays" > "$pre-window-displays.txt" 2>&1
  android_sh "$INIT" "dumpsys window" 2>/dev/null \
    | grep -aE 'mTopFocusedDisplayId=|mCurrentFocus=|mFocusedApp=|Display: mDisplayId=|mObscuringWindow=' \
    > "$pre-focus.txt"
  android_sh "$INIT" "dumpsys power" 2>/dev/null \
    | grep -aE 'mWakefulness=|mStayOn=|mStayOnWhilePluggedInSetting=|mScreenOffTimeoutSetting=' \
    > "$pre-power.txt"
  ssh_vm -t 15 "tail -200 /run/rhizo-launch/rhizo-launch.log" > "$pre-launch-log.txt" 2>&1
  log "    [causeA $tag] $(grep -aoE 'mTopFocusedDisplayId=-?[0-9]+' "$pre-focus.txt" | head -1) $(grep -aoE 'mWakefulness=[A-Za-z]+' "$pre-power.txt" | head -1); app records: $(awk '
      /ActivityRecord\{/ { app = ""; if (match($0, /com\.rhizo\.winapp2?\//)) app = substr($0, RSTART, RLENGTH - 1) }
      app != "" && match($0, /mVisibleRequested=[a-z]+/) { out[app] = out[app] " " substr($0, RSTART, RLENGTH) }
      app != "" && match($0, /nowVisible=[a-z]+/) { out[app] = out[app] " " substr($0, RSTART, RLENGTH) }
      app != "" && match($0, /(^|[[:space:]])state=[A-Z_]+/) { out[app] = out[app] " " substr($0, RSTART, RLENGTH) }
      END { for (a in out) printf "%s:%s; ", a, out[a] }' "$pre-activities.txt")"
  [[ "$full" == full ]] || return 0
  android_sh "$INIT" "dumpsys SurfaceFlinger --display-id" > "$pre-sf-display-id.txt" 2>&1
  android_sh "$INIT" "dumpsys SurfaceFlinger" 2>/dev/null \
    | grep -aE '^Display [0-9]+ \(|layerFilter=' > "$pre-sf-layerfilter.txt"
  rhizo_ctl_display_list "$INIT" > "$pre-composer-display-list.txt" 2>&1
  android_sh "$INIT" "cat /data/local/tmp/rhizo-layerstack-guard.log" > "$pre-guard-log.txt" 2>&1
  log "    [causeA $tag] SurfaceFlinger layer stacks: $(grep -aoE 'layerStack=[0-9]+' "$pre-sf-layerfilter.txt" | tr '\n' ' '); composer: $(head -1 "$pre-composer-display-list.txt")"
}
rm -f "$EV"/causeA-*
assert_window_painted winapp "$D1" || { window_map_evidence winapp "$D1"; exit 1; }
assert_window_painted winapp2 "$D2" || { window_map_evidence winapp2 "$D2"; exit 1; }
log "    $APP_PKG on composer display $D1, $APP2_PKG on $D2"
cause_a_evidence after-step2


step "3. identity: two apps, two toplevels a dock could tell apart"
j1=$(win_json "$D1") || fail "no toplevel in the compositor's tree for display $D1"
j2=$(win_json "$D2") || fail "no toplevel in the compositor's tree for display $D2"
echo "$j1" > "$EV/identity-1.json"; echo "$j2" > "$EV/identity-2.json"
if [[ -n "$j1" && -n "$j2" ]]; then
  a1=$(st "$(python3 -c "import json,sys; print(json.load(sys.stdin)['app_id'])" <<<"$j1")")
  a2=$(st "$(python3 -c "import json,sys; print(json.load(sys.stdin)['app_id'])" <<<"$j2")")
  t1=$(st "$(python3 -c "import json,sys; print(json.load(sys.stdin)['name'])" <<<"$j1")")
  t2=$(st "$(python3 -c "import json,sys; print(json.load(sys.stdin)['name'])" <<<"$j2")")
  log "    window 1: app_id='$a1' title='$t1'"
  log "    window 2: app_id='$a2' title='$t2'"
  [[ "$a1" != "$a2" ]] || fail "both toplevels carry the same app_id '$a1'"
  [[ "$t1" != "$t2" ]] || fail "both toplevels carry the same title '$t1'"
  [[ "$a1" == *"$APP_PKG"* ]]  || fail "window 1's app_id '$a1' does not name $APP_PKG"
  [[ "$a2" == *"$APP2_PKG"* ]] || fail "window 2's app_id '$a2' does not name $APP2_PKG"
  lbl1=$(python3 -c "import json;print(json.load(open('$VAR_DIR/share/rhizo-winapp.json'))['label'])" 2>/dev/null)
  lbl2=$(python3 -c "import json;print(json.load(open('$VAR_DIR/share/rhizo-winapp2.json'))['label'])" 2>/dev/null)
  if [[ -n "$lbl1" && -n "$lbl2" ]]; then
    [[ "$t1" == "$lbl1" ]] || fail "window 1's title '$t1' is not the app's own label '$lbl1'"
    [[ "$t2" == "$lbl2" ]] || fail "window 2's title '$t2' is not the app's own label '$lbl2'"
  else
    fail "neither APK sidecar carried an application label"
  fi
  pass "each window carries its own app_id and its own app's label"
fi


step "3b. a touch on the app's own display arrives as a touchscreen event"
touch_nonce=$(nonce)
app_ping "$APP_PKG" "$touch_nonce"
app_token RHIZO_ALIVE "$touch_nonce" 30 >/dev/null \
  || fail "$APP_PKG stopped answering before the touch leg"
app_cmd "$APP_PKG" "$APP_ACT" "$touch_nonce" "--es cmd win_info"
tinfo=$(app_token RHIZO_WIN_INFO "$touch_nonce" 30)
if [[ -z "$tinfo" ]]; then
  fail "$APP_PKG never reported its display size"
  cause_a_evidence step3b-no-win-info full
else
  tsize=$(task_size "$(field "$tinfo" display)")
  [[ "$tsize" =~ ^[0-9]+x[0-9]+$ ]] || fail "could not read $APP_PKG's freeform task bounds (got '${tsize:-none}')"
  TW=${tsize%x*}; TH=${tsize#*x}
  TX=$(( ${TW:-0} / 2 )); TY=$(( ${TH:-0} / 2 ))
  before_inject=$(rhizo_ctl_out "$INIT" | grep -c 'inject-failed')
  rhizo_ctl "$INIT" inject touch down "$(st_disp "$D1")" "$TX" "$TY" >/dev/null 2>&1
  rhizo_ctl "$INIT" inject touch up "$(st_disp "$D1")" >/dev/null 2>&1
  after_inject=$(rhizo_ctl_out "$INIT" | grep -c 'inject-failed')
  if (( after_inject > before_inject )); then
    fail "the composer refused the injection: $(rhizo_ctl_out "$INIT" | grep 'inject-failed' | tail -1)"
  fi
  tline=$(app_token RHIZO_POINTER "$touch_nonce" 30)
  if [[ -z "$tline" ]]; then
    fail "a touch at $TX,$TY on display $D1 reached no MotionEvent in the app at all"
    cause_a_evidence step3b-no-touch full
    rhizo_ctl_out "$INIT" | tail -5 | sed 's/^/    | /'
  else
    tvia=$(st "$(field "$tline" via)")
    [[ "$tvia" == "touch" ]] \
      || fail "the app received the event through '$tvia', not its touch handler"
    tsrc=$(st_zero "$(field "$tline" source)")
    (( (${tsrc:-0} & 0x1000) != 0 )) \
      || fail "the app reports source=$tsrc, no SOURCE_CLASS_POINTER touchscreen bit"
    (( (${tsrc:-0} & 0x2000) == 0 )) \
      || fail "the app reports source=$tsrc, the mouse, not the touchscreen"
    trx=$(st_zero "$(field "$tline" rawX)"); try=$(st_zero "$(field "$tline" rawY)")
    log "    touched $TX,$TY on display $D1; the app received raw $trx,$try source=$tsrc"
    awk -v a="${trx:-0}" -v b="$TX" 'BEGIN{exit !(a-b<8 && b-a<8)}' \
      || fail "the touch landed at rawX=$trx, $TX was asked for"
    awk -v a="${try:-0}" -v b="$TY" 'BEGIN{exit !(a-b<8 && b-a<8)}' \
      || fail "the touch landed at rawY=$try, $TY was asked for"
    pass "a real touch on the composer's own touchscreen reached the app where it was aimed"
  fi
fi


step "4. fullscreen and restore, driven from the host"
base=$(win_json "$D1")
BASE_W=$(python3 -c "import json,sys; print(json.load(sys.stdin)['w'])" <<<"$base")
BASE_H=$(python3 -c "import json,sys; print(json.load(sys.stdin)['h'])" <<<"$base")
BASE_X=$(python3 -c "import json,sys; print(json.load(sys.stdin)['x'])" <<<"$base")
BASE_Y=$(python3 -c "import json,sys; print(json.load(sys.stdin)['y'])" <<<"$base")
[[ -n "$BASE_W" && -n "$BASE_H" && -n "$BASE_X" && -n "$BASE_Y" ]] \
  || fail "could not read $APP_PKG's window rect before the fullscreen leg (got '${base:-nothing}')"
read -r OUT_W OUT_H <<<"$(desk_outputs list | python3 -c "
import json,sys
o=[x for x in json.load(sys.stdin) if x['name']=='$OUT1'][0]['rect']
print(o['width'], o['height'])
")"
d1_id=$(display_window_id "$D1")
fs_nonce=$(nonce)
app_cmd "$APP_PKG" "$APP_ACT" "$fs_nonce" "--es cmd set_color --es rgb 20A020"
[[ -n "$d1_id" ]] && desk_window_op "$d1_id" fullscreen
read -r gw gh <<<"$(wait_win_size "$D1" "$OUT_W" "$OUT_H" 40)"
gw=$(st_num "$gw")
[[ "$gw" == "$OUT_W" && "$gh" == "$OUT_H" ]] \
  || fail "fullscreen: the compositor reports the window ${gw}x${gh}, the output is ${OUT_W}x${OUT_H}"
fsmode=$(win_field "$D1" fullscreen_mode)
[[ "$fsmode" == "1" ]] || fail "fullscreen: the compositor reports fullscreen_mode=$fsmode, not 1"
info=$(wait_app_field RHIZO_WIN_INFO "$fs_nonce" w "$OUT_W" 45) \
  || fail "fullscreen: the app's content view never became ${OUT_W} wide (its last report: ${info:-none})"
if [[ -n "$info" ]]; then
  arw=$(field "$info" realw); arh=$(field "$info" realh)
  aw=$(st_num "$(field "$info" w)"); ah=$(field "$info" h)
  fcap=$(caption_px "$D1") || fail "fullscreen: the composer did not report display $D1's scale"
  want_task="${OUT_W}x$(( OUT_H + ${fcap:-0} ))"
  ftask=$(wait_task_size "$(field "$info" display)" "$want_task" 20)
  log "    app reports its display ${arw}x${arh}, its content view ${aw}x${ah} and its task ${ftask}; compositor reports ${gw}x${gh}"
  [[ "$(st "$ftask")" == "$want_task" ]] \
    || fail "fullscreen: the app's freeform task is ${ftask}, the output plus Android's caption is ${want_task}"
  [[ "$aw" == "$OUT_W" ]] \
    || fail "fullscreen: the app's content view is ${aw} wide, the output is ${OUT_W}"
fi
desk_shot /tmp/wg4.png >/dev/null && pull /tmp/wg4.png "$EV/4-fullscreen.png"
st_png "$EV/4-fullscreen.png"
fsrect=$(win_json "$D1")
read -r fx fy fw fh <<<"$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['x'],d['y'],d['w'],d['h'])" <<<"$fsrect")"
nb=0
for _ in $(seq 1 20); do
  desk_shot /tmp/wg4.png >/dev/null && pull /tmp/wg4.png "$EV/4-fullscreen.png"
  nb=$(python3 ../tools/pngstat.py "$EV/4-fullscreen.png" --region "$fx,$fy,$fw,$fh" | grep '^nonblack_pct=' | cut -d= -f2)
  awk -v v="${nb:-0}" 'BEGIN{exit !(v>50)}' && break
  sleep 1
done
awk -v v="${nb:-0}" 'BEGIN{exit !(v>50)}' \
  || fail "fullscreen: the window's own rect is ${nb}% non-black after 20s"
[[ -n "$d1_id" ]] && desk_window_op "$d1_id" unfullscreen
read -r rw rh <<<"$(wait_win_size "$D1" "$BASE_W" "$BASE_H" 40)"
rw=$(st_num "$rw")
[[ "$rw" == "$BASE_W" && "$rh" == "$BASE_H" ]] \
  || fail "restore: the window came back ${rw}x${rh}, not its original ${BASE_W}x${BASE_H}"
pass "fullscreen and restore both moved the window, the display and the app's own frame"

step "5. maximize and restore, driven from the host"
max_nonce=$(nonce)
app_cmd "$APP_PKG" "$APP_ACT" "$max_nonce" "--es cmd set_color --es rgb A02020"
DECO_H=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('decoration_h', 0))" <<<"$(win_json "$D1")" 2>/dev/null)
MAX_W=$OUT_W; MAX_H=$(( OUT_H - ${DECO_H:-0} ))
read -r WORK_W WORK_H <<<"$(_desktop_window_for_display "$D1" 0 | python3 -c "
import json,sys
a=json.load(sys.stdin).get('work_area') or {}
print(a.get('w', ''), a.get('h', ''))")"
[[ -n "$WORK_W" && -n "$WORK_H" ]] && { MAX_W=$WORK_W; MAX_H=$WORK_H; }
[[ -n "$d1_id" ]] && desk_window_op "$d1_id" maximize
read -r mw mh <<<"$(wait_win_size "$D1" "$MAX_W" "$MAX_H" 40)"
mw=$(st_num "$mw")
[[ "$mw" == "$MAX_W" && "$mh" == "$MAX_H" ]] \
  || fail "maximize: the compositor reports the window ${mw}x${mh}, want ${MAX_W}x${MAX_H} (the output is ${OUT_W}x${OUT_H}, a ${DECO_H:-0}px titlebar, work area ${WORK_W:-none}x${WORK_H:-none})"
minfo=$(wait_app_field RHIZO_WIN_INFO "$max_nonce" w "$MAX_W" 45) \
  || fail "maximize: the app's content view never became ${MAX_W} wide (its last report: ${minfo:-none})"
if [[ -n "$minfo" ]]; then
  maw=$(st_num "$(field "$minfo" w)")
  [[ "$maw" == "$MAX_W" ]] || fail "maximize: the app reports its content view ${maw} wide, the window is $MAX_W"
fi
rest_nonce=$(nonce)
app_cmd "$APP_PKG" "$APP_ACT" "$rest_nonce" "--es cmd set_color --es rgb 2060A0"
if [[ -n "$d1_id" ]]; then
  desk_window_op "$d1_id" unmaximize
  desk_window_op "$d1_id" resize "$BASE_W" "$BASE_H"
fi
read -r umw umh <<<"$(wait_win_size "$D1" "$BASE_W" "$BASE_H" 40)"
umw=$(st_num "$umw")
[[ "$umw" == "$BASE_W" && "$umh" == "$BASE_H" ]] \
  || fail "restore from maximized: the window came back ${umw}x${umh}, not ${BASE_W}x${BASE_H}"
rinfo=$(wait_app_field RHIZO_WIN_INFO "$rest_nonce" w "$BASE_W" 45) \
  || fail "restore from maximized: the app's content view never came back to ${BASE_W} wide (its last report: ${rinfo:-none})"
pass "maximize and restore both reached the app"


step "6. a second output: the window keeps painting there and a click lands where the app expects"
new_out=$(desk_outputs add "$SECOND_MODE")
[[ -n "$new_out" ]] || fail "the compositor never produced a second output"
if [[ -n "$new_out" && "$new_out" != "$OUT2" ]]; then
  log "    new output is $new_out, expected $OUT2 -- continuing with the real name"
  OUT2=$new_out
fi
d1_id=$(display_window_id "$D1")
[[ -n "$d1_id" ]] && desk_window_op "$d1_id" to_monitor "$OUT2"
for _i in $(seq 1 20); do
  desk_windows 2>/dev/null | grep -q "\"monitor\": \"$OUT2\"" && break
  sleep 1
done
o2shot=/tmp/wg6.png
desk_shot "$o2shot" "" "$OUT2" >/dev/null && pull "$o2shot" "$EV/6-second-output.png"
st_png "$EV/6-second-output.png"
j6=$(win_json "$D1")
read -r wx wy ww wh <<<"$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['x'],d['y'],d['w'],d['h'])" <<<"$j6")"
read -r o2x o2y <<<"$(desk_outputs list | python3 -c "
import json,sys
o=[x for x in json.load(sys.stdin) if x.get('name') == sys.argv[1]]
print(o[0]['rect']['x'], o[0]['rect']['y']) if o else print('')" "$OUT2" 2>/dev/null)"
[[ -n "$o2x" && -n "$o2y" ]] || fail "the compositor reports no rect for $OUT2"
reg6="$(( ${wx:-0} - ${o2x:-0} )),$(( ${wy:-0} - ${o2y:-0} )),${ww:-0},${wh:-0}"
st6=$(python3 ../tools/pngstat.py "$EV/6-second-output.png" --region "$reg6")
nb2=$(grep '^nonblack_pct=' <<<"$st6" | cut -d= -f2)
dis2=$(grep '^distinct=' <<<"$st6" | cut -d= -f2)
log "    window on $OUT2 at output-local $reg6: ${nb2:-?}% non-black, ${dis2:-?} colors"
awk -v v="${nb2:-0}" 'BEGIN{exit !(v>50)}' \
  || fail "the window paints nothing on $OUT2 (${nb2:-?}% non-black inside its ${ww:-?}x${wh:-?} rect)"
[[ "${dis2:-0}" -gt 20 ]] \
  || fail "the window on $OUT2 is a flat fill (${dis2:-?} colors inside its rect)"
TX=$(( wx + ww / 3 )); TY=$(( wy + wh / 3 ))
ccap=$(caption_px "$D1") || fail "the composer did not report display $D1's scale"
EXP_X=$(( ww / 3 )); EXP_Y=$(( wh / 3 + ${ccap:-0} ))
click_nonce=$(nonce)
app_ping "$APP_PKG" "$click_nonce"
app_token RHIZO_ALIVE "$click_nonce" 30 >/dev/null || fail "the app stopped answering before the click leg"
desktop_inject_click "$TX" "$TY" || fail "the injector refused the click"
ptr=$(wait_app_field RHIZO_POINTER "$click_nonce" via touch 30) || ptr=""
[[ -n "$ptr" ]] || fail "the app's view reported no touch for a click on $OUT2 (its pointer reports this leg: $(app_token RHIZO_POINTER "$click_nonce" 1 || echo none))"
if [[ -n "$ptr" ]]; then
  gx=$(st_num "$(field "$ptr" rawX)"); gy=$(st_num "$(field "$ptr" rawY)")
  log "    clicked layout ${TX},${TY} in a window at ${wx},${wy} ${ww}x${wh}; app received ${gx},${gy} (view $(field "$ptr" x),$(field "$ptr" y)), expected about ${EXP_X},${EXP_Y}"
  awk -v g="${gx%%.*}" -v e="$EXP_X" 'BEGIN{exit !(g-e<24 && e-g<24)}' \
    || fail "the click landed at x=$gx in the app, not near $EXP_X"
  awk -v g="${gy%%.*}" -v e="$EXP_Y" 'BEGIN{exit !(g-e<24 && e-g<24)}' \
    || fail "the click landed at y=$gy in the app, not near $EXP_Y"
fi
pass "the window paints on the second output and a click lands where the app expects"


step "7. an output scale the app has not seen: real pixels, not an upscale"
SCALED_W=960 SCALED_H=540
d1_id=$(display_window_id "$D1")
[[ -n "$d1_id" ]] && desk_window_op "$d1_id" resize "$SCALED_W" "$SCALED_H"
read -r O2X O2Y <<<"$(desk_outputs list | python3 -c "
import json,sys
o=[x for x in json.load(sys.stdin) if x['name']=='$OUT2'][0]['rect']
print(o['x'], o['y'])
")"
[[ -n "$d1_id" ]] && desk_window_op "$d1_id" to_monitor "$OUT2"
on_out2=""
for _i in $(seq 1 20); do
  rhizo_ctl "$INIT" display toplevel "$D1" >/dev/null 2>&1
  ctop=$(rhizo_ctl_out "$INIT" | grep "^display toplevel id=$D1 " | tail -1)
  [[ "$ctop" == *"output=$OUT2"* ]] && { on_out2=1; break; }
  sleep 1
done
log "    composer's own view before the scale change: ${ctop:-no answer}"
[[ -n "$on_out2" ]] \
  || fail "scale: the composer does not have this window on $OUT2 (${ctop:-no answer})"

base_nonce=$(nonce)
app_cmd "$APP_PKG" "$APP_ACT" "$base_nonce" "--es cmd win_info"
binfo=$(wait_app_field RHIZO_WIN_INFO "$base_nonce" w "$SCALED_W" 45) \
  || fail "scale: the app never reported the ${SCALED_W}px window it has before the scale change (last: ${binfo:-none})"
dens_out=$(android_sh "$INIT" "wm density -d $(field "$binfo" display)" 2>/dev/null)
grep -q "Override density" <<<"$dens_out" \
  && fail "a density override is set on this display ($dens_out)"
BASE_PX=$(field "$binfo" w)
BASE_REALW=$(st_num "$(field "$binfo" realw)")
BASE_DENSITY=$(field "$binfo" density)
BASE_DP=$(awk -v p="${BASE_PX:-0}" -v d="${BASE_DENSITY:-0}" 'BEGIN{ if (d>0) printf "%.1f", p/d; else print 0 }')
log "    before the scale change the app reports ${BASE_PX}px at density ${BASE_DENSITY} (${BASE_DP}dp wide)"

# the app reports its new size before Android's resize transition finishes cropping its window
read -r s7w s7h <<<"$(wait_win_size "$D1" "$SCALED_W" "$SCALED_H" 40)"
[[ "$(st_num "$s7w")" == "$SCALED_W" && "$s7h" == "$SCALED_H" ]] \
  || fail "scale: the window never settled at the ${SCALED_W}x${SCALED_H} it was resized to (it reads ${s7w}x${s7h})"
W0=$(python3 -c "import json,sys; print(json.load(sys.stdin)['w'])" <<<"$(win_json "$D1")" 2>/dev/null)
desk_outputs scale "$OUT2" 2

comp_scaled=""
for _i in $(seq 1 20); do
  rhizo_ctl "$INIT" display toplevel "$D1" >/dev/null 2>&1
  ctop=$(rhizo_ctl_out "$INIT" | grep "^display toplevel id=$D1 " | tail -1)
  [[ "$ctop" == *"scale=2"* ]] && { comp_scaled=1; break; }
  sleep 1
done
log "    composer's own view of the window: ${ctop:-no answer}"
[[ -n "$comp_scaled" ]] \
  || fail "the composer never saw $OUT2's scale change (${ctop:-no answer})"

# Android may apply the scale before the nonce reaches the app: query again until a report has the doubled density
scale_nonce=$(nonce)
WANT_SDENSITY=$(awk -v d="${BASE_DENSITY:-0}" 'BEGIN{printf "%g", d*2}')
sinfo=""
sdeadline=$(( SECONDS + 60 ))
while (( SECONDS < sdeadline )); do
  app_cmd "$APP_PKG" "$APP_ACT" "$scale_nonce" "--es cmd win_info"
  scale_hit=$(wait_app_field RHIZO_WIN_INFO "$scale_nonce" density "$WANT_SDENSITY" 3) && { sinfo=$scale_hit; break; }
  [[ -n "$scale_hit" ]] && sinfo=$scale_hit
done
if [[ -z "$sinfo" ]]; then
  fail "scale: the app never reported a window after the scale change"
else
  sw=$(st_num "$(field "$sinfo" w)"); sh=$(field "$sinfo" h)
  sdensity=$(st_zero "$(field "$sinfo" density)")
  sdp=$(awk -v p="${sw:-0}" -v d="${sdensity:-0}" 'BEGIN{ if (d>0) printf "%.1f", p/d; else print 0 }')
  log "    app reports its content view ${sw}x${sh} at density ${sdensity} (${sdp}dp wide) on a scale-2 output"
  W1=$(python3 -c "import json,sys; print(json.load(sys.stdin)['w'])" <<<"$(win_json "$D1")" 2>/dev/null)
  WIN_RATIO=$(awk -v a="${W1:-0}" -v b="${W0:-0}" 'BEGIN{ if (b>0) printf "%.3f", a/b; else print 0 }')
  WANT_PX=$(awk -v p="${BASE_PX:-0}" -v r="$WIN_RATIO" 'BEGIN{ printf "%d", p * r * 2 + 0.5 }')
  log "    the window is ${W1} logical px wide at scale 2 against ${W0} at scale 1 (ratio ${WIN_RATIO}); want ${WANT_PX}px"
  awk -v r="$WIN_RATIO" 'BEGIN{ exit !(r > 0.45 && r < 0.55 || r > 0.95 && r < 1.05) }' \
    || fail "scale: the window went from ${W0} to ${W1} logical px wide, want half or the same"
  awk -v a="${sw:-0}" -v b="$WANT_PX" 'BEGIN{ exit !(b > 0 && a >= b - 2 && a <= b + 2) }' \
    || fail "scale: the app's content view is ${sw}px wide where a ${W1}-px window at scale 2 is ${WANT_PX}px (it was ${BASE_PX}px)"
  awk -v a="${sdensity:-0}" -v b="${BASE_DENSITY:-0}" \
    'BEGIN{ exit !(b > 0 && a > b * 1.8 && a < b * 2.2) }' \
    || fail "scale: the app reports density ${sdensity} on a scale-2 output against ${BASE_DENSITY} before it"
  awk -v a="${sdp:-0}" -v b="${BASE_DP:-0}" -v r="$WIN_RATIO" \
    'BEGIN{ exit !(b > 0 && a > b * r * 0.8 && a < b * r * 1.2) }' \
    || fail "scale: the app lays out ${sdp}dp wide where it laid out ${BASE_DP}dp (window ratio ${WIN_RATIO})"
fi

# the checkerboard rect is reported on a color change: take one drawn after the density doubled
draw_nonce=$(nonce)
app_cmd "$APP_PKG" "$APP_ACT" "$draw_nonce" "--es cmd set_color --es rgb 40A060"
draw=$(app_token RHIZO_DRAW "$draw_nonce" 45)
desk_shot /tmp/wg7.png "" "$OUT2" >/dev/null && pull /tmp/wg7.png "$EV/7-scale.png"
st_png "$EV/7-scale.png"
if [[ -n "$draw" ]]; then
  crx=$(field "$draw" rectX); cry=$(field "$draw" rectY)
  crw=$(field "$draw" rectW); crh=$(field "$draw" rectH)
  js=$(win_json "$D1")
  read -r sx sy <<<"$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['x'],d['y'])" <<<"$js")"
  # app window coordinates include the freeform caption
  cap7=$(caption_px "$D1") || fail "scale: the composer did not report display $D1's scale"
  PX=$(( (sx - O2X) * 2 + crx )); PY=$(( (sy - O2Y) * 2 + cry - ${cap7:-0} ))
  if [[ -n "$crw" && -n "$crh" ]]; then
    python3 ../tools/mkpattern.py --checker "$crw" "$crh" "$WORKDIR/ref.png" \
      || fail "could not generate the reference checkerboard"
    d=$(python3 ../tools/pngstat.py --diff "$EV/7-scale.png" "$WORKDIR/ref.png" \
        --region "$PX,$PY,$crw,$crh" --region2 "0,0,$crw,$crh" \
        | grep '^changed_pct=' | cut -d= -f2)
    log "    checkerboard at ${PX},${PY} ${crw}x${crh}: ${d}% of pixels differ from a native-resolution reference"
    awk -v v="${d:-100}" 'BEGIN{exit !(v<8)}' \
      || fail "scale: ${d}% of the checkerboard differs from a native reference"
  else
    fail "scale: the app's checkerboard report carried no rectangle ($draw)"
  fi
else
  fail "scale: the app never reported where it drew its checkerboard"
fi
pass "the window renders at the output's own pixel density, and the app knows it"
desk_outputs scale "$OUT2" 1
if [[ -n "$d1_id" ]]; then
  desk_window_op "$d1_id" to_monitor "$OUT1"
  desk_window_op "$d1_id" resize "$BASE_W" "$BASE_H"
fi
restored=""
for _i in $(seq 1 20); do
  [[ -n "$d1_id" ]] && desk_window_op "$d1_id" move "$BASE_X" "$BASE_Y" >/dev/null 2>&1
  read -r rsx rsy rsw rsh <<<"$(desktop_window_rect "$D1")"
  [[ -n "${rsh:-}" && "$rsx" == "$BASE_X" && "$rsy" == "$BASE_Y" && "$rsw" == "$BASE_W" && "$rsh" == "$BASE_H" ]] \
    && { restored=1; break; }
  sleep 0.5
done
[[ -n "$restored" ]] \
  || fail "scale: after the restore the window reads ${rsx:-?},${rsy:-?} ${rsw:-?}x${rsh:-?}, not ${BASE_X},${BASE_Y} ${BASE_W}x${BASE_H}"

if [[ "$PROFILE" == plasma || "$PROFILE" == sway ]]; then
  step "7b. a fractional output scale: the app's pixels and density follow 1.5 and 1.25"
  STEP7B_FAILED_AT=$FAILED
  for fs in 1.5 1.25; do
    [[ -n "$d1_id" ]] && desk_window_op "$d1_id" to_monitor "$OUT2"
    for _i in $(seq 1 20); do
      desk_windows 2>/dev/null | grep -q "\"monitor\": \"$OUT2\"" && break
      sleep 0.5
    done
    WF0=$(python3 -c "import json,sys; print(json.load(sys.stdin)['w'])" <<<"$(win_json "$D1")" 2>/dev/null)
    desk_outputs scale "$OUT2" "$fs"
    ctop=""
    for _i in $(seq 1 20); do
      rhizo_ctl "$INIT" display toplevel "$D1" >/dev/null 2>&1
      ctop=$(rhizo_ctl_out "$INIT" | grep "^display toplevel id=$D1 " | tail -1)
      [[ "$ctop" == *" scale=$fs "* ]] && break
      sleep 1
    done
    log "    composer's own view at $fs: ${ctop:-no answer}"
    [[ "$ctop" == *" scale=$fs "* ]] \
      || fail "fractional $fs: the composer's window never took the scale (${ctop:-no answer})"
    WANT_FDENSITY=$(awk -v d="${BASE_DENSITY:-0}" -v f="$fs" 'BEGIN{ printf "%.4f", d * f }')
    WANT_FDISPW=$(awk -v p="${BASE_REALW:-0}" -v f="$fs" 'BEGIN{ printf "%d", p * f + 0.5 }')
    fsinfo="" fw="" fd="" WF="" WANT_FPX=0
    fdeadline=$(( SECONDS + 60 ))
    while (( SECONDS < fdeadline )); do
      WF=$(python3 -c "import json,sys; print(json.load(sys.stdin)['w'])" <<<"$(win_json "$D1")" 2>/dev/null)
      WANT_FPX=$(awk -v w="${WF:-0}" -v f="$fs" 'BEGIN{ printf "%d", w * f + 0.5 }')
      fs_nonce=$(nonce)
      app_cmd "$APP_PKG" "$APP_ACT" "$fs_nonce" "--es cmd win_info"
      sleep 2
      fsinfo=$(android_sh "$INIT" "logcat -d -b all -s RhizoWinApp:I" 2>/dev/null \
               | grep -a -o "RHIZO_WIN_INFO nonce=$fs_nonce.*" | tail -1)
      fw=$(st_num "$(field "$fsinfo" w)"); fd=$(st_zero "$(field "$fsinfo" density)")
      frw=$(st_num "$(field "$fsinfo" realw)")
      awk -v a="${fw:-0}" -v b="$WANT_FPX" -v c="${fd:-0}" -v e="$WANT_FDENSITY" -v r="${frw:-0}" -v q="$WANT_FDISPW" \
        'BEGIN{ exit !(a >= b - 2 && a <= b + 2 && c > e * 0.98 && c < e * 1.02 && r >= q - 2 && r <= q + 2) }' && break
    done
    log "    at $fs the window is ${WF:-?} logical px wide (${WF0:-?} at 1); the app's window is ${fw:-?}px at density ${fd:-?} on a ${frw:-?}px display (want ${WANT_FPX}px at ${WANT_FDENSITY} on ${WANT_FDISPW}px)"
    awk -v a="${WF:-0}" -v b="${WF0:-0}" 'BEGIN{ exit !(b > 0 && a >= b - 2 && a <= b + 2) }' \
      || fail "fractional $fs: the window is ${WF:-?} logical px wide, ${WF0:-?} at scale 1"
    awk -v a="${fw:-0}" -v b="$WANT_FPX" 'BEGIN{ exit !(b > 0 && a >= b - 2 && a <= b + 2) }' \
      || fail "fractional $fs: the app's window is ${fw:-?}px wide where a ${WF:-?}-px window at $fs is ${WANT_FPX}px"
    awk -v a="${frw:-0}" -v b="$WANT_FDISPW" 'BEGIN{ exit !(b > 0 && a >= b - 2 && a <= b + 2) }' \
      || fail "fractional $fs: the app's display is ${frw:-?}px wide where the work area at $fs is ${WANT_FDISPW}px (${BASE_REALW:-?}px at 1)"
    awk -v c="${fd:-0}" -v e="$WANT_FDENSITY" 'BEGIN{ exit !(e > 0 && c > e * 0.98 && c < e * 1.02) }' \
      || fail "fractional $fs: the app's density is ${fd:-?}, not ${WANT_FDENSITY} (${BASE_DENSITY} at scale 1, times $fs)"
    desk_outputs scale "$OUT2" 1
  done
  if [[ -n "$d1_id" ]]; then
    desk_window_op "$d1_id" to_monitor "$OUT1"
    desk_window_op "$d1_id" resize "$BASE_W" "$BASE_H"
    for _i in $(seq 1 20); do
      desk_window_op "$d1_id" move "$BASE_X" "$BASE_Y" >/dev/null 2>&1
      read -r rsx rsy rsw rsh <<<"$(desktop_window_rect "$D1")"
      [[ -n "${rsh:-}" && "$rsx" == "$BASE_X" && "$rsy" == "$BASE_Y" && "$rsw" == "$BASE_W" && "$rsh" == "$BASE_H" ]] && break
      sleep 0.5
    done
  fi
  (( FAILED == STEP7B_FAILED_AT )) \
    && pass "at 1.5 and 1.25 the app's display is the window's logical size at the output's own scale, and its density follows"
fi


step "8. the host's $HOST_LAYOUT keyboard layout reaches the app's own text field"
d1_focus_id=$(display_window_id "$D1")
[[ -n "$d1_focus_id" ]] && desk_window_op "$d1_focus_id" activate
kb_focused=""
for _i in $(seq 1 15); do
  [[ "$(win_field "$D1" focused)" == "True" ]] && { kb_focused=1; break; }
  sleep 1
done
[[ -n "$kb_focused" ]] || fail "the compositor never gave $APP_PKG's window keyboard focus"
kb_nonce=$(nonce)
app_cmd "$APP_PKG" "$APP_ACT" "$kb_nonce" "--es cmd clear_text"
kb_wake=""
for _ in $(seq 1 15); do
  case "$(android_sh "$INIT" "dumpsys power 2>/dev/null | grep -m1 -o 'mWakefulness=[A-Za-z]*'")" in
    *Awake*) kb_wake=1; break ;;
  esac
  android_sh "$INIT" "input keyevent 224; wm dismiss-keyguard" >/dev/null 2>&1
  sleep 1
done
[[ -n "$kb_wake" ]] \
  || fail "the guest will not wake (mWakefulness never reached Awake)"
log "    guest is awake before typing"

kb_af=""; kb_t0=$SECONDS; kb_last=""
for _ in $(seq 1 60); do
  android_sh "$INIT" "input keyevent 224" >/dev/null 2>&1
  app_cmd "$APP_PKG" "$APP_ACT" "$kb_nonce" "--es cmd focus_state"
  kb_last=$(app_token RHIZO_FOCUS "$kb_nonce" 3)
  [[ "$(field "$kb_last" focused)" == "true" && "$(field "$kb_last" field)" == "true" ]] \
    && { kb_af=1; break; }
  sleep 1
done
log "    android focus after $((SECONDS - kb_t0))s: ${kb_last:-no answer}"
[[ -n "$kb_af" ]] \
  || fail "$APP_PKG never reported window+field focus (last: ${kb_last:-none})"
if [[ "$PROFILE" == plasma ]]; then
  active_layout=$(_plasma_harness layouts 2>&1)
else
  active_layout=$(desk_seat_devices | python3 -c "
import json,sys
print(next((i.get('xkb_active_layout_name','') for i in json.load(sys.stdin)
            if i.get('type')=='keyboard'), 'no keyboard'))
")
fi
log "    the seat's active keyboard layout is '${active_layout}'"
grep -qi "french\|${HOST_LAYOUT}" <<<"$active_layout" \
  || fail "the compositor's own keyboard is on '${active_layout}', not $HOST_LAYOUT"
rhizo_ctl "$INIT" display keymap >/dev/null 2>&1
kmstate=$(rhizo_ctl_out "$INIT" | grep '^display keymap ' | tail -1)
log "    composer keymap state: ${kmstate:-no answer}"
[[ "$kmstate" == *"loaded=1"* ]] \
  || fail "the composer has no host keymap table (${kmstate:-no answer})"
mapfile -t layout_lines < <(python3 ../../checks/system/desktop/layout-expect.py "$HOST_LAYOUT" --ascii-only)
EXPECT="${layout_lines[0]:-}"
SEQ="${layout_lines[1]:-}"
[[ -n "$EXPECT" && -n "$SEQ" ]] || { fail "no expected text for host layout $HOST_LAYOUT"; SEQ=""; }
test_type $SEQ || fail "the injector refused the key sequence"
txt=$(app_token RHIZO_TEXT "$kb_nonce" 45)
if [[ -z "$txt" ]]; then
  txt=$(android_sh "$INIT" "logcat -d -b all -s RhizoWinApp:I" 2>/dev/null | grep -a -o "RHIZO_TEXT .*" | tail -1)
fi
[[ -n "$txt" ]] || fail "the app's text field reported nothing for the typed sequence"
if [[ -n "$txt" ]]; then
  got=$(st "$(field "$txt" b64 | base64 -d 2>/dev/null)")
  log "    typed the physical keys [$SEQ] on a $HOST_LAYOUT host; the app's field reads '$got', expected '$EXPECT'"
  [[ "$got" == "$EXPECT" ]] \
    || fail "the app's own text field reads '$got', expected '$EXPECT'"
fi
pass "the host layout's own characters arrived in the app's text field"


step "9. a chord arrives as a chord"
declare -A MOD_BIT=( [ctrl]=4096 [alt]=2 [shift]=1 )
declare -A MOD_KEY=( [ctrl]=29 [alt]=56 [shift]=42 )
for mod in ctrl alt shift; do
  ch_nonce=$(nonce)
  app_ping "$APP_PKG" "$ch_nonce"
  app_token RHIZO_ALIVE "$ch_nonce" 30 >/dev/null || { fail "the app stopped answering before the $mod chord"; break; }
  test_chord 30 "${MOD_KEY[$mod]}" || fail "the injector refused a $mod chord"
  line=$(android_sh "$INIT" "logcat -d -b all -s RhizoWinApp:I" 2>/dev/null \
         | grep -a -o "RHIZO_KEY .*event=down.*" \
         | grep -avE "keyCode=(113|114|57|58|59|60) " | tail -1)
  [[ -n "$line" ]] || { fail "the app reported no non-modifier key-down for the $mod chord"; continue; }
  meta=$(st_zero "$(field "$line" metaState)")
  bit=${MOD_BIT[$mod]}
  log "    $mod chord: the app's own key-down for the letter carries metaState=$meta (needs bit $bit)"
  (( (meta & bit) == bit )) \
    || fail "the $mod chord arrived as separate keys: the letter's own event carries metaState=$meta, without bit $bit"
done
pass "ctrl, alt and shift each reached the app as a modifier on the letter's own event"


step "10. horizontal and high-resolution scroll arrive with the right axis and sign"
STEP10_FAILED_AT=$FAILED
sc_nonce=$(nonce)
app_ping "$APP_PKG" "$sc_nonce"
app_token RHIZO_ALIVE "$sc_nonce" 30 >/dev/null || fail "the app stopped answering before the scroll leg"
jv=$(win_json "$D1")
read -r sx sy sw sh <<<"$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['x'],d['y'],d['w'],d['h'])" <<<"$jv")"
desk_inject_pointer abs $(( sx + sw / 2 )) $(( sy + sh / 2 )) || fail "could not park the pointer over the window"
before=$(android_sh "$INIT" "logcat -d -b all -s RhizoWinApp:I" 2>/dev/null | grep -a -c "RHIZO_SCROLL" || true)
desk_inject_pointer axis h -30 || fail "the injector refused a horizontal scroll"
if [[ "$PROFILE" == plasma ]]; then
  desk_inject_pointer axis v 15 || fail "the injector refused a vertical scroll"
elif [[ "$PROFILE" == gnome ]]; then
  desk_inject_pointer axis_discrete v 1 || fail "the injector refused a discrete wheel step"
else
  inject_axis_discrete v 1 || fail "the injector refused a discrete wheel step"
fi
sline=""
scroll_deadline=$(( SECONDS + 30 ))
while (( SECONDS < scroll_deadline )); do
  scap=$(android_sh "$INIT" "logcat -d -b all -s RhizoWinApp:I" 2>/dev/null | grep -a -o "RHIZO_SCROLL .*")
  snow=$(grep -c . <<<"$scap")
  if (( ${snow:-0} > ${before:-0} )); then
    sline=$(tail -1 <<<"$scap")
    break
  fi
  sleep 1
done
[[ -n "$sline" ]] || fail "the app reported no scroll event within 30s of the injection (it had ${before:-0} before it)"
if [[ -n "$sline" ]]; then
  ah=$(st_zero "$(field "$sline" accumH)"); av=$(st_zero "$(field "$sline" accumV)")
  log "    app's own accumulated scroll: horizontal=$ah vertical=$av"
  awk -v v="${ah:-0}" 'BEGIN{exit !(v!=0)}' \
    || fail "horizontal scroll never reached the app (its own accumulated AXIS_HSCROLL is $ah)"
  awk -v v="${av:-0}" 'BEGIN{exit !(v!=0)}' \
    || fail "the discrete wheel step never reached the app (its own accumulated AXIS_VSCROLL is $av)"
  awk -v v="${ah:-0}" 'BEGIN{exit !(v<0)}' \
    || fail "a leftward horizontal scroll reached the app as $ah, the wrong sign"
fi
(( FAILED == STEP10_FAILED_AT )) && pass "both axes arrived, with the right sign"


step "11. the pointer shape an app asks for is the shape the compositor shows"
STEP11_FAILED_AT=$FAILED
jc=$(win_json "$D1")
read -r cx cy cw ch <<<"$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['x'],d['y'],d['w'],d['h'])" <<<"$jc")"
PTX=$(( cx + cw / 2 )); PTY=$(( cy + ch / 2 ))
AWAYX=$PTX; AWAYY=$(( cy + ch - 40 ))
CREG="$(( PTX - 56 )),$(( PTY - 56 )),128,128"

# move the pointer to a point, capture the output and pull the image
park_and_shoot() {
  desk_inject_pointer abs "$1" "$2" || return 1
  sleep 2
  desk_shot /tmp/wgc.png "" "$OUT1" >/dev/null || return 1
  pull /tmp/wgc.png "$3" || return 1
}
# print the number of pixels of the region the cursor covers
cursor_pixels() {
  python3 ../tools/pngstat.py --diff "$EV/11-away.png" "$1" --region "$CREG" \
    | grep '^changed=' | cut -d= -f2
}

park_and_shoot "$AWAYX" "$AWAYY" "$EV/11-away.png" \
  || fail "could not capture the window with the pointer parked away from the region under test"

# android.view.PointerIcon type ids
declare -A POINTER_TYPE_ID=([TEXT]=1008 [CROSSHAIR]=1007)
declare -A CURSOR_DIGEST=() CURSOR_SEEN=() CURSOR_UPLOADS=() CURSOR_OFFERED=() CURSOR_SKIP=() CURSOR_LAYER=() CURSOR_LAYERCMDS=() CURSOR_BUFCMDS=() CURSOR_NAMED=() CURSOR_IDCHG=() CURSOR_PRESENTS=()
for shape in TEXT CROSSHAIR; do
  ic_nonce=$(nonce)
  app_cmd "$APP_PKG" "$APP_ACT" "$ic_nonce" "--es cmd set_icon --es icon $shape"
  icon=$(app_token RHIZO_ICON "$ic_nonce" 30)
  [[ -n "$icon" ]] || { fail "the app never confirmed it asked for a $shape pointer"; continue; }
  applied=$(st "$(field "$icon" appliedName)")
  [[ "$applied" == "$shape" ]] \
    || fail "the app asked for a $shape pointer and its own view reports '$applied'"

  desk_inject_pointer abs "$AWAYX" "$AWAYY" || fail "could not move the pointer off the region under test"
  park_nonce=$(nonce)
  app_ping "$APP_PKG" "$park_nonce"
  app_token RHIZO_ALIVE "$park_nonce" 30 >/dev/null \
    || fail "$APP_PKG never acknowledged the $shape park's nonce"
  desk_inject_pointer abs "$PTX" "$PTY" || { fail "could not park the pointer for $shape"; continue; }
  entered=$(wait_app_field RHIZO_POINTER "$park_nonce" actionName ACTION_HOVER_ENTER 20)
  [[ -n "$entered" ]] \
    || fail "the pointer parked at $PTX,$PTY never entered $APP_PKG's view for $shape (last: $(app_token RHIZO_POINTER "$park_nonce" 1))"
  resolved=$(wait_app_field RHIZO_ICON_RESOLVE "$park_nonce" name "$shape" 20)
  [[ -n "$resolved" ]] \
    || fail "no pointer icon request to $APP_PKG at the parked point after the $shape icon (last: $(app_token RHIZO_ICON_RESOLVE "$park_nonce" 1))"
  # wait for the composer's pointer_type: it sets the shape only after displayd replies
  want_type=${POINTER_TYPE_ID[$shape]}
  ptype=""
  ptype_deadline=$(( SECONDS + 10 ))
  while (( SECONDS < ptype_deadline )); do
    rhizo_ctl "$INIT" display cursor "$D1" >/dev/null 2>&1
    ptype=$(rhizo_ctl_out "$INIT" | grep "^display cursor id=$D1 " | tail -1 \
            | sed -n 's/.* pointer_type=\([^ ]*\).*/\1/p')
    [[ "$ptype" == "$want_type" ]] && break
    sleep 0.5
  done
  log "    $shape: composer's pointer_type=${ptype:-<none>} (want $want_type) before the capture"
  { desk_shot /tmp/wgc.png "" "$OUT1" >/dev/null && pull /tmp/wgc.png "$EV/11-$shape.png"; } \
    || { fail "could not capture the pointer for $shape"; continue; }

  rhizo_ctl "$INIT" display cursor "$D1" >/dev/null 2>&1
  cline=$(rhizo_ctl_out "$INIT" | grep "^display cursor id=$D1 " | tail -1)
  for _cd in $(rhizo_ctl_display_list "$INIT" 2>/dev/null \
               | grep -oE '[0-9]+\([0-9]+x[0-9]+' | grep -oE '^[0-9]+'); do
    rhizo_ctl "$INIT" display cursor "$_cd" >/dev/null 2>&1
    log "      [$shape] display $_cd cursor: $(rhizo_ctl_out "$INIT" \
         | grep "^display cursor id=$_cd " | tail -1 \
         | sed -E 's/.*(digest=[^ ]*).*(uploads=[^ ]*).*(layer=[^ ]*)/\1 \2 \3/')"
  done
  ANDROID_SH_TIMEOUT=45 android_sh "$INIT" "dumpsys SurfaceFlinger --list 2>/dev/null | grep -F Sprite# | while IFS= read -r L; do echo \"-- \$L\"; dumpsys SurfaceFlinger --latency \"\$L\" 2>/dev/null | head -4; done" \
    > "$EV/11-$shape-sprite-frames.txt" 2>&1 || true
  log "      [$shape] sprite frames: $(grep -cE '^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+' "$EV/11-$shape-sprite-frames.txt" 2>/dev/null) frame row(s) across $(grep -c '^-- ' "$EV/11-$shape-sprite-frames.txt" 2>/dev/null) sprite layer(s)"

  log "      [$shape] display density: $(android_sh "$INIT" "dumpsys display 2>/dev/null | grep -aoE 'displayId=${D1}[,)].*?density=[0-9]+' | head -1" 2>/dev/null | grep -oE 'density=[0-9]+' | head -1)"

  android_sh "$INIT" "dumpsys input 2>/dev/null | grep -aE 'Pointer Display ID|requestedPointerType|resolvedPointerType'" \
    > "$EV/11-$shape-pointer-types.txt" 2>&1 || true
  log "      [$shape] android: $(tr '\n' ' ' < "$EV/11-$shape-pointer-types.txt" 2>/dev/null | sed 's/  */ /g' | cut -c1-220)"
  ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "dumpsys SurfaceFlinger" > "$EV/11-$shape-surfaceflinger.txt" 2>&1 || true
  ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "dumpsys input" > "$EV/11-$shape-input.txt" 2>&1 || true
  rhizo_ctl "$INIT" display audit >/dev/null 2>&1
  aline=$(rhizo_ctl_out "$INIT" | grep "^display audit " | tail -1)
  CURSOR_PRESENTS[$shape]=$(sed -n 's/.* presents=\([^ ]*\).*/\1/p' <<<"$aline" \
                            | tr ',' '\n' | awk -F: -v d="$D1" '$1==d{print $2; exit}')
  CURSOR_DIGEST[$shape]=$(st_const "$(field "$cline" digest)")
  CURSOR_SEEN[$shape]=$(field "$cline" seen)
  CURSOR_UPLOADS[$shape]=$(field "$cline" uploads)
  CURSOR_OFFERED[$shape]=$(field "$cline" offered)
  CURSOR_LAYERCMDS[$shape]=$(field "$cline" layer_cmds)
  CURSOR_BUFCMDS[$shape]=$(field "$cline" buffer_cmds)
  CURSOR_NAMED[$shape]=$(field "$cline" named_cursor)
  CURSOR_IDCHG[$shape]=$(field "$cline" id_changes)
  CURSOR_SKIP[$shape]=$(field "$cline" last_skip)
  CURSOR_LAYER[$shape]=$(field "$cline" layer)
  log "    $shape: composer holds $(field "$cline" width)x$(field "$cline" height) hotspot $(field "$cline" hotspot_x),$(field "$cline" hotspot_y) digest ${CURSOR_DIGEST[$shape]} offered=${CURSOR_OFFERED[$shape]} layer_cmds=${CURSOR_LAYERCMDS[$shape]} buffer_cmds=${CURSOR_BUFCMDS[$shape]} rel_owed=$(field "$cline" rel_owed) rel_emitted=$(field "$cline" rel_emitted) named_cursor=${CURSOR_NAMED[$shape]} id_changes=${CURSOR_IDCHG[$shape]} presents=${CURSOR_PRESENTS[$shape]:-?} seen=${CURSOR_SEEN[$shape]} uploads=${CURSOR_UPLOADS[$shape]} last_skip=${CURSOR_SKIP[$shape]} layer=${CURSOR_LAYER[$shape]}"

  chg=$(st_zero "$(cursor_pixels "$EV/11-$shape.png")")
  log "    $shape: the compositor's cursor covers ${chg} pixels of the region it is parked in"
  awk -v v="${chg:-0}" 'BEGIN{exit !(v>20)}' \
    || fail "with a $shape pointer requested, the compositor is drawing no cursor at all (${chg} pixels differ from the same region with the pointer elsewhere)"
done

android_sh "$INIT" "logcat -d -b all 2>/dev/null | grep -aE 'pointer is not in the window|No mouse pointer controller found for display|Cannot set pointer icon for display'" \
  > "$EV/11-icon-test-warnings.txt" 2>&1 || true
icon_test=$(grep -acE 'pointer is not in the window' "$EV/11-icon-test-warnings.txt" 2>/dev/null); icon_test=${icon_test:-0}
icon_test2=$(grep -acE 'No mouse pointer controller found|Cannot set pointer icon' "$EV/11-icon-test-warnings.txt" 2>/dev/null); icon_test2=${icon_test2:-0}
log "    icon tests: isPointerInWindow rejections=$icon_test, choreographer rejections=$icon_test2 (see $EV/11-icon-test-warnings.txt)"

[[ -n "${CURSOR_DIGEST[TEXT]:-}" && -n "${CURSOR_DIGEST[CROSSHAIR]:-}" ]] \
  || fail "the composer never reported a cursor image for both shapes"
if [[ "${CURSOR_DIGEST[TEXT]:-x}" == "${CURSOR_DIGEST[CROSSHAIR]:-y}" ]]; then
  if [[ "${CURSOR_UPLOADS[TEXT]:-}" == "${CURSOR_UPLOADS[CROSSHAIR]:-}" ]]; then
    if [[ "${CURSOR_OFFERED[TEXT]:-}" == "${CURSOR_OFFERED[CROSSHAIR]:-}" ]]; then
      fail "the composer holds the same cursor image (${CURSOR_DIGEST[TEXT]}) for a text pointer and a crosshair and was never asked about one between them (offered stayed ${CURSOR_OFFERED[TEXT]:-?}, layer_cmds ${CURSOR_LAYERCMDS[TEXT]:-?} -> ${CURSOR_LAYERCMDS[CROSSHAIR]:-?}, buffer_cmds ${CURSOR_BUFCMDS[TEXT]:-?} -> ${CURSOR_BUFCMDS[CROSSHAIR]:-?}, named_cursor ${CURSOR_NAMED[TEXT]:-?} -> ${CURSOR_NAMED[CROSSHAIR]:-?}, id_changes ${CURSOR_IDCHG[TEXT]:-?} -> ${CURSOR_IDCHG[CROSSHAIR]:-?}, presents ${CURSOR_PRESENTS[TEXT]:-?} -> ${CURSOR_PRESENTS[CROSSHAIR]:-?}, remembered layer ${CURSOR_LAYER[TEXT]:-?} -> ${CURSOR_LAYER[CROSSHAIR]:-?}) -- SurfaceFlinger sent no layer command this HAL recognizes as the cursor; Android rejected the app icon at isPointerInWindow ${icon_test} time(s) and at the choreographer ${icon_test2} time(s)"
    else
      fail "the composer holds the same cursor image (${CURSOR_DIGEST[TEXT]}) for a text pointer and a crosshair after being asked ${CURSOR_OFFERED[TEXT]:-?} -> ${CURSOR_OFFERED[CROSSHAIR]:-?} times and reading none of them (seen ${CURSOR_SEEN[TEXT]:-?} -> ${CURSOR_SEEN[CROSSHAIR]:-?}, layer_cmds ${CURSOR_LAYERCMDS[TEXT]:-?} -> ${CURSOR_LAYERCMDS[CROSSHAIR]:-?}, last_skip=${CURSOR_SKIP[CROSSHAIR]:-?})"
    fi
  else
    fail "the composer holds the same cursor image (${CURSOR_DIGEST[TEXT]}) for a text pointer and a crosshair after uploading ${CURSOR_UPLOADS[TEXT]:-?} -> ${CURSOR_UPLOADS[CROSSHAIR]:-?}"
  fi
fi

if [[ -f "$EV/11-TEXT.png" && -f "$EV/11-CROSSHAIR.png" ]]; then
  diffc=$(st_zero "$(python3 ../tools/pngstat.py --diff "$EV/11-TEXT.png" "$EV/11-CROSSHAIR.png" \
          --region "$CREG" | grep '^changed=' | cut -d= -f2)")
  log "    the two requested shapes differ by ${diffc} pixels on screen at the same pointer position"
  awk -v v="${diffc:-0}" 'BEGIN{exit !(v>10)}' \
    || fail "a text cursor and a crosshair produced the same pixels"
else
  fail "one of the two shape captures is missing"
fi
if (( FAILED == STEP11_FAILED_AT )); then
  pass "two different requested shapes produced two different cursors on screen"
fi


step "12. closing one window from the host ends that app and leaves the other alone"
alive_nonce=$(nonce)
app_ping "$APP2_PKG" "$alive_nonce"
app_token RHIZO_ALIVE "$alive_nonce" 30 >/dev/null \
  || fail "$APP2_PKG was not answering before the close"
close_nonce=$(nonce)
app_ping "$APP2_PKG" "$close_nonce"
app_token RHIZO_ALIVE "$close_nonce" 30 >/dev/null \
  || fail "$APP2_PKG never acknowledged this leg's nonce"
d2_close_id=$(display_window_id "$D2")
[[ -n "$d2_close_id" ]] && desk_window_op "$d2_close_id" close
destroyed=$(app_token RHIZO_DESTROYED "$close_nonce" 45)
destroyed=$(st "$destroyed")
[[ "$destroyed" == RHIZO_DESTROYED* ]] \
  || fail "$APP2_PKG never reported its own onDestroy after its window was closed (got: ${destroyed:-nothing})"
live_nonce=$(nonce)
app_ping "$APP_PKG" "$live_nonce"
app_token RHIZO_ALIVE "$live_nonce" 30 >/dev/null \
  || fail "closing $APP2_PKG's window also stopped $APP_PKG"
gone_deadline=$(( SECONDS + 10 )) gone=0
while (( SECONDS < gone_deadline )); do
  _desktop_window_for_display "$D2" 0 --any-size >/dev/null 2>&1 || { gone=1; break; }
  sleep 0.5
done
(( gone )) || fail "$APP2_PKG's toplevel is still in the compositor's tree 10s after being closed"
win_json "$D1" >/dev/null \
  || fail "closing one window unmapped the other app's toplevel too"
assert_window_painted winapp-after-close "$(st_disp "$D1")"
pass "one window closed, its app's activity destroyed, the other kept painting"


step "13. nothing restarted underneath any of that"
SS_PID_END=$(system_server_pid "$INIT")
log "    system_server pid $SS_PID_START -> $SS_PID_END"
[[ -n "$SS_PID_START" && "$SS_PID_START" == "$SS_PID_END" ]] \
  || fail "system_server restarted during the run ($SS_PID_START -> $SS_PID_END)"
# return true only when the capture holds a real threadtime line
logcat_capture_read() {
  grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' "$1"
}
android_sh "$INIT" "logcat -d -b all -t 8000" 2>/dev/null > "$EV/logcat-run.txt"
if ! logcat_capture_read "$EV/logcat-run.txt"; then
  fail "the fatal sweep read no logcat (capture starts: $(head -c 120 "$EV/logcat-run.txt" | tr '\n' ' '))"
else
  bad=$(grep -cE "$TEST_FATAL_RE" "$EV/logcat-run.txt" || true)
  bad=$(st_num "${bad:-0}")
  if (( bad != 0 )); then
    fail "$bad fatal/watchdog lines in logcat during the run"
    grep -E "$TEST_FATAL_RE" "$EV/logcat-run.txt" | head -5
  fi
fi
pass "no restart, no fatal exception"

[[ "$PROFILE" == sway ]] && inject_stop >/dev/null 2>&1
if [[ "$PROFILE" == plasma && "$OUT2" == Virtual-rhizo-* ]]; then
  desk_outputs remove "$OUT2" >/dev/null 2>&1 || log "    could not remove the virtual output $OUT2"
fi

if (( SELFTEST )); then
  failed_steps=$(cut -f2 "$EV/failures.log" 2>/dev/null | sed 's/^step=//' | sort -u)
  survived=() asserting=0
  for st_step in "${SELFTEST_STEPS[@]}"; do
    case "$st_step" in
      0.*|1.*|2.*) continue ;;
    esac
    asserting=$(( asserting + 1 ))
    grep -Fxq "$st_step" <<<"$failed_steps" || survived+=("$st_step")
  done
  if (( ${#survived[@]} )); then
    log "WINDOW/INPUT SYSTEM TEST SELFTEST FAILED -- these legs passed on a corrupted value:"
    printf '    | %s\n' "${survived[@]}" >&2
    printf 'FAILED selftest: %d of %d asserting legs survived a corrupted value\n%s\n' \
      "${#survived[@]}" "$asserting" "$(printf '  %s\n' "${survived[@]}")" > "$EV/selftest-verdict.txt"
    test_record_verdict FAILED
    exit 1
  fi
  log "WINDOW/INPUT SYSTEM TEST SELFTEST PASSED -- all $asserting asserting legs failed on a corrupted value"
  printf 'PASSED selftest: all %d asserting legs failed on a corrupted value\n' "$asserting" \
    > "$EV/selftest-verdict.txt"
  test_record_verdict PASSED
  exit 0
fi
if (( FAILED )); then test_record_verdict FAILED; log "WINDOW/INPUT SYSTEM TEST FAILED"; exit 1; fi
test_record_verdict PASSED
log "WINDOW/INPUT SYSTEM TEST PASSED -- evidence in $EV"
