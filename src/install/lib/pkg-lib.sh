#!/bin/sh

PROG=rhizo
TEARDOWN=/usr/lib/rhizo/install/teardown/teardown.sh
MARK=/run/rhizo-was-running
PKG_DEBIAN_VERSION=/etc/debian_version
PKG_LSM=/sys/kernel/security/lsm
PKG_SELINUXFS=/sys/fs/selinux
PKG_SELINUX_MODE_FILE=/run/rhizo-selinux-mode
PKG_VAR_RUN=/var/run
PKG_UNITS_ENABLE=/usr/lib/rhizo/install/units.enable
PKG_UNITS_START=/usr/lib/rhizo/install/units.start
PKG_UNITS_APPLIED=/var/lib/rhizo/.units.enable.applied
PKG_STATE_DIR=/var/lib/rhizo
PKG_CONFIGURE_PENDING_NAME=.configure-pending
PKG_STATE_SUBVOLUME_RECORD=/etc/rhizo/state-subvolume
RHIZO_INSTALL_RECORD="${RHIZO_INSTALL_RECORD:-/var/lib/rhizo/.created-by-install}"
RHIZO_INSTALL_FAILED="${RHIZO_INSTALL_FAILED:-/etc/rhizo/install-failed}"
PKG_SELINUX_MODE_HELPER="${RHIZO_SELINUX_MODE_HELPER:-/usr/lib/rhizo/rhizo-selinux-mode}"
PKG_ANDROIDD_ENV="${RHIZO_ANDROIDD_ENV:-/etc/rhizo/androidd.env}"
PKG_HOST_MODE_DIR=/usr/lib/rhizo/host-mode
PKG_HOST_MODE_FILES="usr/lib/systemd/system/service.d/50-rhizo-private-users.conf
usr/lib/systemd/system/avahi-daemon.service.d/50-rhizo-policy.conf
usr/lib/systemd/system/accounts-daemon.service.d/rhizo-skel.conf
usr/lib/systemd/system/user@.service.d/rhizo-user-prep.conf
usr/lib/systemd/system/session-.scope.d/rhizo-session-vt.conf
etc/profile.d/rhizo-console-vt.sh
usr/share/fish/vendor_conf.d/rhizo-console-acl.fish
etc/apt/apt.conf.d/50rhizo"
PKG_HOST_MODE_RENAMED="usr/share/fish/vendor_conf.d/rhizo-console-vt.fish
usr/lib/systemd/system/avahi-daemon.service.d/rhizo-after-policy.conf"

# set PKG_MODE to the configured SELinux mode
pkg_read_selinux_mode() {
  if ! PKG_MODE=$("$PKG_SELINUX_MODE_HELPER" --env-file "$PKG_ANDROIDD_ENV" --configured); then
    echo "[$PROG] cannot read the configured SELinux mode from $PKG_SELINUX_MODE_HELPER" >&2
    return 1
  fi
  case "$PKG_MODE" in
    host|namespace) ;;
    *) echo "[$PROG] $PKG_SELINUX_MODE_HELPER --configured printed '$PKG_MODE', which is neither host nor namespace" >&2
       return 1 ;;
  esac
}

# set PKG_BOOT_MODE to this boot's SELinux mode
pkg_boot_selinux_mode() {
  PKG_BOOT_MODE=""
  if [ -e "$PKG_SELINUX_MODE_FILE" ]; then
    if ! PKG_BOOT_MODE=$(cat "$PKG_SELINUX_MODE_FILE" 2>/dev/null); then
      echo "[$PROG] cannot read this boot's SELinux mode record $PKG_SELINUX_MODE_FILE" >&2
      return 1
    fi
  fi
  [ -n "$PKG_BOOT_MODE" ] || PKG_BOOT_MODE="$PKG_MODE"
  case "$PKG_BOOT_MODE" in
    host|namespace) ;;
    *) echo "[$PROG] this boot's SELinux mode record $PKG_SELINUX_MODE_FILE reads '$PKG_BOOT_MODE', not host or namespace" >&2
       return 1 ;;
  esac
}

# remove host-mode links at their old names
pkg_host_mode_drop_renamed() {
  for pkg_hm_old in $PKG_HOST_MODE_RENAMED; do
    pkg_hm_dst="${RHIZO_PKG_ROOT:-}/$pkg_hm_old"
    [ -L "$pkg_hm_dst" ] && [ "$(readlink "$pkg_hm_dst")" = "$PKG_HOST_MODE_DIR/$pkg_hm_old" ] || continue
    if ! rm -f "$pkg_hm_dst"; then
      echo "[$PROG] could not remove /$pkg_hm_old, the link of a renamed host-mode file" >&2
      return 1
    fi
  done
}

# link the payload's host-mode files into place
pkg_host_mode_links() {
  if ! grep -qx host-mode-links "$RHIZO_INSTALL_RECORD" 2>/dev/null \
     && ! echo host-mode-links >> "$RHIZO_INSTALL_RECORD"; then
    echo "[$PROG] could not record host-mode-links in $RHIZO_INSTALL_RECORD" >&2
    return 1
  fi
  pkg_host_mode_drop_renamed || return 1
  for pkg_hm_file in $PKG_HOST_MODE_FILES; do
    pkg_hm_src="${RHIZO_PKG_ROOT:-}$PKG_HOST_MODE_DIR/$pkg_hm_file"
    case $pkg_hm_file in
      etc/apt/*) [ -d "${RHIZO_PKG_ROOT:-}/etc/apt" ] || continue ;;
      usr/share/fish/*) [ -f "$pkg_hm_src" ] || continue ;;
    esac
    pkg_hm_dst="${RHIZO_PKG_ROOT:-}/$pkg_hm_file"
    if [ ! -f "$pkg_hm_src" ]; then
      echo "[$PROG] the payload has no $PKG_HOST_MODE_DIR/$pkg_hm_file to link to /$pkg_hm_file" >&2
      return 1
    fi
    pkg_hm_dir=$(dirname "$pkg_hm_dst")
    while [ ! -d "$pkg_hm_dir" ]; do
      if ! grep -qxF "host-mode-dir:${pkg_hm_dir#"${RHIZO_PKG_ROOT:-}"}" "$RHIZO_INSTALL_RECORD" 2>/dev/null \
         && ! echo "host-mode-dir:${pkg_hm_dir#"${RHIZO_PKG_ROOT:-}"}" >> "$RHIZO_INSTALL_RECORD"; then
        echo "[$PROG] could not record host-mode-dir:${pkg_hm_dir#"${RHIZO_PKG_ROOT:-}"} in $RHIZO_INSTALL_RECORD" >&2
        return 1
      fi
      pkg_hm_dir=$(dirname "$pkg_hm_dir")
    done
    if ! { mkdir -p "$(dirname "$pkg_hm_dst")" && ln -sfn "$PKG_HOST_MODE_DIR/$pkg_hm_file" "$pkg_hm_dst"; }; then
      echo "[$PROG] could not link /$pkg_hm_file to $PKG_HOST_MODE_DIR/$pkg_hm_file" >&2
      return 1
    fi
  done
}

# remove the host-mode files linked into place
pkg_host_mode_unlink() {
  pkg_host_mode_drop_renamed || return 1
  for pkg_hm_file in $PKG_HOST_MODE_FILES; do
    pkg_hm_dst="${RHIZO_PKG_ROOT:-}/$pkg_hm_file"
    if [ -L "$pkg_hm_dst" ]; then
      [ "$(readlink "$pkg_hm_dst")" = "$PKG_HOST_MODE_DIR/$pkg_hm_file" ] || continue
    elif [ -f "$pkg_hm_dst" ]; then
      cmp -s "$pkg_hm_dst" "${RHIZO_PKG_ROOT:-}$PKG_HOST_MODE_DIR/$pkg_hm_file" || continue
    else
      continue
    fi
    if ! rm -f "$pkg_hm_dst"; then
      echo "[$PROG] could not remove /$pkg_hm_file" >&2
      return 1
    fi
  done
  for pkg_hm_dir in $(sed -n 's/^host-mode-dir://p' "$RHIZO_INSTALL_RECORD" 2>/dev/null | sort -r); do
    if [ -d "${RHIZO_PKG_ROOT:-}$pkg_hm_dir" ] && [ -n "$(ls -A "${RHIZO_PKG_ROOT:-}$pkg_hm_dir")" ]; then
      continue
    fi
    if [ -d "${RHIZO_PKG_ROOT:-}$pkg_hm_dir" ] && ! rmdir "${RHIZO_PKG_ROOT:-}$pkg_hm_dir"; then
      echo "[$PROG] could not remove $pkg_hm_dir, which Rhizo made for its host-mode files" >&2
      return 1
    fi
    pkg_record_drop "host-mode-dir:$pkg_hm_dir" || return 1
  done
  pkg_record_drop host-mode-links
}

# apply host mode's links and its pacman or apt edits
pkg_enter_host_mode() {
  if [ -f "${RHIZO_PKG_ROOT:-}/etc/pacman.conf" ]; then
    pkg_pacman_downloaduser_off || return 1
    pkg_login_tty_on || return 1
  fi
  pkg_host_mode_links || return 1
  if command -v apt-config >/dev/null 2>&1; then
    pkg_apt_partial_root
  fi
}

# give apt's partial dirs to root
pkg_apt_partial_root() {
  eval "$(APT_CONFIG='' apt-config shell APT_LISTS Dir::State::lists/d APT_ARCHIVES Dir::Cache::archives/d)"
  if [ -z "$APT_LISTS" ] || [ -z "$APT_ARCHIVES" ]; then
    echo "[$PROG] apt-config named no lists or archives directory (lists='$APT_LISTS' archives='$APT_ARCHIVES')" >&2
    return 1
  fi
  for d in "${APT_LISTS}partial" "${APT_LISTS}auxfiles" "${APT_ARCHIVES}partial"; do
    [ -d "$d" ] || continue
    if ! { chown root:root "$d" && chown -R root:root "$d"; }; then
      echo "[$PROG] could not hand $d to root; apt cannot download under Rhizo's policy until it is" >&2
      return 1
    fi
  done
}

# undo host mode's pacman.conf, login.defs and links
pkg_leave_host_mode() {
  pkg_leave_rc=0
  if pkg_pacman_downloaduser_restore; then pkg_record_drop pacman-downloaduser || pkg_leave_rc=1; else pkg_leave_rc=1; fi
  if pkg_login_tty_restore; then pkg_record_drop login-defs-tty || pkg_leave_rc=1; else pkg_leave_rc=1; fi
  pkg_host_mode_unlink || pkg_leave_rc=1
  return "$pkg_leave_rc"
}

# make the state directory a btrfs subvolume
pkg_state_dirs_btrfs() {
  pkg_state_subvolume || return 1
  pkg_state_subvolume_record
}

# create the state subvolume and move it
pkg_state_subvolume() {
  state=$PKG_STATE_DIR
  parent=$(dirname "$state")
  new="$parent/.$(basename "$state").new"
  [ "$(stat -f -c %T "$parent")" = btrfs ] || return 0
  if [ -d "$state" ] && [ "$(stat -c %d "$state")" != "$(stat -c %d "$parent")" ]; then return 0; fi
  if [ -d "$state" ] && [ -n "$(ls -A "$state")" ]; then
    echo "[$PROG] $state already holds files -- left a plain directory"
    return 0
  fi
  if ! command -v btrfs >/dev/null 2>&1 || ! command -v chattr >/dev/null 2>&1; then
    echo "[$PROG] no btrfs or chattr command -- $state left a plain directory; install btrfs-progs and" \
         "e2fsprogs before rhizo to make it a subvolume"
    return 0
  fi
  if ! btrfs subvolume create "$new"; then
    echo "[$PROG] could not make $new a btrfs subvolume to put in place of $state" >&2
    return 1
  fi
  if ! chattr +C "$new"; then
    echo "[$PROG] could not set NOCOW on the new subvolume $new: chattr +C failed" >&2
    pkg_state_subvolume_drop "$new"
    return 1
  fi
  if ! mv -T "$new" "$state"; then
    echo "[$PROG] could not move the new subvolume $new over $state" >&2
    pkg_state_subvolume_drop "$new"
    return 1
  fi
}

# delete the given btrfs subvolume
pkg_state_subvolume_drop() {
  btrfs subvolume delete "$1" || echo "[$PROG] could not delete $1, which stays beside $PKG_STATE_DIR" >&2
}

# update the btrfs subvolume record file
pkg_state_subvolume_record() {
  if [ -d "$PKG_STATE_DIR" ] && [ "$(stat -f -c %T "$PKG_STATE_DIR")" = btrfs ] \
     && [ "$(stat -c %i "$PKG_STATE_DIR")" = 256 ]; then
    if ! { mkdir -p "$(dirname "$PKG_STATE_SUBVOLUME_RECORD")" \
           && echo "$PKG_STATE_DIR" > "$PKG_STATE_SUBVOLUME_RECORD"; }; then
      echo "[$PROG] could not record $PKG_STATE_DIR as a btrfs subvolume in $PKG_STATE_SUBVOLUME_RECORD" >&2
      return 1
    fi
  elif ! rm -f "$PKG_STATE_SUBVOLUME_RECORD"; then
    echo "[$PROG] could not remove $PKG_STATE_SUBVOLUME_RECORD, which no longer matches $PKG_STATE_DIR" >&2
    return 1
  fi
}

# create rhizo's directories and drop outdated files
pkg_state_dirs() {
  mkdir -p /etc/rhizo /var/lib/rhizo /var/cache/rhizo /var/log/rhizo /srv/rhizo
  systemd-tmpfiles --create rhizo-run-root.conf

  rm -f /var/lib/rhizo/.prepared
  rm -f /var/lib/rhizo/androidd-runtime.env.migrated

  rm -f /var/lib/rhizo/rhizo-host-teardown.sh /var/lib/rhizo/rhizo-teardown-lib.sh

  for old in /var/lib/rhizo/farm-state /var/lib/rhizo/farm-state-*; do
    [ -d "$old" ] || continue
    new="/var/lib/rhizo/device-state${old#/var/lib/rhizo/farm-state}"
    if [ ! -e "$new" ]; then
      mv "$old" "$new" || echo "[$PROG] could not move $old to $new" >&2
    elif cp -R --update=none "$old"/. "$new"/; then
      rm -r "$old" || echo "[$PROG] could not remove $old after merging it into $new" >&2
    else
      echo "[$PROG] could not merge $old into $new" >&2
    fi
  done

  if [ ! -e /etc/rhizo/hostfs.conf ]; then
    echo "[$PROG] no /etc/rhizo/hostfs.conf yet -- rhizo-hostfs.service stays inactive until you create one"
    echo "[$PROG] share your Downloads/Documents/Pictures/Music/Videos automatically:"
    echo "[$PROG]   /usr/bin/python3 /usr/lib/rhizo/tools/hostfs.py default-config --as-user <you> --out /etc/rhizo/hostfs.conf"
  fi
}

# create a system account and its group
pkg_sys_account() {
  if command -v adduser >/dev/null 2>&1 && [ -f "$PKG_DEBIAN_VERSION" ]; then
    adduser --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin --group "$1"
  elif getent group "$1" >/dev/null 2>&1; then
    useradd --system --gid "$1" --no-create-home --home-dir /nonexistent --shell /usr/bin/nologin "$1"
  else
    useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/bin/nologin "$1"
  fi
}

# create the netbridged and uhid system accounts
pkg_accounts() {
  if ! getent passwd rhizo-netbridged >/dev/null 2>&1; then
    nb_had_group=0
    getent group rhizo-netbridged >/dev/null 2>&1 && nb_had_group=1
    pkg_sys_account rhizo-netbridged \
      || { echo "[$PROG] could not create the rhizo-netbridged system account" >&2; exit 1; }
    { echo user:rhizo-netbridged
      [ "$nb_had_group" = 1 ] || echo group:rhizo-netbridged
    } >> /var/lib/rhizo/.created-by-install \
      || { echo "[$PROG] could not record the rhizo-netbridged account in /var/lib/rhizo/.created-by-install" >&2; exit 1; }
    echo "[$PROG] created system account 'rhizo-netbridged' for the host network daemon"
  fi

  if ! getent passwd rhizo-uhid >/dev/null 2>&1; then
    uh_had_group=0
    getent group rhizo-uhid >/dev/null 2>&1 && uh_had_group=1
    pkg_sys_account rhizo-uhid \
      || { echo "[$PROG] could not create the rhizo-uhid system account" >&2; exit 1; }
    { echo user:rhizo-uhid
      [ "$uh_had_group" = 1 ] || echo group:rhizo-uhid
    } >> /var/lib/rhizo/.created-by-install \
      || { echo "[$PROG] could not record the rhizo-uhid account in /var/lib/rhizo/.created-by-install" >&2; exit 1; }
    udevadm trigger --subsystem-match=misc --sysname-match=cuse --sysname-match=uhid || true
    echo "[$PROG] created system account 'rhizo-uhid' for the uhid broker"
  fi
}

# run rhizo install and grant the desktop user
pkg_install_and_grants() {
  # pyc invalidation compares source mtime and size
  find /usr/lib/rhizo -depth -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
  /usr/bin/rhizo install || {
    echo "[$PROG] 'rhizo install' failed; rhizo will not start until it succeeds" >&2
    exit 1
  }
  pkg_read_selinux_mode \
    || exit 1

  chown root:rhizo /var/log/rhizo
  chmod 0775 /var/log/rhizo

  systemctl enable rhizo-stream-capability.path
  systemctl start rhizo-stream-capability.path

  owner="$(cat /etc/rhizo/desktop-user 2>/dev/null || true)"
  if [ -z "$owner" ]; then
    echo "[$PROG] 'rhizo install' left no /etc/rhizo/desktop-user to run the app watcher as" >&2
    exit 1
  fi
  mkdir -p /etc/systemd/system/rhizo-app-events.service.d
  printf '[Service]\nUser=%s\nGroup=%s\n' "$owner" "$owner" \
    > /etc/systemd/system/rhizo-app-events.service.d/10-desktop-user.conf

  # shellcheck disable=SC2043
  for unit in rhizo-deskd.service; do
    mkdir -p "/etc/systemd/system/$unit.d"
    printf '[Service]\nUser=%s\n' "$owner" > "/etc/systemd/system/$unit.d/10-desktop-user.conf"
  done
  for unit in rhizo-audiod.service rhizo-camerad.service rhizo-locationd.service; do
    mkdir -p "/etc/systemd/system/$unit.d"
    printf '[Service]\nUser=%s\nGroup=rhizo\n' "$owner" > "/etc/systemd/system/$unit.d/10-desktop-user.conf"
  done

  if ! id -nG "$owner" | tr ' ' '\n' | grep -qx rhizo; then
    usermod -aG rhizo "$owner"
    echo "[$PROG] granted '$owner' the rhizo group"
  fi
}

# move the state of renamed units to their new names
pkg_rename_units() {
  pkg_ru_dir="${RHIZO_PKG_ROOT:-}/etc/systemd/system"
  for pkg_ru_pair in rhizo-appwatch.service:rhizo-app-events.service \
                     rhizo-prune.path:rhizo-remove-entries.path rhizo-prune.service:rhizo-remove-entries.service; do
    pkg_ru_old=${pkg_ru_pair%%:*}
    pkg_ru_new=${pkg_ru_pair#*:}
    systemctl stop "$pkg_ru_old" 2>/dev/null || true
    if command -v deb-systemd-helper >/dev/null 2>&1; then
      deb-systemd-helper purge "$pkg_ru_old" >/dev/null 2>&1 || true
    fi
    for pkg_ru_link in "$pkg_ru_dir"/*.wants/"$pkg_ru_old"; do
      [ -L "$pkg_ru_link" ] && rm -f "$pkg_ru_link"
    done
    if [ "$(readlink "$pkg_ru_dir/$pkg_ru_old" 2>/dev/null)" = /dev/null ]; then
      rm -f "$pkg_ru_dir/$pkg_ru_old"
      ln -sf /dev/null "$pkg_ru_dir/$pkg_ru_new"
    fi
  done
  if [ -d "$pkg_ru_dir/rhizo-appwatch.service.d" ]; then
    rm -f "$pkg_ru_dir/rhizo-appwatch.service.d/10-desktop-user.conf"
    rmdir "$pkg_ru_dir/rhizo-appwatch.service.d" 2>/dev/null || true
  fi
}

# enable the core systemd units
pkg_enable_core_units() {
  for unit in rhizo-brokerd.socket rhizo-resync.path rhizo-app-events.service \
              rhizo-display-pool.path rhizo-desktop-attach.path rhizo-session-start.path; do
    case "$(systemctl is-enabled "$unit" 2>/dev/null)" in
      masked|masked-runtime)
        echo "[$PROG] $unit is masked by the server profile -- left masked, not enabled"
        continue
        ;;
    esac
    systemctl enable "$unit"
    if [ "$unit" = rhizo-desktop-attach.path ]; then
      systemctl start "$unit"
    fi
  done
}

# enable the desktop session user unit
pkg_user_units_and_desktop() {
  systemctl daemon-reload

  systemd-tmpfiles --create rhizo-desktop-session.conf

  case "$(systemctl --global is-enabled rhizo-desktop-session.path 2>/dev/null)" in
    masked|masked-runtime)
      echo "[$PROG] rhizo-desktop-session.path is masked by the server profile -- left masked, not enabled"
      ;;
    *)
      systemctl --global enable rhizo-desktop-session.path rhizo-desk-notify.path
      if [ "$(systemctl is-active user@1000.service 2>/dev/null)" = active ]; then
        if ! { runuser -u "$owner" -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload \
               && runuser -u "$owner" -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start rhizo-desktop-session.path rhizo-desk-notify.path; }; then
          echo "[$PROG] could not start rhizo-desktop-session.path and rhizo-desk-notify.path in $owner's running manager -- session.env and the notification relay appear at $owner's next login" >&2
        fi
      fi
      ;;
  esac

  /usr/bin/python3 /usr/lib/rhizo/tools/appsync.py --mimeapps-only
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications
  fi

  if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload
  fi
}

# stop the processes of the replaced version
pkg_stop_old_payload() {
  if [ -n "${1:-}" ] && [ -s "$TEARDOWN" ]; then
    bash "$TEARDOWN" --stop-payload-processes \
      || echo "[$PROG] a process an older version started may still run; the next boot's cleanup reaps it" >&2
  fi
}

# print the reboot notice for the selinux switch
pkg_selinux_switch_notice() {
  case ",$(cat "$PKG_LSM" 2>/dev/null)," in
    *,apparmor,*)
      echo "[$PROG] REBOOT REQUIRED. selinux replaces apparmor as this machine's"
      echo "[$PROG] security module, which only a reboot can do. setup finishes"
      ;;
    *)
      echo "[$PROG] REBOOT REQUIRED. selinux becomes this machine's security"
      echo "[$PROG] module, which only a reboot can do. setup finishes"
      ;;
  esac
  echo "[$PROG] automatically on the way back up; then run: rhizo status"
}

# print the reboot required message
pkg_reboot_notice() {
  case "${PKG_MODE:-}" in
    host|namespace) ;;
    *) echo "[$PROG] the reboot notice needs the configured SELinux mode, which pkg_read_selinux_mode sets" >&2
       return 1 ;;
  esac
  pkg_boot_selinux_mode \
    || return 1
  if [ "$PKG_MODE" = namespace ]; then
    rm -f "$MARK"
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    if [ -n "${1:-}" ]; then
      echo "[$PROG] reboot to finish the upgrade"
    else
      echo "[$PROG] reboot to finish the install"
    fi
    echo "[$PROG] reboot into the Rhizo kernel, the default boot entry now:"
    echo "[$PROG] Android runs there in its own SELinux namespace, and the"
    echo "[$PROG] one-time setup runs early on that boot. 'rhizo status' shows"
    echo "[$PROG] setup: pending-reboot until then."
  elif [ -e "$MARK" ]; then
    rm -f "$MARK"
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    echo "[$PROG] reboot to finish the upgrade"
    echo "[$PROG] the sandbox was stopped to replace its files and cannot"
    echo "[$PROG] restart until this machine reboots. Your apps and data are"
    echo "[$PROG] untouched; reboot when convenient."
  elif [ "$PKG_BOOT_MODE" != namespace ] && [ -d "$PKG_SELINUXFS" ] \
       && [ "$(cat "$PKG_SELINUXFS/enforce" 2>/dev/null)" != 0 ]; then
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    echo "[$PROG] reboot to finish the upgrade"
    echo "[$PROG] the sandbox already ran on this boot, so the new version's"
    echo "[$PROG] one-time setup runs early on the next boot, before Android's"
    echo "[$PROG] policy loads. Your apps and data are untouched; reboot when"
    echo "[$PROG] convenient. 'rhizo status' shows setup: pending-reboot until then."
  elif [ -d "$PKG_SELINUXFS" ]; then
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    if [ -n "${1:-}" ]; then
      echo "[$PROG] reboot to finish the upgrade"
    else
      echo "[$PROG] reboot to finish the install"
    fi
    echo "[$PROG] Android's security policy loads only at boot, before anyone"
    echo "[$PROG] logs in, and this boot's logins started without it. The"
    echo "[$PROG] one-time setup runs early on the next boot; reboot when"
    echo "[$PROG] convenient. 'rhizo status' shows setup: pending-reboot until then."
  fi

  if [ "$PKG_MODE" = host ] && [ ! -d "$PKG_SELINUXFS" ]; then
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    pkg_selinux_switch_notice
  fi
}

# list the androidd instance units
pkg_live_androidd_instances() {
  { systemctl list-units --all --no-legend --plain 'androidd@*.service' 2>/dev/null
    systemctl list-unit-files --no-legend --plain 'androidd@*.service' 2>/dev/null
  } | awk '{print $1}' | grep -vxF 'androidd@.service'
}

# stop the rhizo units
pkg_pre_replace() {
  case "$1" in
    upgrade)
      instances=$(pkg_live_androidd_instances | sort -u)
      if [ "$(systemctl is-active androidd.service 2>/dev/null)" = active ] || [ -n "$instances" ]; then
        touch "$MARK"
        systemctl stop androidd.service 2>/dev/null || true
        for u in $instances; do
          systemctl stop "$u" 2>/dev/null || true
        done
        echo "[rhizo] stopped the sandbox for the upgrade; it starts again afterwards"
      fi
      if [ -s "$TEARDOWN" ]; then
        bash "$TEARDOWN" --stop-payload-processes \
          || echo "[rhizo] a process this version started may still run; the next boot's cleanup reaps it" >&2
      fi
      ;;
    remove)
      rm -f "$MARK"
      systemctl stop androidd.service 2>/dev/null || true
      for u in $(pkg_live_androidd_instances | sort -u); do
        systemctl stop "$u" 2>/dev/null || true
        systemctl disable "$u" 2>/dev/null || true
      done
      systemctl stop rhizo-hostfs.service rhizo-app-events.service \
                     rhizo-brokerd.socket rhizo-resync.path \
                     rhizo-server-idle.service 2>/dev/null || true
      systemctl stop rhizo-update-confirm.service rhizo-update-begin.service \
                     rhizo-prepare.service rhizo-policy.service 2>/dev/null || true
      systemctl disable rhizo-brokerd.socket rhizo-resync.path rhizo-app-events.service 2>/dev/null || true
      owner="$(cat /etc/rhizo/desktop-user 2>/dev/null || true)"
      if [ -n "$owner" ] && [ "$(systemctl is-active user@1000.service 2>/dev/null)" = active ]; then
        runuser -u "$owner" -- env XDG_RUNTIME_DIR=/run/user/1000 \
          systemctl --user stop rhizo-desktop-session.path rhizo-desktop-session.service \
                                rhizo-desk-notify.path rhizo-desk-notify.service 2>/dev/null || true
      fi
      systemctl --global disable rhizo-desktop-session.path rhizo-desk-notify.path 2>/dev/null || true
      rmdir /etc/systemd/user/default.target.wants 2>/dev/null || true
      ;;
  esac
}

# set profile to the active profile's name
pkg_read_profile() {
  profile=$(/usr/bin/rhizo profile show) || return 1
  profile=${profile#RHIZO_PROFILE profile=}
  case "$profile" in
    desktop|server) ;;
    *) return 1 ;;
  esac
}

# enable the units listed in PKG_UNITS_ENABLE
pkg_enable_listed_units() {
  if [ -n "$1" ] && [ ! -r "$2" ]; then
    echo "[$PROG] cannot read $2, the replaced version's unit list -- no unit enabled" >&2
    return 1
  fi
  failed=
  pkg_read_profile || profile=active
  while read -r enable_unit; do
    if [ -n "$1" ] && grep -qxF "$enable_unit" "$2"; then continue; fi
    case "$(systemctl is-enabled "$enable_unit" 2>/dev/null)" in
      masked|masked-runtime)
        echo "[$PROG] $enable_unit is masked by the $profile profile -- left masked, not enabled"
        continue
        ;;
    esac
    systemctl enable "$enable_unit" || failed="$failed $enable_unit"
  done < "$PKG_UNITS_ENABLE"
  if [ -n "$failed" ]; then
    echo "[$PROG] could not enable:$failed" >&2
    return 1
  fi
  cp "$PKG_UNITS_ENABLE" "$PKG_UNITS_APPLIED"
}

# start the units listed in PKG_UNITS_START
pkg_start_listed_units() {
  action=start
  [ -z "$1" ] || action=restart
  failed=
  while read -r start_unit; do
    case "$(systemctl is-enabled "$start_unit" 2>/dev/null)" in
      enabled|enabled-runtime) ;;
      *) if [ -z "$1" ] || ! systemctl --quiet is-active "$start_unit"; then continue; fi ;;
    esac
    if [ -z "$1" ]; then
      systemctl --quiet start "$start_unit" || failed="$failed $start_unit"
    else
      systemctl --quiet restart "$start_unit" || failed="$failed $start_unit"
    fi
  done < "$PKG_UNITS_START"
  if [ -n "$failed" ]; then
    echo "[$PROG] could not $action:$failed" >&2
    return 1
  fi
}

# stop the units listed in PKG_UNITS_START
pkg_stop_listed_units() {
  stop_units=$(cat "$PKG_UNITS_START") || return 1
  # shellcheck disable=SC2086
  systemctl stop $stop_units
}

# apply the rhizo profile to the units
pkg_unit_policy() {
  pkg_read_profile \
    || { echo "[$PROG] 'rhizo profile show' names no profile ($profile) to apply again" >&2; return 1; }
  /usr/bin/rhizo profile "$profile"
  /usr/lib/rhizo/streamd/capability-sync.sh \
    || echo "[$PROG] could not sync rhizo-streamd.socket to stream.enabled; it stays as the package manager" \
            "left it until 'systemctl start rhizo-stream-capability.service' succeeds" >&2
}

# comment out DownloadUser in pacman.conf
pkg_pacman_downloaduser_off() {
  conf="${RHIZO_PKG_ROOT:-}/etc/pacman.conf"
  grep -Eq '^#?[[:space:]]*DownloadUser[[:space:]]*=.*# rhizo$|^[[:space:]]*DownloadUser[[:space:]]*=' "$conf" || return 0
  pkg_record_token pacman-downloaduser || return 1
  grep -Eq '^[[:space:]]*DownloadUser[[:space:]]*=' "$conf" || return 0
  sed -i -E 's/^([[:space:]]*DownloadUser[[:space:]]*=.*)$/#\1  # rhizo/' "$conf"
}

# add a token to the install record
pkg_record_token() {
  grep -qx "$1" "$RHIZO_INSTALL_RECORD" 2>/dev/null || echo "$1" >> "$RHIZO_INSTALL_RECORD"
}

# remove a token from the install record
pkg_record_drop() {
  [ -f "$RHIZO_INSTALL_RECORD" ] || return 0
  grep -qxF -- "$1" "$RHIZO_INSTALL_RECORD" || return 0
  grep -vxF -- "$1" "$RHIZO_INSTALL_RECORD" > "$RHIZO_INSTALL_RECORD.new"
  if [ "$?" -gt 1 ] || ! mv "$RHIZO_INSTALL_RECORD.new" "$RHIZO_INSTALL_RECORD"; then
    rm -f "$RHIZO_INSTALL_RECORD.new"
    echo "[$PROG] could not drop $1 from $RHIZO_INSTALL_RECORD" >&2
    return 1
  fi
}

# uncomment DownloadUser in pacman.conf
pkg_pacman_downloaduser_restore() {
  conf="${RHIZO_PKG_ROOT:-}/etc/pacman.conf"
  grep -qx pacman-downloaduser "$RHIZO_INSTALL_RECORD" 2>/dev/null || return 0
  sed -i -E 's/^#([[:space:]]*DownloadUser[[:space:]]*=.*[^[:space:]])[[:space:]]*# rhizo$/\1/' "$conf" || return 1
  grep -Eq '^[[:space:]]*DownloadUser[[:space:]]*=' "$conf" && return 0
  echo "[$PROG] DownloadUser in $conf is not active and carries no '# rhizo' mark to undo, so it stays as it is" >&2
  return 1
}

PKG_TTY_GROUP_NONE=rhizo-no-tty-group
PKG_LOGIN_BEGIN="# >>> rhizo: login reopens the tty it gave the account, which root may only do through the account's own group"
PKG_LOGIN_END="# <<< rhizo"

# give login ttys to the account's group in login.defs
pkg_login_tty_on() {
  conf="${RHIZO_PKG_ROOT:-}/etc/login.defs"
  [ -f "$conf" ] || return 0
  if grep -qxF "$PKG_LOGIN_BEGIN" "$conf"; then
    pkg_record_token login-defs-tty
    return
  fi
  if getent group "$PKG_TTY_GROUP_NONE" >/dev/null; then
    echo "[$PROG] a group named $PKG_TTY_GROUP_NONE exists: remove or rename that group, then install again" >&2
    return 1
  fi
  pkg_record_token login-defs-tty || return 1
  sed -i -E 's/^([[:space:]]*TTY(GROUP|PERM)[[:space:]].*[^[:space:]])[[:space:]]*$/#\1  # rhizo/' "$conf" || return 1
  printf '%s\nTTYGROUP\t%s\nTTYPERM\t0660\n%s\n' "$PKG_LOGIN_BEGIN" "$PKG_TTY_GROUP_NONE" "$PKG_LOGIN_END" >> "$conf"
}

# put login.defs' TTYGROUP and TTYPERM back
pkg_login_tty_restore() {
  conf="${RHIZO_PKG_ROOT:-}/etc/login.defs"
  grep -qx login-defs-tty "$RHIZO_INSTALL_RECORD" 2>/dev/null || return 0
  [ -f "$conf" ] || return 0
  if grep -qxF "$PKG_LOGIN_BEGIN" "$conf" \
      && ! sed -n "\\|^$PKG_LOGIN_BEGIN\$|,\$p" "$conf" | grep -qxF "$PKG_LOGIN_END"; then
    echo "[$PROG] $conf has the '# >>> rhizo' line but no '# <<< rhizo' line after it, so nothing is removed:" \
         "delete the block by hand and uncomment the lines marked '# rhizo'" >&2
    return 1
  fi
  sed -i -e "\\|^$PKG_LOGIN_BEGIN\$|,\\|^$PKG_LOGIN_END\$|d" \
    -E -e 's/^#([[:space:]]*TTY(GROUP|PERM)[[:space:]].*[^[:space:]])[[:space:]]*# rhizo$/\1/' "$conf"
}

# save the failed step for rhizo status and exit
pkg_configure_exit_after_policy() {
  trap - EXIT
  echo "[$PROG] $1 failed (exit $2); the unit policy ran after it" >&2
  { echo "$1 $2" > "$RHIZO_INSTALL_FAILED"; } 2>/dev/null || :
  exit "$2"
}

# save or drop the failed step for rhizo status and exit
pkg_configure_exit() {
  trap - EXIT
  if [ "$1" = 0 ]; then
    rm -f "$RHIZO_INSTALL_FAILED" 2>/dev/null || :
  else
    echo "[$PROG] $pkg_step failed (exit $1); configuring stopped there" >&2
    { echo "$pkg_step $1" > "$RHIZO_INSTALL_FAILED"; } 2>/dev/null || :
  fi
  exit "$1"
}

# run the configure the pacman scriptlet left
pkg_configure_pending() {
  pkg_pending="$PKG_STATE_DIR/$PKG_CONFIGURE_PENDING_NAME"
  if [ ! -f "$pkg_pending" ]; then
    echo "[$PROG] no $pkg_pending: rhizo's install or upgrade scriptlet left no configure for this hook" >&2
    return 1
  fi
  if ! pkg_pending_from=$(cat "$pkg_pending"); then
    echo "[$PROG] cannot read $pkg_pending" >&2
    return 1
  fi
  if [ -n "$pkg_pending_from" ]; then
    pkg_configure "$pkg_pending_from" "$PKG_STATE_DIR/.units.enable.replaced"
  else
    pkg_configure "" ""
  fi
  pkg_pending_rc=$?
  if ! rm -f "$pkg_pending" "$PKG_STATE_DIR/.units.enable.replaced"; then
    echo "[$PROG] could not remove $pkg_pending" >&2
    pkg_pending_rc=1
  fi
  return "$pkg_pending_rc"
}

# run the pacman configure steps
pkg_configure() {
  (
    set -e
    pkg_step=
    trap 'pkg_configure_exit "$?"' EXIT
    pkg_step=pkg_read_selinux_mode; pkg_read_selinux_mode
    pkg_step=pkg_state_dirs_btrfs; pkg_state_dirs_btrfs
    pkg_step=pkg_state_dirs; pkg_state_dirs
    pkg_step=pkg_accounts; pkg_accounts
    pkg_step=pkg_install_and_grants; pkg_install_and_grants
    pkg_step=pkg_enable_core_units; pkg_enable_core_units
    pkg_step=pkg_user_units_and_desktop; pkg_user_units_and_desktop
    pkg_step=pkg_stop_old_payload; pkg_stop_old_payload "$1"
    pkg_step=pkg_reboot_notice; pkg_reboot_notice "$1"
    enable_rc=0 start_rc=0
    pkg_step=pkg_enable_listed_units; pkg_enable_listed_units "$1" "$2" || enable_rc=$?
    pkg_step=pkg_start_listed_units; pkg_start_listed_units "$1" || start_rc=$?
    pkg_step=pkg_unit_policy; pkg_unit_policy
    [ "$enable_rc" = 0 ] || pkg_configure_exit_after_policy pkg_enable_listed_units "$enable_rc"
    [ "$start_rc" = 0 ] || pkg_configure_exit_after_policy pkg_start_listed_units "$start_rc"
  )
}
