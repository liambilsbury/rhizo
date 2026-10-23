#!/bin/bash
# define the desktop bridge assertion functions
_DESKTOP_ASSERT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -F st      >/dev/null || st()      { printf '%s' "$1"; }
declare -F st_disp >/dev/null || st_disp() { printf '%s' "$1"; }
declare -F st_png  >/dev/null || st_png()  { return 0; }

# print a random 24 character hex token
nonce() { head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# print the byte size of a guest log
desk_log_offset() {
  local n; n=$(ssh_vm -t 10 "stat -c%s $1 2>/dev/null || echo 0" | tr -d '[:space:]')
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$n"
}

# wait for a unit to report active
desk_unit_await_active() {
  local unit="$1" deadline=$(( $(date +%s) + $2 )) state="" result
  while (( $(date +%s) < deadline )); do
    state=$(ssh_vm -t 10 "systemctl is-active $unit 2>/dev/null" | tr -d '[:space:]')
    [[ "$state" == active ]] && return 0
    [[ "$state" == failed ]] && break
    sleep 2
  done
  result=$(ssh_vm -t 10 "systemctl show -p Result --value $unit 2>/dev/null" | tr -d '[:space:]')
  echo "$unit is '${state:-<unread>}' (Result=${result:-<unread>}), never active within $2s"
  return 1
}

# wait for rhizo-desk-token.service to log delivery
desk_token_await() {
  local off="$1" deadline=$(( $(date +%s) + $2 )) out=""
  while (( $(date +%s) < deadline )); do
    out=$(ssh_vm -t 10 "tail -c +$((off + 1)) /var/log/rhizo/rhizo-desk-token.log 2>/dev/null")
    if grep '^RHIZO_DESK_TOKEN_DELIVERED ' <<<"$out"; then
      return 0
    fi
    if grep -q '^FAIL: ' <<<"$out"; then
      tail -5 <<<"$out"
      return 1
    fi
    sleep 2
  done
  tail -5 <<<"${out:-<nothing logged past byte $off>}"
  return 1
}

# wait for rhizo-desk-token.service to report active
desk_token_settled() {
  local deadline=$(( $(date +%s) + $1 )) state=""
  while (( $(date +%s) < deadline )); do
    state=$(ssh_vm -t 10 'systemctl show -p ActiveState --value rhizo-desk-token.service' | tr -d '[:space:]')
    [[ "$state" == active ]] && return 0
    [[ "$state" == failed ]] && break
    sleep 2
  done
  echo "rhizo-desk-token.service is '${state:-<unread>}':"
  ssh_vm -t 10 'tail -5 /var/log/rhizo/rhizo-desk-token.log'
  return 1
}

# check the com.rhizo.desktop package and its grants
desk_bridge_granted() {
  local init="$1" label="$2" path ime listeners
  path=$(android_sh "$init" "pm path com.rhizo.desktop" | tr -d '\r')
  [[ "$path" == "package:/system_ext/app/RhizoDesktop/RhizoDesktop.apk" ]] \
    || { echo "$label: com.rhizo.desktop is not the launcher's /system_ext app (pm path: '${path:-<none>}')"; return 1; }
  ime=$(android_sh "$init" "settings get secure default_input_method" | tr -d '\r')
  [[ "$ime" == "com.rhizo.desktop/.RhizoIme" ]] \
    || { echo "$label: default_input_method is '${ime:-<none>}', not the android app's IME"; return 1; }
  listeners=$(android_sh "$init" "settings get secure enabled_notification_listeners" | tr -d '\r')
  [[ ":$listeners:" == *":com.rhizo.desktop/com.rhizo.desktop.NotifListener:"* ]] \
    || { echo "$label: the android app is not an enabled notification listener (got '${listeners:-<none>}')"; return 1; }
}

# wait for the authenticated line in rhizo-deskd.log
desk_bridge_await_auth() {
  local off="$1" deadline=$(( $(date +%s) + $2 )) out
  [[ "$off" =~ ^[0-9]+$ ]] || return 2
  while (( $(date +%s) < deadline )); do
    out=$(ssh_vm -t 10 "tail -c +$((off + 1)) /var/log/rhizo/rhizo-deskd.log 2>/dev/null")
    grep -q 'android app authenticated' <<<"$out" && return 0
    sleep 2
  done
  return 1
}

# write the post-flip AVC denials to a file
avc_after_flip() {
  local out="$1" raw mode
  mode=$(guest_selinux_mode) || { printf '%s\n' "$mode" > "$out"; return 5; }
  if [[ "$mode" == namespace ]]; then
    raw=$(ssh_vm -t 60 "dmesg | awk '/RHIZO_MARKER selinuxns=android-enforce value=1/ && !flip {flip=1; print \"RHIZO_AVC_FLIP\"; next} flip && !alive {alive=1; print \"RHIZO_AVC_ALIVE\"} flip && /avc: *denied/ {print}'; echo RHIZO_AVC_END")
  else
    raw=$(ssh_vm -t 60 "cat /var/log/rhizo/rhizo-avc.log.1 /var/log/rhizo/rhizo-avc.log 2>/dev/null | awk '/enforcing=1 old_enforcing=0/ {flip=1; print \"RHIZO_AVC_FLIP\"; next} flip && !alive {alive=1; print \"RHIZO_AVC_ALIVE\"} flip && /avc: *denied/ {print}'; echo RHIZO_AVC_END")
  fi
  if [[ "$raw" != *RHIZO_AVC_END ]]; then
    printf '<read cut off: no end marker>\n' > "$out"
    return 2
  fi
  grep -v '^RHIZO_AVC_' <<<"$raw" | grep -a 'avc: *denied' > "$out"
  grep -qx 'RHIZO_AVC_FLIP' <<<"$raw" || return 3
  grep -qx 'RHIZO_AVC_ALIVE' <<<"$raw" || return 4
  return 0
}

# print a count per distinct AVC denial signature
avc_denial_signatures() {
  sed -nE 's/.*avc: +denied +\{ ([^}]*) \}.*comm="([^"]*)".*scontext=([^ ]*) tcontext=([^ ]*) tclass=([^ ]*).*/{ \1 } comm=\2 \3->\4:\5/p' \
    | sort | uniq -c | sort -rn | sed -E 's/^ *([0-9]+) /\1x /'
}

# wait for a matching app logcat line
app_wait_token() {
  local pat="$1" deadline=$(( $(date +%s) + $2 )) since="${3:-}" logs hit
  if (( $# >= 3 )); then
    [[ "$since" =~ ^[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.000$ ]] || return 1
  fi
  while (( $(date +%s) < deadline )); do
    if [[ -n "$since" ]]; then
      logs=$(android_sh "$INIT" "logcat -d -b all -t '$since'")
    else
      logs=$(android_sh "$INIT" "logcat -d -b all")
    fi
    hit=$(grep -a -o "$pat" <<<"$logs" | tail -1)
    [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
    sleep 2
  done
  return 1
}

# wait for a matching app logcat line
clip_wait_applied() {
  app_wait_token "$2" 60 "$1" >/dev/null
}

# kill the clipboard test bridge and remove its fifo and output
clip_stop() {
  gcmd_user "pgrep -f 'rhizo-wlbridge-[t]est' | xargs -r kill 2>/dev/null; rm -f $CLIP_FIFO /tmp/rhizo-clip.out; true" 15
}

CLIP_BRIDGE_SOURCES="/usr/lib/rhizo/deskbridge/rhizo-wlbridge /root/share/rhizo-wlbridge"
CLIP_BRIDGE_CAPS="${CLIP_BRIDGE_CAPS:-clipboard,drag,pointer}"
CLIP_BRIDGE_EXTRA="${CLIP_BRIDGE_EXTRA:-}"

# start rhizo-wlbridge-test in the guest
clip_start() {
  local out
  clip_stop
  out=$(gcmd_root "for s in $CLIP_BRIDGE_SOURCES; do [ -s \"\$s\" ] || continue
cp -f \"\$s\" /tmp/rhizo-wlbridge-test && chmod +x /tmp/rhizo-wlbridge-test && echo \"RHIZO_CLIP_STAGED \$s\"; exit; done
echo RHIZO_CLIP_NO_SOURCE" 25 2>&1)
  [[ "$out" == *RHIZO_CLIP_STAGED* ]] \
    || { fail "could not stage the system test's own clipboard client from any of $CLIP_BRIDGE_SOURCES: $(tr '\n' ' ' <<<"${out:-<no output>}")"; return 1; }
  gcmd_user "rm -f $CLIP_FIFO && mkfifo $CLIP_FIFO
setsid sh -c 'sleep 86400 > $CLIP_FIFO' >/dev/null 2>&1 </dev/null & disown
setsid sh -c '/tmp/rhizo-wlbridge-test --caps $CLIP_BRIDGE_CAPS $CLIP_BRIDGE_EXTRA < $CLIP_FIFO > /tmp/rhizo-clip.out 2>&1' >/dev/null 2>&1 </dev/null & disown
true" 25
  wait_guest 15 "grep -q ready /tmp/rhizo-clip.out" \
    || { fail "the system test's own clipboard client never reported ready"; gcmd_user "cat /tmp/rhizo-clip.out"; return 1; }
  return 0
}

# send a command line to the clipboard bridge's fifo
clipcmd() { gcmd_user "echo '$1' > $CLIP_FIFO" 10; }

# print the line count of /tmp/rhizo-clip.out
clip_mark() {
  local n; n=$(gcmd_user "wc -l < /tmp/rhizo-clip.out 2>/dev/null || echo 0" 10 | tr -d '[:space:]')
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$n"
}

# wait for a matching line in /tmp/rhizo-clip.out
clip_await() {
  local re="$1" since="$2" deadline=$(( $(date +%s) + $3 )) new hit
  [[ "$since" =~ ^[0-9]+$ ]] || return 1
  while (( $(date +%s) <= deadline )); do
    new=$(gcmd_user "tail -n +$(( since + 1 )) /tmp/rhizo-clip.out 2>/dev/null" 10)
    hit=$(grep -a -E -m1 "$re" <<<"$new")
    [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
    hit=$(grep -a -m1 '^error ' <<<"$new")
    [[ -n "$hit" ]] && { printf '%s' "$hit"; return 2; }
    sleep 1
  done
  return 1
}

# print the host selection for a mime type
clip_wait_data() {
  local mime="$1" deadline=$(( $(date +%s) + $2 )) since="${3:-}" mark ack changed left
  while (( $(date +%s) < deadline )); do
    if [[ -n "$since" ]]; then
      changed=$(gcmd_user "tail -n +$(( since + 1 )) /tmp/rhizo-clip.out 2>/dev/null" 10 \
        | grep -a -E -c "^selection( [^ ]+)* $mime( |\$)")
      (( ${changed:-0} > 0 )) || { sleep 1; continue; }
    fi
    mark=$(clip_mark) || { sleep 1; continue; }
    clipcmd "get $mime"
    left=$(( deadline - $(date +%s) )); (( left < 1 )) && left=1
    ack=$(clip_await "^(data|nodata) $mime( |\$)" "$mark" "$left")
    [[ "$ack" == "data $mime "* ]] && { printf '%s' "${ack#data $mime }"; return 0; }
    sleep 1
  done
  return 1
}

# write dumpsys and logcat output to a file
clip_focus_snapshot() {
  {
    echo "=== dumpsys window"
    android_sh "$INIT" "dumpsys window"
    echo "=== dumpsys window displays"
    android_sh "$INIT" "dumpsys window displays"
    echo "=== dumpsys activity activities"
    android_sh "$INIT" "dumpsys activity activities"
    echo "=== logcat ClipboardService and RHIZO_CLIP_ lines"
    android_sh "$INIT" "logcat -d -b all" | grep -a -E 'ClipboardService|RHIZO_CLIP_' | tail -20
  } > "$1" 2>&1
}

# print the app clipboard read token
clip_read() {
  local pat="$1" secs="$2" snap="$3" since deadline logs hit
  since=$(logcat_since_marker "$INIT")
  [[ "$since" =~ ^[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.000$ ]] || return 1
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_read" >/dev/null 2>&1
  deadline=$(( $(date +%s) + secs ))
  while (( $(date +%s) < deadline )); do
    logs=$(android_sh "$INIT" "logcat -d -b all -t '$since'")
    if grep -a -q 'RHIZO_CLIP_EMPTY' <<<"$logs"; then
      clip_focus_snapshot "$snap"
      return 2
    fi
    hit=$(grep -a -o "$pat" <<<"$logs" | tail -1)
    [[ -n "$hit" ]] && { printf '%s' "$hit"; return 0; }
    sleep 2
  done
  return 1
}

# kill the notification sink and remove its fifo
notify_sink_stop() {
  gcmd_user "pgrep -f 'rhizo-notify-[s]ink' | xargs -r kill 2>/dev/null; rm -f $NOTIF_FIFO; true" 15
}

# start notify-sink.py in the guest
notify_sink_start() {
  local want_bus="${1:-}"
  notify_sink_stop
  timeout 30 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$_DESKTOP_ASSERT_LIB_DIR/../guest/notify-sink.py" "$SSH_TARGET:/tmp/notify-sink.py" \
    || { fail "could not copy the notification sink into the guest"; return 1; }
  gcmd_root "chmod +x /tmp/notify-sink.py" 15 \
    || { fail "could not make the notification sink executable"; return 1; }
  local bus="$want_bus"
  [[ -n "$bus" ]] || bus=$(ssh_vm -t 10 "sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' /run/rhizo-desktop/session.env" | tr -d '\r')
  [[ "$bus" == unix:* ]] \
    || { fail "/run/rhizo-desktop/session.env names no unix: DBUS_SESSION_BUS_ADDRESS for the sink to join (got '$bus')"; return 1; }
  gcmd_user "rm -f $NOTIF_FIFO $NOTIF_REC /tmp/rhizo-notify-sink.out
: > $NOTIF_REC
rm -rf /tmp/rhizo-notif-icons && mkdir -p /tmp/rhizo-notif-icons
mkfifo $NOTIF_FIFO
setsid sh -c 'sleep 86400 > $NOTIF_FIFO' >/dev/null 2>&1 </dev/null & disown
setsid env DBUS_SESSION_BUS_ADDRESS='$bus' PYTHONPATH=/usr/lib/rhizo sh -c '/tmp/notify-sink.py --record $NOTIF_REC --icon-dir /tmp/rhizo-notif-icons < $NOTIF_FIFO > /tmp/rhizo-notify-sink.out 2>&1' >/dev/null 2>&1 </dev/null & disown
true" 30
  wait_guest 20 "grep -q ready /tmp/rhizo-notify-sink.out" \
    || { fail "the notification sink never owned org.freedesktop.Notifications"; gcmd_user "cat /tmp/rhizo-notify-sink.out"; return 1; }
  return 0
}

# send a notification action to notify-sink.py
notify_invoke_action() {
  gcmd_user "echo 'invoke $1 $2' > $NOTIF_FIFO" 10
}

# write a 16x16 PNG image to a file
make_png() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import struct, sys, zlib
path, r, g, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
w = h = 16
rows = b""
for y in range(h):
    row = b""
    for x in range(w):
        row += bytes([(r + x * 7) % 256, (g + y * 11) % 256, (b + x * y) % 256])
    rows += b"\x00" + row
def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
open(path, "wb").write(
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(rows))
    + chunk(b"IEND", b""))
PY
}

# print the distinct color count of a PNG
png_distinct() {
  python3 "$(dirname "${BASH_SOURCE[0]}")/../tools/pngstat.py" "$1" | grep '^distinct=' | cut -d= -f2
}

# assert xdg-open on the host reaches the app
desktop_assert_link_host_to_app() {
  local INIT="$1" APP_PKG="$2" EV="$3"
  local _before_failed=$FAILED
  gcmd_root "systemctl restart rhizo-app-events.service" 15 \
    || fail "could not restart rhizo-app-events.service to re-arm its trigger"
  local desktop_file=/usr/share/applications/rhizo-$APP_PKG.desktop
  wait_guest 240 "grep -q x-scheme-handler/rhizo-test $desktop_file" \
    || fail "no .desktop entry claiming the test scheme was synthesized for $APP_PKG"
  if gcmd_user "test -f $desktop_file"; then
    gcmd_user "cat $desktop_file" > "$EV/desktop-entry.txt" 2>&1
    grep -q 'x-scheme-handler/rhizo-test' "$EV/desktop-entry.txt" \
      || fail "the synthesized entry claims no scheme handler (see $EV/desktop-entry.txt)"
    grep -qE 'Exec=.*%u' "$EV/desktop-entry.txt" \
      || fail "the synthesized entry has no %u"
    local handler
    handler=$(gcmd_user "xdg-mime query default x-scheme-handler/rhizo-test" 15 | tr -d '\r')
    [[ "$handler" == "rhizo-$APP_PKG.desktop" ]] \
      || fail "the host's desktop database resolves rhizo-test to '$handler'"
    local uri got since
    uri="rhizo-test://open/$(nonce)"
    since=$(logcat_since_marker "$INIT")
    gcmd_user "xdg-open '$uri'" 30
    got=$(st "$(app_wait_token "RHIZO_VIEW uri=[^ ]*" 60 "$since")")
    if [[ "$got" == "RHIZO_VIEW uri=$uri" ]]; then
      pass "a link opened with xdg-open reached the Android app byte for byte"
    else
      fail "the app received '$got', the host opened '$uri'"
    fi
  else
    fail "no $desktop_file on the guest"
  fi
  (( FAILED == _before_failed ))
}

# assert an Android VIEW link reaches the host
desktop_assert_link_android_to_host() {
  local INIT="$1" APP_PKG="$2" APP_ACT="$3" BRIDGE_PKG="$4"
  local _before_failed=$FAILED
  android_sh "$INIT" "cmd role add-role-holder android.app.role.BROWSER $BRIDGE_PKG" >/dev/null 2>&1
  local role
  role=$(android_sh "$INIT" "cmd role get-role-holders android.app.role.BROWSER" | tr -d '\r')
  grep -q "$BRIDGE_PKG" <<<"$role" || fail "the android app did not take the browser role (got '$role')"
  gcmd_root "printf '#!/bin/sh\\nprintf \"%%s\\\\n\" \"\$1\" >> /tmp/rhizo-url-received\\n' > /tmp/rhizo-url-record.sh; chmod +x /tmp/rhizo-url-record.sh
printf '[Desktop Entry]\\nType=Application\\nName=Rhizo URL recorder\\nExec=/tmp/rhizo-url-record.sh %%u\\nMimeType=x-scheme-handler/https;\\nNoDisplay=true\\n' > /usr/share/applications/rhizo-url-record.desktop
rm -f /tmp/rhizo-url-received
update-desktop-database /usr/share/applications 2>/dev/null; true" 30 \
    || fail "could not stage the host's own URL recorder"
  gcmd_user "mkdir -p \$HOME/.config
if [ -e \$HOME/.config/mimeapps.list ] && [ ! -e \$HOME/.config/mimeapps.list.rhizo-url-record ]; then cp -p \$HOME/.config/mimeapps.list \$HOME/.config/mimeapps.list.rhizo-url-record; fi
printf '[Default Applications]\\nx-scheme-handler/https=rhizo-url-record.desktop\\n' > \$HOME/.config/mimeapps.list
true" 15 \
    || fail "could not set the session's own default handler for https"
  local outuri received since
  outuri="https://rhizo-out.example/$(nonce)"
  since=$(logcat_since_marker "$INIT")
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd send_url --es uri $outuri" >/dev/null 2>&1
  app_wait_token "RHIZO_SENT_VIEW" 30 "$since" >/dev/null || fail "the app never fired its VIEW intent"
  received=""
  local deadline=$(( $(date +%s) + 45 ))
  while (( $(date +%s) < deadline )); do
    received=$(gcmd_user "cat /tmp/rhizo-url-received 2>/dev/null | tail -1" 10 | tr -d '\r')
    [[ -n "$received" ]] && break
    sleep 2
  done
  received=$(st "$received")
  [[ "$received" == "$outuri" ]] || fail "the host handler received '$received', Android sent '$outuri'"
  [[ "$received" == "$outuri" ]] && pass "a link opened in Android reached the host's own handler byte for byte"
  desktop_link_recorder_undo
  (( FAILED == _before_failed ))
}

# remove the host URL recorder and restore mimeapps.list
desktop_link_recorder_undo() {
  gcmd_root "rm -f /usr/share/applications/rhizo-url-record.desktop /tmp/rhizo-url-record.sh /tmp/rhizo-url-received
update-desktop-database /usr/share/applications 2>/dev/null; true" 30 \
    || fail "could not remove the host's own URL recorder the Android-to-host link leg staged"
  gcmd_user "if [ -e \$HOME/.config/mimeapps.list.rhizo-url-record ]; then mv -f \$HOME/.config/mimeapps.list.rhizo-url-record \$HOME/.config/mimeapps.list; else rm -f \$HOME/.config/mimeapps.list; fi
true" 15 \
    || fail "could not put the session's own mimeapps.list back after the Android-to-host link leg"
}

# write drag-and-drop debug files to the evidence directory
desktop_dnd_evidence() {
  local ev="$1" label="$2" since="$3" deskd_off="${4:-}" out
  [[ -n "$ev" && -d "$ev" ]] || return 0
  out=$(rhizo_ctl_out "$INIT" | tail -20)
  printf '%s\n' "${out:-<none>}" > "$ev/$label-control-out.txt"
  if [[ "$deskd_off" =~ ^[0-9]+$ ]]; then
    out=$(ssh_vm -t 15 "tail -c +$(( deskd_off + 1 )) /var/log/rhizo/rhizo-deskd.log 2>/dev/null | grep -a -E 'pad never armed|drag carried|drag-out pad ready|no pad watching|drop .* on composer display|pointer enter' | tail -40")
    printf '%s\n' "${out:-<none>}" > "$ev/$label-dnd-deskd.txt"
  else
    echo '<none: rhizo-deskd.log offset unread before the leg>' > "$ev/$label-dnd-deskd.txt"
  fi
  out=""
  [[ -n "$since" ]] && out=$(android_sh "$INIT" "logcat -d -b all -t '$since'" | grep -a -E 'RHIZO_DROP_|RHIZO_DRAG' | tail -60)
  printf '%s\n' "${out:-<none>}" > "$ev/$label-dnd-logcat.txt"
  out=""
  [[ -n "$since" ]] && out=$(android_sh "$INIT" "logcat -d -b crash -t '$since'" | tail -150)
  printf '%s\n' "${out:-<none>}" > "$ev/$label-dnd-crash.txt"
  local f cmd
  for f in outputs tree clip-out sway-log; do
    out=""
    if [[ "${RHIZO_DESKTOP_PROFILE:-}" == sway ]]; then
      case "$f" in
        outputs) cmd="swaymsg -t get_outputs" ;;
        tree) cmd="swaymsg -t get_tree" ;;
        clip-out) cmd="tail -40 /tmp/rhizo-clip.out" ;;
        sway-log) cmd="tail -80 /tmp/rhizo-sway-1000.log" ;;
      esac
      out=$(gcmd_user "$cmd" 20)
    fi
    printf '%s\n' "${out:-<none>}" > "$ev/$label-dnd-$f.txt"
  done
  return 0
}

# run toybox in the guest
_dnd_ctl_read() {
  local init="$1" out; shift
  out=$(_ssh_vm_out 10 "nsenter -a -t $init -- /system/bin/toybox $*")
  [[ -z "$out" ]] && out=$(probe_cmd 10 "/system/bin/toybox $*")
  printf '%s' "$out"
}

# print the line count of control.out
_dnd_ctl_lines() {
  local out; out=$(_dnd_ctl_read "$1" wc -l /data/rhizo_control/control.out | tr -d '\r')
  [[ "$out" =~ ^[[:space:]]*([0-9]+)[[:space:]]+/data/rhizo_control/control\.out$ ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# assert a host drop reaches the Android window
desktop_assert_dnd_drop_onto_app() {
  local INIT="$1" cdisp="$2" EV="$3"
  local _before_failed=$FAILED
  local drop_payload drop_b64 rect since deskd_off why label="drop-d$cdisp"
  drop_payload="rhizo-drop-$(nonce)"
  drop_b64=$(printf '%s' "$drop_payload" | base64 -w0)
  since=$(logcat_since_marker "$INIT")
  deskd_off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) || deskd_off=""
  if ! why=$(desktop_activate_display_window "$cdisp"); then
    fail "the Android window could not be raised to drop onto: $why"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    return 1
  fi
  if ! rect=$(desktop_mapped_window_rect "$cdisp"); then
    fail "the Android window has no rect to drop onto: ${rect:-it is not mapped}"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    return 1
  fi
  local wx wy ww wh drop_x drop_y
  read -r wx wy ww wh <<<"$rect"
  drop_x=$(( wx + ww / 2 )); drop_y=$(( wy + wh / 2 ))
  log "    dropping at $drop_x,$drop_y over the ${ww}x${wh} window at +$wx+$wy"
  local before_n after_drops landed=0 deadline
  if ! before_n=$(_dnd_ctl_lines "$INIT"); then
    fail "control.out's line count did not read before the drop"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    return 1
  fi
  if ! why=$(desk_dnd pad on); then
    fail "the system test's drag pad never mapped: $why"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    return 1
  fi
  if ! why=$(desk_dnd drop "$drop_x" "$drop_y" text/plain "$drop_b64"); then
    fail "the host drag never reached the Android window: $why"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    desk_dnd pad off >/dev/null 2>&1
    return 1
  fi
  deadline=$(( $(date +%s) + 45 ))
  while (( $(date +%s) < deadline )); do
    after_drops=$(_dnd_ctl_read "$INIT" tail -n "+$(( before_n + 1 ))" /data/rhizo_control/control.out \
      | grep -c "^drop id=$cdisp port=")
    (( after_drops > 0 )) && { landed=1; break; }
    sleep 2
  done
  if (( landed == 0 )); then
    fail "the compositor never delivered a drop to display $cdisp, the Android window's own surface"
    gcmd_user "tail -5 /tmp/rhizo-clip.out" | sed 's/^/    | /'
  else
    pass "the compositor delivered a real drop to the Android window's own surface"
    local got got_text
    got=$(app_wait_token "RHIZO_DROP mime=[^ ]* b64=[A-Za-z0-9+/=]*" 60 "$since")
    if [[ -z "$got" ]]; then
      fail "the app never reported a drop"
      android_sh "$INIT" "logcat -d -b all" | grep -a -E 'RHIZO_DROP_|RHIZO_DRAG_' | tail -6 | sed 's/^/    | /'
    else
      got_text=$(st "$(printf '%s' "${got##*b64=}" | base64 -d 2>/dev/null)")
      [[ "$got_text" == "$drop_payload" ]] \
        || fail "the app received '$got_text', the host dragged '$drop_payload'"
      [[ "$got_text" == "$drop_payload" ]] \
        && pass "a real Android drop delivered the host's bytes to the app's own uid"
    fi
  fi
  desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
  desk_dnd pad off >/dev/null 2>&1
  (( FAILED == _before_failed ))
}

# assert Android drag-out reaches the host
desktop_assert_dnd_drag_out_of_app() {
  local INIT="$1" APP_PKG="$2" APP_ACT="$3" cdisp="$4" EV="${5:-${EV:-}}"
  local _before_failed=$FAILED
  local out_payload out_b64 why since deskd_off label="dragout-d$4"
  out_payload="rhizo-dragout-$(nonce)"
  out_b64=$(printf '%s' "$out_payload" | base64 -w0)
  since=$(logcat_since_marker "$INIT")
  deskd_off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) || deskd_off=""
  if [[ -z "$cdisp" ]]; then
    fail "no Android window to drag out of"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    return 1
  fi
  if ! why=$(desk_dnd pad on); then
    fail "the system test's drag pad never mapped: $why"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    return 1
  fi
  local rect wx wy ww wh press_x press_y pad_point
  if ! why=$(desktop_activate_display_window "$cdisp"); then
    fail "the Android window could not be raised to drag out of: $why"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    desk_dnd pad off >/dev/null 2>&1
    return 1
  fi
  if ! rect=$(desktop_mapped_window_rect "$cdisp"); then
    fail "the Android window has no rect to drag out of: ${rect:-it is not mapped}"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    desk_dnd pad off >/dev/null 2>&1
    return 1
  fi
  read -r wx wy ww wh <<<"$rect"
  press_x=$(( wx + ww / 2 )); press_y=$(( wy + wh / 2 ))
  if ! pad_point=$(desk_dnd pad-point); then
    fail "the system test's drag pad has no position to carry the drag to: $pad_point"
    desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
    desk_dnd pad off >/dev/null 2>&1
    return 1
  fi
  local watch_ready=0 deadline n
  deadline=$(( $(date +%s) + 45 ))
  while (( $(date +%s) < deadline )); do
    n=$(android_sh "$INIT" "logcat -d -b all" | grep -a -c 'RHIZO_DRAGWATCH_READY')
    (( ${n:-0} > 0 )) && { watch_ready=1; break; }
    sleep 3
  done
  (( watch_ready == 1 )) || fail "no pad ever reported itself watching for drags out"
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd drag_out --es kind text --es mime text/plain --es b64 $out_b64" >/dev/null 2>&1
  app_wait_token "RHIZO_DRAG_ARMED_OUT" 30 "$since" >/dev/null || fail "the app never armed its drag"
  desk_dnd release >/dev/null 2>&1
  why=$(desk_dnd press "$press_x" "$press_y") || fail "the press on the Android window at $press_x,$press_y failed: $why"
  app_wait_token "RHIZO_DRAG_STARTED" 30 "$since" >/dev/null || fail "the app never started its drag"
  app_wait_token "RHIZO_DRAGOUT_DATA" 60 "$since" >/dev/null || fail "the pad never read the app's drag payload"
  local out_since; out_since=$(clip_mark) || out_since=0
  why=$(desk_dnd moveto $pad_point) || fail "carrying the drag to the pad at $pad_point failed: $why"
  clip_await '^dragenter ' "$out_since" 15 >/dev/null || fail "the drag never entered the pad at $pad_point"
  why=$(desk_dnd release) || fail "releasing the drag over the pad failed: $why"
  local got_out="" out_started
  out_started=$(date +%s)
  got_out=$(clip_await '^dropped ' "$out_since" 150)
  (( $? == 0 )) || got_out=""
  log "    the host side answered after $(( $(date +%s) - out_started ))s"
  if [[ -z "$got_out" ]]; then
    fail "the host never received the drag leaving Android"
    android_sh "$INIT" "logcat -d -b all" | grep -a -E 'RHIZO_DRAGOUT|RHIZO_DRAGWATCH|RHIZO_DRAG_' | tail -5 | sed 's/^/    | /'
    android_sh "$INIT" "logcat -d -b all" | grep -a -E 'WaylandBackend::StartDrag' | tail -3 | sed 's/^/    | /'
    ssh_vm -t 15 "tail -6 /var/log/rhizo/rhizo-deskd.log" | sed 's/^/    | /'
  else
    local out_text
    out_text=$(st "$(printf '%s' "${got_out##* }" | base64 -d 2>/dev/null)")
    [[ "$out_text" == "$out_payload" ]] || fail "the host received '$out_text', the app dragged '$out_payload'"
    [[ "$out_text" == "$out_payload" ]] && pass "a drag out of an Android window delivered its bytes to a host client"
  fi
  desktop_dnd_evidence "$EV" "$label" "$since" "$deskd_off"
  desk_dnd pad off >/dev/null 2>&1
  (( FAILED == _before_failed ))
}

# assert a host GUI program runs in rhizo_host
desktop_assert_host_client_intact() {
  local INIT="$1" EV="$2"
  local _before_failed=$FAILED
  local env uid wd rd
  env=$(desk_env 2>/dev/null)
  uid=$(grep -o 'RHIZO_DESK_UID=[0-9]*' <<<"$env" | cut -d= -f2)
  wd=$(grep -o 'WAYLAND_DISPLAY=[^[:space:]]*' <<<"$env" | cut -d= -f2)
  rd=$(grep -o 'XDG_RUNTIME_DIR=[^[:space:]]*' <<<"$env" | cut -d= -f2)
  if [[ -z "$uid" || -z "$wd" || -z "$rd" ]]; then
    fail "host.desktop-intact: could not resolve the desktop session's own uid/WAYLAND_DISPLAY/XDG_RUNTIME_DIR from desk_env"
    return 1
  fi
  local desk_user; desk_user=$(ssh_vm -t 10 "getent passwd $uid | cut -d: -f1" | tr -d '[:space:]')
  if [[ -z "$desk_user" ]]; then
    fail "host.desktop-intact: could not resolve uid $uid to an account name"
    return 1
  fi

  local sock="$rd/$wd" comp_pid comp_ctx
  comp_pid=$(desk_user_sh --user "$desk_user" 10 "fuser '$sock' 2>/dev/null" | tr -d '[:space:]')
  if [[ -z "$comp_pid" ]]; then
    fail "host.desktop-intact: could not resolve the compositor's own pid from the session's Wayland socket ($sock)"
    return 1
  fi
  comp_ctx=$(ssh_vm -t 10 "cat /proc/$comp_pid/attr/current 2>/dev/null" | tr -d '\000\r\n')

  local before_out
  if ! before_out=$(desk_windows 2>/dev/null); then
    fail "host.desktop-intact: the 'before' desk_windows read failed"
    return 1
  fi

  desk_user_sh --user "$desk_user" 20 "systemctl --user reset-failed rhizo-lifecycle-hostclient.service 2>/dev/null; true" >/dev/null 2>&1
  desk_user_sh --user "$desk_user" 20 "systemd-run --user --collect --unit=rhizo-lifecycle-hostclient -E WAYLAND_DISPLAY=$wd -- foot" >/dev/null 2>&1
  local mapped=0 deadline
  deadline=$(( $(date +%s) + 20 ))
  while (( $(date +%s) < deadline )); do
    local windows_now; windows_now=$(desk_windows 2>/dev/null)
    if grep -qF '"app_id": "foot"' <<<"$windows_now"; then
      mapped=1
      break
    fi
    sleep 1
  done
  local pid ctx
  pid=$(desk_user_sh --user "$desk_user" 15 "systemctl --user show -p MainPID --value rhizo-lifecycle-hostclient.service" | tr -d '[:space:]')
  if [[ -n "$pid" && "$pid" != 0 ]]; then
    ctx=$(ssh_vm -t 15 "cat /proc/$pid/attr/current 2>/dev/null" | tr -d '\000\r\n')
  fi
  desk_user_sh --user "$desk_user" 15 "systemctl --user stop rhizo-lifecycle-hostclient.service" >/dev/null 2>&1
  {
    echo "before=$(grep -c . <<<"$before_out") mapped=$mapped pid=${pid:-<none>} context=${ctx:-<none>}"
    echo "compositor_pid=$comp_pid compositor_context=${comp_ctx:-<none>}"
  } > "$EV/host-desktop-intact.txt"

  if (( mapped == 0 )); then
    fail "host.desktop-intact: a host GUI client launched inside the session never mapped a window with app_id foot"
  elif [[ -z "$pid" || "$pid" == 0 ]]; then
    fail "host.desktop-intact: systemd --user never reported a MainPID for the host client"
  elif [[ "$ctx" != *:rhizo_host:* ]]; then
    fail "host.desktop-intact: the host client's own context is '${ctx:-<empty>}', not rhizo_host"
  elif [[ "$comp_ctx" != *:rhizo_host:* ]]; then
    fail "host.desktop-intact: the compositor's own context (pid $comp_pid, the session's Wayland socket owner) is '${comp_ctx:-<empty>}', not rhizo_host"
  else
    pass "host.desktop-intact: a host GUI client launched inside the session mapped app_id foot and ran in rhizo_host (pid $pid), the same as the compositor itself (pid $comp_pid)"
  fi
  (( FAILED == _before_failed ))
}
