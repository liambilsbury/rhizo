#!/bin/bash
# deb pool fetch helpers
DEB_POOL_FETCH_ENV_TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./runtime-debs.sh
source "$DEB_POOL_FETCH_ENV_TOOLS/runtime-debs.sh"

# set APT_CONFIG to the private apt environment
deb_pool_fetch_env() {
  rrd_online_env "$1" || return 2
  export APT_CONFIG="$RRD_APT_CONFIG"
}

# delete .debs missing from the pool manifest
deb_pool_prune_superseded() {
  local pool="$1" manifest="$1/MANIFEST.tsv" name share dir where f base
  [[ -f "$manifest" ]] || { echo "[deb-pool-fetch-env] no $manifest to prune $pool against" >&2; return 2; }
  name=$(basename "$pool")
  share=$(dirname "$pool")
  local -a dirs=("$pool")
  if [[ "$(basename "$share")" == share ]]; then
    for dir in "$(dirname "$share")"/share-*/"$name"; do [[ -d "$dir" ]] && dirs+=("$dir"); done
  fi
  for dir in "${dirs[@]}"; do
    where=""
    [[ "$dir" == "$pool" ]] || where=" from $dir"
    for f in "$dir"/*.deb; do
      [[ -e "$f" ]] || continue
      base=$(basename "$f")
      awk -F'\t' -v b="$base" 'NR > 1 && $5 == b { found = 1 } END { exit !found }' "$manifest" && continue
      rm -f -- "$f" || { echo "[deb-pool-fetch-env] could not remove $base$where, which $manifest no longer names" >&2; return 2; }
      echo "[deb-pool-fetch-env] removed $base$where: $manifest no longer names it"
    done
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" && "${1:-}" == "--selftest" ]]; then
  set -uo pipefail
  BAD=0
  ok() { echo "SELFTEST OK: $1"; }
  bad() { echo "SELFTEST FAIL: $1"; BAD=$((BAD + 1)); }
  T=$(mktemp -d) || exit 1
  trap 'rm -rf "$T"' EXIT

  rrd_online_env() { RRD_APT_CONFIG="$T/stub-apt.conf"; : > "$RRD_APT_CONFIG"; return 0; }
  unset APT_CONFIG
  if deb_pool_fetch_env "$T/env" && [[ "$APT_CONFIG" == "$T/stub-apt.conf" ]]; then
    ok "deb_pool_fetch_env exports APT_CONFIG from rrd_online_env's own RRD_APT_CONFIG on success"
  else
    bad "deb_pool_fetch_env on a successful rrd_online_env: APT_CONFIG=${APT_CONFIG:-<unset>}"
  fi
  rrd_online_env() { return 2; }
  unset APT_CONFIG
  if ! deb_pool_fetch_env "$T/env" 2>/dev/null && [[ -z "${APT_CONFIG:-}" ]]; then
    ok "deb_pool_fetch_env propagates rrd_online_env's own failure and exports nothing"
  else
    bad "deb_pool_fetch_env swallowed a failing rrd_online_env: APT_CONFIG=${APT_CONFIG:-<unset>}"
  fi
  unset -f rrd_online_env

  P="$T/pool"; mkdir -p "$P"
  : > "$P/kept_1.0_all.deb"
  : > "$P/old_0.9_all.deb"
  printf 'package\tversion\tarch\tsha256\tfile\nkept\t1.0\tall\tdeadbeef\tkept_1.0_all.deb\n' > "$P/MANIFEST.tsv"
  out=$(deb_pool_prune_superseded "$P"); rc=$?
  if (( rc == 0 )) && [[ -f "$P/kept_1.0_all.deb" && ! -e "$P/old_0.9_all.deb" ]] \
      && [[ "$out" == "[deb-pool-fetch-env] removed old_0.9_all.deb: $P/MANIFEST.tsv no longer names it" ]]; then
    ok "deb_pool_prune_superseded removes and names a .deb its manifest no longer lists, and keeps one it does"
  else
    bad "deb_pool_prune_superseded on a pool with one superseded file: rc=$rc out=$out $(ls "$P" | tr '\n' ' ')"
  fi
  out=$(deb_pool_prune_superseded "$P" 2>&1); rc=$?
  if (( rc == 0 )) && [[ -z "$out" ]]; then
    ok "deb_pool_prune_superseded is quiet on a pool that already matches its manifest"
  else
    bad "deb_pool_prune_superseded on an already-clean pool: rc=$rc out=$out"
  fi
  S="$T/share/vmpool"; L="$T/share-1/vmpool"; mkdir -p "$S" "$L"
  : > "$S/kept_1.0_all.deb"; : > "$L/kept_1.0_all.deb"; : > "$L/old_0.9_all.deb"
  printf 'package\tversion\tarch\tsha256\tfile\nkept\t1.0\tall\tdeadbeef\tkept_1.0_all.deb\n' > "$S/MANIFEST.tsv"
  out=$(deb_pool_prune_superseded "$S"); rc=$?
  if (( rc == 0 )) && [[ -f "$L/kept_1.0_all.deb" && ! -e "$L/old_0.9_all.deb" ]] \
      && [[ "$out" == "[deb-pool-fetch-env] removed old_0.9_all.deb from $L: $S/MANIFEST.tsv no longer names it" ]]; then
    ok "deb_pool_prune_superseded prunes each vm's share-N copy against share/'s manifest, which sync.sh never does"
  else
    bad "deb_pool_prune_superseded left a vm copy's superseded file: rc=$rc out=$out $(ls "$L" | tr '\n' ' ')"
  fi

  rm -f "$P/MANIFEST.tsv"
  out=$(deb_pool_prune_superseded "$P" 2>&1); rc=$?
  if (( rc == 2 )) && [[ "$out" == "[deb-pool-fetch-env] no $P/MANIFEST.tsv to prune $P against" ]] && [[ -f "$P/kept_1.0_all.deb" ]]; then
    ok "deb_pool_prune_superseded refuses, removing nothing, a pool with no MANIFEST.tsv to prune against"
  else
    bad "deb_pool_prune_superseded on a pool with no manifest: rc=$rc out=$out"
  fi

  echo "deb-pool-fetch-env-lib selftest: $( (( BAD )) && echo FAIL || echo OK ) ($BAD failed)"
  exit $(( BAD > 0 ? 1 : 0 ))
fi
