# shellcheck shell=bash

CACHYOS_LTS_PKGS=(linux-cachyos-lts linux-cachyos-lts-headers)

CACHYOS_LOADER_ENTRY_ID=$(cat <<'EOF'
awk -v p="$1" '
  /^[[:space:]]*\/[^\/]/ { d = $0; sub(/^[[:space:]]*\/\+?/, "", d); sub(/[[:space:]]+$/, "", d) }
  /^[[:space:]]*\/\/[^\/]/ {
    e = $0; sub(/^[[:space:]]*\/\/\+?/, "", e); sub(/[[:space:]]+$/, "", e)
    if (e == p && d ~ /^[A-Za-z0-9-]+$/) { n++; id = d "." e }
  }
  END { if (n == 1) print id }' /boot/limine.conf
EOF
)

# print the kernel release of a package
cachyos_kernel_release() {
  ssh_vm -t 20 "pacman -Qlq $1 | sed -n 's|^/usr/lib/modules/\\([^/]*\\)/\$|\\1|p' | head -1" | tr -d '[:space:]'
}

# print the boot loader entry last booted
cachyos_loader_entry_selected() {
  ssh_vm -t 20 'f=$(ls /sys/firmware/efi/efivars/LoaderEntrySelected-* 2>/dev/null) && tail -c +5 "$f" | tr -d "\0"' | tr -d '\r\n'
}

# reboot onto a boot loader entry
cachyos_boot_once() {
  ssh_vm -t 20 "bootctl set-oneshot $(printf '%q' "$1")" || { fail "5: bootctl set-oneshot $1 failed"; return 1; }
  reboot_and_wait "$2" || { fail "5: the reboot onto $1 did not come back"; return 1; }
  local sel; sel=$(cachyos_loader_entry_selected)
  [[ "$sel" == "$1" ]] || { fail "5: the boot loader reports '${sel:-<unread>}' selected, not the one-shot $1"; return 1; }
}

# install and boot linux-cachyos-lts
cachyos_update_leg() {
  local profile="$1" out own own_entry lts lts_entry n0 prep
  local log="$EV/${profile}-cachyos-update.log"
  own=$(ssh_vm -t 20 'uname -r' | tr -d '[:space:]')
  out=$(ssh_vm -t 1500 "$CACHYOS_POOL_CONF_CMD && pacman --config $CACHYOS_POOL_CONF -S --needed --noconfirm ${CACHYOS_LTS_PKGS[*]} 2>&1; echo PACMAN_RC=\$?")
  printf '%s\n' "$out" > "$log"
  grep -qx 'PACMAN_RC=0' <<<"$out" || { fail "5: pacman -S ${CACHYOS_LTS_PKGS[*]} from the pool failed (see $log)"; return 1; }
  lts=$(cachyos_kernel_release linux-cachyos-lts)
  [[ -n "$lts" && "$lts" != "$own" ]] || { fail "5: linux-cachyos-lts names no module directory of its own ('$lts', running $own)"; return 1; }
  own_entry=$(cachyos_loader_entry_selected)
  lts_entry=$(ssh_vm -t 20 "bash -s -- linux-cachyos-lts" <<<"$CACHYOS_LOADER_ENTRY_ID" | tr -d '[:space:]')
  [[ -n "$own_entry" && -n "$lts_entry" ]] \
    || { fail "5: limine.conf holds no one entry for linux-cachyos-lts ('$lts_entry'), or the boot loader reports none it booted ('$own_entry'): $(ssh_vm -t 20 'grep -E "^[[:space:]]*/" /boot/limine.conf 2>&1' | tr '\n' ' ')"; return 1; }
  n0=$(ssh_vm -t 15 'wc -l < /var/log/rhizo/prepare.log' | tr -d '[:space:]')
  cachyos_boot_once "$lts_entry" "cycle-$profile LTS kernel" || return 1
  out=$(ssh_vm -t 20 'uname -r; cat /proc/cmdline' | tr -d '\r')
  printf '%s\n' "$out" >> "$log"
  [[ "$(head -1 <<<"$out")" == "$lts" ]] \
    && pass "5: limine booted linux-cachyos-lts ($lts)" \
    || { fail "5: the host booted $(head -1 <<<"$out"), not $lts, from the boot loader's entry $lts_entry"; return 1; }
  [[ " $(sed -n 2p <<<"$out") " == *" security=selinux "* || " $(sed -n 2p <<<"$out") " == *",selinux,"* ]] \
    && [[ " $(sed -n 2p <<<"$out") " == *" androidboot."* ]] \
    && pass "5: the LTS kernel's cmdline carries Rhizo's tokens" \
    || { fail "5: the LTS kernel's cmdline lacks Rhizo's tokens: $(sed -n 2p <<<"$out")"; return 1; }
  installer_assert_kernel_check "cycle-$profile" "on the LTS kernel" || return 1
  prep=$(ssh_vm -t 60 "journalctl -b -u rhizo-kernel-refresh.service --no-pager -o cat 2>&1; tail -n +$((n0 + 1)) /var/log/rhizo/prepare.log")
  printf '%s\n' "$prep" >> "$log"
  grep -q "RHIZO_PREPARE_KERNEL_REFRESHED=1 kernel=$lts " <<<"$prep" \
    && pass "5: rhizo-kernel-refresh.service re-keyed setup for $lts" \
    || { fail "5: no RHIZO_PREPARE_KERNEL_REFRESHED=1 kernel=$lts on the LTS boot (see $log)"; return 1; }
  lc_post_reboot_sandbox "$profile" 5 || return 1
  lc_step5_app_check "$profile" "cycle-$profile-lts" || return 1
  cachyos_boot_once "$own_entry" "cycle-$profile own kernel" || return 1
  [[ "$(ssh_vm -t 20 'uname -r' | tr -d '[:space:]')" == "$own" ]] \
    || { fail "5: the host did not boot back onto $own"; return 1; }
  installer_assert_kernel_check "cycle-$profile" "back on its own kernel" || return 1
  lc_post_reboot_sandbox "$profile" 5 || return 1
  pass "5: linux-cachyos-lts installed from the pool, limine booted it with Rhizo's tokens and the sandbox ran on it; back on $own"
}
