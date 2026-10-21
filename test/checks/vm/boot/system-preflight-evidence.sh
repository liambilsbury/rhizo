#!/bin/bash
# test vm-preflight FAIL lines in boot evidence
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_LIB="${TEST_LIB_FILE:-$HERE/../system/lib/lib.sh}"
COLLECTOR="${COLLECT_EVIDENCE_FILE:-$HERE/../vm/boot/collect-boot-evidence.sh}"
[[ -r "$TEST_LIB" ]] || { echo "FAIL: cannot read $TEST_LIB"; exit 1; }
[[ -r "$COLLECTOR" ]] || { echo "FAIL: cannot read $COLLECTOR"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# print a function's definition from a file
extract_func() {
  local f="$1" name="$2" start end
  start=$(grep -n "^${name}() {" "$f" | head -1 | cut -d: -f1)
  [[ -n "$start" ]] || return 1
  end=$(awk -v s="$start" 'NR > s && /^}/ { print NR; exit }' "$f")
  [[ -n "$end" ]] || return 1
  sed -n "${start},${end}p" "$f"
}

FAILURES=()
# record a failure
fail() { FAILURES+=("$1"); }

# print the stub preflight.sh stderr text
preflight_stub_output() {
  local rc="$1" line="$2"
  printf '  SKIP half-configured packages: deferred to this caller'"'"'s own start-sway.sh step\n'
  printf '  SKIP egl: deferred to this caller'"'"'s own start-sway.sh step\n'
  if [[ -n "$line" ]]; then
    printf '  FAIL GSI tree at /srv/rhizo/gsi_system is not usable: TRUNCATED bin/init \n'
    printf '       re-stage it with test/vm/image/stage-gsi-trees.sh, or check RHIZO_GSI points at the right tree\n'
    printf '%s\n' "$line"
    printf '       truncate /root/rhizo-avc.log and /root/boot.log, then re-check\n'
  fi
  printf '  SKIP prepared tree: deferred to this caller'"'"'s own redeploy.sh staging step, which restages /root before this boot'"'"'s launcher runs\n'
  (( rc != 0 )) && printf 'vm 1 is NOT ready to boot Android\n'
}

# write a stub preflight.sh and its output file
write_preflight_stub() {
  local dir="$1" rc="$2" line="$3" expected="$4"
  preflight_stub_output "$rc" "$line" > "$expected"
  {
    echo '#!/bin/bash'
    if [[ -n "${SPLIT_STUB:-}" ]]; then
      echo "cat >&2 <<'STUBEOF'"
      head -n1 "$expected"
      echo 'STUBEOF'
      echo 'sleep 0.2'
      echo "cat >&2 <<'STUBEOF'"
      tail -n +2 "$expected"
      echo 'STUBEOF'
    else
      echo "cat >&2 <<'STUBEOF'"
      cat "$expected"
      echo 'STUBEOF'
    fi
    echo "exit $rc"
  } > "$dir/preflight.sh"
  chmod +x "$dir/preflight.sh"
}

# write a stub common.sh
write_stub_common() {
  local dir="$1"
  cat > "$dir/common.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VAR_DIR="$REPO/var"
SUFFIX=""
SSH_PORT=2222
RHIZO_VM="${RHIZO_VM:-0}"
ssh_vm() { return 255; }
rig_run_identity() { :; }
EOF
}

# run test_boot against the stubbed preflight.sh
run_test_boot() {
  local case="$1" lib="$2" collector="$3" prc="$4" line="$5"
  shift 5
  local test_boot_args=("$@")
  local root="$WORK/case-$case" ev
  [[ -n "${KEEP_ROOT:-}" ]] || rm -rf "$root"
  mkdir -p "$root/test/vm/boot" "$root/tmp"
  if [[ -n "${CUSTOM_STUB:-}" ]]; then
    cp "$CUSTOM_STUB" "$root/test/vm/boot/preflight.sh"
    chmod +x "$root/test/vm/boot/preflight.sh"
  else
    write_preflight_stub "$root/test/vm/boot" "$prc" "$line" "$root/test/vm/preflight-expected.txt"
  fi
  cp "$collector" "$root/test/vm/boot/collect-boot-evidence.sh"
  chmod +x "$root/test/vm/boot/collect-boot-evidence.sh"
  write_stub_common "$root/test/vm"
  ev="$root/ev"
  mkdir -p "$ev"
  : > "$root/mktemp-calls.log"

  local test_boot_body test_collect_body
  test_boot_body="$(extract_func "$lib" test_boot)" \
    || { echo "MISSING test_boot() in $lib" > "$root/run.out"; echo 2 > "$root/rc"; return; }
  test_collect_body="$(extract_func "$lib" test_collect_boot_evidence)" \
    || { echo "MISSING test_collect_boot_evidence() in $lib" > "$root/run.out"; echo 2 > "$root/rc"; return; }

  (
    set -u
    set +o pipefail
    REPO="$root"
    EV="$ev"
    RHIZO_VM=1
    SUFFIX=""
    TMPDIR="$root/tmp"
    export TMPDIR
    FAIL_LOG="$root/fail.log"
    : > "$FAIL_LOG"
    test_require_staged() { return 0; }
    wait_for_boot_slot()  { return 0; }
    wait_for_ssh()        { return 0; }
    wait_for_guest_ready(){ return 0; }
    ssh_vm()               { return 0; }
    kill_vm()              { :; }
    boot_vm()              { :; }
    log()                  { :; }
    fail()                 { echo "$*" >> "$FAIL_LOG"; }
    mktemp() { local p; p=$(command mktemp "$@") || return $?; echo "$p" >> "$root/mktemp-calls.log"; printf '%s\n' "$p"; }
    eval "$test_collect_body"
    eval "$test_boot_body"
    echo "TMPDIR-BEFORE-COUNT: $(find "$TMPDIR" -maxdepth 1 -name 'rhizo-preflight-*' 2>/dev/null | wc -l)"
    test_boot "${test_boot_args[@]}"
    echo "test_boot rc=$?"
    echo "TMPDIR-AFTER-COUNT: $(find "$TMPDIR" -maxdepth 1 -name 'rhizo-preflight-*' 2>/dev/null | wc -l)"
  ) > "$root/run.out" 2>&1

  grep -o 'test_boot rc=[0-9]*' "$root/run.out" | tail -1 | cut -d= -f2 > "$root/rc"
}

# check preflight.txt matches the stub output
check_failed_preflight_line_in_bundle() {
  local lib="$1" collector="$2" root rc bundle line="  FAIL guest root filesystem is 93% full"
  SPLIT_STUB=1 run_test_boot failed-line "$lib" "$collector" 1 "$line"
  root="$WORK/case-failed-line"
  rc=$(cat "$root/rc" 2>/dev/null || echo "")
  [[ "$rc" == "1" ]] || { fail "test_boot returned '$rc', not 1, on a failed preflight with a unique FAIL line: $(cat "$root/run.out" 2>/dev/null)"; return; }
  bundle=$(find "$root/ev/boot-failure" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  [[ -n "$bundle" ]] || { fail "no boot-failure bundle was created on a failed preflight: $(cat "$root/run.out" 2>/dev/null)"; return; }
  [[ -f "$bundle/preflight.txt" ]] \
    || { fail "no $bundle/preflight.txt"; return; }
  cmp -s "$bundle/preflight.txt" "$root/test/vm/preflight-expected.txt" \
    || fail "$bundle/preflight.txt is not byte-for-byte the stub's full output -- expected: $(cat "$root/test/vm/preflight-expected.txt" 2>/dev/null) -- got: $(cat "$bundle/preflight.txt" 2>/dev/null)"
  grep -q '^preflight output .* preflight\.txt$' "$bundle/MANIFEST.txt" \
    || fail "$bundle/MANIFEST.txt does not name the preflight item: $(cat "$bundle/MANIFEST.txt" 2>/dev/null)"

  KEEP_ROOT=1 run_test_boot failed-line "$lib" "$collector" 1 "  FAIL guest root filesystem is 97% full"
  bundle=$(find "$root/ev/boot-failure" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
  [[ -n "$bundle" ]] \
    || { fail "no boot-failure bundle was created on a second failed preflight in the same root: $(cat "$root/run.out" 2>/dev/null)"; return; }
  cmp -s "$bundle/preflight.txt" "$root/test/vm/preflight-expected.txt" \
    || fail "$bundle/preflight.txt is not the second failed run's own output -- expected: $(cat "$root/test/vm/preflight-expected.txt" 2>/dev/null) -- got: $(cat "$bundle/preflight.txt" 2>/dev/null)"
}

# check a passing preflight removes its temp file
check_success_no_tmp_leak() {
  local lib="$1" collector="$2" root rc before after calls path
  run_test_boot passed "$lib" "$collector" 0 ""
  root="$WORK/case-passed"
  rc=$(cat "$root/rc" 2>/dev/null || echo "")
  [[ "$rc" == "0" ]] || { fail "test_boot returned '$rc', not 0, on a passing preflight: $(cat "$root/run.out" 2>/dev/null)"; return; }
  before=$(grep -o 'TMPDIR-BEFORE-COUNT: [0-9]*' "$root/run.out" | grep -o '[0-9]*$')
  after=$(grep -o 'TMPDIR-AFTER-COUNT: [0-9]*' "$root/run.out" | grep -o '[0-9]*$')
  [[ "$before" == "0" && "$after" == "0" ]] \
    || fail "TMPDIR's rhizo-preflight-* file count changed on a passing preflight: before=$before after=$after ($(cat "$root/run.out" 2>/dev/null))"
  calls=$(cat "$root/mktemp-calls.log" 2>/dev/null)
  [[ -n "$calls" ]] || { fail "test_boot never called mktemp for a passing preflight"; return; }
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$root/tmp/"* ]] \
      || fail "test_boot's preflight capture landed at '$path', not under TMPDIR ($root/tmp)"
    [[ -e "$path" ]] \
      && fail "test_boot's preflight capture file '$path' still exists after a passing run"
  done <<<"$calls"
}

# check a failed preflight removes its temp file
check_failed_leaves_no_tmp_file() {
  local lib="$1" collector="$2" root rc before after calls path line="  FAIL disk is full"
  run_test_boot failed-tmp "$lib" "$collector" 1 "$line"
  root="$WORK/case-failed-tmp"
  rc=$(cat "$root/rc" 2>/dev/null || echo "")
  [[ "$rc" == "1" ]] || { fail "test_boot returned '$rc', not 1, on a failed preflight: $(cat "$root/run.out" 2>/dev/null)"; return; }
  before=$(grep -o 'TMPDIR-BEFORE-COUNT: [0-9]*' "$root/run.out" | grep -o '[0-9]*$')
  after=$(grep -o 'TMPDIR-AFTER-COUNT: [0-9]*' "$root/run.out" | grep -o '[0-9]*$')
  [[ "$before" == "0" && "$after" == "0" ]] \
    || fail "TMPDIR's rhizo-preflight-* file count changed on a failed preflight: before=$before after=$after ($(cat "$root/run.out" 2>/dev/null))"
  calls=$(cat "$root/mktemp-calls.log" 2>/dev/null)
  [[ -n "$calls" ]] || { fail "test_boot never called mktemp for a failed preflight"; return; }
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$root/tmp/"* ]] \
      || fail "test_boot's preflight capture landed at '$path', not under TMPDIR ($root/tmp)"
    [[ -e "$path" ]] \
      && fail "test_boot's preflight capture file '$path' still exists after a failed run"
  done <<<"$calls"
}

# check EV for preflight files
check_nothing_named_preflight_under_ev() {
  local lib="$1" collector="$2" root leaked calls path

  run_test_boot ev-clean-passed "$lib" "$collector" 0 ""
  root="$WORK/case-ev-clean-passed"
  leaked=$(find "$root/ev" -maxdepth 1 -iname '*preflight*' 2>/dev/null)
  [[ -z "$leaked" ]] \
    || fail "test_boot left '$leaked' directly under \$EV on a passing preflight -- \$EV must never hold a preflight file"
  calls=$(cat "$root/mktemp-calls.log" 2>/dev/null)
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$root/ev/"* ]] \
      && fail "test_boot's preflight capture was created under \$EV ('$path') on a passing preflight, not outside it"
  done <<<"$calls"

  run_test_boot ev-clean-failed "$lib" "$collector" 1 "  FAIL something broke"
  root="$WORK/case-ev-clean-failed"
  leaked=$(find "$root/ev" -maxdepth 1 -iname '*preflight*' 2>/dev/null)
  [[ -z "$leaked" ]] \
    || fail "test_boot left '$leaked' directly under \$EV on a failed preflight -- \$EV must never hold a preflight file outside the dated boot-failure bundle"
  calls=$(cat "$root/mktemp-calls.log" 2>/dev/null)
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "$root/ev/"* ]] \
      && fail "test_boot's preflight capture was created under \$EV ('$path') on a failed preflight, not outside it"
  done <<<"$calls"
}

# check test_boot reports a mktemp failure
check_mktemp_failure_named() {
  local lib="$1" root="$WORK/case-mktemp-fails" ev
  rm -rf "$root"
  mkdir -p "$root/test/vm"
  ev="$root/ev"
  mkdir -p "$ev"

  local test_boot_body test_collect_body
  test_boot_body="$(extract_func "$lib" test_boot)" \
    || { fail "MISSING test_boot() in $lib"; return; }
  test_collect_body="$(extract_func "$lib" test_collect_boot_evidence)" \
    || { fail "MISSING test_collect_boot_evidence() in $lib"; return; }

  (
    set -u
    set +o pipefail
    # shellcheck disable=SC2034
    REPO="$root"
    # shellcheck disable=SC2034
    EV="$ev"
    # shellcheck disable=SC2034
    RHIZO_VM=1
    # shellcheck disable=SC2034
    SUFFIX=""
    TMPDIR="$root/tmp"
    mkdir -p "$TMPDIR"
    export TMPDIR
    FAIL_LOG="$root/fail.log"
    : > "$FAIL_LOG"
    test_require_staged() { return 0; }
    wait_for_boot_slot()  { return 0; }
    wait_for_ssh()        { return 0; }
    wait_for_guest_ready(){ return 0; }
    ssh_vm()               { return 0; }
    kill_vm()              { :; }
    boot_vm()              { :; }
    log()                  { :; }
    fail()                 { echo "$*" >> "$FAIL_LOG"; }
    mktemp()                { return 1; }
    eval "$test_collect_body"
    eval "$test_boot_body"
    test_boot
    echo "test_boot rc=$?"
  ) > "$root/run.out" 2>&1

  local rc
  rc=$(grep -o 'test_boot rc=[0-9]*' "$root/run.out" | tail -1 | cut -d= -f2)
  [[ "$rc" == "1" ]] || { fail "test_boot ($lib) returned '$rc', not 1, when mktemp fails: $(cat "$root/run.out" 2>/dev/null)"; return; }
  grep -qi mktemp "$root/fail.log" 2>/dev/null \
    || fail "test_boot ($lib) failed without naming mktemp as the cause: $(cat "$root/fail.log" 2>/dev/null)"
}

# check the collector omits preflight.txt for four labels
check_collector_label_gated() {
  local f="$1" label
  for label in test-vm-never-came-up x-preflight-failed-y test-preflight-failed-x x-test-preflight-failed; do
    check_collector_label_gated_one "$f" "$label"
  done
  return 0
}

# run the collector and look for preflight.txt
check_collector_label_gated_one() {
  local f="$1" label="$2" fixture dest bundle line="  FAIL guest root filesystem is 93% full"
  fixture="$WORK/collector-fixture-wrong-label"
  rm -rf "$fixture"
  mkdir -p "$fixture/boot"
  cp "$f" "$fixture/boot/collect-boot-evidence.sh"
  chmod +x "$fixture/boot/collect-boot-evidence.sh"
  write_stub_common "$fixture"
  printf '%s\n' "$line" > "$fixture/preflight-capture.txt"

  dest="$WORK/collector-dest-wrong-label"
  rm -rf "$dest"
  mkdir -p "$dest"
  RHIZO_PREFLIGHT_EVIDENCE="$fixture/preflight-capture.txt" RHIZO_VM=1 \
    "$fixture/boot/collect-boot-evidence.sh" "$dest" "$label" \
    > "$WORK/collector-run-wrong-label.out" 2>&1

  bundle=$(find "$dest" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  [[ -n "$bundle" ]] \
    || { fail "$f: the real collector made no bundle under $dest ($(cat "$WORK/collector-run-wrong-label.out" 2>/dev/null))"; return; }
  [[ -f "$bundle/preflight.txt" ]] \
    && fail "$f: the real collector wrote preflight.txt for label '$label' with RHIZO_PREFLIGHT_EVIDENCE set ($bundle)"
  return 0
}

# check test_boot returns 0 on preflight exit 0
check_exit0_with_fail_text_passes() {
  local lib="$1" collector="$2" root rc line="  FAIL this looks scary but the script says it is fine"
  run_test_boot exit0-fail-text "$lib" "$collector" 0 "$line"
  root="$WORK/case-exit0-fail-text"
  rc=$(cat "$root/rc" 2>/dev/null || echo "")
  [[ "$rc" == "0" ]] \
    || fail "test_boot returned '$rc', not 0, for a preflight that printed a FAIL-shaped line but exited 0: $(cat "$root/run.out" 2>/dev/null)"
}

# check test_init for preflight references
check_test_init_has_no_preflight_surface() {
  local lib="$1" body
  body="$(extract_func "$lib" test_init)" || { fail "MISSING test_init() in $lib"; return; }
  grep -qi preflight <<<"$body" \
    && fail "test_init ($lib) now mentions preflight"
  return 0
}

# check a relative RHIZO_PREFLIGHT_EVIDENCE reaches the bundle
check_collector_relative_preflight_evidence() {
  local f="$1" fixture callerdir dest bundle line="  FAIL rel capture"
  fixture="$WORK/collector-fixture-relpath"
  rm -rf "$fixture"
  mkdir -p "$fixture/boot"
  cp "$f" "$fixture/boot/collect-boot-evidence.sh"
  chmod +x "$fixture/boot/collect-boot-evidence.sh"
  write_stub_common "$fixture"

  callerdir="$WORK/collector-callerdir-relpath"
  rm -rf "$callerdir"
  mkdir -p "$callerdir/rel"
  printf '%s\n' "$line" > "$callerdir/rel/cap.txt"

  dest="$WORK/collector-dest-relpath"
  rm -rf "$dest"
  mkdir -p "$dest"

  (
    cd "$callerdir" || exit 2
    RHIZO_PREFLIGHT_EVIDENCE="rel/cap.txt" RHIZO_VM=1 \
      "$fixture/boot/collect-boot-evidence.sh" "$dest" "test-preflight-failed"
  ) > "$WORK/collector-run-relpath.out" 2>&1

  bundle=$(find "$dest" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  [[ -n "$bundle" ]] \
    || { fail "$f: the real collector made no bundle under $dest for a relative RHIZO_PREFLIGHT_EVIDENCE run from a different cwd ($(cat "$WORK/collector-run-relpath.out" 2>/dev/null))"; return; }
  [[ -f "$bundle/preflight.txt" ]] \
    || { fail "$f: no $bundle/preflight.txt for a relative RHIZO_PREFLIGHT_EVIDENCE run from $callerdir ($(cat "$WORK/collector-run-relpath.out" 2>/dev/null))"; return; }
  grep -qF "$line" "$bundle/preflight.txt" \
    || fail "$f: $bundle/preflight.txt does not contain the relative capture's FAIL line: $(cat "$bundle/preflight.txt" 2>/dev/null)"
}

# check preflight.txt holds stdout and stderr
check_stdout_and_stderr_both_captured() {
  local lib="$1" collector="$2" root rc bundle expected stub
  expected="$WORK/mixed-expected.txt"
  printf '  FAIL something broke\na stray stdout line\n       a hint\nvm 1 is NOT ready to boot Android\n' > "$expected"
  stub="$WORK/mixed-stub.sh"
  {
    echo '#!/bin/bash'
    echo "echo '  FAIL something broke' >&2"
    echo "echo 'a stray stdout line'"
    echo "cat >&2 <<'STUBEOF'"
    printf '       a hint\nvm 1 is NOT ready to boot Android\n'
    echo 'STUBEOF'
    echo 'exit 1'
  } > "$stub"
  chmod +x "$stub"
  CUSTOM_STUB="$stub" run_test_boot stdout-capture "$lib" "$collector" 1 ""
  root="$WORK/case-stdout-capture"
  rc=$(cat "$root/rc" 2>/dev/null || echo "")
  [[ "$rc" == "1" ]] || { fail "test_boot returned '$rc', not 1, on a failed preflight that also writes to stdout: $(cat "$root/run.out" 2>/dev/null)"; return; }
  bundle=$(find "$root/ev/boot-failure" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  [[ -n "$bundle" ]] || { fail "no boot-failure bundle was created for a preflight that writes to stdout: $(cat "$root/run.out" 2>/dev/null)"; return; }
  cmp -s "$bundle/preflight.txt" "$expected" \
    || fail "$bundle/preflight.txt does not carry vm-preflight's stdout line alongside its stderr -- expected: $(cat "$expected" 2>/dev/null) -- got: $(cat "$bundle/preflight.txt" 2>/dev/null)"
}

# run all checks against the given files
run_all_checks() {
  FAILURES=()
  check_failed_preflight_line_in_bundle "$1" "$2"
  check_success_no_tmp_leak "$1" "$2"
  check_failed_leaves_no_tmp_file "$1" "$2"
  check_nothing_named_preflight_under_ev "$1" "$2"
  check_mktemp_failure_named "$1"
  check_collector_label_gated "$2"
  check_exit0_with_fail_text_passes "$1" "$2"
  check_test_init_has_no_preflight_surface "$1"
  check_collector_relative_preflight_evidence "$2"
  check_stdout_and_stderr_both_captured "$1" "$2"
}

if (( ! SELFTEST )); then
  run_all_checks "$TEST_LIB" "$COLLECTOR"
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}"
    exit 1
  fi
  echo "ok: a failed preflight lands vm-preflight's full output in the boot-failure bundle and test_boot returns 1; no preflight temp file is left in TMPDIR or \$EV; preflight.txt is written only for test-preflight-failed; a preflight exiting 0 passes; test_init does not mention preflight"
  exit 0
fi

# pipe the capture through tee
inject_tee_masks_rc() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    "$REPO/test/vm/boot/preflight.sh" --quiet "${preflight_args[@]}" > "$preflight_out" 2>&1\n    preflight_rc=$?\n'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: capture line not found")
new = '    "$REPO/test/vm/boot/preflight.sh" --quiet "${preflight_args[@]}" 2>&1 | tee "$preflight_out"\n    preflight_rc=$?\n'
open(p, "w").write(s.replace(old, new, 1))
PY
}

# drop RHIZO_PREFLIGHT_EVIDENCE from the collector call
inject_var_not_passed() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '      RHIZO_PREFLIGHT_EVIDENCE="$preflight_out" test_collect_boot_evidence "test-preflight-failed"\n'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: evidence-forwarding call not found")
new = '      test_collect_boot_evidence "test-preflight-failed"\n'
open(p, "w").write(s.replace(old, new, 1))
PY
}

# drop the rm on the failure path
inject_rm_removed_on_failure() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('      RHIZO_PREFLIGHT_EVIDENCE="$preflight_out" test_collect_boot_evidence "test-preflight-failed"\n'
       '      rm -f "$preflight_out"\n'
       '      return 1\n')
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: failure-path rm not found")
new = ('      RHIZO_PREFLIGHT_EVIDENCE="$preflight_out" test_collect_boot_evidence "test-preflight-failed"\n'
       '      return 1\n')
open(p, "w").write(s.replace(old, new, 1))
PY
}

# drop the rm on the success path
inject_rm_removed_on_success() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    fi\n    rm -f "$preflight_out"\n  fi\n}\n'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: success-path rm not found")
new = '    fi\n  fi\n}\n'
open(p, "w").write(s.replace(old, new, 1))
PY
}

# create the capture file under EV
inject_file_under_ev() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'preflight_out="$(mktemp "${TMPDIR:-/tmp}/rhizo-preflight-XXXXXX")" || {\n'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: mktemp call not found")
new = 'preflight_out="$(mktemp "${EV:-/tmp}/rhizo-preflight-XXXXXX")" || {\n'
open(p, "w").write(s.replace(old, new, 1))
PY
}

# drop the mktemp failure check
inject_fail_on_mktemp_removed() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('    preflight_out="$(mktemp "${TMPDIR:-/tmp}/rhizo-preflight-XXXXXX")" || {\n'
       '      fail "test_boot: mktemp failed for the preflight capture"\n'
       '      return 1\n'
       '    }\n')
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: mktemp-failure check not found")
new = '    preflight_out="$(mktemp "${TMPDIR:-/tmp}/rhizo-preflight-XXXXXX")"\n'
open(p, "w").write(s.replace(old, new, 1))
PY
}

# invert the preflight_rc check
inject_rc_check_inverted() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if (( preflight_rc != 0 )); then\n'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: rc check not found")
new = 'if (( preflight_rc == 0 )); then\n'
open(p, "w").write(s.replace(old, new, 1))
PY
}

# append captures to a persistent file
inject_history_append() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '      RHIZO_PREFLIGHT_EVIDENCE="$preflight_out" test_collect_boot_evidence "test-preflight-failed"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: evidence-forwarding call not found")
new = ('      cat "$preflight_out" >> "$REPO/preflight-history.txt"\n'
       '      RHIZO_PREFLIGHT_EVIDENCE="$REPO/preflight-history.txt" test_collect_boot_evidence "test-preflight-failed"\n')
open(p, "w").write(s.replace(old, new, 1))
PY
}

# run preflight a second time in the background
inject_collect_before_run() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('    "$REPO/test/vm/boot/preflight.sh" --quiet "${preflight_args[@]}" > "$preflight_out" 2>&1\n'
       '    preflight_rc=$?\n')
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: capture line not found")
new = ('    "$REPO/test/vm/boot/preflight.sh" --quiet "${preflight_args[@]}" > /dev/null 2>&1\n'
       '    preflight_rc=$?\n'
       '    "$REPO/test/vm/boot/preflight.sh" --quiet "${preflight_args[@]}" > "$preflight_out" 2>&1 &\n')
open(p, "w").write(s.replace(old, new, 1))
PY
}

# redirect stderr to the capture file
inject_stdout_capture_dropped() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '"${preflight_args[@]}" > "$preflight_out" 2>&1\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: capture redirection not found")
new = '"${preflight_args[@]}" 2> "$preflight_out"\n'
open(p, "w").write(s.replace(old, new, 1))
PY
}

# remove the label check from the collector
inject_collector_ignores_label() {
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(
    r'if \[\[ "\$LABEL" != test-preflight-failed \]\]; then.*?\nfi\n(?=\nif \[\[ -r "\$console" \]\]; then)',
    s, re.DOTALL,
)
if not m:
    sys.exit("SELFTEST SETUP FAIL: label-gated preflight section not found")
new_block = (
    'if [[ -n "${RHIZO_PREFLIGHT_EVIDENCE:-}" ]]; then\n'
    '  if [[ -s "$RHIZO_PREFLIGHT_EVIDENCE" ]]; then\n'
    '    cp -p "$RHIZO_PREFLIGHT_EVIDENCE" "$DEST/preflight.txt"\n'
    '    keep "preflight output" "$DEST/preflight.txt"\n'
    '  else\n'
    '    drop "preflight output" "$RHIZO_PREFLIGHT_EVIDENCE is empty or unreadable"\n'
    '  fi\n'
    'else\n'
    '  note "$(printf \'%-22s %s\' "preflight output" "RHIZO_PREFLIGHT_EVIDENCE not set by the caller -- nothing to fold in")"\n'
    'fi\n'
)
s = s[:m.start()] + new_block + s[m.end():]
open(p, "w").write(s)
PY
}

# match labels with a preflight glob
inject_collector_glob_label() {
  python3 - "$1" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if [[ "$LABEL" != test-preflight-failed ]]; then\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: label system test not found")
open(p, "w").write(s.replace(old, 'if [[ "$LABEL" != *preflight* ]]; then\n'))
PY2
}

# match labels with a trailing glob
inject_collector_prefix_glob_label() {
  python3 - "$1" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'if [[ "$LABEL" != test-preflight-failed ]]; then\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: label system test not found")
open(p, "w").write(s.replace(old, 'if [[ "$LABEL" != test-preflight-failed* ]]; then\n'))
PY2
}

# copy the first capture line
inject_collector_head1() {
  python3 - "$1" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    cp -p "$RHIZO_PREFLIGHT_EVIDENCE" "$DEST/preflight.txt"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: preflight copy line not found")
open(p, "w").write(s.replace(old, '    head -n1 "$RHIZO_PREFLIGHT_EVIDENCE" > "$DEST/preflight.txt"\n', 1))
PY2
}

# copy the FAIL lines
inject_collector_fail_lines_only() {
  python3 - "$1" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    cp -p "$RHIZO_PREFLIGHT_EVIDENCE" "$DEST/preflight.txt"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: preflight copy line not found")
open(p, "w").write(s.replace(old, '    grep -F FAIL "$RHIZO_PREFLIGHT_EVIDENCE" > "$DEST/preflight.txt"\n', 1))
PY2
}

# copy the first 4 capture lines
inject_collector_head4() {
  python3 - "$1" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    cp -p "$RHIZO_PREFLIGHT_EVIDENCE" "$DEST/preflight.txt"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: preflight copy line not found")
open(p, "w").write(s.replace(old, '    head -n4 "$RHIZO_PREFLIGHT_EVIDENCE" > "$DEST/preflight.txt"\n', 1))
PY2
}

# copy the last 4 capture lines
inject_collector_tail4() {
  python3 - "$1" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    cp -p "$RHIZO_PREFLIGHT_EVIDENCE" "$DEST/preflight.txt"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: preflight copy line not found")
open(p, "w").write(s.replace(old, '    tail -n4 "$RHIZO_PREFLIGHT_EVIDENCE" > "$DEST/preflight.txt"\n', 1))
PY2
}

# remove the keep call for preflight.txt
inject_collector_no_keep() {
  python3 - "$1" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    keep "preflight output" "$DEST/preflight.txt"\n'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: keep line not found")
open(p, "w").write(s.replace(old, '', 1))
PY2
}

# remove the relative path resolution
inject_collector_no_relpath_fix() {
  python3 - "$1" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = ('[[ -z "${RHIZO_PREFLIGHT_EVIDENCE:-}" || "$RHIZO_PREFLIGHT_EVIDENCE" == /* ]] \\\n'
       '  || RHIZO_PREFLIGHT_EVIDENCE="$PWD/$RHIZO_PREFLIGHT_EVIDENCE"\n\n')
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: relative-path fix not found")
open(p, "w").write(s.replace(old, '', 1))
PY2
}

# run all checks against a mutated copy
selftest_case() {
  local name="$1" inject="$2" target="$3" lib="$TEST_LIB" collector="$COLLECTOR"
  local copy="$WORK/defect-$name.sh"
  if [[ "$target" == "test-lib" ]]; then
    cp "$TEST_LIB" "$copy"
    "$inject" "$copy" || { echo "SELFTEST SETUP FAIL ($name)"; exit 1; }
    bash -n "$copy" || { echo "SELFTEST SETUP FAIL ($name): mutated copy is not valid bash"; exit 1; }
    lib="$copy"
  else
    cp "$COLLECTOR" "$copy"
    "$inject" "$copy" || { echo "SELFTEST SETUP FAIL ($name)"; exit 1; }
    bash -n "$copy" || { echo "SELFTEST SETUP FAIL ($name): mutated copy is not valid bash"; exit 1; }
    collector="$copy"
  fi
  run_all_checks "$lib" "$collector"
  if (( ${#FAILURES[@]} == 0 )); then
    echo "SELFTEST FAIL ($name): the checker passed a copy with the $name defect reintroduced"
    exit 1
  fi
  echo "selftest ok ($name): detected -- ${FAILURES[0]}"
}

selftest_case tee-masks-rc              inject_tee_masks_rc              test-lib
selftest_case var-not-passed            inject_var_not_passed            test-lib
selftest_case rm-removed-on-failure     inject_rm_removed_on_failure     test-lib
selftest_case rm-removed-on-success     inject_rm_removed_on_success     test-lib
selftest_case file-under-ev             inject_file_under_ev             test-lib
selftest_case fail-on-mktemp-removed    inject_fail_on_mktemp_removed    test-lib
selftest_case rc-check-inverted         inject_rc_check_inverted         test-lib
selftest_case history-append            inject_history_append            test-lib
selftest_case collect-before-run        inject_collect_before_run        test-lib
selftest_case stdout-capture-dropped    inject_stdout_capture_dropped    test-lib
selftest_case collector-ignores-label   inject_collector_ignores_label   collector
selftest_case collector-glob-label      inject_collector_glob_label      collector
selftest_case collector-prefix-glob-label inject_collector_prefix_glob_label collector
selftest_case collector-head1           inject_collector_head1           collector
selftest_case collector-head4           inject_collector_head4           collector
selftest_case collector-tail4           inject_collector_tail4           collector
selftest_case collector-fail-lines-only inject_collector_fail_lines_only collector
selftest_case collector-no-keep         inject_collector_no_keep         collector
selftest_case collector-no-relpath-fix  inject_collector_no_relpath_fix  collector

run_all_checks "$TEST_LIB" "$COLLECTOR"
if (( ${#FAILURES[@]} > 0 )); then
  printf 'SELFTEST FAIL (clean): the real files failed their own checker: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "selftest ok (clean): the real lib.sh and collect-boot-evidence.sh pass every assertion"
