#!/bin/bash
# print a TSV census of host state
set -uo pipefail
PROG=host-snapshot
# print the usage text
usage() {
  cat <<'EOF'
Usage: host-snapshot.sh [--with-apt]
  --with-apt   include /etc/apt in the census (off by default: apt's own timers change it on any host)
EOF
}

WITH_APT=0
for a in "$@"; do
  case "$a" in
    --with-apt) WITH_APT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[$PROG] unknown argument '$a'" >&2; exit 2 ;;
  esac
done

# print a TSV row for a key
emit() {
  local section="$1" key="$2"; shift 2
  local value="$*"
  value="${value//$'\t'/ }"
  value="${value//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$section" "$key" "$value"
}

# print census rows for a directory's entries
list_dir() {
  local section="$1" dir="$2" depth="${3:-2}"
  if [[ ! -e "$dir" ]]; then
    emit "$section" "$dir" absent
    return 0
  fi
  emit "$section" "$dir" present
  local f
  while IFS= read -r f; do
    emit "$section" "$f" listed
  done < <(find "$dir" -mindepth 1 -maxdepth "$depth" 2>/dev/null | LC_ALL=C sort)
}

if command -v dpkg-query >/dev/null 2>&1; then
  while IFS=$'\t' read -r pkg ver status; do
    [[ -n "$pkg" ]] || continue
    emit dpkg "$pkg.version" "$ver"
    emit dpkg "$pkg.status" "$status"
  done < <(dpkg-query -W -f='${Package}\t${Version}\t${Status}\n' 2>/dev/null)
else
  emit dpkg tool absent
fi

if command -v pacman >/dev/null 2>&1; then
  while read -r pkg ver; do
    [[ -n "$pkg" ]] || continue
    emit pacman "$pkg.version" "$ver"
  done < <(pacman -Q 2>/dev/null)
else
  emit pacman tool absent
fi

while IFS=: read -r name _pw uid gid _gecos home shell; do
  [[ -n "$name" ]] || continue
  emit passwd "$name" "uid=$uid gid=$gid home=$home shell=$shell"
done < /etc/passwd
while IFS=: read -r name _pw gid members; do
  [[ -n "$name" ]] || continue
  emit group "$name" "gid=$gid members=$members"
done < /etc/group

# return 0 for an excluded /etc path
etc_excluded() {
  case "$1" in
    /etc/ld.so.cache|/etc/mtab|/etc/resolv.conf|/etc/adjtime|/etc/.pwd.lock|/etc/machine-id)
      return 0 ;;
    /etc/apt|/etc/apt/*)
      (( WITH_APT )) && return 1 || return 0 ;;
  esac
  return 1
}
while IFS= read -r -d '' path; do
  etc_excluded "$path" && continue
  if [[ -L "$path" ]]; then
    emit etc "$path" "symlink target=$(readlink "$path")"
  elif [[ -d "$path" ]]; then
    emit etc "$path" "dir mode=$(stat -c '%a' "$path" 2>/dev/null) owner=$(stat -c '%U:%G' "$path" 2>/dev/null)"
  elif [[ -f "$path" ]]; then
    emit etc "$path" "file mode=$(stat -c '%a' "$path" 2>/dev/null) owner=$(stat -c '%U:%G' "$path" 2>/dev/null) sha256=$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1)"
  else
    emit etc "$path" other
  fi
done < <(find /etc -print0 2>/dev/null)

if command -v systemctl >/dev/null 2>&1; then
  while read -r unit state _rest; do
    [[ -n "$unit" ]] || continue
    emit unit "$unit" "$state"
  done < <(systemctl list-unit-files --no-legend --plain 2>/dev/null)
else
  emit unit tool absent
fi

for scope in system:/var/lib/systemd/deb-systemd-helper-enabled user:/var/lib/systemd/deb-systemd-user-helper-enabled; do
  d="${scope#*:}"
  [[ -d "$d" ]] || continue
  while IFS= read -r -d '' f; do
    emit dsh "${scope%%:*}:${f#"$d"/}" present
  done < <(find "$d" -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
done

for d in /etc/default/grub.d /etc/modules-load.d /etc/modprobe.d /usr/lib/systemd/system/service.d; do
  if [[ -d "$d" ]]; then
    while IFS= read -r f; do
      emit listing "$f" "sha256=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
    done < <(find "$d" -maxdepth 1 -type f 2>/dev/null | LC_ALL=C sort)
  else
    emit listing "$d" absent
  fi
done

list_dir usr_src /usr/src 2

shopt -s nullglob
for d in /lib/modules/*/updates; do
  kver="$(basename "$(dirname "$d")")"
  while IFS= read -r f; do
    emit modules_updates "$kver: $f" present
  done < <(find "$d" -type f 2>/dev/null | LC_ALL=C sort)
done
shopt -u nullglob

if [[ -f /boot/grub/grub.cfg ]]; then
  emit grub cfg.sha256 "$(sha256sum /boot/grub/grub.cfg 2>/dev/null | cut -d' ' -f1)"
else
  emit grub cfg.sha256 absent
fi
emit grub cmdline "$(cat /proc/cmdline 2>/dev/null)"
if [[ -f /boot/limine.conf ]]; then
  while IFS= read -r line; do
    emit limine cmdline "$line"
  done < <(sed -n 's/^[[:space:]]*\(kernel_\)\{0,1\}cmdline:[[:space:]]*//p' /boot/limine.conf | grep -v '\.snapshots/' | LC_ALL=C sort -u)
else
  emit limine conf absent
fi
if [[ -f /etc/fstab ]]; then
  emit fstab sha256 "$(sha256sum /etc/fstab 2>/dev/null | cut -d' ' -f1)"
else
  emit fstab sha256 absent
fi
while IFS= read -r line; do
  [[ "$line" == Filename* ]] && continue
  [[ -n "$line" ]] || continue
  emit swaps "$(awk '{print $1}' <<<"$line")" "$line"
done < /proc/swaps

list_dir home_root /root 3
desktop_user="$(cat /etc/rhizo/desktop-user 2>/dev/null)"
if [[ -n "$desktop_user" ]]; then
  desktop_home="$(getent passwd "$desktop_user" 2>/dev/null | cut -d: -f6)"
  if [[ -n "$desktop_home" ]]; then
    list_dir home_desktop "$desktop_home/.config" 3
    list_dir home_desktop "$desktop_home/.local/share" 3
  else
    emit home_desktop "desktop-user=$desktop_user" "no passwd entry"
  fi
else
  emit home_desktop desktop-user "no /etc/rhizo/desktop-user"
fi

list_dir applications /usr/share/applications 1
shopt -s nullglob
icon_hits=(/usr/share/icons/hicolor/*/apps/rhizo*)
shopt -u nullglob
if (( ${#icon_hits[@]} )); then
  for f in "${icon_hits[@]}"; do emit icons "$f" present; done
else
  emit icons "/usr/share/icons/hicolor/*/apps/rhizo*" absent
fi

for d in /var/lib/rhizo /usr/lib/rhizo /etc/rhizo /srv/rhizo /var/cache/rhizo /var/log/rhizo; do
  list_dir rhizo_dirs "$d" 2
done

for d in /var/lib/apt /var/cache/apt /var/lib/systemd /var/log; do
  list_dir state_dirs "$d" 1
done

if [[ "$(stat -f -c %T / 2>/dev/null)" == btrfs ]] && command -v btrfs >/dev/null 2>&1; then
  while IFS= read -r path; do
    emit btrfs "$path" present
  done < <(btrfs subvolume list / 2>/dev/null | awk '{ print $NF }' | grep -vE '(^|/)\.snapshots/[0-9]+/snapshot$' | LC_ALL=C sort)
else
  emit btrfs root not-btrfs
fi

# print security.selinux labels for files in directories
selinux_census() {
  python3 - "$@" <<'PYEOF'
import os, sys
dirs = sys.argv[1:]
paths = []
seen = set()
for d in dirs:
    if not os.path.isdir(d):
        print("DIRABSENT\t%s" % d)
        continue
    if os.path.realpath(d) in seen:
        continue
    seen.add(os.path.realpath(d))
    try:
        names = sorted(os.listdir(d))
    except OSError:
        continue
    for n in names:
        p = os.path.join(d, n)
        if os.path.isfile(p) and not os.path.islink(p):
            paths.append(p)
try:
    for line in open("/proc/self/maps"):
        head, sep, p = line.rstrip("\n").partition(" /")
        if not sep:
            continue
        p = "/" + p.strip()
        if os.path.basename(p).startswith("ld-") and ".so" in os.path.basename(p):
            paths.append(p)
            break
except OSError:
    pass
for p in sorted(set(paths)):
    try:
        v = os.getxattr(p, "security.selinux").decode().rstrip("\0")
    except OSError:
        v = ""
    print("XATTR\t%s\t%s" % (p, v or "<none>"))
PYEOF
}
if command -v python3 >/dev/null 2>&1; then
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      DIRABSENT) emit selinux_xattr "$a" dir-absent ;;
      XATTR) emit selinux_xattr "$a" "$b" ;;
    esac
  done < <(selinux_census /usr/bin /usr/sbin /usr/lib/systemd)
else
  emit selinux_xattr tool absent
fi

emit lsm active "$(cat /sys/kernel/security/lsm 2>/dev/null)"
emit kernel uname_r "$(uname -r)"
if command -v dpkg >/dev/null 2>&1; then
  audit_out="$(dpkg --audit 2>&1)"
  if [[ -z "$audit_out" ]]; then
    emit dpkg_audit result clean
  else
    n=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      n=$((n + 1))
      emit dpkg_audit "line.$n" "$line"
    done <<<"$audit_out"
  fi
else
  emit dpkg_audit tool absent
fi

emit end sentinel ok
