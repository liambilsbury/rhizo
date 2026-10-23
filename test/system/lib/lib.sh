#!/bin/bash
# define the system test verdicts, evidence dirs, steps and exit trap
# shellcheck disable=SC2034

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TEARDOWN=0
TEST_NO_VM=0
TEST_WORKDIR=""
TEST_NESTED=0
TEST_BOOT_FAULT=""
TEST_BOOTED=""

# print the evidence dir of a test
test_evidence_dir() {
  local name="$1" variant="${2:-}" token=""
  [[ -n "$variant" && "$variant" != user ]] && token="-$variant"
  echo "$VAR_DIR/scratch/$name$token${SUFFIX:--0}"
}

# print the evidence dir of a nested test
test_nested_evidence_dir() {
  echo "$(test_evidence_dir "$1")/nested-from-$(basename "${RHIZO_TEST_INVOKED:-$0}")"
}

# record a failed verdict and kill the vm on exit
test_cleanup() {
  local rc=$?
  [[ -n "${TEST_EXTRA_CLEANUP:-}" ]] && "$TEST_EXTRA_CLEANUP"
  if (( rc != 0 )) && (( TEST_VERDICT_RECORDED == 0 )) && [[ -n "${EV:-}" ]]; then
    test_record_verdict FAILED "exit=$rc"
  fi
  [[ -n "$TEST_WORKDIR" ]] && rm -rf "$TEST_WORKDIR"
  if (( TEST_NO_VM == 0 )) && { (( TEST_TEARDOWN )) || (( rc >= 128 )); }; then
    kill_vm
  fi
  return $rc
}

# set up a system test
test_init() {
  local name="$1" variant="" root=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --variant)       variant="$2"; shift 2 ;;
      --evidence-root) root="$2"; shift 2 ;;
      --teardown)      TEST_TEARDOWN=1; shift ;;
      --no-vm)         TEST_NO_VM=1; shift ;;
      *) echo "test_init: unknown argument $1" >&2; return 2 ;;
    esac
  done

  : "${RHIZO_TEST_INVOKED:=$0}"
  export RHIZO_TEST_INVOKED
  TEST_NESTED=0
  [[ "$RHIZO_TEST_INVOKED" == "$0" ]] || TEST_NESTED=1

  if [[ -n "$root" ]]; then
    EV="$root"
  else
    EV="$(test_evidence_dir "$name" "$variant")"
  fi
  (( TEST_NESTED )) && EV="$EV/nested-from-$(basename "$RHIZO_TEST_INVOKED")"
  mkdir -p "$EV" || return 1
  : > "$EV/failures.log"
  TEST_NAME="$name"
  TEST_WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/test-$name${SUFFIX}.XXXXXX") || return 1

  FAILED=0
  STEP_MARK=0
  TEST_VERDICT_RECORDED=0
  test_trap_signals
  rig_test_started
  trap test_cleanup EXIT
}

source "$(dirname "${BASH_SOURCE[0]}")/../../vm/image/release-map.sh"

# wait for systemd to leave starting
wait_for_guest_ready() {
  local deadline_s="${1:-120}" start state jobs
  local jobs_ev=""
  if [[ -n "${EV:-}" && -d "${EV:-}" ]]; then
    jobs_ev="$EV/wait-guest-ready-jobs.txt"
    [[ "${_WGR_EV_OPENED:-}" == "$jobs_ev" ]] || { echo '<none>' > "$jobs_ev"; _WGR_EV_OPENED=$jobs_ev; }
  fi
  start=$(date +%s)
  while true; do
    state=$(ssh_vm -t 10 'systemctl is-system-running 2>/dev/null' | tr -d '[:space:]')
    case "$state" in
      running|degraded)
        log "guest ready ($state) after $(( $(date +%s) - start ))s"
        return 0 ;;
    esac
    if (( $(date +%s) - start > deadline_s )); then
      log "guest still '${state:-unreachable}' after ${deadline_s}s"
      if [[ -n "$jobs_ev" ]]; then
        jobs=$(ssh_vm -t 15 'systemctl list-jobs --no-pager 2>&1; echo "--- is-system-running"; systemctl is-system-running 2>&1')
        [[ "$(cat "$jobs_ev" 2>/dev/null)" == '<none>' ]] && : > "$jobs_ev"
        printf '=== %s: still %s after %ss\n%s\n' "$(date -u +%FT%TZ)" "${state:-unreachable}" "$deadline_s" "${jobs:-<none>}" >> "$jobs_ev"
        log "  its pending jobs: $jobs_ev"
      fi
      return 1
    fi
    sleep 2
  done
}

GUEST_LOOP_MAX_READ='cat /sys/module/loop/parameters/max_loop 2>/dev/null || sed -n "s/^\(.* \)\?loop\.max_loop=\([0-9]*\).*/\2/p" /proc/cmdline'

# boot a new guest and check it is ready
test_boot() {
  TEST_BOOT_FAULT=""
  TEST_BOOT_NO_ROW=""
  test_require_staged RhizoAudioRouter.apk RhizoBootRro.apk RhizoSoftwareRro.apk RhizoHome.apk RhizoDesktop.apk || return 1
  local do_preflight=1 preflight_args=(--redeploy-follows) release=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-preflight) do_preflight=0; shift ;;
      --skip-graphics-preflight) preflight_args+=(--skip-graphics); shift ;;
      --release) release="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  [[ -n "${EV:-}" ]] && export RHIZO_BOOT_EVIDENCE_DIR="$EV/boot-failure"
  if [[ -n "$release" ]]; then
    if ! release_known "$release"; then
      fail "test_boot: unknown release '$release' -- known: ${RELEASE_LABELS[*]}"
      return 1
    fi
    if ! "$REPO/tools/build/release.sh" "$release" >&2; then
      fail "test_boot: $release needs something built first -- see the command named above"
      return 1
    fi
    [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]] || export RHIZO_KERNEL="${GSI_KERNEL[$release]}"
    if [[ "$release" != "a16" ]]; then
      export RHIZO_GSI="${GSI_DIR[$release]}" RHIZO_RELEASE="$release"
      preflight_args+=(--skip-gsi-tree)
    fi
  fi
  if [[ "${RHIZO_SKIP_BOOT:-0}" == 1 ]]; then
    log "chained onto the existing guest on vm $RHIZO_VM (RHIZO_SKIP_BOOT=1)"
    if ! wait_for_ssh 60; then
      fail "chained onto vm $RHIZO_VM but it is not reachable"
      "$REPO/test/vm/boot/explain-boot.sh" >&2
      test_collect_boot_evidence "chain-vm-unreachable"
      return 1
    fi
    TEST_BOOTED=1
    return 0
  fi
  if [[ "${RHIZO_TEST_INSTALLED:-0}" == 1 ]]; then
    fail "test_boot: RHIZO_TEST_INSTALLED=1 needs RHIZO_SKIP_BOOT=1; a rig boot replaces the installed deploy"
    return 1
  fi
  local boot_id_before=""
  boot_id_before=$(ssh_vm -t 8 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]')
  kill_vm
  boot_vm

  if ! wait_for_boot_slot; then
    fail "test_boot: vm $RHIZO_VM is still queued for a qemu slot"
    test_collect_boot_evidence "test-vm-queued-for-slot"
    return 1
  fi
  if ! wait_for_ssh 300; then
    if [[ -n "$RHIZO_BOOT_REFUSAL" ]]; then
      fail "test_boot: vm $RHIZO_VM was refused before any guest launched: $RHIZO_BOOT_REFUSAL"
      [[ -z "${TEST_BOOTED:-}" ]] && TEST_BOOT_NO_ROW=1
      test_collect_boot_evidence "test-vm-refused"
      return 1
    fi
    fail "test_boot: vm $RHIZO_VM never came up, see the CAUSE= line below"
    "$REPO/test/vm/boot/explain-boot.sh" >&2
    test_collect_boot_evidence "test-vm-never-came-up"
    return 1
  fi
  TEST_BOOTED=1
  if ! wait_for_guest_ready 120; then
    fail "test_boot: vm $RHIZO_VM answered ssh but systemd never left 'starting' within 120s"
    test_collect_boot_evidence "test-vm-never-ready"
    return 1
  fi
  if [[ -n "$boot_id_before" ]]; then
    local boot_id_after
    boot_id_after=$(ssh_vm -t 10 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$boot_id_after" || "$boot_id_after" == "$boot_id_before" ]]; then
      fail "test_boot: vm $RHIZO_VM still carries boot_id $boot_id_before"
      test_collect_boot_evidence "test-vm-not-replaced"
      return 1
    fi
    log "boot_id $boot_id_before -> $boot_id_after (a real replacement, not a reconnect)"
  fi
  if (( do_preflight )); then
    local preflight_out preflight_rc
    preflight_out="$(mktemp "${TMPDIR:-/tmp}/rhizo-preflight-XXXXXX")" || {
      fail "test_boot: mktemp failed for the preflight capture"
      return 1
    }
    "$REPO/test/vm/boot/preflight.sh" --quiet "${preflight_args[@]}" > "$preflight_out" 2>&1
    preflight_rc=$?
    cat "$preflight_out" >&2
    if (( preflight_rc != 0 )); then
      fail "test_boot: vm $RHIZO_VM booted but failed preflight, see above"
      RHIZO_PREFLIGHT_EVIDENCE="$preflight_out" test_collect_boot_evidence "test-preflight-failed"
      rm -f "$preflight_out"
      return 1
    fi
    rm -f "$preflight_out"
  fi
}

# save the guest's account of a failed boot
test_collect_boot_evidence() {
  TEST_BOOT_FAULT="$1"
  RHIZO_BOOT_NO_ROW="${TEST_BOOT_NO_ROW:-}" "$REPO/test/vm/boot/collect-boot-evidence.sh" \
    "${EV:-$VAR_DIR/scratch/boot-failure$SUFFIX}/boot-failure" "$1"
}

TEST_FATAL_RE='\*\*\* WATCHDOG KILLING SYSTEM PROCESS|FATAL EXCEPTION|Fatal signal [0-9]+ \(SIG|JNI FatalError|\*\*\* \*\*\* \*\*\*|^[^[:space:]]+ +[^[:space:]]+ +[0-9]+ +[0-9]+ F '
TEST_WATCHDOG_KILL_RE='\*\*\* WATCHDOG KILLING SYSTEM PROCESS'

# print the first fatal lines of a log, five by default
test_fatal_lines() { grep -E "$TEST_FATAL_RE" "$1" 2>/dev/null | head -"${2:-5}"; }

# succeed only when a logcat capture holds a threadtime line
test_logcat_capture_read() {
  grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' "$1"
}

TEST_CRASH_EVENT_GAP_S=2
# count a logcat's fatal events
test_crash_events() {
  grep -E "$TEST_FATAL_RE" "$1" \
    | awk '{
        if ($0 ~ /^[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9] /)
          printf "%.3f\n", (substr($0, 1, 2) * 31 + substr($0, 4, 2)) * 86400 \
            + substr($0, 7, 2) * 3600 + substr($0, 10, 2) * 60 + substr($0, 13, 6)
        else
          print "untimed"
      }' \
    | LC_ALL=C sort -n \
    | awk -v gap="$TEST_CRASH_EVENT_GAP_S" '
        $1 == "untimed" { untimed = 1; next }
        !n || $1 - last > gap { n++ }
        { last = $1 }
        END { print (n ? n : untimed) + 0 }'
}

# count, log and record a failure
fail() {
  log "FAIL: $*"
  FAILED=$((FAILED + 1))
  [[ -n "$EV" ]] && printf '%s\tstep=%s\tFAIL: %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TEST_STEP:-<none>}" "${*//$'\n'/ | }" >> "$EV/failures.log"
  if [[ "${RHIZO_TEST_FAIL_FAST:-0}" == 1 && "$BASH_SUBSHELL" == 0 ]] \
     && [[ -n "${TEST_EXTRA_CLEANUP:-}" || "${TEST_FAIL_FAST_SAFE:-}" == 1 ]]; then
    log "    stopping at the first failure (RHIZO_TEST_FAIL_FAST=0 runs every leg)"
    exit 1
  fi
  return 0
}
# start and log a step
step() { STEP_MARK=$FAILED; TEST_STEP="$*"; log "=== $*"; }
# log a passed assertion
pass() { log "  ok: $*"; return 0; }
# log a step that was not run and why
skip() { log "  NOT RUN: $*"; }

# print a scratch log path under $EV
test_scratch_log() { echo "$EV/$1.log"; }

# print the file of a named system test
system_test_file() {
  python3 "$(dirname "${BASH_SOURCE[0]}")/../run/system_tests.py" --path "$1"
}

# print a system test's contract headers
test_print_contract() {
  local file="$1"
  [[ -r "$file" || "$file" == /* ]] \
    || file=$(python3 "$(dirname "${BASH_SOURCE[0]}")/../run/system_tests.py" --path "$(basename "$file")" 2>/dev/null) || return 1
  [[ -r "$file" ]] || return 1
  awk '
    /^# test-boot-mode:/       { sub(/^# test-boot-mode: */,""); split($0,a," "); bm=a[1] }
    /^# test-boots-unit:/      { sub(/^# test-boots-unit: */,""); split($0,a," "); bu=a[1] }
    /^# test-nests:/           { sub(/^# test-nests: */,""); split($0,a," "); n=a[1] }
    /^# test-records-metrics:/ { sub(/^# test-records-metrics: */,""); split($0,a," "); rm=a[1] }
    /^# test-verdict-params:/  { vp=$0; sub(/^# test-verdict-params: */,"",vp); sub(/ -- .*/,"",vp) }
    /^# test-requires:/        { gr=$0; sub(/^# test-requires: */,"",gr); sub(/ -- .*/,"",gr) }
    END {
      if (bm == "") { exit 1 }
      printf "boot_mode=%s\tboots_unit=%s\tnests=%s\trecords_metrics=%s\tverdict_params=%s\ttest_requires=%s\n", \
        bm, (bu==""?"na":bu), (n==""||n=="none"?"-":n), (rm==""?"no":rm), (vp==""?"-":vp), (gr==""?"undeclared":gr)
    }
  ' "$file"
}

# start a desktop session when a chained boot has none
test_ensure_desktop() {
  local session_log="$1" restart_log="$2"
  if desk_windows >/dev/null 2>&1; then
    log "  compositor: the desktop session is up on the chained boot"
    return 0
  fi
  log "  compositor: the chain's leader started no desktop session -- starting it and restarting the stack under it"
  local up=0
  desk_session_up --stage-login >"$session_log" 2>&1 && up=1
  test_unstage_seat_login >>"$session_log" 2>&1 \
    || { fail "the seat login this chain staged is still on the vm's disk (see $session_log)"; exit 1; }
  (( up )) || { fail "the desktop session did not start (see $session_log)"; exit 1; }
  test_publish_session_env >>"$session_log" 2>&1 \
    || { fail "the login session's socket was not published for the restarted stack (see $session_log)"; exit 1; }
  test_restart_stack "$restart_log" || { fail "the stack did not come back under the compositor (see $restart_log)"; exit 1; }
}

# write /run/rhizo-desktop/session.env for the running session
test_publish_session_env() {
  local sock uid out script
  sock=$(desk_socket_path 2>/dev/null | tr -d '\r')
  [[ "$sock" =~ ^/run/user/([0-9]+)/wayland-[0-9]+$ ]] || { log "    no session socket to publish (got '${sock:-<none>}')"; return 1; }
  uid=${BASH_REMATCH[1]}
  script='S=$1; R=$(dirname "$S"); H=$(getent passwd "$(id -u)" | cut -d: -f6)
[ -S "$S" ] || { echo "$S is not a socket"; exit 1; }
printf "XDG_RUNTIME_DIR=%s\nWAYLAND_DISPLAY=%s\nRHIZO_WAYLAND_HOST_SOCKET=%s\nDBUS_SESSION_BUS_ADDRESS=unix:path=%s/bus\nHOME=%s\n" \
  "$R" "$(basename "$S")" "$S" "$R" "$H" >/run/rhizo-desktop/session.env.tmp \
  && chmod 0644 /run/rhizo-desktop/session.env.tmp \
  && mv /run/rhizo-desktop/session.env.tmp /run/rhizo-desktop/session.env && echo SESSION_ENV_PUBLISHED'
  out=$(printf '%s\n' "$script" | ssh_vm -t 30 "runuser -u \"\$(getent passwd $uid | cut -d: -f1)\" -- sh -s -- $sock" 2>&1)
  log "    session.env for $sock: ${out:-<no answer>}"
  [[ "$out" == *SESSION_ENV_PUBLISHED* ]]
}

# remove the seat login start-sway.sh staged
test_unstage_seat_login() {
  local mark out
  mark=$(sed -n 's/^SEAT_PROFILE_MARK="\(.*\)"$/\1/p' "$REPO/test/vm/start/start-sway.sh")
  [[ -n "$mark" ]] || { log "    no SEAT_PROFILE_MARK in $REPO/test/vm/start/start-sway.sh"; return 1; }
  out=$(ssh_vm -t 30 "M=$(printf '%q' "$mark"); D=/etc/systemd/system/getty@tty1.service.d/autologin.conf
    P=\$(getent passwd 1000 | cut -d: -f6)/.profile
    if [ -e \"\$D\" ]; then rm -f \"\$D\" && systemctl daemon-reload || exit 1; fi
    if [ -f \"\$P\" ] && grep -qxF \"\$M\" \"\$P\"; then
      awk -v m=\"\$M\" '\$0 == m { skip = 4 } skip > 0 { skip--; next } { print }' \"\$P\" >\"\$P.rhizo-tmp\" \
        && cat \"\$P.rhizo-tmp\" >\"\$P\" && rm -f \"\$P.rhizo-tmp\" || exit 1
    fi
    [ ! -e \"\$D\" ] && ! grep -qxF \"\$M\" \"\$P\" 2>/dev/null && echo SEAT_LOGIN_UNSTAGED" 2>&1)
  log "    seat login unstaged: ${out:-<no answer>}"
  [[ "$out" == *SEAT_LOGIN_UNSTAGED* ]]
}
# run test_ensure_desktop
test_ensure_sway() { test_ensure_desktop "$@"; }

# start the audio host side on a chained boot that lacks it
test_ensure_audio() {
  local audio_log="$1"
  if [[ "${RHIZO_TEST_INSTALLED:-0}" == 1 ]]; then
    log "  audio: restarting the installed audio host side and adding null-sink taps"
    "$_LIB_DIR/../../vm/start/start-audio.sh" >"$audio_log" 2>&1 \
      || { fail "the installed audio host side did not restart (see $audio_log)"; return 1; }
    return 0
  fi
  if ssh_vm -t 10 'test -S /run/rhizo-audio/audiod && pgrep -x rhizo-audiod >/dev/null' >/dev/null 2>&1; then
    log "  audio: the host side is already up on the chained boot"
    return 0
  fi
  log "  audio: the chain's leader started no audio host side -- starting it"
  "$_LIB_DIR/../../vm/start/start-audio.sh" >"$audio_log" 2>&1 \
    || { fail "audio host side did not start on the chained boot (see $audio_log)"; return 1; }
}

# restart androidd.service and wait for boot_completed
test_restart_stack() {
  local rlog="$1" t0 rc init_before init_after bc="" deadline
  init_before=$(guest_init_pid 10)
  [[ -n "$init_before" ]] || { echo "no init second_stage before the restart" >"$rlog"; return 1; }
  t0=$(date +%s)
  ssh_vm -t 300 'systemctl restart androidd.service' >"$rlog" 2>&1; rc=$?
  echo "systemctl restart rc=$rc" >>"$rlog"
  [[ "$rc" == 0 ]] || return 1
  deadline=$(( t0 + 240 ))
  while (( $(date +%s) < deadline )); do
    init_after=$(guest_init_pid 10)
    if [[ -n "$init_after" && "$init_after" != "$init_before" ]]; then
      bc=$(getprop_live "$init_after" sys.boot_completed) || bc=""
      [[ "$bc" == "1" ]] && break
    fi
    sleep 2
  done
  echo "init $init_before -> ${init_after:-<none>}" >>"$rlog"
  echo "boot_completed=${bc:-<none>} after $(( $(date +%s) - t0 ))s" >>"$rlog"
  [[ "$bc" == "1" ]] || return 1
  log "  stack restarted: sys.boot_completed=1 in $(( $(date +%s) - t0 ))s"
}

# fail unless each named var/share artifact is current
test_require_staged() {
  local out line
  out=$("$_LIB_DIR/../../../tools/build/stamps.py" require "$@" 2>&1) && return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] && fail "$line"
  done <<<"$out"
  return 1
}

# exit with a signal's status
test_trap_signals() {
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'exit 130' INT
}

# write the verdict and reasons to disk
test_record_verdict() {
  local vf="$EV/verdict.txt" vf_target headline reasons=""
  headline="$1 $(date -u +%Y-%m-%dT%H:%M:%SZ) system test=${TEST_NAME:-unknown} vm=${RHIZO_VM:-0}${2:+ $2}${3:+ $3}"
  if [[ -s "$EV/failures.log" ]]; then
    reasons="failures=$(wc -l < "$EV/failures.log") (reasons in $EV/failures.log)"$'\n'"$(cat "$EV/failures.log")"
  fi
  vf_target="$(rig_result_path "$vf")"
  rig_verdict_write "$vf_target" "$headline" "$headline" "$reasons"
  TEST_VERDICT_RECORDED=1
  if [[ "$1" == PASSED ]]; then
    rig_result_keep "$vf"
    log "    verdict recorded in $vf"
  elif [[ "$vf_target" != "$vf" ]]; then
    log "    $vf holds a passing run's verdict -- this $1 run's verdict is in $vf_target instead"
  else
    log "    verdict recorded in $vf_target"
  fi
  [[ "$1" == FAILED ]] && RHIZO_TEST_EV_DIR="$EV" "$REPO/test/vm/boot/collect-boot-evidence.sh" --assert-only "$EV/test-failure" "${TEST_NAME:-unknown}"
  if (( TEST_NESTED )); then
    rig_test_recorded "$1" "${2:-}"
    log "    boot log left alone -- nested inside ${RHIZO_TEST_INVOKED}"
    return 0
  fi
  local log_err cause=""
  [[ "$1" == FAILED ]] && cause="$TEST_BOOT_FAULT"
  if [[ -n "${TEST_BOOT_NO_ROW:-}" ]]; then
    log "    boot log left alone -- this attempt was refused before it had its own row"
  else
    log_err=$(rig_boot_outcome "${RHIZO_VM:-0}" "$1" \
      "system test=${TEST_NAME:-unknown}" ${2:+"params=$2"} ${cause:+"cause=$cause"} 2>&1 >/dev/null) \
      || log "    boot record not updated: ${log_err##*$'\n'}"
  fi
  rig_test_recorded "$1" "${2:-}"
}

# remove the evidence files matching a glob
test_prune_evidence() {
  local target="$1" f base g match
  shift
  for f in "$EV"/*; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    # shellcheck disable=SC2053
    [[ "$base" == $target ]] || continue
    match=0
    for g in "$@"; do
      # shellcheck disable=SC2053
      [[ "$base" == $g ]] && { match=1; break; }
    done
    (( match )) || rm -f "$f"
  done
}
