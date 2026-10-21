#!/bin/bash
# test removing rhizo tokens from bootloader files
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOOT="$HERE/../bootstrap/bootstrap.sh"
TEARDOWN="$HERE/../teardown/teardown.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/sh\necho host\n' > "$TMP/host-mode-helper"; chmod +x "$TMP/host-mode-helper"
export RHIZO_SELINUX_MODE_HELPER="$TMP/host-mode-helper"
HOST_PATH=$PATH
FAILED=0 SKIPPED=0
# compare two values and print ok or FAIL
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; FAILED=$((FAILED + 1)); fi
}
# run check or count a skip
check_unprivileged() {
  if (( EUID != 0 )); then check "$@"; return; fi
  echo "SKIP $1 -- the suite runs as root, which no mode bit stops"
  SKIPPED=$((SKIPPED + 1))
}
# shellcheck source=fixtures/bootloader-fixtures.sh
. "$HERE/fixtures/bootloader-fixtures.sh"
link_bootstrap_tools "$TMP/tools"
mkdir -p "$TMP/pkgtools"
cat > "$TMP/pkgtools/dpkg-query" <<'STUB'
#!/bin/bash
[[ -s "$RHIZO_BL_ROOT/pkgs" ]] || exit 1
while read -r p; do echo "ii  $p"; done < "$RHIZO_BL_ROOT/pkgs"
echo "un  linux-headers-6.0-rhizo"
STUB
cat > "$TMP/pkgtools/pacman" <<'STUB'
#!/bin/bash
rc=0
for p in "${@:2}"; do if grep -qx "$p" "$RHIZO_BL_ROOT/pkgs" 2>/dev/null; then echo "$p"; else rc=1; fi; done
exit $rc
STUB
chmod +x "$TMP/pkgtools/dpkg-query" "$TMP/pkgtools/pacman"
P="[rhizo-host-teardown]"
NL=$'\n'
export RHIZO_BL_ROOT="$TMP/root"
R="$RHIZO_BL_ROOT"
CTOK="lsm=capability,landlock,lockdown,yama,selinux,bpf $TOKENS_MID $TOKENS_ANDROIDBOOT"
CTOK_SORTED=" $(tr ' ' '\n' <<<"$CTOK" | LC_ALL=C sort | paste -sd ' ')"
UTOK_SORTED=" $(tr ' ' '\n' <<<"$UBUNTU_TOKENS" | LC_ALL=C sort | paste -sd ' ')"
ANDROID_SORTED=" $(tr ' ' '\n' <<<"$TOKENS_ANDROIDBOOT" | LC_ALL=C sort | paste -sd ' ')"
GRUB_CMDS="/usr/sbin/update-grub or /usr/bin/grub-mkconfig -o /boot/grub/grub.cfg"

# print a function's definition from a file
lift() {
  awk -v f="$1" '$0 ~ "^" f "\\(\\) *\\{" { on = 1; print; if ($0 ~ /\} *$/) exit; next }
                 on { print } on && /^}/ { exit }' "$2"
}
STEP_TEXT=""
for f in log failstop mark_change contribution regen_choices report_left_tokens report_stranded_tokens \
         list_cmdline_tokens remove_cmdline_tokens regenerate_holders reboot_needed_for_lsm host_lsm_keeps_selinux \
         rhizo_tokens_carried note_enforcing_deferrals restore_default_entry namespace_install rhizo_kernel_packages \
         rhizo_kernel_note clear_host_labels teardown_mode_helper teardown_selinux_mode \
         teardown_helper_run teardown_own_context teardown_host_policy_state teardown_android_policy_loaded \
         host_labels_record host_labels_parse host_labels_restorecon host_labels_named host_labels_stop \
         print_host_labels; do
  body=$(lift "$f" "$TEARDOWN")
  [[ -n "$body" ]] || { echo "FAIL no $f() in $TEARDOWN"; exit 1; }
  STEP_TEXT+="$body$NL"
done
FLAVOR_DEF=$(grep -m1 '^FLAVOR=' "$TEARDOWN")
FINAL_TEXT=$(sed -n '/^if (( ! ANY_CHANGE )); then$/,$p' "$TEARDOWN")
[[ -n "$FLAVOR_DEF" && -n "$FINAL_TEXT" ]] \
  || { echo "FAIL no FLAVOR= line or final section in $TEARDOWN"; exit 1; }

# run code with the three libraries loaded
on_root() {
  (
    export RHIZO_OS_RELEASE="$R/etc/os-release"
    export PATH="${STEP_PATH:-$R/bin:$R/usr/sbin:$TMP/tools}${EXTRA_PATH:+:$EXTRA_PATH}"
    # shellcheck source=../lib/host-flavor.sh
    . "$HERE/../lib/host-flavor.sh"
    # shellcheck source=../bootstrap/bootloader.sh
    . "$HERE/../bootstrap/bootloader.sh"
    # shellcheck source=../teardown/teardown-lib.sh
    . "$HERE/../teardown/teardown-lib.sh"
    # shellcheck disable=SC2034
    PROG=rhizo-host-teardown ANY_CHANGE=0 REGEN_DEFERRED=() LEFT_CONFIGS=()
    eval "$FLAVOR_DEF"
    eval "$STEP_TEXT"
    # shellcheck disable=SC2317
    [[ -n "${KERNEL_QUERY_REAL:-}" ]] || rhizo_kernel_packages() { [[ ! -s "$R/pkgs" ]] || cat "$R/pkgs"; }
    # shellcheck disable=SC2317
    lsm_active() { cat "$R/sys/kernel/security/lsm" 2>/dev/null; }
    eval "$1"
  )
}

# run the teardown step and save its output
teardown_step() {
  rm -f "$TMP/deferred" "$TMP/changed" "$TMP/unit" "$TMP/final"
  # shellcheck disable=SC2016
  on_root 'remove_cmdline_tokens
           echo "${REGEN_DEFERRED[*]}" > "$TMP/deferred"; echo "$ANY_CHANGE" > "$TMP/changed"
           teardown_deferred_paths 0; teardown_final_cleanup_unit 0 > "$TMP/unit"
           ( eval "$FINAL_TEXT" ) > "$TMP/final" 2>&1; echo "rc=$?" >> "$TMP/final"' > "$TMP/out" 2> "$TMP/err"
  echo $? > "$TMP/rc"
}
OK_END="$P done; no reboot needed
RHIZO_TEARDOWN_OK removed=1
rc=0"
REBOOT_END="$P Rhizo's files are removed; SELinux is this boot's active LSM
$P AppArmor returns after a reboot
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
REBOOT_LIMINE_LEFT="$P Rhizo's files are removed; SELinux is this boot's active LSM
$P SELinux stays on until $R/boot/limine.conf is regenerated: install limine-update, then run /usr/bin/limine-update
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
REBOOT_DEFERRED="$P Rhizo's files are removed; SELinux is this boot's active LSM
$P SELinux turns off at the boot after next: the next boot regenerates the bootloader config
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
# write an lsm list that includes selinux
selinux_running() { echo capability,landlock,lockdown,yama,selinux,bpf > "$R/sys/kernel/security/lsm"; }
# list the cmdline tokens and save the results
verify_listing() { on_root list_cmdline_tokens > "$TMP/out" 2> "$TMP/err"; echo $? > "$TMP/rc"; }
# count the error lines equal to the text
has_line() { grep -cxF -- "$1" "$TMP/err"; }

# run a setup function in a subshell
fixture() { ( "$@" ) || { echo "FAIL setup $*"; exit 1; }; }
# build a fixture root from a setup
fixture_root() {
  rm -rf "$R" "$TMP/before"; mkdir -p "$R" "$TMP/before"
  fixture "$1" "$R"
  link_usr "$R"
}
# copy the given paths into a backup
keep() { local p; for p in "$@"; do mkdir -p "$TMP/before/${p%/*}"; cp -a "$R/$p" "$TMP/before/$p"; done; }
# print whether a fixture file matches its saved copy
same() { cmp -s "$TMP/before/$1" "$R/$1" && echo same || echo differs; }
# print whether a fixture file is present or gone
gone() { [[ -e "$R/$1" ]] && echo present || echo gone; }
# count the androidboot.hardware=rhizo tokens in a fixture file
rhizo_tokens_in() { grep -c 'androidboot.hardware=rhizo' "$R/$1"; }
# count the unit lines naming a given ExecStart
regen_lines() { grep -cxF "ExecStart=$1" "$TMP/unit"; }

ubuntu()     { add_ubuntu_host "$1"; }
# add a cachyos host with limine
limine()     { add_cachyos_host "$1"; }
# add a cachyos host with sdboot
sdboot()     { add_cachyos_host "$1" sdboot; }
# add a cachyos host with an inline grub cmdline
grub()       { add_cachyos_host "$1" grub_inline; }
# write a bare cachyos tree with an os-release
cachy_bare() { mkdir -p "$1/bin" "$1/etc"; printf 'ID=cachyos\n' > "$1/etc/os-release"; }
# write a bare arch tree with an os-release
arch_bare()  { mkdir -p "$1/bin" "$1/etc"; printf 'ID=arch\n' > "$1/etc/os-release"; }
# add an ubuntu host and set its version to 22.04
ubuntu2204() { add_ubuntu_host "$1"; sed -i 's/^VERSION_ID=.*/VERSION_ID="22.04"/' "$1/etc/os-release"; }
# add an Ubuntu host with loglevel=8 configured
ubuntu_own() { add_ubuntu_host "$1"; echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=8"' >> "$1/etc/default/grub"
               run_stub "$1/bin/update-grub"; : > "$1/calls"; }
# add a cachyos host whose limine cmdline carries its loglevel
limine_own() { add_cachyos_host "$1"
               limine_default "$1" "$LIMINE_ESP" "${LIMINE_BASE%\"} loglevel=8\"" "$LIMINE_ORDER"; }
# add a cachyos host whose sdboot options carry their loglevel
sdboot_own() { add_cachyos_host "$1" sdboot
               sed -i 's/^LINUX_OPTIONS=.*/LINUX_OPTIONS="nowatchdog quiet splash loglevel=8"/' \
                 "$1/etc/sdboot-manage.conf"
               run_stub "$1/bin/sdboot-manage" gen; : > "$1/calls"; }
# add a limine host with a kernel cmdline
limine_kcmd() { add_cachyos_host "$1"; mkdir -p "$1/etc/kernel"
                echo "$LIMINE_CMDLINE loglevel=8" > "$1/etc/kernel/cmdline"
                limine_default "$1" "$LIMINE_ESP" 'KERNEL_CMDLINE[default]=""' "$LIMINE_ORDER"; }

# install the Rhizo kernel beside the host's own
with_rhizo_kernel() {
  if [[ -x "$R/bin/update-grub" ]]; then
    touch "$R/boot/vmlinuz-7.1.0-rc1-rhizo"; run_stub "$R/bin/update-grub"
  else
    touch "$R/boot/vmlinuz-linux-rhizo" "$R/boot/initramfs-linux-rhizo.img"
    if [[ -x "$R/bin/limine-update" ]]; then run_stub "$R/bin/limine-update"
    elif [[ -x "$R/bin/sdboot-manage" ]]; then run_stub "$R/bin/sdboot-manage" gen
    else run_stub "$R/bin/grub-mkconfig" -o "$R/boot/grub/grub.cfg"; fi
  fi
  : > "$R/calls"
}
# run the bootstrap on a new fixture
installed() {
  fixture_root "$1"
  with_rhizo_kernel
  keep "${@:2}"
  boot_run "$R" "$TMP/tools" "$BOOT" > "$TMP/boot.out" 2>&1 \
    || { echo "FAIL bootstrap on $1: $(tail -3 "$TMP/boot.out")"; exit 1; }
  : > "$R/calls"
}
# apply tokens to a bootloader kind
lib_apply() {
  on_root "bootloader_apply $1 '${2:-$CTOK}' >/dev/null" || { echo "FAIL bootloader_apply $1"; exit 1; }
  : > "$R/calls"
}

installed ubuntu etc/default/grub boot/grub/grub.cfg
check "ubuntu installed: the drop-in is there" "$(gone etc/default/grub.d/90-rhizo.cfg)" present
teardown_step
check "ubuntu: rc"                              "$(< "$TMP/rc")" 0
check "ubuntu: stdout is update-grub's"         "$(< "$TMP/out")" "$P   Generating grub configuration file ..."
check "ubuntu: stderr word for word"            "$(< "$TMP/err")" "$P running update-grub
$P   removed: $R/etc/default/grub.d/90-rhizo.cfg, and regenerated $R/boot/grub/grub.cfg"
check "ubuntu: the drop-in is gone"             "$(gone etc/default/grub.d/90-rhizo.cfg)" gone
check "ubuntu: /etc/default/grub as before"     "$(same etc/default/grub)" same
check "ubuntu: grub.cfg as before the install"  "$(same boot/grub/grub.cfg)" same
check "ubuntu: grub.cfg carries no rhizo token" "$(rhizo_tokens_in boot/grub/grub.cfg)" 0
check "ubuntu: nothing deferred, the run ends OK" "$(< "$TMP/deferred")|$(< "$TMP/final")" "|$OK_END"
check "ubuntu: a change is counted"             "$(< "$TMP/changed")" 1

installed limine etc/default/limine boot/limine.conf
check "limine installed: the block is there"    "$(grep -c '^# >>> rhizo$' "$R/etc/default/limine")" 1
teardown_step
check "limine: rc"                              "$(< "$TMP/rc")" 0
check "limine: stdout is limine-update's"       "$(< "$TMP/out")" "$P   Updating limine.conf"
check "limine: stderr"                          "$(< "$TMP/err")" "$P running limine-update
$P   removed: rhizo's block in $R/etc/default/limine, and regenerated $R/boot/limine.conf"
check "limine: /etc/default/limine is its three lines again" "$(< "$R/etc/default/limine")" \
  "$LIMINE_ESP$NL$LIMINE_BASE$NL$LIMINE_ORDER"
check "limine: /etc/default/limine byte-identical" "$(same etc/default/limine)" same
check "limine: limine.conf as before the install" "$(same boot/limine.conf)" same
check "limine: the default entry boots the base" \
  "$(awk '$0 ~ /^ *\/\/linux-cachyos$/ {on = 1} on && /cmdline:/ {sub(/^ *cmdline: */, ""); print; exit}' \
     "$R/boot/limine.conf")" \
  "$LIMINE_CMDLINE"
check "limine: limine.conf carries no rhizo token" "$(rhizo_tokens_in boot/limine.conf)" 0
check "limine: nothing deferred"               "$(< "$TMP/deferred")" ""

installed sdboot etc/sdboot-manage.conf boot/loader/entries/linux-cachyos.conf
check "sdboot installed: the block is there"    "$(grep -c '^# >>> rhizo$' "$R/etc/sdboot-manage.conf")" 1
teardown_step
check "sdboot: rc"                              "$(< "$TMP/rc")" 0
check "sdboot: sdboot-manage gen prints nothing, and no empty line stands for it" "$(< "$TMP/out")" ""
check "sdboot: stderr"                          "$(< "$TMP/err")" "$P running sdboot-manage gen
$P   removed: rhizo's block in $R/etc/sdboot-manage.conf, and regenerated $R/boot/loader/entries"
check "sdboot: sdboot-manage.conf byte-identical" "$(same etc/sdboot-manage.conf)" same
check "sdboot: the entry as before the install" "$(same boot/loader/entries/linux-cachyos.conf)" same
check "sdboot: the entry carries no rhizo token" "$(rhizo_tokens_in boot/loader/entries/linux-cachyos.conf)" 0

installed grub etc/default/grub boot/grub/grub.cfg
check "grub without grub.d: no drop-in directory" "$(gone etc/default/grub.d)" gone
check "grub without grub.d installed: the block is there" "$(grep -c '^# >>> rhizo$' "$R/etc/default/grub")" 1
teardown_step
check "grub without grub.d: rc"                 "$(< "$TMP/rc")" 0
check "grub without grub.d: stderr"             "$(< "$TMP/err")" "$P running grub-mkconfig
$P   removed: rhizo's block in $R/etc/default/grub, and regenerated $R/boot/grub/grub.cfg"
check "grub without grub.d: /etc/default/grub byte-identical" "$(same etc/default/grub)" same
check "grub without grub.d: grub.cfg as before the install" "$(same boot/grub/grub.cfg)" same
check "grub without grub.d: grub.cfg carries no rhizo token" "$(rhizo_tokens_in boot/grub/grub.cfg)" 0

LLE_VAR=sys/firmware/efi/efivars/LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a
# add a namespace-mode cachyos limine host
limine_ns() { add_cachyos_host "$1"; touch "$1/boot/vmlinuz-linux-rhizo" "$1/boot/initramfs-linux-rhizo.img"
              run_stub "$1/bin/limine-update"; echo namespace > "$1/selinux-mode"; : > "$1/calls"; }
# add a namespace-mode ubuntu host
ubuntu_ns() { add_ubuntu_host "$1"; touch "$1/boot/vmlinuz-7.1.0-rc1-rhizo"; run_stub "$1/bin/update-grub"
              echo namespace > "$1/selinux-mode"; : > "$1/calls"; }
# run the namespace-mode teardown steps
ns_teardown_step() {
  rm -f "$TMP/final"
  # shellcheck disable=SC2016
  on_root 'INSTALL_RECORD="$R/var/lib/rhizo/.created-by-install" TEARDOWN_NS_INSTALL=1
           restore_default_entry; remove_cmdline_tokens
           ( eval "$FINAL_TEXT" ) > "$TMP/final" 2>&1; echo "rc=$?" >> "$TMP/final"' > "$TMP/out" 2> "$TMP/err"
  echo $? > "$TMP/rc"
}
NS_OK_END="$P done; selinux namespace mode needs no reboot
RHIZO_TEARDOWN_OK removed=1
rc=0"

installed limine_ns etc/default/limine
check "limine namespace installed: the Rhizo kernel is the remembered entry, the previous one recorded" \
  "$(tail -c +5 "$R/$LLE_VAR" | tr -d '\0')|$(grep '^rhizo-kernel-default ' "$R/var/lib/rhizo/.created-by-install")" \
  "CachyOS/linux-rhizo|rhizo-kernel-default CachyOS/linux-cachyos"
selinux_running
ns_teardown_step
check "limine namespace teardown: rc" "$(< "$TMP/rc")" 0
check "limine namespace teardown: the default entry put back, then the block removed" "$(< "$TMP/err")" \
  "$P   removed: the Rhizo kernel as the default boot entry; CachyOS/linux-cachyos is the default again
$P running limine-update
$P   removed: rhizo's block in $R/etc/default/limine, and regenerated $R/boot/limine.conf"
check "limine namespace teardown: LimineLastBootedEntry names the stock kernel" \
  "$(tail -c +5 "$R/$LLE_VAR" | tr -d '\0')" CachyOS/linux-cachyos
check "limine namespace teardown: the record line dropped" \
  "$(grep -c '^rhizo-kernel-default ' "$R/var/lib/rhizo/.created-by-install")" 0
check "limine namespace teardown: no android token on any entry" "$(rhizo_tokens_in boot/limine.conf)" 0
check "limine namespace teardown: /etc/default/limine byte-identical" "$(same etc/default/limine)" same
check "limine namespace teardown with the Rhizo kernel's selinux in the LSM list: no reboot asked" \
  "$(< "$TMP/final")" "$NS_OK_END"
installed limine etc/default/limine
check "limine host mode installed: the Rhizo kernel is the remembered entry, the previous one recorded" \
  "$(tail -c +5 "$R/$LLE_VAR" | tr -d '\0')|$(grep '^rhizo-kernel-default ' "$R/var/lib/rhizo/.created-by-install")" \
  "CachyOS/linux-rhizo|rhizo-kernel-default CachyOS/linux-cachyos"
# shellcheck disable=SC2016
on_root 'INSTALL_RECORD="$R/var/lib/rhizo/.created-by-install" restore_default_entry' > "$TMP/out" 2> "$TMP/err"
check "limine host mode teardown: the default entry put back" "$(< "$TMP/err")" \
  "$P   removed: the Rhizo kernel as the default boot entry; CachyOS/linux-cachyos is the default again"
check "limine host mode teardown: LimineLastBootedEntry names the stock kernel, the record line dropped" \
  "$(tail -c +5 "$R/$LLE_VAR" | tr -d '\0')|$(grep -c '^rhizo-kernel-default ' "$R/var/lib/rhizo/.created-by-install")" \
  "CachyOS/linux-cachyos|0"
selinux_running
check "the LSM verdict in host mode with selinux running still asks for the reboot" \
  "$(on_root 'TEARDOWN_NS_INSTALL=0; reboot_needed_for_lsm && echo reboot || echo none')" reboot

installed ubuntu_ns etc/default/grub
selinux_running
on_root '"$R/bin/grub-editenv" "$R/boot/grub/grubenv" set saved_entry=1'
ns_teardown_step
check "ubuntu namespace teardown with a saved entry the user chose: kept, said, the drop-in removed" \
  "$(< "$TMP/rc")|$(< "$TMP/err")|$(grep '^saved_entry=' "$R/boot/grub/grubenv")" \
  "0|$P   kept the default boot entry 1, chosen after the install
$P running update-grub
$P   removed: $R/etc/default/grub.d/90-rhizo.cfg, and regenerated $R/boot/grub/grub.cfg|saved_entry=1"
check "ubuntu namespace teardown: grub.cfg boots GRUB's own default again" \
  "$(grep -c 'set default' "$R/boot/grub/grub.cfg")|$(rhizo_tokens_in boot/grub/grub.cfg)" "0|0"
check "ubuntu namespace teardown: no reboot asked" "$(< "$TMP/final")" "$NS_OK_END"

UBU_KERNEL_PKGS="linux-headers-7.1.0-rc1-rhizo${NL}linux-headers-rhizo${NL}linux-image-7.1.0-rc1-rhizo${NL}linux-image-rhizo"
UBU_PURGE="'sudo apt purge linux-headers-7.1.0-rc1-rhizo linux-headers-rhizo linux-image-7.1.0-rc1-rhizo linux-image-rhizo'"
UBU_AUTOREMOVE="run no apt autoremove before that purge; it removes your older kernel"
PAC_LINE="$P the Rhizo kernel is installed: run 'sudo pacman -R \$(pacman -Qq linux-rhizo linux-rhizo-headers 2>/dev/null)', then reboot"
installed ubuntu_ns etc/default/grub
selinux_running
echo "$UBU_KERNEL_PKGS" > "$R/pkgs"
ns_teardown_step
check "ubuntu namespace teardown with the Rhizo kernel installed: the purge and the reboot, no autoremove before them" \
  "$(< "$TMP/final")" "$P the Rhizo kernel is installed: run $UBU_PURGE, then reboot
$P $UBU_AUTOREMOVE
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
installed ubuntu_ns etc/default/grub
selinux_running
sed -i "s/echo $UBUNTU_RELEASE/echo 7.1.0-rc1-rhizo/" "$R/bin/uname"
check "a teardown with nothing left to remove on the running Rhizo kernel: the reboot named, never clean" \
  "$(on_root 'INSTALL_RECORD="$R/var/lib/rhizo/.created-by-install" TEARDOWN_NS_INSTALL=1 ANY_CHANGE=0
              ( eval "$FINAL_TEXT" ) 2>&1; echo "rc=$?"')" "$P nothing found to remove
$P this boot runs the Rhizo kernel 7.1.0-rc1-rhizo; reboot to leave it
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
installed limine_ns etc/default/limine
selinux_running
printf 'linux-rhizo\nlinux-rhizo-headers\n' > "$R/pkgs"
ns_teardown_step
check "cachyos namespace teardown with the Rhizo kernel installed: the reboot and pacman's removal of what is left named" \
  "$(tail -4 "$TMP/final")" "$PAC_LINE
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
check "a host-mode teardown on a stock kernel with the Rhizo kernel installed: the purge after the LSM reboot" \
  "$(on_root 'TEARDOWN_NS_INSTALL=0 ANY_CHANGE=1; ( eval "$FINAL_TEXT" ) 2>&1' | tail -2)" "$PAC_LINE
RHIZO_TEARDOWN_REBOOT_REQUIRED=1"

E="$TMP/e2e"; mkdir -p "$E/bin" "$E/lib/install" "$E/state"
cat > "$E/bin/pacman" <<'STUB'
#!/bin/bash
case "$1" in
  -Qq)
    rc=0
    for p in "${@:2}"; do
      if grep -qx "$p" "$E_INSTALLED"; then echo "$p"; else echo "error: package '$p' was not found" >&2; rc=1; fi
    done
    exit "$rc" ;;
  -R*)
    shift; while [[ "${1:-}" == -* ]]; do shift; done
    (( $# )) || { echo "error: no targets specified (use -h for help)" >&2; exit 1; }
    for p in "$@"; do grep -qx "$p" "$E_INSTALLED" || { echo "error: target not found: $p" >&2; exit 1; }; done
    for p in "$@"; do sed -i "/^$p\$/d" "$E_INSTALLED"; done
    echo "removed $*" >> "$E_INSTALLED.log" ;;
esac
STUB
printf 'teardown\n' > "$E/lib/install/teardown/teardown.sh"; chmod +x "$E/bin/pacman" "$E/lib/install/teardown/teardown.sh"
printf 'ID=cachyos\n' > "$E/os-release"
export E_INSTALLED="$E/installed"
printf 'rhizo\nlinux-rhizo\nlinux-rhizo-headers\n' > "$E_INSTALLED"
note=$(KERNEL_QUERY_REAL=1 EXTRA_PATH="$E/bin" on_root 'FLAVOR=cachyos; rhizo_kernel_note' 2>&1)
cmd=$(sed -n "s/^.* '\(sudo pacman -R .*\)', then reboot$/\1/p" <<<"$note")
out=$( ( export RHIZO_LIB_DIR="$E/lib" RHIZO_STATE_DIR="$E/state" RHIZO_OS_RELEASE="$E/os-release" RHIZO_CLI_SOURCE_ONLY=1
         source "$HERE/../cli/rhizo.sh"; PATH="$E/bin:$PATH"; RHIZO_ASSUME_YES=1 cmd_uninstall ) 2>&1 </dev/null ); rc=$?
check "the note on cachyos, taken while rhizo is installed, gives the -Qq removal line" \
  "$(tail -2 <<<"$note")" "$PAC_LINE"
check "rhizo uninstall on cachyos, its teardown's note taken while every package is installed: pacman removes rhizo" \
  "$rc|$(cat "$E_INSTALLED.log")" "0|removed rhizo"
out=$(PATH="$E/bin:$PATH" bash -c "${cmd#sudo }" 2>&1); rc=$?
check "after rhizo uninstall, the note's pacman command removes what is left of the Rhizo kernel" \
  "$rc|$out|$(tail -1 "$E_INSTALLED.log")|$(wc -c < "$E_INSTALLED")" "0||removed linux-rhizo linux-rhizo-headers|0"

echo "$UBU_KERNEL_PKGS" > "$R/pkgs"
check "the kernel query on ubuntu lists the installed Rhizo packages through dpkg-query" \
  "$(KERNEL_QUERY_REAL=1 EXTRA_PATH="$TMP/pkgtools" on_root 'FLAVOR=ubuntu; rhizo_kernel_packages; echo "rc=$?"')" \
  "$UBU_KERNEL_PKGS${NL}rc=0"
printf 'linux-rhizo\n' > "$R/pkgs"
check "the kernel query on cachyos lists what pacman holds" \
  "$(KERNEL_QUERY_REAL=1 EXTRA_PATH="$TMP/pkgtools" on_root 'FLAVOR=cachyos; rhizo_kernel_packages; echo "rc=$?"')" \
  "linux-rhizo${NL}rc=0"
check "the kernel query with no package tool: cannot tell, named" \
  "$(KERNEL_QUERY_REAL=1 on_root 'FLAVOR=ubuntu; rhizo_kernel_packages 2>&1; echo "rc=$?"')" \
  "no dpkg-query to list the installed kernels${NL}rc=2"
rm "$R/pkgs"

REC_FILE="$TMP/ns-record"
# print namespace_install's answer for a record and a boot mode file
ns_answer() { on_root "INSTALL_RECORD=$REC_FILE TEARDOWN_SELINUX_MODE_FILE=$TMP/ns-mode-file
                      TEARDOWN_ANDROIDD_ENV=/etc/rhizo/androidd.env
                      namespace_install && echo namespace || echo host"; }
# print the LSM reboot answer for a record and a boot mode file
lsm_answer() { on_root "INSTALL_RECORD=$REC_FILE TEARDOWN_SELINUX_MODE_FILE=$TMP/ns-mode-file
                       TEARDOWN_ANDROIDD_ENV=/etc/rhizo/androidd.env TEARDOWN_NS_INSTALL=0; namespace_install && TEARDOWN_NS_INSTALL=1
                       reboot_needed_for_lsm && echo reboot || echo none"; }
selinux_running
printf 'group:rhizo\nselinux-mode namespace\n' > "$REC_FILE"; rm -f "$TMP/ns-mode-file"
check "a namespace-mode install: no LSM reboot with the Rhizo kernel's selinux active" "$(ns_answer)|$(lsm_answer)" \
  "namespace|none"
printf 'group:rhizo\n' > "$REC_FILE"; echo host > "$TMP/ns-mode-file"
check "switched back to host mode, the record's line dropped: the LSM reboot asked" "$(ns_answer)|$(lsm_answer)" \
  "host|reboot"
echo namespace > "$TMP/ns-mode-file"
check "switched to namespace mode on this boot before the record says so: no LSM reboot" \
  "$(ns_answer)|$(lsm_answer)" "namespace|none"
# write a mode helper fixture
mode_helper_fixture() {
  if [[ -n "$1" ]]; then
    printf '#!/bin/sh\necho "$@" > "%s/td-helper-argv"\necho %s\n' "$TMP" "$1" > "$TMP/td-helper"
  else
    printf '#!/bin/sh\nexit 3\n' > "$TMP/td-helper"
  fi
  chmod +x "$TMP/td-helper"
}
printf 'group:rhizo\n' > "$REC_FILE"; rm -rf "$TMP/ns-mode-file"
mode_helper_fixture namespace
check "no record line and no boot record: the configured namespace mode, through the helper" \
  "$(RHIZO_SELINUX_MODE_HELPER=$TMP/td-helper ns_answer)|$(cat "$TMP/td-helper-argv")" \
  "namespace|--env-file /etc/rhizo/androidd.env --configured"
mode_helper_fixture host
check "no record line and no boot record: the configured host mode, through the helper" \
  "$(RHIZO_SELINUX_MODE_HELPER=$TMP/td-helper ns_answer)" "host"
mode_helper_fixture ""
check "no record line, no boot record and a failing helper: a named failure, never host" \
  "$(RHIZO_SELINUX_MODE_HELPER=$TMP/td-helper ns_answer 2>&1 | tail -1)" "RHIZO_TEARDOWN_FAILED reason=selinux-mode-unreadable"
mkdir -p "$TMP/ns-mode-file"; mode_helper_fixture host
check "an unreadable boot record: a named failure, never host" \
  "$(RHIZO_SELINUX_MODE_HELPER=$TMP/td-helper ns_answer 2>&1 | tail -1)" "RHIZO_TEARDOWN_FAILED reason=selinux-mode-unreadable"
rm -rf "$TMP/ns-mode-file"

# print clear_host_labels' result for a planted scan
labels_answer() {
  printf '%s\0' "$1" > "$TMP/labels-attr"; echo "$2" > "$TMP/labels-enforce"; echo "$3" > "$TMP/labels-mode"
  echo pending > "$TMP/labels-pending"
  on_root "TEARDOWN_SELINUX_ENFORCE=$TMP/labels-enforce TEARDOWN_ATTR_CURRENT=$TMP/labels-attr
           TEARDOWN_SELINUX_MODE_FILE=$TMP/labels-mode HOST_LABELS_PENDING=$TMP/labels-pending
           selinux_xattr_report() { echo \"scan \$1\" >> $TMP/labels-scans; printf '%s\n' '$5'; return $4; }
           ( clear_host_labels ) 2>&1; echo \"rc=\$?\""
  echo "record=$(tr '\n' '|' < "$TMP/labels-pending" 2>/dev/null || echo gone)"
}
SYS_CTX="system_u:system_r:init_t:s0"
: > "$TMP/labels-scans"
check "no policy loaded: the labels are stripped and the record dropped" \
  "$(labels_answer kernel "" namespace 0 'cleared: /usr/sbin/sshd')|$(tr '\n' ' ' < "$TMP/labels-scans")" \
  "$P   cleared: /usr/sbin/sshd${NL}RHIZO_TEARDOWN_HOST_LABELS_CLEARED=1${NL}rc=0${NL}record=gone|scan clear "
check "no SELinux at all: the labels are stripped" \
  "$(labels_answer "" "" namespace 0 'cleared: /usr/sbin/sshd' | tail -3)" \
  "RHIZO_TEARDOWN_HOST_LABELS_CLEARED=1${NL}rc=0${NL}record=gone"
check "a strip that fails with no policy loaded: failed by name, the record kept for the next boot" \
  "$(labels_answer kernel "" namespace 1 "FAILED: /usr/sbin/sshd ([Errno 95] Operation not supported: x)" | tail -3)" \
  "RHIZO_TEARDOWN_HOST_LABELS_FAILED reason=host-labels-clear-failed${NL}rc=1${NL}record=failed host-labels-clear-failed|\
removing a rhizo_host label failed: /usr/sbin/sshd ([Errno 95] Operation not supported: x); the next boot retries|"
check "a scan that crashes naming no file: failed by cause" \
  "$(labels_answer kernel "" namespace 1 "" | grep -c 'the label scan exited 1; the next boot retries')" 2
: > "$TMP/labels-scans"
for enforce in 0 1; do
  check "Android's policy loaded host-wide (enforce=$enforce): refused by name, nothing scanned or stripped" \
    "$(labels_answer u:r:rhizo_host:s0 "$enforce" namespace 0 x | tail -2)|$(wc -l < "$TMP/labels-scans")" \
    "rc=1${NL}record=refused android-policy-loaded|Android's policy is loaded host-wide on this boot;\
 the next boot removes the labels||0"
done
check "the host's own enforcing policy with host labels: refused, naming the files and the restorecon command" \
  "$(labels_answer "$SYS_CTX" 1 namespace 0 "labeled: /usr/sbin/sshd${NL}labeled: /usr/bin/bash${NL}labeled-modules: 12 /usr/lib/modules" \
     | tail -3)|$(tr '\n' ' ' < "$TMP/labels-scans")" \
  "RHIZO_TEARDOWN_HOST_LABELS_REFUSED reason=host-policy-loaded${NL}rc=1${NL}record=refused host-policy-loaded|the \
host SELinux policy is enforcing and host mode's label is on \
/usr/sbin/sshd /usr/bin/bash and 12 files under /usr/lib/modules: run 'sudo restorecon \
-F /usr/sbin/sshd /usr/bin/bash && sudo restorecon -RF /usr/lib/modules'||scan list "
: > "$TMP/labels-scans"
check "the host's own permissive policy with no host label: the record dropped, nothing stripped" \
  "$(labels_answer "$SYS_CTX" 0 namespace 0 "" | tail -3)|$(tr '\n' ' ' < "$TMP/labels-scans")" \
  "RHIZO_TEARDOWN_HOST_LABELS_CLEARED=1${NL}rc=0${NL}record=gone|scan list "
check "a policy loaded with an unreadable enforce node: failed by name" \
  "$(labels_answer "$SYS_CTX" x namespace 0 "" | tail -3 | head -1)" "RHIZO_TEARDOWN_HOST_LABELS_FAILED reason=host-state-unknown"
: > "$TMP/labels-scans"
# print print_host_labels' output for a planted scan
labels_listing() {
  on_root "selinux_xattr_report() { [[ \$1 == list ]] || exit 7; printf '%s' '$2'; return $1; }
           ( print_host_labels ) 2>&1; echo \"rc=\$?\""
}
check "the label listing with labels: the lines, the named files, the restorecon command and labeled=1" \
  "$(labels_listing 0 "labeled: /usr/sbin/sshd${NL}labeled-modules: 3 /usr/lib/modules")" \
  "labeled: /usr/sbin/sshd${NL}labeled-modules: 3 /usr/lib/modules${NL}files: /usr/sbin/sshd and 3 files under /usr/lib/modules
command: sudo restorecon -F /usr/sbin/sshd && sudo restorecon -RF /usr/lib/modules${NL}RHIZO_TEARDOWN_HOST_LABELS labeled=1${NL}rc=0"
check "the label listing with no labels: labeled=0" "$(labels_listing 0 "")" "RHIZO_TEARDOWN_HOST_LABELS labeled=0${NL}rc=0"
check "a label scan that fails: failed by cause" "$(labels_listing 1 "" | tail -2)" \
  "RHIZO_TEARDOWN_FAILED reason=label-scan-failed${NL}rc=1"
check "host mode configured: refused, the labels left to host mode" \
  "$(labels_answer kernel "" host 0 x | tail -3 | head -1)|$(wc -l < "$TMP/labels-scans")" \
  "RHIZO_TEARDOWN_HOST_LABELS_REFUSED reason=host-mode|0"

installed ubuntu
selinux_running
teardown_step
check "ubuntu with selinux running: the reboot notice, word for word" "$(< "$TMP/final")" "$REBOOT_END"
# add a limine host with selinux in lsm=
limine_lsm_selinux() { add_cachyos_host "$1"
                       limine_default "$1" "$LIMINE_ESP" \
                         "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE lsm=landlock,lockdown,yama,selinux,bpf\"" \
                         "$LIMINE_ORDER"; }
installed limine_lsm_selinux
selinux_running
teardown_step
check "cachyos whose own lsm= keeps selinux: the notice says SELinux stays after a reboot" "$(< "$TMP/final")" \
  "$P Rhizo's files are removed; SELinux is this boot's active LSM
$P SELinux stays on after a reboot: the host's lsm=landlock,lockdown,yama,selinux,bpf on the next boot's cmdline\
 makes selinux the major LSM
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
LTOK="lsm=capability,landlock,lockdown,yama,selinux,bpf $TOKENS_MID $TOKENS_ANDROIDBOOT"
fixture_root limine
lib_apply limine "$LTOK"
selinux_running
: > "$R/regen-fails"
teardown_step
rm "$R/regen-fails"
check "limine with rhizo's lsm= list, limine-update failing: deferred" "$(< "$TMP/deferred")" limine
check "limine with rhizo's lsm= list, limine-update failing: the deferred notice" "$(< "$TMP/final")" \
  "$REBOOT_DEFERRED"
fixture_root limine
lib_apply limine "$LTOK"
rm "$R/bin/limine-update"
selinux_running
RHIZO_BOOTLOADER=limine teardown_step
check "limine with rhizo's lsm= list and no limine-update: it stays until limine.conf is regenerated" \
  "$(< "$TMP/final")" "$REBOOT_LIMINE_LEFT"
fixture_root limine_lsm_selinux
lib_apply limine
selinux_running
: > "$R/regen-fails"
teardown_step
rm "$R/regen-fails"
check "limine-update failing on a host whose own lsm= keeps selinux: deferred" "$(< "$TMP/deferred")" limine
check "limine-update failing on a host whose own lsm= keeps selinux: the notice says SELinux stays" \
  "$(< "$TMP/final")" "$P Rhizo's files are removed; SELinux is this boot's active LSM
$P SELinux stays on after a reboot: the host's lsm=landlock,lockdown,yama,selinux,bpf on the next boot's cmdline\
 makes selinux the major LSM
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
# add a limine host with rhizo's lsm= list
limine_lsm_same() { add_cachyos_host "$1"
                    limine_default "$1" "$LIMINE_ESP" \
                      "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE ${LTOK%% *}\"" "$LIMINE_ORDER"; }
fixture_root limine_lsm_same
lib_apply limine "$LTOK"
selinux_running
teardown_step
check "a host lsm= the same as rhizo's: the notice says SELinux stays after a reboot" "$(< "$TMP/final")" \
  "$P Rhizo's files are removed; SELinux is this boot's active LSM
$P SELinux stays on after a reboot: the host's ${LTOK%% *} on the next boot's cmdline\
 makes selinux the major LSM
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
CANNOT_TELL="$P Rhizo's files are removed; SELinux is this boot's active LSM
$P the next boot's cmdlines cannot be read (see above)
RHIZO_TEARDOWN_REBOOT_REQUIRED=1"
# run $1 and FINAL_TEXT in on_root
step_then_final() {
  # shellcheck disable=SC2016
  on_root "remove_cmdline_tokens; $1"'; ( eval "$FINAL_TEXT" ) > "$TMP/final" 2>&1' > "$TMP/out" 2> "$TMP/err"
}
fixture_root limine
lib_apply limine
selinux_running
# shellcheck disable=SC2016
step_then_final 'chmod 000 "$R/boot/limine.conf"'
chmod 644 "$R/boot/limine.conf"
check_unprivileged "a limine.conf this uid cannot read at the notice: whether selinux leaves cannot be told" \
  "$(< "$TMP/final")" "${CANNOT_TELL%%"$NL$P the next"*}
cannot read $R/boot/limine.conf as uid $EUID
${CANNOT_TELL#*"active LSM$NL"}"
fixture_root limine
mkdir -p "$R/etc/limine-entry-tool.d"; echo 'TIMEOUT=3' > "$R/etc/limine-entry-tool.d/50-local.conf"
lib_apply limine
selinux_running
# shellcheck disable=SC2016
step_then_final 'chmod 000 "$R/etc/limine-entry-tool.d"'
chmod 755 "$R/etc/limine-entry-tool.d"
check_unprivileged "a limine-entry-tool.d this uid cannot read at the notice: whether selinux leaves cannot be told" \
  "$(< "$TMP/final")" "${CANNOT_TELL%%"$NL$P the next"*}
cannot read $R/etc/limine-entry-tool.d as uid $EUID
${CANNOT_TELL#*"active LSM$NL"}"
fixture_root limine
lib_apply limine
selinux_running
step_then_final 'awk() { echo "awk: read error" >&2; return 2; }'
check "a limine.conf whose read fails at the notice: whether selinux leaves cannot be told" "$(< "$TMP/final")" \
  "${CANNOT_TELL%%"$NL$P the next"*}
awk: read error
${CANNOT_TELL#*"active LSM$NL"}"
fixture_root limine
lib_apply limine
selinux_running
: > "$R/regen-fails"
step_then_final 'awk() { echo "awk: read error" >&2; return 2; }'
rm "$R/regen-fails"
check "a deferred regeneration and a read that fails at the notice: it stays at the next boot, then cannot be told" \
  "$(< "$TMP/final")" "${CANNOT_TELL%%"$NL$P the next"*}
awk: read error
$P SELinux stays on at the next boot, which regenerates the bootloader config; its cmdlines cannot be read (see above)
RHIZO_TEARDOWN_REBOOT_REQUIRED=1"
fixture_root limine
lib_apply limine
on_root 'bootloader_strip limine' || { echo "FAIL bootloader_strip limine on $R"; exit 1; }
selinux_running
step_then_final 'ANY_CHANGE=1'
check "limine.conf still carrying rhizo's tokens, limine-update installed: it stays until limine.conf is regenerated" \
  "$(< "$TMP/final")" "${CANNOT_TELL%%"$NL$P the next"*}
$P SELinux stays on until $R/boot/limine.conf is regenerated (it carries:$ANDROID_SORTED): run /usr/bin/limine-update
RHIZO_TEARDOWN_REBOOT_REQUIRED=1"

installed ubuntu_own etc/default/grub boot/grub/grub.cfg
check "ubuntu with loglevel=8 of its own: installed grub.cfg carries it twice on each of its two kernel entries" \
  "$(grep -o 'loglevel=8' "$R/boot/grub/grub.cfg" | grep -c '')" 4
teardown_step
check "ubuntu with loglevel=8 of its own: the base's output, word for word" \
  "$(< "$TMP/rc")|$(< "$TMP/out")|$(< "$TMP/err")" \
  "0|$P   Generating grub configuration file ...|$P running update-grub
$P   removed: $R/etc/default/grub.d/90-rhizo.cfg, and regenerated $R/boot/grub/grub.cfg"
check "ubuntu with loglevel=8 of its own: nothing deferred, so no unit, and the run ends OK" \
  "$(< "$TMP/deferred")|$(< "$TMP/final")" "|$OK_END"
check "ubuntu with loglevel=8 of its own: grub.cfg as before the install" "$(same boot/grub/grub.cfg)" same

# add an Ubuntu host with a 40_custom entry
ubuntu_custom() { add_ubuntu_host "$1"; mkdir -p "$1/etc/grub.d"
                  printf '%s\n' 'menuentry "custom" {' '	linux /vmlinuz-custom root=UUID=abc ro loglevel=8' '}' \
                    > "$1/etc/grub.d/40_custom"
                  run_stub "$1/bin/update-grub"; : > "$1/calls"; }
installed ubuntu_custom etc/default/grub boot/grub/grub.cfg
teardown_step
check "ubuntu with a 40_custom entry carrying loglevel=8: the base's output, word for word" \
  "$(< "$TMP/rc")|$(< "$TMP/out")|$(< "$TMP/err")" \
  "0|$P   Generating grub configuration file ...|$P running update-grub
$P   removed: $R/etc/default/grub.d/90-rhizo.cfg, and regenerated $R/boot/grub/grub.cfg"
check "ubuntu with a 40_custom entry: nothing deferred, so no unit" "$(< "$TMP/deferred")" ""
check "ubuntu with a 40_custom entry: grub.cfg as before the install" "$(same boot/grub/grub.cfg)" same

for own in limine_own sdboot_own; do
  case "$own" in
    limine_own) installed "$own" etc/default/limine boot/limine.conf ;;
    sdboot_own) installed "$own" etc/sdboot-manage.conf boot/loader/entries/linux-cachyos.conf ;;
  esac
  teardown_step
  check "$own: no WARNING"                      "$(grep -c WARNING "$TMP/err")" 0
  check "$own: regenerated"                     "$(grep -c ', and regenerated ' "$TMP/err")" 1
  check "$own: nothing deferred"                "$(< "$TMP/deferred")" ""
done

fixture_root limine_kcmd
keep etc/default/limine boot/limine.conf
lib_apply limine
teardown_step
check "limine with /etc/kernel/cmdline's loglevel=8: no WARNING" "$(grep -c WARNING "$TMP/err")" 0
check "limine with /etc/kernel/cmdline's loglevel=8: nothing deferred" "$(< "$TMP/deferred")" ""
check "limine with /etc/kernel/cmdline's loglevel=8: limine.conf as before" "$(same boot/limine.conf)" same

# add a limine host with loglevel=8 appended
limine_line_own() { add_cachyos_host "$1"
                    limine_default "$1" "$LIMINE_ESP" "$LIMINE_BASE" 'KERNEL_CMDLINE[default]+=quiet loglevel=8' \
                      "$LIMINE_ORDER"; }
installed limine_line_own etc/default/limine boot/limine.conf
check "limine with an unquoted += line's loglevel=8: installed limine.conf carries it twice on each of its two kernel entries" \
  "$(grep -o 'loglevel=8' "$R/boot/limine.conf" | grep -c '')" 4
teardown_step
check "limine with an unquoted += line's loglevel=8: no WARNING" "$(grep -c WARNING "$TMP/err")" 0
check "limine with an unquoted += line's loglevel=8: regenerated" "$(grep -c ', and regenerated ' "$TMP/err")" 1
check "limine with an unquoted += line's loglevel=8: nothing deferred" "$(< "$TMP/deferred")" ""
check "limine with an unquoted += line's loglevel=8: limine.conf as before" "$(same boot/limine.conf)" same
# add a limine host with a loglevel=8 drop-in
limine_dropin_replaced() { add_cachyos_host "$1"; mkdir -p "$1/etc/limine-entry-tool.d"
                           echo 'KERNEL_CMDLINE[default]+=quiet loglevel=8' \
                             > "$1/etc/limine-entry-tool.d/50-local.conf"
                           run_stub "$1/bin/limine-update"; : > "$1/calls"; }
installed limine_dropin_replaced etc/default/limine boot/limine.conf
check "limine with a drop-in's loglevel=8 the base replaces: installed limine.conf carries rhizo's alone on each of its two kernel entries" \
  "$(grep -o 'loglevel=8' "$R/boot/limine.conf" | grep -c '')" 2
stub "$R/bin/limine-update" <<<'echo "Updating limine.conf" >&2'
teardown_step
check "limine-update leaving the tokens, a drop-in's loglevel=8 the base replaces: named among rhizo's" \
  "$(has_line "$P   WARNING: limine-update ran but $R/boot/limine.conf carries:$CTOK_SORTED;\
 the next boot runs limine-update again")" 1

installed ubuntu_own etc/default/grub
echo 'GRUB_TIMEOUT=3' > "$R/etc/default/grub.d/50-local.cfg"
chmod 000 "$R/etc/default/grub.d/50-local.cfg"
teardown_step
chmod 644 "$R/etc/default/grub.d/50-local.cfg"
check_unprivileged "an unreadable grub.d file: the token stays flagged, by name" \
  "$(has_line "$P   WARNING: update-grub ran but \
$R/boot/grub/grub.cfg carries: loglevel=8 (see above);\
 the next boot runs update-grub again")" 1
check_unprivileged "an unreadable grub.d file: the file is named" \
  "$(has_line "cannot read $R/etc/default/grub.d/50-local.cfg")" 1
check_unprivileged "an unreadable grub.d file: deferred"     "$(< "$TMP/deferred")" grub-dropin

READS_RHIZO="/usr/lib/rhizo|rhizo-(bootloader|host-flavor|teardown-lib)|bootloader_|host_|(^|[ ;'])(\\.|source) "
# test teardown with a failing regeneration
regen_fails() {
  installed "$1" "$3"
  : > "$R/regen-fails"
  teardown_step
  check "$2 regeneration failing: rc"           "$(< "$TMP/rc")" 0
  check "$2 regeneration failing: the edited file as before the install" "$(same "$3")" same
  check "$2 regeneration failing: deferred"     "$(< "$TMP/deferred")" "$2"
  check "$2 regeneration failing: one literal ExecStart=$4" "$(regen_lines "$4")" 1
  check "$2 regeneration failing: no unit line but the removal names rhizo's files or functions" \
    "$(grep -v "^ExecStart=/bin/sh -c 'rm -rf " "$TMP/unit" | grep -cE "$READS_RHIZO")" 0
}
regen_fails ubuntu grub-dropin etc/default/grub /usr/sbin/update-grub
check "grub-dropin regeneration failing: stderr word for word" "$(< "$TMP/err")" "$P running update-grub
regeneration failed
$P   WARNING: update-grub failed after removing $R/etc/default/grub.d/90-rhizo.cfg;\
 the next boot runs it again
$P   removed: $R/etc/default/grub.d/90-rhizo.cfg (grub.cfg regenerates on the next boot)"
check "grub-dropin regeneration failing: the drop-in is gone" "$(gone etc/default/grub.d/90-rhizo.cfg)" gone
regen_fails limine limine etc/default/limine /usr/bin/limine-update
check "limine regeneration failing: says so"   "$(has_line "$P   WARNING: limine-update failed after removing rhizo's\
 block in $R/etc/default/limine; the next boot runs it again")" 1
check "cachyos's unit has no dpkg line"        "$(grep -c 'dpkg' "$TMP/unit")" 0
regen_fails sdboot sdboot etc/sdboot-manage.conf "/usr/bin/sdboot-manage gen"
regen_fails grub grub-inline etc/default/grub "/usr/bin/grub-mkconfig -o /boot/grub/grub.cfg"

installed limine_own etc/default/limine
stub "$R/bin/limine-update" <<<'echo "Updating limine.conf" >&2'
teardown_step
check "limine-update leaving the tokens: deferred" "$(< "$TMP/deferred")" limine
check "limine-update leaving the tokens: names rhizo's, not the host's loglevel=8" \
  "$(has_line "$P   WARNING: limine-update ran but $R/boot/limine.conf carries:${CTOK_SORTED/ loglevel=8/};\
 the next boot runs limine-update again")" 1
check "limine-update leaving the tokens: not reported as regenerated" "$(grep -c 'and regenerated' "$TMP/err")" 0
check "limine-update leaving the tokens: the block is still taken out" "$(same etc/default/limine)" same

installed limine etc/default/limine
# shellcheck disable=SC2016
printf '%s\n' "$(< "$R/bin/limine-update")" 'chmod 000 "$RHIZO_BL_ROOT/boot/limine.conf"' > "$R/bin/limine-update.new"
mv "$R/bin/limine-update.new" "$R/bin/limine-update"; chmod +x "$R/bin/limine-update"
teardown_step
chmod 644 "$R/boot/limine.conf"
check_unprivileged "an unreadable limine.conf after limine-update: deferred" "$(< "$TMP/deferred")" limine
check_unprivileged "an unreadable limine.conf after limine-update: says so" \
  "$(has_line "$P   WARNING: cannot read the cmdlines in\
 $R/boot/limine.conf after limine-update; the next boot runs limine-update again")" 1

installed ubuntu etc/default/grub boot/grub/grub.cfg
on_root "bootloader_write grub-inline '$UBUNTU_TOKENS'" || { echo "FAIL a grub block on $R"; exit 1; }
run_stub "$R/bin/update-grub"; : > "$R/calls"
teardown_step
check "drop-in and grub block: one update-grub" "$(ncalls "$R" update-grub)" 1
check "drop-in and grub block: stderr"          "$(< "$TMP/err")" "$P   NOTE: removing rhizo's tokens from $R/etc/default/grub;\
 grub-dropin boots this host
$P running update-grub
$P   removed: $R/etc/default/grub.d/90-rhizo.cfg, and regenerated $R/boot/grub/grub.cfg
$P   removed: rhizo's block in $R/etc/default/grub, and regenerated $R/boot/grub/grub.cfg"
check "drop-in and grub block: /etc/default/grub as before" "$(same etc/default/grub)" same
check "drop-in and grub block: grub.cfg as before the install" "$(same boot/grub/grub.cfg)" same
check "drop-in and grub block: nothing deferred" "$(< "$TMP/deferred")" ""

installed ubuntu
on_root "bootloader_write grub-inline '$UBUNTU_TOKENS'" || { echo "FAIL a grub block on $R"; exit 1; }
run_stub "$R/bin/update-grub"
stub "$R/bin/update-grub" <<<'echo "Generating grub configuration file ..." >&2'
teardown_step
check "two holders, tokens left: each named once" "$(has_line "$P   WARNING: update-grub ran but\
 $R/boot/grub/grub.cfg carries:$UTOK_SORTED; the next boot runs update-grub again")" 1

# write rhizo's block into /etc/default/grub
grub_block() {
  printf 'GRUB_CMDLINE_LINUX=""\n' > "$R/etc/default/grub"
  keep etc/default/grub
  on_root "bootloader_write grub-inline '$CTOK'" || { echo "FAIL a grub block on $R"; exit 1; }
}
# write a grub.cfg that holds a rhizo token
leftover_grub_cfg() { mkdir -p "$R/boot/grub"
                   echo "linux /vmlinuz-linux-cachyos root=UUID=abc rw $CTOK" > "$R/boot/grub/grub.cfg"; }
installed limine etc/default/limine boot/limine.conf
grub_block
leftover_grub_cfg
selinux_running
: > "$R/regen-fails"
teardown_step
rm "$R/regen-fails"
check "a leftover grub holder: rc"                 "$(< "$TMP/rc")" 0
check "a leftover grub holder: named"              "$(has_line "$P   NOTE: removing rhizo's tokens from $R/etc/default/grub;\
 limine boots this host")" 1
check "a leftover grub holder: its block is gone"  "$(same etc/default/grub)" same
check "a leftover grub holder: the file and the tokens named, and that this host does not boot through it" \
  "$(has_line "$P   WARNING: left $R/boot/grub/grub.cfg (carries:$CTOK_SORTED);\
 limine boots this host")" 1
check "a leftover grub holder: no advice to install grub" "$(grep -c 'is installed' "$TMP/err")" 0
check "a leftover grub holder: the run keeps its status, CachyOS's reboot notice with limine's regeneration deferred" \
  "$(< "$TMP/final")" "$REBOOT_DEFERRED"
check "a leftover grub holder: limine's failed regeneration is deferred, grub's is not" "$(< "$TMP/deferred")" limine
check "no unit carries a regenerator that is not installed" "$(grep -cE 'update-grub|grub-mkconfig' "$TMP/unit")" 0
check "the unit carries the installed one"      "$(regen_lines /usr/bin/limine-update)" 1
check "a leftover grub holder: limine's block is gone too" "$(same etc/default/limine)" same

teardown_step
check "the next run: names them again"          "$(has_line "$P   WARNING: left $R/boot/grub/grub.cfg (carries:\
$ANDROID_SORTED); limine boots this host")" 1
check "the next run: its status unchanged by them" "$(tail -2 "$TMP/final")" "RHIZO_TEARDOWN_ALREADY_CLEAN=1${NL}rc=0"
verify_listing
check "--verify names them, and they leave the host clean" "$(< "$TMP/rc")|$(< "$TMP/err")" \
  "0|$P   bootloader tokens: absent
$P   bootloader tokens: left in $R/boot/grub/grub.cfg (carries:$ANDROID_SORTED);\
 limine boots this host"

fixture_root cachy_bare
mkdir -p "$R/etc/default"
grub_block
leftover_grub_cfg
teardown_step
check "no bootloader detected: says why, naming the command /etc/default/grub has none of" \
  "$(has_line "$P   WARNING: cannot detect the bootloader ($R/etc/default/grub is there, but no\
 grub-mkconfig is in any of $R/usr/bin, $R/usr/sbin, $R/bin, $R/sbin, $R/usr/local/sbin, $R/usr/local/bin to regenerate\
 its config -- install it); removing rhizo's tokens from every bootloader file")" 1
check "no bootloader detected: the tool, the file, the tokens and the command named" \
  "$(has_line "$P   WARNING: $R/boot/grub/grub.cfg (carries:$CTOK_SORTED); install update-grub or grub-mkconfig,\
 then run $GRUB_CMDS")" 1
check "no bootloader detected: the run keeps its status" "$(< "$TMP/final")" "$OK_END"
check "no bootloader detected: nothing deferred" "$(< "$TMP/deferred")" ""
check "no bootloader detected: its block is gone" "$(same etc/default/grub)" same
fixture_root cachy_bare
mkdir -p "$R/etc/default" "$R/sys/kernel/security"
grub_block
leftover_grub_cfg
selinux_running
teardown_step
check "no bootloader detected, selinux running: it stays until grub.cfg is regenerated, the command named" \
  "$(< "$TMP/final")" "$P Rhizo's files are removed; SELinux is this boot's active LSM
$P SELinux stays on until $R/boot/grub/grub.cfg is regenerated: install update-grub or grub-mkconfig, then run $GRUB_CMDS
RHIZO_TEARDOWN_REBOOT_REQUIRED=1
rc=0"
fixture_root cachy_bare
mkdir -p "$R/etc/default" "$R/sys/kernel/security"
grub_block
leftover_grub_cfg
chmod 000 "$R/boot/grub/grub.cfg"
selinux_running
teardown_step
chmod 644 "$R/boot/grub/grub.cfg"
check_unprivileged "no bootloader detected and grub.cfg unreadable, selinux running: whether it leaves cannot be told" \
  "$(grep -v "^cannot read $R/boot/grub/grub.cfg" "$TMP/final")" "${CANNOT_TELL}${NL}rc=0"
verify_listing
check "no bootloader detected: --verify names them, not clean" "$(< "$TMP/rc")|$(< "$TMP/err")" \
  "1|$P   bootloader tokens: absent
$P   bootloader tokens: PRESENT in $R/boot/grub/grub.cfg (carries:$ANDROID_SORTED);\
 install update-grub or grub-mkconfig, then run $GRUB_CMDS"

installed limine etc/default/limine
rm "$R/bin/limine-update"
selinux_running
teardown_step
check "limine-update gone: the warning names it, not a missing configuration" \
  "$(has_line "$P   WARNING: cannot detect the bootloader ($R/etc/default/limine is there, but no\
 limine-update is in any of $R/usr/bin, $R/usr/sbin, $R/bin, $R/sbin, $R/usr/local/sbin, $R/usr/local/bin to\
 regenerate its config -- install it); removing rhizo's tokens from every bootloader file")" 1
check "limine-update gone: it stays until limine.conf is regenerated" "$(< "$TMP/final")" "$REBOOT_LIMINE_LEFT"

installed limine etc/default/limine
rm "$R/bin/limine-update"
selinux_running
RHIZO_BOOTLOADER=limine teardown_step
check "RHIZO_BOOTLOADER's tool absent: the tool, the file, the tokens and the command named" \
  "$(has_line "$P   WARNING: $R/boot/limine.conf (carries:$CTOK_SORTED); install limine-update,\
 then run /usr/bin/limine-update")" 1
check "RHIZO_BOOTLOADER's tool absent: the run keeps its status, the notice saying it stays until limine.conf is\
 regenerated" "$(< "$TMP/final")" "$REBOOT_LIMINE_LEFT"
check "RHIZO_BOOTLOADER's tool absent: no unit line for it" "$(< "$TMP/deferred")|$(grep -c limine "$TMP/unit")" "|0"
check "RHIZO_BOOTLOADER's tool absent: the block is gone" "$(same etc/default/limine)" same
RHIZO_BOOTLOADER=limine verify_listing
check "RHIZO_BOOTLOADER's tool absent: --verify names them, not clean" "$(< "$TMP/rc")|$(< "$TMP/err")" \
  "1|$P   bootloader tokens: absent
$P   bootloader tokens: PRESENT in $R/boot/limine.conf (carries:$ANDROID_SORTED);\
 install limine-update, then run /usr/bin/limine-update"

VERIFY_ENV=(env RHIZO_BL_ROOT="$R" RHIZO_OS_RELEASE="$R/etc/os-release" PATH="$R/bin:$HOST_PATH")
# run teardown --verify and print its output
full_verify() { "${VERIFY_ENV[@]}" bash "$TEARDOWN" --verify 2>&1; }
SUDO_VERIFY="-- run 'sudo rhizo uninstall --verify'"
installed limine etc/default/limine
rm "$R/bin/limine-update"
RHIZO_BOOTLOADER=limine teardown_step
chmod 000 "$R/boot"
RHIZO_BOOTLOADER=limine verify_listing
chmod 755 "$R/boot"
check_unprivileged "the config this host boots through cannot be read: --verify says so once, without a verdict" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" "2|$P   bootloader tokens: absent
$P   bootloader tokens: cannot read $R/boot as uid $EUID $SUDO_VERIFY"
fixture_root limine
chmod 000 "$R/boot"
verify_listing
full=$(full_verify)
chmod 755 "$R/boot"
check_unprivileged "a /boot this uid cannot search: --verify says so once, nothing else about the bootloader" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" "2|$P   bootloader tokens: cannot read $R/boot as uid $EUID $SUDO_VERIFY
$P   bootloader tokens: absent"
check_unprivileged "a /boot this uid cannot search: --verify ends verify-cannot-read, not VERIFIED or not-clean" \
  "$(grep -c "bootloader tokens: cannot read" <<<"$full")|$(grep -c 'PRESENT in\|VERIFIED\|not-clean' <<<"$full")|$(
     tail -1 <<<"$full")" "1|0|RHIZO_TEARDOWN_FAILED reason=verify-cannot-read"
verify_listing
check "everything readable: --verify as before" "$(< "$TMP/rc")|$(< "$TMP/err")" "0|$P   bootloader tokens: absent"
check "everything readable: the whole --verify reads nothing as unreadable" \
  "$(grep -c "cannot read\|verify-cannot-read" <<<"$(full_verify)")" 0
installed limine etc/default/limine
rm "$R/bin/limine-update"
RHIZO_BOOTLOADER=limine teardown_step
chmod 000 "$R/boot/limine.conf"
full=$(RHIZO_BOOTLOADER=limine unshare -r "${VERIFY_ENV[@]}" bash "$TEARDOWN" --verify 2>&1)
chmod 644 "$R/boot/limine.conf"
check "as root, the config this host boots through is read whatever its mode: --verify judges it" \
  "$(grep -c "bootloader tokens: cannot read\|verify-cannot-read" <<<"$full")|$(
     grep -c "bootloader tokens: PRESENT in $R/boot/limine.conf" <<<"$full")|$(tail -1 <<<"$full")" \
  "0|1|RHIZO_TEARDOWN_FAILED reason=not-clean"
fixture_root ubuntu
mkdir -p "$R/boot/efi"
verify_listing; efi_open="$(< "$TMP/rc")|$(< "$TMP/err")"; full_open=$(full_verify)
chmod 000 "$R/boot/efi"
verify_listing; efi_shut="$(< "$TMP/rc")|$(< "$TMP/err")"; full_shut=$(full_verify)
chmod 755 "$R/boot/efi"
check_unprivileged "ubuntu with an ESP this uid cannot search: the bootloader lines are the searchable ESP's" \
  "$efi_shut" "$efi_open"
check_unprivileged "ubuntu with an ESP this uid cannot search: --verify is the searchable ESP's, byte for byte" \
  "$full_shut" "$full_open"

installed limine etc/default/limine
rm "$R/bin/limine-update"
teardown_step
chmod 000 "$R/boot/limine.conf"
verify_listing
full=$(full_verify)
root_full=$(unshare -r "${VERIFY_ENV[@]}" bash "$TEARDOWN" --verify 2>&1)
chmod 644 "$R/boot/limine.conf"
check_unprivileged "none detected, a stranded limine.conf this uid cannot read: --verify says so, without a verdict" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" "2|$P   bootloader tokens: absent
$P   bootloader tokens: cannot read $R/boot/limine.conf as uid $EUID $SUDO_VERIFY"
check_unprivileged "none detected, a stranded limine.conf this uid cannot read: --verify ends verify-cannot-read" \
  "$(grep -c "bootloader tokens: cannot read" <<<"$full")|$(tail -1 <<<"$full")" \
  "1|RHIZO_TEARDOWN_FAILED reason=verify-cannot-read"
check "none detected, the same limine.conf as root: PRESENT, not clean" \
  "$(grep -c "bootloader tokens: PRESENT in $R/boot/limine.conf" <<<"$root_full")|$(tail -1 <<<"$root_full")" \
  "1|RHIZO_TEARDOWN_FAILED reason=not-clean"
installed ubuntu etc/default/grub
rm "$R/bin/update-grub"
teardown_step
chmod 000 "$R/boot/grub/grub.cfg"
verify_listing
full=$(full_verify)
chmod 644 "$R/boot/grub/grub.cfg"
check_unprivileged "none detected on ubuntu, a stranded grub.cfg this uid cannot read: --verify says so" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" "2|$P   grub drop-in    : absent
$P   bootloader tokens: cannot read $R/boot/grub/grub.cfg as uid $EUID $SUDO_VERIFY"
check_unprivileged "none detected on ubuntu, a stranded grub.cfg this uid cannot read: ends verify-cannot-read" \
  "$(grep -c "bootloader tokens: cannot read" <<<"$full")|$(tail -1 <<<"$full")" \
  "1|RHIZO_TEARDOWN_FAILED reason=verify-cannot-read"
fixture_root limine
base_end=$(full_verify | tail -1)
leftover_grub_cfg
chmod 000 "$R/boot/grub/grub.cfg"
verify_listing
full=$(full_verify)
chmod 644 "$R/boot/grub/grub.cfg"
check_unprivileged "limine detected, a foreign grub.cfg this uid cannot read: --verify says nothing of it" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" "0|$P   bootloader tokens: absent"
check_unprivileged "limine detected, a foreign grub.cfg this uid cannot read: the verdict is the host's without it" \
  "$(grep -c "cannot read" <<<"$full")|$(tail -1 <<<"$full")" "0|$base_end"

installed limine etc/default/limine
chmod 000 "$R/etc/default/limine"
verify_listing
full=$(full_verify)
chmod 644 "$R/etc/default/limine"
check_unprivileged "a holder file this uid cannot read: --verify says so in one line, without a verdict" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" \
  "2|$P   bootloader tokens: cannot read $R/etc/default/limine as uid $EUID $SUDO_VERIFY"
check_unprivileged "a holder file this uid cannot read: the whole --verify ends verify-cannot-read" \
  "$(grep -c "bootloader tokens: cannot read" <<<"$full")|$(grep -c "awk" <<<"$full")|$(tail -1 <<<"$full")" \
  "1|0|RHIZO_TEARDOWN_FAILED reason=verify-cannot-read"
installed limine etc/default/limine
printf '#!/bin/bash\ncase "$*" in *"found = 1"*) echo "awk: read error" >&2; exit 2 ;; esac\n%s\n' \
  "exec \"$TMP/tools/awk\" \"\$@\"" > "$R/bin/awk"
chmod +x "$R/bin/awk"
teardown_step
rm "$R/bin/awk"
check "a holder file awk cannot read: the removal is refused, as before" "$(< "$TMP/rc") $(< "$TMP/out")" \
  "1 RHIZO_TEARDOWN_FAILED reason=bootloader-config-unreadable"
check "a holder file awk cannot read: named, as before" \
  "$(has_line "cannot read $R/etc/default/limine: awk exited 2")" 1

installed limine etc/default/limine
rm "$R/bin/limine-update"
RHIZO_BOOTLOADER=limine teardown_step
limine_move_esp "$R" /boot/limine
chmod 000 "$R/boot/limine"
RHIZO_BOOTLOADER=limine teardown_step
chmod 755 "$R/boot/limine"
check_unprivileged "a stranded limine.conf behind an unsearchable directory: the removal says why once" \
  "$(grep -c "cannot read $R/boot/limine as uid $EUID" "$TMP/err")" 1

installed limine etc/default/limine
rm "$R/bin/limine-update"
limine_move_esp "$R" /boot/limine
chmod 000 "$R/boot/limine"
teardown_step
chmod 755 "$R/boot/limine"
check_unprivileged "a holder's limine.conf behind an unsearchable directory: the removal says why once" \
  "$(grep -c "cannot read $R/boot/limine as uid $EUID" "$TMP/err")" 1
check_unprivileged "a holder's limine.conf behind an unsearchable directory: the config named by its writer" \
  "$(has_line "$P   WARNING: the config limine-update writes (has cmdlines that cannot be read); install limine-update,\
 then run /usr/bin/limine-update")" 1
fixture_root limine
rm "$R/bin/limine-update"
limine_move_esp "$R" /boot/limine
chmod 000 "$R/boot/limine"
on_root 'report_left_tokens apply limine "" "has cmdlines that cannot be read"' > "$TMP/out" 2> "$TMP/err"
chmod 755 "$R/boot/limine"
check_unprivileged "a reason no caller said: the report says it, then names the config by its writer" \
  "$(< "$TMP/err")" "cannot read $R/boot/limine as uid $EUID
$P   WARNING: the config limine-update writes (has cmdlines that cannot be read); install limine-update,\
 then run /usr/bin/limine-update"

# set up unreadable boot/efi and grub.cfg
efi_and_grub_shut() {
  fixture_root limine
  mkdir -p "$R/home/user/bin" "$R/boot/efi"
  mv "$R/bin/limine-update" "$R/home/user/bin/"
  limine_move_esp "$R" /boot/efi
  leftover_grub_cfg
  chmod 000 "$R/boot/grub/grub.cfg" "$R/boot/efi"
}
EFI_SHUT="$P   bootloader tokens: cannot read $R/boot/efi as uid $EUID $SUDO_VERIFY"
GRUB_SHUT="$P   bootloader tokens: cannot read $R/boot/grub/grub.cfg as uid $EUID $SUDO_VERIFY"
efi_and_grub_shut
EXTRA_PATH="$R/home/user/bin" verify_listing
chmod 755 "$R/boot/efi"; chmod 644 "$R/boot/grub/grub.cfg"
check_unprivileged "limine-update only on a user's PATH, an ESP and a grub.cfg this uid cannot read: each said once" \
  "$(< "$TMP/rc")|$(has_line "$EFI_SHUT")|$(has_line "$GRUB_SHUT")" "2|1|1"
efi_and_grub_shut
# shellcheck disable=SC2016
on_root 'bootloader_kind() { echo "cannot read $R/boot/efi as uid $EUID" >&2; return 2; }
         list_cmdline_tokens' > "$TMP/out" 2> "$TMP/err"
echo $? > "$TMP/rc"
chmod 755 "$R/boot/efi"; chmod 644 "$R/boot/grub/grub.cfg"
check_unprivileged "detection's reason met again after another: said once, in the order met" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" "2|$EFI_SHUT
$P   bootloader tokens: absent
$GRUB_SHUT"

installed limine etc/default/limine
mkdir "$R/private"
mv "$R/etc/default/limine" "$R/private/limine"; ln -s "$R/private/limine" "$R/etc/default/limine"
chmod 000 "$R/private"
verify_listing
full=$(full_verify)
root_full=$(unshare -r "${VERIFY_ENV[@]}" bash "$TEARDOWN" --verify 2>&1)
chmod 755 "$R/private"
check_unprivileged "/etc/default/limine linked out of this uid's reach: --verify says so once, without a verdict" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" "2|$P   bootloader tokens: cannot read $R/private as uid $EUID $SUDO_VERIFY"
check_unprivileged "/etc/default/limine linked out of this uid's reach: --verify ends verify-cannot-read" \
  "$(grep -c "bootloader tokens: cannot read" <<<"$full")|$(grep -c 'bootloader tokens: absent' <<<"$full")|$(
     tail -1 <<<"$full")" "1|0|RHIZO_TEARDOWN_FAILED reason=verify-cannot-read"
check "/etc/default/limine linked into a directory, as root: PRESENT, not clean" \
  "$(grep -c "bootloader tokens: PRESENT ($R/etc/default/limine)" <<<"$root_full")|$(tail -1 <<<"$root_full")" \
  "1|RHIZO_TEARDOWN_FAILED reason=not-clean"
installed sdboot etc/sdboot-manage.conf
rm "$R/bin/sdboot-manage"
teardown_step
mkdir "$R/private"
mv "$R/boot/loader/entries/linux-cachyos.conf" "$R/private/"
ln -s "$R/private/linux-cachyos.conf" "$R/boot/loader/entries/linux-cachyos.conf"
chmod 000 "$R/private"
verify_listing
full=$(full_verify)
root_full=$(unshare -r "${VERIFY_ENV[@]}" bash "$TEARDOWN" --verify 2>&1)
chmod 755 "$R/private"
check_unprivileged "none detected, a stranded sd-boot entry linked out of this uid's reach: --verify says so" \
  "$(< "$TMP/rc")|$(< "$TMP/err")" "2|$P   bootloader tokens: absent
$P   bootloader tokens: cannot read $R/private as uid $EUID $SUDO_VERIFY"
check_unprivileged "none detected, a stranded sd-boot entry linked out of this uid's reach: ends verify-cannot-read" \
  "$(grep -c "bootloader tokens: cannot read" <<<"$full")|$(tail -1 <<<"$full")" \
  "1|RHIZO_TEARDOWN_FAILED reason=verify-cannot-read"
check "none detected, the same sd-boot entry as root: PRESENT, not clean" \
  "$(grep -c "bootloader tokens: PRESENT in $R/boot/loader/entries" <<<"$root_full")|$(tail -1 <<<"$root_full")" \
  "1|RHIZO_TEARDOWN_FAILED reason=not-clean"

installed ubuntu etc/default/grub boot/grub/grub.cfg
rm "$R/usr/bin" "$R/usr/sbin"; mkdir "$R/usr/bin" "$R/usr/sbin"
mv "$R/bin/update-grub" "$R/bin/grub-gen" "$R/usr/sbin/"
STEP_PATH="$R/bin:$TMP/tools" teardown_step
check "update-grub only under /usr/sbin, PATH without it: the base's output, word for word" \
  "$(< "$TMP/rc")|$(< "$TMP/out")|$(< "$TMP/err")" "0|$P   Generating grub configuration file ...|$P running update-grub
$P   removed: $R/etc/default/grub.d/90-rhizo.cfg, and regenerated $R/boot/grub/grub.cfg"
check "update-grub only under /usr/sbin, PATH without it: run once, nothing deferred" \
  "$(ncalls "$R" update-grub)|$(< "$TMP/deferred")" "1|"
check "update-grub only under /usr/sbin, PATH without it: grub.cfg as before the install" \
  "$(same boot/grub/grub.cfg)" same

installed limine etc/default/limine
grub_block
teardown_step
check "a grub holder with no grub.cfg: says so" "$(has_line "$P   no update-grub or grub-mkconfig is installed, and no\
 next-boot cmdline of grub-inline carries rhizo's tokens")" 1
check "a grub holder with no grub.cfg: its block is gone" "$(same etc/default/grub)" same
check "a grub holder with no grub.cfg: nothing deferred" "$(< "$TMP/deferred")" ""

installed grub etc/default/grub
rm "$R/usr/bin" "$R/usr/sbin"
mkdir "$R/usr/bin" "$R/usr/sbin"
mv "$R/bin/grub-mkconfig" "$R/usr/sbin/grub-mkconfig"
: > "$R/regen-fails"
teardown_step
check "grub-mkconfig only under /usr/sbin: deferred" "$(< "$TMP/deferred")" grub-inline
check "grub-mkconfig only under /usr/sbin: the unit runs it where it is" \
  "$(regen_lines "/usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg")|$(grep -c /usr/bin/grub-mkconfig "$TMP/unit")" "1|0"
check "grub-mkconfig only under /usr/sbin: advice names that path" "$(on_root 'regen_choices grub-inline cmd')" \
  "/usr/sbin/update-grub or /usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg"

installed grub etc/default/grub boot/grub/grub.cfg
mkdir -p "$R/home/user/bin"
mv "$R/bin/grub-mkconfig" "$R/home/user/bin/grub-mkconfig"
EXTRA_PATH="$R/home/user/bin" teardown_step
check "grub-mkconfig only in a user's PATH directory: not run" "$(ncalls "$R" grub-mkconfig)" 0
check "grub-mkconfig only in a user's PATH directory: no unit line" \
  "$(< "$TMP/deferred")|$(grep -c grub "$TMP/unit")" "|0"
check "grub-mkconfig only in a user's PATH directory: the usual paths advised" \
  "$(has_line "$P   WARNING: $R/boot/grub/grub.cfg (carries:$CTOK_SORTED); install update-grub or grub-mkconfig,\
 then run $GRUB_CMDS")" 1

fixture_root limine
fixture add_grub_inline "$R"
keep etc/default/limine boot/limine.conf etc/default/grub boot/grub/grub.cfg
lib_apply limine
lib_apply grub-inline
RHIZO_BOOTLOADER=limine teardown_step
check "two holders, limine chosen: rc"          "$(< "$TMP/rc")" 0
check "two holders, limine chosen: grub-mkconfig ran" "$(ncalls "$R" grub-mkconfig)" 1
check "two holders, limine chosen: limine-update ran" "$(ncalls "$R" limine-update)" 1
for p in etc/default/limine boot/limine.conf etc/default/grub boot/grub/grub.cfg; do
  check "two holders, limine chosen: $p as before" "$(same "$p")" same
done
check "two holders, limine chosen: nothing deferred" "$(< "$TMP/deferred")" ""

installed ubuntu etc/default/grub boot/grub/grub.cfg
sed -i 's/^VERSION_ID=.*/VERSION_ID="26.04"/' "$R/etc/os-release"
teardown_step
check "an ubuntu upgraded past 24.04: rc"       "$(< "$TMP/rc")" 0
check "an ubuntu upgraded past 24.04: stderr"   "$(< "$TMP/err")" "$P   WARNING: cannot detect the bootloader (cannot find the bootloader on unsupported:ubuntu 26.04); removing\
 rhizo's tokens from every bootloader file
$P running update-grub
$P   removed: $R/etc/default/grub.d/90-rhizo.cfg, and regenerated $R/boot/grub/grub.cfg"
check "an ubuntu upgraded past 24.04: grub.cfg as before the install" "$(same boot/grub/grub.cfg)" same

installed limine etc/default/limine boot/limine.conf
fixture add_sdboot "$R"
teardown_step
check "limine and sdboot both configured: says why it cannot tell" \
  "$(grep -cF "cannot detect the bootloader (more than one bootloader is configured here (limine sdboot)" \
     "$TMP/err")" 1
check "limine and sdboot both configured: limine's block is gone" "$(same etc/default/limine)" same
check "limine and sdboot both configured: limine.conf as before" "$(same boot/limine.conf)" same

fixture_root ubuntu
teardown_step
check "ubuntu, nothing installed: stderr word for word" "$(< "$TMP/rc") $(< "$TMP/err")" \
  "0 $P grub drop-in already absent: $R/etc/default/grub.d/90-rhizo.cfg"
check "ubuntu, nothing installed: no change"    "$(< "$TMP/changed")" 0
check "ubuntu, nothing installed: nothing regenerated" "$(ncalls "$R" update-grub)" 0
fixture_root limine
teardown_step
check "cachyos, nothing installed"              "$(< "$TMP/rc") $(< "$TMP/err")" \
  "0 $P bootloader tokens already absent: $R/etc/default/limine"
fixture_root cachy_bare
teardown_step
check "cachyos with no bootloader found, nothing installed" "$(< "$TMP/rc") $(< "$TMP/err")" \
  "0 $P bootloader tokens already absent"

installed limine etc/default/limine
chmod 000 "$R/etc/default/limine"
teardown_step
chmod 644 "$R/etc/default/limine"
check_unprivileged "an unreadable /etc/default/limine: refused" "$(< "$TMP/rc") $(< "$TMP/out")" \
  "1 RHIZO_TEARDOWN_FAILED reason=bootloader-config-unreadable"
fixture_root limine
printf '%s\n' "$LIMINE_ESP" "$LIMINE_BASE" "# >>> rhizo" 'KERNEL_CMDLINE[default]+=" old=1"' > "$R/etc/default/limine"
keep etc/default/limine
teardown_step
check "an unterminated block: refused"          "$(< "$TMP/rc") $(< "$TMP/out")" \
  "1 RHIZO_TEARDOWN_FAILED reason=bootloader-tokens-unreadable"
check "an unterminated block: file untouched"   "$(same etc/default/limine)" same
fixture_root ubuntu
mkdir "$R/etc/default/grub.d/90-rhizo.cfg"
verify_listing
check "a directory at the drop-in's path: verify says PRESENT" "$(< "$TMP/rc") $(< "$TMP/err")" \
  "1 $P   grub drop-in    : PRESENT ($R/etc/default/grub.d/90-rhizo.cfg)"
teardown_step
check "a directory at the drop-in's path: the removal stops as before" "$(< "$TMP/rc") $(< "$TMP/out")" \
  "1 RHIZO_TEARDOWN_FAILED reason=grub-dropin-rm-failed"
check "a directory at the drop-in's path: rm's own error, then the failure" "$(tail -2 "$TMP/err")" \
  "rm: cannot remove '$R/etc/default/grub.d/90-rhizo.cfg': Is a directory
$P FAILED: could not remove $R/etc/default/grub.d/90-rhizo.cfg"

installed ubuntu
verify_listing
check "verify, ubuntu drop-in present"          "$(< "$TMP/rc") $(< "$TMP/err")" \
  "1 $P   grub drop-in    : PRESENT ($R/etc/default/grub.d/90-rhizo.cfg)"
fixture_root ubuntu
verify_listing
check "verify, ubuntu drop-in absent"           "$(< "$TMP/rc") $(< "$TMP/err")" "0 $P   grub drop-in    : absent"
installed limine
grub_block
verify_listing
check "verify, two cachyos holders"             "$(< "$TMP/rc") $(< "$TMP/err")" \
  "1 $P   bootloader tokens: PRESENT ($R/etc/default/grub)
$P   bootloader tokens: PRESENT ($R/etc/default/limine)"
fixture_root limine
verify_listing
check "verify, cachyos absent"                  "$(< "$TMP/rc") $(< "$TMP/err")" "0 $P   bootloader tokens: absent"

echo 1 > "$TMP/enforce-node"
printf 'u:r:rhizo_host:s0\0' > "$TMP/attr-current"
# print the teardown's host enforcement note
enforcing_note() {
  if [[ "$1" == none ]]; then rm -f "$TMP/selinux-mode"; else echo "$1" > "$TMP/selinux-mode"; fi
  # shellcheck disable=SC2016
  on_root 'TEARDOWN_SELINUX_MODE_FILE=$TMP/selinux-mode TEARDOWN_SELINUX_ENFORCE=$TMP/enforce-node
           TEARDOWN_ATTR_CURRENT=$TMP/attr-current TEARDOWN_ANDROIDD_ENV=/etc/rhizo/androidd.env
           note_enforcing_deferrals' 2>&1
}
check "an enforcing host names the removals the next boot finishes" "$(enforcing_note none)" \
      "$P selinux is enforcing; refused removals run at the next boot"
SYS_CTX="system_u:system_r:init_t:s0"
for state_note in \
    "kernel|1|the host loads no policy" \
    "|1|the host loads no policy" \
    "$SYS_CTX|0|the host policy is permissive" \
    "$SYS_CTX|1|the host policy is enforcing; refused removals run at the next boot" \
    "$SYS_CTX|x|unknown host SELinux state ($TMP/enforce-node reads 'x')" \
    "u:r:rhizo_host:s0|1|Android's policy is loaded host-wide on this boot; refused removals run at the next boot"; do
  IFS='|' read -r ctx enforce note <<<"$state_note"
  printf '%s\0' "$ctx" > "$TMP/attr-current"; echo "$enforce" > "$TMP/enforce-node"
  check "namespace mode with the task context '$ctx' and enforce '$enforce' names that state" \
    "$(enforcing_note namespace)" "$P selinux namespace mode: $note"
done
echo 0 > "$TMP/enforce-node"
check "a permissive host logs nothing about enforcement" "$(enforcing_note host)" ""

records_dir_line=$(grep -m1 '^SELINUXNS_RECORDS_DIR=' "$TEARDOWN")
mkdir -p "$TMP/run/rhizo-selinuxns" "$TMP/run/rhizo-selinuxns-2"; : > "$TMP/run/rhizo-selinuxns-x"
for f in selinuxns_records_dirs remove_selinuxns_records report_selinuxns_records; do
  body=$(lift "$f" "$TEARDOWN")
  [[ -n "$body" ]] || { echo "FAIL no $f() in $TEARDOWN"; FAILED=$((FAILED + 1)); continue; }
  RECORDS_TEXT+="$body$NL"
done
# shellcheck disable=SC2016
out=$(RHIZO_TEARDOWN_SELINUXNS_RECORDS_DIR="$TMP/run/rhizo-selinuxns" \
      on_root "$records_dir_line$NL${RECORDS_TEXT:-}${NL}remove_selinuxns_records; report_selinuxns_records" 2>&1)
check "the teardown removes every records dir under its /run and keeps a plain file" \
  "$(ls "$TMP/run" | tr '\n' ' ')|$(grep -c 'rhizo-selinuxns\[-<id>\] : absent' <<<"$out")" "rhizo-selinuxns-x |1"

SKIP_NOTE=""; (( SKIPPED )) && SKIP_NOTE=", $SKIPPED skipped as root"
(( FAILED )) && { echo "$FAILED failed$SKIP_NOTE"; exit 1; }
echo "test-teardown-bootloader: ok$SKIP_NOTE"
