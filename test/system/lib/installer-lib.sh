#!/bin/bash
_INSTALLER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F note >/dev/null 2>&1; then
  note() { log "  $*"; }
fi
source "$(dirname "${BASH_SOURCE[0]}")/../../../tools/fetch/pools/deb/deb-pool-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../host/host-census-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../vm/guest-os/guest-os-lib.sh"

TEST_SWAY_DEBS="${TEST_SWAY_DEBS:-/var/lib/test-sway-debs}"
TEST_GNOME_DEBS="${TEST_GNOME_DEBS:-/var/lib/test-gnome-debs}"
TEST_RHIZO_RUNTIME_DEBS="${TEST_RHIZO_RUNTIME_DEBS:-/var/lib/test-runtime-debs}"
TEST_PIPEWIRE_DEBS="${TEST_PIPEWIRE_DEBS:-/var/lib/test-pipewire-debs}"
TEST_APT_OFFLINE_CONF="$TEST_RHIZO_RUNTIME_DEBS/apt/apt.conf"
INSTALLER_TRANSFERRED_DEBS=()
INSTALLER_OFFLINE_UNMET=""
INSTALLER_SELINUX_MODE="${INSTALLER_SELINUX_MODE:-}"
INSTALLER_ANDROIDD_ENV=/etc/rhizo/androidd.env

# wait until the guest answers ssh again
wait_back() {
  local deadline=$((SECONDS + ${1:-420}))
  while (( SECONDS < deadline )); do
    wait_for_ssh 5 >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# write INSTALLER_SELINUX_MODE into the guest's androidd.env
installer_pin_selinux_mode() {
  local what="$1" out
  [[ -n "$INSTALLER_SELINUX_MODE" ]] || return 0
  out=$(ssh_vm -t 30 "f=$INSTALLER_ANDROIDD_ENV
if [ ! -e \$f ]; then echo NO_ENV_FILE; exit 0; fi
sed -i '/^RHIZO_SELINUX_MODE=/d' \$f && echo RHIZO_SELINUX_MODE=$INSTALLER_SELINUX_MODE >> \$f || exit 1
grep '^RHIZO_SELINUX_MODE=' \$f")
  case "$out" in
    NO_ENV_FILE) return 0 ;;
    "RHIZO_SELINUX_MODE=$INSTALLER_SELINUX_MODE")
      note "$what: $INSTALLER_ANDROIDD_ENV pins RHIZO_SELINUX_MODE=$INSTALLER_SELINUX_MODE for the reboot" ;;
    *)
      fail "$what: could not pin RHIZO_SELINUX_MODE=$INSTALLER_SELINUX_MODE in $INSTALLER_ANDROIDD_ENV before the reboot (read back: $(tr '\n' ' ' <<<"${out:-<nothing>}"))"
      return 1 ;;
  esac
}

# reboot the guest and wait for ssh
reboot_and_wait() {
  local what="$1" before after
  installer_pin_selinux_mode "$what" || return 1
  before=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
  ssh_vm -t 20 'sync; (sleep 1; systemctl reboot) >/dev/null 2>&1 & echo ISSUED' >/dev/null 2>&1
  timeout 20 ssh -O exit "${SSH_OPTS[@]}" -p "$SSH_PORT" "$SSH_TARGET" 2>/dev/null || true
  rm -f "$SSH_CONTROL_SOCK" 2>/dev/null || true
  local down_deadline=$((SECONDS + 100)) down_misses=0
  while (( SECONDS < down_deadline )); do
    if ssh_vm -t 3 'true' >/dev/null 2>&1; then
      down_misses=0
    else
      (( ++down_misses >= 2 )) && break
    fi
    sleep 1
  done
  if ! wait_back 900; then
    tail -60 "$VAR_DIR/vm-boot${SUFFIX}.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
      > "$EV/reboot-console${what// /-}.log" 2>&1
    "$_INSTALLER_LIB_DIR/../../vm/boot/explain-boot.sh" >> "$EV/reboot-console${what// /-}.log" 2>&1 || true
    fail "$what: the host never came back (console and explanation in $EV/reboot-console${what// /-}.log)"
    "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV/boot-failure${what// /-}" "installer${what// /-}-unreachable"
    return 1
  fi
  after=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
  if [[ -z "$before" || -z "$after" || "$after" == "$before" ]]; then
    fail "$what: boot_id did not change ($before -> $after)"
    "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV/boot-failure${what// /-}" "installer${what// /-}-not-rebooted"
    return 1
  fi
  note "$what: boot_id $before -> $after (a real reboot, not a reconnect)"

  local stable=0 tries=0
  while (( stable < 3 && tries < 40 )); do
    if ssh_vm -t 15 'true' >/dev/null 2>&1; then stable=$((stable + 1)); else stable=0; fi
    tries=$((tries + 1))
    (( stable < 3 )) || break
    sleep 3
  done
  if (( stable < 3 )); then
    fail "$what: sshd never answered three times running after the reboot"
    "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV/boot-failure${what// /-}" "installer${what// /-}-unstable-ssh"
    return 1
  fi
  if declare -F installer_post_reboot_hook >/dev/null; then
    installer_post_reboot_hook "$what"
  fi
  return 0
}

# print the guest uptime in seconds
guest_uptime() { ssh_vm -t 20 'cut -d" " -f1 /proc/uptime' | tr -d '[:space:]'; }
# print the last dmesg marker line
sandbox_marker_after() {
  ssh_vm -t 30 "dmesg 2>/dev/null | sed -E 's/^\\[[[:space:]]*([0-9.]+)\\][[:space:]]*/\\1 /' | awk -v t=$1 '/$2/ { if (\$1+0 > t+0) last=\$0 } END { print last }'"
}
# wait for the sandbox boot marker
wait_sandbox_started() {
  local deadline=$((SECONDS + $1))
  while (( SECONDS < deadline )); do
    [[ -n "$(sandbox_marker_after "$2" 'RHIZO_MARKER sys.boot_completed=1 sandbox=0')" ]] && return 0
    sleep 10
  done
  return 1
}
# print the sandbox init pid
resolve_init_pid() {
  local deadline=$((SECONDS + $1)) pid=""
  while (( SECONDS < deadline )); do
    pid=$(guest_init_pid 20)
    [[ -n "$pid" ]] && break
    sleep 5
  done
  printf '%s' "$pid"
}

# wait for the dpkg locks to clear
wait_dpkg_free() {
  local what="$1" deadline=$((SECONDS + 300)) holder
  while (( SECONDS < deadline )); do
    if ssh_vm -t 30 'fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1 && exit 1; exit 0' >/dev/null 2>&1; then
      return 0
    fi
    sleep 10
  done
  holder=$(ssh_vm -t 30 'fuser -v /var/lib/dpkg/lock-frontend 2>&1 | tail -2' | tr -d '\r')
  note "$what: dpkg lock still held after 300s ($holder)"
  return 1
}

# capture a host-snapshot.sh census
take_snapshot() {
  local label="$1" outfile="$2" rc
  rm -f "$outfile" "$outfile.err"
  timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$REPO/test/system/host/host-snapshot.sh" \
      "$SSH_TARGET:/root/host-snapshot.sh" \
    || { fail "$label: could not stage host-snapshot.sh"; return 1; }
  ssh_vm -t 180 'bash /root/host-snapshot.sh' > "$outfile" 2>"$outfile.err"
  rc=$?
  if (( rc != 0 )); then
    fail "$label: host-snapshot.sh's ssh exited $rc (stderr: $(tail -5 "$outfile.err" 2>/dev/null | tr '\n' ' '))"
    return 1
  fi
  if [[ "$(tail -1 "$outfile" 2>/dev/null)" != $'end\tsentinel\tok' ]]; then
    fail "$label: host-snapshot.sh's output does not end with the completeness sentinel (end/sentinel/ok) (last line: $(tail -1 "$outfile" 2>/dev/null))"
    return 1
  fi
  local n
  n=$(wc -l < "$outfile" 2>/dev/null | tr -d '[:space:]')
  note "$label: host snapshot captured, $n row(s) ($outfile)"
  return 0
}

# check the keystore probe result lines
assert_keystore_probe() {
  local label="$1" text="$2" done_line nok nfail
  done_line=$(grep -E 'RHIZO_KEYSTORE_PROBE done ' <<<"$text" | tail -1)
  if [[ -z "$done_line" ]]; then
    fail "[$label] the keystore probe never reported done: $(grep -E 'RHIZO_KEYSTORE_PROBE' <<<"$text" | tail -2 | tr '\n' ' ')"
    return 1
  fi
  nok=$(sed -n 's/.* ok=\([0-9]*\).*/\1/p' <<<"$done_line")
  nfail=$(sed -n 's/.* fail=\([0-9]*\).*/\1/p' <<<"$done_line")
  if [[ "$nfail" != 0 || "$nok" != 3 ]]; then
    fail "[$label] keystore probe: ok=${nok:-?} fail=${nfail:-?} -- $(grep -E 'result=fail' <<<"$text" | sed 's/.*RHIZO_KEYSTORE_PROBE //' | head -3 | tr '\n' ' ')"
    return 1
  fi
  pass "[$label] EC generate+sign, RSA generate+sign and HMAC import+mac all answered through the running KeyMint"
}

# check the KeyMint staging marker line
assert_keymint_staged() {
  local label="$1" marker="$2"
  case "$marker" in
    *"rhizo-keymint-service staged on /vendor/bin/hw"*)
      pass "[$label] the launcher staged the KeyMint binary from the payload this boot" ;;
    *"NOT FOUND"*)
      fail "[$label] the launcher found no rhizo-keymint-service to stage: $marker" ;;
    *)
      fail "[$label] no keymint staging marker from this boot" ;;
  esac
}

# check a dpkg status field reads ii
installer_abbrev_configured() {
  [[ ${#1} -eq 3 && "${1:0:2}" == ii && "${1:2:1}" == " " ]]
}

# boot the guest and check stock state
installer_assert_stock() {
  local leg="$1"
  boot_vm
  if ! wait_for_boot_slot 3600; then
    fail "[$leg] still queued for a qemu slot after an hour"
    return 1
  fi
  if ! wait_back 420; then
    fail "[$leg] the pristine VM never came up"
    "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV/boot-failure-$leg-initial" "installer-$leg-initial-boot"
    return 1
  fi
  local cmdline lsm_before stock="apparmor active, no selinuxfs"
  cmdline=$(ssh_vm -t 20 'cat /proc/cmdline')
  note "[$leg] cmdline as booted: $cmdline"
  if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then
    installer_assert_stock_cachyos "$leg" || return 1
    stock="neither selinux nor apparmor active, no selinuxfs, no rhizo cmdline tokens or block"
  else
    case "$cmdline" in *rhizo*|*security=selinux*)
      fail "[$leg] the image booted already carrying Rhizo cmdline tokens" ;;
    esac
    lsm_before=$(ssh_vm -t 20 'cat /sys/kernel/security/lsm 2>/dev/null')
    note "[$leg] before: lsm=$lsm_before"
    case ",$lsm_before," in
      *,apparmor,*) : ;;
      *) fail "[$leg] apparmor is NOT active on the stock image (lsm=$lsm_before)" ;;
    esac
    case ",$lsm_before," in *,selinux,*) fail "[$leg] selinux is ALREADY active before anything ran" ;; esac
  fi
  local pre
  pre=$(ssh_vm -t 20 'ls -d /var/lib/rhizo /usr/lib/rhizo /etc/rhizo 2>/dev/null | tr "\n" " "; systemctl list-unit-files "rhizo*" androidd.service --no-legend 2>/dev/null | wc -l')
  case "$pre" in
    *rhizo*) fail "[$leg] the new disk already carries Rhizo state: $pre" ;;
    *) pass "[$leg] stock: $stock, no Rhizo files or units" ;;
  esac
}

# print the package names of Rhizo kernel debs
installer_kernel_deb_packages() {
  local k p names=""
  for k in "$@"; do
    if ! p=$(dpkg-deb -f "$k" Package) || [[ -z "$p" ]]; then
      echo "could not read the Package field of $(basename "$k") (read '${p:-<nothing>}')"
      return 1
    fi
    names+=" $p"
  done
  printf '%s' "$names"
}

# check the guest booted the Rhizo kernel
installer_assert_rhizo_kernel() {
  local leg="$1" what="$2" kernel
  kernel=$(ssh_vm -t 20 'uname -r' | tr -d '[:space:]')
  if [[ "$kernel" == *-rhizo ]]; then
    pass "[$leg] $what booted the Rhizo kernel $kernel"
  else
    fail "[$leg] $what booted '${kernel:-<unread>}', not the Rhizo kernel the rhizo package depends on"
    return 1
  fi
  installer_assert_kernel_check "$leg" "after $what"
}

# print the uptime when rhizo-session-start.service started androidd
installer_session_start_uptime() {
  local leg="$1" out status mono
  out=$(ssh_vm -t 30 'test -s /run/rhizo-desktop/session.env && echo SESSION=yes; systemctl show -p ExecMainStatus -p ExecMainStartTimestampMonotonic rhizo-session-start.service; echo DONE')
  status=$(sed -n 's/^ExecMainStatus=//p' <<<"$out")
  mono=$(sed -n 's/^ExecMainStartTimestampMonotonic=//p' <<<"$out")
  if [[ "$out" != *DONE || "$out" != *SESSION=yes* || "$status" != 0 || ! "$mono" =~ ^[1-9][0-9]*$ ]]; then
    fail "[$leg] androidd.service is active after prepare released its setup boot, and rhizo-session-start.service did not start it for a resolved desktop session (read: $(tr '\n' ' ' <<<"${out:-<no answer over ssh>}"))"
    return 1
  fi
  printf '%s.%06d' "$((mono / 1000000))" "$((mono % 1000000))"
}

# print the install's reboot notice line
installer_reboot_notice() {
  if [[ "$INSTALLER_SELINUX_MODE" == host ]]; then
    echo 'REBOOT REQUIRED'
  else
    echo 'reboot into the Rhizo kernel, the default boot entry now'
  fi
}

# check the guest matches the stock cachyos base
installer_assert_stock_cachyos() {
  local leg="$1" bl kind conf out why rc line
  bl=$(cachyos_base_bootloader "$RHIZO_CACHYOS_BASE" RHIZO_CACHYOS_BASE 2>&1) || { fail "[$leg] $bl"; return 1; }
  read -r kind conf _ <<<"$(cachyos_bootloader_files "$bl")"
  out=$(ssh_vm -t 20 "$(cachyos_stock_probe "$conf")" 2>&1)
  echo "$out" > "$EV/$leg-stock-state.txt"
  note "[$leg] before: $(grep -E '^(lsm|enforce|markers)=' <<<"$out" | tr '\n' ' ')(markers counted in $conf, a $kind host)"
  why=$(cachyos_stock_mismatches "$conf" <<<"$out")
  rc=$?
  (( rc )) || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] && fail "[$leg] $line"
  done <<<"$why"
  [[ -n "$why" ]] || fail "[$leg] the stock-state check exited $rc and named nothing"
  return 0
}

# copy a pool to the guest and install
installer_stage_pool() {
  local leg="$1" what="$2" src="$3" dst="$4" roots="$5" allow="$6" nd out
  [[ -d "$src" ]] || { fail "[$leg] no $src to stage the $what from"; return 1; }
  ssh_vm -t 60 "mkdir -p $dst" >/dev/null 2>&1
  timeout 900 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$src"/*.deb "$SSH_TARGET:$dst/" \
    || { fail "[$leg] could not stage the $what packages"; return 1; }
  nd=$(ssh_vm -t 60 "ls $dst/*.deb 2>/dev/null | wc -l" | tr -d '[:space:]')
  note "[$leg] staged $nd $what package(s) over scp"
  [[ "${nd:-0}" -gt 0 ]] || { fail "[$leg] no $what packages reached the guest"; return 1; }
  if out=$(deb_pool_stage "$leg-$what" "$dst" "$roots" "$allow" "$EV/$leg-$what-plan.tsv" "$EV/$leg-$what-install.log"); then
    pass "[$leg] $out"
  else
    fail "[$leg] $out"
    return 1
  fi
}

# unpack linux-modules-extra and install the compositor pool
installer_stage_desktop_resemblance() {
  local leg="$1"
  local mextra="$SHARE_DIR/modules-extra.deb"
  [[ -f "$mextra" ]] || { fail "[$leg] no $mextra"; return 1; }
  timeout 300 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$mextra" "$SSH_TARGET:/root/modules-extra.deb" \
    || { fail "[$leg] could not stage linux-modules-extra"; return 1; }
  local seed
  seed=$(ssh_vm -t 600 'set -e
    K=$(uname -r)
    rm -rf /tmp/mx && mkdir -p /tmp/mx
    dpkg-deb -x /root/modules-extra.deb /tmp/mx
    [ -d "/tmp/mx/lib/modules/$K" ] || { echo "seed-error=no modules for $K in the package"; exit 0; }
    cp -a "/tmp/mx/lib/modules/$K/." "/lib/modules/$K/"
    rm -rf /tmp/mx
    depmod -a
    echo "netfilter_ko=$(find /lib/modules/$K/kernel/net -name "*.ko*" 2>/dev/null | grep -c netfilter)"
    echo "veth_ko=$(find /lib/modules/$K -name "veth.ko*" 2>/dev/null | wc -l)"
    modprobe 9pnet_virtio 2>/dev/null; modprobe 9p 2>/dev/null
    echo "9p=$(modinfo -n 9p 2>/dev/null)"')
  note "[$leg] $seed"
  [[ "$seed" == *seed-error=* ]] && fail "[$leg] linux-modules-extra did not seed: $seed"
  local nf veth
  nf=$(sed -n 's/^netfilter_ko=//p' <<<"$seed" | tr -d '[:space:]')
  veth=$(sed -n 's/^veth_ko=//p' <<<"$seed" | tr -d '[:space:]')
  note "[$leg] modules after seeding: netfilter=${nf:-?} veth=${veth:-?}"
  [[ "${nf:-0}" -gt 100 && "${veth:-0}" -ge 1 ]] \
    && pass "[$leg] the base module tree is intact after seeding" \
    || fail "[$leg] seeding left the base module tree unreachable (netfilter=${nf:-?} veth=${veth:-?})"
  installer_stage_pool "$leg" compositor "$SHARE_DIR/sway-debs" "$TEST_SWAY_DEBS" \
    "$DEB_POOL_SWAY_ROOTS" "$DEB_POOL_SWAY_ALLOW_UPGRADE" || return 1
  local unconf
  unconf=$(ssh_vm -t 60 'for p in sway swaybg grim wlrctl libwlroots12t64 libegl1 libgbm1 libgl1-mesa-dri libpciaccess0; do
      [ "$(dpkg-query -W -f="\${db:Status-Abbrev}" $p 2>/dev/null | tr -d " ")" = ii ] || echo $p; done; echo UNCONF_END')
  if [[ "$unconf" != *UNCONF_END* ]]; then
    fail "[$leg] could not read the compositor packages' dpkg state (got: ${unconf:-nothing})"
    return 1
  fi
  unconf=$(grep -v '^UNCONF_END$' <<<"$unconf" | grep .)
  if [[ -n "$unconf" ]]; then
    fail "[$leg] compositor packages still unconfigured: $(tr "\n" " " <<<"$unconf")"
    return 1
  fi
  pass "[$leg] the compositor stack is installed and configured"
  if [[ "${RHIZO_DESKTOP_PROFILE:-}" == gnome ]]; then
    installer_stage_pool "$leg" gnome "$SHARE_DIR/gnome-debs" "$TEST_GNOME_DEBS" \
      "$DEB_POOL_GNOME_ROOTS" "$DEB_POOL_GNOME_ALLOW_UPGRADE" || return 1
  fi
}

# create the desktop user with uid 1000
installer_stage_desktop_user() {
  local leg="$1" name="$2" have home check
  have=$(ssh_vm -t 20 "getent passwd 1000 | cut -d: -f1; echo DONE")
  [[ "$have" == DONE || "$have" == *$'\n'DONE ]] \
    || { fail "[$leg] incomplete read of uid 1000's account (no DONE token): $have"; return 1; }
  have="${have%DONE}"; have="${have%$'\n'}"
  if [[ -z "$have" ]]; then
    ssh_vm -t 60 "useradd --uid 1000 --user-group --create-home --shell /bin/bash $name \
      && runuser -u $name -- sh -c 'chmod 0750 ~ && cd && for d in Desktop Documents Downloads Music Pictures Videos; do install -d -m 0755 \"\$d\"; done'" \
      >/dev/null 2>&1
  elif [[ "$have" != "$name" ]]; then
    fail "[$leg] uid 1000 is already '$have', not the desktop user '$name' this vm stages"
    return 1
  fi
  check=$(ssh_vm -t 20 "getent passwd 1000 | cut -d: -f1,6; stat -c '%u %a' \"\$(getent passwd 1000 | cut -d: -f6)\" \"\$(getent passwd 1000 | cut -d: -f6)/Downloads\" 2>&1; echo DONE")
  home=$(head -1 <<<"$check")
  if [[ "$check" != *$'\n'DONE || "$home" != "$name:/home/$name" ]] \
     || [[ "$(sed -n 2,3p <<<"$check" | tr '\n' ' ')" != "1000 750 1000 755 " ]]; then
    fail "[$leg] uid 1000 is not a desktop login with its own 0750 home and Downloads: $(tr '\n' ' ' <<<"$check")"
    return 1
  fi
  pass "[$leg] uid 1000 is the desktop user $name, home /home/$name (0750) with its xdg dirs"
}

# print a release's pins-file row from tools/fetch/gsi-pins.sh: release, url, sha256 and description
installer_gsi_pin() { ( source "$REPO/tools/fetch/gsi-pins.sh" && gsi_pin_row "$1" ); }

# copy the a16 GSI zip to the guest
installer_seed_gsi_zip() { installer_seed_gsi_zip_release "$1" a16; }

# copy a GSI release zip to the guest, and give a release the product does not pin a row in /etc/rhizo/gsi-pins.tsv
installer_seed_gsi_zip_release() {
  local leg="$1" release="$2" pin want_sha row
  pin=$(installer_gsi_pin "$release") || { fail "[$leg] tools/fetch/gsi-pins.sh has no $release pin"; return 1; }
  want_sha=$(cut -f3 <<<"$pin")
  local gsi_zip
  gsi_zip=$(source "$REPO/tools/fetch/gsi-pins.sh" && gsi_seed_path "$VAR_DIR" "$release")
  if [[ ! -f "$gsi_zip" ]]; then
    fail "[$leg] no $gsi_zip to seed with -- fetch it on the outer host first"
    return 1
  fi
  ssh_vm -t 60 'mkdir -p /var/cache/rhizo/gsi' >/dev/null 2>&1
  timeout 1800 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$gsi_zip" "$SSH_TARGET:/var/cache/rhizo/gsi/gsi_$release.zip" \
    || { fail "[$leg] could not stage the $release GSI zip"; return 1; }
  local seeded_sha
  seeded_sha=$(ssh_vm -t 300 "sha256sum /var/cache/rhizo/gsi/gsi_$release.zip | cut -d' ' -f1" | tr -d '[:space:]')
  note "[$leg] seeded $release GSI zip sha256=$seeded_sha"
  [[ "$seeded_sha" == "$want_sha" ]] \
    && pass "[$leg] the seeded $release image matches its pin" \
    || fail "[$leg] the seeded $release image does not match its pin"
  [[ "$release" == a16 ]] && return 0
  row=$(base64 -w0 <<<"$pin")
  ssh_vm -t 60 "mkdir -p /etc/rhizo && touch /etc/rhizo/gsi-pins.tsv && sed -i '/^$release\t/d' /etc/rhizo/gsi-pins.tsv && echo $row | base64 -d >> /etc/rhizo/gsi-pins.tsv" >/dev/null 2>&1 \
    || { fail "[$leg] could not add the $release pin to /etc/rhizo/gsi-pins.tsv"; return 1; }
}

# stage the runtime pool for apt
installer_stage_offline_repo() {
  local leg="$1" pool="${2:-$SHARE_DIR/runtime-debs}" idx n log="$EV/$1-offline-repo.log" out remote problems stamped indexed unmet
  ssh_vm -t 60 "rm -rf $TEST_RHIZO_RUNTIME_DEBS" >/dev/null 2>&1
  INSTALLER_OFFLINE_UNMET=""
  [[ -d "$pool" ]] \
    || { fail "[$leg] no $pool -- run tools/fetch/pools/deb/runtime-debs.sh"; return 1; }
  command -v dpkg-scanpackages >/dev/null 2>&1 \
    || { fail "[$leg] no dpkg-scanpackages on this host (dpkg-dev) to index $pool"; return 1; }
  idx="$EV/$leg-offline-repo.Packages"
  (cd "$pool" && dpkg-scanpackages -m . /dev/null > "$idx" 2>/dev/null) \
    || { fail "[$leg] dpkg-scanpackages could not index $pool"; return 1; }
  n=$(grep -c '^Package: ' "$idx")
  (( n > 0 )) || { fail "[$leg] $pool indexes to no package"; return 1; }
  if ! problems=$(deb_pool_stamp_problems "$pool" "${INSTALLER_TRANSFERRED_DEBS[@]}"); then
    fail "[$leg] $pool is not what tools/fetch/pools/deb/runtime-debs.sh --check passed for these .debs: $(tr '\n' ';' <<<"$problems") -- run it again"
    return 1
  fi
  stamped=$(awk -F'\t' '$1 == "pool" && $3 ~ /\.deb$/ { print $3 "\t" $2 }' "$pool/$DEB_POOL_STAMP" | sort)
  indexed=$(awk '/^Filename: / { f = $2; sub(/^\.\//, "", f) } /^SHA256: / { print f "\t" $2 }' "$idx" | sort)
  if [[ -z "$stamped" || "$stamped" != "$indexed" ]]; then
    fail "[$leg] the index built from $pool does not carry the hashes its stamp names: $(diff <(echo "$stamped") <(echo "$indexed") | grep '^[<>]' | head -3 | tr '\n' ' ')"
    return 1
  fi
  unmet="$EV/$leg-offline-repo.UNMET-RECOMMENDS"
  cp "$pool/UNMET-RECOMMENDS" "$unmet" 2>/dev/null
  if [[ "$(sha256sum "$unmet" 2>/dev/null | cut -d' ' -f1)" != "$(awk -F'\t' '$1 == "pool" && $3 == "UNMET-RECOMMENDS" { print $2 }' "$pool/$DEB_POOL_STAMP")" ]]; then
    fail "[$leg] $pool/UNMET-RECOMMENDS is not the record its stamp names"
    return 1
  fi
  ssh_vm -t 60 "mkdir -p $TEST_RHIZO_RUNTIME_DEBS/apt/lists/partial $TEST_RHIZO_RUNTIME_DEBS/apt/sources.list.d" >/dev/null 2>&1
  if ! timeout 900 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$pool"/*.deb "$SSH_TARGET:$TEST_RHIZO_RUNTIME_DEBS/" \
      || ! timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$idx" "$SSH_TARGET:$TEST_RHIZO_RUNTIME_DEBS/Packages"; then
    fail "[$leg] could not stage the runtime pool onto the guest"
    return 1
  fi
  out=$(ssh_vm -t 300 "set -u
    d=$TEST_RHIZO_RUNTIME_DEBS
    echo \"deb [trusted=yes] file:\$d ./\" > \$d/apt/sources.list
    printf '%s\n' \"Dir::Etc::SourceList \\\"\$d/apt/sources.list\\\";\" \"Dir::Etc::SourceParts \\\"\$d/apt/sources.list.d\\\";\" \
      \"Dir::State::Lists \\\"\$d/apt/lists\\\";\" 'Dir::Cache::pkgcache \"\";' 'Dir::Cache::srcpkgcache \"\";' \
      'Acquire::Languages \"none\";' > $TEST_APT_OFFLINE_CONF
    [ -s $TEST_APT_OFFLINE_CONF ] || { echo UPDATE_RC=NOCONF; exit; }
    echo \"staged=\$(ls \$d/*.deb | wc -l)\"
    APT_CONFIG=$TEST_APT_OFFLINE_CONF apt-get update 2>&1; echo \"UPDATE_RC=\$?\"
    echo '--- policy'; APT_CONFIG=$TEST_APT_OFFLINE_CONF apt-cache policy 2>&1
    echo '--- config'; APT_CONFIG=$TEST_APT_OFFLINE_CONF apt-config dump 2>&1 | grep -i '^Dir::Etc::sourcelist '")
  echo "$out" > "$log"
  remote=$(grep -E '[a-z0-9+.-]+://' <<<"$out" | head -3)
  if ! grep -qx 'UPDATE_RC=0' <<<"$out"; then
    fail "[$leg] apt-get update over the offline pool failed (see $log)"
    return 1
  elif grep -q '^W: Unable to read' <<<"$out"; then
    fail "[$leg] apt could not read $TEST_APT_OFFLINE_CONF and read the guest's own sources: $(grep -m1 '^W: Unable to read' <<<"$out") (see $log)"
    return 1
  elif [[ -n "$remote" ]]; then
    fail "[$leg] apt under $TEST_APT_OFFLINE_CONF still names a remote source: $(tr '\n' '|' <<<"$remote") (see $log)"
    return 1
  elif ! grep -q "file:$TEST_RHIZO_RUNTIME_DEBS ./" <<<"$out" \
      || ! grep -qi "^Dir::Etc::sourcelist \"$TEST_RHIZO_RUNTIME_DEBS/apt/sources.list\";" <<<"$out"; then
    fail "[$leg] apt under $TEST_APT_OFFLINE_CONF does not read the pool as its source list (see $log)"
    return 1
  elif ! grep -qx "staged=$n" <<<"$out"; then
    fail "[$leg] the guest holds $(sed -n 's/^staged=//p' <<<"$out" | head -1) pool file(s), the index $n (see $log)"
    return 1
  fi
  INSTALLER_OFFLINE_UNMET="$unmet"
  pass "[$leg] apt's only source is the offline pool its check stamped: $n package(s) at file:$TEST_RHIZO_RUNTIME_DEBS, no remote URI"
}

# check an apt log for remote fetches
installer_assert_offline_apt() {
  local leg="$1" log="$2" what="$3" problems
  problems=$(deb_pool_apt_log_problems "$log" "${INSTALLER_OFFLINE_UNMET:-$SHARE_DIR/runtime-debs/UNMET-RECOMMENDS}")
  if [[ -n "$problems" ]]; then
    fail "[$leg] $what was not offline and complete: $(tr '\n' ';' <<<"$problems") (see $log)"
    return 1
  fi
  pass "[$leg] $what resolved from the offline pool alone: no remote fetch, no Recommends left unmet that a connected host installs"
}

# copy the .deb files to the guest
installer_transfer_artifact() {
  local leg="$1" rhizo_deb="$2" problems
  local -a kernel_debs=("${@:3}")
  ssh_vm -t 30 'rm -rf /root/rhizo-artifact && mkdir -p /root/rhizo-artifact' >/dev/null 2>&1
  if ! problems=$(deb_pool_stamp_problems "$SHARE_DIR/runtime-debs" "$rhizo_deb" "${kernel_debs[@]}"); then
    fail "[$leg] the offline pool was not checked for $(basename "$rhizo_deb")${kernel_debs[*]:+ and the Rhizo kernel .debs}: $(tr '\n' ';' <<<"$problems") -- run tools/fetch/pools/deb/runtime-debs.sh"
    return 1
  fi
  timeout 900 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$rhizo_deb" "${kernel_debs[@]}" "$SSH_TARGET:/root/rhizo-artifact/" \
    || { fail "[$leg] could not transfer the packages"; return 1; }
  INSTALLER_TRANSFERRED_DEBS+=("$rhizo_deb" "${kernel_debs[@]}")
  local crossed
  crossed=$(ssh_vm -t 30 'ls /root/rhizo-artifact | sort | tr "\n" " "')
  note "[$leg] crossed: $crossed"
  case "$crossed" in
    *sync*|*redeploy*|*launcher3*|*share*) fail "[$leg] something other than the packages crossed: $crossed" ;;
    *) pass "[$leg] only the .deb files reached the target" ;;
  esac
  local rigfiles
  rigfiles=$(ssh_vm -t 30 'ls /root/share /root/launcher3.py /root/gfx_hal 2>/dev/null | head -3 | tr "\n" " "')
  if [[ -n "$rigfiles" ]]; then
    fail "[$leg] the rig path had already staged files on this host: $rigfiles"
  else
    pass "[$leg] no rig staging on the target: no /root/share, no /root/launcher3.py, no /root/gfx_hal"
  fi
}

INSTALLER_MASKSET_CMD=$(cat <<'EOF'
bash -c 'eval "$(sed -n "/^SERVER_MASKED_UNITS=(/,/)/p" "$0")"; echo "MASKSET ${SERVER_MASKED_UNITS[*]}"' /usr/bin/rhizo
EOF
)

# print each unit load problem
installer_unit_load_problems() {
  local profile="$1" masked=" $2 " u st has want
  case "$profile" in
    desktop|server) ;;
    *) echo "the host's profile read '${profile:-<empty>}', not desktop or server"; return 0 ;;
  esac
  while read -r u st has; do
    [[ -n "$u" ]] || continue
    want=loaded
    [[ "$profile" == server && "$masked" == *" $u "* ]] && want=masked
    if [[ "$st" != "$want" ]]; then
      echo "$u is ${st:-<unread>}, the $profile profile leaves it $want"
    elif [[ "$has" != 1 ]]; then
      echo "$u has no unit file under /usr/lib/systemd/system"
    fi
  done <<<"$3"
}

# print the unit problems in a guest read
installer_unit_read_problems() {
  local r="$1"
  if [[ "$r" != *$'\n'DONE ]]; then
    echo "incomplete read of the host's profile and unit states (no DONE token): $(tr '\n' ' ' <<<"${r:-<empty>}")"
    return 0
  fi
  if ! grep -q '^MASKSET [a-z]' <<<"$r"; then
    echo "the installed CLI named no SERVER_MASKED_UNITS"
    return 0
  fi
  installer_unit_load_problems "$(sed -n 's/^PROFILE //p' <<<"$r" | head -1)" \
    "$(sed -n 's/^MASKSET //p' <<<"$r" | head -1)" "$(sed -n 's/^UNIT //p' <<<"$r")"
}

INSTALLER_POLICY_SOCKET_CMD='/usr/bin/rhizo profile show 2>/dev/null | sed -n "s/^RHIZO_PROFILE profile=/PROFILE /p"
echo "STREAM $(/usr/lib/rhizo/streamd/capability-sync.sh --check)"
for u in rhizo-api.socket rhizo-streamd.socket; do
  echo "SOCKET $u $(systemctl is-enabled $u 2>&1) $(systemctl is-active $u 2>&1)"
done
echo DONE'

# print each policy socket problem
installer_policy_socket_problems() {
  local r="$1" profile stream want_api want_stream u want got
  if [[ "$r" != *$'\n'DONE ]]; then
    echo "incomplete read of the profile, stream.enabled and the two sockets (no DONE token):" \
         "$(tr '\n' ' ' <<<"${r:-<empty>}")"
    return 0
  fi
  profile=$(sed -n 's/^PROFILE //p' <<<"$r" | head -1)
  stream=$(sed -n 's/^STREAM //p' <<<"$r" | head -1)
  case "$profile" in
    desktop) want_api="disabled inactive" ;;
    server) want_api="enabled active" ;;
    *) echo "the read names no profile (${profile:-none})"; return 0 ;;
  esac
  case "$stream" in
    disable) want_stream="disabled inactive" ;;
    enable) want_stream="enabled active" ;;
    *) echo "the stream sync's --check gave no decision (${stream:-none})"; return 0 ;;
  esac
  for u in rhizo-api.socket rhizo-streamd.socket; do
    want=$want_api
    [[ "$u" == rhizo-streamd.socket ]] && want=$want_stream
    got=$(sed -n "s/^SOCKET $u //p" <<<"$r" | head -1)
    [[ "$got" == "$want" ]] \
      || echo "$u is '${got:-unread}', where the $profile profile with stream.enabled's $stream wants '$want'"
  done
}

# check the policy socket states
installer_assert_policy_sockets() {
  local leg="$1" when="$2" r problems sockets
  r=$(ssh_vm -t 60 "$INSTALLER_POLICY_SOCKET_CMD")
  printf '%s\n' "${r:-<none>}" > "$EV/$leg-policy-sockets.txt"
  problems=$(installer_policy_socket_problems "$r")
  if [[ -n "$problems" ]]; then
    fail "[$leg] $when: $(tr '\n' ';' <<<"$problems")"
    return 1
  fi
  sockets=$(sed -n 's/^SOCKET //p' <<<"$r" | tr '\n' ';')
  pass "[$leg] $when: $sockets as the $(sed -n 's/^PROFILE //p' <<<"$r") profile and stream.enabled's" \
       "$(sed -n 's/^STREAM //p' <<<"$r") decide"
}

INSTALLER_BOOT_ONLY_UNITS="androidd.service rhizo-prepare.service rhizo-policy.service rhizo-update-begin.service rhizo-update-confirm.service rhizo-selinux-mode.service rhizo-host-labels.service"

# print the start marks of each boot-only unit
installer_start_marks() {
  ssh_vm -t 30 "for u in $INSTALLER_BOOT_ONLY_UNITS; do echo \"MARK \$u \$(systemctl show -p ConditionTimestampMonotonic --value \$u 2>/dev/null) \$(systemctl show -p InactiveExitTimestampMonotonic --value \$u 2>/dev/null)\"; done; systemctl list-jobs --no-legend --plain 2>/dev/null | awk '{print \"JOB\", \$2}'; echo DONE"
}

# print each boot-only unit started between reads
installer_start_mark_problems() {
  local before="$1" after="$2" u b a
  if [[ "$before" != *DONE || "$after" != *DONE ]]; then
    echo "incomplete read of the start marks (no DONE token): before='$(tr '\n' ' ' <<<"$before")' after='$(tr '\n' ' ' <<<"$after")'"
    return 0
  fi
  for u in $INSTALLER_BOOT_ONLY_UNITS; do
    if grep -qxF "JOB $u" <<<"$after"; then
      echo "$u has a job queued after it (systemctl list-jobs)"
    fi
    b=$(sed -n "s/^MARK $u //p" <<<"$before" | head -1)
    a=$(sed -n "s/^MARK $u //p" <<<"$after" | head -1)
    if [[ ! "$b" =~ ^[0-9]+\ [0-9]+$ || ! "$a" =~ ^[0-9]+\ [0-9]+$ ]]; then
      echo "$u has no readable start marks (before='$b' after='$a')"
    elif (( ${a% *} > ${b% *} || ${a#* } > ${b#* } )); then
      echo "$u got a start job (condition/inactive-exit timestamps $b -> $a)"
    fi
  done
}

# check the boot-only units for start jobs
installer_assert_started_nothing() {
  local leg="$1" what="$2" problems
  problems=$(installer_start_mark_problems "$3" "$4")
  if [[ -n "$problems" ]]; then
    fail "[$leg] $what started what dpkg must never start: $(tr '\n' ';' <<<"$problems")"
    return 1
  fi
  pass "[$leg] $what started none of $INSTALLER_BOOT_ONLY_UNITS"
}

# install both .deb files and reboot the guest
installer_install_reboot_prepare() {
  local leg="$1" predates=0
  case "${2:-}" in
    "") ;;
    --predates-no-start) predates=1 ;;
    *) fail "[$leg] installer_install_reboot_prepare: unknown option '$2'"; return 1 ;;
  esac
  local out marks_before marks_after prep0 mode_env=""
  [[ -z "$INSTALLER_SELINUX_MODE" ]] || mode_env="RHIZO_SELINUX_MODE=$INSTALLER_SELINUX_MODE "
  marks_before=$(installer_start_marks)
  out=$(ssh_vm -t 1800 '[ -s '"$TEST_APT_OFFLINE_CONF"' ] || { echo APT_RC=NOCONF; exit; }
    cd /root/rhizo-artifact && k=; for f in ./linux-image-*rhizo_*.deb ./linux-headers-*rhizo_*.deb; do [ -e "$f" ] && k="$k $f"; done
    '"$mode_env"'APT_CONFIG='"$TEST_APT_OFFLINE_CONF"' DEBIAN_FRONTEND=noninteractive apt-get install -y $k ./rhizo_*.deb 2>&1; rc=$?; echo "APT_RC=$rc"; if [ "$rc" -ne 0 ]; then '"$mode_env"'dpkg -i $k ./rhizo_*.deb 2>&1; fi')
  echo "$out" > "$EV/$leg-install.log"
  echo "$out" | tail -25 | sed 's/^/  /'
  installer_assert_offline_apt "$leg" "$EV/$leg-install.log" "the install"
  local states
  states=$(ssh_vm -t 30 "dpkg-query -W -f='\${Package}=\${db:Status-Abbrev}\n' rhizo 2>&1; echo DONE")
  local line unconf=0
  while IFS= read -r line; do
    [[ "$line" == DONE ]] && continue
    installer_abbrev_configured "${line#*=}" || unconf=1
  done <<<"$states"
  if [[ "$states" != *$'\n'DONE ]] || (( unconf )); then
    fail "[$leg] the install left the packages as $(grep -v '^DONE$' <<<"$states" | tr '\n' ' ')-- not configured: $(grep -aE '^E: |depends on|dependency problems' <<<"$out" | head -3 | tr '\n' ' ')"
    return 1
  fi
  grep -qF "$(installer_reboot_notice)" <<<"$out" || fail "[$leg] the install did not ask for a reboot with '$(installer_reboot_notice)'"
  marks_after=$(installer_start_marks)
  printf '%s\n=== after\n%s\n' "$marks_before" "$marks_after" > "$EV/$leg-install-start-marks.txt"
  if (( predates )); then
    note "[$leg] start marks not asserted: --predates-no-start, a package built before dpkg stopped starting the boot-only units"
  else
    installer_assert_started_nothing "$leg" "the install" "$marks_before" "$marks_after"
  fi
  local unitread profile badunits
  unitread=$(ssh_vm -t 60 "/usr/bin/rhizo profile show 2>/dev/null | sed -n 's/^RHIZO_PROFILE profile=/PROFILE /p'
$INSTALLER_MASKSET_CMD
for u in androidd.service rhizo-prepare.service rhizo-hostfs.service rhizo-app-events.service; do
  echo \"UNIT \$u \$(systemctl show -p LoadState --value \$u 2>/dev/null) \$([ -f /usr/lib/systemd/system/\$u ] && echo 1 || echo 0)\"; done
echo DONE")
  profile=$(sed -n 's/^PROFILE //p' <<<"$unitread" | head -1)
  badunits=$(installer_unit_read_problems "$unitread")
  if [[ -n "$badunits" ]]; then
    fail "[$leg] systemd does not hold the shipped units the way the ${profile:-unread} profile leaves them after the install: $(tr '\n' ';' <<<"$badunits")"
  else
    pass "[$leg] every shipped unit is installed and loads, or is masked by the $profile profile"
  fi
  if declare -F installer_pre_reboot_hook >/dev/null; then
    installer_pre_reboot_hook "$leg" || return 1
  fi
  prep0=$(installer_prepare_log_lines)
  if [[ -z "$prep0" ]]; then
    fail "[$leg] could not read prepare.log's line count before the install's reboot"
    return 1
  fi
  reboot_and_wait "[$leg] install" || return 1

  step "[$leg] 8. the install's reboot runs the Rhizo kernel, which carries what Android needs"
  installer_assert_rhizo_kernel "$leg" "the install's reboot" || return 1

  step "[$leg] 9. setup finished on its own"
  installer_await_prepare "$leg" "$EV/$leg-prepare.log" "$prep0" ""
  ssh_vm -t 120 'tail -200 /var/log/rhizo/boot.log 2>/dev/null' > "$EV/$leg-android-boot.log" 2>&1
  return 0
}

# check kernel-check.sh passes on the running kernel
installer_assert_kernel_check() {
  local leg="$1" when="$2" check
  check=$(ssh_vm -t 30 '/usr/lib/rhizo/tools/kernel-check.sh 2>&1; echo "rc=$?"')
  if [[ "$check" == *rc=0 ]]; then
    pass "[$leg] $when: kernel-check.sh passes on $(ssh_vm -t 20 'uname -r' | tr -d '[:space:]'): built-in binder, /dev/ashmem and /proc/config.gz"
  else
    fail "[$leg] $when: kernel-check.sh refuses the running kernel: $(tr '\n' ' ' <<<"${check:-<no answer over ssh>}")"
    return 1
  fi
}

# print the line count of prepare.log
installer_prepare_log_lines() {
  ssh_vm -t 30 'if [ -e /var/log/rhizo/prepare.log ]; then wc -l < /var/log/rhizo/prepare.log; else echo 0; fi' \
    | grep -oE '^[0-9]+$'
}

INSTALLER_PREPARE_OUT=""
# wait for RHIZO_PREPARE_OK in prepare.log
installer_await_prepare() {
  local leg="$1" evf="$2" skip="$3" what="$4"
  [[ "$(ssh_vm -t 30 'systemctl is-active rhizo-prepare.service' | tr -d '[:space:]')" == failed ]] \
    || ssh_vm -t 60 'systemctl start --no-block rhizo-prepare.service' >/dev/null 2>&1
  local prep="" waited=0 unit_state="" cond_show=""
  while (( waited < 2100 )); do
    prep=$(ssh_vm -t 60 "tail -n +$((skip + 1)) /var/log/rhizo/prepare.log 2>/dev/null")
    grep -q 'RHIZO_PREPARE_OK\|RHIZO_PREPARE_FAILED\|RHIZO_PREPARE_REFUSED' <<<"$prep" && break
    unit_state=$(ssh_vm -t 60 'systemctl is-active rhizo-prepare.service' | tr -d '[:space:]')
    [[ "$unit_state" == failed ]] && break
    cond_show=$(ssh_vm -t 30 'systemctl show -p ConditionResult -p ConditionTimestampMonotonic rhizo-prepare.service' | tr -d '\r')
    if grep -qx 'ConditionResult=no' <<<"$cond_show" && grep -q '^ConditionTimestampMonotonic=[1-9]' <<<"$cond_show"; then
      unit_state=condition-skipped
      break
    fi
    sleep 30
    waited=$((waited + 30))
  done
  note "[$leg] prepare unit state after ${waited}s: ${unit_state:-unknown}"
  # shellcheck disable=SC2034
  INSTALLER_PREPARE_OUT="$prep"
  echo "$prep" > "$evf"
  ssh_vm -t 60 'systemctl show -p Result,ExecMainStatus,ConditionResult,ActiveState,SubState rhizo-prepare.service androidd.service; echo "=== conditions ==="; ls -la /sys/fs/selinux/enforce /var/lib/rhizo/.prepared 2>&1; ls -A /var/lib/rhizo/prepared 2>&1 | head -5; echo "lsm=$(cat /sys/kernel/security/lsm 2>&1)"; echo "cmdline=$(cat /proc/cmdline)"; echo "=== journal ==="; journalctl -u rhizo-prepare.service -n 40 --no-pager 2>&1' \
    >> "$evf" 2>&1
  if grep -q 'RHIZO_PREPARE_OK' <<<"$prep"; then
    pass "[$leg] prepare reported RHIZO_PREPARE_OK$what"
    return 0
  fi
  local cond
  cond=$(ssh_vm -t 60 'journalctl -b -u rhizo-prepare.service --no-pager 2>/dev/null | grep -c "Condition check resulted"' | tr -d '[:space:]')
  if [[ "${cond:-0}" != 0 ]]; then
    fail "[$leg] rhizo-prepare.service was SKIPPED by a condition check, not run$what (see $evf)"
  else
    fail "[$leg] prepare never reported RHIZO_PREPARE_OK$what (see $evf)"
  fi
  return 1
}

INSTALLER_APP_T0=""

# start androidd.service and check an app paints
installer_assert_app_paints() {
  local leg="$1"
  local t0 booted=0
  t0=$(guest_uptime)
  # shellcheck disable=SC2034
  INSTALLER_APP_T0="$t0"
  ssh_vm -t 600 'systemctl start androidd.service' >"$EV/$leg-start.log" 2>&1
  wait_sandbox_started 420 "$t0" && booted=1
  if (( ! booted )); then
    ssh_vm -t 120 'systemctl status androidd.service --no-pager -l 2>&1 | head -40; echo "=== journal ==="; journalctl -u androidd.service -n 60 --no-pager 2>&1' \
      > "$EV/$leg-androidd-journal.log" 2>&1
    ssh_vm -t 60 '/usr/lib/rhizo/tools/kernel-check.sh; echo "kernel-check rc=$?"' \
      >> "$EV/$leg-androidd-journal.log" 2>&1
    fail "[$leg] the sandbox did not reach boot_completed when started on demand (see $EV/$leg-androidd-journal.log)"
    return 1
  fi
  pass "[$leg] the sandbox started on demand"
  local handoff_line wl_line wl_sock
  handoff_line=$(sandbox_marker_after "$t0" 'is parked -- staging here')
  wl_line=$(sandbox_marker_after "$t0" 'wayland socket (bind-mounted|NOT FOUND|bind mount FAILED)')
  { echo "t0=$t0"
    sandbox_marker_after "$t0" 'RHIZO_MARKER launch_start sandbox=0'
    echo "$handoff_line"
    echo "$wl_line"
    sandbox_marker_after "$t0" 'EnsureWaylandConnected'
  } > "$EV/$leg-sandbox-wayland.txt" 2>&1
  note "[$leg] start: ${handoff_line:-no parked-supervisor handoff line after t0=$t0}"
  if [[ "$wl_line" != *'wayland socket bind-mounted: '* ]]; then
    fail "[$leg] the sandbox bound no compositor socket: ${wl_line:-no wayland socket line after t0=$t0} (see $EV/$leg-sandbox-wayland.txt)"
    return 1
  fi
  wl_sock=${wl_line#*bind-mounted: }
  wl_sock=${wl_sock%% -> *}
  note "[$leg] the sandbox bound compositor socket $wl_sock"
  pass "[$leg] the sandbox under test bound the compositor socket"

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
  ssh_vm -t 60 'tail -40 /run/rhizo-launch/rhizo-launch.log 2>/dev/null' > "$EV/$leg-launch.log" 2>&1
  local launched cdisp
  launched=$(cat "$EV/$leg-launch.log" 2>/dev/null)
  echo "$launched" | sed 's/^/  /'
  cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$launched" | tail -1 | cut -d= -f2)
  if [[ -z "$cdisp" ]]; then
    fail "[$leg] the launch reported no cdisplay= to screenshot"
    return 1
  fi
  note "[$leg] app launched onto composer display $cdisp"
  local mdeadline=$((SECONDS + 180)) mapped=0
  while (( SECONDS < mdeadline )); do
    if declare -F mapped_window_rect >/dev/null 2>&1; then
      mapped_window_rect "$cdisp" >/dev/null 2>&1 && { mapped=1; break; }
    elif declare -F desktop_mapped_window_rect >/dev/null 2>&1; then
      desktop_mapped_window_rect "$cdisp" 5 >/dev/null 2>&1 && { mapped=1; break; }
    else
      break
    fi
    sleep 5
  done
  if (( mapped )); then
    note "[$leg] a toplevel is mapped on display $cdisp"
  else
    if declare -F sway_windows >/dev/null 2>&1; then
      sway_windows > "$EV/$leg-sway-windows.txt" 2>&1
      declare -F swaycmd >/dev/null 2>&1 && swaycmd "-t get_tree" 120 > "$EV/$leg-sway-tree.json" 2>&1
    elif declare -F desk_windows >/dev/null 2>&1; then
      desk_windows > "$EV/$leg-sway-windows.txt" 2>&1
    fi
    declare -F rhizo_ctl_out >/dev/null 2>&1 && rhizo_ctl_out "$init_pid" > "$EV/$leg-composer-control.out" 2>&1
    note "[$leg] no toplevel mapped on display $cdisp within 180s -- asking assert_window_painted anyway"
  fi
  assert_window_painted "$leg-app" "$cdisp"
}
