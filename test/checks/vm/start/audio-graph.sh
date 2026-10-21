#!/bin/bash
# test the audio graph script against PipeWire
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
MODE=run
[[ "${1:-}" == --selftest ]] && MODE=selftest

for tool in pipewire wireplumber pw-cli pw-dump dbus-daemon python3 setsid; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool is not installed here" >&2; exit 1; }
done
SPA_DIR=""
for d in /usr/lib/*/spa-0.2; do [[ -d "$d" ]] && { SPA_DIR="$d"; break; }; done
[[ -d "$SPA_DIR/audioconvert" ]] || { echo "FAIL: no audioconvert plugin under ${SPA_DIR:-/usr/lib/*/spa-0.2}" >&2; exit 1; }

START_AUDIO=test/vm/start/start-audio.sh
SCRIPT=$(sed -n "/^AUDIO_GRAPH_SH=\$(cat <<'AUDIO_GRAPH_EOF'\$/,/^AUDIO_GRAPH_EOF\$/p" "$START_AUDIO" | sed '1d;$d')
[[ "$SCRIPT" == *AUDIO_GRAPH_OK* ]] || { echo "FAIL: no AUDIO_GRAPH_SH heredoc in $START_AUDIO" >&2; exit 1; }

WORK=$(mktemp -d /tmp/agraph.XXXXXX)
BUS_INFO=$(XDG_RUNTIME_DIR="$WORK" dbus-daemon --session --fork --print-address=1 --print-pid=1)
DBUS_SESSION_BUS_ADDRESS=$(sed -n 1p <<<"$BUS_INFO")
export DBUS_SESSION_BUS_ADDRESS
BUS_PID=$(sed -n 2p <<<"$BUS_INFO")
# kill the case processes and remove the work directory
cleanup() {
  local f
  for f in "$WORK"/case*/state/proc.*; do
    [[ -e "$f" ]] && kill "${f##*.}" 2>/dev/null
  done
  kill "$BUS_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
unset SPA_PLUGIN_DIR PIPEWIRE_REMOTE PIPEWIRE_RUNTIME_DIR

mkdir -p "$WORK/spa-noconvert" "$WORK/bin"
for d in "$SPA_DIR"/*; do
  [[ "$(basename "$d")" == audioconvert ]] || ln -s "$d" "$WORK/spa-noconvert/"
done

cat >"$WORK/bin/shimlib" <<'EOF'
alive() { kill -0 "$1" 2>/dev/null; }
unit_pid() { local p; p=$(cat "$AG_STATE/unit.$1" 2>/dev/null) && alive "$p" && echo "$p"; }
kill_wait() {
  local p
  for p in "$@"; do kill "$p" 2>/dev/null; done
  for _ in $(seq 1 40); do
    for p in "$@"; do alive "$p" && break; p=""; done
    [[ -z "$p" ]] && return 0
    sleep 0.1
  done
  return 1
}
EOF
cat >"$WORK/bin/runuser" <<'EOF'
#!/bin/bash
while [[ $# -gt 0 && "$1" != -- ]]; do shift; done
shift
if [[ "${1:-}" == env ]]; then
  args=()
  for a in "$@"; do
    [[ "$a" == XDG_RUNTIME_DIR=* ]] && a="XDG_RUNTIME_DIR=$AG_XDG"
    args+=("$a")
  done
  exec "${args[@]}"
fi
exec "$@"
EOF
cat >"$WORK/bin/cat" <<'EOF'
#!/bin/bash
if [[ $# == 1 && "$1" =~ ^/proc/([0-9]+)/attr/current$ ]]; then
  f="$AG_STATE/domain.${BASH_REMATCH[1]}"
  [[ -f "$f" ]] || exit 1
  printf '%s\0' "$(/bin/cat "$f")"
  exit 0
fi
exec /bin/cat "$@"
EOF
cat >"$WORK/bin/systemctl" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/shimlib"
echo "systemctl $*" >>"$AG_STATE/calls"
user=0
[[ "${1:-}" == --user ]] && { user=1; shift; }
verb="$1"; shift
if (( user )); then
  case "$verb" in
    list-units)
      for u in "$@"; do
        case "$u" in
          pipewire.socket|pipewire.service) p=session-pipewire ;;
          wireplumber.service) p=session-wireplumber ;;
          *) continue ;;
        esac
        [[ -n "$(unit_pid "$p")" ]] && echo "$u loaded active running"
      done
      exit 0 ;;
    stop)
      pids=()
      for u in "$@"; do
        case "$u" in
          pipewire.socket|pipewire.service) p=$(unit_pid session-pipewire) ;;
          wireplumber.service) p=$(unit_pid session-wireplumber) ;;
          *) echo "Unit $u not loaded." >&2; exit 5 ;;
        esac
        [[ -n "$p" ]] && pids+=("$p")
      done
      kill_wait "${pids[@]}"; exit $? ;;
    daemon-reload) touch "$AG_STATE/reloaded"; exit 0 ;;
    start)
      for u in "$@"; do
        case "$u" in
          pipewire.socket|pipewire.service) p=session-pipewire ;;
          wireplumber.service) p=session-wireplumber ;;
          *) echo "Unit $u not found." >&2; exit 5 ;;
        esac
        [[ -n "$(unit_pid "$p")" ]] && continue
        [[ -f "$AG_STATE/reloaded" ]] || { echo "Unit $u not found." >&2; exit 5; }
        XDG_RUNTIME_DIR="$AG_XDG" SPA_PLUGIN_DIR="$(cat "$AG_STATE/spa")" setsid "${p#session-}" >"$AG_STATE/$p.log" 2>&1 </dev/null &
        pid=$!
        echo "$pid" >"$AG_STATE/unit.$p"; echo "${p#session-}" >"$AG_STATE/proc.$pid"
        cat "$AG_STATE/domain.$(cat "$AG_STATE/manager")" >"$AG_STATE/domain.$pid"
        if [[ "$p" == session-pipewire ]]; then
          for _ in $(seq 1 40); do
            XDG_RUNTIME_DIR="$AG_XDG" pw-cli info 0 >/dev/null 2>&1 && break
            sleep 0.1
          done
        fi
      done
      exit 0 ;;
  esac
  echo "unmodeled systemctl --user $verb" >&2; exit 1
fi
case "$verb" in
  show)
    [[ "$1 $2 $3" == "-p MainPID --value" || "$1 $2 $3" == "-p ActiveState --value" ]] || { echo "unmodeled show $*" >&2; exit 1; }
    prop="$2"; unit="$4"
    if [[ "$unit" == user@*.service ]]; then
      [[ "$prop" == MainPID ]] && cat "$AG_STATE/manager"
      [[ "$prop" == ActiveState ]] && echo active
      exit 0
    fi
    p=$(unit_pid "$unit")
    if [[ "$prop" == MainPID ]]; then echo "${p:-0}"
    elif [[ -n "$p" ]]; then echo active
    else echo inactive
    fi
    exit 0 ;;
  is-active)
    [[ "$1" == --quiet ]] && shift
    [[ -n "$(unit_pid "$1")" ]]; exit $? ;;
  stop)
    pids=()
    for u in "$@"; do p=$(unit_pid "$u"); [[ -n "$p" ]] && pids+=("$p"); done
    kill_wait "${pids[@]}"; exit $? ;;
  reset-failed) exit 0 ;;
esac
echo "unmodeled systemctl $verb" >&2
exit 1
EOF
cat >"$WORK/bin/systemd-run" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/shimlib"
echo "systemd-run $*" >>"$AG_STATE/calls"
unit=""
while [[ $# -gt 0 && "$1" == -* ]]; do
  case "$1" in --unit=*) unit="${1#--unit=}" ;; esac
  shift
done
[[ -n "$unit" && $# -gt 0 ]] || { echo "systemd-run: no unit or command" >&2; exit 1; }
[[ -z "$(unit_pid "$unit")" ]] || { echo "Unit $unit already exists." >&2; exit 1; }
XDG_RUNTIME_DIR="$AG_XDG" setsid "$@" >"$AG_STATE/$unit.log" 2>&1 </dev/null &
p=$!
echo "$p" >"$AG_STATE/unit.$unit"
echo "$(basename "$1")" >"$AG_STATE/proc.$p"
echo u:r:rhizo_host:s0 >"$AG_STATE/domain.$p"
EOF
cat >"$WORK/bin/pgrep" <<'EOF'
#!/bin/bash
. "$(dirname "$0")/shimlib"
pattern="${!#}"
for f in "$AG_STATE"/proc.*; do
  [[ -e "$f" ]] || continue
  p="${f##*.}"
  alive "$p" && [[ "$(cat "$f")" =~ ^($pattern)$ ]] && echo "$p"
done
exit 0
EOF
cat >"$WORK/bin/journalctl" <<'EOF'
#!/bin/bash
cat "$AG_STATE"/session-pipewire.log 2>/dev/null
exit 0
EOF
chmod +x "$WORK/bin/runuser" "$WORK/bin/cat" "$WORK/bin/systemctl" "$WORK/bin/systemd-run" \
  "$WORK/bin/pgrep" "$WORK/bin/journalctl"

# create the directories for a case
new_case() {
  CASE="$WORK/case-$1"
  mkdir -p "$CASE/xdg" "$CASE/state"
  chmod 700 "$CASE/xdg"
}

# record a case's user manager domain and the plugins its PipeWire loads
prepare_session() {
  echo 4242 >"$CASE/state/manager"
  echo "$1" >"$CASE/state/domain.4242"
  echo "$2" >"$CASE/state/spa"
}

# start PipeWire and WirePlumber under a manager
start_session() {
  prepare_session "$2" "$3"
  touch "$CASE/state/reloaded"
  PATH="$WORK/bin:$PATH" AG_STATE="$CASE/state" AG_XDG="$CASE/xdg" \
    systemctl --user start pipewire.service wireplumber.service
  echo "$1" >"$CASE/state/domain.4242"
  rm -f "$CASE/state/calls"
}

# kill the processes listed in the case state
end_case() {
  local f
  for f in "$CASE"/state/proc.*; do
    [[ -e "$f" ]] && kill "${f##*.}" 2>/dev/null
  done
}

# run the graph script with shimmed commands
run_script() {
  PATH="$WORK/bin:$PATH" AG_STATE="$CASE/state" AG_XDG="$CASE/xdg" \
    timeout 90 bash -c "$1" audio-graph "$(id -un)" 4 >"$CASE/out" 2>&1
  RC=$?
}

# print the rhizo_sink_ node names
sink_nodes() {
  XDG_RUNTIME_DIR="$CASE/xdg" pw-dump 2>/dev/null | python3 -c '
import json, sys
for obj in json.loads(sys.stdin.read() or "[]"):
    props = (obj.get("info") or {}).get("props") or {}
    if props.get("media.class") == "Audio/Sink" and str(props.get("node.name", "")).startswith("rhizo_sink_"):
        print(props["node.name"])' | LC_ALL=C sort
}

WANT_SINKS=$'rhizo_sink_bus0\nrhizo_sink_bus1\nrhizo_sink_bus2\nrhizo_sink_bus3\nrhizo_sink_primary'
uid=$(id -u)

# test the script on a leftover PipeWire session
case_leftover_manager() {
  local bad=0 calls
  new_case "leftover-$2"
  start_session u:r:kernel:s0 u:r:kernel:s0 "$WORK/spa-noconvert"
  run_script "$1"
  if (( RC != 0 )) || ! grep -q '^AUDIO_GRAPH_OK' "$CASE/out"; then
    echo "  leftover manager: the script exited $RC without AUDIO_GRAPH_OK"; bad=1
  fi
  grep -q "replaced the session's PipeWire" "$CASE/out" \
    || { echo "  leftover manager: the session's kernel-domain PipeWire was not replaced"; bad=1; }
  [[ "$(sink_nodes)" == "$WANT_SINKS" ]] \
    || { echo "  leftover manager: sinks in the graph: $(sink_nodes | tr '\n' ' ')"; bad=1; }
  calls=$(grep '^systemd-run' "$CASE/state/calls" 2>/dev/null)
  for want in "--setenv=XDG_RUNTIME_DIR=/run/user/$uid" "--setenv=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus"; do
    [[ "$(grep -cF -- "$want" <<<"$calls")" == 2 ]] \
      || { echo "  leftover manager: both systemd-run units need $want"; bad=1; }
  done
  grep -q '^systemctl restart user@' "$CASE/state/calls" 2>/dev/null \
    && { echo "  leftover manager: the script restarted user@"; bad=1; }
  run_script "$1"
  if (( RC != 0 )) || ! grep -q '^AUDIO_GRAPH reusing' "$CASE/out"; then
    echo "  leftover manager rerun: exited $RC without reusing the running units"; bad=1
  fi
  [[ "$(sink_nodes)" == "$WANT_SINKS" ]] \
    || { echo "  leftover manager rerun: sinks in the graph: $(sink_nodes | tr '\n' ' ')"; bad=1; }
  (( bad )) && sed 's/^/    | /' "$CASE/out"
  end_case
  return "$bad"
}

# test the script with PipeWire missing audioconvert
case_sink_absent() {
  local bad=0 n
  new_case "absent-$2"
  start_session u:r:rhizo_host:s0 u:r:rhizo_host:s0 "$WORK/spa-noconvert"
  run_script "$1"
  (( RC != 0 )) || { echo "  sink absent: the script exited 0 with no sink in the graph"; bad=1; }
  grep -q '^AUDIO_GRAPH_OK' "$CASE/out" && { echo "  sink absent: the script printed AUDIO_GRAPH_OK"; bad=1; }
  for n in $WANT_SINKS; do
    grep -q "^AUDIO_GRAPH_FAIL null sinks absent.* $n\b" "$CASE/out" \
      || { echo "  sink absent: the failure does not name $n"; bad=1; }
  done
  grep -q '^systemd-run' "$CASE/state/calls" 2>/dev/null \
    && { echo "  sink absent: the script replaced a PipeWire that was not in kernel"; bad=1; }
  (( bad )) && sed 's/^/    | /' "$CASE/out"
  end_case
  return "$bad"
}

# test the script on a session with unloaded units
case_units_unloaded() {
  local bad=0
  new_case "unloaded-$2"
  prepare_session u:r:rhizo_host:s0 "$SPA_DIR"
  run_script "$1"
  if (( RC != 0 )) || ! grep -q '^AUDIO_GRAPH_OK' "$CASE/out"; then
    echo "  units unloaded: the script exited $RC without AUDIO_GRAPH_OK"; bad=1
  fi
  grep -q '^systemctl --user daemon-reload' "$CASE/state/calls" 2>/dev/null \
    || { echo "  units unloaded: the script never reloaded the user manager"; bad=1; }
  [[ "$(sink_nodes)" == "$WANT_SINKS" ]] \
    || { echo "  units unloaded: sinks in the graph: $(sink_nodes | tr '\n' ' ')"; bad=1; }
  grep -q '^systemd-run' "$CASE/state/calls" 2>/dev/null \
    && { echo "  units unloaded: the script replaced a PipeWire that was not in kernel"; bad=1; }
  (( bad )) && sed 's/^/    | /' "$CASE/out"
  end_case
  return "$bad"
}

# test the script on a session whose PipeWire runs in kernel
case_units_kernel() {
  local bad=0 pw
  new_case "kernel-units-$2"
  start_session u:r:rhizo_host:s0 u:r:kernel:s0 "$SPA_DIR"
  run_script "$1"
  if (( RC != 0 )) || ! grep -q '^AUDIO_GRAPH_OK' "$CASE/out"; then
    echo "  units in kernel: the script exited $RC without AUDIO_GRAPH_OK"; bad=1
  fi
  grep -q "^AUDIO_GRAPH stopped .* own PipeWire left in kernel" "$CASE/out" \
    || { echo "  units in kernel: the session's kernel-domain PipeWire was not stopped"; bad=1; }
  pw=$(cat "$CASE/state/unit.session-pipewire" 2>/dev/null)
  [[ "$(cat "$CASE/state/domain.$pw" 2>/dev/null)" == u:r:rhizo_host:s0 ]] \
    || { echo "  units in kernel: the session's PipeWire (pid ${pw:-none}) is not in rhizo_host"; bad=1; }
  [[ "$(sink_nodes)" == "$WANT_SINKS" ]] \
    || { echo "  units in kernel: sinks in the graph: $(sink_nodes | tr '\n' ' ')"; bad=1; }
  grep -q '^systemd-run' "$CASE/state/calls" 2>/dev/null \
    && { echo "  units in kernel: the script replaced the PipeWire of a manager that is not in kernel"; bad=1; }
  (( bad )) && sed 's/^/    | /' "$CASE/out"
  end_case
  return "$bad"
}

# find exit 1 in the AUDIO_GRAPH_OK failure branch
host_tests_on_ok() {
  python3 -c '
import re, sys
text = sys.stdin.read()
m = re.search(r"if ! grep -q .\^AUDIO_GRAPH_OK. <<<\"\$graph_out\"; then\n(.*?)\nfi\n", text, re.S)
sys.exit(0 if m and re.search(r"^\s*exit 1\s*$", m.group(1), re.M) else 1)' <<<"$1"
}

if [[ "$MODE" == run ]]; then
  fails=0
  case_leftover_manager "$SCRIPT" real || fails=1
  case_sink_absent "$SCRIPT" real || fails=1
  case_units_unloaded "$SCRIPT" real || fails=1
  case_units_kernel "$SCRIPT" real || fails=1
  host_tests_on_ok "$(cat "$START_AUDIO")" \
    || { echo "  start-audio.sh does not exit 1 when AUDIO_GRAPH_OK is missing"; fails=1; }
  if (( fails )); then
    echo "FAIL: start-audio.sh's audio graph script (above)" >&2
    exit 1
  fi
  echo "check-audio-graph: a kernel-domain session PipeWire is replaced and every sink read back; a session that predates PipeWire starts its own and one that predates the policy restarts its own; an absent sink fails by name; start-audio.sh stops on it"
  exit 0
fi

# replace the one matching line in the text
plant() {
  python3 -c '
import sys
text, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
if text.count(old) != 1:
    sys.exit("plant site %r found %d times" % (old, text.count(old)))
print(text.replace(old, new), end="")' "$1" "$2" "$3"
}
problems=()
no_swap=$(plant "$SCRIPT" 'if [ "$mgr_domain" = u:r:kernel:s0 ]; then' 'if false; then') \
  || problems+=("the kernel-domain branch moved; the selftest cannot plant it")
no_fail=$(plant "$SCRIPT" 'fail "null sinks absent' 'echo "planted') \
  || problems+=("the absent-sink failure moved; the selftest cannot plant it")
no_start=$(plant "$SCRIPT" '  as_user systemctl --user start pipewire.socket pipewire.service wireplumber.service \' '  true \') \
  || problems+=("the session unit start moved; the selftest cannot plant it")
no_restart=$(plant "$SCRIPT" '  if [ -n "$stuck" ]; then' '  if false; then') \
  || problems+=("the kernel-domain session unit stop moved; the selftest cannot plant it")
no_exit=$(plant "$(cat "$START_AUDIO")" $'  log "FAIL: the audio graph is not ready -- see the AUDIO_GRAPH lines above"\n  exit 1\n' $'  log "FAIL: the audio graph is not ready -- see the AUDIO_GRAPH lines above"\n') \
  || problems+=("start-audio.sh's AUDIO_GRAPH_OK system test moved; the selftest cannot plant it")

if (( ${#problems[@]} == 0 )); then
  case_leftover_manager "$SCRIPT" real >/dev/null || problems+=("the real script fails the leftover-manager case")
  case_leftover_manager "$no_swap" planted >/dev/null && problems+=("a script that never replaces a kernel-domain PipeWire passes")
  case_sink_absent "$SCRIPT" real >/dev/null || problems+=("the real script fails the absent-sink case")
  case_sink_absent "$no_fail" planted >/dev/null && problems+=("a script that logs an absent sink and carries on passes")
  case_units_unloaded "$SCRIPT" real >/dev/null || problems+=("the real script fails the units-unloaded case")
  case_units_unloaded "$no_start" planted >/dev/null && problems+=("a script that never starts a session's own PipeWire passes")
  case_units_kernel "$SCRIPT" real >/dev/null || problems+=("the real script fails the units-in-kernel case")
  case_units_kernel "$no_restart" planted >/dev/null && problems+=("a script that keeps a session's kernel-domain PipeWire passes")
  host_tests_on_ok "$(cat "$START_AUDIO")" || problems+=("the real start-audio.sh fails the AUDIO_GRAPH_OK system test check")
  host_tests_on_ok "$no_exit" && problems+=("a start-audio.sh that carries on without AUDIO_GRAPH_OK passes")
fi
if (( ${#problems[@]} )); then
  for p in "${problems[@]}"; do echo "FAIL: $p" >&2; done
  exit 1
fi
echo "check-audio-graph --selftest: each planted defect fails its case and the real scripts pass"
