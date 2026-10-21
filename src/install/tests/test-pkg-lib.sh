#!/bin/sh
# test pkg-lib.sh offline
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
LIB="$HERE/../lib/pkg-lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILED=0
# shellcheck source=lib/host-write-guard.sh
. "$HERE/lib/host-write-guard.sh"
GUARDED_PATH=$(guard_path /usr/bin:/bin)
# print ok or FAIL for a comparison
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; return; fi
  echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; FAILED=$((FAILED + 1))
}

mkdir -p "$TMP/bin" "$TMP/bin-noadduser"
# write a stub command to $TMP/bin
stub() {
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n%s\n' "$1" "$TMP" "$2" > "$TMP/bin/$1"
  chmod +x "$TMP/bin/$1"
}
stub systemctl 'case "$1" in
  is-enabled) cat "'"$TMP"'/state/$2" 2>/dev/null || { echo disabled; exit 1; } ;;
  enable) grep -qx "$2" "'"$TMP"'/fail-enable" 2>/dev/null && exit 1 ;;
  --quiet) [ "$2" = is-active ] && { grep -qx "$3" "'"$TMP"'/active" 2>/dev/null; exit; }
           f="'"$TMP"'/fail-$2"
           [ -e "$f" ] && { [ ! -s "$f" ] || grep -qx "$3" "$f"; } && exit 1 ;;
  *) [ -e "'"$TMP"'/fail-$1" ] && exit 1 ;;
esac
exit 0'
stub adduser 'exit "$(cat "'"$TMP"'/adduser-rc" 2>/dev/null || echo 0)"'
stub useradd 'exit 0'
stub getent 'case "$1" in passwd) f=accounts ;; group) f=groups ;; *) exit 2 ;; esac
grep -qx "$2" "'"$TMP"'/$f" 2>/dev/null'
stub rhizo '[ "$*" = "profile show" ] && echo "RHIZO_PROFILE profile=$(cat "'"$TMP"'/profile")"
exit 0'
printf '#!/bin/sh\ncat "%s/configured-mode" 2>/dev/null || echo host\n' "$TMP" > "$TMP/bin/rhizo-selinux-mode"
chmod +x "$TMP/bin/rhizo-selinux-mode"
export RHIZO_SELINUX_MODE_HELPER="$TMP/bin/rhizo-selinux-mode"
for c in systemctl useradd getent rhizo; do cp "$TMP/bin/$c" "$TMP/bin-noadduser/$c"; done
mkdir -p "$TMP/state"
STUB_LIB="$TMP/lib-stub-rhizo.sh"
sed -e "s|/usr/bin/rhizo |$TMP/bin/rhizo |" "$LIB" > "$STUB_LIB"

# run code under dash with stubs on PATH
run() {
  : > "$TMP/calls"
  PATH="$1:$GUARDED_PATH" dash -ec '. "$1"; PKG_DEBIAN_VERSION="$2/debian_version"; PKG_LSM="$2/lsm"
    PKG_SELINUXFS="$2/selinuxfs"; PKG_VAR_RUN="$2/var-run"; MARK="$2/was-running"
    PKG_SELINUX_MODE_FILE="$2/selinux-mode"; eval "$3"' \
    run "$STUB_LIB" "$TMP" "$2" 2>&1
}
# print the calls the fakes recorded
calls() { cat "$TMP/calls"; }

dash -n "$LIB"; check "the library parses under dash" "$?" 0

ADDUSER='adduser --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin --group rhizo-netbridged'
USERADD='useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/bin/nologin'
USERADD="$USERADD rhizo-netbridged"
echo 13 > "$TMP/debian_version"
run "$TMP/bin" 'pkg_sys_account rhizo-netbridged' >/dev/null; rc=$?
check "debian: account rc"                 "$rc" 0
check "debian: adduser with today's argv"  "$(calls)" "$ADDUSER"
rm "$TMP/debian_version"
run "$TMP/bin" 'pkg_sys_account rhizo-netbridged' >/dev/null; rc=$?
check "no debian_version: account rc"      "$rc" 0
check "no debian_version: useradd"         "$(calls)" "getent group rhizo-netbridged
$USERADD"
echo 13 > "$TMP/debian_version"
if PATH="$TMP/bin-noadduser:/usr/bin:/bin" command -v adduser >/dev/null; then
  echo "FAIL no adduser: /usr/bin or /bin holds an adduser, so this case cannot take it away"; FAILED=$((FAILED + 1))
else
  run "$TMP/bin-noadduser" 'pkg_sys_account rhizo-netbridged' >/dev/null
  check "debian_version, no adduser: useradd" "$(calls)" "getent group rhizo-netbridged
$USERADD"
fi
rm "$TMP/debian_version"
echo rhizo-netbridged > "$TMP/groups"
run "$TMP/bin" 'pkg_sys_account rhizo-netbridged' >/dev/null; rc=$?
check "group exists, useradd: rc"          "$rc" 0
GID_USERADD='useradd --system --gid rhizo-netbridged --no-create-home --home-dir /nonexistent'
check "group exists: useradd takes it as the primary group" "$(calls)" "getent group rhizo-netbridged
$GID_USERADD --shell /usr/bin/nologin rhizo-netbridged"
echo rhizo-uhid > "$TMP/groups"
run "$TMP/bin" 'pkg_sys_account rhizo-netbridged' >/dev/null
check "another group exists: useradd makes its own" "$(calls)" "getent group rhizo-netbridged
$USERADD"
rm "$TMP/groups"
echo 13 > "$TMP/debian_version"
echo 1 > "$TMP/adduser-rc"
run "$TMP/bin" 'pkg_sys_account rhizo-netbridged' >/dev/null; rc=$?
check "adduser's failure is the step's"    "$rc" 1

printf 'rhizo-netbridged\nrhizo-uhid\n' > "$TMP/accounts"
out=$(run "$TMP/bin" pkg_accounts); rc=$?
check "accounts present: rc"               "$rc" 0
check "accounts present: no output"        "$out" ""
check "accounts present: only lookups"     "$(calls | tr '\n' ';')" \
  "getent passwd rhizo-netbridged;getent passwd rhizo-uhid;"
: > "$TMP/accounts"
out=$(run "$TMP/bin" pkg_accounts); rc=$?
check "account refused: rc"                "$rc" 1
check "account refused: names it"          "$out" "[rhizo] could not create the rhizo-netbridged system account"
check "account refused: today's argv, once" "$(calls | grep -c '^adduser ')/$(calls | grep '^adduser ')" "1/$ADDUSER"
rm "$TMP/adduser-rc"

APPARMOR="[rhizo] REBOOT REQUIRED. selinux replaces apparmor as this machine's
[rhizo] security module, which only a reboot can do. setup finishes
[rhizo] automatically on the way back up; then run: rhizo status"
BECOMES="[rhizo] REBOOT REQUIRED. selinux becomes this machine's security
[rhizo] module, which only a reboot can do. setup finishes
[rhizo] automatically on the way back up; then run: rhizo status"
printf 'lockdown,capability,landlock,yama,apparmor,ima,evm' > "$TMP/lsm"
check "ubuntu's lsm list: replaces apparmor"  "$(run "$TMP/bin" pkg_selinux_switch_notice)" "$APPARMOR"
printf 'capability,landlock,lockdown,yama,bpf' > "$TMP/lsm"
check "no apparmor: becomes the module"       "$(run "$TMP/bin" pkg_selinux_switch_notice)" "$BECOMES"
printf 'capability,apparmorx,yama' > "$TMP/lsm"
check "a longer name is not apparmor"         "$(run "$TMP/bin" pkg_selinux_switch_notice)" "$BECOMES"
printf 'apparmor' > "$TMP/lsm"
check "apparmor alone: replaces apparmor"     "$(run "$TMP/bin" pkg_selinux_switch_notice)" "$APPARMOR"
rm "$TMP/lsm"
check "no lsm file: becomes the module"       "$(run "$TMP/bin" pkg_selinux_switch_notice)" "$BECOMES"

UPGRADE="[rhizo] reboot to finish the upgrade"
POLICY="[rhizo] Android's security policy loads only at boot, before anyone
[rhizo] logs in, and this boot's logins started without it. The
[rhizo] one-time setup runs early on the next boot; reboot when
[rhizo] convenient. 'rhizo status' shows setup: pending-reboot until then."
# run pkg_reboot_notice and print its results
notice() {
  out=$(run "$TMP/bin" "pkg_read_selinux_mode; pkg_reboot_notice '$1'"); rc=$?
  printf '%s\nrc=%s was-running=%s reboot-required=%s' "$out" "$rc" \
    "$([ -e "$TMP/was-running" ] && echo yes || echo no)" \
    "$([ -e "$TMP/var-run/reboot-required" ] && echo yes || echo no)"
}
mkdir -p "$TMP/selinuxfs"; echo 1 > "$TMP/selinuxfs/enforce"; : > "$TMP/was-running"
check "sandbox stopped for the upgrade" "$(notice 0.1.2)" "$UPGRADE
[rhizo] the sandbox was stopped to replace its files and cannot
[rhizo] restart until this machine reboots. Your apps and data are
[rhizo] untouched; reboot when convenient.
rc=0 was-running=no reboot-required=yes"
rm -rf "$TMP/var-run"
check "enforcing, the sandbox ran this boot" "$(notice 0.1.2)" "$UPGRADE
[rhizo] the sandbox already ran on this boot, so the new version's
[rhizo] one-time setup runs early on the next boot, before Android's
[rhizo] policy loads. Your apps and data are untouched; reboot when
[rhizo] convenient. 'rhizo status' shows setup: pending-reboot until then.
rc=0 was-running=no reboot-required=yes"
NAMESPACE="[rhizo] reboot into the Rhizo kernel, the default boot entry now:
[rhizo] Android runs there in its own SELinux namespace, and the
[rhizo] one-time setup runs early on that boot. 'rhizo status' shows
[rhizo] setup: pending-reboot until then."
rm -rf "$TMP/var-run"; echo namespace > "$TMP/selinux-mode"; echo namespace > "$TMP/configured-mode"
check "namespace mode, the host's enforce node reads 1: the Rhizo kernel notice" "$(notice 0.1.2)" "$UPGRADE
$NAMESPACE
rc=0 was-running=no reboot-required=yes"
rm -rf "$TMP/var-run"; : > "$TMP/was-running"
check "namespace mode, the sandbox stopped for the upgrade: the Rhizo kernel notice" "$(notice 0.1.2)" "$UPGRADE
$NAMESPACE
rc=0 was-running=no reboot-required=yes"
rm -rf "$TMP/var-run" "$TMP/selinux-mode" "$TMP/selinuxfs"; printf 'lockdown,capability,landlock,yama,apparmor' > "$TMP/lsm"
check "namespace mode on a stock kernel: the Rhizo kernel notice, no module switch" "$(notice "")" \
  "[rhizo] reboot to finish the install
$NAMESPACE
rc=0 was-running=no reboot-required=yes"
rm -rf "$TMP/var-run" "$TMP/selinux-mode"; mkdir -p "$TMP/selinux-mode" "$TMP/selinuxfs"; echo 1 > "$TMP/selinuxfs/enforce"
echo host > "$TMP/configured-mode"
check "host configured, this boot's mode record unreadable: a named failure, no notice" "$(notice 0.1.2 | tail -2)" \
  "[rhizo] cannot read this boot's SELinux mode record $TMP/selinux-mode
rc=1 was-running=no reboot-required=no"
rm -rf "$TMP/var-run" "$TMP/selinux-mode"; echo permissive > "$TMP/selinux-mode"
check "host configured, this boot's mode record garbled: a named failure, no notice" "$(notice 0.1.2 | tail -2)" \
  "[rhizo] this boot's SELinux mode record $TMP/selinux-mode reads 'permissive', not host or namespace
rc=1 was-running=no reboot-required=no"
rm -rf "$TMP/selinux-mode"; printf '#!/bin/sh\necho "$@" > "%s/helper-argv"\necho host\n' "$TMP" > "$TMP/bin/rhizo-selinux-mode"
out=$(run "$TMP/bin" "pkg_read_selinux_mode")
check "pkg_read_selinux_mode asks the helper with the androidd env file" "$(cat "$TMP/helper-argv")" \
  "--env-file /etc/rhizo/androidd.env --configured"
printf '#!/bin/sh\ncat "%s/configured-mode" 2>/dev/null || echo host\n' "$TMP" > "$TMP/bin/rhizo-selinux-mode"
rm -rf "$TMP/var-run"; echo bogus > "$TMP/configured-mode"
check "a mode that is neither host nor namespace: refused, named" "$(notice "")" \
  "[rhizo] $TMP/bin/rhizo-selinux-mode --configured printed 'bogus', which is neither host nor namespace
rc=1 was-running=no reboot-required=no"
rm -rf "$TMP/var-run" "$TMP/lsm" "$TMP/configured-mode"; mkdir -p "$TMP/selinuxfs"; echo 0 > "$TMP/selinuxfs/enforce"
check "selinuxfs, permissive: an install" "$(notice "")" "[rhizo] reboot to finish the install
$POLICY
rc=0 was-running=no reboot-required=yes"
rm -rf "$TMP/var-run"
check "selinuxfs, permissive: an upgrade" "$(notice 0.1.2)" "$UPGRADE
$POLICY
rc=0 was-running=no reboot-required=yes"
rm -rf "$TMP/var-run" "$TMP/selinuxfs"; printf 'lockdown,capability,landlock,yama,apparmor' > "$TMP/lsm"
check "no selinuxfs: the module switch" "$(notice "")" "$APPARMOR
rc=0 was-running=no reboot-required=yes"
rm -rf "$TMP/var-run" "$TMP/lsm"

echo masked > "$TMP/state/rhizo-resync.path"
echo masked-runtime > "$TMP/state/rhizo-display-pool.path"
echo enabled > "$TMP/state/rhizo-app-events.service"
out=$(run "$TMP/bin" pkg_enable_core_units); rc=$?
check "masked: rc"                         "$rc" 0
check "masked: named, left masked"         "$out" \
  "[rhizo] rhizo-resync.path is masked by the server profile -- left masked, not enabled
[rhizo] rhizo-display-pool.path is masked by the server profile -- left masked, not enabled"
check "masked: enables only the others"    "$(calls | grep ' enable ' | tr '\n' ';')" \
  "systemctl enable rhizo-brokerd.socket;systemctl enable rhizo-app-events.service;systemctl enable rhizo-desktop-attach.path;systemctl enable rhizo-session-start.path;"
check "starts the attach path it enabled, for the boot already running" \
  "$(calls | grep -c '^systemctl start rhizo-desktop-attach.path$')" 1
echo masked > "$TMP/state/rhizo-desktop-attach.path"
out=$(run "$TMP/bin" pkg_enable_core_units)
check "masked attach path: named, left masked" "$(printf '%s\n' "$out" | grep -c 'rhizo-desktop-attach.path is masked')" 1
check "masked attach path: not enabled"    "$(calls | grep -c ' enable rhizo-desktop-attach.path')" 0
check "masked attach path: not started"    "$(calls | grep -c ' start rhizo-desktop-attach.path')" 0
rm "$TMP/state/"*
echo rhizo-resync.path > "$TMP/fail-enable"
out=$(run "$TMP/bin" pkg_enable_core_units); rc=$?
check "enable refused: rc"                 "$rc" 1
check "enable refused: stops there"        "$(calls | grep ' enable ' | tr '\n' ';')" \
  "systemctl enable rhizo-brokerd.socket;systemctl enable rhizo-resync.path;"
rm "$TMP/fail-enable"

printf 'a.socket\nb.service\nc.path\n' > "$TMP/units"
echo masked > "$TMP/state/b.service"
LISTED='PKG_UNITS_ENABLE="$2/units"; PKG_UNITS_APPLIED="$2/applied"; pkg_enable_listed_units'
echo desktop > "$TMP/profile"
out=$(run "$TMP/bin" "$LISTED"); rc=$?
check "listed enable: rc"                  "$rc" 0
check "listed enable: masked named with the desktop profile, left masked" "$out" \
  "[rhizo] b.service is masked by the desktop profile -- left masked, not enabled"
check "listed enable: the others enabled"  "$(calls | grep ' enable ' | tr '\n' ';')" \
  "systemctl enable a.socket;systemctl enable c.path;"
check "listed enable: the list recorded as applied" "$(cat "$TMP/applied" 2>&1)" "$(cat "$TMP/units")"
rm "$TMP/applied"
echo server > "$TMP/profile"
out=$(run "$TMP/bin" "$LISTED")
check "listed enable, server profile: masked named with the server profile" "$out" \
  "[rhizo] b.service is masked by the server profile -- left masked, not enabled"
rm "$TMP/applied"
echo "unknown (/etc/rhizo/policy.conf unreadable)" > "$TMP/profile"
out=$(run "$TMP/bin" "$LISTED")
check "listed enable, unreadable profile: masked named by the active profile" "$out" \
  "[rhizo] b.service is masked by the active profile -- left masked, not enabled"
rm "$TMP/applied"
echo desktop > "$TMP/profile"
echo a.socket > "$TMP/fail-enable"
out=$(run "$TMP/bin" "$LISTED"); rc=$?
check "listed enable refused: rc"          "$rc" 1
check "listed enable refused: every unit tried, the failure named" \
  "$(calls | grep -c ' enable '):$(printf '%s' "$out" | tail -1)" "2:[rhizo] could not enable: a.socket"
check "listed enable refused: nothing recorded as applied" "$(ls "$TMP/applied" 2>/dev/null)" ""
rm "$TMP/fail-enable" "$TMP/state/"*
out=$(run "$TMP/bin" 'PKG_UNITS_ENABLE="$2/no-such-list"; pkg_enable_listed_units' 2>&1); rc=$?
check "listed enable, no list: rc"         "$rc" 2
printf 'a.socket\nc.path\n' > "$TMP/replaced"
out=$(run "$TMP/bin" 'PKG_UNITS_ENABLE="$2/units"; PKG_UNITS_APPLIED="$2/applied"; pkg_enable_listed_units 0.1.3-1 "$2/replaced"'); rc=$?
check "listed enable, upgrade: rc"         "$rc" 0
check "listed enable, upgrade: only the newly listed unit" "$(calls | grep ' enable ' | tr '\n' ';')" \
  "systemctl enable b.service;"
out=$(run "$TMP/bin" 'PKG_UNITS_ENABLE="$2/units"; PKG_UNITS_APPLIED="$2/applied"; pkg_enable_listed_units 0.1.3-1 "$2/no-such"' 2>&1); rc=$?
check "listed enable, upgrade with no replaced list: refused, named" "$rc:$out:$(calls | grep -c ' enable ')" \
  "1:[rhizo] cannot read $TMP/no-such, the replaced version's unit list -- no unit enabled:0"
out=$(run "$TMP/bin" 'PKG_UNITS_ENABLE="$2/units"; PKG_UNITS_APPLIED="$2/applied"; pkg_enable_listed_units ""'); rc=$?
check "listed enable, new install: every unit" "$rc:$(calls | grep ' enable ' | tr '\n' ';')" \
  "0:systemctl enable a.socket;systemctl enable b.service;systemctl enable c.path;"
rm "$TMP/replaced" "$TMP/profile"
echo enabled > "$TMP/state/a.socket"; echo enabled-runtime > "$TMP/state/c.path"
echo static > "$TMP/state/b.service"; echo b.service > "$TMP/active"
run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_start_listed_units ""' >/dev/null; rc=$?
check "listed start, install: rc"          "$rc" 0
check "listed start, install: enabled units only" "$(calls | grep -v ' is-' | tr '\n' ';')" \
  "systemctl --quiet start a.socket;systemctl --quiet start c.path;"
run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_start_listed_units 0.1.3-1' >/dev/null; rc=$?
check "listed start, upgrade: rc"          "$rc" 0
check "listed start, upgrade: enabled and running units restarted" "$(calls | grep -v ' is-' | tr '\n' ';')" \
  "systemctl --quiet restart a.socket;systemctl --quiet restart b.service;systemctl --quiet restart c.path;"
rm "$TMP/active"
run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_start_listed_units 0.1.3-1' >/dev/null
check "listed start, upgrade: a stopped static unit stays stopped" "$(calls | grep -v ' is-' | tr '\n' ';')" \
  "systemctl --quiet restart a.socket;systemctl --quiet restart c.path;"
rm "$TMP/state/"*
run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_start_listed_units ""' >/dev/null; rc=$?
check "listed start, none enabled: rc"     "$rc" 0
check "listed start, none enabled: no start" "$(calls | grep -v ' is-')" ""
echo enabled > "$TMP/state/a.socket"; : > "$TMP/fail-start"
run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_start_listed_units ""' >/dev/null; rc=$?
check "listed start refused: rc"           "$rc" 1
echo enabled > "$TMP/state/c.path"; echo a.socket > "$TMP/fail-start"
out=$(run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_start_listed_units ""' 2>&1); rc=$?
check "listed start: a unit after a failing one still starts" "$(calls | grep -v ' is-' | tr '\n' ';')" \
  "systemctl --quiet start a.socket;systemctl --quiet start c.path;"
check "listed start: the failing one named, the step failed" "$rc:$out" "1:[rhizo] could not start: a.socket"
rm "$TMP/fail-start"; echo a.socket > "$TMP/fail-restart"
out=$(run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_start_listed_units 0.1.3-1' 2>&1); rc=$?
check "listed restart: a unit after a failing one still restarts" "$(calls | grep -v ' is-' | tr '\n' ';')" \
  "systemctl --quiet restart a.socket;systemctl --quiet restart c.path;"
check "listed restart: the failing one named, the step failed" "$rc:$out" "1:[rhizo] could not restart: a.socket"
rm "$TMP/fail-restart" "$TMP/state/"*
run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_stop_listed_units' >/dev/null; rc=$?
check "listed stop: rc"                    "$rc" 0
check "listed stop: one stop of every unit" "$(calls)" "systemctl stop a.socket b.service c.path"
: > "$TMP/fail-stop"
run "$TMP/bin" 'PKG_UNITS_START="$2/units"; pkg_stop_listed_units' >/dev/null; rc=$?
check "listed stop refused: rc"            "$rc" 1
rm "$TMP/fail-stop"

STEPS=$(sed -n 's/^ *pkg_step=\([a-z_]*\);.*/\1/p' "$LIB")
[ -n "$STEPS" ] || { echo "FAIL no pkg_step= line in $LIB, so no configure step can be stubbed"; exit 1; }
# print stub definitions for the configure steps
stub_steps() {
  for s in $STEPS; do
    printf '%s() { echo "%s $*" >> "$steps_log"; ' "$s" "$s"
    if [ "$s" = pkg_read_selinux_mode ]; then printf 'PKG_MODE="${CONFIGURE_MODE:-host}"; '; fi
    if [ "$s" = "$1" ]; then printf 'false; echo "%s went on" >> "$steps_log"; ' "$s"; fi
    if [ "$s" = "$2" ]; then printf 'exit 3; '; fi
    if [ "$s" = "${3:-}" ]; then printf 'return 4; '; fi
    printf '}\n'
  done
}
# run pkg_configure with stub steps
configure() {
  rm -f "$TMP/steps"
  out=$(RHIZO_INSTALL_FAILED="$TMP/install-failed" PATH="$TMP/bin:$GUARDED_PATH" "$1" -c '. "$1"; steps_log="$2/steps"
    eval "$3"; pkg_configure "$4" "$5"; echo "rc=$?"; echo "caller went on"' \
    configure "$LIB" "$TMP" "$(stub_steps "$3" "$4" "${5:-}")" "$2" "${2:+$TMP/replaced}" 2>"$TMP/configure-err")
  printf '%s\n%s' "$(sed 's/ *$//' "$TMP/steps")" "$out"
}
for sh in dash bash; do
  check "$sh: pkg_configure runs every step in order, host mode's files and edits left to rhizo install" \
    "$(configure "$sh" "" none none)" "pkg_read_selinux_mode
pkg_state_dirs_btrfs
pkg_state_dirs
pkg_accounts
pkg_install_and_grants
pkg_enable_core_units
pkg_user_units_and_desktop
pkg_stop_old_payload
pkg_reboot_notice
pkg_enable_listed_units
pkg_start_listed_units
pkg_unit_policy
rc=0
caller went on"
  check "$sh: pkg_configure in namespace mode runs no host-mode step" \
    "$(CONFIGURE_MODE=namespace configure "$sh" "" none none | tr '\n' ';')" "pkg_read_selinux_mode;pkg_state_dirs_btrfs;\
pkg_state_dirs;pkg_accounts;pkg_install_and_grants;pkg_enable_core_units;pkg_user_units_and_desktop;pkg_stop_old_payload;\
pkg_reboot_notice;pkg_enable_listed_units;pkg_start_listed_units;pkg_unit_policy;rc=0;caller went on"
  check "$sh: pkg_configure passes the replaced version" "$(configure "$sh" 0.1.3-1 none none | grep 0.1.3-1)" \
    "pkg_stop_old_payload 0.1.3-1
pkg_reboot_notice 0.1.3-1
pkg_enable_listed_units 0.1.3-1 $TMP/replaced
pkg_start_listed_units 0.1.3-1"
  check "$sh: a failing command stops its step and the steps after it" \
    "$(configure "$sh" "" pkg_user_units_and_desktop none | tr '\n' ';')" \
    "pkg_read_selinux_mode;pkg_state_dirs_btrfs;pkg_state_dirs;pkg_accounts;pkg_install_and_grants;pkg_enable_core_units;\
pkg_user_units_and_desktop;rc=1;caller went on"
  check "$sh: the failing step is named" "$(cat "$TMP/configure-err")" \
    "[rhizo] pkg_user_units_and_desktop failed (exit 1); configuring stopped there"
  check "$sh: the failing step is saved for rhizo status" "$(cat "$TMP/install-failed" 2>&1)" \
    "pkg_user_units_and_desktop 1"
  configure "$sh" "" none none >/dev/null
  check "$sh: a configure that finishes drops the saved failure" \
    "$(test -e "$TMP/install-failed" && echo kept || echo gone)" gone
  check "$sh: a step's exit stops it" "$(configure "$sh" "" none pkg_accounts | tr '\n' ';')" \
    "pkg_read_selinux_mode;pkg_state_dirs_btrfs;pkg_state_dirs;pkg_accounts;rc=3;caller went on"
  check "$sh: the exiting step is named" "$(cat "$TMP/configure-err")" \
    "[rhizo] pkg_accounts failed (exit 3); configuring stopped there"
  for s in pkg_enable_listed_units pkg_start_listed_units; do
    check "$sh: a failed $s still runs the start and the unit policy, then fails" \
      "$(configure "$sh" "" none none $s | tail -5 | tr '\n' ';')" \
      "pkg_enable_listed_units;pkg_start_listed_units;pkg_unit_policy;rc=4;caller went on"
    check "$sh: the failed $s is named" "$(cat "$TMP/configure-err")" \
      "[rhizo] $s failed (exit 4); the unit policy ran after it"
    check "$sh: the failed $s is saved for rhizo status" "$(cat "$TMP/install-failed" 2>&1)" "$s 4"
    rm -f "$TMP/install-failed"
  done
done

printf '[options]\nDownloadUser = alpm\nParallelDownloads = 5\n' > "$TMP/pacman.conf.orig"
mkdir -p "$TMP/pm/etc"
# run a function on the fixture pacman.conf
dl() {
  PATH="$TMP/bin:$GUARDED_PATH" "$1" -ec '. "$1"; RHIZO_PKG_ROOT="$2/pm"; RHIZO_INSTALL_RECORD="$2/pm/record"; "$3"' \
    dl "$LIB" "$TMP" "$2" 2>&1
}
for sh in dash bash; do
  cp "$TMP/pacman.conf.orig" "$TMP/pm/etc/pacman.conf"; rm -f "$TMP/pm/record"
  out=$(dl "$sh" pkg_pacman_downloaduser_off); rc=$?
  check "$sh: downloaduser off: rc"          "$rc:$out" "0:"
  check "$sh: downloaduser off: line commented" "$(cat "$TMP/pm/etc/pacman.conf")" \
    "[options]
#DownloadUser = alpm  # rhizo
ParallelDownloads = 5"
  check "$sh: downloaduser off: recorded"    "$(cat "$TMP/pm/record")" "pacman-downloaduser"
  dl "$sh" pkg_pacman_downloaduser_off >/dev/null
  check "$sh: downloaduser off twice: one token" "$(grep -c . "$TMP/pm/record")" 1
  out=$(dl "$sh" pkg_pacman_downloaduser_restore); rc=$?
  check "$sh: downloaduser restore: rc"      "$rc:$out" "0:"
  check "$sh: downloaduser restore: byte-identical" \
    "$(cmp "$TMP/pacman.conf.orig" "$TMP/pm/etc/pacman.conf" && echo same)" same
  printf '[options]\n#DownloadUser = alpm  # rhizo\n' > "$TMP/pm/etc/pacman.conf"; rm -f "$TMP/pm/record"
  dl "$sh" pkg_pacman_downloaduser_restore >/dev/null
  check "$sh: restore without the token leaves the line" "$(cat "$TMP/pm/etc/pacman.conf")" \
    "[options]
#DownloadUser = alpm  # rhizo"
  printf '[options]\n#DownloadUser = root\n' > "$TMP/pm/etc/pacman.conf"; echo pacman-downloaduser > "$TMP/pm/record"
  out=$(dl "$sh" pkg_pacman_downloaduser_restore); rc=$?
  check "$sh: restore of a hand-edited line: named, refused, token kept" \
    "$rc:$out:$(cat "$TMP/pm/record"):$(tail -1 "$TMP/pm/etc/pacman.conf")" \
    "1:[rhizo] DownloadUser in $TMP/pm/etc/pacman.conf is not active and carries no '# rhizo' mark to undo, \
so it stays as it is:pacman-downloaduser:#DownloadUser = root"
  printf '[options]\n#DownloadUser = alpm\n' > "$TMP/pm/etc/pacman.conf"; echo pacman-downloaduser > "$TMP/pm/record"
  dl "$sh" pkg_pacman_downloaduser_off >/dev/null; rc=$?
  check "$sh: no active line: off leaves the file" "$rc:$(cat "$TMP/pm/etc/pacman.conf")" "0:[options]
#DownloadUser = alpm"
  printf '[options]\n#DownloadUser = alpm\n' > "$TMP/pm/etc/pacman.conf"; rm -f "$TMP/pm/record"
  dl "$sh" pkg_pacman_downloaduser_off >/dev/null
  check "$sh: no active line: nothing recorded" "$(test -e "$TMP/pm/record" && echo recorded || echo none)" none
  printf '[options]\n#DownloadUser = alpm  # rhizo\n' > "$TMP/pm/etc/pacman.conf"; rm -f "$TMP/pm/record"
  dl "$sh" pkg_pacman_downloaduser_off >/dev/null
  check "$sh: a line this install commented with no token: the token is recorded" "$(cat "$TMP/pm/record" 2>&1)" \
    pacman-downloaduser
  cp "$TMP/pacman.conf.orig" "$TMP/pm/etc/pacman.conf"; rm -f "$TMP/pm/record"
  printf '#!/bin/sh\n/usr/bin/sed "$@"; exit 1\n' > "$TMP/bin/sed"; chmod +x "$TMP/bin/sed"
  dl "$sh" pkg_pacman_downloaduser_off >/dev/null; rc=$?
  rm -f "$TMP/bin/sed"
  check "$sh: an edit that fails halfway still leaves the token, so removal checks the file" \
    "$rc:$(cat "$TMP/pm/record" 2>&1)" "1:pacman-downloaduser"
done

printf '# login.defs\nTTYGROUP\ttty\nTTYPERM\t\t0600\nUMASK\t\t077\n' > "$TMP/login.defs.orig"
LOGIN_BLOCK="# >>> rhizo: login reopens the tty it gave the account, which root may only do through the account's own group
TTYGROUP	rhizo-no-tty-group
TTYPERM	0660
# <<< rhizo"
for sh in dash bash; do
  cp "$TMP/login.defs.orig" "$TMP/pm/etc/login.defs"; rm -f "$TMP/pm/record"; : > "$TMP/groups"
  out=$(dl "$sh" pkg_login_tty_on); rc=$?
  check "$sh: login tty on: rc" "$rc:$out" "0:"
  check "$sh: login tty on: the old lines commented, the block appended" "$(cat "$TMP/pm/etc/login.defs")" \
    "# login.defs
#TTYGROUP	tty  # rhizo
#TTYPERM		0600  # rhizo
UMASK		077
$LOGIN_BLOCK"
  check "$sh: login tty on: recorded" "$(cat "$TMP/pm/record")" "login-defs-tty"
  dl "$sh" pkg_login_tty_on >/dev/null
  check "$sh: login tty on twice: one block, one token" \
    "$(grep -c '^# >>> rhizo' "$TMP/pm/etc/login.defs"):$(grep -c . "$TMP/pm/record")" "1:1"
  out=$(dl "$sh" pkg_login_tty_restore); rc=$?
  check "$sh: login tty restore: rc" "$rc:$out" "0:"
  check "$sh: login tty restore: byte-identical" \
    "$(cmp "$TMP/login.defs.orig" "$TMP/pm/etc/login.defs" && echo same)" same
  echo rhizo-no-tty-group > "$TMP/groups"; rm -f "$TMP/pm/record"
  out=$(dl "$sh" pkg_login_tty_on); rc=$?
  check "$sh: login tty on with the group present: refused, file untouched, nothing recorded" \
    "$rc:$out:$(cmp "$TMP/login.defs.orig" "$TMP/pm/etc/login.defs" && echo same):$(test -e "$TMP/pm/record" && echo recorded || echo none)" \
    "1:[rhizo] a group named rhizo-no-tty-group exists: remove or rename that group, then install again:same:none"
  : > "$TMP/groups"
  printf '# login.defs\n#TTYGROUP\ttty\n' > "$TMP/pm/etc/login.defs"; cp "$TMP/pm/etc/login.defs" "$TMP/login.defs.commented"
  dl "$sh" pkg_login_tty_on >/dev/null; dl "$sh" pkg_login_tty_restore >/dev/null
  check "$sh: login tty on and restore with no active lines: byte-identical" \
    "$(cmp "$TMP/login.defs.commented" "$TMP/pm/etc/login.defs" && echo same)" same
  rm -f "$TMP/pm/etc/login.defs" "$TMP/pm/record"
  out=$(dl "$sh" pkg_login_tty_on); rc=$?
  check "$sh: no login.defs: nothing done" "$rc:$out:$(test -e "$TMP/pm/record" && echo recorded || echo none)" "0::none"
  cp "$TMP/login.defs.orig" "$TMP/pm/etc/login.defs"
  dl "$sh" pkg_login_tty_on >/dev/null; rm -f "$TMP/pm/record"
  dl "$sh" pkg_login_tty_restore >/dev/null
  check "$sh: restore without the token leaves the block" "$(grep -c '^# >>> rhizo' "$TMP/pm/etc/login.defs")" 1
  dl "$sh" pkg_login_tty_on >/dev/null
  check "$sh: a block already there with no token: the token is recorded" "$(cat "$TMP/pm/record" 2>&1)" \
    login-defs-tty
  cp "$TMP/login.defs.orig" "$TMP/pm/etc/login.defs"; rm -f "$TMP/pm/record"
  printf '#!/bin/sh\n/usr/bin/sed "$@"; exit 1\n' > "$TMP/bin/sed"; chmod +x "$TMP/bin/sed"
  dl "$sh" pkg_login_tty_on >/dev/null; rc=$?
  rm -f "$TMP/bin/sed"
  check "$sh: an edit that fails halfway still leaves the token, so removal checks the file" \
    "$rc:$(cat "$TMP/pm/record" 2>&1)" "1:login-defs-tty"
  cp "$TMP/login.defs.orig" "$TMP/pm/etc/login.defs"; rm -f "$TMP/pm/record"
  dl "$sh" pkg_login_tty_on >/dev/null
  grep -v '^# <<< rhizo$' "$TMP/pm/etc/login.defs" > "$TMP/login.defs.noend"; cp "$TMP/login.defs.noend" "$TMP/pm/etc/login.defs"
  out=$(dl "$sh" pkg_login_tty_restore); rc=$?
  check "$sh: restore with the end line removed by hand: refused, named, file untouched" \
    "$rc:$out:$(cmp "$TMP/login.defs.noend" "$TMP/pm/etc/login.defs" && echo same)" \
    "1:[rhizo] $TMP/pm/etc/login.defs has the '# >>> rhizo' line but no '# <<< rhizo' line after it, so nothing is \
removed: delete the block by hand and uncomment the lines marked '# rhizo':same"
done

mkdir -p "$TMP/pm/teardown" "$TMP/pm/lib"
sed -n '/^if \[\[ -f "\$INSTALL_RECORD" \]\] && grep -qx pacman-downloaduser /,/^fi$/p' "$HERE/../teardown/teardown.sh" > "$TMP/pm/teardown/teardown-block.sh"
cp "$LIB" "$TMP/pm/lib/pkg-lib.sh"
[ -s "$TMP/pm/teardown/teardown-block.sh" ] || { echo "FAIL the teardown has no DownloadUser block"; FAILED=$((FAILED + 1)); }
# run the teardown block on the fixture
tdb() {
  RHIZO_PKG_ROOT="$TMP/pm" INSTALL_RECORD="$TMP/pm/record" PATH="$(guard_path "$PATH")" bash -c '
    log() { echo "$*"; }; failstop() { echo "failstop $*"; exit 1; }; mark_change() { echo "changed $*"; }
    export RHIZO_PKG_ROOT; . "$1"' tdb "$TMP/pm/teardown/teardown-block.sh" 2>&1
}
cp "$TMP/pacman.conf.orig" "$TMP/pm/etc/pacman.conf"; rm -f "$TMP/pm/record"
dl bash pkg_pacman_downloaduser_off >/dev/null
out=$(tdb); rc=$?
check "teardown: restores a recorded DownloadUser" "$rc:$out" \
  "0:changed the DownloadUser line in /etc/pacman.conf, which this install commented out"
check "teardown: the file is byte-identical" \
  "$(cmp "$TMP/pacman.conf.orig" "$TMP/pm/etc/pacman.conf" && echo same)" same
check "teardown: the token is dropped" "$(grep -c pacman-downloaduser "$TMP/pm/record")" 0
printf '[options]\n#DownloadUser = alpm  # rhizo\n' > "$TMP/pm/etc/pacman.conf"; echo other > "$TMP/pm/record"
out=$(tdb)
check "teardown: no token, nothing touched" "$out:$(cat "$TMP/pm/etc/pacman.conf")" ":[options]
#DownloadUser = alpm  # rhizo"

printf '[options]\n#DownloadUser = root\n' > "$TMP/pm/etc/pacman.conf"; echo pacman-downloaduser > "$TMP/pm/record"
out=$(tdb | grep -c 'left the DownloadUser line')
check "teardown: a hand-edited line is left and says so" "$out:$(cat "$TMP/pm/record")" "1:pacman-downloaduser"

stub stream-sync 'exit 1'
sed -e "s|/usr/bin/rhizo |$TMP/bin/rhizo |" \
    -e "s|/usr/lib/rhizo/streamd/capability-sync.sh|$TMP/bin/stream-sync|" "$LIB" > "$TMP/lib-stub-cli.sh"
SYNC_TAIL="left it until 'systemctl start rhizo-stream-capability.service' succeeds"
# run pkg_unit_policy under dash with the stub rhizo CLI
policy() { PATH="$TMP/bin:$GUARDED_PATH" dash -ec '. "$1"; pkg_unit_policy' policy "$TMP/lib-stub-cli.sh" 2>&1; }
for p in desktop server; do
  echo "$p" > "$TMP/profile"
  : > "$TMP/calls"
  out=$(policy); rc=$?
  check "unit policy, $p: the profile applied again, then the stream sync" "$(calls | tr '\n' ';')" \
    "rhizo profile show;rhizo profile $p;stream-sync ;"
  check "unit policy, $p: the stream sync's failure named, the step not failed" "$rc:$(echo "$out" | tail -1)" \
    "0:[rhizo] could not sync rhizo-streamd.socket to stream.enabled; it stays as the package manager $SYNC_TAIL"
done
echo "unknown (/etc/rhizo/policy.conf unreadable)" > "$TMP/profile"
: > "$TMP/calls"
out=$(policy); rc=$?
check "unit policy, an unreadable profile: refused before any change" "$rc:$(calls | tr '\n' ';')" \
  "1:rhizo profile show;"
check "unit policy, an unreadable profile: the value named" "$out" \
  "[rhizo] 'rhizo profile show' names no profile (unknown (/etc/rhizo/policy.conf unreadable)) to apply again"
check "the library reads rhizo profile show in one function" "$(grep -c 'usr/bin/rhizo profile show' "$LIB")" 1
rm "$TMP/profile"

TREE="$(cd "$HERE/../../.." && pwd)"
mkdir -p "$TMP/real/etc" "$TMP/real/state" "$TMP/real/systemd"
printf '[stream]\nenabled = maybe\n' > "$TMP/real/policy.orig"
printf '#!/bin/sh\nexec bash "%s/src/install/cli/rhizo.sh" "$@"\n' "$TREE" > "$TMP/real/rhizo"
printf '#!/bin/sh\nexec bash "%s/src/services/streamd/capability-sync.sh" "$@"\n' "$TREE" > "$TMP/real/sync"
chmod +x "$TMP/real/rhizo" "$TMP/real/sync"
sed -e "s|/usr/bin/rhizo |$TMP/real/rhizo |" \
    -e "s|/usr/lib/rhizo/streamd/capability-sync.sh|$TMP/real/sync|" "$LIB" > "$TMP/lib-real-cli.sh"
BAD="$TMP/real/etc/policy.conf: [stream] enabled='maybe', expected yes or no"
for sh in dash bash; do
  cp "$TMP/real/policy.orig" "$TMP/real/etc/policy.conf"; : > "$TMP/calls"
  out=$(RHIZO_LIB_DIR="$TREE/src/androidd" RHIZO_ETC_DIR="$TMP/real/etc" RHIZO_STATE_DIR="$TMP/real/state" \
    RHIZO_INSTALL_FAILED="$TMP/real/etc/install-failed" \
    RHIZO_SYSTEMD_ETC_DIR="$TMP/real/systemd" RHIZO_POLICY_CONF="$TMP/real/etc/policy.conf" \
    RHIZO_CLI_TEST_NO_ROOT=1 PATH="$TMP/bin:$GUARDED_PATH" "$sh" -c '. "$1"; steps_log="$2/steps"; eval "$3"
      pkg_configure "" ""; echo "rc=$?"' \
    configure "$TMP/lib-real-cli.sh" "$TMP" "$(stub_steps none none | grep -v '^pkg_unit_policy()')" \
    2>"$TMP/real-err")
  check "$sh: an unparseable policy.conf: configure completes through the tree's CLI" "$(echo "$out" | tail -1)" rc=0
  check "$sh: an unparseable policy.conf: the desktop profile and stream.enabled's off applied" \
    "$(grep -cx -e 'systemctl disable --now rhizo-api.socket' -e 'systemctl disable --now rhizo-streamd.socket' \
       "$TMP/calls")" 2
  check "$sh: an unparseable policy.conf: named on stderr, then not rewritten" "$(cat "$TMP/real-err")" \
    "$BAD -- denying every optional capability
[rhizo] $BAD: applying desktop to the units only"
  check "$sh: an unparseable policy.conf: its bytes unchanged" \
    "$(cmp -s "$TMP/real/etc/policy.conf" "$TMP/real/policy.orig" && echo unchanged || echo rewritten)" unchanged
done

REAL_STAT=$(command -v stat); REAL_MV=$(command -v mv); REAL_MKDIR=$(command -v mkdir)
mkdir -p "$TMP/bin-btrfs" "$TMP/bin-nobtrfs" "$TMP/root/var/lib"
: > "$TMP/subvol-inos"
stub stat 'T='"$TMP"'
case "$1 $2" in
  "-f -c") o=$(cat "$T/own-fs" 2>/dev/null); [ -n "$o" ] && [ "${o%% *}" = "$4" ] && { echo "${o#* }"; exit 0; }
           cat "$T/fstype"; exit ;;
  "-c %d") [ "$3" = "$(cat "$T/own-dev" 2>/dev/null)" ] && { echo 4242; exit 0; } ;;
  "-c %i") i=$('"$REAL_STAT"' -c %i "$3") || exit; grep -qx "$i" "$T/subvol-inos" && i=256; echo "$i"; exit 0 ;;
esac
exec '"$REAL_STAT"' "$@"'
stub btrfs 'T='"$TMP"'
rc=$(cat "$T/btrfs-$2-rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
case "$1 $2" in
  "subvolume create") '"$REAL_MKDIR"' "$3" && '"$REAL_STAT"' -c %i "$3" >> "$T/subvol-inos" ;;
  "subvolume delete") rm -rf "$3" ;;
esac'
stub chattr 'exit "$(cat "'"$TMP"'/chattr-rc" 2>/dev/null || echo 0)"'
stub mv '[ -e "'"$TMP"'/mv-rc" ] && exit "$(cat "'"$TMP"'/mv-rc")"
exec '"$REAL_MV"' "$@"'
for c in stat btrfs chattr mv; do "$REAL_MV" "$TMP/bin/$c" "$TMP/bin-btrfs/$c"; done
cp "$TMP/bin-btrfs/stat" "$TMP/bin-btrfs/mv" "$TMP/bin-nobtrfs/"
R="$TMP/root/var/lib/rhizo"
N="$TMP/root/var/lib/.rhizo.new"
REC="$TMP/etc/rhizo/state-subvolume"
B="$TMP/bin-btrfs:$TMP/bin"
SUB="btrfs subvolume create $N;chattr +C $N;mv -T $N $R;"
NOCMD="[rhizo] no btrfs or chattr command -- $R left a plain directory; install btrfs-progs and\
 e2fsprogs before rhizo to make it a subvolume"
# run pkg_state_dirs_btrfs and print its results
state_dirs() {
  out=$(run "$1" 'PKG_STATE_DIR="$2/root/var/lib/rhizo"; PKG_STATE_SUBVOLUME_RECORD="$2/etc/rhizo/state-subvolume"
    pkg_state_dirs_btrfs'); rc=$?
  printf '%s|%s|%s|%s|%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ';')" \
    "$(calls | grep -E '^(btrfs|chattr|mv) ' | tr '\n' ';')" "$(is_dir "$R")" \
    "$(if [ -e "$N" ]; then echo new-left; else echo no-new; fi)" "$(cat "$REC" 2>/dev/null || echo no-record)"
}
# print dir when the path is a directory, else none
is_dir() { if [ -d "$1" ]; then echo dir; else echo none; fi; }
# write the R record into REC under the test etc/rhizo
leftover_record() { mkdir -p "$TMP/etc/rhizo"; echo "$R" > "$REC"; }
# make a directory and empty subvol-inos
plain() { : > "$TMP/subvol-inos"; mkdir "$1"; }
echo btrfs > "$TMP/fstype"
check "btrfs, no state dir: a NOCOW subvolume beside it, moved into place, recorded" "$(state_dirs "$B")" \
  "0||$SUB|dir|no-new|$R"
rm -rf "$R"; : > "$TMP/subvol-inos"; echo ext2/ext3 > "$TMP/fstype"; leftover_record
check "a parent that is not btrfs: nothing made, and a record it does not match dropped" "$(state_dirs "$B")" \
  "0|||none|no-new|no-record"
echo btrfs > "$TMP/fstype"; plain "$R"; : > "$R/data.img"; leftover_record
check "btrfs, a state dir holding files: left, named, and not recorded" "$(state_dirs "$B")" \
  "0|[rhizo] $R already holds files -- left a plain directory||dir|no-new|no-record"
rm "$R/data.img"
check "btrfs, an empty state dir: the new subvolume moved over it, recorded" "$(state_dirs "$B")" \
  "0||$SUB|dir|no-new|$R"
rm -rf "$R" "$REC"; plain "$R"; echo 1 > "$TMP/btrfs-create-rc"
check "btrfs, the subvolume refused: named, the empty state dir as it was" "$(state_dirs "$B")" \
  "1|[rhizo] could not make $N a btrfs subvolume to put in place of $R|btrfs subvolume create $N;|dir|no-new|no-record"
rm "$TMP/btrfs-create-rc"; echo 1 > "$TMP/chattr-rc"
check "btrfs, NOCOW refused: named, the new subvolume deleted, the state dir as it was" "$(state_dirs "$B")" \
  "1|[rhizo] could not set NOCOW on the new subvolume $N: chattr +C failed|btrfs subvolume create $N;chattr +C $N;\
btrfs subvolume delete $N;|dir|no-new|no-record"
echo 1 > "$TMP/btrfs-delete-rc"
check "btrfs, NOCOW refused and the new subvolume not deleted: both named, the state dir as it was" \
  "$(state_dirs "$B")" "1|[rhizo] could not set NOCOW on the new subvolume $N: chattr +C failed;[rhizo] could not\
 delete $N, which stays beside $R|btrfs subvolume create $N;chattr +C $N;btrfs subvolume delete $N;|dir|new-left|\
no-record"
rm -rf "$N" "$TMP/btrfs-delete-rc" "$TMP/chattr-rc"; echo 1 > "$TMP/mv-rc"
check "btrfs, the move refused: named, the new subvolume deleted, the state dir as it was" "$(state_dirs "$B")" \
  "1|[rhizo] could not move the new subvolume $N over $R|btrfs subvolume create $N;chattr +C $N;mv -T $N $R;\
btrfs subvolume delete $N;|dir|no-new|no-record"
rm -rf "$TMP/mv-rc" "$TMP/etc/rhizo"; rmdir "$R"; : > "$TMP/etc/rhizo"
check "btrfs, the record not written: named" "$(state_dirs "$B" | sed 's/^\(1|\)mkdir: [^;]*;/\1/')" \
  "1|[rhizo] could not record $R as a btrfs subvolume in $REC|$SUB|dir|no-new|no-record"
rm "$TMP/etc/rhizo"; echo "$R" > "$TMP/own-dev"
check "btrfs, an empty subvolume of its own already: left as it is, recorded" "$(state_dirs "$B")" "0|||dir|no-new|$R"
: > "$R/data.img"; rm "$REC"
check "btrfs, an upgrade's subvolume of its own holding files: left, nothing said, recorded" "$(state_dirs "$B")" \
  "0|||dir|no-new|$R"
rm -rf "$R"; plain "$R"; echo "$R" > "$TMP/own-dev"; echo "$R ext2/ext3" > "$TMP/own-fs"
stat -c %i "$R" >> "$TMP/subvol-inos"
check "btrfs, another filesystem's inode 256 mounted on the state dir: left, not recorded" "$(state_dirs "$B")" \
  "0|||dir|no-new|no-record"
rm -rf "$R" "$TMP/own-dev" "$TMP/own-fs"; plain "$R"
if PATH="$TMP/bin-nobtrfs:$TMP/bin:/usr/bin:/bin" command -v btrfs >/dev/null; then
  echo "FAIL no btrfs: /usr/bin or /bin holds a btrfs, so this case cannot take it away"; FAILED=$((FAILED + 1))
else
  check "btrfs, no btrfs command: named, the empty state dir left" \
    "$(state_dirs "$TMP/bin-nobtrfs:$TMP/bin")" "0|$NOCMD||dir|no-new|no-record"
fi
mkdir -p "$TMP/bin-nochattr"
cp "$TMP/bin-btrfs/stat" "$TMP/bin-btrfs/btrfs" "$TMP/bin-btrfs/mv" "$TMP/bin-nochattr/"
for c in dirname ls cat basename rm grep; do ln -s "$(command -v "$c")" "$TMP/bin-nochattr/$c"; done
if PATH="$TMP/bin-nochattr" command -v chattr >/dev/null; then
  echo "FAIL no chattr: $TMP/bin-nochattr holds a chattr, so this case cannot take it away"; FAILED=$((FAILED + 1))
else
  : > "$TMP/calls"
  out=$(PATH="$(guard_path "$TMP/bin-nochattr")" "$(command -v dash)" -ec '. "$1"; PKG_STATE_DIR="$2"; PKG_STATE_SUBVOLUME_RECORD="$3"
    pkg_state_dirs_btrfs' nochattr "$LIB" "$R" "$REC" 2>&1); rc=$?
  check "btrfs, no chattr command: named, the empty state dir left" \
    "$rc|$out|$(calls | grep -E '^(btrfs|mv) ' | tr '\n' ';')|$(is_dir "$R")" "0|$NOCMD||dir"
fi
rm -rf "$R"

TEARDOWN_SH="$TREE/src/install/teardown/teardown.sh"
TD_HELPERS=$(grep -E '^(log|mark_change)\(\) \{' "$TEARDOWN_SH")
TD_MOUNTED=$(sed -n '/^mounted_under() {/,/^}$/p' "$TEARDOWN_SH")
TD_STATE=$(sed -n '/^  if \[\[ -d "\$STATE_ROOT" \]\]; then$/,/^  fi$/p' "$TEARDOWN_SH")
for part in TD_HELPERS TD_MOUNTED TD_STATE; do
  eval "text=\$$part"
  [ -n "$text" ] || { echo "FAIL $part: no such text in $TEARDOWN_SH"; FAILED=$((FAILED + 1)); }
done
mkdir -p "$TMP/bin-rm"; REAL_RM=$(command -v rm)
printf '#!/bin/sh\nfor a; do t=$a; done\nif [ "$t" = "$(cat "%s/rm-keeps-root" 2>/dev/null)" ]; then\n' "$TMP" \
  > "$TMP/bin-rm/rm"
printf '  find "$t" -mindepth 1 -delete; exit "$(cat "%s/rm-rc")"\nfi\nexec %s "$@"\n' "$TMP" "$REAL_RM" \
  >> "$TMP/bin-rm/rm"
chmod +x "$TMP/bin-rm/rm"
S="$TMP/state-root"
# run the teardown state purge and print results
purge() {
  out=$(PATH="$TMP/bin-rm:$GUARDED_PATH" bash -c 'PROG=rhizo-host-teardown STATE_ROOT="$1"; eval "$2"
    ANY_CHANGE=0 DEFERRED_REMOVALS=0; eval "$3"; echo "deferred=$DEFERRED_REMOVALS"' \
    purge "$S" "$TD_HELPERS
$TD_MOUNTED" "$TD_STATE" 2>&1); rc=$?
  printf '%s;rc=%s|%s' "$(printf '%s' "$out" | tr '\n' ';')" "$rc" \
    "$(if [ -d "$S" ]; then echo "dir $(ls -A "$S")"; else echo none; fi)"
}
P=rhizo-host-teardown
LEFT="[$P]   deferring what is left of $S to the post-reboot cleanup: selinux denies removing it while enforcing"
mkdir "$S"; : > "$S/device-state"
check "purge, a state dir rm -rf takes: removed" "$(purge)" \
  "[$P]   removed: $S (--purge: every remaining Rhizo state file);deferred=0;rc=0|none"
mkdir "$S"; : > "$S/device-state"; echo "$S" > "$TMP/rm-keeps-root"; echo 1 > "$TMP/rm-rc"
check "purge, a subvolume's root rmdir(2) refuses before linux 4.18: its files gone, the root deferred" "$(purge)" \
  "$LEFT;deferred=1;rc=0|dir "
: > "$S/device-state"; echo 0 > "$TMP/rm-rc"
check "purge, a removal that exits 0 with the directory still there: deferred, as any leftover" "$(purge)" \
  "$LEFT;deferred=1;rc=0|dir "
rm -rf "$S" "$TMP/rm-keeps-root" "$TMP/rm-rc"

printf '#!/bin/sh\necho "teardown $*" >> "%s/calls"\nexit "${TEARDOWN_RC:-0}"\n' "$TMP" > "$TMP/teardown.sh"
out=$(run "$TMP/bin" 'TEARDOWN="$2/teardown.sh"; pkg_stop_old_payload ""'); rc=$?
check "new install: rc"                    "$rc" 0
check "new install: no teardown"           "$(calls)$out" ""
out=$(run "$TMP/bin" 'TEARDOWN="$2/teardown.sh"; pkg_stop_old_payload 0.1.2'); rc=$?
check "upgrade: rc"                        "$rc" 0
check "upgrade: stops the old payload"     "$(calls)" "teardown --stop-payload-processes"
out=$(TEARDOWN_RC=3 run "$TMP/bin" 'TEARDOWN="$2/teardown.sh"; pkg_stop_old_payload 0.1.2'); rc=$?
check "teardown refused: still rc 0"       "$rc" 0
check "teardown refused: says so"          "$out" \
  "[rhizo] a process an older version started may still run; the next boot's cleanup reaps it"

HM="$TMP/hm"
# run a host-mode link step on the fixture root
hm() { RHIZO_PKG_ROOT="$HM" RHIZO_INSTALL_RECORD="$HM/record" PATH="$GUARDED_PATH" dash -c '. "$1"; "$2"; echo "rc=$?"' \
         hm "$LIB" "$1" 2>&1; }
rm -rf "$HM"; mkdir -p "$HM/etc/profile.d" "$HM/usr/lib/systemd/system/user@.service.d" "$HM/usr/share"
: > "$HM/usr/lib/systemd/system/user@.service.d/other.conf"
for f in $(sed -n '/^PKG_HOST_MODE_FILES="/,/"$/p' "$LIB" | tr -d '"' | sed 's/^PKG_HOST_MODE_FILES=//'); do
  mkdir -p "$HM/usr/lib/rhizo/host-mode/$(dirname "$f")"; echo "$f" > "$HM/usr/lib/rhizo/host-mode/$f"
done
check "host-mode links: rc" "$(hm pkg_host_mode_links)" "rc=0"
check "host-mode links: every file linked, apt's skipped with no /etc/apt" \
  "$(cd "$HM" && find usr/lib/systemd usr/share etc -type l | LC_ALL=C sort | tr '\n' ' ')" \
  "etc/profile.d/rhizo-console-vt.sh usr/lib/systemd/system/accounts-daemon.service.d/rhizo-skel.conf \
usr/lib/systemd/system/avahi-daemon.service.d/50-rhizo-policy.conf usr/lib/systemd/system/service.d/50-rhizo-private-users.conf \
usr/lib/systemd/system/session-.scope.d/rhizo-session-vt.conf usr/lib/systemd/system/user@.service.d/rhizo-user-prep.conf \
usr/share/fish/vendor_conf.d/rhizo-console-acl.fish "
check "host-mode links: the record names the token and only the directories the links made" \
  "$(LC_ALL=C sort "$HM/record" | tr '\n' ' ')" "host-mode-dir:/usr/lib/systemd/system/accounts-daemon.service.d \
host-mode-dir:/usr/lib/systemd/system/avahi-daemon.service.d host-mode-dir:/usr/lib/systemd/system/service.d \
host-mode-dir:/usr/lib/systemd/system/session-.scope.d host-mode-dir:/usr/share/fish \
host-mode-dir:/usr/share/fish/vendor_conf.d host-mode-links "
: > "$HM/usr/lib/systemd/system/service.d/10-admin.conf"
check "host-mode unlink: rc" "$(hm pkg_host_mode_unlink)" "rc=0"
check "host-mode unlink: no link left, the directories it made gone, a directory holding another file kept" \
  "$(cd "$HM" && find usr/lib/systemd usr/share etc \( -type l -o -type d \) | LC_ALL=C sort | tr '\n' ' ')" \
  "etc etc/profile.d usr/lib/systemd usr/lib/systemd/system usr/lib/systemd/system/service.d \
usr/lib/systemd/system/user@.service.d usr/share "
check "host-mode unlink: the kept directory's token stays, every other token gone" "$(cat "$HM/record")" \
  "host-mode-dir:/usr/lib/systemd/system/service.d"
rm "$HM/usr/lib/systemd/system/service.d/10-admin.conf"
hm pkg_host_mode_unlink >/dev/null
check "host-mode unlink again once the directory empties: it goes, with its token" \
  "$([ -e "$HM/usr/lib/systemd/system/service.d" ] && echo kept || echo gone)|$(wc -c < "$HM/record")" "gone|0"
rm "$HM/usr/lib/rhizo/host-mode/usr/share/fish/vendor_conf.d/rhizo-console-acl.fish"
check "host-mode links from a payload with no fish file: linked, the fish file skipped" \
  "$(hm pkg_host_mode_links)|$(cd "$HM" && find usr/share -type l | wc -l)" "rc=0|0"
hm pkg_host_mode_unlink >/dev/null

# write a mode helper that fails as given
mode_helper() { printf '#!/bin/sh\n%s\n' "$1" > "$TMP/bin/rhizo-selinux-mode"; }
mode_helper 'echo "rhizo-selinux-mode: broken" >&2; exit 255'
check "a failing mode helper: refused, its message and the step's named" "$(run "$TMP/bin" 'pkg_read_selinux_mode'; echo "rc=$?")" \
  "rhizo-selinux-mode: broken
[rhizo] cannot read the configured SELinux mode from $TMP/bin/rhizo-selinux-mode
rc=1"
rm "$TMP/bin/rhizo-selinux-mode"
out=$(run "$TMP/bin" 'pkg_read_selinux_mode'); rc=$?
check "a missing mode helper: refused, named" "$(printf '%s\n' "$out" | tail -1)|rc=$rc" \
  "[rhizo] cannot read the configured SELinux mode from $TMP/bin/rhizo-selinux-mode|rc=1"
rm -f "$TMP/install-failed" "$TMP/steps"
out=$(RHIZO_INSTALL_FAILED="$TMP/install-failed" PATH="$TMP/bin:$GUARDED_PATH" dash -c '. "$1"; steps_log="$2/steps"
  pkg_state_dirs_btrfs() { echo state >> "$steps_log"; }; pkg_configure "" ""; echo "rc=$?"' cfg "$LIB" "$TMP" 2>&1)
check "a missing mode helper stops pkg_configure at its first step, saved for rhizo status, nothing after it run" \
  "$(printf '%s\n' "$out" | tail -1)|$(cat "$TMP/install-failed" 2>&1)|$(cat "$TMP/steps" 2>/dev/null)" \
  "rc=1|pkg_read_selinux_mode 1|"
rm -f "$TMP/install-failed" "$TMP/steps"
printf '#!/bin/sh\ncat "%s/configured-mode" 2>/dev/null || echo host\n' "$TMP" > "$TMP/bin/rhizo-selinux-mode"
chmod +x "$TMP/bin/rhizo-selinux-mode"

UPG="$TMP/upgrade"; mkdir -p "$UPG"
cat > "$UPG/run.sh" <<'UPGEOF'
set -uo pipefail
TREE=$1 UPG=$2
. "$TREE/src/install/tests/fixtures/bootloader-fixtures.sh"
R=$UPG/root I=$UPG/install
mkdir -p "$R" "$UPG/tools" "$I"
export RHIZO_BL_ROOT=$R
link_bootstrap_tools "$UPG/tools"
for t in bash sh python3 cmp ln rmdir getent; do ln -s "$(type -P "$t")" "$UPG/tools/$t"; done
add_cachyos_host "$R" limine
touch "$R/boot/vmlinuz-linux-rhizo" "$R/boot/initramfs-linux-rhizo.img"
run_stub "$R/bin/limine-update"
printf '[options]\nDownloadUser = alpm\n' > "$R/etc/pacman.conf"
printf '# login.defs\nTTYGROUP\ttty\nTTYPERM\t\t0600\n' > "$R/etc/login.defs"
cp "$R/etc/pacman.conf" "$UPG/pacman.conf.orig"; cp "$R/etc/login.defs" "$UPG/login.defs.orig"
mkdir -p "$R/lib/modules" "$R/usr/lib/systemd"; : > "$R/usr/lib/systemd/systemd"
while read -r src rel; do
  install -D -m 0644 "$TREE/$src" "$R/usr/lib/rhizo/host-mode/$rel"
done <<'MAP'
debian/dropins/private-users-off.conf usr/lib/systemd/system/service.d/50-rhizo-private-users.conf
debian/dropins/avahi-daemon-policy.conf usr/lib/systemd/system/avahi-daemon.service.d/50-rhizo-policy.conf
debian/dropins/accounts-daemon-skel.conf usr/lib/systemd/system/accounts-daemon.service.d/rhizo-skel.conf
debian/dropins/user-at-prep.conf usr/lib/systemd/system/user@.service.d/rhizo-user-prep.conf
debian/dropins/session-scope-vt.conf usr/lib/systemd/system/session-.scope.d/rhizo-session-vt.conf
debian/profile.d/console-vt.sh etc/profile.d/rhizo-console-vt.sh
debian/apt.conf.d/50rhizo etc/apt/apt.conf.d/50rhizo
MAP
mkdir -p "$I/bootstrap" "$I/lib" "$I/teardown" "$I/prepare"
for f in bootstrap/bootstrap.sh lib/host-flavor.sh bootstrap/bootloader.sh lib/pkg-lib.sh; do cp "$TREE/src/install/$f" "$I/$f"; done
sed "s|^RHIZO_TEARDOWN_LIB_HOST_MODULE_ROOT=.*|RHIZO_TEARDOWN_LIB_HOST_MODULE_ROOT=$R/lib/modules|" \
  "$TREE/src/install/teardown/teardown-lib.sh" > "$I/teardown/teardown-lib.sh"
sed "s|^HOST_EXEC_PATHS=(.*|HOST_EXEC_PATHS=($R/usr/lib/systemd/systemd|" "$TREE/src/install/teardown/teardown.sh" \
  | sed '/^                  \/usr\/bin\/dash /d; /^                  \/usr\/sbin\/modprobe)/s/.*/)/' > "$I/teardown/teardown.sh"
printf '#!/bin/sh\nexit 0\n' > "$I/prepare/prepare.sh"
chmod +x "$I"/*/*.sh
REC=$R/var/lib/rhizo/.created-by-install
ENVS=(PATH="$R/bin:$UPG/tools" HOME="$R" RHIZO_BL_ROOT="$R" RHIZO_OS_RELEASE="$R/etc/os-release"
  RHIZO_BOOT_DIR="$R/boot" RHIZO_PROC_CONFIG="$R/proc/config.gz" RHIZO_LSM_FILE="$R/sys/kernel/security/lsm"
  RHIZO_BOOTSTRAP_CMDLINE="$R/proc/cmdline" RHIZO_BOOTSTRAP_SWAPS="$R/proc/swaps" RHIZO_BOOTSTRAP_MEMINFO="$R/proc/meminfo"
  RHIZO_BOOTSTRAP_SELINUXFS="$R/sys/fs/selinux" RHIZO_BOOTSTRAP_ZSWAP="$R/sys/module/zswap/parameters/enabled"
  RHIZO_BOOTSTRAP_ATTR_CURRENT="$R/proc/self/attr/current" RHIZO_BINDER_DEVICES_FILE="$R/sys/module/binder/parameters/devices"
  RHIZO_BOOTSTRAP_FSTAB="$R/etc/fstab" RHIZO_BOOTSTRAP_SWAPFILE="$R/swapfile" RHIZO_STATE_DIR="$R/var/lib/rhizo"
  RHIZO_ETC_DIR="$R/etc/rhizo" RHIZO_RUN_MOUNT="$R/run" RHIZO_SELINUX_MODE_HELPER="$R/bin/rhizo-selinux-mode"
  RHIZO_SELINUX_MODE_FILE="$R/run/rhizo-selinux-mode" RHIZO_PKG_ROOT="$R" RHIZO_INSTALL_RECORD="$REC"
  RHIZO_SELINUX_ENFORCE="$R/sys/fs/selinux/enforce" RHIZO_CLI_TEST_NO_ROOT=1 RHIZO_LIB_DIR="$UPG/lib")
echo host > "$R/selinux-mode"
env -i "${ENVS[@]}" "$BL_FIX_UNSHARE" -r "$BL_FIX_BASH" "$I/bootstrap/bootstrap.sh" > "$UPG/host-install.out" 2>&1 \
  || { echo "host-mode bootstrap failed: $(tail -2 "$UPG/host-install.out")"; exit 1; }
mkdir -p "$R/etc/apt/apt.conf.d" "$R/etc/profile.d" "$R/var/lib/rhizo" "$R/run"
env -i "${ENVS[@]}" sh -c '. "$1"; pkg_pacman_downloaduser_off && pkg_login_tty_on && pkg_host_mode_links' sh \
  "$I/lib/pkg-lib.sh" || { echo "host-mode package edits failed"; exit 1; }
{ grep -c 'lsm=.*enforcing=0' "$R/etc/default/limine"; grep -cx -e pacman-downloaduser -e login-defs-tty -e host-mode-links "$REC"
  find "$R/usr/lib/systemd" "$R/etc/apt" "$R/etc/profile.d" -type l | wc -l; } | paste -sd ' ' > "$UPG/host-edits"
echo namespace > "$R/selinux-mode"
cat > "$UPG/upgrade.sh" <<EOF
RHIZO_CLI_SOURCE_ONLY=1 source "$TREE/src/install/cli/rhizo.sh"
INSTALL_DIR="$I"
# answer cmd_upgrade's unit queries
systemctl() { case "\$1 \${2:-}" in "is-enabled rhizo-prepare.service") echo enabled ;; "daemon-reload ") ;; *) return 1 ;; esac; }
cmd_upgrade
EOF
env -i "${ENVS[@]}" "$BL_FIX_UNSHARE" -r "$BL_FIX_BASH" "$UPG/upgrade.sh" > "$UPG/upgrade.out" 2>&1
echo "rc=$?" >> "$UPG/upgrade.out"
UPGEOF
bash "$UPG/run.sh" "$TREE" "$UPG" > "$UPG/setup.out" 2>&1
check "upgrade from host mode: the setup made the host-mode edits" \
  "$(cat "$UPG/setup.out")|$(cat "$UPG/host-edits" 2>&1)" "|1 3 7"
check "upgrade from host mode: rhizo upgrade ends asking for the reboot into the Rhizo kernel" \
  "$(tail -2 "$UPG/upgrade.out")" "RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=rhizo-kernel
rc=0"
check "upgrade from host mode: pacman.conf and login.defs byte-identical to before Rhizo" \
  "$(cmp "$UPG/pacman.conf.orig" "$UPG/root/etc/pacman.conf" && cmp "$UPG/login.defs.orig" "$UPG/root/etc/login.defs" \
     && echo same)" same
check "upgrade from host mode: no host-mode file linked" \
  "$(find "$UPG/root/usr/lib/systemd" "$UPG/root/etc/apt" "$UPG/root/etc/profile.d" -type l | wc -l)" 0
check "upgrade from host mode: the record keeps no host-mode token, and records the mode and the previous default" \
  "$(grep -v '^swapfile' "$UPG/root/var/lib/rhizo/.created-by-install")" "rhizo-kernel-default CachyOS/linux-cachyos
selinux-mode namespace"
check "upgrade from host mode: the tokens rewritten without lsm= or enforcing=, androidboot kept" \
  "$(grep -c 'lsm=\|enforcing=' "$UPG/root/etc/default/limine" "$UPG/root/boot/limine.conf" | tr '\n' ' ')|$(grep -c \
     'androidboot.hardware=rhizo' "$UPG/root/etc/default/limine")" \
  "$UPG/root/etc/default/limine:0 $UPG/root/boot/limine.conf:0 |1"
check "upgrade from host mode: the Rhizo kernel is the remembered boot entry" \
  "$(tail -c +5 "$UPG/root/sys/firmware/efi/efivars/LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a" | tr -d '\0')" \
  CachyOS/linux-rhizo
check "upgrade from host mode: the host labels cleared through the teardown, nothing said" \
  "$(grep -c 'rhizo_host_exec\|FAILED' "$UPG/upgrade.out")" 0

RU="$TMP/ru/etc/systemd/system"
mkdir -p "$RU/multi-user.target.wants" "$RU/rhizo-appwatch.service.d"
ln -s /usr/lib/systemd/system/rhizo-appwatch.service "$RU/multi-user.target.wants/rhizo-appwatch.service"
ln -s /dev/null "$RU/rhizo-prune.path"
echo '[Service]' > "$RU/rhizo-appwatch.service.d/10-desktop-user.conf"
: > "$TMP/calls"
ru_out=$(RHIZO_PKG_ROOT="$TMP/ru" PATH="$TMP/bin:$GUARDED_PATH" dash -c '. "$1"; pkg_rename_units; echo "rc=$?"' ru "$STUB_LIB" 2>&1)
check "renamed units: the move succeeds" "$ru_out" "rc=0"
check "renamed units: each old unit is stopped" "$(grep -c '^systemctl stop rhizo-\(appwatch\|prune\)' "$TMP/calls")" 3
check "renamed units: no enable link is left at an old name" "$(ls "$RU/multi-user.target.wants")" ""
check "renamed units: a masked old unit leaves its new name masked" \
  "$(readlink "$RU/rhizo-remove-entries.path")|$([ -e "$RU/rhizo-prune.path" ] || [ -L "$RU/rhizo-prune.path" ] && echo left)" "/dev/null|"
check "renamed units: an unmasked old unit masks nothing" "$([ -L "$RU/rhizo-app-events.service" ] && echo masked)" ""
check "renamed units: the old desktop-user drop-in is gone" "$([ -e "$RU/rhizo-appwatch.service.d" ] && echo left)" ""

report_escapes || FAILED=$((FAILED + 1))
[ "$FAILED" -eq 0 ] || { echo "$FAILED failed"; exit 1; }
echo "test-pkg-lib: ok"
