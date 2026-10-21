#!/bin/bash
# test the functions in prepare.sh
# shellcheck disable=SC2034
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../prepare/prepare.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "       got  $2"
    echo "       want $3"
    FAILED=$((FAILED + 1))
  fi
}

# print a function's definition from the script
lift() {
  awk -v f="$1" '$0 ~ "^" f "\\(\\) *\\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
for f in setup_boot_socket_state keep_or_release_setup_boot resolve_sandbox_paths sandbox_init_alive; do
  body=$(lift "$f")
  if [[ -z "$body" ]]; then
    echo "FAIL no $f() in $SCRIPT"
    exit 1
  fi
  eval "$body"
done
SANDBOX_ID=0
resolve_sandbox_paths

CALLS="$TMP/calls"
# print the stub needed-modules list or probe output
python3() {
  [[ "${2:-}" != needed-modules ]] || { printf '%s\n' "$NEEDED_MODULES"; return 0; }
  echo "probe $*" >> "$CALLS"; [[ -n "${PROBE_OUT:-}" ]] && printf '%s\n' "$PROBE_OUT"; return "${PROBE_RC:-0}"
}
# log its arguments
systemctl() { echo "systemctl $*" >> "$CALLS"; }
sync() { :; }
# log its arguments
log() { echo "log $*" >> "$CALLS"; }
# log the reason and exit 1
failstop() { echo "failstop $1" >> "$CALLS"; exit 1; }
# print the setup boot's kernel log lines
dmesg() {
  local now; now=$(cut -d' ' -f1 /proc/uptime)
  printf '[    4.000000] RHIZO_MARKER launch_start\n'
  printf '[    4.500000] wayland socket NOT FOUND -- tried /run/user/0/wayland-0 (absent)\n'
  case "${PARK:-}" in
    parked) awk -v n="$now" 'BEGIN{printf "[%12.6f] androidd-stop: supervisor parked, stack is stopped\n", n + 1}' ;;
    never)  awk -v n="$now" 'BEGIN{printf "[%12.6f] androidd-stop: supervisor never parked within 30s\n", n + 1}' ;;
    earlier) printf '[    5.000000] androidd-stop: supervisor parked, stack is stopped\n' ;;
  esac
}

# run keep_or_release_setup_boot and record its calls
run_case() {
  : > "$CALLS"
  # shellcheck disable=SC2034
  ( KEEP_RUNNING=$1; KEPT_RUNNING=0
    keep_or_release_setup_boot /payload/probe-client.py /run/rhizo/probe.sock
    echo "KEPT=$KEPT_RUNNING" >> "$CALLS" )
}
# print yes when the calls log holds the text
has() { grep -qF -- "$1" "$CALLS" && echo yes || echo no; }

PROBE_OUT=bound PROBE_RC=0 PARK=none run_case 1
check "a bound socket keeps the setup boot" "$(has KEPT=1)" yes
check "a kept setup boot is never stopped" "$(has 'systemctl stop')" no
check "the probe asks about the composer's own path" "$(has /dev/socket/rhizo_wayland/wayland-0)" yes
check "the kept boot says why" "$(has 'log leaving androidd.service running')" yes
check "a kept boot queues the Wants= its ignore-dependencies start skipped" \
      "$(has 'systemctl start --no-block androidd.service')" yes

PROBE_OUT=$'some banner\nbound' PARK=none run_case 1
check "only the probe's last line is the answer" "$(has KEPT=1)" yes

PROBE_OUT=absent PARK=parked run_case 1
check "an absent socket stops the setup boot" "$(has 'systemctl stop androidd.service')" yes
check "a released setup boot is not kept" "$(has KEPT=0)" yes
check "the release is logged with its socket state" "$(has 'log releasing the setup boot: socket absent')" yes
check "a park after the stop is accepted" "$(has 'log resident supervisor parked -- the next start hands off')" yes
check "a parked release does not failstop" "$(has failstop)" no
check "a released boot starts nothing" "$(has 'systemctl start')" no

PROBE_OUT=not-a-socket PARK=parked run_case 1
check "a placeholder with no socket on it releases" "$(has 'log releasing the setup boot: socket not-a-socket')" yes

PROBE_OUT="" PROBE_RC=97 PARK=parked run_case 1
check "an unreachable probe releases rather than keeps" "$(has 'log releasing the setup boot: socket unknown')" yes
check "an unreachable probe is never kept" "$(has KEPT=1)" no

PROBE_OUT="/system/bin/sh: [: permission denied" PROBE_RC=1 PARK=parked run_case 1
check "an answer that is not a state releases" "$(has 'log releasing the setup boot: socket unknown')" yes

PROBE_OUT=absent PROBE_RC=0 PARK=none run_case 1
check "no park line fails setup-boot-release-unparked" "$(has 'failstop setup-boot-release-unparked')" yes
PARK=never run_case 1
check "a supervisor that never parked fails by name" "$(has 'failstop setup-boot-release-unparked')" yes
PARK=earlier run_case 1
check "a park stamped before this stop is not this stop's" "$(has 'failstop setup-boot-release-unparked')" yes

PROBE_OUT=bound PARK=none run_case 0
check "the rig's run never asks the probe" "$(has probe)" no
check "the rig's run always stops" "$(has 'systemctl stop androidd.service')" yes
check "the rig's run never checks for a park" "$(has failstop)" no

for f in release_tree unit_env_file resolve_release prepare_release_gates point_at_release; do
  body=$(lift "$f")
  if [[ -z "$body" ]]; then
    echo "FAIL no $f() in $SCRIPT"
    exit 1
  fi
  eval "$body"
done
REL="$TMP/rel"
mkdir -p "$REL/srv/gsi_system/bin" "$REL/state/update"
echo init > "$REL/srv/gsi_system/bin/init"
export RHIZO_GSI_ROOT="$REL/srv"
ENVF="$REL/androidd.env"
RUNTIME_ENV="$REL/runtime.env"
PREPARE_REQUEST="$REL/state/prepare-request"
UPDATE_STATE="$REL/state/update/state"
FETCH_GSI="$REL/fetch.sh" GSI_UPDATE="$REL/gsi-update.sh"
printf '#!/bin/bash\necho "fetch $*" >> "%s"\n[[ "${FETCH_OUT:-}" == RHIZO_GSI_OK* ]] && mkdir -p "%s/srv/gsi_system_$2/bin" && echo init > "%s/srv/gsi_system_$2/bin/init"\necho "${FETCH_OUT:-RHIZO_GSI_ALREADY_STAGED=1}"\n' \
  "$CALLS" "$REL" "$REL" > "$FETCH_GSI"
printf '#!/bin/bash\necho "gsi-update $*" >> "%s"\n[[ "$1" == adopt ]] && { echo "RHIZO_GSI_UPDATE current=$3 candidate=- tries=- previous=-"; exit 0; }\necho "${KERNEL_OUT:-RHIZO_GSI_KERNEL_OK release=$3}"\n' \
  "$CALLS" > "$GSI_UPDATE"
# print the environment file line for cat
systemctl() { [[ "$1" == cat ]] && printf '[Service]\nEnvironmentFile=-%s\n' "$ENVF"; }
# log its arguments and exit 1
refuse() { echo "refuse $*" >> "$CALLS"; exit 1; }
# log its arguments and exit 1
failstop() { echo "failstop $*" >> "$CALLS"; exit 1; }

# print the values resolve_release sets
resolve_case() {
  ( RELEASE="$1" WIPE_DATA=0 VARIANT=user FROM_REQUEST=0
    resolve_release
    echo "$RELEASE $WIPE_DATA $VARIANT $FROM_REQUEST" )
}
rm -f "$PREPARE_REQUEST"; printf 'RHIZO_PERMISSIVE=1\n' > "$ENVF"
check "current with no request and no env release is a16" "$(resolve_case current)" "a16 0 user 0"
printf 'RHIZO_RELEASE=a15\n' >> "$ENVF"
check "current with no request is the release androidd.env boots" "$(resolve_case current)" "a15 0 user 0"
printf 'release=a15\nvariant=userdebug\nwipe_data=1\n' > "$PREPARE_REQUEST"
printf 'RHIZO_RELEASE=a16\n' > "$ENVF"
check "current with a deferred request takes its release, variant and wipe" \
      "$(resolve_case current)" "a15 1 userdebug 1"
printf 'release=current\nvariant=\nwipe_data=0\n' > "$PREPARE_REQUEST"
check "a request for the current release resolves it from androidd.env" "$(resolve_case current)" "a16 0 user 1"
check "an explicit release ignores a request" "$(resolve_case a16)" "a16 0 user 0"
rm -f "$PREPARE_REQUEST"

# run prepare_release_gates and record its calls
tests_case() {
  : > "$CALLS"
  ( RELEASE="$1" GSI_EXPLICIT="$2" GSI=$(release_tree "$1") STAGED_TREE=0
    prepare_release_gates
    echo "rc=0 staged=$STAGED_TREE" >> "$CALLS" )
}
FETCH_OUT="RHIZO_GSI_OK release=a15 tree=x sha256=x" tests_case a15 0
check "a release's gates ask gsi-update whether this kernel runs it" "$(has 'gsi-update kernel-check --release a15')" yes
check "an unstaged release's tree is fetched and staged" "$(has 'fetch --release a15')" yes
check "a system test run that staged it says so, for mark_change" "$(has 'rc=0 staged=1')" yes
tests_case a15 0
check "an already-staged tree is fetched again, which derives its own files" "$(has 'fetch --release a15')" yes
check "an already-staged tree is no change" "$(has 'rc=0 staged=0')" yes
rm -rf "$REL/srv/gsi_system_a15"
tests_case a15 0
check "a fetch that reports a tree staged and leaves none fails no-gsi-tree" "$(has 'failstop no-gsi-tree')" yes
KERNEL_OUT="RHIZO_GSI_UPDATE_REFUSED reason=kernel-unsupported" tests_case a17 0
check "a kernel that cannot run the release refuses kernel-unsupported" "$(has 'refuse kernel-unsupported')" yes
check "that refusal stages nothing" "$(has 'fetch ')" no
FETCH_OUT="RHIZO_GSI_FAILED reason=gsi-libs-missing" tests_case a15 0
check "a tree the fetch could not stage or derive fails gsi-stage" "$(has 'failstop gsi-stage')" yes
tests_case a16 1
check "an explicit --gsi tree is never fetched" "$(has 'fetch ')" no
printf 'good_release=a16\ntrial_release=a17\ntrial_tries=2\n' > "$UPDATE_STATE"
tests_case a15 0
check "switching release under an armed trial refuses trial-in-flight" "$(has 'refuse trial-in-flight')" yes
tests_case a16 1
check "re-preparing the good release under an armed trial goes ahead" "$(has 'rc=0')" yes
rm -f "$UPDATE_STATE"

# run point_at_release for a15 and record calls
point_case() {
  : > "$CALLS"
  ( RELEASE=a15 GSI="$REL/srv/gsi_system_a15" SANDBOX_ID="$1" ANDROIDD_UNIT=androidd.service
    point_at_release
    echo "rc=0" >> "$CALLS" )
}
printf 'RHIZO_PERMISSIVE=1\nRHIZO_GSI=/srv/rhizo/gsi_system\nRHIZO_RELEASE=a16\n' > "$RUNTIME_ENV"
printf 'RHIZO_PERMISSIVE=1\n' > "$ENVF"
point_case 0
check "pointing leaves the conffile as it was" "$(cat "$ENVF")" "RHIZO_PERMISSIVE=1"
check "the sandbox is pointed at the prepared release" "$(sed -n 's/^RHIZO_RELEASE=//p' "$RUNTIME_ENV")" a15
check "the sandbox is pointed at the prepared tree" "$(sed -n 's/^RHIZO_GSI=//p' "$RUNTIME_ENV")" "$REL/srv/gsi_system_a15"
check "pointing keeps every other line" "$(sed -n 's/^RHIZO_PERMISSIVE=//p' "$RUNTIME_ENV")" 1
check "with no gsi state there is nothing to adopt" "$(has 'gsi-update adopt')" no
printf 'good_release=a16\nprevious_release=a17\n' > "$UPDATE_STATE"
point_case 0
check "with gsi state the prepared release is adopted as current" "$(has 'gsi-update adopt --release a15')" yes
check "pointing again leaves one RHIZO_RELEASE line" "$(grep -c '^RHIZO_RELEASE=' "$RUNTIME_ENV")" 1
printf 'RHIZO_RELEASE=a16\n' > "$RUNTIME_ENV"
point_case 2
check "an instance above 0 leaves the host's release alone" "$(cat "$RUNTIME_ENV")" "RHIZO_RELEASE=a16"
check "an instance above 0 adopts nothing" "$(has 'gsi-update adopt')" no
rm -f "$UPDATE_STATE"

# create a fake /proc entry for a pid
fakeproc() {
  local pid="$1" cg="$2"; shift 2
  mkdir -p "$TMP/proc/$pid"
  printf '%s\0' "$@" > "$TMP/proc/$pid/cmdline"
  printf '0::%s\n' "$cg" > "$TMP/proc/$pid/cgroup"
}
fakeproc 1200 /user.slice/user-1000.slice/session-3.scope init second_stage
fakeproc 1300 /rhizo-host init second_stage
fakeproc 1500 /rhizo-2/init init second_stage
fakeproc 4242 /rhizo/init init second_stage
fakeproc 10001 /rhizo/init init second_stage
bash -c 'exec -a "init second_stage" sleep 60' &
real_decoy=$!
PROC_ROOT="$TMP/proc"
SANDBOX_ID=0; resolve_sandbox_paths; INIT_PID_FILE="$TMP/absent-pidfile"
check "id 0 with no pid file: the guard finds the init in the stack's cgroup, past decoys" "$(sandbox_init_alive)" 4242
rm -rf "$TMP/proc/4242" "$TMP/proc/10001"
fakeproc 4343 /system.slice/androidd.service/android/init init second_stage
check "id 0 with no pid file under androidd.service's delegated cgroup: its init" "$(sandbox_init_alive)" 4343
rm -rf "$TMP/proc/4343"
check "id 0 with no pid file and only decoys outside the stack: nothing is alive" "$(sandbox_init_alive)" ""
echo 1500 > "$TMP/pidfile-2"
SANDBOX_ID=2; resolve_sandbox_paths; INIT_PID_FILE="$TMP/pidfile-2"
check "an instance's own pid file naming its live init: that pid" "$(sandbox_init_alive)" 1500
INIT_PID_FILE="$TMP/absent-pidfile"
check "an instance above 0 with no pid file never scans" "$(sandbox_init_alive)" ""
kill "$real_decoy" 2>/dev/null
wait "$real_decoy" 2>/dev/null
SANDBOX_ID=0; resolve_sandbox_paths

. "$HERE/../lib/host-flavor.sh"
. "$HERE/../prepare/kernel-changed.sh"
BM="$TMP/kernel"; CONF="$BM/rhizo.conf"
mkdir -p "$BM/sys/binder/parameters" "$BM/state/prepared"
# shellcheck disable=SC2034
RHIZO_BINDER_DEVICES_FILE="$BM/sys/binder/parameters/devices" RHIZO_ASHMEM_DEVICE="$BM/ashmem"
RHIZO_PROC_CONFIG="$BM/config.gz"
for f in needed_modules write_modules_load_conf require_rhizo_kernel verify_kernel verify_modules_load; do
  body=$(lift "$f")
  if [[ -z "$body" ]]; then
    echo "FAIL no $f() in $SCRIPT"
    exit 1
  fi
  eval "${body//\/etc\/modules-load.d\/rhizo.conf/$CONF}"
done
PAYLOAD="$BM/payload"
mkdir -p "$BM/gsi" && printf 'ro.debuggable=0\n' > "$BM/gsi/build.prop"
NEEDED_MODULES=$(RHIZO_GSI="$BM/gsi" command python3 -B "$HERE/../../androidd/boot.py" needed-modules) \
  && [[ -n "$NEEDED_MODULES" ]] || { echo "FAIL boot.py needed-modules printed no list" >&2; exit 1; }
# print a fixed kernel release
uname() { echo 7.2.9-1-cachyos; }
# log its arguments
mark_change() { echo "mark_change $*" >> "$CALLS"; }
# print the logged calls separated by semicolons
calls() { tr '\n' ';' < "$CALLS"; }
# make the fixture host boot a Rhizo or stock kernel
reset_host() {
  rm -rf "$BM/sys"/* "$BM/ashmem" "$CONF" "$RHIZO_PROC_CONFIG"
  : > "$CALLS"
  [[ "${1:-}" == stock ]] && return 0
  mkdir -p "$BM/sys/binder/parameters"; echo "${1:-binder,hwbinder,vndbinder}" > "$RHIZO_BINDER_DEVICES_FILE"
  ln -s /dev/null "$BM/ashmem"; touch "$RHIZO_PROC_CONFIG"
}
STOCK="$(host_kernel_refusal "built-in binder, $BM/ashmem, $RHIZO_PROC_CONFIG")"

# print the modules write_modules_load_conf names
mods_case() {
  : > "$CALLS"; rm -f "$CONF"
  ( write_modules_load_conf )
  if [[ -s "$CONF" ]]; then grep -v '^#' "$CONF" | LC_ALL=C sort | tr '\n' ' '; else echo "no conf: $(calls)"; fi
}
# print the sorted union of the given and needed modules
with_needed() { { printf '%s\n' "$@" "$NEEDED_MODULES"; } | LC_ALL=C sort -u | tr '\n' ' '; }
reset_host
check "the modules-load set is the netfilter sweep, the fixed five and the needed modules, no binder module" \
      "$(mods_case)" "$(with_needed dm-mod dm-verity loop tun uinput)"
check "the conf names the kernel it was written on" "$(grep -c '^# kernel=7.2.9-1-cachyos$' "$CONF")" 1
check "the apply flow writes the modules-load set right after the kernel check" \
      "$(grep -A1 -xF '(( RESUME )) || require_rhizo_kernel' "$SCRIPT" | tail -1)" "(( RESUME )) || write_modules_load_conf"

# print require_rhizo_kernel's calls
kernel_case() { : > "$CALLS"; ( require_rhizo_kernel; echo "passed" >> "$CALLS" ); calls; }
reset_host
check "the Rhizo kernel passes" "$(kernel_case)" "passed;"
reset_host stock
check "a stock kernel refuses not-rhizo-kernel, saying to boot the Rhizo kernel" "$(kernel_case)" \
      "refuse not-rhizo-kernel $STOCK;"
reset_host; rm "$RHIZO_PROC_CONFIG"
check "a kernel with no /proc/config.gz refuses, naming it alone" "$(kernel_case)" \
      "refuse not-rhizo-kernel $(host_kernel_refusal "$RHIZO_PROC_CONFIG");"
reset_host binder
WANT="refuse binder-builtin-devices this kernel's built-in binder creates devices 'binder' -- 'rhizo install'"
WANT+=" writes binder.devices=binder,hwbinder,vndbinder to the kernel cmdline; reboot once it has;"
check "built-in binder with the wrong devices refuses binder-builtin-devices, naming them" "$(kernel_case)" "$WANT"

REFRESH=$(awk '/^if \[\[ "\$MODE" == kernel-refresh \]\]; then$/ {on=1} on {print} on && /^fi$/ {exit}' "$SCRIPT")
# shellcheck disable=SC2016
REFRESH=${REFRESH//'[[ $EUID -eq 0 ]] || refuse "not-root" "must run as root"'/:}
REFRESH=${REFRESH//\/var\/lib\/rhizo/$BM/state}
check "the kernel-refresh block is in the script" "$(grep -c 'RHIZO_PREPARE_KERNEL_REFRESHED=1' <<<"$REFRESH")" 3
# run the kernel-refresh block and print results
refresh_case() {
  local out
  : > "$CALLS"
  # shellcheck disable=SC2034
  out=$( ( MODE=kernel-refresh PAYLOAD="$BM/payload"; eval "$REFRESH" ) )
  echo "${out##*$'\n'}|$(grep -E '^(refuse|failstop)' "$CALLS" | tr '\n' ';')"
}
reset_host
check "the Rhizo kernel refreshes" "$(refresh_case)" "RHIZO_PREPARE_KERNEL_REFRESHED=1 kernel=7.2.9-1-cachyos|"
reset_host stock
REFUSED="|refuse not-rhizo-kernel $STOCK;"
check "a stock kernel's refresh refuses not-rhizo-kernel" "$(refresh_case)" "$REFUSED"
mkdir -p "$BM/payload"; echo 0.1.4 > "$BM/payload/VERSION"
# write a marker file and run refresh_case
marker_case() {
  printf '%s' "$1" > "$BM/state/.prepared"
  local out; out=$(refresh_case)
  if [[ ! -e "$BM/state/.prepared" ]]; then echo "$out|absent"; return; fi
  echo "$out|$(tr '\n' ' ' < "$BM/state/.prepared")"
}
GONE="log kernel-refresh: $BM/state/.prepared names payload 0.1.3 and $BM/payload/VERSION 0.1.4: removed"
check "a marker another payload wrote is removed before the kernel checks" \
      "$(marker_case $'kernel=7.2.9-1-cachyos\nversion=0.1.3\n')|$(grep -cF "$GONE" "$CALLS")" \
      "RHIZO_PREPARE_KERNEL_REFRESHED=1 kernel=7.2.9-1-cachyos prepared=payload-changed||absent|1"
check "a marker this payload wrote is kept, and the kernel checks run" \
      "$(marker_case $'kernel=7.2.9-1-cachyos\nversion=0.1.4\n')" "$REFUSED|kernel=7.2.9-1-cachyos version=0.1.4 "
check "a marker with no version= line is kept" \
      "$(marker_case $'kernel=7.2.9-1-cachyos\n')" "$REFUSED|kernel=7.2.9-1-cachyos "
check "a marker with an empty version= is kept" \
      "$(marker_case $'kernel=7.2.9-1-cachyos\nversion=\n')" "$REFUSED|kernel=7.2.9-1-cachyos version= "
check "the refresh decides through kernel-changed.sh's payload_changed, the condition's own test" \
      "$( payload_changed() { return 1; }; marker_case $'kernel=7.2.9-1-cachyos\nversion=0.1.3\n')" \
      "$REFUSED|kernel=7.2.9-1-cachyos version=0.1.3 "
rm "$BM/payload/VERSION"
check "a payload with no VERSION file keeps the marker" \
      "$(marker_case $'kernel=7.2.9-1-cachyos\nversion=0.1.3\n')" "$REFUSED|kernel=7.2.9-1-cachyos version=0.1.3 "
rm "$BM/state/.prepared"

# run a verify function and print its results
verify_case() {
  local rc=0
  : > "$CALLS"
  ( "$1" ) 2>"$BM/verify-err" || rc=$?
  echo "$(calls)stderr=[$(< "$BM/verify-err")]rc=$rc"
}
NEEDED_COMMA=${NEEDED_MODULES//$'\n'/, }
NEEDED_SLASH=${NEEDED_MODULES//$'\n'//}
reset_host; printf '# x\nuinput\ntun\n%s\n' "$NEEDED_MODULES" > "$CONF"
check "the modules-load verify line names uinput, tun and the needed modules" \
      "$(verify_case verify_modules_load)" \
      "log   modules-load.d: $CONF present and names uinput, tun, $NEEDED_COMMA;stderr=[]rc=0"
MISSING="log   modules-load.d: $CONF missing or does not name uinput/tun/$NEEDED_SLASH;"
printf 'uinput\n%s\n' "$NEEDED_MODULES" > "$CONF"
check "a conf without tun fails verify" "$(verify_case verify_modules_load)" "${MISSING}stderr=[]rc=1"
rm "$CONF"
check "no conf fails verify in one line, nothing on stderr" "$(verify_case verify_modules_load)" "${MISSING}stderr=[]rc=1"
check "the Rhizo kernel verifies" "$(verify_case verify_kernel)" \
      "log   kernel: built-in binder (devices=binder,hwbinder,vndbinder), $BM/ashmem and $RHIZO_PROC_CONFIG present;stderr=[]rc=0"
reset_host stock
check "a stock kernel fails verify, saying to boot the Rhizo kernel" "$(verify_case verify_kernel)" \
      "log   kernel: $STOCK;stderr=[]rc=1"
reset_host binder
check "built-in binder with the wrong devices fails verify" "$(verify_case verify_kernel)" \
      "log   kernel: built-in binder creates devices 'binder', not binder,hwbinder,vndbinder;stderr=[]rc=1"

body=$(lift require_render_node)
if [[ -z "$body" ]]; then
  echo "FAIL no require_render_node() in $SCRIPT"
  exit 1
fi
eval "$body"
PAYLOAD="$HERE/../prepare"
mkdir -p "$TMP/gpu/sys" "$TMP/gpu/dev"
# print the fixture's androidd.env path
unit_env_file() { echo "${ENV_FIXTURE:-}"; }
# run require_render_node on the fixture sysfs and print its calls
render_case() {
  : > "$CALLS"
  ( RHIZO_SYS_CLASS_DRM="$TMP/gpu/sys" RHIZO_DEV_DRI="$TMP/gpu/dev" require_render_node; echo "rc=$?" >> "$CALLS" )
  paste -sd';' "$CALLS"
}
WHY="devices.dri is on, so the sandbox's graphics allocator opens the host's render node and no boot"
WHY+=" completes without one: this host needs a GPU driver with a render node (a VM: a virtio-gpu device"
WHY+=" with 3D enabled), or set [devices] dri = off in /etc/rhizo/policy.conf (or run rhizo gpu off) to"
WHY+=" render in software"
check "a host with no render node is refused in the gpu resolver's words" "$(render_case)" \
      "refuse no-render-node no render node under $TMP/gpu/sys -- $WHY"
for row in "renderD128 2147483648 card0" "renderD129 17095983104 card1"; do
  read -r name vram card <<<"$row"
  mkdir -p "$TMP/gpu/sys/$name/device/drm/$card"
  echo DRIVER=amdgpu > "$TMP/gpu/sys/$name/device/uevent"
  echo "$vram" > "$TMP/gpu/sys/$name/device/mem_info_vram_total"
done
check "a chosen render node with no device file is refused by name" "$(render_case)" \
      "refuse no-render-node no $TMP/gpu/dev/renderD129 -- $WHY"
: > "$TMP/gpu/dev/renderD129"
check "a regular file at the chosen render node's path is no render node" "$(render_case)" \
      "refuse no-render-node no $TMP/gpu/dev/renderD129 -- $WHY"
rm "$TMP/gpu/dev/renderD129"; ln -s /dev/null "$TMP/gpu/dev/renderD129"
check "a character device at the chosen render node's path passes" "$(render_case)" "rc=0"
rm "$TMP/gpu/dev/renderD129"; ln -s /dev/null "$TMP/gpu/dev/renderD128"
printf 'RHIZO_RENDER_NODE=%s\n' "$TMP/gpu/dev/renderD128" > "$TMP/gpu/androidd.env"
check "the unit's androidd.env names the render node" "$(ENV_FIXTURE="$TMP/gpu/androidd.env" render_case)" "rc=0"
check "the render node and the prepared tree's driver come from the gpu resolver with the unit's env file" \
      "$(grep -c 'detect-gpu-driver.sh" --node --env-file "$env_file"' "$SCRIPT")/$(grep -c 'detect-gpu-driver.sh" --env-file "$(unit_env_file)"' "$SCRIPT")" \
      "2/1"
GATE='(( SKIP_SETUP_BOOT )) || [[ "$DRI" == False ]] || require_render_node'
ask=$(grep -nxF "$GATE" "$SCRIPT" | cut -d: -f1)
read_at=$(grep -nxF 'DRI=$(read_dri)' "$SCRIPT" | cut -d: -f1)
refuse_at=$(grep -n '^\[\[ "\$DRI" == Error:\* \]\] && refuse "host-policy-error" ' "$SCRIPT" | cut -d: -f1)
check "step 0 reads devices.dri once, refuses a host policy that does not parse by name, then gates the render node" \
      "$(( ${read_at:-99999} < ${refuse_at:-0} && ${refuse_at:-99999} < ${ask:-0} ))" 1
stage=$(grep -n '^(( RESUME )) || prepare_release_gates$' "$SCRIPT" | cut -d: -f1)
check "step 0 asks for the render node unless --skip-setup-boot or devices.dri is off" "${ask:+asked}" asked
check "the render node is asked for before the release's tree is staged" \
      "$(( ${ask:-99999} < ${stage:-0} ))" 1
# run the render node gate and print whether it asked
gate_case() {
  ( SKIP_SETUP_BOOT=$1; DRI=$2
    require_render_node() { echo asked; }
    eval "$GATE" )
}
# run the host policy refusal and print its token
refuse_case() {
  ( DRI=$1
    refuse() { echo "$1"; }
    eval "$(sed -n "${refuse_at:-0}p" "$SCRIPT")" )
}
check "step 0 refuses a host policy that does not parse as host-policy-error" \
      "$(refuse_case "Error: /etc/rhizo/policy.conf: [devices] dri='maybe', expected yes or no")" host-policy-error
check "step 0 does not refuse a policy that reads devices.dri off" "$(refuse_case False)" ""
check "step 0 asks for the render node with devices.dri on" "$(gate_case 0 True)" asked
check "step 0 does not ask for the render node with devices.dri off" "$(gate_case 0 False)" ""
check "step 0 does not ask for the render node with --skip-setup-boot" "$(gate_case 1 True)" ""
check "step 0 asks for the render node when devices.dri cannot be read" "$(gate_case 0 '')" asked

body=$(lift read_dri)
if [[ -z "$body" ]]; then
  echo "FAIL no read_dri() in $SCRIPT"
  exit 1
fi
eval "$body"
# print read_dri's answer for a policy text
dri_case() {
  printf '%b' "$1" > "$TMP/dri.conf"
  ( unset -f python3; PAYLOAD="$HERE/../../androidd"; export RHIZO_POLICY_CONF="$TMP/dri.conf"; read_dri 2>/dev/null )
}
check "read_dri reads dri = off through the payload's own parser" "$(dri_case '[devices]\ndri = off\n')" False
check "read_dri reads a policy with no devices.dri as on" "$(dri_case '[rhizo]\nprofile = server\n')" True
check "read_dri names why a policy.conf does not parse instead of reading it as off" \
      "$(dri_case '[devices]\ndri = maybe\n' | sed 's/^\(Error: \).*\(expected yes or no\)$/\1\2/')" "Error: expected yes or no"

body=$(lift prepare_tree)
if [[ -z "$body" ]]; then
  echo "FAIL no prepare_tree() in $SCRIPT"
  exit 1
fi
eval "$body"
mkdir -p "$TMP/payload/gpu_driver_amd/egl" "$TMP/payload/gpu_driver_amd/lib"
# run prepare_tree on an amd host and print its argv
tree_case() {
  : > "$CALLS"
  ( PAYLOAD="$TMP/payload"; PREPARED_ROOT="$TMP/prepared"; TREE_DRI=$1
    read_dri() { echo "$TREE_DRI"; }
    bash() { echo amd; }
    configured_selinux_mode() { echo namespace; }
    python3() { echo "tree $*" >> "$CALLS"; echo "PREPARE_TREE_OK key=abcdefabcdef inputs=1 outputs=1"; }
    readlink() { echo abcdefabcdef; }
    mark_change() { :; }
    prune_prepared() { :; }
    refuse() { echo "refuse $1" >> "$CALLS"; exit 1; }
    prepare_tree ) >/dev/null 2>&1
  sed -n 's/^tree //p' "$CALLS"
}
check "prepare_tree stages the host's amd set with devices.dri on" "$(tree_case True)" \
      "$TMP/payload/launcher3.py prepare-tree $TMP/prepared --gpu-driver gpu_driver_amd"
check "prepare_tree passes no gpu driver with devices.dri off, so the tree takes the software set" \
      "$(tree_case False)" "$TMP/payload/launcher3.py prepare-tree $TMP/prepared"

body=$(lift setup_boot_completed)
if [[ -z "$body" ]]; then
  echo "FAIL no setup_boot_completed() in $SCRIPT"
  exit 1
fi
eval "$body"
start='[   34.098231] L3: RHIZO_MARKER launch_start sandbox=0'
done_='[   37.372311] RHIZO_MARKER sys.boot_completed=1 sandbox=0'
start2='[   71.428082] L3: RHIZO_MARKER launch_start sandbox=0'
done2='[   89.200011] RHIZO_MARKER sys.boot_completed=1 sandbox=0'
check "the setup boot wait ignores the boot_completed of an earlier start on this boot" \
      "$(printf '%s\n' "$start" "$done_" | setup_boot_completed 1)" ""
check "the setup boot wait ignores an earlier boot_completed after this run's own launch_start" \
      "$(printf '%s\n' "$start" "$done_" "$start2" | setup_boot_completed 1)" ""
check "the setup boot wait answers this run's own boot_completed" \
      "$(printf '%s\n' "$start" "$done_" "$start2" "$done2" | setup_boot_completed 1)" "1"
check "the setup boot wait answers the first start of a boot" "$(printf '%s\n' "$start" "$done_" | setup_boot_completed 0)" "1"

body=$(lift check_selinux_for_setup)
if [[ -z "$body" ]]; then
  echo "FAIL no check_selinux_for_setup() in $SCRIPT"
  exit 1
fi
eval "$body"
mkdir -p "$TMP/modebin"
# run check_selinux_for_setup against a fixture and print its calls
selinux_case() {
  local out="$1"
  : > "$CALLS"; : > "$TMP/modebin/asked"
  [[ "$1" != refuse:* ]] || out+="${5-$'\t'why-text}"
  printf '#!/bin/bash\necho "$*" >> %q\n%s\nprintf "%%s\\n" %q\n' "$TMP/modebin/asked" "${4:-}" "$out" \
    > "$TMP/modebin/rhizo-selinux-mode"
  chmod +x "$TMP/modebin/rhizo-selinux-mode"
  (
    lsm_file="$TMP/modebin/lsm"; enforce_file="$TMP/modebin/enforce"
    rm -f "$lsm_file" "$enforce_file"
    [[ -n "$2" ]] && printf '%s' "$2" > "$lsm_file"
    [[ -n "$3" ]] && printf '%s' "$3" > "$enforce_file"
    body2=${body//\/usr\/lib\/rhizo\/rhizo-selinux-mode/$TMP/modebin/rhizo-selinux-mode}
    body2=${body2//\/sys\/kernel\/security\/lsm/$lsm_file}
    body2=${body2//\/sys\/fs\/selinux\/enforce/$enforce_file}
    GSI=/srv/gsi
    eval "$body2"
    check_selinux_for_setup; echo "ok" >> "$CALLS" ) >/dev/null 2>&1
  paste -sd';' "$CALLS"
}
check "namespace mode needs no host selinux or enforce node" "$(selinux_case namespace '' '')" "ok"
check "host mode with selinux active and enforce 0 passes" "$(selinux_case host 'capability,selinux' 0)" "ok"
check "host mode with enforce 1 is refused as enforcing" "$(selinux_case host 'capability,selinux' 1)" \
      "refuse enforcing $TMP/modebin/enforce=1 -- this step runs only before Android's policy is loaded"
check "host mode without selinux in the lsm list is refused" "$(selinux_case host 'capability,apparmor' '')" \
      "refuse selinux-not-active selinux is not an active LSM (got 'capability,apparmor') -- run install/bootstrap/bootstrap.sh and reboot first"
check "a refused mode is refused with the helper's why text and the mode" \
      "$(selinux_case refuse:kernel-has-no-selinux-namespaces '' '')" \
      "refuse selinux-mode why-text (refuse:kernel-has-no-selinux-namespaces)"
check "a mode helper that crashes is refused by its exit, never an empty reason" \
      "$(selinux_case host 'capability,selinux' 0 'echo boom >&2; exit 255')" \
      "refuse selinux-mode $TMP/modebin/rhizo-selinux-mode exited 255 reading this boot's SELinux mode"
check "a refusal asks the mode helper once, for the mode and its why together" \
      "$(selinux_case refuse:x '' '' >/dev/null; cat "$TMP/modebin/asked")" "--env-file /etc/rhizo/androidd.env --mode-and-why"
check "a refusal the helper gives no why is refused naming the helper" "$(selinux_case refuse:x '' '' '' '')" \
      "refuse selinux-mode $TMP/modebin/rhizo-selinux-mode named no reason (refuse:x)"
check "a mode helper printing no mode it knows is refused by what it printed" "$(selinux_case permissive '' '')" \
      "refuse selinux-mode $TMP/modebin/rhizo-selinux-mode printed 'permissive', not namespace, host or refuse:<reason>"
check "the mode helper is RHIZO_SELINUX_MODE_HELPER's when set, as configured_selinux_mode's is" \
      "$(grep -c 'helper="${RHIZO_SELINUX_MODE_HELPER:-/usr/lib/rhizo/rhizo-selinux-mode}"' <<<"$body")" 1

if (( FAILED )); then
  echo "$FAILED checks failed"
  exit 1
fi
echo "0 checks failed"
