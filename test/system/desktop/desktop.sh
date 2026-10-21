#!/bin/bash
# test-boot-mode: cold-required
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boots-unit: na
# test-records-metrics: no
# test-requires: share:rhizo-wlbridge share:RhizoDesktop.apk share:rhizo-deskapp.apk
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }
source ../../system/lib/settle-lib.sh
source ../lib/desktop-assert-lib.sh

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
SELFTEST=0
ROUNDS=3
ROUNDS_NOTE="default"
for arg in "$@"; do
  case "$arg" in
    --skip-boot) SKIP_BOOT=1 ;;
    --selftest) SELFTEST=1 ;;
    --fast) ROUNDS=1; ROUNDS_NOTE="FAST (reduced repetition)" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done
# print the rounds verdict parameter
verdict_params() {
  [[ "$ROUNDS_NOTE" == default ]] || printf 'rounds=%s' "$ROUNDS"
}

test_init desktop
if (( SELFTEST )); then
  EV="$EV/selftest"
  mkdir -p "$EV" || exit 1
  : > "$EV/failures.log"
fi
WORKDIR="$TEST_WORKDIR"

# corrupt a received value under --selftest
st() {
  if (( SELFTEST )); then printf '%s' "${1}-selftest-corrupted"; else printf '%s' "$1"; fi
}
# replace the received PNG with a different image
st_png() {
  (( SELFTEST )) || return 0
  python3 - "$1" <<'STPY'
import struct, sys, zlib
w = h = 16
rows = b"".join(b"\x00" + bytes([9, 9, 9] * w) for _ in range(h))
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
# print the count argument
st_up() {
  if (( SELFTEST )); then printf '%s' $(( ${1:-0} + 100000 )); else printf '%s' "${1:-0}"; fi
}
# print the composer display id
st_disp() {
  if (( SELFTEST )); then printf '%s' 4095; else printf '%s' "$1"; fi
}
# append a denial line to the AVC log
st_avc() {
  (( SELFTEST )) && printf '%s\n' \
    "audit: avc:  denied  { write } for  pid=1 comm=\"selftest\" scontext=u:r:kernel:s0 tcontext=u:r:rhizo_host:s0 tclass=fifo_file permissive=0" \
    >> "$1"
  return 0
}

SELFTEST_STEPS=()
if (( SELFTEST )); then
  # shellcheck disable=SC2034
  step() { TEST_STEP="$*"; SELFTEST_STEPS+=("$*"); log "=== $*"; }
fi

ADB=~/Android/Sdk/platform-tools/adb
DESK_PORT=47100
# shellcheck disable=SC2034
CLIP_FIFO=/tmp/rhizo-clip.fifo
BRIDGE_PKG=com.rhizo.desktop
APP_PKG=com.rhizo.deskapp
APP_ACT=com.rhizo.deskapp.MainActivity
SECOND_PKG=com.android.deskclock
SECOND_ACT=com.android.deskclock.DeskClock

for f in "$VAR_DIR/share/rhizo-wlbridge" "$REPO/src/services/deskbridge/deskd.py" \
         "$VAR_DIR/share/RhizoDesktop.apk" "$VAR_DIR/share/rhizo-deskapp.apk"; do
  [[ -f "$f" ]] || { fail "missing $f"; exit 1; }
done
test_require_staged rhizo-wlbridge RhizoDesktop.apk rhizo-deskapp.apk || exit 1

# print the base64 of a file
b64_of() { base64 -w0 < "$1"; }

if (( SKIP_BOOT == 0 )); then
  step "0. boot the guest, the compositor and both halves of the bridge"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up >"$EV/desktop-sway.log" 2>&1 \
    || { fail "the desktop session did not start (see $EV/desktop-sway.log)"; exit 1; }
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 200 >"$EV/desktop-redeploy.log" 2>&1 \
    || { fail "redeploy.sh failed (see $EV/desktop-redeploy.log)"; exit 1; }
  tail -4 "$EV/desktop-redeploy.log"
fi

INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"
enforce=$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce' | tr -d '\r')
[[ "$enforce" == "1" ]] || fail "SELinux is not enforcing (enforce=$enforce)"
android_sh "$INIT" "logcat -c" >/dev/null 2>&1

step "1. the host half of the bridge is up"
TOKEN_LOG_OFF=$(desk_log_offset /var/log/rhizo/rhizo-desk-token.log)
../../vm/start/start-deskd.sh --port "$DESK_PORT" >"$EV/desktop-deskd-start.log" 2>&1 \
  || { fail "start-deskd.sh failed (see $EV/desktop-deskd-start.log)"; exit 1; }
pass "rhizo-deskd is listening and its Wayland client is connected"


step "2. install the test app; the product staged the android app, granted it and connected the bridge"
../../vm/boot/adb-tunnel.sh up >"$EV/desktop-adb.log" 2>&1 || { fail "adb-tunnel.sh up failed"; exit 1; }
android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$VAR_DIR/share/rhizo-deskapp.apk" /data/local/tmp/rhizo-deskapp.apk \
  || { fail "adb push of the test app failed"; exit 1; }
out=$(ANDROID_SH_TIMEOUT=180 android_sh "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/rhizo-deskapp.apk")
grep -qx "Success" <<<"$out" || fail "pm install of rhizo-deskapp.apk did not print 'Success': $out"
pkglist=$(android_sh "$INIT" "pm list packages")
grep -qx "package:$APP_PKG" <<<"$pkglist" || fail "$APP_PKG missing from pm list packages"

desk_token_await "$TOKEN_LOG_OFF" 360 >"$EV/desktop-token-delivery.log" 2>&1 \
  || fail "the product's grants and delivery (rhizo-desk-token.service) never logged RHIZO_DESK_TOKEN_DELIVERED (see $EV/desktop-token-delivery.log)"
granted=$(desk_bridge_granted "$INIT" "2") || fail "$granted"
connected=0
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
  logs=$(android_sh "$INIT" "logcat -d -b all")
  if grep -q "RHIZO_DESK_CONNECTED" <<<"$logs"; then connected=1; break; fi
  sleep 3
done
(( connected == 1 )) || { fail "the android app never reported RHIZO_DESK_CONNECTED"; \
  android_sh "$INIT" "logcat -d -b all" | grep -a "rhizo-desk" | tail -20 | sed 's/^/    | /'; }
deskd_log=$(ssh_vm -t 10 "cat /var/log/rhizo/rhizo-deskd.log")
grep -q "android app authenticated" <<<"$deskd_log" || fail "rhizo-deskd never authenticated the android app"
pass "the launcher-staged android holds the default IME and the listener grant the product set, channel authenticated"

# launch the app and print its log line
launch_app() {
  ssh_vm -t 120 "/usr/lib/rhizo/tools/rhizo-launch.sh $1 $2 ${3:-} > /tmp/test-desktop-launch.out 2>&1" >/dev/null 2>&1
  ssh_vm -t 15 "grep -a 'cdisplay=' /run/rhizo-launch/rhizo-launch.log | tail -1"
}

step "3. the test app is a real, painted window"
launch_out=$(launch_app "$APP_PKG" "$APP_ACT")
echo "$launch_out" > "$EV/desktop-launch.txt"
cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$launch_out" | head -1 | cut -d= -f2)
[[ -n "$cdisp" ]] || { fail "rhizo-launch.sh reported no composer display for $APP_PKG"; }
[[ -n "$cdisp" ]] && assert_window_painted deskapp "$(st_disp "$cdisp")"

clip_start || exit 1

step "4. clipboard text, host -> Android, read by the app as its own uid (rounds=$ROUNDS)"
for round in $(seq 1 "$ROUNDS"); do
  log "  round $round of $ROUNDS"
  want="rhizo-host-clip-$(nonce)"
  want_b64=$(printf '%s' "$want" | base64 -w0)
  want_sha=$(printf '%s' "$want" | sha256sum | cut -d' ' -f1)
  set_since=$(logcat_since_marker "$INIT")
  clipcmd "set text/plain $want_b64"
  if ! clip_wait_applied "$set_since" "RHIZO_DESK_CLIP_APPLIED mime=text/[^ ]* sha256=$want_sha"; then
    fail "round $round: the android app never applied the host's clip (no RHIZO_DESK_CLIP_APPLIED with its sha256 in 60s)"
    break
  fi
  got=$(clip_read "RHIZO_CLIP_READ mime=[^ ]* b64=[A-Za-z0-9+/=]*" 45 "$EV/focus-at-clip-read-4.txt")
  read_rc=$?
  if (( read_rc == 2 )); then
    fail "round $round: the app read an empty clipboard (RHIZO_CLIP_EMPTY) -- focus at that moment is in $EV/focus-at-clip-read-4.txt"
    break
  fi
  if [[ -z "$got" ]]; then
    fail "round $round: the app never reported a clipboard read"
    break
  fi
  got_b64=${got##*b64=}
  got_text=$(st "$(printf '%s' "$got_b64" | base64 -d 2>/dev/null)")
  [[ "$got_text" == "$want" ]] || fail "round $round: the app read '$got_text', the host set '$want'"
done
pass "the host selection arrived in an app's own ClipboardManager, byte for byte"

step "5. clipboard text, Android -> host, read by an independent Wayland client (rounds=$ROUNDS)"
for round in $(seq 1 "$ROUNDS"); do
  log "  round $round of $ROUNDS"
  want="rhizo-android-clip-$(nonce)"
  want_b64=$(printf '%s' "$want" | base64 -w0)
  clip_since=$(clip_mark) || { fail "round $round: the system test's clipboard client's output could not be read"; break; }
  wrote_since=$(logcat_since_marker "$INIT")
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_write --es mime text/plain --es b64 $want_b64" >/dev/null 2>&1
  app_wait_token "RHIZO_CLIP_WROTE" 30 "$wrote_since" >/dev/null || { fail "round $round: the app never wrote the clip"; break; }
  got_b64=$(clip_wait_data "text/plain" 45 "$clip_since")
  if [[ -z "$got_b64" ]]; then
    fail "round $round: the host selection never carried the app's clip"
    gcmd_user "cat /tmp/rhizo-clip.out" | tail -5 | sed 's/^/    | /'
    break
  fi
  got_text=$(st "$(printf '%s' "$got_b64" | base64 -d 2>/dev/null)")
  [[ "$got_text" == "$want" ]] || fail "round $round: the host read '$got_text', the app set '$want'"
done
pass "an app's clip arrived on the host selection, byte for byte"

NOTIF_FIFO=/tmp/rhizo-notify.fifo
NOTIF_REC=/tmp/rhizo-notif.jsonl

step "6. an Android notification reaches the desktop with its own bytes and icon"
notify_sink_start || exit 1
python3 - "$WORKDIR/icon.png" <<'ICONPY'
import struct, sys, zlib
w = h = 16
left, right = (17, 200, 99), (240, 60, 30)
rows = b"".join(b"\x00" + b"".join(bytes(left if x < w // 2 else right) for x in range(w)) for _ in range(h))
def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
open(sys.argv[1], "wb").write(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(rows))
    + chunk(b"IEND", b""))
ICONPY
icon_b64=$(base64 -w0 < "$WORKDIR/icon.png")
ntitle="rhizo-notif-$(nonce)"
nbody="rhizo-body-$(nonce)"
notif_since=$(logcat_since_marker "$INIT")
android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd notify --es title $ntitle --es body $nbody --es icon_b64 $icon_b64" >/dev/null 2>&1
app_wait_token "RHIZO_NOTIF_POSTED" 30 "$notif_since" >/dev/null || fail "the app never posted its notification"

got_rec=""
deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < deadline )); do
  got_rec=$(gcmd_user "grep -a '$ntitle' $NOTIF_REC 2>/dev/null | tail -1" 10)
  [[ -n "$got_rec" ]] && break
  sleep 2
done
if [[ -z "$got_rec" ]]; then
  fail "the desktop's notification daemon never received the app's notification"
  gcmd_user "tail -5 /var/log/rhizo/rhizo-deskd.log; tail -5 /tmp/rhizo-notify-sink.out" | sed 's/^/    | /'
else
  printf '%s\n' "$got_rec" > "$EV/notification-record.json"
  nid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$EV/notification-record.json")
  rec_summary=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["summary"])' "$EV/notification-record.json")
  rec_body=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["body"])' "$EV/notification-record.json")
  [[ "$rec_summary" == "$ntitle" ]] || fail "the desktop got summary '$rec_summary', the app posted '$ntitle'"
  [[ "$rec_body" == "$nbody" ]] || fail "the desktop got body '$rec_body', the app posted '$nbody'"
  icon_path=$(python3 -c 'import json,sys;print((json.load(open(sys.argv[1])).get("hints") or {}).get("image-path",""))' "$EV/notification-record.json")
  rm -f "$EV/notification-icon.png"
  printf '<none>\n' > "$EV/notification-icon-stats.txt"
  if [[ -z "$icon_path" ]]; then
    fail "the notification carried no icon to the desktop"
  elif ! desk_user_pull "$icon_path" "$EV/notification-icon.png" 60; then
    fail "could not read $icon_path, the icon the desktop was given, as the desktop user"
  else
    st_png "$EV/notification-icon.png"
    src_stats=$(python3 ../tools/pngstat.py "$WORKDIR/icon.png")
    got_stats=$(python3 ../tools/pngstat.py "$EV/notification-icon.png")
    echo "$got_stats" > "$EV/notification-icon-stats.txt"
    icon_ok=1
    for ch in mean_r mean_g mean_b; do
      a=$(grep "^$ch=" <<<"$src_stats" | cut -d= -f2)
      b=$(grep "^$ch=" <<<"$got_stats" | cut -d= -f2)
      awk -v a="$a" -v b="$b" 'BEGIN { exit !((a - b < 12) && (b - a < 12)) }' \
        || { fail "the icon on the desktop has $ch=$b, the app posted $ch=$a"; icon_ok=0; }
    done
    d=$(grep '^distinct=' <<<"$got_stats" | cut -d= -f2)
    awk -v v="$d" 'BEGIN { exit !(v + 0 > 1) }' \
      || { fail "the icon that reached the desktop is a single flat color ($got_stats)"; icon_ok=0; }
    (( icon_ok )) && pass "the notification's title, body and icon pixels all reached the desktop"
  fi

  step "7. activating the desktop notification brings the Android app forward"
  activated_since=$(logcat_since_marker "$INIT")
  gcmd_user "echo 'invoke $nid default' > $NOTIF_FIFO" 10
  app_wait_token "RHIZO_NOTIF_ACTIVATED" 45 "$activated_since" >/dev/null \
    || fail "activating the notification never reached the app's own contentIntent"
  [[ -n "$cdisp" ]] && assert_window_painted deskapp-activated "$(st_disp "$cdisp")"
  pass "the desktop's own activation reached the app and its window is painted"
fi

# print the line count of the launch log
launch_log_lines() {
  ssh_vm -t 15 'wc -l < /run/rhizo-launch/rhizo-launch.log 2>/dev/null' | tr -d '[:space:]'
}

# print the am_start_return record for a package
launch_record_since() {
  local deadline line
  deadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < deadline )); do
    line=$(ssh_vm -t 15 "tail -n +$(( $2 + 1 )) /run/rhizo-launch/rhizo-launch.log 2>/dev/null" \
      | grep -a " event=am_start_return .* pkg=$1 " | head -1)
    [[ -n "$line" ]] && { printf '%s\n' "$line"; return 0; }
    sleep 2
  done
  return 1
}

step "8. a link opened on the host is handled by the Android app that claims it"
link_n=$(launch_log_lines)
link_windows=$(desktop_app_toplevel_count) || link_windows=""
desktop_assert_link_host_to_app "$INIT" "$APP_PKG" "$EV"

step "8b. the running app took the link in its own window"
if [[ ! "$link_n" =~ ^[0-9]+$ ]]; then
  fail "the launch log's length could not be read before the link"
elif ! link_rec=$(launch_record_since "$APP_PKG" "$link_n"); then
  fail "the link opened on the host left no launch record for $APP_PKG"
else
  link_cdisp=$(st_disp "$(grep -o 'cdisplay=[0-9]*' <<<"$link_rec" | head -1 | cut -d= -f2)")
  link_windows_after=$(desktop_app_toplevel_count) || link_windows_after=""
  if [[ "$link_cdisp" != "$cdisp" ]]; then
    fail "the link launched $APP_PKG onto composer display ${link_cdisp:-<none>}, not its own window's $cdisp"
  elif [[ -z "$link_windows" || "$link_windows_after" != "$link_windows" ]]; then
    fail "app windows went from ${link_windows:-<unread>} to ${link_windows_after:-<unread>} when the running app took a link"
  else
    pass "the running app took the link in its own window (composer display $cdisp), no second window"
  fi
fi

step "9. a link opened in Android is handled by the host"
desktop_assert_link_android_to_host "$INIT" "$APP_PKG" "$APP_ACT" "$BRIDGE_PKG"

step "10. clipboard image, host -> Android, read by the app as its own uid"
make_png "$WORKDIR/host-clip.png" 40 90 200
host_png_b64=$(base64 -w0 < "$WORKDIR/host-clip.png")
set_since=$(logcat_since_marker "$INIT")
clipcmd "set image/png $host_png_b64"
got="" read_rc=3
if clip_wait_applied "$set_since" "RHIZO_DESK_CLIP_APPLIED mime=image/png"; then
  got=$(clip_read "RHIZO_CLIP_READ mime=image/png b64=[A-Za-z0-9+/=]*" 60 "$EV/focus-at-clip-read-10.txt")
  read_rc=$?
fi
if (( read_rc == 3 )); then
  fail "the android app never applied the host's image clip (no RHIZO_DESK_CLIP_APPLIED in 60s)"
elif (( read_rc == 2 )); then
  fail "the app read an empty image clipboard (RHIZO_CLIP_EMPTY) -- focus at that moment is in $EV/focus-at-clip-read-10.txt"
elif [[ -z "$got" ]]; then
  fail "the app never reported reading an image clip"
else
  printf '%s' "${got##*b64=}" | base64 -d > "$EV/clip-image-android-read.png" 2>/dev/null
  st_png "$EV/clip-image-android-read.png"
  if cmp -s "$WORKDIR/host-clip.png" "$EV/clip-image-android-read.png"; then
    d=$(png_distinct "$EV/clip-image-android-read.png")
    awk -v v="$d" 'BEGIN { exit !(v + 0 > 20) }' \
      || fail "the image the app read has only $d distinct colors"
    pass "the host's image clip reached the app's own uid, pixel for pixel ($d distinct colors)"
  else
    fail "the image the app read differs from the one the host put on the clipboard"
  fi
fi

step "11. clipboard image, Android -> host, read by an independent Wayland client"
make_png "$WORKDIR/android-clip.png" 200 30 70
android_png_b64=$(base64 -w0 < "$WORKDIR/android-clip.png")
clip_since=$(clip_mark) || fail "the system test's clipboard client's output could not be read"
img_wrote_since=$(logcat_since_marker "$INIT")
android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_write --es mime image/png --es b64 $android_png_b64" >/dev/null 2>&1
app_wait_token "RHIZO_CLIP_WROTE" 30 "$img_wrote_since" >/dev/null || fail "the app never wrote its image clip"
got_b64=$(clip_wait_data "image/png" 60 "${clip_since:-0}")
if [[ -z "$got_b64" ]]; then
  fail "the host selection never carried the app's image"
else
  printf '%s' "$got_b64" | base64 -d > "$EV/clip-image-host-read.png" 2>/dev/null
  st_png "$EV/clip-image-host-read.png"
  if cmp -s "$WORKDIR/android-clip.png" "$EV/clip-image-host-read.png"; then
    d=$(png_distinct "$EV/clip-image-host-read.png")
    awk -v v="$d" 'BEGIN { exit !(v + 0 > 20) }' \
      || fail "the image on the host selection has only $d distinct colors"
    pass "an app's image clip reached the host selection, pixel for pixel ($d distinct colors)"
  else
    fail "the image on the host selection differs from the one the app copied"
  fi
fi

step "12. the bridge adds no periodic wakeup"
deskd_pid=$(gcmd_root "systemctl show -p MainPID --value rhizo-deskd" 15 | tr -d '\r')
if [[ ! "$deskd_pid" =~ ^[0-9]+$ ]] || (( deskd_pid == 0 )); then
  fail "rhizo-deskd has no main pid"
else
  log "    $(await_guest_quiet)"
  ctx_before=$(gcmd_user "awk '/voluntary_ctxt_switches/ {print \$2}' /proc/$deskd_pid/status | head -1" 15 | tr -d '\r')
  sleep 30
  ctx_after=$(gcmd_user "awk '/voluntary_ctxt_switches/ {print \$2}' /proc/$deskd_pid/status | head -1" 15 | tr -d '\r')
  delta=$(st_up $(( ${ctx_after:-0} - ${ctx_before:-0} )) )
  log "    rhizo-deskd voluntary context switches over 30 quiet seconds: $delta"
  (( delta <= 30 )) || fail "the bridge woke $delta times in 30 idle seconds"
  (( delta <= 30 )) && pass "the bridge is event-driven: $delta wakeups in 30 idle seconds"
fi

step "15. a file dragged from the host onto the Android window lands in the app"
desktop_assert_dnd_drop_onto_app "$INIT" "$cdisp" "$EV"

step "16. text dragged out of an Android window reaches the host"
desktop_assert_dnd_drag_out_of_app "$INIT" "$APP_PKG" "$APP_ACT" "$cdisp"

step "17. a second app's window opens beside the first, with a drag-out pad of its own"
second_ok=0
second_n=$(launch_log_lines)
second_since=$(logcat_since_marker "$INIT")
launch_app "$SECOND_PKG" "$SECOND_ACT" >/dev/null
if [[ ! "$second_n" =~ ^[0-9]+$ ]] || ! second_rec=$(launch_record_since "$SECOND_PKG" "$second_n"); then
  fail "launching $SECOND_PKG left no launch record"
else
  second_cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$second_rec" | head -1 | cut -d= -f2)
  second_logid=$(st_disp "$(grep -oE '(^| )display=[0-9]+' <<<"$second_rec" | head -1 | cut -d= -f2)")
  if [[ -z "$second_cdisp" || "$second_cdisp" == "$cdisp" ]]; then
    fail "$SECOND_PKG got no window of its own (composer display ${second_cdisp:-<none>})"
  elif ! app_wait_token "RHIZO_DRAGWATCH_READY display=$second_logid x=" 60 "$second_since" >/dev/null; then
    fail "$SECOND_PKG's display $second_logid never reported a drag-out pad of its own"
  else
    second_ok=1
    pass "$SECOND_PKG on composer display $second_cdisp, its own pad watching, $APP_PKG still on $cdisp"
  fi
fi

step "18. a drag out of the first app's window still reaches the host"
if (( second_ok )); then
  desktop_assert_dnd_drag_out_of_app "$INIT" "$APP_PKG" "$APP_ACT" "$cdisp"
else
  fail "no second app window to drag beside (step 17)"
fi

ssh_vm -t 15 "cat /var/log/rhizo/rhizo-deskd.log" > "$EV/deskd.log" 2>&1

step "13. the sandbox still launches and paints with the host bridge stopped"
gcmd_root "systemctl stop rhizo-deskd" 20
desktop_close_all_app_windows 20 || fail "the app windows did not close before the degrade leg"
degrade_out=$(launch_app "$APP_PKG" "$APP_ACT")
degrade_cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$degrade_out" | head -1 | cut -d= -f2)
if [[ -z "$degrade_cdisp" ]]; then
  fail "with the bridge stopped, launching the app produced no display"
else
  assert_window_painted deskapp-nobridge "$(st_disp "$degrade_cdisp")"
fi
tok_off=$(desk_log_offset /var/log/rhizo/rhizo-desk-token.log)
../../vm/start/start-deskd.sh --port "$DESK_PORT" >>"$EV/desktop-deskd-start.log" 2>&1 \
  || fail "the bridge did not come back up after the degrade leg"
desk_token_await "$tok_off" 360 >"$EV/desktop-token-redelivery.log" 2>&1 \
  || fail "rhizo-deskd's restart never led the product to redeliver a token (see $EV/desktop-token-redelivery.log)"
reconnected=0
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
  ssh_vm -t 10 "grep -a -c 'android app authenticated' /var/log/rhizo/rhizo-deskd.log" | grep -qE '^[1-9]' && { reconnected=1; break; }
  sleep 3
done
(( reconnected == 1 )) || fail "the android app never reconnected after the bridge restart"

step "14. no enforced SELinux denial on the paths this bridge opened"
avc_after_flip "$EV/avc-run.log"
avc_rc=$?
st_avc "$EV/avc-run.log"
case "$avc_rc" in
  2) fail "the AVC capture read was cut off (no end marker)" ;;
  3) fail "the AVC capture holds no enforcement flip record" ;;
  4) fail "the AVC capture holds nothing after the enforcement flip" ;;
esac
if (( avc_rc == 0 )); then
  total=$(grep -c -a 'avc: *denied' "$EV/avc-run.log")
  enforced=$(grep -a 'avc: *denied' "$EV/avc-run.log" | grep 'permissive=0' \
    | grep -E 'tclass=(fifo_file|unix_stream_socket|fd)' \
    | grep -E 'scontext=u:r:(kernel|rhizo_host):s0')
  harness_winsz='comm="bash" .* ioctlcmd=0x5413 scontext=u:r:rhizo_host:s0 tcontext=u:r:kernel:s0 tclass=fifo_file'
  winsz=$(grep -aE "$harness_winsz" <<<"$enforced")
  [[ -n "$winsz" ]] && log "    not the bridge: $(grep -c . <<<"$winsz") harness-shell TIOCGWINSZ denial(s) on sshd's pipe"
  enforced=$(grep -avE "$harness_winsz" <<<"$enforced")
  if [[ -n "$enforced" ]]; then
    sigs=$(avc_denial_signatures <<<"$enforced" | head -5)
    fail "enforced denials on the bridge's own object classes: ${sigs:-$(head -1 <<<"$enforced")}"
  else
    pass "no enforced fifo/socket/fd denial between the compositor's domain and the bridge's ($total denial line(s) after the flip, capture alive past it)"
  fi
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
    log "DESKTOP SYSTEM TEST SELFTEST FAILED -- these legs passed on a corrupted payload:"
    printf '    | %s\n' "${survived[@]}" >&2
    exit 1
  fi
  log "DESKTOP SYSTEM TEST SELFTEST PASSED -- all $asserting asserting legs failed on a corrupted payload"
  exit 0
fi
if (( FAILED )); then test_record_verdict FAILED "$(verdict_params)"; log "DESKTOP SYSTEM TEST FAILED"; exit 1; fi
[[ "$ROUNDS_NOTE" == "default" ]] || log "NOTE: rounds=$ROUNDS ($ROUNDS_NOTE) -- not the default system test run"
test_record_verdict PASSED "$(verdict_params)"
log "DESKTOP SYSTEM TEST PASSED -- evidence in $EV"
