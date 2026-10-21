#!/bin/bash
# test the preinst release mismatch refusal
# shellcheck disable=SC2034
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
PREINST_DEFAULT="$ROOT/debian/rhizo.preinst"

# extract the release mismatch lines from the preinst
extract_block() {
  sed -n '/^    META=\/var\/lib\/rhizo\/data\.img\.meta$/,/^    fi$/p' "$1"
}

# run the release mismatch block on a fixture
run_block() {
  local preinst="$1" meta_content="$2" wipe="$3" tmp block rc
  tmp=$(mktemp -d)
  if [[ "$meta_content" != --absent ]]; then
    printf '%s\n' "$meta_content" > "$tmp/data.img.meta"
  fi
  block=$(extract_block "$preinst")
  if [[ -z "$block" ]]; then
    echo "FAIL: could not extract the release-mismatch block from $(basename "$preinst")" >&2
    rm -rf "$tmp"
    return 2
  fi
  block=${block//\/var\/lib\/rhizo\/data.img.meta/$tmp/data.img.meta}
  ( set -e
    PROG=rhizo
    SHIPPED_RELEASE=a16
    RHIZO_WIPE_DATA="$wipe"
    eval "$block"
  ) 2>&1
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# check the preinst release refusal cases
check() {
  local preinst="$1" out rc bad=0

  out=$(run_block "$preinst" 'release=a16' 0); rc=$?
  if (( rc != 0 )); then
    echo "FAIL: a data.img.meta matching this build's own SHIPPED_RELEASE (a16) was refused (rc=$rc): $out" >&2
    bad=1
  fi

  out=$(run_block "$preinst" 'release=a15' 0); rc=$?
  if (( rc != 1 )) || [[ "$out" != *REFUSED* ]]; then
    echo "FAIL: a data.img.meta for a different release (a15) was NOT refused (rc=$rc): $out" >&2
    bad=1
  fi

  out=$(run_block "$preinst" 'release=a15' 1); rc=$?
  if (( rc != 0 )); then
    echo "FAIL: RHIZO_WIPE_DATA=1 did not override the release-mismatch refusal (rc=$rc): $out" >&2
    bad=1
  fi

  out=$(run_block "$preinst" --absent 0); rc=$?
  if (( rc != 0 )); then
    echo "FAIL: a first install with no data.img.meta at all was refused (rc=$rc): $out" >&2
    bad=1
  fi

  (( bad )) && return 1
  echo "preinst release-refusal check: a matching release, a mismatched release, RHIZO_WIPE_DATA=1 and a first install all behave as designed"
  return 0
}

if [[ "${1:-}" == --selftest ]]; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  cp "$PREINST_DEFAULT" "$TMP/preinst"
  if ! check "$TMP/preinst" >/dev/null 2>&1; then
    echo "check-preinst-release-refusal --selftest: FAIL -- the real preinst does not pass" >&2
    exit 1
  fi
  sed 's/^        exit 1$/        true/' "$TMP/preinst" > "$TMP/preinst-no-exit"
  if check "$TMP/preinst-no-exit" >/dev/null 2>&1; then
    echo "check-preinst-release-refusal --selftest: FAIL -- a preinst whose refusal dropped its exit 1 was reported clean" >&2
    exit 1
  fi
  sed 's/\[ "\$meta_release" != "\$SHIPPED_RELEASE" \]/[ "\$meta_release" != "\$meta_release" ]/' "$TMP/preinst" > "$TMP/preinst-weak-cmp"
  if check "$TMP/preinst-weak-cmp" >/dev/null 2>&1; then
    echo "check-preinst-release-refusal --selftest: FAIL -- a comparison weakened to never match was reported clean" >&2
    exit 1
  fi
  echo "check-preinst-release-refusal --selftest: ok (3 cases)"
  exit 0
fi

check "$PREINST_DEFAULT"
