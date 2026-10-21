#!/bin/bash
# check the prepared tree and data release state
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit
REPO="$(cd "../.." && pwd)"
LAUNCHER_DIR="$REPO/src/androidd"

DATA_RELEASE_MARKER_NAME=".rhizo_data_release"
PREPARED_ROOT_REMOTE="/var/lib/rhizo/prepared"
DATA_IMG_REMOTE="/var/lib/rhizo/data.img"
SWITCH_PENDING_REMOTE="/var/lib/rhizo/.rhizo_release_switch_pending"
ANDROIDD_ENV_REMOTE="/root/androidd.env"

# classify the prepared tree probe output
classify_prepared_output() {
  local present="$1" line="$2" key reason
  if [[ "$present" != 1 ]]; then
    echo "none"
    return
  fi
  if [[ "$line" != *"RHIZO_PREPARED_CHECK"* ]]; then
    echo "unknown:no RHIZO_PREPARED_CHECK line back from the probe (sandbox/core.py not staged at /root, or the probe crashed) -- ${line:-empty output}"
    return
  fi
  key=$(sed -n 's/.*key=\([^ ]*\).*/\1/p' <<<"$line")
  reason=$(sed -n 's/.*reason=\([^ ]*\).*/\1/p' <<<"$line")
  if [[ -n "$reason" && "$reason" != "-" ]]; then
    echo "outdated:$reason"
  elif [[ -n "$key" && "$key" != "-" ]]; then
    echo "current:$key"
  else
    echo "unknown:unparseable probe line: $line"
  fi
}

# print the data release state from debugfs output
classify_data_output() {
  local out="$1" err="$2" target="$3" pending="${4:-0}" switching="${5:-0}" content
  if [[ "$pending" == 1 && "$switching" != 1 ]]; then
    echo "discarded:release-switch-pending"
    return
  fi
  content=$(tr -d '\r' <<<"$out" | grep -v '^[[:space:]]*$' | tail -1)
  if [[ -n "$content" ]]; then
    if [[ "$content" == "$target" ]]; then
      echo "ok:$content"
    else
      echo "refused:$content-vs-$target"
    fi
    return
  fi
  if grep -qi "File not found" <<<"$err"; then
    echo "none"
    return
  fi
  if grep -qi "No such file or directory" <<<"$err"; then
    echo "none"
    return
  fi
  if grep -qiE "Filesystem not open|while trying to open" <<<"$err"; then
    echo "unknown:data.img is present but debugfs cannot read it as ext4 (corrupt?)"
    return
  fi
  echo "unknown:empty debugfs output"
}

PREPARED_PY='
import os, sys
sys.path.insert(0, os.environ.get("RHIZO_ENV_DIR", "/root"))
from sandbox import core
override = os.environ.get("RHIZO_PREPARED_ROOT_OVERRIDE")
if override:
    core.PREPARED_ROOT = override
key, reason = core.validate_prepared()
print("RHIZO_PREPARED_CHECK key=%s reason=%s" % (key or "-", reason or "-"))
'

# classify a local fixture prepared tree
check_prepared_local() {
  local root="$1" gsi_dir="$2" present line
  [[ -e "$root/current" ]] && present=1 || present=0
  line=$(RHIZO_GSI="$gsi_dir" RHIZO_ENV_DIR="$LAUNCHER_DIR" RHIZO_PREPARED_ROOT_OVERRIDE="$root" \
         python3 -c "$PREPARED_PY" 2>&1 | tr -d '\r')
  classify_prepared_output "$present" "$line"
}

# classify the prepared tree on the vm
check_prepared_remote() {
  local gsi_dir="$1" present line
  present=$(ssh_vm -t 8 "test -e $PREPARED_ROOT_REMOTE/current && echo 1 || echo 0" 2>/dev/null | tr -d '\r\n')
  line=$(ssh_vm -t 30 "RHIZO_GSI='$gsi_dir' python3 -c '$PREPARED_PY'" 2>&1 | tr -d '\r')
  classify_prepared_output "${present:-0}" "$line"
}

# classify the data release marker of an image
check_data_local() {
  local img="$1" target="$2" out err errfile
  errfile=$(mktemp)
  out=$(debugfs -R "cat /$DATA_RELEASE_MARKER_NAME" "$img" 2>"$errfile")
  err=$(cat "$errfile"); rm -f "$errfile"
  classify_data_output "$out" "$err" "$target" "${3:-0}" "${4:-0}"
}

# classify the data release marker on the vm
check_data_remote() {
  local target="$1" out err errfile pending switching=0 unit_armed
  local ssh_fn="${CLP_SSH_VM:-ssh_vm}"
  errfile=$(mktemp)
  out=$("$ssh_fn" -t 20 "debugfs -R 'cat /$DATA_RELEASE_MARKER_NAME' $DATA_IMG_REMOTE" 2>"$errfile")
  err=$(cat "$errfile"); rm -f "$errfile"
  pending=$("$ssh_fn" -t 8 "test -e $SWITCH_PENDING_REMOTE && echo 1 || echo 0" | tr -d '\r\n')
  [[ "${RHIZO_RELEASE_SWITCH:-0}" == 1 ]] && switching=1
  if [[ "$pending" != 0 && "$pending" != 1 ]]; then
    echo "unknown:could not tell whether $SWITCH_PENDING_REMOTE exists (read '$pending')"
    return
  fi
  unit_armed=$("$ssh_fn" -t 8 "if [ -f $ANDROIDD_ENV_REMOTE ]; then grep -c '^RHIZO_RELEASE_SWITCH=1' $ANDROIDD_ENV_REMOTE; else echo 0; fi" | tr -d '\r\n')
  if [[ ! "$unit_armed" =~ ^[0-9]+$ ]]; then
    echo "unknown:could not read $ANDROIDD_ENV_REMOTE (read '$unit_armed')"
    return
  fi
  if [[ "$pending" == 1 && "$switching" == 0 && "$unit_armed" != 0 ]]; then
    echo "unknown:$ANDROIDD_ENV_REMOTE still arms RHIZO_RELEASE_SWITCH=1"
    return
  fi
  classify_data_output "$out" "$err" "$target" "$pending" "$switching"
}

# create a fixture GSI directory with build.prop
build_gsi_fixture() {
  mkdir -p "$1"
  printf 'ro.system.build.fingerprint=rhizo/test/test:16/TEST/1234567890:user/test-keys\n' > "$1/build.prop"
}

# create a fixture prepared tree with a manifest
build_prepared_fixture() {
  local root="$1" gsi_dir="$2" input_file="$3" key=abc123def456
  rm -rf "$root"
  mkdir -p "$root/$key"
  ln -s "$key" "$root/current"
  RHIZO_ENV_DIR="$LAUNCHER_DIR" RHIZO_GSI="$gsi_dir" INPUT_FILE="$input_file" \
    MANIFEST_PATH="$root/$key/manifest.json" python3 - <<'PYEOF'
import json, os, sys
sys.path.insert(0, os.environ["RHIZO_ENV_DIR"])
from sandbox import core
input_file = os.environ["INPUT_FILE"]
manifest = {
    "layout_version": core.PREPARED_LAYOUT_VERSION,
    "gsi_fingerprint": core.GSI_FINGERPRINT,
    "kernel": os.uname().release,
    "gpu_driver": core.gpu_driver_dir(),
    "inputs": {input_file: core.input_meta(input_file)},
    "outputs": {},
}
json.dump(manifest, open(os.environ["MANIFEST_PATH"], "w"))
PYEOF
}

# print the exit code for the two flags
preparedness_exit_code() {
  if (( $1 )); then echo 1; elif (( $2 )); then echo 3; else echo 0; fi
}

# compare two values and print the result
selftest_assert() {
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1 -> $2"
  else
    echo "  FAIL $1 -> got '$2', want '$3'" >&2
    SELFTEST_BAD=1
  fi
}

# run the offline selftest cases
run_selftest() {
  SELFTEST_BAD=0
  local d; d=$(mktemp -d) || exit 1
  trap 'rm -rf "$d"' RETURN

  local gsi="$d/gsi" root="$d/prepared" input="$d/input.bin"
  build_gsi_fixture "$gsi"
  echo "the input bytes" > "$input"
  build_prepared_fixture "$root" "$gsi" "$input"

  echo "=== prepared-tree: the all-good fixture (before seeding anything) ==="
  local got
  got=$(check_prepared_local "$root" "$gsi")
  echo "  check-vm-preparedness reports: prepared=$got"
  selftest_assert "clean fixture" "$got" "current:abc123def456"

  echo "=== prepared-tree: seeding the ACTUAL vm-2 regression (layout-version) ==="
  python3 - "$root/abc123def456/manifest.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m["layout_version"] = "999"
json.dump(m, open(p, "w"))
PYEOF
  got=$(check_prepared_local "$root" "$gsi")
  echo "  check-vm-preparedness reports: prepared=$got"
  selftest_assert "seeded layout_version=999 (vm-2 shape)" "$got" "outdated:layout-version"

  echo "=== prepared-tree: restoring -- clean again ==="
  build_prepared_fixture "$root" "$gsi" "$input"
  got=$(check_prepared_local "$root" "$gsi")
  echo "  check-vm-preparedness reports: prepared=$got"
  selftest_assert "restored fixture" "$got" "current:abc123def456"

  echo "=== prepared-tree: seeding the ACTUAL vms-1/3/4 regression (input-changed) ==="
  echo "a completely different length of bytes now" > "$input"
  got=$(check_prepared_local "$root" "$gsi")
  echo "  check-vm-preparedness reports: prepared=$got"
  selftest_assert "mutated input (vms-1/3/4 shape)" "$got" "outdated:input-changed:$input"

  echo "=== prepared-tree: no tree ever built on this vm ==="
  rm -rf "$root"
  mkdir -p "$root"
  got=$(check_prepared_local "$root" "$gsi")
  echo "  check-vm-preparedness reports: prepared=$got"
  selftest_assert "never prepared" "$got" "none"

  local img="$d/data.img"

  echo "=== data-release: a new image, nothing recorded yet ==="
  truncate -s 16M "$img"
  mkfs.ext4 -q -F "$img" >/dev/null 2>&1
  got=$(check_data_local "$img" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "new /data" "$got" "none"

  echo "=== data-release: same release recorded -- compatible ==="
  echo -n "a16" > "$d/marker.txt"
  debugfs -w -R "write $d/marker.txt $DATA_RELEASE_MARKER_NAME" "$img" >/dev/null 2>&1
  got=$(check_data_local "$img" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "matching release" "$got" "ok:a16"

  echo "=== data-release: seeding stdout fused with debugfs's own stderr banner ==="
  got=$(classify_data_output "a16" "debugfs 1.47.0 (5-Feb-2023)" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "separated streams, banner after content" "$got" "ok:a16"
  got=$(classify_data_output "a16" "" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "separated streams, no banner at all" "$got" "ok:a16"
  got=$(classify_data_output "a17" "debugfs 1.47.0 (5-Feb-2023)" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "separated streams, a genuine mismatch still refuses" "$got" "refused:a17-vs-a16"

  echo "=== data-release: regression guard ==="
  got=$(classify_data_output "a16debugfs 1.47.0 (5-Feb-2023)" "" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "reverting to a merged 2>&1 read" "$got" "refused:a16debugfs 1.47.0 (5-Feb-2023)-vs-a16"

  echo "=== data-release: a stray stderr line cannot mask a real marker on stdout ==="
  got=$(classify_data_output "a15" "x: No such file or directory" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "stray ENOENT on stderr cannot mask a marker" "$got" "refused:a15-vs-a16"
  got=$(classify_data_output "" "File not found by ext2_lookup" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "empty stdout still reads the stderr keywords" "$got" "none"

  echo "=== data-release: check_data_remote reads its two streams through its own injectable ssh call ==="
  clp_ssh_stub_ok() {
    case "$*" in
      *"debugfs -R"*)
        printf 'a16'
        sleep 0.1
        printf 'debugfs 1.47.0 (5-Feb-2023)\n' >&2
        ;;
      *) echo 0 ;;
    esac
  }
  CLP_SSH_VM=clp_ssh_stub_ok
  got=$(check_data_remote "a16")
  unset CLP_SSH_VM
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "check_data_remote keeps its two streams apart" "$got" "ok:a16"

  clp_ssh_stub_none() {
    case "$*" in
      *"debugfs -R"*) echo "File not found by ext2_lookup" >&2 ;;
      *) echo 0 ;;
    esac
  }
  CLP_SSH_VM=clp_ssh_stub_none
  got=$(check_data_remote "a16")
  unset CLP_SSH_VM
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "check_data_remote still reads a genuine 'no marker yet' (needs err, not a dropped one)" "$got" "none"

  echo "=== data-release: seeding the ACTUAL vm-4 regression (a15-vs-a16) ==="
  truncate -s 16M "$img"
  mkfs.ext4 -q -F "$img" >/dev/null 2>&1
  echo -n "a15" > "$d/marker.txt"
  debugfs -w -R "write $d/marker.txt $DATA_RELEASE_MARKER_NAME" "$img" >/dev/null 2>&1
  got=$(check_data_local "$img" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "seeded a15 marker, booting a16 (vm-4 shape)" "$got" "refused:a15-vs-a16"

  echo "=== data-release: the same a15 marker behind a release-switch pending marker ==="
  got=$(check_data_local "$img" "a16" 1 0)
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "pending switch marker, non-switching boot (vm-3 shape)" "$got" "discarded:release-switch-pending"
  got=$(check_data_local "$img" "a16" 1 1)
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "pending switch marker, switching boot still refused" "$got" "refused:a15-vs-a16"

  echo "=== data-release: restoring -- a16 marker, a16 boot, compatible again ==="
  truncate -s 16M "$img"
  mkfs.ext4 -q -F "$img" >/dev/null 2>&1
  echo -n "a16" > "$d/marker.txt"
  debugfs -w -R "write $d/marker.txt $DATA_RELEASE_MARKER_NAME" "$img" >/dev/null 2>&1
  got=$(check_data_local "$img" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  selftest_assert "restored" "$got" "ok:a16"

  echo "=== data-release: a corrupt image is reported as unknown, never as ok ==="
  : > "$img"
  got=$(check_data_local "$img" "a16")
  echo "  check-vm-preparedness reports: data=$got"
  [[ "$got" == unknown:* ]] \
    && echo "  ok   corrupt image classified as unknown:*" \
    || { echo "  FAIL corrupt image classified as '$got', want unknown:*" >&2; SELFTEST_BAD=1; }

  echo "=== exit-code vocabulary: a refusal and an unreadable answer differ ==="
  selftest_assert "clean -> 0"                  "$(preparedness_exit_code 0 0)" "0"
  selftest_assert "predicts a refusal -> 1"     "$(preparedness_exit_code 1 0)" "1"
  selftest_assert "undeterminable -> 3"         "$(preparedness_exit_code 0 1)" "3"
  selftest_assert "a refusal outranks unknown"  "$(preparedness_exit_code 1 1)" "1"

  if (( SELFTEST_BAD )); then
    echo "check-vm-preparedness --selftest: FAILED" >&2
    return 1
  fi
  echo "check-vm-preparedness --selftest: all assertions passed"
  return 0
}

if [[ "${1:-}" == "--selftest" ]]; then
  run_selftest
  exit $?
fi

source ../vm/common.sh
source ../vm/image/release-map.sh

RELEASE="" QUIET=0 MODE=both DO_REPAIR=0 DO_WIPE_DATA=0 VARIANT=user
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --prepared-only) MODE=prepared; shift ;;
    --data-only) MODE=data; shift ;;
    --repair) DO_REPAIR=1; shift ;;
    --wipe-data) DO_WIPE_DATA=1; shift ;;
    --variant) VARIANT="$2"; shift 2 ;;
    *) echo "vm-preparedness.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [[ -n "$RELEASE" ]] && ! release_known "$RELEASE"; then
  echo "vm-preparedness.sh: '$RELEASE' is not a release release-map.sh declares (known: ${RELEASE_LABELS[*]})" >&2
  exit 2
fi
TARGET_RELEASE="${RELEASE:-${RHIZO_RELEASE:-a16}}"
if [[ -n "$RELEASE" ]]; then
  GSI_DIR_RESOLVED="${GSI_DIR[$RELEASE]}"
else
  GSI_DIR_RESOLVED="${RHIZO_GSI:-/srv/rhizo/gsi_system}"
fi

if (( DO_WIPE_DATA )) && (( ! DO_REPAIR )); then
  echo "vm-preparedness.sh: --wipe-data only means anything together with --repair" >&2
  exit 2
fi

if (( DO_REPAIR )); then
  args=(--release "$TARGET_RELEASE" --variant "$VARIANT")
  (( DO_WIPE_DATA )) && args+=(--wipe-data)
  echo "vm-preparedness.sh: calling prepare-guest.sh ${args[*]} on vm $RHIZO_VM" >&2
  echo "  (this boots the vm through a real setup pass)" >&2
  exec ../vm/image/prepare-guest.sh "${args[@]}"
fi

if ! wait_for_ssh 15 >/dev/null 2>&1; then
  echo "UNREACHABLE vm $RHIZO_VM: no ssh on port $SSH_PORT" >&2
  exit 2
fi

FAILED=0
UNDETERMINED=0

PREPARED_RESULT="-" DATA_RESULT="-"

if [[ "$MODE" != data ]]; then
  PREPARED_RESULT=$(check_prepared_remote "$GSI_DIR_RESOLVED")
  case "$PREPARED_RESULT" in
    current:*)
      (( QUIET )) || echo "  ok   prepared tree: current (${PREPARED_RESULT#current:})" ;;
    none)
      (( QUIET )) || echo "  ok   prepared tree: none built yet on this vm" ;;
    outdated:*)
      echo "  FAIL prepared tree: present but refused for this tree (${PREPARED_RESULT#outdated:})" >&2
      FAILED=1 ;;
    unknown:*)
      echo "  WARN prepared tree: could not be determined (${PREPARED_RESULT#unknown:}) -- reported, not gating" >&2
      UNDETERMINED=1 ;;
  esac
fi

if [[ "$MODE" != prepared ]]; then
  DATA_RESULT=$(check_data_remote "$TARGET_RELEASE")
  case "$DATA_RESULT" in
    ok:*|none)
      (( QUIET )) || echo "  ok   /data release marker: compatible with $TARGET_RELEASE" ;;
    discarded:*)
      (( QUIET )) || echo "  ok   /data release marker: a release switch left $SWITCH_PENDING_REMOTE" ;;
    refused:*)
      echo "  FAIL /data release marker: ${DATA_RESULT#refused:} -- repair with --repair --wipe-data" >&2
      FAILED=1 ;;
    unknown:*)
      echo "  WARN /data release marker: could not be determined (${DATA_RESULT#unknown:}) -- reported, not gating" >&2
      UNDETERMINED=1 ;;
  esac
fi

echo "RHIZO_PREPARED_STATE vm=$RHIZO_VM prepared=$PREPARED_RESULT data=$DATA_RESULT"
exit "$(preparedness_exit_code "$FAILED" "$UNDETERMINED")"
