#!/bin/bash
# print the build variant of the chosen gpu render node
set -uo pipefail
log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

SYS_CLASS_DRM="${RHIZO_SYS_CLASS_DRM:-/sys/class/drm}"
ENV_FILE=""

# print a render node's kernel driver
driver_for_node() {
  local node="$1"
  local ue="$node/device/uevent" drv=""
  [[ -r "$ue" ]] || return 1
  drv=$(sed -n 's/^DRIVER=//p' "$ue")
  if [[ "$drv" == "virtio-pci" ]]; then
    local sub
    for sub in "$node"/device/virtio*; do
      [[ -r "$sub/uevent" ]] || continue
      drv=$(sed -n 's/^DRIVER=//p' "$sub/uevent")
      break
    done
  fi
  [[ -n "$drv" ]] && echo "$drv"
}

# check whether rhizo builds a variant for this driver
supported_driver() {
  case "$1" in
    i915|amdgpu|virtio_gpu) return 0 ;;
    *) return 1 ;;
  esac
}

# map a GPU driver to a variant name
variant_for_driver() {
  case "$1" in
    i915) echo intel ;;
    amdgpu) echo amd ;;
    virtio_gpu) echo virgl ;;
    *) echo virgl ;;
  esac
}

# print a render node's video memory in bytes
vram_of() {
  local v
  v=$(cat "$1/device/mem_info_vram_total" 2>/dev/null) && [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"
}

# print the sysfs render node an override names
override_node() {
  local dir="$1" want="$2" name r
  name=${want##*/}
  [[ "$name" =~ ^(renderD|card)[0-9]+$ || ! -L "$want" ]] || name=$(readlink -- "$want")
  name=${name##*/}
  case "$name" in
    renderD[0-9]*) [[ -e "$dir/$name" ]] && { echo "$dir/$name"; return 0; } ;;
    card[0-9]*)
      for r in "$dir"/renderD[0-9]*; do
        [[ -e "$r/device/drm/$name" ]] && { echo "$r"; return 0; }
      done ;;
  esac
  return 1
}

# print an env file's last value for a key
env_file_value() {
  local v
  v=$(sed -n "s/^[[:space:]]*$2=//p" "$1" 2>/dev/null | tail -1)
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ ^\"(.*)\"$ || "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
  printf '%s' "$v"
}

# print the chosen render node
choose_node() {
  local dir="$1" want="${RHIZO_RENDER_NODE:-}" node drv vram best="" best_vram=-1 first="" supported=""
  [[ -z "$want" && -n "$ENV_FILE" ]] && want=$(env_file_value "$ENV_FILE" RHIZO_RENDER_NODE)
  if [[ -n "$want" ]]; then
    node=$(override_node "$dir" "$want") \
      || { log "detect-gpu-driver: RHIZO_RENDER_NODE=$want names no render node under $dir"; return 1; }
    log "detect-gpu-driver: chose ${node##*/}, which RHIZO_RENDER_NODE=$want names"
    echo "$node"
    return 0
  fi
  local nodes=("$dir"/renderD*)
  [[ -e "${nodes[0]:-}" ]] || { log "detect-gpu-driver: no render node under $dir"; return 1; }
  for node in "${nodes[@]}"; do
    drv=$(driver_for_node "$node") || continue
    [[ -n "$drv" ]] || continue
    vram=$(vram_of "$node")
    log "detect-gpu-driver: candidate ${node##*/} driver $drv vram ${vram:-unknown}"
    [[ -n "$first" ]] || first=$node
    supported_driver "$drv" || continue
    [[ -n "$supported" ]] || supported=$node
    if [[ -n "$vram" ]] && (( vram > best_vram )); then best=$node best_vram=$vram; fi
  done
  [[ -n "$first" ]] || { log "detect-gpu-driver: found render nodes under $dir but none had a readable driver"; return 1; }
  if [[ -n "$best" ]]; then
    log "detect-gpu-driver: chose ${best##*/}, the most video memory of the supported drivers"; echo "$best"
  elif [[ -n "$supported" ]]; then
    log "detect-gpu-driver: chose ${supported##*/}, the first on a supported driver"; echo "$supported"
  else
    log "detect-gpu-driver: chose ${first##*/}, the first, as no driver Rhizo builds for is present"; echo "$first"
  fi
}

# print the chosen node's variant
detect() {
  local dir="${1:-$SYS_CLASS_DRM}" node drv variant card="-" c dev="${RHIZO_DEV_DRI:-/dev/dri}"
  node=$(choose_node "$dir") || return 1
  drv=$(driver_for_node "$node") || { log "detect-gpu-driver: $node has no readable driver"; return 1; }
  variant=$(variant_for_driver "$drv")
  log "detect-gpu-driver: $node -> DRIVER=$drv -> $variant"
  if [[ "${2:-}" == --node ]]; then
    for c in "$node"/device/drm/card[0-9]*; do
      [[ "${c##*/}" =~ ^card[0-9]+$ ]] && { card="$dev/${c##*/}"; break; }
    done
    echo "$dev/${node##*/} $card $variant"
  else
    echo "$variant"
  fi
}

# make a fixture render node
fixture_node() {
  local root="$1" name="$2" drv="$3" vram="${4:-}" card="${5:-}"
  mkdir -p "$root/$name/device/drm"
  printf 'DRIVER=%s\n' "$drv" > "$root/$name/device/uevent"
  [[ -n "$vram" ]] && echo "$vram" > "$root/$name/device/mem_info_vram_total"
  [[ -n "$card" ]] && mkdir -p "$root/$name/device/drm/$card"
  return 0
}

# check node choice against fixture directories
selftest() {
  local fail=0 t
  t=$(mktemp -d); mkdir -p "$t/renderD128/device/virtio3"
  printf 'DRIVER=virtio-pci\n' > "$t/renderD128/device/uevent"
  printf 'DRIVER=virtio_gpu\n' > "$t/renderD128/device/virtio3/uevent"
  [[ "$(detect "$t")" == virgl ]] || { log "SELFTEST FAILED: virtio-pci+virtio_gpu unwrap did not map to virgl"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d); mkdir -p "$t/renderD128/device"
  printf 'DRIVER=i915\n' > "$t/renderD128/device/uevent"
  [[ "$(detect "$t")" == intel ]] || { log "SELFTEST FAILED: i915 did not map to intel"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d); mkdir -p "$t/renderD128/device"
  printf 'DRIVER=amdgpu\n' > "$t/renderD128/device/uevent"
  [[ "$(detect "$t")" == amd ]] || { log "SELFTEST FAILED: amdgpu did not map to amd"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d); mkdir -p "$t/renderD128/device"
  printf 'DRIVER=nouveau\n' > "$t/renderD128/device/uevent"
  [[ "$(detect "$t")" == virgl ]] || { log "SELFTEST FAILED: an unbuilt driver must fall back to virgl, not fail"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d)
  detect "$t" >/dev/null 2>&1 && { log "SELFTEST FAILED: an empty dir (no render node) must refuse, not print a guess"; fail=1; }
  rm -rf "$t"

  local d o rc
  t=$(mktemp -d); d="$t/dev"; mkdir -p "$d/by-path"
  fixture_node "$t/sys" renderD128 amdgpu 2147483648 card0
  fixture_node "$t/sys" renderD129 amdgpu 17095983104 card1
  ln -s ../renderD128 "$d/by-path/pci-0000:12:00.0-render"
  ln -s ../card0 "$d/by-path/pci-0000:12:00.0-card"
  o=$(RHIZO_DEV_DRI="$d" detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "$d/renderD129 $d/card1 amd" ]] || { log "SELFTEST FAILED: two amdgpu: want the larger VRAM on renderD129, got '$o'"; fail=1; }
  o=$(detect "$t/sys" 2>/dev/null)
  [[ "$o" == amd ]] || { log "SELFTEST FAILED: without --node the output is the variant alone, got '$o'"; fail=1; }
  o=$(RHIZO_DEV_DRI="$d" RHIZO_RENDER_NODE="$d/by-path/pci-0000:12:00.0-render" detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "$d/renderD128 $d/card0 amd" ]] || { log "SELFTEST FAILED: an override by by-path render link, got '$o'"; fail=1; }
  o=$(RHIZO_DEV_DRI="$d" RHIZO_RENDER_NODE="$d/by-path/pci-0000:12:00.0-card" detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "$d/renderD128 $d/card0 amd" ]] || { log "SELFTEST FAILED: an override by by-path card link, got '$o'"; fail=1; }
  ln -s /dev/null "$d/renderD128"
  o=$(RHIZO_DEV_DRI="$d" RHIZO_RENDER_NODE="$d/renderD128" detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "$d/renderD128 $d/card0 amd" ]] || { log "SELFTEST FAILED: an override named renderD128 is that node, wherever its file links, got '$o'"; fail=1; }
  printf 'RHIZO_RENDER_NODE=%s\n' "$d/renderD128" > "$t/androidd.env"
  o=$(RHIZO_DEV_DRI="$d" ENV_FILE="$t/androidd.env" detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "$d/renderD128 $d/card0 amd" ]] || { log "SELFTEST FAILED: the env file's override, got '$o'"; fail=1; }
  printf 'RHIZO_RENDER_NODE="%s"\n' "$d/renderD128" > "$t/androidd-double.env"
  o=$(RHIZO_DEV_DRI="$d" ENV_FILE="$t/androidd-double.env" detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "$d/renderD128 $d/card0 amd" ]] || { log "SELFTEST FAILED: a double-quoted env file value, got '$o'"; fail=1; }
  printf "RHIZO_RENDER_NODE='%s'  \n" "$d/renderD128" > "$t/androidd-single.env"
  o=$(RHIZO_DEV_DRI="$d" ENV_FILE="$t/androidd-single.env" detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "$d/renderD128 $d/card0 amd" ]] || { log "SELFTEST FAILED: a single-quoted env file value, got '$o'"; fail=1; }
  o=$(RHIZO_DEV_DRI="$d" RHIZO_RENDER_NODE="$d/renderD129" ENV_FILE="$t/androidd.env" detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "$d/renderD129 $d/card1 amd" ]] || { log "SELFTEST FAILED: the environment beats the env file, got '$o'"; fail=1; }
  o=$(RHIZO_RENDER_NODE="$d/renderD200" detect "$t/sys" --node 2>/dev/null); rc=$?
  [[ $rc != 0 && -z "$o" ]] || { log "SELFTEST FAILED: an override naming no node must fail, got rc=$rc '$o'"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d)
  fixture_node "$t/sys" renderD128 amdgpu 17095983104 card1
  fixture_node "$t/sys" renderD129 amdgpu 2147483648 card0
  o=$(RHIZO_DEV_DRI=/dev/dri detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "/dev/dri/renderD128 /dev/dri/card1 amd" ]] || { log "SELFTEST FAILED: two amdgpu swapped: want renderD128, got '$o'"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d)
  fixture_node "$t/sys" renderD128 i915 "" card0
  fixture_node "$t/sys" renderD129 amdgpu 8589934592 card1
  o=$(RHIZO_DEV_DRI=/dev/dri detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "/dev/dri/renderD129 /dev/dri/card1 amd" ]] || { log "SELFTEST FAILED: i915+amdgpu: want the amdgpu, got '$o'"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d)
  fixture_node "$t/sys" renderD128 nvidia "" card0
  fixture_node "$t/sys" renderD129 i915 "" card1
  o=$(RHIZO_DEV_DRI=/dev/dri detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "/dev/dri/renderD129 /dev/dri/card1 intel" ]] || { log "SELFTEST FAILED: nvidia+i915: want the supported i915, got '$o'"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d)
  fixture_node "$t/sys" renderD128 i915 "" card0
  fixture_node "$t/sys" renderD129 nouveau "" card1
  o=$(RHIZO_DEV_DRI=/dev/dri detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "/dev/dri/renderD128 /dev/dri/card0 intel" ]] || { log "SELFTEST FAILED: i915+nouveau: want the supported i915, got '$o'"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d)
  fixture_node "$t/sys" renderD128 nvidia "" card0
  o=$(RHIZO_DEV_DRI=/dev/dri detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "/dev/dri/renderD128 /dev/dri/card0 virgl" ]] || { log "SELFTEST FAILED: nvidia alone: want it, got '$o'"; fail=1; }
  o=$(RHIZO_DEV_DRI=/dev/dri RHIZO_RENDER_NODE=/dev/dri/renderD128 detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "/dev/dri/renderD128 /dev/dri/card0 virgl" ]] || { log "SELFTEST FAILED: an override names an unsupported node, got '$o'"; fail=1; }
  rm -rf "$t"

  t=$(mktemp -d); mkdir -p "$t/sys/renderD128/device/virtio3" "$t/sys/renderD128/device/drm/card0"
  printf 'DRIVER=virtio-pci\n' > "$t/sys/renderD128/device/uevent"
  printf 'DRIVER=virtio_gpu\n' > "$t/sys/renderD128/device/virtio3/uevent"
  o=$(RHIZO_DEV_DRI=/dev/dri detect "$t/sys" --node 2>/dev/null)
  [[ "$o" == "/dev/dri/renderD128 /dev/dri/card0 virgl" ]] || { log "SELFTEST FAILED: one virtio_gpu, got '$o'"; fail=1; }
  rm -rf "$t"

  if [[ -e /sys/class/drm/renderD128 ]]; then
    live=$(detect) || { log "SELFTEST FAILED: this host's own renderD128 did not resolve"; fail=1; }
    case "$live" in
      virgl|intel|amd) ;;
      *) log "SELFTEST FAILED: this host's renderD128 mapped to unknown variant '$live'"; fail=1 ;;
    esac
    live=$(detect /sys/class/drm --node) || { log "SELFTEST FAILED: this host's own render node did not resolve with --node"; fail=1; }
    [[ "$live" =~ ^/dev/dri/renderD[0-9]+\ (/dev/dri/card[0-9]+|-)\ (virgl|intel|amd)$ ]] \
      || { log "SELFTEST FAILED: this host's --node line is '$live'"; fail=1; }
  fi

  if (( fail )); then log "detect-gpu-driver selftest: FAILED"; return 1; fi
  log "detect-gpu-driver selftest: ok"
}

PRINT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest) unset RHIZO_RENDER_NODE RHIZO_SYS_CLASS_DRM RHIZO_DEV_DRI; selftest; exit $? ;;
    --sys-class-drm) SYS_CLASS_DRM="$2"; shift 2 ;;
    --node) PRINT=--node; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) log "detect-gpu-driver: unknown argument $1"; exit 2 ;;
  esac
done
detect "$SYS_CLASS_DRM" $PRINT
