#!/bin/bash
# check and build the artifacts a release needs
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../../test/vm/common.sh
source ../../test/vm/image/release-map.sh
# print the ABI unwaived marker path
abi_unwaived_marker_path() {
  echo "${RHIZO_ABI_UNWAIVED_MARKER_DIR:-$SHARE_DIR}/.abi-unwaived-$1"
}

# print the unwaived lines from the abi.sh log
abi_report_unwaived() {
  local rc="$1" log="$2"
  if grep -q '^FAIL:' "$log"; then
    grep '^FAIL:' "$log"
    return 1
  fi
  (( rc == 0 )) && return 0
  grep '\[UNWAIVED' "$log"
  return 0
}

# check the binaries load against a release
abi_check() {
  local rel="$1" stamp sum
  [[ "$rel" == a16 ]] && return 0
  sum=$(cat "$SHARE_DIR"/gfx_hal/* "$SHARE_DIR"/gfx_hal_32/* 2>/dev/null | sha256sum | cut -c1-16)
  stamp="$SHARE_DIR/.abi-ok-$rel"
  if [[ -f "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$sum" ]]; then
    log "build-release: ABI for $rel already checked against these exact binaries"
    return 0
  fi
  log "build-release: checking the vendor binaries load against $rel's GSI"
  ../../test/checks/build/abi.sh "$rel" > /tmp/rhizo-abi-$rel.log 2>&1
  local rc=$? unwaived
  if ! unwaived=$(abi_report_unwaived "$rc" /tmp/rhizo-abi-$rel.log); then
    log "build-release: abi.sh could not even run for $rel:"
    sed 's/^/    /' <<<"$unwaived"
    return 1
  fi
  abi_unwaived_test "$rel" "$unwaived" "$ALLOW_UNWAIVED" || return 1
  [[ -f "$(abi_unwaived_marker_path "$rel")" ]] && return 0
  grep -q "SYMBOLS EXPORTED BY" /tmp/rhizo-abi-$rel.log \
    && log "build-release: $rel symbol gaps are all waived in abi-waivers.tsv"
  echo "$sum" > "$stamp"
  log "build-release: ABI clean for $rel"
}

# check a release for unwaived ABI gaps
abi_unwaived_test() {
  local rel="$1" unwaived="$2" allow="$3" marker
  marker="$(abi_unwaived_marker_path "$rel")"
  rm -f "$marker"
  [[ -z "$unwaived" ]] && return 0
  if [[ "$allow" != 1 ]]; then
    log "build-release: abi.sh found symbols $rel does not export, none of them waived:"
    sed 's/^/    /' <<<"$unwaived"
    log "  full report: /tmp/rhizo-abi-$rel.log -- waive one in test/checks/data/abi-waivers.tsv only with boot evidence"
    return 1
  fi
  log "########################################################################"
  log "# UNWAIVED-ABI BOOT: $rel has ABI gap(s) with NO entry in"
  log "# abi-waivers.tsv. It is NOT a normal boot: its rows/verdicts are"
  log "# marked abi_unwaived=1. Unwaived gap(s):"
  sed 's/^/#     /' <<<"$unwaived" | while IFS= read -r line; do log "$line"; done
  log "########################################################################"
  mkdir -p "$(dirname "$marker")"
  { echo "release=$rel"; echo "at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "$unwaived"; } > "$marker"
  return 0
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0 2>/dev/null || exit 0
fi

LABEL="${1:-}"
shift || true
DO_BUILD=0 ALLOW_UNWAIVED=0
for a in "$@"; do
  case "$a" in
    --build) DO_BUILD=1 ;;
    --allow-unwaived) ALLOW_UNWAIVED=1 ;;
    *) echo "release.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done

if ! release_known "$LABEL"; then
  echo "release.sh: usage: tools/build/release.sh <a15|a16> [--build] [--allow-unwaived]" >&2
  echo "  unknown or missing release label: '${LABEL:-<none>}' -- known: ${RELEASE_LABELS[*]}" >&2
  exit 2
fi

if why=$(release_retired "$LABEL"); then
  log "build-release: $LABEL cannot boot on this rig: $why"
  exit 1
fi

if ! ../../test/checks/build/build-set.sh; then
  log "build-release: the common build set is not ready, so $LABEL cannot boot"
  exit 1
fi

abi_check "$LABEL" || exit 1

if ! release_build_needed "$LABEL"; then
  log "build-release: $LABEL needs nothing beyond the common build set"
  exit 0
fi

artifact="$VAR_DIR/${RELEASE_BUILD_ARTIFACT[$LABEL]}"
cmd="${RELEASE_BUILD_CMD[$LABEL]}"

artifact_ready=1
if [[ ! -s "$artifact" ]]; then
  artifact_ready=0
  if (( DO_BUILD )); then
    log "build-release: $LABEL needs $artifact, building it now via $cmd (this can be slow for a from-source kernel)"
    if ! "./$(basename "$cmd")"; then
      log "build-release: $cmd failed"
      exit 1
    fi
    if [[ ! -s "$artifact" ]]; then
      log "build-release: $cmd exited 0 but $artifact does not exist"
      exit 1
    fi
    log "build-release: $LABEL built -- $artifact"
    artifact_ready=1
  fi
fi

if (( artifact_ready )); then
  log "build-release: $LABEL's own build artifact is present: $artifact"
  exit 0
fi

if [[ ! -s "$artifact" ]]; then
  log "build-release: $LABEL needs $artifact and it does not exist"
  log "  build it: $cmd"
fi
log "  then re-run this, or pass --build to run it now"
exit 1
