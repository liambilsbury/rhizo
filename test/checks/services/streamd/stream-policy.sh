#!/bin/bash
# test start-stream.sh against stream.enabled
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit

MODE=run
[[ "${1:-}" == "--selftest" ]] && MODE=selftest

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-stream-policy-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

UNREACHABLE_INSTANCE=91

DENY="$WORK/deny.conf"
printf '[stream]\nenabled = no\n' > "$DENY"
SOCK="$WORK/streamd.sock"

SCRIPT="$(pwd)/test/vm/start/start-stream.sh"

DEAD_OFFSET=""
for off in 60000 61000 62000 63000; do
  if ! ss -ltn 2>/dev/null | grep -q ":$((2222 + off)) "; then
    DEAD_OFFSET=$off
    break
  fi
done
[[ -n "$DEAD_OFFSET" ]] || { echo "FAIL: every candidate ssh port has a listener; cannot stage a dead dial" >&2; exit 1; }
export RHIZO_PORT_OFFSET=$DEAD_OFFSET
if [[ "$MODE" == selftest ]]; then
  NOTEST="$WORK/start-stream-notest.sh"
  cp "$SCRIPT" "$NOTEST"
  python3 - "$NOTEST" "$PWD/test/vm/start" <<'PY'
import shlex, sys
path = sys.argv[1]
text = open(path).read()
start = text.index("if (( $? != 0 )); then")
end = text.index("fi\n", start) + 3
if "not starting rhizo-streamd" not in text[start:end]:
    print("FAIL: system test block not found where expected", file=sys.stderr)
    sys.exit(1)
text = text[:start] + text[end:]
selfcd = 'cd "$(dirname "${BASH_SOURCE[0]}")" || exit\n'
if text.count(selfcd) != 1:
    print("FAIL: the copy's self-relative cd is not there exactly once", file=sys.stderr)
    sys.exit(1)
open(path, "w").write(text.replace(selfcd, "cd %s || exit\n" % shlex.quote(sys.argv[2])))
PY
  [[ $? -eq 0 ]] || { echo "FAIL: could not strip the system test for --selftest" >&2; exit 1; }
  chmod +x "$NOTEST"
  SCRIPT="$NOTEST"
fi

rm -f "$SOCK"
out=$(cd test/vm/start && RHIZO_VM="$UNREACHABLE_INSTANCE" RHIZO_POLICY_CONF="$DENY" timeout 25 "$SCRIPT" --socket "$SOCK" 2>&1)
rc=$?
reached_guest=0
grep -q "VM not reachable\|SSH did not come up" <<<"$out" && reached_guest=1
socket_exists=0
[[ -e "$SOCK" ]] && socket_exists=1

if [[ "$MODE" == selftest ]]; then
  if (( reached_guest == 1 )); then
    echo "check-stream-policy --selftest: with the gate removed, a denied policy reaches for the guest anyway, as required"
    exit 0
  fi
  echo "check-stream-policy --selftest: even with the gate removed, denied policy did not reach for the guest" >&2
  echo "$out" >&2
  exit 1
fi

problems=()
(( reached_guest == 1 )) && problems+=("a denied stream.enabled policy still dialed the guest")
(( socket_exists == 1 )) && problems+=("a denied stream.enabled policy still created a socket at $SOCK")
(( rc != 0 )) && problems+=("start-stream.sh exited $rc on a denied policy instead of a clean 0")

if (( ${#problems[@]} )); then
  for p in "${problems[@]}"; do echo "FAIL: $p" >&2; done
  echo "$out" >&2
  exit 1
fi

ALLOW="$WORK/allow.conf"
printf '[stream]\nenabled = yes\n' > "$ALLOW"
out2=$(cd test/vm/start && RHIZO_VM="$UNREACHABLE_INSTANCE" RHIZO_POLICY_CONF="$ALLOW" timeout 25 ./start-stream.sh --socket "$WORK/allow.sock" 2>&1)
if ! grep -q "VM not reachable\|SSH did not come up" <<<"$out2"; then
  echo "FAIL: an allowed policy did not reach for the guest either" >&2
  echo "$out2" >&2
  exit 1
fi

echo "check-stream-policy: stream.enabled=off leaves no socket and no guest contact; stream.enabled=on still reaches for the guest"
