#!/bin/bash
# test composer frame export through rhizo-streamd
# RHIZO_RELEASE=a15 boots that release instead of a16
# test-boot-mode: cold-required
# test-boots-unit: na
# test-nests: none
# test-records-metrics: no
# test-verdict-params: -
# test-requires: share:rhizo-streamd share:rhizo-stream-export-test share:rhizo-stream-export-verify
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit

source ../../vm/common.sh
source ../lib/lib.sh
[[ "${1:-}" == --print-contract ]] && { test_print_contract "${BASH_SOURCE[0]}"; exit $?; }

SELFTEST=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --selftest) SELFTEST=1; shift ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd ../../.. && pwd)"
STREAMD="$VAR_DIR/share/rhizo-streamd"
EXPORT_TEST="$VAR_DIR/share/rhizo-stream-export-test"
VERIFY="$VAR_DIR/share/rhizo-stream-export-verify"
STREAM_CLIENT="$REPO_DIR/test/system/tools/stream-client.py"
BROWSER_PROOF="$REPO_DIR/test/system/tools/browser-stream-proof.py"
PNGSTAT="$REPO_DIR/test/system/tools/pngstat.py"
COMPOSER_RC="$REPO_DIR/src/androidd/guest/init/composer.rc"
HALS_PY="$REPO_DIR/src/androidd/sandbox/hals.py"
MOUNTS_PY="$REPO_DIR/src/androidd/sandbox/rootfs.py"

POLICY_CONF=/etc/rhizo/policy.conf
BOOT_LOG=/root/boot.log
RENDER_NODE=""
if (( ! SELFTEST )); then
  RENDER_NODE=$(bash "$REPO_DIR/src/install/prepare/detect-gpu-driver.sh" --node | cut -d' ' -f1)
  [[ -n "$RENDER_NODE" ]] \
    || { echo "stream.sh: no host render node to encode on -- detect-gpu-driver.sh says why above" >&2; exit 1; }
fi
SANDBOX_SOCKET=$(sed -n 's|.*setenv RHIZO_STREAM_SOCKET \([^ \\]*\).*|\1|p' "$HALS_PY" | head -1)
GUEST_STREAM_SOCKET=/run/rhizo-stream/streamd
GUEST_STREAM_PORT=8555
GUEST_VERIFY_DIR=/var/tmp/rhizo-stream-verify
GUEST_VERIFY_REPORT=$GUEST_VERIFY_DIR/stream-verify.tsv
GUEST_VERIFY_DUMP=$GUEST_VERIFY_DIR/stream-verify-frame.raw
GUEST_VERIFY_LOG=$GUEST_VERIFY_DIR/stream-verify.log
CLIENT_TARGET_FOURCC=0x34324241
VERIFY_MIN_FRAMES=10
FRAME_NONBLACK_MIN_PCT=20
FRAME_DISTINCT_MIN=8
HOST_SOCKET="${TMPDIR:-/tmp}/test-stream-export${SUFFIX}.sock"
HOST_PORT="${RHIZO_STREAM_TEST_PORT:-18571}"
HOST_W=1280
HOST_H=800
FRAME_MATCH_MAX_DELTA=12

STREAM_DEFAULT=$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from sandbox import capabilities as rc
print(rc.CAPABILITIES["stream.enabled"]["default"])' "$REPO/src/androidd")

if (( SELFTEST )); then
  SELFTEST_EV="${TMPDIR:-/tmp}/test-stream-selftest${SUFFIX}"
  rm -rf "$SELFTEST_EV"
  test_init stream --no-vm --evidence-root "$SELFTEST_EV" || exit 1
else
  test_init stream --teardown || exit 1
fi

if [[ -z "$SANDBOX_SOCKET" ]]; then
  fail "could not read the RHIZO_STREAM_SOCKET path out of $HALS_PY"
  test_record_verdict FAILED
  exit 1
fi

# undo the stream setup on the vm
cleanup_vm_state() {
  (( TEST_NO_VM )) && return 0
  local out rc
  out=$(ssh_vm -t 30 "cat $GUEST_VERIFY_LOG" 2>&1); rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/vm-consumer.log"
  out=$(ssh_vm -t 30 "cat $GUEST_VERIFY_REPORT" 2>&1); rc=$?
  printf 'rc=%d\n%s\n' "$rc" "${out:-<none>}" >"$EV/vm-verify-report.log"
  ssh_vm -t 30 "systemctl stop rhizo-stream-verify rhizo-streamd rhizo-stream-capability.path rhizo-streamd.socket rhizo-streamd.service 2>/dev/null
systemctl disable rhizo-streamd.socket 2>/dev/null
systemctl reset-failed rhizo-stream-verify rhizo-streamd rhizo-streamd.socket rhizo-streamd.service 2>/dev/null
rm -f $GUEST_STREAM_SOCKET /etc/rhizo/policy.conf
true" >/dev/null 2>&1
}
# shellcheck disable=SC2034
(( SELFTEST )) || TEST_EXTRA_CLEANUP=cleanup_vm_state

# check stream.enabled defaults to off
assert_capability_default_off() {
  local label="$1" v="$2"
  [[ "$v" == "False" ]] || { fail "$label: stream.enabled defaults to '${v:-<none>}', wanted False"; return 1; }
  pass "$label: stream.enabled defaults off"
}

# check the socket path depends on stream.enabled
assert_socket_env_gated() {
  local label="$1" rc="$2" hals="$3" sub body gate socket
  grep -q '@RHIZO_SUBST stream_socket' <<<"$rc" \
    || { fail "$label: $COMPOSER_RC carries no '@RHIZO_SUBST stream_socket' line"; return 1; }
  if grep -qE '^[[:space:]]*setenv RHIZO_STREAM_SOCKET' <<<"$rc"; then
    fail "$label: $COMPOSER_RC sets RHIZO_STREAM_SOCKET literally"
    return 1
  fi
  sub=$(sed -n '/"stream_socket"/,/},$/p' <<<"$hals")
  [[ -n "$sub" ]] || { fail "$label: sandbox/hals.py has no stream_socket substitution at all"; return 1; }
  if grep -q '"stream_socket": stream_socket_line(' <<<"$sub"; then
    body=$(sed -n '/^def stream_socket_line(/,/^def /p' <<<"$hals" | sed '1!{/^def /d}')
    [[ -n "$body" ]] || { fail "$label: sandbox/hals.py's stream_socket substitution calls stream_socket_line, which it does not define"; return 1; }
    gate=$(grep -n -E '^[[:space:]]+if not [A-Za-z_]+\.allows\("stream\.enabled"\):$' <<<"$body" | head -1 | cut -d: -f1)
    socket=$(grep -n 'setenv RHIZO_STREAM_SOCKET' <<<"$body" | head -1 | cut -d: -f1)
    [[ -n "$gate" && "$(sed -n "$((gate + 1))p" <<<"$body" | tr -d '[:space:]')" == 'return""' ]] \
      || { fail "$label: sandbox/hals.py's stream_socket_line does not return nothing when allows(\"stream.enabled\") is false: $(tr -s '[:space:]' ' ' <<<"$body")"; return 1; }
    [[ -n "$socket" ]] && (( gate < socket )) \
      || { fail "$label: sandbox/hals.py's stream_socket_line returns the socket line before it asks allows(\"stream.enabled\"): $(tr -s '[:space:]' ' ' <<<"$body")"; return 1; }
  else
    grep -q 'allows("stream.enabled")' <<<"$sub" \
      || { fail "$label: sandbox/hals.py's stream_socket substitution does not ask allows(\"stream.enabled\"): $(tr -s '[:space:]' ' ' <<<"$sub")"; return 1; }
  fi
  pass "$label: the socket path reaches the composer only when stream.enabled allows it"
}

# check the sandbox binds the socket directory
assert_socket_dir_bound() {
  local label="$1" src="$2" body
  body=$(grep -n 'rhizo_stream' <<<"$src")
  [[ -n "$body" ]] || { fail "$label: sandbox/rootfs.py binds nothing at /dev/socket/rhizo_stream"; return 1; }
  grep -q 'host_stream_dir' <<<"$src" \
    || { fail "$label: sandbox/rootfs.py binds the socket FILE rather than its directory"; return 1; }
  pass "$label: the stream socket's directory is what reaches the sandbox"
}

# check the boot log for the socket bind
assert_launcher_bind_marker() {
  local label="$1" out="$2"
  if grep -q 'stream socket dir bind mount FAILED' <<<"$out"; then
    fail "$label: the launcher reported the bind failed: $(grep -m1 'bind mount FAILED' <<<"$out")"
    return 1
  fi
  grep -q 'stream socket dir bind-mounted' <<<"$out" \
    || { fail "$label: the launcher never reported binding the stream socket directory: $(tail -2 <<<"$out")"; return 1; }
  pass "$label: $(grep -m1 -o 'stream socket dir bind-mounted.*' <<<"$out")"
}

# check the composer's RHIZO_STREAM_SOCKET path
assert_composer_env() {
  local label="$1" env="$2" want="$3" got via
  got=$(tr '\0' '\n' <<<"$env" | sed -n 's/^RHIZO_STREAM_SOCKET=//p' | head -1); via=environment
  if [[ -z "$got" ]]; then
    got=$(sed -n 's/.*EnsureConnected: connected to \([^ ,]*\).*/\1/p; s/.*EnsureConnected: connect(\([^)]*\)) failed.*/\1/p' <<<"$env" | head -1)
    via="export log"
  fi
  [[ "$got" == "$want" ]] \
    || { fail "$label: the composer's RHIZO_STREAM_SOCKET is '${got:-<unset>}', wanted '$want'"; return 1; }
  pass "$label: the composer holds RHIZO_STREAM_SOCKET=$got (from its $via)"
}

# fail on any text in the listing
assert_nothing_bound() {
  local label="$1" out="$2"
  [[ -z "${out//[[:space:]]/}" ]] \
    || { fail "$label: stream.enabled is off and something is bound anyway: $out"; return 1; }
  pass "$label: nothing bound and no daemon while stream.enabled is off"
}

# print the encoder state of a vainfo listing
streamd_encoder_state() {
  local out="$1" eps
  if ! grep -qE '^[[:space:]]*VAProfile[A-Za-z0-9]+[[:space:]]*:[[:space:]]*VAEntrypoint' <<<"$out"; then
    eps=$(grep -m1 -i 'error' <<<"$out")
    [[ -n "$eps" ]] || eps=$(grep -m1 '[^[:space:]]' <<<"$out")
    printf 'broken %s\n' "${eps:-<no output>}"
    return 0
  fi
  if grep -qE 'VAProfileVP9Profile0[[:space:]]*:[[:space:]]*VAEntrypointEncSliceLP' <<<"$out"; then
    printf 'usable VP9Profile0/EncSliceLP\n'
    return 0
  fi
  eps=$(sed -nE 's/^[[:space:]]*VAProfile([A-Za-z0-9]+)[[:space:]]*:[[:space:]]*VAEntrypoint(EncSlice(LP)?)[[:space:]]*$/\1\/\2/p' <<<"$out" | paste -sd' ' -)
  printf 'none %s\n' "${eps:--}"
}

# print why rhizo-streamd cannot encode
no_encoder_reason() {
  local eps="${1:--}"
  [[ "$eps" == - ]] && eps="no encode entrypoint at all"
  printf 'the GPU offers no encoder rhizo-streamd can use: it encodes VP9 through VAEntrypointEncSliceLP only and has no AV1 encode path, and vainfo lists %s' "$eps"
}

# check vainfo lists the VP9 EncSliceLP encoder
assert_encoder_present() {
  local label="$1" out="$2" state
  state=$(streamd_encoder_state "$out")
  case "$state" in
    usable\ *) pass "$label: ${state#usable }" ;;
    none\ *) skip "$label: $(no_encoder_reason "${state#none }")" ;;
    *) fail "$label: vainfo listed no profile: ${state#broken }"; return 1 ;;
  esac
}

# check rhizo-streamd refuses a host with no usable encoder
assert_daemon_refuses() {
  local label="$1" out="$2"
  if grep -q 'RHIZO_STREAMD_SELFTEST_OK' <<<"$out"; then
    fail "$label: the daemon encoded where vainfo listed no encoder it can use: $(grep -m1 RHIZO_STREAMD_SELFTEST_OK <<<"$out")"
    return 1
  fi
  grep -q 'no usable EncSliceLP profile found' <<<"$out" \
    || { fail "$label: the daemon stopped without naming a refusal: $(tail -2 <<<"$out")"; return 1; }
  pass "$label: $(grep -m1 -o 'no usable EncSliceLP profile found.*' <<<"$out")"
}

# check rhizo-streamd chose the vp9 codec
assert_codec_royalty_free() {
  local label="$1" out="$2" codec
  codec=$(sed -n 's/.*codec=\([a-z0-9]*\).*/\1/p' <<<"$out" | head -1)
  case "$codec" in
    vp9) pass "$label: the daemon chose $codec"; return 0 ;;
    "") fail "$label: no codec= line at all: $(tail -2 <<<"$out")"; return 1 ;;
    *) fail "$label: the daemon chose '$codec' with nothing asking it to"; return 1 ;;
  esac
}

# check the av1 refusal message
assert_av1_refused_by_name() {
  local label="$1" out="$2"
  grep -q 'no AV1 encode function is wired yet' <<<"$out" \
    || { fail "$label: --codec av1 did not name the refusal: $(tail -2 <<<"$out")"; return 1; }
  grep -q 'RHIZO_STREAMD_SELFTEST_OK' <<<"$out" \
    && { fail "$label: --codec av1 encoded anyway"; return 1; }
  pass "$label: --codec av1 refuses by name, never falling through to a silent mismatch"
}

# check --codec h264 requires --allow-h264
assert_h264_refused() {
  local label="$1" out="$2"
  grep -q 'needs --allow-h264' <<<"$out" \
    || { fail "$label: --codec h264 without the opt-in did not name the refusal: $(tail -2 <<<"$out")"; return 1; }
  grep -q 'RHIZO_STREAMD_SELFTEST_OK' <<<"$out" \
    && { fail "$label: --codec h264 without the opt-in encoded anyway"; return 1; }
  pass "$label: --codec h264 without --allow-h264 refuses"
}

# check the H.264 opt-in prints the disclosure
assert_h264_disclosed() {
  local label="$1" out="$2" want
  for want in "patent pools" "MPEG LA" "Access Advance" "not sought or obtained a patent license"; do
    grep -qF "$want" <<<"$out" \
      || { fail "$label: the H.264 opt-in did not print '$want': $(head -3 <<<"$out")"; return 1; }
  done
  pass "$label: the H.264 opt-in printed the AVC patent-question disclosure"
}

# check the composer stand-in acked the frames
assert_export_test_ok() {
  local label="$1" out="$2" want="$3" got
  got=$(sed -n 's/^RHIZO_STREAM_EXPORT_TEST_OK frames=\([0-9]*\).*/\1/p' <<<"$out" | head -1)
  [[ "$got" == "$want" ]] \
    || { fail "$label: the composer stand-in acked ${got:-no} frame(s), wanted $want: $(tail -2 <<<"$out")"; return 1; }
  pass "$label: every one of $want dma-buf frame(s) was imported and acked"
}

# check the stream hello and frame count
assert_stream_hello() {
  local label="$1" out="$2" want_wh="$3" want_n="$4" size codec n
  size=$(sed -n 's/.*RHIZO_STREAM_CAPTURE .*size=\([0-9x]*\).*/\1/p' <<<"$out" | head -1)
  codec=$(sed -n 's/.*RHIZO_STREAM_CAPTURE codec=\([a-z0-9]*\).*/\1/p' <<<"$out" | head -1)
  n=$(sed -n 's/.*RHIZO_STREAM_CAPTURE .*frames=\([0-9]*\).*/\1/p' <<<"$out" | head -1)
  if [[ "$size" != "$want_wh" ]]; then
    fail "$label: the stream announced ${size:-<no hello>}, wanted $want_wh"
    return 1
  fi
  if [[ "$n" != "$want_n" ]]; then
    fail "$label: the viewer read ${n:-no} frame(s), wanted $want_n"
    return 1
  fi
  if [[ "$codec" != "vp9" ]]; then
    fail "$label: the hello announced codec=${codec:-<none>}, wanted vp9 (the only wired encode path)"
    return 1
  fi
  pass "$label: the stream announced $codec at $size and delivered $n frame(s)"
}

# check the decoded frame matches the reference
assert_frame_matches() {
  local label="$1" out="$2" max="$3" delta
  delta=$(sed -n 's/^mean_abs_delta=//p' <<<"$out" | head -1)
  [[ -n "$delta" ]] || { fail "$label: pngstat --diff printed no mean_abs_delta: $(tail -2 <<<"$out")"; return 1; }
  if ! awk -v v="$delta" -v m="$max" 'BEGIN{exit !(v<=m)}'; then
    fail "$label: the decoded streamed frame differs from the reference by mean_abs_delta=$delta, over the $max this encode can lose"
    return 1
  fi
  pass "$label: the decoded streamed frame matches the reference (mean_abs_delta=$delta)"
}

# check the red left and blue right halves
assert_pattern_halves() {
  local label="$1" left="$2" right="$3" lr lb rr rb
  lr=$(sed -n 's/^mean_r=//p' <<<"$left" | head -1); lb=$(sed -n 's/^mean_b=//p' <<<"$left" | head -1)
  rr=$(sed -n 's/^mean_r=//p' <<<"$right" | head -1); rb=$(sed -n 's/^mean_b=//p' <<<"$right" | head -1)
  for v in "$lr" "$lb" "$rr" "$rb"; do
    [[ -n "$v" ]] || { fail "$label: pngstat printed no channel means for one of the halves"; return 1; }
  done
  if ! awk -v a="$lr" -v b="$lb" 'BEGIN{exit !(a>128 && b<64)}'; then
    fail "$label: the left half decoded to mean_r=$lr mean_b=$lb, not red"
    return 1
  fi
  if ! awk -v a="$rr" -v b="$rb" 'BEGIN{exit !(b>128 && a<64)}'; then
    fail "$label: the right half decoded to mean_r=$rr mean_b=$rb, not blue"
    return 1
  fi
  pass "$label: red left (r=$lr b=$lb), blue right (r=$rr b=$rb) survived the round trip"
}

# check the browser viewer proof output
assert_browser_proof() {
  local label="$1" rc="$2" out="$3"
  if (( rc != 0 )); then
    fail "$label: $(tail -3 <<<"$out")"
    return 1
  fi
  grep -q '^RHIZO_BROWSER_PROOF_OK' <<<"$out" \
    || { fail "$label: exited 0 with no RHIZO_BROWSER_PROOF_OK line: $(tail -3 <<<"$out")"; return 1; }
  pass "$label: $(grep '^RHIZO_BROWSER_PROOF_OK' <<<"$out")"
}

# check the rhizo-stream-export-verify selftest output
assert_verify_selftest() {
  local label="$1" out="$2" line
  line=$(grep '^RHIZO_STREAM_VERIFY_SELFTEST_OK' <<<"$out" | tail -1)
  [[ -n "$line" ]] || { fail "$label: no RHIZO_STREAM_VERIFY_SELFTEST_OK line: $(tail -3 <<<"$out")"; return 1; }
  grep -q ' refused=1' <<<"$line" \
    || { fail "$label: the selftest did not refuse its junk frame: $line"; return 1; }
  pass "$label: $line"
}

# check the frames rhizo-stream-export-verify received
assert_verify_report() {
  local label="$1" rep="$2" want_n="$3" want_wh="$4" want_fourcc="$5" n bad
  n=$(grep -c '^RHIZO_STREAM_VERIFY seq=' <<<"$rep")
  [[ "$rep" == "" ]] && n=0
  if grep -q '^RHIZO_STREAM_VERIFY_REFUSED' <<<"$rep"; then
    fail "$label: the consumer refused something: $(grep -m1 '^RHIZO_STREAM_VERIFY_REFUSED' <<<"$rep")"
    return 1
  fi
  (( n >= want_n )) || { fail "$label: $n frame(s) received, wanted at least $want_n"; return 1; }
  bad=$(grep '^RHIZO_STREAM_VERIFY seq=' <<<"$rep" | grep -v " size=$want_wh " | head -1)
  [[ -z "$bad" ]] || { fail "$label: a frame's geometry is not $want_wh: $bad"; return 1; }
  bad=$(grep '^RHIZO_STREAM_VERIFY seq=' <<<"$rep" | grep -v " fourcc=$want_fourcc " | head -1)
  [[ -z "$bad" ]] || { fail "$label: a frame's format is not $want_fourcc: $bad"; return 1; }
  bad=$(grep '^RHIZO_STREAM_VERIFY seq=' <<<"$rep" | grep -v ' dmabuf=1 ' | head -1)
  [[ -z "$bad" ]] || { fail "$label: a frame's fd is not a dma-buf: $bad"; return 1; }
  bad=$(grep '^RHIZO_STREAM_VERIFY seq=' <<<"$rep" | grep -v ' sized=1 ' | head -1)
  [[ -z "$bad" ]] || { fail "$label: a frame's dma-buf is smaller than its own header claims: $bad"; return 1; }
  pass "$label: $n frame(s) at $want_wh $want_fourcc, every one a dma-buf of the size its header names"
}

# check the pixel readback method
assert_verify_readback() {
  local label="$1" rep="$2" want="$3" line kind
  line=$(grep '^RHIZO_STREAM_VERIFY seq=' <<<"$rep" | grep -E ' readback=(virtgpu|mmap|gbm) ' | tail -1)
  [[ -n "$line" ]] || { fail "$label: no frame was read back at all (every readback= is skipped or none)"; return 1; }
  kind=$(sed -n 's/.* readback=\([a-z]*\) .*/\1/p' <<<"$line")
  if [[ "$want" != any && "$kind" != "$want" ]]; then
    fail "$label: the pixels were read back by $kind, wanted $want"
    return 1
  fi
  pass "$label: read back by $kind ($(grep -o 'nonblack_pct=[0-9.]* distinct=[0-9]*' <<<"$line"))"
}

# check the nonblack percent and distinct colors
assert_frame_not_blank() {
  local label="$1" out="$2" min_pct="$3" min_distinct="$4" pct distinct
  pct=$(sed -n 's/^nonblack_pct=//p' <<<"$out" | head -1)
  distinct=$(sed -n 's/^distinct=//p' <<<"$out" | head -1)
  [[ -n "$pct" && -n "$distinct" ]] || { fail "$label: pngstat printed no nonblack_pct/distinct: $(tail -2 <<<"$out")"; return 1; }
  if ! awk -v v="$pct" -v m="$min_pct" 'BEGIN{exit !(v>=m)}'; then
    fail "$label: only $pct% of the frame is non-black (floor $min_pct%)"
    return 1
  fi
  if (( distinct < min_distinct )); then
    fail "$label: only $distinct distinct color(s) (floor $min_distinct)"
    return 1
  fi
  pass "$label: nonblack_pct=$pct distinct=$distinct"
}

# check rhizo-stream-capability.path armed
assert_capability_watch_armed() {
  local label="$1" out="$2" state
  if grep -q 'Failed to enter waiting state\|Permission denied\|not found' <<<"$out"; then
    fail "$label: rhizo-stream-capability.path did not arm: $(grep -m1 'Failed\|denied\|not found' <<<"$out")"
    return 1
  fi
  state=$(tail -1 <<<"$out" | tr -d '[:space:]')
  [[ "$state" == active ]] || { fail "$label: rhizo-stream-capability.path is '${state:-<none>}', wanted active"; return 1; }
  pass "$label: rhizo-stream-capability.path is active"
}

# check the rhizo-streamd.socket unit state
assert_socket_unit_state() {
  local label="$1" out="$2" want="$3" got
  got=$(head -1 <<<"$out" | tr -d '[:space:]')
  [[ "$got" == "$want" ]] \
    || { fail "$label: rhizo-streamd.socket is '${got:-<none>}', wanted $want: $(tail -3 <<<"$out" | tr '\n' ' ')"; return 1; }
  pass "$label: rhizo-streamd.socket is $want"
}

# check the value contains text
assert_present() {
  local label="$1" what="$2" value="$3"
  [[ -n "${value//[[:space:]]/}" ]] || { fail "$label: $what"; return 1; }
  pass "$label: $value"
}

if (( SELFTEST )); then
  step "selftest: every assertion above must be able to fail, by name"

  check_fails() {
    local what="$1" fn="$2"; shift 2
    local before=$FAILED
    "$fn" "$@" >/dev/null
    if (( FAILED > before )); then
      log "  selftest OK: $what"
      FAILED=$before
      : > "$EV/failures.log"
    else
      fail "selftest: $what did NOT fail"
    fi
  }
  check_passes() {
    local what="$1" fn="$2"; shift 2
    local before=$FAILED
    "$fn" "$@" >/dev/null
    if (( FAILED > before )); then
      fail "selftest: $what fired on a genuinely good input"
    else
      log "  selftest OK: $what"
    fi
  }
  check_prints() {
    local what="$1" want="$2" fn="$3"; shift 3
    local got
    got=$("$fn" "$@" 2>&1)
    if [[ "$got" == "$want" ]]; then
      log "  selftest OK: $what"
    else
      fail "selftest: $what printed '$got', wanted '$want'"
    fi
  }
  check_skips() {
    local what="$1" want="$2" fn="$3"; shift 3
    local before=$FAILED out
    "$fn" "$@" >/dev/null 2>"$EV/check-skips.log"
    out=$(cat "$EV/check-skips.log")
    if (( FAILED > before )); then
      fail "selftest: $what failed where it should have skipped: $(tail -1 <<<"$out")"
    elif ! grep -q 'NOT RUN: .*no encoder rhizo-streamd can use' <<<"$out" || ! grep -qF -- "$want" <<<"$out"; then
      fail "selftest: $what logged no NOT RUN line naming '$want': ${out:-<nothing>}"
    else
      log "  selftest OK: $what"
    fi
  }

  check_fails "a capability shipped on is caught" assert_capability_default_off x True
  check_fails "an unreadable default is caught" assert_capability_default_off x ""
  check_passes "the shipped default off is accepted" assert_capability_default_off x False

  RC_GOOD=$'service vendor.rhizo-composer /vendor/bin/hw/rhizo-composer\n# @RHIZO_SUBST stream_socket'
  HALS_GOOD='"stream_socket": "    setenv RHIZO_STREAM_SOCKET /dev/socket/rhizo_stream/streamd\n"
                               if _server_policy.allows("stream.enabled") else ""},'
  HALS_UNGATED='"stream_socket": "    setenv RHIZO_STREAM_SOCKET /dev/socket/rhizo_stream/streamd\n"},'
  check_fails "a template with no substitution point is caught" assert_socket_env_gated x \
    "service vendor.rhizo-composer /vendor/bin/hw/rhizo-composer" "$HALS_GOOD"
  check_fails "a literal socket path in the rc is caught" assert_socket_env_gated x \
    $'    setenv RHIZO_STREAM_SOCKET /dev/socket/rhizo_stream/streamd\n# @RHIZO_SUBST stream_socket' "$HALS_GOOD"
  check_fails "a substitution that never asks the policy is caught" assert_socket_env_gated x \
    "$RC_GOOD" "$HALS_UNGATED"
  check_passes "a policy-gated substitution is accepted" assert_socket_env_gated x "$RC_GOOD" "$HALS_GOOD"
  HALS_CALL='"stream_socket": stream_socket_line(_server_policy),
                           "clipboard_enabled": ""},'
  HALS_HELPER_GOOD="$HALS_CALL"$'\n\n\ndef stream_socket_line(policy):\n    """return the line"""\n    if not policy.allows("stream.enabled"):\n        return ""\n    if core.software_rendering():\n        return ""\n    return "    setenv RHIZO_STREAM_SOCKET /dev/socket/rhizo_stream/streamd\\n"\n\n\ndef stage_software_rro():\n    return False'
  HALS_HELPER_UNGATED="$HALS_CALL"$'\n\n\ndef stream_socket_line(policy):\n    """return the line"""\n    if core.software_rendering():\n        return ""\n    return "    setenv RHIZO_STREAM_SOCKET /dev/socket/rhizo_stream/streamd\\n"\n'
  HALS_HELPER_LATE="$HALS_CALL"$'\n\n\ndef stream_socket_line(policy):\n    """return the line"""\n    line = "    setenv RHIZO_STREAM_SOCKET /dev/socket/rhizo_stream/streamd\\n"\n    if not policy.allows("stream.enabled"):\n        return line\n    return ""\n'
  check_passes "a substitution through a stream_socket_line that asks the policy first is accepted" \
    assert_socket_env_gated x "$RC_GOOD" "$HALS_HELPER_GOOD"
  check_fails "a stream_socket_line that never asks the policy is caught" assert_socket_env_gated x \
    "$RC_GOOD" "$HALS_HELPER_UNGATED"
  check_fails "a stream_socket_line that returns the socket when the policy says no is caught" assert_socket_env_gated x \
    "$RC_GOOD" "$HALS_HELPER_LATE"
  check_fails "a substitution calling a stream_socket_line nobody defines is caught" assert_socket_env_gated x \
    "$RC_GOOD" "$HALS_CALL"
  check_passes "the tree's own sandbox/hals.py is accepted" assert_socket_env_gated x "$RC_GOOD" "$(cat "$HALS_PY")"

  MOUNTS_GOOD='host_stream_socket = os.environ.get("RHIZO_STREAM_HOST_SOCKET", "/run/rhizo-stream/streamd")
    host_stream_dir = os.path.dirname(host_stream_socket)
    mount(host_stream_dir, f"{NEWROOT}/dev/socket/rhizo_stream", None, MS_BIND)'
  check_fails "a launcher that binds nothing is caught" assert_socket_dir_bound x "mount(host_audio_dir, ...)"
  check_fails "a bind of the socket file is caught" assert_socket_dir_bound x \
    'mount(host_stream_socket, f"{NEWROOT}/dev/socket/rhizo_stream", None, MS_BIND)'
  check_passes "a bind of the socket directory is accepted" assert_socket_dir_bound x "$MOUNTS_GOOD"

  check_fails "a failed bind is caught" assert_launcher_bind_marker x \
    "[l3] stream socket dir bind mount FAILED: /run/rhizo-stream -- streaming discards"
  check_fails "a boot with no bind marker is caught" assert_launcher_bind_marker x "[l3] pivoted"
  check_passes "the bind marker is accepted" assert_launcher_bind_marker x \
    "[l3] stream socket dir bind-mounted: /run/rhizo-stream -> /dev/socket/rhizo_stream (socket may appear later)"

  check_fails "an unset composer variable is caught" assert_composer_env x \
    $'PATH=/system/bin\nHOME=/' "$SANDBOX_SOCKET"
  check_fails "an export log naming another path is caught" assert_composer_env x \
    "09-20 08:01:02.003  1234  1234 I rhizo-stream-export: EnsureConnected: connected to /tmp/elsewhere, presenting via the stream export path" "$SANDBOX_SOCKET"
  check_passes "the export log's own connect line is accepted" assert_composer_env x \
    "09-20 08:01:02.003  1234  1234 I rhizo-stream-export: EnsureConnected: connected to $SANDBOX_SOCKET, presenting via the stream export path" "$SANDBOX_SOCKET"
  check_passes "the export log's own refused connect still names the path" assert_composer_env x \
    "09-20 08:01:02.003  1234  1234 I rhizo-stream-export: EnsureConnected: connect($SANDBOX_SOCKET) failed errno=111 (Connection refused) -- no consumer, staying headless" "$SANDBOX_SOCKET"
  check_fails "the wrong socket path is caught" assert_composer_env x \
    "RHIZO_STREAM_SOCKET=/tmp/elsewhere" "$SANDBOX_SOCKET"
  check_passes "the substituted path is accepted" assert_composer_env x \
    $'PATH=/system/bin\n'"RHIZO_STREAM_SOCKET=$SANDBOX_SOCKET" "$SANDBOX_SOCKET"

  check_fails "a socket bound while the capability is off is caught" assert_nothing_bound x \
    "srw-rw-rw- 1 root root 0 /run/rhizo-stream/streamd"
  check_passes "nothing bound while the capability is off is accepted" assert_nothing_bound x ""

  VAINFO_GOOD=$'      VAProfileVP9Profile0            :\tVAEntrypointVLD\n      VAProfileVP9Profile0            :\tVAEntrypointEncSliceLP'
  VAINFO_DECODE_ONLY=$'      VAProfileVP9Profile0            :\tVAEntrypointVLD\n      VAProfileAV1Profile0            :\tVAEntrypointVLD'
  VAINFO_H264_ONLY=$'      VAProfileH264Main               :\tVAEntrypointEncSliceLP'
  VAINFO_INTEL_LP=$'vainfo: Driver version: Intel iHD driver for Intel(R) Gen Graphics - 24.1.0 ()\nvainfo: Supported profile and entrypoints\n      VAProfileH264Main               :\tVAEntrypointEncSliceLP\n      VAProfileVP9Profile0            :\tVAEntrypointVLD\n      VAProfileVP9Profile0            :\tVAEntrypointEncSliceLP\n      VAProfileAV1Profile0            :\tVAEntrypointVLD\n      VAProfileAV1Profile0            :\tVAEntrypointEncSliceLP'
  VAINFO_AMD_NO_LP=$'vainfo: Driver version: Mesa Gallium driver 26.2.4-arch3.1 for AMD Radeon RX 9060 XT (radeonsi, gfx1200, ACO, DRM 3.64, 7.2.9-2-cachyos)\nvainfo: Supported profile and entrypoints\n      VAProfileH264Main               :\tVAEntrypointVLD\n      VAProfileH264Main               :\tVAEntrypointEncSlice\n      VAProfileHEVCMain               :\tVAEntrypointEncSlice\n      VAProfileVP9Profile0            :\tVAEntrypointVLD\n      VAProfileAV1Profile0            :\tVAEntrypointVLD\n      VAProfileAV1Profile0            :\tVAEntrypointEncSlice\n      VAProfileNone                   :\tVAEntrypointVideoProc'
  VAINFO_AV1_LP_ONLY=$'      VAProfileVP9Profile0            :\tVAEntrypointVLD\n      VAProfileAV1Profile0            :\tVAEntrypointEncSliceLP'
  VAINFO_BROKEN=$'libva info: VA-API version 1.24.0\nlibva error: vaGetDriverNameByIndex() failed with unknown libva error, driver_name = (null)\nvaInitialize failed with error code -1 (unknown libva error),exit'
  check_prints "an Intel listing with a VP9 EncSliceLP is an encoder rhizo-streamd can use" \
    "usable VP9Profile0/EncSliceLP" streamd_encoder_state "$VAINFO_INTEL_LP"
  check_prints "an AMD listing of EncSlice encoders only names each one, none of them usable" \
    "none H264Main/EncSlice HEVCMain/EncSlice AV1Profile0/EncSlice" streamd_encoder_state "$VAINFO_AMD_NO_LP"
  check_prints "an AV1 EncSliceLP with no VP9 one is no encoder rhizo-streamd can use" \
    "none AV1Profile0/EncSliceLP" streamd_encoder_state "$VAINFO_AV1_LP_ONLY"
  check_prints "an H.264-only EncSliceLP is no encoder rhizo-streamd can use" \
    "none H264Main/EncSliceLP" streamd_encoder_state "$VAINFO_H264_ONLY"
  check_prints "a decode-only listing has no encode entrypoint" "none -" streamd_encoder_state "$VAINFO_DECODE_ONLY"
  check_prints "a vainfo that listed no profile is broken, named by its error" \
    "broken libva error: vaGetDriverNameByIndex() failed with unknown libva error, driver_name = (null)" \
    streamd_encoder_state "$VAINFO_BROKEN"
  check_prints "an empty vainfo is broken" "broken <no output>" streamd_encoder_state ""
  check_passes "a VP9 encode entrypoint is accepted" assert_encoder_present x "$VAINFO_GOOD"
  check_fails "a vainfo that listed no profile is caught" assert_encoder_present x "$VAINFO_BROKEN"
  check_fails "an empty vainfo is caught" assert_encoder_present x ""
  check_skips "an AMD host skips by name, naming the AV1 EncSlice it offers" "AV1Profile0/EncSlice" \
    assert_encoder_present x "$VAINFO_AMD_NO_LP"
  check_skips "a decode-only host skips by name" "no encode entrypoint at all" \
    assert_encoder_present x "$VAINFO_DECODE_ONLY"
  check_skips "an H.264-only host skips by name" "H264Main/EncSliceLP" assert_encoder_present x "$VAINFO_H264_ONLY"

  check_fails "a daemon that encoded where no encoder was found is caught" assert_daemon_refuses x \
    "RHIZO_STREAMD_SELFTEST_OK codec=vp9 frames=1 size=128x96 bytes=200 fps=100.00 out=/tmp/x.ivf"
  check_fails "a daemon that died without naming a refusal is caught" assert_daemon_refuses x \
    "Segmentation fault (core dumped)"
  check_passes "the daemon's own named refusal is accepted" assert_daemon_refuses x \
    "[rhizo-streamd] VA-API 1.24 on /dev/dri/renderD128"$'\n'"[rhizo-streamd] no usable EncSliceLP profile found (forced=(auto) allow_h264=0)"

  check_fails "an h264 default is caught" assert_codec_royalty_free x "[rhizo-streamd] codec=h264 profile=6"
  check_fails "no codec line at all is caught" assert_codec_royalty_free x "[rhizo-streamd] VA-API 1.20"
  check_passes "a vp9 default is accepted" assert_codec_royalty_free x "[rhizo-streamd] codec=vp9 profile=19"
  check_fails "an av1 default is caught (no encode function is wired for it)" \
    assert_codec_royalty_free x "[rhizo-streamd] codec=av1 profile=32"

  check_fails "a silent av1 fallthrough is caught" assert_av1_refused_by_name x \
    "[rhizo-streamd] no usable EncSliceLP profile found"
  check_fails "av1 encoding anyway is caught" assert_av1_refused_by_name x \
    "RHIZO_STREAMD_SELFTEST_OK codec=av1 frames=1 size=128x96 bytes=200 fps=100.00 out=/tmp/x.ivf"
  check_passes "the named av1 refusal is accepted" assert_av1_refused_by_name x \
    "[rhizo-streamd] --codec av1 refused: no AV1 encode function is wired yet"

  check_fails "an h264 encode with no opt-in is caught" assert_h264_refused x \
    "RHIZO_STREAMD_SELFTEST_OK codec=h264 frames=1 size=128x96 bytes=200 fps=100.00 out=/tmp/x.ivf"
  check_fails "a silent refusal is caught" assert_h264_refused x "[rhizo-streamd] no usable EncSliceLP profile found"
  check_passes "a named refusal is accepted" assert_h264_refused x \
    "[rhizo-streamd] --codec h264 needs --allow-h264"

  DISCLOSURE=$'rhizo-streamd: --codec h264 was requested. H.264/AVC decode and encode\nare covered by patent pools (MPEG LA\'s AVC pool, and Access Advance\'s\nHEVC/AVC pool) independent of any copyright question. This project has\nnot sought or obtained a patent license for either pool'
  check_fails "an opt-in that printed nothing is caught" assert_h264_disclosed x "[rhizo-streamd] codec=h264"
  check_fails "a disclosure missing a pool is caught" assert_h264_disclosed x \
    "H.264/AVC is covered by patent pools. This project has not sought or obtained a patent license for either pool"
  check_passes "the full disclosure is accepted" assert_h264_disclosed x "$DISCLOSURE"

  check_fails "a stand-in that acked fewer frames is caught" assert_export_test_ok x \
    "RHIZO_STREAM_EXPORT_TEST_OK frames=2 size=1280x800 drm_fourcc=0x34324241" 4
  check_fails "a stand-in that printed nothing is caught" assert_export_test_ok x "connect failed" 4
  check_passes "a complete stand-in run is accepted" assert_export_test_ok x \
    "RHIZO_STREAM_EXPORT_TEST_OK frames=4 size=1280x800 drm_fourcc=0x34324241" 4

  HELLO_GOOD="RHIZO_STREAM_CAPTURE codec=vp9 version=1 size=1280x800 frames=2 out=/tmp/c.ivf"
  check_fails "the wrong announced geometry is caught" assert_stream_hello x \
    "RHIZO_STREAM_CAPTURE codec=vp9 version=1 size=640x480 frames=2 out=/tmp/c.ivf" 1280x800 2
  check_fails "fewer frames than asked for is caught" assert_stream_hello x \
    "RHIZO_STREAM_CAPTURE codec=vp9 version=1 size=1280x800 frames=1 out=/tmp/c.ivf" 1280x800 2
  check_fails "a capture that never connected is caught" assert_stream_hello x "" 1280x800 2
  check_fails "a hello announcing av1 is caught" assert_stream_hello x \
    "RHIZO_STREAM_CAPTURE codec=av1 version=1 size=1280x800 frames=2 out=/tmp/c.ivf" 1280x800 2
  check_passes "a complete capture is accepted" assert_stream_hello x "$HELLO_GOOD" 1280x800 2

  check_fails "a frame that decoded to something else is caught" assert_frame_matches x \
    $'changed=900000\nchanged_pct=88.0\nmean_abs_delta=97.4' "$FRAME_MATCH_MAX_DELTA"
  check_fails "a diff that produced no number is caught" assert_frame_matches x "size=1280x800" "$FRAME_MATCH_MAX_DELTA"
  check_passes "a frame within the encode's own loss is accepted" assert_frame_matches x \
    $'changed=120000\nchanged_pct=11.7\nmean_abs_delta=3.9' "$FRAME_MATCH_MAX_DELTA"

  RED=$'mean_r=234.00\nmean_g=0.00\nmean_b=2.00'
  BLUE=$'mean_r=3.00\nmean_g=0.00\nmean_b=244.00'
  check_fails "swapped halves are caught" assert_pattern_halves x "$BLUE" "$RED"
  check_fails "a black frame is caught" assert_pattern_halves x $'mean_r=0.00\nmean_b=0.00' $'mean_r=0.00\nmean_b=0.00'
  check_fails "pngstat output with no means is caught" assert_pattern_halves x "size=1280x800" "size=1280x800"
  check_passes "red left and blue right are accepted" assert_pattern_halves x "$RED" "$BLUE"

  check_fails "a browser-proof crash is caught" assert_browser_proof x 3 "FAIL: streamd never bound its socket"
  check_fails "a wrong-content browser proof is caught" assert_browser_proof x 1 \
    "RHIZO_BROWSER_PROOF_MISMATCH frames=4 left_r=3.0 left_b=240.0 right_r=240.0 right_b=3.0"
  check_fails "a 0-exit with no OK line is caught" assert_browser_proof x 0 "some other output"
  check_passes "a real pass is accepted" assert_browser_proof x 0 \
    "RHIZO_BROWSER_PROOF_OK frames=4 left_r=255.0 left_b=3.0 right_r=1.0 right_b=243.0"

  check_fails "a verifier selftest that printed nothing is caught" assert_verify_selftest x "[stream-export-verify] gbm_bo_create failed"
  check_fails "a verifier selftest that acked junk is caught" assert_verify_selftest x \
    "RHIZO_STREAM_VERIFY_SELFTEST_OK frames=3 refused=0 readback=mmap left_r=255.0 left_b=0.0 right_r=0.0 right_b=255.0 dump_bytes=131072"
  check_passes "a real verifier selftest is accepted" assert_verify_selftest x \
    "RHIZO_STREAM_VERIFY_SELFTEST_OK frames=3 refused=1 readback=mmap left_r=255.0 left_b=0.0 right_r=0.0 right_b=255.0 dump_bytes=131072"

  VLINE="RHIZO_STREAM_VERIFY seq=%s size=%s fourcc=%s modifier=0x0000000000000000 stride=5120 offset=0 fd_bytes=4194304 dmabuf=%s sized=%s readback=%s nonblack_pct=97.10 distinct=310 mean_r=40.1 mean_g=40.3 mean_b=41.0 left_r=40.0 left_b=41.0 right_r=40.2 right_b=41.1 presented_ns=1 received_ns=2"
  vline() { printf "$VLINE" "$@"; }
  # shellcheck disable=SC2059
  REPORT_GOOD=$(vline 1 1280x800 0x34324241 1 1 virtgpu; echo; vline 2 1280x800 0x34324241 1 1 virtgpu; echo; vline 3 1280x800 0x34324241 1 1 skipped)
  check_fails "too few frames is caught" assert_verify_report x "$REPORT_GOOD" 4 1280x800 0x34324241
  check_fails "an empty report is caught" assert_verify_report x "" 1 1280x800 0x34324241
  check_fails "a refused message is caught" assert_verify_report x \
    "$REPORT_GOOD"$'\n'"RHIZO_STREAM_VERIFY_REFUSED magic=0x4a554e4b version=1 fd=5 reason=not-a-frame" 3 1280x800 0x34324241
  check_fails "the wrong geometry is caught" assert_verify_report x \
    "$(vline 1 640x480 0x34324241 1 1 virtgpu; echo; vline 2 1280x800 0x34324241 1 1 virtgpu)" 2 1280x800 0x34324241
  check_fails "the wrong format is caught" assert_verify_report x \
    "$(vline 1 1280x800 0x34325258 1 1 virtgpu)" 1 1280x800 0x34324241
  check_fails "an fd that is not a dma-buf is caught" assert_verify_report x \
    "$(vline 1 1280x800 0x34324241 0 1 mmap)" 1 1280x800 0x34324241
  check_fails "an undersized dma-buf is caught" assert_verify_report x \
    "$(vline 1 1280x800 0x34324241 1 0 skipped)" 1 1280x800 0x34324241
  check_passes "a clean report is accepted" assert_verify_report x "$REPORT_GOOD" 3 1280x800 0x34324241

  check_fails "a report with no readback is caught" assert_verify_readback x \
    "$(vline 1 1280x800 0x34324241 1 1 skipped)" virtgpu
  check_fails "an outdated-shadow mmap on a virtio-gpu is caught" assert_verify_readback x \
    "$(vline 1 1280x800 0x34324241 1 1 mmap)" virtgpu
  check_passes "a virtgpu readback is accepted" assert_verify_readback x "$REPORT_GOOD" virtgpu
  check_passes "any readback is accepted where the host decides" assert_verify_readback x \
    "$(vline 1 1280x800 0x34324241 1 1 mmap)" any
  check_passes "a gbm readback of a tiled buffer is accepted where the host decides" assert_verify_readback x \
    "$(vline 1 1280x800 0x34324241 1 1 gbm)" any
  check_fails "a gbm readback where virtio-gpu's own transfer is wanted is caught" assert_verify_readback x \
    "$(vline 1 1280x800 0x34324241 1 1 gbm)" virtgpu

  check_fails "an all-black frame is caught" assert_frame_not_blank x \
    $'size=1280x800\npixels=1024000\nnonblack=0\nnonblack_pct=0.0\ndistinct=1' 20 8
  check_fails "a flat single-color frame is caught" assert_frame_not_blank x \
    $'size=1280x800\nnonblack=1024000\nnonblack_pct=100.0\ndistinct=1' 20 8
  check_fails "pngstat output with no coverage keys is caught" assert_frame_not_blank x "size=1280x800" 20 8
  check_passes "a real picture is accepted" assert_frame_not_blank x \
    $'size=1280x800\nnonblack=990000\nnonblack_pct=96.7\ndistinct=412' 20 8

  check_fails "a watcher that could not create its watch is caught" assert_capability_watch_armed x \
    $'Job for rhizo-stream-capability.path failed.\nFailed to enter waiting state: Permission denied\nfailed'
  check_fails "an inactive watcher is caught" assert_capability_watch_armed x "inactive"
  check_fails "an absent watcher unit is caught" assert_capability_watch_armed x \
    $'Failed to restart rhizo-stream-capability.path: Unit rhizo-stream-capability.path not found.\ninactive'
  check_passes "an armed watcher is accepted" assert_capability_watch_armed x "active"

  check_fails "a socket unit the watcher never enabled is caught" assert_socket_unit_state x \
    $'disabled\nactive' enabled
  check_fails "a socket unit the watcher never disabled is caught" assert_socket_unit_state x \
    $'enabled\ninactive' disabled
  check_fails "no answer at all is caught" assert_socket_unit_state x "" enabled
  check_passes "an enabled socket unit is accepted" assert_socket_unit_state x $'enabled\nlistening' enabled
  check_passes "a disabled socket unit is accepted" assert_socket_unit_state x $'disabled\ninactive' disabled

  check_fails "a missing dependency is caught" assert_present x "no vpxdec on this host" ""
  check_passes "a present dependency is accepted" assert_present x "vpxdec" "/usr/bin/vpxdec"

  if (( FAILED )); then
    log "test-stream --selftest: FAILED"
    exit 1
  fi
  log "test-stream --selftest: the system test can still fail"
  exit 0
fi

# write text to an evidence file
save_evidence() {
  printf '%s\n' "$2" > "$EV/$1"
}

# wait for sys.boot_completed and print it
guest_boot_completed() {
  local deadline=$((SECONDS + $1)) bc=""
  while (( SECONDS < deadline )); do
    bc=$(getprop_vm "$INIT" sys.boot_completed 2>/dev/null | tr -d '\r\n')
    [[ "$bc" == 1 ]] && break
    sleep 3
  done
  printf '%s' "$bc"
}

# start rhizo-stream-verify and print its state
ensure_verifier_enforcing() {
  local state
  state=$(vm_consumer_state rhizo-stream-verify)
  if grep -qx 'active' <<<"$state" && grep -q "^s.* $GUEST_STREAM_SOCKET" <<<"$state" \
      && grep -q 'u:r:rhizo_host:s0' <<<"$state"; then
    printf '%s\n' "$state"
    return 0
  fi
  if ! RHIZO_POLICY_CONF="$HOST_STREAM_POLICY" ../../vm/start/start-stream.sh --verify-only --socket "$GUEST_STREAM_SOCKET" \
      --report "$GUEST_VERIFY_REPORT" --dump "$GUEST_VERIFY_DUMP" > "$EV/start-stream-verify-enforcing.log" 2>&1; then
    echo "start-stream.sh --verify-only failed on the enforcing side: $(tail -3 "$EV/start-stream-verify-enforcing.log" | tr '\n' ' ')"
    return 1
  fi
  vm_consumer_state rhizo-stream-verify
}

# check the SELinux domain in the ps line
assert_consumer_domain() {
  local label="$1" out="$2" want="$3" got
  got=$(grep -o 'u:r:[a-z_]*:s0' <<<"$out" | head -1)
  [[ "$got" == "$want" ]] || { fail "$label: the consumer runs as '${got:-<none>}', wanted $want"; return 1; }
  pass "$label: the consumer runs as $got"
}

# wait for and print the composer pid
resolve_composer() {
  local deadline=$((SECONDS + $1)) pid=""
  while (( SECONDS < deadline )); do
    pid=$(ssh_vm -t 15 'pgrep -x rhizo-composer' 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ -n "$pid" ]] && break
    sleep 3
  done
  printf '%s' "$pid"
}

# print the guest init pid
resolve_init() {
  local deadline=$((SECONDS + $1)) pid=""
  while (( SECONDS < deadline )); do
    pid=$(guest_init_pid 15)
    [[ -n "$pid" ]] && break
    sleep 3
  done
  printf '%s' "$pid"
}

# grep the boot log and dmesg
guest_marker() {
  ssh_vm -t 20 "grep -aF '$1' $BOOT_LOG 2>/dev/null; dmesg | grep -aF '$1'" 2>/dev/null
}

# dump the composer target to a PNG file
fetch_client_target_png() {
  local before reply w h s raw
  before=$(rhizo_ctl_out "$INIT" | grep -c '^dump-client-target')
  [[ "$before" =~ ^[0-9]+$ ]] || before=0
  rhizo_ctl "$INIT" display dump-client-target >/dev/null 2>&1
  for _ in $(seq 1 30); do
    reply=$(rhizo_ctl_out "$INIT" | grep '^dump-client-target' | tail -n +$((before + 1)) | tail -1)
    [[ -n "$reply" ]] && break
    sleep 1
  done
  save_evidence client-target-reply.txt "$reply"
  grep -q '^dump-client-target done .* xfer=ok' <<<"$reply" || return 1
  read -r w h s <<<"$(sed -n \
    's/^dump-client-target done size=\([0-9]*\)x\([0-9]*\) stride=\([0-9]*\) .*/\1 \2 \3/p' \
    <<<"$reply")"
  [[ -n "$w" && -n "$h" && -n "$s" ]] || return 1
  raw="$EV/client-target.raw"
  rm -f "$raw"
  local want got b64 prc
  want=$(sed -n 's/.* bytes=\([0-9]*\) .*/\1/p' <<<"$reply")
  b64=$(probe_cmd 120 "/system/bin/toybox base64 /data/rhizo_control/client_target.raw"); prc=$?
  printf '%s\n' "probe rc=$prc base64_chars=${#b64} head=$(head -c 200 <<<"$b64" | tr '\n' ' ')" > "$EV/client-target-pull.txt"
  base64 -d <<<"$b64" > "$raw" 2>>"$EV/client-target-pull.txt"
  got=$(stat -c %s "$raw" 2>/dev/null)
  if [[ -z "$want" || "$got" != "$want" ]]; then
    rm -f "$SHARE_DIR/client-target.raw"
    ssh_vm -t 60 "python3 -c 'import shutil; shutil.copyfile(\"/run/rhizo/data/rhizo_control/client_target.raw\", \"/root/share/client-target.raw\")'" >> "$EV/client-target-pull.txt" 2>&1
    [[ -f "$SHARE_DIR/client-target.raw" ]] && cp --remove-destination "$SHARE_DIR/client-target.raw" "$raw"
    got=$(stat -c %s "$raw" 2>/dev/null)
    printf '%s\n' "rhizo_host copy: got=${got:-0} want=${want:-?}" >> "$EV/client-target-pull.txt"
  fi
  [[ -n "$want" && "$got" == "$want" ]] || { log "  client-target dump: pulled ${got:-0} bytes, the reply said ${want:-?} (evidence: $EV/client-target-pull.txt)"; return 1; }
  python3 "$STREAM_CLIENT" raw-to-png --raw "$raw" --size "${w}x${h}" --stride "$s" \
    --out "$1" >/dev/null 2>&1 || return 1
  printf '%sx%s' "$w" "$h"
}

# wait for rhizo-stream-capability.service to finish
await_capability_sync_idle() {
  local deadline=$((SECONDS + $1)) st
  while (( SECONDS < deadline )); do
    st=$(ssh_vm -t 15 "systemctl is-active rhizo-stream-capability.service 2>&1" 2>/dev/null | tr -d '[:space:]')
    [[ "$st" == inactive || "$st" == failed ]] && return 0
    sleep 1
  done
  return 1
}

# print the stream verify report
verify_report() { ssh_vm -t 20 "cat $GUEST_VERIFY_REPORT 2>/dev/null" 2>/dev/null; }
# print the frame line count
verify_frame_count() {
  local n
  n=$(ssh_vm -t 15 "grep -c '^RHIZO_STREAM_VERIFY seq=' $GUEST_VERIFY_REPORT 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# wait for n frame lines in the report
await_verify_frames() {
  local deadline=$((SECONDS + $2)) n=0
  while (( SECONDS < deadline )); do
    n=$(verify_frame_count)
    (( n >= $1 )) && break
    sleep 1
  done
  verify_report
}

# wait for the frame count to stop changing
await_presents_quiet() {
  local deadline=$((SECONDS + $2)) prev=-1 n same=0
  while (( SECONDS < deadline )); do
    n=$(verify_frame_count)
    if [[ "$n" == "$prev" ]]; then
      (( ++same >= $1 )) && return 0
    else
      same=0
    fi
    prev=$n
    sleep 1
  done
  return 1
}

# poll the enabled state of rhizo-streamd.socket
await_socket_unit() {
  local deadline=$((SECONDS + $2)) got=""
  while (( SECONDS < deadline )); do
    got=$(ssh_vm -t 15 "systemctl is-enabled rhizo-streamd.socket 2>&1" 2>/dev/null | head -1 | tr -d '[:space:]')
    [[ "$got" == "$1" ]] && break
    sleep 1
  done
  printf '%s\n' "$got"
  ssh_vm -t 20 "systemctl is-active rhizo-streamd.socket 2>&1; journalctl -u rhizo-stream-capability.service -b --no-pager 2>&1 | tail -5" 2>/dev/null
}

# copy the newest read-back frame from the vm
fetch_verify_dump() {
  local got=""
  ssh_vm -t 15 "rm -f $GUEST_VERIFY_DUMP; systemctl kill -s USR1 rhizo-stream-verify" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    got=$(ssh_vm -t 15 "stat -c %s $GUEST_VERIFY_DUMP 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
    [[ "$got" == "$1" ]] && break
    sleep 1
  done
  [[ "$got" == "$1" ]] || return 1
  rm -f "$2"
  ssh_vm -t 120 "base64 $GUEST_VERIFY_DUMP" 2>/dev/null | base64 -d > "$2" 2>/dev/null
  [[ "$(stat -c %s "$2" 2>/dev/null)" == "$1" ]]
}

step "1. the capability, read from the files that decide it -- no VM, no boot"

assert_capability_default_off "1a. the shipped default" "$STREAM_DEFAULT"
assert_socket_env_gated "1b. the composer's socket variable" "$(cat "$COMPOSER_RC")" "$(cat "$HALS_PY")"
assert_socket_dir_bound "1c. what the launcher binds" "$(cat "$MOUNTS_PY")"

step "2. this host's own encoder: what vainfo reports, and what it produces"

VPXDEC=$(command -v vpxdec)
assert_present "2a. a real decoder" \
  "no vpxdec on this host (apt-get install vpx-tools)" \
  "$VPXDEC"
VAINFO=$(command -v vainfo)
assert_present "2b. vainfo" \
  "no vainfo on this host (apt-get install libva-utils)" \
  "$VAINFO"

HOST_ENCODER=""
if [[ -n "$VAINFO" && -n "$VPXDEC" && -x "$STREAMD" && -x "$EXPORT_TEST" ]]; then
  VAINFO_OUT=$(vainfo --display drm --device "$RENDER_NODE" 2>&1)
  save_evidence vainfo.txt "$VAINFO_OUT"
  HOST_ENCODER=$(streamd_encoder_state "$VAINFO_OUT")
  assert_encoder_present "2c. the encoder rhizo-streamd uses" "$VAINFO_OUT"

  SELFTEST_IVF="$EV/host-selftest.ivf"
  SELFTEST_OUT=$("$STREAMD" --selftest-encode "$SELFTEST_IVF" --render-node "$RENDER_NODE" 2>&1)
  save_evidence streamd-selftest.txt "$SELFTEST_OUT"
  if [[ "$HOST_ENCODER" == none\ * ]]; then
    assert_daemon_refuses "2d. the daemon on a GPU with no encoder it can use" "$SELFTEST_OUT"
  else
    assert_codec_royalty_free "2d. the codec chosen with nothing forced" "$SELFTEST_OUT"
  fi

  H264_OFF=$("$STREAMD" --selftest-encode "$EV/h264.ivf" --codec h264 --render-node "$RENDER_NODE" 2>&1)
  assert_h264_refused "2e. H.264 without the opt-in" "$H264_OFF"
  H264_ON=$("$STREAMD" --selftest-encode "$EV/h264.ivf" --codec h264 --allow-h264 \
    --render-node "$RENDER_NODE" 2>&1)
  save_evidence h264-disclosure.txt "$H264_ON"
  assert_h264_disclosed "2f. the H.264 opt-in's disclosure" "$H264_ON"

  AV1_OUT=$("$STREAMD" --selftest-encode "$EV/av1.ivf" --codec av1 --render-node "$RENDER_NODE" 2>&1)
  save_evidence av1-refusal.txt "$AV1_OUT"
  assert_av1_refused_by_name "2g. --codec av1 (not selectable until it is wired)" "$AV1_OUT"
else
  skip "2c-2g. this host's encoder -- vainfo, vpxdec or a built rhizo-streamd is missing"
fi

step "3. a real dma-buf in, a decoded frame out, on this host's own engine"

if [[ "$HOST_ENCODER" == none\ * ]]; then
  skip "3a-3d. the host encode proof -- $(no_encoder_reason "${HOST_ENCODER#none }") (evidence: $EV/vainfo.txt)"
elif [[ -x "$STREAMD" && -x "$EXPORT_TEST" && -n "$VPXDEC" ]]; then
  rm -f "$HOST_SOCKET"
  "$STREAMD" --socket "$HOST_SOCKET" --port "$HOST_PORT" --render-node "$RENDER_NODE" \
    > "$EV/streamd.log" 2>&1 &
  STREAMD_PID=$!
  for _ in $(seq 1 50); do [[ -S "$HOST_SOCKET" ]] && break; sleep 0.2; done

  if [[ ! -S "$HOST_SOCKET" ]]; then
    fail "3a. rhizo-streamd never bound $HOST_SOCKET: $(tail -3 "$EV/streamd.log")"
  else
    pass "3a. the daemon bound $HOST_SOCKET and is serving TCP $HOST_PORT"
    CAP_IVF="$EV/host-capture.ivf"
    python3 "$STREAM_CLIENT" capture --port "$HOST_PORT" --frames 2 --out "$CAP_IVF" \
      --times "$EV/host-capture.tsv" > "$EV/host-capture.log" 2>&1 &
    VIEWER=$!
    for _ in $(seq 1 100); do
      grep -q '^RHIZO_STREAM_HELLO ' "$EV/host-capture.log" 2>/dev/null && break
      sleep 0.1
    done
    EXPORT_OUT=$("$EXPORT_TEST" --socket "$HOST_SOCKET" --frames 4 --size "${HOST_W}x${HOST_H}" \
      --render-node "$RENDER_NODE" 2>&1)
    save_evidence export-test.txt "$EXPORT_OUT"
    assert_export_test_ok "3b. the composer stand-in" "$EXPORT_OUT" 4
    wait "$VIEWER" 2>/dev/null
    CAP_OUT=$(cat "$EV/host-capture.log")
    assert_stream_hello "3c. the viewer's own account" "$CAP_OUT" "${HOST_W}x${HOST_H}" 2

    rm -f "$EV/host-capture.i420" "$EV/host-frame.png"
    if [[ -s "$CAP_IVF" ]]; then
      if ! vpxdec --codec=vp9 --i420 -o "$EV/host-capture.i420" "$CAP_IVF" > "$EV/vpxdec.log" 2>&1; then
        fail "3d. vpxdec exited nonzero decoding the captured stream: $(tail -3 "$EV/vpxdec.log")"
      elif ! python3 "$STREAM_CLIENT" frame-to-png --i420 "$EV/host-capture.i420" \
          --size "${HOST_W}x${HOST_H}" --frame 0 --out "$EV/host-frame.png" > "$EV/frame-to-png.log" 2>&1; then
        fail "3d. frame-to-png exited nonzero: $(tail -3 "$EV/frame-to-png.log")"
      else
        HALF=$(( HOST_W / 2 ))
        LEFT=$(python3 "$PNGSTAT" "$EV/host-frame.png" --region "0,0,$HALF,$HOST_H" 2>&1)
        RIGHT=$(python3 "$PNGSTAT" "$EV/host-frame.png" --region "$HALF,0,$HALF,$HOST_H" 2>&1)
        save_evidence host-frame-halves.txt "left:"$'\n'"$LEFT"$'\n'"right:"$'\n'"$RIGHT"
        assert_pattern_halves "3d. the decoded streamed frame" "$LEFT" "$RIGHT"
      fi
    else
      fail "3d. no frames were captured"
    fi
  fi
  kill "$STREAMD_PID" 2>/dev/null
  rm -f "$HOST_SOCKET"
else
  skip "3. the host encode proof -- rhizo-streamd, its composer stand-in or vpxdec is missing"
fi

step "3e. the browser viewer: a real headless Chromium, real WebCodecs, a real stream"

PLAYWRIGHT_OK=$(python3 -c 'import playwright.sync_api' 2>/dev/null && echo yes)
if [[ "$HOST_ENCODER" == none\ * ]]; then
  skip "3e. the browser viewer proof -- $(no_encoder_reason "${HOST_ENCODER#none }")"
elif [[ -x "$STREAMD" && -x "$EXPORT_TEST" && "$PLAYWRIGHT_OK" == yes ]]; then
  BROWSER_OUT=$(python3 "$BROWSER_PROOF" --streamd "$STREAMD" --export-test "$EXPORT_TEST" \
    --render-node "$RENDER_NODE" --port "${RHIZO_STREAM_BROWSER_PORT:-18701}" 2>&1)
  BROWSER_RC=$?
  save_evidence browser-proof.txt "$BROWSER_OUT"
  if (( BROWSER_RC == 2 )); then
    skip "3e. the browser viewer proof -- $(grep -m1 '^SKIP:' <<<"$BROWSER_OUT")"
  else
    assert_browser_proof "3e. the browser viewer decodes a real stream" "$BROWSER_RC" "$BROWSER_OUT"
  fi
else
  skip "3e. the browser viewer proof -- playwright is not installed, or rhizo-streamd/the composer stand-in is missing (pip install playwright && python3 -m playwright install chromium)"
fi

step "3f. the verify-only consumer: its own selftest, then the composer stand-in through it"

assert_present "3f. a built rhizo-stream-export-verify" \
  "no $VERIFY -- build it with tools/build/services/streamd.sh" \
  "$([[ -x "$VERIFY" ]] && echo "$VERIFY")"
if [[ -x "$VERIFY" && -x "$EXPORT_TEST" ]]; then
  VERIFY_SELFTEST=$("$VERIFY" --selftest --render-node "$RENDER_NODE" 2>&1)
  save_evidence verify-selftest.txt "$VERIFY_SELFTEST"
  assert_verify_selftest "3f1. the consumer's own red-left/blue-right round trip" "$VERIFY_SELFTEST"

  HOST_VERIFY_SOCKET="${TMPDIR:-/tmp}/test-stream-verify${SUFFIX}.sock"
  rm -f "$HOST_VERIFY_SOCKET" "$EV/host-verify.tsv"
  "$VERIFY" --socket "$HOST_VERIFY_SOCKET" --report "$EV/host-verify.tsv" --readback-every 1 --frames 4 \
    --render-node "$RENDER_NODE" > "$EV/host-verify.log" 2>&1 &
  VERIFY_PID=$!
  for _ in $(seq 1 50); do [[ -S "$HOST_VERIFY_SOCKET" ]] && break; sleep 0.2; done
  if [[ ! -S "$HOST_VERIFY_SOCKET" ]]; then
    fail "3f2. rhizo-stream-export-verify never bound $HOST_VERIFY_SOCKET: $(tail -3 "$EV/host-verify.log")"
  else
    VEXPORT_OUT=$("$EXPORT_TEST" --socket "$HOST_VERIFY_SOCKET" --frames 4 --size "${HOST_W}x${HOST_H}" \
      --render-node "$RENDER_NODE" 2>&1)
    save_evidence verify-export-test.txt "$VEXPORT_OUT"
    assert_export_test_ok "3f2. the composer stand-in, acked by the consumer" "$VEXPORT_OUT" 4
    wait "$VERIFY_PID" 2>/dev/null
    HOST_VERIFY_OUT=$(cat "$EV/host-verify.tsv" 2>/dev/null)
    assert_verify_report "3f3. the consumer's account of those frames" "$HOST_VERIFY_OUT" 4 \
      "${HOST_W}x${HOST_H}" "$CLIENT_TARGET_FOURCC"
    assert_verify_readback "3f4. the pixels behind the stand-in's dma-buf" "$HOST_VERIFY_OUT" any
    HOST_VERIFY_LAST=$(grep '^RHIZO_STREAM_VERIFY seq=' <<<"$HOST_VERIFY_OUT" | tail -1)
    assert_pattern_halves "3f5. the stand-in's red-left/blue-right pattern, read back by the consumer" \
      "$(sed -n 's/.* left_r=\([0-9.]*\) left_b=\([0-9.]*\).*/mean_r=\1\nmean_b=\2/p' <<<"$HOST_VERIFY_LAST")" \
      "$(sed -n 's/.* right_r=\([0-9.]*\) right_b=\([0-9.]*\).*/mean_r=\1\nmean_b=\2/p' <<<"$HOST_VERIFY_LAST")"
  fi
  kill "$VERIFY_PID" 2>/dev/null
  rm -f "$HOST_VERIFY_SOCKET"
else
  skip "3f1-3f5. the verify-only consumer -- rhizo-stream-export-verify or the composer stand-in is missing"
fi

step "5. a vm with stream.enabled on: the socket, the composer, the daemon"

BOOT_ARGS=(--skip-graphics-preflight)
[[ -n "${RHIZO_RELEASE:-}" ]] && BOOT_ARGS+=(--release "$RHIZO_RELEASE")
export RHIZO_COMPOSER_DEBUG=1
test_boot "${BOOT_ARGS[@]}" || { test_record_verdict FAILED; exit 1; }

../../vm/sync.sh >/dev/null || { fail "5. sync.sh failed"; test_record_verdict FAILED; exit 1; }
if ! ../../vm/redeploy.sh --skip-kill --no-launch > "$EV/redeploy-stage.log" 2>&1; then
  fail "5. redeploy.sh --no-launch failed -- see $EV/redeploy-stage.log"
  test_record_verdict FAILED
  exit 1
fi

OFF_STATE=$(ssh_vm -t 20 "ls -l $GUEST_STREAM_SOCKET 2>/dev/null; pgrep -a rhizo-streamd" 2>/dev/null)
assert_nothing_bound "5a. before the capability is granted" "$OFF_STATE"

HOST_STREAM_POLICY="$EV/policy-stream-on.conf"
printf '[stream]\nenabled = yes\n' > "$HOST_STREAM_POLICY"

# print the unit and socket state
vm_consumer_state() {
  ssh_vm -t 20 "systemctl is-active $1 2>&1; ls -l $GUEST_STREAM_SOCKET 2>&1; ps -o pid,label,cmd -C rhizo-stream-export-verify -C rhizo-streamd 2>/dev/null | tail -n +2" 2>/dev/null
}
# check the unit and socket state
assert_consumer_up() {
  local label="$1" unit="$2" out="$3"
  grep -qx 'active' <<<"$out" || { fail "$label: $unit is not active: $(tr '\n' ' ' <<<"$out")"; return 1; }
  grep -q "^s.* $GUEST_STREAM_SOCKET" <<<"$out" || { fail "$label: no socket at $GUEST_STREAM_SOCKET: $(tr '\n' ' ' <<<"$out")"; return 1; }
  pass "$label: $unit active, $(grep -m1 "$GUEST_STREAM_SOCKET" <<<"$out" | awk '{print $1, $3, $4}') $GUEST_STREAM_SOCKET"
}

ssh_vm -t 20 "install -d -m 0755 /etc/rhizo
: > $POLICY_CONF
echo '[stream]' >> $POLICY_CONF
echo 'enabled = yes' >> $POLICY_CONF
cat $POLICY_CONF" > "$EV/policy.conf" 2>&1
assert_present "5b. $POLICY_CONF grants stream.enabled" \
  "the write produced no readable [stream]/enabled = yes -- see $EV/policy.conf" \
  "$(grep -A1 '\[stream\]' "$EV/policy.conf" | grep 'enabled = yes')"

cp --remove-destination "$STREAM_CLIENT" "$SHARE_DIR/stream-client.py" \
  || fail "5b. could not stage the viewer into $SHARE_DIR"
if ! compgen -G "$SHARE_DIR/stream-debs/vainfo_*.deb" >/dev/null; then
  fail "5c. no vainfo in $SHARE_DIR/stream-debs -- run tools/fetch/pools/deb/fetch.sh stream-debs"
fi
DEBS_OUT=$(ssh_vm -t 180 "dpkg -i /root/share/stream-debs/*.deb > /tmp/stream-debs.log 2>&1; echo dpkg_rc=\$?; tail -5 /tmp/stream-debs.log" 2>&1)
save_evidence stream-debs-install.txt "$DEBS_OUT"
GUEST_VAINFO_BIN=$(ssh_vm -t 15 'command -v vainfo' 2>/dev/null | tr -d '[:space:]')
assert_present "5c. vainfo on the vm" \
  "no vainfo on the vm after installing $SHARE_DIR/stream-debs (evidence: $EV/stream-debs-install.txt)" \
  "$GUEST_VAINFO_BIN"
GUEST_RENDER_NODE=$(ssh_vm -t 15 "bash /root/share/detect-gpu-driver.sh --node 2>/dev/null" 2>/dev/null | cut -d' ' -f1)
GUEST_VAINFO=$(ssh_vm -t 30 "vainfo --display drm --device $GUEST_RENDER_NODE 2>&1" 2>/dev/null)
save_evidence guest-vainfo.txt "$GUEST_VAINFO"

VM_STREAM=0
VM_VERIFY=0
if [[ -z "$GUEST_VAINFO_BIN" ]]; then
  fail "5c. no vainfo to ask this vm with"
elif [[ -z "${GUEST_VAINFO//[[:space:]]/}" ]]; then
  fail "5c. vainfo printed nothing at all on the vm (evidence: $EV/guest-vainfo.txt)"
elif [[ "$(streamd_encoder_state "$GUEST_VAINFO")" == usable\ * ]]; then
  if RHIZO_POLICY_CONF="$HOST_STREAM_POLICY" ../../vm/start/start-stream.sh --port "$GUEST_STREAM_PORT" --socket "$GUEST_STREAM_SOCKET" \
      > "$EV/start-stream.log" 2>&1; then
    DAEMON_STATE=$(vm_consumer_state rhizo-streamd)
    save_evidence vm-daemon-state.txt "$DAEMON_STATE"
    if assert_consumer_up "5c. rhizo-streamd on the vm" rhizo-streamd "$DAEMON_STATE"; then VM_STREAM=1; fi
  else
    fail "5c. start-stream.sh failed on a vm whose vainfo DOES report an encode entrypoint -- see $EV/start-stream.log"
  fi
else
  if [[ "$HOST_ENCODER" == none\ * ]]; then
    ENCODE_PROVEN="no encode is proven in this run, since this host's own GPU offers none either (step 2c)"
  else
    ENCODE_PROVEN="the encode is proven on this host in step 3"
  fi
  skip "5c. the vm's own encode (6a-6e) -- this vm offers no encoder rhizo-streamd can use: $(grep -m1 -E 'libva error|Driver version|error' <<<"$GUEST_VAINFO" | cut -c1-120) (evidence: $EV/guest-vainfo.txt); $ENCODE_PROVEN, and the export below through rhizo-stream-export-verify"
  if RHIZO_POLICY_CONF="$HOST_STREAM_POLICY" ../../vm/start/start-stream.sh --verify-only --socket "$GUEST_STREAM_SOCKET" \
      --report "$GUEST_VERIFY_REPORT" --dump "$GUEST_VERIFY_DUMP" > "$EV/start-stream-verify.log" 2>&1; then
    VERIFIER_STATE=$(vm_consumer_state rhizo-stream-verify)
    save_evidence vm-verifier-state.txt "$VERIFIER_STATE"
    if assert_consumer_up "5c2. rhizo-stream-export-verify on the vm in the daemon's place" \
        rhizo-stream-verify "$VERIFIER_STATE"; then VM_VERIFY=1; fi
  else
    fail "5c2. start-stream.sh --verify-only failed -- see $EV/start-stream-verify.log"
  fi
fi

INIT=""
if ! ../../vm/redeploy.sh --skip-kill > "$EV/redeploy-launch.log" 2>&1; then
  fail "5d. redeploy.sh failed to launch Android -- see $EV/redeploy-launch.log"
else
  INIT=$(resolve_init 300)
  assert_present "5d. the sandbox's init" "no init second_stage after the launch" "$INIT"
fi

if [[ -n "$INIT" ]]; then
  assert_launcher_bind_marker "5e. the launcher's own account" "$(guest_marker 'stream socket dir')"
  COMPOSER_PID=$(resolve_composer 180)
  COMPOSER_ENV=$(ssh_vm -t 20 "[ -n '$COMPOSER_PID' ] && tr '\\0' '\\n' < /proc/$COMPOSER_PID/environ" 2>/dev/null)
  COMPOSER_EXPORT_LOG=""
  for _ in $(seq 1 30); do
    grep -q 'RHIZO_STREAM_SOCKET=' <<<"$COMPOSER_ENV" && break
    COMPOSER_EXPORT_LOG=$(logcat_vm "$INIT" -d -s rhizo-stream-export 2>/dev/null | grep -a 'EnsureConnected')
    [[ -n "$COMPOSER_EXPORT_LOG" ]] && break
    sleep 2
  done
  save_evidence composer-environ.txt "pid=${COMPOSER_PID:-<none>}"$'\n'"$COMPOSER_ENV"$'\n'"$COMPOSER_EXPORT_LOG"
  assert_composer_env "5e. the composer's environment" "$COMPOSER_ENV"$'\n'"$COMPOSER_EXPORT_LOG" "$SANDBOX_SOCKET"
fi

step "6. the frame the composer exported IS its own client target, and the rows"

GEOM=$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from sandbox import capabilities as rc
print(rc.CAPABILITIES["server.display"]["default"].split("@")[0])' "$REPO/src/androidd")

if (( VM_STREAM )) && [[ -n "$INIT" ]]; then
  BOOT_OK=$(guest_boot_completed 300)
  [[ "$BOOT_OK" == 1 ]] || fail "6a. sys.boot_completed never read 1"

  ssh_vm -t 120 'command -v vpxdec >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y vpx-tools >/dev/null 2>&1' >/dev/null 2>&1
  GUEST_VPXDEC=$(ssh_vm -t 15 'command -v vpxdec' 2>/dev/null)
  assert_present "6a. a decoder on the vm" "no vpxdec on the vm to decode the captured stream with" "$GUEST_VPXDEC"

  ssh_vm -t 90 "python3 /root/share/stream-client.py capture --port $GUEST_STREAM_PORT --frames 4 \
      --out /root/share/vm-stream.ivf > /root/share/vm-capture.log 2>&1" >/dev/null 2>&1
  VM_CAP=$(cat "$SHARE_DIR/vm-capture.log" 2>/dev/null)
  save_evidence vm-capture.txt "$VM_CAP"
  assert_stream_hello "6b. the vm's stream" "$VM_CAP" "$GEOM" 4

  rm -f "$SHARE_DIR/vm-stream.i420" "$EV/vm-stream.png"
  ssh_vm -t 10 "rm -f /root/share/vm-stream.i420" >/dev/null 2>&1
  DECODE_RC=$(ssh_vm -t 60 "vpxdec --codec=vp9 --i420 -o /root/share/vm-stream.i420 /root/share/vm-stream.ivf >/root/share/vm-vpxdec.log 2>&1; echo \$?" 2>/dev/null | tr -d '[:space:]')
  save_evidence vm-vpxdec.txt "$(cat "$SHARE_DIR/vm-vpxdec.log" 2>/dev/null)"

  CT_WH=$(fetch_client_target_png "$EV/client-target.png")
  assert_present "6c. the composer's own client-target dump" \
    "the control channel never produced a new dump (evidence: $EV/client-target-log.txt)" "$CT_WH"
  if [[ "$DECODE_RC" != "0" ]]; then
    fail "6c2. the streamed frame against the composer's own client target -- vpxdec exited $DECODE_RC on the guest (evidence: $EV/vm-vpxdec.txt)"
  elif ! python3 "$STREAM_CLIENT" frame-to-png --i420 "$SHARE_DIR/vm-stream.i420" --size "$GEOM" \
      --frame -1 --out "$EV/vm-stream.png" > "$EV/vm-frame-to-png.log" 2>&1; then
    fail "6c2. the streamed frame against the composer's own client target -- frame-to-png exited nonzero: $(tail -3 "$EV/vm-frame-to-png.log")"
  elif [[ -n "$CT_WH" ]]; then
    DIFF_OUT=$(python3 "$PNGSTAT" --diff "$EV/vm-stream.png" "$EV/client-target.png" 2>&1)
    save_evidence frame-diff.txt "$DIFF_OUT"
    assert_frame_matches "6c2. the streamed frame against the composer's own client target" \
      "$DIFF_OUT" "$FRAME_MATCH_MAX_DELTA"
  else
    fail "6c2. the streamed frame against the composer's own client target -- no client-target PNG to compare"
  fi

elif (( VM_VERIFY )) && [[ -n "$INIT" ]]; then
  BOOT_OK=$(guest_boot_completed 300)
  [[ "$BOOT_OK" == 1 ]] || fail "6a. sys.boot_completed never read 1"

  VERIFIER_STATE=$(ensure_verifier_enforcing)
  save_evidence verifier-enforcing.txt "$VERIFIER_STATE"
  assert_consumer_up "6a2. the consumer on the enforcing side of the flip" \
    rhizo-stream-verify "$VERIFIER_STATE"
  assert_consumer_domain "6a3. the consumer's own domain" "$VERIFIER_STATE" u:r:rhizo_host:s0

  android_sh "$INIT" "am start -a android.settings.SETTINGS" >/dev/null 2>&1
  for _ in 1 2 3; do
    android_sh "$INIT" "input swipe 640 640 640 240 300" >/dev/null 2>&1
  done
  VERIFY_REPORT=$(await_verify_frames "$VERIFY_MIN_FRAMES" 90)
  save_evidence stream-verify.tsv "$VERIFY_REPORT"
  assert_verify_report "6b. the real composer's export, received on the vm" "$VERIFY_REPORT" \
    "$VERIFY_MIN_FRAMES" "$GEOM" "$CLIENT_TARGET_FOURCC"
  assert_verify_readback "6b2. the pixels behind the exported dma-buf" "$VERIFY_REPORT" virtgpu

  if ! await_presents_quiet 3 60; then
    fail "6c. the screen never went quiet for 3s in 60s (the report kept growing)"
  fi
  CT_WH=$(fetch_client_target_png "$EV/client-target.png")
  assert_present "6c. the composer's own client-target dump" \
    "the control channel never answered 'dump-client-target done ... xfer=ok' (evidence: $EV/client-target-reply.txt)" "$CT_WH"
  if [[ -n "$CT_WH" ]]; then
    CT_STATS=$(python3 "$PNGSTAT" "$EV/client-target.png" 2>&1)
    save_evidence client-target-stats.txt "$CT_STATS"
    assert_frame_not_blank "6c1. the client target is a picture, not a blank" "$CT_STATS" \
      "$FRAME_NONBLACK_MIN_PCT" "$FRAME_DISTINCT_MIN"
  fi
  VERIFY_REPORT=$(verify_report)
  VERIFY_LAST=$(grep '^RHIZO_STREAM_VERIFY seq=' <<<"$VERIFY_REPORT" | grep -E ' readback=(virtgpu|mmap) ' | tail -1)
  read -r V_W V_H V_STRIDE <<<"$(sed -n 's/.* size=\([0-9]*\)x\([0-9]*\) .* stride=\([0-9]*\) .*/\1 \2 \3/p' <<<"$VERIFY_LAST")"
  rm -f "$EV/stream-verify-frame.png"
  if [[ -z "$V_W" || -z "$V_H" || -z "$V_STRIDE" ]]; then
    fail "6c2. the exported frame against the composer's own client target -- no read-back frame line to take the geometry from"
  elif ! fetch_verify_dump $(( V_STRIDE * V_H )) "$EV/stream-verify-frame.raw"; then
    fail "6c2. the exported frame against the composer's own client target -- SIGUSR1 produced no $(( V_STRIDE * V_H ))-byte dump at $GUEST_VERIFY_DUMP, or it did not come over whole"
  elif ! python3 "$STREAM_CLIENT" raw-to-png --raw "$EV/stream-verify-frame.raw" --size "${V_W}x${V_H}" \
           --stride "$V_STRIDE" --out "$EV/stream-verify-frame.png" > "$EV/verify-raw-to-png.log" 2>&1; then
    fail "6c2. the exported frame against the composer's own client target -- raw-to-png failed: $(tail -3 "$EV/verify-raw-to-png.log" 2>/dev/null)"
  elif [[ -n "$CT_WH" ]]; then
    DIFF_OUT=$(python3 "$PNGSTAT" --diff "$EV/stream-verify-frame.png" "$EV/client-target.png" 2>&1)
    save_evidence frame-diff.txt "$DIFF_OUT"
    assert_frame_matches "6c2. the exported frame against the composer's own client target" \
      "$DIFF_OUT" "$FRAME_MATCH_MAX_DELTA"
  else
    fail "6c2. the exported frame against the composer's own client target -- no client-target PNG to compare"
  fi
  skip "6d-6e. the two vm rows -- no encoder on this vm"
else
  skip "6. the vm's own frame comparison and its two rows -- no consumer is up on this vm"
fi

step "6f. the packaged capability path, live: stream.enabled turns the socket unit on and off"

if [[ -n "$INIT" ]] && (( VM_STREAM || VM_VERIFY )); then
  ssh_vm -t 30 "systemctl stop rhizo-stream-verify rhizo-streamd 2>/dev/null; systemctl disable --now rhizo-streamd.socket 2>/dev/null; systemctl reset-failed rhizo-streamd.socket rhizo-streamd.service 2>/dev/null; true" >/dev/null 2>&1
  PRE_STATE=$(ssh_vm -t 15 "systemctl is-enabled rhizo-streamd.socket 2>&1" 2>/dev/null | head -1 | tr -d '[:space:]')
  save_evidence capability-pre.txt "$PRE_STATE"
  assert_socket_unit_state "6f0. before the grant" "$PRE_STATE" disabled
  ARM_OUT=$(ssh_vm -t 30 "systemctl restart rhizo-stream-capability.path 2>&1; systemctl is-active rhizo-stream-capability.path 2>&1" 2>/dev/null)
  save_evidence capability-watch-armed.txt "$ARM_OUT"
  assert_capability_watch_armed "6f1. the watcher, armed under enforcement" "$ARM_OUT"
  ssh_vm -t 20 "printf '[stream]\nenabled = yes\n' > $POLICY_CONF" >/dev/null 2>&1
  ON_STATE=$(await_socket_unit enabled 30)
  save_evidence capability-on.txt "$ON_STATE"
  assert_socket_unit_state "6f2. stream.enabled granted" "$ON_STATE" enabled
  await_capability_sync_idle 30 || log "  the capability sync did not go idle in 30s; writing the withdrawal anyway"
  ssh_vm -t 20 "printf '[stream]\nenabled = no\n' > $POLICY_CONF" >/dev/null 2>&1
  OFF_STATE=$(await_socket_unit disabled 30)
  save_evidence capability-off.txt "$OFF_STATE"
  assert_socket_unit_state "6f3. stream.enabled withdrawn" "$OFF_STATE" disabled
  OFF_BOUND=$(ssh_vm -t 20 "ls -l $GUEST_STREAM_SOCKET 2>/dev/null; pgrep -a rhizo-streamd" 2>/dev/null)
  save_evidence capability-off-bound.txt "$OFF_BOUND"
  assert_nothing_bound "6f4. after the withdrawal" "$OFF_BOUND"
else
  skip "6f. the packaged capability path -- no consumer ran on this vm"
fi

if (( FAILED )); then
  log "test-stream: FAILED with $FAILED failure(s)"
  test_record_verdict FAILED
  exit 1
fi
log "test-stream: PASSED"
test_record_verdict PASSED
