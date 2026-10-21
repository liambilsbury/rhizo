#!/bin/bash
# test pruning of superseded prepared trees
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/src/install/prepare/prepare.sh"
CLI="$REPO/src/install/cli/rhizo.sh"
LAUNCHER="$REPO/src/androidd/boot.py"

[[ -r "$SRC" ]] || { echo "check-prepared-tree-prune: cannot read $SRC" >&2; exit 1; }
[[ -r "$CLI" ]] || { echo "check-prepared-tree-prune: cannot read $CLI" >&2; exit 1; }
[[ -r "$LAUNCHER" ]] || { echo "check-prepared-tree-prune: cannot read $LAUNCHER" >&2; exit 1; }

# print the definition of a function
extract() {
  sed -n "/^$2() {/,/^}/p" "$1"
}

key_len_lines=$(grep -c 'key_material)\.encode())\.hexdigest()\[:' "$LAUNCHER")
[[ "$key_len_lines" -eq 1 ]] \
  || { echo "check-prepared-tree-prune: FAIL: $LAUNCHER has $key_len_lines line(s) anchored on key_material).encode()).hexdigest()[: , want exactly 1" >&2; exit 1; }
key_len=$(sed -n 's/.*key_material)\.encode())\.hexdigest()\[:\([0-9][0-9]*\)\].*/\1/p' "$LAUNCHER")
[[ "$key_len" =~ ^[0-9]+$ ]] \
  || { echo "check-prepared-tree-prune: FAIL: could not read the prepared-tree key length out of $LAUNCHER (expected a key_material).encode()).hexdigest()[:N] slice)" >&2; exit 1; }
launcher_text="$(cat "$LAUNCHER")"

# repeat a hex digit key_len times
hexstr() {
  local s="" i
  for ((i = 0; i < key_len; i++)); do s+="$1"; done
  printf '%s' "$s"
}
CUR=$(hexstr c)
PREV=$(hexstr b)
OLD=$(hexstr a)

# run prune_prepared on a fixture directory
trial() {
  local fn="$1" tmp outside out
  tmp=$(mktemp -d); outside=$(mktemp -d)
  echo keep > "$outside/precious"
  mkdir -p "$tmp/$CUR/vendor/lib64" "$tmp/$PREV/vendor/lib64" "$tmp/$OLD/vendor/lib64" "$tmp/build.part"
  echo m > "$tmp/$CUR/manifest.json"
  echo m > "$tmp/$PREV/manifest.json"
  echo m > "$tmp/$OLD/manifest.json"
  echo partial > "$tmp/build.part/manifest.json"
  ln -s "$CUR" "$tmp/current"
  ln -s "$CUR" "$tmp/current.tmp"
  ln -s "$outside" "$tmp/stray"

  out=$( ( PREPARED_ROOT="$tmp"; log() { :; }; eval "$fn"; prune_prepared "$PREV" ) 2>&1 )

  [[ -d "$tmp/$OLD" ]] && echo "an old prepared tree at a superseded key was not removed"
  [[ -f "$tmp/$CUR/manifest.json" ]] || echo "the current prepared tree's own content was removed"
  [[ -f "$tmp/$PREV/manifest.json" ]] || echo "the previous prepared tree's own content was removed"
  [[ -L "$tmp/current" ]] || echo "the current symlink itself was removed"
  [[ -d "$tmp/build.part" && -f "$tmp/build.part/manifest.json" ]] \
    || echo "a concurrent prepare's build.part was removed"
  [[ -L "$tmp/current.tmp" ]] || echo "current.tmp was removed"
  [[ -L "$tmp/stray" ]] || echo "a stray symlink under PREPARED_ROOT was removed"
  [[ -f "$outside/precious" ]] \
    || echo "a file outside PREPARED_ROOT, reached only through a symlink, was removed"
  [[ -z "$out" ]] || echo "prune_prepared printed: $out"
  rm -rf "$tmp" "$outside"

  tmp=$(mktemp -d)
  mkdir -p "$tmp/$CUR" "$tmp/$PREV"
  echo m > "$tmp/$CUR/manifest.json"
  echo m > "$tmp/$PREV/manifest.json"
  ln -s "$CUR" "$tmp/current"
  ( PREPARED_ROOT="$tmp"; log() { :; }; eval "$fn"; prune_prepared "$tmp/$PREV" ) >/dev/null 2>&1
  [[ -f "$tmp/$PREV/manifest.json" ]] \
    || echo "a keep_prev argument that was a raw absolute path did not protect the real previous tree's content"
  rm -rf "$tmp"

  tmp=$(mktemp -d)
  mkdir -p "$tmp/$OLD"; echo m > "$tmp/$OLD/manifest.json"
  ( PREPARED_ROOT="$tmp"; log() { :; }; eval "$fn"; prune_prepared "" )
  [[ -f "$tmp/$OLD/manifest.json" ]] || echo "a tree was removed with no current symlink set"
  rm -rf "$tmp"
}

# run prune_prepared on a same-key fixture
trial_samekey() {
  local fn="$1" tmp out older newer keep_prev_arg
  older=$(hexstr d); newer=$(hexstr e)
  for keep_prev_arg in "$CUR" ""; do
    tmp=$(mktemp -d)
    mkdir -p "$tmp/$CUR" "$tmp/$older" "$tmp/$newer"
    echo m > "$tmp/$CUR/manifest.json"
    echo m > "$tmp/$older/manifest.json"; touch -d '2 days ago' "$tmp/$older"
    echo m > "$tmp/$newer/manifest.json"; touch -d '1 hour ago' "$tmp/$newer"
    ln -s "$CUR" "$tmp/current"

    out=$( ( PREPARED_ROOT="$tmp"; log() { :; }; eval "$fn"; prune_prepared "$keep_prev_arg" ) 2>&1 )

    [[ -d "$tmp/$newer" ]] \
      || echo "the newest other prepared tree was not kept as a rollback target on a same-key re-prepare (keep_prev='$keep_prev_arg')"
    [[ -d "$tmp/$older" ]] \
      && echo "an older prepared tree survived a same-key re-prepare instead of being pruned (keep_prev='$keep_prev_arg')"
    [[ -f "$tmp/$CUR/manifest.json" ]] \
      || echo "the current tree's own content was removed on a same-key re-prepare (keep_prev='$keep_prev_arg')"
    [[ -z "$out" ]] || echo "prune_prepared printed: $out (keep_prev='$keep_prev_arg')"
    rm -rf "$tmp"
  done
}

# check the key filter in prune_prepared
key_format_ok() {
  local want; want=$(printf '=~ ^[0-9a-f]{%s}$ ]]' "$key_len")
  grep -qF "$want" <<<"$1"
}

# run prepare_tree with stubs and trace prune_prepared
trace_prune_called() {
  local body="$1" mode="$2" py_key r
  case "$mode" in
    ok) py_key=222222222222 ;;
    fail) py_key="" ;;
    samekey) py_key=111111111111 ;;
  esac
  r=$( (
    # shellcheck disable=SC2034
    PAYLOAD=/nonexistent PREPARED_ROOT=/nonexistent
    log() { :; }; mark_change() { :; }
    refuse() { echo REFUSE; exit 1; }
    failstop() { echo FAILSTOP; exit 1; }
    prune_prepared() { echo PRUNE_CALLED; }
    bash() { echo virgl; }
    readlink() { echo 111111111111; }
    configured_selinux_mode() { echo namespace; }
    if [[ -n "$py_key" ]]; then
      python3() { echo "PREPARE_TREE_OK key=$py_key inputs=1 outputs=1"; }
    else
      python3() { return 1; }
    fi
    eval "$body"
    prepare_tree
  ) 2>/dev/null )
  grep -qF PRUNE_CALLED <<<"$r"
}

# compare the prune_prepared and prepare_tree line numbers
def_call_order_ok() {
  local def_line call_line
  def_line=$(grep -n '^prune_prepared() {' <<<"$1" | cut -d: -f1 | head -1)
  call_line=$(grep -n '^(( RESUME )) || prepare_tree\([[:space:]]\|$\)' <<<"$1" | cut -d: -f1 | head -1)
  [[ -n "$def_line" && -n "$call_line" && "$def_line" -lt "$call_line" ]]
}

# trace prune_prepared calls in prepare_tree
wiring() {
  local t="$1"
  trace_prune_called "$t" ok \
    || echo "prune_prepared never runs on a successful prepare_tree"
  trace_prune_called "$t" fail \
    && echo "prune_prepared runs even when prepare_tree fails"
  trace_prune_called "$t" samekey \
    || echo "prune_prepared never runs when the prepared-tree key did not change from a same-key re-prepare"
}

cli_allow=(
  'PREPARED_ROOT="$STATE_DIR/prepared"'
  'STATE_DIR="${RHIZO_STATE_DIR:-/var/lib/rhizo}"'
)
# report destructive uses of PREPARED_ROOT in rhizo.sh
cli_guard() {
  destructive_verb() {
    grep -qE '\b(rm|rmdir|unlink|mv)\b|\bfind\b[^|;]*-delete\b|-exec[[:space:]]+rm\b|\btruncate\b|[^>]>[[:space:]]*"?\$|:[[:space:]]*>[[:space:]]*"?\$' <<<"$1"
    }
  taint_vars() {
    local ln seg
    while IFS= read -r ln; do
      while IFS= read -r seg; do
        [[ "$seg" =~ ^[[:space:]]*(local|declare|readonly)?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*(PREPARED_ROOT|STATE_DIR|prepared) ]] \
          && echo "${BASH_REMATCH[2]}"
      done < <(tr ';' '\n' <<<"$ln")
    done <<<"$1" | sort -u
    }
  mentions_trigger() {
    [[ "$1" == *PREPARED_ROOT* || "$1" == *STATE_DIR* || "$1" == *prepared* ]] && return 0
    [[ -n "$2" ]] && grep -qE '\$\{?('"$2"')\}?' <<<"$1"
    }
  func_body() { sed -n "/^$2() {/,/^}/p" <<<"$1"; }
  opens_multiline_func() {
    local line="$1"
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]\{ ]] || return 1
    line="${line%%[[:space:]]#*}"
    [[ "$line" =~ \}[[:space:]]*$ ]] && return 1
    return 0
    }
  func_names() {
    local line
    while IFS= read -r line; do
      opens_multiline_func "$line" || continue
      line="${line%%(*}"; echo "$line"
    done <<<"$1"
    }
  top_level_text() {
    local line skip=0
    while IFS= read -r line; do
      if (( skip )); then [[ "$line" == "}" ]] && skip=0; continue; fi
      opens_multiline_func "$line" && { skip=1; continue; }
      printf '%s\n' "$line"
    done <<<"$1"
    }
  calls_destructive_helper() {
    local line d rest re
    while IFS= read -r line; do
      while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        re="((^|[;&|])[[:space:]]*|\b(do|then|else|if|while|until|!)[[:space:]]+)$d([[:space:]]|\$)"
        [[ "$line" =~ $re ]] || continue
        rest="${line/$d/}"
        mentions_trigger "$rest" "$3" && return 0
      done <<<"$2"
    done <<<"$1"
    return 1
    }
  is_destructive() {
    destructive_verb "$1" && return 0
    calls_destructive_helper "$1" "$2" "$3"
    }
  local scope_allow=(
    'gc_templates|rm -f "$f" && log "removed old data template $(basename "$f")"'
  )
  local stripped line fname body a ok remainder func_tvars top_text top_tvars
  stripped="$(grep -v '^[[:space:]]*#' <<<"$1")"

  local destructive_funcs="" dfname dbody
  while IFS= read -r dfname; do
    [[ -n "$dfname" ]] || continue
    dbody="$(func_body "$stripped" "$dfname")"
    destructive_verb "$dbody" && destructive_funcs+="$dfname"$'\n'
  done < <(func_names "$stripped")

  while IFS= read -r line; do
    [[ "$line" =~ ^(PREPARED_ROOT|STATE_DIR)= ]] || continue
    ok=0
    for a in "${cli_allow[@]}"; do [[ "$line" == "$a" ]] && { ok=1; break; }; done
    (( ok )) || echo "src/install/cli/rhizo.sh's definition of PREPARED_ROOT or STATE_DIR does not match the expected line exactly: $line"
  done <<<"$stripped"

  while IFS= read -r fname; do
    [[ -n "$fname" ]] || continue
    body="$(func_body "$stripped" "$fname")"
    func_tvars="$(taint_vars "$body" | paste -sd'|' -)"
    mentions_trigger "$body" "$func_tvars" || continue
    is_destructive "$body" "$destructive_funcs" "$func_tvars" || continue
    ok=0
    for a in "${scope_allow[@]}"; do
      if [[ "$fname" == "${a%%|*}" && "$body" == *"${a#*|}"* ]]; then
        remainder="${body/${a#*|}/}"
        is_destructive "$remainder" "$destructive_funcs" "$func_tvars" || ok=1
        break
      fi
    done
    (( ok )) || echo "src/install/cli/rhizo.sh's $fname() touches PREPARED_ROOT/STATE_DIR/prepared and also destroys bytes in the same scope"
  done < <(func_names "$stripped")

  top_text="$(top_level_text "$stripped")"
  top_tvars="$(taint_vars "$top_text" | paste -sd'|' -)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    mentions_trigger "$line" "$top_tvars" || continue
    is_destructive "$line" "$destructive_funcs" "$top_tvars" || continue
    echo "src/install/cli/rhizo.sh has a top-level line touching PREPARED_ROOT/STATE_DIR/prepared and destroying bytes: $line"
  done <<<"$top_text"
}

fn="$(extract "$SRC" prune_prepared)"
if [[ -z "$fn" ]]; then
  echo "check-prepared-tree-prune: FAIL: no prune_prepared() function in $SRC" >&2
  exit 1
fi
tree_fn="$(extract "$SRC" prepare_tree)"
if [[ -z "$tree_fn" ]]; then
  echo "check-prepared-tree-prune: FAIL: no prepare_tree() function in $SRC to check the wiring of" >&2
  exit 1
fi
cli_text="$(cat "$CLI")"
src_text="$(cat "$SRC")"

# run all prune_prepared checks
check_all() {
  trial "$1"
  trial_samekey "$1"
  key_format_ok "$1" || echo "prune_prepared's key-format filter is not anchored to exactly {$key_len} hex characters (src/androidd/boot.py's own key length)"
  wiring "$2"
  def_call_order_ok "$4" || echo "prune_prepared() is defined at or after the top-level (( RESUME )) || prepare_tree call site"
  cli_guard "$3"
}

if [[ "${1:-}" == --selftest ]]; then
  expect() {
    grep -qxF "$2" <<<"$3" || { echo "check-prepared-tree-prune: FAIL selftest: $1 was not flagged: ${3:-<no finding>}" >&2; exit 1; }
  }
  mutate() {
    [[ "$3" != "$2" ]] || { echo "check-prepared-tree-prune: FAIL selftest: could not build the $1 mutant" >&2; exit 1; }
  }

  noop=$(sed 's/rm -rf "\$d" && log/: no-op #/' <<<"$fn"); mutate "no-op prune" "$fn" "$noop"
  expect "a no-op prune" "an old prepared tree at a superseded key was not removed" "$(trial "$noop")"

  drops_cur=$(sed 's/"\$name" == "\$cur" || //' <<<"$fn"); mutate "deletes current" "$fn" "$drops_cur"
  expect "a prune that deletes the current tree's content" "the current prepared tree's own content was removed" "$(trial "$drops_cur")"

  drops_prev=$(sed 's/ || "\$name" == "\$keep_prev"//' <<<"$fn"); mutate "deletes previous" "$fn" "$drops_prev"
  expect "a prune that deletes the previous tree's content" "the previous prepared tree's own content was removed" "$(trial "$drops_prev")"

  no_fallback=$(awk '
    /^  if \[\[ -z "\$keep_prev" \|\| "\$keep_prev" == "\$cur" \]\]; then$/ { skip=1 }
    skip && /^  fi$/ { skip=0; next }
    skip { next }
    { print }
  ' <<<"$fn")
  mutate "same-key mtime fallback dropped" "$fn" "$no_fallback"
  expect "a prune with no same-key mtime fallback" "the newest other prepared tree was not kept as a rollback target on a same-key re-prepare (keep_prev='$CUR')" "$(trial_samekey "$no_fallback")"

  no_basename=$(grep -v 'keep_prev=\$(basename -- "\$keep_prev")' <<<"$fn")
  mutate "keep_prev basename normalization dropped" "$fn" "$no_basename"
  expect "a keep_prev that is a raw absolute path, with no basename normalization" "a keep_prev argument that was a raw absolute path did not protect the real previous tree's content" "$(trial "$no_basename")"

  noguard=$(sed -e '/^    \[\[ -L /d' \
                 -e '/\[\[ "\$name" =~ \^\[0-9a-f\]/d' \
                 -e 's#"\$PREPARED_ROOT"/\*;#"$PREPARED_ROOT"/*/;#' <<<"$fn")
  mutate "no symlink/format guard" "$fn" "$noguard"
  expect "a prune with no symlink guard and no key-format filter" "the current prepared tree's own content was removed" "$(trial "$noguard")"

  gc_prepared_908402d2='prune_prepared() {  # prune_prepared <key-to-also-keep-besides-current>
  local keep_prev="$1" cur="" d name
  [[ -L "$PREPARED_ROOT/current" ]] && cur=$(readlink "$PREPARED_ROOT/current")
  [[ -n "$cur" ]] || return 0
  for d in "$PREPARED_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    name=$(basename "$d")
    [[ "$name" == "$cur" || "$name" == "$keep_prev" ]] && continue
    rm -rf "$d" && log "  pruned old prepared tree $name"
  done
}'
  expect "908402d2 src/install/cli/rhizo.sh's gc_prepared (renamed)" "the current prepared tree's own content was removed" "$(trial "$gc_prepared_908402d2")"

  key_check() { key_format_ok "$1" || echo "prune_prepared's key-format filter is not anchored to exactly {$key_len} hex characters (src/androidd/boot.py's own key length)"; }
  want_key_finding="prune_prepared's key-format filter is not anchored to exactly {$key_len} hex characters (src/androidd/boot.py's own key length)"

  loosened_open=$(sed 's/=~ \^\[0-9a-f\]{'"$key_len"'}\$ \]\]/=~ ^[0-9a-f]{'"$key_len"',}$ ]]/' <<<"$fn")
  mutate "key filter with an open-ended count" "$fn" "$loosened_open"
  expect "a key filter with an open-ended {N,} count" "$want_key_finding" "$(key_check "$loosened_open")"

  loosened_unanchored=$(sed 's/=~ \^\[0-9a-f\]{'"$key_len"'}\$ \]\]/=~ [0-9a-f]{'"$key_len"'} ]]/' <<<"$fn")
  mutate "key filter with no anchors" "$fn" "$loosened_unanchored"
  expect "a key filter with no ^\$ anchors" "$want_key_finding" "$(key_check "$loosened_unanchored")"

  loosened_any=$(sed 's/=~ \^\[0-9a-f\]{'"$key_len"'}\$ \]\]/=~ ^[0-9a-f]+$ ]]/' <<<"$fn")
  mutate "key filter accepting any length of hex" "$fn" "$loosened_any"
  expect "a key filter accepting any length of hex" "$want_key_finding" "$(key_check "$loosened_any")"

  p20_launcher=$(printf '_CACHE_TAG = lambda b: __import__("hashlib").sha1(b).hexdigest()[:12]\n%s' \
    "$(sed 's/key_material)\.encode())\.hexdigest()\[:12\]/key_material).encode()).hexdigest()[:16]/' <<<"$launcher_text")")
  mutate "decoy hexdigest slice plus the real key moved to 16" "$launcher_text" "$p20_launcher"
  p20_file=$(mktemp)
  printf '%s\n' "$p20_launcher" > "$p20_file"
  p20_n=$(grep -c 'key_material)\.encode())\.hexdigest()\[:' "$p20_file")
  p20_len=$(sed -n 's/.*key_material)\.encode())\.hexdigest()\[:\([0-9][0-9]*\)\].*/\1/p' "$p20_file")
  rm -f "$p20_file"
  [[ "$p20_n" -eq 1 && "$p20_len" == 16 ]] \
    || { echo "check-prepared-tree-prune: FAIL selftest: the key-length reader misread a decoy-plus-real-at-16 file -- got n=$p20_n len=$p20_len, want n=1 len=16" >&2; exit 1; }

  removed=$(grep -v 'prune_prepared "\$prev_key"' <<<"$tree_fn"); mutate "call removed" "$tree_fn" "$removed"
  expect "a removed prune call" "prune_prepared never runs on a successful prepare_tree" "$(wiring "$removed")"

  moved=$(awk '/prune_prepared "\$prev_key"/ { next } { print } /^  KEY=\$\(sed -n/ { print "  prune_prepared \"$prev_key\"" }' <<<"$tree_fn")
  mutate "call moved before the failure check" "$tree_fn" "$moved"
  expect "a prune call moved before the failure check" "prune_prepared runs even when prepare_tree fails" "$(wiring "$moved")"

  commented=$(sed 's/^  prune_prepared "\$prev_key"$/  # the next release adds prune_prepared "$prev_key" here/' <<<"$tree_fn")
  mutate "call moved into a comment" "$tree_fn" "$commented"
  expect "a prune call that only exists in a comment" "prune_prepared never runs on a successful prepare_tree" "$(wiring "$commented")"

  dead=$(sed 's/^  prune_prepared "\$prev_key"$/  false \&\& prune_prepared "$prev_key"/' <<<"$tree_fn")
  mutate "call made dead" "$tree_fn" "$dead"
  expect "a prune call made unreachable behind false &&" "prune_prepared never runs on a successful prepare_tree" "$(wiring "$dead")"

  inside_if=$(awk '
    /^  prune_prepared "\$prev_key"$/ { next }
    { print }
    /^    failstop "prepare-tree-failed"/ { print "  prune_prepared \"$prev_key\"" }
  ' <<<"$tree_fn")
  mutate "call moved inside the failure if-block" "$tree_fn" "$inside_if"
  expect "a prune call moved inside the failure if-block, after failstop" "prune_prepared never runs on a successful prepare_tree" "$(wiring "$inside_if")"

  dead_if=$(sed 's/^  prune_prepared "\$prev_key"$/  if (( 0 )); then\n  prune_prepared "$prev_key"\n  fi/' <<<"$tree_fn")
  mutate "call wrapped in an always-false if" "$tree_fn" "$dead_if"
  expect "a prune call wrapped in an always-false if (( 0 ))" "prune_prepared never runs on a successful prepare_tree" "$(wiring "$dead_if")"

  def_after=$(awk '
    /^prune_prepared\(\) \{/ { infn=1 }
    infn { buf = buf $0 "\n"; if ($0 == "}") { infn=0; next }; next }
    { print }
    /^TREE_DIR="\$PREPARED_ROOT\/\$KEY"$/ { printf "%s", buf }
  ' <<<"$src_text")
  mutate "prune_prepared defined after its call site" "$src_text" "$def_after"
  def_order_check() { def_call_order_ok "$1" && echo ok || echo "prune_prepared() is defined at or after the top-level (( RESUME )) || prepare_tree call site"; }
  expect "prune_prepared() moved to be defined after (( RESUME )) || prepare_tree" "prune_prepared() is defined at or after the top-level (( RESUME )) || prepare_tree call site" "$(def_order_check "$def_after")"

  same_key_skip=$(awk '
    /^  \[\[ "\$KEY" != "\$prev_key" \]\] && mark_change/ { print; print "  [[ \"$KEY\" == \"$prev_key\" ]] && return 0"; next }
    { print }
  ' <<<"$tree_fn")
  mutate "prune skipped on a same-key re-prepare" "$tree_fn" "$same_key_skip"
  expect "prune skipped whenever the key did not change" "prune_prepared never runs when the prepared-tree key did not change from a same-key re-prepare" "$(wiring "$same_key_skip")"

  reintroduced=$(printf '%s\nsweep_p() { while read -r d; do rm -rf "$d"; done < <(ls -d "$PREPARED_ROOT"/*/); }\n' "$cli_text")
  mutate "rhizo.sh regains a removal loop" "$cli_text" "$reintroduced"
  expect "rhizo.sh with a reintroduced PREPARED_ROOT-touching line, a different shape entirely" "src/install/cli/rhizo.sh has a top-level line touching PREPARED_ROOT/STATE_DIR/prepared and destroying bytes: sweep_p() { while read -r d; do rm -rf \"\$d\"; done < <(ls -d \"\$PREPARED_ROOT\"/*/); }" "$(cli_guard "$reintroduced")"

  aliased=$(printf '%s\nTREES="$STATE_DIR/prep""ared"\nsweep_p() { rm -rf "$TREES"/*/; }\n' "$cli_text")
  mutate "rhizo.sh regains a removal loop via a one-hop alias" "$cli_text" "$aliased"
  expect "an alias variable used destructively" "src/install/cli/rhizo.sh has a top-level line touching PREPARED_ROOT/STATE_DIR/prepared and destroying bytes: sweep_p() { rm -rf \"\$TREES\"/*/; }" "$(cli_guard "$aliased")"

  gc_prepared_scope=$(printf '%s\ngc_prepared() {\n  local keep_prev="$1" cur="" d name\n  [[ -L "$PREPARED_ROOT/current" ]] && cur=$(readlink "$PREPARED_ROOT/current")\n  [[ -n "$cur" ]] || return 0\n  for d in "$PREPARED_ROOT"/*/; do\n    [[ -d "$d" ]] || continue\n    name=$(basename "$d")\n    [[ "$name" == "$cur" || "$name" == "$keep_prev" ]] && continue\n    rm -rf "$d" && log "gc: removed old prepared tree $name"\n  done\n}\n' "$cli_text")
  mutate "908402d2's gc_prepared reintroduced as a whole function" "$cli_text" "$gc_prepared_scope"
  expect "a reintroduced multi-line gc_prepared function" "src/install/cli/rhizo.sh's gc_prepared() touches PREPARED_ROOT/STATE_DIR/prepared and also destroys bytes in the same scope" "$(cli_guard "$gc_prepared_scope")"

  log_only=$(sed 's/^    gc_templates "\$template_key"$/    log "prepared trees are pruned by prepare.sh"\n&/' <<<"$cli_text")
  mutate "a read-only log line mentioning prepared" "$cli_text" "$log_only"
  out="$(cli_guard "$log_only")"
  [[ -z "$out" ]] || { echo "check-prepared-tree-prune: FAIL selftest: cli_guard flagged a read-only log line: $out" >&2; exit 1; }

  commented_cli=$(printf '%s\n# for d in "$PREPARED_ROOT"/*/; do rm -rf "$d"; done\n' "$cli_text")
  out="$(cli_guard "$commented_cli")"
  [[ -z "$out" ]] || { echo "check-prepared-tree-prune: FAIL selftest: cli_guard flagged a commented-out loop: $out" >&2; exit 1; }

  out="$(check_all "$fn" "$tree_fn" "$cli_text" "$src_text")"
  [[ -z "$out" ]] || { echo "check-prepared-tree-prune: FAIL selftest: the real source was flagged: $out" >&2; exit 1; }
  echo "check-prepared-tree-prune selftest: 21 mutants caught (no-op prune, deletes current's content, deletes previous's content, same-key mtime fallback dropped, keep_prev basename normalization dropped, no symlink/format guard, 908402d2 gc_prepared shape, open-ended key count, unanchored key filter, any-length hex filter, key-length reader misled by a decoy hexdigest slice, call removed, call moved before the failure check, call moved into a comment, call made dead, call moved inside the failure if-block, call wrapped in an always-false if, prune_prepared defined after its call site, prune skipped on a same-key re-prepare, rhizo.sh loop reintroduced with a different shape, the same loop via a one-hop alias, 908402d2's gc_prepared reintroduced whole), a read-only log line and a commented-out cli loop correctly ignored, the real source clean"
  exit 0
fi

out="$(check_all "$fn" "$tree_fn" "$cli_text" "$src_text")"
RC=0
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  echo "check-prepared-tree-prune: FAIL: $l" >&2
  RC=1
done <<<"$out"
(( RC )) || echo "prepare.sh prunes a prepared tree at a superseded key itself, on every successful prepare including a same-key re-prepare (which keeps the newest other generation by mtime) and never on a failed one, without touching a symlink or a name shaped anything but exactly {$key_len} hex characters; prune_prepared() is defined before it is called; and no recognized scope of rhizo.sh pairs a prepared-tree trigger with a destructive verb or a one-hop destructive helper call"
exit "$RC"
