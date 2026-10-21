#!/bin/bash
# start network test fixtures in the vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

UPSTREAM_A_IP="127.0.0.2"
UPSTREAM_B_IP="127.0.0.3"
UPSTREAM_A_PID="/run/rhizo-netfix-up-a.pid"
UPSTREAM_B_PID="/run/rhizo-netfix-up-b.pid"
UPSTREAM_A_LOG="/tmp/rhizo-netfix-up-a.log"
UPSTREAM_B_LOG="/tmp/rhizo-netfix-up-b.log"

RESOLV_BACKUP="/tmp/rhizo-netfix-resolv.orig"
ENV_BACKUP="/tmp/rhizo-netfix-environment.orig"

PROXY_NS="rhizoproxy"
PROXY_VETH_HOST="rhizopx0"
PROXY_VETH_NS="rhizopx1"
PROXY_HOST_IP="10.88.0.1"
PROXY_NS_IP="10.88.0.2"
PROXY_ORIGIN_PID="/run/rhizo-proxyorigin.pid"
PROXY_ORIGIN_LOG="/tmp/rhizo-proxyorigin.log"

PROXYFIX_MANIFEST="/run/rhizo-proxyfix.ports"

PORTAL_DIR="/run/rhizo-netbridged"
PORTAL_FILE="$PORTAL_DIR/portal"

usage() {
  cat >&2 <<'EOF'
usage: start-netfix.sh upstreams up <name> | upstreams down
       start-netfix.sh resolver <ip> | resolver restore
       start-netfix.sh hostproxy <url> | hostproxy none
       start-netfix.sh proxyorigin up | proxyorigin down
       start-netfix.sh proxyup <port> <tag> | proxydown
       start-netfix.sh portalserv up <ip> | portalserv down
       start-netfix.sh v6origin up | v6origin down
       start-netfix.sh portal on <ip> | portal off
       start-netfix.sh status
EOF
  exit 1
}

# mount the share or exit
mount_share() {
  guest_mount_share || exit 1
}

PORTALSERV_PID="/tmp/rhizo-portalserv.pid"
PORTALSERV_LOG="/tmp/rhizo-portalserv.log"

# start the captive portal HTTP endpoint
portalserv_up() {
  local ip="$1"
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  mount_share
  log "starting the captive-portal endpoint on $ip:80..."
  ssh_vm -t 25 "cp -f /root/share/serve-dns-http.py /root/serve-dns-http.py
ip addr replace $ip/24 dev vethrhz0
if [ -f $PORTALSERV_PID ]; then kill -9 \"\$(cat $PORTALSERV_PID)\" 2>/dev/null; rm -f $PORTALSERV_PID; fi
sleep 1
setsid sh -c 'echo \$\$ > $PORTALSERV_PID; exec python3 /root/serve-dns-http.py --ip $ip --portal-redirect http://$ip/signin' >$PORTALSERV_LOG 2>&1 < /dev/null & disown
sleep 1; echo launched" >/dev/null 2>&1 || true

  local deadline=$(( $(date +%s) + 20 )) code=""
  while (( $(date +%s) < deadline )); do
    code=$(ssh_vm -t 8 "curl -s -o /dev/null -w '%{http_code}' http://$ip/generate_204" 2>/dev/null)
    [[ "$code" == "302" ]] && { log "portal endpoint up on $ip, answering /generate_204 with 302"; return 0; }
    sleep 2
  done
  log "FAIL: the portal endpoint answered '${code:-nothing}' instead of 302 within 20s"
  ssh_vm -t 10 "tail -10 $PORTALSERV_LOG" 2>&1 | sed 's/^/    /'
  return 1
}

# stop the portal endpoint
portalserv_down() {
  ssh_vm -t 15 "if [ -f $PORTALSERV_PID ]; then kill -9 \"\$(cat $PORTALSERV_PID)\" 2>/dev/null; rm -f $PORTALSERV_PID; fi; true" >/dev/null 2>&1
  log "portal endpoint stopped"
}

V6ORIGIN_IP="fd00:12ab:cd34::1"
V6ORIGIN_PID="/tmp/rhizo-v6origin.pid"
V6ORIGIN_LOG="/tmp/rhizo-v6origin.log"

# start an IPv6 HTTP endpoint on the veth
v6origin_up() {
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  mount_share
  log "starting the IPv6 origin on [$V6ORIGIN_IP]:80..."
  ssh_vm -t 20 "cp -f /root/share/serve-dns-http.py /root/serve-dns-http.py
ip -6 addr replace $V6ORIGIN_IP/64 dev vethrhz0
if [ -f $V6ORIGIN_PID ]; then kill -9 \"\$(cat $V6ORIGIN_PID)\" 2>/dev/null; rm -f $V6ORIGIN_PID; fi
sleep 1
setsid sh -c 'echo \$\$ > $V6ORIGIN_PID; exec python3 /root/serve-dns-http.py --ip $V6ORIGIN_IP' >$V6ORIGIN_LOG 2>&1 < /dev/null & disown
sleep 1; echo launched" >/dev/null 2>&1 || true

  local deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    if ssh_vm -t 8 "curl -sf -g http://[$V6ORIGIN_IP]/nettest" 2>/dev/null | grep -q RHIZO-NET-OK; then
      log "v6 origin up and self-verified on [$V6ORIGIN_IP]:80"
      return 0
    fi
    sleep 1
  done
  log "FAIL: the IPv6 origin did not answer within 15s"
  ssh_vm -t 10 "tail -10 $V6ORIGIN_LOG" 2>&1 | sed 's/^/    /'
  return 1
}

# stop the v6 origin
v6origin_down() {
  ssh_vm -t 15 "if [ -f $V6ORIGIN_PID ]; then kill -9 \"\$(cat $V6ORIGIN_PID)\" 2>/dev/null; rm -f $V6ORIGIN_PID; fi; true" >/dev/null 2>&1
  log "v6 origin stopped"
}

# start two DNS and HTTP endpoints
upstreams_up() {
  local name="$1"
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  mount_share
  log "starting two netserv upstreams answering $name (127.0.0.2, 127.0.0.3)..."
  ssh_vm -t 15 "cp -f /root/share/serve-dns-http.py /root/serve-dns-http.py
if [ -f $UPSTREAM_A_PID ]; then kill -9 \"\$(cat $UPSTREAM_A_PID)\" 2>/dev/null; rm -f $UPSTREAM_A_PID; fi
if [ -f $UPSTREAM_B_PID ]; then kill -9 \"\$(cat $UPSTREAM_B_PID)\" 2>/dev/null; rm -f $UPSTREAM_B_PID; fi
sleep 1
setsid sh -c 'echo \$\$ > $UPSTREAM_A_PID; exec python3 /root/serve-dns-http.py --ip $UPSTREAM_A_IP --hostname $name --with-dns --ttl 1' >$UPSTREAM_A_LOG 2>&1 < /dev/null & disown
setsid sh -c 'echo \$\$ > $UPSTREAM_B_PID; exec python3 /root/serve-dns-http.py --ip $UPSTREAM_B_IP --hostname $name --with-dns --ttl 1' >$UPSTREAM_B_LOG 2>&1 < /dev/null & disown
sleep 1; echo launched" >/dev/null 2>&1 || true

  ssh_vm -t 10 "cat > /root/rhizo-netfix-dns-probe.py <<'PYEOF'
import socket, sys
hostname, ip, timeout_s = sys.argv[1], sys.argv[2], float(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(timeout_s)
labels = b''.join(bytes([len(l)]) + l.encode() for l in hostname.split('.'))
q = b'\\x12\\x34\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00' + labels + b'\\x00\\x00\\x01\\x00\\x01'
s.sendto(q, (ip, 53))
data, _ = s.recvfrom(512)
if data[:2] != q[:2] or (data[3] & 0x0f) != 0:
    sys.exit(1)
print('.'.join(str(b) for b in data[-4:]))
PYEOF" || { log "FAIL: could not write the netfix DNS probe script"; exit 1; }

  local got_a="" got_b="" http_a="" http_b="" ok=0
  deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    got_a=$(ssh_vm -t 5 "python3 /root/rhizo-netfix-dns-probe.py '$name' '$UPSTREAM_A_IP' 3" 2>/dev/null)
    got_b=$(ssh_vm -t 5 "python3 /root/rhizo-netfix-dns-probe.py '$name' '$UPSTREAM_B_IP' 3" 2>/dev/null)
    http_a=$(ssh_vm -t 5 "curl -sf http://$UPSTREAM_A_IP/nettest" 2>/dev/null)
    http_b=$(ssh_vm -t 5 "curl -sf http://$UPSTREAM_B_IP/nettest" 2>/dev/null)
    if [[ "$got_a" == "$UPSTREAM_A_IP" && "$got_b" == "$UPSTREAM_B_IP" \
          && "$http_a" == *RHIZO-NET-OK* && "$http_b" == *RHIZO-NET-OK* ]]; then
      ok=1; break
    fi
    sleep 1
  done
  if [[ "$ok" != 1 ]]; then
    log "FAIL: upstreams did not self-verify within 15s (A answered '$got_a', B answered '$got_b')"
    ssh_vm -t 5 "tail -20 $UPSTREAM_A_LOG; echo ---; tail -20 $UPSTREAM_B_LOG" 2>&1
    exit 1
  fi
  log "upstreams up: $name -> A ($UPSTREAM_A_IP) and B ($UPSTREAM_B_IP) each answer with their own address"
}

# stop the netserv upstreams
upstreams_down() {
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  log "stopping the netserv upstreams..."
  ssh_vm -t 10 "if [ -f $UPSTREAM_A_PID ]; then kill -9 \"\$(cat $UPSTREAM_A_PID)\" 2>/dev/null; rm -f $UPSTREAM_A_PID; fi
if [ -f $UPSTREAM_B_PID ]; then kill -9 \"\$(cat $UPSTREAM_B_PID)\" 2>/dev/null; rm -f $UPSTREAM_B_PID; fi
echo down" || { log "FAIL: upstream teardown did not complete"; exit 1; }
  log "netserv upstreams stopped"
}

# point the guest resolv.conf at a nameserver
resolver_up() {
  local ip="$1" target owner uid gid got ok
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  target=$(ssh_vm -t 8 "readlink -f /etc/resolv.conf")
  [[ -n "$target" ]] || { log "FAIL: could not resolve /etc/resolv.conf's real target"; exit 1; }
  log "resolv.conf target is $target"

  if ! ssh_vm -t 8 "[ -f $RESOLV_BACKUP ]"; then
    ssh_vm -t 8 "cp -f $target $RESOLV_BACKUP && chmod 0644 $RESOLV_BACKUP" \
      || { log "FAIL: could not back up $target to $RESOLV_BACKUP"; exit 1; }
    log "backed up $target -> $RESOLV_BACKUP"
  fi

  owner=$(ssh_vm -t 8 "stat -c '%u:%g' $target")
  [[ -n "$owner" ]] || { log "FAIL: could not stat $target's owner"; exit 1; }
  uid="${owner%%:*}"; gid="${owner##*:}"

  ssh_vm -t 8 "setpriv --reuid=$uid --regid=$gid --clear-groups tee $target >/dev/null" <<<"nameserver $ip" \
    || { log "FAIL: could not write $target as uid=$uid gid=$gid"; exit 1; }

  ok=0; deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    got=$(ssh_vm -t 5 "cat $target" 2>/dev/null)
    [[ "$got" == "nameserver $ip" ]] && { ok=1; break; }
    sleep 1
  done
  [[ "$ok" == 1 ]] || { log "FAIL: $target reads '$got', not 'nameserver $ip', within 15s"; exit 1; }
  log "resolver pointed at $ip ($target)"
}

# restore the guest resolv.conf from its backup
resolver_restore() {
  local target owner uid gid want got ok
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  if ! ssh_vm -t 8 "[ -f $RESOLV_BACKUP ]"; then
    log "resolver already at its original setting (no backup present)"
    return 0
  fi
  target=$(ssh_vm -t 8 "readlink -f /etc/resolv.conf")
  [[ -n "$target" ]] || { log "FAIL: could not resolve /etc/resolv.conf's real target"; exit 1; }
  owner=$(ssh_vm -t 8 "stat -c '%u:%g' $target")
  [[ -n "$owner" ]] || { log "FAIL: could not stat $target's owner"; exit 1; }
  uid="${owner%%:*}"; gid="${owner##*:}"

  ssh_vm -t 8 "setpriv --reuid=$uid --regid=$gid --clear-groups cp $RESOLV_BACKUP $target" \
    || { log "FAIL: could not restore $target from $RESOLV_BACKUP"; exit 1; }

  want=$(ssh_vm -t 8 "cat $RESOLV_BACKUP")
  ok=0; deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    got=$(ssh_vm -t 5 "cat $target" 2>/dev/null)
    [[ "$got" == "$want" ]] && { ok=1; break; }
    sleep 1
  done
  [[ "$ok" == 1 ]] || { log "FAIL: $target does not match the backup within 15s"; exit 1; }
  ssh_vm -t 8 "rm -f $RESOLV_BACKUP" || true
  log "resolver restored to its original setting ($target)"
}

# set https_proxy in /etc/environment
hostproxy_up() {
  local url="$1" got ok
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  if ! ssh_vm -t 8 "[ -f $ENV_BACKUP ]"; then
    ssh_vm -t 8 "cp -f /etc/environment $ENV_BACKUP && chmod 0644 $ENV_BACKUP" \
      || { log "FAIL: could not back up /etc/environment"; exit 1; }
    log "backed up /etc/environment -> $ENV_BACKUP"
  fi
  ssh_vm -t 8 "{ grep -vE '^[[:space:]]*(export[[:space:]]+)?(https?|all|no)_proxy=' /etc/environment || true; echo 'https_proxy=$url'; } > /tmp/rhizo-env.new && cat /tmp/rhizo-env.new > /etc/environment && rm -f /tmp/rhizo-env.new && echo ENVWRITTEN" \
    | grep -q ENVWRITTEN \
    || { log "FAIL: could not write /etc/environment"; exit 1; }

  ok=0; deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    got=$(ssh_vm -t 5 "cat /etc/environment" 2>/dev/null)
    grep -qx "https_proxy=$url" <<<"$got" && { ok=1; break; }
    sleep 1
  done
  [[ "$ok" == 1 ]] || { log "FAIL: /etc/environment carries no 'https_proxy=$url' line within 15s; it reads: $got"; exit 1; }
  log "hostproxy set to $url"
}

# remove proxy lines from /etc/environment
hostproxy_none() {
  local want got ok
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  if ssh_vm -t 8 "[ -f $ENV_BACKUP ]"; then
    ssh_vm -t 8 "cp -f $ENV_BACKUP /etc/environment" \
      || { log "FAIL: could not restore /etc/environment from $ENV_BACKUP"; exit 1; }
  fi
  ssh_vm -t 10 "{ grep -vE '^[[:space:]]*(export[[:space:]]+)?(https?|all|no)_proxy=' /etc/environment || true; } > /tmp/rhizo-env.stripped && cat /tmp/rhizo-env.stripped > /etc/environment && rm -f /tmp/rhizo-env.stripped && echo STRIPPED" \
    | grep -q STRIPPED \
    || { log "FAIL: could not strip proxy lines from /etc/environment"; exit 1; }
  if ssh_vm -t 8 "grep -qE '^[[:space:]]*(export[[:space:]]+)?(https?|all)_proxy=' /etc/environment"; then
    log "FAIL: a proxy line survives in /etc/environment"
    ssh_vm -t 8 "cat /etc/environment" 2>&1 | sed 's/^/    /'
    exit 1
  fi

  ssh_vm -t 8 "rm -f $ENV_BACKUP" || true
  log "hostproxy cleared"
}

# start an HTTP endpoint in the proxy namespace
proxyorigin_up() {
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  log "creating the $PROXY_NS namespace and veth pair ($PROXY_HOST_IP <-> $PROXY_NS_IP)..."
  ssh_vm -t 15 "if ! ip netns list | grep -q '^$PROXY_NS '; then ip netns add $PROXY_NS; fi
if ! ip link show $PROXY_VETH_HOST >/dev/null 2>&1; then
  ip link add $PROXY_VETH_HOST type veth peer name $PROXY_VETH_NS
  ip link set $PROXY_VETH_NS netns $PROXY_NS
fi
ip addr replace $PROXY_HOST_IP/24 dev $PROXY_VETH_HOST
ip link set $PROXY_VETH_HOST up
nsenter --net=/var/run/netns/$PROXY_NS ip addr replace $PROXY_NS_IP/24 dev $PROXY_VETH_NS
nsenter --net=/var/run/netns/$PROXY_NS ip link set $PROXY_VETH_NS up
nsenter --net=/var/run/netns/$PROXY_NS ip link set lo up
echo netns-ready" || { log "FAIL: could not create the $PROXY_NS namespace/veth pair"; exit 1; }

  ssh_vm -t 10 "cat > /root/rhizo-proxyorigin.py <<'PYEOF'
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/proxytest':
            body = b'RHIZO-PROXY-OK'
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, fmt, *a):
        pass
http.server.HTTPServer(('10.88.0.2', 80), H).serve_forever()
PYEOF" || { log "FAIL: could not write the proxy-origin script"; exit 1; }

  log "starting the proxy origin (${PROXY_NS_IP}:80 inside $PROXY_NS)..."
  ssh_vm -t 15 "if [ -f $PROXY_ORIGIN_PID ]; then kill -9 \"\$(cat $PROXY_ORIGIN_PID)\" 2>/dev/null; rm -f $PROXY_ORIGIN_PID; fi
sleep 1
setsid nsenter --net=/var/run/netns/$PROXY_NS sh -c 'echo \$\$ > $PROXY_ORIGIN_PID; exec python3 /root/rhizo-proxyorigin.py' >$PROXY_ORIGIN_LOG 2>&1 < /dev/null & disown
sleep 1; echo launched" >/dev/null 2>&1 || true

  local ok=0 deadline
  deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    if ssh_vm -t 5 "curl -sf http://$PROXY_NS_IP/proxytest | grep -q RHIZO-PROXY-OK"; then
      ok=1; break
    fi
    sleep 1
  done
  if [[ "$ok" != 1 ]]; then
    log "FAIL: proxy origin did not self-verify within 15s -- see $PROXY_ORIGIN_LOG"
    ssh_vm -t 5 "tail -20 $PROXY_ORIGIN_LOG" 2>&1
    exit 1
  fi
  log "proxy origin up and self-verified, reachable only from the guest's root netns"
}

# remove the proxy origin process, namespace and veth pair
proxyorigin_down() {
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  log "tearing down the $PROXY_NS namespace and veth pair..."
  ssh_vm -t 10 "if [ -f $PROXY_ORIGIN_PID ]; then kill -9 \"\$(cat $PROXY_ORIGIN_PID)\" 2>/dev/null; rm -f $PROXY_ORIGIN_PID; fi
ip netns del $PROXY_NS 2>/dev/null
ip link del $PROXY_VETH_HOST 2>/dev/null
echo down" || { log "FAIL: proxy origin teardown did not complete"; exit 1; }
  log "$PROXY_NS namespace and veth pair removed"
}

# start proxy-fixture.py on a port
proxyup() {
  local port="$1" tag="$2" pidfile logfile ok code
  pidfile="/run/rhizo-proxyfix-$port.pid"
  logfile="/tmp/rhizo-proxyfix-$port.log"
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  mount_share
  log "starting proxy-fixture.py (127.0.0.1:$port tag=$tag)..."
  ssh_vm -t 15 "cp -f /root/share/proxy-fixture.py /root/proxy-fixture.py
if [ -f $pidfile ]; then kill -9 \"\$(cat $pidfile)\" 2>/dev/null; rm -f $pidfile; fi
sleep 1
setsid sh -c 'echo \$\$ > $pidfile; exec python3 /root/proxy-fixture.py --bind 127.0.0.1 --port $port --tag $tag' >$logfile 2>&1 < /dev/null & disown
echo $port >> $PROXYFIX_MANIFEST
sleep 1; echo launched" >/dev/null 2>&1 || true

  ok=0; deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    code=$(ssh_vm -t 5 "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/" 2>/dev/null)
    [[ "$code" == "400" ]] && { ok=1; break; }
    sleep 1
  done
  if [[ "$ok" != 1 ]]; then
    log "FAIL: proxy-fixture.py did not self-verify on port $port within 15s -- see $logfile"
    ssh_vm -t 5 "tail -20 $logfile" 2>&1
    exit 1
  fi
  log "proxyfix up on 127.0.0.1:$port tag=$tag"
}

# stop the recorded proxyfix instances
proxydown() {
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  if ! ssh_vm -t 8 "[ -f $PROXYFIX_MANIFEST ]"; then
    log "no proxyfix instances recorded, nothing to stop"
    return 0
  fi
  local ports port
  ports=$(ssh_vm -t 8 "cat $PROXYFIX_MANIFEST" 2>/dev/null)
  for port in $ports; do
    ssh_vm -t 8 "pidfile=/run/rhizo-proxyfix-$port.pid; if [ -f \$pidfile ]; then kill -9 \$(cat \$pidfile) 2>/dev/null; rm -f \$pidfile; fi" \
      || log "  could not stop proxyfix on port $port cleanly"
  done
  ssh_vm -t 8 "rm -f $PROXYFIX_MANIFEST" || true
  log "proxyfix instances stopped: $ports"
}

# write the captive portal address and wait for it to take effect
portal_on() {
  local ip="$1" got ok
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  ssh_vm -t 8 "mkdir -p $PORTAL_DIR" || { log "FAIL: could not create $PORTAL_DIR"; exit 1; }
  ssh_vm -t 8 "tee $PORTAL_FILE >/dev/null" <<<"$ip" || { log "FAIL: could not write $PORTAL_FILE"; exit 1; }

  ok=0; deadline=$(( $(date +%s) + 10 ))
  while (( $(date +%s) < deadline )); do
    got=$(ssh_vm -t 5 "cat $PORTAL_FILE" 2>/dev/null)
    [[ "$got" == "$ip" ]] && { ok=1; break; }
    sleep 1
  done
  [[ "$ok" == 1 ]] || { log "FAIL: $PORTAL_FILE reads '$got', not '$ip', within 10s"; exit 1; }
  log "portal switch on: $PORTAL_FILE -> $ip"
}

# remove the captive portal file
portal_off() {
  local owner uid gid
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  if ! ssh_vm -t 8 "[ -f $PORTAL_FILE ]"; then
    log "portal switch off (already gone)"
    return 0
  fi
  owner=$(ssh_vm -t 8 "stat -c '%u:%g' $PORTAL_FILE")
  [[ -n "$owner" ]] || { log "FAIL: could not stat $PORTAL_FILE's owner"; exit 1; }
  uid="${owner%%:*}"; gid="${owner##*:}"
  ssh_vm -t 8 "setpriv --reuid=$uid --regid=$gid --clear-groups rm -f $PORTAL_FILE" \
    || { log "FAIL: could not remove $PORTAL_FILE as uid=$uid gid=$gid"; exit 1; }
  if ssh_vm -t 8 "[ -f $PORTAL_FILE ]"; then
    log "FAIL: $PORTAL_FILE still exists after removal"
    exit 1
  fi
  log "portal switch off"
}

# print the state of the network fixtures
status() {
  wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }
  echo "upstreams:"
  if ssh_vm -t 5 "[ -f $UPSTREAM_A_PID ] && kill -0 \$(cat $UPSTREAM_A_PID) 2>/dev/null"; then
    echo "  $UPSTREAM_A_IP: up"
  else
    echo "  $UPSTREAM_A_IP: down"
  fi
  if ssh_vm -t 5 "[ -f $UPSTREAM_B_PID ] && kill -0 \$(cat $UPSTREAM_B_PID) 2>/dev/null"; then
    echo "  $UPSTREAM_B_IP: up"
  else
    echo "  $UPSTREAM_B_IP: down"
  fi

  echo "resolver:"
  ssh_vm -t 5 "readlink -f /etc/resolv.conf" 2>/dev/null | sed 's/^/  target=/'
  ssh_vm -t 5 "cat \$(readlink -f /etc/resolv.conf)" 2>/dev/null | sed 's/^/  /'
  ssh_vm -t 5 "[ -f $RESOLV_BACKUP ]" && echo "  (backup present -- resolver has been redirected)"

  echo "hostproxy:"
  ssh_vm -t 5 "grep -i '^https_proxy=' /etc/environment" 2>/dev/null | sed 's/^/  /'
  ssh_vm -t 5 "[ -f $ENV_BACKUP ]" && echo "  (backup present -- hostproxy has been redirected)"

  echo "proxyorigin:"
  if ssh_vm -t 5 "ip netns list | grep -q '^$PROXY_NS '"; then
    echo "  $PROXY_NS netns up"
  else
    echo "  down"
  fi

  echo "proxyfix:"
  if ssh_vm -t 5 "[ -f $PROXYFIX_MANIFEST ]"; then
    ssh_vm -t 5 "cat $PROXYFIX_MANIFEST" 2>/dev/null | sed 's/^/  port /'
  else
    echo "  none running"
  fi

  echo "portal:"
  if ssh_vm -t 5 "[ -f $PORTAL_FILE ]"; then
    ssh_vm -t 5 "cat $PORTAL_FILE" 2>/dev/null | sed 's/^/  /'
  else
    echo "  off"
  fi
}

case "${1:-}" in
  upstreams)
    case "${2:-}" in
      up) [[ -n "${3:-}" ]] || usage; upstreams_up "$3" ;;
      down) upstreams_down ;;
      *) usage ;;
    esac ;;
  resolver)
    case "${2:-}" in
      "") usage ;;
      restore) resolver_restore ;;
      *) resolver_up "$2" ;;
    esac ;;
  hostproxy)
    case "${2:-}" in
      "") usage ;;
      none) hostproxy_none ;;
      *) hostproxy_up "$2" ;;
    esac ;;
  proxyorigin)
    case "${2:-}" in
      up) proxyorigin_up ;;
      down) proxyorigin_down ;;
      *) usage ;;
    esac ;;
  proxyup)
    [[ -n "${2:-}" && -n "${3:-}" ]] || usage
    proxyup "$2" "$3" ;;
  proxydown)
    proxydown ;;
  portalserv)
    case "${2:-}" in
      up)   portalserv_up "${3:?portalserv up needs an ip}" ;;
      down) portalserv_down ;;
      *)    usage ;;
    esac
    ;;
  v6origin)
    case "${2:-}" in
      up)   v6origin_up ;;
      down) v6origin_down ;;
      *)    usage ;;
    esac
    ;;
  portal)
    case "${2:-}" in
      on) [[ -n "${3:-}" ]] || usage; portal_on "$3" ;;
      off) portal_off ;;
      *) usage ;;
    esac ;;
  status)
    status ;;
  *)
    usage ;;
esac
