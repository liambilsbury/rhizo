#!/bin/bash
# test bootstrap.sh --show
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOOT="$HERE/../bootstrap/bootstrap.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILED=0 SKIPPED=0
NL=$'\n'
# run check or count a skip
check_unprivileged() {
  if (( EUID != 0 )); then check "$@"; return; fi
  echo "SKIP $1 -- the suite runs as root, which no mode bit stops"
  SKIPPED=$((SKIPPED + 1))
}
# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; FAILED=$((FAILED + 1)); fi
}
# shellcheck source=fixtures/bootloader-fixtures.sh
. "$HERE/fixtures/bootloader-fixtures.sh"
link_bootstrap_tools "$TMP/tools"

# print the --show output for a fixture host
show() {
  local root="$TMP/root"
  rm -rf "$root"; mkdir -p "$root"
  (
    export RHIZO_BL_ROOT="$root"
    if [[ "$1" == cachyos ]]; then add_cachyos_host "$root" "${SHOW_LOADER:-limine}"; else "add_$1_host" "$root"; fi
    "$2" "$root"
    BOOT_AS_USER=1 boot_run "$root" "$TMP/tools" "$BOOT" --show "${@:3}" 2> "$TMP/show.err"
  )
}
# leave the fixture host unchanged
as_is()         { :; }
# add an lsm list to the cmdline, a zram swap and binder devices
host_derived()  { echo "$(< "$1/proc/cmdline") lsm=landlock,lockdown,yama,integrity,apparmor,bpf" > "$1/proc/cmdline"
                  printf '%s\n/dev/zram0 partition 16G 0 100\n' "$SWAPS_HEADER" > "$1/proc/swaps"
                  mkdir -p "$1/sys/module/binder/parameters"; echo binder > "$1/sys/module/binder/parameters/devices"; }
# write a 16G zram swap list
zram_16g()      { printf '%s\n/dev/zram0 partition 16G 0 100\n' "$SWAPS_HEADER" > "$1/proc/swaps"; }
# write a cmdline and lsm file that list apparmor
apparmor()      { echo "$LIMINE_CMDLINE lsm=landlock,lockdown,yama,integrity,apparmor,bpf" > "$1/proc/cmdline"
                  echo capability,landlock,lockdown,yama,integrity,apparmor,bpf > "$1/sys/kernel/security/lsm"; }
# write the apparmor fixture and remove the lsm file
lsm_unreadable() { apparmor "$1"; rm "$1/sys/kernel/security/lsm"; }
# remove the lsm file
no_lsm_file()   { rm "$1/sys/kernel/security/lsm"; }
# write only the name binder to the binder devices parameter
binder_only()   { echo binder > "$1/sys/module/binder/parameters/devices"; }
# write a cmdline with binder.devices set
binder_kept()   { echo "$LIMINE_CMDLINE binder.devices=binder,hwbinder,vndbinder" > "$1/proc/cmdline"; }
# remove the binder module directory
no_binder()     { rm -r "$1/sys/module/binder"; }
# remove access to the boot directory
boot_unsearchable() { chmod 000 "$1/boot"; }
# write an arch os-release
arch_host()     { printf 'ID=arch\n' > "$1/etc/os-release"; }
# write a grub cmdline that holds a command substitution
# shellcheck disable=SC2016
dollar_line()   { rm -f "$1/etc/default/limine" "$1/bin/limine-update"; add_grub_inline "$1"
                  printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet $(cat /x)"' > "$1/etc/default/grub"; }
# write a limine config with an lsm= list
own_line_lsm()  { limine_default "$1" "$LIMINE_ESP" \
                    "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE lsm=landlock,lockdown,yama,integrity,selinux,bpf\"" \
                    "$LIMINE_ORDER"; }
# write a swap list that holds /swapfile
swapfile_swap() { printf '%s\n/swapfile file 4194300 0 -2\n' "$SWAPS_HEADER" > "$1/proc/swaps"; }
# write a limine config with an lsm list
own_line_bpf_first() { limine_default "$1" "$LIMINE_ESP" \
                         "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE lsm=landlock,lockdown,yama,integrity,bpf,selinux\"" \
                         "$LIMINE_ORDER"; }
CACHY_LSM=lsm=capability,landlock,lockdown,yama,selinux,bpf


check "ubuntu: today's line"                  "$(show ubuntu as_is)" "$UBUNTU_TOKENS"
check "ubuntu --lsm-list: today's line"       "$(show ubuntu as_is --lsm-list)" "$UBUNTU_LSM_TOKENS"
check "ubuntu loop.max_loop=48: today's line" "$(BOOT_LOOP_MAX=48 show ubuntu as_is)" "${UBUNTU_TOKENS/loop.max_loop=64/loop.max_loop=48}"
check "ubuntu --lsm-list loop.max_loop=48: today's line" "$(BOOT_LOOP_MAX=48 show ubuntu as_is --lsm-list)" \
  "${UBUNTU_LSM_TOKENS/loop.max_loop=64/loop.max_loop=48}"
check "ubuntu loop value with a doubled space and a glob: printed as given" "$(BOOT_LOOP_MAX='64  *' show ubuntu as_is)" \
  "${UBUNTU_TOKENS/loop.max_loop=64/loop.max_loop=64  *}"
check "ubuntu ignores a cmdline lsm=, zram swap and binder devices" "$(show ubuntu host_derived)" "$UBUNTU_TOKENS"
check "cachyos stock: an lsm= list with selinux ahead of bpf, and no zswap on zram" "$(show cachyos as_is)" \
  "$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT"
check "cachyos zram swap of the brief's size"  "$(show cachyos zram_16g)" "$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT"
check "cachyos with an lsm= list: selinux takes apparmor's place, no security=" "$(show cachyos apparmor)" \
  "lsm=capability,landlock,lockdown,yama,integrity,selinux,bpf $TOKENS_MID $TOKENS_ANDROIDBOOT"
check "cachyos --lsm-list extends the active list" "$(show cachyos as_is --lsm-list)" \
  "lsm=capability,landlock,lockdown,yama,selinux,bpf $TOKENS_MID $TOKENS_ANDROIDBOOT"
check "cachyos whose own configured line carries an lsm= holding selinux: exactly that list (ruling 61)" \
  "$(show cachyos own_line_lsm)" "lsm=landlock,lockdown,yama,integrity,selinux,bpf $TOKENS_MID $TOKENS_ANDROIDBOOT"
check "cachyos stock and the rest: nothing on stderr" "$(show cachyos as_is >/dev/null; cat "$TMP/show.err")" ""
check "cachyos whose own configured line puts bpf before selinux: not adopted, the active list's order instead" \
  "$(show cachyos own_line_bpf_first)" "$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT"
check "cachyos with no readable active list: refused, naming the file" \
  "$(show cachyos no_lsm_file; echo "rc=$?")|$(< "$TMP/show.err")" "rc=1|[rhizo-host-bootstrap] FAIL: off Ubuntu\
 rhizo's lsm= list is the active one with selinux ahead of bpf, but $TMP/root/sys/kernel/security/lsm cannot be read:\
 No such file or directory"
check_unprivileged "cachyos --show as a user who cannot search /boot: the active list's, and why on stderr" \
  "$(show cachyos boot_unsearchable; chmod 755 "$TMP/root/boot")|$(< "$TMP/show.err")" \
  "$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT|[rhizo-host-bootstrap] the LSM token shown is the running\
 cmdline's: the bootstrap, run as root, chooses it from this host's own configured line, which this caller cannot read\
 (cannot read $TMP/root/boot as uid $EUID)"
check "an unsupported flavor's --show: the active list's, and on stderr that the bootstrap would stop" \
  "$(show cachyos arch_host)|$(< "$TMP/show.err")" "$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT|\
[rhizo-host-bootstrap] the LSM token shown is the running cmdline's, as the bootstrap would stop on this host: cannot\
 find the bootloader on unsupported:arch unknown"
# shellcheck disable=SC2016
check "a host line only running its file would tell: --show says the bootstrap would stop, naming it" \
  "$(show cachyos dollar_line)|$(< "$TMP/show.err")" "$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT|\
[rhizo-host-bootstrap] the LSM token shown is the running cmdline's, as the bootstrap would stop on this host: cannot\
 read GRUB_CMDLINE_LINUX_DEFAULT in $TMP/root/etc/default/grub: its value has \$("
check "cachyos lsm= with no readable active list: refused, naming the file" \
  "$(show cachyos lsm_unreadable; echo "rc=$?")|$(< "$TMP/show.err")" "rc=1|[rhizo-host-bootstrap] FAIL: off Ubuntu\
 rhizo's lsm= list is the active one with selinux ahead of bpf, but $TMP/root/sys/kernel/security/lsm cannot be read:\
 No such file or directory"
check "cachyos --lsm-list with no readable active list: refused, naming the file" \
  "$(show cachyos no_lsm_file --lsm-list; echo "rc=$?")|$(< "$TMP/show.err")" "rc=1|[rhizo-host-bootstrap] FAIL:\
 --lsm-list builds its list from the active one, but $TMP/root/sys/kernel/security/lsm cannot be read: No such file\
 or directory"
check "cachyos built-in binder naming other devices gets binder.devices" "$(show cachyos binder_only)" \
  "$CACHY_LSM $TOKENS_MID binder.devices=binder,hwbinder,vndbinder $TOKENS_ANDROIDBOOT"
check "cachyos binder.devices already on the cmdline is kept" "$(show cachyos binder_kept)" \
  "$CACHY_LSM $TOKENS_MID binder.devices=binder,hwbinder,vndbinder $TOKENS_ANDROIDBOOT"
check "cachyos without built-in binder: no binder.devices" "$(show cachyos no_binder)" "$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT"
check "cachyos swap on a swapfile keeps zswap"   "$(show cachyos swapfile_swap)" "$CACHY_LSM $TOKENS_MID zswap.enabled=1 $TOKENS_ANDROIDBOOT"

NS_MID="loglevel=8 log_buf_len=16M audit_backlog_limit=32768 systemd.unified_cgroup_hierarchy=1 loop.max_loop=64"
# configure selinux namespace mode
ns_mode()       { echo namespace > "$1/selinux-mode"; }
# configure namespace mode with a binder device
ns_binder()     { ns_mode "$1"; binder_only "$1"; }
# configure namespace mode without an lsm list
ns_no_lsm()     { ns_mode "$1"; no_lsm_file "$1"; }
# configure an unknown selinux mode
odd_mode()      { echo hostwide > "$1/selinux-mode"; }
check "ubuntu namespace: no security= or enforcing= token" "$(show ubuntu ns_mode)" \
  "$NS_MID zswap.enabled=1 $TOKENS_ANDROIDBOOT"
check "cachyos namespace: no lsm= or enforcing= token, no zswap on zram" "$(show cachyos ns_mode)" \
  "$NS_MID $TOKENS_ANDROIDBOOT"
check "cachyos namespace with built-in binder naming other devices: binder.devices" "$(show cachyos ns_binder)" \
  "$NS_MID binder.devices=binder,hwbinder,vndbinder $TOKENS_ANDROIDBOOT"
check "cachyos namespace reads no lsm list: none readable is no refusal" \
  "$(show cachyos ns_no_lsm; echo "rc=$?")|$(< "$TMP/show.err")" "$NS_MID $TOKENS_ANDROIDBOOT${NL}rc=0|"
check "namespace --lsm-list: refused, named" "$(show ubuntu ns_mode --lsm-list; echo "rc=$?")|$(< "$TMP/show.err")" \
  "rc=1|[rhizo-host-bootstrap] FAIL: --lsm-list writes an lsm= list, which selinux namespace mode never writes"
check "a configured mode that is neither: refused, named" "$(show ubuntu odd_mode; echo "rc=$?")|$(< "$TMP/show.err")" \
  "rc=1|[rhizo-host-bootstrap] FAIL: $TMP/root/bin/rhizo-selinux-mode --configured printed 'hostwide', which is\
 neither host nor namespace"
# use namespace mode and log the mode helper's arguments
ns_mode_argv()  { ns_mode "$1"; : > "$1/selinux-mode-argv"; }
show ubuntu ns_mode_argv > /dev/null
check "the mode helper reads the configured mode from the env file every other reader names" \
  "$(sort -u "$TMP/root/selinux-mode-argv")" "--env-file /etc/rhizo/androidd.env --configured"

SKIP_NOTE=""; (( SKIPPED )) && SKIP_NOTE=", $SKIPPED skipped as root"
L_A=lsm=landlock,lockdown,yama,integrity,selinux,bpf L_B=lsm=yama,selinux,bpf L_X=lsm=landlock,bpf
ADOPT_A="$L_A $TOKENS_MID $TOKENS_ANDROIDBOOT"
KEEP="$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT"
# write limine keys for default and cachyos-lts
lts_key()       { limine_default "$1" "$LIMINE_ESP" "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE $L_A\"" \
                    "KERNEL_CMDLINE[linux-cachyos-lts]=\"$LIMINE_CMDLINE ${LTS_LSM:-}\"" "$LIMINE_ORDER"; }
# install the lts kernel and write its limine key
lts_installed() { touch "$1/boot/vmlinuz-linux-cachyos-lts"; lts_key "$1"; }
# write sdboot-manage.conf and run sdboot-manage
sd_opts()       { printf 'LINUX_OPTIONS="nowatchdog quiet %s"\nLINUX_FALLBACK_OPTIONS="quiet %s"\n' "${MAIN_LSM:-}" \
                    "${FB_LSM:-}" > "$1/etc/sdboot-manage.conf"; run_stub "$1/bin/sdboot-manage" gen; }
# add the fallback initramfs and write the sdboot options
sd_fallback()   { touch "$1/initramfs-linux-cachyos-fallback.img"; sd_opts "$1"; }
# write GRUB_CMDLINE_LINUX_DEFAULT to the grub file
grub_recovery() { printf '%s\n' "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $L_A\"" > "$1/etc/default/grub"; }
# write both grub cmdline variables
grub_both()     { printf '%s\n' "GRUB_CMDLINE_LINUX=\"$L_B\"" "GRUB_CMDLINE_LINUX_DEFAULT=\"quiet $L_A\"" \
                    'GRUB_DISABLE_RECOVERY=true' > "$1/etc/default/grub"; }
# write two limine KERNEL_CMDLINE lines
limine_front()  { limine_default "$1" "$LIMINE_ESP" "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE $L_A\"" \
                    "KERNEL_CMDLINE[default]+=\"$L_B\"" "$LIMINE_ORDER"; }
check "limine, an uninstalled kernel's key leaving selinux out: not a next-boot line, so the host's list adopted" \
  "$(LTS_LSM=$L_X show cachyos lts_key)" "$ADOPT_A"
check "limine, an installed kernel's key leaving selinux out: the running cmdline's choice, refused later" \
  "$(LTS_LSM=$L_X show cachyos lts_installed)" "$KEEP"
check "limine, an installed kernel's key carrying no lsm=: the running cmdline's choice, as adopting changes it" \
  "$(LTS_LSM='' show cachyos lts_installed)" "$KEEP"
check "limine, two installed kernels' lists both making selinux the major LSM: the first line's" \
  "$(LTS_LSM=$L_B show cachyos lts_installed)" "$ADOPT_A"
check "limine, a += in front of the = carrying another list: the last on the line, the ='s" \
  "$(show cachyos limine_front)" "$ADOPT_A"
check "sdboot, LINUX_FALLBACK_OPTIONS leaving selinux out with no fallback image: not a next-boot line, adopted" \
  "$(SHOW_LOADER=sdboot MAIN_LSM=$L_A FB_LSM=$L_X show cachyos sd_opts)" "$ADOPT_A"
check "sdboot, the same with the fallback image: the running cmdline's choice, refused later" \
  "$(SHOW_LOADER=sdboot MAIN_LSM=$L_A FB_LSM=$L_X show cachyos sd_fallback)" "$KEEP"
check "sdboot, a fallback entry carrying no lsm=: the running cmdline's choice, as adopting changes it" \
  "$(SHOW_LOADER=sdboot MAIN_LSM=$L_A FB_LSM='' show cachyos sd_fallback)" "$KEEP"
check "sdboot, only the fallback entry carrying a list: the running cmdline's choice, the main entry's LSMs kept" \
  "$(SHOW_LOADER=sdboot MAIN_LSM='' FB_LSM=$L_A show cachyos sd_fallback)" "$KEEP"
check "grub, GRUB_CMDLINE_LINUX's list then GRUB_CMDLINE_LINUX_DEFAULT's: the last on the line, _DEFAULT's" \
  "$(SHOW_LOADER=grub_inline show cachyos grub_both)" "$ADOPT_A"
check "grub with its recovery entry, which carries no lsm=: the running cmdline's choice" \
  "$(SHOW_LOADER=grub_inline show cachyos grub_recovery)" "$KEEP"
# write sdboot-manage.conf and run sdboot-manage
sd_main_only()  { printf 'LINUX_OPTIONS="nowatchdog quiet %s"\n#LINUX_FALLBACK_OPTIONS=""\n' "$L_A" \
                    > "$1/etc/sdboot-manage.conf"; touch "$1/initramfs-linux-cachyos-fallback.img"
                  run_stub "$1/bin/sdboot-manage" gen; }
# install the lts kernel and write an empty limine key for it
lts_empty()     { touch "$1/boot/vmlinuz-linux-cachyos-lts"
                  limine_default "$1" "$LIMINE_ESP" "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE $L_A\"" \
                    'KERNEL_CMDLINE[linux-cachyos-lts]=""' "$LIMINE_ORDER"; }
# write limine cmdline keys for two entries
limine_fb()     { limine_default "$1" "$LIMINE_ESP" "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE $L_A\"" \
                    "KERNEL_CMDLINE[fallback]=\"$LIMINE_CMDLINE\"" "$LIMINE_ORDER" MKINITCPIO_FALLBACK=yes; }
# write /etc/kernel/cmdline and the limine default
limine_kcmd()   { mkdir -p "$1/etc/kernel"; echo "$LIMINE_CMDLINE $L_A" > "$1/etc/kernel/cmdline"
                  limine_default "$1" "$LIMINE_ESP" "$LIMINE_ORDER"; }
check "sdboot, the fallback entry's LINUX_FALLBACK_OPTIONS commented out: an empty line, the running choice" \
  "$(SHOW_LOADER=sdboot show cachyos sd_main_only)" "$KEEP"
check "limine, the last kernel entry's own key empty: an empty line, the running choice" \
  "$(show cachyos lts_empty)" "$KEEP"
check "limine, a fallback entry taking KERNEL_CMDLINE[fallback], which carries no lsm=: the running choice" \
  "$(show cachyos limine_fb)|$(grep -c '^  //linux-cachyos-fallback$' "$TMP/root/boot/limine.conf")" "$KEEP|1"
check "limine, no key set: /etc/kernel/cmdline's list adopted" "$(show cachyos limine_kcmd)" "$ADOPT_A"
# add a second bootloader to the fixture host
two_loaders()   { add_sdboot "$1"; }
check "two bootloaders: --show says the bootstrap would stop, naming why" \
  "$(show cachyos two_loaders)|$(< "$TMP/show.err")" "$KEEP|[rhizo-host-bootstrap] the LSM token shown is the\
 running cmdline's, as the bootstrap would stop on this host: more than one bootloader is configured here (limine\
 sdboot) -- set RHIZO_BOOTLOADER to the one that boots this machine"

(( FAILED )) && { echo "$FAILED failed$SKIP_NOTE"; exit 1; }
echo "test-bootstrap-tokens: ok$SKIP_NOTE"
