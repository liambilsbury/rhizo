#!/bin/bash
# test sway launch_entry scoping of no_focus
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FX=$(mktemp -d) || exit 1
trap 'rm -rf "$FX"' EXIT
BAD=""

# run _desk_sway_launch_entry and record guest commands
run_launch() {
  (
    cd "$HERE/../system/lib" || exit 1
    source ./sway-lib.sh >/dev/null 2>&1
    # shellcheck disable=SC2034
    SWAY_LAUNCH_STATE="$FX/state"
    gcmd_user() {
      printf '%s\n' "$1" >> "$FX/cmds"
      case "$1" in
        *"sed -n 's/^Exec=//p'"*) echo "rhizo launch com.x %u" ;;
        *get_workspaces*) echo 3 ;;
        "cat $FX/state"*) cat "$FX/state" 2>/dev/null ;;
        "echo '"*) bash -c "${1%% && *}" ;;
        *"rm -f $FX/state"*) rm -f "$FX/state" ;;
        *) : ;;
      esac
      return 0
    }
    _desk_sway_launch_entry "$@"
  )
}

: > "$FX/cmds"
run_launch /usr/share/applications/rhizo-com.x.desktop --no-token > "$FX/out1"
ws1=$(grep -o 'no_focus \[workspace="^rhizo-launch-[0-9]*' "$FX/cmds" | grep -o 'rhizo-launch-[0-9]*')
grep -q "no_focus \[app_id" "$FX/cmds" && BAD+=" a no_focus rule names the app_id;"
[[ -n "$ws1" ]] || BAD+=" no no_focus rule targets a rhizo-launch-N workspace: $(tr '\n' '|' < "$FX/cmds");"
grep -q "move container to workspace $ws1' >/dev/null && swaymsg 'workspace $ws1'" "$FX/cmds" \
  || BAD+=" the focused window is not moved along to $ws1 before switching to it;"
grep -q "env -u XDG_ACTIVATION_TOKEN" "$FX/cmds" || BAD+=" --no-token did not strip the token;"
: > "$FX/cmds"
run_launch "done" > /dev/null
grep -qF "[workspace=\"^$ws1\$\"] move container to workspace 3' >/dev/null; swaymsg 'workspace 3'" "$FX/cmds" \
  || BAD+=" done does not move $ws1's windows back to workspace 3 and switch to it: $(tr '\n' '|' < "$FX/cmds");"
[[ -e "$FX/state" ]] && BAD+=" done left its state behind;"
run_launch /usr/share/applications/rhizo-com.x.desktop > /dev/null
ws2=$(tail -n 1 "$FX/state" 2>/dev/null | cut -d' ' -f1)
[[ -n "$ws2" && "$ws2" != "$ws1" ]] || BAD+=" a second launch reused workspace '$ws2';"

if [[ -n "$BAD" ]]; then
  echo "check-sway-launch-scope: FAIL:$BAD"
  exit 1
fi
echo "check-sway-launch-scope: each launch scopes no_focus to a new workspace of its own and done moves its windows back"
