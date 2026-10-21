#!/bin/bash
# test contract.tsv matches system test declarations
set -uo pipefail
shopt -s nullglob

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYS_DIR="${RHIZO_CHECK_SYSTEM:-$HERE/../system}"
CONTRACT="$SYS_DIR/run/contract.tsv"
source "$HERE/../system/run/system-tests.sh"

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  mkdir -p "$t/run"
  trap 'rm -rf "$t"' EXIT

  cat > "$t/fixture.sh" <<'EOF'
#!/bin/bash
# test-boot-mode: shared
# test-boots-unit: yes
# test-records-metrics: no
# test-verdict-params: iterations=20
# test-requires: share:rhizo-fixture.apk
[[ "${1:-}" == --print-contract ]] && {
  printf 'boot_mode=shared\tboots_unit=yes\tnests=-\trecords_metrics=no\tverdict_params=iterations=20\ttest_requires=share:rhizo-fixture.apk\n'
  exit 0
}
EOF
  chmod +x "$t/fixture.sh"
  printf 'fixture.sh\tshared\tyes\t-\tno\titerations=20\tshare:rhizo-fixture.apk\n' > "$t/run/contract.tsv"
  lc="$t/lc/test/system/lifecycle"
  mkdir -p "$lc" "$t/lc/test/system/cycle" "$t/lc/test/system/lib" "$t/lc/test/vm"
  cp "$HERE/../system/cycle/entry.sh" "$t/lc/test/system/cycle/entry.sh" 2>/dev/null \
    || { echo "SELFTEST FAILED: test/system/cycle/entry.sh is missing" >&2; exit 1; }
  : > "$t/lc/test/vm/common.sh"
  printf 'test_print_contract() { sed -n "s/^# test-requires: //p" "$1"; }\n' > "$t/lc/test/system/lib/lib.sh"
  printf '#!/bin/bash\n# test-boot-mode: cold-required\n# test-requires: share:own\nsource "$(dirname "${BASH_SOURCE[0]}")/../cycle/entry.sh"\n' \
    > "$lc/lifecycle-x.sh"
  lc_out=$(cd "$t" && bash lc/test/system/lifecycle/lifecycle-x.sh --print-contract 2>&1)
  if [[ "$lc_out" != "share:own" ]]; then
    echo "SELFTEST FAILED: a thin lifecycle test printed '$lc_out' for its own test-requires, not 'share:own'" >&2
    exit 1
  fi
  rm -rf "$t/lc"

  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if grep -q FAIL <<<"$out"; then
    echo "SELFTEST FAILED (unmutated): a matching declaration was reported anyway" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  printf 'fixture.sh\tshared\tno\t-\tno\titerations=20\tshare:rhizo-fixture.apk\n' > "$t/run/contract.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'declares boots_unit=yes, contract.tsv says boots_unit=no' <<<"$out"; then
    echo "SELFTEST FAILED: a tsv/live mismatch on boots_unit was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  printf 'fixture.sh\tshared\tyes\t-\tno\titerations=99\tshare:rhizo-fixture.apk\n' > "$t/run/contract.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'declares verdict_params=iterations=20, contract.tsv says verdict_params=iterations=99' <<<"$out"; then
    echo "SELFTEST FAILED: a tsv/live mismatch on verdict_params was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  printf 'fixture.sh\tshared\tyes\t-\tno\titerations=20\tnone\n' > "$t/run/contract.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'declares test_requires=share:rhizo-fixture.apk, contract.tsv says test_requires=none' <<<"$out"; then
    echo "SELFTEST FAILED: a tsv/live mismatch on test_requires was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  cat > "$t/undeclared.sh" <<'EOF'
#!/bin/bash
# test-boot-mode: shared
# test-boots-unit: yes
# test-records-metrics: no
[[ "${1:-}" == --print-contract ]] && {
  printf 'boot_mode=shared\tboots_unit=yes\tnests=-\trecords_metrics=no\tverdict_params=-\ttest_requires=none\n'
  exit 0
}
EOF
  chmod +x "$t/undeclared.sh"
  printf 'fixture.sh\tshared\tyes\t-\tno\titerations=20\tshare:rhizo-fixture.apk\nundeclared.sh\tshared\tyes\t-\tno\t-\tundeclared\n' > "$t/run/contract.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'declares test_requires=none, contract.tsv says test_requires=undeclared' <<<"$out"; then
    echo "SELFTEST FAILED: a system test whose default drifted from undeclared to none was not caught" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  rm -f "$t/undeclared.sh"

  : > "$t/run/contract.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'fixture.sh has no row in contract.tsv' <<<"$out"; then
    echo "SELFTEST FAILED: a system test missing from contract.tsv was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  printf 'fixture.sh\tshared\tyes\t-\tno\titerations=20\tshare:rhizo-fixture.apk\nghost.sh\tshared\tyes\t-\tno\t-\t-\n' > "$t/run/contract.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'contract.tsv names ghost.sh, which is not a system test script' <<<"$out"; then
    echo "SELFTEST FAILED: a tsv row naming a nonexistent system test was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  cat > "$t/fixture.sh" <<'EOF'
#!/bin/bash
# test-boot-mode: shared
# test-boots-unit: yes
# test-records-metrics: no
# test-verdict-params: iterations=20
# test-requires: share:rhizo-fixture.apk
[[ "${1:-}" == --print-contract ]] && {
  printf 'boot_mode=shared\tboots_unit=yes\tnests=-\trecords_metrics=no\tverdict_params=iterations=20\n'
  exit 0
}
EOF
  chmod +x "$t/fixture.sh"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'declares test_requires=, contract.tsv says test_requires=share:rhizo-fixture.apk' <<<"$out"; then
    echo "SELFTEST FAILED: a printf that dropped test_requires was not caught" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  echo "selftest ok: detects a tsv/live field mismatch (boots_unit, verdict_params and test_requires), an undeclared default read as none, a printf that drops a field, a system test with no row, and a row naming a system test that does not exist"
  exit 0
fi

FAILED=0
[[ -f "$CONTRACT" ]] || { echo "FAIL: $CONTRACT is missing"; exit 1; }

declare -A ROW
while IFS=$'\t' read -r test bm bu nests rm vp gr; do
  [[ -z "$test" || "$test" == \#* ]] && continue
  ROW["$test"]="boot_mode=$bm	boots_unit=$bu	nests=$nests	records_metrics=$rm	verdict_params=$vp	test_requires=$gr"
done < "$CONTRACT"

declare -A SYS_PATH=()
SYS_MAP=$(system_test_map "$SYS_DIR") && [[ -n "$SYS_MAP" ]] \
  || { echo "FAIL: no system test could be listed under $SYS_DIR"; exit 1; }
while IFS=$'\t' read -r n p; do SYS_PATH[$n]=$p; done <<<"$SYS_MAP"

for test in "${!ROW[@]}"; do
  [[ -n "${SYS_PATH[$test]:-}" ]] \
    || { echo "FAIL: contract.tsv names $test, which is not a system test script"; FAILED=1; }
done

for base in $(printf '%s\n' "${!SYS_PATH[@]}" | sort); do
  f="${SYS_PATH[$base]}"
  if [[ -z "${ROW[$base]:-}" ]]; then
    echo "FAIL: $base has no row in contract.tsv"
    FAILED=1
    continue
  fi
  live=$("$f" --print-contract 2>/dev/null)
  if [[ -z "$live" ]]; then
    echo "FAIL: $base --print-contract produced nothing"
    FAILED=1
    continue
  fi
  want="${ROW[$base]}"
  for field in boot_mode boots_unit nests records_metrics verdict_params test_requires; do
    lv=$(grep -oE "$field=[^	]*" <<<"$live" | cut -d= -f2-)
    wv=$(grep -oE "$field=[^	]*" <<<"$want" | cut -d= -f2-)
    [[ "$lv" == "$wv" ]] \
      || { echo "FAIL: $base declares $field=$lv, contract.tsv says $field=$wv"; FAILED=1; }
  done
done

(( FAILED )) && { echo "contract.tsv is out of date"; exit 1; }
echo "contract.tsv matches every system test's own declaration"
exit 0
