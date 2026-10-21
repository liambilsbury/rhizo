#!/bin/bash
# test the /proc/sysrq-trigger mask
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO="${RHIZO_CHECK_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
MOUNTS="$REPO/src/androidd/sandbox/rootfs.py"
LAUNCHER="$REPO/src/androidd/boot.py"
TEST="$REPO/test/system/boot/host-safety.sh"

FAILED=0
# print a failure line and mark the check failed
bad() { echo "FAIL: sysrq mask: $*"; FAILED=1; }

# remove blanks and newlines from $1
flatten() { tr -d ' \t\n' <<<"$1"; }

# print the python function $2 from file $1
func_body() {
  awk -v fn="$2" '
    $0 ~ "^def "fn"\\(" { f=1 }
    f && /^[^ \t]/ && !($0 ~ "^def "fn"\\(") { exit }
    f { print }
  ' "$1"
}

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' EXIT
  mkdir -p "$t/src/androidd/sandbox" "$t/test/system/boot"

  write_good() {
    cat > "$t/src/androidd/sandbox/rootfs.py" <<'MOUNTSEOF'
def harden_proc_sys():
    """CONFINEMENT: bind /proc/sys over itself and remount it read-only so
    init's sysctl writes EROFS harmlessly. /proc/sysrq-trigger is a SIBLING
    of /proc/sys, not a child, and is masked separately below over its own
    dedicated /dev/.rhizo_sysrq_sink dummy -- see that block's own comment
    for why the sink must never be /dev/null.

    Returns True if the RO remount and the sysrq mask both landed, so a
    caller can fail loudly instead of silently running an unconfined
    sandbox."""
    ro_ok = False
    if mount("/proc/sys", "/proc/sys", None, MS_BIND):
        ro_ok = bool(mount(None, "/proc/sys", None, MS_BIND | MS_REMOUNT | MS_RDONLY))
    sysrq_ok, sysrq_labeled = _mask_sysrq_trigger()
    kmsg(f"proc-sys hardened by owner: ro={'ok' if ro_ok else 'FAIL'} "
         f"sysrq={'ok' if sysrq_ok else 'FAIL'}")
    return ro_ok and sysrq_ok


def build_root_and_pivot(mount_proc=True):
    if os.path.exists("/sys/block/zram0/reset"):
        open("/rhizoroot/tmp_zram_reset","w").write("")
        mount("/rhizoroot/tmp_zram_reset", f"{NEWROOT}/sys/block/zram0/reset", None, MS_BIND)


def _mask_sysrq_trigger():
    """Mask /proc/sysrq-trigger inside the sandbox, and say whether it landed."""
    _sysrq_dst = "/proc/sysrq-trigger"
    _sysrq_sink = "/dev/.rhizo_sysrq_sink"
    try:
        cur, snk = os.stat(_sysrq_dst), os.stat(_sysrq_sink)
        if ((cur.st_dev, cur.st_ino) == (snk.st_dev, snk.st_ino)
                and os.statvfs(_sysrq_dst).f_flag & os.ST_RDONLY):
            return True, True
    except OSError:
        pass
    _detach_if_mounted(_sysrq_dst)
    try:
        open(_sysrq_sink, "w").close()
        os.chmod(_sysrq_sink, 0o644)
        if not mount(_sysrq_sink, _sysrq_dst, None, MS_BIND):
            return False, False
        return bool(mount(None, _sysrq_dst, None, MS_BIND | MS_REMOUNT | MS_RDONLY)), False
    except OSError as e:
        kmsg(f"sysrq-sink: {e}")
        return False, False


def _pivot_and_harden(mount_proc=True):
    if mount_proc:
        harden_proc_sys()
MOUNTSEOF
    cat > "$t/src/androidd/boot.py" <<'LAUNCHEREOF'
def androidd_stop():
    """androidd.service's ExecStop: drive Android's sys.powerctl=shutdown
    sequence, wait it out, and fall back to a namespace-scoped kill if it
    does not finish in time.

    What DOES work before that final, structurally-blocked call:
    StopServices()/StopUntrackedProcesses() (reboot.cpp:938-949), which kill
    zygote/system_server/every app by signaling their own process groups,
    already pid/cgroup scoped, well before KillAllProcesses() is ever
    reached."""
    pass
LAUNCHEREOF
    cat > "$t/test/system/boot/host-safety.sh" <<'TESTEOF'
#!/bin/bash
# proves the /proc/sysrq-trigger mask holds both directions: a write outside
# the sandbox reaches dmesg as sysrq, a write inside it (nsenter) does not.
# baseline: boot_id, sshd, systemd-networkd, systemd-udevd pids unchanged.
TESTEOF
    chmod +x "$t/test/system/boot/host-safety.sh"
  }

  CASES=0
  check_case() {
    local name="$1" want="$2" out
    CASES=$((CASES + 1))
    out=$(RHIZO_CHECK_REPO_DIR="$t" "$SELF" 2>&1)
    if ! grep -qF "$want" <<<"$out"; then
      echo "SELFTEST FAILED ($name): expected to see:" >&2
      echo "  $want" >&2
      echo "the check produced:" >&2
      sed 's/^/    /' <<<"$out" >&2
      exit 1
    fi
  }

  write_good
  out=$(RHIZO_CHECK_REPO_DIR="$t" "$SELF" 2>&1); rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "SELFTEST FAILED (unmutated): a fully-fixed tree still failed:" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  write_good
  sed -i '/_detach_if_mounted(_sysrq_dst)/d' "$t/src/androidd/sandbox/rootfs.py"
  check_case "no detach" "no _detach_if_mounted call for /proc/sysrq-trigger"

  write_good
  sed -i 's/mount(_sysrq_sink, _sysrq_dst, None, MS_BIND)/mount("\/dev\/null", _sysrq_dst, None, MS_BIND)/' "$t/src/androidd/sandbox/rootfs.py"
  check_case "sink is /dev/null" "bind source is /dev/null"

  write_good
  sed -i '/mount(None, _sysrq_dst/d' "$t/src/androidd/sandbox/rootfs.py"
  check_case "no RO remount" "no MS_BIND|MS_REMOUNT|MS_RDONLY remount of /proc/sysrq-trigger"

  write_good
  sed -i '/sys\/block\/zram0\/reset", None, MS_BIND/d' "$t/src/androidd/sandbox/rootfs.py"
  check_case "no zram shadow" "no shadow bound over /sys/block/zram0/reset"

  write_good
  sed -i "s/init's sysctl writes EROFS harmlessly\./init's sysctl\/sysrq writes EROFS harmlessly./" "$t/src/androidd/sandbox/rootfs.py"
  check_case "outdated docstring" "harden_proc_sys docstring still claims sysrq is EROFS-masked by the /proc/sys bind"

  write_good
  sed -i 's/return ro_ok and sysrq_ok/return ro_ok/' "$t/src/androidd/sandbox/rootfs.py"
  check_case "return ignores sysrq" "return value does not depend on the sysrq bind outcome"

  write_good
  python3 - "$t/src/androidd/boot.py" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace(
  "What DOES work before that final, structurally-blocked call:\n"
  "    StopServices()/StopUntrackedProcesses() (reboot.cpp:938-949), which kill\n"
  "    zygote/system_server/every app by signaling their own process groups,\n"
  "    already pid/cgroup scoped, well before KillAllProcesses() is ever\n"
  "    reached.",
  "What DOES work before that final, structurally-blocked call:\n"
  "    DoReboot()'s entire teardown sequence (stopping services, unmounting\n"
  "    /data, killing zygote/\n"
  "    system_server) -- real, useful work, already done.")
open(p, "w").write(s)
PYEOF
  check_case "outdated androidd_stop docstring" "androidd_stop: docstring still attributes zygote/system_server teardown to the masked sysrq write"

  write_good
  rm -f "$t/test/system/boot/host-safety.sh"
  check_case "system test missing" "host-safety.sh missing or not executable"

  write_good
  chmod -x "$t/test/system/boot/host-safety.sh"
  check_case "system test not executable" "host-safety.sh missing or not executable"

  write_good
  sed -i '/systemd-udevd/d' "$t/test/system/boot/host-safety.sh"
  check_case "system test missing marker" "host-safety.sh is missing"

  echo "selftest ok: detects all $CASES seeded defects, passes a fixed fixture clean"
  exit 0
fi

if [[ ! -f "$MOUNTS" ]]; then
  bad "$MOUNTS is missing"
  exit 1
fi

body=$(func_body "$MOUNTS" harden_proc_sys; func_body "$MOUNTS" _mask_sysrq_trigger)
if [[ -z "$body" ]]; then
  bad "no harden_proc_sys() function in $MOUNTS"
else
  dst_var=$(grep -oE '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*"/proc/sysrq-trigger"' <<<"$body" \
            | head -1 | sed -E 's/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=.*/\1/')
  dst_pat="/proc/sysrq-trigger"
  [[ -n "$dst_var" ]] && dst_pat="$dst_pat|$dst_var"

  if ! grep -qE "_detach_if_mounted\(\s*(${dst_pat})\s*\)" <<<"$body"; then
    bad "no _detach_if_mounted call for /proc/sysrq-trigger"
  fi

  bind_line=$(grep -E "mount\([^,]+,\s*(${dst_pat})\s*,.*MS_BIND\)" <<<"$body")
  if grep -qE '"/dev/null"' <<<"$bind_line"; then
    bad "bind source is /dev/null"
  fi

  remount_line=$(grep -E "mount\(None\s*,\s*(${dst_pat})\s*,.*MS_RDONLY" <<<"$body")
  if [[ -z "$remount_line" ]] || ! grep -q 'MS_BIND' <<<"$remount_line" \
     || ! grep -q 'MS_REMOUNT' <<<"$remount_line"; then
    bad "no MS_BIND|MS_REMOUNT|MS_RDONLY remount of /proc/sysrq-trigger"
  fi

  if grep -qF "$(flatten 'sysctl/sysrq writes EROFS harmlessly')" <<<"$(flatten "$body")"; then
    bad "harden_proc_sys docstring still claims sysrq is EROFS-masked by the /proc/sys bind"
  fi

  harden_body=$(func_body "$MOUNTS" harden_proc_sys)
  return_line=$(grep -E '^\s*return ' <<<"$harden_body" | tail -1)
  summary_line=$(grep -A2 -F 'proc-sys hardened' <<<"$harden_body")
  return_ids=$(grep -oiE '[a-z_][a-z0-9_]*' <<<"$return_line" | grep -i sysrq)
  shared=0
  for id in $return_ids; do
    grep -qi -- "$id" <<<"$summary_line" && shared=1
  done
  if [[ $shared -eq 0 ]]; then
    bad "return value does not depend on the sysrq bind outcome"
  fi

  if ! grep -qE 'mount\(.*tmp_zram_reset.*sys/block/zram0/reset' "$MOUNTS"; then
    bad "no shadow bound over /sys/block/zram0/reset"
  fi
fi

if [[ ! -f "$LAUNCHER" ]]; then
  bad "$LAUNCHER is missing"
else
  stop_body=$(func_body "$LAUNCHER" androidd_stop)
  if grep -qF "$(flatten 'killing zygote/system_server) -- real, useful work, already done')" <<<"$(flatten "$stop_body")"; then
    bad "androidd_stop: docstring still attributes zygote/system_server teardown to the masked sysrq write"
  fi
fi

if [[ ! -x "$TEST" ]]; then
  bad "host-safety.sh missing or not executable"
else
  for marker in sysrq-trigger dmesg boot_id sshd systemd-networkd systemd-udevd; do
    grep -qF -- "$marker" "$TEST" || bad "host-safety.sh is missing '$marker'"
  done
fi

if (( FAILED )); then
  echo "the sysrq mask is not fenced"
  exit 1
fi
echo "sysrq mask: detach, sink, RO remount, both docstrings and the return-value postcondition are all present; the system test carries its own two-directional markers"
exit 0
