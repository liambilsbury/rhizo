#!/bin/bash
# start a KWin session in the vm
# shellcheck disable=SC2319
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ../common.sh
source ./render-node-relabel.sh
source ../../system/lib/desk-user-lib.sh

HARNESS_DIR="/tmp/rhizo-plasma-harness"
KDE_INJECT="/usr/local/bin/kde-inject"
KDE_VOUT="/usr/local/bin/kde-virtual-output"
VOUT_UNITS="rhizo-virtual-output-*"
UNIT="rhizo-kwin"
INJECT_UNIT="rhizo-kde-inject"
INJECT_FIFO="/tmp/rhizo-plasma-inject.fifo"
INJECT_OUT="/tmp/rhizo-plasma-inject.out"
WATCH_UNIT="rhizo-notify-watch"
NOTIFY_REC="/tmp/rhizo-plasma-notif.jsonl"
NOTIFY_OUT="/tmp/rhizo-plasma-notify-watch.out"
NOTIFY_SERVER="/tmp/rhizo-plasma-notif.server"
LAUNCHER_UNITS="rhizo-launcher-*"
RIG_SOCKET="wayland-0"
DROPIN="90-rhizo-test.conf"
ENVD_DIR=".config/environment.d"
ENVD_REL="$ENVD_DIR/90-rhizo-test.conf"
PERMISSION_VAR="KWIN_WAYLAND_NO_PERMISSION_CHECKS"

# set the guest root and saved directory
set_root() {
  GUEST_ROOT="$1"
  SAVED_DIR="$GUEST_ROOT/var/lib/rhizo-plasma-login"
}
set_root ""

# print a FAIL line
log_fail() { log "FAIL: $*"; }
# print the epoch second plus $1
deadline() { echo $(( $(date +%s) + $1 )); }

# run a script through desk_user_sh
as_user() { desk_user_sh --user "$DESKTOP_USER" "$@"; }
# run the plasma harness command as the desktop user
harness() { as_user "${2:-20}" "python3 $HARNESS_DIR/plasma-harness.py $1"; }

KWIN_LISTENS=$(cat <<'EOF'
ids=" $(for f in /proc/"$pid"/fd/*; do readlink "$f"; done 2>/dev/null \
  | sed -n 's/^socket:\[\([0-9]*\)\]$/\1/p' | tr '\n' ' ')"
[ "$ids" != " " ] || { echo "no socket fd of pid $pid is readable" >&2; exit 1; }
awk -v ids="$ids" -v rd="$rd" 'NR > 1 && $4 == "00010000" && index($8, rd "/wayland-") == 1 \
  && $8 !~ /\.lock$/ && index(ids, " " $7 " ") { print substr($8, length(rd) + 2) }' /proc/net/unix
EOF
)

# print the wayland socket names of kwin
kwin_sockets() { ssh_vm -t 10 "pid=$1 rd=$RUNTIME_DIR
$KWIN_LISTENS"; }

# print the ActiveState of a user unit
unit_state() {
  as_user 10 "if test -S \"\$XDG_RUNTIME_DIR/systemd/private\"; then systemctl --user show -p ActiveState --value $1; else echo no-manager; fi" \
    2>/dev/null | tr -d '[:space:]'
}

# stop a user unit
stop_unit() {
  local state
  state=$(unit_state "$1")
  case "$state" in
    inactive|no-manager) ;;
    failed)
      as_user 10 "systemctl --user reset-failed $1" || { log_fail "could not reset the failed $1 unit"; return 1; } ;;
    active|activating|deactivating|reloading)
      as_user 20 "systemctl --user stop $1" || { log_fail "systemctl --user stop $1 failed"; return 1; } ;;
    *) log_fail "$1's ActiveState read '${state:-<nothing>}' -- the user manager did not answer"; return 1 ;;
  esac
  state=$(unit_state "$1")
  [[ "$state" == inactive || "$state" == no-manager ]] || { log_fail "$1 is still '$state' after stopping it"; return 1; }
}

stop_system_unit() {
  local state
  state=$(ssh_vm -t 10 "systemctl show -p ActiveState --value $1" 2>/dev/null | tr -d '[:space:]')
  case "$state" in
    inactive) ;;
    failed) ssh_vm -t 10 "systemctl reset-failed $1" || { log_fail "could not reset the failed $1 unit"; return 1; } ;;
    active|activating|deactivating|reloading)
      ssh_vm -t 20 "systemctl stop $1" || { log_fail "systemctl stop $1 failed"; return 1; } ;;
    *) log_fail "$1's ActiveState read '${state:-<nothing>}' -- systemd did not answer"; return 1 ;;
  esac
  state=$(ssh_vm -t 10 "systemctl show -p ActiveState --value $1" 2>/dev/null | tr -d '[:space:]')
  [[ "$state" == inactive ]] || { log_fail "$1 is still '$state' after stopping it"; return 1; }
}

# stop the rig unit
stop_rig() {
  local end
  stop_unit "$UNIT" || return 1
  end=$(deadline 30)
  until as_user 10 "! awk -v p=\"\$XDG_RUNTIME_DIR/$RIG_SOCKET\" 'NR > 1 && \$8 == p { f = 1 } END { exit !f }' /proc/net/unix"; do
    (( $(date +%s) < end )) || break
    sleep 1
  done
  as_user 10 "! awk -v p=\"\$XDG_RUNTIME_DIR/$RIG_SOCKET\" 'NR > 1 && \$8 == p { f = 1 } END { exit !f }' /proc/net/unix" \
    || { log_fail "a process still listens on $RUNTIME_DIR/$RIG_SOCKET with $UNIT stopped: $(ssh_vm -t 10 "ss -xlpn | grep -F '$RUNTIME_DIR/$RIG_SOCKET '" 2>&1 | tr -s ' ' | tr '\n' ' ')"; return 1; }
  as_user 10 "rm -f \"\$XDG_RUNTIME_DIR/$RIG_SOCKET\" \"\$XDG_RUNTIME_DIR/$RIG_SOCKET.lock\" && test ! -e \"\$XDG_RUNTIME_DIR/$RIG_SOCKET\"" \
    || { log_fail "could not remove $RUNTIME_DIR/$RIG_SOCKET after $UNIT stopped"; return 1; }
}

# succeed when the rig socket's only listener is the seat login's kwin
seat_kwin_holds_rig_socket() {
  local out
  [[ "$(unit_state "$UNIT")" == inactive || "$(unit_state "$UNIT")" == no-manager ]] || return 1
  out=$(ssh_vm -t 10 "rd=$RUNTIME_DIR; for pid in \$(pgrep -u $DESKTOP_UID -x kwin_wayland); do
  socks=\$($KWIN_LISTENS)
  case \" \$(echo \$socks) \" in *' $RIG_SOCKET '*) ;; *) continue ;; esac
  case \"\$(cat /proc/\$pid/cgroup)\" in
    */session.slice/plasma-kwin_wayland.service|*/session-*.scope) echo SEAT=\$pid ;;
    *) echo OTHER=\$pid ;;
  esac
done" 2>/dev/null)
  [[ "$out" == SEAT=* && "$out" != *$'\n'* ]] || return 1
  log "the seat login's kwin (pid ${out#SEAT=}) holds $RUNTIME_DIR/$RIG_SOCKET with $UNIT inactive"
}

# stop the session's units and delete their files
stop_helpers() {
  local out
  stop_system_unit "$INJECT_UNIT" || return 1
  stop_unit "$WATCH_UNIT" || return 1
  out=$(as_user 20 "if test -S \"\$XDG_RUNTIME_DIR/systemd/private\"; then
  systemctl --user stop '$LAUNCHER_UNITS' '$VOUT_UNITS' || exit 1
  left=\$(systemctl --user list-units --state=active,activating,deactivating,reloading --no-legend --plain '$LAUNCHER_UNITS' '$VOUT_UNITS') \
    || { echo 'systemctl --user list-units did not answer'; exit 1; }
  [ -z \"\$left\" ] || { echo \"a launcher or virtual output unit still runs: \$left\"; exit 1; }
fi
rm -f $INJECT_FIFO $INJECT_OUT $NOTIFY_OUT $NOTIFY_REC $NOTIFY_SERVER /tmp/rhizo-plasma-launcher-*.out" 2>&1) \
    || { log_fail "the launchers' units or the helpers' files outlived the stop: $(tr '\n' ' ' <<<"$out")"; return 1; }
}

# write the keyboard layout to kxkbrc
write_layout() {
  as_user 15 "kwriteconfig6 --file kxkbrc --group Layout --key Use --type bool true \
&& kwriteconfig6 ${2:-} --file kxkbrc --group Layout --key LayoutList $1" \
    || { log_fail "kwriteconfig6 could not write layout $1 to $DESKTOP_USER's kxkbrc"; return 1; }
}

# wait for kwin to list the layout
await_layout() {
  local got="" end
  end=$(deadline 10)
  while :; do
    got=$(harness layouts 10 2>&1)
    [[ "$got" == "$1" ]] && { log "kwin's keyboard layouts read '$got'"; return 0; }
    (( $(date +%s) < end )) || break
    sleep 0.5
  done
  log_fail "kwin's keyboard layouts read '$got' 10s after writing $1 to kxkbrc"
  return 1
}

# write the lock and display settings
write_session_prefs() {
  as_user 15 "kwriteconfig6 ${1:-} --file kscreenlockerrc --group Daemon --key Autolock --type bool false \
&& kwriteconfig6 ${1:-} --file kscreenlockerrc --group Daemon --key LockOnResume --type bool false \
&& kwriteconfig6 ${1:-} --file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle --type bool false \
&& kwriteconfig6 ${1:-} --file powerdevilrc --group AC --group Display --key DimDisplayWhenIdle --type bool false \
&& kwriteconfig6 ${1:-} --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 0 \
&& kwriteconfig6 ${1:-} --file kwinrc --group Windows --key FocusStealingPreventionLevel --delete" \
    || { log_fail "kwriteconfig6 could not write $DESKTOP_USER's kscreenlockerrc, powerdevilrc and kwinrc settings"; return 1; }
}

reconfigure_kwin() {
  as_user 10 "busctl --user call org.kde.KWin /KWin org.kde.KWin reconfigure" >/dev/null \
    || { log_fail "kwin did not take its reconfigure call"; return 1; }
}

# unlock the screen and turn outputs on
refresh_lock() {
  local ss="busctl --user call org.freedesktop.ScreenSaver /ScreenSaver" active end
  as_user 10 "$ss org.kde.screensaver configure" >/dev/null \
    || { log_fail "kwin's screen locker did not take its configure call"; return 1; }
  active=$(as_user 10 "$ss org.freedesktop.ScreenSaver GetActive")
  if [[ "$active" == "b false" ]]; then wake_outputs "$2"; return; fi
  [[ "$active" == "b true" ]] || { log_fail "kwin's screen locker answered GetActive with '${active:-nothing}'"; return 1; }
  ssh_vm -t 10 "loginctl unlock-session $1" || { log_fail "loginctl could not unlock session $1"; return 1; }
  end=$(deadline 10)
  while :; do
    active=$(as_user 10 "$ss org.freedesktop.ScreenSaver GetActive")
    [[ "$active" == "b false" ]] && { log "the session was locked: unlocked through logind"; break; }
    (( $(date +%s) < end )) || { log_fail "kwin's screen locker still reads '$active' 10s after loginctl unlock-session $1"; return 1; }
    sleep 0.5
  done
  wake_outputs "$2"
}

# turn the outputs on
wake_outputs() {
  local kd="WAYLAND_DISPLAY=$1 QT_QPA_PLATFORM=wayland kscreen-doctor" modes
  modes=$(as_user 15 "$kd --dpms show" 2>&1)
  grep -q '^dpms mode for screen .*: off$' <<<"$modes" || return 0
  as_user 15 "$kd --dpms on" >/dev/null 2>&1 || { log_fail "kscreen-doctor --dpms on failed"; return 1; }
  modes=$(as_user 15 "$kd --dpms show" 2>&1)
  grep -q '^dpms mode for screen .*: on$' <<<"$modes" && ! grep -q '^dpms mode for screen .*: off$' <<<"$modes" \
    || { log_fail "an output's power still reads off after kscreen-doctor --dpms on: $(tr '\n' ' ' <<<"$modes")"; return 1; }
  log "an output was off: turned on"
}

# restart the display-manager.service unit
dm_restart() {
  ssh_vm -t 60 'dm=$(systemctl show -p Id --value display-manager.service) && systemctl reset-failed "$dm" && systemctl restart "$dm"' \
    || { log_fail "display-manager.service did not restart"; return 1; }
}

# print the display-manager.service journal
dm_journal() {
  ssh_vm -t 20 'journalctl -b --no-pager -n 40 -u "$(systemctl show -p Id --value display-manager.service)"'
}

# print the sddm or plasmalogin drop-in directory
dm_confd() {
  local out dm target
  out=$(ssh_vm -t 10 'echo "DM=$(systemctl show -p Id --value display-manager.service)"; echo "TARGET=$(systemctl get-default)"' 2>&1)
  dm=$(sed -n 's/^DM=//p' <<<"$out"); target=$(sed -n 's/^TARGET=//p' <<<"$out")
  [[ "$target" == graphical.target ]] \
    || { log_fail "this host boots ${target:-<unread>}, where no display manager starts"; return 1; }
  case "$dm" in
    plasmalogin.service) echo "$GUEST_ROOT/etc/plasmalogin.conf.d" ;;
    sddm.service) echo "$GUEST_ROOT/etc/sddm.conf.d" ;;
    *) log_fail "display-manager.service is '${dm:-<unread>}', not plasmalogin.service or sddm.service"; return 1 ;;
  esac
}

# print the login variables on one line
login_vars() {
  printf 'u=%q uid=%s home=$(getent passwd %q | cut -d: -f6) rundir=%q confd=%q dropin=%q envd=%q envd_dir=%q saved=%q var=%q' \
    "$DESKTOP_USER" "$DESKTOP_UID" "$DESKTOP_USER" "$GUEST_ROOT/run/user/$DESKTOP_UID" "$1" "$DROPIN" "$ENVD_REL" \
    "$ENVD_DIR" "$SAVED_DIR" "$PERMISSION_VAR"
}

LOGIN_STAGE=$(cat <<'EOF'
set -u
as() { runuser -u "$u" -- "$@"; }
if [ ! -e "$saved/saved" ]; then
  rm -rf "$saved" && mkdir -p "$saved" && chmod 700 "$saved" && echo "$confd" > "$saved/confd" || exit 1
  if [ -d "$confd" ]; then
    if [ -e "$confd/$dropin" ]; then cp -p "$confd/$dropin" "$saved/dropin.orig" || exit 1; fi
  else : > "$saved/confd.absent" || exit 1; fi
  if as test -e "$home/$envd"; then
    as cat "$home/$envd" > "$saved/envd.orig" && as stat -c %a "$home/$envd" > "$saved/envd.mode" || exit 1
  fi
  : > "$saved/envd.created" || exit 1
  as test -d "$home/$envd_dir" || echo "$home/$envd_dir" > "$saved/envd.created" || exit 1
  if as test -S "$rundir/systemd/private"; then
    menv=$(as env XDG_RUNTIME_DIR="$rundir" systemctl --user show-environment) || exit 1
    printf '%s\n' "$menv" | grep -E "^$var=" > "$saved/manager-env"
    [ -e "$saved/manager-env" ] || exit 1
  fi
  : > "$saved/saved" || exit 1
fi
mkdir -p "$confd" && printf '[Autologin]\nUser=%s\nSession=plasma\n' "$u" > "$confd/$dropin" || exit 1
as mkdir -p "$home/$envd_dir" || exit 1
printf '%s=1\n' "$var" | as sh -c 'cat > "$1"' sh "$home/$envd" || exit 1
echo "DROPIN=$(tr '\n' ' ' < "$confd/$dropin")"
echo "ENVD=$(as cat "$home/$envd" | tr '\n' ' ')"
echo DONE
EOF
)

LOGIN_RESTORE=$(cat <<'EOF'
set -u
as() { runuser -u "$u" -- "$@"; }
dfile="$confd/$dropin" efile="$home/$envd"
if [ -e "$saved/dropin.orig" ]; then
  if cmp -s "$saved/dropin.orig" "$dfile" && [ "$(stat -c %a "$saved/dropin.orig")" = "$(stat -c %a "$dfile")" ]; then
    echo "ALREADY dropin"
  else cp -p "$saved/dropin.orig" "$dfile" || { echo "FAILED dropin: could not put $dfile back"; exit 1; }; fi
elif [ -e "$dfile" ]; then rm -f "$dfile" || { echo "FAILED dropin: could not remove $dfile"; exit 1; }
else echo "ALREADY dropin"; fi
if [ -e "$saved/confd.absent" ]; then
  if [ -e "$confd" ]; then
    rmdir "$confd" || { echo "FAILED confd: $confd holds files it did not hold before: $(ls -A "$confd" | tr '\n' ' ')"; exit 1; }
  else echo "ALREADY confd"; fi
fi
if [ -e "$saved/envd.orig" ]; then
  mode=$(cat "$saved/envd.mode")
  if [ "$(as cat "$efile" 2>/dev/null | cmp -s "$saved/envd.orig" - && as stat -c %a "$efile")" = "$mode" ]; then
    echo "ALREADY envd"
  else as sh -c 'cat > "$1" && chmod "$2" "$1"' sh "$efile" "$mode" < "$saved/envd.orig" \
    || { echo "FAILED envd: could not put $efile back"; exit 1; }; fi
elif as test -e "$efile"; then as rm -f "$efile" || { echo "FAILED envd: could not remove $efile"; exit 1; }
else echo "ALREADY envd"; fi
if [ -s "$saved/envd.created" ]; then
  d=$(cat "$saved/envd.created")
  if as test -e "$d"; then as rmdir "$d" || { echo "FAILED envd-dir: $d holds files it did not hold before"; exit 1; }
  else echo "ALREADY envd-dir"; fi
fi
if [ -e "$saved/dropin.orig" ]; then
  cmp -s "$saved/dropin.orig" "$dfile" && [ "$(stat -c %a "$saved/dropin.orig")" = "$(stat -c %a "$dfile")" ] && echo "SAME dropin"
elif [ ! -e "$dfile" ]; then echo "SAME dropin"; fi
if [ -e "$saved/confd.absent" ]; then [ -e "$confd" ] || echo "SAME confd"; else [ -d "$confd" ] && echo "SAME confd"; fi
if [ -e "$saved/envd.orig" ]; then
  [ "$(as cat "$efile" 2>/dev/null | cmp -s "$saved/envd.orig" - && as stat -c %a "$efile")" = "$(cat "$saved/envd.mode")" ] \
    && echo "SAME envd"
elif ! as test -e "$efile"; then echo "SAME envd"; fi
if [ -s "$saved/envd.created" ]; then as test -e "$(cat "$saved/envd.created")" || echo "SAME envd-dir"
else echo "SAME envd-dir"; fi
echo DONE
EOF
)

# stage the autologin drop-in and run dm_restart
stage_login() {
  local confd out manager
  confd=$(dm_confd) || return 1
  out=$(ssh_vm -t 30 "$(login_vars "$confd")
$LOGIN_STAGE" 2>&1)
  [[ "$out" == *DONE* ]] || { log_fail "staging the login did not complete: $(tr '\n' ' ' <<<"$out")"; return 1; }
  grep -qx "DROPIN=\[Autologin\] User=$DESKTOP_USER Session=plasma " <<<"$out" \
    || { log_fail "$confd/$DROPIN does not read an autologin of $DESKTOP_USER: $(tr '\n' ' ' <<<"$out")"; return 1; }
  grep -qx "ENVD=$PERMISSION_VAR=1 " <<<"$out" \
    || { log_fail "~$DESKTOP_USER/$ENVD_REL does not read $PERMISSION_VAR=1: $(tr '\n' ' ' <<<"$out")"; return 1; }
  write_layout "${LAYOUT:-us}" || return 1
  write_session_prefs || return 1
  manager=$(manager_state) || return 1
  if [[ "$manager" == up ]]; then
    as_user 20 "systemctl --user daemon-reload" || { log_fail "$DESKTOP_USER's user manager did not reload"; return 1; }
  fi
  dm_restart || return 1
  log "seat login staged: $confd/$DROPIN autologs $DESKTOP_USER into plasma, ~$DESKTOP_USER/$ENVD_REL carries $PERMISSION_VAR, layout ${LAYOUT:-us}"
}

# print up or down from the private socket
manager_state() {
  local out
  out=$(as_user 10 'if test -S "$XDG_RUNTIME_DIR/systemd/private"; then echo MANAGER=up; else echo MANAGER=down; fi' 2>&1)
  case "$out" in
    MANAGER=up|MANAGER=down) echo "${out#MANAGER=}" ;;
    *) log_fail "could not read whether $DESKTOP_USER's user manager runs: ${out:-<nothing>}"; return 1 ;;
  esac
}

# undo the staged login
restore_login() {
  local confd out sid end state manager envread vars_before already
  confd=$(ssh_vm -t 10 "cat $SAVED_DIR/confd") || { log_fail "$SAVED_DIR names no display manager drop-in dir"; return 1; }
  out=$(ssh_vm -t 10 "loginctl list-sessions --no-legend") || { log_fail "loginctl list-sessions did not answer"; return 1; }
  sid=$(awk -v u="$DESKTOP_USER" '$3 == u && $4 == "seat0" { print $1; exit }' <<<"$out")
  out=$(ssh_vm -t 30 "$(login_vars "$confd")
$LOGIN_RESTORE" 2>&1)
  if [[ "$out" != *DONE* ]]; then
    log_fail "putting back what the staged login replaced stopped: $(grep '^FAILED' <<<"$out" || tr '\n' ' ' <<<"$out")"
    return 1
  fi
  already=$(sed -n 's/^ALREADY //p' <<<"$out" | tr '\n' ' ')
  [[ -n "$already" ]] && log "already as before, left alone: $already"
  for v in dropin confd envd envd-dir; do
    grep -qx "SAME $v" <<<"$out" || { log_fail "the $v does not read as it was before the staged login: $(tr '\n' ' ' <<<"$out")"; return 1; }
  done
  dm_restart || return 1
  if [[ -n "$sid" ]]; then
    end=$(deadline 60)
    while :; do
      state=$(ssh_vm -t 10 "echo STATE=\$(loginctl show-session $sid -p State --value 2>/dev/null)" 2>/dev/null)
      [[ "$state" == STATE= || "$state" == STATE=closing ]] && break
      (( $(date +%s) < end )) || { log_fail "$DESKTOP_USER's login session $sid still reads '${state:-<no answer>}' 60s after the display manager restarted"; return 1; }
      sleep 1
    done
    log "the staged login's session $sid ended: its State reads '${state#STATE=}' (empty once gone)"
  fi
  manager=$(manager_state) || return 1
  if [[ "$manager" == up ]]; then
    envread=$(ssh_vm -t 10 "if [ -e $SAVED_DIR/manager-env ]; then echo PRESENT; cat $SAVED_DIR/manager-env; else echo ABSENT; fi; echo DONE" 2>&1)
    case "$envread" in
      PRESENT*$'\n'DONE|PRESENT$'\n'DONE) vars_before=$(sed -e '1d' -e '$d' <<<"$envread") ;;
      ABSENT$'\n'DONE) vars_before="" ;;
      *) log_fail "the user manager's environment before the staging did not read: $(tr '\n' ' ' <<<"$envread")"; return 1 ;;
    esac
    if ! grep -q "^$PERMISSION_VAR=" <<<"$vars_before"; then
      as_user 10 "systemctl --user unset-environment $PERMISSION_VAR" \
        || { log_fail "could not unset $PERMISSION_VAR in $DESKTOP_USER's user manager"; return 1; }
    fi
    as_user 20 "systemctl --user daemon-reload" || { log_fail "$DESKTOP_USER's user manager did not reload"; return 1; }
    out=$(as_user 10 "systemctl --user show-environment" 2>&1) || { log_fail "$DESKTOP_USER's user manager environment did not read"; return 1; }
    [[ "$(grep "^$PERMISSION_VAR=" <<<"$out")" == "$(grep "^$PERMISSION_VAR=" <<<"$vars_before")" ]] \
      || { log_fail "$DESKTOP_USER's user manager carries '$(grep "^$PERMISSION_VAR=" <<<"$out")', before the staging '$(grep "^$PERMISSION_VAR=" <<<"$vars_before")'"; return 1; }
  fi
  ssh_vm -t 10 "rm -f $SAVED_DIR/saved" || { log_fail "could not remove $SAVED_DIR/saved"; return 1; }
  ssh_vm -t 10 "rm -rf $SAVED_DIR" || { log_fail "could not remove $SAVED_DIR"; return 1; }
  log "staged login undone: the display manager's $confd and $DESKTOP_USER's environment.d read as before"
}

# restore the recorded staged login
restore_if_staged() {
  local saved
  saved=$(ssh_vm -t 10 "if [ -e $SAVED_DIR/saved ]; then echo SAVED=yes; elif [ -e $SAVED_DIR ]; then echo SAVED=left; else echo SAVED=no; fi" 2>/dev/null)
  case "$saved" in
    SAVED=yes) restore_login ;;
    SAVED=left)
      ssh_vm -t 10 "rm -rf $SAVED_DIR" || { log_fail "could not remove $SAVED_DIR, which a finished restore left"; return 1; }
      log "removed $SAVED_DIR, which a finished restore left without its marker" ;;
    SAVED=no) log "no staged login recorded in $SAVED_DIR" ;;
    *) log_fail "could not read whether a staged login is recorded in $SAVED_DIR"; return 1 ;;
  esac
}

# test staging and restoring the login
selftest() {
  local tmp rc=0 n=0 out snap0 snap
  tmp=$(mktemp -d) || return 1
  local stubs="$tmp/stubs" fx="$tmp/state" home="$tmp/root/home/deskuser"
  mkdir -p "$stubs" "$fx" "$home/.config" "$tmp/root/run/user/1000/systemd" "$tmp/root/var/lib" "$tmp/root/etc"
  cat > "$stubs/runuser" <<'EOF'
#!/bin/bash
[ "$1" = -u ] && [ "$3" = -- ] || { echo "unexpected runuser $*" >&2; exit 64; }
shift 3
exec "$@"
EOF
  cat > "$stubs/getent" <<EOF
#!/bin/bash
[ "\$1 \$2" = "passwd deskuser" ] && echo "deskuser:x:1000:1000::$home:/bin/bash"
EOF
  cat > "$stubs/kwriteconfig6" <<EOF
#!/bin/bash
echo "\$*" >> "$fx/kwriteconfig6"
EOF
  cat > "$stubs/loginctl" <<EOF
#!/bin/bash
case "\$1" in
  list-sessions) cat "$fx/sessions" 2>/dev/null ;;
  show-session) [ -e "$fx/session-live" ] && echo active ;;
  *) echo "unexpected loginctl \$*" >&2; exit 64 ;;
esac
EOF
  cat > "$stubs/systemctl" <<EOF
#!/bin/bash
f="$fx/fail"
case "\$*" in
  "show -p Id --value display-manager.service") echo plasmalogin.service ;;
  get-default) echo graphical.target ;;
  "reset-failed plasmalogin.service") ;;
  "restart plasmalogin.service") [ -e "\$f.dm-restart" ] && exit 1; echo restart >> "$fx/dm" ;;
  "--user daemon-reload") ;;
  "--user show-environment") cat "$fx/manager-env" ;;
  "--user unset-environment "*) [ -e "\$f.unset" ] && exit 1; grep -v "^\$3=" "$fx/manager-env" > "$fx/m.new"; mv "$fx/m.new" "$fx/manager-env" ;;
  *) echo "unexpected systemctl \$*" >&2; exit 64 ;;
esac
EOF
  chmod +x "$stubs"/*
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$tmp/root/run/user/1000/systemd/private"
  printf 'HOME=%s\nLANG=C\n' "$home" > "$fx/manager-env"
  manager_import() { grep -q "^$PERMISSION_VAR=" "$fx/manager-env" || echo "$PERMISSION_VAR=1" >> "$fx/manager-env"; }
  unreached() { [[ -s "$fx/fail.match" && "$1" == *"$(cat "$fx/fail.match")"* ]]; }
  ssh_vm() { [[ "$1" == -t ]] && shift 2; unreached "$1" && return 255; PATH="$stubs:$PATH" bash -c "$1"; }
  as_user() { unreached "$2" && return 255; HOME="$home" XDG_RUNTIME_DIR="$tmp/root/run/user/1000" PATH="$stubs:$PATH" bash -c "$2"; }
  log() { printf '%s\n' "$*" >> "$tmp/log"; }
  DESKTOP_USER=deskuser DESKTOP_UID=1000 LAYOUT=""
  set_root "$tmp/root"
  snapshot() {
    (cd "$tmp/root" && find etc home -printf '%p %y %m\n' | sort && find etc home -type f -exec md5sum {} + | sort)
    cat "$fx/manager-env"
  }
  check() {
    n=$(( n + 1 ))
    if [[ "$2" != 0 ]]; then echo "FAIL $1: $3"; rc=1; fi
  }
  stop_once() {
    : > "$tmp/log"; restore_if_staged; local r=$?
    printf '%s %s' "$r" "$(tr '\n' ' ' < "$tmp/log")"
  }

  snap0=$(snapshot)
  : > "$tmp/log"; stage_login; check stage.clean $? "$(cat "$tmp/log")"
  [[ "$(cat "$tmp/root/etc/plasmalogin.conf.d/$DROPIN")" == $'[Autologin]\nUser=deskuser\nSession=plasma' ]]
  check stage.dropin $? "the drop-in reads $(cat "$tmp/root/etc/plasmalogin.conf.d/$DROPIN" 2>&1)"
  [[ "$(cat "$home/$ENVD_REL")" == "$PERMISSION_VAR=1" ]]; check stage.envd $? "environment.d reads $(cat "$home/$ENVD_REL" 2>&1)"
  grep -qx -- "--file kxkbrc --group Layout --key LayoutList us" "$fx/kwriteconfig6"
  check stage.layout-us $? "kxkbrc writes: $(tr '\n' ';' < "$fx/kwriteconfig6")"
  grep -qx -- "--file kscreenlockerrc --group Daemon --key Autolock --type bool false" "$fx/kwriteconfig6" \
    && grep -qx -- "--file powerdevilrc --group AC --group Display --key TurnOffDisplayWhenIdle --type bool false" "$fx/kwriteconfig6" \
    && grep -qx -- "--file kwinrc --group Windows --key FocusStealingPreventionLevel --delete" "$fx/kwriteconfig6"
  check stage.session-prefs $? "kscreenlockerrc, powerdevilrc and kwinrc writes: $(tr '\n' ';' < "$fx/kwriteconfig6")"
  manager_import
  echo "408 1000 deskuser seat0 1 user tty1 no -" > "$fx/sessions"
  out=$(stop_once); check restore.clean "${out%% *}" "$out"
  [[ "$(snapshot)" == "$snap0" ]]; check restore.clean-as-before $? "$(diff <(echo "$snap0") <(snapshot))"
  [[ ! -e "$SAVED_DIR" ]]; check restore.record-removed $? "$SAVED_DIR is still there"
  out=$(stop_once); [[ "$out" == "0 no staged login recorded"* ]]; check restore.again-no-op $? "$out"

  : > "$tmp/log"; stage_login && stage_login; check stage.twice $? "$(cat "$tmp/log")"
  out=$(stop_once); check restore.after-twice "${out%% *}" "$out"
  [[ "$(snapshot)" == "$snap0" ]]; check restore.twice-as-before $? "$(diff <(echo "$snap0") <(snapshot))"

  mkdir -p "$tmp/root/etc/plasmalogin.conf.d" "$home/$ENVD_DIR"
  printf '[Autologin]\nUser=someone\n' > "$tmp/root/etc/plasmalogin.conf.d/$DROPIN"
  chmod 600 "$tmp/root/etc/plasmalogin.conf.d/$DROPIN"
  printf 'FOO=1\n' > "$home/$ENVD_REL"; chmod 640 "$home/$ENVD_REL"
  manager_import
  local snap3; snap3=$(snapshot)
  : > "$tmp/log"; stage_login; check stage.over-files $? "$(cat "$tmp/log")"
  chmod 600 "$home/$ENVD_REL"
  out=$(stop_once); check restore.over-files "${out%% *}" "$out"
  [[ "$(snapshot)" == "$snap3" ]]; check restore.files-as-before $? "$(diff <(echo "$snap3") <(snapshot))"

  local point inject fix want
  for point in dropin confd envd dm-restart unset saved-probe manager-probe manager-env record; do
    if [[ "$point" == dropin ]]; then
      snap=$snap3
    else
      rm -rf "$tmp/root/etc/plasmalogin.conf.d" "${home:?}/$ENVD_DIR"
      grep -v "^$PERMISSION_VAR=" "$fx/manager-env" > "$fx/m.new"; mv "$fx/m.new" "$fx/manager-env"
      snap=$(snapshot)
    fi
    : > "$tmp/log"; stage_login || { check "stage.$point" 1 "$(cat "$tmp/log")"; continue; }
    manager_import
    case "$point" in
      dropin) inject="chmod 444 $tmp/root/etc/plasmalogin.conf.d/$DROPIN" fix="chmod 644 $tmp/root/etc/plasmalogin.conf.d/$DROPIN"
              want="FAILED dropin" ;;
      confd) inject="touch $tmp/root/etc/plasmalogin.conf.d/other.conf" fix="rm $tmp/root/etc/plasmalogin.conf.d/other.conf"
             want="FAILED confd" ;;
      envd) inject="chmod 555 $home/$ENVD_DIR" fix="chmod 755 $home/$ENVD_DIR" want="could not remove $home/$ENVD_REL" ;;
      dm-restart) inject="touch $fx/fail.dm-restart" fix="rm $fx/fail.dm-restart" want="did not restart" ;;
      unset) inject="touch $fx/fail.unset" fix="rm $fx/fail.unset" want="could not unset" ;;
      saved-probe) inject="echo SAVED= > $fx/fail.match" fix="rm $fx/fail.match"
                   want="could not read whether a staged login is recorded" ;;
      manager-probe) inject="echo MANAGER= > $fx/fail.match" fix="rm $fx/fail.match"
                     want="could not read whether deskuser's user manager runs" ;;
      manager-env) inject="echo PRESENT > $fx/fail.match" fix="rm $fx/fail.match"
                   want="environment before the staging did not read" ;;
      record) inject="echo 'rm -rf $SAVED_DIR' > $fx/fail.match" fix="rm $fx/fail.match"
              want="could not remove $SAVED_DIR" ;;
    esac
    eval "$inject"
    out=$(stop_once 2>/dev/null)
    [[ "$out" == 1* && "$out" == *"$want"* && -d "$SAVED_DIR" ]]
    check "restore.$point-fails" $? "$out"
    eval "$fix"
    out=$(stop_once); check "restore.$point-rerun" "${out%% *}" "$out"
    case "$point" in
      dropin|saved-probe) want="" ;;
      confd) want="already as before, left alone: dropin" ;;
      envd) want="already as before, left alone: dropin confd" ;;
      dm-restart|unset|manager-probe|manager-env) want="already as before, left alone: dropin confd envd envd-dir" ;;
      record) want="which a finished restore left without its marker" ;;
    esac
    [[ "$out" == *"$want"* ]]; check "restore.$point-names-done-steps" $? "$out"
    [[ "$(snapshot)" == "$snap" ]]; check "restore.$point-as-before" $? "$(diff <(echo "$snap") <(snapshot))"
    out=$(stop_once); [[ "$out" == "0 no staged login recorded"* ]]; check "restore.$point-again" $? "$out"
  done
  chmod -R u+w "$tmp"; rm -rf "$tmp"
  (( rc == 0 )) && echo "start-plasma selftest: $n checks, the staged login's restore puts every file back and runs again after each failure"
  return "$rc"
}

if [[ "${1:-}" == --selftest ]]; then
  selftest
  exit $?
fi

MONITORS="1920x1080"
LAYOUT=""
DESKTOP_USER_ARG=""
MODE="start"
START_ARGS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --monitors) MONITORS="$2"; START_ARGS+=" $1"; shift 2 ;;
    --layout) LAYOUT="$2"; START_ARGS+=" $1"; shift 2 ;;
    --user) DESKTOP_USER_ARG="$2"; shift 2 ;;
    --install-only) MODE="install-only"; shift ;;
    --stage-login) MODE="stage-login"; shift ;;
    --set-layout) MODE="set-layout"; LAYOUT="$2"; shift 2 ;;
    --stop) MODE="stop"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$LAYOUT" || "$LAYOUT" =~ ^[a-z]{2,8}$ ]] || { echo "start-plasma.sh: want an xkb layout code, got '$LAYOUT'" >&2; exit 2; }

wait_for_ssh "${RHIZO_PLASMA_SSH_WAIT:-20}" || { log_fail "VM not reachable"; exit 1; }

DESKTOP_USER="$DESKTOP_USER_ARG"
if [[ -z "$DESKTOP_USER" ]]; then
  DESKTOP_USER=$(ssh_vm -t 8 'cat /etc/rhizo/desktop-user 2>/dev/null' | tr -d '[:space:]')
  [[ -n "$DESKTOP_USER" ]] || DESKTOP_USER=$(ssh_vm -t 8 'getent passwd 1000 | cut -d: -f1' | tr -d '[:space:]')
fi
DESKTOP_UID=$(ssh_vm -t 8 "id -u '$DESKTOP_USER' 2>/dev/null" | tr -d '[:space:]')
if [[ -z "$DESKTOP_UID" ]]; then
  log_fail "no such account '$DESKTOP_USER' on the guest -- cannot resolve a uid to run kwin as"
  exit 1
fi
RUNTIME_DIR="/run/user/$DESKTOP_UID"
KWIN_LOG="/tmp/rhizo-kwin-$DESKTOP_UID.log"
log "plasma session: user=$DESKTOP_USER uid=$DESKTOP_UID runtime_dir=$RUNTIME_DIR"

if [[ "$MODE" == set-layout ]]; then
  write_layout "$LAYOUT" --notify && await_layout "$LAYOUT"
  exit $?
fi

if [[ "$MODE" == stop ]]; then
  stop_helpers || exit 1
  restore_if_staged || exit 1
  stop_rig || exit 1
  log "$UNIT, $INJECT_UNIT, $WATCH_UNIT and the launchers stopped (nothing listens on $RUNTIME_DIR/$RIG_SOCKET)"
  exit 0
fi

out=$(ssh_vm -t 20 'for t in kwin_wayland spectacle kscreen-doctor kwriteconfig6 wayland-info wayland-scanner cc pkg-config; do
  command -v "$t" >/dev/null || echo "MISSING $t"; done
[ -r /usr/share/plasma-wayland-protocols/fake-input.xml ] || echo "MISSING plasma-wayland-protocols"
python3 -c "import gi; gi.require_version(\"Gtk\", \"4.0\"); from gi.repository import Gtk" 2>/dev/null || echo "MISSING gtk4 python-gobject"
echo RHIZO_TOOLS_READ' 2>&1)
[[ "$out" == *RHIZO_TOOLS_READ* ]] || { log_fail "the guest's tools could not be read: $out"; exit 1; }
if grep -q '^MISSING' <<<"$out"; then
  log_fail "the guest lacks $(sed -n 's/^MISSING //p' <<<"$out" | tr '\n' ' ')-- tools/build/vm/cachyos-dev.sh's package list carries them"
  exit 1
fi
ssh_vm -t 10 "mkdir -p $HARNESS_DIR && chmod 755 $HARNESS_DIR" || { log_fail "could not create $HARNESS_DIR"; exit 1; }
timeout 30 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" ../../system/guest/plasma-harness.py ../../system/guest/gnome-launcher.py ../../../src/services/deskbridge/dbus_min.py \
  ../../system/inject/kde-inject.c ../../../tools/build/test-tools/kde-inject.sh \
  ../../system/inject/kde-virtual-output.c ../../../tools/build/test-tools/kde-virtual-output.sh "$SSH_TARGET:$HARNESS_DIR/" \
  || { log_fail "could not stage plasma-harness.py, gnome-launcher.py, dbus_min.py and the kde-inject and kde-virtual-output sources to $HARNESS_DIR"; exit 1; }
ssh_vm -t 10 "chmod 644 $HARNESS_DIR/plasma-harness.py $HARNESS_DIR/gnome-launcher.py $HARNESS_DIR/dbus_min.py $HARNESS_DIR/kde-inject.c $HARNESS_DIR/kde-inject.sh $HARNESS_DIR/kde-virtual-output.c $HARNESS_DIR/kde-virtual-output.sh" \
  || { log_fail "could not make the staged harness readable"; exit 1; }
out=$(ssh_vm -t 120 "bash $HARNESS_DIR/kde-inject.sh $HARNESS_DIR/kde-inject.c $KDE_INJECT && echo RHIZO_KDE_INJECT_BUILT" 2>&1)
[[ "$out" == *RHIZO_KDE_INJECT_BUILT* ]] || { log_fail "kde-inject did not build on the guest: $out"; exit 1; }
out=$(ssh_vm -t 120 "bash $HARNESS_DIR/kde-virtual-output.sh $HARNESS_DIR/kde-virtual-output.c $KDE_VOUT && echo RHIZO_KDE_VOUT_BUILT" 2>&1)
[[ "$out" == *RHIZO_KDE_VOUT_BUILT* ]] || { log_fail "kde-virtual-output did not build on the guest: $out"; exit 1; }
log "plasma-harness.py and gnome-launcher.py staged in $HARNESS_DIR, kde-inject built at $KDE_INJECT, kde-virtual-output at $KDE_VOUT"
if [[ "$MODE" == install-only ]]; then
  exit 0
fi

# ping kwin on org.kde.KWin
harness_ping() {
  local out ping_pid
  out=$(harness "await-name org.kde.KWin 30" 40 2>&1) || { log_fail "$out"; return 1; }
  ping_out=$(harness ping 20 2>&1) || { log_fail "plasma-harness.py ping failed: $ping_out"; return 1; }
  ping_pid=$(sed -n 's/^rhizo-harness kwin pid=\([0-9]*\) .*/\1/p' <<<"$ping_out")
  [[ "$ping_pid" == "$1" ]] && return 0
  log_fail "org.kde.KWin is owned by pid ${ping_pid:-?}, but the plasma session's kwin is pid $1 -- another kwin answers"
  return 1
}

# save and check wayland-info for org_kde_kwin_fake_input
check_wayland_info() {
  local info
  info=$(as_user 15 "env WAYLAND_DISPLAY=$1 wayland-info" 2>&1)
  ssh_vm -t 10 "cat > /tmp/rhizo-plasma-wayland-info.txt" <<<"$info" \
    || { log_fail "could not save wayland-info to guest:/tmp/rhizo-plasma-wayland-info.txt"; return 1; }
  log "wayland-info saved to guest:/tmp/rhizo-plasma-wayland-info.txt ($(wc -l <<<"$info") lines)"
  grep -q "'org_kde_kwin_fake_input'" <<<"$info" && return 0
  log_fail "kwin on $1 offers no org_kde_kwin_fake_input"
  return 1
}

# start the kde-inject unit
start_injector() {
  local out end
  stop_system_unit "$INJECT_UNIT" || return 1
  out=$(as_user 20 "rm -f $INJECT_FIFO $INJECT_OUT && mkfifo -m 600 $INJECT_FIFO" 2>&1) \
    || { log_fail "could not make $INJECT_FIFO as $DESKTOP_USER: $out"; return 1; }
  out=$(ssh_vm -t 20 "systemd-run --unit=$INJECT_UNIT --collect --uid=$DESKTOP_USER --gid=$DESKTOP_USER \
  -p Environment=XDG_RUNTIME_DIR=$RUNTIME_DIR -p Environment=WAYLAND_DISPLAY=$1 \
  -- sh -c 'exec $KDE_INJECT <> $INJECT_FIFO > $INJECT_OUT 2>&1'" 2>&1) \
    || { log_fail "the $INJECT_UNIT unit did not start: $out"; return 1; }
  out=$(as_user 10 "echo > $INJECT_FIFO" 2>&1) || { log_fail "could not write $INJECT_FIFO: $out"; return 1; }
  end=$(deadline 10)
  until as_user 10 "grep -qx ok $INJECT_OUT"; do
    (( $(date +%s) < end )) || { log_fail "kde-inject ($INJECT_UNIT) answered no ok within 10s: $(as_user 10 "cat $INJECT_OUT" 2>&1 | tr '\n' ' ')"; return 1; }
    sleep 0.2
  done
  log "the session's input device: kde-inject as $INJECT_UNIT, reading $INJECT_FIFO"
}

# start the rhizo-notify-watch unit
start_watcher() {
  local out end pid kept
  out=$(harness "await-name org.freedesktop.Notifications 30" 40 2>&1) || { log_fail "$out"; return 1; }
  pid=${out##*pid=}
  [[ "$pid" =~ ^[0-9]+$ ]] || { log_fail "await-name named no server pid: $out"; return 1; }
  kept=$(as_user 10 "if [ -e $NOTIFY_SERVER ]; then echo SERVER=\$(cat $NOTIFY_SERVER); else echo SERVER=none; fi" 2>&1)
  [[ "$kept" == SERVER=* ]] || { log_fail "the watcher's server record $NOTIFY_SERVER did not read: $kept"; return 1; }
  if [[ "$(unit_state "$WATCH_UNIT")" == active && "$kept" == "SERVER=$pid" ]]; then
    log "the notification watcher: $WATCH_UNIT already records $NOTIFY_REC for this server (pid $pid), kept"
    return 0
  fi
  stop_unit "$WATCH_UNIT" || return 1
  log "the notification watcher starts a new record: the server is pid $pid, the record's ${kept#SERVER=}"
  out=$(as_user 20 "rm -f $NOTIFY_REC $NOTIFY_OUT $NOTIFY_SERVER && echo $pid > $NOTIFY_SERVER \
&& systemd-run --user --unit=$WATCH_UNIT --collect \
  -p StandardOutput=truncate:$NOTIFY_OUT -p StandardError=truncate:$NOTIFY_OUT \
  -- python3 $HARNESS_DIR/plasma-harness.py notify-watch --record $NOTIFY_REC" 2>&1) \
    || { log_fail "the $WATCH_UNIT unit did not start: $out"; return 1; }
  end=$(deadline 15)
  until as_user 10 "grep -qx ready $NOTIFY_OUT"; do
    (( $(date +%s) < end )) || { log_fail "the notification watcher ($WATCH_UNIT) never said ready within 15s: $(as_user 10 "cat $NOTIFY_OUT" 2>&1 | tr '\n' ' ')"; return 1; }
    sleep 0.2
  done
  log "the notification watcher: $WATCH_UNIT, recording $NOTIFY_REC"
}

# check kwin's environment for $PERMISSION_VAR
check_login_env() {
  local got
  got=$(ssh_vm -t 10 "tr '\\0' '\\n' < /proc/$1/environ" 2>&1 | grep -x "$PERMISSION_VAR=1")
  [[ "$got" == "$PERMISSION_VAR=1" ]] && return 0
  log_fail "the login's kwin (pid $1) does not carry $PERMISSION_VAR=1"
  return 1
}

# reset the outputs with plasma-harness.py
reset_outputs() {
  local out
  out=$(as_user 40 "env WAYLAND_DISPLAY=$1 python3 $HARNESS_DIR/plasma-harness.py outputs $2" 2>&1) \
    || { log_fail "the outputs could not be put back: $out"; return 1; }
  log "outputs $out"
}

# wait for the autologin wayland session
await_login_session() {
  local line end
  end=$(deadline 120)
  while :; do
    line=$(ssh_vm -t 10 "for s in \$(loginctl list-sessions --no-legend | awk -v u=$(printf '%q' "$DESKTOP_USER") '\$3 == u && \$4 == \"seat0\" { print \$1 }'); do
  echo \"\$s \$(loginctl show-session \$s -p Type -p Active -p Service | sort | tr '\\n' ' ')\"; done" 2>/dev/null \
      | grep -E ' Active=yes Service=(plasmalogin|sddm)-autologin Type=wayland $' | head -1)
    [[ -n "$line" ]] && { log "login session: $line"; return 0; }
    (( $(date +%s) < end )) || break
    sleep 1
  done
  log_fail "the display manager logged $DESKTOP_USER into no wayland session on seat0 within 120s -- its journal:"
  dm_journal >&2
  return 1
}

# print the kwin pid and wayland socket
await_login_kwin() {
  local pids sock="" pa=() end
  end=$(deadline 240)
  while :; do
    pids=$(ssh_vm -t 10 "echo PIDS=\$(pgrep -u $DESKTOP_UID -x kwin_wayland)" 2>/dev/null)
    read -r -a pa <<<"${pids#PIDS=}"
    if [[ "$pids" == PIDS=* ]] && (( ${#pa[@]} == 1 )); then
      sock=$(kwin_sockets "${pa[0]}" 2>/dev/null | grep -xE 'wayland-[0-9]+')
      [[ -n "$sock" && "$sock" != *$'\n'* ]] && { echo "${pa[0]} $sock"; return 0; }
    fi
    (( $(date +%s) < end )) || break
    sleep 1
  done
  echo "the last read: '${pids:-no answer}', sockets '${sock//$'\n'/ }'" >&2
  return 1
}

# remove the sway seat login
unstage_sway_login() {
  local out
  out=$(desk_unstage_sway_login "$DESKTOP_USER") \
    || { log_fail "could not take the sway seat login off this vm: $(tr '\n' ' ' <<<"$out")"; return 1; }
  [[ "$out" == *GETTY_UNSTAGED* || "$out" == *PROFILE_UNSTAGED* ]] \
    && log "a sway-profile system test's tty1 login was staged on this vm: $(grep -E '_(UN|NONE)' <<<"$out" | tr '\n' ' ')"
  return 0
}

if [[ "$MODE" == stage-login ]]; then
  SESSION_MODE=login
else
  SESSION_MODE=$(desk_session_mode) || { log_fail "could not decide the session mode"; exit 1; }
fi
log "session mode: $SESSION_MODE"
if [[ "$SESSION_MODE" == login ]]; then
  if [[ "$MODE" == stage-login ]]; then
    [[ "$START_ARGS" != *--monitors* ]] || { log_fail "a seat login runs on the machine's own outputs and cannot take --monitors"; exit 1; }
    stop_helpers || exit 1
    unstage_sway_login || exit 1
    seat_kwin_holds_rig_socket || stop_rig || exit 1
    stage_login || exit 1
    await_login_session || exit 1
  elif [[ -n "$START_ARGS" ]]; then
    log_fail "login mode cannot take$START_ARGS -- stage them with --stage-login"
    exit 1
  fi
  read -r unit_pid WL_SOCK <<<"$(await_login_kwin)"
  if [[ -z "$WL_SOCK" ]]; then
    log_fail "no one kwin_wayland of $DESKTOP_USER listened on one wayland-N within 240s -- the display manager's journal:"
    dm_journal >&2
    exit 1
  fi
  check_login_env "$unit_pid" || exit 1
  check_wayland_info "$WL_SOCK" || exit 1
  harness_ping "$unit_pid" || exit 1
  if [[ "$MODE" != stage-login ]]; then write_session_prefs --notify && reconfigure_kwin || exit 1; fi
  login_sid=$(ssh_vm -t 10 "loginctl list-sessions --no-legend | awk -v u=$(printf '%q' "$DESKTOP_USER") '\$3 == u && \$4 == \"seat0\" { print \$1; exit }'" | tr -d '[:space:]')
  [[ -n "$login_sid" ]] || { log_fail "loginctl lists no seat0 session of $DESKTOP_USER to unlock"; exit 1; }
  refresh_lock "$login_sid" "$WL_SOCK" || exit 1
  if [[ "$MODE" == stage-login ]]; then
    await_layout "${LAYOUT:-us}" || exit 1
    reset_outputs "$WL_SOCK" reset-scale || exit 1
  fi
  ctx_mode=$(desk_login_context_mode) || { log_fail "could not read whether the guest has SELinux"; exit 1; }
  shell_ctx=$(desk_compositor_context "$unit_pid" "$ctx_mode") \
    || { log_fail "kwin_wayland (pid $unit_pid) runs in '$shell_ctx', not rhizo_host"; exit 1; }
  start_injector "$WL_SOCK" || exit 1
  start_watcher || exit 1
  log "kwin up as $DESKTOP_USER (uid $DESKTOP_UID, pid $unit_pid, context $shell_ctx) in the seat login. Wayland socket: $RUNTIME_DIR/$WL_SOCK."
  log "harness: $ping_out"
  exit 0
fi

[[ "$MONITORS" =~ ^[1-9][0-9]*x[1-9][0-9]*(,[1-9][0-9]*x[1-9][0-9]*)*$ ]] \
  || { log_fail "--monitors '$MONITORS' is not WxH[,WxH...]"; exit 1; }
IFS=',' read -r -a SIZE_ARR <<<"$MONITORS"
for s in "${SIZE_ARR[@]}"; do
  [[ "$s" == "${SIZE_ARR[0]}" ]] \
    || { log_fail "--monitors '$MONITORS' asks for outputs of different sizes"; exit 1; }
done
WIDTH=${SIZE_ARR[0]%x*} HEIGHT=${SIZE_ARR[0]#*x} COUNT=${#SIZE_ARR[@]}

greeter_out=$(ssh_vm -t 90 "$DESK_STOP_GREETER" 2>&1)
[[ "$greeter_out" == inactive || "$greeter_out" == failed ]] \
  || { log_fail "could not leave the vm with no display manager and no greeter: $greeter_out"; exit 1; }
unstage_sway_login || exit 1
render_node_relabel "$DESKTOP_UID" || exit 1
ssh_vm -t 10 "loginctl enable-linger $DESKTOP_USER" || { log_fail "loginctl enable-linger $DESKTOP_USER failed"; exit 1; }
log "waiting for the user bus ($RUNTIME_DIR/bus)..."
end=$(deadline 30)
until as_user 6 'test -S "$XDG_RUNTIME_DIR/bus"' >/dev/null 2>&1; do
  (( $(date +%s) < end )) || { log_fail "no user bus at $RUNTIME_DIR/bus 30s after enable-linger"; exit 1; }
  sleep 1
done

stop_helpers || exit 1
stop_rig || exit 1
login_sock=$(as_user 10 "awk -v rd=\"\$XDG_RUNTIME_DIR/\" 'NR > 1 && \$4 == \"00010000\" && index(\$8, rd \"wayland-\") == 1 && \$8 !~ /\\.lock\$/ { print \$8; exit }' /proc/net/unix" 2>/dev/null | tr -d '\r')
[[ -z "$login_sock" ]] || { log_fail "a compositor already listens on $login_sock (a seat login's session): stop it, or attach in login mode"; exit 1; }
write_layout "${LAYOUT:-us}" --notify || exit 1
write_session_prefs || exit 1

log "Starting kwin_wayland --virtual (${COUNT}x ${WIDTH}x${HEIGHT}) on $RIG_SOCKET..."
out=$(as_user 20 "systemd-run --user --unit=$UNIT --collect \
  -E $PERMISSION_VAR=1 -E XDG_SESSION_TYPE=wayland -E QV4_FORCE_INTERPRETER=1 -E QT_FORCE_STDERR_LOGGING=1 \
  ${RHIZO_KWIN_LOGGING_RULES:+-E QT_LOGGING_RULES=$RHIZO_KWIN_LOGGING_RULES} \
  -p StandardOutput=truncate:$KWIN_LOG -p StandardError=truncate:$KWIN_LOG \
  -- kwin_wayland --virtual --no-lockscreen --socket $RIG_SOCKET --width $WIDTH --height $HEIGHT --output-count $COUNT
echo RHIZO_LAUNCH_RC=\$?" 2>&1)
launch_rc=$(grep -oE 'RHIZO_LAUNCH_RC=[0-9]+' <<<"$out" | cut -d= -f2)
[[ "$launch_rc" == 0 ]] || { log_fail "systemd-run did not accept the $UNIT unit (rc=${launch_rc:-unknown}): $out"; exit 1; }

unit_pid=""
end=$(deadline 30)
while :; do
  unit_pid=$(as_user 10 "systemctl --user show -p MainPID --value $UNIT" 2>/dev/null | tr -d '[:space:]')
  [[ "$unit_pid" =~ ^[1-9][0-9]*$ && "$(kwin_sockets "$unit_pid" 2>/dev/null)" == "$RIG_SOCKET" ]] && break
  unit_pid=""
  (( $(date +%s) < end )) || break
  sleep 0.5
done
if [[ -z "$unit_pid" ]]; then
  log_fail "$UNIT never listened on $RUNTIME_DIR/$RIG_SOCKET within 30s -- kwin's log:"
  ssh_vm -t 8 "tail -40 $KWIN_LOG" >&2
  exit 1
fi
log "kwin_wayland (pid $unit_pid) listens on $RUNTIME_DIR/$RIG_SOCKET"
check_wayland_info "$RIG_SOCKET" || exit 1
if ! harness_ping "$unit_pid"; then
  ssh_vm -t 8 "tail -40 $KWIN_LOG" >&2
  exit 1
fi
reset_outputs "$RIG_SOCKET" reset || exit 1
await_layout "${LAYOUT:-us}" || exit 1
start_injector "$RIG_SOCKET" || exit 1
log "kwin up as $DESKTOP_USER (uid $DESKTOP_UID, pid $unit_pid). Wayland socket: $RUNTIME_DIR/$RIG_SOCKET."
log "harness: $ping_out"
