#!/bin/bash
# test sync.sh and runtime-debs.sh temp file cleanup
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# print a function's text from a file
extract() {
  sed -n "/^$2() {/,/^}/p" "$1"
}

# run the cleanup cases and print FAIL lines
run_checks() {
  local sync="$1" fetch="$2" fx out fns
  fns="$WORK/sync-fns.sh"
  { for f in tree_listing vm_differs vm_extras sync_temp_cleanup stray_temps sweep_stray_temps mirror_vm verify_vm; do
      extract "$sync" "$f"
    done; } > "$fns"
  for f in sync_temp_cleanup stray_temps sweep_stray_temps; do
    grep -q "^$f() {" "$fns" || echo "FAIL: sync.sh has no $f()"
  done

  fx="$WORK/sync-fx"; rm -rf "$fx"; mkdir -p "$fx/var/share/pool" "$fx/var/share-2/pool"
  echo real > "$fx/var/share/pool/a.deb"
  echo partial > "$fx/var/share/pool/b.deb.tmp.4242"
  echo partial > "$fx/var/share-2/pool/c.deb.tmp.2193966"
  out=$(cd "$fx" && bash -c '
    set -uo pipefail; CHECK=0
    sync_one() { cp -p "$1" "$2"; }
    source "'"$fns"'"
    sweep_stray_temps var/share var/share-2/ && mirror_vm var/share-2/ && verify_vm var/share-2/; echo "RC=$?"' 2>&1)
  [[ "$out" == *RC=0* ]] || echo "FAIL: sync over a share and vm holding stray temps did not finish clean: $(tr '\n' ' ' <<<"$out")"
  [[ -z "$(find "$fx" -name '*.tmp.[0-9]*')" ]] \
    || echo "FAIL: sync left stray temps: $(find "$fx" -name '*.tmp.[0-9]*' | tr '\n' ' ')"
  [[ -f "$fx/var/share-2/pool/a.deb" ]] || echo "FAIL: sync did not mirror share/pool/a.deb into share-2"
  grep -q 'c.deb.tmp.2193966' <<<"$out" || echo "FAIL: sync removed a stray temp without naming it"

  echo partial > "$fx/var/share-2/pool/d.deb.tmp.77"
  out=$(cd "$fx" && bash -c '
    set -uo pipefail; CHECK=1
    source "'"$fns"'"
    verify_vm var/share-2/; echo "RC=$?"' 2>&1)
  [[ "$out" == *RC=1* && "$out" == *d.deb.tmp.77* ]] \
    || echo "FAIL: --check did not fail naming share-2's stray temp: $(tr '\n' ' ' <<<"$out")"
  [[ -f "$fx/var/share-2/pool/d.deb.tmp.77" ]] || echo "FAIL: --check removed a file"

  fx="$WORK/sync-kill"; rm -rf "$fx"; mkdir -p "$fx/var/share/pool" "$fx/var/share-2/pool"
  echo real > "$fx/var/share/pool/a.deb"
  (cd "$fx" && bash -c '
    set -uo pipefail; CHECK=0
    ln() { return 1; }
    sync_one() { echo half > "$2"; kill -TERM $$; sleep 5; }
    source "'"$fns"'"
    sync_temp_cleanup
    mirror_vm var/share-2/' >/dev/null 2>&1)
  [[ -z "$(find "$fx" -name '*.tmp.[0-9]*')" ]] \
    || echo "FAIL: a sync killed mid-copy left $(find "$fx" -name '*.tmp.[0-9]*' | tr '\n' ' ')"

  fns="$WORK/fetch-fns.sh"
  { extract "$fetch" rrd_sweep_temps; extract "$fetch" rrd_install_pool_file; extract "$fetch" rrd_temp_cleanup; } > "$fns"
  for f in rrd_sweep_temps rrd_install_pool_file rrd_temp_cleanup; do
    grep -q "^$f() {" "$fns" || echo "FAIL: runtime-debs.sh has no $f()"
  done
  grep -q 'rrd_sweep_temps "$POOL"' "$fetch" \
    || echo "FAIL: runtime-debs.sh's main run never sweeps the pool before its check"
  grep -q 'rrd_install_pool_file ' <<<"$(extract "$fetch" rrd_fetch)" \
    || echo "FAIL: rrd_fetch copies into the pool without rrd_install_pool_file"
  fx="$WORK/fetch-fx"; rm -rf "$fx"; mkdir -p "$fx/pool" "$fx/src"
  echo keep > "$fx/pool/x.deb"; echo partial > "$fx/pool/g++-13_13.3.0_amd64.deb.tmp.2193966"
  out=$(bash -c 'source "'"$fns"'"; rrd_sweep_temps "'"$fx/pool"'"; echo "RC=$?"' 2>&1)
  [[ -z "$(find "$fx/pool" -name '*.tmp.*')" && -f "$fx/pool/x.deb" && "$out" == *g++-13_13.3.0_amd64.deb.tmp.2193966* ]] \
    || echo "FAIL: rrd_sweep_temps did not remove and name the pool's stray temp, keeping the rest: $(tr '\n' ' ' <<<"$out")"
  echo new > "$fx/src/y.deb"
  (bash -c '
    source "'"$fns"'"
    rrd_temp_cleanup
    cp() { command cp "$@"; kill -TERM $$; sleep 5; }
    rrd_install_pool_file "'"$fx/src/y.deb"'" "'"$fx/pool"'"' >/dev/null 2>&1)
  [[ -z "$(find "$fx/pool" -name '*.tmp.*')" ]] \
    || echo "FAIL: a pool copy killed mid-write left $(find "$fx/pool" -name '*.tmp.*' | tr '\n' ' ')"
  out=$(bash -c 'source "'"$fns"'"; rrd_install_pool_file "'"$fx/src/y.deb"'" "'"$fx/pool"'"; echo "RC=$?"' 2>&1)
  [[ "$out" == *RC=0* && "$(cat "$fx/pool/y.deb" 2>/dev/null)" == new ]] \
    || echo "FAIL: rrd_install_pool_file did not land the file: $(tr '\n' ' ' <<<"$out")"
}

if (( ! SELFTEST )); then
  problems=$(run_checks "$HERE/../vm/sync.sh" "$HERE/../../tools/fetch/pools/deb/runtime-debs.sh")
  if [[ -n "$problems" ]]; then
    printf '%s\n' "$problems"
    exit 1
  fi
  echo "share temp cleanup: sync.sh and runtime-debs.sh sweep stray temps, name them, and leave none when killed"
  exit 0
fi

# write an edited copy of the file
mutant() {
  local out; out="$WORK/mut-$1-$(basename "$2")"
  OLD="$3" NEW="$4" python3 -c '
import os, sys
s = open(sys.argv[1]).read()
if s.count(os.environ["OLD"]) < 1:
    sys.exit("mutant anchor not found: " + os.environ["OLD"][:60])
open(sys.argv[2], "w").write(s.replace(os.environ["OLD"], os.environ["NEW"]))' "$2" "$out" || exit 1
  printf '%s' "$out"
}
failed=0
# check the output for the problem text
check_mutant() {
  local got
  got=$(run_checks "$2" "$3")
  if grep -qF "$4" <<<"$got"; then
    echo "selftest ok ($1): detected"
  else
    echo "SELFTEST FAIL ($1): not caught, wanted '$4', got: $(tr '\n' ' ' <<<"$got")"
    failed=1
  fi
}
S="$HERE/../vm/sync.sh" F="$HERE/../../tools/fetch/pools/deb/runtime-debs.sh"
check_mutant no-sweep "$(mutant no-sweep "$S" 'find "$d" -type f -name '"'"'*.tmp.[0-9]*'"'"' -print' 'true')" "$F" "stray temps"
check_mutant no-trap "$(mutant no-trap "$S" 'rm -f -- "${SYNC_TMP:-}"' ':')" "$F" "killed mid-copy"
check_mutant fetch-no-sweep "$S" "$(mutant fetch-no-sweep "$F" 'rrd_sweep_temps "$POOL"' ':')" "never sweeps the pool"
check_mutant fetch-direct-cp "$S" "$(mutant fetch-direct-cp "$F" 'rrd_install_pool_file "$f" "$pool"' 'cp --remove-destination "$f" "$pool/"')" "without rrd_install_pool_file"
check_mutant fetch-no-trap "$S" "$(mutant fetch-no-trap "$F" 'rm -f -- "${RRD_TMP:-}"' ':')" "pool copy killed mid-write"
problems=$(run_checks "$S" "$F")
[[ -z "$problems" ]] || { echo "SELFTEST FAIL (clean): the real files fail: $problems"; failed=1; }
(( failed )) && exit 1
echo "selftest ok: 5 defects caught, the real sync.sh and runtime-debs.sh pass"
