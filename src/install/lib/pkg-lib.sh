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
    echo "[$PROG] $PKG_SELINUX_MODE_HELPER --configured failed" >&2
    return 1
  fi
  case "$PKG_MODE" in
    host|namespace) ;;
    *) echo "[$PROG] $PKG_SELINUX_MODE_HELPER --configured printed '$PKG_MODE', expected host or namespace" >&2
       return 1 ;;
  esac
}

# set PKG_BOOT_MODE to the SELinux mode in PKG_SELINUX_MODE_FILE
pkg_boot_selinux_mode() {
  PKG_BOOT_MODE=""
  if [ -e "$PKG_SELINUX_MODE_FILE" ]; then
    if ! PKG_BOOT_MODE=$(cat "$PKG_SELINUX_MODE_FILE" 2>/dev/null); then
      echo "[$PROG] failed to read $PKG_SELINUX_MODE_FILE" >&2
      return 1
    fi
  fi
  [ -n "$PKG_BOOT_MODE" ] || PKG_BOOT_MODE="$PKG_MODE"
  case "$PKG_BOOT_MODE" in
    host|namespace) ;;
    *) echo "[$PROG] $PKG_SELINUX_MODE_FILE contains '$PKG_BOOT_MODE', expected host or namespace" >&2
       return 1 ;;
  esac
}

# remove the PKG_HOST_MODE_RENAMED links
pkg_host_mode_drop_renamed() {
  for pkg_hm_old in $PKG_HOST_MODE_RENAMED; do
    pkg_hm_dst="${RHIZO_PKG_ROOT:-}/$pkg_hm_old"
    [ -L "$pkg_hm_dst" ] && [ "$(readlink "$pkg_hm_dst")" = "$PKG_HOST_MODE_DIR/$pkg_hm_old" ] || continue
    if ! rm -f "$pkg_hm_dst"; then
      echo "[$PROG] failed to remove /$pkg_hm_old" >&2
      return 1
    fi
  done
}

# link the payload's host-mode files into place
pkg_host_mode_links() {
  if ! grep -qx host-mode-links "$RHIZO_INSTALL_RECORD" 2>/dev/null \
     && ! echo host-mode-links >> "$RHIZO_INSTALL_RECORD"; then
    echo "[$PROG] failed to write host-mode-links to $RHIZO_INSTALL_RECORD" >&2
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
      echo "[$PROG] no $PKG_HOST_MODE_DIR/$pkg_hm_file" >&2
      return 1
    fi
    pkg_hm_dir=$(dirname "$pkg_hm_dst")
    while [ ! -d "$pkg_hm_dir" ]; do
      if ! grep -qxF "host-mode-dir:${pkg_hm_dir#"${RHIZO_PKG_ROOT:-}"}" "$RHIZO_INSTALL_RECORD" 2>/dev/null \
         && ! echo "host-mode-dir:${pkg_hm_dir#"${RHIZO_PKG_ROOT:-}"}" >> "$RHIZO_INSTALL_RECORD"; then
        echo "[$PROG] failed to write host-mode-dir:${pkg_hm_dir#"${RHIZO_PKG_ROOT:-}"} to $RHIZO_INSTALL_RECORD" >&2
        return 1
      fi
      pkg_hm_dir=$(dirname "$pkg_hm_dir")
    done
    if ! { mkdir -p "$(dirname "$pkg_hm_dst")" && ln -sfn "$PKG_HOST_MODE_DIR/$pkg_hm_file" "$pkg_hm_dst"; }; then
      echo "[$PROG] failed to link /$pkg_hm_file to $PKG_HOST_MODE_DIR/$pkg_hm_file" >&2
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
      echo "[$PROG] failed to remove /$pkg_hm_file" >&2
      return 1
    fi
  done
  for pkg_hm_dir in $(sed -n 's/^host-mode-dir://p' "$RHIZO_INSTALL_RECORD" 2>/dev/null | sort -r); do
    if [ -d "${RHIZO_PKG_ROOT:-}$pkg_hm_dir" ] && [ -n "$(ls -A "${RHIZO_PKG_ROOT:-}$pkg_hm_dir")" ]; then
      continue
    fi
    if [ -d "${RHIZO_PKG_ROOT:-}$pkg_hm_dir" ] && ! rmdir "${RHIZO_PKG_ROOT:-}$pkg_hm_dir"; then
      echo "[$PROG] failed to remove $pkg_hm_dir" >&2
      return 1
    fi
    pkg_record_drop "host-mode-dir:$pkg_hm_dir" || return 1
  done
  pkg_record_drop host-mode-links
}

# apply the host-mode links and the pacman or apt edits
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

# chown apt's partial dirs to root
pkg_apt_partial_root() {
  eval "$(APT_CONFIG='' apt-config shell APT_LISTS Dir::State::lists/d APT_ARCHIVES Dir::Cache::archives/d)"
  if [ -z "$APT_LISTS" ] || [ -z "$APT_ARCHIVES" ]; then
    echo "[$PROG] apt-config printed no lists or archives directory (lists='$APT_LISTS' archives='$APT_ARCHIVES')" >&2
    return 1
  fi
  for d in "${APT_LISTS}partial" "${APT_LISTS}auxfiles" "${APT_ARCHIVES}partial"; do
    [ -d "$d" ] || continue
    if ! { chown root:root "$d" && chown -R root:root "$d"; }; then
      echo "[$PROG] failed to chown $d to root:root" >&2
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

# create the state subvolume with PKG_CONFIGURE_PENDING_NAME and move the subvolume to PKG_STATE_DIR
pkg_state_subvolume() {
  state=$PKG_STATE_DIR
  parent=$(dirname "$state")
  new="$parent/.$(basename "$state").new"
  [ "$(stat -f -c %T "$parent")" = btrfs ] || return 0
  pkg_state_subvolume_recover || return 1
  if [ -d "$state" ] && [ "$(stat -c %d "$state")" != "$(stat -c %d "$parent")" ]; then return 0; fi
  held=
  if [ -d "$state" ]; then held=$(ls -A "$state"); fi
  if [ -n "$held" ] && { [ "$held" != "$PKG_CONFIGURE_PENDING_NAME" ] || [ ! -f "$state/$held" ] || [ -L "$state/$held" ]; }; then
    echo "[$PROG] $state is a non-empty plain directory"
    return 0
  fi
  if ! command -v btrfs >/dev/null 2>&1 || ! command -v chattr >/dev/null 2>&1; then
    echo "[$PROG] no btrfs or chattr command, $state is a plain directory"
    return 0
  fi
  if ! btrfs subvolume create "$new"; then
    echo "[$PROG] btrfs subvolume create $new failed" >&2
    return 1
  fi
  if ! chattr +C "$new"; then
    echo "[$PROG] chattr +C $new failed" >&2
    pkg_state_subvolume_drop "$new"
    return 1
  fi
  if [ -n "$held" ] && ! mv "$state/$held" "$new/$held"; then
    echo "[$PROG] failed to move $state/$held to $new/$held" >&2
    pkg_state_subvolume_drop "$new"
    return 1
  fi
  if ! mv -T "$new" "$state"; then
    echo "[$PROG] failed to move $new to $state" >&2
    if [ -n "$held" ] && ! mv "$new/$held" "$state/$held"; then
      echo "[$PROG] failed to move $new/$held to $state/$held" >&2
      return 1
    fi
    pkg_state_subvolume_drop "$new"
    return 1
  fi
}

# move PKG_CONFIGURE_PENDING_NAME from the .new subvolume to PKG_STATE_DIR and delete the .new subvolume
pkg_state_subvolume_recover() {
  rec_new="$(dirname "$PKG_STATE_DIR")/.$(basename "$PKG_STATE_DIR").new"
  rec_marker="$PKG_STATE_DIR/$PKG_CONFIGURE_PENDING_NAME"
  if [ ! -d "$rec_new" ] || [ -L "$rec_new" ]; then return 0; fi
  if [ "$(stat -c %i "$rec_new")" != 256 ]; then
    echo "[$PROG] $rec_new is not a btrfs subvolume" >&2
    return 1
  fi
  if [ -f "$rec_new/$PKG_CONFIGURE_PENDING_NAME" ] && [ ! -L "$rec_new/$PKG_CONFIGURE_PENDING_NAME" ]; then
    if [ -e "$rec_marker" ] || [ -L "$rec_marker" ]; then
      rm -f "$rec_new/$PKG_CONFIGURE_PENDING_NAME"
    elif ! { mkdir -p "$PKG_STATE_DIR" && mv "$rec_new/$PKG_CONFIGURE_PENDING_NAME" "$rec_marker"; }; then
      echo "[$PROG] failed to move $rec_new/$PKG_CONFIGURE_PENDING_NAME to $rec_marker" >&2
      return 1
    else
      echo "[$PROG] moved $rec_new/$PKG_CONFIGURE_PENDING_NAME to $rec_marker"
    fi
  fi
  if [ -n "$(ls -A "$rec_new")" ]; then
    echo "[$PROG] $rec_new is not empty" >&2
    return 1
  fi
  pkg_state_subvolume_drop "$rec_new"
  [ ! -e "$rec_new" ]
}

# delete the btrfs subvolume $1
pkg_state_subvolume_drop() {
  btrfs subvolume delete "$1" || echo "[$PROG] btrfs subvolume delete $1 failed" >&2
}

# update the btrfs subvolume record file
pkg_state_subvolume_record() {
  if [ -d "$PKG_STATE_DIR" ] && [ "$(stat -f -c %T "$PKG_STATE_DIR")" = btrfs ] \
     && [ "$(stat -c %i "$PKG_STATE_DIR")" = 256 ]; then
    if ! { mkdir -p "$(dirname "$PKG_STATE_SUBVOLUME_RECORD")" \
           && echo "$PKG_STATE_DIR" > "$PKG_STATE_SUBVOLUME_RECORD"; }; then
      echo "[$PROG] failed to write $PKG_STATE_DIR to $PKG_STATE_SUBVOLUME_RECORD" >&2
      return 1
    fi
  elif ! rm -f "$PKG_STATE_SUBVOLUME_RECORD"; then
    echo "[$PROG] failed to remove $PKG_STATE_SUBVOLUME_RECORD" >&2
    return 1
  fi
}

# create the rhizo directories and remove outdated files
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
      mv "$old" "$new" || echo "[$PROG] failed to move $old to $new" >&2
    elif cp -R --update=none "$old"/. "$new"/; then
      rm -r "$old" || echo "[$PROG] failed to remove $old" >&2
    else
      echo "[$PROG] failed to copy $old to $new" >&2
    fi
  done

  if [ ! -e /etc/rhizo/hostfs.conf ]; then
    echo "[$PROG] no /etc/rhizo/hostfs.conf"
  fi
}

# create a system account and group
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
      || { echo "[$PROG] failed to create the rhizo-netbridged system account" >&2; exit 1; }
    { echo user:rhizo-netbridged
      [ "$nb_had_group" = 1 ] || echo group:rhizo-netbridged
    } >> /var/lib/rhizo/.created-by-install \
      || { echo "[$PROG] failed to write the rhizo-netbridged account to /var/lib/rhizo/.created-by-install" >&2; exit 1; }
    echo "[$PROG] created system account rhizo-netbridged"
  fi

  if ! getent passwd rhizo-uhid >/dev/null 2>&1; then
    uh_had_group=0
    getent group rhizo-uhid >/dev/null 2>&1 && uh_had_group=1
    pkg_sys_account rhizo-uhid \
      || { echo "[$PROG] failed to create the rhizo-uhid system account" >&2; exit 1; }
    { echo user:rhizo-uhid
      [ "$uh_had_group" = 1 ] || echo group:rhizo-uhid
    } >> /var/lib/rhizo/.created-by-install \
      || { echo "[$PROG] failed to write the rhizo-uhid account to /var/lib/rhizo/.created-by-install" >&2; exit 1; }
    udevadm trigger --subsystem-match=misc --sysname-match=cuse --sysname-match=uhid || true
    echo "[$PROG] created system account rhizo-uhid"
  fi
}

# run rhizo install and write the desktop-user drop-ins
pkg_install_and_grants() {
  # pyc invalidation compares source mtime and size
  find /usr/lib/rhizo -depth -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
  /usr/bin/rhizo install || {
    echo "[$PROG] rhizo install failed" >&2
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
    echo "[$PROG] no /etc/rhizo/desktop-user after rhizo install" >&2
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
    echo "[$PROG] added $owner to the rhizo group"
  fi
}

# move rhizo-appwatch and rhizo-prune unit state to rhizo-app-events and rhizo-remove-entries
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
        echo "[$PROG] $unit is masked"
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
      echo "[$PROG] rhizo-desktop-session.path is masked"
      ;;
    *)
      systemctl --global enable rhizo-desktop-session.path rhizo-desk-notify.path
      if [ "$(systemctl is-active user@1000.service 2>/dev/null)" = active ]; then
        if ! { runuser -u "$owner" -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user daemon-reload \
               && runuser -u "$owner" -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user start rhizo-desktop-session.path rhizo-desk-notify.path; }; then
          echo "[$PROG] failed to start rhizo-desktop-session.path and rhizo-desk-notify.path in the user manager of $owner" >&2
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
      || echo "[$PROG] teardown.sh --stop-payload-processes failed" >&2
  fi
}

# print the reboot notice for the selinux switch
pkg_selinux_switch_notice() {
  case ",$(cat "$PKG_LSM" 2>/dev/null)," in
    *,apparmor,*)
      echo "[$PROG] reboot required for selinux"
      echo "[$PROG] the kernel loads selinux in place of apparmor at the next boot"
      ;;
    *)
      echo "[$PROG] reboot required for selinux"
      echo "[$PROG] the kernel loads selinux at the next boot"
      ;;
  esac
  echo "[$PROG] rhizo-prepare.service runs at the next boot"
}

# print the reboot required message
pkg_reboot_notice() {
  case "${PKG_MODE:-}" in
    host|namespace) ;;
    *) echo "[$PROG] PKG_MODE is not host or namespace" >&2
       return 1 ;;
  esac
  pkg_boot_selinux_mode \
    || return 1
  if [ "$PKG_MODE" = namespace ]; then
    rm -f "$MARK"
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    if [ -n "${1:-}" ]; then
      echo "[$PROG] reboot required for the upgrade"
    else
      echo "[$PROG] reboot required for the install"
    fi
    echo "[$PROG] the default boot entry is the Rhizo kernel"
    echo "[$PROG] rhizo-prepare.service runs at the next boot"
  elif [ -e "$MARK" ]; then
    rm -f "$MARK"
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    echo "[$PROG] reboot required for the upgrade"
    echo "[$PROG] the sandbox starts at the next boot"
  elif [ "$PKG_BOOT_MODE" != namespace ] && [ -d "$PKG_SELINUXFS" ] \
       && [ "$(cat "$PKG_SELINUXFS/enforce" 2>/dev/null)" != 0 ]; then
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    echo "[$PROG] reboot required for the upgrade"
    echo "[$PROG] rhizo-prepare.service runs at the next boot, before rhizo-policy.service"
  elif [ -d "$PKG_SELINUXFS" ]; then
    mkdir -p "$PKG_VAR_RUN"
    touch "$PKG_VAR_RUN/reboot-required"
    if [ -n "${1:-}" ]; then
      echo "[$PROG] reboot required for the upgrade"
    else
      echo "[$PROG] reboot required for the install"
    fi
    echo "[$PROG] rhizo-policy.service loads Android's policy before systemd-user-sessions.service"
    echo "[$PROG] rhizo-prepare.service runs at the next boot"
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
        echo "[rhizo] stopped the sandbox"
      fi
      if [ -s "$TEARDOWN" ]; then
        bash "$TEARDOWN" --stop-payload-processes \
          || echo "[rhizo] teardown.sh --stop-payload-processes failed" >&2
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
    echo "[$PROG] failed to read $2" >&2
    return 1
  fi
  failed=
  pkg_read_profile || profile=active
  while read -r enable_unit; do
    if [ -n "$1" ] && grep -qxF "$enable_unit" "$2"; then continue; fi
    case "$(systemctl is-enabled "$enable_unit" 2>/dev/null)" in
      masked|masked-runtime)
        echo "[$PROG] $enable_unit is masked by the $profile profile"
        continue
        ;;
    esac
    systemctl enable "$enable_unit" || failed="$failed $enable_unit"
  done < "$PKG_UNITS_ENABLE"
  if [ -n "$failed" ]; then
    echo "[$PROG] systemctl enable failed for$failed" >&2
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
    echo "[$PROG] systemctl $action failed for$failed" >&2
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
    || { echo "[$PROG] rhizo profile show printed no profile ($profile)" >&2; return 1; }
  /usr/bin/rhizo profile "$profile"
  /usr/lib/rhizo/streamd/capability-sync.sh \
    || echo "[$PROG] capability-sync.sh failed" >&2
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
    echo "[$PROG] failed to remove $1 from $RHIZO_INSTALL_RECORD" >&2
    return 1
  fi
}

# uncomment DownloadUser in pacman.conf
pkg_pacman_downloaduser_restore() {
  conf="${RHIZO_PKG_ROOT:-}/etc/pacman.conf"
  grep -qx pacman-downloaduser "$RHIZO_INSTALL_RECORD" 2>/dev/null || return 0
  sed -i -E 's/^#([[:space:]]*DownloadUser[[:space:]]*=.*[^[:space:]])[[:space:]]*# rhizo$/\1/' "$conf" || return 1
  grep -Eq '^[[:space:]]*DownloadUser[[:space:]]*=' "$conf" && return 0
  echo "[$PROG] DownloadUser in $conf is commented out without a '# rhizo' mark" >&2
  return 1
}

PKG_TTY_GROUP_NONE=rhizo-no-tty-group
PKG_LOGIN_BEGIN="# >>> rhizo: login reopens the tty it gave the account, which root may only do through the account's own group"
PKG_LOGIN_END="# <<< rhizo"

# set TTYGROUP and TTYPERM in login.defs
pkg_login_tty_on() {
  conf="${RHIZO_PKG_ROOT:-}/etc/login.defs"
  [ -f "$conf" ] || return 0
  if grep -qxF "$PKG_LOGIN_BEGIN" "$conf"; then
    pkg_record_token login-defs-tty
    return
  fi
  if getent group "$PKG_TTY_GROUP_NONE" >/dev/null; then
    echo "[$PROG] group $PKG_TTY_GROUP_NONE exists" >&2
    return 1
  fi
  pkg_record_token login-defs-tty || return 1
  sed -i -E 's/^([[:space:]]*TTY(GROUP|PERM)[[:space:]].*[^[:space:]])[[:space:]]*$/#\1  # rhizo/' "$conf" || return 1
  printf '%s\nTTYGROUP\t%s\nTTYPERM\t0660\n%s\n' "$PKG_LOGIN_BEGIN" "$PKG_TTY_GROUP_NONE" "$PKG_LOGIN_END" >> "$conf"
}

# restore TTYGROUP and TTYPERM in login.defs
pkg_login_tty_restore() {
  conf="${RHIZO_PKG_ROOT:-}/etc/login.defs"
  grep -qx login-defs-tty "$RHIZO_INSTALL_RECORD" 2>/dev/null || return 0
  [ -f "$conf" ] || return 0
  if grep -qxF "$PKG_LOGIN_BEGIN" "$conf" \
      && ! sed -n "\\|^$PKG_LOGIN_BEGIN\$|,\$p" "$conf" | grep -qxF "$PKG_LOGIN_END"; then
    echo "[$PROG] $conf has a '# >>> rhizo' line without a later '# <<< rhizo' line" >&2
    return 1
  fi
  sed -i -e "\\|^$PKG_LOGIN_BEGIN\$|,\\|^$PKG_LOGIN_END\$|d" \
    -E -e 's/^#([[:space:]]*TTY(GROUP|PERM)[[:space:]].*[^[:space:]])[[:space:]]*# rhizo$/\1/' "$conf"
}

# write the failed step to RHIZO_INSTALL_FAILED and exit
pkg_configure_exit_after_policy() {
  trap - EXIT
  echo "[$PROG] $1 failed with exit status $2" >&2
  { echo "$1 $2" > "$RHIZO_INSTALL_FAILED"; } 2>/dev/null || :
  exit "$2"
}

# write or remove RHIZO_INSTALL_FAILED and exit
pkg_configure_exit() {
  trap - EXIT
  if [ "$1" = 0 ]; then
    rm -f "$RHIZO_INSTALL_FAILED" 2>/dev/null || :
  else
    echo "[$PROG] $pkg_step failed with exit status $1" >&2
    { echo "$pkg_step $1" > "$RHIZO_INSTALL_FAILED"; } 2>/dev/null || :
  fi
  exit "$1"
}

# run pkg_configure for PKG_CONFIGURE_PENDING_NAME
pkg_configure_pending() {
  pkg_pending="$PKG_STATE_DIR/$PKG_CONFIGURE_PENDING_NAME"
  pkg_state_subvolume_recover || return 1
  if [ ! -f "$pkg_pending" ]; then
    echo "[$PROG] no $pkg_pending" >&2
    return 1
  fi
  if ! pkg_pending_from=$(cat "$pkg_pending"); then
    echo "[$PROG] failed to read $pkg_pending" >&2
    return 1
  fi
  if [ -n "$pkg_pending_from" ]; then
    pkg_configure "$pkg_pending_from" "$PKG_STATE_DIR/.units.enable.replaced"
  else
    pkg_configure "" ""
  fi
  pkg_pending_rc=$?
  if ! rm -f "$pkg_pending" "$PKG_STATE_DIR/.units.enable.replaced"; then
    echo "[$PROG] failed to remove $pkg_pending" >&2
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
