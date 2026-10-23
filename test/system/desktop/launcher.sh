#!/bin/bash
# test launching two apps with rhizo-launch.sh
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: shared
# test-boots-unit: yes
# test-records-metrics: no
# test-requires: file:aapt2
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
source ../lib/desktop-lib.sh \
  || { fail "desktop profile ${RHIZO_DESKTOP_PROFILE:-sway} unavailable"; exit 1; }

SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
[[ "${1:-}" == "--skip-boot" ]] && SKIP_BOOT=1

test_init launcher
WORKDIR="$TEST_WORKDIR"

# print the composer display id
cdisp_of() {
  local c
  c=$(grep -o 'cdisplay=[0-9]*' <<<"$1" | cut -d= -f2)
  [[ -n "$c" ]] || c=$(grep -oE '(^|[[:space:]])display=[0-9]+' <<<"$1" | tail -1 | cut -d= -f2)
  printf '%s' "$c"
}

# print the framework display id
logid_of() {
  grep -oE '(^|[[:space:]])display=[0-9]+' <<<"$1" | tail -1 | cut -d= -f2
}

# print the committed value of a launch line
committed_of() {
  grep -oE 'committed=[A-Za-z]+' <<<"$1" | tail -1 | cut -d= -f2
}

# check the committed value of a launch
assert_power_confirmed() {
  local label="$1" logid="$2" committed="$3"
  case "$committed" in
    ON|confirmed|skipped)
      pass "$label: display=$logid reported committed=$committed" ;;
    *)
      fail "$label: display=$logid reported committed=${committed:-<none>}, which assert_power_confirmed does not recognize" ;;
  esac
}

# check the icon files of an entry
check_entry_icon() {
  local pkg="$1" icon files path dir sz w h want n=0
  icon=$(entry_field "$2" Icon)
  files=$(ssh_vm -t 20 "find $ICONS_DIR -type f -name 'rhizo-$pkg.png' -print; echo LISTED")
  grep -qx LISTED <<<"$files" || { fail "$pkg: the hicolor walk did not complete"; return; }
  if [[ "$icon" == rhizo ]]; then
    [[ "$(ssh_vm -t 10 "if [ -f $ICONS_DIR/256x256/apps/rhizo.png ]; then echo PRESENT; else echo ABSENT; fi" | tr -d '\r')" == PRESENT ]] \
      || fail "$pkg: Icon=rhizo but there is no generic icon under $ICONS_DIR/256x256/apps"
    return
  fi
  [[ "$icon" == "rhizo-$pkg" ]] || { fail "$pkg: Icon= is '$icon', expected rhizo-$pkg or rhizo"; return; }
  while read -r -u 3 path; do
    [[ "$path" == /* ]] || continue
    dir=$(basename "$(dirname "$(dirname "$path")")")
    pull "$path" "$WORKDIR/icon-$pkg-$dir.png" || { fail "$pkg: could not pull $path"; continue; }
    if ! sz=$(png_ihdr "$WORKDIR/icon-$pkg-$dir.png"); then
      fail "$pkg: $path is not a PNG this system test can read an IHDR out of"
      continue
    fi
    read -r w h <<<"$sz"
    want=$(expected_size_dir "$(( w < h ? w : h ))")
    if [[ -z "$want" ]]; then
      fail "$pkg: a ${w}x${h} raster is filed under $dir, and no standard hicolor size is that small"
    elif [[ "$dir" != "${want}x${want}" ]]; then
      fail "$pkg: a ${w}x${h} raster is filed under $dir, the largest standard size it fits is ${want}x${want}"
    fi
    n=$(( n + 1 ))
  done 3< <(grep -v '^LISTED$' <<<"$files")
  (( n > 0 )) || fail "$pkg: Icon=$icon names no file under $ICONS_DIR"
  log "    $pkg: $n icon(s), each under the hicolor directory its own IHDR size names"
}

# check the format of one .desktop entry
check_entry_format() {
  local pkg="$1" f="$2" guest="$3" id v
  id="rhizo-$pkg"
  [[ "$guest" == "$APPS_DIR/$id.desktop" ]] \
    || fail "$pkg: the manifest puts its entry at $guest, the contract says $APPS_DIR/$id.desktop"
  v=$(entry_field "$f" Exec)
  [[ "$v" == "rhizo launch $pkg %u" ]] || fail "$pkg: Exec= is '$v', expected 'rhizo launch $pkg %u'"
  v=$(entry_field "$f" StartupWMClass)
  [[ "$v" == "$id" ]] || fail "$pkg: StartupWMClass= is '$v', expected $id"
  v=$(entry_field "$f" StartupNotify)
  [[ "$v" == true ]] || fail "$pkg: StartupNotify= is '$v', expected true"
  v=$(entry_field "$f" X-Rhizo-Package)
  [[ "$v" == "$pkg" ]] || fail "$pkg: X-Rhizo-Package= is '$v', expected $pkg"
  grep -q '^X-Rhizo-Activity=' "$f" \
    || fail "$pkg: the entry has no X-Rhizo-Activity= line (empty is valid, absent is not)"
  grep -q '/root' "$f" && fail "$pkg: the entry still names a /root path"
  check_entry_icon "$pkg" "$f"
}

# check the toplevel app_id against the entry
assert_launch_identity() {
  local label="$1" pkg="$2" disp="$3" id ident app_id wmclass
  id="rhizo-$pkg"
  [[ -n "$disp" ]] || { fail "$label: no composer display id to resolve a toplevel on"; return; }
  if ! ident=$(resolve_display_toplevel "$disp"); then
    fail "$label: the composer reports no toplevel on display $disp"
    return
  fi
  app_id=${ident%% *}
  wmclass=$(entry_field "$WORKDIR/verify-$pkg.desktop" StartupWMClass)
  log "    $label: app_id='$app_id' desktop-file-id='$id' StartupWMClass='$wmclass'"
  [[ "$app_id" == "$id" ]] || fail "$label: the toplevel's app_id is '$app_id', its entry is $id.desktop"
  [[ "$wmclass" == "$id" ]] || fail "$label: StartupWMClass= is '$wmclass', the toplevel's app_id is '$app_id'"
}

# print the resumed activity of a display
resumed_on() {
  android_sh "$1" "dumpsys activity activities" \
    | awk -v want="Display #$2 " '/Display #/ {inseg = index($0, want) > 0}
                                   inseg && /topResumedActivity=/ {print; exit}' \
    | sed 's/.*ActivityRecord{[^ ]* [^ ]* \([^ }]*\).*/\1/'
}

AAPT2="${RHIZO_AAPT2:-$VAR_DIR/share/aapt2}"
[[ -x "$AAPT2" ]] || { fail "no aapt2 at $AAPT2 -- build it with tools/build/toolchain/aapt2.sh or set RHIZO_AAPT2"; test_record_verdict FAILED; exit 1; }

APPS_DIR=/usr/share/applications
ICONS_DIR=/usr/share/icons/hicolor
HICOLOR_SIZES="16 22 24 32 36 48 64 72 96 128 192 256 512"

# print the value of an entry key
entry_field() {
  awk -F= -v k="$2" '
    function unescape(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < length(s)) {
          i++
          c = substr(s, i, 1)
          if (c == "s") c = " "
          else if (c == "n") c = "\n"
          else if (c == "t") c = "\t"
          else if (c != "\\") out = out "\\"
        }
        out = out c
      }
      return out
    }
    /^\[/ { sect = ($0 == "[Desktop Entry]") }
    sect && $1 == k { sub(/^[^=]*=/, ""); print unescape($0); exit }' "$1"
}

# print the width and height of a PNG
png_ihdr() {
  python3 -c "
import struct, sys
b = open(sys.argv[1], 'rb').read(24)
if b[:8] != b'\x89PNG\r\n\x1a\n' or b[12:16] != b'IHDR':
    sys.exit(1)
print(*struct.unpack('>II', b[16:24]))
" "$1"
}

# print the hicolor size for a raster
expected_size_dir() {
  local s best=""
  for s in $HICOLOR_SIZES; do (( s <= $1 )) && best=$s; done
  printf '%s' "$best"
}

if (( SKIP_BOOT == 0 )); then
  step "0. boot: VM, compositor, Android"
  export RHIZO_USE_UNIT=1
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  desk_session_up >$EV/launcher-sway.log 2>&1 || { fail "the desktop session did not start (see $EV/launcher-sway.log)"; exit 1; }
  ../../vm/sync.sh >/dev/null || { fail "sync.sh failed"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 180 >$EV/launcher-redeploy.log 2>&1 || { fail "redeploy.sh failed (see $EV/launcher-redeploy.log)"; exit 1; }
  tail -3 $EV/launcher-redeploy.log
else
  test_ensure_desktop "$EV/chained-launcher-sway.log" "$EV/chained-redeploy.log"
fi
INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage"; exit 1; }
log "init_pid=$INIT"

boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || fail "sys.boot_completed='$boot_completed' at system test start"
SS_PID_START=$(system_server_pid "$INIT")
log "system_server pid at start: $SS_PID_START"
TEST_SINCE=$(logcat_since_marker "$INIT")

android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "locksettings set-disabled true" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null
awake=$(wait_device_awake "$INIT")
[[ "$awake" == "mWakefulness=Awake" ]] || fail "device is not awake ($awake)"
pass "booted, awake, keyguard disabled"
if wait_guest 120 "test -e /run/rhizo-display-pool/ready || journalctl -b -q -t rhizo-display-pool 2>/dev/null | grep -q 'stage=done\|attempt 5'"; then
  log "    boot prime settled: $(gcmd_user 'cat /run/rhizo-display-pool/ready 2>/dev/null || journalctl -b -q -t rhizo-display-pool -o cat | tail -1' 15 | tr -d '\r')"
else
  log "    boot prime reported nothing in 120s"
fi

step "1. .desktop synthesis"
ssh_vm -t 30 "find $APPS_DIR -maxdepth 1 -name 'rhizo-*.desktop' -exec grep -l '^X-Rhizo-Package=' {} + | xargs -r rm -f
find $ICONS_DIR -type f -name 'rhizo-*.png' -delete"
MANIFEST="$WORKDIR/rhizo-apps.json"
python3 ../../../src/services/appsync/appsync.py "$INIT" --manifest "$MANIFEST" --min-apps 2 > "$EV/appsync.log" 2>&1
rc=$?
tail -15 "$EV/appsync.log"
napps=$(python3 -c "import json; print(len(json.load(open('$MANIFEST'))['apps']))" 2>/dev/null || echo 0)
log "manifest reports $napps synthesized app(s), rc=$rc"
[[ "$napps" -ge 2 ]] || fail "fewer than 2 .desktop entries synthesized"
cp "$MANIFEST" "$EV/rhizo-apps.json"

python3 -c "
import json
m = json.load(open('$MANIFEST'))
for a in m['apps']:
    print(a['package'] + '\t' + a['apk_guest_path'] + '\t' + a['desktop_guest_path'] + '\t' + a['label'])
" > "$WORKDIR/apps.tsv"

verify_n=0
while IFS=$'\t' read -r -u 3 pkg apkpath dtpath label; do
  pull "$dtpath" "$WORKDIR/verify-$pkg.desktop" || { log "    $pkg: could not re-pull .desktop"; continue; }
  check_entry_format "$pkg" "$WORKDIR/verify-$pkg.desktop" "$dtpath"
  ondisk=$(entry_field "$WORKDIR/verify-$pkg.desktop" Name)
  [[ "$ondisk" == "$label" ]] || { fail "$pkg: on-disk Name= ('$ondisk') != manifest label ('$label')"; continue; }
  pull "$apkpath" "$WORKDIR/verify-$pkg.apk" || { log "    $pkg: could not re-pull APK"; continue; }
  pulled_badging=$("$AAPT2" dump badging "$WORKDIR/verify-$pkg.apk" 2>/dev/null)
  pulled_label=$(grep '^application-label:' <<<"$pulled_badging" | head -1 | sed "s/^application-label:'//;s/'\$//")
  [[ -n "$pulled_label" ]] || pulled_label=$(sed -n "s/^application: label='\(.*\)' icon='[^']*'.*/\1/p" <<<"$pulled_badging" | head -1)
  [[ "$pulled_label" == "$label" ]] || { fail "$pkg: new aapt2 label ('$pulled_label') != manifest label ('$label')"; continue; }
  verify_n=$((verify_n + 1))
  log "    re-verified $pkg: Name='$pulled_label' (new pull + new aapt2 run)"
done 3< "$WORKDIR/apps.tsv"
[[ "$verify_n" -ge 2 ]] || fail "fewer than 2 entries independently re-verified against a new aapt2 run"
pass ".desktop entries synthesized from real APKs and independently re-verified"

APP_A_PKG=com.android.messaging
read -r PKG1 ACT1 <<<"$(python3 -c "import json; a=[x for x in json.load(open('$MANIFEST'))['apps'] if x['package'] == '$APP_A_PKG']; print(a[0]['package'], a[0]['activity']) if a else None")"
[[ "$PKG1" == "$APP_A_PKG" && -n "$ACT1" ]] || { fail "the manifest has no entry for app A, $APP_A_PKG"; exit 1; }
log "    app A: $PKG1/$ACT1"

step "2. primed spare: unmapped, unpainted"
primary_id=$(_desktop_window_id_for_identity rhizo Rhizo 20)
[[ -n "$primary_id" ]] && desk_window_op "$primary_id" move 0 1080
if (( SKIP_BOOT )); then
  log "    skipped: this is a chained (--skip-boot) run, and the spare pool only refills on an app launch through rhizo-launch.sh"
  pass "spare check skipped on a chained run (see log)"
else
spare_id="" dlist=""
outer_deadline=$(( $(date +%s) + 60 ))
while (( $(date +%s) < outer_deadline )); do
  before_n=$(rhizo_ctl_out "$INIT" | grep -c '^display list' || true)
  rhizo_ctl "$INIT" display list >/dev/null
  reply_deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < reply_deadline )); do
    after_n=$(rhizo_ctl_out "$INIT" | grep -c '^display list' || true)
    if [[ "${after_n:-0}" -gt "${before_n:-0}" ]]; then
      dlist=$(rhizo_ctl_out "$INIT" | grep '^display list' | tail -1)
      break
    fi
    sleep 1
  done
  spare_id=$(rhizo_dl_spares "$dlist" | head -1)
  [[ -n "$spare_id" ]] && break
  sleep 1
done
if [[ -z "$spare_id" ]]; then
  fail "no primed spare in 'display list' after 60s: $dlist"
else
  log "    primed spare: composer id=$spare_id ($dlist)"
  windows=$(desk_windows)
  echo "$windows" > "$EV/spare-sway-windows.txt"
  if desktop_window_rect "$spare_id" >/dev/null 2>&1; then
    fail "spare $spare_id has a mapped sway toplevel"
  fi
  if desk_shot /tmp/test-launcher-spare-before.png && pull /tmp/test-launcher-spare-before.png "$WORKDIR/spare-before.png" 90; then
    sleep 5
    if desk_shot /tmp/test-launcher-spare-after.png && pull /tmp/test-launcher-spare-after.png "$WORKDIR/spare-after.png" 90; then
      stats=$(python3 ../tools/pngstat.py --diff "$WORKDIR/spare-before.png" "$WORKDIR/spare-after.png")
      changed=$(grep '^changed=' <<<"$stats" | cut -d= -f2)
      echo "$stats" > "$EV/spare-unpainted-pngstat.txt"
      log "    spare $spare_id, 5s apart, no app open: $stats"
      [[ "${changed:-0}" == "0" ]] \
        || fail "the screen changed ($changed px) with spare $spare_id still unclaimed and no app open"
    else
      fail "could not take the 'after' screenshot for the spare-unpainted check"
    fi
  else
    fail "could not take the 'before' screenshot for the spare-unpainted check"
  fi
  pass "spare $spare_id stays surfaceless: no sway toplevel, nothing painted 5s apart"
fi
fi

step "3. launch wrapper: app A"
desktop_close_all_app_windows 20 "rhizo-$PKG1" || fail "app A's open windows did not close before its launch"
out=$(ssh_vm -t 45 "/usr/bin/rhizo launch $PKG1" 2>&1); launch_rc=$?
log "    rhizo launch exit output: $out"
log "    rhizo launch rc=$launch_rc"
line1=$(ssh_vm -t 10 "tail -1 /run/rhizo-launch/rhizo-launch.log" 2>/dev/null)
log "    launch log: $line1"
cdisp1=$(cdisp_of "$line1")
logid1=$(logid_of "$line1")
committed1=$(committed_of "$line1")
[[ -n "$logid1" ]] || { fail "app A: rhizo-launch.sh produced no display id"; }
[[ "$committed1" != skipped ]] || fail "app A: the launch reused a display app A already had, and this step proves one being made"
resumed1=""
if [[ -n "$logid1" ]]; then
  for _ in $(seq 1 20); do
    resumed1=$(resumed_on "$INIT" "$logid1")
    [[ -n "$resumed1" ]] && break
    sleep 1
  done
fi
log "    app A: display=$logid1 cdisplay=$cdisp1 dumpsys resumed='$resumed1' (expect '$PKG1/$ACT1')"
[[ "$resumed1" == "$PKG1/$ACT1" ]] || fail "app A: dumpsys shows '$resumed1', expected '$PKG1/$ACT1'"
pass "rhizo-launch.sh $PKG1 $ACT1 -> real display $cdisp1, correct resumed activity"
assert_power_confirmed appA "$logid1" "$committed1"
[[ -n "$cdisp1" ]] && assert_window_painted appA "$cdisp1"
assert_launch_identity appA "$PKG1" "$cdisp1"

step "4. launch wrapper: app B (app A still open)"
before_disps=$(android_sh "$INIT" "dumpsys display" | grep -c "^  Display Id=")
cdisp2=""; logid2=""; resumed2=""; committed2=""; PKG2=""; ACT2=""
APP_B_PKG=com.android.settings
read -r cand_pkg cand_act <<<"$(python3 -c "import json; a=[x for x in json.load(open('$MANIFEST'))['apps'] if x['package'] == '$APP_B_PKG']; print(a[0]['package'], a[0]['activity']) if a else None")"
[[ "$cand_pkg" == "$APP_B_PKG" && -n "$cand_act" ]] || { fail "the manifest has no entry for app B, $APP_B_PKG"; exit 1; }
log "    app B: trying $cand_pkg/$cand_act"
desktop_close_all_app_windows 20 "rhizo-$cand_pkg" || log "    app B's open windows did not close"
out=$(ssh_vm -t 45 "/usr/bin/rhizo launch $cand_pkg" 2>&1)
line2=$(ssh_vm -t 10 "tail -1 /run/rhizo-launch/rhizo-launch.log" 2>/dev/null)
log "    launch log: $line2"
cand_cdisp=$(cdisp_of "$line2")
cand_logid=$(logid_of "$line2")
cand_committed=$(committed_of "$line2")
if [[ -z "$cand_cdisp" || "$cand_cdisp" == "$cdisp1" || "$cand_committed" == skipped ]]; then
  log "    app B $cand_pkg produced no new display (committed=${cand_committed:-<none>})"
else
  cand_resumed=""
  for _ in $(seq 1 15); do
    cand_resumed=$(resumed_on "$INIT" "$cand_logid")
    [[ -n "$cand_resumed" ]] && break
    sleep 1
  done
  log "    app B $cand_pkg: display=$cand_logid cdisplay=$cand_cdisp dumpsys resumed='$cand_resumed'"
  if [[ "$cand_resumed" == "$cand_pkg/$cand_act" ]]; then
    PKG2="$cand_pkg"; ACT2="$cand_act"; cdisp2="$cand_cdisp"; logid2="$cand_logid"; resumed2="$cand_resumed"
    committed2="$cand_committed"
  else
    log "    app B $cand_pkg did not resolve to itself (got '$cand_resumed')"
  fi
fi
[[ -n "$cdisp2" ]] || fail "app B, $APP_B_PKG, did not launch cleanly"
log "    app B: $PKG2/$ACT2 -> display=$logid2 cdisplay=$cdisp2 dumpsys resumed='$resumed2'"
[[ -n "$PKG2" && "$resumed2" == "$PKG2/$ACT2" ]] || fail "app B never resolved to a clean launch"
assert_power_confirmed appB "$logid2" "$committed2"

resumed1_after=""
deadline=$(( $(date +%s) + 10 ))
while (( $(date +%s) < deadline )); do
  resumed1_after=$(resumed_on "$INIT" "$logid1")
  [[ "$resumed1_after" == "$PKG1/$ACT1" ]] && break
  sleep 0.5
done
log "    app A still: display=$logid1 dumpsys resumed='$resumed1_after'"
[[ "$resumed1_after" == "$PKG1/$ACT1" ]] || fail "app A's display changed/died after launching app B ($resumed1_after)"

after_disps=$(android_sh "$INIT" "dumpsys display" | grep -c "^  Display Id=")
log "    display count: $before_disps -> $after_disps (unchanged is correct when app B claims a spare)"
[[ -n "$logid2" && "$logid2" != "$logid1" ]] \
  || fail "app B did not get its own display (app A=$logid1, app B=$logid2)"
(( after_disps >= before_disps )) || fail "a display was lost launching app B ($before_disps -> $after_disps)"
pass "two concurrent real displays, two different real apps, both correct per dumpsys: $PKG1 and $PKG2"
[[ -n "$cdisp2" ]] && assert_window_painted appB "$cdisp2"
[[ -n "$PKG2" ]] && assert_launch_identity appB "$PKG2" "$cdisp2"
[[ -n "$cdisp1" ]] && assert_window_painted appA-still "$cdisp1"
assert_launch_identity appA-still "$PKG1" "$cdisp1"

step "5. regression check"
SS_PID_END=$(system_server_pid "$INIT")
boot_end=$(getprop_live "$INIT" sys.boot_completed) || boot_end="<unreadable rc=$?>"
log "    system_server pid $SS_PID_START -> $SS_PID_END, sys.boot_completed=$boot_end"
[[ "$SS_PID_START" == "$SS_PID_END" ]] || fail "system_server restarted ($SS_PID_START -> $SS_PID_END)"
[[ "$boot_end" == "1" ]] || fail "sys.boot_completed is '$boot_end'"
logcat_vm "$INIT" -d -t "$TEST_SINCE" 2>/dev/null > "$EV/logcat-since-start.txt"
grep -E -B2 -A6 "$TEST_FATAL_RE" "$EV/logcat-since-start.txt" > "$EV/fatal-lines.txt" 2>/dev/null
cp "$EV/logcat-since-start.txt" "$EV/fatal-logcat-full.txt"
test_logcat_capture_read "$EV/logcat-since-start.txt" \
  || fail "$EV/logcat-since-start.txt holds no logcat line"
bad=$(grep -cE "$TEST_FATAL_RE" "$EV/fatal-lines.txt" 2>/dev/null)
bad=${bad:-0}
log "    fatal/watchdog lines in logcat: $bad (crash events: $(test_crash_events "$EV/logcat-since-start.txt"))"
[[ "$bad" == "0" ]] || {
  fail "logcat has $bad fatal/watchdog lines"
  test_fatal_lines "$EV/logcat-since-start.txt"
}

step "6. close the app windows this system test opened and remove their displays"
# print the Android display ids
lch_display_ids() { android_sh "$INIT" "dumpsys display" | grep -oE "^  Display Id=[0-9]+" | grep -oE "[0-9]+$" | sort -n | tr '\n' ' '; }
# read the composer display list line
lch_dlist() {
  local before; before=$(rhizo_ctl_out "$INIT" | grep -c '^display list')
  rhizo_ctl "$INIT" display list >/dev/null
  local _
  for _ in $(seq 1 15); do
    if (( $(rhizo_ctl_out "$INIT" | grep -c '^display list') > before )); then
      rhizo_ctl_out "$INIT" | grep '^display list' | tail -1; return 0
    fi
    sleep 1
  done
  return 1
}
log "    app windows mapped: $(desktop_app_toplevel_count)"
desk_windows | sed 's/^/      /'
desktop_close_all_app_windows 20 || log "    desktop_close_all_app_windows did not clear them all"
dlist=$(lch_dlist); log "    composer display list: ${dlist#display list }"
spare_cid=$(rhizo_dl_spares "$dlist" | head -1)
spare_lid=""
if [[ -n "$spare_cid" ]]; then
  spare_port=$(rhizo_ctl_out "$INIT" | grep -o "display pooled id=$spare_cid port=[0-9]*" | tail -1 | grep -o 'port=[0-9]*' | cut -d= -f2)
  [[ -n "$spare_port" ]] && spare_lid=$(resolve_logical_id "$spare_port")
fi
for cid in $(grep -oE '[0-9]+\([0-9]+x[0-9]+\)' <<<"$dlist" | grep -oE '^[0-9]+'); do
  [[ "$cid" == 1 ]] && continue
  rhizo_ctl "$INIT" display remove "$cid" >/dev/null
done
allowed="$(resolve_logical_id 0) $spare_lid"
# check for leftover displays and app windows
lch_clean() {
  local id
  for id in $(lch_display_ids); do grep -qw "$id" <<<"$allowed" || return 1; done
  [[ "$(desktop_app_toplevel_count)" == 0 ]]
}
ids_end=""
for _ in $(seq 1 30); do ids_end=$(lch_display_ids); lch_clean && break; sleep 1; done
if lch_clean; then
  pass "app windows closed, displays [$ids_end] are the primary plus the spare (logical ${spare_lid:-none})"
else
  android_sh "$INIT" "dumpsys display" > "$EV/leftover-dumpsys-display.txt" 2>&1
  rhizo_ctl_out "$INIT" > "$EV/leftover-composer-control.txt" 2>&1
  desk_windows > "$EV/leftover-sway-windows.txt" 2>&1
  fail "displays [$ids_end] are not the primary plus the spare (logical ${spare_lid:-none}), or an app window is still mapped (see $EV/leftover-*.txt)"
fi

# print a systemd property of a guest unit
unit_prop() { ssh_vm -t 10 "systemctl show -p $2 --value $1" | tr -d '\r'; }
# wait for a guest unit to be active
await_active() {
  local deadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < deadline )); do
    [[ "$(unit_prop "$1" ActiveState)" == active ]] && return 0
    sleep 2
  done
  return 1
}
# wait for a guest unit's main process to start again
await_started() {
  local deadline=$(( $(date +%s) + 60 ))
  while (( $(date +%s) < deadline )); do
    [[ "$(unit_prop "$1" ExecMainStartTimestampMonotonic)" != "$2" ]] && return 0
    sleep 2
  done
  return 1
}

step "7. a desktop session that arrives after Android starts the bridge and the audio host"
androidd_state=$(unit_prop androidd.service ActiveState)
[[ "$androidd_state" == active ]] || fail "androidd.service is '$androidd_state': this leg needs Android started by its unit"
desk_user=$(ssh_vm -t 10 "stat -c %U /run/rhizo-desktop/session.env" | tr -d '\r')
desk_uid=$(ssh_vm -t 10 "stat -c %u /run/rhizo-desktop/session.env" | tr -d '\r')
[[ "$desk_uid" =~ ^[0-9]+$ ]] || fail "no session.env owner to act as (got '$desk_user' '$desk_uid')"
pipewire=$(ssh_vm -t 15 "runuser -u $desk_user -- env XDG_RUNTIME_DIR=/run/user/$desk_uid systemctl --user is-active pipewire.service" | tr -d '\r')
desk_gate=$(ssh_vm -t 10 '/usr/lib/rhizo/tools/capability-allowed.sh --any desktop.clipboard desktop.notifications desktop.drag desktop.open_uri >/dev/null 2>&1; echo $?' | tr -d '\r')
audio_gate=$(ssh_vm -t 10 '/usr/lib/rhizo/tools/capability-allowed.sh audio.out >/dev/null 2>&1; echo $?' | tr -d '\r')
gcmd_root "systemctl stop rhizo-deskd.service rhizo-audiod.service" 30 || fail "could not stop the desktop daemons"
gcmd_root "runuser -u $desk_user -- rm -f /run/rhizo-desktop/session.env" 20 \
  || fail "could not remove session.env as its owner $desk_user"
gcmd_root "systemctl start rhizo-deskd.service rhizo-audiod.service" 30 \
  || fail "starting the desktop daemons with no session failed instead of being skipped"
for unit in rhizo-deskd.service rhizo-audiod.service; do
  state="$(unit_prop "$unit" ActiveState) $(unit_prop "$unit" ConditionResult)"
  [[ "$state" == "inactive no" ]] \
    || fail "$unit with no session.env reads '$state', want 'inactive no' (skipped by its ConditionPathExists=)"
done
attach_before=$(unit_prop rhizo-desktop-attach.service InvocationID)
deskd_t0=$(unit_prop rhizo-deskd.service ExecMainStartTimestampMonotonic)
audiod_t0=$(unit_prop rhizo-audiod.service ExecMainStartTimestampMonotonic)
test_publish_session_env || fail "could not publish the desktop session env"
if [[ "$desk_gate" == 0 ]]; then
  await_active rhizo-deskd.service || fail "rhizo-deskd did not start within 60 s of the session arriving"
  [[ "$(unit_prop rhizo-deskd.service ExecMainStartTimestampMonotonic)" != "$deskd_t0" ]] \
    || fail "rhizo-deskd reads active without a new start for the session"
else
  log "    no desktop.* capability is on (gate rc=$desk_gate): rhizo-deskd's start is the gate's to skip"
fi
attach_now=$(unit_prop rhizo-desktop-attach.service InvocationID)
attach_result=$(unit_prop rhizo-desktop-attach.service Result)
[[ -n "$attach_now" && "$attach_now" != "$attach_before" && "$attach_result" == success ]] \
  || fail "rhizo-desktop-attach.service did not run for the new session (InvocationID '$attach_before' -> '$attach_now', Result=$attach_result)"
if [[ "$audio_gate" == 0 ]]; then
  await_started rhizo-audiod.service "$audiod_t0" || fail "the session's arrival never started rhizo-audiod (audio.out is on)"
  audiod_t1=$(unit_prop rhizo-audiod.service ExecMainStartTimestampMonotonic)
  gcmd_root "systemctl stop rhizo-audiod.service" 20 || fail "could not stop rhizo-audiod for the re-login leg"
  test_publish_session_env || fail "could not publish the desktop session env again"
  await_started rhizo-audiod.service "$audiod_t1" || fail "the next session write never started rhizo-audiod again"
  if [[ "$pipewire" == active ]]; then
    await_active rhizo-audiod.service || fail "rhizo-audiod started for the session but is not active, with PipeWire running"
  else
    log "    the session runs no PipeWire ($pipewire): rhizo-audiod was started and stopped on its own PipeWire check"
  fi
else
  log "    audio.out is off on this guest (gate rc=$audio_gate): rhizo-audiod's start is the gate's to skip"
fi

if (( FAILED )); then log "LAUNCHER SYSTEM TEST FAILED"
test_record_verdict FAILED; exit 1; fi
log "LAUNCHER SYSTEM TEST PASSED -- evidence in $EV"
test_record_verdict PASSED
