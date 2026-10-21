#!/bin/bash
# test the LSM bootstrap from a stock image
# RHIZO_GUEST_OS=cachyos runs the cycle on the CachyOS pristine base RHIZO_CACHYOS_BASE names
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: boot-smoke.sh
# test-records-metrics: no
# test-verdict-params: boot=grub new_disk=1
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

REUSE_DISK=0
BOOTSTRAP_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-contract) source ../../vm/common.sh; source ../lib/lib.sh
                       test_print_contract "${BASH_SOURCE[0]}"; exit $? ;;
    --reuse-disk) REUSE_DISK=1; shift ;;
    --bootstrap-only) BOOTSTRAP_ONLY=1; shift ;;
    --instance) RHIZO_VM="$2"; export RHIZO_VM; shift 2 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done
export RHIZO_BOOT=grub
source ../../vm/common.sh
source ../lib/lib.sh
source ../../vm/guest-os/guest-os-lib.sh
guest_os_valid "$RHIZO_GUEST_OS" || { echo "unknown RHIZO_GUEST_OS '$RHIZO_GUEST_OS' (ubuntu or cachyos)" >&2; exit 2; }

EV_TOKEN=""
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  CACHYOS_BL=$(cachyos_base_bootloader "$RHIZO_CACHYOS_BASE" RHIZO_CACHYOS_BASE) || exit 2
  read -r CACHYOS_KIND CACHYOS_CONF CACHYOS_GEN <<<"$(cachyos_bootloader_files "$CACHYOS_BL")"
  EV_TOKEN="$RHIZO_CACHYOS_BASE"
elif (( BOOTSTRAP_ONLY )); then
  EV_TOKEN=bootstrap-only
fi
EV="$(test_evidence_dir lsm-bootstrap "$EV_TOKEN")"
mkdir -p "$EV"
EV_FILES=(bootstrap-run.log bootstrap-verify.log bootstrap-second-run.log provision.log test-boot-smoke.log)
[[ "$RHIZO_GUEST_OS" == cachyos ]] && EV_FILES+=(efibootmgr-first-boot.txt stock-state.txt bootstrap-show.txt
  config-after-bootstrap.txt next-boot-cmdlines.txt second-run-sha256.txt attr-current.txt)
for f in "${EV_FILES[@]}"; do
  echo "<none: this run did not reach the step that writes $f>" > "$EV/$f"
done
# shellcheck disable=SC2034
TEST_NAME="lsm-bootstrap"
test_trap_signals
rig_test_started
# shellcheck disable=SC2034
TEST_VERDICT_RECORDED=0
trap test_cleanup EXIT
SUMMARY="$(rig_result_path "$EV/summary.txt")"
: > "$SUMMARY"
FAILED=0
# log a failure and record it in the summary
fail() { log "FAIL: $*"; echo "FAIL: $*" >> "$SUMMARY"; FAILED=1; }
# log a line and record it in the summary
note() { log "  $*"; echo "$*" >> "$SUMMARY"; }
# fail for each output line of a check
fail_each() {
  local line any=0
  (( $1 )) || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] && { fail "$line"; any=1; }
  done <<<"$3"
  (( any )) || fail "$2 exited $1 and named nothing"
}

BOOTSTRAP="$REPO/src/install/bootstrap/bootstrap.sh"
[[ -f "$BOOTSTRAP" ]] || { fail "no $BOOTSTRAP"; exit 1; }

# wait until the guest answers ssh again
wait_back() {
  local deadline=$((SECONDS + ${1:-300}))
  while (( SECONDS < deadline )); do
    wait_for_ssh 5 >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

step "1. the pinned, verified stock image"
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  out=$(cd "$VAR_DIR/cachyos-dl" && sha256sum -c "$RHIZO_CACHYOS_BASE.sha256" 2>&1)
  rc=$?
  echo "$out" | sed 's/^/  /'
  (( rc == 0 )) || { fail "cachyos-dl/$RHIZO_CACHYOS_BASE.sha256 does not verify (rc $rc): $out"; exit 1; }
  note "verified cachyos-dl/$RHIZO_CACHYOS_BASE.qcow2 and its OVMF vars against $RHIZO_CACHYOS_BASE.sha256 ($CACHYOS_BL)"
else
  ../../../tools/fetch/images/ubuntu-base.sh 2>&1 | sed 's/^/  /' || { fail "ubuntu-base.sh failed"; exit 1; }
fi

DISK="$VAR_DIR/$(guest_disk "$RHIZO_GUEST_OS" grub "$SUFFIX")"
VARS="$(guest_vars "$RHIZO_GUEST_OS" grub "$SUFFIX")"
if (( REUSE_DISK )); then
  note "REUSE-DISK: this disk was NOT recreated"
else
  rm -f "$VAR_DIR/settled$SUFFIX"
  step "2. a disk with no other ancestry"
  kill_vm >/dev/null 2>&1
  rm -f "$DISK"
  note "deleted $(basename "$DISK") -- this run starts from the pinned image"
  if [[ -n "$VARS" ]]; then
    rm -f "$VAR_DIR/$VARS"
    note "deleted $VARS -- the boot copies cachyos-dl/$RHIZO_CACHYOS_BASE.OVMF_VARS.fd"
  fi
fi

if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  step "3. $CACHYOS_BL boot from the base's own disk (no -kernel, no -append)"
else
  step "3. GRUB boot (no -kernel, no -append)"
fi
boot_vm
wait_for_boot_slot || { fail "the pristine VM never got a qemu slot"; exit 1; }
if ! wait_back 420; then
  fail "the pristine VM never came up"
  "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV" "lsm-bootstrap-initial-boot"
  exit 1
fi
chain=$(qemu-img info -U --backing-chain "$DISK" 2>/dev/null | grep -E '^(image|backing file):' | sed 's/^/    /')
echo "$chain" >> "$SUMMARY"
log "  backing chain:"; echo "$chain"
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  base_img=$(guest_base cachyos grub)
  if ! backing=$(guest_disk_backing "$DISK"); then
    fail "cannot read the backing file of $(basename "$DISK")"
  elif [[ "$backing" != "$base_img" ]]; then
    fail "$(basename "$DISK") is backed by '$backing', not $base_img"
  elif ! base_backing=$(guest_disk_backing "$VAR_DIR/$base_img"); then
    fail "cannot read the backing file of $base_img"
  elif [[ -n "$base_backing" ]]; then
    fail "$base_img is itself backed by '$base_backing'"
  fi
  efi=$(ssh_vm -t 20 'efibootmgr' 2>&1)
  echo "$efi" > "$EV/efibootmgr-first-boot.txt"
  current=$(sed -n 's/^BootCurrent: //p' <<<"$efi")
  note "firmware booted: BootCurrent ${current:-<none>}: $(grep -m1 "^Boot${current:-none}" <<<"$efi" || echo '<no such entry>')"
fi
cmdline=$(ssh_vm -t 20 'cat /proc/cmdline')
note "cmdline as booted: $cmdline"

step "4. the stock starting state, observed from inside"
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  stock=$(ssh_vm -t 20 "$(cachyos_stock_probe "$CACHYOS_CONF")" 2>&1)
  echo "$stock" > "$EV/stock-state.txt"
  note "before: $(grep -E '^(lsm|enforce|markers)=' <<<"$stock" | tr '\n' ' ')(markers counted in $CACHYOS_CONF)"
  why=$(cachyos_stock_mismatches "$CACHYOS_CONF" <<<"$stock")
  fail_each $? "the stock-state check" "$why"
else
  case "$cmdline" in
    *rhizo*|*security=selinux*) fail "the pristine image booted ALREADY carrying Rhizo cmdline tokens" ;;
  esac
  lsm_before=$(ssh_vm -t 20 'cat /sys/kernel/security/lsm 2>/dev/null')
  selinux_before=$(ssh_vm -t 20 'ls -d /sys/fs/selinux 2>/dev/null || echo absent')
  aa_before=$(ssh_vm -t 20 'aa-status --enabled >/dev/null 2>&1 && echo enabled || echo not-enabled')
  note "before: lsm=$lsm_before selinuxfs=$selinux_before apparmor=$aa_before"
  case ",$lsm_before," in
    *,apparmor,*) : ;;
    *) fail "apparmor is NOT active on the stock image (lsm=$lsm_before)" ;;
  esac
  case ",$lsm_before," in
    *,selinux,*) fail "selinux is ALREADY active before the bootstrap ran" ;;
  esac
  [[ "$selinux_before" == absent ]] || fail "/sys/fs/selinux already exists before the bootstrap ran"
fi

step "5. src/install/bootstrap/bootstrap.sh (the product script, unmodified)"
timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$BOOTSTRAP" "${BOOTSTRAP%/*}/host-flavor.sh" "${BOOTSTRAP%/*}/bootloader.sh" \
  "$REPO/src/androidd/host/selinux-mode.py" "$SSH_TARGET:/root/" \
  || { fail "could not stage the bootstrap script"; exit 1; }
ssh_vm -t 20 'chmod 0755 /root/rhizo-selinux-mode.py' || { fail "could not make the staged mode helper executable"; exit 1; }
BS_ENV="RHIZO_SELINUX_MODE=host RHIZO_SELINUX_MODE_HELPER=/root/rhizo-selinux-mode.py"
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  kind=$(ssh_vm -t 20 'bash -c ". /root/host-flavor.sh && . /root/bootloader.sh && bootloader_kind"' 2>&1)
  note "bootloader kind the library detects: $kind (the $CACHYOS_BL base is $CACHYOS_KIND)"
  [[ "$kind" == "$CACHYOS_KIND" ]] || fail "bootloader.sh detects '$kind' on the $RHIZO_CACHYOS_BASE base, not $CACHYOS_KIND"
  tokens=$(ssh_vm -t 60 "$BS_ENV bash /root/bootstrap.sh --show 2>/root/rhizo-show.err")
  rc=$?
  echo "$tokens" > "$EV/bootstrap-show.txt"
  (( rc == 0 )) && [[ -n "$tokens" ]] \
    || { fail "bootstrap.sh --show exited $rc printing '$tokens': $(ssh_vm -t 20 'cat /root/rhizo-show.err' 2>&1)"; exit 1; }
fi
boot_id_before=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
out=$(ssh_vm -t 300 "$BS_ENV bash /root/bootstrap.sh" 2>&1)
echo "$out" > "$EV/bootstrap-run.log"
echo "$out" | sed 's/^/  /'
grep -q 'RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1' <<<"$out" \
  || { fail "the bootstrap did not report REBOOT_REQUIRED"; exit 1; }
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  block=$(ssh_vm -t 20 "echo \"last=\$(tail -n 1 $CACHYOS_CONF 2>&1)\"; echo \"begins=\$(grep -c '^# >>> rhizo\$' $CACHYOS_CONF 2>&1)\"" 2>&1)
  ssh_vm -t 20 "cat $CACHYOS_CONF" > "$EV/config-after-bootstrap.txt" 2>&1
  note "$CACHYOS_CONF after the run: $(tr '\n' ' ' <<<"$block")"
  grep -qx 'last=# <<< rhizo' <<<"$block" || fail "$CACHYOS_CONF does not end with rhizo's '# <<< rhizo' line: $(tr '\n' ' ' <<<"$block")"
  grep -qx 'begins=1' <<<"$block" || fail "$CACHYOS_CONF does not carry exactly one '# >>> rhizo' line: $(tr '\n' ' ' <<<"$block")"
  gen=$(ssh_vm -t 20 "$(cachyos_cmdlines_probe "$CACHYOS_KIND")" 2>&1)
  echo "$gen" > "$EV/next-boot-cmdlines.txt"
  note "next-boot cmdlines in $CACHYOS_GEN: $(grep -c '^line=' <<<"$gen")"
  why=$(cmdlines_missing_tokens "$tokens" <<<"$gen")
  fail_each $? "the token check of $CACHYOS_GEN" "$why"
fi

step "6. exactly one reboot"
ssh_vm -t 20 'sync; (sleep 1; systemctl reboot) >/dev/null 2>&1 & echo ISSUED' >/dev/null 2>&1
sleep 20
if ! wait_back 420; then
  fail "the host never came back from its reboot"
  "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV" "lsm-bootstrap-reboot-unreachable"
  exit 1
fi
boot_id_after=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
if [[ -z "$boot_id_before" || "$boot_id_after" == "$boot_id_before" ]]; then
  fail "boot_id did not change ($boot_id_before -> $boot_id_after)"
  "$REPO/test/vm/boot/collect-boot-evidence.sh" "$EV" "lsm-bootstrap-reboot-noop"
  exit 1
fi
note "boot_id $boot_id_before -> $boot_id_after (a real reboot, not a reconnect)"

step "7. SELinux active and enforceable"
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  fs=$(ssh_vm -t 20 'if [ -e /sys/fs/selinux/enforce ]; then echo mounted; elif [ -d /sys/fs/selinux ]; then echo empty; else echo absent; fi' 2>&1)
  note "/sys/fs/selinux before --verify: $fs"
  [[ "$fs" == empty ]] || fail "/sys/fs/selinux reads '$fs' before --verify, not an empty mount point"
fi
out=$(ssh_vm -t 60 "$BS_ENV bash /root/bootstrap.sh --verify" 2>&1)
echo "$out" > "$EV/bootstrap-verify.log"
echo "$out" | sed 's/^/  /'
grep -q 'RHIZO_BOOTSTRAP_VERIFIED=1' <<<"$out" || fail "--verify did not confirm the post-reboot state"
lsm_after=$(ssh_vm -t 20 'cat /sys/kernel/security/lsm 2>/dev/null')
aa_after=$(ssh_vm -t 20 'aa-status --enabled >/dev/null 2>&1 && echo enabled || echo not-enabled')
note "after:  lsm=$lsm_after selinuxfs=$(ssh_vm -t 15 'ls -d /sys/fs/selinux 2>/dev/null || echo absent') apparmor=$aa_after"
ssh_vm -t 20 'dmesg | grep -m1 "LSM: initializing"' >> "$SUMMARY" 2>/dev/null
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  grep -qE 'zswap +: not requested \(swap is on zram\)' <<<"$out" \
    || fail "--verify did not report zswap as not requested with swap on zram: $(grep -E 'zswap +:' <<<"$out" || echo '<no zswap line>')"
  [[ ",$lsm_after," == *,selinux,* && ",$lsm_after," != *,apparmor,* ]] \
    || fail "the LSM list after the reboot is '$lsm_after', lacking selinux or carrying apparmor"
  first=""
  for l in ${lsm_after//,/ }; do
    case "$l" in selinux|bpf) first=$l; break ;; esac
  done
  note "the first of selinux and bpf in the LSM list after the reboot: ${first:-neither}"
  [[ "$first" == selinux ]] || fail "the LSM list after the reboot is '$lsm_after', want selinux ahead of bpf"
  attr=$(ssh_vm -t 20 'cat /proc/self/attr/current' 2>&1)
  rc=$?
  echo "$attr" > "$EV/attr-current.txt"
  note "/proc/self/attr/current after the reboot: $attr (rc $rc)"
  (( rc == 0 )) && [[ -n "$attr" ]] \
    || fail "/proc/self/attr/current cannot be read after the reboot (rc $rc): $attr"
  enforce=$(ssh_vm -t 20 'cat /sys/fs/selinux/enforce' 2>&1)
  note "/sys/fs/selinux/enforce after --verify: $enforce"
  [[ "$enforce" == 0 || "$enforce" == 1 ]] || fail "/sys/fs/selinux/enforce reads '$enforce' after --verify mounted selinuxfs"
  sums_before=$(ssh_vm -t 20 "sha256sum $CACHYOS_CONF; find $CACHYOS_GEN -type f -exec sha256sum {} +" 2>&1)
fi

out=$(ssh_vm -t 120 "$BS_ENV bash /root/bootstrap.sh" 2>&1)
echo "$out" > "$EV/bootstrap-second-run.log"
grep -q 'RHIZO_BOOTSTRAP_ALREADY_APPLIED=1' <<<"$out" \
  && note "re-running the bootstrap is a clean no-op (ALREADY_APPLIED)" \
  || fail "re-running the bootstrap did not report ALREADY_APPLIED"
if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  sums_after=$(ssh_vm -t 20 "sha256sum $CACHYOS_CONF; find $CACHYOS_GEN -type f -exec sha256sum {} +" 2>&1)
  printf 'before the second run:\n%s\nafter it:\n%s\n' "$sums_before" "$sums_after" > "$EV/second-run-sha256.txt"
  note "sha256 of $CACHYOS_CONF and $CACHYOS_GEN around the second run: $(grep -c . <<<"$sums_after") file(s), $([[ "$sums_before" == "$sums_after" ]] && echo unchanged || echo CHANGED)"
  if [[ "$sums_before" != "$sums_after" ]]; then
    fail "the second run changed $CACHYOS_CONF or $CACHYOS_GEN: before '$sums_before' after '$sums_after'"
  elif [[ -z "$sums_after" ]] || grep -vqE '^[0-9a-f]{64}  /' <<<"$sums_after"; then
    fail "cannot sha256 $CACHYOS_CONF and $CACHYOS_GEN: read '$sums_after'"
  fi
fi

if (( BOOTSTRAP_ONLY )); then
  note "--bootstrap-only: stopped after --verify and the second run; no payload provisioned, no boot-smoke.sh"
else
  if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
    step "8. the rig deploy (redeploy.sh --no-launch)"
    ../../vm/redeploy.sh --no-launch > "$EV/provision.log" 2>&1
    rc=$?
    sed 's/^/  /' "$EV/provision.log" | tail -40
    (( rc == 0 )) || { fail "redeploy.sh --no-launch exited $rc -- see $EV/provision.log"; exit 1; }
    grep -q 'Staged OK' "$EV/provision.log" || fail "redeploy.sh --no-launch exited 0 without logging Staged OK"
  else
    step "8. provision the Rhizo payload"
    if ! ../../vm/image/provision-pristine.sh 2>&1 | tee "$EV/provision.log" | sed 's/^/  /'; then
      fail "provision-pristine.sh failed"; exit 1
    fi
    grep -q 'ready for boot-smoke.sh' "$EV/provision.log" || fail "provisioning did not report ready"
  fi

  step "9. boot-smoke.sh --variant user (unmodified)"
  if "$(system_test_file boot-smoke.sh)" --variant user 2>&1 | tee "$EV/test-boot-smoke.log" | tail -25; then
    note "boot-smoke.sh: PASSED"
  else
    fail "boot-smoke.sh did not pass"
  fi
  smoke_fails=$(grep -c '^\[.*\] FAIL:' "$EV/test-boot-smoke.log" 2>/dev/null); true
  smoke_fails=${smoke_fails:-0}
  note "boot-smoke.sh FAIL lines: $smoke_fails"
  [[ "$smoke_fails" == "0" ]] || fail "boot-smoke.sh printed $smoke_fails FAIL line(s)"
fi

PARAMS="boot=grub new_disk=$(( ! REUSE_DISK ))"
(( BOOTSTRAP_ONLY )) && PARAMS+=" bootstrap_only=1"
GUEST=""
[[ "$RHIZO_GUEST_OS" == cachyos ]] && GUEST="guest_os=cachyos base=$RHIZO_CACHYOS_BASE"
{
  echo
  echo "instance: $RHIZO_VM   boot mode: grub   new disk: $(( ! REUSE_DISK ))"
  if [[ -n "$GUEST" ]] || (( BOOTSTRAP_ONLY )); then
    echo "guest os: $RHIZO_GUEST_OS   base: ${GUEST:+$RHIZO_CACHYOS_BASE}   bootstrap only: $BOOTSTRAP_ONLY"
  fi
  echo "result: $( ((FAILED)) && echo FAIL || echo PASS )"
} >> "$SUMMARY"

if (( FAILED )); then
  test_record_verdict FAILED "$PARAMS" "$GUEST"
  [[ "$SUMMARY" == "$EV/summary.txt" ]] || log "$EV/summary.txt is banked and tracked -- left alone; this FAILED run's own summary is in $SUMMARY"
  log "LSM BOOTSTRAP SYSTEM TEST FAILED -- evidence in $EV"
  exit 1
fi
rig_result_keep "$EV/summary.txt"
test_record_verdict PASSED "$PARAMS" "$GUEST"
log "LSM BOOTSTRAP SYSTEM TEST PASSED -- evidence in $EV"
