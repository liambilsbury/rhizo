#!/bin/bash
# test the scratch directory of fetch-gsi.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="$REPO/src/install/prepare/fetch-gsi.sh"
[[ -r "$SRC" ]] || { echo "check-gsi-scratch: cannot read $SRC" >&2; exit 1; }
FAILED=0
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; FAILED=$((FAILED + 1)); fi
}
# print a function's text from a script
lift() { sed -n "/^$1() {/,/^}/p" <<<"$2"; }

# run the scratch functions against a state directory
run_scratch() {
  local text="$1" state="$2" action="$3" calls="$4"
  (
    export RHIZO_STATE_DIR="$state"
    log() { echo "log $*" >> "$calls"; }
    hostops() {
      echo "hostops $*" >> "$calls"
      [[ "$1" != is-mount ]] || { [[ "$2" == *"/gsi.mounted/mnt" ]]; return; }
      [[ "$1 $2" != "loop-find "*"/gsi.loopfail/"* ]] || return 1
      [[ -z "${UMOUNT_FAILS:-}" || "$1" != umount ]]
    }
    eval "$(lift scratch_root "$text")"
    eval "$(lift sweep_stale_scratch "$text")"
    eval "$(lift make_scratch "$text")"
    "$action"
  )
}

# run all of the scenarios against a script text
scenarios() {
  local text="$1" tmp state calls made
  tmp=$(mktemp -d -p "$WORK")
  state="$tmp/state"
  calls="$tmp/calls"; : > "$calls"
  made=$(run_scratch "$text" "$state" make_scratch "$calls")
  check "a missing state directory is created" "$([[ -d "$state/fetch-scratch" ]] && echo yes || echo no)" yes
  check "the scratch root is root-only" "$(stat -c %a "$state/fetch-scratch" 2>/dev/null)" 700
  check "the scratch directory is below the state directory" "${made%/gsi.*}" "$state/fetch-scratch"
  mkdir -p "$state/fetch-scratch/gsi.stale" "$state/fetch-scratch/gsi.fresh" "$state/fetch-scratch/other.stale" \
           "$state/fetch-scratch/gsi.mounted/mnt" "$state/fetch-scratch/gsi.loopfail" "$tmp/target"
  ln -s "$tmp/target" "$state/fetch-scratch/gsi.link"
  touch -h -d '3 days ago' "$state/fetch-scratch/gsi.stale" "$state/fetch-scratch/other.stale" \
        "$state/fetch-scratch/gsi.mounted" "$state/fetch-scratch/gsi.link" "$state/fetch-scratch/gsi.loopfail"
  [[ -z "$made" ]] || touch -d '3 days ago' "$made"
  UMOUNT_FAILS=1 run_scratch "$text" "$state" sweep_stale_scratch "$calls"
  check "a stale directory goes" "$([[ -e "$state/fetch-scratch/gsi.stale" ]] && echo kept || echo gone)" gone
  check "a stale scratch directory made by make_scratch goes" "$([[ -e "$made" ]] && echo kept || echo gone)" gone
  check "a fresh directory stays" "$([[ -e "$state/fetch-scratch/gsi.fresh" ]] && echo kept || echo gone)" kept
  check "a directory with another name stays" "$([[ -e "$state/fetch-scratch/other.stale" ]] && echo kept || echo gone)" kept
  check "a stale symlink stays and its target is untouched" \
    "$([[ -L "$state/fetch-scratch/gsi.link" && -d "$tmp/target" ]] && echo kept || echo gone)" kept
  check "a directory whose mount will not unmount stays" "$([[ -e "$state/fetch-scratch/gsi.mounted" ]] && echo kept || echo gone)" kept
  check "its mount was unmounted before any removal" "$(grep -c "^hostops umount .*/gsi.mounted/mnt" "$calls")" 1
  check "the sweep names the directory it leaves" "$(grep -c "^log leaving .*gsi.mounted" "$calls")" 1
  check "a directory whose loop lookup fails stays" "$([[ -e "$state/fetch-scratch/gsi.loopfail" ]] && echo kept || echo gone)" kept
  check "the sweep names the directory whose loop lookup failed" "$(grep -c "^log leaving .*gsi.loopfail.*loop-find" "$calls")" 1
  check "the exit cleanup removes its scratch on one filesystem only" \
    "$(grep -m1 '^cleanup() {' <<<"$text" | grep -c 'rm -rf --one-file-system')" 1
  check "the exit cleanup removes the scratch root once it is empty" \
    "$(grep -m1 '^cleanup() {' <<<"$text" | grep -c 'rmdir -- "$(scratch_root)"')" 1
}

TEXT=$(cat "$SRC")
scenarios "$TEXT"
if [[ "${1:-}" == --selftest ]]; then
  mutate() { local t="${TEXT//"$2"/"$3"}"; [[ "$t" != "$TEXT" ]] || { echo "FAIL mutant $1 changed nothing"; FAILED=$((FAILED + 1)); return; }
    local before=$FAILED; scenarios "$t" > /dev/null; local after=$FAILED; FAILED=$before
    if (( after > before )); then echo "ok   mutant $1 fails"; else echo "FAIL mutant $1 passes"; FAILED=$((FAILED + 1)); fi; }
  mutate "no mkdir of the root" 'mkdir -p -m 0700 "$root" && ' ''
  mutate "a world-readable root" 'mkdir -p -m 0700' 'mkdir -p -m 0755'
  mutate "no age limit" '-mmin +1440' '-mmin +0'
  mutate "any name" "-name 'gsi.*'" "-name '*'"
  mutate "symlinks followed" '-type d -name' '-name'
  mutate "no unmount" 'hostops umount "$d/mnt" ||' 'true ||'
  mutate "an empty scratch root left behind" ' rmdir -- "$(scratch_root)" 2>/dev/null;' ''
  mutate "a failed loop lookup read as no loops" 'if ! loops=$(hostops loop-find "$d/system.img"); then' 'if ! loops=$(hostops loop-find "$d/system.img" || true); then'
fi
(( FAILED == 0 )) && echo "check-gsi-scratch: ok" || { echo "check-gsi-scratch: $FAILED failed"; exit 1; }
