#!/bin/bash
# check that configure.sh turns a distro config into a Rhizo kernel config
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cache=${RHIZO_KERNEL_CACHE:-$HOME/.cache/rhizo/kernel}
base=$(sed -n 's/^base_tag=//p' "$root/kernel/SOURCE")
git -C "$cache/linux" cat-file -e "$base:scripts/config" 2>/dev/null \
  || { echo "NOT RUN: test-configure.sh: no $base tree in $cache/linux (run make kernel-inputs)"; exit 77; }
tmp=$(mktemp -d); trap 'rm -r "$tmp"' EXIT
mkdir -p "$tmp/tree/scripts"; git -C "$cache/linux" show "$base:scripts/config" > "$tmp/tree/scripts/config"
chmod +x "$tmp/tree/scripts/config"
printf '%s\n' 'CONFIG_SECURITY_SELINUX=y' '# CONFIG_SECURITY_SELINUX_DEVELOP is not set' 'CONFIG_LOCALVERSION_AUTO=y' \
  'CONFIG_LSM="landlock,lockdown,yama,integrity,apparmor"' 'CONFIG_ANDROID_BINDER_IPC=m' 'CONFIG_ANDROID_BINDER_DEVICES=""' \
  '# CONFIG_NETFILTER_XTABLES_LEGACY is not set' '# CONFIG_IKCONFIG is not set' > "$tmp/distro.config"
RHIZO_SKIP_OLDDEFCONFIG=1 "$root/kernel/configure.sh" "$tmp/tree" "$tmp/distro.config" ubuntu
c="$tmp/tree/.config"
grep -qx 'CONFIG_SECURITY_SELINUX_NS=y' "$c"
grep -qx 'CONFIG_SECURITY_SELINUX_DEVELOP=y' "$c"
grep -qx 'CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf"' "$c"
grep -qx 'CONFIG_LOCALVERSION="-rhizo"' "$c"
grep -qx '# CONFIG_LOCALVERSION_AUTO is not set' "$c"
grep -qx '# CONFIG_DEBUG_INFO_BTF_MODULES is not set' "$c"
grep -qx 'CONFIG_ANDROID_BINDER_IPC=y' "$c"
grep -qx 'CONFIG_ANDROID_BINDERFS=y' "$c"
grep -qx 'CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"' "$c"
grep -qx 'CONFIG_ANDROID_ASHMEM=y' "$c"
grep -qx 'CONFIG_IKCONFIG=y' "$c"
grep -qx 'CONFIG_IKCONFIG_PROC=y' "$c"
grep -qx 'CONFIG_NETFILTER_XTABLES_LEGACY=y' "$c"
for s in IP_NF_IPTABLES_LEGACY IP6_NF_IPTABLES_LEGACY IP_NF_FILTER IP_NF_MANGLE IP_NF_RAW IP_NF_NAT \
  IP6_NF_FILTER IP6_NF_MANGLE IP6_NF_RAW IP6_NF_NAT; do
  grep -qx "CONFIG_$s=m" "$c"
done
echo PASS
