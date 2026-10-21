#!/bin/bash
# test check_stage_dirs on complete and incomplete trees
set -uo pipefail
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# print a failure message to stderr and exit 1
fail() { echo "check-stage-dirs: $*" >&2; exit 1; }

if [[ "${1:-}" != "--selftest" ]]; then
  grep -q '^check_stage_dirs()' "$TOOLS_DIR/../vm/common.sh" \
    || fail "common.sh lost check_stage_dirs()"
  grep -q '^STAGE_DIR_NAMES=' "$TOOLS_DIR/../vm/common.sh" \
    || fail "common.sh lost STAGE_DIR_NAMES"
  grep -q 'check_stage_dirs "\$SHARE_DIR"' "$TOOLS_DIR/../vm/redeploy.sh" \
    || fail "redeploy.sh no longer checks STAGE_DIR_NAMES before staging"
  grep -q 'STAGE_DIRS="'"'"'"\$STAGE_DIR_NAMES"' "$TOOLS_DIR/../vm/redeploy.sh" \
    || fail "redeploy.sh's stage_cmd no longer builds STAGE_DIRS from the shared list"
  exit 0
fi

source "$TOOLS_DIR/../vm/common.sh"

# name the driver directories STAGE_DIR_NAMES lacks
missing_launcher_dirs() {
  local d
  for d in $(sed -n '/^def gpu_driver_dir():/,/^def /p' "$1" | grep -o '"gpu_driver[a-z0-9_]*"' | tr -d '"' | sort -u); do
    [[ " $STAGE_DIR_NAMES " == *" $d "* ]] || echo "$d"
  done
}

T=$(mktemp -d) || fail "mktemp failed"
trap 'rm -rf "$T"' EXIT

for d in $STAGE_DIR_NAMES; do mkdir -p "$T/$d"; done
check_stage_dirs "$T" 2>/dev/null \
  || fail "selftest 1: a complete tree was refused"

rm -rf "$T/gpu_driver_zink"
out=$(check_stage_dirs "$T" 2>&1) \
  && fail "selftest 2: a tree missing gpu_driver_zink was NOT refused"
[[ "$out" == *gpu_driver_zink* ]] \
  || fail "selftest 2: refusal message did not name the missing dir: $out"

launcher_env="$TOOLS_DIR/../../src/androidd/sandbox/core.py"
grep -q '"gpu_driver_software"' "$launcher_env" \
  || fail "selftest 3: sandbox/core.py's gpu_driver_dir() no longer names gpu_driver_software"
out=$(missing_launcher_dirs "$launcher_env")
[[ -z "$out" ]] \
  || fail "selftest 3: gpu_driver_dir() can pick $out, which STAGE_DIR_NAMES does not stage into the guest"
mkdir -p "$T/sandbox"
printf 'def gpu_driver_dir():\n    return "gpu_driver_new" if x else "gpu_driver"\n\n\ndef other():\n    return "gpu_driver_other"\n' > "$T/sandbox/core.py"
out=$(missing_launcher_dirs "$T/sandbox/core.py")
[[ "$out" == gpu_driver_new ]] \
  || fail "selftest 4: a gpu_driver_dir() naming an unstaged gpu_driver_new was reported as '$out'"

echo "check-stage-dirs: ok"
