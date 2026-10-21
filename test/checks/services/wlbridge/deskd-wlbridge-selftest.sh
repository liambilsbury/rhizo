#!/bin/bash
# run rhizo-wlbridge's built-in selftests
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit
WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-deskd-wlbridge-XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if ! ./tools/build/services/wlbridge.sh "$WORK/rhizo-wlbridge" > "$WORK/build.log" 2>&1; then
  echo "check-deskd-wlbridge-selftest: wlbridge.sh failed:"
  cat "$WORK/build.log"
  exit 1
fi

fail=0
out=$("$WORK/rhizo-wlbridge" --selftest-base64 2>&1)
rc=$?
if (( rc != 0 )) || ! grep -q "base64 round trip OK" <<<"$out"; then
  echo "check-deskd-wlbridge-selftest: --selftest-base64 did not pass (rc=$rc):"
  echo "$out"
  fail=1
fi

out=$("$WORK/rhizo-wlbridge" --selftest-buffers 2>&1)
rc=$?
if (( rc != 0 )) || ! grep -q "buffer shrink and grow_buf both OK" <<<"$out"; then
  echo "check-deskd-wlbridge-selftest: --selftest-buffers did not pass (rc=$rc):"
  echo "$out"
  fail=1
fi

(( fail == 0 )) && echo "check-deskd-wlbridge-selftest: base64 round trip and buffer growth/shrink both OK"
exit $fail
