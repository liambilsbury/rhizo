#!/bin/bash
RHIZO_GUEST_OS="${RHIZO_GUEST_OS:-ubuntu}"
RHIZO_CACHYOS_BASE="${RHIZO_CACHYOS_BASE:-cachyos-stock}"

# succeed when the name is a known guest os
guest_os_valid() { [[ "$1" == ubuntu || "$1" == cachyos ]]; }

# print the bootloader a cachyos base installs
cachyos_base_bootloader() {
  case "$1" in
    cachyos-stock)  echo limine ;;
    cachyos-sdboot) echo systemd-boot ;;
    cachyos-grub)   echo grub ;;
    *) echo "$2 is '$1', which names no pristine cachyos base: cachyos-stock, cachyos-sdboot or cachyos-grub" >&2; return 1 ;;
  esac
}

# print the vm disk for a guest OS
guest_disk() {
  local os="$1" boot="$2" suffix="$3" tag=""
  [[ "$os" == cachyos ]] && tag="-cachyos"
  if [[ "$boot" == grub ]]; then echo "vm${tag}-pristine${suffix}.qcow2"
  else echo "vm${tag}${suffix}.qcow2"; fi
}

# print the base image of a vm disk
guest_base() {
  case "$1:$2" in
    ubuntu:grub)    echo "pristine-dl/noble-server-cloudimg-amd64.img" ;;
    ubuntu:direct)  echo "noble-server-cloudimg-amd64.img" ;;
    cachyos:grub)
      cachyos_base_bootloader "$RHIZO_CACHYOS_BASE" RHIZO_CACHYOS_BASE >/dev/null || return 1
      echo "cachyos-dl/$RHIZO_CACHYOS_BASE.qcow2" ;;
    cachyos:direct) echo "cachyos-dl/cachyos-dev.qcow2" ;;
  esac
}

# print the cloud-init source file
guest_seed_src() {
  case "$1:$2" in
    ubuntu:grub)   echo "config/cloud-init-pristine.yaml" ;;
    ubuntu:direct) echo "config/cloud-init.yaml" ;;
  esac
}

# print the firmware of a guest os
guest_firmware() { [[ "$1" == cachyos ]] && echo uefi || echo bios; }

# print the PCI slot of the vm disk
guest_disk_slot() {
  if [[ "$1:$2" == cachyos:grub ]]; then echo 0x5; fi
}

# print the vm's UEFI variable store name
guest_vars() {
  [[ "$(guest_firmware "$1")" == uefi ]] || return 0
  if [[ "$2" == grub ]]; then echo "OVMF_VARS-cachyos-pristine$3.fd"; else echo "OVMF_VARS-cachyos$3.fd"; fi
}

# print the UEFI variable store to copy
guest_vars_base() {
  local img
  case "$1:$2" in
    cachyos:grub)   img=$(guest_base cachyos grub) || return 1; echo "${img%.qcow2}.OVMF_VARS.fd" ;;
    cachyos:direct) echo "cachyos-dl/cachyos-stock.OVMF_VARS.fd" ;;
  esac
}

# print the backing file of a disk
guest_disk_backing() {
  local info
  info=$(qemu-img info -U --output=json "$1") || return 1
  python3 -c 'import json, sys; print(json.load(sys.stdin).get("backing-filename", ""))' <<<"$info"
}

# print the Rhizo kernel's package revision from a checkout's kernel/VERSION
rhizo_kernel_revision() {
  local v
  v=$(cat "$1/kernel/VERSION" 2>/dev/null) || { echo "cannot read $1/kernel/VERSION" >&2; return 1; }
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || { echo "$1/kernel/VERSION holds '$v', not a revision number" >&2; return 1; }
  echo "$v"
}

# print the make targets that build the guest os's kernel packages
rhizo_kernel_builder() {
  if [[ "$1" == cachyos ]]; then echo "make kernel-inputs kernel-arch"; else echo "make kernel-inputs kernel-deb"; fi
}

# print the Rhizo kernel packages of a revision in a directory
rhizo_kernel_packages() {
  local os="$1" dir="$2" rev="$3" f n kr
  case "$os" in
    ubuntu)
      for f in "$dir"/linux-image-*_*-"$rev"_amd64.deb; do
        n=${f##*/linux-image-}
        kr=${n%%_*}
        [[ -f "$f" && "$kr" != rhizo && "$kr" != *-dbg && "$n" == "${kr}_${kr}-${rev}_amd64.deb" ]] || continue
        [[ -f "$dir/linux-image-rhizo_${kr}-${rev}_amd64.deb" ]] || return 1
        printf '%s\n' "$f" "$dir/linux-image-rhizo_${kr}-${rev}_amd64.deb"
        return 0
      done ;;
    cachyos)
      for f in "$dir"/linux-rhizo-[0-9]*-"$rev"-"$(uname -m)".pkg.tar.zst; do
        n=${f##*/linux-rhizo-}
        [[ -f "$f" && "${n%-"$rev"-*.pkg.tar.zst}" != *-* ]] || continue
        echo "$f"
        return 0
      done ;;
  esac
  return 1
}

# print the kernel release a Rhizo kernel package installs
rhizo_kernel_release() {
  local n=${1##*/}
  case "$n" in
    linux-image-*.deb) n=${n#linux-image-}; echo "${n%%_*}" ;;
    linux-rhizo-*.pkg.tar.zst) n=${n#linux-rhizo-}; n=${n%-*-*.pkg.tar.zst}; echo "${n//_/-}" ;;
    *) return 1 ;;
  esac
}

# print the kernel directory beside a vm disk
vm_kernel_dir() {
  local real
  real=$(realpath -m -- "$1") || return 1
  echo "${real%.qcow2}.rhizo-kernel"
}

# succeed when a vm kernel directory holds the given revision
vm_kernel_current() {
  [[ "$(cat "$1/revision" 2>/dev/null)" == "$2" && -s "$1/vmlinuz" && -s "$1/initrd.img" ]]
}

# print the cachyos base build command
cachyos_builder() {
  local bl
  if [[ "$1" != grub ]]; then echo tools/build/vm/cachyos-dev.sh
  elif [[ "$RHIZO_CACHYOS_BASE" == cachyos-stock ]]; then echo tools/build/vm/cachyos-base.sh
  else
    bl=$(cachyos_base_bootloader "$RHIZO_CACHYOS_BASE" RHIZO_CACHYOS_BASE) || return 1
    echo "tools/build/vm/cachyos-base.sh --bootloader $bl --name $RHIZO_CACHYOS_BASE"
  fi
}

# print the root= kernel arguments
guest_root_arg() {
  local uuid file
  if [[ "$1" == cachyos ]]; then
    file="$(guest_base cachyos "$2")" || return 1
    file="${file%.qcow2}.root-uuid"
    [[ -f "$file" ]] || { echo "no $file -- run $(cachyos_builder "$2") first" >&2; return 1; }
    uuid=$(cat "$file") || return 1
    [[ -n "$uuid" ]] || { echo "$file is empty -- run $(cachyos_builder "$2") first" >&2; return 1; }
    echo "root=UUID=$uuid rootflags=subvol=/@ rw"
  else
    echo "root=LABEL=cloudimg-rootfs ro"
  fi
}

# print the lsm kernel argument of a guest os
guest_lsm_arg() {
  if [[ "$1" == cachyos ]]; then echo "lsm=landlock,lockdown,yama,integrity,selinux,bpf"
  else echo "lsm=lockdown,capability,landlock,yama,integrity,selinux,bpf"; fi
}

# print the config files of a cachyos bootloader
cachyos_bootloader_files() {
  case "$1" in
    limine)       echo "limine /etc/default/limine /boot/limine.conf" ;;
    systemd-boot) echo "sdboot /etc/sdboot-manage.conf /boot/loader/entries" ;;
    grub)         echo "grub-inline /etc/default/grub /boot/grub/grub.cfg" ;;
    *) echo "no pristine cachyos base installs bootloader '$1': limine, systemd-boot or grub" >&2; return 1 ;;
  esac
}

# print the stock cachyos probe script
cachyos_stock_probe() {
  cat <<EOF
echo "lsm=\$(cat /sys/kernel/security/lsm 2>&1)"
if [ -e /sys/fs/selinux/enforce ]; then echo enforce=present; else echo enforce=absent; fi
echo "cmdline=\$(cat /proc/cmdline 2>&1)"
echo "markers=\$(grep -c '# >>> rhizo' $1 2>&1)"
echo probe=done
EOF
}

# print each probe mismatch with stock cachyos
cachyos_stock_mismatches() {
  local conf="$1" line lsm="" enforce="" cmdline="" markers="" done=0 bad=0 t words=()
  while IFS= read -r line; do
    case "$line" in
      lsm=*) lsm=${line#lsm=} ;;
      enforce=*) enforce=${line#enforce=} ;;
      cmdline=*) cmdline=${line#cmdline=} ;;
      markers=*) markers=${line#markers=} ;;
      probe=done) done=1 ;;
    esac
  done
  (( done )) || { echo "the stock-state probe did not run to its end"; return 1; }
  if [[ ! "$lsm" =~ ^[a-z0-9_]+(,[a-z0-9_]+)*$ ]]; then
    echo "/sys/kernel/security/lsm did not read as an LSM list: '$lsm'"; bad=1
  else
    [[ ",$lsm," != *,selinux,* ]] || { echo "selinux is already an active LSM before the bootstrap ran (lsm=$lsm)"; bad=1; }
    [[ ",$lsm," != *,apparmor,* ]] || { echo "apparmor is an active LSM, which stock cachyos does not start (lsm=$lsm)"; bad=1; }
  fi
  case "$enforce" in
    absent) ;;
    present) echo "/sys/fs/selinux/enforce already exists before the bootstrap ran"; bad=1 ;;
    *) echo "cannot tell whether /sys/fs/selinux/enforce exists: read '$enforce'"; bad=1 ;;
  esac
  read -ra words <<<"$cmdline"
  (( ${#words[@]} )) || { echo "/proc/cmdline read empty"; bad=1; }
  for t in "${words[@]}"; do
    case "$t" in
      security=selinux|lsm=*|androidboot.*) echo "/proc/cmdline already carries $t"; bad=1 ;;
    esac
  done
  case "$markers" in
    0) ;;
    ''|*[!0-9]*) echo "cannot count '# >>> rhizo' lines in $conf: read '$markers'"; bad=1 ;;
    *) echo "$conf already carries $markers '# >>> rhizo' line(s)"; bad=1 ;;
  esac
  return "$bad"
}

# print the boot cmdline probe script
cachyos_cmdlines_probe() {
  case "$1" in
    limine) cat <<'EOF'
awk '/^[[:space:]]*cmdline:/ && !/\/\.snapshots\// { sub(/^[[:space:]]*cmdline:[[:space:]]*/, ""); print "line=" $0 }' /boot/limine.conf
EOF
      ;;
    sdboot) cat <<'EOF'
awk '/^options[[:space:]]/ { sub(/^options[[:space:]]+/, ""); print "line=" $0 }' /boot/loader/entries/*.conf
EOF
      ;;
    grub-inline) cat <<'EOF'
awk '/^[[:space:]]*linux[[:space:]]/ && !/\/\.snapshots\// { sub(/^[[:space:]]*linux[[:space:]]+[^[:space:]]+[[:space:]]*/, ""); print "line=" $0 }' /boot/grub/grub.cfg
EOF
      ;;
    *) echo "no cmdline reader for bootloader kind '$1': limine, sdboot or grub-inline" >&2; return 1 ;;
  esac
  echo 'echo probe=done'
}

# print each cmdline missing a required token
cmdlines_missing_tokens() {
  local want=() words=() line missing t n=0 done=0 bad=0
  read -ra want <<<"$1"
  (( ${#want[@]} )) || { echo "no tokens to look for"; return 1; }
  while IFS= read -r line; do
    case "$line" in
      probe=done) done=1; continue ;;
      line=*) line=${line#line=} ;;
      *) continue ;;
    esac
    n=$((n + 1))
    read -ra words <<<"$line"
    missing=""
    for t in "${want[@]}"; do
      [[ " ${words[*]} " == *" $t "* ]] || missing+=" $t"
    done
    [[ " ${words[*]} " == *" root="* ]] || missing+=" root="
    [[ -z "$missing" ]] || { echo "next-boot cmdline '$line' lacks:$missing"; bad=1; }
  done
  (( done )) || { echo "the cmdline probe did not run to its end"; return 1; }
  (( n )) || { echo "no next-boot cmdline was read"; return 1; }
  return "$bad"
}
