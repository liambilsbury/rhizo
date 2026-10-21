#!/bin/bash
# rebuild the rhizo .deb when it no longer matches the tree
_dp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${DEB_PREFLIGHT_BUILD_DIR:=$_dp_here}"
: "${DEB_PREFLIGHT_FETCH_DIR:=$_dp_here/../../../fetch/pools/deb}"
: "${DEB_PREFLIGHT_VM_DIR:=$_dp_here/../../../../test/vm}"
: "${DEB_PREFLIGHT_ENV_RUN:=$_dp_here/../../env/run.sh}"
_DP_SYSTEM_TESTS="$_dp_here/../../../../test/system/run/system_tests.py"
unset _dp_here

# return success if any named system test needs the rhizo .deb
deb_preflight_needs_deb() {
  local system_dir="$1"; shift
  local test path requires rest
  for test in "$@"; do
    [[ -n "$test" ]] || continue
    path=$(python3 "$_DP_SYSTEM_TESTS" --path "$test" "$system_dir" 2>/dev/null) || path="$system_dir/$test"
    requires=$("$path" --print-contract 2>/dev/null) || continue
    case "$requires" in
      *test_requires=*)
        rest="${requires#*test_requires=}"
        rest="${rest%%$'\t'*}"
        [[ " $rest " == *" deb:rhizo "* ]] && return 0
        ;;
    esac
  done
  return 1
}

# print the state of the .deb and runtime pool
deb_preflight_state() {
  local system_dir="$1" var_dir="$2" deb pdir
  local -a pools=()
  local -a debs=()
  local nullglob_was
  nullglob_was=$(shopt -p nullglob)
  shopt -s nullglob
  debs=("${RHIZO_DEB_DIR:-$var_dir/debs}"/rhizo_*_amd64.deb)
  eval "$nullglob_was"
  deb=""
  (( ${#debs[@]} )) && deb="${debs[-1]}"
  if [[ -z "$deb" ]] || ! python3 "$DEB_PREFLIGHT_BUILD_DIR/../../stamps.py" deb-require "$deb" >/dev/null 2>&1; then
    echo deb-changed
    return 0
  fi
  for pdir in "$var_dir/share" "$var_dir"/share-*; do
    [[ -d "$pdir" && ! -L "$pdir" ]] || continue
    [[ "$pdir" == "$var_dir/share" || -d "$pdir/runtime-debs" ]] && pools+=("$pdir/runtime-debs")
  done
  if (( ${#pools[@]} )) && ! RHIZO_DEB_DIR="${RHIZO_DEB_DIR:-$var_dir/debs}" \
      RHIZO_DEB_DIR_PREV="${RHIZO_DEB_DIR_PREV:-$var_dir/debs/prev}" \
      "$DEB_PREFLIGHT_FETCH_DIR/runtime-debs.sh" --stamp-covers "${pools[@]}" >/dev/null 2>&1; then
    echo pool-changed
    return 0
  fi
  echo current
}

# run a command in the build container
deb_preflight_in_env() {
  local inside="${DEB_PREFLIGHT_IN_CONTAINER:-}"
  if [[ -z "$inside" ]]; then
    inside=0
    [[ -e /run/.containerenv || -e /.dockerenv ]] && inside=1
  fi
  if (( inside )); then "$@"; else "$DEB_PREFLIGHT_ENV_RUN" "$@"; fi
}

# re-fetch the runtime pool in the build container
deb_preflight_fetch_pool() {
  local v
  local -a pass=()
  for v in RHIZO_DEB_DIR RHIZO_DEB_DIR_PREV RHIZO_KERNEL_DEB_DIR; do
    [[ -n "${!v:-}" ]] && pass+=("$v=${!v}")
  done
  deb_preflight_in_env env "${pass[@]}" "$DEB_PREFLIGHT_FETCH_DIR/runtime-debs.sh"
}

# rebuild the .deb, its pool and the shares as needed
deb_preflight_rebuild_if_changed() {
  local system_dir="$1" var_dir="$2" log_file="$3" state
  state=$(deb_preflight_state "$system_dir" "$var_dir")
  case "$state" in
    deb-changed)
      echo "deb-preflight: the rhizo .deb is missing or changed for this tree -- rebuilding it, its offline pool and the shares" >&2
      { deb_preflight_in_env "$DEB_PREFLIGHT_BUILD_DIR/debs.sh" && deb_preflight_fetch_pool \
          && "$DEB_PREFLIGHT_VM_DIR/sync.sh"; } >"$log_file" 2>&1 ;;
    pool-changed)
      echo "deb-preflight: the rhizo .deb matches this tree but a runtime pool was checked against another .deb -- re-fetching the pool and re-syncing the shares" >&2
      { deb_preflight_fetch_pool && "$DEB_PREFLIGHT_VM_DIR/sync.sh"; } >"$log_file" 2>&1 ;;
    *) return 0 ;;
  esac || {
    echo "deb-preflight: the rebuild failed ($log_file); preflight names what is still missing" >&2
    return 1
  }
  return 0
}

# rebuild the .deb and pool when out of date
deb_preflight() {
  local system_dir="$1" var_dir="$2" log_file="$3"; shift 3
  deb_preflight_needs_deb "$system_dir" "$@" || return 0
  deb_preflight_rebuild_if_changed "$system_dir" "$var_dir" "$log_file"
}

# print what a real preflight run would rebuild
deb_preflight_plan() {
  local system_dir="$1" var_dir="$2" state; shift 2
  if ! deb_preflight_needs_deb "$system_dir" "$@"; then
    echo none
    return 0
  fi
  state=$(deb_preflight_state "$system_dir" "$var_dir")
  case "$state" in
    deb-changed)  echo "deb-preflight (dry run): the rhizo .deb is missing or changed -- a real run rebuilds it, its offline pool and the shares before claiming any vm" >&2 ;;
    pool-changed) echo "deb-preflight (dry run): a runtime pool was checked against another .deb -- a real run re-fetches it and re-syncs the shares before claiming any vm" >&2 ;;
  esac
  echo "$state"
}
