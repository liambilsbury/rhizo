#!/bin/bash
# start serve-dns-http.py in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

IP="${1:?usage: start-netserv.sh <bind/answer-ip> [hostname]}"
HOSTNAME="${2:-rhizo-test.internal}"

wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }

UNMANAGED_NET=/etc/systemd/network/90-rhizo-veth.network
if ssh_vm -t 10 "test -f $UNMANAGED_NET" >/dev/null 2>&1; then
  if ssh_vm -t 20 "grep -q Unmanaged=yes $UNMANAGED_NET" >/dev/null 2>&1; then
    log "the retired networkd unit is already neutralized"
  else
    log "neutralizing the retired networkd unit left on this vm"
    ssh_vm -t 25 "printf '[Match]\nName=vethrhz0\n\n[Link]\nUnmanaged=yes\n' > $UNMANAGED_NET && networkctl reload && ip addr replace $IP/24 dev vethrhz0 && ip -6 addr replace fd00:12ab:cd34::1/64 dev vethrhz0 && ip link set vethrhz0 up" >/dev/null 2>&1 \
      || log "note: could not neutralize $UNMANAGED_NET"
  fi
fi

NET_WAIT="${RHIZO_NET_WAIT:-60}"
# print the veth address line for an IP
veth_addr_ready() {
  ssh_vm -t 10 'ip -4 -o addr show' 2>/dev/null | grep -F "inet $1/"
}
wait_for_nonempty "$NET_WAIT" veth_addr_ready "$IP" >/dev/null \
  || { log "FAIL: $IP was never assigned to the veth (waited ${NET_WAIT}s)"; exit 1; }

log "Starting serve-dns-http.py (DNS+HTTP on ${IP}, hostname=${HOSTNAME})..."
guest_mount_share || exit 1
ssh_vm -t 15 "cp -f /root/share/serve-dns-http.py /root/serve-dns-http.py
if [ -f /run/rhizo-netserv.pid ]; then kill -9 \"\$(cat /run/rhizo-netserv.pid)\" 2>/dev/null; rm -f /run/rhizo-netserv.pid; fi
sleep 1
setsid sh -c 'echo \$\$ > /run/rhizo-netserv.pid; exec python3 /root/serve-dns-http.py --ip $IP --hostname $HOSTNAME' >/tmp/rhizo-netserv.log 2>&1 < /dev/null & disown
sleep 1; echo launched" >/dev/null 2>&1 || true

ssh_vm -t 10 "cat > /root/rhizo-dns-probe.py <<'PYEOF'
import socket, sys
hostname, ip = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
labels = b''.join(bytes([len(l)]) + l.encode() for l in hostname.split('.'))
q = b'\\x12\\x34\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00' + labels + b'\\x00\\x00\\x01\\x00\\x01'
s.sendto(q, (ip, 53))
data, _ = s.recvfrom(512)
sys.exit(0 if data[:2] == q[:2] and (data[3] & 0x0f) == 0 else 1)
PYEOF" || { log "FAIL: could not write the DNS probe script"; exit 1; }

log "Self-verifying the product resolver and this HTTP endpoint..."
deadline=$(( $(date +%s) + 15 ))
ok=0
while (( $(date +%s) < deadline )); do
  if ssh_vm -t 5 "python3 /root/rhizo-dns-probe.py '$HOSTNAME' '$IP'" \
     && ssh_vm -t 5 "curl -sf http://$IP/nettest | grep -q RHIZO-NET-OK"; then
    ok=1; break
  fi
  sleep 1
done
if [[ "$ok" != 1 ]]; then
  log "FAIL: the resolver/HTTP self-check did not pass within 15s"
  ssh_vm -t 5 "tail -30 /tmp/rhizo-netserv.log" 2>&1
  exit 1
fi
log "netserv up on $IP (HTTP:80 /nettest+/generate_204+/throughput); rhizo-netbridged answers $HOSTNAME on :53"
