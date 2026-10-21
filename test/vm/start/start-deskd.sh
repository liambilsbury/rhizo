#!/bin/bash
# start the desktop bridge host half in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

PORT=47100
UNIT=rhizo-deskd.service
LOG=/var/log/rhizo/rhizo-deskd.log

SANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"
if [[ "$SANDBOX_ID" != 0 ]]; then
  log "FAIL: RHIZO_SANDBOX_ID=$SANDBOX_ID -- rhizo-deskd.service is instance-0-only: nothing started"
  exit 1
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }

guest_mount_share || exit 1

if ! ssh_vm -t 10 "command -v xdg-open >/dev/null && command -v xdg-mime >/dev/null && command -v update-desktop-database >/dev/null"; then
  log "FAIL: xdg-open, xdg-mime or update-desktop-database is missing"
  exit 1
fi

ssh_vm -t 10 "test -e /root/share/rhizo-wlbridge" \
  || { log "FAIL: /root/share/rhizo-wlbridge missing -- build it with tools/build/services/wlbridge.sh"; exit 1; }
ssh_vm -t 10 "install -d -m 0755 /usr/lib/rhizo/deskbridge /usr/lib/rhizo/broker" \
  || { log "FAIL: could not create the packaged deskbridge/broker directories"; exit 1; }
timeout 30 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" ../../../src/services/deskbridge/deskd.py ../../../src/services/deskbridge/desk-token.py ../../../src/services/deskbridge/desk-notify.py ../../../src/services/broker/brokerd.py "$SSH_TARGET:/root/" \
  || { log "FAIL: could not copy the bridge sources into the guest"; exit 1; }
ssh_vm -t 10 "install -d -m 0755 /usr/lib/rhizo/tools && install -m 0755 /root/share/capability-allowed.sh /usr/lib/rhizo/tools/capability-allowed.sh && install -D -m 0644 /root/share/sandbox/capabilities.py /usr/lib/rhizo/tools/sandbox/capabilities.py && install -m 0755 /root/share/probe-client.py /usr/lib/rhizo/probe-client.py && install -m 0755 /root/desk-token.py /usr/lib/rhizo/deskbridge/desk-token.py" \
  || { log "FAIL: could not stage the token delivery and capability gate at their packaged paths"; exit 1; }
ssh_vm -t 10 "install -m 0755 /root/share/rhizo-wlbridge /usr/lib/rhizo/deskbridge/rhizo-wlbridge && install -m 0755 /root/deskd.py /usr/lib/rhizo/deskbridge/deskd.py && install -m 0755 /root/desk-notify.py /usr/lib/rhizo/deskbridge/desk-notify.py && install -m 0755 /root/brokerd.py /usr/lib/rhizo/broker/brokerd.py && install -m 0644 /root/share/dbus_min.py /usr/lib/rhizo/dbus_min.py && install -m 0644 /root/share/dbus_min.py /usr/lib/rhizo/deskbridge/dbus_min.py && install -D -m 0644 /root/share/sandbox/capabilities.py /usr/lib/rhizo/sandbox/capabilities.py && install -D -m 0644 /root/share/sandbox/capabilities.py /usr/lib/rhizo/deskbridge/sandbox/capabilities.py" \
  || { log "FAIL: could not stage the bridge binaries at their packaged paths"; exit 1; }

ssh_vm -t 10 "install -D -m 0644 /root/share/rhizo-desktop-session.path /usr/lib/systemd/user/rhizo-desktop-session.path && install -m 0644 /root/share/rhizo-desktop-session.service /usr/lib/systemd/user/rhizo-desktop-session.service && install -m 0644 /root/share/rhizo-desk-notify.path /usr/lib/systemd/user/rhizo-desk-notify.path && install -m 0644 /root/share/rhizo-desk-notify.service /usr/lib/systemd/user/rhizo-desk-notify.service && install -D -m 0644 /root/share/rhizo-desktop-session.tmpfiles /usr/lib/tmpfiles.d/rhizo-desktop-session.conf && systemd-tmpfiles --create rhizo-desktop-session.conf && install -m 0644 /root/share/rhizo-deskd.service /etc/systemd/system/$UNIT && install -m 0644 /root/share/rhizo-desk-token.service /etc/systemd/system/rhizo-desk-token.service" \
  || { log "FAIL: could not install the rhizo-desktop-session user units and tmpfiles entry, $UNIT or rhizo-desk-token.service -- run test/vm/sync.sh first"; exit 1; }

log "Starting the desktop session, then $UNIT on port $PORT..."
# print why deskd cannot reach its session bus
deskd_explain() {
  ssh_vm -t 25 "echo '=== session.env ==='
cat /run/rhizo-desktop/session.env 2>&1
echo '=== systemctl show: $UNIT ==='
systemctl show -p User,EnvironmentFiles,Environment,MainPID,DropInPaths $UNIT 2>&1
echo '=== systemctl --user status: rhizo-desktop-session (desktop user manager) ==='
_su=\$(cat /etc/rhizo/desktop-user 2>/dev/null || echo ubuntu)
runuser -u \"\$_su\" -- env XDG_RUNTIME_DIR=/run/user/\$(id -u \"\$_su\" 2>/dev/null || echo 1000) systemctl --user status --no-pager rhizo-desktop-session.path rhizo-desktop-session.service 2>&1
echo '=== deskd MainPID environ ==='
_mp=\$(systemctl show -p MainPID --value $UNIT 2>/dev/null)
if [ -n \"\$_mp\" ] && [ \"\$_mp\" != 0 ]; then
  echo \"MainPID=\$_mp\"; tr '\\0' '\\n' < /proc/\$_mp/environ 2>&1
else
  echo 'no MainPID -- unit is not running'
fi
echo '=== /run/user, /run/user/<uid> ==='
ls -la /run/user 2>&1
_u=\$(cat /etc/rhizo/desktop-user 2>/dev/null || echo ubuntu)
_uid=\$(id -u \"\$_u\" 2>/dev/null || echo 1000)
ls -la /run/user/\$_uid 2>&1
echo '=== stat of every component of the bus path ==='
stat /run 2>&1; stat /run/user 2>&1; stat /run/user/\$_uid 2>&1; stat /run/user/\$_uid/bus 2>&1
echo '=== ps: sway, dbus-daemon ==='
ps -eo user,pid,args 2>&1 | grep -E 'sway|dbus-daemon' | grep -v grep
echo '=== systemctl list-units rhizo-desk* --all ==='
systemctl list-units 'rhizo-desk*' --all --no-pager 2>&1
echo '=== ps: anything named rhizo-deskd/rhizo-wlbridge, any pid ==='
ps -eo user,pid,ppid,args 2>&1 | grep -E 'rhizo-deskd|rhizo-wlbridge' | grep -v grep
echo '=== journalctl -b --user-unit rhizo-desktop-session -u rhizo-deskd ==='
journalctl -b --user-unit rhizo-desktop-session.service --user-unit rhizo-desktop-session.path -u rhizo-deskd --no-pager 2>&1 | tail -100
echo '=== $LOG: size, mtime, and head ==='
stat -c 'size=%s mtime_epoch=%Y mtime=%y' $LOG 2>&1
head -c 4000 $LOG 2>&1" 2>&1
}

start_cmd="set -u
DESKTOP_USER=\$(cat /etc/rhizo/desktop-user 2>/dev/null || echo ubuntu)
mkdir -p /etc/systemd/system/$UNIT.d
printf '[Service]\nUser=%s\n' \"\$DESKTOP_USER\" > /etc/systemd/system/$UNIT.d/10-desktop-user.conf
mkdir -p /var/log/rhizo
groupadd -f rhizo
chown root:rhizo /var/log/rhizo && chmod 0775 /var/log/rhizo
DESKTOP_UID=\$(id -u \"\$DESKTOP_USER\" 2>/dev/null || echo 1000)
RD=/run/user/\$DESKTOP_UID
systemctl start user@\$DESKTOP_UID.service
if ! runuser -u \"\$DESKTOP_USER\" -- test -S \"\$RD/bus\"; then
  runuser -u \"\$DESKTOP_USER\" -- env XDG_RUNTIME_DIR=\$RD dbus-daemon --session --fork --address=unix:path=\$RD/bus
fi
systemctl daemon-reload
systemctl unmask $UNIT rhizo-desk-token.service >/dev/null 2>&1 || true
systemctl --global unmask rhizo-desktop-session.path rhizo-desktop-session.service rhizo-desk-notify.path rhizo-desk-notify.service >/dev/null 2>&1 || true
systemctl --global enable rhizo-desktop-session.path rhizo-desk-notify.path >/dev/null
runuser -u \"\$DESKTOP_USER\" -- env XDG_RUNTIME_DIR=\$RD sh -c 'systemctl --user daemon-reload; systemctl --user start rhizo-desk-notify.path' >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8 9 10; do
  test -s /run/rhizo-desktop/session.env && break
  runuser -u \"\$DESKTOP_USER\" -- env XDG_RUNTIME_DIR=\$RD sh -c 'systemctl --user daemon-reload; systemctl --user start rhizo-desktop-session.path; systemctl --user start rhizo-desktop-session.service' >/dev/null 2>&1
  sleep 1
done
test -s /run/rhizo-desktop/session.env || { echo DESKD_NO_SESSION_ENV; exit 1; }
systemctl stop $UNIT 2>/dev/null
systemctl reset-failed $UNIT rhizo-desk-token.service 2>/dev/null || true
: > $LOG
date -u '+TRUNCATED_AT %s %Y-%m-%dT%H:%M:%SZ'
systemctl restart $UNIT
for i in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'listening on 192.168.100.1:$PORT' $LOG && break
  sleep 1
done
for i in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'wayland bridge ready' $LOG && break
  sleep 1
done
grep -q 'listening on 192.168.100.1:$PORT' $LOG && echo DESKD_LISTENING
grep -q 'wayland bridge ready' $LOG && echo DESKD_WL_READY
[ \"\$(systemctl is-active $UNIT)\" = active ] && echo DESKD_ACTIVE"
out=$(ssh_vm -t 55 "$start_cmd" 2>&1); echo "$out"
if grep -q DESKD_NO_SESSION_ENV <<<"$out"; then
  log "FAIL: rhizo-desktop-session.service never wrote /run/rhizo-desktop/session.env"
  exit 1
fi
if ! grep -q DESKD_LISTENING <<<"$out"; then
  log "FAIL: rhizo-deskd is not listening on 192.168.100.1:$PORT"
  ssh_vm -t 8 "tail -30 $LOG" >&2
  deskd_explain >&2
  exit 1
fi
if ! grep -q DESKD_WL_READY <<<"$out"; then
  log "FAIL: rhizo-wlbridge never reported ready"
  ssh_vm -t 8 "tail -30 $LOG" >&2
  deskd_explain >&2
  exit 1
fi
if ! grep -q DESKD_ACTIVE <<<"$out"; then
  log "FAIL: $UNIT logged as listening and ready but systemctl is-active does not say active"
  ssh_vm -t 8 "systemctl status $UNIT --no-pager -l 2>&1 | head -20" >&2
  deskd_explain >&2
  exit 1
fi
log "debug: $(ssh_vm -t 10 "_u=\$(cat /etc/rhizo/desktop-user 2>/dev/null || echo ubuntu); _uid=\$(id -u \"\$_u\" 2>/dev/null); echo user=\$_u uid=\$_uid wayland_display=\$(grep -o 'WAYLAND_DISPLAY=.*' /run/rhizo-desktop/session.env 2>/dev/null) dbus=\$(grep -o 'DBUS_SESSION_BUS_ADDRESS=.*' /run/rhizo-desktop/session.env 2>/dev/null)" 2>&1)"
log "desktop host side up: port $PORT, unit $UNIT, session /run/rhizo-desktop/session.env"
