#!/bin/bash
# test boot reaches sys.boot_completed
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-requires: none
# test-verdict-params: boot_wait=90s
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh

[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
BOOT_WAIT=90
VARIANT=user
GSI_TREE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot-wait) BOOT_WAIT="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --gsi) GSI_TREE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
VERDICT_REDUCTION=""
if [[ "$VARIANT" != user ]]; then VERDICT_REDUCTION+=" variant=$VARIANT"; fi
if [[ -n "$GSI_TREE" ]]; then VERDICT_REDUCTION+=" gsi=$GSI_TREE"; fi
case "$VARIANT" in
  user)      EXPECT_PERMISSIVE="" ;;
  userdebug) EXPECT_PERMISSIVE="su" ;;
  *) echo "unknown --variant '$VARIANT' (expected user|userdebug)" >&2; exit 2 ;;
esac
[[ -n "$GSI_TREE" ]] && export RHIZO_GSI="$GSI_TREE"

test_init boot-smoke --teardown

mapfile -t VENDOR_SVC < <(grep -oE 'service vendor\.rhizo-[a-zA-Z0-9_-]+' "$REPO/src/androidd/boot.py" | awk '{print $2}' | sort -u)
if [[ ${#VENDOR_SVC[@]} -eq 0 ]]; then
  fail "found no 'service vendor.rhizo-*' declarations in launcher3.py"
fi
log "expected vendor HAL services (from launcher3.py): ${VENDOR_SVC[*]:-<none>}"
CHECK_SVC=(keystore2 "${VENDOR_SVC[@]}")

../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
REDEPLOY_LOG="$EV/redeploy.log"
: > "$REDEPLOY_LOG"
if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then RHIZO_KERNEL=""; else RHIZO_KERNEL="${RHIZO_KERNEL:-}"; fi
step "1. cold boot: RHIZO_KERNEL=$RHIZO_KERNEL ../../vm/redeploy.sh --boot-wait $BOOT_WAIT"
RHIZO_KERNEL="$RHIZO_KERNEL" ../../vm/redeploy.sh --boot-wait "$BOOT_WAIT" > "$REDEPLOY_LOG" 2>&1 &
REDEPLOY_PID=$!

LIVENESS_LOG="$EV/liveness-poll.log"
: > "$LIVENESS_LOG"
DMESG_TAIL="$EV/dmesg-tail.txt"
: > "$DMESG_TAIL"

INIT_PID=""
FATAL_REBOOT_SEEN=0
declare -A SVC_EVER_UP SVC_RESTARTS

# read service states from dmesg markers
refresh_svc_state() {
  local dm svc st prev s s_re
  dm=$(ssh_vm -t 8 'dmesg 2>/dev/null | grep -a "RHIZO_SVC "' 2>/dev/null)
  [[ -z "$dm" ]] && return
  for s in "${CHECK_SVC[@]}"; do
    SVC_RESTARTS[$s]=0; SVC_EVER_UP[$s]=0
    prev=""
    s_re="${s//./\\.}"
    while IFS= read -r st; do
      [[ -z "$st" ]] && continue
      [[ "$st" == "running" ]] && SVC_EVER_UP[$s]=1
      [[ "$prev" == "running" ]] && SVC_RESTARTS[$s]=$(( SVC_RESTARTS[$s] + 1 ))
      prev="$st"
      echo "svc=$s state=$st" >> "$LIVENESS_LOG"
    done < <(echo "$dm" | grep -oE "RHIZO_SVC ${s_re}=[a-z]+" | sed "s/^RHIZO_SVC ${s_re}=//")
  done
}

start_ts=$(date +%s)
hard_deadline=$(( start_ts + 600 ))
while kill -0 "$REDEPLOY_PID" 2>/dev/null; do
  now=$(date +%s)
  if (( now > hard_deadline )); then
    log "    monitoring hard deadline (600s) hit -- redeploy.sh still running, stopping our own polling"
    break
  fi

  if [[ -z "$INIT_PID" ]]; then
    INIT_PID=$(grep -oE 'init second_stage pid=[0-9]+' "$REDEPLOY_LOG" 2>/dev/null | tail -1 | cut -d= -f2)
    [[ -n "$INIT_PID" ]] && log "    observed init_pid=$INIT_PID at t=$((now-start_ts))s"
  fi

  dm=$(ssh_vm -t 8 'dmesg 2>/dev/null' 2>/dev/null)
  if [[ -n "$dm" ]]; then
    echo "$dm" > "$DMESG_TAIL"
    grep -q "InitFatalReboot" <<<"$dm" && FATAL_REBOOT_SEEN=1
  fi

  refresh_svc_state
  if (( FATAL_REBOOT_SEEN )); then
    log "    InitFatalReboot observed in dmesg"
    break
  fi
  sleep 5
done
wait "$REDEPLOY_PID" 2>/dev/null
REDEPLOY_RC=$?
log "    redeploy.sh exit code: $REDEPLOY_RC"
tail -15 "$REDEPLOY_LOG" | sed 's/^/    | /'

if [[ -z "$INIT_PID" ]]; then
  INIT_PID=$(grep -oE 'init second_stage pid=[0-9]+' "$REDEPLOY_LOG" 2>/dev/null | tail -1 | cut -d= -f2)
  [[ -n "$INIT_PID" ]] && log "    (post-loop) recovered init_pid=$INIT_PID from the completed redeploy.log"
fi
refresh_svc_state

step "2. sys.boot_completed"
if [[ "$REDEPLOY_RC" == 0 ]] && grep -q "SUCCESS: sys.boot_completed=1" "$REDEPLOY_LOG"; then
  pass "sys.boot_completed=1 reached within ${BOOT_WAIT}s (redeploy.sh exit 0)"
else
  fail "sys.boot_completed=1 not reached within ${BOOT_WAIT}s (redeploy.sh exit $REDEPLOY_RC) -- see $REDEPLOY_LOG"
fi

step "2b. SELinux posture (M9: enforcing by default)"
EXPECT_ENFORCE=1
[[ "${RHIZO_PERMISSIVE:-}" == "1" ]] && EXPECT_ENFORCE=0
enforce_now=$(ssh_vm -t 15 'cat /sys/fs/selinux/enforce 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
if [[ "$enforce_now" == "$EXPECT_ENFORCE" ]]; then
  pass "/sys/fs/selinux/enforce=$enforce_now (expected $EXPECT_ENFORCE for this posture)"
else
  fail "/sys/fs/selinux/enforce='$enforce_now', expected '$EXPECT_ENFORCE'"
fi
LIVE_POLICY="$EV/live-sepolicy.bin"
if ssh_vm -t 30 'cat /sys/fs/selinux/policy' > "$LIVE_POLICY" 2>/dev/null && [[ -s "$LIVE_POLICY" ]]; then
  perm_out=$("$REPO/test/checks/lib/policy-lab.sh" permissive "$LIVE_POLICY" --expect "$EXPECT_PERMISSIVE" 2>&1)
  perm_rc=$?
  echo "$perm_out" > "$EV/live-permissive-types.txt"
  if (( perm_rc == 0 )); then
    pass "live policy permissive set is exactly '${EXPECT_PERMISSIVE:-<none>}' for the $VARIANT variant (sepolicy-analyze, the same check testAllDomainsEnforcing runs)"
  else
    fail "live policy permissive set is not '${EXPECT_PERMISSIVE:-<none>}' -- see $EV/live-permissive-types.txt"
  fi
else
  fail "could not pull /sys/fs/selinux/policy off the VM"
fi

step "3. system_server restarts"
last_restarts=$(grep -oE 'restarts_seen=[0-9]+' "$REDEPLOY_LOG" | tail -1 | cut -d= -f2)
if [[ -z "$last_restarts" ]]; then
  fail "no 'restarts_seen=N' line in redeploy.sh's own log"
elif [[ "$last_restarts" == "0" ]]; then
  pass "zero system_server restarts (redeploy.sh's own tracking)"
else
  fail "$last_restarts system_server restart(s) observed during boot (redeploy.sh's own tracking)"
fi

step "4. InitFatalReboot"
FATAL_REBOOT_DMESG="$EV/dmesg-initfatalreboot.txt"
if (( FATAL_REBOOT_SEEN )); then
  cp "$DMESG_TAIL" "$FATAL_REBOOT_DMESG"
  fail "dmesg showed 'InitFatalReboot' during the boot window (see $FATAL_REBOOT_DMESG)"
  grep -B3 -A3 "InitFatalReboot" "$FATAL_REBOOT_DMESG" | sed 's/^/    | /'
else
  echo "<none>" > "$FATAL_REBOOT_DMESG"
  pass "no InitFatalReboot observed in dmesg over the boot window"
fi

step "4b. launcher speaks post-flip (kmsg channel self-test)"
hb_deadline=$((SECONDS + 15))
while :; do
  dm4b=$(ssh_vm -t 10 'dmesg 2>/dev/null')
  grep -q "L3: init(pid1) alive" <<<"$dm4b" && break
  (( SECONDS < hb_deadline )) || break
  sleep 1
done
[[ -n "$dm4b" ]] && printf '%s\n' "$dm4b" > "$DMESG_TAIL"
if grep -q "L3: init(pid1) alive" <<<"$dm4b"; then
  pass "post-flip heartbeat observed in host dmesg"
else
  fail "no 'L3: init(pid1) alive' heartbeat observed in dmesg after boot_completed (see $DMESG_TAIL)"
fi

step "4c. overlayfs mounter-cred bug (item 5): zero dev=overlay, zero enforced kernel-domain denials on system_ext/product/system"
overlay_avc=$(grep -a 'avc:  *denied' <<<"$dm4b" | grep 'dev="overlay"')
android_kernel_avc=$(grep -a 'avc:  *denied' <<<"$dm4b" | grep 'scontext=u:r:kernel:s0' | grep 'permissive=0' \
  | grep -E '(path|name)="(/system_ext|/product|/system/)')
if [[ -z "$overlay_avc" && -z "$android_kernel_avc" ]]; then
  pass 'no dev="overlay" AVC and no enforced kernel-domain denial on a system_ext/product/system path'
else
  fail "overlayfs mounter-cred signature present in dmesg (see $DMESG_TAIL)"
  [[ -n "$overlay_avc" ]] && printf '%s\n' "$overlay_avc" | sed 's/^/    | dev=overlay: /'
  [[ -n "$android_kernel_avc" ]] && printf '%s\n' "$android_kernel_avc" | sed 's/^/    | kernel-domain: /'
fi
suspect_avc=$(grep -a 'avc:  *denied' <<<"$dm4b" | grep 'scontext=u:r:kernel:s0' | grep 'permissive=1' \
  | grep -E '(path|name)="(/system_ext|/product|/system/)')
if [[ -n "$suspect_avc" ]]; then
  log "  SUSPECT: permissive-window kernel-domain denial on this same class of path -- read by hand, not a fail"
  printf '%s\n' "$suspect_avc" | sed 's/^/    | suspect: /'
fi

# check a service came up and stayed up
check_svc_liveness() {
  local svc="$1"
  if [[ -z "$INIT_PID" ]]; then
    fail "$svc liveness: init second_stage was never observed during the boot window"
  elif [[ "${SVC_EVER_UP[$svc]:-0}" != 1 ]]; then
    fail "$svc was never observed in state 'running' during the boot window (init_pid=$INIT_PID)"
  elif [[ "${SVC_RESTARTS[$svc]:-0}" != 0 ]]; then
    fail "$svc restarted ${SVC_RESTARTS[$svc]} time(s) during the boot window"
  else
    pass "$svc came up and stayed up (0 restarts observed)"
  fi
}

step "5. keystore2 liveness (checked throughout the boot window, see $LIVENESS_LOG)"
check_svc_liveness keystore2

step "6. vendor.rhizo-* HAL service liveness"
for svc in "${VENDOR_SVC[@]}"; do
  check_svc_liveness "$svc"
done

step "7. logcat fatal/watchdog sweep"
if [[ -n "$INIT_PID" ]]; then
  # test-log-window: safe -- cold-required, a boot for the system test's whole
  logcat_vm "$INIT_PID" -d -t 8000 2>/dev/null > "$EV/logcat-scanned.txt"
  bad=$(grep -cE "$TEST_FATAL_RE" "$EV/logcat-scanned.txt")
  log "    fatal/watchdog lines in logcat: ${bad:-0} (crash events: $(test_crash_events "$EV/logcat-scanned.txt"))"
  if ! test_logcat_capture_read "$EV/logcat-scanned.txt"; then
    fail "the fatal sweep read no logcat line (capture starts: $(head -c 120 "$EV/logcat-scanned.txt" | tr '\n' ' '))"
  elif [[ "${bad:-0}" != "0" ]]; then
    fail "logcat has $bad fatal/watchdog line(s)"
    test_fatal_lines "$EV/logcat-scanned.txt" | sed 's/^/    | /'
  else
    pass "no FATAL EXCEPTION / Watchdog kill / native fatal signal in logcat"
  fi
else
  log "    skipped -- init second_stage never observed, nothing to logcat"
fi

step "8. prepared-host consumption (item 6)"
prepared_present=$(ssh_vm -t 8 'test -e /var/lib/rhizo/prepared/current && echo yes || echo no')
if [[ "$prepared_present" == "yes" ]]; then
  launch_ln=$(grep -n "RHIZO_MARKER launch_start" <<<"$dm4b" | tail -1 | cut -d: -f1)
  complete_ln=$(grep -n "RHIZO_MARKER sys.boot_completed=1" <<<"$dm4b" | tail -1 | cut -d: -f1)
  if [[ -n "$launch_ln" && -n "$complete_ln" && "$complete_ln" -gt "$launch_ln" ]]; then
    window=$(sed -n "${launch_ln},${complete_ln}p" <<<"$dm4b")
    refused=$(grep -o "RHIZO_MARKER prepared_refused=[^ ]*" <<<"$window" | tail -1 | cut -d= -f2)
    if grep -q "RHIZO_MARKER prepared=" <<<"$window"; then
      pass "prepared tree present at /var/lib/rhizo/prepared/current and this boot's kmsg carries RHIZO_MARKER prepared= inside the launch_start..boot_completed window"
    elif [[ "$refused" == kernel ]]; then
      pass "prepared tree present but for another kernel: this boot refused it by name (prepared_refused=$refused) and said so in its own kmsg window"
    elif [[ -n "$refused" ]]; then
      fail "prepared tree present at /var/lib/rhizo/prepared/current but this boot refused it: prepared_refused=$refused (see $DMESG_TAIL)"
    else
      fail "prepared tree present at /var/lib/rhizo/prepared/current but this boot's kmsg has no RHIZO_MARKER prepared= or prepared_refused= inside the boot window (see $DMESG_TAIL)"
    fi
  else
    fail "prepared tree present but this boot's own launch_start/boot_completed window could not be located in dmesg"
  fi
else
  log "    no prepared tree at /var/lib/rhizo/prepared/current on this host"
  pass "no prepared tree on this host"
fi

step "8c. sandbox cgroup ceilings (item 3) are on the cgroup the sandbox runs in"
cg_dm="$dm4b"
[[ -n "$cg_dm" ]] || cg_dm=$(ssh_vm -t 10 'dmesg 2>/dev/null' 2>/dev/null)
for cg_f in memory.max pids.max; do
  cg_ln=$(grep -a -o "cgroup /[^ =]*/$cg_f=[0-9]*" <<<"$cg_dm" | tail -1)
  if [[ -z "$cg_ln" ]]; then
    cg_bad=$(grep -a -o "cgroup $cg_f FAILED[^|]*" <<<"$cg_dm" | tail -1)
    fail "this boot's kmsg carries no '$cg_f=' line from the launcher${cg_bad:+ -- it says: $cg_bad}"
    continue
  fi
  cg_path=${cg_ln#cgroup }; cg_path=${cg_path%%=*}
  cg_want=${cg_ln##*=}
  cg_got=$(ssh_vm -t 10 "cat $cg_path 2>/dev/null" 2>/dev/null | tr -d '\r')
  if [[ "$cg_got" == "$cg_want" ]]; then
    pass "$cg_path reads $cg_got, the value this boot's launcher says it wrote"
  else
    fail "$cg_path reads '${cg_got:-<unreadable>}', not the $cg_want this boot's launcher says it wrote"
  fi
done

SUMMARY_TARGET="$(rig_result_path "$EV/summary.txt")"
{
  echo "boot-smoke.sh summary -- $(date -u +%FT%TZ)"
  echo "boot_wait=${BOOT_WAIT}s redeploy_rc=$REDEPLOY_RC init_pid=${INIT_PID:-<none>}"
  echo "restarts_seen=${last_restarts:-<unknown>} fatal_reboot_seen=$FATAL_REBOOT_SEEN"
  echo "vendor.rhizo-* services checked: ${VENDOR_SVC[*]:-<none>}"
  echo
  echo "result: $([[ "$FAILED" == 0 ]] && echo PASS || echo FAIL)"
} > "$SUMMARY_TARGET"

if (( FAILED )); then
  "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV" "boot-smoke-post-boot-fail"
  log "BOOT SMOKE SYSTEM TEST FAILED -- evidence in $EV"
  test_record_verdict FAILED "boot_wait=${BOOT_WAIT}s$VERDICT_REDUCTION"
  exit 1
fi
rig_result_keep "$EV/summary.txt"
log "BOOT SMOKE SYSTEM TEST PASSED -- evidence in $EV"
test_record_verdict PASSED "boot_wait=${BOOT_WAIT}s$VERDICT_REDUCTION"
