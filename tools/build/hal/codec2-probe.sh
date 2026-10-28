#!/bin/bash
# build rhizo-codec2-probe into gfx_hal
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
C2=src/android/hal/codec2
# shellcheck source=../../../src/android/hal/codec2/tools/libva-inputs.sh
source "$C2/tools/libva-inputs.sh"
libva_inputs

NAME=rhizo-codec2-probe
STAGE=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --no-stage) STAGE=0; shift ;;
    *) echo "usage: $0 [--name NAME --no-stage]" >&2; exit 2 ;;
  esac
done

SRC_ARGS=()
for f in caps device log convert vpp decode_session encode_session; do SRC_ARGS+=(--extra-src "$C2/va/$f.cpp"); done
for f in streams functional/functional functional/md5 functional/clips_data measure/measure; do
  SRC_ARGS+=(--extra-src "$C2/tools/$f.cpp")
done
INC_ARGS=(--extra-inc "$C2" --extra-inc "$C2/tools/functional")
for d in "$C2"/dec/*/; do
  d="${d%/}"
  n=0
  for f in "$d"/*.cpp; do [[ -f "$f" ]] && { SRC_ARGS+=(--extra-src "$f"); n=$((n + 1)); }; done
  (( n )) && INC_ARGS+=(--extra-inc "$d")
done
for d in "$C2"/enc/h264 "$C2"/enc/hevc "$C2"/enc/common; do
  for f in "$d"/*.cpp "$d"/*.cc; do [[ -f "$f" ]] && SRC_ARGS+=(--extra-src "$f"); done
  INC_ARGS+=(--extra-inc "$d")
done
STAGE_ARGS=(--stage gfx_hal)
(( STAGE )) || STAGE_ARGS=()

tools/build/hal/hal.sh "$NAME" "$C2/tools/probe.cpp" \
  "${SRC_ARGS[@]}" "${INC_ARGS[@]}" \
  --extra-inc "$LIBVA_INC" \
  --cxxflag -std=gnu++20 \
  --no-default-libs \
  --so va-drm \
  --so va \
  --so log \
  "${STAGE_ARGS[@]}"

if (( STAGE )); then
  mkdir -p var/share/gfx_hal/codec2-measure
  rm -f var/share/gfx_hal/codec2-measure/clips.tsv var/share/gfx_hal/codec2-measure/*.ivf
  install -m 0644 "$C2"/tools/measure/clips/*.ivf "$C2"/tools/measure/clips/clips.tsv var/share/gfx_hal/codec2-measure/
  python3 tools/build/stamps.py stamp gfx_hal/rhizo-codec2-probe || exit 1
else
  rm -f "var/bin/$NAME" "var/share/$NAME"
  echo "[codec2-probe] kept in toolchain/out/$NAME only"
fi
