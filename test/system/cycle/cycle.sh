#!/bin/bash
# run the lifecycle cycle steps and record each claim
# shellcheck disable=SC2034

# append a row to claims.tsv
_lc_claims_row() {
  [[ -n "${EV:-}" ]] || return 0
  [[ -s "$EV/claims.tsv" ]] || printf 'claim_id\tresult\n' > "$EV/claims.tsv"
  printf '%s\t%s\n' "$1" "$2" >> "$EV/claims.tsv"
}
# append a row to claims-detail.tsv
_lc_claims_detail() {
  [[ -n "${EV:-}" ]] || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$EV/claims-detail.tsv"
}

# run a claim and record its result
claim_assert() {
  skip() { fail "$*"; }
  local id="$1" fn="$2" result note before rc
  shift 2
  if note=$(_lc_resume_blocked "$fn"); then
    log "claim $id: not_run ($note)"
    _lc_claims_row "$id" not_run
    _lc_claims_detail "$id" "${TEST_STEP:-<none>}" "$note"
    return 0
  fi
  local sited
  [[ -n "${LIFECYCLE_PROFILE:-}" ]] && sited=$(_lc_expected_claims "$LIFECYCLE_PROFILE")
  if [[ -n "${LIFECYCLE_PROFILE:-}" ]] && ! grep -qxF "$id" <<<"$sited"; then
    log "claim $id: not asserted -- test/system/cycle/claims.tsv does not site it in $LIFECYCLE_PROFILE"
    return 0
  fi
  note="-"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    fail "claim $id: no such function $fn"
    result=fail
    note="missing function $fn"
  else
    before=$FAILED
    "$fn" "$@"; rc=$?
    if (( rc == 0 && FAILED == before )); then
      pass "claim $id: ok"
      result=pass
    else
      result=fail
      note="rc=$rc failed=$((FAILED - before))"
    fi
  fi
  _lc_claims_row "$id" "$result"
  _lc_claims_detail "$id" "${TEST_STEP:-<none>}" "$note"
}

# record a fenced claim with its reason
claim_fence() {
  local id="$1" reason="$2"
  log "claim $id: fenced ($reason)"
  _lc_claims_row "$id" "fenced"
  _lc_claims_detail "$id" "${TEST_STEP:-<none>}" "$reason"
}

LC_STEP_IDS=(0 1 2 3 4 5 6 7 8 9 9b 10)
declare -gA LC_STEP_STATE=(
  [0]='LC_SWAPFILE_(INODE|UUID)_SEED|snapshot-before\.tsv|LC_SEAT_LOGIN_[A-Z_]+'
  [1]='LC_INSTALL_[A-Z_]+|LC_SWAPFILE_ACTIVE_(BEFORE|AFTER)_INSTALL|cycle-[$][{]?[a-z0-9_]+[}]?-(install|prepare)\.log|lc_snapshot_diff'
  [3]='upgrade-install\.log|LC_UPGRADE_[A-Z_]+|lc_snapshot_diff'
  [4]='LC_INSTANCE_(ADD|ALLOC)_[A-Z_]+'
  [5]='lc_snapshot_diff'
  [6]='LC_GSI_[A-Z_]+'
  [7]='LC_LSM_AFTER_REMOVE_[A-Z_]+|LC_SWAPFILE_(INODE|UUID)_AFTER_REMOVE|[$][{]?[a-z0-9_]+[}]?-remove\.log|snapshot-(after|diff)-remove'
  [8]='lc_snapshot_diff'
  [9]='LC_SWAPFILE_(INODE|UUID)_AFTER_PURGE|[$][{]?[a-z0-9_]+[}]?-(purge|autoremove)\.log|snapshot-(after|diff)-purge'
  [9b]='cli-purge\.log'
)
LC_RESUME_NO_SANDBOX=" 8 9b 10 "
LC_LAST_IDX=$(( ${#LC_STEP_IDS[@]} - 1 ))
LC_FROM_IDX=0 LC_TO_IDX=$LC_LAST_IDX LC_LIVE=0 LC_CUR_STEP="" LC_BODY_TRACE=""
declare -gA LC_STEP_TITLE=()

# print the position of a step id
_lc_step_index() {
  local i
  for i in "${!LC_STEP_IDS[@]}"; do
    [[ "${LC_STEP_IDS[$i]}" == "$1" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

# print the reason for a bad knob value
lifecycle_knob_refusal() {
  local from="${RHIZO_LIFECYCLE_FROM_STEP:-}" to="${RHIZO_LIFECYCLE_TO_STEP:-}" knob
  for knob in RHIZO_LIFECYCLE_FROM_STEP RHIZO_LIFECYCLE_TO_STEP; do
    if [[ -n "${!knob:-}" ]] && ! _lc_step_index "${!knob}" >/dev/null; then
      echo "$knob=${!knob} is not a lifecycle step -- one of: ${LC_STEP_IDS[*]}"
      return 1
    fi
  done
  if [[ -n "$from" && -n "$to" ]] && (( $(_lc_step_index "$from") > $(_lc_step_index "$to") )); then
    echo "RHIZO_LIFECYCLE_FROM_STEP=$from comes after RHIZO_LIFECYCLE_TO_STEP=$to"
    return 1
  fi
  if [[ -n "${RHIZO_LIFECYCLE_KEEP_VM:-}" && "$RHIZO_LIFECYCLE_KEEP_VM" != 1 ]]; then
    echo "RHIZO_LIFECYCLE_KEEP_VM=$RHIZO_LIFECYCLE_KEEP_VM is neither 1 nor unset"
    return 1
  fi
}

# succeed when RHIZO_LIFECYCLE_KEEP_VM is 1
lifecycle_keep_vm() { [[ "${RHIZO_LIFECYCLE_KEEP_VM:-}" == 1 ]]; }

# count the claim rows per result
_lc_claim_counts() {
  awk -F'\t' '$1 != "" && $1 != "claim_id" && $1 !~ /^step\./ {
      t++
      if ($2 == "pass") p++
      else if ($2 == "fail") { f++; ids = ids (ids == "" ? "" : ",") $1 }
      else if ($2 == "not_run") { n++; ids = ids (ids == "" ? "" : ",") $1 }
      else if ($2 == "fenced") x++
    }
    END { printf "%d %d %d %d %d %s\n", t, p, f, n, x, (ids == "" ? "-" : ids) }' "$1"
}

# set the current step and log its title
lc_step() {
  LC_CUR_STEP="$1"
  LC_STEP_TITLE[$1]="$2"
  if [[ "$1" == 0 ]]; then rm -f "${EV:-/nonexistent}/journal-avc.log" "${EV:-/nonexistent}/journal-inputd.log"; else lc_pull_journal; fi
  step "$1: $2"
}

# copy the guest journals into $EV
lc_pull_journal() {
  (( ${LC_LIVE:-0} )) && [[ -n "${EV:-}" ]] || return 0
  local out
  out=$(ssh_vm -t 120 "journalctl --no-pager -o short-iso-precise -g 'avc: +denied|type=140[34]' 2>/dev/null; echo LC_JOURNAL_DONE" 2>/dev/null) || return 0
  [[ "$out" == *LC_JOURNAL_DONE ]] || return 0
  printf '%s\n' "${out%LC_JOURNAL_DONE}" > "$EV/journal-avc.log"
  out=$(ssh_vm -t 120 "journalctl --no-pager -o short-iso-precise -u 'rhizo-inputd@*' -u 'rhizo-inputd-uhid@*' 2>/dev/null; echo LC_JOURNAL_DONE" 2>/dev/null) || return 0
  [[ "$out" == *LC_JOURNAL_DONE ]] || return 0
  printf '%s\n' "${out%LC_JOURNAL_DONE}" > "$EV/journal-inputd.log"
}

# return success for a step outside LC_FROM_IDX..LC_TO_IDX
_lc_step_skipped() {
  local i
  i=$(_lc_step_index "$1") || return 1
  (( i < LC_FROM_IDX || i > LC_TO_IDX ))
}

# print the step range of this run
_lc_range() { printf 'steps %s..%s only' "${LC_STEP_IDS[$LC_FROM_IDX]}" "${LC_STEP_IDS[$LC_TO_IDX]}"; }

# return success for a runnable step body
lc_body() {
  if _lc_step_skipped "$1"; then
    LC_BODY_TRACE+="$1:skip "
    log "step $1: body skipped ($(_lc_range))"
    return 1
  fi
  if (( ! LC_LIVE )); then
    LC_BODY_TRACE+="$1:nolive "
    return 1
  fi
  LC_BODY_TRACE+="$1:run "
}

# print a function and its lc_ callees
_lc_fn_text() {
  local -A seen=()
  local queue=("$1") f body called
  while (( ${#queue[@]} )); do
    f="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${seen[$f]:-}" ]] && continue
    seen[$f]=1
    body=$(declare -f "$f") || continue
    printf '%s\n' "$body"
    for called in $(grep -oE '\b_?lc_[A-Za-z0-9_.-]+' <<<"$body" | sort -u); do
      declare -F "$called" >/dev/null 2>&1 && queue+=("$called")
    done
  done
}

# print the reason for skipping a function
_lc_resume_blocked() {
  (( LC_FROM_IDX > 0 || LC_TO_IDX < LC_LAST_IDX )) || return 1
  local from text i s hit kind id r
  from=$(_lc_range)
  if _lc_step_skipped "$LC_CUR_STEP"; then
    echo "$from: its own step $LC_CUR_STEP was skipped"
    return 0
  fi
  text=$(_lc_fn_text "$1")
  [[ -n "$text" ]] || return 1
  for (( i = 0; i < LC_FROM_IDX; i++ )); do
    s="${LC_STEP_IDS[$i]}"
    hit=$(grep -oE "_lc_step_passed ${s}\.[A-Za-z0-9_.-]+${LC_STEP_STATE[$s]:+|${LC_STEP_STATE[$s]}}" <<<"$text" | head -1)
    if [[ -n "$hit" ]]; then
      echo "$from: reads $hit, which only the skipped step $s records"
      return 0
    fi
  done
  while read -r kind id; do
    [[ -n "$id" ]] || continue
    [[ "$kind" == _lc_step_passed ]] && id="step.$id"
    r=$(awk -F'\t' -v id="$id" 'NR>1 && $1==id{r=$2} END{print r}' "${EV:-}/claims.tsv" 2>/dev/null)
    if [[ "$r" == not_run ]]; then
      echo "$from: reads $id, which this run recorded not_run"
      return 0
    fi
  done < <(grep -oE '_lc_(step|claim)_passed [A-Za-z0-9_.-]+' <<<"$text" | sort -u)
  return 1
}

# log how to resume the kept guest
lifecycle_print_resume() {
  local profile="$1" vm="${RHIZO_VM:-0}" id
  log "RHIZO_LIFECYCLE_KEEP_VM=1: the $profile guest stays up on vm $vm (ssh -p ${SSH_PORT:-?} ${SSH_TARGET:-root@127.0.0.1}), as step ${LC_STEP_IDS[$LC_TO_IDX]} left it"
  log "  resume: RHIZO_VM=$vm RHIZO_LIFECYCLE_KEEP_VM=1 RHIZO_LIFECYCLE_FROM_STEP=<step> [RHIZO_LIFECYCLE_TO_STEP=<step>] test/system/lifecycle/lifecycle-$profile.sh"
  log "  steps (a resume past 2 reuses the fixtures already on the guest):"
  for id in "${LC_STEP_IDS[@]}"; do
    log "    $id: ${LC_STEP_TITLE[$id]:-<not reached>}"
  done
  log "  stop it: RHIZO_VM=$vm bash -c 'source test/vm/common.sh && kill_vm'"
}

# fail the claim for a missing guest
lc_need_guest() {
  declare -F ssh_vm >/dev/null 2>&1 && return 0
  fail "claim $1: no live guest in scope (ssh_vm undefined -- common.sh not sourced)"
  return 1
}

# remove the trailing DONE line from a variable
lc_done_strip() {
  local -n _lc_done_v="$1"
  if [[ "$_lc_done_v" == DONE ]]; then
    _lc_done_v=""
    return 0
  fi
  [[ "$_lc_done_v" == *$'\n'DONE ]] || return 1
  _lc_done_v="${_lc_done_v%$'\n'DONE}"
}

# run the rhizo CLI on the guest
lc_rhizo() {
  local t=90
  [[ "${1:-}" =~ ^[0-9]+$ ]] && { t="$1"; shift; }
  ssh_vm -t "$t" "/usr/bin/rhizo $*"
}
# succeed when the guest reports the unit active
lc_unit_active() { [[ "$(ssh_vm -t 20 "systemctl is-active $1 2>/dev/null" | tr -d '[:space:]')" == active ]]; }
LC_DATA_IMG_QUIESCENT_CMD=$(cat <<'EOF'
img=/var/lib/rhizo/data.img
rimg=$(readlink -m "$img" 2>/dev/null)
[ -n "$rimg" ] || rimg=$img
systemctl stop androidd.service 2>/dev/null
for i in $(seq 1 30); do
  st=$(systemctl is-active androidd.service 2>/dev/null)
  case "$st" in inactive|failed) stopped=1 ;; *) stopped=0 ;; esac
  if lj=$(losetup -j "$img" 2>/dev/null); then
    loops=$(echo $(printf '%s\n' "$lj" | cut -d: -f1))
  else
    loops="unknown(losetup-j-failed)"
  fi
  for b in /sys/block/loop*/loop/backing_file; do
    [ -e "$b" ] || continue
    if ! bf=$(cat "$b" 2>/dev/null); then
      loops="${loops:+$loops }unknown($b-unreadable)"
      continue
    fi
    d=${b#/sys/block/}
    d=/dev/${d%%/*}
    case "$bf" in
      "$img"|"$img (deleted)"|"$rimg"|"$rimg (deleted)") case " $loops " in *" $d "*) ;; *) loops="${loops:+$loops }$d" ;; esac ;;
    esac
  done
  held=""
  for l in $loops; do
    mm=$(cat "/sys/block/${l#/dev/}/dev" 2>/dev/null)
    [ -n "$mm" ] && grep -qs " $mm " /proc/[0-9]*/mountinfo && held="${held:+$held }$l"
  done
  if ! command -v fuser >/dev/null 2>&1; then
    procs="unknown(no-fuser)"
  else
    ferr=$(mktemp)
    procs=$(fuser "$img" 2>"$ferr"); frc=$?
    if [ "$frc" -ne 0 ] && [ -s "$ferr" ]; then
      procs="unknown(fuser-failed:$(head -c 80 "$ferr" | tr -s '[:space:]' ' '))"
    elif [ "$frc" -eq 0 ] && [ -z "$(echo $procs)" ]; then
      procs="unknown(fuser-rc0-named-no-pid)"
    fi
    rm -f "$ferr"
  fi
  [ "$stopped" = 1 ] && [ -z "$loops" ] && [ -z "$procs" ] && break
  sleep 1
done
echo "UNIT ${st:-unknown}"
echo "MOUNTED ${held:-none}"
echo "ATTACHED ${loops:-none}"
echo "OPEN ${procs:-none}"
if [ "$stopped" = 1 ] && [ -z "$loops" ] && [ -z "$procs" ]; then
  sync
  echo "SHA $(sha256sum "$img" 2>/dev/null | cut -d' ' -f1)"
fi
echo DONE
EOF
)
# print the data.img sha from a read
lc_data_img_sha_of() {
  local r="$1" sha
  if [[ "$r" != *$'\n'DONE ]]; then
    echo "the read never finished: $(tr '\n' ' ' <<<"${r:-<empty>}")"
    return 1
  fi
  sha=$(sed -n 's/^SHA //p' <<<"$r")
  if [[ ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    echo "data.img never read quiescent: $(grep -E '^(UNIT|MOUNTED|ATTACHED|OPEN|SHA) ' <<<"$r" | tr '\n' ' ')"
    return 1
  fi
  printf '%s\n' "$sha"
}
LC_VBMETA_ATTACHED_CMD=$(cat <<'EOF'
img=/usr/lib/rhizo/vbmeta.img
loops=""
[ -d /sys/block/ ] && [ -r /sys/block/ ] || loops="unknown(/sys/block/-unlistable)"
for b in /sys/block/loop*/loop/backing_file; do
  [ -e "$b" ] || continue
  d=${b#/sys/block/}
  d=/dev/${d%%/*}
  if ! bf=$(cat "$b" 2>/dev/null); then
    loops="${loops:+$loops }unknown($d-backing_file-unreadable)"
    continue
  fi
  case "$bf" in
    "$img"|"$img (deleted)") loops="${loops:+$loops }$d" ;;
  esac
done
echo "VBMETA_ATTACHED ${loops:-none}"
echo DONE
EOF
)
# check the vbmeta.img loop read
lc_vbmeta_detached_of() {
  local r="$1" a
  if [[ "$r" != *$'\n'DONE ]]; then
    echo "the vbmeta.img loop read never finished: $(tr '\n' ' ' <<<"${r:-<empty>}")"
    return 1
  fi
  a=$(sed -n 's/^VBMETA_ATTACHED //p' <<<"$r")
  [[ "$a" == none ]] && return 0
  echo "a loop still backs /usr/lib/rhizo/vbmeta.img after the remove: ${a:-<no VBMETA_ATTACHED line>}"
  return 1
}
# test for a loop device on vbmeta.img
lc_vbmeta_was_attached() {
  local r="$1" a
  [[ "$r" == *$'\n'DONE ]] || return 1
  a=$(sed -n 's/^VBMETA_ATTACHED //p' <<<"$r")
  [[ " $a " =~ \ /dev/loop[0-9]+\  ]]
}
LC_DESKTOP_USER=""
# print the guest's desktop user
lc_desktop_user() {
  [[ -n "$LC_DESKTOP_USER" ]] && { printf '%s' "$LC_DESKTOP_USER"; return 0; }
  LC_DESKTOP_USER=$(ssh_vm -t 10 'cat /etc/rhizo/desktop-user 2>/dev/null' | tr -d '[:space:]')
  [[ -n "$LC_DESKTOP_USER" ]] || LC_DESKTOP_USER=ubuntu
  printf '%s' "$LC_DESKTOP_USER"
}
# succeed when the guest reports the unit loaded
lc_unit_loaded() { [[ "$(ssh_vm -t 20 "systemctl show -p LoadState --value $1 2>/dev/null" | tr -d '[:space:]')" == loaded ]]; }
# count the /swapfile rows in /proc/swaps
lc_swapfile_active() {
  local out; out=$(ssh_vm -t 20 "awk '\$1 == \"/swapfile\" {n++} END {print n+0}' /proc/swaps; echo DONE")
  lc_done_strip out && printf '%s' "$out"
}
# search a repo file for a substring
grep_doc() {
  local root; root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  grep -qF "$2" "$root/$1" 2>/dev/null
}

# print the Android init pid
lc_resolve_init() { ssh_vm -t "${1:-30}" "$RHIZO_INIT_SCAN_BODY" | head -1 | tr -d '[:space:]'; }

# print a launchable package and activity
lc_resolve_activity() {
  local init="$1" pkgact
  pkgact=$(android_sh "$init" "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.android.settings" \
           | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' | tail -1)
  [[ "$pkgact" == */* ]] || pkgact=$(android_sh "$init" "cmd package query-activities -a android.intent.action.MAIN -c android.intent.category.LAUNCHER" \
             | grep -oE '[a-zA-Z0-9_.]+/[a-zA-Z0-9_.$]+' | head -1)
  printf '%s' "$pkgact"
}

# launch an app and print init pkg act
lc_desktop_fixture_app() {
  local init pkgact
  init=$(lc_resolve_init 60); [[ -n "$init" ]] || return 1
  pkgact=$(lc_resolve_activity "$init"); [[ "$pkgact" == */* ]] || return 1
  ssh_vm -t 60 "/usr/lib/rhizo/tools/rhizo-launch.sh ${pkgact%%/*} ${pkgact##*/}" >/dev/null 2>&1
  printf '%s %s %s' "$init" "${pkgact%%/*}" "${pkgact##*/}"
}

LC_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/desk-user-lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../host/host-census-lib.sh"
export RHIZO_DESK_SESSION=login
source "$(dirname "${BASH_SOURCE[0]}")/claims-install.sh"
source "$(dirname "${BASH_SOURCE[0]}")/claims-desktop.sh"
source "$(dirname "${BASH_SOURCE[0]}")/claims-server.sh"
source "$(dirname "${BASH_SOURCE[0]}")/claims-gsi.sh"

APPS_DIR=/usr/share/applications
ICONS_DIR=/usr/share/icons/hicolor
MIMEAPPS="$APPS_DIR/mimeapps.list"
MIMEINFO="$APPS_DIR/mimeinfo.cache"
INBOX=/run/rhizo/data/rhizo_inbox
SHARE_NAME=Download
CLIP_FIFO=/tmp/rhizo-lifecycle-clip.fifo
NOTIF_FIFO=/tmp/rhizo-lifecycle-notify.fifo
NOTIF_REC=/tmp/rhizo-lifecycle-notif.jsonl
POLICY_CONF=/etc/rhizo/policy.conf
LC_DESKTOP_HUMAN=deskuser
WORKDIR="${TMPDIR:-/tmp}"
DESK_USER="" DESK_HOME="" DESK_RUNTIME_DIR="" BUS_ADDR="" DOWNLOADS=""
INIT="" APP_PKG="" APP_ACT="" DESKAPP_PKG="" DESKAPP_ACT="" BRIDGE_PKG=""
LC_FIXTURE_LABEL="" LC_FIXTURE_SHA="" LC_ENTRY_PATH="" LC_ENTRY_ID=""

LC_INSTALL_BID_BEFORE="" LC_INSTALL_BID_AFTER="" LC_INSTALL_DEB_VERSION=""
LC_INSTALL_BOOTS_BEFORE="" LC_INSTALL_BOOTS_AFTER=""
LC_LSM_AFTER_REMOVE_PRE_REBOOT="" LC_LSM_AFTER_REMOVE_POST_REBOOT=""
LC_SWAPFILE_INODE_SEED="" LC_SWAPFILE_UUID_SEED=""
LC_SWAPFILE_INODE_AFTER_REMOVE="" LC_SWAPFILE_UUID_AFTER_REMOVE=""
LC_SWAPFILE_INODE_AFTER_PURGE="" LC_SWAPFILE_UUID_AFTER_PURGE=""
LC_SWAPFILE_ACTIVE_BEFORE_INSTALL="" LC_SWAPFILE_ACTIVE_AFTER_INSTALL=""
LC_SWAPFILE_FSTAB_LINE='/swapfile                                 none            swap    sw              0       0'
LC_NEW_DEB="" LC_PREV_DEB=""
LC_DEB_NEW_VERSION="" LC_DEB_PREV_VERSION="" LC_DEB_EVIDENCE=""
LC_KERNEL_DEBS=()

LC_GSI_ARM_STATUS="" LC_GSI_CONFIRM_STATUS="" LC_GSI_ROLLBACK_STATUS=""
LC_GSI_ROLLBACK_DATA_RELEASE_OK=""
LC_GSI_EXHAUST_ARM_STATUS="" LC_GSI_EXHAUST_TRIES_STATUS="" LC_GSI_EXHAUST_FINAL_STATUS=""
LC_GSI_AUTOROLLBACK_MARKER_SEEN=""
LC_GSI_REFUSED_STATUS_BEFORE="" LC_GSI_REFUSED_LAST="" LC_GSI_REFUSED_STATUS_AFTER=""
LC_GSI_REFUSED_SHA_MISMATCH=""
LC_GSI_PREPARE_LINE="" LC_GSI_PLANTED_ON=""
LC_GSI_DATA_KEY=rhizo_lifecycle_gsi_data LC_GSI_DATA_TOKEN=""
DESKAPP_LAUNCH_CONFIRM=clip

LC_UPGRADE_CLI_RC="" LC_UPGRADE_CLI_OUT="" LC_UPGRADE_CLI_MARKER="" LC_UPGRADE_CLI_SETUP=""

# run a step function and record its result
step_claim() {
  skip() { fail "$*"; }
  local id="step.$1" fn="$2" result before rc why
  shift 2
  if why=$(_lc_resume_blocked "$fn"); then
    log "$id: not_run ($why)"
    _lc_claims_row "$id" not_run
    _lc_claims_detail "$id" "${TEST_STEP:-<none>}" "$why"
    return 0
  fi
  before=$FAILED
  "$fn" "$@"; rc=$?
  if (( rc == 0 && FAILED == before )); then
    pass "$id: ok"
    result=pass
  else
    result=fail
  fi
  _lc_claims_row "$id" "$result"
  _lc_claims_detail "$id" "${TEST_STEP:-<none>}" "-"
}

# install the desktop-bridge test app
_lc_desktop_install_fixture_apps() {
  _lc_desktop_fixture_identity 2 || return 1
  _lc_desktop_plant_fixture_apps "$VAR_DIR/share/rhizo-deskapp.apk"
}

# set the desktop fixture app globals
_lc_desktop_fixture_identity() {
  local label="$1"
  local app_apk="$VAR_DIR/share/rhizo-deskapp.apk"
  if [[ ! -f "$app_apk" ]]; then
    fail "$label: missing $app_apk -- tools/build/test-apps/deskapp.sh stages it"
    return 1
  fi
  BRIDGE_PKG=com.rhizo.desktop
  APP_PKG=com.rhizo.deskapp
  APP_ACT=com.rhizo.deskapp.MainActivity
  DESKAPP_PKG="$APP_PKG"; DESKAPP_ACT="$APP_ACT"
  LC_FIXTURE_SHA=$(sha256sum "$app_apk" | cut -d' ' -f1)
  local aapt2="${RHIZO_AAPT2:-$VAR_DIR/share/aapt2}"
  if [[ -x "$aapt2" ]]; then
    LC_FIXTURE_LABEL=$("$aapt2" dump badging "$app_apk" | grep '^application-label:' | head -1 | sed "s/^application-label:'//;s/'\$//")
  fi
  [[ -n "$LC_FIXTURE_LABEL" ]] || LC_FIXTURE_LABEL="Rhizo Desk Test"
  LC_ENTRY_PATH="$APPS_DIR/rhizo-$APP_PKG.desktop"
  LC_ENTRY_ID="rhizo-$APP_PKG"
}

# install rhizo-deskapp.apk on the guest
_lc_desktop_plant_fixture_apps() {
  local app_apk="$1"
  android_sh "$INIT" "cmd battery set ac 1" >/dev/null 2>&1
  android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null 2>&1
  android_sh "$INIT" "input keyevent 224" >/dev/null 2>&1

  ssh_vm -t 60 'rm -f /root/rhizo-deskapp.apk' >/dev/null 2>&1
  timeout 60 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$app_apk" "$SSH_TARGET:/root/rhizo-deskapp.apk" \
    || { fail "2: could not stage the desktop-bridge test app to the guest"; return 1; }
  lc_rhizo 90 app install /root/rhizo-deskapp.apk >/dev/null 2>&1 \
    || { fail "2: rhizo app install did not accept rhizo-deskapp.apk"; return 1; }
  local pkglist; pkglist=$(android_sh "$INIT" "pm list packages")
  grep -qx "package:$APP_PKG" <<<"$pkglist" || { fail "2: $APP_PKG missing from pm list packages after install"; return 1; }

}

# wait for rhizo-deskd to authenticate the bridge
_lc_desktop_connect_bridge() {
  local off="${1:-}" why
  if [[ -z "$INIT" ]]; then
    fail "4: no live Android init to require the bridge from"
    return 1
  fi
  if [[ ! "$off" =~ ^[0-9]+$ ]]; then
    fail "4: rhizo-deskd.log's size before step 4's restart read '${off:-<nothing>}', not a byte offset"
    return 1
  fi
  why=$(desk_unit_await_active rhizo-deskd.service 120) \
    || { fail "4: N did not bring rhizo-deskd.service up with the sandbox: $why"; return 1; }
  why=$(desk_token_settled 360) \
    || { fail "4: the product's grants and token delivery (rhizo-desk-token.service) did not succeed: $why"; return 1; }
  why=$(desk_bridge_granted "$INIT" "4") || { fail "$why"; return 1; }
  desk_bridge_await_auth "$off" 60 \
    || { fail "4: rhizo-deskd logged no 'android app authenticated' past byte $off of its log within 60s of the product's token delivery"; return 1; }
}

# restart androidd.service and wait for boot_completed
lc_sandbox_restart() {
  local label="$1" state t0
  ssh_vm -t 120 'systemctl stop androidd.service' >/dev/null 2>&1
  state=$(ssh_vm -t 20 'systemctl is-active androidd.service 2>/dev/null; echo DONE')
  lc_done_strip state \
    || { fail "$label: incomplete read of androidd.service's state after systemctl stop (no DONE token): $state"; return 1; }
  if [[ "$state" != inactive && "$state" != failed ]]; then
    fail "$label: androidd.service reads '${state:-<nothing>}' after systemctl stop, want inactive"
    return 1
  fi
  t0=$(guest_uptime)
  if [[ ! "$t0" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    fail "$label: the guest's uptime before the start read '${t0:-<nothing>}', not a number"
    return 1
  fi
  ssh_vm -t 600 'systemctl start androidd.service' >/dev/null 2>&1
  wait_sandbox_started 420 "$t0" \
    || { fail "$label: the sandbox did not reach boot_completed after uptime $t0"; return 1; }
}

# start the sandbox and set INIT
lc_sandbox_up() {
  local label="$1"
  INIT=""
  lc_sandbox_restart "$label" || return 1
  INIT=$(resolve_init_pid 60)
  [[ -n "$INIT" ]] || { fail "$label: androidd started but no Android init pid resolved"; return 1; }
}

# run rhizo start on the rebooted host
lc_post_reboot_sandbox() {
  local profile="$1" label="$2" out rc
  out=$(lc_rhizo 600 start 2>&1); rc=$?
  if (( rc != 0 )); then
    fail "$label: rhizo start after the reboot exited $rc on $profile: $(tail -3 <<<"$out" | tr '\n' ' ')"
    return 1
  fi
  wait_sandbox_started 420 0
}

# restart the sandbox and connect the bridge
lc_step4_restart() {
  local profile="$1" off=""
  case "$profile" in gnome|sway|plasma) off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log) ;; esac
  step_claim 4.sandbox-up lc_sandbox_up 4
  case "$profile" in gnome|sway|plasma)
    [[ -n "$INIT" ]] && step_claim 4.bridge-connected _lc_desktop_connect_bridge "$off"
  ;; esac
}

# wait for the app entry sync to finish
lc_step4_entries_synced() {
  local bound t0 took
  bound=$(resync_bound)
  if [[ ! "$bound" =~ ^[0-9]+$ ]]; then
    fail "4: rhizo-resync.service declares no RuntimeMaxSec= to bound the entry wait by (read '${bound:-<nothing>}')"
    return 1
  fi
  if [[ -z "${LC_ENTRY_PATH:-}" ]]; then
    fail "4: no fixture entry path resolved to wait for"
    return 1
  fi
  if [[ ! "${INIT:-}" =~ ^[0-9]+$ ]]; then
    fail "4: no Android init pid resolved for the restart (read '${INIT:-<nothing>}')"
    return 1
  fi
  t0=$(date +%s)
  if ! wait_guest_file "$bound" "$LC_ENTRY_PATH"; then
    fail "4: $LC_ENTRY_PATH did not appear within ${bound}s (rhizo-resync.service's RuntimeMaxSec=) of the restart"
    return 1
  fi
  took=$(( $(date +%s) - t0 ))
  log "4: $LC_ENTRY_PATH present ${took}s into the wait"
  await_entry_sync_idle "4: the restart's entry sync" $(( bound > took ? bound - took : 1 )) || return 1
  log "4: the entry sync owes this init nothing, $(( $(date +%s) - t0 ))s into the wait"
}

# check the fixture app paints a window
lc_step10_app_paints() {
  local profile="$1" lrc launched cdisp
  lrc=$(ssh_vm -t 300 "/usr/lib/rhizo/tools/rhizo-launch.sh $APP_PKG $APP_ACT >/tmp/rhizo-lifecycle-launch.log 2>&1; echo rc=\$?" 2>/dev/null | tr -d '\r' | tail -1)
  [[ "$lrc" == rc=0 ]] || { fail "10: rhizo-launch.sh $APP_PKG $APP_ACT reported '${lrc:-<nothing: the ssh call did not complete>}', not rc=0 (the guest's /tmp/rhizo-lifecycle-launch.log has its output)"; return 1; }
  launched=$(ssh_vm -t 60 'tail -40 /run/rhizo-launch/rhizo-launch.log 2>/dev/null')
  cdisp=$(grep -o 'cdisplay=[0-9]*' <<<"$launched" | tail -1 | cut -d= -f2)
  if [[ -z "$cdisp" ]]; then
    fail "10: the launch of $APP_PKG reported no cdisplay= to screenshot"
    return 1
  fi
  local w; w=$(desk_windows 2>/dev/null)
  [[ "$w" == *"rhizo-$APP_PKG"* ]] \
    || fail "10: no desk_windows entry names app_id rhizo-$APP_PKG after launch"
  assert_window_painted "cycle-$profile-final-app" "$cdisp"
}

# set the desktop session globals
_lc_desk_session_globals() {
  local label="$1"
  DESK_USER=$(lc_desktop_user)
  DESK_HOME=$(ssh_vm -t 10 "getent passwd '$DESK_USER' | cut -d: -f6" | tr -d '\r')
  if [[ "$DESK_HOME" != /home/* ]]; then
    fail "$label: the desktop user '$DESK_USER' has home '${DESK_HOME:-<none>}', not a /home directory a desktop session lives in"
    return 1
  fi
  DOWNLOADS="$DESK_HOME/Downloads"
  local desk_env_out
  desk_env_out=$(desk_env 2>/dev/null)
  DESK_RUNTIME_DIR=$(grep -o 'XDG_RUNTIME_DIR=[^[:space:]]*' <<<"$desk_env_out" | cut -d= -f2)
  if [[ -z "$DESK_RUNTIME_DIR" ]]; then
    fail "$label: could not resolve the desktop session's own XDG_RUNTIME_DIR from desk_env"
    return 1
  fi
  if ! _lc_private_bus; then
    fail "$label: could not start a session dbus-daemon for $DESK_USER"
    return 1
  fi
}

# start a session dbus-daemon for DESK_USER
_lc_private_bus() {
  BUS_ADDR=$(ssh_vm -t 25 "runuser -u $DESK_USER -- env XDG_RUNTIME_DIR=$DESK_RUNTIME_DIR dbus-daemon --session --fork --print-address" | tr -d '\r' | head -1)
  [[ "$BUS_ADDR" == unix:* ]] || { BUS_ADDR=""; return 1; }
}

# set the fixture app globals
_lc_server_fixture_identity() {
  local label="$1"
  local aapt2="${RHIZO_AAPT2:-$VAR_DIR/share/aapt2}"
  local fixture_apk="$VAR_DIR/share/rhizo-test-fixture.apk"
  local fixture_meta="$VAR_DIR/share/rhizo-test-fixture.json"
  if [[ ! -x "$aapt2" ]]; then
    fail "$label: no aapt2 at $aapt2 -- build it with tools/build/toolchain/aapt2.sh or set RHIZO_AAPT2"
    return 1
  fi
  if [[ ! -f "$fixture_apk" || ! -f "$fixture_meta" ]]; then
    fail "$label: missing $fixture_apk/$fixture_meta -- fetch the install fixture with tools/fetch/test-apk.sh"
    return 1
  fi
  local meta_sha meta_pkg meta_act got_sha
  meta_sha=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" "$fixture_meta" 2>/dev/null)
  meta_pkg=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['package'])" "$fixture_meta" 2>/dev/null)
  meta_act=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['activity'])" "$fixture_meta" 2>/dev/null)
  got_sha=$(sha256sum "$fixture_apk" | cut -d' ' -f1)
  if [[ -z "$meta_pkg" || -z "$meta_act" || "$meta_sha" != "$got_sha" ]]; then
    fail "$label: fixture metadata unreadable or sha256 mismatch ($got_sha != pinned ${meta_sha:-<none>})"
    return 1
  fi
  APP_PKG="$meta_pkg"; APP_ACT="$meta_act"
  DESKAPP_PKG="$meta_pkg"; DESKAPP_ACT="$meta_act"
  DESKAPP_LAUNCH_CONFIRM=displayed
  LC_FIXTURE_LABEL=$("$aapt2" dump badging "$fixture_apk" | grep '^application-label:' | head -1 | sed "s/^application-label:'//;s/'\$//")
  if [[ -z "$LC_FIXTURE_LABEL" ]]; then
    fail "$label: $aapt2 read no application-label from $fixture_apk"
    return 1
  fi
  LC_FIXTURE_SHA="$meta_sha"
  LC_ENTRY_PATH="$APPS_DIR/rhizo-$APP_PKG.desktop"
  LC_ENTRY_ID="rhizo-$APP_PKG"
}

# read the fixture globals from the guest
lc_resume_resolve() {
  local profile="$1" from="${RHIZO_LIFECYCLE_FROM_STEP:-}" rc=0 pkgs prc
  [[ -n "$TEST_WORKDIR" ]] && WORKDIR="$TEST_WORKDIR"
  case "$profile" in
    gnome|sway|plasma)
      _lc_desktop_fixture_identity resume || rc=1
      _lc_desk_session_globals resume || rc=1
      ;;
    server) _lc_server_fixture_identity resume || rc=1 ;;
  esac
  INIT=$(lc_resolve_init 30)
  if [[ -z "$INIT" ]]; then
    if [[ "$LC_RESUME_NO_SANDBOX" == *" $from "* ]]; then
      log "resume: no sandbox running on entry to step $from, as expected"
    else
      fail "resume: no Android init on the running guest -- step $from expects the sandbox up (resume from step 2 to start it)"
      rc=1
    fi
    return $rc
  fi
  pkgs=$(android_sh "$INIT" "pm list packages"); prc=$?
  if (( prc != 0 )) || [[ -z "$pkgs" ]]; then
    fail "resume: pm list packages on init $INIT read nothing (android_sh rc=$prc)"
    return 1
  fi
  grep -qx "package:$APP_PKG" <<<"$pkgs" \
    || { fail "resume: fixture $APP_PKG is not installed on this guest -- step 2 plants it (resume from step 2)"; rc=1; }
  if [[ -n "$BRIDGE_PKG" ]] && (( LC_FROM_IDX > $(_lc_step_index 4) )) && ! grep -qx "package:$BRIDGE_PKG" <<<"$pkgs"; then
    fail "resume: $BRIDGE_PKG is not on this guest"
    rc=1
  fi
  (( rc == 0 )) && pass "resume: globals re-read from the guest (init=$INIT app=$APP_PKG user=${DESK_USER:-<none>})"
  return $rc
}

# install the fixture app for the profile
lc_setup_fixtures() {
  local profile="$1"
  [[ -n "$TEST_WORKDIR" ]] && WORKDIR="$TEST_WORKDIR"

  case "$profile" in
    gnome|sway|plasma)
      _lc_desk_session_globals 2 || return 1
      desk_user_sh 15 "mkdir -p '$DOWNLOADS'" \
        || { fail "2: could not create $DOWNLOADS as $DESK_USER"; return 1; }
      _lc_desktop_install_fixture_apps
      ;;
    server)
      _lc_server_fixture_identity 2 || return 1
      ssh_vm -t 60 'rm -f /root/rhizo-lifecycle-fixture.apk' >/dev/null 2>&1
      timeout 120 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$VAR_DIR/share/rhizo-test-fixture.apk" "$SSH_TARGET:/root/rhizo-lifecycle-fixture.apk" \
        || { fail "2: could not stage the fixture APK to the guest"; return 1; }
      lc_rhizo 120 app install /root/rhizo-lifecycle-fixture.apk >/dev/null 2>&1 \
        || fail "2: rhizo app install did not accept the fixture APK"
      ;;
  esac
}

# write the debug Environment= drop-ins
installer_pre_reboot_hook() {
  local leg="$1" pair body=""
  [[ -n "${RHIZO_LIFECYCLE_GUEST_ENV:-}" ]] || return 0
  for pair in $RHIZO_LIFECYCLE_GUEST_ENV; do
    [[ "$pair" =~ ^RHIZO_[A-Z0-9_]+=[A-Za-z0-9_.:/-]+$ ]] \
      || { fail "[$leg] RHIZO_LIFECYCLE_GUEST_ENV entry '$pair' is not RHIZO_NAME=value"; return 1; }
    body+="Environment=$pair"$'\n'
  done
  local unit out load env loaded="" absent=""
  for unit in rhizo-policy.service androidd.service; do
    out=$(ssh_vm -t 20 "mkdir -p /etc/systemd/system/$unit.d && printf '[Service]\n%s' '$body' > /etc/systemd/system/$unit.d/90-lifecycle-debug.conf && systemctl daemon-reload && systemctl show -p LoadState -p Environment $unit")
    load=$(sed -n 's/^LoadState=//p' <<<"$out" | head -1)
    env=$(sed -n 's/^Environment=//p' <<<"$out" | head -1)
    case "$load" in
      loaded)
        for pair in $RHIZO_LIFECYCLE_GUEST_ENV; do
          [[ " $env " == *" $pair "* ]] \
            || { fail "[$leg] $unit is loaded but does not carry $pair after its debug drop-in (got: Environment=$env)"; return 1; }
        done
        loaded+=" $unit"
        ;;
      not-found) absent+=" $unit" ;;
      *) fail "[$leg] $unit reads LoadState='${load}' after its debug drop-in, want loaded or not-found (got: ${out:-nothing})"; return 1 ;;
    esac
  done
  [[ -n "$loaded" ]] \
    || { fail "[$leg] no unit the debug drop-ins target is installed (not-found:$absent)"; return 1; }
  [[ -z "$absent" ]] \
    || note "[$leg] not installed yet, drop-in left in place for the upgrade:$absent"
  note "[$leg] debug drop-ins written before the install reboot, carried by$loaded: $RHIZO_LIFECYCLE_GUEST_ENV"
}

# check an app starts on the new kernel
lc_step5_app_check() {
  local profile="$1" leg="$2" out
  if [[ "$profile" != server ]]; then
    ssh_vm -t 120 'systemctl stop androidd.service' >/dev/null 2>&1
    installer_assert_app_paints "$leg"
    return
  fi
  lc_sandbox_up "[$leg]" || return 1
  out=$(android_sh "$INIT" "am start -W -n $APP_PKG/$APP_ACT" 2>&1)
  grep -q '^Status: ok' <<<"$out" \
    || { fail "[$leg] am start -W $APP_PKG/$APP_ACT on the new kernel did not report Status: ok: $(tr '\n' ' ' <<<"$out" | head -c 300)"; return 1; }
  pass "[$leg] $APP_PKG/$APP_ACT starts on a new boot on the new kernel"
}

LC_SERVER_APP_SETTLE_S=5
# install and launch the fixture app
lc_server_app_launches() {
  local label="$1" apk=/root/rhizo-lifecycle-fixture.apk out short lcat="" disp="" crash="" crash_re deadline settle
  if [[ -z "$APP_PKG" || -z "$APP_ACT" ]]; then
    fail "[$label] no server fixture package/activity from step 2 to launch"
    return 1
  fi
  lc_sandbox_up "[$label]" || return 1
  timeout 120 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$VAR_DIR/share/rhizo-test-fixture.apk" "$SSH_TARGET:$apk" \
    || { fail "[$label] could not stage the fixture APK to the guest"; return 1; }
  out=$(lc_rhizo 180 app install "$apk" 2>&1)
  if ! grep -q "^RHIZO_APP installed=$APP_PKG " <<<"$out"; then
    fail "[$label] rhizo app install did not report RHIZO_APP installed=$APP_PKG: $(tail -3 <<<"$out" | tr '\n' ' ')"
    return 1
  fi
  android_sh "$INIT" "logcat -c" >/dev/null 2>&1
  out=$(android_sh "$INIT" "am start -W -n $APP_PKG/$APP_ACT" 2>&1)
  printf '%s\n' "${out:-<none>}" > "$EV/$label-amstart.log"
  short="$APP_ACT"
  [[ "$APP_ACT" == "$APP_PKG".* ]] && short=".${APP_ACT#"$APP_PKG".}"
  deadline=$((SECONDS + 30))
  while (( SECONDS < deadline )); do
    lcat=$(android_sh "$INIT" "logcat -d -v threadtime" 2>/dev/null)
    disp=$(grep -m1 -F "ActivityTaskManager: Displayed $APP_PKG/$short" <<<"$lcat")
    [[ -n "$disp" ]] && break
    sleep 2
  done
  crash_re="AndroidRuntime: Process: $APP_PKG,|ActivityManager: Process $APP_PKG \\(pid [0-9]+\\) has died|ActivityManager: ANR in $APP_PKG( |$)"
  crash=$(grep -E "$crash_re" <<<"$lcat" | head -3)
  if [[ -n "$disp" && -z "$crash" ]]; then
    settle=$((SECONDS + LC_SERVER_APP_SETTLE_S))
    while :; do
      if [[ -z "$(android_sh "$INIT" "pidof $APP_PKG" 2>/dev/null | tr -d '[:space:]')" ]]; then
        crash="no $APP_PKG process is alive after its launch, $((SECONDS - settle + LC_SERVER_APP_SETTLE_S))s after its first frame"
        break
      fi
      (( SECONDS < settle )) || break
      sleep 1
      lcat=$(android_sh "$INIT" "logcat -d -v threadtime" 2>/dev/null)
      crash=$(grep -E "$crash_re" <<<"$lcat" | head -3)
      [[ -n "$crash" ]] && break
    done
  elif [[ -z "$crash" && -z "$(android_sh "$INIT" "pidof $APP_PKG" 2>/dev/null | tr -d '[:space:]')" ]]; then
    crash="no $APP_PKG process is alive after its launch"
  fi
  printf '%s\n' "${lcat:-<none>}" > "$EV/$label-logcat-since-launch.log"
  if ! grep -q '^Status: ok' <<<"$out"; then
    fail "[$label] am start -W $APP_PKG/$APP_ACT did not report Status: ok: $(tr '\n' ' ' <<<"$out" | head -c 300) (see $EV/$label-amstart.log)"
    return 1
  fi
  if [[ -z "$disp" ]]; then
    fail "[$label] $APP_PKG's launch never logged 'ActivityTaskManager: Displayed $APP_PKG/$short' within 30s (see $EV/$label-logcat-since-launch.log)"
    return 1
  fi
  if [[ -n "$crash" ]]; then
    fail "[$label] $APP_PKG crashed after its launch: $(tr '\n' ' ' <<<"$crash")"
    return 1
  fi
  pass "[$label] $APP_PKG, installed again after purge, launched headless on a new boot: Status: ok, ${disp#*ActivityTaskManager: }, and alive with no crash or ANR ${LC_SERVER_APP_SETTLE_S}s on"
}

LC_PKGWIN_TAG="$HOST_CENSUS_PKGWIN_TAG"
# run a command under host_census_pkgwin
lc_pkgwin() {
  local kind="$1"
  (( LC_LIVE )) || { shift 2; "$@"; return; }
  host_census_pkgwin "$EV/${profile:?}-pkgwin-$kind.log" "$@"
}

# wait for boot and the dpkg lock
lc_host_settle() {
  local out state jobs
  out=$(ssh_vm -t 330 'timeout 300 systemctl is-system-running --wait 2>/dev/null; echo "RC=$?"' | tr -d '\r')
  state=$(grep -v '^RC=' <<<"$out" | tail -1)
  if [[ "$state" != running && "$state" != degraded ]]; then
    jobs=$(ssh_vm -t 20 'systemctl list-jobs --no-pager 2>&1 | head -20' | tr -d '\r' | tr '\n' ' ')
    echo "$1: systemctl is-system-running --wait read '${state:-<nothing>}' ($(grep '^RC=' <<<"$out")) within 300s, still queued: ${jobs% }"
    return 1
  fi
  if ! wait_dpkg_free "$1" >/dev/null 2>&1; then
    echo "$1: the dpkg lock was still held 300s after the boot finished ($(ssh_vm -t 30 'fuser -v /var/lib/dpkg/lock-frontend 2>&1 | tail -2' | tr -d '\r' | tr '\n' ' ' | sed 's/ $//'))"
    return 1
  fi
}

# diff the host census snapshot
lc_snapshot_diff() { host_census_snapshot_diff "$1" "$2" cycle; }

# record the apt kept packages
lc_apt_kept_record() { host_census_apt_kept_record "$1" 9; }
LC_APTKEPT_TAG="$HOST_CENSUS_APTKEPT_TAG"

# resolve a deb file from a glob
lc_one_deb() {
  local var="$1" role="$2" glob="$3" vvar="${4:-}" m=() names="<none>" ver sha
  mapfile -t m < <(compgen -G "$glob")
  if (( ${#m[@]} != 1 )); then
    (( ${#m[@]} )) && names=$(printf '%s ' "${m[@]##*/}")
    fail "debs: $role wants exactly one ${glob##*/} in ${glob%/*}, found ${#m[@]}: $names"
    return 1
  fi
  ver=$(dpkg-deb -f "${m[0]}" Version 2>/dev/null)
  [[ -n "$ver" ]] || { fail "debs: could not read the Version field of ${m[0]##*/}"; return 1; }
  sha=$(sha256sum "${m[0]}" | cut -d' ' -f1)
  printf -v "$var" '%s' "${m[0]}"
  [[ -z "$vvar" ]] || printf -v "$vvar" '%s' "$ver"
  LC_DEB_EVIDENCE+="deb $role=${m[0]##*/} version=$ver sha256=$sha"$'\n'
}

# check the deb matches its build stamp
_lc_deb_require() { python3 "$LC_TOOLS_DIR/../../../tools/build/stamps.py" deb-require "$1" 2>&1; }

# resolve the new rhizo and Rhizo kernel debs
lc_resolve_new_debs() {
  local dir="${RHIZO_DEB_DIR:-$VAR_DIR/debs}" why rc=0 kdir kdebs k kver
  lc_one_deb LC_NEW_DEB new "$dir/rhizo_*_amd64.deb" LC_DEB_NEW_VERSION || rc=1
  (( rc == 0 )) || return 1
  why=$(_lc_deb_require "$LC_NEW_DEB") \
    || { fail "debs: ${LC_NEW_DEB##*/} is not this tree's build (${why#stamps: }) -- rebuild it with tools/build/packaging/deb/debs.sh"; return 1; }
  LC_KERNEL_DEBS=()
  if ! lc_on_cachyos; then
    kdir="${RHIZO_KERNEL_DEB_DIR:-$dir}"
    if ! kdebs=$(deb_pool_kernel_debs "$LC_NEW_DEB" "$kdir"); then
      fail "debs: ${LC_NEW_DEB##*/} depends on a Rhizo kernel .deb $kdir lacks (see above) -- copy there the four Rhizo kernel .debs; tools/fetch/pools/deb/runtime-debs.sh --kernel-debs names the ones missing"
      return 1
    fi
    for k in $kdebs; do
      kver=$(dpkg-deb -f "$k" Version) && [[ -n "$kver" ]] \
        || { fail "debs: could not read the Version field of ${k##*/}"; return 1; }
      LC_KERNEL_DEBS+=("$k")
      LC_DEB_EVIDENCE+="deb kernel=${k##*/} version=$kver sha256=$(sha256sum "$k" | cut -d' ' -f1)"$'\n'
    done
  fi
  pass "debs: N is ${LC_NEW_DEB##*/} ($LC_DEB_NEW_VERSION, this tree's build)${LC_KERNEL_DEBS[*]:+ with the ${#LC_KERNEL_DEBS[@]} Rhizo kernel .debs it depends on}"
}

# test for a cachyos guest
lc_on_cachyos() { [[ "${RHIZO_GUEST_OS:-ubuntu}" == cachyos ]]; }

LC_PURGE_RHIZO_KERNEL_UBUNTU='k=
q=$(dpkg-query -W -f "\${db:Status-Abbrev} \${Package}\n" "linux-image-*rhizo" "linux-headers-*rhizo" 2>&1); r=$?
if [ "$r" -gt 1 ]; then echo "KERNEL_QUERY_RC=$r $q"; exit 0; fi
while IFS= read -r line; do
  case "${line:0:3}" in
    "ii ") k="$k ${line:4}" ;;
  esac
done <<<"$q"
echo "KERNEL_PKGS=$k"
if [ -n "$k" ]; then DEBIAN_FRONTEND=noninteractive apt-get purge -y $k 2>&1; echo "KERNEL_RC=$?"; fi'
# purge the Rhizo kernel packages by name
lc_purge_rhizo_kernel() {
  local profile="$1" log="$EV/$1-purge-kernel.log" out pkgs rc
  if lc_on_cachyos; then installer_cachyos_remove_rhizo_kernel "cycle-$profile" "$log"; return; fi
  out=$(ssh_vm -t 900 "$LC_PURGE_RHIZO_KERNEL_UBUNTU")
  printf '%s\n' "${out:-<no answer over ssh>}" > "$log"
  if ! grep -q '^KERNEL_PKGS=' <<<"$out"; then
    fail "9: could not list the installed Rhizo kernel packages: $(head -3 <<<"${out:-<no answer over ssh>}" | tr '\n' ' ')(see $log)"
    return 1
  fi
  pkgs=$(sed -n 's/^KERNEL_PKGS= *//p' <<<"$out")
  rc=$(sed -n 's/^KERNEL_RC=//p' <<<"$out" | tail -1)
  if [[ -z "${pkgs// /}" ]]; then
    (( ${#LC_KERNEL_DEBS[@]} == 0 )) \
      || { fail "9: N depends on the Rhizo kernel, and no Rhizo kernel package was installed to purge (see $log)"; return 1; }
    pass "9: no Rhizo kernel package was installed"
  elif [[ "$rc" == 0 ]]; then
    pass "9: the Rhizo kernel packages were removed by name: ${pkgs% }"
  else
    fail "9: removing the Rhizo kernel packages (${pkgs% }) exited ${rc:-<no status recorded>} (see $log)"
    return 1
  fi
}

# succeed when any of steps 3, 8, 9b and 10 is not skipped
_lc_range_needs_n() {
  local s
  for s in 3 8 9b 10; do _lc_step_skipped "$s" || return 0; done
  return 1
}

# check the offline apt configuration exists
lc_apt_conf_present() {
  local got
  got=$(ssh_vm -t 15 "if [ -s '$TEST_APT_OFFLINE_CONF' ]; then echo CONF_OK; else echo CONF_MISSING; fi" | tr -d '[:space:]')
  [[ "$got" == CONF_OK ]] \
    || { fail "$1: the offline apt configuration $TEST_APT_OFFLINE_CONF is not on the guest (read '${got:-<nothing>}')"; return 1; }
}

# upgrade rhizo from N-1 with apt-get
lc_step3_upgrade() {
  local profile="$1" deb="$2" want before after apt_rc
  local log="$EV/${profile}-upgrade-install.log"
  want=$(dpkg-deb -f "$deb" Version 2>/dev/null)
  [[ -n "$want" ]] || { fail "3: could not read the Version field of $deb"; return 1; }
  before=$(ssh_vm -t 15 "dpkg-query -W -f='\${Version}\n' rhizo 2>/dev/null; echo DONE")
  lc_done_strip before || { fail "3: incomplete read of dpkg's rhizo version before the upgrade (no DONE token): $before"; return 1; }
  if [[ -z "$before" ]] || ! dpkg --compare-versions "$before" lt "$want" 2>/dev/null; then
    fail "3: dpkg reports rhizo '${before:-<not installed>}' before the upgrade, want an N-1 older than $want"
    return 1
  fi
  installer_transfer_artifact "cycle-$profile-upgrade" "$deb" "${LC_KERNEL_DEBS[@]}" || return 1
  local marks_before marks_after
  marks_before=$(installer_start_marks)
  lc_pkgwin rhizo-install step3-upgrade \
    ssh_vm -t 1800 '[ -s '"$TEST_APT_OFFLINE_CONF"' ] || { echo APT_RC=NOCONF; exit; }; cd /root/rhizo-artifact && k=; for f in ./linux-image-*rhizo_*.deb ./linux-headers-*rhizo_*.deb; do [ -e "$f" ] && k="$k $f"; done
      APT_CONFIG='"$TEST_APT_OFFLINE_CONF"' DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold $k ./rhizo_*.deb 2>&1; echo "APT_RC=$?"' \
    > "$log" 2>&1
  marks_after=$(installer_start_marks)
  printf '%s\n=== after\n%s\n' "$marks_before" "$marks_after" > "$EV/${profile}-upgrade-start-marks.txt"
  apt_rc=$(sed -n 's/^APT_RC=//p' "$log" | tail -1)
  if [[ "$apt_rc" == NOCONF ]]; then
    fail "3: the offline apt configuration $TEST_APT_OFFLINE_CONF is missing or empty on the guest (see $log)"
    return 1
  fi
  if [[ "$apt_rc" != 0 ]]; then
    fail "3: apt-get install of rhizo $want over $before exited APT_RC=${apt_rc:-<none recorded>}: $(grep -aE '^E: ' "$log" | head -2 | tr '\n' ' ')(see $log)"
    return 1
  fi
  installer_assert_offline_apt "cycle-$profile-upgrade" "$log" "the N-1 -> N upgrade install" || return 1
  after=$(ssh_vm -t 15 "dpkg-query -W -f='\${Version}\n' rhizo 2>/dev/null; echo DONE")
  lc_done_strip after || { fail "3: incomplete read of dpkg's rhizo version after the upgrade (no DONE token): $after"; return 1; }
  [[ "$after" == "$want" ]] \
    || { fail "3: apt-get install exited 0 but dpkg reports rhizo '${after:-<not installed>}', want $want"; return 1; }
  installer_assert_started_nothing "cycle-$profile-upgrade" "3: the N-1 -> N upgrade" "$marks_before" "$marks_after" \
    || return 1
  pass "3: dpkg moved rhizo $before -> $after"
}

# run rhizo upgrade and record its output
lc_step3_cli_upgrade() {
  LC_UPGRADE_CLI_MARKER=$(ssh_vm -t 15 'printf "kernel=%s\nversion=lifecycle-planted\n" "$(uname -r)" > /var/lib/rhizo/.prepared && echo planted')
  [[ "$LC_UPGRADE_CLI_MARKER" == planted ]] || { LC_UPGRADE_CLI_MARKER="plant failed: $LC_UPGRADE_CLI_MARKER"; return 0; }
  LC_UPGRADE_CLI_OUT=$(lc_rhizo 600 upgrade 2>&1); LC_UPGRADE_CLI_RC=$?
  LC_UPGRADE_CLI_MARKER=$(ssh_vm -t 15 'if [ -e /var/lib/rhizo/.prepared ]; then echo present; else echo absent; fi')
  LC_UPGRADE_CLI_SETUP=$(lc_rhizo 60 status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("setup"))' 2>&1)
}

# reboot and check the finished upgrade
lc_step3_finish_upgrade() {
  local profile="$1" deb="$2" want enforce id_before id_after n0 prep="" waited=0 cond marker ver pkgs
  local log="$EV/${profile}-upgrade-install.log" plog="$EV/${profile}-upgrade-prepare.log"
  _lc_step_passed 3.version-moved \
    || { fail "3: the apt upgrade to N did not land"; return 1; }
  want=$(dpkg-deb -f "$deb" Version 2>/dev/null)
  [[ -n "$want" ]] || { fail "3: could not read the Version field of $deb"; return 1; }
  enforce=$(ssh_vm -t 15 'e=$(cat /sys/fs/selinux/enforce); echo "$e"; echo DONE')
  lc_done_strip enforce || { fail "3: incomplete read of /sys/fs/selinux/enforce (no DONE token): $enforce"; return 1; }
  [[ "$enforce" == 1 ]] \
    || { fail "3: enforce reads '$enforce' after step 2's sandbox, not 1"; return 1; }
  grep -qF '[rhizo] reboot to finish the upgrade' "$log" && grep -qF '[rhizo] the sandbox already ran on this boot' "$log" \
    || { fail "3: the upgrade on a host whose sandbox ran and stopped this boot never printed '[rhizo] reboot to finish the upgrade' with its ran-this-boot reason (see $log)"; return 1; }
  id_before=$(ssh_vm -t 15 "stat -c 'ino=%i crtime=%W' /var/lib/rhizo/data.img; echo DONE")
  lc_done_strip id_before && [[ "$id_before" == ino=* ]] \
    || { fail "3: could not read data.img's identity before the reboot: $id_before"; return 1; }
  n0=$(ssh_vm -t 15 'wc -l < /var/log/rhizo/prepare.log; echo DONE')
  lc_done_strip n0 && [[ "$n0" =~ ^[0-9]+$ ]] \
    || { fail "3: could not count prepare.log's lines before the reboot: $n0"; return 1; }

  reboot_and_wait "cycle-$profile upgrade" || { fail "3: the reboot that finishes the upgrade did not come back"; return 1; }
  installer_assert_rhizo_kernel "cycle-$profile" "the reboot that finishes the upgrade" || return 1
  while (( waited < 2100 )); do
    prep=$(ssh_vm -t 60 "tail -n +$((n0 + 1)) /var/log/rhizo/prepare.log")
    grep -q 'RHIZO_PREPARE_OK\|RHIZO_PREPARE_FAILED\|RHIZO_PREPARE_REFUSED' <<<"$prep" && break
    [[ "$(ssh_vm -t 20 'systemctl is-active rhizo-prepare.service' | tr -d '[:space:]')" == failed ]] && break
    cond=$(ssh_vm -t 30 'systemctl show -p ConditionResult -p ConditionTimestampMonotonic rhizo-prepare.service' | tr -d '\r')
    if grep -qx 'ConditionResult=no' <<<"$cond" && grep -q '^ConditionTimestampMonotonic=[1-9]' <<<"$cond"; then
      printf '%s\n' "$prep" > "$plog"
      fail "3: rhizo-prepare.service condition-skipped on the reboot -- /var/lib/rhizo/.prepared survived the upgrade"
      return 1
    fi
    sleep 30
    waited=$((waited + 30))
  done
  printf '%s\n' "$prep" > "$plog"
  ! grep -q 'prepared=payload-changed' <<<"$prep" \
    || { fail "3: rhizo-kernel-refresh.service removed a marker naming another payload on the reboot --" \
              "/var/lib/rhizo/.prepared survived the upgrade (see $plog)"; return 1; }
  grep -q '^RHIZO_PREPARE_OK .* data=kept ' <<<"$prep" \
    || { fail "3: N's prepare on the reboot did not report RHIZO_PREPARE_OK with data=kept after ${waited}s (see $plog)"; return 1; }
  marker=$(ssh_vm -t 15 'cat /var/lib/rhizo/.prepared; echo DONE')
  lc_done_strip marker && grep -qx "version=$want" <<<"$marker" \
    || { fail "3: .prepared after the reboot reads '$(tr '\n' ' ' <<<"$marker")', want version=$want"; return 1; }
  ver=$(ssh_vm -t 15 'cat /usr/lib/rhizo/VERSION; echo DONE')
  lc_done_strip ver && [[ "$ver" == "$want" ]] \
    || { fail "3: /usr/lib/rhizo/VERSION reads '$ver' after the reboot, want $want"; return 1; }
  id_after=$(ssh_vm -t 15 "stat -c 'ino=%i crtime=%W' /var/lib/rhizo/data.img; echo DONE")
  lc_done_strip id_after && [[ "$id_after" == "$id_before" ]] \
    || { fail "3: data.img is not the same file across the upgrade's reboot ($id_before -> $id_after)"; return 1; }

  case "$profile" in gnome|sway|plasma)
    desk_session_up >"$EV/${profile}-upgrade-session.log" 2>&1 \
      || { fail "3: desk_session_up did not bring the $profile session back after the reboot (see $EV/${profile}-upgrade-session.log)"; return 1; }
  ;; esac
  [[ -n "$APP_PKG" ]] || { fail "3: no fixture package from step 2 to look for after the reboot"; return 1; }
  lc_sandbox_up 3 || return 1
  pkgs=$(android_sh "$INIT" "pm list packages")
  grep -qx "package:$APP_PKG" <<<"$pkgs" \
    || { fail "3: $APP_PKG, planted in step 2, is not installed after the upgrade's reboot"; return 1; }
  pass "3: the reboot finished the upgrade: prepare OK with data=kept, version $want, data.img $id_after unchanged, $APP_PKG still installed"
}

# prepare a release with rhizo prepare
lc_step6_prepare_release() {
  local profile="$1" rel="$2" out n0 prep="" waited=0 cond left
  local plog="$EV/${profile}-gsi-prepare-$rel.log"
  LC_GSI_PREPARE_LINE=""
  ssh_vm -t 120 'systemctl stop androidd.service' >/dev/null 2>&1
  n0=$(ssh_vm -t 15 'wc -l < /var/log/rhizo/prepare.log; echo DONE')
  lc_done_strip n0 && [[ "$n0" =~ ^[0-9]+$ ]] \
    || { fail "6: could not count prepare.log's lines before the prepare: $n0"; return 1; }
  out=$(lc_rhizo 900 prepare --release "$rel" --wipe-data 2>&1)
  printf '%s\n' "$out" > "$EV/${profile}-gsi-prepare-$rel-cli.log"
  LC_GSI_PREPARE_LINE=$(grep -E '^RHIZO_PREPARE_' <<<"$out" | tail -1)
  [[ "$LC_GSI_PREPARE_LINE" == "RHIZO_PREPARE_REBOOT_REQUIRED=1 reason=enforcing release=$rel" ]] \
    || { fail "6: rhizo prepare --release $rel --wipe-data ended '${LC_GSI_PREPARE_LINE:-<no RHIZO_PREPARE_ line>}', want its deferral to the next boot (RHIZO_PREPARE_REBOOT_REQUIRED=1 reason=enforcing release=$rel)"; return 1; }
  reboot_and_wait "cycle-$profile prepare-$rel" || { fail "6: the reboot that runs the deferred prepare did not come back"; return 1; }
  while (( waited < 2100 )); do
    prep=$(ssh_vm -t 60 "tail -n +$((n0 + 1)) /var/log/rhizo/prepare.log")
    grep -q 'RHIZO_PREPARE_OK\|RHIZO_PREPARE_FAILED\|RHIZO_PREPARE_REFUSED\|RHIZO_PREPARE_ALREADY_PREPARED' <<<"$prep" && break
    [[ "$(ssh_vm -t 20 'systemctl is-active rhizo-prepare.service' | tr -d '[:space:]')" == failed ]] && break
    cond=$(ssh_vm -t 30 'systemctl show -p ConditionResult -p ConditionTimestampMonotonic rhizo-prepare.service' | tr -d '\r')
    if grep -qx 'ConditionResult=no' <<<"$cond" && grep -q '^ConditionTimestampMonotonic=[1-9]' <<<"$cond"; then
      printf '%s\n' "$prep" > "$plog"
      fail "6: rhizo-prepare.service condition-skipped on the reboot -- rhizo prepare left /var/lib/rhizo/.prepared in place"
      return 1
    fi
    sleep 30
    waited=$((waited + 30))
  done
  printf '%s\n' "$prep" > "$plog"
  grep -qF "release $rel, tree ${GSI_DIR[$rel]}, from /var/lib/rhizo/prepare-request" <<<"$prep" \
    || { fail "6: the reboot's prepare did not run the deferred request for $rel (see $plog)"; return 1; }
  grep -q '^RHIZO_PREPARE_OK .* data=instantiated ' <<<"$prep" \
    || { fail "6: the reboot's prepare of $rel did not report RHIZO_PREPARE_OK with data=instantiated after ${waited}s (see $plog)"; return 1; }
  left=$(ssh_vm -t 15 'if [ -e /var/lib/rhizo/prepare-request ]; then echo present; else echo absent; fi')
  [[ "$left" == absent ]] \
    || { fail "6: /var/lib/rhizo/prepare-request reads '${left:-<unread>}' after the prepare it asked for finished, want absent"; return 1; }
  case "$profile" in gnome|sway|plasma)
    desk_session_up >"$EV/${profile}-gsi-prepare-session.log" 2>&1 \
      || { fail "6: desk_session_up did not bring the $profile session back after the reboot (see $EV/${profile}-gsi-prepare-session.log)"; return 1; }
  ;; esac
  lc_sandbox_up 6 || return 1
  local before=$FAILED
  assert_booted_release "$rel" "${GSI_DIR[$rel]}"
  (( FAILED == before )) || return 1
  pass "6: rhizo prepare --release $rel --wipe-data moved the host to $rel on a new /data"
}

# plant the fixture app on the release
lc_step6_plant_fixture() {
  local profile="$1" rel="$2" pkgs
  LC_GSI_PLANTED_ON=""
  [[ -n "$INIT" && -n "$DESKAPP_PKG" ]] \
    || { fail "6: no live Android init or fixture package to plant on $rel"; return 1; }
  case "$profile" in
    gnome|sway|plasma) _lc_desktop_plant_fixture_apps "$VAR_DIR/share/rhizo-deskapp.apk" || return 1 ;;
    server)
      ssh_vm -t 60 'rm -f /root/rhizo-lifecycle-fixture.apk' >/dev/null 2>&1
      timeout 120 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$VAR_DIR/share/rhizo-test-fixture.apk" "$SSH_TARGET:/root/rhizo-lifecycle-fixture.apk" \
        || { fail "6: could not stage the fixture APK to the guest"; return 1; }
      lc_rhizo 120 app install /root/rhizo-lifecycle-fixture.apk >/dev/null 2>&1 \
        || { fail "6: rhizo app install did not accept the fixture APK on $rel"; return 1; }
      pkgs=$(android_sh "$INIT" "pm list packages")
      grep -qx "package:$DESKAPP_PKG" <<<"$pkgs" \
        || { fail "6: $DESKAPP_PKG missing from pm list packages after its install on $rel"; return 1; }
      ;;
  esac
  local before=$FAILED
  assert_booted_release "$rel" "${GSI_DIR[$rel]}"
  (( FAILED == before )) || return 1
  _lc_plant_gsi_data "$rel" || return 1
  LC_GSI_PLANTED_ON="$rel"
  pass "6: $DESKAPP_PKG and $LC_GSI_DATA_KEY=$LC_GSI_DATA_TOKEN planted on a running $rel"
}

# print the mtime of /data/system/users/0
_lc_settings_mtime() {
  android_sh "$INIT" "toybox stat -c %y /data/system/users/0" | tr -d '\r\n'
}

LC_SETTINGS_PUT_GAP_MS=2500
# plant a GSI data token in global settings
_lc_plant_gsi_data() {
  local rel="$1" token baseline put_ms back mtime="" end_ms now_ms
  LC_GSI_DATA_TOKEN=""
  token="rhizo-lc-$(cat /proc/sys/kernel/random/uuid)"
  baseline=$(_lc_settings_mtime)
  [[ -n "$baseline" ]] \
    || { fail "6: /data/system/users/0's mtime is unreadable on $rel"; return 1; }
  android_sh "$INIT" "settings put global $LC_GSI_DATA_KEY $token" >/dev/null 2>&1
  put_ms=$(( $(date +%s%N) / 1000000 ))
  back=$(android_sh "$INIT" "settings get global $LC_GSI_DATA_KEY" | tr -d '[:space:]')
  [[ "$back" == "$token" ]] \
    || { fail "6: settings get global $LC_GSI_DATA_KEY on $rel reads '${back:-<empty>}' right after putting '$token'"; return 1; }
  end_ms=$(( put_ms + 10000 ))
  while :; do
    mtime=$(_lc_settings_mtime)
    now_ms=$(( $(date +%s%N) / 1000000 ))
    if [[ -n "$mtime" && "$mtime" != "$baseline" ]] && (( now_ms - put_ms >= LC_SETTINGS_PUT_GAP_MS )); then
      LC_GSI_DATA_TOKEN="$token"
      return 0
    fi
    (( now_ms < end_ms )) || break
    sleep 1
  done
  fail "6: $LC_GSI_DATA_KEY=$token never proved durable on $rel -- /data/system/users/0 still reads '${mtime:-<unreadable>}' (was '$baseline') 10s after the put"
  return 1
}

# run the lifecycle steps for a profile
lifecycle_run_cycle() {
  local profile="$1"
  LC_LIVE=0 LC_FROM_IDX=0 LC_TO_IDX=$LC_LAST_IDX LC_CUR_STEP="" LC_BODY_TRACE=""
  declare -F ssh_vm >/dev/null 2>&1 && LC_LIVE=1
  local lc_refusal
  if ! lc_refusal=$(lifecycle_knob_refusal); then
    fail "lifecycle_run_cycle: $lc_refusal"
    return 1
  fi
  [[ -n "${RHIZO_LIFECYCLE_FROM_STEP:-}" ]] && LC_FROM_IDX=$(_lc_step_index "$RHIZO_LIFECYCLE_FROM_STEP")
  [[ -n "${RHIZO_LIFECYCLE_TO_STEP:-}" ]] && LC_TO_IDX=$(_lc_step_index "$RHIZO_LIFECYCLE_TO_STEP")

  LC_NEW_DEB="" LC_PREV_DEB=""
  LC_DEB_NEW_VERSION="" LC_DEB_PREV_VERSION="" LC_DEB_EVIDENCE="" LC_KERNEL_DEBS=()
  if (( LC_LIVE )) && { _lc_range_needs_n || lc_on_cachyos; }; then
    lc_resolve_new_debs || return 1
    if lc_on_cachyos; then lc_cachyos_resolve || return 1; fi
  fi

  if (( LC_FROM_IDX > 0 && LC_LIVE )); then
    lc_step resume "reattach to the guest already up on vm ${RHIZO_VM:-0}, starting at step $RHIZO_LIFECYCLE_FROM_STEP"
    if ! wait_for_ssh 60; then
      fail "resume: RHIZO_LIFECYCLE_FROM_STEP=$RHIZO_LIFECYCLE_FROM_STEP needs a guest already running on vm ${RHIZO_VM:-0}, and none answers"
      "$REPO/test/vm/boot/explain-boot.sh" >&2
      test_collect_boot_evidence "chain-vm-unreachable"
      return 1
    fi
    log "resume: guest boot_id $(ssh_vm -t 10 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')"
    (( LC_FROM_IDX > $(_lc_step_index 2) )) && step_claim resume.globals lc_resume_resolve "$profile"
  fi

  lc_step 0 "pristine disk, GRUB boot, stock asserted, desktop-resemblance staging, host snapshot"
  if lc_body 0; then
    if lc_on_cachyos; then
      lc_cachyos_step0 "$profile" || return 1
    else
      local lc_disk="$VAR_DIR/vm-pristine${SUFFIX}.qcow2"
      "$LC_TOOLS_DIR/../../../tools/fetch/images/ubuntu-base.sh" 2>&1 | sed 's/^/  /' || fail "0: ubuntu-base.sh failed"
      kill_vm >/dev/null 2>&1
      rm -f "$VAR_DIR/settled${SUFFIX}" "$lc_disk"
      installer_assert_stock "cycle-$profile" || return 1
      ssh_vm -t 60 "[ -f /swapfile ] || fallocate -l 256M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=256 status=none
        chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile 2>/dev/null
        grep -qxF '$LC_SWAPFILE_FSTAB_LINE' /etc/fstab 2>/dev/null || echo '$LC_SWAPFILE_FSTAB_LINE' >> /etc/fstab
        systemctl daemon-reload
        true" >/dev/null 2>&1
      local lc_swap_seed
      lc_swap_seed=$(ssh_vm -t 30 'stat -c %i /swapfile 2>/dev/null; blkid -o value -s UUID /swapfile 2>/dev/null; echo DONE')
      if [[ "$lc_swap_seed" == *$'\n'DONE ]]; then
        lc_swap_seed="${lc_swap_seed%$'\n'DONE}"
        LC_SWAPFILE_INODE_SEED=$(head -1 <<<"$lc_swap_seed")
        LC_SWAPFILE_UUID_SEED=$(sed -n 2p <<<"$lc_swap_seed")
      fi
      [[ -n "$LC_SWAPFILE_INODE_SEED" && -n "$LC_SWAPFILE_UUID_SEED" ]] \
        || fail "0: could not seed and read back a pre-existing /swapfile fixture"
      installer_stage_desktop_resemblance "cycle-$profile" || return 1
      case "$profile" in
        sway)
          installer_stage_pool "cycle-$profile" pipewire "$SHARE_DIR/pipewire-debs" "$TEST_PIPEWIRE_DEBS" "pipewire wireplumber" "" \
            || return 1
          ;;
        server)
          installer_stage_pool "cycle-$profile" adb "$SHARE_DIR/adb-debs" "$LC_TEST_ADB_DEBS" "adb" "" \
            || return 1
          ;;
      esac
      case "$profile" in
        gnome|sway|plasma) installer_stage_desktop_user "cycle-$profile" "$LC_DESKTOP_HUMAN" || return 1 ;;
      esac
      case "$profile" in
        gnome|sway|plasma)
          desk_session_up --stage-login --user "$LC_DESKTOP_HUMAN" > "$EV/${profile}-seat-login-stage.log" 2>&1 \
            || fail "0: the $profile seat login did not come up on the stock host (see $EV/${profile}-seat-login-stage.log)"
          lc_seat_login_record "$profile" "cycle-$profile stock"
          ;;
      esac
    fi
    rm -f "$EV/${profile}"-pkgwin-*.log "$EV/${profile}"-owned-*.tsv "$EV/${profile}"-apt-kept-*.log
    take_snapshot "cycle-$profile before" "$EV/${profile}-snapshot-before.tsv"
  fi

  lc_step 1 "install N-1, one reboot, prepare OK"
  if lc_body 1; then
    if lc_on_cachyos; then
      lc_cachyos_step1 "$profile"
    else
      local lc_prev_dir="${RHIZO_DEB_DIR_PREV:-$VAR_DIR/debs/prev}"
      if lc_one_deb LC_PREV_DEB prev "$lc_prev_dir/rhizo_*_amd64.deb" LC_DEB_PREV_VERSION; then
        LC_INSTALL_DEB_VERSION="$LC_DEB_PREV_VERSION"
        installer_seed_gsi_zip "cycle-$profile" || true
        installer_seed_gsi_zip_release "cycle-$profile" a15 || true
        lc_pkgwin test-staged step1-offline-pool installer_stage_offline_repo "cycle-$profile" || true
        LC_INSTALL_BID_BEFORE=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
        LC_INSTALL_BOOTS_BEFORE=$(ssh_vm -t 20 'journalctl --list-boots --no-pager 2>/dev/null | wc -l; echo DONE')
        [[ "$LC_INSTALL_BOOTS_BEFORE" == *$'\n'DONE ]] \
          && LC_INSTALL_BOOTS_BEFORE="${LC_INSTALL_BOOTS_BEFORE%$'\n'DONE}" || LC_INSTALL_BOOTS_BEFORE=""
        LC_SWAPFILE_ACTIVE_BEFORE_INSTALL=$(lc_swapfile_active)
        lc_step1_install() {
          installer_transfer_artifact "cycle-$profile" "$LC_PREV_DEB" \
            && lc_pkgwin rhizo-install step1-install installer_install_reboot_prepare "cycle-$profile"
        }
        step_claim 1.prepare-ok lc_step1_install
        LC_INSTALL_BID_AFTER=$(ssh_vm -t 20 'cat /proc/sys/kernel/random/boot_id' | tr -d '[:space:]')
        LC_INSTALL_BOOTS_AFTER=$(ssh_vm -t 20 'journalctl --list-boots --no-pager 2>/dev/null | wc -l; echo DONE')
        [[ "$LC_INSTALL_BOOTS_AFTER" == *$'\n'DONE ]] \
          && LC_INSTALL_BOOTS_AFTER="${LC_INSTALL_BOOTS_AFTER%$'\n'DONE}" || LC_INSTALL_BOOTS_AFTER=""
        LC_SWAPFILE_ACTIVE_AFTER_INSTALL=$(lc_swapfile_active)
      fi
    fi
  fi
  claim_assert cli.install lc_assert_cli.install "$@"
  claim_assert cli.prepare lc_assert_cli.prepare "$@"
  claim_assert install.cmd-apt-install lc_assert_install.cmd-apt-install "$@"
  claim_assert install.cmd-reboot lc_assert_install.cmd-reboot "$@"
  claim_assert install.install-flow lc_assert_install.install-flow "$@"
  claim_assert install.one-reboot lc_assert_install.one-reboot "$@"
  claim_assert install.requirements lc_assert_install.requirements "$@"
  claim_assert install.security-module-change lc_assert_install.security-module-change "$@"
  claim_assert install.where-things-live lc_assert_install.where-things-live "$@"
  claim_assert readme.current-state lc_assert_readme.current-state "$@"
  lc_step 2 "session up AS desktop user; plant APK (broker), hostfs file, policy.conf edit"
  if lc_body 2; then
    case "$profile" in
      gnome|sway|plasma)
        desk_session_up || fail "2: desk_session_up did not start a $profile session"
        local lc_user; lc_user=$(lc_desktop_user)
        desk_user_sh --user "$lc_user" 15 'mkdir -p "$HOME/Downloads"' \
          || fail "2: could not create ~$lc_user/Downloads as $lc_user"
        ssh_vm -t 15 "printf '[Download]\ndir = /home/$lc_user/Downloads\n' > /etc/rhizo/hostfs.conf" >/dev/null 2>&1
        ssh_vm -t 30 'systemctl restart rhizo-hostfs.service' >/dev/null 2>&1
        ;;
    esac
    step_claim 2.sandbox-up lc_sandbox_up 2
    lc_rhizo 15 profile "$([[ "$profile" == server ]] && echo server || echo desktop)" >/dev/null 2>&1
    [[ -n "$INIT" ]] && step_claim 2.fixtures-planted lc_setup_fixtures "$profile"
  fi
  claim_assert install.cmd-status lc_assert_install.cmd-status "$@"
  claim_assert cli.adb-key lc_assert_cli.adb-key "$@"
  case "$profile" in gnome|sway|plasma)
    claim_assert install.cmd-hostfs-default-config lc_assert_install.cmd-hostfs-default-config "$@"
    claim_assert install.hostfs-share lc_assert_install.hostfs-share "$@"
    claim_assert install.cmd-hostfs-ini lc_assert_install.cmd-hostfs-ini "$@"
  ;; esac
  case "$profile" in gnome|sway|plasma)
    claim_assert session.user-is-desktop-user lc_assert_session.user-is-desktop-user "$@"
  ;; esac
  lc_step 3 "Rhizo upgrade N-1->N after use: reboot to finish, prepare OK, version moved, data kept"
  if lc_body 3; then
    ssh_vm -t 120 'systemctl stop androidd.service' >/dev/null 2>&1
    if lc_on_cachyos; then
      step_claim 3.version-moved lc_cachyos_step3_upgrade "$profile"
    else
      step_claim 3.version-moved lc_step3_upgrade "$profile" "$LC_NEW_DEB"
    fi
    _lc_step_passed 3.version-moved && lc_step3_cli_upgrade
    step_claim 3.reboot-finishes-upgrade lc_step3_finish_upgrade "$profile" "$LC_NEW_DEB"
  fi
  claim_assert cli.upgrade lc_assert_cli.upgrade "$@"
  lc_step 4 "full claims sweep for the profile"
  if lc_body 4; then
    lc_step4_restart "$profile"
    case "$profile" in gnome|sway|plasma)
      step_claim 4.entries-synced lc_step4_entries_synced
    ;; esac
  fi
  case "$profile" in gnome|sway|plasma)
    claim_assert session.env-from-user-manager lc_assert_session.env-from-user-manager "$@"
  ;; esac
  claim_assert policy.absent-is-defaults lc_assert_policy.absent-is-defaults "$@"
  case "$profile" in gnome|sway|plasma)
    claim_assert policy.off-is-unreachable lc_assert_policy.off-is-unreachable "$@"
  ;; esac
  claim_assert policy.unparsable-denies-optional lc_assert_policy.unparsable-denies-optional "$@"
  case "$profile" in gnome|sway|plasma)
    claim_assert applifecycle.hand-file-to-app lc_assert_applifecycle.hand-file-to-app "$@"
    claim_assert applifecycle.install-mime-handler lc_assert_applifecycle.install-mime-handler "$@"
    claim_assert applifecycle.menu-entry-icons lc_assert_applifecycle.menu-entry-icons "$@"
    claim_assert applifecycle.uninstall-entry-action lc_assert_applifecycle.uninstall-entry-action "$@"
    claim_assert audio.idle-no-stream lc_assert_audio.idle-no-stream "$@"
    claim_assert audio.sound-plays lc_assert_audio.sound-plays "$@"
    claim_assert capability.audio-out lc_assert_capability.audio-out "$@"
    claim_assert capability.desktop-drag lc_assert_capability.desktop-drag "$@"
    claim_assert capability.desktop-notifications lc_assert_capability.desktop-notifications "$@"
    claim_assert capability.desktop-open-uri lc_assert_capability.desktop-open-uri "$@"
  ;; esac
  claim_assert capability.network-enabled lc_assert_capability.network-enabled "$@"
  claim_assert capability.network-services lc_assert_capability.network-services "$@"
  claim_assert host.no-device-reannounce lc_assert_host.no-device-reannounce "$@"
  claim_assert sandbox.host-input-invisible lc_assert_sandbox.host-input-invisible "$@"
  case "$profile" in gnome|sway|plasma)
    claim_assert cli.app lc_assert_cli.app "$@"
  ;; esac
  case "$profile" in server)
    claim_assert cli.device lc_assert_cli.device "$@"
  ;; esac
  claim_assert cli.doctor lc_assert_cli.doctor "$@"
  case "$profile" in server)
    claim_assert cli.instance lc_assert_cli.instance "$@"
  ;; esac
  case "$profile" in gnome|sway|plasma)
    claim_assert cli.launch lc_assert_cli.launch "$@"
    claim_assert applifecycle.launch-activates-window lc_assert_applifecycle.launch-activates-window "$@"
  ;; esac
  claim_assert cli.profile lc_assert_cli.profile "$@"
  claim_assert cli.reset lc_assert_cli.reset "$@"
  claim_assert cli.shell lc_assert_cli.shell "$@"
  claim_assert cli.start lc_assert_cli.start "$@"
  claim_assert cli.status lc_assert_cli.status "$@"
  claim_assert cli.stop lc_assert_cli.stop "$@"
  claim_assert cli.version lc_assert_cli.version "$@"
  case "$profile" in gnome|sway|plasma)
    claim_assert clipboard.frozen-source lc_assert_clipboard.frozen-source "$@"
    claim_assert clipboard.password-hint lc_assert_clipboard.password-hint "$@"
    claim_assert desktop.clipboard-both-ways lc_assert_desktop.clipboard-both-ways "$@"
    claim_assert desktop.clipboard-images lc_assert_desktop.clipboard-images "$@"
    claim_assert desktop.dnd-both-ways lc_assert_desktop.dnd-both-ways "$@"
    claim_assert desktop.dnd-secondary-displays lc_assert_desktop.dnd-secondary-displays "$@"
    claim_assert desktop.ime-no-toast lc_assert_desktop.ime-no-toast "$@"
    claim_assert desktop.keymap-follows-host lc_assert_desktop.keymap-follows-host "$@"
    claim_assert desktop.links-both-ways lc_assert_desktop.links-both-ways "$@"
    claim_assert desktop.notifications-activation lc_assert_desktop.notifications-activation "$@"
    claim_assert desktop.notifications-icon lc_assert_desktop.notifications-icon "$@"
    claim_assert desktop.notifications-inline-reply-fallback lc_assert_desktop.notifications-inline-reply-fallback "$@"
    claim_assert desktop.windows-usable lc_assert_desktop.windows-usable "$@"
    claim_assert host.desktop-intact lc_assert_host.desktop-intact "$@"
    claim_assert host.journal-user-units lc_assert_host.journal-user-units "$@"
    claim_assert host.probe-root-only lc_assert_host.probe-root-only "$@"
    claim_assert hostfs.shared-storage lc_assert_hostfs.shared-storage "$@"
    claim_assert hostfs.write-through lc_assert_hostfs.write-through "$@"
  ;; esac
  claim_assert network.dns lc_assert_network.dns "$@"
  claim_assert network.internet-via-gateway lc_assert_network.internet-via-gateway "$@"
  claim_assert network.mdns-off-default lc_assert_network.mdns-off-default "$@"
  claim_assert readme.what-that-buys lc_assert_readme.what-that-buys "$@"
  case "$profile" in server)
    claim_assert server.adb-reach-host lc_assert_server.adb-reach-host "$@"
    claim_assert server.adb-reach-lan lc_assert_server.adb-reach-lan "$@"
    claim_assert server.control-api lc_assert_server.control-api "$@"
    claim_assert server.explicit-start-only lc_assert_server.explicit-start-only "$@"
    claim_assert server.idle-stop lc_assert_server.idle-stop "$@"
    claim_assert server.instance-add lc_assert_server.instance-add "$@"
    claim_assert cli.snapshot lc_assert_cli.snapshot "$@"
    claim_assert server.instance-allocate lc_assert_server.instance-allocate "$@"
    claim_assert server.instance-release lc_assert_server.instance-release "$@"
    claim_assert server.instance-remove lc_assert_server.instance-remove "$@"
    claim_assert server.no-compositor lc_assert_server.no-compositor "$@"
    claim_assert server.pool-set lc_assert_server.pool-set "$@"
    claim_assert cli.pool lc_assert_cli.pool "$@"
    claim_assert server.snapshot-clone lc_assert_server.snapshot-clone "$@"
  ;; esac
  claim_assert host.new-account-home lc_assert_host.new-account-home "$@"
  claim_assert host.user-manager-start lc_assert_host.user-manager-start "$@"
  claim_assert host.private-users-services lc_assert_host.private-users-services "$@"
  claim_assert host.hotplug-after-flip lc_assert_host.hotplug-after-flip "$@"
  lc_step 5 "Ubuntu upgrade from the staged local repo incl. kernel -> reboot -> sweep"
  if lc_body 5; then
    lc_step5_ubuntu_update() {
      if ! declare -F ubuntu_update_leg >/dev/null 2>&1; then
        fail "5: ubuntu-update-leg.sh's ubuntu_update_leg is not sourced"
        return 1
      fi
      local lc_repo_url="${RHIZO_UPDATE_REPO_URL:-}"
      if [[ -z "$lc_repo_url" ]]; then
        if ! "$LC_TOOLS_DIR/../../vm/guest-os/serve-update-repo.sh" start >&2; then
          fail "5: serve-update-repo.sh start could not bring the shared update repo up -- run tools/fetch/pools/deb/ubuntu-update-debs.sh first if it has never been fetched"
          return 1
        fi
        lc_repo_url=$("$LC_TOOLS_DIR/../../vm/guest-os/serve-update-repo.sh" url)
      fi
      lc_pkgwin ubuntu-update step5 ubuntu_update_leg \
        "$lc_repo_url" \
        "${RHIZO_UPDATE_POOL_DIR:-$VAR_DIR/share/ubuntu-update-debs}" \
        reboot_and_wait \
        "lc_post_reboot_sandbox $profile 5" \
        "lc_step5_app_check $profile cycle-$profile-ubuntu-update" \
        || { fail "5: ubuntu_update_leg reported failure"; return 1; }
    }
    if lc_on_cachyos; then
      lc_step5_cachyos_update() {
        lc_pkgwin host-update step5-cachyos-update cachyos_update_leg "$profile" \
          || { fail "5: cachyos_update_leg reported failure"; return 1; }
      }
      step_claim 5.cachyos-update lc_step5_cachyos_update
    else
      step_claim 5.ubuntu-update lc_step5_ubuntu_update
    fi
  fi
  claim_assert install.apt-helpers-as-root lc_assert_install.apt-helpers-as-root "$@"

  lc_step 6 "a15 on a new /data (rhizo prepare), GSI update a15 -> a16 + manual + automatic rollback (gsi-update-lib legs 2-4, via /usr/bin/rhizo gsi), back to a16 -> sweep"
  if lc_body 6; then
    lc_gsi_stage_noop() { :; }
    local lc_update_sh="/usr/bin/rhizo gsi" lc_arm lc_confirm
    GSI_LEG_ENV_FILE=/etc/rhizo/androidd.env
    GSI_LEG_PER_BOOT_KNOBS=RHIZO_FAULT_NO_READY
    GSI_LEG_SKIP_KNOBS=RHIZO_RELEASE_SWITCH
    if [[ -n "$INIT" && -n "$DESKAPP_PKG" ]]; then
      step_claim 6.prepare-a15 lc_step6_prepare_release "$profile" a15
      _lc_step_passed 6.prepare-a15 && step_claim 6.plant-on-a15 lc_step6_plant_fixture "$profile" a15
      if _lc_step_passed 6.plant-on-a15; then
        step_claim 6.gsi-update-leg gsi_leg_update lifecycle-gsi-update "$lc_update_sh" a15 a16 3 lc_gsi_stage_noop
        step_claim 6.gsi-manual-rollback-leg gsi_leg_manual_rollback lifecycle-gsi-rollback "$lc_update_sh" a15 a16 lc_gsi_stage_noop
        step_claim 6.gsi-exhaustion-leg gsi_leg_exhaustion lifecycle-gsi-exhaust "$lc_update_sh" a15 a16 2 lc_gsi_stage_noop
        step_claim 6.gsi-refused-fetch-leg gsi_leg_refused_fetch lifecycle-gsi-refused "$lc_update_sh" a16 3
        lc_arm="$LC_GSI_ARM_STATUS" lc_confirm="$LC_GSI_CONFIRM_STATUS"
        step_claim 6.gsi-back-to-a16 gsi_leg_update lifecycle-gsi-final "$lc_update_sh" a15 a16 3 lc_gsi_stage_noop
        LC_GSI_ARM_STATUS="$lc_arm" LC_GSI_CONFIRM_STATUS="$lc_confirm"
      else
        fail "6: the fixture was not planted on a running a15"
      fi
    else
      fail "6: no live Android init/DESKAPP_PKG from step 2"
    fi
    unset GSI_LEG_ENV_FILE GSI_LEG_PER_BOOT_KNOBS GSI_LEG_SKIP_KNOBS
  fi
  claim_assert cli.gsi lc_assert_cli.gsi "$@"
  claim_assert gsi.prepare-release lc_assert_gsi.prepare-release "$@"
  claim_assert gsi.app-survives lc_assert_gsi.app-survives "$@"
  claim_assert gsi.automatic-rollback lc_assert_gsi.automatic-rollback "$@"
  claim_assert gsi.manual-rollback lc_assert_gsi.manual-rollback "$@"
  claim_assert gsi.refused-fetch lc_assert_gsi.refused-fetch "$@"
  claim_assert gsi.update lc_assert_gsi.update "$@"
  lc_step 7 "apt remove -> data kept -> reboot -> AppArmor back"
  if lc_body 7; then
    local lc_data_sha_before lc_data_sha_after lc_data_why=""
    local lc_vbmeta_before
    lc_vbmeta_before=$(ssh_vm -t 30 "$LC_VBMETA_ATTACHED_CMD")
    lc_data_sha_before=$(lc_data_img_sha_of "$(ssh_vm -t 120 "$LC_DATA_IMG_QUIESCENT_CMD")") \
      || { lc_data_why="before remove, $lc_data_sha_before"; lc_data_sha_before=""; }
    local lc_remove_out
    host_census_shutdown_audit_arm "$profile" remove
    if lc_on_cachyos; then
      lc_remove_out=$(lc_cachyos_remove "$profile")
    else
      lc_remove_out=$(ssh_vm -t 300 'apt-get remove -y rhizo 2>&1; rc=$?; echo "APT_RC=$rc"; if [ "$rc" -ne 0 ]; then dpkg --remove rhizo 2>&1; fi')
    fi
    echo "$lc_remove_out" > "$EV/${profile}-remove.log"
    wait_dpkg_free "cycle-$profile-remove" || true
    local lc_vbmeta_after_remove
    lc_vbmeta_after_remove=$(ssh_vm -t 30 "$LC_VBMETA_ATTACHED_CMD")
    lc_step7_vbmeta_detached() {
      local why
      if ! lc_vbmeta_was_attached "$lc_vbmeta_before"; then
        fail "7: no loop backed vbmeta.img before the stop ($(tr '\n' ' ' <<<"${lc_vbmeta_before:-<empty>}"))"
        return 1
      fi
      if why=$(lc_vbmeta_detached_of "$lc_vbmeta_after_remove"); then
        pass "7: no loop device backs /usr/lib/rhizo/vbmeta.img after the remove"
        return 0
      fi
      fail "7: $why"
      return 1
    }
    step_claim 7.vbmeta-detached lc_step7_vbmeta_detached
    LC_LSM_AFTER_REMOVE_PRE_REBOOT=$(ssh_vm -t 20 'cat /sys/kernel/security/lsm 2>/dev/null')
    reboot_and_wait "cycle-$profile post-remove" || fail "7: reboot after remove did not come back"
    host_census_shutdown_audit_disarm "$profile" remove
    LC_LSM_AFTER_REMOVE_POST_REBOOT=$(ssh_vm -t 20 'cat /sys/kernel/security/lsm 2>/dev/null')
    local lc_swap_after_remove
    lc_swap_after_remove=$(ssh_vm -t 30 'stat -c %i /swapfile 2>/dev/null; blkid -o value -s UUID /swapfile 2>/dev/null; echo DONE')
    if [[ "$lc_swap_after_remove" == *$'\n'DONE ]]; then
      lc_swap_after_remove="${lc_swap_after_remove%$'\n'DONE}"
      LC_SWAPFILE_INODE_AFTER_REMOVE=$(head -1 <<<"$lc_swap_after_remove")
      LC_SWAPFILE_UUID_AFTER_REMOVE=$(sed -n 2p <<<"$lc_swap_after_remove")
    fi
    lc_data_sha_after=$(lc_data_img_sha_of "$(ssh_vm -t 120 "$LC_DATA_IMG_QUIESCENT_CMD")") \
      || { lc_data_why="${lc_data_why:+$lc_data_why; }after the reboot, $lc_data_sha_after"; lc_data_sha_after=""; }
    lc_step7_data_unchanged() {
      if [[ -z "$lc_data_sha_before" || -z "$lc_data_sha_after" ]]; then
        fail "7: could not read /var/lib/rhizo/data.img's sha, unmounted, on one side of remove+reboot (before='$lc_data_sha_before' after='$lc_data_sha_after'): $lc_data_why"
        return 1
      elif [[ "$lc_data_sha_before" != "$lc_data_sha_after" ]]; then
        fail "7: data.img sha changed across a plain remove ($lc_data_sha_before -> $lc_data_sha_after)"
        return 1
      fi
      pass "7: data.img is unchanged across a plain remove+reboot"
    }
    step_claim 7.data-img-unchanged lc_step7_data_unchanged
    local lc_settle_remove
    if lc_settle_remove=$(lc_host_settle "7: after remove+reboot"); then lc_settle_remove=""; fi
    take_snapshot "cycle-$profile after-remove" "$EV/${profile}-snapshot-after-remove.tsv"
    lc_step7_snapshot_diff() {
      [[ -z "$lc_settle_remove" ]] || { fail "$lc_settle_remove"; return 1; }
      lc_snapshot_diff "$profile" remove \
        && pass "7: host-snapshot-diff.py: a plain remove touched only allowlisted state" \
        || { fail "7: host-snapshot-diff.py found undisclosed drift after remove (see $EV/${profile}-snapshot-diff-remove.txt)"; return 1; }
    }
    step_claim 7.snapshot-diff-remove lc_step7_snapshot_diff
  fi
  claim_assert install.cmd-apt-remove lc_assert_install.cmd-apt-remove "$@"
  claim_assert packaging.remove-keeps-data lc_assert_packaging.remove-keeps-data "$@"
  claim_assert packaging.remove-reverses-host-state lc_assert_packaging.remove-reverses-host-state "$@"
  claim_assert packaging.second-reboot-needed lc_assert_packaging.second-reboot-needed "$@"

  lc_step 8 "reinstall -> APK listed"
  if lc_body 8; then
    lc_step8_reinstall() {
      if lc_on_cachyos; then
        if ! lc_pkgwin rhizo-install step8-reinstall lc_cachyos_reinstall "$profile" -reinstall; then
          fail "8: reinstall did not reach RHIZO_PREPARE_OK"
          return 1
        fi
        return 0
      fi
      installer_transfer_artifact "cycle-$profile-reinstall" "$LC_NEW_DEB" "${LC_KERNEL_DEBS[@]}" || return 1
      lc_apt_conf_present 8 || return 1
      lc_pkgwin rhizo-install step8-reinstall installer_install_reboot_prepare "cycle-$profile-reinstall" \
        || { fail "8: reinstall did not reach RHIZO_PREPARE_OK"; return 1; }
    }
    step_claim 8.reinstall-prepare-ok lc_step8_reinstall
    if [[ -n "$APP_PKG" ]]; then
      lc_step8_apk_listed() {
        lc_sandbox_up 8 || return 1
        local pkgs; pkgs=$(android_sh "$INIT" "pm list packages")
        grep -qx "package:$APP_PKG" <<<"$pkgs" \
          && pass "8: $APP_PKG is listed after reinstall" \
          || { fail "8: $APP_PKG is not in pm list packages after reinstall"; return 1; }
      }
      step_claim 8.apk-listed lc_step8_apk_listed
    fi
  fi
  case "$profile" in gnome|sway|plasma)
    claim_assert applifecycle.restart-from-user-side lc_assert_applifecycle.restart-from-user-side "$@"
  ;; esac

  lc_step 9 "apt purge + autoremove -> reboot -> snapshot diff"
  if lc_body 9; then
    local lc_purge_out
    host_census_shutdown_audit_arm "$profile" purge
    if lc_on_cachyos; then
      lc_purge_out=$(lc_cachyos_purge)
      echo "$lc_purge_out" > "$EV/${profile}-purge.log"
      lc_purge_rhizo_kernel "$profile"
    else
      lc_purge_out=$(ssh_vm -t 300 'apt-get purge -y rhizo 2>&1; rc=$?; echo "APT_RC=$rc"; if [ "$rc" -ne 0 ]; then dpkg --purge rhizo 2>&1; fi')
      echo "$lc_purge_out" > "$EV/${profile}-purge.log"
      wait_dpkg_free "cycle-$profile-purge" || true
      lc_purge_rhizo_kernel "$profile"
      ssh_vm -t 600 'DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y 2>&1; echo "APT_RC=$?"' \
        > "$EV/${profile}-autoremove.log" 2>&1
      wait_dpkg_free "cycle-$profile-autoremove" || true
      lc_apt_kept_record "$profile"
    fi
    reboot_and_wait "cycle-$profile post-purge" || fail "9: reboot after purge did not come back"
    host_census_shutdown_audit_disarm "$profile" purge
    local lc_swap_after_purge
    lc_swap_after_purge=$(ssh_vm -t 30 'stat -c %i /swapfile 2>/dev/null; blkid -o value -s UUID /swapfile 2>/dev/null; echo DONE')
    if [[ "$lc_swap_after_purge" == *$'\n'DONE ]]; then
      lc_swap_after_purge="${lc_swap_after_purge%$'\n'DONE}"
      LC_SWAPFILE_INODE_AFTER_PURGE=$(head -1 <<<"$lc_swap_after_purge")
      LC_SWAPFILE_UUID_AFTER_PURGE=$(sed -n 2p <<<"$lc_swap_after_purge")
    fi
    lc_step9_data_gone() {
      local gone; gone=$(ssh_vm -t 15 'test -f /var/lib/rhizo/data.img && echo PRESENT || echo ABSENT' | tr -d '\r')
      [[ "$gone" == ABSENT ]] \
        && pass "9: data.img is gone after purge" \
        || { fail "9: data.img is still present after purge ($gone)"; return 1; }
    }
    step_claim 9.data-gone lc_step9_data_gone
    local lc_settle_purge
    if lc_settle_purge=$(lc_host_settle "9: after purge+reboot"); then lc_settle_purge=""; fi
    take_snapshot "cycle-$profile after-purge" "$EV/${profile}-snapshot-after-purge.tsv"
    lc_step9_snapshot_diff() {
      [[ -z "$lc_settle_purge" ]] || { fail "$lc_settle_purge"; return 1; }
      lc_snapshot_diff "$profile" purge \
        && pass "9: host-snapshot-diff.py: purge returned the host to stock" \
        || { fail "9: host-snapshot-diff.py found undisclosed drift after purge (see $EV/${profile}-snapshot-diff-purge.txt)"; return 1; }
    }
    step_claim 9.snapshot-diff-purge lc_step9_snapshot_diff
  fi
  claim_assert install.cmd-apt-purge lc_assert_install.cmd-apt-purge "$@"
  claim_assert packaging.purge-deletes-data lc_assert_packaging.purge-deletes-data "$@"
  claim_assert packaging.swapfile-precise-removal lc_assert_packaging.swapfile-precise-removal "$@"

  lc_step 9b "reinstall -> rhizo uninstall --purge (the CLI's own guided path, never exercised by step 9's plain apt purge) -> reboot"
  if lc_body 9b; then
    lc_step9b_reinstall() {
      if lc_on_cachyos; then
        if ! lc_cachyos_reinstall "$profile" -reinstall-for-cli-purge; then
          fail "9b: reinstall did not reach RHIZO_PREPARE_OK"
          return 1
        fi
        return 0
      fi
      installer_transfer_artifact "cycle-$profile-reinstall-for-cli-purge" "$LC_NEW_DEB" "${LC_KERNEL_DEBS[@]}" || return 1
      lc_apt_conf_present 9b || return 1
      installer_install_reboot_prepare "cycle-$profile-reinstall-for-cli-purge" || { fail "9b: reinstall did not reach RHIZO_PREPARE_OK"; return 1; }
    }
    step_claim 9b.reinstall-prepare-ok lc_step9b_reinstall
    local lc_cli_purge_out
    lc_cli_purge_out=$(ssh_vm -t 300 'RHIZO_ASSUME_YES=1 /usr/bin/rhizo uninstall --purge 2>&1')
    echo "$lc_cli_purge_out" > "$EV/${profile}-cli-purge.log"
    wait_dpkg_free "cycle-$profile-cli-purge" || true
    reboot_and_wait "cycle-$profile post-cli-purge" || fail "9b: reboot after rhizo uninstall --purge did not come back"
  fi
  claim_assert cli.uninstall lc_assert_cli.uninstall "$@"
  claim_assert install.removing lc_assert_install.removing "$@"

  lc_step 10 "reinstall from purge -> prepare OK, one app paints. Teardown."
  if lc_body 10; then
    lc_step10_reinstall() {
      if lc_on_cachyos; then
        if ! lc_cachyos_reinstall "$profile" -reinstall-purge; then
          fail "10: reinstall-from-purge did not reach RHIZO_PREPARE_OK"
          return 1
        fi
        return 0
      fi
      installer_transfer_artifact "cycle-$profile-reinstall-purge" "$LC_NEW_DEB" "${LC_KERNEL_DEBS[@]}" || return 1
      lc_apt_conf_present 10 || return 1
      installer_install_reboot_prepare "cycle-$profile-reinstall-purge" || { fail "10: reinstall-from-purge did not reach RHIZO_PREPARE_OK"; return 1; }
    }
    step_claim 10.reinstall-purge-prepare-ok lc_step10_reinstall
    case "$profile" in
      gnome|sway|plasma) desk_session_up >/dev/null 2>&1 ;;
    esac
    case "$profile" in
      gnome|sway|plasma)
        if [[ -n "$APP_PKG" && -n "$APP_ACT" ]]; then
          lc_step10_plant_fixture() {
            lc_sandbox_up 10 || return 1
            _lc_desktop_plant_fixture_apps "$VAR_DIR/share/rhizo-deskapp.apk"
          }
          step_claim 10.fixture-planted lc_step10_plant_fixture
          step_claim 10.app-paints lc_step10_app_paints "$profile"
        fi
        ;;
      server)
        lc_server_app_launches "cycle-$profile-final"
        ;;
    esac
  fi
  case "$profile" in gnome|sway|plasma)
    claim_assert applifecycle.launch-composited-app-id lc_assert_applifecycle.launch-composited-app-id "$@"
  ;; esac
  case "$profile" in gnome|sway|plasma)
    claim_assert host.seat-login lc_assert_host.seat-login "$@"
  ;; esac
}

# print the cycle claim ids for a profile
_lc_expected_claims() {
  local claims_tsv="$LC_TOOLS_DIR/claims.tsv" cid cprofiles cassert
  [[ -f "$claims_tsv" ]] || return 1
  while IFS=$'\t' read -r cid cprofiles cassert; do
    [[ "$cid" == \#* || -z "$cid" ]] && continue
    [[ "$cassert" == cycle:* ]] || continue
    case ",$cprofiles," in *",$1,"*) printf '%s\n' "$cid" ;; esac
  done < "$claims_tsv"
}

# record unreached claims and the finished cycle
lifecycle_finish_cycle() {
  local profile="$1" cycle_id="$2" started="$3" expected cid
  lc_pull_journal
  [[ -s "$EV/claims.tsv" ]] || printf 'claim_id\tresult\n' > "$EV/claims.tsv"
  if expected=$(_lc_expected_claims "$profile"); then
    for cid in $expected; do
      if ! awk -F'\t' -v id="$cid" 'NR>1 && $1==id{f=1} END{exit !f}' "$EV/claims.tsv"; then
        fail "claim $cid: never reached a claim_assert call this cycle"
        printf '%s\t%s\n' "$cid" "not_run" >> "$EV/claims.tsv"
        _lc_claims_detail "$cid" "<missing>" "never reached a claim_assert call this cycle"
      fi
    done
  else
    fail "lifecycle_finish_cycle: cannot read $LC_TOOLS_DIR/claims.tsv to derive the expected claim set for $profile"
  fi
  rig_cycle_finished "$profile" "$cycle_id" "$started"
}

# print CLEAN or FAIL for a profile's claims
lifecycle_claims_verdict() {
  local total nfail nnotrun expected_total
  read -r total _ nfail nnotrun _ _ < <(_lc_claim_counts "$EV/claims.tsv")
  expected_total=$(_lc_expected_claims "$1" | grep -c .)
  if [[ "$nfail" == 0 && "$nnotrun" == 0 && "$total" -gt 0 && "$total" == "$expected_total" ]]; then
    echo CLEAN
  else
    echo FAIL
  fi
}
