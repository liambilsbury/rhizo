#!/bin/sh
# test rhizo.install under bash and dash
set -u
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
INSTALL="$HERE/../../../archlinux/rhizo/rhizo.install"
LIB="$HERE/../lib/pkg-lib.sh"
POSTRM="$HERE/../../../debian/rhizo.postrm.in"
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
: > "$TMP/skipped"
# check a case or skip it
check_unprivileged() {
  if [ "$(id -u)" -ne 0 ]; then check "$@"; return; fi
  echo "SKIP $1 -- the suite runs as root, which no mode bit stops"
  echo x >> "$TMP/skipped"
}

mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho "systemctl $*" >> "%s/calls"\n[ -e "%s/fail-$1" ] && exit 1\nexit 0\n' "$TMP" "$TMP" \
  > "$TMP/bin/systemctl"
chmod +x "$TMP/bin/systemctl"
mkdir -p "$TMP/install/teardown"
printf '#!/bin/sh\necho "teardown $*" >> "%s/calls"\nexit "${TEARDOWN_RC:-0}"\n' "$TMP" > "$TMP/install/teardown/teardown.sh"
cat > "$TMP/stub-lib.sh" <<'EOF'
pkg_configure() { echo "pkg_configure [$*]" >> "$T/calls"; return "${CONFIGURE_RC:-0}"; }
pkg_pre_replace() { echo "pkg_pre_replace $*" >> "$T/calls"; return "${PRE_REPLACE_RC:-0}"; }
pkg_stop_listed_units() { echo "pkg_stop_listed_units $*" >> "$T/calls"; return "${STOP_RC:-0}"; }
EOF

# run code with rhizo.install sourced
scriptlet() {
  : > "$TMP/calls"
  PATH="$TMP/bin:$GUARDED_PATH" T="$TMP" "$1" -c '. "$1"; _lib="$2/stub-lib.sh"; _teardown="$2/install/teardown/teardown.sh"
    _state="$2/state"; _unit_dir="$2/units"; _payload="$2/payload"; _cache="$2/cache"; _logs="$2/logs"
    _srv="$2/srv"; eval "$3"' scriptlet "$INSTALL" "$TMP" "$2"
}
# print the logged calls separated by semicolons
calls() { tr '\n' ';' < "$TMP/calls"; }

for sh in bash dash; do
  rm -rf "$TMP/units" "$TMP/state"; mkdir -p "$TMP/units"
  out=$(scriptlet "$sh" 'pre_install 0.1.3-1'); rc=$?
  check "$sh: pre_install, no cleanup pending: nothing" "$rc:$out:$(calls)" "0::"
  : > "$TMP/units/rhizo-final-cleanup.service"
  out=$(scriptlet "$sh" 'pre_install 0.1.3-1'); rc=$?
  check "$sh: pre_install cancels a pending cleanup" "$rc:$out:$(calls)" \
    "0:[rhizo] canceled a pending post-removal cleanup from an earlier removal:systemctl disable --now \
rhizo-final-cleanup.service;systemctl daemon-reload;"
  check "$sh: pre_install deletes the cleanup unit" "$([ -e "$TMP/units/rhizo-final-cleanup.service" ] && echo kept)" ""
  : > "$TMP/units/rhizo-final-cleanup.service"; : > "$TMP/fail-disable"
  out=$(scriptlet "$sh" 'pre_install 0.1.3-1'); rc=$?
  check "$sh: a refused disable is returned, the unit still deleted, nothing claimed" \
    "$rc:$out:$([ -e "$TMP/units/rhizo-final-cleanup.service" ] && echo kept)" "1::"
  rm "$TMP/fail-disable"

  rm -rf "$TMP/state"
  out=$(scriptlet "$sh" 'post_install 0.1.3-1'); rc=$?
  check "$sh: post_install configures nothing and records an install's configure for the hook" \
    "$rc:$out:$(calls):$(wc -c < "$TMP/state/.configure-pending")" "0:::0"
  mkdir -p "$TMP/state"; echo a.socket > "$TMP/state/.units.enable.replaced"
  out=$(scriptlet "$sh" 'post_upgrade 0.1.4-1 0.1.3-1'); rc=$?
  check "$sh: post_upgrade configures nothing and records the replaced version for the hook, the unit list kept" \
    "$rc:$out:$(calls):$(cat "$TMP/state/.configure-pending"):$(cat "$TMP/state/.units.enable.replaced")" \
    "0:::0.1.3-1:a.socket"
  rm -rf "$TMP/state"; : > "$TMP/state"
  out=$(scriptlet "$sh" 'post_install 0.1.3-1' 2>&1); rc=$?
  check "$sh: a state dir that cannot be made: post_install fails, named" "$rc:$(printf '%s' "$out" | tail -1)" \
    "1:[rhizo] could not record the configure for the PostTransaction hook in $TMP/state"
  rm -f "$TMP/state"

  : > "$TMP/units/rhizo-final-cleanup.service"
  mkdir -p "$TMP/state"; printf 'a.socket\nb.path\n' > "$TMP/state/.units.enable.applied"
  out=$(scriptlet "$sh" 'pre_upgrade 0.1.4-1 0.1.3-1'); rc=$?
  check "$sh: pre_upgrade stops the old version and cancels a pending cleanup" "$rc:$(calls)" \
    "0:systemctl disable --now rhizo-final-cleanup.service;systemctl daemon-reload;pkg_pre_replace upgrade;"
  check "$sh: pre_upgrade records the replaced version" "$(cat "$TMP/state/.upgrade-from")" 0.1.3-1
  check "$sh: pre_upgrade keeps the unit list an install applied in full" \
    "$(cat "$TMP/state/.units.enable.replaced" 2>&1)" "$(printf 'a.socket\nb.path')"
  rm "$TMP/state/.units.enable.applied" "$TMP/state/.units.enable.replaced"
  out=$(scriptlet "$sh" 'pre_upgrade 0.1.4-1 0.1.3-1' 2>&1); rc=$?
  check "$sh: no applied unit list: an empty one, so the upgrade enables every unit" \
    "$rc:$(wc -c < "$TMP/state/.units.enable.replaced")" "0:0"
  out=$(PRE_REPLACE_RC=1 scriptlet "$sh" 'pre_upgrade 0.1.4-1 0.1.3-1'); rc=$?
  check "$sh: pre_upgrade returns the stop's failure" "$rc" 1

  out=$(scriptlet "$sh" 'unset RHIZO_TEARDOWN_PURGE; pre_remove 0.1.3-1' 2>&1); rc=$?
  check "$sh: pre_remove: prerm's remove arm, the unit stops, then a teardown that keeps data" "$rc:$out:$(calls)" \
    "0::pkg_pre_replace remove;pkg_stop_listed_units ;teardown ;"
  out=$(RHIZO_TEARDOWN_PURGE=1 scriptlet "$sh" 'pre_remove 0.1.3-1' 2>&1); rc=$?
  check "$sh: pre_remove purges on RHIZO_TEARDOWN_PURGE=1" "$rc:$(calls)" \
    "0:pkg_pre_replace remove;pkg_stop_listed_units ;teardown --purge;"
  out=$(RHIZO_TEARDOWN_PURGE=yes scriptlet "$sh" 'pre_remove 0.1.3-1' 2>&1); rc=$?
  check "$sh: pre_remove purges on 1 only" "$(calls | sed 's/.*;teardown/teardown/')" "teardown ;"
  mkdir -p "$TMP/install/lib" "$TMP/install/bootstrap"
  for f in teardown/teardown-lib.sh lib/host-flavor.sh bootstrap/bootloader.sh lib/pkg-lib.sh; do : > "$TMP/install/$f"; done
  mkdir -p "$TMP/payload"; : > "$TMP/payload/rhizo-selinux-mode"
  rm -rf "$TMP/state/teardown"
  out=$(TEARDOWN_RC=3 scriptlet "$sh" 'pre_remove 0.1.3-1' 2>&1); rc=$?
  check "$sh: a failing teardown is named and returned, kept, and the command that finishes it named" "$rc:$out" \
    "1:[rhizo] teardown reported a problem; see its output above
[rhizo] pacman removes the package anyway; once the problem above is fixed, finish with:
[rhizo]   sudo bash $TMP/state/teardown/install/teardown/teardown.sh  && sudo rm -r $TMP/state/teardown"
  check "$sh: the kept teardown has the libraries it sources and the mode helper it runs" \
    "$(cd "$TMP/state/teardown" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" \
    "./install/bootstrap/bootloader.sh ./install/lib/host-flavor.sh ./install/lib/pkg-lib.sh ./install/teardown/teardown-lib.sh ./install/teardown/teardown.sh ./rhizo-selinux-mode "
  out=$(TEARDOWN_RC=3 RHIZO_TEARDOWN_PURGE=1 scriptlet "$sh" 'pre_remove 0.1.3-1' 2>&1)
  check "$sh: a kept purge is finished as a purge" "$(printf '%s\n' "$out" | tail -1)" \
    "[rhizo]   sudo bash $TMP/state/teardown/install/teardown/teardown.sh --purge && sudo rm -r $TMP/state/teardown"
  out=$(scriptlet "$sh" 'pre_install 0.1.3-1' 2>&1)
  check "$sh: a reinstall drops a kept teardown" "$([ -e "$TMP/state/teardown" ] && echo kept)" ""
  out=$(PRE_REPLACE_RC=1 STOP_RC=1 scriptlet "$sh" 'pre_remove 0.1.3-1' 2>&1); rc=$?
  check "$sh: the teardown runs after a failing stop" "$rc:$(calls)" \
    "1:pkg_pre_replace remove;pkg_stop_listed_units ;teardown ;"
  out=$(scriptlet "$sh" '_lib=/nonexistent/pkg-lib.sh; pre_remove 0.1.3-1' 2>/dev/null); rc=$?
  check "$sh: the teardown runs without the library" "$rc:$(calls)" "1:teardown ;"

  postrm_fixture() {
    rm -rf "$TMP/cache" "$TMP/logs" "$TMP/units" "$TMP/payload" "$TMP/srv"
    mkdir -p "$TMP/cache/x" "$TMP/logs" "$TMP/payload/tools/__pycache__" "$TMP/payload/__pycache__" \
      "$TMP/payload/kept" "$TMP/srv"
    : > "$TMP/payload/__pycache__/a.pyc"; : > "$TMP/payload/tools/__pycache__/b.pyc"; : > "$TMP/payload/kept/c"
    for u in rhizo-app-events.service rhizo-deskd.service rhizo-desktop-session.service rhizo-audiod.service; do
      mkdir -p "$TMP/units/$u.d"; : > "$TMP/units/$u.d/10-desktop-user.conf"
    done
    : > "$TMP/units/rhizo-audiod.service.d/20-admin.conf"
  }
  left() { (cd "$TMP" && find cache logs units payload srv 2>/dev/null | LC_ALL=C sort | tr '\n' ' '); }
  postrm_fixture; mkdir -p "$TMP/state"; : > "$TMP/state/.units.enable.applied"; : > "$TMP/state/.configure-pending"
  : > "$TMP/state/.units.enable.replaced"
  out=$(scriptlet "$sh" 'unset RHIZO_TEARDOWN_PURGE; post_remove 0.1.3-1' 2>&1); rc=$?
  check "$sh: post_remove: rc and reload" "$rc:$out:$(calls)" "0::systemctl daemon-reload;"
  check "$sh: post_remove forgets the applied unit list, and the replaced list and configure of an upgrade no hook ran" \
    "$(for f in .units.enable.applied .units.enable.replaced .configure-pending; do [ ! -e "$TMP/state/$f" ] || echo "$f"; done)" ""
  check "$sh: post_remove leaves an admin's drop-in, the payload's own files and /srv" "$(left)" \
    "payload payload/kept payload/kept/c srv units units/rhizo-audiod.service.d \
units/rhizo-audiod.service.d/20-admin.conf "
  postrm_fixture
  out=$(RHIZO_TEARDOWN_PURGE=1 scriptlet "$sh" 'post_remove 0.1.3-1' 2>&1); rc=$?
  check "$sh: a purge also takes an empty /srv" "$rc:$(left | grep -c 'srv ')" "0:0"
  postrm_fixture; : > "$TMP/srv/gsi"
  out=$(RHIZO_TEARDOWN_PURGE=1 scriptlet "$sh" 'post_remove 0.1.3-1' 2>&1); rc=$?
  check "$sh: a purge keeps a /srv that holds something" "$rc:$(left | grep -c 'srv ')" "0:1"
  postrm_fixture; chmod 0500 "$TMP/cache/x"; : > "$TMP/cache/y"; chmod 0500 "$TMP/cache"
  out=$(scriptlet "$sh" 'post_remove 0.1.3-1' 2>/dev/null); rc=$?
  check_unprivileged "$sh: a state dir that cannot go is named and returned" "$rc:$out" "1:"
  out=$(scriptlet "$sh" 'post_remove 0.1.3-1' 2>&1 >/dev/null | tail -1)
  check_unprivileged "$sh: the failure names the dir" "$out" "[rhizo] could not remove $TMP/cache"
  : > "$TMP/units/rhizo-final-cleanup.service"
  out=$(scriptlet "$sh" 'post_remove 0.1.3-1' 2>/dev/null); rc=$?
  check_unprivileged "$sh: one the teardown scheduled is left to its cleanup" "$rc:$out" \
    "0:[rhizo] $TMP/cache is left to rhizo-final-cleanup.service at the next boot"
  chmod -R u+w "$TMP/cache"
done

# run a copy of the real teardown without its payload
kept_alone() {
  rm -rf "$TMP/kept"; mkdir -p "$TMP/kept/payload/install" "$TMP/kept/state"
  cp -r "$HERE/../teardown" "$HERE/../lib" "$HERE/../bootstrap" "$TMP/kept/payload/install/"
  cp "$HERE/../../androidd/host/selinux-mode.py" "$TMP/kept/payload/rhizo-selinux-mode"
  PATH="$TMP/bin:$GUARDED_PATH" bash -c '. "$1"; _teardown="$2/payload/install/teardown/teardown.sh"
    _state="$2/state"; _payload="$2/payload"; _keep_teardown --verify' keep "$INSTALL" "$TMP/kept" 2>/dev/null
  rm -r "$TMP/kept/payload"
  chmod 0644 "$TMP/kept/state/teardown/rhizo-selinux-mode"
  env -u RHIZO_SELINUX_MODE_HELPER PATH=/usr/bin:/bin bash "$TMP/kept/state/teardown/install/teardown/teardown.sh" --verify 2>&1
}
out=$(kept_alone)
check "the kept teardown runs alone, its mode helper read through python3 from a copy that cannot execute" \
  "$(printf '%s\n' "$out" | grep -c 'rhizo-selinux-mode\|library-unreadable\|selinux-mode-unreadable'):$(printf \
     '%s\n' "$out" | tail -1 | sed 's/^RHIZO_TEARDOWN_FAILED reason=not-clean$/RHIZO_TEARDOWN_VERIFIED=1/')" \
  "0:RHIZO_TEARDOWN_VERIFIED=1"

want=$(sed -n 's/^DESKTOP_USER_DROPINS="\(.*\)"$/\1/p' "$POSTRM")
got=$(sed -n 's/^_dropin_units="\(.*\)"$/\1/p' "$INSTALL")
check "the drop-in list is debian/rhizo.postrm.in's" "$got" "$want"

STEPS=$(sed -n 's/^ *pkg_step=\([a-z_]*\);.*/\1/p' "$LIB")
[ -n "$STEPS" ] || { echo "FAIL no pkg_step= line in $LIB, so no configure step can be stubbed"; exit 1; }
for s in $STEPS; do
  printf '%s() { echo %s >> "$T/calls"; }\n' "$s" "$s"
done > "$TMP/steps.sh"
printf '. "%s"\n. "%s/steps.sh"\n' "$LIB" "$TMP" > "$TMP/real-lib.sh"
cat >> "$TMP/real-lib.sh" <<'EOF'
PKG_STATE_DIR="$T/pkg-state"; PKG_STATE_SUBVOLUME_RECORD="$T/state-subvolume"
RHIZO_INSTALL_RECORD="$T/install-record"; RHIZO_INSTALL_FAILED="$T/install-failed"
pkg_accounts() { echo pkg_accounts >> "$T/calls"; false; echo on >> "$T/calls"; }
EOF
HOOK="$HERE/../../../archlinux/files/usr/share/libalpm/hooks/zz-rhizo-configure.hook"
HOOK_SCRIPT="$HERE/../../../archlinux/files/usr/share/libalpm/scripts/rhizo-configure"
check "the configure hook runs after rhizo installs or upgrades, once the transaction ends" \
  "$(grep -E '^(Operation|Type|Target|When|Exec) = ' "$HOOK" | tr '\n' ';')" \
  "Operation = Install;Operation = Upgrade;Type = Package;Target = rhizo;When = PostTransaction;\
Exec = /usr/share/libalpm/scripts/rhizo-configure;"
for kernel_hook in 60-depmod.hook 90-mkinitcpio-install.hook 90-limine-mkinitcpio-remove-post.hook grub.hook \
                   sdboot-kernel-update.hook; do
  check "pacman runs the configure hook after $kernel_hook" \
    "$(printf '%s\n%s\n' "$kernel_hook" zz-rhizo-configure.hook | LC_ALL=C sort | tail -1)" zz-rhizo-configure.hook
done
check "the hook's script runs the recorded configure through the installed library" \
  "$(grep -vE '^#' "$HOOK_SCRIPT" | tr '\n' ';')" ". /usr/lib/rhizo/install/lib/pkg-lib.sh || exit 1;pkg_configure_pending;"
check "the hook's script is executable" "$([ -x "$HOOK_SCRIPT" ] && echo yes)" yes

# run the recorded configure through the library with stub steps
pending() {
  : > "$TMP/calls"
  T="$TMP" PATH="$TMP/bin:$GUARDED_PATH" "$1" -c '. "$1"; PKG_STATE_DIR="$2/state"; eval "$3"; pkg_configure_pending; echo "rc=$?"' \
    pending "$LIB" "$TMP" "$2" 2>&1
}
STUB_CONFIGURE='pkg_configure() { echo "pkg_configure [$*]" >> "$T/calls"; return "${CONFIGURE_RC:-0}"; }'
for sh in bash dash; do
  rm -rf "$TMP/state"; mkdir -p "$TMP/state"; : > "$TMP/state/.configure-pending"
  out=$(pending "$sh" "$STUB_CONFIGURE")
  check "$sh: the hook configures a new install, then drops the record" \
    "$out:$(calls):$([ -e "$TMP/state/.configure-pending" ] && echo kept)" "rc=0:pkg_configure [ ];:"
  echo 0.1.3-1 > "$TMP/state/.configure-pending"; echo a.socket > "$TMP/state/.units.enable.replaced"
  out=$(pending "$sh" "$STUB_CONFIGURE")
  check "$sh: the hook configures an upgrade from the recorded version and its unit list, then drops both" \
    "$out:$(calls):$(ls -A "$TMP/state")" "rc=0:pkg_configure [0.1.3-1 $TMP/state/.units.enable.replaced];:"
  echo 0.1.3-1 > "$TMP/state/.configure-pending"
  out=$(CONFIGURE_RC=4 pending "$sh" "$STUB_CONFIGURE")
  check "$sh: a failed configure's status returned, the record dropped all the same" \
    "$out:$(ls -A "$TMP/state")" "rc=4:"
  out=$(pending "$sh" "$STUB_CONFIGURE")
  check "$sh: the hook with no recorded configure refuses, named" "$out:$(calls)" \
    "[rhizo] no $TMP/state/.configure-pending: rhizo's install or upgrade scriptlet left no configure for this hook
rc=1:"
done

rm -f "$TMP/install-failed"; mkdir -p "$TMP/pkg-state"; : > "$TMP/pkg-state/.configure-pending"
: > "$TMP/calls"
out=$(T="$TMP" PATH="$TMP/bin:$GUARDED_PATH" bash -c '. "$1"; pkg_configure_pending' rl "$TMP/real-lib.sh" 2>&1); rc=$?
check "bash: the hook with the library: a failing step stops it, named" "$rc:$out:$(calls)" \
  "1:[rhizo] pkg_accounts failed (exit 1); configuring stopped there:pkg_read_selinux_mode;pkg_state_dirs_btrfs;pkg_state_dirs;\
pkg_accounts;"
check "bash: the hook with the library: the failing step saved for rhizo status" \
  "$(cat "$TMP/install-failed" 2>&1)" "pkg_accounts 1"

printf '. "%s"\n. "%s/steps.sh"\n' "$LIB" "$TMP" > "$TMP/joint-lib.sh"
cat >> "$TMP/joint-lib.sh" <<'EOF'
PKG_STATE_DIR="$T/pkg-state"; PKG_STATE_SUBVOLUME_RECORD="$T/state-subvolume"
RHIZO_INSTALL_RECORD="$T/install-record"; RHIZO_INSTALL_FAILED="$T/install-failed"
pkg_install_and_grants() {
  if [ ! -e "$T/kernel-entry" ]; then
    echo "/boot/limine.conf lists no Rhizo kernel entry -- is the Rhizo kernel installed?" >&2; return 1
  fi
  echo pkg_install_and_grants >> "$T/calls"
}
EOF
sed "s|/usr/lib/rhizo/install/lib/pkg-lib.sh|$TMP/joint-lib.sh|" "$HOOK_SCRIPT" > "$TMP/rhizo-configure"
NS_STEPS=$(printf '%s\n' $STEPS | grep -vx 'pkg_pacman_downloaduser_off\|pkg_login_tty_on\|pkg_host_mode_links' | tr '\n' ';')
# run the copied hook script as pacman would
run_hook() { : > "$TMP/calls"; T="$TMP" PATH="$TMP/bin:$GUARDED_PATH" "$1" "$TMP/rhizo-configure" 2>&1; }
for sh in bash dash; do
  rm -rf "$TMP/pkg-state" "$TMP/kernel-entry" "$TMP/install-failed"
  out=$(scriptlet "$sh" '_lib="$2/joint-lib.sh"; _state="$2/pkg-state"; post_install 0.1.3-1' 2>&1); rc=$?
  check "$sh: one transaction with the kernel: rhizo's scriptlet runs before the kernel has a boot entry and succeeds" \
    "$rc:$out:$(calls)" "0::"
  : > "$TMP/kernel-entry"
  out=$(run_hook "$sh"); rc=$?
  check "$sh: one transaction with the kernel: rhizo's hook, after the kernel's, runs every namespace-mode step" \
    "$rc:$out:$(calls)" "0::$NS_STEPS"
  check "$sh: one transaction with the kernel: nothing pending, no failure saved" \
    "$(ls -A "$TMP/pkg-state"):$([ -e "$TMP/install-failed" ] && echo saved)" ":"
  rm -rf "$TMP/pkg-state" "$TMP/kernel-entry" "$TMP/install-failed"
  scriptlet "$sh" '_lib="$2/joint-lib.sh"; _state="$2/pkg-state"; post_upgrade 0.1.4-1 0.1.3-1' >/dev/null 2>&1
  out=$(run_hook "$sh"); rc=$?
  check "$sh: the Rhizo kernel still has no entry when the hook runs: it fails, named, the step saved for rhizo status" \
    "$rc:$(printf '%s\n' "$out" | head -1):$(cat "$TMP/install-failed" 2>&1)" \
    "1:/boot/limine.conf lists no Rhizo kernel entry -- is the Rhizo kernel installed?:pkg_install_and_grants 1"
done

report_escapes || FAILED=$((FAILED + 1))
SKIPPED=$(grep -c '' "$TMP/skipped")
SKIP_NOTE=""; [ "$SKIPPED" -eq 0 ] || SKIP_NOTE=", $SKIPPED skipped as root"
[ "$FAILED" -eq 0 ] || { echo "$FAILED failed$SKIP_NOTE"; exit 1; }
echo "test-rhizo-install: ok$SKIP_NOTE"
