#!/bin/bash
# test deb_preflight
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1
export DEB_PREFLIGHT_IN_CONTAINER=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$HERE/../../tools/build/packaging/deb/deb-preflight.sh"
[[ -r "$LIB" ]] || { echo "FAIL: cannot read $LIB"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=()
fail() { FAILURES+=("$1"); }

# write a stub build container runner
make_stub_env_runner() {
  mkdir -p "$1/tools/build/env"
  cat > "$1/tools/build/env/run.sh" <<'SH'
#!/bin/bash
[[ -n "${CDP_CALL_LOG:-}" ]] && echo "IN_ENV $*" >> "$CDP_CALL_LOG"
exec "$@"
SH
  chmod +x "$1/tools/build/env/run.sh"
}

# create a directory of stub build tools
make_stub_tools_dir() {
  local matches="$1" build_rc="${2:-0}" fetch_rc="${3:-0}" stamp_rc="${4:-0}"
  local dir="$WORK/tools-$RANDOM$RANDOM"
  mkdir -p "$dir/var/share" "$dir/tools/build/packaging/deb" "$dir/tools/fetch/pools/deb" "$dir/test/vm" "$dir/test/system"
  cp "$LIB" "$dir/tools/build/packaging/deb/deb-preflight.sh"
  make_stub_env_runner "$dir"

  cat > "$dir/tools/build/stamps.py" <<PY
import os, sys
log = os.environ.get("CDP_CALL_LOG")
if log:
    with open(log, "a") as f:
        f.write("STAMPS " + " ".join(sys.argv[1:]) + "\n")
sys.exit(0 if $matches else 1)
PY

  cat > "$dir/tools/build/packaging/deb/debs.sh" <<SH
#!/bin/bash
[[ -n "\${CDP_CALL_LOG:-}" ]] && echo "BUILD_DEBS \$*" >> "\$CDP_CALL_LOG"
echo "build-debs stub: \$*"
exit $build_rc
SH
  chmod +x "$dir/tools/build/packaging/deb/debs.sh"

  cat > "$dir/tools/fetch/pools/deb/runtime-debs.sh" <<SH
#!/bin/bash
if [[ "\${1:-}" == --stamp-covers ]]; then
  [[ -n "\${CDP_CALL_LOG:-}" ]] && echo "STAMP_COVERS \$*" >> "\$CDP_CALL_LOG"
  exit $stamp_rc
fi
[[ -n "\${CDP_CALL_LOG:-}" ]] && echo "FETCH_RUNTIME \$*" >> "\$CDP_CALL_LOG"
echo "fetch-rhizo-runtime-debs stub: \$*"
exit $fetch_rc
SH
  chmod +x "$dir/tools/fetch/pools/deb/runtime-debs.sh"

  cat > "$dir/test/vm/sync.sh" <<'SH'
#!/bin/bash
[[ -n "${CDP_CALL_LOG:-}" ]] && echo "SYNC $*" >> "$CDP_CALL_LOG"
exit 0
SH
  chmod +x "$dir/test/vm/sync.sh"

  echo "$dir"
}

# write a fake system test script
make_contract_test() {
  local dir="$1" name="$2" requires="$3"
  cat > "$dir/$name" <<EOF
#!/bin/bash
# test-boot-mode: shared
if [[ "\${1:-}" == --print-contract ]]; then
  printf 'boot_mode=shared\tboots_unit=yes\tnests=-\trecords_metrics=no\tverdict_params=-\ttest_requires=$requires\n'
  exit 0
fi
exit 0
EOF
  chmod +x "$dir/$name"
}

# test deb_preflight_needs_deb with stub system tests
check_needs_deb() {
  local dir
  dir="$(make_stub_tools_dir 1)"
  make_contract_test "$dir/test/system" deb.sh deb:rhizo
  make_contract_test "$dir/test/system" none.sh none
  make_contract_test "$dir/test/system" undeclared.sh undeclared
  cat > "$dir/test/system/broken.sh" <<'EOF'
#!/bin/bash
exit 2
EOF
  chmod +x "$dir/test/system/broken.sh"

  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    deb_preflight_needs_deb "$dir/test/system" deb.sh ) \
    || fail "deb_preflight_needs_deb said no deb needed for a system test declaring deb:rhizo"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    ! deb_preflight_needs_deb "$dir/test/system" none.sh ) \
    || fail "deb_preflight_needs_deb said a deb was needed for a system test declaring none"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    ! deb_preflight_needs_deb "$dir/test/system" undeclared.sh ) \
    || fail "deb_preflight_needs_deb said a deb was needed for a system test with an undeclared contract"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    ! deb_preflight_needs_deb "$dir/test/system" broken.sh ) \
    || fail "deb_preflight_needs_deb said a deb was needed for a system test whose --print-contract exits nonzero"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    deb_preflight_needs_deb "$dir/test/system" none.sh deb.sh ) \
    || fail "deb_preflight_needs_deb missed a deb:rhizo token when it was not the FIRST system test in the list"
}

# test deb_preflight_rebuild_if_changed on a matching deb
check_rebuild_matching_skips() {
  local dir log
  dir="$(make_stub_tools_dir 1)"
  mkdir -p "$dir/debs"
  touch "$dir/debs/rhizo_0.1.0_amd64.deb"
  log="$WORK/log-matching-$RANDOM"; : > "$log"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    export CDP_CALL_LOG="$log"
    export RHIZO_DEB_DIR="$dir/debs"
    deb_preflight_rebuild_if_changed "$dir/test/system" "$dir/var" "$WORK/rebuild-matching.log" ) \
    || fail "deb_preflight_rebuild_if_changed refused a matching deb"
  grep -q '^STAMPS deb-require ' "$log" \
    || fail "deb_preflight_rebuild_if_changed never asked stamps.py about the present deb"
  grep -q '^STAMP_COVERS --stamp-covers .*/share/runtime-debs' "$log" \
    || fail "deb_preflight_rebuild_if_changed never asked whether the runtime pool's stamp covers a matching deb: $(cat "$log")"
  { grep -q '^BUILD_DEBS ' "$log" || grep -q '^FETCH_RUNTIME ' "$log" || grep -q '^SYNC ' "$log"; } \
    && fail "deb_preflight_rebuild_if_changed rebuilt a deb stamps.py called matching: $(cat "$log")"
}

# test refetching a changed runtime pool
check_rebuild_pool_changed_refetches() {
  local dir log order
  dir="$(make_stub_tools_dir 1 0 0 1)"
  mkdir -p "$dir/debs"
  touch "$dir/debs/rhizo_0.1.0_amd64.deb"
  log="$WORK/log-poolchanged-$RANDOM"; : > "$log"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    export CDP_CALL_LOG="$log"
    export RHIZO_DEB_DIR="$dir/debs"
    deb_preflight_rebuild_if_changed "$dir/test/system" "$dir/var" "$WORK/rebuild-poolchanged.log" ) \
    || fail "deb_preflight_rebuild_if_changed reported failure re-fetching a changed pool when the stubs all succeed"
  grep -q '^BUILD_DEBS' "$log" && fail "a matching deb was rebuilt only because its pool was changed: $(cat "$log")"
  order=$(grep -oE '^(FETCH_RUNTIME|SYNC)' "$log" | paste -sd, -)
  [[ "$order" == "FETCH_RUNTIME,SYNC" ]] \
    || fail "a pool whose stamp does not cover a matching deb was not re-fetched and re-synced, in that order: $(cat "$log")"
  grep -q '^IN_ENV .*/runtime-debs.sh$' "$log" \
    || fail "a changed pool was re-fetched on the host, not in the build container: $(cat "$log")"
}

# test deb_preflight_plan for each deb state
check_plan() {
  local dir log out matches stamp want spec
  for spec in "0 0 deb-changed" "1 1 pool-changed" "1 0 current"; do
    read -r matches stamp want <<<"$spec"
    dir="$(make_stub_tools_dir "$matches" 0 0 "$stamp")"
    make_contract_test "$dir/test/system" deb.sh deb:rhizo
    mkdir -p "$dir/debs"
    touch "$dir/debs/rhizo_0.1.0_amd64.deb"
    log="$WORK/log-plan-$RANDOM"; : > "$log"
    out=$( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
      export CDP_CALL_LOG="$log"
      export RHIZO_DEB_DIR="$dir/debs"
      deb_preflight_plan "$dir/test/system" "$dir/var" deb.sh 2>/dev/null )
    [[ "$out" == "$want" ]] || fail "deb_preflight_plan said '$out' where a real run meets $want"
    { grep -q '^BUILD_DEBS' "$log" || grep -q '^FETCH_RUNTIME' "$log" || grep -q '^SYNC' "$log"; } \
      && fail "deb_preflight_plan ran a rebuild tool ($want): $(cat "$log")"
  done
  dir="$(make_stub_tools_dir 0)"
  make_contract_test "$dir/test/system" none.sh none
  out=$( source "$dir/tools/build/packaging/deb/deb-preflight.sh"; deb_preflight_plan "$dir/test/system" "$dir/var" none.sh 2>/dev/null )
  [[ "$out" == none ]] || fail "deb_preflight_plan said '$out' for a selection that needs no deb"
}

# test rebuilding a missing or changed deb
check_rebuild_missing_and_changed_rebuild_in_order() {
  local dir log
  dir="$(make_stub_tools_dir 0)"
  log="$WORK/log-missing-$RANDOM"; : > "$log"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    export CDP_CALL_LOG="$log"
    export RHIZO_DEB_DIR="$dir/debs"
    deb_preflight_rebuild_if_changed "$dir/test/system" "$dir/var" "$WORK/rebuild-missing.log" ) \
    || fail "deb_preflight_rebuild_if_changed reported failure when the rebuild stubs all succeed"
  grep -q '^STAMPS' "$log" \
    && fail "deb_preflight_rebuild_if_changed asked stamps.py about a deb that does not exist at all"
  grep -q '^BUILD_DEBS' "$log" || fail "a missing deb was not rebuilt with debs.sh: $(cat "$log")"
  grep -q '^FETCH_RUNTIME' "$log" || fail "a missing deb's runtime pool was never re-checked with runtime-debs.sh: $(cat "$log")"
  grep -q '^SYNC' "$log" || fail "a missing deb's rebuild never re-synced the shares with sync.sh: $(cat "$log")"
  local order; order=$(grep -oE '^(BUILD_DEBS|FETCH_RUNTIME|SYNC)' "$log" | paste -sd, -)
  [[ "$order" == "BUILD_DEBS,FETCH_RUNTIME,SYNC" ]] \
    || fail "the rebuild did not run debs.sh, runtime-debs.sh, sync.sh in that order: $order"
  grep -q '^IN_ENV .*/debs.sh$' "$log" \
    || fail "a missing deb was built on the host, not in the build container: $(cat "$log")"
  grep -q '^IN_ENV .*/runtime-debs.sh$' "$log" \
    || fail "a missing deb's pool was re-fetched on the host, not in the build container: $(cat "$log")"

  dir="$(make_stub_tools_dir 0)"
  mkdir -p "$dir/debs"
  touch "$dir/debs/rhizo_0.1.0_amd64.deb"
  log="$WORK/log-changed-$RANDOM"; : > "$log"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    export CDP_CALL_LOG="$log"
    export RHIZO_DEB_DIR="$dir/debs"
    deb_preflight_rebuild_if_changed "$dir/test/system" "$dir/var" "$WORK/rebuild-changed.log" ) \
    || fail "deb_preflight_rebuild_if_changed reported failure rebuilding a changed deb when the rebuild stubs all succeed"
  grep -q '^STAMPS deb-require ' "$log" || fail "a present deb was never asked about via stamps.py deb-require"
  grep -q '^BUILD_DEBS' "$log" || fail "a changed deb was not rebuilt with debs.sh: $(cat "$log")"
  grep -q '^FETCH_RUNTIME' "$log" || fail "a changed deb's runtime pool was never re-checked: $(cat "$log")"
  grep -q '^SYNC' "$log" || fail "a changed deb's rebuild never re-synced the shares: $(cat "$log")"
}

# test the rebuild inside the build container
check_rebuild_in_container_runs_direct() {
  local dir log
  dir="$(make_stub_tools_dir 0)"
  log="$WORK/log-incontainer-$RANDOM"; : > "$log"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    export CDP_CALL_LOG="$log"
    export RHIZO_DEB_DIR="$dir/debs"
    export DEB_PREFLIGHT_IN_CONTAINER=1
    deb_preflight_rebuild_if_changed "$dir/test/system" "$dir/var" "$WORK/rebuild-incontainer.log" ) \
    || fail "deb_preflight_rebuild_if_changed reported failure inside the container when the rebuild stubs all succeed"
  grep -q '^IN_ENV' "$log" && fail "a rebuild already inside the build container started the container's runner again: $(cat "$log")"
  { grep -q '^BUILD_DEBS' "$log" && grep -q '^FETCH_RUNTIME' "$log"; } \
    || fail "a rebuild inside the build container did not build the deb and re-fetch its pool: $(cat "$log")"
}

# test a failing debs.sh in the rebuild
check_rebuild_stops_at_first_failure() {
  local dir log
  dir="$(make_stub_tools_dir 0 1 0)"
  log="$WORK/log-failfirst-$RANDOM"; : > "$log"
  ( source "$dir/tools/build/packaging/deb/deb-preflight.sh"
    export CDP_CALL_LOG="$log"
    export RHIZO_DEB_DIR="$dir/debs"
    deb_preflight_rebuild_if_changed "$dir/test/system" "$dir/var" "$WORK/rebuild-failfirst.log" ) \
    && fail "deb_preflight_rebuild_if_changed reported success although debs.sh itself failed"
  grep -q '^BUILD_DEBS' "$log" || fail "debs.sh was never even called"
  grep -q '^FETCH_RUNTIME' "$log" && fail "runtime-debs.sh ran after debs.sh had already failed: $(cat "$log")"
  grep -q '^SYNC' "$log" && fail "sync.sh ran after debs.sh had already failed: $(cat "$log")"
  [[ -s "$WORK/rebuild-failfirst.log" ]] || fail "a failed rebuild left no log at the path the caller was given"
}

run_all_checks() {
  FAILURES=()
  check_needs_deb
  check_rebuild_matching_skips
  check_rebuild_missing_and_changed_rebuild_in_order
  check_rebuild_stops_at_first_failure
  check_rebuild_in_container_runs_direct
  check_rebuild_pool_changed_refetches
  check_plan
}

if (( ! SELFTEST )); then
  run_all_checks
  if (( ${#FAILURES[@]} > 0 )); then
    printf 'FAIL: %s\n' "${FAILURES[@]}" >&2
    exit 1
  fi
  echo "check-deb-preflight: ok"
  exit 0
fi

# replace the pool-changed output with current
inject_lib_pool_ignored() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    echo pool-changed\n    return 0\n'
if old not in s:
    sys.exit("SELFTEST SETUP FAIL: deb_preflight_state's pool-changed answer not found")
open(p, "w").write(s.replace(old, "    echo current\n    return 0\n", 1))
PY
}

# run the deb build on the host
inject_lib_build_on_host() {
  python3 - "$1" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = 'deb_preflight_in_env "$DEB_PREFLIGHT_BUILD_DIR/debs.sh"'
if s.count(old) != 1:
    sys.exit("SELFTEST SETUP FAIL: deb_preflight_rebuild_if_changed's container deb build not found")
open(p, "w").write(s.replace(old, '"$DEB_PREFLIGHT_BUILD_DIR/debs.sh"', 1))
PY
}

# run the checks on a mutated deb-preflight.sh
selftest_lib_case() {
  local name="$1" inject="$2" real_lib="$LIB"
  cp "$real_lib" "$WORK/defect-$name-deb-preflight.sh"
  "$inject" "$WORK/defect-$name-deb-preflight.sh" || { echo "SELFTEST SETUP FAIL ($name)"; exit 1; }
  bash -n "$WORK/defect-$name-deb-preflight.sh" || { echo "SELFTEST SETUP FAIL ($name): mutated copy is not valid bash"; exit 1; }
  LIB="$WORK/defect-$name-deb-preflight.sh"
  run_all_checks
  LIB="$real_lib"
  if (( ${#FAILURES[@]} == 0 )); then
    echo "SELFTEST FAIL ($name): the checker passed a deb-preflight.sh copy with the $name defect reintroduced"
    exit 1
  fi
  echo "selftest ok ($name): detected -- ${FAILURES[0]}"
}

selftest_lib_case pool-stamp-ignored  inject_lib_pool_ignored
selftest_lib_case deb-built-on-host  inject_lib_build_on_host

run_all_checks
if (( ${#FAILURES[@]} > 0 )); then
  printf 'SELFTEST FAIL (clean): the real deb-preflight.sh failed its own checker: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "selftest ok (clean): the real deb-preflight.sh passes every assertion"
exit 0
