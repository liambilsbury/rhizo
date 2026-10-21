# shellcheck disable=SC2034
# shellcheck shell=bash

# shellcheck source=../lib/installer-cachyos-lib.sh
_LIFECYCLE_CACHYOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIFECYCLE_CACHYOS_DIR/../lib/installer-cachyos-lib.sh"

LC_CACHYOS_PREV=()
LC_CACHYOS_NEW=()

# resolve both releases' package files and versions
lc_cachyos_resolve() {
  local pkgset
  RHIZO_DEB="$LC_NEW_DEB"
  pkgset=$(installer_cachyos_pkgset "$CACHYOS_PKG_DIR" 1) || { fail "debs: $pkgset"; return 1; }
  mapfile -t LC_CACHYOS_PREV <<<"$pkgset"
  pkgset=$(installer_cachyos_pkgset "$CACHYOS_PKG_DIR_UP" 2) || { fail "debs: $pkgset"; return 1; }
  mapfile -t LC_CACHYOS_NEW <<<"$pkgset"
  installer_cachyos_kernel_pkgs debs "${LC_CACHYOS_PREV[0]}" || return 1
  LC_DEB_PREV_VERSION=$(installer_cachyos_pkg_id "${LC_CACHYOS_PREV[0]}" | cut -d' ' -f2)
  LC_PACMAN_NEW_VERSION=$(installer_cachyos_pkg_id "${LC_CACHYOS_NEW[0]}" | cut -d' ' -f2)
  pass "debs: N-1 is rhizo $LC_DEB_PREV_VERSION and N rhizo $LC_PACMAN_NEW_VERSION, both built from ${LC_NEW_DEB##*/}"
}

# prepare the stock cachyos vm
lc_cachyos_step0() {
  local profile="$1" leg="cycle-$1" base_sha pool_sha out
  export RHIZO_CACHYOS_BASE="${RHIZO_CACHYOS_BASE:-cachyos-stock}"
  base_sha=$(sha256sum "$VAR_DIR/$(guest_base cachyos grub)" | cut -d' ' -f1)
  pool_sha=$(cut -d' ' -f1 "$SHARE_DIR/arch-pool/POOL.base")
  [[ -n "$base_sha" && "$base_sha" == "$pool_sha" ]] \
    || { fail "0: $RHIZO_CACHYOS_BASE (sha256 ${base_sha:-<unread>}) is not the base the pool names ($(cat "$SHARE_DIR/arch-pool/POOL.base"))"; return 1; }
  kill_vm >/dev/null 2>&1
  rm -f "$VAR_DIR/$(guest_disk cachyos grub "$SUFFIX")"
  installer_assert_stock "$leg" || return 1
  installer_cachyos_assert_pool "$leg" || return 1
  installer_cachyos_stage_harness "$leg" || return 1
  ssh_vm -t 30 'mkdir -p /etc/systemd/journald.conf.d && printf "[Journal]\nSystemMaxUse=1G\n" > /etc/systemd/journald.conf.d/zz-rhizo-cycle.conf && systemctl restart systemd-journald' \
    || { fail "0: could not raise the journal's 50M cap for the cycle's boots"; return 1; }
  out=$(ssh_vm -t 20 'getent passwd 1000 | cut -d: -f1; [ -L /etc/systemd/system/display-manager.service ] && echo DM_ENABLED')
  [[ "$out" == "$LC_DESKTOP_HUMAN"$'\n'DM_ENABLED ]] \
    || { fail "0: the stock base is not a desktop with $LC_DESKTOP_HUMAN at uid 1000 and its display manager enabled: $(tr '\n' ' ' <<<"$out")"; return 1; }
  desk_session_up --stage-login --user "$LC_DESKTOP_HUMAN" > "$EV/${profile}-seat-login-stage.log" 2>&1 \
    || fail "0: the $profile seat login did not come up on the stock host (see $EV/${profile}-seat-login-stage.log)"
  lc_seat_login_record "$profile" "cycle-$profile stock"
}

# install the packages and reboot
lc_cachyos_install() {
  local profile="$1" suffix="$2" label="$3"; shift 3
  lc_pkgwin rhizo-install "$label" installer_cachyos_install_reboot_prepare "cycle-$profile$suffix" install "$CACHYOS_ARTIFACT" "$@"
}

# seed the GSI zips and install release 1
lc_cachyos_step1() {
  local profile="$1"
  installer_seed_gsi_zip "cycle-$profile" || return 1
  installer_seed_gsi_zip_release "cycle-$profile" a15 || return 1
  LC_INSTALL_BID_BEFORE=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
  LC_INSTALL_BOOTS_BEFORE=$(ssh_vm -t 20 'journalctl --list-boots --no-pager 2>/dev/null | wc -l; echo DONE')
  [[ "$LC_INSTALL_BOOTS_BEFORE" == *$'\n'DONE ]] \
    && LC_INSTALL_BOOTS_BEFORE="${LC_INSTALL_BOOTS_BEFORE%$'\n'DONE}" || LC_INSTALL_BOOTS_BEFORE=""
  lc_step1_install() { lc_cachyos_install "$profile" "" step1-install "${LC_CACHYOS_PREV[@]}" "${CACHYOS_KERNEL_PKGS[@]}"; }
  step_claim 1.prepare-ok lc_step1_install
  LC_INSTALL_BID_AFTER=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
  LC_INSTALL_BOOTS_AFTER=$(ssh_vm -t 20 'journalctl --list-boots --no-pager 2>/dev/null | wc -l; echo DONE')
  [[ "$LC_INSTALL_BOOTS_AFTER" == *$'\n'DONE ]] \
    && LC_INSTALL_BOOTS_AFTER="${LC_INSTALL_BOOTS_AFTER%$'\n'DONE}" || LC_INSTALL_BOOTS_AFTER=""
}

# run pacman -U on release 2
lc_cachyos_step3_upgrade() {
  local profile="$1" leg="cycle-$1-upgrade" before after marks_before marks_after
  before=$(ssh_vm -t 15 'pacman -Q rhizo 2>&1' | awk '{ print $2 }')
  [[ "$before" == "$LC_DEB_PREV_VERSION" ]] \
    || { fail "3: pacman holds rhizo '${before:-<not installed>}' before the upgrade, want N-1 $LC_DEB_PREV_VERSION"; return 1; }
  installer_cachyos_transfer "$leg" "$CACHYOS_ARTIFACT_UP" "${LC_CACHYOS_NEW[@]}" || return 1
  marks_before=$(installer_start_marks)
  lc_pkgwin rhizo-install step3-upgrade installer_cachyos_pacman_u "$leg" upgrade "$CACHYOS_ARTIFACT_UP" "${LC_CACHYOS_NEW[@]}" \
    || return 1
  cp "$EV/$leg-upgrade.log" "$EV/${profile}-upgrade-install.log"
  marks_after=$(installer_start_marks)
  printf '%s\n=== after\n%s\n' "$marks_before" "$marks_after" > "$EV/${profile}-upgrade-start-marks.txt"
  after=$(ssh_vm -t 15 'pacman -Q rhizo 2>&1' | awk '{ print $2 }')
  [[ "$after" == "$LC_PACMAN_NEW_VERSION" ]] \
    || { fail "3: pacman -U exited 0 but pacman holds rhizo '${after:-<not installed>}', want $LC_PACMAN_NEW_VERSION"; return 1; }
  installer_assert_started_nothing "$leg" "3: the N-1 -> N upgrade" "$marks_before" "$marks_after" || return 1
  pass "3: pacman moved rhizo $before -> $after"
}

# run pacman -R on the rhizo package
lc_cachyos_remove() {
  ssh_vm -t 300 'pacman -R --noconfirm rhizo 2>&1; echo "PACMAN_RC=$?"'
}

# run rhizo uninstall --purge
lc_cachyos_purge() {
  ssh_vm -t 900 'RHIZO_ASSUME_YES=1 /usr/bin/rhizo uninstall --purge 2>&1; echo "PURGE_RC=$?"'
}

# reinstall release 2 and reboot
lc_cachyos_reinstall() {
  installer_cachyos_install_reboot_prepare "cycle-$1$2" reinstall "$CACHYOS_ARTIFACT_UP" "${LC_CACHYOS_NEW[@]}" "${CACHYOS_KERNEL_PKGS[@]}"
}
