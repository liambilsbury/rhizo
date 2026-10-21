#!/bin/bash
# define the desk_* verbs that drive a desktop profile
_DESKTOP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_DESKTOP_LIB_DIR/desk-user-lib.sh"

RHIZO_DESKTOP_PROFILE="${RHIZO_DESKTOP_PROFILE:-sway}"

DESKTOP_VERBS=(desk_session_up desk_session_down desk_socket_path desk_env
               desk_shot desk_inject_pointer desk_inject_key desk_windows
               desk_window_op desk_outputs desk_seat_devices desk_keyboard_layout
               desk_notifications desk_dnd_fixture desk_clipboard desk_dnd
               desk_launch_entry)

case "$RHIZO_DESKTOP_PROFILE" in
  sway)
    source "$_DESKTOP_LIB_DIR/sway-lib.sh"
    ;;
  server)
    :
    ;;
  gnome)
    if [[ -r "$_DESKTOP_LIB_DIR/gnome-lib.sh" ]]; then
      source "$_DESKTOP_LIB_DIR/gnome-lib.sh"
    else
      echo "desktop-lib.sh: RHIZO_DESKTOP_PROFILE=gnome but $_DESKTOP_LIB_DIR/gnome-lib.sh does not exist yet" >&2
      return 1 2>/dev/null || exit 1
    fi
    ;;
  plasma)
    source "$_DESKTOP_LIB_DIR/plasma-lib.sh"
    ;;
  *)
    echo "desktop-lib.sh: unknown RHIZO_DESKTOP_PROFILE '$RHIZO_DESKTOP_PROFILE' (want sway, gnome, plasma or server)" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# call the active profile's _desk_<profile>_<fn>
_desk_dispatch() {
  local fn="$1"; shift
  local impl="_desk_${RHIZO_DESKTOP_PROFILE}_${fn}"
  if ! declare -F "$impl" >/dev/null; then
    echo "desktop-lib.sh: profile '$RHIZO_DESKTOP_PROFILE' does not implement $fn (wanted $impl)" >&2
    return 2
  fi
  "$impl" "$@" </dev/null
}

# start the desktop session
desk_session_up()     { _desk_dispatch session_up "$@"; }
# stop the desktop session
desk_session_down()   { _desk_dispatch session_down "$@"; }
# print the compositor socket path
desk_socket_path()    { _desk_dispatch socket_path "$@"; }
# print the compositor environment
# shellcheck disable=SC2120
desk_env()            { _desk_dispatch env "$@"; }
# capture a screenshot
desk_shot()           { _desk_dispatch shot "$@"; }
# inject a pointer event
desk_inject_pointer() { _desk_dispatch inject_pointer "$@"; }
# inject a key event
desk_inject_key()     { _desk_dispatch inject_key "$@"; }
# list the toplevel windows
# shellcheck disable=SC2120
desk_windows()        { _desk_dispatch windows "$@"; }
# run an operation on a window
desk_window_op()      { _desk_dispatch window_op "$@"; }
# list, add, remove or scale the outputs
desk_outputs()        { _desk_dispatch outputs "$@"; }
# list the seat's input devices
desk_seat_devices()   { _desk_dispatch seat_devices "$@"; }
# put all of the seat keyboards on an xkb layout now
desk_keyboard_layout() { _desk_dispatch keyboard_layout "$@"; }
# start a .desktop entry and print the launched token line
desk_launch_entry()   { _desk_dispatch launch_entry "$@"; }
# list or activate desktop notifications
desk_notifications()  { _desk_dispatch notifications "$@"; }
# set up the drag-and-drop fixture
desk_dnd_fixture()    { _desk_dispatch dnd_fixture "$@"; }
# drive the host side of a clipboard leg
desk_clipboard()      { _desk_dispatch clipboard "$@"; }
# drive the host end of a drag on the test client's pad
desk_dnd()            { _desk_dispatch dnd "$@"; }

# click the left button at a point
desktop_inject_click() {
  local x="$1" y="$2"
  desk_inject_pointer abs $(( x > 40 ? x - 37 : x + 37 )) $(( y > 40 ? y - 29 : y + 29 )) || return 1
  desk_inject_pointer abs "$x" "$y" || return 1
  desk_inject_pointer btn 272 1 || return 1
  desk_inject_pointer btn 272 0 || return 1
}

# print the x y w h of a display's window
desktop_window_rect() {
  local disp="$1" win
  win=$(_desktop_window_for_display "$disp" 0) || return 1
  python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['x'], d['y'], d['w'], d['h'])" "$win"
}

# print a display's window rect once mapped
desktop_mapped_window_rect() {
  local win outs rect
  win=$(_desktop_window_for_display "$1" "${2:-60}") || return 1
  rect=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['x'], d['y'], d['w'], d['h'])" "$win") || return 1
  outs=$(desk_outputs list) || { echo "the window at $rect has no layout to be on: the outputs did not read"; return 1; }
  python3 -c "
import json, sys
x, y, w, h = (int(v) for v in sys.argv[1].split())
cx, cy = x + w // 2, y + h // 2
try:
    outs = json.loads(sys.argv[2])
except ValueError:
    print('the window at %s has no layout to be on: the outputs did not read' % sys.argv[1]); sys.exit(1)
for o in outs:
    r = o.get('rect') or {}
    if o.get('active', True) and r.get('x', 0) <= cx < r.get('x', 0) + r.get('width', 0) \
            and r.get('y', 0) <= cy < r.get('y', 0) + r.get('height', 0):
        print(sys.argv[1]); sys.exit(0)
print('the window at %s has its center %d,%d on no active output (%s)' % (sys.argv[1], cx, cy,
      ', '.join('%s %sx%s at %s,%s' % (o.get('name'), (o.get('rect') or {}).get('width'), (o.get('rect') or {}).get('height'),
                (o.get('rect') or {}).get('x'), (o.get('rect') or {}).get('y')) for o in outs if o.get('active', True)) or 'none active'))
sys.exit(1)
" "$rect" "$outs"
}

# raise and activate a display's toplevel
desktop_activate_display_window() {
  local disp="$1" wins ids id n
  wins=$(_desktop_window_for_display "$disp" "${2:-60}" --all) || { echo "display $disp has no mapped window to activate"; return 1; }
  ids=$(python3 -c "
import json, sys
for l in sys.stdin:
    l = l.strip()
    if l:
        print(json.loads(l).get('id', ''))
" <<<"$wins")
  local -a idv
  mapfile -t idv < <(grep . <<<"$ids")
  n=${#idv[@]}
  (( n > 0 )) || { echo "display $disp's window carries no id to activate"; return 1; }
  for id in "${idv[@]}"; do
    desk_window_op "$id" activate >/dev/null 2>&1 </dev/null || { echo "activating display $disp's window $id failed"; return 1; }
    _display_toplevel_activated "$disp" </dev/null && return 0
  done
  echo "none of the $n windows carrying display $disp's app_id and title became its activated toplevel once raised"
  return 1
}

# wait for the composer to report the display toplevel activated
_display_toplevel_activated() {
  local disp="$1" init="${INIT:-}" before line deadline
  [[ -n "$init" ]] || return 1
  deadline=$(( $(date +%s) + 5 ))
  while :; do
    before=$(_dnd_ctl_lines "$init") || return 1
    rhizo_ctl "$init" display toplevel "$disp" >/dev/null 2>&1
    line=$(_dnd_ctl_read "$init" tail -n "+$(( before + 1 ))" /data/rhizo_control/control.out \
      | grep -m1 "^display toplevel id=$disp ")
    [[ "$line" == *" activated=1 "* ]] && return 0
    (( $(date +%s) < deadline )) || return 1
    sleep 0.5
  done
}

# give a Rhizo toplevel keyboard focus
desktop_focus_rhizo_window() {
  local w id
  w=$(desk_windows) || { echo "desk_windows failed"; return 1; }
  id=$(RHIZO_WANT_APP="rhizo-${APP_PKG:-}" python3 -c "
import json, os, sys
want = os.environ['RHIZO_WANT_APP']
wins = []
for l in sys.stdin:
    l = l.strip()
    if not l:
        continue
    try:
        wins.append(json.loads(l))
    except ValueError:
        continue
def rhizo(w):
    app = w.get('app_id') or ''
    return (app == 'rhizo' or app.startswith('rhizo-')) and app != 'rhizo-dragpad'
mapped = [w for w in wins if rhizo(w) and w.get('w', 0) > 0 and w.get('h', 0) > 0]
pick = [w for w in mapped if w.get('app_id') == want] or mapped
print(pick[0]['id'] if pick else '')
" <<<"$w")
  [[ -n "$id" ]] || { echo "no Rhizo window is mapped to take focus"; return 1; }
  desk_window_op "$id" activate >/dev/null 2>&1 || { echo "activating Rhizo window $id failed"; return 1; }
}

DESKTOP_FOCUS_HOLDER_APP=rhizo-focus-holder
# start the focus-holder window and activate it
desktop_focus_holder_up() {
  local env wd deadline id=""
  env=$(desk_env 2>/dev/null)
  wd=$(grep -o 'WAYLAND_DISPLAY=[^[:space:]]*' <<<"$env" | cut -d= -f2)
  [[ -n "$wd" ]] || { echo "desk_env named no WAYLAND_DISPLAY to start the focus holder on"; return 1; }
  desk_user_sh 20 "systemctl --user is-active -q $DESKTOP_FOCUS_HOLDER_APP.service || { systemctl --user reset-failed $DESKTOP_FOCUS_HOLDER_APP.service 2>/dev/null; systemd-run --user --collect --unit=rhizo-focus-holder -E WAYLAND_DISPLAY=$wd -- foot --app-id=$DESKTOP_FOCUS_HOLDER_APP; }" >/dev/null 2>&1
  deadline=$(( $(date +%s) + 20 ))
  while (( $(date +%s) < deadline )); do
    id=$(desk_windows 2>/dev/null | RHIZO_WANT_APP="$DESKTOP_FOCUS_HOLDER_APP" python3 -c "
import json, os, sys
for l in sys.stdin:
    try:
        win = json.loads(l)
    except ValueError:
        continue
    if win.get('app_id') == os.environ['RHIZO_WANT_APP']:
        print(win.get('id', ''))
        break
")
    [[ -n "$id" ]] && break
    sleep 1
  done
  [[ -n "$id" ]] || { echo "the focus holder ($DESKTOP_FOCUS_HOLDER_APP, foot) never mapped a window within 20s"; return 1; }
  desk_window_op "$id" activate >/dev/null 2>&1 || { echo "activating the focus holder's window $id failed"; return 1; }
}

# stop the focus-holder window
desktop_focus_holder_down() {
  desk_user_sh 15 "systemctl --user stop $DESKTOP_FOCUS_HOLDER_APP.service 2>/dev/null; true" >/dev/null 2>&1
}

# print the ids of the app windows
desktop_app_window_ids() {
  local w
  w=$(desk_windows) || return 1
  python3 -c "
import json, sys
only = sys.argv[1]
for l in sys.stdin:
    l = l.strip()
    if not l:
        continue
    try:
        win = json.loads(l)
    except ValueError:
        continue
    app = win.get('app_id') or ''
    title = win.get('title') or ''
    if app in ('rhizo-dragpad', 'rhizo-focus-holder'):
        continue
    if only and app != only:
        continue
    if app != 'rhizo' or title.startswith('Rhizo display'):
        print(win.get('id', ''))
" "${1:-}" <<<"$w"
}

# print how many app windows are mapped
desktop_app_toplevel_count() {
  local ids
  ids=$(desktop_app_window_ids) || return 1
  grep -c . <<<"$ids"
}

# close all of the app windows
desktop_close_all_app_windows() {
  local tries="${1:-40}" only="${2:-}" i ids id
  for (( i = 0; i < tries; i++ )); do
    if ids=$(desktop_app_window_ids "$only"); then
      [[ -z "$ids" ]] && return 0
      local -a idv
      mapfile -t idv < <(grep . <<<"$ids")
      for id in "${idv[@]}"; do
        desk_window_op "$id" close >/dev/null 2>&1 </dev/null
      done
    fi
    sleep 1
  done
  return 1
}

# print a line per composer toplevel as app_id, id and title
desktop_composer_windows() {
  local w
  w=$(desk_windows) || return 1
  python3 -c "
import json, sys
for l in sys.stdin:
    l = l.strip()
    if not l:
        continue
    try:
        win = json.loads(l)
    except ValueError:
        continue
    app = win.get('app_id') or ''
    if app in ('rhizo-dragpad', 'rhizo-focus-holder'):
        continue
    print('%s\t%s\t%s' % (app, win.get('id', ''), win.get('title') or ''))
" <<<"$w"
}

# close a display's window
desktop_close_display_window() {
  local win id
  win=$(_desktop_window_for_display "$1" 0) || return 1
  id=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('id', ''))" "$win") || return 1
  [[ -n "$id" ]] || return 1
  desk_window_op "$id" close >/dev/null 2>&1 </dev/null
}

# assert the server profile has no desktop socket
_desk_server_session_up() {
  local out listing
  out=$(ssh_vm -t 8 "$DESK_WAYLAND_LISTENERS; ls /run/rhizo-wayland/wayland-0 2>/dev/null; echo RHIZO_LS_DONE" 2>/dev/null)
  if [[ "$out" != *RHIZO_LS_DONE* ]]; then
    echo "desk_session_up (server): the remote probe never completed (no sentinel read back)" >&2
    return 1
  fi
  listing=$(grep -v '^RHIZO_LS_DONE$' <<<"$out")
  if [[ -n "${listing//[[:space:]]/}" ]]; then
    echo "desk_session_up (server): a compositor socket already exists: $(tr '\n' ' ' <<<"$listing")" >&2
    return 1
  fi
  return 0
}
_desk_server_session_down() { return 0; }
# print that the verb needs a desktop session and return 3
_desk_server_no_session() {
  echo "desk_${1:-verb} (server): no desktop session -- the server profile runs no compositor" >&2
  return 3
}
# fail the socket_path verb
_desk_server_socket_path()    { _desk_server_no_session socket_path; }
# fail the env verb
_desk_server_env()            { _desk_server_no_session env; }
# fail the shot verb
_desk_server_shot()           { _desk_server_no_session shot; }
# fail the inject_pointer verb
_desk_server_inject_pointer() { _desk_server_no_session inject_pointer; }
# fail the inject_key verb
_desk_server_inject_key()     { _desk_server_no_session inject_key; }
# fail the windows verb
_desk_server_windows()        { _desk_server_no_session windows; }
# fail the window_op verb
_desk_server_window_op()      { _desk_server_no_session window_op; }
# fail the outputs verb
_desk_server_outputs()        { _desk_server_no_session outputs; }
# fail the seat_devices verb
_desk_server_seat_devices()   { _desk_server_no_session seat_devices; }
# fail the keyboard_layout verb
_desk_server_keyboard_layout() { _desk_server_no_session keyboard_layout; }
# fail the notifications verb
_desk_server_notifications()  { _desk_server_no_session notifications; }
# fail the dnd_fixture verb
_desk_server_dnd_fixture()    { _desk_server_no_session dnd_fixture; }
# fail the clipboard verb
_desk_server_clipboard()      { _desk_server_no_session clipboard; }
# fail the dnd verb
_desk_server_dnd()            { _desk_server_no_session dnd; }
# fail the launch_entry verb
_desk_server_launch_entry()   { _desk_server_no_session launch_entry; }


# copy a guest file to the host with scp
pull() {
  timeout "${3:-30}" scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_TARGET:$1" "$2"
}

_RHIZO_NO_DISPLAY_TOPLEVEL_VERB=0
# print the app_id and title of a display's toplevel
resolve_display_toplevel() {
  local disp="$1" init="${INIT:?resolve_display_toplevel needs \$INIT set}"
  (( _RHIZO_NO_DISPLAY_TOPLEVEL_VERB )) && return 1
  local before deadline lines n line app_id title
  before=$(rhizo_ctl_out "$init" | grep -c "^display toplevel id=$disp ")
  rhizo_ctl "$init" display toplevel "$disp" >/dev/null 2>&1
  deadline=$(( $(date +%s) + 5 ))
  while (( $(date +%s) < deadline )); do
    lines=$(rhizo_ctl_out "$init" | grep "^display toplevel id=$disp ")
    n=$(grep -c . <<<"$lines")
    if (( n > before )); then
      line=$(tail -1 <<<"$lines")
      app_id=$(grep -o 'app_id=[^ ]*' <<<"$line" | cut -d= -f2-)
      title=$(sed -n 's/^.*title=//p' <<<"$line")
      [[ -n "$app_id" ]] || return 1
      printf '%s %s' "$app_id" "$title"
      return 0
    fi
    sleep 0.2
  done
  _RHIZO_NO_DISPLAY_TOPLEVEL_VERB=1
  return 1
}

# print why a display's toplevel was never mapped
display_toplevel_unmapped_reason() {
  local disp="$1" init="${INIT:-}" before line
  [[ -n "$init" ]] || return 0
  before=$(rhizo_ctl_out "$init" | grep -c "^display toplevel id=$disp ")
  rhizo_ctl "$init" display toplevel "$disp" >/dev/null 2>&1
  local deadline=$(( $(date +%s) + 5 ))
  while (( $(date +%s) < deadline )); do
    line=$(rhizo_ctl_out "$init" | grep "^display toplevel id=$disp " | tail -1)
    if (( $(rhizo_ctl_out "$init" | grep -c "^display toplevel id=$disp ") > before )); then
      if [[ "$line" == *"output=(none)"* ]]; then
        printf 'the composer holds a toplevel for it (%s) that never reached an output' \
          "$(grep -oE 'app_id=[^ ]+' <<<"$line")"
      fi
      return 0
    fi
    sleep 0.2
  done
  return 0
}

# print the JSON line of a display's toplevel
_desktop_window_for_display() {
  local disp="$1" deadline_s="${2:-60}" any_size=0 all=0 i reply app_id title line
  [[ "${3:-}" == --any-size ]] && any_size=1
  [[ "${3:-}" == --all ]] && all=1
  for (( i = 0; i <= deadline_s; i++ )); do
    reply=$(resolve_display_toplevel "$disp" 2>/dev/null)
    if [[ -n "$reply" ]]; then
      IFS=' ' read -r app_id title <<<"$reply"
    else
      app_id="rhizo"; title="Rhizo display $disp"
    fi
    line=$(desk_windows 2>/dev/null | RHIZO_WANT_APP="$app_id" RHIZO_WANT_TITLE="$title" RHIZO_ANY_SIZE="$any_size" RHIZO_ALL="$all" python3 -c "
import json, os, sys
want_app = os.environ['RHIZO_WANT_APP']
want_title = os.environ['RHIZO_WANT_TITLE']
any_size = os.environ['RHIZO_ANY_SIZE'] == '1'
hits = []
for l in sys.stdin:
    l = l.strip()
    if not l:
        continue
    try:
        w = json.loads(l)
    except ValueError:
        continue
    if w.get('app_id') != want_app or w.get('title') != want_title:
        continue
    if not any_size and not (w.get('w', 0) > 0 and w.get('h', 0) > 0):
        continue
    hits.append(w)
if os.environ['RHIZO_ALL'] == '1':
    for w in hits:
        print(json.dumps(w))
elif hits:
    print(json.dumps(next((w for w in hits if w.get('focused')), hits[0])))
")
    [[ -n "$line" ]] && { printf '%s' "$line"; return 0; }
    (( i < deadline_s )) && sleep 1
  done
  return 1
}

# print the window id of the toplevel with an app_id and title
_desktop_window_id_for_identity() {
  local app_id="$1" title="$2" deadline_s="${3:-20}" i id
  for (( i = 0; i <= deadline_s; i++ )); do
    id=$(desk_windows 2>/dev/null | RHIZO_WANT_APP="$app_id" RHIZO_WANT_TITLE="$title" python3 -c "
import json, os, sys
want_app = os.environ['RHIZO_WANT_APP']
want_title = os.environ['RHIZO_WANT_TITLE']
for l in sys.stdin:
    l = l.strip()
    if not l:
        continue
    try:
        w = json.loads(l)
    except ValueError:
        continue
    if w.get('app_id') == want_app and w.get('title') == want_title:
        print(w.get('id', ''))
        break
")
    [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }
    (( i < deadline_s )) && sleep 1
  done
  return 1
}

# assert a display's window is painted
assert_window_painted() {
  local label="$1" disp="$2" win x y w h nb distinct
  if ! win=$(_desktop_window_for_display "$disp" 60); then
    local why; why=$(display_toplevel_unmapped_reason "$disp" 2>/dev/null)
    fail "$label: display $disp has no mapped window of nonzero size${why:+ ($why)}"
    echo "<none>" > "$EV/$label-window-rect.txt"
    desk_windows > "$EV/$label-sway-windows.txt" 2>&1
    return 1
  fi
  read -r x y w h <<<"$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['x'], d['y'], d['w'], d['h'])" "$win")"
  echo "$x $y $w $h" > "$EV/$label-window-rect.txt"
  desk_windows > "$EV/$label-sway-windows.txt" 2>&1
  local i stats
  for i in $(seq 1 20); do
    if win=$(_desktop_window_for_display "$disp" 5); then
      read -r x y w h <<<"$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['x'], d['y'], d['w'], d['h'])" "$win")"
      echo "$x $y $w $h" > "$EV/$label-window-rect.txt"
    fi
    if ! desk_shot "/tmp/rhizo-${TEST_NAME:-test}-$label.png"; then
      fail "$label: the compositor produced no screenshot"
      return 1
    fi
    pull "/tmp/rhizo-${TEST_NAME:-test}-$label.png" "$EV/$label-window.png" 90 || {
      fail "$label: could not pull the screenshot"; return 1; }
    stats=$(python3 "$_DESKTOP_LIB_DIR/../tools/pngstat.py" "$EV/$label-window.png" --region "$x,$y,$w,$h")
    nb=$(grep '^nonblack_pct=' <<<"$stats" | cut -d= -f2)
    distinct=$(grep '^distinct=' <<<"$stats" | cut -d= -f2)
    if awk -v v="$nb" 'BEGIN { exit !(v + 0 > 50) }' \
       && awk -v v="$distinct" 'BEGIN { exit !(v + 0 > 20) }'; then
      break
    fi
    sleep 1
  done
  echo "$stats" > "$EV/$label-pngstat.txt"
  log "    $label: window ${w}x${h}+${x}+${y} nonblack_pct=$nb distinct=$distinct"
  awk -v v="$nb" 'BEGIN { exit !(v + 0 > 50) }' \
    || { fail "$label: window is still $nb% non-black after 20s, expected over 50%"; return 1; }
  awk -v v="$distinct" 'BEGIN { exit !(v + 0 > 20) }' \
    || { fail "$label: window still has only $distinct distinct colors after 20s, expected over 20"; return 1; }
  pass "$label: a real window, mapped at ${w}x${h} and really painted ($nb% non-black, $distinct colors)"
  return 0
}

# poll until a screenshot region changes by the minimum
wait_shot_change() {
  local deadline_s="$1" before="$2" after="$3" region="$4" minchg="$5"
  local start changed guest=/tmp/rhizo-capture-after.png
  start=$(date +%s)
  changed=0
  while true; do
    if desk_shot "$guest" >/dev/null 2>&1 && pull "$guest" "$after" 2>/dev/null; then
      changed=$(python3 "$REPO/test/system/tools/pngstat.py" --diff "$before" "$after" --region "$region" \
                | grep '^changed=' | cut -d= -f2)
      [[ -n "$changed" ]] || changed=0
      if (( changed >= minchg )); then echo "$changed"; return 0; fi
    fi
    if (( $(date +%s) - start > deadline_s )); then echo "$changed"; return 1; fi
    sleep 1
  done
}

# poll for a screenshot change with no sleep between samples
wait_shot_change_ms() {
  local deadline_s="$1" before="$2" after="$3" region="$4" minchg="$5"
  local start_s start_ns changed guest=/tmp/rhizo-capture-after-ms.png
  start_s=$(date +%s)
  start_ns=$(date +%s%N)
  changed=0
  while true; do
    if desk_shot "$guest" >/dev/null 2>&1 && pull "$guest" "$after" 2>/dev/null; then
      changed=$(python3 "$REPO/test/system/tools/pngstat.py" --diff "$before" "$after" --region "$region" \
                | grep '^changed=' | cut -d= -f2)
      [[ -n "$changed" ]] || changed=0
      if (( changed >= minchg )); then
        echo "$changed $(( ($(date +%s%N) - start_ns) / 1000000 ))"
        return 0
      fi
    fi
    if (( $(date +%s) - start_s > deadline_s )); then
      echo "$changed $(( ($(date +%s%N) - start_ns) / 1000000 ))"
      return 1
    fi
  done
}


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --print-verbs) printf '%s\n' "${DESKTOP_VERBS[@]}"; exit 0 ;;
    *) echo "usage: desktop-lib.sh --print-verbs" >&2; exit 2 ;;
  esac
fi
