#!/bin/bash
# test the rhizo-delayd selftest
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1

SRC=src/services/delayd/delayd.c
MODE=run
[[ "${1:-}" == "--selftest" ]] && MODE=selftest

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-delayd-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [[ "$MODE" == run ]]; then
  tools/build/services/delayd.sh "$WORK/rhizo-delayd" >"$WORK/build.log" 2>&1 \
    || { echo "FAIL: delayd.sh failed:" >&2; cat "$WORK/build.log" >&2; exit 1; }
  out=$("$WORK/rhizo-delayd" --selftest 2>&1); rc=$?
  if (( rc != 0 )); then
    echo "FAIL: rhizo-delayd --selftest failed:" >&2
    echo "$out" >&2
    exit 1
  fi
  n=$(sed -n 's/^rhizo-delayd selftest: \([0-9]*\) assertions passed$/\1/p' <<<"$out")
  if [[ -z "$n" ]] || (( n < 100 )); then
    echo "FAIL: rhizo-delayd --selftest asserted too little to check anything ('$out')" >&2
    exit 1
  fi
  mkdir -p "$WORK/tracefs/instances/rhizo-delay"
  out=$(RHIZO_SELINUX_MODE_FILE="$WORK/no-mode-record" "$WORK/rhizo-delayd" --remove-instance --tracefs "$WORK/tracefs" 2>&1); rc=$?
  if (( rc != 0 )) || [[ -e "$WORK/tracefs/instances/rhizo-delay" ]] || ! grep -q 'reason=selinux-mode' <<<"$out"; then
    echo "FAIL: --remove-instance with no mode record exited $rc and left the instance ($out)" >&2
    exit 1
  fi
  gcc -std=gnu11 -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=undefined -o "$WORK/rhizo-delayd-san" "$SRC" \
    || { echo "FAIL: the sanitized build failed" >&2; exit 1; }
  if ! out=$(ASAN_OPTIONS=detect_leaks=0 "$WORK/rhizo-delayd-san" --selftest 2>&1); then
    echo "FAIL: rhizo-delayd --selftest failed under ASan/UBSan:" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "check-delayd: rhizo-delayd --selftest passed ($n assertions, also sanitized)"
  exit 0
fi

# write the mutated source to mut.c
make_mutant() {
  sed -e "$2" "$SRC" >"$WORK/mut.c"
  if cmp -s "$SRC" "$WORK/mut.c"; then
    echo "FAIL: mutation '$1' matched nothing in $SRC" >&2
    return 1
  fi
}
# require the mutated selftest to fail
mutate() {
  local label="$1" out rc
  make_mutant "$@" || return 1
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
# run the mutant selftest under AddressSanitizer
mutate_asan() {
  local label="$1" out
  make_mutant "$@" || return 1
  gcc -std=gnu11 -O1 -w -fsanitize=address -o "$WORK/mut" "$WORK/mut.c" || { echo "FAIL: mutation '$label' did not build" >&2; return 1; }
  out=$(ASAN_OPTIONS=detect_leaks=0 "$WORK/mut" --selftest 2>&1)
  if grep -q AddressSanitizer <<<"$out"; then
    echo "ok: the sanitized selftest fails with '$label'"
  else
    echo "FAIL: the sanitized selftest does not notice '$label'" >&2
    return 1
  fi
}
fail=0
mutate "FLOOR_NS lowered to 0.4 ms" 's/^#define FLOOR_NS 500000ULL/#define FLOOR_NS 400000ULL/' || fail=1
mutate "GAP_NS doubled" 's/^#define GAP_NS 1000000ULL/#define GAP_NS 2000000ULL/' || fail=1
mutate "MAX_SPAN_NS doubled" 's/^#define MAX_SPAN_NS 100000000ULL/#define MAX_SPAN_NS 200000000ULL/' || fail=1
mutate "DELAYED_WP_US raised" 's/^#define DELAYED_WP_US 2000ULL/#define DELAYED_WP_US 3000ULL/' || fail=1
mutate "work-period held summed in ns, not whole us" 's|t->wp_held += held / 1000;|t->wp_held += held / 1000 * 1000 + held % 1000;|' || fail=1
mutate "the watermark removed" 's/^#define WATERMARK_NS 5000000ULL/#define WATERMARK_NS 0ULL/' || fail=1
mutate "fork inheritance removed" 's/^\tif (psb) {$/\tif (0) {/' || fail=1
mutate "the time-extend delta ignored" 's/ts += td + ((u64)rd32(data + off + 4) << 27);/ts += td;/' || fail=1
mutate "the missed-events flag ignored" 's/if (flags & RB_MISSED_EVENTS) {/if (0) {/' || fail=1
mutate "holder rule: nothing is ever held" 's/return get_task(e, occ_tid)->sb != t->sb;/return 0;/' || fail=1
mutate "holder rule: everything non-idle is held" 's/return get_task(e, occ_tid)->sb != t->sb;/return 1;/' || fail=1
mutate "peer context not checked" 's/ || strcmp(a, HOST_DELAY_CTX))/ || 0)/' || fail=1
mutate "a peer may take any namespace's stream" '/^static struct sbx \*peer_sandbox/,/^}/ s/sbx_find(e, ino)/e->sbs/' || fail=1
mutate "records go to the wrong namespace's connection" 's/struct conn \*c = t->sb->conn;/struct conn *c = e->sbs ? e->sbs->conn : NULL;/' || fail=1
mutate "on_loss does nothing" '/^static void on_loss/,/^}/ s/^\te->lost_pages++;$/\treturn;/' || fail=1
mutate "a hole is settled over" '/^static void on_loss/,/^}/ s/^\t\tclose_ep(e, t, t->ep_last_held);$/\t\tsettle(e, t, v->ts); close_ep(e, t, t->ep_last_held);/' || fail=1
mutate "a gone child's namespace is not taken from its parent" 's/^\t} else if (e->ops->pid_ns_children(/\t} else if (0 \&\& e->ops->pid_ns_children(/' || fail=1
mutate_asan "fork reads the parent after the table may have purged it" 's/^\tif (psb) {$/\tif (parent->sb) {/' || fail=1
mutate "namespace mode read as host" 's/^\tif (ns) {$/\tif (0) {/' || fail=1
mutate "an unreadable mode read as host" 's/^\tif (ns < 0)$/\tif (0)/' || fail=1
mutate "a mode file starting namespace read as namespace" 's/!strcmp(buf, "namespace")/!strncmp(buf, "namespace", 9)/' || fail=1
exit $fail
