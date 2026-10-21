#!/bin/bash
# test the zip cleanup in fetch-gsi.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/src/install/prepare/fetch-gsi.sh"

[[ -r "$SRC" ]] || { echo "check-gsi-cache-cleanup: cannot read $SRC" >&2; exit 1; }

# extract cleanup_gsi_zip_cache from the script text
extract_fn() {
  sed -n '/^cleanup_gsi_zip_cache() {/,/^}/p' <<<"$1"
}

# drop cleanup_gsi_zip_cache, the usage text and comment lines
outside_fn() {
  awk '/^(cleanup_gsi_zip_cache|usage)\(\) \{/{skip=1} skip{ if (/^}/) {skip=0}; next } { print }' <<<"$1" \
    | grep -v '^[[:space:]]*#'
}

# run cleanup_gsi_zip_cache on fixture zip files
trial() {
  local fn="$1" tmp zip out
  tmp=$(mktemp -d)
  zip="$tmp/gsi_a16.zip"

  : > "$zip"
  ( eval "$fn"; cleanup_gsi_zip_cache "$zip" "" )
  [[ -e "$zip" ]] && echo "an ordinary cached zip was not removed"

  : > "$zip"
  ( eval "$fn"; cleanup_gsi_zip_cache "$zip" "$zip" )
  [[ -e "$zip" ]] || echo "a --from-zip file was removed -- it is the caller's, not the cache's"

  rm -f "$zip"
  out=$( ( eval "$fn"; cleanup_gsi_zip_cache "$zip" "" ) 2>&1 )
  [[ -z "$out" ]] || echo "calling it with no cached zip printed: $out"

  rm -rf "$tmp"
}

# check the already-staged path runs cleanup_gsi_zip_cache
fastpath_ok() {
  grep -qE '^staged && \{ log "\$TREE is already staged"; derive_gsi_libs; cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"; echo "RHIZO_GSI_ALREADY_STAGED=1"; exit 0; \}$' <<<"$1"
}

# check cleanup_gsi_zip_cache follows the rename's sync
new_stage_ok() {
  local t="$1" mv_line sync_line call_line
  mv_line=$(grep -n '^mv "\$TREE\.part" "\$TREE" || failstop' <<<"$t" | cut -d: -f1 | head -1)
  [[ -n "$mv_line" ]] || return 1
  sync_line=$((mv_line + 1))
  [[ "$(sed -n "${sync_line}p" <<<"$t")" == "sync" ]] || return 1
  call_line=$((sync_line + 1))
  [[ "$(sed -n "${call_line}p" <<<"$t")" == 'cleanup_gsi_zip_cache "$ZIP" "$FROM_ZIP"' ]]
}

# check the number of cleanup_gsi_zip_cache calls
call_count_ok() {
  local n; n=$(grep -c 'cleanup_gsi_zip_cache ' <<<"$1")
  [[ "$n" -eq 2 ]]
}

# count the already-staged markers in the text
marker_count_ok() {
  local n; n=$(grep -c 'RHIZO_GSI_ALREADY_STAGED=1' <<<"$1")
  [[ "$n" -eq 1 ]]
}

mapfile -t zip_allow <<'ALLOWLIST'
FROM_ZIP=""
    --from-zip) FROM_ZIP="${2:-}"; shift 2 ;;
ZIP="$CACHE/gsi_$RELEASE.zip"
staged && { log "$TREE is already staged"; derive_gsi_libs; cleanup_gsi_zip_cache "$ZIP" "$FROM_ZIP"; echo "RHIZO_GSI_ALREADY_STAGED=1"; exit 0; }
command -v curl >/dev/null 2>&1 || [[ -n "$FROM_ZIP" ]] || refuse "no-curl" "curl is required to download the image"
if [[ -n "$FROM_ZIP" ]]; then
  [[ -f "$FROM_ZIP" ]] || refuse "no-such-zip" "--from-zip '$FROM_ZIP' does not exist"
  have=$(sha256sum "$FROM_ZIP" | cut -d' ' -f1)
  [[ "$have" == "$WANT" ]] || failstop "sha256-mismatch" "$FROM_ZIP is $have, the pin is $WANT"
  ZIP="$FROM_ZIP"
  log "using $ZIP (its sha256 is still checked against the pin below)"
elif [[ -f "$ZIP" ]] && [[ "$(sha256sum "$ZIP" | cut -d' ' -f1)" == "$WANT" ]]; then
  curl -fsS -L --retry 3 --retry-delay 5 -o "$ZIP.part" "${GSI_URL[$RELEASE]}" \
  mv "$ZIP.part" "$ZIP"
have=$(sha256sum "$ZIP" | cut -d' ' -f1)
[[ "$have" == "$WANT" ]] || failstop "sha256-mismatch" "$ZIP is $have, the pin is $WANT"
python3 - "$ZIP" "$TMP/system.img" <<'PYEOF' || failstop "extract-failed" "system.img is not in the archive"
cleanup_gsi_zip_cache "$ZIP" "$FROM_ZIP"
ALLOWLIST
# report disallowed ZIP and FROM_ZIP uses
zip_guard() {
  local line ok a
  while IFS= read -r line; do
    grep -qE '\$\{?(ZIP|FROM_ZIP)\}?|\bZIP=|\bFROM_ZIP=' <<<"$line" || continue
    ok=0
    for a in "${zip_allow[@]}"; do [[ "$line" == "$a" ]] && { ok=1; break; }; done
    (( ok )) || echo "a line outside cleanup_gsi_zip_cache touches \$ZIP or \$FROM_ZIP and is not on the allowlist: $line"
  done <<<"$1"
}

whole="$(cat "$SRC")"
fn="$(extract_fn "$whole")"
if [[ -z "$fn" ]]; then
  echo "check-gsi-cache-cleanup: FAIL: no cleanup_gsi_zip_cache() function in $SRC to test" >&2
  exit 1
fi
outside="$(outside_fn "$whole")"

# run the wiring checks and print findings
check_wiring() {
  local o="$1"
  fastpath_ok "$o" || echo "the already-staged fast path does not call cleanup_gsi_zip_cache before its exit 0"
  new_stage_ok "$o" || echo "the new-stage cleanup call is not the statement immediately after the rename's sync"
  call_count_ok "$o" || echo "cleanup_gsi_zip_cache is not called exactly twice"
  marker_count_ok "$o" || echo "RHIZO_GSI_ALREADY_STAGED=1 does not appear exactly once"
  zip_guard "$o"
}

if [[ "${1:-}" == --selftest ]]; then
  expect() {
    grep -qF "$2" <<<"$3" || { echo "check-gsi-cache-cleanup: FAIL selftest: $1 was not flagged: ${3:-<no finding>}" >&2; exit 1; }
  }
  mutate() {
    [[ "$3" != "$2" ]] || { echo "check-gsi-cache-cleanup: FAIL selftest: could not build the $1 mutant" >&2; exit 1; }
  }
  wiring_of() { check_wiring "$(outside_fn "$1")"; }

  broken=$(sed 's/rm -f "\$zip"/: no-op/' <<<"$fn")
  mutate "no-op cleanup" "$fn" "$broken"
  expect "a no-op cleanup" "an ordinary cached zip was not removed" "$(trial "$broken")"

  unguarded=$(sed '/\[\[ -n "\$from_zip" \]\] && return 0/d' <<<"$fn")
  mutate "unguarded --from-zip removal" "$fn" "$unguarded"
  expect "a cleanup that deletes a --from-zip file" "caller's, not the cache's" "$(trial "$unguarded")"

  m=$(sed 's/cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"; echo "RHIZO_GSI_ALREADY_STAGED=1"/echo "RHIZO_GSI_ALREADY_STAGED=1"/' <<<"$whole")
  m=$(sed 's/^# host reads it again. Never remove/# host reads it again; callers use cleanup_gsi_zip_cache "$ZIP" "$FROM_ZIP". Never remove/' <<<"$m")
  mutate "fast-path call removed, kept alive only in a comment" "$whole" "$m"
  expect "fast-path call removed, kept alive only in a comment" "already-staged fast path does not call" "$(wiring_of "$m")"

  m=$(grep -v '^cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"$' <<<"$whole")
  m=$(sed "s/^log \"sha256 verified against the pin\"\$/&\\ncleanup_gsi_zip_cache \"\$ZIP\" \"\$FROM_ZIP\"/" <<<"$m")
  mutate "cleanup moved before extraction" "$whole" "$m"
  expect "cleanup moved before extraction" "not the statement immediately after the rename's sync" "$(wiring_of "$m")"

  m=$(sed 's/cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"; echo "RHIZO_GSI_ALREADY_STAGED=1"; exit 0;/echo "RHIZO_GSI_ALREADY_STAGED=1"; exit 0; cleanup_gsi_zip_cache "$ZIP" "$FROM_ZIP";/' <<<"$whole")
  mutate "fast-path call moved after exit 0" "$whole" "$m"
  expect "fast-path call moved after exit 0" "already-staged fast path does not call" "$(wiring_of "$m")"

  m=$(sed 's/^cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"$/&\nrm -f "$ZIP"/' <<<"$whole")
  mutate "bare rm added outside the function" "$whole" "$m"
  expect "bare rm -f \"\$ZIP\" added outside the function" "not on the allowlist" "$(wiring_of "$m")"

  m=$(grep -v '^cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"$' <<<"$whole")
  m=$(sed 's/^rm -rf "\$TREE"$/cleanup_gsi_zip_cache "$ZIP" "$FROM_ZIP"\n&/' <<<"$m")
  mutate "cleanup moved before the rename" "$whole" "$m"
  expect "cleanup moved before the rename" "not the statement immediately after the rename's sync" "$(wiring_of "$m")"

  m=$(sed "s/^log \"sha256 verified against the pin\"\$/&\\ncleanup_gsi_zip_cache \"\$ZIP\" \"\$FROM_ZIP\"/" <<<"$whole")
  mutate "extra call added before extraction" "$whole" "$m"
  expect "an extra call added before extraction, the real two left in place" "cleanup_gsi_zip_cache is not called exactly twice" "$(wiring_of "$m")"

  m=$(sed "s/^log \"sha256 verified against the pin\"\$/&\\ncleanup_gsi_zip_cache \"\$ZIP\" \"\"/" <<<"$whole")
  mutate "extra call with a different argument" "$whole" "$m"
  expect "an extra call spelled with a different second argument" "cleanup_gsi_zip_cache is not called exactly twice" "$(wiring_of "$m")"

  m=$(sed 's/^cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"$/&\nrm -f "${ZIP}"/' <<<"$whole")
  mutate "braced rm added outside the function" "$whole" "$m"
  expect "rm -f \"\${ZIP}\" (braced) added outside the function" "not on the allowlist" "$(wiring_of "$m")"

  m=$(sed 's/^cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"$/&\nunlink "$ZIP"/' <<<"$whole")
  mutate "unlink added outside the function" "$whole" "$m"
  expect "unlink \"\$ZIP\" added outside the function" "not on the allowlist" "$(wiring_of "$m")"

  m=$(sed 's/^cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"$/&\n: > "$ZIP"/' <<<"$whole")
  mutate "truncate-by-redirect added outside the function" "$whole" "$m"
  expect ": > \"\$ZIP\" added outside the function" "not on the allowlist" "$(wiring_of "$m")"

  m=$(sed 's/^cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"$/&\ncp \/dev\/null "$ZIP"/' <<<"$whole")
  mutate "cp /dev/null added outside the function" "$whole" "$m"
  expect "cp /dev/null \"\$ZIP\" added outside the function" "not on the allowlist" "$(wiring_of "$m")"

  m=$(sed 's/^staged && { log "\$TREE is already staged"; derive_gsi_libs; cleanup_gsi_zip_cache "\$ZIP" "\$FROM_ZIP"; echo "RHIZO_GSI_ALREADY_STAGED=1"; exit 0; }$/[[ -s "$TREE\/bin\/init" ]] \&\& { echo "RHIZO_GSI_ALREADY_STAGED=1"; exit 0; }\n&/' <<<"$whole")
  mutate "a second, earlier already-staged exit with no cleanup" "$whole" "$m"
  expect "a second already-staged exit that skips cleanup" "RHIZO_GSI_ALREADY_STAGED=1 does not appear exactly once" "$(wiring_of "$m")"

  out="$(trial "$fn")$(wiring_of "$whole")"
  [[ -z "$out" ]] || { echo "check-gsi-cache-cleanup: FAIL selftest: the real source was flagged: $out" >&2; exit 1; }
  echo "check-gsi-cache-cleanup selftest: 13 mutants caught (no-op cleanup, unguarded --from-zip removal, fast-path call in a comment only, cleanup before extraction, fast-path call after exit 0, bare rm outside the function, cleanup before the rename, extra call before extraction, extra call with a different argument, braced rm outside the function, unlink outside the function, truncate-by-redirect outside the function, cp /dev/null outside the function, a second unguarded already-staged exit), the real source clean"
  exit 0
fi

RC=0
out="$(check_wiring "$outside")"
while IFS= read -r l; do
  [[ -n "$l" ]] || continue
  echo "check-gsi-cache-cleanup: FAIL: $l" >&2
  RC=1
done <<<"$out"

trial_out=$(trial "$fn")
if [[ -n "$trial_out" ]]; then
  while IFS= read -r l; do echo "check-gsi-cache-cleanup: FAIL: $l" >&2; done <<<"$trial_out"
  RC=1
fi
[[ "$RC" -ne 0 ]] || echo "the GSI download cache is removed once its tree is staged, in the right place on both paths, exactly once each, a --from-zip file never is, and no other line touches \$ZIP or \$FROM_ZIP outside the allowlist"
exit "$RC"
