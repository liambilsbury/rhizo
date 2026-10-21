#!/bin/bash
# fetch the .debs for guest Ubuntu updates
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit
POOL="$(pwd)/var/share/ubuntu-update-debs"
mkdir -p "$POOL"

# print a prefixed progress line
log() { echo "[fetch-ubuntu-update-debs] $*"; }

SYSTEMD_STACK=(
  udev systemd systemd-timesyncd libpam-systemd libsystemd0 libudev1
  systemd-resolved systemd-sysv libnss-systemd
)

STATUS_ARG=""
CHECK_MODE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS_ARG="$2"; shift 2 ;;
    --check) CHECK_MODE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

MANIFEST="$POOL/MANIFEST.tsv"

if (( CHECK_MODE )); then
  [[ -f "$MANIFEST" ]] || { log "FAIL: no $MANIFEST -- nothing has been fetched yet"; exit 1; }
  bad=0
  n=0
  while IFS=$'\t' read -r pkg ver sha cat src; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    n=$((n + 1))
    f="$POOL/$src"
    if [[ ! -f "$f" ]]; then
      log "FAIL: $pkg $ver: $src is in the manifest but missing from $POOL"
      bad=1
      continue
    fi
    have=$(sha256sum "$f" | cut -d' ' -f1)
    if [[ "$have" != "$sha" ]]; then
      log "FAIL: $pkg $ver: $src sha256 is $have, manifest says $sha"
      bad=1
    fi
  done < "$MANIFEST"
  [[ -f "$POOL/Packages" ]] || { log "FAIL: no $POOL/Packages"; bad=1; }
  [[ -f "$POOL/Release" ]] || { log "FAIL: no $POOL/Release"; bad=1; }
  if (( bad )); then
    log "--check FAILED"
    exit 1
  fi
  log "--check OK: $n package(s) match the manifest, Packages/Release present"
  exit 0
fi

# require a command on the PATH
require_tool() { command -v "$1" >/dev/null || { log "FAIL: $1 not found -- apt install $2"; exit 2; }; }
require_tool apt-get apt
require_tool dpkg-scanpackages dpkg-dev
require_tool apt-cache apt

real_image=$(apt-cache depends linux-image-generic 2>/dev/null \
  | awk '/^  Depends: linux-image-[0-9]/{print $2; exit}')
[[ -n "$real_image" ]] || { log "FAIL: linux-image-generic names no linux-image-<ver>-generic dependency -- run apt-get update"; exit 1; }
KVER="${real_image#linux-image-}"
KBASE="${KVER%-generic}"
log "newest available kernel: $KVER"

NAMED_KERNEL=(
  "linux-image-$KVER" "linux-modules-$KVER" "linux-modules-extra-$KVER"
  "linux-headers-$KVER" "linux-headers-$KBASE"
  linux-generic linux-image-generic linux-headers-generic
)

STATUS_FILE="$STATUS_ARG"
EXTRACT_WORK=""
if [[ -z "$STATUS_FILE" ]]; then
  PRISTINE_IMG="$(pwd)/var/pristine-dl/noble-server-cloudimg-amd64.img"
  [[ -f "$PRISTINE_IMG" ]] || { log "FAIL: no $PRISTINE_IMG (tools/fetch/images/ubuntu-base.sh) and no --status FILE given"; exit 2; }
  require_tool qemu-img qemu-utils
  command -v sfdisk >/dev/null || command -v /sbin/sfdisk >/dev/null \
    || { log "FAIL: sfdisk not found -- apt install fdisk, or pass --status FILE"; exit 2; }
  command -v debugfs >/dev/null || { log "FAIL: debugfs not found -- apt install e2fsprogs, or pass --status FILE"; exit 2; }
  EXTRACT_WORK=$(mktemp -d)
  trap 'rm -rf "$EXTRACT_WORK"' EXIT
  qemu-img convert -O raw "$PRISTINE_IMG" "$EXTRACT_WORK/raw" \
    || { log "FAIL: qemu-img convert failed"; exit 1; }
  part_json=$("$(command -v sfdisk || echo /sbin/sfdisk)" -J "$EXTRACT_WORK/raw") \
    || { log "FAIL: sfdisk -J could not read a partition table from the pristine image"; exit 1; }
  read -r p_start p_size p_ssize <<<"$(python3 -c '
import json, sys
d = json.loads(sys.argv[1])["partitiontable"]
p = max(d["partitions"], key=lambda x: x["size"])
print(p["start"], p["size"], d.get("sectorsize", 512))
' "$part_json")"
  [[ -n "$p_start" && -n "$p_size" ]] || { log "FAIL: could not read a partition start/size from the pristine image"; exit 1; }
  dd if="$EXTRACT_WORK/raw" of="$EXTRACT_WORK/part.img" bs="$p_ssize" skip="$p_start" count="$p_size" status=none \
    || { log "FAIL: dd of the root partition failed"; exit 1; }
  debugfs -R 'cat /var/lib/dpkg/status' "$EXTRACT_WORK/part.img" \
    > "$EXTRACT_WORK/status" 2>"$EXTRACT_WORK/debugfs.err"
  if [[ ! -s "$EXTRACT_WORK/status" ]]; then
    log "FAIL: debugfs read an empty /var/lib/dpkg/status from the extracted partition:"
    cat "$EXTRACT_WORK/debugfs.err" >&2
    exit 1
  fi
  STATUS_FILE="$EXTRACT_WORK/status"
fi
[[ -r "$STATUS_FILE" ]] || { log "FAIL: cannot read $STATUS_FILE"; exit 2; }

pristine_kver=$(python3 -c '
import re, sys
status, want_prefix = sys.argv[1], "linux-image-"
pkg = ver = ""
for stanza in open(status, errors="replace").read().split("\n\n"):
    m = re.search(r"^Package: (\S+)", stanza, re.M)
    if not m or not m.group(1).startswith(want_prefix) or not m.group(1).endswith("-generic"):
        continue
    if not re.search(r"^Status: install ok installed", stanza, re.M):
        continue
    vm = re.search(r"^Version: (\S+)", stanza, re.M)
    if vm:
        pkg, ver = m.group(1), vm.group(1)
        break
print(f"{pkg}\t{ver}")
' "$STATUS_FILE")
pristine_pkg="${pristine_kver%%$'\t'*}"
pristine_ver="${pristine_kver#*$'\t'}"
if [[ -z "$pristine_pkg" ]]; then
  log "FAIL: no installed linux-image-*-generic stanza found in $STATUS_FILE"
  exit 1
fi
log "pristine image carries $pristine_pkg $pristine_ver"

candidate_ver=$(apt-cache policy "linux-image-$KVER" 2>/dev/null | awk '/Candidate:/{print $2; exit}')
[[ -n "$candidate_ver" ]] || { log "FAIL: apt-cache policy linux-image-$KVER reported no candidate version"; exit 1; }
if dpkg --compare-versions "$candidate_ver" le "$pristine_ver"; then
  log "REFUSING: the newest available kernel is linux-image-$KVER $candidate_ver, and the pristine image already carries $pristine_pkg $pristine_ver -- nothing newer exists to fetch"
  exit 1
fi
log "pristine $pristine_ver -> newest $candidate_ver: fetching"

derived=$(apt-get -o Dir::State::status="$STATUS_FILE" -o APT::Get::Show-Versions=false \
    install --dry-run --no-install-recommends \
    "${NAMED_KERNEL[@]}" "${SYSTEMD_STACK[@]}" 2>"$POOL/.derive.stderr" \
  | awk '/^Inst /{print $2}' | sort -u)
if [[ -z "$derived" ]]; then
  log "FAIL: apt-get install --dry-run against the pristine status named nothing to install -- see $POOL/.derive.stderr:"
  cat "$POOL/.derive.stderr" >&2
  exit 1
fi
rm -f "$POOL/.derive.stderr"
n_derived=$(grep -c . <<<"$derived")
log "derived $n_derived package(s) against the pristine status"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; [[ -n "$EXTRACT_WORK" ]] && rm -rf "$EXTRACT_WORK"' EXIT
mapfile -t WANT <<<"$derived"
if ! ( cd "$WORK" && apt-get download "${WANT[@]}" >"$WORK/.download.log" 2>&1 ); then
  log "FAIL: apt-get download failed -- $WORK/.download.log:"
  tail -30 "$WORK/.download.log" >&2
  exit 1
fi

# print the category of a package
category_of() {
  local p="$1" x
  for x in "${NAMED_KERNEL[@]}"; do [[ "$x" == "$p" ]] && { echo kernel; return; }; done
  for x in "${SYSTEMD_STACK[@]}"; do [[ "$x" == "$p" ]] && { echo systemd-stack; return; }; done
  echo dependency
}

: > "$MANIFEST.new"
echo "# package	version	sha256	category	source_pool" >> "$MANIFEST.new"
missing=()
for p in "${WANT[@]}"; do
  f=$(compgen -G "$WORK/${p}_*.deb" | head -1) || true
  if [[ -z "${f:-}" ]]; then
    missing+=("$p")
    continue
  fi
  base=$(basename "$f")
  cp --remove-destination "$f" "$POOL/$base"
  sha=$(sha256sum "$POOL/$base" | cut -d' ' -f1)
  ver=$(dpkg-deb -f "$POOL/$base" Version)
  cat=$(category_of "$p")
  printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$ver" "$sha" "$cat" "$base" >> "$MANIFEST.new"
  log "$base $sha ($cat)"
done
if (( ${#missing[@]} > 0 )); then
  log "FAIL: apt-get download produced no .deb for: ${missing[*]}"
  rm -f "$MANIFEST.new"
  exit 1
fi
mv -f "$MANIFEST.new" "$MANIFEST"

( cd "$POOL" && dpkg-scanpackages -m . /dev/null 2>"$POOL/.scan.stderr" > Packages.new ) \
  || { log "FAIL: dpkg-scanpackages failed -- $POOL/.scan.stderr:"; cat "$POOL/.scan.stderr" >&2; exit 1; }
rm -f "$POOL/.scan.stderr"
mv -f "$POOL/Packages.new" "$POOL/Packages"
gzip -9c "$POOL/Packages" > "$POOL/Packages.gz"

cat > "$POOL/Release" <<EOF
Origin: Ubuntu
Label: Ubuntu
Suite: noble-security
Codename: noble
Version: 24.04
Architectures: amd64
Components: main
Description: Rhizo lifecycle-test local mirror of the packages named in MANIFEST.tsv, served by test/vm/guest-os/serve-update-repo.sh -- never the real Ubuntu archive
Date: $(date -Ru)
EOF

log "pool complete: $n_derived package(s) in $POOL, Packages/Packages.gz/Release written"
