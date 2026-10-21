#!/bin/bash

_SWAY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INJECT_FIFO=/tmp/rhizo-inject.fifo
INJECT_SOCK=${RHIZO_INJECT_SOCK:-/tmp/rhizo-inject.sock}
RHIZO_INJECT_OVER_TCP=${RHIZO_INJECT_OVER_TCP:-0}

# run a root command in the guest
gcmd_root() { ssh_vm -t "${2:-20}" "$1"; }

# run a desktop user command in the guest
gcmd_user() {
  local cmd="$1" timeout="${2:-20}"
  local escaped_cmd
  escaped_cmd=$(printf '%q' "$cmd")
  ssh_vm -t "$timeout" "cat > /root/rhizo-client-run.sh <<'RHIZO_CLIENT_RUN_EOF'
#!/bin/bash
_rhizo_u=\$(cat /etc/rhizo/desktop-user 2>/dev/null || echo ubuntu)
_rhizo_uid=\$(id -u \"\$_rhizo_u\" 2>/dev/null || echo 1000)
_rhizo_wd=\$(runuser -u \"\$_rhizo_u\" -- bash -c 'ls /run/user/\$(id -u) 2>/dev/null | grep -E \"^wayland-[0-9]+\$\" | head -1')
_rhizo_sock=\$(runuser -u \"\$_rhizo_u\" -- bash -c 'ls /run/user/\$(id -u)/sway-ipc.* 2>/dev/null | head -1')
exec runuser -u \"\$_rhizo_u\" -- env XDG_RUNTIME_DIR=/run/user/\$_rhizo_uid WAYLAND_DISPLAY=\"\$_rhizo_wd\" SWAYSOCK=\"\$_rhizo_sock\" bash -c \"\$1\"
RHIZO_CLIENT_RUN_EOF
chmod +x /root/rhizo-client-run.sh
/root/rhizo-client-run.sh $escaped_cmd"
}

# return an error for a bare gcmd call
gcmd() {
  log "gcmd: ambiguous -- use gcmd_root (administrative) or gcmd_user (session client)"
  return 2
}

# run swaymsg with the given arguments
swaycmd() { gcmd_user "swaymsg $1" "${2:-20}"; }

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

# wait for the seat pointer and keyboard capabilities
_inject_wait_capabilities() {
  local who="$1" want_keyboard="${2:-1}"
  wait_guest 10 "swaymsg -t get_seats | python3 -c \"
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if any((s.get('capabilities',0) & 1) for s in d) else 1)
\"" || { log "$who: seat never gained pointer capability"; return 1; }
  (( want_keyboard )) || return 0
  wait_guest 10 "swaymsg -t get_seats | python3 -c \"
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if any((s.get('capabilities',0) & 2) for s in d) else 1)
\"" || { log "$who: seat never gained keyboard capability"; return 1; }
  return 0
}

# copy wlr-inject to /tmp on the guest
inject_stage() {
  local out
  out=$(gcmd_root "cp -f /root/share/wlr-inject /tmp/rhizo-wlr-inject && chmod +x /tmp/rhizo-wlr-inject && echo RHIZO_INJECT_STAGED" 25 2>&1)
  case "$out" in
    *RHIZO_INJECT_STAGED*) return 0 ;;
  esac
  log "inject_stage: could not stage /root/share/wlr-inject onto the guest: ${out:-no output}"
  log "  build it with tools/build/test-tools/wlr-inject.sh"
  return 1
}

# start the wlr-inject devices
inject_devices_up() {
  inject_stop
  guest_mount_share || return 1
  inject_stage || return 1
  gcmd_user "rm -f $INJECT_FIFO
setsid sh -c '/tmp/rhizo-wlr-inject --listen $INJECT_SOCK ${RHIZO_INJECT_KEYMAP:+--keymap $RHIZO_INJECT_KEYMAP} > /tmp/wlr-inject.out 2>&1' >/dev/null 2>&1 </dev/null & disown
true" 25
  wait_guest 15 "grep -q ready /tmp/wlr-inject.out" \
    || { log "inject_devices_up: wlr-inject never reported ready"; gcmd_user "cat /tmp/wlr-inject.out"; return 1; }
  RHIZO_INJECT_OVER_TCP=1
  _inject_wait_capabilities inject_devices_up
}

# connect to wlr-inject over its socket
inject_attach() {
  RHIZO_INJECT_OVER_TCP=1
  inject ping >/dev/null 2>&1
  wait_guest 15 "grep -q pong /tmp/wlr-inject.out" \
    || { log "inject_attach: the injector never answered a ping over its socket"; gcmd_user "cat /tmp/wlr-inject.out; dmesg -T | grep -i wlr-inject | tail -3"; return 1; }
  _inject_wait_capabilities inject_attach || return 1
  inject "mods 0 0 0 0" \
    || { log "inject_attach: could not activate the virtual keyboard on the seat"; return 1; }
  return 0
}

# start wlr-inject with a pointer device
inject_start() {
  inject_stop
  guest_mount_share || return 1
  inject_stage || return 1
  gcmd_user "rm -f $INJECT_FIFO && mkfifo $INJECT_FIFO
setsid sh -c 'sleep 86400 > $INJECT_FIFO' >/dev/null 2>&1 </dev/null & disown
setsid sh -c '/tmp/rhizo-wlr-inject --no-keyboard < $INJECT_FIFO > /tmp/wlr-inject.out 2>&1' >/dev/null 2>&1 </dev/null & disown
true" 25
  wait_guest 15 "grep -q ready /tmp/wlr-inject.out" || { log "inject_start: wlr-inject never reported ready"; gcmd_user "cat /tmp/wlr-inject.out"; return 1; }
  _inject_wait_capabilities inject_start 0 || return 1
  return 0
}

# send a command to wlr-inject
inject() {
  if (( ${RHIZO_INJECT_OVER_TCP:-0} )); then
    gcmd_user "printf '%s\n' '$1' | python3 -c \"
import socket,sys
s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('$INJECT_SOCK')
s.sendall(sys.stdin.buffer.read())
s.close()\"" 10
  else
    gcmd_user "echo '$1' > $INJECT_FIFO" 10
  fi
}

# send an absolute move and a left click
inject_click() {
  local x="$1" y="$2" w="${3:-1920}" h="${4:-1080}"
  inject "abs $(( x > 40 ? x - 37 : x + 37 )) $(( y > 40 ? y - 29 : y + 29 )) $w $h" || return 1
  inject "abs $x $y $w $h" || return 1
  inject "btn 272 1" || return 1
  inject "btn 272 0" || return 1
}

# send a horizontal scroll value to wlr-inject
inject_axis_h() { inject "axis_h $1" || return 1; }

# inject a discrete axis scroll
inject_axis_discrete() { inject "axis_disc $1 $2" || return 1; }

# send a keyboard press or release
inject_key() { inject "key $1 $2" || return 1; }

# press a key chord with modifiers
inject_chord() {
  local target="$1"; shift
  local -a chord_mods=("$@")
  local m bit mask=0 i
  for m in "${chord_mods[@]}"; do
    case "$m" in
      29|97)   bit=4  ;;
      42|54)   bit=1  ;;
      56|100)  bit=8  ;;
      125|126) bit=64 ;;
      *) log "inject_chord: unrecognized modifier evdev code $m"; return 1 ;;
    esac
    mask=$(( mask | bit ))
  done
  for m in "${chord_mods[@]}"; do inject "key $m 1" || return 1; done
  inject "mods $mask 0 0 0" || return 1
  inject "key $target 1" || return 1
  inject "key $target 0" || return 1
  inject "mods 0 0 0 0" || return 1
  for (( i=${#chord_mods[@]}-1; i>=0; i-- )); do
    inject "key ${chord_mods[i]} 0" || return 1
  done
}

# press and release each evdev code
inject_type() {
  local c
  for c in "$@"; do
    inject "key $c 1" || return 1
    inject "key $c 0" || return 1
  done
}

# stop the injector and remove its fifo and socket
inject_stop() { gcmd_user "pkill -x wlr-inject; pkill -f 'sleep 86400'; rm -f $INJECT_FIFO $INJECT_SOCK; true" 10; RHIZO_INJECT_OVER_TCP=0; }

# take a screenshot on the guest
shot() { _sway_grim "$1" "${2:-}" ""; }

# copy a file from the guest with scp
pull() {
  timeout "${3:-30}" scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_TARGET:$1" "$2"
}

# print a line per mapped sway window
sway_windows() {
  gcmd_user "swaymsg -t get_tree | python3 -c \"
import json,sys
def walk(n):
    for c in n.get('nodes',[])+n.get('floating_nodes',[]):
        if c.get('pid'):
            r=c['rect']
            print(c.get('app_id'), c.get('name'), r['x'], r['y'], r['width'], r['height'], c.get('focused'))
        walk(c)
walk(json.load(sys.stdin))\"" "${1:-20}"
}

# wait for screenshot pixels to change
wait_shot_change() {
  local deadline_s="$1" before="$2" after="$3" region="$4" minchg="$5"
  local start changed guest=/tmp/rhizo-shot-after.png
  start=$(date +%s)
  changed=0
  while true; do
    if shot "$guest" >/dev/null 2>&1 && pull "$guest" "$after" 2>/dev/null; then
      changed=$(python3 "$REPO/test/system/tools/pngstat.py" --diff "$before" "$after" --region "$region" \
                | grep '^changed=' | cut -d= -f2)
      [[ -n "$changed" ]] || changed=0
      if (( changed >= minchg )); then echo "$changed"; return 0; fi
    fi
    if (( $(date +%s) - start > deadline_s )); then echo "$changed"; return 1; fi
    sleep 1
  done
}

# print changed pixels and elapsed milliseconds
wait_shot_change_ms() {
  local deadline_s="$1" before="$2" after="$3" region="$4" minchg="$5"
  local start_s start_ns changed guest=/tmp/rhizo-shot-after-ms.png
  start_s=$(date +%s)
  start_ns=$(date +%s%N)
  changed=0
  while true; do
    if shot "$guest" >/dev/null 2>&1 && pull "$guest" "$after" 2>/dev/null; then
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

_RHIZO_NO_DISPLAY_TOPLEVEL_VERB=0
# request the app_id and title of a display
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

# escape regex characters in a string
_sway_regex_escape() {
  sed -e 's/[][\.^$*+?(){}|\\]/\\&/g' <<<"$1"
}

# print the rect for an app_id and title
_window_rect_for_identity() {
  local app_id_b64 title_b64
  app_id_b64=$(printf '%s' "$1" | base64 -w0)
  title_b64=$(printf '%s' "$2" | base64 -w0)
  gcmd_user "swaymsg -t get_tree | python3 -c \"
import base64, json, sys
want_app = base64.b64decode('$app_id_b64').decode()
want_title = base64.b64decode('$title_b64').decode()
def walk(n):
    for c in n.get('nodes', []) + n.get('floating_nodes', []):
        if c.get('pid') and c.get('app_id') == want_app and c.get('name') == want_title:
            r = c['rect']
            if r['width'] > 0 and r['height'] > 0:
                print(r['x'], r['y'], r['width'], r['height'])
                sys.exit(0)
        walk(c)
walk(json.load(sys.stdin))\"" "${3:-20}"
}

# print a swaymsg criteria string for a display
display_selector() {
  local disp="$1" reply app_id title
  reply=$(resolve_display_toplevel "$disp" 2>/dev/null)
  if [[ -n "$reply" ]]; then
    IFS=' ' read -r app_id title <<<"$reply"
  else
    app_id="rhizo"; title="Rhizo display $disp"
  fi
  printf '[app_id="^%s$" title="^%s$"]' "$(_sway_regex_escape "$app_id")" "$(_sway_regex_escape "$title")"
}

# print the window rect of a display
window_rect_now() {
  local disp="$1" reply app_id title
  reply=$(resolve_display_toplevel "$disp" 2>/dev/null)
  if [[ -n "$reply" ]]; then
    IFS=' ' read -r app_id title <<<"$reply"
  else
    app_id="rhizo"; title="Rhizo display $disp"
  fi
  local rect
  rect=$(_window_rect_for_identity "$app_id" "$title") && [[ -n "$rect" ]] || return 1
  printf '%s' "$rect"
}

# wait for a display window rect
mapped_window_rect() {
  local disp="$1" i rect reply app_id title
  for i in $(seq 1 60); do
    reply=$(resolve_display_toplevel "$disp" 2>/dev/null)
    if [[ -n "$reply" ]]; then
      IFS=' ' read -r app_id title <<<"$reply"
    else
      app_id="rhizo"; title="Rhizo display $disp"
    fi
    rect=$(_window_rect_for_identity "$app_id" "$title") && [[ -n "$rect" ]] && { printf '%s' "$rect"; return 0; }
    sleep 1
  done
  return 1
}

# wait for a mapped window on a display
display_window_mapped() {
  local disp="$1" deadline_s="${2:-0}" i
  for (( i = 0; i <= deadline_s; i++ )); do
    [[ -n "$(window_rect_now "$disp" 2>/dev/null)" ]] && return 0
    (( i < deadline_s )) && sleep 1
  done
  local why; why=$(display_toplevel_unmapped_reason "$disp" 2>/dev/null)
  [[ -n "$why" ]] && echo "display $disp: $why" >&2
  return 1
}

# print the unmapped reason of a display
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

# close the toplevel on a display
close_display_window() {
  local disp="$1" timeout="${2:-10}" reply app_id title id
  reply=$(resolve_display_toplevel "$disp" 2>/dev/null)
  if [[ -n "$reply" ]]; then
    IFS=' ' read -r app_id title <<<"$reply"
  else
    app_id="rhizo"; title="Rhizo display $disp"
  fi
  id=$(_con_id_for_identity "$app_id" "$title" "$timeout") || return 1
  [[ -n "$id" ]] || return 1
  gcmd_user "swaymsg '[con_id=$id] kill' >/dev/null" "$timeout" 2>/dev/null
}

# print the sway con_id of a toplevel
_con_id_for_identity() {
  local app_id_b64 title_b64
  app_id_b64=$(printf '%s' "$1" | base64 -w0)
  title_b64=$(printf '%s' "$2" | base64 -w0)
  gcmd_user "swaymsg -t get_tree | python3 -c \"
import base64, json, sys
want_app = base64.b64decode('$app_id_b64').decode()
want_title = base64.b64decode('$title_b64').decode()
def walk(n):
    for c in n.get('nodes', []) + n.get('floating_nodes', []):
        if c.get('pid') and c.get('app_id') == want_app and c.get('name') == want_title:
            print(c['id'])
            sys.exit(0)
        walk(c)
walk(json.load(sys.stdin))\"" "${3:-10}"
}

# print the con_id of each app window
_app_con_ids() {
  gcmd_user "swaymsg -t get_tree | python3 -c \"
import json, sys
def walk(n):
    for c in n.get('nodes', []) + n.get('floating_nodes', []):
        if c.get('pid'):
            app = c.get('app_id') or ''
            name = c.get('name') or ''
            if app != 'rhizo' or name.startswith('Rhizo display'):
                print(c['id'])
        walk(c)
walk(json.load(sys.stdin))\"" "${1:-20}"
}

# print the number of mapped app windows
app_toplevel_count() { _app_con_ids "${1:-20}" | grep -c . ; }

# close all app windows
close_all_app_windows() {
  local tries="${1:-40}" i ids id
  for (( i = 0; i < tries; i++ )); do
    ids=$(_app_con_ids 2>/dev/null)
    [[ -z "$ids" ]] && return 0
    while IFS= read -r id; do
      [[ -n "$id" ]] && gcmd_user "swaymsg '[con_id=$id] kill' >/dev/null" 5 2>/dev/null
    done <<<"$ids"
    sleep 1
  done
  return 1
}

# check the pixels of a display window
assert_window_painted() {
  local label="$1" disp="$2" rect x y w h nb distinct
  if ! rect=$(mapped_window_rect "$disp"); then
    local why; why=$(display_toplevel_unmapped_reason "$disp" 2>/dev/null)
    fail "$label: display $disp has no mapped window of nonzero size${why:+ ($why)}"
    echo "<none>" > "$EV/$label-window-rect.txt"
    sway_windows > "$EV/$label-sway-windows.txt" 2>&1
    return 1
  fi
  read -r x y w h <<<"$rect"
  echo "$rect" > "$EV/$label-window-rect.txt"
  sway_windows > "$EV/$label-sway-windows.txt" 2>&1
  local i stats nb distinct
  for i in $(seq 1 20); do
    if ! shot /tmp/rhizo-${TEST_NAME:-test}-$label.png; then
      fail "$label: grim produced no screenshot"
      return 1
    fi
    pull /tmp/rhizo-${TEST_NAME:-test}-$label.png "$EV/$label-window.png" 90 || {
      fail "$label: could not pull the screenshot"; return 1; }
    stats=$(python3 "$_SWAY_LIB_DIR/../tools/pngstat.py" "$EV/$label-window.png" --region "$x,$y,$w,$h")
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

# start the sway session with start-sway.sh
_desk_sway_session_up() {
  local user="" layout="" monitors=""
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage-login) args+=(--stage-login); shift ;;
      --user) user="$2"; shift 2 ;;
      --layout) layout="$2"; shift 2 ;;
      --monitors) monitors="$2"; shift 2 ;;
      *) echo "_desk_sway_session_up: unknown argument $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$layout" ]] && args+=(--xkb-layout "$layout")
  [[ -n "$user" ]] && args+=(--user "$user")
  [[ -n "$monitors" ]] && args+=(--size "${monitors%%,*}")
  "$_SWAY_LIB_DIR/../../vm/start/start-sway.sh" "${args[@]}"
}

# stop sway and swaybg
_desk_sway_session_down() {
  gcmd_user "pkill -9 sway 2>/dev/null; pkill -9 swaybg 2>/dev/null; true" 15
}

# print the desktop user's session environment
_desk_sway_env() {
  gcmd_user "_u=\$(cat /etc/rhizo/desktop-user 2>/dev/null || echo ubuntu); \
_uid=\$(id -u \"\$_u\" 2>/dev/null || echo 1000); \
_rd=/run/user/\$_uid; \
_wd=\$(ls \$_rd 2>/dev/null | grep -E '^wayland-[0-9]+\$' | head -1); \
echo WAYLAND_DISPLAY=\$_wd; echo XDG_RUNTIME_DIR=\$_rd; echo DBUS_SESSION_BUS_ADDRESS=unix:path=\$_rd/bus; echo RHIZO_DESK_UID=\$_uid" 15
}

# print the path of the sway wayland socket
_desk_sway_socket_path() {
  gcmd_user "_u=\$(cat /etc/rhizo/desktop-user 2>/dev/null || echo ubuntu); \
_rd=/run/user/\$(id -u \"\$_u\" 2>/dev/null || echo 1000); \
_wd=\$(ls \$_rd 2>/dev/null | grep -E '^wayland-[0-9]+\$' | head -1); \
[ -n \"\$_wd\" ] && echo \$_rd/\$_wd" 15
}

# take a screenshot with grim on the guest
_desk_sway_shot() {
  local out="$1" region="${2:-}" output="${3:-}" geom="" oarg=""
  if [[ -n "$region" ]]; then
    local x y w h
    IFS=',' read -r x y w h <<<"$region"
    geom="-g '$x,$y ${w}x${h}'"
  fi
  [[ -n "$output" ]] && oarg="-o $output"
  _sway_grim "$out" "$oarg $geom" "$output"
}

# run grim on the guest
_sway_grim() {
  local out="$1" grim_args="$2" output="$3"
  local rc hang_ev=""
  if [[ -n "${EV:-}" && -d "${EV:-}" ]]; then
    hang_ev="$EV/sway-shot-hang-$(basename "$out" .png).txt"
    [[ " ${_SWAY_SHOT_EV_OPENED:-} " == *" $hang_ev "* ]] \
      || { echo '<none>' > "$hang_ev"; _SWAY_SHOT_EV_OPENED+=" $hang_ev"; }
  fi
  gcmd_user "timeout 10 grim $grim_args $out && test -s $out" 25; rc=$?
  if (( rc == 124 )); then
    echo "_sway_grim: no frame: grim got none within 10s${hang_ev:+ (see $hang_ev)}" >&2
    if [[ -n "$hang_ev" ]]; then
      [[ "$(cat "$hang_ev" 2>/dev/null)" == '<none>' ]] && : > "$hang_ev"
      { echo "### $(date -u +%FT%TZ)"; _desk_sway_shot_hang_evidence "$output"; } >> "$hang_ev"
    fi
  fi
  return "$rc"
}

# print debug output for a failed grim screenshot
_desk_sway_shot_hang_evidence() {
  local output="${1:-}" name out
  [[ -n "$output" ]] || output=$(gcmd_user "swaymsg -t get_outputs | python3 -c \"import json,sys; o=[x['name'] for x in json.load(sys.stdin) if x.get('active')]; print(o[0] if o else '')\"" 20 | tr -d '[:space:]')
  for name in grim-wayland-debug outputs session-active tty0-active sway-log drm-clients card0-tags coldboots; do
    case "$name" in
      grim-wayland-debug)
        out=$(gcmd_user "WAYLAND_DEBUG=1 timeout 10 grim ${output:+-o $output} /tmp/rhizo-shot-debug.png 2>&1 | tail -150; echo \"grim rc=\${PIPESTATUS[0]}\"" 25) ;;
      outputs)
        out=$(gcmd_user "swaymsg -t get_outputs | python3 -c \"import json,sys
for x in json.load(sys.stdin): print(x.get('name'), 'active=%s' % x.get('active'), 'power=%s' % x.get('power'), 'dpms=%s' % x.get('dpms'), 'mode=%s' % (x.get('current_mode') or {}))\"" 20) ;;
      session-active)
        out=$(gcmd_user "for s in \$(loginctl show-user \$(id -u) -p Sessions --value); do echo \"\$s \$(loginctl show-session \$s -p Active)\"; done" 20) ;;
      tty0-active) out=$(gcmd_user "cat /sys/class/tty/tty0/active" 10) ;;
      sway-log) out=$(gcmd_user "tail -80 /tmp/rhizo-sway-1000.log" 10) ;;
      drm-clients) out=$(ssh_vm -t 15 "cat /sys/kernel/debug/dri/*/clients" 2>/dev/null) ;;
      card0-tags) out=$(ssh_vm -t 15 "udevadm info /dev/dri/card0" 2>/dev/null) ;;
      coldboots) out=$(ssh_vm -t 15 "dmesg | grep -E 'ueventd: (Coldboot|Cannot stat /dev/ptmx)'" 2>/dev/null) ;;
    esac
    printf '=== %s\n%s\n' "$name" "${out:-<none>}"
  done
}

# print the bounding box of active outputs
_sway_layout_extent() {
  gcmd_user "swaymsg -t get_outputs | python3 -c \"
import json,sys
o=[x for x in json.load(sys.stdin) if x.get('active')]
print(max(x['rect']['x']+x['rect']['width'] for x in o), max(x['rect']['y']+x['rect']['height'] for x in o))\"" 20
}

# send a pointer event to wlr-inject
_desk_sway_inject_pointer() {
  local verb="$1"; shift
  case "$verb" in
    abs)
      local lx ly
      read -r lx ly <<<"$(_sway_layout_extent)"
      [[ -n "$lx" && -n "$ly" ]] || { echo "_desk_sway_inject_pointer abs: could not read the layout extent" >&2; return 1; }
      inject "abs $1 $2 $lx $ly"
      ;;
    btn) inject "btn $1 $2" ;;
    axis)
      case "$1" in
        v) inject "axis $2" ;;
        h) inject "axis_h $2" ;;
        *) echo "_desk_sway_inject_pointer axis: want h or v, got '$1'" >&2; return 2 ;;
      esac
      ;;
    *) echo "_desk_sway_inject_pointer: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# inject a single key event
_desk_sway_inject_key() { inject_key "$1" "$2"; }

# print a JSON object per mapped toplevel
_desk_sway_windows() {
  gcmd_user "swaymsg -t get_tree | python3 -c \"
import json, sys
def walk(n, output):
    if n.get('type') == 'output':
        output = n.get('name')
    for c in n.get('nodes', []) + n.get('floating_nodes', []):
        if c.get('pid'):
            r = c['rect']
            print(json.dumps({
                'app_id': c.get('app_id'), 'id': c.get('id'), 'title': c.get('name'),
                'x': r['x'], 'y': r['y'], 'w': r['width'], 'h': r['height'],
                'fullscreen': c.get('fullscreen_mode') == 1,
                'maximized': c.get('type') != 'floating_con',
                'focused': bool(c.get('focused')),
                'urgent': bool(c.get('urgent')),
                'monitor': output,
            }))
        walk(c, output)
walk(json.load(sys.stdin), None)\"" "${1:-20}"
}

# run a window operation on a sway container
_desk_sway_window_op() {
  local id="$1" op="$2"; shift 2
  case "$op" in
    fullscreen)   gcmd_user "swaymsg '[con_id=$id] fullscreen enable' >/dev/null" 20 ;;
    unfullscreen) gcmd_user "swaymsg '[con_id=$id] fullscreen disable' >/dev/null" 20 ;;
    maximize)     gcmd_user "swaymsg '[con_id=$id] floating disable' >/dev/null" 20 ;;
    unmaximize)   gcmd_user "swaymsg '[con_id=$id] floating enable' >/dev/null" 20 ;;
    move)         gcmd_user "swaymsg '[con_id=$id] move position $1 $2' >/dev/null" 20 ;;
    resize)       gcmd_user "swaymsg '[con_id=$id] resize set $1 px $2 px' >/dev/null" 20 ;;
    to_monitor)   gcmd_user "swaymsg '[con_id=$id] move container to output $1' >/dev/null" 20 ;;
    activate)     gcmd_user "swaymsg '[con_id=$id] focus' >/dev/null" 20 ;;
    close)        gcmd_user "swaymsg '[con_id=$id] kill' >/dev/null" 20 ;;
    *) echo "_desk_sway_window_op: unknown op '$op'" >&2; return 2 ;;
  esac
}

# run a sway output command
_desk_sway_outputs() {
  local verb="$1"; shift
  case "$verb" in
    add)
      local w="${1%x*}" h="${1#*x}" maxx name before_count after_count
      maxx=$(gcmd_user "swaymsg -t get_outputs | python3 -c \"
import json,sys
o=[x for x in json.load(sys.stdin) if x.get('active')]
print(max((x['rect']['x']+x['rect']['width'] for x in o), default=0))\"" 20)
      before_count=$(gcmd_user "swaymsg -t get_outputs | python3 -c \"
import json,sys
print(sum(1 for x in json.load(sys.stdin) if x['name'].startswith('HEADLESS-')))\"" 20)
      gcmd_user "swaymsg create_output >/dev/null" 20 || return 1
      after_count=$(gcmd_user "swaymsg -t get_outputs | python3 -c \"
import json,sys
print(sum(1 for x in json.load(sys.stdin) if x['name'].startswith('HEADLESS-')))\"" 20)
      if [[ -z "$before_count" || -z "$after_count" || "$after_count" -le "$before_count" ]]; then
        echo "_desk_sway_outputs add: create_output did not add a HEADLESS-* output (before=${before_count:-?} after=${after_count:-?})" >&2
        return 1
      fi
      name=$(gcmd_user "swaymsg -t get_outputs | python3 -c \"
import json,sys
o=[x['name'] for x in json.load(sys.stdin) if x['name'].startswith('HEADLESS-')]
print(sorted(o, key=lambda n: int(n.split('-')[1]))[-1] if o else '')\"" 20)
      [[ -n "$name" ]] || return 1
      gcmd_user "swaymsg 'output $name mode ${w}x${h} position ${maxx:-0} 0' >/dev/null" 20 || return 1
      printf '%s' "$name"
      ;;
    remove) gcmd_user "swaymsg 'output $1 unplug' >/dev/null" 20 ;;
    scale)  gcmd_user "swaymsg 'output $1 scale $2' >/dev/null" 20 ;;
    list)   gcmd_user "swaymsg -t get_outputs" 20 ;;
    *) echo "_desk_sway_outputs: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# print the sway input devices
_desk_sway_seat_devices() { gcmd_user "swaymsg -t get_inputs" "${1:-20}"; }

# set the sway keyboard layout
_desk_sway_keyboard_layout() {
  [[ "${1:-}" =~ ^[a-z]{2,8}$ ]] || { echo "_desk_sway_keyboard_layout: want an xkb layout code, got '${1:-}'" >&2; return 2; }
  gcmd_user "swaymsg input type:keyboard xkb_layout $1" 20
}

# list or activate notifications
_desk_sway_notifications() {
  local verb="$1"; shift
  declare -F notify_sink_start >/dev/null 2>&1 \
    || { echo "_desk_sway_notifications: desktop-assert-lib.sh is not sourced" >&2; return 2; }
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
" "$1") || { echo "_desk_sway_notifications: the sink recorded no notification $1" >&2; return 1; }
      [[ " $declared " == *" $key "* ]] \
        || { echo "_desk_sway_notifications: notification $1 declares no action '$key' (declared: ${declared:-none})" >&2; return 1; }
      notify_invoke_action "$1" "$key" ;;
    *) echo "_desk_sway_notifications: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# set or get the clipboard
_desk_sway_clipboard() {
  local verb="$1"; shift
  declare -F clip_start >/dev/null 2>&1 \
    || { echo "_desk_sway_clipboard: desktop-assert-lib.sh is not sourced" >&2; return 2; }
  local running; running=$(gcmd_user "pgrep -f 'rhizo-wlbridge-[t]est' | head -1" 10 | tr -d '[:space:]')
  [[ -n "$running" ]] || clip_start || return 1
  case "$verb" in
    set) clipcmd "set $1 $2" ;;
    mark) clip_mark ;;
    get) clip_wait_data "$1" "${2:-30}" "${3:-}" ;;
    focus-rhizo) desktop_focus_rhizo_window ;;
    *) echo "_desk_sway_clipboard: unknown verb '$verb'" >&2; return 2 ;;
  esac
}

# send drag and drop commands to rhizo-wlbridge-test
_desk_sway_dnd() {
  local verb="$1"; shift
  declare -F clip_start >/dev/null 2>&1 \
    || { echo "_desk_sway_dnd: desktop-assert-lib.sh is not sourced"; return 2; }
  local running; running=$(gcmd_user "pgrep -f 'rhizo-wlbridge-[t]est' | head -1" 10 | tr -d '[:space:]')
  [[ -n "$running" ]] || clip_start || { echo "the system test's own client did not start"; return 1; }
  local since ack
  since=$(clip_mark) || { echo "the system test's own client's output could not be read"; return 1; }
  case "$verb" in
    pad)
      case "$1" in
        on) clipcmd "dragpad on"; ack=$(clip_await '^padmapped$' "$since" 15) || { echo "${ack:-no padmapped within 15s}"; return 1; } ;;
        off) clipcmd "dragpad off" ;;
        *) echo "_desk_sway_dnd pad: want on or off, got '$1'"; return 2 ;;
      esac
      ;;
    pad-point)
      clipcmd "padorigin"
      ack=$(clip_await '^padorigin [0-9]+ [0-9]+$' "$since" 15) || { echo "${ack:-no padorigin answer within 15s}"; return 1; }
      local px py
      read -r _ px py <<<"$ack"
      echo "$(( px + 32 )) $(( py + 32 ))"
      ;;
    press)
      clipcmd "press $1 $2"
      ack=$(clip_await "^pressed $1 $2\$" "$since" 15) || { echo "${ack:-no press answer within 15s}"; return 1; }
      ;;
    moveto)
      clipcmd "moveto $1 $2"
      ack=$(clip_await "^movedto $1 $2\$" "$since" 15) || { echo "${ack:-no moveto answer within 15s}"; return 1; }
      ;;
    release)
      clipcmd "release"
      ack=$(clip_await '^released$' "$since" 15) || { echo "${ack:-no release answer within 15s}"; return 1; }
      ;;
    drop)
      clipcmd "dragto $1 $2 $3 $4"
      ack=$(clip_await '^dragstarted ' "$since" 20) || { echo "${ack:-the drag never started within 20s}"; return 1; }
      ;;
    *) echo "_desk_sway_dnd: unknown verb '$verb'"; return 2 ;;
  esac
}
SWAY_LAUNCH_STATE=/tmp/rhizo-sway-launch-scope

# launch a desktop entry through swaymsg exec
_desk_sway_launch_entry() {
  local entry="$1" mode="${2:-}" cmd strip="" ws back
  if [[ "$entry" == "done" ]]; then
    read -r ws back <<<"$(gcmd_user "cat $SWAY_LAUNCH_STATE 2>/dev/null" 10)"
    [[ -n "$ws" && -n "$back" ]] || return 0
    gcmd_user "swaymsg '[workspace=\"^$ws\$\"] move container to workspace $back' >/dev/null; swaymsg 'workspace $back' >/dev/null && rm -f $SWAY_LAUNCH_STATE" 20 \
      || { echo "moving the launch's windows back to workspace $back failed"; return 1; }
    return 0
  fi
  [[ "$entry" =~ ^/[A-Za-z0-9_./-]+\.desktop$ ]] || { echo "not a desktop entry path this exec can take: $entry"; return 1; }
  [[ -z "$mode" || "$mode" == --no-token ]] || { echo "_desk_sway_launch_entry: want --no-token or nothing, got '$mode'"; return 2; }
  [[ "$mode" == --no-token ]] && strip="env -u XDG_ACTIVATION_TOKEN -u DESKTOP_STARTUP_ID "
  cmd=$(gcmd_user "sed -n 's/^Exec=//p' '$entry' | head -1" 15)
  cmd=$(sed -E 's/ %[uUfFick]//g' <<<"$cmd")
  [[ -n "$cmd" ]] || { echo "$entry has no Exec= line to run"; return 1; }
  [[ "$cmd" != *"'"* ]] || { echo "$entry's Exec= carries a quote this exec cannot pass: $cmd"; return 1; }
  back=$(gcmd_user "swaymsg -t get_workspaces | python3 -c \"import json,sys; print([w['name'] for w in json.load(sys.stdin) if w['focused']][0])\"" 15)
  [[ "$back" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "the focused workspace's name did not read ('$back')"; return 1; }
  ws="rhizo-launch-$(date +%s%N)"
  gcmd_user "echo '$ws $back' > $SWAY_LAUNCH_STATE && swaymsg 'no_focus [workspace=\"^$ws\$\"]' >/dev/null && swaymsg 'move container to workspace $ws' >/dev/null && swaymsg 'workspace $ws' >/dev/null" 20 \
    || { echo "scoping the launch to workspace $ws failed"; return 1; }
  gcmd_user "swaymsg exec -- '$strip$cmd'" 20 >/dev/null || { echo "swaymsg exec of '$strip$cmd' failed"; return 1; }
  if [[ -n "$strip" ]]; then echo "launched token=none via swaymsg exec on $ws"; else echo "launched token=sway via swaymsg exec on $ws"; fi
}

# report that sway has no drag-and-drop fixture
_desk_sway_dnd_fixture() {
  echo "_desk_sway_dnd_fixture: not wired up yet" >&2
  return 2
}

# test for the staged wlr-inject file
sway_injector_staged() {
  [[ -f "$VAR_DIR/share/wlr-inject" ]]
}
