#!/bin/bash
# test display add and kill cycles
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: shared
# test-boots-unit: no
# test-records-metrics: no
# test-requires: none
# test-verdict-params: iterations=200 idle_cycles=3
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
ITERATIONS=200
IDLE_CYCLES=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-boot) SKIP_BOOT=1; shift ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --idle-cycles) IDLE_CYCLES="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

test_init display-stress

# save crash logs and tombstones
capture_crash_evidence() {
  local init_pid="$1" iter="$2" reason="$3"
  local dir; dir="$EV/crash-$(date +%s)-iter${iter}"
  mkdir -p "$dir"
  echo "$reason" > "$dir/reason.txt"
  logcat_vm "$init_pid" -d -b all -t 8000 > "$dir/logcat.txt" 2>&1
  ssh_vm -t 10 "nsenter -a -t $init_pid -- /system/bin/toybox ps -A" > "$dir/ps.txt" 2>&1
  local names name
  names=$(ssh_vm -t 10 "nsenter -a -t $init_pid -- /system/bin/toybox ls /data/tombstones/" 2>/dev/null)
  for name in $names; do
    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]] || continue
    ssh_vm -t 15 "nsenter -a -t $init_pid -- /system/bin/toybox cat /data/tombstones/$name" \
      > "$dir/tombstone-$name" 2>/dev/null
  done
  rhizo_ctl "$init_pid" wl status >/dev/null
  rhizo_ctl_out "$init_pid" > "$dir/wl-status.txt" 2>/dev/null
  desk_windows > "$dir/sway-tree.json" 2>&1
  log "    crash evidence captured -> $dir (reason: $reason)"
}

if (( SKIP_BOOT == 0 )); then
  step "0. boot: VM, compositor, Android"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up >"$EV/display-stress-sway.log" 2>&1 || { fail "the desktop session did not start (see $EV/display-stress-sway.log)"; exit 1; }
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 180 >"$EV/display-stress-redeploy.log" 2>&1 \
    || { fail "redeploy.sh failed (see $EV/display-stress-redeploy.log)"; exit 1; }
  tail -3 "$EV/display-stress-redeploy.log"
else
  test_ensure_sway "$EV/chained-display-stress-sway.log" "$EV/chained-redeploy.log"
fi
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
log "init_pid=$INIT"

boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"
SS_PID_START=$(system_server_pid "$INIT")
log "system_server pid at start: $SS_PID_START"
[[ -n "$SS_PID_START" ]] || { fail "could not read system_server pid at start"; exit 1; }
STRESS_SINCE=$(logcat_since_marker "$INIT")
SF_PID_START=$(surfaceflinger_pid "$INIT")
log "surfaceflinger pid at start: $SF_PID_START"
[[ -n "$SF_PID_START" ]] || { fail "could not read surfaceflinger pid at start"; exit 1; }

android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "locksettings set-disabled true" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
wait_guest 30 "true" >/dev/null
power=$(android_sh "$INIT" "dumpsys power")
awake=$(grep -m1 -o "mWakefulness=[A-Za-z]*" <<<"$power")
[[ "$awake" == "mWakefulness=Awake" ]] || fail "device is not awake ($awake)"
pass "booted, awake, keyguard disabled, system_server pid=$SS_PID_START"

if ! dlist=$(rhizo_ctl_display_list "$INIT"); then
  fail "pre-loop cleanup: display list unreadable, cannot establish a baseline"
else
  ids_before=$(rhizo_dl_ids "$dlist")
  spares_before=$(rhizo_dl_spares "$dlist")
  removed=""
  for did in $ids_before; do
    [[ "$did" == 1 ]] && continue
    if grep -qx "$did" <<<"$spares_before"; then
      rhizo_ctl "$INIT" display release-spare "$did" >/dev/null
    else
      rhizo_ctl "$INIT" display remove "$did" >/dev/null
    fi
    removed+="$did "
  done
  if ! dlist_after=$(rhizo_ctl_display_list "$INIT"); then
    fail "pre-loop cleanup: display list unreadable after removal"
  else
    ids_after=$(rhizo_dl_ids "$dlist_after")
    grep -qx 1 <<<"$ids_after" || fail "pre-loop cleanup: the composer's display list does not contain the primary (id 1) (list: ${dlist_after#display list })"
    for did in $removed; do
      grep -qx "$did" <<<"$ids_after" && fail "pre-loop cleanup: display $did still present after 'display remove $did' (list: ${dlist_after#display list })"
    done
    probe_ids=""
    probe_ok=1
    for _ in 1 2; do
      rhizo_ctl "$INIT" display add 640 480 >/dev/null
      probe_line=$(rhizo_ctl_out "$INIT" | grep -o 'display added id=[0-9]* port=[0-9]*' | tail -1)
      probe_id=$(grep -o 'id=[0-9]*' <<<"$probe_line" | grep -o '[0-9]*$')
      if [[ -z "$probe_id" ]]; then
        probe_ok=0
        break
      fi
      probe_ids+="$probe_id "
    done
    for did in $probe_ids; do
      rhizo_ctl "$INIT" display remove "$did" >/dev/null
    done
    (( probe_ok )) || fail "pre-loop cleanup: could not add 2 probe displays after removing (${dlist_after#display list })"
    log "    displays removed before this run's baseline: ${removed:-none} (${dlist#display list }); 2 probe displays added and removed clean, the pool is genuinely free"
  fi
fi

# print dma-buf object count and size in kB
dmabuf_objs_kb() {
  local out
  out=$(ssh_vm -t 15 "awk '/^[0-9]/{n++; t+=\$1+0} END {print n, t/1024}' /sys/kernel/debug/dma_buf/bufinfo" 2>/dev/null)
  [[ "$out" =~ ^([0-9]+)[[:space:]]+([0-9.]+) ]] || { echo "no dma_buf bufinfo reading from the guest" >&2; return 1; }
  echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
}

# save dma-buf buffer and fd lists
bank_dmabuf_state() {
  local rc fds
  ssh_vm -t 15 'cat /sys/kernel/debug/dma_buf/bufinfo' > "$EV/dmabuf-$1-bufinfo.txt" 2>&1
  rc=$?
  (( rc == 0 )) || echo "<none: ssh rc=$rc>" >> "$EV/dmabuf-$1-bufinfo.txt"
  fds=$(ssh_vm -t 60 'grep -s -H -e "^size:" -e "^exp_name:" /proc/[0-9]*/fdinfo/*; grep -s -H "" /proc/[0-9]*/comm')
  rc=$?
  if (( rc != 0 )) || ! grep -q ':exp_name:' <<<"$fds"; then
    echo "<none: ssh rc=$rc, no dma-buf fd in $(wc -l <<<"$fds") fdinfo line(s)>" > "$EV/dmabuf-$1-holders.txt"
    return
  fi
  awk -F: '
    $1 ~ /\/comm$/ { split($1, p, "/"); comm[p[3]] = $2; next }
    { split($1, p, "/"); k = p[3] SUBSEP p[5] }
    $2 == "size" { size[k] = $3 + 0 }
    $2 == "exp_name" { buf[k] = 1 }
    END {
      for (k in buf) { split(k, q, SUBSEP); n[q[1]]++; kb[q[1]] += size[k] / 1024 }
      for (pid in n) printf "%s pid=%s bufs=%d kB=%.0f\n", comm[pid], pid, n[pid], kb[pid]
    }' <<<"$fds" | sort -t= -k4 -nr > "$EV/dmabuf-$1-holders.txt"
}

DMABUF_BASE=$(dmabuf_objs_kb) || fail "could not read a dma-buf baseline"
bank_dmabuf_state baseline
DMABUF_BASE_OBJS=${DMABUF_BASE% *}
DMABUF_BASE_KB=${DMABUF_BASE#* }
log "    dma-buf baseline: ${DMABUF_BASE_OBJS} objects, ${DMABUF_BASE_KB}kB"

step "1. stress loop: $ITERATIONS iterations of add -> map -> kill -> gone"
CLEAN=0
OWN_CONTENT=0
RESTART_SEEN=0
REPEAT_SEEN=0
LAST_FAIL_REASON=""
REPEAT_COUNT=0
SUMMARY="$(rig_result_path "$EV/summary.tsv")"
: > "$SUMMARY"

# print the id of the last added display
last_added_id() {
  rhizo_ctl_out "$INIT" | grep -o 'display added id=[0-9]*' \
    | tail -1 | grep -o '[0-9]*$'
}

# print the last display added reply
last_added_line() {
  rhizo_ctl_out "$INIT" | grep -o 'display added id=[0-9]* port=[0-9]*' | tail -1
}

# print the display list reply
query_display_list() { rhizo_ctl_display_list "$INIT"; }

# check committedState ON for a display port (a16: address {port=N}, a17: address StablePhysical{id=I, port=N})
committed_on() {
  local dd
  dd=$(android_sh "$INIT" "dumpsys display" 2>/dev/null)
  awk -v want="address (StablePhysical[{]id=[0-9]+, |[{])port=$1[,}]" '$0 ~ want {found=1}
       found && /committedState/ {print; exit}' <<<"$dd" \
    | grep -q "committedState ON"
}

# search dumpsys display for a logical id
display_present() {
  local dd
  dd=$(android_sh "$INIT" "dumpsys display" 2>/dev/null)
  grep -q "^  Display Id=$1\$" <<<"$dd"
}

CONTENT_ACT=com.android.settings/.homepage.SettingsHomepageActivity
# check a port's display device reports FLAG_OWN_CONTENT_ONLY
owns_content() {
  local dd
  dd=$(android_sh "$INIT" "dumpsys display" 2>/dev/null)
  awk -v want="address (StablePhysical[{]id=[0-9]+, |[{])port=$1[,}]" '/DisplayDeviceInfo[{]/ && $0 ~ want {print; exit}' <<<"$dd" \
    | grep -q "FLAG_OWN_CONTENT_ONLY"
}

for ((iter = 1; iter <= ITERATIONS; iter++)); do
  iter_start=$(date +%s.%N)
  iter_ok=1
  reason=""

  before_id=$(last_added_id)
  rhizo_ctl "$INIT" display add 640 480 >/dev/null
  new_id=""
  new_port=""
  deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    line=$(last_added_line)
    cand=$(grep -o 'id=[0-9]*' <<<"$line" | grep -o '[0-9]*$')
    if [[ -n "$cand" && "$cand" != "$before_id" ]]; then
      new_id="$cand"
      new_port=$(grep -o 'port=[0-9]*' <<<"$line" | grep -o '[0-9]*$')
      break
    fi
    sleep 0.2
  done
  if [[ -z "$new_id" || -z "$new_port" ]]; then
    iter_ok=0
    if rhizo_ctl_out "$INIT" | grep -q 'display add-failed no-free-port'; then
      reason="no new display id/port reported (composer: add-failed no-free-port)"
    elif [[ -z "$(rhizo_ctl_out "$INIT" 2>/dev/null)" ]]; then
      reason="no new display id/port reported (composer: unreachable)"
    else
      reason="no new display id/port reported (composer: no matching reply)"
    fi
  fi

  log_id=""
  if (( iter_ok )); then
    deadline=$(( $(date +%s) + 15 ))
    while (( $(date +%s) < deadline )); do
      log_id=$(resolve_logical_id "$new_port")
      [[ -n "$log_id" ]] && break
      sleep 0.2
    done
    if [[ -z "$log_id" ]]; then
      iter_ok=0; reason="composer display $new_id port $new_port never got a logical id (dumpsys display mViewports)"
    fi
  fi

  if (( iter_ok )); then
    android_sh "$INIT" "cmd display enable-display $log_id" >/dev/null
    mapped=0
    deadline=$(( $(date +%s) + 15 ))
    reissued=0
    while (( $(date +%s) < deadline )); do
      if display_present "$log_id" && committed_on "$new_port"; then mapped=1; break; fi
      (( reissued % 6 == 5 )) && android_sh "$INIT" "cmd display enable-display $log_id" >/dev/null
      reissued=$((reissued + 1))
      sleep 0.3
    done
    if (( ! mapped )); then
      iter_ok=0; reason="display $new_id (logical $log_id) never reached Display-Id-present + committedState ON"
    fi
  fi

  if (( iter_ok )) && owns_content "$new_port"; then
    OWN_CONTENT=$((OWN_CONTENT + 1))
    am_out=$(android_sh "$INIT" "am start --display $log_id -n $CONTENT_ACT")
    if [[ "$am_out" != *"Starting: Intent"* || "$am_out" == *"Error"* ]]; then
      iter_ok=0; reason="display $new_id (logical $log_id) owns its content and am start of $CONTENT_ACT on it failed: ${am_out//$'\n'/ }"
    elif ! _desktop_window_for_display "$new_id" 15 >/dev/null; then
      iter_ok=0; reason="display $new_id (logical $log_id) owns its content and its window never mapped with $CONTENT_ACT on it"
    fi
  fi

  if (( iter_ok )); then
    gone=0
    kill_sent=0
    deadline=$(( $(date +%s) + 15 ))
    reissued=0
    desktop_close_display_window "$new_id" && kill_sent=1
    while (( $(date +%s) < deadline )); do
      if ! display_present "$log_id"; then gone=1; break; fi
      if (( reissued % 6 == 5 )) && desktop_close_display_window "$new_id"; then
        kill_sent=1
      fi
      reissued=$((reissued + 1))
      sleep 0.2
    done
    if (( ! gone )); then
      iter_ok=0; reason="display $new_id (logical $log_id) still present in dumpsys display after swaymsg kill (kill_sent=$kill_sent)"
    fi
  elif [[ -n "$new_id" ]]; then
    desktop_close_display_window "$new_id"
    if [[ -n "$log_id" ]]; then
      cleanup_deadline=$(( $(date +%s) + 15 ))
      while (( $(date +%s) < cleanup_deadline )); do
        display_present "$log_id" || break
        sleep 0.3
      done
    fi
  fi

  ss_now=$(system_server_pid "$INIT")
  if [[ "$ss_now" != "$SS_PID_START" ]]; then
    RESTART_SEEN=1
    reason="${reason:+$reason; }system_server pid changed $SS_PID_START -> $ss_now"
    iter_ok=0
  fi

  sf_now=$(surfaceflinger_pid "$INIT")
  if [[ -z "$sf_now" || "$sf_now" != "$SF_PID_START" ]]; then
    RESTART_SEEN=1
    reason="${reason:+$reason; }surfaceflinger pid changed $SF_PID_START -> ${sf_now:-gone}"
    iter_ok=0
  fi

  iter_end=$(date +%s.%N)
  dur=$(awk -v a="$iter_start" -v b="$iter_end" 'BEGIN{printf "%.2f", b-a}')
  if (( iter_ok )); then
    CLEAN=$((CLEAN + 1))
    printf "%d\tOK\tid=%s\t%ss\n" "$iter" "$new_id" "$dur" >> "$SUMMARY"
  else
    printf "%d\tFAIL\tid=%s\t%ss\t%s\n" "$iter" "${new_id:-none}" "$dur" "$reason" >> "$SUMMARY"
    log "  iter $iter/$ITERATIONS FAIL: $reason"
    capture_crash_evidence "$INIT" "$iter" "$reason"
    if [[ "$reason" == "$LAST_FAIL_REASON" ]]; then
      REPEAT_COUNT=$((REPEAT_COUNT + 1))
    else
      LAST_FAIL_REASON="$reason"
      REPEAT_COUNT=1
    fi
    (( REPEAT_COUNT >= 3 )) && REPEAT_SEEN=1
  fi
  (( iter % 20 == 0 )) && log "  ...$iter/$ITERATIONS done, $CLEAN clean so far"
  (( RESTART_SEEN )) && { log "system_server restarted -- aborting the loop early"; break; }
  (( REPEAT_SEEN )) && { log "iter $iter/$ITERATIONS: '$LAST_FAIL_REASON' failed $REPEAT_COUNT times running -- aborting early"; break; }
done

step "stress loop done: $CLEAN/$ITERATIONS clean (see $SUMMARY)"
(( REPEAT_SEEN )) && log "    stopped early after $REPEAT_COUNT identical failures -- the checks below ran against ~$iter iterations, not $ITERATIONS"

step "2. final checks"
dlist=$(query_display_list) || fail "the composer answered no new 'display list' for the final-state check"
log "    final 'display list': $dlist"
spare_id=$(rhizo_dl_spares "$dlist" | head -1)
spare_port=""
if [[ -n "$spare_id" ]]; then
  spare_port=$(rhizo_ctl_out "$INIT" | grep -o "display pooled id=$spare_id port=[0-9]*" \
    | tail -1 | grep -o 'port=[0-9]*' | cut -d= -f2)
fi
primary_logid=$(resolve_logical_id 0)
spare_logid=""
[[ -n "$spare_port" ]] && spare_logid=$(resolve_logical_id "$spare_port")
final_ids=$(android_sh "$INIT" "dumpsys display" | grep "^  Display Id=" | sed 's/^  Display Id=//' | sort -n)
spare_released_line=$(rhizo_ctl_out "$INIT" | grep -c '^display spare-released id=')
if [[ -z "$spare_id" && "$spare_released_line" -gt 0 ]]; then
  expect_ids=$(printf '%s\n' "$primary_logid" | sed '/^$/d' | sort -n)
  log "    final live display ids: {$(tr '\n' ' ' <<<"$final_ids")} expect: primary=$primary_logid, no spare ($spare_released_line spare-released reply(ies) seen)"
  [[ -n "$primary_logid" ]] || fail "could not resolve the primary's own logical id"
  [[ "$final_ids" == "$expect_ids" ]] || fail "leftover displays are {$(tr '\n' ' ' <<<"$final_ids")}, expected exactly the primary ($primary_logid), no spare"
else
  expect_ids=$(printf '%s\n%s\n' "$primary_logid" "$spare_logid" | sed '/^$/d' | sort -n)
  log "    final live display ids: {$(tr '\n' ' ' <<<"$final_ids")} expect: primary=$primary_logid spare($spare_id)=$spare_logid"
  if [[ -z "$spare_id" || -z "$spare_port" || -z "$primary_logid" || -z "$spare_logid" ]]; then
    fail "could not resolve the expected leftover set (spare_id=$spare_id spare_port=$spare_port primary_logid=$primary_logid spare_logid=$spare_logid)"
  elif [[ "$final_ids" != "$expect_ids" ]]; then
    fail "leftover displays are {$(tr '\n' ' ' <<<"$final_ids")}, expected exactly the primary ($primary_logid) plus the spare ($spare_logid)"
  fi
fi
extra_count=$(python3 -c "
import sys
final = set(x for x in sys.argv[1].split() if x)
expect = set(x for x in sys.argv[2].split() if x)
print(len(final - expect))
" "$(tr '\n' ' ' <<<"$final_ids")" "$(tr '\n' ' ' <<<"$expect_ids")")
log "    extra displays (live, not in the expected set): $extra_count"

SS_PID_END=$(system_server_pid "$INIT")
boot_end=$(getprop_live "$INIT" sys.boot_completed) || boot_end="<unreadable rc=$?>"
log "    system_server pid $SS_PID_START -> $SS_PID_END, sys.boot_completed=$boot_end"
[[ "$SS_PID_START" == "$SS_PID_END" ]] || fail "system_server restarted ($SS_PID_START -> $SS_PID_END)"
[[ "$boot_end" == "1" ]] || fail "sys.boot_completed is '$boot_end'"

logcat_vm "$INIT" -d -t "$STRESS_SINCE" 2>/dev/null > "$EV/logcat-scanned.txt"
scanned=$(wc -l < "$EV/logcat-scanned.txt" 2>/dev/null); scanned=${scanned:-0}
log "    logcat lines scanned: $scanned"
test_logcat_capture_read "$EV/logcat-scanned.txt" \
  || fail "logcat scan holds no logcat line ($scanned line(s))"

grep -E -B14 -A6 "$TEST_FATAL_RE" "$EV/logcat-scanned.txt" > "$EV/fatal-lines.txt" 2>/dev/null
bad=$(grep -cE "$TEST_FATAL_RE" "$EV/fatal-lines.txt" 2>/dev/null)
bad=${bad:-0}
log "    fatal/watchdog lines in logcat: $bad (crash events: $(test_crash_events "$EV/logcat-scanned.txt"))"
if [[ "$bad" != "0" ]]; then
  fail "logcat has $bad fatal/watchdog lines (context in $EV/fatal-lines.txt)"
  grep -E "$TEST_FATAL_RE|>>> .* <<<|^.* F DEBUG   : pid:" "$EV/fatal-lines.txt" | head -6
fi

[[ "$CLEAN" == "$ITERATIONS" ]] || fail "$CLEAN/$ITERATIONS iterations clean -- not 200/200"

step "3. dma-buf retention check ($ITERATIONS add/kill cycles against the boot baseline)"
DMABUF_END=$(dmabuf_objs_kb) || fail "could not read a dma-buf ending sample"
bank_dmabuf_state end
if [[ -n "${DMABUF_END:-}" ]]; then
  DMABUF_END_OBJS=${DMABUF_END% *}
  DMABUF_END_KB=${DMABUF_END#* }
  obj_growth=$(( DMABUF_END_OBJS - DMABUF_BASE_OBJS ))
  kb_growth=$(awk -v a="$DMABUF_END_KB" -v b="$DMABUF_BASE_KB" 'BEGIN{printf "%.0f", a-b}')
  log "    dma-buf end: ${DMABUF_END_OBJS} objects (+${obj_growth}), ${DMABUF_END_KB}kB (+${kb_growth}kB) vs baseline"
  (( obj_growth <= 30 )) || fail "dma-buf objects grew by $obj_growth after $ITERATIONS cycles"
  (( $(awk -v g="$kb_growth" 'BEGIN{print (g <= 12000)}') )) || fail "dma-buf size grew by ${kb_growth}kB after $ITERATIONS cycles"
fi

idle_released=0
if [[ "${RHIZO_TEST_INSTALLED:-0}" == 1 ]]; then
  idle_src="the installed guest's dmesg"
  DISPLAY_POOL_IDLE_S=$(_ssh_vm_out 30 "dmesg" | grep -ao 'RHIZO_MARKER display_pool_idle_s=[0-9]*' | tail -1 | cut -d= -f2)
else
  idle_src="$VAR_DIR/vm-boot${SUFFIX}.log"
  DISPLAY_POOL_IDLE_S=$(grep -ao 'RHIZO_MARKER display_pool_idle_s=[0-9]*' "$idle_src" | tail -1 | cut -d= -f2)
fi
[[ "$DISPLAY_POOL_IDLE_S" =~ ^[0-9]+$ ]] || fail "the composer logged no 'RHIZO_MARKER display_pool_idle_s=' line on this boot's console ($idle_src)"
if [[ "$DISPLAY_POOL_IDLE_S" =~ ^[0-9]+$ ]] && (( DISPLAY_POOL_IDLE_S > 0 )); then
  step "4. idle release/re-arm leg ($IDLE_CYCLES cycles, composer display_pool_idle_s=$DISPLAY_POOL_IDLE_S)"
  IDLE_MARGIN=20
  idle_deadline_budget=$(( DISPLAY_POOL_IDLE_S + IDLE_MARGIN ))
  last_arm=$(_ssh_vm_out 15 "dmesg | grep -o 'pool_idle_armed release_at=[0-9]*' | tail -1 | cut -d= -f2")
  if [[ "$last_arm" =~ ^[0-9]+$ ]]; then
    drain_until=$(( last_arm + 5 ))
    (( $(date +%s) < drain_until )) && log "    draining the stress loop's own pending arms until $drain_until ($(( drain_until - $(date +%s) ))s)"
    while (( $(date +%s) < drain_until )); do sleep 2; done
  else
    log "    no 'pool_idle_armed' marker on the guest's kmsg yet -- nothing pending to drain"
  fi
  for ((cyc = 1; cyc <= IDLE_CYCLES; cyc++)); do
    dl=$(query_display_list) || { fail "idle-release cycle $cyc: the composer answered no 'display list' before the cycle"; break; }
    s1=$(rhizo_dl_spares "$dl" | head -1)
    if [[ -z "$s1" ]]; then
      before_n=$(rhizo_ctl_out "$INIT" | grep -c '^display pooled id=')
      rhizo_ctl "$INIT" display pool-add 960 1080 >/dev/null
      deadline=$(( $(date +%s) + 15 ))
      while (( $(date +%s) < deadline )); do
        after_n=$(rhizo_ctl_out "$INIT" | grep -c '^display pooled id=')
        (( after_n > before_n )) && { s1=$(rhizo_ctl_out "$INIT" | grep '^display pooled id=' | tail -1 | grep -o 'id=[0-9]*' | cut -d= -f2); break; }
        sleep 0.3
      done
    fi
    if [[ -z "$s1" ]]; then fail "idle-release cycle $cyc: could not prime a spare to claim"; break; fi

    rhizo_ctl "$INIT" display claim "$s1" >/dev/null
    claim_deadline=$(( $(date +%s) + 15 ))
    claimed=0
    while (( $(date +%s) < claim_deadline )); do
      rhizo_ctl_out "$INIT" | grep -q "^display claimed id=$s1\$" && { claimed=1; break; }
      sleep 0.3
    done
    if (( ! claimed )); then fail "idle-release cycle $cyc: display $s1 never claimed"; break; fi

    before_n=$(rhizo_ctl_out "$INIT" | grep -c '^display pooled id=')
    rhizo_ctl "$INIT" display pool-add 960 1080 >/dev/null
    s2=""
    deadline=$(( $(date +%s) + 15 ))
    while (( $(date +%s) < deadline )); do
      after_n=$(rhizo_ctl_out "$INIT" | grep -c '^display pooled id=')
      (( after_n > before_n )) && { s2=$(rhizo_ctl_out "$INIT" | grep '^display pooled id=' | tail -1 | grep -o 'id=[0-9]*' | cut -d= -f2); break; }
      sleep 0.3
    done
    if [[ -z "$s2" ]]; then fail "idle-release cycle $cyc: refill never produced a new spare"; break; fi

    rhizo_ctl "$INIT" display remove "$s1" >/dev/null

    released=0
    deadline=$(( $(date +%s) + idle_deadline_budget ))
    while (( $(date +%s) < deadline )); do
      rhizo_ctl_out "$INIT" | grep -q "^display spare-released id=$s2\$" && { released=1; break; }
      sleep 2
    done
    if (( ! released )); then
      fail "idle-release cycle $cyc: no 'display spare-released id=$s2' within ${idle_deadline_budget}s"
      break
    fi
    dl_after=$(query_display_list) || { fail "idle-release cycle $cyc: the composer answered no 'display list' after the release"; break; }
    if grep -qE "(^| )${s2}\([0-9]+x[0-9]+" <<<"$dl_after"; then
      fail "idle-release cycle $cyc: display $s2 still in 'display list' after its own spare-released reply"
      break
    fi
    if [[ -n "$(rhizo_dl_spares "$dl_after")" ]]; then
      fail "idle-release cycle $cyc: a spare is still listed after the release: $dl_after"
      break
    fi

    dmabuf_now=$(dmabuf_objs_kb) || { fail "idle-release cycle $cyc: could not read dma-buf after release"; break; }
    dmabuf_now_objs=${dmabuf_now% *}
    obj_delta=$(( dmabuf_now_objs - DMABUF_BASE_OBJS ))
    log "    cycle $cyc: released id=$s2, dma-buf now ${dmabuf_now_objs} objects (${obj_delta} vs baseline)"
    if (( obj_delta > 30 )); then
      fail "idle-release cycle $cyc: dma-buf objects ${obj_delta} above baseline after release"
      break
    fi
    idle_released=$((idle_released + 1))
  done
  log "    idle release/re-arm: $idle_released/$IDLE_CYCLES cycles released and confirmed"
  (( idle_released == IDLE_CYCLES )) || fail "idle release/re-arm leg: $idle_released/$IDLE_CYCLES cycles clean"
else
  step "4. idle release/re-arm leg: skipped (composer display_pool_idle_s=${DISPLAY_POOL_IDLE_S:-unknown}, the release never fires)"
fi

cp "$SUMMARY" "$EV/summary-$(date +%s).tsv" 2>/dev/null || true

dmabuf_delta="dmabuf_delta=+${obj_growth:-0}objs/+${kb_growth:-0}kB"

verdict_params="iterations=$ITERATIONS idle_cycles=$IDLE_CYCLES"
verdict_info="$dmabuf_delta own_content_iterations=$OWN_CONTENT logcat_lines_scanned=$scanned extra_displays=$extra_count ss_pid_start=$SS_PID_START ss_pid_end=$SS_PID_END idle_release_cycles=$idle_released/$IDLE_CYCLES"
(( REPEAT_SEEN )) && verdict_info="$verdict_info stopped_early=repeat reason=\"$LAST_FAIL_REASON\" repeats=$REPEAT_COUNT at_iter=$iter"
if (( FAILED )); then log "DISPLAY STRESS SYSTEM TEST FAILED ($CLEAN/$ITERATIONS clean)"; test_record_verdict FAILED "$verdict_params" "$verdict_info"; exit 1; fi
rig_result_keep "$EV/summary.tsv"
log "DISPLAY STRESS SYSTEM TEST PASSED -- $CLEAN/$ITERATIONS clean, $extra_count extra displays, system_server pid $SS_PID_START unchanged, $scanned logcat lines scanned. Evidence in $EV"
test_record_verdict PASSED "$verdict_params" "$verdict_info"
