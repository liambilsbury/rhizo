#!/bin/bash
# restart rhizo-netbridged in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

WAIT=25
if [[ "${1:-}" == "--wait" ]]; then WAIT="$2"; shift 2; fi

SANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"
UNIT=rhizo-netbridged; [[ "$SANDBOX_ID" == 0 ]] || UNIT="rhizo-netbridged-$SANDBOX_ID"
OCTET3=$(( 100 + SANDBOX_ID ))
ULA_PREFIX=fd00:12ab:cd34::
[[ "$SANDBOX_ID" == 0 ]] || printf -v ULA_PREFIX 'fd00:12ab:cd34:%x::' "$SANDBOX_ID"
LOG="/tmp/$UNIT.log"
SRC=/tmp/rhizo-netbridged-src
MAIN=$SRC/netbridged.py
ARGS="--veth-if vethrhz$SANDBOX_ID --veth-addr 192.168.$OCTET3.1 --subnet 192.168.$OCTET3.0/24"
ARGS+=" --pool-start 192.168.$OCTET3.50 --pool-end 192.168.$OCTET3.100"
ARGS+=" --ula-prefix $ULA_PREFIX"
[[ "$SANDBOX_ID" == 0 ]] || ARGS+=" --state-dir /run/$UNIT"
[[ $# -gt 0 ]] && ARGS+=" $*"

wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }

route=$(ssh_vm -t 10 "ip -4 route show default") || { log "FAIL: could not read the guest's default route"; exit 1; }
UPLINK=$(awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<<"$route")
[[ -n "$UPLINK" ]] || { log "FAIL: the guest has no IPv4 default route ($route)"; exit 1; }
ARGS="--uplink $UPLINK $ARGS"

if [[ "${RHIZO_TEST_INSTALLED:-0}" == 1 ]]; then
  # rerun the installed daemon with the launcher's argv plus ours
  SAVED=/run/rhizo-test-netbridged.argv
  ssh_vm -t 15 "[ -s $SAVED ] || { pid=\$(systemctl show -p MainPID --value $UNIT); [ -n \"\$pid\" ] && [ \"\$pid\" != 0 ] \
      && tr '\\0' '\\n' < /proc/\$pid/cmdline > $SAVED.new && mv $SAVED.new $SAVED; }; [ -s $SAVED ]" >/dev/null \
    || { log "FAIL: no running installed $UNIT to read the launcher's argv from"; exit 1; }
  base=$(ssh_vm -t 10 "cat $SAVED" | tr -d '\r')
  log "the launcher's $UNIT argv: $(tr '\n' ' ' <<<"$base")"
  extra=$(printf ' %q' "$@")
  want="${WANT_SERVICES:-dhcp,dns,ra,mdns,proxy}"
  ARGV=$(awk -v svc="$want" 'NR == 1 { next } drop { drop = 0; next } $0 == "--local-a" || $0 == "--portal" { drop = 1; next }
    skip { skip = 0; next } $0 == "--services" { print; print svc; skip = 1; next } { print }' <<<"$base" | tr '\n' ' ')
  LOG=/tmp/$UNIT.log
  KEPT=/run/rhizo-test-netbridged.leases.json
  ssh_vm -t 25 "rm -f $KEPT; cp -p /run/$UNIT/leases.json $KEPT 2>/dev/null
    systemctl stop $UNIT 2>/dev/null; systemctl reset-failed $UNIT 2>/dev/null; rm -f $LOG; true" >/dev/null 2>&1
  start_out=$(ssh_vm -t 40 "systemd-run --unit=$UNIT --collect -p RuntimeDirectory=$UNIT -p User=rhizo-netbridged \
    -p 'ExecStartPre=/bin/sh -c \"[ ! -e $KEPT ] || cp -p $KEPT /run/$UNIT/leases.json\"' \
    -p 'CapabilityBoundingSet=CAP_NET_RAW CAP_NET_BIND_SERVICE' -p 'AmbientCapabilities=CAP_NET_RAW CAP_NET_BIND_SERVICE' \
    -p NoNewPrivileges=yes -p StandardOutput=file:$LOG -p StandardError=file:$LOG /usr/bin/python3 $ARGV$extra" 2>&1)
  start_rc=$?
else
ssh_vm -t 30 "mkdir -p $SRC && cp -f /root/share/netbridged/*.py $SRC/" >/dev/null \
  || { log "FAIL: could not stage src/services/netbridged from the 9p share into $SRC"; exit 1; }
ssh_vm -t 20 "test -r $MAIN" >/dev/null \
  || { log "FAIL: $MAIN is not in the guest"; exit 1; }

ssh_vm -t 25 "systemctl stop $UNIT 2>/dev/null; systemctl reset-failed $UNIT 2>/dev/null; rm -f $LOG; true" >/dev/null 2>&1

start_out=$(ssh_vm -t 40 "systemd-run --unit=$UNIT --collect -p StandardOutput=file:$LOG -p StandardError=file:$LOG python3 $MAIN $ARGS" 2>&1)
start_rc=$?
fi
if (( start_rc != 0 )); then
  log "FAIL: systemd-run did not start the daemon (rc=$start_rc)"
  sed 's/^/    /' <<<"$start_out"
  exit 1
fi

deadline=$(( $(date +%s) + WAIT ))
ready=""
while (( $(date +%s) < deadline )); do
  ready=$(ssh_vm -t 10 "grep -m1 NB_READY $LOG" 2>/dev/null)
  [[ -n "$ready" ]] && break
  sleep 1
done
if [[ -z "$ready" ]]; then
  log "FAIL: rhizo-netbridged did not report NB_READY within ${WAIT}s"
  ssh_vm -t 15 "tail -20 $LOG" 2>&1 | sed 's/^/    /'
  exit 1
fi
want="${WANT_SERVICES:-dhcp,dns,ra,mdns,proxy}"
got=$(sed 's/.*services=//' <<<"$ready" | tr -d '[:space:]')
missing=""
for svc in ${want//,/ }; do
  [[ ",$got," == *",$svc,"* ]] || missing+="$svc "
done
if [[ -n "$missing" ]]; then
  log "FAIL: rhizo-netbridged came up without: ${missing% }"
  ssh_vm -t 15 "grep NB_SERVICE_FAILED $LOG" 2>&1 | sed 's/^/    /'
  exit 1
fi
log "netbridge: ${ready#*] }"
