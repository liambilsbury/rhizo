#!/bin/bash
# start rhizo-audiod and PipeWire in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh
source ../../../tools/fetch/pools/deb/deb-pool-lib.sh

BUSES=4
INSTALL_ONLY=0
SOCKET=/run/rhizo-audio/audiod
SANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"
if [[ "$SANDBOX_ID" != 0 ]]; then
  log "FAIL: RHIZO_SANDBOX_ID=$SANDBOX_ID -- the audio host side is instance-0-only: nothing started"
  exit 1
fi
UNIT=rhizo-audiod.service
LOG=/var/log/rhizo/rhizo-audiod.log
while [[ $# -gt 0 ]]; do
  case "$1" in
    --buses) BUSES="$2"; shift 2 ;;
    --socket) SOCKET="$2"; shift 2 ;;
    --install-only) INSTALL_ONLY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ "$SOCKET" != /run/rhizo-audio/audiod ]]; then
  log "note: --socket $SOCKET is accepted but ignored -- rhizo-audiod.service's own ExecStart is fixed at /run/rhizo-audio/audiod"
  SOCKET=/run/rhizo-audio/audiod
fi

REPO="$(cd "../../.." && pwd)"
CAPS_DIR="$REPO/src/androidd"
[[ -f "$CAPS_DIR/sandbox/capabilities.py" ]] || CAPS_DIR="$(pwd)"
policy_err=$(python3 -c "
import sys
sys.path.insert(0, '$CAPS_DIR')
from sandbox import capabilities
sys.exit(0 if capabilities.policy_or_deny().allows('audio.out') else 1)
" 2>&1)
if (( $? != 0 && ! INSTALL_ONLY )); then
  log "audio.out is off${policy_err:+ ($policy_err)} -- not starting pipewire, wireplumber or rhizo-audiod, no socket created"
  exit 0
fi

wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }

DESKTOP_USER=$(ssh_vm -t 10 "cat /etc/rhizo/desktop-user 2>/dev/null" | tr -d '[:space:]')
DESKTOP_USER="${DESKTOP_USER:-ubuntu}"

guest_mount_share || exit 1

PIPEWIRE_DEBS=/root/share/pipewire-debs
PIPEWIRE_PKGS="pipewire pipewire-bin wireplumber libpipewire-0.3-modules"
# print each pipewire package not configured
unconfigured_pipewire() {
  ssh_vm -t 20 ". /etc/os-release || exit 1
  case \$ID in
    cachyos|arch)
      for p in pipewire wireplumber; do pacman -Q \$p >/dev/null 2>&1 || echo \$p; done
      exit 0 ;;
    ubuntu) ;;
    *) echo \"no package query for os-release ID '\$ID'\" >&2; exit 1 ;;
  esac
  for p in $PIPEWIRE_PKGS; do
    st=\$(dpkg-query -W -f='\${db:Status-Abbrev}' \$p 2>/dev/null | tr -d ' ')
    [ \"\$st\" = ii ] || echo \$p
  done"
}

log "Ensuring pipewire/wireplumber are installed and configured (idempotent)..."
missing=$(unconfigured_pipewire) || { log "FAIL: could not ask the guest which pipewire packages dpkg holds configured"; exit 1; }
if [[ -n "$missing" ]]; then
  guest_refuse_install_if_enforcing "pipewire/wireplumber" \
    "boot the vm with test/vm/run-vm.sh and run test/vm/start/start-audio.sh --install-only before test/vm/redeploy.sh launches Android" \
    || exit 1
  if ! ssh_vm -t 8 "ls $PIPEWIRE_DEBS/pipewire_*.deb >/dev/null 2>&1"; then
    log "FAIL: no pipewire .debs reachable on the 9p share:"
    log "  tools/fetch/pools/deb/fetch.sh pipewire-debs"
    exit 1
  fi
  row=$(deb_pool_row pipewire-debs) || exit 1
  IFS=$'\t' read -r _method roots allow <<<"$row"
  [[ "$allow" == - ]] && allow=""
  if ! staged=$(deb_pool_stage pipewire "$PIPEWIRE_DEBS" "$roots" "$allow" \
      "/tmp/pipewire-plan${SUFFIX}.tsv" "/tmp/pipewire-install${SUFFIX}.log"); then
    log "FAIL: $staged"
    exit 1
  fi
  log "$staged"
  still=$(unconfigured_pipewire) || { log "FAIL: could not ask the guest which pipewire packages dpkg holds configured after the install"; exit 1; }
  if [[ -n "$still" ]]; then
    log "FAIL: still not configured after install: $(tr '\n' ' ' <<<"$still")-- see /tmp/pipewire-install${SUFFIX}.log"
    exit 1
  fi
  log "pipewire/wireplumber installed and configured"
else
  log "pipewire/wireplumber already installed and configured"
fi

halfconf=$(ssh_vm -t 20 'dpkg -l | awk "/^i[^i]/ {print \$2}" | tr "\n" " "' 2>/dev/null | tr -d "\r")
if [ -n "${halfconf// /}" ]; then
  log "FAIL: packages are unpacked but NOT configured: $halfconf"
  log "  fix on a NON-enforcing guest:"
  log "    boot the VM without launching Android, then"
  log "    dpkg --configure -a; apt-get update && apt-get --fix-broken install -y"
  exit 1
fi

if (( INSTALL_ONLY )); then
  log "pipewire installed and configured (--install-only, not starting the audio host side)"
  exit 0
fi

INSTALLED=0
[[ "${RHIZO_TEST_INSTALLED:-0}" == 1 ]] && INSTALLED=1
log "Ensuring the desktop session is resolved..."
if (( INSTALLED )); then
  log "RHIZO_TEST_INSTALLED=1: using the installed units and the session's PipeWire, staging nothing from this tree"
  session_cmd="test -s /run/rhizo-desktop/session.env && echo SESSION_ENV_OK"
else
session_cmd="mkdir -p /var/log/rhizo
groupadd -f rhizo
chown root:rhizo /var/log/rhizo && chmod 0775 /var/log/rhizo
id -u $DESKTOP_USER >/dev/null 2>&1 || useradd -m -s /bin/bash $DESKTOP_USER
usermod -aG rhizo $DESKTOP_USER
mkdir -p /etc/systemd/system/$UNIT.d
printf '[Service]\nUser=%s\nGroup=rhizo\n' '$DESKTOP_USER' > /etc/systemd/system/$UNIT.d/10-desktop-user.conf
systemctl daemon-reload
install -D -m 0644 /root/share/rhizo-desktop-session.path /usr/lib/systemd/user/rhizo-desktop-session.path
install -m 0644 /root/share/rhizo-desktop-session.service /usr/lib/systemd/user/rhizo-desktop-session.service
install -D -m 0644 /root/share/rhizo-desktop-session.tmpfiles /usr/lib/tmpfiles.d/rhizo-desktop-session.conf
systemd-tmpfiles --create rhizo-desktop-session.conf
systemctl --global unmask rhizo-desktop-session.path rhizo-desktop-session.service >/dev/null 2>&1 || true
systemctl --global enable rhizo-desktop-session.path >/dev/null
DU_UID=\$(id -u $DESKTOP_USER)
systemctl start user@\$DU_UID.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  test -s /run/rhizo-desktop/session.env && break
  runuser -u $DESKTOP_USER -- env XDG_RUNTIME_DIR=/run/user/\$DU_UID sh -c 'systemctl --user daemon-reload; systemctl --user start rhizo-desktop-session.path; systemctl --user start rhizo-desktop-session.service' >/dev/null 2>&1
  sleep 1
done
test -s /run/rhizo-desktop/session.env && echo SESSION_ENV_OK"
fi
out=$(ssh_vm -t 20 "$session_cmd" 2>&1); echo "$out"
if ! grep -q SESSION_ENV_OK <<<"$out"; then
  log "FAIL: the desktop user's rhizo-desktop-session.service never wrote /run/rhizo-desktop/session.env"
  exit 1
fi

if (( ! INSTALLED )); then
  ssh_vm -t 10 "install -d -m 0755 /usr/lib/rhizo/audiod && install -m 0755 /root/share/rhizo-audiod /usr/lib/rhizo/audiod/rhizo-audiod" \
    || { log "FAIL: could not stage rhizo-audiod at its packaged path (build it with tools/build/services/audiod.sh)"; exit 1; }
  ssh_vm -t 10 "install -d -m 0755 /usr/lib/rhizo/tools && install -m 0755 /root/share/capability-allowed.sh /usr/lib/rhizo/tools/capability-allowed.sh && install -D -m 0644 /root/share/sandbox/capabilities.py /usr/lib/rhizo/sandbox/capabilities.py" \
    || { log "FAIL: could not stage the audio.out capability gate"; exit 1; }
  ssh_vm -t 10 "install -m 0644 /root/share/rhizo-audiod.service /etc/systemd/system/$UNIT" \
    || { log "FAIL: could not install $UNIT -- run test/vm/sync.sh first"; exit 1; }
fi

AUDIO_GRAPH_SH=$(cat <<'AUDIO_GRAPH_EOF'
set -u
U="$1"; BUSES="$2"; INSTALLED="${3:-0}"
fail() { echo "AUDIO_GRAPH_FAIL $*"; exit 1; }
if ! uid=$(id -u "$U") || ! gid=$(id -g "$U"); then fail "no account '$U'"; fi
rd="/run/user/$uid"
as_user() { runuser -u "$U" -- env XDG_RUNTIME_DIR="$rd" "$@"; }
domain_of() { [ -n "${1:-}" ] && [ "$1" != 0 ] && cat "/proc/$1/attr/current" 2>/dev/null | tr -d '\0'; }
RIG_PW=rhizo-rig-pipewire.service
RIG_WP=rhizo-rig-wireplumber.service
SESSION_UNITS=(pipewire-pulse.socket pipewire-pulse.service wireplumber.service pipewire.socket pipewire.service)
# stop the session's PipeWire units and wait for their processes to exit
stop_session_pipewire() {
  local loaded left=""
  mapfile -t loaded < <(as_user systemctl --user list-units --all --plain --no-legend "${SESSION_UNITS[@]}" | awk '{print $1}')
  [ "${#loaded[@]}" = 0 ] || as_user systemctl --user stop "${loaded[@]}"
  for _ in $(seq 1 20); do
    left=$(pgrep -u "$uid" -x 'pipewire|wireplumber' | tr '\n' ' ')
    [ -z "$left" ] && break
    sleep 0.25
  done
  [ -z "$left" ] || fail "the session's own PipeWire is still running after systemctl --user stop (pids $left)"
}

mgr=$(systemctl show -p MainPID --value "user@$uid.service")
mgr_domain=$(domain_of "$mgr")
echo "AUDIO_GRAPH user@$uid.service pid=${mgr:-0} domain=${mgr_domain:-unreadable}"
pw=""
if [ "$INSTALLED" = 1 ]; then
  echo "AUDIO_GRAPH installed guest: the session's PipeWire"
  as_user systemctl --user start pipewire.socket pipewire.service wireplumber.service || fail "$U's pipewire and wireplumber did not start"
elif [ "$mgr_domain" = u:r:kernel:s0 ]; then
  if systemctl is-active --quiet "$RIG_PW" && systemctl is-active --quiet "$RIG_WP"; then
    echo "AUDIO_GRAPH reusing $RIG_PW and $RIG_WP"
  else
    for u in "$RIG_WP" "$RIG_PW"; do
      case "$(systemctl show -p ActiveState --value "$u")" in
        active|activating|reloading|deactivating) systemctl stop "$u" ;;
      esac
      [ "$(systemctl show -p ActiveState --value "$u")" = failed ] && systemctl reset-failed "$u"
    done
    stop_session_pipewire
    systemd-run --quiet --unit=$RIG_PW --uid="$uid" --gid="$gid" \
      --setenv=XDG_RUNTIME_DIR="$rd" --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$rd/bus" \
      /usr/bin/pipewire || fail "$RIG_PW did not start"
    up=0
    for _ in $(seq 1 40); do
      as_user pw-cli info 0 >/dev/null 2>&1 && { up=1; break; }
      sleep 0.25
    done
    [ "$up" = 1 ] || fail "$RIG_PW never answered on $rd/pipewire-0"
    systemd-run --quiet --unit=$RIG_WP --uid="$uid" --gid="$gid" \
      --setenv=XDG_RUNTIME_DIR="$rd" --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=$rd/bus" \
      /usr/bin/wireplumber || fail "$RIG_WP did not start"
    echo "AUDIO_GRAPH replaced the session's PipeWire with $RIG_PW and $RIG_WP"
  fi
  pw=$(systemctl show -p MainPID --value "$RIG_PW")
else
  as_user systemctl --user daemon-reload
  stuck=""
  for p in $(pgrep -u "$uid" -x 'pipewire|wireplumber'); do
    [ "$(domain_of "$p")" = u:r:kernel:s0 ] && stuck="$stuck $p"
  done
  if [ -n "$stuck" ]; then
    stop_session_pipewire
    echo "AUDIO_GRAPH stopped $U's own PipeWire left in kernel (pids$stuck)"
  fi
  as_user systemctl --user start pipewire.socket pipewire.service wireplumber.service \
    || fail "$U's own pipewire and wireplumber did not start"
  echo "AUDIO_GRAPH started $U's own pipewire.socket, pipewire.service and wireplumber.service"
fi

wp_up=0
for _ in $(seq 1 60); do
  as_user pw-cli ls Client 2>/dev/null | grep -q 'application.name = "WirePlumber"' && { wp_up=1; break; }
  sleep 0.5
done
[ "$wp_up" = 1 ] || fail "WirePlumber never registered with $U's PipeWire"
{ [ -n "$pw" ] && [ "$pw" != 0 ]; } || pw=$(pgrep -u "$uid" -x pipewire | head -1)
pw_domain=$(domain_of "$pw")
echo "AUDIO_GRAPH pipewire pid=${pw:-0} domain=${pw_domain:-unreadable}"
[ "$pw_domain" != u:r:kernel:s0 ] || fail "PipeWire (pid $pw) still carries the kernel initial SID"

sinks_present() {
  as_user pw-dump | python3 -c '
import json, sys
for obj in json.load(sys.stdin):
    props = (obj.get("info") or {}).get("props") or {}
    if props.get("media.class") == "Audio/Sink" and props.get("node.name"):
        print(props["node.name"])'
}
want=""
for i in $(seq 0 $((BUSES - 1))); do want="$want rhizo_sink_bus$i"; done
want="$want rhizo_sink_primary"
have=" $(sinks_present | tr '\n' ' ') "
for n in $want; do
  case "$have" in *" $n "*) continue ;; esac
  case "$n" in
    rhizo_sink_primary) extra="node.description=RhizoPrimary" ;;
    *) extra="node.description=RhizoBus${n#rhizo_sink_bus} monitor.channel-volumes=true" ;;
  esac
  as_user pw-cli create-node adapter "{ factory.name=support.null-audio-sink node.name=$n media.class=Audio/Sink object.linger=true audio.position=[FL FR] $extra }" \
    || echo "AUDIO_GRAPH pw-cli create-node $n exited $?"
done
missing=""
for _ in $(seq 1 20); do
  have=" $(sinks_present | tr '\n' ' ') "
  missing=""
  for n in $want; do
    case "$have" in *" $n "*) ;; *) missing="$missing $n" ;; esac
  done
  [ -z "$missing" ] && break
  sleep 0.25
done
if [ -n "$missing" ]; then
  journalctl -q --no-pager _UID="$uid" _COMM=pipewire -n 15 | sed 's/^/AUDIO_GRAPH pipewire: /'
  fail "null sinks absent from the graph after pw-cli create-node:$missing"
fi
echo "AUDIO_GRAPH_OK$want"
AUDIO_GRAPH_EOF
)

log "Resolving $DESKTOP_USER's PipeWire and creating $BUSES null sinks (rhizo_sink_bus0..$((BUSES-1)), rhizo_sink_primary)..."
graph_out=$(ssh_vm -t 120 "bash -c $(printf %q "$AUDIO_GRAPH_SH") audio-graph $DESKTOP_USER $BUSES $INSTALLED" 2>&1)
echo "$graph_out"
if ! grep -q '^AUDIO_GRAPH_OK' <<<"$graph_out"; then
  log "FAIL: the audio graph is not ready -- see the AUDIO_GRAPH lines above"
  exit 1
fi

log "Starting $UNIT on $SOCKET..."
audiod_cmd="systemctl daemon-reload
systemctl unmask $UNIT >/dev/null 2>&1 || true
systemctl stop $UNIT 2>/dev/null
systemctl reset-failed $UNIT 2>/dev/null || true
rm -f $SOCKET
: > $LOG
systemctl restart $UNIT
for i in 1 2 3 4 5 6 7 8 9 10; do
  state=\$(systemctl is-active $UNIT 2>/dev/null)
  [[ \"\$state\" == active ]] && [[ -S $SOCKET ]] && break
  sleep 1
done
[[ \"\$(systemctl is-active $UNIT 2>/dev/null)\" == active ]] && echo AUDIOD_UNIT_ACTIVE
test -S $SOCKET && echo AUDIOD_SOCKET_OK
ls -la $SOCKET
systemctl is-active $UNIT"
out=$(ssh_vm -t 20 "$audiod_cmd" 2>&1); echo "$out"
if ! grep -q AUDIOD_UNIT_ACTIVE <<<"$out"; then
  log "FAIL: $UNIT never became active"
  ssh_vm -t 8 "tail -20 $LOG" >&2
  exit 1
fi
if ! grep -q AUDIOD_SOCKET_OK <<<"$out"; then
  log "FAIL: rhizo-audiod socket did not appear"
  ssh_vm -t 8 "tail -20 $LOG" >&2
  exit 1
fi
log "audio host side up: $SOCKET, $BUSES buses, map /run/rhizo-audio-map"
