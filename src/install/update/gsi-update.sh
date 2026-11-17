#!/bin/bash
# Android release update, rollback and abort
set -uo pipefail

PROG=rhizo-gsi-update
log() { echo "[$PROG] $*" >&2; }
# print a refusal reason and exit 1
refuse() { local t="$1"; shift; log "$*"; echo "RHIZO_GSI_UPDATE_REFUSED reason=$t"; exit 1; }
# print a failure reason and exit 1
failstop() { local t="$1"; shift; log "$*"; echo "RHIZO_GSI_UPDATE_FAILED reason=$t"; exit 1; }
# print the usage text
usage() {
  echo "gsi-update.sh update|rollback|abort|status|begin-boot|confirm|kernel-check|adopt [--release R] [--tries N] [--timeout S]"
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR="${RHIZO_STATE_DIR:-/var/lib/rhizo}"
UPDATE_DIR="$STATE_DIR/update"
STATE="$UPDATE_DIR/state"
DATA_IMG="${RHIZO_DATA_IMG:-$STATE_DIR/data.img}"
TRIAL_IMG="$UPDATE_DIR/trial-data.img"
PREVIOUS_IMG="$UPDATE_DIR/previous-data.img"
PREPARE_REQUEST="${RHIZO_PREPARE_REQUEST:-$STATE_DIR/prepare-request}"
GSI_ROOT="${RHIZO_GSI_ROOT:-/srv/rhizo}"
FETCH_SH="${RHIZO_FETCH_GSI:-$HERE/../prepare/fetch-gsi.sh}"
FETCH_APP="${RHIZO_FETCH_APP:-$HERE/../apps/fetch-app.sh}"
GAPPS_ENABLED="$STATE_DIR/gapps/enabled"
AWAIT_PY="${RHIZO_AWAIT_BOOT:-$HERE/../prepare/await-boot-completed.py}"
E2FSCK="${RHIZO_E2FSCK:-e2fsck}"
BOOT_ID_FILE="${RHIZO_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}"
DEFAULT_TRIES=3
OWNED_KEYS='RHIZO_GSI|RHIZO_DATA_IMG|RHIZO_RELEASE|RHIZO_DATA_RELEASE_CHANGE|RHIZO_WIPE_DATA'
RUNTIME_ENV="${RHIZO_RUNTIME_ENV:-/var/lib/rhizo/androidd-runtime.env}"

# print the staged tree path for a release
release_tree() {
  case "$1" in
    a16) echo "$GSI_ROOT/gsi_system" ;;
    a15|a17) echo "$GSI_ROOT/gsi_system_$1" ;;
    *) return 1 ;;
  esac
}
# return whether release_tree returns 0 for the release
release_known() { release_tree "$1" >/dev/null 2>&1; }

KALLSYMS="${RHIZO_KALLSYMS:-/proc/kallsyms}"
declare -A KERNEL_NEEDS=([a17]="bpf_get_current_pid_tgid_vnr bpf_get_netns_cookie_sock_create")

# print why a release lacks kernel support
release_kernel_unsupported() {
  local need="${KERNEL_NEEDS[$1]:-}" have name missing=""
  [[ -n "$need" ]] || return 1
  if ! have=$(awk '{print $3}' "$KALLSYMS" 2>&1) || [[ -z "$have" ]]; then
    printf 'failed to read %s (%s)' "$KALLSYMS" "${have:-empty}"
    return 0
  fi
  for name in $need; do
    grep -qxF "$name" <<<"$have" || missing+=" $name"
  done
  [[ -n "$missing" ]] || return 1
  printf '%s has no%s' "$KALLSYMS" "$missing"
  return 0
}

# return whether the release tree has a non-empty bin/init
tree_staged() { local t; t=$(release_tree "$1") && [[ -s "$t/bin/init" ]]; }

# run fetch-gsi.sh --derive-only for a release
derive_release_libs() {
  "$FETCH_SH" --release "$1" --derive-only >&2
}

# write the launch environment for a release
launch_release() {
  derive_release_libs "$1" \
    || log "fetch-gsi.sh --derive-only failed for $1"
  write_launch_env "$1" ""
}

# return whether Android's policy is loaded host-wide
policy_loaded() {
  local ctx
  ctx=$(tr -d '\0' < "${RHIZO_ATTR_CURRENT:-/proc/self/attr/current}" 2>/dev/null) || return 1
  [[ "$ctx" == u:r:* ]]
}

# print a value from the state file
state_get() {
  [[ -f "$STATE" ]] || return 1
  local v
  v=$(sed -n "s/^$1=//p" "$STATE" | tail -1)
  [[ -n "$v" ]] || return 1
  printf '%s\n' "$v"
}

# write key=value lines to the state file
state_write() {
  mkdir -p "$UPDATE_DIR" || failstop "state-dir" "failed to create $UPDATE_DIR"
  local body="" kv
  for kv in "$@"; do
    [[ "$kv" == *=* ]] || failstop "state-key" "'$kv' is not key=value"
    [[ "${kv#*=}" == *$'\n'* ]] && failstop "state-key" "newline in the value of $kv"
    body+="$kv"$'\n'
  done
  RHIZO_STATE_BODY="$body" python3 -c '
import os, sys
path = sys.argv[1]
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
try:
    os.write(fd, os.environ["RHIZO_STATE_BODY"].encode())
    os.fsync(fd)
finally:
    os.close(fd)
os.rename(tmp, path)
d = os.open(os.path.dirname(path), os.O_RDONLY)
try:
    os.fsync(d)
finally:
    os.close(d)
' "$STATE" || failstop "state-write" "failed to write $STATE"
}

# remove the trial fields from the state file
state_clear_trial() {
  local good prev fields
  good=$(state_get good_release) || failstop "state-missing" "no good_release in $STATE"
  prev=$(state_get previous_release) || prev=""
  fields=("good_release=$good")
  [[ -n "$prev" ]] && fields+=("previous_release=$prev")
  state_write "${fields[@]}"
}

# print the path of the sandbox service's environment file
env_file_path() {
  local f
  f=$(systemctl cat androidd.service 2>/dev/null | sed -n 's/^EnvironmentFile=-\?\(.*\)$/\1/p' | grep -vxF -e /var/lib/rhizo/host-mode-kept.env -e /var/lib/rhizo/androidd-runtime.env | tail -1)
  [[ -n "$f" ]] || return 1
  printf '%s\n' "$f"
}

# merge release keys into the runtime state file
write_launch_env() {
  local rel="$1" img="$2" change="${3:-}" tree
  tree=$(release_tree "$rel") || failstop "unknown-release" "no tree for release $rel"
  mkdir -p "$(dirname "$RUNTIME_ENV")"
  if [[ -f "$RUNTIME_ENV" ]]; then
    grep -Ev "^($OWNED_KEYS)=" "$RUNTIME_ENV" > "$RUNTIME_ENV.rhizo-gsi-update.tmp" || [[ $? -eq 1 ]] \
      || failstop "env-write" "failed to read $RUNTIME_ENV"
  else
    : > "$RUNTIME_ENV.rhizo-gsi-update.tmp"
  fi
  {
    printf 'RHIZO_GSI=%s\n' "$tree"
    printf 'RHIZO_RELEASE=%s\n' "$rel"
    printf 'RHIZO_WIPE_DATA=0\n'
    [[ -n "$img" ]] && printf 'RHIZO_DATA_IMG=%s\n' "$img"
    [[ -n "$change" ]] && printf 'RHIZO_DATA_RELEASE_CHANGE=1\n'
  } >> "$RUNTIME_ENV.rhizo-gsi-update.tmp"
  mv "$RUNTIME_ENV.rhizo-gsi-update.tmp" "$RUNTIME_ENV" \
    || failstop "env-write" "failed to replace $RUNTIME_ENV"
  log "wrote release=$rel tree=$tree data=${img:-$DATA_IMG} to $RUNTIME_ENV"
}

# remove the trial image files
discard_trial_artifacts() {
  rm -f "$TRIAL_IMG" "$TRIAL_IMG.part" "$TRIAL_IMG.meta" "$TRIAL_IMG.meta.tmp"
}

# return whether e2fsck -fn exits with bit 4 or 8 on a trial image
trial_image_corrupt() {
  command -v "$E2FSCK" >/dev/null 2>&1 || { log "no $E2FSCK, $1 unchecked"; return 1; }
  "$E2FSCK" -fn "$1" >/dev/null 2>&1
  (( ($? & 12) != 0 ))
}

# copy the data image to the destination file
copy_data_image() {
  local src="$1" dst="$2"
  [[ -s "$src" ]] || failstop "no-data-img" "$src is missing or empty"
  rm -f "$dst.part"
  cp --sparse=always "$src" "$dst.part" \
    || failstop "data-copy" "failed to copy $src to $dst.part"
  mv "$dst.part" "$dst" || failstop "data-copy" "failed to rename $dst.part to $dst"
}

# write the release to data.img.meta
write_data_meta() {
  local meta="$1.meta" rel="$2" variant template
  variant=$(sed -n 's/^variant=//p' "$meta" 2>/dev/null | tail -1); variant="${variant:-user}"
  template=$(sed -n 's/^template=//p' "$meta" 2>/dev/null | tail -1)
  printf 'release=%s\nvariant=%s\ntemplate=%s\nprovenance=gsi-update\n' \
    "$rel" "$variant" "$template" > "$meta.tmp" \
    || failstop "meta-write" "failed to write $meta.tmp"
  mv "$meta.tmp" "$meta" || failstop "meta-write" "failed to replace $meta"
}

# print the summary line
final_line() {
  local good trial tries prev
  good=$(state_get good_release) || good="-"
  trial=$(state_get trial_release) || trial="-"
  tries=$(state_get trial_tries) || tries="-"
  prev=$(state_get previous_release) || prev="-"
  echo "RHIZO_GSI_UPDATE current=$good candidate=$trial tries=$tries previous=$prev"
}

# return whether androidd.service is active
sandbox_running() {
  [[ "$(systemctl is-active androidd.service 2>/dev/null)" == active ]]
}

# print the current release guess
current_release_guess() {
  local env_file r files=()
  env_file="${RHIZO_ANDROIDD_ENV:-}"
  [[ -n "$env_file" ]] || env_file=$(env_file_path) || env_file=""
  [[ -z "$env_file" || ! -f "$env_file" ]] || files+=("$env_file")
  [[ ! -f "$RUNTIME_ENV" ]] || files+=("$RUNTIME_ENV")
  if (( ${#files[@]} )); then
    r=$(sed -n 's/^RHIZO_RELEASE=//p' "${files[@]}" | tail -1)
    if [[ -n "$r" ]] && release_known "$r"; then
      printf '%s\n' "$r"
      return 0
    fi
  fi
  r=$(sed -n 's/^release=//p' "$DATA_IMG.meta" 2>/dev/null | tail -1)
  printf '%s\n' "${r:-a16}"
}

# fetch the release's LiteGapps payload
fetch_gapps_payload() {
  local rel="$1" out rc line
  [[ -e "$GAPPS_ENABLED" ]] || return 0
  out=$(RHIZO_STATE_DIR="$STATE_DIR" "$FETCH_APP" litegapps --release "$rel"); rc=$?
  line=$(grep '^RHIZO_APP_' <<<"$out" | tail -1)
  [[ $rc -eq 0 && "$line" == RHIZO_APP_FETCHED* ]] && return 0
  [[ "$line" == RHIZO_APP_REFUSED* ]] && refuse "gapps-unavailable" \
    "no LiteGapps payload for $rel with Google's apps enabled ($line)"
  refuse "gapps-fetch-failed" \
    "failed to fetch the LiteGapps payload for $rel (${line:-$FETCH_APP failed with exit status $rc})"
}

# arm a trial of another release
cmd_update() {
  local rel="" tries="$DEFAULT_TRIES"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release) rel="${2:-}"; shift 2 ;;
      --tries) tries="${2:-}"; shift 2 ;;
      *) failstop "usage" "unknown argument '$1'" ;;
    esac
  done
  [[ -n "$rel" ]] || refuse "no-release" "update without --release <a15|a16|a17>"
  release_known "$rel" || refuse "unknown-release" "unknown release $rel"
  local why
  why=$(release_kernel_unsupported "$rel") && refuse "kernel-unsupported" "$why"
  [[ "$tries" =~ ^[1-9][0-9]*$ ]] || refuse "bad-tries" "--tries '$tries' is not a positive integer"
  sandbox_running && refuse "sandbox-running" \
    "androidd.service is active"
  [[ -s "$PREPARE_REQUEST" ]] && refuse "prepare-pending" \
    "a prepare of $(sed -n 's/^release=//p' "$PREPARE_REQUEST" | tail -1) is pending in $PREPARE_REQUEST"
  local armed; armed=$(state_get trial_release) || armed=""
  [[ -n "$armed" ]] && refuse "trial-in-flight" \
    "a trial of $armed is armed"

  local good; good=$(state_get good_release) || good=$(current_release_guess)
  [[ "$rel" == "$good" ]] && refuse "already-current" "$rel is the current release"
  fetch_gapps_payload "$rel"

  local tree; tree=$(release_tree "$rel")
  if ! tree_staged "$rel" && policy_loaded; then
    "$FETCH_SH" --release "$rel" --fetch-only >&2 || failstop "fetch" "fetch-gsi.sh --fetch-only failed for $rel"
    log "rhizo-update-begin.service stages $tree at the next boot"
  else
    "$FETCH_SH" --release "$rel" >&2 || failstop "fetch" "fetch-gsi.sh failed for $rel"
    tree_staged "$rel" || failstop "not-staged" "$tree has no bin/init after fetch-gsi.sh"
  fi

  mkdir -p "$UPDATE_DIR" || failstop "state-dir" "failed to create $UPDATE_DIR"
  rm -f "$PREVIOUS_IMG" "$PREVIOUS_IMG.meta"
  copy_data_image "$DATA_IMG" "$TRIAL_IMG"
  [[ -f "$DATA_IMG.meta" ]] && cp -f "$DATA_IMG.meta" "$TRIAL_IMG.meta"
  write_data_meta "$TRIAL_IMG" "$rel"

  local prev; prev=$(state_get previous_release) || prev=""
  local fields=("good_release=$good" "trial_release=$rel" "trial_tries=$tries"
                "trial_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  [[ -n "$prev" ]] && fields+=("previous_release=$prev")
  state_write "${fields[@]}"
  log "armed $rel with $tries tries, current $good"
  final_line
}

# abort the armed trial and relaunch the good release
cmd_abort() {
  local trial; trial=$(state_get trial_release) || refuse "no-trial" "no trial is armed"
  sandbox_running && refuse "sandbox-running" "androidd.service is active"
  local good; good=$(state_get good_release)
  rm -f "$TRIAL_IMG" "$TRIAL_IMG.part"
  state_clear_trial
  launch_release "$good"
  log "removed the $trial trial, current $good"
  final_line
}

# restore the previous release and PREVIOUS_IMG
cmd_rollback() {
  sandbox_running && refuse "sandbox-running" "androidd.service is active"
  local armed; armed=$(state_get trial_release) || armed=""
  [[ -n "$armed" ]] && refuse "trial-in-flight" \
    "a trial of $armed is armed"
  local prev good
  prev=$(state_get previous_release) || refuse "no-previous" \
    "no previous_release in $STATE"
  good=$(state_get good_release) || failstop "state-missing" "no good_release in $STATE"
  [[ -s "$PREVIOUS_IMG" ]] || refuse "no-previous-data" \
    "no $PREVIOUS_IMG"
  derive_release_libs "$prev" || failstop "gsi-libs" \
    "fetch-gsi.sh --derive-only failed for $prev"
  mv "$PREVIOUS_IMG" "$DATA_IMG" || failstop "data-restore" "failed to move $PREVIOUS_IMG to $DATA_IMG"
  rm -f "$PREVIOUS_IMG.meta"
  write_data_meta "$DATA_IMG" "$prev"
  state_write "good_release=$prev"
  write_launch_env "$prev" ""
  log "rolled back to $prev and $PREVIOUS_IMG"
  final_line
}

# print the update state
cmd_status() {
  if [[ ! -f "$STATE" ]]; then
    log "no $STATE"
    echo "RHIZO_GSI_UPDATE current=$(current_release_guess) candidate=- tries=- previous=-"
    return 0
  fi
  local good trial tries prev started keeps
  good=$(state_get good_release) || good="?"
  trial=$(state_get trial_release) || trial=""
  tries=$(state_get trial_tries) || tries=""
  prev=$(state_get previous_release) || prev=""
  log "current=$good"
  if [[ -n "$trial" ]]; then
    started=$(state_get trial_started) || started="?"
    log "candidate=$trial tries=$tries armed=$started"
    tree_staged "$trial" || log "rhizo-update-begin.service stages the $trial tree at the next boot"
  else
    log "candidate=none"
  fi
  keeps=""; [[ -s "$PREVIOUS_IMG" ]] && keeps=" data=$PREVIOUS_IMG"
  log "previous=${prev:-none}$keeps"
  final_line
}

# write the launch environment for a boot
cmd_begin_boot() {
  if [[ ! -f "$STATE" ]]; then
    log "no $STATE"
    return 0
  fi
  if [[ -s "$PREPARE_REQUEST" ]]; then
    log "a prepare of $(sed -n 's/^release=//p' "$PREPARE_REQUEST" | tail -1) is pending in $PREPARE_REQUEST"
    final_line
    return 0
  fi
  local good trial tries
  good=$(state_get good_release) || failstop "state-missing" "no good_release in $STATE"
  trial=$(state_get trial_release) || trial=""
  if [[ -z "$trial" ]]; then
    launch_release "$good"
    final_line
    return 0
  fi
  tries=$(state_get trial_tries) || tries=0
  local boot
  boot=$(tr -d '[:space:]' < "$BOOT_ID_FILE" 2>/dev/null)
  [[ -n "$boot" ]] || failstop "boot-id" "failed to read $BOOT_ID_FILE"
  if [[ "$(state_get trial_boot || true)" == "$boot" ]]; then
    write_launch_env "$trial" "$TRIAL_IMG" change
    log "RHIZO_MARKER gsi_update_try_this_boot=$trial left=$tries"
    final_line
    return 0
  fi
  if (( tries <= 0 )); then
    log "$trial has no tries left, launching $good"
    rm -f "$TRIAL_IMG" "$TRIAL_IMG.part"
    state_clear_trial
    launch_release "$good"
    log "RHIZO_MARKER gsi_update_rolled_back=$trial-to-$good"
    final_line
    return 0
  fi
  local why
  if why=$(release_kernel_unsupported "$trial"); then
    log "$why, discarding the $trial trial and launching $good"
    discard_trial_artifacts
    state_clear_trial
    launch_release "$good"
    log "RHIZO_MARKER gsi_update_kernel_unsupported=$trial"
    final_line
    return 0
  fi
  if trial_image_corrupt "$TRIAL_IMG"; then
    log "$E2FSCK -fn $TRIAL_IMG failed, discarding the $trial trial and launching $good"
    discard_trial_artifacts
    state_clear_trial
    launch_release "$good"
    log "RHIZO_MARKER gsi_update_trial_corrupt=$trial-to-$good"
    final_line
    return 0
  fi
  if ! tree_staged "$trial"; then
    if policy_loaded; then
      log "the $trial tree is not staged and the policy is loaded, launching $good"
      launch_release "$good"
      log "RHIZO_MARKER gsi_update_stage_waiting=$trial"
      final_line
      return 0
    fi
    if ! "$FETCH_SH" --release "$trial" --offline >&2 || ! tree_staged "$trial"; then
      log "failed to stage the $trial tree, discarding the trial and launching $good"
      discard_trial_artifacts
      state_clear_trial
      launch_release "$good"
      log "RHIZO_MARKER gsi_update_stage_failed=$trial"
      final_line
      return 0
    fi
  fi
  if ! derive_release_libs "$trial"; then
    log "fetch-gsi.sh --derive-only failed for $trial, discarding the trial and launching $good"
    discard_trial_artifacts
    state_clear_trial
    launch_release "$good"
    log "RHIZO_MARKER gsi_update_libs_failed=$trial"
    final_line
    return 0
  fi
  local left=$(( tries - 1 )) prev started fields
  prev=$(state_get previous_release) || prev=""
  started=$(state_get trial_started) || started=""
  fields=("good_release=$good" "trial_release=$trial" "trial_tries=$left" "trial_boot=$boot")
  [[ -n "$started" ]] && fields+=("trial_started=$started")
  [[ -n "$prev" ]] && fields+=("previous_release=$prev")
  state_write "${fields[@]}"
  write_launch_env "$trial" "$TRIAL_IMG" change
  log "RHIZO_MARKER gsi_update_try=$trial left=$left"
  final_line
}

# return whether trial_boot matches the boot_id for trial $1
trial_ran_this_boot() {
  local boot armed
  boot=$(tr -d '[:space:]' < "$BOOT_ID_FILE" 2>/dev/null)
  armed=$(state_get trial_release) || armed=""
  if [[ -n "$boot" && "$armed" == "$1" && "$(state_get trial_boot || true)" == "$boot" ]]; then
    return 0
  fi
  log "trial_boot does not match the boot_id for the $1 trial"
  log "RHIZO_MARKER gsi_update_confirm_not_trial_boot=$1"
  return 1
}

# promote the trial on a completed boot
cmd_confirm() {
  local timeout=900
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="${2:-}"; shift 2 ;;
      *) failstop "usage" "unknown argument '$1'" ;;
    esac
  done
  local trial
  trial=$(state_get trial_release) || { log "no trial_release in $STATE"; return 0; }
  trial_ran_this_boot "$trial" || return 0
  if ! python3 "$AWAIT_PY" --timeout "$timeout"; then
    log "no boot completion marker for $trial within ${timeout}s"
    return 0
  fi
  trial_ran_this_boot "$trial" || return 0
  local good; good=$(state_get good_release) || failstop "state-missing" "no good_release in $STATE"
  mv "$DATA_IMG" "$PREVIOUS_IMG" || failstop "promote-data" "failed to move $DATA_IMG to $PREVIOUS_IMG"
  [[ -f "$DATA_IMG.meta" ]] && mv "$DATA_IMG.meta" "$PREVIOUS_IMG.meta"
  mv "$TRIAL_IMG" "$DATA_IMG" || failstop "promote-data" "failed to move $TRIAL_IMG to $DATA_IMG"
  [[ -f "$TRIAL_IMG.meta" ]] && mv "$TRIAL_IMG.meta" "$DATA_IMG.meta"
  write_data_meta "$DATA_IMG" "$trial"
  state_write "good_release=$trial" "previous_release=$good"
  write_launch_env "$trial" ""
  log "RHIZO_MARKER gsi_update_good=$trial"
  log "current $trial, previous $good"
  final_line
}

# mark a prepared release current
cmd_adopt() {
  local rel="" good armed
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release) rel="${2:-}"; shift 2 ;;
      *) failstop "usage" "unknown argument '$1'" ;;
    esac
  done
  release_known "$rel" || refuse "unknown-release" "unknown release '$rel'"
  armed=$(state_get trial_release) || armed=""
  [[ -n "$armed" ]] && refuse "trial-in-flight" "a trial of $armed is armed"
  good=$(state_get good_release) || good=""
  if [[ -f "$STATE" && "$good" != "$rel" ]]; then
    rm -f "$PREVIOUS_IMG" "$PREVIOUS_IMG.meta"
    discard_trial_artifacts
    state_write "good_release=$rel"
    log "current $rel, removed the ${good:-no release} rollback data"
  fi
  final_line
}

# check the release's kernel support and print the result
cmd_kernel_check() {
  local rel="" why
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --release) rel="${2:-}"; shift 2 ;;
      *) failstop "usage" "unknown argument '$1'" ;;
    esac
  done
  release_known "$rel" || refuse "unknown-release" "unknown release '$rel'"
  why=$(release_kernel_unsupported "$rel") && refuse "kernel-unsupported" "$why"
  echo "RHIZO_GSI_KERNEL_OK release=$rel"
}

[[ "${RHIZO_GSI_UPDATE_SOURCE_ONLY:-0}" == 1 ]] && return 0

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  update)     shift; cmd_update "$@" ;;
  rollback)   shift; cmd_rollback "$@" ;;
  abort)      shift; cmd_abort "$@" ;;
  status)     shift; cmd_status "$@" ;;
  begin-boot) shift; cmd_begin_boot "$@" ;;
  confirm)    shift; cmd_confirm "$@" ;;
  kernel-check) shift; cmd_kernel_check "$@" ;;
  adopt)      shift; cmd_adopt "$@" ;;
  "")         usage; exit 2 ;;
  *)          echo "[$PROG] unknown command '$1'" >&2; exit 2 ;;
esac
