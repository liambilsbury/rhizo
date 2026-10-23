#!/bin/bash
# test APK install and removal
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: shared
# test-boots-unit: yes
# test-nests: launcher.sh
# test-records-metrics: no
# test-verdict-params: cycles=2 (default)
# test-requires: share:rhizo-test-fixture.apk file:rhizo-test-fixture.json share:rhizo-deskapp.apk file:rhizo-deskapp.json
# shellcheck disable=SC2034
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
source ../lib/install-lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
SELFTEST=0
CYCLES=2
CYCLES_NOTE="default"
for arg in "$@"; do
  case "$arg" in
    --skip-boot) SKIP_BOOT=1 ;;
    --fast)      CYCLES=1; CYCLES_NOTE="FAST, src/install/remove cycles reduced" ;;
    --selftest)  SELFTEST=1 ;;
    *) echo "usage: install.sh [--skip-boot] [--fast] [--selftest]" >&2; exit 2 ;;
  esac
done

test_init install
if (( SELFTEST )); then
  EV="$EV/selftest"
  mkdir -p "$EV" || exit 1
  : > "$EV/failures.log"
  CYCLES=1
  CYCLES_NOTE="selftest"
fi
WORKDIR="$TEST_WORKDIR"
VERDICT_PARAMS="cycles=$CYCLES ($CYCLES_NOTE)"

HOSTFS_CONF_WRITTEN=0
# remove the hostfs config from the guest
install_cleanup() {
  local rc=$?
  if (( HOSTFS_CONF_WRITTEN )) && ! ssh_vm -t 20 "rm -f $HOSTFS_CONF"; then
    log "    could not remove $HOSTFS_CONF from the guest -- this vm still carries it"
  fi
  return $rc
}
trap 'install_cleanup; test_cleanup' EXIT

# record a FAILED verdict and exit
bail() { fail "$1"; test_record_verdict FAILED "$VERDICT_PARAMS"; exit 1; }

# corrupt a received string for --selftest
st() {
  if (( SELFTEST )); then printf 'selftest-corrupted-%s' "$1"; else printf '%s' "$1"; fi
}
# offset a received number for --selftest
st_num() {
  if (( SELFTEST )); then printf '%s' $(( ${1%%.*} + 100000 )); else printf '%s' "$1"; fi
}
# replace a received number with 0 for --selftest
st_zero() {
  if (( SELFTEST )); then printf '0'; else printf '%s' "$1"; fi
}
# print the received value
st_const() {
  if (( SELFTEST )); then printf 'selftest-collapsed'; else printf '%s' "$1"; fi
}
# replace a display id with 4095 for --selftest
st_disp() {
  if (( SELFTEST )); then printf '%s' 4095; else printf '%s' "$1"; fi
}
# append a name to received text for --selftest
st_inject() {
  if (( SELFTEST )); then printf '%s\n%s' "$1" "$2"; else printf '%s' "$1"; fi
}
# remove a name from received text for --selftest
st_strip() {
  if (( SELFTEST )); then printf '%s' "${1//$2/}"; else printf '%s' "$1"; fi
}

SELFTEST_STEPS=()
SELFTEST_UNRUN=()
if (( SELFTEST )); then
  step() { TEST_STEP="$*"; SELFTEST_STEPS+=("$*"); log "=== $*"; }
fi

ADB=~/Android/Sdk/platform-tools/adb
APPS_DIR=/usr/share/applications
ICONS_DIR=/usr/share/icons/hicolor
MIMEAPPS="$APPS_DIR/mimeapps.list"
MIMEINFO="$APPS_DIR/mimeinfo.cache"
APK_HANDLER="$APPS_DIR/rhizo-apk-installer.desktop"
INBOX=/run/rhizo/data/rhizo_inbox
DESK_USER=""
DESK_HOME=""
DOWNLOADS=""
HOSTFS_CONF=/etc/rhizo/hostfs.conf
HOSTFS_TOOL=/usr/lib/rhizo/tools/hostfs.py
SHARE_NAME=Download
HTMLVIEWER_ENTRY=rhizo-com.android.htmlviewer.desktop
NOTIF_FIFO=/tmp/rhizo-install-notify.fifo
NOTIF_REC=/tmp/rhizo-install-notif.jsonl
NOTIF_OUT=/tmp/rhizo-install-sink.out
NOTIF_ICONS=/tmp/rhizo-install-icons
BUS_ADDR=""

AAPT2="${RHIZO_AAPT2:-$VAR_DIR/share/aapt2}"

FIXTURE_APK="$VAR_DIR/share/rhizo-test-fixture.apk"
FIXTURE_META="$VAR_DIR/share/rhizo-test-fixture.json"
DESKAPP_APK="$VAR_DIR/share/rhizo-deskapp.apk"
DESKAPP_META="$VAR_DIR/share/rhizo-deskapp.json"

# print a key from a metadata JSON file
meta_field() {
  python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"
}
# print the application label of an APK
apk_label() {
  "$AAPT2" dump badging "$1" | grep '^application-label:' | head -1 | sed "s/^application-label:'//;s/'\$//"
}

[[ -x "$AAPT2" ]] || bail "no aapt2 at $AAPT2 -- build it with tools/build/toolchain/aapt2.sh or set RHIZO_AAPT2"
for f in "$FIXTURE_APK" "$FIXTURE_META"; do
  [[ -f "$f" ]] || bail "missing $f -- fetch the install fixture with tools/fetch/test-apk.sh"
done
for f in "$DESKAPP_APK" "$DESKAPP_META"; do
  [[ -f "$f" ]] || bail "missing $f -- build the content fixture with tools/build/test-apps/deskapp.sh"
done
FIXTURE_SHA=$(meta_field "$FIXTURE_META" sha256)
GOT_SHA=$(sha256sum "$FIXTURE_APK" | cut -d' ' -f1)
[[ "$FIXTURE_SHA" == "$GOT_SHA" ]] || bail "cached fixture sha256 mismatch ($GOT_SHA != pinned $FIXTURE_SHA)"
PKG=$(meta_field "$FIXTURE_META" package)
ACT=$(meta_field "$FIXTURE_META" activity)
ENTRY_NAME="rhizo-$PKG.desktop"
ENTRY_PATH="$APPS_DIR/$ENTRY_NAME"
ENTRY_ID="rhizo-$PKG"
LABEL=$(apk_label "$FIXTURE_APK")
[[ -n "$LABEL" ]] || bail "$AAPT2 read no application-label from $FIXTURE_APK"
log "fixture: $PKG/$ACT label='$LABEL' sha256=$FIXTURE_SHA"

DESKAPP_SHA=$(meta_field "$DESKAPP_META" sha256)
DESKAPP_PKG=$(meta_field "$DESKAPP_META" package)
[[ -n "$DESKAPP_SHA" && -n "$DESKAPP_PKG" ]] \
  || bail "$DESKAPP_META carries no package/sha256 -- rebuild the content fixture with tools/build/test-apps/deskapp.sh"
GOT_DESKAPP_SHA=$(sha256sum "$DESKAPP_APK" | cut -d' ' -f1)
[[ "$DESKAPP_SHA" == "$GOT_DESKAPP_SHA" ]] \
  || bail "content fixture sha256 mismatch ($GOT_DESKAPP_SHA != pinned $DESKAPP_SHA) -- rebuild it with tools/build/test-apps/deskapp.sh"
DESKAPP_ENTRY="rhizo-$DESKAPP_PKG.desktop"
DESKAPP_LABEL=$(apk_label "$DESKAPP_APK")
[[ -n "$DESKAPP_LABEL" ]] || bail "$AAPT2 read no application-label from $DESKAPP_APK"
log "content fixture: $DESKAPP_PKG label='$DESKAPP_LABEL' sha256=$DESKAPP_SHA"

# print a random hex string
nonce() { head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# read the last token match from logcat
app_token_seen() {
  local logs
  logs=$(android_sh "$INIT" "logcat -d -b all -s RhizoDeskApp:I" 2>/dev/null)
  POLL_READ=$(grep -a -o "$1" <<<"$logs" | tail -1)
  [[ -n "$POLL_READ" ]]
}
# wait for a token in the app logcat
app_wait_token() {
  poll_until "$2" 2 app_token_seen "$1" || return 1
  printf '%s' "$POLL_READ"
}

# read the newest display list line
display_list_grew() {
  local after_n
  after_n=$(rhizo_ctl_out "$INIT" | grep -c '^display list' || true)
  [[ "${after_n:-0}" -gt "$1" ]] || return 1
  POLL_READ=$(rhizo_ctl_out "$INIT" | grep '^display list' | tail -1)
}

# remove the non-primary displays
display_cleanup() {
  local before_n dlist did removed=""
  before_n=$(rhizo_ctl_out "$INIT" | grep -c '^display list' || true)
  rhizo_ctl "$INIT" display list >/dev/null
  poll_until 15 1 display_list_grew "${before_n:-0}"
  dlist="$POLL_READ"
  for did in $(grep -oE '[0-9]+\(' <<<"$dlist" | tr -d '('); do
    [[ "$did" == 1 ]] && continue
    rhizo_ctl "$INIT" display remove "$did" >/dev/null
    removed+="$did "
  done
  log "    displays removed before this launch: ${removed:-none} (${dlist#display list })"
}

# check notify-sink.py printed ready
sink_ready() {
  [[ "$(ssh_vm -t 10 "if grep -q ready $NOTIF_OUT; then echo READY; else echo WAITING; fi" | tr -d '\r')" == READY ]]
}

# read the IPv4 address of eth0
sandbox_leased() {
  POLL_READ=$(android_sh "$1" 'ip -4 -o addr show eth0' 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)
  [[ -n "$POLL_READ" ]]
}

# verify the sandbox init process runs
sandbox_up_for_leg() {
  local live bc="" unit
  live=$(guest_init_pids 10)
  if [[ -n "$INIT" ]]; then
    bc=$(getprop_live "$INIT" sys.boot_completed) || bc="<unreadable rc=$?>"
  fi
  if [[ -n "$INIT" ]] && grep -qx "$INIT" <<<"$live" && [[ "$bc" == 1 ]]; then
    return 0
  fi
  unit=$(ssh_vm -t 15 "systemctl is-active androidd.service" | tr -d '\r')
  if [[ -n "$INIT" && -n "$live" ]] && ! grep -qx "$INIT" <<<"$live"; then
    fail "the sandbox restarted under this leg (this system test's init=$INIT, init second_stage now=${live//$'\n'/,}, androidd.service=${unit:-<no answer>}) -- its assertions were not run"
  else
    live=${live//$'\n'/,}
    fail "no running sandbox under this leg (androidd.service=${unit:-<no answer>}, init second_stage=${live:-none}, this system test's init=${INIT:-none}, sys.boot_completed='$bc') -- its assertions were not run"
  fi
  (( SELFTEST )) && SELFTEST_UNRUN+=("$TEST_STEP")
  return 1
}

# check a capture holds a logcat line
logcat_capture_read() {
  grep -qE '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} +[0-9]+ +[0-9]+ [VDIWEFA] ' "$1"
}

PRIMARY_TEARDOWN="MaybeTeardownOnLastAppDisplayClosed: last app display closed -- primary's own surface dropped too"
PRIMARY_CLOSED_RE='WaylandBackend: display 1 xdg_toplevel\.close from compositor'
PRIMARY_APP_CLOSED_RE='WaylandBackend: display ([02-9]|[1-9][0-9]+) xdg_toplevel\.close from compositor'
# print the verdict on the primary window close
primary_close_verdict() {
  local before="$1" closed="$2" after="$3" cap="$4" alive
  if ! logcat_capture_read "$cap"; then
    echo "the logcat since the app close holds no line"
    return 1
  fi
  if [[ "$before" == "?" ]]; then
    echo "the window listing before the app close never completed"
    return 1
  fi
  if [[ -n "$before" ]] && grep -Fxq -- "$before" "$closed"; then
    echo "the app-close loop closed window $before, the primary rhizo/Rhizo surface"
    return 1
  fi
  if grep -qE -- "$PRIMARY_CLOSED_RE" "$cap"; then
    echo "the compositor closed the primary's own toplevel (composer display 1) during the app close"
    return 1
  fi
  alive=$(python3 -c "
import json, sys
for l in sys.stdin:
    try:
        win = json.loads(l)
    except ValueError:
        continue
    if win.get('app_id') == 'rhizo' and win.get('title') == 'Rhizo':
        print('alive')
        break
" <"$after")
  if [[ "$alive" == alive ]]; then
    echo "primary rhizo/Rhizo surface still mapped after closing app windows"
    return 0
  fi
  if [[ -z "$before" ]]; then
    echo "no primary surface was mapped before the app close (the composer maps it at boot only)"
    return 0
  fi
  if grep -qF -- "$PRIMARY_TEARDOWN" "$cap"; then
    if grep -qE -- "$TEST_FATAL_RE" "$cap"; then
      echo "the composer dropped the primary, but the logcat since the app close holds a fatal line: $(grep -m1 -E -- "$TEST_FATAL_RE" "$cap" | cut -c1-200)"
      return 1
    fi
    if ! RE="$PRIMARY_APP_CLOSED_RE" TD="$PRIMARY_TEARDOWN" awk '
        $0 ~ ENVIRON["RE"] { app = 1 } index($0, ENVIRON["TD"]) { exit !app } END { if (!app) exit 1 }' "$cap"; then
      echo "the composer's last-app teardown is not preceded by any app display's close in this run's logcat"
      return 1
    fi
    echo "the composer dropped the primary with the last app display, and nothing closed it"
    return 0
  fi
  echo "the primary rhizo/Rhizo surface is gone after closing app windows and the composer logged no last-app teardown"
  return 1
}

# return true when the hostfs tool reports all of the shares attached
hostfs_attached() {
  POLL_READ=$(ssh_vm -t 25 "python3 $HOSTFS_TOOL status --config $HOSTFS_CONF --json" 2>&1 | tr -d '\r')
  grep -q '"all_attached": true' <<<"$POLL_READ"
}

if (( SKIP_BOOT == 0 )); then
  step "0. boot: VM, compositor, Android"
  export RHIZO_USE_UNIT=1
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" \
    || { test_record_verdict FAILED "$VERDICT_PARAMS"; exit 1; }
  desk_session_up >"$EV/install-sway.log" 2>&1 || bail "the desktop session did not start (see $EV/install-sway.log)"
  ../../vm/sync.sh >/dev/null || bail "sync.sh failed"
  ../../vm/redeploy.sh --skip-kill --boot-wait 180 >"$EV/install-redeploy.log" 2>&1 || bail "redeploy.sh failed (see $EV/install-redeploy.log)"
  tail -6 "$EV/install-redeploy.log"
else
  RHIZO_SWAY_SSH_WAIT=300 test_ensure_sway "$EV/chained-install-sway.log" "$EV/chained-redeploy.log"
fi
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || bail "no init second_stage"
log "init_pid=$INIT"
DESK_USER=$(desk_user_name) || bail "the guest did not answer which account is its desktop user"
DESK_HOME=$(ssh_vm -t 10 "getent passwd $DESK_USER | cut -d: -f6" | tr -d '\r')
[[ -n "$DESK_HOME" ]] || bail "no home directory for $DESK_USER on the guest"
DOWNLOADS=$DESK_HOME/Downloads
log "desktop user $DESK_USER, home $DESK_HOME"

boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"

android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "locksettings set-disabled true" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
awake=$(wait_device_awake "$INIT")
[[ "$awake" == "mWakefulness=Awake" ]] || fail "device is not awake ($awake)"
pass "booted, awake, keyguard disabled"

touch "$WORKDIR/test-start"

step "1. regression baseline: launcher.sh --skip-boot (this same live boot)"
launcher_verdict="$(test_evidence_dir launcher)/verdict.txt"
guest_boot_epoch=$(ssh_vm -t 15 "date -d \"\$(uptime -s)\" +%s" | tr -d '\r')
verdict_ok=0
if (( SKIP_BOOT )) && [[ -r "$launcher_verdict" ]]; then
  read -r v_state v_ts _ < "$launcher_verdict"
  v_sha=$(sed -n 's/^sha=//p' "$launcher_verdict" | head -1)
  v_epoch=$(date -d "$v_ts" +%s 2>/dev/null || echo 0)
  if [[ "$v_state" == PASSED && "$v_sha" == "$(git rev-parse --short HEAD)" ]] && (( v_epoch > guest_boot_epoch )); then
    verdict_ok=1
  fi
fi
if (( verdict_ok )); then
  pass "launcher.sh PASSED on this boot as the chain leader ($v_ts, sha=$v_sha) -- its verdict is the baseline"
  LAUNCHER_MANIFEST="$(test_evidence_dir launcher)/rhizo-apps.json"
elif "$(system_test_file launcher.sh)" --skip-boot > "$EV/test-launcher-baseline.log" 2>&1; then
  pass "launcher.sh passed against this boot"
  LAUNCHER_MANIFEST="$(test_nested_evidence_dir launcher)/rhizo-apps.json"
else
  fail "launcher.sh FAILED against this boot -- see $EV/test-launcher-baseline.log"
  tail -20 "$EV/test-launcher-baseline.log"
  LAUNCHER_MANIFEST="$(test_nested_evidence_dir launcher)/rhizo-apps.json"
fi

step "2. preconditions: the packaged machinery, the desktop user, the sink"
android_sh "$INIT" "logcat -c" >/dev/null 2>&1

pkgs_now=$(android_sh "$INIT" "pm list packages" | sort)
if grep -qx "package:$PKG" <<<"$pkgs_now"; then
  log "    $PKG left installed by a previous run -- uninstalling before the precondition check"
  android_sh "$INIT" "pm uninstall --user 0 $PKG" >/dev/null 2>&1
  pkgs_now=$(android_sh "$INIT" "pm list packages" | sort)
fi
grep -qx "package:$PKG" <<<"$pkgs_now" && fail "$PKG is installed before the system test installs it"

sock_state=$(ssh_vm -t 15 "systemctl is-active rhizo-brokerd.socket" | tr -d '\r')
[[ "$sock_state" == active ]] || fail "rhizo-brokerd.socket is '$sock_state'"
groups_out=$(ssh_vm -t 15 "id -nG $DESK_USER" | tr -d '\r')
grep -qw rhizo <<<"$groups_out" || fail "$DESK_USER is not in group rhizo (groups: $groups_out)"
[[ "$(guest_file_state "$APK_HANDLER")" == PRESENT ]] \
  || fail "no $APK_HANDLER -- nothing on the host claims application/vnd.android.package-archive"
[[ "$(guest_file_state /usr/bin/rhizo)" == PRESENT ]] || fail "no /usr/bin/rhizo on the guest"

DESK_RUNTIME_DIR=/tmp/xdg-runtime-$DESK_USER
ssh_vm -t 15 "runuser -u $DESK_USER -- mkdir -p -m 0700 $DESK_RUNTIME_DIR" || bail "could not create $DESK_RUNTIME_DIR as $DESK_USER"
BUS_ADDR=$(ssh_vm -t 25 "runuser -u $DESK_USER -- env XDG_RUNTIME_DIR=$DESK_RUNTIME_DIR dbus-daemon --session --fork --print-address" | tr -d '\r' | head -1)
[[ "$BUS_ADDR" == unix:* ]] || bail "no private session bus for $DESK_USER (dbus-daemon said '$BUS_ADDR')"
log "    session bus: $BUS_ADDR"
SINK_PATH="/tmp/rhizo-notify-sink-$(nonce).py"
timeout 30 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" ../guest/notify-sink.py "$SSH_TARGET:$SINK_PATH" \
  || bail "could not copy the notification sink into the guest"
ssh_vm -t 20 "chmod 0755 $SINK_PATH; chown $DESK_USER $SINK_PATH" >/dev/null
user_sh 30 "pgrep -f 'rhizo-install-[n]otif.jsonl' | xargs -r kill
rm -f $NOTIF_FIFO $NOTIF_REC $NOTIF_OUT
rm -rf $NOTIF_ICONS && mkdir -p $NOTIF_ICONS
mkfifo $NOTIF_FIFO
setsid sh -c 'sleep 86400 > $NOTIF_FIFO' >/dev/null 2>&1 </dev/null &
setsid env PYTHONPATH=/usr/lib/rhizo sh -c '$SINK_PATH --record $NOTIF_REC --icon-dir $NOTIF_ICONS < $NOTIF_FIFO > $NOTIF_OUT 2>&1' >/dev/null 2>&1 </dev/null &
true" >/dev/null
poll_until 20 1 sink_ready \
  || { ssh_vm -t 10 "cat $NOTIF_OUT" | sed 's/^/    | /'; bail "the notification sink never owned org.freedesktop.Notifications"; }
user_sh 20 "mkdir -p $DOWNLOADS" >/dev/null
pass "broker socket listening, $DESK_USER in group rhizo, session bus and sink up, fixture absent"

SS_PID_AFTER_RESTART=""
RESTART_SINCE=""
for cycle in $(seq 1 "$CYCLES"); do

step "3. install by the host's own APK handler, as $DESK_USER (cycle $cycle of $CYCLES)"
n=$(nonce)
install_apk_via_broker "$cycle" "$FIXTURE_APK" "$FIXTURE_SHA" "$PKG" "$LABEL" "$ENTRY_PATH" "$ENTRY_ID"

step "4. identity: one name across the entry, the toplevel and StartupWMClass (cycle $cycle of $CYCLES)"
display_cleanup
# shellcheck disable=SC2154
exec_value=$(entry_field "$entry_text" Exec)
wmclass=$(entry_field "$entry_text" StartupWMClass)
launch_cmd=$(exec_command "$exec_value")
[[ "$launch_cmd" == "rhizo launch $PKG" ]] \
  || fail "the entry's Exec= is '$exec_value', expected 'rhizo launch $PKG %u'"
launch_out=$(user_sh 180 "$launch_cmd 2>&1; echo EXEC_RC=\$?")
printf '%s\n' "$launch_out" > "$EV/cycle$cycle-launch.log"
launched=$(sentinel_of "$launch_out" "RHIZO_LAUNCHED ")
log "    launch sentinel: ${launched:-<none>}"
[[ -n "$launched" ]] || fail "the entry's Exec printed no RHIZO_LAUNCHED sentinel"
cdisp=$(st_disp "$(grep -o 'cdisplay=[0-9]*' <<<"$launched" | cut -d= -f2)")
logid=$(grep -oE '(^|[[:space:]])display=[0-9]+' <<<"$launched" | tail -1 | cut -d= -f2)
if [[ -z "$cdisp" ]]; then
  fail "the launch sentinel carries no cdisplay= ($launched)"
else
  ident=$(resolve_display_toplevel "$cdisp")
  app_id=$(st "${ident%% *}")
  log "    app_id='$app_id' desktop-file-id='$ENTRY_ID' StartupWMClass='$wmclass'"
  [[ "$app_id" == "$ENTRY_ID" ]] || fail "the toplevel's app_id is '$app_id', the entry is $ENTRY_NAME"
  [[ "$wmclass" == "$ENTRY_ID" ]] || fail "StartupWMClass= is '$wmclass', the toplevel's app_id is '$app_id'"
  [[ "$(entry_field "$entry_text" StartupNotify)" == true ]] || fail "the entry has no StartupNotify=true"
  assert_window_painted "cycle$cycle-identity" "$cdisp"
fi
resumed="" rstat=0 acts="$EV/cycle$cycle-activities.txt"
if [[ -n "$logid" ]]; then
  await_resumed_on_display "$INIT" "$logid" "$acts"; rstat=$?
  resumed="$RESUMED_READ"
else
  printf '<none: the launch sentinel carries no display=>\n' > "$acts"
  fail "the launch sentinel carries no display= ($launched)"
fi
entry_act=$(entry_field "$entry_text" X-Rhizo-Activity)
[[ "$entry_act" == .* ]] && entry_act_fq="$PKG$entry_act" || entry_act_fq="$entry_act"
[[ "$entry_act_fq" == "$ACT" ]] || fail "the entry's X-Rhizo-Activity= is '$entry_act', the fixture's own manifest says $ACT"
if [[ -n "$logid" ]]; then
  elsewhere=$(resumed_where "$PKG" "$acts" | paste -sd '|')
  case $rstat in
    0) [[ "$resumed" == "$PKG/$entry_act" ]] \
         || fail "dumpsys shows '$resumed' resumed on display $logid, expected $PKG/$entry_act (see $acts)" ;;
    2) fail "no whole 'dumpsys activity activities' read (see $acts)" ;;
    3) fail "dumpsys has no display $logid, the one the launch put $PKG on; $PKG resumed: ${elsewhere:-nowhere} (see $acts)" ;;
    *) fail "nothing is resumed on display $logid, expected $PKG/$entry_act; $PKG resumed: ${elsewhere:-nowhere} (see $acts)" ;;
  esac
fi
pass "the entry's own Exec launched the app under app_id $ENTRY_ID into a real painted window"

step "5. removal through the entry's own Uninstall action, as $DESK_USER (cycle $cycle of $CYCLES)"
install_uninstall_via_entry_action "$cycle" "$n" "$PKG" "$ENTRY_PATH" "$ENTRY_NAME" "$entry_text"

done

step "6. a stopped sandbox starts from the user's side, with its shares back"
unit_state=$(ssh_vm -t 15 "systemctl is-active androidd.service" | tr -d '\r')
if [[ "$unit_state" != active ]]; then
  fail "androidd.service is '$unit_state', so this boot's leader did not use RHIZO_USE_UNIT=1"
else
  HOSTFS_CONF_WRITTEN=1
  ssh_vm -t 30 "printf '[$SHARE_NAME]\ndir = $DOWNLOADS\nuser = $DESK_USER\nmode = over\n' > $HOSTFS_CONF" \
    || fail "could not write $HOSTFS_CONF"
  ssh_vm -t 90 "systemctl restart rhizo-hostfs.service" >/dev/null 2>&1
  poll_until 120 3 hostfs_attached \
    || fail "the [$SHARE_NAME] share never attached before the stop (status said: ${POLL_READ:-<no answer>})"

  stock_pkg=""
  STOCK_PKG=com.android.settings
  manifest_epoch=$(stat -c %Y "$LAUNCHER_MANIFEST" 2>/dev/null || echo 0)
  if (( verdict_ok )); then manifest_ref=$guest_boot_epoch; else manifest_ref=$(stat -c %Y "$WORKDIR/test-start"); fi
  if (( manifest_epoch <= manifest_ref )); then
    fail "$LAUNCHER_MANIFEST is missing or older than $( ((verdict_ok)) && echo "this boot" || echo "this run")"
  else
    stock_pkg=$(python3 -c "
import json
apps = json.load(open('$LAUNCHER_MANIFEST'))['apps']
print(next((a['package'] for a in apps if a['package'] == '$STOCK_PKG'), ''))
")
    [[ -n "$stock_pkg" ]] || fail "test-launcher's manifest has no entry for $STOCK_PKG"
  fi
  if [[ -n "$stock_pkg" ]]; then
    stock_entry="$APPS_DIR/rhizo-$stock_pkg.desktop"
    stock_text=$(ssh_vm -t 15 "cat $stock_entry")
    stock_cmd=$(exec_command "$(entry_field "$stock_text" Exec)")
    [[ "$stock_cmd" == "rhizo launch $stock_pkg" ]] \
      || fail "$stock_entry Exec= reduces to '$stock_cmd', expected 'rhizo launch $stock_pkg'"
    display_cleanup
    RESTART_SINCE=$(logcat_since_marker "$INIT")
    ssh_vm -t 180 "systemctl stop androidd.service" >"$EV/androidd-stop.log" 2>&1
    stopped=$(ssh_vm -t 15 "systemctl is-active androidd.service" | tr -d '\r')
    [[ "$stopped" == active ]] && fail "androidd.service is still active after systemctl stop"
    log "    androidd.service stopped ($stopped); launching $stock_pkg as $DESK_USER"
    start_out=$(user_sh 420 "$stock_cmd 2>&1; echo EXEC_RC=\$?")
    printf '%s\n' "$start_out" > "$EV/start-on-demand.log"
    [[ -n "$(sentinel_of "$start_out" "RHIZO_SANDBOX starting=1")" ]] \
      || fail "the CLI never printed RHIZO_SANDBOX starting=1 before waiting for the sandbox"
    started=$(sentinel_of "$start_out" "RHIZO_LAUNCHED ")
    log "    start-on-demand sentinel: ${started:-<none>}"
    after_state=$(ssh_vm -t 20 "systemctl is-active androidd.service" | tr -d '\r')
    [[ "$after_state" == active ]] || fail "androidd.service is '$after_state' after the user launched an app"
    INIT=$(guest_init_pid 15)
    [[ -n "$INIT" ]] || fail "no init second_stage after the on-demand start"
    bc=$(getprop_live "$INIT" sys.boot_completed) || bc="<unreadable rc=$?>"
    bc=$(st_zero "$bc")
    [[ "$bc" == "1" ]] || fail "sys.boot_completed is '$bc' after the on-demand start"
    scdisp=$(st_disp "$(grep -o 'cdisplay=[0-9]*' <<<"$started" | cut -d= -f2)")
    if [[ -n "$scdisp" ]]; then
      assert_window_painted start-on-demand "$scdisp"
    else
      fail "the on-demand launch produced no cdisplay= to look for a window on"
    fi
    poll_until 180 5 hostfs_attached
    attached="$POLL_READ"
    printf '%s\n' "$attached" > "$EV/hostfs-status-after-restart.json"
    all_attached=$(st "$(sed -n 's/.*"all_attached": \([a-z]*\).*/\1/p' <<<"$attached")")
    [[ "$all_attached" == true ]] \
      || fail "hostfs.py reports all_attached=$all_attached after the sandbox restarted (see $EV/hostfs-status-after-restart.json)"
    poll_until 120 5 sandbox_leased "$INIT"
    lease=$(st "$POLL_READ")
    [[ "$lease" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || fail "the restarted sandbox's eth0 holds no IPv4 lease from the bridge (read '${lease:-<nothing>}')"
    log "    eth0 after the on-demand start: $lease"
    SS_PID_AFTER_RESTART=$(system_server_pid "$INIT")
    log "    system_server pid after the on-demand start: $SS_PID_AFTER_RESTART"
    pass "a stopped sandbox came back because a user launched an app, and its shares and network came back with it"
  fi
fi

step "7. the content types Android's own resolver names reach the desktop"
if sandbox_up_for_leg; then
deskapp_guest_apk="$DOWNLOADS/deskapp-$(nonce).apk"
base64 -w0 "$DESKAPP_APK" > "$WORKDIR/deskapp.b64"
ssh_vm -t 120 "runuser -u $DESK_USER -- sh -c 'base64 -d > $deskapp_guest_apk'" < "$WORKDIR/deskapp.b64" \
  || fail "could not write the content fixture into $deskapp_guest_apk as $DESK_USER"
deskapp_open=$(user_sh 240 "xdg-open $deskapp_guest_apk 2>&1; echo XDG_RC=\$?")
printf '%s\n' "$deskapp_open" > "$EV/deskapp-xdg-open-install.log"
# return true when the desk app package is listed
deskapp_listed() { POLL_READ=$(android_sh "$INIT" "pm list packages" | sort); grep -qx "package:$DESKAPP_PKG" <<<"$POLL_READ"; }
poll_until 180 3 deskapp_listed \
  || fail "$DESKAPP_PKG not in pm list packages within 180s of the handler launch (xdg-open said: $(tr '\n' '|' <<<"$deskapp_open" | tail -c 200))"

wait_guest_file 300 "$APPS_DIR/$DESKAPP_ENTRY" \
  || fail "no $APPS_DIR/$DESKAPP_ENTRY within 300s of installing $DESKAPP_PKG"
deskapp_text=$(ssh_vm -t 15 "cat $APPS_DIR/$DESKAPP_ENTRY")
printf '%s\n' "$deskapp_text" > "$EV/deskapp-entry.desktop"
deskapp_name=$(entry_field "$deskapp_text" Name)
[[ "$deskapp_name" == "$DESKAPP_LABEL" ]] \
  || fail "$DESKAPP_ENTRY's Name= is '$deskapp_name', this system test's own aapt2 run read '$DESKAPP_LABEL'"
deskapp_mime=$(entry_field "$deskapp_text" MimeType)
grep -q 'text/plain;' <<<"$deskapp_mime" \
  || fail "$DESKAPP_ENTRY carries MimeType='$deskapp_mime', which does not offer text/plain"
# check the MIME cache lists the deskapp
cache_lists_deskapp() { POLL_READ=$(ssh_vm -t 20 "grep '^text/plain=' $MIMEINFO" | tr -d '\r'); grep -q "$DESKAPP_ENTRY" <<<"$POLL_READ"; }
if ! poll_until 240 3 cache_lists_deskapp; then
  log "    $MIMEINFO's text/plain line never listed $DESKAPP_ENTRY within 240s"
fi
mimeinfo_line=$(st_strip "$POLL_READ" "$DESKAPP_ENTRY")
grep -qF "$DESKAPP_ENTRY" <<<"$mimeinfo_line" \
  || fail "$MIMEINFO's text/plain line is '$mimeinfo_line', which does not list $DESKAPP_ENTRY"
htmlviewer_state=$(guest_file_state "$APPS_DIR/$HTMLVIEWER_ENTRY")
case "$htmlviewer_state" in
  PRESENT)
    htmlviewer_text=$(ssh_vm -t 15 "cat $APPS_DIR/$HTMLVIEWER_ENTRY")
    [[ "$(entry_field "$htmlviewer_text" X-Rhizo-Package)" == com.android.htmlviewer ]] \
      || fail "$HTMLVIEWER_ENTRY read back without its X-Rhizo-Package= (read: $(head -c 200 <<<"$htmlviewer_text" | tr '\n' '|'))"
    [[ "$(entry_field "$htmlviewer_text" NoDisplay)" == true ]] \
      || fail "$HTMLVIEWER_ENTRY is not NoDisplay=true"
    ! grep -q 'text/plain;' <<<"$(entry_field "$htmlviewer_text" MimeType)" \
      || fail "$HTMLVIEWER_ENTRY offers text/plain"
    ;;
  ABSENT) log "    no $HTMLVIEWER_ENTRY: HTMLViewer opens no probed type from the file: URI rhizo launch hands Android" ;;
  *) fail "could not read whether $APPS_DIR/$HTMLVIEWER_ENTRY exists (read '${htmlviewer_state:-<nothing>}')" ;;
esac
pass "the app that claims text/plain is offered for it, and HTMLViewer is not"
fi

step "8. a file in the user's own folder opens in the Android app that claims it"
if sandbox_up_for_leg; then
install_file_handoff "$DESKAPP_ENTRY"
fi

step "9. nothing restarted underneath any of that"
if sandbox_up_for_leg; then
SS_PID_END=$(system_server_pid "$INIT")
boot_end=$(getprop_live "$INIT" sys.boot_completed) || boot_end="<unreadable rc=$?>"
log "    system_server pid $SS_PID_AFTER_RESTART -> $SS_PID_END, sys.boot_completed=$boot_end"
if [[ -z "$SS_PID_AFTER_RESTART" ]]; then
  fail "leg 6 never recorded a system_server pid"
else
  [[ "$SS_PID_AFTER_RESTART" == "$SS_PID_END" ]] \
    || fail "system_server restarted after the on-demand start ($SS_PID_AFTER_RESTART -> $SS_PID_END)"
fi
[[ "$boot_end" == "1" ]] || fail "sys.boot_completed is '$boot_end'"
if [[ -n "$RESTART_SINCE" ]]; then
  logcat_vm "$INIT" -d -v threadtime -t "$RESTART_SINCE" 2>/dev/null > "$EV/logcat-since-restart.txt"
else
  # test-log-window: safe -- not clean, ACKNOWLEDGED: step 6 never reached
  log "    no RESTART_SINCE marker (step 6 did not reach the restart) -- falling back to a line count"
  logcat_vm "$INIT" -d -v threadtime -t 8000 2>/dev/null > "$EV/logcat-since-restart.txt"
fi
logcat_capture_read "$EV/logcat-since-restart.txt" \
  || fail "$EV/logcat-since-restart.txt holds no logcat line"
grep -E -B2 -A6 "$TEST_FATAL_RE" "$EV/logcat-since-restart.txt" > "$EV/fatal-lines.txt" 2>/dev/null
bad=$(grep -cE "$TEST_FATAL_RE" "$EV/fatal-lines.txt" 2>/dev/null)
bad=$(st_num "${bad:-0}")
log "    fatal/watchdog lines in logcat: $bad"
if [[ "$bad" != "0" ]]; then
  fail "logcat has $bad fatal/watchdog lines (see $EV/fatal-lines.txt)"
  test_fatal_lines "$EV/fatal-lines.txt"
fi
pass "no restart, no fatal exception"
fi

step "10. close the app windows this system test opened"
# print the ids of rhizo-* windows
rhizo_app_window_ids() {
  local w
  w=$(desk_windows) || return 1
  python3 -c "
import json, sys
for l in sys.stdin:
    l = l.strip()
    if not l:
        continue
    try:
        win = json.loads(l)
    except ValueError:
        continue
    if (win.get('app_id') or '').startswith('rhizo-'):
        print(win.get('id', ''))
" <<<"$w"
}
if windows_before=$(desk_windows 2>/dev/null); then
  primary_before=$(python3 -c "
import json, sys
for l in sys.stdin:
    try:
        win = json.loads(l)
    except ValueError:
        continue
    if win.get('app_id') == 'rhizo' and win.get('title') == 'Rhizo':
        print(win.get('id', ''))
        break
" <<<"$windows_before")
else
  primary_before="?"
fi
CLOSE_SINCE=$(logcat_since_marker "$INIT")
close_ids=""
left=""
for _ in $(seq 1 40); do
  ids=$(rhizo_app_window_ids) || { left=""; sleep 1; continue; }
  # close all of the rhizo-* toplevels
  while IFS= read -r _id; do
    [[ -z "$_id" ]] && continue
    grep -Fxq -- "$_id" <<<"$close_ids" && continue
    desk_window_op "$_id" close >/dev/null 2>&1
    close_ids+="${close_ids:+$'\n'}$_id"
  done <<<"$ids"
  left=$(grep -c . <<<"$ids")
  [[ "$left" == "0" ]] && break
  sleep 1
done
printf '%s\n' "${close_ids:-<none>}" > "$EV/app-windows-closed.txt"
if left_json=$(desk_windows 2>/dev/null); then
  survivors=$(python3 -c "
import json, sys
for l in sys.stdin:
    try:
        win = json.loads(l)
    except ValueError:
        continue
    if (win.get('app_id') or '').startswith('rhizo-'):
        print('%s id=%s title=%s' % (win['app_id'], win.get('id'), win.get('title')))
" <<<"$left_json")
  printf '%s\n' "${survivors:-<none>}" > "$EV/app-windows-left.txt"
else
  survivors="<the window read failed>"
  printf '%s\n' "$survivors" > "$EV/app-windows-left.txt"
fi
if [[ "$left" == "0" ]]; then
  pass "app windows closed, no rhizo-* toplevel left mapped"
else
  fail "${left:-the guest read never completed}: rhizo-* toplevel(s) still mapped 40s after closing them: $(paste -sd';' <<<"$survivors")"
fi

# search the close logcat for the teardown line
capture_app_close() {
  logcat_vm "$INIT" -d -v threadtime -t "$CLOSE_SINCE" 2>/dev/null > "$EV/logcat-app-close.txt"
  (( SELFTEST )) && echo "$(date +'%m-%d %H:%M:%S.000')   113   150 I rhizo-wayland-backend: WaylandBackend: display 1 xdg_toplevel.close from compositor" >> "$EV/logcat-app-close.txt"
  grep -qF -- "$PRIMARY_TEARDOWN" "$EV/logcat-app-close.txt"
}
if ! windows_after=$(desk_windows 2>/dev/null); then
  printf '<the window read failed>\n' > "$EV/app-windows-after.txt"
  fail "the window listing after the app close never completed"
elif [[ -z "$CLOSE_SINCE" ]]; then
  printf '%s\n' "$windows_after" > "$EV/app-windows-after.txt"
  fail "no guest clock was read before the app close"
else
  printf '%s\n' "$windows_after" > "$EV/app-windows-after.txt"
  if ! capture_app_close && [[ -n "$primary_before" && "$primary_before" != "?" ]] \
      && ! grep -qF '"app_id": "rhizo",' "$EV/app-windows-after.txt"; then
    poll_until 20 1 capture_app_close || true
  fi
  if why=$(primary_close_verdict "$primary_before" "$EV/app-windows-closed.txt" \
      "$EV/app-windows-after.txt" "$EV/logcat-app-close.txt"); then
    pass "$why"
  else
    fail "$why"
  fi
fi

if (( SELFTEST )); then
  failed_steps=$(cut -f2 "$EV/failures.log" 2>/dev/null | sed 's/^step=//' | sort -u)
  survived=() asserting=0
  for st_step in "${SELFTEST_STEPS[@]}"; do
    case "$st_step" in
      0.*|1.*|2.*) continue ;;
    esac
    asserting=$(( asserting + 1 ))
    if printf '%s\n' "${SELFTEST_UNRUN[@]}" | grep -Fxq -- "$st_step"; then
      survived+=("$st_step (never ran: no live sandbox)")
      continue
    fi
    grep -Fxq "$st_step" <<<"$failed_steps" || survived+=("$st_step")
  done
  if (( ${#survived[@]} )); then
    log "INSTALL SYSTEM TEST SELFTEST FAILED -- these legs passed on a corrupted value:"
    printf '    | %s\n' "${survived[@]}" >&2
    printf 'FAILED selftest: %d of %d asserting legs survived a corrupted value\n%s\n' \
      "${#survived[@]}" "$asserting" "$(printf '  %s\n' "${survived[@]}")" > "$EV/selftest-verdict.txt"
    test_record_verdict FAILED "$VERDICT_PARAMS"
    exit 1
  fi
  log "INSTALL SYSTEM TEST SELFTEST PASSED -- all $asserting asserting legs failed on a corrupted value"
  printf 'PASSED selftest: all %d asserting legs failed on a corrupted value\n' "$asserting" \
    > "$EV/selftest-verdict.txt"
  test_record_verdict PASSED "$VERDICT_PARAMS"
  exit 0
fi
if (( FAILED )); then
  test_record_verdict FAILED "$VERDICT_PARAMS"
  log "INSTALL SYSTEM TEST FAILED"
  exit 1
fi
test_record_verdict PASSED "$VERDICT_PARAMS"
log "INSTALL SYSTEM TEST PASSED -- evidence in $EV"
