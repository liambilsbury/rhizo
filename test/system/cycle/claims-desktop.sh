#!/bin/bash
# define the desktop lifecycle claim checks

_LC_DESKTOP_LAUNCH_ERR="" _LC_DESKTOP_LAUNCH_CDISP=""
LC_DESKTOP_PEER_PKG=com.android.deskclock
LC_DESKTOP_PEER_ACT=com.android.deskclock.DeskClock
# launch the app and read its composer display
_lc_desktop_launch_new_display() {
  local label="$1" pkg="$2" act="$3"
  _LC_DESKTOP_LAUNCH_ERR="" _LC_DESKTOP_LAUNCH_CDISP=""
  if ! desktop_close_all_app_windows 20 "rhizo-$pkg"; then
    _LC_DESKTOP_LAUNCH_ERR="$pkg's open windows did not close before its new launch"
    return 1
  fi
  local before_n; before_n=$(ssh_vm -t 15 'wc -l < /run/rhizo-launch/rhizo-launch.log 2>/dev/null' | tr -d '[:space:]')
  [[ "$before_n" =~ ^[0-9]+$ ]] || before_n=0
  local out; out=$(ssh_vm -t 300 "/usr/lib/rhizo/tools/rhizo-launch.sh $pkg $act >/tmp/rhizo-lifecycle-launch-$label.log 2>&1; echo rc=\$?")
  if [[ "$(tail -1 <<<"$out")" != "rc=0" ]]; then
    _LC_DESKTOP_LAUNCH_ERR="rhizo-launch.sh for $pkg/$act did not report rc=0 (last line: $(tail -1 <<<"$out"); its log ends: $(ssh_vm -t 15 "tail -3 /tmp/rhizo-lifecycle-launch-$label.log" 2>/dev/null | tr '\n' ' '))"
    return 1
  fi
  local new_lines; new_lines=$(ssh_vm -t 60 "tail -n +$((before_n + 1)) /run/rhizo-launch/rhizo-launch.log 2>/dev/null")
  local hits; hits=$(grep -c 'event=am_start_return pid=' <<<"$new_lines")
  if [[ "$hits" != 1 ]]; then
    _LC_DESKTOP_LAUNCH_ERR="expected exactly one new event=am_start_return line for $pkg/$act after line $before_n, got $hits"
    return 1
  fi
  if grep -q 'committed=skipped' <<<"$new_lines"; then
    _LC_DESKTOP_LAUNCH_ERR="$pkg/$act went back onto a display it already had, not a new one"
    return 1
  fi
  local line cdisp
  line=$(grep 'event=am_start_return pid=' <<<"$new_lines")
  cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$line" | cut -d= -f2)
  if [[ -z "$cdisp" ]]; then
    _LC_DESKTOP_LAUNCH_ERR="the new event=am_start_return line for $pkg/$act names no cdisplay= ($line)"
    return 1
  fi
  _LC_DESKTOP_LAUNCH_CDISP=$cdisp
}

# print FOUND for a window with this app_id
_lc_desktop_window_app_id_exact() {
  local want="$1" w
  w=$(desk_windows 2>/dev/null) || return 1
  python3 -c "
import json, sys
want = sys.argv[1]
for l in sys.stdin:
    l = l.strip()
    if not l:
        continue
    try:
        win = json.loads(l)
    except ValueError:
        continue
    if win.get('app_id') == want:
        print('FOUND')
        break
" "$want" <<<"$w"
}

# wait for a window with this app_id
_lc_desktop_await_app_id() {
  local end=$(( $(date +%s) + ${2:-15} ))
  while :; do
    [[ "$(_lc_desktop_window_app_id_exact "$1")" == FOUND ]] && { echo FOUND; return 0; }
    (( $(date +%s) < end )) || return 1
    sleep 0.5
  done
}

# print the sandbox's cgroup path
_lc_desktop_stack_cgroup() {
  local init_pid="$1" ipath result
  ipath=$(ssh_vm -t 10 "sed -n 's|^0::||p' /proc/$init_pid/cgroup" 2>/dev/null)
  [[ -n "$ipath" ]] || return 1
  result=$(ssh_vm -t 10 "level='$ipath'
    while :; do
      [ -d \"/sys/fs/cgroup\$level/system\" ] && { echo \"\$level\"; break; }
      [ \"\$level\" = / ] && break
      level=\${level%/*}
      [ -z \"\$level\" ] && level=/
    done" 2>/dev/null)
  [[ -n "$result" ]] || return 1
  printf '/sys/fs/cgroup%s' "${result%/}"
}

# grant POST_NOTIFICATIONS to the fixture app
_lc_desktop_fixture_may_notify() {
  android_sh "$INIT" "pm grant $APP_PKG android.permission.POST_NOTIFICATIONS" >/dev/null 2>&1
  local dump rc grants
  dump=$(android_sh "$INIT" "dumpsys package $APP_PKG"); rc=$?
  if (( rc != 0 )) || [[ -z "$dump" ]]; then
    echo "dumpsys package $APP_PKG read nothing (rc $rc)"
    return 1
  fi
  grants=$(grep -a -o 'android.permission.POST_NOTIFICATIONS: granted=[a-z]*' <<<"$dump" | sort -u | tr '\n' ' ')
  [[ "$grants" == 'android.permission.POST_NOTIFICATIONS: granted=true ' ]] && return 0
  echo "$APP_PKG does not hold POST_NOTIFICATIONS after pm grant (dumpsys package: ${grants:-no POST_NOTIFICATIONS grant line})"
  return 1
}

# wait for a notification in NotificationManagerService
_lc_desktop_nms_holds() {
  local id="$1" deadline=$(( $(date +%s) + $2 )) keys
  while (( $(date +%s) < deadline )); do
    keys=$(android_sh "$INIT" "cmd notification list")
    grep -a -q -F -- "|$APP_PKG|$id|" <<<"$keys" && return 0
    sleep 1
  done
  return 1
}

_LC_DESKTOP_NOTIFY_REC="" _LC_DESKTOP_NOTIFY_ID="" _LC_DESKTOP_NOTIFY_ERR="" _LC_DESKTOP_NOTIFY_OFF="" _LC_DESKTOP_NOTIFY_AID=""
# post a notification and wait for its record
_lc_desktop_notify_post_via_desk() {
  local title="$1" icon_b64="${2:-}" reply="${3:-}" why off posted id
  _LC_DESKTOP_NOTIFY_REC="" _LC_DESKTOP_NOTIFY_ID="" _LC_DESKTOP_NOTIFY_ERR="" _LC_DESKTOP_NOTIFY_OFF="" _LC_DESKTOP_NOTIFY_AID=""
  if ! desk_notifications list >/dev/null 2>&1; then
    _LC_DESKTOP_NOTIFY_ERR="the desktop's notification service did not answer before the post (desk_notifications list failed)"
    return 1
  fi
  why=$(_lc_desktop_fixture_may_notify) || { _LC_DESKTOP_NOTIFY_ERR="$why"; return 1; }
  off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) \
    || { _LC_DESKTOP_NOTIFY_ERR="rhizo-deskd.log's size read no byte offset"; return 1; }
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd notify --es title $title --es body rhizo-notify-body${icon_b64:+ --es icon_b64 $icon_b64}${reply:+ --ez reply true}" >/dev/null 2>&1
  if ! posted=$(app_wait_token "RHIZO_NOTIF_POSTED id=[0-9]* title=$title" 30); then
    _LC_DESKTOP_NOTIFY_ERR="the app never logged RHIZO_NOTIF_POSTED for title $title"
    return 1
  fi
  id=${posted#RHIZO_NOTIF_POSTED id=}; id=${id%% *}
  _LC_DESKTOP_NOTIFY_OFF=$off _LC_DESKTOP_NOTIFY_AID=$id
  if ! _lc_desktop_nms_holds "$id" 15; then
    _LC_DESKTOP_NOTIFY_ERR="NotificationManagerService never listed $APP_PKG's notification $id (cmd notification list), though the app logged RHIZO_NOTIF_POSTED for $title: NMS dropped the post"
    return 1
  fi
  local deadline rec; deadline=$(( $(date +%s) + 45 ))
  while (( $(date +%s) < deadline )); do
    rec=$(desk_notifications list 2>/dev/null | python3 -c "
import json, sys
want = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if rec.get('title') == want:
        print(json.dumps(rec))
        break
" "$title")
    if [[ -n "$rec" ]]; then
      _LC_DESKTOP_NOTIFY_REC=$rec
      _LC_DESKTOP_NOTIFY_ID=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("id", ""))' "$rec")
      return 0
    fi
    sleep 2
  done
  local dlog
  dlog=$(ssh_vm -t 15 "tail -c +$((off + 1)) /var/log/rhizo/rhizo-deskd.log 2>/dev/null" \
    | grep -a -F -e "|$APP_PKG|$id|" -e "notification from $APP_PKG" -e 'a desktop notification call failed' -e 'desktop notification queue is full' \
    | tail -3 | tr '\n' ' ')
  _LC_DESKTOP_NOTIFY_ERR="desk_notifications list never recorded a notification with title $title within 45s of NMS posting it as $id; rhizo-deskd.log past byte $off: ${dlog:-no line naming it}"
  return 1
}

# restart rhizo-deskd.service and wait for authentication
_lc_desktop_bridge_restart() {
  local off why
  off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) \
    || { echo "rhizo-deskd.log's size read no byte offset"; return 1; }
  ssh_vm -t 30 'systemctl restart rhizo-deskd.service' >/dev/null 2>&1
  why=$(desk_unit_await_active rhizo-deskd.service 60) || { echo "$why"; return 1; }
  why=$(desk_token_settled 360) || { echo "the token delivery after the restart did not settle: $why"; return 1; }
  desk_bridge_await_auth "$off" 60 \
    || { echo "rhizo-deskd logged no 'android app authenticated' past byte $off within 60s of its token delivery"; return 1; }
}

# wait for rhizo-deskd's authenticated log line
_lc_desktop_bridge_current() {
  local deadline=$(( $(date +%s) + $1 )) why out=""
  why=$(desk_unit_await_active rhizo-deskd.service 120) || { echo "$why"; return 1; }
  why=$(desk_token_settled 360) || { echo "the token delivery did not settle: $why"; return 1; }
  while (( $(date +%s) < deadline )); do
    out=$(ssh_vm -t 15 "awk '/listening on /{n=NR; a=0; d=0} /android app authenticated/{a=NR} /android app disconnected/{d=NR}
END{print (n && a > d) ? \"BRIDGE_CURRENT\" : \"BRIDGE_NOT_CURRENT\"}' /var/log/rhizo/rhizo-deskd.log 2>/dev/null; echo DONE")
    lc_done_strip out || out=""
    [[ "$out" == BRIDGE_CURRENT ]] && return 0
    sleep 2
  done
  echo "rhizo-deskd's log since its last 'listening on' carries no 'android app authenticated' that no 'android app disconnected' followed, within $1s (last read: ${out:-<unfinished>})"
  return 1
}

# print the resumed activity on each display
_lc_desktop_resumed_pkgacts() {
  local out rc
  out=$(android_sh "$INIT" 'dumpsys activity activities; echo "RHIZO_DUMPSYS_RC=$?"'); rc=$?
  if (( rc != 0 )) || ! grep -qx 'RHIZO_DUMPSYS_RC=0' <<<"$out" || ! grep -q 'Display #' <<<"$out"; then
    local shown="<nothing>"
    [[ -n "$out" ]] && shown="$(head -c 160 <<<"$out" | tr '\n' ' ')..."
    echo "dumpsys activity activities did not complete (android_sh rc=$rc, $(grep -o 'RHIZO_DUMPSYS_RC=[0-9]*' <<<"$out" || echo 'no exit status'), $(grep -c 'Display #' <<<"$out") display segment(s): $shown)" >&2
    return 1
  fi
  grep 'topResumedActivity=' <<<"$out" \
    | sed 's/.*ActivityRecord{[^ ]* [^ ]* \([^ }]*\).*/\1/'
}

# check the app window on its display
lc_assert_desktop.windows-usable() {
  lc_need_guest desktop.windows-usable || return 1
  if [[ -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "desktop.windows-usable: no fixture package/activity resolved this cycle"
    return 1
  fi
  _lc_desktop_launch_new_display windows-usable "$APP_PKG" "$APP_ACT"
  local cdisp=$_LC_DESKTOP_LAUNCH_CDISP
  if [[ -z "$cdisp" ]]; then
    fail "desktop.windows-usable: $_LC_DESKTOP_LAUNCH_ERR"
    return 1
  fi
  if [[ "$(_lc_desktop_await_app_id "rhizo-$APP_PKG")" != FOUND ]]; then
    fail "desktop.windows-usable: no desk_windows entry has app_id exactly rhizo-$APP_PKG on display $cdisp within 15s of its launch"
    return 1
  fi
  local toplevel; toplevel=$(resolve_display_toplevel "$cdisp" 2>/dev/null)
  if [[ "$toplevel" != "rhizo-$APP_PKG "* ]]; then
    fail "desktop.windows-usable: resolve_display_toplevel $cdisp reports '$toplevel', not app_id rhizo-$APP_PKG"
    return 1
  fi
  local raise_why
  if ! raise_why=$(desktop_activate_display_window "$cdisp"); then
    fail "desktop.windows-usable: $raise_why"
    return 1
  fi
  local before=$FAILED
  assert_window_painted "cycle-desktop-windows-usable" "$cdisp"
  (( FAILED == before )) \
    && pass "desktop.windows-usable: app_id rhizo-$APP_PKG is mapped and really painted on display $cdisp" \
    || return 1
}

_LC_CLIP_SET_WHY="" _LC_CLIP_SET_OFF="" _LC_CLIP_SET_SINCE=""
# set the host clipboard through desk_clipboard
_lc_desktop_clip_set() {
  local f="$EV/$1-clip-set.txt" rc
  _LC_CLIP_SET_OFF=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) || _LC_CLIP_SET_OFF=""
  _LC_CLIP_SET_SINCE=$(logcat_since_marker "$INIT") || _LC_CLIP_SET_SINCE=""
  desk_clipboard set "$2" "$3" > "$f" 2>&1; rc=$?
  [[ -s "$f" ]] || echo '<none>' > "$f"
  _LC_CLIP_SET_WHY="desk_clipboard set rc=$rc: $(head -c 300 "$f" | tr '\n' ' ')"
  return "$rc"
}

# write rhizo-deskd's clipboard log lines to a file
_lc_deskd_clip_trail() {
  local lines
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    lines=$(ssh_vm -t 15 "tail -c +$(( $1 + 1 )) /var/log/rhizo/rhizo-deskd.log 2>/dev/null | grep -a -e ' clip ' -e 'wlbridge' | tail -60")
    printf '%s\n' "${lines:-<none>}" > "$2"
  else
    echo '<none: rhizo-deskd.log offset unread before the leg>' > "$2"
  fi
}

# write the clipboard evidence files
_lc_desktop_clip_evidence() {
  local comp
  printf '%s\n' "${2:-<none>}" > "$EV/$1-clip-read.txt"
  if [[ "$_LC_CLIP_SET_SINCE" =~ ^[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.000$ ]]; then
    comp=$(android_sh "$INIT" "logcat -d -b all -t '$_LC_CLIP_SET_SINCE'" | grep -a -E 'WaylandBackend: selection|control: clip' | tail -40)
    printf '%s\n' "${comp:-<none>}" > "$EV/$1-clip-composer.txt"
  else
    echo '<none: no logcat marker before the set>' > "$EV/$1-clip-composer.txt"
  fi
  _lc_deskd_clip_trail "$_LC_CLIP_SET_OFF" "$EV/$1-clip-deskd.txt"
}

# wait for rhizo-deskd to relay the clipboard
_lc_desktop_clip_relayed() {
  local mime="$1" n="$2" deadline=$(( $(date +%s) + $3 )) out
  [[ "$_LC_CLIP_SET_OFF" =~ ^[0-9]+$ ]] \
    || { echo "rhizo-deskd.log's offset was unread before the set"; return 1; }
  while (( $(date +%s) < deadline )); do
    out=$(ssh_vm -t 15 "tail -c +$(( _LC_CLIP_SET_OFF + 1 )) /var/log/rhizo/rhizo-deskd.log; echo DONE" | tr -d '\r')
    lc_done_strip out && grep -a -q -E -- " clip (composer|host) -> android: $mime, $n bytes\$" <<<"$out" && return 0
    sleep 1
  done
  echo "rhizo-deskd never relayed the host's $mime ($n bytes) to the android app within ${3}s of the set; its relays past the set: $(grep -a -E -- ' clip (composer|host) -> android: ' <<<"$out" | tail -3 | tr '\n' ' ')"
  return 1
}

# copy a nonce between host and Android clipboards
lc_assert_desktop.clipboard-both-ways() {
  lc_need_guest desktop.clipboard-both-ways || return 1
  if [[ -z "$INIT" || -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "desktop.clipboard-both-ways: no live Android init/fixture package resolved this cycle"
    return 1
  fi
  local ok=1

  local want; want="rhizo-h2a-$(nonce)"
  _lc_desktop_clip_set "$TEST_STEP-h2a" text/plain "$(printf '%s' "$want" | base64 -w0)"
  local got="" rc=0 relay_why
  if ! relay_why=$(_lc_desktop_clip_relayed text/plain "${#want}" 60); then
    rc=3
  else
    got=$(clip_read 'RHIZO_CLIP_READ mime=[^ ]* b64=[A-Za-z0-9+/=]*' 45 "$EV/$TEST_STEP-clip-h2a-focus.txt")
    rc=$?
  fi
  _lc_desktop_clip_evidence "$TEST_STEP-h2a" "$got"
  if (( rc == 3 )); then
    fail "desktop.clipboard-both-ways: $relay_why ($_LC_CLIP_SET_WHY)"
    ok=0
  elif (( rc == 2 )); then
    fail "desktop.clipboard-both-ways: the app read an empty clipboard (RHIZO_CLIP_EMPTY, no focus) -- see $EV/$TEST_STEP-clip-h2a-focus.txt ($_LC_CLIP_SET_WHY)"
    ok=0
  elif [[ -z "$got" ]]; then
    fail "desktop.clipboard-both-ways: the app never reported a clipboard read (host -> Android) ($_LC_CLIP_SET_WHY)"
    ok=0
  else
    local got_text; got_text=$(printf '%s' "${got##*b64=}" | base64 -d 2>/dev/null)
    [[ "$got_text" == "$want" ]] \
      || { fail "desktop.clipboard-both-ways: the app read '$got_text', the host set '$want'"; ok=0; }
  fi

  local want2 want2_b64; want2="rhizo-a2h-$(nonce)"; want2_b64=$(printf '%s' "$want2" | base64 -w0)
  local before_n; before_n=$(android_sh "$INIT" "logcat -d -b all" | grep -c 'RHIZO_CLIP_WROTE')
  local why mark
  why=$(desk_clipboard focus-rhizo) \
    || { fail "desktop.clipboard-both-ways: no Rhizo window took focus for the app's copy: $why"; ok=0; }
  mark=$(desk_clipboard mark) || mark=""
  local setok_before; setok_before=$(_dnd_ctl_lines "$INIT") || setok_before=""
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_write --es mime text/plain --es b64 $want2_b64" >/dev/null 2>&1
  local wrote=0 deadline; deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    local now_n; now_n=$(android_sh "$INIT" "logcat -d -b all" | grep -c 'RHIZO_CLIP_WROTE')
    (( now_n > before_n )) && { wrote=1; break; }
    sleep 2
  done
  local setok=0
  if (( wrote == 1 )) && [[ "$setok_before" =~ ^[0-9]+$ ]]; then
    deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < deadline )); do
      _dnd_ctl_read "$INIT" tail -n "+$(( setok_before + 1 ))" /data/rhizo_control/control.out \
        | grep -q '^clip set-ok cid=' && { setok=1; break; }
      sleep 1
    done
  fi
  if (( wrote == 0 )); then
    fail "desktop.clipboard-both-ways: the app never wrote its clip (RHIZO_CLIP_WROTE stayed at $before_n)"
    ok=0
  elif (( setok == 0 )); then
    fail "desktop.clipboard-both-ways: the composer never acknowledged the app's clip (no 'clip set-ok' on control.out past line ${setok_before:-<unread>})"
    ok=0
  else
    local got2_b64; got2_b64=$(desk_clipboard get text/plain 45 "$mark")
    if [[ -z "$got2_b64" ]]; then
      fail "desktop.clipboard-both-ways: the host selection never carried the app's clip"
      ok=0
    else
      local got2_text; got2_text=$(printf '%s' "$got2_b64" | base64 -d 2>/dev/null)
      [[ "$got2_text" == "$want2" ]] \
        || { fail "desktop.clipboard-both-ways: the host read '$got2_text', the app set '$want2'"; ok=0; }
    fi
  fi

  (( ok )) \
    && pass "desktop.clipboard-both-ways: a nonce crossed byte for byte in both directions" \
    || return 1
}

# copy a PNG between host and Android clipboards
lc_assert_desktop.clipboard-images() {
  lc_need_guest desktop.clipboard-images || return 1
  if [[ -z "$INIT" || -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "desktop.clipboard-images: no live Android init/fixture package resolved this cycle"
    return 1
  fi
  local ok=1 host_png="$WORKDIR/$TEST_STEP-lc-clip-h2a.png" android_png="$WORKDIR/$TEST_STEP-lc-clip-a2h.png"

  local h_nonce; h_nonce=$(nonce)
  make_png "$host_png" "$(( 16#${h_nonce:0:2} ))" "$(( 16#${h_nonce:2:2} ))" "$(( 16#${h_nonce:4:2} ))"
  local host_b64; host_b64=$(base64 -w0 < "$host_png")
  local before_read_n; before_read_n=$(android_sh "$INIT" "logcat -d -b all" | grep -c 'RHIZO_CLIP_READ mime=image/png')
  _lc_desktop_clip_set "$TEST_STEP-image-h2a" image/png "$host_b64"
  local got="" rc=0 relay_why
  if ! relay_why=$(_lc_desktop_clip_relayed image/png "$(stat -c%s "$host_png")" 60); then
    rc=3
  else
    got=$(clip_read 'RHIZO_CLIP_READ mime=image/png b64=[A-Za-z0-9+/=]*' 60 "$EV/$TEST_STEP-clip-image-h2a-focus.txt")
    rc=$?
  fi
  _lc_desktop_clip_evidence "$TEST_STEP-image-h2a" "$got"
  if (( rc == 3 )); then
    fail "desktop.clipboard-images: $relay_why ($_LC_CLIP_SET_WHY)"
    ok=0
  elif (( rc == 2 )); then
    fail "desktop.clipboard-images: the app read an empty image clipboard (RHIZO_CLIP_EMPTY, no focus) ($_LC_CLIP_SET_WHY)"
    ok=0
  elif [[ -z "$got" ]]; then
    fail "desktop.clipboard-images: the app never reported reading an image clip (host -> Android) ($_LC_CLIP_SET_WHY)"
    ok=0
  elif (( $(android_sh "$INIT" "logcat -d -b all" | grep -c 'RHIZO_CLIP_READ mime=image/png') <= before_read_n )); then
    fail "desktop.clipboard-images: clip_read returned a hit but RHIZO_CLIP_READ's own count for image/png never rose above $before_read_n"
    ok=0
  else
    printf '%s' "${got##*b64=}" | base64 -d > "$EV/$TEST_STEP-clip-image-h2a-read.png" 2>/dev/null
    if cmp -s "$host_png" "$EV/$TEST_STEP-clip-image-h2a-read.png"; then
      local d; d=$(png_distinct "$EV/$TEST_STEP-clip-image-h2a-read.png")
      awk -v v="${d:-0}" 'BEGIN { exit !(v + 0 > 20) }' \
        || { fail "desktop.clipboard-images: the image the app read has only ${d:-0} distinct colors"; ok=0; }
    else
      fail "desktop.clipboard-images: the image the app read differs from the one the host set"
      ok=0
    fi
  fi

  local a_nonce; a_nonce=$(nonce)
  make_png "$android_png" "$(( 16#${a_nonce:0:2} ))" "$(( 16#${a_nonce:2:2} ))" "$(( 16#${a_nonce:4:2} ))"
  local android_b64; android_b64=$(base64 -w0 < "$android_png")
  local before_wrote_n; before_wrote_n=$(android_sh "$INIT" "logcat -d -b all" | grep -c 'RHIZO_CLIP_WROTE')
  local why mark
  why=$(desk_clipboard focus-rhizo) \
    || { fail "desktop.clipboard-images: no Rhizo window took focus for the app's copy: $why"; ok=0; }
  mark=$(desk_clipboard mark) || mark=""
  local a2h_off; a2h_off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) || a2h_off=""
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_write --es mime image/png --es b64 $android_b64" >/dev/null 2>&1
  local wrote=0 deadline; deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    (( $(android_sh "$INIT" "logcat -d -b all" | grep -c 'RHIZO_CLIP_WROTE') > before_wrote_n )) && { wrote=1; break; }
    sleep 2
  done
  if (( wrote == 0 )); then
    fail "desktop.clipboard-images: the app never wrote its image clip (RHIZO_CLIP_WROTE stayed at $before_wrote_n)"
    ok=0
  else
    local got_b64; got_b64=$(desk_clipboard get image/png 60 "$mark")
    if [[ -z "$got_b64" ]]; then
      fail "desktop.clipboard-images: the host selection never carried the app's image"
      ok=0
    else
      printf '%s' "$got_b64" | base64 -d > "$EV/$TEST_STEP-clip-image-a2h-read.png" 2>/dev/null
      if cmp -s "$android_png" "$EV/$TEST_STEP-clip-image-a2h-read.png"; then
        local d2; d2=$(png_distinct "$EV/$TEST_STEP-clip-image-a2h-read.png")
        awk -v v="${d2:-0}" 'BEGIN { exit !(v + 0 > 20) }' \
          || { fail "desktop.clipboard-images: the image on the host selection has only ${d2:-0} distinct colors"; ok=0; }
      else
        fail "desktop.clipboard-images: the image on the host selection differs from the one the app copied (sha256 $(sha256sum < "$EV/$TEST_STEP-clip-image-a2h-read.png" | cut -c1-12) read, $(sha256sum < "$android_png" | cut -c1-12) copied; rhizo-deskd's trail in $TEST_STEP-image-a2h-clip-deskd.txt)"
        ok=0
      fi
    fi
  fi
  (( ok )) || _lc_deskd_clip_trail "$a2h_off" "$EV/$TEST_STEP-image-a2h-clip-deskd.txt"

  (( ok )) \
    && pass "desktop.clipboard-images: an image/png nonce crossed pixel for pixel in both directions" \
    || return 1
}

# check logcat for clipboard access toasts
lc_assert_desktop.ime-no-toast() {
  lc_need_guest desktop.ime-no-toast || return 1
  if [[ -z "$INIT" || -z "$APP_PKG" || -z "$APP_ACT" || -z "$BRIDGE_PKG" ]]; then
    fail "desktop.ime-no-toast: no live Android init/fixture package/android resolved this cycle"
    return 1
  fi

  local since; since=$(logcat_since_marker "$INIT")
  local toast_log="$EV/$TEST_STEP-ime-toast-log.txt"
  printf '<none>\n' > "$toast_log"
  if [[ ! "$since" =~ ^[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.000$ ]]; then
    fail "desktop.ime-no-toast: the guest's clock read '${since:-<empty>}', no logcat marker to read ClipboardService's lines from"
    return 1
  fi
  local ime; ime=$(android_sh "$INIT" "settings get secure default_input_method" | tr -d '\r' | tail -1)
  if [[ "$ime" != "$BRIDGE_PKG/"* ]]; then
    fail "desktop.ime-no-toast: the default IME is '${ime:-<empty>}', not the android app's own IME"
    return 1
  fi
  local want want_b64; want="rhizo-ime-$(nonce)"; want_b64=$(printf '%s' "$want" | base64 -w0)
  local before_n; before_n=$(android_sh "$INIT" "logcat -d -b all" | grep -c 'RHIZO_CLIP_WROTE')
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_write --es mime text/plain --es b64 $want_b64" >/dev/null 2>&1
  local wrote=0 deadline; deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    (( $(android_sh "$INIT" "logcat -d -b all" | grep -c 'RHIZO_CLIP_WROTE') > before_n )) && { wrote=1; break; }
    sleep 2
  done
  if (( wrote == 0 )); then
    fail "desktop.ime-no-toast: the app never wrote its clip for the android app's own background listener to read (RHIZO_CLIP_WROTE stayed at $before_n)"
    return 1
  fi

  local relayed="" start_s; start_s=$(date +%s)
  while (( $(date +%s) - start_s < 20 )); do
    local got_b64; got_b64=$(desk_clipboard get text/plain 1 2>/dev/null)
    [[ -n "$got_b64" ]] && relayed=$(printf '%s' "$got_b64" | base64 -d 2>/dev/null)
    [[ "$relayed" == "$want" ]] && break
  done
  if [[ "$relayed" != "$want" ]]; then
    fail "desktop.ime-no-toast: the host never received the android app's relay of '$want' (got '${relayed:-<none>}')"
    return 1
  fi

  local label="${LC_FIXTURE_LABEL:-Rhizo Desk Test}"
  local ctl_line="ClipboardService: $label pasted from your clipboard"
  local relay_logs rc oldest
  relay_logs=$(android_sh "$INIT" "logcat -d -b all -t '$since'"); rc=$?
  if (( rc != 0 )) || ! grep -a -q -F -- "RHIZO_CLIP_WROTE b64=$want_b64" <<<"$relay_logs"; then
    fail "desktop.ime-no-toast: the logcat read of the relay's window (rc $rc) does not hold this run's own RHIZO_CLIP_WROTE b64=$want_b64"
    return 1
  fi
  oldest=$(android_sh "$INIT" "logcat -d -b system -m 2" | grep -a -o -m1 -E '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}')
  if [[ -z "$oldest" || ! "$oldest" < "$since" ]]; then
    fail "desktop.ime-no-toast: the system log buffer's oldest entry is '${oldest:-<unread>}', not before the marker $since"
    return 1
  fi
  local relay_lines; relay_lines=$(grep -a -F 'pasted from your clipboard' <<<"$relay_logs" | grep -a -F 'ClipboardService')
  local ctl_before; ctl_before=$(grep -a -c -F -- "$ctl_line" <<<"$relay_lines")

  local want3; want3="rhizo-ime-ctrl-$(nonce)"
  _lc_desktop_clip_set "$TEST_STEP-ime-ctrl" text/plain "$(printf '%s' "$want3" | base64 -w0)"
  local relay_why
  if ! relay_why=$(_lc_desktop_clip_relayed text/plain "${#want3}" 60); then
    fail "desktop.ime-no-toast: the positive control's host clip was never relayed: $relay_why ($_LC_CLIP_SET_WHY)"
    return 1
  fi
  local got; got=$(clip_read 'RHIZO_CLIP_READ mime=[^ ]* b64=[A-Za-z0-9+/=]*' 45 "$EV/$TEST_STEP-ime-ctrl-focus.txt")
  _lc_desktop_clip_evidence "$TEST_STEP-ime-ctrl" "$got"
  local got_text; got_text=$(printf '%s' "${got##*b64=}" | base64 -d 2>/dev/null)
  if [[ "$got_text" != "$want3" ]]; then
    fail "desktop.ime-no-toast: the positive control's host clip never reached the app (it read '${got_text:-<nothing>}', the host set '$want3') ($_LC_CLIP_SET_WHY)"
    return 1
  fi
  local lines="" logs ctl_now=0 deadline=$(( $(date +%s) + 20 ))
  while (( $(date +%s) < deadline )); do
    logs=$(android_sh "$INIT" "logcat -d -b all -t '$since'")
    lines=$(grep -a -F 'pasted from your clipboard' <<<"$logs" | grep -a -F 'ClipboardService')
    ctl_now=$(grep -a -c -F -- "$ctl_line" <<<"$lines")
    (( ctl_now > ctl_before )) && break
    sleep 2
  done
  printf '%s\n' "${relay_lines:-<none>}" "--- after the positive control" "${lines:-<none>}" > "$toast_log"
  if (( ctl_now <= ctl_before )); then
    local show; show=$(android_sh "$INIT" "settings get secure clipboard_show_access_notifications" | tr -d '\r' | tail -1)
    fail "desktop.ime-no-toast: the positive control (the focused $APP_PKG reading the android app's clip) logged no new '$label pasted from your clipboard' either (clipboard_show_access_notifications=${show:-<unread>})"
    return 1
  fi
  local other; other=$(printf '%s\n%s\n' "$relay_lines" "$lines" | grep -a . | grep -a -v -F -- "$ctl_line" | sort -u)
  [[ -z "$other" ]] \
    && pass "desktop.ime-no-toast: ClipboardService logged no access toast for the android app's default-IME relay of '$want', and did for the focused fixture reading the android app's clip (positive control)" \
    || { fail "desktop.ime-no-toast: ClipboardService logged an access toast besides the positive control's while the android app's default-IME read relayed the clip: $(head -2 <<<"$other" | tr '\n' ' ')"; return 1; }
}

# check a notification carries its icon
lc_assert_desktop.notifications-icon() {
  lc_need_guest desktop.notifications-icon || return 1
  if [[ -z "$INIT" || -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "desktop.notifications-icon: no live Android init/fixture package resolved this cycle"
    return 1
  fi
  printf '<none>\n' > "$EV/$TEST_STEP-notification-record.json"
  rm -f "$EV/$TEST_STEP-notification-icon.png"
  local icon="$WORKDIR/$TEST_STEP-notif-icon.png"
  make_png "$icon" 17 200 99
  local icon_b64; icon_b64=$(base64 -w0 < "$icon")
  local ntitle; ntitle="rhizo-notif-$(nonce)"
  _lc_desktop_notify_post_via_desk "$ntitle" "$icon_b64"
  if [[ -z "$_LC_DESKTOP_NOTIFY_REC" ]]; then
    fail "desktop.notifications-icon: $_LC_DESKTOP_NOTIFY_ERR"
    return 1
  fi
  printf '%s\n' "$_LC_DESKTOP_NOTIFY_REC" > "$EV/$TEST_STEP-notification-record.json"
  local icon_path; icon_path=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("icon") or "")' "$_LC_DESKTOP_NOTIFY_REC")
  if [[ "$icon_path" != /* ]]; then
    fail "desktop.notifications-icon: the desktop's notification $ntitle carried no icon file (icon='$icon_path')"
    return 1
  fi
  local out; out=$(desk_user_sh 30 "base64 -w0 < $(printf '%q' "$icon_path") && echo && echo DONE" 2>/dev/null)
  if ! lc_done_strip out || [[ -z "$out" ]]; then
    fail "desktop.notifications-icon: could not read $icon_path, the icon the desktop was given, as the desktop user"
    return 1
  fi
  if ! printf '%s' "$out" | base64 -d > "$EV/$TEST_STEP-notification-icon.png" 2>/dev/null; then
    fail "desktop.notifications-icon: $icon_path, read back as the desktop user, is not clean base64"
    return 1
  fi
  local d; d=$(png_distinct "$EV/$TEST_STEP-notification-icon.png")
  if ! awk -v v="${d:-0}" 'BEGIN { exit !(v + 0 > 1) }'; then
    fail "desktop.notifications-icon: the icon the desktop was handed ($icon_path) has only ${d:-0} distinct color(s)"
    return 1
  fi
  local src_stats got_stats ch a b
  src_stats=$(python3 "$LC_TOOLS_DIR/../tools/pngstat.py" "$icon")
  got_stats=$(python3 "$LC_TOOLS_DIR/../tools/pngstat.py" "$EV/$TEST_STEP-notification-icon.png")
  for ch in mean_r mean_g mean_b; do
    a=$(grep "^$ch=" <<<"$src_stats" | cut -d= -f2)
    b=$(grep "^$ch=" <<<"$got_stats" | cut -d= -f2)
    if [[ -z "$a" || -z "$b" ]] || ! awk -v a="$a" -v b="$b" 'BEGIN { exit !((a - b < 12) && (b - a < 12)) }'; then
      fail "desktop.notifications-icon: the icon the desktop was handed ($icon_path) has $ch=${b:-<unread>}, the app posted $ch=${a:-<unread>}"
      return 1
    fi
  done
  pass "desktop.notifications-icon: the desktop's own notification of $ntitle was handed $icon_path through image-path, the posted PNG's colors, $d distinct"
}

# wait for RHIZO_NOTIF_ACTIVATED in logcat
_lc_desktop_notif_activated_wait() {
  local title="$1" deadline=$(( $(date +%s) + $2 )) logs
  while (( $(date +%s) < deadline )); do
    logs=$(android_sh "$INIT" "logcat -d -b all")
    grep -qE -- "RHIZO_NOTIF_ACTIVATED title=${title}([[:space:]]|\$)" <<<"$logs" && return 0
    sleep 2
  done
  return 1
}

# wait for rhizo-deskd's activated log line
_lc_desktop_deskd_activated() {
  local post_off="$1" aid="$2" click_off="$3" deadline=$(( $(date +%s) + $4 )) posted clicked did=""
  [[ "$post_off" =~ ^[0-9]+$ && "$click_off" =~ ^[0-9]+$ && -n "$aid" ]] \
    || { echo "no rhizo-deskd.log offsets or app notification id to anchor the read (post '$post_off', click '$click_off', id '$aid')"; return 1; }
  while (( $(date +%s) < deadline )); do
    posted=$(ssh_vm -t 15 "tail -c +$((post_off + 1)) /var/log/rhizo/rhizo-deskd.log; echo DONE" | tr -d '\r')
    clicked=$(ssh_vm -t 15 "tail -c +$((click_off + 1)) /var/log/rhizo/rhizo-deskd.log; echo DONE" | tr -d '\r')
    if lc_done_strip posted && lc_done_strip clicked; then
      did=$(grep -a -F -- "|$APP_PKG|$aid|" <<<"$posted" | sed -n 's/.* -> desktop id \([0-9][0-9]*\)$/\1/p' | tail -1)
      [[ -n "$did" ]] && grep -a -q -E -- " notification $did activated \(default\)\$" <<<"$clicked" && return 0
    fi
    sleep 2
  done
  if [[ -z "$did" ]]; then
    echo "rhizo-deskd logged no desktop id for $APP_PKG's notification $aid past byte $post_off"
  else
    echo "rhizo-deskd never logged 'notification $did activated (default)' past byte $click_off; its lines past the click: $(grep -a -E -- " notification $did " <<<"$clicked" | tail -3 | tr '\n' ' ')"
  fi
  return 1
}

# click a notification and check the app opens
lc_assert_desktop.notifications-activation() {
  lc_need_guest desktop.notifications-activation || return 1
  if [[ -z "$INIT" || -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "desktop.notifications-activation: no live Android init/fixture package resolved this cycle"
    return 1
  fi
  local title; title="rhizo-activate-$(nonce)"
  _lc_desktop_notify_post_via_desk "$title"
  local nid="$_LC_DESKTOP_NOTIFY_ID"
  if [[ -z "$nid" ]]; then
    fail "desktop.notifications-activation: ${_LC_DESKTOP_NOTIFY_ERR:-the post named no notification id}"
    return 1
  fi
  local act_why click_off
  click_off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) \
    || { fail "desktop.notifications-activation: rhizo-deskd.log's size read no byte offset before the click"; return 1; }
  if ! act_why=$(desk_notifications activate "$nid" default 2>&1); then
    fail "desktop.notifications-activation: the desktop's daemon did not take a click on notification $nid (desk_notifications activate $nid default failed: $(tr '\n' ' ' <<<"${act_why:-<no output>}" | head -c 400))"
    return 1
  fi
  if ! act_why=$(_lc_desktop_deskd_activated "$_LC_DESKTOP_NOTIFY_OFF" "$_LC_DESKTOP_NOTIFY_AID" "$click_off" 45); then
    fail "desktop.notifications-activation: a click on notification $nid: $act_why"
    return 1
  fi
  _lc_desktop_notif_activated_wait "$title" 45 \
    && pass "desktop.notifications-activation: activating notification $nid via desk_notifications sent ActionInvoked default (rhizo-deskd logged it activated) and fired its own contentIntent (RHIZO_NOTIF_ACTIVATED title=$title)" \
    || { fail "desktop.notifications-activation: the app never logged RHIZO_NOTIF_ACTIVATED title=$title within 45s of activating notification $nid"; return 1; }
}

# click a reply notification and check activation
lc_assert_desktop.notifications-inline-reply-fallback() {
  local c=desktop.notifications-inline-reply-fallback
  lc_need_guest "$c" || return 1
  if [[ -z "$INIT" || -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "$c: no live Android init/fixture package resolved this cycle"
    return 1
  fi
  local title; title="rhizo-reply-$(nonce)"
  _lc_desktop_notify_post_via_desk "$title" "" reply
  local nid="$_LC_DESKTOP_NOTIFY_ID"
  if [[ -z "$nid" ]]; then
    fail "$c: ${_LC_DESKTOP_NOTIFY_ERR:-the post named no notification id}"
    return 1
  fi
  if ! app_wait_token "RHIZO_NOTIF_REPLY_POSTED title=$title remote_inputs=[1-9]" 15 >/dev/null; then
    fail "$c: the fixture never logged RHIZO_NOTIF_REPLY_POSTED title=$title with a RemoteInput"
    return 1
  fi
  local has_default
  has_default=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("has_default_action"))' "$_LC_DESKTOP_NOTIFY_REC" 2>/dev/null)
  if [[ "$has_default" != True && "$has_default" != None ]]; then
    fail "$c: the desktop's notification $nid offers no default action (has_default_action=${has_default:-<unread>})"
    return 1
  fi
  local act_why click_off
  click_off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) \
    || { fail "$c: rhizo-deskd.log's size read no byte offset before the click"; return 1; }
  if ! act_why=$(desk_notifications activate "$nid" default 2>&1); then
    fail "$c: the desktop's daemon did not take a click on notification $nid (desk_notifications activate $nid default failed: $(tr '\n' ' ' <<<"${act_why:-<no output>}" | head -c 400))"
    return 1
  fi
  if ! act_why=$(_lc_desktop_deskd_activated "$_LC_DESKTOP_NOTIFY_OFF" "$_LC_DESKTOP_NOTIFY_AID" "$click_off" 45); then
    fail "$c: a click on notification $nid: $act_why"
    return 1
  fi
  if ! _lc_desktop_notif_activated_wait "$title" 45; then
    fail "$c: the app never logged RHIZO_NOTIF_ACTIVATED title=$title within 45s of a click on notification $nid"
    return 1
  fi
  local logs rc
  logs=$(android_sh "$INIT" "logcat -d -b all"); rc=$?
  if (( rc != 0 )) || ! grep -qE -- "RHIZO_NOTIF_ACTIVATED title=${title}([[:space:]]|\$)" <<<"$logs"; then
    fail "$c: the logcat read after the click (rc $rc) does not hold RHIZO_NOTIF_ACTIVATED title=$title"
    return 1
  fi
  if grep -qE -- "RHIZO_NOTIF_REPLIED title=${title}([[:space:]]|\$)" <<<"$logs"; then
    fail "$c: a click on notification $nid fired its RemoteInput reply's own PendingIntent (RHIZO_NOTIF_REPLIED title=$title)"
    return 1
  fi
  pass "$c: a click on notification $nid (ActionInvoked key default, the one action rhizo-deskd declares, logged by rhizo-deskd as activated (default)) opened the app at conversation $title through its contentIntent (RHIZO_NOTIF_ACTIVATED), and the RemoteInput reply it carried never fired"
}

LC_KM_CONTROL_OUT=/run/rhizo/data/rhizo_control/control.out

# save and print rhizo-keymapd.service state
_lc_keymapd_state() {
  local out
  out=$(ssh_vm -t 30 'systemctl show -p ActiveState,SubState,Result,InvocationID,ActiveEnterTimestamp,ExecMainStatus,NRestarts rhizo-keymapd.service
echo "--- journalctl -u rhizo-keymapd.service -b"; journalctl -u rhizo-keymapd.service -b --no-pager 2>&1 | tail -40
echo "--- /var/log/rhizo/rhizo-keymapd.log"; tail -40 /var/log/rhizo/rhizo-keymapd.log 2>&1; echo DONE' 2>/dev/null | tr -d '\r')
  [[ -n "${EV:-}" && -d "$EV" ]] && printf '%s\n' "${out:-<none>}" >> "$EV/keymapd.txt"
  printf '%s' "$out"
}

# print the keymap table-loaded line
_lc_keymap_loaded_after() {
  local off="$1" deadline=$(( $(date +%s) + $2 )) out digest loaded
  while (( $(date +%s) < deadline )); do
    out=$(ssh_vm -t 15 "tail -c +$((off + 1)) $LC_KM_CONTROL_OUT 2>/dev/null")
    digest=$(grep -o '^keymap ready .*digest=[0-9]*' <<<"$out" | tail -1 | sed 's/.*digest=//')
    if [[ -n "$digest" ]]; then
      loaded=$(sed -n "/^keymap ready .*digest=$digest /,\$p" <<<"$out" | grep -m1 "^keymap table-loaded digest=$digest ")
      [[ -n "$loaded" ]] && { printf '%s\n' "$loaded"; return 0; }
    fi
    sleep 1
  done
  printf '%s\n' "$(grep '^keymap ' <<<"$out" | tail -3 | tr '\n' '|')"
  return 1
}

LC_KM_RESOLVE_PY='import importlib.util, sys
s = importlib.util.spec_from_file_location("keymapd", "/usr/lib/rhizo/keymapd/keymapd.py")
k = importlib.util.module_from_spec(s); s.loader.exec_module(k)
raw = k.read_from(k.sandbox_to_host(sys.argv[1]))
print("fnv=%d" % k.fnv1a32(raw))
print("q=%s" % k.Xkb().resolve(raw.decode("utf-8")).get(16, [""])[0])'

# print the character the keymap gives KEY_Q
_lc_keymap_key_q() {
  local path out fnv
  path=$(ssh_vm -t 15 "tail -c +$(($1 + 1)) $LC_KM_CONTROL_OUT 2>/dev/null" | grep -o "^keymap ready .*digest=$2 path=[^ ]*" | tail -1 | sed 's/.* path=//')
  [[ "$path" == /data/* ]] || { echo "no 'keymap ready ... digest=$2 path=' past byte $1 names the file"; return 1; }
  out=$(ssh_vm -t 30 "python3 -c $(printf '%q' "$LC_KM_RESOLVE_PY") $(printf '%q' "$path") 2>&1; echo DONE" 2>/dev/null | tr -d '\r')
  lc_done_strip out || { echo "keymapd's resolver over $path never finished"; return 1; }
  fnv=$(sed -n 's/^fnv=//p' <<<"$out")
  [[ "$fnv" == "$2" ]] || { echo "$path hashes to '${fnv:-<unread>}', not the composer's keymap digest $2: $(tr '\n' ' ' <<<"$out")"; return 1; }
  sed -n 's/^q=//p' <<<"$out"
}

# change the host layout and check the keymap
lc_assert_desktop.keymap-follows-host() {
  local c=desktop.keymap-follows-host
  lc_need_guest "$c" || return 1
  [[ -n "${EV:-}" && -d "$EV" ]] && : > "$EV/keymapd.txt"
  local st inv act
  st=$(_lc_keymapd_state)
  inv=$(sed -n 's/^InvocationID=//p' <<<"$st"); act=$(sed -n 's/^ActiveState=//p' <<<"$st")
  if [[ "$act" != active || -z "$inv" ]]; then
    fail "$c: rhizo-keymapd.service is '${act:-<unread>}' (invocation '${inv:-<none>}', $(grep -E '^(Result|ExecMainStatus|NRestarts)=' <<<"$st" | tr '\n' ' ')) before any layout change, want active (state, journal and log in \$EV/keymapd.txt)"
    return 1
  fi
  local layout off got why="" loaded=() digest q want
  for layout in fr us; do
    off=$(ssh_vm -t 15 "stat -c%s $LC_KM_CONTROL_OUT" 2>/dev/null | tr -d '[:space:]')
    [[ "$off" =~ ^[0-9]+$ ]] || { why="control.out's size read '${off:-<empty>}' before the $layout change"; break; }
    desk_keyboard_layout "$layout" >/dev/null 2>&1 || { why="desk_keyboard_layout $layout failed"; break; }
    if ! got=$(_lc_keymap_loaded_after "$off" 30); then
      why="after the host layout went to $layout, control.out past byte $off logged no 'keymap table-loaded' for a keymap announced after it within 30s (its keymap lines: ${got:-<none>})"
      break
    fi
    loaded+=("$layout: $got")
    digest=$(sed -n 's/^keymap table-loaded digest=\([0-9]*\).*/\1/p' <<<"$got")
    want=q; [[ "$layout" == fr ]] && want=a
    if ! q=$(_lc_keymap_key_q "$off" "$digest"); then why="after the host went to $layout, $q"; break; fi
    if [[ "$q" != "$want" ]]; then
      why="after the host went to $layout, the keymap the composer loaded (digest $digest) resolves KEY_Q to '${q:-<nothing>}', not '$want'"
      break
    fi
    loaded[-1]+=" KEY_Q=$q"
  done
  local d_fr d_us
  d_fr=$(sed -n 's/^fr: keymap table-loaded digest=\([0-9]*\).*/\1/p' <<<"${loaded[0]:-}")
  d_us=$(sed -n 's/^us: keymap table-loaded digest=\([0-9]*\).*/\1/p' <<<"${loaded[1]:-}")
  [[ -n "$why" || "$d_fr" != "$d_us" ]] \
    || why="the composer loaded the same keymap digest ${d_fr:-<none>} after the host went to fr and after it went back to us"
  [[ -z "$why" || "$layout" == us ]] || desk_keyboard_layout us >/dev/null 2>&1
  local st1 inv1 act1
  st1=$(_lc_keymapd_state)
  inv1=$(sed -n 's/^InvocationID=//p' <<<"$st1"); act1=$(sed -n 's/^ActiveState=//p' <<<"$st1")
  if [[ -n "$why" ]]; then
    fail "$c: $why (keymapd state, journal and log in \$EV/keymapd.txt)"
    return 1
  fi
  if [[ "$act1" != active || "$inv1" != "$inv" ]]; then
    fail "$c: rhizo-keymapd.service read '$act1' invocation '${inv1:-<none>}' after the layout changes, was active invocation $inv (\$EV/keymapd.txt)"
    return 1
  fi
  pass "$c: rhizo-keymapd stayed active (invocation $inv) while the host layout went to fr and back to us, and the composer loaded its table for each new keymap (${loaded[*]})"
}

# assert links open both ways between host and Android
lc_assert_desktop.links-both-ways() {
  lc_need_guest desktop.links-both-ways || return 1
  if [[ -z "$INIT" || -z "$APP_PKG" || -z "$APP_ACT" || -z "$BRIDGE_PKG" ]]; then
    fail "desktop.links-both-ways: no fixture package/activity/android resolved this cycle"
    return 1
  fi
  local before=$FAILED
  desktop_assert_link_host_to_app "$INIT" "$APP_PKG" "$EV"
  desktop_assert_link_android_to_host "$INIT" "$APP_PKG" "$APP_ACT" "$BRIDGE_PKG"
  (( FAILED == before )) \
    && pass "desktop.links-both-ways: a link opened on the host reached the app, and a link opened in Android reached the host, both byte for byte" \
    || return 1
}

# assert files drag both ways between host and app
lc_assert_desktop.dnd-both-ways() {
  lc_need_guest desktop.dnd-both-ways || return 1
  if [[ -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "desktop.dnd-both-ways: no fixture package/activity resolved this cycle"
    return 1
  fi
  _lc_desktop_launch_new_display dnd-both-ways "$APP_PKG" "$APP_ACT"
  local cdisp=$_LC_DESKTOP_LAUNCH_CDISP
  if [[ -z "$cdisp" ]]; then
    fail "desktop.dnd-both-ways: $_LC_DESKTOP_LAUNCH_ERR"
    return 1
  fi
  local before=$FAILED
  desktop_assert_dnd_drop_onto_app "$INIT" "$cdisp" "$EV"
  desktop_assert_dnd_drag_out_of_app "$INIT" "$APP_PKG" "$APP_ACT" "$cdisp"
  (( FAILED == before )) \
    && pass "desktop.dnd-both-ways: a file dragged onto the app landed, and a drag out of the app reached the host, both byte for byte" \
    || return 1
}

# drop a file onto a second app display
lc_assert_desktop.dnd-secondary-displays() {
  lc_need_guest desktop.dnd-secondary-displays || return 1
  if [[ -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "desktop.dnd-secondary-displays: no fixture package/activity resolved this cycle"
    return 1
  fi
  _lc_desktop_launch_new_display dnd-secondary-peer "$LC_DESKTOP_PEER_PKG" "$LC_DESKTOP_PEER_ACT"
  local peer=$_LC_DESKTOP_LAUNCH_CDISP
  if [[ -z "$peer" ]]; then
    fail "desktop.dnd-secondary-displays: $_LC_DESKTOP_LAUNCH_ERR"
    return 1
  fi
  _lc_desktop_launch_new_display dnd-secondary "$APP_PKG" "$APP_ACT"
  local cdisp2=$_LC_DESKTOP_LAUNCH_CDISP
  if [[ -z "$cdisp2" ]]; then
    fail "desktop.dnd-secondary-displays: $_LC_DESKTOP_LAUNCH_ERR"
    desktop_close_all_app_windows 20 "rhizo-$LC_DESKTOP_PEER_PKG" \
      || log "    desktop.dnd-secondary-displays: $LC_DESKTOP_PEER_PKG's window did not close after the claim"
    return 1
  fi
  local before=$FAILED
  if [[ "$cdisp2" == "$peer" ]] || ! desktop_mapped_window_rect "$peer" >/dev/null 2>&1; then
    fail "desktop.dnd-secondary-displays: $LC_DESKTOP_PEER_PKG's display $peer is not still up beside $cdisp2"
  else
    desktop_assert_dnd_drop_onto_app "$INIT" "$cdisp2" "$EV"
  fi
  desktop_close_all_app_windows 20 "rhizo-$LC_DESKTOP_PEER_PKG" \
    || log "    desktop.dnd-secondary-displays: $LC_DESKTOP_PEER_PKG's window did not close after the claim"
  (( FAILED == before )) \
    && pass "desktop.dnd-secondary-displays: a drop landed on a newly created composer display ($cdisp2) with $LC_DESKTOP_PEER_PKG's ($peer) still up beside it" \
    || return 1
}

# assert xdg-mime resolves an APK to the apk installer entry
lc_assert_applifecycle.install-mime-handler() {
  lc_need_guest applifecycle.install-mime-handler || return 1
  if [[ -z "$DESK_USER" ]]; then
    fail "applifecycle.install-mime-handler: no desktop session user resolved this cycle"
    return 1
  fi
  local handler; handler=$(user_sh 30 "xdg-mime query default application/vnd.android.package-archive" | tr -d '\r')
  [[ "$handler" == "rhizo-apk-installer.desktop" ]] \
    && pass "applifecycle.install-mime-handler: xdg-mime resolves an APK to rhizo-apk-installer.desktop" \
    || { fail "applifecycle.install-mime-handler: xdg-mime resolves an APK to '$handler', not rhizo-apk-installer.desktop"; return 1; }
}

# check the menu entry icon files
lc_assert_applifecycle.menu-entry-icons() {
  lc_need_guest applifecycle.menu-entry-icons || return 1
  if [[ -z "$APP_PKG" ]]; then
    fail "applifecycle.menu-entry-icons: no fixture package resolved this cycle"
    return 1
  fi
  local apk="$VAR_DIR/share/rhizo-deskapp.apk" aapt2="${RHIZO_AAPT2:-$VAR_DIR/share/aapt2}" badging declared
  badging=$("$aapt2" dump badging "$apk" 2>/dev/null)
  if ! grep -q '^application:' <<<"$badging"; then
    fail "applifecycle.menu-entry-icons: $aapt2 dump badging $apk printed no application: line to tell whether it declares an icon"
    return 1
  fi
  declared=$(sed -n "s/^application:.* icon='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)
  local entry; entry=$(ssh_vm -t 15 "cat $LC_ENTRY_PATH 2>/dev/null; echo DONE")
  lc_done_strip entry || { fail "applifecycle.menu-entry-icons: incomplete read of $LC_ENTRY_PATH (no DONE token): $entry"; return 1; }
  local entry_icon; entry_icon=$(entry_field "$entry" Icon)
  local icons; icons=$(icon_list "$APP_PKG")
  if ! grep -qx LISTED <<<"$icons"; then
    fail "applifecycle.menu-entry-icons: the hicolor walk for $APP_PKG did not complete"
    return 1
  fi
  local n; n=$(grep -c "/rhizo-$APP_PKG.png\$" <<<"$icons")
  if [[ -n "$declared" ]]; then
    [[ "$entry_icon" == "rhizo-$APP_PKG" ]] \
      || { fail "applifecycle.menu-entry-icons: the APK declares icon '$declared' but $LC_ENTRY_PATH says Icon='$entry_icon', not rhizo-$APP_PKG"; return 1; }
    (( n > 0 )) \
      && pass "applifecycle.menu-entry-icons: appsync wrote $n icon(s) named rhizo-$APP_PKG.png for the APK's own icon" \
      || { fail "applifecycle.menu-entry-icons: the entry names Icon=rhizo-$APP_PKG but no hicolor file matches rhizo-$APP_PKG.png"; return 1; }
    return 0
  fi
  [[ "$entry_icon" == rhizo ]] \
    || { fail "applifecycle.menu-entry-icons: the APK declares no icon, so the entry should name the generic Icon=rhizo, but $LC_ENTRY_PATH says Icon='$entry_icon'"; return 1; }
  (( n == 0 )) \
    || { fail "applifecycle.menu-entry-icons: the APK declares no icon, yet hicolor carries $n rhizo-$APP_PKG.png file(s)"; return 1; }
  [[ "$(guest_file_state "$ICONS_DIR/256x256/apps/rhizo.png")" == PRESENT ]] \
    && pass "applifecycle.menu-entry-icons: the APK declares no icon, and its entry names the generic Icon=rhizo, which appsync wrote at $ICONS_DIR/256x256/apps/rhizo.png" \
    || { fail "applifecycle.menu-entry-icons: the entry names Icon=rhizo but no generic icon is at $ICONS_DIR/256x256/apps/rhizo.png"; return 1; }
}

# assert desk_windows lists a window with the app's exact app_id
lc_assert_applifecycle.launch-composited-app-id() {
  lc_need_guest applifecycle.launch-composited-app-id || return 1
  if [[ -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "applifecycle.launch-composited-app-id: no fixture package/activity resolved this cycle"
    return 1
  fi
  local want="rhizo-$APP_PKG"
  if [[ "$(_lc_desktop_window_app_id_exact "$want")" != FOUND ]]; then
    _lc_desktop_launch_new_display launch-composited-app-id "$APP_PKG" "$APP_ACT" >/dev/null
  fi
  [[ "$(_lc_desktop_await_app_id "$want")" == FOUND ]] \
    && pass "applifecycle.launch-composited-app-id: desk_windows lists a window with app_id exactly $want" \
    || { fail "applifecycle.launch-composited-app-id: no desk_windows entry has app_id exactly $want within 15s of its launch"; return 1; }
}

LA_CDISP="" LA_WIN="" LA_LAUNCHED="" LA_SINCE="" LA_ERR=""
# launch the entry and record what it produced
_lc_launch_activation_leg() {
  local label="$1" mode="${2:-}" want="rhizo-$APP_PKG" before_n new deadline
  LA_CDISP="" LA_WIN="" LA_LAUNCHED="" LA_SINCE="" LA_ERR=""
  desktop_close_all_app_windows || { LA_ERR="$label: the app's windows did not close before the launch"; return 1; }
  LA_ERR=$(desktop_focus_holder_up) || { LA_ERR="$label: $LA_ERR"; return 1; }
  LA_ERR=""
  before_n=$(ssh_vm -t 15 'wc -l < /run/rhizo-launch/rhizo-launch.log 2>/dev/null' | tr -d '[:space:]')
  [[ "$before_n" =~ ^[0-9]+$ ]] || { LA_ERR="$label: the launch log's line count did not read before the launch"; return 1; }
  LA_SINCE=$(logcat_since_marker "$INIT")
  [[ -n "$LA_SINCE" ]] || { LA_ERR="$label: no logcat marker read before the launch"; return 1; }
  if ! LA_LAUNCHED=$(desk_launch_entry "$LC_ENTRY_PATH" $mode); then
    LA_ERR="$label: ${LA_LAUNCHED:-the launch of $LC_ENTRY_PATH failed}"
    return 1
  fi
  deadline=$(( $(date +%s) + 90 ))
  while (( $(date +%s) < deadline )); do
    if [[ -z "$LA_CDISP" ]]; then
      new=$(ssh_vm -t 15 "tail -n +$(( before_n + 1 )) /run/rhizo-launch/rhizo-launch.log 2>/dev/null")
      LA_CDISP=$(grep -m1 "event=am_start_return pid=[0-9]* pkg=$APP_PKG " <<<"$new" | grep -o 'cdisplay=[0-9]*' | cut -d= -f2)
    fi
    if [[ -n "$LA_CDISP" ]]; then
      LA_WIN=$(desk_windows 2>/dev/null | python3 -c "
import json, sys
for l in sys.stdin:
    try:
        w = json.loads(l)
    except ValueError:
        continue
    if w.get('app_id') == sys.argv[1] and w.get('w', 0) > 0 and w.get('h', 0) > 0:
        print(json.dumps(w))
        break
" "$want")
      [[ -n "$LA_WIN" ]] && return 0
    fi
    sleep 2
  done
  [[ -n "$LA_CDISP" ]] \
    && LA_ERR="$label: composer display $LA_CDISP's $want window never mapped" \
    || LA_ERR="$label: the launch log gained no am_start_return for $APP_PKG"
  return 1
}

# print focused or urgent for a window
_lc_window_raised() {
  python3 -c "
import json, sys
w = json.loads(sys.argv[1])
print('focused' if w.get('focused') else 'urgent' if w.get('urgent') else '')
" "$1"
}

# launch the app entry and check its window
lc_assert_applifecycle.launch-activates-window() {
  local rc
  _lc_launch_activates_window; rc=$?
  desktop_focus_holder_down
  return "$rc"
}

# launch the entry twice and check focus
_lc_launch_activates_window() {
  lc_need_guest applifecycle.launch-activates-window || return 1
  if [[ -z "$APP_PKG" || -z "$LC_ENTRY_PATH" ]]; then
    fail "applifecycle.launch-activates-window: no fixture package or entry resolved this cycle"
    return 1
  fi
  local want="rhizo-$APP_PKG" raised reply="" applied="" ctl deadline logs before_n
  INIT=$(lc_resolve_init 60)
  [[ -n "$INIT" ]] || { fail "applifecycle.launch-activates-window: no sandbox init to read the composer's replies from"; return 1; }

  if ! _lc_launch_activation_leg control --no-token; then
    fail "applifecycle.launch-activates-window: $LA_ERR"
    desk_launch_entry "done" >/dev/null 2>&1
    return 1
  fi
  printf '%s\n%s\n' "$LA_LAUNCHED" "$LA_WIN" > "$EV/launch-activation-control.txt"
  raised=$(_lc_window_raised "$LA_WIN")
  desk_launch_entry "done" >/dev/null 2>&1
  if [[ -n "$raised" ]]; then
    fail "applifecycle.launch-activates-window: the control launch with no token left $want's window $raised"
    return 1
  fi

  before_n=$(_dnd_ctl_lines "$INIT") \
    || { fail "applifecycle.launch-activates-window: control.out's line count did not read before the launch"; return 1; }
  if ! _lc_launch_activation_leg token; then
    fail "applifecycle.launch-activates-window: $LA_ERR"
    desk_launch_entry "done" >/dev/null 2>&1
    return 1
  fi
  raised=""
  deadline=$(( $(date +%s) + 90 ))
  while (( $(date +%s) < deadline )); do
    if [[ -z "$reply" ]]; then
      ctl=$(_dnd_ctl_read "$INIT" tail -n "+$(( before_n + 1 ))" /data/rhizo_control/control.out)
      reply=$(grep -m1 -E "^display (activate-held|activated|activate-failed) id=$LA_CDISP( |\$)" <<<"$ctl")
      [[ "$reply" == "display activated id=$LA_CDISP"* ]] && applied="$reply"
    fi
    [[ "$reply" == *activate-failed* ]] && break
    if [[ "$reply" == *activate-held* && -z "$applied" ]]; then
      logs=$(logcat_vm "$INIT" -d -b all -T "$LA_SINCE" 2>/dev/null)
      applied=$(grep -a -m1 "display $LA_CDISP mapped, activated with its held token" <<<"$logs")
    fi
    if [[ -n "$applied" ]]; then
      LA_WIN=$(desk_windows 2>/dev/null | grep -F "\"app_id\": \"$want\"" | head -1)
      raised=$([[ -n "$LA_WIN" ]] && _lc_window_raised "$LA_WIN")
      [[ -n "$raised" ]] && break
    fi
    sleep 2
  done
  desk_windows > "$EV/launch-activation-windows.txt" 2>&1
  printf '%s\n' "${ctl:-<none>}" > "$EV/launch-activation-composer.txt"
  printf '%s\n' "${LA_LAUNCHED:-<none>}" > "$EV/launch-activation-launcher.txt"
  desk_launch_entry "done" >/dev/null 2>&1
  if [[ -z "$reply" ]]; then
    fail "applifecycle.launch-activates-window: the composer never answered a display activate for the launch's display $LA_CDISP"
    return 1
  fi
  if [[ "$reply" == *activate-failed* ]]; then
    fail "applifecycle.launch-activates-window: the composer refused the launch's token for display $LA_CDISP: $reply"
    return 1
  fi
  if [[ -z "$applied" ]]; then
    fail "applifecycle.launch-activates-window: the composer held the token for display $LA_CDISP ($reply) and never logged activating with it once mapped"
    return 1
  fi
  [[ -n "$raised" ]] \
    && pass "applifecycle.launch-activates-window: the entry's launch left $want's window $raised through its token on display $LA_CDISP ($applied), where the same launch with no token left it unraised" \
    || { fail "applifecycle.launch-activates-window: the composer activated display $LA_CDISP with the token but $want's window is neither focused nor urgent (see launch-activation-windows.txt)"; return 1; }
}

# run the Uninstall action and restore the app
lc_assert_applifecycle.uninstall-entry-action() {
  lc_need_guest applifecycle.uninstall-entry-action || return 1
  if [[ -z "$APP_PKG" || -z "$LC_ENTRY_PATH" ]]; then
    fail "applifecycle.uninstall-entry-action: no fixture entry resolved this cycle to remove"
    return 1
  fi
  local entry_text_now; entry_text_now=$(ssh_vm -t 15 "cat $LC_ENTRY_PATH")
  if [[ -z "$entry_text_now" ]]; then
    fail "applifecycle.uninstall-entry-action: could not read $LC_ENTRY_PATH to find its own Uninstall action"
    return 1
  fi
  local entry_filename; entry_filename=$(basename "$LC_ENTRY_PATH")
  local before=$FAILED
  if [[ "$BUS_ADDR" != unix:* ]]; then
    fail "applifecycle.uninstall-entry-action: no private session bus to run the removal on (BUS_ADDR='${BUS_ADDR:-}')"
    return 1
  fi
  if ! notify_sink_start "$BUS_ADDR"; then
    fail "applifecycle.uninstall-entry-action: no notification sink on $BUS_ADDR to record the removal's notification"
    return 1
  fi
  install_uninstall_via_entry_action "-applifecycle-uninstall" "$(nonce)" "$APP_PKG" "$LC_ENTRY_PATH" "$entry_filename" "$entry_text_now"
  local removed_ok=0; (( FAILED == before )) && removed_ok=1

  local fixture_apk="$VAR_DIR/share/rhizo-deskapp.apk"
  if [[ -f "$fixture_apk" && -n "$LC_FIXTURE_SHA" && -n "$LC_FIXTURE_LABEL" && -n "$LC_ENTRY_ID" ]]; then
    install_apk_via_broker "-applifecycle-uninstall-restore" "$fixture_apk" "$LC_FIXTURE_SHA" "$APP_PKG" "$LC_FIXTURE_LABEL" "$LC_ENTRY_PATH" "$LC_ENTRY_ID"
  else
    fail "applifecycle.uninstall-entry-action: no fixture apk/sha/label/entry-id to restore $APP_PKG with after removing it"
  fi
  notify_sink_stop

  if (( removed_ok )); then
    pass "applifecycle.uninstall-entry-action: the entry's own Uninstall action removed $APP_PKG, its icons and its mimeapps lines, leaving every other entry byte-identical"
  fi
  (( FAILED == before ))
}

# stop androidd.service and start it with rhizo launch
lc_assert_applifecycle.restart-from-user-side() {
  lc_need_guest applifecycle.restart-from-user-side || return 1
  if [[ -z "$APP_PKG" || -z "$APP_ACT" || -z "$DESK_USER" ]]; then
    fail "applifecycle.restart-from-user-side: no fixture package/activity/desktop user resolved this cycle"
    return 1
  fi
  local old_init="$INIT"
  if [[ -z "$old_init" ]]; then
    fail "applifecycle.restart-from-user-side: no Android init pid resolved before the stop"
    return 1
  fi
  if [[ -z "$LC_ENTRY_PATH" ]] || ! wait_guest_file 240 "$LC_ENTRY_PATH"; then
    fail "applifecycle.restart-from-user-side: ${LC_ENTRY_PATH:-<no entry path>} did not come back within 240s of the sandbox starting"
    return 1
  fi
  ssh_vm -t 60 'systemctl stop androidd.service' >/dev/null 2>&1
  local active; active=$(ssh_vm -t 15 'systemctl is-active androidd.service 2>/dev/null' | tr -d '[:space:]')
  if [[ "$active" != "inactive" ]]; then
    fail "applifecycle.restart-from-user-side: systemctl is-active androidd.service read '$active' after the stop, not exactly 'inactive'"
    return 1
  fi
  local out; out=$(user_sh 300 "/usr/bin/rhizo launch $APP_PKG 2>&1; echo rc=\$?")
  if [[ "$(tail -1 <<<"$out")" != "rc=0" ]]; then
    fail "applifecycle.restart-from-user-side: rhizo launch (as $DESK_USER) did not report rc=0 (last line: $(tail -1 <<<"$out"); $(grep -m1 'RHIZO_FAIL' <<<"$out" || echo 'no RHIZO_FAIL line'))"
    return 1
  fi
  if ! grep -q 'RHIZO_SANDBOX starting=1' <<<"$out"; then
    fail "applifecycle.restart-from-user-side: rhizo launch's own output carries no 'RHIZO_SANDBOX starting=1' ($out)"
    return 1
  fi
  active=$(ssh_vm -t 15 'systemctl is-active androidd.service 2>/dev/null' | tr -d '[:space:]')
  if [[ "$active" != "active" ]]; then
    fail "applifecycle.restart-from-user-side: systemctl is-active androidd.service read '$active' after rhizo launch, not exactly 'active'"
    return 1
  fi
  local new_init; new_init=$(resolve_init_pid 60)
  if [[ -z "$new_init" ]]; then
    fail "applifecycle.restart-from-user-side: rhizo launch restarted androidd but no Android init pid resolved"
    return 1
  fi
  if [[ "$new_init" == "$old_init" ]]; then
    fail "applifecycle.restart-from-user-side: the init pid is still $old_init after rhizo launch"
    return 1
  fi
  INIT="$new_init"
  local awake
  if ! awake=$(wait_device_awake "$INIT" 60); then
    _lc_restart_keep_crash_log
    fail "applifecycle.restart-from-user-side: the restarted sandbox (init $INIT) never read awake within 60s (last: '${awake:-<nothing>}') -- Android's crash buffer is in $EV/applifecycle-restart-crash-logcat.txt"
    return 1
  fi
  local resumed why
  if ! resumed=$(_lc_desktop_resumed_pkgacts 2>"$EV/applifecycle-restart-resumed.err"); then
    why=$(cat "$EV/applifecycle-restart-resumed.err")
    _lc_restart_keep_crash_log
    fail "applifecycle.restart-from-user-side: after rhizo launch returned on top, $why -- Android's crash buffer is in $EV/applifecycle-restart-crash-logcat.txt"
    return 1
  fi
  if [[ "$resumed" != *"$APP_PKG/"* ]]; then
    _lc_restart_keep_crash_log
    fail "applifecycle.restart-from-user-side: androidd restarted but no topResumedActivity names $APP_PKG (got: $(tr '\n' ' ' <<<"$resumed")) -- Android's crash buffer is in $EV/applifecycle-restart-crash-logcat.txt"
    return 1
  fi
  pass "applifecycle.restart-from-user-side: rhizo launch (as $DESK_USER) restarted androidd (init $old_init -> $new_init) and resumed $APP_PKG"
}

# save Android's crash and system logcat
_lc_restart_keep_crash_log() {
  local log
  log=$(android_sh "$INIT" 'logcat -b crash -b system -d -v threadtime; echo "RHIZO_LOGCAT_RC=$?"')
  printf '%s\n' "${log:-<no logcat read: android_sh reached no shell>}" > "$EV/applifecycle-restart-crash-logcat.txt"
}

# assert the file handoff procedure completes
lc_assert_applifecycle.hand-file-to-app() {
  lc_need_guest applifecycle.hand-file-to-app || return 1
  if [[ -z "$LC_ENTRY_PATH" ]]; then
    fail "applifecycle.hand-file-to-app: no fixture desktop entry resolved this cycle"
    return 1
  fi
  install_file_handoff "$(basename "$LC_ENTRY_PATH")" \
    && pass "applifecycle.hand-file-to-app: the file-handoff procedure completed" \
    || { fail "applifecycle.hand-file-to-app: install_file_handoff reported failure"; return 1; }
}

LC_HOST_SINK=rhizo_lc_host_sink

# create a PipeWire null output
_lc_audio_host_sink_up() {
  user_sh 30 "if pw-dump 2>/dev/null | grep -q '\"media.class\": \"Audio/Sink\"'; then echo HAVE_SINK; elif pw-cli create-node adapter '{ factory.name=support.null-audio-sink node.name=$LC_HOST_SINK node.description=RhizoLifecycleHostSink media.class=Audio/Sink object.linger=true audio.position=[FL FR] }' >/dev/null; then echo MADE_SINK; else echo NO_SINK; fi" 2>/dev/null | tr -d '\r'
}

# destroy the PipeWire null output
_lc_audio_host_sink_down() {
  local out
  out=$(user_sh 30 "id=\$(pw-cli ls Node 2>/dev/null | awk '/^[[:space:]]*id [0-9]+,/{gsub(\",\",\"\",\$2); id=\$2} /node.name = \"$LC_HOST_SINK\"/{print id}' | head -1); [ -z \"\$id\" ] || pw-cli destroy \"\$id\" >/dev/null 2>&1; if ! d=\$(pw-dump 2>/dev/null); then echo UNREAD; elif printf '%s' \"\$d\" | grep -q '\"node.name\": \"$LC_HOST_SINK\"'; then echo KEPT; else echo GONE; fi" 2>/dev/null | tr -d '\r')
  [[ "$out" == GONE ]] \
    || fail "audio.sound-plays: the stand-in sink $LC_HOST_SINK was not shown gone from the user's graph (${out:-<no answer>})"
}

# print the app node and default output
_lc_audio_app_on_default_sink() {
  python3 -c '
import json, sys
path, pkg = sys.argv[1], sys.argv[2]
def die(msg):
    print(msg)
    sys.exit(1)
try:
    objs = json.load(open(path))
except (OSError, ValueError) as e:
    die("the pw-dump read during the capture is unreadable: %s" % e)
if not isinstance(objs, list):
    die("the pw-dump read during the capture is not a list of objects")
def props(o):
    return o.get("props") or (o.get("info") or {}).get("props") or {}
sink = None
for o in objs:
    if o.get("type") == "PipeWire:Interface:Metadata" and props(o).get("metadata.name") == "default":
        for m in o.get("metadata") or []:
            v = m.get("value")
            if m.get("key") == "default.audio.sink" and isinstance(v, dict):
                sink = v.get("name")
if not sink:
    die("the graph names no default.audio.sink")
nodes = [o for o in objs if o.get("type") == "PipeWire:Interface:Node"]
sink_ids = {o.get("id") for o in nodes
            if props(o).get("node.name") == sink and props(o).get("media.class") == "Audio/Sink"}
if not sink_ids:
    die("the default sink %s is no Audio/Sink node in the graph" % sink)
rhizo = [(o.get("id"), props(o).get("node.name"), props(o).get("application.name")) for o in nodes
         if str(props(o).get("node.name", "")).startswith("rhizo.")]
mine = {i: n for i, n, a in rhizo if a == pkg}
if not mine:
    die("no rhizo.* stream of %s in the graph (rhizo nodes: %s)"
        % (pkg, ", ".join("%s app=%s" % (n, a) for _, n, a in rhizo) or "none"))
links = [(o.get("info") or {}) for o in objs if o.get("type") == "PipeWire:Interface:Link"]
into = [l for l in links if l.get("output-node-id") in mine]
live = [l for l in into if l.get("input-node-id") in sink_ids and l.get("state") == "active"]
if not live:
    die("no active link from %s into the default sink %s (its links: %s)"
        % ("/".join(sorted(mine.values())), sink,
           ", ".join("node %s %s" % (l.get("input-node-id"), l.get("state")) for l in into)
           or "none"))
print("%s -> %s" % (mine[live[0]["output-node-id"]], sink))
' "$1" "$2"
}

LC_AUDIO_TAP=rhizo-lc-app-tap

# print the app node the capture stream reads
_lc_audio_tap_from_app() {
  python3 -c '
import json, sys
path, pkg, tap = sys.argv[1], sys.argv[2], sys.argv[3]
def die(msg):
    print(msg)
    sys.exit(1)
try:
    objs = json.load(open(path))
except (OSError, ValueError) as e:
    die("the pw-dump read during the capture is unreadable: %s" % e)
if not isinstance(objs, list):
    die("the pw-dump read during the capture is not a list of objects")
def props(o):
    return o.get("props") or (o.get("info") or {}).get("props") or {}
nodes = {o.get("id"): props(o) for o in objs if o.get("type") == "PipeWire:Interface:Node"}
taps = {i for i, p in nodes.items() if p.get("node.name") == tap}
if not taps:
    die("the capture stream %s is not in the graph" % tap)
mine = {i for i, p in nodes.items() if str(p.get("node.name", "")).startswith("rhizo.") and p.get("application.name") == pkg}
links = [(o.get("info") or {}) for o in objs if o.get("type") == "PipeWire:Interface:Link"]
into = [l for l in links if l.get("input-node-id") in taps]
if not into:
    die("the capture stream %s has no input link" % tap)
foreign = sorted({l.get("output-node-id") for l in into} - mine)
if foreign:
    die("the capture stream %s also reads %s, not only %s" % (tap, ", ".join(
        "%s (node %s)" % (nodes.get(i, {}).get("node.name", "?"), i) for i in foreign), pkg))
live = [l for l in into if l.get("state") == "active"]
if not live:
    die("no active link from %s into the capture stream %s" % (pkg, tap))
print(nodes[live[0]["output-node-id"]].get("node.name"))
' "$1" "$2" "$LC_AUDIO_TAP"
}

# play the tone app and check its capture
lc_assert_audio.sound-plays() {
  lc_need_guest audio.sound-plays || return 1
  if [[ -z "$INIT" ]]; then
    fail "audio.sound-plays: no live Android init resolved this cycle"
    return 1
  fi
  if ! lc_unit_active rhizo-audiod.service; then
    fail "audio.sound-plays: rhizo-audiod.service is not active, real audio routing is not possible"
    return 1
  fi
  local apk="$VAR_DIR/share/rhizo-audiotest-a.apk"
  if [[ ! -f "$apk" ]]; then
    fail "audio.sound-plays: missing $apk -- tools/build/test-apps/audiotestapp.sh stages the tone fixture"
    return 1
  fi
  local sink_state
  sink_state=$(_lc_audio_host_sink_up)
  case "$sink_state" in
    MADE_SINK|HAVE_SINK) ;;
    *) fail "audio.sound-plays: the desktop user's PipeWire has no Audio/Sink and none could be made (${sink_state:-<no answer>})"; return 1 ;;
  esac
  local before=$FAILED
  _lc_audio_sound_plays "$apk"
  [[ "$sink_state" == MADE_SINK ]] && _lc_audio_host_sink_down
  (( FAILED == before ))
}

# install the tone app and record it
_lc_audio_sound_plays() {
  local apk="$1" pkg=com.rhizo.audiotest.a
  ssh_vm -t 60 'rm -f /root/rhizo-lifecycle-audiotest.apk' >/dev/null 2>&1
  timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$apk" "$SSH_TARGET:/root/rhizo-lifecycle-audiotest.apk" \
    || { fail "audio.sound-plays: could not stage $apk to the guest"; return 1; }
  local since; since=$(guest_now)
  lc_rhizo 60 app install /root/rhizo-lifecycle-audiotest.apk >/dev/null 2>&1 \
    || { fail "audio.sound-plays: rhizo app install did not accept $apk"; return 1; }
  local pkglist; pkglist=$(android_sh "$INIT" "pm list packages")
  grep -qx "package:$pkg" <<<"$pkglist" \
    || { fail "audio.sound-plays: $pkg missing from pm list packages after its install"; return 1; }
  local entry="$APPS_DIR/rhizo-$pkg.desktop" lout audio_line
  if ! drain_wrote_entry "$DRAIN_ENTRY_WAIT_S" "$pkg" "$since"; then
    fail "audio.sound-plays: no drain line for $pkg in rhizo-resync.service's journal at or after its install (guest clock ${since:-<unread>}) within ${DRAIN_ENTRY_WAIT_S}s"
    return 1
  fi
  if ! wait_guest_file 240 "$entry"; then
    fail "audio.sound-plays: $entry did not appear within 240s of installing $pkg"
    return 1
  fi
  local play_since; play_since=$(logcat_since_marker "$INIT")
  lout=$(user_sh 300 "/usr/bin/rhizo launch $pkg 2>&1; echo rc=\$?")
  if [[ "$(tail -1 <<<"$lout")" != "rc=0" ]] || ! grep -q "^RHIZO_LAUNCHED pkg=$pkg " <<<"$lout"; then
    fail "audio.sound-plays: rhizo launch $pkg (as $DESK_USER) did not launch it (last line: $(tail -1 <<<"$lout"); $(grep -m1 'RHIZO_FAIL' <<<"$lout" || echo 'no RHIZO_FAIL line'))"
    android_sh "$INIT" "am force-stop $pkg" >/dev/null 2>&1
    return 1
  fi
  audio_line=$(ssh_vm -t 15 "grep -a ' audio pkg=${pkg}[ :]'/run/rhizo-launch/rhizo-launch.log 2>/dev/null | tail -1" | tr -d '\r')
  if ! app_wait_token "RHIZO_AUDIO_PLAYING" 30 "$play_since" >/dev/null; then
    fail "audio.sound-plays: $pkg never logged RHIZO_AUDIO_PLAYING after launch"
    android_sh "$INIT" "am force-stop $pkg" >/dev/null 2>&1
    return 1
  fi
  local wav="$EV/$TEST_STEP-audio-sound-plays.wav"
  local graph="$EV/$TEST_STEP-audio-sound-plays-pw-dump.json"
  local pre="$EV/$TEST_STEP-audio-sound-plays-pw-dump-pre.json"
  rm -f "$wav" "$graph" "$pre"
  ssh_vm -t 15 'rm -f /tmp/rhizo-lifecycle-audio-capture.wav /tmp/rhizo-lifecycle-audio-graph.json /tmp/rhizo-lifecycle-audio-graph-pre.json' >/dev/null 2>&1
  local node linked out
  out=$(user_sh 20 "pw-dump > /tmp/rhizo-lifecycle-audio-graph-pre.json 2>/dev/null && echo PRE_DUMP" 2>&1)
  if ! grep -qx PRE_DUMP <<<"$(tr -d '\r' <<<"$out")" || ! pull /tmp/rhizo-lifecycle-audio-graph-pre.json "$pre" 30; then
    fail "audio.sound-plays: the user's PipeWire graph could not be read before the capture ($(tail -1 <<<"$out"))"
    android_sh "$INIT" "am force-stop $pkg" >/dev/null 2>&1
    return 1
  fi
  if ! linked=$(_lc_audio_app_on_default_sink "$pre" "$pkg"); then
    fail "audio.sound-plays: $linked (its launch: ${audio_line:-<no audio line in rhizo-launch.log>})"
    android_sh "$INIT" "am force-stop $pkg" >/dev/null 2>&1
    return 1
  fi
  node=${linked%% -> *}
  local pwout pwrc
  pwout=$(user_sh 35 "timeout 8 pw-record --target 0 -P '{ node.name=$LC_AUDIO_TAP }' --rate 48000 --channels 2 --format s16 /tmp/rhizo-lifecycle-audio-capture.wav 2>&1 & p=\$!
n=0; until pw-link -i 2>/dev/null | grep -q '^$LC_AUDIO_TAP:'; do n=\$((n + 1)); [ \$n -ge 50 ] && break; sleep 0.1; done
for o in \$(pw-link -o 2>/dev/null | awk -v n='$node:' 'index(\$0, n) == 1'); do
  ch=\${o##*_}
  for i in \$(pw-link -i 2>/dev/null | grep '^$LC_AUDIO_TAP:'); do
    case \"\$ch:\$i\" in MONO:*|*_\"\$ch\") pw-link \"\$o\" \"\$i\" && echo \"TAP_LINKED \$o \$i\" ;; esac
  done
done
if pw-dump > /tmp/rhizo-lifecycle-audio-graph.json 2>/dev/null && kill -0 \$p 2>/dev/null; then echo PW_DUMP_IN_CAPTURE; fi; wait \$p; rc=\$?; case \$rc in 124) exit 0 ;; 0) exit 90 ;; *) exit \$rc ;; esac" 2>&1)
  pwrc=$?
  local audiod_status
  audiod_status=$(ssh_vm -t 15 'cat /run/rhizo-audio/status && echo STATUS_READ' 2>/dev/null | tr -d '\r')
  android_sh "$INIT" "am force-stop $pkg" >/dev/null 2>&1
  if (( pwrc != 0 )); then
    fail "audio.sound-plays: pw-record via user_sh exited $pwrc, not the timeout-terminated 0 a running capture reports ($(tail -2 <<<"$pwout" | tr '\n' ' '))"
    return 1
  fi
  if [[ "$audiod_status" != *STATUS_READ* ]] || ! grep -qE '^streams=[1-9][0-9]*$' <<<"$audiod_status"; then
    fail "audio.sound-plays: rhizo-audiod carried no stream at the end of the capture ($(grep '^streams=' <<<"$audiod_status" || echo 'status unread'))"
    return 1
  fi
  if ! grep -qx 'PW_DUMP_IN_CAPTURE' <<<"$(tr -d '\r' <<<"$pwout")"; then
    fail "audio.sound-plays: the user's PipeWire graph was not read while the capture ran ($(tail -2 <<<"$pwout" | tr '\n' ' '))"
    return 1
  fi
  pull /tmp/rhizo-lifecycle-audio-graph.json "$graph" 30 \
    || { fail "audio.sound-plays: could not pull the pw-dump read during the capture"; return 1; }
  if ! linked=$(_lc_audio_app_on_default_sink "$graph" "$pkg"); then
    fail "audio.sound-plays: $linked (its launch: ${audio_line:-<no audio line in rhizo-launch.log>})"
    return 1
  fi
  local tapped
  if ! tapped=$(_lc_audio_tap_from_app "$graph" "$pkg"); then
    fail "audio.sound-plays: $tapped (links made: $(grep -c '^TAP_LINKED ' <<<"$(tr -d '\r' <<<"$pwout")"))"
    return 1
  fi
  pull /tmp/rhizo-lifecycle-audio-capture.wav "$wav" 30
  local pullrc=$?
  if (( pullrc != 0 )); then
    fail "audio.sound-plays: could not pull the capture of $tapped (pull exited $pullrc)"
    return 1
  fi
  if [[ ! -s "$wav" ]]; then
    fail "audio.sound-plays: the pulled capture at $wav is empty"
    return 1
  fi
  local rms
  out=$(python3 "$LC_TOOLS_DIR/../tools/wavstat.py" "$wav" 2>&1) || { fail "audio.sound-plays: wavstat.py could not read the capture: $out"; return 1; }
  rms=$(awk '$1=="rms"{print $2}' <<<"$out")
  if [[ "$rms" =~ ^[0-9.]+([eE][-+]?[0-9]+)?$ ]] && awk -v v="$rms" 'BEGIN{exit !(v>0.001)}'; then
    pass "audio.sound-plays: $pkg's own node $tapped, linked into the default sink ($linked), captured alone was non-silent (rms=$rms)"
  else
    fail "audio.sound-plays: $pkg's own node $tapped, captured alone, is silent (rms=${rms:-<none>})"
    return 1
  fi
}

# check the rhizo-audiod stream count
lc_assert_audio.idle-no-stream() {
  lc_need_guest audio.idle-no-stream || return 1
  if ! lc_unit_active rhizo-audiod.service; then
    fail "audio.idle-no-stream: rhizo-audiod.service is not active"
    return 1
  fi
  local out
  out=$(ssh_vm -t 20 'cat /run/rhizo-audio/status && echo STATUS_READ')
  if [[ -z "$out" || "$out" != *STATUS_READ* ]]; then
    fail "audio.idle-no-stream: could not read /run/rhizo-audio/status (rhizo-audiod.service not running, or the guest is unreachable)"
    return 1
  fi
  local line; line=$(grep '^streams=' <<<"$out")
  if [[ -z "$line" ]]; then
    fail "audio.idle-no-stream: /run/rhizo-audio/status carries no streams= line: $out"
    return 1
  fi
  [[ "$line" == "streams=0" ]] \
    && pass "audio.idle-no-stream: no active pw_stream from audiod while the sandbox is idle" \
    || { fail "audio.idle-no-stream: audiod reports $line with nothing playing"; return 1; }
}

# assert the host client is intact after the cycle
lc_assert_host.desktop-intact() {
  lc_need_guest host.desktop-intact || return 1
  if [[ -z "$INIT" ]]; then
    fail "host.desktop-intact: no live Android init resolved this cycle"
    return 1
  fi
  desktop_assert_host_client_intact "$INIT" "$EV"
}

_LC_FZ_FREEZE_BODY='cg=$1; rel=${cg#/sys/fs/cgroup}; keep=""; n=0
for p in $(pgrep -x rhizo-composer); do
  c=$(sed -n "s|^0::||p" "/proc/$p/cgroup")
  case "$c" in "$rel"/*) keep="$p $c"; n=$((n + 1)) ;; esac
done
if [ "$n" != 1 ]; then echo "ERR $n rhizo-composer processes in $cg"; echo DONE; exit 0; fi
set -- $keep; kp=$1; kc=$2; dir=$cg; rest=${kc#"$rel"/}
while [ -n "$rest" ]; do
  comp=${rest%%/*}
  case "$rest" in */*) rest=${rest#*/} ;; *) rest="" ;; esac
  for child in "$dir"/*/; do
    child=${child%/}
    [ -f "$child/cgroup.freeze" ] || continue
    [ "${child##*/}" = "$comp" ] && continue
    if [ "$(cat "$child/cgroup.freeze")" = 1 ]; then echo "KEPT $child"
    elif echo 1 > "$child/cgroup.freeze"; then echo "FROZE $child"
    else echo "ERR could not freeze $child"; fi
  done
  dir=$dir/$comp
done
echo "KEEP $kp $kc"; echo DONE'
_LC_FZ_VERIFY_BODY='cg=$1; kp=$2; kc=$3
live() {
  list=$(find "$cg" -name cgroup.procs) || { echo "ERR find could not walk every cgroup under $cg"; return; }
  for f in $list; do
    d=${f%/cgroup.procs}
    procs=$(cat "$f") || { echo "ERR could not list $f"; continue; }
    for p in $procs; do
      [ "$p" != "$kp" ] || continue
      grep -qx "frozen 1" "$d/cgroup.events" || echo "LIVE $p $(cat "/proc/$p/comm" 2>/dev/null) $d"
    done
  done
}
i=0
while out=$(live); [ -n "$out" ]; do
  i=$((i + 1)); [ "$i" -gt 100 ] && break
  sleep 0.1
done
[ -z "$out" ] || echo "$out"
grep -qx "frozen 0" "/sys/fs/cgroup$kc/cgroup.events" || echo "ERR the composer'"'"'s own cgroup /sys/fs/cgroup$kc does not read frozen 0"
echo DONE'
_LC_FZ_UNFREEZE_BODY='for t in "$@"; do echo 0 > "$t/cgroup.freeze" || echo "ERR could not unfreeze $t"; done; echo DONE'

# run a bash body in the guest
_lc_fz_guest() {
  local t="$1" body="$2"; shift 2
  ssh_vm -t "$t" "bash -c $(printf '%q' "$body") _ $(printf '%q ' "$@")" | tr -d '\r'
}

# test pasting a clip from frozen Android
lc_assert_clipboard.frozen-source() {
  lc_need_guest clipboard.frozen-source || return 1
  if [[ -z "$INIT" || -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "clipboard.frozen-source: no live Android init/fixture package resolved this cycle"
    return 1
  fi
  local cg; cg=$(_lc_desktop_stack_cgroup "$INIT")
  if [[ -z "$cg" ]]; then
    fail "clipboard.frozen-source: could not resolve the sandbox's own stack cgroup to freeze"
    return 1
  fi
  local why
  why=$(_lc_desktop_bridge_current 120) \
    || { fail "clipboard.frozen-source: the bridge was not up for the app's clip to cross: $why"; return 1; }
  local want want_b64; want="rhizo-frozen-$(nonce)"; want_b64=$(printf '%s' "$want" | base64 -w0)
  local before_setok; before_setok=$(rhizo_ctl_out "$INIT" | grep -c '^clip set-ok cid=')
  why=$(desk_clipboard focus-rhizo) \
    || { fail "clipboard.frozen-source: no Rhizo window took focus for the app's copy: $why"; return 1; }
  local mark; mark=$(desk_clipboard mark) || mark=""
  local fz_off; fz_off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) || fz_off=""
  local wrote_since; wrote_since=$(logcat_since_marker "$INIT")
  android_sh "$INIT" "am start -n $APP_PKG/$APP_ACT --es cmd clip_write --es mime text/plain --es b64 $want_b64" >/dev/null 2>&1
  if ! app_wait_token "RHIZO_CLIP_WROTE" 30 "$wrote_since" >/dev/null; then
    fail "clipboard.frozen-source: the app never wrote its clip for the composer's own eager copy to pick up"
    return 1
  fi
  local got_setok=$before_setok deadline
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    got_setok=$(rhizo_ctl_out "$INIT" | grep -c '^clip set-ok cid=')
    (( got_setok > before_setok )) && break
    sleep 1
  done
  if (( got_setok <= before_setok )); then
    fail "clipboard.frozen-source: the composer never acknowledged a 'clip set' for the app's own clip (no new 'clip set-ok' on control.out)"
    return 1
  fi

  local wl_off
  wl_off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) \
    || { fail "clipboard.frozen-source: rhizo-deskd.log's size read no byte offset before the wlbridge's stop"; return 1; }
  ssh_vm -t 15 "pkill -x rhizo-wlbridge" >/dev/null 2>&1
  local wl_left="" wl_rows wl_deadline; wl_deadline=$(( $(date +%s) + 10 ))
  while true; do
    wl_rows=$(ssh_vm -t 15 "ps -e -o pid=,stat=,comm=,args= && echo DONE")
    lc_done_strip wl_rows || { wl_left="<the read never finished>"; break; }
    wl_left=$(awk '$3 == "rhizo-wlbridge" && $2 !~ /^Z/ { $1 = $1; print }' <<<"$wl_rows")
    [[ -z "$wl_left" ]] && break
    (( $(date +%s) < wl_deadline )) || break
    sleep 1
  done
  if [[ -n "$wl_left" ]]; then
    local wl_why; wl_why=$(_lc_desktop_bridge_restart) || wl_why="and the bridge restart after it failed: $wl_why"
    fail "clipboard.frozen-source: rhizo-deskd's rhizo-wlbridge was not gone after its pkill ($wl_left)${wl_why:+ $wl_why}"
    return 1
  fi
  local carrier="" c_deadline=$(( $(date +%s) + 30 )) c_why=""
  while (( $(date +%s) < c_deadline )); do
    carrier=$(ssh_vm -t 15 "tail -c +$(( wl_off + 1 )) /var/log/rhizo/rhizo-deskd.log | grep -a 'clip carrier: '; echo DONE")
    lc_done_strip carrier && [[ -n "$carrier" ]] && break
    carrier=""
    sleep 1
  done
  if [[ -z "$carrier" ]]; then
    c_why="rhizo-deskd logged no clip carrier line in 30s after its wlbridge exited"
  elif [[ "$carrier" == *"handed to the composer's leg"* ]]; then
    local handed_ok=$got_setok h_deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < h_deadline )); do
      handed_ok=$(rhizo_ctl_out "$INIT" | grep -c '^clip set-ok cid=')
      (( handed_ok > got_setok )) && break
      sleep 1
    done
    (( handed_ok > got_setok )) \
      || c_why="the composer never acknowledged the clip rhizo-deskd handed it after the wlbridge exited (no new 'clip set-ok'; $(tail -1 <<<"$carrier"))"
  elif [[ "$carrier" != *"already carries Android's clip"* ]]; then
    c_why="rhizo-deskd did not hand the app's clip to the composer after its wlbridge exited: $(tail -1 <<<"$carrier")"
  fi
  if [[ -n "$c_why" ]]; then
    _lc_deskd_clip_trail "$fz_off" "$EV/clipboard-frozen-source-deskd.txt"
    local c_restart; c_restart=$(_lc_desktop_bridge_restart) || c_why+=", and the bridge restart after it failed: $c_restart"
    fail "clipboard.frozen-source: $c_why"
    return 1
  fi

  local plan frozen="" verify="" plan_err start_s elapsed got_b64="" kp="" kc="" unfreeze_out
  plan=$(_lc_fz_guest 30 "$_LC_FZ_FREEZE_BODY" "$cg")
  frozen=$(sed -n 's/^FROZE //p' <<<"$plan" | tr '\n' ' ')
  read -r _ kp kc <<<"$(grep -m1 '^KEEP ' <<<"$plan")"
  plan_err=$(grep '^ERR ' <<<"$plan" | tr '\n' ' ')
  if lc_done_strip plan && [[ -z "$plan_err" && -n "$frozen" && -n "$kp" ]]; then
    # shellcheck disable=SC2086
    verify=$(_lc_fz_guest 60 "$_LC_FZ_VERIFY_BODY" "$cg" "$kp" "$kc")
    if lc_done_strip verify && [[ -z "$verify" ]]; then
      start_s=$(date +%s)
      got_b64=$(desk_clipboard get text/plain 20 "$mark")
      elapsed=$(( $(date +%s) - start_s ))
    fi
  fi
  if [[ -n "$frozen" ]]; then
    # shellcheck disable=SC2086
    unfreeze_out=$(_lc_fz_guest 30 "$_LC_FZ_UNFREEZE_BODY" $frozen)
  fi
  [[ -n "${EV:-}" && -d "$EV" ]] && printf 'FREEZE\n%s\nVERIFY\n%s\nUNFREEZE\n%s\n' "${plan:-<none>}" "${verify:-<none>}" "${unfreeze_out:-<none>}" \
    > "$EV/${TEST_STEP:-cycle}-frozen-source-freeze.txt"
  local restore_why
  restore_why=$(_lc_desktop_bridge_restart) \
    || { fail "clipboard.frozen-source: rhizo-deskd, restarted to bring back the wlbridge leg this claim stopped, did not come back: $restore_why"; return 1; }

  if [[ -n "$frozen" ]] && { ! lc_done_strip unfreeze_out || [[ -n "$unfreeze_out" ]]; }; then
    fail "clipboard.frozen-source: the frozen cgroups did not all unfreeze: ${unfreeze_out:-<the unfreeze never finished>}"
    return 1
  fi
  if [[ -n "$plan_err" || -z "$frozen" || -z "$kp" ]]; then
    fail "clipboard.frozen-source: could not freeze every Android process but the composer in $cg: ${plan_err:-${plan:-<the freeze never answered>}}"
    return 1
  fi
  if [[ -n "$verify" ]]; then
    fail "clipboard.frozen-source: with every cgroup off the composer's path frozen, not every other Android process was: $(head -5 <<<"$verify" | tr '\n' '|')"
    return 1
  fi
  if [[ -z "$got_b64" ]]; then
    fail "clipboard.frozen-source: a host paste never completed within 20s with every Android process but the composer (pid $kp) frozen (the composer's own copy did not answer)"
    return 1
  fi
  local got_text; got_text=$(printf '%s' "$got_b64" | base64 -d 2>/dev/null)
  [[ "$got_text" == "$want" ]] \
    && pass "clipboard.frozen-source: a host paste completed from the composer's own copy in ${elapsed}s with every other Android process frozen ($(wc -w <<<"$frozen") cgroups, the app that copied and the android app among them)" \
    || { fail "clipboard.frozen-source: the host read '$got_text', the app set '$want', with every Android process but the composer frozen"; return 1; }
}

# test the password hint skip
lc_assert_clipboard.password-hint() {
  lc_need_guest clipboard.password-hint || return 1
  if [[ -z "$INIT" ]]; then
    fail "clipboard.password-hint: no live Android init resolved this cycle"
    return 1
  fi
  local marker; marker=$(logcat_since_marker "$INIT")
  local before; before=$(rhizo_ctl_out "$INIT" | grep -c '^clip id=')
  local hint_b64; hint_b64=$(printf 'rhizo-hint-%s' "$(nonce)" | base64 -w0)
  desk_clipboard set "text/plain,x-kde-passwordManagerHint" "$hint_b64" >/dev/null 2>&1
  local deadline seen=0
  deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    (( $(rhizo_ctl_out "$INIT" | grep -c '^clip id=') > before )) && { seen=1; break; }
    sleep 1
  done
  if (( seen )); then
    fail "clipboard.password-hint: the composer downloaded a selection whose mime list carried x-kde-passwordManagerHint alongside text/plain"
    return 1
  fi
  local composer_log; composer_log=$(android_sh "$INIT" "logcat -d -b all -t '$marker'")
  if ! grep -qF 'selection carries a password-manager hint' <<<"$composer_log"; then
    fail "clipboard.password-hint: the composer never logged 'selection carries a password-manager hint' after $marker"
    return 1
  fi

  local control_b64; control_b64=$(printf 'rhizo-control-%s' "$(nonce)" | base64 -w0)
  desk_clipboard set text/plain "$control_b64" >/dev/null 2>&1
  local control_seen=0
  deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    (( $(rhizo_ctl_out "$INIT" | grep -c '^clip id=') > before )) && { control_seen=1; break; }
    sleep 1
  done
  (( control_seen )) \
    && pass "clipboard.password-hint: an offer carrying x-kde-passwordManagerHint alongside text/plain was never downloaded (and the composer logged the skip), while a plain offer right after was" \
    || { fail "clipboard.password-hint: even a plain text/plain offer never reached the composer"; return 1; }
}

# test the compositor socket uid
lc_assert_session.user-is-desktop-user() {
  lc_need_guest session.user-is-desktop-user || return 1
  local env uid wd out
  env=$(desk_env 2>/dev/null)
  uid=$(grep -o 'RHIZO_DESK_UID=[0-9]*' <<<"$env" | cut -d= -f2)
  wd=$(grep -o 'WAYLAND_DISPLAY=[^[:space:]]*' <<<"$env" | cut -d= -f2)
  [[ "$uid" != 0 && -n "$uid" ]] \
    || { fail "session.user-is-desktop-user: desk_env reported no non-root uid (RHIZO_DESK_UID='$uid')"; return 1; }
  [[ -n "$wd" ]] \
    || { fail "session.user-is-desktop-user: desk_env found no compositor socket in uid $uid's runtime dir"; return 1; }
  local probe='import os, socket, stat, sys
p = sys.argv[1]
st = os.stat(p)
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
s.connect(p)
print("SOCK uid=%d sock=%d" % (st.st_uid, stat.S_ISSOCK(st.st_mode)))'
  out=$(desk_user_sh 15 "python3 -c $(printf '%q' "$probe") \"\$XDG_RUNTIME_DIR/$wd\"" 2>&1)
  grep -qx "SOCK uid=$uid sock=1" <<<"$out" \
    && pass "session.user-is-desktop-user: the compositor's socket $wd is owned by uid $uid, not root, and accepts a connection" \
    || { fail "session.user-is-desktop-user: the session socket $wd did not read back as a live socket owned by uid $uid: ${out:-<empty>}"; return 1; }
}

LC_UNIT_PATH_PROPS=Id,FragmentPath,SourcePath,DropInPaths,ExecCondition,ExecStartPre,ExecStart,ExecStartPost,ExecReload,ExecStop,ExecStopPost,WorkingDirectory,RootDirectory,RootImage,EnvironmentFiles,ReadWritePaths,ReadOnlyPaths,InaccessiblePaths,ExecPaths,NoExecPaths,BindPaths,BindReadOnlyPaths,RequiresMountsFor,PIDFile,StandardInputFileDescriptorName,StandardOutputFileDescriptorName,StandardErrorFileDescriptorName,Paths,Where,What,Listen,User,Type,Options,Slice

# classify unit paths under user directories
_lc_unit_reach_classify() {
  awk -v home="$1" '
    function reach(p,    u) {
      if (p ~ /^\/home\/[^\/]/) return 1
      if (home != "" && (p == home || index(p, home "/") == 1)) return 1
      if (p ~ /^\/run\/user\/[^\/]*[*?[]/) return 1
      if (p ~ /^\/run\/user\/[0-9]+(\/|$)/) {
        u = substr(p, 11); sub(/\/.*/, "", u)
        if (u + 0 == 0) return 0
        return p ~ /^\/run\/user\/[0-9]+\/?$/ ? 2 : 1
      }
      return 0
    }
    function hex(s) {
      s = tolower(s)
      return (index("0123456789abcdef", substr(s, 1, 1)) - 1) * 16 + index("0123456789abcdef", substr(s, 2, 1)) - 1
    }
    function unesc(s,    o, i, c) {  # unescape a systemd unit name
      o = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "-") o = o "/"
        else if (c == "\\" && substr(s, i + 1, 3) ~ /^x[0-9a-fA-F][0-9a-fA-F]$/) { o = o sprintf("%c", hex(substr(s, i + 2, 2))); i += 3 }
        else o = o c
      }
      return o
    }
    # resolve unit specifiers in a value
    function spec(v, u,    at, nm, inst, pre, usr, hm, id, o, i, c) {
      unres = 0
      nm = u; sub(/\.[^.]*$/, "", nm)
      at = index(nm, "@")
      pre = at ? substr(nm, 1, at - 1) : nm
      inst = at ? substr(nm, at + 1) : ""
      usr = prop[u, "User"]
      if (usr ~ /^(|root|0)$/) { hm = "/root"; id = "0" }
      else if (usr in pwuid) { hm = pwhome[usr]; id = pwuid[usr] }
      o = ""
      for (i = 1; i <= length(v); i++) {
        c = substr(v, i, 1)
        if (c != "%" || i == length(v)) { o = o c; continue }
        c = substr(v, ++i, 1)
        if (c == "%") o = o "%"
        else if (c == "i") o = o inst
        else if (c == "I") o = o unesc(inst)
        else if (c == "f") o = o "/" unesc(at ? inst : pre)
        else if (c == "p") o = o pre
        else if (c == "P") o = o unesc(pre)
        else if (c == "n") o = o u
        else if (c == "N") o = o nm
        else if (c == "t") o = o "/run"
        else if (c == "S") o = o "/var/lib"
        else if (c == "C") o = o "/var/cache"
        else if (c == "L") o = o "/var/log"
        else if (c == "E") o = o "/etc"
        else if (c == "T") o = o "/tmp"
        else if (c == "V") o = o "/var/tmp"
        else if (c == "h" || c == "U") { if (hm == "") { unres = 1; return "" }; o = o (c == "h" ? hm : id) }
        else o = o "%" c
      }
      return o
    }
    function conds(u,    nf, fl, i, f, j, k, v, p, r) {
      nf = split(prop[u, "FragmentPath"] " " prop[u, "DropInPaths"], fl, " ")
      for (i = 1; i <= nf; i++) {
        f = fl[i]
        if (!(f in frc)) { print "UNREAD " u " unit file " f " was never read"; continue }
        if (frc[f] != "0") { print "UNREAD " u " unit file " f " could not be read (sed rc " frc[f] ")"; continue }
        for (j = 1; j <= nc[f]; j++) {
          k = cond[f, j]; sub(/[ \t]*=.*/, "", k)
          v = cond[f, j]; sub(/^[^=]*=[ \t]*/, "", v); sub(/^\|[ \t]*/, "", v); sub(/^![ \t]*/, "", v)
          p = spec(v, u)
          if (unres) { print "UNREAD " u " " cond[f, j] " names %h or %U and User=" prop[u, "User"] " did not resolve"; continue }
          if (p ~ /^\// && (r = reach(p))) { hit[u, ++nh[u]] = k " " p " (in " f ")"; kind[u, nh[u]] = r }
        }
      }
    }
    # match a logind session scope home
    function logind_home(u, h,    uid) {
      if (u !~ /^session-[0-9]+\.scope$/ || prop[u, "FragmentPath"] != "/run/systemd/transient/" u) return 0
      if (prop[u, "SourcePath"] != "") return 0
      if (prop[u, "Slice"] !~ /^user-[1-9][0-9]*\.slice$/) return 0
      uid = prop[u, "Slice"]; sub(/^user-/, "", uid); sub(/\.slice$/, "", uid)
      return (uid in pwhome) && pwuid[uid] == uid && pwhome[uid] ~ /^\/./ && h == "RequiresMountsFor " pwhome[uid]
    }
    function flush(u,    fromfile, i, h, own, mine) {
      if (u == "") return
      fromfile = prop[u, "FragmentPath"] != "" || prop[u, "DropInPaths"] != "" \
        || (prop[u, "SourcePath"] != "" && prop[u, "SourcePath"] !~ /^\/proc\//)
      if (fromfile && prop[u, "WorkingDirectory"] ~ /^!?~$/ && prop[u, "User"] !~ /^(|root|0)$/)
        hit[u, ++nh[u]] = "WorkingDirectory ~ (the home of User=" prop[u, "User"] ")"
      conds(u)
      if (nh[u] == 0) return
      if (!fromfile && u !~ /\.(mount|automount|swap)$/) return
      own = prop[u, "Type"] ~ /^fuse(blk)?\./ && prop[u, "Options"] ~ /(^|,)user_id=[1-9][0-9]*(,|$)/
      for (i = 1; i <= nh[u]; i++) {
        h = hit[u, i]
        if (fromfile && logind_home(u, h)) { print "SKIP " u " " h " (logind'"'"'s own session scope, " prop[u, "Slice"] "'"'"'s home)"; continue }
        if (fromfile) { print "REACH " u " " h; continue }
        mine = own || (kind[u, i] == 2 && h ~ /^Where / && prop[u, "Type"] == "tmpfs")
        print (mine ? "SKIP " : "REACH ") u " " h " (a mount-table unit, What=" prop[u, "What"] \
          " Type=" prop[u, "Type"] (mine ? ", the user'"'"'s own)" : ", not a user'"'"'s own FUSE mount)")
      }
    }
    FILENAME == ARGV[1] { if ($0 != "") order[++nw] = $0; next }
    FILENAME == ARGV[2] {
      if (/^FILE /) { cf = substr($0, 6); frc[cf] = "<unfinished>"; sec = ""; cont = ""; next }
      if (/^FILERC /) { if (cf != "") frc[cf] = substr($0, 8); cf = ""; next }
      if (/^PASSWD /) {
        l = substr($0, 9 + length($2))
        if (split(l, pw, ":") >= 7 && pw[3] ~ /^[0-9]+$/) { pwuid[$2] = pw[3]; pwhome[$2] = pw[6] }
        next
      }
      if (cf == "" || substr($0, 1, 1) != " ") next
      l = substr($0, 2)
      if (cont == "" && l ~ /^[ \t]*[#;]/) next
      l = cont l; cont = ""
      if (l ~ /\\$/) { cont = substr(l, 1, length(l) - 1) " "; next }
      sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l)
      if (l ~ /^\[.*\]$/) { sec = l; next }
      if (sec == "[Unit]" && l ~ /^(Condition|Assert)[A-Za-z]+[ \t]*=/) cond[cf, ++nc[cf]] = l
      next
    }
    /^UNIT / { flush(cur); cur = substr($0, 6); seen[cur] = 1; next }
    /^SHOWRC / { rc[cur] = substr($0, 8); next }
    cur != "" && /^[A-Za-z]+=/ {
      k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1)
      if (k == "Id") { id[cur] = v; next }
      if (k ~ /^(FragmentPath|SourcePath|DropInPaths|What|Type|Options|User|WorkingDirectory|Slice)$/) prop[cur, k] = v
      n = split(v, f, /[[:space:];:,()"\047=]+/)
      for (i = 1; i <= n; i++) {
        p = f[i]; sub(/^[-+!@]+/, "", p)
        if (p ~ /^\// && (r = reach(p))) { hit[cur, ++nh[cur]] = k " " p; kind[cur, nh[cur]] = r }
      }
    }
    END {
      flush(cur)
      for (i = 1; i <= nw; i++) {
        u = order[i]
        if (!(u in seen)) print "UNREAD " u " has no systemctl show block"
        else if (rc[u] != "0") print "UNREAD " u " systemctl show exited " (rc[u] == "" ? "<unread>" : rc[u])
        else if (id[u] == "") print "UNREAD " u " read no Id"
      }
    }' <(printf '%s\n' "$2") <(printf '%s\n' "${4:-}") <(printf '%s\n' "$3")
}

# print the unit names in a listing
_lc_unit_names() {
  awk '{ for (i = 1; i <= NF; i++) if ($i ~ /\.(service|socket|target|device|mount|automount|swap|timer|path|slice|scope)$/) { if ($i !~ /@\./) print $i; break } }'
}
# classify unit paths under user directories
_lc_system_unit_reach() {
  local lists loaded names i out shown=""
  lists=$(ssh_vm -t 60 "systemctl list-units --all --plain --no-legend; echo LURC=\$?; systemctl list-unit-files --plain --no-legend --state=enabled,enabled-runtime,linked,linked-runtime; echo LFRC=\$?; echo DONE" 2>/dev/null | tr -d '\r')
  lc_done_strip lists || { echo "the unit listing never finished"; return 1; }
  if ! grep -qx 'LURC=0' <<<"$lists" || ! grep -qx 'LFRC=0' <<<"$lists"; then
    echo "a unit listing failed ($(grep -E '^L[UF]RC=' <<<"$lists" | tr '\n' ' '))"; return 1
  fi
  loaded=$(sed '/^LURC=/,$d' <<<"$lists" | _lc_unit_names)
  [[ -n "$loaded" ]] || { echo "list-units named no unit"; return 1; }
  names=$(grep -v -E '^L[UF]RC=' <<<"$lists" | _lc_unit_names | sort -u)
  local -a all; mapfile -t all <<<"$names"
  for (( i = 0; i < ${#all[@]}; i += 150 )); do
    out=$(ssh_vm -t 300 "for u in $(printf '%q ' "${all[@]:i:150}"); do echo \"UNIT \$u\"; systemctl show -p $LC_UNIT_PATH_PROPS -- \"\$u\"; echo \"SHOWRC \$?\"; done; echo DONE" 2>/dev/null | tr -d '\r')
    lc_done_strip out || { echo "the unit read never finished (units $i onward of ${#all[@]})"; return 1; }
    shown+="$out"$'\n'
  done
  local -a files users; local files_out="" who=""
  mapfile -t files < <(sed -n 's/^FragmentPath=//p; s/^DropInPaths=//p' <<<"$shown" | tr ' ' '\n' | grep '^/' | sort -u)
  mapfile -t users < <(sed -n 's/^User=//p; s/^Slice=user-\([0-9]*\)\.slice$/\1/p' <<<"$shown" | grep -vxE '(root|0)?' | sort -u)
  (( ${#users[@]} )) && who="for u in $(printf '%q ' "${users[@]}"); do echo \"PASSWD \$u \$(getent passwd \"\$u\")\"; done; "
  for (( i = 0; i < ${#files[@]}; i += 150 )); do
    out=$(ssh_vm -t 300 "for f in $(printf '%q ' "${files[@]:i:150}"); do echo \"FILE \$f\"; sed 's/^/ /' \"\$f\"; r=\$?; echo; echo \"FILERC \$r\"; done; ${who}echo DONE" 2>/dev/null | tr -d '\r')
    lc_done_strip out || { echo "the unit file read never finished (files $i onward of ${#files[@]})"; return 1; }
    files_out+="$out"$'\n'
  done
  echo "UNITS ${#all[@]}"
  _lc_unit_reach_classify "$1" "$names" "$shown" "$files_out"
}

# test the session.env file
lc_assert_session.env-from-user-manager() {
  local c=session.env-from-user-manager env uid wd user home out want
  lc_need_guest "$c" || return 1
  env=$(desk_env 2>/dev/null)
  uid=$(grep -o 'RHIZO_DESK_UID=[0-9]*' <<<"$env" | cut -d= -f2)
  wd=$(grep -o 'WAYLAND_DISPLAY=[^[:space:]]*' <<<"$env" | cut -d= -f2)
  [[ -n "$uid" && "$uid" != 0 && -n "$wd" ]] \
    || { fail "$c: desk_env found no live non-root session (uid='$uid' WAYLAND_DISPLAY='$wd')"; return 1; }
  user=$(lc_desktop_user)
  out=$(ssh_vm -t 30 'for u in rhizo-desktop-session.path rhizo-desktop-session.service; do
  echo "LOAD $u=$(systemctl show -p LoadState --value -- "$u")"; done; echo DONE')
  lc_done_strip out || { fail "$c: the PID 1 unit read never finished"; return 1; }
  local loads; loads=$(grep '^LOAD ' <<<"$out" | cut -d' ' -f2- | tr '\n' ' ')
  [[ "$loads" == "rhizo-desktop-session.path=not-found rhizo-desktop-session.service=not-found " ]] \
    || { fail "$c: PID 1 still loads a desktop-session unit: ${loads:-<no LoadState read>}"; return 1; }
  out=$(desk_user_sh 20 "systemctl --user is-active rhizo-desktop-session.path rhizo-desktop-session.service
stat -c %Y \"\$XDG_RUNTIME_DIR/$wd\" 2>/dev/null || echo none
stat -c '%u %a %Y' /run/rhizo-desktop/session.env 2>/dev/null || echo none
getent passwd $uid | cut -d: -f6
cat /run/rhizo-desktop/session.env; echo DONE")
  lc_done_strip out || { fail "$c: the desktop user's read never finished: ${out:-<empty>}"; return 1; }
  [[ "$(sed -n 1,2p <<<"$out" | tr '\n' ' ')" == "active active " ]] \
    || { fail "$c: $user's manager does not run the pair: $(sed -n 1,2p <<<"$out" | tr '\n' ' ')"; return 1; }
  local sock_t env_uid env_mode env_t
  sock_t=$(sed -n 3p <<<"$out"); read -r env_uid env_mode env_t <<<"$(sed -n 4p <<<"$out")"; home=$(sed -n 5p <<<"$out")
  [[ "$env_uid" == "$uid" && "$env_mode" == 644 && "$env_t" =~ ^[0-9]+$ && "$sock_t" =~ ^[0-9]+$ ]] && (( env_t >= sock_t )) \
    || { fail "$c: session.env is not uid $uid's own 0644 file written after the socket (file: '$env_uid $env_mode $env_t', socket mtime '$sock_t')"; return 1; }
  want=$(printf '%s\n' "XDG_RUNTIME_DIR=/run/user/$uid" "WAYLAND_DISPLAY=$wd" \
    "RHIZO_WAYLAND_HOST_SOCKET=/run/user/$uid/$wd" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" "HOME=$home")
  [[ "$home" == /?* && "$(tail -n +6 <<<"$out")" == "$want" ]] \
    || { fail "$c: session.env does not name $user's own session: $(tail -n +6 <<<"$out" | tr '\n' ' ')"; return 1; }
  local rc reach bad sweep="${EV:-}/session-env-unit-reach.txt"
  rc=$(ssh_vm -t 60 "systemctl daemon-reload >/dev/null 2>&1; echo RC=\$?" 2>/dev/null | tr -d '\r' | tail -1)
  [[ "$rc" == RC=0 ]] || { fail "$c: systemctl daemon-reload did not exit 0 (${rc:-no RC read})"; return 1; }
  # desk-user-ok:
  rc=$(ssh_vm -t 30 "systemd-run --quiet --unit=rhizo-lc-dacprobe --path-property=PathExistsGlob=/run/user/$uid/rhizo-lc-dacprobe-\\* -p ConditionPathExists=/run/user/$uid/rhizo-lc-dacprobe-cond /bin/true >/dev/null 2>&1; echo RC=\$?" 2>/dev/null | tr -d '\r' | tail -1)
  if [[ "$rc" == RC=0 ]]; then
    reach=$(_lc_system_unit_reach "$home"); rc=$?
  else
    reach="the planted PID 1 .path could not be started (${rc:-no RC read})"; rc=1
  fi
  ssh_vm -t 20 'systemctl stop rhizo-lc-dacprobe.path rhizo-lc-dacprobe.service; systemctl reset-failed rhizo-lc-dacprobe.path rhizo-lc-dacprobe.service' >/dev/null 2>&1
  if (( rc != 0 )); then
    [[ -n "${EV:-}" && -d "$EV" ]] && printf '<unread: %s>\n' "$reach" > "$sweep"
    fail "$c: the system units could not be read: $reach"; return 1
  fi
  [[ -n "${EV:-}" && -d "$EV" ]] && printf '%s\n' "$reach" > "$sweep"
  bad=$(sed -n 's/^UNREAD //p' <<<"$reach")
  [[ -z "$bad" ]] || { fail "$c: $(grep -c . <<<"$bad") system unit(s) could not be read: $(tr '\n' '|' <<<"$bad")"; return 1; }
  grep -q "^REACH rhizo-lc-dacprobe\.path Paths /run/user/$uid/" <<<"$reach" \
    || { fail "$c: the planted PID 1 .path watching /run/user/$uid was not named by the unit read"; return 1; }
  grep -q "^REACH rhizo-lc-dacprobe\.service ConditionPathExists /run/user/$uid/" <<<"$reach" \
    || { fail "$c: the planted PID 1 .service's ConditionPathExists under /run/user/$uid was not named by the unit file read"; return 1; }
  bad=$(grep '^REACH ' <<<"$reach" | grep -v -E '^REACH rhizo-lc-dacprobe\.(path|service) ' | cut -d' ' -f2-)
  [[ -z "$bad" ]] \
    || { fail "$c: $(grep -c . <<<"$bad") system unit propert(ies) name a path in a user dir (unit property path): $(tr '\n' '|' <<<"$bad")"; return 1; }
  pass "$c: $user's own manager wrote session.env ($wd, uid $uid, after the socket), PID 1 loads no desktop-session unit, and after a daemon-reload none of the $(sed -n 's/^UNITS //p' <<<"$reach") system units loaded, enabled or linked names a path under /home/, $home or a non-root /run/user/<uid>/ in a property or a Condition/Assert of its files (the planted .path and its .service's Condition under /run/user/$uid were named)"
}

LC_SEAT_LOGIN_ROWS=""
LC_SEAT_LOGIN_N=0

# print the seat login fields for a profile
_lc_seat_login_kind() {
  case "$1" in
    sway) echo "sway login -" ;;
    gnome) echo "gnome-shell gdm-autologin gdm" ;;
    plasma) echo "kwin_wayland plasmalogin-autologin -" ;;
    *) return 1 ;;
  esac
}

# record the seat login of this boot
lc_seat_login_record() {
  local profile="$1" label="$2" comm service greeter boot seat verdict rc kind result f
  read -r comm service greeter <<<"$(_lc_seat_login_kind "$profile")"
  [[ -n "$comm" ]] || return 0
  [[ "$greeter" == - ]] && greeter=""
  LC_SEAT_LOGIN_N=$((LC_SEAT_LOGIN_N + 1))
  f="$EV/seat-login-$LC_SEAT_LOGIN_N"
  [[ -n "$LC_SEAT_LOGIN_ROWS" ]] || printf 'boot_id\tlabel\tkind\tresult\tdetail\n' > "$EV/seat-login.tsv"
  boot=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]-')
  desk_session_up --user "$LC_DESKTOP_HUMAN" > "$f-attach.log" 2>&1
  rc=$?
  seat=$(desk_seat_read "$LC_DESKTOP_HUMAN" "$comm" "$greeter")
  verdict=$(desk_seat_verdict "$LC_DESKTOP_HUMAN" "$service" "$greeter" "$seat") && result=pass || result=fail
  kind=$(sed -n '1s/^kind=//p' <<<"$verdict")
  printf 'label=%s boot=%s attach_rc=%s\n=== read\n%s\n=== verdict\n%s\n' "$label" "${boot:-<unread>}" "$rc" "$seat" "$verdict" > "$f.txt"
  LC_SEAT_LOGIN_ROWS+="${boot:-<unread>}"$'\t'"$label"$'\t'"${kind:-unknown}"$'\t'"$result"$'\t'"$(tail -n +2 <<<"$verdict" | tr '\n' '|' | head -c 600)"$'\n'
  tail -1 <<<"${LC_SEAT_LOGIN_ROWS%$'\n'}" >> "$EV/seat-login.tsv"
  log "seat login [$label]: $result, ${kind:-unknown} boot ${boot:-<unread>}, attach rc=$rc: $(tail -n +2 <<<"$verdict" | head -2 | tr '\n' ' ' | head -c 300)"
}

# record the seat login on reboot
installer_post_reboot_hook() {
  lc_seat_login_record "${LIFECYCLE_PROFILE:-}" "$1"
  if [[ -n "${BUS_ADDR:-}" ]]; then
    _lc_private_bus \
      || log "$1: no session dbus-daemon for ${DESK_USER:-<no user>} after the reboot"
  fi
}

LC_POLICY_BOOTS_CMD=$(cat <<'EOF'
journalctl -o json --no-pager _PID=1 UNIT=rhizo-policy.service 2>/dev/null \
  | grep -E '"MESSAGE_ID":"(39f53479d3a045ac8e11786248231fbf|be02cf6855d2428ba40df7e9d022f03d)"' \
  | sed -n 's/.*"_BOOT_ID":"\([0-9a-f]*\)".*/\1/p' | sort -u
echo DONE
EOF
)

LC_LIST_BOOTS_AWK='$2 ~ /^[0-9a-f]{32}$/ { print $2 }'
LC_LIST_BOOTS_CMD="journalctl --list-boots --no-pager 2>/dev/null | awk '$LC_LIST_BOOTS_AWK'
echo DONE"

# test seat login rows against the journal boots
lc_assert_host.seat-login() {
  local c=host.seat-login bad boots b missing="" npol listed row_b row_label row_kind unlisted="" unstarted=""
  lc_need_guest "$c" || return 1
  if [[ -z "$LC_SEAT_LOGIN_ROWS" ]]; then
    printf '<none>\n' > "$EV/seat-login-policy-boots.txt"
    fail "$c: no boot of this cycle recorded a seat-login read"
    return 1
  fi
  bad=$(awk -F'\t' 'NF && $4 != "pass" { print $2 " (boot " $1 ", " $3 "): " $5 }' <<<"$LC_SEAT_LOGIN_ROWS")
  if [[ -n "$bad" ]]; then
    printf '<not read: a recorded boot failed>\n' > "$EV/seat-login-policy-boots.txt"
    fail "$c: $(grep -c . <<<"$bad") boot(s) came up without a working seat login (see $EV/seat-login.tsv): $(head -3 <<<"$bad" | tr '\n' ';')"
    return 1
  fi
  boots=$(ssh_vm -t 60 "$LC_POLICY_BOOTS_CMD")
  if ! lc_done_strip boots; then
    printf '<incomplete read>\n' > "$EV/seat-login-policy-boots.txt"
    fail "$c: the journal read of the boots that started rhizo-policy.service never finished: ${boots:-<empty>}"
    return 1
  fi
  printf '%s\n' "${boots:-<none>}" > "$EV/seat-login-policy-boots.txt"
  [[ -n "$boots" ]] || { fail "$c: this disk's journal holds no boot whose PID 1 started rhizo-policy.service"; return 1; }
  listed=$(ssh_vm -t 60 "$LC_LIST_BOOTS_CMD")
  if ! lc_done_strip listed; then
    printf '<incomplete read>\n' > "$EV/seat-login-journal-boots.txt"
    fail "$c: the journal's boot list never finished: ${listed:-<empty>}"
    return 1
  fi
  printf '%s\n' "${listed:-<none>}" > "$EV/seat-login-journal-boots.txt"
  while IFS=$'\t' read -r row_b row_label row_kind _; do
    [[ -n "$row_b" ]] || continue
    grep -qxF -- "$row_b" <<<"$listed" || unlisted+=" $row_b ($row_label)"
    [[ "$row_kind" == policy ]] && ! grep -qxF -- "$row_b" <<<"$boots" && unstarted+=" $row_b ($row_label)"
  done <<<"$LC_SEAT_LOGIN_ROWS"
  [[ -z "$unlisted" ]] \
    || { fail "$c: boot(s)$unlisted are not in this disk's journal (see $EV/seat-login-journal-boots.txt)"; return 1; }
  [[ -z "$unstarted" ]] \
    || { fail "$c: boot(s)$unstarted ran under the policy but the journal's rhizo-policy.service starts miss them (see $EV/seat-login-policy-boots.txt)"; return 1; }
  for b in $boots; do
    awk -F'\t' -v b="$b" '$1 == b && $3 == "policy" { f = 1 } END { exit !f }' <<<"$LC_SEAT_LOGIN_ROWS" || missing+=" $b"
  done
  [[ -z "$missing" ]] \
    || { fail "$c: boot(s)$missing started rhizo-policy.service, and no seat-login read under the policy was recorded for them"; return 1; }
  npol=$(awk -F'\t' '$3 == "policy"' <<<"$LC_SEAT_LOGIN_ROWS" | grep -c .)
  pass "$c: all $(grep -c . <<<"$LC_SEAT_LOGIN_ROWS") boot(s) read came up with a working seat login, the $npol under Rhizo's policy among them, each is in this disk's journal, and they cover every boot that started rhizo-policy.service"
}
