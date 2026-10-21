#!/bin/bash
# test the data release marker check
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${RHIZO_CHECK_ROOT:-$REPO}" || exit

read -r -d '' CORRECT_STUB <<'PY' || true
import os
DATA_RELEASE_MARKER_NAME = ".rhizo_data_release"
def check_data_release_marker(mount_point, release, wipe_requested, change_requested=False, log=print):
    marker = os.path.join(mount_point, DATA_RELEASE_MARKER_NAME)
    try:
        prev = open(marker).read().strip()
    except FileNotFoundError:
        prev = ""
    except PermissionError:
        log(f"RHIZO_MARKER data_release=unverifiable release={release}")
        return True
    except OSError:
        prev = ""
    if prev and prev != release and not wipe_requested:
        vm = os.environ.get("RHIZO_VM", "?")
        log(f"/data was last booted with release {prev}; refusing to boot release "
            f"{release} onto it on vm {vm} without RHIZO_WIPE_DATA=1")
        log(f"RHIZO_MARKER data_release_refused={prev}-vs-{release}")
        return False
    try:
        with open(marker, "w") as f:
            f.write(release)
    except OSError:
        pass
    log(f"RHIZO_MARKER data_release={release}")
    return True
PY

read -r -d '' FAIL_OPEN_STUB <<'PY' || true
import os
DATA_RELEASE_MARKER_NAME = ".rhizo_data_release"
def check_data_release_marker(mount_point, release, wipe_requested, change_requested=False, log=print):
    marker = os.path.join(mount_point, DATA_RELEASE_MARKER_NAME)
    try:
        prev = open(marker).read().strip()
    except OSError:
        prev = ""
    if prev and prev != release and not wipe_requested and not change_requested:
        log(f"refusing {release} onto {prev} without RHIZO_WIPE_DATA=1")
        log(f"RHIZO_MARKER data_release_refused={prev}-vs-{release}")
        return False
    if change_requested and prev and prev != release:
        log(f"RHIZO_MARKER data_release_changed={prev}-to-{release}")
    try:
        with open(marker, "w") as f:
            f.write(release)
    except OSError:
        pass
    log(f"RHIZO_MARKER data_release={release}")
    return True
PY

read -r -d '' BROKEN_STUB <<'PY' || true
import os
DATA_RELEASE_MARKER_NAME = ".rhizo_data_release"
def check_data_release_marker(mount_point, release, wipe_requested, change_requested=False, log=print):
    marker = os.path.join(mount_point, DATA_RELEASE_MARKER_NAME)
    try:
        with open(marker, "w") as f:
            f.write(release)
    except OSError:
        pass
    log(f"RHIZO_MARKER data_release={release}")
    return True
PY

WIRED_LAUNCHER='from sandbox.rootfs import check_data_release_marker
def prepare_host_and_data():
    if not check_data_release_marker("/run/rhizo/data", RHIZO_RELEASE, not RHIZO_PERSIST_DATA):
        os._exit(1)
'
UNWIRED_LAUNCHER='from sandbox.rootfs import check_data_release_marker
def prepare_host_and_data():
    pass
'

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' EXIT
  fail_case() {
    RHIZO_CHECK_ROOT="$t" "$SELF" >/tmp/check-data-release-marker.selftest.out 2>&1
    local got=$?
    if (( got != 1 )); then
      echo "SELFTEST FAILED: $1 -- expected rc=1 (defect found), got rc=$got" >&2
      sed 's/^/  /' /tmp/check-data-release-marker.selftest.out >&2
      exit 1
    fi
  }

  mkdir -p "$t/src/androidd"
  printf '%s' "$BROKEN_STUB" > "$t/src/androidd/sandbox/rootfs.py"
  printf '%s' "$WIRED_LAUNCHER" > "$t/src/androidd/boot.py"
  fail_case "a reverted guard that never refuses a cross-release boot"

  printf '%s' "$CORRECT_STUB" > "$t/src/androidd/sandbox/rootfs.py"
  printf '%s' "$UNWIRED_LAUNCHER" > "$t/src/androidd/boot.py"
  fail_case "boot.py no longer calling the guard (or not refusing on it)"

  printf '%s' "$FAIL_OPEN_STUB" > "$t/src/androidd/sandbox/rootfs.py"
  printf '%s' "$WIRED_LAUNCHER" > "$t/src/androidd/boot.py"
  fail_case "an unreadable marker taken as absent"

  echo "selftest ok: detects a reverted guard, a stripped-out call site, and an unreadable marker taken as absent"
  exit 0
fi

rc=0

if ! grep -q 'check_data_release_marker' src/androidd/boot.py 2>/dev/null; then
  echo "FAIL: boot.py no longer references check_data_release_marker() at all" >&2
  rc=1
elif ! grep -A2 -F 'check_data_release_marker(' src/androidd/boot.py | grep -q 'os\._exit(1)'; then
  echo "FAIL: boot.py calls check_data_release_marker() but no longer stops the boot (os._exit(1)) when it returns False" >&2
  rc=1
fi

PYRUN=(python3)
(( EUID == 0 )) && PYRUN=(setpriv --bounding-set "-dac_override,-dac_read_search" python3)
py_out=$("${PYRUN[@]}" - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.path.join(os.getcwd(), "src", "androidd"))
from sandbox import rootfs as rm

failures = []

def case(name, prev, release, wipe, expect_ok, expect_marker_after, change=False):
    d = tempfile.mkdtemp()
    if prev is not None:
        open(os.path.join(d, rm.DATA_RELEASE_MARKER_NAME), "w").write(prev)
    logs = []
    ok = rm.check_data_release_marker(d, release, wipe, change, log=logs.append)
    try:
        after = open(os.path.join(d, rm.DATA_RELEASE_MARKER_NAME)).read().strip()
    except FileNotFoundError:
        after = None
    if ok != expect_ok:
        failures.append(f"{name}: expected ok={expect_ok}, got {ok}")
    if after != expect_marker_after:
        failures.append(f"{name}: expected marker={expect_marker_after!r} on disk after, got {after!r}")
    joined = "\n".join(logs)
    if not expect_ok:
        if release not in joined or (prev or "") not in joined:
            failures.append(f"{name}: refusal message does not name both releases -- {joined!r}")
        if "RHIZO_MARKER data_release_refused=" not in joined:
            failures.append(f"{name}: no machine-parseable refusal marker -- {joined!r}")
    else:
        if f"RHIZO_MARKER data_release={release}" not in joined:
            failures.append(f"{name}: missing 'RHIZO_MARKER data_release={release}' line -- {joined!r}")
        if "RHIZO_MARKER data_release_refused=" in joined:
            failures.append(f"{name}: accepted the boot but still printed a refusal marker -- {joined!r}")
        changed = f"RHIZO_MARKER data_release_changed={prev}-to-{release}"
        if change and prev and prev != release and changed not in joined:
            failures.append(f"{name}: a declared release change is not named in the log -- {joined!r}")
        if not change and "data_release_changed=" in joined:
            failures.append(f"{name}: named a declared change nobody declared -- {joined!r}")

case("cross-release, no wipe", "a17", "a16", False, False, "a17")
case("cross-release, with wipe", "a17", "a16", True, True, "a16")
case("missing marker", None, "a16", False, True, "a16")
case("same release", "a16", "a16", False, True, "a16")
case("declared release change", "a16", "a17", False, True, "a17", True)
case("declared change, same release", "a16", "a16", False, True, "a16", True)

def unreadable_case(name, prev, release):
    d = tempfile.mkdtemp()
    marker = os.path.join(d, rm.DATA_RELEASE_MARKER_NAME)
    open(marker, "w").write(prev)
    os.chmod(marker, 0)
    try:
        open(marker).close()
        os.chmod(marker, 0o644)
        failures.append(f"{name}: fixture: the marker stayed readable at mode 0 -- this process holds DAC override")
        return
    except PermissionError:
        pass
    logs = []
    try:
        ok = rm.check_data_release_marker(d, release, False, False, log=logs.append)
    finally:
        os.chmod(marker, 0o644)
    joined = "\n".join(logs)
    if ok is not True:
        failures.append(f"{name}: expected the launch to proceed, got {ok}")
    if open(marker).read().strip() != prev:
        failures.append(f"{name}: the marker was rewritten")
    if "RHIZO_MARKER data_release=unverifiable" not in joined:
        failures.append(f"{name}: no 'RHIZO_MARKER data_release=unverifiable' line -- {joined!r}")
    if f"RHIZO_MARKER data_release={release}" in joined:
        failures.append(f"{name}: printed data_release={release} without having read the marker -- {joined!r}")

unreadable_case("unreadable marker, same release", "a16", "a16")
unreadable_case("unreadable marker, other release", "a17", "a16")

if failures:
    print("FAIL: the /data cross-release guard does not behave as the fix promises:")
    for f in failures:
        print(" ", f)
    sys.exit(1)
print("ok: all eight /data cross-release scenarios behave as the fix promises")
PY
)
py_rc=$?
echo "$py_out"
(( py_rc != 0 )) && rc=1

(( rc == 0 )) && echo "the /data cross-release guard is wired into boot.py and behaves correctly"
exit $rc
