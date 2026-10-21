#!/bin/bash
# define fixtures for the bootloader tests

LIMINE_ESP='ESP_PATH="/boot"'
LIMINE_BASE='KERNEL_CMDLINE[default]="splash quiet zswap.enabled=0 nowatchdog rw rootflags=subvol=/@ root=UUID=44444444-4444-4444-8444-444444444444"'
LIMINE_ORDER='BOOT_ORDER="*, *lts, *fallback, Snapshots"'
LIMINE_CMDLINE="splash quiet zswap.enabled=0 nowatchdog rw rootflags=subvol=/@ root=UUID=44444444-4444-4444-8444-444444444444"

# print the opening lines of a stub script
bl_fix_preamble() {
  cat <<'PREAMBLE'
echo "${0##*/}" >> "$RHIZO_BL_ROOT/calls"
[[ ! -e "$RHIZO_BL_ROOT/regen-fails" ]] || { echo "regeneration failed" >&2; exit 3; }
PREAMBLE
}
# write an executable stub script
stub() {
  { echo '#!/bin/bash'; bl_fix_preamble; cat; } > "$1"
  chmod +x "$1"
}
# run a stub script quietly
run_stub() {
  PATH="${1%/*}:$PATH" "$@" >/dev/null 2>&1 || { echo "FAIL fixture stub ${1##*/} exited $?"; exit 1; }
}
# count the lines in a calls file that equal a given text
ncalls() { grep -c "^$2\$" "$1/calls"; }
# print the last lines of a grub stub
bl_fix_grub_write() {
  cat <<'WRITE'
opts=${entry#linux * }
for k in "$RHIZO_BL_ROOT"/boot/vmlinuz-*rhizo "$RHIZO_BL_ROOT"/boot/vmlinuz-*-generic; do
  [[ -e "$k" ]] || continue
  rel=${k##*/vmlinuz-}
  entry+=$'\n'"submenu 'Advanced options' \$menuentry_id_option 'gnulinux-advanced-abc' {"
  entry+=$'\n'"	menuentry 'Linux $rel' \$menuentry_id_option 'gnulinux-$rel-advanced-abc' {"
  entry+=$'\n'"		linux /vmlinuz-$rel $opts"$'\n'"	}"$'\n'"}"
done
{
  if [[ "${GRUB_DEFAULT:-}" == saved ]]; then echo 'set default="${saved_entry}"'
  elif [[ -n "${GRUB_DEFAULT:-}" ]]; then echo "set default=\"$GRUB_DEFAULT\""; fi
  if [[ -f "$RHIZO_BL_ROOT/etc/grub.d/40_custom" ]]; then
    printf '%s\n' "### BEGIN /etc/grub.d/10_linux ###" "$entry" "### END /etc/grub.d/10_linux ###" \
      "### BEGIN /etc/grub.d/40_custom ###" "$(< "$RHIZO_BL_ROOT/etc/grub.d/40_custom")" \
      "### END /etc/grub.d/40_custom ###"
  else
    echo "$entry"
  fi
} > "$out"
WRITE
}
# write a grub-editenv stub
add_grub_editenv() {
  cat > "$1/bin/grub-editenv" <<'STUB'
#!/bin/bash
f=$1 op=$2; shift 2
[[ -e "$f" ]] || echo '# GRUB Environment Block' > "$f"
for kv; do
  grep -v "^${kv%%=*}=" "$f" > "$f.new"
  [[ "$op" != set ]] || echo "$kv" >> "$f.new"
  mv "$f.new" "$f"
done
STUB
  chmod +x "$1/bin/grub-editenv"
}
# write a chattr stub and the EFI variable directory
add_efivars() {
  mkdir -p "$1/sys/firmware/efi/efivars"
  printf '#!/bin/bash\nexit 0\n' > "$1/bin/chattr"
  chmod +x "$1/bin/chattr"
}
# write an EFI variable holding NUL-terminated text
efivar_put() {
  printf '\007\000\000\000%s\000' "$2" > "$1/sys/firmware/efi/efivars/$3"
}
# link usr/bin and usr/sbin to bin
link_usr() { mkdir -p "$1/usr"; ln -s ../bin "$1/usr/bin"; ln -s ../bin "$1/usr/sbin"; }

LIMINE_MID=2dd58b8daf034264b2e97f1b76353ff6
# create a limine fixture with a limine-update stub
add_limine() {
  mkdir -p "$1/boot/EFI/BOOT" "$1/boot/loader"
  touch "$1/boot/vmlinuz-linux-cachyos" "$1/boot/initramfs-linux-cachyos.img"
  echo "$LIMINE_MID" > "$1/etc/machine-id"
  printf '%s\n' "$LIMINE_ESP" "$LIMINE_BASE" "$LIMINE_ORDER" > "$1/etc/default/limine"
  printf 'timeout: 5\n/+CachyOS\n  //linux-cachyos\n  protocol: linux\n  cmdline: quiet root=UUID=old\n' \
    > "$1/boot/limine.conf.old"
  stub "$1/bin/limine-update" <<'STUB'
if [[ ! -s "$RHIZO_BL_ROOT/etc/machine-id" ]]; then
  echo "Generating machine-id at /etc/machine-id..."
  printf 7f51fccaf8a54cdb858f4e8cfd3fee90 > "$RHIZO_BL_ROOT/etc/machine-id"
fi
echo "Updating limine.conf" >&2
esp=$(awk '/^[[:space:]]*ESP_PATH[[:space:]]*=/ {v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/"$/, "", v)
  sub(/^"/, "", v)} END {print v}' $(for f in "$RHIZO_BL_ROOT"/usr/share/limine-entry-tool.d/*.conf \
  "$RHIZO_BL_ROOT/etc/limine-entry-tool.conf" "$RHIZO_BL_ROOT"/etc/limine-entry-tool.d/*.conf; do
  [[ ! -f "$f" ]] || echo "$f"; done) "$RHIZO_BL_ROOT/etc/default/limine") || exit 4
conf="$RHIZO_BL_ROOT${esp:-/boot}/limine.conf" snaps="" mid=$(< "$RHIZO_BL_ROOT/etc/machine-id")
# print the OS entry for this machine id
own_node() {
  awk -v mid="$mid" '/^\/[^\/]/ {if (n) exit; head = $0; next}
    (" " $0 " ") ~ ("[[:space:]]machine-id=" mid "[[:space:]]") && head != "" {n = 1; print head}
    n {print}' "$conf"
}
[[ ! -f "$conf" ]] || snaps=$(own_node | sed -n '/^[[:space:]]*\/\/Snapshots$/,/^$/p')
parsed=$(awk '/^[[:space:]]*#/ {next}
  match($0, /^[[:space:]]*KERNEL_CMDLINE\[[^]]*\]\+?=/) {
    h = substr($0, RSTART, RLENGTH); v = substr($0, RLENGTH + 1)
    k = h; sub(/^[[:space:]]*KERNEL_CMDLINE\[/, "", k); sub(/\].*/, "", k); gsub(/["\047]/, "", k)
    sub(/[[:space:]]+$/, "", v); if (length(v) > 1 && v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
    print (h ~ /\+=$/ ? "+" : "=") "\t" k "\t" v }' $(for f in "$RHIZO_BL_ROOT"/usr/share/limine-entry-tool.d/*.conf \
      "$RHIZO_BL_ROOT/etc/limine-entry-tool.conf" "$RHIZO_BL_ROOT"/etc/limine-entry-tool.d/*.conf; do
      [[ ! -f "$f" ]] || echo "$f"; done) "$RHIZO_BL_ROOT/etc/default/limine") || exit 4
has_key() { grep -q "^.$(printf '\t')$1$(printf '\t')" <<<"$parsed"; }
fallback=$(awk '/^[[:space:]]*MKINITCPIO_FALLBACK[[:space:]]*=/ {v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
  sub(/"$/, "", v); sub(/^"/, "", v)} END {print v}' $(for f in "$RHIZO_BL_ROOT"/usr/share/limine-entry-tool.d/*.conf \
  "$RHIZO_BL_ROOT/etc/limine-entry-tool.conf" "$RHIZO_BL_ROOT"/etc/limine-entry-tool.d/*.conf; do
  [[ ! -f "$f" ]] || echo "$f"; done) "$RHIZO_BL_ROOT/etc/default/limine") || exit 4
cmdline_of() {  # print the cmdline for a key
  local op k v cl=""
  while IFS=$'\t' read -r op k v; do
    [[ "$k" == "$1" ]] || continue
    if [[ "$op" == + ]]; then cl="$v${cl:+${v:+ }$cl}"; else cl=$v; fi
  done <<<"$parsed"
  echo "$cl"
}
{
  printf '%s\n' "/+CachyOS" "### This OS entry is auto-generated by limine-entry-tool" "comment: CachyOS" \
    "comment: machine-id=$mid order-priority=50 "
  for k in "$RHIZO_BL_ROOT"/boot/vmlinuz-*; do
    [[ -e "$k" ]] || continue
    name=${k##*/vmlinuz-}
    for entry in "$name" ${fallback:+"$name-fallback"}; do
      [[ "$entry" == "$name" || "$fallback" == yes || "$fallback" == "$name" ]] || continue
      key=default
      if has_key "$name"; then key=$name; fi
      if [[ "$entry" != "$name" ]] && has_key fallback; then key=fallback; fi
      cl=$(cmdline_of "$key")
      [[ -n "$cl" || ! -f "$RHIZO_BL_ROOT/etc/kernel/cmdline" ]] || cl=$(< "$RHIZO_BL_ROOT/etc/kernel/cmdline")
      printf '%s\n' "  //$entry" "  ### This kernel entry is auto-generated by limine-entry-tool" \
        "  comment: kernel-id=$entry " "  protocol: linux" "  path: boot():/$mid/$name/vmlinuz" "  cmdline: $cl" ""
    done
  done
  [[ -z "$snaps" ]] || printf '%s\n\n' "$snaps"
} > "$conf.own"
[[ -f "$conf" ]] || printf '%s\n' "# Limine boot loader configuration" "timeout: 5" "remember_last_entry: yes" "" \
  "/EFI fallback" "### This EFI entry is auto-generated by limine-entry-tool" "comment: Default EFI loader" \
  "comment: order-priority=10 " "protocol: efi" "path: boot():/EFI/BOOT/BOOTX64.EFI" > "$conf"
awk -v mid="$mid" -v ownf="$conf.own" '
  function own_out(   l) { if (!done) { while ((getline l < ownf) > 0) print l; done = 1 } }
  function flush(   i) { if (isown && !seen++) own_out(); else for (i = 1; i <= n; i++) print buf[i]; n = 0; isown = 0 }
  /^\/[^\/]/ { if (innode) flush(); innode = 1; if ($0 == "/EFI fallback") own_out() }
  !innode { print; next }
  { buf[++n] = $0 }
  (" " $0 " ") ~ ("[[:space:]]machine-id=" mid "[[:space:]]") { isown = 1 }
  END { if (innode) flush(); own_out() }' "$conf" > "$conf.new" || exit 4
mv "$conf.new" "$conf" && rm "$conf.own"
STUB
  run_stub "$1/bin/limine-update"
  add_efivars "$1"
  efivar_put "$1" CachyOS/linux-cachyos LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a
  : > "$1/calls"
}
# move a limine host's ESP_PATH and its limine.conf to a directory
limine_move_esp() {
  mkdir -p "$1$2"
  mv "$1/boot/limine.conf" "$1$2/limine.conf"
  sed -i "s|^ESP_PATH=.*|ESP_PATH=\"$2\"|" "$1/etc/default/limine"
}
# write /etc/default/limine and run limine-update
limine_default() {
  local root="$1"; shift
  printf '%s\n' "$@" > "$root/etc/default/limine"
  run_stub "$root/bin/limine-update"
  : > "$root/calls"
}
# print a limine.conf OS entry header
limine_os() {
  printf '%s\n' "/+$1" "### This OS entry is auto-generated by limine-entry-tool" \
    "comment: machine-id=${2:-$LIMINE_MID}"
}
# print a limine.conf kernel entry
limine_entry() {
  printf '%s\n' "  //$1" "  ### This kernel entry is auto-generated by limine-entry-tool" "  protocol: linux" \
    "  cmdline: $2"
}
# add a snapshot subtree to limine.conf
limine_snapper_sync() {
  local conf="$1/boot/limine.conf"
  printf '%s\n' "     //Snapshots" "     ### Auto-generated by limine-snapper-sync" "     comment: 1 snapshots" \
    "     ///2 │ 2026-10-03 20:55:08" "     comment: Fresh CachyOS Installation" "     ////linux-cachyos" \
    "     protocol: linux" "     cmdline: ${LIMINE_CMDLINE/subvol=\/@/subvol=/@/.snapshots/2/snapshot}" "" \
    > "$conf.snaps"
  awk -v f="$conf.snaps" -v mid="$LIMINE_MID" '
    function put(   l) { while ((getline l < f) > 0) print l; own = 0 }
    /^\/[^\/]/ && own { put() }
    (" " $0 " ") ~ ("[[:space:]]machine-id=" mid "[[:space:]]") { own = 1 }
    { print }
    END { if (own) put() }' "$conf" > "$conf.new" && mv "$conf.new" "$conf" && rm "$conf.snaps"
}

# create an sdboot fixture with an sdboot-manage stub
add_sdboot() {
  mkdir -p "$1/boot/loader/entries"
  touch "$1/boot/vmlinuz-linux-cachyos" "$1/boot/initramfs-linux-cachyos.img"
  printf 'LINUX_OPTIONS="nowatchdog quiet splash"\nREMOVE_EXISTING="no"\n' > "$1/etc/sdboot-manage.conf"
  stub "$1/bin/sdboot-manage" <<'STUB'
[[ "$1" == gen ]] || exit 2
LINUX_OPTIONS="" LINUX_FALLBACK_OPTIONS="" DISABLE_FALLBACK=no KERNEL_PATTERN="vmlinuz-*" INITRD_PREFIX=initramfs
. "$RHIZO_BL_ROOT/etc/sdboot-manage.conf"
for f in "$RHIZO_BL_ROOT"/usr/lib/sdboot-manage.conf.d/*.conf "$RHIZO_BL_ROOT"/etc/sdboot-manage.conf.d/*.conf; do
  [[ ! -f "$f" ]] || . "$f"
done
sdoptions="root=UUID=abc rw rootflags=subvol=/@"
IFS=
for k in "$RHIZO_BL_ROOT"/boot/$KERNEL_PATTERN; do
  [[ -f "$k" ]] || continue
  kernel="/${k##*/}" name=${kernel//vmlinuz-/}; name=${name#/}
  entry="$RHIZO_BL_ROOT/boot/loader/entries/$name" initramfs=${kernel//vmlinuz/$INITRD_PREFIX}
  printf 'title Linux %s\noptions %s %s\nlinux %s\ninitrd %s.img\n' \
    "$name" "$sdoptions" "$LINUX_OPTIONS" "$kernel" "$initramfs" > "$entry.conf"
  if [[ -e "$RHIZO_BL_ROOT$initramfs-fallback.img" && "$DISABLE_FALLBACK" != yes ]]; then
    printf 'title Linux %s (Fallback)\noptions %s %s\nlinux %s\ninitrd %s-fallback.img\n' \
      "$name" "$sdoptions" "$LINUX_FALLBACK_OPTIONS" "$kernel" "$initramfs" > "$entry-fallback.conf"
  fi
done
STUB
  run_stub "$1/bin/sdboot-manage" gen
  add_efivars "$1"
  : > "$1/calls"
}

# create a grub fixture with a grub-mkconfig stub
add_grub_inline() {
  mkdir -p "$1/boot/grub"
  printf "GRUB_CMDLINE_LINUX_DEFAULT='nowatchdog quiet splash'\nGRUB_CMDLINE_LINUX=\"\"\nGRUB_DISABLE_RECOVERY=true\n" \
    > "$1/etc/default/grub"
  { cat <<'STUB'; bl_fix_grub_write; } | stub "$1/bin/grub-mkconfig"
[[ "$1" == -o && -n "${2:-}" ]] || { echo "usage: grub-mkconfig -o FILE" >&2; exit 2; }
echo "Generating grub configuration file ..." >&2
. "$RHIZO_BL_ROOT/etc/default/grub"
for f in "$RHIZO_BL_ROOT"/etc/default/grub.d/*.cfg; do [[ ! -f "$f" ]] || . "$f"; done
entry="linux /vmlinuz-linux-cachyos root=UUID=abc rw $GRUB_CMDLINE_LINUX $GRUB_CMDLINE_LINUX_DEFAULT" out="$2"
STUB
  run_stub "$1/bin/grub-mkconfig" -o "$1/boot/grub/grub.cfg"
  add_grub_editenv "$1"
  : > "$1/calls"
}

# create a grub fixture with an update-grub stub
add_grub_dropin() {
  mkdir -p "$1/boot/grub" "$1/etc/default/grub.d"
  printf 'GRUB_CMDLINE_LINUX="console=ttyS0"\n' > "$1/etc/default/grub"
  stub "$1/bin/update-grub" <<<'exec grub-gen "$@"'
  { echo '#!/bin/bash'; cat <<'STUB'; bl_fix_grub_write; } > "$1/bin/grub-gen"
echo "Generating grub configuration file ..." >&2
. "$RHIZO_BL_ROOT/etc/default/grub"
for f in "$RHIZO_BL_ROOT"/etc/default/grub.d/*.cfg; do [[ ! -e "$f" ]] || . "$f"; done
entry="linux /vmlinuz root=UUID=abc ro $GRUB_CMDLINE_LINUX${GRUB_CMDLINE_LINUX_DEFAULT:+ $GRUB_CMDLINE_LINUX_DEFAULT}"
out="$RHIZO_BL_ROOT/boot/grub/grub.cfg"
STUB
  chmod +x "$1/bin/grub-gen"
  run_stub "$1/bin/update-grub"
  add_grub_editenv "$1"
  : > "$1/calls"
}

UBUNTU_TOKENS="security=selinux enforcing=0 loglevel=8 log_buf_len=16M audit_backlog_limit=32768 systemd.unified_cgroup_hierarchy=1 loop.max_loop=64 zswap.enabled=1 androidboot.hardware=rhizo androidboot.selinux=permissive androidboot.use_memfd=1 androidboot.first_stage_console=0 androidboot.verifiedbootstate=orange androidboot.veritymode=disabled androidboot.vbmeta.digest=095fdab58d1f3bf532d502403738752341bedbbcd73c38ec1349105d54728b4e"
# shellcheck disable=SC2034
UBUNTU_LSM_TOKENS="lsm=lockdown,capability,landlock,yama,integrity,selinux,bpf ${UBUNTU_TOKENS#security=selinux }"
# shellcheck disable=SC2034
TOKENS_MID="enforcing=0 loglevel=8 log_buf_len=16M audit_backlog_limit=32768 systemd.unified_cgroup_hierarchy=1 loop.max_loop=64"
# shellcheck disable=SC2034
TOKENS_ANDROIDBOOT="androidboot.hardware=rhizo androidboot.selinux=permissive androidboot.use_memfd=1 androidboot.first_stage_console=0 androidboot.verifiedbootstate=orange androidboot.veritymode=disabled androidboot.vbmeta.digest=095fdab58d1f3bf532d502403738752341bedbbcd73c38ec1349105d54728b4e"

UBUNTU_RELEASE=6.8.0-136-generic
CACHYOS_RELEASE=7.2.9-1-cachyos
SWAPS_HEADER=$'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority'
SWAP_UUID=5e3c2a8e-7d41-4b0e-9a55-2f6d1c8b9e07

# link the bootstrap tools into a directory
link_bootstrap_tools() {
  local t
  mkdir -p "$1"
  for t in awk sed grep sort cat tr head tail wc mkdir dirname basename rm mv chmod mktemp readlink sync dd zcat gzip \
           uname; do
    ln -s "$(type -P "$t")" "$1/$t"
  done
}

# create stub host tools in the root bin
add_host_tools() {
  local bin="$1/bin"
  mkdir -p "$bin"
  cat > "$bin/uname" <<EOF
#!/bin/bash
if [[ "\$1" == -r ]]; then echo $2; else exec $(type -P uname) "\$@"; fi
EOF
  cat > "$bin/stat" <<EOF
#!/bin/bash
case "\$*" in
  "-f -c %T /") echo $3 ;;
  "-c %d:%i "*) [[ -e "\${!#}" ]] && echo 2049:131 ;;
  *) exec $(type -P stat) "\$@" ;;
esac
EOF
  cat > "$bin/blkid" <<EOF
#!/bin/bash
[[ "\$4" == UUID ]] && grep -q SWAPSPACE2 "\$5" 2>/dev/null && echo $SWAP_UUID
EOF
  cat > "$bin/df" <<'EOF'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 20509264 5242880 15266384 26%% /\n'
EOF
  cat > "$bin/swapon" <<'EOF'
#!/bin/bash
echo "${0##*/} $*" >> "$RHIZO_BL_ROOT/calls"
EOF
  cat > "$bin/fallocate" <<'EOF'
#!/bin/bash
echo "${0##*/} $*" >> "$RHIZO_BL_ROOT/calls"
echo "allocated $2" > "${!#}"
EOF
  cat > "$bin/mkswap" <<'EOF'
#!/bin/bash
echo "${0##*/} $*" >> "$RHIZO_BL_ROOT/calls"
echo SWAPSPACE2 >> "$1"
EOF
  cat > "$bin/rhizo-selinux-mode" <<'EOF'
#!/bin/bash
[[ ! -e "$RHIZO_BL_ROOT/selinux-mode-argv" ]] || echo "$*" >> "$RHIZO_BL_ROOT/selinux-mode-argv"
mode=$(cat "$RHIZO_BL_ROOT/selinux-mode" 2>/dev/null) || mode=host
case " $* " in
  *" --configured "*) echo "$mode" ;;
  *" --why "*) cat "$RHIZO_BL_ROOT/selinux-mode-why" 2>/dev/null ;;
  *" --mode-and-why "*) running=$(cat "$RHIZO_BL_ROOT/selinux-mode-running" 2>/dev/null) || running=$mode
    if [[ "$running" == refuse:* ]]; then printf '%s\t%s\n' "$running" "$(cat "$RHIZO_BL_ROOT/selinux-mode-why" 2>/dev/null)"
    else echo "$running"; fi ;;
  *) cat "$RHIZO_BL_ROOT/selinux-mode-running" 2>/dev/null || echo "$mode" ;;
esac
EOF
  echo '#!/bin/bash' > "$bin/sleep"
  cat > "$bin/mount" <<'EOF'
#!/bin/bash
echo "${0##*/} $*" >> "$RHIZO_BL_ROOT/calls"
[[ ! -e "$RHIZO_BL_ROOT/mount-fails" ]] || { echo "mount: $4: permission denied." >&2; exit 32; }
echo 0 > "$4/enforce"
EOF
  chmod +x "$bin"/*
}

# create an ubuntu host fixture
add_ubuntu_host() {
  local r="$1"
  mkdir -p "$r/bin" "$r/etc/default" "$r/boot" "$r/proc" "$r/sys/kernel/security" "$r/sys/module/zswap/parameters" "$r/var/lib"
  printf '%s\n' 'PRETTY_NAME="Ubuntu 24.04.3 LTS"' 'NAME="Ubuntu"' 'VERSION_ID="24.04"' 'VERSION="24.04.3 LTS (Noble Numbat)"' \
    'VERSION_CODENAME=noble' 'ID=ubuntu' 'ID_LIKE=debian' > "$r/etc/os-release"
  printf '%s\n' 'CONFIG_SECURITY_SELINUX=y' 'CONFIG_SECURITY_SELINUX_DEVELOP=y' 'CONFIG_SECURITY_APPARMOR=y' '# CONFIG_IKCONFIG is not set' \
    > "$r/boot/config-$UBUNTU_RELEASE"
  echo lockdown,capability,landlock,yama,apparmor,ima,evm > "$r/sys/kernel/security/lsm"
  echo N > "$r/sys/module/zswap/parameters/enabled"
  echo "BOOT_IMAGE=/vmlinuz-$UBUNTU_RELEASE root=UUID=abc ro console=tty1 console=ttyS0" > "$r/proc/cmdline"
  printf '%s\n/swap.img                               file      2097148   0     -2\n' "$SWAPS_HEADER" > "$r/proc/swaps"
  printf 'MemTotal:        8131540 kB\nSwapTotal:       2097148 kB\n' > "$r/proc/meminfo"
  printf '/swap.img\tnone\tswap\tsw\t0\t0\n' > "$r/etc/fstab"
  add_grub_dropin "$r"
  add_host_tools "$r" "$UBUNTU_RELEASE" ext2/ext3
}

# create a cachyos host fixture
add_cachyos_host() {
  local r="$1"
  mkdir -p "$r/bin" "$r/etc/default" "$r/boot" "$r/proc" "$r/sys/kernel/security" "$r/sys/module/zswap/parameters" \
    "$r/sys/module/binder/parameters" "$r/var/lib"
  printf '%s\n' 'NAME="CachyOS Linux"' 'PRETTY_NAME="CachyOS"' 'ID=cachyos' 'ID_LIKE=arch' 'BUILD_ID=rolling' \
    'ANSI_COLOR="38;2;23;147;209"' 'HOME_URL="https://cachyos.org/"' 'LOGO=cachyos' > "$r/etc/os-release"
  printf '%s\n' 'CONFIG_SECURITY_SELINUX=y' 'CONFIG_SECURITY_SELINUX_DEVELOP=y' 'CONFIG_ANDROID_BINDER_IPC=y' \
    'CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"' | gzip > "$r/proc/config.gz"
  echo capability,landlock,lockdown,yama,bpf > "$r/sys/kernel/security/lsm"
  mkdir -p "$r/proc/self/attr"; echo kernel > "$r/proc/self/attr/current"
  echo N > "$r/sys/module/zswap/parameters/enabled"
  echo binder,hwbinder,vndbinder > "$r/sys/module/binder/parameters/devices"
  echo "$LIMINE_CMDLINE" > "$r/proc/cmdline"
  printf '%s\n/dev/zram0                              partition 8038396   0     100\n' "$SWAPS_HEADER" > "$r/proc/swaps"
  printf 'MemTotal:        8038396 kB\nSwapTotal:       8038396 kB\n' > "$r/proc/meminfo"
  printf 'UUID=44444444-4444-4444-8444-444444444444 / btrfs subvol=/@,defaults,noatime,compress=zstd 0 0\n' > "$r/etc/fstab"
  "add_${2:-limine}" "$r"
  add_host_tools "$r" "$CACHYOS_RELEASE" btrfs
}

# create a stub tool in the root bin
add_pkg_tool() {
  printf '#!/bin/bash\nprintf %%s %q\nexit %d\n' "${4:-}" "$3" > "$1/bin/$2"
  chmod +x "$1/bin/$2"
}

BL_FIX_BASH=$(type -P bash)
BL_FIX_UNSHARE=$(type -P unshare)

# run the bootstrap on a fixture root
boot_run() {
  local root="$1" tools="$2" boot="$3"
  local -a as_root=("$BL_FIX_UNSHARE" -r)
  shift 3
  [[ -z "${BOOT_AS_USER:-}" ]] || as_root=()
  env -i PATH="$root/bin:$tools" HOME="$root" RHIZO_BL_ROOT="$root" \
    RHIZO_OS_RELEASE="$root/etc/os-release" RHIZO_BOOT_DIR="$root/boot" RHIZO_PROC_CONFIG="$root/proc/config.gz" \
    RHIZO_LSM_FILE="$root/sys/kernel/security/lsm" RHIZO_BOOTSTRAP_CMDLINE="$root/proc/cmdline" \
    RHIZO_BOOTSTRAP_SWAPS="$root/proc/swaps" RHIZO_BOOTSTRAP_MEMINFO="$root/proc/meminfo" \
    RHIZO_BOOTSTRAP_SELINUXFS="$root/sys/fs/selinux" RHIZO_BOOTSTRAP_ZSWAP="$root/sys/module/zswap/parameters/enabled" \
    RHIZO_BOOTSTRAP_ATTR_CURRENT="$root/proc/self/attr/current" \
    RHIZO_BINDER_DEVICES_FILE="$root/sys/module/binder/parameters/devices" RHIZO_BOOTSTRAP_FSTAB="$root/etc/fstab" \
    RHIZO_BOOTSTRAP_SWAPFILE="$root/swapfile" RHIZO_STATE_DIR="$root/var/lib/rhizo" \
    RHIZO_SELINUX_MODE_HELPER="$root/bin/rhizo-selinux-mode" \
    ${BOOT_LOOP_MAX:+RHIZO_LOOP_MAX_LOOP="$BOOT_LOOP_MAX"} ${RHIZO_BOOTLOADER:+RHIZO_BOOTLOADER="$RHIZO_BOOTLOADER"} \
    "${as_root[@]}" "$BL_FIX_BASH" "$boot" "$@"
}
