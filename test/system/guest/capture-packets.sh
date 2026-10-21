#!/bin/bash
# capture packets on vethrhz0 and eth0
set -uo pipefail

DIR=/tmp/rhizo-netcap
SNIFFER=/root/sniff-packets.py
HOST_IF=vethrhz0
SBX_IF=eth0
READY_TIMEOUT=15

# print the usage line and exit
usage() { echo "usage: capture-packets.sh {start <tag> [filter]|stop <tag>|status <tag>|clean <tag>}" >&2; exit 2; }

CMD="${1:-}"; TAG="${2:-}"
[[ -n "$CMD" && -n "$TAG" ]] || usage
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "netcap: tag must be [A-Za-z0-9._-]+" >&2; exit 2; }
FILTER="${3:-}"

mkdir -p "$DIR"
h_pcap="$DIR/$TAG.host.pcap"; h_err="$DIR/$TAG.host.err"; h_pid="$DIR/$TAG.host.pid"
s_pcap="$DIR/$TAG.sbx.pcap";  s_err="$DIR/$TAG.sbx.err";  s_pid="$DIR/$TAG.sbx.pid"

# print the lowest init second_stage pid
stack_init_pid() {
  _sip_pid=""
  for _sip_d in "${RHIZO_PROC_ROOT:-/proc}"/[0-9]*; do
    case "$(tr '\0' ' ' 2>/dev/null < "$_sip_d/cmdline")" in *"init second_stage"*) ;; *) continue ;; esac
    case "$(sed -n 's|^0::||p' "$_sip_d/cgroup" 2>/dev/null)" in
      /rhizo/*|/system.slice/androidd.service/android/*)
        [ -z "$_sip_pid" ] || [ "${_sip_d##*/}" -lt "$_sip_pid" ] && _sip_pid=${_sip_d##*/} ;;
    esac
  done
  [ -z "$_sip_pid" ] || echo "$_sip_pid"
}
# print the pid of the sandbox init process
sandbox_init() {
  local p
  p=$(stack_init_pid)
  [[ -n "$p" ]] || return 1
  echo "$p"
}

# print the packet count in the SNIFF_STOPPED line
captured_count() {
  local err="$1" n
  n=$(sed -n 's/^SNIFF_STOPPED .*packets=\([0-9]*\).*/\1/p' "$err" 2>/dev/null | tail -1)
  [[ -n "$n" ]] && echo "$n" || echo -1
}

# print the drop count in the SNIFF_STOPPED line
dropped_count() {
  local err="$1" n
  n=$(sed -n 's/^SNIFF_STOPPED .*drops=\(-\?[0-9]*\).*/\1/p' "$err" 2>/dev/null | tail -1)
  [[ -n "$n" ]] && echo "$n" || echo -1
}

# wait for SNIFF_LISTENING in the error file
wait_ready() {
  local err="$1" pidfile="$2" label="$3" pid deadline=$((SECONDS + READY_TIMEOUT))
  pid=$(<"$pidfile")
  while (( SECONDS < deadline )); do
    grep -q "^SNIFF_LISTENING " "$err" 2>/dev/null && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "netcap: $label sniffer exited before it began listening:" >&2
      sed 's/^/  /' "$err" >&2
      return 1
    fi
    sleep 0.2
  done
  echo "netcap: $label sniffer never reported SNIFF_LISTENING within ${READY_TIMEOUT}s" >&2
  sed 's/^/  /' "$err" >&2
  return 1
}

# terminate the process in the pid file
stop_one() {
  local pidfile="$1" err="$2" pid
  [[ -f "$pidfile" ]] || return 0
  pid=$(<"$pidfile")
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null
    local deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )) && kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$pidfile"
}

case "$CMD" in
start)
  stop_one "$h_pid" "$h_err"; stop_one "$s_pid" "$s_err"
  rm -f "$h_pcap" "$s_pcap" "$h_err" "$s_err"

  init=$(sandbox_init) || { echo "netcap: no sandbox init second_stage" >&2; exit 1; }
  [[ -r "$SNIFFER" ]] || { echo "netcap: $SNIFFER is not present -- net-capture.sh stages it" >&2; exit 1; }

  setsid python3 "$SNIFFER" --iface "$HOST_IF" --out "$h_pcap" \
    </dev/null >/dev/null 2>"$h_err" &
  echo $! > "$h_pid"

  setsid nsenter -t "$init" -n -- python3 "$SNIFFER" --iface "$SBX_IF" --out "$s_pcap" \
    </dev/null >/dev/null 2>"$s_err" &
  echo $! > "$s_pid"

  ok=0
  wait_ready "$h_err" "$h_pid" "host($HOST_IF)" || ok=1
  wait_ready "$s_err" "$s_pid" "sandbox($SBX_IF via pid $init)" || ok=1
  if (( ok )); then
    stop_one "$h_pid" "$h_err"; stop_one "$s_pid" "$s_err"
    echo "NETCAP_START_FAILED tag=$TAG"
    exit 1
  fi
  echo "NETCAP_STARTED tag=$TAG init=$init host_if=$HOST_IF sbx_if=$SBX_IF filter=${FILTER:-none}"
  ;;

stop)
  stop_one "$h_pid" "$h_err"; stop_one "$s_pid" "$s_err"
  echo "NETCAP_STOPPED tag=$TAG host_packets=$(captured_count "$h_err") sbx_packets=$(captured_count "$s_err") host_drops=$(dropped_count "$h_err") sbx_drops=$(dropped_count "$s_err") host_pcap=$h_pcap sbx_pcap=$s_pcap"
  ;;

status)
  h=stopped; s=stopped
  [[ -f "$h_pid" ]] && kill -0 "$(<"$h_pid")" 2>/dev/null && h=running
  [[ -f "$s_pid" ]] && kill -0 "$(<"$s_pid")" 2>/dev/null && s=running
  echo "NETCAP_STATUS tag=$TAG host=$h sbx=$s host_bytes=$(stat -c%s "$h_pcap" 2>/dev/null || echo 0) sbx_bytes=$(stat -c%s "$s_pcap" 2>/dev/null || echo 0)"
  ;;

clean)
  stop_one "$h_pid" "$h_err"; stop_one "$s_pid" "$s_err"
  rm -f "$h_pcap" "$s_pcap" "$h_err" "$s_err"
  echo "NETCAP_CLEANED tag=$TAG"
  ;;

*) usage ;;
esac
