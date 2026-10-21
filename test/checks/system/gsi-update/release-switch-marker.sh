#!/bin/bash
# check the release-switch marker wiring
set -uo pipefail
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${RHIZO_CHECK_ROOT:-$REPO}" || exit

read -r -d '' CORRECT_STUB <<'PY' || true
import os
RELEASE_SWITCH_PENDING_NAME = ".rhizo_release_switch_pending"
def sync_release_switch_marker(data_img, switching, log=print):
    pending = os.path.join(os.path.dirname(data_img) or "/", RELEASE_SWITCH_PENDING_NAME)
    if switching:
        open(pending, "w").close()
        return
    if os.path.exists(pending):
        log(f"RHIZO_MARKER release_switch_pending=found -- discarding {data_img}")
        for path in (data_img, data_img + ".meta", pending):
            try: os.unlink(path)
            except FileNotFoundError: pass
PY

read -r -d '' BROKEN_STUB <<'PY' || true
import os
RELEASE_SWITCH_PENDING_NAME = ".rhizo_release_switch_pending"
def sync_release_switch_marker(data_img, switching, log=print):
    pending = os.path.join(os.path.dirname(data_img) or "/", RELEASE_SWITCH_PENDING_NAME)
    if os.path.exists(pending):
        log(f"RHIZO_MARKER release_switch_pending=found -- discarding {data_img}")
        for path in (data_img, data_img + ".meta", pending):
            try: os.unlink(path)
            except FileNotFoundError: pass
    if switching:
        open(pending, "w").close()
PY

TIER_ANCHOR='_quota_probably_available = _probe_data_tier() == "quota"'

WIRED_LAUNCHER="from sandbox.rootfs import sync_release_switch_marker
def prepare_host_and_data():
    _data_img = '/var/lib/rhizo/data.img'
    sync_release_switch_marker(_data_img, os.environ.get('RHIZO_RELEASE_SWITCH') == '1')
    $TIER_ANCHOR
"
UNWIRED_LAUNCHER="from sandbox.rootfs import sync_release_switch_marker
def prepare_host_and_data():
    _data_img = '/var/lib/rhizo/data.img'
    $TIER_ANCHOR
"
LATE_LAUNCHER="from sandbox.rootfs import sync_release_switch_marker
def prepare_host_and_data():
    _data_img = '/var/lib/rhizo/data.img'
    $TIER_ANCHOR
    sync_release_switch_marker(_data_img, os.environ.get('RHIZO_RELEASE_SWITCH') == '1')
"

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  mkdir -p "$t/src/androidd"
  trap 'rm -rf "$t"' EXIT
  fail_case() {
    RHIZO_CHECK_ROOT="$t" "$SELF" >/tmp/check-release-switch-marker.selftest.out 2>&1
    local got=$?
    if (( got != 1 )); then
      echo "SELFTEST FAILED: $1 -- expected rc=1 (defect found), got rc=$got" >&2
      sed 's/^/  /' /tmp/check-release-switch-marker.selftest.out >&2
      exit 1
    fi
  }

  printf '%s' "$BROKEN_STUB" > "$t/src/androidd/sandbox/rootfs.py"
  printf '%s' "$WIRED_LAUNCHER" > "$t/src/androidd/boot.py"
  fail_case "a reverted function that discards on switching=True too"

  printf '%s' "$CORRECT_STUB" > "$t/src/androidd/sandbox/rootfs.py"
  printf '%s' "$UNWIRED_LAUNCHER" > "$t/src/androidd/boot.py"
  fail_case "boot.py no longer calling the function"

  printf '%s' "$CORRECT_STUB" > "$t/src/androidd/sandbox/rootfs.py"
  printf '%s' "$LATE_LAUNCHER" > "$t/src/androidd/boot.py"
  fail_case "the call moved to after the data tier's own reuse-vs-wipe decision"

  echo "selftest ok: detects an indiscriminate-discard regression, a stripped call site, and a too-late call site"
  exit 0
fi

rc=0

sw_line=$(grep -n 'sync_release_switch_marker(' src/androidd/boot.py 2>/dev/null | head -1 | cut -d: -f1)
tier_line=$(grep -nF "$TIER_ANCHOR" src/androidd/boot.py 2>/dev/null | head -1 | cut -d: -f1)
if [[ -z "$sw_line" ]]; then
  echo "FAIL: boot.py no longer calls sync_release_switch_marker() at all" >&2
  rc=1
elif [[ -z "$tier_line" ]]; then
  echo "FAIL: boot.py's data-tier anchor line moved or was reworded" >&2
  rc=1
elif (( sw_line > tier_line )); then
  echo "FAIL: sync_release_switch_marker() now runs after the data tier's reuse-vs-wipe decision" >&2
  rc=1
fi

py_out=$(python3 - <<'PY'
import os, sys, tempfile
sys.path.insert(0, os.path.join(os.getcwd(), "src", "androidd"))
from sandbox import rootfs as rm

failures = []

def case(name, switching, pre_pending, expect_pending_after, expect_discarded):
    d = tempfile.mkdtemp()
    data_img = os.path.join(d, "data.img")
    meta = data_img + ".meta"
    open(data_img, "w").write("x")
    open(meta, "w").write("y")
    pending = os.path.join(d, rm.RELEASE_SWITCH_PENDING_NAME)
    if pre_pending:
        open(pending, "w").close()
    logs = []
    rm.sync_release_switch_marker(data_img, switching, log=logs.append)
    joined = "\n".join(logs)
    pending_after = os.path.exists(pending)
    data_after, meta_after = os.path.exists(data_img), os.path.exists(meta)
    if pending_after != expect_pending_after:
        failures.append(f"{name}: expected pending present={expect_pending_after}, got {pending_after}")
    if expect_discarded:
        if data_after or meta_after:
            failures.append(f"{name}: expected data_img+.meta discarded, got data={data_after} meta={meta_after}")
        if "RHIZO_MARKER release_switch_pending=found" not in joined:
            failures.append(f"{name}: discarded but logged no RHIZO_MARKER release_switch_pending=found -- {joined!r}")
    elif not (data_after and meta_after):
        failures.append(f"{name}: data_img/.meta should be untouched, got data={data_after} meta={meta_after}")

case("first switching leg", True, False, True, False)
case("later switching leg, already armed", True, True, True, False)
case("ordinary boot, nothing pending", False, False, False, False)
case("ordinary boot, leftover pending", False, True, False, True)

if failures:
    print("FAIL: sync_release_switch_marker does not behave as the fix promises:")
    for f in failures:
        print(" ", f)
    sys.exit(1)
print("ok: all four release-switch marker scenarios behave as the fix promises")
PY
)
py_rc=$?
echo "$py_out"
(( py_rc != 0 )) && rc=1

gvs=test/system/install/version-swap.sh
if [[ -f "$gvs" ]]; then
  wipes=$(grep -c 'RHIZO_WIPE_DATA=1' "$gvs")
  switches=$(grep -c 'RHIZO_RELEASE_SWITCH=1' "$gvs")
  if (( switches < wipes )); then
    echo "FAIL: $gvs has $wipes RHIZO_WIPE_DATA=1 redeploy.sh call(s) but only $switches RHIZO_RELEASE_SWITCH=1" >&2
    rc=1
  fi
fi

ggu=test/system/install/gsi-update.sh
gsc=test/system/lib/gsi-update-cleanup.sh
if [[ -f "$ggu" ]]; then
  if ! grep -q 'RHIZO_RELEASE_SWITCH=1' "$ggu"; then
    echo "FAIL: $ggu no longer arms RHIZO_RELEASE_SWITCH=1 on its baseline boot" >&2
    rc=1
  fi
  if [[ -f "$gsc" ]] && ! grep -qE '(^|[^.])\bsource[[:space:]]+\.\./lib/gsi-update-cleanup\.sh\b' "$ggu"; then
    echo "FAIL: $ggu no longer sources $gsc" >&2
    rc=1
  fi
fi
if [[ -f "$gsc" ]]; then
  if ! grep -qE 'rm[[:space:]]+-f[^#]*rhizo_release_switch_pending' "$gsc"; then
    echo "FAIL: $gsc's cleanup no longer drops the release-switch pending file" >&2
    rc=1
  fi
elif [[ -f "$ggu" ]] && ! grep -qE 'rm[[:space:]]+-f[^#]*rhizo_release_switch_pending' "$ggu"; then
  echo "FAIL: neither $ggu nor $gsc drops the release-switch pending file" >&2
  rc=1
fi

(( rc == 0 )) && echo "the release-switch marker repair is wired into boot.py and both release-switching system tests arm it"
exit $rc
