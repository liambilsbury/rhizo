#!/bin/bash
# check install-kernel makes GRUB default to saved
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/../../vm/rhizo-kernel-vm.sh"
REL=7.1.0-rc1-rhizo

# print set_grub_default's guest body from a driver text
guest_body() {
  sed -n '/^set_grub_default() {/,/^}/p' <<<"$1" | sed -n "/<<'GUEST'/,/^GUEST\$/p" | sed '1d;$d'
}

# run a guest body on a fixture root
run_case() {
  local body="$1" setup="$2" root bin out rc
  root=$(mktemp -d); bin=$(mktemp -d)
  mkdir -p "$root/etc/default/grub.d" "$root/boot/grub"
  printf 'GRUB_TIMEOUT=0\nGRUB_DEFAULT=0\nGRUB_CMDLINE_LINUX=""\n' > "$root/etc/default/grub"
  printf 'menuentry gnulinux-advanced-abc\nmenuentry gnulinux-%s-advanced-abc\n' "$REL" > "$root/boot/grub/grub.cfg"
  ( cd "$root" && eval "$setup" )
  sha256sum "$root/etc/default/grub" > "$root/.grub.sha"
  for t in update-grub grub-set-default grub-editenv; do printf '#!/bin/sh\nexit 0\n' > "$bin/$t"; chmod +x "$bin/$t"; done
  out=$(PATH="$bin:$PATH" RHIZO_GRUB_ROOT="$root" bash -s -- "$REL" <<<"$body" 2>&1); rc=$?
  printf 'rc=%s\n' "$rc"
  printf 'out=%s\n' "$out"
  sha256sum -c --quiet "$root/.grub.sha" >/dev/null 2>&1 && echo "grub=same" || echo "grub=changed"
  if [[ -f "$root/etc/default/grub.d/99-rhizo-kernel-vm.cfg" ]]; then
    echo "own=$(cat "$root/etc/default/grub.d/99-rhizo-kernel-vm.cfg")"
  else
    echo "own=absent"
  fi
  rm -rf "$root" "$bin"
}

# print each wrong case's finding
check_body() {
  local body="$1" r
  [[ -n "$body" ]] || { echo "no set_grub_default guest body to test"; return; }
  r=$(run_case "$body" ':')
  grep -qx 'rc=0' <<<"$r" || echo "a host with GRUB_DEFAULT=0 and no drop-in fails: $r"
  grep -qx 'grub=same' <<<"$r" || echo "a host with no drop-in has its /etc/default/grub edited"
  grep -qx 'own=GRUB_DEFAULT=saved' <<<"$r" || echo "a host with no drop-in gets no saved drop-in: $r"
  r=$(run_case "$body" "printf 'GRUB_DEFAULT=saved\n' > etc/default/grub.d/90-rhizo.cfg")
  grep -qx 'rc=0' <<<"$r" && grep -qx 'grub=same' <<<"$r" && grep -qx 'own=absent' <<<"$r" \
    || echo "a host whose drop-in already sets saved gets a write: $r"
  r=$(run_case "$body" "printf 'GRUB_DEFAULT=2\n' > etc/default/grub.d/50-other.cfg")
  grep -qx 'grub=same' <<<"$r" && grep -qx 'own=GRUB_DEFAULT=saved' <<<"$r" \
    || echo "an earlier drop-in that sets another value is not overridden by the driver's own: $r"
  r=$(run_case "$body" "printf 'GRUB_DEFAULT=0\n' > etc/default/grub.d/99z-later.cfg")
  grep -qx 'rc=1' <<<"$r" && grep -q 'sorts after' <<<"$r" && grep -qx 'own=absent' <<<"$r" \
    || echo "a later drop-in that sets another value is let through: $r"
  r=$(run_case "$body" "sed -i '/^GRUB_DEFAULT=/d' etc/default/grub")
  grep -qx 'grub=same' <<<"$r" && grep -qx 'own=GRUB_DEFAULT=saved' <<<"$r" \
    || echo "a host with no GRUB_DEFAULT at all has /etc/default/grub edited or gets no drop-in: $r"
}

text=$(cat "$DRIVER") || { echo "rhizo-kernel-grub-default: cannot read $DRIVER" >&2; exit 1; }
if [[ "${1:-}" == --selftest ]]; then
  expect() {
    grep -qF "$2" <<<"$3" || { echo "rhizo-kernel-grub-default: FAIL selftest: $1 was not flagged: ${3:-<no finding>}" >&2; exit 1; }
  }
  body=$(guest_body "$text")
  edits=${body/"printf 'GRUB_DEFAULT=saved\\n' > \"\$own\""/"sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' \"\$root/etc/default/grub\""}
  [[ "$edits" != "$body" ]] || { echo "rhizo-kernel-grub-default: FAIL selftest: the write mutant found no anchor" >&2; exit 1; }
  expect "an edit of /etc/default/grub" "has its /etc/default/grub edited" "$(check_body "$edits")"
  always=${body/'if [ "$(effective $dropins)" != saved ]; then'/'if true; then'}
  expect "a drop-in written over a saved default" "already sets saved gets a write" "$(check_body "$always")"
  later=${body/'if [ "$f" \> "$own" ] && grep'/'if false && grep'}
  expect "a later drop-in let through" "is let through" "$(check_body "$later")"
  out=$(check_body "$body")
  [[ -z "$out" ]] || { echo "rhizo-kernel-grub-default: FAIL selftest: the real body has findings: $out" >&2; exit 1; }
  echo "rhizo-kernel-grub-default: selftest ok"
  exit 0
fi
out=$(check_body "$(guest_body "$text")")
if [[ -n "$out" ]]; then
  echo "rhizo-kernel-grub-default: FAIL"
  while IFS= read -r line; do echo "  $line"; done <<<"$out"
  exit 1
fi
echo "rhizo-kernel-grub-default: ok"
