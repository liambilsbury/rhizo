#!/bin/bash
# check boot refusal and ssh hang labels differ
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
W_GCBE="test_collect_boot"
W_GCBE="${W_GCBE}_evidence"
W_CE="collect"
W_CE="${W_CE}_evidence"
W_CBESH="collect-boot-evidence"
W_CBESH="${W_CBESH}.sh"
COMMON="$HERE/../vm/common.sh"
TEST_LIB="$HERE/../system/lib/lib.sh"
REDEPLOY="$HERE/../vm/redeploy.sh"
COLLECT="$HERE/../vm/boot/$W_CBESH"
HOOKS="$HERE/../vm/rig/hooks.sh"
REAL_RSV="$HERE/../vm/run-vm.sh"
RSV_PIDFILE_WRITE_RE='^(\[\[ "\$PRINT_ARGV" == 1 \]\] \|\| )?echo \$\$ > "vm-boot\$\{SUFFIX\}\.pid"$'
for f in "$COMMON" "$TEST_LIB" "$REDEPLOY" "$COLLECT" "$HOOKS" "$REAL_RSV"; do
  [[ -r "$f" ]] || { echo "FAIL: cannot read $f"; exit 1; }
done

WORK="$(mktemp -d)"
# kill processes with a working directory under <dir>
reap_fixture_pids() {
  local base="${1:-$WORK}" p target
  for p in /proc/[0-9]*; do
    [[ -e "$p/cwd" ]] || continue
    target=$(readlink -f "$p/cwd" 2>/dev/null)
    [[ -n "$target" && "$target" == "$base"* ]] && kill -9 "${p#/proc/}" 2>/dev/null
  done
}
trap 'reap_fixture_pids; rm -rf "$WORK"' EXIT

FAILURES=()
# record a failure and print it
fail_check() { FAILURES+=("$1"); echo "FAIL: $1"; }

# print the bash block for <start_regex>
extract_block() {
  local f="$1" pattern="$2"
  shift 2
  python3 - "$f" "$pattern" "$@" <<'PY'
import re, sys
path, pattern = sys.argv[1], sys.argv[2]
stop_patterns = sys.argv[3:]
lines = open(path).read().splitlines()
rx = re.compile(pattern)
start = next((i for i, l in enumerate(lines) if rx.search(l)), None)
if start is None:
    sys.exit(1)
open_kw = re.compile(r'^(if|for|while|until|case)\b')
close_kw = re.compile(r'^(fi|done|esac)$')
depth = 0
seen_open = False
end = None
for i in range(start, len(lines)):
    stripped = lines[i].strip()
    if open_kw.match(stripped):
        depth += 1
        seen_open = True
    elif close_kw.match(stripped):
        depth -= 1
    if seen_open and depth == 0:
        end = i
        break
if end is None:
    sys.exit(1)
print("\n".join(lines[start:end + 1]))
PY
}

# print a function's body from a file
extract_func() {
  local f="$1" name="$2" start end
  start=$(grep -n "^${name}() {" "$f" | tail -1 | cut -d: -f1)
  [[ -n "$start" ]] || return 1
  end=$(awk -v s="$start" 'NR > s && /^}/ { print NR; exit }' "$f")
  [[ -n "$end" ]] || return 1
  sed -n "${start},${end}p" "$f"
}

# print the lines between two regex matches
extract_lines() {
  local f="$1" start_re="$2" stop_re="${3:-^$}"
  python3 - "$f" "$start_re" "$stop_re" <<'PY'
import re, sys
path, start_re, stop_re = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
srx = re.compile(start_re); erx = re.compile(stop_re)
start = next((i for i, l in enumerate(lines) if srx.search(l)), None)
if start is None:
    sys.exit(1)
end = next((i for i in range(start + 1, len(lines)) if erx.search(lines[i])), None)
if end is None:
    sys.exit(1)
print("\n".join(lines[start:end]))
PY
}

# print RHIZO_PORT_OFFSET for a free port
free_port_offset() {
  local port
  port=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
  echo $((port - 2222))
}

# create a fixture tree under $WORK/<name>
new_fixture() {
  local root="$WORK/$1"
  reap_fixture_pids "$root"
  rm -rf "$root"
  mkdir -p "$root/test/vm/boot" "$root/test/vm/image" "$root/test/vm/rig" "$root/test/system/lib" "$root/src/androidd/host" "$root/var" "$root/bin"
  cp "$COMMON" "$root/test/vm/common.sh"
  cp "$TEST_LIB" "$root/test/system/lib/lib.sh"
  cp "$COLLECT" "$root/test/vm/boot/$W_CBESH"
  chmod +x "$root/test/vm/boot/$W_CBESH"
  cp "$HOOKS" "$root/test/vm/rig/hooks.sh"
  printf '%s\n' 'rig_boot_started() { echo "STARTED $1" >> "$RHIZO_FIXTURE_BOOT_RECORD"; }' \
    'rig_boot_outcome() { echo "OUTCOME $1 $2" >> "$RHIZO_FIXTURE_BOOT_RECORD"; }' > "$root/record-hook.sh"
  : > "$root/src/androidd/host/parse-display-list.sh"
  : > "$root/test/vm/image/release-map.sh"
  : > "$root/var/vm_key"
  chmod 600 "$root/var/vm_key"
  printf '#!/bin/bash\nexit 0\n' > "$root/test/vm/boot/explain-boot.sh"
  chmod +x "$root/test/vm/boot/explain-boot.sh"
  echo "$root"
}

# write a stub run-vm.sh in the fixture tree
write_run_vm() {
  local root="$1" mode="$2" delay="${3:-0}"
  cat > "$root/test/vm/run-vm.sh" <<EOF
#!/bin/bash
set -euo pipefail
cd "\$(dirname "\$0")/../../var"
echo \$\$ > vm-boot.pid
EOF
  case "$mode" in
    refuse)
      cat >> "$root/test/vm/run-vm.sh" <<'EOF'
echo "run-vm.sh: refusing to boot vm 0 at the boot guard" >&2
exit 1
EOF
      ;;
    refuse-late)
      cat >> "$root/test/vm/run-vm.sh" <<EOF
sleep $delay
echo "run-vm.sh: refusing to boot vm 0 at the boot guard" >&2
exit 1
EOF
      ;;
    refuse-silent)
      cat >> "$root/test/vm/run-vm.sh" <<'EOF'
exit 1
EOF
      ;;
    hang|succeed-late)
      cat >> "$root/test/vm/run-vm.sh" <<'EOF'
sleep 300
EOF
      ;;
    *) echo "write_run_vm: unknown mode $mode" >&2; return 1 ;;
  esac
  chmod +x "$root/test/vm/run-vm.sh"
}

# write a stub ssh into <root>/bin
write_ssh() {
  local root="$1" mode="$2" delay="${3:-0}"
  case "$mode" in
    refuse)
      cat > "$root/bin/ssh" <<'EOF'
#!/bin/bash
exit 255
EOF
      ;;
    reachable)
      cat > "$root/bin/ssh" <<'EOF'
#!/bin/bash
case "$*" in
  *"echo ok"*) exit 255 ;;
  *is-system-running*) echo running; exit 0 ;;
  *) echo ok; exit 0 ;;
esac
EOF
      ;;
    succeed-late)
      cat > "$root/bin/ssh" <<EOF
#!/bin/bash
now=\$(date +%s)
start_file="\$(dirname "\$0")/../ssh-start"
[[ -f "\$start_file" ]] || echo "\$now" > "\$start_file"
start=\$(cat "\$start_file")
if (( now - start >= $delay )); then
  echo ok
  exit 0
fi
exit 255
EOF
      ;;
    *) echo "write_ssh: unknown mode $mode" >&2; return 1 ;;
  esac
  chmod +x "$root/bin/ssh"
  cat > "$root/bin/scp" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$root/bin/scp"
}

# run test_boot in a subshell on a fixture
run_test_boot() {
  local root="$1" ssh_wait="${2:-5}"
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"
    mkdir -p "$XDG_RUNTIME_DIR"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    source ./test/system/lib/lib.sh
    body=$(extract_func ./test/system/lib/lib.sh test_boot) || exit 98
    body="${body/wait_for_ssh 300/wait_for_ssh $ssh_wait}"
    eval "$body"
    FAILED=0 EV=""
    test_require_staged() { return 0; }
    eval "$W_GCBE() { echo \"LABEL:\$1\" >> \"$root/label.log\"; TEST_BOOT_FAULT=\"\$1\"; }"
    test_boot --no-preflight > "$root/test.out" 2>&1
    echo $? > "$root/test.rc"
  )
}

# print the last label a run logged
label_of() { grep -o '^LABEL:.*' "$1/label.log" 2>/dev/null | tail -1 | cut -d: -f2-; }

# check test_boot labels a pre-boot refusal
check_precheck_refusal_labeled() {
  local root; root=$(new_fixture precheck-refusal)
  write_run_vm "$root" refuse
  write_ssh "$root" refuse
  run_test_boot "$root"
  local rc; rc=$(cat "$root/test.rc")
  [[ "$rc" == "1" ]] || { fail_check "precheck refusal: test_boot returned '$rc', not 1: $(cat "$root/test.out")"; return; }
  local label; label=$(label_of "$root")
  [[ "$label" == "test-vm-refused" ]] \
    || fail_check "precheck refusal: test_boot filed '$label', not test-vm-refused: $(cat "$root/test.out")"
}

# check test_boot labels a silent refusal
check_silent_refusal_still_labeled() {
  local root; root=$(new_fixture silent-refusal)
  write_run_vm "$root" refuse-silent
  write_ssh "$root" refuse
  run_test_boot "$root"
  local rc; rc=$(cat "$root/test.rc")
  [[ "$rc" == "1" ]] || { fail_check "silent refusal: test_boot returned '$rc', not 1: $(cat "$root/test.out")"; return; }
  local label; label=$(label_of "$root")
  [[ "$label" == "test-vm-refused" ]] \
    || fail_check "silent refusal: test_boot filed '$label', not test-vm-refused, on a launcher that printed nothing: $(cat "$root/test.out")"
}

# check a late refusal gets the refusal label
check_late_refusal_still_labeled() {
  local root; root=$(new_fixture late-refusal)
  write_run_vm "$root" refuse-late 5
  write_ssh "$root" refuse
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    kill_vm
    boot_vm
    if ! wait_for_ssh 12; then
      if [[ -n "${RHIZO_BOOT_REFUSAL:-}" ]]; then
        echo "LABEL:test-vm-refused" >> "$root/label.log"
      else
        echo "LABEL:test-vm-never-came-up" >> "$root/label.log"
      fi
    fi
  ) > "$root/test.out" 2>&1
  local label; label=$(label_of "$root")
  [[ "$label" == "test-vm-refused" ]] \
    || fail_check "late refusal (8s, well past wait_for_ssh's first look): got '$label', not test-vm-refused: $(cat "$root/test.out")"
}

# check the label for a hung guest vm
check_real_hang_keeps_old_label() {
  local root; root=$(new_fixture real-hang)
  write_run_vm "$root" hang
  write_ssh "$root" refuse
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    source ./test/system/lib/lib.sh
    test_require_staged() { return 0; }
    eval "$W_GCBE() { echo \"LABEL:\$1\" >> \"$root/label.log\"; TEST_BOOT_FAULT=\"\$1\"; }"
    kill_vm
    boot_vm
    wait_for_boot_slot 6 > "$root/slot.out" 2>&1
    if ! wait_for_ssh 6; then
      if [[ -n "${RHIZO_BOOT_REFUSAL:-}" ]]; then
        "$W_GCBE" "test-vm-refused"
      else
        "$W_GCBE" "test-vm-never-came-up"
      fi
    fi
    kill_vm >/dev/null 2>&1
  ) > "$root/test.out" 2>&1
  local label; label=$(label_of "$root")
  [[ "$label" == "test-vm-never-came-up" ]] \
    || fail_check "real hang: got '$label', wanted test-vm-never-came-up (a live launcher must never be read as refused): $(cat "$root/test.out")"
}

# check a slow boot leaves RHIZO_BOOT_REFUSAL empty
check_slow_success_not_refused() {
  local root; root=$(new_fixture slow-success)
  write_run_vm "$root" succeed-late
  write_ssh "$root" succeed-late 7
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    kill_vm
    boot_vm
    wait_for_ssh 12
    echo "SSH_RC=$?" > "$root/ssh.rc"
    echo "REFUSAL=[${RHIZO_BOOT_REFUSAL:-}]" >> "$root/ssh.rc"
    kill_vm >/dev/null 2>&1
  ) > "$root/test.out" 2>&1
  grep -q '^SSH_RC=0$' "$root/ssh.rc" 2>/dev/null \
    || fail_check "slow success: ssh never succeeded within budget: $(cat "$root/ssh.rc" 2>/dev/null) $(cat "$root/test.out")"
  grep -q '^REFUSAL=\[\]$' "$root/ssh.rc" 2>/dev/null \
    || fail_check "slow success: RHIZO_BOOT_REFUSAL was set on a boot that actually came up: $(cat "$root/ssh.rc" 2>/dev/null)"
}

# check redeploy.sh labels a refusal ssh-refused
check_redeploy_refused_labeled() {
  local root; root=$(new_fixture redeploy-refusal)
  write_run_vm "$root" refuse
  write_ssh "$root" refuse
  local block; block=$(extract_block "$REDEPLOY" '^if \[\[ "\$SKIP_KILL" == 0 \]\]; then$')
  [[ -n "$block" ]] || { fail_check "redeploy refusal: could not extract the kill/boot/wait_for_ssh block from $REDEPLOY"; return; }
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX="" SKIP_KILL=0
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    explain_dead_boot() { :; }
    eval "$W_CE() { echo \"LABEL:\$1\" >> \"$root/label.log\"; }"
    log() { echo "$*" >&2; }
    eval "$block"
  ) > "$root/redeploy.out" 2>&1
  local label; label=$(label_of "$root")
  [[ "$label" == "ssh-refused" ]] \
    || fail_check "redeploy refusal: filed '$label', not ssh-refused: $(cat "$root/redeploy.out")"
}

# write an earlier boot's record for vm 0
seed_log() {
  printf 'SEEDED 0 an earlier boot\n' > "$1"
}

# print the boot records a run wrote
own_records() { grep -v '^SEEDED ' "$1" 2>/dev/null; }

# print the count of started boots with no outcome
unrecorded_boots() { awk '/^STARTED / { p++ } /^OUTCOME / { if (p > 0) p-- } END { print p + 0 }' "$1"; }

# check a refusal leaves the test log unchanged
check_test_log_untouched_on_refusal() {
  local root; root=$(new_fixture test-log)
  write_run_vm "$root" refuse
  write_ssh "$root" reachable
  local log_file="$root/log.tsv"
  seed_log "$log_file"
  local before after
  before=$(sha256sum "$log_file" | cut -d' ' -f1)
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    export RHIZO_VM_HOOK="$root/record-hook.sh" RHIZO_FIXTURE_BOOT_RECORD="$log_file"
    export EV="$root/ev"; mkdir -p "$EV"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    source ./test/system/lib/lib.sh
    body=$(extract_func ./test/system/lib/lib.sh test_boot) || exit 98
    body="${body/wait_for_ssh 300/wait_for_ssh 5}"
    eval "$body"
    FAILED=0 TEST_NAME=boot-smoke
    test_require_staged() { return 0; }
    rig_verdict_write() { :; }
    test_boot --no-preflight
    test_record_verdict FAILED
  ) > "$root/test.out" 2>&1
  after=$(sha256sum "$log_file" | cut -d' ' -f1)
  [[ "$before" == "$after" ]] \
    || fail_check "system test log safety: the seeded record changed on a refused test_boot ($before -> $after): $(cat "$root/test.out")"
}

# check a refusal leaves the redeploy log unchanged
check_redeploy_log_untouched_on_refusal() {
  local root; root=$(new_fixture redeploy-log)
  write_run_vm "$root" refuse
  write_ssh "$root" reachable
  local log_file="$root/log.tsv"
  seed_log "$log_file"
  local before after
  before=$(sha256sum "$log_file" | cut -d' ' -f1)
  local block; block=$(extract_block "$REDEPLOY" '^if \[\[ "\$SKIP_KILL" == 0 \]\]; then$')
  [[ -n "$block" ]] || { fail_check "redeploy log safety: could not extract the block from $REDEPLOY"; return; }
  block="${block/wait_for_ssh 180/wait_for_ssh 5}"
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX="" SKIP_KILL=0
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    export RHIZO_VM_HOOK="$root/record-hook.sh" RHIZO_FIXTURE_BOOT_RECORD="$log_file"
    export BOOT_EVIDENCE_DIR="$root/boot-failure"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    explain_dead_boot() { :; }
    eval "$W_CE() { ./test/vm/boot/$W_CBESH \"\$BOOT_EVIDENCE_DIR\" \"\$1\"; }"
    log() { echo "$*" >&2; }
    eval "$block"
  ) > "$root/redeploy.out" 2>&1
  after=$(sha256sum "$log_file" | cut -d' ' -f1)
  [[ "$before" == "$after" ]] \
    || fail_check "redeploy log safety: the seeded record changed on a refused redeploy ($before -> $after): $(cat "$root/redeploy.out")"
}

# check a refusal leaves VM_PIDFILE unchanged
check_shared_pidfile_untouched_on_refusal() {
  local root; root=$(new_fixture shared-pidfile-safety)
  write_run_vm "$root" refuse
  write_ssh "$root" refuse
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    bash -c 'exec -a run-vm.sh sleep 300' &
    foreign_pid=$!
    sleep 0.2
    echo "$foreign_pid" > "$VM_PIDFILE"
    sha256sum "$VM_PIDFILE" | cut -d' ' -f1 > "$root/pidfile-before.sha"
    boot_vm
    wait_for_ssh 10
    echo "SSH_RC=$?" > "$root/result"
    echo "REFUSAL=[${RHIZO_BOOT_REFUSAL:-}]" >> "$root/result"
    sha256sum "$VM_PIDFILE" | cut -d' ' -f1 > "$root/pidfile-after.sha"
    kill "$foreign_pid" 2>/dev/null
  ) > "$root/test.out" 2>&1
  grep -q '^REFUSAL=\[.\+\]$' "$root/result" 2>/dev/null \
    || fail_check "shared-pidfile safety: the refusal was never detected at all (no RHIZO_BOOT_REFUSAL): $(cat "$root/result" 2>/dev/null) $(cat "$root/test.out")"
  local before after
  before=$(cat "$root/pidfile-before.sha" 2>/dev/null)
  after=$(cat "$root/pidfile-after.sha" 2>/dev/null)
  [[ -n "$before" && "$before" == "$after" ]] \
    || fail_check "shared-pidfile safety: VM_PIDFILE changed on a refused launch ($before -> $after): $(cat "$root/test.out")"
}

# check TEST_BOOT_NO_ROW resets between two test_boot calls
check_no_row_reset_across_two_boots() {
  local root; root=$(new_fixture two-boot)
  local log_file="$root/log.tsv"
  seed_log "$log_file"
  local state="$root/call.state"
  echo 1 > "$state"
  cat > "$root/test/vm/run-vm.sh" <<EOF
#!/bin/bash
cd "\$(dirname "\$0")/../../var"
call=\$(cat "$state")
echo \$\$ > vm-boot.pid
if [[ "\$call" == 1 ]]; then
  echo "run-vm.sh: refusing to boot vm 0 at the boot guard" >&2
  exit 1
fi
echo \$\$ > vm.pid
rm -f vm-boot.pid
source ../test/vm/rig/hooks.sh && rig_boot_started 0
SSH_PORT=\$((2222 + RHIZO_VM + \${RHIZO_PORT_OFFSET:-0}))
exec ./qemu-system-x86_64 -netdev user,id=n,hostfwd=tcp:127.0.0.1:\${SSH_PORT}-:22
EOF
  chmod +x "$root/test/vm/run-vm.sh"
  printf '#!/bin/bash\nsleep 300\n' > "$root/var/qemu-system-x86_64"
  chmod +x "$root/var/qemu-system-x86_64"
  cat > "$root/bin/ssh" <<EOF
#!/bin/bash
call=\$(cat "$state" 2>/dev/null)
pid=\$(cat "$root/var/vm.pid" 2>/dev/null)
if [[ "\$call" == 3 ]]; then
  exit 255
fi
if [[ -n "\$pid" ]] && kill -0 "\$pid" 2>/dev/null; then
  case "\$*" in *is-system-running*) echo running ;; *) echo ok ;; esac
  exit 0
fi
exit 255
EOF
  chmod +x "$root/bin/ssh"
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    export RHIZO_VM_HOOK="$root/record-hook.sh" RHIZO_FIXTURE_BOOT_RECORD="$log_file"
    export EV="$root/ev"; mkdir -p "$EV"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    source ./test/system/lib/lib.sh
    body=$(extract_func ./test/system/lib/lib.sh test_boot) || exit 98
    body="${body/wait_for_ssh 300/wait_for_ssh 8}"
    eval "$body"
    FAILED=0 TEST_NAME=storage
    test_require_staged() { return 0; }
    eval "$W_GCBE() { echo \"LABEL:\$1\" >> \"$root/label.log\"; TEST_BOOT_FAULT=\"\$1\"; }"
    rig_verdict_write() { :; }
    test_boot --no-preflight; echo "BOOT1 rc=$? NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}]"
    test_record_verdict FAILED
    echo 2 > "$state"
    kill_vm >/dev/null 2>&1
    test_boot --no-preflight; echo "BOOT2 rc=$? NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}]"
    test_record_verdict PASSED
    echo 3 > "$state"
    kill_vm >/dev/null 2>&1
    test_boot --no-preflight; echo "BOOT3 rc=$? NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}] REFUSAL=[${RHIZO_BOOT_REFUSAL:-}]"
    test_record_verdict FAILED
    kill_vm >/dev/null 2>&1
  ) > "$root/test.out" 2>&1
  grep -q '^BOOT2 rc=0' "$root/test.out" \
    || { fail_check "two-boot: the second (real) boot did not succeed at all: $(cat "$root/test.out")"; return; }
  own_records "$log_file" > "$root/s1-rows.tsv"
  grep -qx 'OUTCOME 0 PASSED' "$root/s1-rows.tsv" \
    || fail_check "two-boot: no boot ended PASSED: $(cat "$root/s1-rows.tsv") :: $(cat "$root/test.out")"
  (( $(unrecorded_boots "$root/s1-rows.tsv") == 0 )) \
    || fail_check "two-boot: a started boot still has no outcome after both verdicts: $(cat "$root/s1-rows.tsv")"
  local label3; label3=$(label_of "$root")
  [[ "$label3" == "test-vm-never-came-up" ]] \
    || fail_check "two-boot: boot 3 (a real launch that genuinely hung) filed '$label3', not test-vm-never-came-up: $(cat "$root/test.out")"
  grep -qx 'OUTCOME 0 FAILED' "$root/s1-rows.tsv" \
    || fail_check "two-boot: boot 3 did not end FAILED: $(cat "$root/s1-rows.tsv") :: $(cat "$root/test.out")"
}

# check a boot 2 hang records its row
check_no_row_reset_refused_then_hang() {
  local root; root=$(new_fixture refused-then-hang)
  local log_file="$root/log.tsv"
  seed_log "$log_file"
  local state="$root/call.state"
  echo 1 > "$state"
  cat > "$root/test/vm/run-vm.sh" <<EOF
#!/bin/bash
cd "\$(dirname "\$0")/../../var"
call=\$(cat "$state")
echo \$\$ > vm-boot.pid
if [[ "\$call" == 1 ]]; then
  echo "run-vm.sh: refusing to boot vm 0 at the boot guard" >&2
  exit 1
fi
echo \$\$ > vm.pid
rm -f vm-boot.pid
source ../test/vm/rig/hooks.sh && rig_boot_started 0
SSH_PORT=\$((2222 + RHIZO_VM + \${RHIZO_PORT_OFFSET:-0}))
exec ./qemu-system-x86_64 -netdev user,id=n,hostfwd=tcp:127.0.0.1:\${SSH_PORT}-:22
EOF
  chmod +x "$root/test/vm/run-vm.sh"
  printf '#!/bin/bash\nsleep 300\n' > "$root/var/qemu-system-x86_64"
  chmod +x "$root/var/qemu-system-x86_64"
  printf '#!/bin/bash\nexit 255\n' > "$root/bin/ssh"
  chmod +x "$root/bin/ssh"
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    export RHIZO_VM_HOOK="$root/record-hook.sh" RHIZO_FIXTURE_BOOT_RECORD="$log_file"
    export EV="$root/ev"; mkdir -p "$EV"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    source ./test/system/lib/lib.sh
    body=$(extract_func ./test/system/lib/lib.sh test_boot) || exit 98
    body="${body/wait_for_ssh 300/wait_for_ssh 8}"
    eval "$body"
    FAILED=0 TEST_NAME=storage
    test_require_staged() { return 0; }
    eval "$W_GCBE() { echo \"LABEL:\$1\" >> \"$root/label.log\"; TEST_BOOT_FAULT=\"\$1\"; }"
    rig_verdict_write() { :; }
    test_boot --no-preflight; echo "BOOT1 rc=$? NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}]"
    echo 2 > "$state"
    kill_vm >/dev/null 2>&1
    test_boot --no-preflight; echo "BOOT2 rc=$? NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}] REFUSAL=[${RHIZO_BOOT_REFUSAL:-}]"
    test_record_verdict FAILED
    kill_vm >/dev/null 2>&1
  ) > "$root/test.out" 2>&1
  grep -q '^BOOT2 rc=1 NO_ROW=\[\] ' "$root/test.out" \
    || fail_check "refused-then-hang: TEST_BOOT_NO_ROW was set on boot 2's own genuine timeout: $(cat "$root/test.out")"
  local label; label=$(label_of "$root")
  [[ "$label" == "test-vm-never-came-up" ]] \
    || fail_check "refused-then-hang: boot 2 (a real launch that genuinely hung) filed '$label', not test-vm-never-came-up: $(cat "$root/test.out")"
  own_records "$log_file" > "$root/s1-rows.tsv"
  (( $(unrecorded_boots "$root/s1-rows.tsv") == 0 )) \
    || fail_check "refused-then-hang: boot 2 has no outcome after test_record_verdict FAILED: $(cat "$root/s1-rows.tsv") :: $(cat "$root/test.out")"
  grep -qx 'OUTCOME 0 FAILED' "$root/s1-rows.tsv" \
    || fail_check "refused-then-hang: boot 2 did not end FAILED: $(cat "$root/s1-rows.tsv") :: $(cat "$root/test.out")"
}

# check a launch crash files never-came-up
check_crash_after_real_boot_labeled() {
  local root; root=$(new_fixture crash-after-boot)
  local log_file="$root/log.tsv"
  local rsv_head rsv_tail rsv_selfdir rsv_print
  rsv_selfdir=$(extract_lines "$REAL_RSV" '^SELF_DIR="') \
    || { fail_check "crash after real boot: run-vm.sh no longer resolves its own SELF_DIR (line 28)"; return; }
  rsv_print=$(extract_lines "$REAL_RSV" '^PRINT_ARGV="' '^') \
    || { fail_check "crash after real boot: run-vm.sh no longer assigns PRINT_ARGV"; return; }
  rsv_head=$(extract_lines "$REAL_RSV" "$RSV_PIDFILE_WRITE_RE") \
    || { fail_check "crash after real boot: could not extract run-vm.sh's own private-pidfile write (line 45)"; return; }
  rsv_tail=$(extract_lines "$REAL_RSV" '^rm -f "vm-boot\$\{SUFFIX\}\.pid"$') \
    || { fail_check "crash after real boot: could not extract run-vm.sh's own rm/add fragment (526-529)"; return; }
  local write_line refusal_line
  write_line=$(grep -nE "$RSV_PIDFILE_WRITE_RE" "$REAL_RSV" | head -1 | cut -d: -f1)
  refusal_line=$(grep -nE '^[[:space:]]+exit 1$' "$REAL_RSV" | head -1 | cut -d: -f1)
  [[ -n "$write_line" ]] \
    || { fail_check "crash after real boot: run-vm.sh no longer has a private-pidfile write line at all"; return; }
  [[ -n "$refusal_line" ]] \
    || { fail_check "crash after real boot: run-vm.sh no longer has any refusal exit to order the write against"; return; }
  (( write_line < refusal_line )) \
    || { fail_check "crash after real boot: run-vm.sh's private-pidfile write (line $write_line) no longer comes before its first refusal exit (line $refusal_line)"; return; }
  local selfdir_line cd_line relative_resolves
  selfdir_line=$(grep -n '^SELF_DIR="' "$REAL_RSV" | head -1 | cut -d: -f1)
  cd_line=$(grep -n '^cd "' "$REAL_RSV" | head -1 | cut -d: -f1)
  [[ "$(sed -n "${selfdir_line}p" "$REAL_RSV")" == *'&& pwd'* ]] \
    || { fail_check "crash after real boot: run-vm.sh's SELF_DIR (line $selfdir_line) no longer resolves absolutely (want \`cd ... && pwd\`)"; return; }
  [[ -n "$cd_line" ]] && (( selfdir_line < cd_line )) \
    || { fail_check "crash after real boot: run-vm.sh assigns SELF_DIR (line $selfdir_line) at or after its own cd (line ${cd_line:-none})"; return; }
  relative_resolves=$(grep -c 'dirname "\${BASH_SOURCE\[0\]}")/' "$REAL_RSV")
  (( relative_resolves == 0 )) \
    || { fail_check "crash after real boot: run-vm.sh still reaches its sibling scripts through a post-cd relative dirname in $relative_resolves place(s)"; return; }
  {
    echo '#!/bin/bash'
    printf '%s\n' "$rsv_selfdir"
    printf '%s\n' "$rsv_print"
    printf '%s\n' "$rsv_head"
    echo 'echo $$ > "vm${SUFFIX}.pid"                    # line 98'
    echo 'source "$SELF_DIR/rig/hooks.sh"                 # the boot guard passes'
    printf '%s\n' "$rsv_tail"
    echo 'SSH_PORT=$((2222 + RHIZO_VM + ${RHIZO_PORT_OFFSET:-0}))'
    echo 'exec ./qemu-system-x86_64 -netdev user,id=n,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22   # line 588'
  } > "$root/test/vm/run-vm.sh"
  chmod +x "$root/test/vm/run-vm.sh"
  cat > "$root/var/qemu-system-x86_64" <<'EOF'
#!/bin/bash
sleep 3
exit 1
EOF
  chmod +x "$root/var/qemu-system-x86_64"
  write_ssh "$root" refuse
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    export RHIZO_VM_HOOK="$root/record-hook.sh" RHIZO_FIXTURE_BOOT_RECORD="$log_file"
    export EV="$root/ev"; mkdir -p "$EV"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    source ./test/system/lib/lib.sh
    body=$(extract_func ./test/system/lib/lib.sh test_boot) || exit 98
    body="${body/wait_for_ssh 300/wait_for_ssh 8}"
    eval "$body"
    FAILED=0 TEST_NAME=crash-after-boot
    test_require_staged() { return 0; }
    eval "$W_GCBE() { echo \"LABEL:\$1\" >> \"$root/label.log\"; TEST_BOOT_FAULT=\"\$1\"; }"
    rig_verdict_write() { :; }
    test_boot --no-preflight
    echo "rc=$? NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}] REFUSAL=[${RHIZO_BOOT_REFUSAL:-}]"
    test_record_verdict FAILED
  ) > "$root/test.out" 2>&1
  local label; label=$(label_of "$root")
  [[ "$label" == "test-vm-never-came-up" ]] \
    || fail_check "crash after real boot: filed '$label', not test-vm-never-came-up: $(cat "$root/test.out")"
  own_records "$log_file" > "$root/s1-rows.tsv"
  grep -qx 'OUTCOME 0 FAILED' "$root/s1-rows.tsv" \
    || fail_check "crash after real boot: this attempt did not end FAILED: $(cat "$root/s1-rows.tsv") :: $(cat "$root/test.out")"
  (( $(unrecorded_boots "$root/s1-rows.tsv") == 0 )) \
    || fail_check "crash after real boot: this attempt still has no outcome: $(cat "$root/s1-rows.tsv")"
}

# check a second refusal records boot 1's row
check_second_boot_refused_after_real_boot_closes_row() {
  local root; root=$(new_fixture storage-shape)
  local log_file="$root/log.tsv"
  local state="$root/call.state"; echo 1 > "$state"
  cat > "$root/test/vm/run-vm.sh" <<EOF
#!/bin/bash
cd "\$(dirname "\$0")/../../var"
call=\$(cat "$state")
echo \$\$ > vm-boot.pid
echo \$\$ > vm.pid
if [[ "\$call" == 2 ]]; then
  echo "run-vm.sh: refusing to boot vm 0 at the boot guard" >&2
  exit 1
fi
rm -f vm-boot.pid
source ../test/vm/rig/hooks.sh && rig_boot_started 0
SSH_PORT=\$((2222 + RHIZO_VM + \${RHIZO_PORT_OFFSET:-0}))
exec ./qemu-system-x86_64 -netdev user,id=n,hostfwd=tcp:127.0.0.1:\${SSH_PORT}-:22
EOF
  chmod +x "$root/test/vm/run-vm.sh"
  printf '#!/bin/bash\nsleep 300\n' > "$root/var/qemu-system-x86_64"
  chmod +x "$root/var/qemu-system-x86_64"
  cat > "$root/bin/ssh" <<EOF
#!/bin/bash
pid=\$(cat "$root/var/vm.pid" 2>/dev/null)
comm=\$(cat /proc/\$pid/comm 2>/dev/null)
if [[ -n "\$pid" ]] && [[ "\$comm" == qemu-system* ]] && kill -0 "\$pid" 2>/dev/null; then
  case "\$*" in *is-system-running*) echo running ;; *) echo ok ;; esac
  exit 0
fi
exit 255
EOF
  chmod +x "$root/bin/ssh"
  (
    cd "$root" || exit 99
    export PATH="$root/bin:$PATH"
    export RHIZO_VM=0 SUFFIX=""
    export XDG_RUNTIME_DIR="$root/xdg"; mkdir -p "$XDG_RUNTIME_DIR"
    export RHIZO_VM_HOOK="$root/record-hook.sh" RHIZO_FIXTURE_BOOT_RECORD="$log_file"
    export EV="$root/ev"; mkdir -p "$EV"
    RHIZO_PORT_OFFSET=$(free_port_offset); export RHIZO_PORT_OFFSET
    source ./test/vm/common.sh
    source ./test/system/lib/lib.sh
    body=$(extract_func ./test/system/lib/lib.sh test_boot) || exit 98
    body="${body/wait_for_ssh 300/wait_for_ssh 8}"
    eval "$body"
    # shellcheck disable=SC2034
    FAILED=0 TEST_NAME=storage-shape
    test_require_staged() { return 0; }
    eval "$W_GCBE() { echo \"LABEL:\$1\" >> \"$root/label.log\"; TEST_BOOT_FAULT=\"\$1\"; }"
    rig_verdict_write() { :; }
    test_boot --no-preflight
    echo "BOOT1 rc=$? NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}]"
    echo 2 > "$state"
    test_boot --no-preflight
    echo "BOOT2 rc=$? NO_ROW=[${TEST_BOOT_NO_ROW:-}] BOOTED=[${TEST_BOOTED:-}]"
    test_record_verdict FAILED
    kill_vm >/dev/null 2>&1
  ) > "$root/test.out" 2>&1
  local label; label=$(label_of "$root")
  [[ "$label" == "test-vm-refused" ]] \
    || fail_check "real boot then refused boot: filed '$label', not test-vm-refused: $(cat "$root/test.out")"
  own_records "$log_file" > "$root/s1-rows.tsv"
  grep -qx 'OUTCOME 0 FAILED' "$root/s1-rows.tsv" \
    || fail_check "real boot then refused boot: boot 1 did not end FAILED: $(cat "$root/s1-rows.tsv") :: $(cat "$root/test.out")"
  (( $(unrecorded_boots "$root/s1-rows.tsv") == 0 )) \
    || fail_check "real boot then refused boot: a started boot still has no outcome: $(cat "$root/s1-rows.tsv")"
  local n; n=$(grep -c '^STARTED ' "$root/s1-rows.tsv")
  (( n <= 1 )) \
    || fail_check "real boot then refused boot: more than one boot started: $(cat "$root/s1-rows.tsv")"
}

RUN_CHECKS=(check_precheck_refusal_labeled check_silent_refusal_still_labeled check_late_refusal_still_labeled
            check_real_hang_keeps_old_label check_slow_success_not_refused
            check_redeploy_refused_labeled check_test_log_untouched_on_refusal
            check_redeploy_log_untouched_on_refusal
            check_shared_pidfile_untouched_on_refusal
            check_no_row_reset_across_two_boots
            check_no_row_reset_refused_then_hang
            check_crash_after_real_boot_labeled
            check_second_boot_refused_after_real_boot_closes_row)

if (( SELFTEST )); then
  MUT="$WORK/mut"
  mkdir -p "$MUT"
  SELF_FAILED=0

  run_against() {
    local save_c="$COMMON" save_g="$TEST_LIB" save_r="$REDEPLOY" fn="$4"
    COMMON="$1" TEST_LIB="$2" REDEPLOY="$3"
    FAILURES=()
    "$fn"
    local n=${#FAILURES[@]}
    COMMON="$save_c" TEST_LIB="$save_g" REDEPLOY="$save_r"
    (( n > 0 ))
  }

  run_against_rsv() {
    local save_r="$REAL_RSV" fn="$2"
    REAL_RSV="$1"
    FAILURES=()
    "$fn"
    local n=${#FAILURES[@]}
    REAL_RSV="$save_r"
    (( n > 0 ))
  }

  run_against_log() {
    local save_g="$TEST_LIB" save_col="$COLLECT" fn="$3"
    TEST_LIB="$1" COLLECT="$2"
    FAILURES=()
    "$fn"
    local n=${#FAILURES[@]}
    TEST_LIB="$save_g" COLLECT="$save_col"
    (( n > 0 ))
  }

  run_against_log_redeploy() {
    local save_r="$REDEPLOY" fn="$2"
    REDEPLOY="$1"
    FAILURES=()
    "$fn"
    local n=${#FAILURES[@]}
    REDEPLOY="$save_r"
    (( n > 0 ))
  }
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$COMMON" "$MUT/common-ignored.sh"
  python3 - "$MUT/common-ignored.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'\n\s*RHIZO_BOOT_REFUSAL="run-vm\.sh exited before qemu started"\n', '\n', s, count=1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not drop the RHIZO_BOOT_REFUSAL assignment")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$MUT/common-ignored.sh" "$TEST_LIB" "$REDEPLOY" check_precheck_refusal_labeled \
    || { echo "SELFTEST FAIL: refusal-ignored mutant (RHIZO_BOOT_REFUSAL never set) still passed"; exit 1; }
  echo "mutant 1/19 (refusal ignored) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$COMMON" "$MUT/common-window.sh"
  python3 - "$MUT/common-window.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace(
    'if (( slept )) && _boot_refused_via "$VAR_DIR/vm-boot${SUFFIX}.pid"; then',
    'if (( ! slept )) && _boot_refused_via "$VAR_DIR/vm-boot${SUFFIX}.pid"; then', 1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not narrow the dead-pid check to one look")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$MUT/common-window.sh" "$TEST_LIB" "$REDEPLOY" check_late_refusal_still_labeled \
    || { echo "SELFTEST FAIL: fixed-window mutant (dead-pid checked once, not every pass) still passed"; exit 1; }
  echo "mutant 2/19 (fixed detection window) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$COMMON" "$MUT/common-blind.sh"
  python3 - "$MUT/common-blind.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace(
  '[[ -n "$pid" ]] && ! vm_pid_is_ours "$pid"',
  '[[ -n "$pid" ]]', 1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not make the dead-pid check liveness-blind")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$MUT/common-blind.sh" "$TEST_LIB" "$REDEPLOY" check_slow_success_not_refused \
    || { echo "SELFTEST FAIL: liveness-blind mutant (any non-empty pidfile reads as refused) still passed"; exit 1; }
  echo "mutant 3/19 (slow real boot misread as refused) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$TEST_LIB" "$MUT/lib-wronglabel.sh"
  python3 - "$MUT/lib-wronglabel.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
_gcbe = 'test_collect_boot' + '_evidence'
s2 = s.replace(_gcbe + ' "test-vm-refused"',
               _gcbe + ' "test-vm-refused-oops"', 1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not rename the refusal label")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$COMMON" "$MUT/lib-wronglabel.sh" "$REDEPLOY" check_precheck_refusal_labeled \
    || { echo "SELFTEST FAIL: wrong-label mutant (test-vm-refused-oops) still passed"; exit 1; }
  echo "mutant 4/19 (wrong label) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$REDEPLOY" "$MUT/redeploy-unfixed.sh"
  python3 - "$MUT/redeploy-unfixed.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(
  r'    if \[\[ -n "\$RHIZO_BOOT_REFUSAL" \]\]; then\n.*?\n    fi\n',
  '', s, count=1, flags=re.S)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not revert redeploy.sh's own refusal branch")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$COMMON" "$TEST_LIB" "$MUT/redeploy-unfixed.sh" check_redeploy_refused_labeled \
    || { echo "SELFTEST FAIL: redeploy-unfixed mutant still passed"; exit 1; }
  echo "mutant 5/19 (redeploy call site unfixed) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT


  cp "$TEST_LIB" "$MUT/lib-noverdictskip.sh"
  python3 - "$MUT/lib-noverdictskip.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace('  if [[ -n "${TEST_BOOT_NO_ROW:-}" ]]; then', '  if false; then', 1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not remove test_record_verdict's NO_ROW skip")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against_log "$MUT/lib-noverdictskip.sh" "$COLLECT" check_test_log_untouched_on_refusal \
    || { echo "SELFTEST FAIL: test_record_verdict NO_ROW skip removed, still passed"; exit 1; }
  echo "mutant 6/19 (test_record_verdict skip removed) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$COLLECT" "$MUT/collect-noskip.sh"
  python3 - "$MUT/collect-noskip.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace(
  'if [[ -z "${TEST_NAME:-}" && -z "${RHIZO_BOOT_NO_ROW:-}" ]]; then',
  'if [[ -z "${TEST_NAME:-}" ]]; then', 1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not remove the collector's own skip")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against_log "$TEST_LIB" "$MUT/collect-noskip.sh" check_test_log_untouched_on_refusal \
    || { echo "SELFTEST FAIL: the collector's own skip removed, still passed"; exit 1; }
  echo "mutant 7/19 (collector skip removed) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$TEST_LIB" "$MUT/lib-noexport.sh"
  python3 - "$MUT/lib-noexport.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
_cbesh = 'collect-boot-evidence' + '.sh'
s2 = s.replace(
  '  RHIZO_BOOT_NO_ROW="${TEST_BOOT_NO_ROW:-}" "$REPO/test/vm/boot/' + _cbesh + '" \\\n',
  '  "$REPO/test/vm/boot/' + _cbesh + '" \\\n', 1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not remove the RHIZO_BOOT_NO_ROW export")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against_log "$MUT/lib-noexport.sh" "$COLLECT" check_test_log_untouched_on_refusal \
    || { echo "SELFTEST FAIL: RHIZO_BOOT_NO_ROW export removed, still passed"; exit 1; }
  echo "mutant 8/19 (NO_ROW never forwarded to the collector) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$REDEPLOY" "$MUT/redeploy-noexport.sh"
  python3 - "$MUT/redeploy-noexport.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace('      export RHIZO_BOOT_NO_ROW=1\n', '', 1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not remove redeploy.sh's RHIZO_BOOT_NO_ROW export")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against_log_redeploy "$MUT/redeploy-noexport.sh" check_redeploy_log_untouched_on_refusal \
    || { echo "SELFTEST FAIL: redeploy.sh's RHIZO_BOOT_NO_ROW export removed, still passed"; exit 1; }
  echo "mutant 9/19 (redeploy NO_ROW export removed) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$COMMON" "$MUT/common-timeout-token.sh"
  python3 - "$MUT/common-timeout-token.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '      log "SSH did not come up within ${deadline_s}s"\n'
new = '      log "SSH did not come up within ${deadline_s}s"\n      RHIZO_BOOT_REFUSAL=timeout\n'
n = s.count(old)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: pattern count %d for the timeout-token mutant" % n)
open(p, "w").write(s.replace(old, new, 1))
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$MUT/common-timeout-token.sh" "$TEST_LIB" "$REDEPLOY" check_real_hang_keeps_old_label \
    || { echo "SELFTEST FAIL: timeout-token mutant (a genuine timeout also sets RHIZO_BOOT_REFUSAL) still passed"; exit 1; }
  echo "mutant 10/19 (timeout misread as refusal) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$TEST_LIB" "$MUT/lib-norowreset.sh"
  python3 - "$MUT/lib-norowreset.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  TEST_BOOT_NO_ROW=""\n  test_require_staged '
new = '  test_require_staged '
n = s.count(old)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: pattern count %d for the NO_ROW-never-reset mutant" % n)
open(p, "w").write(s.replace(old, new, 1))
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$COMMON" "$MUT/lib-norowreset.sh" "$REDEPLOY" check_no_row_reset_across_two_boots \
    || { echo "SELFTEST FAIL: NO_ROW-never-reset mutant still passed"; exit 1; }
  echo "mutant 11/19 (TEST_BOOT_NO_ROW never reset) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$COMMON" "$MUT/common-vmpidfile-token.sh"
  python3 - "$MUT/common-vmpidfile-token.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    if (( slept )) && _boot_refused_via "$VM_PIDFILE"; then\n'
new = '    if (( slept )) && _boot_refused_via "$VM_PIDFILE"; then\n      RHIZO_BOOT_REFUSAL="vmpidfile"\n'
n = s.count(old)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: pattern count %d for the VM_PIDFILE-token mutant" % n)
open(p, "w").write(s.replace(old, new, 1))
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$MUT/common-vmpidfile-token.sh" "$TEST_LIB" "$REDEPLOY" check_crash_after_real_boot_labeled \
    || { echo "SELFTEST FAIL: VM_PIDFILE-token mutant (a real crash also sets RHIZO_BOOT_REFUSAL) still passed"; exit 1; }
  echo "mutant 12/19 (VM_PIDFILE branch sets a refusal token) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$TEST_LIB" "$MUT/lib-nobooted.sh"
  python3 - "$MUT/lib-nobooted.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '  TEST_BOOTED=1\n  if ! wait_for_guest_ready 120; then'
new = '  if ! wait_for_guest_ready 120; then'
n = s.count(old)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: pattern count %d for the never-sets-BOOTED mutant" % n)
open(p, "w").write(s.replace(old, new, 1))
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$COMMON" "$MUT/lib-nobooted.sh" "$REDEPLOY" check_second_boot_refused_after_real_boot_closes_row \
    || { echo "SELFTEST FAIL: never-sets-BOOTED mutant still passed"; exit 1; }
  echo "mutant 13/19 (TEST_BOOTED never set) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$TEST_LIB" "$MUT/lib-noguard.sh"
  python3 - "$MUT/lib-noguard.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '      [[ -z "${TEST_BOOTED:-}" ]] && TEST_BOOT_NO_ROW=1\n      test_collect_boot_evidence "test-vm-refused"'
new = '      TEST_BOOT_NO_ROW=1\n      test_collect_boot_evidence "test-vm-refused"'
n = s.count(old)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: pattern count %d for the BOOTED-guard-dropped mutant" % n)
open(p, "w").write(s.replace(old, new, 1))
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$COMMON" "$MUT/lib-noguard.sh" "$REDEPLOY" check_second_boot_refused_after_real_boot_closes_row \
    || { echo "SELFTEST FAIL: BOOTED-guard-dropped mutant still passed"; exit 1; }
  echo "mutant 14/19 (TEST_BOOTED guard on NO_ROW dropped) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$COMMON" "$MUT/common-log-tail-token.sh"
  python3 - "$MUT/common-log-tail-token.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '      RHIZO_BOOT_REFUSAL="run-vm.sh exited before qemu started"'
new = '      RHIZO_BOOT_REFUSAL=$(tail -3 "$REPO/vm-boot${SUFFIX}.log" 2>/dev/null | tr \'\\n\' \' \')'
n = s.count(old)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: pattern count %d for the log-tail-token mutant" % n)
open(p, "w").write(s.replace(old, new, 1))
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$MUT/common-log-tail-token.sh" "$TEST_LIB" "$REDEPLOY" check_silent_refusal_still_labeled \
    || { echo "SELFTEST FAIL: log-tail-token mutant (empty on a silent launcher) still passed"; exit 1; }
  echo "mutant 15/19 (refusal token reverts to an empty log tail) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$COMMON" "$MUT/common-shared-pidfile-rm.sh"
  python3 - "$MUT/common-shared-pidfile-rm.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('  RHIZO_BOOT_REFUSAL=""\n'
       '  rm -f "$VAR_DIR/vm-boot${SUFFIX}.pid"\n')
new = ('  RHIZO_BOOT_REFUSAL=""\n'
       '  rm -f "$VM_PIDFILE"\n')
n = s.count(old)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: pattern count %d for the shared-pidfile-rm mutant" % n)
open(p, "w").write(s.replace(old, new, 1))
PY
  [[ $? -eq 0 ]] || exit 1
  run_against "$MUT/common-shared-pidfile-rm.sh" "$TEST_LIB" "$REDEPLOY" check_shared_pidfile_untouched_on_refusal \
    || { echo "SELFTEST FAIL: shared-pidfile-rm mutant (boot_vm rm's VM_PIDFILE instead of the private one) still passed"; exit 1; }
  echo "mutant 16/19 (boot_vm rm's the shared pidfile instead of the private one) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$REAL_RSV" "$MUT/rsv-no-selfdir.sh"
  python3 - "$MUT/rsv-no-selfdir.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'\nSELF_DIR="[^\n]*\n', '\n', s, count=1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not drop run-vm.sh's SELF_DIR assignment")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against_rsv "$MUT/rsv-no-selfdir.sh" check_crash_after_real_boot_labeled \
    || { echo "SELFTEST FAIL: no-SELF_DIR mutant (assignment deleted, five uses left) still passed"; exit 1; }
  echo "mutant 17/19 (run-vm.sh's SELF_DIR assignment deleted) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$REAL_RSV" "$MUT/rsv-relative-selfdir.sh"
  python3 - "$MUT/rsv-relative-selfdir.sh" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'\nSELF_DIR="[^\n]*\n',
            '\nSELF_DIR="$(dirname "${BASH_SOURCE[0]}")"\n', s, count=1)
if s2 == s:
    sys.exit("SELFTEST SETUP FAIL: could not make run-vm.sh's SELF_DIR relative")
open(p, "w").write(s2)
PY
  [[ $? -eq 0 ]] || exit 1
  run_against_rsv "$MUT/rsv-relative-selfdir.sh" check_crash_after_real_boot_labeled \
    || { echo "SELFTEST FAIL: relative-SELF_DIR mutant (no cd ... && pwd) still passed"; exit 1; }
  echo "mutant 18/19 (run-vm.sh's SELF_DIR resolved relatively) caught"
  ) &
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || SELF_FAILED=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT

  cp "$REAL_RSV" "$MUT/rsv-relative-resolve.sh"
  python3 - "$MUT/rsv-relative-resolve.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '"$SELF_DIR/rig/hooks.sh"'
new = '"$(dirname "${BASH_SOURCE[0]}")/rig/hooks.sh"'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: pattern count %d for the relative-resolve mutant" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PY
  [[ $? -eq 0 ]] || exit 1
  run_against_rsv "$MUT/rsv-relative-resolve.sh" check_crash_after_real_boot_labeled \
    || { echo "SELFTEST FAIL: relative-resolve mutant (a sibling-script call site back on a post-cd relative dirname) still passed"; exit 1; }
  echo "mutant 19/19 (a sibling-script call site reverted to a post-cd relative dirname) caught"
  ) &

  for p in $(jobs -p); do wait "$p" || SELF_FAILED=1; done
  (( SELF_FAILED )) && exit 1
  echo "selftest ok: all 19 mutants caught"
  exit 0
fi

rc=0
for fn in "${RUN_CHECKS[@]}"; do
  while (( $(jobs -rp | wc -l) >= 8 )); do wait -n || rc=1; done
  ( WORK=$(mktemp -d) || exit 1; trap 'reap_fixture_pids "$WORK"; rm -rf "$WORK"' EXIT
    FAILURES=()
    "$fn"
    (( ${#FAILURES[@]} == 0 )) ) &
done
for p in $(jobs -p); do wait "$p" || rc=1; done
(( rc == 0 )) && echo "ok: pre-boot refusals are labeled apart from a real ssh hang at both call sites, and a slow real boot is never misread as one"
exit $rc
