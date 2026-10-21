#!/bin/bash
# test the instance pool commands of rhizo.sh
# shellcheck disable=SC1090
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
REPO="$(cd "$HERE/../.." && pwd)"

if [[ "${1:-}" == "--selftest" ]]; then
  shift
  SELFTEST=1
else
  SELFTEST=0
fi
CLI="${1:-$REPO/src/install/cli/rhizo.sh}"
CAPS_SRC="$REPO/src/androidd/sandbox/capabilities.py"
[[ -r "$CLI" ]] || { echo "no rhizo.sh at $CLI" >&2; exit 2; }

WORK=$(mktemp -d) || exit 2
kill_fake_inits() { cat "$WORK"/*/.systemd/fake-inits 2>/dev/null | xargs -r kill 2>/dev/null; return 0; }
if [[ "${RHIZO_FIXTURE_KEEP:-0}" == 1 ]]; then
  trap 'kill_fake_inits; echo "fixture kept at $WORK"' EXIT
else
  trap 'kill_fake_inits; rm -rf "$WORK"' EXIT
fi

RUN_LOG="$WORK/checks-run"; : > "$RUN_LOG"
FAIL_LOG="$WORK/checks-failed"; : > "$FAIL_LOG"

# print ok or FAIL for a check
check() {
  echo "$1" >> "$RUN_LOG"
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "       got  $2"
    echo "       want $3"
    echo "$1" >> "$FAIL_LOG"
  fi
}
note() { echo "     .. $*"; }
section() { echo; echo "=== $* ==="; }

# replace text in a copy of rhizo.sh
mutate() {
  python3 - "$CLI" "$1" "$2" "$3" "$4" <<'PYEOF'
import sys
src, dst, old, new, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
text = open(src).read()
got = text.count(old)
if got != want:
    sys.exit("mutation anchor %r: expected %d occurrence(s), found %d" % (old[:60], want, got))
open(dst, "w").write(text.replace(old, new))
PYEOF
}

# print the failed check names
failed_against() {
  local out
  out=$(bash "${BASH_SOURCE[0]}" "$1" 2>&1)
  sed -n 's/^  - \([0-9][^.]*\)\..*/\1/p' <<<"$out" | tr '\n' ' ' | sed 's/ $//'
}

if (( SELFTEST )); then
  SCRATCH=$(mktemp -d) || exit 2
  trap 'kill_fake_inits; rm -rf "$WORK" "$SCRATCH"' EXIT
  fails=0
  expect_caught() {
    local label="$1" mutant="$2"; shift 2
    local got name
    got=$(failed_against "$mutant")
    for name in "$@"; do
      if [[ " $got " == *" $name "* ]]; then
        echo "ok   $label: reverting it is caught by $name"
      else
        echo "FAIL $label: reverting it is NOT caught by $name"
        echo "       the mutant's failures were: ${got:-<none>}"
        fails=1
      fi
    done
  }

  mutate "$SCRATCH/f1.sh" \
    $'pool_unlock() {\n  flock -u 9 2>/dev/null\n  exec 9>&-\n}' \
    $'pool_unlock() {\n  flock -u 9 2>/dev/null\n  exec 9>&- 2>/dev/null\n}' 1 || exit 2
  expect_caught "F1 pool_unlock's exec carries no 2>/dev/null" "$SCRATCH/f1.sh" \
    "0b" "0c" "1'c2" "2'a2" "4d1" "4d3" "4e1" "6m"

  mutate "$SCRATCH/f2.sh" 'do_instance_add "$id" "" >&2' 'do_instance_add "$id" ""' 1 || exit 2
  expect_caught "F2 the instance add's sentinel stays off stdout" "$SCRATCH/f2.sh" "1a2"

  mutate "$SCRATCH/f3.sh" \
    $'  if [[ -n "$dir" && -e "$dir" ]]; then' \
    $'  if false; then' 1 || exit 2
  expect_caught "F3 instance remove reclaims the per-instance trees" "$SCRATCH/f3.sh" \
    "6f" "6g" "6h"

  mutate "$SCRATCH/f4.sh" \
    $'\n    check_server_profile_for_instance "$id"\n' $'\n' 1 || exit 2
  expect_caught "F4 the instance pool asks the profile refusal too" "$SCRATCH/f4.sh" "7e" "7e2"

  mutate "$SCRATCH/f5.sh" \
    $'  src=""\n  if [[ -n "$from" ]]; then\n    src=$(find_template "$from")' \
    $'  src=""\n  mkdir -p "$(dirname "$img")"\n  if [[ -n "$from" ]]; then\n    src=$(find_template "$from")' 1 || exit 2
  expect_caught "F5 a refused --from creates no instance directory" "$SCRATCH/f5.sh" "5j"

  mutate "$SCRATCH/f6.sh" \
    $'    if ! wait_boot_completed "$id" 300; then\n      log "instance $id reported no sys.boot_completed=1: stopped, left out of the pool"\n      systemctl stop "$unit"\n      pool_reservation_drop "$id"; break\n    fi\n' \
    '' 1 || exit 2
  expect_caught "F6 a pool member is frozen only after its boot completes" "$SCRATCH/f6.sh" "1h2"

  mutate "$SCRATCH/f7.sh" \
    $'    if ! wait_boot_completed "$id" 300; then\n      log "instance $id reported no sys.boot_completed=1: stopped, left out of the pool"\n      systemctl stop "$unit"\n      pool_reservation_drop "$id"; break\n    fi\n' \
    $'    wait_boot_completed "$id" 300 || true\n' 1 || exit 2
  expect_caught "F7 a pool member whose boot never completes is left out, not frozen" "$SCRATCH/f7.sh" \
    "1o1" "1o2" "1o4" "1o5"

  mutate "$SCRATCH/f8.sh" \
    $'    wait_boot_completed "$id" 300 \\\n      || die "$unit restarted after the snapshot with no sys.boot_completed=1' \
    $'    { wait_boot_completed "$id" 300 || true; } \\\n      || die "$unit restarted after the snapshot with no sys.boot_completed=1' 1 || exit 2
  expect_caught "F8 a restored member is re-frozen only once its boot completes" "$SCRATCH/f8.sh" \
    "4f0" "4f2" "4f4"
  mutate "$SCRATCH/f9.sh" \
    $'    wait_boot_completed "$id" 300 \\\n      || die "$unit restarted after the snapshot with no sys.boot_completed=1' \
    $'    true \\\n      || die "$unit restarted after the snapshot with no sys.boot_completed=1' 1 || exit 2
  expect_caught "F9 a restored member's boot is asked before its re-freeze" "$SCRATCH/f9.sh" \
    "4c8b" "4f0" "4f3"

  clean=$(failed_against "$CLI")
  if [[ -z "$clean" ]]; then
    echo "ok   the shipped src/install/cli/rhizo.sh fails none of them"
  else
    echo "FAIL the shipped src/install/cli/rhizo.sh still fails: $clean"
    fails=1
  fi

  (( fails )) && { echo "check-rhizo-cli-pool selftest: FAILED"; exit 1; }
  echo "check-rhizo-cli-pool selftest: 9 reverted fixes caught by name (F1 pool_unlock stderr, F2 pool set's second sentinel, F3 the leaked vendor/apex trees, F4 the pool's missing profile refusal, F5 the refused clone's leftover directory, F6 a member frozen before its boot, F7 an unbooted member frozen anyway, F8 and F9 a restored member re-frozen unbooted), the shipped file clean"
  exit 0
fi

mkdir -p "$WORK/lib/sandbox"
cp "$CAPS_SRC" "$WORK/lib/sandbox/capabilities.py"
cat > "$WORK/lib/probe-client.py" <<'EOF'
import os, re, sys
sock, cmd = sys.argv[1], sys.argv[3]
if not os.path.exists(sock):
    sys.exit(1)
m = re.search(r"/run/rhizo-(\d+)/data/local/tmp/rhizo-probe\.sock$", sock)
unit = "androidd@%s.service" % m.group(1) if m else "androidd.service"
if "getprop sys.boot_completed" in cmd:
    with open(os.path.join(os.environ["RHIZO_FIXTURE_ROOT"], ".systemd", "calls.log"), "a") as log:
        log.write("probe %s sys.boot_completed\n" % unit)
    if unit not in os.environ.get("RHIZO_FIX_NO_BOOT", "").split():
        print("1")
EOF

mkdir -p "$WORK/bin"

cat > "$WORK/bin/systemctl" <<'EOF'
#!/bin/bash
set -uo pipefail
R="${RHIZO_FIXTURE_ROOT:?}"
SD="$R/.systemd"
mkdir -p "$SD/state" "$SD/frozen"
printf '%s\n' "$*" >> "$SD/calls.log"
printf '%s | members=%s\n' "$*" \
  "$(tr '\n' ',' < "${RHIZO_STATE_DIR:-/nonexistent}/pool-members" 2>/dev/null)" \
  >> "$SD/calls-with-pool.log"
sub="${1:-}"; shift || true
unit=""
for a in "$@"; do
  case "$a" in androidd.service|androidd@*.service|rhizo-*) unit="$a" ;; esac
done
id_of() {
  case "$1" in
    androidd@*.service) local t="${1#androidd@}"; printf '%s\n' "${t%.service}" ;;
    *) printf '0\n' ;;
  esac
}
sock_dir() {
  local id="$1" rr="$R/run/rhizo"
  [[ "$id" == 0 ]] || rr="$R/run/rhizo-$id"
  printf '%s/data/local/tmp\n' "$rr"
}
listed() {
  [[ " ${1:-} " == *" $2 "* ]]
}
state_of() { cat "$SD/state/$unit" 2>/dev/null || echo inactive; }
pid_file() {
  local id; id=$(id_of "$unit")
  if [[ "$id" == 0 ]]; then printf '%s\n' "${RHIZO_INIT_PID_BASE:?}"; else printf '%s-%s\n' "${RHIZO_INIT_PID_BASE:?}" "$id"; fi
}
stop_fake_init() {
  local pf pid; pf=$(pid_file); pid=$(cat "$pf" 2>/dev/null)
  [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null
  rm -f "$pf"
}

[[ -n "$unit" ]] || exit 0
case "$sub" in
  start)
    listed "${RHIZO_FIX_FAIL_START:-}" "$unit" && exit 1
    echo active > "$SD/state/$unit"
    rm -f "$SD/frozen/$unit"
    if ! listed "${RHIZO_FIX_NO_SOCKET:-}" "$unit"; then
      d=$(sock_dir "$(id_of "$unit")")
      mkdir -p "$d"
      python3 - "$d" <<'PY'
import os, socket, sys
os.chdir(sys.argv[1])
try:
    os.unlink('rhizo-probe.sock')
except FileNotFoundError:
    pass
socket.socket(socket.AF_UNIX).bind('rhizo-probe.sock')
PY
    fi
    stop_fake_init
    mkdir -p "$(dirname "$(pid_file)")"
    (exec -a "init second_stage" sleep 300) </dev/null >/dev/null 2>&1 &
    echo "$!" > "$(pid_file)"
    echo "$!" >> "$SD/fake-inits"
    exit 0
    ;;
  stop)
    listed "${RHIZO_FIX_FAIL_STOP:-}" "$unit" && exit 1
    echo inactive > "$SD/state/$unit"
    rm -f "$SD/frozen/$unit"
    rm -f "$(sock_dir "$(id_of "$unit")")/rhizo-probe.sock"
    stop_fake_init
    exit 0
    ;;
  freeze)
    listed "${RHIZO_FIX_FAIL_FREEZE:-}" "$unit" && exit 1
    [[ "$(state_of)" == active ]] || exit 1
    : > "$SD/frozen/$unit"
    exit 0
    ;;
  thaw)
    [[ "$(state_of)" == active ]] || exit 1
    rm -f "$SD/frozen/$unit"
    exit 0
    ;;
  is-active)
    s=$(state_of); echo "$s"
    [[ "$s" == active ]] && exit 0 || exit 3
    ;;
  show)
    if [[ -e "$SD/frozen/$unit" ]]; then echo frozen; else echo running; fi
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/systemctl"

cat > "$WORK/bin/systemd-run" <<'EOF'
#!/bin/bash
set -uo pipefail
R="${RHIZO_FIXTURE_ROOT:?}"
SD="$R/.systemd"
mkdir -p "$SD/pending"
printf '%s\n' "$*" >> "$SD/run.log"
[[ "${RHIZO_FIX_SYSTEMD_RUN_FAIL:-0}" == 1 ]] && exit 1
unit=""; envs=(); cmd=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit=*)    unit="${1#--unit=}"; shift ;;
    --setenv=*)  envs+=("${1#--setenv=}"); shift ;;
    --collect|--quiet|--pipe|--wait) shift ;;
    --description=*) shift ;;
    -*) shift ;;
    *) cmd=("$@"); break ;;
  esac
done
[[ -n "$unit" ]] || exit 1
{
  echo '#!/bin/bash'
  for e in "${envs[@]}"; do printf 'export %s\n' "$(printf '%q' "$e" | sed "s/^'//;s/'$//")"; done
  printf 'exec'
  printf ' %q' "${cmd[@]}"
  printf '\n'
} > "$SD/pending/$unit"
chmod +x "$SD/pending/$unit"
exit 0
EOF
chmod +x "$WORK/bin/systemd-run"

cat > "$WORK/bin/cp" <<'EOF'
#!/bin/bash
set -uo pipefail
R="${RHIZO_FIXTURE_ROOT:?}"
mkdir -p "$R/.systemd"
printf '%s\n' "$*" >> "$R/.systemd/cp.log"
[[ "${RHIZO_FIX_CP_FAIL:-0}" == 1 ]] && exit 1
exec /bin/cp "$@"
EOF
chmod +x "$WORK/bin/cp"

cat > "$WORK/bin/sync" <<'EOF'
#!/bin/bash
set -uo pipefail
R="${RHIZO_FIXTURE_ROOT:?}"
mkdir -p "$R/.systemd"
printf '%s\n' "$*" >> "$R/.systemd/sync.log"
[[ "${RHIZO_FIX_SYNC_FAIL:-0}" == 1 ]] && exit 1
exit 0
EOF
chmod +x "$WORK/bin/sync"

# create a host tree and print its path
new_root() {
  local r="$WORK/$1"
  mkdir -p "$r/etc/rhizo/instances" "$r/var/lib/rhizo" "$r/var/log/rhizo" \
           "$r/run" "$r/root" "$r/.systemd/state" "$r/.systemd/frozen" "$r/.systemd/pending"
  : > "$r/.systemd/calls.log"
  : > "$r/.systemd/run.log"
  printf '[rhizo]\nprofile = server\n' > "$r/etc/rhizo/policy.conf"
  printf '%s\n' "$r"
}

# export the RHIZO_* variables for a root
use_root() {
  export RHIZO_FIXTURE_ROOT="$1"
  export RHIZO_CLI_TEST_NO_ROOT=1
  export RHIZO_STATE_DIR="$1/var/lib/rhizo"
  export RHIZO_ETC_DIR="$1/etc/rhizo"
  export RHIZO_VAR_CACHE="$1/var/cache/rhizo"
  export RHIZO_VAR_LOG="$1/var/log/rhizo"
  export RHIZO_SYSTEMD_ETC_DIR="$1/etc/systemd/system"
  export RHIZO_GSI_ROOT="$1/srv/rhizo"
  export RHIZO_RUN_MOUNT="$1/run"
  export RHIZO_INIT_PID_BASE="$1/root/.rhizo_init_pid"
  export RHIZO_LIB_DIR="$WORK/lib"
  export RHIZO_POLICY_CONF="$1/etc/rhizo/policy.conf"
  export RHIZO_POOL_HEADROOM_BYTES=$(( 64 * 1024 * 1024 * 1024 ))
  export PATH="$WORK/bin:$PATH"
}

# write an env file for each id
configured() {
  local r="$1"; shift
  local id
  for id in "$@"; do printf 'RHIZO_SANDBOX_ID=%s\n' "$id" > "$r/etc/rhizo/instances/$id.env"; done
}

# count the calls.log lines for a call
call_count() {
  grep -cxF "$2" "$1/.systemd/calls.log" 2>/dev/null || true
}
# check the first call precedes the second
call_order_ok() {
  local a b
  a=$(grep -nxF "$2" "$1/.systemd/calls.log" 2>/dev/null | head -1 | cut -d: -f1)
  b=$(grep -nxF "$3" "$1/.systemd/calls.log" 2>/dev/null | tail -1 | cut -d: -f1)
  if [[ -n "$a" && -n "$b" ]] && (( a < b )); then echo yes; else echo no; fi
}
# print the pool members at a call
members_at() {
  local line
  line=$(grep -F "$2 | members=" "$1/.systemd/calls-with-pool.log" 2>/dev/null | head -1)
  [[ -n "$line" ]] || { printf '<no-such-call>\n'; return; }
  printf '%s\n' "${line#*| members=}"
}
# print the non-blank lines of a file
lines_of() {
  local f="$1" out
  out=$(grep -ve '^[[:space:]]*$' "$f" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
  printf '%s\n' "${out:-<empty>}"
}
# print yes when a path exists, else no
exists() { [[ -e "$1" ]] && echo yes || echo no; }
# run each pending systemd-run script
run_pending() {
  local f
  for f in "$1/.systemd/pending"/*; do
    [[ -f "$f" ]] || continue
    bash "$f" >/dev/null 2>&1
    rm -f "$f"
  done
}
# write the content to a file
mkimg() {
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}

note "subject: $CLI"

section "0. does anything the CLI says after a pool lock still reach the operator"
(
  R=$(new_root case0); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"

  before=$( (log "before any lock") 2>&1 >/dev/null )
  check "0a. a log line before any pool lock reaches stderr" "$before" "[rhizo] before any lock"
  after=$( (pool_lock; pool_unlock; log "after an unlock") 2>&1 >/dev/null )
  check "0b. a log line after pool_unlock reaches stderr" "$after" "[rhizo] after an unlock"
  dmsg=$( (pool_lock; pool_unlock; die "the instance pool is empty") 2>&1 >/dev/null )
  check "0c. a die after pool_unlock still names its reason" "$dmsg" "[rhizo] FAIL: the instance pool is empty"
  unlock_with_the_exec_redirect() { flock -u 9 2>/dev/null; exec 9>&- 2>/dev/null; }
  lost=$( (pool_lock; unlock_with_the_exec_redirect; log "after an unlock") 2>&1 >/dev/null )
  check "0d. ... and does not when the exec carries one (the mechanism)" "$lost" ""
)

section "1. pool set 1 from empty"
(
  R=$(new_root case1); use_root "$R"
  configured "$R" 1 2
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"

  out=$(cmd_pool_set 1 2>"$R/stderr")
  check "1a. pool set 1's own final line reports k=1 members=1" "$(tail -1 <<<"$out")" \
        "RHIZO_POOL k=1 members=1"
  check "1a2. pool set puts exactly one sentinel line on stdout" \
        "$(grep -c '^RHIZO_' <<<"$out")" 1
  check "1a3. the instance add's sentinel is still narrated, on stderr" \
        "$(grep -c '^RHIZO_INSTANCE_ADDED id=3 ' "$R/stderr")" 1
  check "1b. K landed in pool.conf" "$(cat "$R/etc/rhizo/pool.conf")" "K=1"
  check "1c. exactly one instance was added" \
        "$(ls "$R/etc/rhizo/instances"/*.env | wc -l)" 3
  check "1d. the id added is the next free one above the configured ones" \
        "$(exists "$R/etc/rhizo/instances/3.env")" yes
  check "1e. its env file names its own id" \
        "$(cat "$R/etc/rhizo/instances/3.env")" "RHIZO_SANDBOX_ID=3"
  check "1f. the member was started" "$(call_count "$R" "start androidd@3.service")" 1
  check "1g. the member was frozen (parked, not left running)" \
        "$(call_count "$R" "freeze androidd@3.service")" 1
  check "1h. the freeze came after the start" \
        "$(call_order_ok "$R" "start androidd@3.service" "freeze androidd@3.service")" yes
  check "1h2. the freeze came after the member's own sys.boot_completed was asked" \
        "$(call_order_ok "$R" "probe androidd@3.service sys.boot_completed" "freeze androidd@3.service")" yes
  check "1i. the unit is left frozen" "$(exists "$R/.systemd/frozen/androidd@3.service")" yes
  check "1j. pool-members holds exactly the member" "$(lines_of "$R/var/lib/rhizo/pool-members")" "3"
  check "1k. pool-pending was drained by the promotion" \
        "$(lines_of "$R/var/lib/rhizo/pool-pending")" "<empty>"
  check "1l. pool status agrees with both files" "$(cmd_pool_status)" \
        "RHIZO_POOL k=1 members=1 pending=0"
  check "1m. the member's own directory exists" "$(exists "$R/var/lib/rhizo/instances/3")" yes
  check "1n. a new member gets no data.img of its own from the CLI" \
        "$(exists "$R/var/lib/rhizo/instances/3/data.img")" no
)

section "1o. pool set 1 when the member starts but its boot never completes"
(
  R=$(new_root case1o); use_root "$R"
  configured "$R" 1 2
  export RHIZO_FIX_NO_BOOT="androidd@3.service"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  sleep() { SECONDS=$(( SECONDS + ${1%%.*} )); }

  out=$(cmd_pool_set 1 2>"$R/stderr")
  check "1o1. a member whose boot never completes is never frozen" \
        "$(call_count "$R" "freeze androidd@3.service")" 0
  check "1o2. ... it is stopped instead" "$(call_count "$R" "stop androidd@3.service")" 1
  check "1o3. ... only after its own sys.boot_completed was asked" \
        "$(call_order_ok "$R" "probe androidd@3.service sys.boot_completed" "stop androidd@3.service")" yes
  check "1o4. pool-members stays empty" "$(lines_of "$R/var/lib/rhizo/pool-members")" "<empty>"
  check "1o5. pool set reports members=0 against k=1" "$(tail -1 <<<"$out")" "RHIZO_POOL k=1 members=0"
  check "1o6. the operator is told why" \
        "$(grep -c 'instance 3 reported no sys.boot_completed=1' "$R/stderr")" 1
)

section "1'. pool set 1 when the member's own boot fails (the observed vm run)"
(
  R=$(new_root case1b); use_root "$R"
  export RHIZO_FIX_FAIL_START="androidd@1.service"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"

  out=$(cmd_pool_set 1 2>"$R/stderr")
  rc=$?
  check "1'a. pool set exits 0 even though the pool was never filled" "$rc" 0
  check "1'b. it reports members=0 against k=1 (the vm's own symptom)" \
        "$(tail -1 <<<"$out")" "RHIZO_POOL k=1 members=0"
  check "1'c. the system test's assert_pool_configured verdict on that" \
        "$(if [[ "$(tail -1 <<<"$out")" == "RHIZO_POOL k=1 members=1" ]]; then echo pass; else echo fail; fi)" fail
  check "1'c1. the narration before the first pool_unlock survives" \
        "$(grep -c 'to the pool (target 1)' "$R/stderr")" 1
  check "1'c2. the operator is told WHY the member was left out" \
        "$(grep -c 'failed to start' "$R/stderr")" 1
  check "1'd. the reservation was dropped" "$(lines_of "$R/var/lib/rhizo/pool-pending")" "<empty>"
  check "1'e. but instance 1's env file is left behind" \
        "$(exists "$R/etc/rhizo/instances/1.env")" yes
  unset RHIZO_FIX_FAIL_START
  out2=$(cmd_pool_set 1 2>>"$R/stderr")
  check "1'f. the retry fills the pool" "$(tail -1 <<<"$out2")" "RHIZO_POOL k=1 members=1"
  check "1'g. ... with a NEW id, id 1 is burnt" "$(lines_of "$R/var/lib/rhizo/pool-members")" "2"
  check "1'h. two ids are now configured for a pool of one" \
        "$(ls "$R/etc/rhizo/instances"/*.env | wc -l)" 2
  check "1'i. and 'instance remove' is what un-burns the id" \
        "$(cmd_instance_remove 1 >/dev/null 2>&1; pool_next_free_id)" 1
)

section "1''. pool set with no measurable headroom"
(
  R=$(new_root case1c); use_root "$R"
  unset RHIZO_POOL_HEADROOM_BYTES
  export RHIZO_LIB_DIR="$R/nonexistent-lib"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"

  err=$( (cmd_pool_set 1) 2>&1 >/dev/null )
  check "1''a. an unmeasurable headroom refuses rather than sizing blind" \
        "$(grep -c 'could not measure host memory headroom' <<<"$err")" 1
  check "1''b. ... and says nothing about WHY the measurement failed" \
        "$(grep -c 'core\|ModuleNotFound\|Traceback' <<<"$err")" 0
  check "1''c. no pool.conf was written" "$(exists "$R/etc/rhizo/pool.conf")" no
)

section "2. instance allocate with one member"
(
  R=$(new_root case2); use_root "$R"
  configured "$R" 1 2
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"

  cmd_pool_set 1 >/dev/null 2>&1
  : > "$R/.systemd/calls.log"

  out=$(cmd_instance_allocate 2>"$R/stderr")
  check "2a. allocate prints the id it handed out" "$out" "RHIZO_ALLOCATED id=3 adb="
  check "2b. the member was unfrozen" "$(call_count "$R" "thaw androidd@3.service")" 1
  check "2c. the id left pool-members at once" \
        "$(lines_of "$R/var/lib/rhizo/pool-members")" "<empty>"
  check "2d. a replacement unit was requested by name" \
        "$(grep -c 'unit=rhizo-pool-replace-3' "$R/.systemd/run.log")" 1
  check "2e. the replacement is its own transient unit, not a subshell" \
        "$(exists "$R/.systemd/pending/rhizo-pool-replace-3")" yes
  check "2f. it re-enters the CLI as 'pool reconcile'" \
        "$(grep -c 'pool reconcile' "$R/.systemd/pending/rhizo-pool-replace-3")" 1
  check "2g. it carries RHIZO_STATE_DIR across the unit boundary" \
        "$(grep -c 'RHIZO_STATE_DIR' "$R/.systemd/pending/rhizo-pool-replace-3")" 1

  run_pending "$R"
  check "2h. after the replacement runs, the pool is back at k" \
        "$(lines_of "$R/var/lib/rhizo/pool-members")" "4"
  check "2i. ... with a NEW id, never the allocated one" \
        "$(grep -c '^3$' "$R/var/lib/rhizo/pool-members")" 0
  check "2j. pool-pending is empty (system test 7d)" \
        "$(lines_of "$R/var/lib/rhizo/pool-pending")" "<empty>"
  check "2k. pool status reports the drained reservation (system test 7d)" \
        "$(cmd_pool_status)" "RHIZO_POOL k=1 members=1 pending=0"
  check "2l. the replacement was started and frozen too" \
        "$(call_count "$R" "freeze androidd@4.service")" 1
)

section "2'. allocate against an empty pool"
(
  R=$(new_root case2b); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  mkdir -p "$R/var/lib/rhizo"; : > "$R/var/lib/rhizo/pool-members"
  err=$( (cmd_instance_allocate) 2>&1 >/dev/null ); rc=$?
  check "2'a. an empty pool is refused" "$rc" 1
  check "2'a2. ... by name, so the caller learns why" \
        "$(grep -c 'the instance pool is empty' <<<"$err")" 1
  check "2'b. no replacement unit was asked for" \
        "$(ls "$R/.systemd/pending" | wc -l)" 0
)

section "3. pool set 0 with members present"
(
  R=$(new_root case3); use_root "$R"
  configured "$R" 1
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"

  cmd_pool_set 2 >/dev/null 2>&1
  before=$(lines_of "$R/var/lib/rhizo/pool-members")
  check "3a. two members first" "$before" "2 3"
  : > "$R/.systemd/calls.log"

  out=$(cmd_pool_set 0 2>"$R/stderr")
  check "3b. pool set 0 reports an empty pool" "$out" "RHIZO_POOL k=0 members=0"
  check "3c. pool-members is empty" "$(lines_of "$R/var/lib/rhizo/pool-members")" "<empty>"
  check "3d. pool-pending is empty" "$(lines_of "$R/var/lib/rhizo/pool-pending")" "<empty>"
  check "3e. every member was unfrozen before its stop" \
        "$(call_count "$R" "thaw androidd@2.service")$(call_count "$R" "thaw androidd@3.service")" "11"
  check "3f. every member was stopped" \
        "$(call_count "$R" "stop androidd@2.service")$(call_count "$R" "stop androidd@3.service")" "11"
  check "3g. both units are inactive" \
        "$(cat "$R/.systemd/state/androidd@2.service")$(cat "$R/.systemd/state/androidd@3.service")" \
        "inactiveinactive"
  check "3h. K=0 landed" "$(cat "$R/etc/rhizo/pool.conf")" "K=0"
  check "3i. the shrunk members' env files survive the shrink" \
        "$(ls "$R/etc/rhizo/instances"/*.env | wc -l)" 3
  check "3j. ... so their ids stay burnt for the next grow" \
        "$(exists "$R/etc/rhizo/instances/2.env")$(exists "$R/etc/rhizo/instances/3.env")" "yesyes"
)

section "4. snapshot"
(
  R=$(new_root case4a); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  mkimg "$R/var/lib/rhizo/data.img" "instance-0-payload"
  printf 'release=a16\nvariant=user\n' > "$R/var/lib/rhizo/data.img.meta"
  echo active > "$R/.systemd/state/androidd.service"
  KEY12=$(sha256sum "$R/var/lib/rhizo/data.img" | cut -c1-12)

  out=$(cmd_snapshot -i 0 test-clone-src 2>"$R/stderr")
  check "4a1. the snapshot line names the content-addressed key" \
        "$out" "RHIZO_SNAPSHOT name=test-clone-src key=$KEY12 path=$R/var/lib/rhizo/templates/data-template.test-clone-src.$KEY12.img"
  check "4a2. the template is a byte copy of data.img" \
        "$(cmp -s "$R/var/lib/rhizo/data.img" "$R/var/lib/rhizo/templates/data-template.test-clone-src.$KEY12.img" && echo same || echo differs)" same
  check "4a3. a .meta sidecar carries the key" \
        "$(grep -c "\"key\": \"$KEY12\"" "$R/var/lib/rhizo/templates/data-template.test-clone-src.$KEY12.img.meta")" 1
  check "4a4. the source's release/variant carried into the sidecar" \
        "$(grep -c '"release": "a16", "variant": "user"' "$R/var/lib/rhizo/templates/data-template.test-clone-src.$KEY12.img.meta")" 1
  check "4a5. the running instance was stopped first" "$(call_count "$R" "stop androidd.service")" 1
  check "4a6. the image was synced before the copy" \
        "$(grep -c -- "-f -- $R/var/lib/rhizo/data.img" "$R/.systemd/sync.log")" 1
  check "4a7. the copy went to a .part file and was renamed into place" \
        "$(grep -c "data-template.test-clone-src.$KEY12.img.part" "$R/.systemd/cp.log")" 1
  check "4a8. the instance was restored to active" "$(call_count "$R" "start androidd.service")" 1
  check "4a9. ... and the restore came after the stop" \
        "$(call_order_ok "$R" "stop androidd.service" "start androidd.service")" yes
  check "4a10. its final state is the one it was in" \
        "$(cat "$R/.systemd/state/androidd.service")" active
  check "4a11. it was not left frozen" "$(exists "$R/.systemd/frozen/androidd.service")" no
)
(
  R=$(new_root case4b); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  mkimg "$R/var/lib/rhizo/data.img" "instance-0-payload"
  echo inactive > "$R/.systemd/state/androidd.service"

  out=$(cmd_snapshot -i 0 stopped-src 2>"$R/stderr")
  check "4b1. a stopped instance still produces a template" \
        "$(grep -c '^RHIZO_SNAPSHOT name=stopped-src' <<<"$out")" 1
  check "4b2. ... with no stop" "$(call_count "$R" "stop androidd.service")" 0
  check "4b3. ... and no start (never started just because it was inspected)" \
        "$(call_count "$R" "start androidd.service")" 0
  check "4b4. it is still inactive" "$(cat "$R/.systemd/state/androidd.service")" inactive
)
(
  R=$(new_root case4c); use_root "$R"
  configured "$R" 5
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  mkimg "$R/var/lib/rhizo/instances/5/data.img" "member-5-payload"
  echo active > "$R/.systemd/state/androidd@5.service"
  : > "$R/.systemd/frozen/androidd@5.service"
  mkdir -p "$R/var/lib/rhizo"; echo 5 > "$R/var/lib/rhizo/pool-members"

  out=$(cmd_snapshot -i 5 member-src 2>"$R/stderr")
  check "4c1. a frozen pool member snapshots" "$(grep -c '^RHIZO_SNAPSHOT name=member-src' <<<"$out")" 1
  check "4c2. it was claimed out of the pool BEFORE the stop (nothing can allocate it)" \
        "$(members_at "$R" "stop androidd@5.service")" ""
  check "4c2b. ... and before the unfreeze too" \
        "$(members_at "$R" "thaw androidd@5.service")" ""
  check "4c3. it was unfrozen so it could shut down" "$(call_count "$R" "thaw androidd@5.service")" 1
  check "4c4. ... then stopped" "$(call_count "$R" "stop androidd@5.service")" 1
  check "4c5. the unfreeze came before the stop" \
        "$(call_order_ok "$R" "thaw androidd@5.service" "stop androidd@5.service")" yes
  check "4c6. it was booted again, not merely restarted into 'running'" \
        "$(call_count "$R" "start androidd@5.service")" 1
  check "4c7. ... and re-frozen" "$(call_count "$R" "freeze androidd@5.service")" 1
  check "4c8. the freeze came after the start" \
        "$(call_order_ok "$R" "start androidd@5.service" "freeze androidd@5.service")" yes
  check "4c8b. ... and after the restarted member's own sys.boot_completed was asked" \
        "$(call_order_ok "$R" "probe androidd@5.service sys.boot_completed" "freeze androidd@5.service")" yes
  check "4c9. it is a frozen unit again" "$(exists "$R/.systemd/frozen/androidd@5.service")" yes
  check "4c10. its pool-members line is back" \
        "$(lines_of "$R/var/lib/rhizo/pool-members")" "5"
  check "4c11. the line came back only AFTER the re-freeze" \
        "$(members_at "$R" "freeze androidd@5.service")" ""
)
(
  R=$(new_root case4d); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  mkimg "$R/var/lib/rhizo/data.img" "instance-0-payload"
  echo active > "$R/.systemd/state/androidd.service"
  export RHIZO_FIX_CP_FAIL=1

  err=$( (cmd_snapshot -i 0 doomed) 2>&1 >/dev/null ); rc=$?
  check "4d0. the snapshot fails" "$rc" 1
  check "4d1. a failure after the stop is reported" \
        "$(grep -c 'cannot copy' <<<"$err")" 1
  check "4d2. the EXIT trap restored the instance anyway" \
        "$(call_count "$R" "start androidd.service")" 1
  check "4d3. ... and said so" "$(grep -c 'restoring instance 0' <<<"$err")" 1
  check "4d4. the instance is active again, not stopped forever" \
        "$(cat "$R/.systemd/state/androidd.service")" active
  check "4d5. no half-written template was installed" \
        "$(ls "$R/var/lib/rhizo/templates"/*.img 2>/dev/null | wc -l)" 0
)
(
  R=$(new_root case4e); use_root "$R"
  configured "$R" 5
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  mkimg "$R/var/lib/rhizo/instances/5/data.img" "member-5-payload"
  echo active > "$R/.systemd/state/androidd@5.service"
  : > "$R/.systemd/frozen/androidd@5.service"
  echo 5 > "$R/var/lib/rhizo/pool-members"
  export RHIZO_FIX_SYNC_FAIL=1

  err=$( (cmd_snapshot -i 5 doomed) 2>&1 >/dev/null ); rc=$?
  check "4e0. the snapshot fails" "$rc" 1
  check "4e1. the sync failure is reported" "$(grep -c 'sync -f' <<<"$err")" 1
  check "4e2. the trap re-booted and re-froze the member" \
        "$(call_count "$R" "start androidd@5.service")$(call_count "$R" "freeze androidd@5.service")" "11"
  check "4e3. its pool-members line came back" \
        "$(lines_of "$R/var/lib/rhizo/pool-members")" "5"
)
(
  R=$(new_root case4f); use_root "$R"
  configured "$R" 5
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  sleep() { SECONDS=$(( SECONDS + ${1%%.*} )); }
  mkimg "$R/var/lib/rhizo/instances/5/data.img" "member-5-payload"
  echo active > "$R/.systemd/state/androidd@5.service"
  : > "$R/.systemd/frozen/androidd@5.service"
  echo 5 > "$R/var/lib/rhizo/pool-members"
  export RHIZO_FIX_NO_BOOT="androidd@5.service"

  err=$( (cmd_snapshot -i 5 unbooted) 2>&1 >/dev/null ); rc=$?
  check "4f0. the snapshot fails when the restored member never boots" "$rc" 1
  check "4f1. ... and says the restarted member never reported sys.boot_completed=1" \
        "$(grep -c 'with no sys.boot_completed=1 within 300s' <<<"$err")" 1
  check "4f2. the unbooted member is not re-frozen" "$(call_count "$R" "freeze androidd@5.service")" 0
  check "4f3. the restore asked the restarted member for its own sys.boot_completed" \
        "$(grep -qxF 'probe androidd@5.service sys.boot_completed' "$R/.systemd/calls.log" && echo asked || echo never)" asked
  check "4f4. its pool-members line does not come back" \
        "$(lines_of "$R/var/lib/rhizo/pool-members")" "<empty>"
)

section "5. instance add --from <template>"
(
  R=$(new_root case5); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  mkimg "$R/var/lib/rhizo/data.img" "snapshot-payload-with-the-app"
  echo active > "$R/.systemd/state/androidd.service"
  cmd_snapshot -i 0 test-clone-src >"$R/snap.out" 2>/dev/null
  TPL=$(sed -n 's/.*path=//p' "$R/snap.out")

  out=$(cmd_instance_add 9 --from test-clone-src 2>"$R/stderr")
  check "5a. the add line names the id, the env and the source" \
        "$out" "RHIZO_INSTANCE_ADDED id=9 env=$R/etc/rhizo/instances/9.env data=$R/var/lib/rhizo/instances/9/data.img from=test-clone-src"
  check "5b. the clone's data.img is a byte copy of the template" \
        "$(cmp -s "$TPL" "$R/var/lib/rhizo/instances/9/data.img" && echo same || echo differs)" same
  tpl_ino=$(stat -c %i "$TPL"); clone_ino=$(stat -c %i "$R/var/lib/rhizo/instances/9/data.img")
  check "5c. never shared with the template -- two distinct inodes" \
        "$( [[ "$tpl_ino" == "$clone_ino" ]] && echo shared || echo distinct)" distinct
  check "5d. the env file names the id" "$(cat "$R/etc/rhizo/instances/9.env")" "RHIZO_SANDBOX_ID=9"
  check "5e. the template's .meta traveled with the image" \
        "$(exists "$R/var/lib/rhizo/instances/9/data.img.meta")" yes
  check "5f. a second add on the same id is refused" \
        "$( (cmd_instance_add 9 --from test-clone-src) 2>&1 >/dev/null | grep -c 'already configured')" 1
)
(
  R=$(new_root case5b); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  err=$( (cmd_instance_add 9 --from nosuchtemplate) 2>&1 >/dev/null )
  check "5g. a missing template is refused by name" \
        "$(grep -c "no snapshot template 'nosuchtemplate'" <<<"$err")" 1
  check "5h. no env file is left behind" "$(exists "$R/etc/rhizo/instances/9.env")" no
  check "5i. no data.img is left behind" "$(exists "$R/var/lib/rhizo/instances/9/data.img")" no
  check "5j. and no instance directory either (the lookup precedes the mkdir)" \
        "$(exists "$R/var/lib/rhizo/instances/9")" no
)

section "6. instance remove"
(
  R=$(new_root case6); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  configured "$R" 9
  mkimg "$R/var/lib/rhizo/instances/9/data.img" "clone-payload"
  printf 'release=a16\n' > "$R/var/lib/rhizo/instances/9/data.img.meta"
  mkdir -p "$R/var/lib/rhizo/instances/9/vendor/bin/hw" "$R/var/lib/rhizo/instances/9/apex_override"
  : > "$R/var/lib/rhizo/instances/9/vendor/bin/hw/rhizo.keymint"
  : > "$R/var/lib/rhizo/instances/9/apex_override/com.android.tethering.apex"
  echo active > "$R/.systemd/state/androidd@9.service"

  out=$(cmd_instance_remove 9 2>"$R/stderr")
  check "6a. remove reports all three halves" "$out" \
        "RHIZO_INSTANCE_REMOVED id=9 env=removed data=removed trees=removed"
  check "6b. the unit was stopped" "$(call_count "$R" "stop androidd@9.service")" 1
  check "6c. the env file is gone" "$(exists "$R/etc/rhizo/instances/9.env")" no
  check "6d. data.img is gone" "$(exists "$R/var/lib/rhizo/instances/9/data.img")" no
  check "6e. its .meta is gone" "$(exists "$R/var/lib/rhizo/instances/9/data.img.meta")" no
  check "6f. the instance's own vendor tree is gone" \
        "$(exists "$R/var/lib/rhizo/instances/9/vendor")" no
  check "6g. the instance's own apex_override tree is gone" \
        "$(exists "$R/var/lib/rhizo/instances/9/apex_override")" no
  check "6h. the instance directory is gone" "$(exists "$R/var/lib/rhizo/instances/9")" no
)
(
  R=$(new_root case6b); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  configured "$R" 9
  mkimg "$R/var/lib/rhizo/instances/9/data.img" "clone-payload"
  mkdir -p "$R/var/lib/rhizo/instances/9/vendor" "$R/var/lib/rhizo/instances/9/apex_override"
  echo active > "$R/.systemd/state/androidd@9.service"

  out=$(cmd_instance_remove 9 --keep-data 2>"$R/stderr")
  check "6i. --keep-data says so" "$out" \
        "RHIZO_INSTANCE_REMOVED id=9 env=removed data=kept trees=removed"
  check "6j. the image survives" "$(exists "$R/var/lib/rhizo/instances/9/data.img")" yes
  check "6j2. the staged trees do not -- they restage from the GSI at launch" \
        "$(exists "$R/var/lib/rhizo/instances/9/vendor")$(exists "$R/var/lib/rhizo/instances/9/apex_override")" "nono"
  check "6k. the env file does not" "$(exists "$R/etc/rhizo/instances/9.env")" no
  check "6l. and the id is free again" "$(pool_next_free_id)" 1
)
(
  R=$(new_root case6c); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  configured "$R" 9
  mkimg "$R/var/lib/rhizo/instances/9/data.img" "clone-payload"
  echo active > "$R/.systemd/state/androidd@9.service"
  echo 9 > "$R/var/lib/rhizo/pool-members"
  export RHIZO_FIX_FAIL_STOP="androidd@9.service"

  err=$( (cmd_instance_remove 9) 2>&1 >/dev/null ); rc=$?
  check "6m0. a failed stop refuses to remove the instance" "$rc" 1
  check "6m. ... and says so" \
        "$(grep -c 'not removed' <<<"$err")" 1
  check "6n. the env file survives the refusal" "$(exists "$R/etc/rhizo/instances/9.env")" yes
  check "6n2. so does its data.img" "$(exists "$R/var/lib/rhizo/instances/9/data.img")" yes
  check "6o. but its pool-members line was already dropped" \
        "$(lines_of "$R/var/lib/rhizo/pool-members")" "<empty>"
)
(
  R=$(new_root case6d); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  mkimg "$R/var/lib/rhizo/data.img" "instance-0-payload"
  echo inactive > "$R/.systemd/state/androidd.service"
  out=$(do_instance_remove 0 0 2>"$R/stderr")
  check "6p. removing id 0 reports no tree of its own" "$out" \
        "RHIZO_INSTANCE_REMOVED id=0 env=absent data=removed trees=absent"
  check "6q. its data.img went" "$(exists "$R/var/lib/rhizo/data.img")" no
  check "6r. and STATE_DIR itself did not" "$(exists "$R/var/lib/rhizo")" yes
)

section "7. the profile refusal"
(
  R=$(new_root case7); use_root "$R"
  printf '[rhizo]\nprofile = desktop\n' > "$R/etc/rhizo/policy.conf"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"

  err=$( (cmd_instance_add 5) 2>&1 >/dev/null )
  check "7a. instance add above 0 is refused under the desktop profile" \
        "$(grep -c 'instance add 5 refused: rhizo.profile is desktop, not server' <<<"$err")" 1
  check "7b. the refusal names the units that make it unsafe" \
        "$(grep -c 'rhizo-app-events.service' <<<"$err")" 1
  check "7c. no env file was written" "$(exists "$R/etc/rhizo/instances/5.env")" no
  check "7d. instance add 0 is never refused (it is the default instance)" \
        "$( (check_server_profile_for_instance 0) >/dev/null 2>&1 && echo allowed || echo refused)" allowed
)
(
  R=$(new_root case7b); use_root "$R"
  printf '[rhizo]\nprofile = desktop\n' > "$R/etc/rhizo/policy.conf"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"

  out=$(cmd_pool_set 1 2>"$R/stderr")
  check "7e. the instance pool refuses to add an instance under the desktop profile" \
        "$(if [[ -e "$R/etc/rhizo/instances/1.env" ]]; then echo added; else echo refused; fi)" refused
  check "7e2. ... in the same words 'instance add' refuses in" \
        "$(grep -c 'instance add 1 refused: rhizo.profile is desktop, not server' "$R/stderr")" 1
  check "7e3. and no member was started" \
        "$(call_count "$R" "start androidd@1.service")" 0
  check "7e4. and pool set put no sentinel of its own on stdout" "$out" ""
)
(
  R=$(new_root case7c); use_root "$R"
  printf 'this is not an ini file\n' > "$R/etc/rhizo/policy.conf"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  err=$( (cmd_instance_add 5) 2>&1 >/dev/null )
  check "7f. an unparseable policy.conf denies rather than defaults" \
        "$(grep -c 'not server' <<<"$err")" 1
)
(
  R=$(new_root case7d); use_root "$R"
  printf '[rhizo]\nprofile = desktop\n' > "$R/etc/rhizo/policy.conf"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  configured "$R" 1
  echo active > "$R/.systemd/state/androidd@1.service"
  printf 'K=0\n' > "$R/etc/rhizo/pool.conf"
  out=$( (cmd_instance_release 1) 2>/dev/null ); rc=$?
  check "7g. release still works on a desktop host -- it shrinks, it never adds" \
        "$rc$out" "0RHIZO_RELEASED id=1"
)

section "8. the test-only root bypass"
(
  R=$(new_root case8); use_root "$R"
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  check "8a. with a fixture ETC_RHIZO and STATE_DIR, a non-root caller is let through" \
        "$( (( EUID == 0 )) && echo skipped-running-as-root || { cli_root_ok && echo allowed || echo refused; })" \
        "$( (( EUID == 0 )) && echo skipped-running-as-root || echo allowed)"
  # shellcheck disable=SC2034
  ETC_RHIZO=/etc/rhizo
  check "8b. ... and refused again the moment ETC_RHIZO is the real one" \
        "$( (( EUID == 0 )) && echo skipped-running-as-root || { cli_root_ok && echo allowed || echo refused; })" \
        "$( (( EUID == 0 )) && echo skipped-running-as-root || echo refused)"
  # shellcheck disable=SC2034
  ETC_RHIZO="$R/etc/rhizo"; STATE_DIR=/var/lib/rhizo
  check "8c. ... or STATE_DIR is" \
        "$( (( EUID == 0 )) && echo skipped-running-as-root || { cli_root_ok && echo allowed || echo refused; })" \
        "$( (( EUID == 0 )) && echo skipped-running-as-root || echo refused)"
  # shellcheck disable=SC2034
  STATE_DIR="$R/var/lib/rhizo"; unset RHIZO_CLI_TEST_NO_ROOT
  check "8d. ... or the variable itself is unset" \
        "$( (( EUID == 0 )) && echo skipped-running-as-root || { cli_root_ok && echo allowed || echo refused; })" \
        "$( (( EUID == 0 )) && echo skipped-running-as-root || echo refused)"
)

echo
echo "=== summary ==="
RUN=$(grep -c . "$RUN_LOG")
FAILED=$(grep -c . "$FAIL_LOG")
echo "checks run: $RUN   failed: $FAILED"
if (( FAILED )); then
  echo "failed checks:"
  sed 's/^/  - /' "$FAIL_LOG"
  exit 1
fi
echo "all checks passed"
