#!/bin/bash
# run guest commands for the desktop user
# shellcheck disable=SC2034

[[ -n "${DESK_USER_LIB_SOURCED:-}" ]] && return 0
DESK_USER_LIB_SOURCED=1

# run a script for the desktop user
desk_user_sh() {
  local user="${DESK_USER:-}" envs=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user) user="$2"; shift 2 ;;
      --env) envs+=" $(printf '%q' "$2")"; shift 2 ;;
      *) break ;;
    esac
  done
  local t="$1" b64 uq
  b64=$(printf '%s' "$2" | base64 -w0)
  uq=$(printf '%q' "$user")
  ssh_vm -t "$t" "_dus='$b64'; _du=$uq
[ -n \"\$_du\" ] || _du=\$(tr -d '[:space:]' 2>/dev/null < /etc/rhizo/desktop-user)
[ -n \"\$_du\" ] || _du=ubuntu
_duid=\$(id -u \"\$_du\" 2>/dev/null) || { echo \"desk_user_sh: no account \$_du on the guest\" >&2; exit 97; }
_dh=\$(getent passwd \"\$_du\" | cut -d: -f6)
_drd=/run/user/\$_duid
exec runuser -u \"\$_du\" -- env HOME=\"\$_dh\" USER=\"\$_du\" LOGNAME=\"\$_du\" XDG_RUNTIME_DIR=\"\$_drd\" DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$_drd/bus\" PATH=/usr/local/bin:/usr/bin:/bin$envs /bin/bash -c \"\$(printf %s \"\$_dus\" | base64 -d)\""
}

DESK_SWAY_GETTY_DROPIN=/etc/systemd/system/getty@tty1.service.d/autologin.conf
DESK_SWAY_PROFILE_MARK="# rhizo vm: start sway at the tty1 login"

DESK_UNSTAGE_SWAY=$(cat <<'EOF'
set -u
u=$1 d=$2 mark=$3
h=$(getent passwd "$u" | cut -d: -f6)
[ -n "$h" ] || { echo "no home directory for $u"; exit 1; }
if [ -e "$d" ]; then
  rm -f "$d" || exit 1
  rmdir --ignore-fail-on-non-empty "$(dirname "$d")" || exit 1
  systemctl daemon-reload || exit 1
  for s in $(loginctl list-sessions --no-legend | awk -v u="$u" '$3 == u && $5 == "tty1" { print $1 }'); do
    loginctl terminate-session "$s" || exit 1
  done
  systemctl restart getty@tty1.service || exit 1
  echo GETTY_UNSTAGED
else
  echo GETTY_NONE
fi
if grep -qxF "$mark" "$h/.profile" 2>/dev/null; then
  runuser -u "$u" -- sed -i "/^$mark\$/,/^fi\$/d" "$h/.profile" || exit 1
  if grep -qxF "$mark" "$h/.profile"; then echo "the block is still in $h/.profile"; exit 1; fi
  echo PROFILE_UNSTAGED
else
  echo PROFILE_NONE
fi
echo DONE
EOF
)

# remove the sway login from the vm
desk_unstage_sway_login() {
  local out
  out=$(ssh_vm -t 90 "bash -s -- $(printf '%q' "$1") $DESK_SWAY_GETTY_DROPIN $(printf '%q' "$DESK_SWAY_PROFILE_MARK")" \
    <<<"$DESK_UNSTAGE_SWAY" 2>&1)
  printf '%s\n' "$out"
  [[ "$out" == *$'\n'DONE ]]
}

DESK_STOP_GREETER=$(cat <<'EOF'
set -- $(loginctl list-sessions --no-legend | awk -v c=greeter '$6 == c {print $1, $2}')
systemctl stop display-manager.service || { echo "display-manager.service did not stop"; exit 1; }
while [ $# -ge 2 ]; do
  for u in "session-$1.scope" "user@$2.service"; do
    systemctl stop "$u" 2>/dev/null || [ "$(systemctl show -p LoadState --value "$u")" != loaded ] \
      || { echo "$u of the greeter (uid $2) did not stop"; exit 1; }
  done
  left=$(pgrep -u "$2" -l | tr "\n" " ")
  [ -z "$left" ] || { echo "the greeter account (uid $2) still runs $left"; exit 1; }
  shift 2
done
systemctl is-active display-manager.service
EOF
)

# print the desktop user account name
desk_user_name() {
  if [[ -n "${DESK_USER:-}" ]]; then printf '%s\n' "$DESK_USER"; return 0; fi
  local f out
  f=$(printf '%q' "${DESK_USER_FILE:-/etc/rhizo/desktop-user}")
  out=$(ssh_vm -t 10 "u=; if [ -e $f ]; then u=\$(tr -d '[:space:]' < $f) || exit 1; fi; echo \"\${u:-ubuntu}\"") || return 1
  out=${out//$'\r'/}
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# copy a guest file to the host
desk_user_pull() {
  local src="$1" dst="$2" t="${3:-30}" out
  rm -f "$dst"
  out=$(desk_user_sh "$t" "base64 -w0 < $(printf '%q' "$src") && echo && echo RHIZO_PULL_DONE" 2>/dev/null)
  if [[ "$out" != *$'\n'RHIZO_PULL_DONE ]]; then
    echo "desk_user_pull: reading $src as the desktop user did not complete" >&2
    return 1
  fi
  out=${out%$'\n'RHIZO_PULL_DONE}
  if [[ "$out" == *$'\n'* ]] || ! printf '%s' "$out" | base64 -d > "$dst" 2>/dev/null; then
    rm -f "$dst"
    echo "desk_user_pull: $src, read as the desktop user, is not one clean base64 line" >&2
    return 1
  fi
}

# print the desktop session mode
desk_session_mode() {
  local want="${RHIZO_DESK_SESSION:-auto}" out rc
  case "$want" in
    login|rig) printf '%s\n' "$want"; return 0 ;;
    auto) ;;
    *) echo "desk_session_mode: RHIZO_DESK_SESSION='$want', want login, rig or auto" >&2; return 2 ;;
  esac
  out=$(guest_android_enforce); rc=$?
  if (( rc == 2 )); then
    out=$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce 2>/dev/null; echo; echo RHIZO_ENFORCE_READ' 2>/dev/null)
    if [[ "$out" != *RHIZO_ENFORCE_READ* ]]; then
      echo "desk_session_mode: could not read /sys/fs/selinux/enforce on the guest" >&2
      return 1
    fi
    out=$(head -1 <<<"$out" | tr -d '[:space:]')
  elif (( rc != 0 )); then
    echo "desk_session_mode: could not read Android's enforce state on the guest: $out" >&2
    return 1
  fi
  if [[ "$out" == 1 ]]; then printf 'login\n'; else printf 'rig\n'; fi
}

# print the security context of a compositor
desk_compositor_context() {
  local pid="$1" mode="${2:-}" ctx out lsm
  case "$mode" in
    login|rig|stock) ;;
    *) echo "desk_compositor_context: mode '$mode', want login, rig or stock" >&2; return 2 ;;
  esac
  out=$(ssh_vm -t 10 "tr -d '\\000' < /proc/$pid/attr/current 2>/dev/null; echo; echo \"LSM=\$(cat /sys/kernel/security/lsm)\"; [ -d /proc/$pid ] && echo ALIVE" | tr -d '\r')
  ctx=$(head -1 <<<"$out")
  lsm=$(sed -n 's/^LSM=//p' <<<"$out")
  if [[ -z "$ctx" && "$mode" == stock && "$out" == *$'\n'ALIVE && -n "$lsm" && ",$lsm," != *,selinux,* \
        && ",$lsm," != *,apparmor,* && ",$lsm," != *,smack,* ]]; then
    printf '<none: lsm=%s labels no process>\n' "$lsm"
    return 0
  fi
  printf '%s\n' "${ctx:-<unreadable>}"
  [[ -n "$ctx" ]] || return 1
  [[ "$mode" == stock ]] && return 0
  [[ "$ctx" == *:rhizo_host:* ]] && return 0
  [[ "$mode" == rig && "$ctx" != *:* ]]
}

# print the compositor context mode
desk_login_context_mode() {
  local out
  out=$(ssh_vm -t 10 'if [ -e /sys/fs/selinux/enforce ] && [ "$(tr -d "\000" < /proc/1/attr/current 2>/dev/null)" != kernel ]; then echo login; else echo stock; fi; echo DONE' 2>/dev/null)
  case "$out" in
    $'login\nDONE'|$'stock\nDONE') printf '%s\n' "${out%%$'\n'*}" ;;
    *) echo "desk_login_context_mode: could not read /sys/fs/selinux on the guest: ${out:-<nothing>}" >&2; return 1 ;;
  esac
}

DESK_SWAY_SEAT_HZ=60

# print the sway output line for a mode
desk_sway_seat_output() {
  local size="$1" hz="${2:-$DESK_SWAY_SEAT_HZ}"
  [[ "$size" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] \
    || { echo "desk_sway_seat_output: size '$size', want WxH" >&2; return 2; }
  [[ "$hz" =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]] \
    || { echo "desk_sway_seat_output: refresh '$hz', want a number of Hz of at least 1" >&2; return 2; }
  printf 'output * mode --custom %s@%sHz\n' "$size" "$hz"
}

DESK_CLEAR_SESSION_SOCKETS=$(cat <<'EOF'
rm -f "$XDG_RUNTIME_DIR"/wayland-* "$XDG_RUNTIME_DIR"/sway-ipc.* \
  && ! ls -A "$XDG_RUNTIME_DIR" 2>/dev/null | grep -qE '^(wayland-[0-9]|sway-ipc\.)'
EOF
)

DESK_PID_WAYLAND_LISTENERS=$(cat <<'EOF'
proc=${proc:-/proc}
ids=" $(for f in "$proc/$pid"/fd/*; do readlink "$f"; done 2>/dev/null \
  | sed -n 's/^socket:\[\([0-9]*\)\]$/\1/p' | tr '\n' ' ')"
if [ "$ids" = " " ]; then
  held=""
  ppid=$(awk '{ sub(/.*\) /, ""); print $2 }' "$proc/$pid/stat" 2>/dev/null)
  for l in "${XDG_RUNTIME_DIR:?}"/wayland-*.lock; do
    [ -e "$l" ] || continue
    ino=$(stat -c %i "$l") || continue
    awk -v pid="$pid" -v ppid="${ppid:-0}" -v ino="$ino" '($5 == pid || $5 == ppid) && $6 ~ (":" ino "$") { f = 1 } END { exit !f }' "$proc/locks" \
      && held="$held ${l##*/}"
  done
  [ -n "$held" ] || { echo "no socket fd of pid $pid is readable, and neither it nor its parent ${ppid:-?} holds a wayland lock in $XDG_RUNTIME_DIR" >&2; exit 1; }
  for l in $held; do echo "${l%.lock}"; done
  exit 0
fi
awk -v ids="$ids" 'NR > 1 && $4 == "00010000" && $8 ~ /\/wayland-[0-9]+$/ && index(ids, " " $7 " ") {
  n = split($8, p, "/"); print p[n] }' "$proc/net/unix"
EOF
)

# print the wayland socket a pid listens on
desk_compositor_socket() {
  local user="$1" pid="$2" out n
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "desk_compositor_socket: '$pid' is not a pid" >&2; return 1; }
  out=$(desk_user_sh --user "$user" 10 "pid=$pid
$DESK_PID_WAYLAND_LISTENERS") || { echo "desk_compositor_socket: could not read pid $pid's sockets: $out" >&2; return 1; }
  n=$(grep -c . <<<"$out")
  if [[ "$n" != 1 ]]; then
    echo "desk_compositor_socket: pid $pid listens on $n wayland sockets, want 1: $(tr '\n' ' ' <<<"$out")" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

DESK_WAYLAND_LISTENERS=$(cat <<'EOF'
{ awk 'NR > 1 && $8 ~ /\/wayland-[0-9]+$/ { print $8 }' /proc/net/unix || echo "unreadable: /proc/net/unix"; } | sort -u
EOF
)

DESK_SEAT_READ=$(cat <<'EOF'
uid=$(id -u "$u" 2>/dev/null)
echo "UID=$uid"
s=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
echo "SEAT_ACTIVE=$s"
[ -z "$s" ] || loginctl show-session "$s" -p Id -p Name -p Seat -p Active -p State -p Class -p Service \
  -p TimestampMonotonic 2>/dev/null | sed 's/^/SESSION_/'
systemctl show rhizo-policy.service -p LoadState -p ActiveState -p ActiveEnterTimestampMonotonic 2>/dev/null \
  | sed 's/^/POLICY_/'
[ -z "$s" ] || echo "SESSION_VTNr=$(loginctl show-session "$s" -p VTNr --value 2>/dev/null)"
lp=$(systemctl show systemd-logind.service -p MainPID --value 2>/dev/null)
if [ -n "$lp" ] && [ "$lp" != 0 ] && readlink "/proc/$lp/fd/0" >/dev/null 2>&1; then
  echo "LOGIND_TTYS=$(for f in /proc/"$lp"/fd/*; do readlink "$f"; done 2>/dev/null | grep -x '/dev/tty[0-9]*' | sort -u | tr '\n' ' ')"
fi
pids=""
[ -z "$uid" ] || pids=$(pgrep -u "$uid" -x "$comm" 2>/dev/null | tr '\n' ' ')
echo "COMP_PIDS=$pids"
set -- $pids
if [ $# -eq 1 ]; then
  echo "COMP_PS=$(ps -o uid=,label= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //')"
  cg=$(sed -n 's/^0:://p' "/proc/$1/cgroup" 2>/dev/null)
  echo "COMP_CGROUP=$cg"
  case "$cg" in
    */user@*.service/*) ;;
    */*.scope|*/*.service)
      echo "COMP_UNIT_START=$(systemctl show "${cg##*/}" -p InactiveExitTimestampMonotonic --value 2>/dev/null)" ;;
  esac
fi
journalctl -b -o json --no-pager MESSAGE_ID=8d45620c1a4348dbb17410da57c60c66 2>/dev/null | while IFS= read -r l; do
  m=$(printf '%s' "$l" | sed -n 's/.*"__MONOTONIC_TIMESTAMP":"\([0-9]*\)".*/\1/p')
  n=$(printf '%s' "$l" | sed -n 's/.*"USER_ID":"\([^"]*\)".*/\1/p')
  i=$(printf '%s' "$l" | sed -n 's/.*"SESSION_ID":"\([^"]*\)".*/\1/p')
  echo "LOGIND_START=$m $n $i"
done
if [ -n "$greeter" ]; then
  guid=$(id -u "$greeter" 2>/dev/null)
  echo "GREETER_UID=$guid"
  [ -z "$guid" ] || echo "GREETER_SHELL_FIRST=$(journalctl -b -o json --no-pager _UID="$guid" _COMM="$comm" 2>/dev/null \
    | head -1 | sed -n 's/.*"__MONOTONIC_TIMESTAMP":"\([0-9]*\)".*/\1/p')"
fi
echo DONE
EOF
)

# print the seat login state from the guest
desk_seat_read() {
  local user="$1" comm="$2" greeter="$3" out pid cg sock="" ustart
  out=$(ssh_vm -t 60 "u=$(printf '%q' "$user"); comm=$(printf '%q' "$comm"); greeter=$(printf '%q' "$greeter")
$DESK_SEAT_READ" 2>/dev/null)
  if [[ "$out" != DONE && "$out" != *$'\n'DONE ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  out=${out%DONE}
  pid=$(sed -n 's/^COMP_PIDS=\([0-9][0-9]*\) *$/\1/p' <<<"$out")
  cg=$(sed -n 's/^COMP_CGROUP=//p' <<<"$out")
  if [[ -n "$pid" ]]; then
    sock=$(desk_compositor_socket "$user" "$pid" 2>/dev/null)
    if [[ "$cg" == */user@*.service/* ]]; then
      ustart=$(desk_user_sh --user "$user" 15 "systemctl --user show $(printf '%q' "${cg##*/}") -p InactiveExitTimestampMonotonic --value" 2>/dev/null)
      out+="COMP_UNIT_START=$(tr -d '[:space:]' <<<"$ustart")"$'\n'
    fi
  fi
  printf '%sSOCKET=%s\nDONE\n' "$out" "$sock"
}

# return true for a positive number
_seat_usec_ok() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 )); }

# check the seat login read for problems
desk_seat_verdict() {
  local user="$1" service="$2" greeter="$3" read="$4" line kind=unknown starts="" psu="" psl="" cg
  local sess pol comp gs="" gsh="" uid sid vt="" held=""
  local -A v=()
  local -a p=() pids=()
  if [[ "$read" != DONE && "$read" != *$'\n'DONE ]]; then
    echo "kind=unknown"
    echo "read.incomplete: the guest read never reached DONE: $(tail -3 <<<"${read:-<empty>}" | tr '\n' ' ')"
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      LOGIND_START=*) starts+="${line#LOGIND_START=}"$'\n' ;;
      *=*) v[${line%%=*}]=${line#*=} ;;
    esac
  done <<<"$read"
  uid=${v[UID]:-} sid=${v[SESSION_Id]:-} sess=${v[SESSION_TimestampMonotonic]:-}
  pol=${v[POLICY_ActiveEnterTimestampMonotonic]:-} comp=${v[COMP_UNIT_START]:-} cg=${v[COMP_CGROUP]:-}
  case "${v[POLICY_LoadState]:-}" in
    loaded) kind=policy ;;
    not-found) kind=stock ;;
    *) p+=("policy.load-state-unread: rhizo-policy.service's LoadState read '${v[POLICY_LoadState]:-<none>}'") ;;
  esac
  [[ "$uid" =~ ^[0-9]+$ ]] || p+=("user.unknown: no uid for $user ('$uid')")
  if [[ -z "${v[SEAT_ACTIVE]:-}" ]]; then
    p+=("seat.no-active-session: seat0 has no active session")
  else
    [[ "${v[SESSION_Name]:-}" == "$user" ]] \
      || p+=("seat.not-desktop-user: seat0's active session $sid belongs to '${v[SESSION_Name]:-<none>}', not $user")
    [[ "${v[SESSION_Seat]:-}" == seat0 ]] || p+=("seat.not-seat0: session $sid reads seat '${v[SESSION_Seat]:-<none>}'")
    [[ "${v[SESSION_Active]:-}" == yes && "${v[SESSION_State]:-}" == active ]] \
      || p+=("seat.not-active: session $sid reads Active=${v[SESSION_Active]:-<none>} State=${v[SESSION_State]:-<none>}")
    [[ "${v[SESSION_Class]:-}" == user ]] || p+=("seat.not-user-class: session $sid is class '${v[SESSION_Class]:-<none>}'")
    [[ "${v[SESSION_Service]:-}" == "$service" ]] \
      || p+=("seat.not-staged-login: session $sid came from PAM service '${v[SESSION_Service]:-<none>}', not $service")
    _seat_usec_ok "$sess" || p+=("seat.timestamp-unread: session $sid's TimestampMonotonic read '$sess'")
    if [[ "$service" == login ]]; then
      vt=${v[SESSION_VTNr]:-}
      if [[ ! "$vt" =~ ^[1-9][0-9]*$ ]]; then
        p+=("seat.no-vt: session $sid, a console login, reads VTNr '${vt:-<none>}'")
      elif [[ -z "${v[LOGIND_TTYS]+set}" ]]; then
        p+=("seat.vt-unread: systemd-logind's open files were not read")
      elif [[ " ${v[LOGIND_TTYS]} " != *" /dev/tty$vt "* ]]; then
        p+=("seat.no-vt-control: logind holds no /dev/tty$vt for session $sid (it holds: ${v[LOGIND_TTYS]:-<none>})")
      else
        held="; logind holds its /dev/tty$vt"
      fi
    fi
  fi
  read -r -a pids <<<"${v[COMP_PIDS]:-}"
  if (( ${#pids[@]} != 1 )); then
    p+=("compositor.not-one: uid ${uid:-?} runs ${#pids[@]} compositor process(es): ${v[COMP_PIDS]:-<none>}")
  else
    read -r psu psl <<<"${v[COMP_PS]:-}"
    if [[ -z "$psl" ]]; then
      p+=("compositor.ps-unreadable: ps -Z of pid ${pids[0]} read '${v[COMP_PS]:-}'")
    else
      [[ "$psu" == "$uid" ]] || p+=("compositor.not-desktop-uid: pid ${pids[0]} runs as uid $psu, not $uid")
      [[ "$kind" != policy || "$psl" == *:rhizo_host:* ]] \
        || p+=("compositor.not-rhizo-host: pid ${pids[0]} runs in '$psl' on a host with Rhizo's policy")
    fi
    if [[ -z "$cg" ]]; then
      p+=("compositor.cgroup-unread: no cgroup read for pid ${pids[0]}")
    elif [[ -n "$sid" && "$cg" == */session-"$sid".scope ]]; then
      :
    elif [[ "$service" == gdm-* || "$service" == plasmalogin-* || "$service" == sddm-* ]] \
        && [[ "$cg" == */user@"$uid".service/session.slice/* ]]; then
      _seat_usec_ok "$comp" && _seat_usec_ok "$sess" && (( 10#$comp <= 10#$sess )) \
        && p+=("order.compositor-before-session: ${cg##*/} started at ${comp}us, session $sid at ${sess}us")
    else
      p+=("compositor.outside-seat-login: pid ${pids[0]} runs in $cg, not session $sid's scope")
    fi
    _seat_usec_ok "$comp" || p+=("compositor.unit-start-unread: ${cg##*/}'s InactiveExitTimestampMonotonic read '$comp'")
    [[ -n "${v[SOCKET]:-}" ]] || p+=("compositor.no-wayland-socket: pid ${pids[0]} listens on no single wayland socket")
  fi
  if [[ "$kind" == policy ]]; then
    [[ "${v[POLICY_ActiveState]:-}" == active ]] || p+=("policy.not-active: rhizo-policy.service is '${v[POLICY_ActiveState]:-<none>}'")
    if ! _seat_usec_ok "$pol"; then
      p+=("policy.timestamp-unread: rhizo-policy.service's ActiveEnterTimestampMonotonic read '$pol'")
    else
      _seat_usec_ok "$sess" && (( 10#$sess <= 10#$pol )) \
        && p+=("order.session-before-policy: session $sid at ${sess}us, rhizo-policy.service active at ${pol}us")
      _seat_usec_ok "$comp" && (( 10#$comp <= 10#$pol )) \
        && p+=("order.compositor-before-policy: ${cg##*/} started at ${comp}us, rhizo-policy.service active at ${pol}us")
    fi
  fi
  if [[ -n "$greeter" ]]; then
    gs=$(awk -v g="$greeter" '$2 == g { print $1; exit }' <<<"$starts")
    gsh=${v[GREETER_SHELL_FIRST]:-}
    if ! _seat_usec_ok "$gs"; then
      p+=("greeter.no-session: logind started no session of $greeter this boot")
    else
      _seat_usec_ok "$sess" && (( 10#$gs >= 10#$sess )) \
        && p+=("greeter.after-user-session: $greeter's session at ${gs}us, $user's at ${sess}us")
      [[ "$kind" == policy ]] && _seat_usec_ok "$pol" && (( 10#$gs <= 10#$pol )) \
        && p+=("order.greeter-before-policy: $greeter's session at ${gs}us, rhizo-policy.service active at ${pol}us")
    fi
    if ! _seat_usec_ok "$gsh"; then
      p+=("greeter.compositor-never-ran: no journal line from $greeter's (uid ${v[GREETER_UID]:-?}) compositor this boot")
    else
      _seat_usec_ok "$sess" && (( 10#$gsh >= 10#$sess )) \
        && p+=("greeter.compositor-after-user-session: $greeter's compositor first logged at ${gsh}us, $user's session at ${sess}us")
    fi
  fi
  echo "kind=$kind"
  if (( ${#p[@]} )); then
    printf '%s\n' "${p[@]}"
    return 1
  fi
  echo "ok: $kind boot, session $sid ($service) of $user active on seat0 from ${sess}us$held; compositor pid ${pids[0]} uid $psu $psl in ${cg##*/} from ${comp}us on ${v[SOCKET]}${pol:+; rhizo-policy.service active from ${pol}us}${gs:+; greeter $greeter session from ${gs}us, its compositor from ${gsh}us}"
}

DESK_SEAT_POLL=$(cat <<'EOF'
uid=$(id -u "$u" 2>/dev/null)
echo "UID=$uid"
echo "SYSTEM=$(systemctl is-system-running 2>/dev/null)"
[ -z "$uid" ] || echo "PIDS=$(pgrep -u "$uid" -x "$comm" 2>/dev/null | tr '\n' ' ')"
echo DONE
EOF
)

# print the state of a seat poll
desk_seat_poll_judge() {
  local read="$1" sys
  local -a pids=()
  if [[ "$read" != *$'\n'DONE ]]; then
    echo "wait the poll never reached DONE: $(tail -2 <<<"${read:-<empty>}" | tr '\n' ' ')"
    return 0
  fi
  sys=$(sed -n 's/^SYSTEM=//p' <<<"$read")
  case "$sys" in initializing|starting) echo "starting $sys"; return 0 ;; esac
  if [[ -z "$(sed -n 's/^UID=\([0-9][0-9]*\)$/\1/p' <<<"$read")" ]]; then
    echo "wait no such account"
    return 0
  fi
  read -r -a pids <<<"$(sed -n 's/^PIDS=//p' <<<"$read")"
  case "${#pids[@]}" in
    1) echo "ready ${pids[0]}" ;;
    0) echo "wait none runs yet (system ${sys:-<unread>})" ;;
    *) echo "wait ${#pids[@]} run: ${pids[*]}" ;;
  esac
}

# wait for the seat compositor pid
desk_seat_compositor_wait() {
  local user="$1" comm="$2" start=$SECONDS settled="" out judged="" pid
  while (( SECONDS - start < 2400 )); do
    out=$(ssh_vm -t 15 "u=$(printf '%q' "$user"); comm=$(printf '%q' "$comm")
$DESK_SEAT_POLL" 2>/dev/null)
    judged=$(desk_seat_poll_judge "$out")
    case "$judged" in
      starting*) settled="" ;;
      *) [[ -n "$settled" ]] || settled=$SECONDS ;;
    esac
    if [[ "$judged" == "ready "* ]]; then
      pid=${judged#ready }
      if desk_compositor_socket "$user" "$pid" >/dev/null 2>&1; then
        printf '%s\n' "$pid"
        return 0
      fi
      judged="wait pid $pid listens on no single wayland socket yet"
    fi
    [[ -n "$settled" ]] && (( SECONDS - settled >= 240 )) && break
    sleep 2
  done
  echo "desk_seat_compositor_wait: no $comm of $user came up on the seat login: $judged" >&2
  return 1
}
