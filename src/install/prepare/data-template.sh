#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MATERIALIZE="${CHECK_TEMPLATE_MATERIALIZE:-$HERE/materialize-data-template.py}"
LAUNCHER="${RHIZO_LAUNCHER:-$HERE/launcher3.py}"
# run a hostops.py operation in this script's domain
hostops() { python3 "${RHIZO_HOSTOPS:-$HERE/hostops.py}" "$@"; }

# print prepare's SELinux mode, or the configured one
selinux_mode() {
  if [[ -n "${RHIZO_SELINUX_MODE:-}" ]]; then
    echo "$RHIZO_SELINUX_MODE"
  else
    "${RHIZO_SELINUX_MODE_HELPER:-$HERE/rhizo-selinux-mode}" \
      --env-file "${RHIZO_ANDROIDD_ENV:-/etc/rhizo/androidd.env}" --configured
  fi
}

# check for a host policy in namespace mode
host_policy() {
  local ctx mode
  ctx=$(tr -d '\0' < "${RHIZO_ATTR_CURRENT:-/proc/self/attr/current}" 2>/dev/null) || return 1
  [[ "$ctx" == *:* ]] || return 1
  if ! mode=$(selinux_mode); then
    log "the configured SELinux mode in ${RHIZO_ANDROIDD_ENV:-/etc/rhizo/androidd.env} could not be read"
    echo "TEMPLATE_FAILED reason=selinux-mode-unreadable"
    exit 1
  fi
  [[ "$mode" == namespace ]]
}

# print a hash of the template builder files
builder_sha_of() {
  { sha256sum < "$MATERIALIZE"; sha256sum < "$HERE/data-template.sh"; } | sha256sum | cut -c1-16
}
# print a manifest's module lines as name and digest
module_lines_of() {
  grep '^MODULE' | awk '{print $2"\t"$3}' | LC_ALL=C sort
}
# hash the template inputs into the template key
compute_template_key() {
  builder_sha=$(builder_sha_of)
  key_input="gsi_fingerprint=$fp
variant=$VARIANT
format=$FORMAT
size=$SIZE
builder_version=$BUILDER_VERSION
builder_sha=$builder_sha
seed=$SEED
$module_lines"
  KEY=$(sha256sum <<<"$key_input" | cut -d' ' -f1)
}
# print the superseded data template files
superseded_templates() {
  local m b cur="${6:-}"
  [[ "$cur" =~ ^[0-9a-f]{16}$ ]] || cur=""
  for m in "$1"/data-template.*.img.meta; do
    [[ -f "$m" ]] || continue
    grep -qF "\"key\": \"$2\"" "$m" && continue
    b=$(sed -n 's/.*"builder_sha": "\([0-9a-f]*\)".*/\1/p' "$m")
    if [[ -n "$cur" && -n "$b" && "$b" != "$cur" ]]; then
      printf '%s\n' "${m%.meta}"
    elif grep -qF "\"gsi_fingerprint\": \"$3\"" "$m" && grep -qF "\"variant\": \"$4\"" "$m" \
      && grep -qF "\"format\": \"$5\"" "$m"; then
      printf '%s\n' "${m%.meta}"
    fi
  done
  return 0
}
if [[ "${1:-}" == "--print-key" ]]; then
  fp=fixture; VARIANT=user; FORMAT=fixture; SIZE=0; SEED=none; module_lines="fixture"
  BUILDER_VERSION=$(sed -n 's/^BUILDER_VERSION = "\(.*\)"/\1/p' "$MATERIALIZE")
  compute_template_key; echo "${KEY:0:12}"; exit 0
fi
if [[ "${1:-}" == "--print-superseded" ]]; then
  superseded_templates "$2" "$3" "$4" "$5" "$6" "${7:-}"; exit 0
fi
if [[ "${1:-}" == "--print-module-lines" ]]; then
  module_lines_of; exit 0
fi
if [[ "${1:-}" == "--print-builder-sha" ]]; then
  [[ -r "$MATERIALIZE" ]] || { echo "rhizo-data-template: cannot read $MATERIALIZE" >&2; exit 1; }
  builder_sha_of; exit 0
fi
PROG=rhizo-data-template
log() { echo "[$PROG] $*" >&2; }

TEMPLATES_DIR="/var/lib/rhizo/templates"
MOUNTPOINT="/mnt/rhizo-template-build"
APEX_DIR=""
FORMAT=""
EXCLUDE_NAME=""
VARIANT="user"
SIZE="4G"
SEED="none"

# remove all of the superseded templates
prune_superseded() {
  local img
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    log "removing superseded template $img"
    rm -f "$img" "$img.meta"
  done < <(superseded_templates "$TEMPLATES_DIR" "$KEY12" "$fp" "$VARIANT" "$FORMAT" "$(builder_sha_of)")
}

usage() {
  echo "usage: data-template.sh --apex-dir DIR --format quota|plain [--seed none|decompressed]" \
       "[--exclude NAME] [--variant user|userdebug] [--size 4G] [--templates-dir DIR]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apex-dir) APEX_DIR="${2:-}"; shift 2 ;;
    --format) FORMAT="${2:-}"; shift 2 ;;
    --exclude) EXCLUDE_NAME="${2:-}"; shift 2 ;;
    --seed) SEED="${2:-}"; shift 2 ;;
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --size) SIZE="${2:-}"; shift 2 ;;
    --templates-dir) TEMPLATES_DIR="${2:-}"; shift 2 ;;
    *) usage; echo "TEMPLATE_FAILED reason=bad-argument"; exit 2 ;;
  esac
done
case "$FORMAT" in
  quota|plain) ;;
  *) usage; echo "TEMPLATE_FAILED reason=bad-format"; exit 2 ;;
esac
case "$SEED" in
  none|decompressed) ;;
  *) usage; echo "TEMPLATE_FAILED reason=bad-seed"; exit 2 ;;
esac
if [[ -z "$APEX_DIR" || ! -d "$APEX_DIR" ]]; then
  echo "TEMPLATE_FAILED reason=no-apex-dir"
  log "--apex-dir '$APEX_DIR' does not exist"
  exit 1
fi
GSI="$(dirname "$APEX_DIR")"
if [[ ! -f "$MATERIALIZE" ]]; then
  echo "TEMPLATE_FAILED reason=no-materializer"
  log "$MATERIALIZE not found beside this script"
  exit 1
fi

active=$(systemctl is-active androidd.service 2>/dev/null)
if [[ "$active" == active ]]; then
  echo "TEMPLATE_REFUSED reason=androidd-active"
  log "androidd.service is active -- stop it first (systemctl stop androidd.service)"
  exit 1
fi

BUILDER_VERSION=$(sed -n 's/^BUILDER_VERSION = "\(.*\)"/\1/p' "$MATERIALIZE")
if [[ -z "$BUILDER_VERSION" ]]; then
  echo "TEMPLATE_FAILED reason=no-builder-version"
  log "could not read BUILDER_VERSION out of $MATERIALIZE"
  exit 1
fi

fp=$(grep -m1 -E '^ro\.(system\.)?build\.fingerprint=' "$GSI/build.prop" 2>/dev/null | cut -d= -f2-)
if [[ -z "$fp" ]]; then
  echo "TEMPLATE_FAILED reason=no-gsi-fingerprint"
  log "no ro.build.fingerprint / ro.system.build.fingerprint in $GSI/build.prop"
  exit 1
fi

exclude_flag=()
[[ -n "$EXCLUDE_NAME" ]] && exclude_flag=(--exclude "$EXCLUDE_NAME")

log "computing the content-address key (manifest-only pass, no write)"
manifest_out=$(python3 "$MATERIALIZE" --apex-dir "$APEX_DIR" "${exclude_flag[@]}" --manifest-only 2>&1)
if ! grep -q '^MATERIALIZE_OK' <<<"$manifest_out"; then
  echo "TEMPLATE_FAILED reason=manifest-pass-failed"
  log "$manifest_out"
  exit 1
fi
module_lines=$(module_lines_of <<<"$manifest_out")
module_count=$(grep -c . <<<"$module_lines")
if [[ -z "$module_lines" || "$module_count" -lt 1 ]]; then
  echo "TEMPLATE_FAILED reason=no-modules"
  log "$manifest_out"
  exit 1
fi

compute_template_key
KEY12="${KEY:0:12}"
IMG="$TEMPLATES_DIR/data-template.$KEY12.img"
META="$IMG.meta"
payloads_sha=$(sha256sum <<<"$module_lines" | cut -d' ' -f1)

log "key=$KEY12 variant=$VARIANT format=$FORMAT seed=$SEED modules=$module_count"

force=0
[[ "${RHIZO_TEMPLATE_FORCE_REBUILD:-0}" == 1 ]] && force=1

if [[ -s "$IMG" && -f "$META" ]] && grep -q "\"key\": \"$KEY12\"" "$META" && (( ! force )); then
  log "$IMG already exists and its .meta agrees with the newly derived key -- no-op"
  prune_superseded
  echo "TEMPLATE_OK key=$KEY12 path=$IMG new=0"
  exit 0
fi
[[ -s "$IMG" ]] && (( force )) && log "RHIZO_TEMPLATE_FORCE_REBUILD=1 -- rebuilding key=$KEY12 even though it already exists"

log "building (mkfs + populate + label), format=$FORMAT size=$SIZE"
materialize=(python3 "$MATERIALIZE")
if host_policy; then
  materialize=(python3 "$LAUNCHER" in-android-policy materialize-data-template "$MATERIALIZE")
fi
mkfs_opts=()
mount_opts=()
if [[ "$FORMAT" == quota ]]; then
  mkfs_opts=(-O "quota,project")
  mount_opts=(-o prjquota)
fi
mkdir -p "$TEMPLATES_DIR"
PART="$IMG.part"
mkdir -p "$MOUNTPOINT"
if hostops is-mount "$MOUNTPOINT" && ! hostops umount "$MOUNTPOINT"; then
  echo "TEMPLATE_FAILED reason=umount-failed"
  exit 1
fi
if ! leftovers=$(hostops loop-find "$PART"); then
  echo "TEMPLATE_FAILED reason=loop-find-failed"
  exit 1
fi
for leftover in $leftovers; do
  if ! hostops loop-detach "$leftover"; then
    echo "TEMPLATE_FAILED reason=loop-detach-failed"
    exit 1
  fi
done
rm -f "$PART"
if ! truncate -s "$SIZE" "$PART"; then
  echo "TEMPLATE_FAILED reason=truncate-failed"
  exit 1
fi
if ! LOOP=$(hostops loop-attach "$PART"); then
  rm -f "$PART"
  echo "TEMPLATE_FAILED reason=losetup-failed"
  exit 1
fi
if ! systemd-run --wait --collect --quiet --unit "rhizo-template-mkfs-$$" /usr/sbin/mke2fs -t ext4 -q -F "${mkfs_opts[@]}" "$LOOP"; then
  hostops loop-detach "$LOOP"
  rm -f "$PART"
  log "mke2fs on $LOOP failed -- journalctl -u rhizo-template-mkfs-$$ holds its output"
  echo "TEMPLATE_FAILED reason=mkfs-failed"
  exit 1
fi
if ! hostops mount -t ext4 "${mount_opts[@]}" "$LOOP" "$MOUNTPOINT"; then
  hostops loop-detach "$LOOP"
  rm -f "$PART"
  echo "TEMPLATE_FAILED reason=mount-failed"
  exit 1
fi
mkdir -p "$MOUNTPOINT/apex/decompressed" "$MOUNTPOINT/apex/active"
build_out=$("${materialize[@]}" --apex-dir "$APEX_DIR" "${exclude_flag[@]}" --seed "$SEED" \
  --out-dir "$MOUNTPOINT/apex/decompressed" --active-dir "$MOUNTPOINT/apex/active" \
  --apex-root-dir "$MOUNTPOINT/apex" 2>&1)
sync
if ! hostops umount "$MOUNTPOINT"; then
  echo "TEMPLATE_FAILED reason=umount-failed"
  exit 1
fi
rmdir "$MOUNTPOINT" || log "could not remove the build mount point $MOUNTPOINT"
if ! hostops loop-detach "$LOOP"; then
  rm -f "$PART"
  echo "TEMPLATE_FAILED reason=loop-detach-failed"
  exit 1
fi
if ! grep -q '^MATERIALIZE_OK' <<<"$build_out"; then
  rm -f "$PART"
  echo "TEMPLATE_FAILED reason=materialize-did-not-confirm"
  log "$build_out"
  exit 1
fi
mv "$PART" "$IMG"
sync

module_set_json=$(awk -F'\t' '{printf "%s\"%s\"", (NR>1?",":""), $1}' <<<"$module_lines")
if [[ "$SEED" == none ]]; then
  seed_set_json=""; seed_count=0
else
  seed_set_json="$module_set_json"; seed_count=$module_count
fi
cat > "$META.tmp" <<EOF
{
 "key": "$KEY12",
 "variant": "$VARIANT",
 "gsi_fingerprint": "$fp",
 "format": "$FORMAT",
 "size": "$SIZE",
 "seed": "$SEED",
 "seed_set": [$seed_set_json],
 "seed_count": $seed_count,
 "module_set": [$module_set_json],
 "module_count": $module_count,
 "payloads_sha": "$payloads_sha",
 "builder_version": "$BUILDER_VERSION",
 "builder_sha": "$builder_sha",
 "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
mv "$META.tmp" "$META"

verify=$(stat -c %s "$IMG" 2>/dev/null)
if [[ -z "$verify" || "$verify" -eq 0 ]]; then
  echo "TEMPLATE_FAILED reason=empty-artifact"
  exit 1
fi

log "built $IMG ($verify bytes)"
prune_superseded
echo "TEMPLATE_OK key=$KEY12 path=$IMG new=1"
exit 0
