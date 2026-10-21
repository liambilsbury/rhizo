#!/bin/bash
# test disable-pointer-accel.sh against stubbed releases
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
script=${1:-../system/inject/disable-pointer-accel.sh}
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/system/inject" "$tmp/vm" || exit 1
cp "$script" "$tmp/system/inject/disable-pointer-accel.sh" || exit 1
cat >"$tmp/vm/common.sh" <<'EOF'
log() { echo "LOG $*"; }
guest_init_pid() { echo 4242; }
android_sh() {
  echo "CMD $2" >>"$STUB_CMDS"
  case "$2" in
    "dumpsys input") printf 'Input Manager State:\n  Pointer Speed: 0\n  %s: {}\n' "$STUB_EXEMPT" ;;
    "settings get system mouse_pointer_acceleration_enabled") echo "${STUB_ACCEL:-0}" ;;
  esac
}
EOF
rc=0
# run disable-pointer-accel.sh against the stub
run() {
  : >"$tmp/cmds"
  STUB_EXEMPT="$1" STUB_CMDS="$tmp/cmds" bash "$tmp/system/inject/disable-pointer-accel.sh" >"$tmp/out" 2>&1
  echo $? >"$tmp/rc"
}
# print ok or FAIL for a condition
expect() {
  if eval "$2"; then echo "ok   $1"; else echo "FAIL $1: rc=$(cat "$tmp/rc") out=$(tr '\n' ' ' <"$tmp/out") cmds=$(tr '\n' ' ' <"$tmp/cmds")"; rc=1; fi
}
run "Display with Mouse Scaling Disabled"
expect "A16/A17: the setting is put, read back and reported off" \
  '[[ $(cat "$tmp/rc") == 0 ]] && grep -q "settings put system mouse_pointer_acceleration_enabled 0" "$tmp/cmds" && grep -q "pointer acceleration off" "$tmp/out"'
STUB_ACCEL=1 run "Display with Mouse Scaling Disabled"
expect "A16: a put that does not stick fails" \
  '[[ $(cat "$tmp/rc") != 0 ]] && ! grep -q "pointer acceleration off" "$tmp/out"'
run "Display with Mouse Pointer Acceleration Disabled"
expect "A15: nothing is put and nothing claims acceleration is off" \
  '[[ $(cat "$tmp/rc") == 0 ]] && ! grep -q "settings put" "$tmp/cmds" && grep -q "NOT turned off" "$tmp/out" && ! grep -q "pointer acceleration off" "$tmp/out"'
run "Display with Something Else"
expect "a dump naming neither set fails" '[[ $(cat "$tmp/rc") != 0 ]]'
exit $rc
