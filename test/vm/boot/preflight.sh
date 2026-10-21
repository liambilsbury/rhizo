#!/bin/bash
# check a vm is ready for a boot
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh
source ../guest-os/guest-os-lib.sh
source ../../system/lib/gsi-update-cleanup.sh

QUIET=0
SKIP_GRAPHICS=0
SKIP_GSI_TREE=0
SKIP_RESIDUE=0
REDEPLOY_FOLLOWS=0
SELFTEST=0
for _a in "$@"; do
  case "$_a" in
    --quiet) QUIET=1 ;;
    --skip-graphics) SKIP_GRAPHICS=1 ;;
    --skip-gsi-tree) SKIP_GSI_TREE=1 ;;
    --skip-residue) SKIP_RESIDUE=1 ;;
    --redeploy-follows) REDEPLOY_FOLLOWS=1 ;;
    --selftest) SELFTEST=1 ;;
  esac
done

FAILED=0
# print an ok line unless quiet
ok()   { (( QUIET )) || echo "  ok   $*"; }
# print a SKIP line to stderr
skipped() { echo "  SKIP $*" >&2; }
# print a FAIL line to stderr and mark the preflight failed
bad()  { echo "  FAIL $*" >&2; FAILED=1; }
# print a WARNING line to stderr
warn() { echo "  WARNING: $*" >&2; }
# print a hint line to stderr
hint() { echo "       $*" >&2; }

# print the server-profile masked unit names
masked_units_from_cli() {
  awk '
    /^SERVER_MASKED_UNITS=\(/ { inarr = 1 }
    inarr {
      line = $0
      sub(/^SERVER_MASKED_UNITS=\(/, "", line)
      closed = index(line, ")")
      sub(/\).*$/, "", line)
      n = split(line, f)
      for (i = 1; i <= n; i++)
        if (f[i] ~ /^[A-Za-z0-9@_.-]+\.(service|socket|path|timer)$/) print f[i]
      if (closed) exit
    }
  ' "${1:-$REPO/src/install/cli/rhizo.sh}" 2>/dev/null
}

# check the vm for leftover run state
check_residue() {
  local cli="${1:-}" out rc line id detail body mask_probe
  local -a mask_units=() masked=() instances=() androidd=()
  mapfile -t mask_units < <(masked_units_from_cli "$cli")
  mask_probe=': no unit list to ask about'
  if (( ${#mask_units[@]} )); then
    mask_probe='for u in '"${mask_units[*]}"'; do
        case "$(systemctl is-enabled "$u" 2>/dev/null)" in
          masked|masked-runtime) echo "masked:$u" ;;
        esac
      done'
  fi
  body='
      RESIDUE_MASK_PROBE
      for f in /etc/rhizo/instances/*.env; do
        [ -e "$f" ] || continue
        b=${f##*/}
        echo "instance-env:${b%.env}"
      done
      systemctl list-units --no-legend --no-pager --state=active "androidd@*.service" 2>/dev/null |
        while read -r row; do
          for tok in $row; do
            case "$tok" in androidd@*.service) echo "androidd-active:$tok" ;; esac
          done
        done
      echo RESIDUE_PROBE_OK
    '
  body="${body//RESIDUE_MASK_PROBE/$mask_probe}"
  out=$(ssh_vm -t 30 "$body")
  rc=$?
  out="${out//$'\r'/}"
  if (( rc != 0 )); then
    skipped "vm residue: the guest did not answer this probe (ssh_vm rc=$rc)"
  elif ! grep -qx RESIDUE_PROBE_OK <<<"$out"; then
    skipped "vm residue: the probe never reached its own end marker on the guest"
  else
    while IFS= read -r line; do
      case "$line" in
        masked:*) masked+=("${line#masked:}") ;;
        instance-env:*)
          id="${line#instance-env:}"
          if [[ "$id" =~ ^[0-9]+$ ]] && (( 10#$id == 0 )); then continue; fi
          instances+=("$id") ;;
        androidd-active:*) androidd+=("${line#androidd-active:}") ;;
      esac
    done <<<"$out"
    if (( ${#mask_units[@]} == 0 )); then
      skipped "server-profile masks: no SERVER_MASKED_UNITS array parsed out of src/install/cli/rhizo.sh"
    elif (( ${#masked[@]} )); then
      warn "residue: ${masked[*]} masked"
      hint "redeploy.sh's staging unmasks them. By hand: rhizo profile desktop"
    else
      ok "no server-profile masks (${#mask_units[@]} units, read from src/install/cli/rhizo.sh)"
    fi
    detail=""
    (( ${#instances[@]} )) && detail+=" /etc/rhizo/instances/{${instances[*]}}.env still configured"
    (( ${#androidd[@]} )) && detail+=" ${androidd[*]} still active"
    if [[ -n "$detail" ]]; then
      warn "residue:$detail"
      hint "test-multi-instance's own reset clears this before its redeploy."
      hint "By hand: rhizo pool set 0, then rhizo instance remove <id>"
    else
      ok "no instance above 0 configured and no androidd@ instance running"
    fi
  fi

  if gsi_update_vm_has_residue 30; then
    bad "gsi-update residue on this vm: $GSI_UPDATE_RESIDUE_MSG"
    hint "/var/lib/rhizo/update pins the release for this guest. Clear it by hand:"
    hint "test/system/manual/gsi-update-vm-reset.sh $RHIZO_VM"
  elif [[ "$GSI_UPDATE_RESIDUE_MSG" == "could not check"* ]]; then
    skipped "gsi-update residue: $GSI_UPDATE_RESIDUE_MSG"
  else
    ok "no gsi-update residue"
  fi
}

# check the running kernel for binder and ashmem
check_kernel() {
  local out dev lacks=""
  out=$(ssh_vm -t 15 'echo "BINDER_DEVICES=$(cat /sys/module/binder/parameters/devices 2>&1)"
if grep -qw binder /proc/filesystems; then echo BINDERFS_REGISTERED; fi
if [ -c /dev/ashmem ]; then echo ASHMEM_CHAR; fi
if [ -e /proc/config.gz ]; then echo CONFIG_GZ; fi
echo KERNEL_PROBE_END' 2>&1)
  out="${out//$'\r'/}"
  dev=$(sed -n 's/^BINDER_DEVICES=//p' <<<"$out")
  if ! grep -qx KERNEL_PROBE_END <<<"$out"; then
    bad "kernel $1: the probe never reached its end marker (${out:-no answer})"
    return
  fi
  [[ "$dev" == binder,hwbinder,vndbinder ]] || lacks+=" binder devices '$dev', not binder,hwbinder,vndbinder;"
  grep -qx BINDERFS_REGISTERED <<<"$out" || lacks+=" no binderfs in /proc/filesystems;"
  grep -qx ASHMEM_CHAR <<<"$out" || lacks+=" no /dev/ashmem;"
  grep -qx CONFIG_GZ <<<"$out" || lacks+=" no /proc/config.gz;"
  if [[ -z "$lacks" ]]; then
    ok "kernel $1 has built-in binder (devices=$dev), binderfs, /dev/ashmem and /proc/config.gz"
  else
    bad "kernel $1:${lacks%;}"
    hint "Rhizo needs the Rhizo kernel (linux-image-rhizo / linux-rhizo); boot the vm on it"
  fi
}

if (( SELFTEST )); then
  st_fails=0
  st_dir=$(mktemp -d)
  st_case() {
    local name="$1" want_failed="$2" re="$3"
    shift 3
    FAILED=0
    check_residue "$@" >"$st_dir/out" 2>&1
    if (( FAILED != want_failed )) || ! grep -Eq "$re" "$st_dir/out"; then
      echo "FAIL selftest: $name (FAILED=$FAILED, wanted $want_failed, wanted /$re/)"
      sed 's/^/    /' "$st_dir/out"
      st_fails=1
    else
      echo "ok   selftest: $name"
    fi
  }
  gsi_update_vm_has_residue() { GSI_UPDATE_RESIDUE_MSG="no gsi-update residue found"; return 1; }

  mapfile -t st_units < <(masked_units_from_cli)
  if (( ${#st_units[@]} == 19 )) \
     && [[ " ${st_units[*]} " == *" rhizo-hostfs.service "* ]] \
     && [[ " ${st_units[*]} " == *" rhizo-display-pool-release.service "* ]]; then
    echo "ok   selftest: the mask list comes from src/install/cli/rhizo.sh (${#st_units[@]} units, continuation lines included)"
  else
    echo "FAIL selftest: parsing SERVER_MASKED_UNITS out of src/install/cli/rhizo.sh gave ${#st_units[@]} units: ${st_units[*]:-<none>}"
    st_fails=1
  fi

  ssh_vm() { echo RESIDUE_PROBE_OK; }
  st_case "a clean vm passes" 0 "ok   no server-profile masks"
  ssh_vm() { printf 'instance-env:00\nRESIDUE_PROBE_OK\n'; }
  st_case "instance 0's own env file is not residue" 0 "ok   no instance above 0"
  ssh_vm() { printf 'masked:rhizo-hostfs.service\nRESIDUE_PROBE_OK\n'; }
  st_case "a masked unit warns and does not refuse the boot" 0 "WARNING: residue: rhizo-hostfs.service masked"
  st_case "the mask warning still names the by-hand fix" 0 "rhizo profile desktop"
  ssh_vm() { printf 'instance-env:2\nandroidd-active:androidd@2.service\nRESIDUE_PROBE_OK\n'; }
  st_case "a leftover instance warns and does not refuse the boot" 0 "WARNING: residue:.*instances.*still configured.*androidd@2.service still active"
  st_case "the instance warning still names the by-hand fix" 0 "rhizo instance remove"
  ssh_vm() { return 255; }
  st_case "a vm that cannot answer SKIPs, never passes" 0 "SKIP vm residue.*ssh_vm rc=255"
  ssh_vm() { echo masked:rhizo-hostfs.service; }
  st_case "a probe cut off before its end marker SKIPs" 0 "SKIP vm residue.*end marker"
  ssh_vm() { echo RESIDUE_PROBE_OK; }
  : >"$st_dir/no-array.sh"
  st_case "a CLI with no SERVER_MASKED_UNITS SKIPs the mask half" 0 "SKIP server-profile masks" "$st_dir/no-array.sh"
  ssh_vm() { printf 'instance-env:2\nRESIDUE_PROBE_OK\n'; }
  st_case "an unreadable mask list does not take the instance half with it" 0 "WARNING: residue:.*instances.*still configured" "$st_dir/no-array.sh"
  ssh_vm() { echo RESIDUE_PROBE_OK; }
  gsi_update_vm_has_residue() { GSI_UPDATE_RESIDUE_MSG="residue found: update-dir-present"; return 0; }
  st_case "gsi-update residue is the one half that FAILS, naming the reset tool" 1 "FAIL gsi-update residue"
  st_case "the gsi-update failure names the reset tool" 1 "gsi-update-vm-reset.sh"
  gsi_update_vm_has_residue() { GSI_UPDATE_RESIDUE_MSG="could not check -- ssh_vm itself failed (rc=255), the vm may be unreachable"; return 1; }
  st_case "an unreachable vm SKIPs the gsi-update half instead of passing it" 0 "SKIP gsi-update residue"

  st_kernel() {
    FAILED=0
    check_kernel 7.1.0-rc1-rhizo >"$st_dir/out" 2>&1
    if (( FAILED != $2 )) || ! grep -Eq "$3" "$st_dir/out"; then
      echo "FAIL selftest: $1 (FAILED=$FAILED, wanted $2, wanted /$3/)"
      sed 's/^/    /' "$st_dir/out"
      st_fails=1
    else
      echo "ok   selftest: $1"
    fi
  }
  ssh_vm() { printf '%s\n' "$PROBE"; }
  PROBE=$'BINDER_DEVICES=binder,hwbinder,vndbinder\nBINDERFS_REGISTERED\nASHMEM_CHAR\nCONFIG_GZ\nKERNEL_PROBE_END'
  st_kernel "the Rhizo kernel passes" 0 "ok   kernel 7.1.0-rc1-rhizo has built-in binder \(devices=binder,hwbinder,vndbinder\), binderfs, /dev/ashmem and /proc/config.gz"
  PROBE=$'BINDER_DEVICES=binder\nBINDERFS_REGISTERED\nASHMEM_CHAR\nCONFIG_GZ\nKERNEL_PROBE_END'
  st_kernel "a binder with one device FAILS" 1 "FAIL kernel 7.1.0-rc1-rhizo: binder devices 'binder', not binder,hwbinder,vndbinder$"
  PROBE=$'BINDER_DEVICES=cat: /sys/module/binder/parameters/devices: No such file or directory\nKERNEL_PROBE_END'
  st_kernel "a stock kernel FAILS naming all four" 1 "no binderfs in /proc/filesystems; no /dev/ashmem; no /proc/config.gz$"
  PROBE=$'BINDER_DEVICES=binder,hwbinder,vndbinder\nBINDERFS_REGISTERED\nCONFIG_GZ\nKERNEL_PROBE_END'
  st_kernel "a kernel without ashmem FAILS" 1 "FAIL kernel 7.1.0-rc1-rhizo: no /dev/ashmem$"
  PROBE='BINDER_DEVICES=binder,hwbinder,vndbinder'
  st_kernel "a kernel probe cut short FAILS" 1 "FAIL kernel 7.1.0-rc1-rhizo: the probe never reached its end marker"

  rm -rf "$st_dir"
  if (( st_fails )); then
    echo "vm-preflight residue selftest FAILED" >&2
    exit 1
  fi
  echo "vm-preflight residue selftest: every case passed"
  exit 0
fi

(( QUIET )) || echo "vm $RHIZO_VM preflight (ssh :$SSH_PORT)"

if ! wait_for_ssh 15 >/dev/null 2>&1; then
  echo "  UNREACHABLE vm $RHIZO_VM: no ssh on port $SSH_PORT" >&2
  hint "boot it first: RHIZO_VM=$RHIZO_VM test/vm/redeploy.sh --no-launch"
  exit 2
fi
ok "ssh"

guest_os=$(guest_os_id)
rc=$?
if (( rc != 0 )) || [[ "$guest_os" != "$RHIZO_GUEST_OS" ]]; then
  if (( rc != 0 )); then
    bad "could not read the guest's /etc/os-release (ssh_vm rc=$rc)"
  else
    bad "vm $RHIZO_VM runs ID=${guest_os:-<empty>} but RHIZO_GUEST_OS is '$RHIZO_GUEST_OS'"
    hint "run this with RHIZO_GUEST_OS set to the OS the vm booted"
  fi
  rig_vm_record "$RHIZO_VM" preflight=failed
  echo "vm $RHIZO_VM is NOT ready to boot Android" >&2
  exit 1
fi

if (( SKIP_RESIDUE )); then
  skipped "vm residue: this caller owns the vm state it starts from (--skip-residue)"
else
  check_residue
fi

if [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
  skipped "half-configured packages: a cachyos guest has no dpkg"
elif (( SKIP_GRAPHICS )); then
  skipped "half-configured packages: deferred to this caller's own start-sway.sh step"
else
  unconf=$(ssh_vm -t 25 'dpkg -l 2>/dev/null | awk "\$1 ~ /^i[^i]/ {print \$2}" | tr "\n" " "')
  unconf=$(tr -d '\r' <<<"$unconf" | sed 's/  */ /g; s/^ *//; s/ *$//')
  leftover=$(tr ' ' '\n' <<<"$unconf" | grep -v '^linux-modules-extra' | grep -v '^$' | tr '\n' ' ')
  if [[ -n "${leftover// /}" ]]; then
    bad "half-configured packages: ${leftover}"
    hint "apt-get --fix-broken install -y in the guest;"
    hint "if apt refuses with 'dpkg was interrupted', run dpkg --configure -a,"
    hint "then apt-get --fix-broken install -y again;"
    hint "dpkg --audit names the package; stage a missing .deb into"
    hint "$SHARE_DIR/sway-debs/ and dpkg -i it"
  else
    ok "no half-configured packages"
  fi
fi

if ssh_vm -t 10 'getent passwd rhizo-netbridged >/dev/null' >/dev/null 2>&1; then
  ok "rhizo-netbridged account resolves"
elif (( REDEPLOY_FOLLOWS )); then
  skipped "rhizo-netbridged account: absent, deferred to this caller's own redeploy.sh staging step"
else
  bad "rhizo-netbridged account missing -- units naming it die 217/USER"
  hint "redeploy.sh's staging creates it (debian/rhizo.postinst)"
fi

kver=$(ssh_vm -t 15 'uname -r' | tr -d '\r\n')

check_kernel "$kver"

if (( SKIP_GRAPHICS )); then
  skipped "egl: deferred to this caller's own start-sway.sh step"
else
egl=$(ssh_vm -t 45 "pgrep -x sway >/dev/null 2>&1 && echo ALREADY-RUNNING && exit 0
  XDG_RUNTIME_DIR=/run/user/0 WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
  WLR_RENDERER=gles2 timeout 12 sway -c /dev/null -d 2>&1 \
  | grep -m1 'EGL driver name'" 2>/dev/null | tr -d '\r')
if [[ "$egl" == *"ALREADY-RUNNING"* ]]; then
  skipped "egl: a compositor is already running on this vm"
elif [[ -n "$egl" ]]; then
  ok "egl context creates (${egl##*: })"
else
  bad "no EGL context: the renderer cannot initialize"
  hint "run test/vm/start/start-sway.sh on this vm"
fi
fi

gsi="${RHIZO_GSI:-/srv/rhizo/gsi_system}"
if (( SKIP_GSI_TREE )); then
  skipped "gsi tree at $gsi: deferred to this caller's own redeploy.sh self-staging step"
elif [[ "$RHIZO_GUEST_OS" == cachyos ]] && ! ssh_vm -t 15 "test -s '$gsi/bin/init'" >/dev/null 2>&1; then
  skipped "gsi tree at $gsi: absent on a cachyos base until redeploy.sh stages it"
else
gsi_body='
  if [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = 1 ]; then
    echo "NOPROBE this guest is already enforcing"
    exit 0
  fi
  for f in bin/init bin/app_process64 bin/servicemanager bin/toybox; do
    [ -s "$g/$f" ] || { echo "MISSING $f"; continue; }
    hdr=$(od -An -tx1 -N20 "$g/$f" 2>/dev/null | tr -d " \n")
    case "$hdr" in
      7f454c4602*) ;;
      *) echo "NOTELF64 $f"; continue ;;
    esac
    [ "${hdr:36:4}" = 3e00 ] || echo "WRONGARCH $f"
    shoff=$(od -An -tu8 -j40 -N8 "$g/$f" | tr -d " ")
    shent=$(od -An -tu2 -j58 -N2 "$g/$f" | tr -d " ")
    shnum=$(od -An -tu2 -j60 -N2 "$g/$f" | tr -d " ")
    size=$(stat -c %s "$g/$f")
    if [ -n "$shoff" ] && [ $((shoff + shnum * shent)) -gt "$size" ]; then
      echo "TRUNCATED $f ($size bytes, ELF claims $((shoff + shnum * shent)))"
    fi
  done
  err=$(GSI_LOAD_CMD 2>&1 >/dev/null | grep -v linkerconfig | head -1)
  if [ -z "$err" ]; then
    echo LOADS
  else
    case "$err" in
      *"Permission denied"*|*"permission denied"*)
        echo "NOPROBE the loader was refused by policy ($err)" ;;
      *) echo "NOLOAD $err" ;;
    esac
  fi
'
gsi_body="${gsi_body//GSI_LOAD_CMD/$(gsi_bootstrap_cmd "$gsi" bin/toybox true)}"
gsi_body="${gsi_body//GSI_TREE/$gsi}"
gsi_check=$(ssh_vm -t 40 "g='$gsi'; $gsi_body" | tr -d '\r')
noprobe=$(grep '^NOPROBE ' <<<"$gsi_check" | head -1)
gsi_bad=$(grep -vE '^(LOADS|NOPROBE )' <<<"$gsi_check" | tr '\n' ' ')
if [[ -n "${gsi_bad// /}" ]]; then
  bad "GSI tree at $gsi is not usable: ${gsi_bad}"
  hint "re-stage it with test/vm/image/stage-gsi-trees.sh, or check RHIZO_GSI points at the right tree"
elif [[ -n "$noprobe" ]]; then
  skipped "gsi tree at $gsi not checked: ${noprobe#NOPROBE }"
else
  ok "GSI tree at $gsi loads (toybox ran under its own bootstrap linker)"
fi
fi

freepct=$(ssh_vm -t 20 "df --output=pcent / | tail -1 | tr -dc '0-9'")
if [[ -z "$freepct" ]]; then
  bad "could not read the guest's disk usage"
elif (( freepct >= 92 )); then
  bad "guest root filesystem is ${freepct}% full"
  hint "du -sh /srv/rhizo /var/lib/rhizo/data.img /var/lib/rhizo/templates /var/cache/rhizo/gsi /var/lib/rhizo/prepared to find what grew, then re-check"
else
  ok "guest disk ${freepct}% used"
fi

data_out=$("$REPO/test/checks/vm/boot/vm-preparedness.sh" --data-only --quiet 2>&1)
data_rc=$?
if (( data_rc == 0 )); then
  ok "/data release marker: $(sed -n 's/^RHIZO_PREPARED_STATE.*data=\([^ ]*\).*/\1/p' <<<"$data_out")"
elif (( data_rc == 3 )); then
  log "    $(grep '^  WARN' <<<"$data_out" | sed 's/^  WARN //')"
else
  bad "$(grep '^  FAIL' <<<"$data_out" | sed 's/^  FAIL //')"
  hint "test/vm/image/prepare-guest.sh --wipe-data wipes /data onto the release this boot wants; or boot with RHIZO_WIPE_DATA=1"
fi

if (( REDEPLOY_FOLLOWS )); then
  skipped "prepared tree: deferred to this caller's own redeploy.sh staging step"
else
  prep_out=$("$REPO/test/checks/vm/boot/vm-preparedness.sh" --prepared-only --quiet 2>&1)
  log "    prepared tree: $(sed -n 's/^RHIZO_PREPARED_STATE.*prepared=\([^ ]*\).*/\1/p' <<<"$prep_out")"
fi

if (( FAILED )); then
  rig_vm_record "$RHIZO_VM" preflight=failed
  echo "vm $RHIZO_VM is NOT ready to boot Android" >&2
  exit 1
fi
rig_vm_record "$RHIZO_VM" preflight=clean
(( QUIET )) || echo "vm $RHIZO_VM preflight clean"
exit 0
