#!/bin/bash
# print how to run a `# test-boot-mode:` script
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
# shellcheck source=system-tests.sh
source ./system-tests.sh

# print the boot mode and flags
show() {
  local g="$1" f
  f=$(system_test_path "$g") || { echo "no such test: $g" >&2; return 1; }
  echo "=== $g"
  echo "  boot mode: $(sed -n 's/^# test-boot-mode: \(.*\)/\1/p' "$f" | head -1)"
  local flags
  flags=$(grep -oE '^[[:space:]]*--[a-z-]+\)' "$f" | tr -d ' )' | sort -u | tr '\n' ' ')
  echo "  flags: ${flags:-<none>}"
  echo "  release aware: $(grep -q RHIZO_RELEASE "$f" && echo yes || echo 'no -- always runs the default release')"
  echo "  records benchmark rows: $(grep -qE 'bench-common\.sh|bench_record' "$f" && echo yes || echo no)"
  sed -n 's/^# *\(RHIZO_[A-Z_]*=.*\)/  env: \1/p' "$f" | head -4
}

if [[ -n "${1:-}" ]]; then
  g="${1##*/}"; [[ "$g" == *.sh ]] || g="$g.sh"
  system_test_path "$g" >/dev/null 2>&1 || { echo "usage.sh: $g is not a system test (no file of that name under test/system has a '# test-boot-mode:' header)" >&2; exit 2; }
  show "$g"
  exit $?
fi

names=$(system_tests) || { echo "usage.sh: could not list the system tests" >&2; exit 2; }
for g in $names; do show "$g"; echo; done
