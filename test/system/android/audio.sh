#!/bin/bash
# test per-app audio through PipeWire
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: shared
# test-boots-unit: no
# test-nests: display.sh,network.sh
# test-records-metrics: no
# test-requires: share:rhizo-audiotest-a.apk share:rhizo-audiotest-b.apk share:RhizoAudioRouter.apk share:rhizo-audiod file:gfx_hal/rhizo-audio-core-service vm-dir:pipewire-debs
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh

[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }
ADB=~/Android/Sdk/platform-tools/adb

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
RUN_REGRESSION=1
for arg in "$@"; do
  case "$arg" in
    --skip-boot) SKIP_BOOT=1 ;;
    --no-regression) RUN_REGRESSION=0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done
# print the verdict parameters
verdict_params() {
  (( RUN_REGRESSION )) || printf 'regression=0'
}

test_init audio

PKG_A=com.rhizo.audiotest.a
PKG_B=com.rhizo.audiotest.b
ACT=com.rhizo.audiotest.MainActivity
HZ_A=440
HZ_B=880
BUS_A=""
BUS_B=""

for f in "$VAR_DIR/share/rhizo-audiotest-a.apk" "$VAR_DIR/share/rhizo-audiotest-b.apk" \
         "$VAR_DIR/share/RhizoAudioRouter.apk" "$VAR_DIR/share/rhizo-audiod" \
         "$VAR_DIR/share/gfx_hal/rhizo-audio-core-service"; do
  [[ -f "$f" ]] || { fail "missing $f"; exit 1; }
done
test_require_staged rhizo-audiotest-a.apk rhizo-audiotest-b.apk RhizoAudioRouter.apk rhizo-audiod || exit 1

PW_AS_DESKTOP='u=$(tr -d "[:space:]" 2>/dev/null < /etc/rhizo/desktop-user); u=${u:-ubuntu}; runuser -u "$u" -- env XDG_RUNTIME_DIR=/run/user/$(id -u "$u")'

# record a PipeWire output monitor
pw_capture() {
  ssh_vm -t $(( $2 + 20 )) "$PW_AS_DESKTOP \
    timeout $2 pw-record --target=$1 -P '{ stream.capture.sink=true }' \
      --rate 48000 --channels 2 --format s16 $3; \
    rc=\$?; case \$rc in 124) exit 0 ;; 0) exit 90 ;; *) exit \$rc ;; esac"
}

# print the id of a PipeWire node
pw_node_id() {
  ssh_vm -t 15 "$PW_AS_DESKTOP pw-dump" 2>/dev/null | python3 -c "
import json,sys
want=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
for o in d:
    p=((o.get('info') or {}).get('props') or {})
    if p.get('node.name')==want: print(o['id']); break
" "$1"
}

# print a property of a PipeWire node
pw_node_prop() {
  python3 -c "
import json,sys
path, want, key = sys.argv[1], sys.argv[2], sys.argv[3]
try: d=json.load(open(path))
except Exception: sys.exit(0)
for o in d:
    p=((o.get('info') or {}).get('props') or {})
    if p.get('node.name')==want: print(p.get(key,'')); break
" "$1" "$2" "$3"
}

# print a value from wavstat output
wavstat_get() {
  local wav="$1" key="$2" out; shift 2
  out=$(python3 "$REPO/test/system/tools/wavstat.py" "$wav" "$@" 2>&1) || return 1
  awk -v k="$key" '$1==k {print $2}' <<<"$out"
}

# print the I/O handle of a bus output
bus_output_handle() {
  awk -v want="@:$2}" '
    /I\/O handle: [0-9]+;/ { h = $0; sub(/.*I\/O handle: /, "", h); sub(/;.*/, "", h); next }
    /^ *Devices: / { if (h != "" && index($0, want)) { print h; exit } h = "" }' "$1"
}

# print frames and active tracks of a thread
bus_thread_state() {
  awk -v h="$2" -v u="$3" '
    /^[A-Za-z]+ thread 0x/ { mine = 0; table = 0 }
    /^  I\/O handle: / { mine = ($3 == h); if (mine) found = 1 }
    mine && /^  Output devices: .*AUDIO_DEVICE_OUT_BUS/ { bus = 1 }
    mine && /^  Frames written: / && frames == "" { frames = $3 }
    mine && /Tracks of which/ { table = 1; next }
    mine && /Effect Chains|Local log:/ { table = 0 }
    mine && table && match($0, /[0-9]+ +yes +[0-9]+\/ *[0-9]+/) {
      row = substr($0, RSTART, RLENGTH); sub(/.*\/ */, "", row); if (row == u) n++
    }
    END { if (!found) print "none 0 0"; else printf "%s %d %d\n", (frames == "" ? "none" : frames), bus, n }' "$1"
}

# print the desktop profile for a system test
regress_profile() { [[ "$1" == network.sh ]] && echo sway || echo "${RHIZO_DESKTOP_PROFILE:-sway}"; }
REGRESS_LEFT_OTHER_PROFILE=0
# run a system test not covered by an earlier PASS
regress_one() {
  local g="$1" reused profile
  profile=$(regress_profile "$g")
  if RHIZO_DESKTOP_PROFILE="$profile" rig_earlier_pass "$g" tree >"$EV/audio-regress-$g.pass" 2>"$EV/audio-regress-$g.reuse"; then
    reused=$(<"$EV/audio-regress-$g.pass")
    printf 'reused: a full-run PASS recorded at %s on the tree this run started from, evidence %s\n' \
      "${reused%%$'\t'*}" "${reused#*$'\t'}" > "$EV/audio-regress-$g.log"
    pass "$g passed on this same tree (full-run PASS recorded at ${reused%%$'\t'*}, evidence ${reused#*$'\t'})"
  else
    log "    running $g (own boot): $(tail -1 "$EV/audio-regress-$g.reuse")"
    [[ "$profile" == "${RHIZO_DESKTOP_PROFILE:-sway}" ]] || REGRESS_LEFT_OTHER_PROFILE=1
    if RHIZO_DESKTOP_PROFILE="$profile" RHIZO_SKIP_BOOT=0 "$(system_test_file "$g")" >"$EV/audio-regress-$g.log" 2>&1; then
      pass "$g still passes"
    else
      fail "$g regressed (see $EV/audio-regress-$g.log)"
      grep -E "FAIL" "$EV/audio-regress-$g.log" | head -5 >&2
    fi
  fi
  cp "$EV/audio-regress-$g.log" "$EV/regress-$g.log" 2>/dev/null
}
if (( RUN_REGRESSION == 1 )); then
  step "0a. regression: the accumulated system test suite, each on a new boot or its PASS on this tree"
  for g in display.sh network.sh; do
    regress_one "$g"
  done
fi

if (( SKIP_BOOT == 1 && REGRESS_LEFT_OTHER_PROFILE == 1 )); then
  log "    the guest under this chain was booted by a regression leg under the $(regress_profile network.sh) profile, not ${RHIZO_DESKTOP_PROFILE:-sway}: booting this system test's own"
  SKIP_BOOT=0 RHIZO_SKIP_BOOT=0
fi
if (( SKIP_BOOT == 0 )); then
  step "0. boot: VM, compositor, audio host side, Android"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up >$EV/audio-sway.log 2>&1 || { fail "the desktop session did not start (see $EV/audio-sway.log)"; exit 1; }
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 200 >$EV/audio-redeploy.log 2>&1 \
    || { fail "redeploy.sh failed (see $EV/audio-redeploy.log)"; exit 1; }
  tail -4 $EV/audio-redeploy.log
  ../../vm/start/start-audio.sh >$EV/audio-host.log 2>&1 || { fail "audio host side did not start (see $EV/audio-host.log)"; exit 1; }
else
  test_ensure_sway "$EV/chained-audio-sway.log" "$EV/chained-redeploy.log"
  test_ensure_audio "$EV/chained-audio-host.log" || exit 1
fi
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
log "init_pid=$INIT"

leftover=$(ssh_vm -t 10 "test -f /etc/rhizo/policy.conf && echo PRESENT || echo ABSENT" 2>/dev/null | tr -d '\r')
if [[ "$leftover" == "PRESENT" ]]; then
  log "    clearing an old /etc/rhizo/policy.conf left on this vm's disk by an earlier run"
  ssh_vm -t 10 "rm -f /etc/rhizo/policy.conf" >/dev/null 2>&1
fi

boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"
SS_PID_START=$(system_server_pid "$INIT")
log "system_server pid at start: $SS_PID_START"

android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "locksettings set-disabled true" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
android_stay_awake "$INIT" >/dev/null
pass "booted, awake, keyguard disabled"

step "1. HAL topology: primary + per-app buses"
ssh_vm -t 15 "dmesg | grep rhizo-audio-core" > "$EV/hal-kmsg.txt" 2>&1
opened=$(grep -c "output stream open" "$EV/hal-kmsg.txt")
(( opened >= 5 )) || fail "HAL opened $opened output streams at boot, expected 5 (primary + 4 buses)"
for b in bus0 bus1 bus2 bus3 primary; do
  grep -q "\[$b\] output stream open" "$EV/hal-kmsg.txt" || fail "no output stream opened for $b"
done
android_sh "$INIT" "dumpsys media.audio_policy" > "$EV/audio-policy.txt" 2>&1
avail=$(grep -m1 "Available output devices" "$EV/audio-policy.txt")
grep -q "(5)" <<<"$avail" || fail "audio policy reports '$avail', expected 5 available output devices"
grep -q "Config source" "$EV/audio-policy.txt" || fail "no config source line in the policy dump"
log "    $(grep -m1 'Config source' "$EV/audio-policy.txt")"
pass "HAL exposes 5 outputs and the framework made all 5 devices available"

step "2. install: $PKG_A ($HZ_A Hz) + $PKG_B ($HZ_B Hz)"
../../vm/boot/adb-tunnel.sh up || fail "adb-tunnel.sh up failed"
timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$VAR_DIR/share/rhizo-audiotest-a.apk" /data/local/tmp/rhizo-audiotest-a.apk \
  && timeout 60 "$ADB" -s "127.0.0.1:$ADB_PORT" push "$VAR_DIR/share/rhizo-audiotest-b.apk" /data/local/tmp/rhizo-audiotest-b.apk \
  || fail "adb push of the audio fixtures failed"
for apk_pkg in "rhizo-audiotest-a.apk:$PKG_A" "rhizo-audiotest-b.apk:$PKG_B"; do
  apk="${apk_pkg%%:*}"; pkg="${apk_pkg##*:}"
  out=$(ANDROID_SH_TIMEOUT=180 android_sh "$INIT" "pm install -r -t -g --user 0 /data/local/tmp/$apk")
  grep -qx "Success" <<<"$out" || fail "pm install of $apk did not print 'Success': $out"
  pkglist=$(android_sh "$INIT" "pm list packages")
  grep -qx "package:$pkg" <<<"$pkglist" || fail "$pkg missing from pm list packages"
done
android_sh "$INIT" "dumpsys package com.rhizo.audiorouter" > "$EV/router-package.txt" 2>&1
grep -q "android.permission.MODIFY_AUDIO_ROUTING: granted=true" "$EV/router-package.txt" \
  || fail "the router app does not hold MODIFY_AUDIO_ROUTING (privapp-permissions allowlist?)"
psout=$(android_sh "$INIT" "ps -A")
grep -q com.rhizo.audiorouter <<<"$psout" \
  || fail "the router app process is not running (persistent=true?)"
pass "both fixtures installed; router running with MODIFY_AUDIO_ROUTING granted"

audio_map_before=$(ssh_vm -t 10 "cat /run/rhizo-audio-map" 2>/dev/null)
if [[ -n "$audio_map_before" ]]; then
  audio_map_pruned=""
  while read -r _abus _apkg; do
    [[ -n "$_abus" && -n "$_apkg" ]] || continue
    if [[ "$_apkg" == "$PKG_A" || "$_apkg" == "$PKG_B" ]]; then
      audio_map_pruned+="$_abus $_apkg"$'\n'
    else
      log "    reclaiming $_abus from $_apkg"
      android_sh "$INIT" "am force-stop $_apkg" >/dev/null 2>&1
    fi
  done <<<"$audio_map_before"
  if [[ -n "$audio_map_pruned" ]]; then
    ssh_vm -t 10 "cat > /run/rhizo-audio-map" <<<"${audio_map_pruned%$'\n'}" >/dev/null 2>&1 \
      || fail "could not write the reclaimed audio bus map"
  else
    ssh_vm -t 10 "> /run/rhizo-audio-map" >/dev/null 2>&1 \
      || fail "could not truncate the reclaimed audio bus map"
  fi
fi

step "3. launch: one bus per app, assigned by the launcher"
launch_log_mark=$(ssh_vm -t 10 "stat -c %s /run/rhizo-launch/rhizo-launch.log 2>/dev/null || echo 0" | tr -d '\r')
if ! [[ "$launch_log_mark" =~ ^[0-9]+$ ]]; then
  fail "could not size the launcher's log before launching (got '$launch_log_mark')"
  launch_log_mark=0
fi
play_since=$(android_sh "$INIT" 'date "+%m-%d %H:%M:%S.000"' | tail -1 | tr -d '\r')
[[ "$play_since" =~ ^[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\.000$ ]] \
  || fail "could not read the guest clock before launching (got '$play_since')"
for pkg in "$PKG_A" "$PKG_B"; do
  ssh_vm -t 120 "/usr/lib/rhizo/tools/rhizo-launch.sh $pkg $ACT" >/dev/null 2>&1 \
    || fail "rhizo-launch.sh failed for $pkg"
done
ssh_vm -t 10 "cat /run/rhizo-audio-map" > "$EV/audio-map.txt" 2>&1
BUS_A=$(awk -v p="$PKG_A" '$2==p{print $1; exit}' "$EV/audio-map.txt")
BUS_B=$(awk -v p="$PKG_B" '$2==p{print $1; exit}' "$EV/audio-map.txt")
[[ -n "$BUS_A" ]] || fail "$PKG_A is on no bus at all (see $EV/audio-map.txt)"
[[ -n "$BUS_B" ]] || fail "$PKG_B is on no bus at all (see $EV/audio-map.txt)"
[[ -n "$BUS_A" && "$BUS_A" != "$BUS_B" ]] \
  || fail "$PKG_A and $PKG_B share bus '$BUS_A'"
log "    resolved from the launcher's own map: $PKG_A=$BUS_A $PKG_B=$BUS_B"
ssh_vm -t 10 "tail -c +$(( launch_log_mark + 1 )) /run/rhizo-launch/rhizo-launch.log | grep audio" > "$EV/launch-log.txt" 2>&1
for bus_pkg in "$BUS_A:$PKG_A" "$BUS_B:$PKG_B"; do
  bus="${bus_pkg%%:*}"; pkg="${bus_pkg##*:}"
  grep -qF "audio pkg=$pkg bus=$bus -> ok registered=true" "$EV/launch-log.txt" \
    || fail "the router reported no registration of $pkg on '$bus' for this step's launch (see $EV/launch-log.txt)"
done

deadline=$(( $(date +%s) + 60 ))
playing=0
while (( $(date +%s) < deadline )); do
  android_sh "$INIT" "logcat -d -b all -t \"$play_since\"" | grep "RHIZO_AUDIO_PLAYING" > "$EV/app-playing.txt"
  if grep -qF "RHIZO_AUDIO_PLAYING pkg=$PKG_A hz=$HZ_A " "$EV/app-playing.txt" \
     && grep -qF "RHIZO_AUDIO_PLAYING pkg=$PKG_B hz=$HZ_B " "$EV/app-playing.txt"; then
    playing=1; break
  fi
  sleep 3
done
(( playing == 1 )) \
  || fail "$PKG_A and $PKG_B did not both log RHIZO_AUDIO_PLAYING since $play_since (see $EV/app-playing.txt)"
pass "both apps launched and playing, each mapped to its own bus"

step "4. routing: each app's own track on its own BUS mixer thread"
android_sh "$INIT" "dumpsys media.audio_policy" > "$EV/audio-policy-routing.txt" 2>&1
android_sh "$INIT" "dumpsys media.audio_flinger" > "$EV/audio-flinger.txt" 2>&1
android_sh "$INIT" "pm list packages -U --user 0 com.rhizo.audiotest" > "$EV/audiotest-uids.txt" 2>&1
routed_handles=()
for bus_pkg in "$BUS_A:$PKG_A" "$BUS_B:$PKG_B"; do
  bus="${bus_pkg%%:*}"; pkg="${bus_pkg##*:}"
  uid=$(awk -v p="package:$pkg" '$1==p && $2 ~ /^uid:[0-9]/ { sub(/^uid:/, "", $2); sub(/,.*/, "", $2); print $2; exit }' "$EV/audiotest-uids.txt")
  handle=$(bus_output_handle "$EV/audio-policy-routing.txt" "$bus")
  if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
    fail "no uid for $pkg in pm list packages -U (see $EV/audiotest-uids.txt)"; continue
  fi
  if ! [[ "$handle" =~ ^[0-9]+$ ]]; then
    fail "the audio policy names no output I/O handle for '$bus' (see $EV/audio-policy-routing.txt)"; continue
  fi
  read -r frames on_bus tracks <<<"$(bus_thread_state "$EV/audio-flinger.txt" "$handle" "$uid")"
  log "    $bus: output $handle, frames written $frames, BUS device $on_bus, active tracks from $pkg (uid $uid): $tracks"
  if ! [[ "$frames" =~ ^[0-9]+$ ]]; then
    fail "AudioFlinger has no mixer thread for $bus's I/O handle $handle (see $EV/audio-flinger.txt)"; continue
  fi
  (( on_bus == 1 )) || fail "$bus's mixer thread (I/O handle $handle) is not on an AUDIO_DEVICE_OUT_BUS device"
  (( frames > 0 )) || fail "$bus's mixer thread (I/O handle $handle) has written no frames"
  (( tracks >= 1 )) || fail "$bus's mixer thread (I/O handle $handle) holds no active track from $pkg (uid $uid)"
  routed_handles+=("$handle")
done
[[ ${#routed_handles[@]} -eq 2 && "${routed_handles[0]}" != "${routed_handles[1]}" ]] \
  || fail "the two apps did not resolve to two distinct mixer threads (handles: ${routed_handles[*]:-none})"
pass "each app's own active track is on its own BUS mixer thread, and both threads are writing frames"
ssh_vm -t 15 "pid=\$(pgrep -x rhizo-audio-cor | head -1); [ -n \"\$pid\" ] && ps -L -o tid=,ni=,comm=,cls=,rtprio= -p \$pid" \
  | tr -d '\r' >"$EV/hal-workers.txt" 2>&1
[[ -s "$EV/hal-workers.txt" ]] || echo "<none>" >"$EV/hal-workers.txt"
n=$(awk '$3 == "rhizo-aud-out"' "$EV/hal-workers.txt" | grep -c .)
bad=$(awk '$3 == "rhizo-aud-out" && $2 != -19 {print $1 ":ni=" $2 ",cls=" $4 ",rtprio=" $5}' "$EV/hal-workers.txt" | tr '\n' ' ')
[[ "$n" -ge 2 && -z "${bad// /}" ]] \
  && pass "the HAL's $n playback worker(s) run at nice -19" \
  || fail "the HAL's playback workers: $n named rhizo-aud-out, not at nice -19: [${bad}] ($EV/hal-workers.txt)"

step "5. presence: one PipeWire node per app"
declare -A app_name=() node_desc=()
audio_deadline=$(( $(date +%s) + 45 ))
while (( $(date +%s) < audio_deadline )); do
  ssh_vm -t 15 "$PW_AS_DESKTOP pw-dump" > "$EV/pw-dump.json" 2>&1
  all_matched=1
  for bus_pkg in "$BUS_A:$PKG_A" "$BUS_B:$PKG_B"; do
    bus="${bus_pkg%%:*}"; pkg="${bus_pkg##*:}"
    app_name[$bus]=$(pw_node_prop "$EV/pw-dump.json" "rhizo.$bus" application.name)
    node_desc[$bus]=$(pw_node_prop "$EV/pw-dump.json" "rhizo.$bus" node.description)
    [[ "${app_name[$bus]}" == "$pkg" && "${node_desc[$bus]}" == "$pkg" ]] || all_matched=0
  done
  (( all_matched )) && break
  sleep 1
done
ssh_vm -t 10 "cat /var/log/rhizo/rhizo-audiod.log" > "$EV/audiod.log" 2>&1
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$EV/pw-dump.json" 2>/dev/null \
  || fail "pw-dump never returned pipewire's graph: $(head -c 120 "$EV/pw-dump.json" | tr '\n' ' ')"
for bus_pkg in "$BUS_A:$PKG_A" "$BUS_B:$PKG_B"; do
  bus="${bus_pkg%%:*}"; pkg="${bus_pkg##*:}"
  [[ -n "${app_name[$bus]}" ]] || fail "node rhizo.$bus is not in the live graph"
  [[ "${app_name[$bus]}" == "$pkg" && "${node_desc[$bus]}" == "$pkg" ]] \
    || fail "rhizo.$bus carries app='${app_name[$bus]}' description='${node_desc[$bus]}' in the live graph, expected '$pkg'"
  grep -q "node 'rhizo.$bus' up (app '$pkg'" "$EV/audiod.log" \
    || log "    audiod.log never recorded '$pkg' for $bus at connect time (named later, from a live map)"
done
pass "two distinct PipeWire nodes, each carrying its own package name"

step "6. content: per-node tone isolation (the real per-app proof)"
rm -f "$EV/test-audio-a.wav" "$EV/test-audio-b.wav"
ssh_vm -t 15 "rm -f /tmp/test-audio-a.wav /tmp/test-audio-b.wav" >/dev/null 2>&1 \
  || fail "could not clear the guest's earlier step-6 captures"
pw_capture "rhizo_sink_$BUS_B" 4 /tmp/test-audio-b.wav >/dev/null 2>&1 &
capture_b=$!
pw_capture "rhizo_sink_$BUS_A" 4 /tmp/test-audio-a.wav >/dev/null 2>&1
capture_a_rc=$?
wait "$capture_b"
capture_b_rc=$?
(( capture_a_rc == 0 )) || fail "the capture of rhizo_sink_$BUS_A did not run to its deadline (exit $capture_a_rc)"
(( capture_b_rc == 0 )) || fail "the capture of rhizo_sink_$BUS_B did not run to its deadline (exit $capture_b_rc)"
timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" \
  "$SSH_TARGET:/tmp/test-audio-a.wav" "$SSH_TARGET:/tmp/test-audio-b.wav" "$EV/" \
  || fail "could not retrieve the captures"

for side in "a:$HZ_A:$HZ_B" "b:$HZ_B:$HZ_A"; do
  s="${side%%:*}"; rest="${side#*:}"; mine="${rest%%:*}"; theirs="${rest##*:}"
  wav="$EV/test-audio-$s.wav"
  [[ -f "$wav" ]] || { fail "no capture for side $s"; continue; }
  python3 "$REPO/test/system/tools/wavstat.py" "$wav" --tones "$HZ_A" "$HZ_B" > "$EV/wavstat-$s.txt" 2>&1 \
    || { fail "wavstat could not read capture $s (see $EV/wavstat-$s.txt)"; continue; }
  rms=$(awk '$1=="rms"{print $2}' "$EV/wavstat-$s.txt")
  dom=$(awk '$1=="dominant_hz"{print $2}' "$EV/wavstat-$s.txt")
  mine_share=$(awk -v k="tone_${mine}_share" '$1==k{print $2}' "$EV/wavstat-$s.txt")
  theirs_share=$(awk -v k="tone_${theirs}_share" '$1==k{print $2}' "$EV/wavstat-$s.txt")
  log "    $s: rms=$rms dominant=${dom}Hz own(${mine})=$mine_share other(${theirs})=$theirs_share"
  if ! [[ "$rms" =~ ^[0-9.]+([eE][-+]?[0-9]+)?$ && "$dom" =~ ^[0-9.]+([eE][-+]?[0-9]+)?$ && "$mine_share" =~ ^[0-9.]+([eE][-+]?[0-9]+)?$ && "$theirs_share" =~ ^[0-9.]+([eE][-+]?[0-9]+)?$ ]]; then
    fail "wavstat gave no numbers for capture $s (rms='$rms' dominant='$dom' own='$mine_share' other='$theirs_share')"
    continue
  fi
  awk -v v="$rms" 'BEGIN{exit !(v > 0.001)}' || fail "capture $s is silent (rms=$rms)"
  awk -v d="$dom" -v m="$mine" 'BEGIN{exit !(d > m-15 && d < m+15)}' \
    || fail "capture $s has dominant frequency ${dom}Hz, expected ~${mine}Hz"
  awk -v v="$mine_share" 'BEGIN{exit !(v > 0.9)}' \
    || fail "capture $s holds only $mine_share of its energy at its own tone"
  awk -v v="$theirs_share" 'BEGIN{exit !(v < 0.1)}' \
    || fail "capture $s is contaminated by the other app's tone (share $theirs_share)"
done
pass "each node contains its own app's tone and not the other's"

step "7. control: zeroing one node silences that app only"
node_a=$(pw_node_id "rhizo.$BUS_A")
[[ -n "$node_a" ]] || fail "cannot resolve node id for rhizo.$BUS_A"
ssh_vm -t 15 "$PW_AS_DESKTOP wpctl set-volume $node_a 0" >/dev/null 2>&1 \
  || fail "wpctl set-volume failed for node $node_a"
rm -f "$EV/test-audio-a-muted.wav" "$EV/test-audio-b-muted.wav"
ssh_vm -t 15 "rm -f /tmp/test-audio-a-muted.wav /tmp/test-audio-b-muted.wav" >/dev/null 2>&1 \
  || fail "could not clear the guest's earlier step-7 captures"
pw_capture "rhizo_sink_$BUS_B" 3 /tmp/test-audio-b-muted.wav >/dev/null 2>&1 &
capture_b=$!
pw_capture "rhizo_sink_$BUS_A" 3 /tmp/test-audio-a-muted.wav >/dev/null 2>&1
capture_a_rc=$?
wait "$capture_b"
capture_b_rc=$?
(( capture_a_rc == 0 )) || fail "the muted capture of rhizo_sink_$BUS_A did not run to its deadline (exit $capture_a_rc)"
(( capture_b_rc == 0 )) || fail "the muted capture of rhizo_sink_$BUS_B did not run to its deadline (exit $capture_b_rc)"
timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" \
  "$SSH_TARGET:/tmp/test-audio-a-muted.wav" "$SSH_TARGET:/tmp/test-audio-b-muted.wav" "$EV/" \
  || fail "could not retrieve the muted captures"
ssh_vm -t 15 "$PW_AS_DESKTOP wpctl set-volume $node_a 1.0" >/dev/null 2>&1 \
  || fail "wpctl could not restore node $node_a's volume"

muted_rms=$(wavstat_get "$EV/test-audio-a-muted.wav" rms) \
  || fail "wavstat could not read $EV/test-audio-a-muted.wav"
other_rms=$(wavstat_get "$EV/test-audio-b-muted.wav" rms) \
  || fail "wavstat could not read $EV/test-audio-b-muted.wav"
log "    muted app rms=$muted_rms, other app rms=$other_rms"
if [[ "$muted_rms" =~ ^[0-9.]+([eE][-+]?[0-9]+)?$ && "$other_rms" =~ ^[0-9.]+([eE][-+]?[0-9]+)?$ ]]; then
  awk -v v="$muted_rms" 'BEGIN{exit !(v < 0.0005)}' || fail "the muted app is still audible (rms=$muted_rms)"
  awk -v v="$other_rms" 'BEGIN{exit !(v > 0.001)}' || fail "muting one app silenced the other too (rms=$other_rms)"
else
  fail "the muted captures gave no rms (muted='$muted_rms' other='$other_rms')"
fi

rm -f "$EV/test-audio-a-restored.wav"
ssh_vm -t 15 "rm -f /tmp/test-audio-a-restored.wav" >/dev/null 2>&1 \
  || fail "could not clear the guest's earlier restored capture"
pw_capture "rhizo_sink_$BUS_A" 3 /tmp/test-audio-a-restored.wav >/dev/null 2>&1 \
  || fail "the capture of rhizo_sink_$BUS_A after its volume was restored did not run to its deadline"
timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_TARGET:/tmp/test-audio-a-restored.wav" "$EV/" \
  || fail "could not retrieve the restored capture"
restored_rms=$(wavstat_get "$EV/test-audio-a-restored.wav" rms) \
  || fail "wavstat could not read $EV/test-audio-a-restored.wav"
log "    app A after its volume was restored: rms=$restored_rms"
if [[ "$restored_rms" =~ ^[0-9.]+([eE][-+]?[0-9]+)?$ ]]; then
  awk -v v="$restored_rms" 'BEGIN{exit !(v > 0.001)}' || fail "app A stayed silent after its volume was restored (rms=$restored_rms)"
else
  fail "the restored capture gave no rms ('$restored_rms')"
fi
pass "host-side volume acts on exactly one app, and the app is audible again once restored"

step "8. stability through the whole system test"
boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test end"
SS_PID_END=$(system_server_pid "$INIT")
if [[ -z "$SS_PID_START" || -z "$SS_PID_END" ]]; then
  fail "no system_server pid to compare (start='$SS_PID_START' end='$SS_PID_END')"
elif [[ "$SS_PID_START" != "$SS_PID_END" ]]; then
  fail "system_server restarted during the system test ($SS_PID_START -> $SS_PID_END)"
fi
ssh_vm -t 10 "cat /var/log/rhizo/rhizo-audiod.log" > "$EV/audiod-final.log" 2>&1
log "    bridge stats: $(grep -c 'node .* up' "$EV/audiod-final.log") nodes created"
pass "sys.boot_completed=1, system_server pid unchanged ($SS_PID_END)"

step "9. capability: audio.out on gives a daemon and a socket, withheld gives neither"
AUDIO_SOCK=/run/rhizo-audio/audiod

policy_left=$(ssh_vm -t 10 "test -f /etc/rhizo/policy.conf && echo PRESENT || echo ABSENT" 2>/dev/null | tr -d '\r')
[[ "$policy_left" == "ABSENT" ]] \
  || fail "a leftover /etc/rhizo/policy.conf on the guest means this leg is not proving the shipped default"
daemon_on=$(ssh_vm -t 10 "pgrep -x rhizo-audiod >/dev/null && echo UP || echo DOWN" 2>/dev/null | tr -d '\r')
sock_on=$(ssh_vm -t 10 "test -S $AUDIO_SOCK && echo UP || echo DOWN" 2>/dev/null | tr -d '\r')
[[ "$daemon_on" == "UP" && "$sock_on" == "UP" ]] \
  || fail "audio.out at its default: daemon=$daemon_on socket=$sock_on, expected both UP"

audio_withheld_policy="$TEST_WORKDIR/policy-audio-withheld.conf"
printf '[audio]\nout = no\n' > "$audio_withheld_policy"
ssh_vm -t 20 "sync" >/dev/null 2>&1
console_1_8="$VAR_DIR/vm-boot${SUFFIX}.log"
cp -p "$console_1_8" "$EV/console-steps-1-8.log" \
  || echo "<none: no readable $console_1_8 before the step 9 reboot>" > "$EV/console-steps-1-8.log"
kill_vm
boot_vm
wait_for_boot_slot || fail "the audio.out-withheld reboot never got a qemu slot"
wait_for_ssh 300 || fail "the vm did not come back after the audio.out-withheld reboot"
desk_session_up >>"$EV/audio-capability.log" 2>&1
../../vm/redeploy.sh --skip-kill --boot-wait 200 >>"$EV/audio-capability.log" 2>&1 \
  || fail "redeploy.sh failed during the audio.out-withheld reboot (see $EV/audio-capability.log)"
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || fail "no init second_stage after the audio.out-withheld reboot"
android_stay_awake "$INIT" >/dev/null
RHIZO_POLICY_CONF="$audio_withheld_policy" ../../vm/start/start-audio.sh >>"$EV/audio-capability.log" 2>&1
daemon_off=$(ssh_vm -t 10 "pgrep -x rhizo-audiod >/dev/null && echo UP || echo DOWN" 2>/dev/null | tr -d '\r')
sock_off=$(ssh_vm -t 10 "test -S $AUDIO_SOCK && echo UP || echo DOWN" 2>/dev/null | tr -d '\r')
[[ "$daemon_off" == "DOWN" && "$sock_off" == "DOWN" ]] \
  || fail "audio.out withheld: daemon=$daemon_off socket=$sock_off, expected both DOWN"

ssh_vm -t 20 "printf '[audio]\nout = no\n' > /etc/rhizo/policy.conf" \
  || fail "could not write the withheld policy onto the guest's /etc/rhizo/policy.conf"
ssh_vm -t 10 "systemctl start rhizo-audiod.service" >>"$EV/audio-capability.log" 2>&1
cond_result=$(ssh_vm -t 10 "systemctl show -p ConditionResult --value rhizo-audiod.service" 2>/dev/null | tr -d '\r')
active_cond=$(ssh_vm -t 10 "systemctl is-active rhizo-audiod.service" 2>/dev/null | tr -d '\r')
sock_cond_off=$(ssh_vm -t 10 "test -S $AUDIO_SOCK && echo UP || echo DOWN" 2>/dev/null | tr -d '\r')
[[ "$cond_result" == "no" && "$active_cond" != "active" && "$sock_cond_off" == "DOWN" ]] \
  || fail "audio.out withheld via the guest's own policy.conf: rhizo-audiod.service's own ExecCondition=capability-allowed.sh did not skip it (ConditionResult=$cond_result, is-active=$active_cond, socket=$sock_cond_off)"
ssh_vm -t 20 "rm -f /etc/rhizo/policy.conf" \
  || fail "could not remove the withheld policy from the guest's /etc/rhizo/policy.conf"
ssh_vm -t 10 "systemctl reset-failed rhizo-audiod.service 2>/dev/null; systemctl start rhizo-audiod.service" >>"$EV/audio-capability.log" 2>&1
unit_active_on=$(ssh_vm -t 10 "systemctl is-active rhizo-audiod.service" 2>/dev/null | tr -d '\r')
[[ "$unit_active_on" == "active" ]] \
  || fail "audio.out restored via the guest's own policy.conf: rhizo-audiod.service did not become active (is-active=$unit_active_on)"
pass "audio.out on (default) gives a live daemon and socket; withheld, both are unreachable"

step "evidence in $EV"
android_release_stay_awake "$INIT"
if (( FAILED == 0 )); then
  test_record_verdict PASSED "$(verdict_params)"
  log "SYSTEM TEST PASSED"
else
  test_record_verdict FAILED "$(verdict_params)"
  log "SYSTEM TEST FAILED"
fi
exit "$FAILED"
