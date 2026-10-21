#!/bin/bash
# test the androidd.env write on --no-launch
# shellcheck disable=SC2034
set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
HERE="$(dirname "$SELF")/../.."
DEPLOY="${RHIZO_CHECK_DEPLOY:-$HERE/../vm/redeploy.sh}"

START_ANCHOR='^LAUNCH_ENV=""$'
END_ANCHOR='^log "Launching boot\.py selinux_setup\.\.\."$'

# print the span between the LAUNCH_ENV anchors
extract_launch_span() {
  awk '
    /^LAUNCH_ENV=""$/ { p=1 }
    p { buf[n++] = $0 }
    /^log "Launching boot\.py selinux_setup\.\.\."$/ { done=1; exit }
    END { if (done) for (i=0; i<n; i++) print buf[i] }
  ' "$1"
}

# run the span and print its ssh_vm arguments
run_span() {
  local f="$1" do_launch="$2" use_unit="$3" span marker
  span=$(extract_launch_span "$f")
  [[ -n "$span" ]] || { echo "NOSPAN"; return; }
  marker=$(mktemp) || { echo "NOSPAN"; return; }
  (
    ssh_vm() { printf '%s\n' "$*" >> "$MARKER_FILE"; return 0; }
    log() { :; }
    launch_env_denied() { return 1; }
    RELEASE=""
    GSI_PATH=""
    DO_LAUNCH="$do_launch"
    RHIZO_USE_UNIT="$use_unit"
    unset RHIZO_SELINUX_MODE
    MARKER_FILE="$marker"
    eval "$span"
  ) >/dev/null 2>&1
  cat "$marker"
  rm -f "$marker"
}

# check --no-launch writes androidd.env
check_no_launch_writes_androidd_env() {
  local f="$1" rc=0 out use_unit
  for use_unit in 0 1; do
    out=$(run_span "$f" 0 "$use_unit")
    if [[ "$out" == NOSPAN ]]; then
      echo "FAIL: could not find the LAUNCH_ENV..androidd.env span in $f (anchors: '$START_ANCHOR' .. '$END_ANCHOR')"
      rc=1
    elif [[ "$out" != *androidd.env* || "$out" != *RHIZO_WIPE_DATA=* ]]; then
      echo "FAIL: $f -- DO_LAUNCH=0 RHIZO_USE_UNIT=$use_unit never writes /root/androidd.env with the built LAUNCH_ENV (RHIZO_WIPE_DATA= included) on it"
      rc=1
    elif [[ "$out" != *"rm -f /var/lib/rhizo/androidd-runtime.env"* ]]; then
      echo "FAIL: $f -- DO_LAUNCH=0 RHIZO_USE_UNIT=$use_unit leaves /var/lib/rhizo/androidd-runtime.env in place"
      rc=1
    elif [[ "$out" != *"echo 'RHIZO_SELINUX_MODE=host' >> /root/androidd.env"* ]]; then
      echo "FAIL: $f -- DO_LAUNCH=0 RHIZO_USE_UNIT=$use_unit writes /root/androidd.env with no RHIZO_SELINUX_MODE=host when the caller sets none"
      rc=1
    fi
  done
  return $rc
}

# print the deploy's guest env file lines
etc_env_lines() {
  grep -E '^[^#]*/etc/rhizo/androidd\.env' "$1" | sed "s#/etc/rhizo/androidd\.env#$2#g"
}

# print guest env file writes nested or after selinuxfs
etc_env_order_problems() {
  awk '
    /^stage_cmd=\047set -e$/ { on = 1 }
    !on { next }
    /systemctl start rhizo-selinuxfs\.service/ && !start { start = NR }
    /^[^#]*\/etc\/rhizo\/androidd\.env/ {
      writes++
      if (start) late = late " " NR
      else if (depth) nested = nested " " NR
    }
    {
      t = $0
      sub(/^stage_cmd\+=\$\047\\n\047[\047"]/, "", t)
      sub(/^[[:space:]]+/, "", t)
      w = t
      sub(/[[:space:];].*$/, "", w)
      sub(/[\047"]+$/, "", w)
      if (w ~ /^(if|case|for|while|until)$/ && t !~ /(^|[;[:space:]])(fi|esac|done)([;[:space:]\047"]|$)/) depth++
      else if (w ~ /^(fi|esac|done)$/) depth--
    }
    END {
      if (!on) { print FILENAME ": no stage_cmd=\047set -e line opens the staging"; exit }
      if (!start) print FILENAME ": the staging never runs systemctl start rhizo-selinuxfs.service"
      if (!writes) print FILENAME ": the staging writes nothing into /etc/rhizo/androidd.env"
      if (late != "") print FILENAME ":" late ": writes /etc/rhizo/androidd.env after line " start " starts rhizo-selinuxfs.service"
      if (nested != "") print FILENAME ":" nested ": writes /etc/rhizo/androidd.env inside an if, case or loop"
    }' "$1"
}

# check the guest env file's mode rewrite
check_etc_env_mode() {
  local f="$1" t lines rc=0 got want before
  t=$(mktemp -d) || return 1
  lines=$(etc_env_lines "$f" "$t/androidd.env")
  if [[ -z "$lines" ]]; then
    echo "FAIL: $f stages nothing into the guest's /etc/rhizo/androidd.env"
    rm -rf "$t"
    return 1
  fi
  if grep -qvE '^(touch|sed|echo|printf) ' <<<"$lines"; then
    echo "FAIL: $f has a /etc/rhizo/androidd.env line this check runs only as touch, sed, echo or printf: $(grep -vE '^(touch|sed|echo|printf) ' <<<"$lines" | head -1)"
    rm -rf "$t"
    return 1
  fi
  for before in absent packaged; do
    rm -f "$t/androidd.env"
    want="RHIZO_SELINUX_MODE=host"
    if [[ "$before" == packaged ]]; then
      printf '# knobs\nRHIZO_SELINUX_MODE=namespace\n#RHIZO_PERMISSIVE=1\nRHIZO_RENDER_NODE=/dev/dri/renderD128\n' > "$t/androidd.env"
      want=$'# knobs\n#RHIZO_PERMISSIVE=1\nRHIZO_RENDER_NODE=/dev/dri/renderD128\nRHIZO_SELINUX_MODE=host'
    fi
    if ! (set -e; eval "$lines") >/dev/null 2>&1; then
      echo "FAIL: $f's /etc/rhizo/androidd.env lines exit nonzero on a $before file: ${lines//$'\n'/; }"
      rc=1
      continue
    fi
    got=$(cat "$t/androidd.env")
    if [[ "$got" != "$want" ]]; then
      echo "FAIL: $f's staging leaves the guest's /etc/rhizo/androidd.env ($before before) as '${got//$'\n'/|}', not '${want//$'\n'/|}'"
      rc=1
    fi
  done
  rm -rf "$t"
  return $rc
}

if [[ "${1:-}" == --selftest ]]; then
  t=$(mktemp -d) || exit 1
  trap 'rm -rf "$t"' EXIT

  cat > "$t/broken.sh" <<'EOF'
LAUNCH_ENV=""
LAUNCH_ENV+="RHIZO_WIPE_DATA=${RHIZO_WIPE_DATA:-0} "
if [[ "$DO_LAUNCH" == 0 ]]; then
  log "Done (--no-launch, not starting the sandbox)"
  exit 0
fi
_androidd_env_cmd() {
  local cmd kv
  cmd=": > /root/androidd.env"
  for kv in $LAUNCH_ENV; do
    cmd+=$'\n'"echo '$kv' >> /root/androidd.env"
  done
  printf '%s' "$cmd"
}
if [[ "${RHIZO_USE_UNIT:-0}" != "1" ]]; then
  ssh_vm -t 30 "$(_androidd_env_cmd)" >/dev/null 2>&1
fi
log "Launching boot.py selinux_setup..."
EOF

  cat > "$t/fixed.sh" <<'EOF'
LAUNCH_ENV=""
LAUNCH_ENV+="RHIZO_WIPE_DATA=${RHIZO_WIPE_DATA:-0} "
LAUNCH_ENV+="RHIZO_SELINUX_MODE=${RHIZO_SELINUX_MODE:-host} "
_androidd_env_cmd() {
  local cmd kv
  cmd=": > /root/androidd.env"
  cmd+=$'\n'"rm -f /var/lib/rhizo/androidd-runtime.env"
  for kv in $LAUNCH_ENV; do
    cmd+=$'\n'"echo '$kv' >> /root/androidd.env"
  done
  printf '%s' "$cmd"
}
if [[ "${RHIZO_USE_UNIT:-0}" != "1" || "$DO_LAUNCH" == 0 ]]; then
  ssh_vm -t 30 "$(_androidd_env_cmd)" >/dev/null 2>&1
fi
if [[ "$DO_LAUNCH" == 0 ]]; then
  log "Done (--no-launch, not starting the sandbox; /root/androidd.env recorded the forwarded RHIZO_* knobs above)"
  exit 0
fi
log "Launching boot.py selinux_setup..."
EOF

  sed '/RHIZO_SELINUX_MODE/d' "$t/fixed.sh" > "$t/no-mode.sh"
  sed '/rm -f \/var\/lib\/rhizo\/androidd-runtime.env/d' "$t/fixed.sh" > "$t/stale-runtime.sh"

  cat > "$t/etc-env-appended.sh" <<'EOF'
install -d -m 0755 /etc/rhizo
echo RHIZO_SELINUX_MODE=host >> /etc/rhizo/androidd.env
EOF

  cat > "$t/etc-env-rewritten.sh" <<'EOF'
install -d -m 0755 /etc/rhizo
touch /etc/rhizo/androidd.env
sed -i "/^RHIZO_SELINUX_MODE=/d" /etc/rhizo/androidd.env
echo RHIZO_SELINUX_MODE=host >> /etc/rhizo/androidd.env
EOF

  cat > "$t/deleted-write-decoy-call.sh" <<'EOF'
LAUNCH_ENV=""
LAUNCH_ENV+="RHIZO_WIPE_DATA=${RHIZO_WIPE_DATA:-0} "
if [[ "$DO_LAUNCH" == 0 ]]; then
  ssh_vm -t 5 "true"
  log "Done (--no-launch, not starting the sandbox)"
  exit 0
fi
log "Launching boot.py selinux_setup..."
EOF

  cat > "$t/no-end-anchor.sh" <<'EOF'
LAUNCH_ENV=""
LAUNCH_ENV+="RHIZO_WIPE_DATA=${RHIZO_WIPE_DATA:-0} "
if [[ "$DO_LAUNCH" == 0 ]]; then
  exit 0
fi
log "Launching boot.py, but the anchor text below does not match..."
rm -rf /this-must-never-run
EOF

  fail=0
  if check_no_launch_writes_androidd_env "$t/broken.sh" >/dev/null; then
    echo "SELFTEST FAILED: the pre-fix ordering (DO_LAUNCH exit before the write) was not flagged" >&2
    fail=1
  fi
  if ! check_no_launch_writes_androidd_env "$t/fixed.sh" >/dev/null; then
    echo "SELFTEST FAILED: the fixed ordering (write reachable before the DO_LAUNCH exit) was flagged as broken:" >&2
    check_no_launch_writes_androidd_env "$t/fixed.sh" >&2
    fail=1
  fi
  if check_no_launch_writes_androidd_env "$t/no-mode.sh" >/dev/null; then
    echo "SELFTEST FAILED: a LAUNCH_ENV with no RHIZO_SELINUX_MODE=host default was not flagged" >&2
    fail=1
  fi
  if check_no_launch_writes_androidd_env "$t/stale-runtime.sh" >/dev/null; then
    echo "SELFTEST FAILED: a deploy that leaves the runtime state file in place was not flagged" >&2
    fail=1
  fi
  if check_etc_env_mode "$t/etc-env-appended.sh" >/dev/null; then
    echo "SELFTEST FAILED: an append that leaves the packaged RHIZO_SELINUX_MODE=namespace line in place was not flagged" >&2
    fail=1
  fi
  if check_etc_env_mode "$t/no-mode.sh" >/dev/null; then
    echo "SELFTEST FAILED: a deploy that never writes /etc/rhizo/androidd.env was not flagged" >&2
    fail=1
  fi
  if ! check_etc_env_mode "$t/etc-env-rewritten.sh" >/dev/null; then
    echo "SELFTEST FAILED: the rewrite to one RHIZO_SELINUX_MODE=host line was flagged:" >&2
    check_etc_env_mode "$t/etc-env-rewritten.sh" >&2
    fail=1
  fi
  if check_no_launch_writes_androidd_env "$t/deleted-write-decoy-call.sh" >/dev/null; then
    echo "SELFTEST FAILED: a deleted write block plus an unrelated ssh_vm call was not flagged (argv content was not actually checked)" >&2
    fail=1
  fi
  span_out=$(extract_launch_span "$t/no-end-anchor.sh")
  if [[ -n "$span_out" ]]; then
    echo "SELFTEST FAILED: a missing END anchor did not fail closed -- extract_launch_span printed a span anyway:" >&2
    printf '%s\n' "$span_out" >&2
    fail=1
  fi
  stage_head="stage_cmd='set -e
install -d -m 0755 /etc/rhizo"
  write_lines='touch /etc/rhizo/androidd.env
sed -i "/^RHIZO_SELINUX_MODE=/d" /etc/rhizo/androidd.env
echo RHIZO_SELINUX_MODE=host >> /etc/rhizo/androidd.env'
  start_line="systemctl start rhizo-selinuxfs.service || exit 1'"
  printf '%s\n%s\n%s\n' "$stage_head" "$write_lines" "$start_line" > "$t/order-good.sh"
  printf '%s\n%s\n%s\n' "$stage_head" "$start_line" "stage_cmd+=\$'\\n''$write_lines'" > "$t/order-late.sh"
  printf '%s\ncase "$RHIZO_GUEST_OS" in\n  cachyos)\n%s\n    ;;\nesac\n%s\n' "$stage_head" "$write_lines" "$start_line" > "$t/order-guest-case.sh"
  printf "%s'\nif [[ \$RHIZO_GUEST_OS == cachyos ]]; then\n  stage_cmd+=\$'\\\\n''%s'\nfi\nstage_cmd+=\$'\\\\n''%s\n" "$stage_head" "$write_lines" "$start_line" > "$t/order-host-if.sh"
  if [[ -n "$(etc_env_order_problems "$t/order-good.sh")" ]]; then
    echo "SELFTEST FAILED: an unconditional write before the selinuxfs start was flagged: $(etc_env_order_problems "$t/order-good.sh")" >&2
    fail=1
  fi
  for fixture in order-late:'starts rhizo-selinuxfs.service' order-guest-case:'inside an if, case or loop' \
                 order-host-if:'inside an if, case or loop'; do
    out=$(etc_env_order_problems "$t/${fixture%%:*}.sh")
    if [[ "$out" != *"${fixture#*:}"* ]]; then
      echo "SELFTEST FAILED: ${fixture%%:*} was not flagged as '${fixture#*:}': ${out:-<nothing>}" >&2
      fail=1
    fi
  done
  if [[ -f "$DEPLOY" ]] && { ! check_no_launch_writes_androidd_env "$DEPLOY" || ! check_etc_env_mode "$DEPLOY" \
      || [[ -n "$(etc_env_order_problems "$DEPLOY")" ]]; } >/dev/null; then
    echo "SELFTEST FAILED: the real $DEPLOY failed the same check the selftest fixtures exercise -- see the real run's own output" >&2
    fail=1
  fi
  if (( fail )); then exit 1; fi
  echo "selftest ok: flags the pre-fix --no-launch ordering under both RHIZO_USE_UNIT values, a LAUNCH_ENV with no host-mode default, a guest env file appended to or never written, written after the selinuxfs start or inside a guest case or host if, a deleted write with a decoy ssh_vm call, and a missing END anchor closed, clears the fixed ordering and the env-file rewrite, and agrees with the real file"
  exit 0
fi

[[ -f "$DEPLOY" ]] || { echo "no $DEPLOY to check" >&2; exit 1; }
rc=0
check_no_launch_writes_androidd_env "$DEPLOY" || rc=1
check_etc_env_mode "$DEPLOY" || rc=1
order=$(etc_env_order_problems "$DEPLOY")
[[ -z "$order" ]] || { printf 'FAIL: %s\n' "$order"; rc=1; }
(( rc == 0 )) && echo "test/vm/redeploy.sh --no-launch always records the forwarded RHIZO_* knobs and RHIZO_SELINUX_MODE=host into /root/androidd.env (both RHIZO_USE_UNIT values), and rewrites the guest's /etc/rhizo/androidd.env to RHIZO_SELINUX_MODE=host, unconditionally and before it starts rhizo-selinuxfs.service"
exit $rc
