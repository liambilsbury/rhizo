#!/bin/bash
# copy sources into var/share
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=rig/hooks.sh
source test/vm/rig/hooks.sh || exit 2

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
CHECK_BAD=0

if (( CHECK )) && [[ ! -d var/share ]]; then
  echo "sync.sh --check: no var/share/ on this host, nothing is staged"
  exit 0
fi

# copy a file and check the copy
sync_one() {
  [[ -e "$2" && "$1" -ef "$2" ]] && return 0
  if (( CHECK )); then
    cmp -s "$1" "$2" 2>/dev/null || {
      echo "OUT OF SYNC: $2 does not carry $1" >&2
      CHECK_BAD=1
    }
    return 0
  fi
  local x1=0 x2=0
  [[ -x "$1" ]] && x1=1
  [[ -x "$2" ]] && x2=1
  if [[ -f "$2" ]] && (( x1 == x2 )) && cmp -s "$1" "$2"; then
    return 0
  fi
  mkdir -p "$(dirname "$2")"
  cp -p "$1" "$2"
  diff -q "$1" "$2" >/dev/null || {
    echo "SYNC MISMATCH: $1 differs from $2 after copy" >&2
    exit 1
  }
}

sync_one src/androidd/boot.py var/share/launcher3.py
sync_one src/services/udev/59-loop-unbound.rules var/share/rhizo-loop-unbound.rules
for _mod in src/androidd/sandbox/*.py; do
  [ -f "$_mod" ] || continue
  mkdir -p var/share/sandbox
  sync_one "$_mod" "var/share/sandbox/$(basename "$_mod")"
done
for _guest in src/androidd/guest/*/*; do
  [ -f "$_guest" ] || continue
  _rel=${_guest#src/androidd/guest/}
  mkdir -p "var/share/guest/$(dirname "$_rel")"
  sync_one "$_guest" "var/share/guest/$_rel"
done
if [[ -f var/share/sys-kernel-readers.txt ]]; then
  mkdir -p var/share/guest
  sync_one var/share/sys-kernel-readers.txt var/share/guest/sys-kernel-readers.txt
fi

for _nb in ./src/services/netbridged/*.py; do
  [ -f "$_nb" ] || continue
  case "$(basename "$_nb")" in selftest_*) continue ;; esac
  mkdir -p var/share/netbridged
  sync_one "$_nb" "var/share/netbridged/$(basename "$_nb")"
done
sync_one src/services/appsync/appsync.py var/share/appsync.py
sync_one src/services/appsync/resync.sh var/share/resync.sh
sync_one src/services/appsync/remove-entries.sh var/share/remove-entries.sh
sync_one src/services/appsync/remove-entries.path var/share/rhizo-remove-entries.path
sync_one src/services/appsync/remove-entries.service var/share/rhizo-remove-entries.service
sync_one src/services/units/session/desktop-attach.path var/share/rhizo-desktop-attach.path
sync_one src/services/units/session/desktop-attach.service var/share/rhizo-desktop-attach.service
sync_one src/services/units/session/session-start.path var/share/rhizo-session-start.path
sync_one src/services/units/session/session-start.service var/share/rhizo-session-start.service
sync_one ./src/install/cli/rhizo.sh var/share/install/cli/rhizo.sh
sync_one ./src/services/api/apid.py var/share/apid.py
sync_one src/services/api/api.socket var/share/rhizo-api.socket
sync_one src/services/api/api@.service var/share/rhizo-api@.service
sync_one ./src/install/update/gsi-update.sh var/share/install/update/gsi-update.sh
sync_one ./src/install/prepare/await-boot-completed.py var/share/install/prepare/await-boot-completed.py
sync_one ./src/install/prepare/prepare.sh var/share/install/prepare/prepare.sh
sync_one ./src/install/prepare/verify-prepared-tree.py var/share/install/prepare/verify-prepared-tree.py
sync_one ./src/install/cli/print-share-row.py var/share/install/cli/print-share-row.py
sync_one ./src/install/prepare/fetch-gsi.sh var/share/install/prepare/fetch-gsi.sh
sync_one ./src/install/bootstrap/bootstrap.sh var/share/install/bootstrap/bootstrap.sh
sync_one ./src/install/teardown/teardown.sh var/share/install/teardown/teardown.sh
sync_one ./src/install/prepare/kernel-changed.sh var/share/install/prepare/kernel-changed.sh
sync_one ./src/install/bootstrap/skel-fill.sh var/share/install/bootstrap/skel-fill.sh
sync_one ./src/install/bootstrap/user-cgroup-reset.sh var/share/install/bootstrap/user-cgroup-reset.sh
sync_one ./src/install/bootstrap/console-vt.py var/share/install/bootstrap/console-vt.py
sync_one ./src/install/bootstrap/rundir-root.py var/share/install/bootstrap/rundir-root.py
sync_one ./debian/profile.d/console-vt.sh var/share/rhizo-console-vt.sh
sync_one src/services/units/session/user-prep@.service var/share/rhizo-user-prep@.service
sync_one src/services/units/session/session-vt@.service var/share/rhizo-session-vt@.service
sync_one debian/dropins/private-users-off.conf var/share/host-mode/usr/lib/systemd/system/service.d/50-rhizo-private-users.conf
sync_one debian/dropins/avahi-daemon-policy.conf var/share/host-mode/usr/lib/systemd/system/avahi-daemon.service.d/50-rhizo-policy.conf
sync_one debian/dropins/accounts-daemon-skel.conf var/share/host-mode/usr/lib/systemd/system/accounts-daemon.service.d/rhizo-skel.conf
sync_one debian/dropins/user-at-prep.conf var/share/host-mode/usr/lib/systemd/system/user@.service.d/rhizo-user-prep.conf
sync_one debian/dropins/session-scope-vt.conf var/share/host-mode/usr/lib/systemd/system/session-.scope.d/rhizo-session-vt.conf
sync_one ./src/install/teardown/teardown-lib.sh var/share/install/teardown/teardown-lib.sh
sync_one ./src/install/lib/host-flavor.sh var/share/install/lib/host-flavor.sh
sync_one ./src/install/bootstrap/bootloader.sh var/share/install/bootstrap/bootloader.sh
sync_one ./src/install/lib/pkg-lib.sh var/share/install/lib/pkg-lib.sh
sync_one src/services/probe-client/probe-client.py var/share/probe-client.py
sync_one ./src/services/deskbridge/dbus_min.py var/share/dbus_min.py
sync_one ./src/services/broker/inbox_stage.py var/share/inbox_stage.py
sync_one ./src/services/udev/70-uinput.rules var/share/70-rhizo-uinput.rules
sync_one src/androidd/host/kernel-check.sh var/share/kernel-check.sh
sync_one src/install/prepare/derive-patches.sh var/share/derive-patches.sh
sync_one src/install/prepare/config-disable.prop var/share/config-disable.prop
sync_one ./src/services/broker/brokerd.py var/share/brokerd.py
sync_one ./src/services/broker/broker-client.py var/share/broker-client.py
sync_one src/services/broker/brokerd.socket var/share/rhizo-brokerd.socket
sync_one src/services/broker/brokerd@.service var/share/rhizo-brokerd@.service
sync_one src/services/units/applications/apk-installer.desktop var/share/rhizo-apk-installer.desktop
sync_one tools/build/packaging/deb/gen-rhizo-icon.py var/share/gen-rhizo-icon.py
sync_one test/system/guest/serve-dns-http.py var/share/serve-dns-http.py
sync_one test/system/guest/lan-fixture.py var/share/lan-fixture.py
sync_one test/system/guest/proxy-fixture.py var/share/proxy-fixture.py
sync_one src/androidd/host/launch-app.sh var/share/rhizo-launch.sh
sync_one test/system/guest/capture-packets.sh var/share/capture-packets.sh
sync_one test/system/guest/sniff-packets.py var/share/sniff-packets.py
sync_one test/system/tools/stack-meter.py var/share/stack-meter.py
sync_one src/install/prepare/align-apex.py var/share/align-apex.py
sync_one src/install/prepare/materialize-data-template.py var/share/materialize-data-template.py
sync_one src/install/prepare/data-template.sh var/share/data-template.sh
sync_one src/install/prepare/hostops.py var/share/hostops.py
sync_one test/vm/guest-os/seed-modules-extra.sh var/share/seed-modules-extra.sh
sync_one src/install/prepare/detect-gpu-driver.sh var/share/detect-gpu-driver.sh
sync_one src/androidd/host/capture-kernel-log.sh var/share/rhizo-avc-capture.sh
sync_one src/androidd/host/unfreeze-cgroup.sh var/share/rhizo-cgroup-unfreeze.sh
sync_one src/androidd/host/parse-display-list.sh var/share/rhizo-display-list.sh
sync_one src/services/units/boot/androidd.service var/share/androidd.service
sync_one src/services/units/boot/androidd@.service var/share/androidd@.service
sync_one src/services/units/boot/policy.service var/share/rhizo-policy.service
sync_one src/services/units/boot/selinuxfs.service var/share/rhizo-selinuxfs.service
sync_one src/services/units/boot/selinux-mode.service var/share/rhizo-selinux-mode.service
sync_one src/services/units/boot/host-labels.service var/share/rhizo-host-labels.service
sync_one src/androidd/host/selinux-mode.py var/share/rhizo-selinux-mode.py
(( CHECK )) || mkdir -p var/share/run-rhizo.mount.d var/share/run-rhizo-data.mount.d
sync_one src/services/appsync/resync-rearm.service var/share/rhizo-resync-rearm.service
sync_one src/services/appsync/resync.path var/share/rhizo-resync.path
sync_one src/services/appsync/resync.service var/share/rhizo-resync.service
sync_one src/androidd/host/fill-display-pool.sh var/share/rhizo-fill-display-pool.sh
sync_one src/services/units/display-pool/display-pool.path var/share/rhizo-display-pool.path
sync_one src/services/units/display-pool/display-pool.service var/share/rhizo-display-pool.service
sync_one src/androidd/host/release-idle-display.sh var/share/rhizo-release-idle-display.sh
sync_one src/services/units/display-pool/display-pool-release.service var/share/rhizo-display-pool-release.service
sync_one src/services/appsync/app-events.py var/share/app-events.py
sync_one src/services/hostfs/hostfs.py var/share/hostfs.py
sync_one src/services/hostfs/hostfs.service var/share/rhizo-hostfs.service
sync_one src/services/appsync/app-events.service var/share/rhizo-app-events.service
sync_one src/services/units/boot/kernel-refresh.service var/share/rhizo-kernel-refresh.service
sync_one src/services/server-idle/server-idle.service var/share/rhizo-server-idle.service
sync_one src/services/server-idle/server-idle@.service var/share/rhizo-server-idle@.service
sync_one ./src/services/server-idle/server-idle.py var/share/server-idle.py
sync_one src/services/streamd/streamd.socket var/share/rhizo-streamd.socket
sync_one src/services/streamd/streamd.service var/share/rhizo-streamd.service
sync_one src/services/streamd/stream-capability.path var/share/rhizo-stream-capability.path
sync_one src/services/streamd/stream-capability.service var/share/rhizo-stream-capability.service
sync_one ./src/services/streamd/capability-sync.sh var/share/capability-sync.sh
sync_one ./src/services/streamd/viewer.html var/share/viewer.html
sync_one src/services/units/boot/update-begin.service var/share/rhizo-update-begin.service
sync_one src/services/units/boot/update-confirm.service var/share/rhizo-update-confirm.service
sync_one src/services/units/session/desktop-session.path var/share/rhizo-desktop-session.path
sync_one src/services/units/session/desktop-session.service var/share/rhizo-desktop-session.service
sync_one src/services/units/session/desktop-session.tmpfiles var/share/rhizo-desktop-session.tmpfiles
sync_one src/services/deskbridge/desk-notify.path var/share/rhizo-desk-notify.path
sync_one src/services/deskbridge/desk-notify.service var/share/rhizo-desk-notify.service
sync_one src/services/units/boot/run-root.tmpfiles var/share/rhizo-run-root.tmpfiles
sync_one src/services/deskbridge/deskd.service var/share/rhizo-deskd.service
sync_one src/services/deskbridge/desk-token.service var/share/rhizo-desk-token.service
sync_one src/services/audiod/audiod.service var/share/rhizo-audiod.service
sync_one src/services/inputd/inputd@.service var/share/rhizo-inputd@.service
sync_one src/services/inputd/inputd-uhid@.service var/share/rhizo-inputd-uhid@.service
sync_one ./debian/dropins/inputd-instance0.conf var/share/rhizo-inputd-instance0.conf
sync_one src/services/displayd/displayd.service var/share/rhizo-displayd.service
sync_one src/services/keymapd/keymapd.service var/share/rhizo-keymapd.service
sync_one src/androidd/sandbox/capability-allowed.sh var/share/capability-allowed.sh
sync_one ./src/services/deskbridge/deskd.py var/share/deskd.py
sync_one ./src/services/deskbridge/desk-token.py var/share/desk-token.py
sync_one ./src/services/deskbridge/desk-notify.py var/share/desk-notify.py
sync_one ./src/services/displayd/displayd.py var/share/displayd.py
sync_one ./src/services/keymapd/keymapd.py var/share/keymapd.py
sync_one src/services/rtd/rtd.service var/share/rhizo-rtd.service
sync_one src/services/delayd/delayd.service var/share/rhizo-delayd.service
sync_one src/services/headroomd/headroomd.service var/share/rhizo-headroomd.service
sync_one src/services/btd/btd.service var/share/rhizo-btd.service
sync_one ./src/services/btd/btd.py var/share/btd.py
sync_one ./debian/dropins/androidd-btd.conf var/share/androidd-btd.conf
sync_one ./src/services/rtd/rtd.py var/share/rtd.py
sync_one src/services/appsync/run-rhizo.mount.d/resync-rearm.conf \
         var/share/run-rhizo.mount.d/rhizo-resync-rearm.conf
sync_one src/services/appsync/run-rhizo-data.mount.d/resync-rearm.conf \
         var/share/run-rhizo-data.mount.d/rhizo-resync-rearm.conf
sync_one ./src/android/hal/audio-core/audio_policy_configuration.xml \
         var/share/audio_policy_configuration.xml

# print four tab separated fields per file
tree_listing() {
  find "$1" -type f -printf '%P\t%i\t%s\t%T@\n' | awk -F'\t' -v OFS='\t' '{ sub(/\..*/, "", $4); print }'
}

# print the vm's missing or changed share files
vm_differs() {
  { tree_listing "$1" | sed 's/^/L\t/'; tree_listing var/share | sed 's/^/S\t/'; } |
    awk -F'\t' '$1 == "L" { ino[$2] = $3; sz[$2] = $4; mt[$2] = $5; next }
      !($2 in ino) || (ino[$2] != $3 && (sz[$2] != $4 || mt[$2] != $5)) { print $2 }'
}

# set signal traps for the mirror temp file
sync_temp_cleanup() {
  SYNC_TMP=""
  trap 'rm -f -- "${SYNC_TMP:-}"' EXIT
  trap 'rm -f -- "${SYNC_TMP:-}"; exit 130' INT
  trap 'rm -f -- "${SYNC_TMP:-}"; exit 143' TERM
  trap 'rm -f -- "${SYNC_TMP:-}"; exit 129' HUP
}

# print the stray temp files under the directories
stray_temps() {
  local d
  for d in "$@"; do
    [[ -d "$d" ]] || continue
    find "$d" -type f -name '*.tmp.[0-9]*' -print
  done
}

# remove all of the stray temps under the dirs
sweep_stray_temps() {
  local t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    rm -f -- "$t" && echo "  sync: removed a stray temp a killed run left: $t"
  done < <(stray_temps "$@")
}

WHOLE_SET_DIRS=(runtime-debs arch-pool arch-pkgs)

# print vm files missing from var/share
vm_extras() {
  local vm="$1" dir f
  for dir in "${WHOLE_SET_DIRS[@]}"; do
    [[ -d "$vm$dir" ]] || continue
    while IFS= read -r -d '' f; do
      [[ -e "var/share/${f#"$vm"}" ]] || printf '%s\n' "$f"
    done < <(find "$vm$dir" -type f -print0)
  done
}

# link or copy var/share files into the vm
mirror_vm() {
  local vm="$1" f rel n=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    f="var/share/$rel"
    mkdir -p "$vm$(dirname "$rel")"
    SYNC_TMP="$vm$rel.tmp.$$"
    if ln "$f" "$SYNC_TMP" 2>/dev/null || sync_one "$f" "$SYNC_TMP"; then
      mv -f "$SYNC_TMP" "$vm$rel"
      SYNC_TMP=""
    else
      rm -f "$SYNC_TMP"
      SYNC_TMP=""
      echo "  sync: FAILED to stage $vm$rel" >&2
      return 1
    fi
    n=$((n+1))
  done < <(vm_differs "$vm")
  echo "  $vm: $n file(s) re-linked or re-copied"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rm -f -- "$f" && echo "  $vm: removed ${f#"$vm"}, which var/share/ no longer holds"
  done < <(vm_extras "$vm")
}

# report stale files in the vm directory
verify_vm() {
  local vm="$1" rel bad=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    echo "VM OUTDATED: $vm$rel does not carry var/share/$rel" >&2
    bad=1
  done < <(vm_differs "$vm")
  local t
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    echo "VM OUTDATED: $t is a stray temp a killed run left -- run test/vm/sync.sh" >&2
    bad=1
  done < <(stray_temps "$vm")
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    echo "VM OUTDATED: $t is not in var/share/, and its directory is checked as a whole set -- run test/vm/sync.sh" >&2
    bad=1
  done < <(vm_extras "$vm")
  return $bad
}

rc=0
if (( CHECK )); then
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    echo "OUT OF SYNC: $t is a stray temp a killed run left" >&2
    CHECK_BAD=1
  done < <(stray_temps var/share)
else
  sync_temp_cleanup
  # shellcheck disable=SC2046
  sweep_stray_temps var/share $(rig_other_shares)
fi
for vm in $(rig_other_shares); do
  [[ -d "$vm" ]] || continue
  (( CHECK )) || mirror_vm "$vm"
  verify_vm "$vm" || rc=1
done

if (( CHECK )); then
  if (( CHECK_BAD || rc )); then
    echo "sync.sh --check: staged copies are out of date -- run test/vm/sync.sh" >&2
    exit 1
  fi
  echo "sync.sh --check: every staged copy carries its source"
  exit 0
fi

if (( rc )); then
  echo "one or more vms are still out of date after mirroring -- see the VM OUTDATED lines above" >&2
  exit 1
fi

echo "synced OK: $(date '+%H:%M:%S')"
