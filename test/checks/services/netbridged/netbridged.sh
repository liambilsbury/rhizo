#!/bin/bash
# run the netbridged selftests and comment check
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit

NB=src/services/netbridged
MODE=run
[[ "${1:-}" == "--selftest" ]] && MODE=selftest

FAILED=0
found=0

for t in "$NB"/selftest_*.py; do
  [[ -f "$t" ]] || continue
  found=$((found + 1))
  if [[ "$MODE" == selftest ]]; then
    if ! out=$(cd "$NB" && timeout 120 python3 "$(basename "$t")" --selftest 2>&1); then
      echo "FAIL: $t --selftest did not confirm its assertions can fail" >&2
      sed 's/^/    /' <<<"$out" >&2
      FAILED=1
    fi
  else
    if ! out=$(cd "$NB" && timeout 120 python3 "$(basename "$t")" 2>&1); then
      echo "FAIL: $t" >&2
      sed 's/^/    /' <<<"$out" >&2
      FAILED=1
    fi
  fi
done

if (( found == 0 )); then
  echo "FAIL: no selftest found under $NB" >&2
  FAILED=1
fi

if [[ "$MODE" == run ]]; then
  if ! python3 - "$NB" <<'PY'
import glob, os, sys
nb = sys.argv[1]
bad = []
for path in sorted(glob.glob(os.path.join(nb, "*.py"))):
    indoc = run = 0
    for n, line in enumerate(open(path), 1):
        q = line.count('"""')
        if q:
            indoc = (indoc + q) % 2
            run = 0
            continue
        if indoc:
            run = 0
            continue
        if line.lstrip().startswith("#"):
            run += 1
            if run == 3:
                bad.append(f"{path}:{n}")
        else:
            run = 0
if bad:
    print("FAIL: comment runs of three or more lines:", file=sys.stderr)
    for b in bad:
        print(f"    {b}", file=sys.stderr)
    sys.exit(1)
PY
  then
    FAILED=1
  fi
fi

if (( FAILED )); then
  echo "check-netbridged: the host network daemon is not in a committable state" >&2
  exit 1
fi
if [[ "$MODE" == selftest ]]; then
  echo "check-netbridged: selftest ok -- all $found module selftests confirm their assertions can fail"
else
  echo "check-netbridged: $found module selftest(s) pass, no comment run over two lines"
fi
