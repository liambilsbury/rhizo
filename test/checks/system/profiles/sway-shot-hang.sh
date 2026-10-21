#!/bin/bash
# test sway screenshot paths save hang evidence
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FX=$(mktemp -d) || exit 1
trap 'rm -rf "$FX"' EXIT
BAD=""

# run shot or desk_shot against stub commands
run_shot() {
  (
    rm -f "$FX"/*.txt
    # shellcheck disable=SC2034
    RHIZO_DESKTOP_PROFILE=sway
    cd "$HERE/../system/lib" || exit 1
    source ./desktop-lib.sh >/dev/null 2>&1
    # shellcheck disable=SC2034
    EV="$FX" fx_rc="$2"
    gcmd_user() {
      case "$1" in
        "WAYLAND_DEBUG=1"*) echo "[1.0]  -> zwlr_screencopy_frame_v1@12.copy(wl_buffer@14)"; echo "grim rc=124" ;;
        "timeout 10 "*) return "$fx_rc" ;;
        *get_outputs*) echo "Virtual-1 active=True power=True dpms=True mode={}" ;;
        *loginctl*) echo "5 Active=yes" ;;
        *tty0/active*) echo tty1 ;;
        *rhizo-sway*) echo "connector Virtual-1: Atomic commit failed: Permission denied" ;;
      esac
      return 0
    }
    ssh_vm() {
      case "${*: -1}" in
        *dri/*/clients*) printf 'command   pid dev master a   uid      magic\n     sway  5118   0   n    y  1000          0\n' ;;
        *udevadm\ info*) printf 'P: /devices/pci0000:00/0000:00:02.0/drm/card0\nG: seat\nQ: seat\n' ;;
        *ueventd*) echo "[  400.762578] ueventd: Cannot stat /dev/ptmx: Permission denied" ;;
      esac
      return 0
    }
    if [[ "$1" == shot ]]; then shot /tmp/rhizo-test-base-app.png; else desk_shot /tmp/rhizo-test-base-app.png; fi
    echo "RC=$?"
  )
}

ev="$FX/sway-shot-hang-rhizo-test-base-app.txt"
for via in shot desk; do
  out=$(run_shot "$via" 124 2>/dev/null)
  [[ "$out" == "RC=124" ]] || BAD+=" $via: a hung grim returned '$out', want 124;"
  for sec in grim-wayland-debug outputs session-active tty0-active sway-log drm-clients card0-tags coldboots; do
    grep -qx "=== $sec" "$ev" 2>/dev/null || BAD+=" $via: the hang evidence has no $sec section;"
  done
  grep -q "sway  5118   0   n" "$ev" 2>/dev/null || BAD+=" $via: drm-clients does not carry the clients read;"
  grep -q "^Q: seat" "$ev" 2>/dev/null || BAD+=" $via: card0-tags does not carry the current tags;"
  out=$(run_shot "$via" 0 2>/dev/null)
  [[ "$out" == "RC=0" && "$(cat "$ev" 2>/dev/null)" == '<none>' ]] \
    || BAD+=" $via: a shot that answered gave '$out' and evidence '$(head -1 "$ev" 2>/dev/null)', want 0 and an explicit <none>;"
done

if [[ -n "$BAD" ]]; then
  echo "check-sway-shot-hang: FAIL:$BAD"
  exit 1
fi
echo "check-sway-shot-hang: shot and desk_shot bound grim and save a hang's DRM master, card0 tags and coldboot times"
