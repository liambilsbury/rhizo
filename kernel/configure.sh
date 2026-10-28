#!/bin/bash
# write a Rhizo kernel .config into a kernel tree from a distro config
set -euo pipefail
tree=$1 cfg=$2 distro=$3
cp "$cfg" "$tree/.config"
cd "$tree"
./scripts/config --enable SECURITY_SELINUX --enable SECURITY_SELINUX_NS --enable SECURITY_SELINUX_BOOTPARAM \
  --enable SECURITY_SELINUX_DEVELOP --set-str LOCALVERSION -rhizo --disable LOCALVERSION_AUTO \
  --set-str LSM "landlock,lockdown,yama,integrity,selinux,bpf" --disable DEBUG_INFO_BTF_MODULES \
  --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
./scripts/config --enable ANDROID_BINDER_IPC --enable ANDROID_BINDERFS \
  --set-str ANDROID_BINDER_DEVICES "binder,hwbinder,vndbinder" --enable ANDROID_ASHMEM --enable IKCONFIG --enable IKCONFIG_PROC
./scripts/config --enable NETFILTER_XTABLES_LEGACY --module IP_NF_IPTABLES_LEGACY --module IP6_NF_IPTABLES_LEGACY \
  --module IP_NF_FILTER --module IP_NF_MANGLE --module IP_NF_RAW --module IP_NF_NAT \
  --module IP6_NF_FILTER --module IP6_NF_MANGLE --module IP6_NF_RAW --module IP6_NF_NAT
./scripts/config --module RHIZO_WLAN
[ "$distro" = ubuntu ] && ./scripts/config --disable DEFAULT_SECURITY_APPARMOR
[ "${RHIZO_SKIP_OLDDEFCONFIG:-0}" = 1 ] || make olddefconfig >/dev/null
