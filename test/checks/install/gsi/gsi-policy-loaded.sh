#!/bin/bash
# test the GSI scripts' loaded policy detection
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
FETCH="$REPO/src/install/prepare/fetch-gsi.sh"
UPDATE="$REPO/src/install/update/gsi-update.sh"
HELPER="$REPO/src/androidd/host/selinux-mode.py"

# print policy_loaded() from a script's text
extract_fn() {
  sed -n '/^policy_loaded() {/,/^}/p' <<<"$1"
}

# print a case's answer
ask() {
  local fn="$1" ctx="$2" mode="$3" helper="$4" tmp out
  tmp=$(mktemp -d)
  printf '%s' "$ctx" > "$tmp/attr"
  : > "$tmp/androidd.env"
  [[ "$mode" == default ]] || printf 'RHIZO_SELINUX_MODE=%s\n' "$mode" > "$tmp/androidd.env"
  out=$(env -u RHIZO_SELINUX_MODE RHIZO_ATTR_CURRENT="$tmp/attr" RHIZO_ANDROIDD_ENV="$tmp/androidd.env" \
    RHIZO_SELINUX_MODE_HELPER="$helper" bash -c 'refuse() { echo "refused:$1"; exit 1; }'$'\n'"$fn"$'\n''if policy_loaded; then echo loaded; else echo free; fi' 2>/dev/null)
  rm -rf "$tmp"
  printf '%s' "$out"
}

# print a finding for each wrong case
trial() {
  local fn="$1" name="$2" host_ctx=system_u:system_r:initrc_t:s0
  [[ "$(ask "$fn" "$host_ctx" default "$HELPER")" == free ]] \
    || echo "$name: the host's own policy reads as loaded in the default namespace mode"
  [[ "$(ask "$fn" "$host_ctx" namespace "$HELPER")" == free ]] \
    || echo "$name: the host's own policy reads as loaded in namespace mode"
  [[ "$(ask "$fn" u:r:rhizo_host:s0 host "$HELPER")" == loaded ]] \
    || echo "$name: Android's policy loaded host-wide reads as free in host mode"
  [[ "$(ask "$fn" kernel host "$HELPER")" == free ]] \
    || echo "$name: no policy reads as loaded in host mode"
  [[ "$(ask "$fn" kernel namespace "$HELPER")" == free ]] \
    || echo "$name: no policy reads as loaded in namespace mode"
  [[ "$(ask "$fn" "$host_ctx" host "$HELPER")" == free ]] \
    || echo "$name: the host's own policy reads as Android's in host mode"
  [[ "$(ask "$fn" u:r:rhizo_host:s0 namespace "$HELPER")" == loaded ]] \
    || echo "$name: Android's policy left host-wide by host mode reads as free once namespace mode is configured"
  [[ "$(ask "$fn" u:r:rhizo_host:s0 host /nonexistent/rhizo-selinux-mode)" == loaded ]] \
    || echo "$name: Android's policy loaded host-wide reads as free with no mode helper to run"
}

# check the refusal line calls policy_loaded
wiring() {
  grep -qE '^\[\[ "\$MODE" == apply \]\] && policy_loaded \\$' <<<"$1" \
    || echo "fetch-gsi.sh: the policy-loaded refusal is not decided by policy_loaded"
}

# print all of the findings for both scripts
check_all() {
  local fetch_text="$1" update_text="$2" fn pair
  for pair in "fetch-gsi.sh:$fetch_text" "gsi-update.sh:$update_text"; do
    fn=$(extract_fn "${pair#*:}")
    if [[ -z "$fn" ]]; then echo "${pair%%:*}: no policy_loaded() to test"; continue; fi
    trial "$fn" "${pair%%:*}"
  done
  wiring "$fetch_text"
}

for f in "$FETCH" "$UPDATE" "$HELPER"; do
  [[ -r "$f" ]] || { echo "check-gsi-policy-loaded: cannot read $f" >&2; exit 1; }
done
fetch_text=$(cat "$FETCH")
update_text=$(cat "$UPDATE")

if [[ "${1:-}" == --selftest ]]; then
  expect() {
    grep -qF "$2" <<<"$3" || { echo "check-gsi-policy-loaded: FAIL selftest: $1 was not flagged: ${3:-<no finding>}" >&2; exit 1; }
  }
  with_fn() {
    BODY="$2" awk '/^policy_loaded\(\) \{/{print "policy_loaded() {"; print ENVIRON["BODY"]; print "}"; skip=1; next}
      skip{ if (/^}/) skip=0; next } { print }' <<<"$1"
  }
  old='  local ctx; ctx=$(tr -d '"'"'\0'"'"' < "${RHIZO_ATTR_CURRENT:-/proc/self/attr/current}" 2>/dev/null) || return 1; [[ "$ctx" == *:* ]]'
  out=$(check_all "$(with_fn "$fetch_text" "$old")" "$update_text")
  expect "fetch's mode-blind check" "fetch-gsi.sh: the host's own policy reads as loaded in namespace mode" "$out"
  out=$(check_all "$fetch_text" "$(with_fn "$update_text" "$old")")
  expect "gsi-update's mode-blind check" "gsi-update.sh: the host's own policy reads as loaded in the default namespace mode" "$out"
  always='  return 0'
  out=$(check_all "$(with_fn "$fetch_text" "$always")" "$update_text")
  expect "a check that always reads loaded" "fetch-gsi.sh: no policy reads as loaded in host mode" "$out"
  configured='  local ctx m; ctx=$(cat "$RHIZO_ATTR_CURRENT") || return 1; [[ "$ctx" == *:* ]] || return 1; m=$("${RHIZO_SELINUX_MODE_HELPER:-x}" --env-file "$RHIZO_ANDROIDD_ENV" --configured) || m=host; [[ "$m" != namespace ]]'
  out=$(check_all "$(with_fn "$fetch_text" "$configured")" "$update_text")
  expect "a check that reads the configured mode" \
    "fetch-gsi.sh: Android's policy left host-wide by host mode reads as free once namespace mode is configured" "$out"
  out=$(check_all "$fetch_text" "$(with_fn "$update_text" "$configured")")
  expect "gsi-update's check that reads the configured mode" "gsi-update.sh: the host's own policy reads as Android's in host mode" "$out"
  out=$(check_all "$(sed 's/^\[\[ "\$MODE" == apply \]\] && policy_loaded \\$/[[ "$MODE" == apply ]] \\/' <<<"$fetch_text")" "$update_text")
  expect "a refusal that no longer asks policy_loaded" "the policy-loaded refusal is not decided by policy_loaded" "$out"
  out=$(check_all "$fetch_text" "$update_text")
  [[ -z "$out" ]] || { echo "check-gsi-policy-loaded: FAIL selftest: the current scripts have findings: $out" >&2; exit 1; }
  echo "check-gsi-policy-loaded: selftest ok"
  exit 0
fi

out=$(check_all "$fetch_text" "$update_text")
if [[ -n "$out" ]]; then
  echo "check-gsi-policy-loaded: FAIL"
  while IFS= read -r line; do echo "  $line"; done <<<"$out"
  exit 1
fi
echo "check-gsi-policy-loaded: ok"
