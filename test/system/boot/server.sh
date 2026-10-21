#!/bin/bash
# test the headless boot profile
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: none
# test-records-metrics: no
# test-verdict-params: -
# test-requires: share:rhizo-fps.apk
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
export RHIZO_DESKTOP_PROFILE=server
source ../lib/desktop-lib.sh \
  || { fail "desktop profile server unavailable"; exit 1; }
source ../lib/server-assert-lib.sh

SELFTEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd ../../.. && pwd)"
CLI_SRC="$REPO_DIR/src/install/cli/rhizo.sh"

ADB=~/Android/Sdk/platform-tools/adb
ADB_TARGET="127.0.0.1:$ADB_PORT"
# run adb against the test device
adbx() { "$ADB" -s "$ADB_TARGET" "$@"; }

# shellcheck disable=SC2034
POLICY_CONF=/etc/rhizo/policy.conf
RIG_ADB_KEY="$HOME/.android/adbkey.pub"
RIG_KEY_GUEST=/root/adbkey.pub
OPERATOR_KEYS=/etc/rhizo/adb_keys
BOOT_LOG=/root/boot.log
ANDROIDD_ENV=/root/androidd.env

IDLE_STOP_LONG_S=4800
IDLE_STOP_SHORT_S=60
FRAME_WINDOW_S=15

FIXTURE_APK="$VAR_DIR/share/rhizo-fps.apk"
FIXTURE_PKG=com.rhizo.fps
FIXTURE_ACT="$FIXTURE_PKG/android.app.NativeActivity"

if ! read -r CAP_DISPLAY_DEFAULT CAP_SCREEN_OFF_DEFAULT < <(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from sandbox import capabilities as rc
print(rc.CAPABILITIES["server.display"]["default"],
      rc.CAPABILITIES["server.screen_off_s"]["default"])' "$REPO/src/androidd"); then
  echo "server.sh: could not read server.display/server.screen_off_s defaults from sandbox/capabilities.py" >&2
  exit 2
fi
if [[ -z "$CAP_DISPLAY_DEFAULT" || -z "$CAP_SCREEN_OFF_DEFAULT" ]]; then
  echo "server.sh: server.display/server.screen_off_s defaults read as empty" >&2
  exit 2
fi

DISPLAY_GEOMETRY="1024x768@60/320"
SCREEN_OFF_S=25
if [[ "$DISPLAY_GEOMETRY" == "$CAP_DISPLAY_DEFAULT" ]]; then
  echo "server.sh: DISPLAY_GEOMETRY must differ from the capability default $CAP_DISPLAY_DEFAULT to prove the config path, not the fallback" >&2
  exit 2
fi
if [[ "$SCREEN_OFF_S" == "$CAP_SCREEN_OFF_DEFAULT" ]]; then
  echo "server.sh: SCREEN_OFF_S must differ from the capability default $CAP_SCREEN_OFF_DEFAULT to prove the config path, not AOSP's own stock timeout" >&2
  exit 2
fi
DISPLAY_WH="${DISPLAY_GEOMETRY%@*}"
DISPLAY_DPI="${DISPLAY_GEOMETRY##*/}"
if [[ ! "$DISPLAY_WH" =~ ^[0-9]+x[0-9]+$ || ! "$DISPLAY_DPI" =~ ^[0-9]+$ ]]; then
  echo "server.sh: DISPLAY_GEOMETRY '$DISPLAY_GEOMETRY' is not WxH@fps/dpi" >&2
  exit 2
fi

MASKED_BLOCK=$(sed -n '/^SERVER_MASKED_UNITS=(/,/)/p' "$CLI_SRC")
mapfile -t MASKED_UNITS < <(printf '%s\n' "$MASKED_BLOCK" | sed 's/^SERVER_MASKED_UNITS=(//' \
  | tr -d '()' | tr -s ' \t' '\n' | grep -E '^rhizo-[a-z-]+\.(service|path)$')
MASKED_UNITS_EXPECTED_N=$(printf '%s\n' "$MASKED_BLOCK" | sed 's/^SERVER_MASKED_UNITS=(//' | tr -d '()' | wc -w)
if [[ ${#MASKED_UNITS[@]} -ne "$MASKED_UNITS_EXPECTED_N" ]]; then
  echo "server.sh: parsed ${#MASKED_UNITS[@]} masked units from $CLI_SRC but SERVER_MASKED_UNITS itself names $MASKED_UNITS_EXPECTED_N" >&2
  exit 2
fi
IDLE_UNIT=$(sed -n 's/^SERVER_IDLE_UNIT=//p' "$CLI_SRC" | head -1)
IDLE_STOP_UNIT=$(sed -n 's/^TIMER_UNIT = _instanced("\(.*\)", SANDBOX_ID)$/\1/p' "$REPO_DIR/src/services/server-idle/server-idle.py" | head -1)

if (( SELFTEST )); then
  SELFTEST_EV="${TMPDIR:-/tmp}/test-server-selftest${SUFFIX}"
  rm -rf "$SELFTEST_EV"
  test_init server --no-vm --evidence-root "$SELFTEST_EV" || exit 1
else
  test_init server --teardown || exit 1
fi

# remove hostfs.conf from the vm
cleanup_hostfs_conf() {
  (( TEST_NO_VM )) && return 0
  ssh_vm -t 10 "rm -f /etc/rhizo/hostfs.conf" >/dev/null 2>&1
}
# restore the desktop profile and remove policy.conf
cleanup_vm_state() {
  (( TEST_NO_VM )) && return 0
  cleanup_hostfs_conf
  local out rc
  out=$(ssh_vm -t 60 "rhizo profile desktop" 2>&1)
  rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" > "$EV/profile-desktop-cleanup.txt"
  (( rc == 0 )) || log "WARNING: test-server cleanup: 'rhizo profile desktop' exited $rc; see $EV/profile-desktop-cleanup.txt"
  ssh_vm -t 10 "rm -f /etc/rhizo/policy.conf" >/dev/null 2>&1
}
# shellcheck disable=SC2034
(( SELFTEST )) || TEST_EXTRA_CLEANUP=cleanup_vm_state

if [[ ${#MASKED_UNITS[@]} -eq 0 || -z "$IDLE_UNIT" || -z "$IDLE_STOP_UNIT" ]]; then
  fail "could not read the unit names out of $CLI_SRC and src/services/server-idle/server-idle.py"
  test_record_verdict FAILED
  exit 1
fi

if (( SELFTEST )); then
  step "selftest: every assertion above must be able to fail, by name"

  check_fails() {
    local what="$1" fn="$2"; shift 2
    local before=$FAILED
    "$fn" "$@" >/dev/null
    if (( FAILED > before )); then
      log "  selftest OK: $what"
      FAILED=$before
      : > "$EV/failures.log"
    else
      fail "selftest: $what did NOT fail"
    fi
  }
  check_passes() {
    local what="$1" fn="$2"; shift 2
    local before=$FAILED
    "$fn" "$@" >/dev/null
    if (( FAILED > before )); then
      fail "selftest: $what fired on a genuinely good input"
    else
      log "  selftest OK: $what"
    fi
  }

  check_fails "a tap taken is caught" assert_adb_no_tap x \
    "state=unauthorized -- clearing the real 'Allow USB debugging?' dialog"$'\n'"ADB BRIDGE UP -- 127.0.0.1:5555 is device (after clearing the auth dialog, 3 tap attempt(s))"
  check_fails "no bridge-up line at all is caught" assert_adb_no_tap x "some unrelated log tail"
  check_passes "a no-tap device is accepted" assert_adb_no_tap x "ADB BRIDGE UP -- 127.0.0.1:5555 is device"

  check_fails "boot_completed=0 is caught" assert_boot_completed x "0"
  check_fails "an empty boot_completed is caught" assert_boot_completed x ""
  check_passes "boot_completed=1 is accepted" assert_boot_completed x "1"

  check_fails "a published compositor socket is caught" assert_no_wayland_socket x "/run/user/0/wayland-1"
  check_passes "no compositor socket is accepted" assert_no_wayland_socket x ""
  check_fails "an empty result from an incomplete probe is not trusted as 'no socket'" \
    assert_no_wayland_socket x "" 0

  check_fails "a boot with no headless marker is caught" assert_headless_marker x "[l3] pivoted"
  check_passes "the launcher's headless marker is accepted" assert_headless_marker x \
    "[l3] wayland socket NOT FOUND -- tried wayland-0 (absent)"

  check_fails "a live compositor pid is caught" assert_no_compositor_process x "4821"
  check_passes "no compositor pid is accepted" assert_no_compositor_process x ""
  check_fails "an empty result from an incomplete probe is not trusted as 'no process'" \
    assert_no_compositor_process x "" 0

  if out=$(probe_ssh_result "no tag here"); [[ $? -eq 0 || -n "$out" ]]; then
    fail "selftest: probe_ssh_result treated output with no trailing sentinel as complete"
  else
    log "  selftest OK: probe_ssh_result reports incomplete with no trailing tag"
  fi
  if out=$(probe_ssh_result $'some output\n'"$PROBE_DONE_TAG"); [[ $? -eq 0 && "$out" == "some output" ]]; then
    log "  selftest OK: probe_ssh_result strips the trailing tag and reports complete"
  else
    fail "selftest: probe_ssh_result did not cleanly accept a complete result (got '$out')"
  fi

  check_fails "an unmasked unit is caught" assert_unit_masked x rhizo-display-pool.path $'LoadState=loaded\nActiveState=active'
  check_fails "a masked but still active unit is caught" assert_unit_masked x rhizo-display-pool.path $'LoadState=masked\nActiveState=active'
  check_passes "a masked inactive unit is accepted" assert_unit_masked x rhizo-display-pool.path $'LoadState=masked\nActiveState=inactive'

  check_fails "a masked unit fails the desktop-baseline unmask check" assert_unit_unmasked x rhizo-display-pool.path $'LoadState=masked\nActiveState=inactive'
  check_passes "a loaded unit passes the desktop-baseline unmask check" assert_unit_unmasked x rhizo-display-pool.path $'LoadState=loaded\nActiveState=inactive'

  check_fails "an inactive idle unit is caught" assert_unit_active x "$IDLE_UNIT" $'LoadState=loaded\nActiveState=inactive'
  check_fails "a masked idle unit is caught" assert_unit_active x "$IDLE_UNIT" $'LoadState=masked\nActiveState=inactive'
  check_passes "a running idle unit is accepted" assert_unit_active x "$IDLE_UNIT" $'LoadState=loaded\nActiveState=active'

  check_fails "the CLI reporting desktop is caught" assert_profile_applied x "RHIZO_PROFILE profile=desktop"
  check_fails "an unreadable policy file is caught" assert_profile_applied x \
    "RHIZO_PROFILE profile=unknown (/etc/rhizo/policy.conf unreadable, or rhizo.profile is not a registered capability)"
  check_passes "the CLI reporting server is accepted" assert_profile_applied x "RHIZO_PROFILE profile=server"

  POLICY_GOOD=$'[rhizo]\nprofile = server\n[server]\nadb_reach = host\nidle_stop_s = 4800\ndisplay = '"$DISPLAY_GEOMETRY"$'\nscreen_off_s = '"$SCREEN_OFF_S"$'\n[devices]\ndri = on'
  check_fails "the wrong adb_reach in the written file is caught" assert_policy_written x "$POLICY_GOOD" lan 4800 on
  check_fails "a file the write never reached is caught" assert_policy_written x "" host 4800 on
  check_passes "the written policy is accepted" assert_policy_written x "$POLICY_GOOD" host 4800 on

  check_fails "an add that registered nothing is caught" assert_adbkey_registered x "RHIZO_ADBKEY added=0" "RHIZO_ADBKEY list=1"
  check_fails "an empty key list is caught" assert_adbkey_registered x "RHIZO_ADBKEY added=1" "RHIZO_ADBKEY list=0"
  check_passes "one registered key is accepted" assert_adbkey_registered x "RHIZO_ADBKEY added=1" \
    $'F0:11:22\tuser@rig\nRHIZO_ADBKEY list=1'

  check_fails "status naming the desktop profile is caught" assert_status_json x \
    '{"profile":"desktop","unit":"active","boot_completed":"1","adb":"192.168.100.50:5555","release":"a16","prepared":"k","adb_keys":1}'
  check_fails "status with no adb endpoint is caught" assert_status_json x \
    '{"profile":"server","unit":"active","boot_completed":"1","adb":null,"release":"a16","prepared":"k","adb_keys":1}'
  check_fails "status with no registered key is caught" assert_status_json x \
    '{"profile":"server","unit":"active","boot_completed":"1","adb":"192.168.100.50:5555","release":"a16","prepared":"k","adb_keys":0}'
  check_fails "status that is not JSON is caught" assert_status_json x "RHIZO_FAIL no probe client"
  check_passes "a complete server status is accepted" assert_status_json x \
    '{"profile":"server","unit":"active","boot_completed":"1","adb":"192.168.100.50:5555","release":"a16","prepared":"k","adb_keys":1}'

  DOCTOR_OK=$'[rhizo]   adb endpoint: 192.168.100.50:5555\n[rhizo]   registered adb keys: 1\nRHIZO_DOCTOR_OK warnings=0'
  check_fails "doctor with no adb endpoint line is caught" assert_doctor_server x \
    $'[rhizo]   registered adb keys: 1\nRHIZO_DOCTOR_OK warnings=0'
  check_fails "doctor reporting issues is caught" assert_doctor_server x \
    $'[rhizo]   adb endpoint: 192.168.100.50:5555\n[rhizo]   platform: fail -- this host is debian\nRHIZO_DOCTOR_ISSUES issues=1 warnings=0'
  check_fails "doctor's own 'not running' placeholder is caught" assert_doctor_server x \
    $'[rhizo]   adb endpoint: not running\nRHIZO_DOCTOR_OK warnings=0'
  check_passes "a clean server doctor is accepted" assert_doctor_server x "$DOCTOR_OK"

  check_fails "the wrong resolution is caught" assert_display_geometry x "real 1920 x 1080, density $DISPLAY_DPI" "$DISPLAY_WH" "$DISPLAY_DPI"
  check_fails "the wrong density is caught" assert_display_geometry x "real ${DISPLAY_WH/x/ x }, density 160" "$DISPLAY_WH" "$DISPLAY_DPI"
  check_passes "the configured geometry is accepted" assert_display_geometry x \
    "DisplayInfo{... real ${DISPLAY_WH/x/ x }, density $DISPLAY_DPI (400.0 x 400.0) dpi ...}" "$DISPLAY_WH" "$DISPLAY_DPI"

  check_fails "a density SurfaceFlinger disagrees on is caught" assert_sf_density x 213 "$DISPLAY_DPI"
  check_fails "an unset density is caught" assert_sf_density x "" "$DISPLAY_DPI"
  check_passes "the matching density is accepted" assert_sf_density x "$DISPLAY_DPI" "$DISPLAY_DPI"

  check_fails "no CLIENT TARGET line at all is caught" assert_client_target_painted x "[l3] pivoted" "$DISPLAY_WH"
  check_fails "the wrong sampled size is caught" assert_client_target_painted x \
    "CLIENT TARGET display=0 1920x1080 stride=7680 sampled=100 nonZero=90 (90%) rgbNonZero=85 (85%) first px=ff00ff00" "$DISPLAY_WH"
  check_fails "a black client target is caught" assert_client_target_painted x \
    "CLIENT TARGET display=0 ${DISPLAY_WH} stride=4096 sampled=100 nonZero=2 (2%) rgbNonZero=1 (1%) first px=00000000" "$DISPLAY_WH"
  check_passes "a real painted client target is accepted" assert_client_target_painted x \
    "CLIENT TARGET display=0 ${DISPLAY_WH} stride=4096 sampled=100 nonZero=95 (95%) rgbNonZero=90 (90%) first px=ff00ff00" "$DISPLAY_WH"

  check_predicate() {
    local what="$1" want="$2" got=0
    client_target_is_painted "$3" "$DISPLAY_WH" || got=1
    if (( got == want )); then
      log "  selftest OK: $what"
    else
      fail "selftest: $what -- client_target_is_painted returned $got, wanted $want"
    fi
  }
  check_predicate "the poll predicate rejects no sample, as the assertion does" 1 "[l3] pivoted"
  check_predicate "the poll predicate rejects the wrong size, as the assertion does" 1 \
    "CLIENT TARGET display=0 1920x1080 stride=7680 sampled=100 nonZero=90 (90%) rgbNonZero=85 (85%) first px=ff00ff00"
  check_predicate "the poll predicate rejects a black sample, as the assertion does" 1 \
    "CLIENT TARGET display=0 ${DISPLAY_WH} stride=4096 sampled=100 nonZero=2 (2%) rgbNonZero=1 (1%) first px=00000000"
  check_predicate "the poll predicate rejects the launch-transition frame 3d caught live" 1 \
    "CLIENT TARGET display=1 ${DISPLAY_WH} stride=4096 sampled=49152 nonZero=49152 (100%) rgbNonZero=3072 (6%) first px=000000ff"
  check_predicate "the poll predicate accepts the painted sample the assertion accepts" 0 \
    "CLIENT TARGET display=0 ${DISPLAY_WH} stride=4096 sampled=100 nonZero=95 (95%) rgbNonZero=90 (90%) first px=ff00ff00"

  check_fails "the stock 60s timeout instead of the configured one is caught" assert_screen_off_setting x "60000" "$SCREEN_OFF_S"
  check_fails "an unreadable setting is caught" assert_screen_off_setting x "" "$SCREEN_OFF_S"
  check_passes "the configured timeout in ms is accepted" assert_screen_off_setting x "$((SCREEN_OFF_S * 1000))" "$SCREEN_OFF_S"

  check_fails "a device still awake is caught" assert_display_off x "mWakefulness=Awake" "mState=OFF"
  check_fails "a display still on is caught" assert_display_off x "mWakefulness=Asleep" "mState=ON"
  check_passes "an asleep device with the display off is accepted" assert_display_off x \
    "mWakefulness=Asleep" "DisplayPowerController: mState=OFF"

  check_fails "a counter that never moved is caught" assert_frames_advanced x 40 40
  check_fails "an unreadable counter is caught" assert_frames_advanced x "" ""
  check_passes "an advancing counter is accepted" assert_frames_advanced x 40 900

  check_fails "an advancing counter with the display off is caught" assert_frames_stalled x 40 47
  check_fails "a counter that dropped (composer restart) is caught, not just a rise" assert_frames_stalled x 1240 0
  check_fails "an unreadable counter is caught" assert_frames_stalled x "" ""
  check_passes "a held counter is accepted" assert_frames_stalled x 40 40

  check_fails "a failed install is caught" assert_install_ok x "Failure [INSTALL_FAILED_INVALID_APK]"
  check_passes "a successful install is accepted" assert_install_ok x "Success"

  check_fails "an am start error is caught" assert_launch_ok x "Error: Activity not started, unable to resolve Intent"
  check_fails "a missing Status: ok is caught" assert_launch_ok x "Starting: Intent { ... }"
  check_passes "a real Status: ok is accepted" assert_launch_ok x $'Starting: Intent { ... }\nStatus: ok\nComplete'


  NAT_LAN='-P PREROUTING ACCEPT
-A PREROUTING -i ens3 -p tcp -m tcp --dport 5555 -j DNAT --to-destination 192.168.100.50:5555'
  NAT_TUNNEL='-P PREROUTING ACCEPT
-A PREROUTING -p tcp -m tcp --dport 5555 -j DNAT --to-destination 192.168.100.50:5555'
  check_fails "the product rule present under host is caught" assert_dnat_absent x "$NAT_LAN" ens3
  check_passes "no product rule under host is accepted" assert_dnat_absent x "$NAT_TUNNEL" ens3
  check_fails "an empty result from an incomplete probe is not trusted as 'no rule'" \
    assert_dnat_absent x "" ens3 0
  check_fails "a complete probe with no policy line is not trusted as 'no rule' either" \
    assert_dnat_absent x "" ens3 1
  check_fails "no product rule under lan is caught" assert_dnat_present x '-P PREROUTING ACCEPT' ens3
  check_fails "adb-tunnel.sh's own rule standing in for it is caught" assert_dnat_present x "$NAT_TUNNEL" ens3
  check_passes "the product rule under lan is accepted" assert_dnat_present x "$NAT_LAN" ens3

  check_fails "a launcher that refused to arm is caught" assert_lan_armed_marker x \
    "[l3] server.adb_reach=lan refused to arm: no operator key at /etc/rhizo/adb_keys, rule not created"
  check_fails "a boot with no arming marker is caught" assert_lan_armed_marker x "[l3] pivoted"
  check_passes "the arming marker is accepted" assert_lan_armed_marker x \
    "[l3] server.adb_reach=lan armed: DNAT ens3:5555 -> 192.168.100.50:5555"

  check_fails "an armed marker is caught by the refusal assertion" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan armed: DNAT ens3:5555 -> 192.168.100.50:5555"
  check_fails "no marker at all is caught" assert_lan_refused_marker x "[l3] pivoted"
  check_passes "refused for the wrong profile is accepted" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan refused to arm: rhizo.profile=desktop, not server, rule not created" "not server"
  check_passes "refused for a debuggable image is accepted" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan refused to arm: the GSI is debuggable, rule not created" "debuggable"
  check_passes "refused for RHIZO_ADB_ROOT is accepted" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan refused to arm: RHIZO_ADB_ROOT is set, rule not created" "RHIZO_ADB_ROOT"
  check_passes "refused for RHIZO_PERMISSIVE is accepted" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan refused to arm: RHIZO_PERMISSIVE is set, rule not created" "RHIZO_PERMISSIVE"
  check_passes "refused for no uplink is accepted" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan refused to arm: no default route (no uplink), rule not created" "no default route"
  check_passes "refused for no operator key is accepted" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan refused to arm: no operator key at /etc/rhizo/adb_keys, rule not created" "no operator key"
  check_passes "refused for instance above zero is accepted" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan refused to arm: RHIZO_SANDBOX_ID=2: the DNAT target is single-instance only, rule not created" "single-instance only"
  check_fails "refused but not naming the reason asked for is caught" assert_lan_refused_marker x \
    "[l3] server.adb_reach=lan refused to arm: the GSI is debuggable, rule not created" "no operator key"

  check_fails "the instance>0 marker missing is caught" assert_adb_lan_instance_marker x \
    "[l3] server.adb_reach=lan refused to arm: no operator key at /etc/rhizo/adb_keys, rule not created"
  check_passes "the instance>0 marker is accepted" assert_adb_lan_instance_marker x \
    "[l3] server.adb_reach=lan refused to arm: RHIZO_SANDBOX_ID=2: the DNAT target is single-instance only, rule not created"$'\n'"[l3] RHIZO_MARKER adb_lan_refused=instance_above_zero"

  check_fails "adb root actually granting root is caught" assert_adb_root_refused x \
    "restarting adbd as root" $'uid=0(root) gid=0(root)'
  check_fails "a shell reading uid=0 afterward is caught" assert_adb_root_refused x \
    "adbd cannot run as root in production builds" $'uid=0(root) gid=2000(shell)'
  check_fails "an unreachable adbd printing neither line is caught" assert_adb_root_refused x \
    "error: closed" "error: no devices/emulators found"
  check_fails "a real refusal with no readable id afterward is caught" assert_adb_root_refused x \
    "adbd cannot run as root in production builds" ""
  check_passes "adb root refused on a user build is accepted" assert_adb_root_refused x \
    "adbd cannot run as root in production builds" $'uid=2000(shell) gid=2000(shell)'

  check_fails "adbd answering from the uplink under host is caught" assert_adb_unreachable x device
  check_fails "an unauthorized answer from the uplink under host is caught" assert_adb_unreachable x unauthorized
  check_passes "no answer from the uplink under host is accepted" assert_adb_unreachable x ""

  check_fails "an offline device where one was wanted is caught" assert_adb_state x offline device
  check_passes "a device is accepted" assert_adb_state x device device

  check_fails "a refused veth-side connect is caught" assert_tcp_reachable x 1
  check_passes "an answered veth-side connect is accepted" assert_tcp_reachable x 0

  check_fails "a live share mount under 'over' mode is caught" assert_no_hostfs_mount x \
    $'/dev/root / ext4 rw 0 0\n/dev/fuse /mnt/user/0/emulated/0/Download fuse rw,nosuid,nodev 0 0'
  check_fails "a live share mount under 'under' mode is caught" assert_no_hostfs_mount x \
    $'/dev/root / ext4 rw 0 0\n/dev/fuse /data/media/0/Download fuse rw,nosuid,nodev 0 0'
  check_fails "an empty mount table is caught" assert_no_hostfs_mount x ""
  check_passes "a mount table with no share, and an unrelated fuse mount elsewhere, is accepted" assert_no_hostfs_mount x \
    $'/dev/root / ext4 rw 0 0\ntmpfs /dev tmpfs rw 0 0\n/dev/fuse /mnt/unrelated fuse rw 0 0'

  IDLE_SEED_LINE="started this run's own session count at 0 -- the 0 adb entries already in the conntrack table, phantom or real, are never counted"
  IDLE_NEW_LINE='count=1 NEW tcp reply-src=192.168.100.50:5555'
  NL_HEADER='sk               Eth Pid        Groups   Rmem     Wmem     Dump  Locks    Drops    Inode'
  NL_OTHER='0000000000000000 16  980        00000001 0        0        0     2        0        21455'
  NL_JOINED='0000000000000000 12  3381289462 00000005 0        0        0     2        0        33104'
  NL_UNBOUND='0000000000000000 12  3381289462 00000000 0        0        0     2        0        33104'
  NL_FOREIGN='0000000000000000 12  77         00000005 0        0        0     2        0        99999'
  MY_INODES='33104 33105'
  check_fails "a detector whose child exposes no socket inodes is caught" assert_detector_subscribed x \
    "$NL_HEADER"$'\n'"$NL_JOINED" "" "13359"
  check_fails "a detector that has execve'd but not yet joined a ctnetlink group is caught" assert_detector_subscribed x \
    "$NL_HEADER"$'\n'"$NL_OTHER"$'\n'"$NL_UNBOUND" "$MY_INODES" "13359"
  check_fails "a detector with no netfilter socket at all is caught" assert_detector_subscribed x \
    "$NL_HEADER"$'\n'"$NL_OTHER" "$MY_INODES" "13359"
  check_fails "an empty netlink read is caught" assert_detector_subscribed x "" "$MY_INODES" "13359"
  check_fails "a joined group owned by ANOTHER process is caught" assert_detector_subscribed x \
    "$NL_HEADER"$'\n'"$NL_FOREIGN" "$MY_INODES" "13359"
  check_passes "a subscribed detector is accepted, though its port id is not its pid" assert_detector_subscribed x \
    "$NL_HEADER"$'\n'"$NL_OTHER"$'\n'"$NL_JOINED" "$MY_INODES" "13359"

  check_fails_saying() {
    local what="$1" want="$2" fn="$3"; shift 3
    local before=$FAILED text rc=0
    text=$( "$fn" "$@" 2>&1 ) || rc=$?
    FAILED=$before
    : > "$EV/failures.log"
    if (( rc != 0 )) && grep -qF "$want" <<<"$text"; then
      log "  selftest OK: $what"
    else
      fail "selftest: $what -- wanted a failure saying '$want', got rc=$rc: ${text:-<no output at all>}"
    fi
  }
  check_fails_saying "another process's joined socket is named as belonging to another process" \
    "belong to another process" assert_detector_subscribed x "$NL_HEADER"$'\n'"$NL_FOREIGN" "$MY_INODES" "13359"
  check_fails_saying "an unjoined socket is named as the detector not watching" \
    "NOT yet watching ctnetlink" assert_detector_subscribed x "$NL_HEADER"$'\n'"$NL_UNBOUND" "$MY_INODES" "13359"

  check_subscribed_predicate() {
    local what="$1" want="$2" got=0
    detector_subscribed "$3" "$4" || got=1
    if (( got == want )); then
      log "  selftest OK: $what"
    else
      fail "selftest: $what -- detector_subscribed returned $got, wanted $want"
    fi
  }
  check_subscribed_predicate "the poll predicate rejects empty inodes, as the assertion does" 1 \
    "$NL_HEADER"$'\n'"$NL_JOINED" ""
  check_subscribed_predicate "the poll predicate rejects an unjoined socket, as the assertion does" 1 \
    "$NL_HEADER"$'\n'"$NL_UNBOUND" "$MY_INODES"
  check_subscribed_predicate "the poll predicate rejects another process's joined socket, as the assertion does" 1 \
    "$NL_HEADER"$'\n'"$NL_FOREIGN" "$MY_INODES"
  check_subscribed_predicate "the poll predicate accepts what the assertion accepts" 0 \
    "$NL_HEADER"$'\n'"$NL_JOINED" "$MY_INODES"

  check_fails "a started detector that counted nothing is caught" assert_session_counted x "$IDLE_SEED_LINE"
  check_fails "a DESTROY with no NEW this start ever counted is caught" assert_session_counted x \
    "$IDLE_SEED_LINE"$'\n''count=0 DESTROY tcp reply-src=192.168.100.50:5555'
  check_fails "an empty journal read is caught" assert_session_counted x ""
  check_passes "a counted session is accepted" assert_session_counted x \
    "$IDLE_SEED_LINE"$'\n'"$IDLE_NEW_LINE"

  TEST_SELF=$(basename "${BASH_SOURCE[0]}")
  TEST_REAL_RUN=$(sed -n '/^save_evidence() {$/,$p' "$TEST_SELF")
  [[ -n "$TEST_REAL_RUN" ]] || fail "selftest: could not read $TEST_SELF's own real-run half"
  BARRIER_GOOD=$'SUB_DEADLINE=$((SECONDS + 60))\nwhile (( SECONDS < SUB_DEADLINE )); do\n  SUB_INODES=$(idle_detector_sock_inodes "$SUB_CHILD")\n  SUB_NETLINK=$(idle_netlink)\n  detector_subscribed "$SUB_NETLINK" "$SUB_INODES" && break\n  sleep 1\ndone\nassert_detector_subscribed "4m1. x" "$SUB_NETLINK" "$SUB_INODES" "$SUB_CHILD"\nADB_STATE_4M2=$(uplink_adb_state 120)'
  BARRIER_PORTID=$'SUB_DEADLINE=$((SECONDS + 60))\nwhile (( SECONDS < SUB_DEADLINE )); do\n  SUB_NETLINK=$(idle_netlink)\n  detector_subscribed "$SUB_NETLINK" "$SUB_CHILD" && break\n  sleep 1\ndone\nassert_detector_subscribed "4m1. x" "$SUB_NETLINK" "$SUB_CHILD"\nADB_STATE_4M2=$(uplink_adb_state 120)'
  BARRIER_WEAK=$'SUB_DEADLINE=$((SECONDS + 60))\nwhile (( SECONDS < SUB_DEADLINE )); do\n  SUB_JOURNAL=$(idle_journal "$IDLE_INVOCATION" "$IDLE_SINCE")\n  detector_subscribed "$SUB_JOURNAL" "$SUB_CHILD" && break\n  sleep 2\ndone\nassert_detector_subscribed "4m1. x" "$SUB_JOURNAL" "$SUB_CHILD"\nADB_STATE_4M2=$(uplink_adb_state 120)'
  check_fails "a 4m2 connect with no subscribe wait before it is caught" assert_subscribe_barrier_present x \
    $'assert_unit_active "4m. x" "$IDLE_UNIT" "ActiveState=active"\nADB_STATE_4M2=$(uplink_adb_state 120)'
  check_fails "a bare sleep in place of the wait is caught" assert_subscribe_barrier_present x \
    $'sleep 5\nassert_detector_subscribed "4m1. x" "$SUB_JOURNAL" "$SUB_CHILD"\nADB_STATE_4M2=$(uplink_adb_state 120)'
  check_fails "a wait that stands after the connect is caught" assert_subscribe_barrier_present x \
    $'ADB_STATE_4M2=$(uplink_adb_state 120)\nSUB_DEADLINE=$((SECONDS + 60))\n  SUB_NETLINK=$(idle_netlink)\n  detector_subscribed "$SUB_NETLINK" "$SUB_CHILD" && break\nassert_detector_subscribed "4m1. x" "$SUB_NETLINK" "$SUB_CHILD"'
  check_fails "text with no 4m2 connect in it at all is caught" assert_subscribe_barrier_present x "nothing here"
  check_fails "a barrier that waits on the daemon's own seed line instead of its socket is caught" \
    assert_subscribe_barrier_present x "$BARRIER_WEAK"
  check_fails "a barrier that identifies the socket by port id instead of inode is caught" \
    assert_subscribe_barrier_present x "$BARRIER_PORTID"
  check_passes "the shape the real run must have is accepted" assert_subscribe_barrier_present x "$BARRIER_GOOD"

  FLIP_GOOD=$'ENFORCE=1\nBTIME=1790471825\nFLIP=1790471868.545 real enforce flip: wrote 1 (kernel enforce now=1)\nRHIZO_FLIP_DONE'
  check_passes "a flip written this boot with enforce=1 is accepted" assert_enforce_flipped x "$FLIP_GOOD"
  check_passes "a flip already done earlier this boot is accepted" assert_enforce_flipped x \
    "${FLIP_GOOD/wrote 1 (kernel enforce now=1)/already enforcing; no marker wait, no write}"
  check_fails "enforce=0 is caught" assert_enforce_flipped x "${FLIP_GOOD/ENFORCE=1/ENFORCE=0}"
  check_fails "a flip line from an earlier boot is caught" assert_enforce_flipped x "${FLIP_GOOD/FLIP=1790471868/FLIP=1790400000}"
  check_fails "a failed flip is caught" assert_enforce_flipped x \
    "${FLIP_GOOD/wrote 1 (kernel enforce now=1)/FAILED: [Errno 13] Permission denied}"
  check_fails "no flip line is caught" assert_enforce_flipped x "${FLIP_GOOD/FLIP=*real enforce flip: wrote 1 (kernel enforce now=1)/FLIP=}"
  check_fails "a probe with no trailing tag is caught" assert_enforce_flipped x "${FLIP_GOOD%RHIZO_FLIP_DONE}"
  check_fails "0k with no flip wait before it is caught" assert_flip_wait_before_0k x \
    $'UNREG_STATE=$(_test_key_adb_state "$TEST_KEY_HOME" 20)\nFLIP_READ=$(await_enforce_flip 120)'
  check_fails "a wait whose result is never asserted is caught" assert_flip_wait_before_0k x \
    $'FLIP_READ=$(await_enforce_flip 120)\nUNREG_STATE=$(_test_key_adb_state "$TEST_KEY_HOME" 20)'
  REVOKE_OK="[rhizo] revoked ABCD from the running sandbox's /adb_keys and restarted adbd"$'\n'"RHIZO_ADBKEY removed=1"
  check_passes "a live revoke that ended the session and left the sandbox up is accepted" \
    assert_live_revoke x "$REVOKE_OK" unauthorized 4242 4242 closed
  check_fails "a revoked key that still authorizes is caught" assert_live_revoke x "$REVOKE_OK" device 4242 4242 closed
  check_fails "a revoke that restarted the sandbox is caught" assert_live_revoke x "$REVOKE_OK" unauthorized 4242 5151 closed
  check_fails "a revoke that left the key's open session running is caught" \
    assert_live_revoke x "$REVOKE_OK" unauthorized 4242 4242 open
  check_fails "a remove that never reached the running sandbox is caught" \
    assert_live_revoke x "RHIZO_ADBKEY removed=1" unauthorized 4242 4242 closed
  check_fails "a remove that removed nothing is caught" \
    assert_live_revoke x "${REVOKE_OK/removed=1/removed=0}" unauthorized 4242 4242 closed
  check_fails "an unread init pid is caught" assert_live_revoke x "$REVOKE_OK" unauthorized "" "" closed
  grep -q 'assert_live_revoke "0p. ' <<<"$TEST_REAL_RUN" \
    || fail "selftest: the real run no longer proves adb-key remove revokes live (0p)"
  check_passes "a flip wait asserted before 0k is accepted" assert_flip_wait_before_0k x \
    $'FLIP_READ=$(await_enforce_flip 120)\nassert_enforce_flipped "0j3. x" "$FLIP_READ"\nUNREG_STATE=$(_test_key_adb_state "$TEST_KEY_HOME" 20)'
  assert_flip_wait_before_0k "selftest: this system test's own wait for the enforce flip still precedes 0k" "$TEST_REAL_RUN"
  assert_subscribe_barrier_present "selftest: this system test's own 4m2 precondition is still in place" "$TEST_REAL_RUN"

  check_fails "an unarmed idle timer is caught" assert_idle_timer_armed x "ActiveState=inactive"
  check_passes "an armed idle timer is accepted" assert_idle_timer_armed x "ActiveState=active"

  check_fails "the wrong androidd state is caught" assert_androidd_state x "active" "inactive"
  check_passes "the wanted androidd state is accepted" assert_androidd_state x "inactive" "inactive"

  check_fails "a missing dependency is caught" assert_present x "no rhizo on the guest" ""
  check_passes "a present dependency is accepted" assert_present x "rhizo" "/usr/bin/rhizo"

  if (( FAILED )); then
    log "test-server --selftest: FAILED"
    exit 1
  fi
  log "test-server --selftest: the system test can still fail"
  exit 0
fi

# write text to an evidence file
save_evidence() {
  printf '%s\n' "$2" > "$EV/$1"
}

for _ev_name in adb-key.txt androidd.env boot.log deps.txt doctor.txt \
    dumpsys-display-off.txt dumpsys-display-on.txt dumpsys-power-off.txt \
    nat-host.txt nat-lan.txt nat-no-key.txt policy.conf \
    profile-desktop-baseline.txt profile-desktop-cleanup.txt profile.txt \
    sandbox-mounts.txt status.json \
    step2-client-target.txt \
    redeploy-stage.log androidd-start.log adb-tunnel-step1.log \
    adb-tunnel-teardown.log adb-tunnel-teardown-2.log \
    restart-after-keyadd.log restart-to-lan.log restart-no-key.log \
    restart-key-restored.log reboot-software.log adb-tunnel-bridge-only-software.log restart-after-idle.log \
    restart-screen-off-check.log idle-restart.log idle-journal.txt \
    idle-netlink.txt idle-conntrack-sockets.txt; do
  save_evidence "$_ev_name" "<none: this run did not reach the step that writes $_ev_name>"
done
unset _ev_name

step "0. a vm with no compositor, staged, configured for the server profile"

BOOT_ARGS=(--skip-graphics-preflight)
[[ -n "${RHIZO_RELEASE:-}" ]] && BOOT_ARGS+=(--release "$RHIZO_RELEASE")
test_boot "${BOOT_ARGS[@]}" || { test_record_verdict FAILED; exit 1; }
cleanup_hostfs_conf

../../vm/sync.sh >/dev/null || { fail "0. sync.sh failed"; test_record_verdict FAILED; exit 1; }
STAGE_LOG="$EV/redeploy-stage.log"
if ! ../../vm/redeploy.sh --skip-kill --no-launch > "$STAGE_LOG" 2>&1; then
  fail "0. redeploy.sh --no-launch failed -- see $STAGE_LOG"
  test_record_verdict FAILED
  exit 1
fi
pass "0. staged with no launch (nothing has started Android yet)"

DEPS=$(ssh_vm -t 20 'command -v rhizo; command -v adb;
  test -f /usr/lib/systemd/system/'"$IDLE_UNIT"' && echo unit-staged;
  test -r /usr/lib/rhizo/server-idle/server-idle.py && echo idle-script-staged' 2>/dev/null)
save_evidence deps.txt "$DEPS"
assert_present "0a. the CLI is staged" "no /usr/bin/rhizo (redeploy.sh stage_cmd installs it from share/install/cli/rhizo.sh)" \
  "$(grep -m1 '^/usr/bin/rhizo$' <<<"$DEPS")"
assert_present "0c. the idle unit is staged" \
  "no /usr/lib/systemd/system/$IDLE_UNIT" \
  "$(grep -m1 '^unit-staged$' <<<"$DEPS")"
assert_present "0d. the idle daemon is staged" \
  "no /usr/lib/rhizo/server-idle/server-idle.py" \
  "$(grep -m1 '^idle-script-staged$' <<<"$DEPS")"

ssh_vm -t 15 "rm -f $RIG_KEY_GUEST $OPERATOR_KEYS" >/dev/null 2>&1
assert_present "0e0. the rig's own key file is really gone from the guest" \
  "rm did not remove $RIG_KEY_GUEST" \
  "$(ssh_vm -t 10 "test ! -e $RIG_KEY_GUEST && echo removed" 2>/dev/null)"
assert_present "0e0b. the operator key file is really gone from the guest" \
  "rm did not remove $OPERATOR_KEYS" \
  "$(ssh_vm -t 10 "test ! -e $OPERATOR_KEYS && echo removed" 2>/dev/null)"

TEST_KEY_DIR="$EV/systestkey"
mkdir -p "$TEST_KEY_DIR"
rm -f "$TEST_KEY_DIR/adbkey" "$TEST_KEY_DIR/adbkey.pub"
KEYGEN_OUT=$("$ADB" keygen "$TEST_KEY_DIR/adbkey" 2>&1)
assert_present "0e1. a new adb keypair generated for this run" \
  "adb keygen failed: $KEYGEN_OUT" "$([[ -s "$TEST_KEY_DIR/adbkey.pub" ]] && echo "$TEST_KEY_DIR/adbkey.pub")"

TEST_ADB_SERVER_PORT=$((6037 + RHIZO_VM))

# restart androidd.service and recreate the adb bridge
restart_androidd() {
  ssh_vm -t 300 'systemctl restart androidd.service' > "$EV/$1" 2>&1
  INIT=$(resolve_init 180)
  [[ -n "$INIT" ]] || return 1
  ../../vm/boot/adb-tunnel.sh bridge-only > "$EV/adb-tunnel-bridge-only-${1%.log}.log" 2>&1
  return 0
}

# print the adb state for a key
_test_key_adb_state() {
  local key_home="$1" deadline=$((SECONDS + $2)) state=""
  HOME="$key_home" ANDROID_ADB_SERVER_PORT="$TEST_ADB_SERVER_PORT" "$ADB" kill-server >/dev/null 2>&1
  while (( SECONDS < deadline )); do
    HOME="$key_home" ANDROID_ADB_SERVER_PORT="$TEST_ADB_SERVER_PORT" "$ADB" disconnect "$ADB_TARGET" >/dev/null 2>&1
    HOME="$key_home" ANDROID_ADB_SERVER_PORT="$TEST_ADB_SERVER_PORT" "$ADB" connect "$ADB_TARGET" >/dev/null 2>&1
    state=$(HOME="$key_home" ANDROID_ADB_SERVER_PORT="$TEST_ADB_SERVER_PORT" "$ADB" devices \
      | awk -v want="$ADB_TARGET" '$1==want{print $2}')
    [[ -n "$state" && "$state" != offline ]] && break
    sleep 2
  done
  printf '%s' "$state"
}
TEST_KEY_HOME="$EV/testkey-home"
mkdir -p "$TEST_KEY_HOME/.android"
cp "$TEST_KEY_DIR/adbkey" "$TEST_KEY_HOME/.android/adbkey"
cp "$TEST_KEY_DIR/adbkey.pub" "$TEST_KEY_HOME/.android/adbkey.pub"

POLICY_TEXT=$(write_policy host "$IDLE_STOP_LONG_S" on)
save_evidence policy.conf "$POLICY_TEXT"
assert_policy_written "0f. the server policy" "$POLICY_TEXT" host "$IDLE_STOP_LONG_S" on

DESKTOP_BASELINE_OUT=$(ssh_vm -t 60 "rhizo profile desktop" 2>&1)
DESKTOP_BASELINE_RC=$?
save_evidence profile-desktop-baseline.txt "$DESKTOP_BASELINE_OUT"
if (( DESKTOP_BASELINE_RC != 0 )); then
  fail "0f0. 'rhizo profile desktop' exited $DESKTOP_BASELINE_RC -- see $EV/profile-desktop-baseline.txt"
fi
for u in "${MASKED_UNITS[@]}"; do
  assert_unit_unmasked "0f1. $u unmasked under the desktop baseline" "$u" \
    "$(ssh_vm -t 10 "systemctl show -p LoadState,ActiveState $u" 2>/dev/null)"
done
assert_unit_masked "0f2. $IDLE_UNIT masked under the desktop baseline" "$IDLE_UNIT" \
  "$(ssh_vm -t 10 "systemctl show -p LoadState,ActiveState $IDLE_UNIT" 2>/dev/null)"

PROFILE_OUT=$(ssh_vm -t 60 "rhizo profile server" 2>&1)
save_evidence profile.txt "$PROFILE_OUT"
assert_profile_applied "0g. rhizo profile server" "$PROFILE_OUT"
assert_profile_applied "0h. rhizo profile show" "$(ssh_vm -t 20 'rhizo profile show' 2>&1)"

ENV_CMD="grep -Ev '^(RHIZO_RESIDENT_G|RHIZO_RESIDENT_DISPATCH|RHIZO_COMPOSER_DEBUG|RHIZO_GSI|RHIZO_RELEASE)=' $ANDROIDD_ENV > $ANDROIDD_ENV.test-tmp 2>/dev/null || : > $ANDROIDD_ENV.test-tmp"
ENV_CMD+=$'\n'"echo 'RHIZO_RESIDENT_G=1' >> $ANDROIDD_ENV.test-tmp"
ENV_CMD+=$'\n'"echo 'RHIZO_RESIDENT_DISPATCH=1' >> $ANDROIDD_ENV.test-tmp"
ENV_CMD+=$'\n'"echo 'RHIZO_COMPOSER_DEBUG=1' >> $ANDROIDD_ENV.test-tmp"
[[ -n "${RHIZO_GSI:-}" ]] && ENV_CMD+=$'\n'"echo 'RHIZO_GSI=$RHIZO_GSI' >> $ANDROIDD_ENV.test-tmp"
[[ -n "${RHIZO_RELEASE:-}" ]] && ENV_CMD+=$'\n'"echo 'RHIZO_RELEASE=$RHIZO_RELEASE' >> $ANDROIDD_ENV.test-tmp"
ENV_CMD+=$'\n'"mv $ANDROIDD_ENV.test-tmp $ANDROIDD_ENV || echo RHIZO_ENV_MV_FAILED"
ENV_CMD+=$'\n'"cat $ANDROIDD_ENV"
ANDROIDD_ENV_TEXT=$(ssh_vm -t 20 "$ENV_CMD")
save_evidence androidd.env "$ANDROIDD_ENV_TEXT"
assert_present "0i. androidd.service's environment file" \
  "could not write $ANDROIDD_ENV" \
  "$(grep -m1 '^RHIZO_RESIDENT_G=1$' <<<"$ANDROIDD_ENV_TEXT")"
if grep -q 'RHIZO_ENV_MV_FAILED' <<<"$ANDROIDD_ENV_TEXT"; then
  fail "0i1. the environment file was published, not left as the old one: the mv onto $ANDROIDD_ENV failed"
else
  pass "0i1. the environment file was published, not left as the old one"
fi
assert_present "0i2. redeploy.sh's own record survived the merge" \
  "the merge produced an androidd.env with no RHIZO_WIPE_DATA= line" \
  "$(grep -m1 '^RHIZO_WIPE_DATA=' <<<"$ANDROIDD_ENV_TEXT")"

if (( FAILED )); then
  log "test-server: the vm is not configured for the server profile, refusing to spend a boot"
  test_record_verdict FAILED
  exit 1
fi

ssh_vm -t 20 ": > $BOOT_LOG" >/dev/null 2>&1
ssh_vm -t 60 'systemctl start androidd.service' > "$EV/androidd-start.log" 2>&1
INIT=$(resolve_init 180)
if [[ -z "$INIT" ]]; then
  save_evidence boot.log "$(ssh_vm -t 20 "tail -80 $BOOT_LOG")"
  fail "0j. no init second_stage after systemctl start androidd.service -- see $EV/boot.log"
  test_record_verdict FAILED
  exit 1
fi
pass "0j. androidd.service started the sandbox, init pid=$INIT"

BRIDGE_LOG="$EV/adb-tunnel-bridge-only.log"
../../vm/boot/adb-tunnel.sh bridge-only > "$BRIDGE_LOG" 2>&1
BRIDGE_RC=$?
if (( BRIDGE_RC != 0 )); then
  fail "0j2. adb-tunnel.sh bridge-only failed (rc=$BRIDGE_RC) -- see $BRIDGE_LOG"
  test_record_verdict FAILED
  exit 1
fi

FLIP_READ=$(await_enforce_flip 300)
save_evidence enforce-flip.txt "$FLIP_READ"
assert_enforce_flipped "0j3. the host's real enforce flip is done before any adb or CLI read" "$FLIP_READ"
UNREG_STATE=$(_test_key_adb_state "$TEST_KEY_HOME" 20)
assert_adb_state "0k. an unregistered key reads unauthorized" "$UNREG_STATE" unauthorized

save_evidence adb-key-stdio.txt "$(ssh_vm -t 30 "grep ^flags /proc/self/fdinfo/1 /proc/self/fdinfo/2; readlink /proc/self/fd/1 /proc/self/fd/2; cat /proc/self/attr/current; echo" < "$TEST_KEY_DIR/adbkey.pub" 2>&1)"
KEY_ADD=$(ssh_vm -t 30 "rhizo adb-key add -" < "$TEST_KEY_DIR/adbkey.pub" 2>&1)
KEY_LIST=$(ssh_vm -t 20 "rhizo adb-key list" 2>&1)
save_evidence adb-key.txt "$KEY_ADD"$'\n'"$KEY_LIST"
assert_adbkey_registered "0l. the new key, registered through the CLI's own verb" "$KEY_ADD" "$KEY_LIST"

KEY_ADD2=$(ssh_vm -t 30 "rhizo adb-key add -" < "$RIG_ADB_KEY" 2>&1)
assert_adbkey_registered "0m. the rig's own key, registered alongside it" "$KEY_ADD2" "$(ssh_vm -t 20 "rhizo adb-key list" 2>&1)"

ssh_vm -t 20 ": > $BOOT_LOG" >/dev/null 2>&1
if ! restart_androidd restart-after-keyadd.log; then
  fail "0n. no init second_stage after the restart that stages the registered keys"
else
  pass "0n. the sandbox restarted with the registered keys staged, init pid=$INIT"
  REG_STATE=$(_test_key_adb_state "$TEST_KEY_HOME" 30)
  assert_adb_state "0o. the newly registered key authorizes with no dialog" "$REG_STATE" device
  HOME="$TEST_KEY_HOME" ANDROID_ADB_SERVER_PORT="$TEST_ADB_SERVER_PORT" "$ADB" -s "$ADB_TARGET" shell sleep 600 \
    > "$EV/revoke-session.log" 2>&1 &
  REVOKE_SESSION=$!
  INIT_BEFORE_REVOKE="$INIT"
  TEST_FPR=$(awk '{print $1}' "$TEST_KEY_DIR/adbkey.pub" | base64 -d 2>/dev/null | md5sum | awk '{print $1}' \
    | sed 's/\(..\)/\1:/g; s/:$//' | tr 'a-f' 'A-F')
  REVOKE_OUT=$(ssh_vm -t 60 "rhizo adb-key remove $TEST_FPR" 2>&1)
  save_evidence adb-key-revoke.txt "fingerprint=$TEST_FPR"$'\n'"$REVOKE_OUT"
  SESSION_STATE=open
  for _ in $(seq 1 30); do kill -0 "$REVOKE_SESSION" 2>/dev/null || { SESSION_STATE=closed; break; }; sleep 1; done
  kill "$REVOKE_SESSION" 2>/dev/null
  REVOKED_STATE=$(_test_key_adb_state "$TEST_KEY_HOME" 30)
  INIT_AFTER_REVOKE=$(resolve_init 20 2>/dev/null)
  assert_live_revoke "0p. adb-key remove revokes the registered key live" "$REVOKE_OUT" "$REVOKED_STATE" \
    "$INIT_BEFORE_REVOKE" "$INIT_AFTER_REVOKE" "$SESSION_STATE"
fi
ANDROID_ADB_SERVER_PORT="$TEST_ADB_SERVER_PORT" "$ADB" kill-server >/dev/null 2>&1

step "1. boot_completed over adb alone, a headless boot, the desktop units masked"

TUNNEL_LOG="$EV/adb-tunnel-step1.log"
../../vm/boot/adb-tunnel.sh up > "$TUNNEL_LOG" 2>&1
TUNNEL_RC=$?
assert_adb_no_tap "1a. a registered key authorizes with no dialog" "$(cat "$TUNNEL_LOG")"
if (( TUNNEL_RC == 0 )); then
  assert_boot_completed "1b. sys.boot_completed, read over adb" "$(adb_boot_completed 300)"
else
  fail "1b. adb-tunnel.sh exited $TUNNEL_RC -- see $TUNNEL_LOG"
fi

if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then
  dm_out=$(ssh_vm -t 90 "$DESK_STOP_GREETER" 2>&1)
  [[ "$dm_out" == inactive || "$dm_out" == failed ]] || fail "1c0. putting the cachyos vm in the server posture (no display manager, no greeter): $dm_out"
fi
WL_RAW=$(probe_ssh 15 "$DESK_WAYLAND_LISTENERS; ls -1 /run/rhizo-wayland/* 2>/dev/null")
WL=$(probe_ssh_result "$WL_RAW"); WL_COMPLETE=$?
assert_no_wayland_socket "1c. nothing published a compositor socket" "$WL" $(( WL_COMPLETE == 0 ))
desk_up_err=$(desk_session_up 2>&1 >/dev/null); desk_up_rc=$?
if (( desk_up_rc == 0 )); then
  pass "1c2. desk_session_up (server profile) confirms no compositor socket exists"
else
  fail "1c2. desk_session_up (server profile) found a compositor socket: ${desk_up_err:-no detail}"
fi
HL_MARK=""; HL_DEADLINE=$((SECONDS + 60))
while (( SECONDS < HL_DEADLINE )); do
  HL_MARK=$(guest_marker 'wayland socket NOT FOUND')
  [[ -n "$HL_MARK" ]] && break
  sleep 2
done
assert_headless_marker "1d. the launcher's own headless marker" "$HL_MARK"
COMPOSITOR_RAW=$(probe_ssh 10 'pgrep -x sway; pgrep -x weston')
COMPOSITOR_PS=$(probe_ssh_result "$COMPOSITOR_RAW"); COMPOSITOR_COMPLETE=$?
assert_no_compositor_process "1e. no compositor process" "$COMPOSITOR_PS" $(( COMPOSITOR_COMPLETE == 0 ))

for u in "${MASKED_UNITS[@]}"; do
  assert_unit_masked "1f. $u" "$u" "$(ssh_vm -t 10 "systemctl show -p LoadState,ActiveState $u" 2>/dev/null)"
done
assert_unit_active "1g. $IDLE_UNIT" "$IDLE_UNIT" "$(ssh_vm -t 10 "systemctl show -p LoadState,ActiveState $IDLE_UNIT" 2>/dev/null)"

STATUS_JSON=$(ssh_vm -t 60 'rhizo status --json' 2>/dev/null | tail -1)
save_evidence status.json "$STATUS_JSON"
assert_status_json "1h. rhizo status --json" "$STATUS_JSON"
DOCTOR_OUT=$(ssh_vm -t 90 'rhizo doctor' 2>&1)
save_evidence doctor.txt "$DOCTOR_OUT"
assert_doctor_server "1i. rhizo doctor under the server profile" "$DOCTOR_OUT"

SERIAL=$(adb_endpoint_now)
SANDBOX_IP="${SERIAL%%:*}"
assert_present "1j. the adb endpoint the CLI reports" \
  "rhizo status --json named no adb endpoint" "$SERIAL"

step "2. the configured geometry, a painted frame, and the display going off"

android_sh "$INIT" "settings put global stay_on_while_plugged_in 0" >/dev/null 2>&1

DD=$(android_sh "$INIT" "dumpsys display" 2>/dev/null)
save_evidence dumpsys-display-on.txt "$DD"
assert_display_geometry "2a. the configured geometry" "$DD" "$DISPLAY_WH" "$DISPLAY_DPI"
assert_sf_density "2b. SurfaceFlinger's own density" \
  "$(adbx shell getprop ro.sf.lcd_density 2>/dev/null | tr -d '\r\n')" "$DISPLAY_DPI"

assert_present "2b1. /dev/dri/renderD128 or card0 is visible with devices.dri on (the probe's positive control)" \
  "neither node is visible even with devices.dri on" \
  "$(android_sh "$INIT" "test -e /dev/dri/renderD128 -o -e /dev/dri/card0 && echo present" 2>/dev/null)"

SETTINGS_DIR=/data/system/users/0
CORRUPT_MS=612345000
BASELINE_MTIME=$(android_sh "$INIT" "toybox stat -c %y $SETTINGS_DIR" 2>/dev/null | tr -d '\n')
PUT_MS=$(( $(date +%s%N) / 1000000 ))
android_sh "$INIT" "settings put system screen_off_timeout $CORRUPT_MS" >/dev/null 2>&1
LANDED=0
LANDED_DEADLINE_MS=$(( $(date +%s%N) / 1000000 + 30000 ))
while :; do
  MTIME=$(android_sh "$INIT" "toybox stat -c %y $SETTINGS_DIR" 2>/dev/null | tr -d '\n')
  NOW_MS=$(( $(date +%s%N) / 1000000 ))
  if [[ -n "$MTIME" && "$MTIME" != "$BASELINE_MTIME" ]] && (( NOW_MS - PUT_MS >= 2000 )); then
    LANDED=1
    break
  fi
  (( NOW_MS >= LANDED_DEADLINE_MS )) && break
  sleep 2
done
(( LANDED )) || fail "2b2. the corrupted screen_off_timeout ($CORRUPT_MS) never reached $SETTINGS_DIR on disk (no rename seen since the put, or too soon after it)"

android_sh "$INIT" sync >/dev/null 2>&1
ssh_vm -t 20 ": > $BOOT_LOG" >/dev/null 2>&1
if ! restart_androidd restart-screen-off-check.log; then
  fail "2b2. no init second_stage after the screen_off_timeout regression-proof restart"
else
  BC=$(adb_boot_completed 180)
  if [[ "$BC" != 1 ]]; then
    fail "2b2. sys.boot_completed never read 1 after the restart"
  elif (( LANDED )); then
    assert_screen_off_setting "2b2. screen_off_timeout reapplied after a restart, over a corrupted persisted value" \
      "$(android_sh "$INIT" "settings get system screen_off_timeout" 2>/dev/null)" "$SCREEN_OFF_S"
  fi
fi
if [[ -n "${INIT:-}" ]]; then
  android_sh "$INIT" "settings put system screen_off_timeout $((SCREEN_OFF_S * 1000))" >/dev/null 2>&1
fi

if [[ ! -f "$FIXTURE_APK" ]]; then
  fail "2c. no $FIXTURE_APK -- run tools/build/test-apps/fpsapp.sh"
else
  assert_install_ok "2c. the fixture installs over adb" "$(adbx install -r -g "$FIXTURE_APK" 2>&1)"
  wake_display "$INIT"
  CT_SENTINEL=$(guest_sentinel)
  if [[ -z "$CT_SENTINEL" ]]; then
    fail "2d. could not place a dmesg sentinel before launch"
  fi
  assert_launch_ok "2d. the fixture launches" "$(adbx shell am start -W -n "$FIXTURE_ACT" 2>&1)"

  CT_LOG=""; CT_DEADLINE=$((SECONDS + 30))
  while (( SECONDS < CT_DEADLINE )); do
    CT_LOG=$(guest_marker_since "$CT_SENTINEL" 'CLIENT TARGET display=')
    if [[ -n "$CT_LOG" ]]; then
      CT_PROBE_PCT=$(grep -oE 'rgbNonZero=[0-9]+ \([0-9]+%\)' <<<"$CT_LOG" | tail -1 | grep -oE '[0-9]+%' | tr -d '%')
      [[ "$CT_PROBE_PCT" =~ ^[0-9]+$ ]] && (( CT_PROBE_PCT > CLIENT_TARGET_MIN_RGB_PCT )) && break
    fi
    sleep 2
  done
  save_evidence step2-client-target.txt "$CT_LOG"
  assert_client_target_painted "2e. the composer's client-target sample" "$CT_LOG" "$DISPLAY_WH"

  wake_display "$INIT"
  COUNT_ON_BEFORE=$(presented_count "$INIT")
  sleep "$FRAME_WINDOW_S"
  COUNT_ON_AFTER=$(presented_count "$INIT")
  assert_frames_advanced "2f. the presented-frame counter over ${FRAME_WINDOW_S}s with the display ON" \
    "$COUNT_ON_BEFORE" "$COUNT_ON_AFTER"
fi

OFF_DEADLINE=$((SECONDS + SCREEN_OFF_S + 90))
PW=""; DDOFF=""
while (( SECONDS < OFF_DEADLINE )); do
  PW=$(android_sh "$INIT" "dumpsys power" 2>/dev/null)
  DDOFF=$(android_sh "$INIT" "dumpsys display" 2>/dev/null)
  [[ "$(grep -m1 -oE 'mWakefulness=[A-Za-z]+' <<<"$PW")" == "mWakefulness=Asleep" ]] && break
  sleep 5
done
save_evidence dumpsys-power-off.txt "$PW"
save_evidence dumpsys-display-off.txt "$DDOFF"
assert_display_off "2g. the display after screen_off_s=${SCREEN_OFF_S}s with no input" "$PW" "$DDOFF"

COUNT_OFF_BEFORE=$(presented_count "$INIT")
sleep "$FRAME_WINDOW_S"
COUNT_OFF_AFTER=$(presented_count "$INIT")
assert_frames_stalled "2h. the presented-frame counter over ${FRAME_WINDOW_S}s with the display OFF" \
  "$COUNT_OFF_BEFORE" "$COUNT_OFF_AFTER"

step "3. the fixture installs and launches over adb and over the staged CLI"

wake_display "$INIT"
assert_install_ok "3a. pm install over adb" "$(adbx install -r -g "$FIXTURE_APK" 2>&1)"
assert_launch_ok "3b. am start -W over adb" "$(adbx shell am start -W -n "$FIXTURE_ACT" 2>&1)"
adbx shell am force-stop "$FIXTURE_PKG" >/dev/null 2>&1
assert_launch_ok "3c. am start -W over 'rhizo shell --', the host-side channel" \
  "$(ssh_vm -t 60 "rhizo shell -- am start -W -n $FIXTURE_ACT" 2>&1)"

FIXTURE_ON_GUEST=/data/local/tmp/test-server-fixture.apk
adbx uninstall "$FIXTURE_PKG" >/dev/null 2>&1
PUSH_OUT=$(adbx push "$FIXTURE_APK" "$FIXTURE_ON_GUEST" 2>&1)
assert_present "3c2. the fixture apk pushed to the guest for the rhizo-shell install" \
  "adb push did not report success: $PUSH_OUT" "$(grep -m1 -i pushed <<<"$PUSH_OUT")"
assert_install_ok "3c3. pm install over 'rhizo shell --', the host-side channel" \
  "$(ssh_vm -t 60 "rhizo shell -- pm install -r -g $FIXTURE_ON_GUEST" 2>&1)"
adbx shell rm -f "$FIXTURE_ON_GUEST" >/dev/null 2>&1

CT3_SENTINEL=$(guest_sentinel)
if [[ -z "$CT3_SENTINEL" ]]; then
  fail "3d. could not place a dmesg sentinel"
else
  wake_display "$INIT"
  adbx shell am start -W -n "$FIXTURE_ACT" >/dev/null 2>&1
  CT_3D=""; CT3_DEADLINE=$((SECONDS + 60))
  while (( SECONDS < CT3_DEADLINE )); do
    CT_3D=$(guest_marker_since "$CT3_SENTINEL" 'CLIENT TARGET display=')
    client_target_is_painted "$CT_3D" "$DISPLAY_WH" && break
    sleep 2
  done
  save_evidence step3-client-target.txt "$CT_3D"
  assert_client_target_painted "3d. a still frame is retrievable from the composer's client target after the host-channel install (screen RECORDING is out of scope: no in-guest encoder by design, the server-mode design)" \
    "$CT_3D" "$DISPLAY_WH"
fi

step "4. adb_reach both ways, no host share, and the idle-stop cycle"

../../vm/boot/adb-tunnel.sh up --stop > "$EV/adb-tunnel-teardown.log" 2>&1
UPLINK=$(ssh_vm -t 10 "ip -4 route show default | awk '{print \$5; exit}'" 2>/dev/null | tr -d '[:space:]')
assert_present "4a. the guest's uplink interface" "no default route on the guest" "$UPLINK"

NAT_HOST_RAW=$(probe_ssh 10 'iptables -t nat -S PREROUTING')
NAT_HOST=$(probe_ssh_result "$NAT_HOST_RAW"); NAT_HOST_COMPLETE=$?
save_evidence nat-host.txt "$NAT_HOST"
[[ -n "$UPLINK" ]] && assert_dnat_absent "4b. adb_reach=host" "$NAT_HOST" "$UPLINK" $(( NAT_HOST_COMPLETE == 0 ))
assert_adb_unreachable "4c. adb_reach=host, from the uplink side" "$(uplink_adb_state 20)"
SANDBOX_IP="$(adb_endpoint_now)"; SANDBOX_IP="${SANDBOX_IP%%:*}"
if [[ -n "$SANDBOX_IP" ]]; then
  assert_tcp_reachable "4d. adb_reach=host, from the veth side" "$(veth_probe_rc "$SANDBOX_IP")"
else
  fail "4d. no sandbox address"
fi

POLICY_TEXT=$(write_policy lan "$IDLE_STOP_LONG_S" on)
assert_policy_written "4e. the policy flipped to adb_reach=lan" "$POLICY_TEXT" lan "$IDLE_STOP_LONG_S" on
HOSTFS_CONF_TEXT=$(ssh_vm -t 15 "install -d -m 0755 /etc/rhizo && printf '[Download]\ndir=/root\nuser=root\n' > /etc/rhizo/hostfs.conf && cat /etc/rhizo/hostfs.conf" 2>/dev/null)
assert_present "4e2. the hostfs.conf a real share is configured with" \
  "the write to /etc/rhizo/hostfs.conf did not read back" \
  "$(grep -m1 '^\[Download\]$' <<<"$HOSTFS_CONF_TEXT")"
ssh_vm -t 20 ": > $BOOT_LOG" >/dev/null 2>&1
LAN_SENTINEL=$(guest_sentinel)
[[ -n "$LAN_SENTINEL" ]] || fail "4f. could not place a dmesg sentinel before the lan restart"
if ! restart_androidd restart-to-lan.log; then
  fail "4f. no init second_stage after the restart onto adb_reach=lan"
else
  NAT_LAN=$(ssh_vm -t 10 'iptables -t nat -S PREROUTING' 2>/dev/null)
  save_evidence nat-lan.txt "$NAT_LAN"
  [[ -n "$UPLINK" ]] && assert_dnat_present "4f. adb_reach=lan" "$NAT_LAN" "$UPLINK"
  assert_lan_armed_marker "4g. the launcher's own account of the rule" "$(guest_marker_since "$LAN_SENTINEL" 'server.adb_reach=lan')"
  assert_adb_state "4h. adb_reach=lan, from the uplink side" "$(uplink_adb_state 300)" device
  assert_boot_completed "4i. sys.boot_completed over that connection" "$(adb_boot_completed 300)"

  ROOT_OUT=$(adbx root 2>&1)
  sleep 2
  ID_OUT=$(adbx shell id 2>&1)
  assert_adb_root_refused "4i2. adb root over the armed lan path is refused" "$ROOT_OUT" "$ID_OUT"

  MOUNTS=$(android_sh "$INIT" "cat /proc/mounts" 2>/dev/null)
  save_evidence sandbox-mounts.txt "$MOUNTS"
  assert_no_hostfs_mount "4j. no share under adb_reach=lan, with one genuinely configured" "$MOUNTS"
  assert_unit_masked "4k. rhizo-hostfs.service" rhizo-hostfs.service \
    "$(ssh_vm -t 10 'systemctl show -p LoadState,ActiveState rhizo-hostfs.service' 2>/dev/null)"
fi
cleanup_hostfs_conf

ssh_vm -t 15 ": > $OPERATOR_KEYS" >/dev/null 2>&1
ssh_vm -t 20 ": > $BOOT_LOG" >/dev/null 2>&1
NOKEY_SENTINEL=$(guest_sentinel)
[[ -n "$NOKEY_SENTINEL" ]] || fail "4s0. could not place a dmesg sentinel before the no-key restart"
if ! restart_androidd restart-no-key.log; then
  fail "4s0. no init second_stage after the no-key restart"
else
  NAT_NOKEY_RAW=$(probe_ssh 10 'iptables -t nat -S PREROUTING')
  NAT_NOKEY=$(probe_ssh_result "$NAT_NOKEY_RAW"); NAT_NOKEY_COMPLETE=$?
  save_evidence nat-no-key.txt "$NAT_NOKEY"
  [[ -n "$UPLINK" ]] && assert_dnat_absent "4s0. adb_reach=lan with no operator key registered" "$NAT_NOKEY" "$UPLINK" $(( NAT_NOKEY_COMPLETE == 0 ))
  assert_lan_refused_marker "4s1. the launcher refused to arm with no key" \
    "$(guest_marker_since "$NOKEY_SENTINEL" 'server.adb_reach=lan')" "no operator key"
fi
KEY_RESTORE=$(ssh_vm -t 30 "rhizo adb-key add -" < "$RIG_ADB_KEY" 2>&1)
assert_adbkey_registered "4s2. the operator key, restored for the captures below" \
  "$KEY_RESTORE" "$(ssh_vm -t 20 "rhizo adb-key list" 2>&1)"

ssh_vm -t 40 'test -s /root/.android/adbkey.pub || { mkdir -p /root/.android && adb keygen /root/.android/adbkey; }' >/dev/null 2>&1
GUEST_KEY_ADD=$(ssh_vm -t 30 "rhizo adb-key add - < /root/.android/adbkey.pub" 2>&1)
assert_adbkey_registered "4s2b. the guest's own adb client key, which step 5 samples with" \
  "$GUEST_KEY_ADD" "$(ssh_vm -t 20 "rhizo adb-key list" 2>&1)"
ssh_vm -t 20 ": > $BOOT_LOG" >/dev/null 2>&1
if ! restart_androidd restart-key-restored.log; then
  fail "4s3. no init second_stage after restoring the operator key"
else
  assert_adb_state "4s3. adb_reach=lan re-armed after restoring the key" "$(uplink_adb_state 300)" device
fi

POLICY_TEXT=$(write_policy lan "$IDLE_STOP_SHORT_S" on)
assert_policy_written "4l. idle_stop_s lowered for the cycle" "$POLICY_TEXT" lan "$IDLE_STOP_SHORT_S" on
IDLE_SINCE=$(ssh_vm -t 10 'date +%s' 2>/dev/null | tr -d '[:space:]')
ssh_vm -t 30 "systemctl restart $IDLE_UNIT" > "$EV/idle-restart.log" 2>&1
assert_unit_active "4m. $IDLE_UNIT after the reconfiguration" "$IDLE_UNIT" \
  "$(ssh_vm -t 10 "systemctl show -p LoadState,ActiveState $IDLE_UNIT" 2>/dev/null)"

IDLE_INVOCATION=$(idle_invocation)
SUB_NETLINK=""; SUB_CHILD=""; SUB_INODES=""
SUB_DEADLINE=$((SECONDS + 60))
while (( SECONDS < SUB_DEADLINE )); do
  SUB_CHILD=$(idle_detector_pid)
  SUB_INODES=$(idle_detector_sock_inodes "$SUB_CHILD")
  SUB_NETLINK=$(idle_netlink)
  detector_subscribed "$SUB_NETLINK" "$SUB_INODES" && break
  sleep 1
done
save_evidence idle-netlink.txt "${SUB_NETLINK:-<none: cat /proc/net/netlink returned nothing>}"
save_evidence idle-conntrack-sockets.txt "idle detector ${SUB_CHILD:-<none>} socket inodes: ${SUB_INODES:-<none>}"
save_idle_journal
assert_detector_subscribed "4m1. the restarted detector is watching ctnetlink, within 60s and before 4m2 opens its session" \
  "$SUB_NETLINK" "$SUB_INODES" "$SUB_CHILD"

ADB_STATE_4M2=$(uplink_adb_state 120)
COUNT_JOURNAL=""
COUNT_DEADLINE=$((SECONDS + 30))
while (( SECONDS < COUNT_DEADLINE )); do
  COUNT_JOURNAL=$(idle_journal "$IDLE_INVOCATION" "$IDLE_SINCE")
  session_counted "$COUNT_JOURNAL" && break
  sleep 2
done
save_idle_journal
assert_adb_state "4m2. a session the restarted detector saw open for itself" "$ADB_STATE_4M2" device
assert_session_counted "4m2b. the detector counted that session, so its close is what 4n waits on" \
  "$COUNT_JOURNAL"

../../vm/boot/adb-tunnel.sh up --stop > "$EV/adb-tunnel-teardown-2.log" 2>&1
"$ADB" disconnect "$ADB_TARGET" >/dev/null 2>&1
"$ADB" kill-server >/dev/null 2>&1

CT_TW=$(ssh_vm -t 10 'cat /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait' 2>/dev/null | tr -d '[:space:]')
if [[ ! "$CT_TW" =~ ^[0-9]+$ ]]; then
  fail "4n. could not read nf_conntrack_tcp_timeout_time_wait on the guest"
  CT_TW=180
fi
TIMER_DEADLINE=$((SECONDS + CT_TW + 60)); TIMER_SHOW=""
while (( SECONDS < TIMER_DEADLINE )); do
  TIMER_SHOW=$(ssh_vm -t 10 "systemctl show -p ActiveState $IDLE_STOP_UNIT.timer" 2>/dev/null)
  [[ "$(grep -m1 '^ActiveState=' <<<"$TIMER_SHOW" | cut -d= -f2)" == active ]] && break
  sleep 3
done
save_idle_journal
save_idle_table idle-table-after-close.txt
assert_idle_timer_armed "4n. the one-shot stop unit, armed within ${CT_TW}s of the last session closing" "$TIMER_SHOW"

STOP_DEADLINE=$((SECONDS + IDLE_STOP_SHORT_S + 120)); ANDROIDD_STATE=""
while (( SECONDS < STOP_DEADLINE )); do
  ANDROIDD_STATE=$(ssh_vm -t 10 'systemctl is-active androidd.service' 2>/dev/null | tr -d '\r\n')
  [[ "$ANDROIDD_STATE" == inactive ]] && break
  sleep 5
done
assert_androidd_state "4o. androidd.service after idle_stop_s=${IDLE_STOP_SHORT_S}s" "$ANDROIDD_STATE" inactive

ssh_vm -t 300 'systemctl start androidd.service' > "$EV/restart-after-idle.log" 2>&1
INIT=$(resolve_init 180)
if [[ -z "$INIT" ]]; then
  fail "4p. no init second_stage after systemctl start androidd.service"
else
  assert_adb_state "4p. adb after the idle stop and start" "$(uplink_adb_state 300)" device
  assert_boot_completed "4q. sys.boot_completed after the idle stop and start" "$(adb_boot_completed 300)"
fi

POLICY_TEXT=$(write_policy lan "$IDLE_STOP_LONG_S" on)
assert_policy_written "4r. idle_stop_s restored" "$POLICY_TEXT" lan "$IDLE_STOP_LONG_S" on
ssh_vm -t 30 "systemctl restart $IDLE_UNIT" >/dev/null 2>&1

if (( FAILED )); then
  log "test-server: FAILED with $FAILED failure(s)"
  test_record_verdict FAILED
  exit 1
fi
log "test-server: PASSED"
test_record_verdict PASSED
