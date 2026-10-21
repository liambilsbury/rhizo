#!/bin/bash
# test rt.budgets, rt.contain and instance.cpu_max
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-requires: none
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
SELFTEST=0
for arg in "$@"; do
  case "$arg" in
    --skip-boot) SKIP_BOOT=1 ;;
    --selftest) SELFTEST=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

export RHIZO_USE_UNIT=1
test_init rt-budgets
SELFTEST_STEPS=()
echo "<none: leg H not reached>" >"$EV/status-contain.json"
echo "<none: leg B not reached>" >"$EV/status-recur.json"
echo "<none: leg L not reached>" >"$EV/carve-snapshot.txt"
# record the step name instead of running steps in selftest mode
# shellcheck disable=SC2034
step() { TEST_STEP="$*"; SELFTEST_STEPS+=("$*"); log "=== $*"; }

POLICY_CONF=/etc/rhizo/policy.conf
POLICY_SAVED=/etc/rhizo/policy.conf.rt-budgets-test
INSTANCE_CONF=/etc/rhizo/instances/0.conf
INSTANCE_SAVED=/etc/rhizo/instances/0.conf.rt-budgets-test
INSTANCE_CONF_ARMED=0
CARVE_CG=""
STATUS=/run/rhizo-rtd/status.json
RTD_PY=/usr/lib/rhizo/rtd/rtd.py
PKG=com.android.settings
COVER_ACT=com.android.deskclock/.DeskClock
ACT=com.android.settings/.homepage.SettingsHomepageActivity

# put back whatever policy.conf the vm had, on all of the exit paths
restore_policy_conf() {
  local got
  (( TEST_NO_VM )) && return 0
  ssh_vm -t 20 "if [ -e $POLICY_SAVED ]; then mv -f $POLICY_SAVED $POLICY_CONF; else rm -f $POLICY_CONF; fi
    systemctl stop rhizo-rtd.service" >/dev/null 2>&1
  (( INSTANCE_CONF_ARMED )) || return 0
  got=$(ssh_vm -t 20 "had=0; [ -e $INSTANCE_SAVED ] && had=1
    if [ \$had = 1 ]; then mv -f $INSTANCE_SAVED $INSTANCE_CONF; else rm -f $INSTANCE_CONF; fi
    cg='/sys/fs/cgroup$CARVE_CG'; if [ -z '$CARVE_CG' ]; then cg=\$(cat /root/.rhizo_cgroup_root 2>/dev/null); cg=\${cg%/android}; fi
    if [ -n \"\$cg\" ] && [ -e \"\$cg/cpu.max\" ]; then printf 'max 100000\n' > \"\$cg/cpu.max\"; cat \"\$cg/cpu.max\"; fi
    echo had=\$had conf=\$(test -e $INSTANCE_CONF && echo present || echo absent)" 2>&1 | tr -d '\r' | tr '\n' ' ')
  case "$got" in
    *"had=1 conf=present"*|*"had=0 conf=absent"*) log "CLEANUP_OK: instance 0's overlay restored, cpu.max put back ($got)" ;;
    *) log "CLEANUP_INCOMPLETE: instance 0's overlay or cpu.max ($got)" ;;
  esac
}
# shellcheck disable=SC2034
TEST_EXTRA_CLEANUP=restore_policy_conf

# corrupt a received value under --selftest
seen() { if (( SELFTEST )); then echo "$2"; else echo "$1"; fi; }

# wait for a guest command to succeed
await_vm() {
  local deadline=$(( $(date +%s) + $1 ))
  while (( $(date +%s) < deadline )); do
    ssh_vm -t 15 "$2" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# query status.json with a python expression
status_q() {
  local js
  js=$(ssh_vm -t 15 "cat $STATUS 2>/dev/null")
  STATUS_JSON="$js" python3 -c "
import json, os, sys
try:
    s = json.loads(os.environ['STATUS_JSON'])
except ValueError:
    print('<status unreadable>'); sys.exit(3)
print($1)"
}

# read debug.hwui.use_hint_manager
hwui_prop() {
  local v rc
  v=$(getprop_live "$INIT" debug.hwui.use_hint_manager); rc=$?
  case $rc in 0) echo "$v" ;; 95) echo "<unset>" ;; *) echo "<unreadable rc=$rc>" ;; esac
}

# print the kernel's admitted SCHED_DEADLINE bandwidth
dl_total_bw() {
  ssh_vm -t 15 "mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
    grep -m1 'dl_bw->total_bw' /sys/kernel/debug/sched/debug | awk '{print \$3}'" | tr -d '\r'
}

# print how many threads in the guest have the deadline class
dln_threads() { ssh_vm -t 15 "ps -eLo cls --no-headers | grep -c DLN" | tr -d '\r'; }

TEST_RUN_ID="$(date +%s).$$"
# write a numbered mark line to the guest kernel log
kmsg_mark() { ssh_vm -t 10 "echo 'rt-budgets-test mark $1/$TEST_RUN_ID.' > /dev/kmsg"; }

# print the kernel log after a mark
dmesg_after() {
  ssh_vm -t 20 "dmesg | awk -v m='rt-budgets-test mark $1/$TEST_RUN_ID.' 'f; index(\$0, m) { f = 1 } END { if (!f) print \"NO_MARK\" }'; echo KMSG_END" | tr -d '\r'
}

# print kernel units against grants plus reservation
kernel_vs_grants() {
  local snap=""
  for _ in 1 2 3 4 5; do
    snap=$(ssh_vm -t 15 "a=\$(grep -m1 'dl_bw->total_bw' /sys/kernel/debug/sched/debug | awk '{print \$3}')
      s=\$(cat $STATUS); b=\$(grep -m1 'dl_bw->total_bw' /sys/kernel/debug/sched/debug | awk '{print \$3}')
      [ \"\$a\" = \"\$b\" ] && echo \"\$a \$s\"" | tr -d '\r')
    [[ -n "$snap" ]] && break
  done
  echo "${snap:-<none>}" >"$1"
  SNAP="$snap" BASE="$DL_BASE" python3 -c "
import json, os
total, st = os.environ['SNAP'].split(' ', 1)
st = json.loads(st)
own = st.get('self_reservation') or {}
own = (own['runtime_ns'] << 20) // own['period_ns'] if own.get('granted') else 0
granted = sum((int(rt) << 20) // int(period) for rt, period in st['grants'].values())
print(int(total) - int(os.environ['BASE']), granted + own, own)" 2>/dev/null
}

# print the processes left in the daemon's unit cgroup
rtd_cgroup_procs() {
  ssh_vm -t 15 "d=/sys/fs/cgroup/system.slice/rhizo-rtd.service
    if [ ! -d \$d ]; then echo 0; elif p=\$(cat \$d/cgroup.procs); then printf '%s' \"\$p\" | grep -c .; else echo unreadable; fi" | tr -d '\r'
}

# turn rt.budgets on with rt.budget_percent set to $1
write_policy() {
  ssh_vm -t 20 "mkdir -p /etc/rhizo; printf '[rt]\nbudgets = on\nbudget_percent = %s\n' $1 > $POLICY_CONF" \
    || { fail "could not write $POLICY_CONF"; return 1; }
}

# write a policy.conf with rt.contain_percent and rt.contain_period_us set
write_policy_contain() {
  ssh_vm -t 20 "mkdir -p /etc/rhizo; printf '[rt]\nbudgets = off\ncontain = on\ncontain_percent = %s\ncontain_runtime_us = 2000\ncontain_period_us = 16667\n' $1 > $POLICY_CONF" \
    || { fail "could not write $POLICY_CONF for rt.contain"; return 1; }
}

# restart only the daemon
restart_rtd_only() {
  ssh_vm -t 30 "systemctl restart rhizo-rtd.service" >"$EV/$1-rtd-restart.txt" 2>&1 \
    || { fail "rhizo-rtd.service did not start ($EV/$1-rtd-restart.txt)"; return 1; }
}

# print the host pid of SurfaceFlinger
sf_pid() { ssh_vm -t 10 "pgrep -x surfaceflinger | head -1" | tr -d '\r'; }

# print all of the real-time threads in the sandbox's process tree
sandbox_rt_threads() {
  ssh_vm -t 30 "pids=\$(ps -e -o pid=,ppid= | awk -v root=$INIT '{ up[\$1] = \$2 }
      END { for (p in up) { q = p; while (q in up && q != root && q > 1) q = up[q]; if (q == root) print p } }' | paste -sd,)
    ps -L -o tid=,cls=,pri=,comm=,pid= -p \"\$pids\" | awk '\$2 == \"FF\" || \$2 == \"RR\" || \$2 == \"DLN\"'
    echo RT_END" | tr -d '\r' >"$1"
}

# wait for the sandbox to hold no SCHED_FIFO/RR thread
await_no_fifo() {
  local deadline=$(( $(date +%s) + $1 ))
  while :; do
    sandbox_rt_threads "$2"
    grep -qx RT_END "$2" && ! awk '$2 == "FF" || $2 == "RR"' "$2" | grep -q . && return 0
    (( $(date +%s) < deadline )) || return 1
    sleep 1
  done
}

# print all of the binder pool threads of a host pid
sf_pool_threads() {
  ssh_vm -t 20 "ps -L -o tid=,cls=,pri=,comm= -p $1 | awk '\$4 ~ /^binder:[0-9]+_[0-9]+\$/'
    echo POOL_END" | tr -d '\r' >"$2"
}

# wait for all of the pool threads to be SCHED_DEADLINE
await_sf_pool_contained() {
  local deadline=$(( $(date +%s) + $2 ))
  while :; do
    sf_pool_threads "$1" "$3"
    grep -qx POOL_END "$3" && grep -v -x POOL_END "$3" | grep -q . \
      && ! grep -v -x POOL_END "$3" | awk '$2 != "DLN"' | grep -q . && return 0
    (( $(date +%s) < deadline )) || return 1
    sleep 1
  done
}

# print the daemon's main thread scheduling class
rtd_main_cls() {
  ssh_vm -t 15 "pid=\$(systemctl show -p MainPID --value rhizo-rtd.service)
    [ -n \"\$pid\" ] && [ \"\$pid\" != 0 ] && ps -o cls= -p \"\$pid\"" | tr -d '\r' | tr -d ' '
}

# print kernel units against contain grants plus reservation
contain_kernel_vs_grants() {
  local snap=""
  for _ in 1 2 3 4 5; do
    snap=$(ssh_vm -t 15 "a=\$(grep -m1 'dl_bw->total_bw' /sys/kernel/debug/sched/debug | awk '{print \$3}')
      s=\$(cat $STATUS); b=\$(grep -m1 'dl_bw->total_bw' /sys/kernel/debug/sched/debug | awk '{print \$3}')
      [ \"\$a\" = \"\$b\" ] && echo \"\$a \$s\"" | tr -d '\r')
    [[ -n "$snap" ]] && break
  done
  echo "${snap:-<none>}" >"$2"
  SNAP="$snap" BASE="$1" python3 -c "
import json, os
total, st = os.environ['SNAP'].split(' ', 1)
st = json.loads(st)
own = st.get('self_reservation') or {}
own = (own['runtime_ns'] << 20) // own['period_ns'] if own.get('granted') else 0
granted = sum((int(rt) << 20) // int(period) for rt, period in st.get('contain_grants', {}).values())
print(int(total) - int(os.environ['BASE']), granted + own, own)" 2>/dev/null
}

# restart the daemon and the stack and relaunch Settings
restart_with_settings() {
  ssh_vm -t 30 "systemctl restart rhizo-rtd.service" >"$EV/$1-rtd-restart.txt" 2>&1 \
    || { fail "rhizo-rtd.service did not start ($EV/$1-rtd-restart.txt)"; return 1; }
  test_publish_session_env || { fail "could not publish the desktop session env"; return 1; }
  test_restart_stack "$EV/$1-restart.log" || { fail "the stack did not come back ($EV/$1-restart.log)"; return 1; }
  INIT=$(guest_init_pid 10)
  wait_device_awake "$INIT" 20 >/dev/null
  android_stay_awake "$INIT" >/dev/null
  launch_settings "$1"
}

# launch Settings and set its display, logical id and pid
launch_settings() {
  local line
  ssh_vm -t 150 "/usr/lib/rhizo/tools/rhizo-launch.sh $PKG ${ACT#*/}" >"$EV/$1-launch.txt" 2>&1
  line=$(ssh_vm -t 15 "grep -a ' pkg=$PKG ' /run/rhizo-launch/rhizo-launch.log | grep -a -v 'event=' | grep -a ' cdisplay=' | tail -1")
  CDISP=$(grep -o ' cdisplay=[0-9]*' <<<"$line" | cut -d= -f2)
  LOGICAL=$(grep -o ' display=[0-9]*' <<<"$line" | cut -d= -f2)
  [[ -n "$CDISP" && -n "$LOGICAL" ]] || { fail "Settings got no display (cdisplay='$CDISP' logical='$LOGICAL')"; return 1; }
  android_sh "$INIT" "am start --display $LOGICAL -n $ACT" >/dev/null 2>&1
  APP_PID=""
  for _ in $(seq 20); do
    APP_PID=$(ssh_vm -t 10 "ps -eo pid,args --no-headers | awk '\$2==\"$PKG\"{print \$1}' | head -1" | tr -d '\r')
    [[ -n "$APP_PID" ]] && break
    sleep 1
  done
  [[ -n "$APP_PID" ]] || { fail "no $PKG process on the host"; return 1; }
  log "    Settings: host pid $APP_PID, composer display $CDISP, logical display $LOGICAL"
}

# print the activity resumed on top of a logical display
resumed_on() {
  android_sh "$1" "dumpsys activity activities" \
    | awk -v want="Display #$2 " '/Display #/ {inseg = index($0, want) > 0}
                                   inseg && /topResumedActivity=/ {print; exit}' \
    | sed 's/.*ActivityRecord{[^ ]* [^ ]* \([^ }]*\).*/\1/'
}

# swipe Settings' list from inside Android
swipe_for() {
  ANDROID_SH_TIMEOUT=$(( $1 + 30 )) android_sh "$INIT" "end=\$((\$(date +%s) + $1))
    while [ \$(date +%s) -lt \$end ]; do
      input -d $LOGICAL swipe 480 800 480 300 200 || exit 1
      input -d $LOGICAL swipe 480 300 480 800 200 || exit 1
    done"
}

# wait for the background swipes a leg started
end_swipes() {
  [[ -n "${SWIPE_JOB:-}" ]] || return 0
  wait "$SWIPE_JOB" || fail "the background swipes on display $LOGICAL failed"
  SWIPE_JOB=""
}

if (( SKIP_BOOT == 0 )); then
  step "0. boot the guest, the desktop session and the stack with rt.budgets at its default"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up >"$EV/sway.log" 2>&1 || { fail "the desktop session did not start (see $EV/sway.log)"; exit 1; }
  ../../vm/sync.sh >"$EV/sync.log" 2>&1 || { fail "sync.sh failed (see $EV/sync.log)"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 240 >"$EV/redeploy.log" 2>&1 \
    || { fail "redeploy.sh failed (see $EV/redeploy.log)"; exit 1; }
fi
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
wait_device_awake "$INIT" 20 >/dev/null
android_stay_awake "$INIT" >/dev/null
kmsg_mark start || { fail "could not write a mark into the kernel log"; exit 1; }
TEST_T0=$(ssh_vm -t 15 "date +%s" | tr -d '\r')
DL_BASE=$(dl_total_bw)
[[ "$DL_BASE" =~ ^[0-9]+$ ]] || { fail "could not read the kernel's deadline bandwidth total ('$DL_BASE')"; exit 1; }
ssh_vm -t 15 "rm -f $POLICY_SAVED; if [ -e $POLICY_CONF ]; then cp -a $POLICY_CONF $POLICY_SAVED; fi" \
  || { fail "could not snapshot $POLICY_CONF"; exit 1; }
ssh_vm -t 15 "grep -q '^\[rt\]' $POLICY_CONF 2>/dev/null" \
  && { fail "$POLICY_CONF already configures [rt]; the off leg needs the default"; exit 1; }

step "A. capability off: no daemon, no socket, no deadline thread, no hwui opt-in, HAL sessions off"
v=$(seen "$(ssh_vm -t 10 'echo $(systemctl is-active rhizo-rtd.service) $(test -e /run/rhizo-rt && echo present || echo absent)' | tr -d '\r') $(rtd_cgroup_procs)" "active present 1")
read -r state dir procs <<<"$v"
[[ "$state" != active && "$dir" == absent && "$procs" == 0 ]] \
  && pass "no rhizo-rtd ($state, $procs processes in its cgroup) and no /run/rhizo-rt" \
  || fail "off left the daemon ($state, $procs processes in its cgroup) or /run/rhizo-rt ($dir)"
v=$(seen "$(ssh_vm -t 10 "test -e /proc/$INIT/root/dev/socket/rhizo_rt && echo present || echo absent" | tr -d '\r')" present)
[[ "$v" == absent ]] && pass "no /dev/socket/rhizo_rt in the sandbox" || fail "sandbox has /dev/socket/rhizo_rt with the capability off"
v=$(seen "$(dln_threads)" 1)
[[ "$v" == 0 ]] && pass "no SCHED_DEADLINE thread on the host" || fail "$v SCHED_DEADLINE threads with the capability off"
hwui=$(hwui_prop)
v=$(seen "$hwui" true)
[[ "$v" != true && "$v" != "<unreadable"* ]] && pass "debug.hwui.use_hint_manager unset ('$v')" \
  || fail "debug.hwui.use_hint_manager '$v' with the capability off"
v=$(seen "$(ssh_vm -t 10 "dmesg | grep -a -o 'RHIZO_MARKER power_sessions=[a-z]*' | tail -1" | tr -d '\r')" "RHIZO_MARKER power_sessions=on")
[[ "$v" == "RHIZO_MARKER power_sessions=off" ]] && pass "the power HAL reported sessions off" || fail "power HAL marker: '$v'"

step "C. a 1% cap is enforced: the grant is clamped or refused and logged with both values"
write_policy 1 && restart_with_settings cap1 && { swipe_for 6 || fail "swipes on display $LOGICAL failed"; }
await_vm 30 "grep -q 'cap: requested=' $STATUS" || log "    no cap line within 30s"
v=$(seen "$(status_q "' '.join(r for r in s.get('refusals', []) if r.startswith('cap: requested='))")" "")
log "    cap lines: ${v:-<none>}"
ok=$(V="$v" python3 -c "
import os, re
lines = re.findall(r'cap: requested=([0-9.]+) granted=([0-9.]+) cap=([0-9.]+)', os.environ['V'])
print(int(any(float(g) <= float(c) + 1e-9 < float(r) for r, g, c in lines)))")
[[ "$ok" == 1 ]] && pass "a request above the cap was cut to fit" || fail "no cap line with granted <= cap < requested"
v=$(seen "$(V="$v" python3 -c "
import os, re
print(int(bool(re.search(r'cap: requested=[0-9.]+ granted=[0-9.]+ cap=[0-9.]+ pool=budgets tenant=\S+', os.environ['V']))))")" 0)
[[ "$v" == 1 ]] && pass "the cap line names its pool and its tenant after requested, granted and cap" \
  || fail "no cap line ends in pool=budgets tenant=<cgroup> ($v)"
v=$(seen "$(status_q "'%.6f %.6f' % (s['granted_bw'], s['cap_bw'])")" "2.0 0.04")
read -r g c <<<"$v"
python3 -c "import sys; sys.exit(0 if float('$g') <= float('$c') + 1e-9 else 1)" 2>/dev/null \
  && pass "granted bandwidth $g within cap $c" || fail "granted bandwidth '$g' over cap '$c'"
v=$(seen "$(kernel_vs_grants "$EV/bw-snapshot-cap1.txt")" "50000 50000 0")
read -r got want own <<<"$v"
capu=$(status_q "int(s['cap_bw'] * (1 << 20))")
[[ -n "$got" && "$got" == "$want" && "$own" =~ ^[0-9]+$ && "$capu" =~ ^[0-9]+$ ]] && (( got - own <= capu )) \
  && pass "the kernel admitted exactly the daemon's grants plus its own $own-unit reservation ($got units), grants within the cap's $capu" \
  || fail "kernel admitted '$got' units, the daemon's grants and own reservation come to '$want' (own '$own'), the cap is '$capu' ($EV/bw-snapshot-cap1.txt)"

step "B. capability on: Settings' session gives its RenderThread a capped SCHED_DEADLINE budget"
kmsg_mark B || fail "could not write a mark into the kernel log"
write_policy 25 && restart_with_settings on
v=$(seen "$(ssh_vm -t 10 "test -S /proc/$INIT/root/dev/socket/rhizo_rt/rtd && echo present || echo absent" | tr -d '\r')" absent)
[[ "$v" == present ]] && pass "the sandbox sees /dev/socket/rhizo_rt/rtd" || fail "no rtd socket inside the sandbox"
hwui=$(hwui_prop)
v=$(seen "$hwui" "")
[[ "$v" == true ]] && pass "hwui opted into hint sessions" || fail "debug.hwui.use_hint_manager='$v' with the capability on"
v=$(seen "$(dmesg_after B | grep -a -o 'RHIZO_MARKER power_sessions=[a-z]*' | tail -1)" "RHIZO_MARKER power_sessions=off")
[[ "$v" == "RHIZO_MARKER power_sessions=on" ]] && pass "the power HAL reported sessions on" || fail "power HAL marker since this leg's restart: '$v'"
swipe_for 20 & SWIPE_JOB=$!
RT_TIDS=$(ssh_vm -t 10 "ps -Lo tid,comm -p $APP_PID --no-headers | awk '\$2==\"RenderThread\"{print \$1}'" | tr -d '\r' | tr '\n' ' ')
APP_TIDS=$(ssh_vm -t 10 "ls /proc/$APP_PID/task" | tr -d '\r' | tr '\n' ' ')
await_vm 30 "python3 -c \"import json,sys; s=json.load(open('$STATUS')); sys.exit(0 if any(t in '$APP_TIDS'.split() for t in s['grants']) else 1)\"" \
  || log "    no grant on a Settings thread within 30s"
ssh_vm -t 10 "cat $STATUS" >"$EV/status-on.json" 2>&1
v=$(seen "$(status_q "' '.join(h for x in s['sessions'].values() for h in x['threads'] if h in '$RT_TIDS'.split())")" "")
[[ -n "$v" ]] && pass "a live session's threads include Settings' RenderThread ($v)" \
  || fail "no session names Settings' RenderThread ($RT_TIDS) -- $EV/status-on.json"
v=$(seen "$(status_q "' '.join(sorted({h for x in s['sessions'].values() if x['state']=='active' and any(t in '$APP_TIDS'.split() for t in x['threads']) for h,t in x['threads'].items() if t['policy']=='deadline'}))")" "")
log "    deadline threads in Settings' sessions: ${v:-<none>}; Settings threads: $APP_TIDS"
foreign=""
for t in $v; do [[ " $APP_TIDS " == *" $t "* ]] || foreign+=" $t"; done
[[ -n "$v" && -z "$foreign" ]] && pass "Settings' session holds SCHED_DEADLINE on its own threads ($v)" \
  || fail "deadline threads '$v', not Settings' own: '$foreign'"
GRANTED="$v"
ssh_vm -t 15 "for t in $v; do echo \$t \$(awk '/^policy/{print \$3}' /proc/\$t/sched); done" >"$EV/sched-on.txt" 2>&1
n=$(grep -c . "$EV/sched-on.txt")
v=$(seen "$(awk '$2 != 6 {print $1 ":policy=" $2}' "$EV/sched-on.txt" | tr '\n' ' ')" "forced")
[[ "$n" -ge 1 && -z "${v// /}" ]] && pass "$n granted thread(s): the kernel reports SCHED_DEADLINE (policy 6)" \
  || fail "kernel policy of the granted threads: [$v] ($EV/sched-on.txt)"
v=$(seen "$(for t in $RT_TIDS; do [[ " $GRANTED " == *" $t "* ]] && grep -qx "$t 6" "$EV/sched-on.txt" && echo "$t"; done)" "")
[[ -n "$v" ]] && pass "Settings' RenderThread ($v) is granted and the kernel runs it under SCHED_DEADLINE" \
  || fail "no RenderThread of Settings ($RT_TIDS) holds a grant the kernel runs; granted: '$GRANTED'"
v=$(seen "$(python3 -c "
import json
s = json.load(open('$EV/status-on.json'))
want, got = {}, {}
for x in s['sessions'].values():
    for h, t in x['threads'].items():
        if h in '$GRANTED'.split() and h in '$RT_TIDS'.split():
            f = t.get('frame_cpu_ns')
            w = max(200000, min(0.9 * x['period_ns'], 1.25 * f)) if f else 0
            want[h], got[h] = max(want.get(h, 0), w), t['runtime_ns']
print(' '.join('%s:runtime=%d:want=%d:%s' % (h, got[h], want[h], 'ok' if want[h] and 0.5 <= got[h] / want[h] <= 1.5 else 'off')
               for h in sorted(want)))" 2>&1)" "1:runtime=2000000:want=0:off")
[[ "$v" == *":ok"* && "$v" != *":off"* && "$v" != *Error* ]] \
  && pass "Settings' granted RenderThread is sized from its measured CPU per frame ($v)" \
  || fail "Settings' granted RenderThread is not sized 1.25 x its measured frame CPU: [$v] ($EV/status-on.json)"
recur_py="
import json, sys
s = json.load(open(sys.argv[1]))
want, target = {}, {}
for x in s['sessions'].values():
    for h in x['threads']:
        if h in '$GRANTED'.split() and h in '$RT_TIDS'.split() and h in s['grants'] and x.get('grant_period_ns'):
            want.setdefault(h, set()).add(x['grant_period_ns'])
            target[h] = x['period_ns']
out = []
for h in sorted(want):
    got, t = s['grants'][h][1], target[h]
    ok = t <= got <= 4 * t and any(0 <= got - p <= t // 4 for p in want[h])
    out.append('%s:period=%d:target=%d:frame_periods=%s:%s' % (h, got, t, ','.join(map(str, sorted(want[h]))), 'ok' if ok else 'off'))
print(' '.join(out))"
cp "$EV/status-on.json" "$EV/status-recur.json"
for recur_read in 1 2 3 4 5 6 7 8 9 10; do
  v=$(seen "$(python3 -c "$recur_py" "$EV/status-recur.json" 2>&1)" "1:period=11666666:target=11666666:frame_periods=14583332:off")
  [[ "$v" == *":ok"* && "$v" != *":off"* && "$v" != *Error* ]] && break
  (( recur_read < 10 )) && { sleep 0.3; ssh_vm -t 10 "cat $STATUS" >"$EV/status-recur.json" 2>&1; }
done
[[ "$v" == *":ok"* && "$v" != *":off"* && "$v" != *Error* ]] \
  && pass "Settings' granted RenderThread recurs at its session's frame period ($v, read $recur_read of 10)" \
  || fail "Settings' granted RenderThread does not recur at its session's frame period in 10 reads 0.3 s apart: [$v] ($EV/status-recur.json)"
HWUI_TIDS=$(ssh_vm -t 10 "ps -Lo tid,comm -p $APP_PID --no-headers | awk '\$2 ~ /^hwuiTask/{print \$1}'" | tr -d '\r' | tr '\n' ' ')
if [[ -n "${HWUI_TIDS// /}" ]]; then
  ssh_vm -t 15 "for t in $HWUI_TIDS; do echo \$t \$(awk '/^policy/{print \$3}' /proc/\$t/sched); done" >"$EV/sched-helpers-on.txt" 2>&1
else
  echo "<none>" >"$EV/sched-helpers-on.txt"
fi
n=$(grep -c ' 6$' "$EV/sched-helpers-on.txt")
v=$(seen "$(awk 'NF == 2 && $2 != 6 {print $1 ":policy=" $2}' "$EV/sched-helpers-on.txt" | tr '\n' ' ')" "forced")
[[ -n "${HWUI_TIDS// /}" && "$n" -ge 1 && -z "${v// /}" ]] \
  && pass "Settings' hwuiTask helper(s) ($HWUI_TIDS) run SCHED_DEADLINE while its RenderThread is held" \
  || fail "Settings' hwuiTask helpers ('$HWUI_TIDS'): $n at policy 6, not [$v] ($EV/sched-helpers-on.txt)"
v=$(seen "$(status_q "' '.join(sorted({h for x in s['sessions'].values() for h in x.get('helpers', {}) if h in '$HWUI_TIDS'.split()}))")" "")
[[ -n "$v" ]] && pass "Settings' session names its helpers ($v)" \
  || fail "no session names a hwuiTask helper of Settings ('$HWUI_TIDS') -- $EV/status-on.json"
BINDER_TIDS=$(ssh_vm -t 10 "ps -Lo tid,comm -p $APP_PID --no-headers | awk '\$2 ~ /^binder:/{print \$1}'" | tr -d '\r' | tr '\n' ' ')
if [[ -n "${BINDER_TIDS// /}" ]]; then
  await_vm 5 "for t in $BINDER_TIDS; do test ! -e /proc/\$t/sched || awk '/^policy/{exit \$3 != 6}' /proc/\$t/sched || exit 1; done" \
    || log "    a binder pool thread of Settings is not SCHED_DEADLINE 5s after the check began"
  ssh_vm -t 15 "for t in $BINDER_TIDS; do echo \$t \$(awk '/^policy/{print \$3}' /proc/\$t/sched); done" >"$EV/sched-binder-on.txt" 2>&1
else
  echo "<none>" >"$EV/sched-binder-on.txt"
fi
n=$(grep -c ' 6$' "$EV/sched-binder-on.txt")
v=$(seen "$(awk 'NF == 2 && $2 != 6 {print $1 ":policy=" $2}' "$EV/sched-binder-on.txt" | tr '\n' ' ')" "forced")
[[ -n "${BINDER_TIDS// /}" && "$n" -ge 1 && -z "${v// /}" ]] \
  && pass "Settings' $n binder pool thread(s) run SCHED_DEADLINE while its RenderThread is held" \
  || fail "Settings' binder pool ('$BINDER_TIDS'): $n at policy 6, not [$v] ($EV/sched-binder-on.txt)"
ssh_vm -t 10 "cat $STATUS" >"$EV/status-binder-on.json" 2>&1
v=$(seen "$(status_q "' '.join(sorted(h for x in s['sessions'].values() for h, t in x.get('helpers', {}).items() if h in '$BINDER_TIDS'.split() and t['runtime_ns'] == 200000))")" "")
[[ -n "$v" ]] && pass "Settings' session holds its binder pool at the 200us floor ($v)" \
  || fail "no session holds a binder pool thread of Settings ('$BINDER_TIDS') at 200000ns -- $EV/status-binder-on.json"
v=$(seen "$(kernel_vs_grants "$EV/bw-snapshot.txt")" "1 2 0")
read -r got want own <<<"$v"
[[ -n "$got" && "$got" == "$want" ]] && pass "the kernel admitted exactly the daemon's grants plus its own $own-unit reservation ($got units over the pre-test total)" \
  || fail "kernel admitted '$got' units over the pre-test total, the daemon's grants and own reservation come to '$want' (own '$own') ($EV/bw-snapshot.txt)"
v=$(seen "$(status_q "'%.6f %.6f' % (s['granted_bw'], s['cap_bw'])")" "2.0 1.0")
read -r g c <<<"$v"
python3 -c "import sys; sys.exit(0 if 0 < float('$g') <= float('$c') + 1e-9 else 1)" 2>/dev/null \
  && pass "granted bandwidth $g within cap $c" || fail "granted bandwidth '$g' against cap '$c'"
v=$(seen "$(rtd_main_cls)" TS)
[[ "$v" == DLN ]] && pass "rhizo-rtd's own main thread is SCHED_DEADLINE with rt.budgets on" \
  || fail "rhizo-rtd's own main thread class '$v', want DLN, with rt.budgets on"

step "D. Settings dying with budgets, and a new Settings covered by another app, give up SCHED_DEADLINE"
APP_TIDS=$(ssh_vm -t 10 "ls /proc/$APP_PID/task" | tr -d '\r' | tr '\n' ' ')
[[ -n "${APP_TIDS// /}" ]] || fail "could not list Settings' threads before its force-stop"
v=$(seen "$(status_q "' '.join(t for t in s['grants'] if t in '$APP_TIDS'.split())")" "")
[[ -n "$v" ]] && pass "Settings holds grants ($v) as it is force-stopped" || fail "Settings holds no grant to lose before its force-stop"
android_sh "$INIT" "am force-stop $PKG" >/dev/null 2>&1; rc=$?
[[ "$rc" == 0 ]] || fail "am force-stop $PKG did not run (android_sh rc=$rc)"
await_vm 15 "! test -d /proc/$APP_PID" || log "    Settings' process $APP_PID still alive 15s after force-stop"
v=$(seen "$(ssh_vm -t 10 "test -d /proc/$APP_PID && echo alive || echo gone" | tr -d '\r')" alive)
[[ "$v" == gone ]] && pass "Settings' process $APP_PID is gone" || fail "Settings' process $APP_PID is '$v' after force-stop"
named="sum(1 for x in s['sessions'].values() if any(h in '$APP_TIDS'.split() for h in list(x['threads']) + list(x.get('helpers', {})))) + sum(1 for t in s['grants'] if t in '$APP_TIDS'.split())"
await_vm 15 "python3 -c \"import json,sys; s=json.load(open('$STATUS')); sys.exit(0 if $named == 0 else 1)\"" \
  || log "    a session or grant still names a Settings thread 15s after force-stop"
v=$(seen "$(status_q "$named")" 1)
[[ "$v" == 0 ]] && pass "no session or grant names a Settings thread after its force-stop" \
  || fail "$v session(s) or grant(s) still name a Settings thread after its force-stop"
v=$(seen "$(kernel_vs_grants "$EV/bw-snapshot-forcestop.txt")" "1 2 0")
read -r got want own <<<"$v"
[[ -n "$got" && "$got" == "$want" ]] && pass "after the force-stop, the kernel counts exactly the daemon's grants plus its own $own-unit reservation ($got units)" \
  || fail "after the force-stop, the kernel counts '$got' units over the pre-test total and the daemon's grants and own reservation come to '$want' (own '$own') ($EV/bw-snapshot-forcestop.txt)"
end_swipes

launch_settings again && { swipe_for 20 & SWIPE_JOB=$!; }
await_vm 30 "python3 -c \"import json,os,sys; s=json.load(open('$STATUS')); sys.exit(0 if any(t in os.listdir('/proc/$APP_PID/task') for t in s['grants']) else 1)\"" \
  || log "    the relaunched Settings got no grant within 30s"
APP_TIDS=$(ssh_vm -t 10 "ls /proc/$APP_PID/task" | tr -d '\r' | tr '\n' ' ')
GRANTED=$(status_q "' '.join(t for t in s['grants'] if t in '$APP_TIDS'.split())")
[[ -n "$GRANTED" && "$GRANTED" != "<status unreadable>" ]] || fail "the relaunched Settings holds no grant to give up"
PRIOR=$(status_q "' '.join(sorted({h: t['prior'] for x in s['sessions'].values() for h,t in list(x['threads'].items()) + list(x.get('helpers', {}).items()) if h in '$GRANTED'.split()}.values()))")
android_sh "$INIT" "am start --display $LOGICAL -n $COVER_ACT" >/dev/null 2>&1
top=""
for _ in $(seq 10); do
  top=$(resumed_on "$INIT" "$LOGICAL")
  [[ "$top" == "$COVER_ACT" ]] && break
  sleep 1
done
v=$(seen "$top" "$PKG/${ACT#*/}")
[[ "$v" == "$COVER_ACT" ]] && pass "$COVER_ACT covers Settings on display $LOGICAL" \
  || fail "display $LOGICAL's resumed activity is '$v', not $COVER_ACT"
await_vm 15 "! ps -Lo cls -p $APP_PID --no-headers | grep -q DLN" || log "    Settings still has deadline threads after 15s"
v=$(seen "$(ssh_vm -t 10 "ps -Lo cls -p $APP_PID --no-headers | grep -c DLN" | tr -d '\r')" 2)
[[ "$v" == 0 ]] && pass "covered Settings holds no SCHED_DEADLINE thread" || fail "$v Settings threads still SCHED_DEADLINE after it was covered"
now=$(ssh_vm -t 10 "ps -L -o tid=,cls=,ni= -p $APP_PID" | tr -d '\r' \
  | awk -v want=" $GRANTED " 'index(want, " " $1 " ") { print ($2 == "TS" ? "other" : $2) ":" $3 }' | LC_ALL=C sort | tr '\n' ' ')
v=$(seen "${now% }" "DLN:-")
[[ -n "$PRIOR" && "$v" == "$PRIOR" ]] && pass "granted threads restored to their prior policy ($PRIOR)" \
  || fail "granted threads after revoke '$v', recorded prior '$PRIOR'"
v=$(seen "$(kernel_vs_grants "$EV/bw-snapshot-covered.txt")" "1 2 0")
read -r got want own <<<"$v"
[[ -n "$got" && "$got" == "$want" ]] && pass "after the cover, the kernel counts exactly the daemon's grants plus its own $own-unit reservation ($got units)" \
  || fail "after the cover, the kernel counts '$got' units over the pre-test total and the daemon's grants and own reservation come to '$want' (own '$own') ($EV/bw-snapshot-covered.txt)"
end_swipes

ssh_vm -t 30 "systemctl stop rhizo-rtd.service" >/dev/null 2>&1 || fail "rhizo-rtd.service did not stop"
v=$(seen "$(rtd_cgroup_procs)" 1)
[[ "$v" == 0 ]] && pass "the stop left no process in the daemon's cgroup" || fail "$v process(es) left in rhizo-rtd.service's cgroup after its stop"
v=$(seen "$(ssh_vm -t 10 "test -e /run/rhizo-rt && echo present || echo absent" | tr -d '\r')" present)
[[ "$v" == absent ]] && pass "the stop removed /run/rhizo-rt" || fail "/run/rhizo-rt outlived the daemon's stop ($v)"
v=$(seen "$(dl_total_bw)" "$(( DL_BASE + 1 ))")
[[ "$v" == "$DL_BASE" ]] && pass "deadline bandwidth back to its pre-test total ($DL_BASE) after the revokes and the daemon's stop" \
  || fail "kernel deadline total is $v, was $DL_BASE before any grant: revoked bandwidth is still counted"
v=$(seen "$(dln_threads)" 1)
[[ "$v" == 0 ]] && pass "no SCHED_DEADLINE thread outlived the daemon" || fail "$v SCHED_DEADLINE thread(s) outlived the daemon"
ssh_vm -t 30 "systemctl start rhizo-rtd.service" >/dev/null 2>&1 || fail "rhizo-rtd.service did not start again for leg E"

step "E. a peer that is not the power HAL is refused, and the root selftest refuses a foreign tid"
before=$(dln_threads)
ssh_vm -t 15 "python3 -c \"
import os, socket
print(os.getpid(), flush=True)
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
try:
    s.connect('/run/rhizo-rt/rtd')
except OSError as e:
    print('refused', e.errno, flush=True)
else:
    s.send(b'open 9 1 0 16666666 1')
    print('connected', flush=True)
\"" 2>&1 | tr -d '\r' >"$EV/forged-peer.txt"
fp=$(head -1 "$EV/forged-peer.txt")
outcome=$(sed -n 2p "$EV/forged-peer.txt")
denials=$(ssh_vm -t 15 "dmesg | grep -a -c -E '\{ connectto \} for +pid=$fp .*tcontext=u:r:rhizo_rtd:s0'" | tr -d '\r')
v=$(seen "$outcome $denials" "connected 0")
[[ "$v" == "refused 13 1" && "$before" =~ ^[0-9]+$ && "$(dln_threads)" == "$before" ]] \
  && pass "host peer pid $fp refused at connect by SELinux (EACCES, one denial logged), deadline thread count unchanged" \
  || fail "host peer pid '$fp': outcome and denials '$v', want 'refused 13 1' ($EV/forged-peer.txt)"
ssh_vm -t 60 "python3 $RTD_PY --selftest" >"$EV/selftest-vm.txt" 2>&1; rc=$?
v=$(seen "$rc $(grep -c 'SELFTEST OK:   a peer whose context is not' "$EV/selftest-vm.txt")" "1 0")
[[ "$v" == "0 1" ]] && pass "rhizo-rtd --selftest on the vm, its peer check included: $(tail -1 "$EV/selftest-vm.txt")" \
  || fail "rhizo-rtd --selftest on the vm rc=$rc ($EV/selftest-vm.txt)"
ssh_vm -t 120 "python3 $RTD_PY --selftest-root" >"$EV/selftest-root.txt" 2>&1; rc=$?
v=$(seen "$rc $(grep -c 'assertions passed' "$EV/selftest-root.txt")" "1 0")
[[ "$v" == "0 1" ]] && pass "rhizo-rtd --selftest-root: $(tail -1 "$EV/selftest-root.txt")" \
  || fail "rhizo-rtd --selftest-root rc=$rc ($EV/selftest-root.txt)"

step "G. rt.contain off: Android's own SCHED_FIFO/RR threads run as Android set them"
sandbox_rt_threads "$EV/contain-off.txt"
grep -qx RT_END "$EV/contain-off.txt" || fail "the sandbox's thread list could not be read whole ($EV/contain-off.txt)"
grep -v -x RT_END "$EV/contain-off.txt" | awk '{print $1, $2 ":" $3}' | sort > "$EV/contain-off-map.txt"
n=$(awk '$2 == "FF" || $2 == "RR"' "$EV/contain-off.txt" | grep -c .)
v=$(seen "$(awk '$2 == "DLN"' "$EV/contain-off.txt" | grep -c .)" 1)
[[ "$n" -ge 2 && "$v" == 0 ]] \
  && pass "$n Android thread(s) at SCHED_FIFO/RR and none at SCHED_DEADLINE with rt.contain off ($EV/contain-off.txt)" \
  || fail "$n Android FIFO/RR thread(s) and $v at SCHED_DEADLINE with rt.contain off ($EV/contain-off.txt)"
SF_PID=$(sf_pid)
[[ "$SF_PID" =~ ^[0-9]+$ ]] || fail "no surfaceflinger pid on the host (got '$SF_PID')"
sf_pool_threads "${SF_PID:-0}" "$EV/sf-pool-off.txt"
grep -qx POOL_END "$EV/sf-pool-off.txt" || fail "SurfaceFlinger's binder pool threads could not be read whole ($EV/sf-pool-off.txt)"

step "H. rt.contain on: no Android thread keeps SCHED_FIFO/RR, each former one is SCHED_DEADLINE within the cap"
kmsg_mark H || fail "could not write a mark into the kernel log"
write_policy_contain 10 && restart_rtd_only on-contain
await_no_fifo 15 "$EV/contain-on.txt" || log "    the sandbox still holds FIFO/RR threads 15s after rt.contain came on"
v=$(seen "$(awk '$2 == "FF" || $2 == "RR"' "$EV/contain-on.txt" | grep -c .)" 1)
[[ "$v" == 0 ]] && pass "no Android thread at SCHED_FIFO/RR with rt.contain on ($EV/contain-on.txt)" \
  || fail "$v Android thread(s) still SCHED_FIFO/RR with rt.contain on ($EV/contain-on.txt)"
v=$(seen "$(awk 'NR == FNR { if ($2 != "DLN") was[$1] = 1; next } ($1 in was) && $2 != "DLN"' \
  "$EV/contain-off.txt" <(grep -v -x RT_END "$EV/contain-on.txt") | grep -c .)" 1)
n=$(awk '$2 == "DLN"' "$EV/contain-on.txt" | grep -c .)
[[ "$v" == 0 && "$n" -ge 2 ]] && pass "$n Android thread(s) at SCHED_DEADLINE, every surviving FIFO/RR one among them" \
  || fail "$v former FIFO/RR thread(s) not at SCHED_DEADLINE, $n at SCHED_DEADLINE ($EV/contain-on.txt)"
v=$(seen "$(contain_kernel_vs_grants "$DL_BASE" "$EV/bw-snapshot-contain.txt")" "1 2 0")
read -r got want own <<<"$v"
capu=$(status_q "int(s.get('contain_cap_bw', 0) * (1 << 20))")
[[ -n "$got" && "$got" == "$want" && "$own" =~ ^[0-9]+$ && "$capu" =~ ^[0-9]+$ ]] && (( got - own > 0 && got - own <= capu )) \
  && pass "the kernel admitted exactly rt.contain's own grants plus the daemon's $own-unit reservation ($got units), grants within its own cap's $capu" \
  || fail "kernel admitted '$got' units over the pre-leg total, rt.contain's own grants and the daemon's reservation come to '$want' (own '$own'), its cap is '$capu' ($EV/bw-snapshot-contain.txt)"
await_sf_pool_contained "$SF_PID" 5 "$EV/sf-pool-on.txt" \
  || log "    a SurfaceFlinger binder pool thread is not SCHED_DEADLINE 5s after the check began"
grep -qx POOL_END "$EV/sf-pool-on.txt" || fail "SurfaceFlinger's binder pool threads could not be read whole with rt.contain on ($EV/sf-pool-on.txt)"
n=$(grep -v -x POOL_END "$EV/sf-pool-on.txt" | grep -c .)
v=$(seen "$(grep -v -x POOL_END "$EV/sf-pool-on.txt" | awk '$2 != "DLN"' | grep -c .)" 1)
[[ "$v" == 0 && "$n" -ge 1 ]] \
  && pass "every SurfaceFlinger binder pool thread ($n) is SCHED_DEADLINE with rt.contain on, none left SCHED_OTHER ($EV/sf-pool-on.txt)" \
  || fail "$v of $n SurfaceFlinger binder pool thread(s) not SCHED_DEADLINE with rt.contain on ($EV/sf-pool-on.txt)"
ssh_vm -t 10 "cat $STATUS" >"$EV/status-contain.json" 2>&1
MEASURED_PY="c['policy'] == 'deadline' and c.get('sized_by') == 'measured'"
IDLE_PY="$MEASURED_PY and c.get('cpu_rate') is not None and c['cpu_rate'] * 16667000 * 1.25 <= 200000 and (c.get('cpu_run_ns') or 0) * 2 <= 200000"
v=$(seen "$(status_q "'%d %d %d' % (sum(1 for c in s['contained'].values() if $IDLE_PY), sum(1 for c in s['contained'].values() if ($IDLE_PY) and c['runtime_ns'] != 200000), sum(1 for c in s['contained'].values() if ($MEASURED_PY) and c['runtime_ns'] > 2000000))")" "0 1 1")
read -r n_idle n_wrong n_over <<<"$v"
[[ "$n_idle" =~ ^[0-9]+$ && "$n_idle" -ge 1 && "$n_wrong" == 0 && "$n_over" == 0 ]] \
  && pass "$n_idle idle contained thread(s) hold the 200us floor and none passes rt.contain_runtime_us ($EV/status-contain.json)" \
  || fail "contained sizing: $n_idle idle thread(s), $n_wrong of them off the floor, $n_over over the 2ms ceiling ($EV/status-contain.json)"
RUN_PY="$MEASURED_PY and c.get('cpu_run_ns') is not None"
v=$(seen "$(status_q "'%d %d' % (sum(1 for c in s['contained'].values() if $RUN_PY), sum(1 for c in s['contained'].values() if ($RUN_PY) and c['runtime_ns'] < 0.89 * min(2000000, max(200000, 2 * c['cpu_run_ns']))))")" "0 1")
read -r n_run n_under <<<"$v"
[[ "$n_run" =~ ^[0-9]+$ && "$n_run" -ge 1 && "$n_under" == 0 ]] \
  && pass "$n_run measured contained thread(s) that ran hold at least twice their CPU per run ($EV/status-contain.json)" \
  || fail "contained sizing per run: $n_run thread(s) with a CPU per run, $n_under held under twice it ($EV/status-contain.json)"
v=$(seen "$(rtd_main_cls)" TS)
[[ "$v" == DLN ]] && pass "rhizo-rtd's own main thread is SCHED_DEADLINE with rt.contain on" \
  || fail "rhizo-rtd's own main thread class '$v', want DLN, with rt.contain on"

step "I. a SurfaceFlinger restart is re-caught: its new threads are SCHED_DEADLINE within a scan cycle"
kmsg_mark I || fail "could not write a mark into the kernel log"
SF_PID=$(sf_pid)
out=$(ssh_vm -t 15 "cg=\$(sed -n 's/^0:://p' /proc/$SF_PID/cgroup)
  if [ -n \"\$cg\" ] && [ \"\$(cat /sys/fs/cgroup\$cg/cgroup.procs)\" = '$SF_PID' ]; then
    echo 1 > /sys/fs/cgroup\$cg/cgroup.kill && echo RHIZO_SF_KILLED \$cg
  else echo \"cgroup '\$cg' holds: \$(cat /sys/fs/cgroup\$cg/cgroup.procs 2>&1 | tr '\n' ' ')\"; fi" 2>&1 | tr -d '\r')
[[ "$out" == *RHIZO_SF_KILLED* ]] || fail "could not kill SurfaceFlinger (host pid $SF_PID) through its own cgroup: ${out:-no answer}"
SF_NEW=""
for _ in $(seq 15); do
  cand=$(sf_pid)
  [[ -n "$cand" && "$cand" != "$SF_PID" ]] && { SF_NEW=$cand; break; }
  sleep 1
done
v=$(seen "$SF_NEW" "")
[[ -n "$v" ]] && pass "SurfaceFlinger restarted (host pid $SF_PID -> $SF_NEW)" \
  || fail "SurfaceFlinger did not restart within 15s of its cgroup's kill ($out)"
await_no_fifo 30 "$EV/contain-sf-restarted.txt" || log "    FIFO/RR threads remain 30s after SurfaceFlinger's restart"
v=$(seen "$(awk '$2 == "FF" || $2 == "RR"' "$EV/contain-sf-restarted.txt" | grep -c .)" 1)
n=$(awk -v sf="$SF_NEW" '$5 == sf && $2 == "DLN"' "$EV/contain-sf-restarted.txt" | grep -c .)
[[ "$v" == 0 && "$n" -ge 1 ]] \
  && pass "after the restart, no Android thread at SCHED_FIFO/RR and $n of the new SurfaceFlinger's at SCHED_DEADLINE" \
  || fail "after the restart: $v Android FIFO/RR thread(s), $n of the new SurfaceFlinger's at SCHED_DEADLINE ($EV/contain-sf-restarted.txt)"
await_sf_pool_contained "$SF_NEW" 5 "$EV/sf-pool-sf-restarted.txt" \
  || log "    a new SurfaceFlinger binder pool thread is not SCHED_DEADLINE 5s after the check began"
grep -qx POOL_END "$EV/sf-pool-sf-restarted.txt" || fail "the new SurfaceFlinger's binder pool threads could not be read whole ($EV/sf-pool-sf-restarted.txt)"
n=$(grep -v -x POOL_END "$EV/sf-pool-sf-restarted.txt" | grep -c .)
v=$(seen "$(grep -v -x POOL_END "$EV/sf-pool-sf-restarted.txt" | awk '$2 != "DLN"' | grep -c .)" 1)
[[ "$v" == 0 && "$n" -ge 1 ]] \
  && pass "the new SurfaceFlinger's binder pool thread(s) ($n) are SCHED_DEADLINE too, none left SCHED_OTHER ($EV/sf-pool-sf-restarted.txt)" \
  || fail "$v of $n the new SurfaceFlinger's binder pool thread(s) not SCHED_DEADLINE ($EV/sf-pool-sf-restarted.txt)"

step "J. the daemon's stop restores every contained thread's exact prior policy and priority"
ssh_vm -t 30 "systemctl stop rhizo-rtd.service" >/dev/null 2>&1 || fail "rhizo-rtd.service did not stop (rt.contain's own stop)"
v=$(seen "$(rtd_cgroup_procs)" 1)
[[ "$v" == 0 ]] && pass "the stop left no process in the daemon's cgroup (rt.contain's own stop)" \
  || fail "$v process(es) left in rhizo-rtd.service's cgroup after rt.contain's own stop"
sandbox_rt_threads "$EV/contain-restored.txt"
grep -qx RT_END "$EV/contain-restored.txt" || fail "the sandbox's thread list could not be read whole ($EV/contain-restored.txt)"
v=$(seen "$(awk '$2 == "DLN"' "$EV/contain-restored.txt" | grep -c .)" 1)
[[ "$v" == 0 ]] && pass "no Android thread left at SCHED_DEADLINE after the stop" \
  || fail "$v Android thread(s) still SCHED_DEADLINE after the stop ($EV/contain-restored.txt)"
v=$(seen "$(awk 'NR == FNR { was[$1] = $2 ":" $3; next } ($1 in was) && was[$1] != $2 ":" $3 { print $1 }' \
  <(grep -v -x RT_END "$EV/contain-off.txt") <(grep -v -x RT_END "$EV/contain-restored.txt") | tr '\n' ' ')" "forced")
w=$(awk 'NR == FNR { if ($2 == "DLN") con[$1] = 1; next } ($1 in con) && $2 != "FF" && $2 != "RR" { print $1 }' \
  <(grep -v -x RT_END "$EV/contain-sf-restarted.txt") <(grep -v -x RT_END "$EV/contain-restored.txt") | tr '\n' ' ')
[[ -z "${v// /}" && -z "${w// /}" ]] \
  && pass "every contained thread still alive is back to its own class and priority ($EV/contain-restored.txt)" \
  || fail "threads not restored: changed since G [$v], contained but not FIFO/RR [$w] ($EV/contain-off.txt vs $EV/contain-restored.txt)"
want=$(grep -v -x POOL_END "$EV/sf-pool-off.txt" | awk '{print $2, $3}' | sort -u | tr '\n' ';')
sf_pool_threads "$SF_NEW" "$EV/sf-pool-restored.txt"
grep -qx POOL_END "$EV/sf-pool-restored.txt" || fail "SurfaceFlinger's binder pool threads could not be read whole after the stop ($EV/sf-pool-restored.txt)"
n=$(grep -v -x POOL_END "$EV/sf-pool-restored.txt" | grep -c .)
v=$(seen "$(grep -v -x POOL_END "$EV/sf-pool-restored.txt" | awk '{print $2, $3}' | sort -u | tr '\n' ';')" "bad;")
[[ "$want" =~ ^(FF|RR)\ [0-9]+\;$ && "$v" == "$want" && "$n" -ge 1 ]] \
  && pass "SurfaceFlinger's binder pool thread(s) ($n) are back at '$want' after the stop, as at G ($EV/sf-pool-restored.txt)" \
  || fail "SurfaceFlinger's binder pool thread(s) after the stop: '$v' ($n found), want G's single FIFO/RR value '$want' ($EV/sf-pool-off.txt, $EV/sf-pool-restored.txt)"
v=$(seen "$(dl_total_bw)" "$(( DL_BASE + 1 ))")
[[ "$v" == "$DL_BASE" ]] \
  && pass "deadline bandwidth back to its pre-test total ($DL_BASE) after rt.contain's own revokes and stop" \
  || fail "kernel deadline total is $v after rt.contain's own stop, was $DL_BASE before any grant: revoked bandwidth is still counted"
ssh_vm -t 30 "systemctl start rhizo-rtd.service" >/dev/null 2>&1 || fail "rhizo-rtd.service did not start again after rt.contain's own legs"

step "K. rhizo-vsync, the Wayland pump and the composer's own binder thread: FIFO 2 off, SCHED_DEADLINE on, restored after"
COMPOSER_PID=$(ssh_vm -t 10 "pgrep -x rhizo-composer | head -1" | tr -d '\r')
[[ "$COMPOSER_PID" =~ ^[0-9]+$ ]] || fail "no rhizo-composer pid on the host (got '$COMPOSER_PID')"

# print the class and priority of a composer thread
composer_thread() {
  awk -v pid="$COMPOSER_PID" -v c="$2" '$4 == c && $5 == pid { print $2, $3; f = 1 } END { if (!f) print "<none> <none>" }' "$1"
}

for ct in rhizo-vsync rhizo-wl-pump rhizo-composer; do
  v=$(seen "$(composer_thread "$EV/contain-off.txt" "$ct")" "<none> <none>")
  [[ "$v" == "FF 42" ]] && pass "$ct: FIFO priority 2 with rt.contain off ($EV/contain-off.txt)" \
    || fail "$ct: '$v' with rt.contain off, want 'FF 42' ($EV/contain-off.txt)"
done
for ct in rhizo-vsync rhizo-wl-pump rhizo-composer; do
  raw=$(composer_thread "$EV/contain-on.txt" "$ct")
  v=$(seen "${raw%% *}" FF)
  [[ "$v" == "DLN" ]] && pass "$ct: SCHED_DEADLINE with rt.contain on ($EV/contain-on.txt)" \
    || fail "$ct: cls '$v' with rt.contain on, want 'DLN' ($EV/contain-on.txt)"
done
for ct in rhizo-vsync rhizo-wl-pump rhizo-composer; do
  v=$(seen "$(composer_thread "$EV/contain-restored.txt" "$ct")" "<none> <none>")
  [[ "$v" == "FF 42" ]] && pass "$ct: restored to FIFO priority 2 after rt.contain's stop ($EV/contain-restored.txt)" \
    || fail "$ct: '$v' after rt.contain's stop, want 'FF 42' ($EV/contain-restored.txt)"
done

# print a capped instance's cgroup, cpu.max and status
carve_snapshot() {
  ssh_vm -t 25 "for i in 1 2 3 4 5; do
      s=\$(cat $STATUS)
      cg=\$(printf '%s' \"\$s\" | python3 -c 'import json,sys; print(next((k for k in json.load(sys.stdin).get(\"tenants\", {}) if k.startswith(\"/\")), \"\"))')
      [ -n \"\$cg\" ] || continue
      a=\$(cat /sys/fs/cgroup\$cg/cpu.max); s=\$(cat $STATUS); b=\$(cat /sys/fs/cgroup\$cg/cpu.max)
      held=\$(printf '%s' \"\$s\" | python3 -c 'import json,os,sys; print(len(set(json.load(sys.stdin).get(\"grants\", {})) & set(os.listdir(\"/proc/$2/task\"))))')
      [ \"\$a\" = \"\$b\" ] && [ \"\${held:-0}\" -gt 0 ] && { echo \"\$cg|\$a\"; echo \"\$s\"; exit 0; }
    done; echo NONE" | tr -d '\r' >"$1"
}

step "L. instance.cpu_max set: the ceiling cgroup's cpu.max is lowered by what rhizo-rtd reserves, and restored on its stop"
kmsg_mark L || fail "could not write a mark into the kernel log"
ssh_vm -t 15 "mkdir -p /etc/rhizo/instances; rm -f $INSTANCE_SAVED; if [ -e $INSTANCE_CONF ]; then cp -a $INSTANCE_CONF $INSTANCE_SAVED; fi
  printf '[instance]\ncpu_max = 100000 100000\n' > $INSTANCE_CONF" \
  && INSTANCE_CONF_ARMED=1 || fail "could not write $INSTANCE_CONF"
write_policy 25 && restart_with_settings carve && { swipe_for 20 & SWIPE_JOB=$!; }
await_vm 40 "python3 -c \"import json,os,sys; s=json.load(open('$STATUS')); held=set(s.get('grants', {})) & set(os.listdir('/proc/$APP_PID/task')); sys.exit(0 if held and any(t.get('cpu_max_written') for t in s.get('tenants', {}).values()) else 1)\"" \
  || log "    no Settings thread held a grant under a lowered cpu.max within 40s"
carve_snapshot "$EV/carve-snapshot.txt" "$APP_PID"
CARVE_CG=$(sed -n 1p "$EV/carve-snapshot.txt" | cut -d'|' -f1)
[[ "$CARVE_CG" == /* ]] || { fail "no tenant with a cgroup path in the status ($EV/carve-snapshot.txt)"; CARVE_CG=""; }
LIVE_MAX=$(sed -n 1p "$EV/carve-snapshot.txt" | cut -d'|' -f2)
# evaluate a python expression over the tenant's status
carve_q() {
  sed -n '2,$p' "$EV/carve-snapshot.txt" | CG="$CARVE_CG" LIVE="$LIVE_MAX" python3 -c "
import json, os, sys
try:
    s = json.load(sys.stdin)
    t = s['tenants'][os.environ['CG']]
except (ValueError, KeyError):
    print('<status unreadable>'); sys.exit(3)
live = os.environ['LIVE']
print($1)"
}
v=$(seen "$(carve_q "t['cpu_max_configured']")" "max 100000")
[[ "$v" == "100000 100000" ]] && pass "rhizo-rtd read instance.cpu_max for $CARVE_CG as its configured quota ('$v')" \
  || fail "the daemon's configured cpu.max for '$CARVE_CG' is '$v', want '100000 100000' ($EV/carve-snapshot.txt)"
v=$(seen "$(carve_q "'%d %.6f' % (100000 - int(live.split()[0]), t['reserved_bw'])")" "0 0.5")
read -r carved reserved <<<"$v"
python3 -c "import sys; sys.exit(0 if float('$reserved') > 0 and int('$carved') >= float('$reserved') * 100000 - 1 else 1)" 2>/dev/null \
  && pass "cpu.max reads '$LIVE_MAX': ${carved}us of the 100000us quota are carved out for ${reserved} CPUs reserved" \
  || fail "cpu.max reads '$LIVE_MAX': ${carved}us carved against ${reserved} CPUs reserved, carve < reserved or nothing reserved ($EV/carve-snapshot.txt)"
v=$(seen "$(carve_q "'%s' % (t['cpu_max_written'] == live)")" "False")
[[ "$v" == True ]] && pass "the daemon's recorded written value is what the kernel reads" \
  || fail "status cpu_max_written differs from the live cpu.max '$LIVE_MAX' ($EV/carve-snapshot.txt)"
v=$(seen "$(carve_q "'%s %s %s' % (t['reclaim'], t['weight'], t['reclaim_revoked_at'])")" "False 4.0 1.0")
[[ "$v" == "True 1.0 None" ]] && pass "the honest capped tenant keeps RECLAIM (never revoked) and its weight is its 1 CPU limit" \
  || fail "tenant reclaim/weight/reclaim_revoked_at '$v', want 'True 1.0 None' ($EV/carve-snapshot.txt)"
v=$(seen "$(carve_q "t['dl_cpu_ns']")" 0)
[[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]] && pass "the tenant's reserved threads used ${v}ns of CPU while they held grants" \
  || fail "dl_cpu_ns '$v' for the tenant: no CPU counted while threads held a grant ($EV/carve-snapshot.txt)"
echo "<none: not reached>" >"$EV/demand-status.json"
W0=$(seen "$(carve_q "t['request_windows']")" "<missing>")
[[ "$W0" =~ ^[0-9]+$ ]] || fail "the carve snapshot's tenant has no request_windows count ('$W0') ($EV/carve-snapshot.txt)"
await_vm 15 "python3 -c \"import json,sys; t=json.load(open('$STATUS'))['tenants'].get('$CARVE_CG', {}); sys.exit(0 if t.get('request_windows', 0) >= ${W0:-0} + 2 else 1)\"" \
  || log "    the tenant closed fewer than two demand windows within 15s of the carve snapshot"
ssh_vm -t 15 "cat $STATUS" | tr -d '\r' >"$EV/demand-status.json"
v=$(seen "$(CG="$CARVE_CG" python3 -c "
import json, os
s = json.load(open('$EV/demand-status.json'))
t = s['tenants'][os.environ['CG']]
print('%d %d %.6f %.6f %.6f %.3f %s %.6f %.6f' % (t['request_windows'], t['request_samples'], t['request_p50'], t['request_p95'], t['request_max'], t['request_window_s'], t['windows_over_slice'], t['slice_budgets'], min(s['cap_bw'], 0.9 * t['weight'])))")" \
  "0 0 0.000000 0.000000 0.000000 0.000 0 0.900000 0.900000")
read -r d_windows d_n d_p50 d_p95 d_max d_win d_over d_slice d_want <<<"$v"
[[ "$d_windows" =~ ^[0-9]+$ && "$W0" =~ ^[0-9]+$ ]] && (( d_windows >= W0 + 2 )) \
  || fail "the status read for the demand check is not two windows past the carve snapshot (windows '$d_windows', snapshot '$W0') ($EV/demand-status.json)"
python3 -c "
import sys
n, p50, p95, mx, win, over, sl, want = int('$d_n'), float('$d_p50'), float('$d_p95'), float('$d_max'), float('$d_win'), int('$d_over'), float('$d_slice'), float('$d_want')
sys.exit(0 if n >= 1 and 0 <= p50 <= p95 <= mx and mx > 0 and 0 < win <= 2.5 and over >= 0 and abs(sl - want) < 1e-6 else 1)" 2>/dev/null \
  && pass "the tenant's last window carries its budgets request (n=$d_n p50=$d_p50 p95=$d_p95 max=$d_max over ${d_win}s, $d_over window(s) over) beside its slice $d_slice" \
  || fail "tenant request over the last window '$v' (windows samples p50 p95 max window_s windows_over_slice slice want_slice): want samples >= 1, p50 <= p95 <= max, max > 0, a window of at most 2.5s and the slice the cap gives ($EV/demand-status.json)"
for f in crash-kill crash-recover-log crash-rt crash-status; do echo "<none: not reached>" >"$EV/$f.txt"; done
RTD_LOG=/var/log/rhizo/rhizo-rtd.log
# print the daemon's main pid
rtd_main_pid() { ssh_vm -t 10 "systemctl show -p MainPID --value rhizo-rtd.service" | tr -d '\r'; }
OLD_PID=$(rtd_main_pid)
LOG_LINES=$(ssh_vm -t 10 "wc -l < $RTD_LOG" | tr -d '\r')
HELD_BEFORE=$(status_q "len(s['grants']) + len(s.get('contain_grants', {}))")
[[ "$OLD_PID" =~ ^[1-9][0-9]*$ && "$LOG_LINES" =~ ^[0-9]+$ && "$HELD_BEFORE" =~ ^[1-9][0-9]*$ ]] \
  || fail "nothing to crash: main pid '$OLD_PID', log lines '$LOG_LINES', grants held '$HELD_BEFORE'"
ssh_vm -t 15 "systemctl kill -s SIGKILL rhizo-rtd.service" >"$EV/crash-kill.txt" 2>&1 || fail "could not SIGKILL rhizo-rtd.service ($EV/crash-kill.txt)"
await_vm 40 "p=\$(systemctl show -p MainPID --value rhizo-rtd.service); [ \"\$p\" != 0 ] && [ \"\$p\" != '$OLD_PID' ] && systemctl is-active --quiet rhizo-rtd.service && tail -n +$(( LOG_LINES + 1 )) $RTD_LOG | grep -q '^recover: revoked='" \
  || fail "systemd did not restart rhizo-rtd.service within 40s of the SIGKILL (main pid was $OLD_PID, now '$(rtd_main_pid)')"
ssh_vm -t 15 "tail -n +$(( LOG_LINES + 1 )) $RTD_LOG; echo LOG_END" | tr -d '\r' >"$EV/crash-recover-log.txt"
v=$(seen "$(sed -n 's/^recover: revoked=\([0-9]*\) .*/\1/p' "$EV/crash-recover-log.txt" | head -1)" 0)
[[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 ]] && pass "the restarted daemon revoked $v grant(s) the killed one left on their threads (of $HELD_BEFORE held)" \
  || fail "the restarted daemon logged no 'recover: revoked=N' with N >= 1 ('$v', $HELD_BEFORE grants were held at the kill) ($EV/crash-recover-log.txt)"
sandbox_rt_threads "$EV/crash-rt.txt"
CRASH_STATUS=$(ssh_vm -t 15 "cat $STATUS" | tr -d '\r')
printf '%s\n' "$CRASH_STATUS" >"$EV/crash-status.txt"
v=$(seen "$(grep -qx RT_END "$EV/crash-rt.txt" && awk '$2 == "DLN" { print $1 }' "$EV/crash-rt.txt" | STATUS_JSON="$CRASH_STATUS" python3 -c "
import json, os, sys
held = set(json.loads(os.environ['STATUS_JSON'])['grants']) | set(json.loads(os.environ['STATUS_JSON']).get('contain_grants', {}))
print(len([t for t in sys.stdin.read().split() if t not in held]))" || echo '<unreadable>')" 99)
[[ "$v" == 0 ]] && pass "after the restart no SCHED_DEADLINE thread in the sandbox is one the daemon does not hold ($EV/crash-rt.txt)" \
  || fail "$v SCHED_DEADLINE thread(s) in the sandbox are not held by the restarted daemon ($EV/crash-rt.txt, status in $EV/crash-status.txt)"
v=$(seen "$(grep -c '^carve-restore: tenant=[^ ]* cpu.max=100000 100000$' "$EV/crash-recover-log.txt")" 0)
[[ "$v" =~ ^[0-9]+$ && "$v" -ge 1 ]] && pass "the restart put the lowered cpu.max back to the configured '100000 100000' (recovery log)" \
  || fail "the restarted daemon logged no 'carve-restore: tenant=... cpu.max=100000 100000' (was '$LIVE_MAX' while reserved) ($EV/crash-recover-log.txt)"
end_swipes
ssh_vm -t 30 "systemctl stop rhizo-rtd.service" >/dev/null 2>&1 || fail "rhizo-rtd.service did not stop (leg L)"
v=$(seen "$(ssh_vm -t 10 "cat /sys/fs/cgroup$CARVE_CG/cpu.max" | tr -d '\r')" "$LIVE_MAX")
[[ "$v" == "100000 100000" ]] && pass "after the daemon's stop cpu.max reads the configured '$v' again" \
  || fail "cpu.max reads '$v' after the daemon's stop, want '100000 100000' (was '$LIVE_MAX' while reserved)"

step "F. enforce=1 throughout, and no denial the feature caused"
v=$(seen "$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce' | tr -d '\r')" 0)
[[ "$v" == 1 ]] && pass "enforcing at the end" || fail "enforce=$v at the end"
dmesg_after start >"$EV/kmsg-since-start.txt"
grep -qx KMSG_END "$EV/kmsg-since-start.txt" && ! grep -qx NO_MARK "$EV/kmsg-since-start.txt" \
  || fail "the kernel log since the system test's start mark could not be read whole ($EV/kmsg-since-start.txt)"
grep -a 'avc:  denied' "$EV/kmsg-since-start.txt" \
  | grep -a -E 'scontext=u:r:rhizo_power:s0|rhizo_rt_socket|rhizo_rtd|setsched|getsched|scontext=u:r:rhizo_host:s0 .*tcontext=u:r:[a-z_]*app' \
  | grep -a -v -E "\\{ connectto \\} for +pid=${fp:-none} .*tcontext=u:r:rhizo_rtd:s0" >"$EV/avc-feature.txt"
v=$(seen "$(grep -c . "$EV/avc-feature.txt")" 1)
[[ "$v" == 0 ]] && pass "no feature denial in the kernel log" || fail "$v feature denial(s): $EV/avc-feature.txt"
ssh_vm -t 20 "journalctl -u rhizo-rtd.service --since @$TEST_T0 --no-pager -o short-monotonic; echo JOURNAL_END" >"$EV/rtd-journal.txt" 2>&1
v=$(seen "$(grep -c -E 'Failed to kill|remains running after unit stopped|left-over process' "$EV/rtd-journal.txt") \
$(grep -c 'systemd\[1\]: Stopped ' "$EV/rtd-journal.txt") $(grep -cx JOURNAL_END "$EV/rtd-journal.txt")" "1 0 0")
read -r bad stops ended <<<"$v"
[[ "$bad" == 0 && "$stops" -ge 1 && "$ended" == 1 ]] && pass "every daemon stop in this run ($stops) killed it (systemd's journal)" \
  || fail "journal: $bad line(s) of a daemon surviving its stop, $stops stop(s), end marker $ended ($EV/rtd-journal.txt)"

if (( SELFTEST )); then
  failed_steps=$(cut -f2 "$EV/failures.log" 2>/dev/null | sed 's/^step=//' | sort -u)
  survived=()
  for st in "${SELFTEST_STEPS[@]}"; do
    [[ "$st" == 0.* ]] && continue
    grep -Fxq "$st" <<<"$failed_steps" || survived+=("$st")
  done
  if (( ${#survived[@]} )); then
    printf 'FAILED selftest: legs passed on a corrupted value:\n%s\n' "$(printf '  %s\n' "${survived[@]}")" > "$EV/selftest-verdict.txt"
    test_record_verdict FAILED "selftest=1"; log "RT-BUDGETS SYSTEM TEST SELFTEST FAILED"; exit 1
  fi
  echo "PASSED selftest: every asserting leg failed on a corrupted value" > "$EV/selftest-verdict.txt"
  test_record_verdict PASSED "selftest=1"; log "RT-BUDGETS SYSTEM TEST SELFTEST PASSED"; exit 0
fi
if (( FAILED )); then test_record_verdict FAILED; log "RT-BUDGETS SYSTEM TEST FAILED"; exit 1; fi
test_record_verdict PASSED
log "RT-BUDGETS SYSTEM TEST PASSED -- evidence in $EV"
