#!/bin/bash
# test rhizo device set value injection
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: no
# test-nests: -
# test-records-metrics: no
# test-requires: share:rhizo-devicereader.apk share:rhizo-devicereader.json
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh

[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
ADB=~/Android/Sdk/platform-tools/adb

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
SELFTEST=0
WITH_VDM=0
for arg in "$@"; do
  case "$arg" in
    --skip-boot) SKIP_BOOT=1 ;;
    --selftest) SELFTEST=1 ;;
    --with-vdm) WITH_VDM=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if (( SELFTEST )); then
  test_init device-injection --no-vm --evidence-root "$(test_evidence_dir device-injection)/selftest"
else
  test_init device-injection
fi

# write <none> to each evidence file
ev_none() {
  local f
  for f in "$@"; do printf '<none>\n' > "$EV/$f"; done
}
if (( SELFTEST )); then
  ev_none selftest-clean-0.log selftest-clean-1.log selftest-off-output.log \
          selftest-last-failures.log selftest-location-cases.log \
          selftest-ready-cases.log readiness.txt
else
  ev_none redeploy.log androidd-start.log pm-install.log \
          pids-before.txt pids-after.txt readiness.txt am-start.log \
          location-features.txt location-dumpsys.txt vm-restore.txt
fi

PKG=com.rhizo.devicereader
ACT=com.rhizo.devicereader.MainActivity
TAG=RhizoDeviceReader
APK="$VAR_DIR/share/rhizo-devicereader.apk"
test_require_staged rhizo-devicereader.apk rhizo-devicereader.json || exit 1

# remove files from the guest
vm_rm() {
  local f args=""
  for f in "$@"; do args+=" '$f'"; done
  ssh_vm -t 20 "rm -f$args" >/dev/null 2>&1
  return 0
}
# print PRESENT or ABSENT for guest paths
vm_probe() {
  local f body=""
  for f in "$@"; do body+="[ -e '$f' ] && { echo PRESENT; exit 0; }; "; done
  body+="echo ABSENT"
  ssh_vm -t 20 "$body" 2>/dev/null
}

# print the files rhizo device set creates
device_state_paths() {
  local d dirs=(/var/lib/rhizo/device-state)
  [[ -n "${RHIZO_DEVICE_STATE_DIR:-}" ]] && dirs+=("$RHIZO_DEVICE_STATE_DIR")
  for d in "${dirs[@]}"; do
    printf '%s\n' "$d/device-state.conf" "$d/sensor-accel.conf" "$d/sensor-gyro.conf" \
                  "$d/sensor-light.conf" "$d/camera.frame"
  done
}

# remove guest paths and record the read-back
_restore_paths() {
  local key="$1" where="$2"; shift 2
  local left
  vm_rm "$@"
  left=$(vm_probe "$@")
  left=${left//$'\r'/}
  left=${left##*$'\n'}
  [[ "$left" == PRESENT || "$left" == ABSENT ]] || left=UNREADABLE
  echo "where=$where $key=$left" >> "$EV/vm-restore.txt"
  log "  vm restore ($where): $key=$left"
  [[ "$left" == ABSENT ]]
}

POLICY_CONF_WRITTEN=0;  POLICY_CONF_RESTORED=0
DEVICE_STATE_WRITTEN=0;   DEVICE_STATE_RESTORED=0
FIXTURE_INSTALLED=0;    FIXTURE_RESTORED=0
CAMERA_FRAMES_STAGED=0; CAMERA_FRAMES_RESTORED=0

# remove /etc/rhizo/policy.conf
restore_policy_conf() {
  (( POLICY_CONF_WRITTEN )) || return 0
  (( POLICY_CONF_RESTORED )) && return 0
  _restore_paths policy_conf "$1" /etc/rhizo/policy.conf || return 1
  POLICY_CONF_RESTORED=1
}

# restore the device state files once, if this run wrote them
restore_device_state() {
  (( DEVICE_STATE_WRITTEN )) || return 0
  (( DEVICE_STATE_RESTORED )) && return 0
  local paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(device_state_paths)
  _restore_paths device_state "$1" "${paths[@]}" || return 1
  DEVICE_STATE_RESTORED=1
}

# uninstall the fixture app and remove its APK
restore_fixture() {
  (( FIXTURE_INSTALLED )) || return 0
  (( FIXTURE_RESTORED )) && return 0
  local path
  android_sh "$INIT" "pm uninstall --user 0 $PKG" >/dev/null 2>&1
  path=$(android_sh "$INIT" "pm path $PKG" 2>/dev/null)
  path=${path//$'\r'/}
  [[ "$path" == *"package:"* ]] && {
    echo "where=$1 fixture=STILL_INSTALLED ($path)" >> "$EV/vm-restore.txt"
    log "  vm restore ($1): fixture=STILL_INSTALLED"
    return 1
  }
  _restore_paths fixture "$1" /data/local/tmp/rhizo-devicereader.apk || return 1
  FIXTURE_RESTORED=1
}

# remove the staged camera test PNGs
restore_camera_frames() {
  (( CAMERA_FRAMES_STAGED )) || return 0
  (( CAMERA_FRAMES_RESTORED )) && return 0
  local left=ABSENT f
  rm -f "$SHARE_DIR/device-injection-test-dark.png" "$SHARE_DIR/device-injection-test-light.png"
  for f in "$SHARE_DIR/device-injection-test-dark.png" "$SHARE_DIR/device-injection-test-light.png"; do
    [[ -e "$f" ]] && left=PRESENT
  done
  echo "where=$1 camera_frames=$left" >> "$EV/vm-restore.txt"
  log "  vm restore ($1): camera_frames=$left"
  [[ "$left" == ABSENT ]] || return 1
  CAMERA_FRAMES_RESTORED=1
}

# remove leftover device state files
clear_device_state() {
  local paths=() p left
  while IFS= read -r p; do paths+=("$p"); done < <(device_state_paths)
  left=$(vm_probe "${paths[@]}")
  left=${left//$'\r'/}
  left=${left##*$'\n'}
  if [[ "$left" == PRESENT ]]; then
    log "  clearing leftover device state this vm carried in from an earlier run"
    vm_rm "${paths[@]}"
  fi
  echo "start-clear device_state=$left" >> "$EV/vm-restore.txt"
  return 0
}

VM_STATE=(
  "policy_conf|-|restore_policy_conf"
  "device_state|clear_device_state|restore_device_state"
  "fixture|-|restore_fixture"
  "camera_frames|-|restore_camera_frames"
)
EXPECT_VM_STATE=(policy_conf device_state fixture camera_frames)

# run the clear step of each vm state kind that has one
clear_leftover_vm_state() {
  local row key clear restore
  for row in "${VM_STATE[@]}"; do
    IFS='|' read -r key clear restore <<<"$row"
    [[ "$clear" == "-" ]] && continue
    "$clear"
  done
  return 0
}

# restore all kinds of vm state
restore_vm_state() {
  local where="$1" row key clear restore bad=0
  for row in "${VM_STATE[@]}"; do
    IFS='|' read -r key clear restore <<<"$row"
    "$restore" "$where" || bad=1
  done
  return $bad
}

# restore vm state at exit
cleanup_vm_state() {
  restore_vm_state exit-trap
  return 0
}
# shellcheck disable=SC2034
(( SELFTEST )) || TEST_EXTRA_CLEANUP=cleanup_vm_state

SELFTEST_TARGET=""
declare -A SELFTEST_WANT=()
# run rhizo device set on the guest
device_set() {
  local leg="$1" expected="$2"; shift 2
  if (( SELFTEST )); then
    SELFTEST_WANT["$leg"]="$expected"
    return 0
  fi
  local out
  DEVICE_STATE_WRITTEN=1
  out=$(ssh_vm -t 15 "rhizo device set $*" 2>&1)
  if (( $? != 0 )); then
    fail "$leg: 'rhizo device set $*' failed: $out"
    return 1
  fi
  return 0
}

# wait for the app to log the token
device_wait_token() {
  local leg="$1" regex="$2" marker="$3" deadline="${4:-60}"
  if (( SELFTEST )); then
    local sent="${SELFTEST_WANT[$leg]:-}"
    if [[ "$leg" == "$SELFTEST_TARGET" ]]; then
      sent=$(tr '0-9' '1234567890' <<<"$sent")
    fi
    local logs="09-17 00:00:00.000  1000  1000 I $TAG: $sent"
    POLL_READ=$(grep -aF "$regex" <<<"$logs" | tail -1)
    [[ -n "$POLL_READ" ]]
    return $?
  fi
  poll_until "$deadline" 2 _device_token_seen "$regex" "$marker"
}
# search logcat for the token
_device_token_seen() {
  local logs
  logs=$(logcat_vm "$INIT" -d -t "$2" -b all -s "$TAG:I")
  POLL_READ=$(grep -aF "$1" <<<"$logs" | tail -1)
  [[ -n "$POLL_READ" ]]
}
# poll a probe command
poll_until() {
  local deadline=$(( $(date +%s) + $1 )) nap="$2"
  shift 2
  POLL_READ=""
  while (( $(date +%s) < deadline )); do
    "$@" && return 0
    sleep "$nap"
  done
  return 1
}
# take a guest logcat time marker
device_marker() {
  (( SELFTEST )) && return 0
  MARKER=$(logcat_since_marker "$INIT")
  sleep 1
}

# set a value and check the app token
do_leg_change() {
  local leg="$1" expected="$2"; shift 2
  device_marker
  device_set "$leg" "$expected" "$@" || return 0
  if device_wait_token "$leg" "$expected" "${MARKER:-}" 60; then
    pass "$leg: $expected reached the app"
  else
    fail "$leg: no app token matched '$expected' within 60s (last seen: ${POLL_READ:-<none>})"
  fi
}

# print the pids of the app and HALs
device_pids() {
  (( SELFTEST )) && { echo "selftest"; return 0; }
  if (( WITH_VDM )); then
    android_sh "$INIT" \
      "echo app=\$(pidof $PKG) health=\$(pidof rhizo-health-service) thermal=\$(pidof rhizo-thermal-service) gnss=\$(pidof rhizo-gnss-service) virtualdevice=\$(pidof com.rhizo.virtualdevice)"
  else
    android_sh "$INIT" \
      "echo app=\$(pidof $PKG) health=\$(pidof rhizo-health-service) thermal=\$(pidof rhizo-thermal-service) gnss=\$(pidof rhizo-gnss-service)"
  fi
}

PROBE_STATE=""
PROBE_RAW=""
INIT=""

# classify an android_sh read
_probe_state() {
  local rc="$1" raw="$2" needle="$3"
  if (( rc == 97 || rc == 98 )) || [[ -z "$raw" ]]; then
    echo unreachable
    return 0
  fi
  [[ "$raw" == *"Can't find service"* ]] && { echo not-yet; return 0; }
  [[ "$raw" == *"$needle"* ]] && { echo ready; return 0; }
  echo not-yet
}

# print the state for a boot_completed value
_boot_state() {
  [[ "$1" == 1 ]] && echo ready || echo not-yet
}

# poll a probe and record the outcome
await_ready() {
  local label="$1" budget="$2" probe="$3"
  local deadline=$(( $(date +%s) + budget )) t0 polls=0 unreachable=0 last=""
  t0=$(date +%s)
  while :; do
    PROBE_STATE=""; PROBE_RAW=""
    "$probe"
    polls=$(( polls + 1 ))
    last="$PROBE_RAW"
    [[ "$PROBE_STATE" == unreachable ]] && unreachable=$(( unreachable + 1 ))
    if [[ "$PROBE_STATE" == ready ]]; then
      echo "READY  $label after $(( $(date +%s) - t0 ))s, $polls poll(s): $last" >> "$EV/readiness.txt"
      log "  ready: $label ($(( $(date +%s) - t0 ))s, $polls poll(s))"
      return 0
    fi
    (( $(date +%s) < deadline )) || break
    sleep 2
  done
  echo "TIMEOUT $label after ${budget}s, $polls poll(s), $unreachable unreachable: $last" >> "$EV/readiness.txt"
  if (( unreachable == polls )); then
    fail "$label: the guest never answered within ${budget}s -- all $polls probe(s) came back unreachable (last read: ${last:-<none>})"
  else
    fail "$label: not ready within ${budget}s ($unreachable of $polls probe(s) unreachable, last read: ${last:-<none>})"
  fi
  return 1
}

# find the sandbox init pid and set INIT
probe_init_pid() {
  local raw rc
  raw=$(_ssh_vm_out 15 'for p in $('"$RHIZO_INIT_SCAN_BODY"'); do
      [ "$(cat /proc/$p/comm 2>/dev/null)" = init ] || continue
      [ "$(awk "/^NSpid:/{if (NF>=3 && \$NF!=1) print \"foreign\"}" /proc/$p/status 2>/dev/null)" = foreign ] && continue
      echo $p; break
    done'); rc=$?
  raw=${raw//[[:space:]]/}
  PROBE_RAW="init second_stage pid='$raw' ssh rc=$rc"
  if (( rc != 0 )); then PROBE_STATE=unreachable; return 0; fi
  if [[ -n "$raw" ]]; then INIT="$raw"; PROBE_STATE=ready; else PROBE_STATE=not-yet; fi
}

ENFORCE_WANT=1
[[ -n "${RHIZO_PERMISSIVE:-}" && "${RHIZO_PERMISSIVE}" != 0 ]] && ENFORCE_WANT=0
# check whether /sys/fs/selinux/enforce reads the wanted value
probe_enforcing() {
  local raw rc
  raw=$(_ssh_vm_out 10 'cat /sys/fs/selinux/enforce'); rc=$?
  raw=${raw//[[:space:]]/}
  PROBE_RAW="/sys/fs/selinux/enforce='$raw' (want '$ENFORCE_WANT') ssh rc=$rc"
  if (( rc != 0 )) || [[ -z "$raw" ]]; then PROBE_STATE=unreachable; return 0; fi
  [[ "$raw" == "$ENFORCE_WANT" ]] && PROBE_STATE=ready || PROBE_STATE=not-yet
}

# read sys.boot_completed from the guest
probe_boot_completed() {
  local raw
  raw=$(getprop_live "$INIT" sys.boot_completed) || raw="<unreadable rc=$?>"
  raw=${raw//[[:space:]]/}
  PROBE_RAW="sys.boot_completed='$raw'"
  PROBE_STATE=$(_boot_state "$raw")
}

# run cmd package path in the guest
probe_package_service() {
  local raw rc
  raw=$(android_sh "$INIT" "cmd package path android"); rc=$?
  PROBE_RAW="cmd package path android -> rc=$rc '${raw//$'\n'/ | }'"
  PROBE_STATE=$(_probe_state "$rc" "$raw" "package:")
}

# run dumpsys activity activities in the guest
probe_activity_service() {
  local raw rc
  raw=$(android_sh "$INIT" "dumpsys activity activities"); rc=$?
  PROBE_RAW="dumpsys activity activities -> rc=$rc, ${#raw} bytes"
  PROBE_STATE=$(_probe_state "$rc" "$raw" "ACTIVITY MANAGER ACTIVITIES")
}

# look for the fixture in the activity stack
probe_fixture_started() {
  local raw rc st
  raw=$(android_sh "$INIT" "dumpsys activity activities"); rc=$?
  PROBE_RAW="dumpsys activity activities -> rc=$rc, ${#raw} bytes, $PKG/ present=$([[ "$raw" == *"$PKG/"* ]] && echo yes || echo no)"
  st=$(_probe_state "$rc" "$raw" "ACTIVITY MANAGER ACTIVITIES")
  [[ "$st" == ready ]] || { PROBE_STATE="$st"; return 0; }
  [[ "$raw" == *"$PKG/"* ]] && PROBE_STATE=ready || PROBE_STATE=not-yet
}

READINESS_WAITS=(
  "SELinux enforcement on the guest|300|probe_enforcing"
  "sys.boot_completed (pm install's own predicate)|600|probe_boot_completed"
  "the package service answering a real request|120|probe_package_service"
  "the activity service answering a real request|120|probe_activity_service"
)
EXPECT_READINESS_PROBES=(probe_enforcing probe_boot_completed probe_package_service probe_activity_service)
# wait for each readiness probe in turn
await_all_ready() {
  local row label budget probe
  for row in "${READINESS_WAITS[@]}"; do
    IFS='|' read -r label budget probe <<<"$row"
    await_ready "$label" "$budget" "$probe" || return 1
  done
  return 0
}

SELFTEST_LOCATION=(0 "feature:android.hardware.location.gps" 0 "    gps provider:" "true")

# print the location precondition verdict
_location_verdict() {
  local rc="$1" features="$2" prc="$3" providers="$4" enabled="$5"
  if (( rc != 0 )) || [[ -z "$features" ]] || (( prc != 0 )) || [[ -z "$providers" ]]; then
    echo unreadable
    return 0
  fi
  grep -qaxF 'feature:android.hardware.location.gps' <<<"$features" || {
    echo not-declared
    return 0
  }
  [[ "$providers" == *"Can't find service"* ]] && { echo unreadable; return 0; }
  grep -qa 'gps provider' <<<"$providers" || {
    echo no-provider
    return 0
  }
  [[ "$enabled" == true ]] || {
    echo disabled
    return 0
  }
  echo ok
}

# assert the gps provider exists
assert_location_available() {
  local features providers enabled declared summary gnss_pid verdict rc prc
  if (( SELFTEST )); then
    rc=${SELFTEST_LOCATION[0]}; features=${SELFTEST_LOCATION[1]}
    prc=${SELFTEST_LOCATION[2]}; providers=${SELFTEST_LOCATION[3]}
    enabled=${SELFTEST_LOCATION[4]}; gnss_pid=selftest
  else
    features=$(android_sh "$INIT" "pm list features")
    rc=$?
    providers=$(android_sh "$INIT" "dumpsys location")
    prc=$?
    enabled=$(android_sh "$INIT" "cmd location is-location-enabled")
    gnss_pid=$(android_sh "$INIT" "pidof rhizo-gnss-service")
    features=${features//$'\r'/}
    providers=${providers//$'\r'/}
    enabled=${enabled//$'\r'/}; enabled=${enabled##*$'\n'}
    gnss_pid=${gnss_pid//$'\r'/}; gnss_pid=${gnss_pid##*$'\n'}
  fi
  [[ -n "$gnss_pid" ]] || gnss_pid="<none>"
  declared=$(grep -aiE '^feature:.*location' <<<"$features" | sort)
  summary=$(tr '\n' ' ' <<<"$declared")
  summary="${summary% }"
  [[ -n "${summary// }" ]] || summary="<none>"
  verdict=$(_location_verdict "$rc" "$features" "$prc" "$providers" "$enabled")
  {
    echo "# android_sh rc: pm list features=$rc, dumpsys location=$prc"
    echo "# pm list features, filtered to location"
    echo "${declared:-<none>}"
    echo "# cmd location is-location-enabled"
    echo "${enabled:-<none>}"
    echo "# pidof rhizo-gnss-service"
    echo "$gnss_pid"
    echo "# _location_verdict"
    echo "$verdict"
  } > "$EV/location-features.txt"
  echo "${providers:-<none>}" > "$EV/location-dumpsys.txt"
  case "$verdict" in
    unreadable)
      fail "location precondition unreadable: the guest answered nothing (pm list features rc=$rc bytes=${#features}, dumpsys location rc=$prc bytes=${#providers})"
      return 1 ;;
    not-declared)
      fail "location feature not declared: pm list features carries no 'feature:android.hardware.location.gps' (location features present: $summary)"
      return 1 ;;
    no-provider)
      fail "no gps provider: the location feature IS declared but dumpsys location shows LocationManagerService built no gps provider (rhizo-gnss-service pid=$gnss_pid, full read: $EV/location-dumpsys.txt)"
      return 1 ;;
    disabled)
      fail "location is disabled: 'cmd location is-location-enabled' read '${enabled:-<none>}', wanted 'true'"
      return 1 ;;
  esac
  pass "location available: android.hardware.location.gps declared, a gps provider exists and location is enabled"
}

# write a solid gray PNG file
write_test_png() {
  python3 - "$1" "$2" <<'EOF'
import struct, sys, zlib
path, gray = sys.argv[1], int(sys.argv[2])
w = h = 32
def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data)))
sig = b"\x89PNG\r\n\x1a\n"
ihdr = chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
row = bytes([0]) + bytes([gray]) * w
idat = chunk(b"IDAT", zlib.compress(row * h, 9))
iend = chunk(b"IEND", b"")
with open(path, "wb") as f:
    f.write(sig + ihdr + idat + iend)
EOF
}

# run all injection legs
run_all_legs() {
  step "1. battery: level and charging state, then a live change"
  do_leg_change battery "RHIZO_DEVICE_BATTERY level=42 charging=discharging" battery 42 discharging
  do_leg_change battery "RHIZO_DEVICE_BATTERY level=10 charging=charging" battery 10 charging

  step "2. thermal: skin temperature severity, then a live change"
  do_leg_change thermal "RHIZO_DEVICE_THERMAL status=1" thermal 31
  do_leg_change thermal "RHIZO_DEVICE_THERMAL status=5" thermal 35

  step "3. gps: the location feature, then a fix, then a live change"
  assert_location_available
  do_leg_change gps "RHIZO_DEVICE_GPS lat=37.7749 lon=-122.4194" gps 37.7749 -122.4194
  do_leg_change gps "RHIZO_DEVICE_GPS lat=51.5074 lon=-0.1278" gps 51.5074 -0.1278

  step "4. network proxy (delegated)"
  skip "network proxy: proven by server.sh's own DNAT check"

  if (( ! WITH_VDM )); then
    step "5. sensor/camera (devices.virtual, off by default)"
    if (( SELFTEST )); then
      skip "devices.virtual is off -- pass --with-vdm against a boot with it on to assert these"
    else
      local report pid staged
      report=$(android_sh "$INIT" "echo pid=\$(pidof com.rhizo.virtualdevice); [ -e /product/priv-app/RhizoVirtualDevice/RhizoVirtualDevice.apk ] && echo staged=yes || echo staged=no")
      pid=$(grep -oE 'pid=[0-9]*' <<<"$report" | cut -d= -f2)
      staged=$(grep -oE 'staged=(yes|no)' <<<"$report" | cut -d= -f2)
      if [[ -z "$pid" && "$staged" == no ]]; then
        pass "devices.virtual is off: RhizoVirtualDevice is neither staged nor running (report: $report)"
      else
        fail "devices.virtual is off but the virtual device app is staged or running -- expected neither (report: $report)"
      fi
    fi
    return 0
  fi

  step "5. sensor: accel (vector) and light (scalar), then a live change"
  do_leg_change sensor_accel "RHIZO_DEVICE_SENSOR_ACCEL x=1.5 y=2.5 z=9.8" sensor accel 1.5 2.5 9.8
  do_leg_change sensor_accel "RHIZO_DEVICE_SENSOR_ACCEL x=3.5 y=4.5 z=-9.8" sensor accel 3.5 4.5 -9.8
  do_leg_change sensor_light "RHIZO_DEVICE_SENSOR_LIGHT lux=400.0" sensor light 400
  do_leg_change sensor_light "RHIZO_DEVICE_SENSOR_LIGHT lux=750.0" sensor light 750

  step "6. camera: a solid test frame, then a live change"
  if (( SELFTEST )); then
    do_leg_change camera "RHIZO_DEVICE_CAMERA brightness=0" camera "<selftest: no real file>"
    do_leg_change camera "RHIZO_DEVICE_CAMERA brightness=1" camera "<selftest: no real file>"
  else
    guest_mount_share || { fail "camera leg: guest_mount_share failed, cannot stage a test frame"; return 0; }
    local dark_png="$SHARE_DIR/device-injection-test-dark.png" \
          light_png="$SHARE_DIR/device-injection-test-light.png"
    CAMERA_FRAMES_STAGED=1
    write_test_png "$dark_png" 64 || { fail "camera leg: write_test_png (dark) failed"; return 0; }
    write_test_png "$light_png" 255 || { fail "camera leg: write_test_png (light) failed"; return 0; }
    do_leg_change camera "RHIZO_DEVICE_CAMERA brightness=0" camera "/root/share/device-injection-test-dark.png"
    do_leg_change camera "RHIZO_DEVICE_CAMERA brightness=1" camera "/root/share/device-injection-test-light.png"
    rm -f "$dark_png" "$light_png"
  fi
}

# print the leg names from ok lines
leg_set_from_log() {
  grep -oE 'ok: [a-z_]+:' "$1" | sed -E 's/^ok: ([a-z_]+):$/\1/' | sort -u
}

# test _location_verdict against a case table
selftest_location_cases() {
  local bad=0 want rc features prc providers enabled got n=0
  while IFS='|' read -r want rc features prc providers enabled; do
    [[ -n "$want" ]] || continue
    got=$(_location_verdict "$rc" "$(printf '%b' "$features")" "$prc" \
                            "$(printf '%b' "$providers")" "$enabled")
    n=$((n+1))
    [[ "$got" == "$want" ]] && continue
    echo "SELFTEST FAILURE: _location_verdict(pm-rc=$rc dumpsys-rc=$prc enabled='$enabled') answered '$got', wanted '$want'" >&2
    bad=1
  done <<'CASES'
unreadable|98|feature:android.hardware.location.gps|0|    gps provider:|true
unreadable|0||0|    gps provider:|true
unreadable|0|feature:android.hardware.location.gps|97|    gps provider:|true
unreadable|0|feature:android.hardware.location.gps|0||true
not-declared|0|feature:android.hardware.audio.output\nfeature:android.hardware.location|0|    gps provider:|true
not-declared|0|feature:android.hardware.location.gps_extra|0|    gps provider:|true
unreadable|0|feature:android.hardware.location.gps|0|Can't find service: location|true
no-provider|0|feature:android.hardware.location.gps|0|Location Providers:\n    network provider:\n    fused provider:|true
disabled|0|feature:android.hardware.location.gps|0|    gps provider:|false
disabled|0|feature:android.hardware.location.gps|0|    gps provider:|cmd: Can't find service: location
ok|0|feature:android.hardware.location\nfeature:android.hardware.location.gps|0|Location Providers:\n    gps provider:\n    network provider:|true
CASES
  echo "selftest_location_cases: $n case(s)"
  return $bad
}

# test the vm state restore and clear
selftest_vm_state_cases() {
  local bad=0 n=0 got want row key clear restore out tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/device-vm-selftest.XXXXXX") || return 1

  got=$(device_state_paths | sort | tr '\n' ' ')
  want="/var/lib/rhizo/device-state/camera.frame /var/lib/rhizo/device-state/device-state.conf /var/lib/rhizo/device-state/sensor-accel.conf /var/lib/rhizo/device-state/sensor-gyro.conf /var/lib/rhizo/device-state/sensor-light.conf "
  n=$(( n + 1 ))
  [[ "$got" == "$want" ]] \
    || { echo "SELFTEST FAILURE: device_state_paths returns [$got], wanted [$want]" >&2; bad=1; }
  got=$(RHIZO_DEVICE_STATE_DIR=/srv/alt device_state_paths | grep -c '^/srv/alt/')
  n=$(( n + 1 ))
  [[ "$got" == 5 ]] \
    || { echo "SELFTEST FAILURE: an overridden RHIZO_DEVICE_STATE_DIR contributes $got paths, wanted 5" >&2; bad=1; }

  got=""
  for row in "${VM_STATE[@]}"; do
    IFS='|' read -r key clear restore <<<"$row"
    got+="$key "
    n=$(( n + 1 ))
    declare -F "$restore" >/dev/null \
      || { echo "SELFTEST FAILURE: vm state '$key' names restore '$restore', which this script does not define" >&2; bad=1; }
    [[ "$clear" == "-" ]] || declare -F "$clear" >/dev/null \
      || { echo "SELFTEST FAILURE: vm state '$key' names clear '$clear', which this script does not define" >&2; bad=1; }
  done
  n=$(( n + 1 ))
  [[ "${got% }" == "${EXPECT_VM_STATE[*]}" ]] \
    || { echo "SELFTEST FAILURE: the system test undoes [${got% }] but this script expects [${EXPECT_VM_STATE[*]}]" >&2; bad=1; }
  got=""
  for row in "${VM_STATE[@]}"; do
    IFS='|' read -r key clear restore <<<"$row"
    [[ "$key" == device_state ]] && got="$clear"
  done
  n=$(( n + 1 ))
  [[ -n "$got" && "$got" != "-" ]] \
    || { echo "SELFTEST FAILURE: device_state has no start-clear" >&2; bad=1; }

  _vm_drive() {
    local answer="$1" fn="$2" where="${3:-inline}" pmpath="${4:-}"
    (
      EV="$tmp"; : > "$tmp/vm-restore.txt"; : > "$tmp/rm.log"
      POLICY_CONF_WRITTEN=1; DEVICE_STATE_WRITTEN=1; FIXTURE_INSTALLED=1
      CAMERA_FRAMES_STAGED=0
      vm_rm() { printf '%s\n' "$@" >> "$tmp/rm.log"; return 0; }
      vm_probe() { printf '%s\n' "$answer"; }
      android_sh() { [[ -n "$pmpath" ]] && printf '%s\n' "$pmpath"; return 0; }
      log() { :; }
      "$fn" "$where" >/dev/null 2>&1
      echo "rc=$?"
      echo "RM:$(sort -u "$tmp/rm.log" | tr '\n' ' ')"
      echo "EV:$(tr '\n' ' ' < "$tmp/vm-restore.txt")"
    )
  }
  _expect() {
    local label="$1" text="$2"; shift 2
    local needle
    for needle in "$@"; do
      n=$(( n + 1 ))
      [[ "$text" == *"$needle"* ]] && continue
      echo "SELFTEST FAILURE: $label did not carry '$needle' -- got: ${text//$'\n'/ }" >&2
      bad=1
    done
  }

  out=$(_vm_drive ABSENT restore_vm_state)
  _expect "a restore whose read-back says ABSENT" "$out" \
    "rc=0" "/etc/rhizo/policy.conf" "/var/lib/rhizo/device-state/device-state.conf" \
    "/var/lib/rhizo/device-state/sensor-accel.conf" "/var/lib/rhizo/device-state/sensor-gyro.conf" \
    "/var/lib/rhizo/device-state/sensor-light.conf" "/var/lib/rhizo/device-state/camera.frame" \
    "/data/local/tmp/rhizo-devicereader.apk" \
    "policy_conf=ABSENT" "device_state=ABSENT" "fixture=ABSENT"

  out=$(_vm_drive PRESENT restore_vm_state)
  _expect "a restore whose read-back still says PRESENT" "$out" "rc=1" "device_state=PRESENT" "policy_conf=PRESENT"

  out=$(_vm_drive "" restore_vm_state)
  _expect "a restore the guest never answered" "$out" "rc=1" "device_state=UNREADABLE"

  out=$(_vm_drive ABSENT restore_vm_state inline "package:/data/app/~~x==/com.rhizo.devicereader-1/base.apk")
  _expect "a restore whose fixture is still installed" "$out" "rc=1" "fixture=STILL_INSTALLED"

  out=$(_vm_drive PRESENT clear_leftover_vm_state)
  _expect "the start-clear on a vm carrying leftover device state" "$out" \
    "start-clear device_state=PRESENT" "/var/lib/rhizo/device-state/device-state.conf" \
    "/var/lib/rhizo/device-state/camera.frame"
  n=$(( n + 1 ))
  [[ "$out" == *"/etc/rhizo/policy.conf"* ]] \
    && { echo "SELFTEST FAILURE: the start-clear removed /etc/rhizo/policy.conf, which it does not own" >&2; bad=1; }

  out=$(_vm_drive ABSENT clear_leftover_vm_state)
  _expect "the start-clear on an already-clean vm" "$out" "start-clear device_state=ABSENT"
  n=$(( n + 1 ))
  [[ "$out" == *"RM: "$'\n'* || "$out" == *"RM:"$'\n'* ]] \
    || { echo "SELFTEST FAILURE: the start-clear removed something on a vm that had nothing to clear -- got: ${out//$'\n'/ }" >&2; bad=1; }

  rm -rf "$tmp"
  echo "selftest_vm_state_cases: $n case(s)"
  return $bad
}

# check _probe_state and _boot_state on fixtures
selftest_ready_cases() {
  local bad=0 want rc raw needle got n=0 pair
  while IFS='|' read -r want rc raw needle; do
    [[ -n "$want" ]] || continue
    got=$(_probe_state "$rc" "$(printf '%b' "$raw")" "$needle")
    n=$(( n + 1 ))
    [[ "$got" == "$want" ]] && continue
    echo "SELFTEST FAILURE: _probe_state(rc=$rc raw='$raw' needle='$needle') answered '$got', wanted '$want'" >&2
    bad=1
  done <<'CASES'
unreachable|97|package:/system/framework/framework-res.apk|package:
unreachable|98|package:/system/framework/framework-res.apk|package:
unreachable|0||package:
not-yet|0|Can't find service: package|package:
not-yet|0|Can't find service: package|package
not-yet|0|Error: device is still booting.|package:
ready|0|package:/system/framework/framework-res.apk|package:
not-yet|0|Can't find service: activity|ACTIVITY MANAGER ACTIVITIES
ready|0|ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)\n  Display #0|ACTIVITY MANAGER ACTIVITIES
CASES
  for pair in "1:ready" "0:not-yet" ":not-yet" "11:not-yet" "true:not-yet"; do
    got=$(_boot_state "${pair%%:*}")
    n=$(( n + 1 ))
    [[ "$got" == "${pair##*:}" ]] && continue
    echo "SELFTEST FAILURE: _boot_state('${pair%%:*}') answered '$got', wanted '${pair##*:}'" >&2
    bad=1
  done
  echo "selftest_ready_cases: $n case(s)"
  return $bad
}

# check the readiness wait table
selftest_readiness_table() {
  local bad=0 row label budget probe got="" want p
  want="${EXPECT_READINESS_PROBES[*]}"
  for row in "${READINESS_WAITS[@]}"; do
    IFS='|' read -r label budget probe <<<"$row"
    got+="$probe "
    [[ -n "$label" ]] || { echo "SELFTEST FAILURE: a readiness wait carries no label: '$row'" >&2; bad=1; }
    [[ "$budget" =~ ^[1-9][0-9]*$ ]] \
      || { echo "SELFTEST FAILURE: readiness wait '$label' has deadline '$budget', not a positive number" >&2; bad=1; }
    declare -F "$probe" >/dev/null \
      || { echo "SELFTEST FAILURE: readiness wait '$label' names probe '$probe', which this script does not define" >&2; bad=1; }
  done
  [[ "${got% }" == "$want" ]] \
    || { echo "SELFTEST FAILURE: step 0b waits on [${got% }] but this script expects [$want]" >&2; bad=1; }
  for p in probe_init_pid probe_fixture_started; do
    declare -F "$p" >/dev/null \
      || { echo "SELFTEST FAILURE: $p is no longer defined" >&2; bad=1; }
  done
  echo "selftest_readiness_table: ${#READINESS_WAITS[@]} wait(s), $want"
  return $bad
}

# check await_ready on fixture probes
selftest_await_cases() {
  local bad=0 before rc line
  _sa_ready()       { PROBE_RAW="fixture"; PROBE_STATE=ready; }
  _sa_notyet()      { PROBE_RAW="fixture"; PROBE_STATE=not-yet; }
  _sa_unreachable() { PROBE_RAW="fixture"; PROBE_STATE=unreachable; }

  before=$FAILED; : > "$EV/failures.log"
  await_ready "selftest: a probe that is ready" 0 _sa_ready; rc=$?
  (( rc == 0 && FAILED == before )) \
    || { echo "SELFTEST FAILURE: await_ready on a ready probe returned rc=$rc and booked $(( FAILED - before )) failure(s)" >&2; bad=1; }
  FAILED=$before

  before=$FAILED; : > "$EV/failures.log"
  await_ready "selftest: a probe that never becomes ready" 0 _sa_notyet; rc=$?
  line=$(tr '\n' ' ' < "$EV/failures.log")
  { (( rc != 0 && FAILED == before + 1 )) \
      && [[ "$line" == *"not ready within 0s"* && "$line" != *"unreachable guest"* ]]; } \
    || { echo "SELFTEST FAILURE: await_ready on a never-ready probe: rc=$rc, $(( FAILED - before )) failure(s), log: $line" >&2; bad=1; }
  FAILED=$before

  before=$FAILED; : > "$EV/failures.log"
  await_ready "selftest: a probe the guest never answers" 0 _sa_unreachable; rc=$?
  line=$(tr '\n' ' ' < "$EV/failures.log")
  { (( rc != 0 && FAILED == before + 1 )) \
      && [[ "$line" == *"unreachable guest and not a slow boot"* ]]; } \
    || { echo "SELFTEST FAILURE: await_ready on an unreachable probe: rc=$rc, $(( FAILED - before )) failure(s), log: $line" >&2; bad=1; }
  FAILED=$before
  : > "$EV/failures.log"
  return $bad
}

if (( SELFTEST )); then
  selftest_location_cases > "$EV/selftest-location-cases.log" 2>&1 || {
    echo "SELFTEST FAILURE: _location_verdict does not answer its own fixture table -- see $EV/selftest-location-cases.log" >&2
    exit 1
  }
  cat "$EV/selftest-location-cases.log"

  { selftest_ready_cases && selftest_await_cases && selftest_readiness_table \
      && selftest_vm_state_cases; } > "$EV/selftest-ready-cases.log" 2>&1 || {
    echo "SELFTEST FAILURE: the readiness classifiers or await_ready do not answer their own fixtures -- see $EV/selftest-ready-cases.log" >&2
    cat "$EV/selftest-ready-cases.log" >&2
    exit 1
  }
  cat "$EV/selftest-ready-cases.log"

  for WITH_VDM in 0 1; do
    if (( WITH_VDM )); then
      EXPECT_LEGS=(battery thermal gps sensor_accel sensor_light camera)
    else
      EXPECT_LEGS=(battery thermal gps)
    fi
    SELFTEST_TARGET=""
    before=$FAILED
    : > "$EV/failures.log"
    run_all_legs >"$EV/selftest-clean-$WITH_VDM.log" 2>&1
    clean_got=$(( FAILED - before ))
    FAILED=$before
    (( clean_got == 0 )) || {
      echo "SELFTEST FAILURE: an UNCORRUPTED with-vdm=$WITH_VDM pass produced $clean_got failure(s) -- see $EV/selftest-clean-$WITH_VDM.log and $EV/failures.log" >&2
      exit 1
    }
    grep -q "ok: location available:" "$EV/selftest-clean-$WITH_VDM.log" || {
      echo "SELFTEST FAILURE: with-vdm=$WITH_VDM ran no location precondition -- see $EV/selftest-clean-$WITH_VDM.log" >&2
      exit 1
    }
    got_legs=$(leg_set_from_log "$EV/selftest-clean-$WITH_VDM.log")
    want_legs=$(printf '%s\n' "${EXPECT_LEGS[@]}" | sort -u)
    [[ "$got_legs" == "$want_legs" ]] || {
      echo "SELFTEST FAILURE: with-vdm=$WITH_VDM actually exercised leg set [$got_legs] but this script expects [$want_legs]" >&2
      exit 1
    }
    for SELFTEST_TARGET in "${EXPECT_LEGS[@]}"; do
      step "selftest: with-vdm=$WITH_VDM leg '$SELFTEST_TARGET' corrupted"
      before=$FAILED
      : > "$EV/failures.log"
      run_all_legs
      got=$(( FAILED - before ))
      own=$(grep -cE "FAIL: ${SELFTEST_TARGET}: " "$EV/failures.log")
      bad_sibling=0
      for sib in "${EXPECT_LEGS[@]}"; do
        [[ "$sib" == "$SELFTEST_TARGET" ]] && continue
        grep -qE "FAIL: ${sib}: " "$EV/failures.log" && bad_sibling=1
      done
      if (( got == 2 && own == 2 && bad_sibling == 0 )); then
        log "  ok: corrupting '$SELFTEST_TARGET' (with-vdm=$WITH_VDM) failed exactly its own two named assertions, no others"
      else
        cp "$EV/failures.log" "$EV/selftest-last-failures.log"
        echo "SELFTEST FAILURE: corrupting '$SELFTEST_TARGET' (with-vdm=$WITH_VDM) produced $got total failures (${own} named '$SELFTEST_TARGET', sibling-named=$bad_sibling), wanted 2/2/0 -- see $EV/selftest-last-failures.log" >&2
        exit 1
      fi
      FAILED=$before
    done
  done
  WITH_VDM=0
  SELFTEST_TARGET=""
  before=$FAILED
  : > "$EV/failures.log"
  run_all_legs >"$EV/selftest-off-output.log" 2>&1
  off_got=$(( FAILED - before ))
  FAILED=$before
  (( off_got == 0 )) || { echo "SELFTEST FAILURE: with-vdm=0's own off-posture assertion failed -- see $EV/selftest-off-output.log" >&2; exit 1; }
  grep -q "NOT RUN: devices.virtual is off" "$EV/selftest-off-output.log" \
    || { echo "SELFTEST FAILURE: with-vdm=0 did not skip the sensor/camera step through skip()'s own NOT RUN: marker -- see $EV/selftest-off-output.log" >&2; exit 1; }
  echo "SELFTEST OK: every leg's own corruption is caught BY NAME under both postures, the exercised leg set matches expectations, an uncorrupted pass produces zero failures, and the off posture names its own skip through skip()'s real marker" >&2
  : > "$EV/failures.log"
  test_record_verdict PASSED "selftest=legs+vdm"
  exit 0
fi

if (( SKIP_BOOT == 0 )); then
  step "0. boot the guest and Android under profile=server"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --no-launch >"$EV/redeploy.log" 2>&1 \
    || { fail "redeploy.sh failed (see $EV/redeploy.log)"; exit 1; }
  POLICY_CONF_WRITTEN=1
  ssh_vm -t 60 "printf '[rhizo]\nprofile = server\n' > /etc/rhizo/policy.conf" \
    || { fail "could not write /etc/rhizo/policy.conf on the guest"; exit 1; }
  PROFILE_READ=$(ssh_vm -t 20 "sed -n 's/^profile = //p' /etc/rhizo/policy.conf" | tr -d '\r')
  [[ "$PROFILE_READ" == server ]] \
    || { fail "policy.conf reads profile='$PROFILE_READ', wanted server"; exit 1; }
  ssh_vm -t 600 'systemctl start androidd.service' >"$EV/androidd-start.log" 2>&1 \
    || { fail "systemctl start androidd.service failed (see $EV/androidd-start.log)"; exit 1; }
  tail -4 "$EV/redeploy.log"
fi
await_ready "the sandbox's own init second_stage pid" 300 probe_init_pid \
  || { test_record_verdict FAILED; exit 1; }

step "0b. wait for the capabilities step 0a needs, each on its own condition"
await_all_ready || { test_record_verdict FAILED; exit 1; }

step "0c. clear any vm state an earlier run left behind"
clear_leftover_vm_state

step "0a. install and launch the read-back fixture"
../../vm/boot/adb-tunnel.sh up || fail "adb-tunnel.sh up failed"
if [[ "$FAILED" == 0 ]]; then
  FIXTURE_INSTALLED=1
  timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$APK" /data/local/tmp/rhizo-devicereader.apk \
    || fail "adb push of the fixture APK failed"
fi
if [[ "$FAILED" == 0 ]]; then
  install_out=$(android_sh "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/rhizo-devicereader.apk"); install_rc=$?
  echo "rc=$install_rc"$'\n'"$install_out" > "$EV/pm-install.log"
  if (( install_rc == 97 || install_rc == 98 )) || [[ -z "$install_out" ]]; then
    fail "pm install got no answer from the guest at all (android_sh rc=$install_rc)"
  else
    grep -qx "Success" <<<"$install_out" || fail "pm install did not print a literal 'Success' line: $install_out"
  fi
fi
if [[ "$FAILED" == 0 ]]; then
  am_out=$(android_sh "$INIT" "am start -n $PKG/$ACT"); am_rc=$?
  echo "rc=$am_rc"$'\n'"$am_out" > "$EV/am-start.log"
  if (( am_rc != 0 )) || ! grep -qa '^Starting: Intent' <<<"$am_out" \
     || grep -qa '^Error:' <<<"$am_out"; then
    fail "am start -n $PKG/$ACT was refused (rc=$am_rc): ${am_out//$'\n'/ | }"
  fi
fi
if [[ "$FAILED" == 0 ]]; then
  await_ready "$PKG in the activity stack after am start" 60 probe_fixture_started
fi
if [[ "$FAILED" == 0 ]]; then pass "fixture installed and launched"; fi

# reject a pid snapshot with an empty field
device_pids_complete() {
  local label="$1" snapshot="$2"
  (( SELFTEST )) && return 0
  [[ -n "$snapshot" ]] || { fail "$label pid snapshot is empty"; return 1; }
  if grep -qE '=([[:space:]]|$)' <<<"$snapshot"; then
    fail "$label pid snapshot has an empty field: $snapshot"
    return 1
  fi
  return 0
}

if [[ "$FAILED" == 0 ]]; then
  PIDS_BEFORE=$(device_pids)
  echo "$PIDS_BEFORE" > "$EV/pids-before.txt"
  device_pids_complete before "$PIDS_BEFORE"
  run_all_legs
  PIDS_AFTER=$(device_pids)
  echo "$PIDS_AFTER" > "$EV/pids-after.txt"
  device_pids_complete after "$PIDS_AFTER"
  [[ "$PIDS_BEFORE" == "$PIDS_AFTER" ]] \
    || fail "the fixture app and/or a HAL restarted during the run: before='$PIDS_BEFORE' after='$PIDS_AFTER'"
fi

step "7. restore the vm: undo every kind of state this run wrote"
if restore_vm_state inline; then
  pass "vm restored: policy.conf, the device-state bridge files, the fixture and any staged camera frames all read back ABSENT"
else
  fail "could not restore the vm: at least one kind of state this run wrote is still PRESENT (or unreadable) after removal (see $EV/vm-restore.txt)"
fi

if [[ "$FAILED" == 0 ]]; then
  test_record_verdict PASSED
  log "DEVICE-INJECTION SYSTEM TEST PASSED"
else
  test_record_verdict FAILED
  log "DEVICE-INJECTION SYSTEM TEST FAILED"
fi
exit "$FAILED"
