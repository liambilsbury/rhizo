#!/bin/bash
# test headroom.sh's no-load sampling
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HR="$REPO/test/system/measure/headroom.sh"
SELFTEST=0
case "${1:-}" in
  --selftest) SELFTEST=1 ;;
  "") ;;
  *) HR="$1" ;;
esac
WORK=$(mktemp -d)
MUTANT=0
# remove the fixture files and folders this check made
cleanup() { rm -f "$WORK"/c*/* "$WORK"/*.sh; rmdir "$WORK"/c* "$WORK" 2>/dev/null; }
trap cleanup EXIT

FNS="field num_cmp seen hr_stats counts_grown nan_reason run_more run_level probe_logcat_agrees assert_sampling"

# print the named functions' definitions from a script
defs() {
  awk -v names=" $2 " '
    !on && /^[a-z_]+\(\) \{/ {
      n = substr($0, 1, index($0, "(") - 1)
      if (index(names, " " n " ")) { print; on = ($0 ~ /\{$/); next }
    }
    on { print; if ($0 == "}") on = 0 }' "$1"
}

# print the stubs standing in for the guest, the probe app and the rig
stubs() {
  cat <<'STUBS'
SELFTEST=0
pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; }
log() { :; }
probe_start() { echo "$1 $2" >>"$EV/calls.txt"; }
probe_stop() { :; }
dump_hint() { :; }
snap_android_tids() { :; }
adversary_start() { ADV_T0=0; ADV_ON=1; }
adversary_stop() { ADV_ON=0; }
guest_counts() {
  if [[ -e "$EV/counted" ]]; then echo "hz=100 ticks=1250 requests=30"; else : >"$EV/counted"; echo "hz=100 ticks=1000 requests=5"; fi
}
fixture() {
  local spec="${1%@*}" v="99.25" ok n i t=10000000000
  [[ "$1" == *@* ]] && v="${1#*@}"
  ok="${spec%/*}"; n="${spec#*/}"
  echo "RHIZO_HEADROOM_INFO supported=1 min_interval_ms=100 window_min=100 window_max=10000"
  echo "RHIZO_HEADROOM api=ndk t_ns=$t type=average window=1000 rc=0 value=NaN"
  for (( i = 0; i < n; i++ )); do
    t=$(( t + 100000000 ))
    if (( i < ok )); then echo "RHIZO_HEADROOM api=java t_ns=$t type=average window=1000 value=$v"
    else echo "RHIZO_HEADROOM api=java t_ns=$t type=average window=1000 value=NaN"; fi
  done
  echo "RHIZO_HEADROOM_DONE samples=$n nan=$(( n - ok ))"
}
probe_finish() {
  RUN=$(( RUN + 1 ))
  (( RUN <= 10 )) || { echo "RUNAWAY more than 10 probe runs"; return 1; }
  local spec="${SPECS[RUN-1]:-0/0}"
  if [[ "$spec" == empty ]]; then echo "<empty read>" >"$EV/$1-probe.txt"; : >"$EV/$1-logcat.txt"; return 1; fi
  fixture "$spec" >"$EV/$1-probe.txt"
  sed -n 's/^RHIZO_HEADROOM api=java /I RhizoHeadroom: RHIZO_HEADROOM api=java /p' "$EV/$1-probe.txt" >"$EV/$1-logcat.txt"
}
RUN=0
STUBS
}

# run a level of a script on fixture probe runs
run_case() {
  local script="$1" k="$2" ev
  shift 2
  ev=$(mktemp -d "$WORK/c.XXXXXX")
  EV="$ev" bash -c "$(grep -E '^(HEADROOM_MIN_SAMPLES|SAMPLE_S|SAMPLE_MORE_S|SAMPLE_MORE_RUNS|SAMPLE_LOAD_S|SETTLE_S|ADV_SLACK_S)=[0-9]+$' "$script")
$(defs "$script" "$FNS")
$(stubs)
SPECS=($*)
run_level lvl $k
echo \"RUNS \${#RL_TAGS[@]}\"
echo \"STATS \$RL_STATS\"
assert_sampling L \"\$RL_STATS\" \"\${RL_TAGS[@]}\"
echo \"AGREES \$(probe_logcat_agrees \"\${RL_TAGS[@]}\")\"
sed 's/^/CALL /' \"\$EV/calls.txt\"" 2>&1
}

BAD=0
# record a case's failed expectation
bad() { echo "FAIL: $1"; BAD=$(( BAD + 1 )); }

# check that one case's output holds all of the expected line patterns
expect() {
  local what="$1" out="$2" pat
  shift 2
  for pat in "$@"; do
    grep -qE -- "$pat" <<<"$out" || { bad "$what: no line matching '$pat' in: $(tr '\n' '|' <<<"$out" | cut -c1-600)"; return; }
  done
  [[ $SELFTEST == 1 && -n "${QUIET:-}" ]] || echo "ok   $what"
}

# check that one case's output holds no line matching a pattern
expect_not() {
  local what="$1" out="$2" pat="$3"
  grep -qE -- "$pat" <<<"$out" && { bad "$what: a line matches '$pat': $(grep -E -- "$pat" <<<"$out" | head -2 | tr '\n' '|')"; return; }
  [[ $SELFTEST == 1 && -n "${QUIET:-}" ]] || echo "ok   $what"
}

# run all of the cases against a copy of headroom.sh
check_script() {
  local hr="$1" fn out
  BAD=0
  for fn in $FNS; do
    grep -qE "^$fn\(\) \{" "$hr" || bad "$hr defines no $fn()"
  done
  (( BAD )) && return

  out=$(run_case "$hr" 0 "25/400")
  expect "a first no-load run with 25 non-NaN samples makes no more runs" "$out" \
    '^RUNS 1$' '^PASS L: 25 non-NaN java samples in 1 probe run\(s\) \(>= 20; 375 NaN: rhizo-headroomd served 25 requests while the guest.s user and nice time grew 2500 ms; HintManagerService answers an ordinary app NaN' \
    '^CALL lvl 375$'
  expect_not "a first no-load run with 25 non-NaN samples starts no second probe" "$out" '^CALL lvl-2 '

  out=$(run_case "$hr" 0 "17/400" "8/130@90.00")
  expect "a short first no-load run (17) gets one more 120 s run and reaches 25" "$out" \
    '^RUNS 2$' '^CALL lvl 375$' '^CALL lvl-2 120$' '^STATS n=530 ok=25 nan=505 err=0 unsup=0 median=99.25 min=90.00 max=99.25 runs=2 user_nice_ms=2500 hal_requests=25$' \
    '^PASS L: each of the 2 probe run\(s\) has its info line' '^PASS L: each probe run.s NDK sample' \
    '^PASS L: 25 non-NaN java samples in 2 probe run\(s\)' '^AGREES 530 530$'

  out=$(run_case "$hr" 0 "10/400" "4/130" "3/130" "5/130")
  expect "a level short over three runs takes the third extra run and reaches 22" "$out" \
    '^RUNS 4$' '^CALL lvl-4 120$' '^PASS L: 22 non-NaN java samples in 4 probe run\(s\)'

  out=$(run_case "$hr" 0 "10/400" "2/130" "2/130" "2/130" "9/130")
  expect "a level still short after the extra runs stops at four runs and fails the floor" "$out" \
    '^RUNS 4$' '^FAIL L: 16 non-NaN java samples in 4 probe run\(s\), want at least 20 \(774 NaN: rhizo-headroomd served 25 requests'
  expect_not "a level still short after the extra runs starts no fifth run" "$out" '^CALL lvl-5 '

  out=$(run_case "$hr" 0 "0/400" "0/130" "0/130" "0/130")
  expect "an all-NaN level fails the floor after the extra runs" "$out" \
    '^RUNS 4$' '^STATS n=790 ok=0 nan=790 ' '^FAIL L: 0 non-NaN java samples in 4 probe run\(s\), want at least 20'
  expect_not "an all-NaN level passes nothing on its samples" "$out" '^PASS L: [0-9]+ non-NaN'

  out=$(run_case "$hr" 0 "0/0" "0/0" "0/0" "0/0")
  expect "a level whose runs wrote no java sample fails the floor" "$out" \
    '^RUNS 4$' '^STATS n=0 ok=0 ' '^FAIL L: 0 non-NaN java samples in 4 probe run\(s\), want at least 20'

  out=$(run_case "$hr" 0 "empty")
  expect "a first run that wrote nothing fails its info line and the floor with no more runs" "$out" \
    '^RUNS 1$' '^FAIL L: 0 probe info line\(s\) for 1 run\(s\)' '^FAIL L: 0 non-NaN java samples in 1 probe run\(s\), want at least 20'

  out=$(run_case "$hr" 2 "5/400")
  expect "a loaded level short of the floor gets no more runs and fails" "$out" \
    '^RUNS 1$' '^FAIL L: 5 non-NaN java samples in 1 probe run\(s\), want at least 20'
  expect_not "a loaded level starts no second probe" "$out" '^CALL lvl-2 '

  out=$(run_case "$hr" 0 "17/400" "3/130@error:RuntimeException")
  expect "an error sample in an extra run fails the error check" "$out" \
    '^FAIL L: 3 java sample\(s\) reported error:<exception>'
}

# print headroom.sh with a literal replacement
mutate() {
  python3 -c '
import sys
s = open(sys.argv[1]).read()
if s.count(sys.argv[2]) != 1:
    sys.exit(1)
sys.stdout.write(s.replace(sys.argv[2], sys.argv[3]))' "$HR" "$1" "$2"
}

if (( SELFTEST )); then
  rc=0
  QUIET=1 check_script "$HR"
  (( BAD == 0 )) && echo "ok   the check passes the tree's headroom.sh" || { echo "FAIL: the check fails the tree's headroom.sh"; rc=1; }
  while IFS='|' read -r name old new; do
    copy="$WORK/mutant-$(( ++MUTANT )).sh"
    mutate "$old" "$new" >"$copy" && [[ -s "$copy" ]] || { echo "FAIL: mutation '$name' found no single '$old' in headroom.sh"; rc=1; continue; }
    QUIET=1 check_script "$copy" >/dev/null
    (( BAD > 0 )) && echo "ok   caught: $name ($BAD failed expectation(s))" || { echo "FAIL: not caught: $name"; rc=1; }
  done <<'MUTANTS'
the floor ignored|num_cmp "$v" ge "$HEADROOM_MIN_SAMPLES"|num_cmp "$v" ge 0
no run after the first|field "$RL_STATS" ok) < HEADROOM_MIN_SAMPLES|field "$RL_STATS" ok) < 0
no cap on the extra runs|&& r <= SAMPLE_MORE_RUNS ))|&& r <= 99 ))
a NaN sample read as a number|if v == "NaN":|if v == "nan":
only the newest run's file counted|RL_STATS=$(hr_stats 0 "${files[@]}")|RL_STATS=$(hr_stats 0 "$EV/$tag-$r-probe.txt")
a loaded level given more runs|(( k == 0 )) && run_more "$tag"|run_more "$tag"
extra runs as long as the first|probe_start "$tag-$r" "$SAMPLE_MORE_S"|probe_start "$tag-$r" "$SAMPLE_S"
the info line read from the first run only|info=$(( info + ${a:-0} ))|info=$(( ${a:-0} ))
MUTANTS
  (( rc == 0 )) && echo "headroom sample floor selftest passed" || echo "headroom sample floor selftest FAILED"
  exit $rc
fi

check_script "$HR"
(( BAD == 0 )) && { echo "headroom sample floor checks passed"; exit 0; }
echo "headroom sample floor checks FAILED ($BAD)"
exit 1
