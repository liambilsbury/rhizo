#!/bin/bash
# implement the desk_* functions for KDE Plasma

_PLASMA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/desk-user-lib.sh"

PLASMA_HARNESS_DIR="/tmp/rhizo-plasma-harness"
PLASMA_RIG_UNIT="rhizo-kwin"
PLASMA_INJECT_UNIT="rhizo-kde-inject"
PLASMA_INJECT_FIFO="/tmp/rhizo-plasma-inject.fifo"
PLASMA_INJECT_OUT="/tmp/rhizo-plasma-inject.out"
PLASMA_WATCH_UNIT="rhizo-notify-watch"
PLASMA_NOTIFY_REC="/tmp/rhizo-plasma-notif.jsonl"
PLASMA_VOUT_UNIT="rhizo-virtual-output"
PLASMA_VOUT_TOOL="/usr/local/bin/kde-virtual-output"

PLASMA_PICK_SOCKET=$(cat <<'EOF'
unset WAYLAND_DISPLAY
for _s in $(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E '^wayland-[0-9]+$'); do
  if awk -v p="$XDG_RUNTIME_DIR/$_s" 'NR > 1 && $4 == "00010000" && $8 == p { f = 1 } END { exit !f }' /proc/net/unix; then
    export WAYLAND_DISPLAY="$_s"
    break
  fi
done
EOF
)

# run a command in the Plasma session
gcmd_plasma() { desk_user_sh "${2:-20}" "$PLASMA_PICK_SOCKET
$1"; }

# run a command in the guest
gcmd_root() { ssh_vm -t "${2:-20}" "$1"; }
# run a command in the Plasma session
gcmd_user() { gcmd_plasma "$1" "${2:-20}"; }
# poll a guest command for success
wait_guest() {
  local deadline_s="$1" test_cmd="$2" start
  start=$(date +%s)
  while true; do
    if gcmd_user "$test_cmd" >/dev/null 2>&1; then return 0; fi
    if (( $(date +%s) - start > deadline_s )); then return 1; fi
    sleep 1
  done
}

# run plasma-harness.py in the guest
_plasma_harness() {
  gcmd_plasma "python3 $PLASMA_HARNESS_DIR/plasma-harness.py $1" "${2:-20}"
}

# print rig or login for the session
_plasma_mode() {
  local out wd rig
  out=$(gcmd_plasma "echo \"WD=\${WAYLAND_DISPLAY:-}\"; systemctl --user is-active -q $PLASMA_RIG_UNIT && echo RIG=1" 15)
  wd=$(sed -n 's/^WD=//p' <<<"$out")
  rig=$(sed -n 's/^RIG=//p' <<<"$out")
  case "$wd" in
    wayland-[0-9]*) if [[ "$rig" == 1 ]]; then echo rig; else echo login; fi ;;
    *) echo "no plasma session listens on a wayland socket" >&2; return 1 ;;
  esac
}

PLASMA_INJECT_SCRIPT=$(cat <<'EOF'
answers() { c=$(grep -cE '^(ok|err)( |$)' "$out"); [ $? -le 1 ] && echo "$c"; }
systemctl is-active -q "$unit" \
  || { echo "the session input device $unit is not running: desk_session_up starts it"; exit 1; }
[ -r "$out" ] || { echo "the session input device's answers $out are missing or unreadable"; exit 1; }
n=$(answers) || { echo "the session input device's answers $out did not read"; exit 1; }
lines=$(wc -l < "$out") || { echo "the session input device's answers $out did not read"; exit 1; }
printf '%s\n' "$@" > "$fifo" || { echo "the session input device's FIFO $fifo took no events"; exit 1; }
end=$(( $(date +%s) + 20 ))
while :; do
  c=$(answers) || { echo "the session input device's answers $out did not read"; exit 1; }
  [ "$c" -ge $(( n + $# )) ] && break
  systemctl is-active -q "$unit" || { echo "kde-inject exited: $(tail -2 "$out" | tr '\n' ' ')"; exit 1; }
  [ "$(date +%s)" -lt "$end" ] || { echo "kde-inject answered $(( c - n )) of $# events within 20s"; exit 1; }
  sleep 0.05
done
refused=$(tail -n "+$(( lines + 1 ))" "$out" | grep -m1 '^err ')
[ -z "$refused" ] || { echo "kde-inject refused an event: ${refused#err }"; exit 1; }
EOF
)

# send event lines to the input device
_plasma_inject() {
  local line out
  for line in "$@"; do
    [[ -z "$line" || "$line" =~ ^(move\ -?[0-9]+(\.[0-9]+)?\ -?[0-9]+(\.[0-9]+)?|button\ [0-9]+\ [01]|key\ [0-9]+\ [01]|axis\ [01]\ -?[0-9]+(\.[0-9]+)?)$ ]] \
      || { echo "_plasma_inject: not an event line: '$line'" >&2; return 2; }
  done
  out=$(gcmd_plasma "set -- $(printf '%q ' "$@")
unit=$PLASMA_INJECT_UNIT out=$PLASMA_INJECT_OUT fifo=$PLASMA_INJECT_FIFO
$PLASMA_INJECT_SCRIPT" 30) || { echo "_plasma_inject: ${out:-the guest did not answer}" >&2; return 1; }
}

# start the Plasma session
_desk_plasma_session_up() {
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage-login) args+=(--stage-login); shift ;;
      --user|--layout|--monitors) args+=("$1" "$2"); shift 2 ;;
      *) echo "_desk_plasma_session_up: unknown argument $1" >&2; return 2 ;;
    esac
  done
  "$_PLASMA_LIB_DIR/../../vm/start/start-plasma.sh" "${args[@]}"
}

# stop the plasma session
_desk_plasma_session_down() { "$_PLASMA_LIB_DIR/../../vm/start/start-plasma.sh" --stop; }

# print the session environment
_desk_plasma_env() {
  gcmd_plasma 'echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"; echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"; echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"; echo "RHIZO_DESK_UID=$(id -u)"' 15
}

# print the path of the plasma wayland socket
_desk_plasma_socket_path() {
  gcmd_plasma '[ -n "${WAYLAND_DISPLAY:-}" ] && echo "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"' 15
}

# capture a screenshot with plasma-harness.py
_desk_plasma_shot() {
  local out="$1" region="${2:-}" output="${3:-}" shot_args="$1"
  if [[ -n "$region" ]]; then
    local x y w h
    IFS=',' read -r x y w h <<<"$region"
    shot_args="$shot_args $x $y $w $h"
  fi
  [[ -n "$output" ]] && shot_args="$shot_args --output $output"
  _plasma_harness "shot $shot_args" 45
}

# send a pointer event to the input device
_desk_plasma_inject_pointer() {
  local verb="$1"; shift
  case "$verb" in
    abs) _plasma_inject "move $1 $2" ;;
    btn) _plasma_inject "button $1 $2" ;;
    axis)
      case "$1" in
        v) _plasma_inject "axis 0 $2" ;;
        h) _plasma_inject "axis 1 $2" ;;
        *) echo "_desk_plasma_inject_pointer axis: want h or v, got '$1'" >&2; return 2 ;;
      esac
      ;;
    *) echo "_desk_plasma_inject_pointer: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# inject a single key event
_desk_plasma_inject_key() { _plasma_inject "key $1 $2"; }

# list the toplevel windows
_desk_plasma_windows() { _plasma_harness "windows" "${1:-20}"; }

# run a window operation through plasma-harness.py
_desk_plasma_window_op() {
  local id="$1" op="$2"; shift 2
  local extra=""
  case "$op" in
    move|resize) extra="$1 $2" ;;
    to_monitor) extra="$1" ;;
    fullscreen|unfullscreen|maximize|unmaximize|activate|close) ;;
    *) echo "_desk_plasma_window_op: unknown op '$op'" >&2; return 2 ;;
  esac
  _plasma_harness "window-op $id $op $extra"
}

# add a kwin virtual output of WxH to the seat login and print its name
_plasma_virtual_output_add() {
  local w="${1%x*}" h="${1#*x}" n out name end
  [[ "$w" =~ ^[1-9][0-9]*$ && "$h" =~ ^[1-9][0-9]*$ ]] || { echo "_plasma_virtual_output_add: not WxH: '$1'" >&2; return 2; }
  n=$(gcmd_plasma "i=2; while systemctl --user is-active -q $PLASMA_VOUT_UNIT-\$i; do i=\$((i + 1)); done; echo \$i" 10 | tr -d '[:space:]')
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "_plasma_virtual_output_add: the user manager named no free unit (got '$n')" >&2; return 1; }
  name="Virtual-rhizo-$n"
  out=$(gcmd_plasma "o=/tmp/$PLASMA_VOUT_UNIT-$n.out; rm -f \$o
systemd-run --user --unit=$PLASMA_VOUT_UNIT-$n --collect -p StandardOutput=truncate:\$o -p StandardError=truncate:\$o \
  -E WAYLAND_DISPLAY=\$WAYLAND_DISPLAY -- $PLASMA_VOUT_TOOL rhizo-$n $w $h >/dev/null 2>&1 || { echo 'systemd-run refused the unit'; exit 1; }
end=\$((\$(date +%s) + 10))
until grep -qx ok \$o 2>/dev/null; do
  grep -q '^err ' \$o 2>/dev/null && { cat \$o; exit 1; }
  [ \$(date +%s) -lt \$end ] || { echo \"no answer in 10s: \$(cat \$o 2>/dev/null)\"; exit 1; }
  sleep 0.2
done" 30) || { echo "_plasma_virtual_output_add: kde-virtual-output: $out" >&2; return 1; }
  end=$(( $(date +%s) + 15 ))
  until _plasma_harness "outputs list" 2>/dev/null | grep -q "\"name\": \"$name\""; do
    (( $(date +%s) < end )) || { echo "_plasma_virtual_output_add: kwin listed no $name within 15s" >&2; return 1; }
    sleep 0.5
  done
  out=$(_plasma_harness "outputs scale $name 1" 2>&1) \
    || { echo "_plasma_virtual_output_add: $name did not take scale 1: $out" >&2; return 1; }
  printf '%s\n' "$name"
}

# run an outputs command through plasma-harness.py
_desk_plasma_outputs() {
  local verb="$1"; shift
  case "$verb" in
    add)
      local out
      if [[ "$(_plasma_mode 2>/dev/null)" == login ]]; then
        out=$(_plasma_harness "outputs add $1" 2>&1) && { printf '%s\n' "$out"; return 0; }
        [[ "$out" == *"no disabled output has that mode"* ]] || { printf '%s\n' "$out" >&2; return 1; }
        _plasma_virtual_output_add "$1"
      else
        _plasma_harness "outputs add $1"
      fi ;;
    remove)
      if [[ "$1" == Virtual-rhizo-* ]]; then
        gcmd_plasma "systemctl --user stop $PLASMA_VOUT_UNIT-${1#Virtual-rhizo-}" 20 || return 1
      else
        _plasma_harness "outputs remove $1"
      fi ;;
    scale) _plasma_harness "outputs scale $1 $2" ;;
    list) _plasma_harness "outputs list" ;;
    *) echo "_desk_plasma_outputs: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# list the seat input devices
_desk_plasma_seat_devices() { _plasma_harness "seat-devices" "${1:-20}"; }

# set the keyboard layout through start-plasma.sh
_desk_plasma_keyboard_layout() {
  [[ "${1:-}" =~ ^[a-z]{2,8}$ ]] || { echo "_desk_plasma_keyboard_layout: want an xkb layout code, got '${1:-}'" >&2; return 2; }
  "$_PLASMA_LIB_DIR/../../vm/start/start-plasma.sh" --set-layout "$1"
}

# stop the launcher units
_plasma_launcher_stop() {
  gcmd_plasma "systemctl --user stop 'rhizo-launcher-*' || exit 1
left=\$(systemctl --user list-units --state=active,activating,deactivating,reloading --no-legend --plain 'rhizo-launcher-*') \
  || { echo 'systemctl --user list-units did not answer'; exit 1; }
[ -z \"\$left\" ] || { echo \"a launcher unit still runs: \$left\"; exit 1; }
rm -f /tmp/rhizo-plasma-launcher-*.out" 30
}

PLASMA_FOCUS_SAVED=/tmp/rhizo-plasma-focus-stealing.saved
# set kwin's focus-stealing prevention to medium, saving the user's value once
_plasma_focus_medium() {
  gcmd_plasma "if [ ! -e $PLASMA_FOCUS_SAVED ]; then
  v=\$(kreadconfig6 --file kwinrc --group Windows --key FocusStealingPreventionLevel) || exit 1
  printf '%s\n' \"\$v\" > $PLASMA_FOCUS_SAVED || exit 1
fi
kwriteconfig6 --file kwinrc --group Windows --key FocusStealingPreventionLevel 2 \\
  && busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure" 15
}
# restore the saved focus-stealing prevention level
_plasma_focus_restore() {
  gcmd_plasma "[ -e $PLASMA_FOCUS_SAVED ] || exit 0
v=\$(cat $PLASMA_FOCUS_SAVED)
if [ -n \"\$v\" ]; then kwriteconfig6 --file kwinrc --group Windows --key FocusStealingPreventionLevel \"\$v\"
else kwriteconfig6 --file kwinrc --group Windows --key FocusStealingPreventionLevel --delete; fi \\
  && busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure && rm -f $PLASMA_FOCUS_SAVED" 15
}

# launch a desktop entry through the launcher window
_desk_plasma_launch_entry() {
  local entry="$1" mode="${2:-}" nonce out wins win id x y w h end line why
  if [[ "$entry" == "done" ]]; then
    why=$(_plasma_launcher_stop) || { echo "$why"; return 1; }
    _plasma_focus_restore >/dev/null || { echo "kwin's focus stealing prevention was not put back"; return 1; }
    return 0
  fi
  [[ "$entry" =~ ^/[A-Za-z0-9_./-]+\.desktop$ ]] || { echo "not a desktop entry path the launcher can take: $entry"; return 1; }
  [[ -z "$mode" || "$mode" == --no-token ]] || { echo "_desk_plasma_launch_entry: want --no-token or nothing, got '$mode'"; return 2; }
  why=$(_plasma_launcher_stop) || { echo "an earlier launcher would not stop: $why"; return 1; }
  _plasma_focus_medium >/dev/null || { echo "kwin's focus stealing prevention could not be set to Medium"; return 1; }
  nonce="$(date +%s%N)$RANDOM"
  out="/tmp/rhizo-plasma-launcher-$nonce.out"
  why=$(gcmd_plasma "systemd-run --user --unit=rhizo-launcher-$nonce --collect -p KillMode=process \
  -E WAYLAND_DISPLAY=\$WAYLAND_DISPLAY -p StandardOutput=truncate:$out -p StandardError=truncate:$out \
  -- python3 $PLASMA_HARNESS_DIR/gnome-launcher.py --nonce $nonce $mode $entry" 25 2>&1) \
    || { echo "the launcher unit did not start: $why"; return 1; }
  end=$(( $(date +%s) + 30 ))
  until gcmd_plasma "grep -qax 'ready nonce=$nonce' $out" 10; do
    (( $(date +%s) < end )) || { echo "the launcher never said ready: $(gcmd_plasma "grep -av Warning $out | tail -3" 10 | tr '\n' ' ')"; return 1; }
    sleep 0.5
  done
  while :; do
    wins=$(desk_windows 2>/dev/null)
    win=$(python3 -c "
import json, sys
for l in sys.stdin:
    try:
        w = json.loads(l)
    except ValueError:
        continue
    if w.get('title') == sys.argv[1]:
        print(w['id'], w['x'], w['y'], w['w'], w['h'])
        break
" "rhizo-harness-launcher-$nonce" <<<"$wins")
    [[ -n "$win" ]] && break
    (( $(date +%s) < end )) || { echo "the launcher's window rhizo-harness-launcher-$nonce never mapped"; return 1; }
    sleep 0.5
  done
  read -r id x y w h <<<"$win"
  desk_window_op "$id" activate >/dev/null 2>&1 || { echo "raising the launcher's window $id failed"; return 1; }
  _plasma_harness "window-op $id above" >/dev/null || { echo "keeping the launcher's window $id above failed"; return 1; }
  why=$(_plasma_inject "move $(( x + w / 2 - 20 )) $(( y + h / 2 ))" "move $(( x + w / 2 )) $(( y + h / 2 ))" \
    "button 272 1" "button 272 0" 2>&1) || { echo "clicking the launcher: $why"; return 1; }
  end=$(( $(date +%s) + 30 ))
  until line=$(gcmd_plasma "grep -a -m1 -E '^(launched|launch-failed) nonce=$nonce ' $out" 10); [[ -n "$line" ]]; do
    (( $(date +%s) < end )) || { echo "the launcher printed no launch line within 30s of the click"; return 1; }
    sleep 0.5
  done
  line="${line/ nonce=$nonce/}"
  echo "$line"
  [[ "$line" == "launched token="* ]]
}

# list or activate notifications
_desk_plasma_notifications() {
  local verb="$1"; shift
  local mode
  mode=$(_plasma_mode) || return 1
  if [[ "$mode" == login ]]; then
    local run="systemctl --user is-active -q $PLASMA_WATCH_UNIT \
  || { echo 'the notification watcher $PLASMA_WATCH_UNIT is not running: desk_session_up --stage-login starts it' >&2; exit 1; }
python3 $PLASMA_HARNESS_DIR/plasma-harness.py notifications"
    case "$verb" in
      list) gcmd_plasma "$run list --record $PLASMA_NOTIFY_REC" 20 ;;
      activate)
        [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "_desk_plasma_notifications activate: want a notification id, got '${1:-}'" >&2; return 2; }
        [[ "${2:-default}" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "_desk_plasma_notifications activate: not an action key: '${2:-}'" >&2; return 2; }
        gcmd_plasma "$run activate $1 ${2:-default} --record $PLASMA_NOTIFY_REC" 30 ;;
      *) echo "_desk_plasma_notifications: unknown verb '$verb'" >&2; return 2 ;;
    esac
    return
  fi
  declare -F notify_sink_start >/dev/null 2>&1 \
    || { echo "_desk_plasma_notifications: desktop-assert-lib.sh is not sourced" >&2; return 2; }
  local running; running=$(gcmd_user "pgrep -f 'rhizo-notify-[s]ink' | head -1" 10 | tr -d '[:space:]')
  [[ -n "$running" ]] || notify_sink_start || return 1
  case "$verb" in
    list)
      gcmd_user "cat $NOTIF_REC 2>/dev/null" 10 | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    hints = rec.get('hints') or {}
    icon = hints.get('image-path', '')
    print(json.dumps({
        'id': str(rec.get('id', '')),
        'source': hints.get('desktop-entry', rec.get('app_name', '')),
        'title': rec.get('summary', ''),
        'body': rec.get('body', ''),
        'has_default_action': 'default' in (rec.get('actions') or [])[0::2],
        'icon': icon if isinstance(icon, str) else '',
    }))
"
      ;;
    activate)
      local key="${2:-default}" declared
      declared=$(gcmd_user "cat $NOTIF_REC 2>/dev/null" 10 | python3 -c "
import json, sys
want, keys = sys.argv[1], None
for line in sys.stdin:
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if str(rec.get('id', '')) == want:
        keys = (rec.get('actions') or [])[0::2]
if keys is None:
    sys.exit(1)
print(' '.join(keys))
" "$1") || { echo "_desk_plasma_notifications: the sink recorded no notification $1" >&2; return 1; }
      [[ " $declared " == *" $key "* ]] \
        || { echo "_desk_plasma_notifications: notification $1 declares no action '$key' (declared: ${declared:-none})" >&2; return 1; }
      notify_invoke_action "$1" "$key" ;;
    *) echo "_desk_plasma_notifications: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# send a pointer drag from source to destination
_desk_plasma_dnd_fixture() {
  _plasma_inject "move $1 $2" "button 272 1" "move $3 $4" "button 272 0"
}

# shellcheck disable=SC2034
CLIP_BRIDGE_CAPS="clipboard,drag"
# shellcheck disable=SC2034
CLIP_BRIDGE_EXTRA="--pad xdg"

# print the pad window line
_plasma_pad_window() {
  local deadline=$(( $(date +%s) + ${1:-15} )) line
  while (( $(date +%s) <= deadline )); do
    line=$(desk_windows 2>/dev/null | grep -F '"app_id": "rhizo-dragpad"' | head -1)
    [[ -n "$line" ]] && { printf '%s' "$line"; return 0; }
    sleep 1
  done
  return 1
}

# map the pad window and print its id
_plasma_pad_up() {
  local running since ack win id
  running=$(gcmd_user "pgrep -f 'rhizo-wlbridge-[t]est' | head -1" 10 | tr -d '[:space:]')
  [[ -n "$running" ]] || clip_start >/dev/null || { echo "the system test's own client did not start"; return 1; }
  if ! win=$(_plasma_pad_window 0); then
    since=$(clip_mark) || { echo "the system test's own client's output could not be read"; return 1; }
    clipcmd "dragpad on"
    ack=$(clip_await '^padmapped$' "$since" 15) || { echo "the pad never mapped: ${ack:-no answer within 15s}"; return 1; }
    win=$(_plasma_pad_window 15) || { echo "the pad mapped but kwin lists no rhizo-dragpad window"; return 1; }
  fi
  id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$win")
  _plasma_harness "window-op $id above" >/dev/null || { echo "the pad could not be kept above ($id)"; return 1; }
  _plasma_harness "window-op $id move 16 16" >/dev/null || { echo "the pad could not be moved to 16,16 ($id)"; return 1; }
  printf '%s' "$id"
}

# run a clipboard verb on kwin
_desk_plasma_clipboard() {
  local verb="$1"; shift
  declare -F clip_start >/dev/null 2>&1 \
    || { echo "_desk_plasma_clipboard: desktop-assert-lib.sh is not sourced" >&2; return 2; }
  local running; running=$(gcmd_user "pgrep -f 'rhizo-wlbridge-[t]est' | head -1" 10 | tr -d '[:space:]')
  [[ -n "$running" ]] || clip_start || return 1
  case "$verb" in
    set)
      clipcmd "set $1 $2"
      local why; why=$(desktop_focus_rhizo_window) || { echo "_desk_plasma_clipboard set: $why" >&2; return 1; }
      ;;
    mark) clip_mark ;;
    get) clip_wait_data "$1" "${2:-30}" "${3:-}" ;;
    focus-rhizo) desktop_focus_rhizo_window ;;
    *) echo "_desk_plasma_clipboard: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# run a drag and drop verb on kwin
_desk_plasma_dnd() {
  local verb="$1"; shift
  local pad why win since ack
  case "$verb" in
    pad)
      case "$1" in
        on)
          pad=$(_plasma_pad_up) || { echo "$pad"; return 1; }
          why=$(_plasma_inject "" 2>&1) || { echo "$why"; return 1; }
          ;;
        off)
          desktop_focus_rhizo_window >/dev/null 2>&1
          clipcmd "dragpad off"
          ;;
        *) echo "_desk_plasma_dnd pad: want on or off, got '$1'"; return 2 ;;
      esac
      ;;
    pad-point)
      win=$(_plasma_pad_window 15) || { echo "the pad is not mapped"; return 1; }
      python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['x'] + d['w'] // 2, d['y'] + d['h'] // 2)" "$win"
      ;;
    press) why=$(_plasma_inject "move $1 $2" "button 272 1" 2>&1) || { echo "$why"; return 1; } ;;
    moveto) why=$(_plasma_inject "move $1 $2" 2>&1) || { echo "$why"; return 1; } ;;
    release) why=$(_plasma_inject "button 272 0" 2>&1) || { echo "$why"; return 1; } ;;
    drop)
      local x="$1" y="$2" mime="$3" b64="$4" point
      point=$(_desk_plasma_dnd pad-point) || { echo "$point"; return 1; }
      since=$(clip_mark) || { echo "the system test's own client's output could not be read"; return 1; }
      clipcmd "dragarm $mime $b64"
      ack=$(clip_await "^dragarmed $mime\$" "$since" 15) || { echo "the pad never armed: ${ack:-no answer within 15s}"; return 1; }
      why=$(_plasma_inject "move $point" "button 272 1" 2>&1) || { echo "pressing the pad at $point: $why"; return 1; }
      ack=$(clip_await "^dragstarted $mime\$" "$since" 15) \
        || { _plasma_inject "button 272 0" >/dev/null 2>&1; echo "the press on the pad started no drag: ${ack:-no answer within 15s}"; return 1; }
      why=$(_plasma_inject "move $x $y" 2>&1) \
        || { _plasma_inject "button 272 0" >/dev/null 2>&1; echo "carrying the drag to $x,$y: $why"; return 1; }
      ack=$(clip_await "^dragtarget $mime\$" "$since" 15) \
        || { _plasma_inject "button 272 0" >/dev/null 2>&1; echo "the window at $x,$y never accepted the drag: ${ack:-no answer within 15s}"; return 1; }
      why=$(_plasma_inject "button 272 0" 2>&1) || { echo "releasing the drag: $why"; return 1; }
      ;;
    *) echo "_desk_plasma_dnd: unknown verb '$verb'"; return 2 ;;
  esac
}
