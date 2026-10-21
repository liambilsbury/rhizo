#!/bin/bash
# test installing and removing the rhizo packages
# test-boot-mode: cold-required
# test-boots-unit: na
# test-records-metrics: no
# test-verdict-params: leg=base
# test-requires: deb:rhizo deb:rhizo-kernel prev-debs:rhizo vm-file:rhizo-keystoreprobe.apk vm-file:modules-extra.deb vm-dir:sway-debs vm-dir:runtime-debs pool-checked:runtime-debs vm-dir:adb-debs gsi:gsi_a16.zip
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

LEG=base
REUSE_DISK=0
THROUGH_BOOT=0
SELFTEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-contract) source ../../vm/common.sh; source ../lib/lib.sh
                       test_print_contract "${BASH_SOURCE[0]}"; exit $? ;;
    --reuse-disk) REUSE_DISK=1; shift ;;
    --through-boot) THROUGH_BOOT=1; shift ;;
    --instance) RHIZO_VM="$2"; export RHIZO_VM; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done
VERDICT_REDUCTION=""
UPGRADE_VERDICT_INFO=""
if (( REUSE_DISK )); then VERDICT_REDUCTION=" new_disk=0"; fi
if (( THROUGH_BOOT )); then VERDICT_REDUCTION="$VERDICT_REDUCTION through=boot"; fi

export RHIZO_BOOT=grub
source ../../vm/common.sh
source ../lib/lib.sh
if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then
  [[ "${RHIZO_DESKTOP_PROFILE:-plasma}" == plasma ]] \
    || { fail "a cachyos vm's installer leg runs under the plasma profile (got RHIZO_DESKTOP_PROFILE=$RHIZO_DESKTOP_PROFILE)"; exit 1; }
  export RHIZO_DESKTOP_PROFILE=plasma
  source ../lib/desktop-lib.sh || { fail "the plasma desktop profile is unavailable"; exit 1; }
else
  [[ "${RHIZO_DESKTOP_PROFILE:-sway}" == sway ]] \
    || { fail "this system test only runs under the sway desktop profile (got RHIZO_DESKTOP_PROFILE=$RHIZO_DESKTOP_PROFILE)"; exit 1; }
  source ../lib/sway-lib.sh
fi

if (( SELFTEST )); then
  EV=$(mktemp -d) || exit 1
  trap 'rm -rf "$EV"' EXIT
  FAILED=0
else
  test_init installer --teardown
fi

SETTLED_LINK_TARGET=""
# restore the worktree's settled-marker link
restore_settled_link() {
  [[ -n "$SETTLED_LINK_TARGET" ]] || return 0
  ln -sfn "$SETTLED_LINK_TARGET" "$VAR_DIR/settled$SUFFIX"
  note "restored the worktree's settled-marker link for vm ${RHIZO_VM:-0}"
}

SUMMARY="$(rig_result_path "$EV/summary.txt")"
: > "$SUMMARY"
# log a note and add it to the summary
note() { log "  $*"; echo "$*" >> "$SUMMARY"; }

source ../lib/installer-lib.sh
if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then
  # shellcheck source=../lib/installer-cachyos-lib.sh
  source ../lib/installer-cachyos-lib.sh
fi

REPO_ROOT="$(cd ../../.. && pwd)"
export RHIZO_SWAY_DEBS="$TEST_SWAY_DEBS"
DEB_DIR="${RHIZO_DEB_DIR:-$REPO_ROOT/var/debs}"
RHIZO_DEB=""
DEB_DIR_PREV="${RHIZO_DEB_DIR_PREV:-$REPO_ROOT/var/debs/prev}"
N1_PAIR_SOURCE="build N-1 from the last commit at debian/changelog's previous version: tools/build/packaging/deb/debs.sh --at <that commit> --out $DEB_DIR_PREV"
KERNEL_DEB_DIR="${RHIZO_KERNEL_DEB_DIR:-$DEB_DIR}"
KERNEL_DEBS=()
ADB="${RHIZO_ADB:-$HOME/Android/Sdk/platform-tools/adb}"
INSTALLER_DESKTOP_HUMAN=deskuser

# note the size and sha256 of a package
note_artifact() {
  note "artifact: $(basename "$1") $(du -h "$1" | cut -f1) sha256 $(sha256sum "$1" | cut -d' ' -f1)"
}

if (( ! SELFTEST )); then
step "0. the shippable artifact"
shopt -s nullglob
debs=("$DEB_DIR"/rhizo_*_amd64.deb)
shopt -u nullglob
if (( ${#debs[@]} == 0 )); then
  fail "no built package: rhizo_*.deb comes from dpkg-buildpackage -us -uc -b in this worktree (looked in $DEB_DIR)"
  restore_settled_link
  test_record_verdict FAILED "leg=$LEG$VERDICT_REDUCTION"
  exit 1
fi
EV_DEB_DIR="$EV/artifact"
rm -rf "$EV_DEB_DIR"
mkdir -p "$EV_DEB_DIR"
# print the mtime of the settings directory
_settings_dir_mtime_min() {
  ANDROID_SH_TIMEOUT=20 android_sh "$1" "toybox stat -c %y /data/system/users/0" | tr -d '\r\n'
}

_SETTINGS_MIN_PUT_GAP_MS=2500
# wait for the settings directory mtime to move and print it
await_settings_durable_min() {
  local init="$1" baseline="$2" last_put_ms="$3" deadline_s="${4:-10}" mtime moved=0 end_ms now_ms
  end_ms=$(( $(date +%s%N) / 1000000 + deadline_s * 1000 ))
  while :; do
    mtime=$(_settings_dir_mtime_min "$init")
    [[ -n "$mtime" && "$mtime" != "$baseline" ]] && moved=1
    now_ms=$(( $(date +%s%N) / 1000000 ))
    if (( moved )) && (( now_ms - last_put_ms >= _SETTINGS_MIN_PUT_GAP_MS )); then
      printf '%s' "$mtime"
      return 0
    fi
    (( now_ms < end_ms )) || break
    sleep 1
  done
  return 1
}

# print the .deb with the highest version
highest_version_deb() {
  local best="" best_ver="" f ver
  for f in "$@"; do
    ver=$(dpkg-deb -f "$f" Version 2>/dev/null)
    [[ -n "$ver" ]] || continue
    if [[ -z "$best" ]] || dpkg --compare-versions "$ver" gt "$best_ver"; then
      best="$f"; best_ver="$ver"
    fi
  done
  printf '%s' "$best"
}
# copy a .deb or fail the system test
cp_deb_or_fail() {
  cp -f "$1" "$2" || {
    fail "could not copy $(basename "$1") into $EV_DEB_DIR"
    restore_settled_link
    test_record_verdict FAILED "leg=$LEG$VERDICT_REDUCTION"
    exit 1
  }
}
cp_deb_or_fail "${debs[-1]}" "$EV_DEB_DIR/$(basename "${debs[-1]}")"
cp -f "${debs[-1]}.inputs" "$EV_DEB_DIR/$(basename "${debs[-1]}").inputs" 2>/dev/null || true
if [[ "${RHIZO_GUEST_OS:-ubuntu}" != cachyos ]]; then
  if ! kdebs=$(deb_pool_kernel_debs "${debs[-1]}" "$KERNEL_DEB_DIR"); then
    fail "$(basename "${debs[-1]}") depends on a Rhizo kernel .deb $KERNEL_DEB_DIR lacks (see above) -- tools/fetch/pools/deb/runtime-debs.sh --kernel-debs names the ones missing"
    restore_settled_link
    test_record_verdict FAILED "leg=$LEG$VERDICT_REDUCTION"
    exit 1
  fi
  for k in $kdebs; do
    cp_deb_or_fail "$k" "$EV_DEB_DIR/$(basename "$k")"
    KERNEL_DEBS+=("$EV_DEB_DIR/$(basename "$k")")
  done
fi
RHIZO_DEB="$EV_DEB_DIR/$(basename "${debs[-1]}")"
note_artifact "$RHIZO_DEB"
for k in "${KERNEL_DEBS[@]}"; do note_artifact "$k"; done
pass "the rhizo package present${KERNEL_DEBS[*]:+, with the ${#KERNEL_DEBS[@]} Rhizo kernel .debs the rhizo package depends on}"
why=$(python3 ../../../tools/build/stamps.py deb-require "$RHIZO_DEB" 2>&1)
why_rc=$?
if (( why_rc != 0 )); then
  fail "$(basename "$RHIZO_DEB") ${why#stamps: } -- rebuild it with tools/build/packaging/deb/debs.sh"
  restore_settled_link
  test_record_verdict FAILED "leg=$LEG$VERDICT_REDUCTION"
  exit 1
fi
deb_commit=$(awk -F'\t' '$1=="commit"{print $2}' "${RHIZO_DEB}.inputs" 2>/dev/null)
pass "$(basename "$RHIZO_DEB") tracked and untracked routed inputs unchanged since the build at ${deb_commit:-unknown}"
drift=$(python3 ../../checks/lib/package-tree.py "$RHIZO_DEB" "$REPO_ROOT" 2>&1)
drift_rc=$?
echo "$drift" > "$EV/package-tree-drift.txt"
if (( drift_rc == 0 )); then
  pass "$(tail -1 <<<"$drift")"
else
  fail "$(basename "$RHIZO_DEB") is not this tree's build (rc=$drift_rc, $(grep -c '^FAIL' <<<"$drift") finding(s), first: $(grep -m1 '^FAIL' <<<"$drift")) -- rebuild it with tools/build/packaging/deb/debs.sh; every finding is in $EV/package-tree-drift.txt"
  restore_settled_link
  test_record_verdict FAILED "leg=$LEG$VERDICT_REDUCTION"
  exit 1
fi
step "1. the artifact carries no trace of the rig path"
rig_hits=""
names=$(dpkg-deb -c "$RHIZO_DEB" | awk '{print $6}')
for bad in ../../vm/sync.sh ../../vm/redeploy.sh ../../vm/image/provision-pristine.sh run-vm.sh; do
  grep -q "/$bad\$" <<<"$names" && rig_hits="$rig_hits $(basename "$RHIZO_DEB"):$bad"
done
body=$(dpkg-deb --fsys-tarfile "$RHIZO_DEB" | tar -xO 2>/dev/null | tr -c '[:print:]\n' ' ')
for bad in 'trans=virtio' '9p2000.L' 'var/vm'; do
  grep -qF "$bad" <<<"$body" && rig_hits="$rig_hits $(basename "$RHIZO_DEB"):$bad"
done
if [[ -n "$rig_hits" ]]; then
  fail "the artifact references the rig path:$rig_hits"
else
  pass "no rig-path reference in any package"
fi
fi

FALLBACK_MARKERS='RhizoKeyMintDevice|rhizo_keymint\.cpp'
KEYSTORE_PROBE_APK="$SHARE_DIR/rhizo-keystoreprobe.apk"
KEYSTORE_PROBE_PKG=com.rhizo.keystoreprobe
TEST_PROBE_DIR=/var/tmp/rhizo-test-probe
TEST_ADB_DEBS=/var/lib/test-adb-debs
TEST_GUEST_ADB_HOME=/tmp/rhizo-test-adb
PAYLOAD_KEYMINT=/usr/lib/rhizo/rhizo-keymint-service

# check strings output for FALLBACK_MARKERS
assert_no_fallback_markers() {
  local label="$1" what="$2" text="$3"
  if grep -qE "$FALLBACK_MARKERS" <<<"$text"; then
    fail "[$label] $what is the AES-only fallback: its strings name $(grep -oE "$FALLBACK_MARKERS" <<<"$text" | sort -u | tr '\n' ' ')"
    return 1
  fi
  pass "[$label] $what carries none of the fallback's markers"
}

# check the packaged KeyMint binary and probe app
keymint_leg() {
  local leg="$1" init_pid="$2" t0="$3"
  step "$leg: the KeyMint the package ships is the one that runs, and it answers non-AES keys"

  local unpack deb_sha deb_size
  unpack=$(mktemp -d)
  if ! dpkg-deb --fsys-tarfile "$RHIZO_DEB" | tar -x -C "$unpack" ".$PAYLOAD_KEYMINT" 2>/dev/null \
     || [[ ! -f "$unpack$PAYLOAD_KEYMINT" ]]; then
    fail "[$leg] $(basename "$RHIZO_DEB") does not carry $PAYLOAD_KEYMINT"
    rm -rf "$unpack"; return 1
  fi
  deb_sha=$(sha256sum "$unpack$PAYLOAD_KEYMINT" | cut -d' ' -f1)
  deb_size=$(stat -c %s "$unpack$PAYLOAD_KEYMINT")
  note "[$leg] package keymint: sha256=$deb_sha size=$deb_size"
  echo "$deb_sha  $PAYLOAD_KEYMINT ($deb_size bytes, from $(basename "$RHIZO_DEB"))" > "$EV/$leg-keymint-sha.txt"
  assert_no_fallback_markers "$leg" "the package's rhizo-keymint-service" "$(strings "$unpack$PAYLOAD_KEYMINT")"
  rm -rf "$unpack"

  local guest_sha
  guest_sha=$(ssh_vm -t 60 "sha256sum $PAYLOAD_KEYMINT 2>/dev/null | cut -d' ' -f1" | tr -d '[:space:]')
  echo "$guest_sha  $PAYLOAD_KEYMINT (installed on the guest)" >> "$EV/$leg-keymint-sha.txt"
  if [[ "$guest_sha" == "$deb_sha" ]]; then
    pass "[$leg] the installed $PAYLOAD_KEYMINT is byte-identical to the package's"
  else
    fail "[$leg] the installed $PAYLOAD_KEYMINT (sha256=${guest_sha:-<unreadable>}) is not the package's ($deb_sha)"
  fi
  local km_marker launch_t
  launch_t=$(sandbox_marker_after 0 'RHIZO_MARKER launch_start sandbox=0' | awk '{print $1}')
  km_marker=$(sandbox_marker_after "${launch_t:-$t0}" 'rhizo-keymint-service (staged on|NOT FOUND)')
  echo "${km_marker:-<no marker>} (after launch_start ${launch_t:-<none, t0=$t0>})" >> "$EV/$leg-keymint-sha.txt"
  if [[ -z "$km_marker" ]]; then
    { echo "t0=$t0 launch_start=${launch_t:-<none>} -- this boot's staging, start and handoff lines:"
      ssh_vm -t 30 "dmesg 2>/dev/null | grep -a -E 'rhizo-keymint-service|is parked|launch_start|wayland socket|boot_completed'"
    } >> "$EV/$leg-keymint-sha.txt" 2>&1
  fi
  assert_keymint_staged "$leg" "$km_marker"
  local running
  running=$(android_sh "$init_pid" "ps -A -o NAME 2>/dev/null | grep -c '^rhizo-keymint-service\$'" | grep -oE '^[0-9]+' | head -1)
  if [[ "${running:-0}" -ge 1 ]]; then
    pass "[$leg] rhizo-keymint-service is running in the sandbox"
  else
    fail "[$leg] no rhizo-keymint-service process in the sandbox (ps counted ${running:-nothing})"
  fi

  if [[ ! -f "$KEYSTORE_PROBE_APK" ]]; then
    fail "[$leg] no $KEYSTORE_PROBE_APK -- run tools/build/test-apps/keystoreprobe.sh"
    return 1
  fi
  local desktop_user
  desktop_user=$(ssh_vm -t 30 'cat /etc/rhizo/desktop-user 2>/dev/null' | tr -d '[:space:]')
  if [[ -z "$desktop_user" ]]; then
    fail "[$leg] the install recorded no /etc/rhizo/desktop-user"
    return 1
  fi
  note "[$leg] desktop account: $desktop_user"
  ssh_vm -t 60 "mkdir -p $TEST_PROBE_DIR && chmod 0755 $TEST_PROBE_DIR" >/dev/null 2>&1
  timeout 300 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$KEYSTORE_PROBE_APK" "$SSH_TARGET:$TEST_PROBE_DIR/" \
    || { fail "[$leg] could not stage the keystore probe"; return 1; }
  ssh_vm -t 60 "chmod 0644 $TEST_PROBE_DIR/$(basename "$KEYSTORE_PROBE_APK")" >/dev/null 2>&1
  local install_out
  install_out=$(ssh_vm -t 600 "sudo -u $desktop_user -- /usr/bin/rhizo app install $TEST_PROBE_DIR/$(basename "$KEYSTORE_PROBE_APK") 2>&1; echo rc=\$?")
  printf '%s\n' "$install_out" > "$EV/$leg-keystore-probe-install.log"
  if grep -q "^RHIZO_APP installed=$KEYSTORE_PROBE_PKG " <<<"$install_out" && grep -qx 'rc=0' <<<"$install_out"; then
    pass "[$leg] rhizo app install put the probe in as $desktop_user through the broker"
  else
    fail "[$leg] rhizo app install as $desktop_user did not report the probe installed (see $EV/$leg-keystore-probe-install.log): $(tail -3 <<<"$install_out" | tr '\n' ' ')"
    return 1
  fi

  android_sh "$init_pid" "logcat -c" >/dev/null 2>&1
  android_sh "$init_pid" "am start -n $KEYSTORE_PROBE_PKG/.MainActivity" > "$EV/$leg-keystore-probe-start.log" 2>&1
  local pdeadline=$((SECONDS + 240)) probe_log=""
  while (( SECONDS < pdeadline )); do
    probe_log=$(android_sh "$init_pid" "logcat -d -s RhizoKeystoreProbe:* 2>/dev/null" | grep -E 'RHIZO_KEYSTORE_PROBE' || true)
    grep -q 'RHIZO_KEYSTORE_PROBE done ' <<<"$probe_log" && break
    sleep 2
  done
  printf '%s\n' "$probe_log" > "$EV/$leg-keystore-probe.log"
  echo "$probe_log" | sed 's/^/  /'
  assert_keystore_probe "$leg" "$probe_log"

  local remove_out
  remove_out=$(ssh_vm -t 300 "sudo -u $desktop_user -- /usr/bin/rhizo app remove $KEYSTORE_PROBE_PKG 2>&1; echo rc=\$?")
  printf '%s\n' "$remove_out" > "$EV/$leg-keystore-probe-remove.log"
  if grep -q "^RHIZO_APP removed=$KEYSTORE_PROBE_PKG" <<<"$remove_out" && grep -qx 'rc=0' <<<"$remove_out"; then
    pass "[$leg] rhizo app remove took the probe out again"
  else
    fail "[$leg] rhizo app remove did not report the probe removed: $(tail -2 <<<"$remove_out" | tr '\n' ' ')"
  fi
  ssh_vm -t 60 "rm -rf $TEST_PROBE_DIR" >/dev/null 2>&1
  return 0
}

# run a command in a package window
test_pkgwin() {
  local kind="$1"
  [[ "$leg" == base ]] || { shift 2; "$@"; return; }
  host_census_pkgwin "$EV/$leg-pkgwin-$kind.log" "$@"
}

# write leftover Rhizo paths and processes to <file>
record_leftovers() {
  ssh_vm -t 60 '
    marker=leftover-probe n=0
    for p in /var/lib/rhizo /usr/lib/rhizo /etc/rhizo /var/cache/rhizo /var/log/rhizo /srv/rhizo; do
      [ -e "$p" ] || continue
      n=$((n + 1))
      echo "== $p"
      find "$p" -maxdepth 2 -printf "%TY-%Tm-%Td %TT %u:%g %Z %p\n" 2>&1 | sort | head -40
    done
    procs=$(ps -eo pid,ppid,lstart,unit,args --no-headers 2>/dev/null | grep -E "rhizo|launcher3|androidd" | grep -v -e "$marker" -e "grep -E")
    if [ -n "$procs" ]; then n=$((n + 1)); echo "== processes"; echo "$procs"; fi
    [ "$n" -gt 0 ] || echo "<none>"
    true' > "$1" 2>&1
}

# run a leg of the installer system test
run_leg() {
  local leg="$1"
  local DISK="$VAR_DIR/vm-pristine${SUFFIX}.qcow2"

  step "[$leg] 2. the pinned, verified stock image"
  ../../../tools/fetch/images/ubuntu-base.sh 2>&1 | sed 's/^/  /' || { fail "[$leg] ubuntu-base.sh failed"; return 1; }

  if (( REUSE_DISK )); then
    note "[$leg] REUSE-DISK: this disk was NOT recreated"
  else
    step "[$leg] 3. a disk with no other ancestry"
    kill_vm >/dev/null 2>&1
    if [[ -L "$VAR_DIR/settled$SUFFIX" ]]; then
      SETTLED_LINK_TARGET=$(readlink "$VAR_DIR/settled$SUFFIX")
    fi
    rm -f "$VAR_DIR/settled$SUFFIX" "$DISK"
    note "[$leg] deleted $(basename "$DISK") -- this leg starts from the pinned image"
  fi

  step "[$leg] 4. GRUB boot, stock state observed from inside"
  installer_assert_stock "$leg" || return 1

  step "[$leg] 5. make this vm resemble a real desktop, before Rhizo"
  installer_stage_desktop_resemblance "$leg" || return 1
  if [[ "$leg" == base ]]; then
    installer_stage_desktop_user "$leg" "$INSTALLER_DESKTOP_HUMAN" || return 1
    if ! ../../vm/start/start-sway.sh --stage-login --user "$INSTALLER_DESKTOP_HUMAN" >"$EV/$leg-seat-login-stage.log" 2>&1; then
      fail "[$leg] the sway seat login of $INSTALLER_DESKTOP_HUMAN did not come up on the stock host (see $EV/$leg-seat-login-stage.log)"
      return 1
    fi
    pass "[$leg] $INSTALLER_DESKTOP_HUMAN's tty1 login runs sway on the stock host, as every later boot's login will"
    installer_stage_pool "$leg" adb "$SHARE_DIR/adb-debs" "$TEST_ADB_DEBS" "adb" "" || return 1
  fi

  if [[ "$leg" == base ]]; then
    step "[$leg] 5c. host snapshot before Rhizo touches anything"
    rm -f "$EV/$leg"-pkgwin-*.log "$EV/$leg"-owned-*.tsv "$EV/$leg"-apt-kept-*.log
    take_snapshot "[$leg] before" "$EV/$leg-snapshot-before.tsv" || return 1
    pass "[$leg] pre-install host snapshot captured"
  fi

  step "[$leg] 6. only the artifact crosses"
  installer_transfer_artifact "$leg" "$RHIZO_DEB" "${KERNEL_DEBS[@]}" || return 1

  step "[$leg] 6b. seed the GSI download the guest cannot make"
  installer_seed_gsi_zip "$leg" || return 1

  step "[$leg] 6c. stage the offline pool a real host's apt stands for"
  test_pkgwin test-staged step6c-offline-pool installer_stage_offline_repo "$leg" || return 1

  step "[$leg] 7-9. one command, one reboot, setup finished on its own"
  test_pkgwin rhizo-install step7-install installer_install_reboot_prepare "$leg" || return 1
  local prep
  prep=$(cat "$EV/$leg-prepare.log" 2>/dev/null)

  step "[$leg] 9a. the profile's and stream.enabled's sockets after the install"
  installer_assert_policy_sockets "$leg" "after the install and its reboot" || return 1

  step "[$leg] 9b. the session starts after setup, onto a released sandbox"
  local sock_line active session_t0=""
  sock_line=$(grep -o 'setup boot socket: .*' <<<"$prep" | tail -1)
  note "[$leg] prepare's ${sock_line:-setup boot socket: <no such line>}"
  if ! grep -qF 'releasing the setup boot: socket ' <<<"$prep"; then
    fail "[$leg] prepare kept its setup boot (${sock_line:-no setup boot socket: line})"
    return 1
  fi
  if ! grep -qF 'resident supervisor parked -- the next start hands off' <<<"$prep"; then
    fail "[$leg] prepare released its setup boot but reported no parked supervisor ($(grep -o 'RHIZO_PREPARE_[A-Z]* reason=[a-z-]*' <<<"$prep" | tail -1))"
    return 1
  fi
  active=$(ssh_vm -t 30 'systemctl is-active androidd.service' | tr -d '[:space:]')
  if [[ "$active" == active ]]; then
    session_t0=$(installer_session_start_uptime "$leg") || return 1
    pass "[$leg] setup released its sandbox with the supervisor parked, and rhizo-session-start.service started Android again for the logged-in desktop session at uptime ${session_t0}s"
  else
    pass "[$leg] setup released its sandbox (androidd.service ${active:-unknown}) with the supervisor parked"
  fi
  if ! ../../vm/start/start-sway.sh >"$EV/$leg-sway.log" 2>&1; then
    cp -f "${TMPDIR:-/tmp}/sway-install${SUFFIX}.log" "$EV/$leg-sway-install.log" 2>/dev/null || true
    ssh_vm -t 60 'dpkg -l | grep -E "^i[^i]" | head -20; echo "=== dpkg audit ==="; dpkg --audit 2>&1 | head -20' \
      >> "$EV/$leg-sway-install.log" 2>&1
    fail "[$leg] sway did not start (see $EV/$leg-sway.log and $EV/$leg-sway-install.log)"
    return 1
  fi
  swaycmd "-t get_version" 30 >/dev/null 2>&1 \
    && pass "[$leg] the compositor answers after setup" \
    || { fail "[$leg] sway started but does not answer on its ipc socket"; return 1; }

  step "[$leg] 10. a real app in a real composited frame"
  local t0 booted=0
  if [[ -n "$session_t0" ]]; then
    t0=$session_t0
    note "[$leg] androidd.service runs already, started by rhizo-session-start.service at uptime ${t0}s: step 10 reads that start"
  else
    t0=$(guest_uptime)
    ssh_vm -t 600 'systemctl start androidd.service' >"$EV/$leg-start.log" 2>&1
  fi
  wait_sandbox_started 420 "$t0" && booted=1
  if (( booted )); then
    pass "[$leg] the sandbox started on demand after setup"
    local handoff_line wl_line wl_sock
    handoff_line=$(sandbox_marker_after "$t0" 'is parked -- staging here')
    wl_line=$(sandbox_marker_after "$t0" 'wayland socket (bind-mounted|NOT FOUND|bind mount FAILED)')
    { echo "t0=$t0"
      sandbox_marker_after "$t0" 'RHIZO_MARKER launch_start sandbox=0'
      echo "$handoff_line"
      echo "$wl_line"
      sandbox_marker_after "$t0" 'EnsureWaylandConnected'
    } > "$EV/$leg-sandbox-wayland.txt" 2>&1
    note "[$leg] start after setup: ${handoff_line:-no parked-supervisor handoff line after t0=$t0}"
    if [[ "$wl_line" != *'wayland socket bind-mounted: '* ]]; then
      fail "[$leg] the sandbox started after setup bound no compositor socket: ${wl_line:-no wayland socket line after t0=$t0} (see $EV/$leg-sandbox-wayland.txt)"
      return 1
    fi
    wl_sock=${wl_line#*bind-mounted: }
    wl_sock=${wl_sock%% -> *}
    note "[$leg] the sandbox bound compositor socket $wl_sock"
    pass "[$leg] the sandbox under test bound the compositor socket"
    if (( THROUGH_BOOT )); then
      note "[$leg] --through-boot: sys.boot_completed=1 reached on the installed artifact; the app launch, upgrade and removal legs did not run"
      return 0
    fi
  else
    ssh_vm -t 120 'systemctl status androidd.service --no-pager -l 2>&1 | head -40; echo "=== journal ==="; journalctl -u androidd.service -n 60 --no-pager 2>&1' \
      > "$EV/$leg-androidd-journal.log" 2>&1
    ssh_vm -t 60 '/usr/lib/rhizo/tools/kernel-check.sh; echo "kernel-check rc=$?"' \
      >> "$EV/$leg-androidd-journal.log" 2>&1
    fail "[$leg] the sandbox did not reach boot_completed when started after setup (see $EV/$leg-androidd-journal.log)"
    return 1
  fi

  local launched cdisp
  local init_pid pkgact
  init_pid=$(resolve_init_pid 120)
  [[ -n "$init_pid" ]] || { fail "[$leg] no Android init is running to ask for an activity"; return 1; }
  note "[$leg] android init pid=$init_pid"
  INIT="$init_pid"
  export INIT
  pkgact=$(android_sh "$init_pid" "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.android.settings" \
           | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' | tail -1)
  if [[ "$pkgact" != */* ]]; then
    note "[$leg] settings resolved nothing; asking for any launchable activity"
    pkgact=$(android_sh "$init_pid" "cmd package query-activities -a android.intent.action.MAIN -c android.intent.category.LAUNCHER" \
             | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' | head -1)
  fi
  if [[ "$pkgact" != */* ]]; then
    fail "[$leg] the device named no launchable activity at all"
    return 1
  fi
  note "[$leg] launching $pkgact"
  ssh_vm -t 300 "/usr/lib/rhizo/tools/rhizo-launch.sh ${pkgact%%/*} ${pkgact##*/} >/tmp/rhizo-test-launch.log 2>&1; echo rc=\$?" \
    > "$EV/$leg-launch-rc.log" 2>&1
  ssh_vm -t 60 'cat /tmp/rhizo-test-launch.log 2>/dev/null' > "$EV/$leg-launch.log" 2>&1
  ssh_vm -t 60 'tail -40 /run/rhizo-launch/rhizo-launch.log 2>/dev/null' \
    >> "$EV/$leg-launch.log" 2>&1
  launched=$(cat "$EV/$leg-launch.log" 2>/dev/null | tail -20)
  echo "$launched" > "$EV/$leg-launch.log"
  echo "$launched" | sed 's/^/  /'
  cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$launched" | tail -1 | cut -d= -f2)
  if [[ -z "$cdisp" ]]; then
    fail "[$leg] the launch reported no cdisplay= to screenshot"
  else
    note "[$leg] app launched onto composer display $cdisp"
    local mdeadline=$((SECONDS + 180)) mapped=0
    while (( SECONDS < mdeadline )); do
      if mapped_window_rect "$cdisp" >/dev/null 2>&1; then mapped=1; break; fi
      sleep 5
    done
    if (( mapped )); then
      note "[$leg] a toplevel is mapped on display $cdisp"
      assert_window_painted "$leg-app" "$cdisp"
    else
      sway_windows > "$EV/$leg-sway-windows.txt" 2>&1
      swaycmd "-t get_tree" 120 > "$EV/$leg-sway-tree.json" 2>&1
      rhizo_ctl_out "$init_pid" > "$EV/$leg-composer-control.out" 2>&1
      ssh_vm -t 60 "dmesg 2>/dev/null | grep -E 'rhizo-composer|RHIZO_MARKER|CreateDisplay|AddDisplay|Wayland|wayland' \
        | grep -vE 'toplevel-failed|<- display toplevel' | tail -200" \
        > "$EV/$leg-display-markers.log" 2>&1
      ssh_vm -t 60 "dmesg 2>/dev/null | grep -cE 'toplevel-failed'" \
        > "$EV/$leg-display-retry-count.txt" 2>&1
      android_sh "$init_pid" "dumpsys activity activities" 2>/dev/null | head -60 \
        > "$EV/$leg-activities.log" 2>&1
      { ssh_vm -t 30 'ls -la /run/rhizo-wayland/ 2>&1; findmnt -o TARGET,PROPAGATION /run/rhizo-wayland 2>&1'
        android_sh "$init_pid" "ls -la /dev/socket/rhizo_wayland/ 2>&1"
      } > "$EV/$leg-wayland-socket.txt" 2>&1
      fail "[$leg] no toplevel ever mapped on display $cdisp within 180s -- sway listed $(wc -l < "$EV/$leg-sway-windows.txt") client window(s) (see $EV/$leg-sway-tree.json and $EV/$leg-composer-control.out)"
    fi
  fi

  keymint_leg "$leg" "$init_pid" "$t0" || return 1

  step "[$leg] 11. a real N-1 -> N upgrade"
  shopt -s nullglob
  prev_debs=("$DEB_DIR_PREV"/rhizo_*_amd64.deb)
  shopt -u nullglob
  if (( ${#prev_debs[@]} == 0 )); then
    fail "[$leg] no N-1 package: rhizo_*_amd64.deb in $DEB_DIR_PREV -- $N1_PAIR_SOURCE"
    return 1
  fi
  local prev_deb_path
  prev_deb_path=$(highest_version_deb "${prev_debs[@]}")
  PREV_DEB_NAME="$(basename "$prev_deb_path")"
  cp -f "$prev_deb_path" "$EV_DEB_DIR/$PREV_DEB_NAME" \
    || { fail "[$leg] could not copy the N-1 package into $EV_DEB_DIR"; return 1; }
  note_artifact "$EV_DEB_DIR/$PREV_DEB_NAME"

  n_version=$(dpkg-deb -f "$RHIZO_DEB" Version 2>/dev/null)
  n1_version=$(dpkg-deb -f "$EV_DEB_DIR/$PREV_DEB_NAME" Version 2>/dev/null)
  if [[ -z "$n_version" || -z "$n1_version" || "$n_version" == "$n1_version" ]]; then
    fail "[$leg] N-1 ($PREV_DEB_NAME, version=${n1_version:-?}) is not a real N-1 of N ($n_version) -- $N1_PAIR_SOURCE"
    return 1
  fi
  local tree_n1_version
  tree_n1_version=$(dpkg-parsechangelog -l"$REPO_ROOT/debian/changelog" -o1 -c1 -SVersion 2>/dev/null)
  if [[ "$n1_version" != "$tree_n1_version" ]]; then
    fail "[$leg] N-1 ($n1_version, from $PREV_DEB_NAME) is not this tree's own previous changelog entry (debian/changelog -o1 -c1 says '${tree_n1_version:-<none>}') -- $DEB_DIR_PREV holds an old or unrelated build; $N1_PAIR_SOURCE"
    return 1
  fi
  if dpkg-deb -f "$EV_DEB_DIR/$PREV_DEB_NAME" Depends 2>/dev/null | grep -qE '(^|[ ,])rhizo-binder-modules([ ,(]|$)'; then
    fail "[$leg] N-1 $n1_version ($PREV_DEB_NAME) depends on rhizo-binder-modules -- put a newer N-1 in $DEB_DIR_PREV"
    return 1
  fi
  note "[$leg] N-1=$n1_version, N=$n_version"
  UPGRADE_VERDICT_INFO="$UPGRADE_VERDICT_INFO n1_rhizo[$leg]=$PREV_DEB_NAME:$(sha256sum "$EV_DEB_DIR/$PREV_DEB_NAME" | cut -d' ' -f1)"

  ssh_vm -t 30 'rm -rf /root/rhizo-artifact-prev && mkdir -p /root/rhizo-artifact-prev' >/dev/null 2>&1
  timeout 600 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$EV_DEB_DIR/$PREV_DEB_NAME" "$SSH_TARGET:/root/rhizo-artifact-prev/" \
    || { fail "[$leg] could not stage N-1 onto the guest"; return 1; }

  local n1_kernel kernel_pkgs=""
  if ! n1_kernel=$(deb_pool_kernel_debs "$EV_DEB_DIR/$PREV_DEB_NAME" "$EV_DEB_DIR"); then
    fail "[$leg] N-1 ($PREV_DEB_NAME) depends on a Rhizo kernel .deb this run's artifact lacks (see above)"
    return 1
  fi
  if ! kernel_pkgs=$(installer_kernel_deb_packages "${KERNEL_DEBS[@]}"); then
    fail "[$leg] $kernel_pkgs"
    return 1
  fi
  wait_dpkg_free "[$leg] N-1 install"
  if [[ -n "$kernel_pkgs" && -z "$n1_kernel" ]]; then
    out=$(ssh_vm -t 1800 "cd /root/rhizo-artifact-prev && dpkg -i --force-confold ./$PREV_DEB_NAME 2>&1; echo '--- purge the Rhizo kernel'; dpkg --purge$kernel_pkgs 2>&1")
  else
    out=$(ssh_vm -t 900 "cd /root/rhizo-artifact-prev && dpkg -i --force-confold ./$PREV_DEB_NAME 2>&1")
  fi
  echo "$out" > "$EV/$leg-downgrade-to-n1.log"
  if grep -qE '^dpkg: error' <<<"$out"; then
    fail "[$leg] installing N-1 ($n1_version) over N ($n_version) failed: $(tail -8 <<<"$out" | tr '\n' ' ')"
    return 1
  fi
  pass "[$leg] N-1 ($n1_version) installed over N ($n_version)"
  if [[ -n "$kernel_pkgs" && -z "$n1_kernel" ]]; then
    local kernel_left
    kernel_left=$(ssh_vm -t 30 "for p in$kernel_pkgs; do s=\$(dpkg-query -W -f='\${Status}' \$p 2>&1); case \"\$s\" in *not-installed|*'no packages found'*) ;; *) echo \"\$p: \$s\" ;; esac; done; echo DONE")
    if [[ "$kernel_left" == DONE ]]; then
      pass "[$leg] the Rhizo kernel N-1 predates is purged:$kernel_pkgs"
    else
      fail "[$leg] the Rhizo kernel packages are still on the N-1 host: $(grep -v '^DONE$' <<<"$kernel_left" | tr '\n' ';')"
      return 1
    fi
  fi

  local n1_dpkg_state
  n1_dpkg_state=$(ssh_vm -t 20 "dpkg-query -W -f='\${Version}\t\${db:Status-Abbrev}' rhizo 2>/dev/null")
  if [[ "${n1_dpkg_state%%$'\t'*}" == "$n1_version" && "$n1_dpkg_state" == *$'\t'* ]] \
      && installer_abbrev_configured "${n1_dpkg_state#*$'\t'}"; then
    pass "[$leg] dpkg-query confirms rhizo $n1_version is installed and configured (ii)"
  else
    fail "[$leg] dpkg-query -W rhizo reports '${n1_dpkg_state:-<empty>}' after the N-1 install, wanted version $n1_version and status 'ii ' (installed, configured, no error flag)"
    return 1
  fi
  local n1_prep_n0
  n1_prep_n0=$(ssh_vm -t 20 'wc -l < /var/log/rhizo/prepare.log 2>/dev/null' | tr -d '[:space:]')
  if [[ -z "$n1_prep_n0" ]]; then
    fail "[$leg] could not read a baseline line count from /var/log/rhizo/prepare.log before rebooting into N-1"
    return 1
  fi

  reboot_and_wait "[$leg] after N-1 install" || return 1
  installer_assert_rhizo_kernel "$leg" "the N-1 install's reboot" || return 1

  installer_await_prepare "$leg" "$EV/$leg-n1-prepare.log" "$n1_prep_n0" " for N-1, past its own pre-reboot baseline" \
    || return 1

  local n1_prepared_marker n1_guest_kernel
  n1_prepared_marker=$(ssh_vm -t 20 'cat /var/lib/rhizo/.prepared 2>/dev/null')
  n1_guest_kernel=$(ssh_vm -t 20 'uname -r' | tr -d '[:space:]')
  if grep -qx "version=$n1_version" <<<"$n1_prepared_marker" && grep -qx "kernel=$n1_guest_kernel" <<<"$n1_prepared_marker"; then
    pass "[$leg] /var/lib/rhizo/.prepared carries version=$n1_version kernel=$n1_guest_kernel"
  else
    fail "[$leg] /var/lib/rhizo/.prepared does not carry version=$n1_version kernel=$n1_guest_kernel (read: '${n1_prepared_marker:-<empty>}')"
    return 1
  fi

  local n1_t0 n1_booted=0
  n1_t0=$(guest_uptime)
  ssh_vm -t 420 'systemctl start androidd.service' >"$EV/$leg-n1-start.log" 2>&1
  wait_sandbox_started 420 "$n1_t0" && n1_booted=1
  if (( ! n1_booted )); then
    fail "[$leg] the N-1 sandbox never reached boot_completed after its own setup (see $EV/$leg-n1-start.log)"
    return 1
  fi
  local n1_init; n1_init=$(resolve_init_pid 60)
  if [[ -z "$n1_init" ]]; then
    fail "[$leg] N-1 booted but no init second_stage pid was found"
    return 1
  fi
  INIT="$n1_init"
  pass "[$leg] N-1 is up, init pid=$n1_init"

  step "[$leg] 11a. plant fixtures under N-1: an app, a settings marker, an adb key"
  local desktop_user
  desktop_user=$(ssh_vm -t 30 'cat /etc/rhizo/desktop-user 2>/dev/null' | tr -d '[:space:]')
  if [[ -z "$desktop_user" ]]; then
    fail "[$leg] no /etc/rhizo/desktop-user"
    return 1
  fi
  local fixture_apk="$SHARE_DIR/rhizo-test-fixture.apk" fixture_meta="$SHARE_DIR/rhizo-test-fixture.json"
  if [[ ! -f "$fixture_apk" || ! -f "$fixture_meta" ]]; then
    fail "[$leg] no $fixture_apk/$fixture_meta -- fetch the install fixture with tools/fetch/test-apk.sh"
    return 1
  fi
  local fixture_pkg fixture_act
  fixture_pkg=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["package"])' "$fixture_meta")
  fixture_act=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["activity"])' "$fixture_meta")
  ssh_vm -t 60 "mkdir -p $TEST_PROBE_DIR && chmod 0755 $TEST_PROBE_DIR" >/dev/null 2>&1
  timeout 300 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$fixture_apk" "$SSH_TARGET:$TEST_PROBE_DIR/" \
    || { fail "[$leg] could not stage the fixture apk"; return 1; }
  ssh_vm -t 60 "chmod 0644 $TEST_PROBE_DIR/$(basename "$fixture_apk")" >/dev/null 2>&1
  local fixture_install
  fixture_install=$(ssh_vm -t 600 "sudo -u $desktop_user -- /usr/bin/rhizo app install $TEST_PROBE_DIR/$(basename "$fixture_apk") 2>&1; echo rc=\$?")
  printf '%s\n' "$fixture_install" > "$EV/$leg-fixture-install.log"
  if grep -q "^RHIZO_APP installed=$fixture_pkg " <<<"$fixture_install" && grep -qx 'rc=0' <<<"$fixture_install"; then
    pass "[$leg] the fixture app installed under N-1, as $desktop_user through the broker"
  else
    fail "[$leg] rhizo app install did not report the fixture installed (see $EV/$leg-fixture-install.log): $(tail -3 <<<"$fixture_install" | tr '\n' ' ')"
    return 1
  fi

  local settings_mtime_before settings_put_ms
  settings_mtime_before=$(_settings_dir_mtime_min "$n1_init")
  SOAK_UUID=$(cat /proc/sys/kernel/random/uuid)
  ANDROID_SH_TIMEOUT=20 android_sh "$n1_init" "settings put global rhizo_soak_marker $SOAK_UUID" >/dev/null 2>&1
  settings_put_ms=$(( $(date +%s%N) / 1000000 ))
  local put_back; put_back=$(ANDROID_SH_TIMEOUT=20 android_sh "$n1_init" "settings get global rhizo_soak_marker" | tr -d '[:space:]')
  if [[ "$put_back" == "$SOAK_UUID" ]]; then
    pass "[$leg] settings put/get round-tripped the soak marker under N-1"
  else
    fail "[$leg] settings get global rhizo_soak_marker read back '${put_back:-<empty>}', wanted $SOAK_UUID"
    return 1
  fi
  if await_settings_durable_min "$n1_init" "$settings_mtime_before" "$settings_put_ms" 10 >/dev/null; then
    pass "[$leg] the soak marker's settings write proved durable before the upgrade began"
  else
    fail "[$leg] the soak marker's settings write never proved durable"
    return 1
  fi

  local test_key_dir="$EV/$leg-adbkey"
  mkdir -p "$test_key_dir"
  rm -f "$test_key_dir/adbkey" "$test_key_dir/adbkey.pub"
  if ! "$ADB" keygen "$test_key_dir/adbkey" >"$EV/$leg-adb-keygen.log" 2>&1 || [[ ! -s "$test_key_dir/adbkey.pub" ]]; then
    fail "[$leg] adb keygen did not produce $test_key_dir/adbkey.pub (see $EV/$leg-adb-keygen.log)"
    return 1
  fi
  local key_add
  key_add=$(ssh_vm -t 30 "rhizo adb-key add -" < "$test_key_dir/adbkey.pub" 2>&1)
  printf '%s\n' "$key_add" > "$EV/$leg-adbkey-add.log"
  if ! grep -q '^RHIZO_ADBKEY added=1' <<<"$key_add"; then
    fail "[$leg] rhizo adb-key add did not report added=1 (see $EV/$leg-adbkey-add.log): $(tail -3 <<<"$key_add" | tr '\n' ' ')"
    return 1
  fi
  pass "[$leg] a new adb key registered under N-1"

  local data_ino_before data_crtime_before
  data_ino_before=$(ssh_vm -t 20 'stat -c %i /var/lib/rhizo/data.img 2>/dev/null' | tr -d '[:space:]')
  data_crtime_before=$(ssh_vm -t 20 'stat -c %W /var/lib/rhizo/data.img 2>/dev/null' | tr -d '[:space:]')
  if [[ -z "$data_ino_before" || -z "$data_crtime_before" || "$data_crtime_before" == 0 ]]; then
    fail "[$leg] could not read a real inode/crtime for /var/lib/rhizo/data.img before the upgrade (ino='${data_ino_before:-<empty>}' crtime='${data_crtime_before:-<empty>}')"
    return 1
  fi
  note "[$leg] data.img before the upgrade: ino=$data_ino_before crtime=$data_crtime_before"

  step "[$leg] 11b. N-1 -> N: apt-get install of the rhizo package with the kernel packages it depends on"
  wait_dpkg_free "[$leg] N upgrade"
  local upgrade_bid_before upgrade_bid_after
  upgrade_bid_before=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
  local n_prep_n0
  n_prep_n0=$(ssh_vm -t 20 'wc -l < /var/log/rhizo/prepare.log 2>/dev/null' | tr -d '[:space:]')
  if [[ -z "$n_prep_n0" ]]; then
    fail "[$leg] could not read a baseline line count from /var/log/rhizo/prepare.log before the N upgrade"
    return 1
  fi
  local upgrade_out n_deb_name upgrade_marks_before upgrade_marks_after upgrade_debs=""
  n_deb_name=$(basename "$RHIZO_DEB")
  for k in "${KERNEL_DEBS[@]}"; do upgrade_debs+=" /root/rhizo-artifact/$(basename "$k")"; done
  upgrade_marks_before=$(installer_start_marks)
  test_pkgwin rhizo-install step11b-upgrade ssh_vm -t 1800 "[ -s $TEST_APT_OFFLINE_CONF ] || { echo APT_RC=NOCONF; exit; }
    APT_CONFIG=$TEST_APT_OFFLINE_CONF DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold /root/rhizo-artifact/$n_deb_name$upgrade_debs 2>&1; echo \"APT_RC=\$?\"" > "$EV/$leg-upgrade-to-n.log"
  upgrade_out=$(cat "$EV/$leg-upgrade-to-n.log")
  upgrade_marks_after=$(installer_start_marks)
  printf '%s\n=== after\n%s\n' "$upgrade_marks_before" "$upgrade_marks_after" > "$EV/$leg-upgrade-start-marks.txt"
  installer_assert_started_nothing "$leg" "the N-1 -> N upgrade" "$upgrade_marks_before" "$upgrade_marks_after"
  installer_assert_offline_apt "$leg" "$EV/$leg-upgrade-to-n.log" "the N-1 -> N upgrade"
  if grep -qE '^E: |^dpkg: error' <<<"$upgrade_out"; then
    fail "[$leg] apt-get install of N over N-1 failed: $(tail -8 <<<"$upgrade_out" | tr '\n' ' ')"
    return 1
  fi
  pass "[$leg] apt-get install of N ($n_version) over N-1 ($n1_version) reported no error"

  if grep -qF "Unpacking rhizo ($n_version) over ($n1_version)" <<<"$upgrade_out"; then
    pass "[$leg] apt's own log confirms it unpacked rhizo ($n_version) over ($n1_version), not a no-op"
  else
    fail "[$leg] apt-get's log never reported 'Unpacking rhizo ($n_version) over ($n1_version)' (see $EV/$leg-upgrade-to-n.log)"
    return 1
  fi

  if ! grep -q 'reboot to finish the upgrade' <<<"$upgrade_out"; then
    fail "[$leg] postinst never printed 'reboot to finish the upgrade' (see $EV/$leg-upgrade-to-n.log)"
    return 1
  fi
  local n_init
  note "[$leg] postinst asked for a reboot to finish the upgrade -- rebooting"
  reboot_and_wait "[$leg] after the N upgrade" || return 1
  installer_assert_rhizo_kernel "$leg" "the N upgrade's reboot" || return 1
  upgrade_bid_after=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
  [[ "$upgrade_bid_after" != "$upgrade_bid_before" ]] \
    && pass "[$leg] the upgrade rebooted, as postinst said it would (boot_id $upgrade_bid_before -> $upgrade_bid_after)" \
    || fail "[$leg] postinst asked for a reboot but boot_id did not change"
  installer_await_prepare "$leg" "$EV/$leg-n-prepare.log" "$n_prep_n0" " for N after the upgrade"
  if grep -q 'RHIZO_PREPARE_OK' <<<"$INSTALLER_PREPARE_OUT" && grep -q 'DATA_STATE=kept' <<<"$INSTALLER_PREPARE_OUT"; then
    pass "[$leg] N's own prepare reported RHIZO_PREPARE_OK and DATA_STATE=kept"
  else
    fail "[$leg] N's own prepare did not report both RHIZO_PREPARE_OK and DATA_STATE=kept in the lines past its own pre-upgrade baseline (see $EV/$leg-n-prepare.log)"
  fi
  local n_prepared_marker n_guest_kernel
  n_prepared_marker=$(ssh_vm -t 20 'cat /var/lib/rhizo/.prepared 2>/dev/null')
  n_guest_kernel=$(ssh_vm -t 20 'uname -r' | tr -d '[:space:]')
  if grep -qx "version=$n_version" <<<"$n_prepared_marker" && grep -qx "kernel=$n_guest_kernel" <<<"$n_prepared_marker"; then
    pass "[$leg] /var/lib/rhizo/.prepared carries version=$n_version kernel=$n_guest_kernel"
  else
    fail "[$leg] /var/lib/rhizo/.prepared does not carry version=$n_version kernel=$n_guest_kernel (read: '${n_prepared_marker:-<empty>}')"
  fi
  if ! ../../vm/start/start-sway.sh >"$EV/$leg-sway-after-upgrade.log" 2>&1; then
    fail "[$leg] sway did not start after the N upgrade's reboot (see $EV/$leg-sway-after-upgrade.log)"
    return 1
  fi
  local n_t0 n_booted=0
  n_t0=$(guest_uptime)
  ssh_vm -t 420 'systemctl start androidd.service' >"$EV/$leg-n-start.log" 2>&1
  wait_sandbox_started 420 "$n_t0" && n_booted=1
  if (( ! n_booted )); then
    fail "[$leg] N's sandbox never reached boot_completed after the upgrade (see $EV/$leg-n-start.log)"
    return 1
  fi
  n_init=$(resolve_init_pid 60)
  if [[ -z "$n_init" ]]; then
    fail "[$leg] no init second_stage pid was found for N after the upgrade"
    return 1
  fi
  INIT="$n_init"

  step "[$leg] 11c. what survived the upgrade"
  local dpkg_s; dpkg_s=$(ssh_vm -t 20 'dpkg -s rhizo 2>/dev/null')
  if grep -qx "Version: $n_version" <<<"$dpkg_s"; then
    pass "[$leg] dpkg -s rhizo reports Version: $n_version"
  else
    fail "[$leg] dpkg -s rhizo does not report Version: $n_version: $(grep '^Version:' <<<"$dpkg_s")"
  fi
  local guest_version; guest_version=$(ssh_vm -t 20 'cat /usr/lib/rhizo/VERSION 2>/dev/null' | tr -d '[:space:]')
  if [[ "$guest_version" == "$n_version" ]]; then
    pass "[$leg] /usr/lib/rhizo/VERSION moved N-1 ($n1_version) -> N ($n_version)"
  else
    fail "[$leg] /usr/lib/rhizo/VERSION reads '${guest_version:-<empty>}', wanted $n_version"
  fi

  local pkgs_after; pkgs_after=$(ANDROID_SH_TIMEOUT=30 android_sh "$n_init" "pm list packages")
  if grep -qx "package:$fixture_pkg" <<<"$pkgs_after"; then
    pass "[$leg] the fixture app is still in pm list packages after the upgrade"
  else
    fail "[$leg] $fixture_pkg is gone from pm list packages after the upgrade"
  fi
  ssh_vm -t 300 "/usr/lib/rhizo/tools/rhizo-launch.sh $fixture_pkg $fixture_act >/tmp/rhizo-test-fixture-relaunch.log 2>&1; echo rc=\$?" \
    > "$EV/$leg-fixture-relaunch-rc.log" 2>&1
  local fdeadline=$((SECONDS + 180)) fmapped=0 fcdisp=""
  ssh_vm -t 60 'tail -40 /run/rhizo-launch/rhizo-launch.log 2>/dev/null' > "$EV/$leg-fixture-relaunch.log" 2>&1
  fcdisp=$(grep "pkg=$fixture_pkg " "$EV/$leg-fixture-relaunch.log" | grep -o 'cdisplay=[0-9]*' | tail -1 | cut -d= -f2)
  _RHIZO_NO_DISPLAY_TOPLEVEL_VERB=0
  local want_appid="rhizo-$fixture_pkg" got_reply="" got_appid="" got_title=""
  while [[ -n "$fcdisp" ]] && (( SECONDS < fdeadline )); do
    got_reply=$(resolve_display_toplevel "$fcdisp" 2>/dev/null)
    if [[ -n "$got_reply" ]]; then
      IFS=' ' read -r got_appid got_title <<<"$got_reply"
      [[ "$got_appid" == "$want_appid" ]] && { fmapped=1; break; }
    fi
    sleep 5
  done
  if [[ -z "$fcdisp" ]]; then
    fail "[$leg] rhizo-launch.sh named no cdisplay= for $fixture_pkg after the upgrade (see $EV/$leg-fixture-relaunch.log and $EV/$leg-fixture-relaunch-rc.log)"
  elif (( fmapped )); then
    assert_window_painted "$leg-fixture-after-upgrade" "$fcdisp"
  else
    fail "[$leg] display $fcdisp never resolved app_id=$want_appid after the upgrade (last seen: app_id=${got_appid:-<none>} title=${got_title:-<none>}, see $EV/$leg-fixture-relaunch.log)"
  fi

  local marker_after; marker_after=$(ANDROID_SH_TIMEOUT=20 android_sh "$n_init" "settings get global rhizo_soak_marker" | tr -d '[:space:]')
  if [[ "$marker_after" == "$SOAK_UUID" ]]; then
    pass "[$leg] the settings marker survived the upgrade byte for byte"
  else
    fail "[$leg] settings get global rhizo_soak_marker reads '${marker_after:-<empty>}' after the upgrade, wanted $SOAK_UUID"
  fi

  local live_adbkeys; live_adbkeys=$(ANDROID_SH_TIMEOUT=20 android_sh "$n_init" "cat /adb_keys")
  local pubkey_body; pubkey_body=$(awk '{print $1}' "$test_key_dir/adbkey.pub")
  if grep -qF "$pubkey_body" <<<"$live_adbkeys"; then
    pass "[$leg] the adb key fingerprint is still in the LIVE adb_keys after the upgrade"
  else
    fail "[$leg] the adb key registered under N-1 is gone from the live sandbox's /adb_keys after the upgrade"
  fi
  local adbd_state adb_endpoint
  adbd_state=$(ANDROID_SH_TIMEOUT=20 android_sh "$n_init" "getprop init.svc.adbd" | tr -d '[:space:]')
  adb_endpoint=$(ssh_vm -t 20 '/usr/bin/rhizo status --adb' | tr -d '[:space:]')
  if [[ "$adbd_state" != running || "$adb_endpoint" != *:5555 ]]; then
    fail "[$leg] adbd state='${adbd_state:-<empty>}' endpoint='${adb_endpoint:-<empty>}' after the upgrade"
  else
    local connect_out adb_path
    adb_path=$(ssh_vm -t 20 'command -v adb 2>/dev/null' | tr -d '[:space:]')
    echo "adb=${adb_path:-<none>}" > "$EV/$leg-adb-tools-install.log"
    timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$test_key_dir/adbkey" "$SSH_TARGET:/root/rhizo-test-upgrade-adbkey" \
      && ssh_vm -t 20 'chmod 600 /root/rhizo-test-upgrade-adbkey' >/dev/null 2>&1
    connect_out=$(ssh_vm -t 30 "export HOME=$TEST_GUEST_ADB_HOME ANDROID_ADB_SERVER_PORT=5039 ADB_LOCAL_TRANSPORT_MAX_PORT=5554 ADB_VENDOR_KEYS=/root/rhizo-test-upgrade-adbkey; mkdir -p \$HOME; adb connect $adb_endpoint >/dev/null 2>&1; adb -s $adb_endpoint shell echo ok; adb kill-server >/dev/null 2>&1" 2>&1 | tr -d '\r')
    echo "$connect_out" > "$EV/$leg-adb-connect.log"
    if [[ -z "$adb_path" ]]; then
      fail "[$leg] the guest has no adb client -- run tools/fetch/pools/deb/fetch.sh adb-debs"
    elif [[ "$(tail -1 <<<"$connect_out" | tr -d '[:space:]')" == ok ]]; then
      pass "[$leg] a real 'adb connect' from inside the guest, using the key registered under N-1, reached the upgraded sandbox and ran a command"
    else
      fail "[$leg] 'adb connect' + 'adb shell echo ok' with N-1's own key did not print exactly 'ok' after the upgrade (see $EV/$leg-adb-connect.log): $(tail -3 <<<"$connect_out" | tr '\n' ' ')"
    fi
  fi

  local data_ino_after data_crtime_after
  data_ino_after=$(ssh_vm -t 20 'stat -c %i /var/lib/rhizo/data.img 2>/dev/null' | tr -d '[:space:]')
  data_crtime_after=$(ssh_vm -t 20 'stat -c %W /var/lib/rhizo/data.img 2>/dev/null' | tr -d '[:space:]')
  if [[ -z "$data_crtime_after" || "$data_crtime_after" == 0 ]]; then
    fail "[$leg] could not read a real crtime for /var/lib/rhizo/data.img after the upgrade (crtime='${data_crtime_after:-<empty>}')"
  elif [[ -n "$data_ino_before" && "$data_ino_before" == "$data_ino_after" && "$data_crtime_before" == "$data_crtime_after" ]]; then
    pass "[$leg] data.img's inode and crtime are unchanged across the upgrade (ino=$data_ino_after crtime=$data_crtime_after)"
  else
    fail "[$leg] data.img changed identity across the upgrade: ino $data_ino_before -> $data_ino_after, crtime $data_crtime_before -> $data_crtime_after"
  fi

  step "[$leg] 12a. apt-get remove, falling back to dpkg --remove"
  local remove_marker="rhizo-remove-marker-$$-$RANDOM"
  ssh_vm -t 30 "mkdir -p /var/lib/rhizo && echo $remove_marker > /var/lib/rhizo/.test-remove-marker" >/dev/null 2>&1
  wait_dpkg_free "[$leg] product remove"
  ssh_vm -t 120 'systemd-run --unit=rhizo-test-remove --collect --quiet \
      /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get remove -y rhizo > /var/tmp/remove.log 2>&1; echo apt=\$? >> /var/tmp/remove.log; if ! grep -q \"^apt=0\$\" /var/tmp/remove.log; then dpkg --remove rhizo >> /var/tmp/remove.log 2>&1; echo dpkg=\$? >> /var/tmp/remove.log; fi; echo done > /var/tmp/remove.done"' \
    >/dev/null 2>&1
  local rmdl=$((SECONDS + 900))
  while (( SECONDS < rmdl )); do
    ssh_vm -t 30 'test -e /var/tmp/remove.done' >/dev/null 2>&1 && break
    sleep 2
  done
  out=$(ssh_vm -t 120 'cat /var/tmp/remove.log 2>/dev/null')
  echo "$out" > "$EV/$leg-remove.log"
  echo "$out" | tail -15 | sed 's/^/  /'
  if grep -q '^apt=0$' <<<"$out"; then
    pass "[$leg] apt-get remove succeeded"
  elif grep -q '^dpkg=0$' <<<"$out"; then
    note "[$leg] apt-get remove refused on this vm (expected here: linux-modules-extra's own dependency is unmet, see the comment above)"
    pass "[$leg] dpkg --remove succeeded after apt-get refused"
  else
    fail "[$leg] neither apt-get remove nor dpkg --remove succeeded (see $EV/$leg-remove.log)"
    return 1
  fi

  step "[$leg] 12b. any scheduled post-reboot cleanup unit names only what a non-purge remove may touch"
  local cleanup_read
  cleanup_read=$(ssh_vm -t 30 'if [ -e /etc/systemd/system/rhizo-final-cleanup.service ]; then echo UNIT_PRESENT; cat /etc/systemd/system/rhizo-final-cleanup.service; echo UNIT_END; else echo UNIT_ABSENT; fi')
  echo "$cleanup_read" > "$EV/$leg-final-cleanup-unit.txt"
  case "$cleanup_read" in
    UNIT_ABSENT*)
      note "[$leg] no rhizo-final-cleanup.service was scheduled"
      pass "[$leg] no deferred-cleanup unit to check"
      ;;
    UNIT_PRESENT*)
      local bad_tokens="" unit_verdict
      for token in 'data.img' '/srv/rhizo'; do
        grep -qF "$token" <<<"$cleanup_read" && bad_tokens="$bad_tokens $token"
      done
      if grep -Eq '(^|[ =])/(var/lib|usr/lib|etc|srv)/rhizo([ ;]|$)' <<<"$cleanup_read"; then
        bad_tokens="$bad_tokens whole-word-bare-root-match"
      fi
      unit_verdict=$(python3 "$REPO_ROOT/test/checks/install/teardown/teardown-remove-keeps-data.py" \
          --unit-file "$EV/$leg-final-cleanup-unit.txt" 2>&1) \
        || bad_tokens="$bad_tokens $(grep '^FAIL' <<<"$unit_verdict" | tr '\n' ' ')"
      echo "$unit_verdict" > "$EV/$leg-final-cleanup-unit-verdict.txt"
      if [[ -n "$bad_tokens" ]]; then
        fail "[$leg] rhizo-final-cleanup.service's ExecStart names$bad_tokens (see $EV/$leg-final-cleanup-unit.txt)"
      else
        pass "[$leg] the scheduled cleanup unit names exactly what teardown_deferred_paths 0 allows: no data.img, kept configuration, /srv/rhizo, bare root or purge-only path"
      fi
      ;;
    *)
      fail "[$leg] could not read whether rhizo-final-cleanup.service exists -- ssh returned neither UNIT_PRESENT nor UNIT_ABSENT (see $EV/$leg-final-cleanup-unit.txt)"
      ;;
  esac

  step "[$leg] 12b2. reinstall BEFORE the reboot proves preinst cancels a pending cleanup unit"
  wait_dpkg_free "[$leg] reinstall before reboot (preinst-cancel leg)"
  local reinstall_marks_before reinstall_marks_after
  reinstall_marks_before=$(installer_start_marks)
  test_pkgwin rhizo-install step12b2-reinstall ssh_vm -t 900 '[ -s '"$TEST_APT_OFFLINE_CONF"' ] || { echo APT_RC=NOCONF; exit; }
    cd /root/rhizo-artifact && APT_CONFIG='"$TEST_APT_OFFLINE_CONF"' DEBIAN_FRONTEND=noninteractive apt-get install -y ./rhizo_*.deb 2>&1; rc=$?; echo "APT_RC=$rc"; if [ "$rc" -ne 0 ]; then dpkg -i ./rhizo_*.deb 2>&1; fi' > "$EV/$leg-reinstall-before-reboot.log"
  out=$(cat "$EV/$leg-reinstall-before-reboot.log")
  echo "$out" | tail -15 | sed 's/^/  /'
  reinstall_marks_after=$(installer_start_marks)
  printf '%s\n=== after\n%s\n' "$reinstall_marks_before" "$reinstall_marks_after" > "$EV/$leg-reinstall-before-reboot-start-marks.txt"
  installer_assert_offline_apt "$leg" "$EV/$leg-reinstall-before-reboot.log" "the reinstall before the reboot"
  installer_assert_started_nothing "$leg" "the reinstall before the reboot" "$reinstall_marks_before" "$reinstall_marks_after"
  if grep -q 'reboot to finish the \(install\|upgrade\)' <<<"$out"; then
    pass "[$leg] the reinstall before the reboot asked for the reboot that finishes it"
  else
    fail "[$leg] the reinstall before the reboot never printed 'reboot to finish the install/upgrade' (see $EV/$leg-reinstall-before-reboot.log)"
  fi
  local unconf_reinstall2
  unconf_reinstall2=$(ssh_vm -t 60 'for p in rhizo; do
      [ "$(dpkg-query -W -f="\${db:Status-Abbrev}" $p 2>/dev/null | tr -d " ")" = ii ] || echo $p; done')
  if [[ -z "$unconf_reinstall2" ]]; then
    pass "[$leg] the reinstall-before-reboot installed and configured the package"
  else
    fail "[$leg] the reinstall-before-reboot left these unconfigured: $unconf_reinstall2 (see $EV/$leg-reinstall-before-reboot.log)"
    return 1
  fi
  local cleanup_read2
  cleanup_read2=$(ssh_vm -t 30 'if [ -e /etc/systemd/system/rhizo-final-cleanup.service ]; then echo UNIT_PRESENT; else echo UNIT_ABSENT; fi')
  echo "$cleanup_read2" > "$EV/$leg-final-cleanup-unit-after-reinstall.txt"
  case "$cleanup_read2" in
    UNIT_ABSENT*)
      pass "[$leg] preinst canceled the pending cleanup unit -- it is gone right after this reinstall" ;;
    UNIT_PRESENT*)
      fail "[$leg] rhizo-final-cleanup.service is still scheduled after a reinstall" ;;
    *)
      fail "[$leg] could not read whether rhizo-final-cleanup.service exists after the reinstall" ;;
  esac

  step "[$leg] 12b2b. reboot the reinstall, and confirm nothing the cleanup unit would have removed is gone"
  reboot_and_wait "[$leg] reinstall-before-reboot" || return 1
  local survive
  survive=$(ssh_vm -t 30 '[ -e /usr/lib/rhizo/tools/app-events.py ] && echo APPWATCH_OK || echo APPWATCH_GONE; [ -s /var/lib/rhizo/data.img ] && echo DATAIMG_OK || echo DATAIMG_GONE')
  if grep -q APPWATCH_OK <<<"$survive"; then
    pass "[$leg] the reinstalled appwatch helper survived the reboot after the preinst-cancel leg"
  else
    fail "[$leg] the reinstalled appwatch helper did not survive the reboot after the preinst-cancel leg: $survive"
  fi
  if grep -q DATAIMG_OK <<<"$survive"; then
    pass "[$leg] data.img survived the reboot after the preinst-cancel leg"
  else
    fail "[$leg] data.img did not survive the reboot after the preinst-cancel leg: $survive"
  fi
  local remove_marker_read2
  remove_marker_read2=$(ssh_vm -t 30 'cat /var/lib/rhizo/.test-remove-marker 2>/dev/null' | tr -d '[:space:]')
  if [[ "$remove_marker_read2" == "$remove_marker" ]]; then
    pass "[$leg] the pre-removal marker survived the preinst-cancel leg's reboot byte for byte"
  else
    fail "[$leg] the pre-removal marker read back as '${remove_marker_read2:-<gone>}' after the preinst-cancel leg's reboot, wanted '$remove_marker'"
  fi

  step "[$leg] 12b3. remove again, so the rest of step 12 continues from the removed state"
  wait_dpkg_free "[$leg] second remove (restoring state after the preinst-cancel leg)"
  ssh_vm -t 120 'systemd-run --unit=rhizo-test-remove2 --collect --quiet \
      /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get remove -y rhizo > /var/tmp/remove2.log 2>&1; echo apt=\$? >> /var/tmp/remove2.log; if ! grep -q \"^apt=0\$\" /var/tmp/remove2.log; then dpkg --remove rhizo >> /var/tmp/remove2.log 2>&1; echo dpkg=\$? >> /var/tmp/remove2.log; fi; echo done > /var/tmp/remove2.done"' \
    >/dev/null 2>&1
  local rmdl2=$((SECONDS + 900))
  while (( SECONDS < rmdl2 )); do
    ssh_vm -t 30 'test -e /var/tmp/remove2.done' >/dev/null 2>&1 && break
    sleep 2
  done
  out=$(ssh_vm -t 120 'cat /var/tmp/remove2.log 2>/dev/null')
  echo "$out" > "$EV/$leg-remove-again.log"
  echo "$out" | tail -15 | sed 's/^/  /'
  if grep -q '^apt=0$' <<<"$out" || grep -q '^dpkg=0$' <<<"$out"; then
    pass "[$leg] removed again after the preinst-cancel leg, ready to continue as a normal removal"
  else
    fail "[$leg] the second remove (after the preinst-cancel leg) did not succeed (see $EV/$leg-remove-again.log)"
    return 1
  fi

  step "[$leg] 12c. reboot after the remove"
  reboot_and_wait "[$leg] post-remove" || return 1

  step "[$leg] 12d. host-snapshot diff: apt remove kept only what the census explains"
  take_snapshot "[$leg] after-remove" "$EV/$leg-snapshot-after-remove.tsv" || return 1
  local diffout diffrc
  host_census_snapshot_diff "$leg" remove installer
  diffrc=$?
  diffout=$(cat "$EV/$leg-snapshot-diff-remove.txt" 2>/dev/null)
  if (( diffrc == 0 )); then
    pass "[$leg] host-snapshot diff (remove): every difference is allowlisted, every allowlist row for this phase matched something"
  else
    fail "[$leg] host-snapshot diff (remove) found unexplained state ($(grep -c '^FAIL' <<<"$diffout") finding(s), first: $(grep -m1 '^FAIL' <<<"$diffout"); full list in $EV/$leg-snapshot-diff-remove.txt)"
  fi

  step "[$leg] 12e. reinstall after a plain remove"
  wait_dpkg_free "[$leg] reinstall after remove"
  test_pkgwin rhizo-install step12e-reinstall ssh_vm -t 900 '[ -s '"$TEST_APT_OFFLINE_CONF"' ] || { echo APT_RC=NOCONF; exit; }
    cd /root/rhizo-artifact && APT_CONFIG='"$TEST_APT_OFFLINE_CONF"' DEBIAN_FRONTEND=noninteractive apt-get install -y ./rhizo_*.deb 2>&1; rc=$?; echo "APT_RC=$rc"; if [ "$rc" -ne 0 ]; then dpkg -i ./rhizo_*.deb 2>&1; fi' > "$EV/$leg-reinstall-after-remove.log"
  out=$(cat "$EV/$leg-reinstall-after-remove.log")
  echo "$out" | tail -15 | sed 's/^/  /'
  installer_assert_offline_apt "$leg" "$EV/$leg-reinstall-after-remove.log" "the reinstall after a plain remove"
  if grep -qF "$(installer_reboot_notice)" <<<"$out"; then
    pass "[$leg] the reinstall asked for a reboot"
  else
    fail "[$leg] the reinstall after a plain remove did not ask for a reboot (see $EV/$leg-reinstall-after-remove.log)"
    return 1
  fi
  local prep2_before_lines
  prep2_before_lines=$(installer_prepare_log_lines)
  if [[ -z "$prep2_before_lines" ]]; then
    fail "[$leg] could not read prepare.log's line count before the reinstall's reboot"
    return 1
  fi
  reboot_and_wait "[$leg] reinstall-after-remove" || return 1

  step "[$leg] 12g. prepare re-runs after reinstall, keeps data, and a real app still launches"
  installer_await_prepare "$leg" "$EV/$leg-prepare-after-remove-reinstall.log" "$prep2_before_lines" \
    " after the remove+reinstall cycle" || return 1
  local ok_line2
  ok_line2=$(grep -m1 'RHIZO_PREPARE_OK' <<<"$INSTALLER_PREPARE_OUT")
  if [[ "$ok_line2" == *"data=kept"* ]]; then
    pass "[$leg] prepare reported data=kept -- the reinstall did not touch the surviving data.img"
  else
    fail "[$leg] prepare did not report data=kept after a remove+reinstall over a surviving data.img: $ok_line2"
  fi
  local remove_marker_read
  remove_marker_read=$(ssh_vm -t 30 'cat /var/lib/rhizo/.test-remove-marker 2>/dev/null' | tr -d '[:space:]')
  if [[ "$remove_marker_read" == "$remove_marker" ]]; then
    pass "[$leg] the marker written before removal survived the remove+reinstall cycle byte for byte"
  else
    fail "[$leg] the marker written before removal read back as '${remove_marker_read:-<gone>}', wanted '$remove_marker'"
  fi
  if ! ../../vm/start/start-sway.sh >"$EV/$leg-sway-after-remove-reinstall.log" 2>&1; then
    fail "[$leg] sway did not start after the remove+reinstall reboot (see $EV/$leg-sway-after-remove-reinstall.log)"
    return 1
  fi
  if ! swaycmd "-t get_version" 30 >/dev/null 2>&1; then
    fail "[$leg] sway started but does not answer on its ipc socket (after remove+reinstall)"
    return 1
  fi
  local t0b booted2=0
  t0b=$(guest_uptime)
  ssh_vm -t 600 'systemctl is-active androidd.service >/dev/null 2>&1 || systemctl start androidd.service' \
    >"$EV/$leg-start-after-remove-reinstall.log" 2>&1
  wait_sandbox_started 420 "$t0b" && booted2=1
  if (( ! booted2 )); then
    fail "[$leg] the sandbox did not reach boot_completed after the remove+reinstall cycle"
    return 1
  fi
  local init_pid2 pkgact2
  init_pid2=$(resolve_init_pid 120)
  if [[ -z "$init_pid2" ]]; then
    fail "[$leg] no Android init after the remove+reinstall cycle"
    return 1
  fi
  INIT="$init_pid2"; export INIT
  pkgact2=$(android_sh "$init_pid2" "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.android.settings" \
           | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' | tail -1)
  if [[ "$pkgact2" != */* ]]; then
    pkgact2=$(android_sh "$init_pid2" "cmd package query-activities -a android.intent.action.MAIN -c android.intent.category.LAUNCHER" \
             | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' | head -1)
  fi
  if [[ "$pkgact2" != */* ]]; then
    fail "[$leg] the device named no launchable activity after the remove+reinstall cycle"
    return 1
  fi
  ssh_vm -t 300 "/usr/lib/rhizo/tools/rhizo-launch.sh ${pkgact2%%/*} ${pkgact2##*/} >/tmp/rhizo-test-launch2.log 2>&1; echo rc=\$?" \
    > "$EV/$leg-launch-after-remove-reinstall-rc.log" 2>&1
  ssh_vm -t 60 'tail -40 /run/rhizo-launch/rhizo-launch.log 2>/dev/null' \
    > "$EV/$leg-launch-after-remove-reinstall.log" 2>&1
  local launched2 cdisp2
  launched2=$(cat "$EV/$leg-launch-after-remove-reinstall.log" 2>/dev/null | tail -20)
  cdisp2=$(grep -o 'cdisplay=[0-9]*' <<<"$launched2" | tail -1 | cut -d= -f2)
  if [[ -z "$cdisp2" ]]; then
    fail "[$leg] the post-reinstall launch reported no cdisplay= to screenshot"
  else
    local mdeadline2=$((SECONDS + 180)) mapped2=0
    while (( SECONDS < mdeadline2 )); do
      if mapped_window_rect "$cdisp2" >/dev/null 2>&1; then mapped2=1; break; fi
      sleep 5
    done
    if (( mapped2 )); then
      assert_window_painted "$leg-app-after-remove-reinstall" "$cdisp2"
    else
      fail "[$leg] no toplevel ever mapped on display $cdisp2 after the remove+reinstall cycle within 180s"
    fi
  fi

  step "[$leg] 12h. purge removes what a plain remove keeps"
  wait_dpkg_free "[$leg] product purge"
  local kernel_purge=""
  [[ -z "$kernel_pkgs" ]] || kernel_purge="dpkg --purge$kernel_pkgs >> /var/tmp/purge.log 2>&1; echo kernel=\\\$? >> /var/tmp/purge.log; "
  ssh_vm -t 120 'systemd-run --unit=rhizo-test-purge --collect --quiet \
      /bin/sh -c "DEBIAN_FRONTEND=noninteractive apt-get purge -y rhizo > /var/tmp/purge.log 2>&1; echo apt=\$? >> /var/tmp/purge.log; if ! grep -q \"^apt=0\$\" /var/tmp/purge.log; then dpkg --purge rhizo >> /var/tmp/purge.log 2>&1; echo dpkg=\$? >> /var/tmp/purge.log; fi; '"$kernel_purge"'DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y >> /var/tmp/purge.log 2>&1; echo autoremove=\$? >> /var/tmp/purge.log; echo done > /var/tmp/purge.done"' \
    >/dev/null 2>&1
  local pdl=$((SECONDS + 900))
  while (( SECONDS < pdl )); do
    ssh_vm -t 30 'test -e /var/tmp/purge.done' >/dev/null 2>&1 && break
    sleep 2
  done
  out=$(ssh_vm -t 120 'cat /var/tmp/purge.log 2>/dev/null')
  echo "$out" > "$EV/$leg-uninstall.log"
  echo "$out" | tail -15 | sed 's/^/  /'
  if grep -q '^apt=0$' <<<"$out" || grep -q '^dpkg=0$' <<<"$out"; then
    pass "[$leg] the purge succeeded"
  else
    fail "[$leg] neither apt-get purge nor dpkg --purge succeeded (see $EV/$leg-uninstall.log)"
  fi
  if [[ -n "$kernel_pkgs" ]]; then
    if grep -q '^kernel=0$' <<<"$out"; then
      pass "[$leg] dpkg --purge of the Rhizo kernel succeeded:$kernel_pkgs"
    else
      fail "[$leg] dpkg --purge of the Rhizo kernel did not succeed (see $EV/$leg-uninstall.log)"
    fi
  fi
  if grep -q '^autoremove=0$' <<<"$out"; then
    pass "[$leg] apt-get autoremove --purge succeeded"
  else
    fail "[$leg] apt-get autoremove --purge did not succeed (see $EV/$leg-uninstall.log)"
  fi
  wait_dpkg_free "[$leg] after the purge's autoremove"
  host_census_apt_kept_record "$leg" "[$leg] 12h"
  local left
  left=$(ssh_vm -t 60 '
    for p in /etc/default/grub.d/90-rhizo.cfg /var/lib/rhizo /usr/lib/rhizo /etc/rhizo \
             /etc/modules-load.d/rhizo.conf /usr/bin/rhizo /var/cache/rhizo /var/log/rhizo; do
      [ -e "$p" ] && echo "LEFT $p"
    done
    grep -q "^/swapfile " /etc/fstab 2>/dev/null && echo "LEFT /etc/fstab swap line"
    [ -f /swapfile ] && echo "LEFT /swapfile"
    systemctl list-unit-files "rhizo*" androidd.service --no-legend 2>/dev/null | sed "s/^/LEFT unit /"
    true')
  case "$left" in
    *90-rhizo.cfg*|*swapfile*|*fstab*)
      echo "$left" | sed 's/^/  /'; echo "$left" >> "$SUMMARY"
      fail "[$leg] the bootloader change or the swapfile survived the purge" ;;
    *) pass "[$leg] the bootloader change and the swapfile are gone" ;;
  esac
  record_leftovers "$EV/$leg-leftovers-pre-reboot.txt"

  step "[$leg] 12i. after the purge reboot, the host is stock"
  reboot_and_wait "[$leg] post-purge" || return 1
  local cdl=$((SECONDS + 300)) leftover=""
  while (( SECONDS < cdl )); do
    leftover=$(ssh_vm -t 60 '
      for p in /etc/default/grub.d/90-rhizo.cfg /var/lib/rhizo /usr/lib/rhizo /etc/rhizo \
               /etc/modules-load.d/rhizo.conf /usr/bin/rhizo /var/cache/rhizo /var/log/rhizo; do
        [ -e "$p" ] && echo "LEFT $p"
      done
      grep -q "^/swapfile " /etc/fstab 2>/dev/null && echo "LEFT /etc/fstab swap line"
      [ -f /swapfile ] && echo "LEFT /swapfile"
      true')
    [[ -z "$leftover" ]] && break
    sleep 3
  done
  record_leftovers "$EV/$leg-leftovers-post-reboot.txt"
  if [[ -n "$leftover" ]]; then
    echo "$leftover" | sed 's/^/  /'
    echo "$leftover" >> "$SUMMARY"
    fail "[$leg] purge left files behind after the reboot (what each holds and what still runs: $EV/$leg-leftovers-post-reboot.txt, and before the reboot: $EV/$leg-leftovers-pre-reboot.txt)"
  else
    pass "[$leg] nothing of Rhizo's remains on disk"
  fi
  local lsm_end
  lsm_end=$(ssh_vm -t 20 'cat /sys/kernel/security/lsm 2>/dev/null')
  note "[$leg] after purge and reboot: lsm=$lsm_end"
  case ",$lsm_end," in
    *,apparmor,*) pass "[$leg] apparmor is the active LSM again" ;;
    *) fail "[$leg] apparmor did not come back (lsm=$lsm_end)" ;;
  esac
  case ",$lsm_end," in *,selinux,*) fail "[$leg] selinux is STILL active after purge" ;; esac

  step "[$leg] 12j. host-snapshot diff: apt purge returns the host to stock"
  take_snapshot "[$leg] after-purge" "$EV/$leg-snapshot-after-purge.tsv" || return 1
  local diffout2 diffrc2
  host_census_snapshot_diff "$leg" purge installer
  diffrc2=$?
  diffout2=$(cat "$EV/$leg-snapshot-diff-purge.txt" 2>/dev/null)
  if (( diffrc2 == 0 )); then
    pass "[$leg] host-snapshot diff (purge): the host matches its pre-install state exactly, modulo the allowlist"
  else
    fail "[$leg] host-snapshot diff (purge) found unexplained state ($(grep -c '^FAIL' <<<"$diffout2") finding(s), first: $(grep -m1 '^FAIL' <<<"$diffout2"); full list in $EV/$leg-snapshot-diff-purge.txt)"
  fi

  return 0
}

if (( SELFTEST )); then
  step "selftest: the system test must catch a broken install"
  before=$FAILED
  left="LEFT /etc/default/grub.d/90-rhizo.cfg"
  [[ -n "$left" ]] && fail "selftest: a leftover file is reported"
  if (( FAILED > before )); then
    log "  selftest OK: the removal assertion fails when something is left behind"
    FAILED=$before
  else
    fail "selftest: the removal assertion did NOT fire on a leftover path"
  fi

  before=$FAILED
  assert_no_fallback_markers "selftest" "a binary" $'libc.so\nRhizoKeyMintDevice::generateKey\nrhizo_keymint.cpp'
  if (( FAILED > before )); then
    log "  selftest OK: a binary carrying the fallback's markers is caught"
    FAILED=$before
  else
    fail "selftest: the fallback-marker assertion did NOT fire on RhizoKeyMintDevice"
  fi
  before=$FAILED
  assert_keystore_probe "selftest" $'RHIZO_KEYSTORE_PROBE op=ec_p256_generate_sign_verify result=fail err=ProviderException: Failed to generate key pair cause=KeyStoreException: Algorithm not supported\nRHIZO_KEYSTORE_PROBE op=hmac_sha256_import_mac result=ok\nRHIZO_KEYSTORE_PROBE done ok=2 fail=1'
  if (( FAILED > before )); then
    log "  selftest OK: a probe reporting a refused key is caught"
    FAILED=$before
  else
    fail "selftest: the keystore probe assertion did NOT fire on fail=1"
  fi
  before=$FAILED
  assert_keymint_staged "selftest" "[   9.9] RHIZO_MARKER rhizo-keymint-service NOT FOUND at /usr/lib/rhizo/rhizo-keymint-service"
  if (( FAILED > before )); then
    log "  selftest OK: the launcher reporting no KeyMint binary to stage is caught"
    FAILED=$before
  else
    fail "selftest: the staging assertion did NOT fire on the launcher's NOT FOUND marker"
  fi
  before=$FAILED
  assert_keymint_staged "selftest" ""
  if (( FAILED > before )); then
    log "  selftest OK: a boot with no staging marker at all is caught"
    FAILED=$before
  else
    fail "selftest: the staging assertion did NOT fire on a missing marker"
  fi
  before=$FAILED
  assert_keymint_staged "selftest" "[   9.9] rhizo-keymint-service staged on /vendor/bin/hw"
  if (( FAILED > before )); then
    fail "selftest: the staging assertion fired on the launcher's own success marker"
  else
    log "  selftest OK: the real staging marker passes"
  fi

  before=$FAILED
  assert_keystore_probe "selftest" $'RHIZO_KEYSTORE_PROBE op=ec_p256_generate_sign_verify result=ok security_level=SOFTWARE'
  if (( FAILED > before )); then
    log "  selftest OK: a probe with no done line is caught"
    FAILED=$before
  else
    fail "selftest: the keystore probe assertion did NOT fire on a missing done line"
  fi
  before=$FAILED
  assert_keystore_probe "selftest" $'RHIZO_KEYSTORE_PROBE op=ec_p256_generate_sign_verify result=ok\nRHIZO_KEYSTORE_PROBE op=rsa_2048_generate_sign_verify result=ok\nRHIZO_KEYSTORE_PROBE op=hmac_sha256_import_mac result=ok\nRHIZO_KEYSTORE_PROBE done ok=3 fail=0'
  if (( FAILED > before )); then
    fail "selftest: the keystore probe assertion fired on a clean three-of-three run"
  else
    log "  selftest OK: a clean three-of-three probe passes"
  fi

  before=$FAILED
  ssh_vm() { echo 6.8.0-136-generic; }
  installer_assert_rhizo_kernel "selftest" "a reboot"
  if (( FAILED > before )); then
    log "  selftest OK: a reboot into a stock kernel instead of the Rhizo kernel is caught"
    FAILED=$before
  else
    fail "selftest: the Rhizo kernel assertion did NOT fire on 6.8.0-136-generic"
  fi
  before=$FAILED
  ssh_vm() { if [[ "${*: -1}" == 'uname -r' ]]; then echo 7.1.0-rc1-rhizo; else echo rc=0; fi; }
  installer_assert_rhizo_kernel "selftest" "a reboot"
  if (( FAILED > before )); then
    fail "selftest: the Rhizo kernel assertion fired on 7.1.0-rc1-rhizo with kernel-check.sh passing"
  else
    log "  selftest OK: a reboot into the Rhizo kernel that kernel-check.sh passes is accepted"
  fi
  before=$FAILED
  ssh_vm() { if [[ "${*: -1}" == 'uname -r' ]]; then echo 7.1.0-rc1-rhizo; else printf 'no built-in binder\nrc=1\n'; fi; }
  installer_assert_rhizo_kernel "selftest" "a reboot"
  if (( FAILED > before )); then
    log "  selftest OK: a Rhizo kernel kernel-check.sh refuses is caught"
    FAILED=$before
  else
    fail "selftest: the Rhizo kernel assertion did NOT fire when kernel-check.sh refused the kernel"
  fi

  before=$FAILED
  ssh_vm() { printf 'SESSION=yes\nExecMainStatus=0\nExecMainStartTimestampMonotonic=63123456\nDONE\n'; }
  st_t0=$(installer_session_start_uptime "selftest")
  if (( FAILED == before )) && [[ "$st_t0" == 63.123456 ]]; then
    log "  selftest OK: a background start by rhizo-session-start.service is read as its uptime"
  else
    fail "selftest: a session start at 63123456us read '$st_t0'"
  fi
  before=$FAILED
  ssh_vm() { printf 'ExecMainStatus=0\nExecMainStartTimestampMonotonic=0\nDONE\n'; }
  installer_session_start_uptime "selftest" >/dev/null
  if (( FAILED > before )); then
    log "  selftest OK: an active androidd that rhizo-session-start.service did not start is caught"
    FAILED=$before
  else
    fail "selftest: an active androidd with no session start was accepted"
  fi

  st_dir=$(mktemp -d) || exit 1
  mkdir -p "$st_dir/pkg/DEBIAN"
  printf 'Package: linux-image-rhizo\nVersion: 1\nArchitecture: amd64\nMaintainer: x <x@invalid>\nDescription: x\n' > "$st_dir/pkg/DEBIAN/control"
  dpkg-deb -Znone --build "$st_dir/pkg" "$st_dir/linux-image-rhizo_1_amd64.deb" >/dev/null
  : > "$st_dir/linux-headers-rhizo_1_amd64.deb"
  st_names=$(installer_kernel_deb_packages "$st_dir/linux-image-rhizo_1_amd64.deb")
  if [[ "$st_names" == " linux-image-rhizo" ]]; then
    log "  selftest OK: a kernel .deb's Package field is read as its name"
  else
    fail "selftest: the kernel .deb names read '$st_names', want ' linux-image-rhizo'"
  fi
  if st_names=$(installer_kernel_deb_packages "$st_dir/linux-image-rhizo_1_amd64.deb" "$st_dir/linux-headers-rhizo_1_amd64.deb" 2>"$st_dir/err"); then
    fail "selftest: an unreadable kernel .deb was named '$st_names' instead of failing"
  elif [[ "$st_names" == "could not read the Package field of linux-headers-rhizo_1_amd64.deb"* ]]; then
    log "  selftest OK: an unreadable kernel .deb fails naming the file"
  else
    fail "selftest: an unreadable kernel .deb failed with '$st_names', which does not name linux-headers-rhizo_1_amd64.deb"
  fi
  rm -rf "$st_dir"

  if (( FAILED )); then
    log "test-installer --selftest: FAILED"
    exit 1
  fi
  log "test-installer --selftest: the system test can still fail"
  exit 0
fi

if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then
  (( FAILED )) || run_leg_cachyos base
else
  run_leg base
fi

{
  echo
  echo "instance: $RHIZO_VM   boot mode: grub   new disk: $(( ! REUSE_DISK ))   legs: $LEG"
  echo "result: $( ((FAILED)) && echo FAIL || echo PASS )"
} >> "$SUMMARY"

if (( FAILED )); then
  restore_settled_link
  test_record_verdict FAILED "leg=$LEG$VERDICT_REDUCTION"
  log "test-installer: FAILED with $FAILED failure(s) -- see $SUMMARY"
  exit 1
fi
restore_settled_link
rig_result_keep "$EV/summary.txt"
test_record_verdict PASSED "leg=$LEG$VERDICT_REDUCTION" "$UPGRADE_VERDICT_INFO"
log "test-installer: PASSED -- see $SUMMARY"
