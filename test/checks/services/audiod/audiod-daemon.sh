#!/bin/bash
# test rhizo-audiod over its unix socket
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit

EV=test/checks/data/audiod
MODE=run
[[ "${1:-}" == "--selftest" ]] && MODE=selftest

pkg-config --exists libpipewire-0.3 || {
  echo "FAIL: libpipewire-0.3 dev files missing (apt-get install libpipewire-0.3-dev)" >&2
  exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-audiod-daemon-XXXXXX")
PW_PID=""
# kill the daemon and pipewire and remove the work directory
cleanup() {
  [[ -f "$WORK/daemon.pid" ]] && kill -9 "$(cat "$WORK/daemon.pid")" 2>/dev/null
  [[ -n "$PW_PID" ]] && kill -9 "$PW_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

command -v pipewire >/dev/null || {
  echo "FAIL: no pipewire binary to start a scratch core (apt-get install pipewire)" >&2
  exit 1
}
mkdir -p "$WORK/pw"
export PIPEWIRE_RUNTIME_DIR="$WORK/pw"
pipewire >"$WORK/pipewire.log" 2>&1 &
PW_PID=$!
up=0
for _ in $(seq 1 50); do
  [[ -S "$WORK/pw/pipewire-0" ]] && { up=1; break; }
  sleep 0.1
done
if (( ! up )); then
  echo "FAIL: scratch pipewire never created its socket:" >&2
  cat "$WORK/pipewire.log" >&2
  exit 1
fi

tools/build/services/audiod.sh "$WORK" >"$WORK/build.log" 2>&1 \
  || { echo "FAIL: audiod.sh failed:" >&2; cat "$WORK/build.log" >&2; exit 1; }
CLIENT_BIN="$WORK/rhizo-audiod-loadclient"

BIN="$WORK/rhizo-audiod"
EXPECT=fixed
IDLE_TIMEOUT=3
EXTRA_ARGS=(--idle-timeout "$IDLE_TIMEOUT")
if [[ "$MODE" == selftest ]]; then
  # shellcheck disable=SC2046
  gcc -O2 -Wall -Wextra -o "$WORK/rhizo-audiod-prefix" "$EV/pre-fix-reference.c" \
    $(pkg-config --cflags --libs libpipewire-0.3) -lpthread \
    || { echo "FAIL: could not build the pre-fix reference binary" >&2; exit 1; }
  BIN="$WORK/rhizo-audiod-prefix"
  EXPECT=broken
  EXTRA_ARGS=()
fi

SOCK="$WORK/audiod.sock"
MAP="$WORK/map"; : > "$MAP"
LOG="$WORK/daemon.log"

rm -f "$SOCK"; : > "$LOG"
( "$BIN" --socket "$SOCK" --map "$MAP" "${EXTRA_ARGS[@]}" >"$LOG" 2>&1 & echo $! > "$WORK/daemon.pid" )
up=0
for _ in $(seq 1 50); do
  [[ -S "$SOCK" ]] && { up=1; break; }
  sleep 0.1
done
if (( ! up )); then
  echo "FAIL: rhizo-audiod never created its socket:" >&2
  cat "$LOG" >&2
  exit 1
fi

python3 "$EV/daemon_tests.py" "$SOCK" "$LOG" "$CLIENT_BIN" "$EXPECT" "$IDLE_TIMEOUT" >"$WORK/tests.log" 2>&1
rc=$?
cat "$WORK/tests.log"
cases=$(grep -c '^PASS \|^FAIL ' "$WORK/tests.log")
if (( cases == 0 )); then
  echo "FAIL: daemon_tests.py asserted nothing" >&2
  exit 1
fi

kill -9 "$(cat "$WORK/daemon.pid")" 2>/dev/null

if [[ "$MODE" == selftest ]]; then
  if (( rc != 0 )); then
    echo "check-audiod-daemon --selftest: at least one assertion did NOT reproduce its pre-fix defect" >&2
    exit 1
  fi
  echo "check-audiod-daemon --selftest: $cases assertion(s) correctly reproduced the pre-fix defects"
  exit 0
fi

if (( rc != 0 )); then
  echo "FAIL: check-audiod-daemon: $cases assertion(s) run, at least one failed" >&2
  exit 1
fi
echo "check-audiod-daemon: $cases assertion(s) passed against the real daemon"
