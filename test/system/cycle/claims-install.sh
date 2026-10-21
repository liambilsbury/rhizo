#!/bin/bash
# define the install, cli, packaging, readme and host account claim checks

# return whether a bare step's last row in claims.tsv says pass
_lc_step_passed() {
  [[ -n "${EV:-}" && -s "$EV/claims.tsv" ]] || return 1
  local r; r=$(awk -F'\t' -v id="step.$1" 'NR>1 && $1==id{r=$2} END{print r}' "$EV/claims.tsv")
  [[ "$r" == pass ]]
}

# return whether a claim's last row in claims.tsv says pass
_lc_claim_passed() {
  [[ -n "${EV:-}" && -s "$EV/claims.tsv" ]] || return 1
  local r; r=$(awk -F'\t' -v id="$1" 'NR>1 && $1==id{r=$2} END{print r}' "$EV/claims.tsv")
  [[ "$r" == pass ]]
}

# print the SELinux mode the cycle pins
lc_selinux_mode() { printf '%s' "${INSTALLER_SELINUX_MODE:-namespace}"; }

# fail a host-mode claim outside host mode
lc_claim_host_mode() {
  local id="$1" what="$2" mode
  mode=$(lc_selinux_mode)
  [[ "$mode" == host ]] && return 0
  fail "$id: $mode mode: this claim asserts host mode's $what"
  return 1
}

# check step 1's install requires a reboot and sets security=selinux
lc_assert_cli.install() {
  lc_need_guest cli.install || return 1
  lc_claim_host_mode cli.install "selinux token in the bootloader file" || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "cli.install: no cycle profile argument"; return 1; }
  local log_file="$EV/cycle-$p1-install.log"
  if [[ ! -s "$log_file" ]]; then
    fail "cli.install: no $log_file evidence from step 1"
    return 1
  fi
  grep -q 'REBOOT REQUIRED' "$log_file" \
    || { fail "cli.install: no 'REBOOT REQUIRED' in $log_file"; return 1; }
  if lc_on_cachyos; then
    local block; block=$(ssh_vm -t 20 "sed -n '/^# >>> rhizo/,/^# <<< rhizo/p' /etc/default/limine; echo DONE")
    lc_done_strip block || { fail "cli.install: incomplete read of /etc/default/limine (no DONE token): $block"; return 1; }
    [[ "$block" =~ lsm=[^\ \"]*selinux ]] \
      && pass "cli.install: host mode: $log_file reports REBOOT REQUIRED and /etc/default/limine's rhizo block names selinux in its lsm= list" \
      || { fail "cli.install: host mode: /etc/default/limine's rhizo block names no lsm= list with selinux: $block"; return 1; }
    return 0
  fi
  local grub; grub=$(ssh_vm -t 20 'cat /etc/default/grub.d/90-rhizo.cfg 2>/dev/null; echo DONE')
  lc_done_strip grub || { fail "cli.install: incomplete read of 90-rhizo.cfg (no DONE token): $grub"; return 1; }
  [[ "$grub" == *security=selinux* ]] \
    && pass "cli.install: host mode: $log_file reports REBOOT REQUIRED and /etc/default/grub.d/90-rhizo.cfg carries security=selinux" \
    || { fail "cli.install: host mode: /etc/default/grub.d/90-rhizo.cfg does not carry security=selinux: $grub"; return 1; }
}

# check step 1 prepared the current tree
lc_assert_cli.prepare() {
  lc_need_guest cli.prepare || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "cli.prepare: no cycle profile argument"; return 1; }
  local log_file="$EV/cycle-$p1-prepare.log"
  if [[ ! -s "$log_file" ]]; then
    fail "cli.prepare: no $log_file evidence from step 1"
    return 1
  fi
  local lines; lines=$(wc -l < "$log_file")
  grep -q 'RHIZO_PREPARE_OK' "$log_file" \
    || { fail "cli.prepare: no RHIZO_PREPARE_OK in $log_file ($lines lines)"; return 1; }
  local key; key=$(ssh_vm -t 20 'readlink /var/lib/rhizo/prepared/current 2>/dev/null; echo DONE')
  lc_done_strip key || { fail "cli.prepare: incomplete read of prepared/current (no DONE token): $key"; return 1; }
  [[ -n "$key" ]] || { fail "cli.prepare: no /var/lib/rhizo/prepared/current symlink after prepare"; return 1; }
  local exists; exists=$(ssh_vm -t 20 "test -e /var/lib/rhizo/prepared/'$key' && echo PRESENT || echo ABSENT")
  [[ "$exists" == *PRESENT* ]] \
    && pass "cli.prepare: $log_file has RHIZO_PREPARE_OK ($lines lines) and /var/lib/rhizo/prepared/$key exists" \
    || { fail "cli.prepare: /var/lib/rhizo/prepared/$key does not exist (prepared/current -> $key)"; return 1; }
}

# check rhizo upgrade on the enforcing host
lc_assert_cli.upgrade() {
  lc_need_guest cli.upgrade || return 1
  [[ "$LC_UPGRADE_CLI_MARKER" != "plant failed:"* ]] \
    || { fail "cli.upgrade: step 3 could not plant a done marker before rhizo upgrade ($LC_UPGRADE_CLI_MARKER)"; return 1; }
  [[ -n "$LC_UPGRADE_CLI_RC" ]] \
    || { fail "cli.upgrade: step 3 recorded no rhizo upgrade run"; return 1; }
  local out="$LC_UPGRADE_CLI_OUT"
  [[ "$LC_UPGRADE_CLI_RC" == 0 ]] \
    || { fail "cli.upgrade: rhizo upgrade on an enforcing host exited $LC_UPGRADE_CLI_RC, want 0: $out"; return 1; }
  grep -qxF '[rhizo] reboot to finish the upgrade' <<<"$out" \
    || { fail "cli.upgrade: rhizo upgrade on an enforcing host never printed '[rhizo] reboot to finish the upgrade': $out"; return 1; }
  grep -qxF 'RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=enforcing' <<<"$out" \
    || { fail "cli.upgrade: no 'RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=enforcing' line: $out"; return 1; }
  if grep -q 'RHIZO_PREPARE_' <<<"$out"; then
    fail "cli.upgrade: rhizo upgrade ran prepare on an enforcing host: $(grep 'RHIZO_PREPARE_' <<<"$out" | head -1)"
    return 1
  fi
  [[ "$LC_UPGRADE_CLI_MARKER" == absent ]] \
    || { fail "cli.upgrade: the done marker step 3 planted reads '$LC_UPGRADE_CLI_MARKER' after the deferral, want absent"; return 1; }
  [[ "$LC_UPGRADE_CLI_SETUP" == pending-reboot ]] \
    && pass "cli.upgrade: on an enforcing host rhizo upgrade exited 0, printed 'reboot to finish the upgrade', ran no prepare, and status reports setup=pending-reboot" \
    || { fail "cli.upgrade: rhizo status --json reports setup='$LC_UPGRADE_CLI_SETUP' after the deferral, want pending-reboot"; return 1; }
}

# check rhizo gsi ran the a15 to a16 trial
lc_assert_cli.gsi() {
  lc_need_guest cli.gsi || return 1
  _lc_step_passed 6.gsi-update-leg \
    || { fail "cli.gsi: step 6's 6.gsi-update-leg did not pass"; return 1; }
  [[ "$LC_GSI_ARM_STATUS" == "RHIZO_GSI_UPDATE current=a15 candidate=a16 tries=3 previous=-" ]] \
    || { fail "cli.gsi: rhizo gsi's own arm line was '${LC_GSI_ARM_STATUS:-<not recorded -- step 6 did not run>}', want current=a15 candidate=a16 tries=3 previous=-"; return 1; }
  [[ "$LC_GSI_CONFIRM_STATUS" == "RHIZO_GSI_UPDATE current=a16 candidate=- tries=- previous=a15" ]] \
    && pass "cli.gsi: rhizo gsi armed and confirmed the a15->a16 trial exactly (arm: $LC_GSI_ARM_STATUS; confirm: $LC_GSI_CONFIRM_STATUS)" \
    || { fail "cli.gsi: rhizo gsi's own confirm line was '${LC_GSI_CONFIRM_STATUS:-<not recorded>}', want current=a16 candidate=- tries=- previous=a15"; return 1; }
}

# check step 9b's rhizo uninstall --purge log
lc_assert_cli.uninstall() {
  lc_need_guest cli.uninstall || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "cli.uninstall: no cycle profile argument"; return 1; }
  local log_file="$EV/$p1-cli-purge.log"
  if [[ ! -s "$log_file" ]]; then
    fail "cli.uninstall: no $log_file evidence from step 9b's rhizo uninstall --purge"
    return 1
  fi
  local content; content=$(cat "$log_file")
  if [[ "$content" == *RHIZO_TEARDOWN_ALREADY_CLEAN=1* ]]; then
    fail "cli.uninstall: rhizo uninstall --purge reported ALREADY_CLEAN: $content"
    return 1
  fi
  [[ "$content" == *RHIZO_TEARDOWN_REBOOT_REQUIRED=1* || "$content" == *"RHIZO_TEARDOWN_OK removed=1"* ]] \
    || { fail "cli.uninstall: no RHIZO_TEARDOWN_REBOOT_REQUIRED=1/RHIZO_TEARDOWN_OK sentinel in $log_file: $content"; return 1; }
  local load; load=$(ssh_vm -t 20 'systemctl show -p LoadState --value androidd.service 2>/dev/null; echo DONE')
  lc_done_strip load || { fail "cli.uninstall: incomplete read of androidd.service's LoadState (no DONE token): $load"; return 1; }
  [[ "$load" == not-found ]] \
    && pass "cli.uninstall: rhizo uninstall --purge printed a real removal sentinel and androidd.service is LoadState=not-found" \
    || { fail "cli.uninstall: androidd.service LoadState is '$load' after rhizo uninstall --purge, want not-found"; return 1; }
}

# check rhizo status --json output
lc_assert_cli.status() {
  lc_need_guest cli.status || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "cli.status: no cycle profile argument"; return 1; }
  local out; out=$(lc_rhizo status --json 2>&1)
  local prof; [[ "$p1" == server ]] && prof=server || prof=desktop
  local bad
  bad=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError as exc:
    print("not JSON: %s" % exc); raise SystemExit
want_profile = sys.argv[2]
bad = []
if d.get("profile") != want_profile:
    bad.append("profile=%r (want %r)" % (d.get("profile"), want_profile))
if d.get("boot_completed") != "1":
    bad.append("boot_completed=%r" % d.get("boot_completed"))
if not d.get("adb"):
    bad.append("adb=%r" % d.get("adb"))
if d.get("unit") != "active":
    bad.append("unit=%r" % d.get("unit"))
print("; ".join(bad))' "$out" "$prof" 2>&1)
  [[ -z "$bad" ]] \
    && pass "cli.status: rhizo status --json reports profile=$prof, boot_completed=1, unit=active and a live adb endpoint" \
    || { fail "cli.status: rhizo status --json reports $bad (raw: $out)"; return 1; }
}

# check rhizo --version matches the package version
lc_assert_cli.version() {
  lc_need_guest cli.version || return 1
  local cli file dpkg
  cli=$(lc_rhizo --version 2>&1)
  file=$(ssh_vm -t 20 'cat /usr/lib/rhizo/VERSION 2>/dev/null')
  if lc_on_cachyos; then
    dpkg=$(ssh_vm -t 20 'pacman -Q rhizo 2>/dev/null' | awk '{ sub(/-[0-9]+$/, "", $2); print $2 }')
  else
    dpkg=$(ssh_vm -t 20 "dpkg-query -W -f='\${Version}' rhizo 2>/dev/null")
  fi
  if [[ -z "$file" ]]; then
    fail "cli.version: /usr/lib/rhizo/VERSION is empty or missing"
    return 1
  fi
  if [[ "$cli" != "$file" ]]; then
    fail "cli.version: rhizo --version printed '$cli', /usr/lib/rhizo/VERSION says '$file'"
    return 1
  fi
  if [[ "$dpkg" != "$file" ]]; then
    fail "cli.version: dpkg-query reports rhizo at '$dpkg', /usr/lib/rhizo/VERSION says '$file'"
    return 1
  fi
  pass "cli.version: rhizo --version, /usr/lib/rhizo/VERSION and dpkg agree at $file"
}

# check rhizo doctor reports no failed check
lc_assert_cli.doctor() {
  lc_need_guest cli.doctor || return 1
  local out rc; out=$(lc_rhizo doctor 2>&1); rc=$?
  printf 'rc=%s\n%s\n' "$rc" "$out" > "$EV/cli-doctor.txt"
  local sentinel; sentinel=$(grep -m1 -E '^RHIZO_DOCTOR_(OK|ISSUES) ' <<<"$out")
  [[ -n "$sentinel" ]] || { fail "cli.doctor: no RHIZO_DOCTOR_OK/RHIZO_DOCTOR_ISSUES sentinel in rhizo doctor's output (rc=$rc, whole report in $EV/cli-doctor.txt): $out"; return 1; }
  local issues; issues=$(grep -E ': fail -- ' <<<"$out" | sed 's/^\[rhizo\] *//' | paste -sd '|' | sed 's/|/ | /g')
  local rc_fail="cli.doctor: rhizo doctor printed '$sentinel'${issues:+ ($issues)} but exited $rc, want 0 (whole report in $EV/cli-doctor.txt)"
  local prof; prof=$(lc_rhizo profile 2>&1 | sed -n 's/^RHIZO_PROFILE profile=//p')
  if [[ "$prof" == server ]]; then
    if ! declare -F assert_doctor_server >/dev/null 2>&1; then
      fail "cli.doctor: server profile but assert_doctor_server (server-assert-lib.sh) is not sourced"
      return 1
    fi
    (( rc == 0 )) || { fail "$rc_fail"; return 1; }
    assert_doctor_server cli.doctor "$out"
    return $?
  fi
  [[ "$sentinel" == RHIZO_DOCTOR_OK* ]] \
    || { fail "cli.doctor: $sentinel: $issues (whole report in $EV/cli-doctor.txt)"; return 1; }
  (( rc == 0 )) || { fail "$rc_fail"; return 1; }
  pass "cli.doctor: $sentinel, rhizo doctor exited 0"
}

# check rhizo profile prints this cycle's exact profile line
lc_assert_cli.profile() {
  lc_need_guest cli.profile || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "cli.profile: no cycle profile argument"; return 1; }
  local out; out=$(lc_rhizo profile 2>&1)
  local line; line=$(grep -m1 '^RHIZO_PROFILE ' <<<"$out")
  local want; [[ "$p1" == server ]] && want=server || want=desktop
  [[ "$line" == "RHIZO_PROFILE profile=$want" ]] \
    && pass "cli.profile: $line" \
    || { fail "cli.profile: no exact RHIZO_PROFILE profile=$want line: $out"; return 1; }
}

# check rhizo reset clears Android's /data
lc_assert_cli.reset() {
  lc_need_guest cli.reset || return 1
  local init; init=$(lc_resolve_init 60)
  [[ -n "$init" ]] || { fail "cli.reset: no sandbox init to plant a nonce in before reset"; return 1; }
  local nonce="rhizo-lifecycle-reset-nonce-$$-$RANDOM"
  local planted; planted=$(android_sh "$init" "printf '%s' '$nonce' > /data/local/tmp/$nonce; test -f /data/local/tmp/$nonce && echo PRESENT || echo ABSENT; echo DONE")
  lc_done_strip planted || { fail "cli.reset: incomplete read planting the nonce (no DONE token): $planted"; return 1; }
  [[ "$planted" == *PRESENT* ]] || { fail "cli.reset: could not plant $nonce in /data/local/tmp before reset: $planted"; return 1; }

  local t0; t0=$(guest_uptime)
  local out rc; out=$(lc_rhizo 120 reset 2>&1); rc=$?
  (( rc == 0 )) || { fail "cli.reset: rhizo reset exited $rc: $out"; return 1; }

  wait_sandbox_started 420 "$t0" || { fail "cli.reset: the sandbox never reached boot_completed after reset"; return 1; }
  INIT=$(resolve_init_pid 60)
  if [[ -z "$INIT" ]]; then
    fail "cli.reset: reset completed but no init pid resolved afterward"
    return 1
  fi

  local after; after=$(android_sh "$INIT" "test -f /data/local/tmp/$nonce && echo PRESENT || echo ABSENT; echo DONE")
  lc_done_strip after || { fail "cli.reset: incomplete read of the nonce after reset (no DONE token): $after"; return 1; }
  if [[ "$after" != *ABSENT* ]]; then
    fail "cli.reset: $nonce is still present in /data/local/tmp after rhizo reset: $after"
    return 1
  fi
  pass "cli.reset: a nonce planted in /data/local/tmp before reset is gone after it, and the sandbox reached boot_completed again"

  [[ -n "$APP_PKG" && -n "${1:-}" ]] && lc_setup_fixtures "$1"
  return 0
}

# check rhizo shell answers the sandbox's ro.build.id
lc_assert_cli.shell() {
  lc_need_guest cli.shell || return 1
  local out; out=$(lc_rhizo shell -- getprop ro.build.id 2>&1)
  local trimmed; trimmed=$(tr -d '[:space:]' <<<"$out")
  [[ "$trimmed" == BP4A.251205.006 ]] \
    && pass "cli.shell: getprop ro.build.id inside the sandbox read BP4A.251205.006" \
    || { fail "cli.shell: expected the sandbox's own ro.build.id (BP4A.251205.006), got: $out"; return 1; }
}

# print androidd.service's init pid
_lc_unit_init_pid() {
  local deadline=$((SECONDS + $1)) out pid=""
  while (( SECONDS < deadline )); do
    out=$(ssh_vm -t 20 'p=$(cat /root/.rhizo_init_pid 2>/dev/null)
case "$p" in
  ""|*[!0-9]*) ;;
  *) case "$(tr "\0" " " 2>/dev/null </proc/$p/cmdline)" in *"init second_stage"*)
       case "$(sed -n "s|^0::||p" /proc/$p/cgroup 2>/dev/null)" in /rhizo/*|/system.slice/androidd.service/android/*) echo "$p" ;; esac ;; esac ;;
esac
echo DONE')
    lc_done_strip out && pid=$(tr -d '[:space:]' <<<"$out")
    [[ -n "$pid" ]] && break
    sleep 5
  done
  printf '%s' "$pid"
}

# check rhizo start restarts androidd
lc_assert_cli.start() {
  lc_need_guest cli.start || return 1
  INIT=""
  ssh_vm -t 90 'systemctl stop androidd.service' >/dev/null 2>&1
  local before; before=$(ssh_vm -t 20 'systemctl is-active androidd.service 2>/dev/null; echo DONE')
  lc_done_strip before || { fail "cli.start: incomplete read of androidd.service's state before starting (no DONE token): $before"; return 1; }
  if [[ "$before" == active ]]; then
    fail "cli.start: androidd.service is still active after being stopped"
    return 1
  fi

  local t0; t0=$(guest_uptime)
  local out rc; out=$(lc_rhizo 600 start 2>&1); rc=$?
  if (( rc != 0 )); then
    fail "cli.start: rhizo start exited $rc: $out"
    return 1
  fi
  lc_unit_active androidd.service || { fail "cli.start: androidd.service is not active after rhizo start exited 0"; return 1; }
  wait_sandbox_started 420 "$t0" \
    || { fail "cli.start: androidd.service is active but the sandbox never reached boot_completed after rhizo start"; return 1; }
  INIT=$(_lc_unit_init_pid 60)
  [[ -n "$INIT" ]] || { fail "cli.start: the sandbox reached boot_completed but /root/.rhizo_init_pid named no live init second_stage afterward"; return 1; }
  pass "cli.start: rhizo start exited 0, androidd.service is active and the sandbox reached boot_completed (init $INIT), from a confirmed-inactive start"
}

# check rhizo stop leaves androidd.service inactive
lc_assert_cli.stop() {
  lc_need_guest cli.stop || return 1
  local out rc; out=$(lc_rhizo 120 stop 2>&1); rc=$?
  INIT=""
  (( rc == 0 )) || { fail "cli.stop: rhizo stop exited $rc: $out"; return 1; }
  local after; after=$(ssh_vm -t 20 'systemctl is-active androidd.service 2>/dev/null; echo DONE')
  lc_done_strip after || { fail "cli.stop: incomplete read of androidd.service's state after rhizo stop (no DONE token): $after"; return 1; }
  [[ "$after" == inactive ]] || { fail "cli.stop: androidd.service is '$after' after rhizo stop exited 0, not inactive"; return 1; }
  local t0; t0=$(guest_uptime)
  out=$(lc_rhizo 600 start 2>&1); rc=$?
  (( rc == 0 )) || { fail "cli.stop: androidd.service stopped, but rhizo start after it exited $rc: $out"; return 1; }
  wait_sandbox_started 420 "$t0" || { fail "cli.stop: the sandbox never reached boot_completed again after rhizo stop"; return 1; }
  INIT=$(_lc_unit_init_pid 60)
  [[ -n "$INIT" ]] || { fail "cli.stop: the sandbox started again but /root/.rhizo_init_pid named no live init second_stage"; return 1; }
  pass "cli.stop: rhizo stop exited 0 and androidd.service read inactive; the sandbox started again (init $INIT)"
}

# print the resumed activity lines of an activities dump
_lc_resumed_lines() { grep -E '(^|[[:space:]])(top)?ResumedActivity[:=]' <<<"$1"; }
# print the first resumed line naming a package's activity
_lc_resumed_naming() { _lc_resumed_lines "$1" | grep -F -m1 " $2/"; }

# check rhizo launch resumes an app
lc_assert_cli.launch() {
  lc_need_guest cli.launch || return 1
  local init pkgact; init=$(lc_resolve_init 60)
  [[ -n "$init" ]] || { fail "cli.launch: no sandbox init to resolve an activity from"; return 1; }
  pkgact=$(lc_resolve_activity "$init")
  [[ "$pkgact" == */* ]] || { fail "cli.launch: no launchable activity resolved"; return 1; }
  local pkg="${pkgact%%/*}" fs fs_rc
  fs=$(android_sh "$init" "am force-stop $pkg 2>&1; echo FORCE_STOP_RC=\$?"); fs_rc=$?
  grep -qx 'FORCE_STOP_RC=0' <<<"$fs" \
    || { fail "cli.launch: am force-stop $pkg did not exit 0 (android_sh rc=$fs_rc): ${fs:-<empty>}"; return 1; }
  local dump="" still="" stopped="" deadline; deadline=$(( $(date +%s) + 15 ))
  while (( $(date +%s) < deadline )); do
    dump=$(android_sh "$init" "dumpsys activity activities; echo DONE")
    if lc_done_strip dump && grep -q '^ACTIVITY MANAGER ACTIVITIES' <<<"$dump"; then
      still=$(_lc_resumed_naming "$dump" "$pkg")
      [[ -z "$still" ]] && { stopped=1; break; }
    else
      still=""
    fi
    sleep 2
  done
  if [[ -z "$stopped" ]]; then
    [[ -n "$still" ]] \
      && fail "cli.launch: $pkg is still the resumed activity after am force-stop ($still)" \
      || fail "cli.launch: no whole 'dumpsys activity activities' read after am force-stop $pkg (last: '$(head -c 200 <<<"${dump:-<empty>}")')"
    return 1
  fi
  local out rc; out=$(lc_rhizo launch "$pkg" 2>&1); rc=$?
  if (( rc != 0 )); then
    fail "cli.launch: rhizo launch $pkg exited $rc: $out"
    return 1
  fi
  local resumed=""; deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    dump=$(android_sh "$init" "dumpsys activity activities" 2>/dev/null)
    resumed=$(_lc_resumed_naming "$dump" "$pkg")
    [[ -n "$resumed" ]] && break
    sleep 2
  done
  [[ -n "$resumed" ]] \
    && pass "cli.launch: $pkgact is the resumed activity after rhizo launch ($resumed)" \
    || { fail "cli.launch: rhizo launch exited 0 but $pkg never became the resumed activity (last read's resumed lines: '$(_lc_resumed_lines "$dump" | sed 's/^ *//' | paste -sd '|')')"; return 1; }
}

# check rhizo app list prints its sentinel and lists com.android.settings
lc_assert_cli.app() {
  lc_need_guest cli.app || return 1
  local out; out=$(lc_rhizo app list 2>&1)
  local sentinel; sentinel=$(grep -m1 '^RHIZO_APP list=' <<<"$out")
  [[ -n "$sentinel" ]] || { fail "cli.app: no RHIZO_APP list= sentinel in rhizo app list's output: $out"; return 1; }
  grep -qE $'^com\\.android\\.settings\t' <<<"$out" \
    && pass "cli.app: rhizo app list includes com.android.settings ($sentinel)" \
    || { fail "cli.app: com.android.settings is missing from rhizo app list: $out"; return 1; }
}

# check rhizo device set battery 42 discharging reaches BatteryService
lc_assert_cli.device() {
  lc_need_guest cli.device || return 1
  local init; init=$(lc_resolve_init 60)
  [[ -n "$init" ]] || { fail "cli.device: no sandbox init to read battery state from"; return 1; }
  local out rc; out=$(lc_rhizo device set battery 42 discharging 2>&1); rc=$?
  if (( rc != 0 )); then
    fail "cli.device: rhizo device set battery 42 discharging exited $rc: $out"
    return 1
  fi
  local batt="" level="" status="" deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    batt=$(android_sh "$init" "dumpsys battery" 2>/dev/null)
    level=$(grep -m1 -E '^ *level:' <<<"$batt" | tr -dc '0-9')
    status=$(grep -m1 -E '^ *status:' <<<"$batt" | tr -dc '0-9')
    [[ "$level" == 42 && "$status" == 3 ]] && break
    sleep 2
  done
  [[ "$level" == 42 && "$status" == 3 ]] \
    && pass "cli.device: dumpsys battery reads level: 42 and status: 3 (discharging) after rhizo device set battery 42 discharging" \
    || { fail "cli.device: dumpsys battery reads level='${level:-<empty>}' status='${status:-<empty>}' 30s after rhizo device set battery 42 discharging, wanted 42 and 3 (discharging)"; return 1; }
}

# check rhizo adb-key add and list
lc_assert_cli.adb-key() {
  lc_need_guest cli.adb-key || return 1
  local add list
  local adb="${RHIZO_ADB:-$HOME/Android/Sdk/platform-tools/adb}" key_dir="$EV/cli-adbkey"
  mkdir -p "$key_dir" && rm -f "$key_dir/adbkey" "$key_dir/adbkey.pub"
  if ! "$adb" keygen "$key_dir/adbkey" >"$key_dir/keygen.log" 2>&1 || [[ ! -s "$key_dir/adbkey.pub" ]]; then
    fail "cli.adb-key: $adb keygen did not produce $key_dir/adbkey.pub: $(tail -2 "$key_dir/keygen.log" 2>/dev/null | tr '\n' ' ')"
    return 1
  fi
  add=$(ssh_vm -t 30 "/usr/bin/rhizo adb-key add -" < "$key_dir/adbkey.pub" 2>&1)
  list=$(lc_rhizo adb-key list 2>&1)
  if ! declare -F assert_adbkey_registered >/dev/null 2>&1; then
    fail "cli.adb-key: assert_adbkey_registered (server-assert-lib.sh) is not sourced"
    return 1
  fi
  assert_adbkey_registered cli.adb-key "$add" "$list" || return 1
  local fpr; fpr=$(sed -n 's/^.*registered \([0-9A-F:]\+\).*/\1/p' <<<"$add" | tail -1)
  if [[ -z "$fpr" ]]; then
    fail "cli.adb-key: could not read the added key's own fingerprint from rhizo adb-key add's output: $add"
    return 1
  fi
  grep -qF "$fpr" <<<"$list" \
    && pass "cli.adb-key: the key just added ($fpr) is present in rhizo adb-key list" \
    || { fail "cli.adb-key: fingerprint $fpr is missing from rhizo adb-key list: $list"; return 1; }
}

# check rhizo snapshot of an instance
lc_assert_cli.snapshot() {
  lc_need_guest cli.snapshot || return 1
  if [[ -z "${LC_INSTANCE_ADD_ID:-}" ]]; then
    fail "cli.snapshot: no instance from server.instance-add this cycle to snapshot"
    return 1
  fi
  local id="$LC_INSTANCE_ADD_ID" unit img
  unit="androidd@$id.service"
  img="/var/lib/rhizo/instances/$id/data.img"

  ssh_vm -t 600 "systemctl start $unit" >/dev/null 2>&1
  local deadline=$(( $(date +%s) + 180 )) has_img=""
  while (( $(date +%s) < deadline )); do
    has_img=$(ssh_vm -t 15 "test -s '$img' && echo PRESENT || echo ABSENT")
    [[ "$has_img" == PRESENT ]] && break
    sleep 5
  done
  if [[ "$has_img" != PRESENT ]]; then
    fail "cli.snapshot: instance $id never produced a non-empty $img after starting $unit"
    ssh_vm -t 60 "systemctl stop $unit" >/dev/null 2>&1
    return 1
  fi

  local state_before; state_before=$(ssh_vm -t 20 "systemctl is-active $unit 2>/dev/null; echo DONE")
  lc_done_strip state_before || { fail "cli.snapshot: incomplete read of $unit's state before snapshotting (no DONE token): $state_before"; return 1; }

  local out rc
  out=$(lc_rhizo 120 snapshot -i "$id" cli-snapshot-real 2>&1); rc=$?
  local key; key=$(sed -n 's/^RHIZO_SNAPSHOT name=cli-snapshot-real key=\([^ ]*\).*/\1/p' <<<"$out" | tail -1)
  if (( rc != 0 )) || [[ -z "$key" ]]; then
    fail "cli.snapshot: rhizo snapshot -i $id cli-snapshot-real exited $rc with no RHIZO_SNAPSHOT key= line: $out"
    return 1
  fi

  local listed; listed=$(ssh_vm -t 20 "ls /var/lib/rhizo/templates/data-template.cli-snapshot-real.$key.img 2>/dev/null; echo DONE")
  lc_done_strip listed || { fail "cli.snapshot: incomplete read of the template listing (no DONE token): $listed"; return 1; }
  if [[ -z "$listed" ]]; then
    fail "cli.snapshot: no template file matching data-template.cli-snapshot-real.$key.img on disk (key='$key')"
    return 1
  fi

  local state_after; state_after=$(ssh_vm -t 20 "systemctl is-active $unit 2>/dev/null; echo DONE")
  lc_done_strip state_after || { fail "cli.snapshot: incomplete read of $unit's state after snapshotting (no DONE token): $state_after"; return 1; }
  ssh_vm -t 120 "systemctl stop $unit; rm -f $listed $listed.meta" >/dev/null 2>&1

  [[ -n "$state_before" && "$state_after" == "$state_before" ]] \
    && pass "cli.snapshot: instance $id snapshotted to a non-empty key=$key template ($listed), and $unit is back to its prior state ($state_after)" \
    || { fail "cli.snapshot: $unit was '$state_before' going into the snapshot call, '$state_after' after it"; return 1; }
}

# check rhizo instance add and remove
lc_assert_cli.instance() {
  lc_need_guest cli.instance || return 1
  local id=91 env_file="/etc/rhizo/instances/91.env"
  ssh_vm -t 60 "test -f $env_file && /usr/bin/rhizo instance remove $id >/dev/null 2>&1; true" >/dev/null 2>&1

  local add_out; add_out=$(lc_rhizo 60 instance add "$id" 2>&1)
  if [[ "$add_out" != "RHIZO_INSTANCE_ADDED id=$id "* ]]; then
    fail "cli.instance: rhizo instance add $id did not print RHIZO_INSTANCE_ADDED id=$id: $add_out"
    return 1
  fi
  local env; env=$(ssh_vm -t 20 "cat $env_file 2>/dev/null; echo DONE")
  lc_done_strip env || { fail "cli.instance: incomplete read of instance $id's env file (no DONE token): $env"; return 1; }
  if [[ "$env" != *"RHIZO_SANDBOX_ID=$id"* ]]; then
    fail "cli.instance: instance $id's env file after add is '$env', want RHIZO_SANDBOX_ID=$id"
    ssh_vm -t 60 "/usr/bin/rhizo instance remove $id" >/dev/null 2>&1
    return 1
  fi

  local rm_out rc; rm_out=$(lc_rhizo 60 instance remove "$id" 2>&1); rc=$?
  if [[ "$rc" != 0 || "$rm_out" != *"RHIZO_INSTANCE_REMOVED id=$id "* ]]; then
    fail "cli.instance: rhizo instance remove $id exited $rc with no matching RHIZO_INSTANCE_REMOVED line: $rm_out"
    return 1
  fi
  local gone; gone=$(ssh_vm -t 20 "test -f $env_file && echo PRESENT || echo ABSENT; echo DONE")
  lc_done_strip gone || { fail "cli.instance: incomplete read confirming instance $id is gone (no DONE token): $gone"; return 1; }
  [[ "$gone" == *ABSENT* ]] \
    && pass "cli.instance: instance add $id configured RHIZO_SANDBOX_ID=$id, then instance remove $id exited 0 and $env_file is gone" \
    || { fail "cli.instance: $env_file is still present after instance remove $id ($gone)"; return 1; }
}

# check rhizo pool set reads back in pool status
lc_assert_cli.pool() {
  lc_need_guest cli.pool || return 1
  local out rc; out=$(lc_rhizo "$LC_POOL_BOOT_T" pool set 1 2>&1); rc=$?
  if (( rc != 0 )); then
    fail "cli.pool: rhizo pool set 1 exited $rc: $out"
    return 1
  fi
  local members=""
  if declare -F lc_wait_pool_members >/dev/null 2>&1; then
    members=$(lc_wait_pool_members 1)
  fi
  local status; status=$(lc_rhizo 30 pool status 2>&1)
  lc_rhizo 60 pool set 0 >/dev/null 2>&1
  local line; line=$(grep -m1 '^RHIZO_POOL ' <<<"$status")
  if [[ "$line" != "RHIZO_POOL k=1 members=1 pending=0" ]]; then
    fail "cli.pool: rhizo pool status after 'pool set 1' (members reached '${members:-<not waited>}') read '$line', want RHIZO_POOL k=1 members=1 pending=0"
    return 1
  fi
  pass "cli.pool: rhizo pool set 1 is read back by rhizo pool status as $line"
}

# check selinux is in the installed host's lsm list
lc_assert_install.security-module-change() {
  lc_need_guest install.security-module-change || return 1
  local lsm; lsm=$(ssh_vm -t 20 'cat /sys/kernel/security/lsm 2>/dev/null')
  [[ ",$lsm," == *,selinux,* ]] \
    && pass "install.security-module-change: selinux is active on the installed host (lsm=$lsm)" \
    || { fail "install.security-module-change: selinux is not in lsm=$lsm after install"; return 1; }
}

# check the booted cmdline turns on selinux
lc_assert_install.requirements() {
  lc_need_guest install.requirements || return 1
  lc_claim_host_mode install.requirements "selinux token on the booted cmdline" || return 1
  local cmdline; cmdline=$(ssh_vm -t 20 'cat /proc/cmdline')
  if lc_on_cachyos; then
    [[ " $cmdline " =~ \ lsm=[^\ ]*selinux ]] \
      && pass "install.requirements: host mode: the booted kernel's lsm= list names selinux" \
      || { fail "install.requirements: host mode: no lsm= list with selinux on the booted cmdline: $cmdline"; return 1; }
    return 0
  fi
  [[ "$cmdline" == *security=selinux* ]] \
    && pass "install.requirements: host mode: the booted kernel carries security=selinux" \
    || { fail "install.requirements: host mode: no security=selinux on the booted cmdline: $cmdline"; return 1; }
}

# check journalctl counted exactly one boot across step 1's install
lc_assert_install.one-reboot() {
  lc_need_guest install.one-reboot || return 1
  if [[ ! "$LC_INSTALL_BOOTS_BEFORE" =~ ^[0-9]+$ || ! "$LC_INSTALL_BOOTS_AFTER" =~ ^[0-9]+$ ]]; then
    fail "install.one-reboot: no journalctl boot count recorded around step 1's install (before='${LC_INSTALL_BOOTS_BEFORE:-}' after='${LC_INSTALL_BOOTS_AFTER:-}')"
    return 1
  fi
  local delta=$(( LC_INSTALL_BOOTS_AFTER - LC_INSTALL_BOOTS_BEFORE ))
  [[ "$delta" == 1 ]] \
    && pass "install.one-reboot: journalctl --list-boots grew by exactly 1 across install+reboot+prepare ($LC_INSTALL_BOOTS_BEFORE -> $LC_INSTALL_BOOTS_AFTER)" \
    || { fail "install.one-reboot: journalctl --list-boots grew by $delta across the install ($LC_INSTALL_BOOTS_BEFORE -> $LC_INSTALL_BOOTS_AFTER), want exactly 1"; return 1; }
}

# check step 1's prepare-ok step passed
lc_assert_install.install-flow() {
  lc_need_guest install.install-flow || return 1
  _lc_step_passed 1.prepare-ok \
    && pass "install.install-flow: step 1's own install (units load, kernel check, RHIZO_PREPARE_OK) recorded no failure" \
    || { fail "install.install-flow: step 1's own src/install/prepare check (step.1.prepare-ok) did not pass"; return 1; }
}

# check /var/lib/rhizo, /usr/lib/rhizo and /etc/rhizo exist
lc_assert_install.where-things-live() {
  lc_need_guest install.where-things-live || return 1
  local d dirs=(/var/lib/rhizo /usr/lib/rhizo /etc/rhizo) cmd=""
  for d in "${dirs[@]}"; do cmd+="[ -d '$d' ] && echo OK:$d; "; done
  local out; out=$(ssh_vm -t 20 "$cmd echo DONE")
  lc_done_strip out || { fail "install.where-things-live: incomplete read (no DONE token): $out"; return 1; }
  local missing=()
  for d in "${dirs[@]}"; do grep -qx "OK:$d" <<<"$out" || missing+=("$d"); done
  if (( ${#missing[@]} == 0 )); then
    pass "install.where-things-live: all 3 documented directories exist ($out)"
  else
    fail "install.where-things-live: missing: ${missing[*]} (full read: $out)"
    return 1
  fi
}

# check a file the user writes to Downloads appears with the same sha in Android
lc_assert_install.hostfs-share() {
  lc_need_guest install.hostfs-share || return 1
  lc_unit_loaded rhizo-hostfs.service || { fail "install.hostfs-share: rhizo-hostfs.service does not load"; return 1; }
  [[ -n "$INIT" && -n "$DOWNLOADS" ]] || { fail "install.hostfs-share: no live sandbox init/Downloads dir from step 2 to prove the share through"; return 1; }
  local nonce sha out androidsha deadline
  nonce="rhizo-lifecycle-hostfs-$$-$RANDOM.txt"
  out=$(desk_user_sh 20 "printf 'rhizo-hostfs-%s' '$nonce' > '$DOWNLOADS/$nonce' && sha256sum '$DOWNLOADS/$nonce' | cut -d' ' -f1; echo DONE")
  lc_done_strip out || { fail "install.hostfs-share: incomplete read writing the host nonce file (no DONE token): $out"; return 1; }
  sha="$out"
  [[ -n "$sha" ]] || { fail "install.hostfs-share: could not write/sha the host nonce file at $DOWNLOADS/$nonce"; return 1; }
  local raw complete=0
  deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    raw=$(android_sh "$INIT" "sha256sum /storage/emulated/0/Download/$nonce 2>/dev/null | cut -d' ' -f1; echo DONE")
    androidsha="$raw"
    if lc_done_strip androidsha; then
      complete=1
      [[ -n "$androidsha" ]] && break
    else
      complete=0
    fi
    sleep 2
  done
  (( complete )) || { fail "install.hostfs-share: incomplete read from Android (no DONE token): $raw"; return 1; }
  [[ -n "$androidsha" ]] \
    || { fail "install.hostfs-share: /storage/emulated/0/Download/$nonce never appeared inside Android within 30s of writing $DOWNLOADS/$nonce on the host"; return 1; }
  [[ "$androidsha" == "$sha" ]] \
    && pass "install.hostfs-share: /storage/emulated/0/Download/$nonce reads back with the host's own sha256 ($sha)" \
    || { fail "install.hostfs-share: android sha='$androidsha' host sha='$sha' for $nonce"; return 1; }
}

# check step 9b's rhizo uninstall --purge log shows the removal
lc_assert_install.removing() {
  lc_need_guest install.removing || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "install.removing: no cycle profile argument"; return 1; }
  local log_file="$EV/$p1-cli-purge.log"
  if [[ ! -s "$log_file" ]]; then
    fail "install.removing: no $log_file evidence from step 9b's rhizo uninstall --purge"
    return 1
  fi
  local content; content=$(cat "$log_file")
  if [[ "$content" == *RHIZO_TEARDOWN_ALREADY_CLEAN=1* ]]; then
    fail "install.removing: rhizo uninstall --purge reported ALREADY_CLEAN: $content"
    return 1
  fi
  [[ "$content" == *RHIZO_TEARDOWN_REBOOT_REQUIRED=1* || "$content" == *"RHIZO_TEARDOWN_OK removed=1"* ]] \
    || { fail "install.removing: no RHIZO_TEARDOWN_REBOOT_REQUIRED=1/RHIZO_TEARDOWN_OK sentinel in $log_file: $content"; return 1; }
  local load; load=$(ssh_vm -t 20 'systemctl show -p LoadState --value androidd.service 2>/dev/null; echo DONE')
  lc_done_strip load || { fail "install.removing: incomplete read of androidd.service's LoadState (no DONE token): $load"; return 1; }
  [[ "$load" == not-found ]] \
    && pass "install.removing: the removal path leaves a real removal sentinel and androidd.service LoadState=not-found" \
    || { fail "install.removing: androidd.service LoadState is '$load' after removal, want not-found"; return 1; }
}

# check step 1's apt-get install half exited 0
lc_assert_install.cmd-apt-install() {
  lc_need_guest install.cmd-apt-install || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "install.cmd-apt-install: no cycle profile argument"; return 1; }
  local log_file="$EV/cycle-$p1-install.log"
  if [[ ! -s "$log_file" ]]; then
    fail "install.cmd-apt-install: no $log_file evidence from step 1"
    return 1
  fi
  local apt_rc; apt_rc=$(sed -n 's/^APT_RC=//p' "$log_file" | tail -1)
  if [[ "$apt_rc" != 0 ]]; then
    fail "install.cmd-apt-install: step 1's own apt-get install exited APT_RC=${apt_rc:-<none recorded>} in $log_file"
    return 1
  fi
  local out; out=$(ssh_vm -t 20 "dpkg-query -W -f='\${Status}\t\${Version}\n' rhizo 2>&1; echo DONE")
  lc_done_strip out || { fail "install.cmd-apt-install: incomplete read of dpkg status/version (no DONE token): $out"; return 1; }
  local status="${out%%$'\t'*}" version="${out#*$'\t'}"
  [[ "$status" == "install ok installed" ]] \
    || { fail "install.cmd-apt-install: dpkg Status is '$status', want install ok installed"; return 1; }
  if [[ -z "$LC_INSTALL_DEB_VERSION" ]]; then
    fail "install.cmd-apt-install: no N-1 .deb version recorded from step 1 to compare against"
    return 1
  fi
  [[ "$version" == "$LC_INSTALL_DEB_VERSION" ]] \
    && pass "install.cmd-apt-install: apt-get install itself exited 0 (APT_RC=0), dpkg reports Status='install ok installed' Version=$version, matching the installed .deb" \
    || { fail "install.cmd-apt-install: dpkg reports Version=$version, the installed .deb was $LC_INSTALL_DEB_VERSION"; return 1; }
}

# check the boot_id changed across step 1's install
lc_assert_install.cmd-reboot() {
  lc_need_guest install.cmd-reboot || return 1
  if [[ -z "$LC_INSTALL_BID_BEFORE" || -z "$LC_INSTALL_BID_AFTER" ]]; then
    fail "install.cmd-reboot: no boot_id recorded around step 1's install to prove 'sudo reboot' really reboots this host"
    return 1
  fi
  [[ "$LC_INSTALL_BID_BEFORE" != "$LC_INSTALL_BID_AFTER" ]] \
    && pass "install.cmd-reboot: the host really rebooted during step 1's install ($LC_INSTALL_BID_BEFORE -> $LC_INSTALL_BID_AFTER)" \
    || { fail "install.cmd-reboot: boot_id did not change ($LC_INSTALL_BID_BEFORE -> $LC_INSTALL_BID_AFTER)"; return 1; }
}

# check rhizo status --json reports this profile with the documented fields
lc_assert_install.cmd-status() {
  lc_need_guest install.cmd-status || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "install.cmd-status: no cycle profile argument"; return 1; }
  local out; out=$(lc_rhizo status --json 2>&1)
  local prof; [[ "$p1" == server ]] && prof=server || prof=desktop
  local bad
  bad=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError as exc:
    print("not JSON: %s" % exc); raise SystemExit
want_profile = sys.argv[2]
bad = []
if d.get("profile") != want_profile:
    bad.append("profile=%r (want %r)" % (d.get("profile"), want_profile))
if d.get("boot_completed") != "1":
    bad.append("boot_completed=%r" % d.get("boot_completed"))
if not d.get("adb"):
    bad.append("adb=%r" % d.get("adb"))
if d.get("unit") != "active":
    bad.append("unit=%r" % d.get("unit"))
print("; ".join(bad))' "$out" "$prof" 2>&1)
  [[ -z "$bad" ]] \
    && pass "install.cmd-status: rhizo status --json reports profile=$prof, boot_completed=1, unit=active and a live adb endpoint" \
    || { fail "install.cmd-status: rhizo status --json reports $bad (raw: $out)"; return 1; }
}

# check the hostfs round trip and hostfs.conf shape
lc_assert_install.cmd-hostfs-ini() {
  lc_need_guest install.cmd-hostfs-ini || return 1
  if ! _lc_claim_passed install.hostfs-share; then
    fail "install.cmd-hostfs-ini: install.hostfs-share (the real round trip through this same file) did not pass this run"
    return 1
  fi
  local user; user=$(lc_desktop_user)
  local content; content=$(ssh_vm -t 20 'cat /etc/rhizo/hostfs.conf 2>/dev/null; echo DONE')
  lc_done_strip content || { fail "install.cmd-hostfs-ini: incomplete read of hostfs.conf (no DONE token): $content"; return 1; }
  [[ "$content" == *"[Download]"* && "$content" == *"dir = /home/$user/Downloads"* ]] \
    && pass "install.cmd-hostfs-ini: install.hostfs-share's real round trip passed, and /etc/rhizo/hostfs.conf carries [Download]/dir = /home/$user/Downloads" \
    || { fail "install.cmd-hostfs-ini: /etc/rhizo/hostfs.conf does not carry the documented [Download]/dir= shape: $content"; return 1; }
}

# check hostfs.py default-config names the user's Downloads
lc_assert_install.cmd-hostfs-default-config() {
  lc_need_guest install.cmd-hostfs-default-config || return 1
  local user; user=$(lc_desktop_user)
  local out; out=$(ssh_vm -t 30 "p=/usr/lib/rhizo/tools/hostfs.py; [ -x \"\$p\" ] || p=\$(command -v hostfs.py 2>/dev/null); [ -n \"\$p\" ] && \"\$p\" default-config --as-user '$user' 2>&1; echo DONE")
  lc_done_strip out || { fail "install.cmd-hostfs-default-config: incomplete read (no DONE token): $out"; return 1; }
  [[ "$out" == *"[Download]"* && "$out" == *"dir = /home/$user/Downloads"* ]] \
    && pass "install.cmd-hostfs-default-config: hostfs.py default-config --as-user $user names /home/$user/Downloads" \
    || { fail "install.cmd-hostfs-default-config: default-config did not name the user's Downloads: $out"; return 1; }
}

# check step 7's apt-get remove half exited 0
lc_assert_install.cmd-apt-remove() {
  lc_need_guest install.cmd-apt-remove || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "install.cmd-apt-remove: no cycle profile argument"; return 1; }
  local log_file="$EV/$p1-remove.log"
  if [[ ! -s "$log_file" ]]; then
    fail "install.cmd-apt-remove: no $log_file evidence from step 7"
    return 1
  fi
  local apt_rc; apt_rc=$(sed -n 's/^APT_RC=//p' "$log_file" | tail -1)
  if [[ "$apt_rc" != 0 ]]; then
    fail "install.cmd-apt-remove: step 7's own apt-get remove exited APT_RC=${apt_rc:-<none recorded>} in $log_file"
    return 1
  fi
  local status; status=$(ssh_vm -t 20 "dpkg-query -W -f='\${Status}\n' rhizo 2>&1; echo DONE")
  lc_done_strip status || { fail "install.cmd-apt-remove: incomplete read of dpkg status (no DONE token): $status"; return 1; }
  [[ "$status" == "deinstall ok config-files" ]] \
    && pass "install.cmd-apt-remove: apt-get remove itself exited 0 (APT_RC=0), dpkg-query reports rhizo Status=deinstall ok config-files" \
    || { fail "install.cmd-apt-remove: dpkg reports rhizo Status='$status' after apt remove, want deinstall ok config-files"; return 1; }
}

# check step 9's apt-get purge half exited 0 and its log
lc_assert_install.cmd-apt-purge() {
  lc_need_guest install.cmd-apt-purge || return 1
  local p1="${1:-}"
  [[ -n "$p1" ]] || { fail "install.cmd-apt-purge: no cycle profile argument"; return 1; }
  local log_file="$EV/$p1-purge.log"
  if [[ ! -s "$log_file" ]]; then
    fail "install.cmd-apt-purge: no $log_file evidence from step 9"
    return 1
  fi
  local apt_rc; apt_rc=$(sed -n 's/^APT_RC=//p' "$log_file" | tail -1)
  if [[ "$apt_rc" != 0 ]]; then
    fail "install.cmd-apt-purge: step 9's own apt-get purge exited APT_RC=${apt_rc:-<none recorded>} in $log_file"
    return 1
  fi
  local ar_log="$EV/$p1-autoremove.log" ar_rc
  [[ -s "$ar_log" ]] || { fail "install.cmd-apt-purge: no $ar_log evidence from step 9"; return 1; }
  ar_rc=$(sed -n 's/^APT_RC=//p' "$ar_log" | tail -1)
  if [[ "$ar_rc" != 0 ]]; then
    fail "install.cmd-apt-purge: step 9's apt-get autoremove --purge exited APT_RC=${ar_rc:-<none recorded>} in $ar_log"
    return 1
  fi
  local out rc; out=$(ssh_vm -t 20 "dpkg-query -W rhizo 2>&1; echo RC=\$?")
  [[ "$out" == *$'\n'RC=* ]] || { fail "install.cmd-apt-purge: incomplete read of dpkg-query (no RC= token): $out"; return 1; }
  rc="${out##*RC=}"
  [[ "$rc" == 1 && "$out" == *"no packages found"* ]] \
    && pass "install.cmd-apt-purge: apt-get purge and autoremove --purge both exited 0 (APT_RC=0), dpkg-query -W rhizo now exits 1 with 'no packages found'" \
    || { fail "install.cmd-apt-purge: dpkg-query -W rhizo exited $rc after purge, want 1 with 'no packages found': $out"; return 1; }
}

# check step 5's Ubuntu update under enforcement
lc_assert_install.apt-helpers-as-root() {
  local id=install.apt-helpers-as-root
  lc_need_guest "$id" || return 1
  lc_claim_host_mode "$id" "enforcing host and its 50rhizo apt link" || return 1
  local out enforce owners
  out=$(ssh_vm -t 30 "echo enforce=\$(cat /sys/fs/selinux/enforce 2>/dev/null); echo link=\$(readlink /etc/apt/apt.conf.d/50rhizo); apt-config dump APT::Sandbox::User; stat -c 'owner=%U:%G %n' /var/lib/apt/lists/partial /var/lib/apt/lists/auxfiles /var/cache/apt/archives/partial 2>&1; echo DONE")
  lc_done_strip out || { fail "$id: incomplete guest read (no DONE token): $out"; return 1; }
  enforce=$(sed -n 's/^enforce=//p' <<<"$out")
  [[ "$enforce" == 1 ]] \
    || { fail "$id: host mode: /sys/fs/selinux/enforce reads '${enforce:-<none>}', want 1"; return 1; }
  [[ "$(sed -n 's/^link=//p' <<<"$out")" == /usr/lib/rhizo/host-mode/etc/apt/apt.conf.d/50rhizo ]] \
    || { fail "$id: host mode: /etc/apt/apt.conf.d/50rhizo is not host mode's link to /usr/lib/rhizo/host-mode/etc/apt/apt.conf.d/50rhizo: $(tr '\n' '|' <<<"$out")"; return 1; }
  grep -qx 'APT::Sandbox::User "root";' <<<"$out" \
    || { fail "$id: apt-config does not read APT::Sandbox::User \"root\": $(tr '\n' '|' <<<"$out")"; return 1; }
  owners=$(grep -c '^owner=root:root /var/' <<<"$out")
  [[ "$owners" == 3 ]] \
    || { fail "$id: $owners of apt's 3 partial dirs are root:root: $(grep '^owner=' <<<"$out" | tr '\n' '|')"; return 1; }
  _lc_step_passed 5.ubuntu-update \
    || { fail "$id: step.5.ubuntu-update did not pass"; return 1; }
  pass "$id: host mode: enforce=1, host mode's 50rhizo link reads APT::Sandbox::User \"root\", apt's 3 partial dirs are root:root, and step 5's update passed through them"
}

# check README.md still states what the install buys
lc_assert_readme.what-that-buys() {
  local bad="" want
  for want in \
    "Rhizo leaves the GSI image and platform SELinux policy unmodified" \
    "its HALs run on the host hardware"
  do
    grep_doc README.md "$want" || bad+="'$want' "
  done
  [[ -z "$bad" ]] \
    && pass "readme.what-that-buys: the unmodified GSI image and platform SELinux policy and HALs on the host's hardware are still in README.md" \
    || { fail "readme.what-that-buys: missing from README.md: $bad"; return 1; }
}

# check README.md still lists the supported hosts
lc_assert_readme.current-state() {
  grep_doc README.md 'Ubuntu 24.04 + GNOME' && grep_doc README.md 'CachyOS + KDE Plasma' \
    && pass "readme.current-state: the supported hosts are still in README.md" \
    || { fail "readme.current-state: the supported hosts are gone from README.md"; return 1; }
}

# check step 7's data.img-unchanged step passed
lc_assert_packaging.remove-keeps-data() {
  lc_need_guest packaging.remove-keeps-data || return 1
  _lc_step_passed 7.data-img-unchanged \
    && pass "packaging.remove-keeps-data: step 7's own before==after sha256 check on data.img passed (a non-empty read both sides, unchanged)" \
    || { fail "packaging.remove-keeps-data: step 7's own data.img-unchanged check (step.7.data-img-unchanged) did not pass"; return 1; }
}

# check step 7's host snapshot diff after remove passed
lc_assert_packaging.remove-reverses-host-state() {
  lc_need_guest packaging.remove-reverses-host-state || return 1
  _lc_step_passed 7.snapshot-diff-remove \
    && pass "packaging.remove-reverses-host-state: step 7's own host-snapshot-diff.py run after remove found only disclosed drift" \
    || { fail "packaging.remove-reverses-host-state: step 7's own check (step.7.snapshot-diff-remove) did not pass -- see \$EV/*-snapshot-diff-remove.txt"; return 1; }
}

# check step 9's data-gone step passed and the package is gone
lc_assert_packaging.purge-deletes-data() {
  lc_need_guest packaging.purge-deletes-data || return 1
  _lc_step_passed 9.data-gone \
    || { fail "packaging.purge-deletes-data: step 9's own data.img-gone check (step.9.data-gone) did not pass"; return 1; }
  local out rc
  if lc_on_cachyos; then
    out=$(ssh_vm -t 20 "pacman -Q rhizo 2>&1; echo RC=\$?")
    [[ "$out" == *$'\n'RC=* ]] || { fail "packaging.purge-deletes-data: incomplete read of pacman -Q (no RC= token): $out"; return 1; }
    rc="${out##*RC=}"
    [[ "$rc" == 1 && "$out" == *"was not found"* ]] \
      && pass "packaging.purge-deletes-data: data.img is gone (step 9) and pacman -Q rhizo exits 1, the package not found, after the purge" \
      || { fail "packaging.purge-deletes-data: pacman -Q rhizo exited $rc after the purge, want 1 with 'was not found': $out"; return 1; }
    return 0
  fi
  out=$(ssh_vm -t 20 "dpkg-query -W rhizo 2>&1; echo RC=\$?")
  [[ "$out" == *$'\n'RC=* ]] || { fail "packaging.purge-deletes-data: incomplete read of dpkg-query (no RC= token): $out"; return 1; }
  rc="${out##*RC=}"
  [[ "$rc" == 1 && "$out" == *"no packages found"* ]] \
    && pass "packaging.purge-deletes-data: data.img is gone (step 9) and dpkg-query -W rhizo exits 1 with 'no packages found' after purge" \
    || { fail "packaging.purge-deletes-data: dpkg-query -W rhizo exited $rc after purge, want 1 with 'no packages found': $out"; return 1; }
}

# check selinux stays until the reboot after remove
lc_assert_packaging.second-reboot-needed() {
  lc_need_guest packaging.second-reboot-needed || return 1
  local bad=""
  [[ ",$LC_LSM_AFTER_REMOVE_PRE_REBOOT," == *,selinux,* ]] \
    || bad+="lsm after remove, before reboot was '${LC_LSM_AFTER_REMOVE_PRE_REBOOT:-<not recorded>}' (want selinux still active); "
  lc_on_cachyos || [[ ",$LC_LSM_AFTER_REMOVE_POST_REBOOT," == *,apparmor,* ]] \
    || bad+="lsm after the post-remove reboot was '${LC_LSM_AFTER_REMOVE_POST_REBOOT:-<not recorded>}' (want apparmor active); "
  [[ ",$LC_LSM_AFTER_REMOVE_POST_REBOOT," != *,selinux,* ]] \
    || bad+="selinux is still active after the post-remove reboot ($LC_LSM_AFTER_REMOVE_POST_REBOOT); "
  [[ -z "$bad" ]] \
    && pass "packaging.second-reboot-needed: selinux stayed active until the reboot ($LC_LSM_AFTER_REMOVE_PRE_REBOOT), the host's own list is back after it ($LC_LSM_AFTER_REMOVE_POST_REBOOT)" \
    || { fail "packaging.second-reboot-needed: $bad"; return 1; }
}

# check the seeded /swapfile survives install and removal
lc_assert_packaging.swapfile-precise-removal() {
  lc_need_guest packaging.swapfile-precise-removal || return 1
  if [[ -z "$LC_SWAPFILE_INODE_SEED" || -z "$LC_SWAPFILE_UUID_SEED" ]]; then
    fail "packaging.swapfile-precise-removal: no seeded /swapfile fixture recorded from step 0"
    return 1
  fi
  if [[ "$LC_SWAPFILE_ACTIVE_BEFORE_INSTALL" != 1 ]]; then
    fail "packaging.swapfile-precise-removal: the step-0 /swapfile was not active before step 1's install (/proc/swaps rows: '${LC_SWAPFILE_ACTIVE_BEFORE_INSTALL:-<not recorded>}', want 1)"
    return 1
  fi
  if [[ "$LC_SWAPFILE_ACTIVE_AFTER_INSTALL" != 1 ]]; then
    fail "packaging.swapfile-precise-removal: the step-0 /swapfile was not active after step 1's reboot (/proc/swaps rows: '${LC_SWAPFILE_ACTIVE_AFTER_INSTALL:-<not recorded>}', want 1)"
    return 1
  fi
  local bad=""
  [[ "$LC_SWAPFILE_INODE_AFTER_REMOVE" == "$LC_SWAPFILE_INODE_SEED" && "$LC_SWAPFILE_UUID_AFTER_REMOVE" == "$LC_SWAPFILE_UUID_SEED" ]] \
    || bad+="after remove: inode='${LC_SWAPFILE_INODE_AFTER_REMOVE:-<not recorded>}' uuid='${LC_SWAPFILE_UUID_AFTER_REMOVE:-<not recorded>}' (want inode=$LC_SWAPFILE_INODE_SEED uuid=$LC_SWAPFILE_UUID_SEED); "
  [[ "$LC_SWAPFILE_INODE_AFTER_PURGE" == "$LC_SWAPFILE_INODE_SEED" && "$LC_SWAPFILE_UUID_AFTER_PURGE" == "$LC_SWAPFILE_UUID_SEED" ]] \
    || bad+="after purge: inode='${LC_SWAPFILE_INODE_AFTER_PURGE:-<not recorded>}' uuid='${LC_SWAPFILE_UUID_AFTER_PURGE:-<not recorded>}' (want inode=$LC_SWAPFILE_INODE_SEED uuid=$LC_SWAPFILE_UUID_SEED); "
  [[ -z "$bad" ]] \
    && pass "packaging.swapfile-precise-removal: the pre-existing /swapfile (inode=$LC_SWAPFILE_INODE_SEED uuid=$LC_SWAPFILE_UUID_SEED, active across step 1's install and reboot) is identical after remove and purge" \
    || { fail "packaging.swapfile-precise-removal: $bad"; return 1; }
}


LC_REMOVE_HOME_FN=$(cat <<'EOF'
remove_home() {  # remove_home <dir>; rc 0 once <dir> is gone
  (cd / && setpriv --reuid="$(stat -c %u "$1")" --regid="$(stat -c %g "$1")" --clear-groups \
     sh -c "chmod -R u+rwX $1 && find $1 -mindepth 1 -delete") && rmdir "$1"
}
EOF
)
LC_NEW_ACCOUNT_HOME_CMD=$(cat <<'EOF'
set -u
t0=$(date +%s)
db="passwd shadow group gshadow subuid subgid"
save=$(mktemp -d /run/rhizo-lc-account.XXXXXX) || { echo save=failed; echo DONE; exit 0; }
for f in $db; do
  for g in "$f" "$f-"; do [ -e "/etc/$g" ] && cp -a "/etc/$g" "$save/$g"; done
done
names() { LC_ALL=C sort | tr '\n' '/'; }
entries() {
  if runuser -u rhzskel -- ls -A /home/rhzskel > "$save/ls" 2>/dev/null; then names < "$save/ls"; else echo unreadable; fi
}
echo "enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
echo "skel=$(ls -A /etc/skel 2>/dev/null | wc -l)"
echo "login_home_mode=$(awk '$1 == "HOME_MODE" { sub(/^0+/, "", $2); print $2 }' /etc/login.defs 2>/dev/null)"
echo "skel_names=$(ls -A /etc/skel 2>/dev/null | names)"
echo "adduser=$(command -v adduser || echo absent)"
if command -v adduser >/dev/null 2>&1; then
  term_err=$(LC_ALL=C adduser --quiet --disabled-password --comment "" rhzterm 2>&1 >/dev/null); echo "term_adduser_rc=$?"
  echo "term_adduser_err=$(printf '%s' "$term_err" | tr '\n' ' ' | cut -c1-400)"
else
  LC_ALL=C useradd -m rhzterm >/dev/null 2>&1; echo "term_useradd_rc=$?"
  echo "term_home_entries=$(runuser -u rhzterm -- ls -A /home/rhzterm 2>/dev/null | wc -l)"
fi
if getent passwd rhzterm >/dev/null; then echo term_account=present; else echo term_account=absent; fi
if systemctl cat accounts-daemon.service >/dev/null 2>&1; then
  echo create_via=accounts-daemon
  busctl call org.freedesktop.Accounts /org/freedesktop/Accounts org.freedesktop.Accounts \
    CreateUser ssi rhzskel "Rhizo Skel" 0 >/dev/null 2>&1
  echo "create_rc=$?"
else
  echo create_via=useradd
  useradd -m -s /bin/bash rhzskel >/dev/null 2>&1
  echo "create_rc=$?"
fi
uid=$(id -u rhzskel 2>/dev/null)
echo "home_before=$(stat -c %a:%U /home/rhzskel 2>/dev/null):$(entries)"
if [ -n "$uid" ]; then systemctl start "user@$uid.service" >/dev/null 2>&1; echo "user_at_rc=$?"; else echo user_at_rc=no-account; fi
echo "home_after=$(stat -c %a:%U /home/rhzskel 2>/dev/null):$(entries)"
if runuser -u rhzskel -- cmp -s /etc/skel/.bashrc /home/rhzskel/.bashrc 2>/dev/null; then echo bashrc=same; else echo bashrc=differs; fi
a=$(sed -n 's/^alias \([A-Za-z0-9_]*\)=.*/\1/p' /etc/skel/.bashrc 2>/dev/null | head -1); echo "skel_alias=${a:-none}"
if [ -n "$a" ] && runuser -l rhzskel -c "bash -lic 'alias $a'" >/dev/null 2>&1 \
   && ! runuser -u rhzskel -- bash --norc --noprofile -ic "alias $a" >/dev/null 2>&1; then echo login_shell_alias=yes; else echo login_shell_alias=no; fi
echo "journal_fill=$(journalctl -b --since "@$t0" -u "rhizo-user-prep@${uid:-none}.service" -u "user@${uid:-none}.service" --no-pager 2>/dev/null | grep -c 'rhizo-skel-fill: filled /home/rhzskel')"
left=""
for u in rhzskel rhzterm; do
  u_id=$(id -u "$u" 2>/dev/null) || continue
  loginctl terminate-user "$u" >/dev/null 2>&1
  systemctl stop "user@$u_id.service" "user-runtime-dir@$u_id.service" >/dev/null 2>&1
  userdel "$u" >/dev/null 2>&1 || left="$left account:$u"
done
for g in rhzskel rhzterm; do
  getent group "$g" >/dev/null || continue
  groupdel "$g" >/dev/null 2>&1 || left="$left group:$g"
done
rm -f /var/lib/AccountsService/users/rhzskel /var/lib/AccountsService/users/rhzterm
for h in /home/rhzskel /home/rhzterm; do
  [ -e "$h" ] || continue
  remove_home "$h" || left="$left home:$h"
done
for f in $db; do
  if [ -e "$save/$f-" ]; then cp -a "$save/$f-" "/etc/$f-" || left="$left backup:$f-"; else rm -f "/etc/$f-"; fi
  if [ -e "$save/$f" ]; then cmp -s "$save/$f" "/etc/$f" || left="$left changed:/etc/$f"
  elif [ -e "/etc/$f" ]; then left="$left new:/etc/$f"; fi
done
rm -rf "$save"
if [ -z "$left" ]; then echo cleanup=ok; else echo "cleanup=left:$left"; fi
echo DONE
EOF
)
LC_NEW_ACCOUNT_HOME_CMD="$LC_REMOVE_HOME_FN"$'\n'"$LC_NEW_ACCOUNT_HOME_CMD"

# check new accounts get their home from /etc/skel
lc_assert_host.new-account-home() {
  local id=host.new-account-home profile="${1:-}" out skel skel_names term_err want got key
  lc_need_guest "$id" || return 1
  lc_claim_host_mode "$id" "enforcing host and the adduser disclosure" || return 1
  # desk-user-ok: root only stats, creates and rmdirs each home itself; inside a home it runs as its owner
  out=$(ssh_vm -t 180 "$LC_NEW_ACCOUNT_HOME_CMD")
  lc_done_strip out || { fail "$id: incomplete guest read (no DONE token): $(tr '\n' ' ' <<<"${out:-<empty>}")"; return 1; }
  skel=$(sed -n 's/^skel=//p' <<<"$out")
  [[ "$skel" =~ ^[1-9][0-9]*$ ]] || { fail "$id: /etc/skel lists '${skel:-<unread>}' entries"; return 1; }
  skel_names=$(sed -n 's/^skel_names=//p' <<<"$out")
  [[ -n "$skel_names" ]] || { fail "$id: no /etc/skel name list read"; return 1; }
  local term_account=absent term_how="terminal adduser failed on the disclosed skel copy and left no account"
  if grep -qx 'adduser=absent' <<<"$out"; then
    lc_on_cachyos || { fail "$id: the host has no adduser"; return 1; }
    grep -qx 'term_useradd_rc=0' <<<"$out" && grep -qx 'term_home_entries=0' <<<"$out" \
      || { fail "$id: a terminal useradd -m did not exit 0 with an empty home: $(grep -E '^term_(useradd_rc|home_entries)=' <<<"$out" | tr '\n' ' ')"; return 1; }
    term_account=present term_how="terminal useradd -m made the account with an empty home, its skel copy refused without a word"
  else
  if grep -qx 'term_adduser_rc=0' <<<"$out"; then
    fail "$id: terminal adduser succeeded: $(tr '\n' ' ' <<<"$out")"; return 1
  fi
  grep -qxE 'term_adduser_rc=[1-9][0-9]*' <<<"$out" \
    || { fail "$id: no terminal adduser exit status read ($(grep '^term_adduser_rc=' <<<"$out" || echo 'no term_adduser_rc line'))"; return 1; }
  term_err=$(sed -n 's/^term_adduser_err=//p' <<<"$out")
  grep -qE '(open >/home/rhzterm/[^ ]*|mkdir: /home/rhzterm/[^ ]*|symlink): Permission denied' <<<"$term_err" \
    || { fail "$id: terminal adduser failed, but not with the disclosed skel copy's 'open >/home/rhzterm/...: Permission denied': ${term_err:-<no stderr>}"; return 1; }
  fi
  [[ "$profile" != gnome ]] || grep -qx 'create_via=accounts-daemon' <<<"$out" \
    || { fail "$id: gnome has no accounts-daemon to create the account through ($(grep '^create_via=' <<<"$out"))"; return 1; }
  local mode; mode=$(sed -n 's/^login_home_mode=//p' <<<"$out")
  [[ "$mode" =~ ^[0-7]{3}$ ]] || { fail "$id: no HOME_MODE read from /etc/login.defs ('${mode:-<none>}')"; return 1; }
  for want in enforce=1 "term_account=$term_account" create_rc=0 "home_before=$mode:rhzskel:" user_at_rc=0 \
              "home_after=$mode:rhzskel:$skel_names" bashrc=same login_shell_alias=yes journal_fill=1 cleanup=ok; do
    key="${want%%=*}"
    got=$(grep "^$key=" <<<"$out" | head -1)
    [[ "$got" == "$want" ]] \
      || { fail "$id: host mode: want $want, got ${got:-no $key line}: $(tr '\n' ' ' <<<"$out")"; return 1; }
  done
  pass "$id: host mode: $term_how; $(sed -n 's/^create_via=//p' <<<"$out") made a 0$mode empty home that user@ filled with exactly /etc/skel's $skel entries ($skel_names) as its owner, a login shell reads them (skel's alias $(sed -n 's/^skel_alias=//p' <<<"$out")), and the recipe removed it all"
}

LC_USER_MANAGER_START_CMD=$(cat <<'EOF'
set -u
u=rhzlogin
db="passwd shadow group gshadow subuid subgid"
save=$(mktemp -d /run/rhizo-lc-login.XXXXXX) || { echo save=failed; echo DONE; exit 0; }
for f in $db; do
  for g in "$f" "$f-"; do [ -e "/etc/$g" ] && cp -a "/etc/$g" "$save/$g"; done
done
echo "enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
useradd -m -s /bin/bash "$u" >/dev/null 2>&1; echo "create_rc=$?"
uid=$(id -u "$u" 2>/dev/null) || uid=none
echo "uid=$uid"
cg=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service
key="$save/key"
ssh-keygen -q -t ed25519 -N '' -f "$key" >/dev/null 2>&1; echo "key_rc=$?"
runuser -u "$u" -- sh -c 'umask 077 && mkdir -p "$1/.ssh" && cat > "$1/.ssh/authorized_keys"' sh "/home/$u" < "$key.pub"
echo "authkeys_rc=$?"
login() {
  o=$(timeout 90 ssh -n -i "$key" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$u@127.0.0.1" '
    echo "class=$(loginctl show-session "$XDG_SESSION_ID" -p Class --value 2>&1)"
    echo "manager=$(systemctl --user is-system-running 2>&1)"
    if [ -S "$XDG_RUNTIME_DIR/bus" ]; then echo bus=yes; else echo bus=no; fi' 2>&1)
  echo "$1_run_rc=$?"
  printf '%s\n' "$o" | sed "s/^/$1_/"
  echo "$1_result=$(systemctl show -p Result --value "user@$uid.service")"
  echo "$1_status=$(systemctl show -p ExecMainStatus --value "user@$uid.service")"
}
logout() {
  loginctl terminate-user "$u" >/dev/null 2>&1
  i=0
  while [ "$(systemctl is-active "user@$uid.service")" != inactive ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i+1)); done
  echo "$1_user_at=$(systemctl is-active "user@$uid.service")"
  if [ -d "$cg" ]; then echo "$1_leftover=yes"; else echo "$1_leftover=no"; fi
}
if [ "$uid" != none ]; then
  login first; logout first
  login again; logout again
  echo "reset_logged=$(journalctl -b -u "rhizo-user-prep@$uid.service" --no-pager 2>/dev/null | grep -c "rhizo-user-cgroup-reset: removed the cgroup user@$uid.service")"
fi
if [ -z "${greeter:-}" ]; then
  echo greeter_user_at=no-login-manager
elif ! greeter_uid=$(id -u "$greeter" 2>/dev/null); then
  echo greeter_user_at=no-greeter-account
else
  first_usec() { sed -n 's/.*"__MONOTONIC_TIMESTAMP":"\([0-9]*\)".*/\1/p' | head -1; }
  echo "greeter_policy_at=$(journalctl -b -o json --no-pager _PID=1 UNIT=rhizo-policy.service \
    MESSAGE_ID=39f53479d3a045ac8e11786248231fbf 2>/dev/null | first_usec)"
  echo "greeter_user_at_started=$(journalctl -b -o json --no-pager _PID=1 "UNIT=user@$greeter_uid.service" \
    MESSAGE_ID=39f53479d3a045ac8e11786248231fbf 2>/dev/null | first_usec)"
  echo "greeter_user_at_failed=$(journalctl -b -o json --no-pager _PID=1 "UNIT=user@$greeter_uid.service" \
    MESSAGE_ID=be02cf6855d2428ba40df7e9d022f03d 2>/dev/null | grep -c .)"
  echo "greeter_seat_session_at=$(journalctl -b -o json --no-pager MESSAGE_ID=8d45620c1a4348dbb17410da57c60c66 \
    "USER_ID=${seat_user:-}" 2>/dev/null | first_usec)"
fi
left=""
if [ "$uid" != none ]; then
  loginctl terminate-user "$u" >/dev/null 2>&1
  systemctl stop "user@$uid.service" "user-runtime-dir@$uid.service" >/dev/null 2>&1
  /usr/lib/rhizo/install/bootstrap/user-cgroup-reset.sh "$uid" >/dev/null 2>&1
  if [ -d "$cg" ]; then echo cgroup_after_cleanup=left; else echo cgroup_after_cleanup=gone; fi
  userdel "$u" >/dev/null 2>&1 || left="$left account:$u"
fi
if getent group "$u" >/dev/null; then groupdel "$u" >/dev/null 2>&1 || left="$left group:$u"; fi
h=/home/$u
if [ -e "$h" ]; then
  remove_home "$h" || left="$left home:$h"
fi
for f in $db; do
  if [ -e "$save/$f-" ]; then cp -a "$save/$f-" "/etc/$f-" || left="$left backup:$f-"; else rm -f "/etc/$f-"; fi
  if [ -e "$save/$f" ]; then cmp -s "$save/$f" "/etc/$f" || left="$left changed:/etc/$f"
  elif [ -e "/etc/$f" ]; then left="$left new:/etc/$f"; fi
done
rm -rf "$save"
if [ -z "$left" ]; then echo cleanup=ok; else echo "cleanup=left:$left"; fi
echo DONE
EOF
)
LC_USER_MANAGER_START_CMD="$LC_REMOVE_HOME_FN"$'\n'"$LC_USER_MANAGER_START_CMD"

LC_PRIVATE_USERS_DROPIN=/usr/lib/systemd/system/service.d/50-rhizo-private-users.conf
LC_PRIVATE_USERS_STOCK=uuidd.service
[[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]] && LC_PRIVATE_USERS_STOCK=power-profiles-daemon.service
LC_PRIVATE_USERS_CMD=$(cat <<'EOF'
echo "enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
if d=$(cat "$f" 2>/dev/null); then
  if command -v pacman >/dev/null 2>&1; then echo "dropin_owner=$(pacman -Qoq "$f" 2>/dev/null)"
  else echo "dropin_owner=$(dpkg-query -S "$f" 2>/dev/null | cut -d: -f1)"; fi
  echo "dropin_off=$(printf '%s\n' "$d" | sed -n '/^\[Service\]/,/^\[/p' | grep -cx 'PrivateUsers=no')"
  echo "dropin_read=$(systemctl show -p DropInPaths --value systemd-journald.service | tr ' ' '\n' | grep -cx "$f")"
else echo dropin=absent; fi
m=$(systemd-run --wait --pipe --quiet --collect --unit=rhizo-lc-privusers -p PrivateUsers=yes cat /proc/self/uid_map 2>&1); echo "run_rc=$?"
echo "$m" | sed 's/^/map /'
if [ "$(systemctl show -p LoadState --value upower.service)" = loaded ]; then
  echo "upower_boot=$(systemctl is-active upower.service)"
else echo upower=absent; fi
units=$(systemctl list-units --type=service --all --plain --no-legend); echo "pu_list_rc=$?"
n=0
for u in $(printf '%s\n' "$units" | cut -d' ' -f1); do
  systemctl cat "$u" 2>/dev/null | grep -qiE '^PrivateUsers=(yes|true|on|1|self|identity|full)$' || continue
  [ -n "$(systemctl show -p InvocationID --value "$u")" ] || systemctl start "$u" >/dev/null 2>&1
  n=$((n + 1))
  echo "pu_unit=$u:$(systemctl show -p InvocationID --value "$u"):$(systemctl show -p Result --value "$u"):$(systemctl show -p ActiveState --value "$u"):$(systemctl show -p ExecMainStatus --value "$u")"
done
echo "pu_checked=$n"
if [ "$(systemctl show -p LoadState --value upower.service)" = loaded ]; then
  systemctl start upower.service >/dev/null 2>&1; echo "upower_rc=$?"; echo "upower=$(systemctl is-active upower.service)"
fi
echo DONE
EOF
)
LC_PRIVATE_USERS_CMD="f=$LC_PRIVATE_USERS_DROPIN"$'\n'"$LC_PRIVATE_USERS_CMD"
LC_PRIVATE_USERS_USER_CMD=$(cat <<'EOF'
m=$(systemd-run --user --wait --pipe --quiet --collect -p PrivateUsers=yes cat /proc/self/uid_map 2>&1); echo "urun_rc=$?"
echo "$m" | sed 's/^/umap /'
echo DONE
EOF
)
# check PrivateUsers= services start on the enforcing host
lc_assert_host.private-users-services() {
  local id=host.private-users-services out map umap uout up upb n bad row inv res act why=() user
  local prof="${1:-}"
  [[ -n "$prof" ]] || { fail "$id: no cycle profile argument"; return 1; }
  lc_need_guest "$id" || return 1
  lc_claim_host_mode "$id" "enforcing host and its PrivateUsers=no drop-in" || return 1
  out=$(ssh_vm -t 120 "$LC_PRIVATE_USERS_CMD" 2>/dev/null | tr -d '\r')
  lc_done_strip out || { fail "$id: incomplete guest read (no DONE token): $(tr '\n' ' ' <<<"${out:-<empty>}")"; return 1; }
  [[ "$(grep -m1 '^enforce=' <<<"$out")" == enforce=1 ]] \
    || { fail "$id: host mode: the host is not enforcing ($(grep -m1 '^enforce=' <<<"$out"))"; return 1; }
  map=$(sed -n 's/^map //p' <<<"$out" | tr -s ' ' | sed 's/^ //' | sed '/^$/d' | tr '\n' '|')
  [[ "$(grep -m1 '^run_rc=' <<<"$out")" == run_rc=0 && "$map" == '0 0 4294967295|' ]] \
    || why+=("(a) a PrivateUsers=yes transient system service did not run in the host's namespace ($(grep -m1 '^run_rc=' <<<"$out"), uid_map '${map:-<none>}', want '0 0 4294967295|')")
  [[ "$(grep -m1 '^pu_list_rc=' <<<"$out")" == pu_list_rc=0 ]] \
    || why+=("(b) systemctl list-units did not answer ($(grep -m1 '^pu_list_rc=' <<<"$out"))")
  n=$(sed -n 's/^pu_checked=//p' <<<"$out")
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 )) \
    || why+=("(b) no loaded system unit declaring PrivateUsers= was checked (pu_checked=${n:-<none>})")
  bad=()
  while IFS= read -r row; do
    IFS=: read -r _ inv res act _ <<<"$row"
    [[ -n "$inv" && "$res" == success && "$act" != failed ]] || bad+=("$row")
  done < <(sed -n 's/^pu_unit=//p' <<<"$out")
  (( ${#bad[@]} == 0 )) \
    || why+=("(b) stock PrivateUsers= units that did not run this boot (unit:invocation:result:state:status): ${bad[*]}")
  grep -q "^pu_unit=$LC_PRIVATE_USERS_STOCK:" <<<"$out" \
    || why+=("(b) $LC_PRIVATE_USERS_STOCK was not among the units checked")
  up=$(grep -m1 '^upower=' <<<"$out"); upb=$(grep -m1 '^upower_boot=' <<<"$out")
  [[ ( "$up" == upower=absent && -z "$upb" ) || ( "$up" == upower=active && "$upb" != upower_boot=failed ) ]] \
    || why+=("(b) upower.service reads ${upb:-upower_boot=?} after boot and ${up:-upower=?} after a start ($(grep -m1 '^upower_rc=' <<<"$out"))")
  if grep -qx 'dropin=absent' <<<"$out"; then
    why+=("(c) $LC_PRIVATE_USERS_DROPIN is absent")
  else
    [[ "$(grep -m1 '^dropin_owner=' <<<"$out")" == dropin_owner=rhizo ]] \
      || why+=("(c) $LC_PRIVATE_USERS_DROPIN is not rhizo's packaged file ($(grep -m1 '^dropin_owner=' <<<"$out"))")
    [[ "$(grep -m1 '^dropin_off=' <<<"$out")" == dropin_off=1 ]] \
      || why+=("(c) $LC_PRIVATE_USERS_DROPIN sets no [Service] PrivateUsers=no ($(grep -m1 '^dropin_off=' <<<"$out"))")
    [[ "$(grep -m1 '^dropin_read=' <<<"$out")" == dropin_read=1 ]] \
      || why+=("(c) systemd lists no $LC_PRIVATE_USERS_DROPIN among systemd-journald.service's DropInPaths ($(grep -m1 '^dropin_read=' <<<"$out"))")
  fi
  if [[ "$prof" == server ]]; then
    user="(d) is not asserted on server, whose profile runs no desktop user's systemd --user or user bus"
  else
    uout=$(desk_user_sh 60 "$LC_PRIVATE_USERS_USER_CMD" 2>&1 | tr -d '\r')
    if ! lc_done_strip uout; then
      why+=("(d) incomplete desktop-user read (no DONE token): $(tr '\n' ' ' <<<"${uout:-<empty>}")")
    else
      umap=$(sed -n 's/^umap //p' <<<"$uout" | tr -s ' ' | sed 's/^ //' | sed '/^$/d' | tr '\n' '|')
      [[ "$(grep -m1 '^urun_rc=' <<<"$uout")" == urun_rc=0 && -n "$umap" && "$umap" != *4294967295* ]] \
        || why+=("(d) a desktop user's PrivateUsers=yes unit ($(grep -m1 '^urun_rc=' <<<"$uout")) read uid_map '${umap:-<none>}', not a private user namespace")
      user="a desktop user's PrivateUsers=yes unit got its own namespace (uid_map $umap)"
    fi
  fi
  if (( ${#why[@]} )); then
    fail "$id: host mode: $(printf '%s; ' "${why[@]}" | sed 's/; $//')"
    return 1
  fi
  pass "$id: host mode: a PrivateUsers=yes system service ran in the host's namespace (uid_map $map) under enforcement with rhizo's $LC_PRIVATE_USERS_DROPIN read by systemd, $n stock PrivateUsers= unit(s) ran this boot and succeeded ($(sed -n 's/^pu_unit=\([^:]*\):.*/\1/p' <<<"$out" | tr '\n' ' ' | sed 's/ $//')), upower.service ${up#upower=}; $user"
}

# check a user unit's journal entries carry its invocation id
lc_assert_host.journal-user-units() {
  local id=host.journal-user-units n unit out entry deadline
  lc_need_guest "$id" || return 1
  n=$(printf '%04x%04x' $RANDOM $RANDOM); unit="rhizo-lc-jrnl-$n"
  out=$(desk_user_sh 30 "systemd-run --user --quiet --unit=$unit /bin/sh -c 'echo rhizo-lc-jrnl-$n; exec sleep infinity'; echo rc=\$?" 2>&1)
  if [[ "$(tail -1 <<<"$out")" != rc=0 ]]; then
    fail "$id: the desktop user could not start a user unit to log from: $(tr '\n' ' ' <<<"${out:-<empty>}")"
    return 1
  fi
  deadline=$(( $(date +%s) + 30 )); entry=""
  while (( $(date +%s) < deadline )); do
    out=$(ssh_vm -t 20 "journalctl _SYSTEMD_USER_UNIT=$unit.service -o export --no-pager 2>/dev/null; echo DONE" 2>/dev/null | tr -d '\r')
    lc_done_strip out && entry=$(awk -v m="MESSAGE=rhizo-lc-jrnl-$n" 'BEGIN { RS = "" } index($0, m "\n") || substr($0, length($0) - length(m) + 1) == m { print; exit }' <<<"$out")
    [[ -n "$entry" ]] && break
    sleep 1
  done
  desk_user_sh 20 "systemctl --user stop $unit.service" >/dev/null 2>&1
  [[ -n "$entry" ]] || { fail "$id: the journal held no entry of user unit $unit.service's line within 30s"; return 1; }
  grep -qE '^_SYSTEMD_INVOCATION_ID=[0-9a-f]{32}$' <<<"$entry" \
    || { fail "$id: user unit $unit.service's entry carries no _SYSTEMD_INVOCATION_ID: $(grep -E '^_(SYSTEMD_USER_UNIT|UID|PID)=' <<<"$entry" | tr '\n' ' ')"; return 1; }
  pass "$id: user unit $unit.service's journal entry carries its $(grep -m1 '^_SYSTEMD_INVOCATION_ID=' <<<"$entry")"
}

LC_PROBE_CLIENT=/usr/lib/rhizo/rhizo-probe-client
LC_PROBE_SOCK=/run/rhizo/data/local/tmp/rhizo-probe.sock
# check the probe channel answers root and refuses the desktop user
lc_assert_host.probe-root-only() {
  local id=host.probe-root-only n cmd root_out user_out
  lc_need_guest "$id" || return 1
  n=$(printf '%04x%04x' $RANDOM $RANDOM)
  cmd="$LC_PROBE_CLIENT $LC_PROBE_SOCK 10 'echo rhizo-lc-probe-$n'"
  root_out=$(ssh_vm -t 30 "$cmd 2>&1; echo rc=\$?" 2>/dev/null | tr -d '\r')
  if ! grep -qx "rhizo-lc-probe-$n" <<<"$root_out"; then
    fail "$id: root's own probe of the sandbox did not answer: $(tr '\n' ' ' <<<"${root_out:-<empty>}")"
    return 1
  fi
  user_out=$(desk_user_sh 30 "$cmd 2>&1; echo rc=\$?" 2>&1 | tr -d '\r')
  [[ "$user_out" == *rc=* ]] || { fail "$id: the desktop user's probe attempt never finished: $(tr '\n' ' ' <<<"${user_out:-<empty>}")"; return 1; }
  if grep -qx "rhizo-lc-probe-$n" <<<"$user_out" || grep -qx 'rc=0' <<<"$user_out"; then
    fail "$id: the desktop user ran a command in Android through rhizo-probed: $(tr '\n' ' ' <<<"$user_out")"
    return 1
  fi
  local how=""
  if grep -qx 'rc=97' <<<"$user_out" && grep -qx 'RHIZO_PROBE_UNREACHABLE: Permission denied' <<<"$user_out"; then
    how="connect() refused by the socket's 0600 mode and uid-0 ACL, before rhizo-probed's SO_PEERCRED check"
  elif grep -qx 'rc=98' <<<"$user_out" && grep -qE '^RHIZO_PROBE_REFUSED: peer uid [1-9][0-9]* is not root$' <<<"$user_out"; then
    how="rhizo-probed's SO_PEERCRED refusal: $(grep -m1 '^RHIZO_PROBE_REFUSED' <<<"$user_out")"
  fi
  if [[ -z "$how" ]]; then
    fail "$id: the desktop user's probe failed, but neither by the socket's DAC nor by rhizo-probed's refusal: $(tr '\n' ' ' <<<"$user_out")"
    return 1
  fi
  pass "$id: root's probe answered, and the desktop user's was refused: $how"
}

# check each login gets a running user manager and bus
lc_assert_host.user-manager-start() {
  local id=host.user-manager-start profile="${1:-}" out want key got pol gstart gfail seat
  lc_need_guest "$id" || return 1
  lc_claim_host_mode "$id" "enforcing host and rhizo-policy.service's order" || return 1
  local greeter=""
  if declare -F _lc_seat_login_kind >/dev/null; then
    greeter=$(_lc_seat_login_kind "$profile" 2>/dev/null | awk '{ print $3 }')
    [[ "$greeter" == - ]] && greeter=""
  fi
  # desk-user-ok: root only creates, stats and rmdirs the login account's home; inside it runs as its owner
  out=$(ssh_vm -t 240 "seat_user=$(printf '%q' "${LC_DESKTOP_HUMAN:-}") greeter=$(printf '%q' "$greeter")"$'\n'"$LC_USER_MANAGER_START_CMD")
  lc_done_strip out || { fail "$id: incomplete guest read (no DONE token): $(tr '\n' ' ' <<<"${out:-<empty>}")"; return 1; }
  for want in enforce=1 create_rc=0 key_rc=0 authkeys_rc=0 \
              first_run_rc=0 first_class=user first_bus=yes first_result=success first_status=0 first_user_at=inactive \
              again_run_rc=0 again_class=user again_bus=yes again_result=success again_status=0 again_user_at=inactive \
              cgroup_after_cleanup=gone cleanup=ok; do
    key="${want%%=*}"
    got=$(grep "^$key=" <<<"$out" | head -1)
    [[ "$got" == "$want" ]] \
      || { fail "$id: host mode: want $want, got ${got:-no $key line}: $(tr '\n' ' ' <<<"$out")"; return 1; }
  done
  for key in first_manager again_manager; do
    got=$(grep "^$key=" <<<"$out" | head -1)
    [[ "$got" =~ ^$key=(running|degraded)$ ]] \
      || { fail "$id: want $key=running or degraded, got ${got:-no $key line}: $(tr '\n' ' ' <<<"$out")"; return 1; }
  done
  grep -qxE 'first_leftover=(yes|no)' <<<"$out" && grep -qxE 'reset_logged=[0-9]+' <<<"$out" \
    || { fail "$id: no leftover-cgroup or reset count read after the first logout: $(tr '\n' ' ' <<<"$out")"; return 1; }
  if grep -qx first_leftover=yes <<<"$out" && grep -qx reset_logged=0 <<<"$out"; then
    fail "$id: the first logout left user@'s cgroup and the second start logged no reset: $(tr '\n' ' ' <<<"$out")"; return 1
  fi
  if [[ -n "$greeter" ]]; then
    grep -qx greeter_user_at=no-greeter-account <<<"$out" \
      && { fail "$id: $profile logs in through $greeter's greeter, and this host has no $greeter account"; return 1; }
    pol=$(sed -n 's/^greeter_policy_at=//p' <<<"$out"); gstart=$(sed -n 's/^greeter_user_at_started=//p' <<<"$out")
    gfail=$(sed -n 's/^greeter_user_at_failed=//p' <<<"$out"); seat=$(sed -n 's/^greeter_seat_session_at=//p' <<<"$out")
    [[ "$gfail" == 0 ]] \
      || { fail "$id: $greeter's greeter's user manager failed to start ${gfail:-<unread>} time(s) this boot"; return 1; }
    [[ "$gstart" =~ ^[0-9]+$ ]] \
      || { fail "$id: this boot's journal holds no start of $greeter's greeter's user manager (${gstart:-<none>})"; return 1; }
    [[ "$pol" =~ ^[0-9]+$ ]] && (( 10#$gstart > 10#$pol )) \
      || { fail "$id: $greeter's greeter's user manager started at ${gstart}us, not after rhizo-policy.service finished (${pol:-<none>}us)"; return 1; }
    [[ "$seat" =~ ^[0-9]+$ ]] \
      || { fail "$id: this boot's journal holds no logind session of ${LC_DESKTOP_HUMAN:-the desktop user} (read '${seat:-<none>}'; host.seat-login says why)"; return 1; }
    (( 10#$gstart < 10#$seat )) \
      || { fail "$id: $greeter's greeter's user manager started at ${gstart}us, not before ${LC_DESKTOP_HUMAN:-the desktop user}'s seat session (${seat}us)"; return 1; }
  fi
  pass "$id: host mode: an sshd login (class user) got a running user manager and session bus under enforcement, twice across a logout ($(grep -E '^(first_leftover|reset_logged|greeter_[a-z_]+)=' <<<"$out" | tr '\n' ' '))"
}
