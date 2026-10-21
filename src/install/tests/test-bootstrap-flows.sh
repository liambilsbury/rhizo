#!/bin/bash
# test the bootstrap on stubbed hosts
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOOT="$HERE/../bootstrap/bootstrap.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILED=0 SKIPPED=0
NL=$'\n'
# skip a test for uid 0
skip_as_root() {
  (( EUID == 0 )) || return 1
  echo "SKIP $1 -- the suite runs as root, which no non-root refusal stops"
  SKIPPED=$((SKIPPED + 1))
}
# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; FAILED=$((FAILED + 1)); fi
}
# shellcheck source=fixtures/bootloader-fixtures.sh
. "$HERE/fixtures/bootloader-fixtures.sh"
link_bootstrap_tools "$TMP/tools"
R="$TMP/root"
UBUNTU_RHIZO=7.1.0-rc1-rhizo

# create an ubuntu host fixture
h_ubuntu() {
  add_ubuntu_host "$1" && touch "$1/boot/vmlinuz-$UBUNTU_RHIZO" || return
  printf '%s\n' 'CONFIG_SECURITY_SELINUX=y' 'CONFIG_SECURITY_SELINUX_DEVELOP=y' 'CONFIG_IKCONFIG_PROC=y' > "$1/boot/config-$UBUNTU_RHIZO"
  run_stub "$1/bin/update-grub" && : > "$1/calls"
}
# create a cachyos host fixture
h_cachyos() {
  add_cachyos_host "$@" || return
  touch "$1/boot/vmlinuz-linux-rhizo" "$1/boot/initramfs-linux-rhizo.img"
  case "${2:-limine}" in
    limine) run_stub "$1/bin/limine-update" ;;
    sdboot) run_stub "$1/bin/sdboot-manage" gen ;;
    grub_inline) run_stub "$1/bin/grub-mkconfig" -o "$1/boot/grub/grub.cfg" ;;
  esac
  : > "$1/calls"
}

DROPIN_HEAD="# Written by install/bootstrap/bootstrap.sh: Rhizo's kernel command line"

# print path mode and md5 per file
manifest() {
  local f
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
     printf '%s %s %s\n' "${f#./}" "$(stat -c %a "$f")" "$(md5sum < "$f" | cut -d' ' -f1)"
   done)
}

# run the bootstrap on a stubbed host
run_on() {
  rm -rf "$R" "$TMP/out" "$TMP/err"; mkdir -p "$R"
  echo "setup failed" > "$TMP/rc"
  (
    export RHIZO_BL_ROOT="$R"
    "$1" "$R" || exit
    manifest "$R" > "$TMP/before"
    boot_run "$R" "$TMP/tools" "$BOOT" "${@:2}" > "$TMP/out" 2> "$TMP/err"
    echo $? > "$TMP/rc"
  )
}

# print the last run's output and changed files
render() {
  local line p m text
  {
    echo "rc=$(< "$TMP/rc")"
    echo "--- stdout"; cat "$TMP/out"
    echo "--- stderr"; cat "$TMP/err"
    echo "--- files"
    manifest "$R" > "$TMP/after"
    while IFS= read -r line; do
      grep -qxF "$line" "$TMP/before" && continue
      read -r p m _ <<<"$line"
      echo "== $p $m"
      cat "$R/$p"
    done < "$TMP/after"
    awk 'NR == FNR {seen[$1]; next} !($1 in seen) {print "== " $1 " removed"}' "$TMP/after" "$TMP/before"
  } > "$TMP/render"
  text=$(< "$TMP/render")
  text=${text//"$BOOT"/@BOOT@}
  text=${text//"$R"/@ROOT@}
  text=${text//"$UBUNTU_TOKENS"/@TOKENS@}
  text=${text//"$UBUNTU_LSM_TOKENS"/@LSM_TOKENS@}
  printf '%s\n' "${text//"$DROPIN_HEAD"/@DROPIN_HEAD@}"
}

# compare a run's render with stdin
expect() {
  local want got
  want=$(cat)
  run_on "${@:2}"
  got=$(render)
  if [[ "$got" == "$want" ]]; then echo "ok   $1"; else echo "FAIL $1"; diff <(echo "$want") <(echo "$got") | sed 's/^/       /'; FAILED=$((FAILED + 1)); fi
}

# run the bootstrap on a root
first_apply() { BOOT_AS_USER='' BOOT_LOOP_MAX='' boot_run "$1" "$TMP/tools" "$BOOT" > /dev/null 2>&1 || { echo "FAIL setup apply on $1"; return 1; }; }

# write the lsm and cmdline files
ubuntu_live() {
  echo lockdown,capability,landlock,yama,selinux,ima,evm > "$1/sys/kernel/security/lsm"
  mkdir -p "$1/sys/fs/selinux"; echo 0 > "$1/sys/fs/selinux/enforce"
  echo Y > "$1/sys/module/zswap/parameters/enabled"
  echo "BOOT_IMAGE=/vmlinuz-$UBUNTU_RHIZO $(sed -n 's/^linux [^ ]* //p' "$1/boot/grub/grub.cfg")" > "$1/proc/cmdline"
  sed -i "s/echo $UBUNTU_RELEASE/echo $UBUNTU_RHIZO/" "$1/bin/uname"
}

# set up a stock ubuntu host
s_stock()        { h_ubuntu "$1"; }
# set up an ubuntu host after a first apply and its reboot
s_live()         { h_ubuntu "$1" && first_apply "$1" && ubuntu_live "$1" && : > "$1/calls"; }
# set up a live ubuntu host whose drop-in was removed and grub regenerated
s_restored()     { s_live "$1" && rm "$1/etc/default/grub.d/90-rhizo.cfg" && run_stub "$1/bin/update-grub" && : > "$1/calls"; }
# set up a live ubuntu host with zswap turned off
s_zswap_off()    { s_live "$1" && echo N > "$1/sys/module/zswap/parameters/enabled"; }
# set up a live ubuntu host booted with an lsm= list and its drop-in removed
s_vm_lsm()     { s_live "$1" && sed -i 's/ security=selinux / lsm=lockdown,capability,landlock,yama,integrity,selinux,bpf /' "$1/proc/cmdline" \
                     && rm "$1/etc/default/grub.d/90-rhizo.cfg" && run_stub "$1/bin/update-grub" && : > "$1/calls"; }
# set up a live ubuntu host booted without zswap.enabled=1 and zswap off
s_no_ztoken()    { s_live "$1" && sed -i 's/ zswap.enabled=1 / /' "$1/proc/cmdline" && echo N > "$1/sys/module/zswap/parameters/enabled"; }
# set up an ubuntu host with no swap
s_no_swap()      { h_ubuntu "$1" && echo "$SWAPS_HEADER" > "$1/proc/swaps" && : > "$1/etc/fstab"; }
# set up a live ubuntu host whose lsm list also holds apparmor
s_apparmor_too() { s_live "$1" && echo lockdown,capability,landlock,yama,selinux,apparmor,ima,evm > "$1/sys/kernel/security/lsm"; }
# set up a host that reads as debian 12
s_debian()       { h_ubuntu "$1" && printf '%s\n' 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"' 'ID=debian' 'VERSION_ID="12"' > "$1/etc/os-release"; }
# set up an ubuntu host with no kernel config in /boot
s_no_kconfig()   { h_ubuntu "$1" && rm "$1/boot/config-$UBUNTU_RELEASE"; }
# set up an ubuntu host with no swap on btrfs
s_btrfs_noswap() { s_no_swap "$1" && add_host_tools "$1" "$UBUNTU_RELEASE" btrfs; }
# set up an ubuntu host whose kernel lacks SELINUX_DEVELOP
s_no_develop()   { h_ubuntu "$1" && printf '%s\n' 'CONFIG_SECURITY_SELINUX=y' '# CONFIG_SECURITY_SELINUX_DEVELOP is not set' > "$1/boot/config-$UBUNTU_RELEASE"; }
# set up an ubuntu host whose kernel config is only in /proc/config.gz
s_proc_config()  { s_no_kconfig "$1" && printf 'CONFIG_SECURITY_SELINUX=y\nCONFIG_SECURITY_SELINUX_DEVELOP=y\n' | gzip > "$1/proc/config.gz"; }
# set up an ubuntu host whose kernel has no selinux
s_kconfig_nose() { h_ubuntu "$1" && printf '%s\n' '# CONFIG_SECURITY_SELINUX is not set' 'CONFIG_SECURITY_APPARMOR=y' > "$1/boot/config-$UBUNTU_RELEASE"; }
# set up an ubuntu host with no /etc/default/grub
s_no_grub()      { h_ubuntu "$1" && rm "$1/etc/default/grub"; }
# set up an ubuntu host with no update-grub
s_no_updgrub()   { h_ubuntu "$1" && rm "$1/bin/update-grub"; }
# set up an ubuntu host whose grub regeneration fails
s_regen_fails()  { h_ubuntu "$1" && : > "$1/regen-fails"; }
# set up an ubuntu host after a first apply whose next regeneration fails
s_reapply_fails() { h_ubuntu "$1" && first_apply "$1" && : > "$1/calls" && : > "$1/regen-fails"; }
# add an ubuntu host with a failing update-grub
s_restore_fails() { h_ubuntu "$1" && stub "$1/bin/update-grub" <<'STUB'
rm "$RHIZO_BL_ROOT/etc/default/grub.d/90-rhizo.cfg" && mkdir "$RHIZO_BL_ROOT/etc/default/grub.d/90-rhizo.cfg"
echo "regeneration failed" >&2; exit 3
STUB
}
# set up an ubuntu host with update-grub and grub-gen only under /usr/sbin
s_sbin_only()    { h_ubuntu "$1" && mkdir -p "$1/usr/sbin" \
                     && mv "$1/bin/update-grub" "$1/bin/grub-gen" "$1/usr/sbin/"; }
# set up an ubuntu host with a grub.d file that sets GRUB_CMDLINE_LINUX
s_overridden()   { h_ubuntu "$1" && printf 'GRUB_CMDLINE_LINUX="console=ttyS0"\n' > "$1/etc/default/grub.d/99-local.cfg"; }

expect "ubuntu first apply on a host without selinux" s_stock <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : absent
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=UUID=abc ro console=tty1 console=ttyS0
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
[rhizo-host-bootstrap] confirmed all 15 tokens present in @ROOT@/boot/grub/grub.cfg
[rhizo-host-bootstrap] made gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc the default boot entry; @ROOT@/var/lib/rhizo/.created-by-install keeps the previous one for the uninstall
[rhizo-host-bootstrap] 
[rhizo-host-bootstrap] An LSM list is a boot-time kernel parameter. There is no live-reconfigure
[rhizo-host-bootstrap] path, so this does not take effect until the machine reboots.
[rhizo-host-bootstrap] After rebooting, confirm with: @BOOT@ --verify
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1
--- stderr
--- files
== boot/grub/grub.cfg 644
set default="${saved_entry}"
linux /vmlinuz root=UUID=abc ro console=ttyS0 @TOKENS@
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-abc' {
	menuentry 'Linux 7.1.0-rc1-rhizo' $menuentry_id_option 'gnulinux-7.1.0-rc1-rhizo-advanced-abc' {
		linux /vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
	}
}
== boot/grub/grubenv 644
# GRUB Environment Block
saved_entry=gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc
== calls 644
update-grub
== etc/default/grub.d/90-rhizo.cfg 644
@DROPIN_HEAD@
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }@TOKENS@"
GRUB_DEFAULT=saved
== var/lib/rhizo/.created-by-install 644
rhizo-kernel-default -
EOF
expect "ubuntu first apply with --lsm-list" s_stock --lsm-list <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : absent
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=UUID=abc ro console=tty1 console=ttyS0
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @LSM_TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
[rhizo-host-bootstrap] confirmed all 15 tokens present in @ROOT@/boot/grub/grub.cfg
[rhizo-host-bootstrap] made gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc the default boot entry; @ROOT@/var/lib/rhizo/.created-by-install keeps the previous one for the uninstall
[rhizo-host-bootstrap] 
[rhizo-host-bootstrap] An LSM list is a boot-time kernel parameter. There is no live-reconfigure
[rhizo-host-bootstrap] path, so this does not take effect until the machine reboots.
[rhizo-host-bootstrap] After rebooting, confirm with: @BOOT@ --verify
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1
--- stderr
--- files
== boot/grub/grub.cfg 644
set default="${saved_entry}"
linux /vmlinuz root=UUID=abc ro console=ttyS0 @LSM_TOKENS@
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-abc' {
	menuentry 'Linux 7.1.0-rc1-rhizo' $menuentry_id_option 'gnulinux-7.1.0-rc1-rhizo-advanced-abc' {
		linux /vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @LSM_TOKENS@
	}
}
== boot/grub/grubenv 644
# GRUB Environment Block
saved_entry=gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc
== calls 644
update-grub
== etc/default/grub.d/90-rhizo.cfg 644
@DROPIN_HEAD@
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }@LSM_TOKENS@"
GRUB_DEFAULT=saved
== var/lib/rhizo/.created-by-install 644
rhizo-kernel-default -
EOF
expect "ubuntu second run on the booted result" s_live <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,selinux,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : present
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux/enforce  : 0
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
[rhizo-host-bootstrap] selinux is already an active LSM, selinuxfs is mounted, zswap is active, and @ROOT@/etc/default/grub.d/90-rhizo.cfg and @ROOT@/boot/grub/grub.cfg carry every token -- nothing to do
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_ALREADY_APPLIED=1
--- stderr
--- files
EOF
expect "ubuntu live with the drop-in removed" s_restored <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,selinux,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : present
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux/enforce  : 0
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
[rhizo-host-bootstrap] this boot already runs selinux and zswap, but the next boot's configuration does not carry them (@ROOT@/etc/default/grub.d/90-rhizo.cfg is absent or differs) -- restoring it
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
[rhizo-host-bootstrap] confirmed all 15 tokens present in @ROOT@/boot/grub/grub.cfg
[rhizo-host-bootstrap] the running kernel already has selinux and zswap, so no reboot is needed for them; the next boot keeps them
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_CONFIG_RESTORED=1
--- stderr
--- files
== boot/grub/grub.cfg 644
set default="${saved_entry}"
linux /vmlinuz root=UUID=abc ro console=ttyS0 @TOKENS@
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-abc' {
	menuentry 'Linux 7.1.0-rc1-rhizo' $menuentry_id_option 'gnulinux-7.1.0-rc1-rhizo-advanced-abc' {
		linux /vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
	}
}
== calls 644
update-grub
== etc/default/grub.d/90-rhizo.cfg 644
@DROPIN_HEAD@
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }@TOKENS@"
GRUB_DEFAULT=saved
EOF
expect "ubuntu selinux live but zswap off" s_zswap_off <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,selinux,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : present
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux/enforce  : 0
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
[rhizo-host-bootstrap] selinux already applied, but zswap.enabled=1 is missing from a prior bootstrap -- rewriting the drop-in to add it
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
[rhizo-host-bootstrap] confirmed all 15 tokens present in @ROOT@/boot/grub/grub.cfg
[rhizo-host-bootstrap] 
[rhizo-host-bootstrap] An LSM list is a boot-time kernel parameter. There is no live-reconfigure
[rhizo-host-bootstrap] path, so this does not take effect until the machine reboots.
[rhizo-host-bootstrap] After rebooting, confirm with: @BOOT@ --verify
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1
--- stderr
--- files
== calls 644
update-grub
EOF
expect "ubuntu live on a cmdline carrying lsm= keeps security=selinux" s_vm_lsm <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,selinux,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : present
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux/enforce  : 0
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @LSM_TOKENS@
[rhizo-host-bootstrap] this boot already runs selinux and zswap, but the next boot's configuration does not carry them (@ROOT@/etc/default/grub.d/90-rhizo.cfg is absent or differs) -- restoring it
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
[rhizo-host-bootstrap] confirmed all 15 tokens present in @ROOT@/boot/grub/grub.cfg
[rhizo-host-bootstrap] the running kernel already has selinux and zswap, so no reboot is needed for them; the next boot keeps them
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_CONFIG_RESTORED=1
--- stderr
--- files
== boot/grub/grub.cfg 644
set default="${saved_entry}"
linux /vmlinuz root=UUID=abc ro console=ttyS0 @TOKENS@
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-abc' {
	menuentry 'Linux 7.1.0-rc1-rhizo' $menuentry_id_option 'gnulinux-7.1.0-rc1-rhizo-advanced-abc' {
		linux /vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
	}
}
== calls 644
update-grub
== etc/default/grub.d/90-rhizo.cfg 644
@DROPIN_HEAD@
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }@TOKENS@"
GRUB_DEFAULT=saved
EOF
expect "ubuntu first apply with no swap provisions a swapfile" s_no_swap <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] provisioning @ROOT@/swapfile (2097152KB)
[rhizo-host-bootstrap] swap active: SwapTotal: 2097148 kB
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : absent
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=UUID=abc ro console=tty1 console=ttyS0
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
[rhizo-host-bootstrap] confirmed all 15 tokens present in @ROOT@/boot/grub/grub.cfg
[rhizo-host-bootstrap] made gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc the default boot entry; @ROOT@/var/lib/rhizo/.created-by-install keeps the previous one for the uninstall
[rhizo-host-bootstrap] 
[rhizo-host-bootstrap] An LSM list is a boot-time kernel parameter. There is no live-reconfigure
[rhizo-host-bootstrap] path, so this does not take effect until the machine reboots.
[rhizo-host-bootstrap] After rebooting, confirm with: @BOOT@ --verify
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1
--- stderr
--- files
== boot/grub/grub.cfg 644
set default="${saved_entry}"
linux /vmlinuz root=UUID=abc ro console=ttyS0 @TOKENS@
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-abc' {
	menuentry 'Linux 7.1.0-rc1-rhizo' $menuentry_id_option 'gnulinux-7.1.0-rc1-rhizo-advanced-abc' {
		linux /vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
	}
}
== boot/grub/grubenv 644
# GRUB Environment Block
saved_entry=gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc
== calls 644
fallocate -l 2097152K @ROOT@/swapfile
mkswap @ROOT@/swapfile
swapon @ROOT@/swapfile
update-grub
== etc/default/grub.d/90-rhizo.cfg 644
@DROPIN_HEAD@
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }@TOKENS@"
GRUB_DEFAULT=saved
== etc/fstab 644
@ROOT@/swapfile none swap sw 0 0
== swapfile 600
allocated 2097152K
SWAPSPACE2
== var/lib/rhizo/.created-by-install 644
swapfile:2049:131:5e3c2a8e-7d41-4b0e-9a55-2f6d1c8b9e07
swapfile-fstab
rhizo-kernel-default -
EOF
expect "ubuntu --verify" s_live --verify <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] post-reboot verification
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,selinux,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : present
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux/enforce  : 0
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
[rhizo-host-bootstrap]   zswap                    : active
[rhizo-host-bootstrap]   swap                     : active (SwapTotal: 2097148 kB)
[rhizo-host-bootstrap] VERIFIED: SELinux is the active exclusive LSM, selinuxfs is mounted, and zswap is active
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_VERIFIED=1
--- stderr
--- files
EOF
expect "ubuntu --verify with apparmor also active" s_apparmor_too --verify <<'EOF'
rc=1
--- stdout
[rhizo-host-bootstrap] post-reboot verification
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,selinux,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : present
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux/enforce  : 0
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
--- stderr
[rhizo-host-bootstrap] FAIL: apparmor is ALSO active
--- files
EOF
expect "ubuntu --verify with zswap off" s_zswap_off --verify <<'EOF'
rc=1
--- stdout
[rhizo-host-bootstrap] post-reboot verification
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,selinux,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : present
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux/enforce  : 0
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
--- stderr
[rhizo-host-bootstrap] FAIL: zswap.enabled=1 was written to the cmdline but @ROOT@/sys/module/zswap/parameters/enabled is not 'Y' after reboot
--- files
EOF
expect "ubuntu --verify on a cmdline without zswap.enabled=1 still checks zswap" s_no_ztoken --verify <<'EOF'
rc=1
--- stdout
[rhizo-host-bootstrap] post-reboot verification
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,selinux,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : present
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux/enforce  : 0
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 security=selinux enforcing=0 loglevel=8 log_buf_len=16M audit_backlog_limit=32768 systemd.unified_cgroup_hierarchy=1 loop.max_loop=64 androidboot.hardware=rhizo androidboot.selinux=permissive androidboot.use_memfd=1 androidboot.first_stage_console=0 androidboot.verifiedbootstate=orange androidboot.veritymode=disabled androidboot.vbmeta.digest=095fdab58d1f3bf532d502403738752341bedbbcd73c38ec1349105d54728b4e
--- stderr
[rhizo-host-bootstrap] FAIL: zswap.enabled=1 was written to the cmdline but @ROOT@/sys/module/zswap/parameters/enabled is not 'Y' after reboot
--- files
EOF
skip_as_root "ubuntu not root" || BOOT_AS_USER=1 expect "ubuntu not root" s_stock <<'EOF'
rc=1
--- stdout
--- stderr
[rhizo-host-bootstrap] FAIL: must run as root (it edits the bootloader configuration)
--- files
EOF
expect "unsupported debian host" s_debian <<'EOF'
rc=1
--- stdout
--- stderr
[rhizo-host-bootstrap] FAIL: this host is 'debian 12' -- Rhizo supports Ubuntu 24.04 and CachyOS
--- files
EOF
expect "ubuntu with no kernel config" s_no_kconfig <<'EOF'
rc=1
--- stdout
--- stderr
[rhizo-host-bootstrap] FAIL: no readable @ROOT@/boot/config-6.8.0-136-generic -- cannot confirm this kernel has CONFIG_SECURITY_SELINUX=y
--- files
EOF
expect "ubuntu btrfs root with no swap provisions a swapfile as before" s_btrfs_noswap <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] provisioning @ROOT@/swapfile (2097152KB)
[rhizo-host-bootstrap] swap active: SwapTotal: 2097148 kB
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : absent
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=UUID=abc ro console=tty1 console=ttyS0
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
[rhizo-host-bootstrap] confirmed all 15 tokens present in @ROOT@/boot/grub/grub.cfg
[rhizo-host-bootstrap] made gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc the default boot entry; @ROOT@/var/lib/rhizo/.created-by-install keeps the previous one for the uninstall
[rhizo-host-bootstrap] 
[rhizo-host-bootstrap] An LSM list is a boot-time kernel parameter. There is no live-reconfigure
[rhizo-host-bootstrap] path, so this does not take effect until the machine reboots.
[rhizo-host-bootstrap] After rebooting, confirm with: @BOOT@ --verify
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1
--- stderr
--- files
== boot/grub/grub.cfg 644
set default="${saved_entry}"
linux /vmlinuz root=UUID=abc ro console=ttyS0 @TOKENS@
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-abc' {
	menuentry 'Linux 7.1.0-rc1-rhizo' $menuentry_id_option 'gnulinux-7.1.0-rc1-rhizo-advanced-abc' {
		linux /vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
	}
}
== boot/grub/grubenv 644
# GRUB Environment Block
saved_entry=gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc
== calls 644
fallocate -l 2097152K @ROOT@/swapfile
mkswap @ROOT@/swapfile
swapon @ROOT@/swapfile
update-grub
== etc/default/grub.d/90-rhizo.cfg 644
@DROPIN_HEAD@
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }@TOKENS@"
GRUB_DEFAULT=saved
== etc/fstab 644
@ROOT@/swapfile none swap sw 0 0
== swapfile 600
allocated 2097152K
SWAPSPACE2
== var/lib/rhizo/.created-by-install 644
swapfile:2049:131:5e3c2a8e-7d41-4b0e-9a55-2f6d1c8b9e07
swapfile-fstab
rhizo-kernel-default -
EOF
expect "ubuntu kernel config without SELINUX_DEVELOP is not refused" s_no_develop <<'EOF'
rc=0
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : absent
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=UUID=abc ro console=tty1 console=ttyS0
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
[rhizo-host-bootstrap] confirmed all 15 tokens present in @ROOT@/boot/grub/grub.cfg
[rhizo-host-bootstrap] made gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc the default boot entry; @ROOT@/var/lib/rhizo/.created-by-install keeps the previous one for the uninstall
[rhizo-host-bootstrap] 
[rhizo-host-bootstrap] An LSM list is a boot-time kernel parameter. There is no live-reconfigure
[rhizo-host-bootstrap] path, so this does not take effect until the machine reboots.
[rhizo-host-bootstrap] After rebooting, confirm with: @BOOT@ --verify
[rhizo-host-bootstrap] RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1
--- stderr
--- files
== boot/grub/grub.cfg 644
set default="${saved_entry}"
linux /vmlinuz root=UUID=abc ro console=ttyS0 @TOKENS@
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-abc' {
	menuentry 'Linux 7.1.0-rc1-rhizo' $menuentry_id_option 'gnulinux-7.1.0-rc1-rhizo-advanced-abc' {
		linux /vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0 @TOKENS@
	}
}
== boot/grub/grubenv 644
# GRUB Environment Block
saved_entry=gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc
== calls 644
update-grub
== etc/default/grub.d/90-rhizo.cfg 644
@DROPIN_HEAD@
GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX:+$GRUB_CMDLINE_LINUX }@TOKENS@"
GRUB_DEFAULT=saved
== var/lib/rhizo/.created-by-install 644
rhizo-kernel-default -
EOF
expect "ubuntu reads only /boot/config-*, never /proc/config.gz" s_proc_config <<'EOF'
rc=1
--- stdout
--- stderr
[rhizo-host-bootstrap] FAIL: no readable @ROOT@/boot/config-6.8.0-136-generic -- cannot confirm this kernel has CONFIG_SECURITY_SELINUX=y
--- files
EOF
expect "ubuntu kernel config without selinux" s_kconfig_nose <<'EOF'
rc=1
--- stdout
--- stderr
[rhizo-host-bootstrap] FAIL: @ROOT@/boot/config-6.8.0-136-generic does not set CONFIG_SECURITY_SELINUX=y -- this kernel cannot do SELinux at all, and no cmdline can change that
--- files
EOF
expect "ubuntu without /etc/default/grub" s_no_grub <<'EOF'
rc=1
--- stdout
--- stderr
[rhizo-host-bootstrap] FAIL: no @ROOT@/etc/default/grub -- this host does not use GRUB
--- files
EOF
expect "ubuntu without update-grub" s_no_updgrub <<'EOF'
rc=1
--- stdout
--- stderr
[rhizo-host-bootstrap] FAIL: no update-grub in any of @ROOT@/usr/bin, @ROOT@/usr/sbin, @ROOT@/bin, @ROOT@/sbin, @ROOT@/usr/local/sbin, @ROOT@/usr/local/bin -- grub2-common is not installed
--- files
EOF
expect "ubuntu update-grub failing" s_regen_fails <<'EOF'
rc=1
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : absent
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=UUID=abc ro console=tty1 console=ttyS0
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
--- stderr
regeneration failed
[rhizo-host-bootstrap] FAIL: update-grub failed
[rhizo-host-bootstrap]   removed @ROOT@/etc/default/grub.d/90-rhizo.cfg, which this run wrote
--- files
== calls 644
update-grub
EOF
expect "ubuntu grub.cfg missing the tokens after update-grub" s_overridden <<'EOF'
rc=1
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : absent
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=UUID=abc ro console=tty1 console=ttyS0
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @TOKENS@
[rhizo-host-bootstrap] running update-grub
[rhizo-host-bootstrap]   Generating grub configuration file ...
--- stderr
[rhizo-host-bootstrap] FAIL: update-grub ran but @ROOT@/boot/grub/grub.cfg is missing: @TOKENS@
[rhizo-host-bootstrap]   removed @ROOT@/etc/default/grub.d/90-rhizo.cfg, which this run wrote
--- files
== boot/grub/grub.cfg 644
set default="${saved_entry}"
linux /vmlinuz root=UUID=abc ro console=ttyS0
submenu 'Advanced options' $menuentry_id_option 'gnulinux-advanced-abc' {
	menuentry 'Linux 7.1.0-rc1-rhizo' $menuentry_id_option 'gnulinux-7.1.0-rc1-rhizo-advanced-abc' {
		linux /vmlinuz-7.1.0-rc1-rhizo root=UUID=abc ro console=ttyS0
	}
}
== calls 644
update-grub
EOF
expect "ubuntu re-run with new tokens and update-grub failing" s_reapply_fails --lsm-list <<'EOF'
rc=1
--- stdout
[rhizo-host-bootstrap] swap already configured: /swap.img file 2097148 0 -2
[rhizo-host-bootstrap] current state:
[rhizo-host-bootstrap]   @ROOT@/sys/kernel/security/lsm : lockdown,capability,landlock,yama,apparmor,ima,evm
[rhizo-host-bootstrap]   @ROOT@/sys/fs/selinux          : absent
[rhizo-host-bootstrap]   @ROOT@/proc/cmdline            : BOOT_IMAGE=/vmlinuz-6.8.0-136-generic root=UUID=abc ro console=tty1 console=ttyS0
[rhizo-host-bootstrap] wrote @ROOT@/etc/default/grub.d/90-rhizo.cfg
[rhizo-host-bootstrap]   tokens: @LSM_TOKENS@
[rhizo-host-bootstrap] running update-grub
--- stderr
regeneration failed
[rhizo-host-bootstrap] FAIL: update-grub failed
[rhizo-host-bootstrap]   put @ROOT@/etc/default/grub.d/90-rhizo.cfg back as it was before this run
--- files
== calls 644
update-grub
EOF
DROPIN_LINE='^etc/default/grub.d/90-rhizo.cfg '
check "ubuntu re-run with new tokens and update-grub failing: the earlier drop-in, byte for byte" \
  "$(grep -c "$DROPIN_LINE" "$TMP/before")|$(grep "$DROPIN_LINE" "$TMP/after")" "1|$(grep "$DROPIN_LINE" "$TMP/before")"
run_on s_restore_fails
DROPIN_PATH="$R/etc/default/grub.d/90-rhizo.cfg"
check "ubuntu update-grub failing and the drop-in not restorable: the FAIL, then why it keeps this run's tokens" \
  "$(< "$TMP/rc")|$(tail -2 "$TMP/err")" "1|[rhizo-host-bootstrap] FAIL: update-grub failed
[rhizo-host-bootstrap]   could not put $DROPIN_PATH back as it was before this run (rm: cannot remove\
 '$DROPIN_PATH': Is a directory; could not restore $DROPIN_PATH) -- it keeps this run's tokens"
run_on s_stock; stock_render=$(render)
run_on s_sbin_only
check "ubuntu with update-grub only under /usr/sbin, off PATH: the stock first apply's render" "$(render)" \
  "$stock_render"

CACHY_LSM=lsm=capability,landlock,lockdown,yama,selinux,bpf
CTOK="$CACHY_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT"
P="[rhizo-host-bootstrap]"
REBOOT_TAIL=$(printf '%s\n' "$P " "$P An LSM list is a boot-time kernel parameter. There is no live-reconfigure" \
  "$P path, so this does not take effect until the machine reboots." "$P After rebooting, confirm with: $BOOT --verify" \
  "$P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1")

# print the linux-cachyos cmdline from limine.conf
default_cmdline() {
  awk '$0 ~ /^ *\/\/linux-cachyos$/ {on = 1} on && /^ *cmdline:/ {sub(/^ *cmdline: */, ""); print; exit}' \
    "$1/boot/limine.conf"
}
# print rhizo's block in /etc/default/limine
limine_block() { sed -n '/^# >>> rhizo$/,/^# <<< rhizo$/p' "$1/etc/default/limine"; }

# print the cmdline of limine's Rhizo kernel entry
rhizo_cmdline() {
  awk '$0 ~ /^ *\/\/linux-rhizo$/ {on = 1} on && /^ *cmdline:/ {sub(/^ *cmdline: */, ""); print; exit}' \
    "$1/boot/limine.conf"
}
# make the stub uname report the Rhizo kernel
boot_rhizo() { sed -i "s/echo $CACHYOS_RELEASE/echo $UBUNTU_RHIZO/" "$1/bin/uname"; }
# write the cmdline and lsm files
cachyos_live() {
  local cmdline
  cmdline=$(rhizo_cmdline "$1")
  boot_rhizo "$1"
  echo "$cmdline" > "$1/proc/cmdline"
  echo capability,landlock,lockdown,yama,selinux,bpf > "$1/sys/kernel/security/lsm"
  mkdir -p "$1/sys/fs/selinux"; echo 0 > "$1/sys/fs/selinux/enforce"
  [[ " $cmdline " != *" binder.devices=binder,hwbinder,vndbinder "* ]] \
    || echo binder,hwbinder,vndbinder > "$1/sys/module/binder/parameters/devices"
  : > "$1/calls"
}
# save copies of the limine files
keep() { cp "$1/etc/default/limine" "$TMP/limine.before" && cp "$1/boot/limine.conf" "$TMP/limine.conf.before"; }
# print same when two files are equal, else differs
same() { cmp -s "$1" "$2" && echo same || echo differs; }

# set up a stock cachyos host with its limine files saved
c_stock()          { h_cachyos "$1" && keep "$1"; }
# write the base with += only
c_append_base()    { h_cachyos "$1" \
                       && limine_default "$1" "$LIMINE_ESP" "KERNEL_CMDLINE[default]+=\"$LIMINE_CMDLINE\"" "$LIMINE_ORDER" \
                       && keep "$1"; }
# set up a live cachyos host with its limine files saved
c_live()           { h_cachyos "$1" && first_apply "$1" && cachyos_live "$1" && keep "$1"; }
# set up a cachyos host whose built-in binder already has devices
c_binder_only()    { h_cachyos "$1" && echo binder > "$1/sys/module/binder/parameters/devices"; }
# set up a live binder host with its limine files saved
c_binder_live()    { c_binder_only "$1" && first_apply "$1" && cachyos_live "$1" && keep "$1"; }
# set up a cachyos host with its cmdline in /etc/kernel/cmdline
c_drops_base()     { h_cachyos "$1" && mkdir -p "$1/etc/kernel" && echo "$LIMINE_CMDLINE" > "$1/etc/kernel/cmdline" \
                       && limine_default "$1" "$LIMINE_ESP" 'KERNEL_CMDLINE[default]=""' "$LIMINE_ORDER" && keep "$1"; }
# set up a cachyos host booted with apparmor in its lsm= list
c_apparmor()       { h_cachyos "$1" \
                       && limine_default "$1" "$LIMINE_ESP" "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE lsm=landlock,lockdown,yama,apparmor,bpf\"" "$LIMINE_ORDER" \
                       && default_cmdline "$1" > "$1/proc/cmdline" \
                       && echo capability,landlock,lockdown,yama,apparmor,bpf > "$1/sys/kernel/security/lsm" \
                       && keep "$1"; }
# set up a cachyos host whose kernel lacks SELINUX_DEVELOP
c_no_develop()     { h_cachyos "$1" && keep "$1" \
                       && printf '%s\n' CONFIG_SECURITY_SELINUX=y '# CONFIG_SECURITY_SELINUX_DEVELOP is not set' | gzip > "$1/proc/config.gz"; }
# set up a host that reads as arch linux
c_arch()           { h_cachyos "$1" && printf '%s\n' 'NAME="Arch Linux"' 'ID=arch' > "$1/etc/os-release"; }
# set up a cachyos host whose limine regeneration fails
c_regen_fails()    { h_cachyos "$1" && keep "$1" && : > "$1/regen-fails"; }
# set up a live cachyos host with a swap file
c_live_swapfile()  { c_live "$1" && printf '%s\n/swapfile file 4194300 0 -2\n' "$SWAPS_HEADER" > "$1/proc/swaps"; }
# add a cachyos host with selinux in lsm=
c_lsm_selinux()    { h_cachyos "$1" \
                       && limine_default "$1" "$LIMINE_ESP" \
                            "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE lsm=landlock,lockdown,yama,selinux,bpf\"" \
                            "$LIMINE_ORDER" \
                       && default_cmdline "$1" > "$1/proc/cmdline" \
                       && echo capability,landlock,lockdown,yama,selinux,bpf > "$1/sys/kernel/security/lsm" \
                       && keep "$1"; }
# set up a live cachyos host with selinux in lsm=
c_lsm_selinux_live() { c_lsm_selinux "$1" && first_apply "$1" && cachyos_live "$1" && keep "$1"; }
# add rhizo's block to the c_apparmor host
c_apparmor_blocked() { c_apparmor "$1" && printf '%s\n' '# >>> rhizo' \
                         "KERNEL_CMDLINE[default]+=\" $RHIZO_LSM $TOKENS_MID $TOKENS_ANDROIDBOOT\"" \
                         '# <<< rhizo' >> "$1/etc/default/limine" && run_stub "$1/bin/limine-update" && : > "$1/calls" \
                         && keep "$1"; }
# boot the c_apparmor_blocked host
c_apparmor_booted() { c_apparmor_blocked "$1" && default_cmdline "$1" > "$1/proc/cmdline"; }
# add a limine host with a swapfile
c_swapfile()       { h_cachyos "$1" \
                       && printf '%s\n/swapfile file 4194300 0 -2\n' "$SWAPS_HEADER" > "$1/proc/swaps" \
                       && keep "$1"; }
# add a grub host with lsm= in GRUB_CMDLINE_LINUX_DEFAULT
c_grub_lsm()       { h_cachyos "$1" grub_inline \
                       && sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\).*/\1'nowatchdog quiet splash lsm=landlock,bpf'/" \
                            "$1/etc/default/grub" && run_stub "$1/bin/grub-mkconfig" -o "$1/boot/grub/grub.cfg" \
                       && : > "$1/calls" && cp "$1/etc/default/grub" "$TMP/grub.before"; }
OTHER_OS=$(limine_os "Arch Linux" 0123456789abcdef0123456789abcdef; limine_entry linux "root=UUID=other rw quiet"; echo)
# set up a cachyos host whose limine.conf also boots a second os
c_second_os()      { h_cachyos "$1" && printf '%s\n' "$OTHER_OS" > "$TMP/other-os" \
                       && awk -v f="$TMP/other-os" '$0 == "/EFI fallback" {while ((getline l < f) > 0) print l}
                                                    {print}' "$1/boot/limine.conf" > "$1/boot/limine.conf.new" \
                       && mv "$1/boot/limine.conf.new" "$1/boot/limine.conf"; }
# add lsm=landlock,bpf to the live host
c_live_host_lsm()  { c_live "$1" \
                       && sed -i 's/^\(KERNEL_CMDLINE\[default\]=".*\)"$/\1 lsm=landlock,bpf"/' \
                            "$1/etc/default/limine" \
                       && run_stub "$1/bin/limine-update" && : > "$1/calls" && keep "$1"; }
# set up a live cachyos host with audit_backlog_limit=64
c_live_host_audit() { c_live "$1" \
                       && sed -i 's/^\(KERNEL_CMDLINE\[default\]=".*\)"$/\1 audit_backlog_limit=64"/' \
                            "$1/etc/default/limine" \
                       && run_stub "$1/bin/limine-update" && : > "$1/calls" && keep "$1"; }
# add an lsm= list to the lts key
c_lts_lsm()        { h_cachyos "$1" && touch "$1/boot/vmlinuz-linux-cachyos-lts" \
                       && limine_default "$1" "$LIMINE_ESP" "$LIMINE_BASE" \
                            "KERNEL_CMDLINE[linux-cachyos-lts]=\"$LIMINE_CMDLINE lsm=landlock,bpf\"" "$LIMINE_ORDER" \
                       && keep "$1"; }
# add a cachyos host and write proc/cmdline
c_voided_booted()  { h_cachyos "$1" \
                       && echo "security=selinux $TOKENS_MID $LIMINE_CMDLINE lsm=landlock,bpf" > "$1/proc/cmdline"; }
# add an empty /sys/fs/selinux directory
c_selinuxfs_dir()  { h_cachyos "$1" && mkdir -p "$1/sys/fs/selinux"; }
# remove the selinuxfs enforce file
c_live_unmounted() { c_live "$1" && rm "$1/sys/fs/selinux/enforce"; }
# set up a live cachyos host whose selinuxfs mount fails
c_live_mount_fails() { c_live_unmounted "$1" && : > "$1/mount-fails"; }
# add another OS entry to an sdboot host
c_sdboot_other()   { h_cachyos "$1" sdboot \
                       && printf 'title Other Linux\noptions root=UUID=0 rw\nlinux /other/vmlinuz\n' \
                       > "$1/boot/loader/entries/other-os.conf"; }
# add a LINUX_OPTIONS drop-in to sdboot-manage.conf.d
c_sdboot_dropin()  { h_cachyos "$1" sdboot && mkdir -p "$1/etc/sdboot-manage.conf.d" \
                       && printf 'LINUX_OPTIONS="nowatchdog quiet splash"\n' \
                            > "$1/etc/sdboot-manage.conf.d/50-local.conf" \
                       && cp "$1/etc/sdboot-manage.conf" "$TMP/sdboot.before"; }
# set up a live cachyos host whose limine block was removed
c_block_removed()  { c_live "$1" && limine_default "$1" "$LIMINE_ESP" "$LIMINE_BASE" "$LIMINE_ORDER"; }
# move the limine base to /etc/kernel/cmdline
c_live_base_blind() { c_live "$1" && mkdir -p "$1/etc/kernel" && echo "$LIMINE_CMDLINE" > "$1/etc/kernel/cmdline" \
                        && sed -i 's/^KERNEL_CMDLINE\[default\]=.*/KERNEL_CMDLINE[default]=""/' "$1/etc/default/limine" && keep "$1"; }
# write limine-update and mv stub scripts
c_restore_breaks() {
  c_live_base_blind "$1" || return
  mv "$1/bin/limine-update" "$1/bin/limine-update.real"
  cat > "$1/bin/limine-update" <<'STUB'
#!/bin/bash
"$RHIZO_BL_ROOT/bin/limine-update.real" "$@"; rc=$?
: > "$RHIZO_BL_ROOT/mv-fails"
exit $rc
STUB
  cat > "$1/bin/mv" <<STUB
#!/bin/bash
[[ ! -e "\$RHIZO_BL_ROOT/mv-fails" ]] || { echo "mv: cannot move" >&2; exit 1; }
exec $(type -P mv) "\$@"
STUB
  chmod +x "$1/bin/limine-update" "$1/bin/mv"
}
# run c_live and write an awk stub
c_live_unreadable() {
  c_live "$1" || return
  printf '#!/bin/bash\ncase "$*" in *Snapshots*) echo "awk: cannot open limine.conf" >&2; exit 2 ;; esac\n' \
    > "$1/bin/awk"
  printf 'exec %q "$@"\n' "$TMP/tools/awk" >> "$1/bin/awk"
  chmod +x "$1/bin/awk"
}
# add a 40_custom entry to grub.cfg
c_grub_custom() {
  h_cachyos "$1" grub_inline || return
  mkdir -p "$1/etc/grub.d"
  printf '%s\n' 'menuentry "rescue" {' '	linux /vmlinuz-rescue root=UUID=abc rw single' '}' > "$1/etc/grub.d/40_custom"
  run_stub "$1/bin/grub-mkconfig" -o "$1/boot/grub/grub.cfg"; : > "$1/calls"
}
# run c_grub_custom and write the boot files
c_grub_custom_live() {
  c_grub_custom "$1" && first_apply "$1" || return
  awk '$1 == "###" && $3 ~ /10_linux/ {on = $2 == "BEGIN"; next}
       on && $1 == "linux" && $2 ~ /rhizo/ {for (i = 3; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "\n"); exit}' \
    "$1/boot/grub/grub.cfg" > "$1/proc/cmdline"
  boot_rhizo "$1"
  echo capability,landlock,lockdown,yama,selinux,bpf > "$1/sys/kernel/security/lsm"
  mkdir -p "$1/sys/fs/selinux"; echo 0 > "$1/sys/fs/selinux/enforce"
  : > "$1/calls"
}
# set up a binder-only cachyos host with selinux in its lsm list
c_binder_pending() { c_binder_only "$1" && echo capability,landlock,lockdown,yama,selinux,bpf > "$1/sys/kernel/security/lsm" \
                       && mkdir -p "$1/sys/fs/selinux" && echo 0 > "$1/sys/fs/selinux/enforce"; }
OLD_TOK="security=selinux $TOKENS_MID $TOKENS_ANDROIDBOOT"
# set up a cachyos host with an older install's limine block
c_old_install()    { h_cachyos "$1" \
                       && printf '%s\n' '# >>> rhizo' "KERNEL_CMDLINE[default]+=\" $OLD_TOK\"" '# <<< rhizo' \
                            >> "$1/etc/default/limine" && run_stub "$1/bin/limine-update" \
                       && default_cmdline "$1" > "$1/proc/cmdline" \
                       && echo capability,landlock,lockdown,yama,bpf,selinux > "$1/sys/kernel/security/lsm" \
                       && mkdir -p "$1/sys/fs/selinux" && echo 0 > "$1/sys/fs/selinux/enforce" \
                       && rm "$1/proc/self/attr/current" && : > "$1/calls" && keep "$1"; }
# remove /proc/self/attr/current from the live host
c_live_attr_fails() { c_live "$1" && rm "$1/proc/self/attr/current"; }
# put bpf ahead of selinux in lsm
c_live_bpf_first() { c_live "$1" && echo capability,landlock,lockdown,yama,bpf,selinux > "$1/sys/kernel/security/lsm"; }

run_on c_stock
check "cachyos first apply: rc"                "$(< "$TMP/rc")" 0
check "cachyos first apply: zram is the swap"  "$(head -1 "$TMP/out")" "$P swap already configured: /dev/zram0 partition 8038396 0 100"
check "cachyos first apply: the apply log"     "$(awk -v s="$P wrote " 'index($0, s) == 1 {on = 1} on' "$TMP/out")" "$P wrote $R/etc/default/limine
$P   tokens: $CTOK
$P running limine-update
$P   Updating limine.conf
$P confirmed all 14 tokens present in $R/boot/limine.conf
$P made CachyOS/linux-rhizo the default boot entry; $R/var/lib/rhizo/.created-by-install keeps the previous one for the uninstall
$REBOOT_TAIL"
check "cachyos first apply: stderr"            "$(< "$TMP/err")" ""
check "cachyos first apply: the marked block ends /etc/default/limine" "$(< "$R/etc/default/limine")" "$LIMINE_ESP
$LIMINE_BASE
$LIMINE_ORDER
# >>> rhizo
KERNEL_CMDLINE[default]+=\" $CTOK\"
# <<< rhizo"
check "cachyos first apply: rhizo's tokens, then the base with root=, as limine-entry-tool composes them" \
  "$(default_cmdline "$R")" "$CTOK $LIMINE_CMDLINE"
check "cachyos first apply: no zswap.enabled=1 on a zram host" "$(grep -c 'zswap.enabled=1' "$R/boot/limine.conf")" 0
check "cachyos first apply: no swapfile made"  "$([[ -e "$R/swapfile" ]] && echo made || echo none)" none

run_on c_append_base
check "cachyos first apply on an append-only base: rc" "$(< "$TMP/rc")" 0
check "cachyos first apply on an append-only base: stderr" "$(< "$TMP/err")" ""
check "cachyos first apply on an append-only base: the block follows the host's line" "$(< "$R/etc/default/limine")" "$LIMINE_ESP
KERNEL_CMDLINE[default]+=\"$LIMINE_CMDLINE\"
$LIMINE_ORDER
# >>> rhizo
KERNEL_CMDLINE[default]+=\" $CTOK\"
# <<< rhizo"
check "cachyos first apply on an append-only base: rhizo's tokens, then the host's" \
  "$(default_cmdline "$R")" "$CTOK $LIMINE_CMDLINE"

run_on c_live
check "cachyos second run: rc and marker"      "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"
check "cachyos second run: says so without zswap" "$(tail -2 "$TMP/out" | head -1)" \
  "$P selinux is already an active LSM, selinuxfs is mounted, and $R/etc/default/limine and $R/boot/limine.conf carry every token -- nothing to do"
check "cachyos second run: /etc/default/limine unchanged" "$(same "$TMP/limine.before" "$R/etc/default/limine")" same
check "cachyos second run: nothing regenerated" "$(ncalls "$R" limine-update)" 0

run_on c_live --verify
check "cachyos --verify on zram: rc"           "$(< "$TMP/rc")" 0
check "cachyos --verify on zram: passes without zswap and says so" "$(tail -4 "$TMP/out")" "$P   zswap                    : not requested (swap is on zram)
$P   swap                     : active (SwapTotal: 8038396 kB)
$P VERIFIED: SELinux is the active exclusive LSM and selinuxfs is mounted
$P RHIZO_BOOTSTRAP_VERIFIED=1"

run_on c_live_swapfile --verify
check "cachyos --verify, no zswap token, swap not on zram: says what it saw" "$(< "$TMP/rc") $(grep -F 'zswap ' "$TMP/out")" \
  "0 $P   zswap                    : not on the cmdline, and no zram swap is active"

run_on c_drops_base
check "cachyos regeneration dropping the base: rc" "$(< "$TMP/rc")" 1
check "cachyos regeneration dropping the base: names the lost tokens and the undo" "$(< "$TMP/err")" \
  "$P FAIL: limine-update ran but $R/boot/limine.conf lost: nowatchdog quiet root=UUID=44444444-4444-4444-8444-444444444444 rootflags=subvol=/@ rw splash zswap.enabled=0 -- put $R/etc/default/limine back as it was and ran limine-update again"
check "cachyos regeneration dropping the base: /etc/default/limine byte-identical" "$(same "$TMP/limine.before" "$R/etc/default/limine")" same
check "cachyos regeneration dropping the base: limine.conf regenerated as it was" "$(same "$TMP/limine.conf.before" "$R/boot/limine.conf")" same
check "cachyos regeneration dropping the base: regenerated twice" "$(ncalls "$R" limine-update)" 2
check "cachyos regeneration dropping the base: both regenerations logged" "$(tail -2 "$TMP/out")" "$P   Updating limine.conf
$P   Updating limine.conf"

run_on c_regen_fails
check "cachyos regeneration failing: rc"       "$(< "$TMP/rc")" 1
check "cachyos regeneration failing: says the undo did not finish and where the file is" "$(< "$TMP/err")" "regeneration failed
regeneration failed
$P FAIL: limine-update failed -- and putting $R/etc/default/limine back did not finish (see above): $R/etc/default/limine no longer carries this run's tokens, and $R/boot/limine.conf has every token besides rhizo's own that the next boot had before this run"
check "cachyos regeneration failing: /etc/default/limine byte-identical" "$(same "$TMP/limine.before" "$R/etc/default/limine")" same

APPARMOR_LSM=lsm=landlock,lockdown,yama,apparmor,bpf
RHIZO_LSM=lsm=capability,landlock,lockdown,yama,selinux,bpf
LSM_OVERRIDE="limine-update ran, but the host's own $APPARMOR_LSM, set by KERNEL_CMDLINE[default] in\
 $R/etc/default/limine, comes after rhizo's $RHIZO_LSM on the next boot's cmdline and leaves selinux out of the LSM\
 list -- remove that lsm= from the host's own line, or add selinux to it"
run_on c_apparmor
check "cachyos whose own lsm= list comes after rhizo's: fails naming it, where it is set and what to do" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" \
  "1|$P FAIL: $LSM_OVERRIDE -- put $R/etc/default/limine back as it was and ran limine-update again"
check "cachyos whose own lsm= list comes after rhizo's: /etc/default/limine as it was" \
  "$(same "$TMP/limine.before" "$R/etc/default/limine")" same
check "cachyos whose own lsm= list comes after rhizo's: limine.conf as it was" \
  "$(same "$TMP/limine.conf.before" "$R/boot/limine.conf")" same
check "cachyos whose own lsm= list comes after rhizo's: no reboot asked for" "$(grep -c REBOOT_REQUIRED "$TMP/out")" 0
run_on c_apparmor_blocked
check "cachyos re-run on such a host carrying rhizo's block: fails the same way, never REBOOT_REQUIRED" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")|$(grep -c REBOOT_REQUIRED "$TMP/out")" \
  "1|$P FAIL: $LSM_OVERRIDE -- put $R/etc/default/limine back as it was and ran limine-update again|0"
run_on c_apparmor_booted --verify
check "cachyos --verify booted with the host's lsm= last: names it as what overrides rhizo's" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: selinux is not in the active LSM list -- $R/proc/cmdline's last\
 lsm=, $APPARMOR_LSM, comes after rhizo's and leaves selinux out of the LSM list; remove that lsm= from the host's own\
 line, or add selinux to it, then run the bootstrap again"
run_on c_voided_booted --verify
check "cachyos --verify booted with the host's lsm= beside rhizo's security=: says it voids it" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: selinux is not in the active LSM list -- $R/proc/cmdline carries\
 lsm=landlock,bpf, which voids rhizo's security=selinux, as the kernel ignores security= beside any lsm=, and leaves\
 selinux out of the LSM list; remove that lsm= from the host's own line, or add selinux to it, then run the bootstrap\
 again"
run_on c_apparmor --verify
check "cachyos --verify booted with only the host's own lsm=: the plain message, as no token of rhizo's is there" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: selinux is not in the active LSM list -- the reboot did not take\
 effect, or the cmdline did not carry it"
run_on c_second_os
check "cachyos with another system's OS entry on the ESP: applied, that entry not read" \
  "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
check "cachyos with another system's OS entry on the ESP: that entry as it was" \
  "$(awk '/^\/\+Arch Linux$/ {on = 1} /^\/EFI fallback$/ {on = 0} on' "$R/boot/limine.conf")" "$OTHER_OS"
run_on c_live_host_lsm
check "cachyos live, its own line since given an lsm= without selinux: fails, never ALREADY_APPLIED" \
  "$(< "$TMP/rc")|$(grep -c ALREADY_APPLIED "$TMP/out")" "1|0"
check "cachyos live, its own line since given an lsm=: says what the next boot lacks, no empty lacks clause" \
  "$(grep -cxF "$P this boot already runs selinux, but the next boot's configuration does not carry it (the host's\
 own lsm=landlock,bpf overrides rhizo's $CACHY_LSM in $R/boot/limine.conf) -- restoring it" "$TMP/out")" 1
run_on c_live_host_audit
check "cachyos live, its own line since given a smaller audit_backlog_limit=: says what the next boot lacks" \
  "$(< "$TMP/rc")|$(grep -cxF "$P this boot already runs selinux, but the next boot's configuration does not carry\
 it (the host's own audit_backlog_limit=64 overrides rhizo's audit_backlog_limit=32768 in $R/boot/limine.conf) --\
 restoring it" "$TMP/out")" "1|1"
run_on c_lts_lsm
check "cachyos two kernels, only linux-cachyos-lts's own key carrying lsm=: fails naming that variable" \
  "$(< "$TMP/rc")|$(grep -c "set by KERNEL_CMDLINE\[linux-cachyos-lts\] in $R/etc/default/limine" "$TMP/err")" "1|1"
# add a 99-local.cfg lsm= drop-in
c_cachy_dropin_lsm() { h_cachyos "$1" grub_inline && add_grub_dropin "$1" \
                         && printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet lsm=landlock,bpf"\n' \
                              > "$1/etc/default/grub.d/99-local.cfg" \
                         && run_stub "$1/bin/update-grub" && : > "$1/calls"; }
RHIZO_BOOTLOADER=grub-dropin run_on c_cachy_dropin_lsm
check "cachyos run as grub-dropin, a later drop-in's lsm=: judged off Ubuntu, so it fails naming that drop-in" \
  "$(< "$TMP/rc")|$(grep -c "GRUB_CMDLINE_LINUX_DEFAULT in $R/etc/default/grub.d/99-local.cfg, comes after" "$TMP/err")" \
  "1|1"
run_on c_selinuxfs_dir
check "cachyos first apply with an empty /sys/fs/selinux and selinux not active: nothing mounted" \
  "$(< "$TMP/rc")|$(grep -c '^mount' "$R/calls")" "0|0"
run_on c_lsm_selinux
check "cachyos whose own lsm= list holds selinux: fine, a reboot asked for" \
  "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
HOST_LSM_SELINUX=lsm=landlock,lockdown,yama,integrity,selinux,bpf
# set up an unbooted cachyos host with selinux in its lsm= list
c_lsm_selinux_unbooted() { h_cachyos "$1" \
                             && limine_default "$1" "$LIMINE_ESP" \
                                  "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE $HOST_LSM_SELINUX\"" "$LIMINE_ORDER" \
                             && keep "$1"; }
# set up that host after a first apply and its reboot
c_lsm_selinux_unbooted_live() { c_lsm_selinux_unbooted "$1" && first_apply "$1" && cachyos_live "$1" && keep "$1"; }
# set HOST_LSM in the HOST_KIND host
c_host_lsm() {
  local r="$1"
  case "$HOST_KIND" in
    limine) h_cachyos "$r" \
              && limine_default "$r" "$LIMINE_ESP" "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE $HOST_LSM\"" \
                   "$LIMINE_ORDER" ;;
    sdboot) h_cachyos "$r" sdboot \
              && sed -i "s/^LINUX_OPTIONS=.*/LINUX_OPTIONS=\"nowatchdog quiet splash $HOST_LSM\"/" \
                   "$r/etc/sdboot-manage.conf" \
              && run_stub "$r/bin/sdboot-manage" gen ;;
    grub|grub_linux)
      local var=GRUB_CMDLINE_LINUX_DEFAULT
      [[ "$HOST_KIND" == grub ]] || var=GRUB_CMDLINE_LINUX
      h_cachyos "$r" grub_inline \
        && sed -i "s/^\($var=\).*/\1'nowatchdog quiet splash $HOST_LSM'/" "$r/etc/default/grub" \
        && run_stub "$r/bin/grub-mkconfig" -o "$r/boot/grub/grub.cfg" ;;
  esac || return
  : > "$r/calls"
}
# write the fake cmdline and lsm files
c_host_lsm_live() {
  local r="$1"
  c_host_lsm "$r" && first_apply "$r" || return
  case "$HOST_KIND" in
    limine) rhizo_cmdline "$r" ;;
    sdboot) sed -n 's/^options //p' "$r/boot/loader/entries/linux-rhizo.conf" ;;
    *) awk '$1 == "linux" && $2 ~ /rhizo/ {for (i = 3; i <= NF; i++) printf "%s%s", $i, (i < NF ? " " : "\n"); exit}' \
         "$r/boot/grub/grub.cfg" ;;
  esac > "$r/proc/cmdline"
  boot_rhizo "$r"
  echo "capability,${HOST_LSM#lsm=}" | sed 's/,integrity//' > "$r/sys/kernel/security/lsm"
  mkdir -p "$r/sys/fs/selinux"; echo 0 > "$r/sys/fs/selinux/enforce"
  : > "$r/calls"
}
run_on c_lsm_selinux_unbooted
check "cachyos whose own line since gained an lsm= holding selinux: rhizo's block takes exactly that list (ruling 61)" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/out")|$(limine_block "$R" | grep -c " $HOST_LSM_SELINUX ")\
|$(limine_block "$R" | grep -c 'security=')" "0|$P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1|1|0"
run_on c_lsm_selinux_unbooted_live
check "cachyos whose own line since gained an lsm= holding selinux: the run after the reboot is ALREADY_APPLIED" \
  "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"
for case in "limine lsm=selinux" "limine lsm=landlock,lockdown,yama,integrity,tomoyo,selinux,bpf" \
            "grub lsm=selinux" "sdboot lsm=landlock,lockdown,yama,integrity,tomoyo,selinux,bpf"; do
  HOST_KIND=${case%% *} HOST_LSM=${case#* }
  run_on c_host_lsm
  check "$HOST_KIND whose own line carries $HOST_LSM: rhizo's LSM token is exactly that" \
    "$(< "$TMP/rc")|$(tail -1 "$TMP/out")|$(grep -cF "$P   tokens: $HOST_LSM " "$TMP/out")" \
    "0|$P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1|1"
  run_on c_host_lsm_live
  check "$HOST_KIND whose own line carries $HOST_LSM: the run after the one reboot is ALREADY_APPLIED" \
    "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"
done
for case in "sdboot lsm=landlock,lockdown,yama,integrity,bpf" "sdboot lsm=landlock,lockdown,yama,integrity,apparmor,bpf" \
            "sdboot lsm=landlock,lockdown,yama,integrity,bpf,selinux" "grub_linux lsm=landlock,lockdown,yama,integrity,bpf"; do
  read -r HOST_KIND HOST_LSM <<<"$case"
  run_on c_host_lsm
  check "$HOST_KIND whose own line carries $HOST_LSM ahead of rhizo's: applied with the active list's order" \
    "$(< "$TMP/rc")|$(tail -1 "$TMP/out")|$(grep -cF "$P   tokens: $CACHY_LSM " "$TMP/out")" \
    "0|$P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1|1"
done
BPF_FIRST=lsm=landlock,lockdown,yama,integrity,bpf,selinux
for case in "limine KERNEL_CMDLINE[default] in $R/etc/default/limine" \
            "grub GRUB_CMDLINE_LINUX_DEFAULT in $R/etc/default/grub"; do
  HOST_KIND=${case%% *} HOST_LSM=$BPF_FIRST
  run_on c_host_lsm
  check "$HOST_KIND whose own line puts bpf before selinux after rhizo's lsm=: refused, naming it and the fix" \
    "$(< "$TMP/rc")|$(grep -cF "the host's own $BPF_FIRST, set by ${case#* }, comes after rhizo's $CACHY_LSM on the\
 next boot's cmdline and puts bpf before selinux, so /proc/<pid>/attr answers EINVAL and no SELinux context can be read\
 or set -- remove that lsm= from the host's own line, or put selinux before bpf in it" "$TMP/err")|$(grep -c \
 REBOOT_REQUIRED "$TMP/out")" "1|1|0"
done
run_on c_swapfile
check "cachyos with swap on a file: the base's own later zswap.enabled=0 wins over rhizo's, and the run says so" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: limine-update ran, but the host's own zswap.enabled=0, set by\
 KERNEL_CMDLINE[default] in $R/etc/default/limine, comes after rhizo's zswap.enabled=1 on the next boot's cmdline and\
 takes effect instead -- remove that zswap.enabled= from the host's own line -- put $R/etc/default/limine back as it\
 was and ran limine-update again"
MODULES_BUILTIN="lib/modules/$CACHYOS_RELEASE/modules.builtin"
# set up a cachyos host with its max_loop=8 in its limine cmdline
c_max_loop()        { h_cachyos "$1" \
                        && limine_default "$1" "$LIMINE_ESP" "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE max_loop=8\"" \
                             "$LIMINE_ORDER" \
                        && keep "$1"; }
# set up that max_loop host with loop built into the kernel
c_max_loop_builtin() { c_max_loop "$1" && mkdir -p "$1/${MODULES_BUILTIN%/*}" \
                         && printf 'kernel/drivers/block/loop.ko\n' > "$1/$MODULES_BUILTIN"; }
# set up that max_loop host with loop as a module
c_max_loop_module() { c_max_loop "$1" && mkdir -p "$1/${MODULES_BUILTIN%/*}" \
                        && printf 'kernel/drivers/block/nbd.ko\n' > "$1/$MODULES_BUILTIN"; }
run_on c_max_loop
check "cachyos with its own max_loop= and no modules.builtin: fails, naming what cannot be read" \
  "$(< "$TMP/rc")|$(grep -cxF "cannot tell whether loop is built into $CACHYOS_RELEASE: $R/$MODULES_BUILTIN cannot be\
 read" "$TMP/err")|$(grep -cF "$P FAIL: cannot check $R/boot/limine.conf for the tokens" "$TMP/err")" "1|1|1"
check "cachyos with its own max_loop= and no modules.builtin: /etc/default/limine as it was" \
  "$(same "$TMP/limine.before" "$R/etc/default/limine")" same
run_on c_max_loop_builtin
check "cachyos with its own max_loop= and loop built in: fails naming it" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: limine-update ran, but the host's own max_loop=8, set by\
 KERNEL_CMDLINE[default] in $R/etc/default/limine, comes after rhizo's loop.max_loop=64 on the next boot's cmdline\
 and asks for less -- remove that max_loop= from the host's own line, or raise it to at least 64 -- put\
 $R/etc/default/limine back as it was and ran limine-update again"
run_on c_max_loop_module
check "cachyos with its own max_loop= and loop a module: fine, a reboot asked for" \
  "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
run_on c_grub_lsm
check "grub whose own GRUB_CMDLINE_LINUX_DEFAULT lsm= follows rhizo's: fails naming it" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: grub-mkconfig ran, but the host's own lsm=landlock,bpf, set by\
 GRUB_CMDLINE_LINUX_DEFAULT in $R/etc/default/grub, comes after rhizo's $CACHY_LSM on the next boot's cmdline and\
 leaves selinux out of the LSM list -- remove that lsm= from the host's own line, or add selinux to it -- put\
 $R/etc/default/grub back as it was and ran grub-mkconfig again"
check "grub whose own lsm= follows rhizo's: /etc/default/grub as it was" \
  "$(same "$TMP/grub.before" "$R/etc/default/grub")" same

run_on c_no_develop
check "cachyos kernel without SELINUX_DEVELOP: refused" "$(< "$TMP/rc") $(< "$TMP/out")$(< "$TMP/err")" \
  "1 $P FAIL: $R/proc/config.gz does not set CONFIG_SECURITY_SELINUX_DEVELOP=y -- enforcing=0 has no effect on this kernel, so the host's own boot would run enforcing under a policy that is not loaded yet"
check "cachyos kernel without SELINUX_DEVELOP: /etc/default/limine untouched" "$(same "$TMP/limine.before" "$R/etc/default/limine")" same

run_on c_arch
check "unsupported arch host: refused"         "$(< "$TMP/rc") $(< "$TMP/out")$(< "$TMP/err")" \
  "1 $P FAIL: this host is 'arch unknown' -- Rhizo supports Ubuntu 24.04 and CachyOS"

run_on c_binder_only
check "cachyos binder naming other devices: binder.devices written" "$(limine_block "$R")" "# >>> rhizo
KERNEL_CMDLINE[default]+=\" $CACHY_LSM $TOKENS_MID binder.devices=binder,hwbinder,vndbinder $TOKENS_ANDROIDBOOT\"
# <<< rhizo"
run_on c_binder_live
check "cachyos binder.devices kept after the reboot: ALREADY_APPLIED" "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"
check "cachyos binder.devices kept after the reboot: /etc/default/limine unchanged" "$(same "$TMP/limine.before" "$R/etc/default/limine")" same

run_on c_binder_pending
check "cachyos selinux live but binder devices not: a reboot, not a restore" "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
check "cachyos selinux live but binder devices not: says why" "$(grep -cxF "$P selinux already applied, but this boot's cmdline lacks: $CACHY_LSM $TOKENS_MID binder.devices=binder,hwbinder,vndbinder $TOKENS_ANDROIDBOOT -- writing them, which take effect at the next boot" "$TMP/out")" 1

# run the bootstrap and check the result
rerun_changes() {
  run_on c_live "${@:4}"
  check "$1: rc and marker"                    "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
  check "$1: says what this boot lacks"        "$(grep -cxF "$P selinux already applied, but this boot's cmdline lacks: $3 -- writing them, which take effect at the next boot" "$TMP/out")" 1
  check "$1: rhizo's block carries the new line" "$(limine_block "$R")" "# >>> rhizo
KERNEL_CMDLINE[default]+=\" $2\"
# <<< rhizo"
  check "$1: the kernel entry is the new line and the base" "$(default_cmdline "$R")" "$2 $LIMINE_CMDLINE"
  check "$1: stderr"                           "$(< "$TMP/err")" ""
}
BOOT_LOOP_MAX=48 rerun_changes "cachyos re-run with loop.max_loop=48" "$CACHY_LSM ${TOKENS_MID/loop.max_loop=64/loop.max_loop=48} $TOKENS_ANDROIDBOOT" \
  loop.max_loop=48
rerun_changes "cachyos re-run with a new vbmeta digest" "$CACHY_LSM $TOKENS_MID ${TOKENS_ANDROIDBOOT%=*}=abcdef0123" \
  androidboot.vbmeta.digest=abcdef0123 --vbmeta-digest abcdef0123
run_on c_live --lsm-list
check "cachyos re-run with --lsm-list: the same list as without, so ALREADY_APPLIED" "$(< "$TMP/rc") $(tail -1 "$TMP/out")" \
  "0 $P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"

run_on c_old_install --verify
check "cachyos --verify booted with selinux behind bpf: fails naming the order and the fix" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: bpf comes before selinux in the active LSM list\
 (capability,landlock,lockdown,yama,bpf,selinux), so /proc/<pid>/attr answers EINVAL and no SELinux context can be\
 read or set -- run the bootstrap again, which writes an lsm= list with selinux ahead of bpf, and reboot"
run_on c_old_install
check "cachyos re-run on an install that wrote security=selinux: rhizo's block takes the list, a reboot asked for" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/out")|$(limine_block "$R" | grep -c " $CACHY_LSM ")|$(limine_block "$R" | grep -c 'security=')" \
  "0|$P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1|1|0"
check "cachyos re-run on an install that wrote security=selinux: says this boot lacks the list" \
  "$(grep -cxF "$P selinux already applied, but this boot's cmdline lacks: $CACHY_LSM -- writing them, which take effect at the next boot" "$TMP/out")" 1
run_on c_live_bpf_first
check "cachyos running rhizo's tokens but selinux behind bpf: not ALREADY_APPLIED" \
  "$(< "$TMP/rc")|$(grep -c ALREADY_APPLIED "$TMP/out")|$(tail -1 "$TMP/out")" "0|0|$P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
check "cachyos running rhizo's tokens but selinux behind bpf: says so" \
  "$(grep -cxF "$P selinux is active, but behind bpf (capability,landlock,lockdown,yama,bpf,selinux) -- the next boot\
 takes the order in rhizo's lsm= list" "$TMP/out")" 1
run_on c_live_attr_fails --verify
check "cachyos --verify where /proc/self/attr/current cannot be read: fails naming it" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: selinux is active but $R/proc/self/attr/current cannot be read\
 (No such file or directory), so no SELinux context can be read or set through /proc/<pid>/attr"
run_on c_live --verify
check "cachyos --verify: reports the context /proc/self/attr/current reads" \
  "$(grep -cxF "$P   $R/proc/self/attr/current : kernel" "$TMP/out")" 1

BASE_LOST="nowatchdog quiet root=UUID=44444444-4444-4444-8444-444444444444 rootflags=subvol=/@ rw splash zswap.enabled=0"
BOOT_LOOP_MAX=48 run_on c_live_base_blind
check "cachyos re-run losing the base: rc"     "$(< "$TMP/rc")" 1
check "cachyos re-run losing the base: names only base tokens, and that the old file drops them too" "$(< "$TMP/err")" \
  "$P FAIL: limine-update ran but $R/boot/limine.conf lost: $BASE_LOST -- put $R/etc/default/limine back as it was and ran limine-update again, but the next boot still lacks: $BASE_LOST"
check "cachyos re-run losing the base: /etc/default/limine byte-identical" "$(same "$TMP/limine.before" "$R/etc/default/limine")" same

BOOT_LOOP_MAX=48 run_on c_restore_breaks
check "cachyos restore failing after a lost base: rc" "$(< "$TMP/rc")" 1
check "cachyos restore failing after a lost base: says which file holds what" "$(tail -1 "$TMP/err")" \
  "$P FAIL: limine-update ran but $R/boot/limine.conf lost: $BASE_LOST -- and putting $R/etc/default/limine back did not finish (see above): $R/etc/default/limine still carries this run's tokens, and $R/boot/limine.conf lacks: $BASE_LOST"
check "cachyos restore failing after a lost base: the restore's own error shown" "$(grep -c "could not restore $R/etc/default/limine" "$TMP/err")" 1

run_on c_live_unreadable
check "cachyos second run, limine.conf unreadable: stops" "$(< "$TMP/rc") $(tail -1 "$TMP/err")" \
  "1 $P FAIL: cannot read the host's own cmdline settings for limine (see above)"
check "cachyos second run, limine.conf unreadable: names it" \
  "$(grep -cxF "cannot read the cmdlines in $R/boot/limine.conf" "$TMP/err")" 1
check "cachyos second run, limine.conf unreadable: /etc/default/limine unchanged" \
  "$(same "$TMP/limine.before" "$R/etc/default/limine")" same
check "cachyos second run, limine.conf unreadable: nothing regenerated" "$(ncalls "$R" limine-update)" 0

run_on c_grub_custom
check "grub with a 40_custom entry lacking rhizo's tokens: confirmed, not missing" \
  "$(< "$TMP/rc") $(tail -1 "$TMP/out")" \
  "0 $P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
check "grub with a 40_custom entry: the custom entry left as it was" "$(grep -c 'single$' "$R/boot/grub/grub.cfg")" 1
run_on c_grub_custom_live
check "grub with a 40_custom entry, second run: ALREADY_APPLIED" "$(< "$TMP/rc") $(tail -1 "$TMP/out")" \
  "0 $P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"
check "grub with a 40_custom entry, second run: nothing regenerated" "$(ncalls "$R" grub-mkconfig)" 0

run_on c_lsm_selinux_live
check "cachyos second run on a host lsm= list holding selinux: ALREADY_APPLIED" "$(< "$TMP/rc") $(tail -1 "$TMP/out")" \
  "0 $P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"
check "cachyos second run on a host lsm= list holding selinux: /etc/default/limine unchanged" \
  "$(same "$TMP/limine.before" "$R/etc/default/limine")" same
check "cachyos second run on a host lsm= list holding selinux: nothing regenerated" "$(ncalls "$R" limine-update)" 0

run_on c_live --verify
check "cachyos --verify with selinuxfs mounted: no mount" "$(< "$TMP/rc")|$(grep -c '^mount' "$R/calls")" "0|0"
run_on c_live_unmounted --verify
check "cachyos --verify on an empty /sys/fs/selinux: mounts selinuxfs there and verifies" \
  "$(< "$TMP/rc")|$(< "$R/calls")|$(tail -1 "$TMP/out")" \
  "0|mount -t selinuxfs selinuxfs $R/sys/fs/selinux|$P RHIZO_BOOTSTRAP_VERIFIED=1"
check "cachyos --verify on an empty /sys/fs/selinux: reports the mounted enforce file" \
  "$(grep -cxF "$P   $R/sys/fs/selinux/enforce  : 0" "$TMP/out")" 1
run_on c_live_mount_fails --verify
check "cachyos --verify where selinuxfs cannot be mounted: fails naming the mount point" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" \
  "1|$P FAIL: selinux is an active LSM but selinuxfs cannot be mounted at $R/sys/fs/selinux"
run_on c_live_unmounted
check "cachyos second run on an empty /sys/fs/selinux: mounts it, then ALREADY_APPLIED, never another reboot" \
  "$(< "$TMP/rc")|$(grep -c '^mount' "$R/calls")|$(tail -1 "$TMP/out")" "0|1|$P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1"

run_on c_sdboot_other
check "sdboot with another OS's entry: applied, the other entry left alone" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/out")|$(grep -c 'androidboot' "$R/boot/loader/entries/other-os.conf")" \
  "0|$P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1|0"
check "sdboot with another OS's entry: gen printed nothing, so no empty line stands for it" \
  "$(grep -cxF "$P   " "$TMP/out")" 0
run_on c_sdboot_dropin
check "sdboot whose drop-in keeps the tokens out: names the entry, and rolls back without an empty line" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")|$(grep -cxF "$P   " "$TMP/out")" \
  "1|$P FAIL: sdboot-manage gen ran but $R/boot/loader/entries/linux-cachyos.conf is missing: $CTOK and\
 $R/boot/loader/entries/linux-rhizo.conf is missing: $CTOK -- put\
 $R/etc/sdboot-manage.conf back as it was and ran sdboot-manage gen again|0"
check "sdboot whose drop-in keeps the tokens out: sdboot-manage.conf as it was" \
  "$(same "$TMP/sdboot.before" "$R/etc/sdboot-manage.conf")" same

run_on c_block_removed
check "cachyos block removed on the running boot: CONFIG_RESTORED" "$(< "$TMP/rc") $(tail -1 "$TMP/out")" "0 $P RHIZO_BOOTSTRAP_CONFIG_RESTORED=1"
check "cachyos block removed on the running boot: says so" "$(grep -cxF "$P this boot already runs selinux, but the next boot's configuration does not carry it ($R/etc/default/limine is absent or differs) -- restoring it" "$TMP/out")" 1
check "cachyos block removed on the running boot: the kernel entry is whole again" "$(default_cmdline "$R")" \
  "$CTOK $LIMINE_CMDLINE"

RHIZO_ENTRY="gnulinux-advanced-abc>gnulinux-$UBUNTU_RHIZO-advanced-abc"
NS_RECORD="rhizo-kernel-default -${NL}selinux-mode namespace"
# set up namespace mode on a stock ubuntu host
n_stock()     { add_ubuntu_host "$1" && touch "$1/boot/vmlinuz-$UBUNTU_RHIZO" && run_stub "$1/bin/update-grub" \
                  && echo namespace > "$1/selinux-mode" && : > "$1/calls"; }
# set up namespace mode over a host-mode install
n_from_host() { add_ubuntu_host "$1" && touch "$1/boot/vmlinuz-$UBUNTU_RHIZO" && run_stub "$1/bin/update-grub" && first_apply "$1" \
                  && echo namespace > "$1/selinux-mode" && : > "$1/calls"; }
# boot the Rhizo kernel after a namespace-mode apply
n_live()      { n_stock "$1" && first_apply "$1" && sed -i "s/echo $UBUNTU_RELEASE/echo $UBUNTU_RHIZO/" "$1/bin/uname" \
                  && echo "BOOT_IMAGE=/vmlinuz-$UBUNTU_RHIZO $(sed -n "s|^[[:space:]]*linux /vmlinuz-$UBUNTU_RHIZO ||p" \
                       "$1/boot/grub/grub.cfg")" > "$1/proc/cmdline" \
                  && echo Y > "$1/sys/module/zswap/parameters/enabled" && : > "$1/calls"; }
# move the booted result's default to the stock kernel
n_live_moved() { n_live "$1" && "$1/bin/grub-editenv" "$1/boot/grub/grubenv" set saved_entry=0; }
# boot the namespace-mode result on a refused kernel
n_live_refused() { n_live "$1" && echo refuse:no-selinuxns > "$1/selinux-mode-running" \
                     && echo "this kernel has no SELinux namespaces" > "$1/selinux-mode-why"; }
# boot the refused result and record the mode helper's calls
n_live_refused_argv() { n_live_refused "$1" && : > "$1/selinux-mode-argv"; }
# set up namespace mode without the Rhizo kernel
n_no_kernel() { add_ubuntu_host "$1" && echo namespace > "$1/selinux-mode"; }
# set up namespace mode on a kernel without selinux
n_kconfig_nose() { n_stock "$1" && printf '%s\n' '# CONFIG_SECURITY_SELINUX is not set' > "$1/boot/config-$UBUNTU_RELEASE"; }
# set up namespace mode on a cachyos limine host
n_cachyos()   { add_cachyos_host "$1" && touch "$1/boot/vmlinuz-linux-rhizo" "$1/boot/initramfs-linux-rhizo.img" \
                  && run_stub "$1/bin/limine-update" && echo namespace > "$1/selinux-mode" && : > "$1/calls"; }
NS_DROPIN="$R/etc/default/grub.d/90-rhizo.cfg"
# print whether a file exists
gone_or_present() { [[ -e "$1" ]] && echo present || echo absent; }

run_on n_stock
check "ubuntu namespace first apply: REBOOT_REQUIRED naming the Rhizo kernel" \
  "$(< "$TMP/rc")|$(tail -4 "$TMP/out" | head -2)" "0|$P Android runs only on the Rhizo kernel, the default boot entry now, and
$P its cmdline takes effect when that kernel boots: reboot into it."
check "ubuntu namespace first apply: no security= or enforcing= in the drop-in or grub.cfg" \
  "$(grep -c 'security=\|enforcing=\|lsm=' "$NS_DROPIN" "$R/boot/grub/grub.cfg")" "$NS_DROPIN:0
$R/boot/grub/grub.cfg:0"
check "ubuntu namespace first apply: GRUB boots the saved entry, the Rhizo kernel" \
  "$(tail -1 "$NS_DROPIN")|$(grep -c '^set default="${saved_entry}"$' "$R/boot/grub/grub.cfg")|$(cat "$R/boot/grub/grubenv")" \
  "GRUB_DEFAULT=saved|1|# GRUB Environment Block
saved_entry=$RHIZO_ENTRY"
check "ubuntu namespace first apply: the record keeps no previous saved entry and the mode" \
  "$(grep -v '^swapfile' "$R/var/lib/rhizo/.created-by-install")" "$NS_RECORD"
check "ubuntu namespace first apply: selinuxfs never mounted" "$(grep -c '^mount' "$R/calls")" 0
run_on n_kconfig_nose
check "ubuntu namespace on a kernel without selinux: not refused, the stock kernel's config is not Rhizo's" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/out")" "0|$P RHIZO_BOOTSTRAP_REBOOT_REQUIRED=1"
run_on n_from_host
check "ubuntu namespace over a host-mode install: the host-mode tokens rewritten away" \
  "$(< "$TMP/rc")|$(grep -c 'security=selinux\|enforcing=0' "$NS_DROPIN" "$R/boot/grub/grub.cfg" | tr '\n' ' ')" \
  "0|$NS_DROPIN:0 $R/boot/grub/grub.cfg:0 "
check "ubuntu namespace over a host-mode install: the Rhizo kernel made the default" \
  "$(grep '^saved_entry=' "$R/boot/grub/grubenv")" "saved_entry=$RHIZO_ENTRY"
run_on n_live
check "ubuntu namespace second run on the booted result: ALREADY_APPLIED, the default left alone" \
  "$(< "$TMP/rc")|$(tail -2 "$TMP/out" | tr '\n' ' ')|$(grep -c '^rhizo-kernel-default' "$R/var/lib/rhizo/.created-by-install")" \
  "0|$P the Rhizo kernel runs, zswap is active, and $NS_DROPIN and $R/boot/grub/grub.cfg carry every token -- nothing to\
 do $P RHIZO_BOOTSTRAP_ALREADY_APPLIED=1 |1"
run_on n_live --verify
check "ubuntu namespace --verify on the booted result: VERIFIED" "$(< "$TMP/rc")|$(tail -2 "$TMP/out" | tr '\n' ' ')" \
  "0|$P VERIFIED: the Rhizo kernel is the default boot entry and runs Android in selinux namespace mode, and zswap is\
 active $P RHIZO_BOOTSTRAP_VERIFIED=1 "
run_on n_live_moved --verify
check "ubuntu namespace --verify with the stock kernel as the default: fails naming the entry" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: the default boot entry is '0', not the Rhizo kernel -- choose the\
 Rhizo kernel in the boot menu, or run the bootstrap again"
run_on n_live_refused --verify
check "ubuntu namespace --verify on a kernel the mode check refuses: fails with its reason" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")" "1|$P FAIL: this boot cannot start Android in selinux namespace mode: this\
 kernel has no SELinux namespaces (refuse:no-selinuxns)"
run_on n_live_refused_argv --verify
check "ubuntu namespace --verify on a refused kernel: asks the mode helper once for the mode and its reason" \
  "$(grep -v -- '--configured' "$R/selinux-mode-argv")" "--env-file /etc/rhizo/androidd.env --mode-and-why"
run_on n_no_kernel
check "ubuntu namespace with no Rhizo kernel installed: fails naming it" \
  "$(< "$TMP/rc")|$(tail -2 "$TMP/err" | tr '\n' ' ')" "1|$R/boot/grub/grub.cfg lists no Rhizo kernel entry -- is the\
 Rhizo kernel installed? $P FAIL: cannot make the Rhizo kernel the default boot entry (see above) "
check "ubuntu namespace with no Rhizo kernel installed: refused before any write" \
  "$(gone_or_present "$NS_DROPIN"):$(grep -c . "$R/calls")" "absent:0"
# switch a namespace-mode ubuntu host back to host mode
n_to_host()   { n_stock "$1" && first_apply "$1" && echo host > "$1/selinux-mode" && : > "$1/calls"; }
run_on n_to_host
check "ubuntu switched back to host mode: the host-mode tokens written, GRUB still boots the saved Rhizo kernel entry, the namespace line dropped" \
  "$(< "$TMP/rc")|$(grep -c 'security=selinux enforcing=0' "$NS_DROPIN")|$(grep -c GRUB_DEFAULT=saved "$NS_DROPIN")|$(grep -v \
     '^swapfile' "$R/var/lib/rhizo/.created-by-install")" "0|1|1|rhizo-kernel-default -"
# switch the host-mode result to namespace mode again
n_to_ns()     { n_to_host "$1" && first_apply "$1" && echo namespace > "$1/selinux-mode" && : > "$1/calls"; }
run_on n_to_ns
check "ubuntu switched to namespace mode again: the line back, the recorded default kept" \
  "$(< "$TMP/rc")|$(grep -c 'security=\|enforcing=' "$NS_DROPIN")|$(grep -v '^swapfile' \
     "$R/var/lib/rhizo/.created-by-install")" "0|0|rhizo-kernel-default -${NL}selinux-mode namespace"
# remove the mode helper the bootstrap reads
n_no_helper() { n_stock "$1" && rm "$1/bin/rhizo-selinux-mode"; }
run_on n_no_helper
check "a missing mode helper: refused before any write, named" \
  "$(< "$TMP/rc")|$(tail -1 "$TMP/err")|$(gone_or_present "$NS_DROPIN")" \
  "1|$P FAIL: cannot read the configured SELinux mode from $R/bin/rhizo-selinux-mode|absent"
# make the mode helper fail
n_bad_helper() { n_stock "$1" && printf '#!/bin/bash\necho "rhizo-selinux-mode: broken" >&2\nexit 255\n' \
                   > "$1/bin/rhizo-selinux-mode"; }
run_on n_bad_helper
check "a failing mode helper: refused before any write, its own message shown" \
  "$(< "$TMP/rc")|$(tr '\n' ' ' < "$TMP/err")|$(gone_or_present "$NS_DROPIN")" \
  "1|rhizo-selinux-mode: broken $P FAIL: cannot read the configured SELinux mode from $R/bin/rhizo-selinux-mode |absent"
run_on n_cachyos
check "cachyos namespace first apply: no lsm= or enforcing= on any kernel entry, the Rhizo kernel remembered" \
  "$(< "$TMP/rc")|$(grep -c 'lsm=\|enforcing=' "$R/boot/limine.conf")|$(tail -c +5 \
     "$R/sys/firmware/efi/efivars/LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a" | tr -d '\0')" \
  "0|0|CachyOS/linux-rhizo"
check "cachyos namespace first apply: the record keeps the stock kernel as the previous default" \
  "$(cat "$R/var/lib/rhizo/.created-by-install")" "rhizo-kernel-default CachyOS/linux-cachyos
selinux-mode namespace"
# set up host mode without the Rhizo kernel
h_no_kernel() { add_ubuntu_host "$1"; }
run_on h_no_kernel
check "ubuntu host mode with no Rhizo kernel installed: fails naming it" \
  "$(< "$TMP/rc")|$(tail -2 "$TMP/err" | tr '\n' ' ')" "1|$R/boot/grub/grub.cfg lists no Rhizo kernel entry -- is the\
 Rhizo kernel installed? $P FAIL: cannot make the Rhizo kernel the default boot entry (see above) "
check "ubuntu host mode with no Rhizo kernel installed: refused before any write" \
  "$(gone_or_present "$NS_DROPIN"):$(grep -c . "$R/calls")" "absent:0"
run_on c_stock
check "cachyos host mode first apply: the Rhizo kernel remembered" \
  "$(< "$TMP/rc")|$(tail -c +5 "$R/sys/firmware/efi/efivars/LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a" \
     | tr -d '\0')" "0|CachyOS/linux-rhizo"
check "cachyos host mode first apply: the record keeps the stock kernel as the previous default" \
  "$(cat "$R/var/lib/rhizo/.created-by-install")" "rhizo-kernel-default CachyOS/linux-cachyos"

SKIP_NOTE=""; (( SKIPPED )) && SKIP_NOTE=", $SKIPPED skipped as root"
(( FAILED )) && { echo "$FAILED failed$SKIP_NOTE"; exit 1; }
echo "test-bootstrap-flows: ok$SKIP_NOTE"
