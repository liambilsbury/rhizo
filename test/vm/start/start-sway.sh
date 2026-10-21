#!/bin/bash
# start a headless sway compositor in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh
source ../guest-os/guest-os-lib.sh
source ./render-node-relabel.sh
source ../../../tools/fetch/pools/deb/deb-pool-lib.sh
source ../../system/lib/desk-user-lib.sh

SOCKET_NAME="wayland-rhizo"
WAYLAND_SHARE_DIR="${RHIZO_WAYLAND_HOST_DIR:-/run/rhizo-wayland}"
EXTRA_INSTANCE_IDS=()
for _id in ${RHIZO_SANDBOX_IDS:-}; do EXTRA_INSTANCE_IDS+=("$_id"); done
OUTPUT_SIZE="1920x1080"
OUTPUT_REFRESH="${RHIZO_SWAY_REFRESH:-}"
XKB_LAYOUT="${RHIZO_SWAY_XKB_LAYOUT:-}"
INSTALL_ONLY=0
STAGE_LOGIN=0
DESKTOP_USER_ARG=""
START_ARGS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket) SOCKET_NAME="$2"; START_ARGS+=" $1"; shift 2 ;;
    --size) OUTPUT_SIZE="$2"; START_ARGS+=" $1"; shift 2 ;;
    --refresh) OUTPUT_REFRESH="$2"; START_ARGS+=" $1"; shift 2 ;;
    --xkb-layout) XKB_LAYOUT="$2"; START_ARGS+=" $1"; shift 2 ;;
    --instance) EXTRA_INSTANCE_IDS+=("$2"); START_ARGS+=" $1"; shift 2 ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    --stage-login) STAGE_LOGIN=1; shift ;;
    --user) DESKTOP_USER_ARG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
for _id in ${EXTRA_INSTANCE_IDS+"${EXTRA_INSTANCE_IDS[@]}"}; do
  [[ "$_id" =~ ^[0-9]+$ ]] && (( 10#$_id >= 1 && 10#$_id <= 99 )) \
    || { echo "--instance takes an id 1-99, got '$_id'" >&2; exit 2; }
done

if [[ -n "$OUTPUT_REFRESH" ]]; then
  OUTPUT_MODE_CLAUSE="mode ${OUTPUT_SIZE}@${OUTPUT_REFRESH}Hz"
else
  OUTPUT_MODE_CLAUSE="resolution $OUTPUT_SIZE"
fi

if [[ -n "$XKB_LAYOUT" ]]; then
  XKB_CLAUSE="input * xkb_layout $XKB_LAYOUT"
else
  XKB_CLAUSE=""
fi

SSH_WAIT="${RHIZO_SWAY_SSH_WAIT:-20}"
wait_for_ssh "$SSH_WAIT" || { log "FAIL: VM not reachable"; exit 1; }

DESKTOP_USER="$DESKTOP_USER_ARG"
if [[ -z "$DESKTOP_USER" ]]; then
  DESKTOP_USER=$(ssh_vm -t 8 'cat /etc/rhizo/desktop-user 2>/dev/null' | tr -d '[:space:]')
  [[ -n "$DESKTOP_USER" ]] || DESKTOP_USER=$(ssh_vm -t 8 'getent passwd 1000 | cut -d: -f1' | tr -d '[:space:]')
fi
DESKTOP_UID=$(ssh_vm -t 8 "id -u '$DESKTOP_USER' 2>/dev/null" | tr -d '[:space:]')
if [[ -z "$DESKTOP_UID" ]]; then
  log "FAIL: no such account '$DESKTOP_USER' on the guest"
  exit 1
fi
RUNTIME_DIR="/run/user/$DESKTOP_UID"
log "compositor session: user=$DESKTOP_USER uid=$DESKTOP_UID runtime_dir=$RUNTIME_DIR"

SWAY_DEBS="${RHIZO_SWAY_DEBS:-/root/share/sway-debs}"

# mount the share unless the sway debs are already reachable
mount_share_if_needed() {
  ssh_vm -t 8 "ls $SWAY_DEBS/sway_*.deb >/dev/null 2>&1" && return 0
  guest_mount_share
}

WANT_PKGS="sway swaybg grim wlrctl foot libwlroots12t64 libegl1 libegl-mesa0 libgbm1 libgl1-mesa-dri mesa-libgallium libdrm-intel1 libpciaccess0"
ARCH_PKGS="sway grim foot"
# print the wanted packages that are not installed and configured
unconfigured_pkgs() {
  if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
    ssh_vm -t 20 "for p in $ARCH_PKGS; do pacman -Qq \$p >/dev/null 2>&1 || echo \$p; done"
    return
  fi
  ssh_vm -t 20 "for p in $WANT_PKGS; do
    st=\$(dpkg-query -W -f='\${db:Status-Abbrev}' \$p 2>/dev/null | tr -d ' ')
    [ \"\$st\" = ii ] || echo \$p
  done"
}

SWAY_TOOLS=sway/grim/wlrctl; [[ "$RHIZO_GUEST_OS" == cachyos ]] && SWAY_TOOLS=sway/grim
log "Ensuring $SWAY_TOOLS are installed and configured (idempotent)..."
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  missing=$(unconfigured_pkgs) || { log "FAIL: could not ask the cachyos guest which packages it has"; exit 1; }
  if [[ -n "$missing" ]]; then
    log "FAIL: the cachyos guest lacks $(tr '\n' ' ' <<<"$missing")-- rebuild its base image" \
        "(tools/build/vm/cachyos-dev.sh)"
    exit 1
  fi
  log "$SWAY_TOOLS already installed"
elif [[ -n "$(unconfigured_pkgs)" ]]; then
  guest_refuse_install_if_enforcing "sway and its Mesa stack" \
    "boot the vm with test/vm/run-vm.sh and run test/vm/start/start-sway.sh --install-only before test/vm/redeploy.sh launches Android" \
    || exit 1
  mount_share_if_needed
  if ! ssh_vm -t 8 "ls $SWAY_DEBS/sway_*.deb >/dev/null 2>&1"; then
    log "FAIL: no sway .debs reachable -- neither staged on the guest nor on the 9p share:"
    log "  tools/fetch/pools/deb/fetch.sh sway-debs"
    exit 1
  fi
  if ! staged=$(deb_pool_stage sway "$SWAY_DEBS" "$DEB_POOL_SWAY_ROOTS" "$DEB_POOL_SWAY_ALLOW_UPGRADE" \
      "/tmp/sway-plan${SUFFIX}.tsv" "/tmp/sway-install${SUFFIX}.log"); then
    log "FAIL: $staged"
    exit 1
  fi
  log "$staged"
  still="$(unconfigured_pkgs)"
  if [[ -n "$still" ]]; then
    log "FAIL: still not configured after install: $(tr '\n' ' ' <<<"$still")"
    log "  see /tmp/sway-install${SUFFIX}.log"
    tail -30 /tmp/sway-install${SUFFIX}.log >&2
    exit 1
  fi
  log "$SWAY_TOOLS installed and configured"
else
  log "$SWAY_TOOLS already installed"
fi

sway_common='default_border none
default_floating_border none
titlebar_border_thickness 0
gaps inner 0
gaps outer 0
focus_follows_mouse no
xwayland disable
for_window [app_id="^rhizo"] floating enable, resize set 960 1080, move position 960 0
for_window [app_id="rhizo" title="^Rhizo$"] floating enable, resize set 960 1080, move position 0 0
'"$XKB_CLAUSE"'
'
sway_conf="${sway_common}output HEADLESS-1 $OUTPUT_MODE_CLAUSE position 0 0
"
if (( INSTALL_ONLY )); then
  log "stack installed and configured (--install-only, not starting a compositor)"
  exit 0
fi

SEAT_SWAY_LOG="/tmp/rhizo-sway-$DESKTOP_UID.log"
SEAT_PROFILE_MARK="$DESK_SWAY_PROFILE_MARK"
SEAT_PROFILE="$SEAT_PROFILE_MARK
if [ -z \"\$WAYLAND_DISPLAY\" ] && [ \"\${XDG_VTNR:-}\" = 1 ]; then
  exec sway >\"/tmp/rhizo-sway-\$(id -u).log\" 2>&1
fi"
SEAT_GETTY_DROPIN=$(cat <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin RHIZO_DESKTOP_USER - $TERM
EOF
)
SEAT_GETTY_DROPIN=${SEAT_GETTY_DROPIN/RHIZO_DESKTOP_USER/$DESKTOP_USER}

# set up the sway seat login for the user
stage_seat_login() {
  local out seat_output sway_seat_conf
  seat_output=$(desk_sway_seat_output "$OUTPUT_SIZE" "$OUTPUT_REFRESH") \
    || { log "FAIL: no seat output mode for size '$OUTPUT_SIZE' refresh '${OUTPUT_REFRESH:-<default>}'"; return 1; }
  sway_seat_conf="${sway_common}${seat_output}
include /etc/sway/config.d/*
"
  desk_user_sh --user "$DESKTOP_USER" 20 "install -d -m 0755 \"\$HOME/.config/sway\" && cat > \"\$HOME/.config/sway/config\"" \
    <<<"$sway_seat_conf" \
    || { log "FAIL: could not write ~$DESKTOP_USER/.config/sway/config as $DESKTOP_USER"; return 1; }
  desk_user_sh --user "$DESKTOP_USER" 20 "grep -qxF $(printf '%q' "$SEAT_PROFILE_MARK") \"\$HOME/.profile\" \
|| printf '\\n%s\\n' $(printf '%q' "$SEAT_PROFILE") >> \"\$HOME/.profile\"" \
    || { log "FAIL: could not add the tty1 sway start to ~$DESKTOP_USER/.profile as $DESKTOP_USER"; return 1; }
  out=$(ssh_vm -t 60 "install -d -m 0755 /etc/systemd/system/getty@tty1.service.d \
&& cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf && systemctl daemon-reload \
&& echo \"ENABLED=\$(systemctl is-enabled getty@tty1.service)\" \
&& echo \"EXEC=\$(systemctl show -p ExecStart --value getty@tty1.service)\" \
&& systemctl restart getty@tty1.service && echo RHIZO_GETTY_RESTARTED" <<<"$SEAT_GETTY_DROPIN" 2>&1)
  if [[ "$out" != *RHIZO_GETTY_RESTARTED* ]]; then
    log "FAIL: getty@tty1's autologin drop-in did not load and restart: $(tr '\n' ' ' <<<"$out")"
    return 1
  fi
  if ! grep -qx 'ENABLED=enabled' <<<"$out"; then
    log "FAIL: getty@tty1.service is not enabled on this host: $(grep '^ENABLED=' <<<"$out")"
    return 1
  fi
  if ! grep -q "^EXEC=.*--autologin $DESKTOP_USER " <<<"$out"; then
    log "FAIL: getty@tty1.service's ExecStart does not autologin $DESKTOP_USER after the reload: $(grep '^EXEC=' <<<"$out")"
    return 1
  fi
  log "seat login staged: ~$DESKTOP_USER/.config/sway/config, ~/.profile starts sway on tty1, getty@tty1 autologins $DESKTOP_USER"
}

if (( STAGE_LOGIN )); then
  SESSION_MODE=login
else
  SESSION_MODE=$(desk_session_mode) || { log "FAIL: could not decide the session mode"; exit 1; }
fi
log "session mode: $SESSION_MODE"
if [[ "$SESSION_MODE" == login ]]; then
  if (( STAGE_LOGIN )); then
    stage_seat_login || exit 1
  elif [[ -n "$START_ARGS$XKB_LAYOUT$OUTPUT_REFRESH" ]]; then
    log "FAIL: login mode cannot take$START_ARGS${XKB_LAYOUT:+ layout $XKB_LAYOUT}${OUTPUT_REFRESH:+ refresh $OUTPUT_REFRESH} -- stage them with --stage-login"
    exit 1
  fi
  if ! sway_pid=$(desk_seat_compositor_wait "$DESKTOP_USER" sway); then
    log "FAIL: the seat login never brought up $DESKTOP_USER's sway -- its log ($SEAT_SWAY_LOG):"
    ssh_vm -t 8 "tail -40 $SEAT_SWAY_LOG" >&2
    exit 1
  fi
  if ! real_sock=$(desk_compositor_socket "$DESKTOP_USER" "$sway_pid"); then
    log "FAIL: sway (pid $sway_pid) of the seat login listens on no single wayland socket"
    exit 1
  fi
  if ! desk_user_sh --user "$DESKTOP_USER" 10 "SWAYSOCK=\"\$XDG_RUNTIME_DIR/sway-ipc.$DESKTOP_UID.$sway_pid.sock\" swaymsg -t get_version"; then
    log "FAIL: sway (pid $sway_pid) IPC not answering on its own sway-ipc.$DESKTOP_UID.$sway_pid.sock -- sway log:"
    ssh_vm -t 8 "tail -40 $SEAT_SWAY_LOG" >&2
    exit 1
  fi
  sway_uid=$(ssh_vm -t 8 "stat -c %u /proc/$sway_pid 2>/dev/null" | tr -d '\r')
  sock_uid=$(desk_user_sh --user "$DESKTOP_USER" 8 "stat -c %u \"\$XDG_RUNTIME_DIR/$real_sock\"" | tr -d '[:space:]')
  if [[ -z "$sway_uid" || "$sway_uid" != "$DESKTOP_UID" || "$sock_uid" != "$DESKTOP_UID" ]]; then
    log "FAIL: the seat login's sway is not the desktop user's -- pid ${sway_pid:-<none>} uid=${sway_uid:-<none>}, socket owner uid=${sock_uid:-<none>}, wanted $DESKTOP_UID"
    exit 1
  fi
  ctx_mode=$(desk_login_context_mode) || { log "FAIL: could not read whether the guest has SELinux"; exit 1; }
  if ! sway_ctx=$(desk_compositor_context "$sway_pid" "$ctx_mode"); then
    log "FAIL: sway (pid $sway_pid) runs in '$sway_ctx', not rhizo_host"
    exit 1
  fi
  log "sway up as $DESKTOP_USER (uid $DESKTOP_UID, pid $sway_pid, context $sway_ctx) in the tty1 seat login. Wayland socket: $RUNTIME_DIR/$real_sock."
  exit 0
fi

if [[ "$SESSION_MODE" == rig ]]; then
  # desk-user-ok: rig mode only
  ssh_vm -t 10 "test -d $RUNTIME_DIR || { mkdir -p $RUNTIME_DIR && chown $DESKTOP_USER:$DESKTOP_USER $RUNTIME_DIR && chmod 700 $RUNTIME_DIR; }" \
    || { log "FAIL: could not create $RUNTIME_DIR for $DESKTOP_USER"; exit 1; }
  ssh_vm -t 10 "loginctl enable-linger $DESKTOP_USER >/dev/null 2>&1 || true"
fi

log "(Re)starting headless sway (socket link=$SOCKET_NAME, output=$OUTPUT_SIZE)..."
if ! kill_out=$(ssh_vm -t 20 "pkill -9 -x sway; pkill -9 -x swaybg; rm -f /tmp/sway.log || { echo 'could not remove the earlier run log'; exit 1; }
for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x 'sway|swaybg' >/dev/null || exit 0; sleep 0.5; done
echo \"still running after pkill -9: \$(pgrep -ax 'sway|swaybg' | tr '\n' ' ')\"; exit 1" 2>&1); then
  log "FAIL: could not end the earlier sway session: ${kill_out:-no output}"
  exit 1
fi
desk_user_sh --user "$DESKTOP_USER" 15 "$DESK_CLEAR_SESSION_SOCKETS" \
  || { log "FAIL: a dead compositor's wayland-N or sway-ipc socket is still in $RUNTIME_DIR after clearing it as $DESKTOP_USER"; exit 1; }
ssh_vm -t 10 "cat > /tmp/sway-rhizo.conf <<'EOF'
$sway_conf
EOF
chmod 644 /tmp/sway-rhizo.conf"

render_node_relabel "$DESKTOP_UID" || exit 1

launch_cmd="runuser -u $DESKTOP_USER -- bash -c 'XDG_RUNTIME_DIR=$RUNTIME_DIR WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
  WLR_RENDERER=gles2 setsid sway -c /tmp/sway-rhizo.conf -d >/tmp/sway.log 2>&1 < /dev/null & disown'; \
  sleep 3"
out=$(ssh_vm -t 20 "$launch_cmd" 2>&1); true
echo "$out"
desk_user_sh --user "$DESKTOP_USER" 8 'ls -la "$XDG_RUNTIME_DIR"/'

sway_pid="" real_sock=""
for (( i = 0; i < 20; i++ )); do
  sway_pid=$(ssh_vm -t 8 "pgrep -x sway" | tr -d '\r')
  if [[ "$sway_pid" =~ ^[1-9][0-9]*$ ]] && real_sock=$(desk_compositor_socket "$DESKTOP_USER" "$sway_pid" 2>/dev/null); then
    break
  fi
  real_sock=""
  sleep 1
done
if [[ -z "$real_sock" ]]; then
  log "FAIL: no single sway (pgrep -x sway: $(tr '\n' ' ' <<<"${sway_pid:-<none>}")) listened on one wayland socket in $RUNTIME_DIR -- sway log:"
  [[ "$sway_pid" =~ ^[1-9][0-9]*$ ]] && desk_compositor_socket "$DESKTOP_USER" "$sway_pid" >/dev/null
  ssh_vm -t 8 "tail -40 /tmp/sway.log" >&2
  exit 1
fi
desk_user_sh --user "$DESKTOP_USER" 8 "ln -sf \"\$XDG_RUNTIME_DIR/$real_sock\" \"\$XDG_RUNTIME_DIR/$SOCKET_NAME\" && chmod 777 \"\$XDG_RUNTIME_DIR/$real_sock\"" \
  || { log "FAIL: could not link $SOCKET_NAME onto $real_sock in $RUNTIME_DIR as $DESKTOP_USER"; exit 1; }

# desk-user-ok: rig mode only
ssh_vm -t 10 "mkdir -p $WAYLAND_SHARE_DIR && chmod 755 $WAYLAND_SHARE_DIR \
  && { mountpoint -q $WAYLAND_SHARE_DIR/wayland-0 && umount $WAYLAND_SHARE_DIR/wayland-0; :; } \
  && : > $WAYLAND_SHARE_DIR/wayland-0 \
  && mount --bind $RUNTIME_DIR/$real_sock $WAYLAND_SHARE_DIR/wayland-0 \
  && chmod 777 $WAYLAND_SHARE_DIR/wayland-0" \
  || { log "FAIL: could not publish the wayland socket at $WAYLAND_SHARE_DIR/wayland-0"; exit 1; }
# desk-user-ok: rig mode only
wayland_label_out=$(ssh_vm -t 10 "python3 -c \"
import os
sock = '$RUNTIME_DIR/$real_sock'
os.setxattr(sock, 'security.selinux', b'u:object_r:rhizo_wayland_socket:s0\\\\0')
print('wayland socket relabel OK:', os.getxattr(sock, 'security.selinux'))
\"" 2>&1)
echo "$wayland_label_out"
[[ "$wayland_label_out" == *"relabel OK"* ]] \
  || { log "FAIL: could not label $RUNTIME_DIR/$real_sock rhizo_wayland_socket -- see output above"; exit 1; }
log "wayland socket published at $WAYLAND_SHARE_DIR/wayland-0 (bind of $RUNTIME_DIR/$real_sock)"

configured_ids=$(ssh_vm -t 10 "ls /etc/rhizo/instances/ 2>/dev/null | sed -n 's/^\([0-9][0-9]*\)\.env\$/\1/p'")
publish_ids=$(printf '%s\n' ${EXTRA_INSTANCE_IDS+"${EXTRA_INSTANCE_IDS[@]}"} $configured_ids \
  | sed -n 's/^0*\([1-9][0-9]*\)$/\1/p' | sort -un)
for id in $publish_ids; do
  dir="$WAYLAND_SHARE_DIR-$id"
  # desk-user-ok: rig mode only
  ssh_vm -t 10 "mkdir -p $dir && chmod 755 $dir \
    && { mountpoint -q $dir/wayland-0 && umount $dir/wayland-0; :; } \
    && : > $dir/wayland-0 \
    && mount --bind $RUNTIME_DIR/$real_sock $dir/wayland-0 \
    && chmod 777 $dir/wayland-0" \
    || { log "FAIL: could not publish the wayland socket at $dir/wayland-0"; exit 1; }
  log "wayland socket published at $dir/wayland-0 for instance $id (the same inode)"
done

if ! desk_user_sh --user "$DESKTOP_USER" 10 "SWAYSOCK=\"\$XDG_RUNTIME_DIR/sway-ipc.$DESKTOP_UID.$sway_pid.sock\" swaymsg -t get_version"; then
  log "FAIL: sway (pid $sway_pid) IPC not answering on its own sway-ipc.$DESKTOP_UID.$sway_pid.sock -- sway log:"
  ssh_vm -t 8 "tail -40 /tmp/sway.log" >&2
  exit 1
fi
sway_uid=$(ssh_vm -t 8 "stat -c %u /proc/$sway_pid 2>/dev/null" | tr -d '\r')
sock_uid=$(desk_user_sh --user "$DESKTOP_USER" 8 "stat -c %u \"\$XDG_RUNTIME_DIR/$real_sock\" 2>/dev/null" | tr -d '[:space:]')
if [[ -z "$sway_uid" || -z "$sock_uid" || "$sway_uid" != "$DESKTOP_UID" || "$sock_uid" != "$DESKTOP_UID" ]]; then
  log "FAIL: sway is not running as the desktop user -- sway pid uid=${sway_uid:-<none>}, socket owner uid=${sock_uid:-<none>}, wanted $DESKTOP_UID"
  exit 1
fi
log "sway up as $DESKTOP_USER (uid $DESKTOP_UID, pid $sway_pid). Wayland socket: $RUNTIME_DIR/$real_sock (linked as $SOCKET_NAME)."
log "IPC: SWAYSOCK=$RUNTIME_DIR/sway-ipc.$DESKTOP_UID.$sway_pid.sock swaymsg ..."
