#!/bin/bash
# test hostfsd.sh --selftest with a bare name
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="${HOSTFSD_CHECK_OVERRIDE:-$HERE/services/hostfsd/hostfsd.sh}"
fail() { echo "check-hostfsd-selfexec: $*" >&2; exit 1; }

[[ -r "$TARGET" ]] || fail "cannot read $TARGET"

if [[ "${1:-}" != "--selftest" ]]; then
  bash -n "$TARGET" || fail "hostfsd.sh does not parse"
  if grep -qE '"\$0"' "$TARGET"; then
    fail "hostfsd.sh re-execs bare \$0 again"
  fi
  grep -q '^SELF=' "$TARGET" \
    || fail "lost the SELF absolute-path resolution"
  echo "check-hostfsd-selfexec: wiring intact"
  exit 0
fi

out=$(cd "$(dirname "$TARGET")" && bash "$(basename "$TARGET")" --selftest 2>&1)
rc=$?
if (( rc != 0 )); then
  fail "bash $(basename "$TARGET") --selftest failed (rc=$rc): $out"
fi
if grep -qE 'command not found' <<<"$out"; then
  fail "bare-name invocation still hit a command-not-found re-exec: $out"
fi

echo "check-hostfsd-selfexec selftest: bare-name invocation resolves and passes"
