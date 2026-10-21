#!/bin/bash
# test devices.dri off when enforcing
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: none
# test-records-metrics: no
# test-verdict-params: -
# test-requires: share:gpu_driver_software share:rhizo-secureapp.apk
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }

SELFTEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

SECURE_PKG=com.rhizo.secureapp
SECURE_ACT=com.rhizo.secureapp/.MainActivity
CAL_PKG=com.android.calendar
CAL_ACT=com.android.calendar/.AllInOneActivity
HOME_PKG=com.rhizo.home
SOFTWARE_LINE="RHIZO_GPU dri=off driver=gpu_driver_software"
AVC_LOG=/var/log/rhizo/rhizo-avc.log
SUPERVISOR_LOG=/var/log/rhizo/supervisor.log
REFUSED_MARKER="RHIZO_MARKER gpu_driver_refused=policy-reload-needed"
BOOTED_MARKER="RHIZO_MARKER sys.boot_completed=1 sandbox=0"

if (( SELFTEST )); then
  SELFTEST_EV="${TMPDIR:-/tmp}/test-software-render-selftest${SUFFIX}"
  rm -rf "$SELFTEST_EV"
  test_init software-render --no-vm --evidence-root "$SELFTEST_EV" || exit 1
  # shellcheck disable=SC2034
  TEST_VERDICT_RECORDED=1
else
  test_init software-render || exit 1
fi

INIT=""
PREPARED_BACKUP=/root/.software-render-prepared
REBOOT_FLAG_BEFORE=""
SETTINGS_BEFORE=""
SETTINGS_OK=0
# restore the policy, screen settings and .prepared marker
software_render_cleanup() {
  (( TEST_NO_VM )) && return 0
  local out init stay timeout verdict=CLEANUP_OK
  out=$(ssh_vm -t 30 "mkdir -p /etc/rhizo && python3 - off /etc/rhizo/policy.conf" <"$REPO/test/vm/image/guest-policy-dri.py" 2>&1)
  printf 'devices.dri off through guest-policy-dri.py: %s\n' "${out:-<none>}" >"$EV/cleanup.txt"
  init=$(guest_init_pid 15)
  if [[ -n "$init" ]]; then
    stay=$(sed -n 's/^stay=//p' <<<"$SETTINGS_BEFORE"); timeout=$(sed -n 's/^timeout=//p' <<<"$SETTINGS_BEFORE")
    [[ "$stay" =~ ^[0-9]+$ ]] && android_sh "$init" "settings put global stay_on_while_plugged_in $stay" >/dev/null 2>&1
    [[ "$timeout" =~ ^[0-9]+$ ]] && android_sh "$init" "settings put system screen_off_timeout $timeout" >/dev/null 2>&1
    ssh_vm -t 120 "rhizo app remove $SECURE_PKG" >>"$EV/cleanup.txt" 2>&1
  fi
  ssh_vm -t 15 "if [ -s $PREPARED_BACKUP ]; then [ -s /var/lib/rhizo/.prepared ] || cp -p $PREPARED_BACKUP /var/lib/rhizo/.prepared; fi" >/dev/null 2>&1
  [[ "$REBOOT_FLAG_BEFORE" == absent ]] && ssh_vm -t 10 "rm -f /run/reboot-required" >/dev/null 2>&1
  ssh_vm -t 30 sync >/dev/null 2>&1
  out=$(ssh_vm -t 30 "sed -n 's/^dri *= *//p' /etc/rhizo/policy.conf; if [ -s $PREPARED_BACKUP ] && [ ! -s /var/lib/rhizo/.prepared ]; then echo prepared-missing; fi; rm -f $PREPARED_BACKUP; echo RHIZO_CLEANUP_READ" 2>&1)
  [[ "$out" == *RHIZO_CLEANUP_READ* ]] || verdict=CLEANUP_UNVERIFIED
  [[ "$verdict" == CLEANUP_OK && "$(head -1 <<<"$out")" != off ]] && verdict=CLEANUP_INCOMPLETE
  [[ "$out" == *prepared-missing* ]] && verdict=CLEANUP_INCOMPLETE
  if [[ -n "$init" && "$verdict" == CLEANUP_OK ]]; then
    out=$(android_sh "$init" "settings get global stay_on_while_plugged_in; settings get system screen_off_timeout; pm list packages $SECURE_PKG")
    printf 'after: %s\n' "${out//$'\n'/ | }" >>"$EV/cleanup.txt"
    [[ "$out" == *"package:$SECURE_PKG"* ]] && verdict=CLEANUP_INCOMPLETE
  elif [[ -z "$init" ]]; then
    verdict=CLEANUP_INCOMPLETE
    echo "no sandbox running: the screen settings and the secure app could not be restored" >>"$EV/cleanup.txt"
  fi
  echo "$verdict" >>"$EV/cleanup.txt"
  log "$verdict (see $EV/cleanup.txt)"
}


# check the kernel log for the software render markers
assert_boot_markers() {
  local label="$1" dm="$2" want miss="" bad
  for want in "RHIZO_MARKER gpu_mode=software driver=gpu_driver_software" "RHIZO_MARKER policy_dri=off" \
              "RHIZO_MARKER software_rro=staged" "memfd buffers (RHIZO_ALLOCATOR=memfd), no render node opened"; do
    grep -qaF "$want" <<<"$dm" || miss+="'$want' "
  done
  [[ -z "$miss" ]] || { fail "$label: this boot's kernel log lacks $miss-- the launch did not take the software path"; return 1; }
  bad=$(grep -aE 'RHIZO_MARKER (gpu_mode=gpu|gpu_driver_refused=)|dri_source=' <<<"$dm" | head -3)
  [[ -z "$bad" ]] || { fail "$label: this boot's kernel log carries a gpu-mode or refusal line: ${bad//$'\n'/ | }"; return 1; }
  pass "$label: gpu_mode=software on the software set, the policy recorded for dri off, the software overlay and memfd buffers, with no render node source and no refusal"
}

# check the guest has no /dev/dri and no render node in sysfs
assert_no_guest_dri() {
  local label="$1" out="$2"
  [[ "$out" == *RHIZO_DRI_DONE* ]] || { fail "$label: the /dev/dri read never finished (got '${out:-<empty>}')"; return 1; }
  grep -qx 'dev_dri=absent' <<<"$out" \
    || { fail "$label: the guest has a /dev/dri ($(grep '^dev_dri=' <<<"$out"))"; return 1; }
  grep -qx 'render_nodes=0' <<<"$out" \
    || { fail "$label: /sys/class/drm lists a render node ($(grep '^render_nodes=' <<<"$out")) on a vm booted with no gpu device"; return 1; }
  pass "$label: the guest has no /dev/dri and no render node"
}

# check /sys/fs/selinux/enforce reads 1
assert_enforcing() {
  local label="$1" v="${2//[[:space:]]/}"
  [[ "$v" == 1 ]] || { fail "$label: /sys/fs/selinux/enforce reads '${v:-<empty>}', wanted 1"; return 1; }
  pass "$label: the guest is enforcing"
}

# check a rhizo gpu line's last line is the one wanted
assert_cli_line() {
  local label="$1" out="$2" want="$3" got
  got=$(tail -1 <<<"$out")
  [[ "$got" == "$want" ]] || { fail "$label: printed '${got:-<nothing>}', wanted '$want'"; return 1; }
  pass "$label: $want"
}

# check SurfaceFlinger's GLES line names llvmpipe
assert_gles_llvmpipe() {
  local label="$1" sf="$2" gles
  gles=$(grep -m1 -E '^GLES: ' <<<"$sf")
  [[ -n "$gles" ]] || { fail "$label: dumpsys SurfaceFlinger has no 'GLES:' line"; return 1; }
  [[ "$gles" == *llvmpipe* ]] || { fail "$label: SurfaceFlinger composes on '$gles', not llvmpipe"; return 1; }
  pass "$label: ${gles}"
}

# check the software overlay is enabled on the framework
assert_overlay_enabled() {
  local label="$1" list="$2"
  grep -qx '\[x\] com.rhizo.overlay.software' <<<"$list" \
    || { fail "$label: cmd overlay list android does not show '[x] com.rhizo.overlay.software'"; return 1; }
  pass "$label: com.rhizo.overlay.software is enabled"
}

# check ro.config.avoid_gfx_accel reads true
assert_avoid_gfx_accel() {
  local label="$1" v="${2//[[:space:]]/}"
  [[ "$v" == true ]] || { fail "$label: ro.config.avoid_gfx_accel reads '${v:-<empty>}', not true"; return 1; }
  pass "$label: ro.config.avoid_gfx_accel=true"
}

# check the screen-off fade is disabled
assert_colorfade_off() {
  local label="$1" dump="$2" on off
  off=$(grep -c 'mColorFadeEnabled=false' <<<"$dump")
  on=$(grep -c 'mColorFadeEnabled=true' <<<"$dump")
  (( off > 0 )) || { fail "$label: dumpsys display carries no mColorFadeEnabled line"; return 1; }
  (( on == 0 )) || { fail "$label: $on display(s) report mColorFadeEnabled=true"; return 1; }
  pass "$label: mColorFadeEnabled=false on every display ($off line(s))"
}

# check two pids read the same and are pids
assert_pid_kept() {
  local label="$1" what="$2" before="${3//[[:space:]]/}" after="${4//[[:space:]]/}"
  [[ "$before" =~ ^[0-9]+$ ]] || { fail "$label: $what's pid before reads '${before:-<empty>}'"; return 1; }
  [[ "$after" =~ ^[0-9]+$ ]] || { fail "$label: $what's pid after reads '${after:-<empty>}' -- $what is not running"; return 1; }
  [[ "$before" == "$after" ]] || { fail "$label: $what restarted ($before -> $after)"; return 1; }
  pass "$label: $what kept pid $after"
}

# check two pids read differently and are pids
assert_pid_changed() {
  local label="$1" what="$2" before="${3//[[:space:]]/}" after="${4//[[:space:]]/}"
  [[ "$before" =~ ^[0-9]+$ ]] || { fail "$label: $what's host pid before the restart reads '${before:-<empty>}'"; return 1; }
  [[ "$after" =~ ^[0-9]+$ ]] || { fail "$label: no $what after the restart (read '${after:-<empty>}')"; return 1; }
  [[ "$before" != "$after" ]] || { fail "$label: $what is still host pid $after"; return 1; }
  pass "$label: $what went from host pid $before to $after"
}

# check the crash buffer read completed and holds no fatal line
assert_crash_buffer_clean() {
  local label="$1" out="$2" n
  [[ "$out" == *RHIZO_CRASH_DONE* ]] || { fail "$label: the crash buffer read never finished (got '${out:0:120}')"; return 1; }
  n=$(grep -cE 'Fatal signal|FATAL EXCEPTION' <<<"$out")
  (( n == 0 )) || { fail "$label: the crash buffer holds $n fatal line(s): $(grep -m2 -E 'Fatal signal|FATAL EXCEPTION|>>> ' <<<"$out" | tr '\n' ' ')"; return 1; }
  pass "$label: the crash buffer holds no fatal line"
}

# check a kernel log for the software launch and no graphics denials
assert_no_graphics_denials() {
  local label="$1" log="$2" exe buf sup
  [[ "$log" == *RHIZO_AVC_DONE* ]] || { fail "$label: the denial source read never finished"; return 1; }
  grep -qaF "RHIZO_MARKER gpu_mode=software" <<<"$log" \
    || { fail "$label: the denial source does not reach back to this boot's launch (no gpu_mode=software line)"; return 1; }
  sup=$(grep -caE 'kauditd_printk_skb: [0-9]+ callbacks suppressed|audit: (rate|backlog) limit exceeded|audit_lost=[1-9]' <<<"$log")
  (( sup == 0 )) || { fail "$label: the kernel suppressed audit lines $sup time(s)"; return 1; }
  exe=$(grep -aE 'avc: +denied +\{ execmem \}' <<<"$log")
  [[ -z "$exe" ]] || { fail "$label: $(grep -c . <<<"$exe") execmem denial(s), first: $(head -1 <<<"$exe")"; return 1; }
  buf=$(grep -aE 'avc: +denied .*rhizo_graphics_buffer' <<<"$log")
  [[ -z "$buf" ]] || { fail "$label: $(grep -c . <<<"$buf") rhizo_graphics_buffer denial(s), first: $(head -1 <<<"$buf")"; return 1; }
  pass "$label: no execmem and no rhizo_graphics_buffer denial since the launch, and no audit line suppressed"
}

# check dumpsys power's wakefulness is the one wanted
assert_wakefulness() {
  local label="$1" got="${2//[[:space:]]/}" want="$3"
  [[ "$got" == "$want" ]] || { fail "$label: mWakefulness=${got:-<unread>}, wanted $want"; return 1; }
  pass "$label: mWakefulness=$want"
}

# check the secure app's window carries FLAG_SECURE
assert_secure_window() {
  local label="$1" dump="$2"
  if awk -v pkg="$SECURE_PKG/" '
      /^ *Window #[0-9]+ Window\{/ { inwin = index($0, pkg) > 0; next }
      inwin && /^ *fl=/ && / SECURE( |$)|fl=SECURE( |$)/ { found = 1 }
      END { exit found ? 0 : 1 }' <<<"$dump"; then
    pass "$label: $SECURE_PKG's window carries FLAG_SECURE"
  else
    fail "$label: no window of $SECURE_PKG carries FLAG_SECURE in dumpsys window windows"
  fi
}

# check an app's gfxinfo counts a frame drawn through gl
assert_frames() {
  local label="$1" pkg="$2" gfx="$3" n
  n=$(sed -n 's/^Total frames rendered: \([0-9]*\).*/\1/p' <<<"$gfx" | head -1)
  [[ "$n" =~ ^[0-9]+$ ]] || { fail "$label: dumpsys gfxinfo $pkg has no 'Total frames rendered' line"; return 1; }
  (( n > 0 )) || { fail "$label: $pkg rendered no frame"; return 1; }
  grep -q 'Pipeline=Skia (OpenGL)' <<<"$gfx" \
    || { fail "$label: $pkg did not draw through Skia's gl pipeline ($(grep -m1 -o 'Pipeline=[^ ]*' <<<"$gfx"))"; return 1; }
  pass "$label: $pkg rendered $n frame(s) through Skia (OpenGL)"
}

# check the top resumed activity belongs to a package
assert_top_package() {
  local label="$1" pkg="$2" act="$3" top
  top=$(grep -m1 -E 'topResumedActivity=|ResumedActivity:' <<<"$act")
  [[ -n "$top" ]] || { fail "$label: dumpsys activity names no resumed activity"; return 1; }
  [[ "$top" == *" $pkg/"* ]] || { fail "$label: the resumed activity is not $pkg's: ${top## }"; return 1; }
  pass "$label: $pkg is in front"
}

# check pm install named the secure app
assert_installed() {
  local label="$1" out="$2"
  grep -q "^RHIZO_APP installed=$SECURE_PKG " <<<"$out" \
    || { fail "$label: rhizo app install did not report installed=$SECURE_PKG (last line: $(tail -1 <<<"$out"))"; return 1; }
  pass "$label: $SECURE_PKG installed"
}

# check a launch in the other mode was refused by name
assert_refused() {
  local label="$1" text="$2"
  grep -qaF "$REFUSED_MARKER" <<<"$text" \
    || { fail "$label: no '$REFUSED_MARKER' line in the kernel log, journal or supervisor log since the restart"; return 1; }
  pass "$label: the start was refused with gpu_driver_refused=policy-reload-needed"
}

# check no Android init runs
assert_no_init() {
  local label="$1" pid="${2//[[:space:]]/}"
  [[ -z "$pid" ]] || { fail "$label: an Android init runs (pid $pid) after a refused start"; return 1; }
  pass "$label: no Android init runs"
}

# check the sandbox's boot completed after a kernel-clock mark
assert_booted_since() {
  local label="$1" text="$2"
  [[ -n "$text" ]] || { fail "$label: no '$BOOTED_MARKER' line after the restart's mark"; return 1; }
  pass "$label: $BOOTED_MARKER after the restart"
}

# check the screen settings read gave a number for each
assert_settings_read() {
  local label="$1" text="$2" stay timeout
  stay=$(sed -n 's/^stay=//p' <<<"$text"); timeout=$(sed -n 's/^timeout=//p' <<<"$text")
  [[ "$stay" =~ ^[0-9]+$ && "$timeout" =~ ^[0-9]+$ ]] \
    || { fail "$label: stay_on_while_plugged_in read '${stay:-<nothing>}' and screen_off_timeout '${timeout:-<nothing>}', not two numbers"; return 1; }
  pass "$label: stay_on_while_plugged_in=$stay screen_off_timeout=$timeout, kept for the cleanup"
}

# check the cleanup sets devices.dri off with guest-policy-dri.py
assert_cleanup_writes_key() {
  local label="$1" trace="$2"
  grep -qF 'python3 - off /etc/rhizo/policy.conf' <<<"$trace" \
    || { fail "$label: the cleanup never sets devices.dri off with guest-policy-dri.py"; return 1; }
  ! grep -q 'rhizo gpu' <<<"$trace" \
    || { fail "$label: the cleanup runs rhizo gpu: $(grep -m1 'rhizo gpu' <<<"$trace")"; return 1; }
  pass "$label: the cleanup sets devices.dri off with guest-policy-dri.py and never runs rhizo gpu"
}

if (( SELFTEST )); then
  step "selftest: every assertion must be able to fail, by name"
  FAILLOG_SNAPSHOT="$TEST_WORKDIR/failures.log.snapshot"
  check_fails() {
    local what="$1" fn="$2"; shift 2
    local before=$FAILED
    cp "$EV/failures.log" "$FAILLOG_SNAPSHOT" 2>/dev/null || : > "$FAILLOG_SNAPSHOT"
    "$fn" "$@" >/dev/null 2>&1
    if (( FAILED > before )); then
      log "  selftest OK: $what"
      FAILED=$before
      cp "$FAILLOG_SNAPSHOT" "$EV/failures.log"
    else
      fail "selftest: $what did NOT fail"
    fi
  }
  check_passes() {
    local what="$1" fn="$2"; shift 2
    local before=$FAILED
    "$fn" "$@" >/dev/null 2>&1
    if (( FAILED > before )); then fail "selftest: $what fired on a genuinely good input"; else log "  selftest OK: $what"; fi
  }

  DM_GOOD='[   11.01] L3: RHIZO_MARKER gpu_mode=software driver=gpu_driver_software
[   11.10] L3: devices.dri off: rhizo-policy-software.cil joins the policy (execmem for llvmpipe'"'"'s jit)
[   17.10] L3: RHIZO_MARKER policy_dri=off
[   18.37] L3: RHIZO_MARKER software_rro=staged (no screen-off fade, no gl in system_server)
[   19.93] rhizo-graphics-allocator: memfd buffers (RHIZO_ALLOCATOR=memfd), no render node opened'
  check_passes "a software boot's markers are accepted" assert_boot_markers x "$DM_GOOD"
  check_fails "a boot that never logged gpu_mode=software is caught" assert_boot_markers x "${DM_GOOD//gpu_mode=software/gpu_mode=gpu}"
  check_fails "a boot whose policy was recorded for dri on is caught" assert_boot_markers x "${DM_GOOD//policy_dri=off/policy_dri=on}"
  check_fails "a boot that staged no software overlay is caught" assert_boot_markers x "${DM_GOOD//software_rro=staged/software_rro=absent}"
  check_fails "an allocator that opened a render node is caught" assert_boot_markers x "${DM_GOOD//memfd buffers/dmabuf buffers}"
  check_fails "a boot that also resolved a render node is caught" assert_boot_markers x "$DM_GOOD"$'\n[   9.0] L3: dri_source=ok node=/dev/dri/renderD128'
  check_fails "a boot that logged a refusal is caught" assert_boot_markers x "$DM_GOOD"$'\n[   9.0] L3: RHIZO_MARKER gpu_driver_refused=no-render-node'

  check_passes "a guest with no /dev/dri and no render node is accepted" assert_no_guest_dri x $'dev_dri=absent\nrender_nodes=0\nRHIZO_DRI_DONE'
  check_fails "a guest with /dev/dri is caught" assert_no_guest_dri x $'dev_dri=present renderD128\nrender_nodes=1\nRHIZO_DRI_DONE'
  check_fails "a guest whose sysfs lists a render node is caught" assert_no_guest_dri x $'dev_dri=absent\nrender_nodes=1\nRHIZO_DRI_DONE'
  check_fails "a read that never finished is caught" assert_no_guest_dri x "dev_dri=absent"

  check_passes "an enforcing guest is accepted" assert_enforcing x 1
  check_fails "a permissive guest is caught" assert_enforcing x 0
  check_fails "an unread enforce node is caught" assert_enforcing x ""

  check_passes "rhizo gpu's software line is accepted" assert_cli_line x $'[rhizo] note\nRHIZO_GPU dri=off driver=gpu_driver_software' "$SOFTWARE_LINE"
  check_fails "rhizo gpu naming the gpu set is caught" assert_cli_line x "RHIZO_GPU dri=on driver=gpu_driver" "$SOFTWARE_LINE"
  check_fails "rhizo gpu printing nothing is caught" assert_cli_line x "" "$SOFTWARE_LINE"
  check_fails "a loaded mode the line did not expect is caught" assert_cli_line x "$SOFTWARE_LINE loaded=on" "$SOFTWARE_LINE"

  SF_GOOD=$'RE GLES (Ganesh)\nGLES: Mesa, llvmpipe (LLVM 18.1.8, 256 bits), OpenGL ES 3.2 Mesa 25.2.8\n'
  check_passes "SurfaceFlinger on llvmpipe is accepted" assert_gles_llvmpipe x "$SF_GOOD"
  check_fails "SurfaceFlinger on virgl is caught" assert_gles_llvmpipe x $'RE GLES (Ganesh) llvmpipe\nGLES: Mesa, virgl (AMD Radeon RX 9060 XT), OpenGL ES 3.2'
  check_fails "a dump with only the RE GLES header is caught" assert_gles_llvmpipe x $'RE GLES (Ganesh) llvmpipe\n'

  check_passes "the enabled software overlay is accepted" assert_overlay_enabled x $'android\n[x] com.rhizo.overlay.boot\n[x] com.rhizo.overlay.software\n[ ] android.gsi.overlay'
  check_fails "a disabled software overlay is caught" assert_overlay_enabled x $'android\n[x] com.rhizo.overlay.boot\n[ ] com.rhizo.overlay.software'
  check_fails "an absent software overlay is caught" assert_overlay_enabled x $'android\n[x] com.rhizo.overlay.boot'

  check_passes "ro.config.avoid_gfx_accel=true is accepted" assert_avoid_gfx_accel x true
  check_fails "an unset ro.config.avoid_gfx_accel is caught" assert_avoid_gfx_accel x ""

  check_passes "the fade off on every display is accepted" assert_colorfade_off x $'  mColorFadeEnabled=false\n  mColorFadeEnabled=false'
  check_fails "a display with the fade on is caught" assert_colorfade_off x $'  mColorFadeEnabled=false\n  mColorFadeEnabled=true'
  check_fails "a dump with no fade line is caught" assert_colorfade_off x "Display Power Controller:"

  check_passes "a pid kept across a leg is accepted" assert_pid_kept x system_server 251 251
  check_fails "a restarted system_server is caught" assert_pid_kept x system_server 251 4079
  check_fails "a system_server gone after the leg is caught" assert_pid_kept x system_server 251 ""
  check_passes "a restarted surfaceflinger is accepted" assert_pid_changed x surfaceflinger 4302 20132
  check_fails "a surfaceflinger never restarted is caught" assert_pid_changed x surfaceflinger 4302 4302
  check_fails "no surfaceflinger after the restart is caught" assert_pid_changed x surfaceflinger 4302 ""

  check_passes "an empty crash buffer is accepted" assert_crash_buffer_clean x $'--------- beginning of crash\nRHIZO_CRASH_DONE'
  check_fails "a system_server crash is caught" assert_crash_buffer_clean x $'F libc    : Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR) in tid 297 (PowerManagerSer)\nRHIZO_CRASH_DONE'
  check_fails "a java crash is caught" assert_crash_buffer_clean x $'E AndroidRuntime: FATAL EXCEPTION: main\nRHIZO_CRASH_DONE'
  check_fails "an unfinished crash read is caught" assert_crash_buffer_clean x ""

  AVC_GOOD=$'[   11.0] L3: RHIZO_MARKER gpu_mode=software driver=gpu_driver_software\n[  40.0] audit: type=1400 avc:  denied  { getopt } for comm="FinalizerDaemon" scontext=u:r:priv_app:s0 permissive=0\nRHIZO_AVC_DONE'
  check_passes "a launch with only unrelated denials is accepted" assert_no_graphics_denials x "$AVC_GOOD"
  check_fails "an execmem denial is caught" assert_no_graphics_denials x \
    "$AVC_GOOD"$'\n[  62.0] audit: type=1400 avc:  denied  { execmem } for  pid=255 comm="PowerManagerSer" scontext=u:r:system_server:s0 tcontext=u:r:system_server:s0 tclass=process permissive=0'
  check_fails "a rhizo_graphics_buffer denial is caught" assert_no_graphics_denials x \
    "$AVC_GOOD"$'\n[  63.0] audit: type=1400 avc:  denied  { map } for comm="RenderThread" tcontext=u:object_r:rhizo_graphics_buffer:s0 tclass=file permissive=0'
  check_fails "suppressed audit lines are caught as the scan's own premise" assert_no_graphics_denials x \
    "$AVC_GOOD"$'\n[  64.0] kauditd_printk_skb: 14 callbacks suppressed'
  check_fails "a source that does not reach back to the launch is caught" assert_no_graphics_denials x $'[ 900.0] something\nRHIZO_AVC_DONE'
  check_fails "an unfinished denial read is caught" assert_no_graphics_denials x "${AVC_GOOD%RHIZO_AVC_DONE}"

  check_passes "an asleep screen is accepted when asleep is wanted" assert_wakefulness x Asleep Asleep
  check_fails "an awake screen is caught when asleep is wanted" assert_wakefulness x Awake Asleep
  check_fails "an unread wakefulness is caught" assert_wakefulness x "" Awake

  WIN_GOOD='  Window #6 Window{d3a7737 u0 com.rhizo.secureapp/com.rhizo.secureapp.MainActivity}:
    mDisplayId=0 rootTaskId=9
      fl=LAYOUT_IN_SCREEN SECURE LAYOUT_INSET_DECOR SPLIT_TOUCH HARDWARE_ACCELERATED DRAWS_SYSTEM_BAR_BACKGROUNDS
  Window #7 Window{aa u0 com.rhizo.home/com.rhizo.home.HomeActivity}:
      fl=LAYOUT_IN_SCREEN'
  check_passes "a secure window is accepted" assert_secure_window x "$WIN_GOOD"
  check_fails "the app's window without FLAG_SECURE is caught" assert_secure_window x "${WIN_GOOD// SECURE / }"
  check_fails "FLAG_SECURE on another app's window is caught" assert_secure_window x \
    $'  Window #6 Window{d u0 com.rhizo.secureapp/com.rhizo.secureapp.MainActivity}:\n      fl=LAYOUT_IN_SCREEN\n  Window #7 Window{a u0 com.rhizo.home/com.rhizo.home.HomeActivity}:\n      fl=SECURE'
  check_fails "a secure flag on a pfl= line is not taken for fl=" assert_secure_window x \
    $'  Window #6 Window{d u0 com.rhizo.secureapp/com.rhizo.secureapp.MainActivity}:\n      pfl=SECURE\n      fl=LAYOUT_IN_SCREEN'

  GFX_GOOD=$'Total frames rendered: 16\nPipeline=Skia (OpenGL)'
  check_passes "frames drawn through gl are accepted" assert_frames x "$CAL_PKG" "$GFX_GOOD"
  check_fails "no frame rendered is caught" assert_frames x "$CAL_PKG" $'Total frames rendered: 0\nPipeline=Skia (OpenGL)'
  check_fails "an app not running is caught" assert_frames x "$CAL_PKG" "No process found for: com.android.calendar"
  check_fails "frames drawn through a pipeline other than Skia's gl are caught" assert_frames x "$CAL_PKG" $'Total frames rendered: 16\nPipeline=Skia (Vulkan)'

  check_passes "the package in front is accepted" assert_top_package x "$CAL_PKG" \
    "  topResumedActivity=ActivityRecord{25829590 u0 com.android.calendar/.AllInOneActivity t10}"
  check_fails "another package in front is caught" assert_top_package x "$CAL_PKG" \
    "  topResumedActivity=ActivityRecord{189239768 u0 com.rhizo.secureapp/.MainActivity t9}"
  check_fails "no resumed activity is caught" assert_top_package x "$CAL_PKG" "ACTIVITY MANAGER ACTIVITIES"

  check_passes "an installed secure app is accepted" assert_installed x "RHIZO_APP installed=$SECURE_PKG label=U2VjdXJl"
  check_fails "a failed install is caught" assert_installed x "RHIZO_FAIL pm install did not print a literal Success line"

  check_passes "a refused start is accepted" assert_refused x "[ 120.0] L3: $REFUSED_MARKER (devices.dri is on, but the policy loaded this host boot is for dri = off; reboot)"
  check_fails "a start that was not refused is caught" assert_refused x "[ 120.0] L3: RHIZO_MARKER gpu_mode=gpu driver=gpu_driver"
  check_passes "no init after a refusal is accepted" assert_no_init x ""
  check_fails "an init after a refusal is caught" assert_no_init x 4242
  check_passes "a boot completed after the mark is accepted" assert_booted_since x "[ 200.0] $BOOTED_MARKER"
  check_fails "no boot completed after the mark is caught" assert_booted_since x ""

  check_passes "two numbered screen settings are accepted" assert_settings_read x $'stay=0\ntimeout=60000'
  check_fails "a settings read that returned nothing is caught" assert_settings_read x ""
  check_fails "a setting read back as null is caught" assert_settings_read x $'stay=null\ntimeout=60000'
  check_fails "a timeout read that never came is caught" assert_settings_read x "stay=0"

  cleanup_trace() {
    local trace="$TEST_WORKDIR/cleanup-trace"
    : > "$trace"
    ( TEST_NO_VM=0; EV="$TEST_WORKDIR/cleanup-ev"; mkdir -p "$EV"
      ssh_vm() { [[ "$1" == -t ]] && shift 2; echo "ssh $*" >>"$trace"; [[ "$*" == *RHIZO_CLEANUP_READ* ]] && printf 'off\nRHIZO_CLEANUP_READ\n'; return 0; }
      guest_init_pid() { :; }
      android_sh() { echo "android $2" >>"$trace"; }
      log() { :; }
      "${1:-software_render_cleanup}" ) </dev/null >/dev/null 2>&1
    cat "$trace"
  }
  check_passes "the cleanup sets the key with guest-policy-dri.py" assert_cleanup_writes_key x "$(cleanup_trace)"
  eval "$(declare -f software_render_cleanup | sed '1s/software_render_cleanup/cleanup_with_rhizo_gpu/; s#python3 - off /etc/rhizo/policy.conf#rhizo gpu off#')"
  check_fails "a cleanup that runs rhizo gpu off is caught" assert_cleanup_writes_key x "$(cleanup_trace cleanup_with_rhizo_gpu)"

  if (( FAILED )); then
    log "test-software-render --selftest: FAILED"
    exit 1
  fi
  log "test-software-render --selftest: every assertion fails by name on a broken fixture and passes the good one"
  exit 0
fi


GR_OUT="" GR_RC=0
# run a guest command and keep its output in the evidence
guest_read() {
  local name="$1" tmo="$2" err; shift 2
  err=$(mktemp)
  GR_OUT=$(ssh_vm -t "$tmo" "$@" 2>"$err"); GR_RC=$?
  local retried=""
  if (( GR_RC == 255 )); then
    sleep 2
    GR_OUT=$(ssh_vm -t "$tmo" "$@" 2>>"$err"); GR_RC=$?; retried=" retried=1"
  fi
  printf 'rc=%d%s\n%s\nstderr: %s\n' "$GR_RC" "$retried" "${GR_OUT:-<none>}" "$(tr '\n' ' ' <"$err")" >"$EV/$name"
  rm -f "$err"
}

AO="" AO_RC=0
# run an Android command and keep its output in the evidence
android_read() {
  local name="$1" body="$2"
  AO=$(android_sh "$INIT" "$body"); AO_RC=$?
  printf 'rc=%d\n%s\n' "$AO_RC" "${AO:-<none>}" >"$EV/$name"
}

# print the kernel's uptime in seconds
kernel_clock() {
  ssh_vm -t 10 'cut -d" " -f1 /proc/uptime' 2>/dev/null | tr -dc '0-9.'
}

# print the dmesg lines past a kernel-clock mark
dmesg_since() {
  awk -v m="$1" '
    match($0, /^\[[ ]*[0-9]+\.[0-9]+\]/) {
      t = substr($0, RSTART + 1, RLENGTH - 2) + 0
      if (t > m) print
    }' <<<"$2"
}

# print surfaceflinger's host pid
surfaceflinger_host_pid() {
  ssh_vm -t 15 'for p in /proc/[0-9]*; do [ "$(cat $p/comm 2>/dev/null)" = surfaceflinger ] && { echo ${p#/proc/}; break; }; done' 2>/dev/null | tr -dc '0-9'
}

# read the whole-boot denial source into evidence
read_denials() {
  guest_read "$1" 40 "if [ -s $AVC_LOG ]; then cat $AVC_LOG.1 $AVC_LOG 2>/dev/null; else dmesg; fi; echo RHIZO_AVC_DONE"
}

# read the crash buffer into evidence
read_crash_buffer() {
  android_read "$1" 'logcat -b crash -d; echo RHIZO_CRASH_DONE'
}

# read system_server's and surfaceflinger's pids into SS and SF
read_pids() {
  android_read "$1-system_server.txt" 'pidof system_server'; SS="${AO//[[:space:]]/}"
  android_read "$1-surfaceflinger.txt" 'pidof surfaceflinger'; SF="${AO//[[:space:]]/}"
}

# poll dumpsys power for the wanted wakefulness
wait_wakefulness() {
  local want="$1" deadline=$(( SECONDS + $2 ))
  WAKE=""
  while :; do
    WAKE=$(android_sh "$INIT" 'dumpsys power | grep -m1 mWakefulness=' | sed -n 's/.*mWakefulness=//p' | tr -d '[:space:]')
    [[ "$WAKE" == "$want" || $SECONDS -ge $deadline ]] && break
    sleep 3
  done
}

# poll the kernel log for the sandbox's boot completion
wait_booted_since() {
  local mark="$1" deadline=$(( SECONDS + $2 ))
  BOOTED=""
  while :; do
    BOOTED=$(dmesg_since "$mark" "$(ssh_vm -t 20 'dmesg' 2>/dev/null)" | grep -aF "$BOOTED_MARKER" | tail -1)
    [[ -n "$BOOTED" || $SECONDS -ge $deadline ]] && break
    sleep 3
  done
}

EV_NAMES=(redeploy.log dmesg-boot.txt dri.txt enforce-boot.txt gpu-show-boot.txt sf-boot.txt overlay-list.txt \
    avoid-gfx-accel.txt display.txt crash-soak.txt avc-soak.txt gpu-on.txt gpu-show-on.txt restart-refused.log \
    refusal.txt gpu-off.txt restart-software.log sf-restart.txt crash-restart.txt avc-restart.txt settings-before.txt \
    crash-screen.txt avc-screen.txt secure-install.txt secure-start.txt secure-window.txt secure-gfxinfo.txt \
    calendar-start.txt calendar-top.txt calendar-gfxinfo.txt home-top.txt crash-secure.txt avc-secure.txt \
    prepared-before.txt cleanup.txt enforce-restart.txt)
for _tag in t0 t60 screen-start screen-end secure-start secure-end; do
  EV_NAMES+=("$_tag-system_server.txt" "$_tag-surfaceflinger.txt")
done
for _ev_name in "${EV_NAMES[@]}"; do
  printf '%s\n' "<none: this run did not reach the step that writes $_ev_name>" >"$EV/$_ev_name"
done
unset _ev_name _tag


step "0. boot a vm with no gpu device and launch Android through androidd.service with devices.dri off"
export RHIZO_VM_GPU=off RHIZO_USE_UNIT=1
test_boot --skip-graphics-preflight || { fail "0. boot failed"; test_record_verdict FAILED; exit 1; }
../../vm/sync.sh >/dev/null || { fail "0. sync.sh failed"; test_record_verdict FAILED; exit 1; }
guest_read prepared-before.txt 10 "rm -f $PREPARED_BACKUP; [ -s /var/lib/rhizo/.prepared ] && cp -p /var/lib/rhizo/.prepared $PREPARED_BACKUP; cat /var/lib/rhizo/.prepared 2>/dev/null; [ -e /run/reboot-required ] && echo reboot_flag=present || echo reboot_flag=absent"
REBOOT_FLAG_BEFORE=$(sed -n 's/^reboot_flag=//p' <<<"$GR_OUT")
# shellcheck disable=SC2034
TEST_EXTRA_CLEANUP=software_render_cleanup
if ! ../../vm/redeploy.sh --skip-kill --boot-wait 180 >"$EV/redeploy.log" 2>&1; then
  grep -q STAGED_OK "$EV/redeploy.log" || log "    redeploy.sh never printed STAGED_OK"
  fail "0. redeploy.sh did not bring Android up with devices.dri off -- see $EV/redeploy.log"
  "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV" "software-render-boot-fail"
  test_record_verdict FAILED
  exit 1
fi
INIT=$(guest_init_pid 15)
[[ -n "$INIT" ]] || { fail "0. redeploy.sh reported a boot but no Android init runs"; test_record_verdict FAILED; exit 1; }
pass "0. Android booted (init pid $INIT)"

step "1. the launch's markers, no gpu device, enforcement, and rhizo gpu"
guest_read dmesg-boot.txt 40 'dmesg'
assert_boot_markers "1a. this boot's kernel log" "$GR_OUT"
guest_read dri.txt 15 "if [ -e /dev/dri ]; then echo \"dev_dri=present \$(ls /dev/dri | tr '\n' ' ')\"; else echo dev_dri=absent; fi; echo \"render_nodes=\$(ls /sys/class/drm 2>/dev/null | grep -c '^renderD')\"; echo RHIZO_DRI_DONE"
assert_no_guest_dri "1b. the guest's devices" "$GR_OUT"
guest_read enforce-boot.txt 10 'cat /sys/fs/selinux/enforce'
assert_enforcing "1c. after the boot" "$GR_OUT"
guest_read gpu-show-boot.txt 30 'rhizo gpu'
assert_cli_line "1d. the guest's packaged rhizo gpu" "$GR_OUT" "$SOFTWARE_LINE"

step "2. SurfaceFlinger on llvmpipe, the software overlay, ro.config.avoid_gfx_accel and no screen-off fade"
android_read sf-boot.txt 'dumpsys SurfaceFlinger'
assert_gles_llvmpipe "2a. SurfaceFlinger's renderer" "$AO"
android_read overlay-list.txt 'cmd overlay list android'
assert_overlay_enabled "2b. the framework overlays" "$AO"
android_read avoid-gfx-accel.txt 'getprop ro.config.avoid_gfx_accel'
assert_avoid_gfx_accel "2c. system_server's hwui switch" "$AO"
android_read display.txt 'dumpsys display'
assert_colorfade_off "2d. the screen-off fade" "$AO"
SF_HOST_BOOT=$(surfaceflinger_host_pid)

step "3. 60 s under enforcement: no restart, no crash, no execmem or rhizo_graphics_buffer denial"
read_pids t0; SS0=$SS; SF0=$SF
sleep 60
read_pids t60
assert_pid_kept "3a. over 60 s" system_server "$SS0" "$SS"
assert_pid_kept "3b. over 60 s" surfaceflinger "$SF0" "$SF"
read_crash_buffer crash-soak.txt
assert_crash_buffer_clean "3c. after 60 s" "$AO"
read_denials avc-soak.txt
assert_no_graphics_denials "3d. after 60 s" "$GR_OUT"

step "4. rhizo gpu on: a reboot is asked for and a start is refused; rhizo gpu off: the sandbox restarts onto llvmpipe under enforcement"
guest_read gpu-on.txt 120 'rhizo gpu on'
assert_cli_line "4a. rhizo gpu on under the software policy" "$GR_OUT" "RHIZO_GPU_REBOOT_REQUIRED=1 dri=on loaded=off"
guest_read gpu-show-on.txt 30 'rhizo gpu'
assert_cli_line "4b. rhizo gpu after the switch" "$GR_OUT" "RHIZO_GPU dri=on driver=gpu_driver loaded=off"
MARK=$(kernel_clock)
SUP_MARK=$(ssh_vm -t 10 "stat -c %s $SUPERVISOR_LOG 2>/dev/null || echo 0" 2>/dev/null | tr -dc '0-9')
WALL_MARK=$(ssh_vm -t 10 'date +%s' 2>/dev/null | tr -dc '0-9')
guest_read restart-refused.log 300 'systemctl restart androidd.service; echo rc=$?'
REFUSAL=""
deadline=$(( SECONDS + 90 ))
while :; do
  REFUSAL=$( { dmesg_since "${MARK:-0}" "$(ssh_vm -t 20 'dmesg' 2>/dev/null)"
               ssh_vm -t 20 "journalctl -u androidd.service --since @${WALL_MARK:-0} -o cat --no-pager 2>/dev/null; tail -c +$(( ${SUP_MARK:-0} + 1 )) $SUPERVISOR_LOG 2>/dev/null" 2>/dev/null
             } | grep -aF "$REFUSED_MARKER" | tail -1)
  [[ -n "$REFUSAL" || $SECONDS -ge $deadline ]] && break
  sleep 3
done
printf '%s\n' "${REFUSAL:-<none>}" >"$EV/refusal.txt"
assert_refused "4c. a start with dri on under the software policy" "$REFUSAL"
assert_no_init "4d. after the refused start" "$(guest_init_pid 15)"
guest_read gpu-off.txt 120 'rhizo gpu off'
assert_cli_line "4e. rhizo gpu off under the software policy" "$GR_OUT" "$SOFTWARE_LINE"
guest_read enforce-restart.txt 10 'cat /sys/fs/selinux/enforce'
assert_enforcing "4f. before the software restart" "$GR_OUT"
MARK=$(kernel_clock)
guest_read restart-software.log 300 'systemctl restart androidd.service; echo rc=$?'
wait_booted_since "${MARK:-0}" 240
assert_booted_since "4g. the sandbox restarted in software mode" "$BOOTED"
INIT=$(guest_init_pid 15)
assert_pid_changed "4h. across the restarts" surfaceflinger "$SF_HOST_BOOT" "$(surfaceflinger_host_pid)"
android_read sf-restart.txt 'dumpsys SurfaceFlinger'
assert_gles_llvmpipe "4i. SurfaceFlinger restarted under enforcement" "$AO"
read_crash_buffer crash-restart.txt
assert_crash_buffer_clean "4j. after the restart" "$AO"
read_denials avc-restart.txt
assert_no_graphics_denials "4k. after the restart" "$GR_OUT"

step "5. with stay-on cleared and a 60 s timeout, the screen goes off and wakes twice with no restart, crash or denial"
android_read settings-before.txt 'echo stay=$(settings get global stay_on_while_plugged_in); echo timeout=$(settings get system screen_off_timeout)'
SETTINGS_OK=0
if assert_settings_read "5a. the screen settings before the leg" "$AO"; then
  SETTINGS_BEFORE="$AO" SETTINGS_OK=1
  android_sh "$INIT" 'settings put global stay_on_while_plugged_in 0; settings put system screen_off_timeout 60000; svc power stayon false; input keyevent 224' >/dev/null 2>&1
  read_pids screen-start; SS0=$SS; SF0=$SF
  for cycle in 1 2; do
    wait_wakefulness Asleep 120
    assert_wakefulness "5.$cycle a. the screen timed out" "$WAKE" Asleep
    android_sh "$INIT" 'input keyevent 224' >/dev/null 2>&1
    wait_wakefulness Awake 30
    assert_wakefulness "5.$cycle b. the screen woke" "$WAKE" Awake
  done
  read_pids screen-end
  assert_pid_kept "5c. across the screen-off cycles" system_server "$SS0" "$SS"
  assert_pid_kept "5d. across the screen-off cycles" surfaceflinger "$SF0" "$SF"
  read_crash_buffer crash-screen.txt
  assert_crash_buffer_clean "5e. after the screen-off cycles" "$AO"
  read_denials avc-screen.txt
  assert_no_graphics_denials "5f. after the screen-off cycles" "$GR_OUT"
fi

step "6. a FLAG_SECURE app is left for Calendar, HOME and the recents key with no restart, crash or denial"
if (( SETTINGS_OK )); then
  android_sh "$INIT" 'settings put system screen_off_timeout 1800000; input keyevent 224' >/dev/null 2>&1
else
  android_sh "$INIT" 'input keyevent 224' >/dev/null 2>&1
fi
guest_read secure-install.txt 400 "rhizo app install /root/share/rhizo-secureapp.apk"
assert_installed "6a. rhizo app install" "$GR_OUT"
read_pids secure-start; SS0=$SS; SF0=$SF
ANDROID_SH_TIMEOUT=60 android_read secure-start.txt "am start -W -n $SECURE_ACT"
android_read secure-window.txt 'dumpsys window windows'
assert_secure_window "6b. the secure app's window" "$AO"
android_read secure-gfxinfo.txt "dumpsys gfxinfo $SECURE_PKG"
assert_frames "6c. the secure app" "$SECURE_PKG" "$AO"
ANDROID_SH_TIMEOUT=60 android_read calendar-start.txt "am start -W -n $CAL_ACT"
android_read calendar-top.txt 'dumpsys activity activities | grep -m1 -E "topResumedActivity=|ResumedActivity:"'
assert_top_package "6d. Calendar started over the secure app" "$CAL_PKG" "$AO"
android_read calendar-gfxinfo.txt "dumpsys gfxinfo $CAL_PKG"
assert_frames "6e. Calendar, an untrusted app" "$CAL_PKG" "$AO"
ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "am start -W -n $SECURE_ACT" >/dev/null 2>&1
android_sh "$INIT" 'input keyevent 3' >/dev/null 2>&1
sleep 2
android_read home-top.txt 'dumpsys activity activities | grep -m1 -E "topResumedActivity=|ResumedActivity:"'
assert_top_package "6f. HOME over the secure app" "$HOME_PKG" "$AO"
ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "am start -W -n $SECURE_ACT" >/dev/null 2>&1
android_sh "$INIT" 'input keyevent 187' >/dev/null 2>&1
sleep 2
read_pids secure-end
assert_pid_kept "6g. across the secure switches and the recents key" system_server "$SS0" "$SS"
assert_pid_kept "6h. across the secure switches and the recents key" surfaceflinger "$SF0" "$SF"
read_crash_buffer crash-secure.txt
assert_crash_buffer_clean "6i. after the secure switches and the recents key" "$AO"
read_denials avc-secure.txt
assert_no_graphics_denials "6j. after the secure switches" "$GR_OUT"

if (( FAILED )); then
  "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV" "software-render-fail"
  log "test-software-render: FAILED with $FAILED failure(s) -- evidence in $EV"
  test_record_verdict FAILED
  exit 1
fi
log "test-software-render: PASSED -- evidence in $EV"
test_record_verdict PASSED
exit 0
