#!/bin/bash
# check nested sway restarts raise the ssh wait
# shellcheck disable=SC2034
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWAY_SRC="$HERE/../vm/start/start-sway.sh"
INSTALL_SRC="$HERE/../system/install/install.sh"
[[ -r "$SWAY_SRC" ]] || { echo "FAIL: cannot read $SWAY_SRC"; exit 1; }
[[ -r "$INSTALL_SRC" ]] || { echo "FAIL: cannot read $INSTALL_SRC"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=()
# record a failure
fail() { FAILURES+=("$1"); }

# print the SSH_WAIT= line to the wait_for_ssh line
extract_ssh_wait_snippet() {
  local f="$1" start end
  start=$(grep -n '^SSH_WAIT=' "$f" | head -1 | cut -d: -f1)
  [[ -n "$start" ]] || return 1
  end=$(awk -v s="$start" 'NR>s && /wait_for_ssh/ {print NR; exit}' "$f")
  [[ -n "$end" ]] || return 1
  sed -n "${start},${end}p" "$f"
}

# run the snippet with wait_for_ssh stubbed
run_ssh_wait_snippet() {
  local f="$1" envset="$2" out="$3" body
  body="$(extract_ssh_wait_snippet "$f")" || { echo "MISSING SSH_WAIT snippet in $f" > "$out"; return 1; }
  (
    set -uo pipefail
    wait_for_ssh() { echo "DEADLINE=$1"; return 0; }
    log() { :; }
    eval "$envset"
    eval "$body"
  ) > "$out" 2>&1
}

# check that the unset override leaves the 20 second wait
check_default_is_20() {
  local out="$WORK/default.out"
  run_ssh_wait_snippet "$SWAY_SRC" "unset RHIZO_SWAY_SSH_WAIT" "$out"
  grep -q '^DEADLINE=20$' "$out" \
    || fail "start-sway.sh's un-overridden wait changed away from the 20s re-confirmation default (got: $(cat "$out"))"
}

# check that the override raises the wait
check_override_wins() {
  local out="$WORK/override.out"
  run_ssh_wait_snippet "$SWAY_SRC" "RHIZO_SWAY_SSH_WAIT=300" "$out"
  grep -q '^DEADLINE=300$' "$out" \
    || fail "start-sway.sh ignores RHIZO_SWAY_SSH_WAIT (got: $(cat "$out"))"
}

# print the SKIP_BOOT block from install.sh
extract_boot_step() {
  local f="$1" start end
  start=$(grep -n '^if (( SKIP_BOOT == 0 )); then$' "$f" | head -1 | cut -d: -f1)
  [[ -n "$start" ]] || return 1
  end=$(awk -v s="$start" 'NR>s && /^fi$/ {print NR; exit}' "$f")
  [[ -n "$end" ]] || return 1
  sed -n "${start},${end}p" "$f"
}

# write stub start-sway.sh, sync.sh and redeploy.sh
write_stub_bin() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/start-sway.sh" <<'EOF'
#!/bin/bash
echo "START_SWAY_SSH_WAIT=${RHIZO_SWAY_SSH_WAIT:-UNSET}"
EOF
  printf '#!/bin/bash\ntrue\n' > "$WORK/bin/sync.sh"
  printf '#!/bin/bash\ntrue\n' > "$WORK/bin/redeploy.sh"
  chmod +x "$WORK/bin/start-sway.sh" "$WORK/bin/sync.sh" "$WORK/bin/redeploy.sh"
  mkdir -p "$WORK/ev"
}

# run the boot step with stubbed commands
run_boot_step() {
  local f="$1" skip="$2" out="$3" body
  body="$(extract_boot_step "$f")" || { echo "MISSING boot step in $f" > "$out"; return 1; }
  rm -rf "$WORK/ev"; mkdir -p "$WORK/ev"
  (
    set -uo pipefail
    cd "$WORK/bin" || exit 1
    step() { :; }
    bail() { echo "BAIL: $1"; exit 1; }
    test_boot() { return 0; }
    test_record_verdict() { :; }
    test_ensure_sway() { echo "NESTED_SSH_WAIT=${RHIZO_SWAY_SSH_WAIT:-UNSET}"; }
    desk_session_up() { ./start-sway.sh "$@"; }
    tail() { :; }
    EV="$WORK/ev" VERDICT_PARAMS="" RHIZO_RELEASE=""
    SKIP_BOOT=$skip
    eval "$body"
  ) > "$out" 2>&1
  [[ -f "$WORK/ev/install-sway.log" ]] && cat "$WORK/ev/install-sway.log" >> "$out"
}

# check that a direct boot leaves the ssh wait unset
check_direct_boot_unaffected() {
  local out="$WORK/direct.out"
  run_boot_step "$INSTALL_SRC" 0 "$out"
  grep -q '^START_SWAY_SSH_WAIT=UNSET$' "$out" \
    || fail "the direct post-test_boot start-sway.sh call is no longer left at the 20s re-confirmation default (got: $(cat "$out"))"
}

# check that a nested boot raises the ssh wait past 20 seconds
check_nested_boot_raises() {
  local out="$WORK/nested.out"
  run_boot_step "$INSTALL_SRC" 1 "$out"
  grep -q '^NESTED_SSH_WAIT=[0-9][0-9][0-9]*$' "$out" && ! grep -q '^NESTED_SSH_WAIT=20$' "$out" \
    || fail "the SKIP_BOOT=1 (nested) branch does not raise the ssh wait past 20s before test_ensure_sway (got: $(cat "$out"))"
}

# run the four ssh wait checks
run_all_checks() {
  FAILURES=()
  SWAY_SRC="$1" INSTALL_SRC="$2"
  write_stub_bin
  check_default_is_20
  check_override_wins
  check_direct_boot_unaffected
  check_nested_boot_raises
}

if (( ! SELFTEST )); then
  run_all_checks "$SWAY_SRC" "$INSTALL_SRC"
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}"
    exit 1
  fi
  echo "ok: start-sway.sh keeps its 20s re-confirmation default, and install.sh's nested restart branch alone raises it"
  exit 0
fi

# hardcode 20 in the wait_for_ssh call
inject_bare_wait_in_startsway() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('SSH_WAIT="${RHIZO_SWAY_SSH_WAIT:-20}"\n'
       'wait_for_ssh "$SSH_WAIT" || { log "FAIL: VM not reachable"; exit 1; }\n')
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: SSH_WAIT snippet not found in start-sway.sh")
s = s.replace(old, 'wait_for_ssh 20 || { log "FAIL: VM not reachable"; exit 1; }\n', 1)
open(p, "w").write(s)
PY
}

# remove the override from the nested test_ensure_sway call
inject_no_override_in_test_install() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'RHIZO_SWAY_SSH_WAIT=300 test_ensure_sway "$EV/chained-install-sway.log" "$EV/chained-redeploy.log"\n'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: nested test_ensure_sway call not found in install.sh")
s = s.replace(old, 'test_ensure_sway "$EV/chained-install-sway.log" "$EV/chained-redeploy.log"\n', 1)
open(p, "w").write(s)
PY
}

# add the override to desk_session_up
inject_blanket_override_in_test_install() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('  desk_session_up >"$EV/install-sway.log" 2>&1 '
       '|| bail "the desktop session did not start (see $EV/install-sway.log)"\n')
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: direct desk_session_up call not found in install.sh")
s = s.replace(old, "  RHIZO_SWAY_SSH_WAIT=300 " + old.lstrip(), 1)
open(p, "w").write(s)
PY
}

# inject a defect and run the checks
selftest_case() {
  local name="$1" which="$2" inject="$3" swaycopy installcopy
  swaycopy="$WORK/defect-$name-sway.sh"; installcopy="$WORK/defect-$name-install.sh"
  cp "$SWAY_SRC_REAL" "$swaycopy"
  cp "$INSTALL_SRC_REAL" "$installcopy"
  if [[ "$which" == sway ]]; then "$inject" "$swaycopy"; else "$inject" "$installcopy"; fi \
    || { echo "SELFTEST SETUP FAIL ($name)"; exit 1; }
  bash -n "$swaycopy" || { echo "SELFTEST SETUP FAIL ($name): mutated start-sway.sh copy is not valid bash"; exit 1; }
  bash -n "$installcopy" || { echo "SELFTEST SETUP FAIL ($name): mutated install.sh copy is not valid bash"; exit 1; }
  run_all_checks "$swaycopy" "$installcopy"
  if (( ${#FAILURES[@]} == 0 )); then
    echo "SELFTEST FAIL ($name): the checker passed a copy with the $name defect reintroduced"
    exit 1
  fi
  echo "selftest ok ($name): detected -- ${FAILURES[0]}"
}

SWAY_SRC_REAL="$SWAY_SRC" INSTALL_SRC_REAL="$INSTALL_SRC"
selftest_case bare-20-wait sway inject_bare_wait_in_startsway
selftest_case nested-no-override install inject_no_override_in_test_install
selftest_case blanket-override install inject_blanket_override_in_test_install

run_all_checks "$SWAY_SRC_REAL" "$INSTALL_SRC_REAL"
if (( ${#FAILURES[@]} > 0 )); then
  printf 'SELFTEST FAIL (clean): the real files failed their own checker: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "selftest ok (clean): the real start-sway.sh and install.sh pass every assertion"
exit 0
