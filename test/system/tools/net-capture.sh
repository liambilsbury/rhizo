#!/bin/bash
# capture packets on both sides of the veth
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh

CMD="${1:-}"; TAG="${2:-}"
[[ -n "$CMD" && -n "$TAG" ]] || { echo "usage: net-capture.sh {start <tag> [filter]|stop <tag>|pull <tag> <dir>|status <tag>|clean <tag>}" >&2; exit 2; }

GUEST=/root/capture-packets.sh
SNIFFER=/root/sniff-packets.py

# copy a file from the guest with scp
fetch() {
  timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_TARGET:$1" "$2"
}

case "$CMD" in
start)
  FILTER="${3:-}"
  ssh_vm -t 20 "cp -f /root/share/capture-packets.sh $GUEST && cp -f /root/share/sniff-packets.py $SNIFFER && chmod +x $GUEST $SNIFFER" >/dev/null \
    || { echo "net-capture: could not stage the capture scripts in the guest" >&2; exit 1; }
  out=$(ssh_vm -t 60 "$GUEST start $TAG $FILTER" 2>&1)
  echo "$out"
  grep -q "^NETCAP_STARTED " <<<"$out"
  ;;
stop)
  out=$(ssh_vm -t 60 "$GUEST stop $TAG" 2>&1)
  echo "$out"
  grep -q "^NETCAP_STOPPED " <<<"$out"
  ;;
status)
  out=$(ssh_vm -t 30 "$GUEST status $TAG" 2>&1)
  echo "$out"
  grep -q "^NETCAP_STATUS " <<<"$out"
  ;;
clean)
  out=$(ssh_vm -t 30 "$GUEST clean $TAG" 2>&1)
  echo "$out"
  grep -q "^NETCAP_CLEANED " <<<"$out"
  ;;
pull)
  DEST="${3:-}"
  [[ -n "$DEST" ]] || { echo "net-capture: pull needs a destination directory" >&2; exit 2; }
  mkdir -p "$DEST"
  rc=0
  for side in host sbx; do
    rm -f "$DEST/$TAG.$side.pcap"
    if ! fetch "/tmp/rhizo-netcap/$TAG.$side.pcap" "$DEST/$TAG.$side.pcap"; then
      echo "net-capture: could not pull the $side pcap for tag $TAG" >&2
      rc=1
    fi
  done
  (( rc == 0 )) && echo "NETCAP_PULLED tag=$TAG dir=$DEST host=$(stat -c%s "$DEST/$TAG.host.pcap" 2>/dev/null || echo 0)B sbx=$(stat -c%s "$DEST/$TAG.sbx.pcap" 2>/dev/null || echo 0)B"
  exit $rc
  ;;
*) echo "net-capture: unknown subcommand $CMD" >&2; exit 2 ;;
esac
