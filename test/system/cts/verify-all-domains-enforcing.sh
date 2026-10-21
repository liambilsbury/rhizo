#!/bin/bash
# check for permissive SELinux domains
set -uo pipefail

# print Android's enforce verdict for the guest's mode
enforce_verdict() {
  local mode="${1%$'\r'}" host="${2//[[:space:]]/}" android="${3//[[:space:]]/}"
  case "$mode" in
    host)
      [[ "$host" == 1 ]] || { echo "host mode: the host's /sys/fs/selinux/enforce reads '${host:-<empty>}', expected 1"; return 1; }
      echo "host mode: the host's /sys/fs/selinux/enforce=1 is Android's (what testGlobalEnforcing asserts)" ;;
    namespace)
      [[ "$android" == 1 ]] \
        || { echo "namespace mode: Android's enforce record reads '${android:-<empty>}', expected 1"; return 1; }
      echo "namespace mode: Android's enforce record reads 1 (the host's own node is not Android's)" ;;
    *)
      echo "the guest's SELinux mode record reads '${mode:-<empty>}', neither host nor namespace"; return 1 ;;
  esac
}

if [[ "${1:-}" == --selftest ]]; then
  bad=0
  while IFS='|' read -r mode host android want; do
    if enforce_verdict "$mode" "$host" "$android" >/dev/null; then got=pass; else got=fail; fi
    [[ "$got" == "$want" ]] || { echo "FAIL selftest: mode='$mode' host='$host' android='$android' gave $got, not $want"; bad=1; }
  done <<'CASES'
host|1||pass
host|0||fail
namespace|0|1|pass
namespace||1|pass
namespace|1|0|fail
namespace|1||fail
||1|fail
permissive|1|1|fail
CASES
  (( bad )) && exit 1
  echo "verify-all-domains-enforcing selftest: host mode reads the host node, namespace mode Android's record, an unknown mode fails"
  exit 0
fi

source "$(dirname "${BASH_SOURCE[0]}")/../../vm/common.sh"

# print the usage text and exit
usage() {
  cat >&2 <<'EOF'
usage: verify-all-domains-enforcing.sh [--adb-only | --selftest]

  --adb-only   skip the tradefed invocation, do only the offline
               sepolicy-analyze cross-check on the live policy blob
  --selftest   judge each mode's enforce reading on fixtures, no guest

Requires a booted sandbox with adb already authorized (test/vm/
adb-tunnel.sh up). Honors RHIZO_VM. Exits 0 only if BOTH proofs pass
(or the one proof, with --adb-only).
EOF
  exit 2
}

ADB_ONLY=0
case "${1:-}" in
  --adb-only) ADB_ONLY=1 ;;
  "") ;;
  *) usage ;;
esac

ADB=~/Android/Sdk/platform-tools/adb
EV="$VAR_DIR/scratch/all-domains-enforcing$SUFFIX"
mkdir -p "$EV"
FAILED=0
# log a failure and mark the test failed
fail() { log "FAIL: $*"; FAILED=1; }
# log a passing check
pass() { log "  ok: $*"; }

state=$("$ADB" devices 2>/dev/null | awk -v want="127.0.0.1:$ADB_PORT" '$1==want{print $2}')
if [[ "$state" != "device" ]]; then
  log "FAIL: no authorized adb device at 127.0.0.1:$ADB_PORT (state='${state:-none}')"
  log "      bring one up with test/vm/boot/adb-tunnel.sh up -- this system test does not skip"
  exit 1
fi
pass "adb connected: 127.0.0.1:$ADB_PORT state=device"

mode=$(ssh_vm -t 10 'cat /run/rhizo-selinux-mode')
if [[ "${mode%$'\r'}" == namespace ]]; then
  host_enf="" android_enf=$(ssh_vm -t 10 'cat /run/rhizo-selinuxns/android-enforce')
else
  host_enf=$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce') android_enf=""
fi
if verdict=$(enforce_verdict "$mode" "$host_enf" "$android_enf"); then
  pass "$verdict -- read on the outer VM, not through guest adb shell"
else
  fail "$verdict"
fi

POL="$EV/live-sepolicy.bin"
if "$ADB" -s "127.0.0.1:$ADB_PORT" pull /sys/fs/selinux/policy "$POL" >/dev/null 2>&1 \
   && [[ -s "$POL" ]]; then
  pass "pulled live /sys/fs/selinux/policy ($(stat -c%s "$POL") bytes) -> $POL"
  if bash "$REPO/test/checks/lib/policy-lab.sh" permissive "$POL" > "$EV/permissive-types.txt" 2>&1; then
    pass "sepolicy-analyze permissive: no permissive types in the LIVE policy"
  else
    fail "sepolicy-analyze reported permissive types in the live policy:"
    sed 's/^/    | /' "$EV/permissive-types.txt" >&2
  fi
else
  fail "could not pull /sys/fs/selinux/policy off the device"
fi

if (( ADB_ONLY )); then
  log "--adb-only: skipping the tradefed invocation by request"
else
  CTS_ROOT="$VAR_DIR/suites/android-cts"
  TF="$CTS_ROOT/tools/cts-tradefed"
  if [[ ! -x "$TF" ]]; then
    fail "cts-tradefed not found at $TF"
  else
    stamp=$(date +%s)
    cmd=("$TF" run cts --serial "127.0.0.1:$ADB_PORT" --abi x86_64
         --disable-reboot --skip-preconditions --has-server-side-config false
         -m CtsSecurityHostTestCases
         -t android.security.cts.SELinuxHostTest#testAllDomainsEnforcing)
    printf '%q ' "${cmd[@]}" > "$EV/invocation.txt"; echo >> "$EV/invocation.txt"
    log "=== out-of-plan run: ${cmd[*]}"
    ( cd "$CTS_ROOT" && USE_ATS=false PATH="$VAR_DIR/share:$HOME/Android/Sdk/platform-tools:$PATH" \
        LD_LIBRARY_PATH="$VAR_DIR/share/aapt-libs:${LD_LIBRARY_PATH:-}" \
        "${cmd[@]}" ) > "$EV/tradefed.log" 2>&1
    tf_rc=$?
    log "tradefed exited rc=$tf_rc, log -> $EV/tradefed.log"
    xml=$(find "$CTS_ROOT/results" -name test_result.xml -newermt "@$((stamp-5))" 2>/dev/null \
          | sort | tail -1)
    if [[ -z "$xml" ]]; then
      fail "tradefed produced no test_result.xml newer than this invocation"
    else
      cp "$xml" "$EV/test_result.xml"
      verdict=$(python3 - "$xml" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for tc in root.iter("TestCase"):
    if tc.get("name") != "android.security.cts.SELinuxHostTest":
        continue
    for t in tc.iter("Test"):
        if t.get("name") == "testAllDomainsEnforcing":
            print(t.get("result", "<no result attr>"))
            sys.exit(0)
print("<not present in test_result.xml>")
PYEOF
)
      if [[ "$verdict" == "pass" ]]; then
        pass "testAllDomainsEnforcing: result=pass (out of plan, base cts plan)"
      else
        fail "testAllDomainsEnforcing: result=$verdict"
      fi
    fi
  fi
fi

if (( FAILED )); then
  log "ALL-DOMAINS-ENFORCING VERIFICATION FAILED -- evidence in $EV"
  exit 1
fi
log "ALL-DOMAINS-ENFORCING VERIFICATION PASSED (out-of-plan run + offline cross-check) -- evidence in $EV"
