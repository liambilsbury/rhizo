#!/bin/bash
# fetch a guest package pool from pools.tsv
set -euo pipefail
FETCH_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./deb-pool-lib.sh
source "$FETCH_TOOLS/deb-pool-lib.sh"
# shellcheck source=./deb-pool-fetch-env-lib.sh
source "$FETCH_TOOLS/deb-pool-fetch-env-lib.sh"

SHARE="$(cd "$FETCH_TOOLS/../../../.." && pwd)/var/share"
W="" WORK=""
trap 'rm -rf "$W" "$WORK"' EXIT

# fetch a derived pool
fetch_derived() {
  local pool="$1" roots="$2" allow="$3" mode="$4" rc=0
  W=$(mktemp -d) || return 2
  deb_pool_fetch_env "$W"
  deb_pool_fetch "$pool" "$roots" "$allow" "$mode" || rc=$?
  if [[ "$mode" != --check && "$rc" == 1 ]]; then
    deb_pool_prune_superseded "$SHARE/$pool"
    rc=0
    deb_pool_fetch "$pool" "$roots" "$allow" --check || rc=$?
  fi
  return "$rc"
}

# check the pool holds a .deb of all of the named packages
pool_has_all() {
  local dir="$1" p
  shift
  for p in "$@"; do
    compgen -G "$dir/${p}_*.deb" >/dev/null || return 1
  done
}

# copy each downloaded .deb into the pool
pool_take() {
  local pool="$1" dir="$2" p f
  shift 2
  for p in "$@"; do
    f=$(compgen -G "$WORK/${p}_*.deb" | head -1) || true
    [[ -n "${f:-}" ]] || { echo "[fetch-$pool] apt-get download produced no .deb for $p" >&2; return 1; }
    cp --remove-destination "$f" "$dir/$(basename "$f")"
    echo "[fetch-$pool] $(basename "$f") $(sha256sum "$dir/$(basename "$f")" | cut -d' ' -f1)"
  done
}

# fetch a listed pool
fetch_listed() {
  local pool="$1" dir="$SHARE/$1"
  local -a want
  read -ra want <<<"$2"
  mkdir -p "$dir"
  if pool_has_all "$dir" "${want[@]}"; then
    echo "[fetch-$pool] already present:"
    ls -1 "$dir"
    return 0
  fi
  W=$(mktemp -d) || return 2
  deb_pool_fetch_env "$W" || return 2
  WORK=$(mktemp -d)
  ( cd "$WORK" && apt-get download "${want[@]}" )
  pool_take "$pool" "$dir" "${want[@]}"
}

# fetch a closure pool
fetch_closure() {
  local pool="$1" dir="$SHARE/$1" closure p prio
  local -a want fetch=()
  read -ra want <<<"$2"
  mkdir -p "$dir"
  if pool_has_all "$dir" "${want[@]}"; then
    echo "[fetch-$pool] already present:"
    ls -1 "$dir"
    return 0
  fi
  W=$(mktemp -d) || return 2
  deb_pool_fetch_env "$W" || return 2
  closure=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
              --no-breaks --no-replaces --no-enhances "${want[@]}" | grep -E '^[a-z0-9]' | sort -u)
  for p in $closure; do
    prio=$(apt-cache show "$p" 2>/dev/null | awk -F': ' '/^Priority:/ && !seen {print $2; seen=1}')
    case "$prio" in
      optional|extra) fetch+=("$p") ;;
      *) echo "[fetch-$pool] base tier ($prio), the image carries it: $p" ;;
    esac
  done
  echo "[fetch-$pool] downloading: ${fetch[*]}"
  WORK=$(mktemp -d)
  ( cd "$WORK" && apt-get download "${fetch[@]}" )
  pool_take "$pool" "$dir" "${fetch[@]}"
  echo "[fetch-$pool] pool ready: $dir"
}

if [[ "${1:-}" == --selftest ]]; then
  set +e
  BAD=0
  ok() { echo "SELFTEST OK: $1"; }
  bad() { echo "SELFTEST FAIL: $1"; BAD=$((BAD + 1)); }
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT
  export TMPDIR="$T/tmp"
  mkdir -p "$TMPDIR"

  M="$T/m/tools/fetch/pools/deb"
  mkdir -p "$M"
  cp "$FETCH_TOOLS/fetch.sh" "$FETCH_TOOLS/deb-pool-lib.sh" "$FETCH_TOOLS/deb-pool-fetch-env-lib.sh" \
     "$FETCH_TOOLS/runtime-debs.sh" "$M/"
  BASE=$'sway-debs\tderived\tsway foot\t-\ngnome-debs\tderived\tgnome-shell\tpolkitd\nfix-debs\tlisted\tfoo\t-\n'
  table_case() {
    local name="$1" rows="$2" want_rc="$3" want_text="$4" out rc
    printf '# pool\tmethod\tpackages\tallow-upgrade\n%s' "$rows" > "$M/pools.tsv"
    out=$(bash "$M/fetch.sh" "${@:5}" 2>&1); rc=$?
    if [[ "$rc" == "$want_rc" && "$out" == *"$want_text"* ]]; then
      ok "$name"
    else
      bad "$name: rc=$rc (want $want_rc), want '$want_text' in: $(tr '\n' '|' <<<"$out" | cut -c1-300)"
    fi
  }
  table_case "an unknown pool fails naming it and the pools the table has" "$BASE" 2 \
    "unknown pool 'nope-debs': $M/pools.tsv names sway-debs gnome-debs fix-debs" nope-debs
  table_case "a row of three columns fails naming its line" "$BASE"$'bad-debs\tlisted\tfoo\n' 2 \
    "pools.tsv:5: 3 column(s), not 4 (pool method packages allow-upgrade)" fix-debs
  table_case "a row of five columns fails naming its line" "$BASE"$'bad-debs\tlisted\tfoo\t-\textra\n' 2 \
    "pools.tsv:5: 5 column(s), not 4" fix-debs
  table_case "an unknown method fails naming the pool and the method" "$BASE"$'bad-debs\tsideways\tfoo\t-\n' 2 \
    "pools.tsv:5: pool bad-debs: unknown method 'sideways' (derived, listed or closure)" fix-debs
  table_case "an allow-upgrade on a listed pool fails by name" "$BASE"$'bad-debs\tlisted\tfoo\tbar\n' 2 \
    "pools.tsv:5: pool bad-debs: allow-upgrade is the derived method's; a listed pool takes -" fix-debs
  table_case "an empty package list fails by name" "$BASE"$'bad-debs\tclosure\t\t-\n' 2 \
    "pools.tsv:5: pool bad-debs: packages '' is not a space-separated package list" fix-debs
  table_case "a comma-separated package list fails by name" "$BASE"$'bad-debs\tclosure\tfoo,bar\t-\n' 2 \
    "pools.tsv:5: pool bad-debs: packages 'foo,bar' is not a space-separated package list" fix-debs
  table_case "a pool named twice fails naming both lines" "$BASE"$'fix-debs\tlisted\tbar\t-\n' 2 \
    "pools.tsv:5: pool fix-debs is named twice (first on line 4)" fix-debs
  table_case "a table without the sway row fails before any fetch" $'fix-debs\tlisted\tfoo\t-\n' 2 \
    "unknown pool 'sway-debs'" fix-debs
  table_case "--check on a listed pool is refused, naming its method" "$BASE" 2 \
    "--check is the derived method's; fix-debs is listed" fix-debs --check
  table_case "no pool is a usage error" "$BASE" 2 "usage: fetch.sh <pool> [--check]"
  table_case "a second pool is a usage error" "$BASE" 2 "usage: fetch.sh <pool> [--check]" fix-debs sway-debs

  got=$(awk -F'\t' '!/^#/ && NF { printf "%s:%s ", $1, $2 }' "$FETCH_TOOLS/pools.tsv")
  if problems=$(deb_pool_table_problems "$FETCH_TOOLS/pools.tsv") \
      && [[ "$got" == "adb-debs:derived gnome-debs:derived pipewire-debs:derived sway-debs:derived desktop-debs:listed server-debs:closure stream-debs:closure " ]]; then
    ok "pools.tsv is well formed and names the seven uniform pools with their methods"
  else
    bad "pools.tsv: ${problems:-} rows: $got"
  fi

  deb_pool_fetch_env() { echo "ENV" >> "$T/calls"; }
  deb_pool_fetch() {
    local n
    n=$(grep -c '^FETCH' "$T/calls" 2>/dev/null)
    echo "FETCH $1 [$2] [$3] [$4]" >> "$T/calls"
    if (( n == 0 )); then return "$STUB_FIRST"; else return "$STUB_THEN"; fi
  }
  deb_pool_prune_superseded() { echo "PRUNE $1" >> "$T/calls"; }
  SHARE="$T/share"
  derived_case() {
    local name="$1" mode="$2" want_rc="$3" want_text="$4" rc
    : > "$T/calls"
    ( set -e; fetch_derived p-debs "r1 r2" "u1" "$mode" ); rc=$?
    if [[ "$rc" == "$want_rc" && "$(tr '\n' '|' < "$T/calls")" == "$want_text" ]]; then
      ok "$name"
    else
      bad "$name: rc=$rc (want $want_rc), calls $(tr '\n' '|' < "$T/calls") (want $want_text)"
    fi
  }
  STUB_FIRST=1 STUB_THEN=0 derived_case "derived: a pool short of the derivation is fetched, pruned against its new manifest and checked" "" 0 \
    "ENV|FETCH p-debs [r1 r2] [u1] []|PRUNE $T/share/p-debs|FETCH p-debs [r1 r2] [u1] [--check]|"
  STUB_FIRST=1 STUB_THEN=1 derived_case "derived: the check after the prune still failing is the exit code" "" 1 \
    "ENV|FETCH p-debs [r1 r2] [u1] []|PRUNE $T/share/p-debs|FETCH p-debs [r1 r2] [u1] [--check]|"
  STUB_FIRST=1 STUB_THEN=0 derived_case "derived: --check downloads nothing and prunes nothing" --check 1 \
    "ENV|FETCH p-debs [r1 r2] [u1] [--check]|"
  STUB_FIRST=3 STUB_THEN=0 derived_case "derived: an undeclared upgrade (3) stops before any prune" "" 3 \
    "ENV|FETCH p-debs [r1 r2] [u1] []|"
  STUB_FIRST=0 STUB_THEN=0 derived_case "derived: a pool matching its derivation is fetched once" "" 0 \
    "ENV|FETCH p-debs [r1 r2] [u1] []|"
  unset -f deb_pool_fetch_env deb_pool_fetch deb_pool_prune_superseded

  export STUB_APT_CONFIG="$T/stub-apt.conf"
  deb_pool_fetch_env() { echo "ENV" >> "$STUB_LOG"; export APT_CONFIG="$STUB_APT_CONFIG"; }
  mkdir -p "$T/bin"
  cp "$FETCH_TOOLS/fixtures/apt-get" "$T/bin/apt-get"
  cp "$FETCH_TOOLS/fixtures/apt-cache" "$T/bin/apt-cache"
  chmod +x "$T/bin/apt-get" "$T/bin/apt-cache"
  export STUB_LOG="$T/apt.log"
  method_case() {
    local name="$1" method="$2" pkgs="$3" want_rc="$4" want_files="$5" want_out="$6" out rc
    out=$( ( set -e; PATH="$T/bin:$PATH" "fetch_$method" p-debs "$pkgs" ) 2>&1 ); rc=$?
    if [[ "$rc" == "$want_rc" && "$(LC_ALL=C ls "$T/share/p-debs" 2>/dev/null | tr '\n' ' ')" == "$want_files" && "$out" == *"$want_out"* ]]; then
      ok "$name"
    else
      bad "$name: rc=$rc (want $want_rc), pool [$(ls "$T/share/p-debs" 2>/dev/null | tr '\n' ' ')] (want [$want_files]), out: $(tr '\n' '|' <<<"$out" | cut -c1-300)"
    fi
  }
  rm -rf "$T/share"; : > "$STUB_LOG"
  method_case "listed: downloads exactly the named packages into the pool, naming each sha256" listed "a b" 0 \
    "a_1.0_all.deb b_1.0_all.deb " "[fetch-p-debs] b_1.0_all.deb $(echo b | sha256sum | cut -d' ' -f1)"
  [[ "$(head -1 "$STUB_LOG")" == ENV ]] && ok "listed: sets up the private apt environment before apt runs" \
    || bad "listed: apt ran outside the private apt environment: $(tr '\n' '|' < "$STUB_LOG")"
  : > "$STUB_LOG"
  method_case "listed: a pool holding every named package downloads nothing" listed "a b" 0 \
    "a_1.0_all.deb b_1.0_all.deb " "[fetch-p-debs] already present:"
  [[ ! -s "$STUB_LOG" ]] && ok "listed: the already-present pool never ran apt" || bad "listed: apt ran on a full pool: $(cat "$STUB_LOG")"
  rm -rf "$T/share"
  STUB_MISSING=b method_case "listed: a package apt-get download did not produce fails naming it" listed "a b" 1 \
    "a_1.0_all.deb " "[fetch-p-debs] apt-get download produced no .deb for b"
  rm -rf "$T/share"; : > "$STUB_LOG"
  method_case "closure: downloads the optional tier of the closure and names the base tier it leaves to the image" closure "a b" 0 \
    "a_1.0_all.deb b_1.0_all.deb libopt_1.0_all.deb " "[fetch-p-debs] base tier (required), the image carries it: libreq"
  [[ "$(head -1 "$STUB_LOG")" == ENV ]] && ok "closure: sets up the private apt environment before apt runs" \
    || bad "closure: apt ran outside the private apt environment: $(tr '\n' '|' < "$STUB_LOG")"
  if grep -qx 'apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances a b' "$STUB_LOG" \
      && grep -qx 'apt-get download a b libopt' "$STUB_LOG"; then
    ok "closure: asks apt-cache for the Depends closure alone and downloads only the optional tier"
  else
    bad "closure: apt calls were $(tr '\n' '|' < "$STUB_LOG")"
  fi
  rm -rf "$T/share"
  STUB_MISSING=libopt method_case "closure: a closure package apt-get download did not produce fails naming it" closure "a b" 1 \
    "a_1.0_all.deb b_1.0_all.deb " "[fetch-p-debs] apt-get download produced no .deb for libopt"

  echo "fetch.sh selftest: $( (( BAD )) && echo FAIL || echo OK ) ($BAD failed)"
  exit $(( BAD > 0 ? 1 : 0 ))
fi

# print the usage line and exit 2
usage() { echo "usage: fetch.sh <pool> [--check] | fetch.sh --selftest" >&2; exit 2; }
(( $# >= 1 && $# <= 2 )) || usage
POOL="$1" MODE="${2:-}"
[[ "$POOL" != -* && ( -z "$MODE" || "$MODE" == --check ) ]] || usage
ROW=$(deb_pool_row "$POOL")
IFS=$'\t' read -r METHOD PACKAGES ALLOW <<<"$ROW"
[[ "$ALLOW" == - ]] && ALLOW=""
case "$METHOD" in
  derived) fetch_derived "$POOL" "$PACKAGES" "$ALLOW" "$MODE" ;;
  *)
    [[ -z "$MODE" ]] || { echo "[fetch-$POOL] --check is the derived method's; $POOL is $METHOD" >&2; exit 2; }
    "fetch_$METHOD" "$POOL" "$PACKAGES" ;;
esac
