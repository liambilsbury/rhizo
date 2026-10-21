#!/bin/bash
# test the rhizo-wlbridge selection release on exit
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
BRIDGE=""
if [[ "${1:-}" == --bridge ]]; then
  BRIDGE="${2:?--bridge wants a path}"
fi

command -v sway >/dev/null \
  || { echo "check-wlbridge-exit-release: sway is not installed here (apt-get install sway)"; exit 1; }

WORK=$(mktemp -d /tmp/rwlx-XXXXXX)
chmod 700 "$WORK"
SWAY_PID="" HOLD_PIDS=() BRIDGE_PIDS=()
# resume sway, kill the test processes and remove the work dir
cleanup() {
  [[ -n "$SWAY_PID" ]] && kill -CONT "$SWAY_PID" 2>/dev/null
  local p
  for p in "${BRIDGE_PIDS[@]}" "${HOLD_PIDS[@]}" $SWAY_PID; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ -z "$BRIDGE" ]]; then
  BRIDGE="$WORK/rhizo-wlbridge"
  if ! ./tools/build/services/wlbridge.sh "$BRIDGE" > "$WORK/build.log" 2>&1; then
    echo "check-wlbridge-exit-release: wlbridge.sh failed:"
    cat "$WORK/build.log"
    exit 1
  fi
fi

fail() { echo "check-wlbridge-exit-release: $*"; exit 1; }

# wait for the command to succeed
wait_for() {
  local deadline=$(( $(date +%s) + $1 )); shift
  until "$@"; do
    (( $(date +%s) < deadline )) || return 1
    sleep 0.05
  done
}

export XDG_RUNTIME_DIR="$WORK"
: > "$WORK/sway.conf"
WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
  sway -c "$WORK/sway.conf" > "$WORK/sway.log" 2>&1 &
SWAY_PID=$!
# return success when a wayland socket lock exists
sock_up() { compgen -G "$WORK/wayland-*.lock" >/dev/null; }
wait_for 20 sock_up || fail "headless sway never made its socket: $(tail -5 "$WORK/sway.log")"
sock=$(compgen -G "$WORK/wayland-*.lock" | head -1)
export WAYLAND_DISPLAY; WAYLAND_DISPLAY=$(basename "${sock%.lock}")

# start rhizo-wlbridge on a FIFO
start_bridge() {
  mkfifo "$WORK/$1.in"
  sleep 3600 > "$WORK/$1.in" &
  HOLD_PIDS+=($!)
  WAYLAND_DEBUG=client "$BRIDGE" --caps clipboard < "$WORK/$1.in" > "$WORK/$1.out" 2> "$WORK/$1.err" &
  BRIDGE_PID=$!
  BRIDGE_PIDS+=("$BRIDGE_PID")
  wait_for 20 grep -q '^ready$' "$WORK/$1.out" \
    || fail "the $1 bridge never said ready: $(tr '\n' '|' < "$WORK/$1.err")"
}

start_bridge observer
start_bridge subject
subject=$BRIDGE_PID
echo "set text/plain $(printf 'rhizo-exit-release' | base64 -w0)" > "$WORK/subject.in"
# return success when the observer output shows the held selection
held() { grep -q '^selection text/plain$' "$WORK/observer.out"; }
wait_for 20 held || fail "the observer never saw the subject's selection: $(tr '\n' '|' < "$WORK/observer.out")"
before=$(wc -l < "$WORK/subject.out")

kill -STOP "$SWAY_PID"
kill -TERM "$subject"
# check the subject process exited
gone() { ! kill -0 "$subject" 2>/dev/null; }
# return success when the subject log shows a release
releasing() { grep -q 'releasing' "$WORK/subject.err"; }
wait_for 20 eval 'gone || releasing' || fail "the bridge neither exited nor released its selection within 20s of SIGTERM"
if gone; then
  fail "the bridge exited, closing its output, while the compositor was stopped: nothing had taken its selection back"
fi
# check the subject waits in poll or ppoll
waiting() { read -r nr _ < "/proc/$subject/syscall" 2>/dev/null && [[ "$nr" == 7 || "$nr" == 271 ]]; }
wait_for 20 eval 'gone || waiting' || fail "the bridge named its release but never waited on the compositor (syscall: $(cat "/proc/$subject/syscall" 2>&1))"
gone && fail "the bridge exited while the compositor was stopped, after naming its release: it did not wait for the compositor to take the selection back"
grep -qE -- '-> zwlr_data_control_source_v1@[0-9]+\.destroy\(\)' "$WORK/subject.err" \
  || fail "the bridge waits on the compositor with its source not yet destroyed: its wait is not for the release"

kill -CONT "$SWAY_PID"
wait_for 20 gone || fail "the bridge did not exit once the compositor ran again"
# return success when the observer output shows the selection released
released() { tail -n +3 "$WORK/observer.out" | grep -q '^selection none$'; }
wait_for 20 released || fail "the observer never saw the host selection go after the bridge's release: $(tr '\n' '|' < "$WORK/observer.out")"
after=$(tail -n +"$(( before + 1 ))" "$WORK/subject.out")
if grep -q '^selection' <<<"$after"; then
  fail "the bridge reported its own release as a host selection change ($(tr '\n' '|' <<<"$after")): rhizo-deskd would record the host as holding nothing of Android's and hand nothing to the composer"
fi

echo "check-wlbridge-exit-release: a SIGTERMed bridge gave its selection back and waited for the compositor before its output closed, without reporting its own release"
