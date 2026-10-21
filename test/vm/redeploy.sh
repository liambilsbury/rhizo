#!/bin/bash
# stage files onto the vm and launch it
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ./common.sh
source ./guest-os/guest-os-lib.sh
source ./image/release-map.sh

# print boot log findings and run explain-boot.sh
explain_dead_boot() {
  local boot_log="$VAR_DIR/vm-boot${SUFFIX}.log"
  log "  requested kernel: RHIZO_KERNEL=${RHIZO_KERNEL:-<unset, the Rhizo kernel>}"
  if [[ ! -r "$boot_log" ]]; then
    log "  no boot log at $boot_log to read"
    return
  fi
  local console
  console=$(tail -400 "$boot_log")
  if grep -q 'Failed to mount /dev/vdb' <<<"$console"; then
    log "  cloud-init could not mount the seed on /dev/vdb"
    log "  isofs is a module: the booted kernel needs its /lib/modules tree"
    log "  test/vm/image/install-kernel.sh installs the Rhizo kernel's modules"
  elif grep -q 'DataSourceNone' <<<"$console"; then
    log "  cloud-init fell back to DataSourceNone"
  fi
  grep -m1 'Linux version' <<<"$console" | sed 's/^/  /' | while read -r l; do log "$l"; done

  if [[ -n "${RHIZO_BOOT_EXPLAINED_BY:-}" ]]; then
    log "  ($RHIZO_BOOT_EXPLAINED_BY will name the cause)"
    return
  fi
  local explained
  explained=$(./boot/explain-boot.sh 2>&1)
  while read -r l; do [[ -n "$l" ]] && log "  $l"; done <<<"$explained"
}

BOOT_EVIDENCE_DIR="${RHIZO_BOOT_EVIDENCE_DIR:-$VAR_DIR/scratch/boot-failure$SUFFIX}"
# run collect-boot-evidence.sh for the label
collect_evidence() {
  ./boot/collect-boot-evidence.sh "$BOOT_EVIDENCE_DIR" "$1"
}

SKIP_KILL=0
BOOT_WAIT=120
DO_LAUNCH=1
GSI_PATH="${RHIZO_GSI:-}"
RELEASE="${RHIZO_RELEASE:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-kill) SKIP_KILL=1; shift ;;
    --boot-wait) BOOT_WAIT="$2"; shift 2 ;;
    --no-launch) DO_LAUNCH=0; shift ;;
    --gsi) GSI_PATH="$2"; shift 2 ;;
    --release) RELEASE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

LAUNCH_ENV_DENY=" RHIZO_GSI RHIZO_RELEASE RHIZO_VM RHIZO_KERNEL RHIZO_BOOT
  RHIZO_GUEST_OS RHIZO_BOOT_EVIDENCE_DIR RHIZO_PORT_OFFSET RHIZO_SKIP_BOOT RHIZO_VM_NAMED
  RHIZO_VM_HOOK RHIZO_PLUMBING_PREFIXES
  RHIZO_VM_CLAIM_WAIT
  RHIZO_RIG_EXCLUSIVE_HELD RHIZO_KERNEL_CACHE
  RHIZO_CHECK_ROOT RHIZO_CHECK_TOOLS RHIZO_SKIP_APT RHIZO_USE_UNIT RHIZO_RENDER_NODE RHIZO_VM_GPU "
# test a name against the launch env deny lists
launch_env_denied() {
  local p
  [[ " ${LAUNCH_ENV_DENY//[$'\n\t']/ } " == *" $1 "* ]] && return 0
  for p in ${RHIZO_PLUMBING_PREFIXES:-}; do [[ "$1" == "$p"* ]] && return 0; done
  return 1
}

while IFS='=' read -r _k _v; do
  [[ "$_k" == RHIZO_* ]] || continue
  launch_env_denied "$_k" && continue
  [[ "$_v" =~ [[:space:]] ]] || continue
  echo "redeploy.sh: REFUSING to launch -- $_k contains whitespace" >&2
  echo "  value: $_v" >&2
  echo "  pass a list comma-separated instead" >&2
  exit 2
done < <(env | grep '^RHIZO_')

if ! python3 ../checks/android/hal/hal-knobs.py --env; then
  echo "redeploy.sh: REFUSING to launch" >&2
  echo "  rebuild that binary with its tools/build/*.sh wrapper, or unset the knob" >&2
  exit 2
fi
if [[ "${RHIZO_SELINUX_MODE:-host}" != host ]]; then
  echo "redeploy.sh: REFUSING to launch -- RHIZO_SELINUX_MODE=$RHIZO_SELINUX_MODE; this rig launches host mode only" >&2
  echo "  run namespace mode on a test/vm/rhizo-kernel-vm.sh guest, or unset RHIZO_SELINUX_MODE" >&2
  exit 2
fi

check_stage_dirs "$SHARE_DIR" || exit 2

STAGE_FILES=(
  launcher3.py
  com.android.tethering.apex
  init.zygote64.rc
  init.zygote64_32.rc
  netd.rc
  surfaceflinger.rc
  audioserver.rc
  audio_policy_configuration.xml
  mediametrics.rc
  vold.rc
  cameraserver.rc
  wificond.rc
  init.vndk-nodef.rc
  product-build.prop
  rhizo-keymint-service
  rhizo-wayland-probe
  rhizo-probed
  rhizo-host-delay
  probe-client.py
  rhizo-hostfsd
  stack-meter.py
  align-apex.py
  detect-gpu-driver.sh
  rhizo-avc-capture.sh
  rhizo-fill-display-pool.sh
  rhizo-release-idle-display.sh
  rhizo-loop-unbound.rules
  RhizoAudioRouter.apk
  RhizoBootRro.apk
  RhizoSettingsRro.apk
  RhizoSettingsProviderRro.apk
  RhizoSoftwareRro.apk
  RhizoHome.apk
  RhizoDesktop.apk
  adbkey.pub
  plat_pub_versioned.cil
  hostops.py
)

RELEASE_RC=(init.zygote64.rc init.zygote64_32.rc netd.rc surfaceflinger.rc vold.rc init.vndk-nodef.rc product-build.prop)
RELEASE_SKIP=(com.android.tethering.apex audioserver.rc
              audio_policy_configuration.xml mediametrics.rc RhizoAudioRouter.apk)
# return whether the first argument equals one of the others
in_list() { local n="$1"; shift; local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1; }
OPTIONAL_STAGE_FILES=(com.android.tethering.apex)
STAGE_FILES+=(vold.rc)

RELEASE_GFX_HAL_BIN=(rhizo-power-service)

if [[ -f "$HOME/.android/adbkey.pub" ]]; then
  stage_to_share "$HOME/.android/adbkey.pub" "$VAR_DIR/share/adbkey.pub" \
    || { log "FAIL: could not stage adbkey.pub into $VAR_DIR/share"; exit 1; }
  stage_to_share "$HOME/.android/adbkey.pub" "$SHARE_DIR/adbkey.pub" \
    || { log "FAIL: could not stage adbkey.pub into $SHARE_DIR"; exit 1; }
else
  log "WARN: $HOME/.android/adbkey.pub not found -- staging empty placeholder, adb will come up unauthorized"
  : > "$SHARE_DIR/adbkey.pub"
fi

[[ -s "$SHARE_DIR/plat_pub_versioned.cil" ]] || {
  log "FAIL: $SHARE_DIR/plat_pub_versioned.cil not built -- run make plat_pub_versioned.cil first"
  exit 1
}

STAGE_VBMETA=0
if [[ -f "$SHARE_DIR/vbmeta.img" ]]; then
  STAGE_VBMETA=1
else
  log "WARN: $SHARE_DIR/vbmeta.img not built -- run tools/build/image/vbmeta.sh first; /dev/block/by-name/vbmeta will be absent this boot"
fi

log "Syncing staged copies from their sources..."
if ! ./sync.sh; then
  log "FAIL: sync.sh could not bring var/share/ up to date"
  exit 1
fi
log "  staged launcher3.py: $(sha256sum "$SHARE_DIR/launcher3.py" | cut -c1-16) (repo: $(sha256sum ../../src/androidd/boot.py | cut -c1-16))"

if [[ "$SKIP_KILL" == 0 ]]; then
  log "Killing any existing VM..."
  kill_vm
  log "Booting a new VM..."
  boot_vm
  wait_for_boot_slot || {
    log "FAIL: this vm's boot never got a qemu slot"
    exit 1
  }
  if ! wait_for_ssh 180; then
    if [[ -n "$RHIZO_BOOT_REFUSAL" ]]; then
      log "FAIL: vm refused before any guest launched: $RHIZO_BOOT_REFUSAL"
      export RHIZO_BOOT_NO_ROW=1
      collect_evidence "ssh-refused"
      unset RHIZO_BOOT_NO_ROW
      exit 1
    fi
    log "FAIL: SSH never came up"
    explain_dead_boot
    collect_evidence "ssh-never-came-up"
    exit 1
  fi
else
  wait_for_ssh 20 || { log "FAIL: --skip-kill but no VM is reachable"; exit 1; }
fi
guest_os=$(guest_os_id)
rc=$?
if (( rc != 0 )); then
  log "FAIL: could not read vm $RHIZO_VM's /etc/os-release (ssh_vm rc=$rc)"
  exit 1
elif [[ "$guest_os" != "$RHIZO_GUEST_OS" ]]; then
  log "FAIL: vm $RHIZO_VM runs ID=${guest_os:-<empty>} but RHIZO_GUEST_OS is '$RHIZO_GUEST_OS'"
  exit 1
fi

log "Staging files..."
guest_mount_share || { log "FAIL: could not mount the 9p share"; exit 1; }
EXPECTED_STAGE_CHUNKS=(
  prep kernel-check freeze-check modprobe-uinput modules-extra stage-dirs
  release-files cleanup-old-launch netbridged-account rhizo-lib-tools
  display-pool-units policy-service hostfs-streamd desktop-units unmask-enable
  androidd-service swap binfmt console-log
)
# check each chunk marker in both outputs
check_stage_chunks() {
  local built="$1" reply="$2" name missing_local="" missing_guest=""
  for name in "${EXPECTED_STAGE_CHUNKS[@]}"; do
    grep -q "RHIZO_STAGE_CHUNK=$name\$" <<<"$built" \
      || missing_local="$missing_local $name"
    grep -q "RHIZO_STAGE_CHUNK=$name\$" <<<"$reply" \
      || missing_guest="$missing_guest $name"
  done
  if [[ -n "$missing_local" ]]; then
    log "FAIL: stage_cmd's own value never carried:$missing_local"
    return 1
  fi
  if [[ -n "$missing_guest" ]]; then
    log "FAIL: the guest never echoed back:$missing_guest"
    return 1
  fi
  return 0
}
stage_cmd='set -e
mkdir -p /run/rhizo-audio /run/rhizo-wayland /var/lib/rhizo
mountpoint -q /run/rhizo-wayland || mount --rbind /run/rhizo-wayland /run/rhizo-wayland
mount --make-shared /run/rhizo-wayland
echo RHIZO_STAGE_CHUNK=prep'
stage_cmd+=$'\n'"RHIZO_GUEST_OS=$RHIZO_GUEST_OS"
stage_cmd+=$'\n''sys_useradd() { getent passwd "$1" >/dev/null 2>&1 || useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/bin/nologin "$1"; }'
stage_cmd+=$'\n'"sh /root/share/kernel-check.sh 2>&1 | sed 's/^/RHIZO_KERNEL_LACKS=/'
[ -d \"/lib/modules/\$(uname -r)\" ] || echo \"RHIZO_NO_MODULE_TREE=\$(uname -r)\"
grep -qw iso9660 /proc/filesystems || modprobe isofs 2>/dev/null || echo \"RHIZO_NO_ISOFS=\$(uname -r)\"
echo RHIZO_STAGE_CHUNK=kernel-check"
stage_cmd+=$'\n''mkdir -p /root/.rhizo_freeze_check
RHIZO_FREEZE_CHECK=absent
if mount -t binder binder /root/.rhizo_freeze_check 2>/dev/null; then
  RHIZO_FREEZE_CHECK=$(cat /root/.rhizo_freeze_check/features/freeze_notification 2>/dev/null || echo absent)
  umount /root/.rhizo_freeze_check 2>/dev/null || true
fi
rmdir /root/.rhizo_freeze_check 2>/dev/null || true
echo "RHIZO_FREEZE_NOTIFICATION_SUPPORT=$RHIZO_FREEZE_CHECK"
echo RHIZO_STAGE_CHUNK=freeze-check'
stage_cmd+=$'\n''modprobe uinput 2>/dev/null || true
echo RHIZO_STAGE_CHUNK=modprobe-uinput'
stage_cmd+=$'\n''case "$RHIZO_GUEST_OS" in
  cachyos) ;;
  *) bash /root/share/seed-modules-extra.sh ;;
esac
echo RHIZO_STAGE_CHUNK=modules-extra'
(( STAGE_VBMETA )) && stage_cmd+=$'\n''cp /root/share/vbmeta.img /root/vbmeta.img'
stage_cmd+=$'\n''STAGE_DIRS="'"$STAGE_DIR_NAMES"'"
if command -v rsync >/dev/null 2>&1; then
  for d in $STAGE_DIRS; do
    mkdir -p "/root/$d"
    rsync -a --delete --exclude __pycache__ "/root/share/$d/" "/root/$d/"
  done
else
  for d in $STAGE_DIRS; do
    rm -rf "/root/$d"
    cp -r "/root/share/$d" "/root/$d"
  done
fi
echo RHIZO_STAGE_CHUNK=stage-dirs'
if [[ -n "$RELEASE" && "$RELEASE" != a16 ]]; then
  # shellcheck source=tools/fetch/gsi-pins.sh
  pin_row=$(source ../../tools/fetch/gsi-pins.sh && gsi_pin_row "$RELEASE" | base64 -w0) \
    || { log "FAIL: tools/fetch/gsi-pins.sh has no $RELEASE pin"; exit 1; }
  stage_cmd+=$'\n'"mkdir -p /etc/rhizo && touch /etc/rhizo/gsi-pins.tsv && sed -i '/^$RELEASE\t/d' /etc/rhizo/gsi-pins.tsv && echo $pin_row | base64 -d >> /etc/rhizo/gsi-pins.tsv"
  log "  gsi pin for --release $RELEASE: /etc/rhizo/gsi-pins.tsv"
  for b in "${RELEASE_GFX_HAL_BIN[@]}"; do
    rel_bin="$SHARE_DIR/rel/$RELEASE/$b"
    if [[ -f "$rel_bin" ]]; then
      stage_cmd+=$'\n'"cp /root/share/rel/$RELEASE/$b /root/gfx_hal/$b"
      log "  gfx_hal override for --release $RELEASE: $b <- share/rel/$RELEASE/$b"
    fi
  done
fi
release_files_cmd=""
for f in "${STAGE_FILES[@]}"; do
  if [[ -d "$SHARE_DIR/$f" ]]; then
    log "REFUSING to stage -- STAGE_FILES names '$f', which is a DIRECTORY; put it in STAGE_DIR_NAMES (common.sh)"
    exit 1
  fi
  if in_list "$f" "${OPTIONAL_STAGE_FILES[@]}" && [[ ! -e "$SHARE_DIR/$f" ]]; then
    log "  optional stage file '$f' is not in $SHARE_DIR -- not staged, and an earlier copy is removed"
    release_files_cmd+=$'\n'"rm -f /root/$f"
    continue
  fi
  src="/root/share/$f"
  if [[ -n "$RELEASE" && "$RELEASE" != a16 ]]; then
    if in_list "$f" "${RELEASE_SKIP[@]}"; then
      release_files_cmd+=$'\n'"rm -f /root/$f"
      continue
    fi
    if in_list "$f" "${RELEASE_RC[@]}"; then
      src="/root/share/rel/$RELEASE/$f"
      if [[ ! -f "$SHARE_DIR/rel/$RELEASE/$f" ]]; then
        log "FAIL: $SHARE_DIR/rel/$RELEASE/$f is missing -- RHIZO_VM=$RHIZO_VM test/vm/redeploy.sh --no-launch, then RHIZO_VM=$RHIZO_VM test/vm/image/stage-gsi-trees.sh --derive-rel $RELEASE"
        exit 1
      fi
    fi
  fi
  release_files_cmd+=$'\n'"cp $src /root/$f"
done
stage_cmd+=$'\n'"$release_files_cmd
echo RHIZO_STAGE_CHUNK=release-files"
stage_cmd+=$'\n''rm -f /root/rhizo-launch.sh /root/appsync.py /root/resync.sh /root/.local/share/applications/rhizo-*.desktop
echo RHIZO_STAGE_CHUNK=cleanup-old-launch'
stage_cmd+=$'\n''case "$RHIZO_GUEST_OS" in
  cachyos) sys_useradd rhizo-netbridged ;;
  *) getent passwd rhizo-netbridged >/dev/null 2>&1 || adduser --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin --group --quiet rhizo-netbridged ;;
esac
echo RHIZO_STAGE_CHUNK=netbridged-account'
stage_cmd+=$'\n''install -d -m 0755 /usr/lib/rhizo && rm -rf /usr/lib/rhizo/netbridged && cp -r /root/share/netbridged /usr/lib/rhizo/netbridged && chmod -R a+rX /usr/lib/rhizo/netbridged'
stage_cmd+=$'\n''install -d -m 0755 /usr/lib/rhizo /usr/lib/rhizo/tools
install -m 0755 /root/share/rhizo-launch.sh /root/share/appsync.py /root/share/resync.sh /root/share/remove-entries.sh /root/share/app-events.py /root/share/hostfs.py /root/share/gen-rhizo-icon.py /root/share/kernel-check.sh /root/share/derive-patches.sh /root/share/aapt2 /usr/lib/rhizo/tools/
install -D -m 0644 /root/share/sandbox/capabilities.py /usr/lib/rhizo/tools/sandbox/capabilities.py
install -m 0644 /root/share/config-disable.prop /usr/lib/rhizo/tools/config-disable.prop
install -m 0644 /root/share/rhizo-cgroup-unfreeze.sh /usr/lib/rhizo/tools/rhizo-cgroup-unfreeze.sh
install -m 0644 /root/share/rhizo-display-list.sh /usr/lib/rhizo/tools/rhizo-display-list.sh
install -d -m 0755 /usr/lib/rhizo/sandbox
install -m 0644 /root/share/sandbox/*.py /usr/lib/rhizo/sandbox/
install -m 0644 /root/share/hostops.py /root/share/launcher3.py /usr/lib/rhizo/
install -m 0755 /root/share/probe-client.py /usr/lib/rhizo/probe-client.py
install -m 0755 /root/share/rhizo-selinux-mode.py /usr/lib/rhizo/rhizo-selinux-mode
install -d -m 0755 /etc/rhizo
touch /etc/rhizo/androidd.env
sed -i "/^RHIZO_SELINUX_MODE=/d" /etc/rhizo/androidd.env
echo RHIZO_SELINUX_MODE=host >> /etc/rhizo/androidd.env
install -m 0755 /root/share/detect-gpu-driver.sh /usr/lib/rhizo/detect-gpu-driver.sh
install -m 0755 /root/share/rhizo-probe-client /usr/lib/rhizo/rhizo-probe-client
install -m 0644 /root/share/dbus_min.py /usr/lib/rhizo/dbus_min.py
install -m 0644 /root/share/inbox_stage.py /usr/lib/rhizo/inbox_stage.py
install -d -m 0755 /usr/lib/udev/rules.d
install -m 0644 /root/share/70-rhizo-uinput.rules /usr/lib/udev/rules.d/70-rhizo-uinput.rules
case "$RHIZO_GUEST_OS" in
  cachyos) sys_useradd rhizo-uhid ;;
  *) getent passwd rhizo-uhid >/dev/null 2>&1 || adduser --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin --group rhizo-uhid >/dev/null ;;
esac
install -m 0755 /root/share/rhizo-inputd /usr/lib/rhizo/rhizo-inputd
install -m 0755 /root/share/rhizo-inputd /usr/lib/udev/rhizo-input-owned
cp /root/share/rhizo-inputd@.service /usr/lib/systemd/system/rhizo-inputd@.service
cp /root/share/rhizo-inputd-uhid@.service /usr/lib/systemd/system/rhizo-inputd-uhid@.service
install -D -m 0644 /root/share/rhizo-inputd-instance0.conf /usr/lib/systemd/system/rhizo-inputd@0.service.d/10-instance0.conf
install -D -m 0644 /root/share/rhizo-inputd-instance0.conf /usr/lib/systemd/system/rhizo-inputd-uhid@0.service.d/10-instance0.conf
udevadm control --reload || true
udevadm trigger --subsystem-match=misc --sysname-match=cuse --sysname-match=uhid || true
install -m 0755 /root/share/install/cli/rhizo.sh /usr/bin/rhizo
install -d -m 0755 /usr/lib/rhizo/install
for _group in bootstrap prepare update teardown lib cli; do
  install -d -m 0755 "/usr/lib/rhizo/install/$_group"
  install -m 0755 /root/share/install/"$_group"/* "/usr/lib/rhizo/install/$_group/"
done
rm -f /usr/lib/rhizo/install/cli/rhizo.sh
install -D -m 0644 /root/share/rhizo-console-vt.sh /etc/profile.d/rhizo-console-vt.sh
install -d -m 0755 /usr/lib/rhizo/broker
install -m 0755 /root/share/brokerd.py /root/share/broker-client.py /usr/lib/rhizo/broker/
install -d -m 0755 /usr/lib/rhizo/server-idle
install -m 0755 /root/share/server-idle.py /usr/lib/rhizo/server-idle/
install -d -m 0755 /usr/lib/rhizo/api
install -m 0755 /root/share/apid.py /usr/lib/rhizo/api/
install -d -m 0755 /usr/share/applications /usr/share/icons/hicolor/256x256/apps
install -m 0644 /root/share/rhizo-apk-installer.desktop /usr/share/applications/rhizo-apk-installer.desktop
python3 /root/share/gen-rhizo-icon.py /usr/share/icons/hicolor/256x256/apps/rhizo.png
chmod 0644 /usr/share/icons/hicolor/256x256/apps/rhizo.png
echo RHIZO_STAGE_CHUNK=rhizo-lib-tools'
stage_cmd+=$'\n''chmod +x /root/rhizo-fill-display-pool.sh /root/rhizo-release-idle-display.sh
mkdir -p /usr/lib/systemd/system
for leftover in /etc/systemd/system/rhizo-remove-entries.path /etc/systemd/system/rhizo-remove-entries.service /etc/systemd/system/rhizo-desktop-attach.path /etc/systemd/system/rhizo-desktop-attach.service; do
  if [ -f "$leftover" ] && [ ! -L "$leftover" ]; then rm -f "$leftover"; fi
done
cp /root/share/rhizo-remove-entries.path /usr/lib/systemd/system/rhizo-remove-entries.path
cp /root/share/rhizo-remove-entries.service /usr/lib/systemd/system/rhizo-remove-entries.service
cp /root/share/rhizo-desktop-attach.path /usr/lib/systemd/system/rhizo-desktop-attach.path
cp /root/share/rhizo-desktop-attach.service /usr/lib/systemd/system/rhizo-desktop-attach.service
cp /root/share/rhizo-session-start.path /usr/lib/systemd/system/rhizo-session-start.path
cp /root/share/rhizo-session-start.service /usr/lib/systemd/system/rhizo-session-start.service
cp /root/share/rhizo-resync.path /usr/lib/systemd/system/rhizo-resync.path
cp /root/share/rhizo-resync.service /usr/lib/systemd/system/rhizo-resync.service
cp /root/share/rhizo-app-events.service /usr/lib/systemd/system/rhizo-app-events.service
case "$RHIZO_GUEST_OS" in
  cachyos)
    [ "$(id -u deskuser)" = 1000 ] || { echo "FAIL: deskuser is not uid 1000 on this cachyos guest (id -u deskuser: $(id -u deskuser 2>&1))" >&2; exit 1; }
    mkdir -p /etc/rhizo
    echo deskuser > /etc/rhizo/desktop-user
    groupadd -f rhizo
    usermod -aG rhizo deskuser
    mkdir -p /etc/systemd/system/rhizo-app-events.service.d
    printf "[Service]\nUser=deskuser\nGroup=deskuser\n" > /etc/systemd/system/rhizo-app-events.service.d/10-desktop-user.conf
    ;;
  *)
id -u ubuntu >/dev/null 2>&1 || useradd -m -s /bin/bash ubuntu
groupadd -f rhizo
usermod -aG rhizo ubuntu
    ;;
esac
case "$RHIZO_GUEST_OS" in
  cachyos) sys_useradd rhizo-netbridged ;;
  *) getent passwd rhizo-netbridged >/dev/null 2>&1 || adduser --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin --group rhizo-netbridged ;;
esac
case "$RHIZO_GUEST_OS" in
  cachyos) ;;
  *)
if ! command -v xdg-open >/dev/null 2>&1 || ! command -v xdg-mime >/dev/null 2>&1 || ! command -v update-desktop-database >/dev/null 2>&1 || [ ! -f /usr/share/icons/hicolor/index.theme ]; then
  if ls /root/share/desktop-debs/*.deb >/dev/null 2>&1; then
    dpkg -i /root/share/desktop-debs/*.deb
  else
    echo "RHIZO_DESKTOP_DEBS=absent"
  fi
fi
if ! command -v conntrack >/dev/null 2>&1 || ! command -v adb >/dev/null 2>&1; then
  if ls /root/share/server-debs/*.deb >/dev/null 2>&1; then
    dpkg -i /root/share/server-debs/*.deb
  else
    echo "RHIZO_SERVER_DEBS=absent"
  fi
fi
    ;;
esac
if command -v update-desktop-database >/dev/null 2>&1; then
  /usr/bin/python3 /usr/lib/rhizo/tools/appsync.py --mimeapps-only
  update-desktop-database /usr/share/applications
else
  echo "RHIZO_DESKTOP_TOOLS=missing -- no update-desktop-database on this guest and no desktop-debs to install; run tools/fetch/pools/deb/fetch.sh desktop-debs and re-sync"
fi
mkdir -p /etc/systemd/system/run-rhizo.mount.d /etc/systemd/system/run-rhizo-data.mount.d
mkdir -p /usr/lib/systemd/system
cp /root/share/rhizo-resync-rearm.service /usr/lib/systemd/system/rhizo-resync-rearm.service
cp /root/share/run-rhizo.mount.d/rhizo-resync-rearm.conf /etc/systemd/system/run-rhizo.mount.d/rhizo-resync-rearm.conf
cp /root/share/run-rhizo-data.mount.d/rhizo-resync-rearm.conf /etc/systemd/system/run-rhizo-data.mount.d/rhizo-resync-rearm.conf
cp /root/share/rhizo-display-pool.path /usr/lib/systemd/system/rhizo-display-pool.path
cp /root/share/rhizo-display-pool.service /usr/lib/systemd/system/rhizo-display-pool.service
cp /root/share/rhizo-display-pool-release.service /usr/lib/systemd/system/rhizo-display-pool-release.service
echo RHIZO_STAGE_CHUNK=display-pool-units
cp /root/share/rhizo-policy.service /usr/lib/systemd/system/rhizo-policy.service
cp /root/share/rhizo-selinuxfs.service /usr/lib/systemd/system/rhizo-selinuxfs.service
cp /root/share/rhizo-selinux-mode.service /usr/lib/systemd/system/rhizo-selinux-mode.service
cp /root/share/rhizo-host-labels.service /usr/lib/systemd/system/rhizo-host-labels.service
systemctl daemon-reload
systemctl start rhizo-selinuxfs.service || { echo "FAIL: systemctl start rhizo-selinuxfs.service failed" >&2; exit 1; }
lsm=$(cat /sys/kernel/security/lsm) || { echo "FAIL: /sys/kernel/security/lsm is unreadable" >&2; exit 1; }
st=$(systemctl show -p ActiveState -p ConditionResult rhizo-selinuxfs.service | tr "\n" " ")
if [[ ",$lsm," == *,selinux,* ]]; then
  if [[ ! -e /sys/fs/selinux/enforce ]]; then
    echo "FAIL: selinux is an active LSM and /sys/fs/selinux/enforce does not exist, with rhizo-selinuxfs.service at ${st:-<unread>}" >&2
    exit 1
  fi
  echo "RHIZO_SELINUXFS=present enforce=$(cat /sys/fs/selinux/enforce) unit: ${st}"
else
  echo "RHIZO_SELINUXFS=not needed, selinux is not in the LSM list ($lsm)"
fi
systemctl mask rhizo-policy.service >/dev/null || { echo "FAIL: systemctl mask rhizo-policy.service failed" >&2; exit 1; }
if [[ ${RHIZO_POLICY_UNIT:-0} == 1 ]]; then
  systemctl unmask rhizo-policy.service
  mkdir -p /etc/systemd/system/rhizo-policy.service.d
  {
    echo "[Unit]"
    echo "ConditionPathExists="
    echo "ConditionPathExists=/root/launcher3.py"
    echo
    echo "[Service]"
    echo "ExecStart="
    echo "ExecStart=/usr/bin/python3 /root/launcher3.py selinux_setup --policy-only"
    echo "ExecStop="
    echo "ExecStop=/usr/bin/python3 /root/launcher3.py policy-stop"
  } > /etc/systemd/system/rhizo-policy.service.d/10-rig-paths.conf
  systemctl daemon-reload
  systemctl enable rhizo-policy.service >/dev/null
  log RHIZO_POLICY_UNIT=1: rhizo-policy.service unmasked, enabled, and repointed at /root/launcher3.py
fi
echo RHIZO_STAGE_CHUNK=policy-service
cp /root/share/rhizo-hostfs.service /usr/lib/systemd/system/rhizo-hostfs.service
cp /root/share/rhizo-kernel-refresh.service /usr/lib/systemd/system/rhizo-kernel-refresh.service
cp /root/share/rhizo-update-begin.service /etc/systemd/system/rhizo-update-begin.service
cp /root/share/rhizo-update-confirm.service /etc/systemd/system/rhizo-update-confirm.service
cp /root/share/rhizo-server-idle.service /usr/lib/systemd/system/rhizo-server-idle.service
cp /root/share/rhizo-server-idle@.service /usr/lib/systemd/system/rhizo-server-idle@.service
cp /root/share/rhizo-api.socket /usr/lib/systemd/system/rhizo-api.socket
cp /root/share/rhizo-api@.service /usr/lib/systemd/system/rhizo-api@.service
cp /root/share/rhizo-streamd.socket /usr/lib/systemd/system/rhizo-streamd.socket
cp /root/share/rhizo-streamd.service /usr/lib/systemd/system/rhizo-streamd.service
cp /root/share/rhizo-stream-capability.path /usr/lib/systemd/system/rhizo-stream-capability.path
cp /root/share/rhizo-stream-capability.service /usr/lib/systemd/system/rhizo-stream-capability.service
install -d -m 0755 /usr/lib/rhizo/streamd
install -m 0755 /root/share/rhizo-streamd /root/share/capability-sync.sh /usr/lib/rhizo/streamd/
install -m 0644 /root/share/viewer.html /usr/lib/rhizo/streamd/
echo RHIZO_STAGE_CHUNK=hostfs-streamd
systemctl stop rhizo-desktop-session.path rhizo-desktop-session.service >/dev/null 2>&1 || true
rm -f /usr/lib/systemd/system/rhizo-desktop-session.path /usr/lib/systemd/system/rhizo-desktop-session.service
rm -f /etc/systemd/system/rhizo-desktop-session.path /etc/systemd/system/rhizo-desktop-session.service
rm -f /etc/systemd/system/multi-user.target.wants/rhizo-desktop-session.path
rm -rf /etc/systemd/system/rhizo-desktop-session.service.d
install -d -m 0755 /usr/lib/systemd/user
cp /root/share/rhizo-desktop-session.path /usr/lib/systemd/user/rhizo-desktop-session.path
cp /root/share/rhizo-desktop-session.service /usr/lib/systemd/user/rhizo-desktop-session.service
cp /root/share/rhizo-desk-notify.path /usr/lib/systemd/user/rhizo-desk-notify.path
cp /root/share/rhizo-desk-notify.service /usr/lib/systemd/user/rhizo-desk-notify.service
install -D -m 0644 /root/share/rhizo-desktop-session.tmpfiles /usr/lib/tmpfiles.d/rhizo-desktop-session.conf
systemd-tmpfiles --create rhizo-desktop-session.conf
install -D -m 0644 /root/share/rhizo-run-root.tmpfiles /usr/lib/tmpfiles.d/rhizo-run-root.conf
systemd-tmpfiles --create rhizo-run-root.conf
cp /root/share/rhizo-deskd.service /usr/lib/systemd/system/rhizo-deskd.service
cp /root/share/rhizo-desk-token.service /usr/lib/systemd/system/rhizo-desk-token.service
cp /root/share/rhizo-audiod.service /usr/lib/systemd/system/rhizo-audiod.service
cp /root/share/rhizo-displayd.service /usr/lib/systemd/system/rhizo-displayd.service
cp /root/share/rhizo-keymapd.service /usr/lib/systemd/system/rhizo-keymapd.service
cp /root/share/rhizo-rtd.service /usr/lib/systemd/system/rhizo-rtd.service
cp /root/share/rhizo-delayd.service /usr/lib/systemd/system/rhizo-delayd.service
cp /root/share/rhizo-headroomd.service /usr/lib/systemd/system/rhizo-headroomd.service
cp /root/share/rhizo-btd.service /usr/lib/systemd/system/rhizo-btd.service
install -D -m 0644 /root/share/androidd-btd.conf /usr/lib/systemd/system/androidd.service.d/24-btd.conf
install -d -m 0755 /usr/lib/rhizo/deskbridge /usr/lib/rhizo/audiod \
                   /usr/lib/rhizo/displayd /usr/lib/rhizo/keymapd /usr/lib/rhizo/rtd
install -m 0755 /root/share/deskd.py /root/share/desk-token.py /root/share/desk-notify.py \
                /root/share/rhizo-wlbridge /usr/lib/rhizo/deskbridge/
install -m 0755 /root/share/rhizo-audiod /usr/lib/rhizo/audiod/
install -m 0755 /root/share/displayd.py /usr/lib/rhizo/displayd/
install -m 0755 /root/share/keymapd.py /usr/lib/rhizo/keymapd/
install -m 0755 /root/share/rtd.py /usr/lib/rhizo/rtd/
install -m 0755 /root/share/rhizo-delayd /usr/lib/rhizo/rhizo-delayd
install -m 0755 /root/share/rhizo-headroomd /usr/lib/rhizo/rhizo-headroomd
install -D -m 0755 /root/share/btd.py /usr/lib/rhizo/btd/btd.py
install -m 0755 /root/share/capability-allowed.sh /usr/lib/rhizo/tools/capability-allowed.sh
cp /root/share/rhizo-brokerd.socket /etc/systemd/system/rhizo-brokerd.socket
cp /root/share/rhizo-brokerd@.service /etc/systemd/system/rhizo-brokerd@.service
cp /root/share/rhizo-user-prep@.service /etc/systemd/system/rhizo-user-prep@.service
cp /root/share/rhizo-session-vt@.service /etc/systemd/system/rhizo-session-vt@.service
install -d -m 0755 /etc/rhizo
echo RHIZO_STAGE_CHUNK=desktop-units
systemctl unmask rhizo-display-pool.path rhizo-display-pool.service rhizo-display-pool-release.service \
                 rhizo-app-events.service rhizo-resync.path rhizo-resync.service \
                 rhizo-resync-rearm.service rhizo-remove-entries.path rhizo-remove-entries.service \
                 rhizo-desktop-attach.path rhizo-desktop-attach.service \
                 rhizo-session-start.path rhizo-session-start.service \
                 rhizo-hostfs.service rhizo-deskd.service rhizo-audiod.service \
                 rhizo-displayd.service rhizo-keymapd.service >/dev/null
systemctl --global unmask rhizo-desktop-session.path rhizo-desktop-session.service \
                          rhizo-desk-notify.path rhizo-desk-notify.service >/dev/null
systemctl daemon-reload
systemctl enable rhizo-remove-entries.path >/dev/null
systemctl enable rhizo-desktop-attach.path >/dev/null
systemctl enable rhizo-session-start.path >/dev/null
systemctl enable rhizo-resync.path >/dev/null
systemctl enable rhizo-app-events.service >/dev/null
systemctl enable rhizo-display-pool.path >/dev/null
systemctl enable rhizo-display-pool-release.service >/dev/null
systemctl disable rhizo-hostfs.service >/dev/null 2>&1
systemctl --global enable rhizo-desktop-session.path rhizo-desk-notify.path >/dev/null
systemctl enable rhizo-brokerd.socket >/dev/null
systemctl enable rhizo-stream-capability.path >/dev/null
systemctl reset-failed rhizo-resync.path rhizo-app-events.service rhizo-display-pool.path rhizo-display-pool.service rhizo-display-pool-release.service rhizo-brokerd.socket
systemctl restart rhizo-app-events.service
systemctl restart rhizo-brokerd.socket
systemctl restart rhizo-display-pool-release.service
systemctl restart rhizo-desktop-attach.path
systemctl restart rhizo-session-start.path
systemctl daemon-reload
if systemctl is-failed --quiet rhizo-rtd.service; then systemctl reset-failed rhizo-rtd.service; fi
systemctl start rhizo-rtd.service
if systemctl is-failed --quiet rhizo-delayd.service; then systemctl reset-failed rhizo-delayd.service; fi
systemctl start rhizo-delayd.service
if systemctl is-failed --quiet rhizo-headroomd.service; then systemctl reset-failed rhizo-headroomd.service; fi
systemctl start rhizo-headroomd.service
if systemctl is-failed --quiet rhizo-btd.service; then systemctl reset-failed rhizo-btd.service; fi
systemctl start rhizo-btd.service
echo RHIZO_STAGE_CHUNK=unmask-enable'
stage_cmd+=$'\n''cp /root/share/androidd.service /etc/systemd/system/androidd.service
cp /root/share/androidd@.service /etc/systemd/system/androidd@.service
for u in androidd.service androidd@.service; do
  mkdir -p /etc/systemd/system/$u.d
  printf "[Service]\nEnvironment=RHIZO_RIG_LOAD_UNDER_LOGIN=1\n" > /etc/systemd/system/$u.d/10-rig-load-under-login.conf
done
systemctl daemon-reload
echo RHIZO_STAGE_CHUNK=androidd-service'
stage_cmd+=$'\n''case "$RHIZO_GUEST_OS" in
  cachyos)
    swapon --noheadings --show=NAME | grep -qx /dev/zram0 \
      || { echo "FAIL: no swap on /dev/zram0 on this cachyos guest, swapon lists: $(swapon --noheadings | tr "\n" " ")" >&2; exit 1; }
    ;;
  *)
if [ "$(wc -l < /proc/swaps)" -lt 2 ]; then
  if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 0600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile 2>/dev/null || true
fi
    ;;
esac
echo "RHIZO_SWAP_KB=$(grep ^SwapTotal /proc/meminfo | tr -s " " | cut -d" " -f2)"
echo RHIZO_STAGE_CHUNK=swap'
stage_cmd+=$'\n''case "$RHIZO_GUEST_OS" in
  cachyos)
    systemctl start proc-sys-fs-binfmt_misc.mount \
      || { echo "FAIL: could not mount binfmt_misc before the launch: $(systemctl status proc-sys-fs-binfmt_misc.mount 2>&1 | tail -3)" >&2; exit 1; } ;;
esac
echo RHIZO_STAGE_CHUNK=binfmt'
RHIZO_CONSOLE_PROBE="RHIZO_CONSOLE_PROBE_$$_$(date +%s)"
stage_cmd+=$'\n'"if [ -e /etc/systemd/network/90-rhizo-veth.network ]; then rm -f /etc/systemd/network/90-rhizo-veth.network; networkctl reload; fi
chmod 0666 /dev/kmsg
printf 'kernel.printk = ${RHIZO_CONSOLE_LOGLEVEL:-8} 4 1 7\\n' > /etc/sysctl.d/99-rhizo-console.conf
sysctl -q -w kernel.printk='${RHIZO_CONSOLE_LOGLEVEL:-8} 4 1 7' 2>/dev/null || echo ${RHIZO_CONSOLE_LOGLEVEL:-8} > /proc/sys/kernel/printk
echo \"RHIZO_CONSOLE_LOGLEVEL=\$(cut -f1 /proc/sys/kernel/printk)\"
printf '<5>%s\\n' '$RHIZO_CONSOLE_PROBE' > /dev/kmsg
journalctl --vacuum-size=200M >/dev/null 2>&1 || true
case \"\$RHIZO_GUEST_OS\" in
  cachyos) ;;
  *)
for f in /var/log/syslog /var/log/kern.log; do if [ -f \$f ] && [ \$(stat -c%s \$f) -gt 314572800 ]; then truncate -s0 \$f; fi; done
rm -f /var/log/syslog.[0-9]* /var/log/kern.log.[0-9]*
    ;;
esac
echo RHIZO_STAGE_CHUNK=console-log
echo STAGED_OK"

if ! out=$(ssh_vm -t 45 "$stage_cmd" 2>&1); then
  log "FAIL: staging failed:"; echo "$out" >&2; exit 1
fi
grep -q STAGED_OK <<<"$out" || { log "FAIL: staging did not confirm"; echo "$out" >&2; exit 1; }
check_stage_chunks "$stage_cmd" "$out" || { echo "$out" >&2; exit 1; }
selinuxfs_line=$(grep -o 'RHIZO_SELINUXFS=.*' <<<"$out" | tail -1)
[[ -n "$selinuxfs_line" ]] || { log "FAIL: the guest never reported RHIZO_SELINUXFS"; echo "$out" >&2; exit 1; }
log "$selinuxfs_line"

case "$RHIZO_GUEST_OS" in
  cachyos)
    log "graphics stack: carried by the cachyos dev base (tools/build/vm/cachyos-dev.sh), no deb pool to install"
    ;;
  *)
    if ! ./start/start-sway.sh --install-only >/dev/null 2>&1; then
      log "WARNING: the graphics stack could not be installed or configured on this vm"
      log "  run test/vm/start/start-sway.sh directly to see why"
    fi
    if [[ -d "$SHARE_DIR/pipewire-debs" ]] && ! ./start/start-audio.sh --install-only >/dev/null 2>&1; then
      log "WARNING: pipewire could not be installed or configured on this vm"
      log "  run test/vm/start/start-audio.sh --install-only directly to see why"
    fi
    ;;
esac

_console_level=$(grep -o 'RHIZO_CONSOLE_LOGLEVEL=[0-9]*' <<<"$out" | head -1 | cut -d= -f2)
if grep -q "$RHIZO_CONSOLE_PROBE" "$VAR_DIR/vm-boot${SUFFIX}.log" 2>/dev/null; then
  log "console channel OK: a <5> notice line reaches vm-boot${SUFFIX}.log (console_loglevel=${_console_level:-?})"
else
  log "WARNING: the serial console is NOT carrying notice-level kmsg (console_loglevel=${_console_level:-unreadable})."
  log "  L3:/L3-primer:/RHIZO_MARKER lines reach only the guest's own dmesg, not vm-boot${SUFFIX}.log"
fi
if grep -q RHIZO_KERNEL_LACKS <<<"$out"; then
  log "FAIL: $(grep -o 'RHIZO_KERNEL_LACKS=.*' <<<"$out" | head -1 | cut -d= -f2-)"
  exit 1
fi
if grep -q RHIZO_NO_MODULE_TREE <<<"$out"; then
  log "FAIL: $(grep -o 'RHIZO_NO_MODULE_TREE=[^ ]*' <<<"$out") -- this guest has no /lib/modules for the kernel it booted"
  log "  test/vm/image/install-kernel.sh installs the Rhizo kernel with its modules into this vm's disk"
  exit 1
fi
if grep -q 'RHIZO_MODULES_EXTRA=absent' <<<"$out"; then
  log "FAIL: $(grep -o 'RHIZO_MODULES_EXTRA=absent[^ ]* [^ ]*' <<<"$out")"
  log "  put that kernel's linux-modules-extra package at $SHARE_DIR/modules-extra.deb"
  exit 1
fi
grep -q 'RHIZO_MODULES_EXTRA=seeded' <<<"$out" \
  && log "$(grep -o 'RHIZO_MODULES_EXTRA=seeded[^ ]* [^ ]*' <<<"$out"): linux-modules-extra unpacked into the guest's module tree"
if grep -q RHIZO_NO_ISOFS <<<"$out"; then
  log "FAIL: $(grep -o 'RHIZO_NO_ISOFS=[^ ]*' <<<"$out") -- no iso9660 support"
  exit 1
fi
log "Staged OK"
swap_kb=$(grep -o 'RHIZO_SWAP_KB=[0-9]*' <<<"$out")
[[ -n "$swap_kb" ]] && log "$swap_kb"
freeze_support=$(grep -o 'RHIZO_FREEZE_NOTIFICATION_SUPPORT=.*' <<<"$out")
log "Binder freeze-notification support: ${freeze_support:-RHIZO_FREEZE_NOTIFICATION_SUPPORT=unknown (debug line missing from staging output)}"
if [[ "$freeze_support" != "RHIZO_FREEZE_NOTIFICATION_SUPPORT=1" ]]; then
  log "FAIL: ${freeze_support:-RHIZO_FREEZE_NOTIFICATION_SUPPORT is missing from the staging output}"
  log "  the running kernel's built-in binder does not report freeze-notification support"
  exit 1
fi

# rebuild the vm's prepared tree
prepared_tree_refresh() {
  local why state enforce out key reason
  why=$(ssh_vm -t 30 'cd /root && python3 -c "from sandbox import core; k, r = core.validate_prepared(); print(\"RHIZO_PREPARED_VERDICT=\" + (r or \"accepted\"))" 2>/dev/null' \
        | grep -o 'RHIZO_PREPARED_VERDICT=[^ ]*' | tail -1 | cut -d= -f2)
  case "$why" in
    accepted|"") return 0 ;;
    manifest-unreadable)
      state=$(ssh_vm -t 15 'p=/var/lib/rhizo/prepared; [ -e $p/current ] || exit 0; k=$(readlink $p/current); echo "current=${k:-not-a-symlink} manifest=$(stat -c %sB $p/$k/manifest.json 2>/dev/null || echo absent)"' | tr -d '\r')
      if [[ -n "$state" ]]; then
        why="manifest-unreadable $state"
      elif [[ "$RHIZO_GUEST_OS" == cachyos ]]; then
        why="absent on a cachyos vm"
      else
        return 0
      fi ;;
    kernel|gsi-fingerprint)
      log "prepared tree refused for '$why'"
      return 0 ;;
  esac
  enforce=$(ssh_vm -t 15 'cat /sys/fs/selinux/enforce 2>/dev/null' | tr -d '[:space:]')
  if [[ "$enforce" != 0 ]]; then
    log "prepared tree refused for '$why' and the guest is enforcing (prepared_refused=$why)"
    return 0
  fi
  log "prepared tree refused for '$why' -- rebuilding the tree half (src/install/prepare/prepare.sh step 4, no boot)"
  if ! ssh_vm -t 15 "test -s /srv/rhizo/gsi_system/bin/init" >/dev/null 2>&1; then
    log "no GSI tree at /srv/rhizo/gsi_system to build it from, staging the a16 tree"
    ./image/stage-gsi-trees.sh a16 || { log "FAIL: could not stage the a16 GSI tree at /srv/rhizo/gsi_system"; return 1; }
  fi
  out=$(ssh_vm -t 900 "dri=$gpu_mode; "'gpu=; [ "$dri" = off ] || gpu=$(bash /root/share/detect-gpu-driver.sh 2>/dev/null); flag=""; case "$gpu" in intel|amd) flag="--gpu-driver gpu_driver_$gpu" ;; esac; python3 /root/launcher3.py prepare-tree /var/lib/rhizo/prepared $flag 2>&1 | tail -3' 2>&1)
  key=$(sed -n 's/^PREPARE_TREE_OK key=\([0-9a-f]*\).*/\1/p' <<<"$out" | tail -1)
  if [[ -n "$key" ]]; then
    log "prepared tree rebuilt: key=$key (was refused for '$why')"
    return 0
  fi
  reason=$(grep -o 'PREPARE_TREE_REFUSED reason=[^ ]*' <<<"$out" | tail -1)
  if [[ -n "$reason" ]]; then
    log "prepared tree NOT rebuilt ($reason)"
    return 0
  fi
  log "FAIL: prepare-tree did not report success: $(tail -1 <<<"$out")"
  return 1
}
gpu_mode=${RHIZO_VM_GPU:-on}
if ! gpu_change=$(ssh_vm -t 30 "[ $gpu_mode != off ] || { mkdir -p /etc/rhizo && touch /etc/rhizo/policy.conf; } && python3 - $gpu_mode /etc/rhizo/policy.conf" < image/guest-policy-dri.py); then
  log "FAIL: could not set devices.dri for RHIZO_VM_GPU=$gpu_mode in the guest's /etc/rhizo/policy.conf"
  exit 1
fi
[[ "$gpu_change" == *changed* && "$gpu_change" != *unchanged* ]] \
  && log "guest policy: devices.dri $([[ $gpu_mode == off ]] && echo "on -> off" || echo "off -> on") (RHIZO_VM_GPU=$gpu_mode)"
if [[ -z "$RELEASE" || "$RELEASE" == a16 ]]; then
  prepared_tree_refresh || exit 1
fi

# print the unit's ExecStartPost line
setup_marker_cmd() {
  local line
  line=$(sed -n 's/^ExecStartPost=//p' "$1" | head -1)
  [[ "$line" == "/bin/sh -c '"*"'" ]] || return 1
  [[ "${line//%%/}" != *%* ]] || return 1
  [[ ! "$line" =~ \$\{|\$[A-Za-z_] ]] || return 1
  printf '%s\n' "${line//%%/%}"
}
# write the setup marker on the guest
record_setup_marker() {
  local cmd out got want
  if ! cmd=$(setup_marker_cmd ../../src/services/units/boot/prepare.service); then
    log "FAIL: rhizo-prepare.service's ExecStartPost= is not a plain /bin/sh -c '...' line this deploy can replay"
    return 1
  fi
  out=$(ssh_vm -t 20 "$cmd && echo \"RHIZO_SETUP_MARKER kernel=\$(sed -n 's/^kernel=//p' /var/lib/rhizo/.prepared) uname=\$(uname -r)\"" 2>&1 | tr -d '\r')
  read -r _ got want < <(grep '^RHIZO_SETUP_MARKER ' <<<"$out" | tail -1)
  if [[ -z "${got#kernel=}" || "${got#kernel=}" != "${want#uname=}" ]]; then
    log "FAIL: could not record the setup marker /var/lib/rhizo/.prepared on the guest (guest said: $(tr '\n' '|' <<<"$out"))"
    return 1
  fi
  log "setup marker recorded as rhizo-prepare.service writes it: /var/lib/rhizo/.prepared $got"
}
record_setup_marker || exit 1

LAUNCH_ENV=""
[[ -n "${RHIZO_NO_RESIZE:-}" ]] && LAUNCH_ENV="RHIZO_NO_RESIZE=$RHIZO_NO_RESIZE "
[[ -n "${RHIZO_ENFORCING:-}" ]] && LAUNCH_ENV+="RHIZO_ENFORCING=$RHIZO_ENFORCING "
[[ -n "${RHIZO_PERMISSIVE:-}" ]] && LAUNCH_ENV+="RHIZO_PERMISSIVE=$RHIZO_PERMISSIVE "
[[ -n "${RHIZO_NO_HOST_PRIME:-}" ]] && LAUNCH_ENV+="RHIZO_NO_HOST_PRIME=$RHIZO_NO_HOST_PRIME "
LAUNCH_ENV+="RHIZO_WIPE_DATA=${RHIZO_WIPE_DATA:-0} "
LAUNCH_ENV+="RHIZO_RIG_LOAD_UNDER_LOGIN=${RHIZO_RIG_LOAD_UNDER_LOGIN:-1} "
LAUNCH_ENV+="RHIZO_SELINUX_MODE=${RHIZO_SELINUX_MODE:-host} "
[[ -n "${RHIZO_WAYLAND_HOST_SOCKET:-}" ]] && LAUNCH_ENV+="RHIZO_WAYLAND_HOST_SOCKET=$RHIZO_WAYLAND_HOST_SOCKET "
[[ -n "${RHIZO_FLIP_EARLY:-}" ]] && LAUNCH_ENV+="RHIZO_FLIP_EARLY=$RHIZO_FLIP_EARLY "
[[ -n "${RHIZO_SEPOLICY_NODONTAUDIT:-}" ]] && LAUNCH_ENV+="RHIZO_SEPOLICY_NODONTAUDIT=$RHIZO_SEPOLICY_NODONTAUDIT "
[[ -n "${RHIZO_ADB_ROOT:-}" ]] && LAUNCH_ENV+="RHIZO_ADB_ROOT=$RHIZO_ADB_ROOT "
[[ -n "${RHIZO_STOP_TIMEOUT:-}" ]] && LAUNCH_ENV+="RHIZO_STOP_TIMEOUT=$RHIZO_STOP_TIMEOUT "
[[ -n "$RELEASE" ]] && LAUNCH_ENV+="RHIZO_RELEASE=$RELEASE "
[[ -n "${RHIZO_VM:-}" ]] && LAUNCH_ENV+="RHIZO_VM=$RHIZO_VM "
if [[ "$DO_LAUNCH" != 0 && -z "$GSI_PATH" ]] && ! ssh_vm -t 15 "test -s /srv/rhizo/gsi_system/bin/init" >/dev/null 2>&1; then
  log "no GSI tree at /srv/rhizo/gsi_system on this vm, staging the a16 tree"
  ./image/stage-gsi-trees.sh a16 || { log "FAIL: could not stage the a16 GSI tree at /srv/rhizo/gsi_system"; exit 1; }
  ssh_vm -t 15 "test -s /srv/rhizo/gsi_system/bin/init" >/dev/null 2>&1 \
    || { log "FAIL: stage-gsi-trees.sh a16 left no bin/init at /srv/rhizo/gsi_system"; exit 1; }
fi
# derive the booting tree's libraries and stock patches
derive_booting_tree_set() {
  local out rc
  staged_set_is_of_tree "$RELEASE" "$GSI_PATH" && return 0
  log "  $GSI_PATH is not the tree the staged stock files came from, deriving its own on the guest"
  out=$(ssh_vm -t 300 "bash -s -- '$GSI_PATH'" < ./image/guest-derive-tree.sh 2>&1)
  rc=$?
  if (( rc != 0 )) || ! grep -q '^RHIZO_TREE_DERIVED ' <<<"$out"; then
    log "FAIL: could not derive $GSI_PATH's own libraries and stock patches (rc=$rc): $(tail -3 <<<"$out" | tr '\n' ' ')"
    return 1
  fi
  log "  $(grep '^RHIZO_TREE_DERIVED ' <<<"$out" | tail -1)"
}
if [[ "$DO_LAUNCH" != 0 && -n "$GSI_PATH" ]]; then
  if ! ssh_vm -t 15 "test -x '$GSI_PATH/bin/init'" >/dev/null 2>&1; then
    if [[ -n "$RELEASE" ]]; then
      log "no GSI tree at $GSI_PATH on this vm, staging it for release $RELEASE"
      if ! ./image/stage-gsi-trees.sh "$RELEASE"; then
        log "FAIL: could not stage a GSI tree at $GSI_PATH for release $RELEASE"
        exit 1
      fi
    fi
    if ! ssh_vm -t 15 "test -x '$GSI_PATH/bin/init'" >/dev/null 2>&1; then
      log "FAIL: --gsi '$GSI_PATH' is not a staged GSI tree on the guest (no bin/init)"
      [[ -z "$RELEASE" ]] && log "  no --release was given"
      exit 1
    fi
  fi
  derive_booting_tree_set || exit 1
  LAUNCH_ENV+="RHIZO_GSI=$GSI_PATH "
  log "Booting GSI tree: $GSI_PATH"
fi

while IFS='=' read -r _k _v; do
  [[ "$_k" == RHIZO_* ]] || continue
  launch_env_denied "$_k" && continue
  [[ " $LAUNCH_ENV " == *" $_k="* ]] && continue
  LAUNCH_ENV+="$_k=$_v "
done < <(env | grep '^RHIZO_')
# print the androidd.env write commands
_androidd_env_cmd() {
  local cmd kv
  cmd=": > /root/androidd.env"
  cmd+=$'\n'"rm -f /var/lib/rhizo/androidd-runtime.env"
  for kv in $LAUNCH_ENV; do
    cmd+=$'\n'"echo '$kv' >> /root/androidd.env"
  done
  printf '%s' "$cmd"
}

if [[ "${RHIZO_USE_UNIT:-0}" != "1" || "$DO_LAUNCH" == 0 ]]; then
  ssh_vm -t 30 "$(_androidd_env_cmd)" >/dev/null 2>&1 \
    || log "note: could not write /root/androidd.env"
fi

case "$RHIZO_GUEST_OS" in
  cachyos) rig_desktop_user=deskuser ;;
  *) rig_desktop_user=ubuntu ;;
esac
# print RHIZO_DESKTOP_SESSION for the guest desktop user
resolve_desktop_session() {
  ssh_vm -t 30 "u=; if [ -e /etc/rhizo/desktop-user ]; then u=\$(tr -d '[:space:]' < /etc/rhizo/desktop-user); fi; [ -n \"\$u\" ] || u=$rig_desktop_user
uid=\$(id -u \"\$u\" 2>/dev/null)
if [ -z \"\$uid\" ] || ! runuser -u \"\$u\" -- sh -c 'for f in /run/user/\$(id -u)/wayland-[0-9]*; do [ -S \"\$f\" ] && exit 0; done; exit 1'; then
  echo 'RHIZO_DESKTOP_SESSION=none'
elif [ \"\$(systemctl is-active user@\$uid.service)\" != active ]; then
  echo \"RHIZO_DESKTOP_SESSION=failed \$u has a Wayland socket and no running user@\$uid.service to resolve it\"
elif ! out=\$(runuser -u \"\$u\" -- env XDG_RUNTIME_DIR=/run/user/\$uid sh -c 'systemctl --user daemon-reload && systemctl --user start rhizo-desktop-session.path rhizo-desk-notify.path && systemctl --user restart rhizo-desktop-session.service' 2>&1); then
  echo \"RHIZO_DESKTOP_SESSION=failed \$out\"
else
  sed -n 's/^RHIZO_WAYLAND_HOST_SOCKET=/RHIZO_DESKTOP_SESSION=/p' /run/rhizo-desktop/session.env
fi"
}
desk_session=$(resolve_desktop_session)
log "${desk_session:-RHIZO_DESKTOP_SESSION=unread (no answer over ssh)}"
if [[ "$desk_session" == RHIZO_DESKTOP_SESSION=failed* && -z "${RHIZO_WAYLAND_HOST_SOCKET:-}" && "$DO_LAUNCH" == 1 ]]; then
  log "FAIL: the desktop user has a Wayland socket but rhizo-desktop-session.service could not resolve it"
  exit 1
fi

if [[ "$DO_LAUNCH" == 0 ]]; then
  log "Done (--no-launch, not starting the sandbox; /root/androidd.env recorded the forwarded RHIZO_* knobs above)"
  exit 0
fi

log "Launching boot.py selinux_setup..."
if [[ "${RHIZO_USE_UNIT:-0}" == "1" ]]; then
  env_cmd=$(_androidd_env_cmd)
  env_cmd+=$'\n'"echo 'RHIZO_RESIDENT_G=1' >> /root/androidd.env"
  env_cmd+=$'\n'"echo 'RHIZO_RESIDENT_DISPATCH=1' >> /root/androidd.env"
  log "Launching via androidd.service (RHIZO_USE_UNIT=1)..."
  ssh_vm -t "$((BOOT_WAIT + 60))" "$env_cmd
: > /root/boot.log
systemctl daemon-reload
systemctl start androidd.service" || log "systemctl start reported failure"
  log "polling sys.boot_completed directly"
  _fallback_ok=0
  for _i in $(seq 1 "$BOOT_WAIT"); do
    _init=$(guest_init_pid 10)
    if [[ -n "$_init" ]]; then
      _bc=$(getprop_vm "$_init" sys.boot_completed 2>/dev/null)
      if [[ "$_bc" == "1" ]]; then _fallback_ok=1; break; fi
    fi
    sleep 1
  done
  if (( ! _fallback_ok )); then
    log "FAIL: androidd.service started but sys.boot_completed never reached 1 within ${BOOT_WAIT}s; read 'journalctl -u androidd.service' and /root/boot.log on the guest"
    collect_evidence "androidd-start-failed"
    exit 1
  fi
  log "confirmed via direct poll: sys.boot_completed=1 (init_pid=$_init)"
  ssh_vm -t 15 "systemctl reset-failed rhizo-display-pool.service rhizo-display-pool.path rhizo-resync.path 2>/dev/null; systemctl restart rhizo-display-pool.path rhizo-resync.path; systemctl restart rhizo-app-events.service; systemctl start --no-block rhizo-display-pool.service rhizo-hostfs.service" >/dev/null 2>&1
else
  ssh_vm -t 10 "cd /root && systemd-run --scope --collect --unit=rhizo-launcher-\$\$ --quiet --expand-environment=no -- \
    sh -c 'chrt --other --pid 0 \$\$ > /root/boot.log 2>&1 && renice -n 0 -p \$\$ > /dev/null 2>> /root/boot.log && ionice -c 0 -p \$\$ >> /root/boot.log 2>&1 && ${LAUNCH_ENV}setsid python3 /root/launcher3.py selinux_setup >> /root/boot.log 2>&1 < /dev/null' & disown; sleep 1; echo launched" >/dev/null 2>&1 || true
fi

INIT_PID=$(wait_for_init 90) || { log "FAIL: init never started"; collect_evidence "init-never-started"; exit 1; }
log "init second_stage pid=$INIT_PID"

log "Polling sys.boot_completed for up to ${BOOT_WAIT}s..."
start=$(date +%s)
last_ss_pid=""
ss_restarts=0
while true; do
  bc=$(getprop_vm "$INIT_PID" sys.boot_completed)
  ss=$(system_server_pid "$INIT_PID")
  if [[ -n "$ss" && -n "$last_ss_pid" && "$ss" != "$last_ss_pid" ]]; then
    if host_pid_alive "$last_ss_pid"; then
      log "  two system_server pids seen ($last_ss_pid still alive, now saw $ss) -- not a restart"
    else
      ss_restarts=$((ss_restarts+1))
    fi
  fi
  [[ -n "$ss" ]] && last_ss_pid="$ss"
  elapsed=$(( $(date +%s) - start ))
  log "t=${elapsed}s boot_completed='${bc}' system_server_pid=${ss:-<none>} restarts_seen=$ss_restarts"
  if [[ "$bc" == "1" ]]; then
    if [[ "${RHIZO_PERMISSIVE:-}" != "1" ]]; then
      enforce_base_deadline=$(( $(date +%s) + 60 ))
      enforce_ceiling=$(( $(date +%s) + 150 ))
      enforce_now=""
      enforce_start=$(date +%s)
      primer_checked=0
      while (( $(date +%s) < enforce_ceiling )); do
        enforce_now=$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce 2>/dev/null' 2>/dev/null | tr -d '[:space:]')
        [[ "$enforce_now" == "1" ]] && break
        if (( ! primer_checked )) && (( $(date +%s) >= enforce_base_deadline )); then
          primer_checked=1
          if ssh_vm -t 10 'pgrep -f rhizo-host-primer' >/dev/null 2>&1; then
            log "enforce still '${enforce_now:-<unreadable>}' at 60s but rhizo-host-primer is still running"
          else
            log "FAIL: sys.boot_completed=1, /sys/fs/selinux/enforce is still '${enforce_now:-<unreadable>}', and rhizo-host-primer has already exited"
            collect_evidence "enforce-never-flipped"
            exit 1
          fi
        fi
        sleep 2
      done
      if [[ "$enforce_now" != "1" ]]; then
        log "FAIL: sys.boot_completed=1 but /sys/fs/selinux/enforce is still '${enforce_now:-<unreadable>}' $(( $(date +%s) - enforce_start ))s later"
        collect_evidence "enforce-never-flipped"
        exit 1
      fi
      log "enforce=1 confirmed (the host primer completed its flip, $(( $(date +%s) - enforce_start ))s after boot_completed)"
    fi
    log "SUCCESS: sys.boot_completed=1 (init_pid=$INIT_PID, ${ss_restarts} system_server restart(s) observed so far)"
    ssh_vm -t 15 "systemctl reset-failed rhizo-display-pool.service rhizo-display-pool.path rhizo-resync.path 2>/dev/null; systemctl restart rhizo-display-pool.path rhizo-resync.path; systemctl restart rhizo-app-events.service; systemctl start --no-block rhizo-display-pool.service rhizo-hostfs.service" >/dev/null 2>&1
    echo "$INIT_PID"
    exit 0
  fi
  if (( elapsed > BOOT_WAIT )); then
    log "FAIL: boot_completed not set within ${BOOT_WAIT}s"
    collect_evidence "boot-completed-timeout"
    exit 1
  fi
  sleep 8
done
