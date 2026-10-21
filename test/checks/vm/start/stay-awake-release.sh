#!/bin/bash
# test android_release_stay_awake undoes the stay-awake settings
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit

source ../vm/common.sh

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK"
bad=0

# record each guest command and answer the screen timeout read
android_sh() {
  printf '%s\n' "$2" >> "$WORK/commands"
  case "$2" in
    "settings get system screen_off_timeout") echo 60000 ;;
    "dumpsys power") echo "mWakefulness=Awake" ;;
  esac
}
# drop the helper's log lines
log() { :; }

android_stay_awake 4242 >/dev/null
: > "$WORK/commands"
android_release_stay_awake 4242
for want in "svc power stayon false" "settings put global stay_on_while_plugged_in 0" "settings put system screen_off_timeout 60000"; do
  if ! grep -qxF "$want" "$WORK/commands"; then
    echo "check-stay-awake-release: the release did not run '$want' (ran: $(paste -sd';' "$WORK/commands"))"
    bad=1
  fi
done

: > "$WORK/commands"
android_release_stay_awake 4343
if ! grep -qxF "settings put global stay_on_while_plugged_in 0" "$WORK/commands"; then
  echo "check-stay-awake-release: a release with no saved timeout left stay_on_while_plugged_in set"
  bad=1
fi

(( bad )) && exit 1
echo "check-stay-awake-release: ok"
