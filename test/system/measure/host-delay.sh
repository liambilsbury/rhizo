#!/bin/bash
# test trace.host_delay off and on
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-requires: share:rt-load share:wlr-inject
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }
source ../lib/install-lib.sh

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
test_init host-delay
SELFTEST_STEPS=()
# record the step name instead of running steps in selftest mode
# shellcheck disable=SC2034
step() { TEST_STEP="$*"; SELFTEST_STEPS+=("$*"); log "=== $*"; }

TOOLS_DIR="$(cd "." && pwd)"
POLICY_CONF=/etc/rhizo/policy.conf
POLICY_SAVED=/etc/rhizo/policy.conf.host-delay-test
POLICY_SNAPSHOT=0
RT_LOAD_STAGED=0
ADV_ON=0
PKG=com.android.settings
ACT=com.android.settings/.homepage.SettingsHomepageActivity
SOCK_DIR=/dev/socket/rhizo_delay
FT_CFG=/data/misc/perfetto-configs/host-delay-test.pbtxt
FT_TRACE=/data/misc/perfetto-traces/host-delay-test.pftrace
FT_LOG=/data/local/tmp/host-delay-test.log
FT_GZ=/data/local/tmp/host-delay-test.pftrace.gz
FT_PID=""
FT_CFG_TEXT='buffers { size_kb: 65536 fill_policy: RING_BUFFER }
data_sources { config { name: "android.surfaceflinger.frametimeline" } }
data_sources { config { name: "linux.process_stats" process_stats_config { scan_all_processes_on_start: true } } }
data_sources { config { name: "rhizo.host_delay" } }
write_into_file: true
file_write_period_ms: 500
duration_ms: 900000'

for t in off quiet adv rtd; do
  for f in "$t.pftrace" "$t.json" "$t-dumpsys.txt" "$t-perfetto.log" "$t-meta.txt" "$t-app-threads.txt" "$t-android-tids.txt" "$t-am-start.txt"; do
    echo "<none: leg for $t not reached>" >"$EV/$f"
  done
done
for f in perfetto-config.pbtxt on-state.txt on-dumpsys.txt adversary-window.txt rt-load-host-pids.txt rt-load-adv.txt \
         socket-dir.txt logcat-hostdelay.txt A-off-state.txt H-off-state.txt b-report.txt c-report.txt d-report.txt e-report.txt kmsg-since-start.txt avc-feature.txt; do
  echo "<none: not reached>" >"$EV/$f"
done
printf '%s\n' "$FT_CFG_TEXT" >"$EV/perfetto-config.pbtxt"

# restore policy.conf and stop the test services
restore_policy_conf() {
  local got body
  (( TEST_NO_VM )) && return 0
  if [[ -n "$FT_PID" ]]; then
    body="kill $FT_PID; rm -f $FT_CFG $FT_TRACE $FT_LOG $FT_GZ"
    ANDROID_SH_TIMEOUT=20 android_sh "$(guest_init_pid 10)" "$body" >/dev/null 2>&1
  fi
  (( POLICY_SNAPSHOT )) || return 0
  got=$(ssh_vm -t 40 "pkill -x rt-load 2>/dev/null
    if [ -e $POLICY_SAVED ]; then mv -f $POLICY_SAVED $POLICY_CONF; else rm -f $POLICY_CONF; fi
    systemctl stop rhizo-delayd.service rhizo-rtd.service
    if [ $RT_LOAD_STAGED = 1 ]; then rm -f /usr/local/bin/rt-load /root/rt-load-adv-*.txt; fi
    echo conf=\$(test -e $POLICY_CONF && echo present || echo absent) saved=\$(test -e $POLICY_SAVED && echo present || echo absent) \
delayd=\$(systemctl is-active rhizo-delayd.service) load=\$(pgrep -cx rt-load)" 2>&1 | tr -d '\r' | tr '\n' ' ')
  case "$got" in
    *"saved=absent"*"delayd=inactive"*"load=0"*) log "CLEANUP_OK: policy.conf restored, rhizo-delayd stopped, no rt-load ($got)" ;;
    *) log "CLEANUP_INCOMPLETE: policy.conf, rhizo-delayd or rt-load ($got)" ;;
  esac
}
# shellcheck disable=SC2034
TEST_EXTRA_CLEANUP=restore_policy_conf

# return the received or corrupted value
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

# wait for Android shell output to match
await_android() {
  local deadline=$(( $(date +%s) + $1 )) out
  while (( $(date +%s) < deadline )); do
    out=$(android_sh "$INIT" "$2" 2>/dev/null | tr -d '\r')
    [[ "$out" == "$3" ]] && return 0
    sleep 1
  done
  return 1
}

# evaluate a python expression on a JSON file
dq() {
  JSON_FILE="$1" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['JSON_FILE']))
    print($2)
except Exception:
    print('<unreadable>')"
}

HD_PRELUDE='import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("hdt", os.path.join(os.environ["TOOLS_DIR"], "../../system/trace/host-delay-trace.py"))
hdt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hdt)
d = json.load(open(os.environ["JSON"]))'
# run python with the host-delay tool preloaded
hdpy() { TOOLS_DIR=$TOOLS_DIR python3 -c "$HD_PRELUDE"$'\n'"$1" 2>&1; }

TEST_RUN_ID="$(date +%s).$$"
# write a numbered mark line to the guest kernel log
kmsg_mark() { ssh_vm -t 10 "echo 'host-delay-test mark $1/$TEST_RUN_ID.' > /dev/kmsg"; }
# print the guest kernel log after a mark
dmesg_after() {
  ssh_vm -t 20 "dmesg | awk -v m='host-delay-test mark $1/$TEST_RUN_ID.' 'f; index(\$0, m) { f = 1 } END { if (!f) print \"NO_MARK\" }'; echo KMSG_END" | tr -d '\r'
}

# launch Settings and set its display and pid
launch_settings() {
  local line
  ssh_vm -t 150 "/usr/lib/rhizo/tools/rhizo-launch.sh $PKG ${ACT#*/}" >"$EV/$1-launch.txt" 2>&1
  line=$(ssh_vm -t 15 "grep -a ' pkg=$PKG ' /run/rhizo-launch/rhizo-launch.log | grep -a -v 'event=' | grep -a ' cdisplay=' | tail -1")
  CDISP=$(grep -o ' cdisplay=[0-9]*' <<<"$line" | cut -d= -f2)
  LOGICAL=$(grep -o ' display=[0-9]*' <<<"$line" | cut -d= -f2)
  [[ -n "$CDISP" && -n "$LOGICAL" ]] || { fail "Settings got no display (cdisplay='$CDISP' logical='$LOGICAL')"; return 1; }
  android_sh "$INIT" "am start -W --display $LOGICAL -n $ACT" | tr -d '\r' >"$EV/$1-am-start.txt" 2>&1
  grep -q '^Status: ok' "$EV/$1-am-start.txt" || { fail "am start -W did not report Status: ok ($EV/$1-am-start.txt)"; return 1; }
  APP_PID=""
  for _ in $(seq 20); do
    APP_PID=$(ssh_vm -t 10 "ps -eo pid,args --no-headers | awk '\$2==\"$PKG\"{print \$1}' | head -1" | tr -d '\r')
    [[ -n "$APP_PID" ]] && break
    sleep 1
  done
  [[ -n "$APP_PID" ]] || { fail "no $PKG process on the host"; return 1; }
  log "    Settings: host pid $APP_PID, composer display $CDISP, logical display $LOGICAL"
}

# move the pointer over the Settings window
park_pointer() {
  local x y w h cx cy
  read -r x y w h <<<"$1"
  cx=$(( x + w / 2 )); cy=$(( y + h / 2 ))
  desk_inject_pointer abs $(( cx > 40 ? cx - 37 : cx + 37 )) $(( cy > 40 ? cy - 29 : cy + 29 )) || return 1
  desk_inject_pointer abs "$cx" "$cy"
}

# wheel-scroll the window under the pointer
scroll_for() {
  local up down fifo script b64
  case "$RHIZO_DESKTOP_PROFILE" in
    plasma) up='axis 0 15'; down='axis 0 -15'; fifo=$PLASMA_INJECT_FIFO ;;
    *)      up='axis_disc v 2'; down='axis_disc v -2'; fifo=$INJECT_FIFO ;;
  esac
  script="stamps=/tmp/hd-scroll-$2.stamps; rm -f \$stamps
exec 3>$fifo || exit 1
i=0; last=; end=\$((EPOCHSECONDS + $1))
while (( EPOCHSECONDS < end )); do
  if (( (i / 30) % 2 == 0 )); then ev='$up'; else ev='$down'; fi
  (( i == 0 )) && printf 'first %s\n' \"\$EPOCHREALTIME\" >\$stamps
  echo \"\$ev\" >&3
  last=\$EPOCHREALTIME
  i=\$((i + 1)); sleep 0.033
done
printf 'last %s\n' \"\$last\" >>\$stamps"
  b64=$(printf '%s' "$script" | base64 -w0)
  gcmd_user "bash -c \"\$(echo $b64 | base64 -d)\"" "$(( $1 + 20 ))"
}

# set the scroll start and end times
scroll_window() {
  local out w
  SCROLL_T0=""; SCROLL_T1=""
  out=$(ssh_vm -t 30 "cat /tmp/hd-scroll-$1.stamps 2>&1; python3 -c 'import time; print(\"PAIR %d %d\" % (time.clock_gettime_ns(time.CLOCK_REALTIME), time.clock_gettime_ns(time.CLOCK_BOOTTIME)))'" | tr -d '\r')
  printf '%s\n' "$out" >"$EV/$1-scroll-stamps.txt"
  w=$(OUT="$out" python3 -c '
import os, re, sys
o = os.environ["OUT"]
f = re.search(r"^first (\d+)\.(\d{6})$", o, re.M)
l = re.search(r"^last (\d+)\.(\d{6})$", o, re.M)
p = re.search(r"^PAIR (\d+) (\d+)$", o, re.M)
if not (f and l and p):
    sys.exit(1)
off = int(p.group(1)) - int(p.group(2))
ns = lambda m: int(m.group(1)) * 10**9 + int(m.group(2)) * 1000
t0, t1 = ns(f) - off, ns(l) - off
if t1 <= t0:
    sys.exit(1)
print(t0, t1)') || return 1
  read -r SCROLL_T0 SCROLL_T1 <<<"$w"
}

# start perfetto and wait for trace data
ft_start() {
  local b64 out pid
  b64=$(printf '%s\n' "$FT_CFG_TEXT" | base64 -w0)
  out=$(ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "echo $b64 | base64 -d > $FT_CFG && rm -f $FT_TRACE $FT_GZ && perfetto --background --txt -c $FT_CFG -o $FT_TRACE </dev/null >$FT_LOG 2>&1; echo perfetto_bg_rc=\$?")
  grep -qx 'perfetto_bg_rc=0' <<<"$out" || { fail "perfetto --background did not start: $out"; return 1; }
  pid=$(ANDROID_SH_TIMEOUT=30 android_sh "$INIT" "pidof perfetto" | tr -d '\r' | grep -xE '[0-9]+')
  [[ -n "$pid" ]] || { fail "not exactly one perfetto client after --background: '$(ANDROID_SH_TIMEOUT=30 android_sh "$INIT" "pidof perfetto")'"; return 1; }
  FT_PID=$pid
  out=$(ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "i=0; while [ \$i -lt 40 ] && ! [ -s $FT_TRACE ]; do sleep 0.5; i=\$((i + 1)); done; [ -s $FT_TRACE ] && echo FT_WRITING || echo FT_SILENT")
  grep -qx FT_WRITING <<<"$out" \
    || { fail "perfetto $FT_PID wrote nothing to $FT_TRACE within 20 s: $(ANDROID_SH_TIMEOUT=30 android_sh "$INIT" "cat $FT_LOG")"; return 1; }
}

# stop perfetto in Android with SIGTERM
ft_stop() {
  local out
  out=$(ANDROID_SH_TIMEOUT=90 android_sh "$INIT" "kill -TERM $FT_PID; i=0; while kill -0 $FT_PID 2>/dev/null && [ \$i -lt 120 ]; do sleep 0.5; i=\$((i + 1)); done; kill -0 $FT_PID 2>/dev/null && echo FT_RUNNING || echo FT_STOPPED")
  grep -qx FT_STOPPED <<<"$out" || { fail "perfetto $FT_PID did not exit after SIGTERM: $out"; return 1; }
}

# pull the perfetto trace from Android
ft_collect() {
  local tag="$1" remote want_sha want_size local_sha gz="$EV/$1.pftrace.gz"
  remote=$(ANDROID_SH_TIMEOUT=120 android_sh "$INIT" "gzip -c $FT_TRACE > $FT_GZ && sha256sum $FT_GZ | cut -c1-64 && wc -c < $FT_GZ" | tr -d '\r')
  want_sha=$(sed -n 1p <<<"$remote"); want_size=$(sed -n 2p <<<"$remote" | tr -d '[:space:]')
  [[ "$want_sha" =~ ^[0-9a-f]{64}$ && "$want_size" =~ ^[0-9]+$ && "$want_size" -gt 0 ]] \
    || { fail "Android's gzip of the trace reported: $remote"; return 1; }
  ANDROID_SH_TIMEOUT=300 android_sh "$INIT" "base64 -w0 $FT_GZ" | tr -d '\r\n' | base64 -d >"$gz" 2>/dev/null
  local_sha=$(sha256sum "$gz" | cut -d' ' -f1)
  [[ "$local_sha" == "$want_sha" ]] || { fail "the $tag trace arrived as sha256 $local_sha, Android sent $want_sha ($want_size bytes)"; rm -f "$gz"; return 1; }
  gunzip -c "$gz" >"$EV/$tag.pftrace" || { fail "the $tag trace did not gunzip"; rm -f "$gz"; return 1; }
  rm -f "$gz"
  ANDROID_SH_TIMEOUT=30 android_sh "$INIT" "cat $FT_LOG" >"$EV/$tag-perfetto.log" 2>&1
  ANDROID_SH_TIMEOUT=30 android_sh "$INIT" "rm -f $FT_CFG $FT_TRACE $FT_LOG $FT_GZ" >/dev/null 2>&1
  FT_PID=""
}

boottime_ns_cmd="python3 -c 'import time; print(\"BT=%d\" % time.clock_gettime_ns(time.CLOCK_BOOTTIME))'"
# start two FIFO 1 rt-loads per vCPU
adversary_start() {
  local out
  out=$(ssh_vm -t 60 "for c in \$(seq 0 $LASTCPU); do
      setsid taskset -c \$c /usr/local/bin/rt-load \$c 60000 45000 3600 1 >/root/rt-load-adv-\$c.txt 2>&1 </dev/null & disown
      setsid taskset -c \$c /usr/local/bin/rt-load \$c 1000 400 3600 1 >/root/rt-load-adv-short-\$c.txt 2>&1 </dev/null & disown
    done
    $boottime_ns_cmd
    sleep 0.5
    echo PIDS=\$(ps -eLo tid=,comm= | awk '\$2==\"rt-load\"{print \$1}' | tr '\n' ' ')" | tr -d '\r')
  ADV_T0=$(sed -n 's/^BT=\([0-9]*\)$/\1/p' <<<"$out")
  sed -n 's/^PIDS=//p' <<<"$out" | tr ' ' '\n' | grep -E '^[0-9]+$' >>"$EV/rt-load-host-pids.txt"
  [[ "$ADV_T0" =~ ^[0-9]+$ ]] || { fail "no BOOTTIME stamp after starting rt-load: $out"; return 1; }
  [[ -n "$(sed -n 's/^PIDS=//p' <<<"$out")" ]] || { fail "no rt-load process after starting it: $out"; return 1; }
  ADV_ON=1
}

# stop rt-load on each vCPU
adversary_stop() {
  local out
  out=$(ssh_vm -t 60 "$boottime_ns_cmd
    echo PIDS=\$(ps -eLo tid=,comm= | awk '\$2==\"rt-load\"{print \$1}' | tr '\n' ' ')
    pkill -x rt-load; sleep 0.3; echo LEFT=\$(pgrep -cx rt-load)" | tr -d '\r')
  ADV_T1=$(sed -n 's/^BT=\([0-9]*\)$/\1/p' <<<"$out")
  sed -n 's/^PIDS=//p' <<<"$out" | tr ' ' '\n' | grep -E '^[0-9]+$' >>"$EV/rt-load-host-pids.txt"
  sort -un "$EV/rt-load-host-pids.txt" -o "$EV/rt-load-host-pids.txt"
  ADV_ON=0
  [[ "$ADV_T1" =~ ^[0-9]+$ ]] || { fail "no BOOTTIME stamp before stopping rt-load: $out"; return 1; }
  grep -qx 'LEFT=0' <<<"$out" || { fail "rt-load still runs after pkill: $out"; return 1; }
}

# append Android's tid table to a file
snap_android_tids() {
  ANDROID_SH_TIMEOUT=90 android_sh "$INIT" "for t in /proc/[0-9]*/task/*; do p=\${t#/proc/}; echo \${p%%/*} \${t##*/}; done" \
    | tr -d '\r' | grep -E '^[0-9]+ [0-9]+$' >>"$EV/$1-android-tids.txt"
}

# run a traced Settings scroll
run_traced() {
  local tag="$1" secs="$2" adv="$3" ok=1 rect
  TR_OK=0; ADV_T0=""; ADV_T1=""; SCROLL_T0=""; SCROLL_T1=""
  : >"$EV/$tag-meta.txt"
  ft_start || return 1
  launch_settings "$tag" || ok=0
  if (( ok )); then
    rect=$(desktop_mapped_window_rect "$CDISP" 60) || { fail "Settings' window never mapped on display $CDISP: $rect"; ok=0; }
  fi
  if (( ok )); then park_pointer "$rect" || { fail "could not park the pointer over Settings"; ok=0; }; fi
  if (( ok && adv )); then adversary_start || ok=0; fi
  if (( ok )); then
    if (( adv )); then
      : >"$EV/$tag-android-tids.txt"
      local t_start=$SECONDS sj late=$(( secs > 12 ? secs - 8 : 7 ))
      scroll_for "$secs" "$tag" & sj=$!
      sleep 3
      snap_android_tids "$tag"
      (( SECONDS - t_start < late )) && sleep $(( late - (SECONDS - t_start) ))
      snap_android_tids "$tag"
      wait "$sj" || fail "the $secs s scroll on display $CDISP failed"
      sort -u "$EV/$tag-android-tids.txt" -o "$EV/$tag-android-tids.txt"
    else
      scroll_for "$secs" "$tag" || fail "the $secs s scroll on display $CDISP failed"
    fi
  fi
  (( ADV_ON )) && adversary_stop
  if (( ok )); then scroll_window "$tag" || fail "the $tag scroll's stamps are missing or malformed ($EV/$tag-scroll-stamps.txt)"; fi
  ANDROID_SH_TIMEOUT=30 android_sh "$INIT" "for p in \$(pidof $PKG); do for t in /proc/\$p/task/*; do echo \$p \${t##*/} \$(cat \$t/comm); done; done" \
    | tr -d '\r' >"$EV/$tag-app-threads.txt"
  android_sh "$INIT" "am force-stop $PKG" >/dev/null 2>&1
  sleep 2
  ft_stop || return 1
  ANDROID_SH_TIMEOUT=30 android_sh "$INIT" "dumpsys rhizo.host_delay" | tr -d '\r' >"$EV/$tag-dumpsys.txt"
  ft_collect "$tag" || return 1
  printf 'adversary=%s\nadv_t0=%s\nadv_t1=%s\nscroll_t0=%s\nscroll_t1=%s\nscroll_s=%s\nhost_pid=%s\n' "$adv" "${ADV_T0:-none}" "${ADV_T1:-none}" "${SCROLL_T0:-none}" "${SCROLL_T1:-none}" "$secs" "${APP_PID:-none}" >"$EV/$tag-meta.txt"
  TR_OK=1
}

# convert a trace to JSON with host-delay-trace.py
analyze() {
  local tag="$1" js="$EV/$1.json"
  echo "<none: $tag analysis did not run>" >"$js"
  (( TR_OK )) || { fail "no $tag trace to analyze"; return 1; }
  python3 ../../system/trace/host-delay-trace.py "$EV/$tag.pftrace" --app "$PKG" --json >"$js.tmp" 2>"$EV/$tag-analysis.err" \
    && [[ "$(dq "$js.tmp" "type(d['records']).__name__")" == list ]] \
    || { fail "host-delay-trace.py could not read the $tag trace ($EV/$tag-analysis.err)"; rm -f "$js.tmp"; return 1; }
  mv "$js.tmp" "$js"
}

# print the app's row from the dumpsys file
dumpsys_row() {
  python3 - "$1" "$2" <<'PY'
import sys
for line in open(sys.argv[1], errors="replace"):
    f = line.rstrip("\r\n").split("\t")
    if len(f) >= 7 and f[0] == sys.argv[2]:
        print(f[2], f[3], f[4], f[5], f[6])
        break
else:
    print("<none>")
PY
}

# restart units and the stack under policy.conf
restart_under_policy() {
  local tag="$1"; shift
  local u
  for u in "$@"; do
    ssh_vm -t 30 "systemctl restart $u" >"$EV/$tag-$u-restart.txt" 2>&1 || { fail "$u did not start ($EV/$tag-$u-restart.txt)"; return 1; }
  done
  test_publish_session_env || { fail "could not publish the desktop session env"; return 1; }
  test_restart_stack "$EV/$tag-restart.log" || { fail "the stack did not come back ($EV/$tag-restart.log)"; return 1; }
  INIT=$(guest_init_pid 10)
  wait_device_awake "$INIT" 20 >/dev/null
  android_stay_awake "$INIT" >/dev/null
}

# check the host_delay off posture
assert_off_posture() {
  local v state d1 d2 inst sock hproc
v=$(seen "$(ssh_vm -t 15 "echo \$(systemctl is-active rhizo-delayd.service) \$(test -e /run/rhizo-delay && echo present || echo absent) \
\$(test -e /run/rhizo-delayd && echo present || echo absent) \$(ls -d /sys/kernel/tracing/instances/rhizo-delay /sys/kernel/debug/tracing/instances/rhizo-delay 2>/dev/null | grep -c .) \
\$(test -e /proc/$INIT/root$SOCK_DIR && echo present || echo absent) \$(pgrep -fc '[r]hizo-host-delay')" | tr -d '\r')" "active present present 1 present 1")
read -r state d1 d2 inst sock hproc <<<"$v"
[[ "$state" != active && "$state" != "" && "$d1" == absent && "$d2" == absent && "$inst" == 0 && "$sock" == absent && "$hproc" == 0 ]] \
  && pass "$1: rhizo-delayd $state, no /run/rhizo-delay, no /run/rhizo-delayd, no tracefs instance, no $SOCK_DIR in the sandbox, no rhizo-host-delay process on the host" \
  || fail "$1: off left something: unit '$state', /run/rhizo-delay $d1, /run/rhizo-delayd $d2, tracefs instances $inst, sandbox socket dir $sock, host processes $hproc"
v=$(seen "$(android_sh "$INIT" "echo ps=\$(ps -A | grep -c [r]hizo-host-dela) svc=\$(service list | grep -c .) hd=\$(service list | grep -c rhizo.host_delay) bin=\$(test -e /system_ext/bin/hw/rhizo-host-delay && echo present || echo absent)" | tr -d '\r')" "ps=1 svc=40 hd=1 bin=present")
[[ "$v" =~ ^ps=0\ svc=([0-9]+)\ hd=0\ bin=absent$ && "${BASH_REMATCH[1]:-0}" -gt 0 ]] \
  && pass "$1: inside the sandbox: no rhizo-host-delay process, no rhizo.host_delay service (of ${BASH_REMATCH[1]} listed), no /system_ext/bin/hw/rhizo-host-delay" \
  || fail "$1: inside the sandbox with the capability off: '$v'"
  printf '%s\n' "$v" >"$EV/$1-off-state.txt"
}

test_require_staged rt-load || exit 1
if (( SKIP_BOOT == 0 )); then
  step "0. boot the guest, the desktop session and the stack with trace.host_delay at its default"
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
ssh_vm -t 15 "rm -f $POLICY_SAVED; if [ -e $POLICY_CONF ]; then cp -a $POLICY_CONF $POLICY_SAVED; fi" \
  || { fail "could not snapshot $POLICY_CONF"; exit 1; }
POLICY_SNAPSHOT=1
ssh_vm -t 15 "awk '/^\[/ { s = \$0 } s == \"[trace]\" && /^[ \t]*host_delay[ \t]*=/ { f = 1 } END { exit !f }' $POLICY_CONF 2>/dev/null" \
  && { fail "$POLICY_CONF already sets [trace] host_delay; the off leg needs the default"; exit 1; }
NPROC=$(ssh_vm -t 10 "nproc" | tr -d '\r')
[[ "$NPROC" =~ ^[1-9][0-9]*$ ]] || { fail "could not read the guest's CPU count ('$NPROC')"; exit 1; }
LASTCPU=$(( NPROC - 1 ))
ssh_vm -t 20 "cat > /usr/local/bin/rt-load && chmod 755 /usr/local/bin/rt-load" <../../../var/share/rt-load \
  || { fail "could not stage rt-load"; exit 1; }
RT_LOAD_STAGED=1
: >"$EV/rt-load-host-pids.txt"
if [[ "$RHIZO_DESKTOP_PROFILE" == sway ]]; then
  inject_start >"$EV/injector.log" 2>&1 || { fail "the wheel injector did not start (see $EV/injector.log)"; exit 1; }
fi

step "A. capability off: no daemon, no runtime dir, no tracefs instance, no socket, no Android daemon, no Rhizo record in a trace"
assert_off_posture A
run_traced off 10 0
analyze off
v=$(seen "$(dq "$EV/off.json" "len(d['frames'])")" 0)
[[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]] && pass "control: the trace holds $v FrameTimeline frames for $PKG" \
  || fail "control: no FrameTimeline frame for $PKG in the off trace ('$v') ($EV/off.json)"
v=$(seen "$(dq "$EV/off.json" "len(d['records']) + len(d['counters'])")" 5)
[[ "$v" == 0 ]] && pass "the off trace holds no Rhizo record and no Rhizo counter" || fail "the off trace holds Rhizo data: records+counters '$v' ($EV/off.json)"
v=$(seen "$(grep -a -o -e 'held off by the host' -e 'rhizo work periods' -e 'rhizo host-delayed work periods' "$EV/off.pftrace" | wc -l)" 3)
ctl=$(grep -a -o "$PKG" "$EV/off.pftrace" | wc -l)
[[ "$v" == 0 && "$ctl" -gt 0 ]] && pass "no Rhizo slice or counter name anywhere in the raw off trace (control: it names $PKG $ctl times)" \
  || fail "raw off trace: $v Rhizo name(s), $ctl mention(s) of $PKG"

step "S. trace.host_delay on: the daemon, its socket in the sandbox, Android's daemon, connected"
ssh_vm -t 20 "mkdir -p /etc/rhizo; printf '[trace]\nhost_delay = on\n' > $POLICY_CONF" || fail "could not write $POLICY_CONF"
restart_under_policy on rhizo-delayd.service
v=$(seen "$(ssh_vm -t 15 "echo \$(systemctl is-active rhizo-delayd.service) \$(test -S /proc/$INIT/root$SOCK_DIR/delayd && echo socket || echo none) \$(test -d /run/rhizo-delayd && echo present || echo absent)" | tr -d '\r')" "inactive none absent")
[[ "$v" == "active socket present" ]] && pass "rhizo-delayd active, the sandbox sees $SOCK_DIR/delayd, /run/rhizo-delayd present" \
  || fail "after switching on: '$v' (want 'active socket present')"
v=$(seen "$(await_android 60 "ps -A | grep -c [r]hizo-host-dela" 1 && echo up || echo down)" down)
[[ "$v" == up ]] && pass "Android's rhizo-host-delay runs in the sandbox" || fail "no rhizo-host-delay process in Android within 60 s"
v=$(seen "$(await_android 60 "dumpsys rhizo.host_delay | grep -c connected=yes" 1 && echo yes || echo no)" no)
android_sh "$INIT" "dumpsys rhizo.host_delay" | tr -d '\r' >"$EV/on-dumpsys.txt"
[[ "$v" == yes ]] && pass "dumpsys rhizo.host_delay says connected=yes" || fail "dumpsys rhizo.host_delay never said connected=yes ($EV/on-dumpsys.txt)"
ssh_vm -t 15 "cat /run/rhizo-delayd/status.json" >"$EV/on-state.txt" 2>&1

step "B. on, no load: no record of 2 ms or more, with the app's counters and FrameTimeline frames as controls"
await_entry_sync_idle "B. the entry sync after the stack restart"
run_traced quiet 20 0
analyze quiet
qt0=$(sed -n 's/^scroll_t0=//p' "$EV/quiet-meta.txt"); qt1=$(sed -n 's/^scroll_t1=//p' "$EV/quiet-meta.txt")
if [[ "$qt0" =~ ^[0-9]+$ && "$qt1" =~ ^[0-9]+$ ]]; then
  dq "$EV/quiet.json" "'records=%d of_2ms=%d of_2ms_in_steady_window=%d of_2ms_before_it=%d' % (len(d['records']), len([r for r in d['records'] if r['held_us'] >= 2000]), len([r for r in d['records'] if r['held_us'] >= 2000 and r['ts'] + r['dur'] > $qt0 and r['ts'] < $qt1]), len([r for r in d['records'] if r['held_us'] >= 2000 and r['ts'] + r['dur'] <= $qt0]))" >"$EV/b-report.txt"
  v=$(seen "$(dq "$EV/quiet.json" "len([r for r in d['records'] if r['held_us'] >= 2000 and r['ts'] + r['dur'] > $qt0 and r['ts'] < $qt1])")" 4)
  [[ "$v" == 0 ]] && pass "no record of 2 ms or more in the steady no-load window ($(( (qt1 - qt0) / 1000000000 )) s; launch cost in $EV/b-report.txt)" \
    || fail "$v record(s) of 2 ms or more in the steady no-load window ($EV/quiet.json, $EV/b-report.txt)"
  v=$(seen "$(dq "$EV/quiet.json" "len([f for f in d['frames'] if f['ts'] >= $qt0 and f['ts'] + f['dur'] <= $qt1])")" 0)
  [[ "$v" =~ ^[0-9]+$ && "$v" -ge 10 ]] && pass "control: $v of the app's FrameTimeline frames lie inside the steady window" \
    || fail "control: only '$v' FrameTimeline frames inside the steady no-load window, want at least 10 ($EV/quiet.json, $EV/quiet-meta.txt)"
else
  fail "no steady no-load window stamped ('$qt0'..'$qt1', $EV/quiet-meta.txt)"
fi
v=$(seen "$(dq "$EV/quiet.json" "d['counters'].get(str(d['app']['pid']), {}).get('work_periods', 0)")" 0)
[[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]] && pass "control: $PKG has $v work periods counted in the trace" \
  || fail "control: $PKG has no work_periods counter in the no-load trace ('$v') ($EV/quiet.json)"
v=$(seen "$(grep -c connected=yes "$EV/quiet-dumpsys.txt")" 0)
[[ "$v" == 1 ]] && pass "control: the dumpsys taken after the no-load leg says connected=yes" \
  || fail "the dumpsys taken after the no-load leg does not say connected=yes ($v, $EV/quiet-dumpsys.txt)"
v=$(seen "$(dq "$EV/quiet.json" "len(d['frames'])")" 0)
[[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]] && pass "control: $v FrameTimeline frames for $PKG in the no-load trace" \
  || fail "control: no FrameTimeline frame for $PKG in the no-load trace ('$v')"

step "C. on, under rt-load: records on the UI thread and the RenderThread, and the host's delay beside each frame FrameTimeline blames on the app"
run_traced adv 30 1
analyze adv
cp "$EV/adv-meta.txt" "$EV/adversary-window.txt" 2>/dev/null
ssh_vm -t 20 "cat /root/rt-load-adv-*.txt" >"$EV/rt-load-adv.txt" 2>&1
read -r T0 T1 <<<"$(sed -n 's/^adv_t0=//p;s/^adv_t1=//p' "$EV/adv-meta.txt" | tr '\n' ' ')"
v=$(seen "$(JSON="$EV/adv.json" T0="${T0:-0}" T1="${T1:-0}" hdpy '
app = d["app"]; pid = app["pid"]; t0 = int(os.environ["T0"]); t1 = int(os.environ["T1"])
recs = [r for r in d["records"] if r["pid"] == pid and r["ts"] + r["dur"] >= t0 and r["ts"] <= t1]
ui = [r for r in recs if r["tid"] == pid]
rt = [r for r in recs if r["thread"] == "RenderThread" or r["tid"] == app["render_tid"]]
sfpid = d["surfaceflinger"]["pid"]
sf = [r for r in d["records"] if sfpid is not None and r["pid"] == sfpid]
blamed = [(min(f["expected_ts"] if f["expected_ts"] is not None else f["ts"], f["ts"]), f["ts"] + f["dur"])
          for f in d["frames"] if not f["on_time"] and "App Deadline Missed" in f["jank_type"]
          and f["ts"] >= t0 and f["ts"] + f["dur"] <= t1]
def held(rs, w):
    return sum(hdt.held_in_window(r, w[0], w[1]) for r in rs)
hit = sum(1 for w in blamed if held(ui + rt + sf, w) >= 2000000)
hit_uirt = sum(1 for w in blamed if held(ui + rt, w) >= 2000000)
drawn = sorted(f["ts"] for f in d["frames"] if f["ts"] >= t0 and f["ts"] + f["dur"] <= t1)
gap_ms = max(b - a for a, b in zip([t0] + drawn, drawn + [t1])) // 1000000
print(len(ui), len(rt), len(blamed), hit, hit_uirt, sfpid if sfpid is not None else "none", len(drawn), gap_ms)')" "0 0 0 0 0 none 0 0")
read -r nui nrt nfr nhit nhit_uirt sfpid ndrawn gapms <<<"$v"
log "    adversary $T0..$T1: UI records $nui, RenderThread records $nrt, late App-Deadline-Missed frames $nfr, of those >= 2 ms held on UI+RenderThread+SurfaceFlinger $nhit, on UI+RenderThread alone $nhit_uirt; app frames drawn $ndrawn, longest stretch with none ${gapms} ms"
printf 'blamed_frames=%s held_uirt_or_sf=%s held_uirt_only=%s surfaceflinger_pid=%s drawn_frames=%s longest_gap_ms=%s\n' "$nfr" "$nhit" "$nhit_uirt" "$sfpid" "$ndrawn" "$gapms" >"$EV/c-report.txt"
[[ "$nui" =~ ^[0-9]+$ && "$nui" -gt 0 ]] && pass "$nui record(s) on the app's UI thread (tid == pid) during the adversary" \
  || fail "no record on the app's UI thread during the adversary ('$v', $EV/adv.json)"
[[ "$nrt" =~ ^[0-9]+$ && "$nrt" -gt 0 ]] && pass "$nrt record(s) on the app's RenderThread during the adversary" \
  || fail "no record on the app's RenderThread during the adversary ('$v', $EV/adv.json)"
[[ "$sfpid" =~ ^[0-9]+$ ]] && pass "control: the trace names SurfaceFlinger (pid $sfpid)" \
  || fail "control: the trace names no single /system/bin/surfaceflinger ('$sfpid', $EV/adv.json)"
[[ "$nfr" =~ ^[0-9]+$ && "$nfr" -ge 10 ]] && pass "control: FrameTimeline marks $nfr of the app's frames inside the adversary late with App Deadline Missed" \
  || fail "control: only '$nfr' late App-Deadline-Missed frames inside the adversary interval ($ndrawn app frames drawn, the longest stretch with none ${gapms} ms), want at least 10 ($EV/adv.json, $EV/adv-meta.txt)"
[[ "$nfr" =~ ^[0-9]+$ && "$nhit" =~ ^[0-9]+$ && "$nfr" -ge 10 ]] && (( nhit * 100 >= nfr * 90 )) \
  && pass "$nhit of $nfr frames FrameTimeline blames on the app hold >= 2 ms of host delay on its UI thread, RenderThread or SurfaceFlinger between expected start and actual end (>= 90%; $nhit_uirt on the app's two threads alone)" \
  || fail "only '$nhit' of '$nfr' frames FrameTimeline blames on the app hold >= 2 ms of host delay beside them, want 90% ($EV/c-report.txt)"
v=$(seen "$(JSON="$EV/adv.json" SNAP="$EV/adv-android-tids.txt" hdpy '
pid = d["app"]["pid"]
snap = {tuple(int(x) for x in l.split()) for l in open(os.environ["SNAP"]) if len(l.split()) == 2}
recs = [r for r in d["records"] if r["pid"] == pid]
ui = {(r["pid"], r["tid"]) for r in recs if r["tid"] == pid}
rt = {(r["pid"], r["tid"]) for r in recs if r["thread"] == "RenderThread" or r["tid"] == d["app"]["render_tid"]}
print(len(snap), len(ui), len(ui - snap), len(rt), len(rt - snap))')" "0 0 9 0 9")
read -r nsnap nui2 nuibad nrt2 nrtbad <<<"$v"
[[ "$nsnap" =~ ^[0-9]+$ && "$nsnap" -gt 0 && "$nui2" -gt 0 && "$nuibad" == 0 ]] \
  && pass "the UI thread's record tid(s) ($nui2) are all in Android's own tid snapshot ($nsnap threads)" \
  || fail "UI-thread record tids against Android's own snapshot: snapshot=$nsnap recorded=$nui2 not-in-snapshot=$nuibad ($EV/adv-android-tids.txt)"
[[ "$nsnap" =~ ^[0-9]+$ && "$nsnap" -gt 0 && "$nrt2" -gt 0 && "$nrtbad" == 0 ]] \
  && pass "the RenderThread's record tid(s) ($nrt2) are all in Android's own tid snapshot" \
  || fail "RenderThread record tids against Android's own snapshot: snapshot=$nsnap recorded=$nrt2 not-in-snapshot=$nrtbad ($EV/adv-android-tids.txt)"

step "D. nothing Android can read holds rt-load or a host pid, judged against Android's own tid snapshot"
: >"$EV/d-report.txt"
for t in quiet adv; do
  for f in "$t.pftrace" "$t-dumpsys.txt"; do
    n=$(grep -a -c rt-load "$EV/$f" 2>/dev/null); ctl=$(grep -a -c -e "$PKG" -e 'rhizo host delay' "$EV/$f" 2>/dev/null)
    echo "$f rt-load=$n control=$ctl" >>"$EV/d-report.txt"
    v=$(seen "$n" 2)
    [[ "$v" == 0 && "$ctl" -gt 0 ]] && pass "no rt-load in $f (control: it names $PKG or the service $ctl times)" \
      || fail "$f: rt-load appears $v time(s), control hits $ctl"
  done
done
android_sh "$INIT" "logcat -d -b all | grep -i -E host.delay | tail -300" | tr -d '\r' >"$EV/logcat-hostdelay.txt"
v=$(seen "$(android_sh "$INIT" "echo total=\$(logcat -d -b all | grep -c .) rtload=\$(logcat -d -b all | grep -c rt-load)" | tr -d '\r')" "total=0 rtload=1")
[[ "$v" =~ ^total=([0-9]+)\ rtload=0$ && "${BASH_REMATCH[1]:-0}" -gt 0 ]] && pass "Android's whole logcat (${BASH_REMATCH[1]} lines) holds no rt-load" \
  || fail "logcat -d -b all: '$v'"
ssh_vm -t 15 "ls -A /proc/$INIT/root$SOCK_DIR" | tr -d '\r' >"$EV/socket-dir.txt" 2>&1
v=$(seen "$(cat "$EV/socket-dir.txt")" "delayd status.json")
[[ "$v" == delayd ]] && pass "$SOCK_DIR holds only the socket (delayd)" || fail "$SOCK_DIR holds '$v' ($EV/socket-dir.txt)"
t=adv
v=$(seen "$(JSON="$EV/$t.json" PIDS="$EV/rt-load-host-pids.txt" SNAP="$EV/$t-android-tids.txt" DUMP="$EV/$t-dumpsys.txt" hdpy '
host = {int(l) for l in open(os.environ["PIDS"]) if l.strip().isdigit()}
snap = {int(x) for l in open(os.environ["SNAP"]) for x in l.split() if x.isdigit()}
rec = {int(x) for r in d["records"] for x in (r["pid"], r["tid"]) if x is not None} | {int(k) for k in d["counters"]}
dump = {int(l.split("\t")[0]) for l in open(os.environ["DUMP"], errors="replace") if l.split("\t")[0].isdigit()}
tbl = {(x["pid"], x["tid"]) for x in d["threads"]}
nmiss = len({(r["pid"], r["tid"]) for r in d["records"]} - tbl)
print(len(d["records"]), len(snap), len((rec & host) - snap), len((dump & host) - snap), nmiss)')" "0 0 7 7 7")
read -r nrec nsnap ncoll ndump nmiss <<<"$v"
echo "$t records=$nrec android-snapshot-numbers=$nsnap rt-load-numbers-in-records-not-in-snapshot=$ncoll rt-load-numbers-in-dumpsys-not-in-snapshot=$ndump (evidence only: records-not-in-trace-thread-table=$nmiss)" >>"$EV/d-report.txt"
[[ "$nsnap" =~ ^[0-9]+$ && "$nsnap" -gt 0 && "$nrec" =~ ^[0-9]+$ ]] \
  && pass "control: Android's own tid snapshot for $t holds $nsnap numbers" \
  || fail "control: Android's tid snapshot for $t is empty or unreadable ('$v', $EV/$t-android-tids.txt)"
[[ "$ncoll" == 0 ]] && pass "$t: no rt-load host pid or tid is a Rhizo record pid or tid unless Android's own snapshot holds that number" \
  || fail "$t: $ncoll record pid/tid(s) are rt-load host numbers Android does not have ($EV/$t.json, $EV/rt-load-host-pids.txt, $EV/$t-android-tids.txt)"
[[ "$ndump" == 0 ]] && pass "$t: no rt-load host pid or tid is a pid in a dumpsys row unless Android's own snapshot holds it" \
  || fail "$t: $ndump dumpsys pid(s) are rt-load host numbers Android does not have ($EV/$t-dumpsys.txt)"
v=$(seen "$(grep -c -E '^[0-9]+$' "$EV/rt-load-host-pids.txt")" 0)
(( v >= NPROC )) && pass "control: $v rt-load host pids and tids recorded" || fail "control: only $v rt-load host pid(s) recorded for $NPROC vCPUs"

step "E. dumpsys equals the trace's last counters; the counters' growth over the trace equals the recount of its records"
: >"$EV/e-report.txt"
for t in quiet adv; do
  need=0; [[ "$t" == adv ]] && need=1
  apid=$(dq "$EV/$t.json" "d['app']['pid']")
  row=$(dumpsys_row "$EV/$t-dumpsys.txt" "$apid")
  out=$(JSON="$EV/$t.json" ROW="$row" NEED="$need" hdpy '
pid = d["app"]["pid"]
row = os.environ["ROW"].split()
c = d["counters"].get(str(pid))
rc = hdt.recount(d["records"]); rc = rc.get(pid) or rc.get(str(pid)) or {"delays": 0, "held_us": 0, "host_delayed": 0}
keys = ("work_periods", "host_delayed", "delays", "held_us")
first = (c or {}).get("first")
def verdict(bad, ok):
    return "MISMATCH " + "; ".join(bad) if bad else "MATCH " + ok
if len(row) < 5 or c is None:
    msg = "MISMATCH no dumpsys row or no counter track for pid %s" % pid
    print(msg); print(msg); print(msg); sys.exit(0)
dv = dict(zip(keys, (int(x) for x in row[:4])))
def nulls(src):
    return [k for k in keys if not isinstance(src.get(k), int)]
bad = ["%s null in the last trace sample" % k for k in nulls(c)]
bad += ["%s dumpsys=%s trace-last=%s" % (k, dv[k], c.get(k)) for k in keys if dv[k] != c.get(k)]
if dv["work_periods"] == 0:
    bad.append("work_periods is 0")
print(verdict(bad, "pid=%s %s" % (pid, " ".join(str(dv[k]) for k in keys))))
if not isinstance(first, dict) or any(k not in first for k in keys):
    msg = "MISMATCH the counters carry no first sample (%r)" % (first,)
    print(msg); print(msg); sys.exit(0)
bad = ["%s null in the last or first sample" % k for k in ("delays", "held_us") if not isinstance(c.get(k), int) or not isinstance(first.get(k), int)]
for k, want in (("delays", rc["delays"]), ("held_us", rc["held_us"])):
    if k not in [b.split()[0] for b in bad] and c[k] - first[k] != want:
        bad.append("%s last-first=%s recount=%s" % (k, c[k] - first[k], want))
if os.environ["NEED"] == "1" and rc["delays"] == 0:
    bad.append("no records under the adversary")
print(verdict(bad, "delays %s held_us %s" % (rc["delays"], rc["held_us"])))
bad = []
if not isinstance(c.get("host_delayed"), int) or not isinstance(first.get("host_delayed"), int):
    bad.append("host_delayed null in the last or first sample")
elif c["host_delayed"] - first["host_delayed"] != rc["host_delayed"]:
    bad.append("host_delayed last-first=%s recount=%s" % (c["host_delayed"] - first["host_delayed"], rc["host_delayed"]))
if os.environ["NEED"] == "1" and rc["host_delayed"] == 0:
    bad.append("recount host_delayed is 0 under the adversary")
print(verdict(bad, "host_delayed %s" % rc["host_delayed"]))')
  e1=$(sed -n 1p <<<"$out"); e2=$(sed -n 2p <<<"$out"); e3=$(sed -n 3p <<<"$out")
  printf '%s pid=%s row=%s\n  1: %s\n  2: %s\n  3: %s\n' "$t" "$apid" "$row" "$e1" "$e2" "$e3" >>"$EV/e-report.txt"
  v=$(seen "$e1" "MISMATCH corrupted")
  [[ "$v" == MATCH* ]] && pass "$t: dumpsys row equals the trace's last counters ($v)" \
    || fail "$t: dumpsys against the trace's last counters: $v ($EV/$t-dumpsys.txt, $EV/$t.json)"
  v=$(seen "$e2" "MISMATCH corrupted")
  [[ "$v" == MATCH* ]] && pass "$t: counters' growth in delays and held_us equals the recount of the app's records ($v)" \
    || fail "$t: delays/held_us growth against the recount: $v ($EV/$t.json)"
  v=$(seen "$e3" "MISMATCH corrupted")
  [[ "$v" == MATCH* ]] && pass "$t: counters' growth in host_delayed equals the recount's ($v)" \
    || fail "$t: host_delayed growth against the recount: $v ($EV/$t.json)"
done

step "F. rt.budgets and trace.host_delay both on: rtd active, power sessions on, delayd connected, a traced scroll still yields counters"
kmsg_mark F || fail "could not write a mark into the kernel log"
ssh_vm -t 20 "mkdir -p /etc/rhizo; printf '[rt]\nbudgets = on\n[trace]\nhost_delay = on\n' > $POLICY_CONF" || fail "could not write $POLICY_CONF"
restart_under_policy rtd rhizo-rtd.service rhizo-delayd.service
v=$(seen "$(ssh_vm -t 10 "systemctl is-active rhizo-rtd.service" | tr -d '\r')" inactive)
[[ "$v" == active ]] && pass "rhizo-rtd.service active" || fail "rhizo-rtd.service is '$v'"
v=$(seen "$(dmesg_after F | grep -a -o 'RHIZO_MARKER power_sessions=[a-z]*' | tail -1)" "RHIZO_MARKER power_sessions=off")
[[ "$v" == "RHIZO_MARKER power_sessions=on" ]] && pass "the power HAL reported sessions on" || fail "power HAL marker since this leg's restart: '$v'"
v=$(seen "$(await_android 60 "dumpsys rhizo.host_delay | grep -c connected=yes" 1 && echo yes || echo no)" no)
[[ "$v" == yes ]] && pass "dumpsys rhizo.host_delay says connected=yes beside rt.budgets" || fail "dumpsys rhizo.host_delay never said connected=yes with rt.budgets on"
run_traced rtd 10 0
analyze rtd
v=$(seen "$(dq "$EV/rtd.json" "d['counters'].get(str(d['app']['pid']), {}).get('work_periods', 0)")" 0)
[[ "$v" =~ ^[0-9]+$ && "$v" -gt 0 ]] && pass "with rt.budgets on, $PKG still has $v work periods counted in the trace" \
  || fail "no work_periods counter for $PKG in the rt.budgets-on trace ('$v', $EV/rtd.json)"
v=$(seen "$(grep -a -c rt-load "$EV/rtd.pftrace")" 2)
[[ "$v" == 0 ]] && pass "no rt-load in the rt.budgets-on trace" || fail "rt-load appears $v time(s) in the rt.budgets-on trace"

step "H. off after on is unreachable again: the default policy back, rhizo-delayd stopped, the stack restarted"
ssh_vm -t 30 "if [ -e $POLICY_SAVED ]; then cp -a $POLICY_SAVED $POLICY_CONF; else rm -f $POLICY_CONF; fi
  systemctl stop rhizo-delayd.service rhizo-rtd.service" >"$EV/H-stop.txt" 2>&1 || fail "could not put the default policy back and stop the daemons ($EV/H-stop.txt)"
restart_under_policy H
assert_off_posture H

step "G. enforce=1, and no denial naming the capability's types since the system test started"
v=$(seen "$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce' | tr -d '\r')" 0)
[[ "$v" == 1 ]] && pass "enforcing at the end" || fail "enforce=$v at the end"
dmesg_after start >"$EV/kmsg-since-start.txt"
grep -qx KMSG_END "$EV/kmsg-since-start.txt" && ! grep -qx NO_MARK "$EV/kmsg-since-start.txt" \
  || fail "the kernel log since the system test's start mark could not be read whole ($EV/kmsg-since-start.txt)"
grep -a 'avc:  denied' "$EV/kmsg-since-start.txt" \
  | grep -a -E 'rhizo_delayd|rhizo_host_delay|rhizo_delay_socket|rhizo_host_delay_service' >"$EV/avc-feature.txt"
v=$(seen "$(grep -c . "$EV/avc-feature.txt")" 1)
[[ "$v" == 0 ]] && pass "no denial naming rhizo_delayd, rhizo_host_delay, rhizo_delay_socket or rhizo_host_delay_service" \
  || fail "$v feature denial(s): $EV/avc-feature.txt"

if (( SELFTEST )); then
  failed_steps=$(cut -f2 "$EV/failures.log" 2>/dev/null | sed 's/^step=//' | sort -u)
  survived=()
  for st in "${SELFTEST_STEPS[@]}"; do
    [[ "$st" == 0.* ]] && continue
    grep -Fxq "$st" <<<"$failed_steps" || survived+=("$st")
  done
  if (( ${#survived[@]} )); then
    printf 'FAILED selftest: legs passed on a corrupted value:\n%s\n' "$(printf '  %s\n' "${survived[@]}")" > "$EV/selftest-verdict.txt"
    test_record_verdict FAILED "selftest=1"; log "HOST-DELAY SYSTEM TEST SELFTEST FAILED"; exit 1
  fi
  echo "PASSED selftest: every asserting leg failed on a corrupted value" > "$EV/selftest-verdict.txt"
  test_record_verdict PASSED "selftest=1"; log "HOST-DELAY SYSTEM TEST SELFTEST PASSED"; exit 0
fi
if (( FAILED )); then test_record_verdict FAILED; log "HOST-DELAY SYSTEM TEST FAILED"; exit 1; fi
test_record_verdict PASSED
log "HOST-DELAY SYSTEM TEST PASSED -- evidence in $EV"
