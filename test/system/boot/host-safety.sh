#!/bin/bash
# prove an androidd stop and restart stay off the guest
# test-boot-mode: shared
# test-boots-unit: yes
# test-records-metrics: no
# test-requires: none
# RHIZO_RELEASE=a15 targets that release through test_boot; default a16
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../vm/common.sh
source ../lib/lib.sh

[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }
SKIP_BOOT=${RHIZO_SKIP_BOOT:-0}
[[ "${1:-}" == "--skip-boot" ]] && SKIP_BOOT=1

export RHIZO_USE_UNIT=1

test_init host-safety

# append a measurement row and log it
record() { printf '%s\t%s\n' "$1" "$2" >> "$EV/measurements.tsv"; log "    [recorded] $1 = $2"; }

# print the comm field of a /proc stat line
proc_comm() {
  local raw="$1"
  [[ -n "$raw" ]] || { printf '<gone>'; return; }
  local c="${raw#*\(}"
  c="${c%%\)*}"
  printf '%s' "$c"
}

if (( SKIP_BOOT == 0 )); then
  step "0. boot: VM, Android, under androidd.service"
  test_boot --skip-graphics-preflight --release "${RHIZO_RELEASE:-}" || exit 1
  ../../vm/sync.sh > "$EV/sync.log" 2>&1 || { fail "sync.sh failed (see $EV/sync.log)"; exit 1; }
  ../../vm/redeploy.sh --skip-kill --boot-wait 240 > "$EV/redeploy.log" 2>&1 || { fail "redeploy.sh failed (see $EV/redeploy.log)"; exit 1; }
  tail -3 "$EV/redeploy.log"
fi

INIT=$(guest_init_pid 10)
[[ -n "$INIT" ]] || { fail "no init second_stage after boot"; test_record_verdict FAILED; exit 1; }
log "init_pid=$INIT"
boot_completed=$(getprop_live "$INIT" sys.boot_completed) || boot_completed="<unreadable rc=$?>"
[[ "$boot_completed" == "1" ]] || { fail "sys.boot_completed='$boot_completed' at system test start"; test_record_verdict FAILED; exit 1; }
active=$(ssh_vm -t 10 'systemctl is-active androidd.service' | tr -d '\r\n')
[[ "$active" == "active" ]] || { fail "androidd.service is '$active' at system test start, not 'active'"; test_record_verdict FAILED; exit 1; }
pass "booted, sys.boot_completed=1, running under androidd.service"

step "1. record host baseline"
boot_id_before=$(ssh_vm -t 10 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r\n')
[[ -n "$boot_id_before" ]] || fail "could not read the guest's boot_id before the stop"
record boot_id_before "${boot_id_before:-<unreadable>}"

SSH_UNIT=ssh.service NET_UNIT=systemd-networkd.service
if [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; then
  SSH_UNIT=sshd.service
  NET_UNIT=$(ssh_vm -t 10 'for u in NetworkManager.service systemd-networkd.service; do systemctl -q is-active "$u" && { echo "$u"; break; }; done' | tr -d '\r\n')
  [[ -n "$NET_UNIT" ]] || { fail "neither NetworkManager nor systemd-networkd is active on this cachyos guest"; NET_UNIT=NetworkManager.service; }
fi
ssh_pid_before=$(ssh_vm -t 10 "systemctl show $SSH_UNIT -p MainPID --value" | tr -d '\r\n')
networkd_pid_before=$(ssh_vm -t 10 "systemctl show $NET_UNIT -p MainPID --value" | tr -d '\r\n')
udevd_pid_before=$(ssh_vm -t 10 'systemctl show systemd-udevd.service -p MainPID --value' | tr -d '\r\n')
for pair in "$SSH_UNIT:$ssh_pid_before" "$NET_UNIT:$networkd_pid_before" "systemd-udevd.service:$udevd_pid_before"; do
  unit="${pair%%:*}"; pid="${pair#*:}"
  [[ -n "$pid" && "$pid" != "0" ]] || fail "could not read a MainPID for $unit before the stop (got '$pid')"
done
record ssh_pid_before "${ssh_pid_before:-<unreadable>}"
record networkd_pid_before "${networkd_pid_before:-<unreadable>}"
record udevd_pid_before "${udevd_pid_before:-<unreadable>}"

ro_mounts_before=$(ssh_vm -t 10 "mount | awk -F'[()]' '{print \$2}' | grep -cE '(^|,)ro(,|\$)'" | tr -d '\r\n')
[[ -n "$ro_mounts_before" ]] || fail "could not count read-only mounts before the stop"
record ro_mounts_before "${ro_mounts_before:-<unreadable>}"
pass "host baseline recorded: boot_id, MainPID x3, ro-mount count"

step "2. prove the mask holds, both directions (sandbox still running)"
# prove a sysrq write is refused inside the sandbox
prove_mask() {
  local INIT="$1" label="$2"
mask_out=$(ssh_vm -t 30 "INIT_PID=$INIT bash -s" <<'REMOTE'
set -u
before=$(dmesg | grep -c 'sysrq:')
echo "dmesg_before=$before"
outside_msg=$(echo w > /proc/sysrq-trigger 2>&1)
echo "outside_rc=$?"
echo "outside_msg=$outside_msg"
sleep 2
after_outside=$(dmesg | grep -c 'sysrq:')
echo "dmesg_after_outside=$after_outside"
inside_msg=$(nsenter -a -t "$INIT_PID" -- /system/bin/sh -c 'echo w > /proc/sysrq-trigger' 2>&1)
inside_rc=$?
inside_msg=$(grep -v 'linker: Warning' <<<"$inside_msg" | tr '\n' ' ')
echo "inside_rc=$inside_rc"
echo "inside_msg=$inside_msg"
sleep 2
after_inside=$(dmesg | grep -c 'sysrq:')
echo "dmesg_after_inside=$after_inside"
echo "DMESG_TAIL_BEGIN"
dmesg | tail -20
echo "DMESG_TAIL_END"
REMOTE
)
printf '%s\n' "$mask_out" > "$(test_scratch_log "mask-proof-$label")"

# print a field of the mask probe output
get_field() { grep -m1 "^$1=" <<<"$mask_out" | cut -d= -f2-; }
dmesg_before=$(get_field dmesg_before)
outside_rc=$(get_field outside_rc)
dmesg_after_outside=$(get_field dmesg_after_outside)
inside_rc=$(get_field inside_rc)
inside_msg=$(get_field inside_msg)
dmesg_after_inside=$(get_field dmesg_after_inside)
record "mask_${label}_dmesg_before" "${dmesg_before:-<no answer>}"
record "mask_${label}_outside_rc" "${outside_rc:-<no answer>}"
record "mask_${label}_dmesg_after_outside" "${dmesg_after_outside:-<no answer>}"
record "mask_${label}_inside_rc" "${inside_rc:-<no answer>}"
record "mask_${label}_dmesg_after_inside" "${dmesg_after_inside:-<no answer>}"

if [[ -z "$mask_out" || -z "$dmesg_after_outside" || -z "$dmesg_after_inside" ]]; then
  fail "mask proof: the probe itself did not run to completion (empty or truncated answer) -- see $(test_scratch_log "mask-proof-$label")"
elif [[ "$dmesg_after_outside" -le "$dmesg_before" ]]; then
  fail "mask proof: writing 'w' OUTSIDE the sandbox produced NO new 'sysrq:' dmesg line ($dmesg_before -> $dmesg_after_outside, outside_rc=$outside_rc); see $(test_scratch_log "mask-proof-$label")"
else
  pass "outside the sandbox: 'w' reached the real kernel sysrq handler ($dmesg_before -> $dmesg_after_outside dmesg 'sysrq:' lines, rc=$outside_rc) -- positive control confirmed"
  if [[ "$dmesg_after_inside" -gt "$dmesg_after_outside" ]]; then
    fail "mask proof: writing 'w' INSIDE the sandbox's own namespace produced a NEW 'sysrq:' dmesg line ($dmesg_after_outside -> $dmesg_after_inside)"
  elif [[ "$inside_rc" == "0" ]]; then
    fail "mask proof: the inside write REPORTED SUCCESS (rc=0) yet produced no kernel action; see $(test_scratch_log "mask-proof-$label")"
  elif ! grep -qi 'read-only file system' <<<"$inside_msg"; then
    fail "mask proof: the inside write failed for a reason OTHER than the read-only mask (rc=$inside_rc, msg=$inside_msg); see $(test_scratch_log "mask-proof-$label")"
  else
    pass "inside the sandbox: the write was REFUSED by the read-only mask (rc=$inside_rc, EROFS) and produced no new 'sysrq:' dmesg line ($dmesg_after_outside -> $dmesg_after_inside), while the positive control above proves the probe mechanism itself works"
  fi
fi
}

prove_mask "$INIT" first-boot

# prove binfmt_misc is unreachable from the sandbox
prove_binfmt() {
  local INIT="$1" label="$2"

  local out
  out=$(ssh_vm -t 40 "INIT_PID=$INIT bash -s" <<'REMOTE'
set -u
BF=/proc/sys/fs/binfmt_misc
mounted=0
grep -qs ' binfmt_misc ' /proc/self/mounts && mounted=1
echo "mounted_at_entry=$mounted"
mounted_by_probe=0
if [ "$mounted" = 0 ]; then
  if mount -t binfmt_misc none "$BF" 2>/dev/null; then
    mounted_by_probe=1
  fi
fi
echo "mounted_by_probe=$mounted_by_probe"
echo "BASELINE_BEGIN"
ls "$BF" 2>/dev/null | grep -v '^status$' | grep -v '^register$' | sort
echo "BASELINE_END"

ctl_add=$(echo ':rhizo-selftest:M::RHZO::/bin/true:' > "$BF/register" 2>&1); ctl_add_rc=$?
echo "control_add_rc=$ctl_add_rc"
echo "control_add_msg=$ctl_add"
ctl_present=0; [ -e "$BF/rhizo-selftest" ] && ctl_present=1
echo "control_present=$ctl_present"
if [ "$ctl_present" = 1 ]; then
  echo -1 > "$BF/rhizo-selftest" 2>/dev/null
fi
ctl_gone=1; [ -e "$BF/rhizo-selftest" ] && ctl_gone=0
echo "control_removed=$ctl_gone"

ins_reg=$(nsenter -a -t "$INIT_PID" -- /system/bin/sh -c \
  "echo ':rhizo-inside:M::RHZOX::/system/bin/true:' > $BF/register" 2>&1); ins_reg_rc=$?
ins_reg=$(grep -v 'linker: Warning' <<<"$ins_reg" | tr '\n' ' ')
echo "inside_register_rc=$ins_reg_rc"
echo "inside_register_msg=$ins_reg"

ins_mnt=$(nsenter -a -t "$INIT_PID" -- /system/bin/toybox mount -t binfmt_misc none "$BF" 2>&1); ins_mnt_rc=$?
ins_mnt=$(grep -v 'linker: Warning' <<<"$ins_mnt" | tr '\n' ' ')
echo "inside_mount_rc=$ins_mnt_rc"
echo "inside_mount_msg=$ins_mnt"
echo "inside_mount_ls=$(nsenter -a -t "$INIT_PID" -- /system/bin/toybox ls "$BF" 2>/dev/null | tr '\n' ',')"
if [ "$ins_mnt_rc" = 0 ]; then
  nsenter -a -t "$INIT_PID" -- /system/bin/toybox umount "$BF" 2>/dev/null
  echo "inside_mount_undone=$?"
fi

nsenter -a -t "$INIT_PID" -- /system/bin/toybox mkdir -p /dev/rhizo-bf-probe 2>/dev/null
ins_alt=$(nsenter -a -t "$INIT_PID" -- /system/bin/toybox mount -t binfmt_misc none /dev/rhizo-bf-probe 2>&1); ins_alt_rc=$?
ins_alt=$(grep -v 'linker: Warning' <<<"$ins_alt" | tr '\n' ' ')
echo "inside_altmount_rc=$ins_alt_rc"
echo "inside_altmount_msg=$ins_alt"
echo "inside_altmount_ls=$(nsenter -a -t "$INIT_PID" -- /system/bin/toybox ls /dev/rhizo-bf-probe 2>/dev/null | tr '\n' ',')"
if [ "$ins_alt_rc" = 0 ]; then
  nsenter -a -t "$INIT_PID" -- /system/bin/toybox umount /dev/rhizo-bf-probe 2>/dev/null
fi
nsenter -a -t "$INIT_PID" -- /system/bin/toybox rmdir /dev/rhizo-bf-probe 2>/dev/null

echo "inside_capeff=$(grep CapEff /proc/$INIT_PID/status | awk '{print $2}')"

echo "inside_exec_prop=$(nsenter -a -t "$INIT_PID" -- /system/bin/getprop ro.enable.native.bridge.exec 2>/dev/null | tr -d '\r')"

echo "AFTER_BEGIN"
ls "$BF" 2>/dev/null | grep -v '^status$' | grep -v '^register$' | sort
echo "AFTER_END"
if [ "$mounted_by_probe" = 1 ]; then
  umount "$BF" 2>/dev/null
fi
REMOTE
)
  printf '%s\n' "$out" > "$(test_scratch_log "binfmt-proof-$label")"

  gf() { grep -m1 "^$1=" <<<"$out" | cut -d= -f2-; }
  local mounted_at_entry mounted_by_probe ctl_rc ctl_present ctl_removed
  local ireg_rc ireg_msg imnt_rc imnt_msg capeff exec_prop
  mounted_at_entry=$(gf mounted_at_entry)
  mounted_by_probe=$(gf mounted_by_probe)
  ctl_rc=$(gf control_add_rc); ctl_present=$(gf control_present); ctl_removed=$(gf control_removed)
  ireg_rc=$(gf inside_register_rc); ireg_msg=$(gf inside_register_msg)
  imnt_rc=$(gf inside_mount_rc);   imnt_msg=$(gf inside_mount_msg)
  local imnt_ls ialt_rc ialt_msg ialt_ls
  imnt_ls=$(gf inside_mount_ls)
  ialt_rc=$(gf inside_altmount_rc); ialt_msg=$(gf inside_altmount_msg); ialt_ls=$(gf inside_altmount_ls)
  capeff=$(gf inside_capeff);      exec_prop=$(gf inside_exec_prop)

  local baseline after
  baseline=$(sed -n '/^BASELINE_BEGIN$/,/^BASELINE_END$/p' <<<"$out" | sed '1d;$d')
  after=$(sed -n '/^AFTER_BEGIN$/,/^AFTER_END$/p' <<<"$out" | sed '1d;$d')

  record "binfmt_${label}_mounted_at_entry" "${mounted_at_entry:-<no answer>}"
  record "binfmt_${label}_mounted_by_probe" "${mounted_by_probe:-<no answer>}"
  record "binfmt_${label}_control_add_rc" "${ctl_rc:-<no answer>}"
  record "binfmt_${label}_inside_register_rc" "${ireg_rc:-<no answer>}"
  record "binfmt_${label}_inside_mount_rc" "${imnt_rc:-<no answer>}"
  record "binfmt_${label}_capeff" "${capeff:-<no answer>}"
  record "binfmt_${label}_entries_before" "$(wc -l <<<"$baseline" | tr -d ' ')"
  record "binfmt_${label}_entries_after" "$(wc -l <<<"$after" | tr -d ' ')"

  if [[ -z "$out" || -z "$ctl_present" || -z "$ireg_rc" ]]; then
    fail "binfmt proof: the probe did not run to completion -- see $(test_scratch_log "binfmt-proof-$label")"
    return
  fi
  if [[ "$mounted_at_entry" == "0" && "$mounted_by_probe" == "0" ]]; then
    fail "binfmt proof: binfmt_misc is not mounted on the guest AND the probe could not mount it"
    return
  elif [[ "$mounted_at_entry" == "0" ]]; then
    log "    binfmt_misc was NOT mounted on the guest at entry; the probe mounted and unmounted it"
  else
    log "    binfmt_misc was already mounted on the guest (systemd-binfmt or equivalent)"
  fi

  if [[ "$ctl_present" != "1" ]]; then
    fail "binfmt proof: registering ':rhizo-selftest:' in the guest ROOT namespace did not appear in the table (rc=$ctl_rc); see $(test_scratch_log "binfmt-proof-$label")"
    return
  fi
  [[ "$ctl_removed" == "1" ]] || fail "binfmt proof: the control entry could not be removed again -- the probe left state behind"
  pass "outside the sandbox: a binfmt_misc handler registered and was removed again (rc=$ctl_rc) -- positive control confirmed"

  if [[ "$ireg_rc" == "0" ]]; then
    fail "binfmt proof: the sandbox's write to /proc/sys/fs/binfmt_misc/register REPORTED SUCCESS"
  elif grep -qi 'no such file' <<<"$ireg_msg" && [[ "$imnt_rc" == "0" || "$ialt_rc" == "0" ]]; then
    fail "binfmt proof: the register write failed only because nothing is mounted at /proc/sys/fs/binfmt_misc right now (ENOENT), and the sandbox CAN mount binfmt_misc itself (mount rc=$imnt_rc, arbitrary-path rc=$ialt_rc)"
  elif ! grep -qiE 'read-only file system|permission denied|no such file' <<<"$ireg_msg"; then
    fail "binfmt proof: the sandbox's register write failed for an unrecognized reason (rc=$ireg_rc, msg=$ireg_msg)"
  else
    pass "inside the sandbox: the register write was refused (rc=$ireg_rc, $ireg_msg)"
  fi

  assert_no_mount() {
    local where="$1" rc="$2" msg="$3" listing="$4"
    if [[ "$rc" == "127" ]]; then
      fail "binfmt proof: the mount probe $where exited 127"
    elif [[ "$rc" == "0" ]]; then
      fail "binfmt proof: the sandbox MOUNTED binfmt_misc $where (rc=0) and sees [$listing]. CapEff=$capeff"
    else
      pass "inside the sandbox: mounting binfmt_misc $where was refused (rc=$rc, $msg)"
    fi
  }
  assert_no_mount "at /proc/sys/fs/binfmt_misc" "$imnt_rc" "$imnt_msg" "$imnt_ls"
  assert_no_mount "at an arbitrary path (/dev/rhizo-bf-probe)" "$ialt_rc" "$ialt_msg" "$ialt_ls"

  if [[ -n "$exec_prop" ]]; then
    fail "binfmt proof: ro.enable.native.bridge.exec is set to '$exec_prop' inside the sandbox"
  else
    pass "ro.enable.native.bridge.exec is unset inside the sandbox"
  fi

  if [[ "$baseline" == "$after" ]]; then
    pass "the guest's binfmt_misc registration table is unchanged across both sandbox attempts ($(wc -l <<<"$baseline" | tr -d ' ') entries)"
  else
    fail "binfmt proof: the registration table CHANGED across the sandbox's attempts -- added: $(comm -13 <(sort <<<"$baseline") <(sort <<<"$after") | tr '\n' ' ') removed: $(comm -23 <(sort <<<"$baseline") <(sort <<<"$after") | tr '\n' ' ')"
  fi

  local bad_interp
  bad_interp=$(ssh_vm -t 20 'BF=/proc/sys/fs/binfmt_misc
    grep -qs " binfmt_misc " /proc/self/mounts || exit 0
    for e in "$BF"/*; do
      case "${e##*/}" in status|register) continue;; esac
      i=$(grep -m1 "^interpreter " "$e" 2>/dev/null | cut -d" " -f2-)
      case "$i" in
        /system/*|/system_ext/*|/run/rhizo/*|/root/share/*|/srv/rhizo/*)
          echo "${e##*/} -> $i" ;;
      esac
    done' 2>/dev/null)
  if [[ -n "$bad_interp" ]]; then
    fail "binfmt proof: a registered handler's interpreter resolves inside a Rhizo-owned tree: $bad_interp"
  else
    pass "no registered handler's interpreter resolves under /system, /system_ext, /run/rhizo, /root/share or /srv/rhizo"
  fi
}

prove_binfmt "$INIT" first-boot

FTRACE_SPIN=rhzftraceprobe
FTRACE_MARK=RHIZO_HOST_FTRACE_MARK
FTRACE_CFG=/data/misc/perfetto-configs/rhizo-ftrace-probe.pbtxt
FTRACE_TRACE=/data/misc/perfetto-traces/rhizo-ftrace-probe.pftrace

# print the host's global ftrace state
ftrace_state() {
  ssh_vm -t 15 'bash -s' <<'REMOTE'
T=/sys/kernel/tracing
echo "tracing_on=$(cat $T/tracing_on) buffer_kb=$(cut -d' ' -f1 $T/buffer_size_kb) set_event=$(sort $T/set_event | md5sum | cut -c1-12)/$(wc -l < $T/set_event) tracer=$(cat $T/current_tracer)"
REMOTE
}

# prove the sandbox cannot reach the host's ftrace
prove_ftrace() {
  local INIT="$1" label="$2"
  local samples_log pf_log mi_log na_log trace_file
  samples_log=$(test_scratch_log "ftrace-samples-$label")
  pf_log=$(test_scratch_log "ftrace-perfetto-$label")
  mi_log=$(test_scratch_log "ftrace-mountinfo-$label")
  na_log=$(test_scratch_log "ftrace-neverallow-$label")
  trace_file="$EV/ftrace-probe-$label.pftrace"
  local f
  for f in "$samples_log" "$pf_log" "$mi_log" "$na_log"; do printf '<none: not reached>\n' > "$f"; done
  rm -f "$trace_file"

  local marker
  marker=$(ssh_vm -t 15 "dmesg | grep -ao 'RHIZO_MARKER ftrace=[a-z]*' | tail -1")
  record "ftrace_${label}_marker" "${marker:-<absent>}"
  [[ "$marker" == *ftrace=on ]] && log "    this boot ran trace.ftrace=on (policy.conf) -- the assertions below fail here"

  local mi fsmounts
  mi=$(ssh_vm -t 20 "cat /proc/$INIT/mountinfo && echo RHIZO_MI_OK")
  printf '%s\n' "$mi" > "$mi_log"
  if [[ "$mi" != *RHIZO_MI_OK* ]]; then
    fail "ftrace proof: could not read /proc/$INIT/mountinfo -- see $mi_log"
  else
    fsmounts=$(grep -E ' - (tracefs|debugfs) ' <<<"$mi" | cut -d' ' -f5 | tr '\n' ' ')
    record "ftrace_${label}_sandbox_mounts" "${fsmounts:-<none>}"
    if [[ -n "$fsmounts" ]]; then
      fail "ftrace proof: the sandbox mounts tracefs or debugfs at [$fsmounts]"
    else
      pass "the sandbox's mount table holds no tracefs and no debugfs"
    fi
  fi

  local pol="$EV/ftrace-live-sepolicy-$label.bin" na na_rc
  if ! ssh_vm -t 30 'cat /sys/fs/selinux/policy' > "$pol" || [[ ! -s "$pol" ]]; then
    fail "ftrace proof: could not pull /sys/fs/selinux/policy"
  else
    na=$("$REPO/test/checks/lib/policy-lab.sh" query neverallow -n 'neverallow domain { debugfs_tracing_debug debugfs }:filesystem { mount remount };' --policy "$pol" 2>&1)
    na_rc=$?
    printf '%s\n' "$na" > "$na_log"
    record "ftrace_${label}_neverallow_rc" "$na_rc"
    if (( na_rc == 0 )); then
      pass "the loaded policy lets no Android domain mount tracefs or debugfs (sepolicy-analyze neverallow)"
    elif grep -q 'neverallow violated by' <<<"$na"; then
      fail "ftrace proof: the loaded policy lets an Android domain mount the host's tracer: $(grep -o 'violated by allow [^;]*' <<<"$na" | cut -d' ' -f3- | tr '\n' ';')"
    else
      fail "ftrace proof: the neverallow query did not run (rc=$na_rc) -- see $na_log"
    fi
  fi

  local cfg put before
  cfg=$(base64 -w0 <<'EOF'
buffers { size_kb: 4096 fill_policy: RING_BUFFER }
data_sources { config { name: "linux.ftrace" ftrace_config { ftrace_events: "sched/sched_switch" ftrace_events: "ftrace/print" } } }
data_sources { config { name: "linux.process_stats" process_stats_config { scan_all_processes_on_start: true } } }
duration_ms: 6000
EOF
)
  put=$(android_sh "$INIT" "echo $cfg | base64 -d > $FTRACE_CFG && rm -f $FTRACE_TRACE && echo RHIZO_CFG_OK")
  if [[ "$put" != *RHIZO_CFG_OK* ]]; then
    fail "ftrace proof: could not stage a perfetto config through Android's shell: $put"
    return
  fi
  before=$(ftrace_state)
  record "ftrace_${label}_host_before" "${before:-<unreadable>}"
  if [[ "$before" != tracing_on=* ]]; then
    fail "ftrace proof: the host's /sys/kernel/tracing is unreadable ($before)"
    return
  fi

  ssh_vm -t 40 "SPIN=$FTRACE_SPIN MARK=$FTRACE_MARK bash -s" > "$samples_log" 2>&1 <<'REMOTE' &
T=/sys/kernel/tracing
ln -sf /usr/bin/sha256sum "/run/$SPIN"
setsid -f timeout 14 "/run/$SPIN" /dev/zero >/dev/null 2>&1 </dev/null
for i in $(seq 1 28); do
  echo "sample=$i tracing_on=$(cat $T/tracing_on) buffer_kb=$(cut -d' ' -f1 $T/buffer_size_kb) set_event=$(sort $T/set_event | md5sum | cut -c1-12)/$(wc -l < $T/set_event) tracer=$(cat $T/current_tracer) spin=$(pgrep -cx "$SPIN")"
  if [ "$i" = 8 ]; then echo "$MARK" > $T/trace_marker; echo "mark_rc=$?"; fi
  sleep 0.5
done
rm -f "/run/$SPIN"
echo RHIZO_SAMPLER_DONE
REMOTE
  local sampler=$!
  ( ANDROID_SH_TIMEOUT=40 android_sh "$INIT" "{ perfetto --txt -c $FTRACE_CFG -o $FTRACE_TRACE </dev/null 2>&1; echo perfetto_rc=\$?; } | tail -6" > "$pf_log" 2>&1 ) &
  local pf=$!
  wait "$pf"
  wait "$sampler"
  local after
  after=$(ftrace_state)
  record "ftrace_${label}_host_after" "${after:-<unreadable>}"

  local b64 pf_rc
  b64=$(ANDROID_SH_TIMEOUT=60 android_sh "$INIT" "gzip -c $FTRACE_TRACE | base64 -w0")
  android_sh "$INIT" "rm -f $FTRACE_CFG $FTRACE_TRACE" > /dev/null
  pf_rc=$(grep -m1 -o 'perfetto_rc=[0-9]*' "$pf_log" | cut -d= -f2)
  record "ftrace_${label}_perfetto_rc" "${pf_rc:-<none>}"
  if ! base64 -d <<<"$b64" | gunzip > "$trace_file"; then
    fail "ftrace proof: no trace came back from Android's perfetto (perfetto_rc=${pf_rc:-none}, ${#b64} base64 bytes) -- see $pf_log"
    return
  fi

  local spin_seen ctl_hits spin_hits mark_hits sshd_hits changed
  spin_seen=$(grep -c 'spin=[1-9]' "$samples_log")
  ctl_hits=$(grep -a -o system_server "$trace_file" | wc -l)
  spin_hits=$(grep -a -o "$FTRACE_SPIN" "$trace_file" | wc -l)
  mark_hits=$(grep -a -o "$FTRACE_MARK" "$trace_file" | wc -l)
  sshd_hits=$(grep -a -o sshd "$trace_file" | wc -l)
  changed=$(grep '^sample=' "$samples_log" | cut -d' ' -f2-5 | sort -u | grep -vxF "$before")
  record "ftrace_${label}_trace_bytes" "$(stat -c %s "$trace_file")"
  record "ftrace_${label}_trace_hits" "system_server=$ctl_hits $FTRACE_SPIN=$spin_hits marker=$mark_hits sshd=$sshd_hits"
  record "ftrace_${label}_host_states_seen" "$(grep -c '^sample=' "$samples_log") samples, $(grep -c . <<<"$changed") differing from before"

  if ! grep -q RHIZO_SAMPLER_DONE "$samples_log"; then
    fail "ftrace proof: the host sampler did not finish -- see $samples_log"
    return
  fi
  if (( spin_seen == 0 )); then
    fail "ftrace proof: the host task $FTRACE_SPIN never ran -- see $samples_log"
    return
  fi
  if (( ctl_hits == 0 )); then
    fail "ftrace proof: Android's perfetto left no trace naming its own system_server (perfetto_rc=${pf_rc:-none}) -- see $pf_log"
    return
  fi
  pass "controls: the host task $FTRACE_SPIN ran in $spin_seen samples, and Android's trace names its own system_server $ctl_hits times"
  if [[ -n "$changed" || "$after" != "$before" ]]; then
    fail "ftrace proof: Android's perfetto changed the HOST's global ftrace -- before [$before], during [$(tr '\n' ';' <<<"$changed")], after [$after]"
  else
    pass "the host's tracing_on, buffer_size_kb, set_event and current_tracer held at [$before] before, during and after Android's trace"
  fi
  if (( spin_hits + mark_hits + sshd_hits > 0 )); then
    fail "ftrace proof: Android's trace carries the host: $FTRACE_SPIN=$spin_hits, the host's trace_marker string=$mark_hits, sshd=$sshd_hits"
  else
    pass "Android's trace carries no host task ($FTRACE_SPIN, sshd) and not the host's trace_marker string"
  fi

  local inst
  inst=$(ssh_vm -t 10 'ls /sys/kernel/tracing/instances && echo RHIZO_LS_OK')
  if [[ "$inst" != *RHIZO_LS_OK* ]]; then
    fail "ftrace proof: could not list the host's /sys/kernel/tracing/instances: $inst"
  elif grep -qxE 'bootreceiver|wifi|mm_events' <<<"$inst"; then
    fail "ftrace proof: the host's tracefs holds Android's own instances [$(grep -xE 'bootreceiver|wifi|mm_events' <<<"$inst" | tr '\n' ' ')]"
  else
    pass "the host's tracefs holds no instance Android's init creates"
  fi
}

prove_ftrace "$INIT" first-boot


step "3. stop the sandbox through its real path"
t0=$(date +%s)
ssh_vm -t 180 'systemctl stop androidd.service'
stop_rc=$?
t1=$(date +%s)
record stop_rc "$stop_rc"
record stop_seconds "$((t1 - t0))"
[[ "$stop_rc" == "0" ]] || fail "systemctl stop androidd.service returned rc=$stop_rc"

step "4. assert containment"
if ! wait_for_ssh 30; then
  fail "ssh did not answer within 30s of 'systemctl stop androidd.service' returning"
  test_record_verdict FAILED
  exit 1
fi
pass "ssh answers within 30s of the stop returning"

boot_id_after=$(ssh_vm -t 10 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r\n')
ssh_pid_after=$(ssh_vm -t 10 "systemctl show $SSH_UNIT -p MainPID --value" | tr -d '\r\n')
networkd_pid_after=$(ssh_vm -t 10 "systemctl show $NET_UNIT -p MainPID --value" | tr -d '\r\n')
udevd_pid_after=$(ssh_vm -t 10 'systemctl show systemd-udevd.service -p MainPID --value' | tr -d '\r\n')
ro_mounts_after=$(ssh_vm -t 10 "mount | awk -F'[()]' '{print \$2}' | grep -cE '(^|,)ro(,|\$)'" | tr -d '\r\n')
record boot_id_after "${boot_id_after:-<unreadable>}"
record ssh_pid_after "${ssh_pid_after:-<unreadable>}"
record networkd_pid_after "${networkd_pid_after:-<unreadable>}"
record udevd_pid_after "${udevd_pid_after:-<unreadable>}"
record ro_mounts_after "${ro_mounts_after:-<unreadable>}"

[[ -n "$boot_id_after" ]] || fail "could not re-read boot_id after the stop"
[[ -n "$boot_id_before" && "$boot_id_after" == "$boot_id_before" ]] \
  || fail "boot_id changed across the stop ($boot_id_before -> $boot_id_after)"
for pair in "$SSH_UNIT:$ssh_pid_before:$ssh_pid_after" \
            "$NET_UNIT:$networkd_pid_before:$networkd_pid_after" \
            "systemd-udevd.service:$udevd_pid_before:$udevd_pid_after"; do
  unit="${pair%%:*}"; rest="${pair#*:}"; before="${rest%%:*}"; after="${rest#*:}"
  if [[ -z "$after" || "$after" == "0" ]]; then
    fail "$unit: could not read a MainPID after the stop (got '$after')"
  elif [[ -n "$before" && "$before" != "0" && "$after" != "$before" ]]; then
    fail "$unit restarted across the stop (MainPID $before -> $after)"
  fi
done
[[ -n "$ro_mounts_after" ]] || fail "could not count read-only mounts after the stop"
if [[ -n "$ro_mounts_before" && -n "$ro_mounts_after" && "$ro_mounts_after" -gt "$ro_mounts_before" ]]; then
  fail "read-only mount count increased across the stop ($ro_mounts_before -> $ro_mounts_after)"
fi
pass "boot_id unchanged, ssh/networkd/udevd MainPID unchanged, no new read-only mount"

step "5. assert the sandbox is genuinely gone"
init_recorded=$(ssh_vm -t 10 'cat /root/.rhizo_init_pid 2>/dev/null' | tr -d '\r\n')
if [[ -z "$init_recorded" ]]; then
  fail "could not read /root/.rhizo_init_pid to know which pid the stop was supposed to remove"
else
  gone=0
  deadline=$(( $(date +%s) + 15 ))
  comm="<not checked>"
  while (( $(date +%s) < deadline )); do
    probe=$(ssh_vm -t 10 "cat /proc/$init_recorded/stat 2>/dev/null; echo RHIZO_STAT_OK")
    if [[ "$probe" != *RHIZO_STAT_OK* ]]; then
      sleep 1
      continue
    fi
    stat_line=${probe%RHIZO_STAT_OK*}
    comm=$(proc_comm "$stat_line")
    [[ "$comm" != "init" ]] && { gone=1; break; }
    sleep 1
  done
  record init_recorded_pid "$init_recorded"
  record init_pid_comm_after_stop "$comm"
  (( gone )) || fail "pid $init_recorded (from /root/.rhizo_init_pid) is still comm='init' 15s after the stop returned"
fi

cg_root=$(ssh_vm -t 10 'cat /root/.rhizo_cgroup_root 2>/dev/null' | tr -d '\r\n')
if [[ -z "$cg_root" ]]; then
  fail "could not read /root/.rhizo_cgroup_root"
else
  record cgroup_root "$cg_root"
  emptied=0
  deadline=$(( $(date +%s) + 15 ))
  populated="<not checked>"
  while (( $(date +%s) < deadline )); do
    populated=$(ssh_vm -t 10 "sup=\$(cut -d' ' -f1 /root/.rhizo_g_pid 2>/dev/null); cat \$(find $cg_root -name cgroup.procs) 2>/dev/null | grep -vx \"\$sup\" | wc -l" | tr -d '\r\n')
    [[ "$populated" == "0" ]] && { emptied=1; break; }
    sleep 1
  done
  record cgroup_populated_after_stop "$populated"
  (( emptied )) || fail "$cg_root still holds $populated pid(s) besides the resident supervisor 15s after the stop returned"
fi
(( gone && emptied )) && pass "init pid $init_recorded no longer comm='init' and $cg_root/cgroup.events reports populated=0"

step "6. leave the stack running (systemctl start)"
t0=$(date +%s)
ssh_vm -t 300 'systemctl start androidd.service'
start_rc=$?
record start_rc "$start_rc"
[[ "$start_rc" == "0" ]] || fail "systemctl start androidd.service returned rc=$start_rc"

bc="" init_after=""
deadline=$(( $(date +%s) + 240 ))
while (( $(date +%s) < deadline )); do
  init_after=$(guest_init_pid 10)
  if [[ -n "$init_after" ]]; then
    bc=$(getprop_vm "$init_after" sys.boot_completed)
    [[ "$bc" == "1" ]] && break
  fi
  sleep 2
done
t1=$(date +%s)
record restart_seconds "$((t1 - t0))"
record boot_completed_after_restart "${bc:-<none>}"
test_collect_boot_evidence after-restart
if [[ "$bc" == "1" ]]; then
  pass "androidd.service started again, sys.boot_completed=1 in $((t1 - t0))s"
else
  fail "androidd.service did not reach sys.boot_completed=1 within 240s of 'systemctl start' returning"
fi

step "7. prove the mask still holds on the restarted sandbox"
if [[ "$bc" == "1" && -n "$init_after" ]]; then
  prove_mask "$init_after" after-restart
  prove_binfmt "$init_after" after-restart
  prove_ftrace "$init_after" after-restart
else
  fail "cannot re-prove the mask: the restarted sandbox never reached boot_completed"
fi

if (( FAILED )); then log "HOST-SAFETY SYSTEM TEST FAILED"
test_record_verdict FAILED; exit 1; fi
log "HOST-SAFETY SYSTEM TEST PASSED -- evidence in $EV"
test_record_verdict PASSED
