#!/bin/bash
# check where data-template.sh takes its SELinux mode
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../../../src/install/prepare/data-template.sh"
HELPER="$HERE/../../../../src/androidd/host/selinux-mode.py"

# print a function from a script text
fn_of() {
  sed -n "/^$2() {/,/^}/p" <<<"$1"
}

# print a case's answer
ask() {
  local text="$1" ctx="$2" env_mode="$3" helper="$4" conf="$5" tmp out
  tmp=$(mktemp -d)
  printf '%s' "$ctx" > "$tmp/attr"
  : > "$tmp/androidd.env"
  [[ -z "$conf" ]] || printf 'RHIZO_SELINUX_MODE=%s\n' "$conf" > "$tmp/androidd.env"
  out=$(env -u RHIZO_SELINUX_MODE ${env_mode:+RHIZO_SELINUX_MODE=$env_mode} RHIZO_ATTR_CURRENT="$tmp/attr" \
    RHIZO_ANDROIDD_ENV="$tmp/androidd.env" RHIZO_SELINUX_MODE_HELPER="$helper" bash -c \
    'log() { :; }; HERE=/nonexistent'$'\n'"$(fn_of "$text" selinux_mode)"$'\n'"$(fn_of "$text" host_policy)"$'\n''if host_policy; then echo ns; else echo plain; fi' 2>/dev/null)
  rm -rf "$tmp"
  printf '%s' "$out" | tail -1
}

# print a finding for each wrong case
check_text() {
  local text="$1" host_ctx=system_u:system_r:initrc_t:s0 got
  [[ -n "$(fn_of "$text" host_policy)" ]] || { echo "no host_policy() to test"; return; }
  got=$(ask "$text" kernel namespace "$HELPER" "")
  [[ "$got" == plain ]] || echo "no policy at all enters Android's policy: $got"
  got=$(ask "$text" "$host_ctx" namespace "$HELPER" host)
  [[ "$got" == ns ]] || echo "prepare's namespace mode does not enter Android's policy: $got"
  got=$(ask "$text" "$host_ctx" host "$HELPER" namespace)
  [[ "$got" == plain ]] || echo "prepare's host mode enters Android's policy: $got"
  got=$(ask "$text" "$host_ctx" "" "$HELPER" host)
  [[ "$got" == plain ]] || echo "an unset mode with host configured enters Android's policy: $got"
  got=$(ask "$text" "$host_ctx" "" "$HELPER" namespace)
  [[ "$got" == ns ]] || echo "an unset mode with namespace configured does not enter Android's policy: $got"
  got=$(ask "$text" "$host_ctx" "" /nonexistent/rhizo-selinux-mode "")
  [[ "$got" == "TEMPLATE_FAILED reason=selinux-mode-unreadable" ]] || echo "an unreadable mode ends '$got', not TEMPLATE_FAILED reason=selinux-mode-unreadable"
  local decide attach
  decide=$(grep -n '^if host_policy; then' <<<"$text" | head -1 | cut -d: -f1)
  attach=$(grep -n 'hostops loop-attach' <<<"$text" | head -1 | cut -d: -f1)
  [[ -n "$decide" && -n "$attach" && "$decide" -lt "$attach" ]] \
    || echo "the materializer is chosen at line ${decide:-?}, not before the loop attach at line ${attach:-?}"
}

text=$(cat "$SCRIPT") || { echo "data-template-mode: cannot read $SCRIPT" >&2; exit 1; }
if [[ "${1:-}" == --selftest ]]; then
  expect() {
    grep -qF "$2" <<<"$3" || { echo "data-template-mode: FAIL selftest: $1 was not flagged: ${3:-<no finding>}" >&2; exit 1; }
  }
  with_fn() {
    BODY="$3" awk -v name="$2" '$0 == name "() {" {print; print ENVIRON["BODY"]; print "}"; skip=1; next}
      skip{ if (/^}/) skip=0; next } { print }' <<<"$1"
  }
  old='  local ctx; [[ "${RHIZO_SELINUX_MODE:-namespace}" == namespace ]] || return 1; ctx=$(tr -d '"'"'\0'"'"' < "$RHIZO_ATTR_CURRENT") || return 1; [[ "$ctx" == *:* ]]'
  expect "a namespace default for an unset mode" "an unset mode with host configured enters" "$(check_text "$(with_fn "$text" host_policy "$old")")"
  failopen='  local ctx m; ctx=$(cat "$RHIZO_ATTR_CURRENT") || return 1; [[ "$ctx" == *:* ]] || return 1; m=$(selinux_mode) || return 1; [[ "$m" == namespace ]]'
  expect "a helper failure read as host" "an unreadable mode ends" "$(check_text "$(with_fn "$text" host_policy "$failopen")")"
  late=$(awk '/^if host_policy; then/{held=$0; getline nxt; held=held "\n" nxt; getline nxt; held=held "\n" nxt; next} {print} /^mkdir -p "\$MOUNTPOINT\/apex\/decompressed"/{print held}' <<<"$text")
  expect "a decision after the loop attach" "not before the loop attach" "$(check_text "$late")"
  out=$(check_text "$text")
  [[ -z "$out" ]] || { echo "data-template-mode: FAIL selftest: the real script has findings: $out" >&2; exit 1; }
  echo "data-template-mode: selftest ok"
  exit 0
fi
out=$(check_text "$text")
if [[ -n "$out" ]]; then
  echo "data-template-mode: FAIL"
  while IFS= read -r line; do echo "  $line"; done <<<"$out"
  exit 1
fi
echo "data-template-mode: ok"
