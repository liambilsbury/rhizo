#!/bin/bash
# build rhizo-audiod and run its selftest
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit

SRC=src/services/audiod/audiod.c
HAL_SRC=src/android/hal/audio-core/src/audio_core.cpp
MODE=run
[[ "${1:-}" == "--selftest" ]] && MODE=selftest

pkg-config --exists libpipewire-0.3 || {
  echo "FAIL: libpipewire-0.3 dev files missing (apt-get install libpipewire-0.3-dev)" >&2
  exit 1
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/check-audiod-selftest-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

if [[ "$MODE" == run ]]; then
  tools/build/services/audiod.sh "$WORK" >"$WORK/build.log" 2>&1 \
    || { echo "FAIL: audiod.sh failed:" >&2; cat "$WORK/build.log" >&2; exit 1; }
  out=$("$WORK/rhizo-audiod" --selftest 2>&1); rc=$?
  cases=$(grep -c '^SELFTEST OK:\|^SELFTEST FAIL:' <<<"$out")
  if (( cases == 0 )); then
    echo "FAIL: rhizo-audiod --selftest asserted nothing" >&2
    exit 1
  fi
  if (( rc != 0 )); then
    echo "FAIL: rhizo-audiod --selftest failed ($cases case(s)):" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "check-audiod-selftest: rhizo-audiod --selftest passed ($cases header case(s))"
else
  cp "$SRC" "$WORK/corrupted.c"
  sed -i 's/if (enforce_label && !label_is_valid(label)) {/if (0 \&\& enforce_label \&\& !label_is_valid(label)) {/' \
    "$WORK/corrupted.c"
  grep -q 'if (0 && enforce_label' "$WORK/corrupted.c" \
    || { echo "FAIL: --selftest could not corrupt the label check" >&2; exit 1; }
  # shellcheck disable=SC2046
  gcc -O2 -Wall -Wextra -o "$WORK/rhizo-audiod-corrupted" "$WORK/corrupted.c" \
    $(pkg-config --cflags --libs libpipewire-0.3) -lpthread \
    || { echo "FAIL: --selftest could not build the corrupted binary" >&2; exit 1; }
  if "$WORK/rhizo-audiod-corrupted" --selftest >"$WORK/corrupt.log" 2>&1; then
    echo "check-audiod-selftest --selftest: with the label check removed, nothing noticed" >&2
    cat "$WORK/corrupt.log" >&2
    exit 1
  fi
  grep -q "SELFTEST FAIL" "$WORK/corrupt.log" \
    || { echo "FAIL: --selftest binary failed for an unrelated reason:" >&2; cat "$WORK/corrupt.log" >&2; exit 1; }
  echo "check-audiod-selftest --selftest: removing the label check makes --selftest fail, as required"
fi

audiod_max=$(grep -oE '#define AUDIOD_MAX_BUS [0-9]+' "$SRC" | grep -oE '[0-9]+$')
hal_max=$(grep -oE 'kMaxBusCount = [0-9]+' "$HAL_SRC" | grep -oE '[0-9]+$')
if [[ -z "$audiod_max" || -z "$hal_max" ]]; then
  echo "FAIL: could not read AUDIOD_MAX_BUS or kMaxBusCount" >&2
  exit 1
fi
if [[ "$audiod_max" != "$hal_max" ]]; then
  echo "FAIL: rhizo-audiod's AUDIOD_MAX_BUS=$audiod_max does not match the HAL's kMaxBusCount=$hal_max" >&2
  exit 1
fi
if [[ "$MODE" == run ]]; then
  echo "check-audiod-selftest: AUDIOD_MAX_BUS matches kMaxBusCount ($audiod_max)"
fi
exit 0
