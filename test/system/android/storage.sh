#!/bin/bash
# test the shared host directory mount
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-requires: share:rhizo-storagetest.apk file:rhizo-hostfsd
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
source ../lib/desk-user-lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }

SHARE_NAME="Download"
KEEP=0
SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-boot) SKIP_BOOT=1; shift ;;
    --name) SHARE_NAME="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ "$SHARE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || { echo "storage.sh: --name must be a plain directory name, got '$SHARE_NAME'" >&2; exit 2; }

test_init storage
ADB="$HOME/Android/Sdk/platform-tools/adb"
SERIAL="127.0.0.1:$ADB_PORT"
HOST_DIR=""
GUEST_TOOL="/root/share/hostfs.py"
CONF="/etc/rhizo/hostfs.conf"
GUEST_DAEMON="/root/share/rhizo-hostfsd"
DAEMON_LINE=""
[[ -n "${RHIZO_HOSTFSD_GUEST_BIN:-}" ]] && DAEMON_LINE="daemon = $RHIZO_HOSTFSD_GUEST_BIN"
APK="$VAR_DIR/share/rhizo-storagetest.apk"
APK_META="$VAR_DIR/share/rhizo-storagetest.json"
test_require_staged rhizo-storagetest.apk || exit 1

STAMP="$(date +%s)-$$"
HOST_TEXT="from the desktop side, run $STAMP"
APP_TEXT="from the android side, run $STAMP"
REWRITE_TEXT="rewritten in place on the host, run $STAMP"

# print the sha256 of a host file
host_sha() { as_owner 25 "sha256sum $1" | tr -d '\r' | cut -d' ' -f1; }

SHARE_USER=""
# run a shell command with runuser
as_owner() {
  ssh_vm -t "$1" "runuser -u $SHARE_USER -- /bin/sh -c '$2'"
}

if (( SKIP_BOOT == 0 )); then
  step "0. boot"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 240 > "$EV/redeploy.log" 2>&1 || { fail "redeploy.sh failed (see $EV/redeploy.log)"; exit 1; }
  tail -4 "$EV/redeploy.log"
fi

SHARE_USER=$(desk_user_name) \
  || { fail "the guest did not answer which account is its desktop user"; test_record_verdict FAILED; exit 1; }
share_home=$(ssh_vm -t 10 "getent passwd $SHARE_USER | cut -d: -f6" 2>/dev/null | tr -d '[:space:]')
[[ -n "$share_home" ]] || { fail "no home directory for $SHARE_USER on the guest"; test_record_verdict FAILED; exit 1; }
HOST_DIR="$share_home/Downloads"
log "share owner $SHARE_USER, host directory $HOST_DIR"

INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage process"; test_record_verdict FAILED; exit 1; }
log "init_pid=$INIT"
SS_PID_START=$(system_server_pid "$INIT")
SINCE=$(logcat_since_marker "$INIT")

enforce=$(ssh_vm -t 10 "cat /sys/fs/selinux/enforce" | tr -d '\r\n')
[[ "$enforce" == "1" ]] || fail "guest is not enforcing (/sys/fs/selinux/enforce=$enforce)"

android_sh "$INIT" "cmd battery set ac 1" >/dev/null 2>&1
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null 2>&1
android_sh "$INIT" "locksettings set-disabled true" >/dev/null 2>&1
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null 2>&1

step "1. a directory of the host's, with the user's own file in it"
[[ -x "$VAR_DIR/share/rhizo-hostfsd" ]] || { fail "no rhizo-hostfsd in share/ -- run tools/build/services/hostfsd.sh"; test_record_verdict FAILED; exit 1; }
ssh_vm -t 20 "test -f $GUEST_TOOL" \
  || { fail "$GUEST_TOOL is not on the guest -- the deploy path did not stage it"; test_record_verdict FAILED; exit 1; }
ssh_vm -t 20 "test -x $GUEST_DAEMON" \
  || { fail "$GUEST_DAEMON is not on the guest -- the deploy path did not stage it"; test_record_verdict FAILED; exit 1; }
as_owner 30 "rm -rf $HOST_DIR && mkdir -p $HOST_DIR && printf %s\\n \"$HOST_TEXT\" > $HOST_DIR/from-the-host.txt && chmod 0644 $HOST_DIR/from-the-host.txt" \
  || { fail "could not create the host share directory as $SHARE_USER"; test_record_verdict FAILED; exit 1; }
# print the SELinux label of a host file
host_label() {
  local out
  out=$(as_owner 20 "python3 -c \"import os,sys;print(sys.argv[3]+os.getxattr(sys.argv[1],sys.argv[2]).decode().rstrip(chr(0)))\" $1 security.selinux XATTR= 2>&1" | tr -d '\r')
  case "$out" in
    XATTR=*)                          printf '%s\n' "${out#XATTR=}" ;;
    *ENODATA*|*"No data available"*)  printf 'NONE\n' ;;
    *)                                printf 'PROBE-FAILED(%s)\n' "$out" ;;
  esac
}
BEFORE=$(as_owner 20 "stat -c %i:%u:%g:%a $HOST_DIR/from-the-host.txt" | tr -d '\r')
BEFORE_XATTR=$(host_label "$HOST_DIR/from-the-host.txt")
[[ "$BEFORE_XATTR" == PROBE-FAILED* ]] && { fail "the SELinux-xattr probe does not work: $BEFORE_XATTR"; }
HOST_INO=$(cut -d: -f1 <<<"$BEFORE")
log "host file before: $BEFORE label=$BEFORE_XATTR"
pass "host directory $HOST_DIR holds the user's file (inode $HOST_INO)"

step "2. with no config the unit does nothing"
ssh_vm -t 20 "test -d /etc/rhizo" \
  || { fail "/etc/rhizo is not on the guest -- the deploy path did not create it"; test_record_verdict FAILED; exit 1; }
ssh_vm -t 60 "systemctl stop rhizo-hostfs.service" >/dev/null 2>&1
ssh_vm -t 20 "rm -f $CONF" >/dev/null 2>&1
ssh_vm -t 30 "systemctl reset-failed rhizo-hostfs.service 2>/dev/null; systemctl restart rhizo-hostfs.service" >/dev/null 2>&1
cond=$(ssh_vm -t 20 "systemctl show -p ConditionResult --value rhizo-hostfs.service" | tr -d '\r')
[[ "$cond" == "no" ]] || fail "with no config the unit did not condition-skip (ConditionResult=$cond)"
mounted=$(ssh_vm -t 20 "grep -c ' /mnt/user/0/emulated/0/$SHARE_NAME ' /proc/$INIT/mountinfo" | tr -d '\r')
[[ "$mounted" == "0" ]] || fail "the unit mounted something with no config present"
pass "with no config the unit condition-skips and mounts nothing"

step "3. configured, a BOOT attaches it with nobody asking"
ssh_vm -t 30 "printf '[%s]\\ndir = %s\\nuser = %s\\nmode = over\\n%s\\n' '$SHARE_NAME' '$HOST_DIR' '$SHARE_USER' '$DAEMON_LINE' > $CONF" \
  || { fail "could not write $CONF"; test_record_verdict FAILED; exit 1; }
ssh_vm -t 20 "cat $CONF" | sed 's/^/  /'
if (( SKIP_BOOT )); then
  fail "the boot leg cannot run chained onto another system test's boot, and a boot with the share configured is what this system test proves"
  ssh_vm -t 60 "systemctl restart rhizo-hostfs.service" >/dev/null 2>&1
else
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  ../../vm/redeploy.sh --skip-kill --boot-wait 240 > "$EV/redeploy-2.log" 2>&1 \
    || { fail "redeploy.sh failed (see $EV/redeploy-2.log)"; test_record_verdict FAILED; exit 1; }
  INIT=$(guest_init_pid 10)
  [[ -n "$INIT" ]] || { fail "no init second_stage after the second boot"; test_record_verdict FAILED; exit 1; }
  log "init_pid=$INIT after the reboot"
  SS_PID_START=$(system_server_pid "$INIT")
  SINCE=$(logcat_since_marker "$INIT")
fi
unit_state=activating
unit_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < unit_deadline )); do
  unit_state=$(ssh_vm -t 20 "systemctl is-active rhizo-hostfs.service" | tr -d '\r')
  [[ "$unit_state" == "activating" ]] || break
  sleep 3
done
ssh_vm -t 30 "journalctl -u rhizo-hostfs.service -n 40 --no-pager" > "$EV/unit.log" 2>&1
sed -n 's/^.*rhizo-hostfs: /  /p' "$EV/unit.log" | tail -8
[[ "$unit_state" == "active" ]] || fail "rhizo-hostfs.service is '$unit_state'"
grep -q "read back through the mount" "$EV/unit.log" \
  || fail "the unit never read anything back through the mount (daemon not serving?)"
st=$(ssh_vm -t 25 "python3 $GUEST_TOOL status --config $CONF" | tr -d '\r')
printf '%s\n' "$st" | sed 's/^/  /'
grep -q "is attached" <<<"$st" || fail "status does not report the share attached"
mline=$(ssh_vm -t 20 "grep ' /mnt/user/0/emulated/0/$SHARE_NAME ' /proc/$INIT/mountinfo" | tr -d '\r')
[[ -n "$mline" ]] || fail "the sandbox's own mountinfo has no entry for the share"
[[ "$mline" == *" - fuse "* ]] || fail "the share is not a fuse mount: $mline"
log "mountinfo: $mline"
(( FAILED )) && { test_record_verdict FAILED; log "STORAGE SYSTEM TEST FAILED"; exit 1; }
pass "$HOST_DIR came up mounted as $SHARE_NAME, attached by the boot"

step "4. install and drive a real app"
pkg=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['package'])" "$APK_META")
act=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['activity'])" "$APK_META")
../../vm/boot/adb-tunnel.sh up > "$EV/adb-tunnel.log" 2>&1 || fail "adb-tunnel.sh up failed"
timeout 60 "$ADB" -s "$SERIAL" push "$APK" /data/local/tmp/rhizo-storagetest.apk > "$EV/push.log" 2>&1 \
  || fail "adb push of the test apk failed"
inst=$(ANDROID_SH_TIMEOUT=180 android_sh "$INIT" \
  "pm install -r -t -g --user 0 /data/local/tmp/rhizo-storagetest.apk" 2>&1 | tr -d '\r')
grep -qx "Success" <<<"$inst" || fail "pm install did not print a literal Success (got: $inst)"
pkgs=$(android_sh "$INIT" "pm list packages" 2>/dev/null | tr -d '\r')
grep -qx "package:$pkg" <<<"$pkgs" \
  || fail "$pkg is absent from pm list packages after a reported install"
pass "installed $pkg"

# start the app and print its log lines
drive_app() {
  local rp="$1" wp="$2" content="$3" deadline
  android_sh "$INIT" "am force-stop $pkg" >/dev/null 2>&1
  android_sh "$INIT" "logcat -c" >/dev/null 2>&1
  android_sh "$INIT" "am start -n $pkg/$act --es read_path '$rp' --es write_path '$wp' \
    --es write_content '$content'" >/dev/null 2>&1
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    out=$(logcat_vm "$INIT" -d -s "RhizoStorageTest:I" 2>/dev/null | tr -d '\r')
    grep -q "RHIZO_STORAGE_WRITE_" <<<"$out" && { printf '%s\n' "$out"; return 0; }
    sleep 1
  done
  printf '%s\n' "${out:-}"
  return 1
}

step "5. host -> app: the app reads the user's file"
run1=$(drive_app "$SHARE_NAME/from-the-host.txt" "$SHARE_NAME/from-the-app.txt" "$APP_TEXT") \
  || fail "the app never logged a write result within 30s"
printf '%s\n' "$run1" > "$EV/app-run1.log"
printf '%s\n' "$run1" | grep RHIZO_STORAGE | sed 's/^.*RhizoStorageTest: /  /'
want_sha=$(host_sha "$HOST_DIR/from-the-host.txt")
got_sha=$(grep -o 'RHIZO_STORAGE_READ_OK .*' <<<"$run1" | grep -o 'sha256=[0-9a-f]*' | cut -d= -f2 | tail -1)
[[ -n "$got_sha" ]] || fail "the app did not report RHIZO_STORAGE_READ_OK"
[[ ${#want_sha} == 64 ]] || fail "could not digest the host file ('$want_sha')"
[[ "$got_sha" == "$want_sha" ]] || fail "the app read different bytes than the host file holds (app $got_sha, host $want_sha)"
app_uid=$(grep -o 'RHIZO_STORAGE_UID uid=[0-9]*' <<<"$run1" | cut -d= -f2 | tail -1)
[[ -n "$app_uid" && "$app_uid" != "0" ]] || fail "the app did not run as an app uid (got '${app_uid:-none}')"
pass "the app, as uid $app_uid, read the user's own file byte for byte"

step "6. app -> host: what the app saved is a real file of the user's"
grep -q "RHIZO_STORAGE_WRITE_OK" <<<"$run1" || fail "the app did not report RHIZO_STORAGE_WRITE_OK"
hostside=$(as_owner 25 "test -f $HOST_DIR/from-the-app.txt && stat -c %s:%u:%g $HOST_DIR/from-the-app.txt && sha256sum $HOST_DIR/from-the-app.txt" 2>&1 | tr -d '\r')
printf '%s\n' "$hostside" > "$EV/app-write-hostside.log"
if [[ -z "$hostside" || "$hostside" == *"No such file"* ]]; then
  fail "the file the app saved is not in the host directory"
else
  h_uid=$(sed -n '1p' <<<"$hostside" | cut -d: -f2)
  h_sha=$(sed -n '2p' <<<"$hostside" | cut -d' ' -f1)
  a_sha=$(grep -o 'RHIZO_STORAGE_WRITE_OK .*' <<<"$run1" | grep -o 'sha256=[0-9a-f]*' | cut -d= -f2 | tail -1)
  [[ ${#a_sha} == 64 ]] || fail "the app reported no digest for what it wrote"
  [[ "$h_sha" == "$a_sha" ]] || fail "host-side bytes differ from what the app wrote (host $h_sha, app $a_sha)"
  [[ "$h_uid" == "1000" ]] || fail "the saved file belongs to uid $h_uid, not to the user who owns the share"
  log "host side: $(tr '\n' ' ' <<<"$hostside")"
fi
pass "the app's save landed in $HOST_DIR as the user's own file"

step "7. one file, not two copies"
as_owner 25 "printf %s\\n \"$REWRITE_TEXT\" > $HOST_DIR/from-the-host.txt" \
  || fail "could not rewrite the host file in place"
after_ino=$(as_owner 20 "stat -c %i $HOST_DIR/from-the-host.txt" | tr -d '\r')
[[ "$after_ino" == "$HOST_INO" ]] || fail "the host file changed inode ($HOST_INO -> $after_ino); it was replaced, not written"
run2=$(drive_app "$SHARE_NAME/from-the-host.txt" "$SHARE_NAME/from-the-app-2.txt" "$APP_TEXT-2") \
  || fail "the app never logged a second run"
printf '%s\n' "$run2" > "$EV/app-run2.log"
got2=$(grep -o 'RHIZO_STORAGE_READ_OK .*' <<<"$run2" | grep -o 'sha256=[0-9a-f]*' | cut -d= -f2 | tail -1)
want2=$(host_sha "$HOST_DIR/from-the-host.txt")
[[ "$want2" != "$want_sha" ]] || fail "the rewrite did not change the host file at all"
[[ "$got2" == "$want2" ]] \
  || fail "the app did not see the host's in-place rewrite (app ${got2:-none}, host $want2)"
pass "a host-side rewrite under the same inode was visible to the app immediately"

step "8. the user's files were not mutated to buy the access"
before_owner=$(cut -d: -f2,3 <<<"$BEFORE")
after_xattr=$(host_label "$HOST_DIR/from-the-host.txt")
[[ "$after_xattr" == PROBE-FAILED* ]] && fail "the SELinux-xattr probe stopped working: $after_xattr"
[[ "$after_xattr" == "$BEFORE_XATTR" ]] \
  || fail "the host file's SELinux xattr changed ('$BEFORE_XATTR' -> '$after_xattr')"
now_owner=$(as_owner 20 "stat -c %u:%g $HOST_DIR/from-the-host.txt" | tr -d '\r')
[[ "$now_owner" == "$before_owner" ]] \
  || fail "the host file was chowned ($before_owner -> $now_owner)"
pass "the user's file kept its owner ($now_owner) and its label ($after_xattr)"

step "9. no denial paid for it"
avc=$(ssh_vm -t 30 "dmesg | grep 'avc: *denied'" 2>/dev/null | tr -d '\r')
printf '%s\n' "$avc" > "$EV/avc.log"
total=$(grep -c 'avc: *denied' <<<"$avc" || true)
(( total > 0 )) || fail "no AVC records at all"
ours=$(grep -E "tcontext=u:object_r:(fuse|media_rw_data_file|mnt_user_file|fuse_device):" <<<"$avc" \
       | grep -v permissive=1 || true)
if [[ -n "$ours" ]]; then
  printf '%s\n' "$ours" | head -8 | sed 's/^/  /'
  fail "$(grep -c . <<<"$ours") enforcing denial(s) on the storage path"
fi
pass "$total AVC records present, none of them enforcing denials on the storage types"

step "10. regression"
SS_PID_END=$(system_server_pid "$INIT")
boot_end=$(getprop_live "$INIT" sys.boot_completed) || boot_end="<unreadable rc=$?>"
[[ "$SS_PID_START" == "$SS_PID_END" ]] || fail "system_server restarted ($SS_PID_START -> $SS_PID_END)"
[[ "$boot_end" == "1" ]] || fail "sys.boot_completed is '$boot_end'"
logcat_vm "$INIT" -d -t "$SINCE" 2>/dev/null > "$EV/logcat-since-start.txt"
logcat_out=$(cat "$EV/logcat-since-start.txt")
bad=$(grep -cE "$TEST_FATAL_RE" <<<"$logcat_out" || true)
if ! test_logcat_capture_read "$EV/logcat-since-start.txt"; then
  fail "the fatal sweep read no logcat since '$SINCE' -- an unreadable log is not a clean one"
elif [[ "$bad" != "0" ]]; then
  fail "logcat carries $bad fatal/watchdog line(s)"
  grep -E "$TEST_FATAL_RE" <<<"$logcat_out" | head -5
fi
pass "system_server intact, boot_completed=1, no fatal lines"

step "11. mode=under: MediaProvider serves and indexes the same directory"
ssh_vm -t 60 "systemctl stop rhizo-hostfs.service" >/dev/null 2>&1
ssh_vm -t 30 "printf '[%s]\\ndir = %s\\nuser = %s\\nmode = under\\n%s\\n' '$SHARE_NAME' '$HOST_DIR' '$SHARE_USER' '$DAEMON_LINE' > $CONF" \
  || fail "could not write the under-mode config"
ssh_vm -t 90 "systemctl restart rhizo-hostfs.service" >/dev/null 2>&1
u_state=activating
u_deadline=$(( $(date +%s) + 120 ))
while (( $(date +%s) < u_deadline )); do
  u_state=$(ssh_vm -t 20 "systemctl is-active rhizo-hostfs.service" | tr -d '\r')
  [[ "$u_state" == "activating" ]] || break
  sleep 3
done
[[ "$u_state" == "active" ]] || fail "the unit is '$u_state' in under mode"
uline=$(ssh_vm -t 20 "grep ' /data/media/0/$SHARE_NAME ' /proc/$INIT/mountinfo" | tr -d '\r')
[[ "$uline" == *" - fuse "* ]] || fail "under mode did not mount fuse at the lower path: ${uline:-none}"
seen=$(android_sh "$INIT" "ls -Z /storage/emulated/0/$SHARE_NAME/" 2>/dev/null | tr -d '\r')
grep -q "from-the-host.txt" <<<"$seen" || fail "the host file does not surface through MediaProvider's FUSE"
grep -q "u:object_r:fuse:s0" <<<"$seen" || fail "what surfaced is not fuse-labeled: $seen"
run3=$(drive_app "$SHARE_NAME/from-the-host.txt" "$SHARE_NAME/under-made.txt" "$APP_TEXT-under") || true
printf '%s\n' "$run3" > "$EV/app-run3.log"
u_app=$(grep -o 'RHIZO_STORAGE_WRITE_OK .*' <<<"$run3" | grep -o 'sha256=[0-9a-f]*' | cut -d= -f2 | tail -1)
[[ ${#u_app} == 64 ]] || fail "the app could not save into an under-mode share"
u_host=$(host_sha "$HOST_DIR/under-made.txt")
[[ "$u_app" == "$u_host" ]] || fail "under-mode save differs on the host (app $u_app, host $u_host)"
u_owner=$(as_owner 20 "stat -c %u $HOST_DIR/under-made.txt" | tr -d '\r')
[[ "$u_owner" == "1000" ]] || fail "the under-mode save belongs to uid $u_owner, not the share's owner"
android_sh "$INIT" "content call --uri content://media --method scan_volume --arg external_primary" >/dev/null 2>&1
sleep 6
rows=$(android_sh "$INIT" "content query --uri content://media/external/file --projection _id:_data --where \"_data LIKE '%/$SHARE_NAME/%'\"" 2>/dev/null | tr -d '\r')
printf '%s\n' "$rows" | sed 's/^/  /' | tail -4
grep -q "from-the-host.txt" <<<"$rows" || fail "MediaStore has no row for the user's file after a scan"
grep -q "under-made.txt" <<<"$rows" || fail "MediaStore has no row for the file the app saved"
grep -q "RHIZO_STORAGE_READ_FAIL" <<<"$run3" \
  || fail "an ordinary app read a file it did not create"
pass "under mode: fuse at the lower path, indexed by MediaStore, app saves land on the host, reads mediated by scoped storage"

if (( KEEP == 0 )); then
  step "11. detaching takes the daemon with it"
  before_n=$(ssh_vm -t 20 "grep -l rhizo-hostfsd /proc/[0-9]*/comm 2>/dev/null | wc -l" | tr -d '\r')
  ssh_vm -t 60 "systemctl stop rhizo-hostfs.service" >/dev/null 2>&1 \
    || fail "stopping rhizo-hostfs.service failed"
  still=$(ssh_vm -t 20 "grep -c ' /mnt/user/0/emulated/0/$SHARE_NAME ' /proc/$INIT/mountinfo" | tr -d '\r')
  [[ "$still" == "0" ]] || fail "the share is still mounted after the unit was stopped"
  gone=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    after_n=$(ssh_vm -t 20 "grep -l rhizo-hostfsd /proc/[0-9]*/comm 2>/dev/null | wc -l" | tr -d '\r')
    [[ "$after_n" == "0" ]] && { gone=1; break; }
    sleep 1
  done
  [[ "$before_n" -ge 1 ]] || fail "no rhizo-hostfsd was running before the detach"
  (( gone )) || fail "rhizo-hostfsd is still running $after_n time(s) after the detach"
  pass "stopping the unit released the share and its daemon exited ($before_n -> 0)"
  as_owner 20 "rm -rf $HOST_DIR" >/dev/null 2>&1
  ssh_vm -t 20 "rm -f $CONF" >/dev/null 2>&1
fi

if (( FAILED )); then
  test_record_verdict FAILED
  log "STORAGE SYSTEM TEST FAILED"
  exit 1
fi
test_record_verdict PASSED
log "STORAGE SYSTEM TEST PASSED -- evidence in $EV"
