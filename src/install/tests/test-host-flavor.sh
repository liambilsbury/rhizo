#!/bin/bash
# test the functions in host-flavor.sh
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILED=0
# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; FAILED=$((FAILED + 1)); fi
}
# write the arguments to the os-release file
osr() { printf '%s\n' "$@" > "$TMP/os-release"; }
export RHIZO_OS_RELEASE="$TMP/os-release" RHIZO_BOOT_DIR="$TMP/boot" RHIZO_PROC_CONFIG="$TMP/config.gz" \
       RHIZO_LSM_FILE="$TMP/lsm"
mkdir -p "$TMP/boot"
# shellcheck source=../lib/host-flavor.sh
. "$HERE/../lib/host-flavor.sh"

osr 'ID=ubuntu' 'VERSION_ID="24.04"';            check "ubuntu 24.04"  "$(host_flavor)" ubuntu
osr 'ID=ubuntu' 'VERSION_ID="25.10"';            check "ubuntu 25.10"  "$(host_flavor)" "unsupported:ubuntu 25.10"
osr 'NAME="CachyOS Linux"' 'ID=cachyos' 'ID_LIKE=arch'; check "cachyos" "$(host_flavor)" cachyos
osr 'ID=arch';                                   check "arch"          "$(host_flavor)" "unsupported:arch unknown"
rm -f "$TMP/os-release";                         check "no os-release" "$(host_flavor)" "unsupported:no-os-release"
osr "ID='ubuntu'" "VERSION_ID='24.04'";          check "single-quoted ubuntu"  "$(host_flavor)" ubuntu
osr "ID='cachyos'";                              check "single-quoted cachyos" "$(host_flavor)" cachyos
osr 'ID=ubuntu';                                 check "ubuntu no version"     "$(host_flavor)" "unsupported:ubuntu unknown"
osr 'NAME="Mystery Linux"';                      check "no ID line"            "$(host_flavor)" "unsupported:unknown unknown"

BOOTCFG="$TMP/boot/config-$(uname -r)"
osr 'ID=cachyos'
printf 'CONFIG_SECURITY_SELINUX=y\nCONFIG_HZ=1000\n' | gzip > "$TMP/config.gz"
check "cachyos kconfig source is proc" "$(host_kconfig_source)" "$TMP/config.gz"
host_kconfig_has SECURITY_SELINUX;      check "proc config: selinux=y"  "$?" 0
host_kconfig_has HZ 1000;               check "proc config: value"      "$?" 0
host_kconfig_has SECURITY_APPARMOR;     check "proc config: absent"     "$?" 1
printf 'CONFIG_SECURITY_APPARMOR=y\n' > "$BOOTCFG"
check "cachyos: proc config wins over the boot one" "$(host_kconfig_source)" "$TMP/config.gz"
osr 'ID=arch'
check "unsupported host: proc config first too"     "$(host_kconfig_source)" "$TMP/config.gz"
osr 'ID=cachyos'
rm "$TMP/config.gz"
check "cachyos without proc config: the boot one"   "$(host_kconfig_source)" "$BOOTCFG"
host_kconfig_has SECURITY_APPARMOR;     check "cachyos boot config: apparmor=y" "$?" 0
rm "$BOOTCFG"
err=$(host_kconfig_has SECURITY_SELINUX 2>&1); rc=$?
check "cachyos no config: rc 2"             "$rc" 2
check "cachyos no config: names both paths" "$err" "no readable $TMP/config.gz or $BOOTCFG"
osr 'ID=ubuntu' 'VERSION_ID="24.04"'
printf 'CONFIG_SECURITY_SELINUX=y\n' | gzip > "$TMP/config.gz"
err=$(host_kconfig_has SECURITY_SELINUX 2>&1); rc=$?
check "ubuntu never reads proc config: rc 2"        "$rc" 2
check "ubuntu no boot config: names only it"        "$err" "no readable $BOOTCFG"
printf 'CONFIG_SECURITY_APPARMOR=y\n' > "$BOOTCFG"
check "ubuntu kconfig source is the boot one"       "$(host_kconfig_source)" "$BOOTCFG"
host_kconfig_has SECURITY_SELINUX;      check "ubuntu reads the boot config, not proc's" "$?" 1
rm -f "$BOOTCFG" "$TMP/config.gz"

echo 'capability,landlock,lockdown,yama,integrity,apparmor,bpf' > "$TMP/lsm"
check "lsm list swaps apparmor"  "$(host_lsm_list_with_selinux)" "lsm=capability,landlock,lockdown,yama,integrity,selinux,bpf"
echo 'capability,landlock,yama' > "$TMP/lsm"
check "lsm list without bpf"     "$(host_lsm_list_with_selinux)" "lsm=capability,landlock,yama,selinux"
echo 'capability,landlock,lockdown,yama,integrity,selinux,bpf' > "$TMP/lsm"
check "lsm list is stable"       "$(host_lsm_list_with_selinux)" "lsm=capability,landlock,lockdown,yama,integrity,selinux,bpf"

mkdir "$TMP/tools"
for t in sed tr head; do ln -s "$(command -v "$t")" "$TMP/tools/$t"; done
# run a command with only the minimal tools on PATH
bare() { PATH="$TMP/tools" "$@"; }

STUBS="$TMP/stubs"; CALLS="$TMP/calls"; export STUBS CALLS
mkdir -p "$TMP/bin" "$STUBS"
for c in dpkg-query dpkg pacman vercmp adduser useradd getent; do
  cat > "$TMP/bin/$c" <<'STUB'
#!/bin/bash
echo "${0##*/} $*" >> "$CALLS"
s="$STUBS/${0##*/}"; [[ ! -e "$s.$1.rc" ]] || s="$s.$1"
cat "$s.out"
exit "$(< "$s.rc")"
STUB
  chmod +x "$TMP/bin/$c"
done
PATH="$TMP/bin:$PATH"
# set the stub output and exit status
answer() {
  printf '%s' "${3:-}" > "$STUBS/$1.out"; echo "$2" > "$STUBS/$1.rc"; : > "$CALLS"
}
# set the stub getent output for a database
answer_db() { : > "$STUBS/getent.$1.out"; echo "$2" > "$STUBS/getent.$1.rc"; }
# check a command's exit status and stderr
refused() {
  local out rc
  out=$("${@:4}" 2>"$TMP/err"); rc=$?
  check "$1: rc"      "$rc" "$2"
  check "$1: stdout"  "$out" ""
  check "$1: stderr"  "$(< "$TMP/err")" "$3"
}
# check a command under bash -e
refused_e() {
  refused "$1 under set -e" "$2" "$3" bash -e -c ". \"\$0\"; \"\$@\"" "$HERE/../lib/host-flavor.sh" "${@:4}"
}
# check host_sys_account_add for an existing account
account_exists() {
  local out rc
  answer getent 0 "rhizo-netbridged:x:999:999::/nonexistent:/usr/sbin/nologin"; answer "$2" 0
  out=$(host_sys_account_add rhizo-netbridged); rc=$?
  check "$1 account exists: rc"      "$rc" 0
  check "$1 account exists: stdout"  "$out" ""
  check "$1 account exists: only the lookup ran" "$(cat "$CALLS")" "getent passwd rhizo-netbridged"
}
NL=$'\n'

answer dpkg-query 0 installed;       host_pkg_installed rhizo-x; check "ubuntu pkg installed: rc"       "$?" 0
check "ubuntu pkg query argv"    "$(cat "$CALLS")" "dpkg-query -W -f=\${db:Status-Status} rhizo-x"
answer dpkg-query 0 config-files;    host_pkg_installed rhizo-x; check "ubuntu pkg config-files: rc"    "$?" 1
answer dpkg-query 0 not-installed;   host_pkg_installed rhizo-x; check "ubuntu pkg not-installed: rc"   "$?" 1
answer dpkg-query 1;                 host_pkg_installed rhizo-x; check "ubuntu pkg unknown: rc"         "$?" 1
answer dpkg-query 2
refused "ubuntu pkg query error" 2 "cannot query packages: dpkg-query exited 2" host_pkg_installed rhizo-x
check "ubuntu package manager"   "$(host_pkg_manager)" dpkg
refused "ubuntu pkg tool absent" 2 "cannot query packages: dpkg-query is not runnable" bare host_pkg_installed rhizo-x

answer dpkg 0;  host_version_lt 1.0 2.0; check "ubuntu version lt: rc"   "$?" 0
check "ubuntu version lt argv"   "$(cat "$CALLS")" "dpkg --compare-versions 1.0 lt 2.0"
answer dpkg 1;  host_version_lt 2.0 1.0; check "ubuntu version ge: rc"   "$?" 1
answer dpkg 2;  refused "ubuntu version dpkg error" 2 "cannot compare 1.0 with 2.0: dpkg exited 2" host_version_lt 1.0 2.0
refused "ubuntu version tool absent" 2 "cannot compare 1.0 with 2.0: dpkg is not runnable" bare host_version_lt 1.0 2.0

answer getent 2; answer adduser 0; host_sys_account_add rhizo-netbridged;      check "ubuntu account: rc"        "$?" 0
check "ubuntu account argv"      "$(cat "$CALLS")" "getent passwd rhizo-netbridged${NL}adduser --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin --group rhizo-netbridged"
answer getent 2; answer adduser 0; host_sys_account_add rhizo-appwatch 1000;   check "ubuntu account uid: rc"    "$?" 0
check "ubuntu account uid argv"  "$(cat "$CALLS")" "getent passwd rhizo-appwatch${NL}adduser --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin --uid 1000 --group rhizo-appwatch"
answer getent 2; answer adduser 1; host_sys_account_add rhizo-netbridged;      check "ubuntu account fails: rc"  "$?" 1
account_exists ubuntu adduser

osr 'ID=cachyos'
answer pacman 0; host_pkg_installed rhizo-x; check "cachyos pkg installed: rc" "$?" 0
check "cachyos pkg query argv"   "$(cat "$CALLS")" "pacman -Qq rhizo-x"
answer pacman 1; host_pkg_installed rhizo-x; check "cachyos pkg unknown: rc"   "$?" 1
refused "cachyos pkg tool absent" 2 "cannot query packages: pacman is not runnable" bare host_pkg_installed rhizo-x
check "cachyos package manager"  "$(host_pkg_manager)" pacman

answer vercmp 0 -1; host_version_lt 1.0 2.0; check "cachyos version lt: rc"    "$?" 0
check "cachyos version lt argv"  "$(cat "$CALLS")" "vercmp 1.0 2.0"
answer vercmp 0 0;  host_version_lt 1.0 1.0; check "cachyos version equal: rc" "$?" 1
answer vercmp 0 1;  host_version_lt 2.0 1.0; check "cachyos version gt: rc"    "$?" 1
answer vercmp 1;    refused "cachyos version vercmp fails" 2 "cannot compare 1.0 with 2.0: vercmp gave no answer" host_version_lt 1.0 2.0
answer vercmp 0;    refused "cachyos version vercmp silent" 2 "cannot compare 1.0 with 2.0: vercmp gave no answer" host_version_lt 1.0 2.0
answer vercmp 0 junk; refused "cachyos version vercmp junk" 2 "cannot compare 1.0 with 2.0: vercmp gave no answer" host_version_lt 1.0 2.0
refused "cachyos version tool absent" 2 "cannot compare 1.0 with 2.0: vercmp gave no answer" bare host_version_lt 1.0 2.0

USERADD_TAIL="--no-create-home --home-dir /nonexistent --shell /usr/bin/nologin"
# print the getent passwd and group lookups
lookups() { echo "getent passwd $1${NL}getent group $1"; }
answer getent 2; answer useradd 0; host_sys_account_add rhizo-netbridged;      check "cachyos account: rc"       "$?" 0
check "cachyos account argv, no group of the name" "$(cat "$CALLS")" \
  "$(lookups rhizo-netbridged)${NL}useradd --system --user-group $USERADD_TAIL rhizo-netbridged"
answer getent 2; answer useradd 0; host_sys_account_add rhizo-appwatch 1000;   check "cachyos account uid: rc"   "$?" 0
check "cachyos account uid argv, no group of the name" "$(cat "$CALLS")" \
  "$(lookups rhizo-appwatch)${NL}useradd --system --user-group $USERADD_TAIL --uid 1000 rhizo-appwatch"
answer getent 2; answer useradd 0; answer_db group 0
host_sys_account_add rhizo-appwatch 1000
check "cachyos account argv, the group of the name already there: it becomes the primary group" "$(cat "$CALLS")" \
  "$(lookups rhizo-appwatch)${NL}useradd --system --gid rhizo-appwatch $USERADD_TAIL --uid 1000 rhizo-appwatch"
rm "$STUBS"/getent.group.*
answer getent 2; answer useradd 9; host_sys_account_add rhizo-netbridged;      check "cachyos account fails: rc" "$?" 9
account_exists cachyos useradd

osr 'ID=arch'
MSG_VERSION="cannot compare versions on unsupported:arch unknown"
MSG_PKG="cannot query packages on unsupported:arch unknown: both dpkg-query and pacman are installed"
MSG_ACCOUNT="cannot create a system account on unsupported:arch unknown"
answer getent 0; answer adduser 0; answer useradd 0
refused "arch version lt"    2 "$MSG_VERSION" host_version_lt 1.0 2.0
refused "arch pkg installed"     2 "$MSG_PKG"     host_pkg_installed rhizo-x
refused "arch account"       1 "$MSG_ACCOUNT" host_sys_account_add rhizo-netbridged 1000
check "arch account: no tool ran" "$(cat "$CALLS")" ""

mkdir "$TMP/only-dpkg" "$TMP/only-pacman"
ln -s "$TMP/bin/dpkg-query" "$TMP/only-dpkg/dpkg-query"
ln -s "$TMP/bin/pacman" "$TMP/only-pacman/pacman"
for d in only-dpkg only-pacman; do ln -s "$(command -v cat)" "$TMP/$d/cat"; done
# run a command with only the given directory on PATH
only() { local d="$1"; shift; PATH="$TMP/tools:$d" "$@"; }
check "arch with dpkg-query: package manager" "$(only "$TMP/only-dpkg" host_pkg_manager)" dpkg
check "arch with pacman: package manager"     "$(only "$TMP/only-pacman" host_pkg_manager)" pacman
answer dpkg-query 0 installed;    only "$TMP/only-dpkg" host_pkg_installed rhizo-x
check "arch with dpkg-query, installed: rc" "$?" 0
answer dpkg-query 0 config-files; only "$TMP/only-dpkg" host_pkg_installed rhizo-x
check "arch with dpkg-query, removed: rc"   "$?" 1
answer pacman 1;                  only "$TMP/only-pacman" host_pkg_installed rhizo-x
check "arch with pacman, absent: rc"        "$?" 1
MSG_NO_PKG="cannot query packages on unsupported:arch unknown: neither dpkg-query nor pacman is installed"
refused "arch package manager, both"    1 "$MSG_PKG"    host_pkg_manager
refused "arch package manager, neither" 1 "$MSG_NO_PKG" bare host_pkg_manager
refused "arch pkg installed, neither"       2 "$MSG_NO_PKG" bare host_pkg_installed rhizo-x

refused_e "arch version lt"   2 "$MSG_VERSION" host_version_lt 1.0 2.0
refused_e "arch pkg installed"    2 "$MSG_PKG"     host_pkg_installed rhizo-x
refused_e "arch account"      1 "$MSG_ACCOUNT" host_sys_account_add rhizo-netbridged 1000

export RHIZO_BINDER_DEVICES_FILE="$TMP/binder-devices" RHIZO_ASHMEM_DEVICE="$TMP/ashmem"
echo binder,hwbinder,vndbinder > "$TMP/binder-devices"; ln -s /dev/null "$TMP/ashmem"; touch "$TMP/config.gz"
host_kernel_lacks;                        check "the Rhizo kernel lacks nothing: rc" "$?" 0
check "the Rhizo kernel lacks nothing: stdout" "$(host_kernel_lacks)" ""
mv "$TMP/binder-devices" "$TMP/binder-devices.away"
check "no built-in binder is named" "$(host_kernel_lacks)" "built-in binder"
rm "$TMP/ashmem"; : > "$TMP/ashmem"; rm "$TMP/config.gz"
check "a stock kernel lacks all three" "$(host_kernel_lacks)" "built-in binder, $TMP/ashmem, $TMP/config.gz"
host_kernel_lacks >/dev/null;             check "a stock kernel lacks all three: rc" "$?" 1
mv "$TMP/binder-devices.away" "$TMP/binder-devices"
check "an ashmem that is no character device is lacking" "$(host_kernel_lacks)" "$TMP/ashmem, $TMP/config.gz"
check "the refusal says to boot the Rhizo kernel" "$(host_kernel_refusal "$TMP/config.gz")" \
  "$(uname -r) has no $TMP/config.gz: boot the Rhizo kernel (linux-image-rhizo on Ubuntu, linux-rhizo on CachyOS)"

STATE="$TMP/state"; REC="$TMP/state-subvolume"; mkdir -p "$STATE"
export RHIZO_STATE_DIR="$STATE" RHIZO_STATE_SUBVOLUME_RECORD="$REC"
SNAPSHOT="$REC records $STATE as a btrfs subvolume, and on this boot it is not one: this boot is a root snapshot\
 whose state subvolume is not mounted, and Rhizo does not run on it"
# run host_state_subvolume_check with a fake stat
subvol() { (
  stat() { case "$1 $2" in "-f -c") echo "$FAKE_FS" ;; "-c %i") echo "$FAKE_INO" ;; *) command stat "$@" ;; esac; }
  out=$(host_state_subvolume_check); echo "rc=$?|$out"
) }
FAKE_FS=btrfs FAKE_INO=4711
check "no record: a plain state dir passes"                 "$(subvol)" "rc=0|"
echo "$STATE" > "$REC"
check "recorded, a plain directory: refused, named"         "$(subvol)" "rc=1|$SNAPSHOT"
check "recorded, the subvolume's top: passes"               "$(FAKE_INO=256 subvol)" "rc=0|"
check "recorded, inode 256 on another filesystem: refused"  "$(FAKE_FS=ext2/ext3 FAKE_INO=256 subvol)" "rc=1|$SNAPSHOT"
rmdir "$STATE"
check "recorded, no state dir at all: refused"              "$(subvol)" "rc=1|$SNAPSHOT"
mkdir "$STATE"
check "the library writes the record this reads" "$(unset RHIZO_STATE_SUBVOLUME_RECORD RHIZO_STATE_DIR
  . "$HERE/../lib/host-flavor.sh"; . "$HERE/../lib/pkg-lib.sh"
  echo "$PKG_STATE_SUBVOLUME_RECORD $PKG_STATE_DIR" | grep -cxF "$RHIZO_STATE_SUBVOLUME_RECORD /var/lib/rhizo")" 1
out=$(bash "$HERE/../prepare/prepare.sh" --verify 2>"$TMP/prepare-err"); rc=$?
check "prepare on a root snapshot: refused first, by name" "$rc|${out##*$'\n'}|$(cat "$TMP/prepare-err")" \
  "1|RHIZO_PREPARE_REFUSED reason=root-snapshot-boot|[rhizo-host-prepare] REFUSED: $SNAPSHOT"
out=$(RHIZO_DERIVED_DIR="$TMP/derived" RHIZO_CACHE_DIR="$TMP/cache" RHIZO_GSI_ROOT="$TMP/srv" \
  bash "$HERE/../prepare/fetch-gsi.sh" --from-zip "$TMP/no-such.zip" 2>"$TMP/fetch-err"); rc=$?
check "the GSI fetch on a root snapshot: refused first, by name, nothing written" \
  "$rc|${out##*$'\n'}|$(cat "$TMP/fetch-err")|$(find "$TMP" -mindepth 1 -maxdepth 1 \( -name derived -o -name cache -o -name srv \) | wc -l)" \
  "1|RHIZO_GSI_REFUSED reason=root-snapshot-boot|[rhizo-host-fetch-gsi] REFUSED: $SNAPSHOT|0"
rm "$REC"; unset RHIZO_STATE_DIR RHIZO_STATE_SUBVOLUME_RECORD

(( FAILED )) && { echo "$FAILED failed"; exit 1; }
echo "test-host-flavor: ok"
