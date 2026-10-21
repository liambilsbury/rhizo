#!/bin/bash
# build the offline pacman pool in share/arch-pool
set -euo pipefail
tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$tools/../../../.."
mode=build
case "${1:-}" in
  "") ;;
  --prove) mode=prove ;;
  *) echo "usage: arch-pool.sh [--prove]" >&2; exit 2 ;;
esac
# shellcheck source=../../../../test/vm/guest-os/cachyos-guest-lib.sh
source "$tools/../../../../test/vm/guest-os/cachyos-guest-lib.sh"
# shellcheck source=arch-pool-lib.sh
source "$tools/arch-pool-lib.sh"

kernel_dir="${RHIZO_KERNEL_PKG_DIR:-var/arch-kernel}"
mapfile -t kernel_names < <(arch_pool_pkgbuild_kernel_names archlinux/rhizo/PKGBUILD.in)
(( ${#kernel_names[@]} )) || { echo "archlinux/rhizo/PKGBUILD.in depends on no Rhizo kernel package" >&2; exit 1; }
kernel_files=$(arch_pool_kernel_pkgs "$kernel_dir" "${kernel_names[@]}")
mapfile -t kernel_file_list <<<"$kernel_files"
kernel_depends=$(arch_pool_kernel_depends "${kernel_file_list[@]}")
# shellcheck disable=SC2034
[[ -z "$kernel_depends" ]] || mapfile -t ARCH_POOL_KERNEL_DEPENDS <<<"$kernel_depends"

dl=var/cachyos-dl
stock="$dl/cachyos-stock"
pool=var/share/arch-pool
dl_dir=/var/tmp/rhizo-arch-pool
OFFLINE_BUDGET=1800
cachyos_build_lock
scratch=$(mktemp -d "$PWD/$dl/scratch.XXXXXX")

# stop the guest and remove the scratch directory
cleanup() {
  stop_guest
  rm -rf "$scratch"
}
trap cleanup EXIT

# boot an overlay of the stock base image
boot_stock() {
  boot_overlay "$stock.qcow2" "$stock.OVMF_VARS.fd" "$scratch/$1" "$dl/arch-pool-$1.log"
  expect 9p findmnt -no FSTYPE /root/share
}

# set targets to the packages to install
request_targets() {
  local out
  out=$(arch_pool_targets) || exit 1
  mapfile -t targets <<<"$out"
}

# download the packages and build share/arch-pool
build_pool() {
  local out="$scratch/build/share/arch-pool" f sums
  mkdir -p "$out"
  boot_stock build
  request_targets
  guest_step 600 pacman -Sy
  guest_step 30 mkdir -p "$dl_dir"
  guest_step 3000 pacman -Sw --noconfirm --cachedir "$dl_dir" "${targets[@]}"
  guest_step 600 "cp -- $dl_dir/*.pkg.tar.zst $dl_dir/*.pkg.tar.zst.sig $ARCH_POOL_GUEST_DIR/"
  guest_step 600 "cd $ARCH_POOL_GUEST_DIR && repo-add $ARCH_POOL_REPO.db.tar.zst *.pkg.tar.zst"
  arch_pool_manifest || exit 1
  guest_poweroff

  for f in "$out"/*; do
    [[ -L "$f" ]] || continue
    cp -L -- "$f" "$f.new"
    mv -f -- "$f.new" "$f"
  done
  arch_pool_conf "$out/pacman.conf"
  printf '%s' "${kernel_depends:+$kernel_depends$'\n'}" > "$out/$ARCH_POOL_KERNEL_RECORD"
  echo "$stock_sha  cachyos-stock.qcow2" > "$out/POOL.base"
  sums=$(cd "$out" && find . -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort | xargs -r -d '\n' sha256sum --)
  printf '%s\n' "$sums" > "$out/POOL.sha256"
  rm -rf -- "$pool"
  mv -- "$out" "$pool"
  cat "$pool/MANIFEST.tsv"
  echo "built $pool from $(wc -l < "$pool/MANIFEST.tsv") packages in $(wc -l < "$pool/POOL.sha256") files, $(du -sh "$pool" | cut -f1)"
}

# run a command with the guest network down
run_offline() {
  local share="$1" t0=$SECONDS died=0 state
  rm -f "$share"/offline.{rc,out,go,started,ended,nic}
  printf '%s\n' "$2" > "$share/offline.cmd"
  cp --remove-destination "$tools/run-offline.sh" "$share/offline.sh"
  cp --remove-destination "$tools/restore-network.sh" "$share/offline.post"
  chmod +x "$share/offline.post"
  guest_step 30 systemd-run --no-block --quiet --unit=rhizo-offline -p ExecStopPost=/root/share/offline.post bash /root/share/offline.sh
  until [[ -f "$share/offline.started" ]]; do
    (( SECONDS - t0 < 30 )) || { echo "the unit rhizo-offline wrote no start marker in 30s, and systemd says:" >&2; guest 30 systemctl status rhizo-offline --no-pager >&2 || echo "systemctl status exited $?" >&2; exit 1; }
    sleep 1
  done
  : > "$share/offline.go"
  t0=$SECONDS
  until [[ -f "$share/offline.rc" ]]; do
    if [[ -f "$share/offline.ended" && ! -f "$share/offline.rc" ]]; then died=1; break; fi
    # shellcheck disable=SC2154
    kill -0 "$qemu_pid" 2>/dev/null || fail_log "qemu exited while the guest ran with its network down" "$share/offline.out"
    (( SECONDS - t0 < OFFLINE_BUDGET )) || fail_log "no result after ${OFFLINE_BUDGET}s with the network down" "$share/offline.out"
    sleep 2
  done
  t0=$SECONDS
  until guest 15 true; do
    kill -0 "$qemu_pid" 2>/dev/null || fail_log "qemu exited while the guest's network came back" "$share/offline.out"
    (( SECONDS - t0 < 120 )) || fail_log "ssh did not answer 120s after the interface came back" "$share/offline.out"
    sleep 2
  done
  if (( died )); then
    state=$(guest 30 systemctl show -p ActiveState -p Result rhizo-offline 2>&1) || state="systemctl show exited $?: $state"
    fail_log "the unit rhizo-offline wrote no result; systemd's post step says $(<"$share/offline.ended"), and the unit is now $(tr '\n' ' ' <<<"$state")" "$share/offline.out"
  fi
  proof_rc=$(<"$share/offline.rc")
  proof_out=$(<"$share/offline.out")
  case "$proof_rc" in
    9[3-8]) echo "the unit stopped before the install with status $proof_rc:" >&2; echo "$proof_out" >&2; exit 1 ;;
  esac
  [[ "$proof_out" == *" is DOWN"* ]] || { echo "the unit's output never says the interface was DOWN:" >&2; echo "$proof_out" >&2; exit 1; }
}

# install the pool packages with the network down
install_leg() {
  local leg="$1" conf="$2" t0=$SECONDS line url
  local -a urls
  mkdir -p "$scratch/$leg/share"
  cp -al -- "$pool" "$scratch/$leg/share/arch-pool"
  boot_stock "$leg"
  request_targets
  arch_pool_options_match || exit 1
  run_offline "$scratch/$leg/share" "pacman --debug --config $conf -Sy --noconfirm ${targets[*]}"
  mapfile -t urls < <(grep -o 'url is [a-z]*://' <<<"$proof_out" || [[ $? -eq 1 ]])
  urls_file=0 urls_other=0
  for url in "${urls[@]}"; do
    if [[ "$url" == "url is file://" ]]; then urls_file=$((urls_file + 1)); else urls_other=$((urls_other + 1)); fi
  done
  echo "on the $leg leg pacman --config $conf -Sy --noconfirm ${targets[*]} exited $proof_rc after $((SECONDS - t0))s and downloaded from $urls_file file:// urls and $urls_other others"
  while IFS= read -r line; do
    [[ "$line" == debug:* ]] || printf '%s\n' "$line"
  done <<<"$proof_out"
}

# check the guest holds the pool packages
expect_pool_installed() {
  local names
  mapfile -t names < <(cut -f1 "$pool/MANIFEST.tsv")
  expect "$(tr '\t' ' ' < "$pool/MANIFEST.tsv")" pacman -Q "${names[@]}"
}

# check the exit status of arch_pool_stage
stage_case() {
  local want="$1" what="$2" name="${3:-}" out rc=0
  out=$(arch_pool_stage 2>&1) || rc=$?
  (( rc == want )) || { echo "arch_pool_stage exited $rc, want $want, over $what:" >&2; echo "$out" >&2; exit 1; }
  [[ -z "$name" || "$out" == *"$name"* ]] || { echo "arch_pool_stage over $what did not name $name:" >&2; echo "$out" >&2; exit 1; }
  echo "arch_pool_stage exited $rc over $what"
  echo "$out"
}

# run arch_pool_stage over altered pool copies
stage_leg() {
  local dir="$scratch/stage/share/arch-pool" victim name files
  mkdir -p "$scratch/stage/share"
  cp -al -- "$pool" "$dir"
  boot_stock stage
  stage_case 0 "the pool as built"
  files=("$dir"/*.pkg.tar.zst)
  victim="${files[0]}"
  name="${victim##*/}"
  cp --remove-destination -- "$pool/$name" "$victim"
  printf x >> "$victim"
  stage_case 1 "the pool with one package file altered" "$name"
  ln -f -- "$pool/$name" "$victim"
  stage_case 0 "the pool with the altered file restored"
  : > "$dir/stray-1-1-any.pkg.tar.zst"
  stage_case 1 "the pool with a package file the record does not list" stray-1-1-any.pkg.tar.zst
  rm -- "$dir/stray-1-1-any.pkg.tar.zst"
  rm -- "$victim"
  stage_case 1 "the pool with one package file removed" "$name"
  guest_poweroff
}

(cd "$dl" && sha256sum -c cachyos-stock.sha256)
stock_sha=$(sed -n 's/  cachyos-stock\.qcow2$//p' "$stock.sha256")
[[ "$stock_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "$stock.sha256 has no cachyos-stock.qcow2 line" >&2; exit 1; }

if [[ "$mode" == build ]]; then
  build_pool
  exit 0
fi

[[ -f "$pool/POOL.sha256" ]] || { echo "no $pool/POOL.sha256 -- run arch-pool.sh first" >&2; exit 1; }
[[ "$(cat "$pool/POOL.base")" == "$stock_sha  cachyos-stock.qcow2" ]] \
  || { echo "$pool was derived against $(cut -d' ' -f1 "$pool/POOL.base"), not the stock base $stock_sha; run arch-pool.sh" >&2; exit 1; }
(cd "$pool" && sha256sum --check --quiet POOL.sha256)
arch_pool_conf "$scratch/pacman.conf"
[[ -f "$pool/$ARCH_POOL_KERNEL_RECORD" ]] \
  || { echo "$pool has no $ARCH_POOL_KERNEL_RECORD, so it was not built for the Rhizo kernel's depends; run arch-pool.sh" >&2; exit 1; }
[[ "$(<"$pool/$ARCH_POOL_KERNEL_RECORD")" == "$kernel_depends" ]] \
  || { echo "$pool carries the Rhizo kernel depends '$(tr '\n' ' ' < "$pool/$ARCH_POOL_KERNEL_RECORD")', and ${kernel_file_list[*]} depend on '$(tr '\n' ' ' <<<"$kernel_depends")'; run arch-pool.sh" >&2; exit 1; }
cmp -s "$scratch/pacman.conf" "$pool/pacman.conf" || {
  echo "arch_pool_conf now writes something other than $pool/pacman.conf; run arch-pool.sh (< is what it writes now):" >&2
  diff "$scratch/pacman.conf" "$pool/pacman.conf" >&2
  exit 1
}

install_leg normal /etc/pacman.conf
(( proof_rc != 0 )) || { echo "the guest's own pacman.conf installed with the network down: the proof cannot fail" >&2; exit 1; }
[[ "$proof_out" == *"failed to synchronize all databases"* ]] \
  || { echo "the guest's own pacman.conf failed for a reason other than the network, rc $proof_rc" >&2; exit 1; }
(( urls_other > 0 )) || { echo "pacman's debug output named no download url outside file://" >&2; exit 1; }
guest_poweroff

install_leg pool "$ARCH_POOL_GUEST_DIR/pacman.conf"
(( proof_rc == 0 )) || { echo "the pool's pacman.conf failed with the network down, rc $proof_rc" >&2; exit 1; }
(( urls_file > 0 && urls_other == 0 )) || { echo "the pool install named $urls_file file:// and $urls_other other download urls" >&2; exit 1; }
expect_pool_installed
guest_poweroff

stage_leg
echo "pool proof passed: the install fails offline on the guest's own conf, succeeds on the pool's, and arch_pool_stage names an altered, an extra and a missing file"
