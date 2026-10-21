#!/bin/bash
# test the sandbox's network on a boot
# RHIZO_RELEASE=a15 targets that release through test_boot; default a16
# test-boot-mode: shared
# test-boots-unit: no
# test-nests: install.sh,launcher.sh
# test-records-metrics: no
# test-requires: share:rhizo-nettest share:rhizo-nettest.apk share:rhizo-nettest.json share:rhizo-nettest2.apk share:rhizo-nettest2.json share:rhizo-vpntest.apk share:rhizo-vpntest.json file:aapt2
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
[[ "${RHIZO_DESKTOP_PROFILE:-sway}" == sway ]] \
  || { fail "this system test only runs under the sway desktop profile (got RHIZO_DESKTOP_PROFILE=$RHIZO_DESKTOP_PROFILE)"; exit 1; }
source ../lib/sway-lib.sh

ADB=~/Android/Sdk/platform-tools/adb

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
[[ "${1:-}" == "--skip-boot" ]] && SKIP_BOOT=1

export RHIZO_USE_UNIT=1

test_init network

ANDROID_RAN_TOKEN=RHIZO_TEST_RAN
ANDROID_VALUE=""

# print a command's output, or return 97 if it never ran
android_observe() {
  local out rc
  out=$(android_sh "$1" "$2; echo $ANDROID_RAN_TOKEN=\$?"); rc=$?
  (( rc == 97 || rc == 98 )) && return 97
  out="${out//$'\r'/}"
  [[ "$out" =~ ${ANDROID_RAN_TOKEN}=[0-9]+$ ]] || return 97
  out="${out%"$ANDROID_RAN_TOKEN"=*}"
  printf '%s' "${out%$'\n'}"
}

# fail naming the Android channel as dead
channel_dead() {
  fail "cannot observe Android: '$1' never ran on init ${INIT:-<none>} (no completion token)"
}

# print a command's output, or a line saying no channel ran it
observe_or_note() {
  android_observe "$1" "$2" || echo "<no channel ran: $2>"
}

# print the guest clock in logcat -t form
guest_log_marker() {
  local m
  m=$(android_observe "$1" "date +'%m-%d %H:%M:%S.000'") || return 97
  tail -1 <<<"$m"
}

# fail with the message or name the dead channel
poll_never() {
  if (( $1 == 0 )); then
    channel_dead "$2"
  else
    fail "$3"
  fi
}

# check a command prints the expected value
expect_android_value() {
  local msg="$4"
  if ! ANDROID_VALUE=$(android_observe "$1" "$2"); then
    channel_dead "$2"
    return 97
  fi
  [[ "$ANDROID_VALUE" == "$3" ]] && return 0
  [[ "$msg" == *@VALUE@* ]] && msg="${msg%%@VALUE@*}${ANDROID_VALUE:-<empty>}${msg#*@VALUE@}"
  fail "$msg"
  return 1
}

NSENTER_MARKER_BOOT="${TMPDIR:-/tmp}/rhizo-nsenter-boot.${RHIZO_VM:-0}"
# clear nsenter dead-channel markers from earlier boots
scope_nsenter_markers_to_boot() {
  local boot_id stamped=""
  boot_id=$(ssh_vm -t 8 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null | tr -d '[:space:]')
  [[ -r "$NSENTER_MARKER_BOOT" ]] && read -r stamped < "$NSENTER_MARKER_BOOT"
  [[ -n "$boot_id" && "$stamped" == "$boot_id" ]] && return 0
  rm -f "${TMPDIR:-/tmp}/rhizo-nsenter-dead.${RHIZO_VM:-0}."*
  if [[ -n "$boot_id" ]]; then
    printf '%s\n' "$boot_id" > "$NSENTER_MARKER_BOOT"
  else
    rm -f "$NSENTER_MARKER_BOOT"
  fi
  log "    cleared vm ${RHIZO_VM:-0}'s nsenter dead-channel markers: none belongs to boot ${boot_id:-<unreadable>}"
  return 0
}

# print the top resumed activity on a display
resumed_on() {
  local acts top
  acts=$(android_observe "$1" "dumpsys activity activities") || return 97
  top=$(awk -v want="Display #$2 " '/Display #/ {inseg = index($0, want) > 0}
                                    inseg && /topResumedActivity=/ {print; exit}' <<<"$acts")
  sed 's/.*ActivityRecord{[^ ]* [^ ]* \([^ }]*\).*/\1/' <<<"$top"
  return 0
}

AAPT2="$VAR_DIR/share/aapt2"
[[ -x "$AAPT2" ]] || { fail "missing $AAPT2 -- run tools/build/toolchain/aapt2.sh"; exit 1; }

VETH_HOST_IP="192.168.100.1"
TEST_HOST="rhizo-test.internal"
if [[ "${RHIZO_ENABLE_PUBLIC_EGRESS:-0}" == "1" ]]; then
  HOST_EGRESS_PROXY="${RHIZO_HOST_EGRESS_PROXY:-http://10.0.2.100:40000}"
else
  HOST_EGRESS_PROXY="${RHIZO_HOST_EGRESS_PROXY:-http://10.0.2.2:40000}"
fi

TESTAPK="$VAR_DIR/share/rhizo-nettest.apk"
TESTAPK_META="$VAR_DIR/share/rhizo-nettest.json"
NATIVE_CLIENT="$VAR_DIR/share/rhizo-nettest"
for f in "$TESTAPK" "$TESTAPK_META" "$NATIVE_CLIENT"; do
  [[ -f "$f" ]] || { fail "missing $f -- run tools/build/test-apps/testapp.sh and tools/build/hal/hal.sh rhizo-nettest first"; exit 1; }
done
python3 ../../../tools/build/stamps.py require rhizo-nettest \
  || { fail "a staged network fixture no longer matches its sources -- rebuild it as the line above names"; exit 1; }
PKG=$(python3 -c "import json;print(json.load(open('$TESTAPK_META'))['package'])")
ACT=$(python3 -c "import json;print(json.load(open('$TESTAPK_META'))['activity'])")
log "test app: $PKG/$ACT"

if (( SKIP_BOOT == 0 )); then
  step "0. boot: VM, compositor, Android"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  ../../vm/start/start-sway.sh >$EV/network-sway.log 2>&1 || { fail "sway did not start (see $EV/network-sway.log)"; exit 1; }
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 180 >$EV/network-redeploy.log 2>&1 || { fail "redeploy.sh failed (see $EV/network-redeploy.log)"; exit 1; }
  tail -6 $EV/network-redeploy.log
fi
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
scope_nsenter_markers_to_boot
log "init_pid=$INIT"

boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"
SS_PID_START=$(system_server_pid "$INIT")
log "system_server pid at start: $SS_PID_START"
TEST_SINCE=""
if test_since=$(android_observe "$INIT" "date +\"%m-%d %H:%M:%S.000\""); then
  TEST_SINCE=$(tail -1 <<<"$test_since")
else
  channel_dead "date +%m-%d %H:%M:%S.000"
fi

android_sh "$INIT" "settings delete global http_proxy" >/dev/null
android_sh "$INIT" "settings delete global global_http_proxy_host" >/dev/null
android_sh "$INIT" "settings delete global global_http_proxy_port" >/dev/null
android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "locksettings set-disabled true" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
if power=$(android_observe "$INIT" "dumpsys power"); then
  awake=$(grep -m1 -o "mWakefulness=[A-Za-z]*" <<<"$power")
  [[ "$awake" == "mWakefulness=Awake" ]] || fail "device is not awake ($awake)"
else
  channel_dead "dumpsys power"
fi
pass "booted, awake, keyguard disabled"

step "1. VM-side DNS+HTTP+DHCP servers"
../../vm/start/start-netbridge.sh --local-a "$TEST_HOST=$VETH_HOST_IP" >> "$EV/netserv-start.log" 2>&1
if ../../vm/start/start-netserv.sh "$VETH_HOST_IP" "$TEST_HOST" >> "$EV/netserv-start.log" 2>&1; then
  pass "netserv self-verified up"
else
  fail "start-netserv.sh did not self-verify -- see $EV/netserv-start.log"
  tail -20 "$EV/netserv-start.log"
fi

step "1b. captive portal seen by a boot's first validation, then cleared"
PORTAL_IP=192.168.100.2
PORTAL_PROBE=portalprobe.rhizo.test
# print the Capabilities of the first NetworkAgentInfo
caps_now() {
  android_observe "$INIT" 'dumpsys connectivity | grep -E "NetworkAgentInfo" | grep -m1 -o "Capabilities: [A-Z_&]*"'
}

# print the capability list of each real network
network_caps() {
  grep -E "NetworkAgentInfo" <<<"$1" | grep -oE "Capabilities: [A-Z_&]+" | sed 's/^Capabilities: //'
}
# return whether a capability list holds a token exactly
caps_have() { tr '&' '\n' <<<"$1" | grep -qx "$2"; }

# print a guest directory's nanosecond mtime
settings_dir_mtime() {
  local init_pid="$1" dir="$2" out
  local mtime_re='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'
  out=$(android_observe "$init_pid" "toybox stat -c %y $dir") || return 97
  out="${out//$'\n'/}"
  printf '%s' "$out"
  [[ "$out" =~ $mtime_re ]] || return 96
  return 0
}

# print this machine's wall clock in milliseconds
now_ms() {
  echo $(( $(date +%s%N) / 1000000 ))
}

# poll for a settings rename past the baseline
wait_settings_durable() {
  local baseline="$1" min_gap_ms="$2" last_put_ms="$3" deadline_s="$4" poll_s="$5"; shift 5
  local end_ms mtime="$baseline" moved=0 rc left_ms
  end_ms=$(( $(now_ms) + deadline_s * 1000 ))
  while :; do
    mtime=$("$@"); rc=$?
    if (( rc == 97 )); then
      printf "cannot observe Android: the read '%s' never ran (no completion token)" "$*"
      return 2
    elif (( rc != 0 )); then
      printf "the read '%s' printed '%s', not an mtime" "$*" "$mtime"
      return 2
    fi
    [[ "$mtime" != "$baseline" ]] && moved=1
    if (( moved )) && (( $(now_ms) - last_put_ms >= min_gap_ms )); then
      printf '%s' "$mtime"
      return 0
    fi
    left_ms=$(( end_ms - $(now_ms) ))
    (( left_ms > 0 )) || break
    (( left_ms > poll_s * 1000 )) && left_ms=$(( poll_s * 1000 ))
    sleep "$(( left_ms / 1000 )).$(printf '%03d' $(( left_ms % 1000 )))"
  done
  if (( moved )); then
    printf 'rename seen but only %dms since the last put, need %dms' \
      "$(( $(now_ms) - last_put_ms ))" "$min_gap_ms"
  else
    printf 'no rename seen in %ss, still %s' "$deadline_s" "$mtime"
  fi
  return 1
}

SETTINGS_USERS_DIR="/data/system/users/0"
MIN_PUT_GAP_MS=2500
PORTAL_URL="http://$PORTAL_PROBE/generate_204"
SETTINGS_MTIME=""

# set SETTINGS_MTIME to the users dir's mtime
read_settings_mtime() {
  local rc
  SETTINGS_MTIME=$(settings_dir_mtime "$INIT" "$SETTINGS_USERS_DIR"); rc=$?
  case "$rc" in
    0) return 0 ;;
    97) channel_dead "toybox stat -c %y $SETTINGS_USERS_DIR" ;;
    *) fail "toybox stat on $SETTINGS_USERS_DIR printed '$SETTINGS_MTIME', not an mtime" ;;
  esac
  return 1
}

# wait for a settings write to persist
await_settings_durable() {
  local rc
  SETTINGS_MTIME=$(wait_settings_durable "$2" "$MIN_PUT_GAP_MS" "$3" 10 1 \
      settings_dir_mtime "$INIT" "$SETTINGS_USERS_DIR"); rc=$?
  case "$rc" in
    0) return 0 ;;
    2) fail "$SETTINGS_MTIME -- $1 not judged on this boot" ;;
    *) fail "$1 never proved durable in $SETTINGS_USERS_DIR -- $SETTINGS_MTIME" ;;
  esac
  return "$rc"
}

# write the captive-portal probe URL settings
write_portal_probe_url() {
  local baseline put_ms rc
  read_settings_mtime || return 1
  baseline="$SETTINGS_MTIME"
  android_sh "$INIT" "settings delete global captive_portal_http_url" >/dev/null
  android_sh "$INIT" "settings delete global captive_portal_https_url" >/dev/null
  android_sh "$INIT" "settings delete global captive_portal_use_https" >/dev/null
  android_sh "$INIT" "settings put global captive_portal_http_url $PORTAL_URL" >/dev/null
  android_sh "$INIT" "settings put global captive_portal_https_url $PORTAL_URL" >/dev/null
  android_sh "$INIT" "settings put global captive_portal_use_https 0" >/dev/null
  put_ms=$(now_ms)
  expect_android_value "$INIT" "settings get global captive_portal_http_url" "$PORTAL_URL" \
    "the probe URL did not take on the boot that wrote it (reads '@VALUE@')" || return 1
  expect_android_value "$INIT" "settings get global captive_portal_https_url" "$PORTAL_URL" \
    "captive_portal_https_url did not take on the boot that wrote it (reads '@VALUE@')" || return 1
  expect_android_value "$INIT" "settings get global captive_portal_use_https" "0" \
    "captive_portal_use_https did not take on the boot that wrote it (reads '@VALUE@')" || return 1
  await_settings_durable "the captive-portal Settings.Global write" "$baseline" "$put_ms"; rc=$?
  (( rc == 2 )) && return 1
  if (( rc == 0 )); then
    baseline="$SETTINGS_MTIME"
  else
    read_settings_mtime || return 1
    baseline="$SETTINGS_MTIME"
  fi
  android_sh "$INIT" "device_config delete connectivity captive_portal_use_https" >/dev/null
  android_sh "$INIT" "device_config put connectivity captive_portal_use_https 0" >/dev/null
  put_ms=$(now_ms)
  expect_android_value "$INIT" "device_config get connectivity captive_portal_use_https" "0" \
    "the captive-portal device_config write did not take on the boot that wrote it (reads '@VALUE@')" || return 1
  await_settings_durable "the captive-portal device_config write (Settings.Config, its own SettingsState/file)" "$baseline" "$put_ms"
  (( $? == 2 )) && return 1
  expect_android_value "$INIT" "settings get global captive_portal_http_url" "$PORTAL_URL" \
    "the probe URL no longer reads back after the durability waits (reads '@VALUE@')"
}
write_portal_probe_url
android_sh "$INIT" "sync" >/dev/null 2>&1
ssh_vm -t 20 "sync" >/dev/null 2>&1
log "    rebooting so a new NetworkMonitor reads $PORTAL_PROBE"
kill_vm
boot_vm
wait_for_boot_slot || fail "the portal-probe reboot never got a qemu slot"
wait_for_ssh 300 || fail "the vm did not come back after the portal-probe reboot"
../../vm/start/start-sway.sh >>"$EV/netfix-portal.log" 2>&1
../../vm/sync.sh >/dev/null
portal_armed="$TEST_WORKDIR/portal-armed"
(
  deadline=$(( $(date +%s) + 300 ))
  while (( $(date +%s) < deadline )); do
    if ssh_vm -t 8 "ip addr show vethrhz0 2>/dev/null | grep -q ' ${VETH_HOST_IP}/'" 2>/dev/null; then
      ../../vm/start/start-netfix.sh portalserv up "$PORTAL_IP" >>"$EV/netfix-portal.log" 2>&1 \
        && echo armed > "$portal_armed"
      exit 0
    fi
    sleep 2
  done
) &
portal_waiter=$!
RHIZO_GATE_EXTRA_INPUT_PORTS="tcp:80,tcp:8081,udp:5353" \
  RHIZO_NETBRIDGED_ARGS="--local-a,$TEST_HOST=$VETH_HOST_IP,--local-a,$PORTAL_PROBE=$VETH_HOST_IP,--portal,$PORTAL_IP" \
  ../../vm/redeploy.sh --skip-kill --boot-wait 200 >>"$EV/netfix-portal.log" 2>&1 \
  || fail "redeploy.sh failed during the portal-probe reboot -- see $EV/netfix-portal.log"
wait "$portal_waiter" 2>/dev/null || true
[[ -f "$portal_armed" ]] || fail "the portal HTTP endpoint never came up against vethrhz0 -- see $EV/netfix-portal.log"
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || fail "no init second_stage after the portal-probe reboot"
scope_nsenter_markers_to_boot
SS_PID_START=$(system_server_pid "$INIT")
android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "locksettings set-disabled true" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
if [[ "$FAILED" == "$STEP_MARK" ]]; then
  portal_seen=0 caps_reads=0
  deadline=$(( $(date +%s) + 240 ))
  while (( $(date +%s) < deadline )); do
    if caps=$(caps_now); then
      caps_reads=$(( caps_reads + 1 ))
      [[ "$caps" == *CAPTIVE_PORTAL* ]] && { portal_seen=1; break; }
    fi
    sleep 10
  done
  (( portal_seen )) || poll_never "$caps_reads" "dumpsys connectivity" \
    "the first validation never reported CAPTIVE_PORTAL against a portal serving 302"
  android_sh "$INIT" "dumpsys connectivity" > "$EV/dumpsys-connectivity-portal.txt"
  logcat_vm "$INIT" -b all -d 2>/dev/null | grep "isCaptivePortal:" | tail -2 > "$EV/portal-probes.txt"
  ../../vm/start/start-netfix.sh portal off >>"$EV/netfix-portal.log" 2>&1 \
    || fail "could not clear the captive portal before the portal-cleared reboot -- see $EV/netfix-portal.log"
  ../../vm/start/start-netserv.sh "$VETH_HOST_IP" "$TEST_HOST" >>"$EV/netfix-portal.log" 2>&1
  ../../vm/start/start-netbridge.sh --local-a "$TEST_HOST=$VETH_HOST_IP" \
                       --local-a "$PORTAL_PROBE=$VETH_HOST_IP" >>"$EV/netfix-portal.log" 2>&1
  cleared=0
  log "    rebooting with the portal gone, to validate a new network"
  android_sh "$INIT" "sync" >/dev/null 2>&1
  ssh_vm -t 20 "sync" >/dev/null 2>&1
  kill_vm
  boot_vm
  wait_for_boot_slot || fail "the portal-cleared reboot never got a qemu slot"
  wait_for_ssh 300 || fail "the vm did not come back after the portal-cleared reboot"
  ../../vm/start/start-sway.sh >>"$EV/netfix-portal.log" 2>&1
  RHIZO_GATE_EXTRA_INPUT_PORTS="tcp:80,tcp:8081,udp:5353" \
    RHIZO_NETBRIDGED_ARGS="--local-a,$TEST_HOST=$VETH_HOST_IP,--local-a,$PORTAL_PROBE=$VETH_HOST_IP" \
    ../../vm/redeploy.sh --skip-kill --boot-wait 200 >>"$EV/netfix-portal.log" 2>&1 \
    || fail "redeploy.sh failed during the portal-cleared reboot -- see $EV/netfix-portal.log"
  INIT=$(guest_init_pid 10)
  [[ -n "$INIT" ]] || fail "no init second_stage after the portal-cleared reboot"
  scope_nsenter_markers_to_boot
  ../../vm/start/start-netserv.sh "$VETH_HOST_IP" "$TEST_HOST" >>"$EV/netfix-portal.log" 2>&1
  SS_PID_START=$(system_server_pid "$INIT")
  android_sh "$INIT" "cmd battery set ac 1" >/dev/null
  android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
  android_sh "$INIT" "locksettings set-disabled true" >/dev/null
  android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
  expect_android_value "$INIT" "settings get global captive_portal_http_url" "$PORTAL_URL" \
    "the captive-portal probe URL did not survive the reboot (reads '@VALUE@')"
  (( $? == 97 )) || log "    probe URL this boot's NetworkMonitor read: ${ANDROID_VALUE:-<empty>}"
  caps_reads=0
  deadline=$(( $(date +%s) + 300 ))
  while (( $(date +%s) < deadline )); do
    if net_caps=$(caps_now); then
      caps_reads=$(( caps_reads + 1 ))
      if [[ "$net_caps" == *VALIDATED* && "$net_caps" != *CAPTIVE_PORTAL* ]]; then cleared=1; break; fi
    fi
    sleep 10
  done
  android_sh "$INIT" "dumpsys connectivity" > "$EV/dumpsys-connectivity-cleared.txt"
  logcat_vm "$INIT" -b all -d 2>/dev/null | grep -E "isCaptivePortal:|NetworkMonitor" | tail -10 > "$EV/cleared-probes.txt"
  (( cleared )) || poll_never "$caps_reads" "dumpsys connectivity" \
    "the network never reached VALIDATED after the portal was taken away"
  [[ "$FAILED" == "$STEP_MARK" ]] && pass "the framework's own probe saw the portal, and reaching VALIDATED once it went is the same transition step 5 asserts"
fi

../../vm/start/start-netfix.sh portal off >>"$EV/netfix-portal.log" 2>&1 \
  || fail "could not clear the captive portal -- see $EV/netfix-portal.log"
../../vm/start/start-netfix.sh portalserv down >>"$EV/netfix-portal.log" 2>&1
../../vm/start/start-netserv.sh "$VETH_HOST_IP" "$TEST_HOST" >>"$EV/netfix-portal.log" 2>&1
../../vm/start/start-netbridge.sh --local-a "$TEST_HOST=$VETH_HOST_IP" \
                     --local-a "$PORTAL_PROBE=$VETH_HOST_IP" >>"$EV/netfix-portal.log" 2>&1

step "2. regression baseline: launcher.sh + install.sh (this same live boot)"
if rig_earlier_pass install.sh inputs >"$EV/test-install-baseline.pass" 2>"$EV/test-install-baseline.reuse"; then
  reused=$(<"$EV/test-install-baseline.pass")
  printf 'reused: a full-run PASS for these inputs recorded at %s, evidence %s\n' \
    "${reused%%$'\t'*}" "${reused#*$'\t'}" > "$EV/test-install-baseline.log"
  pass "install.sh (and the launcher.sh it runs) passed on these inputs at ${reused%%$'\t'*}"
else
  if "$(system_test_file launcher.sh)" --skip-boot > "$EV/test-launcher-baseline.log" 2>&1; then
    pass "launcher.sh clean"
  else
    fail "launcher.sh FAILED against this boot -- see $EV/test-launcher-baseline.log"
    tail -20 "$EV/test-launcher-baseline.log"
  fi
  if "$(system_test_file install.sh)" --skip-boot > "$EV/test-install-baseline.log" 2>&1; then
    pass "install.sh clean (re-ran launcher.sh internally too)"
  else
    fail "install.sh FAILED against this boot -- see $EV/test-install-baseline.log"
    tail -20 "$EV/test-install-baseline.log"
  fi
fi
INIT_BEFORE_BASELINE="$INIT"
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage after the regression baseline"; exit 1; }
scope_nsenter_markers_to_boot
SS_PID_START=$(system_server_pid "$INIT")
if [[ "$INIT" != "$INIT_BEFORE_BASELINE" ]]; then
  log "    the baseline restarted the sandbox: init $INIT_BEFORE_BASELINE -> $INIT, system_server baseline now $SS_PID_START"
else
  log "    init unchanged across the baseline ($INIT), system_server baseline now $SS_PID_START"
fi
../../vm/start/start-netbridge.sh --local-a "$TEST_HOST=$VETH_HOST_IP" \
                     --local-a "$PORTAL_PROBE=$VETH_HOST_IP" >>"$EV/netfix-portal.log" 2>&1
log "    cleaning up prior system tests' displays"
before_n=$(rhizo_ctl_out "$INIT" | grep -c '^display list' || true)
rhizo_ctl "$INIT" display list >/dev/null
dlist=""
deadline=$(( $(date +%s) + 15 ))
while (( $(date +%s) < deadline )); do
  after_n=$(rhizo_ctl_out "$INIT" | grep -c '^display list' || true)
  if [[ "${after_n:-0}" -gt "${before_n:-0}" ]]; then
    dlist=$(rhizo_ctl_out "$INIT" | grep '^display list' | tail -1)
    break
  fi
  sleep 1
done
for did in $(grep -oE '[0-9]+\(' <<<"$dlist" | tr -d '('); do
  rhizo_ctl "$INIT" display remove "$did" >/dev/null 2>&1
done
log "    removed displays: $(grep -oE '[0-9]+\(' <<<"$dlist" | tr -d '(' | tr '\n' ' ')"

step "3. sandbox netns state"
IFACE_IP=""; GATEWAY_IP=""; addr_out=""; route_out=""; netns_reads=0
deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < deadline )); do
  if addr_now=$(android_observe "$INIT" "ip -4 addr show") \
     && route_now=$(android_observe "$INIT" "ip route show table all"); then
    netns_reads=$(( netns_reads + 1 ))
    addr_out="$addr_now" route_out="$route_now"
    IFACE_IP=$(echo "$addr_out" | awk '/inet /{print $2}' | grep -v '^127\.' | grep -vE '^169\.254\.' | head -1)
    GATEWAY_IP=$(echo "$route_out" | awk '/^default/{for(i=1;i<=NF;i++) if ($i=="via") print $(i+1)}' | head -1)
    [[ -n "$IFACE_IP" && -n "$GATEWAY_IP" ]] && break
  fi
  sleep 3
done
echo "$addr_out"  > "$EV/ip-addr.txt"
echo "$route_out" > "$EV/ip-route.txt"
if (( netns_reads == 0 )); then
  channel_dead "ip -4 addr show; ip route show table all"
else
  [[ -n "$IFACE_IP" ]] || fail "no non-loopback, non-link-local IPv4 address in the sandbox netns within 60s"
  [[ -n "$GATEWAY_IP" ]] || fail "no default route (any table) in the sandbox netns within 60s"
  log "    sandbox address=$IFACE_IP default-route-via=$GATEWAY_IP (expect $VETH_HOST_IP)"
  [[ "$GATEWAY_IP" == "$VETH_HOST_IP" ]] || fail "default route via $GATEWAY_IP does not match the veth host address $VETH_HOST_IP"
fi
if [[ "$FAILED" == 0 ]]; then pass "real interface/address/default route in the sandbox netns"; fi

step "4. native client: getaddrinfo() + raw HTTP GET from inside the sandbox"
../../vm/boot/adb-tunnel.sh up || fail "adb-tunnel.sh up failed"
timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$NATIVE_CLIENT" /data/local/tmp/rhizo-nettest \
  || fail "adb push of the native client failed"
android_sh "$INIT" "chmod 755 /data/local/tmp/rhizo-nettest" >/dev/null
out=$(android_observe "$INIT" "/data/local/tmp/rhizo-nettest $TEST_HOST 80 /nettest; echo RHIZO_NETTEST_EXIT=\$?")
native_observed=$?
native_rc=$(sed -n 's/^RHIZO_NETTEST_EXIT=//p' <<<"$out")
out=$(grep -v '^RHIZO_NETTEST_EXIT=' <<<"$out")
echo "$out" > "$EV/native-client.log"
if (( native_observed != 0 )); then
  channel_dead "/data/local/tmp/rhizo-nettest $TEST_HOST 80 /nettest"
else
  log "    native client output:"
  echo "$out" | sed 's/^/      /'
  resolved_ip=$(grep -oE 'RHIZO_NETTEST_RESOLVED ip=[0-9a-fA-F.:]+' <<<"$out" | head -1 | cut -d= -f2)
  resolved_family=$(grep -oE 'RHIZO_NETTEST_RESOLVED .* family=[a-z0-9]+' <<<"$out" | head -1 | sed 's/.*family=//')
  [[ -n "$resolved_ip" ]] || fail "no RHIZO_NETTEST_RESOLVED token"
  [[ "$resolved_ip" == "$VETH_HOST_IP" ]] || fail "resolved ip ($resolved_ip) != netserv answer ip ($VETH_HOST_IP)"
  [[ "$resolved_family" == "inet" ]] || fail "resolved family was '$resolved_family', expected inet for an A-only name"
  grep -qx "RHIZO_NETTEST_HTTP_STATUS 200" <<<"$out" || fail "HTTP status was not 200"
  grep -q "RHIZO_NETTEST_BODY .*RHIZO-NET-OK" <<<"$out" || fail "response body missing the RHIZO-NET-OK marker"
  grep -qx "RHIZO_NETTEST_OK" <<<"$out" || fail "no final RHIZO_NETTEST_OK token"
  [[ "$native_rc" == 0 ]] || fail "native client exit code ${native_rc:-<none>}"
fi
if [[ "$FAILED" == 0 ]]; then pass "real DNS resolution + real TCP/HTTP fetch via bionic getaddrinfo() (proof-test step 2)"; fi

step "5. framework connectivity state (dumpsys/cmd connectivity)"
android_sh "$INIT" "settings put global captive_portal_http_url http://$PORTAL_PROBE/generate_204" >/dev/null
android_sh "$INIT" "settings put global captive_portal_https_url http://$PORTAL_PROBE/generate_204" >/dev/null
android_sh "$INIT" "settings put global captive_portal_use_https 0" >/dev/null
android_sh "$INIT" "device_config put connectivity captive_portal_use_https 0" >/dev/null

conn=""
conn_reads=0
validated=0
triggered_bounce=0
deadline=$(( $(date +%s) + 90 ))
while (( $(date +%s) < deadline )); do
  if conn_now=$(android_observe "$INIT" "dumpsys connectivity"); then
    conn="$conn_now"
    conn_reads=$(( conn_reads + 1 ))
  fi
  while IFS= read -r caps; do
    if caps_have "$caps" VALIDATED && caps_have "$caps" INTERNET; then validated=1; break; fi
  done < <(network_caps "$conn")
  (( validated )) && break
  if (( $(date +%s) > deadline - 60 && triggered_bounce == 0 )); then
    log "    nudging ConnectivityService to re-probe (airplane-mode bounce)"
    android_sh "$INIT" "cmd connectivity airplane-mode enable" >/dev/null 2>&1
    sleep 2
    android_sh "$INIT" "cmd connectivity airplane-mode disable" >/dev/null 2>&1
    triggered_bounce=1
  fi
  sleep 3
done
echo "$conn" > "$EV/dumpsys-connectivity.txt"
if [[ "$validated" == 1 ]]; then
  dns_line=$(grep -m1 -i "DnsAddresses:" <<<"$conn")
  grep -q "$VETH_HOST_IP" <<<"$dns_line" || fail "DnsAddresses ('$dns_line') does not list our DNS server $VETH_HOST_IP"
  [[ "$FAILED" == 0 ]] && pass "framework reports an active, validated network with the right DNS server (proof-test step 2, framework-level)"
else
  poll_never "$conn_reads" "dumpsys connectivity" \
    "no VALIDATED network with INTERNET capability in dumpsys connectivity within 90s -- see $EV/dumpsys-connectivity.txt"
fi

step "6. is this machine's own egress reachable at all (system tests the public fetch in step 13)"
PUBLIC_URL="https://connectivitycheck.gstatic.com/generate_204"
PUBLIC_HOSTPORT="connectivitycheck.gstatic.com:443"
host_reach=$(ssh_vm -t 25 "https_proxy=$HOST_EGRESS_PROXY curl -s -o /dev/null -w '%{http_code}' --max-time 15 $PUBLIC_URL 2>/dev/null; echo \" RC=\$?\"")
echo "$host_reach" > "$EV/public-host-reachability.log"
PUBLIC_REACHABLE=0
if grep -qE "^204 RC=0" <<<"$host_reach"; then
  PUBLIC_REACHABLE=1
  log "    RHIZO_PUBLIC_REACHABLE host probe returned '$host_reach' -- step 13 WILL system test the sandbox's public fetch"
else
  log "    RHIZO_PUBLIC_SKIP_NO_HOST_EGRESS host probe returned '$host_reach' (wanted '204 RC=0') -- step 13's public fetch is NOT gated this run, and NOT counted as a pass"
fi

step "7. install $PKG"
timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$TESTAPK" /data/local/tmp/rhizo-nettest.apk \
  || fail "adb push of the test APK failed"
install_out=$(ANDROID_SH_TIMEOUT=180 android_observe "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/rhizo-nettest.apk"); install_rc=$?
echo "$install_out" > "$EV/pm-install.log"
if (( install_rc != 0 )); then
  channel_dead "pm install -r -t -g --user 0 /data/local/tmp/rhizo-nettest.apk"
else
  log "    pm install output: $install_out"
  grep -qx "Success" <<<"$install_out" || fail "pm install did not print a literal 'Success' line"
fi

step "8. launch + logcat token + pixel proof"
ssh_vm -t 45 "/usr/lib/rhizo/tools/rhizo-launch.sh $PKG $ACT" >/dev/null 2>&1
launch_line=""
deadline=$(( $(date +%s) + 15 ))
while (( $(date +%s) < deadline )); do
  launch_line=$(ssh_vm -t 10 "grep pkg=$PKG /run/rhizo-launch/rhizo-launch.log" 2>/dev/null | tail -1)
  [[ -n "$launch_line" ]] && break
  sleep 1
done
log "    launch log: $launch_line"
disp=$(grep -oE '(^|[[:space:]])display=[0-9]+' <<<"$launch_line" | cut -d= -f2)
cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$launch_line" | cut -d= -f2)
cdisp=${cdisp:-$disp}
[[ -n "$disp" ]] || fail "rhizo-launch.sh produced no display id for $PKG within 15s"

ACT_SHORT="${ACT#"$PKG"}"
resumed=""
resumed_reads=0
if [[ -n "$disp" ]]; then
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    if resumed_now=$(resumed_on "$INIT" "$disp"); then
      resumed="$resumed_now"
      resumed_reads=$(( resumed_reads + 1 ))
    fi
    [[ "$resumed" == "$PKG/$ACT" || "$resumed" == "$PKG/$ACT_SHORT" ]] && break
    sleep 1
  done
fi
if [[ "$resumed" != "$PKG/$ACT" && "$resumed" != "$PKG/$ACT_SHORT" ]]; then
  if [[ -n "$disp" ]] && (( resumed_reads == 0 )); then
    channel_dead "dumpsys activity activities"
  else
    fail "dumpsys shows '$resumed' resumed on display $disp, expected '$PKG/$ACT' (or short form '$PKG/$ACT_SHORT')"
  fi
fi

token_seen=0
deadline=$(( $(date +%s) + 20 ))
while (( $(date +%s) < deadline )); do
  lc=$(logcat_vm "$INIT" -d -s "RhizoNetTest:I" 2>/dev/null)
  if grep -q "RHIZO_NETTEST_APP_OK" <<<"$lc"; then
    token_seen=1; break
  fi
  sleep 1
done
[[ "$token_seen" == 1 ]] || fail "logcat never showed RHIZO_NETTEST_APP_OK"

read -r WX WY WW WH <<<"$(mapped_window_rect "$cdisp")"
log "    window rect: ${WX:-?},${WY:-?} ${WW:-?}x${WH:-?}"
if [[ -n "${WW:-}" ]]; then
  region="$WX,$WY,$WW,$WH"
  deadline=$(( $(date +%s) + 20 ))
  nb=0; dis=0
  while true; do
    shot /tmp/rhizo-test-network-frame.png >/dev/null && pull /tmp/rhizo-test-network-frame.png "$EV/frame.png"
    nb=$(python3 ../tools/pngstat.py "$EV/frame.png" --region "$region" | grep '^nonblack_pct=' | cut -d= -f2)
    dis=$(python3 ../tools/pngstat.py "$EV/frame.png" --region "$region" | grep '^distinct=' | cut -d= -f2)
    awk -v v="${nb:-0}" 'BEGIN{exit !(v>50)}' && [[ "${dis:-0}" -gt 20 ]] && break
    (( $(date +%s) < deadline )) || break
    sleep 1
  done
  log "    region $region: ${nb}% nonblack, $dis distinct colors"
  awk -v v="${nb:-0}" 'BEGIN{exit !(v>50)}' || fail "app window not showing real content (${nb}% nonblack)"
  [[ "${dis:-0}" -gt 20 ]] || fail "app window looks like a flat fill ($dis distinct colors)"
else
  fail "no window rect"
fi
if [[ "$FAILED" == 0 ]]; then
  pass "logcat token AND pixel proof both confirm the app fetched real content (proof-test step 3)"
fi

step "9. the product's own daemon served this network"
nb_log=$(ssh_vm -t 15 "cat /tmp/rhizo-netbridged.log" 2>/dev/null)
echo "$nb_log" > "$EV/netbridged.log"
grep -q "^\[netbridged\] NB_READY " <<<"$nb_log" \
  || fail "rhizo-netbridged never reported NB_READY"
nb_services=$(grep -m1 "NB_READY " <<<"$nb_log" | sed 's/.*services=//')
for svc in dhcp dns ra mdns proxy; do
  [[ ",$nb_services," == *",$svc,"* ]] || fail "rhizo-netbridged came up without its $svc service (services=$nb_services)"
done
sandbox_mac=""
if eth0=$(android_observe "$INIT" "ip addr show eth0"); then
  sandbox_mac=$(grep -oE 'link/ether [0-9a-f:]+' <<<"$eth0" | head -1 | awk '{print $2}')
  [[ -n "$sandbox_mac" ]] || fail "could not read the sandbox eth0 MAC"
else
  channel_dead "ip addr show eth0"
fi
leases=$(ssh_vm -t 15 "cat /run/rhizo-netbridged/leases.json" 2>/dev/null)
echo "$leases" > "$EV/netbridged-leases.json"
log "    daemon lease store: $leases"
if [[ -n "$sandbox_mac" ]]; then
  grep -q "$sandbox_mac" <<<"$leases" \
    || fail "the daemon holds no lease for the sandbox's own MAC $sandbox_mac"
fi
if conn9=$(android_observe "$INIT" "dumpsys connectivity"); then
  sandbox_dns=$(grep -m1 -oE 'DnsAddresses: \[ [^]]*\]' <<<"$conn9")
  log "    Android holds $sandbox_dns"
  grep -q "$VETH_HOST_IP" <<<"$sandbox_dns" \
    || fail "Android's resolver is '$sandbox_dns', not the veth host address the daemon hands out"
else
  channel_dead "dumpsys connectivity"
fi
netcfg_scan=$(ssh_vm -t 10 "grep -l DHCPServer /etc/systemd/network/*.network 2>/dev/null; echo NETCFG_SCANNED")
grep -q NETCFG_SCANNED <<<"$netcfg_scan" \
  || fail "could not scan this vm's networkd config for a second DHCP server"
if [[ -n "$(grep -v '^NETCFG_SCANNED$' <<<"$netcfg_scan" | tr -d '[:space:]')" ]]; then
  fail "a networkd DHCP server is still configured on this vm"
fi
[[ "$FAILED" == "$STEP_MARK" ]] && pass "the daemon served the lease, the router and the resolver, and nothing else did"

step "10. a host resolver change reaches the sandbox with nothing said to Android"
HOSTNAME_ONLY=host-resolver-only.internal
if ../../vm/start/start-netfix.sh upstreams up "$HOSTNAME_ONLY" >"$EV/netfix-upstreams.log" 2>&1; then
  ../tools/net-capture.sh start dnslive >/dev/null || fail "could not start the both-sides capture"
  resolved_via() {
    local ping
    ping=$(android_observe "$INIT" "ping -c1 -W3 $HOSTNAME_ONLY 2>&1 | head -1") || return 97
    grep -oE '\(([0-9.]+)\)' <<<"$ping" | head -1 | tr -d '()'
    return 0
  }
  hoststate_count() { ssh_vm -t 10 "grep -c NB_HOSTSTATE /tmp/rhizo-netbridged.log" | tr -d '[:space:]'; }
  seen=()
  for up in 127.0.0.2 127.0.0.3; do
    before=$(hoststate_count)
    ../../vm/start/start-netfix.sh resolver "$up" >>"$EV/netfix-upstreams.log" 2>&1 \
      || fail "could not point the host's resolver at $up"
    noticed=0
    deadline=$(( $(date +%s) + 20 ))
    while (( $(date +%s) < deadline )); do
      [[ "$(hoststate_count)" -gt "${before:-0}" ]] && { noticed=1; break; }
      sleep 1
    done
    (( noticed )) || fail "the daemon did not notice the host resolver becoming $up within 20s"
    sleep 3
    if got=$(resolved_via); then
      log "    host resolver $up -> sandbox resolves $HOSTNAME_ONLY to ${got:-<nothing>}"
      [[ "$got" == "$up" ]] || fail "with the host resolver at $up the sandbox answered '${got:-<nothing>}'"
    else
      got=""
      channel_dead "ping -c1 -W3 $HOSTNAME_ONLY"
    fi
    seen+=("$got")
  done
  ../../vm/start/start-netfix.sh resolver restore >>"$EV/netfix-upstreams.log" 2>&1 \
    || fail "could not restore the host's resolver configuration"
  ../tools/net-capture.sh stop dnslive >>"$EV/netfix-upstreams.log" 2>&1
  ../tools/net-capture.sh pull dnslive "$EV" >>"$EV/netfix-upstreams.log" 2>&1
  for side in sbx host; do
    answers=$(python3 ../tools/pcapstat.py "$EV/dnslive.$side.pcap" --dns 2>/dev/null \
              | grep "$HOSTNAME_ONLY" | grep -oE '"data": "[0-9.]+"' | sort -u | wc -l)
    (( answers >= 2 )) \
      || fail "the $side capture carries $answers distinct answers for $HOSTNAME_ONLY, expected both"
  done
  ../../vm/start/start-netfix.sh upstreams down >>"$EV/netfix-upstreams.log" 2>&1
  [[ "$FAILED" == "$STEP_MARK" ]] && pass "the same name answered ${seen[0]} then ${seen[1]}, both seen on both sides of the veth, with no reboot and nothing run inside Android"
else
  fail "could not stand up the two host resolvers -- see $EV/netfix-upstreams.log"
fi

# check Android's connect to the host's sshd is refused
closed_port_check() {
  local addr="$1" attempt out rc
  if ! ssh_vm -t 10 "timeout 3 bash -c '</dev/tcp/$addr/22'" >/dev/null 2>&1; then
    fail "the host's sshd does not answer on $addr:22 from the guest itself"
    return
  fi
  attempt="timeout 10 /data/local/tmp/rhizo-nettest $addr 22 /"
  if ! out=$(android_observe "$INIT" "$attempt; echo RHIZO_CLOSED_RC=\$?"); then
    channel_dead "$attempt"
    return
  fi
  rc=$(sed -n 's/^RHIZO_CLOSED_RC=\([0-9]*\)$/\1/p' <<<"$out" | tail -1)
  if ! grep -q "^RHIZO_NETTEST_RESOLVED ip=$addr " <<<"$out"; then
    fail "the probe of $addr:22 from Android never reached its connect (exit '${rc:-none}'): $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  elif [[ "$rc" == 124 ]] || [[ "$rc" == 1 && "$out" == *"RHIZO_NETTEST_FAIL connect "* ]]; then
    log "    the host's sshd at $addr:22, from Android: dropped or refused (exit $rc)"
  else
    fail "Android reached the host's sshd at $addr:22, a port no policy serves (exit '${rc:-none}'): $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  fi
}

step "11. IPv6: SLAAC address, AAAA, and a real TCP fetch over v6"
V6_NAME=v6only.internal
V6_ADDR=fd00:12ab:cd34::1
if ../../vm/start/start-netfix.sh v6origin up >"$EV/netfix-v6.log" 2>&1; then
  ../../vm/start/start-netbridge.sh --local-a "$TEST_HOST=$VETH_HOST_IP" \
                       --local-aaaa "$V6_NAME=$V6_ADDR" >>"$EV/netfix-v6.log" 2>&1 \
    || fail "could not restart the daemon with an AAAA name"
  v6_addr=""
  v6_reads=0
  deadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < deadline )); do
    if eth0_v6=$(android_observe "$INIT" "ip -6 addr show eth0"); then
      v6_reads=$(( v6_reads + 1 ))
      v6_addr=$(awk '/inet6 fd00:12ab:cd34:/ {print $2; exit}' <<<"$eth0_v6")
      [[ -n "$v6_addr" ]] && break
    fi
    sleep 3
  done
  [[ -n "$v6_addr" ]] || poll_never "$v6_reads" "ip -6 addr show eth0" \
    "the sandbox never acquired a global IPv6 address from the advertised prefix"
  log "    sandbox SLAAC address: ${v6_addr:-<none>}"
  rdnss_deadline=$(( $(date +%s) + 26 ))
  while (( $(date +%s) < rdnss_deadline )); do sleep 2; done
  ../tools/net-capture.sh start v6leg >/dev/null || fail "could not start the both-sides capture"
  v6_capture_start=$(date +%s)
  v6_out=$(android_observe "$INIT" "/data/local/tmp/rhizo-nettest $V6_NAME 80 /nettest"); v6_rc=$?
  echo "$v6_out" > "$EV/v6-client.log"
  if (( v6_rc != 0 )); then
    channel_dead "/data/local/tmp/rhizo-nettest $V6_NAME 80 /nettest"
  else
    log "    v6 client: $(tr '\n' ' ' <<<"$v6_out")"
    grep -q "RHIZO_NETTEST_RESOLVED ip=$V6_ADDR family=inet6" <<<"$v6_out" \
      || fail "the v6-only name did not resolve to $V6_ADDR over inet6"
    grep -qx "RHIZO_NETTEST_HTTP_STATUS 200" <<<"$v6_out" || fail "the fetch over IPv6 did not return 200"
    grep -q "RHIZO_NETTEST_BODY .*RHIZO-NET-OK" <<<"$v6_out" || fail "the IPv6 response body is missing its marker"
  fi
  while (( $(date +%s) - v6_capture_start < 26 )); do sleep 2; done
  ../tools/net-capture.sh stop v6leg >>"$EV/netfix-v6.log" 2>&1
  ../tools/net-capture.sh pull v6leg "$EV" >>"$EV/netfix-v6.log" 2>&1
  ra_rdnss=$(python3 ../tools/pcapstat.py "$EV/v6leg.sbx.pcap" --ra --json 2>/dev/null \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);print(sum(1 for r in d.get("ra",[]) if sys.argv[1] in r.get("rdnss",[])))' "$V6_ADDR" 2>/dev/null)
  log "    RAs on the wire carrying rdnss=$V6_ADDR: ${ra_rdnss:-0}"
  (( ${ra_rdnss:-0} > 0 )) \
    || fail "no router advertisement ON THE WIRE carried an RDNSS option for $V6_ADDR"
  for side in sbx host; do
    v6n=$(python3 ../tools/pcapstat.py "$EV/v6leg.$side.pcap" --summary --v6 2>/dev/null \
          | sed -n 's/^packets=//p')
    log "    $side capture: ${v6n:-0} IPv6 frames"
    (( ${v6n:-0} > 0 )) || fail "the $side capture holds no IPv6 frames"
  done
  closed_port_check "$VETH_HOST_IP"
  closed_port_check "$V6_ADDR"
  ../../vm/start/start-netfix.sh v6origin down >>"$EV/netfix-v6.log" 2>&1
  [[ "$FAILED" == "$STEP_MARK" ]] && pass "SLAAC address $v6_addr, AAAA answered, HTTP 200 over v6, IPv6 frames on both sides, and the host's sshd closed to Android over both families"
else
  fail "could not stand up the IPv6 origin -- see $EV/netfix-v6.log"
fi

# check a direct connection to the proxy-only origin is refused
proxy_origin_direct_check() {
  local origin="$1" probe out rc
  probe="timeout 10 /data/local/tmp/rhizo-nettest $origin 80 /proxytest"
  if ! out=$(android_observe "$INIT" "$probe; echo RHIZO_DIRECT_RC=\$?"); then
    channel_dead "$probe"
    return
  fi
  if grep -q "RHIZO_NETTEST_OK" <<<"$out"; then
    fail "the proxy-only origin answered a DIRECT connection"
    return
  fi
  rc=$(sed -n 's/^RHIZO_DIRECT_RC=\([0-9]*\)$/\1/p' <<<"$out" | tail -1)
  if ! grep -q "^RHIZO_NETTEST_RESOLVED ip=$origin " <<<"$out" \
     || ! [[ "$rc" == 124 || ( "$rc" == 1 && "$out" == *"RHIZO_NETTEST_FAIL connect "* ) ]]; then
    fail "the direct attempt at the proxy-only origin never showed a refused connection (exit '${rc:-none}'): $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
  fi
}

step "13. an app reaches a proxy-only origin, and follows the host's proxy when it changes"
PROXY_ORIGIN=10.88.0.2
if ../../vm/start/start-netfix.sh proxyorigin up >"$EV/netfix-proxy.log" 2>&1 \
   && ../../vm/start/start-netfix.sh proxyup 31281 first >>"$EV/netfix-proxy.log" 2>&1 \
   && ../../vm/start/start-netfix.sh proxyup 31282 second >>"$EV/netfix-proxy.log" 2>&1; then
  proxy_origin_direct_check "$PROXY_ORIGIN"
  ../tools/net-capture.sh start proxy >/dev/null || fail "could not start the both-sides capture"
  for pair in "31281:first" "31282:second"; do
    port="${pair%%:*}"; tag="${pair##*:}"
    before_up=$(ssh_vm -t 10 "grep -c 'NB_PROXY_UPSTREAM url=http://127.0.0.1:$port ' /tmp/rhizo-netbridged.log" | tr -d '[:space:]')
    ../../vm/start/start-netfix.sh hostproxy "http://127.0.0.1:$port" >>"$EV/netfix-proxy.log" 2>&1 \
      || fail "could not set the host's proxy to port $port"
    picked=0
    deadline=$(( $(date +%s) + 20 ))
    while (( $(date +%s) < deadline )); do
      now_up=$(ssh_vm -t 10 "grep -c 'NB_PROXY_UPSTREAM url=http://127.0.0.1:$port ' /tmp/rhizo-netbridged.log" | tr -d '[:space:]')
      (( ${now_up:-0} > ${before_up:-0} )) && { picked=1; break; }
      sleep 1
    done
    (( picked )) || fail "the daemon did not pick up the host's proxy on port $port within 20s (NB_PROXY_UPSTREAM count for it never rose above ${before_up:-0})"
    android_sh "$INIT" "settings delete global global_http_proxy_host" >/dev/null
    android_sh "$INIT" "settings delete global global_http_proxy_port" >/dev/null
    android_sh "$INIT" "settings put global http_proxy $VETH_HOST_IP:8118" >/dev/null
    sleep 3
    android_sh "$INIT" "am force-stop $PKG" >/dev/null
    ssh_vm -t 45 "/usr/lib/rhizo/tools/rhizo-launch.sh $PKG $ACT" >/dev/null 2>&1
    android_sh "$INIT" "am start -S -n $PKG/.MainActivity --es path /proxytest --es marker RHIZO-PROXY-OK --es host $PROXY_ORIGIN" >/dev/null 2>&1
    served=0; apptok=""
    deadline=$(( $(date +%s) + 40 ))
    while (( $(date +%s) < deadline )); do
      ssh_vm -t 10 "grep -c 'PROXYFIX_REQUEST tag=$tag .*target=http://$PROXY_ORIGIN/proxytest' /tmp/rhizo-proxyfix-$port.log" \
        | grep -qv '^0$' && served=1
      apptok=$(logcat_vm "$INIT" -d -s RhizoNetTest:I 2>/dev/null \
               | grep -E "RHIZO_NETTEST_APP_OK .*resolved=$PROXY_ORIGIN .*path=/proxytest" | tail -1)
      (( served )) && [[ -n "$apptok" ]] && break
      sleep 2
    done
    (( served )) || fail "the upstream proxy tagged $tag never saw a request for http://$PROXY_ORIGIN/proxytest after the host's proxy changed to it"
    [[ -n "$apptok" ]] || fail "the app never reported fetching the proxy-only origin through the relay"
    log "    app via proxy $tag: $apptok"
    ssh_vm -t 10 "grep -c 'NB_PROXY_REQUEST .* via=127.0.0.1:$port' /tmp/rhizo-netbridged.log" \
      | grep -qv '^0$' || fail "the sandbox-side relay never forwarded to the upstream on port $port"
  done
  ../../vm/start/start-netfix.sh hostproxy none >>"$EV/netfix-proxy.log" 2>&1 \
    || fail "could not clear the host's proxy"
  android_sh "$INIT" "settings put global http_proxy :0" >/dev/null
  sleep 3
  cleared_ok=0
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    before_req=$(ssh_vm -t 10 "grep -c NB_PROXY_REQUEST /tmp/rhizo-netbridged.log" | tr -d '[:space:]')
    logcat_vm "$INIT" -c >/dev/null 2>&1
    android_sh "$INIT" "am start -S -n $PKG/.MainActivity --es path /nettest" >/dev/null 2>&1
    sleep 6
    after_req=$(ssh_vm -t 10 "grep -c NB_PROXY_REQUEST /tmp/rhizo-netbridged.log" | tr -d '[:space:]')
    fetched=$(logcat_vm "$INIT" -d -s RhizoNetTest:I 2>/dev/null \
              | grep -cE "RHIZO_NETTEST_APP_OK .*path=/nettest")
    if (( ${fetched:-0} > 0 )) && [[ "${after_req:-0}" == "${before_req:-0}" ]]; then
      log "    app fetched directly ($fetched token(s)) and the relay count stayed at ${before_req:-0}"
      cleared_ok=1; break
    fi
    android_sh "$INIT" "settings put global http_proxy :0" >/dev/null
    sleep 4
  done
  (( cleared_ok )) || fail "an app still reaches the relay after the global proxy was cleared"
  ../tools/net-capture.sh stop proxy >>"$EV/netfix-proxy.log" 2>&1
  ../tools/net-capture.sh pull proxy "$EV" >>"$EV/netfix-proxy.log" 2>&1
  sbx_pkts=$(python3 ../tools/pcapstat.py "$EV/proxy.sbx.pcap" --summary 2>/dev/null | sed -n 's/^packets=//p')
  (( ${sbx_pkts:-0} > 0 )) \
    || fail "the sandbox-side capture for this leg holds no readable packets (${sbx_pkts:-<unreadable>})"
  direct_replies=$(python3 ../tools/pcapstat.py "$EV/proxy.sbx.pcap" --flows --host "$PROXY_ORIGIN" 2>/dev/null \
                   | grep -c "|$PROXY_ORIGIN:80|" || true)
  log "    sandbox capture: ${direct_replies:-0} flow(s) sourced from the origin"
  [[ "${direct_replies:-0}" == "0" ]] \
    || fail "the origin answered the sandbox directly in ${direct_replies} flow(s)"
  if (( PUBLIC_REACHABLE )); then
    ../../vm/start/start-netfix.sh hostproxy "$HOST_EGRESS_PROXY" >>"$EV/public-fetch.log" 2>&1 \
      || fail "could not point the host's proxy at this machine's own egress"
    pub_picked=0
    deadline=$(( $(date +%s) + 20 ))
    while (( $(date +%s) < deadline )); do
      ssh_vm -t 10 "grep -c 'NB_PROXY_UPSTREAM url=$HOST_EGRESS_PROXY' /tmp/rhizo-netbridged.log" \
        | grep -qv '^0$' && { pub_picked=1; break; }
      sleep 1
    done
    (( pub_picked )) || fail "the daemon never followed the host proxy to this machine's egress"
    android_sh "$INIT" "settings put global http_proxy $VETH_HOST_IP:8118" >/dev/null
    sleep 3
    android_sh "$INIT" "logcat -c" >/dev/null
    android_sh "$INIT" "am force-stop $PKG" >/dev/null 2>&1
    ssh_vm -t 45 "/usr/lib/rhizo/tools/rhizo-launch.sh $PKG $ACT" >/dev/null 2>&1
    android_sh "$INIT" "am start -S -n $PKG/.MainActivity --es url $PUBLIC_URL --es expect 204 --es marker NONE" >/dev/null 2>&1
    pub_tok=""
    deadline=$(( $(date +%s) + 90 ))
    while (( $(date +%s) < deadline )); do
      pub_tok=$(logcat_vm "$INIT" -d -s RhizoNetTest:I 2>/dev/null \
                | grep -E "RHIZO_NETTEST_APP_(OK|FAIL) .*target=$PUBLIC_URL" | tail -1)
      [[ -n "$pub_tok" ]] && break
      sleep 3
    done
    echo "$pub_tok" > "$EV/public-fetch-attempt.log"
    log "    sandbox public fetch: ${pub_tok:-<no token>}"
    grep -q "RHIZO_NETTEST_APP_OK " <<<"$pub_tok" \
      || fail "the host reaches $PUBLIC_URL through its proxy but the sandbox app does not"
    ssh_vm -t 10 "grep -c 'NB_PROXY_CONNECT target=$PUBLIC_HOSTPORT' /tmp/rhizo-netbridged.log" \
      | grep -qv '^0$' \
      || fail "the app reported success but the relay never opened a CONNECT to $PUBLIC_HOSTPORT"
    log "    the relay carried a real CONNECT to $PUBLIC_HOSTPORT for the app"
    android_sh "$INIT" "settings put global http_proxy :0" >/dev/null
    ../../vm/start/start-netfix.sh hostproxy none >>"$EV/public-fetch.log" 2>&1 \
      || fail "could not clear the host proxy after the public fetch"
  fi
  ../../vm/start/start-netfix.sh proxydown >>"$EV/netfix-proxy.log" 2>&1
  ../../vm/start/start-netfix.sh proxyorigin down >>"$EV/netfix-proxy.log" 2>&1
  [[ "$FAILED" == "$STEP_MARK" ]] && pass "both upstream proxies served in turn as the host's setting changed, and no direct flow to the origin exists"
else
  fail "could not stand up the proxy fixtures -- see $EV/netfix-proxy.log"
fi

step "14. an app discovers a LAN device by DNS-SD and connects to it"
if ../../vm/start/start-lanfix.sh >"$EV/lanfix.log" 2>&1 \
   && ../../vm/start/start-netbridge.sh --local-a "$TEST_HOST=$VETH_HOST_IP" \
        --mdns-uplink-if rhizolan0 >>"$EV/lanfix.log" 2>&1; then
  ../tools/net-capture.sh start mdns >/dev/null || fail "could not start the both-sides capture"
  nsd_marker=$(guest_log_marker "$INIT") || nsd_marker=""
  android_sh "$INIT" "logcat -c" >/dev/null
  android_sh "$INIT" "am force-stop $PKG" >/dev/null
  android_sh "$INIT" "am start -n $PKG/.MainActivity --es mode nsd" >/dev/null 2>&1
  nsd_out=""
  deadline=$(( $(date +%s) + 90 ))
  while (( $(date +%s) < deadline )); do
    nsd_out=$(logcat_vm "$INIT" -d -s RhizoNetTest:I 2>/dev/null | grep "RHIZO_NSD_")
    grep -qE "RHIZO_NSD_CONNECT |RHIZO_NSD_FAIL " <<<"$nsd_out" && break
    sleep 5
  done
  echo "$nsd_out" > "$EV/nsd.log"
  if grep -q "RHIZO_NSD_FOUND " <<<"$nsd_out"; then
    echo "<none: NsdManager found the service>" > "$EV/nsd-debug.txt"
  else
    { echo "== logcat since ${nsd_marker:-<no guest timestamp, last 500 lines>}"
      if [[ -n "$nsd_marker" ]]; then logcat_vm "$INIT" -d -t "$nsd_marker" 2>/dev/null
      else logcat_vm "$INIT" -d -t 500 2>/dev/null; fi | grep -iE "nsd|mdns|RhizoNetTest" | tail -200
      echo "== dumpsys servicediscovery"
      observe_or_note "$INIT" "dumpsys servicediscovery" | head -120
      echo "== eth0 link flags and multicast memberships"
      observe_or_note "$INIT" "ip -d link show eth0; ip maddr show dev eth0; cat /proc/net/igmp /proc/net/igmp6"
    } > "$EV/nsd-debug.txt" 2>&1
  fi
  grep -q "RHIZO_NSD_FOUND " <<<"$nsd_out" || fail "NsdManager never discovered the fixture's service"
  grep -q "RHIZO_NSD_RESOLVED " <<<"$nsd_out" || fail "the discovered service never resolved to a host and port"
  grep -q "RHIZO_NSD_CONNECT .*body=RHIZO-LAN-OK" <<<"$nsd_out" \
    || fail "the resolved address was not reachable, or did not return the fixture's marker"
  sleep 2
  ../tools/net-capture.sh stop mdns >>"$EV/lanfix.log" 2>&1
  ../tools/net-capture.sh pull mdns "$EV" >>"$EV/lanfix.log" 2>&1
  for side in sbx host; do
    q=$(python3 ../tools/pcapstat.py "$EV/mdns.$side.pcap" --mdns 2>/dev/null | grep -c "_rhizotest")
    log "    $side capture: $q mDNS records naming the service"
    (( q > 0 )) || fail "the $side capture holds no mDNS traffic for the service"
  done
  ssh_vm -t 10 "grep -c 'NB_MDNS_RELAY .*rhizotest' /tmp/rhizo-netbridged.log" | grep -qv '^0$' \
    || fail "the reflector never relayed a packet naming the service"
  ../../vm/start/start-lanfix.sh --down >>"$EV/lanfix.log" 2>&1
  [[ "$FAILED" == "$STEP_MARK" ]] && pass "discovered, resolved, connected, and the reflector carried it across both segments"
else
  fail "could not stand up the LAN fixture -- see $EV/lanfix.log"
fi

step "15. per-uid accounting matches what TWO apps each moved, cross-checked against the wire"
FIXTURE_PORT2=8081
TESTAPK2="$VAR_DIR/share/rhizo-nettest2.apk"
TESTAPK2_META="$VAR_DIR/share/rhizo-nettest2.json"
[[ -f "$TESTAPK2" && -f "$TESTAPK2_META" ]] \
  || fail "the second test app is missing -- build it with tools/build/test-apps/testapp.sh --package com.rhizo.nettest2 --out rhizo-nettest2"
PKG2=$(python3 -c "import json;print(json.load(open('$TESTAPK2_META'))['package'])")
ACT2=$(python3 -c "import json;print(json.load(open('$TESTAPK2_META'))['activity'])")
timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$TESTAPK2" /data/local/tmp/rhizo-nettest2.apk >/dev/null \
  || fail "adb push of the second test APK failed"
inst2=$(ANDROID_SH_TIMEOUT=180 android_observe "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/rhizo-nettest2.apk"); inst2_rc=$?
if (( inst2_rc != 0 )); then
  channel_dead "pm install -r -t -g --user 0 /data/local/tmp/rhizo-nettest2.apk"
else
  grep -qx "Success" <<<"$inst2" || fail "pm install of $PKG2 did not print Success: $inst2"
fi

# print a package's uid
uid_of() {
  local pkgs
  pkgs=$(android_observe "$INIT" "pm list packages -U $1") || return 97
  grep -oE 'uid:[0-9]+' <<<"$pkgs" | head -1 | cut -d: -f2
  return 0
}
if app_uid=$(uid_of "$PKG"); then
  [[ -n "$app_uid" ]] || fail "could not read $PKG's uid"
else
  channel_dead "pm list packages -U $PKG"
fi
if app_uid2=$(uid_of "$PKG2"); then
  [[ -n "$app_uid2" ]] || fail "could not read $PKG2's uid"
else
  channel_dead "pm list packages -U $PKG2"
fi
if [[ -n "$app_uid" && -n "$app_uid2" ]]; then
  [[ "$app_uid" != "$app_uid2" ]] \
    || fail "$PKG and $PKG2 share uid $app_uid"
fi
log "    $PKG uid=$app_uid, $PKG2 uid=$app_uid2"

# print the rx bytes netstats recorded for a uid
uid_rx() {
  local stats
  stats=$(android_observe "$INIT" "dumpsys netstats --uid") || return 97
  awk -v u="uid=$1 " '
        /ident=/ { f = (index($0, u) > 0); next }
        f && /rb=/ { line=$0; sub(/.*rb=/, "", line); sub(/ .*/, "", line); s += line }
        END { print s+0 }' <<<"$stats"
}
# return whether the port 80 fixture answers with its marker
serving()  { ssh_vm -t 8 "curl -sf http://$VETH_HOST_IP/nettest" 2>/dev/null | grep -q RHIZO-NET-OK; }
# return whether the second fixture port answers 200
serving2() { ssh_vm -t 8 "curl -sf -o /dev/null -w '%{http_code}' http://$VETH_HOST_IP:$FIXTURE_PORT2/throughput2" 2>/dev/null | grep -qx 200; }
if ! serving || ! serving2; then
  ../../vm/start/start-netserv.sh "$VETH_HOST_IP" "$TEST_HOST" >>"$EV/netstats.log" 2>&1
fi
deadline=$(( $(date +%s) + 30 ))
until serving && serving2; do
  (( $(date +%s) < deadline )) || { fail "the HTTP fixtures this leg measures against are not both serving (:80 and :$FIXTURE_PORT2)"; break; }
  sleep 2
done

# launch an app with extras and print its fetch token
run_fetch() {
  local pkg="$1" launchact="$2" amact="$3" match="$4"; shift 4
  local debug="$EV/fetch-debug-$pkg.txt" marker uid pkgs acts
  marker=$(guest_log_marker "$INIT") || marker=""
  android_sh "$INIT" "logcat -c" >/dev/null
  android_sh "$INIT" "am force-stop $pkg" >/dev/null
  ssh_vm -t 45 "/usr/lib/rhizo/tools/rhizo-launch.sh $pkg $launchact" >/dev/null 2>&1
  android_sh "$INIT" "am start -S -n $pkg/$amact $*" >/dev/null 2>&1
  { echo "== sandbox /proc/net/tcp and tcp6, 2s after am start"; sleep 2
    observe_or_note "$INIT" "cat /proc/net/tcp /proc/net/tcp6"
    echo "== 8s after am start"; sleep 6
    observe_or_note "$INIT" "cat /proc/net/tcp /proc/net/tcp6"; } > "$debug.sockets" 2>&1
  local tok="" dl=$(( $(date +%s) + 120 ))
  while (( $(date +%s) < dl )); do
    tok=$(logcat_vm "$INIT" -d -s RhizoNetTest:I 2>/dev/null \
          | grep -E "RHIZO_NETTEST_APP_(OK|FAIL) .*$match" | tail -1)
    [[ -n "$tok" ]] && break
    sleep 3
  done
  if [[ -n "$tok" ]]; then
    echo "<none: $pkg logged its token>" > "$debug"
  else
    uid=""
    pkgs=$(android_observe "$INIT" "pm list packages -U $pkg") \
      && uid=$(grep -oE 'uid:[0-9]+' <<<"$pkgs" | head -1 | cut -d: -f2)
    { echo "== $pkg uid=${uid:-<unread>}: no token matching $match"
      cat "$debug.sockets"
      echo "== logcat since ${marker:-<no guest timestamp, last 500 lines>}"
      if [[ -n "$marker" ]]; then logcat_vm "$INIT" -d -t "$marker" 2>/dev/null
      else logcat_vm "$INIT" -d -t 500 2>/dev/null; fi \
        | grep -E "$pkg|RhizoNetTest|ActivityTaskManager|ActivityManager|NetworkPolicy" | tail -200
      echo "== dumpsys activity activities naming $pkg"
      if acts=$(android_observe "$INIT" "dumpsys activity activities"); then
        grep -F "$pkg" <<<"$acts" | head -20
      else echo "<no channel ran: dumpsys activity activities>"; fi
      if [[ -n "$uid" ]]; then
        echo "== dumpsys netpolicy lines for uid $uid"
        observe_or_note "$INIT" "dumpsys netpolicy" | grep -E "UID=$uid |$uid-|no channel ran" | head -30
        echo "== trafficcontroller owner match for uid $uid"
        observe_or_note "$INIT" "dumpsys connectivity trafficcontroller" | grep -E "ownerMatch|^ *$uid |no channel ran" | head -10
      fi
    } > "$debug" 2>&1
  fi
  rm -f "$debug.sockets"
  printf '%s' "$tok"
}

nb_req_before=$(ssh_vm -t 10 "grep -c NB_PROXY_REQUEST /tmp/rhizo-netbridged.log" | tr -d '[:space:]')
../tools/net-capture.sh start netstats >/dev/null || fail "could not start the both-sides capture"
android_sh "$INIT" "dumpsys netstats --poll" >/dev/null
rx_observed=1
rx1_before=$(uid_rx "$app_uid") || rx_observed=0
rx2_before=$(uid_rx "$app_uid2") || rx_observed=0

tok1=$(run_fetch "$PKG"  "$ACT"  ".MainActivity" "target=http://$TEST_HOST:80/throughput" \
                 "--es path /throughput --es marker RHIZO-NET-THROUGHPUT") || tok1=""
log "    $PKG token: $tok1"
grep -q "RHIZO_NETTEST_APP_OK " <<<"$tok1" || fail "$PKG did not complete its fetch: ${tok1:-<no token>}"
tok2=$(run_fetch "$PKG2" "$ACT2" "$ACT2" "target=http://$TEST_HOST:$FIXTURE_PORT2/throughput2" \
                 "--es url http://$TEST_HOST:$FIXTURE_PORT2/throughput2 --es marker RHIZO-NET-THROUGHPUT2") || tok2=""
log "    $PKG2 token: $tok2"
grep -q "RHIZO_NETTEST_APP_OK " <<<"$tok2" || fail "$PKG2 did not complete its fetch: ${tok2:-<no token>}"

app1_bytes=$(grep -oE 'bytes=[0-9]+' <<<"$tok1" | cut -d= -f2)
app2_bytes=$(grep -oE 'bytes=[0-9]+' <<<"$tok2" | cut -d= -f2)
(( ${app1_bytes:-0} > 16000000 )) || fail "$PKG reported only ${app1_bytes:-0} bytes, expected the 32MiB endpoint"
(( ${app2_bytes:-0} > 4000000 ))  || fail "$PKG2 reported only ${app2_bytes:-0} bytes, expected the 8MiB endpoint"
(( app1_bytes > app2_bytes * 2 )) \
  || fail "the two apps moved $app1_bytes and $app2_bytes bytes -- too close to tell apart"

android_sh "$INIT" "dumpsys netstats --poll" >/dev/null
sleep 2
rx1_after=$(uid_rx "$app_uid") || rx_observed=0
rx2_after=$(uid_rx "$app_uid2") || rx_observed=0
d1=$(( ${rx1_after:-0} - ${rx1_before:-0} ))
d2=$(( ${rx2_after:-0} - ${rx2_before:-0} ))
if (( rx_observed )); then
  log "    uid $app_uid rx delta $d1 (app read $app1_bytes); uid $app_uid2 rx delta $d2 (app read $app2_bytes)"
else
  channel_dead "dumpsys netstats --uid"
fi

nb_req_after=$(ssh_vm -t 10 "grep -c NB_PROXY_REQUEST /tmp/rhizo-netbridged.log" | tr -d '[:space:]')
[[ "${nb_req_after:-0}" == "${nb_req_before:-0}" ]] \
  || fail "a fetch went through the relay"

if (( rx_observed )); then
  (( d1 >= app1_bytes )) || fail "the framework recorded $d1 bytes for uid $app_uid, less than the $app1_bytes $PKG read"
  (( d1 < app1_bytes * 2 )) || fail "the framework recorded $d1 bytes for uid $app_uid, more than twice what $PKG read"
  (( d2 >= app2_bytes )) || fail "the framework recorded $d2 bytes for uid $app_uid2, less than the $app2_bytes $PKG2 read"
  (( d2 < app2_bytes * 2 )) || fail "the framework recorded $d2 bytes for uid $app_uid2, more than twice what $PKG2 read"
  (( d1 > d2 * 2 )) \
    || fail "uid $app_uid recorded $d1 and uid $app_uid2 recorded $d2, want a 4:1 split"
fi

cap_stop=$(../tools/net-capture.sh stop netstats 2>&1); echo "$cap_stop" >>"$EV/netstats.log"
../tools/net-capture.sh pull netstats "$EV" >>"$EV/netstats.log" 2>&1
sbx_drops=$(sed -n 's/.*sbx_drops=\(-\?[0-9]*\).*/\1/p' <<<"$cap_stop" | tail -1)
[[ -n "$sbx_drops" && "$sbx_drops" != "-1" ]] \
  || fail "the capture did not report its kernel drop count (${sbx_drops:-<absent>})"
wire_all=$(python3 ../tools/pcapstat.py "$EV/netstats.sbx.pcap" --summary 2>/dev/null | sed -n 's/^packets=//p')
(( ${wire_all:-0} > 0 )) \
  || fail "the sandbox-side capture for this leg holds no readable packets (${wire_all:-<unreadable>})"
wire1=$(python3 ../tools/pcapstat.py "$EV/netstats.sbx.pcap" --summary --port 80 2>/dev/null | sed -n 's/^bytes=//p')
wire2=$(python3 ../tools/pcapstat.py "$EV/netstats.sbx.pcap" --summary --port $FIXTURE_PORT2 2>/dev/null | sed -n 's/^bytes=//p')
log "    wire: ${wire1:-0} bytes on :80, ${wire2:-0} bytes on :$FIXTURE_PORT2"
(( ${wire1:-0} > 1000000 )) \
  || fail "the veth capture holds only ${wire1:-0} bytes on :80 -- too little to corroborate $PKG's fetch"
(( ${wire2:-0} > 500000 )) \
  || fail "the veth capture holds only ${wire2:-0} bytes on :$FIXTURE_PORT2 -- too little to corroborate $PKG2's fetch"
(( ${wire1:-0} > ${wire2:-0} * 2 )) \
  || fail "the wire shows ${wire1:-0} on :80 and ${wire2:-0} on :$FIXTURE_PORT2, want a 4:1 split"
if (( sbx_drops == 0 )); then
  (( ${wire1:-0} >= app1_bytes )) \
    || fail "the capture dropped nothing yet holds ${wire1:-0} bytes on :80, less than the $app1_bytes $PKG read"
  (( ${wire2:-0} >= app2_bytes )) \
    || fail "the capture dropped nothing yet holds ${wire2:-0} bytes on :$FIXTURE_PORT2, less than the $app2_bytes $PKG2 read"
  log "    capture was lossless"
else
  log "    absolute wire/app totals NOT compared: the sniffer dropped $sbx_drops frame(s)"
fi
# print the data usage Total an app's screen shows
settings_total_bytes() {
  local pkg="$1"
  android_sh "$INIT" "am start -a android.settings.IGNORE_BACKGROUND_DATA_RESTRICTIONS_SETTINGS -d package:$pkg" >/dev/null 2>&1
  local dl=$(( $(date +%s) + 30 ))
  local top="" acts ui
  while (( $(date +%s) < dl )); do
    acts=$(android_observe "$INIT" "dumpsys activity activities") || return 97
    top=$(grep -m1 "topResumedActivity" <<<"$acts")
    [[ "$top" == *AppDataUsageActivity* ]] && break
    sleep 2
  done
  [[ "$top" == *AppDataUsageActivity* ]] \
    || { log "    $pkg: AppDataUsageActivity never became top ('${top:-<none>}')"; return 1; }
  android_sh "$INIT" "uiautomator dump /data/local/tmp/rhizo-ui.xml" >/dev/null 2>&1
  ui=$(android_observe "$INIT" "cat /data/local/tmp/rhizo-ui.xml") || return 97
  printf '%s\n' "$ui" > "$EV/settings-usage-$pkg.xml"
  python3 ../tools/uidump.py "$EV/settings-usage-$pkg.xml" --label Total --bytes 2>/dev/null
}
ui_observed=1
ui1=$(settings_total_bytes "$PKG"); (( $? == 97 )) && ui_observed=0
ui2=$(settings_total_bytes "$PKG2"); (( $? == 97 )) && ui_observed=0
log "    Settings' own screen shows: $PKG=${ui1:-<unreadable>} bytes, $PKG2=${ui2:-<unreadable>} bytes"
if (( ! ui_observed )); then
  channel_dead "dumpsys activity activities / cat /data/local/tmp/rhizo-ui.xml"
elif [[ -z "$ui1" || -z "$ui2" ]]; then
  fail "Settings' per-app data-usage screen did not render a readable Total for both apps ($PKG=${ui1:-<unreadable>}, $PKG2=${ui2:-<unreadable>})"
fi
if (( ui_observed )) && [[ -n "$ui1" && -n "$ui2" ]]; then
  (( ui1 > 0 )) \
    || fail "Settings shows 0 bytes for $PKG, which moved $app1_bytes"
  (( ui2 > 0 )) \
    || fail "Settings shows 0 bytes for $PKG2, which moved $app2_bytes"
  (( ui1 * 2 >= app1_bytes )) \
    || fail "Settings shows only $ui1 bytes for $PKG against the $app1_bytes it actually moved"
  (( ui1 > ui2 * 2 )) \
    || fail "Settings shows $ui1 for $PKG and $ui2 for $PKG2, want a 4:1 split"
fi

[[ "$FAILED" == "$STEP_MARK" ]] \
  && pass "two apps, two uids, two fixture ports: each uid's recorded bytes match its own app's fetch, the veth capture corroborates both, and Settings' own screen shows the same split"

step "16. a VpnService app establishes a tunnel over the host's routing"
VPNAPK="$VAR_DIR/share/rhizo-vpntest.apk"
VPNMETA="$VAR_DIR/share/rhizo-vpntest.json"
if [[ -f "$VPNAPK" && -f "$VPNMETA" ]]; then
  VPNPKG=$(python3 -c "import json;print(json.load(open('$VPNMETA'))['package'])")
  timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$VPNAPK" /data/local/tmp/rhizo-vpntest.apk >/dev/null \
    || fail "adb push of the VPN test APK failed"
  vpn_install=$(ANDROID_SH_TIMEOUT=180 android_observe "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/rhizo-vpntest.apk"); vpn_install_rc=$?
  if (( vpn_install_rc != 0 )); then
    channel_dead "pm install -r -t -g --user 0 /data/local/tmp/rhizo-vpntest.apk"
  else
    grep -qx "Success" <<<"$vpn_install" || fail "pm install of the VPN app did not print Success"
  fi
  android_sh "$INIT" "appops set $VPNPKG ACTIVATE_VPN allow" >/dev/null
  ../tools/net-capture.sh start vpn >/dev/null || fail "could not start the both-sides capture"
  android_sh "$INIT" "logcat -c" >/dev/null
  android_sh "$INIT" "am start -n $VPNPKG/.MainActivity" >/dev/null 2>&1
  vpn_tok=""
  deadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < deadline )); do
    vpn_tok=$(logcat_vm "$INIT" -d -s RhizoVpnTest:I 2>/dev/null | grep -E "RHIZO_VPN_(ESTABLISHED|ESTABLISH_FAILED|PREPARE_NEEDED)")
    [[ -n "$vpn_tok" ]] && break
    sleep 3
  done
  echo "$vpn_tok" > "$EV/vpn.log"
  log "    vpn token: $(tr '\n' ' ' <<<"$vpn_tok")"
  grep -q "RHIZO_VPN_PREPARE_NEEDED" <<<"$vpn_tok" \
    && fail "the VPN app still needs consent -- the ACTIVATE_VPN appop did not take"
  grep -q "RHIZO_VPN_ESTABLISHED " <<<"$vpn_tok" || fail "the VPN app never established its tunnel"
  if vpn_conn=$(android_observe "$INIT" "dumpsys connectivity"); then
    vpn_net=0
    while IFS= read -r caps; do
      caps_have "$caps" NOT_VPN || vpn_net=$(( vpn_net + 1 ))
    done < <(network_caps "$vpn_conn")
    (( ${vpn_net:-0} > 0 )) \
      || fail "no network without NET_CAPABILITY_NOT_VPN appears in dumpsys connectivity"
    log "    VPN networks (capability list lacking NOT_VPN): $vpn_net"
  else
    channel_dead "dumpsys connectivity"
  fi
  relay_before=$(logcat_vm "$INIT" -d -s RhizoVpnTest:I 2>/dev/null | grep -cE "RHIZO_VPN_RELAY ")
  relayed=""
  deadline=$(( $(date +%s) + 60 ))
  next_launch=0
  while (( $(date +%s) < deadline )); do
    if (( $(date +%s) >= next_launch )); then
      android_sh "$INIT" "am force-stop $PKG" >/dev/null
      android_sh "$INIT" "am start -n $PKG/.MainActivity" >/dev/null 2>&1
      next_launch=$(( $(date +%s) + 12 ))
    fi
    relay_now=$(logcat_vm "$INIT" -d -s RhizoVpnTest:I 2>/dev/null | grep -cE "RHIZO_VPN_RELAY ")
    if (( ${relay_now:-0} > ${relay_before:-0} )); then
      relayed=$(logcat_vm "$INIT" -d -s RhizoVpnTest:I 2>/dev/null | grep -E "RHIZO_VPN_RELAY " | tail -1)
      break
    fi
    sleep 3
  done
  [[ -n "$relayed" ]] \
    || fail "no NEW packet was relayed through the tunnel after $PKG started (count stayed at ${relay_before:-0})"
  log "    relayed: $relayed"
  sleep 2
  ../tools/net-capture.sh stop vpn >/dev/null 2>&1
  ../tools/net-capture.sh pull vpn "$EV" >/dev/null 2>&1
  vpn_pkts=$(python3 ../tools/pcapstat.py "$EV/vpn.sbx.pcap" --summary 2>/dev/null | sed -n 's/^packets=//p')
  (( ${vpn_pkts:-0} > 0 )) \
    || fail "the sandbox-side VPN capture holds no readable packets (${vpn_pkts:-<unreadable>})"
  vpn_leak=$(python3 ../tools/pcapstat.py "$EV/vpn.sbx.pcap" --flows 2>/dev/null | grep -c "10\.7\.0\.")
  (( ${vpn_leak:-0} == 0 )) \
    || fail "the tunnel's inner address 10.7.0.x appears in ${vpn_leak} flow(s) on the veth"
  vpn_relayed=$(python3 ../tools/pcapstat.py "$EV/vpn.sbx.pcap" --flows --port 53 2>/dev/null | grep -c "|$VETH_HOST_IP:53")
  (( ${vpn_relayed:-0} > 0 )) \
    || fail "no relayed DNS flow to $VETH_HOST_IP:53 appears on the veth capture"
  log "    vpn capture: $vpn_pkts packets, $vpn_relayed relayed DNS flow(s), $vpn_leak inner-address leak(s)"
  android_sh "$INIT" "am force-stop $VPNPKG" >/dev/null
  android_sh "$INIT" "appops set $VPNPKG ACTIVATE_VPN deny" >/dev/null
  [[ "$FAILED" == "$STEP_MARK" ]] && pass "tunnel established, a VPN network exists, and another app's traffic went through it"
else
  fail "the VPN test APK is missing -- run tools/build/test-apps/vpntestapp.sh"
fi

step "17. regression check"
SS_PID_END=$(system_server_pid "$INIT")
boot_end=$(getprop_live "$INIT" sys.boot_completed) || boot_end="<unreadable rc=$?>"
log "    system_server pid $SS_PID_START -> $SS_PID_END, sys.boot_completed=$boot_end"
[[ "$SS_PID_START" == "$SS_PID_END" ]] || fail "system_server restarted ($SS_PID_START -> $SS_PID_END)"
[[ "$boot_end" == "1" ]] || fail "sys.boot_completed is '$boot_end'"
if [[ -n "$TEST_SINCE" ]]; then
  logcat_vm "$INIT" -d -t "$TEST_SINCE" 2>/dev/null > "$EV/logcat-since-start.txt"
  test_logcat_capture_read "$EV/logcat-since-start.txt" \
    || fail "the fatal sweep read no logcat since '$TEST_SINCE'"
  bad=$(grep -cE "$TEST_FATAL_RE" "$EV/logcat-since-start.txt")
  log "    fatal/watchdog lines in logcat: $bad (crash events: $(test_crash_events "$EV/logcat-since-start.txt"))"
  [[ "$bad" == "0" ]] || {
    fail "logcat has $bad fatal/watchdog lines"
    test_fatal_lines "$EV/logcat-since-start.txt"
  }
else
  fail "no fatal-line sweep: step 0's guest clock read never ran"
fi

ssh_vm -t 10 "tail -80 /tmp/rhizo-netserv.log" > "$EV/netserv.log" 2>/dev/null || true

if (( FAILED )); then
  test_record_verdict FAILED
  log "NETWORK SYSTEM TEST FAILED"
  exit 1
fi
test_record_verdict PASSED
log "NETWORK SYSTEM TEST PASSED -- evidence in $EV"
