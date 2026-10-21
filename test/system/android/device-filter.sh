#!/bin/bash
# test the cgroup device filter
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: none
# test-records-metrics: no
# test-verdict-params: -
# test-requires: none
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

POLICY_CONF=/etc/rhizo/policy.conf

if (( SELFTEST )); then
  SELFTEST_EV="${TMPDIR:-/tmp}/test-device-filter-selftest${SUFFIX}"
  rm -rf "$SELFTEST_EV"
  test_init device-filter --no-vm --evidence-root "$SELFTEST_EV" || exit 1
  # shellcheck disable=SC2034
  TEST_VERDICT_RECORDED=1
else
  test_init device-filter || exit 1
fi

# write text to an evidence file
save_evidence() {
  printf '%s\n' "$2" > "$EV/$1"
}

# print the last RHIZO_DEVFILTER value for a key
devfilter_field() {
  sed -n "s/^RHIZO_DEVFILTER $1=//p" <<<"$2" | tail -1
}

# print the last RHIZO_DEVFILTER0B value for a key
devfilter_field0b() {
  sed -n "s/^RHIZO_DEVFILTER0B $1=//p" <<<"$2" | tail -1
}

# compare the probe and expected host nodes
assert_devfilter_host_match() {
  local label="$1" cap="$2" text="$3" expect="$4" v
  v=$(devfilter_field "host_$cap" "$text")
  if [[ -z "$expect" ]]; then
    fail "$label: devices.$cap's host node was never resolved before this run"
  elif [[ -z "$v" || "$v" == "ABSENT" ]]; then
    fail "$label: devices.$cap's host node was present at step 0b ($expect) and reads ABSENT in the probe"
  elif [[ "$v" != "$expect" ]]; then
    fail "$label: devices.$cap resolved to '$v' in the probe but '$expect' at step 0b"
  else
    pass "$label: devices.$cap's major:minor ($v) matches step 0b's resolution"
  fi
}

# check a mknod result in the probe text
assert_devfilter_mknod() {
  local label="$1" what="$2" suf="$3" text="$4" want="$5" rc errline
  rc=$(devfilter_field "mknod_$suf" "$text")
  errline=$(devfilter_field "mknod_${suf}_err" "$text")
  case "$rc" in
    "")
      fail "$label: the probe never reached mknod_$suf"
      ;;
    SKIPPED_HOST_NODE_ABSENT)
      if [[ "$suf" == ctlsame ]]; then
        fail "$label: no other char device on uinput/tun's own major was found at the top of /dev on this guest to use as a same-major control"
      else
        fail "$label: mknod_$suf was skipped -- its host node was absent"
      fi
      ;;
    rc=0)
      if [[ "$want" == allow ]]; then
        pass "$label: $what: mknod succeeded, as expected for an unwithheld major:minor"
      else
        fail "$label: $what: mknod SUCCEEDED on a withheld device"
      fi
      ;;
    rc=*)
      if [[ "$want" == deny ]]; then
        if [[ "$errline" == *"not permitted"* ]]; then
          pass "$label: $what: mknod was refused ($errline), as expected for a withheld device"
        else
          fail "$label: $what: mknod failed (rc=$rc, err=${errline:-<none>}) but the error text does not say permission was denied"
        fi
      else
        fail "$label: $what: mknod was refused (${errline:-no error text captured}) on a device that must stay reachable"
      fi
      ;;
    *)
      fail "$label: mknod_$suf reports an unparseable result: '$rc'"
      ;;
  esac
}

# compare the pre-join cgroup with the joined cgroup
assert_devfilter_precontrol_cgroup() {
  local label="$1" text="$2" expect="$3" pre
  pre=$(devfilter_field pre_cgroup "$text")
  if [[ -z "$pre" || "$pre" == UNRESOLVED ]]; then
    fail "$label: the probe's own pre-join cgroup (pre_cgroup) never resolved"
    return 1
  fi
  if [[ -z "$expect" ]]; then
    skip "$label: pre-join containment check skipped"
    return 0
  fi
  if [[ "$pre" == "$expect" || "$pre" == "$expect"/* || "$expect" == "$pre"/* ]]; then
    fail "$label: the control half ran inside the filter's own cgroup (pre_cgroup=$pre, joined=$expect)"
    return 1
  fi
  pass "$label: the control half ran in $pre, outside the filter's attach point ($expect)"
}

# check a pre-join mknod result
assert_devfilter_premknod() {
  local label="$1" what="$2" suf="$3" text="$4" rc errline
  rc=$(devfilter_field "premknod_$suf" "$text")
  errline=$(devfilter_field "premknod_${suf}_err" "$text")
  case "$rc" in
    "")
      fail "$label: the probe never reached premknod_$suf"
      ;;
    SKIPPED_HOST_NODE_ABSENT)
      fail "$label: premknod_$suf was skipped -- its host node was absent"
      ;;
    rc=0)
      pass "$label: $what: the pre-join control mknod succeeded, outside the filter's attach point"
      ;;
    rc=*)
      fail "$label: $what: the pre-join control mknod was refused (rc=$rc, err=${errline:-<none>}) OUTSIDE the filter's attach point"
      ;;
    *)
      fail "$label: premknod_$suf reports an unparseable result: '$rc'"
      ;;
  esac
}

# check the probe output
assert_devfilter_probe() {
  local label="$1" text="$2" expect_cg="$3" expect_dri="$4" expect_uinput="$5" expect_tun="$6"
  local v joined

  v=$(devfilter_field init "$text")
  case "$v" in
    ""|NONE|GONE*)
      fail "$label: the probe's own init never resolved (init=${v:-<none>}) -- pgrep found nothing to join"
      return 1
      ;;
  esac

  joined=$(devfilter_field joined "$text")
  assert_devfilter_precontrol_cgroup "$label" "$text" "$expect_cg"
  assert_devfilter_premknod "$label" "devices.dri" dri "$text"
  assert_devfilter_premknod "$label" "devices.uinput" uinput "$text"
  assert_devfilter_premknod "$label" "devices.tun" tun "$text"
  assert_devfilter_premknod "$label" "the unwithheld /dev/null control" null "$text"
  assert_devfilter_premknod "$label" "the same-major control device" ctlsame "$text"

  if [[ -z "$joined" ]]; then
    fail "$label: the probe never reported joined="
  elif [[ -z "$expect_cg" ]]; then
    skip "$label: join comparison skipped"
  elif [[ "$joined" == "$expect_cg" ]]; then
    pass "$label: the probe joined $joined, exactly init's own leaf cgroup"
  else
    fail "$label: the probe joined '$joined', init's own leaf cgroup reads '$expect_cg'"
  fi

  assert_devfilter_host_match "$label" dri "$text" "$expect_dri"
  assert_devfilter_host_match "$label" uinput "$text" "$expect_uinput"
  assert_devfilter_host_match "$label" tun "$text" "$expect_tun"

  assert_devfilter_mknod "$label" "devices.dri" dri "$text" deny
  assert_devfilter_mknod "$label" "devices.uinput" uinput "$text" deny
  assert_devfilter_mknod "$label" "devices.tun" tun "$text" deny
  assert_devfilter_mknod "$label" "the unwithheld /dev/null control" null "$text" allow
  assert_devfilter_mknod "$label" "the same-major control device (proves the deny is minor-specific, not whole-major)" ctlsame "$text" allow
}

# check the host node exists
assert_host_node() {
  local label="$1" cap="$2" val="$3"
  if [[ -z "$val" || "$val" == "ABSENT" ]]; then
    fail "$label: $cap's host node is absent on this guest even after modprobe"
    return 1
  fi
  pass "$label: $cap resolves to major:minor $val on this guest"
}

# check init's cgroup path starts with a slash
assert_expect_cgroup_shape() {
  local label="$1" v="$2"
  if [[ "$v" == /* ]]; then
    pass "$label: this system test's own read of init's cgroup resolved to '$v'"
    return 0
  fi
  fail "$label: this system test's own read of init's cgroup did not resolve to a real path (got '${v:-<empty>}')"
  return 1
}

# check the policy file holds the written values
assert_devices_policy_written() {
  local label="$1" out="$2" dri="$3" uinput="$4" tun="$5" want miss=""
  for want in "[devices]" "dri = $dri" "uinput = $uinput" "tun = $tun"; do
    grep -qxF "$want" <<<"$out" || miss+="'$want' "
  done
  [[ -z "$miss" ]] || { fail "$label: $POLICY_CONF does not carry $miss(it reads: $(tr '\n' ' ' <<<"$out"))"; return 1; }
  pass "$label: $POLICY_CONF carries dri=$dri uinput=$uinput tun=$tun"
}

# write the devices policy file on the vm
write_devices_policy() {
  local dri="$1" uinput="$2" tun="$3" cmd
  cmd="install -d -m 0755 /etc/rhizo"
  cmd+=$'\n'": > $POLICY_CONF"
  cmd+=$'\n'"echo '[devices]' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'dri = $dri' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'uinput = $uinput' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'tun = $tun' >> $POLICY_CONF"
  cmd+=$'\n'"cat $POLICY_CONF"
  ssh_vm -t 20 "$cmd"
}

# print the sandbox init pid
resolve_init() {
  local deadline=$((SECONDS + $1)) pid=""
  while (( SECONDS < deadline )); do
    pid=$(guest_init_pid 15)
    [[ -n "$pid" ]] && break
    sleep 3
  done
  printf '%s' "$pid"
}

# check the init pid exists in /proc
assert_init_live() {
  local label="$1" pid="$2"
  [[ -n "$pid" ]] || { fail "$label: init [second_stage] never appeared on this guest (pgrep found nothing)"; return 1; }
  ssh_vm -t 10 "test -d /proc/$pid" || { fail "$label: /proc/$pid does not exist"; return 1; }
  pass "$label: init is live at pid $pid"
}

# print the cgroup path of a pid
resolve_init_cgroup() {
  ssh_vm -t 10 "sed -n 's/^0:://p' /proc/$1/cgroup" | tr -d '[:space:]'
}

PROBE_SCRIPT=$(cat <<'PROBE'
set -u
emit() { printf 'RHIZO_DEVFILTER %s\n' "$1"; }
# print the lowest init second_stage pid
stack_init_pid() {
  _sip_pid=""
  for _sip_d in "${RHIZO_PROC_ROOT:-/proc}"/[0-9]*; do
    case "$(tr '\0' ' ' 2>/dev/null < "$_sip_d/cmdline")" in *"init second_stage"*) ;; *) continue ;; esac
    case "$(sed -n 's|^0::||p' "$_sip_d/cgroup" 2>/dev/null)" in
      /rhizo/*|/system.slice/androidd.service/android/*)
        [ -z "$_sip_pid" ] || [ "${_sip_d##*/}" -lt "$_sip_pid" ] && _sip_pid=${_sip_d##*/} ;;
    esac
  done
  [ -z "$_sip_pid" ] || echo "$_sip_pid"
}

INIT=$(stack_init_pid)
if [ -z "$INIT" ]; then emit "init=NONE"; exit 0; fi
if [ ! -d "/proc/$INIT" ]; then emit "init=GONE pid=$INIT"; exit 0; fi
emit "init=$INIT"

REL=$(sed -n 's/^0:://p' "/proc/$INIT/cgroup")
case "$REL" in
  /*) ;;
  *) emit "cgroup=UNRESOLVED rel=$REL"; exit 0 ;;
esac
CG="/sys/fs/cgroup$REL"
if [ ! -w "$CG/cgroup.procs" ]; then emit "cgroup=UNWRITABLE path=$CG"; exit 0; fi
emit "cgroup=$CG"

devnum() {
  [ -e "$1" ] || return 1
  printf '%d %d\n' "0x$(stat -c %t "$1")" "0x$(stat -c %T "$1")" 2>/dev/null
}
DRI=$(devnum "$(bash /root/share/detect-gpu-driver.sh --node 2>/dev/null | cut -d' ' -f1)") || DRI=""
UIN=$(devnum /dev/uinput)         || UIN=""
TUN=$(devnum /dev/net/tun)        || TUN=""
NUL=$(devnum /dev/null)           || NUL=""
emit "host_dri=${DRI:-ABSENT}"
emit "host_uinput=${UIN:-ABSENT}"
emit "host_tun=${TUN:-ABSENT}"
emit "host_null=${NUL:-ABSENT}"

UIN_MAJ=${UIN%% *}
UIN_MIN=${UIN##* }
TUN_MIN=${TUN##* }
CTLB=""
CTLB_NAME="none"
if [ -n "$UIN_MAJ" ]; then
  for n in /dev/*; do
    [ -c "$n" ] || continue
    d=$(devnum "$n") || continue
    m=${d%% *}; mi=${d##* }
    [ "$m" = "$UIN_MAJ" ] || continue
    [ "$mi" = "$UIN_MIN" ] && continue
    [ "$mi" = "$TUN_MIN" ] && continue
    CTLB="$d"; CTLB_NAME="$n"; break
  done
fi
emit "control_same_major=${CTLB:-NONE}"
emit "control_same_name=${CTLB_NAME}"

PRE_REL=$(sed -n 's/^0:://p' /proc/self/cgroup)
emit "pre_cgroup=${PRE_REL:-UNRESOLVED}"
PD=$(mktemp -d) || { emit "preprobe=NO_TMPDIR"; exit 0; }
premk() {
  lbl="$1"; pair="$2"
  if [ -z "$pair" ]; then emit "premknod_${lbl}=SKIPPED_HOST_NODE_ABSENT"; return; fi
  rm -f "$PD/$lbl"
  err=$(mknod "$PD/$lbl" c $pair 2>&1); rc=$?
  emit "premknod_${lbl}=rc=$rc"
  emit "premknod_${lbl}_err=$err"
  rm -f "$PD/$lbl"
}
premk dri     "$DRI"
premk uinput  "$UIN"
premk tun     "$TUN"
premk null    "$NUL"
premk ctlsame "$CTLB"
rmdir "$PD" 2>/dev/null
emit "preprobe=DONE"

sh -c '
  CG="$1"; REL="$2"; DRI="$3"; UIN="$4"; TUN="$5"; NUL="$6"; CTLB="$7"
  emit() { printf "RHIZO_DEVFILTER %s\n" "$1"; }
  echo $$ > "$CG/cgroup.procs" 2>/dev/null || { emit "joined=FAILED"; exit 0; }
  joined=$(sed -n "s/^0:://p" /proc/self/cgroup)
  emit "joined=$joined"
  if [ "$joined" != "$REL" ]; then
    emit "join=MISMATCH want=$REL got=$joined"
    exit 0
  fi
  D=$(mktemp -d) || { emit "probe=NO_TMPDIR"; exit 0; }
  mk() {
    lbl="$1"; pair="$2"
    if [ -z "$pair" ]; then emit "mknod_${lbl}=SKIPPED_HOST_NODE_ABSENT"; return; fi
    rm -f "$D/$lbl"
    err=$(mknod "$D/$lbl" c $pair 2>&1); rc=$?
    emit "mknod_${lbl}=rc=$rc"
    emit "mknod_${lbl}_err=$err"
    rm -f "$D/$lbl"
  }
  mk dri     "$DRI"
  mk uinput  "$UIN"
  mk tun     "$TUN"
  mk null    "$NUL"
  mk ctlsame "$CTLB"
  rmdir "$D" 2>/dev/null
  emit "probe=DONE"
' sh "$CG" "$REL" "$DRI" "$UIN" "$TUN" "$NUL" "$CTLB"
PROBE
)

# remove the policy file from the vm
cleanup_policy_conf() {
  (( TEST_NO_VM )) && return 0
  ssh_vm -t 10 "rm -f $POLICY_CONF" >/dev/null 2>&1
}
# shellcheck disable=SC2034
(( SELFTEST )) || TEST_EXTRA_CLEANUP=cleanup_policy_conf

if (( SELFTEST )); then
  step "selftest: every assertion above must be able to fail, by name"

  FAILLOG_SNAPSHOT="$TEST_WORKDIR/failures.log.snapshot"
  snapshot_failures_log() { cp "$EV/failures.log" "$FAILLOG_SNAPSHOT" 2>/dev/null || : > "$FAILLOG_SNAPSHOT"; }
  restore_failures_log() { cp "$FAILLOG_SNAPSHOT" "$EV/failures.log"; }

  check_fails() {
    local what="$1" fn="$2"; shift 2
    local before=$FAILED
    snapshot_failures_log
    "$fn" "$@" >/dev/null
    if (( FAILED > before )); then
      log "  selftest OK: $what"
      FAILED=$before
      restore_failures_log
    else
      fail "selftest: $what did NOT fail"
    fi
  }
  check_passes() {
    local what="$1" fn="$2"; shift 2
    local before=$FAILED
    "$fn" "$@" >/dev/null
    if (( FAILED > before )); then
      fail "selftest: $what fired on a genuinely good input"
    else
      log "  selftest OK: $what"
    fi
  }

  EXPECT_CG="/rhizo/init"
  EXPECT_DRI="226 128"
  EXPECT_UIN="10 223"
  EXPECT_TUN="10 200"
  GOOD=$(cat <<'EOF'
RHIZO_DEVFILTER init=1234
RHIZO_DEVFILTER cgroup=/sys/fs/cgroup/rhizo/init
RHIZO_DEVFILTER host_dri=226 128
RHIZO_DEVFILTER host_uinput=10 223
RHIZO_DEVFILTER host_tun=10 200
RHIZO_DEVFILTER host_null=1 3
RHIZO_DEVFILTER control_same_major=10 237
RHIZO_DEVFILTER control_same_name=/dev/loop-control
RHIZO_DEVFILTER pre_cgroup=/system.slice/sshd.service
RHIZO_DEVFILTER premknod_dri=rc=0
RHIZO_DEVFILTER premknod_dri_err=
RHIZO_DEVFILTER premknod_uinput=rc=0
RHIZO_DEVFILTER premknod_uinput_err=
RHIZO_DEVFILTER premknod_tun=rc=0
RHIZO_DEVFILTER premknod_tun_err=
RHIZO_DEVFILTER premknod_null=rc=0
RHIZO_DEVFILTER premknod_null_err=
RHIZO_DEVFILTER premknod_ctlsame=rc=0
RHIZO_DEVFILTER premknod_ctlsame_err=
RHIZO_DEVFILTER joined=/rhizo/init
RHIZO_DEVFILTER mknod_dri=rc=1
RHIZO_DEVFILTER mknod_dri_err=mknod: '/tmp/x/dri': Operation not permitted
RHIZO_DEVFILTER mknod_uinput=rc=1
RHIZO_DEVFILTER mknod_uinput_err=mknod: '/tmp/x/uinput': Operation not permitted
RHIZO_DEVFILTER mknod_tun=rc=1
RHIZO_DEVFILTER mknod_tun_err=mknod: '/tmp/x/tun': Operation not permitted
RHIZO_DEVFILTER mknod_null=rc=0
RHIZO_DEVFILTER mknod_null_err=
RHIZO_DEVFILTER mknod_ctlsame=rc=0
RHIZO_DEVFILTER mknod_ctlsame_err=
RHIZO_DEVFILTER probe=DONE
EOF
)

  check_passes "a fully passing probe (both denies, both controls, the join) is accepted" \
    assert_devfilter_probe x "$GOOD" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/mknod_uinput=rc=1/mknod_uinput=rc=0}"
  check_fails "uinput allowed is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/mknod_tun=rc=1/mknod_tun=rc=0}"
  check_fails "tun allowed is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/mknod_dri=rc=1/mknod_dri=rc=0}"
  check_fails "dri allowed is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/Operation not permitted/No such file or directory}"
  check_fails "a withheld mknod that failed with a non-permission error is not accepted as 'refused'" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER mknod_null=rc=0/RHIZO_DEVFILTER mknod_null=rc=1}"
  check_fails "the unwithheld /dev/null control refused (a blanket deny) is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER mknod_ctlsame=rc=0/RHIZO_DEVFILTER mknod_ctlsame=rc=1}"
  check_fails "the same-major control refused (a whole-major deny) is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/joined=\/rhizo\/init/joined=\/rhizo\/other}"
  check_fails "a join into the wrong cgroup is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/host_uinput=10 223/host_uinput=ABSENT}"
  check_fails "a host node that vanished between step 0b and the probe is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/host_dri=226 128/host_dri=ABSENT}"
  check_fails "a dri host node that vanished between step 0b and the probe is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/host_tun=10 200/host_tun=ABSENT}"
  check_fails "a tun host node that vanished between step 0b and the probe is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/init=1234/init=NONE}"
  check_fails "init never appearing is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER mknod_ctlsame=rc=0/RHIZO_DEVFILTER mknod_ctlsame=SKIPPED_HOST_NODE_ABSENT}"
  before=$FAILED
  snapshot_failures_log
  assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN" > "$EV/out.txt" 2>&1
  if (( FAILED > before )) && grep -q "no other char device on uinput/tun's own major" "$EV/out.txt" 2>/dev/null; then
    log "  selftest OK: no same-major control device found names that condition, not a generic host-node-absent"
    FAILED=$before
    restore_failures_log
  else
    fail "selftest: a missing same-major control did not name its real condition"
  fi

  MUT="${GOOD/RHIZO_DEVFILTER premknod_dri=rc=0/RHIZO_DEVFILTER premknod_dri=rc=1}"
  check_fails "a pre-join control mknod refused for dri is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER premknod_uinput=rc=0/RHIZO_DEVFILTER premknod_uinput=rc=1}"
  check_fails "a pre-join control mknod refused for uinput is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER premknod_tun=rc=0/RHIZO_DEVFILTER premknod_tun=rc=1}"
  check_fails "a pre-join control mknod refused for tun is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER premknod_null=rc=0/RHIZO_DEVFILTER premknod_null=rc=1}"
  check_fails "a pre-join control mknod refused for the null control is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER premknod_ctlsame=rc=0/RHIZO_DEVFILTER premknod_ctlsame=rc=1}"
  check_fails "a pre-join control mknod refused for the same-major control is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER pre_cgroup=\/system.slice\/sshd.service/RHIZO_DEVFILTER pre_cgroup=UNRESOLVED}"
  check_fails "a pre-join cgroup that never resolved is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER pre_cgroup=\/system.slice\/sshd.service/RHIZO_DEVFILTER pre_cgroup=$EXPECT_CG}"
  check_fails "a pre-join cgroup equal to the joined cgroup is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER pre_cgroup=\/system.slice\/sshd.service/RHIZO_DEVFILTER pre_cgroup=\/rhizo}"
  check_fails "a pre-join cgroup that is the joined cgroup's own parent is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  MUT="${GOOD/RHIZO_DEVFILTER pre_cgroup=\/system.slice\/sshd.service/RHIZO_DEVFILTER pre_cgroup=$EXPECT_CG\/deeper}"
  check_fails "a pre-join cgroup that is a child of the joined cgroup is caught" assert_devfilter_probe x "$MUT" "$EXPECT_CG" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  check_passes "a pre-join cgroup outside the filter's attach point is accepted" \
    assert_devfilter_precontrol_cgroup x "$GOOD" "$EXPECT_CG"

  check_passes "an unresolved cgroup premise skips the join comparison instead of blaming the probe" \
    assert_devfilter_probe x "$GOOD" "" "$EXPECT_DRI" "$EXPECT_UIN" "$EXPECT_TUN"

  check_fails "an unshaped cgroup read (e.g. a failed guest_read's own error text) is caught" \
    assert_expect_cgroup_shape x "cat: /proc/1234/cgroup: No such file or directory"
  check_fails "an empty cgroup read is caught" assert_expect_cgroup_shape x ""
  check_passes "a real cgroup path is accepted" assert_expect_cgroup_shape x "/rhizo/init"

  check_fails "an absent host node at step 0b is caught" assert_host_node x devices.uinput "ABSENT"
  check_fails "an empty host node reading at step 0b is caught" assert_host_node x devices.tun ""
  check_passes "a resolved host node at step 0b is accepted" assert_host_node x devices.dri "226 128"

  POLICY_GOOD=$'[devices]\ndri = no\nuinput = no\ntun = no'
  check_fails "a wrong value in the written policy is caught" assert_devices_policy_written x "$POLICY_GOOD" yes no no
  check_fails "a file the write never reached is caught" assert_devices_policy_written x "" no no no
  check_passes "the written policy is accepted" assert_devices_policy_written x "$POLICY_GOOD" no no no

  check_fails "init never appearing after a restart is caught" assert_init_live x ""

  if (( FAILED )); then
    log "test-device-filter --selftest: FAILED"
    exit 1
  fi
  log "test-device-filter --selftest: the system test can still fail"
  exit 0
fi

for _ev_name in host-nodes.txt policy.conf probe.txt \
    restart-withheld.log init-withheld.txt; do
  save_evidence "$_ev_name" "<none: this run did not reach the step that writes $_ev_name>"
done
unset _ev_name

step "0. a vm booted normally, staged, not yet launched -- so /etc is still writable"
BOOT_ARGS=(--skip-graphics-preflight)
[[ -n "${RHIZO_RELEASE:-}" ]] && BOOT_ARGS+=(--release "$RHIZO_RELEASE")
test_boot "${BOOT_ARGS[@]}" || { test_record_verdict FAILED; exit 1; }

STAGE_LOG="$EV/redeploy-stage.log"
if ! ../../vm/redeploy.sh --skip-kill --no-launch > "$STAGE_LOG" 2>&1; then
  fail "0. redeploy.sh --no-launch failed -- see $STAGE_LOG"
  test_record_verdict FAILED
  exit 1
fi
pass "0. staged with no launch (nothing has started Android yet)"

step "0b. the three host nodes this proof depends on actually exist on this guest (module-backed; may need modprobe)"
NODES_CMD=$(cat <<'NODES'
u_out=$(modprobe uinput 2>&1); u_rc=$?
t_out=$(modprobe tun 2>&1); t_rc=$?
echo "RHIZO_DEVFILTER0B modprobe_uinput_rc=$u_rc"
echo "RHIZO_DEVFILTER0B modprobe_uinput_out=$u_out"
echo "RHIZO_DEVFILTER0B modprobe_tun_rc=$t_rc"
echo "RHIZO_DEVFILTER0B modprobe_tun_out=$t_out"
devnum() {
  [ -e "$1" ] || { echo ABSENT; return; }
  printf '%d %d\n' "0x$(stat -c %t "$1")" "0x$(stat -c %T "$1")"
}
echo "RHIZO_DEVFILTER0B host_dri=$(devnum "$(bash /root/share/detect-gpu-driver.sh --node 2>/dev/null | cut -d' ' -f1)")"
echo "RHIZO_DEVFILTER0B host_uinput=$(devnum /dev/uinput)"
echo "RHIZO_DEVFILTER0B host_tun=$(devnum /dev/net/tun)"
NODES
)
NODES_OUT=$(ssh_vm -t 30 "$NODES_CMD" 2>&1)
save_evidence host-nodes.txt "$NODES_OUT"
HOST_DRI_0B=$(devfilter_field0b host_dri "$NODES_OUT")
HOST_UIN_0B=$(devfilter_field0b host_uinput "$NODES_OUT")
HOST_TUN_0B=$(devfilter_field0b host_tun "$NODES_OUT")

BEFORE_0B=$FAILED
assert_host_node "0b1" "devices.dri" "$HOST_DRI_0B"
assert_host_node "0b2" "devices.uinput" "$HOST_UIN_0B"
assert_host_node "0b3" "devices.tun" "$HOST_TUN_0B"
if (( FAILED > BEFORE_0B )); then
  test_record_verdict FAILED
  exit 1
fi

step "1. withhold all three devices.* capabilities"
POLICY_OUT=$(write_devices_policy no no no)
save_evidence policy.conf "$POLICY_OUT"
assert_devices_policy_written "1" "$POLICY_OUT" no no no

step "2. start the stack under the withheld policy, and resolve init LIVE -- never sys.boot_completed"
RESTART_LOG="$EV/restart-withheld.log"
ssh_vm -t 300 'systemctl restart androidd.service' > "$RESTART_LOG" 2>&1
RESTART_RC=$?
echo "systemctl restart androidd.service rc=$RESTART_RC" >> "$RESTART_LOG"
if (( RESTART_RC != 0 )); then
  fail "2. systemctl restart androidd.service exited $RESTART_RC -- see $RESTART_LOG"
fi
INIT=$(resolve_init 180)
save_evidence init-withheld.txt "pid=${INIT:-<none>}"
assert_init_live "2" "$INIT"

if [[ -n "$INIT" ]]; then
  EXPECT_CG=$(resolve_init_cgroup "$INIT")
  assert_expect_cgroup_shape "2b" "$EXPECT_CG" || EXPECT_CG=""

  step "3. the probe: a pre-join control (outside the filter's attach point) and the joined withhold/allow set (inside the sandbox's leaf), taken by the same process in the same run"
  PROBE_OUT=$(ssh_vm -t 60 "$PROBE_SCRIPT" 2>&1)
  save_evidence probe.txt "$PROBE_OUT"

  step "4. parse and assert the probe's own report -- the pre-join control (all five must succeed, outside the filter) and the joined half (the withheld three refused, the two controls still allowed)"
  assert_devfilter_probe "4" "$PROBE_OUT" "$EXPECT_CG" "$HOST_DRI_0B" "$HOST_UIN_0B" "$HOST_TUN_0B"
else
  skip "3. probe: init never appeared under the withheld policy -- see step 2's own fail"
  skip "4. probe assertions: not run, no probe output to parse"
fi

if (( FAILED )); then
  test_record_verdict FAILED
  log "test-device-filter: FAILED"
  exit 1
fi
test_record_verdict PASSED
log "test-device-filter: PASSED -- evidence in $EV"
exit 0
