#!/bin/bash
# find `ls | head -1` socket picks in start scripts
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$HERE/../system/lib/desk-user-lib.sh"
STARTS=("$HERE/../vm/start/start-sway.sh" "$HERE/../vm/start/start-gnome.sh")
CALLERS=("$HERE/../system/install/installer.sh")

# run the behavior tests against desk-user-lib.sh
lib_behavior() {
  local tmp out
  tmp=$(mktemp -d) || { echo "FAIL setup: mktemp -d"; return; }
  out=$(LIB="$1" TMPD="$tmp" bash <<'EOF'
set -u
unset DESK_USER_LIB_SOURCED
source "$LIB" || { echo "FAIL source: $LIB did not source"; exit 0; }
expect() {  # compare two values
  [[ "$2" == "$3" ]] || echo "FAIL $1: want '$2', got '$3'"
}

CTX=""
ssh_vm() { printf '%s\n' "$CTX"; }
ctx_rc() { CTX="$2"; desk_compositor_context 4242 "$1" >/dev/null 2>&1; echo $?; }
expect context.login-kernel 1 "$(ctx_rc login kernel)"
expect context.login-kernel-domain 1 "$(ctx_rc login u:r:kernel:s0)"
expect context.login-unreadable 1 "$(ctx_rc login '')"
expect context.login-rhizo-host 0 "$(ctx_rc login u:r:rhizo_host:s0)"
expect context.rig-no-policy 0 "$(ctx_rc rig kernel)"
expect context.rig-kernel-domain 1 "$(ctx_rc rig u:r:kernel:s0)"
expect context.rig-rhizo-host 0 "$(ctx_rc rig u:r:rhizo_host:s0)"
expect context.no-mode 2 "$(ctx_rc '' u:r:rhizo_host:s0)"
expect context.stock-apparmor 0 "$(ctx_rc stock unconfined)"
expect context.stock-unreadable 1 "$(ctx_rc stock '')"
expect context.stock-no-labeling-lsm 0 "$(ctx_rc stock $'\nLSM=capability,landlock,lockdown,yama,bpf\nALIVE')"
expect context.stock-unlabeled-under-apparmor 1 "$(ctx_rc stock $'\nLSM=capability,lockdown,yama,apparmor\nALIVE')"
expect context.stock-no-labeling-lsm-dead 1 "$(ctx_rc stock $'\nLSM=capability,landlock,lockdown,yama,bpf')"
expect context.login-no-labeling-lsm 1 "$(ctx_rc login $'\nLSM=capability,landlock,lockdown,yama,bpf\nALIVE')"

seat_out() { local o; o=$(desk_sway_seat_output "$@" 2>/dev/null); echo "$? $o"; }
expect seat-output.default-refresh "0 output * mode --custom 1920x1080@60Hz" "$(seat_out 1920x1080 '')"
expect seat-output.asked-refresh "0 output * mode --custom 1280x720@59.94Hz" "$(seat_out 1280x720 59.94)"
expect seat-output.zero-refused "2 " "$(seat_out 1920x1080 0)"
expect seat-output.sub-hz-refused "2 " "$(seat_out 1920x1080 0.0004)"
expect seat-output.word-refused "2 " "$(seat_out 1920x1080 fast)"
expect seat-output.bad-size-refused "2 " "$(seat_out 1920 60)"

SWAY_GOOD='UID=1000
SEAT_ACTIVE=3
SESSION_Id=3
SESSION_Name=deskuser
SESSION_Seat=seat0
SESSION_Active=yes
SESSION_State=active
SESSION_Class=user
SESSION_Service=login
SESSION_TimestampMonotonic=20000000
SESSION_VTNr=1
LOGIND_TTYS=/dev/tty1 /dev/tty6
POLICY_LoadState=loaded
POLICY_ActiveState=active
POLICY_ActiveEnterTimestampMonotonic=15000000
COMP_PIDS=4242
COMP_PS=1000 u:r:rhizo_host:s0
COMP_CGROUP=/user.slice/user-1000.slice/session-3.scope
COMP_UNIT_START=20000100
LOGIND_START=20000000 deskuser 3
SOCKET=wayland-1
DONE'
GNOME_GOOD='UID=1000
SEAT_ACTIVE=4
SESSION_Id=4
SESSION_Name=deskuser
SESSION_Seat=seat0
SESSION_Active=yes
SESSION_State=active
SESSION_Class=user
SESSION_Service=gdm-autologin
SESSION_TimestampMonotonic=30000000
POLICY_LoadState=loaded
POLICY_ActiveState=active
POLICY_ActiveEnterTimestampMonotonic=15000000
COMP_PIDS=5151
COMP_PS=1000 u:r:rhizo_host:s0
COMP_CGROUP=/user.slice/user-1000.slice/user@1000.service/session.slice/gnome-shell-wayland.service
LOGIND_START=18000000 gdm c1
LOGIND_START=30000000 deskuser 4
GREETER_UID=120
GREETER_SHELL_FIRST=18500000
COMP_UNIT_START=31000000
SOCKET=wayland-0
DONE'
# replace or remove a KEY line
set_field() { awk -v k="$2" -v val="$3" 'index($0, k "=") == 1 { if (val != "-drop") print k "=" val; next } { print }' <<<"$1"; }
# print the exit code and problem names
verdict() {
  local out rc
  out=$(desk_seat_verdict deskuser "$1" "$2" "$3"); rc=$?
  printf '%s %s %s' "$rc" "$(sed -n '1s/^kind=//p' <<<"$out")" \
    "$(tail -n +2 <<<"$out" | sed -n 's/^\([a-z][a-z0-9-]*\(\.[a-z0-9-]*\)*\): .*/\1/p' | tr '\n' ' ')"
}
# check the verdict names the given problem
seat() {
  local got; got=$(verdict "$2" "$3" "$4")
  [[ "$got" == "1 "* && " ${got#* * } " == *" $5 "* ]] || echo "FAIL seat.$1: want $5, got '$got'"
}
PLASMA_GOOD=$(sed -e 's/^SESSION_Service=gdm-autologin$/SESSION_Service=plasmalogin-autologin/' \
  -e 's|/gnome-shell-wayland.service$|/plasma-kwin_wayland.service|' \
  -e 's/^LOGIND_START=18000000 gdm c1$/LOGIND_START=18000000 plasmalogin c1/' <<<"$GNOME_GOOD")
expect seat.sway-good "0 policy ok " "$(verdict login '' "$SWAY_GOOD")"
expect seat.gnome-good "0 policy ok " "$(verdict gdm-autologin gdm "$GNOME_GOOD")"
expect seat.plasma-good "0 policy ok " "$(verdict plasmalogin-autologin plasmalogin "$PLASMA_GOOD")"
seat plasma-kwin-before-session plasmalogin-autologin plasmalogin \
  "$(set_field "$PLASMA_GOOD" COMP_UNIT_START 29000000)" order.compositor-before-session
seat systemd-run-kwin plasmalogin-autologin plasmalogin \
  "$(set_field "$PLASMA_GOOD" COMP_CGROUP /user.slice/user-1000.slice/user@1000.service/app.slice/rhizo-kwin.service)" compositor.outside-seat-login
SWAY_STOCK=$(set_field "$(set_field "$(set_field "$SWAY_GOOD" POLICY_LoadState not-found)" POLICY_ActiveEnterTimestampMonotonic 0)" COMP_PS '1000 unconfined')
expect seat.stock-good "0 stock ok " "$(verdict login '' "$SWAY_STOCK")"
seat empty-read login '' '' read.incomplete
seat no-done login '' "${SWAY_GOOD%DONE}" read.incomplete
seat loginctl-no-session login '' "$(set_field "$SWAY_GOOD" SEAT_ACTIVE '')" seat.no-active-session
seat loginctl-other-user login '' "$(set_field "$SWAY_GOOD" SESSION_Name gdm)" seat.not-desktop-user
seat loginctl-inactive login '' "$(set_field "$SWAY_GOOD" SESSION_Active no)" seat.not-active
seat loginctl-other-seat login '' "$(set_field "$SWAY_GOOD" SESSION_Seat -drop)" seat.not-seat0
seat loginctl-greeter-class login '' "$(set_field "$SWAY_GOOD" SESSION_Class greeter)" seat.not-user-class
seat loginctl-ssh login '' "$(set_field "$SWAY_GOOD" SESSION_Service sshd)" seat.not-staged-login
seat loginctl-no-timestamp login '' "$(set_field "$SWAY_GOOD" SESSION_TimestampMonotonic '')" seat.timestamp-unread
seat loginctl-no-vt login '' "$(set_field "$SWAY_GOOD" SESSION_VTNr 0)" seat.no-vt
seat logind-fds-unread login '' "$(set_field "$SWAY_GOOD" LOGIND_TTYS -drop)" seat.vt-unread
seat logind-vt-not-held login '' "$(set_field "$SWAY_GOOD" LOGIND_TTYS '/dev/tty6 ')" seat.no-vt-control
seat logind-other-vt login '' "$(set_field "$SWAY_GOOD" LOGIND_TTYS '/dev/tty11 /dev/tty6 ')" seat.no-vt-control
seat ps-unreadable login '' "$(set_field "$SWAY_GOOD" COMP_PS '')" compositor.ps-unreadable
seat ps-kernel login '' "$(set_field "$SWAY_GOOD" COMP_PS '1000 u:r:kernel:s0')" compositor.not-rhizo-host
seat ps-root login '' "$(set_field "$SWAY_GOOD" COMP_PS '0 u:r:rhizo_host:s0')" compositor.not-desktop-uid
seat no-compositor login '' "$(set_field "$SWAY_GOOD" COMP_PIDS '')" compositor.not-one
seat two-compositors login '' "$(set_field "$SWAY_GOOD" COMP_PIDS '4242 4343 ')" compositor.not-one
seat systemd-run-sway login '' \
  "$(set_field "$SWAY_GOOD" COMP_CGROUP /user.slice/user-1000.slice/user@1000.service/app.slice/rhizo-sway.service)" compositor.outside-seat-login
seat no-cgroup login '' "$(set_field "$SWAY_GOOD" COMP_CGROUP '')" compositor.cgroup-unread
seat no-socket login '' "$(set_field "$SWAY_GOOD" SOCKET '')" compositor.no-wayland-socket
seat systemctl-no-load-state login '' "$(set_field "$SWAY_GOOD" POLICY_LoadState '')" policy.load-state-unread
seat systemctl-policy-failed login '' "$(set_field "$SWAY_GOOD" POLICY_ActiveState failed)" policy.not-active
seat systemctl-policy-zero login '' "$(set_field "$SWAY_GOOD" POLICY_ActiveEnterTimestampMonotonic 0)" policy.timestamp-unread
seat systemctl-unit-unread login '' "$(set_field "$SWAY_GOOD" COMP_UNIT_START '')" compositor.unit-start-unread
seat compositor-before-policy login '' "$(set_field "$SWAY_GOOD" COMP_UNIT_START 14000000)" order.compositor-before-policy
seat session-before-policy login '' "$(set_field "$SWAY_GOOD" SESSION_TimestampMonotonic 14000000)" order.session-before-policy
seat no-greeter gdm-autologin gdm "$(sed '/^LOGIND_START=18000000 gdm/d' <<<"$GNOME_GOOD")" greeter.no-session
seat greeter-after-user gdm-autologin gdm "$(sed 's/^LOGIND_START=18000000 gdm/LOGIND_START=30500000 gdm/' <<<"$GNOME_GOOD")" greeter.after-user-session
seat greeter-before-policy gdm-autologin gdm "$(sed 's/^LOGIND_START=18000000 gdm/LOGIND_START=14000000 gdm/' <<<"$GNOME_GOOD")" order.greeter-before-policy
seat greeter-shell-never gdm-autologin gdm "$(set_field "$GNOME_GOOD" GREETER_SHELL_FIRST '')" greeter.compositor-never-ran
seat greeter-shell-late gdm-autologin gdm "$(set_field "$GNOME_GOOD" GREETER_SHELL_FIRST 30500000)" greeter.compositor-after-user-session
seat gnome-shell-before-session gdm-autologin gdm "$(set_field "$GNOME_GOOD" COMP_UNIT_START 29000000)" order.compositor-before-session
seat gnome-in-other-user gdm-autologin gdm \
  "$(set_field "$GNOME_GOOD" COMP_CGROUP /user.slice/user-1001.slice/user@1001.service/session.slice/gnome-shell-wayland.service)" compositor.outside-seat-login
seat systemd-run-gnome-shell gdm-autologin gdm \
  "$(set_field "$GNOME_GOOD" COMP_CGROUP /user.slice/user-1000.slice/user@1000.service/app.slice/run-u12.service)" compositor.outside-seat-login
seat gnome-shell-in-manager-root gdm-autologin gdm \
  "$(set_field "$GNOME_GOOD" COMP_CGROUP /user.slice/user-1000.slice/user@1000.service/init.scope)" compositor.outside-seat-login

expect poll.empty "wait" "$(desk_seat_poll_judge '' | cut -d' ' -f1)"
expect poll.starting "starting starting" "$(desk_seat_poll_judge $'UID=1000\nSYSTEM=starting\nPIDS=\nDONE')"
expect poll.ready "ready 4242" "$(desk_seat_poll_judge $'UID=1000\nSYSTEM=running\nPIDS=4242 \nDONE')"
expect poll.degraded-ready "ready 4242" "$(desk_seat_poll_judge $'UID=1000\nSYSTEM=degraded\nPIDS=4242 \nDONE')"
expect poll.none "wait none" "$(desk_seat_poll_judge $'UID=1000\nSYSTEM=running\nPIDS=\nDONE' | cut -d' ' -f1-2)"
expect poll.two "wait 2" "$(desk_seat_poll_judge $'UID=1000\nSYSTEM=running\nPIDS=1 2 \nDONE' | cut -d' ' -f1-2)"
expect poll.no-account "wait no such account" "$(desk_seat_poll_judge $'UID=\nSYSTEM=running\nDONE')"

rd="$TMPD/rd"
mkdir -p "$rd"
touch "$rd/wayland-0" "$rd/wayland-0.lock" "$rd/wayland-1" "$rd/sway-ipc.1000.77.sock" "$rd/bus"
ln -s wayland-0 "$rd/wayland-rhizo"
XDG_RUNTIME_DIR="$rd" bash -c "$DESK_CLEAR_SESSION_SOCKETS" >/dev/null 2>&1
expect clear.leftover-removed "0 " "$? $(ls -A "$rd" | grep -E '^(wayland|sway-ipc)' | tr '\n' ' ')"
[[ -e "$rd/bus" ]] || echo "FAIL clear.keeps-others: the user bus socket was removed too"
rd2="$TMPD/rd2"
mkdir -p "$rd2/wayland-1"
touch "$rd2/wayland-0"
XDG_RUNTIME_DIR="$rd2" bash -c "$DESK_CLEAR_SESSION_SOCKETS" >/dev/null 2>&1
rc=$?
[[ $rc -ne 0 ]] || echo "FAIL clear.survivor-fails: wayland-1 survived and the clear returned 0"

P="$TMPD/proc"
mkdir -p "$P/net" "$P/4242/fd" "$P/5151/fd" "$P/6161/fd"
ln -s 'socket:[222]' "$P/4242/fd/3"
ln -s 'socket:[333]' "$P/4242/fd/4"
ln -s /dev/null "$P/4242/fd/5"
ln -s 'socket:[444]' "$P/4242/fd/6"
ln -s 'socket:[111]' "$P/5151/fd/3"
ln -s 'socket:[222]' "$P/5151/fd/4"
ln -s /dev/null "$P/6161/fd/0"
cat > "$P/net/unix" <<'UNIX'
Num       RefCount Protocol Flags    Type St Inode Path
0000000000000000: 00000002 00000000 00010000 0001 01   111 /run/user/1000/wayland-0
0000000000000000: 00000002 00000000 00010000 0001 01   222 /run/user/1000/wayland-1
0000000000000000: 00000003 00000000 00000000 0001 03   333 /run/user/1000/wayland-0
0000000000000000: 00000002 00000000 00010000 0001 01   444 /run/user/1000/sway-ipc.1000.4242.sock
UNIX
desk_user_sh() {  # run the script in the local shell
  while [[ "${1:-}" == --* ]]; do shift 2; done
  proc="$P" bash -c "$2"
}
got=$(desk_compositor_socket u 4242 2>/dev/null)
expect socket.new-pid "0 wayland-1" "$? $got"
desk_compositor_socket u 5151 >/dev/null 2>&1
expect socket.two-listeners 1 "$?"
desk_compositor_socket u 6161 >/dev/null 2>&1
expect socket.no-listener 1 "$?"
desk_compositor_socket u "" >/dev/null 2>&1
expect socket.no-pid 1 "$?"
rdl="$TMPD/rdl"
mkdir -p "$rdl"
touch "$rdl/wayland-0" "$rdl/wayland-0.lock" "$rdl/wayland-1" "$rdl/wayland-1.lock"
printf '1: FLOCK  ADVISORY  WRITE 9999 00:1a:%s 0 EOF\n2: FLOCK  ADVISORY  WRITE 7171 00:1a:%s 0 EOF\n' \
  "$(stat -c %i "$rdl/wayland-0.lock")" "$(stat -c %i "$rdl/wayland-1.lock")" > "$P/locks"
got=$(XDG_RUNTIME_DIR="$rdl" desk_compositor_socket u 7171 2>/dev/null)
expect socket.locked-by-pid "0 wayland-1" "$? $got"
XDG_RUNTIME_DIR="$rdl" desk_compositor_socket u 8181 >/dev/null 2>&1
expect socket.no-fd-no-lock 1 "$?"
mkdir -p "$P/7272" "$P/7373"
printf '7272 (kwin_wayland) S 7171 7171 7171 0 -1\n' > "$P/7272/stat"
printf '7373 (kwin_wayland) S 1 1 1 0 -1\n' > "$P/7373/stat"
got=$(XDG_RUNTIME_DIR="$rdl" desk_compositor_socket u 7272 2>/dev/null)
expect socket.locked-by-parent "0 wayland-1" "$? $got"
XDG_RUNTIME_DIR="$rdl" desk_compositor_socket u 7373 >/dev/null 2>&1
expect socket.lock-of-no-parent 1 "$?"
mkdir -p "$TMPD/listing"
touch "$TMPD/listing/wayland-0" "$TMPD/listing/wayland-1"
expect fixture.listing-picks-old wayland-0 "$(ls "$TMPD/listing" | grep -E '^wayland-[0-9]+$' | head -1)"
ssh_vm() { shift 2; bash -c "$1"; }
printf 'deskuser\n' > "$TMPD/desktop-user"
expect user.file deskuser "$(DESK_USER_FILE="$TMPD/desktop-user" desk_user_name)"
expect user.no-file ubuntu "$(DESK_USER_FILE="$TMPD/absent" desk_user_name)"
expect user.env-wins named "$(DESK_USER=named DESK_USER_FILE="$TMPD/desktop-user" desk_user_name)"
ssh_vm() { return 255; }
DESK_USER_FILE="$TMPD/desktop-user" desk_user_name >/dev/null 2>&1
expect user.no-answer 1 "$?"
echo BEHAVIOR_DONE
EOF
)
  rm -rf "$tmp"
  grep -qx BEHAVIOR_DONE <<<"$out" \
    || echo "FAIL behavior.incomplete: the behavior run over $1 stopped before its last test"
  out=$(grep -vx BEHAVIOR_DONE <<<"$out")
  [[ -n "$out" ]] && printf '%s\n' "$out"
  return 0
}

# check each start script for rule breaches
starts_static() {
  local f name code hits
  for f in "$@"; do
    name=$(basename "$f" .sh)
    code=$(grep -nv '^[[:space:]]*#' "$f")
    grep -q 'DESK_CLEAR_SESSION_SOCKETS' <<<"$code" \
      || echo "FAIL static.$name.clear: $f never clears a dead session's sockets through DESK_CLEAR_SESSION_SOCKETS"
    grep -qE '=\$\(desk_compositor_socket ' <<<"$code" \
      || echo "FAIL static.$name.socket-by-pid: $f never takes its socket name from desk_compositor_socket"
    grep -qE '=\$\(desk_seat_compositor_wait ' <<<"$code" \
      || echo "FAIL static.$name.seat-attach: $f's login mode never attaches through desk_seat_compositor_wait"
    hits=$(grep -E 'head -1' <<<"$code" | grep -E 'wayland-|sway-ipc' | cut -d: -f1 | tr '\n' ' ')
    [[ -z "$hits" ]] \
      || echo "FAIL static.$name.listing-pick: $f picks a socket by listing the runtime dir (lines $hits)"
    hits=$(grep -E 'desk_compositor_context +"[^"]*" *(\)|;|$)' <<<"$code" | cut -d: -f1 | tr '\n' ' ')
    [[ -z "$hits" ]] \
      || echo "FAIL static.$name.context-mode: $f calls desk_compositor_context with no login|rig mode (lines $hits)"
    hits=$(grep -E "(pkill|rm -f).*;[[:space:]]*(true|sleep [0-9.]+)[[:space:]]*['\"]" <<<"$code" | cut -d: -f1 | tr '\n' ' ')
    [[ -z "$hits" ]] \
      || echo "FAIL static.$name.hidden-cleanup: $f ends a pkill/rm body in '; true' or '; sleep' (lines $hits)"
    hits=$(grep -E 'mode --custom' <<<"$code" \
      | grep -vE 'mode --custom [1-9][0-9]*x[1-9][0-9]*@[1-9][0-9]*(\.[0-9]+)?Hz' | cut -d: -f1 | tr '\n' ' ')
    [[ -z "$hits" ]] \
      || echo "FAIL static.$name.custom-mode-refresh: $f spells a custom mode whose refresh is not a literal of at least 1Hz (lines $hits)"
    if grep -qF '.config/sway/config' <<<"$code" && ! grep -qE '=\$\(desk_sway_seat_output ' <<<"$code"; then
      echo "FAIL static.$name.seat-output: $f writes a seat sway config whose output line does not come from desk_sway_seat_output"
    fi
  done
}

# check the upgrade leg of a system test
upgrade_leg_static() {
  local f="$1" name="$2" code="$3" up_at n_start attach hits
  up_at=$(grep -F 'reboot_and_wait "[$leg] after the N upgrade"' <<<"$code" | head -1 | cut -d: -f1)
  if [[ -z "$up_at" ]]; then
    echo "FAIL static.$name.upgrade-anchor: $f has no reboot_and_wait \"[\$leg] after the N upgrade\" for the upgrade-attach rule to measure from"
  else
    n_start=$(grep -F 'systemctl start androidd.service' <<<"$code" | awk -F: -v at="$up_at" '$1 > at { print $1; exit }')
    attach=$(grep -E '(\./|\.\./\.\./vm/start/)start-sway\.sh([[:space:]]|$)' <<<"$code" | grep -v -- '--stage-login' \
      | awk -F: -v a="$up_at" -v b="${n_start:-0}" '$1 > a && $1 < b { print $1; exit }')
    [[ -n "$n_start" && -n "$attach" ]] \
      || echo "FAIL static.$name.upgrade-attach: $f starts N's sandbox (line ${n_start:-none}) after the upgrade's reboot (line $up_at) with no ./start-sway.sh between"
  fi
  hits=$(grep -E 'am start -n \$fixture_pkg' <<<"$code" | cut -d: -f1 | tr '\n' ' ')
  [[ -z "$hits" ]] \
    || echo "FAIL static.$name.fixture-am-start: $f starts the fixture with a bare am start (lines $hits)"
  grep -qE 'rhizo-launch\.sh \$fixture_pkg \$fixture_act' <<<"$code" \
    || echo "FAIL static.$name.fixture-launch: $f never relaunches the fixture through rhizo-launch.sh"
  hits=$(grep -E 'apt-get install -y' <<<"$code" | grep -v 'TEST_APT_OFFLINE_CONF' | cut -d: -f1 | tr '\n' ' ')
  [[ -z "$hits" ]] \
    || echo "FAIL static.$name.guest-apt-online: $f runs apt-get install outside the offline pool (lines $hits)"
}

# check system tests stage the desktop user
callers_static() {
  local f name code install_at start_after user_at login_at
  for f in "$@"; do
    name=$(basename "$f" .sh)
    code=$(grep -nv '^[[:space:]]*#' "$f" | grep -vE '^[0-9]+:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\(\)')
    upgrade_leg_static "$f" "$name" "$code"
    install_at=$(grep -E '(^|[^A-Za-z0-9_])installer_install_reboot_prepare([[:space:]]|$)' <<<"$code" | head -1 | cut -d: -f1)
    if [[ -z "$install_at" ]]; then
      echo "FAIL static.$name.install-anchor: $f never calls installer_install_reboot_prepare; update the rule's anchor or drop $f from CALLERS"
      continue
    fi
    start_after=$(grep -E '((\./|\.\./\.\./vm/start/)start-sway\.sh|(^|[^A-Za-z0-9_])desk_session_up)([[:space:]]|$)' <<<"$code" \
      | grep -v -- '--stage-login' | awk -F: -v at="$install_at" '$1 > at { print $1; exit }')
    if [[ -z "$start_after" ]]; then
      echo "FAIL static.$name.start-anchor: $f starts no bare ./start-sway.sh or desk_session_up after installing at line $install_at; update the rule's anchor or drop $f from CALLERS"
      continue
    fi
    user_at=$(grep -E '(^|[^A-Za-z0-9_])installer_stage_desktop_user[[:space:]]' <<<"$code" | head -1 | cut -d: -f1)
    login_at=$(grep -E '((\./|\.\./\.\./vm/start/)start-sway\.sh|(^|[^A-Za-z0-9_])desk_session_up)[[:space:]].*--stage-login' <<<"$code" \
      | head -1 | cut -d: -f1)
    [[ -n "$user_at" ]] && (( user_at < install_at )) \
      || echo "FAIL static.$name.desktop-user-staged: $f starts the desktop bare at line $start_after after installing at line $install_at, but puts no person at uid 1000 (installer_stage_desktop_user) before the install${user_at:+ (its call is at line $user_at)}"
    [[ -n "$login_at" ]] && (( login_at < install_at )) \
      || echo "FAIL static.$name.seat-login-staged: $f starts the desktop bare at line $start_after after installing at line $install_at but stages no --stage-login before the install${login_at:+ (its call is at line $login_at)}"
  done
}

# run the behavior and static checks
check() {
  lib_behavior "$1"
  shift
  starts_static "$@"
}

# write an edited copy of src to dst
plant() {
  python3 - "$@" <<'EOF'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src).read()
if old not in text:
    sys.exit(f"plant: {src} no longer carries the anchor {old[:60]!r}")
open(dst, "w").write(text.replace(old, new, 1))
EOF
}

SELF_TMP=""
trap '[[ -n "$SELF_TMP" ]] && rm -rf "$SELF_TMP"' EXIT

# run each plant against the checks
selftest() {
  local tmp bad=0 out name want
  SELF_TMP=$(mktemp -d) || { echo "FAIL: mktemp -d" >&2; return 1; }
  tmp="$SELF_TMP"
  out=$(check "$LIB" "${STARTS[@]}"; callers_static "${CALLERS[@]}")
  if [[ -n "$out" ]]; then
    echo "SELFTEST FAIL: the real tree is not clean:" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  echo "SELFTEST OK: the real lib, both start scripts and the installing system test are clean"

  plant "$LIB" "$tmp/lib-context.sh" '[[ "$mode" == rig && "$ctx" != *:* ]]' '[[ "$ctx" != *:* ]]' || return 1
  plant "$LIB" "$tmp/lib-clear.sh" '  && ! ls -A "$XDG_RUNTIME_DIR"' '  ; true || ! ls -A "$XDG_RUNTIME_DIR"' || return 1
  plant "$LIB" "$tmp/lib-socket.sh" '&& index(ids, " " $7 " ")' '' || return 1
  plant "$LIB" "$tmp/lib-dies.sh" '  local user="$1" pid="$2" out n' '  exit 0' || return 1
  plant "$LIB" "$tmp/lib-seat-label.sh" '[[ "$kind" != policy || "$psl" == *:rhizo_host:* ]]' '[[ -n "$psl" ]]' || return 1
  plant "$LIB" "$tmp/lib-seat-order.sh" '_seat_usec_ok "$comp" && (( 10#$comp <= 10#$pol ))' 'false' || return 1
  plant "$LIB" "$tmp/lib-seat-greeter.sh" 'p+=("greeter.no-session: logind started no session of $greeter this boot")' ':' || return 1
  plant "$LIB" "$tmp/lib-seat-poll.sh" 'initializing|starting) echo "starting $sys"; return 0 ;;' 'initializing) ;;' || return 1
  plant "$LIB" "$tmp/lib-seat-hz.sh" "printf 'output * mode --custom %s@%sHz\\n' \"\$size\" \"\$hz\"" \
    "printf 'output * mode --custom %s%s\\n' \"\$size\" \"\${2:+@\${2}Hz}\"" || return 1
  plant "$LIB" "$tmp/lib-seat-zero.sh" '[[ "$hz" =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]]' '[[ "$hz" =~ ^[0-9.]+$ ]]' || return 1
  plant "${STARTS[0]}" "$tmp/start-sway.sh" 'desk_compositor_context "$sway_pid" "$ctx_mode"' \
    'desk_compositor_context "$sway_pid"' || return 1
  plant "$tmp/start-sway.sh" "$tmp/start-sway.sh" 'sway_pid=$(desk_seat_compositor_wait "$DESKTOP_USER" sway)' \
    'sway_pid=$(desk_user_sh --user "$DESKTOP_USER" 10 "pgrep -x sway")' || return 1
  plant "$tmp/start-sway.sh" "$tmp/start-sway.sh" 'desk_user_sh --user "$DESKTOP_USER" 15 "$DESK_CLEAR_SESSION_SOCKETS"' \
    "desk_user_sh --user \"\$DESKTOP_USER\" 15 'rm -f \"\$XDG_RUNTIME_DIR\"/wayland-* \"\$XDG_RUNTIME_DIR\"/sway-ipc.*; sleep 1'" || return 1
  plant "$tmp/start-sway.sh" "$tmp/start-sway.sh" 'sway_seat_conf="${sway_common}${seat_output}' \
    'sway_seat_conf="${sway_common}output * mode --custom ${OUTPUT_SIZE}${OUTPUT_REFRESH:+@${OUTPUT_REFRESH}Hz}' || return 1
  plant "$tmp/start-sway.sh" "$tmp/start-sway.sh" 'seat_output=$(desk_sway_seat_output "$OUTPUT_SIZE" "$OUTPUT_REFRESH")' \
    'seat_output="output * mode $OUTPUT_SIZE"' || return 1
  plant "${STARTS[1]}" "$tmp/start-gnome.sh" 'WL_SOCK=$(desk_compositor_socket "$DESKTOP_USER" "$unit_pid" 2>/dev/null)' \
    "WL_SOCK=\$(as_user 8 'ls \"\$XDG_RUNTIME_DIR\" | grep -E \"^wayland-[0-9]+\$\" | head -1')" || return 1
  plant "$tmp/start-gnome.sh" "$tmp/start-gnome.sh" 'sock=$(desk_compositor_socket "$DESKTOP_USER" "$unit_pid" 2>/dev/null)' \
    'sock=$(as_user 8 "test -S \"\$XDG_RUNTIME_DIR/wayland-0\" && echo present")' || return 1
  plant "$tmp/start-gnome.sh" "$tmp/start-gnome.sh" 'WL_SOCK=$(desk_compositor_socket "$DESKTOP_USER" "$unit_pid"); then' \
    "WL_SOCK=\$(as_user 8 'ls \"\$XDG_RUNTIME_DIR\" | grep -E \"^wayland-[0-9]+\$\"'); then" || return 1
  plant "$tmp/start-gnome.sh" "$tmp/start-gnome.sh" 'unit_pid=$(desk_seat_compositor_wait "$DESKTOP_USER" gnome-shell)' \
    'unit_pid=$(as_user 10 "pgrep -x gnome-shell")' || return 1
  plant "$tmp/start-gnome.sh" "$tmp/start-gnome.sh" \
    '{ ! mountpoint -q $WAYLAND_SHARE_DIR/wayland-0 || umount $WAYLAND_SHARE_DIR/wayland-0; } && rm -f $GNOME_LOG"' \
    'umount $WAYLAND_SHARE_DIR/wayland-0 2>/dev/null; rm -f $GNOME_LOG; true"' || return 1
  plant "${CALLERS[0]}" "$tmp/test-installer-user.sh" \
    '    installer_stage_desktop_user "$leg" "$INSTALLER_DESKTOP_HUMAN" || return 1' ':' || return 1
  plant "${CALLERS[0]}" "$tmp/test-installer-login.sh" \
    '../../vm/start/start-sway.sh --stage-login --user "$INSTALLER_DESKTOP_HUMAN"' '../../vm/start/start-sway.sh --user "$INSTALLER_DESKTOP_HUMAN"' || return 1
  python3 - "${CALLERS[0]}" "$tmp/test-installer-late.sh" <<'PY' || return 1
import sys
src, dst = sys.argv[1:3]
lines = open(src).read().split("\n")
call = '  test_pkgwin rhizo-install step7-install installer_install_reboot_prepare "$leg" || return 1'
if lines.count(call) != 1:
    sys.exit(f"plant: {src} no longer carries one {call!r}")
at = lines.index(call)
first = next(i for i, l in enumerate(lines) if 'installer_stage_desktop_user "$leg"' in l)
moved = lines.pop(first)
lines.insert(at, moved)
open(dst, "w").write("\n".join(lines))
PY
  plant "${CALLERS[0]}" "$tmp/test-installer-upgrade-attach.sh" \
    'if ! ../../vm/start/start-sway.sh >"$EV/$leg-sway-after-upgrade.log" 2>&1; then' \
    'if ! true >"$EV/$leg-sway-after-upgrade.log" 2>&1; then' || return 1
  plant "${CALLERS[0]}" "$tmp/test-installer-am-start.sh" \
    'ssh_vm -t 300 "/usr/lib/rhizo/tools/rhizo-launch.sh $fixture_pkg $fixture_act >/tmp/rhizo-test-fixture-relaunch.log 2>&1; echo rc=\$?"' \
    'ANDROID_SH_TIMEOUT=20 android_sh "$n_init" "am start -n $fixture_pkg/$fixture_act"' || return 1
  plant "${CALLERS[0]}" "$tmp/test-installer-apt-online.sh" \
    '    adb_path=$(ssh_vm -t 20 '"'"'command -v adb 2>/dev/null'"'"' | tr -d '"'"'[:space:]'"'"')' \
    "    ssh_vm -t 60 'command -v adb >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y android-tools-adb'" || return 1
  python3 - "${CALLERS[0]}" "$tmp" <<'PY' || return 1
import sys
src, tmp = sys.argv[1:3]
text = open(src).read()
for name, old, new in (("renamed", "installer_install_reboot_prepare", "installer_install_and_reboot"),
                       ("wrapped", "../../vm/start/start-sway.sh >", "desk_start_bare >")):
    if old not in text:
        sys.exit(f"plant: {src} no longer carries {old!r}")
    open(f"{tmp}/test-installer-{name}.sh", "w").write(text.replace(old, new))
PY

  while IFS='|' read -r name want; do
    case "$name" in
      lib-*) out=$(check "$tmp/$name.sh" "${STARTS[@]}") ;;
      test-*) out=$(callers_static "$tmp/$name.sh") ;;
      *) out=$(check "$LIB" "$tmp/$name.sh") ;;
    esac
    if grep -q "^FAIL $want" <<<"$out"; then
      echo "SELFTEST OK: $name is caught as $want"
    else
      echo "SELFTEST FAIL: $name was not caught as $want: ${out:-<clean>}" >&2
      bad=1
    fi
  done <<'PLANTS'
lib-context|context.login-kernel:
lib-clear|clear.survivor-fails:
lib-socket|socket.new-pid:
lib-dies|behavior.incomplete:
lib-seat-label|seat.ps-kernel:
lib-seat-order|seat.compositor-before-policy:
lib-seat-greeter|seat.no-greeter:
lib-seat-poll|poll.starting:
lib-seat-hz|seat-output.default-refresh:
lib-seat-zero|seat-output.zero-refused:
start-sway|static.start-sway.context-mode:
start-sway|static.start-sway.seat-attach:
start-sway|static.start-sway.hidden-cleanup:
start-sway|static.start-sway.clear:
start-sway|static.start-sway.custom-mode-refresh:
start-sway|static.start-sway.seat-output:
start-gnome|static.start-gnome.socket-by-pid:
start-gnome|static.start-gnome.listing-pick:
start-gnome|static.start-gnome.seat-attach:
start-gnome|static.start-gnome.hidden-cleanup:
test-installer-user|static.test-installer-user.desktop-user-staged:
test-installer-login|static.test-installer-login.seat-login-staged:
test-installer-late|static.test-installer-late.desktop-user-staged:
test-installer-renamed|static.test-installer-renamed.install-anchor:
test-installer-wrapped|static.test-installer-wrapped.start-anchor:
test-installer-upgrade-attach|static.test-installer-upgrade-attach.upgrade-attach:
test-installer-am-start|static.test-installer-am-start.fixture-am-start:
test-installer-am-start|static.test-installer-am-start.fixture-launch:
test-installer-apt-online|static.test-installer-apt-online.guest-apt-online:
PLANTS
  (( bad )) && return 1
  echo "check-desk-session-start selftest: every reverted fix is caught by name"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  "") ;;
  *) echo "usage: desk-session-start.sh [--selftest]" >&2; exit 2 ;;
esac
out=$(check "$LIB" "${STARTS[@]}"; callers_static "${CALLERS[@]}")
if [[ -n "$out" ]]; then
  printf '%s\n' "$out" >&2
  exit 1
fi
echo "desk session start: the compositor's own pid names its socket and IPC, leftover sockets must be gone, login mode requires rhizo_host, an installing system test stages its seat login first and attaches after the upgrade before relaunching through rhizo-launch.sh"
