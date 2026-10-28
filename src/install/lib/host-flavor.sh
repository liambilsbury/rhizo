#!/bin/bash
# define host distribution functions
RHIZO_OS_RELEASE="${RHIZO_OS_RELEASE:-/etc/os-release}"
RHIZO_BOOT_DIR="${RHIZO_BOOT_DIR:-/boot}"
RHIZO_PROC_CONFIG="${RHIZO_PROC_CONFIG:-/proc/config.gz}"
RHIZO_LSM_FILE="${RHIZO_LSM_FILE:-/sys/kernel/security/lsm}"
RHIZO_BINDER_DEVICES_FILE="${RHIZO_BINDER_DEVICES_FILE:-/sys/module/binder/parameters/devices}"
RHIZO_ASHMEM_DEVICE="${RHIZO_ASHMEM_DEVICE:-/dev/ashmem}"
RHIZO_STATE_SUBVOLUME_RECORD="${RHIZO_STATE_SUBVOLUME_RECORD:-/etc/rhizo/state-subvolume}"

# print ubuntu or cachyos
host_flavor() {
  local id ver
  [[ -r "$RHIZO_OS_RELEASE" ]] || { echo "unsupported:no-os-release"; return 1; }
  id=$(sed -n 's/^ID=//p' "$RHIZO_OS_RELEASE" | tr -d "\"'" | head -1)
  ver=$(sed -n 's/^VERSION_ID=//p' "$RHIZO_OS_RELEASE" | tr -d "\"'" | head -1)
  case "$id:$ver" in
    ubuntu:24.04) echo ubuntu ;;
    cachyos:*)    echo cachyos ;;
    *)            echo "unsupported:${id:-unknown} ${ver:-unknown}"; return 1 ;;
  esac
}

# print the path of the kernel config
host_kconfig_source() {
  local f flavor
  f="$RHIZO_BOOT_DIR/config-$(uname -r)"
  flavor=$(host_flavor) || true
  if [[ "$flavor" == ubuntu ]]; then
    [[ -r "$f" ]] || { echo "no readable $f" >&2; return 1; }
    echo "$f"
  elif [[ -r "$RHIZO_PROC_CONFIG" ]]; then echo "$RHIZO_PROC_CONFIG"
  elif [[ -r "$f" ]]; then echo "$f"
  else echo "no readable $RHIZO_PROC_CONFIG or $f" >&2; return 1; fi
}

# check the kernel config for CONFIG_<sym>
host_kconfig_has() {
  local src text
  src=$(host_kconfig_source) || return 2
  case "$src" in
    *.gz) text=$(zcat "$src") || return 2 ;;
    *)    text=$(cat "$src") || return 2 ;;
  esac
  grep -qx "CONFIG_$1=${2:-y}" <<<"$text"
}

# print the active lsm= list with selinux
host_lsm_list_with_selinux() {
  local active l placed=0
  local -a parts out=()
  active=$(cat "$RHIZO_LSM_FILE") || return 1
  IFS=, read -ra parts <<<"$active"
  for l in "${parts[@]}"; do
    case "$l" in
      apparmor|smack|selinux) ;;
      bpf) out+=(selinux bpf); placed=1 ;;
      *) out+=("$l") ;;
    esac
  done
  (( placed )) || out+=(selinux)
  (IFS=,; echo "lsm=${out[*]}")
}

# print dpkg or pacman
host_pkg_manager() {
  local flavor found=""
  flavor=$(host_flavor) || true
  case "$flavor" in
    ubuntu)  echo dpkg ;;
    cachyos) echo pacman ;;
    *)
      if command -v dpkg-query >/dev/null; then found=dpkg; fi
      if command -v pacman >/dev/null; then found+="${found:+ }pacman"; fi
      case "$found" in
        dpkg|pacman) echo "$found" ;;
        "") echo "cannot query packages on $flavor: neither dpkg-query nor pacman is installed" >&2; return 1 ;;
        *)  echo "cannot query packages on $flavor: both dpkg-query and pacman are installed" >&2; return 1 ;;
      esac ;;
  esac
}

# query the package database for <pkg>
host_pkg_installed() {
  local manager s rc=0
  manager=$(host_pkg_manager) || return 2
  case "$manager" in
    dpkg)
      command -v dpkg-query >/dev/null || { echo "cannot query packages: dpkg-query is not runnable" >&2; return 2; }
      s=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) || rc=$?
      case $rc in
        0) [[ -n "$s" && "$s" != not-installed && "$s" != config-files ]] ;;
        1) return 1 ;;
        *) echo "cannot query packages: dpkg-query exited $rc" >&2; return 2 ;;
      esac ;;
    pacman)
      command -v pacman >/dev/null || { echo "cannot query packages: pacman is not runnable" >&2; return 2; }
      pacman -Qq "$1" >/dev/null 2>&1 ;;
  esac
}

# check version <a> predates version <b>
host_version_lt() {
  local flavor rc rel
  flavor=$(host_flavor) || true
  case "$flavor" in
    ubuntu)
      command -v dpkg >/dev/null || { echo "cannot compare $1 with $2: dpkg is not runnable" >&2; return 2; }
      dpkg --compare-versions "$1" lt "$2" && return 0
      rc=$?
      (( rc == 1 )) && return 1
      echo "cannot compare $1 with $2: dpkg exited $rc" >&2; return 2 ;;
    cachyos)
      if ! command -v vercmp >/dev/null || ! rel=$(vercmp "$1" "$2") || [[ ! "$rel" =~ ^-?[0-9]+$ ]]; then
        echo "cannot compare $1 with $2: vercmp gave no answer" >&2; return 2
      fi
      [[ "$rel" -lt 0 ]] ;;
    *) echo "cannot compare versions on $flavor" >&2; return 2 ;;
  esac
}

# print what the running kernel lacks
host_kernel_lacks() {
  local lacks=()
  [[ -e "$RHIZO_BINDER_DEVICES_FILE" ]] || lacks+=("built-in binder")
  [[ -c "$RHIZO_ASHMEM_DEVICE" ]] || lacks+=("$RHIZO_ASHMEM_DEVICE")
  [[ -e "$RHIZO_PROC_CONFIG" ]] || lacks+=("$RHIZO_PROC_CONFIG")
  (( ${#lacks[@]} )) || return 0
  local joined="" x
  for x in "${lacks[@]}"; do joined+="${joined:+, }$x"; done
  echo "$joined"
  return 1
}

# print the sentence that refuses a kernel lacking <what>
host_kernel_refusal() {
  echo "$(uname -r) has no $1: boot the Rhizo kernel (linux-image-rhizo on Ubuntu, linux-rhizo on CachyOS)"
}

# check the state dir against its subvolume record
host_state_subvolume_check() {
  local state="${RHIZO_STATE_DIR:-/var/lib/rhizo}"
  [[ -e "$RHIZO_STATE_SUBVOLUME_RECORD" ]] || return 0
  [[ -d "$state" && "$(stat -f -c %T "$state")" == btrfs && "$(stat -c %i "$state")" == 256 ]] && return 0
  echo "$RHIZO_STATE_SUBVOLUME_RECORD records $state as a btrfs subvolume, and on this boot it is not one: this boot" \
       "is a root snapshot whose state subvolume is not mounted, and Rhizo does not run on it"
  return 1
}

# create a system account and group
host_sys_account_add() {
  local name="$1" uid="${2:-}" flavor group=(--user-group)
  flavor=$(host_flavor) || true
  case "$flavor" in
    ubuntu)
      getent passwd "$name" >/dev/null && return 0
      adduser --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin \
              ${uid:+--uid "$uid"} --group "$name" ;;
    cachyos)
      getent passwd "$name" >/dev/null && return 0
      if getent group "$name" >/dev/null; then group=(--gid "$name"); fi
      useradd --system "${group[@]}" --no-create-home --home-dir /nonexistent \
              --shell /usr/bin/nologin ${uid:+--uid "$uid"} "$name" ;;
    *) echo "cannot create a system account on $flavor" >&2; return 1 ;;
  esac
}
