#!/bin/bash
# build and run the host-delay core selftest
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
SRC=src/android/native/host-delay
TP="${PERFETTO_TRACE_PROCESSOR:-$PWD/toolchain/perfetto/trace_processor_shell}"
[[ -x "$TP" ]] || { echo "check-host-delay: no trace_processor at $TP (set PERFETTO_TRACE_PROCESSOR)" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
SAN=("-fsanitize=address,undefined" -fno-sanitize-recover=all)
echo 'int main(void){return 0;}' > "$tmp/probe.c"
gcc "${SAN[@]}" "$tmp/probe.c" -o "$tmp/probe" 2>/dev/null && "$tmp/probe" 2>/dev/null || SAN=()
gcc -std=c11 -Wall -Wextra -Werror -O1 -g "${SAN[@]}" \
  "$SRC/hd_selftest.c" "$SRC/hd_core.c" "$SRC/hd_pb.c" -o "$tmp/hd_selftest"
PERFETTO_TRACE_PROCESSOR="$TP" "$tmp/hd_selftest" --selftest
