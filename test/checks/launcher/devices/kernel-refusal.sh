#!/bin/bash
# check kernel-check.sh and the launcher's kernel refusal
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRATCH=$(mktemp -d) || exit 1
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/gsi"
printf 'ro.debuggable=0\nro.system.build.fingerprint=check/kernel-check:16/BP1A/1:user/release-keys\n' > "$SCRATCH/gsi/build.prop"

# build the fixture host tree for <case>
fixture() {
  local f="$SCRATCH/$1"
  rm -rf "$f"; mkdir -p "$f"
  case "$1" in stock) return 0 ;; esac
  echo binder,hwbinder,vndbinder > "$f/devices"
  ln -s /dev/null "$f/ashmem"
  : > "$f/config.gz"
  case "$1" in
    no-config)          rm "$f/config.gz" ;;
    ashmem-file)        rm "$f/ashmem"; : > "$f/ashmem" ;;
    devices)            echo binder > "$f/devices" ;;
    devices-unreadable) rm "$f/devices"; mkdir "$f/devices" ;;
  esac
}

# print the fixture environment for <case>
fixture_env() {
  local f="$SCRATCH/$1"
  echo "RHIZO_BINDER_DEVICES_FILE=$f/devices RHIZO_ASHMEM_DEVICE=$f/ashmem RHIZO_PROC_CONFIG=$f/config.gz"
}

# run kernel-check.sh <script> on <case> and print its status
run_check() {
  local rc=0
  # shellcheck disable=SC2046
  env $(fixture_env "$2") sh "$1" 2>"$SCRATCH/$2.err" || rc=$?
  echo "rc=$rc $(tr '\n' ' ' < "$SCRATCH/$2.err")"
}

LAUNCHER_PY='
import contextlib, io, sys
sys.path[:0] = [sys.argv[2], sys.argv[1]]
with contextlib.redirect_stdout(io.StringIO()):
    import boot as launcher
    try:
        result = "returned %r" % launcher.require_rhizo_kernel()
    except SystemExit as e:
        result = "SystemExit %s" % e
print(result)
'

# print require_rhizo_kernel() from <launcher dir> with <core dir> on <case>
run_launcher() {
  local out
  # shellcheck disable=SC2046
  out=$(env $(fixture_env "$3") RHIZO_GSI="$SCRATCH/gsi" python3 -B -c "$LAUNCHER_PY" "$1" "$2" 2>"$SCRATCH/$3.lerr")
  echo "${out##*$'\n'}$(tr '\n' ' ' < "$SCRATCH/$3.lerr")"
}

CALL_SITE_PY='
import ast, sys
fn = next((n for n in ast.walk(ast.parse(open(sys.argv[1]).read()))
           if isinstance(n, ast.FunctionDef) and n.name == "prepare_host_and_data"), None)
text = ast.unparse(fn) if fn else ""
calls = [s for s in (fn.body if fn else []) if isinstance(s, ast.Expr) and ast.unparse(s) == "require_rhizo_kernel()"]
if len(calls) != 1:
    print("prepare_host_and_data calls require_rhizo_kernel() %d times, not once" % len(calls))
for word in ("modprobe", "insmod", "binder_linux"):
    if word in text:
        print("prepare_host_and_data still names %s" % word)
'

# print each fixture case with an unexpected result
problems() {
  local c got want
  local cases=(
    "ok|rc=0 "
    "stock|rc=1 *has no built-in binder, $SCRATCH/stock/ashmem, $SCRATCH/stock/config.gz: boot the Rhizo kernel*"
    "no-config|rc=1 *has no $SCRATCH/no-config/config.gz: boot the Rhizo kernel*"
    "ashmem-file|rc=1 *has no $SCRATCH/ashmem-file/ashmem: boot the Rhizo kernel*"
    "devices|rc=1 *the kernel's built-in binder creates devices 'binder', expected binder,hwbinder,vndbinder*"
    "devices-unreadable|rc=1 *cannot read $SCRATCH/devices-unreadable/devices*"
  )
  for c in "${cases[@]}"; do
    fixture "${c%%|*}"
    got=$(run_check "$1" "${c%%|*}")
    want="${c#*|}"
    # shellcheck disable=SC2053
    [[ "$got" == $want ]] || echo "kernel-check.sh on ${c%%|*}: got '$got', want '$want'"
  done
  cases=(
    "ok|returned None"
    "stock|SystemExit RHIZO_MARKER kernel_refused=no-binder,no-ashmem,no-config.gz"
    "no-config|SystemExit RHIZO_MARKER kernel_refused=no-config.gz"
    "ashmem-file|SystemExit RHIZO_MARKER kernel_refused=no-ashmem"
    "devices|SystemExit RHIZO_MARKER binder_refused=builtin-devices"
    "devices-unreadable|SystemExit RHIZO_MARKER binder_refused=builtin-devices-unreadable"
  )
  for c in "${cases[@]}"; do
    fixture "${c%%|*}"
    got=$(run_launcher "$3" "$2" "${c%%|*}")
    [[ "$got" == "${c#*|}" ]] || echo "require_rhizo_kernel() on ${c%%|*}: got '$got', want '${c#*|}'"
  done
  python3 -B -c "$CALL_SITE_PY" "$3/boot.py" 2>&1
}

# check the tree's scripts and edited copies
selftest() {
  local fails=0 out src="$HERE/../../src/androidd"
  expect() {
    out=$(problems "$3" "$4" "$5")
    if [[ -z "$2" && -z "$out" ]] || [[ -n "$2" && "$out" == *"$2"* ]]; then
      echo "ok   selftest: $1"
    else
      echo "FAIL selftest: $1: got '$out', want '${2:-nothing}'"; fails=1
    fi
  }
  expect "the tree's check, core and launcher" "" "$src/host/kernel-check.sh" "$src" "$src"
  # shellcheck disable=SC2016
  sed '/^\[ -c "\$ASHMEM" \]/d' "$src/host/kernel-check.sh" > "$SCRATCH/no-ashmem.sh"
  expect "a check that never looks for /dev/ashmem" \
    "kernel-check.sh on ashmem-file: got 'rc=0 '" "$SCRATCH/no-ashmem.sh" "$src" "$src"
  mkdir -p "$SCRATCH/core-no-config/sandbox" "$SCRATCH/launcher-no-call"
  sed 's/^    if not os.path.exists(PROC_CONFIG):$/    if False:/' "$src/sandbox/core.py" > "$SCRATCH/core-no-config/sandbox/core.py"
  expect "a core that never looks for /proc/config.gz" \
    "require_rhizo_kernel() on no-config: got 'returned None'" "$src/host/kernel-check.sh" "$SCRATCH/core-no-config" "$src"
  sed 's/^    require_rhizo_kernel()$/    pass/' "$src/boot.py" > "$SCRATCH/launcher-no-call/boot.py"
  expect "a launcher that never calls the kernel check" \
    "prepare_host_and_data calls require_rhizo_kernel() 0 times, not once" "$src/host/kernel-check.sh" "$src" \
    "$SCRATCH/launcher-no-call"
  return "$fails"
}

if [[ "${1:-}" == --selftest ]]; then
  selftest
  exit
fi
out=$(problems "$HERE/../../src/androidd/host/kernel-check.sh" "$HERE/../../src/androidd" "$HERE/../../src/androidd")
if [[ -n "$out" ]]; then
  echo "$out"
  exit 1
fi
echo "check-kernel-refusal: kernel-check.sh, core.kernel_lacks() and require_rhizo_kernel() pass every fixture host"
