#!/bin/bash
# run build, boot or test for a release
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")" || exit
# print the usage text
usage() {
  cat <<'EOF'
Usage: test/vm/boot/rhizoctl.sh <verb> <a15|a16> [extra args...]
  build     everything that release needs before it can boot
  boot      build, then boot it and wait for sys.boot_completed
  test      boot, then run each system test that reads RHIZO_RELEASE
  check     build + boot + test, in that order, stopping at the
            first failure

Needs RHIZO_VM, the vm to act on.
EOF
}

case "${1:-}" in ""|-h|--help) usage; exit 0 ;; esac

: "${RHIZO_VM:?rhizoctl.sh needs RHIZO_VM, the vm to act on}"
source ../common.sh
source ../image/release-map.sh

VERB="${1:-}"; REL="${2:-}"; shift 2 2>/dev/null || true

case "$VERB" in
  build|boot|test|check) ;;
  "") usage >&2; exit 2 ;;
  *) echo "rhizoctl.sh: unknown verb '$VERB'" >&2; usage >&2; exit 2 ;;
esac

if ! grep -q "^\s*\[$REL\]=" ../image/release-map.sh; then
  echo "rhizoctl.sh: '$REL' is not a release release-map.sh declares" >&2
  exit 2
fi

# print a line prefixed with the script name
say() { echo "[rhizoctl.sh] $*"; }

do_build()  { say "build $REL (release.sh)"; ../../../tools/build/release.sh "$REL" --build; }
do_boot()   { say "boot $REL (boot-release.sh)";   ../boot-release.sh "$REL" "$@"; }
# run the release's system tests
do_test() {
  local g f rc=0
  say "test $REL (each system test that reads RHIZO_RELEASE)"
  for g in $(python3 ../../system/run/system_tests.py); do
    f=$(python3 ../../system/run/system_tests.py --path "$g") || return 1
    grep -q RHIZO_RELEASE "$f" || continue
    say "  $g"
    RHIZO_RELEASE="$REL" "$f" "$@" || rc=1
  done
  return "$rc"
}

case "$VERB" in
  build)   do_build ;;
  boot)    do_build && do_boot "$@" ;;
  test)    do_build && do_boot && do_test "$@" ;;
  check)   do_build && do_boot && do_test ;;
esac
