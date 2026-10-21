#!/bin/bash
# test the boot stage report of explain-boot.sh
set -uo pipefail

SELFTEST=0
TOOLS_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    --tools-dir) TOOLS_DIR="${2:?--tools-dir needs a directory}"; shift 2 ;;
    *) echo "explain-boot-stage.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

RC=0

# print the file text with comments stripped
strip_comments() {
  sed -E 's/(^|[[:space:]])#.*$//' "$1"
}

LAST_CALL_LOG=""
# run boot_stage with faked ssh answers and check its stage
run_case() {
  local name="$1" dir="$2" e_rc="$3" e_out="$4" z_rc="$5" z_out="$6" s_rc="$7" s_out="$8" expected="$9"
  local got counter calls
  counter="$(mktemp)"
  calls="$(mktemp)"
  echo 0 > "$counter"
  got=$(bash -c '
    set -uo pipefail
    cd "'"$dir"'" || exit 3
    export RHIZO_EXPLAIN_BOOT_LIB_ONLY=1
    export RHIZO_VM=999999
    source ./boot/explain-boot.sh >/dev/null 2>&1
    _ssh_vm_out() {
      local n
      n=$(( $(cat "'"$counter"'") + 1 ))
      echo "$n" > "'"$counter"'"
      printf "CALL %s: %s\n" "$n" "$2" >> "'"$calls"'"
      case $n in
        1) printf %s "'"$e_out"'"; return '"$e_rc"' ;;
        2) printf %s "'"$z_out"'"; return '"$z_rc"' ;;
        3) printf %s "'"$s_out"'"; return '"$s_rc"' ;;
        *) printf %s "unexpected-extra-call"; return 1 ;;
      esac
    }
    boot_stage FAKE_INIT_PID
  ' 2>&1)
  rm -f "$counter"
  LAST_CALL_LOG="$calls"
  if [[ "$got" == "$expected" ]]; then
    echo "ok: boot_stage $name -> $got"
  else
    echo "FAIL: boot_stage $name -- expected '$expected', got '$got'"
    RC=1
  fi
}

RUNNING=$'MATCH=500\nUNREADABLE=0\n__STAGE_END__'
NOT_RUNNING=$'MATCH=\nUNREADABLE=0\n__STAGE_END__'
UNREADABLE2=$'MATCH=\nUNREADABLE=2\n__STAGE_END__'
NOINIT_OUT=$'MATCH=\nUNREADABLE=0\nNOINIT=1\n__STAGE_END__'
TRUNCATED=$'MATCH=500\nUNREADABLE=0'

# run the offline walk against a fake /proc
assert_offline_walk() {
  local dir_arg="$1" tmp fake_proc got runner
  tmp="$(mktemp -d)"
  fake_proc="$tmp/proc"
  runner="$tmp/run-offline.sh"
  mkdir -p "$fake_proc"

  cat > "$runner" <<'RUNNER'
set -uo pipefail
cd "$RHIZO_OFFLINE_DIR" || exit 3
export RHIZO_EXPLAIN_BOOT_LIB_ONLY=1
export RHIZO_VM=999999
source ./boot/explain-boot.sh >/dev/null 2>&1
_ssh_vm_out() {
  local timeout_s="$1"; shift
  if [[ -n "${RHIZO_OFFLINE_HOOK:-}" ]]; then
    RHIZO_STAGE_PROC_ROOT="$RHIZO_OFFLINE_PROC" bash -c "$RHIZO_OFFLINE_HOOK"$'\n'"$1"
  else
    RHIZO_STAGE_PROC_ROOT="$RHIZO_OFFLINE_PROC" bash -c "$1"
  fi
}
_stage_pid_by_argv0 "$RHIZO_OFFLINE_ARGV0" "$RHIZO_OFFLINE_INIT_PID"
RUNNER

  offline() {
    got=$(RHIZO_OFFLINE_DIR="$dir_arg" RHIZO_OFFLINE_PROC="$fake_proc" \
          RHIZO_OFFLINE_ARGV0="$1" RHIZO_OFFLINE_INIT_PID="$2" \
          RHIZO_OFFLINE_HOOK="${3:-}" \
          bash "$runner" 2>&1)
    OFFLINE_RC=$?
  }

  rm -rf "${fake_proc:?}"/*
  mkdir -p "$fake_proc/4242" "$fake_proc/500"
  printf 'init\0second_stage\0' > "$fake_proc/4242/cmdline"
  printf 'zygote64\0--start-system-server\0' > "$fake_proc/500/cmdline"
  offline zygote64 4242
  if [[ "$OFFLINE_RC" != 0 ]] || ! grep -qx 'MATCH=500' <<<"$got"; then
    echo "FAIL: offline walk did not find a present zygote64 against a fake /proc (rc=$OFFLINE_RC, got: $got)"
    RC=1
  else
    echo "ok: offline walk finds zygote64 by argv0 against a real fake-/proc read"
  fi

  rm -rf "${fake_proc:?}"/*
  mkdir -p "$fake_proc/4242" "$fake_proc/600"
  printf 'init\0' > "$fake_proc/4242/cmdline"
  printf 'system_server\0' > "$fake_proc/600/cmdline"
  offline system_server 4242
  if [[ "$OFFLINE_RC" != 0 ]] || ! grep -qx 'MATCH=600' <<<"$got"; then
    echo "FAIL: offline walk did not find a present system_server against a fake /proc (rc=$OFFLINE_RC, got: $got)"
    RC=1
  else
    echo "ok: offline walk finds system_server by argv0 against a real fake-/proc read"
  fi

  rm -rf "${fake_proc:?}"/*
  mkdir -p "$fake_proc/4242"
  printf 'init\0' > "$fake_proc/4242/cmdline"
  offline zygote64 4242
  if [[ "$OFFLINE_RC" != 0 ]] || ! grep -qx 'MATCH=' <<<"$got" || ! grep -qx 'UNREADABLE=0' <<<"$got"; then
    echo "FAIL: offline walk against neither process present did not read as a clean miss (rc=$OFFLINE_RC, got: $got)"
    RC=1
  else
    echo "ok: offline walk correctly misses when neither process is present"
  fi

  rm -rf "${fake_proc:?}"/*
  mkdir -p "$fake_proc/4242" "$fake_proc/700"
  printf 'init\0' > "$fake_proc/4242/cmdline"
  printf 'zygote64\0' > "$fake_proc/700/cmdline"
  chmod 000 "$fake_proc/700/cmdline"
  offline zygote64 4242
  chmod 644 "$fake_proc/700/cmdline"
  if [[ "$OFFLINE_RC" != 0 ]] || ! grep -qx 'MATCH=' <<<"$got" || grep -qx 'UNREADABLE=0' <<<"$got"; then
    echo "FAIL: offline walk did not count a denied cmdline read as unreadable (rc=$OFFLINE_RC, got: $got)"
    RC=1
  else
    echo "ok: offline walk counts a denied cmdline read as unreadable rather than as no-match"
  fi

  rm -rf "${fake_proc:?}"/*
  mkdir -p "$fake_proc/4242/ns" "$fake_proc/900/ns"
  printf 'init\0' > "$fake_proc/4242/cmdline"
  ln -s "pid:[4026531836]" "$fake_proc/4242/ns/pid"
  printf 'zygote64\0' > "$fake_proc/900/cmdline"
  ln -s "pid:[4026999999]" "$fake_proc/900/ns/pid"
  offline zygote64 4242
  if [[ "$OFFLINE_RC" != 0 ]] || ! grep -qx 'MATCH=' <<<"$got"; then
    echo "FAIL: offline walk counted a zygote64 outside init_pid's own pid namespace as a match (rc=$OFFLINE_RC, got: $got)"
    RC=1
  else
    echo "ok: offline walk ignores a matching process outside init_pid's own pid namespace"
  fi

  rm -rf "${fake_proc:?}"/*
  mkdir -p "$fake_proc/4242/ns" "$fake_proc/500"
  printf 'init\0' > "$fake_proc/4242/cmdline"
  ln -s "pid:[4026531836]" "$fake_proc/4242/ns/pid"
  printf 'zygote64\0' > "$fake_proc/500/cmdline"
  offline zygote64 4242
  if [[ "$OFFLINE_RC" != 0 ]] || ! grep -qx 'MATCH=500' <<<"$got"; then
    echo "FAIL: offline walk excluded a candidate whose own ns/pid link is unreadable while init_ns is readable (rc=$OFFLINE_RC, got: $got)"
    RC=1
  else
    echo "ok: offline walk does not exclude a candidate merely because ITS OWN ns/pid link is unreadable"
  fi

  rm -rf "${fake_proc:?}"/*
  mkdir -p "$fake_proc/1/ns" "$fake_proc/3000/ns"
  printf '/sbin/init\0' > "$fake_proc/1/cmdline"
  ln -s "pid:[4026531836]" "$fake_proc/1/ns/pid"
  printf 'zygote64\0' > "$fake_proc/3000/cmdline"
  ln -s "pid:[4026532999]" "$fake_proc/3000/ns/pid"
  offline zygote64 4242
  if [[ "$OFFLINE_RC" != 0 ]] || ! grep -qx 'NOINIT=1' <<<"$got" || ! grep -qx 'MATCH=' <<<"$got"; then
    echo "FAIL: offline walk against a nonexistent init_pid did not report NOINIT=1, even with /proc/1 present and a lingering zygote64 in another namespace (rc=$OFFLINE_RC, got: $got)"
    RC=1
  else
    echo "ok: offline walk reports NOINIT=1 instead of walking unfiltered when init_pid itself does not exist, even though /proc/1 is present"
  fi

  rm -rf "${fake_proc:?}"/*
  mkdir -p "$fake_proc/4242/ns" "$fake_proc/700/ns"
  printf 'init\0' > "$fake_proc/4242/cmdline"
  ln -s "pid:[4026531836]" "$fake_proc/4242/ns/pid"
  printf 'zygote64\0' > "$fake_proc/700/cmdline"
  ln -s "pid:[4026531836]" "$fake_proc/700/ns/pid"
  offline zygote64 4242 'readlink() { case "$1" in */700/ns/pid) rm -rf "'"$fake_proc"'/700" ;; esac; command readlink "$@"; }'
  if [[ "$OFFLINE_RC" != 0 ]] || ! grep -qx 'MATCH=' <<<"$got" || ! grep -qx 'UNREADABLE=0' <<<"$got"; then
    echo "FAIL: offline walk counted a pid that vanished mid-walk as UNREADABLE instead of skipping it (rc=$OFFLINE_RC, got: $got)"
    RC=1
  else
    echo "ok: offline walk skips a pid that vanished mid-walk rather than counting it as a denied read"
  fi

  rm -rf "$tmp"
}

# check the STAGE= line in explain-boot.sh
assert_stage_wiring() {
  local dir_arg="$1" src
  local f="$dir_arg/boot/explain-boot.sh"
  src=$(strip_comments "$f")
  if ! grep -q '^boot_stage()' <<<"$src"; then
    echo "FAIL: $f defines no boot_stage() function"; RC=1; return
  fi
  local stage_call_line stage_echo_line verdict_line
  stage_call_line=$(grep -n 'stage=\$(boot_stage' <<<"$src" | tail -1 | cut -d: -f1)
  stage_echo_line=$(grep -n '^[[:space:]]*echo "STAGE=\$stage"$' <<<"$src" | tail -1 | cut -d: -f1)
  verdict_line=$(grep -n 'verdict ANDROID_NOT_BOOTED' <<<"$src" | tail -1 | cut -d: -f1)
  if [[ -z "$stage_call_line" ]]; then
    echo "FAIL: $f's ANDROID_NOT_BOOTED path never calls boot_stage"; RC=1; return
  fi
  if [[ -z "$stage_echo_line" ]]; then
    echo "FAIL: $f's ANDROID_NOT_BOOTED path never prints an exact, uncommented 'echo \"STAGE=\$stage\"' line to stdout"
    RC=1; return
  fi
  if [[ -z "$verdict_line" ]]; then
    echo "FAIL: $f never reaches an ANDROID_NOT_BOOTED verdict at all"; RC=1; return
  fi
  if ! (( stage_call_line < stage_echo_line && stage_echo_line < verdict_line )); then
    echo "FAIL: $f prints STAGE= out of order against boot_stage/the verdict (lines $stage_call_line/$stage_echo_line/$verdict_line)"
    RC=1; return
  fi
  echo "ok: $f wires boot_stage into an exact STAGE=\$stage line before its ANDROID_NOT_BOOTED verdict"
}

# run the ANDROID_NOT_BOOTED tail with stubs
assert_android_not_booted_tail() {
  local dir_arg="$1" f block got
  f="$dir_arg/boot/explain-boot.sh"
  block=$(sed -n '/^stage=\$(boot_stage/,$p' "$f" | head -n -2)
  if [[ -z "$block" ]]; then
    echo "FAIL: $f has no stage=\$(boot_stage ... verdict ANDROID_NOT_BOOTED tail to extract"
    RC=1; return
  fi
  got=$(bash -c '
    set -uo pipefail
    init_pid=4242
    QUIET=0
    CPU_NOTE=""
    RHIZO_VM=999999
    boot_stage() { echo "procs:x($1) enforce:1"; }
    verdict() { :; }
    '"$block"'
  ' 2>&1)
  if [[ "$got" != 'STAGE=procs:x(4242) enforce:1' ]]; then
    echo "FAIL: $f's ANDROID_NOT_BOOTED tail produced '$got', expected 'STAGE=procs:x(4242) enforce:1'"
    RC=1; return
  fi
  echo "ok: $f's ANDROID_NOT_BOOTED tail passes \$init_pid through to boot_stage unchanged and prints STAGE= regardless of QUIET"
}

# run the boot-release.sh cause fold with stubs
assert_boot_release_fold() {
  local dir_arg="$1" block fixture got
  local f="$dir_arg/boot-release.sh"
  block=$(sed -n '/^cause=""$/,/^fi$/{/^[[:space:]]*#/d; p}' "$f")
  if [[ -z "$block" ]]; then
    echo "FAIL: $f has no cause=\"\"...fi block to extract the fold from"
    RC=1; return
  fi
  if ! grep -q 'cause="\$cause:' <<<"$block"; then
    echo "FAIL: $f's extracted block never folds a stage suffix onto cause"
    RC=1; return
  fi
  fixture="$(mktemp -d)"
  mkdir -p "$fixture/boot"
  cat > "$fixture/boot/explain-boot.sh" <<'SH'
#!/bin/bash
echo "CAUSE=ANDROID_NOT_BOOTED"
echo "STAGE=procs:zygote enforce:1"
SH
  chmod +x "$fixture/boot/explain-boot.sh"
  got=$(cd "$fixture" && bash -c '
    set -uo pipefail
    log() { :; }
    rc=1
    '"$block"'
    printf "%s" "$cause"
  ')
  rm -rf "$fixture"
  if [[ "$got" != "ANDROID_NOT_BOOTED:zygote" ]]; then
    echo "FAIL: $f's cause fold produced '\''$got'\'', expected 'ANDROID_NOT_BOOTED:zygote'"
    RC=1; return
  fi
  echo "ok: $f folds the process stage onto cause as ANDROID_NOT_BOOTED:zygote"
}

# check the boot-release.sh evidence collection call
assert_boot_release_call_site() {
  local dir_arg="$1" f fn block fixture calls got n expected
  f="$dir_arg/boot-release.sh"
  fn=$(sed -n '/^_boot_evidence_since_start() {/,/^}$/p' "$f")
  block=$(sed -n '/^boot_start_epoch=/,$p' "$f" | head -n -1)
  if [[ -z "$fn" || -z "$block" ]]; then
    echo "FAIL: $f has no _boot_evidence_since_start()/boot_start_epoch=...exit \$rc call site to extract"
    RC=1; return
  fi
  block="$fn"$'\n'"$block"

  _brc_fixture() {
    local dir="$1" body="$2"
    rm -rf "$dir"; mkdir -p "$dir/boot" "$dir/rig"
    printf '#!/bin/bash\n%s\n' "$body" > "$dir/redeploy.sh"
    cat > "$dir/boot/explain-boot.sh" <<'SH'
#!/bin/bash
echo "CAUSE=ANDROID_NOT_BOOTED"
echo "STAGE=procs:zygote enforce:1"
SH
    cat > "$dir/boot/collect-boot-evidence.sh" <<SH
#!/bin/bash
printf 'ARGC=%s ARGS=%s\n' "\$#" "\$*" >> "$dir/collect-calls.log"
mkdir -p "\$1/\$(date +%s%N)-collected"
exit 0
SH
    chmod +x "$dir"/*.sh "$dir"/boot/*.sh
    : > "$dir/collect-calls.log"
  }

  _brc_run() {
    local dir="$1"
    (cd "$dir" && bash -c '
      set -uo pipefail
      log() { :; }
      rig_boot_outcome() { :; }
      rig_vm_record_boot() { :; }
      RHIZO_VM=999999
      LABEL=a16
      VARIANT=user
      WIPE=auto
      DATA_STATE=x
      SUFFIX=""
      VAR_DIR="'"$dir"'"
      redeploy_args=()
      '"$block"'
    ' 2>&1)
  }

  fixture="$(mktemp -d)"
  _brc_fixture "$fixture" "exit 1"
  mkdir -p "$fixture/decoy-new-dir"
  touch -d "@$(( $(date +%s) + 3600 ))" "$fixture/decoy-new-dir"
  mkdir -p "$fixture/scratch/boot-failure/20200101T000000Z-old"
  touch -d '@1' "$fixture/scratch/boot-failure/20200101T000000Z-old"
  expected="ARGC=2 ARGS=$fixture/scratch/boot-failure ANDROID_NOT_BOOTED:zygote"
  got=$(_brc_run "$fixture")
  calls=$(cat "$fixture/collect-calls.log" 2>/dev/null)
  rm -rf "$fixture"
  n=$(grep -c '^ARGC=' <<<"${calls:-}")
  if [[ "$n" != 1 ]]; then
    echo "FAIL: $f's call site collected evidence $n time(s) for a boot with no bundle of its own (expected exactly 1) -- calls: ${calls:-<none>}, run output: $(tail -1 <<<"$got" | cut -c1-160)"
    RC=1; return
  fi
  if [[ "$calls" != "$expected" ]]; then
    echo "FAIL: $f's call site invoked collect-boot-evidence.sh wrong -- expected '$expected', got '$calls'"
    RC=1; return
  fi

  fixture="$(mktemp -d)"
  _brc_fixture "$fixture" 'mkdir -p "$PWD/scratch/boot-failure/$(date -u +%Y%m%dT%H%M%SZ)-new"
exit 1'
  got=$(_brc_run "$fixture")
  calls=$(cat "$fixture/collect-calls.log" 2>/dev/null)
  rm -rf "$fixture"
  if [[ -n "${calls:-}" ]]; then
    echo "FAIL: $f's call site collected evidence again when redeploy.sh already left a new bundle for this boot -- calls: $calls"
    RC=1; return
  fi

  echo "ok: $f's call site collects a boot-failure bundle exactly once, with the exact directory and cause, for a boot with none of its own, checking the SAME directory and epoch it hands to redeploy.sh, and skips it when a new one already exists"
}

# check _boot_evidence_since_start on three directories
assert_evidence_since_start() {
  local dir_arg="$1" fn d now
  local f="$dir_arg/boot-release.sh"
  fn=$(sed -n '/^_boot_evidence_since_start() {/,/^}$/p' "$f")
  if [[ -z "$fn" ]]; then
    echo "FAIL: $f defines no _boot_evidence_since_start() to tell this boot's own bundle apart from an older one"
    RC=1; return
  fi
  d="$(mktemp -d)"
  now=$(date +%s)

  if bash -c "$fn"$'\n'"_boot_evidence_since_start '$d/absent' '$now'"; then
    echo "FAIL: $f's _boot_evidence_since_start reported a bundle as this boot's in a directory that does not exist"
    RC=1; rm -rf "$d"; return
  fi

  mkdir -p "$d/old/20200101T000000Z-old"
  touch -d "@$(( now - 2 ))" "$d/old/20200101T000000Z-old"
  if bash -c "$fn"$'\n'"_boot_evidence_since_start '$d/old' '$now'"; then
    echo "FAIL: $f's _boot_evidence_since_start treated a bundle older than this boot's start as this boot's"
    RC=1; rm -rf "$d"; return
  fi

  mkdir -p "$d/new/20990101T000000Z-new"
  if ! bash -c "$fn"$'\n'"_boot_evidence_since_start '$d/new' '$now'"; then
    echo "FAIL: $f's _boot_evidence_since_start missed a bundle newer than this boot's start"
    RC=1; rm -rf "$d"; return
  fi

  rm -rf "$d"
  echo "ok: $f's _boot_evidence_since_start tells this boot's own bundle apart from an absent or older one"
}

# check boot-release.sh's collect-boot-evidence.sh call
assert_bundle_on_failure() {
  local dir_arg="$1" src test_block rc_block
  local f="$dir_arg/boot-release.sh"
  src=$(strip_comments "$f")
  if ! grep -q 'collect-boot-evidence\.sh' <<<"$src"; then
    echo "FAIL: $f never calls collect-boot-evidence.sh (outside a comment)"
    RC=1; return
  fi
  test_block=$(sed -n '/TEST_NAME:-}"[[:space:]]*]]; then/,/^fi$/p' <<<"$src")
  if [[ -z "$test_block" ]]; then
    echo "FAIL: $f has no non-comment 'if [[ -z \"\${TEST_NAME:-}\" ]]; then ... fi' block to find the non-test branch in"
    RC=1; return
  fi
  if ! grep -q 'collect-boot-evidence\.sh' <<<"$test_block"; then
    echo "FAIL: $f calls collect-boot-evidence.sh somewhere, but not inside the non-test ([-z \"\${TEST_NAME:-}\"]) branch"
    RC=1; return
  fi
  rc_block=$(sed -n '/rc != 0.*then/,/^  fi$/p' <<<"$test_block")
  if [[ -z "$rc_block" ]] || ! grep -q 'collect-boot-evidence\.sh' <<<"$rc_block"; then
    echo "FAIL: $f's non-test branch never system tests the evidence call inside its own 'if (( rc != 0 )); then ... fi'"
    RC=1; return
  fi
  echo "ok: $f collects a boot-failure bundle in its non-test, rc!=0 branch"
}

# check the CAUSE= output of explain-boot.sh
assert_lib_only_guard_scoped() {
  local dir_arg="$1" out
  out=$(RHIZO_EXPLAIN_BOOT_LIB_ONLY=1 RHIZO_VM=999999 \
        bash "$dir_arg/boot/explain-boot.sh" --quiet 2>/dev/null)
  if ! grep -q '^CAUSE=' <<<"$out"; then
    echo "FAIL: $dir_arg/boot/explain-boot.sh executed directly with RHIZO_EXPLAIN_BOOT_LIB_ONLY exported still produced no CAUSE= line (got: '${out:0:80}')"
    RC=1; return
  fi
  echo "ok: $dir_arg/boot/explain-boot.sh executed directly ignores an exported RHIZO_EXPLAIN_BOOT_LIB_ONLY and still prints a verdict"
}

# check the init pid scan on fixtures
assert_init_pid_detection() {
  local dir_arg="$1" f c body kind out want
  f="$dir_arg/boot/explain-boot.sh"
  c="$dir_arg/common.sh"
  if ! grep -qxF 'init_pid=$(guest_init_pid 10)' "$f"; then
    echo "FAIL: $f does not look up init through common.sh's guest_init_pid, the stack-cgroup scan: $(grep -m1 '^init_pid=' "$f")"
    RC=1; return
  fi
  body=$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${RHIZO_INIT_SCAN_BODY:-}"' _ "$c")
  if [[ -z "$body" ]]; then
    echo "FAIL: $c defines no RHIZO_INIT_SCAN_BODY for guest_init_pid to send"
    RC=1; return
  fi
  local proc; proc=$(mktemp -d)
  for kind in standin stack empty; do
    rm -rf "$proc"; mkdir -p "$proc"
    if [[ "$kind" != empty ]]; then
      mkdir -p "$proc/1200"
      printf '/system/bin/init\0second_stage\0' > "$proc/1200/cmdline"
      printf '0::/user.slice/user-1000.slice/session-3.scope\n' > "$proc/1200/cgroup"
    fi
    want=""
    if [[ "$kind" == stack ]]; then
      mkdir -p "$proc/4242"
      printf '/system/bin/init\0second_stage\0' > "$proc/4242/cmdline"
      printf '0::/rhizo/init\n' > "$proc/4242/cgroup"
      want=4242
    fi
    out=$(RHIZO_PROC_ROOT="$proc" bash -c "$body" 2>/dev/null | head -1)
    if [[ "$out" != "$want" ]]; then
      echo "FAIL: $c's init scan answered '$out' on the $kind fixture, want '$want'"
      RC=1; rm -rf "$proc"; return
    fi
  done
  rm -rf "$proc"
  echo "ok: $f looks init up through guest_init_pid, whose scan takes the stack's own init and never a stand-in carrying its argv"
}

# run all assertions against a directory
check_all() {
  dir_arg="$1"
  run_case "enforce not flipped, both procs running" "$dir_arg" \
    0 0 0 "$RUNNING" 0 "$RUNNING" "procs:system_server enforce:0"
  run_case "enforce read fails (rc=97)" "$dir_arg" \
    97 "" 0 "$NOT_RUNNING" 0 "" "procs:none enforce:unknown:enforce-read-failed(rc=97)"
  run_case "enforce unexpected value" "$dir_arg" \
    0 weird 0 "$NOT_RUNNING" 0 "" "procs:none enforce:unknown:enforce-unexpected-value(weird)"
  run_case "zygote not running" "$dir_arg" \
    0 1 0 "$NOT_RUNNING" 0 "" "procs:none enforce:1"
  run_case "zygote read fails (rc=124)" "$dir_arg" \
    0 1 124 "" 0 "" "procs:unknown:zygote-read-failed(rc=1) enforce:1"
  run_case "zygote cmdline unreadable" "$dir_arg" \
    0 1 0 "$UNREADABLE2" 0 "" "procs:unknown:zygote-cmdline-unreadable(n=2) enforce:1"
  run_case "zygote read truncated before the sentinel" "$dir_arg" \
    0 1 0 "$TRUNCATED" 0 "" "procs:unknown:zygote-read-failed(rc=1) enforce:1"
  run_case "init pid gone at read time (TOCTOU)" "$dir_arg" \
    0 1 0 "$NOINIT_OUT" 0 "" "procs:unknown:no-init enforce:1"
  run_case "system_server not running" "$dir_arg" \
    0 1 0 "$RUNNING" 0 "$NOT_RUNNING" "procs:zygote enforce:1"
  run_case "init pid gone before the system_server walk (TOCTOU)" "$dir_arg" \
    0 1 0 "$RUNNING" 0 "$NOINIT_OUT" "procs:unknown:no-init enforce:1"
  run_case "system_server read fails (rc=98)" "$dir_arg" \
    0 1 0 "$RUNNING" 98 "" "procs:unknown:system_server-read-failed(rc=1) enforce:1"
  run_case "system_server cmdline unreadable" "$dir_arg" \
    0 1 0 "$RUNNING" 0 "$UNREADABLE2" "procs:unknown:system_server-cmdline-unreadable(n=2) enforce:1"
  run_case "system_server running" "$dir_arg" \
    0 1 0 "$RUNNING" 0 "$RUNNING" "procs:system_server enforce:1"
  if [[ -n "$LAST_CALL_LOG" && -f "$LAST_CALL_LOG" ]]; then
    local calllog; calllog=$(cat "$LAST_CALL_LOG"); rm -f "$LAST_CALL_LOG"
    if ! grep -q 'CALL 2:.*"zygote64"' <<<"$calllog" || ! grep -q 'CALL 2:.*/FAKE_INIT_PID/ns/pid' <<<"$calllog"; then
      echo "FAIL: boot_stage's zygote query (call 2) does not match argv0 \"zygote64\" against init_pid's own ns/pid -- $(grep '^CALL 2:' <<<"$calllog" | cut -c1-220)"
      RC=1
    else
      echo "ok: boot_stage's zygote query asks for argv0 \"zygote64\" under init_pid's own namespace"
    fi
    if ! grep -q 'CALL 3:.*"system_server"' <<<"$calllog" || ! grep -q 'CALL 3:.*/FAKE_INIT_PID/ns/pid' <<<"$calllog"; then
      echo "FAIL: boot_stage's system_server query (call 3) does not match argv0 \"system_server\" against init_pid's own ns/pid -- $(grep '^CALL 3:' <<<"$calllog" | cut -c1-220)"
      RC=1
    else
      echo "ok: boot_stage's system_server query asks for argv0 \"system_server\" under init_pid's own namespace"
    fi
  else
    echo "FAIL: boot_stage's call arguments were not captured for the argv0/namespace assertions"
    RC=1
  fi
  assert_offline_walk "$dir_arg"
  assert_stage_wiring "$dir_arg"
  assert_android_not_booted_tail "$dir_arg"
  assert_boot_release_fold "$dir_arg"
  assert_boot_release_call_site "$dir_arg"
  assert_evidence_since_start "$dir_arg"
  assert_bundle_on_failure "$dir_arg"
  assert_lib_only_guard_scoped "$dir_arg"
  assert_init_pid_detection "$dir_arg"
}

if (( SELFTEST )); then
  FIXTURE="$(mktemp -d)"
  trap 'rm -rf "$FIXTURE"' EXIT
  GOOD="$FIXTURE/good"
  mkdir -p "$GOOD"
  cat > "$GOOD/common.sh" <<'SH'
#!/bin/bash
_ssh_vm_out() { return 1; }
ssh_vm() { local t=20; [[ "${1:-}" == -t ]] && { t="$2"; shift 2; }; timeout "$t" bash -c "$*"; }
guest_init_pid() { ssh_vm -t "${1:-10}" "$RHIZO_INIT_SCAN_BODY" 2>/dev/null | tr -d '\r' | head -1; }
SH
  grep '^RHIZO_INIT_SCAN_BODY=' "$(dirname "${BASH_SOURCE[0]}")/../../../vm/common.sh" >> "$GOOD/common.sh"
  mkdir -p "$GOOD/boot"
  cat > "$GOOD/boot/explain-boot.sh" <<'SH'
#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../common.sh
QUIET=0
verdict() { echo "CAUSE=$1"; exit 0; }

boot_stage() {  # print the boot stage and SELinux enforce value
  local init_pid="$1" out rc enforce procs pid unreadable

  out=$(_ssh_vm_out 8 'cat /sys/fs/selinux/enforce'); rc=$?
  if (( rc != 0 )); then
    enforce="unknown:enforce-read-failed(rc=$rc)"
  else
    case "$out" in
      0) enforce="0" ;;
      1) enforce="1" ;;
      *) enforce="unknown:enforce-unexpected-value(${out:-<empty>})" ;;
    esac
  fi

  out=$(_stage_pid_by_argv0 zygote64 "$init_pid"); rc=$?
  if (( rc != 0 )); then
    procs="unknown:zygote-read-failed(rc=$rc)"
  elif [[ "$(sed -n 's/^NOINIT=//p' <<<"$out")" == "1" ]]; then
    procs="unknown:no-init"
  else
    pid=$(sed -n 's/^MATCH=//p' <<<"$out")
    unreadable=$(sed -n 's/^UNREADABLE=//p' <<<"$out")
    if [[ -z "$pid" ]]; then
      if [[ "${unreadable:-0}" -gt 0 ]]; then
        procs="unknown:zygote-cmdline-unreadable(n=$unreadable)"
      else
        procs="none"
      fi
    else
      out=$(_stage_pid_by_argv0 system_server "$init_pid"); rc=$?
      if (( rc != 0 )); then
        procs="unknown:system_server-read-failed(rc=$rc)"
      elif [[ "$(sed -n 's/^NOINIT=//p' <<<"$out")" == "1" ]]; then
        procs="unknown:no-init"
      else
        pid=$(sed -n 's/^MATCH=//p' <<<"$out")
        unreadable=$(sed -n 's/^UNREADABLE=//p' <<<"$out")
        if [[ -z "$pid" ]]; then
          if [[ "${unreadable:-0}" -gt 0 ]]; then
            procs="unknown:system_server-cmdline-unreadable(n=$unreadable)"
          else
            procs="zygote"
          fi
        else
          procs="system_server"
        fi
      fi
    fi
  fi

  echo "procs:$procs enforce:$enforce"
}

_stage_pid_by_argv0() {  # find the process with the given argv0
  local argv0="$1" init_pid="$2" raw rc last_line
  raw=$(_ssh_vm_out 8 "root=\${RHIZO_STAGE_PROC_ROOT:-/proc}; \
    if [ ! -d \"\$root/$init_pid\" ]; then \
      echo \"MATCH=\"; echo \"UNREADABLE=0\"; echo \"NOINIT=1\"; echo __STAGE_END__; \
    else \
      init_ns=\$(readlink \"\$root/$init_pid/ns/pid\" 2>/dev/null); \
      unreadable=0; match=''; \
      for p in \"\$root\"/[0-9]*; do \
        pid=\${p##*/}; \
        if [ -n \"\$init_ns\" ]; then \
          pns=\$(readlink \"\$p/ns/pid\" 2>/dev/null); \
          [ -n \"\$pns\" ] && [ \"\$pns\" != \"\$init_ns\" ] && continue; \
        fi; \
        [ -e \"\$p\" ] || continue; \
        if [ -r \"\$p/cmdline\" ]; then \
          a0=\$(head -z -n1 \"\$p/cmdline\" 2>/dev/null | tr -d '\\0'); \
          [ \"\${a0##*/}\" = \"$argv0\" ] && { match=\"\$pid\"; break; }; \
        else \
          unreadable=\$((unreadable + 1)); \
        fi; \
      done; \
      echo \"MATCH=\$match\"; echo \"UNREADABLE=\$unreadable\"; echo \"NOINIT=0\"; echo __STAGE_END__; \
    fi")
  rc=$?
  if (( rc != 0 )); then
    return 1
  fi
  last_line="${raw##*$'\n'}"
  if [[ "$last_line" != "__STAGE_END__" ]]; then
    return 1
  fi
  printf '%s\n' "$raw"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" || -z "${RHIZO_EXPLAIN_BOOT_LIB_ONLY:-}" ]]; then

init_pid=$(guest_init_pid 10)
[[ -n "$init_pid" ]] || init_pid=1234
bc=""
stage=$(boot_stage "$init_pid")
echo "STAGE=$stage"
verdict ANDROID_NOT_BOOTED "fixture: boot_completed not set (furthest reached: ${stage})" \
  "the vm is fine; this is a guest-side boot problem -- check logcat via android_sh"

fi
SH
  cat > "$GOOD/boot-release.sh" <<'SH'
#!/bin/bash
set -uo pipefail
log() { :; }
rig_vm_record_boot() { :; }
RHIZO_VM=999999
LABEL=a16
VARIANT=user
WIPE=auto
DATA_STATE=x
SUFFIX=""
VAR_DIR="."
redeploy_args=()

_boot_evidence_since_start() {  # check for a recently modified subdirectory
  local d="$1" since="$2" sub mtime
  [[ -d "$d" ]] || return 1
  for sub in "$d"/*/; do
    [[ -d "$sub" ]] || continue
    mtime=$(stat -c %Y "$sub" 2>/dev/null) || continue
    (( mtime >= since )) && return 0
  done
  return 1
}

boot_start_epoch=$(date +%s)
RHIZO_WIPE_DATA="$WIPE" ./redeploy.sh "${redeploy_args[@]}"
rc=$?

cause=""
if (( rc != 0 )); then
  log "boot-release: the boot did not complete, explaining"
  explained=$(./boot/explain-boot.sh 2>&1)
  cause=$(sed -n 's/^CAUSE=//p' <<<"$explained")
  if [[ "$cause" == ANDROID_NOT_BOOTED ]]; then
    procs=$(sed -n 's/^STAGE=procs:\([^ ]*\).*/\1/p' <<<"$explained")
    [[ -n "$procs" ]] && cause="$cause:$procs"
  fi
  echo "$explained" >&2
fi
rig_vm_record_boot "$RHIZO_VM" "rc=$rc" "release=$LABEL" \
  "variant=$VARIANT" "wiped=$WIPE" "data_state=$DATA_STATE" ${cause:+"cause=$cause"}
if [[ -z "${TEST_NAME:-}" ]]; then
  if (( rc != 0 )); then
    ev_dir="${RHIZO_BOOT_EVIDENCE_DIR:-$VAR_DIR/scratch/boot-failure$SUFFIX}"
    if _boot_evidence_since_start "$ev_dir" "$boot_start_epoch"; then
      log "boot-release: a boot-failure bundle for this boot already sits under $ev_dir, not collecting a second"
    else
      ./boot/collect-boot-evidence.sh "$ev_dir" "$cause" >/dev/null
    fi
  fi
  rig_boot_outcome "$RHIZO_VM" "$( (( rc == 0 )) && echo PASSED || echo FAILED )" \
    ${cause:+"cause=$cause"} >/dev/null || echo "boot-release: boot record not updated" >&2
fi
exit $rc
SH
  chmod +x "$GOOD"/*.sh "$GOOD"/boot/*.sh

  echo "-- fixture: known-good copy (expect every assertion to pass) --"
  RC=0
  check_all "$GOOD"
  if (( RC != 0 )); then
    echo "SELFTEST FAIL: the known-good fixture did not pass cleanly"
    exit 1
  fi

  BADA="$FIXTURE/bad-fold-removed"
  cp -r "$GOOD" "$BADA"
  python3 - "$BADA/boot-release.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''  if [[ "$cause" == ANDROID_NOT_BOOTED ]]; then
    procs=$(sed -n 's/^STAGE=procs:\\([^ ]*\\).*/\\1/p' <<<"$explained")
    [[ -n "$procs" ]] && cause="$cause:$procs"
  fi
'''
if old not in s:
    sys.exit("SELFTEST FAIL: could not remove the fold to reintroduce seed A")
open(p, "w").write(s.replace(old, "", 1))
PY
  RC=0
  OUTA=$(check_all "$BADA" 2>&1)
  if [[ "$OUTA" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: removing the fold still looked clean"; exit 1
  fi
  if [[ "$OUTA" != *"never folds a stage suffix"* && "$OUTA" != *"cause fold produced"* ]]; then
    echo "SELFTEST FAIL: the removed fold was not named by the failure: $OUTA"; exit 1
  fi
  echo "selftest ok: seed A (fold removed) caught by name"

  BADB="$FIXTURE/bad-collect-unconditional"
  cp -r "$GOOD" "$BADB"
  python3 - "$BADB/boot-release.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''  if (( rc != 0 )); then
    ev_dir="${RHIZO_BOOT_EVIDENCE_DIR:-$VAR_DIR/scratch/boot-failure$SUFFIX}"
    if _boot_evidence_since_start "$ev_dir" "$boot_start_epoch"; then
      log "boot-release: a boot-failure bundle for this boot already sits under $ev_dir, not collecting a second"
    else
      ./boot/collect-boot-evidence.sh "$ev_dir" "$cause" >/dev/null
    fi
  fi
'''
new = '''  ev_dir="${RHIZO_BOOT_EVIDENCE_DIR:-$VAR_DIR/scratch/boot-failure$SUFFIX}"
  if _boot_evidence_since_start "$ev_dir" "$boot_start_epoch"; then
    log "boot-release: a boot-failure bundle for this boot already sits under $ev_dir, not collecting a second"
  else
    ./boot/collect-boot-evidence.sh "$ev_dir" "$cause" >/dev/null
  fi
'''
if old not in s:
    sys.exit("SELFTEST FAIL: could not un-test the collect call to reintroduce seed B")
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTB=$(check_all "$BADB" 2>&1)
  if [[ "$OUTB" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: un-gating the collect call still looked clean"; exit 1
  fi
  if [[ "$OUTB" != *"never system tests the evidence call inside its own"* ]]; then
    echo "SELFTEST FAIL: the un-gated collect call was not named by the failure: $OUTB"; exit 1
  fi
  echo "selftest ok: seed B (collect made unconditional) caught by name"

  BADC="$FIXTURE/bad-collect-commented"
  cp -r "$GOOD" "$BADC"
  sed -i 's/^      \.\/boot\/collect-boot-evidence\.sh.*/      : # &/' "$BADC/boot-release.sh"
  RC=0
  OUTC=$(check_all "$BADC" 2>&1)
  if [[ "$OUTC" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: commenting out the collect call still looked clean"; exit 1
  fi
  if [[ "$OUTC" != *"never calls collect-boot-evidence.sh (outside a comment)"* ]]; then
    echo "SELFTEST FAIL: the commented-out collect call was not named by the failure: $OUTC"; exit 1
  fi
  echo "selftest ok: seed C (collect line commented out) caught by name"

  BADD="$FIXTURE/bad-stage-devnull"
  cp -r "$GOOD" "$BADD"
  sed -i 's/echo "STAGE=\$stage"/echo "STAGE=$stage" >\/dev\/null/' "$BADD/boot/explain-boot.sh"
  RC=0
  OUTD=$(check_all "$BADD" 2>&1)
  if [[ "$OUTD" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: redirecting STAGE= to /dev/null still looked clean"; exit 1
  fi
  if [[ "$OUTD" != *"never prints an exact, uncommented"* ]]; then
    echo "SELFTEST FAIL: the redirected STAGE= line was not named by the failure: $OUTD"; exit 1
  fi
  echo "selftest ok: seed D (STAGE= redirected to /dev/null) caught by name"

  BADF="$FIXTURE/bad-stage-literal"
  cp -r "$GOOD" "$BADF"
  sed -i 's/echo "STAGE=\$stage"/echo "STAGE=procs:system_server enforce:1"/' "$BADF/boot/explain-boot.sh"
  RC=0
  OUTF=$(check_all "$BADF" 2>&1)
  if [[ "$OUTF" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: hardcoding the STAGE= line still looked clean"; exit 1
  fi
  if [[ "$OUTF" != *"never prints an exact, uncommented"* ]]; then
    echo "SELFTEST FAIL: the hardcoded STAGE= line was not named by the failure: $OUTF"; exit 1
  fi
  echo "selftest ok: seed F (STAGE= replaced by a literal) caught by name"

  BADG="$FIXTURE/bad-sentinel-removed"
  cp -r "$GOOD" "$BADG"
  python3 - "$BADG/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''  last_line="${raw##*$'\\n'}"
  if [[ "$last_line" != "__STAGE_END__" ]]; then
    return 1
  fi
  printf '%s\\n' "$raw"
  return 0
'''
new = '''  printf '%s\\n' "$raw"
  return 0
'''
if old not in s:
    sys.exit("SELFTEST FAIL: could not remove the sentinel check to reintroduce seed G")
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTG=$(check_all "$BADG" 2>&1)
  if [[ "$OUTG" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: removing the sentinel check still looked clean: $OUTG"; exit 1
  fi
  if [[ "$OUTG" != *"zygote read truncated before the sentinel"* ]]; then
    echo "SELFTEST FAIL: the removed sentinel check was not named by the failure: $OUTG"; exit 1
  fi
  echo "selftest ok: seed G (sentinel check removed) caught by name, via check_all's own TRUNCATED case"

  BADH="$FIXTURE/bad-namespace-filter-dropped"
  cp -r "$GOOD" "$BADH"
  python3 - "$BADH/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''      if [ -n \\"\\$init_ns\\" ]; then \\'''
new = '''      if false; then \\'''
if old not in s:
    sys.exit("SELFTEST FAIL: could not drop the pid-namespace filter to reintroduce seed H")
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTH=$(check_all "$BADH" 2>&1)
  if [[ "$OUTH" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: dropping the pid-namespace filter still looked clean: $OUTH"; exit 1
  fi
  if [[ "$OUTH" != *"outside init_pid's own pid namespace as a match"* ]]; then
    echo "SELFTEST FAIL: the dropped namespace filter was not named by the failure: $OUTH"; exit 1
  fi
  echo "selftest ok: seed H (pid-namespace filter dropped) caught by name"

  BADI="$FIXTURE/bad-since-start-inverted"
  cp -r "$GOOD" "$BADI"
  sed -i 's/(( mtime >= since )) && return 0/(( mtime < since )) \&\& return 0/' "$BADI/boot-release.sh"
  RC=0
  OUTI=$(check_all "$BADI" 2>&1)
  if [[ "$OUTI" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: inverting the since-start check still looked clean: $OUTI"; exit 1
  fi
  echo "selftest ok: seed I (evidence since-start check inverted) caught: $(grep -m1 FAIL <<<"$OUTI" | cut -c1-160)"

  BADJ="$FIXTURE/bad-guard-leaks"
  cp -r "$GOOD" "$BADJ"
  sed -i 's/\[\[ "\${BASH_SOURCE\[0\]}" == "\$0" || -z "\${RHIZO_EXPLAIN_BOOT_LIB_ONLY:-}" \]\]/[[ -z "${RHIZO_EXPLAIN_BOOT_LIB_ONLY:-}" ]]/' "$BADJ/boot/explain-boot.sh"
  RC=0
  OUTJ=$(check_all "$BADJ" 2>&1)
  if [[ "$OUTJ" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: an unscoped lib-only guard still looked clean: $OUTJ"; exit 1
  fi
  echo "selftest ok: seed J (lib-only guard leaks from the environment) caught: $(grep -m1 FAIL <<<"$OUTJ" | cut -c1-160)"

  BADK="$FIXTURE/bad-wrong-zygote-argv0"
  cp -r "$GOOD" "$BADK"
  python3 - "$BADK/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '_stage_pid_by_argv0 zygote64 "$init_pid"'
new = '_stage_pid_by_argv0 app_process64 "$init_pid"'
if s.count(old) != 1:
    sys.exit("SELFTEST FAIL: could not find the zygote64 argv0 call to mutate for seed K (count=%d)" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTK=$(check_all "$BADK" 2>&1)
  if [[ "$OUTK" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: matching zygote by app_process64 instead of zygote64 still looked clean"; exit 1
  fi
  if [[ "$OUTK" != *'does not match argv0 "zygote64"'* ]]; then
    echo "SELFTEST FAIL: the wrong zygote argv0 was not named by the failure: $OUTK"; exit 1
  fi
  echo "selftest ok: seed K (zygote matched by app_process64 instead of zygote64) caught by name"

  BADL="$FIXTURE/bad-hardcoded-init-pid"
  cp -r "$GOOD" "$BADL"
  python3 - "$BADL/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'stage=$(boot_stage "$init_pid")'
new = 'stage=$(boot_stage 1)'
if s.count(old) != 1:
    sys.exit("SELFTEST FAIL: could not find the boot_stage call to mutate for seed L (count=%d)" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTL=$(check_all "$BADL" 2>&1)
  if [[ "$OUTL" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: hardcoding boot_stage's init_pid argument still looked clean"; exit 1
  fi
  if [[ "$OUTL" != *"ANDROID_NOT_BOOTED tail produced"* ]]; then
    echo "SELFTEST FAIL: the hardcoded init_pid argument was not named by the failure: $OUTL"; exit 1
  fi
  echo "selftest ok: seed L (boot_stage called with a hardcoded pid instead of \$init_pid) caught by name"

  BADM="$FIXTURE/bad-stage-quiet-gated"
  cp -r "$GOOD" "$BADM"
  python3 - "$BADM/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'echo "STAGE=$stage"\n'
new = 'if (( QUIET )); then\n  echo "STAGE=$stage"\nfi\n'
if s.count(old) != 1:
    sys.exit("SELFTEST FAIL: could not find the STAGE= echo to mutate for seed M (count=%d)" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTM=$(check_all "$BADM" 2>&1)
  if [[ "$OUTM" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: gating STAGE= on QUIET still looked clean"; exit 1
  fi
  if [[ "$OUTM" != *"ANDROID_NOT_BOOTED tail produced"* ]]; then
    echo "SELFTEST FAIL: the QUIET-gated STAGE= line was not named by the failure: $OUTM"; exit 1
  fi
  echo "selftest ok: seed M (STAGE= wrapped in an 'if (( QUIET ))' boot-release.sh never satisfies) caught by name"

  BADN="$FIXTURE/bad-epoch-zeroed"
  cp -r "$GOOD" "$BADN"
  sed -i 's/^boot_start_epoch=\$(date +%s)$/boot_start_epoch=0/' "$BADN/boot-release.sh"
  RC=0
  OUTN=$(check_all "$BADN" 2>&1)
  if [[ "$OUTN" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: zeroing boot_start_epoch still looked clean"; exit 1
  fi
  if [[ "$OUTN" != *"call site collected evidence"* ]]; then
    echo "SELFTEST FAIL: the zeroed epoch was not named by the failure: $OUTN"; exit 1
  fi
  echo "selftest ok: seed N (boot_start_epoch forced to 0) caught by name"

  BADO="$FIXTURE/bad-collect-extra-flag"
  cp -r "$GOOD" "$BADO"
  sed -i 's#\./boot/collect-boot-evidence\.sh "\$ev_dir" "\$cause"#./boot/collect-boot-evidence.sh --guard-only "$ev_dir" "$cause"#' "$BADO/boot-release.sh"
  RC=0
  OUTO=$(check_all "$BADO" 2>&1)
  if [[ "$OUTO" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: adding an extra flag to the collect call still looked clean"; exit 1
  fi
  if [[ "$OUTO" != *"invoked collect-boot-evidence.sh wrong"* ]]; then
    echo "SELFTEST FAIL: the extra collect flag was not named by the failure: $OUTO"; exit 1
  fi
  echo "selftest ok: seed O (an extra flag added to the collect-boot-evidence.sh call) caught by name"

  BADP="$FIXTURE/bad-since-start-widened"
  cp -r "$GOOD" "$BADP"
  sed -i 's/(( mtime >= since )) && return 0/(( mtime + 3000 >= since )) \&\& return 0/' "$BADP/boot-release.sh"
  RC=0
  OUTP=$(check_all "$BADP" 2>&1)
  if [[ "$OUTP" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: widening the since-start tolerance still looked clean"; exit 1
  fi
  echo "selftest ok: seed P (since-start comparison widened by 3000s) caught: $(grep -m1 FAIL <<<"$OUTP" | cut -c1-160)"

  BADQ="$FIXTURE/bad-since-start-wrong-dir"
  cp -r "$GOOD" "$BADQ"
  sed -i 's/if _boot_evidence_since_start "\$ev_dir" "\$boot_start_epoch"; then/if _boot_evidence_since_start "$REPO" "$boot_start_epoch"; then/' "$BADQ/boot-release.sh"
  RC=0
  OUTQ=$(check_all "$BADQ" 2>&1)
  if [[ "$OUTQ" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: pointing the since-start check at REPO instead of ev_dir still looked clean"; exit 1
  fi
  if [[ "$OUTQ" != *"call site collected evidence"* ]]; then
    echo "SELFTEST FAIL: the wrong since-start directory was not named by the failure: $OUTQ"; exit 1
  fi
  echo "selftest ok: seed Q (since-start check pointed at REPO instead of ev_dir) caught by name"

  BADR="$FIXTURE/bad-collect-never"
  cp -r "$GOOD" "$BADR"
  sed -i 's/if (( rc != 0 )); then/if (( rc != 0 \&\& 0 )); then/' "$BADR/boot-release.sh"
  RC=0
  OUTR=$(check_all "$BADR" 2>&1)
  if [[ "$OUTR" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: short-circuiting the collect condition still looked clean"; exit 1
  fi
  if [[ "$OUTR" != *"call site collected evidence"* ]]; then
    echo "SELFTEST FAIL: the short-circuited collect condition was not named by the failure: $OUTR"; exit 1
  fi
  echo "selftest ok: seed R (collect gated on 'rc != 0 && 0') caught by name"

  BADS="$FIXTURE/bad-candidate-ns-guard-dropped"
  cp -r "$GOOD" "$BADS"
  python3 - "$BADS/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''          [ -n \\"\\$pns\\" ] && [ \\"\\$pns\\" != \\"\\$init_ns\\" ] && continue; \\'''
new = '''          [ \\"\\$pns\\" != \\"\\$init_ns\\" ] && continue; \\'''
if old not in s:
    sys.exit("SELFTEST FAIL: could not drop the candidate ns guard to reintroduce seed S")
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTS=$(check_all "$BADS" 2>&1)
  if [[ "$OUTS" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: dropping the candidate's own ns/pid guard still looked clean"; exit 1
  fi
  if [[ "$OUTS" != *"own ns/pid link is unreadable"* ]]; then
    echo "SELFTEST FAIL: the dropped candidate ns guard was not named by the failure: $OUTS"; exit 1
  fi
  echo "selftest ok: seed S (a candidate's own unreadable ns/pid link wrongly excludes it) caught by name"

  BADT="$FIXTURE/bad-pgrep-self-match"
  cp -r "$GOOD" "$BADT"
  python3 - "$BADT/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''init_pid=$(guest_init_pid 10)'''
new = '''init_pid=$(ssh_vm -t 10 'pgrep -f "init second_stage" | head -1' 2>/dev/null | tr -d '\\r\\n')'''
if old not in s:
    sys.exit("SELFTEST FAIL: could not find the init-pid line to revert for seed T")
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTT=$(check_all "$BADT" 2>&1)
  if [[ "$OUTT" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: reverting to pgrep -f self-match still looked clean"; exit 1
  fi
  if [[ "$OUTT" != *"does not look up init through common.sh's guest_init_pid"* ]]; then
    echo "SELFTEST FAIL: the reverted pgrep -f lookup was not named by the failure: $OUTT"; exit 1
  fi
  echo "selftest ok: seed T (init-pid detection reverted to a pgrep -f name match) caught by name"

  BADU="$FIXTURE/bad-vanish-guard-dropped"
  cp -r "$GOOD" "$BADU"
  python3 - "$BADU/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''        [ -e \\"\\$p\\" ] || continue; \\\n'''
if old not in s:
    sys.exit("SELFTEST FAIL: could not find the vanish-mid-walk guard to drop for seed U")
open(p, "w").write(s.replace(old, "", 1))
PY
  RC=0
  OUTU=$(check_all "$BADU" 2>&1)
  if [[ "$OUTU" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: dropping the vanish-mid-walk guard still looked clean"; exit 1
  fi
  if [[ "$OUTU" != *"vanished mid-walk"* ]]; then
    echo "SELFTEST FAIL: the dropped vanish-mid-walk guard was not named by the failure: $OUTU"; exit 1
  fi
  echo "selftest ok: seed U (a pid vanishing mid-walk miscounted as a denied read) caught by name"

  BADV="$FIXTURE/bad-noinit-hardcoded-proc1"
  cp -r "$GOOD" "$BADV"
  python3 - "$BADV/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''    if [ ! -d \\"\\$root/$init_pid\\" ]; then \\
'''
new = '''    if [ ! -d \\"\\$root/1\\" ]; then \\
'''
if s.count(old) != 1:
    sys.exit("SELFTEST FAIL: could not find the NOINIT dir test to hardcode for seed V (count=%d)" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTV=$(check_all "$BADV" 2>&1)
  if [[ "$OUTV" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: hardcoding the NOINIT dir test to /proc/1 still looked clean"; exit 1
  fi
  if [[ "$OUTV" != *"did not report NOINIT=1"* ]]; then
    echo "SELFTEST FAIL: the hardcoded NOINIT test was not named by the failure: $OUTV"; exit 1
  fi
  echo "selftest ok: seed V (offline-walk NOINIT test hardcoded to /proc/1 instead of \$init_pid) caught by name"

  BADW="$FIXTURE/bad-ss-noinit-dropped"
  cp -r "$GOOD" "$BADW"
  python3 - "$BADW/boot/explain-boot.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''      elif [[ "$(sed -n 's/^NOINIT=//p' <<<"$out")" == "1" ]]; then
        procs="unknown:no-init"
      else
'''
new = '''      else
'''
if s.count(old) != 1:
    sys.exit("SELFTEST FAIL: could not find the system_server NOINIT branch to drop for seed W (count=%d)" % s.count(old))
open(p, "w").write(s.replace(old, new, 1))
PY
  RC=0
  OUTW=$(check_all "$BADW" 2>&1)
  if [[ "$OUTW" != *"FAIL:"* ]]; then
    echo "SELFTEST FAIL: dropping the system_server NOINIT branch still looked clean"; exit 1
  fi
  if [[ "$OUTW" != *"boot_stage init pid gone before the system_server walk"* ]]; then
    echo "SELFTEST FAIL: the dropped system_server NOINIT branch was not named by the failure: $OUTW"; exit 1
  fi
  echo "selftest ok: seed W (system_server walk's NOINIT branch dropped, reading procs:zygote instead of unknown:no-init) caught by name"

  echo "selftest ok: every seed is caught by name and the known-good fixture stays clean"
  exit 0
fi

[[ -n "$TOOLS_DIR" ]] || { echo "explain-boot-stage.sh: --tools-dir is required (or pass --selftest)" >&2; exit 2; }
[[ -r "$TOOLS_DIR/boot/explain-boot.sh" ]] || { echo "FAIL: cannot read $TOOLS_DIR/boot/explain-boot.sh"; exit 1; }
[[ -r "$TOOLS_DIR/common.sh" ]] || { echo "FAIL: cannot read $TOOLS_DIR/common.sh"; exit 1; }
[[ -r "$TOOLS_DIR/boot-release.sh" ]] || { echo "FAIL: cannot read $TOOLS_DIR/boot-release.sh"; exit 1; }

check_all "$TOOLS_DIR"
if (( RC == 0 )); then
  echo "ok: explain-boot.sh's ANDROID_NOT_BOOTED catch-all names a STAGE via the real call site, every read's status is checked (including the offline /proc walk, a mid-walk vanish, and init_pid itself going missing), the init-pid detection cannot self-match its own shell, boot-release.sh's real call site folds only the process stage, checks the right directory and epoch, and collects the evidence once per boot on a plain failed boot, and the lib-only guard cannot leak from the environment"
fi
exit $RC
