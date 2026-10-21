#!/bin/bash
# test discarding a corrupt trial image
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$HERE/../../src/install/update/gsi-update.sh"
[[ -r "$SRC" ]] || { echo "FAIL: cannot read $SRC"; exit 1; }
command -v mkfs.ext4 >/dev/null 2>&1 || { echo "FAIL: mkfs.ext4 not on PATH, cannot build the fixture"; exit 1; }
command -v e2fsck >/dev/null 2>&1 || { echo "FAIL: e2fsck not on PATH, cannot build the fixture"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# build a 16M ext4 image
build_clean_image() {
  truncate -s 16M "$1"
  mkfs.ext4 -q -F "$1" >/dev/null 2>&1
}

# overwrite the block bitmap bytes in an image
corrupt_block_bitmap() {
  dd if=/dev/urandom of="$1" bs=1 seek=12288 count=64 conv=notrunc status=none
}

# create the sandbox for cmd_begin_boot
setup_sandbox() {
  local d="$1"
  mkdir -p "$d/gsiroot/gsi_system/bin" "$d/gsiroot/gsi_system_a17/bin"
  printf '#!/bin/sh\nexit 0\n' > "$d/gsiroot/gsi_system/bin/init"
  printf '#!/bin/sh\nexit 0\n' > "$d/gsiroot/gsi_system_a17/bin/init"
  chmod +x "$d/gsiroot/gsi_system/bin/init" "$d/gsiroot/gsi_system_a17/bin/init"
  printf '#!/bin/sh\necho "RHIZO_GSI_DERIVED release=$2 dir=x"\n' > "$d/gsi.sh"
  chmod +x "$d/gsi.sh"
  build_clean_image "$d/data.img"
}

# arm an a17 trial image in the sandbox
arm_trial() {
  local script="$1" d="$2" e2fsck="${3:-e2fsck}"
  export RHIZO_STATE_DIR="$d/state"
  export RHIZO_DATA_IMG="$d/data.img"
  export RHIZO_GSI_ROOT="$d/gsiroot"
  export RHIZO_ANDROIDD_ENV="$d/androidd.env"
  export RHIZO_RUNTIME_ENV="$d/runtime.env"
  export RHIZO_E2FSCK="$e2fsck"
  export RHIZO_FETCH_GSI="$d/gsi.sh"
  # shellcheck source=src/install/update/gsi-update.sh
  RHIZO_GSI_UPDATE_SOURCE_ONLY=1 source "$script"
  sandbox_running() { return 1; }
  mkdir -p "$UPDATE_DIR"
  cp --sparse=always "$RHIZO_DATA_IMG" "$TRIAL_IMG"
  state_write "good_release=a16" "trial_release=a17" "trial_tries=3" "trial_started=2026-01-01T00:00:00Z"
}

FAILURES=()
fail_check() { FAILURES+=("$1"); }

# check cmd_begin_boot discards a corrupt trial image
check_corrupt_trial_discarded() {
  local f="$1" d="$WORK/corrupt" rc
  mkdir -p "$d"
  setup_sandbox "$d"
  (
    set -uo pipefail
    arm_trial "$f" "$d"
    corrupt_block_bitmap "$TRIAL_IMG"
    fsck_rc=0
    e2fsck -fn "$TRIAL_IMG" >/dev/null 2>&1 || fsck_rc=$?
    (( fsck_rc & 12 )) || { echo "FIXTURE FAIL: e2fsck -fn reports the trial image clean (rc=$fsck_rc) -- the corruption did not take" >&2; exit 3; }
    cmd_begin_boot > "$WORK/corrupt.out" 2>&1
    {
      echo "trial_release=$(state_get trial_release || echo none)"
      echo "good_release=$(state_get good_release || echo none)"
      echo "data_img=$(sed -n 's/^RHIZO_DATA_IMG=//p' "$RHIZO_RUNTIME_ENV" | tail -1)"
      echo "trial_present=$([[ -e "$TRIAL_IMG" ]] && echo yes || echo no)"
    } > "$WORK/corrupt.state"
  ) 2> "$WORK/corrupt.stderr"
  rc=$?
  if (( rc == 3 )); then
    fail_check "$(cat "$WORK/corrupt.stderr" 2>/dev/null || echo 'fixture setup failed before cmd_begin_boot ran')"
    return
  fi
  local state; state=$(cat "$WORK/corrupt.state")
  grep -q '^trial_release=none$' <<<"$state" \
    || fail_check "cmd_begin_boot armed a trial image e2fsck -fn calls corrupt (still trial_release=a17): $state"
  grep -q '^good_release=a16$' <<<"$state" \
    || fail_check "cmd_begin_boot did not put good_release back to a16 after discarding the corrupt trial: $state"
  grep -q '^data_img=$' <<<"$state" \
    || fail_check "cmd_begin_boot left RHIZO_DATA_IMG pointed at the discarded trial: $state"
  grep -q '^trial_present=no$' <<<"$state" \
    || fail_check "cmd_begin_boot left the corrupt trial-data.img on disk: $state"
  grep -q 'RHIZO_MARKER gsi_update_trial_corrupt=a17-to-a16' "$WORK/corrupt.out" \
    || fail_check "cmd_begin_boot did not log RHIZO_MARKER gsi_update_trial_corrupt=a17-to-a16: $(cat "$WORK/corrupt.out")"
}

# check cmd_begin_boot arms an uncorrupted trial image
check_clean_trial_still_arms() {
  local d="$WORK/clean"
  mkdir -p "$d"
  setup_sandbox "$d"
  (
    arm_trial "$1" "$d"
    cmd_begin_boot
    echo "trial_release=$(state_get trial_release || echo none)"
  ) > "$WORK/clean.out" 2>&1
  grep -q '^trial_release=a17$' "$WORK/clean.out" \
    || fail_check "cmd_begin_boot discarded a genuinely clean trial image: $(cat "$WORK/clean.out")"
}

# check a missing e2fsck arms the trial image
check_missing_e2fsck_degrades_open() {
  local d="$WORK/missing"
  mkdir -p "$d"
  setup_sandbox "$d"
  (
    arm_trial "$1" "$d" "$WORK/no-such-e2fsck"
    cmd_begin_boot
    echo "trial_release=$(state_get trial_release || echo none)"
  ) > "$WORK/missing.out" 2>&1
  grep -q '^trial_release=a17$' "$WORK/missing.out" \
    || fail_check "a missing e2fsck bricked a genuinely clean trial instead of arming it unchecked: $(cat "$WORK/missing.out")"
}

# run the three trial image checks
run_all_checks() {
  FAILURES=()
  check_corrupt_trial_discarded "$1"
  check_clean_trial_still_arms "$1"
  check_missing_e2fsck_degrades_open "$1"
}

if (( ! SELFTEST )); then
  run_all_checks "$SRC"
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}"
    exit 1
  fi
  echo "ok: cmd_begin_boot discards a trial image a real e2fsck -fn calls corrupt (restoring good_release, dropping trial-data.img, marking RHIZO_MARKER gsi_update_trial_corrupt), still arms a genuinely clean trial, and degrades open when e2fsck itself is missing"
  exit 0
fi

# remove the corruption check from cmd_begin_boot
inject_old_shape() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
marker = '''  if trial_image_corrupt "$TRIAL_IMG"; then
    log "$trial's trial image failed a read-only fsck, discarding it and putting $good back"
    discard_trial_artifacts
    state_clear_trial
    launch_release "$good"
    log "RHIZO_MARKER gsi_update_trial_corrupt=$trial-to-$good"
    final_line
    return 0
  fi
'''
if marker not in s:
    sys.exit("SELFTEST SETUP FAIL: the corruption-check block is not present verbatim in cmd_begin_boot")
open(p, "w").write(s.replace(marker, "", 1))
PY
}

copy="$WORK/defect-old-shape.sh"
cp "$SRC" "$copy"
inject_old_shape "$copy" || { echo "SELFTEST SETUP FAIL"; exit 1; }
bash -n "$copy" || { echo "SELFTEST SETUP FAIL: mutated copy is not valid bash"; exit 1; }
run_all_checks "$copy"
if (( ${#FAILURES[@]} == 0 )); then
  echo "SELFTEST FAIL: the checker passed a copy with cmd_begin_boot's pre-fix shape (no fsck check at all)"
  exit 1
fi
echo "selftest ok: detected -- ${FAILURES[0]}"

run_all_checks "$SRC"
if (( ${#FAILURES[@]} > 0 )); then
  printf 'SELFTEST FAIL (clean): the real gsi-update.sh failed its own checker: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "selftest ok (clean): the real gsi-update.sh passes every assertion"
exit 0
