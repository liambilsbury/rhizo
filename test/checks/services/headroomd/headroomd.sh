#!/bin/bash
# build rhizo-headroomd and run its selftest
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1

SRC=src/services/headroomd/headroomd.c
MODE=run
[[ "${1:-}" == "--selftest" ]] && MODE=selftest

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-headroomd-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [[ "$MODE" == run ]]; then
  tools/build/services/headroomd.sh "$WORK/rhizo-headroomd" >"$WORK/build.log" 2>&1 \
    || { echo "FAIL: headroomd.sh failed:" >&2; cat "$WORK/build.log" >&2; exit 1; }
  out=$("$WORK/rhizo-headroomd" --selftest 2>&1); rc=$?
  if (( rc != 0 )); then
    echo "FAIL: rhizo-headroomd --selftest failed:" >&2
    echo "$out" >&2
    exit 1
  fi
  n=$(sed -n 's/^rhizo-headroomd selftest: \([0-9]*\) assertions passed$/\1/p' <<<"$out")
  if [[ -z "$n" ]] || (( n < 250 )); then
    echo "FAIL: rhizo-headroomd --selftest asserted too little to check anything ('$out')" >&2
    exit 1
  fi
  gcc -std=gnu11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -o "$WORK/rhizo-headroomd-san" "$SRC" \
    || { echo "FAIL: the sanitized build failed" >&2; exit 1; }
  if ! out=$(ASAN_OPTIONS=detect_leaks=0 "$WORK/rhizo-headroomd-san" --selftest 2>&1); then
    echo "FAIL: rhizo-headroomd --selftest failed under ASan/UBSan:" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "check-headroomd: rhizo-headroomd --selftest passed ($n assertions, also sanitized)"
  exit 0
fi

# run the selftest on a mutated source
mutate() {
  local label="$1" out rc
  sed -e "$2" "$SRC" >"$WORK/mut.c"
  if cmp -s "$SRC" "$WORK/mut.c"; then
    echo "FAIL: mutation '$label' matched nothing in $SRC" >&2
    return 1
  fi
  gcc -std=gnu11 -O1 -w -o "$WORK/mut" "$WORK/mut.c" || { echo "FAIL: mutation '$label' did not build" >&2; return 1; }
  out=$("$WORK/mut" --selftest 2>&1); rc=$?
  if (( rc == 0 )); then
    echo "FAIL: the selftest still passes with '$label'" >&2
    return 1
  fi
  if (( rc != 1 )) || ! grep -q '^FAIL \[' <<<"$out"; then
    echo "FAIL: with '$label' the selftest died (exit $rc) instead of failing an assertion" >&2
    return 1
  fi
  echo "ok: the selftest fails with '$label'"
}
fail=0
mutate "guest added to the total" 's/v\[6\] + v\[7\];$/v[6] + v[7] + v[8];/' || fail=1
mutate "busy dropped from taken" 's/\*taken = v\[0\] + v\[1\] + v\[2\] + v\[5\]/*taken = v[0] + v[1] + v[5]/' || fail=1
mutate "the clock's total replaced by one cpu" 's/(unsigned __int128)ns \* ncpu \*/(unsigned __int128)ns * 1 */' || fail=1
mutate "steal dropped from total" 's/ + v\[6\] + v\[7\];$/ + v[6];/' || fail=1
mutate "an old seven-field line accepted" 's/if (nf < CPU_NEED)/if (nf < CPU_NEED - 1)/' || fail=1
mutate "a per-cpu line parsed as the aggregate" "s/(text\[3\] != ' ' && text\[3\] != '\\\\t')/0/" || fail=1
mutate "MIN returns the average" 's/type == T_MIN ? lowest : mean/0 ? lowest : mean/' || fail=1
mutate "AVERAGE returns the minimum" 's/type == T_MIN ? lowest : mean/lowest/' || fail=1
mutate "window selected by step count, not by time" 's/^\tconst struct sample \*start = ring_at(r, back);/\tback = (w + P_MS \/ 2) \/ P_MS < have ? (u32)((w + P_MS \/ 2) \/ P_MS) : have;\n&/' || fail=1
mutate "a tie takes the earlier sample" 's/^\t\tif (d < best) {/\t\tif (d <= best) {/' || fail=1
mutate "window_ms_used reported as steps times the period" 's/^\ta->window_ms = (u32)((newest->ns - start->ns + 500000ULL) \/ 1000000ULL);/\ta->window_ms = back * P_MS;/' || fail=1
mutate "window_ms_used truncated, not rounded" 's/newest->ns - start->ns + 500000ULL/newest->ns - start->ns/' || fail=1
mutate "a start no earlier than the newest sample accepted" 's/^\tif (newest->ns <= start->ns) {/\tif (newest->ns < start->ns) {/' || fail=1
mutate "the target is measured from the oldest sample" 's/(int64_t)newest->ns - (int64_t)(w \* 1000000ULL)/(int64_t)ring_at(r, have)->ns + (int64_t)(w * 1000000ULL)/' || fail=1
mutate "ring one sample short" 's/^#define RING_N 101$/#define RING_N 100/' || fail=1
mutate "sample period doubled" 's/^#define P_MS 100$/#define P_MS 200/' || fail=1
mutate "zero steps answered as data" 's/^\tif (have == 0) {$/\tif (0) {/' || fail=1
mutate "a stalled total is not a reset" 's/^\tif (b->total <= a->total)$/\tif (b->total < a->total)/' || fail=1
mutate "counter-reset treated as ok" 's/^\tif (b->total <= a->total)$/\tif (0)/' || fail=1
mutate "taken going backwards keeps the ring" 's/return ncpu != last_ncpu || taken < last_taken;/return ncpu != last_ncpu;/' || fail=1
mutate "a cpu count change keeps the ring" 's/return ncpu != last_ncpu || taken < last_taken;/return taken < last_taken;/' || fail=1
mutate "only the newest step is checked for a reset" 's/for (u32 j = 0; j < back; j++) {/for (u32 j = 0; j < 1; j++) {/' || fail=1
mutate "result not clamped above" 's/^\tif (v > 100.0)$/\tif (0)/' || fail=1
mutate "result not clamped below" 's/^\tif (v < 0.0)$/\tif (0)/' || fail=1
mutate "any peer context accepted" 's/return in_sandbox && !strcmp(ctx, POWER_CTX);/return in_sandbox;/' || fail=1
mutate "a peer outside the sandbox accepted" 's/return in_sandbox && !strcmp(ctx, POWER_CTX);/return !strcmp(ctx, POWER_CTX);/' || fail=1
mutate "peer context compared by prefix" 's/return in_sandbox && !strcmp(ctx, POWER_CTX);/return in_sandbox \&\& !strncmp(ctx, POWER_CTX, 17);/' || fail=1
mutate "request trailing junk accepted" "s/ || p\[nd\] != '\\\\0')/)/" || fail=1
mutate "window digit cap removed" 's/ || nd > WINDOW_DIGITS//' || fail=1
mutate "request type matched case-insensitively" 's/!strncmp(p, "min ", 4)/!strncasecmp(p, "min ", 4)/' || fail=1
mutate "reply loses a decimal" 's/"ok %.2f %u %u"/"ok %.1f %u %u"/' || fail=1
mutate "reply window and steps swapped" 's/a->value, a->window_ms, a->steps)/a->value, a->steps, a->window_ms)/' || fail=1
mutate "bad requests answered with data" 's/snprintf(out, cap, "err bad-request")/snprintf(out, cap, "nan no-data")/' || fail=1
mutate "reply echoes the request" 's/snprintf(out, cap, "err bad-request")/snprintf(out, cap, "err bad-request %.*s", (int)len, req)/' || fail=1
mutate "status lists a pid" 's/\\"last_error\\":\\"%s\\"}\\n"/\\"last_error\\":\\"%s\\",\\"pid\\":1}\\n"/' || fail=1
mutate "namespace mode read as host" 's/^\tif (ns) {$/\tif (0) {/' || fail=1
mutate "an unreadable mode read as host" 's/^\tif (ns < 0)$/\tif (0)/' || fail=1
mutate "a mode file starting namespace read as namespace" 's/!strcmp(buf, "namespace")/!strncmp(buf, "namespace", 9)/' || fail=1
exit $fail
