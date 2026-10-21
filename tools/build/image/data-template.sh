#!/bin/bash
# build the /data template on the guest
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../../test/vm/common.sh
source ../../../test/vm/image/release-map.sh

TEMPLATES_DIR="/var/lib/rhizo/templates"

# print the usage line to stderr
usage() {
  echo "data-template.sh: usage: tools/build/image/data-template.sh <a15|a16>" \
       "--format quota|plain [--variant user|userdebug] [--size 4G]" >&2
}

LABEL="${1:-}"
if ! release_known "$LABEL"; then
  usage
  echo "  unknown or missing release label: '${LABEL:-<none>}' -- known: ${RELEASE_LABELS[*]}" >&2
  exit 2
fi
shift

VARIANT=user
FORMAT=""
SIZE="4G"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    *) usage; echo "  unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$FORMAT" in
  quota|plain) ;;
  *) usage; echo "  --format is required and must be 'quota' or 'plain' (got '${FORMAT:-<none>}')" >&2; exit 2 ;;
esac
case "$VARIANT" in
  user) GSI="${GSI_DIR[$LABEL]}" ;;
  userdebug)
    if ! userdebug_known "$LABEL"; then
      usage
      echo "  no userdebug GSI exists for release '$LABEL' -- only: ${!GSI_DIR_USERDEBUG[*]}" >&2
      exit 2
    fi
    GSI="${GSI_DIR_USERDEBUG[$LABEL]}"
    ;;
  *) usage; echo "  unknown --variant '$VARIANT' (expected user|userdebug)" >&2; exit 2 ;;
esac
APEX_DIR="$GSI/apex"

if ! grep -q "apex_override_targets(" ../../../src/androidd/sandbox/rootfs.py 2>/dev/null; then
  echo "BUILD_TEMPLATE_FAILED reason=override-mechanism-drift"
  echo "  src/androidd/sandbox/rootfs.py names no apex_override_targets()" >&2
  exit 1
fi
SEED=none

if ! ssh_vm -t 8 true >/dev/null 2>&1; then
  echo "BUILD_TEMPLATE_REFUSED reason=guest-unreachable"
  echo "  instance $RHIZO_VM is not reachable -- boot it first" >&2
  exit 1
fi

active=$(ssh_vm -t 15 'systemctl is-active androidd.service' 2>/dev/null | tr -d '\r\n')
if [[ "$active" == active ]]; then
  echo "BUILD_TEMPLATE_REFUSED reason=androidd-active"
  echo "  androidd.service is active on instance $RHIZO_VM -- stop it first (systemctl stop androidd.service)" >&2
  exit 1
fi

BUILDER_VERSION=$(sed -n 's/^BUILDER_VERSION = "\(.*\)"/\1/p' ../../../src/install/prepare/materialize-data-template.py)
if [[ -z "$BUILDER_VERSION" ]]; then
  echo "BUILD_TEMPLATE_FAILED reason=no-builder-version"
  echo "  could not read BUILDER_VERSION out of materialize-data-template.py" >&2
  exit 1
fi

guest_mount_share 20 || true

if [[ "${RHIZO_GUEST_OS:-ubuntu}" != cachyos ]]; then
  seeded=$(ssh_vm -t 120 "bash /root/share/seed-modules-extra.sh" 2>&1)
  seed_rc=$?
  seeded=$(tr -d '\r' <<<"$seeded")
  if (( seed_rc != 0 )); then
    echo "BUILD_TEMPLATE_FAILED reason=modules-extra-seed-failed"
    echo "  seed-modules-extra.sh exited $seed_rc on vm $RHIZO_VM: ${seeded:-no output}" >&2
    exit 1
  fi
  if grep -q 'RHIZO_MODULES_EXTRA=absent' <<<"$seeded"; then
    echo "BUILD_TEMPLATE_FAILED reason=no-modules-extra"
    echo "  $seeded -- put that kernel's linux-modules-extra package at $SHARE_DIR/modules-extra.deb" >&2
    exit 1
  fi
  [[ -n "$seeded" ]] && log "$seeded"
fi

stage_to_share ../../../src/install/prepare/materialize-data-template.py "$SHARE_DIR/materialize-data-template.py" -p \
  || { log "FAIL: could not stage materialize-data-template.py into $SHARE_DIR"; exit 1; }
stage_to_share ../../../src/install/prepare/data-template.sh "$SHARE_DIR/data-template.sh" -p \
  || { log "FAIL: could not stage data-template.sh into $SHARE_DIR"; exit 1; }

log "computing the content-address key (manifest-only pass, no write)"
gsi_fp=$(ssh_vm -t 15 "grep -m1 -E '^ro\.(system\.)?build\.fingerprint=' $GSI/build.prop 2>/dev/null | cut -d= -f2-" 2>/dev/null | tr -d '\r\n')
if [[ -z "$gsi_fp" ]]; then
  echo "BUILD_TEMPLATE_FAILED reason=no-gsi-fingerprint"
  echo "  could not read a build fingerprint from $GSI/build.prop in vm $RHIZO_VM" >&2
  exit 1
fi

manifest_out=$(ssh_vm -t 90 "python3 /root/share/materialize-data-template.py --apex-dir $APEX_DIR --manifest-only" 2>&1)
if ! grep -q '^MATERIALIZE_OK' <<<"$manifest_out"; then
  echo "BUILD_TEMPLATE_FAILED reason=manifest-pass-failed"
  echo "$manifest_out" >&2
  exit 1
fi
module_lines=$(bash ../../../src/install/prepare/data-template.sh --print-module-lines <<<"$manifest_out")
module_count=$(wc -l <<<"$module_lines")
if [[ -z "$module_lines" || "$module_count" -lt 1 ]]; then
  echo "BUILD_TEMPLATE_FAILED reason=no-modules"
  echo "$manifest_out" >&2
  exit 1
fi

if ! builder_sha=$(bash ../../../src/install/prepare/data-template.sh --print-builder-sha) || [[ ! "$builder_sha" =~ ^[0-9a-f]{16}$ ]]; then
  echo "BUILD_TEMPLATE_FAILED reason=builder-sha"
  echo "  data-template.sh --print-builder-sha printed '$builder_sha'" >&2
  exit 1
fi

key_input="gsi_fingerprint=$gsi_fp
variant=$VARIANT
format=$FORMAT
size=$SIZE
builder_version=$BUILDER_VERSION
builder_sha=$builder_sha
seed=$SEED
$module_lines"
KEY=$(sha256sum <<<"$key_input" | cut -d' ' -f1)
KEY12="${KEY:0:12}"
IMG="$TEMPLATES_DIR/data-template.$KEY12.img"
META="$IMG.meta"

log "key=$KEY12 release=$LABEL variant=$VARIANT format=$FORMAT seed=$SEED modules=$module_count"

force=0
[[ "${RHIZO_TEMPLATE_FORCE_REBUILD:-0}" == 1 ]] && force=1

existing=$(ssh_vm -t 15 "test -s $IMG && test -f $META && grep -q \"\\\"key\\\": \\\"$KEY12\\\"\" $META && echo PRESENT" 2>/dev/null | tr -d '\r\n')
if [[ "$existing" == PRESENT && $force -eq 0 ]]; then
  log "$IMG already exists and its .meta agrees with the newly derived key -- no-op"
  rig_vm_record "$RHIZO_VM" data_template="$KEY12" data_template_release="$LABEL" \
    data_template_variant="$VARIANT" data_template_format="$FORMAT"
  echo "BUILD_TEMPLATE_OK key=$KEY12 path=$IMG new=0"
  exit 0
fi
if [[ "$existing" == PRESENT ]]; then
  log "RHIZO_TEMPLATE_FORCE_REBUILD=1 -- rebuilding key=$KEY12 even though it already exists"
fi

log "building (mkfs + populate + label), format=$FORMAT size=$SIZE"
remote_flags="--apex-dir $APEX_DIR --format $FORMAT --variant $VARIANT --size $SIZE --templates-dir $TEMPLATES_DIR"
remote_flags+=" --seed $SEED"
knobs="RHIZO_TEMPLATE_FORCE_REBUILD=${RHIZO_TEMPLATE_FORCE_REBUILD:-0} RHIZO_SELINUX_MODE=${RHIZO_SELINUX_MODE:-}"
knobs+=" RHIZO_SELINUX_MODE_HELPER=${RHIZO_SELINUX_MODE_HELPER:-} RHIZO_ANDROIDD_ENV=${RHIZO_ANDROIDD_ENV:-}"
knobs+=" RHIZO_ATTR_CURRENT=${RHIZO_ATTR_CURRENT:-} RHIZO_HOSTOPS=${RHIZO_HOSTOPS:-} RHIZO_LAUNCHER=${RHIZO_LAUNCHER:-}"
build_out=$(ssh_vm -t 240 "$knobs bash /root/share/data-template.sh $remote_flags" 2>&1)
remote_key=$(sed -n 's/^TEMPLATE_OK key=\([0-9a-f]\{12\}\).*/\1/p' <<<"$build_out")
if [[ -z "$remote_key" ]]; then
  echo "BUILD_TEMPLATE_FAILED reason=guest-build-failed"
  echo "$build_out" >&2
  exit 1
fi
if [[ "$remote_key" != "$KEY12" ]]; then
  echo "BUILD_TEMPLATE_FAILED reason=key-mismatch"
  echo "  this wrapper derived key=$KEY12 but the builder itself reports key=$remote_key" >&2
  echo "$build_out" >&2
  exit 1
fi
new=$(sed -n 's/.* new=\([01]\).*/\1/p' <<<"$build_out")

verify=$(ssh_vm -t 15 "stat -c %s $IMG" 2>/dev/null | tr -d '\r\n')
if [[ -z "$verify" || "$verify" -eq 0 ]]; then
  echo "BUILD_TEMPLATE_FAILED reason=empty-artifact"
  exit 1
fi

rig_vm_record "$RHIZO_VM" data_template="$KEY12" data_template_release="$LABEL" \
  data_template_variant="$VARIANT" data_template_format="$FORMAT"

log "built $IMG ($verify bytes)"
echo "BUILD_TEMPLATE_OK key=$KEY12 path=$IMG new=${new:-1}"
exit 0
