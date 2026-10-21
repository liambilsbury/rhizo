#!/bin/bash
# test that system_server survives idle, reclaim and freeze legs
# RHIZO_RELEASE=a15 targets that release through test_boot; default a16
# test-boot-mode: shared
# test-boots-unit: no
# test-records-metrics: no
# test-requires: none
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
RECORD_BASELINE=0
FREEZE_LEGS="10 60"
LEGS_NOTE="default"
NO_UNIT=0
WITH_UNIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-boot) SKIP_BOOT=1; shift ;;
    --quick)     FREEZE_LEGS="10";               LEGS_NOTE="QUICK (dev loop, not a real system test run)"; shift ;;
    --long)      FREEZE_LEGS="10 60 600 3600";   LEGS_NOTE="LONG (includes the one-hour datapoint)"; shift ;;
    --freeze-durations) FREEZE_LEGS="$2";        LEGS_NOTE="explicit"; shift 2 ;;
    --record-baseline) RECORD_BASELINE=1; shift ;;
    --no-unit)   NO_UNIT=1; shift ;;
    --with-unit) WITH_UNIT=1; shift ;;
    *) echo "sleep.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
# print the verdict params
verdict_params() {
  [[ "$LEGS_NOTE" == default || "$LEGS_NOTE" == LONG* ]] || printf 'freeze_legs=%s' "${FREEZE_LEGS// /,}"
}
(( WITH_UNIT )) && export RHIZO_USE_UNIT=1

EV="$(test_evidence_dir sleep)"
mkdir -p "$EV" && : > "$EV/failures.log"
# shellcheck disable=SC2034
TEST_NAME="sleep"
test_trap_signals
rig_test_started
mkdir -p "$EV"
for f in "$EV"/meter-frozen-*.json; do
  [[ -e "$f" ]] || continue
  leg="${f##*meter-frozen-}"; leg="${leg%.json}"
  keep=0
  for want in $FREEZE_LEGS; do [[ "$leg" == "$want" ]] && { keep=1; break; }; done
  (( keep )) || { log "evidence hygiene: removing leftover $f (leg ${leg}s not in this run's [$FREEZE_LEGS])"; rm -f "$f"; }
done
WORKDIR=$(mktemp -d)
FAILED=0
RELAUNCH_MS=0
RELAUNCH_DISP=

BASELINE="$VAR_DIR/sleep-baseline.tsv"
MEASURE="$EV/measurements.tsv"
: > "$MEASURE"
# append a measurement row and log it
record() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$MEASURE"; log "    [measured] $1 = $2 ${3:-}"; }

# print the top resumed activity on a display
resumed_on() {
  android_sh "$1" "dumpsys activity activities" \
    | awk -v want="Display #$2 " '/Display #/ {inseg = index($0, want) > 0}
                                   inseg && /topResumedActivity=/ {print; exit}' \
    | sed 's/.*ActivityRecord{[^ ]* [^ ]* \([^ }]*\).*/\1/'
}

# print the stack's cgroup
stack_cgroup() {
  local ipath result
  ipath=$(ssh_vm -t 10 "sed -n 's|^0::||p' /proc/$1/cgroup" 2>/dev/null)
  [[ -n "$ipath" ]] || return 1
  result=$(ssh_vm -t 10 "level='$ipath'
    while :; do
      [ -d \"/sys/fs/cgroup\$level/system\" ] && { echo \"\$level\"; break; }
      [ \"\$level\" = / ] && break
      level=\${level%/*}
      [ -z \"\$level\" ] && level=/
    done" 2>/dev/null)
  [[ -n "$result" ]] || return 1
  echo "/sys/fs/cgroup${result%/}"
}

STACK_UNIT=""
_FROZEN_CG=""
_WATCHDOG_PIDFILE="$WORKDIR/watchdog.pid"
# undo the freeze and remove the work directory
cleanup_on_exit() {
  if [[ -f "$_WATCHDOG_PIDFILE" ]]; then
    kill "$(cat "$_WATCHDOG_PIDFILE" 2>/dev/null)" 2>/dev/null
  fi
  if [[ -n "$_FROZEN_CG" ]]; then
    log "cleanup: stack was left frozen -- issuing the unfreeze this exit path skipped"
    stack_unfreeze "$_FROZEN_CG" 2>/dev/null
  fi
  rm -rf "$WORKDIR"
}
trap cleanup_on_exit EXIT
# freeze a cgroup in the guest under a watchdog
stack_freeze() {
  _FROZEN_CG="$1"
  rm -f "$_WATCHDOG_PIDFILE"
  setsid bash -c '
    echo $$ > "$1"
    sleep 4200
    timeout 60 ssh -i "$2" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=8 -p "$3" "$4" \
        "echo 0 > $5/cgroup.freeze" 2>/dev/null
  ' _ "$_WATCHDOG_PIDFILE" "$SSH_KEY" "$SSH_PORT" "$SSH_TARGET" "$1" \
    < /dev/null > /dev/null 2>&1 &
  disown
  ssh_vm -t 15 "echo 1 > $1/cgroup.freeze"
}
# unfreeze a cgroup in the guest
stack_unfreeze() {
  local rc
  ssh_vm -t 15 "echo 0 > $1/cgroup.freeze"; rc=$?
  (( rc == 0 )) && _FROZEN_CG=""
  if [[ -f "$_WATCHDOG_PIDFILE" ]]; then
    kill "$(cat "$_WATCHDOG_PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$_WATCHDOG_PIDFILE"
  fi
  return "$rc"
}

# print each frozen uid_*/pid_* leaf under a cgroup root
frozen_app_cgroups() {
  ssh_vm -t 15 "root='$1'
    for p in \"\$root\"/*/*/*/ \"\$root\"/*/*/*/*/; do
      [ -d \"\$p\" ] || continue
      cgp=\${p%/}
      leaf=\${cgp##*/}
      parent=\${cgp%/*}
      parent_leaf=\${parent##*/}
      case \"\$leaf\" in
        pid_*)
          case \"\$parent_leaf\" in
            uid_*)
              [ -f \"\$cgp/cgroup.freeze\" ] || continue
              [ \"\$(cat \"\$cgp/cgroup.freeze\" 2>/dev/null)\" = 1 ] && echo \"\$cgp\"
              ;;
          esac
          ;;
      esac
    done" 2>/dev/null
}

# take and pull a stack-meter.py sample
meter() {
  local secs="$1" name="$2"
  ssh_vm -t $((secs + 120)) "python3 /root/stack-meter.py --sample $secs --format json --out /tmp/meter-$name.json" >/dev/null 2>&1
  pull "/tmp/meter-$name.json" "$EV/meter-$name.json" || return 1
  echo "$EV/meter-$name.json"
}

# print a KSM sysfs value from the guest kernel
ksm_read() {
  ssh_vm -t 10 "cat /sys/kernel/mm/ksm/$1 2>/dev/null" 2>/dev/null
}
# write 0 or 1 to the guest kernel's KSM run switch
ksm_set_run() {
  ssh_vm -t 10 "echo $1 > /sys/kernel/mm/ksm/run" >/dev/null 2>&1
}
# print the ksmd kthread's utime plus stime in seconds
ksmd_cpu_seconds() {
  ssh_vm -t 10 'p=$(pgrep -x ksmd); if [ -n "$p" ]; then hz=$(getconf CLK_TCK); awk -v hz="$hz" "{printf \"%.3f\", (\$14+\$15)/hz}" /proc/$p/stat; fi' 2>/dev/null
}

# print a top-level number from a meter json
mval() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print('' if v is None else v)" "$1" "$2" 2>/dev/null
}

# record a meter sample's cgroup memory figures
record_cgroup_mem() {
  local j="$1" p="$2"
  python3 - "$j" <<'PYEOF' | while IFS=$'\t' read -r k v; do record "${p}_${k}" "$v"; done
import json, sys
d = json.load(open(sys.argv[1]))["cgroup_after"]
st = d.get("memory_stat") or {}
print("memory_current\t%s" % d.get("memory_current"))
print("memory_swap_current\t%s" % d.get("memory_swap_current"))
print("memory_peak\t%s" % d.get("memory_peak"))
print("memory_swap_peak\t%s" % d.get("memory_swap_peak"))
print("memory_zswap_current\t%s" % d.get("memory_zswap_current"))
print("memory_zswap_max\t%s" % d.get("memory_zswap_max"))
for k in sorted(st):
    print("memory_%s\t%s" % (k, st[k]))
PYEOF
}

step "sleep.sh: freeze legs = [$FREEZE_LEGS] ($LEGS_NOTE)"

if (( SKIP_BOOT == 0 )); then
  step "0. boot: VM, compositor, Android"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up > "$EV/sway.log" 2>&1 || { fail "the desktop session did not start (see $EV/sway.log)"; exit 1; }
  ../../vm/sync.sh > "$EV/sync.log" 2>&1 || { fail "sync.sh failed (see $EV/sync.log)"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 240 > "$EV/redeploy.log" 2>&1 || { fail "redeploy.sh failed (see $EV/redeploy.log)"; exit 1; }
  tail -3 "$EV/redeploy.log"
else
  test_ensure_sway "$EV/chained-sway.log" "$EV/chained-redeploy.log"
fi

INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
log "init_pid=$INIT"
boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"
SS_PID_START=$(system_server_pid "$INIT")
SF_PID_START=$(surfaceflinger_pid "$INIT")
log "system_server=$SS_PID_START surfaceflinger=$SF_PID_START"
TEST_SINCE=$(logcat_since_marker "$INIT")

CG=$(stack_cgroup "$INIT") || { fail "could not find the stack's cgroup"; exit 1; }
STACK_UNIT=$(ssh_vm -t 10 "INIT=$INIT; "'mp=$(systemctl show -p MainPID --value androidd.service 2>/dev/null); p=$INIT
while [ -n "$mp" ] && [ "$mp" != 0 ] && [ -n "$p" ] && [ "$p" -gt 1 ]; do
  [ "$p" = "$mp" ] && { echo androidd.service; break; }
  p=$(awk "/^PPid/{print \$2}" /proc/$p/status 2>/dev/null)
done
true')
log "stack cgroup: $CG${STACK_UNIT:+ (unit: $STACK_UNIT)}"
record stack_cgroup "$CG"
record stack_unit "${STACK_UNIT:-<none, pre-unit launch path>}"
swap_kb=$(ssh_vm -t 10 'grep ^SwapTotal /proc/meminfo | tr -s " " | cut -d" " -f2')
record swap_total_kb "${swap_kb:-0}"
[[ "${swap_kb:-0}" -gt 0 ]] || fail "no swap configured"
ssh_vm -t 10 "test -f $CG/memory.reclaim" || fail "$CG/memory.reclaim absent"

primer_cg=$(ssh_vm -t 15 'p=$(pgrep -f rhizo-host-primer | head -1); [ -n "$p" ] && sed -n "s|^0::||p" /proc/$p/cgroup' 2>/dev/null)
record host_primer_cgroup "${primer_cg:-<no primer>}"
if [[ -n "$primer_cg" ]]; then
  cg_rel="${CG#/sys/fs/cgroup}"
  [[ "$primer_cg" == "$cg_rel" || "$primer_cg" == "$cg_rel/"* ]] \
    && fail "the host primer is inside the freeze scope ($primer_cg)"
  [[ "$primer_cg" == "$cg_rel" || "$primer_cg" == "$cg_rel/"* ]] \
    || pass "host primer is outside the freeze scope ($primer_cg, stack is $cg_rel)"
fi

android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "locksettings set-disabled true" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
awake=$(wait_device_awake "$INIT")
[[ "$awake" == "mWakefulness=Awake" ]] || fail "device is not awake ($awake)"
pass "booted, awake, keyguard disabled, swap present, memory controller delegated"

rig_run_identity "$EV/run.txt" --manifest-dir "$EV" 2>/dev/null \
  || log "rig_run_identity could not write $EV/run.txt (non-fatal)"

prior_before=$(rhizo_ctl_out "$INIT" | grep -c '^display list' || true)
rhizo_ctl "$INIT" display list >/dev/null
prior_dlist=""
prior_deadline=$(( $(date +%s) + 15 ))
while (( $(date +%s) < prior_deadline )); do
  if [[ "$(rhizo_ctl_out "$INIT" | grep -c '^display list' || true)" -gt "${prior_before:-0}" ]]; then
    prior_dlist=$(rhizo_ctl_out "$INIT" | grep '^display list' | tail -1)
    break
  fi
  sleep 1
done
[[ -n "$prior_dlist" ]] \
  || fail "the composer answered no 'display list' within 15s"
prior_removed=""
for entry in $(grep -oE '[0-9]+\([^)]*\)' <<<"$prior_dlist"); do
  did="${entry%%(*}"
  [[ "$did" == 1 || "$entry" == *,pool* ]] && continue
  rhizo_ctl "$INIT" display remove "$did" >/dev/null 2>&1
  prior_removed+="$did "
done
log "    displays earlier system tests left, removed before this system test's own: ${prior_removed:-none} (${prior_dlist#display list })"

step "1. AWAKE: two apps, two windows"
MANIFEST="$WORKDIR/rhizo-apps.json"
python3 ../../../src/services/appsync/appsync.py "$INIT" --manifest "$MANIFEST" --min-apps 2 > "$EV/appsync.log" 2>&1
napps=$(python3 -c "import json; print(len(json.load(open('$MANIFEST'))['apps']))" 2>/dev/null || echo 0)
[[ "$napps" -ge 2 ]] || { fail "fewer than 2 launchable apps enumerated"; exit 1; }
cp "$MANIFEST" "$EV/rhizo-apps.json"

# launch a manifest app through rhizo-launch.sh
launch_app() {
  local idx="$1" pkg act line disp cdisp
  read -r pkg act <<<"$(python3 -c "import json; a=json.load(open('$MANIFEST'))['apps']; print(a[$idx]['package'], a[$idx]['activity'])")"
  ssh_vm -t 60 "/usr/lib/rhizo/tools/rhizo-launch.sh $pkg $act" >/dev/null 2>&1
  line=$(ssh_vm -t 10 "tail -1 /run/rhizo-launch/rhizo-launch.log" 2>/dev/null)
  disp=$(echo "$line" | grep -oE '(^|[[:space:]])display=[0-9]+' | cut -d= -f2)
  cdisp=$(echo "$line" | grep -o 'cdisplay=[0-9]*' | cut -d= -f2)
  cdisp=${cdisp:-$disp}
  echo "$pkg $act ${cdisp:-}"
}

read -r PKG1 ACT1 CDISP1 <<<"$(launch_app 0)"
[[ -n "$CDISP1" ]] || fail "app A produced no display id"
read -r PKG2 _ CDISP2 <<<"$(launch_app 1)"
[[ -n "$CDISP2" ]] || fail "app B produced no display id"
log "    app A=$PKG1 cdisplay=$CDISP1   app B=$PKG2 cdisplay=$CDISP2"

# print each app display with a mapped window
app_windows() {
  local d
  for d in "$CDISP1" "$CDISP2"; do
    desktop_window_rect "$d" >/dev/null 2>&1 && echo "$d $(desktop_window_rect "$d")"
  done
}
nwin=0
last_ss="$SS_PID_START"; deadline=$(( $(date +%s) + 300 ))
while (( $(date +%s) < deadline )); do
  nwin=$(app_windows | wc -l)
  (( nwin >= 2 )) && break
  cur_ss=$(system_server_pid "$INIT")
  if [[ -n "$cur_ss" && "$cur_ss" != "$last_ss" ]]; then
    log "  system_server restarted mid-poll ($last_ss -> $cur_ss)"
    last_ss="$cur_ss"
    continue
  fi
  sleep 1
done
record awake_windows "$nwin"
record awake_all_toplevels "$(desk_windows | wc -l)"
if (( nwin < 2 )); then
  { echo "=== expected cdisplay ids: A=$CDISP1 ($PKG1)  B=$CDISP2 ($PKG2)"
    echo "=== the compositor's toplevels ==="; desk_windows
    echo "=== launch stages (claimed vs fallback) ==="
    ssh_vm -t 15 "grep -E 'event=stage|event=am_start_return' /run/rhizo-launch/rhizo-launch.log | tail -40" 2>/dev/null
    echo "=== dumpsys display viewports ==="
    android_sh "$INIT" "dumpsys display | grep -E 'mViewports|Display #|committedState'" 2>/dev/null
  } > "$EV/awake-unmapped-debug.txt" 2>&1 || true
  log "    wrote $EV/awake-unmapped-debug.txt (which display failed to map, and its state)"
fi
[[ "$nwin" -ge 2 ]] || fail "expected 2 mapped app toplevels, sway reports $nwin after a 300s wall-clock budget (with system_server-restart resets)"

awake_json=$(meter 10 awake) || fail "could not take the AWAKE measurement"
if [[ -n "${awake_json:-}" ]]; then
  record awake_pss_kb "$(mval "$awake_json" pss_sum_kb)"
  record awake_rss_kb "$(mval "$awake_json" rss_sum_kb)"
  record awake_procs_in_cgroup "$(mval "$awake_json" procs_in_cgroup)"
  record awake_procs_unreadable "$(mval "$awake_json" procs_unreadable)"
  record awake_cpu_pct "$(mval "$awake_json" cpu_pct_of_one_core)" "% of one core"
  record_cgroup_mem "$awake_json" awake
fi
pass "two apps live in two concurrent windows"

step "2. both windows closed (real xdg_toplevel.close)"
closed=0
for _ in $(seq 1 40); do
  [[ -z "$(app_windows)" ]] && { closed=1; break; }
  for d in "$CDISP1" "$CDISP2"; do
    desktop_close_display_window "$d"
  done
  sleep 1
done
record app_windows_after_close "$(app_windows | wc -l)"
record all_toplevels_after_close "$(desk_windows | wc -l)"
(( closed )) || fail "app toplevels still mapped after closing both app windows"

for d in "$CDISP1" "$CDISP2"; do
  rhizo_ctl "$INIT" display remove "$d" >/dev/null 2>&1 || true
done
(( closed )) && pass "both app toplevels gone"

teardown=0
last_ss=$(system_server_pid "$INIT"); deadline=$(( $(date +%s) + 180 ))
while (( $(date +%s) < deadline )); do
  wins=$(desktop_composer_windows) && [[ -z "$wins" ]] && { teardown=1; break; }
  cur_ss=$(system_server_pid "$INIT")
  if [[ -n "$cur_ss" && "$cur_ss" != "$last_ss" ]]; then
    log "  system_server restarted mid-poll ($last_ss -> $cur_ss)"
    last_ss="$cur_ss"
    continue
  fi
  sleep 1
done
wins=$(desktop_composer_windows) || wins="<desk_windows failed>"
printf '%s\n' "${wins:-<none>}" > "$EV/toplevels-after-teardown.txt"
record wayland_toplevels_after_teardown "$(grep -c $'\t' <<<"$wins")"
IDS_AT_TEARDOWN=$(cut -f2 <<<"$wins")
(( teardown )) || fail "composer still holds Wayland surfaces after the last app window closed. Still mapped: [$(tr '\n' '|' <<<"$wins")] (full listing in $EV/toplevels-after-teardown.txt)"
(( teardown )) && pass "composer dropped every Wayland surface on the last app window closing"

step "3. IDLE-CORE: the stay-awake released, the device left alone"
android_sh "$INIT" "settings put global stay_on_while_plugged_in 0" >/dev/null
android_sh "$INIT" "cmd battery unplug" >/dev/null
android_sh "$INIT" "input keyevent 223" >/dev/null
_settle_prev=""; _settle_hits=0; _settle_waited=0
# print the stack cgroup's usage_usec from cpu.stat
_cpu_usec() { ssh_vm -t 20 "awk '/^usage_usec/{print \$2}' /sys/fs/cgroup/rhizo/cpu.stat" 2>/dev/null | tr -dc '0-9'; }
_p0=$(_cpu_usec)
while (( _settle_waited < ${IDLE_SETTLE_MAX_S:-180} )); do
  sleep 10
  _settle_waited=$(( _settle_waited + 10 ))
  _p1=$(_cpu_usec)
  if [[ -z "$_p0" || -z "$_p1" ]]; then _p0="$_p1"; continue; fi
  _cur=$(awk -v a="$_p0" -v b="$_p1" 'BEGIN{printf "%.3f", (b-a)/100000.0}')
  _p0="$_p1"
  if [[ -n "$_settle_prev" ]] && awk -v a="$_cur" -v b="$_settle_prev" \
       'BEGIN{d=a-b; if(d<0)d=-d; t=b*0.10; if(t<0.15)t=0.15; exit !(d<=t)}'; then
    _settle_hits=$(( _settle_hits + 1 ))
    (( _settle_hits >= 2 )) && break
  else
    _settle_hits=0
  fi
  _settle_prev="$_cur"
done
record idle_settle_s "$_settle_waited" "wall seconds until CPU stabilized"
(( _settle_hits >= 2 )) || log "    (idle never stabilized within ${IDLE_SETTLE_MAX_S:-180}s)"
power=$(android_sh "$INIT" "dumpsys power")
wake=$(grep -m1 -o "mWakefulness=[A-Za-z]*" <<<"$power")
record idle_wakefulness "${wake:-unknown}"

KSM_WRITABLE=$(ssh_vm -t 10 "test -w /sys/kernel/mm/ksm/run && echo 1 || echo 0" 2>/dev/null)
if [[ "$KSM_WRITABLE" == "1" ]]; then
  KSM_CPU_BEFORE=$(ksmd_cpu_seconds)
  ksm_set_run 1
  record ksm_run_enabled 1
else
  record ksm_run_enabled 0
  log "    KSM sysfs not writable on this kernel -- KSM measurement skipped"
fi

idle_json=$(meter 30 idle) || fail "could not take the IDLE measurement"
if [[ -n "${idle_json:-}" ]]; then
  idle_cpu=$(mval "$idle_json" cpu_pct_of_one_core)
  idle_cpu_s=$(mval "$idle_json" cpu_seconds)
  idle_ctxt=$(mval "$idle_json" ctxt_switches)
  record idle_cpu_pct "$idle_cpu" "% of one core over 30s"
  record idle_cpu_seconds "$idle_cpu_s"
  record idle_ctxt_switches "$idle_ctxt"
  record idle_pss_kb "$(mval "$idle_json" pss_sum_kb)"
  record idle_rss_kb "$(mval "$idle_json" rss_sum_kb)"
  record_cgroup_mem "$idle_json" idle
  awk -v v="${idle_cpu:-100}" 'BEGIN{exit !(v < 5.0)}' \
    || fail "idle CPU is ${idle_cpu}% of one core with no windows open"
  if [[ -f "$BASELINE" ]]; then
    base_ctxt=$(awk -F'\t' '$1=="idle_ctxt_switches"{print $2}' "$BASELINE")
    base_pss=$(awk -F'\t' '$1=="idle_pss_kb"{print $2}' "$BASELINE")
    if [[ -n "$base_ctxt" ]]; then
      awk -v v="${idle_ctxt:-100000}" -v b="$base_ctxt" 'BEGIN{exit !(v <= b * 1.5 + 5)}' \
        || fail "idle wakeups regressed: ${idle_ctxt} context switches over 30s vs baseline ${base_ctxt}"
    fi
    if [[ -n "$base_pss" ]]; then
      idle_pss=$(mval "$idle_json" pss_sum_kb)
      awk -v v="${idle_pss:-0}" -v b="$base_pss" 'BEGIN{exit !(v <= b * 1.2)}' \
        || fail "idle PSS regressed: ${idle_pss}kB vs baseline ${base_pss}kB"
    fi
    log "    (regressed against $BASELINE)"
  else
    log "    NO BASELINE at $BASELINE -- this run records the numbers, it does not judge them"
  fi
  pass "idle at ${idle_cpu}% of one core, ${idle_ctxt} context switches over 30s"
fi

step "4. reclaim"
before_cur=$(ssh_vm -t 10 "cat $CG/memory.current")
before_swap=$(ssh_vm -t 10 "cat $CG/memory.swap.current")
want=$(( before_cur / 4 ))
orig_swappiness=$(ssh_vm -t 10 'cat /proc/sys/vm/swappiness' 2>/dev/null)
[[ -n "$orig_swappiness" ]] && ssh_vm -t 10 "echo 200 > /proc/sys/vm/swappiness" >/dev/null 2>&1
reclaim_rounds=0; rc=0; round_cur="$before_cur"
while (( reclaim_rounds < 8 )); do
  want=$(( round_cur / 4 ))
  ssh_vm -t 120 "echo $want swappiness=200 > $CG/memory.reclaim 2>/dev/null || echo $want > $CG/memory.reclaim" >/dev/null 2>&1
  rc=$?
  reclaim_rounds=$(( reclaim_rounds + 1 ))
  next_cur=$(ssh_vm -t 10 "cat $CG/memory.current")
  next_swap=$(ssh_vm -t 10 "cat $CG/memory.swap.current")
  [[ -n "$next_cur" && -n "$next_swap" ]] || break
  (( next_swap > before_swap )) && { round_cur="$next_cur"; break; }
  moved=$(( round_cur - next_cur )); (( moved < 0 )) && moved=$(( -moved ))
  round_cur="$next_cur"
  (( moved * 100 < round_cur )) && break
done
sleep 5
[[ -n "$orig_swappiness" ]] && ssh_vm -t 10 "echo $orig_swappiness > /proc/sys/vm/swappiness" >/dev/null 2>&1
after_cur=$(ssh_vm -t 10 "cat $CG/memory.current")
after_swap=$(ssh_vm -t 10 "cat $CG/memory.swap.current")
record reclaim_rounds "$reclaim_rounds"
record reclaim_requested_bytes "$want"
record memory_current_before "$before_cur"
record memory_current_after "$after_cur"
record memory_current_freed "$(( before_cur - after_cur ))"
record memory_swap_before "$before_swap"
record memory_swap_after "$after_swap"
record memory_swapped_out "$(( after_swap - before_swap ))"
[[ "$after_cur" -lt "$before_cur" ]] || fail "memory.reclaim freed nothing (before=$before_cur after=$after_cur, rc=$rc)"
[[ "$after_swap" -gt "$before_swap" ]] || fail "nothing was swapped out"
reclaimed_json=$(meter 5 reclaimed) && {
  record reclaimed_pss_kb "$(mval "$reclaimed_json" pss_sum_kb)"
  record_cgroup_mem "$reclaimed_json" reclaimed
}
[[ "$after_cur" -lt "$before_cur" ]] && pass "reclaim freed $(( (before_cur - after_cur) / 1048576 ))MB, swapped out $(( (after_swap - before_swap) / 1048576 ))MB"

if [[ "$KSM_WRITABLE" == "1" ]]; then
  ksm_set_run 0
  ksm_pages_shared=$(ksm_read pages_shared)
  ksm_pages_sharing=$(ksm_read pages_sharing)
  ksm_general_profit=$(ksm_read general_profit)
  KSM_CPU_AFTER=$(ksmd_cpu_seconds)
  record ksm_pages_shared "${ksm_pages_shared:-0}"
  record ksm_pages_sharing "${ksm_pages_sharing:-0}"
  record ksm_general_profit "${ksm_general_profit:-0}" "bytes, kernel's own net-savings estimate (mm/ksm.c)"
  ksm_scan_cpu=$(awk -v a="${KSM_CPU_BEFORE:-0}" -v b="${KSM_CPU_AFTER:-0}" 'BEGIN{printf "%.3f", b-a}')
  record ksm_scan_cpu_seconds "$ksm_scan_cpu" "ksmd CPU-seconds spent scanning during this IDLE-CORE window"
  ksm_mb_saved=$(awk -v p="${ksm_pages_sharing:-0}" 'BEGIN{printf "%.3f", p*4096/1048576}')
  record ksm_mb_saved_estimate "$ksm_mb_saved" "MB, pages_sharing * 4KiB"
  log "    KSM: ${ksm_pages_shared:-0} pages_shared, ${ksm_pages_sharing:-0} pages_sharing (~${ksm_mb_saved}MB), general_profit=${ksm_general_profit:-0}B, ksmd cost ${ksm_scan_cpu}s"
fi

step "5. relaunch from idle"
# relaunch app A and wait for its window content
relaunch_and_prove() {
  local label="$1" t0 t1 line disp cdisp region wx wy ww wh nb dis stats
  t0=$(date +%s%N)
  ssh_vm -t 60 "/usr/lib/rhizo/tools/rhizo-launch.sh $PKG1 $ACT1" >/dev/null 2>&1
  line=$(ssh_vm -t 10 "tail -1 /run/rhizo-launch/rhizo-launch.log" 2>/dev/null)
  disp=$(echo "$line" | grep -oE '(^|[[:space:]])display=[0-9]+' | cut -d= -f2)
  cdisp=$(echo "$line" | grep -o 'cdisplay=[0-9]*' | cut -d= -f2)
  cdisp=${cdisp:-$disp}
  [[ -n "$disp" ]] || { fail "$label: relaunch produced no display id"; return 1; }
  local got=""
  for _ in $(seq 1 40); do
    got=$(desktop_mapped_window_rect "$cdisp")
    [[ -n "$got" ]] && break
    sleep 1
  done
  [[ -n "$got" ]] || { fail "$label: no window rect for display $disp (composer id $cdisp)"; return 1; }
  read -r wx wy ww wh <<<"$got"
  region="$wx,$wy,$ww,$wh"
  for _ in $(seq 1 25); do
    desk_shot "/tmp/rhizo-sleep-$label.png" >/dev/null 2>&1 || { sleep 1; continue; }
    pull "/tmp/rhizo-sleep-$label.png" "$EV/frame-$label.png" || { sleep 1; continue; }
    stats=$(python3 ../tools/pngstat.py "$EV/frame-$label.png" --region "$region")
    nb=$(echo "$stats" | grep '^nonblack_pct=' | cut -d= -f2)
    dis=$(echo "$stats" | grep '^distinct=' | cut -d= -f2)
    awk -v v="${nb:-0}" 'BEGIN{exit !(v>50)}' && [[ "${dis:-0}" -gt 20 ]] && break
    sleep 1
  done
  t1=$(date +%s%N)
  RELAUNCH_MS=$(( (t1 - t0) / 1000000 ))
  RELAUNCH_DISP="$cdisp"
  awk -v v="${nb:-0}" 'BEGIN{exit !(v>50)}' \
    || { fail "$label: relaunched window is not showing real content (${nb:-<no shot>}% nonblack)"; return 1; }
  [[ "${dis:-0}" -gt 20 ]] \
    || { fail "$label: relaunched window looks like a flat fill (${dis:-<no shot>} distinct colors)"; return 1; }
  return 0
}

if relaunch_and_prove idle; then
  record relaunch_from_idle_ms "$RELAUNCH_MS"
  pass "relaunched from idle in ${RELAUNCH_MS}ms, real composited content"
  new_ids=0
  if wins_after=$(desktop_composer_windows); then
    new_ids=$(cut -f2 <<<"$wins_after" | grep -vxF -f <(printf '%s\n' "${IDS_AT_TEARDOWN:-}") | grep -c .)
  else
    wins_after="<desk_windows failed>"
  fi
  printf '%s\n' "${wins_after:-<none>}" > "$EV/toplevels-after-relaunch.txt"
  record toplevels_created_by_relaunch "$new_ids"
  [[ "$new_ids" -gt 0 ]] \
    || fail "the desktop holds no toplevel the teardown did not already have ($EV/toplevels-after-relaunch.txt)"
fi
[[ -n "$RELAUNCH_DISP" ]] && { desktop_close_display_window "$RELAUNCH_DISP" || log "    could not close display $RELAUNCH_DISP's window"; }
sleep 3

[[ "${KSM_WRITABLE:-0}" == "1" ]] && ksm_set_run 0
step "6. DEEP-ASLEEP: freeze/unfreeze legs"
for secs in $FREEZE_LEGS; do
  log "--- freeze leg ${secs}s"
  before_stock_frozen=$(frozen_app_cgroups "$CG")
  stack_freeze "$CG" || { fail "${secs}s: could not freeze"; break; }
  frozen=""
  for _ in $(seq 1 10); do
    frozen=$(ssh_vm -t 10 "grep -c '^frozen 1' $CG/cgroup.events")
    [[ "$frozen" == "1" ]] && break
    sleep 1
  done
  [[ "$frozen" == "1" ]] || { fail "${secs}s: cgroup never reported frozen"; stack_unfreeze "$CG"; break; }

  fj=$(meter "$secs" "frozen-$secs")
  if [[ -n "${fj:-}" ]]; then
    fcpu=$(mval "$fj" cpu_seconds); fctxt=$(mval "$fj" ctxt_switches)
    record "frozen_${secs}s_cpu_seconds" "$fcpu"
    record "frozen_${secs}s_ctxt_switches" "$fctxt"
    record_cgroup_mem "$fj" "frozen_${secs}s"
    awk -v v="${fcpu:-1}" 'BEGIN{exit !(v == 0)}' \
      || fail "${secs}s: a frozen stack burned ${fcpu} CPU-seconds"
  fi

  t0=$(date +%s%N)
  stack_unfreeze "$CG" || fail "${secs}s: could not unfreeze"
  unfrozen=""
  for _ in $(seq 1 20); do
    unfrozen=$(ssh_vm -t 10 "grep -c '^frozen 0' $CG/cgroup.events")
    [[ "$unfrozen" == "1" ]] && break
    sleep 1
  done
  t1=$(date +%s%N)
  record "thaw_${secs}s_ms" "$(( (t1 - t0) / 1000000 ))" "ms, incl. one ssh round trip"
  [[ "$unfrozen" == "1" ]] || { fail "${secs}s: cgroup never reported unfrozen"; break; }

  after_stock_frozen=$(frozen_app_cgroups "$CG")
  missing=$(comm -23 <(sort <<<"${before_stock_frozen:-}") <(sort <<<"${after_stock_frozen:-}") | grep -v '^$')
  gained=$(comm -13 <(sort <<<"${before_stock_frozen:-}") <(sort <<<"${after_stock_frozen:-}") | grep -v '^$')
  [[ -z "$missing" ]] \
    || log "    (${secs}s: stock reaped $(wc -l <<<"$missing") frozen cached app(s) whose process exited during this leg's own window: [$missing])"
  [[ -z "$gained" ]] \
    || log "    (${secs}s: stock froze $(wc -l <<<"$gained") more app(s) during this leg's own window, on CachedAppOptimizer's own clock, not disturbed by our cycle: [$gained])"
  stock_frozen_count=0
  [[ -n "$after_stock_frozen" ]] && stock_frozen_count=$(wc -l <<<"$after_stock_frozen")
  before_stock_count=0
  [[ -n "${before_stock_frozen:-}" ]] && before_stock_count=$(wc -l <<<"$before_stock_frozen")
  missing_count=0
  [[ -n "$missing" ]] && missing_count=$(wc -l <<<"$missing")
  gained_count=0
  [[ -n "$gained" ]] && gained_count=$(wc -l <<<"$gained")
  record "${secs}s_stock_frozen_app_cgroups" "$stock_frozen_count" \
    "after-set size; before=$before_stock_count missing=$missing_count gained=$gained_count"

  sleep 10
  ss=$(system_server_pid "$INIT"); sf=$(surfaceflinger_pid "$INIT")
  record "after_${secs}s_system_server_pid" "$ss"
  record "after_${secs}s_surfaceflinger_pid" "$sf"
  [[ "$ss" == "$SS_PID_START" ]] || fail "${secs}s freeze: system_server restarted ($SS_PID_START -> $ss)"
  [[ "$sf" == "$SF_PID_START" ]] || fail "${secs}s freeze: surfaceflinger restarted ($SF_PID_START -> $sf)"
  wd=$(logcat_vm "$INIT" -d -t "$TEST_SINCE" 2>/dev/null | grep -cE "$TEST_WATCHDOG_KILL_RE")
  record "after_${secs}s_watchdog_kills" "${wd:-0}"
  [[ "${wd:-0}" == "0" ]] || fail "${secs}s freeze: $wd Watchdog kill line(s) in logcat"
  probe=$(probe_cmd 30 'getprop sys.boot_completed' 2>&1 | head -1)
  record "after_${secs}s_probe" "${probe:-<no answer>}"

  if relaunch_and_prove "unfreeze-$secs"; then
    record "relaunch_after_${secs}s_ms" "$RELAUNCH_MS"
    pass "${secs}s freeze: unfrozen clean, relaunched in ${RELAUNCH_MS}ms with real content"
    [[ -n "$RELAUNCH_DISP" ]] && { desktop_close_display_window "$RELAUNCH_DISP" || log "    could not close display $RELAUNCH_DISP's window"; }
    sleep 3
  fi
  (( FAILED )) && { log "aborting the freeze legs"; break; }
done

if [[ -n "$STACK_UNIT" ]]; then
  step "6b. STOPPED tier: systemctl stop / start"
  t0=$(date +%s%N)
  ssh_vm -t 90 "systemctl stop $STACK_UNIT" || fail "systemctl stop $STACK_UNIT failed"
  t1=$(date +%s%N)
  record stop_ms "$(( (t1 - t0) / 1000000 ))"
  gone=$(ssh_vm -t 15 "$RHIZO_INIT_SCAN_BODY | grep -c .; true" 2>/dev/null | tail -1)
  record init_procs_after_stop "${gone:-<unknown>}"
  [[ "$gone" == "0" ]] || fail "init is still running after systemctl stop (init processes: '${gone:-<unknown>}')"
  up=$(ssh_vm -t 20 'uptime -s' 2>/dev/null)
  record guest_alive_after_stop "${up:-<GUEST GONE>}"
  [[ -n "$up" ]] || fail "the guest did not survive systemctl stop"
  t0=$(date +%s%N)
  ssh_vm -t 300 "systemctl start $STACK_UNIT" || fail "systemctl start $STACK_UNIT failed"
  bc2=""; start_deadline=$((SECONDS + 180))
  while :; do
    INIT=$(guest_init_pid 10)
    [[ -n "$INIT" ]] && bc2=$(getprop_vm "$INIT" sys.boot_completed)
    [[ "$bc2" == "1" ]] && break
    (( SECONDS < start_deadline )) || break
    sleep 1
  done
  t1=$(date +%s%N)
  record cold_start_ms "$(( (t1 - t0) / 1000000 ))"
  record cold_start_boot_completed "${bc2:-<none>}"
  [[ "$bc2" == "1" ]] || fail "after systemctl start, sys.boot_completed='$bc2' within 180s"
  [[ "$bc2" == "1" ]] && pass "graceful stop and a real cold start via the unit ($(awk -F'\t' '$1=="cold_start_ms"{print $2}' "$MEASURE")ms to genuine boot_completed)"
  SS_PID_START=$(system_server_pid "$INIT")
  SF_PID_START=$(surfaceflinger_pid "$INIT")
else
  record stopped_tier_tested "0"
  if (( WITH_UNIT )); then
    fail "STOPPED tier requested via --with-unit but the stack is not running under a unit"
  elif (( NO_UNIT )); then
    step "6b. STOPPED tier: skipped (--no-unit requested it)"
  else
    step "6b. STOPPED tier: skipped (pass --with-unit to exercise it)"
  fi
fi

step "7. regression check"
SS_PID_END=$(system_server_pid "$INIT")
SF_PID_END=$(surfaceflinger_pid "$INIT")
boot_end=$(getprop_live "$INIT" sys.boot_completed) || boot_end="<unreadable rc=$?>"
log "    system_server $SS_PID_START -> $SS_PID_END, surfaceflinger $SF_PID_START -> $SF_PID_END, sys.boot_completed=$boot_end"
[[ "$SS_PID_START" == "$SS_PID_END" ]] || fail "system_server restarted ($SS_PID_START -> $SS_PID_END)"
[[ "$SF_PID_START" == "$SF_PID_END" ]] || fail "surfaceflinger restarted ($SF_PID_START -> $SF_PID_END)"
[[ "$boot_end" == "1" ]] || fail "sys.boot_completed is '$boot_end'"
logcat_vm "$INIT" -d -t "$TEST_SINCE" > "$EV/logcat.txt" 2>/dev/null
test_logcat_capture_read "$EV/logcat.txt" \
  || fail "the fatal sweep read no logcat since '$TEST_SINCE'"
bad=$(grep -cE "$TEST_FATAL_RE" "$EV/logcat.txt")
log "    fatal/watchdog lines in logcat: $bad (crash events: $(test_crash_events "$EV/logcat.txt"))"
[[ "$bad" == "0" ]] || {
  fail "logcat has $bad fatal/watchdog lines"
  test_fatal_lines "$EV/logcat.txt"
}
ssh_vm -t 20 'dmesg | tail -400' > "$EV/dmesg-tail.txt" 2>/dev/null

SUMMARY_TARGET="$(rig_result_path "$EV/summary.txt")"
{
  echo "sleep.sh summary -- $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "freeze legs: [$FREEZE_LEGS] ($LEGS_NOTE)"
  echo "stack cgroup: $CG"
  echo
  cat "$MEASURE"
  echo
  echo "result: $( ((FAILED)) && echo FAIL || echo PASS )"
} > "$SUMMARY_TARGET"

if (( FAILED )); then
  test_record_verdict FAILED "$(verdict_params)"
  log "SLEEP SYSTEM TEST FAILED"
  exit 1
fi

if (( RECORD_BASELINE )); then
  if [[ "$LEGS_NOTE" == "default" || "$LEGS_NOTE" == LONG* ]]; then
    cp "$MEASURE" "$BASELINE"
    log "baseline recorded at $BASELINE; later runs regress against it"
  else
    log "NOT recording a baseline: this was a [$FREEZE_LEGS] ($LEGS_NOTE) run, not a full one"
  fi
fi
[[ "$LEGS_NOTE" == "default" ]] || log "NOTE: freeze legs were [$FREEZE_LEGS] ($LEGS_NOTE) -- not the default system test run"
rig_result_keep "$EV/summary.txt"
test_record_verdict PASSED "$(verdict_params)"
log "SLEEP SYSTEM TEST PASSED -- evidence in $EV"
