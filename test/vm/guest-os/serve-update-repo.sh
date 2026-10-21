#!/bin/bash
# serve the ubuntu update debs over http
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PORT="${RHIZO_UPDATE_REPO_PORT:-40002}"

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit
POOL="${RHIZO_UPDATE_REPO_POOL:-$(pwd)/var/share/ubuntu-update-debs}"
DETACHED_DIR="${RHIZO_UPDATE_REPO_DETACHED_DIR:-$(pwd)/var/detached}"
mkdir -p "$DETACHED_DIR"
PIDFILE="$DETACHED_DIR/serve-update-repo.pid"
LOGFILE="$DETACHED_DIR/serve-update-repo.log"
LOCKFILE="$DETACHED_DIR/serve-update-repo.lock"

# print a line prefixed with the script name
log() { echo "[serve-update-repo] $*"; }

# fetch the Release file from the repo
up() {
  curl -sf -o /dev/null "http://127.0.0.1:$PORT/Release"
}

# print the sha256 of the pool Packages file
pool_packages_sha() {
  [[ -s "$POOL/Packages" ]] || return 1
  sha256sum "$POOL/Packages" 2>/dev/null | cut -d' ' -f1
}

# print the sha256 of the Packages file the server serves
served_packages_sha() {
  local tmp sha
  tmp=$(mktemp) || return 1
  if ! curl -sf -o "$tmp" "http://127.0.0.1:$PORT/Packages" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi
  sha=$(sha256sum "$tmp" | cut -d' ' -f1)
  rm -f "$tmp"
  [[ -n "$sha" ]] || return 1
  echo "$sha"
}

# compare the served and pool Packages hashes
serving_ours() {
  up || return 1
  local want have
  want=$(pool_packages_sha)
  [[ -n "$want" ]] || return 1
  have=$(served_packages_sha)
  [[ -n "$have" && "$have" == "$want" ]]
}

# succeed when the server's pid is alive
running() {
  [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
}

# print the url the guest reaches the server at
url() { echo "http://10.0.2.2:$PORT/"; }

# print the served and pool Packages hashes
foreign_report() {
  local want have
  want=$(pool_packages_sha)
  have=$(served_packages_sha)
  echo "port $PORT is already serving a DIFFERENT pool than $POOL -- served Packages sha256=${have:-<unreadable or empty>}, ours=${want:-<no non-empty local Packages>}"
}

t="" foreign_pid="" test_pid=""
# stop the selftest servers and remove the temp dir
selftest_cleanup() {
  [[ -n "$foreign_pid" ]] && kill "$foreign_pid" 2>/dev/null
  [[ -n "$test_pid" ]] && kill "$test_pid" 2>/dev/null
  [[ -n "$t" ]] && rm -rf "$t"
}

# test start against another pool on the port
serve_update_repo_selftest() {
  local rc port out cases=0
  t=$(mktemp -d) || { echo "SELFTEST FAILED: mktemp -d" >&2; selftest_cleanup; exit 1; }

  mkdir -p "$t/pool-a" "$t/pool-b" "$t/detached"
  printf 'A: our pool\n' > "$t/pool-a/Packages"
  printf 'Release-A\n' > "$t/pool-a/Release"
  printf 'B: a foreign worktree pool\n' > "$t/pool-b/Packages"
  printf 'Release-B\n' > "$t/pool-b/Release"

  port=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
  [[ -n "$port" ]] || { echo "SELFTEST FAILED: could not allocate a scratch port" >&2; selftest_cleanup; exit 1; }

  start_foreign() {
    ( cd "$1" && exec python3 -m http.server "$port" --bind 127.0.0.1 ) \
      >"$t/foreign.log" 2>&1 &
    foreign_pid=$!
    local deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
      curl -sf -o /dev/null "http://127.0.0.1:$port/Release" && return 0
      sleep 0.5
    done
    echo "SELFTEST FAILED: the foreign fixture server on $1 never answered" >&2
    selftest_cleanup; exit 1
  }
  start_foreign "$t/pool-b"
  local deadline

  cases=$((cases + 1))
  out=$(RHIZO_UPDATE_REPO_PORT="$port" RHIZO_UPDATE_REPO_POOL="$t/pool-a" RHIZO_UPDATE_REPO_DETACHED_DIR="$t/detached" "$SELF" start 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "SELFTEST FAILED: start succeeded against a port a foreign server already held: $out" >&2
    selftest_cleanup; exit 1
  fi
  if ! grep -q 'DIFFERENT pool' <<<"$out"; then
    echo "SELFTEST FAILED: start's refusal did not name a pool mismatch: $out" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: start refuses (rc=$rc) rather than reuse a foreign server: ${out##*$'\n'}"

  cases=$((cases + 1))
  if ! kill -0 "$foreign_pid" 2>/dev/null; then
    echo "SELFTEST FAILED: the foreign server was killed by a refused start" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: the foreign server is still running, untouched"

  kill "$foreign_pid" 2>/dev/null
  deadline=$((SECONDS + 10))
  while curl -sf -o /dev/null "http://127.0.0.1:$port/Release" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.5; done

  cases=$((cases + 1))
  out=$(RHIZO_UPDATE_REPO_PORT="$port" RHIZO_UPDATE_REPO_POOL="$t/pool-a" RHIZO_UPDATE_REPO_DETACHED_DIR="$t/detached" "$SELF" start 2>&1)
  rc=$?
  test_pid=$(cat "$t/detached/serve-update-repo.pid" 2>/dev/null)
  if [[ "$rc" -ne 0 ]]; then
    echo "SELFTEST FAILED: start on a free port failed: $out" >&2
    selftest_cleanup; exit 1
  fi
  local served; served=$(curl -sf "http://127.0.0.1:$port/Packages" 2>/dev/null)
  if [[ "$served" != "$(cat "$t/pool-a/Packages")" ]]; then
    echo "SELFTEST FAILED: served Packages does not match pool-a's own bytes" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: start on a free port serves our own pool-a, byte for byte"

  cases=$((cases + 1))
  out=$(RHIZO_UPDATE_REPO_PORT="$port" RHIZO_UPDATE_REPO_POOL="$t/pool-a" RHIZO_UPDATE_REPO_DETACHED_DIR="$t/detached" "$SELF" start 2>&1)
  rc=$?
  if [[ "$rc" -ne 0 ]] || ! grep -q 'already serving' <<<"$out"; then
    echo "SELFTEST FAILED: a second start against our own pool did not report already-serving: rc=$rc $out" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: a second start against our own already-serving pool is idempotent"

  RHIZO_UPDATE_REPO_PORT="$port" RHIZO_UPDATE_REPO_POOL="$t/pool-a" RHIZO_UPDATE_REPO_DETACHED_DIR="$t/detached" "$SELF" stop >/dev/null 2>&1
  test_pid=""

  mkdir -p "$t/pool-empty" "$t/pool-c"
  : > "$t/pool-empty/Packages"
  printf 'Release-empty\n' > "$t/pool-empty/Release"
  printf 'Release-C\n' > "$t/pool-c/Release"
  start_foreign "$t/pool-c"

  cases=$((cases + 1))
  out=$(POOL="$t/pool-empty"; pool_packages_sha)
  rc=$?
  if [[ "$rc" -eq 0 || -n "$out" ]]; then
    echo "SELFTEST FAILED: pool_packages_sha accepted a 0-byte local Packages: rc=$rc sha=$out" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: pool_packages_sha refuses a 0-byte local Packages (rc=$rc)"

  cases=$((cases + 1))
  out=$(PORT="$port"; served_packages_sha)
  rc=$?
  if [[ "$rc" -eq 0 || -n "$out" ]]; then
    echo "SELFTEST FAILED: served_packages_sha hashed a Packages the server does not serve: rc=$rc sha=$out" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: served_packages_sha refuses a server with no Packages (rc=$rc)"

  cases=$((cases + 1))
  out=$(RHIZO_UPDATE_REPO_PORT="$port" RHIZO_UPDATE_REPO_POOL="$t/pool-empty" RHIZO_UPDATE_REPO_DETACHED_DIR="$t/detached" "$SELF" start 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]] || ! grep -q 'DIFFERENT pool' <<<"$out"; then
    echo "SELFTEST FAILED: start with a 0-byte Packages against a foreign server with none did not refuse by name: rc=$rc $out" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: start refuses (rc=$rc) a 0-byte pool against a foreign server with no Packages: ${out##*$'\n'}"

  cases=$((cases + 1))
  out=$(RHIZO_UPDATE_REPO_PORT="$port" RHIZO_UPDATE_REPO_POOL="$t/pool-empty" RHIZO_UPDATE_REPO_DETACHED_DIR="$t/detached" "$SELF" status 2>&1)
  rc=$?
  if [[ "$rc" -eq 0 ]] || grep -q 'RUNNING' <<<"$out"; then
    echo "SELFTEST FAILED: status called a foreign server with no Packages ours: rc=$rc $out" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: status does not report RUNNING (rc=$rc) for that foreign server"

  cases=$((cases + 1))
  : > "$t/pool-c/Packages"
  out=$(PORT="$port"; served_packages_sha)
  rc=$?
  if [[ "$rc" -eq 0 || -n "$out" ]]; then
    echo "SELFTEST FAILED: served_packages_sha hashed a 0-byte served Packages: rc=$rc sha=$out" >&2
    selftest_cleanup; exit 1
  fi
  echo "  selftest OK: served_packages_sha refuses a 0-byte served Packages (rc=$rc)"

  selftest_cleanup
  echo "serve-update-repo selftest: $cases assertions passed"
}

case "${1:-}" in
  --selftest)
    serve_update_repo_selftest
    ;;

  start)
    exec 9>"$LOCKFILE"
    flock 9
    if serving_ours; then
      log "already serving -- $(url)"
      exit 0
    fi
    if up; then
      log "FAIL: $(foreign_report)"
      exit 1
    fi
    [[ -s "$POOL/Packages" && -f "$POOL/Release" ]] \
      || { log "FAIL: no non-empty $POOL/Packages or no $POOL/Release -- run tools/fetch/pools/deb/ubuntu-update-debs.sh first"; exit 1; }
    if running; then
      pid=$(cat "$PIDFILE")
      kill "$pid" 2>/dev/null
      deadline=$((SECONDS + 10))
      while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    setsid sh -c "exec 9>&-; echo \$\$ > '$PIDFILE'; exec python3 -m http.server '$PORT' --directory '$POOL' --bind 0.0.0.0" \
      >"$LOGFILE" 2>&1 < /dev/null &
    disown
    deadline=$((SECONDS + 15))
    ready=0
    while (( SECONDS < deadline )); do
      if serving_ours; then
        ready=1
        break
      fi
      sleep 1
    done
    if (( ! ready )); then
      if up; then
        log "FAIL: $(foreign_report)"
      else
        log "FAIL: server did not answer http://127.0.0.1:$PORT/Release within 15s -- $LOGFILE:"
        tail -20 "$LOGFILE" >&2
      fi
      exit 1
    fi
    log "serving $POOL on pid $(cat "$PIDFILE" 2>/dev/null) -- $(url)"
    ;;

  stop)
    exec 9>"$LOCKFILE"
    flock 9
    if ! running; then
      log "not running"
      rm -f "$PIDFILE"
      exit 0
    fi
    pid=$(cat "$PIDFILE")
    kill "$pid" 2>/dev/null
    deadline=$((SECONDS + 10))
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 1; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    rm -f "$PIDFILE"
    log "stopped"
    ;;

  status)
    if serving_ours; then
      log "RUNNING pid $(cat "$PIDFILE" 2>/dev/null) -- $(url)"
    elif up; then
      log "FAIL: $(foreign_report)"
      exit 1
    elif running; then
      log "pid $(cat "$PIDFILE" 2>/dev/null) alive but not answering http://127.0.0.1:$PORT/Release"
      exit 1
    else
      log "not running"
      exit 1
    fi
    ;;

  url)
    url
    ;;

  *)
    echo "usage: $0 {start|stop|status|url|--selftest}" >&2
    exit 2
    ;;
esac
