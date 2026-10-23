#!/bin/bash
# implement the desk_* functions for GNOME

_GNOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/desk-user-lib.sh"

GNOME_HARNESS_DIR="/tmp/rhizo-gnome-harness"

# run a command in the guest as the session user
gcmd_gnome() { desk_user_sh "${2:-20}" "$1"; }

# run a command in the guest as root
gcmd_root() { ssh_vm -t "${2:-20}" "$1"; }
# run a command as the session user
gcmd_user() {
  gcmd_gnome '_wd=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E "^wayland-[0-9]+$" | head -1)
[ -n "$_wd" ] && export WAYLAND_DISPLAY="$_wd"
'"$1" "${2:-20}"
}
# poll a guest test command as the session user until it succeeds
wait_guest() {
  local deadline_s="$1" test_cmd="$2" start
  start=$(date +%s)
  while true; do
    if gcmd_user "$test_cmd" >/dev/null 2>&1; then return 0; fi
    if (( $(date +%s) - start > deadline_s )); then return 1; fi
    sleep 1
  done
}

# run gnome-harness.py as the session user
_gnome_harness() {
  gcmd_gnome "python3 $GNOME_HARNESS_DIR/gnome-harness.py $1" "${2:-20}"
}

# start the gnome-shell session with optional user, layout and monitors
_desk_gnome_session_up() {
  local user="" layout="" monitors=""
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage-login) args+=(--stage-login); shift ;;
      --user) user="$2"; shift 2 ;;
      --layout) layout="$2"; shift 2 ;;
      --monitors) monitors="$2"; shift 2 ;;
      *) echo "_desk_gnome_session_up: unknown argument $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$layout" ]] && args+=(--xkb-layout "$layout")
  [[ -n "$user" ]] && args+=(--user "$user")
  [[ -n "$monitors" ]] && args+=(--size "$monitors")
  "$_GNOME_LIB_DIR/../../vm/start/start-gnome.sh" "${args[@]}"
}

# stop the gnome-shell session
_desk_gnome_session_down() { "$_GNOME_LIB_DIR/../../vm/start/start-gnome.sh" --stop; }

# print the session environment
_desk_gnome_env() {
  gcmd_gnome '_wd=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E "^wayland-[0-9]+$" | head -1)
echo "WAYLAND_DISPLAY=$_wd"; echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"; echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"; echo "RHIZO_DESK_UID=$(id -u)"' 15
}

# print the path of the gnome-shell wayland socket
_desk_gnome_socket_path() {
  gcmd_gnome '_wd=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -E "^wayland-[0-9]+$" | head -1)
[ -n "$_wd" ] && echo "$XDG_RUNTIME_DIR/$_wd"' 15
}

# capture a screenshot with gnome-harness.py
_desk_gnome_shot() {
  local out="$1" region="${2:-}" output="${3:-}"
  local shot_args="$out"
  if [[ -n "$region" ]]; then
    local x y w h
    IFS=',' read -r x y w h <<<"$region"
    shot_args="$shot_args $x $y $w $h"
  fi
  [[ -n "$output" ]] && shot_args="$shot_args --output $output"
  _gnome_harness "shot $shot_args" 25
}

# inject a pointer event through gnome-harness.py
_desk_gnome_inject_pointer() {
  local verb="$1"; shift
  case "$verb" in
    abs) _gnome_harness "pointer abs $1 $2" ;;
    btn)
      _gnome_pointer_up || return 1
      _gnome_pointer "btn $1 $2" "^button $1 $2\$" ;;
    axis)
      case "$1" in
        h|v) _gnome_harness "pointer axis $1 $2" ;;
        *) echo "_desk_gnome_inject_pointer axis: want h or v, got '$1'" >&2; return 2 ;;
      esac
      ;;
    axis_discrete)
      case "$1" in
        h|v) _gnome_harness "pointer axis-discrete $1 $2" ;;
        *) echo "_desk_gnome_inject_pointer axis_discrete: want h or v, got '$1'" >&2; return 2 ;;
      esac
      ;;
    *) echo "_desk_gnome_inject_pointer: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# inject a single key event
_desk_gnome_inject_key() {
  _gnome_pointer_up || return 1
  _gnome_pointer "key $1 $2" "^key $1 $2\$"
}

# list the toplevel windows
_desk_gnome_windows() { _gnome_harness "windows" "${1:-20}"; }

# run an operation on a window
_desk_gnome_window_op() {
  local id="$1" op="$2"; shift 2
  local extra=""
  case "$op" in
    move|resize) extra="$1 $2" ;;
    to_monitor) extra="$1" ;;
    fullscreen|unfullscreen|maximize|unmaximize|activate|close) ;;
    *) echo "_desk_gnome_window_op: unknown op '$op'" >&2; return 2 ;;
  esac
  _gnome_harness "window-op $id $op $extra"
}

# add, remove, scale or list the outputs
_desk_gnome_outputs() {
  local verb="$1"; shift
  case "$verb" in
    add) _gnome_harness "outputs add $1" 60 ;;
    remove) _gnome_harness "outputs remove $1" 30 ;;
    scale) _gnome_harness "outputs scale $1 $2" ;;
    list) _gnome_harness "outputs list" ;;
    *) echo "_desk_gnome_outputs: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# list the seat's input devices
_desk_gnome_seat_devices() { _gnome_harness "seat-devices" "${1:-20}"; }

# apply an input source through mutter
_desk_gnome_keyboard_layout() {
  [[ "${1:-}" =~ ^[a-z]{2,8}$ ]] || { echo "_desk_gnome_keyboard_layout: want an xkb layout code, got '${1:-}'" >&2; return 2; }
  gcmd_gnome "gsettings set org.gnome.desktop.input-sources sources \"[('xkb', '$1')]\"" 20
}

# stop all of the launchers this harness started
_gnome_launcher_stop() {
  gcmd_user "pat='^python3 $GNOME_HARNESS_DIR/gnome-launcher[.]py( |\$)'"'
pids=$(pgrep -f "$pat")
for sig in TERM KILL; do
  [ -n "$pids" ] || break
  kill -s $sig $pids 2>/dev/null
  for p in $pids; do timeout 10 tail --pid="$p" -f /dev/null; done
  pids=$(pgrep -f "$pat")
done
rm -f /tmp/rhizo-gnome-launcher-*.out
[ -z "$pids" ] || { echo "a launcher still runs after KILL: $pids"; exit 1; }' 30
}

GNOME_FOCUS_SAVED=/tmp/rhizo-gnome-focus-new-windows.saved
# set focus-new-windows to strict, saving the user's value once
_gnome_focus_strict() {
  gcmd_user "k='org.gnome.desktop.wm.preferences focus-new-windows'
if [ ! -s $GNOME_FOCUS_SAVED ]; then
  v=\$(gsettings get \$k) || exit 1
  printf '%s\n' \"\$v\" | tr -d \"'\" > $GNOME_FOCUS_SAVED
  [ -s $GNOME_FOCUS_SAVED ] || exit 1
fi
gsettings set \$k strict" 15
}
# restore the saved focus-new-windows value
_gnome_focus_restore() {
  gcmd_user "[ -s $GNOME_FOCUS_SAVED ] || exit 0
gsettings set org.gnome.desktop.wm.preferences focus-new-windows \"\$(cat $GNOME_FOCUS_SAVED)\" && rm -f $GNOME_FOCUS_SAVED" 15
}

# launch an entry by clicking gnome-launcher.py
_desk_gnome_launch_entry() {
  local entry="$1" mode="${2:-}" nonce out wins win id x y w h deadline line why
  if [[ "$entry" == "done" ]]; then
    why=$(_gnome_launcher_stop) || { echo "$why"; return 1; }
    _gnome_focus_restore >/dev/null || { echo "mutter's focus-new-windows was not put back"; return 1; }
    return 0
  fi
  [[ "$entry" =~ ^/[A-Za-z0-9_./-]+\.desktop$ ]] || { echo "not a desktop entry path the launcher can take: $entry"; return 1; }
  [[ -z "$mode" || "$mode" == --no-token ]] || { echo "_desk_gnome_launch_entry: want --no-token or nothing, got '$mode'"; return 2; }
  why=$(_gnome_launcher_stop) || { echo "an earlier launcher would not stop: $why"; return 1; }
  _gnome_focus_strict >/dev/null || { echo "mutter's focus-new-windows could not be set to strict"; return 1; }
  nonce="$(date +%s%N)$RANDOM"
  out="/tmp/rhizo-gnome-launcher-$nonce.out"
  gcmd_user "setsid sh -c 'python3 $GNOME_HARNESS_DIR/gnome-launcher.py --nonce $nonce $mode $entry > $out 2>&1' >/dev/null 2>&1 </dev/null & disown
true" 25 >/dev/null
  deadline=$(( $(date +%s) + 30 ))
  until gcmd_user "grep -qx 'ready nonce=$nonce' $out" 10; do
    (( $(date +%s) < deadline )) || { echo "the launcher never said ready: $(gcmd_user "tail -3 $out" 10 | tr '\n' ' ')"; return 1; }
    sleep 1
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
    (( $(date +%s) < deadline )) || { echo "the launcher's window rhizo-harness-launcher-$nonce never mapped"; return 1; }
    sleep 1
  done
  read -r id x y w h <<<"$win"
  desk_window_op "$id" activate >/dev/null 2>&1 || { echo "raising the launcher's window $id failed"; return 1; }
  _gnome_harness "window-op $id above" >/dev/null || { echo "keeping the launcher's window $id above failed"; return 1; }
  why=$(_gnome_pointer_up) || { echo "$why"; return 1; }
  why=$(_gnome_pointer "press $(( x + w / 2 )) $(( y + h / 2 ))" "^pressed ") || { echo "pressing the launcher: $why"; return 1; }
  why=$(_gnome_pointer "release" '^released$') || { echo "releasing on the launcher: $why"; return 1; }
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    line=$(gcmd_user "grep -m1 -E '^(launched|launch-failed) nonce=$nonce ' $out" 10)
    [[ -n "$line" ]] && break
    sleep 1
  done
  [[ -n "$line" ]] || { echo "the launcher printed no launch line within 30s of the click"; return 1; }
  line="${line/ nonce=$nonce/}"
  echo "$line"
  [[ "$line" == "launched token="* ]]
}

# list or activate notifications through the extension's tray API
_desk_gnome_notifications() {
  local verb="$1"; shift
  case "$verb" in
    list) _gnome_harness "notifications list" ;;
    activate) _gnome_harness "notifications activate $1 ${2:-default}" ;;
    *) echo "_desk_gnome_notifications: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# drag in a pointer session
_desk_gnome_dnd_fixture() {
  local sx="$1" sy="$2" dx="$3" dy="$4"
  _gnome_harness "pointer drag $sx $sy $dx $dy"
}

# shellcheck disable=SC2034
CLIP_BRIDGE_CAPS="clipboard,drag"
# shellcheck disable=SC2034
CLIP_BRIDGE_EXTRA="--pad xdg --selection pad"
GNOME_POINTER_FIFO=/tmp/rhizo-gnome-pointer.fifo
GNOME_POINTER_OUT=/tmp/rhizo-gnome-pointer.out

# start gnome-harness.py's pointer session
_gnome_pointer_up() {
  local running
  running=$(gcmd_gnome "pgrep -f 'gnome-harness.py [p]ointer-session' | head -1" 10 | tr -d '[:space:]')
  [[ -n "$running" ]] && return 0
  gcmd_gnome "rm -f $GNOME_POINTER_FIFO $GNOME_POINTER_OUT && mkfifo $GNOME_POINTER_FIFO
setsid sh -c 'sleep 86400 > $GNOME_POINTER_FIFO' >/dev/null 2>&1 </dev/null & disown
setsid sh -c 'python3 $GNOME_HARNESS_DIR/gnome-harness.py pointer-session < $GNOME_POINTER_FIFO > $GNOME_POINTER_OUT 2>&1' >/dev/null 2>&1 </dev/null & disown
true" 25
  local deadline=$(( $(date +%s) + 20 ))
  while (( $(date +%s) <= deadline )); do
    gcmd_gnome "grep -qx ready $GNOME_POINTER_OUT" 10 && return 0
    sleep 1
  done
  echo "the pointer session never said ready: $(gcmd_gnome "tail -3 $GNOME_POINTER_OUT" 10 | tr '\n' ' ')"
  return 1
}

# send a pointer-session command and print its answer
_gnome_pointer() {
  local cmd="$1" want="$2" since deadline new hit
  since=$(gcmd_gnome "wc -l < $GNOME_POINTER_OUT" 10 | tr -d '[:space:]')
  [[ "$since" =~ ^[0-9]+$ ]] || { echo "the pointer session's output could not be read"; return 1; }
  gcmd_gnome "echo '$cmd' > $GNOME_POINTER_FIFO" 10
  deadline=$(( $(date +%s) + 20 ))
  while (( $(date +%s) <= deadline )); do
    new=$(gcmd_gnome "tail -n +$(( since + 1 )) $GNOME_POINTER_OUT" 10)
    hit=$(grep -a -E -m1 "$want" <<<"$new") && return 0
    hit=$(grep -a -m1 '^error ' <<<"$new") && { echo "$hit"; return 1; }
    sleep 1
  done
  echo "the pointer session never answered '$cmd' within 20s"
  return 1
}

# print the test pad's desk_windows line once mapped
_gnome_pad_window() {
  local deadline=$(( $(date +%s) + ${1:-15} )) line
  while (( $(date +%s) <= deadline )); do
    line=$(desk_windows 2>/dev/null | grep -F '"app_id": "rhizo-dragpad"' | head -1)
    [[ -n "$line" ]] && { printf '%s' "$line"; return 0; }
    sleep 1
  done
  return 1
}

# run the test client and print the pad's window id
_gnome_pad_up() {
  local running since ack win id
  running=$(gcmd_user "pgrep -f 'rhizo-wlbridge-[t]est' | head -1" 10 | tr -d '[:space:]')
  [[ -n "$running" ]] || clip_start >/dev/null || { echo "the system test's own client did not start"; return 1; }
  if ! win=$(_gnome_pad_window 0); then
    since=$(clip_mark) || { echo "the system test's own client's output could not be read"; return 1; }
    clipcmd "dragpad on"
    ack=$(clip_await '^padmapped$' "$since" 15) || { echo "the pad never mapped: ${ack:-no answer within 15s}"; return 1; }
    win=$(_gnome_pad_window 15) || { echo "the pad mapped but mutter lists no rhizo-dragpad window"; return 1; }
  fi
  id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['id'])" "$win")
  _gnome_harness "window-op $id above" >/dev/null || { echo "the pad could not be kept above ($id)"; return 1; }
  printf '%s' "$id"
}

# focus the pad and confirm its focus line
_gnome_pad_focus() {
  local since ack last
  last=$(gcmd_user "grep -a -E '^focus (pad|away)\$' /tmp/rhizo-clip.out 2>/dev/null | tail -1" 10)
  [[ "$last" == "focus pad" ]] && return 0
  since=$(clip_mark) || { echo "the system test's own client's output could not be read"; return 1; }
  desk_window_op "$1" activate >/dev/null 2>&1 || { echo "activating the pad ($1) failed"; return 1; }
  ack=$(clip_await '^focus pad$' "$since" 15) || { echo "the pad never got keyboard focus: ${ack:-no answer within 15s}"; return 1; }
}

# print the selection line that offers these mimes
_gnome_await_selection() {
  local since="$1" want deadline=$(( $(date +%s) + $3 )) new line
  want=$(tr ',' '\n' <<<"$2" | sort | tr '\n' ' ')
  while (( $(date +%s) <= deadline )); do
    new=$(gcmd_user "tail -n +$(( since + 1 )) /tmp/rhizo-clip.out 2>/dev/null" 10)
    while IFS= read -r line; do
      [[ "$line" == "error "* ]] && { printf '%s' "$line"; return 2; }
      [[ "$line" == "selection "* ]] || continue
      [[ "$(tr ' ' '\n' <<<"${line#selection }" | sort | tr '\n' ' ')" == "$want" ]] \
        && { printf '%s' "$line"; return 0; }
    done <<<"$new"
    sleep 1
  done
  return 1
}

# drive the host end of a clipboard leg through the pad
_desk_gnome_clipboard() {
  local verb="$1"; shift
  case "$verb" in
    mark) echo "-"; return 0 ;;
    set|get|focus-rhizo) ;;
    *) echo "_desk_gnome_clipboard: unknown verb '$verb'" >&2; return 2 ;;
  esac
  local pad why
  pad=$(_gnome_pad_up) || { echo "_desk_gnome_clipboard $verb: $pad" >&2; return 1; }
  why=$(_gnome_pad_focus "$pad") || { echo "_desk_gnome_clipboard $verb: $why" >&2; return 1; }
  local since ack rc=0
  if [[ "$verb" == focus-rhizo ]]; then
    :
  elif [[ "$verb" == set ]]; then
    local mimes="$1" b64="$2"
    since=$(clip_mark) || { echo "_desk_gnome_clipboard set: the client's output could not be read" >&2; return 1; }
    clipcmd "set $mimes $b64"
    ack=$(_gnome_await_selection "$since" "$mimes" 15) \
      || { echo "_desk_gnome_clipboard set: mutter never took the pad's selection: ${ack:-no answer within 15s}" >&2; rc=1; }
  else
    local mime="$1" deadline=$(( $(date +%s) + ${2:-30} )) got=""
    while (( $(date +%s) <= deadline )); do
      since=$(clip_mark) || break
      clipcmd "get $mime"
      ack=$(clip_await "^(data|nodata) $mime( |\$)" "$since" 15)
      if [[ "$ack" == "data $mime "* ]]; then got="${ack#data $mime }"; break; fi
      sleep 1
    done
    [[ -n "$got" ]] && printf '%s' "$got" || rc=1
  fi
  why=$(desktop_focus_rhizo_window) || { echo "_desk_gnome_clipboard $verb: $why" >&2; rc=1; }
  return $rc
}

# drive desk_dnd on GNOME through the pad
_desk_gnome_dnd() {
  local verb="$1"; shift
  local pad why win since ack
  case "$verb" in
    pad)
      case "$1" in
        on)
          pad=$(_gnome_pad_up) || { echo "$pad"; return 1; }
          _gnome_pointer_up || return 1
          ;;
        off)
          desktop_focus_rhizo_window >/dev/null 2>&1
          clipcmd "dragpad off"
          ;;
        *) echo "_desk_gnome_dnd pad: want on or off, got '$1'"; return 2 ;;
      esac
      ;;
    pad-point)
      win=$(_gnome_pad_window 15) || { echo "the pad is not mapped"; return 1; }
      python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['x'] + d['w'] // 2, d['y'] + d['h'] // 2)" "$win"
      ;;
    press) _gnome_pointer "press $1 $2" "^pressed $1 $2\$" ;;
    moveto) _gnome_pointer "moveto $1 $2" "^movedto $1 $2\$" ;;
    release) _gnome_pointer "release" '^released$' ;;
    drop)
      local x="$1" y="$2" mime="$3" b64="$4" point
      point=$(_desk_gnome_dnd pad-point) || { echo "$point"; return 1; }
      since=$(clip_mark) || { echo "the system test's own client's output could not be read"; return 1; }
      clipcmd "dragarm $mime $b64"
      ack=$(clip_await "^dragarmed $mime\$" "$since" 15) || { echo "the pad never armed: ${ack:-no answer within 15s}"; return 1; }
      why=$(_gnome_pointer "press $point" "^pressed $point\$") || { echo "pressing the pad at $point: $why"; return 1; }
      ack=$(clip_await "^dragstarted $mime\$" "$since" 15) \
        || { _gnome_pointer release '^released$' >/dev/null; echo "the press on the pad started no drag: ${ack:-no answer within 15s}"; return 1; }
      why=$(_gnome_pointer "moveto $x $y" "^movedto $x $y\$") \
        || { _gnome_pointer release '^released$' >/dev/null; echo "carrying the drag to $x,$y: $why"; return 1; }
      ack=$(clip_await "^dragtarget $mime\$" "$since" 15) \
        || { _gnome_pointer release '^released$' >/dev/null; echo "the window at $x,$y never accepted the drag: ${ack:-no answer within 15s}"; return 1; }
      _gnome_pointer release '^released$'
      ;;
    *) echo "_desk_gnome_dnd: unknown verb '$verb'"; return 2 ;;
  esac
}
