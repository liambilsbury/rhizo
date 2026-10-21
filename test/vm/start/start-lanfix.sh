#!/bin/bash
# start lan-fixture.py in a vm namespace
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

HOST_IP="10.77.0.1"
NS_IP="10.77.0.2"
PORT="8053"
INSTANCE="rhizo-lanfix"

if [[ "${1:-}" == "--down" ]]; then
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  log "Tearing down the rhizolan namespace and veth pair..."
  ssh_vm -t 10 "if [ -f /run/rhizo-lanfix.pid ]; then kill -9 \"\$(cat /run/rhizo-lanfix.pid)\" 2>/dev/null; rm -f /run/rhizo-lanfix.pid; fi
while iptables -C FORWARD -o rhizolan0 -s 192.168.100.0/24 -j ACCEPT 2>/dev/null; do iptables -D FORWARD -o rhizolan0 -s 192.168.100.0/24 -j ACCEPT; done
while iptables -C FORWARD -i rhizolan0 -d 192.168.100.0/24 -j ACCEPT 2>/dev/null; do iptables -D FORWARD -i rhizolan0 -d 192.168.100.0/24 -j ACCEPT; done
ip netns del rhizolan 2>/dev/null
ip link del rhizolan0 2>/dev/null
echo down" || { log "FAIL: teardown did not complete"; exit 1; }
  log "rhizolan namespace and veth pair removed"
  exit 0
fi

wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }

log "Creating the rhizolan namespace and veth pair (${HOST_IP} <-> ${NS_IP})..."
ssh_vm -t 15 "if ! ip netns list | grep -q '^rhizolan '; then ip netns add rhizolan; fi
if ! ip link show rhizolan0 >/dev/null 2>&1; then
  ip link add rhizolan0 type veth peer name rhizolan1
  ip link set rhizolan1 netns rhizolan
fi
ip addr replace ${HOST_IP}/24 dev rhizolan0
ip link set rhizolan0 up
ip link set rhizolan0 multicast on
nsenter --net=/var/run/netns/rhizolan ip addr replace ${NS_IP}/24 dev rhizolan1
nsenter --net=/var/run/netns/rhizolan ip link set rhizolan1 up
nsenter --net=/var/run/netns/rhizolan ip link set rhizolan1 multicast on
nsenter --net=/var/run/netns/rhizolan ip link set lo up
nsenter --net=/var/run/netns/rhizolan ip route replace 192.168.100.0/24 via ${HOST_IP}
iptables -C FORWARD -o rhizolan0 -s 192.168.100.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o rhizolan0 -s 192.168.100.0/24 -j ACCEPT
iptables -C FORWARD -i rhizolan0 -d 192.168.100.0/24 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i rhizolan0 -d 192.168.100.0/24 -j ACCEPT
echo netns-ready" \
  || { log "FAIL: could not create the namespace/veth pair"; exit 1; }

log "Starting lan-fixture.py (mDNS+TCP on ${NS_IP}:${PORT} inside rhizolan)..."
guest_mount_share || exit 1
ssh_vm -t 15 "cp -f /root/share/lan-fixture.py /root/lan-fixture.py
if [ -f /run/rhizo-lanfix.pid ]; then kill -9 \"\$(cat /run/rhizo-lanfix.pid)\" 2>/dev/null; rm -f /run/rhizo-lanfix.pid; fi
sleep 1
setsid nsenter --net=/var/run/netns/rhizolan sh -c 'echo \$\$ > /run/rhizo-lanfix.pid; exec python3 /root/lan-fixture.py --iface rhizolan1 --ip $NS_IP --port $PORT --instance $INSTANCE' >/tmp/rhizo-lanfix.log 2>&1 < /dev/null & disown
sleep 1; echo launched" >/dev/null 2>&1 || true

ssh_vm -t 10 "cat > /root/rhizo-lanfix-probe.py <<'PYEOF'
import socket, struct, sys, time
iface, timeout_s = sys.argv[1], float(sys.argv[2])
group, port = '224.0.0.251', 5353
def encode_name(name):
    out = bytearray()
    for label in name.split('.'):
        out.append(len(label))
        out.extend(label.encode('ascii'))
    out.append(0)
    return bytes(out)
qname = encode_name('_rhizotest._tcp.local')
query = struct.pack('>HHHHHH', 0x5150, 0, 1, 0, 0, 0) + qname + struct.pack('>HH', 12, 1)
ifindex = socket.if_nametoindex(iface)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
s.bind(('', port))
mreq = struct.pack('=4s4si', socket.inet_aton(group), b'\\x00\\x00\\x00\\x00', ifindex)
s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, mreq)
s.settimeout(timeout_s)
s.sendto(query, (group, port))
deadline = time.time() + timeout_s
while time.time() < deadline:
    try:
        data, addr = s.recvfrom(65536)
    except socket.timeout:
        break
    if len(data) >= 8 and struct.unpack('>HHHH', data[:8])[3] > 0:
        sys.exit(0)
sys.exit(1)
PYEOF" || { log "FAIL: could not write the mDNS probe script"; exit 1; }

log "Self-verifying TCP marker + mDNS responder..."
deadline=$(( $(date +%s) + 15 ))
ok=0
while (( $(date +%s) < deadline )); do
  if ssh_vm -t 5 "timeout 3 bash -c 'exec 3<>/dev/tcp/${NS_IP}/${PORT}; cat <&3' | grep -q RHIZO-LAN-OK" \
     && ssh_vm -t 8 "python3 /root/rhizo-lanfix-probe.py rhizolan0 3"; then
    ok=1; break
  fi
  sleep 1
done
if [[ "$ok" != 1 ]]; then
  log "FAIL: TCP+mDNS self-check did not pass within 15s"
  ssh_vm -t 5 "tail -30 /tmp/rhizo-lanfix.log" 2>&1
  exit 1
fi
log "lanfix up and self-verified (TCP:${NS_IP}:${PORT} -> RHIZO-LAN-OK, mDNS on rhizolan0 answered a real _rhizotest._tcp.local query)"
