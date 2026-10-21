#!/bin/bash
# test Ubuntu security updates against a local repo
set -uo pipefail

# reject a masked or disabled apt timer
uul_assert_timer_enabled() {
  local label="$1" unit="$2" state="$3"
  state="${state//$'\r'/}"
  if [[ -z "${state// /}" ]]; then
    fail "$label: $unit: systemctl is-enabled returned nothing"
    return 1
  fi
  case "$state" in
    enabled|enabled-runtime)
      pass "$label: $unit is $state"
      return 0
      ;;
    masked|masked-runtime)
      fail "$label: $unit is $state"
      return 1
      ;;
    *)
      fail "$label: $unit is-enabled reported '$state', wanted enabled"
      return 1
      ;;
  esac
}

# fail on Permission denied in the log
uul_assert_no_permission_denied() {
  local label="$1" text="$2" hit
  if [[ -z "${text// /}" ]]; then
    fail "$label: log text to scan for Permission denied was empty"
    return 1
  fi
  hit=$(grep -m1 -F 'Permission denied' <<<"$text" || true)
  if [[ -n "$hit" ]]; then
    fail "$label: 'Permission denied' in the log: ${hit:0:200}"
    return 1
  fi
  pass "$label: no 'Permission denied' in the log"
  return 0
}

# fail on any dpkg --audit output
uul_assert_dpkg_audit_empty() {
  local label="$1" text="$2"
  if [[ -n "${text// /}" ]]; then
    fail "$label: dpkg --audit is not empty: ${text:0:300}"
    return 1
  fi
  pass "$label: dpkg --audit is empty"
  return 0
}

# fail on half-configured dpkg -l packages
uul_assert_dpkg_consistent() {
  local label="$1" text="$2" bad
  if [[ -z "${text// /}" ]]; then
    fail "$label: dpkg -l output to check was empty"
    return 1
  fi
  bad=$(awk '$1 ~ /^[^i]i$/ || $1 ~ /^i[^i]$/ {print}' <<<"$text")
  if [[ -n "$bad" ]]; then
    fail "$label: dpkg -l shows half-configured package(s): $(head -3 <<<"$bad" | tr '\n' '|')"
    return 1
  fi
  pass "$label: dpkg -l shows no half-configured package"
  return 0
}

# compare guest package versions with the manifest
uul_assert_systemd_stack_versions() {
  local label="$1" manifest="$2" installed="$3"
  if [[ -z "${manifest// /}" ]]; then
    fail "$label: MANIFEST.tsv text was empty"
    return 1
  fi
  if [[ -z "${installed// /}" ]]; then
    fail "$label: the guest's dpkg-query output was empty"
    return 1
  fi
  local n=0 bad=0 pkg ver cat rest have
  while IFS=$'\t' read -r pkg ver _ cat rest; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    [[ "$cat" == systemd-stack ]] || continue
    n=$((n + 1))
    have=$(awk -F'\t' -v p="$pkg" '$1==p{print $2}' <<<"$installed")
    if [[ -z "$have" ]]; then
      fail "$label: $pkg is not reported installed on the guest at all (wanted $ver)"
      bad=1
      continue
    fi
    if [[ "$have" != "$ver" ]]; then
      fail "$label: $pkg is $have on the guest, the pool carries $ver"
      bad=1
    fi
  done <<<"$manifest"
  if (( n == 0 )); then
    fail "$label: MANIFEST.tsv named no systemd-stack row"
    return 1
  fi
  if (( bad )); then
    return 1
  fi
  pass "$label: all $n systemd-stack package(s) match the pool's versions"
  return 0
}

# check modules-load.d/rhizo.conf names no binder or compat module
uul_assert_conf_no_module() {
  local label="$1" text="$2" hit
  hit=$(grep -xE 'binder_linux|rhizo_binder_pidns|ashmem_compat|ikconfig_compat' <<<"$text" || true)
  if [[ -n "$hit" ]]; then
    fail "$label: /etc/modules-load.d/rhizo.conf names $(tr '\n' ' ' <<<"$hit")"
    return 1
  fi
  pass "$label: /etc/modules-load.d/rhizo.conf names no binder or compat module"
  return 0
}

# compare the read value with the given value
uul_assert_equal() {
  local label="$1" what="$2" want="$3" have="$4"
  have="${have//$'\r'/}"
  if [[ -z "${have// /}" ]]; then
    fail "$label: $what read empty (wanted $want)"
    return 1
  fi
  if [[ "$have" != "$want" ]]; then
    fail "$label: $what is '$have', wanted '$want'"
    return 1
  fi
  pass "$label: $what is $want"
  return 0
}

# check rhizo.conf for the kernel header line
uul_assert_rhizo_conf_kernel_header() {
  local label="$1" kver="$2" text="$3" hit
  if [[ -z "${text// /}" ]]; then
    fail "$label: /etc/modules-load.d/rhizo.conf read empty"
    return 1
  fi
  hit=$(grep -m1 -E "^# kernel=${kver//./\\.}\$" <<<"$text" || true)
  if [[ -z "$hit" ]]; then
    fail "$label: /etc/modules-load.d/rhizo.conf carries no '# kernel=$kver' header"
    return 1
  fi
  pass "$label: rhizo.conf header carries kernel=$kver"
  return 0
}

UUL_PREPARED_MARKERS_CMD="if k=\$(journalctl -k -b -o cat --no-pager 2>/dev/null) && [ -n \"\$k\" ]; then printf '%s\\n' \"\$k\" | grep -aoE '^Linux version [^ ]+|RHIZO_MARKER prepared(_refused)?=[^ ]*'; else echo KLOG_UNREADABLE; fi; echo DONE"
# assert all of the launches bound the prepared tree
uul_assert_prepared_accepted() {
  local label="$1" kver="$2" text="${3//$'\r'/}" refused accepted
  if [[ "$text" != *DONE* ]]; then
    fail "$label: this boot's prepared-tree markers were not read whole (no DONE)"
    return 1
  fi
  if [[ "$text" == *KLOG_UNREADABLE* ]]; then
    fail "$label: this boot's kernel log could not be read from the journal"
    return 1
  fi
  if ! grep -qxF "Linux version $kver" <<<"$text"; then
    fail "$label: the kernel log read holds no 'Linux version $kver' line ($(grep -m1 '^Linux version' <<<"$text" || echo none))"
    return 1
  fi
  refused=$(grep -m1 -oE 'RHIZO_MARKER prepared_refused=[^ ]*' <<<"$text")
  if [[ -n "$refused" ]]; then
    fail "$label: on $kver a launch refused the prepared tree (${refused#RHIZO_MARKER }) and took the copy path"
    return 1
  fi
  accepted=$(grep -m1 -oE 'RHIZO_MARKER prepared=[^ ]+' <<<"$text")
  if [[ -z "$accepted" ]]; then
    fail "$label: no launch on $kver logged RHIZO_MARKER prepared="
    return 1
  fi
  pass "$label: every launch on $kver bound the prepared tree (${accepted#RHIZO_MARKER })"
  return 0
}

UUL_PKGLIST_END="UUL_PKGLIST_END"
# assert the fetched package list matches the pool
uul_assert_fetched_pool() {
  local label="$1" want="$2" text="$3" rows n have path
  text="${text//$'\r'/}"
  if [[ -z "$want" ]]; then
    fail "$label: the pool's own Packages sha256 is empty"
    return 1
  fi
  if ! grep -qx "$UUL_PKGLIST_END" <<<"$text"; then
    fail "$label: the guest's fetched-Packages read never reached its end marker: ${text:0:200}"
    return 1
  fi
  rows=$(sed -n "/^${UUL_PKGLIST_END}\$/q;p" <<<"$text" | grep -E '^[0-9a-f]{64}  ' || true)
  n=0
  [[ -n "$rows" ]] && n=$(wc -l <<<"$rows")
  if (( n == 0 )); then
    fail "$label: the guest holds no fetched Packages list for the served repo under /var/lib/apt/lists"
    return 1
  fi
  if (( n > 1 )); then
    fail "$label: the guest holds $n Packages lists for the served repo: $(tr '\n' '|' <<<"$rows")"
    return 1
  fi
  have="${rows%%  *}"
  path="${rows#*  }"
  if [[ "$have" != "$want" ]]; then
    fail "$label: the guest's fetched Packages is not the pool this leg reads its MANIFEST from -- $path sha256=$have, pool Packages sha256=$want"
    return 1
  fi
  pass "$label: the guest's fetched Packages ($path) is byte-identical to the pool's"
  return 0
}

# wait for the dpkg lock to clear
uul_wait_dpkg_free() {
  local deadline=$((SECONDS + ${1:-300}))
  while (( SECONDS < deadline )); do
    if ssh_vm -t 30 'fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 && exit 1; exit 0' >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  return 1
}

# wait for a unit to stop running
uul_wait_unit_settle() {
  local unit="$1" deadline_s="${2:-1800}" deadline state
  deadline=$((SECONDS + deadline_s))
  while (( SECONDS < deadline )); do
    state=$(ssh_vm -t 20 "systemctl is-active $unit" 2>/dev/null | tr -d '[:space:]')
    case "$state" in
      inactive) echo inactive; return 0 ;;
      failed) echo failed; return 0 ;;
      active|activating|reloading) sleep 10 ;;
      *) sleep 10 ;;
    esac
  done
  echo timeout
  return 1
}

# run the callback command line
uul_run_cb() {
  local -a cb
  read -ra cb <<<"$1"
  shift
  (( ${#cb[@]} )) || return 127
  "${cb[@]}" "$@"
}

# check a callback names a command
uul_check_cb() {
  local -a cb
  read -ra cb <<<"$2"
  (( ${#cb[@]} )) || return 0
  type -t "${cb[0]}" >/dev/null 2>&1 && return 0
  fail "ubuntu-update: $1 '$2' names no function or command ('${cb[0]}')"
  return 1
}

# update the guest from the package pool
ubuntu_update_leg() {
  local repo_url="$1" pool_dir="$2" reboot_fn="$3" boot_completed_fn="$4" launch_fixture_fn="$5"
  local manifest="$pool_dir/MANIFEST.tsv"
  [[ -n "$reboot_fn" ]] || { fail "ubuntu-update: no reboot_fn given"; return 1; }
  uul_check_cb reboot_fn "$reboot_fn" || return 1
  uul_check_cb boot_completed_fn "$boot_completed_fn" || return 1
  uul_check_cb launch_fixture_fn "$launch_fixture_fn" || return 1
  [[ -r "$manifest" ]] || { fail "ubuntu-update: no $manifest -- run tools/fetch/pools/deb/ubuntu-update-debs.sh first"; return 1; }

  local kver
  kver=$(awk -F'\t' '$4=="kernel" && $1 ~ /^linux-image-[0-9]/ {print $1; exit}' "$manifest")
  kver="${kver#linux-image-}"
  if [[ -z "$kver" ]]; then
    fail "ubuntu-update: MANIFEST.tsv names no linux-image-<ver> kernel row"
    return 1
  fi
  local pool_sha repo_hostport
  if [[ ! -s "$pool_dir/Packages" ]]; then
    fail "ubuntu-update: no non-empty $pool_dir/Packages"
    return 1
  fi
  pool_sha=$(sha256sum "$pool_dir/Packages" | cut -d' ' -f1)
  repo_hostport="${repo_url#*://}"
  repo_hostport="${repo_hostport%%/*}"
  if [[ ! "$repo_hostport" =~ ^[A-Za-z0-9.:-]+$ ]]; then
    fail "ubuntu-update: cannot take a host:port apt would name its lists after from '$repo_url'"
    return 1
  fi
  local rkver
  rkver=$(ssh_vm -t 20 'uname -r' | tr -d '[:space:]')
  if [[ "$rkver" != *-rhizo ]]; then
    fail "ubuntu-update: the guest runs '${rkver:-<unread>}' before the update, not the Rhizo kernel"
    return 1
  fi
  step "ubuntu-update: apt's own timers are enabled, never masked"
  local daily_state daily_upgrade_state
  daily_state=$(ssh_vm -t 20 'systemctl is-enabled apt-daily.timer 2>&1')
  daily_upgrade_state=$(ssh_vm -t 20 'systemctl is-enabled apt-daily-upgrade.timer 2>&1')
  uul_assert_timer_enabled "ubuntu-update" "apt-daily.timer" "$daily_state"
  uul_assert_timer_enabled "ubuntu-update" "apt-daily-upgrade.timer" "$daily_upgrade_state"

  step "ubuntu-update: point the guest's apt at the served pool, and only it"
  ssh_vm -t 20 'cp -a /etc/apt/sources.list /etc/apt/.rhizo-leg-sources.list.bak 2>/dev/null; mkdir -p /etc/apt/.rhizo-leg-sourceparts.bak && mv /etc/apt/sources.list.d/*.list /etc/apt/.rhizo-leg-sourceparts.bak/ 2>/dev/null; true' >/dev/null 2>&1
  if ! ssh_vm -t 20 "printf 'deb [trusted=yes] %s ./\n' '$repo_url' > /etc/apt/sources.list"; then
    fail "ubuntu-update: could not write the guest's /etc/apt/sources.list"
  fi
  local restored=0
  uul_restore_sources() {
    (( restored )) && return 0
    restored=1
    ssh_vm -t 20 'mv -f /etc/apt/.rhizo-leg-sources.list.bak /etc/apt/sources.list 2>/dev/null; mv -f /etc/apt/.rhizo-leg-sourceparts.bak/*.list /etc/apt/sources.list.d/ 2>/dev/null; rmdir /etc/apt/.rhizo-leg-sourceparts.bak 2>/dev/null; true' >/dev/null 2>&1
  }
  trap 'uul_restore_sources; trap - RETURN' RETURN

  uul_wait_dpkg_free 300 || log "  ubuntu-update: dpkg lock still held after 300s, proceeding anyway"
  local update_out
  update_out=$(ssh_vm -t 120 "apt-get -o Dir::Etc::sourceparts=- update 2>&1")
  if grep -qE 'Failed to fetch|^E:' <<<"$update_out"; then
    fail "ubuntu-update: apt-get update against $repo_url failed: $(tail -5 <<<"$update_out" | tr '\n' '|')"
  else
    pass "ubuntu-update: apt-get update against $repo_url succeeded"
  fi
  local fetched
  fetched=$(ssh_vm -t 30 "for f in /var/lib/apt/lists/*${repo_hostport}*_Packages; do [ -f \"\$f\" ] && sha256sum \"\$f\"; done; echo $UUL_PKGLIST_END" 2>&1)
  printf '%s\n' "$fetched" > "${EV:-/tmp}/ubuntu-update-fetched-packages.sha256"
  uul_assert_fetched_pool "ubuntu-update" "$pool_sha" "$fetched" || return 1

  step "ubuntu-update: apt-daily-upgrade.service runs unattended-upgrade"
  local t0
  t0=$(ssh_vm -t 15 'date -u +%s' | tr -d '[:space:]')
  if [[ -z "$t0" ]]; then
    fail "ubuntu-update: could not read a guest timestamp before starting apt-daily-upgrade.service"
    t0=0
  fi
  ssh_vm -t 20 'systemctl start --no-block apt-daily-upgrade.service' >/dev/null 2>&1
  local settled
  settled=$(uul_wait_unit_settle apt-daily-upgrade.service "${RHIZO_UUL_DAILY_DEADLINE:-1800}")
  case "$settled" in
    inactive) pass "ubuntu-update: apt-daily-upgrade.service ran to completion" ;;
    failed) fail "ubuntu-update: apt-daily-upgrade.service reported failed" ;;
    timeout) fail "ubuntu-update: apt-daily-upgrade.service did not settle within ${RHIZO_UUL_DAILY_DEADLINE:-1800}s" ;;
  esac

  step "ubuntu-update: this run's logs carry no permission failure, dpkg is consistent"
  local uu_log history_log dpkg_audit dpkg_l
  uu_log=$(ssh_vm -t 30 "python3 -c \"
import sys
t0=$t0
for line in open('/var/log/unattended-upgrades/unattended-upgrades.log', errors='replace'):
    ts=line[:19]
    try:
        import time
        epoch=time.mktime(time.strptime(ts,'%Y-%m-%d %H:%M:%S'))
    except Exception:
        sys.stdout.write(line); continue
    if epoch>=t0:
        sys.stdout.write(line)
\" 2>/dev/null" )
  history_log=$(ssh_vm -t 30 "tail -c 20000 /var/log/apt/history.log 2>/dev/null")
  dpkg_audit=$(ssh_vm -t 30 'dpkg --audit 2>&1')
  dpkg_l=$(ssh_vm -t 30 "dpkg -l" 2>/dev/null)
  printf '%s\n' "$uu_log" > "${EV:-/tmp}/ubuntu-update-uu.log"
  printf '%s\n' "$history_log" > "${EV:-/tmp}/ubuntu-update-history.log"
  printf '%s\n' "$dpkg_audit" > "${EV:-/tmp}/ubuntu-update-dpkg-audit.log"
  uul_assert_no_permission_denied "ubuntu-update" "$uu_log"$'\n'"$history_log"
  uul_assert_dpkg_audit_empty "ubuntu-update" "$dpkg_audit"
  uul_assert_dpkg_consistent "ubuntu-update" "$dpkg_l"

  step "ubuntu-update: the systemd-stack packages in the pool now report the pool's versions"
  local manifest_text installed
  manifest_text=$(cat "$manifest")
  installed=$(ssh_vm -t 30 "dpkg-query -W -f='\${Package}\t\${Version}\n'" 2>/dev/null)
  uul_assert_systemd_stack_versions "ubuntu-update" "$manifest_text" "$installed"

  step "ubuntu-update: apt-get install linux-generic"
  uul_wait_dpkg_free 300 || log "  ubuntu-update: dpkg lock still held before linux-generic install, proceeding"
  local install_out
  install_out=$(ssh_vm -t 900 "apt-get -o Dir::Etc::sourceparts=- -y install linux-generic 2>&1")
  echo "$install_out" > "${EV:-/tmp}/ubuntu-update-linux-generic-install.log"
  if grep -qE '^E:|Unable to fetch' <<<"$install_out"; then
    fail "ubuntu-update: apt-get install linux-generic failed: $(tail -5 <<<"$install_out" | tr '\n' '|')"
  else
    pass "ubuntu-update: apt-get install linux-generic completed"
  fi

  local new_kernel
  new_kernel=$(ssh_vm -t 20 "[ -s /boot/vmlinuz-$kver ] && echo present; echo DONE")
  if [[ "$new_kernel" == $'present\nDONE' ]]; then
    pass "ubuntu-update: the update installed the stock kernel $kver"
  else
    fail "ubuntu-update: the update left no /boot/vmlinuz-$kver"
  fi

  step "ubuntu-update: reboot after the kernel update"
  if ! uul_run_cb "$reboot_fn" "ubuntu-update kernel boot"; then
    fail "ubuntu-update: $reboot_fn reported the reboot did not complete"
    return 1
  fi

  step "ubuntu-update: the Rhizo kernel still boots, kernel-check.sh passes, Android still boots"
  local uname_r
  uname_r=$(ssh_vm -t 20 'uname -r' | tr -d '[:space:]')
  uul_assert_equal "ubuntu-update" "uname -r" "$rkver" "$uname_r"

  local kernel_check_rc
  ssh_vm -t 30 '/usr/lib/rhizo/tools/kernel-check.sh' >"${EV:-/tmp}/ubuntu-update-kernel-check.log" 2>&1
  kernel_check_rc=$?
  if (( kernel_check_rc == 0 )); then
    pass "ubuntu-update: /usr/lib/rhizo/tools/kernel-check.sh passed on $rkver"
  else
    fail "ubuntu-update: /usr/lib/rhizo/tools/kernel-check.sh exited $kernel_check_rc on $rkver -- see ${EV:-/tmp}/ubuntu-update-kernel-check.log"
  fi

  local conf_text
  conf_text=$(ssh_vm -t 20 'cat /etc/modules-load.d/rhizo.conf 2>/dev/null')
  uul_assert_rhizo_conf_kernel_header "ubuntu-update" "$rkver" "$conf_text"
  uul_assert_conf_no_module "ubuntu-update" "$conf_text"

  if [[ -n "$boot_completed_fn" ]]; then
    if uul_run_cb "$boot_completed_fn"; then
      pass "ubuntu-update: Android reached sys.boot_completed after the kernel update's reboot"
    else
      fail "ubuntu-update: Android did not reach sys.boot_completed after the kernel update's reboot ($boot_completed_fn)"
    fi
  else
    fail "ubuntu-update: no boot_completed_fn given"
  fi

  local prep_text
  prep_text=$(ssh_vm -t 30 "$UUL_PREPARED_MARKERS_CMD" 2>/dev/null)
  printf '%s\n' "$prep_text" > "${EV:-/tmp}/ubuntu-update-prepared-markers.log"
  uul_assert_prepared_accepted "ubuntu-update" "$rkver" "$prep_text"

  if [[ -n "$launch_fixture_fn" ]]; then
    if uul_run_cb "$launch_fixture_fn"; then
      pass "ubuntu-update: the fixture app launched after the kernel update"
    else
      fail "ubuntu-update: the fixture app did not launch after the kernel update ($launch_fixture_fn)"
    fi
  else
    fail "ubuntu-update: no launch_fixture_fn given"
  fi
}

# run each assertion on good and bad text
uul_selftest() {
  local cases=0 failed_count=0 last_fail=""

  fail() { failed_count=$((failed_count + 1)); last_fail="$*"; echo "FAIL: $*" >&2; }
  pass() { :; }
  log()  { :; }

  check_fails() {
    local what="$1"; shift
    cases=$((cases + 1))
    local before=$failed_count
    "$@" >/dev/null 2>&1
    if (( failed_count > before )); then
      echo "  selftest OK (fails as expected): $what"
    else
      echo "SELFTEST FAILED: $what did NOT fail" >&2
      exit 1
    fi
  }
  check_passes() {
    local what="$1"; shift
    cases=$((cases + 1))
    local before=$failed_count
    "$@" >/dev/null 2>&1
    if (( failed_count == before )); then
      echo "  selftest OK (passes as expected): $what"
    else
      echo "SELFTEST FAILED: $what failed on correct input" >&2
      exit 1
    fi
  }
  check_fails_named() {
    local what="$1" needle="$2"; shift 2
    cases=$((cases + 1))
    local before=$failed_count
    last_fail=""
    "$@" >/dev/null 2>&1
    if (( failed_count == before )); then
      echo "SELFTEST FAILED: $what did NOT fail" >&2
      exit 1
    fi
    if [[ "$last_fail" != *"$needle"* ]]; then
      echo "SELFTEST FAILED: $what failed, but not by name ('$needle'): $last_fail" >&2
      exit 1
    fi
    echo "  selftest OK (fails by name): $what"
  }

  check_passes "enabled timer"      uul_assert_timer_enabled L unit enabled
  check_fails  "masked timer"       uul_assert_timer_enabled L unit masked
  check_fails  "disabled timer"     uul_assert_timer_enabled L unit disabled
  check_fails  "empty timer state"  uul_assert_timer_enabled L unit ""

  check_passes "clean log"          uul_assert_no_permission_denied L "2026-09-22 unattended-upgrades: nothing to do"
  check_fails  "permission denied"  uul_assert_no_permission_denied L "cannot create /dev/null: Permission denied"
  check_fails  "empty log"          uul_assert_no_permission_denied L ""

  check_passes "empty audit"        uul_assert_dpkg_audit_empty L ""
  check_fails  "nonempty audit"     uul_assert_dpkg_audit_empty L "systemd-timesyncd: reinstreq"

  check_passes "all ii"             uul_assert_dpkg_consistent L $'ii  udev  255-1  amd64\nii  systemd  255-1  amd64'
  check_fails  "half-configured iU" uul_assert_dpkg_consistent L $'ii  udev  255-1  amd64\niU  systemd  255-1  amd64'
  check_fails  "stuck-removal ri"   uul_assert_dpkg_consistent L $'ri  old-pkg  1.0  amd64'
  check_fails  "empty dpkg -l"      uul_assert_dpkg_consistent L ""

  local good_manifest=$'# package\tversion\tsha256\tcategory\tsource_pool\nudev\t255.4-1ubuntu8.17\tdead\tsystemd-stack\tudev_255.4-1ubuntu8.17_amd64.deb\nlinux-image-6.8.0-139-generic\t6.8.0-139.139\tdead\tkernel\tlinux-image-6.8.0-139-generic_6.8.0-139.139_amd64.deb'
  local good_installed=$'udev\t255.4-1ubuntu8.17'
  local older_installed=$'udev\t255.4-1ubuntu8.16'
  check_passes "systemd-stack matches"  uul_assert_systemd_stack_versions L "$good_manifest" "$good_installed"
  check_fails  "systemd-stack older"    uul_assert_systemd_stack_versions L "$good_manifest" "$older_installed"
  check_fails  "systemd-stack missing"  uul_assert_systemd_stack_versions L "$good_manifest" $'other-pkg\t1.0'
  check_fails  "no systemd-stack rows"  uul_assert_systemd_stack_versions L $'# package\tversion\tsha256\tcategory\tsource_pool\nlinux-image-X\t1\tdead\tkernel\tx.deb' "$good_installed"
  check_fails  "empty manifest"         uul_assert_systemd_stack_versions L "" "$good_installed"

  check_passes "conf without modules" uul_assert_conf_no_module L $'# kernel=6.8.0-139-generic\nuinput\ntun'
  check_fails  "conf naming binder"   uul_assert_conf_no_module L $'# kernel=6.8.0-139-generic\nbinder_linux\ntun'
  check_fails  "conf naming ashmem"   uul_assert_conf_no_module L $'uinput\nashmem_compat'

  check_passes "uname matches"      uul_assert_equal L "uname -r" "6.8.0-139-generic" "6.8.0-139-generic"
  check_fails  "uname mismatch"     uul_assert_equal L "uname -r" "6.8.0-139-generic" "6.8.0-71-generic"
  check_fails  "uname empty"        uul_assert_equal L "uname -r" "6.8.0-139-generic" ""

  check_passes "conf header present" uul_assert_rhizo_conf_kernel_header L "6.8.0-139-generic" $'# kernel=6.8.0-139-generic\nudev\nsystemd'
  check_fails  "conf header absent"  uul_assert_rhizo_conf_kernel_header L "6.8.0-139-generic" $'# Written by src/install/prepare/prepare.sh\nudev\nsystemd'
  check_fails  "conf header wrong kver" uul_assert_rhizo_conf_kernel_header L "6.8.0-139-generic" $'# kernel=6.8.0-71-generic\nudev'
  check_fails  "conf empty"          uul_assert_rhizo_conf_kernel_header L "6.8.0-139-generic" ""

  local klog_head=$'Linux version 6.8.0-142-generic'
  check_passes "prepared bound by every launch" uul_assert_prepared_accepted L "6.8.0-142-generic" "$klog_head"$'\nRHIZO_MARKER prepared=abc123def456\nRHIZO_MARKER prepared=abc123def456\nDONE'
  check_fails  "refused on the new kernel" uul_assert_prepared_accepted L "6.8.0-142-generic" "$klog_head"$'\nRHIZO_MARKER prepared_refused=kernel\nRHIZO_MARKER prepared_refused=kernel\nDONE'
  check_fails  "refused once, then bound" uul_assert_prepared_accepted L "6.8.0-142-generic" "$klog_head"$'\nRHIZO_MARKER prepared_refused=kernel\nRHIZO_MARKER prepared=abc123def456\nDONE'
  check_fails  "scrolled buffer: refused once, the refusal scrolled out" uul_assert_prepared_accepted L "6.8.0-142-generic" $'RHIZO_MARKER prepared=abc123def456\nDONE'
  check_fails  "a capture of another kernel's boot" uul_assert_prepared_accepted L "6.8.0-142-generic" $'Linux version 6.8.0-139-generic\nRHIZO_MARKER prepared=abc123def456\nDONE'
  check_fails  "no launch marker"   uul_assert_prepared_accepted L "6.8.0-142-generic" "$klog_head"$'\nDONE'
  check_fails  "kernel log unreadable" uul_assert_prepared_accepted L "6.8.0-142-generic" $'KLOG_UNREADABLE\nDONE'
  check_fails  "read cut short"     uul_assert_prepared_accepted L "6.8.0-142-generic" "$klog_head"$'\nRHIZO_MARKER prepared=abc123def456'

  local sha_a sha_b list="/var/lib/apt/lists/10.0.2.2:40002_._Packages"
  sha_a=$(printf 'Package: udev\nVersion: A\n' | sha256sum | cut -d' ' -f1)
  sha_b=$(printf 'Package: udev\nVersion: B\n' | sha256sum | cut -d' ' -f1)
  check_passes "fetched list is the pool's" uul_assert_fetched_pool L "$sha_a" "$sha_a  $list"$'\n'"$UUL_PKGLIST_END"
  check_fails_named "fetched list is another pool's" "is not the pool this leg reads its MANIFEST from" \
    uul_assert_fetched_pool L "$sha_a" "$sha_b  $list"$'\n'"$UUL_PKGLIST_END"
  check_fails_named "fetched-list read cut short" "end marker" \
    uul_assert_fetched_pool L "$sha_a" "$sha_a  $list"
  check_fails_named "no fetched list" "no fetched Packages list" \
    uul_assert_fetched_pool L "$sha_a" "$UUL_PKGLIST_END"
  check_fails_named "two fetched lists" "Packages lists for the served repo" \
    uul_assert_fetched_pool L "$sha_a" "$sha_a  $list"$'\n'"$sha_b  ${list/_._/_sub_._}"$'\n'"$UUL_PKGLIST_END"
  check_fails_named "empty pool sha" "Packages sha256 is empty" \
    uul_assert_fetched_pool L "" "$sha_a  $list"$'\n'"$UUL_PKGLIST_END"

  local fx out out_match
  fx=$(mktemp -d) || { echo "SELFTEST FAILED: mktemp -d" >&2; exit 1; }
  printf 'Package: udev\nVersion: A\n' > "$fx/Packages"
  printf '# package\tversion\tsha256\tcategory\tsource_pool\nlinux-image-6.8.0-139-generic\t6.8.0-139.139\tdead\tkernel\tx.deb\n' > "$fx/MANIFEST.tsv"
  uul_leg_run() {
    local guest_sha="$1" cb_reboot="${2:-true}" cb_boot="${3:-true}" cb_paint="${4:-true}"
    rm -f "$fx/reached-upgrade"
    (
      EV="$fx"
      step() { :; }
      fail() { echo "FAIL: $*"; }
      pass() { :; }
      log()  { :; }
      uul_cb_record() { echo "CB: $*"; }
      ssh_vm() {
        [[ "${1:-}" == -t ]] && shift 2
        case "$*" in
          *is-enabled*) echo enabled ;;
          'uname -r') echo "${UUL_FX_UNAME:-7.1.0-rc1-rhizo}" ;;
          *'/boot/vmlinuz-'*) printf 'present\nDONE\n' ;;
          */var/lib/apt/lists/*) printf '%s  %s\n%s\n' "$guest_sha" "$list" "$UUL_PKGLIST_END" ;;
          *'start --no-block apt-daily-upgrade'*) : > "$fx/reached-upgrade" ;;
          *is-active*) echo inactive ;;
        esac
        return 0
      }
      wrapper() { ubuntu_update_leg "http://10.0.2.2:40002/" "$fx" "$cb_reboot" "$cb_boot" "$cb_paint"; echo "LEG_RC=$?"; }
      wrapper
      echo "WRAPPER_RETURNED"
    ) 2>&1
  }

  cases=$((cases + 1))
  out=$(uul_leg_run "$sha_b")
  if ! grep -q 'FAIL: ubuntu-update: the guest.s fetched Packages is not the pool this leg reads its MANIFEST from' <<<"$out" \
     || ! grep -qx 'LEG_RC=1' <<<"$out" || [[ -e "$fx/reached-upgrade" ]]; then
    echo "SELFTEST FAILED: ubuntu_update_leg did not stop by name on a guest that fetched another pool: $(tr '\n' '|' <<<"$out")" >&2
    rm -rf "$fx"; exit 1
  fi
  echo "  selftest OK (fails by name): ubuntu_update_leg stops before apt-daily-upgrade when the guest fetched another pool"

  cases=$((cases + 1))
  out_match=$(uul_leg_run "$sha_a")
  if grep -qE 'fetched Packages|fetched-Packages' <<<"$out_match" || [[ ! -e "$fx/reached-upgrade" ]]; then
    echo "SELFTEST FAILED: ubuntu_update_leg did not get past the fetched-list check on a guest that fetched this pool: $(tr '\n' '|' <<<"$out_match")" >&2
    rm -rf "$fx"; exit 1
  fi
  echo "  selftest OK (passes as expected): ubuntu_update_leg reaches apt-daily-upgrade when the guest fetched this pool"

  cases=$((cases + 1))
  if ! grep -qx 'WRAPPER_RETURNED' <<<"$out" || ! grep -qx 'WRAPPER_RETURNED' <<<"$out_match"; then
    echo "SELFTEST FAILED: a caller of ubuntu_update_leg died on its own return (the leg left its RETURN trap set): $(tr '\n' '|' <<<"$out"$'\n'"$out_match")" >&2
    rm -rf "$fx"; exit 1
  fi
  echo "  selftest OK (passes as expected): the leg's RETURN trap does not outlive it into its caller"

  cases=$((cases + 1))
  out=$(uul_leg_run "$sha_a" "uul_cb_record reboot" "uul_cb_record boot 420 0" "uul_cb_record paint cycle-sway-ubuntu-update")
  if ! grep -qx 'CB: reboot ubuntu-update kernel boot' <<<"$out" || ! grep -qx 'CB: boot 420 0' <<<"$out" \
     || ! grep -qx 'CB: paint cycle-sway-ubuntu-update' <<<"$out" || grep -q 'command not found' <<<"$out"; then
    echo "SELFTEST FAILED: ubuntu_update_leg did not run each multi-word callback with its own arguments: $(tr '\n' '|' <<<"$out")" >&2
    rm -rf "$fx"; exit 1
  fi
  echo "  selftest OK (passes as expected): ubuntu_update_leg runs a multi-word callback as a command with its arguments"

  cases=$((cases + 1))
  out=$(uul_leg_run "$sha_a" true "uul_no_such_callback 420 0" true)
  if ! grep -qF "FAIL: ubuntu-update: boot_completed_fn 'uul_no_such_callback 420 0' names no function or command" <<<"$out" \
     || ! grep -qx 'LEG_RC=1' <<<"$out" || [[ -e "$fx/reached-upgrade" ]]; then
    echo "SELFTEST FAILED: ubuntu_update_leg did not refuse, before touching the guest, a callback naming no function: $(tr '\n' '|' <<<"$out")" >&2
    rm -rf "$fx"; exit 1
  fi
  echo "  selftest OK (fails by name): ubuntu_update_leg refuses a callback naming no function before apt-daily-upgrade"

  cases=$((cases + 1))
  out=$(UUL_FX_UNAME=6.8.0-136-generic uul_leg_run "$sha_a")
  if ! grep -qF "FAIL: ubuntu-update: the guest runs '6.8.0-136-generic' before the update, not the Rhizo kernel" <<<"$out" \
     || ! grep -qx 'LEG_RC=1' <<<"$out" || [[ -e "$fx/reached-upgrade" ]]; then
    echo "SELFTEST FAILED: ubuntu_update_leg did not refuse, before apt-daily-upgrade, a guest running a stock kernel: $(tr '\n' '|' <<<"$out")" >&2
    rm -rf "$fx"; exit 1
  fi
  echo "  selftest OK (fails by name): ubuntu_update_leg refuses a guest not running the Rhizo kernel before apt-daily-upgrade"
  rm -rf "$fx"

  echo "lifecycle-ubuntu-update-leg selftest: $cases assertions passed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --selftest) uul_selftest ;;
    *) echo "usage: $0 --selftest   (source this file to use ubuntu_update_leg)" >&2; exit 2 ;;
  esac
fi
