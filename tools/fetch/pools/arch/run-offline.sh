#!/bin/bash
# run offline.cmd on the guest with its network down
exec > /root/share/offline.out 2>&1
share=/root/share
: > "$share/offline.started"
# print a message and write offline.rc
stop() {
  echo "$2"
  echo "$1" > "$share/offline.rc"
  exit 1
}
t0=$SECONDS
until [[ -e "$share/offline.go" ]]; do
  (( SECONDS - t0 < 60 )) || stop 96 "the host wrote no offline.go in 60s"
  sleep 1
done
command -v curl >/dev/null || stop 95 "curl is not installed on the guest"
nic=$(ip -o -4 route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p;q')
[[ -n "$nic" ]] || stop 97 "the guest has no default route"
echo "$nic" > "$share/offline.nic"
ip link set "$nic" down || stop 93 "ip link set $nic down exited $?"
state=$(ip -br link show "$nic" | awk '{ print $2 }')
[[ "$state" == DOWN ]] || stop 93 "$nic is $state after ip link set down"
echo "$nic is $state"
curl_rc=0
curl --silent --max-time 10 --output /dev/null https://cachyos.org || curl_rc=$?
case "$curl_rc" in
  0) stop 98 "https://cachyos.org answers with $nic down" ;;
  6|7|28) echo "curl to https://cachyos.org exits $curl_rc with $nic down" ;;
  *) stop 94 "curl to https://cachyos.org exits $curl_rc with $nic down, which is not a network failure" ;;
esac
rc=0
bash "$share/offline.cmd" || rc=$?
ip link set "$nic" up
echo "$rc" > "$share/offline.rc"
