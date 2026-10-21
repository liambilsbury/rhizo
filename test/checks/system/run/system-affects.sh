#!/bin/bash
# check affects.tsv against the tree
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SYS_DIR="${RHIZO_CHECK_SYSTEM:-$REPO/test/system}"
AFFECTS="$SYS_DIR/run/affects.tsv"

# print the system tests for a path
tests_for_path_sh() {
  local path="$1" best="" best_len=0 prefix tests
  while IFS=$'\t' read -r prefix tests; do
    [[ -z "$prefix" || "$prefix" == \#* ]] && continue
    if [[ "$path" == "$prefix"* ]] && (( ${#prefix} > best_len )); then
      best="$tests"; best_len=${#prefix}
    fi
  done < "$AFFECTS"
  if [[ -z "$best" ]]; then
    if [[ "$path" != */* || "$path" == .* ]]; then best=NONE; else best=ALL; fi
  fi
  echo "$best"
}

if [[ "${1:-}" == "--selftest" ]]; then
  t=$(mktemp -d) || exit 1
  t2=$(mktemp -d) || exit 1
  mkdir -p "$t/run" "$t2/run"
  trap 'rm -rf "$t" "$t2"' EXIT
  printf 'test/system/helper-x.sh\tNONE\n' > "$t/run/affects.tsv"
  printf '#!/bin/bash\n# test-boot-mode: shared\ntest_init x\n./helper-x.sh\n' > "$t/fixture.sh"
  printf '#!/bin/bash\n:\n' > "$t/helper-x.sh"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'fixture.sh uses helper-x.sh' <<<"$out"; then
    echo "SELFTEST FAILED: a system test using a NONE-routed helper was not reported" >&2
    echo "  the check produced:" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  want_case() {
    printf '%s' "$2" > "$t/fixture.sh"
    local o; o=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
    if ! grep -qF "$3" <<<"$o"; then
      echo "SELFTEST FAILED ($1): expected '$3'" >&2
      sed 's/^/    /' <<<"$o" >&2
      exit 1
    fi
  }
  want_case "no test_init" \
    '#!/bin/bash
# test-boot-mode: shared
./helper-x.sh
test_record_verdict PASSED
' "fixture.sh never calls test_init"
  want_case "no verdict" \
    '#!/bin/bash
# test-boot-mode: shared
test_init fixture
./helper-x.sh
echo PASSED
' "fixture.sh never records a verdict"
  want_case "verdict only in a comment" \
    '#!/bin/bash
# test-boot-mode: shared
test_init fixture
./helper-x.sh
# test_record_verdict PASSED
' "fixture.sh never records a verdict"

  printf 'src/\tfixture.sh\nREADME.md\tfixture.sh\n' > "$t/run/affects.tsv"
  for pair in TODO.md:NONE NOTES.txt:NONE .hidden/x/y:NONE README.md:fixture.sh src/a/b:fixture.sh test/unlisted/x:ALL docs/x.md:ALL; do
    got=$(AFFECTS="$t/run/affects.tsv" tests_for_path_sh "${pair%%:*}")
    [[ "$got" == "${pair#*:}" ]] || { echo "SELFTEST FAILED: ${pair%%:*} routed to $got, not ${pair#*:}" >&2; exit 1; }
  done
  printf 'test/system/helper-x.sh\tNONE\n' > "$t/run/affects.tsv"

  printf '%s' '#!/bin/bash
# test-boot-mode: shared
test_init fixture
./helper-x.sh
test_record_verdict PASSED
' > "$t/fixture.sh"
  printf "test/system/helper-x.sh\tfixture.sh\n" > "$t/run/affects.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if grep -q 'fixture.sh never' <<<"$out"; then
    echo "SELFTEST FAILED (unmutated): a complete system test was reported anyway" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  printf 'test/system/orphan.sh\torphan.sh\n' > "$t2/run/affects.tsv"
  printf '#!/bin/bash\n# test-boot-mode: shared\ntest_init orphan\n' > "$t2/orphan.sh"
  out=$(RHIZO_CHECK_SYSTEM="$t2" "$SELF" 2>&1)
  if ! grep -q 'orphan.sh never records a verdict' <<<"$out"; then
    echo "SELFTEST FAILED: a lone system test with no verdict was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  printf '%s' '#!/bin/bash
# test-boot-mode: shared
test_init fixture
|| fail "helper-x.sh owns this contract"
log "see helper-x.sh for why"
test_record_verdict PASSED
' > "$t/fixture.sh"
  printf "test/system/helper-x.sh\tNONE\n" > "$t/run/affects.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if grep -q 'fixture.sh uses helper-x.sh' <<<"$out"; then
    echo "SELFTEST FAILED: a helper named only in a reporting message was read as a use" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  printf '%s' '#!/bin/bash
# test-boot-mode: shared
test_init fixture
./helper-x.sh || fail "helper-x.sh broke"
test_record_verdict PASSED
' > "$t/fixture.sh"
  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'fixture.sh uses helper-x.sh' <<<"$out"; then
    echo "SELFTEST FAILED: a helper run on a line that also reports was missed" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  out=$(RHIZO_CHECK_SYSTEM="$t" "$SELF" 2>&1)
  if ! grep -q 'fixture.sh has no affects.tsv row of its own' <<<"$out"; then
    echo "SELFTEST FAILED: a system test with no row of its own was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  t3=$(mktemp -d) || exit 1
  mkdir -p "$t3/run"
  trap 'rm -rf "$t" "$t2" "$t3"' EXIT
  {
    printf 'test/system/a.sh\ta.sh\n'
    printf 'test/system/b.sh\tb.sh,a.sh\n'
    printf 'test/system/c.sh\tc.sh,b.sh\n'
  } > "$t3/run/affects.tsv"
  for g in a b c; do
    printf '#!/bin/bash\n# test-boot-mode: shared\ntest_init %s\ntest_record_verdict PASSED\n' \
      "$g" > "$t3/$g.sh"
  done
  printf './b.sh\n' >> "$t3/a.sh"
  printf './c.sh\n' >> "$t3/b.sh"
  out=$(RHIZO_CHECK_SYSTEM="$t3" "$SELF" 2>&1)
  if ! grep -q 'routes c.sh to c.sh,b.sh, which omits a.sh' <<<"$out"; then
    echo "SELFTEST FAILED: a row missing its TRANSITIVE consumer was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  printf 'test/system/c.sh\tc.sh,b.sh,a.sh\n' > "$t3/test-affects.tsv.new"
  grep -v '^test/system/c.sh' "$t3/run/affects.tsv" > "$t3/rest"
  cat "$t3/rest" "$t3/test-affects.tsv.new" > "$t3/run/affects.tsv"
  rm -f "$t3/test-affects.tsv.new" "$t3/rest"
  out=$(RHIZO_CHECK_SYSTEM="$t3" "$SELF" 2>&1)
  if grep -q 'which omits a.sh' <<<"$out"; then
    echo "SELFTEST FAILED: a complete transitive row was reported anyway" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  printf 'test/system/input-c.txt\tc.sh,b.sh\n' >> "$t3/run/affects.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t3" "$SELF" 2>&1)
  if ! grep -q 'routes test/system/input-c.txt to c.sh,b.sh, which omits a.sh' <<<"$out"; then
    echo "SELFTEST FAILED: an input row missing a system test that runs one of its system tests was not reported" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi
  grep -v '^test/system/input-c.txt' "$t3/run/affects.tsv" > "$t3/rest"
  printf 'test/system/input-c.txt\tc.sh,b.sh,a.sh\n' >> "$t3/rest"
  mv "$t3/rest" "$t3/run/affects.tsv"
  out=$(RHIZO_CHECK_SYSTEM="$t3" "$SELF" 2>&1)
  if grep -q 'routes test/system/input-c.txt' <<<"$out"; then
    echo "SELFTEST FAILED: an input row naming every runner of its system tests was reported anyway" >&2
    sed 's/^/    /' <<<"$out" >&2
    exit 1
  fi

  t4=$(mktemp -d) || exit 1
  mkdir -p "$t4/run"
  trap 'rm -rf "$t" "$t2" "$t3" "$t4"' EXIT
  {
    printf 'test/system/a.sh\ta.sh\n'
    printf 'test/system/b.sh\tb.sh\n'
    printf 'test/system/helper-y.sh\tNONE\n'
  } > "$t4/run/affects.tsv"
  printf '#!/bin/bash\n# test-boot-mode: shared\ntest_init b\ntest_record_verdict PASSED\n' > "$t4/b.sh"
  printf '#!/bin/bash\n:\n' > "$t4/helper-y.sh"
  {
    printf '#!/bin/bash\n# test-boot-mode: shared\ntest_init a\n./b.sh\n./helper-y.sh\n'
    yes ': filler' | head -n 400000
    printf 'test_record_verdict PASSED\n'
  } > "$t4/a.sh"
  out=$(RHIZO_CHECK_SYSTEM="$t4" "$SELF" 2>&1)
  for want in 'routes b.sh to b.sh, which omits a.sh' 'a.sh uses helper-y.sh'; do
    if ! grep -qF "$want" <<<"$out"; then
      echo "SELFTEST FAILED: a use near the top of a long system test was missed: no '$want'" >&2
      sed 's/^/    /' <<<"$out" | head -20 >&2
      exit 1
    fi
  done

  echo "selftest ok: detects a system test using a helper the map does not route to it, a system test with no test_init, a system test that records no verdict, a system test with no row of its own, a row missing a transitive consumer, and an input row missing any system test that runs one of its system tests, and a use near the top of a long system test"
  exit 0
fi
FAILED=0

source "$REPO/test/system/run/system-tests.sh"
SYS_TESTS=()
declare -A SYS_PATH=() SYS_REL=() REL_IS_TEST=()
SYS_MAP=$(system_test_map "$SYS_DIR") && [[ -n "$SYS_MAP" ]] \
  || { echo "FAIL: no system test could be listed under $SYS_DIR"; exit 1; }
while IFS=$'\t' read -r n p; do
  SYS_TESTS+=("$p"); SYS_PATH[$n]=$p; SYS_REL[$n]="test/system/${p#"$SYS_DIR"/}"; REL_IS_TEST["test/system/${p#"$SYS_DIR"/}"]=1
done <<<"$SYS_MAP"

mapfile -t PREFIXES < <(grep -v '^#' "$AFFECTS" | grep -v '^$' | cut -f1)

while read -r top; do
  [[ -n "$top" ]] || continue
  covered=0
  for p in "${PREFIXES[@]}"; do
    [[ "$p" == "$top"* || "$top" == "$p"* ]] && { covered=1; break; }
  done
  if (( covered == 0 )); then
    echo "FAIL: $top is in the tree but nothing in affects.tsv covers it"
    echo "      until it is classified every diff touching it runs the whole suite"
    FAILED=1
  fi
done < <(git -C "$REPO" ls-files | awk -F/ 'NF>1 && $1 !~ /^\./ {print $1"/"}' | sort -u)

for p in "${PREFIXES[@]}"; do
  [[ -e "$REPO/$p" ]] || { echo "FAIL: affects.tsv maps $p, which does not exist"; FAILED=1; }
done

while IFS=$'\t' read -r prefix tests; do
  [[ -z "$prefix" || "$prefix" == \#* ]] && continue
  [[ "$tests" == ALL || "$tests" == NONE ]] && continue
  for g in ${tests//,/ }; do
    [[ -n "${SYS_PATH[$g]:-}" ]] || { echo "FAIL: $prefix names $g, which is not a system test script"; FAILED=1; }
  done
done < "$AFFECTS"

declare -A TEST_BODY=()
for g in "${SYS_TESTS[@]}"; do
  [[ -f "$g" ]] || continue
  TEST_BODY[$(basename "$g")]=$(sed -e '/^[[:space:]]*#/d' \
      -e '/^[[:space:]]*\(||\|&&\)\?[[:space:]]*\(log\|fail\|note\|step\|pass\|skip\|warn\)[[:space:]]/d' \
      "$g" 2>/dev/null)
done
HELPER_DIRS=("$SYS_DIR")
if [[ "$SYS_DIR" == "$REPO/test/system" ]]; then
  tree=$(python3 "$REPO/test/checks/lib/tree_dirs.py" --test --tools --repo "$REPO") && [[ -n "$tree" ]] \
    || { echo "FAIL: test/checks/lib/tree_dirs.py listed no folder"; exit 1; }
  while IFS= read -r d; do [[ "$d" == test/system ]] || HELPER_DIRS+=("$REPO/$d"); done <<<"$tree"
  for d in src/services src/services/probe-client src/androidd src/install; do HELPER_DIRS+=("$REPO/$d"); done
fi
HELPERS_SCANNED=0 HELPERS_USED=0
declare -A NAME_COUNT=()
ALL_HELPERS=()
for d in "${HELPER_DIRS[@]}"; do
  for helper in "$d"/*.sh "$d"/*.py "$d"/*.c; do
    [[ -f "$helper" ]] || continue
    ALL_HELPERS+=("$helper"); NAME_COUNT[$(basename "$helper")]=$(( ${NAME_COUNT[$(basename "$helper")]:-0} + 1 ))
  done
done
for helper in "${ALL_HELPERS[@]}"; do
  hbase=$(basename "$helper")
  hrel="${helper#"$REPO"/}"
  [[ "$SYS_DIR" == "$REPO/test/system" ]] || hrel="test/system/$hbase"
  HELPERS_SCANNED=$((HELPERS_SCANNED + 1))
  case "$hbase" in vm-*) continue ;; esac
  stem=${hbase%.*}
  [[ "$stem" != *[-_]* ]] && stem=${hbase//./\\.}
  ext_re="(\\.${hbase##*.})?"
  [[ "$stem" == *"\\."* ]] && ext_re=""
  case "$hrel" in test/checks/*|tools/*) [[ -n "$ext_re" ]] && ext_re="\\.${hbase##*.}" ;; esac
  if (( ${NAME_COUNT[$hbase]} > 1 )); then
    hdir=$(basename "$(dirname "$helper")")
    stem="$hdir/${hbase//./\\.}"
  fi
  users=""
  for g in "${SYS_TESTS[@]}"; do
    gb=$(basename "$g")
    [[ "$gb" == lib.sh ]] && continue
    grep -qE "(^|[^a-zA-Z0-9_-])$stem$ext_re([^a-zA-Z0-9_.-]|\.([^a-zA-Z0-9_-]|$)|$)" <<<"${TEST_BODY[$gb]:-}" && users+="$gb "
  done
  [[ -n "$users" ]] || continue
  HELPERS_USED=$((HELPERS_USED + 1))
  routed=$(awk -F'\t' -v k="$hrel" '$1 == k {print $2}' "$AFFECTS")
  [[ -z "$routed" || "$routed" == ALL ]] && continue
  for u in $users; do
    case ",$routed," in
      *",$u,"*) ;;
      *) echo "FAIL: $u uses $hbase but affects.tsv routes it only to $routed"
         echo "      a change to $hbase would not run $u"
         FAILED=1 ;;
    esac
  done
done

TEST_NAMES=$(cut -f1 <<<"$SYS_MAP" | grep -vx lib.sh)
{
  declare -A USES=()
  while read -r g; do
    [[ -n "$g" ]] || continue
    for other in $TEST_NAMES; do
      [[ "$other" == "$g" ]] && continue
      stem=${other//./\\.}
      grep -qE "(^|[^a-zA-Z0-9_-])$stem([^a-zA-Z0-9_-]|$)" <<<"${TEST_BODY[$g]:-}" \
        && USES[$g]+="$other "
    done
  done <<<"$TEST_NAMES"
  changed=1
  while (( changed )); do
    changed=0
    for g in "${!USES[@]}"; do
      for mid in ${USES[$g]}; do
        for x in ${USES[$mid]:-}; do
          [[ "$x" == "$g" ]] && continue
          case " ${USES[$g]} " in
            *" $x "*) ;;
            *) USES[$g]+="$x "; changed=1 ;;
          esac
        done
      done
    done
  done
  tracked_var=$(git -C "$REPO" ls-files -- var | head -3)
  if [[ -n "$tracked_var" ]]; then
    echo "FAIL: tracked paths under var/: $(tr '\n' ' ' <<<"$tracked_var")"
    echo "      var/ must stay untracked"
    FAILED=1
  fi
  ign_repo=$(mktemp -d) && git init -q "$ign_repo" && cp "$REPO/.gitignore" "$ign_repo/.gitignore" || exit 2
  git -C "$ign_repo" check-ignore -q --no-index var/scratch/x-1/verdict.txt; ign_rc=$?
  rm -rf "$ign_repo"
  if [[ "$SYS_DIR" == "$REPO/test/system" ]] && (( ign_rc != 0 )); then
    echo "FAIL: var/scratch/<name>-<vm>/ is not ignored"
    FAILED=1
  fi

  while read -r base; do
    [[ -n "$base" ]] || continue
    want="$base"
    for g in "${!USES[@]}"; do
      case " ${USES[$g]} " in *" $base "*) want+=" $g" ;; esac
    done
    routed=$(awk -F'\t' -v k="${SYS_REL[$base]:-test/system/$base}" '$1 == k {print $2}' "$AFFECTS")
    if [[ -z "$routed" ]]; then
      echo "FAIL: $base has no affects.tsv row of its own"
      echo "      it needs: ${SYS_REL[$base]:-test/system/$base}<TAB>$(tr ' ' ',' <<<"$want")"
      FAILED=1
      continue
    fi
    [[ "$routed" == ALL ]] && continue
    for w in $want; do
      case ",$routed," in
        *",$w,"*) ;;
        *) echo "FAIL: affects.tsv routes $base to $routed, which omits $w ($w runs $base)"
           FAILED=1 ;;
      esac
    done
  done <<<"$TEST_NAMES"

  while IFS=$'\t' read -r prefix routed; do
    [[ -z "$prefix" || "$prefix" == \#* || "$routed" == ALL || "$routed" == NONE ]] && continue
    [[ -n "${REL_IS_TEST[$prefix]:-}" ]] && grep -Fxq "${prefix##*/}" <<<"$TEST_NAMES" && continue
    missing=" "
    for g in ${routed//,/ }; do
      for h in "${!USES[@]}"; do
        case " ${USES[$h]} " in *" $g "*) ;; *) continue ;; esac
        case ",$routed,$missing" in *",$h,"*|*" $h "*) ;; *) missing+="$h " ;; esac
      done
    done
    for h in $missing; do
      echo "FAIL: affects.tsv routes $prefix to $routed, which omits $h ($h runs one of those system tests)"
      FAILED=1
    done
  done < "$AFFECTS"
}

for f in "${SYS_TESTS[@]}"; do
  base=$(basename "$f")
  [[ "$base" == lib.sh ]] && continue
  grep -q '^# test-boot-mode: ' "$f" \
    || { echo "FAIL: $base has no '# test-boot-mode:' tag"; FAILED=1; }
  if ! grep -qE '^[[:space:]]*test_init\b' "$f"; then
    if ! { grep -qE 'test_evidence_dir\b' "$f" && grep -qE '^[[:space:]]*TEST_NAME=' "$f"; }; then
      echo "FAIL: $base never calls test_init"
      FAILED=1
    fi
  fi
  grep -qE '^[[:space:]]*test_record_verdict[[:space:]]+(PASSED|FAILED|"?\$)' "$f" \
    || { echo "FAIL: $base never records a verdict"; FAILED=1; }
done

(( FAILED )) && { echo "affects.tsv is out of date"; exit 1; }
echo "affects.tsv covers the tree, all system tests tagged ($HELPERS_SCANNED helpers scanned, $HELPERS_USED used by a system test)"
exit 0
