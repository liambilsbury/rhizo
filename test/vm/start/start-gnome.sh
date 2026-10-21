#!/bin/bash
# start headless GNOME Shell in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh
source ./render-node-relabel.sh
source ../../system/lib/desk-user-lib.sh

HARNESS_DIR="/tmp/rhizo-gnome-harness"
EXT_STAGE_DIR="/tmp/rhizo-gnome-ext-stage"
WAYLAND_SHARE_DIR="${RHIZO_WAYLAND_HOST_DIR:-/run/rhizo-wayland}"
UNIT="rhizo-gnome"

SIZES="1920x1080"
XKB_LAYOUT="${RHIZO_GNOME_XKB_LAYOUT:-us}"
DESKTOP_USER_ARG=""
MODE="start"
START_ARGS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZES="$2"; START_ARGS+=" $1"; shift 2 ;;
    --xkb-layout) XKB_LAYOUT="$2"; START_ARGS+=" $1"; shift 2 ;;
    --user) DESKTOP_USER_ARG="$2"; shift 2 ;;
    --install-only) MODE="install-only"; shift ;;
    --stage-login) MODE="stage-login"; shift ;;
    --stop) MODE="stop"; shift ;;
    --status) MODE="status"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SSH_WAIT="${RHIZO_GNOME_SSH_WAIT:-20}"
wait_for_ssh "$SSH_WAIT" || { log "FAIL: VM not reachable"; exit 1; }

DESKTOP_USER="$DESKTOP_USER_ARG"
if [[ -z "$DESKTOP_USER" ]]; then
  DESKTOP_USER=$(ssh_vm -t 8 'cat /etc/rhizo/desktop-user 2>/dev/null' | tr -d '[:space:]')
  [[ -n "$DESKTOP_USER" ]] || DESKTOP_USER=ubuntu
fi
DESKTOP_UID=$(ssh_vm -t 8 "id -u '$DESKTOP_USER' 2>/dev/null" | tr -d '[:space:]')
if [[ -z "$DESKTOP_UID" ]]; then
  log "FAIL: no such account '$DESKTOP_USER' on the guest"
  exit 1
fi
RUNTIME_DIR="/run/user/$DESKTOP_UID"
GNOME_LOG="/tmp/rhizo-gnome-shell-$DESKTOP_UID.log"
log "gnome session: user=$DESKTOP_USER uid=$DESKTOP_UID runtime_dir=$RUNTIME_DIR"

# run a script under the desktop user
as_user() { desk_user_sh --user "$DESKTOP_USER" "$@"; }

if [[ "$MODE" == "status" ]]; then
  active=$(as_user 10 "systemctl --user is-active $UNIT" 2>/dev/null | tr -d '[:space:]')
  unit_pid=$(as_user 10 "systemctl --user show -p MainPID --value $UNIT" 2>/dev/null | tr -d '[:space:]')
  sock=$(desk_compositor_socket "$DESKTOP_USER" "$unit_pid" 2>/dev/null)
  ping=$(as_user 10 "python3 $HARNESS_DIR/gnome-harness.py ping" 2>&1)
  echo "unit=${active:-unknown} pid=${unit_pid:-none} socket=${sock:-absent} ping=${ping:-<no answer>}"
  [[ "$active" == "active" && -n "$sock" && "$ping" == rhizo-harness* ]] && exit 0
  exit 1
fi

if [[ "$MODE" == "stop" ]]; then
  as_user 15 "systemctl --user stop $UNIT" 2>&1
  active=$(as_user 10 "systemctl --user is-active $UNIT" 2>/dev/null | tr -d '[:space:]')
  if [[ "$active" != "inactive" && "$active" != "failed" ]]; then
    log "FAIL: $UNIT is still '$active' after systemctl --user stop"
    exit 1
  fi
  ssh_vm -t 10 "! mountpoint -q $WAYLAND_SHARE_DIR/wayland-0 || umount $WAYLAND_SHARE_DIR/wayland-0" \
    || { log "FAIL: could not unmount the published $WAYLAND_SHARE_DIR/wayland-0"; exit 1; }
  as_user 10 "$DESK_CLEAR_SESSION_SOCKETS" \
    || { log "FAIL: a wayland socket is still in $RUNTIME_DIR after clearing it as $DESKTOP_USER"; exit 1; }
  log "gnome-shell stopped (unit confirmed inactive, its sockets cleared)"
  exit 0
fi

GNOME_DEBS="${RHIZO_GNOME_DEBS:-/root/share/gnome-debs}"
source ../../../tools/fetch/pools/deb/deb-pool-lib.sh
WANT_PKGS="$DEB_POOL_GNOME_ROOTS"

# mount the share unless the gnome debs are already visible
mount_share_if_needed() {
  ssh_vm -t 8 "ls $GNOME_DEBS/gnome-shell_*.deb >/dev/null 2>&1" && return 0
  guest_mount_share
}

# list the unconfigured packages
unconfigured_pkgs() {
  local out
  out=$(ssh_vm -t 20 "for p in $WANT_PKGS; do
    st=\$(dpkg-query -W -f='\${db:Status-Abbrev}' \$p 2>/dev/null | tr -d ' ')
    [ \"\$st\" = ii ] || echo \$p
  done
  echo RHIZO_UNCONFIGURED_END")
  if [[ "$out" != *RHIZO_UNCONFIGURED_END* ]]; then
    log "FAIL: unconfigured_pkgs: the guest never finished answering (ssh truncated or failed) -- got: ${out:-nothing at all}"
    return 1
  fi
  grep -v RHIZO_UNCONFIGURED_END <<<"$out" | grep -v '^$'
  return 0
}

log "Ensuring gnome-shell/mutter are installed and configured (idempotent)..."
want_install=0
unconfig_out="$(unconfigured_pkgs)" || exit 1
[[ -n "$unconfig_out" ]] && want_install=1
if (( want_install )); then
  guest_refuse_install_if_enforcing "gnome-shell and its dependency closure" \
    "boot the vm with test/vm/run-vm.sh and run test/vm/start/start-gnome.sh --install-only before test/vm/redeploy.sh launches Android" \
    || exit 1
  mount_share_if_needed
  if ! ssh_vm -t 8 "ls $GNOME_DEBS/gnome-shell_*.deb >/dev/null 2>&1"; then
    log "FAIL: no gnome-debs reachable -- neither staged on the guest nor on the 9p share:"
    log "  tools/fetch/pools/deb/fetch.sh gnome-debs"
    exit 1
  fi
  if ! staged=$(deb_pool_stage gnome "$GNOME_DEBS" "$DEB_POOL_GNOME_ROOTS" "$DEB_POOL_GNOME_ALLOW_UPGRADE" \
      "/tmp/gnome-plan${SUFFIX}.tsv" "/tmp/gnome-install${SUFFIX}.log"); then
    log "FAIL: $staged"
    exit 1
  fi
  log "$staged"
  still="$(unconfigured_pkgs)" || exit 1
  if [[ -n "$still" ]]; then
    log "FAIL: still not configured after install: $(tr '\n' ' ' <<<"$still")"
    log "  see /tmp/gnome-install${SUFFIX}.log"
    tail -40 /tmp/gnome-install${SUFFIX}.log >&2
    exit 1
  fi
  log "gnome-shell/mutter installed and configured"
else
  log "gnome-shell/mutter already installed"
fi

ssh_vm -t 10 "mkdir -p $HARNESS_DIR && chmod 755 $HARNESS_DIR"
timeout 30 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" ../../system/guest/gnome-harness.py ../../system/guest/gnome-launcher.py ../../../src/services/deskbridge/dbus_min.py \
  "$SSH_TARGET:$HARNESS_DIR/" \
  || { log "FAIL: could not stage gnome-harness.py/gnome-launcher.py/dbus_min.py to $HARNESS_DIR"; exit 1; }
ssh_vm -t 10 "chmod 644 $HARNESS_DIR/gnome-harness.py $HARNESS_DIR/gnome-launcher.py $HARNESS_DIR/dbus_min.py"

../../../tools/build/test-tools/gen-gnome-harness-ext.sh || { log "FAIL: could not generate the rhizo-harness@rhizo extension"; exit 1; }
EXT_SRC="$(cd "../../system/guest/gnome-harness-ext/rhizo-harness@rhizo" && pwd)"
EXT_REL=".local/share/gnome-shell/extensions/rhizo-harness@rhizo"
ssh_vm -t 10 "rm -rf $EXT_STAGE_DIR && mkdir -p $EXT_STAGE_DIR && chmod 755 $EXT_STAGE_DIR" \
  || { log "FAIL: could not create $EXT_STAGE_DIR"; exit 1; }
timeout 30 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$EXT_SRC/metadata.json" "$EXT_SRC/extension.js" \
  "$SSH_TARGET:$EXT_STAGE_DIR/" \
  || { log "FAIL: could not copy the rhizo-harness@rhizo extension to $EXT_STAGE_DIR"; exit 1; }
ssh_vm -t 10 "chmod 644 $EXT_STAGE_DIR/metadata.json $EXT_STAGE_DIR/extension.js"
as_user 20 "install -d -m 0755 \"\$HOME/$EXT_REL\" && install -m 0644 $EXT_STAGE_DIR/metadata.json $EXT_STAGE_DIR/extension.js \"\$HOME/$EXT_REL/\"" \
  || { log "FAIL: could not install the rhizo-harness@rhizo extension into ~$DESKTOP_USER/$EXT_REL as $DESKTOP_USER"; exit 1; }

if [[ "$MODE" == "install-only" ]]; then
  log "stack installed and configured, extension staged (--install-only, not starting a session)"
  exit 0
fi

GSETTINGS_XKB="[('xkb', '$XKB_LAYOUT')]"
GSETTINGS_EXT="['rhizo-harness@rhizo']"
GSETTINGS_SET="gsettings set org.gnome.desktop.input-sources sources \"$GSETTINGS_XKB\"
gsettings set org.gnome.shell enabled-extensions \"$GSETTINGS_EXT\"
gsettings set org.gnome.shell disable-user-extensions false
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.interface enable-animations false"
GSETTINGS_GET='echo "SOURCES=$(gsettings get org.gnome.desktop.input-sources sources)"
echo "EXT=$(gsettings get org.gnome.shell enabled-extensions)"
echo RHIZO_GSETTINGS_OK'

# compare the gsettings read-back with the values set
gsettings_check() {
  local out="$1" got_sources got_ext
  [[ "$out" == *RHIZO_GSETTINGS_OK* ]] \
    || { log "FAIL: the gsettings script did not complete: $(tr '\n' ' ' <<<"$out")"; return 1; }
  got_sources=$(sed -n 's/^SOURCES=//p' <<<"$out" | tr -d '\r')
  got_ext=$(sed -n 's/^EXT=//p' <<<"$out" | tr -d '\r')
  [[ "$got_sources" == "$GSETTINGS_XKB" ]] \
    || { log "FAIL: gsettings get org.gnome.desktop.input-sources sources returned '$got_sources', wanted '$GSETTINGS_XKB'"; return 1; }
  [[ "$got_ext" == "$GSETTINGS_EXT" ]] \
    || { log "FAIL: gsettings get org.gnome.shell enabled-extensions returned '$got_ext', wanted '$GSETTINGS_EXT'"; return 1; }
  log "gsettings confirmed by read-back: input-sources=$got_sources enabled-extensions=$got_ext"
}

# ping the harness in gnome-shell
harness_ping() {
  local pid="$1" i ping_pid
  ping_out=""
  for i in $(seq 1 20); do
    ping_out=$(as_user 10 "python3 $HARNESS_DIR/gnome-harness.py ping" 2>&1)
    [[ "$ping_out" == rhizo-harness* ]] && break
    sleep 1
  done
  if [[ "$ping_out" != rhizo-harness* ]]; then
    log "FAIL: org.rhizo.Harness never answered ping -- got: $ping_out"
    return 1
  fi
  ping_pid=$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' <<<"$ping_out")
  if [[ -z "$ping_pid" || "$ping_pid" != "$pid" ]]; then
    log "FAIL: org.rhizo.Harness answered from pid=${ping_pid:-?}, but the session's gnome-shell is pid ${pid:-?}"
    return 1
  fi
  for i in $(seq 1 15); do
    [[ "$ping_out" == *" overview=0"* ]] && return 0
    sleep 1
    ping_out=$(as_user 10 "python3 $HARNESS_DIR/gnome-harness.py ping" 2>&1)
  done
  log "FAIL: gnome-shell is still showing the overview 15s after the harness answered ($ping_out)"
  return 1
}

GDM_TIMED_LOGIN=$(cat <<'EOF'
f=/etc/gdm3/custom.conf
grep -q '^\[daemon\]' "$f" || { echo "no [daemon] section in $f"; exit 1; }
sed -i -e '/^[[:space:]]*\(TimedLoginEnable\|TimedLogin\|TimedLoginDelay\|AutomaticLoginEnable\|AutomaticLogin\)[[:space:]]*=/d' \
  -e "/^\[daemon\]/a TimedLoginEnable=true\nTimedLogin=$u\nTimedLoginDelay=5" "$f" || exit 1
echo "DAEMON=$(sed -n '/^\[daemon\]/,/^\[/p' "$f" | grep -E '^(Timed|Automatic)Login' | tr '\n' ' ')"
echo "DM=$(systemctl show -p Id --value display-manager.service)"
echo "TARGET=$(systemctl get-default)"
systemctl restart display-manager.service && echo RHIZO_DM_RESTARTED
EOF
)
# set up the gdm timed login for the desktop user
stage_seat_login() {
  local out
  out=$(as_user 40 "rd=\$(mktemp -d) || exit 1
XDG_RUNTIME_DIR=\"\$rd\" dbus-run-session -- bash -c $(printf '%q' "set -e
$GSETTINGS_SET
$GSETTINGS_GET"); rc=\$?
rm -rf \"\$rd\"
exit \$rc" 2>&1)
  gsettings_check "$out" || return 1
  out=$(ssh_vm -t 90 "u=$(printf '%q' "$DESKTOP_USER")
$GDM_TIMED_LOGIN" 2>&1)
  if ! grep -qx "DAEMON=TimedLoginEnable=true TimedLogin=$DESKTOP_USER TimedLoginDelay=5 " <<<"$out"; then
    log "FAIL: /etc/gdm3/custom.conf's [daemon] does not read a timed login of $DESKTOP_USER alone: $(tr '\n' ' ' <<<"$out")"
    return 1
  fi
  if ! grep -qxE 'DM=gdm3?\.service' <<<"$out"; then
    log "FAIL: display-manager.service is not gdm on this host: $(grep '^DM=' <<<"$out")"
    return 1
  fi
  if ! grep -qx 'TARGET=graphical.target' <<<"$out"; then
    log "FAIL: this host boots $(sed -n 's/^TARGET=//p' <<<"$out"), where no display manager starts"
    return 1
  fi
  [[ "$out" == *RHIZO_DM_RESTARTED* ]] \
    || { log "FAIL: display-manager.service did not restart: $(tr '\n' ' ' <<<"$out")"; return 1; }
  log "seat login staged: $DESKTOP_USER's gsettings and extension, gdm3 TimedLogin of $DESKTOP_USER after 5s"
}

if [[ "$MODE" == stage-login ]]; then
  SESSION_MODE=login
else
  SESSION_MODE=$(desk_session_mode) || { log "FAIL: could not decide the session mode"; exit 1; }
fi
log "session mode: $SESSION_MODE"
if [[ "$SESSION_MODE" == login ]]; then
  if [[ "$MODE" == stage-login ]]; then
    stage_seat_login || exit 1
  elif [[ -n "$START_ARGS" ]]; then
    log "FAIL: login mode cannot take$START_ARGS -- stage them with --stage-login"
    exit 1
  fi
  if ! unit_pid=$(desk_seat_compositor_wait "$DESKTOP_USER" gnome-shell); then
    log "FAIL: gdm never logged $DESKTOP_USER into a gnome-shell on seat0 -- gdm's journal:"
    ssh_vm -t 20 "journalctl -b --no-pager -n 40 -u gdm.service" >&2
    exit 1
  fi
  if ! WL_SOCK=$(desk_compositor_socket "$DESKTOP_USER" "$unit_pid"); then
    log "FAIL: gnome-shell (pid $unit_pid) of the seat login listens on no single wayland socket"
    exit 1
  fi
  gsettings_check "$(as_user 20 "$GSETTINGS_GET" 2>&1)" || exit 1
  harness_ping "$unit_pid" || exit 1
  ctx_mode=$(desk_login_context_mode) || { log "FAIL: could not read whether the guest has SELinux"; exit 1; }
  if ! shell_ctx=$(desk_compositor_context "$unit_pid" "$ctx_mode"); then
    log "FAIL: gnome-shell (pid $unit_pid) runs in '$shell_ctx', not rhizo_host"
    exit 1
  fi
  log "gnome-shell up as $DESKTOP_USER (uid $DESKTOP_UID, pid $unit_pid, context $shell_ctx) in gdm's seat login. Wayland socket: $RUNTIME_DIR/$WL_SOCK."
  log "harness: $ping_out"
  exit 0
fi

render_node_relabel "$DESKTOP_UID" || exit 1
ssh_vm -t 10 "loginctl enable-linger $DESKTOP_USER >/dev/null 2>&1 || true"
# desk-user-ok:
ssh_vm -t 10 "test -d $RUNTIME_DIR || { mkdir -p $RUNTIME_DIR && chown $DESKTOP_USER:$DESKTOP_USER $RUNTIME_DIR && chmod 700 $RUNTIME_DIR; }" \
  || { log "FAIL: could not create $RUNTIME_DIR for $DESKTOP_USER"; exit 1; }

log "waiting for the user bus ($RUNTIME_DIR/bus)..."
bus_up=0
for (( i = 0; i <= 30; i++ )); do
  as_user 6 'test -S "$XDG_RUNTIME_DIR/bus"' >/dev/null 2>&1 && { bus_up=1; break; }
  (( i < 30 )) && sleep 1
done
(( bus_up )) \
  || { log "FAIL: no user bus at $RUNTIME_DIR/bus after enable-linger"; exit 1; }
log "user bus is up"

log "pre-setting gsettings on the user bus (layout=$XKB_LAYOUT)..."
gsettings_check "$(as_user 20 "set -e
$GSETTINGS_SET
$GSETTINGS_GET" 2>&1)" || exit 1

log "stopping any earlier $UNIT session..."
as_user 15 "systemctl --user stop $UNIT" >/dev/null 2>&1 || true
prior_active=$(as_user 10 "systemctl --user is-active $UNIT" 2>/dev/null | tr -d '[:space:]')
if [[ "$prior_active" != "inactive" && "$prior_active" != "failed" && -n "$prior_active" ]]; then
  log "FAIL: $UNIT is still '$prior_active' after systemctl --user stop"
  exit 1
fi
ssh_vm -t 10 "{ ! mountpoint -q $WAYLAND_SHARE_DIR/wayland-0 || umount $WAYLAND_SHARE_DIR/wayland-0; } && rm -f $GNOME_LOG" \
  || { log "FAIL: could not unmount $WAYLAND_SHARE_DIR/wayland-0 or remove $GNOME_LOG from the earlier session"; exit 1; }
as_user 10 "$DESK_CLEAR_SESSION_SOCKETS" \
  || { log "FAIL: a dead compositor's wayland-N socket is still in $RUNTIME_DIR after clearing it as $DESKTOP_USER"; exit 1; }

IFS=',' read -r -a SIZE_ARR <<<"$SIZES"
VM_FLAGS=""
for s in "${SIZE_ARR[@]}"; do VM_FLAGS="$VM_FLAGS --virtual-monitor $s"; done

log "Starting headless gnome-shell (sizes=$SIZES)..."
as_user 15 "systemctl --user reset-failed $UNIT" >/dev/null 2>&1 || true
launch_cmd="systemd-run --user --unit=$UNIT --collect \
  -p Environment=XDG_SESSION_TYPE=wayland \
  -p StandardOutput=truncate:$GNOME_LOG -p StandardError=truncate:$GNOME_LOG \
  gnome-shell --headless --wayland$VM_FLAGS; echo RHIZO_LAUNCH_RC=\$?"
out=$(as_user 20 "$launch_cmd" 2>&1); echo "$out"
launch_rc=$(grep -oE 'RHIZO_LAUNCH_RC=[0-9]+' <<<"$out" | cut -d= -f2)
if [[ -z "$launch_rc" || "$launch_rc" != "0" ]]; then
  log "FAIL: systemd-run did not accept the gnome-shell unit (rc=${launch_rc:-unknown}) -- see output above"
  exit 1
fi

log "waiting for $UNIT's gnome-shell to listen on a wayland socket in $RUNTIME_DIR..."
unit_pid="" WL_SOCK=""
for (( i = 0; i <= 30; i++ )); do
  unit_pid=$(as_user 10 "systemctl --user show -p MainPID --value $UNIT" 2>/dev/null | tr -d '[:space:]')
  if [[ "$unit_pid" =~ ^[1-9][0-9]*$ ]] && WL_SOCK=$(desk_compositor_socket "$DESKTOP_USER" "$unit_pid" 2>/dev/null); then
    break
  fi
  WL_SOCK=""
  sleep 1
done
if [[ -z "$WL_SOCK" ]]; then
  log "FAIL: $UNIT (MainPID ${unit_pid:-<none>}) never listened on one wayland socket in $RUNTIME_DIR -- gnome-shell log:"
  [[ "$unit_pid" =~ ^[1-9][0-9]*$ ]] && desk_compositor_socket "$DESKTOP_USER" "$unit_pid" >/dev/null
  ssh_vm -t 8 "tail -60 $GNOME_LOG" >&2
  exit 1
fi
log "gnome-shell (pid $unit_pid) listens on $RUNTIME_DIR/$WL_SOCK"

wayland_info_out=$(as_user 15 "env WAYLAND_DISPLAY=$WL_SOCK wayland-info" 2>&1)
ssh_vm -t 10 "cat > /tmp/rhizo-gnome-wayland-info.txt" <<<"$wayland_info_out" >/dev/null 2>&1
log "wayland-info saved to guest:/tmp/rhizo-gnome-wayland-info.txt ($(wc -l <<<"$wayland_info_out") lines)"

if ! harness_ping "$unit_pid"; then
  log "  gnome-shell log:"
  ssh_vm -t 8 "tail -60 $GNOME_LOG" >&2
  exit 1
fi
if ! shell_ctx=$(desk_compositor_context "$unit_pid" "$SESSION_MODE"); then
  log "FAIL: gnome-shell (pid $unit_pid) runs in '$shell_ctx', not rhizo_host"
  exit 1
fi

# desk-user-ok:
ssh_vm -t 10 "mkdir -p $WAYLAND_SHARE_DIR && chmod 755 $WAYLAND_SHARE_DIR \
  && { mountpoint -q $WAYLAND_SHARE_DIR/wayland-0 && umount $WAYLAND_SHARE_DIR/wayland-0; :; } \
  && : > $WAYLAND_SHARE_DIR/wayland-0 \
  && mount --bind $RUNTIME_DIR/$WL_SOCK $WAYLAND_SHARE_DIR/wayland-0 \
  && chmod 777 $WAYLAND_SHARE_DIR/wayland-0" \
  || { log "FAIL: could not publish the wayland socket at $WAYLAND_SHARE_DIR/wayland-0"; exit 1; }
# desk-user-ok:
wayland_label_out=$(ssh_vm -t 10 "python3 -c \"
import os
sock = '$RUNTIME_DIR/$WL_SOCK'
os.setxattr(sock, 'security.selinux', b'u:object_r:rhizo_wayland_socket:s0\\\\0')
print('wayland socket relabel OK:', os.getxattr(sock, 'security.selinux'))
\"" 2>&1)
echo "$wayland_label_out"
[[ "$wayland_label_out" == *"relabel OK"* ]] \
  || { log "FAIL: could not label $RUNTIME_DIR/$WL_SOCK rhizo_wayland_socket -- see output above"; exit 1; }

published_ino=$(ssh_vm -t 8 "stat -Lc %i $WAYLAND_SHARE_DIR/wayland-0" 2>/dev/null | tr -d '[:space:]')
live_ino=$(as_user 8 "stat -Lc %i \"\$XDG_RUNTIME_DIR/$WL_SOCK\"" 2>/dev/null | tr -d '[:space:]')
if [[ -z "$published_ino" || "$published_ino" != "$live_ino" ]]; then
  log "FAIL: published socket inode ($published_ino) != live socket inode ($live_ino)"
  exit 1
fi
log "wayland socket published at $WAYLAND_SHARE_DIR/wayland-0 (bind of $RUNTIME_DIR/$WL_SOCK, inode $live_ino confirmed)"

log "gnome-shell up as $DESKTOP_USER (uid $DESKTOP_UID, pid $unit_pid). Wayland socket: $RUNTIME_DIR/$WL_SOCK."
log "harness: $ping_out"
