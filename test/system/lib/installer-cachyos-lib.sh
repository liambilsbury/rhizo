# shellcheck shell=bash

# shellcheck source=../../../tools/fetch/pools/arch/arch-pool-lib.sh
_INSTALLER_CACHYOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_INSTALLER_CACHYOS_LIB_DIR/../../../tools/fetch/pools/arch/arch-pool-lib.sh"

# run a command on the guest over ssh
guest() { ssh_vm -t "$1" "${@:2}"; }

CACHYOS_PKG_DIR="$VAR_DIR/share/arch-pkgs"
CACHYOS_PKG_DIR_UP="$VAR_DIR/share/arch-pkgs-rel2"
CACHYOS_POOL_CONF=/root/rhizo-pool.conf
CACHYOS_POOL_CONF_CMD="{ sed -n '/^\\[options\\]/,/^\\[/{/^\\[options\\]/p;/^\\[/d;p}' /etc/pacman.conf; printf '\\n[%s]\\nSigLevel = Required DatabaseOptional\\nServer = file://%s\\n' $ARCH_POOL_REPO $ARCH_POOL_GUEST_DIR; } > $CACHYOS_POOL_CONF"
CACHYOS_ARTIFACT=/root/rhizo-artifact
CACHYOS_ARTIFACT_UP=/root/rhizo-artifact-up
CACHYOS_PKGS=()
CACHYOS_PKGS_UP=()
CACHYOS_KERNEL_PKG_DIR="${RHIZO_KERNEL_PKG_DIR:-$VAR_DIR/arch-kernel}"
CACHYOS_KERNEL_PKGS=()
CACHYOS_REMOVE_RHIZO_KERNEL_CMD='k=$(pacman -Qq linux-rhizo linux-rhizo-headers 2>/dev/null | tr "\n" " ")
echo "KERNEL_PKGS=$k"
if [ -n "$k" ]; then pacman -R --noconfirm $k 2>&1; echo "KERNEL_RC=$?"; fi'
CACHYOS_LIMINE_TOKENS_CMD='sed -n "s/^[[:space:]]*\(kernel_\)\{0,1\}cmdline:[[:space:]]*//p" /boot/limine.conf | grep -v "\.snapshots/" | grep -E "androidboot\.|loop\.max_loop=|security=selinux|lsm=[^ ]*selinux"; echo "CMDLINES=$(sed -n "s/^[[:space:]]*\(kernel_\)\{0,1\}cmdline:[[:space:]]*//p" /boot/limine.conf | grep -vc "\.snapshots/")"'

# print the rhizo package of a built set
installer_cachyos_pkgset() {
  local dir="$1" rel="$2" deb_sha src_sha src_rel f out=() how="tools/build/packaging/arch/arch-pkgs.sh"
  (( rel == 1 )) || how+=" --pkgrel $rel"
  [[ -s "$dir/SHA256SUMS" && -s "$dir/SOURCE" ]] || { echo "no $dir/SHA256SUMS or SOURCE: $how builds them"; return 1; }
  (cd "$dir" && sha256sum --quiet --strict -c SHA256SUMS) >/dev/null 2>&1 \
    || { echo "$dir's packages do not match its SHA256SUMS"; return 1; }
  deb_sha=$(sha256sum < "$RHIZO_DEB" | cut -d' ' -f1)
  src_sha=$(awk -F'\t' '$1 == "deb" { print $2 }' "$dir/SOURCE")
  [[ "$src_sha" == "$deb_sha" ]] \
    || { echo "$dir was built from a .deb of sha256 ${src_sha:-<none>}, not $(basename "$RHIZO_DEB") ($deb_sha): $how rebuilds it"; return 1; }
  src_sha=$(awk -F'\t' '$1 == "packaging" { print $2 }' "$dir/SOURCE")
  [[ -n "$src_sha" && "$src_sha" == "$("$_INSTALLER_CACHYOS_LIB_DIR/../../../tools/build/packaging/arch/arch-pkgs.sh" --packaging-digest)" ]] \
    || { echo "$dir was rendered from archlinux bytes ${src_sha:-<unrecorded>}, not this tree's: $how rebuilds it"; return 1; }
  src_rel=$(awk -F'\t' '$1 == "pkgrel" { print $2 }' "$dir/SOURCE")
  [[ "$src_rel" == "$rel" ]] || { echo "$dir's SOURCE names release '${src_rel:-<none>}', not $rel"; return 1; }
  for f in "$dir"/rhizo-[0-9]*-"$rel"-*.pkg.tar.zst; do
    [[ -f "$f" ]] && out+=("$f")
  done
  (( ${#out[@]} == 1 )) || { echo "$dir holds ${#out[@]} release-$rel rhizo packages, not one"; return 1; }
  printf '%s\n' "${out[@]}"
}

# resolve the Rhizo kernel packages rhizo depends on
installer_cachyos_kernel_pkgs() {
  local leg="$1" rhizo_pkg="$2" names files problems
  CACHYOS_KERNEL_PKGS=()
  names=$(arch_pool_pkg_kernel_names "$rhizo_pkg") \
    || { fail "[$leg] could not read the depends of $(basename "$rhizo_pkg") (see above)"; return 1; }
  if [[ -z "$names" ]]; then
    pass "[$leg] $(basename "$rhizo_pkg") depends on no Rhizo kernel package"
    return 0
  fi
  # shellcheck disable=SC2086
  files=$(arch_pool_kernel_pkgs "$CACHYOS_KERNEL_PKG_DIR" $names) \
    || { fail "[$leg] $(basename "$rhizo_pkg") depends on $(tr '\n' ' ' <<<"$names")and $CACHYOS_KERNEL_PKG_DIR does not hold one package file of each (see above)"; return 1; }
  mapfile -t CACHYOS_KERNEL_PKGS <<<"$files"
  if ! problems=$(arch_pool_kernel_problems "$SHARE_DIR/arch-pool" "${CACHYOS_KERNEL_PKGS[@]}"); then
    fail "[$leg] the offline pool does not carry what the Rhizo kernel packages depend on: $(tr '\n' ';' <<<"$problems")"
    return 1
  fi
  pass "[$leg] $(basename "$rhizo_pkg") depends on $(tr '\n' ' ' <<<"$names")which cross as $(for f in "${CACHYOS_KERNEL_PKGS[@]}"; do printf '%s ' "${f##*/}"; done)beside it, their depends carried by the pool"
}

# remove the Rhizo kernel packages by name
installer_cachyos_remove_rhizo_kernel() {
  local leg="$1" log="$2" out pkgs rc
  out=$(ssh_vm -t 900 "$CACHYOS_REMOVE_RHIZO_KERNEL_CMD")
  printf '%s\n' "${out:-<no answer over ssh>}" > "$log"
  if ! grep -q '^KERNEL_PKGS=' <<<"$out"; then
    fail "[$leg] could not list the installed Rhizo kernel packages: $(head -3 <<<"${out:-<no answer over ssh>}" | tr '\n' ' ')(see $log)"
    return 1
  fi
  pkgs=$(sed -n 's/^KERNEL_PKGS= *//p' <<<"$out")
  rc=$(sed -n 's/^KERNEL_RC=//p' <<<"$out" | tail -1)
  if [[ -z "${pkgs// /}" ]]; then
    (( ${#CACHYOS_KERNEL_PKGS[@]} == 0 )) \
      || { fail "[$leg] rhizo depends on the Rhizo kernel, and no Rhizo kernel package was installed to remove (see $log)"; return 1; }
    pass "[$leg] no Rhizo kernel package was installed"
  elif [[ "$rc" == 0 ]]; then
    pass "[$leg] pacman -R removed the Rhizo kernel by name: ${pkgs% }"
  else
    fail "[$leg] pacman -R of the Rhizo kernel (${pkgs% }) exited ${rc:-<no status recorded>} (see $log)"
    return 1
  fi
}

# print the name and version of a package
installer_cachyos_pkg_id() {
  tar --zstd -xOf "$1" .PKGINFO | awk -F' = ' '$1 == "pkgname" { n = $2 } $1 == "pkgver" { v = $2 } END { print n, v }'
}

# copy packages to a guest directory
installer_cachyos_transfer() {
  local leg="$1" dir="$2" crossed want; shift 2
  ssh_vm -t 30 "rm -rf $dir && mkdir -p $dir" || { fail "[$leg] could not empty $dir on the guest"; return 1; }
  timeout 900 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$@" "$SSH_TARGET:$dir/" \
    || { fail "[$leg] could not transfer the packages to $dir"; return 1; }
  crossed=$(ssh_vm -t 30 "ls $dir | sort | tr '\n' ' '")
  want=$(for f in "$@"; do basename "$f"; done | sort | tr '\n' ' ')
  note "[$leg] crossed into $dir: $crossed"
  [[ "$crossed" == "$want" ]] || { fail "[$leg] $dir holds '$crossed', not the packages '$want'"; return 1; }
}

# install packages with pacman -U
installer_cachyos_pacman_u() {
  local leg="$1" what="$2" dir="$3" names="" f out; shift 3
  for f in "$@"; do names+=" ./$(basename "$f")"; done
  out=$(ssh_vm -t 1800 "$CACHYOS_POOL_CONF_CMD && cd $dir && ${INSTALLER_SELINUX_MODE:+RHIZO_SELINUX_MODE=$INSTALLER_SELINUX_MODE }pacman --config $CACHYOS_POOL_CONF -U --noconfirm$names 2>&1; echo PACMAN_RC=\$?")
  printf '%s\n' "$out" > "$EV/$leg-$what.log"
  tail -15 <<<"$out" | sed 's/^/  /'
  grep -qx 'PACMAN_RC=0' <<<"$out" || { fail "[$leg] pacman -U ($what) exited $(sed -n 's/^PACMAN_RC=//p' <<<"$out" | tail -1) (see $EV/$leg-$what.log)"; return 1; }
  if grep -qE '(https?|ftp)://' <<<"$out"; then
    fail "[$leg] pacman reached a remote server during $what: $(grep -m1 -oE '(https?|ftp)://[^ ]*' <<<"$out") (see $EV/$leg-$what.log)"
    return 1
  fi
  pass "[$leg] pacman -U ($what) resolved from the offline pool and exited 0"
}

# check pacman holds the given packages
installer_cachyos_assert_held() {
  local leg="$1" what="$2" f id name ver got bad=0; shift 2
  for f in "$@"; do
    id=$(installer_cachyos_pkg_id "$f"); read -r name ver <<<"$id"
    got=$(ssh_vm -t 20 "pacman -Q $name 2>&1")
    if [[ "$got" != "$name $ver" ]]; then
      fail "[$leg] after $what pacman holds '$got', want '$name $ver'"; bad=1
    fi
  done
  (( bad )) || pass "[$leg] after $what pacman holds $(for f in "$@"; do installer_cachyos_pkg_id "$f"; done | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  return "$bad"
}

# check the load state of shipped units
installer_cachyos_assert_units() {
  local leg="$1" unitread profile badunits
  unitread=$(ssh_vm -t 60 "/usr/bin/rhizo profile show 2>/dev/null | sed -n 's/^RHIZO_PROFILE profile=/PROFILE /p'
$INSTALLER_MASKSET_CMD
for u in androidd.service rhizo-prepare.service rhizo-hostfs.service rhizo-app-events.service; do
  echo \"UNIT \$u \$(systemctl show -p LoadState --value \$u 2>/dev/null) \$([ -f /usr/lib/systemd/system/\$u ] && echo 1 || echo 0)\"; done
echo DONE")
  profile=$(sed -n 's/^PROFILE //p' <<<"$unitread" | head -1)
  badunits=$(installer_unit_read_problems "$unitread")
  if [[ -n "$badunits" ]]; then
    fail "[$leg] systemd does not hold the shipped units the way the ${profile:-unread} profile leaves them: $(tr '\n' ';' <<<"$badunits")"
    return 1
  fi
  pass "[$leg] every shipped unit is installed and loads, or is masked by the $profile profile"
}

# check limine.conf for Rhizo cmdline tokens
installer_cachyos_assert_boot_tokens() {
  local leg="$1" when="$2" want="$3" out n hits markers
  out=$(ssh_vm -t 20 "$CACHYOS_LIMINE_TOKENS_CMD; echo \"MARKERS=\$(grep -c '^# >>> rhizo' /etc/default/limine)\"")
  printf '%s\n' "$out" > "$EV/$leg-boot-tokens-$when.txt"
  n=$(sed -n 's/^CMDLINES=//p' <<<"$out")
  markers=$(sed -n 's/^MARKERS=//p' <<<"$out")
  hits=$(grep -vE '^(CMDLINES|MARKERS)=' <<<"$out" | grep -c .)
  [[ "$n" =~ ^[1-9][0-9]*$ && "$markers" =~ ^[0-9]+$ ]] \
    || { fail "[$leg] $when: could not read limine's cmdlines and block (cmdlines '$n', markers '$markers')"; return 1; }
  if [[ "$want" == absent ]]; then
    (( hits == 0 && markers == 0 )) \
      && pass "[$leg] $when: none of limine's $n next-boot cmdlines carries a Rhizo token, and /etc/default/limine no rhizo block" \
      || fail "[$leg] $when: $hits of limine's $n cmdlines carry a Rhizo token, /etc/default/limine $markers rhizo block(s) (see $EV/$leg-boot-tokens-$when.txt)"
  else
    (( hits == n && markers == 1 )) \
      && pass "[$leg] $when: all $n of limine's next-boot cmdlines carry Rhizo's tokens, from one rhizo block" \
      || fail "[$leg] $when: $hits of limine's $n cmdlines carry Rhizo's tokens, /etc/default/limine $markers rhizo block(s) (see $EV/$leg-boot-tokens-$when.txt)"
  fi
}

# check the pacman DownloadUser setting
installer_cachyos_assert_downloaduser() {
  local leg="$1" when="$2" want="$3" got
  got=$(ssh_vm -t 20 'pacman-conf DownloadUser; echo "RC=$?"')
  if [[ "$want" == alpm ]]; then
    [[ "$got" == $'alpm\nRC=0' ]] && pass "[$leg] $when: pacman's DownloadUser is alpm again" \
      || fail "[$leg] $when: pacman-conf DownloadUser read '$(tr '\n' ' ' <<<"$got")', want alpm"
  else
    [[ "$got" == $'RC=0' || "$got" == $'RC=1' ]] && pass "[$leg] $when: pacman's DownloadUser is commented out" \
      || fail "[$leg] $when: pacman-conf DownloadUser read '$(tr '\n' ' ' <<<"$got")', want none set"
  fi
}

# check prepare released its setup boot
installer_cachyos_assert_released() {
  local leg="$1" prep="$2" sock_line active
  sock_line=$(grep -o 'setup boot socket: .*' <<<"$prep" | tail -1)
  note "[$leg] prepare's ${sock_line:-setup boot socket: <no such line>}"
  grep -qF 'releasing the setup boot: socket ' <<<"$prep" \
    || { fail "[$leg] prepare kept its setup boot (${sock_line:-no setup boot socket: line})"; return 1; }
  grep -qF 'resident supervisor parked -- the next start hands off' <<<"$prep" \
    || { fail "[$leg] prepare released its setup boot but reported no parked supervisor"; return 1; }
  active=$(ssh_vm -t 30 'systemctl is-active androidd.service' | tr -d '[:space:]')
  [[ "$active" != active ]] || { fail "[$leg] androidd.service is still active after prepare released its setup boot"; return 1; }
  pass "[$leg] setup released its sandbox (androidd.service ${active:-unknown}) with the supervisor parked"
}

# check the guest pool and its pacman conf
installer_cachyos_assert_pool() {
  local leg="$1" out
  arch_pool_stage >"$EV/$leg-arch-pool.log" 2>&1 \
    || { fail "[$leg] the pool on the guest is not the one POOL.sha256 records (see $EV/$leg-arch-pool.log)"; return 1; }
  arch_pool_options_match >>"$EV/$leg-arch-pool.log" 2>&1 \
    || { fail "[$leg] the pool's pacman.conf [options] are not the host's own (see $EV/$leg-arch-pool.log)"; return 1; }
  out=$(ssh_vm -t 20 "$CACHYOS_POOL_CONF_CMD; pacman-conf --config $CACHYOS_POOL_CONF --repo-list; for r in \$(pacman-conf --config $CACHYOS_POOL_CONF --repo-list); do pacman-conf --config $CACHYOS_POOL_CONF --repo \$r Server; done")
  printf '%s\n' "$out" >> "$EV/$leg-arch-pool.log"
  [[ "$out" == "$ARCH_POOL_REPO"$'\n'"file://$ARCH_POOL_GUEST_DIR" ]] \
    || { fail "[$leg] the pool's conf names more than the pool: $(tr '\n' ' ' <<<"$out")"; return 1; }
  pass "[$leg] pacman under the pool's conf reads one repository, $ARCH_POOL_REPO, at file://$ARCH_POOL_GUEST_DIR"
}

# install plasma-wayland-protocols and foot from the pool
installer_cachyos_stage_harness() {
  local leg="$1" out
  out=$(ssh_vm -t 300 "$CACHYOS_POOL_CONF_CMD && pacman --config $CACHYOS_POOL_CONF -Sy --needed --noconfirm plasma-wayland-protocols foot 2>&1; echo PACMAN_RC=\$?")
  printf '%s\n' "$out" > "$EV/$leg-harness-deps.log"
  grep -qx 'PACMAN_RC=0' <<<"$out" \
    || { fail "[$leg] plasma-wayland-protocols and foot did not install from the pool (see $EV/$leg-harness-deps.log)"; return 1; }
}

# install packages and reboot the guest
installer_cachyos_install_reboot_prepare() {
  local leg="$1" what="$2" dir="$3" marks_before marks_after prep0; shift 3
  installer_cachyos_transfer "$leg" "$dir" "$@" || return 1
  marks_before=$(installer_start_marks)
  installer_cachyos_pacman_u "$leg" "$what" "$dir" "$@" || return 1
  grep -qF "$(installer_reboot_notice)" "$EV/$leg-$what.log" \
    && pass "[$leg] the $what asked for a reboot" || { fail "[$leg] the $what did not ask for a reboot with '$(installer_reboot_notice)'"; return 1; }
  installer_cachyos_assert_held "$leg" "the $what" "$@" || return 1
  installer_cachyos_assert_units "$leg"
  installer_cachyos_assert_boot_tokens "$leg" "after-$what" present
  if [[ "$INSTALLER_SELINUX_MODE" == host ]]; then
    installer_cachyos_assert_downloaduser "$leg" "after the $what" off
  else
    installer_cachyos_assert_downloaduser "$leg" "after the $what" alpm
  fi
  marks_after=$(installer_start_marks)
  printf '%s\n=== after\n%s\n' "$marks_before" "$marks_after" > "$EV/$leg-$what-start-marks.txt"
  installer_assert_started_nothing "$leg" "the $what" "$marks_before" "$marks_after"
  prep0=$(installer_prepare_log_lines)
  [[ -n "$prep0" ]] || { fail "[$leg] could not read prepare.log's line count before the $what's reboot"; return 1; }
  reboot_and_wait "[$leg] $what" || return 1
  installer_assert_rhizo_kernel "$leg" "the $what's reboot" || return 1
  local plog="$EV/$leg-prepare-$what.log"
  [[ "$what" == install ]] && plog="$EV/$leg-prepare.log"
  installer_await_prepare "$leg" "$plog" "$prep0" " after the $what" || return 1
  ssh_vm -t 120 'tail -200 /var/log/rhizo/boot.log 2>/dev/null' > "$EV/$leg-android-boot-$what.log" 2>&1
}

# print each rig-path trace in the packages
installer_cachyos_rig_hits() {
  local t names body bad
  for t in "$@"; do
    names=$(tar --zstd -tf "$t")
    for bad in sync.sh redeploy.sh provision-pristine.sh run-vm.sh; do
      grep -q "/$bad\$" <<<"$names" && printf ' %s:%s' "$(basename "$t")" "$bad"
    done
    body=$(tar --zstd -xOf "$t" 2>/dev/null | tr -c '[:print:]\n' ' ')
    for bad in 'trans=virtio' '9p2000.L' 'var/vm'; do
      grep -qF "$bad" <<<"$body" && printf ' %s:%s' "$(basename "$t")" "$bad"
    done
  done
  return 0
}

# run the cachyos install and removal leg
run_leg_cachyos() {
  local leg="$1" pkgset disk base_sha pool_sha prep0 out t
  export RHIZO_CACHYOS_BASE="${RHIZO_CACHYOS_BASE:-cachyos-stock}"

  step "[$leg] 0c. the pacman packages, built from this .deb at release 1 and 2"
  pkgset=$(installer_cachyos_pkgset "$CACHYOS_PKG_DIR" 1) || { fail "[$leg] $pkgset"; return 1; }
  mapfile -t CACHYOS_PKGS <<<"$pkgset"
  pkgset=$(installer_cachyos_pkgset "$CACHYOS_PKG_DIR_UP" 2) || { fail "[$leg] $pkgset"; return 1; }
  mapfile -t CACHYOS_PKGS_UP <<<"$pkgset"
  installer_cachyos_kernel_pkgs "$leg" "${CACHYOS_PKGS[0]}" || return 1
  for t in "${CACHYOS_PKGS[@]}" "${CACHYOS_PKGS_UP[@]}" "${CACHYOS_KERNEL_PKGS[@]}"; do note_artifact "$t"; done
  local rig_hits
  rig_hits=$(installer_cachyos_rig_hits "${CACHYOS_PKGS[@]}" "${CACHYOS_PKGS_UP[@]}")
  [[ -z "$rig_hits" ]] && pass "[$leg] neither release's packages carry a trace of the rig path" \
    || { fail "[$leg] the pacman packages carry the rig path:$rig_hits"; return 1; }

  step "[$leg] 2. the stock base the pool was fetched for"
  base_sha=$(sha256sum "$VAR_DIR/$(guest_base cachyos grub)" | cut -d' ' -f1)
  pool_sha=$(cut -d' ' -f1 "$SHARE_DIR/arch-pool/POOL.base")
  [[ -n "$base_sha" && "$base_sha" == "$pool_sha" ]] \
    && pass "[$leg] $RHIZO_CACHYOS_BASE is the base arch-pool was fetched against (sha256 ${base_sha:0:16})" \
    || { fail "[$leg] $RHIZO_CACHYOS_BASE (sha256 ${base_sha:-<unread>}) is not the base the pool names ($(cat "$SHARE_DIR/arch-pool/POOL.base"))"; return 1; }

  disk="$VAR_DIR/$(guest_disk cachyos grub "$SUFFIX")"
  if (( REUSE_DISK )); then
    note "[$leg] REUSE-DISK: this disk was NOT recreated"
  else
    step "[$leg] 3. a disk with no other ancestry"
    kill_vm >/dev/null 2>&1
    rm -f "$disk"
    note "[$leg] deleted $(basename "$disk") -- this leg starts from $RHIZO_CACHYOS_BASE"
  fi

  step "[$leg] 4. limine boot, stock state observed from inside"
  installer_assert_stock "$leg" || return 1

  step "[$leg] 5a. pacman's only source is the offline pool"
  installer_cachyos_assert_pool "$leg" || return 1

  step "[$leg] 5. the stock Plasma desktop, its person logged in on seat0"
  out=$(ssh_vm -t 20 'getent passwd 1000 | cut -d: -f1; [ -L /etc/systemd/system/display-manager.service ] && echo DM_ENABLED')
  [[ "$out" == "$INSTALLER_DESKTOP_HUMAN"$'\n'DM_ENABLED ]] \
    || { fail "[$leg] the stock base is not a desktop with $INSTALLER_DESKTOP_HUMAN at uid 1000 and its display manager enabled: $(tr '\n' ' ' <<<"$out")"; return 1; }
  installer_cachyos_stage_harness "$leg" || return 1
  "$_INSTALLER_CACHYOS_LIB_DIR/../../vm/start/start-plasma.sh" --stage-login --user "$INSTALLER_DESKTOP_HUMAN" >"$EV/$leg-seat-login-stage.log" 2>&1 \
    || { fail "[$leg] the Plasma seat login of $INSTALLER_DESKTOP_HUMAN did not come up on the stock host (see $EV/$leg-seat-login-stage.log)"; return 1; }
  pass "[$leg] $INSTALLER_DESKTOP_HUMAN's Plasma login runs on the stock host, as every later boot's login will"

  step "[$leg] 5c. host snapshot before Rhizo touches anything"
  rm -f "$EV/$leg"-pkgwin-*.log "$EV/$leg"-owned-*.tsv
  take_snapshot "[$leg] before" "$EV/$leg-snapshot-before.tsv" || return 1
  pass "[$leg] pre-install host snapshot captured"

  step "[$leg] 6b. seed the GSI download the guest cannot make"
  installer_seed_gsi_zip "$leg" || return 1

  step "[$leg] 6-9. only the packages cross; one pacman -U, one reboot, the kernel checked, setup finished on its own"
  out=$(ssh_vm -t 30 'ls -d /root/launcher3.py /root/gfx_hal /usr/lib/rhizo /etc/rhizo 2>/dev/null | tr "\n" " "')
  [[ -z "$out" ]] && pass "[$leg] no rig-staged file and no Rhizo path is on the target before the install" \
    || { fail "[$leg] the target already holds $out"; return 1; }
  test_pkgwin rhizo-install step7-install installer_cachyos_install_reboot_prepare "$leg" install "$CACHYOS_ARTIFACT" "${CACHYOS_PKGS[@]}" "${CACHYOS_KERNEL_PKGS[@]}" \
    || return 1

  step "[$leg] 9a. the profile's and stream.enabled's sockets after the install"
  installer_assert_policy_sockets "$leg" "after the install and its reboot" || return 1

  step "[$leg] 9b. the session starts after setup, onto a released sandbox"
  installer_cachyos_assert_released "$leg" "$INSTALLER_PREPARE_OUT" || return 1
  desk_session_up >"$EV/$leg-plasma.log" 2>&1 \
    || { fail "[$leg] the Plasma seat login did not come up after setup (see $EV/$leg-plasma.log)"; return 1; }
  pass "[$leg] the seat login's KWin answers, after setup and before the first start"

  step "[$leg] 10. a real app in a real composited frame"
  installer_assert_app_paints "$leg" || return 1
  keymint_leg "$leg" "$INIT" "$INSTALLER_APP_T0" || return 1

  step "[$leg] 11. release 1 -> 2: pacman -U of the rhizo package"
  installer_cachyos_transfer "$leg" "$CACHYOS_ARTIFACT_UP" "${CACHYOS_PKGS_UP[@]}" || return 1
  test_pkgwin rhizo-install step11-upgrade installer_cachyos_pacman_u "$leg" upgrade "$CACHYOS_ARTIFACT_UP" "${CACHYOS_PKGS_UP[@]}" \
    || return 1
  installer_cachyos_assert_held "$leg" "the upgrade" "${CACHYOS_PKGS_UP[@]}" || return 1
  local old_ver from status
  old_ver=$(installer_cachyos_pkg_id "${CACHYOS_PKGS[0]}" | cut -d' ' -f2)
  from=$(ssh_vm -t 20 'cat /var/lib/rhizo/.upgrade-from 2>&1' | tr -d '\r')
  [[ "$from" == "$old_ver" ]] && pass "[$leg] pre_upgrade recorded the replaced release, $from" \
    || fail "[$leg] /var/lib/rhizo/.upgrade-from reads '$from', want the replaced release $old_ver"
  status=$(ssh_vm -t 60 '/usr/bin/rhizo status 2>&1')
  printf '%s\n' "$status" > "$EV/$leg-status-after-upgrade.txt"
  grep -q '^RHIZO_STATUS .* setup=pending-reboot\b' <<<"$status" && pass "[$leg] rhizo status reads setup=pending-reboot after the upgrade" \
    || fail "[$leg] rhizo status after the upgrade reads '$(grep -m1 '^RHIZO_STATUS' <<<"$status")', want setup=pending-reboot"
  prep0=$(installer_prepare_log_lines)
  [[ -n "$prep0" ]] || { fail "[$leg] could not read prepare.log's line count before the upgrade's reboot"; return 1; }
  reboot_and_wait "[$leg] upgrade" || return 1
  installer_assert_rhizo_kernel "$leg" "the upgrade's reboot" || return 1
  installer_await_prepare "$leg" "$EV/$leg-prepare-after-upgrade.log" "$prep0" " after the upgrade" || return 1
  grep -m1 'RHIZO_PREPARE_OK' <<<"$INSTALLER_PREPARE_OUT" | grep -q 'data=kept' \
    && pass "[$leg] prepare reported data=kept after the upgrade" \
    || fail "[$leg] prepare after the upgrade did not report data=kept: $(grep -m1 'RHIZO_PREPARE_OK' <<<"$INSTALLER_PREPARE_OUT")"
  installer_assert_kernel_check "$leg" "after the upgrade's reboot"

  step "[$leg] 12a. pacman -R rhizo"
  local remove_marker
  remove_marker="test-remove-$(date +%s%N)"
  ssh_vm -t 20 "echo $remove_marker > /var/lib/rhizo/.test-remove-marker" \
    || { fail "[$leg] could not write the marker the remove must keep"; return 1; }
  out=$(ssh_vm -t 900 'pacman -R --noconfirm rhizo 2>&1; echo PACMAN_RC=$?')
  printf '%s\n' "$out" > "$EV/$leg-remove.log"
  tail -15 <<<"$out" | sed 's/^/  /'
  grep -qx 'PACMAN_RC=0' <<<"$out" || { fail "[$leg] pacman -R exited $(sed -n 's/^PACMAN_RC=//p' <<<"$out") (see $EV/$leg-remove.log)"; return 1; }
  out=$(ssh_vm -t 30 'pacman -Q rhizo 2>&1; echo "UNITS=$(systemctl list-unit-files "rhizo*" androidd.service --no-legend | awk "{ print \$1 }" | tr "\n" " ")"; [ -s /var/lib/rhizo/data.img ] && echo DATA_KEPT')
  printf '%s\n' "$out" >> "$EV/$leg-remove.log"
  [[ "$(grep -c "was not found" <<<"$out")" == 1 ]] && pass "[$leg] pacman no longer holds rhizo after the remove" \
    || fail "[$leg] after pacman -R: $(head -1 <<<"$out")"
  [[ "$(sed -n 's/^UNITS=//p' <<<"$out")" =~ ^(rhizo-final-cleanup\.service\ )?$ ]] \
    && pass "[$leg] no shipped unit is left installed, beside the cleanup the next boot runs" \
    || fail "[$leg] unit files remain after the remove: $(sed -n 's/^UNITS=//p' <<<"$out")"
  grep -qx DATA_KEPT <<<"$out" && pass "[$leg] the remove kept /var/lib/rhizo/data.img" \
    || fail "[$leg] the remove did not keep /var/lib/rhizo/data.img"
  installer_cachyos_assert_boot_tokens "$leg" after-remove absent
  installer_cachyos_assert_downloaduser "$leg" "after the remove" alpm

  step "[$leg] 12c. reboot after the remove: the host's own LSMs, no Rhizo token on the cmdline"
  reboot_and_wait "[$leg] remove" || return 1
  installer_assert_stock_cachyos "$leg"
  out=$(ssh_vm -t 30 'echo "UNITS=$(systemctl list-unit-files "rhizo*" androidd.service --no-legend | wc -l)"; [ -s /var/lib/rhizo/data.img ] && echo DATA_KEPT')
  [[ "$out" == $'UNITS=0\nDATA_KEPT' ]] \
    && pass "[$leg] after the remove's reboot no Rhizo unit is left, the cleanup's own included, and data.img is kept" \
    || fail "[$leg] after the remove's reboot: $(tr '\n' ' ' <<<"$out")"

  step "[$leg] 12d. host-snapshot diff: pacman -R kept only what the census explains"
  take_snapshot "[$leg] after-remove" "$EV/$leg-snapshot-after-remove.tsv" || return 1
  host_census_snapshot_diff "$leg" remove installer \
    && pass "[$leg] host-snapshot diff (remove): every difference is explained or allowlisted, every allowlist row matched" \
    || fail "[$leg] host-snapshot diff (remove) found unexplained state (first: $(grep -m1 '^FAIL' "$EV/$leg-snapshot-diff-remove.txt"); full list in $EV/$leg-snapshot-diff-remove.txt)"

  step "[$leg] 12e. reinstall after a plain remove"
  test_pkgwin rhizo-install step12e-reinstall installer_cachyos_pacman_u "$leg" reinstall "$CACHYOS_ARTIFACT_UP" "${CACHYOS_PKGS_UP[@]}" \
    || return 1
  grep -qF "$(installer_reboot_notice)" "$EV/$leg-reinstall.log" && pass "[$leg] the reinstall asked for a reboot" \
    || { fail "[$leg] the reinstall after a plain remove did not ask for a reboot"; return 1; }
  prep0=$(installer_prepare_log_lines)
  [[ -n "$prep0" ]] || { fail "[$leg] could not read prepare.log's line count before the reinstall's reboot"; return 1; }
  reboot_and_wait "[$leg] reinstall-after-remove" || return 1
  installer_assert_rhizo_kernel "$leg" "the reinstall's reboot" || return 1

  step "[$leg] 12g. prepare re-runs after reinstall, keeps data, and a real app still launches"
  installer_await_prepare "$leg" "$EV/$leg-prepare-after-remove-reinstall.log" "$prep0" \
    " after the remove+reinstall cycle" || return 1
  grep -m1 'RHIZO_PREPARE_OK' <<<"$INSTALLER_PREPARE_OUT" | grep -q 'data=kept' \
    && pass "[$leg] prepare reported data=kept -- the reinstall did not touch the surviving data.img" \
    || fail "[$leg] prepare did not report data=kept after the remove+reinstall: $(grep -m1 'RHIZO_PREPARE_OK' <<<"$INSTALLER_PREPARE_OUT")"
  out=$(ssh_vm -t 30 'cat /var/lib/rhizo/.test-remove-marker 2>/dev/null' | tr -d '[:space:]')
  [[ "$out" == "$remove_marker" ]] && pass "[$leg] the marker written before the remove survived it byte for byte" \
    || fail "[$leg] the marker written before the remove read back as '${out:-<gone>}', want '$remove_marker'"
  desk_session_up >"$EV/$leg-plasma-after-reinstall.log" 2>&1 \
    || { fail "[$leg] the Plasma seat login did not come up after the reinstall (see $EV/$leg-plasma-after-reinstall.log)"; return 1; }
  installer_assert_app_paints "$leg-reinstall" || return 1

  step "[$leg] 12h. rhizo uninstall --purge removes what a plain remove keeps"
  out=$(ssh_vm -t 900 'RHIZO_ASSUME_YES=1 /usr/bin/rhizo uninstall --purge 2>&1; echo PURGE_RC=$?')
  printf '%s\n' "$out" > "$EV/$leg-purge.log"
  tail -15 <<<"$out" | sed 's/^/  /'
  grep -qx 'PURGE_RC=0' <<<"$out" || { fail "[$leg] rhizo uninstall --purge exited $(sed -n 's/^PURGE_RC=//p' <<<"$out") (see $EV/$leg-purge.log)"; return 1; }
  out=$(ssh_vm -t 30 'pacman -Q rhizo 2>&1 | grep -c "was not found"')
  [[ "$out" == 1 ]] && pass "[$leg] pacman no longer holds rhizo after the purge" \
    || fail "[$leg] pacman still holds a Rhizo package after the purge (see $EV/$leg-purge.log)"
  installer_cachyos_assert_boot_tokens "$leg" after-purge absent
  installer_cachyos_assert_downloaduser "$leg" "after the purge" alpm
  installer_cachyos_remove_rhizo_kernel "$leg" "$EV/$leg-remove-kernel.log" || return 1

  step "[$leg] 12i. after the purge reboot, the host is stock"
  reboot_and_wait "[$leg] purge" || return 1
  installer_assert_stock_cachyos "$leg"
  out=$(ssh_vm -t 30 'ls -d /var/lib/rhizo /etc/rhizo /srv/rhizo /usr/lib/rhizo /var/cache/rhizo /var/log/rhizo 2>/dev/null | tr "\n" " "; echo; btrfs subvolume list / | grep -c rhizo; systemctl list-unit-files "rhizo*" androidd.service --no-legend | wc -l')
  printf '%s\n' "$out" >> "$EV/$leg-purge.log"
  [[ -z "$(sed -n 1p <<<"$out" | tr -d ' ')" ]] \
    && pass "[$leg] the purge and its cleanup took /var/lib/rhizo, /etc/rhizo, /srv/rhizo, /usr/lib/rhizo and Rhizo's cache and logs" \
    || fail "[$leg] after the purge's reboot these remain: $(sed -n 1p <<<"$out")"
  [[ "$(sed -n 2p <<<"$out")" == 0 ]] && pass "[$leg] no btrfs subvolume names rhizo after the purge" \
    || fail "[$leg] $(sed -n 2p <<<"$out") btrfs subvolume(s) still name rhizo after the purge"
  [[ "$(sed -n 3p <<<"$out")" == 0 ]] && pass "[$leg] no Rhizo unit is left after the purge's reboot" \
    || fail "[$leg] $(sed -n 3p <<<"$out") Rhizo unit file(s) remain after the purge's reboot"

  step "[$leg] 12j. host-snapshot diff: the purge returns the host to stock"
  take_snapshot "[$leg] after-purge" "$EV/$leg-snapshot-after-purge.tsv" || return 1
  host_census_snapshot_diff "$leg" purge installer \
    && pass "[$leg] host-snapshot diff (purge): the host matches its pre-install state, modulo the allowlist" \
    || fail "[$leg] host-snapshot diff (purge) found unexplained state (first: $(grep -m1 '^FAIL' "$EV/$leg-snapshot-diff-purge.txt"); full list in $EV/$leg-snapshot-diff-purge.txt)"
  return 0
}
