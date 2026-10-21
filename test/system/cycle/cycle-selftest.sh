#!/bin/bash
# check the lifecycle cycle's claims and helpers against fixtures, with no vm
# shellcheck disable=SC2034
source "$(dirname "${BASH_SOURCE[0]}")/cycle.sh"

# run all of the fixture cases and exit nonzero when a case fails
cycle_selftest() {
  set -uo pipefail
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  FAILED=0
  EV="$(mktemp -d)" || exit 1
  trap 'rm -rf "$EV"' EXIT
  : > "$EV/failures.log"
  : > "$EV/claims.tsv"
  TEST_STEP="<none>"
  INSTALLER_SELINUX_MODE=host
  eval "$(sed -n '/^RHIZO_INIT_SCAN_BODY=/p; /^guest_init_pids() {/,/^}/p; /^guest_init_pid() {/,/^}/p' \
    "$repo_root/test/vm/common.sh")"

  log()  { echo "$*" >&2; }
  fail() { log "FAIL: $*"; FAILED=$((FAILED + 1)); }
  step() { TEST_STEP="$*"; log "=== $*"; }
  pass() { log "  ok: $*"; }

  source "$(dirname "${BASH_SOURCE[0]}")/../lib/server-assert-lib.sh"
  unset RHIZO_VM_HOOK
  source "$repo_root/test/vm/rig/hooks.sh" || exit 2

  LC_ST_REAL_LC_RHIZO=$(declare -f lc_rhizo)
  LC_ST_REAL_DESK_USER_SH=$(declare -f desk_user_sh)

  BAD=0
  ok() { echo "SELFTEST OK: $1"; }
  bad() { echo "SELFTEST FAIL: $1"; BAD=$((BAD + 1)); }

  for id in cli.install desktop.clipboard-both-ways \
            gsi.update policy.off-is-unreachable packaging.purge-deletes-data; do
    fn="lc_assert_$id"
    before=$FAILED
    if "$fn"; then
      bad "$fn returns 0 with no guest in scope (must fail closed)"
    elif (( FAILED == before )); then
      bad "$fn returned nonzero but never called fail"
    else
      ok "$fn fails by name with no guest in scope"
    fi
  done

  doc_only_ids="readme.what-that-buys readme.current-state"
  ssh_vm() { return 255; }
  android_sh() { return 255; }
  lc_rhizo() { return 255; }
  desk_windows() { return 255; }
  : > "$EV/claims.tsv"
  all_lc_assert_ids=$(declare -F | awk '{print $3}' | grep '^lc_assert_' | sed 's/^lc_assert_//' | sort -u)
  all_bad=0
  for id in $all_lc_assert_ids; do
    case " $doc_only_ids " in
      *" $id "*)
        claim_fence "$id" "selftest: doc-only, needs no guest"
        ;;
      *)
        before=$FAILED
        fn="lc_assert_$id"
        if "$fn" >/dev/null 2>&1; then
          bad "$fn returns 0 with a guest present but every command failing (must fail closed)"
          all_bad=1
        elif (( FAILED == before )); then
          bad "$fn returned nonzero but never called fail (a silent fall-through)"
          all_bad=1
        fi
        ;;
    esac
  done
  unset -f ssh_vm android_sh lc_rhizo desk_windows
  if (( all_bad == 0 )); then
    ok "every lc_assert_* ($(wc -w <<<"$all_lc_assert_ids" | tr -d '[:space:]') of them) fails closed with a guest present but every command on it failing, except the doc-only ones, which fence"
  fi

  before=$FAILED
  ssh_vm() { return 255; }
  if lc_assert_server.no-compositor >/dev/null 2>&1; then
    bad "server.no-compositor passes when its own probe never completes (dead guest)"
  elif (( FAILED == before )); then
    bad "server.no-compositor returned nonzero but never called fail on a probe that never completes"
  else
    ok "1d: server.no-compositor fails closed on a probe that never completes"
  fi
  unset -f ssh_vm

  before=$FAILED
  ssh_vm() { case "${*: -1}" in *get-state*) printf '\n' ;; *) return 255 ;; esac; }
  if lc_assert_server.adb-reach-host >/dev/null 2>&1; then
    bad "server.adb-reach-host passes on an empty adb get-state reply"
  elif (( FAILED == before )); then
    bad "server.adb-reach-host returned nonzero but never called fail on an empty get-state"
  else
    ok "1d: server.adb-reach-host fails closed on an empty adb get-state reply"
  fi
  unset -f ssh_vm

  before=$FAILED
  LC_INSTANCE_ALLOC_ID=7; LC_INSTANCE_ALLOC_ADB=192.168.101.2:5555
  ssh_vm() { return 255; }
  lc_rhizo() { case "$*" in *release*) echo "RHIZO_RELEASED id=7" ;; esac; return 0; }
  if lc_assert_server.instance-release >/dev/null 2>&1; then
    bad "server.instance-release passes when the post-release adb get-state read is dead"
  elif (( FAILED == before )); then
    bad "server.instance-release returned nonzero but never called fail on a dead post-release read"
  else
    ok "1d: server.instance-release fails closed when it cannot confirm the release (dead ssh on the read)"
  fi
  unset -f ssh_vm lc_rhizo
  LC_INSTANCE_ALLOC_ID=""; LC_INSTANCE_ALLOC_ADB=""

  before=$FAILED
  ssh_vm() {
    local body="${*: -1}"
    case "$body" in
      *LC_POLICY_ABSENT_MARKER*) printf '[rhizo]\nprofile = server\n%s\n' "$PROBE_DONE_TAG" ;;
      *'rm -f /etc/rhizo/policy.conf'*) return 0 ;;
      *'base64 -d > /etc/rhizo/policy.conf'*) return 1 ;;
      *) return 255 ;;
    esac
  }
  if lc_assert_policy.absent-is-defaults >/dev/null 2>&1; then
    bad "policy.absent-is-defaults passes when the restore write fails (the vm is left with policy.conf deleted)"
  elif (( FAILED == before )); then
    bad "policy.absent-is-defaults returned nonzero but never called fail on a failed restore"
  else
    ok "1d: policy.absent-is-defaults fails closed when its own restore write fails"
  fi
  unset -f ssh_vm

  before=$FAILED
  INIT=123; DOWNLOADS=/home/ubuntu/Downloads
  ssh_vm() { return 255; }
  desk_user_sh() {
    local body="${*: -1}"
    case "$body" in
      *"sha256sum '$DOWNLOADS/lc-hostfs-writethrough.txt'"*) printf '%s  x\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
      *"test -e '$DOWNLOADS/lc-hostfs-writethrough.txt'"*) printf 'ABSENT\n%s\n' "$PROBE_DONE_TAG" ;;
      *"cat '$DOWNLOADS/lc-hostfs-writethrough.txt'"*) printf '%s' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
      *"rm -f '$DOWNLOADS/lc-hostfs-writethrough.txt'"*) return 0 ;;
      *) return 255 ;;
    esac
  }
  android_sh() {
    case "${*: -1}" in
      printf*) return 1 ;;
      *cat*) printf '%s' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
      *) return 255 ;;
    esac
  }
  if lc_assert_hostfs.write-through >/dev/null 2>"$EV/wt.err"; then
    bad "hostfs.write-through passes when the Android write itself failed (an old file reads the same on both sides)"
  elif (( FAILED == before )); then
    bad "hostfs.write-through returned nonzero but never called fail on a failed Android write"
  elif ! grep -q "the Android write of this cycle's nonce" "$EV/wt.err"; then
    bad "1d: hostfs.write-through failed before the Android write it models: $(grep FAIL "$EV/wt.err" | head -1)"
  else
    ok "1d: hostfs.write-through fails closed when the Android write fails, even with a matching old file on both sides"
  fi
  unset -f ssh_vm android_sh desk_user_sh
  eval "$LC_ST_REAL_DESK_USER_SH"
  INIT=""; DOWNLOADS=""

  before=$FAILED
  drag_fx=$(mktemp -d) || exit 1
  echo on > "$drag_fx/policy"; echo 0 > "$drag_fx/pgreps"
  ssh_vm() {
    local body="${*: -1}" n
    case "$body" in
      *"pgrep -a -x 'rhizo-wlbridge'"*)
        n=$(( $(cat "$drag_fx/pgreps") + 1 )); echo "$n" > "$drag_fx/pgreps"
        if (( n == 1 )); then
          printf '4242 /usr/lib/rhizo/deskbridge/rhizo-wlbridge --caps clipboard,drag\n'
          return 0
        fi
        return 255
        ;;
      *'systemctl is-active rhizo-deskd'*) printf 'active\n' ;;
      *policy_or_deny*)
        if [[ "$(cat "$drag_fx/policy")" == on ]]; then printf 'True frozenset()\n'; else printf 'False frozenset()\n'; fi
        ;;
      *LC_POLICY_ABSENT_MARKER*) printf 'LC_POLICY_ABSENT_MARKER\n%s\n' "$PROBE_DONE_TAG" ;;
      *'test -f /etc/rhizo/policy.conf'*) printf 'ABSENT\n%s\n' "$PROBE_DONE_TAG" ;;
      *"printf '[desktop]"*) echo off > "$drag_fx/policy" ;;
      *'rm -f /etc/rhizo/policy.conf'*) echo on > "$drag_fx/policy" ;;
      *'systemctl restart rhizo-deskd.service'*) : ;;
      *) return 255 ;;
    esac
  }
  lc_st_real_bridge_restart=$(declare -f _lc_desktop_bridge_restart)
  _lc_desktop_bridge_restart() { return 0; }
  drag_err=$(mktemp)
  if lc_assert_capability.desktop-drag >/dev/null 2>"$drag_err"; then
    bad "capability.desktop-drag passes when a restart leaves wlbridge's own argv unreadable (process gone)"
  elif (( FAILED == before )); then
    bad "capability.desktop-drag returned nonzero but never called fail with wlbridge gone after the restart"
  elif ! grep -qF "withheld, no live rhizo-wlbridge --caps argv to read after the restart" "$drag_err"; then
    bad "1d: capability.desktop-drag with no wlbridge after the restart failed elsewhere: $(grep FAIL "$drag_err" | head -1)"
  else
    ok "1d: capability.desktop-drag fails closed, by name, when a restart leaves no wlbridge process to read --caps from"
  fi
  rm -f "$drag_err"
  eval "$lc_st_real_bridge_restart"; unset lc_st_real_bridge_restart
  rm -rf "$drag_fx"
  unset -f ssh_vm
  unset drag_fx drag_err

  declare -F note >/dev/null 2>&1 || note() { log "  $*"; }
  declare -gA hook_state=()
  hook_pair=RHIZO_DEBUG_PERMISSIVE_DOMAIN=rhizo_host
  ssh_vm() {
    local body="${*: -1}" unit st
    unit=$(sed -n 's/.*systemctl show -p LoadState -p Environment \([a-z@.-]*\)$/\1/p' <<<"$body")
    st="${hook_state[$unit]:-dead}"
    [[ "$st" == dead ]] && return 255
    printf 'LoadState=%s\nEnvironment=%s\n' "${st%%|*}" "${st#*|}"
  }
  hook_case() {
    local want="$1" frag="$2" label="$3" before=$FAILED rc msgs
    hook_state=([rhizo-policy.service]="$4" [androidd.service]="$5")
    msgs=$(RHIZO_LIFECYCLE_GUEST_ENV="$hook_pair" installer_pre_reboot_hook selftest 2>&1)
    rc=$?
    if [[ "$want" == pass ]]; then
      if (( rc == 0 && FAILED == before )); then ok "1e: pre-reboot hook passes: $label"
      else bad "1e: pre-reboot hook failed where it must pass ($label): $msgs"; fi
    elif (( rc == 0 )); then
      bad "1e: pre-reboot hook returned 0 on a planted defect ($label)"
    elif [[ "$msgs" != *"$frag"* ]]; then
      bad "1e: pre-reboot hook failed on '$label' but not by name (want '$frag'): $msgs"
    else
      ok "1e: pre-reboot hook fails by name: $label"
    fi
    FAILED=$before
  }
  hook_case pass - "N-1 ships no rhizo-policy.service, androidd.service loaded with the pair" \
    "not-found|" "loaded|$hook_pair"
  hook_case pass - "both units loaded with the pair (the N install)" \
    "loaded|RHIZO_X=1 $hook_pair" "loaded|$hook_pair"
  hook_case fail "no unit the debug drop-ins target is installed" "both units absent" \
    "not-found|" "not-found|"
  hook_case fail "androidd.service is loaded but does not carry $hook_pair" "a loaded unit missing the pair" \
    "not-found|" "loaded|"
  hook_case fail "androidd.service is loaded but does not carry $hook_pair" "a loaded unit carrying only a longer value of the pair" \
    "not-found|" "loaded|${hook_pair}_extra"
  hook_case fail "rhizo-policy.service reads LoadState='masked'" "a masked unit" \
    "masked|" "loaded|$hook_pair"
  hook_case fail "rhizo-policy.service reads LoadState='bad-setting'" "a drop-in that broke its unit" \
    "bad-setting|$hook_pair" "loaded|$hook_pair"
  hook_case fail "androidd.service reads LoadState=''" "an ssh that answered nothing" \
    "not-found|" dead
  unset -f ssh_vm hook_case
  unset hook_state hook_pair

  abort_fx=$(mktemp -d) || exit 1
  mkdir -p "$abort_fx/ev"
  abort_out=$( (
    EV="$abort_fx/ev" LC_POLICY_TRAP_INSTALLED=""
    TEST_EXTRA_CLEANUP=true
    ssh_vm() { return 0; }
    test_cleanup_shape() {
      local rc=$?
      [[ -n "${TEST_EXTRA_CLEANUP:-}" ]] && "$TEST_EXTRA_CLEANUP"
      echo "CLEANUP_RC=$rc"
      (( rc != 0 )) && echo "FAILED exit=$rc" > "$EV/verdict.txt"
      return $rc
    }
    trap test_cleanup_shape EXIT
    lc_arm_policy_restore ""
    exit 3
  ) 2>&1 )
  if grep -qx 'CLEANUP_RC=3' <<<"$abort_out" && [[ "$(cat "$abort_fx/ev/verdict.txt" 2>/dev/null)" == "FAILED exit=3" ]]; then
    ok "1f: the cleanup behind a chained policy-restore trap still sees exit 3 and records FAILED"
  else
    bad "1f: the cleanup behind the chained policy-restore trap lost the exit status ($(grep '^CLEANUP_RC=' <<<"$abort_out" || echo 'no CLEANUP_RC'), verdict: $(cat "$abort_fx/ev/verdict.txt" 2>/dev/null || echo none))"
  fi
  rm -rf "$abort_fx"
  unset abort_fx abort_out

  for order_profile in sway gnome server; do
    order_fx=$(mktemp -d) || exit 1
    mkdir -p "$order_fx/tools/fetch/images" "$order_fx/test/system/cycle"
    printf '#!/bin/bash\nexit 0\n' > "$order_fx/tools/fetch/images/ubuntu-base.sh"
    chmod +x "$order_fx/tools/fetch/images/ubuntu-base.sh"
    order_out=$( (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      cd "$order_fx" || exit 1
      exec 3>&1
      REPO="$order_fx" VAR_DIR="$order_fx" SHARE_DIR="$order_fx/share" SUFFIX="" EV="$order_fx" RHIZO_LIFECYCLE_TO_STEP=0
      LC_TOOLS_DIR="$order_fx/test/system/cycle"
      printf 'claim_id\tresult\n' > "$EV/claims.tsv"
      ssh_vm() { case "${*: -1}" in *'stat -c %i /swapfile'*) printf '12\nuuid-1\nDONE\n' ;; *) return 0 ;; esac; }
      kill_vm() { :; }
      installer_assert_stock() { echo "CALL stock"; }
      installer_stage_desktop_resemblance() { echo "CALL stage $1"; }
      installer_stage_pool() { echo "CALL pool $1 $2 $5"; }
      installer_stage_desktop_user() { echo "CALL user $1 $2"; }
      desk_session_up() { echo "CALL login $*" >&3; }
      lc_seat_login_record() { echo "CALL record $1 $2"; }
      take_snapshot() { echo "CALL snapshot $1"; }
      lifecycle_run_cycle "$order_profile"
    ) 2>/dev/null | grep '^CALL ' )
    rm -rf "$order_fx"
    order_want="CALL stock"$'\n'"CALL stage cycle-$order_profile"
    [[ "$order_profile" == sway ]] && order_want+=$'\n'"CALL pool cycle-sway pipewire pipewire wireplumber"
    [[ "$order_profile" == server ]] && order_want+=$'\n'"CALL pool cycle-server adb adb"
    [[ "$order_profile" == server ]] \
      || order_want+=$'\n'"CALL user cycle-$order_profile deskuser"$'\n'"CALL login --stage-login --user deskuser"$'\n'"CALL record $order_profile cycle-$order_profile stock"
    order_want+=$'\n'"CALL snapshot cycle-$order_profile before"
    if [[ "$order_out" == "$order_want" ]]; then
      ok "1g: $order_profile's step 0 asserts the stock host and takes the \"before\" host snapshot after all of its desktop resemblance: $(tail -n +2 <<<"$order_want" | head -n -1 | cut -d' ' -f2 | tr '\n' ' ')"
    else
      bad "1g: $order_profile's step 0 ran: $(tr '\n' '|' <<<"${order_out:-nothing}") (want: $(tr '\n' '|' <<<"$order_want"))"
    fi
  done
  unset order_fx order_out order_want order_profile

  lc_du_run() {
    (
      lc_du_line="$1" lc_du_stats="$2"
      ssh_vm() {
        case "${*: -1}" in
          "getent passwd 1000 | cut -d: -f1; echo DONE") printf '%s\nDONE\n' "${lc_du_line%%:*}" ;;
          *"cut -d: -f1,6"*) printf '%s\n%b\nDONE\n' "$lc_du_line" "$lc_du_stats" ;;
        esac
      }
      FAILED=0
      installer_stage_desktop_user cycle-sway deskuser >/dev/null 2>"$lc_du_fx"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_du_fx=$(mktemp) || exit 1
  lc_du_out=$( source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"; lc_du_run 'deskuser:/home/deskuser' '1000 750\n1000 755' )
  if [[ "$lc_du_out" == "RC=0 FAILED=0" ]]; then
    ok "1o: a real uid-1000 login with a 0750 home and Downloads passes as the desktop user"
  else
    bad "1o: a real uid-1000 login read '${lc_du_out:-nothing}': $(grep FAIL "$lc_du_fx" | head -1)"
  fi
  lc_du_out=$( source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"; lc_du_run 'rhizo-appwatch:/nonexistent' "stat: cannot statx '/nonexistent': No such file or directory" )
  if [[ "$lc_du_out" == "RC=1 FAILED=1" ]] && grep -q "uid 1000 is already 'rhizo-appwatch'" "$lc_du_fx"; then
    ok "1o: a uid 1000 that is rhizo-appwatch fails by name as the desktop user"
  else
    bad "1o: a uid 1000 that is rhizo-appwatch (home /nonexistent) read '${lc_du_out:-nothing}': $(grep FAIL "$lc_du_fx" | head -1)"
  fi
  rm -f "$lc_du_fx"
  unset -f lc_du_run
  unset lc_du_fx lc_du_out

  lc_ir_fx=$(mktemp -d) || exit 1
  lc_ir_out=$( (
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
    EV="$lc_ir_fx"
    ssh_vm() {
      case "${*: -1}" in
        *"apt-get install"*) printf 'E: Unable to correct problems, you have held broken packages.\nAPT_RC=100\n rhizo depends on libpipewire-0.3-0t64 (>= 0.3.6); however:\ndpkg: error processing package rhizo (--install):\n dependency problems - leaving unconfigured\n' ;;
        *"db:Status-Abbrev"*) printf 'rhizo=iU \nDONE\n' ;;
        *"systemctl is-active rhizo-prepare.service"*) echo inactive ;;
        *"-p ConditionResult -p ConditionTimestampMonotonic"*) printf 'ConditionResult=no\nConditionTimestampMonotonic=4242\n' ;;
        *) return 0 ;;
      esac
    }
    reboot_and_wait() { echo "CALL reboot" >> "$lc_ir_fx/calls"; return 0; }
    FAILED=0
    installer_install_reboot_prepare cycle-server-reinstall >/dev/null 2>"$lc_ir_fx/claim.err"
    echo "RC=$? FAILED=$FAILED REBOOTS=$(grep -c . "$lc_ir_fx/calls" 2>/dev/null || echo 0)"
  ) )
  if [[ "$lc_ir_out" == "RC=1 FAILED=1 REBOOTS=0" ]] && grep -q 'left the packages as rhizo=iU' "$lc_ir_fx/claim.err"; then
    ok "1p: an install that leaves rhizo unconfigured fails naming dpkg's state and never reboots"
  else
    bad "1p: an install leaving rhizo unconfigured read '${lc_ir_out:-nothing}': $(grep FAIL "$lc_ir_fx/claim.err" | head -1)"
  fi
  rm -rf "$lc_ir_fx"
  unset lc_ir_fx lc_ir_out

  lc_ul_out=$( (
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
    cli="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/src/install/cli/rhizo.sh"
    set_line=$(bash -c "${INSTALLER_MASKSET_CMD% /usr/bin/rhizo} $cli" | sed -n 's/^MASKSET //p')
    kept=$'androidd.service loaded 1\nrhizo-prepare.service loaded 1\nrhizo-hostfs.service masked 1\nrhizo-app-events.service masked 1'
    printf 'SERVER_KEPT=[%s]\n' "$(installer_unit_load_problems server "$set_line" "$kept")"
    printf 'DESKTOP_MASKED=[%s]\n' "$(installer_unit_load_problems desktop "$set_line" "$kept")"
    printf 'SERVER_ANDROIDD=[%s]\n' "$(installer_unit_load_problems server "$set_line" $'androidd.service masked 1')"
    printf 'SERVER_UNMASKED=[%s]\n' "$(installer_unit_load_problems server "$set_line" $'rhizo-hostfs.service loaded 1')"
    printf 'UNREAD=[%s]\n' "$(installer_unit_load_problems '' "$set_line" $'androidd.service loaded 1')"
    printf 'NOFILE=[%s]\n' "$(installer_unit_load_problems desktop "$set_line" $'androidd.service loaded 0')"
    read_ok=$'PROFILE server\nMASKSET '"$set_line"$'\n'"$(sed 's/^/UNIT /' <<<"$kept")"$'\nDONE'
    printf 'READ_KEPT=[%s]\n' "$(installer_unit_read_problems "$read_ok")"
    printf 'READ_CUT=[%s]\n' "$(installer_unit_read_problems "${read_ok%$'\n'DONE}")"
    printf 'READ_NOSET=[%s]\n' "$(installer_unit_read_problems $'PROFILE server\nMASKSET \nUNIT rhizo-hostfs.service masked 1\nDONE')"
  ) 2>&1 )
  if grep -qx 'SERVER_KEPT=\[\]' <<<"$lc_ul_out" && grep -qx 'READ_KEPT=\[\]' <<<"$lc_ul_out"; then
    ok "1p2: a kept server profile's masked rhizo-hostfs/rhizo-app-events pass the post-install unit check, read whole"
  else
    bad "1p2: a kept server profile's masked desktop units read: $(grep -E '^(SERVER|READ)_KEPT=' <<<"$lc_ul_out" | tr '\n' ' ')"
  fi
  for lc_ul_case in 'DESKTOP_MASKED=\[rhizo-hostfs.service is masked, the desktop profile leaves it loaded' \
                    'READ_CUT=\[incomplete read' \
                    'READ_NOSET=\[the installed CLI named no SERVER_MASKED_UNITS' \
                    'SERVER_ANDROIDD=\[androidd.service is masked, the server profile leaves it loaded' \
                    'SERVER_UNMASKED=\[rhizo-hostfs.service is loaded, the server profile leaves it masked' \
                    "UNREAD=\[the host's profile read '<empty>'" \
                    'NOFILE=\[androidd.service has no unit file'; do
    if grep -q "^$lc_ul_case" <<<"$lc_ul_out"; then
      ok "1p2: the unit check fails by name: ${lc_ul_case//\\/}"
    else
      bad "1p2: the unit check did not fail as '${lc_ul_case//\\/}': $(tr '\n' '|' <<<"$lc_ul_out")"
    fi
  done
  unset lc_ul_out lc_ul_case

  lc_qs_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_qs_fx/bin" "$lc_qs_fx/sys/loop7"
  head -c 65536 /dev/urandom > "$lc_qs_fx/data.img"
  printf '#!/bin/sh\n[ "$1" = is-active ] && cat "%s/unit" 2>/dev/null\nexit 0\n' "$lc_qs_fx" > "$lc_qs_fx/bin/systemctl"
  printf '#!/bin/sh\n[ -e "%s/lsfail" ] && exit 1\n[ -e "%s/looped" ] && echo "/dev/loop7: []: (%s/data.img)"\nexit 0\n' "$lc_qs_fx" "$lc_qs_fx" "$lc_qs_fx" > "$lc_qs_fx/bin/losetup"
  printf '#!/bin/sh\nexit 0\n' > "$lc_qs_fx/bin/sleep"
  chmod +x "$lc_qs_fx/bin/"*
  awk 'NR == 1 { print $3; exit }' /proc/self/mountinfo > "$lc_qs_fx/sys/loop7/dev"
  lc_qs_cmd="${LC_DATA_IMG_QUIESCENT_CMD/img=\/var\/lib\/rhizo\/data.img/img=$lc_qs_fx/data.img}"
  lc_qs_cmd="${lc_qs_cmd//\/sys\/block\//$lc_qs_fx/sys/}"
  lc_qs_run() { PATH="$lc_qs_fx/bin:$PATH" bash -c "$lc_qs_cmd" 2>/dev/null; }
  lc_qs_want=$(sha256sum "$lc_qs_fx/data.img" | cut -d' ' -f1)
  echo inactive > "$lc_qs_fx/unit"
  lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)")
  if [[ "$lc_qs_got" == "$lc_qs_want" ]]; then
    ok "1p3: a stopped sandbox's unheld data.img hashes to its own sha"
  else
    bad "1p3: a quiescent fixture image read '$lc_qs_got', wanted $lc_qs_want"
  fi
  # shellcheck disable=SC2217
  sleep 30 < "$lc_qs_fx/data.img" & lc_qs_holder=$!
  if lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)"); then
    bad "1p3: an image a process holds open still hashed ($lc_qs_got)"
  elif [[ "$lc_qs_got" == *"OPEN "*"$lc_qs_holder"* ]]; then
    ok "1p3: an image a process holds open is refused, naming the holder"
  else
    bad "1p3: an image a process holds open was refused without naming pid $lc_qs_holder: $lc_qs_got"
  fi
  kill "$lc_qs_holder" 2>/dev/null; wait "$lc_qs_holder" 2>/dev/null
  touch "$lc_qs_fx/looped"
  if lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)"); then
    bad "1p3: an image a mounted loop device backs still hashed ($lc_qs_got)"
  elif [[ "$lc_qs_got" == *"MOUNTED /dev/loop7"* ]]; then
    ok "1p3: an image a mounted loop device backs is refused, naming the loop"
  else
    bad "1p3: an image a mounted loop backs was refused without naming /dev/loop7: $lc_qs_got"
  fi
  bash -c 'exec -a /usr/lib/rhizo/launcher3.py sleep 300' & lc_qs_payload=$!
  for _ in $(seq 1 100); do
    tr '\0' '\n' < "/proc/$lc_qs_payload/cmdline" 2>/dev/null | grep -qxF /usr/lib/rhizo/launcher3.py && break
    sleep 0.05
  done
  lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)")
  if [[ "$lc_qs_got" == *"MOUNTED /dev/loop7"* && "$lc_qs_got" != *RELEASED* ]] \
     && kill -0 "$lc_qs_payload" 2>/dev/null; then
    ok "1p3: a launcher-named process sharing the mount is not killed, and the still-mounted image is refused"
  else
    bad "1p3: payload pid $lc_qs_payload was killed or the mounted image not refused: $lc_qs_got"
  fi
  kill "$lc_qs_payload" 2>/dev/null; wait "$lc_qs_payload" 2>/dev/null
  lc_qs_mm=$(cat "$lc_qs_fx/sys/loop7/dev")
  echo 4095:1048575 > "$lc_qs_fx/sys/loop7/dev"
  if lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)"); then
    bad "1p3: an image a loop still backs, mounted nowhere, still hashed ($lc_qs_got)"
  elif [[ "$lc_qs_got" == *"MOUNTED none"* && "$lc_qs_got" == *"ATTACHED /dev/loop7"* ]]; then
    ok "1p3: an image a loop still backs is refused on ATTACHED even with nothing mounting it"
  else
    bad "1p3: an attached, unmounted loop was refused without naming it on ATTACHED: $lc_qs_got"
  fi
  echo "$lc_qs_mm" > "$lc_qs_fx/sys/loop7/dev"
  rm -f "$lc_qs_fx/looped"
  touch "$lc_qs_fx/lsfail"
  if lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)"); then
    bad "1p3: an image read with a failing losetup -j still hashed ($lc_qs_got)"
  elif [[ "$lc_qs_got" == *"ATTACHED unknown(losetup-j-failed)"* ]]; then
    ok "1p3: a failing losetup -j refuses the image as ATTACHED unknown"
  else
    bad "1p3: a failing losetup -j was not refused as unknown: $lc_qs_got"
  fi
  rm -f "$lc_qs_fx/lsfail"
  mkdir -p "$lc_qs_fx/sys/loop7/loop"
  for lc_qs_bf in "$lc_qs_fx/data.img" "$lc_qs_fx/data.img (deleted)"; do
    printf '%s\n' "$lc_qs_bf" > "$lc_qs_fx/sys/loop7/loop/backing_file"
    if lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)"); then
      bad "1p3: an image sysfs names as '$lc_qs_bf' still hashed ($lc_qs_got)"
    elif [[ "$lc_qs_got" == *"ATTACHED /dev/loop7"* ]]; then
      ok "1p3: a loop whose sysfs backing_file reads '${lc_qs_bf##*/}' is refused though losetup -j lists none"
    else
      bad "1p3: sysfs backing_file '$lc_qs_bf' was not refused naming /dev/loop7: $lc_qs_got"
    fi
  done
  ln -s "$lc_qs_fx" "$lc_qs_fx/alias"
  lc_qs_alias="${lc_qs_cmd/img=$lc_qs_fx\/data.img/img=$lc_qs_fx/alias/data.img}"
  for lc_qs_bf in "$lc_qs_fx/data.img" "$lc_qs_fx/data.img (deleted)"; do
    printf '%s\n' "$lc_qs_bf" > "$lc_qs_fx/sys/loop7/loop/backing_file"
    if lc_qs_got=$(lc_data_img_sha_of "$(PATH="$lc_qs_fx/bin:$PATH" bash -c "$lc_qs_alias" 2>/dev/null)"); then
      bad "1p3: an image named through a symlink, with sysfs naming '$lc_qs_bf', still hashed ($lc_qs_got)"
    elif [[ "$lc_qs_got" == *"ATTACHED /dev/loop7"* ]]; then
      ok "1p3: a loop whose backing_file reads the canonical '${lc_qs_bf##*/}' holds an image named through a symlink"
    else
      bad "1p3: an image named through a symlink was not refused naming /dev/loop7: $lc_qs_got"
    fi
  done
  printf '%s\n' "/var/lib/rhizo/instances/2/data.img" > "$lc_qs_fx/sys/loop7/loop/backing_file"
  lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)")
  if [[ "$lc_qs_got" == "$lc_qs_want" ]]; then
    ok "1p3: a loop backing another instance's image does not hold this one"
  else
    bad "1p3: another instance's loop refused this image: $lc_qs_got"
  fi
  rm -rf "$lc_qs_fx/sys/loop7/loop"
  touch "$lc_qs_fx/looped"
  rm -f "$lc_qs_fx/looped"
  mkdir -p "$lc_qs_fx/nofuser" "$lc_qs_fx/fuserfail"
  for lc_qs_tool in bash cat cut grep head mktemp readlink rm seq sha256sum sync tr; do
    ln -s "$(command -v "$lc_qs_tool")" "$lc_qs_fx/nofuser/$lc_qs_tool"
  done
  ln -s "$lc_qs_fx/bin/"* "$lc_qs_fx/nofuser/"
  if lc_qs_got=$(lc_data_img_sha_of "$(PATH="$lc_qs_fx/nofuser" bash -c "$lc_qs_cmd" 2>/dev/null)"); then
    bad "1p3: an image read with no fuser installed still hashed ($lc_qs_got)"
  elif [[ "$lc_qs_got" == *"OPEN unknown(no-fuser)"* ]]; then
    ok "1p3: an image read with no fuser installed is refused as OPEN unknown"
  else
    bad "1p3: an image read with no fuser installed was not refused as OPEN unknown(no-fuser): $lc_qs_got"
  fi
  printf '#!/bin/sh\necho "fuser: cannot read /proc" >&2\nexit 1\n' > "$lc_qs_fx/fuserfail/fuser"
  chmod +x "$lc_qs_fx/fuserfail/fuser"
  if lc_qs_got=$(lc_data_img_sha_of "$(PATH="$lc_qs_fx/fuserfail:$lc_qs_fx/bin:$PATH" bash -c "$lc_qs_cmd" 2>/dev/null)"); then
    bad "1p3: an image read with a failing fuser still hashed ($lc_qs_got)"
  elif [[ "$lc_qs_got" == *"OPEN unknown(fuser-failed"* ]]; then
    ok "1p3: an image read with a failing fuser is refused as OPEN unknown"
  else
    bad "1p3: an image read with a failing fuser was not refused as OPEN unknown(fuser-failed...): $lc_qs_got"
  fi
  for lc_qs_st in activating deactivating reloading; do
    echo "$lc_qs_st" > "$lc_qs_fx/unit"
    if lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)"); then
      bad "1p3: an image under an androidd.service reading $lc_qs_st still hashed ($lc_qs_got)"
    elif [[ "$lc_qs_got" == *"UNIT $lc_qs_st"* ]]; then
      ok "1p3: an image under an androidd.service reading $lc_qs_st is refused"
    else
      bad "1p3: a unit reading $lc_qs_st was refused without naming it: $lc_qs_got"
    fi
  done
  echo failed > "$lc_qs_fx/unit"
  lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)")
  if [[ "$lc_qs_got" == "$lc_qs_want" ]]; then
    ok "1p3: an image under a failed androidd.service hashes"
  else
    bad "1p3: an image under a failed androidd.service read '$lc_qs_got', wanted $lc_qs_want"
  fi
  echo active > "$lc_qs_fx/unit"
  if lc_qs_got=$(lc_data_img_sha_of "$(lc_qs_run)"); then
    bad "1p3: an image under a still-active androidd.service still hashed ($lc_qs_got)"
  elif [[ "$lc_qs_got" == *"UNIT active"* ]]; then
    ok "1p3: an image under a still-active androidd.service is refused"
  else
    bad "1p3: an active unit was refused without naming it: $lc_qs_got"
  fi
  if lc_qs_got=$(lc_data_img_sha_of $'UNIT inactive\nMOUNTED none\nATTACHED none\nOPEN none\nSHA '"$lc_qs_want"); then
    bad "1p3: a read with no DONE still produced a sha ($lc_qs_got)"
  else
    ok "1p3: a read that never finished yields no sha"
  fi
  rm -rf "$lc_qs_fx"
  unset -f lc_qs_run
  unset lc_qs_fx lc_qs_cmd lc_qs_want lc_qs_got lc_qs_holder lc_qs_payload lc_qs_mm lc_qs_bf lc_qs_alias lc_qs_tool lc_qs_st

  lc_vb_fx=$(mktemp -d) || exit 1
  lc_vb_cmd="${LC_VBMETA_ATTACHED_CMD//\/sys\/block\//$lc_vb_fx/}"
  lc_vb_run() { bash -c "$lc_vb_cmd" 2>/dev/null; }
  lc_vb_loop() {
    mkdir -p "$lc_vb_fx/loop$1/loop"
    printf '%s\n' "$2" > "$lc_vb_fx/loop$1/loop/backing_file"
  }
  if lc_vb_got=$(lc_vbmeta_detached_of "$(lc_vb_run)"); then
    ok "1p3v: no loop devices at all reads detached"
  else
    bad "1p3v: an empty /sys/block was not read detached: $lc_vb_got"
  fi
  lc_vb_loop 0 /var/lib/rhizo/data.img
  lc_vb_loop 2 /srv/other/vbmeta.img
  if lc_vb_got=$(lc_vbmeta_detached_of "$(lc_vb_run)"); then
    ok "1p3v: loops on other files, another vbmeta.img included, read detached"
  else
    bad "1p3v: loops on other files were read as the packaged vbmeta.img: $lc_vb_got"
  fi
  for lc_vb_bf in "/usr/lib/rhizo/vbmeta.img" "/usr/lib/rhizo/vbmeta.img (deleted)"; do
    lc_vb_loop 1 "$lc_vb_bf"
    if lc_vb_got=$(lc_vbmeta_detached_of "$(lc_vb_run)"); then
      bad "1p3v: a loop on '$lc_vb_bf' still read detached"
    elif [[ "$lc_vb_got" == *"backs /usr/lib/rhizo/vbmeta.img after the remove: /dev/loop1" ]]; then
      ok "1p3v: a loop on '$lc_vb_bf' fails the claim, naming /dev/loop1"
    else
      bad "1p3v: a loop on '$lc_vb_bf' failed without naming /dev/loop1: $lc_vb_got"
    fi
  done
  rm -rf "$lc_vb_fx/loop1"
  mkdir -p "$lc_vb_fx/loop3/loop/backing_file"
  if lc_vb_got=$(lc_vbmeta_detached_of "$(lc_vb_run)"); then
    bad "1p3v: an unreadable backing_file still read detached"
  elif [[ "$lc_vb_got" == *"unknown(/dev/loop3-backing_file-unreadable)"* ]]; then
    ok "1p3v: an unreadable backing_file reads unknown, never none"
  else
    bad "1p3v: an unreadable backing_file failed without naming it unknown: $lc_vb_got"
  fi
  if lc_vb_got=$(lc_vbmeta_detached_of $'VBMETA_ATTACHED none'); then
    bad "1p3v: a read with no DONE still read detached"
  else
    ok "1p3v: a read that never finished is not detached"
  fi
  if lc_vb_got=$(lc_vbmeta_detached_of $'noise\nDONE'); then
    bad "1p3v: a finished read with no VBMETA_ATTACHED line still read detached"
  elif [[ "$lc_vb_got" == *"<no VBMETA_ATTACHED line>"* ]]; then
    ok "1p3v: a finished read with no VBMETA_ATTACHED line is not detached, and says so"
  else
    bad "1p3v: a finished read with no VBMETA_ATTACHED line failed for another reason: $lc_vb_got"
  fi
  if lc_vbmeta_was_attached $'VBMETA_ATTACHED none\nDONE'; then
    bad "1p3v: a pre-stop read of none counted as a loop to release"
  else
    ok "1p3v: a pre-stop read of none fails the precondition"
  fi
  if lc_vbmeta_was_attached $'VBMETA_ATTACHED unknown(/dev/loop3-backing_file-unreadable)\nDONE'; then
    bad "1p3v: a pre-stop read of only unknown counted as a loop to release"
  else
    ok "1p3v: a pre-stop read naming only unknown fails the precondition"
  fi
  if lc_vbmeta_was_attached $'VBMETA_ATTACHED /dev/loop1'; then
    bad "1p3v: an unfinished pre-stop read counted as a loop to release"
  else
    ok "1p3v: an unfinished pre-stop read fails the precondition"
  fi
  if lc_vbmeta_was_attached $'VBMETA_ATTACHED /dev/loop1 unknown(/dev/loop3-backing_file-unreadable)\nDONE' \
     && lc_vbmeta_was_attached $'VBMETA_ATTACHED /dev/loop12\nDONE'; then
    ok "1p3v: a pre-stop read naming a /dev/loopN meets the precondition"
  else
    bad "1p3v: a pre-stop read naming a /dev/loopN did not meet the precondition"
  fi
  rm -rf "$lc_vb_fx"
  unset -f lc_vb_run lc_vb_loop
  unset lc_vb_fx lc_vb_cmd lc_vb_got lc_vb_bf

  lc_ls_fx=$(mktemp -d) || exit 1
  printf 'Num       RefCount Protocol Flags    Type St Inode Path\n0000000000000000: 00000002 00000000 00010000 0001 01 4242 %s/xdg/wayland-1\n0000000000000000: 00000002 00000000 00010000 0001 01 4243 /run/dbus/system_bus_socket\n' "$lc_ls_fx" > "$lc_ls_fx/unix"
  lc_ls_out=$(bash -c "${DESK_WAYLAND_LISTENERS//\/proc\/net\/unix/$lc_ls_fx/unix}" 2>/dev/null)
  if [[ "$lc_ls_out" == "$lc_ls_fx/xdg/wayland-1" ]]; then
    ok "1p4: the socket census names a bound wayland socket from the unix table and nothing else"
  else
    bad "1p4: the socket census over a one-compositor table read '${lc_ls_out:-<empty>}'"
  fi
  lc_ls_out=$(bash -c "${DESK_WAYLAND_LISTENERS//\/proc\/net\/unix/$lc_ls_fx/absent}" 2>/dev/null)
  if assert_no_wayland_socket "1p4 selftest" "$lc_ls_out" 1 >/dev/null 2>&1; then
    bad "1p4: an unreadable unix table passed as no compositor socket"
  else
    ok "1p4: an unreadable unix table fails the no-compositor check instead of reading as empty"
  fi
  rm -rf "$lc_ls_fx"
  unset lc_ls_fx lc_ls_out

  lc_md_fx=$(mktemp -d) || exit 1
  lc_md_run() {
    (
      lc_md_mode="${3:-}"
      mkdir -p "$lc_md_fx/proc/8719" "$lc_md_fx/proc/net"
      printf 'Name:\tpython3\nUid:\t%s\t%s\t%s\t%s\n' "${2:-110}" "${2:-110}" "${2:-110}" "${2:-110}" > "$lc_md_fx/proc/8719/status"
      { echo '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops'
        echo '  812: 00000000:0043 00000000:0000 07 00000000:00000000 00:00000000 00000000   110        0 31337 2 0000000000000000 0'
        echo ' 1107: 3500007F:0035 00000000:0000 07 00000000:00000000 00:00000000 00000000   991        0 20021 2 0000000000000000 0'
        [[ -n "$1" ]] && printf '%s\n' "$1"; } > "$lc_md_fx/proc/net/udp"
      echo '  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops' > "$lc_md_fx/proc/net/udp6"
      ssh_vm() {
        local body="${*: -1}"
        case "$body" in
          *"MainPID"*) echo 8719 ;;
          *"ps -o args="*) echo "/usr/bin/python3 /usr/lib/rhizo/netbridged/netbridged.py --services dhcp,dns,proxy,ra" ;;
          *"sport = :5353"*) printf -- '---LC-SPLIT---\nUNCONN 0      0      0.0.0.0:67 0.0.0.0:*\n%s\n' "$PROBE_DONE_TAG" ;;
          *"getent passwd avahi systemd-resolve"*) [[ "$lc_md_mode" == responders ]] && printf 'avahi:104\nsystemd-resolve:974\n'; return 0 ;;
          *"/proc/net/udp"*)
            body=${body//\/proc\//$lc_md_fx/proc/}
            [[ "$lc_md_mode" == cut ]] && body=${body%; echo *}
            bash -c "$body" ;;
          *) return 255 ;;
        esac
      }
      FAILED=0
      lc_assert_network.mdns-off-default >/dev/null 2>"$lc_md_fx/err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_md_case() {
    local got; got=$(lc_md_run "$2" "$3" "$4")
    if [[ "$5" == pass ]]; then
      [[ "$got" == "RC=0 FAILED=0" ]] && return 0
    elif [[ "$got" == "RC=1 FAILED=1" ]] && grep -qF -- "$5" "$lc_md_fx/err"; then
      return 0
    fi
    bad "1q: network.mdns-off-default, $1, read '${got:-nothing}': $(grep FAIL "$lc_md_fx/err" | head -1)"
    return 1
  }
  lc_md_bad=0
  lc_md_case "netbridged's account on :67, nothing on :5353" "" 110 "" pass || lc_md_bad=1
  lc_md_case "avahi's uid on :5353" '  900: 00000000:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000   104        0 40404 2 0000000000000000 0' 110 "" \
    "something is bound to udp :5353 in the host netns with mdns off by default (not rhizo-netbridged's account uid 110, but worth flagging): 5353:104" || lc_md_bad=1
  lc_md_responders='  900: 00000000:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000   104        0 40404 2 0000000000000000 0
  902: 00000000:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000   974        0 40406 2 0000000000000000 0'
  lc_md_case "avahi's and systemd-resolved's own accounts on :5353" "$lc_md_responders" 110 responders pass || lc_md_bad=1
  lc_md_case "another account beside the host's responders" "$lc_md_responders"'
  903: 00000000:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000   105        0 40407 2 0000000000000000 0' 110 responders \
    "(not rhizo-netbridged's account uid 110, but worth flagging): 5353:105" || lc_md_bad=1
  lc_md_case "netbridged's own uid on :5353" '  901: 00000000:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000   110        0 40405 2 0000000000000000 0' 110 "" \
    "rhizo-netbridged's own account (uid 110) holds a udp :5353 socket" || lc_md_bad=1
  lc_md_case "a MainPID running as another uid than :67's owner" "" 111 "" "found no udp :67 (dhcp) socket owned by rhizo-netbridged's account (uid 111" || lc_md_bad=1
  lc_md_case "a MainPID running as root" "" 0 "" "runs as uid '0', not its own unprivileged account" || lc_md_bad=1
  lc_md_case "a read that never finished" "" 110 cut "never completed" || lc_md_bad=1
  (( lc_md_bad )) || ok "1q: network.mdns-off-default reads /proc/net/udp{,6} by owner uid: passes netbridged's account on :67 with nothing on :5353 and with only avahi's and systemd-resolved's accounts there, and fails by name on another uid or netbridged's own on :5353, a :67 owner that is not the MainPID's uid, a root MainPID and a cut read"
  rm -rf "$lc_md_fx"
  unset -f lc_md_run lc_md_case
  unset lc_md_fx lc_md_bad

  lc_dn_fx=$(mktemp -d) || exit 1
  lc_dn_run() {
    (
      lc_dn_line="$2"
      echo '[netbridged] NB_DHCP_ACK ip=192.168.100.2' > "$lc_dn_fx/nb.log"
      ssh_vm() {
        local body="${*: -1}"
        [[ "$body" == *rhizo-netbridged.log* ]] || return 0
        ( eval "${body//\/tmp\/rhizo-netbridged.log/$lc_dn_fx/nb.log}" )
      }
      lc_resolve_init() { echo 4242; }
      android_sh() {
        case "$2" in
          'getprop net.dns1') return 0 ;;
          'dumpsys connectivity')
            [[ "$lc_dn_line" == rc=* ]] && return "${lc_dn_line#rc=}"
            [[ "$lc_dn_line" == dump:* ]] && { printf '%b' "${lc_dn_line#dump:}"; return 0; }
            printf 'Active default network: 100\n\nCurrent Networks:\n  NetworkAgentInfo{network{100}  handle{430570166285}  ni{ETHERNET CONNECTED extra: }\n  lp{{InterfaceName: eth0 LinkAddresses: [ 192.168.100.2/24 ] DnsAddresses: [ %s ] Domains: null MTU: 0}}\n' "$lc_dn_line" ;;
          'ip -4 -o addr show scope global') echo '2: eth0    inet 192.168.100.2/24 brd 192.168.100.255 scope global eth0' ;;
          *'nc -4 -z -w 10 dns.google 443'*)
            printf '[netbridged] NB_DNS_QUERY qname=dns.google qtype=A src=192.168.100.2:40000 proto=udp\n[netbridged] NB_DNS_FORWARD qname=dns.google upstream=10.0.2.3 rcode=0 ms=3.0\n' >> "$lc_dn_fx/nb.log"
            echo 'NC_RC=0' ;;
          *) return 255 ;;
        esac
      }
      FAILED=0
      "lc_assert_$1" >/dev/null 2>"$lc_dn_fx/err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_dn_bad=0
  for lc_dn_claim in network.dns capability.network-services; do
    lc_dn_out=$(lc_dn_run "$lc_dn_claim" /192.168.100.1)
    [[ "$lc_dn_out" == "RC=0 FAILED=0" ]] \
      || { bad "1q2: $lc_dn_claim with DnsAddresses [ /192.168.100.1 ] read '$lc_dn_out': $(grep FAIL "$lc_dn_fx/err" | head -1)"; lc_dn_bad=1; }
    lc_dn_out=$(lc_dn_run "$lc_dn_claim" /10.0.2.3,/192.168.100.10)
    [[ "$lc_dn_out" == "RC=1 FAILED=1" ]] && grep -qF '/10.0.2.3,/192.168.100.10' "$lc_dn_fx/err" \
      || { bad "1q2: $lc_dn_claim with another resolver and a longer address read '$lc_dn_out': $(grep FAIL "$lc_dn_fx/err" | head -1)"; lc_dn_bad=1; }
    lc_dn_out=$(lc_dn_run "$lc_dn_claim" rc=97)
    [[ "$lc_dn_out" == "RC=1 FAILED=1" ]] && grep -qE 'no DnsAddresses read|<unread>' "$lc_dn_fx/err" \
      || { bad "1q2: $lc_dn_claim with android_sh unreachable read '$lc_dn_out': $(grep FAIL "$lc_dn_fx/err" | head -1)"; lc_dn_bad=1; }
    lc_dn_out=$(lc_dn_run "$lc_dn_claim" /10.0.2.3,/192.168.100.1)
    [[ "$lc_dn_out" == "RC=1 FAILED=1" ]] && grep -qF '/10.0.2.3,/192.168.100.1' "$lc_dn_fx/err" \
      || { bad "1q2: $lc_dn_claim with a second resolver beside /192.168.100.1 read '$lc_dn_out': $(grep FAIL "$lc_dn_fx/err" | head -1)"; lc_dn_bad=1; }
    lc_dn_nai='  NetworkAgentInfo{network{%s}  handle{1}  ni{%s CONNECTED extra: } created=x  lp{{InterfaceName: %s LinkAddresses: [ ] DnsAddresses: [ %s ] UsePrivateDns: false PrivateDnsServerName: null ValidatedPrivateDnsAddresses: [ /9.9.9.9 ] Domains: null MTU: 0}}  nc{}}\n'
    lc_dn_out=$(lc_dn_run "$lc_dn_claim" "dump:Active default network: 100\n\nCurrent Networks:\n$(printf "$lc_dn_nai" 101 VPN tun0 /192.168.100.1)\n$(printf "$lc_dn_nai" 100 ETHERNET eth0 /10.0.2.3)\n")
    [[ "$lc_dn_out" == "RC=1 FAILED=1" ]] && grep -qF '/10.0.2.3' "$lc_dn_fx/err" \
      || { bad "1q2: $lc_dn_claim passed on a non-default network's /192.168.100.1 listed ahead of the default's /10.0.2.3: '$lc_dn_out' $(grep FAIL "$lc_dn_fx/err" | head -1)"; lc_dn_bad=1; }
    lc_dn_out=$(lc_dn_run "$lc_dn_claim" "dump:Active default network: 100\n\nCurrent Networks:\n$(printf "$lc_dn_nai" 101 VPN tun0 /10.0.2.3)\n$(printf "$lc_dn_nai" 100 ETHERNET eth0 /192.168.100.1)\n")
    [[ "$lc_dn_out" == "RC=0 FAILED=0" ]] \
      || { bad "1q2: $lc_dn_claim failed the default network's /192.168.100.1 behind a non-default network's /10.0.2.3: '$lc_dn_out' $(grep FAIL "$lc_dn_fx/err" | head -1)"; lc_dn_bad=1; }
    lc_dn_out=$(lc_dn_run "$lc_dn_claim" "dump:Active default network: none\n\nCurrent Networks:\n$(printf "$lc_dn_nai" 100 ETHERNET eth0 /192.168.100.1)")
    [[ "$lc_dn_out" == "RC=1 FAILED=1" ]] \
      || { bad "1q2: $lc_dn_claim passed with no active default network: '$lc_dn_out'"; lc_dn_bad=1; }
  done
  (( lc_dn_bad )) || ok "1q2: network.dns and capability.network-services pass the active default network's own DnsAddresses reading exactly /192.168.100.1 while getprop net.dns1 reads empty, and fail by name on another resolver, a longer address sharing its prefix, a second resolver beside it, a non-default network's list, no default network and an android_sh that never ran"
  rm -rf "$lc_dn_fx"
  unset -f lc_dn_run
  unset lc_dn_fx lc_dn_bad lc_dn_claim lc_dn_out lc_dn_nai

  lc_ns_fx=$(mktemp -d) || exit 1
  lc_ns_run() {
    (
      lc_ns_nc="$1" lc_ns_log="$2"
      lc_ns_good='[netbridged] NB_DNS_QUERY qname=dns.google qtype=A src=192.168.100.50:40211 proto=udp\n[netbridged] NB_DNS_FORWARD qname=dns.google upstream=10.0.2.3 rcode=0 ms=12.4\n'
      case "$2" in
        earlier) printf '%b' "$lc_ns_good" ;;
        *) printf '[netbridged] NB_DHCP_ACK ip=192.168.100.50\n' ;;
      esac > "$lc_ns_fx/nb.log"
      lc_ns_cut=0; [[ "$2" == cut ]] && lc_ns_cut=1
      lc_resolve_init() { echo 4242; }
      android_sh() {
        case "$2" in
          'ip -4 -o addr show scope global') echo '2: eth0    inet 192.168.100.50/24 brd 192.168.100.255 scope global eth0' ;;
          'dumpsys connectivity') printf 'Active default network: 100\n\nCurrent Networks:\n  NetworkAgentInfo{network{100}  handle{430570166285}  ni{ETHERNET CONNECTED extra: }\n  lp{{InterfaceName: eth0 LinkAddresses: [ 192.168.100.50/24 ] DnsAddresses: [ /192.168.100.1 ] Domains: null MTU: 0}}\n' ;;
          'ping -c 1 -W 3 dns.google') printf 'PING dns.google (8.8.8.8) 56(84) bytes of data.\n\n--- dns.google ping statistics ---\n1 packets transmitted, 0 received, 100%% packet loss, time 0ms\n' ;;
          *'nc -4 -z -w 10 dns.google 443'*)
            [[ "$lc_ns_nc" == dead ]] && return 97
            case "$lc_ns_log" in
              good|cut) printf '%b' "$lc_ns_good" ;;
              servfail) printf '[netbridged] NB_DNS_QUERY qname=dns.google qtype=A src=192.168.100.50:40211 proto=udp\n[netbridged] NB_DNS_SERVFAIL qname=dns.google reason=upstream-timeout\n' ;;
              othersrc) printf '[netbridged] NB_DNS_QUERY qname=dns.google qtype=A src=192.168.100.77:40211 proto=udp\n[netbridged] NB_DNS_FORWARD qname=dns.google upstream=10.0.2.3 rcode=0 ms=12.4\n' ;;
              earlier) ;;
              *) printf '[netbridged] NB_DNS_QUERY qname=example.test qtype=A src=192.168.100.50:40211 proto=udp\n' ;;
            esac >> "$lc_ns_fx/nb.log"
            case "$lc_ns_nc" in
              ok) echo 'NC_RC=0' ;;
              *) printf 'nc: Timeout\nNC_RC=1\n' ;;
            esac ;;
          *) return 255 ;;
        esac
      }
      ssh_vm() {
        local body="${*: -1}"
        [[ "$body" == *rhizo-netbridged.log* ]] || return 255
        (( lc_ns_cut )) && return 255
        ( eval "${body//\/tmp\/rhizo-netbridged.log/$lc_ns_fx/nb.log}" )
      }
      FAILED=0
      lc_assert_capability.network-services >/dev/null 2>"$lc_ns_fx/err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_ns_bad=0
  for lc_ns_case in "ok|good|" \
                    "timeout|good|no TCP connection to dns.google:443 completed" \
                    "dead|good|the TCP probe inside the sandbox never completed" \
                    "ok|none|logged no query for dns.google" \
                    "ok|servfail|logged no NOERROR upstream answer" \
                    "ok|cut|never completed" \
                    "ok|earlier|logged no query for dns.google from the sandbox's lease 192.168.100.50 after the probe began" \
                    "ok|othersrc|logged no query for dns.google from the sandbox's lease 192.168.100.50 after the probe began"; do
    IFS='|' read -r lc_ns_nc lc_ns_log lc_ns_want <<<"$lc_ns_case"
    lc_ns_out=$(lc_ns_run "$lc_ns_nc" "$lc_ns_log")
    if [[ -z "$lc_ns_want" ]]; then
      [[ "$lc_ns_out" == "RC=0 FAILED=0" ]] \
        || { bad "1q3: capability.network-services on an ICMP-less rig with a working forwarder and TCP read '$lc_ns_out': $(grep FAIL "$lc_ns_fx/err" | head -1)"; lc_ns_bad=1; }
    elif [[ "$lc_ns_out" != "RC=1 FAILED=1" ]] || ! grep -qF "$lc_ns_want" "$lc_ns_fx/err"; then
      bad "1q3: capability.network-services with nc=$lc_ns_nc log=$lc_ns_log read '$lc_ns_out', want RC=1 naming '$lc_ns_want': $(grep FAIL "$lc_ns_fx/err" | head -1)"
      lc_ns_bad=1
    fi
  done
  (( lc_ns_bad )) || ok "1q3: capability.network-services passes on an ICMP-less rig from the forwarder's own log and a TCP handshake, and fails by name on a timed-out or dead probe, no logged query, no NOERROR answer, a cut log read, a query from earlier in the start and a query from another source"
  rm -rf "$lc_ns_fx"
  unset -f lc_ns_run
  unset lc_ns_fx lc_ns_bad lc_ns_case lc_ns_nc lc_ns_log lc_ns_want lc_ns_out

  lc_pd_run() {
    (
      lc_pd_rc="$1"
      printf '[rhizo]\nprofile = server\n' > "$lc_pd_fx/policy.conf"
      python3() { echo 1; }
      systemctl() { return 0; }
      pgrep() { return 1; }
      fake_test() { if [[ "$1" == audio.out ]]; then return "$lc_pd_rc"; fi; return 1; }
      ssh_vm() {
        local body="${*: -1}"
        body="${body//\/etc\/rhizo\/policy.conf/$lc_pd_fx/policy.conf}"
        body="${body//\/usr\/lib\/rhizo\/tools\/capability-allowed.sh/fake_test}"
        ( eval "$body" )
      }
      FAILED=0
      lc_assert_policy.absent-is-defaults server >/dev/null 2>"$lc_pd_fx/claim.err"
      echo "RC=$? FAILED=$FAILED CONF=$(tr '\n' '|' < "$lc_pd_fx/policy.conf" 2>/dev/null)"
    )
  }
  lc_pd_fx=$(mktemp -d) || exit 1
  lc_pd_out=$(lc_pd_run 0)
  if [[ "$lc_pd_out" == "RC=0 FAILED=0 CONF=[rhizo]|profile = server|" ]]; then
    ok "1r: policy.absent-is-defaults on a server host passes on audio.out's own gate and puts policy.conf back"
  else
    bad "1r: policy.absent-is-defaults on a server host whose audio.out gate allows it read '${lc_pd_out:-nothing}': $(grep FAIL "$lc_pd_fx/claim.err" | head -1)"
  fi
  lc_pd_out=$(lc_pd_run 1)
  if [[ "$lc_pd_out" == "RC=1 FAILED=1 "* ]] && grep -q "audio.out's own gate withheld it on this server host" "$lc_pd_fx/claim.err"; then
    ok "1r: policy.absent-is-defaults on a server host fails by name when audio.out's gate withholds it"
  else
    bad "1r: policy.absent-is-defaults on a server host whose audio.out gate withholds it read '${lc_pd_out:-nothing}': $(grep FAIL "$lc_pd_fx/claim.err" | head -1)"
  fi
  rm -rf "$lc_pd_fx"
  unset -f lc_pd_run
  unset lc_pd_fx lc_pd_out

  lc_ud_run() {
    (
      lc_ud_mode="$1"
      printf '[rhizo]\nprofile = server\n' > "$lc_ud_fx/policy.conf"
      echo 0 > "$lc_ud_fx/n"
      printf '%032x' 1 > "$lc_ud_fx/inv"
      rm -f "$lc_ud_fx"/journal-*
      [[ "$lc_ud_mode" == leftover-deny ]] \
        && echo "/etc/rhizo/policy.conf line 1: not a key=value line -- denying every optional capability" > "$lc_ud_fx/journal-$(cat "$lc_ud_fx/inv")"
      sleep() { SECONDS=$(( SECONDS + ${1%.*} )); }
      python3() { echo 1; }
      pgrep() { return 1; }
      fake_test() { return 1; }
      systemctl() {
        local n inv
        case "$1 ${*: -1}" in
          "show rhizo-server-idle.service") cat "$lc_ud_fx/inv" ;;
          "show rhizo-audiod.service") echo "" ;;
          "start rhizo-server-idle.service"|"restart rhizo-server-idle.service")
            [[ "$lc_ud_mode" == same-inv ]] && return 0
            n=$(( $(cat "$lc_ud_fx/n") + 1 )); echo "$n" > "$lc_ud_fx/n"
            inv=$(printf '%032x' $(( n + 1 ))); echo "$inv" > "$lc_ud_fx/inv"
            if grep -q 'not an ini' "$lc_ud_fx/policy.conf" && [[ "$lc_ud_mode" != ignores ]]; then
              case "$lc_ud_mode" in
                absent|leftover-deny) : > "$lc_ud_fx/journal-$inv" ;;
                *) echo "/etc/rhizo/policy.conf line 1: not a key=value line -- denying every optional capability" > "$lc_ud_fx/journal-$inv" ;;
              esac
              echo "server.idle_stop_s=0 -- idle-stop is off, exiting" >> "$lc_ud_fx/journal-$inv"
            elif [[ "$lc_ud_mode" == no-restore ]] && ! grep -q 'not an ini' "$lc_ud_fx/policy.conf"; then
              echo "server.idle_stop_s=0 -- idle-stop is off, exiting" > "$lc_ud_fx/journal-$inv"
            else
              echo "started this run's own session count at 0 -- the 0 adb entries already in the conntrack table, phantom or real, are never counted" > "$lc_ud_fx/journal-$inv"
            fi ;;
        esac
        return 0
      }
      journalctl() { cat "$lc_ud_fx/journal-${1#_SYSTEMD_INVOCATION_ID=}" 2>/dev/null; }
      ssh_vm() {
        local body="${*: -1}"
        body="${body//\/etc\/rhizo\/policy.conf/$lc_ud_fx/policy.conf}"
        body="${body//\/usr\/lib\/rhizo\/tools\/capability-allowed.sh/fake_test}"
        ( eval "$body" )
      }
      FAILED=0
      lc_assert_policy.unparsable-denies-optional server >/dev/null 2>"$lc_ud_fx/claim.err"
      echo "RC=$? FAILED=$FAILED CONF=$(tr '\n' '|' < "$lc_ud_fx/policy.conf" 2>/dev/null)"
    )
  }
  lc_ud_fx=$(mktemp -d) || exit 1
  lc_ud_out=$(lc_ud_run good)
  if [[ "$lc_ud_out" == "RC=0 FAILED=0 CONF=[rhizo]|profile = server|" ]]; then
    ok "1r2: policy.unparsable-denies-optional on a server host passes on policy_or_deny's denial and rhizo-server-idle's own exit under a new invocation, audiod masked, and puts policy.conf back"
  else
    bad "1r2: policy.unparsable-denies-optional on a server host with audiod masked read '${lc_ud_out:-nothing}': $(grep FAIL "$lc_ud_fx/claim.err" | head -1)"
  fi
  for lc_ud_case in "ignores|started this run's own session count" \
                    "absent|and '<none within 30s>', wanted" \
                    "leftover-deny|and '<none within 30s>', wanted" \
                    "same-inv|InvocationID did not change" \
                    "no-restore|not its session-count seed"; do
    lc_ud_out=$(lc_ud_run "${lc_ud_case%%|*}")
    if [[ "$lc_ud_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "${lc_ud_case#*|}" "$lc_ud_fx/claim.err"; then
      ok "1r2: policy.unparsable-denies-optional on a server host fails by name when the daemon case is ${lc_ud_case%%|*}"
    else
      bad "1r2: policy.unparsable-denies-optional on a server host (${lc_ud_case%%|*}) read '${lc_ud_out:-nothing}', want RC=1 naming '${lc_ud_case#*|}': $(grep FAIL "$lc_ud_fx/claim.err" | head -1)"
    fi
  done
  rm -rf "$lc_ud_fx"
  unset -f lc_ud_run
  unset lc_ud_fx lc_ud_out lc_ud_case

  lc_ar_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_ar_fx/bin" "$lc_ar_fx/cli-adbkey"
  echo private > "$lc_ar_fx/cli-adbkey/adbkey"
  echo "QAAAAlcoperatorkey operator@rig" > "$lc_ar_fx/cli-adbkey/adbkey.pub"
  cat > "$lc_ar_fx/bin/adb" <<EOF
#!/bin/bash
fx=$lc_ar_fx
key="\${ADB_VENDOR_KEYS:-\$HOME/.android/adbkey}"
blob=\$(awk '{print \$1; exit}' "\$key.pub" 2>/dev/null)
serial=""; [[ "\$1" == -s ]] && { serial="\$2"; shift 2; }
case "\$1" in
  connect)
    if [[ "\$2" == 192.168.100.50:5555 && "\$(cat \$fx/idle_on)" == 1 && "\$(cat \$fx/subscribed)" == 1 ]]; then
      echo 1 > \$fx/counted; echo "count=1 NEW tcp reply-src=192.168.100.50:5555" >> \$fx/idle-journal
    fi ;;
  disconnect)
    if [[ "\$2" == 192.168.100.50:5555 && "\$(cat \$fx/counted)" == 1 ]]; then
      echo 0 > \$fx/counted
      [[ "\$(cat \$fx/mode)" == no-stop ]] || { echo 1 > \$fx/armed; echo "armed a 60s idle-stop timer (rhizo-server-idle-stop.timer)" >> \$fx/idle-journal; }
    fi ;;
  get-state)
    if [[ "\$(cat \$fx/booted)" != 1 ]] || { [[ "\$serial" == 127.0.0.1:* ]] && ! grep -q 'DNAT' \$fx/nat; }; then
      echo "error: device offline" >&2; exit 1
    fi
    if [[ -n "\$blob" ]] && grep -qF "\$blob" \$fx/adb_keys; then echo device; else echo "error: device unauthorized." >&2; exit 1; fi ;;
esac
exit 0
EOF
  chmod +x "$lc_ar_fx/bin/adb"
  lc_ar_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      lc_ar_mode="$2"
      # shellcheck disable=SC2034
      EV="$lc_ar_fx" RHIZO_ADB="$lc_ar_fx/bin/adb" ADB_PORT=5556 ANDROID_ADB_SERVER_PORT=5138
      INIT=4242 APP_PKG="" APP_ACT=""
      printf '[rhizo]\nprofile = server\n' > "$lc_ar_fx/policy.conf"
      echo 1 > "$lc_ar_fx/running"; echo 1 > "$lc_ar_fx/booted"; echo 100 > "$lc_ar_fx/uptime"; : > "$lc_ar_fx/nat"
      echo '[   10.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0' > "$lc_ar_fx/dmesg"
      echo "$lc_ar_mode" > "$lc_ar_fx/mode"
      for f in idle_on subscribed counted armed netlink_reads; do echo 0 > "$lc_ar_fx/$f"; done
      : > "$lc_ar_fx/idle-journal"; rm -f "$lc_ar_fx/armed_at"
      : > "$lc_ar_fx/stop-journal"
      [[ "$lc_ar_mode" == other-stop ]] \
        && echo '1789990000.100000 rhizo-pristine systemd[1]: Started rhizo-server-idle-stop.service - /usr/bin/systemctl stop androidd.service.' > "$lc_ar_fx/stop-journal"
      systemctl() { return 0; }
      if [[ "$lc_ar_mode" == unregistered ]]; then echo "QAAAAsomeoneelse x@y" > "$lc_ar_fx/adb_keys"; else cp "$lc_ar_fx/cli-adbkey/adbkey.pub" "$lc_ar_fx/adb_keys"; fi
      rm -rf "$lc_ar_fx/guest-adb"
      lc_ar_path="$lc_ar_fx/bin:$PATH"
      [[ "$lc_ar_mode" == no-adb ]] && lc_ar_path="$lc_ar_fx/no-such-dir"
      sleep() { SECONDS=$(( SECONDS + ${1%.*} )); }
      dmesg() { [[ "$(cat "$lc_ar_fx/running")" == 1 ]] && echo 1 > "$lc_ar_fx/booted"; cat "$lc_ar_fx/dmesg"; }
      lc_ar_start() {
        local up
        echo 1 > "$lc_ar_fx/running"; echo 0 > "$lc_ar_fx/booted"
        up=$(( $(cat "$lc_ar_fx/uptime") + 1 ))
        printf '[ %d.000000] RHIZO_MARKER launch_start sandbox=0\n' "$up" >> "$lc_ar_fx/dmesg"
        if grep -q 'adb_reach = lan' "$lc_ar_fx/policy.conf"; then
          if [[ "$lc_ar_mode" == refused ]]; then
            printf '[ %d.100000] server.adb_reach=lan refused to arm: no operator key at /etc/rhizo/adb_keys, rule not created\n' "$up" >> "$lc_ar_fx/dmesg"
            : > "$lc_ar_fx/nat"
          else
            printf '[ %d.100000] server.adb_reach=lan armed: DNAT ens4:5555 -> 192.168.100.50:5555\n' "$up" >> "$lc_ar_fx/dmesg"
            printf -- '-P PREROUTING ACCEPT\n-A PREROUTING -i ens4 -p tcp -m tcp --dport 5555 -j DNAT --to-destination 192.168.100.50:5555\n' > "$lc_ar_fx/nat"
          fi
        else
          : > "$lc_ar_fx/nat"
        fi
        printf '[ %d.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0\n' $(( up + 3 )) >> "$lc_ar_fx/dmesg"
      }
      ssh_vm() {
        local body="${*: -1}" up n
        case "$body" in
          'systemctl stop androidd.service') echo 0 > "$lc_ar_fx/running"; echo 0 > "$lc_ar_fx/booted" ;;
          'systemctl start androidd.service') [[ "$(cat "$lc_ar_fx/running")" == 1 ]] || lc_ar_start ;;
          'systemctl restart androidd.service') lc_ar_start ;;
          *'systemctl is-active androidd.service'*)
            if [[ "$(cat "$lc_ar_fx/armed")" == 1 ]]; then
              [[ -f "$lc_ar_fx/armed_at" ]] || echo "$SECONDS" > "$lc_ar_fx/armed_at"
              if (( SECONDS - $(cat "$lc_ar_fx/armed_at") >= 60 )); then
                echo 0 > "$lc_ar_fx/armed"; echo 0 > "$lc_ar_fx/running"; echo 0 > "$lc_ar_fx/booted"
                [[ "$lc_ar_mode" == other-stop ]] \
                  || printf '%d.441317 rhizo-pristine systemd[1]: Started rhizo-server-idle-stop.service - /usr/bin/systemctl stop androidd.service.\n' \
                       $(( 1790000000 + SECONDS )) >> "$lc_ar_fx/stop-journal"
              fi
            fi
            if [[ "$(cat "$lc_ar_fx/running")" == 1 ]]; then echo active; else echo inactive; fi
            [[ "$body" == *'echo DONE'* ]] && echo DONE ;;
          'systemctl restart rhizo-server-idle.service')
            for n in subscribed counted netlink_reads; do echo 0 > "$lc_ar_fx/$n"; done
            if grep -q 'idle_stop_s = 60' "$lc_ar_fx/policy.conf"; then
              echo 1 > "$lc_ar_fx/idle_on"
              echo "started this run's own session count at 0 -- the 0 adb entries already in the conntrack table, phantom or real, are never counted" >> "$lc_ar_fx/idle-journal"
            else
              echo 0 > "$lc_ar_fx/idle_on"
            fi ;;
          *'MainPID --value rhizo-server-idle.service'*) echo 777 ;;
          *'/proc/777/fd/'*) echo 'socket:[4242]' ;;
          'cat /proc/net/netlink')
            n=$(( $(cat "$lc_ar_fx/netlink_reads") + 1 )); echo "$n" > "$lc_ar_fx/netlink_reads"
            (( n >= 2 )) && [[ "$(cat "$lc_ar_fx/idle_on")" == 1 && "$lc_ar_mode" != never-subscribes ]] && echo 1 > "$lc_ar_fx/subscribed"
            echo 'sk               Eth Pid        Groups   Rmem     Wmem     Dump  Locks    Drops    Inode'
            if [[ "$(cat "$lc_ar_fx/subscribed")" == 1 ]]; then
              echo 'ffff8a4100000000 12  3381289462 00000005 0        0        0     2        0        4242'
            else
              echo 'ffff8a4100000000 12  3381289462 00000000 0        0        0     2        0        4242'
            fi ;;
          *'journalctl -u rhizo-server-idle.service'*) cat "$lc_ar_fx/idle-journal" ;;
          *'ActiveEnterTimestamp --value rhizo-server-idle-stop.service'*) echo "$PROBE_DONE_TAG" ;;
          *'journalctl -u rhizo-server-idle-stop.service'*)
            ( journalctl() { cat "$lc_ar_fx/stop-journal"; }; eval "$body" ) ;;
          *"date -d '"*) ( eval "$body" ) ;;
          *'date +%s'*) echo $(( 1790000000 + SECONDS )) ;;
          *'/proc/uptime'*) up=$(( $(cat "$lc_ar_fx/uptime") + 1 )); echo "$up" > "$lc_ar_fx/uptime"; echo "$up.00" ;;
          *'*"init second_stage"*'*) [[ "$(cat "$lc_ar_fx/booted")" == 1 ]] && echo 4242 ;;
          *'> /dev/kmsg'*) up=$(cat "$lc_ar_fx/uptime"); printf '[ %d.050000] %s\n' "$up" "$(sed -n "s/^echo '\\([^']*\\)'.*/\\1/p" <<<"$body")" >> "$lc_ar_fx/dmesg" ;;
          *'ip -4 route show default'*) echo ens4 ;;
          *'iptables -t nat -S PREROUTING'*) cat "$lc_ar_fx/nat" ;;
          *'/dev/tcp/'*)
            [[ "$lc_ar_mode" == auto-start && "$(cat "$lc_ar_fx/running")" == 0 ]] && lc_ar_start
            [[ "$(cat "$lc_ar_fx/booted")" == 1 ]] ;;
          *'rhizo status --json'*)
            if [[ "$(cat "$lc_ar_fx/booted")" == 1 ]]; then
              printf '{"profile":"server","boot_completed":"1","adb":"192.168.100.50:5555"}\n'
            else
              printf '{"profile":"server","boot_completed":"","adb":""}\n'
            fi ;;
          *)
            body="${body//\/etc\/rhizo\/policy.conf/$lc_ar_fx/policy.conf}"
            body="${body//\/etc\/rhizo\/adb_keys/$lc_ar_fx/adb_keys}"
            body="${body//\/tmp\/lc-guest-adb/$lc_ar_fx/guest-adb}"
            ( PATH="$lc_ar_path"; eval "$body" ) ;;
        esac
      }
      android_sh() {
        [[ "$(cat "$lc_ar_fx/booted")" == 1 ]] || return 0
        echo "2: eth0    inet 192.168.100.50/24 brd 192.168.100.255 scope global eth0"
      }
      FAILED=0
      "lc_assert_$1" >/dev/null 2>"$lc_ar_fx/claim.err"
      echo "RC=$? FAILED=$FAILED CONF=$(tr '\n' '|' < "$lc_ar_fx/policy.conf" 2>/dev/null)"
    )
  }
  for lc_ar_case in "server.adb-reach-host|good|" \
                    "server.adb-reach-host|no-adb|the guest has no adb client" \
                    "server.adb-reach-host|unregistered|is not in the guest's /etc/rhizo/adb_keys" \
                    "server.adb-reach-lan|good|" \
                    "server.adb-reach-lan|refused|the launcher refused to arm the rule" \
                    "server.explicit-start-only|good|" \
                    "server.explicit-start-only|auto-start|'active' after a connect attempt" \
                    "server.idle-stop|good|" \
                    "server.idle-stop|never-subscribes|held no joined NETLINK_NETFILTER socket" \
                    "server.idle-stop|no-stop|never logged 'armed a 60s idle-stop timer'" \
                    "server.idle-stop|other-stop|is not after this cycle's own"; do
    IFS='|' read -r lc_ar_claim lc_ar_mode lc_ar_want <<<"$lc_ar_case"
    lc_ar_out=$(lc_ar_run "$lc_ar_claim" "$lc_ar_mode")
    if [[ -z "$lc_ar_want" ]]; then
      if [[ "$lc_ar_out" == "RC=0 FAILED=0 CONF=[rhizo]|profile = server|" ]]; then
        ok "1r3: $lc_ar_claim passes on a Type=exec guest whose adbd authorizes only the registered operator key, and leaves policy.conf as it found it"
      else
        bad "1r3: $lc_ar_claim on the good scripted guest read '${lc_ar_out:-nothing}': $(grep FAIL "$lc_ar_fx/claim.err" | head -1)"
      fi
    elif [[ "$lc_ar_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "$lc_ar_want" "$lc_ar_fx/claim.err"; then
      ok "1r3: $lc_ar_claim fails by name on a guest where $lc_ar_mode: $lc_ar_want"
    else
      bad "1r3: $lc_ar_claim ($lc_ar_mode) read '${lc_ar_out:-nothing}', want RC=1 naming '$lc_ar_want': $(grep FAIL "$lc_ar_fx/claim.err" | head -1)"
    fi
  done
  rm -rf "$lc_ar_fx"
  unset -f lc_ar_run
  unset lc_ar_fx lc_ar_out lc_ar_case lc_ar_claim lc_ar_mode lc_ar_want

  lc_is_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_is_fx/bin" "$lc_is_fx/cli-adbkey"
  echo private > "$lc_is_fx/cli-adbkey/adbkey"
  echo "QAAAAlcoperatorkey operator@rig" > "$lc_is_fx/cli-adbkey/adbkey.pub"
  cat > "$lc_is_fx/bin/adb" <<EOF
#!/bin/bash
key="\${ADB_VENDOR_KEYS:-\$HOME/.android/adbkey}"
blob=\$(awk '{print \$1; exit}' "\$key.pub" 2>/dev/null)
[[ "\$1" == -s ]] && shift 2
[[ "\$1" == get-state ]] || exit 0
if [[ -n "\$blob" ]] && grep -qF "\$blob" $lc_is_fx/root/etc/rhizo/adb_keys; then echo device; else echo "error: device unauthorized." >&2; exit 1; fi
EOF
  chmod +x "$lc_is_fx/bin/adb"
  lc_is_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      lc_is_mode="$2" R="$lc_is_fx/root"
      EV="$lc_is_fx" INIT=4242
      rm -rf "$R"; mkdir -p "$R/var/lib/rhizo/templates" "$R/etc/rhizo/instances"
      cp "$lc_is_fx/cli-adbkey/adbkey.pub" "$R/etc/rhizo/adb_keys"
      echo 1 > "$lc_is_fx/booted"; echo 100 > "$lc_is_fx/uptime"; echo 0 > "$lc_is_fx/clone_reads"; echo 0 > "$lc_is_fx/clone_on"
      echo '[   10.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0' > "$lc_is_fx/dmesg"
      sleep() { SECONDS=$(( SECONDS + ${1%.*} )); }
      dmesg() {
        local n up
        echo 1 > "$lc_is_fx/booted"
        if [[ "$(cat "$lc_is_fx/clone_on")" == 1 ]]; then
          n=$(( $(cat "$lc_is_fx/clone_reads") + 1 )); echo "$n" > "$lc_is_fx/clone_reads"; up=$(cat "$lc_is_fx/uptime")
          if (( n == 2 )); then
            case "$lc_is_mode" in
              armed) printf '[ %d.2] L3: server.adb_reach=lan armed: DNAT ens4:5555 -> 192.168.161.50:5555\n' "$up" >> "$lc_is_fx/dmesg" ;;
              never) : ;;
              *) printf '[ %d.2] L3: RHIZO_MARKER adb_lan_refused=instance_above_zero\n[ %d.2] L3: server.adb_reach=lan refused to arm: RHIZO_SANDBOX_ID=61: the DNAT target is single-instance only, rule not created\n' "$up" "$up" >> "$lc_is_fx/dmesg" ;;
            esac
          fi
        fi
        cat "$lc_is_fx/dmesg"
      }
      lc_is_key() { sha256sum "$1" | cut -c1-12; }
      lc_rhizo() {
        local up id name t k
        [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
        case "$*" in
          "snapshot -i 0 "*)
            name="$4"; printf 'tmpl-bytes %s\n' "$name" > "$lc_is_fx/tmpl"; k=$(lc_is_key "$lc_is_fx/tmpl")
            t="/var/lib/rhizo/templates/data-template.$name.$k.img"; mv "$lc_is_fx/tmpl" "$R$t"; echo meta > "$R$t.meta"
            echo "[rhizo] stopping androidd.service (state active)" >&2
            echo 0 > "$lc_is_fx/booted"; up=$(( $(cat "$lc_is_fx/uptime") + 1 ))
            printf '[ %d.000000] RHIZO_MARKER launch_start sandbox=0\n[ %d.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0\n' "$up" $(( up + 3 )) >> "$lc_is_fx/dmesg"
            echo "RHIZO_SNAPSHOT name=$name key=$k path=$t" ;;
          "instance add "*)
            id="$3"; name="${5:-}"; mkdir -p "$R/var/lib/rhizo/instances/$id"
            printf 'RHIZO_SANDBOX_ID=%s\n' "$id" > "$R/etc/rhizo/instances/$id.env"
            if [[ -n "$name" ]]; then
              t=$(ls "$R/var/lib/rhizo/templates/data-template.$name."*.img)
              case "$lc_is_mode" in
                shared) ln "$t" "$R/var/lib/rhizo/instances/$id/data.img" ;;
                other-key) echo other-bytes > "$R/var/lib/rhizo/instances/$id/data.img" ;;
                *) cp "$t" "$R/var/lib/rhizo/instances/$id/data.img" ;;
              esac
            fi
            echo "RHIZO_INSTANCE_ADDED id=$id env=/etc/rhizo/instances/$id.env data=/var/lib/rhizo/instances/$id/data.img from=${name:-none}" ;;
          "instance remove "*) rm -rf "$R/etc/rhizo/instances/$3.env" "$R/var/lib/rhizo/instances/$3"; echo "RHIZO_INSTANCE_REMOVED id=$3 env=removed data=removed trees=absent" ;;
          "pool set "*) echo "RHIZO_POOL k=$3 members=$3" ;;
          "pool status") echo "RHIZO_POOL k=1 members=1 pending=0" ;;
          "instance allocate")
            if [[ "$lc_is_mode" == no-endpoint ]]; then
              echo "[rhizo] instance 1 allocated with no address over /run/rhizo-1/data/local/tmp/rhizo-probe.sock: no endpoint printed"
              echo "RHIZO_ALLOCATED id=1 adb="
            else
              echo "RHIZO_ALLOCATED id=1 adb=192.168.101.50:5555"
            fi ;;
        esac
      }
      ssh_vm() {
        local body="${*: -1}" up
        case "$body" in
          *'/proc/uptime'*) up=$(( $(cat "$lc_is_fx/uptime") + 1 )); echo "$up" > "$lc_is_fx/uptime"; echo "$up.00" ;;
          *'*"init second_stage"*'*) [[ "$(cat "$lc_is_fx/booted")" == 1 ]] && echo 4242 ;;
          'systemctl start androidd@61.service') echo 1 > "$lc_is_fx/clone_on" ;;
          'systemctl stop androidd@61.service') echo 0 > "$lc_is_fx/clone_on" ;;
          *'> /dev/kmsg'*) up=$(cat "$lc_is_fx/uptime"); printf '[ %d.050000] %s\n' "$up" "$(sed -n "s/^echo '\\([^']*\\)'.*/\\1/p" <<<"$body")" >> "$lc_is_fx/dmesg" ;;
          *)
            body="${body//\/var\/lib\/rhizo/$R/var/lib/rhizo}"
            body="${body//\/etc\/rhizo/$R/etc/rhizo}"
            body="${body//\/tmp\/lc-guest-adb/$lc_is_fx/guest-adb}"
            ( PATH="$lc_is_fx/bin:$PATH"; eval "$body" ) ;;
        esac
      }
      FAILED=0
      "lc_assert_$1" >/dev/null 2>"$lc_is_fx/claim.err"
      echo "RC=$? FAILED=$FAILED INIT=$INIT LEFT=$(cd "$R/var/lib/rhizo" && ls templates; for f in "$R/etc/rhizo/instances"/*; do [[ -e "$f" && "${f##*/}" != 90.env ]] && printf '%s ' "${f##*/}"; done)"
    )
  }
  for lc_is_case in "server.instance-add|good|" \
                    "server.instance-add|shared|is the template's own inode" \
                    "server.instance-add|other-key|not the template's key" \
                    "server.instance-allocate|good|" \
                    "server.instance-allocate|no-endpoint|no full RHIZO_ALLOCATED line" \
                    "server.snapshot-clone|good|" \
                    "server.snapshot-clone|armed|ARMED the rule" \
                    "server.snapshot-clone|never|did not print RHIZO_MARKER adb_lan_refused=instance_above_zero within 120s"; do
    IFS='|' read -r lc_is_claim lc_is_mode lc_is_want <<<"$lc_is_case"
    lc_is_out=$(lc_is_run "$lc_is_claim" "$lc_is_mode")
    if [[ -z "$lc_is_want" ]]; then
      if [[ "$lc_is_out" == "RC=0 FAILED=0 INIT=4242 LEFT=" ]]; then
        ok "1r4: $lc_is_claim passes against the documented CLI, waits on instance 0's return, and leaves no template or clone behind"
      else
        bad "1r4: $lc_is_claim on the good scripted guest read '${lc_is_out:-nothing}': $(grep FAIL "$lc_is_fx/claim.err" | head -1)"
      fi
    elif [[ "$lc_is_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "$lc_is_want" "$lc_is_fx/claim.err"; then
      ok "1r4: $lc_is_claim fails by name on a guest where $lc_is_mode: $lc_is_want"
    else
      bad "1r4: $lc_is_claim ($lc_is_mode) read '${lc_is_out:-nothing}', want RC=1 naming '$lc_is_want': $(grep FAIL "$lc_is_fx/claim.err" | head -1)"
    fi
  done
  rm -rf "$lc_is_fx"
  unset -f lc_is_run
  unset lc_is_fx lc_is_out lc_is_case lc_is_claim lc_is_mode lc_is_want

  lc_ca_run() {
    (
      lc_ca_mode="$1"
      EV="$lc_ca_ev"
      logcat_vm() { [[ "$1" == 4242 && "$*" == *'-d -s rhizo-uinput:V'* ]] && echo 'I rhizo-uinput: open(/dev/uinput) FAILED errno=13 (Permission denied)'; }
      INIT=4242 APP_PKG=com.jeffliu.balancetheball APP_ACT=.MainActivity LC_POOL_BOOT_T=60
      lc_ca_start=4242; [[ "$lc_ca_mode" == earlier-logs ]] && lc_ca_start=1850
      lc_ca_later=""
      [[ "$lc_ca_mode" == reused-pid ]] && lc_ca_later=', "[l3] androidd-stop: supervisor parked, stack is stopped", "[l3] START entry=selinux_setup pid=5000", "[l3] RHIZO_PHASE B:launcher_start"'
      lc_rhizo() { case "$*" in *'pool status'*) echo "RHIZO_POOL k=1 members=1" ;; esac; return 0; }
      android_sh() { [[ "$2" == 'dumpsys battery' ]] && echo '  level: 50'; return 0; }
      ssh_vm() {
        local body="${*: -1}"
        case "$body" in
          *'MainPID --value androidd.service'*) printf '4242\n%s\n' "$PROBE_DONE_TAG" ;;
          *'/run/rhizo-wayland/'*) echo "$PROBE_DONE_TAG" ;;
          *'lc-api-client.py instances -'*) echo '{"instances": [{"id": 0, "unit": "androidd.service", "state": "active", "pooled": false}]}' ;;
          *'lc-api-client.py logs 0'*)
            printf '{"lines": ["[l3] androidd-stop: supervisor parked, stack is stopped", "[l3] START entry=selinux_setup pid=%s", "[l3] RHIZO_PHASE B:launcher_start", "[l3] supervisor forked as 4250; this process holds the unit"%s]}\n' "$lc_ca_start" "$lc_ca_later" ;;
          *'lc-api-client.py screenshot 0'*) echo '{"error": "no Wayland compositor socket found"}' ;;
          *'lc-api-client.py input 0 down 1 '*)
            if [[ "$lc_ca_mode" == input-refused ]]; then
              echo "{\"error\": \"instance 0's composer refused the injection: inject-failed id=1 reason=uinput-touch-failed\"}"
            else
              echo '{"injected": "down", "reply": "inject down id=1"}'
            fi ;;
          *'lc-api-client.py input 0 '*) echo "{\"error\": \"instance 0's composer refused the injection: inject-failed id=0 reason=unknown-display\"}" ;;
          *'lc-api-client.py set 0 battery 50 charging'*) echo 'RHIZO_API_RC=0' ;;
          *'lc-api-client.py install 0 '*) printf 'RHIZO_APP installed=%s version=1\nRHIZO_API_RC=0\n' "$APP_PKG" ;;
          *'lc-api-client.py launch 0 '*) printf 'RHIZO_LAUNCHED pkg=%s display=2 cdisplay=2\nRHIZO_API_RC=0\n' "$APP_PKG" ;;
          *'lc-api-client.py allocate -'*) printf 'RHIZO_ALLOCATED id=5 adb=192.168.105.50:5555\nRHIZO_API_RC=0\n' ;;
          *'lc-api-client.py release 5'*) printf 'RHIZO_RELEASED id=5\nRHIZO_API_RC=0\n' ;;
          *) return 0 ;;
        esac
      }
      FAILED=0
      lc_assert_server.control-api >/dev/null 2>"$lc_ca_err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_ca_err=$(mktemp) || exit 1
  lc_ca_ev=$(mktemp -d) || exit 1
  lc_ca_out=$(lc_ca_run good)
  if [[ "$lc_ca_out" == "RC=0 FAILED=0" ]]; then
    ok "1r5: server.control-api passes on a guest whose logs are the unit's own boot log and whose primary display is id 1"
  else
    bad "1r5: server.control-api on a guest whose primary display is id 1 read '$lc_ca_out': $(grep FAIL "$lc_ca_err" | head -3 | tr '\n' ' ')"
  fi
  lc_ca_out=$(lc_ca_run earlier-logs)
  if [[ "$lc_ca_out" == "RC=1 FAILED=1" ]] && grep -qF "no line naming this start's own MainPID 4242" "$lc_ca_err"; then
    ok "1r5: server.control-api fails by name on a logs tail from another start"
  else
    bad "1r5: server.control-api with a logs tail from another start read '$lc_ca_out': $(grep FAIL "$lc_ca_err" | head -1)"
  fi
  lc_ca_out=$(lc_ca_run reused-pid)
  if [[ "$lc_ca_out" == "RC=1 FAILED=1" ]] && grep -qF "its last START line names pid 5000, not this start's MainPID 4242" "$lc_ca_err"; then
    ok "1r5: server.control-api fails by name when MainPID only matches an earlier start's line"
  else
    bad "1r5: server.control-api with START pid=4242 then START pid=5000 read '$lc_ca_out': $(grep FAIL "$lc_ca_err" | head -1)"
  fi
  lc_ca_out=$(lc_ca_run input-refused)
  if [[ "$lc_ca_out" == "RC=1 FAILED=1" ]] \
      && grep -qF "composer logcat: $lc_ca_ev/server-control-api-composer-logcat.log" "$lc_ca_err" \
      && grep -qF 'open(/dev/uinput) FAILED errno=13' "$lc_ca_ev/server-control-api-composer-logcat.log"; then
    ok "1r5: server.control-api saves the composer's logcat lines and names the file when the input verb is refused"
  else
    bad "1r5: server.control-api with a refused input read '$lc_ca_out', log '$(head -c 200 "$lc_ca_ev/server-control-api-composer-logcat.log" 2>/dev/null)': $(grep FAIL "$lc_ca_err" | head -1)"
  fi
  rm -f "$lc_ca_err"
  rm -rf "$lc_ca_ev"
  unset -f lc_ca_run
  unset lc_ca_err lc_ca_out lc_ca_ev

  lc_pr_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      local -a cb
      local lc_pr_start="$4"
      echo '[    1.000000] Linux version 6.8.0-200-generic' > "$lc_pr_fx/dmesg"
      [[ "$3" == autostart ]] && echo '[   20.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0' >> "$lc_pr_fx/dmesg"
      echo 0 > "$lc_pr_fx/starts"
      sleep() { SECONDS=$(( SECONDS + ${1%.*} )); }
      dmesg() { cat "$lc_pr_fx/dmesg"; }
      ssh_vm() { [[ "${*: -1}" == dmesg* ]] && ( eval "${*: -1}" ); return 0; }
      lc_rhizo() {
        [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
        [[ "$*" == start ]] || return 2
        echo $(( $(cat "$lc_pr_fx/starts") + 1 )) > "$lc_pr_fx/starts"
        if [[ "$lc_pr_start" == start-fails ]]; then
          echo "RHIZO_FAIL androidd.service went failed with no 'init second_stage': see journalctl -u androidd.service"
          return 1
        fi
        echo '[   30.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0' >> "$lc_pr_fx/dmesg"
        echo "[rhizo] the sandbox is up and sys.boot_completed is 1" >&2
      }
      profile="$1"
      read -ra cb <<<"$2"
      FAILED=0
      "${cb[@]}" >/dev/null 2>"$lc_pr_fx/claim.err"
      echo "RC=$? FAILED=$FAILED STARTS=$(cat "$lc_pr_fx/starts")"
    )
  }
  lc_pr_fx=$(mktemp -d) || exit 1
  lc_pr_wired=$(declare -f lifecycle_run_cycle | grep -c '"lc_post_reboot_sandbox $profile 5"')
  lc_pr_old=$(lc_pr_run server "wait_sandbox_started 420 0" none start-ok)
  lc_pr_srv=$(lc_pr_run server "lc_post_reboot_sandbox server 5" none start-ok)
  lc_pr_desk=$(lc_pr_run sway "lc_post_reboot_sandbox sway 5" none start-ok)
  lc_pr_bad=$(lc_pr_run server "lc_post_reboot_sandbox server 5" none start-fails)
  if [[ "$lc_pr_wired" != 1 ]]; then
    bad "1s2: step 5 no longer hands the Ubuntu-update leg lc_post_reboot_sandbox as its boot callback"
  elif [[ "$lc_pr_old" != RC=1* ]]; then
    bad "1s2: the scripted explicit-start-only guest booted with nothing starting it ('$lc_pr_old')"
  elif [[ "$lc_pr_srv" != "RC=0 FAILED=0 STARTS=1" ]]; then
    bad "1s2: on a server guest after the reboot the boot callback read '$lc_pr_srv', want one rhizo start and the boot: $(grep FAIL "$lc_pr_fx/claim.err" | head -1)"
  elif [[ "$lc_pr_bad" != "RC=1 FAILED=1 STARTS=1" ]] || ! grep -qF '5: rhizo start after the reboot exited 1' "$lc_pr_fx/claim.err"; then
    bad "1s2: a failed rhizo start after the reboot read '$lc_pr_bad', want a failure naming it: $(grep FAIL "$lc_pr_fx/claim.err" | head -1)"
  elif [[ "$lc_pr_desk" != "RC=0 FAILED=0 STARTS=1" ]]; then
    bad "1s2: on a desktop guest, where nothing starts the on-demand sandbox at boot, the boot callback read '$lc_pr_desk', want one rhizo start and the boot"
  else
    ok "1s2: after step 5's reboot a server sandbox is started by rhizo start and waited on (a bare wait never boots it, a failed start fails by name); so is a desktop one, which nothing starts at boot either (on demand)"
  fi
  rm -rf "$lc_pr_fx"
  unset -f lc_pr_run
  unset lc_pr_fx lc_pr_wired lc_pr_old lc_pr_srv lc_pr_bad lc_pr_desk

  lc_fl_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_fl_fx/bin" "$lc_fl_fx/share"
  printf '#!/bin/sh\nexit 0\n' > "$lc_fl_fx/bin/scp"; chmod +x "$lc_fl_fx/bin/scp"
  : > "$lc_fl_fx/share/rhizo-test-fixture.apk"
  lc_fl_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      lc_fl_mode="$2"
      PATH="$lc_fl_fx/bin:$PATH" EV="$lc_fl_fx" REPO="$lc_fl_fx" VAR_DIR="$lc_fl_fx" SSH_OPTS=() SSH_PORT=2222 SSH_TARGET=root@127.0.0.1
      APP_PKG=com.jeffliu.balancetheball APP_ACT=com.jeffliu.balancetheball.GameActivity INIT=""
      echo 0 > "$lc_fl_fx/running"; echo 100 > "$lc_fl_fx/uptime"; echo 0 > "$lc_fl_fx/reads"
      echo '[   10.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0' > "$lc_fl_fx/dmesg"
      sleep() { SECONDS=$(( SECONDS + ${1%.*} )); }
      dmesg() { cat "$lc_fl_fx/dmesg"; }
      ssh_vm() {
        local body="${*: -1}" up
        case "$body" in
          'systemctl stop androidd.service') echo 0 > "$lc_fl_fx/running" ;;
          *'systemctl is-active androidd.service'*)
            if [[ "$(cat "$lc_fl_fx/running")" == 1 ]]; then echo active; else echo inactive; fi
            [[ "$body" == *'echo DONE'* ]] && echo DONE ;;
          'systemctl start androidd.service')
            if [[ "$(cat "$lc_fl_fx/running")" == 0 ]]; then
              echo 1 > "$lc_fl_fx/running"; up=$(( $(cat "$lc_fl_fx/uptime") + 1 ))
              printf '[ %d.000000] L3: RHIZO_MARKER launch_start sandbox=0\n[ %d.500000] L3: wayland socket NOT FOUND -- tried wayland-0 (absent)\n[ %d.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0\n' "$up" "$up" $(( up + 3 )) >> "$lc_fl_fx/dmesg"
            fi ;;
          *'/proc/uptime'*) up=$(( $(cat "$lc_fl_fx/uptime") + 1 )); echo "$up" > "$lc_fl_fx/uptime"; echo "$up.00" ;;
          *'*"init second_stage"*'*) [[ "$(cat "$lc_fl_fx/running")" == 1 ]] && echo 4242 ;;
          dmesg*) ( eval "$body" ) ;;
          *) return 0 ;;
        esac
        return 0
      }
      lc_rhizo() {
        [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
        [[ "$*" == "app install /root/rhizo-lifecycle-fixture.apk" ]] && echo "RHIZO_APP installed=$APP_PKG version=4"
      }
      android_sh() {
        local n
        case "$2" in
          'logcat -c') echo 0 > "$lc_fl_fx/reads" ;;
          "am start -W -n $APP_PKG/$APP_ACT") printf 'Starting: Intent { cmp=%s/.GameActivity }\nStatus: ok\nLaunchState: COLD\nActivity: %s/.GameActivity\nTotalTime: 99\nComplete\n' "$APP_PKG" "$APP_PKG" ;;
          'logcat -d -v threadtime')
            n=$(( $(cat "$lc_fl_fx/reads") + 1 )); echo "$n" > "$lc_fl_fx/reads"
            echo "09-24 15:00:55.134   219   481 I ActivityTaskManager: START u0 {cmp=$APP_PKG/.GameActivity} result code=0"
            if (( n >= 2 )) && [[ "$lc_fl_mode" != no-display ]]; then
              echo "09-24 15:00:55.231   219   238 I ActivityTaskManager: Displayed $APP_PKG/.GameActivity for user 0: +99ms"
            fi
            if [[ "$lc_fl_mode" == crash ]] || { [[ "$lc_fl_mode" == late-crash ]] && (( n >= 4 )); }; then
              printf '09-24 15:00:56.000  1294  1294 E AndroidRuntime: FATAL EXCEPTION: main\n09-24 15:00:56.000  1294  1294 E AndroidRuntime: Process: %s, PID: 1294\n' "$APP_PKG"
            fi
            if [[ "$lc_fl_mode" == late-anr ]] && (( n >= 4 )); then
              printf '09-24 15:00:58.000   219   240 E ActivityManager: ANR in %s (%s/.GameActivity)\n' "$APP_PKG" "$APP_PKG"
            fi ;;
          "pidof $APP_PKG")
            n=$(( $(cat "$lc_fl_fx/pidofs" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$lc_fl_fx/pidofs"
            case "$lc_fl_mode" in
              died|crash) ;;
              late-death) (( n <= 1 )) && echo 1294 ;;
              *) echo 1294 ;;
            esac ;;
        esac
      }
      FAILED=0
      "$1" cycle-server-final >/dev/null 2>"$lc_fl_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_fl_wired=$(declare -f lifecycle_run_cycle | grep -c 'lc_server_app_launches "cycle-$profile-final"')
  lc_fl_old_call=$(declare -f lifecycle_run_cycle | grep -c 'installer_assert_app_paints "cycle-$profile-final"')
  lc_fl_out=$(lc_fl_run installer_assert_app_paints good)
  if [[ "$lc_fl_wired" != 1 || "$lc_fl_old_call" != 0 ]]; then
    bad "1s3: step 10's server branch does not run lc_server_app_launches (wired=$lc_fl_wired) or still runs installer_assert_app_paints (old call=$lc_fl_old_call)"
  elif [[ "$lc_fl_out" != "RC=1 FAILED="[1-9]* ]] || ! grep -qF 'the sandbox bound no compositor socket' "$lc_fl_fx/claim.err"; then
    bad "1s3: installer_assert_app_paints on the headless guest read '$lc_fl_out'"
  else
    ok "1s3: step 10's server branch runs the headless launch check, not the compositor-socket one a server host can never pass"
  fi
  for lc_fl_case in "good|" \
                    "no-display|never logged 'ActivityTaskManager: Displayed com.jeffliu.balancetheball/.GameActivity'" \
                    "crash|crashed after its launch: 09-24 15:00:56.000  1294  1294 E AndroidRuntime: Process: com.jeffliu.balancetheball" \
                    "died|no com.jeffliu.balancetheball process is alive after its launch" \
                    "late-crash|crashed after its launch: 09-24 15:00:56.000  1294  1294 E AndroidRuntime: Process: com.jeffliu.balancetheball" \
                    "late-anr|ActivityManager: ANR in com.jeffliu.balancetheball" \
                    "late-death|no com.jeffliu.balancetheball process is alive after its launch"; do
    rm -f "$lc_fl_fx/pidofs"
    lc_fl_out=$(lc_fl_run lc_server_app_launches "${lc_fl_case%%|*}")
    if [[ -z "${lc_fl_case#*|}" ]]; then
      if [[ "$lc_fl_out" == "RC=0 FAILED=0" ]]; then
        ok "1s3: lc_server_app_launches passes on the fixture's headless launch: reinstalled, Status: ok, Displayed"
      else
        bad "1s3: lc_server_app_launches on a good headless launch read '$lc_fl_out': $(grep FAIL "$lc_fl_fx/claim.err" | head -1)"
      fi
    elif [[ "$lc_fl_out" == "RC=1 FAILED=1" ]] && grep -qF "${lc_fl_case#*|}" "$lc_fl_fx/claim.err"; then
      ok "1s3: lc_server_app_launches fails by name on a launch with ${lc_fl_case%%|*}"
    else
      bad "1s3: lc_server_app_launches (${lc_fl_case%%|*}) read '$lc_fl_out', want RC=1 naming '${lc_fl_case#*|}': $(grep FAIL "$lc_fl_fx/claim.err" | head -1)"
    fi
  done
  rm -rf "$lc_fl_fx"
  unset -f lc_fl_run
  unset lc_fl_fx lc_fl_out lc_fl_case lc_fl_wired lc_fl_old_call

  lc_s5_fx=$(mktemp -d) || exit 1
  lc_s5_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      lc_s5_mode="$1"
      echo 1 > "$lc_s5_fx/running"; echo 100 > "$lc_s5_fx/uptime"
      echo '[   10.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0' > "$lc_s5_fx/dmesg"
      sleep() { SECONDS=$(( SECONDS + ${1%.*} )); }
      dmesg() { cat "$lc_s5_fx/dmesg"; }
      APP_PKG=com.jeffliu.balancetheball APP_ACT=.MainActivity INIT=""
      ssh_vm() {
        local body="${*: -1}" up
        case "$body" in
          'systemctl stop androidd.service') [[ "$lc_s5_mode" == stuck ]] || echo 0 > "$lc_s5_fx/running" ;;
          *'systemctl is-active androidd.service'*)
            if [[ "$(cat "$lc_s5_fx/running")" == 1 ]]; then echo active; else echo inactive; fi
            echo DONE ;;
          'systemctl start androidd.service')
            if [[ "$(cat "$lc_s5_fx/running")" == 0 ]]; then
              echo 1 > "$lc_s5_fx/running"; up=$(( $(cat "$lc_s5_fx/uptime") + 3 ))
              printf '[ %d.000000] RHIZO_MARKER sys.boot_completed=1 sandbox=0\n' "$up" >> "$lc_s5_fx/dmesg"
            fi ;;
          *'/proc/uptime'*)
            [[ "$lc_s5_mode" == no-uptime ]] && return 255
            up=$(( $(cat "$lc_s5_fx/uptime") + 1 )); echo "$up" > "$lc_s5_fx/uptime"; echo "$up.00" ;;
          *'*"init second_stage"*'*) [[ "$(cat "$lc_s5_fx/running")" == 1 ]] && echo 4242 ;;
          dmesg*) ( eval "$body" ) ;;
        esac
        return 0
      }
      android_sh() {
        if [[ "$lc_s5_mode" == no-activity ]]; then
          printf 'Starting: Intent { cmp=%s }\nError: Activity class {%s} does not exist.\n' "$APP_PKG/$APP_ACT" "$APP_PKG/$APP_PKG$APP_ACT"
        else
          printf 'Starting: Intent { cmp=%s }\nStatus: ok\n' "$APP_PKG/$APP_ACT"
        fi
      }
      FAILED=0
      lc_step5_app_check server cycle-server-ubuntu-update >/dev/null 2>"$lc_s5_fx/claim.err"
      echo "RC=$? FAILED=$FAILED INIT=$INIT"
    )
  }
  lc_s5_out=$(lc_s5_run ok)
  if [[ "$lc_s5_out" == "RC=0 FAILED=0 INIT=4242" ]]; then
    ok "1s: step 5's server app check restarts the sandbox the leg left running and starts the fixture on the new boot"
  else
    bad "1s: step 5's server app check on an already-booted guest read '${lc_s5_out:-nothing}': $(grep FAIL "$lc_s5_fx/claim.err" | head -1)"
  fi
  for lc_s5_case in "stuck|androidd.service reads 'active' after systemctl stop" \
                    "no-uptime|uptime before the start read '<nothing>'" \
                    "no-activity|did not report Status: ok: Starting: Intent { cmp=com.jeffliu.balancetheball/.MainActivity } Error: Activity class"; do
    lc_s5_out=$(lc_s5_run "${lc_s5_case%%|*}")
    if [[ "$lc_s5_out" == "RC=1 FAILED=1 "* ]] && grep -qF "${lc_s5_case#*|}" "$lc_s5_fx/claim.err"; then
      ok "1s: step 5's server app check fails by name on a guest with ${lc_s5_case%%|*}: ${lc_s5_case#*|}"
    else
      bad "1s: step 5's server app check on a guest with ${lc_s5_case%%|*} read '${lc_s5_out:-nothing}', want RC=1 naming '${lc_s5_case#*|}': $(grep FAIL "$lc_s5_fx/claim.err" | head -1)"
    fi
  done
  if grep -q '"installer_assert_app_paints cycle-' <<<"$(declare -f lifecycle_run_cycle)"; then
    bad "1s: step 5 still hands the Ubuntu-update leg installer_assert_app_paints directly"
  fi
  rm -rf "$lc_s5_fx"
  unset -f lc_s5_run
  unset lc_s5_fx lc_s5_out lc_s5_case

  lc_fg_run() {
    local fg="$1" remove_out="$2"
    (
      fg_pid=$BASHPID
      command_not_found_handle() { printf 'CNF %s\n' "$1" >> "$fg/cnf"; kill -TERM "$fg_pid"; return 127; }
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/install-lib.sh"
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      REPO="$fg" VAR_DIR="$fg" WORKDIR="$fg" EV="$fg/ev" INIT=4242
      DESK_USER=deskuser DESK_HOME=/home/deskuser DESK_RUNTIME_DIR="$fg/run"
      DOWNLOADS=/home/deskuser/Downloads BUS_ADDR="unix:path=$fg/run/lc-bus"
      APP_PKG=com.rhizo.selftest LC_ENTRY_ID=rhizo-com.rhizo.selftest
      LC_ENTRY_PATH="$APPS_DIR/rhizo-com.rhizo.selftest.desktop" LC_FIXTURE_LABEL="Selftest App"
      LC_FIXTURE_SHA=$(sha256sum "$fg/share/rhizo-deskapp.apk" | cut -d' ' -f1)
      FG_REMOVE_OUT="$remove_out"
      fg_notify() {
        [[ -e "$fg/sink-on-private-bus" ]] || return 0
        echo "$1" > "$fg/last"; echo $(( $(cat "$fg/notifs") + 1 )) > "$fg/notifs"
      }
      SSH_OPTS=() SSH_PORT=0 SSH_TARGET=fake
      timeout() { shift; "$@"; }
      scp() { return 0; }
      gcmd_root() { return 0; }
      gcmd_user() {
        case "$1" in
          *"DBUS_SESSION_BUS_ADDRESS='$BUS_ADDR'"*notify-sink.py*) touch "$fg/sink-on-private-bus" ;;
          *"xargs -r kill"*) rm -f "$fg/sink-on-private-bus" ;;
        esac
        return 0
      }
      wait_guest() { return 0; }
      ssh_vm() {
        local body="${*: -1}" script path
        case "$body" in
          *"| base64 -d | runuser"*)
            script=$(sed -n "s/^echo '\([A-Za-z0-9+\/=]*\)' | base64 -d.*/\1/p" <<<"$body" | base64 -d)
            case "$script" in
              *"rhizo app remove"*)
                echo 0 > "$fg/installed"; fg_notify "Removed $LC_FIXTURE_LABEL"
                printf '%s\nEXEC_RC=0\n' "$FG_REMOVE_OUT" ;;
              *xdg-open*)
                echo 1 > "$fg/installed"; fg_notify "Installed $LC_FIXTURE_LABEL"
                echo XDG_RC=0 ;;
              *sha256sum*) printf '%s\n' "$LC_FIXTURE_SHA" ;;
            esac ;;
          *"base64 -d > "*) cat >/dev/null ;;
          *"then echo PRESENT; else echo ABSENT"*)
            path=$(sed -n "s/^if \[ -f '\([^']*\)' \].*/\1/p" <<<"$body")
            if [[ "$path" == "$LC_ENTRY_PATH" && "$(cat "$fg/installed")" == 1 ]]; then echo PRESENT; else echo ABSENT; fi ;;
          *"find $ICONS_DIR"*)
            [[ "$(cat "$fg/installed")" == 1 ]] && echo "$ICONS_DIR/48x48/apps/rhizo-$APP_PKG.png"
            echo LISTED ;;
          *"find $APPS_DIR"*) printf 'aaaa  %s/foot.desktop\nLISTED\n' "$APPS_DIR" ;;
          *"cat $MIMEAPPS"*) printf '[Default Applications]\napplication/vnd.android.package-archive=rhizo-apk-installer.desktop\nLISTED\n' ;;
          *"cat $LC_ENTRY_PATH"*)
            printf '[Desktop Entry]\nName=%s\nIcon=%s\nX-Rhizo-Package=%s\nActions=Uninstall;\n\n[Desktop Action Uninstall]\nExec=rhizo app remove %s\n' \
              "$LC_FIXTURE_LABEL" "$LC_ENTRY_ID" "$APP_PKG" "$APP_PKG" ;;
          *"wc -l < $NOTIF_REC"*) cat "$fg/notifs" ;;
          *"tail -1 $NOTIF_REC"*) printf '{"summary": "%s"}\n' "$(cat "$fg/last")" ;;
          *INBOX=*) echo INBOX=0 ;;
          *"systemctl is-active rhizo-resync.service"*)
            printf 'inactive\nqueue=0\ndrained=0\ntrigger=t0\nsynced=init=%s trigger=t0\nstamping=1\nDONE\n' "$INIT" ;;
          *"date +%s.%N"*) echo 1000.5 ;;
          *"journalctl -b -u rhizo-resync.service"*)
            [[ "$(cat "$fg/installed")" == 1 ]] \
              && echo "1001.000000 guest python3[9]: [rhizo-appsync] package $APP_PKG: entry $LC_ENTRY_PATH written, defaults {}"
            echo DONE ;;
        esac
        return 0
      }
      android_sh() {
        echo package:com.android.settings
        [[ "$(cat "$fg/installed")" == 1 ]] && echo "package:$APP_PKG"
        return 0
      }
      mkdir -p "$EV"; echo 1 > "$fg/installed"; echo 0 > "$fg/notifs"
      FAILED=0
      lc_assert_applifecycle.uninstall-entry-action >/dev/null 2>"$fg/claim.err"
      echo "RC=$?"
      echo "FAILED=$FAILED"
    ) 2>/dev/null
    [[ -s "$fg/cnf" ]] && sed 's/^/CNF=/' "$fg/cnf"
    return 0
  }
  lc_fg=$(mktemp -d) || exit 1
  mkdir -p "$lc_fg/share"; head -c 4096 /dev/urandom > "$lc_fg/share/rhizo-deskapp.apk"
  lc_fg_out=$(lc_fg_run "$lc_fg" "RHIZO_APP removed=com.rhizo.selftest")
  if [[ "$lc_fg_out" == $'RC=0\nFAILED=0' ]]; then
    ok "1h: applifecycle.uninstall-entry-action runs whole under set -u and passes against a guest that removes and reinstalls the app"
  else
    bad "1h: applifecycle.uninstall-entry-action against a guest that removes and reinstalls the app read: $(tr '\n' '|' <<<"${lc_fg_out:-nothing (the run died before reporting)}")"
  fi
  if [[ -s "$lc_fg/ev/cycle-applifecycle-uninstall-remove.log" ]] && ! compgen -G "$lc_fg/ev/cyclecycle-*" >/dev/null; then
    ok "1h: the uninstall claim's evidence lands as cycle-applifecycle-uninstall-*, one cycle prefix"
  else
    bad "1h: the uninstall claim's evidence files are: $(ls "$lc_fg/ev" 2>/dev/null | tr '\n' ' ') (want cycle-applifecycle-uninstall-remove.log and no cyclecycle-*)"
  fi
  rm -rf "$lc_fg"; lc_fg=$(mktemp -d) || exit 1
  mkdir -p "$lc_fg/share"; head -c 4096 /dev/urandom > "$lc_fg/share/rhizo-deskapp.apk"
  lc_fg_out=$(lc_fg_run "$lc_fg" "")
  if [[ "$lc_fg_out" == $'RC=1\nFAILED='[1-9]* ]] && grep -q "FAIL: the Uninstall action printed ''" "$lc_fg/claim.err" 2>/dev/null; then
    ok "1h: applifecycle.uninstall-entry-action fails by name when the Uninstall action prints no removal sentinel"
  else
    bad "1h: a removal with no RHIZO_APP sentinel read: $(tr '\n' '|' <<<"${lc_fg_out:-nothing}") (want RC=1 and a failure naming the missing sentinel)"
  fi
  rm -rf "$lc_fg"
  unset -f lc_fg_run
  unset lc_fg lc_fg_out

  lc_ow=$(mktemp -d) || exit 1
  lc_ow_out=$(
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/install-lib.sh"
    resync_bound() { echo 5; }
    RESYNC_POLL_S=0.1 INIT=4242 LC_ENTRY_PATH=/usr/share/applications/rhizo-com.rhizo.selftest.desktop
    echo 0 > "$lc_ow/reads"
    wait_guest_file() { return 0; }
    ssh_vm() {
      local n st stamp
      case "${*: -1}" in
        *rhizo-resync.service*)
          n=$(( $(cat "$lc_ow/reads") + 1 )); echo "$n" > "$lc_ow/reads"
          case "$n" in
            1) st=inactive stamp=t0 ;;
            2) st=active stamp=t0 ;;
            *) st=inactive stamp=t1; touch "$lc_ow/landed" ;;
          esac
          printf '%s\nqueue=0\ndrained=0\ntrigger=t1\nsynced=init=4242 trigger=%s\nstamping=1\nDONE\n' \
            "$st" "$stamp" ;;
      esac
      return 0
    }
    FAILED=0
    lc_step4_entries_synced >/dev/null 2>&1
    echo "RC=$? FAILED=$FAILED"
    [[ -e "$lc_ow/landed" ]] && echo LANDED
  )
  if [[ "$lc_ow_out" == $'RC=0 FAILED=0\nLANDED' ]]; then
    ok "1h2: step 4 returns only once the run an owed resync trigger started has landed"
  else
    bad "1h2: step 4 with a trigger its last synced run did not cover read: $(tr '\n' '|' <<<"${lc_ow_out:-nothing}") (want RC=0 FAILED=0 and the owed run LANDED before it returned)"
  fi
  rm -rf "$lc_ow"
  unset lc_ow lc_ow_out

  lc_di_fx=$(mktemp -d) || exit 1
  lc_di_out=$( (
    EV="$lc_di_fx"; LC_INSTALL_DEB_VERSION=0.1.0
    echo APT_RC=0 > "$EV/cycle-sway-install.log"
    dpkg-query() {
      local a fmt=""
      for a in "$@"; do [[ "$a" == -f=* ]] && fmt="${a#-f=}"; done
      fmt="${fmt//'${Status}'/install ok installed}"
      fmt="${fmt//'${Version}'/0.1.0}"
      printf '%b' "$fmt"
    }
    ssh_vm() { ( eval "${*: -1}" ); }
    FAILED=0
    lc_assert_install.cmd-apt-install sway >/dev/null 2>"$lc_di_fx/apt.err"
    echo "APT RC=$? FAILED=$FAILED"
  ) )
  if [[ "$lc_di_out" == "APT RC=0 FAILED=0" ]]; then
    ok "1i: install.cmd-apt-install reads dpkg-query's own unterminated output and passes on install ok installed/0.1.0"
  else
    bad "1i: install.cmd-apt-install against dpkg-query's own output read '$lc_di_out': $(grep FAIL "$lc_di_fx/apt.err" | head -1)"
  fi
  lc_di_hostfs() {
    local answer="$1"
    (
      echo 0 > "$lc_di_fx/t"
      date() { local t; t=$(( $(cat "$lc_di_fx/t") + 5 )); echo "$t" > "$lc_di_fx/t"; echo "$t"; }
      sleep() { :; }
      INIT=4242; DOWNLOADS=/home/deskuser/Downloads
      ssh_vm() {
        case "${*: -1}" in
          *'LoadState'*) echo loaded ;;
        esac
      }
      desk_user_sh() {
        case "${*: -1}" in
          *"> '$DOWNLOADS/"*sha256sum*) printf '%s\nDONE\n' "$(printf %064d 7)" ;;
        esac
      }
      android_sh() { printf '%b' "$answer"; }
      FAILED=0
      lc_assert_install.hostfs-share >/dev/null 2>"$lc_di_fx/hostfs.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_di_out=$(lc_di_hostfs 'DONE\n')
  if [[ "$lc_di_out" == "RC=1 FAILED=1" ]] && grep -q 'never appeared inside Android' "$lc_di_fx/hostfs.err"; then
    ok "1i: install.hostfs-share names a file that never appears inside Android, not a dead read"
  else
    bad "1i: install.hostfs-share with Android answering a bare DONE read '$lc_di_out': $(grep FAIL "$lc_di_fx/hostfs.err" | head -1)"
  fi
  lc_di_out=$(lc_di_hostfs "$(printf %064d 7)\\nDONE\\n")
  if [[ "$lc_di_out" == "RC=0 FAILED=0" ]]; then
    ok "1i: install.hostfs-share passes when Android reads back the host's own sha"
  else
    bad "1i: install.hostfs-share with a matching Android sha read '$lc_di_out': $(grep FAIL "$lc_di_fx/hostfs.err" | head -1)"
  fi
  rm -rf "$lc_di_fx"
  unset -f lc_di_hostfs
  unset lc_di_fx lc_di_out

  lc_ak_fx=$(mktemp -d) || exit 1
  printf '#!/bin/sh\n[ "$1" = keygen ] || exit 2\necho private > "$2"\necho "QAAAAselftestkey selftest@rig" > "$2.pub"\n' > "$lc_ak_fx/adb"
  chmod +x "$lc_ak_fx/adb"
  lc_ak_out=$( (
    EV="$lc_ak_fx"; RHIZO_ADB="$lc_ak_fx/adb"
    eval "$LC_ST_REAL_LC_RHIZO"
    fake_rhizo() {
      local line
      case "$1 $2" in
        "adb-key add")
          if [[ "$3" == - ]]; then line=$(cat); else line=$(cat "$3" 2>/dev/null) || { echo "RHIZO_FAIL cannot read $3"; return 1; }; fi
          [[ "$line" == QAAA* ]] || { echo "RHIZO_FAIL not an adb public key"; return 1; }
          echo "$line" >> "$lc_ak_fx/adb_keys"
          echo "[rhizo] registered AB:CD" >&2
          echo "RHIZO_ADBKEY added=1" ;;
        "adb-key list")
          [[ -s "$lc_ak_fx/adb_keys" ]] && printf 'AB:CD\tselftest@rig\n'
          echo "RHIZO_ADBKEY list=$(grep -c . "$lc_ak_fx/adb_keys" 2>/dev/null || echo 0)" ;;
      esac
    }
    ssh_vm() {
      local body="${*: -1}"
      body="${body//\/usr\/bin\/rhizo/fake_rhizo}"
      ( adb() { echo "adb: command not found" >&2; return 127; }; eval "$body" )
    }
    FAILED=0
    lc_assert_cli.adb-key >/dev/null 2>"$lc_ak_fx/claim.err"
    echo "RC=$? FAILED=$FAILED"
  ) )
  if [[ "$lc_ak_out" == "RC=0 FAILED=0" ]]; then
    ok "1j: cli.adb-key registers a rig-minted key through the CLI on a guest with no adb"
  else
    bad "1j: cli.adb-key on a guest with no adb read '${lc_ak_out:-nothing, the run died before reporting}': $(grep FAIL "$lc_ak_fx/claim.err" | head -1)"
  fi
  rm -rf "$lc_ak_fx"
  unset lc_ak_fx lc_ak_out

  lc_dv_run() {
    (
      lc_dv_mode="$1"
      rm -rf "$lc_dv_fx/state/device-state"; echo 0 > "$lc_dv_fx/reads"
      sleep() { SECONDS=$(( SECONDS + ${1%.*} )); }
      ssh_vm() { [[ "${*: -1}" == *'*"init second_stage"*'* ]] && echo 4242; return 0; }
      lc_rhizo() {
        [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
        [[ "${1:-}" == device ]] || { echo "not a device verb: $*"; return 2; }
        shift
        echo host > "$lc_dv_fx/selinux-mode"
        # shellcheck disable=SC2034
        ( RHIZO_STATE_DIR="$lc_dv_fx/state" RHIZO_CLI_SOURCE_ONLY=1
          RHIZO_SELINUX_MODE_FILE="$lc_dv_fx/selinux-mode"
          source "$repo_root/src/install/cli/rhizo.sh"
          cmd_device "$@" )
      }
      android_sh() {
        local n lvl=100 st=5 f="$lc_dv_fx/state/device-state/device-state.conf"
        n=$(( $(cat "$lc_dv_fx/reads") + 1 )); echo "$n" > "$lc_dv_fx/reads"
        if [[ "$lc_dv_mode" != earlier ]] && (( n > 1 )) && [[ -f "$f" ]]; then
          lvl=$(sed -n 's/^battery_level=//p' "$f")
          [[ "$lc_dv_mode" == level-only ]] || { [[ "$(sed -n 's/^battery_charging=//p' "$f")" == discharging ]] && st=3 || st=2; }
        fi
        printf 'Current Battery Service state:\n  AC powered: false\n  status: %s\n  health: 2\n  present: true\n  level: %s\n  scale: 100\n' "$st" "$lvl"
      }
      FAILED=0
      lc_assert_cli.device >/dev/null 2>"$lc_dv_fx/claim.err"
      echo "RC=$? FAILED=$FAILED STATE=$(sort "$lc_dv_fx/state/device-state/device-state.conf" 2>/dev/null | tr '\n' '|')"
    )
  }
  lc_dv_fx=$(mktemp -d) || exit 1
  lc_dv_out=$(lc_dv_run good)
  if [[ "$lc_dv_out" == "RC=0 FAILED=0 STATE=battery_charging=discharging|battery_level=42|" ]]; then
    ok "1j2: cli.device drives the CLI's own documented battery grammar and waits for dumpsys to report both the level and the state"
  else
    bad "1j2: cli.device against the real device-set parser read '${lc_dv_out:-nothing}': $(grep FAIL "$lc_dv_fx/claim.err" | head -1)"
  fi
  for lc_dv_case in "earlier|level='100' status='5'" "level-only|level='42' status='5'"; do
    lc_dv_out=$(lc_dv_run "${lc_dv_case%%|*}")
    if [[ "$lc_dv_out" == "RC=1 FAILED=1 "* ]] && grep -qF "${lc_dv_case#*|}" "$lc_dv_fx/claim.err"; then
      ok "1j2: cli.device fails by name on a HAL that delivers ${lc_dv_case%%|*}"
    else
      bad "1j2: cli.device on a HAL that delivers ${lc_dv_case%%|*} read '${lc_dv_out:-nothing}', want RC=1 naming '${lc_dv_case#*|}': $(grep FAIL "$lc_dv_fx/claim.err" | head -1)"
    fi
  done
  rm -rf "$lc_dv_fx"
  unset -f lc_dv_run
  unset lc_dv_fx lc_dv_out lc_dv_case

  lc_sal_unbound=$(python3 - "$(dirname "${BASH_SOURCE[0]}")" <<'PYEOF'
import glob, os, re, sys
d = sys.argv[1]
lib = open(os.path.join(d, "..", "lib", "server-assert-lib.sh")).read().split("\n")
reads, fn = {}, None
for line in lib:
    m = re.match(r"^([a-z_][a-z0-9_]*)\(\)\s*\{", line)
    if m:
        fn = m.group(1)
    if fn and not line.lstrip().startswith("#"):
        for v in re.findall(r"\$\{?([A-Z][A-Z0-9_]*)", line):
            reads.setdefault(fn, set()).add(v)
lib_assigned = set(re.findall(r"^([A-Z][A-Z0-9_]*)=", "\n".join(lib), re.M))
cyc = [os.path.join(d, "cycle.sh")] + sorted(glob.glob(os.path.join(d, "claims-*.sh")))
code = "\n".join(l for f in cyc for l in open(f).read().split("\n") if not l.lstrip().startswith("#"))
assigned = set(re.findall(r"(?:^|[\s;(])(?:local\s+)?([A-Z][A-Z0-9_]*)=", code, re.M)) | lib_assigned
env = {"EV", "HOME", "RANDOM", "FAILED", "SSH_OPTS", "SSH_PORT", "SSH_TARGET", "REPO", "VAR_DIR"}
for f, vs in sorted(reads.items()):
    if not re.search(r"(?<![\w.-])" + re.escape(f) + r"(?![\w-])", code):
        continue
    missing = sorted(v for v in vs if v not in assigned and v not in env)
    if missing:
        print("%s reads %s" % (f, ",".join(missing)))
PYEOF
)
  if [[ -z "$lc_sal_unbound" ]]; then
    ok "1k: every server-assert-lib.sh function a claim calls reads only globals the cycle assigns"
  else
    bad "1k: a claim calls a server-assert-lib.sh function reading a global the cycle never assigns: $(tr '\n' ';' <<<"$lc_sal_unbound")"
  fi
  unset lc_sal_unbound

  lc_rnr_bad=""
  for lc_rnr_f in start-sway.sh start-gnome.sh; do
    lc_rnr_calls=$(grep -E '^[[:space:]]*render_node_relabel\b' "$LC_TOOLS_DIR/../../vm/start/$lc_rnr_f")
    [[ -n "$lc_rnr_calls" ]] || { lc_rnr_bad+="$lc_rnr_f: no render_node_relabel call; "; continue; }
    while IFS= read -r lc_rnr_line; do
      [[ "$lc_rnr_line" =~ render_node_relabel[[:space:]]+\"\$DESKTOP_UID\" ]] \
        || lc_rnr_bad+="$lc_rnr_f: '$(sed 's/^[[:space:]]*//' <<<"$lc_rnr_line")' passes no session uid; "
    done <<<"$lc_rnr_calls"
  done
  if [[ -z "$lc_rnr_bad" ]]; then
    ok "1l: start-sway.sh and start-gnome.sh both call render_node_relabel with \$DESKTOP_UID"
  else
    bad "1l: $lc_rnr_bad"
  fi
  unset lc_rnr_bad lc_rnr_f lc_rnr_calls lc_rnr_line

  lc_mi_run() {
    (
      REPO="$lc_mi_fx" VAR_DIR="$lc_mi_fx"; APP_PKG=com.rhizo.selftest
      LC_ENTRY_PATH="$APPS_DIR/rhizo-com.rhizo.selftest.desktop"
      printf "#!/bin/sh\necho \"package: name='com.rhizo.selftest'\"\necho \"application: label='Selftest App' icon='%s'\"\n" "$1" > "$lc_mi_fx/share/aapt2"
      chmod +x "$lc_mi_fx/share/aapt2"
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/install-lib.sh"
      ssh_vm() {
        case "${*: -1}" in
          "cat $LC_ENTRY_PATH"*) printf '[Desktop Entry]\nName=Selftest App\nIcon=rhizo\nX-Rhizo-Package=com.rhizo.selftest\nDONE\n' ;;
          *"find $ICONS_DIR"*) echo LISTED ;;
          *"$ICONS_DIR/256x256/apps/rhizo.png"*) echo PRESENT ;;
        esac
      }
      FAILED=0
      lc_assert_applifecycle.menu-entry-icons >/dev/null 2>"$lc_mi_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_mi_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_mi_fx/share"
  lc_mi_out=$(lc_mi_run '')
  if [[ "$lc_mi_out" == "RC=0 FAILED=0" ]]; then
    ok "1m: applifecycle.menu-entry-icons passes an icon-less APK whose entry names the generic Icon=rhizo"
  else
    bad "1m: applifecycle.menu-entry-icons on an icon-less APK with Icon=rhizo read '${lc_mi_out:-nothing}': $(grep FAIL "$lc_mi_fx/claim.err" | head -1)"
  fi
  lc_mi_out=$(lc_mi_run 'res/mipmap/ic_launcher.png')
  if [[ "$lc_mi_out" == "RC=1 FAILED=1" ]] && grep -q "declares icon 'res/mipmap/ic_launcher.png' but" "$lc_mi_fx/claim.err"; then
    ok "1m: applifecycle.menu-entry-icons fails by name when an APK with an icon got the generic entry"
  else
    bad "1m: an APK declaring an icon but given Icon=rhizo read '${lc_mi_out:-nothing}': $(grep FAIL "$lc_mi_fx/claim.err" | head -1)"
  fi
  rm -rf "$lc_mi_fx"
  unset -f lc_mi_run
  unset lc_mi_fx lc_mi_out

  lc_up_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_up_fx/pkg/DEBIAN"
  printf 'Package: rhizo\nVersion: 0.1.1\nArchitecture: amd64\nMaintainer: selftest <selftest@rig>\nDepends: libc6, libpipewire-0.3-0t64\nDescription: selftest\n' > "$lc_up_fx/pkg/DEBIAN/control"
  dpkg-deb --build "$lc_up_fx/pkg" "$lc_up_fx/rhizo_0.1.1_amd64.deb" >/dev/null 2>&1
  lc_up_run() {
    (
      EV="$lc_up_fx"; SHARE_DIR="$lc_up_fx/share"; echo "$3" > "$lc_up_fx/ver"; : > "$lc_up_fx/staged"; : > "$lc_up_fx/apt-ran"
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      TEST_APT_OFFLINE_CONF="$lc_up_fx/apt.conf"
      rm -f "$TEST_APT_OFFLINE_CONF"
      [[ "$5" == present ]] && echo 'Dir::Etc::sourcelist "/var/lib/test-runtime-debs/apt/sources.list";' > "$TEST_APT_OFFLINE_CONF"
      [[ -z "${LC_UP_KERNEL:-}" ]] || LC_KERNEL_DEBS=("$lc_up_fx/linux-image-rhizo_9_amd64.deb" "$lc_up_fx/linux-headers-rhizo_9_amd64.deb")
      installer_transfer_artifact() { printf '%s\n' "$@" > "$lc_up_fx/transfer"; return 0; }
      installer_stage_pool() { echo "$5" > "$lc_up_fx/staged"; return 0; }
      ssh_vm() {
        local body="${*: -1}" guard u
        case "$body" in
          *"dpkg-query -W -f='\${Version}\n' rhizo"*) printf '%s\nDONE\n' "$(cat "$lc_up_fx/ver")" ;;
          *"cat /usr/lib/rhizo/VERSION"*) return 0 ;;
          *"InactiveExitTimestampMonotonic"*)
            for u in $INSTALLER_BOOT_ONLY_UNITS; do
              if [[ "$u" == androidd.service && "${LC_UP_STARTS:-0}" == 1 && -s "$lc_up_fx/apt-ran" ]]; then
                echo "MARK $u 0 77"
              else
                echo "MARK $u 0 0"
              fi
            done
            echo DONE ;;
          *"apt-get install"*)
            guard=$(eval "${body%%cd /root/rhizo-artifact*} echo LC_GUARD_PASSED" 2>&1)
            [[ "$guard" == LC_GUARD_PASSED ]] || { printf '%s\n' "$guard"; return 0; }
            echo 1 > "$lc_up_fx/apt-ran"
            printf '%s' "$body" > "$lc_up_fx/apt-body"
            [[ -s "$TEST_APT_OFFLINE_CONF" ]] \
              || echo "W: Unable to read $TEST_APT_OFFLINE_CONF - DirectoryExists (2: No such file or directory)"
            echo "Reading package lists..."
            [[ "$lc_up_remote" == 1 ]] && echo "Get:1 http://archive.ubuntu.com/ubuntu noble/main amd64 libpipewire-0.3-0t64 amd64 1.0.5-1 [252 kB]"
            if [[ "$lc_up_apt_rc" == 0 ]]; then
              [[ "$lc_up_moves" == moves ]] && echo 0.1.1 > "$lc_up_fx/ver"
              echo "Setting up rhizo (0.1.1) ..."
            else
              echo "E: Failed to fetch http://archive.ubuntu.com/ubuntu/pool/main/a/alsa-ucm-conf/x.deb  404  Not Found"
            fi
            echo "APT_RC=$lc_up_apt_rc" ;;
        esac
      }
      lc_up_apt_rc="$1" lc_up_remote="$2" lc_up_moves="$4"
      FAILED=0
      [[ "${6:-}" == stage-first ]] && installer_stage_pool cycle-sway-upgrade upgrade-deps "$SHARE_DIR/pipewire-debs" /var/lib/test-upgrade-debs "libc6 libpipewire-0.3-0t64" "" >/dev/null 2>&1
      lc_step3_upgrade sway "$lc_up_fx/rhizo_0.1.1_amd64.deb" "$lc_up_fx/mods.deb" >/dev/null 2>"$lc_up_fx/claim.err"
      echo "RC=$? FAILED=$FAILED STAGED=$(cat "$lc_up_fx/staged") APT=$(cat "$lc_up_fx/apt-ran")"
    )
  }
  lc_up_out=$(lc_up_run 0 0 0.1.0 moves present)
  if [[ "$lc_up_out" == "RC=0 FAILED=0 STAGED= APT=1" ]]; then
    ok "1n: step 3 reads the upgrade off dpkg (0.1.0 -> 0.1.1) with no VERSION file on N-1, staging nothing ahead of apt"
  else
    bad "1n: step 3 upgrading 0.1.0 -> 0.1.1 read '${lc_up_out:-nothing}': $(grep FAIL "$lc_up_fx/claim.err" | head -1)"
  fi
  lc_up_out=$(lc_up_run 0 0 0.1.0 moves present stage-first)
  if [[ "$lc_up_out" == *" STAGED=libc6 libpipewire-0.3-0t64 APT=1" ]]; then
    ok "1n: the staging recorder names the Depends the old sequence dpkg-installed ahead of apt"
  else
    bad "1n: the staging recorder did not see the old sequence's installer_stage_pool staging: '${lc_up_out:-nothing}'"
  fi
  lc_up_out=$(LC_UP_STARTS=1 lc_up_run 0 0 0.1.0 moves present)
  if [[ "$lc_up_out" == "RC=1 FAILED=1 STAGED= APT=1" ]] && grep -qF 'androidd.service got a start job' "$lc_up_fx/claim.err"; then
    ok "1n: step 3 fails by name when the upgrade starts androidd.service"
  else
    bad "1n: an upgrade that started androidd.service read '${lc_up_out:-nothing}': $(grep FAIL "$lc_up_fx/claim.err" | head -1)"
  fi
  if grep -q 'installer_stage_' <<<"$(declare -f lc_step3_upgrade lc_step3_cli_upgrade lc_step3_finish_upgrade; declare -f lifecycle_run_cycle | sed -n '/lc_step 3 /,/lc_step 4 /p')"; then
    bad "1n: step 3 still stages packages (installer_stage_*) ahead of its apt install of N"
  fi
  for lc_up_case in "0 1 0.1.0 moves present|was not offline and complete: apt reached a remote source|1" \
                    "100 0 0.1.0 stays present|exited APT_RC=100: E: Failed to fetch|1" \
                    "0 0 0.1.0 stays present|apt-get install exited 0 but dpkg reports rhizo '0.1.0', want 0.1.1|1" \
                    "0 0 0.1.1 moves present|dpkg reports rhizo '0.1.1' before the upgrade, want an N-1 older than 0.1.1|" \
                    "0 0 0.2.0 moves present|dpkg reports rhizo '0.2.0' before the upgrade, want an N-1 older than 0.1.1|" \
                    "0 0 0.1.0 moves missing|the offline apt configuration $lc_up_fx/apt.conf is missing or empty on the guest|"; do
    IFS='|' read -r lc_up_args lc_up_want lc_up_apt <<<"$lc_up_case"
    read -ra lc_up_argv <<<"$lc_up_args"
    lc_up_out=$(lc_up_run "${lc_up_argv[@]}")
    if [[ "$lc_up_out" == "RC=1 FAILED=1 STAGED= APT=$lc_up_apt" ]] && grep -qF "$lc_up_want" "$lc_up_fx/claim.err"; then
      ok "1n: step 3 ($lc_up_args) fails by name: $lc_up_want"
    else
      bad "1n: step 3 ($lc_up_args) read '${lc_up_out:-nothing}', want RC=1 APT=$lc_up_apt naming '$lc_up_want': $(grep FAIL "$lc_up_fx/claim.err" | head -1)"
    fi
  done
  lc_up_out=$(LC_UP_KERNEL=1 lc_up_run 0 0 0.1.0 moves present)
  if [[ "$lc_up_out" == "RC=0 FAILED=0 STAGED= APT=1" ]] \
     && [[ "$(tail -n 2 "$lc_up_fx/transfer")" == "$lc_up_fx/linux-image-rhizo_9_amd64.deb"$'\n'"$lc_up_fx/linux-headers-rhizo_9_amd64.deb" ]] \
     && grep -qF 'apt-get install -y -o Dpkg::Options::=--force-confold $k ./rhizo_*.deb' "$lc_up_fx/apt-body" \
     && grep -qF 'for f in ./linux-image-*rhizo_*.deb ./linux-headers-*rhizo_*.deb; do [ -e "$f" ] && k="$k $f"; done' "$lc_up_fx/apt-body"; then
    ok "1n: step 3 crosses N's Rhizo kernel .debs beside N and installs them in the one apt-get, keeping the pinned androidd.env by --force-confold"
  else
    bad "1n: step 3 with N's Rhizo kernel .debs read '${lc_up_out:-nothing}', transferred '$(tr '\n' '|' < "$lc_up_fx/transfer" 2>&1)', apt body '$(tr '\n' '|' < "$lc_up_fx/apt-body" 2>&1)'"
  fi
  rm -rf "$lc_up_fx"
  unset -f lc_up_run
  unset lc_up_fx lc_up_out lc_up_case lc_up_args lc_up_argv lc_up_want lc_up_apt

  lc_pw_fx=$(mktemp -d) || exit 1
  cp "$(dirname "${BASH_SOURCE[0]}")/../host/host-snapshot-diff.py" "$lc_pw_fx/"
  lc_pw_run() {
    (
      cd "$lc_pw_fx" || exit 1
      EV="$lc_pw_fx"; LC_LIVE=1; profile=sway; FAILED=0
      HOST_CENSUS_DIFF="$lc_pw_fx/host-snapshot-diff.py"; HOST_CENSUS_ALLOW_DIR="$lc_pw_fx"
      printf 'Start-Date: 2026-08-01  12:58:33\nCommandline: apt-get install -qqy grub-pc\nInstall: mokutil:amd64 (0.6.0, automatic), grub-pc:amd64 (2.12)\nEnd-Date: 2026-08-01  12:58:35\n' > history.log
      printf '2026-08-01 12:58:34 install grub-pc:amd64 <none> 2.12\n' > dpkg.log
      rm -f sway-pkgwin-*.log
      ssh_vm() {
        local c="${*: -1}"
        c="${c//\/var\/log\/apt\/history.log/$lc_pw_fx/history.log}"; c="${c//\/var\/log\/dpkg.log/$lc_pw_fx/dpkg.log}"
        case "$c" in *dpkg-query*) printf 'xdg-utils\t/usr/bin/xdg-open\nDONE\n' ;; *) bash -c "$c" ;; esac
      }
      fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*" >&2; }
      lc_pw_apt() {
        printf '\nStart-Date: 2026-09-24  01:50:34\nCommandline: apt-get install -y ./rhizo_0.1.0_amd64.deb\nInstall: xdg-utils:amd64 (1.1.3, automatic), rhizo:amd64 (0.1.0)\nEnd-Date: 2026-09-24  01:50:54\n' >> history.log
        printf '2026-09-24 01:50:40 install xdg-utils:all <none> 1.1.3\n' >> dpkg.log
        [[ "$1" == 1 ]] && : > dpkg.log
        return 7
      }
      lc_pkgwin rhizo-install step1-install lc_pw_apt "$1" 2>err
      local rc=$?
      printf 'end\tsentinel\tok\n' > sway-snapshot-before.tsv
      printf 'dpkg\txdg-utils.status\tinstall ok installed\ndpkg\txdg-utils.version\t1.1.3\nselinux_xattr\t/usr/bin/xdg-open\t<none>\nend\tsentinel\tok\n' \
        > sway-snapshot-after-remove.tsv
      : > host-snapshot-allow.tsv
      lc_snapshot_diff sway remove
      echo "RC=$rc FAILED=$FAILED DIFF=$?"
    )
  }
  lc_pw_out=$(lc_pw_run 0)
  if [[ "$lc_pw_out" == "RC=7 FAILED=0 DIFF=0" ]] \
     && [[ "$(python3 "$lc_pw_fx/host-snapshot-diff.py" --list-expected --phase remove --expect "rhizo-install=$lc_pw_fx/sway-pkgwin-rhizo-install.log")" == xdg-utils ]] \
     && head -1 "$lc_pw_fx/sway-snapshot-diff-remove.txt" | grep -q -- "--owned $lc_pw_fx/sway-owned-remove.tsv"; then
    ok "1t: lc_pkgwin records only the automatic install its command made, and lc_snapshot_diff explains it through that window and dpkg -L"
  else
    bad "1t: lc_pkgwin/lc_snapshot_diff read '${lc_pw_out:-nothing}': $(cat "$lc_pw_fx/err" "$lc_pw_fx/sway-snapshot-diff-remove.txt" 2>&1 | tr '\n' '|')"
  fi
  lc_pw_out=$(lc_pw_run 1)
  if [[ "$lc_pw_out" == "RC=7 FAILED=1 DIFF=1" ]] && tail -1 "$lc_pw_fx/sway-pkgwin-rhizo-install.log" | grep -q ' incomplete a package log rotated or shrank'; then
    ok "1t: a package log that shrank under the window is recorded incomplete, fails, and the diff refuses it"
  else
    bad "1t: a shrunk dpkg.log read '${lc_pw_out:-nothing}': $(tail -1 "$lc_pw_fx/sway-pkgwin-rhizo-install.log" 2>&1)"
  fi
  rm -rf "$lc_pw_fx"
  unset -f lc_pw_run
  unset lc_pw_fx lc_pw_out

  lc_pv_fx=$(mktemp -d) || exit 1
  cp "$(dirname "${BASH_SOURCE[0]}")/../host/host-snapshot-diff.py" "$lc_pv_fx/"
  mkdir -p "$lc_pv_fx/bin" "$lc_pv_fx/root/.cache/dconf"
  : > "$lc_pv_fx/root/.cache/dconf/user"
  cat > "$lc_pv_fx/bin/journalctl" <<'EOF'
#!/bin/bash
case "$*" in
  *--until*"-o export"*) echo "_BOOT_ID=boot-a" ;;
  *--since*"-n 1"*"-o export"*) echo "_BOOT_ID=boot-now" ;;
  *--since*"-o export"*) printf '_BOOT_ID=%s\n_BOOT_ID=boot-now\n' "$LC_PV_AFTER_BOOT" ;;
  *--until*) echo "08:29:46.988 systemd-journald[1728]: Journal stopped" ;;
  *--since*) echo "08:29:51.199 kernel: Linux version" ;;
esac
EOF
  chmod +x "$lc_pv_fx/bin/journalctl"
  lc_pv_run() {
    (
      cd "$lc_pv_fx" || exit 1
      HOST_CENSUS_DIFF="$lc_pv_fx/host-snapshot-diff.py"; HOST_CENSUS_ALLOW_DIR="$lc_pv_fx"
      EV="$lc_pv_fx"; LC_LIVE=1; profile=sway; FAILED=0
      export LC_PV_AFTER_BOOT="$1"
      rm -f sway-snapshot-provenance-remove.txt sway-pkgwin-*.log
      if [[ "${2:-0}" == 1 ]]; then
        ssh_vm() { return 255; }
      else
        ssh_vm() { PATH="$lc_pv_fx/bin:$PATH" bash -c "${*: -1}"; }
      fi
      fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*" >&2; }
      printf 'end\tsentinel\tok\n' > sway-snapshot-before.tsv
      printf 'home_root\t%s/root/.cache/dconf/user\tlisted\nend\tsentinel\tok\n' "$lc_pv_fx" > sway-snapshot-after-remove.tsv
      : > host-snapshot-allow.tsv
      lc_snapshot_diff sway remove
      echo "DIFF=$? FAILED=$FAILED"
    )
  }
  lc_pv_file="$lc_pv_fx/sway-snapshot-provenance-remove.txt"
  lc_pv_out=$(lc_pv_run boot-b)
  if [[ "$lc_pv_out" == "DIFF=1 FAILED=0" ]] \
     && grep -q "^PROVENANCE $lc_pv_fx/root/.cache/dconf/user birth=[0-9]" "$lc_pv_file" \
     && grep -q "born after its boot's journal ended" "$lc_pv_file" \
     && grep -q 'Journal stopped' "$lc_pv_file" && grep -q 'Linux version' "$lc_pv_file" \
     && grep -q "sway-snapshot-provenance-remove.txt" "$lc_pv_fx/sway-snapshot-diff-remove.txt"; then
    ok "1t: an unexplained new path gets its birth and the journal around it, and a birth past its boot's journal is named the shutdown's kill phase"
  else
    bad "1t: provenance of an unexplained path read '${lc_pv_out:-nothing}': $(cat "$lc_pv_file" 2>&1 | tr '\n' '|')"
  fi
  lc_pv_out=$(lc_pv_run boot-a)
  if [[ "$lc_pv_out" == "DIFF=1 FAILED=0" ]] && grep -q "^PROVENANCE .* birth=[0-9]" "$lc_pv_file" \
     && ! grep -q "journal ended" "$lc_pv_file"; then
    ok "1t: a birth inside its boot's journal is recorded without the kill-phase verdict"
  else
    bad "1t: a birth inside its boot's journal read '${lc_pv_out:-nothing}': $(cat "$lc_pv_file" 2>&1 | tr '\n' '|')"
  fi
  lc_pv_out=$(lc_pv_run boot-a 1)
  if [[ "$lc_pv_out" == "DIFF=1 FAILED=0" ]] && grep -q '^PROVENANCE_INCOMPLETE' "$lc_pv_file"; then
    ok "1t: an unreadable guest leaves the provenance marked incomplete and the diff's own rc"
  else
    bad "1t: an unreadable guest's provenance read '${lc_pv_out:-nothing}': $(cat "$lc_pv_file" 2>&1 | tr '\n' '|')"
  fi
  rm -rf "$lc_pv_fx"
  unset -f lc_pv_run
  unset lc_pv_fx lc_pv_out lc_pv_file

  lc_sa_fx=$(mktemp -d) || exit 1
  cp "$(dirname "${BASH_SOURCE[0]}")/../host/host-snapshot-diff.py" "$lc_sa_fx/"
  lc_sa_avc() {
    printf '[  %s] audit: type=1400 audit(1790000000.1:7): avc:  granted  { %s } for  pid=4242 comm="%s" name=%s scontext=u:r:rhizo_host:s0 tcontext=u:object_r:rhizo_census_audit_dir:s0 tclass=dir\r\n' "$RANDOM" "${3:-add_name}" "$1" "$2"
  }
  lc_sa_b64() { printf '%s' "$1" | base64 -w0; }
  lc_sa_run() {
    (
      cd "$lc_sa_fx" || exit 1
      HOST_CENSUS_DIFF="$lc_sa_fx/host-snapshot-diff.py"; HOST_CENSUS_ALLOW_DIR="$lc_sa_fx"
      EV="$lc_sa_fx"; LC_LIVE=1; profile=sway; FAILED=0
      HOST_CENSUS_CONSOLE_LOG="$lc_sa_fx/vm-boot-3.log"
      rm -f sway-snapshot-provenance-remove.txt sway-shutdown-audit-remove.txt vm-boot-3.log vm-boot-3.prev.log sway-pkgwin-*.log
      lc_sa_avc earlier '"dconf"' > vm-boot-3.log
      lc_sa_mode="$2" lc_sa_rec="${3:-cache}"
      ssh_vm() {
        local c="${*: -1}" nonce none
        case "$c" in
          *'python3 -c'*' remove')
            nonce=$(awk '{ print $(NF - 1) }' <<<"$c")
            [[ "$lc_sa_mode" == nomarker ]] || printf '[  90.1] RHIZO_CENSUS_AUDIT armed nonce=%s phase=remove dirs=3\n' "$nonce" >> vm-boot-3.log
            case "$lc_sa_mode" in
              blind|nocanary) ;;
              *) lc_sa_avc python3 "\".rhizo_census_canary_$nonce\"" >> vm-boot-3.log
                 lc_sa_avc python3 "\".rhizo_census_canary_$nonce\"" remove_name >> vm-boot-3.log ;;
            esac
            case "$lc_sa_mode" in
              window|rotated|rotated2|nomarker)
                lc_sa_avc fwupdtool '"dconf"' >> vm-boot-3.log
                lc_sa_avc hexname 64636F6E66 >> vm-boot-3.log
                lc_sa_avc teardown '"dconf"' remove_name >> vm-boot-3.log
                lc_sa_avc nested '"user"' >> vm-boot-3.log
                echo '[  90.2] audit: printk limit exceeded' >> vm-boot-3.log ;;
              lostonly) echo '[  90.2] audit: printk limit exceeded' >> vm-boot-3.log ;;
              nocanary) lc_sa_avc other '"other"' >> vm-boot-3.log ;;
              replaced) lc_sa_avc mover '".cache"' remove_name >> vm-boot-3.log
                        lc_sa_avc mover '".cache"' >> vm-boot-3.log ;;
              powerdown) echo '[  95.0] reboot: Power down' >> vm-boot-3.log ;;
            esac
            case "$lc_sa_mode" in
              unclosed|powerdown) mv vm-boot-3.log vm-boot-3.prev.log
                                  printf '[   0.0] Linux version 6.8.0-142-generic\n' > vm-boot-3.log
                                  lc_sa_avc later '"dconf"' >> vm-boot-3.log ;;
              *) printf '[   0.0] Linux version 6.8.0-142-generic\n' >> vm-boot-3.log
                 lc_sa_avc later '"dconf"' >> vm-boot-3.log ;;
            esac
            case "$lc_sa_mode" in
              rotated) mv vm-boot-3.log vm-boot-3.prev.log && : > vm-boot-3.log ;;
              rotated2) mv vm-boot-3.log vm-boot-3.prev.log && ln -f vm-boot-3.prev.log orig.log \
                          && cp vm-boot-3.prev.log vm-boot-3.log && mv vm-boot-3.log vm-boot-3.prev.log \
                          && cp vm-boot-3.prev.log vm-boot-3.log ;;
            esac
            none=$(lc_sa_b64 '<none>')
            case "$lc_sa_rec" in
              cache) printf 'DIR %s %s\nDIR %s %s\n' "$(lc_sa_b64 /root)" "$none" "$(lc_sa_b64 /root/.cache)" "$none" ;;
              skipcache) printf 'DIR %s %s\nDIRSKIP %s %s\n' "$(lc_sa_b64 /root)" "$none" "$(lc_sa_b64 /root/.cache)" "$(lc_sa_b64 u:object_r:other:s0)" ;;
              capped) printf 'DIR %s %s\nDIR %s %s\nDIRCAP 2001 2000\n' "$(lc_sa_b64 /root)" "$none" "$(lc_sa_b64 /root/.cache)" "$none" ;;
              noanc) printf 'DIR %s %s\n' "$(lc_sa_b64 /root/.ssh)" "$none" ;;
              foreign) printf 'DIR %s %s\nDIRFOREIGN %s dev\n' "$(lc_sa_b64 /root)" "$none" "$(lc_sa_b64 /root/.cache)" ;;
              unread) printf 'DIR %s %s\nDIRUNREAD %s PermissionError\n' "$(lc_sa_b64 /root)" "$none" "$(lc_sa_b64 /root/.cache)" ;;
              canaryleft) printf 'DIR %s %s\nDIR %s %s\n' "$(lc_sa_b64 /root)" "$none" "$(lc_sa_b64 /root/.cache)" "$none" ;;
              skipparent) printf 'DIR %s %s\nDIRSKIP %s %s\nDIR %s %s\n' "$(lc_sa_b64 /root)" "$none" "$(lc_sa_b64 /root/.cache)" "$(lc_sa_b64 u:object_r:other:s0)" "$(lc_sa_b64 /root/.cache/dconf)" "$none" ;;
            esac
            if [[ "$lc_sa_rec" == canaryleft ]]; then
              printf 'PRINTK console_loglevel 4->6\nCANARY_FAIL rmdir Permission_denied\nARMED %s 3\nDONE\n' "$nonce"
            else
              printf 'PRINTK console_loglevel 4->6\nCANARY .rhizo_census_canary_%s\nARMED %s 3\nDONE\n' "$nonce" "$nonce"
            fi ;;
          *'python3 -c'*) return 0 ;;
          *) bash -c "$c" ;;
        esac
      }
      fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*" >&2; }
      case "$1" in
        armed) host_census_shutdown_audit_arm sway remove ;;
        skip) printf 'ARM_AT x\nARM_SKIP SELinux is not the active LSM\nDONE\n' > sway-shutdown-audit-remove.txt ;;
      esac
      printf 'end\tsentinel\tok\n' > sway-snapshot-before.tsv
      {
        printf 'home_root\t/etc/rhizo-stray\tlisted\nhome_root\t/root/.cache\tlisted\nhome_root\t/root/.cache/dconf/user\tlisted\n'
        [[ "$lc_sa_rec" == canaryleft ]] \
          && printf 'home_root\t/root/.rhizo_census_canary_%s\tlisted\nhome_root\t/root/.rhizo_census_canary_1-1\tlisted\n' \
               "$(sed -n '1s/.* nonce=//p' sway-shutdown-audit-remove.txt)"
        printf 'end\tsentinel\tok\n'
      } > sway-snapshot-after-remove.tsv
      : > host-snapshot-allow.tsv
      lc_snapshot_diff sway remove
      echo "DIFF=$? FAILED=$FAILED"
    )
  }
  lc_sa_file="$lc_sa_fx/sway-snapshot-provenance-remove.txt"
  lc_sa_p=/root/.cache/dconf/user
  lc_sa_out=$(lc_sa_run armed window)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -q '^SHUTDOWN_AUDIT armed nonce=[0-9-]* dirs=3 ' "$lc_sa_file" \
     && grep -qx "WRITER $lc_sa_p pid=4242 comm=\"fwupdtool\" name=dconf" "$lc_sa_file" \
     && grep -qx "WRITER $lc_sa_p pid=4242 comm=\"hexname\" name=dconf" "$lc_sa_file" \
     && grep -q '^AVC_LOST .*printk limit exceeded' "$lc_sa_file" \
     && ! grep -q 'comm="earlier"\|comm="later"' "$lc_sa_file"; then
    ok "1t: an armed shutdown's console names the process that added the path's first unlabeled component, decodes a hex name, flags lost lines, and reads nothing before its marker or after the next kernel banner"
  else
    bad "1t: the armed console pull read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  if grep -qx "UNLINK $lc_sa_p pid=4242 comm=\"teardown\" name=dconf" "$lc_sa_file" \
     && ! grep -q '^WRITER .*comm="teardown"' "$lc_sa_file" \
     && ! grep -q '^WRITER .*comm="nested"' "$lc_sa_file" \
     && ! grep -q '^UNLINK .*comm="nested"' "$lc_sa_file"; then
    ok "1t: a remove_name of the same name is an UNLINK, never the WRITER, and a name deeper than the first unlabeled component is not attributed"
  else
    bad "1t: WRITER attribution read: $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  if grep -q '^AVC_OUTSIDE /etc/rhizo-stray ' "$lc_sa_file" && grep -q '^AVC_PREDATES /root/.cache ' "$lc_sa_file" \
     && ! grep -v '^AVC_OUTSIDE' "$lc_sa_file" | grep -qE '^(AVC_[A-Z_]*|WRITER|UNLINK) /etc/rhizo-stray '; then
    ok "1t: a path outside /root is AVC_OUTSIDE and a directory the arm labeled is AVC_PREDATES, neither searched for a writer"
  else
    bad "1t: an outside or pre-existing path read: $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed outside)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] && grep -q "^AVC_NONE $lc_sa_p no add_name of dconf in /root/.cache " "$lc_sa_file" \
     && grep -qx 'AVC_CONTROL canary=seen census_avcs=2 lost=0' "$lc_sa_file" \
     && ! grep -q '^AVC_LOST' "$lc_sa_file" && ! grep -q '^WRITER' "$lc_sa_file"; then
    ok "1t: an AVC naming the path only in an earlier shutdown or a later boot leaves the path AVC_NONE, proven by the canary, with no line flagged lost"
  else
    bad "1t: a console with the path's AVC outside the window read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed rotated)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] && grep -q "^WRITER $lc_sa_p pid=4242 comm=\"fwupdtool\"" "$lc_sa_file"; then
    ok "1t: a console a later boot rotated to .prev.log is still found by its inode"
  else
    bad "1t: a rotated console read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed rotated2)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] && grep -q '^AVC_UNREAD the console the arm recorded (inode [0-9]*, .*) is gone: a later boot rotated it twice' "$lc_sa_file" \
     && ! grep -q '^WRITER\|^AVC_NONE' "$lc_sa_file"; then
    ok "1t: a console rotated twice is AVC_UNREAD even though a copy of its text sits at both names"
  else
    bad "1t: a console rotated twice read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed nomarker)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] && grep -q '^AVC_UNREAD the arm marker nonce=' "$lc_sa_file" \
     && ! grep -q '^WRITER' "$lc_sa_file"; then
    ok "1t: a marker that never reached the console reads no AVC at all rather than one from an unknown shutdown"
  else
    bad "1t: a console with no marker read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed blind)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -qx "AVC_NONE_UNPROVEN $lc_sa_p census_avcs=0 lost=0 canary=absent why=no_census_avc,canary_absent" "$lc_sa_file" \
     && ! grep -q '^AVC_NONE ' "$lc_sa_file"; then
    ok "1t: a window holding no census AVC at all is AVC_NONE_UNPROVEN, never AVC_NONE"
  else
    bad "1t: a blind window read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed lostonly)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -qx "AVC_NONE_UNPROVEN $lc_sa_p census_avcs=2 lost=1 canary=seen why=lost_lines" "$lc_sa_file" \
     && ! grep -q '^AVC_NONE ' "$lc_sa_file"; then
    ok "1t: a window with a lost line is AVC_NONE_UNPROVEN even with the canary seen"
  else
    bad "1t: a window with a lost line read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed nocanary)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -qx "AVC_NONE_UNPROVEN $lc_sa_p census_avcs=1 lost=0 canary=absent why=canary_absent" "$lc_sa_file" \
     && ! grep -q '^AVC_NONE ' "$lc_sa_file"; then
    ok "1t: a window carrying census AVCs but not the arm's own canary is AVC_NONE_UNPROVEN"
  else
    bad "1t: a window without the canary read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed outside skipcache)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -q "^AVC_UNARMED $lc_sa_p /root/.cache existed at the arm unlabeled (DIRSKIP)" "$lc_sa_file" \
     && ! grep -q "^AVC_NONE" "$lc_sa_file"; then
    ok "1t: a path whose next component existed unlabeled at the arm is AVC_UNARMED"
  else
    bad "1t: a path under a skipped directory read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed outside skipparent)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -q "^AVC_NONE_UNPROVEN $lc_sa_p .*why=.*ancestor_parent_unarmed" "$lc_sa_file" \
     && ! grep -q "^AVC_NONE " "$lc_sa_file"; then
    ok "1t: an armed ancestor under an unlabeled parent, whose replacement prints nothing, is AVC_NONE_UNPROVEN"
  else
    bad "1t: a path under an armed dir with an unlabeled parent read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed outside noanc)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] && grep -q "^AVC_UNARMED $lc_sa_p no ancestor of it was labeled" "$lc_sa_file" \
     && ! grep -q "^AVC_NONE" "$lc_sa_file"; then
    ok "1t: a path with no labeled ancestor is AVC_UNARMED"
  else
    bad "1t: a path with no labeled ancestor read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed outside capped)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] && grep -q "^AVC_UNARMED $lc_sa_p the arm stopped at its directory cap" "$lc_sa_file" \
     && ! grep -q "^AVC_NONE" "$lc_sa_file"; then
    ok "1t: an arm that hit its directory cap leaves a path with no writer AVC_UNARMED"
  else
    bad "1t: a capped arm read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed outside foreign)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -q "^AVC_UNARMED $lc_sa_p /root/.cache existed at the arm unlabeled (DIRFOREIGN)" "$lc_sa_file" \
     && ! grep -q "^AVC_NONE" "$lc_sa_file"; then
    ok "1t: a path under a directory the arm left out as on another filesystem or a symlink is AVC_UNARMED, never AVC_NONE"
  else
    bad "1t: a path under a DIRFOREIGN directory read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed outside unread)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -q "^AVC_UNARMED $lc_sa_p /root/.cache existed at the arm unlabeled (DIRUNREAD)" "$lc_sa_file" \
     && ! grep -q "^AVC_NONE" "$lc_sa_file"; then
    ok "1t: a path under a directory the arm could not list is AVC_UNARMED, never AVC_NONE"
  else
    bad "1t: a path under a DIRUNREAD directory read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed replaced)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -qx "ANCESTOR_REPLACED $lc_sa_p pid=4242 comm=\"mover\" name=.cache" "$lc_sa_file" \
     && grep -qx "AVC_NONE_UNPROVEN $lc_sa_p census_avcs=4 lost=0 canary=seen why=ancestor_replaced" "$lc_sa_file" \
     && ! grep -q '^AVC_NONE ' "$lc_sa_file"; then
    ok "1t: an armed ancestor removed and made again inside the window turns a path's negative into AVC_NONE_UNPROVEN why=ancestor_replaced"
  else
    bad "1t: a window replacing an armed ancestor read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed unclosed)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -q '^AVC_WINDOW [0-9]* console lines from the marker to the end of the console' "$lc_sa_file" \
     && grep -qx "AVC_NONE_UNPROVEN $lc_sa_p census_avcs=2 lost=0 canary=seen why=window_unclosed" "$lc_sa_file" \
     && ! grep -q '^AVC_NONE \|comm="later"' "$lc_sa_file"; then
    ok "1t: a rotated console that stops before the next banner with no power-off line is AVC_NONE_UNPROVEN why=window_unclosed"
  else
    bad "1t: a window with no closing line read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed powerdown)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -q "^AVC_NONE $lc_sa_p no add_name of dconf in /root/.cache " "$lc_sa_file" \
     && ! grep -q '^AVC_NONE_UNPROVEN' "$lc_sa_file"; then
    ok "1t: a window with no later banner that the kernel's power-off line closes still proves AVC_NONE"
  else
    bad "1t: a window closed by the power-off line read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run armed outside canaryleft)
  lc_sa_n=$(sed -n '1s/.* nonce=//p' "$lc_sa_fx/sway-shutdown-audit-remove.txt")
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] \
     && grep -qx "CANARY_LEFT /root/.rhizo_census_canary_$lc_sa_n the canary of this arm survived it: CANARY_FAIL rmdir Permission_denied; residue of the census, not Rhizo state" "$lc_sa_file" \
     && grep -qx "CANARY_LEFT /root/.rhizo_census_canary_1-1 a census canary from another arm (this one is nonce=$lc_sa_n), not Rhizo state" "$lc_sa_file" \
     && ! grep -qE '^(AVC_[A-Z_]*|WRITER|UNLINK) /root/.rhizo_census_canary_' "$lc_sa_file"; then
    ok "1t: a surviving census canary is named CANARY_LEFT beside the arm's CANARY_FAIL, never searched for a writer"
  else
    bad "1t: a canary left behind read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run skip window)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] && grep -q '^SHUTDOWN_AUDIT_UNARMED SELinux is not the active LSM' "$lc_sa_file"; then
    ok "1t: an arm the guest skipped is recorded as unarmed with its reason"
  else
    bad "1t: a skipped arm read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  lc_sa_out=$(lc_sa_run none window)
  if [[ "$lc_sa_out" == "DIFF=1 FAILED=0" ]] && grep -q '^SHUTDOWN_AUDIT_UNARMED no arm record' "$lc_sa_file"; then
    ok "1t: a phase with no arm record says it ran with no create audit"
  else
    bad "1t: a phase with no arm read '${lc_sa_out:-nothing}': $(tr '\n' '|' < "$lc_sa_file" 2>&1)"
  fi
  rm -rf "$lc_sa_fx"
  unset -f lc_sa_run lc_sa_avc lc_sa_b64
  unset lc_sa_fx lc_sa_out lc_sa_file lc_sa_p lc_sa_n

  lc_ga_fx=$(mktemp -d) || exit 1
  lc_ga_label() {
    python3 -c 'import os, sys
try:
    print(os.getxattr(sys.argv[1], "user.rhizo_census", follow_symlinks=False).decode().rstrip("\0"))
except OSError:
    print("<none>")' "$1"
  }
  lc_ga_setup() {
    rm -rf "${lc_ga_fx:?}"/*
    mkdir -p "$lc_ga_fx/root/.cache/sub" "$lc_ga_fx/root/.ssh" "$lc_ga_fx/root/other" "$lc_ga_fx/outside" "$lc_ga_fx/proc"
    ln -s ../outside "$lc_ga_fx/root/link"
    python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.rhizo_census", b"u:object_r:other:s0")' "$lc_ga_fx/root/other"
    echo '4 4 1 7' > "$lc_ga_fx/proc/printk"
    echo 10 > "$lc_ga_fx/proc/printk_ratelimit_burst"
    : > "$lc_ga_fx/kmsg"
    : > "$lc_ga_fx/enforce"
  }
  lc_ga_env() {
    HC_ROOT="$lc_ga_fx/root" HC_XATTR=user.rhizo_census HC_PROC="$lc_ga_fx/proc" HC_KMSG="$lc_ga_fx/kmsg" \
      HC_ENFORCE="$lc_ga_fx/enforce" "$@"
  }
  lc_ga_disarm() {
    lc_ga_env python3 -c "$HOST_CENSUS_AUDIT_DISARM_PY" "$(awk '$1 == "DIR" { print $2 " " $3 }' <<<"$1" | gzip -c | base64 -w0)" 2>&1
  }
  lc_ga_want=""
  for lc_ga_d in root root/.cache root/.cache/sub root/.ssh; do
    lc_ga_want+="DIR $(printf '%s' "$lc_ga_fx/$lc_ga_d" | base64 -w0) $(printf '%s' '<none>' | base64 -w0)"$'\n'
  done
  lc_ga_setup
  lc_ga_arm=$(lc_ga_env python3 -c "$HOST_CENSUS_AUDIT_ARM_PY" 77-1 remove 2>&1)
  lc_ga_why=""
  [[ "$(grep '^DIR ' <<<"$lc_ga_arm" | sort)" == "$(sort <<<"${lc_ga_want%$'\n'}")" ]] || lc_ga_why+=" DIR rows"
  for lc_ga_d in root root/.cache root/.cache/sub root/.ssh; do
    [[ "$(lc_ga_label "$lc_ga_fx/$lc_ga_d")" == u:object_r:rhizo_census_audit_dir:s0 ]] || lc_ga_why+=" $lc_ga_d unlabeled"
  done
  grep -qx "DIRSKIP $(printf '%s' "$lc_ga_fx/root/other" | base64 -w0) $(printf '%s' u:object_r:other:s0 | base64 -w0)" <<<"$lc_ga_arm" || lc_ga_why+=" no DIRSKIP"
  [[ "$(lc_ga_label "$lc_ga_fx/root/other")" == u:object_r:other:s0 ]] || lc_ga_why+=" other touched"
  [[ "$(lc_ga_label "$lc_ga_fx/outside")" == '<none>' ]] || lc_ga_why+=" symlink followed"
  grep -qx 'PRINTK console_loglevel 4->6' <<<"$lc_ga_arm" || lc_ga_why+=" printk"
  grep -qx 'BURST printk_ratelimit_burst 10->200' <<<"$lc_ga_arm" || lc_ga_why+=" burst"
  grep -qx '<5>RHIZO_CENSUS_AUDIT armed nonce=77-1 phase=remove dirs=4' "$lc_ga_fx/kmsg" || lc_ga_why+=" marker"
  grep -qx 'CANARY .rhizo_census_canary_77-1' <<<"$lc_ga_arm" || lc_ga_why+=" canary"
  [[ -e "$lc_ga_fx/root/.rhizo_census_canary_77-1" ]] && lc_ga_why+=" canary left behind"
  grep -qx 'ARMED 77-1 4' <<<"$lc_ga_arm" || lc_ga_why+=" ARMED"
  grep -qx "DIRFOREIGN $(printf '%s' "$lc_ga_fx/root/link" | base64 -w0) link" <<<"$lc_ga_arm" || lc_ga_why+=" no DIRFOREIGN link"
  if [[ -z "$lc_ga_why" ]]; then
    ok "1t: the guest arm labels every directory on the root's filesystem, skips one labeled otherwise, records a symlink it never follows, raises printk, writes its marker and removes its canary"
  else
    bad "1t: the guest arm on a scratch tree:$lc_ga_why: $(tr '\n' '|' <<<"$lc_ga_arm")"
  fi
  rm -f "$lc_ga_fx/enforce"
  lc_ga_dis=$(lc_ga_disarm "$lc_ga_arm")
  lc_ga_why=""
  for lc_ga_d in root root/.cache root/.cache/sub root/.ssh; do
    [[ "$(lc_ga_label "$lc_ga_fx/$lc_ga_d")" == '<none>' ]] || lc_ga_why+=" $lc_ga_d=$(lc_ga_label "$lc_ga_fx/$lc_ga_d")"
  done
  [[ "$(lc_ga_label "$lc_ga_fx/root/other")" == u:object_r:other:s0 ]] || lc_ga_why+=" other touched"
  if [[ -z "$lc_ga_why" ]] && grep -qx 'DISARMED 4 0' <<<"$lc_ga_dis"; then
    ok "1t: with SELinux inactive the guest disarm removes every label the arm set"
  else
    bad "1t: the guest disarm with SELinux inactive:$lc_ga_why: $(tr '\n' '|' <<<"$lc_ga_dis")"
  fi
  lc_ga_setup
  lc_ga_arm=$(lc_ga_env python3 -c "$HOST_CENSUS_AUDIT_ARM_PY" 77-2 remove 2>&1)
  lc_ga_dis=$(lc_ga_disarm "$lc_ga_arm")
  lc_ga_why=""
  for lc_ga_d in root root/.cache root/.cache/sub root/.ssh; do
    [[ "$(lc_ga_label "$lc_ga_fx/$lc_ga_d")" == u:object_r:unlabeled:s0 ]] || lc_ga_why+=" $lc_ga_d=$(lc_ga_label "$lc_ga_fx/$lc_ga_d")"
  done
  if [[ -z "$lc_ga_why" ]] && grep -qx 'DISARMED 4 0' <<<"$lc_ga_dis"; then
    ok "1t: with SELinux active the guest disarm puts back the explicit unlabeled an absent label reads as"
  else
    bad "1t: the guest disarm with SELinux active:$lc_ga_why: $(tr '\n' '|' <<<"$lc_ga_dis")"
  fi
  lc_ga_setup
  lc_ga_arm=$(HC_DEV=0 lc_ga_env python3 -c "$HOST_CENSUS_AUDIT_ARM_PY" 77-3 remove 2>&1)
  if [[ "$(grep -c '^DIR ' <<<"$lc_ga_arm")" == 1 ]] && grep -qx 'ARMED 77-3 1' <<<"$lc_ga_arm" \
     && [[ "$(lc_ga_label "$lc_ga_fx/root/.cache")" == '<none>' ]] \
     && grep -qx "DIRFOREIGN $(printf '%s' "$lc_ga_fx/root/.cache" | base64 -w0) dev" <<<"$lc_ga_arm"; then
    ok "1t: the guest arm labels no directory on another filesystem than the root's and records each one DIRFOREIGN"
  else
    bad "1t: the guest arm with every subdirectory on another st_dev: $(tr '\n' '|' <<<"$lc_ga_arm")"
  fi
  {
    echo "ARM_AT x nonce=77-3"
    printf '[  90.1] RHIZO_CENSUS_AUDIT armed nonce=77-3 phase=remove dirs=1\n' > "$lc_ga_fx/console.log"
    for lc_ga_d in add_name remove_name; do
      printf '[  90.2] audit: type=1400 audit(1790000000.1:7): avc:  granted  { %s } for  pid=4242 comm="python3" name=".rhizo_census_canary_77-3" scontext=u:r:rhizo_host:s0 tcontext=u:object_r:rhizo_census_audit_dir:s0 tclass=dir\n' "$lc_ga_d" >> "$lc_ga_fx/console.log"
    done
    printf '[   0.0] Linux version 6.8.0-142-generic\n' >> "$lc_ga_fx/console.log"
    echo "CONSOLE $(stat -c %i "$lc_ga_fx/console.log") 0 $lc_ga_fx/console.log"
    python3 -c 'import base64, sys
for l in sys.stdin:
    a = l.split()
    if a and a[0].startswith("DIR"):
        p = base64.b64decode(a[1]).decode()
        a[1] = base64.b64encode(("/root" + p[len(sys.argv[1]):]).encode()).decode()
    print(" ".join(a))' "$lc_ga_fx/root" <<<"$lc_ga_arm"
  } > "$lc_ga_fx/rec"
  lc_ga_pull=$(python3 -c "$HOST_CENSUS_AUDIT_PULL_PY" "$lc_ga_fx/rec" /root/.cache/dconf/user 2>&1)
  if grep -qx 'AVC_CONTROL canary=seen census_avcs=2 lost=0' <<<"$lc_ga_pull" \
     && grep -q '^AVC_UNARMED /root/.cache/dconf/user /root/.cache existed at the arm unlabeled (DIRFOREIGN)' <<<"$lc_ga_pull" \
     && ! grep -q '^AVC_NONE' <<<"$lc_ga_pull"; then
    ok "1t: the pull over the arm's own record calls a path inside a directory on another filesystem AVC_UNARMED, not AVC_NONE"
  else
    bad "1t: the pull over an arm that left out a foreign directory: $(tr '\n' '|' <<<"$lc_ga_pull")"
  fi
  lc_ga_setup
  lc_ga_arm=$(HC_ROOT="$lc_ga_fx/kmsg" HC_XATTR=user.rhizo_census HC_PROC="$lc_ga_fx/proc" HC_KMSG="$lc_ga_fx/kmsg.out" \
    HC_ENFORCE="$lc_ga_fx/enforce" python3 -c "$HOST_CENSUS_AUDIT_ARM_PY" 77-6 remove 2>&1)
  if grep -qx "DIRUNREAD $(printf '%s' "$lc_ga_fx/kmsg" | base64 -w0) NotADirectoryError" <<<"$lc_ga_arm" \
     && ! grep -q '^DIR ' <<<"$lc_ga_arm"; then
    ok "1t: the guest arm records a directory it cannot list as DIRUNREAD"
  else
    bad "1t: the guest arm over a directory it cannot list: $(tr '\n' '|' <<<"$lc_ga_arm")"
  fi
  lc_ga_setup
  mkdir -p "$lc_ga_fx/ev"
  lc_ga_arm=$(lc_ga_env python3 -c "$HOST_CENSUS_AUDIT_ARM_PY" 77-5 remove 2>&1)
  mkdir "$lc_ga_fx/root/.rhizo_census_canary_77-5" "$lc_ga_fx/root/.rhizo_census_canary_77-9"
  for lc_ga_d in rows none; do
    { echo "ARM_AT x prefix=sway phase=$lc_ga_d nonce=77-5"; [[ "$lc_ga_d" == none ]] || printf '%s\n' "$lc_ga_arm"; } \
      > "$lc_ga_fx/ev/sway-shutdown-audit-$lc_ga_d.txt"
    [[ "$lc_ga_d" == none ]] && mkdir "$lc_ga_fx/root/.rhizo_census_canary_77-5"
    (
      EV="$lc_ga_fx/ev"
      ssh_vm() { lc_ga_env bash -c "${*: -1}"; }
      host_census_shutdown_audit_disarm sway "$lc_ga_d"
    )
  done
  lc_ga_why=""
  grep -qx 'CANARY_REMOVED .rhizo_census_canary_77-5' "$lc_ga_fx/ev/sway-shutdown-audit-rows.txt" || lc_ga_why+=" rows: no CANARY_REMOVED"
  grep -qx 'DISARMED 4 0' "$lc_ga_fx/ev/sway-shutdown-audit-rows.txt" || lc_ga_why+=" rows: not DISARMED 4 0"
  grep -q '^DISARM_NONE' "$lc_ga_fx/ev/sway-shutdown-audit-none.txt" || lc_ga_why+=" none: no DISARM_NONE"
  grep -qx 'CANARY_REMOVED .rhizo_census_canary_77-5' "$lc_ga_fx/ev/sway-shutdown-audit-none.txt" || lc_ga_why+=" none: no CANARY_REMOVED"
  [[ -e "$lc_ga_fx/root/.rhizo_census_canary_77-5" ]] && lc_ga_why+=" own canary left"
  [[ -d "$lc_ga_fx/root/.rhizo_census_canary_77-9" ]] || lc_ga_why+=" another arm's canary removed"
  if [[ -z "$lc_ga_why" ]]; then
    ok "1t: the disarm removes the canary its own arm left behind, with or without a labeled directory, and no other arm's"
  else
    bad "1t: the disarm of a canary left behind:$lc_ga_why: $(cat "$lc_ga_fx"/ev/*.txt 2>&1 | tr '\n' '|')"
  fi
  lc_ga_setup
  rm -f "$lc_ga_fx/enforce"
  lc_ga_arm=$(lc_ga_env python3 -c "$HOST_CENSUS_AUDIT_ARM_PY" 77-4 remove 2>&1)
  if grep -q '^ARM_SKIP SELinux is not the active LSM' <<<"$lc_ga_arm" && ! grep -q '^DIR ' <<<"$lc_ga_arm" \
     && [[ "$(lc_ga_label "$lc_ga_fx/root")" == '<none>' && ! -s "$lc_ga_fx/kmsg" ]]; then
    ok "1t: the guest arm with SELinux inactive skips and labels nothing"
  else
    bad "1t: the guest arm with SELinux inactive: $(tr '\n' '|' <<<"$lc_ga_arm")"
  fi
  rm -rf "$lc_ga_fx"
  unset -f lc_ga_label lc_ga_setup lc_ga_env lc_ga_disarm
  unset lc_ga_fx lc_ga_want lc_ga_d lc_ga_arm lc_ga_dis lc_ga_why lc_ga_pull

  lc_ak_fx=$(mktemp -d) || exit 1
  cp "$(dirname "${BASH_SOURCE[0]}")/../host/host-snapshot-diff.py" "$lc_ak_fx/"
  lc_ak_run() {
    (
      cd "$lc_ak_fx" || exit 1
      HOST_CENSUS_DIFF="$lc_ak_fx/host-snapshot-diff.py"; HOST_CENSUS_ALLOW_DIR="$lc_ak_fx"
      EV="$lc_ak_fx"; LC_LIVE=1; profile=sway; FAILED=0; LC_AK_MODE=$1
      rm -f sway-apt-kept-purge.log aptkept.cmd
      printf '%s 1 rhizo-install step1 history\nStart-Date: 2026-09-24  01:50:34\nCommandline: apt-get install -y ./rhizo_0.1.0_amd64.deb\nInstall: libwww-perl:amd64 (6.76-1, automatic), rhizo:amd64 (0.1.0)\nEnd-Date: 2026-09-24  01:50:54\n%s 1 rhizo-install step1 dpkg\n%s 1 rhizo-install step1 end\n' \
        "$LC_PKGWIN_TAG" "$LC_PKGWIN_TAG" "$LC_PKGWIN_TAG" > sway-pkgwin-rhizo-install.log
      ssh_vm() {
        local c="${*: -1}"
        case "$c" in
          *"$LC_APTKEPT_TAG"*)
            echo "$c" > aptkept.cmd
            local ieee_deps='perl, libwww-perl (>= 6), '
            [[ "$LC_AK_MODE" == foreign ]] && ieee_deps='perl, , '
            printf '%s kept libwww-perl\nAUTO libwww-perl\nPROVIDES \nlibwww-perl\nReverse Depends:\n |ieee-data\nDEPS ieee-data\tinstall ok installed\t%s\n%s autoremove-sim\n0 to remove\nSIM_RC=0\n' \
              "$LC_APTKEPT_TAG" "$ieee_deps" "$LC_APTKEPT_TAG"
            [[ "$LC_AK_MODE" == cut ]] || printf '%s end\n' "$LC_APTKEPT_TAG" ;;
          *dpkg-query*) printf 'libwww-perl\t/usr/bin/lwp-download\nDONE\n' ;;
        esac
      }
      fail() { FAILED=$((FAILED + 1)); echo "FAIL: $*" >&2; }
      local rec=0
      if [[ "$1" != none ]]; then lc_apt_kept_record sway 2>>err; rec=$?; fi
      printf 'dpkg\tieee-data.status\tinstall ok installed\ndpkg\tieee-data.version\t1\nend\tsentinel\tok\n' > sway-snapshot-before.tsv
      printf 'dpkg\tieee-data.status\tinstall ok installed\ndpkg\tieee-data.version\t1\ndpkg\tlibwww-perl.status\tinstall ok installed\ndpkg\tlibwww-perl.version\t6.76-1\nselinux_xattr\t/usr/bin/lwp-download\t<none>\nend\tsentinel\tok\n' \
        > sway-snapshot-after-purge.tsv
      : > host-snapshot-allow.tsv
      lc_snapshot_diff sway purge
      echo "REC=$rec DIFF=$? FAILED=$FAILED"
    )
  }
  lc_ak_out=$(lc_ak_run whole)
  if [[ "$lc_ak_out" == "REC=0 DIFF=0 FAILED=0" ]] \
     && grep -q 'apt-cache rdepends --installed --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances' "$lc_ak_fx/aptkept.cmd" \
     && grep -q 'apt-get -s autoremove' "$lc_ak_fx/aptkept.cmd" \
     && grep -q 'apt-mark showauto' "$lc_ak_fx/aptkept.cmd" && grep -q 'SIM_RC=\$?' "$lc_ak_fx/aptkept.cmd" \
     && grep -qF "dpkg-query -W -f='DEPS \${binary:Package}\t\${Status}\t\${Depends}, \${Pre-Depends}, \${Recommends}\n'" "$lc_ak_fx/aptkept.cmd" \
     && grep -qF 'echo "PROVIDES $provs"' "$lc_ak_fx/aptkept.cmd" \
     && head -1 "$lc_ak_fx/sway-snapshot-diff-purge.txt" | grep -q -- "--apt-kept $lc_ak_fx/sway-apt-kept-purge.log"; then
    ok "1t: a package the purge's autoremove kept for the host's own ieee-data passes on apt's recorded reason"
  else
    bad "1t: lc_apt_kept_record/lc_snapshot_diff read '${lc_ak_out:-nothing}': $(cat "$lc_ak_fx/err" "$lc_ak_fx/sway-snapshot-diff-purge.txt" 2>&1 | tr '\n' '|')"
  fi
  lc_ak_out=$(lc_ak_run none)
  if [[ "$lc_ak_out" == "REC=0 DIFF=1 FAILED=0" ]] \
     && grep -q 'libwww-perl should be gone (apt autoremove --purge) after purge' "$lc_ak_fx/sway-snapshot-diff-purge.txt"; then
    ok "1t: with no apt record the same kept package fails the purge diff by name"
  else
    bad "1t: a kept package with no apt record read '${lc_ak_out:-nothing}': $(tr '\n' '|' < "$lc_ak_fx/sway-snapshot-diff-purge.txt")"
  fi
  lc_ak_out=$(lc_ak_run cut)
  if [[ "$lc_ak_out" == "REC=1 DIFF=1 FAILED=1" ]] && grep -q 'no end marker' "$lc_ak_fx/sway-snapshot-diff-purge.txt"; then
    ok "1t: an apt record cut short fails the step and the diff refuses it"
  else
    bad "1t: a cut apt record read '${lc_ak_out:-nothing}': $(tr '\n' '|' < "$lc_ak_fx/sway-snapshot-diff-purge.txt")"
  fi
  lc_ak_out=$(lc_ak_run foreign)
  if [[ "$lc_ak_out" == "REC=0 DIFF=1 FAILED=0" ]] \
     && grep -q 'libwww-perl should be gone .*but dpkg-query shows no installed version' "$lc_ak_fx/sway-snapshot-diff-purge.txt"; then
    ok "1t: a keeper apt-cache names whose installed version does not depend on the package fails the purge diff by name"
  else
    bad "1t: an unconfirmed keeper read '${lc_ak_out:-nothing}': $(tr '\n' '|' < "$lc_ak_fx/sway-snapshot-diff-purge.txt")"
  fi
  mkdir -p "$lc_ak_fx/bin"
  printf '#!/bin/sh\n[ "$2" = perl-openssl-defaults ] || exit 1\nprintf "Status: install ok installed\\nProvides: perl-openssl-abi-3\\n"\n' > "$lc_ak_fx/bin/dpkg"
  printf '#!/bin/sh\necho "$2"\n' > "$lc_ak_fx/bin/apt-mark"
  printf '#!/bin/sh\neval n=\\${$#}\n[ "$n" = perl-openssl-defaults ] && printf "%%s\\nReverse Depends:\\n" "$n" || echo "<$n>"\n' > "$lc_ak_fx/bin/apt-cache"
  printf '#!/bin/sh\ncase "$*" in\n  *DEPS*libnet-ssleay-perl*) printf "DEPS libnet-ssleay-perl:amd64\\tinstall ok installed\\tperl, perl-openssl-abi-3 (>= 1), , \\n" ;;\n  *DEPS*) exit 1 ;;\n  *) printf "ii \\tlibnet-ssleay-perl:amd64\\tperl, perl-openssl-abi-3:any, , \\nii \\tperl-openssl-abi-3-doc\\tperl, , \\nrc \\told\\tperl-openssl-abi-3, , \\n" ;;\nesac\n' > "$lc_ak_fx/bin/dpkg-query"
  printf '#!/bin/sh\necho "0 to remove"\n' > "$lc_ak_fx/bin/apt-get"
  chmod +x "$lc_ak_fx/bin/"*
  lc_ak_out=$(
    cd "$lc_ak_fx" || exit 1
    HOST_CENSUS_DIFF="$lc_ak_fx/host-snapshot-diff.py"; HOST_CENSUS_ALLOW_DIR="$lc_ak_fx"
    EV="$lc_ak_fx"; FAILED=0
    printf 'x\n' > virt-pkgwin-rhizo-install.log
    python3() { echo perl-openssl-defaults; }
    ssh_vm() { PATH="$lc_ak_fx/bin:$PATH" bash -c "${*: -1}"; }
    fail() { FAILED=$((FAILED + 1)); }
    lc_apt_kept_record virt
    echo "REC=$? FAILED=$FAILED"
  )
  if [[ "$lc_ak_out" == "REC=0 FAILED=0" ]] && grep -qx '  libnet-ssleay-perl:amd64' "$lc_ak_fx/virt-apt-kept-purge.log" \
     && grep -q '^DEPS libnet-ssleay-perl:amd64	install ok installed	' "$lc_ak_fx/virt-apt-kept-purge.log" \
     && ! grep -q 'old\|abi-3-doc' "$lc_ak_fx/virt-apt-kept-purge.log"; then
    ok "1t: the recorder names an installed keeper that depends only on a virtual package the kept one provides"
  else
    bad "1t: a keeper through a provided virtual name read '${lc_ak_out:-nothing}': $(tr '\n' '|' < "$lc_ak_fx/virt-apt-kept-purge.log" 2>&1)"
  fi
  rm -rf "$lc_ak_fx"
  unset -f lc_ak_run
  unset lc_ak_fx lc_ak_out

  lc_rel_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/gsi-update-lib.sh"
      INIT=42 lc_rel_tree="$1" lc_rel_live="$2" P=0 F=0
      ssh_vm() { printf '%s' "$lc_rel_tree"; }
      android_sh() { printf '%b' "$lc_rel_live"; }
      log() { :; }
      pass() { P=$((P + 1)); echo "PASS $*"; }
      fail() { F=$((F + 1)); echo "FAIL $*"; }
      out=$(assert_booted_release a16 /srv/rhizo/gsi_system)
      P=$(grep -c '^PASS' <<<"$out"); F=$(grep -c '^FAIL' <<<"$out")
      echo "P=$P F=$F"; echo "$out"
    )
  }
  lc_rel_tree='ro.build.version.sdk=36 ro.system.build.version.release=16 '
  lc_rel_bad=""
  [[ "$(lc_rel_run "$lc_rel_tree" '36\n16\n' | head -1)" == "P=1 F=0" ]] || lc_rel_bad+=" a16 running as a16 did not pass;"
  lc_rel_out=$(lc_rel_run "$lc_rel_tree" '35\n15\n')
  [[ "$(head -1 <<<"$lc_rel_out")" == "P=0 F=1" && "$lc_rel_out" == *"'35 15'"*"did not boot a16"* ]] \
    || lc_rel_bad+=" a15 booted under the a16 label was not failed by name: $(tr '\n' '|' <<<"$lc_rel_out");"
  [[ "$(lc_rel_run "$lc_rel_tree" '' | head -1)" == "P=0 F=1" ]] || lc_rel_bad+=" an unanswered getprop did not fail;"
  lc_rel_out=$(lc_rel_run '' '36\n16\n')
  [[ "$(head -1 <<<"$lc_rel_out")" == "P=0 F=1" && "$lc_rel_out" == *"could not read the a16 identity"* ]] \
    || lc_rel_bad+=" an unreadable tree did not fail by name: $(tr '\n' '|' <<<"$lc_rel_out");"
  if [[ -z "$lc_rel_bad" ]]; then
    ok "1tb: the trial's identity passes only on the running system's own sdk and release, and fails by name on another release, no answer or an unreadable tree"
  else
    bad "1tb:$lc_rel_bad"
  fi
  unset -f lc_rel_run
  unset lc_rel_tree lc_rel_bad lc_rel_out

  lc_pr_run() {
    (
      FAILED=0 INIT="" profile=server EV="$lc_pr_ev"
      declare -A GSI_DIR=([a15]=/srv/rhizo/gsi_system_a15 [a16]=/srv/rhizo/gsi_system)
      lc_pr_cli="$1" lc_pr_prep="$2" lc_pr_left="$3" lc_pr_booted="$4"
      fail() { FAILED=$((FAILED + 1)); echo "FAIL $*"; }
      pass() { :; }
      log() { :; }
      sleep() { :; }
      ssh_vm() {
        [[ "${1:-}" == -t ]] && shift 2
        case "$*" in
          *"wc -l < /var/log/rhizo/prepare.log"*) printf '10\nDONE\n' ;;
          "tail -n +11 /var/log/rhizo/prepare.log") printf '%b' "$lc_pr_prep" ;;
          *"is-active rhizo-prepare.service"*) echo active ;;
          *ConditionResult*) printf 'ConditionResult=yes\nConditionTimestampMonotonic=5\n' ;;
          *prepare-request*) echo "$lc_pr_left" ;;
        esac
      }
      lc_rhizo() { echo "rhizo $*" >> "$lc_pr_ev/rhizo-calls"; printf '%b\n' "$lc_pr_cli"; }
      reboot_and_wait() { :; }
      lc_sandbox_up() { INIT=42; }
      assert_booted_release() { (( lc_pr_booted )) || fail "the running system did not boot $1"; }
      lc_step6_prepare_release server a15; rc=$?
      echo "rc=$rc F=$FAILED line=$LC_GSI_PREPARE_LINE"
    )
  }
  lc_pr_ev=$(mktemp -d)
  lc_pr_ok_cli='[rhizo] SELinux is enforcing\nRHIZO_PREPARE_REBOOT_REQUIRED=1 reason=enforcing release=a15'
  lc_pr_ok_prep='[rhizo-host-prepare] release a15, tree /srv/rhizo/gsi_system_a15, from /var/lib/rhizo/prepare-request\nRHIZO_PREPARE_OK key=aaaaaaaaaaaa tree=/x sepolicy=/x template=bbbbbbbbbbbb data=instantiated dexopt=1/2\n'
  lc_pr_bad=""
  lc_pr_out=$(lc_pr_run "$lc_pr_ok_cli" "$lc_pr_ok_prep" absent 1)
  [[ "$(tail -1 <<<"$lc_pr_out")" == "rc=0 F=0 line=RHIZO_PREPARE_REBOOT_REQUIRED=1 reason=enforcing release=a15" ]] \
    || lc_pr_bad+=" the deferred prepare that ran on the reboot did not pass: $(tr '\n' '|' <<<"$lc_pr_out");"
  grep -qx 'rhizo 900 prepare --release a15 --wipe-data' "$lc_pr_ev/rhizo-calls" \
    || lc_pr_bad+=" the step did not run rhizo prepare --release a15 --wipe-data: $(cat "$lc_pr_ev/rhizo-calls");"
  lc_pr_out=$(lc_pr_run 'RHIZO_PREPARE_REFUSED reason=enforcing' "$lc_pr_ok_prep" absent 1)
  [[ "$(tail -1 <<<"$lc_pr_out")" == "rc=1 F=1 line=RHIZO_PREPARE_REFUSED reason=enforcing" && "$lc_pr_out" == *"want its deferral to the next boot"* ]] \
    || lc_pr_bad+=" a prepare refused under enforcement was not failed by name: $(tr '\n' '|' <<<"$lc_pr_out");"
  lc_pr_out=$(lc_pr_run "$lc_pr_ok_cli" '[rhizo-host-prepare] release a16, tree /srv/rhizo/gsi_system\nRHIZO_PREPARE_OK key=a tree=/x sepolicy=/x template=b data=instantiated dexopt=1/2\n' absent 1)
  [[ "$(tail -1 <<<"$lc_pr_out")" == "rc=1 F=1"* && "$lc_pr_out" == *"did not run the deferred request for a15"* ]] \
    || lc_pr_bad+=" a reboot that prepared the current release instead was not failed: $(tr '\n' '|' <<<"$lc_pr_out");"
  lc_pr_out=$(lc_pr_run "$lc_pr_ok_cli" "${lc_pr_ok_prep/data=instantiated/data=kept}" absent 1)
  [[ "$(tail -1 <<<"$lc_pr_out")" == "rc=1 F=1"* && "$lc_pr_out" == *"data=instantiated"* ]] \
    || lc_pr_bad+=" a prepare that kept the old /data was not failed: $(tr '\n' '|' <<<"$lc_pr_out");"
  lc_pr_out=$(lc_pr_run "$lc_pr_ok_cli" "$lc_pr_ok_prep" present 1)
  [[ "$(tail -1 <<<"$lc_pr_out")" == "rc=1 F=1"* && "$lc_pr_out" == *"prepare-request reads 'present'"* ]] \
    || lc_pr_bad+=" a request left behind was not failed: $(tr '\n' '|' <<<"$lc_pr_out");"
  lc_pr_out=$(lc_pr_run "$lc_pr_ok_cli" "$lc_pr_ok_prep" absent 0)
  [[ "$(tail -1 <<<"$lc_pr_out")" == "rc=1 F=1"* ]] \
    || lc_pr_bad+=" a sandbox that did not boot a15 was not failed: $(tr '\n' '|' <<<"$lc_pr_out");"
  if [[ -z "$lc_pr_bad" ]]; then
    ok "1tc: step 6 reaches a15 only through rhizo prepare's deferral and the reboot's prepare of that request on a new /data, and fails by name on an immediate refusal, another release, kept data, a request left behind or another running release"
  else
    bad "1tc:$lc_pr_bad"
  fi
  rm -rf "$lc_pr_ev"
  unset -f lc_pr_run
  unset lc_pr_ev lc_pr_ok_cli lc_pr_ok_prep lc_pr_bad lc_pr_out

  lc_dl_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/gsi-update-lib.sh"
      INIT=42 DESKAPP_PKG=com.jeffliu.balancetheball DESKAPP_ACT=.GameActivity
      DESKAPP_LAUNCH_CONFIRM="$1" lc_dl_atm="$2" lc_dl_clear="${4:-works}" TEST_FATAL_RE='FATAL EXCEPTION'
      lc_dl_dir=$(mktemp -d)
      echo 1000 > "$lc_dl_dir/clock"
      printf '%b' "${3:-}" > "$lc_dl_dir/ring"
      test_scratch_log() { printf '%s/%s.log' "$lc_dl_dir" "$1"; }
      android_sh() {
        [[ "$2" == "am start"* ]] || return 0
        echo 'Starting: Intent { cmp=com.jeffliu.balancetheball/.GameActivity (has extras) }'
        printf '%b' "$lc_dl_atm" >> "$lc_dl_dir/ring"
      }
      logcat_vm() {
        case " $* " in
          *" -c "*) [[ "$lc_dl_clear" == works ]] && : > "$lc_dl_dir/ring" ;;
          *ActivityTaskManager*) grep -F 'ActivityTaskManager' "$lc_dl_dir/ring" ;;
          *RhizoDeskApp*) grep -F 'RhizoDeskApp' "$lc_dl_dir/ring" ;;
          *) echo '09-25 12:00:00.000   219   481 I ActivityTaskManager: START u0 {cmp=com.jeffliu.balancetheball/.GameActivity}'; cat "$lc_dl_dir/ring" ;;
        esac
      }
      sleep() { echo $(( $(cat "$lc_dl_dir/clock") + ${1%%.*} )) > "$lc_dl_dir/clock"; }
      date() { cat "$lc_dl_dir/clock"; }
      log() { :; }
      pass() { echo "PASS $*"; }
      fail() { echo "FAIL $*"; }
      out=$(assert_deskapp_launches gsi.app-survives)
      echo "P=$(grep -c '^PASS' <<<"$out") F=$(grep -c '^FAIL' <<<"$out")"; echo "$out"
      rm -rf "$lc_dl_dir"
    )
  }
  lc_dl_line='09-25 12:00:00.100   219   238 I ActivityTaskManager: Displayed com.jeffliu.balancetheball/.GameActivity for user 0: +99ms\n'
  lc_dl_bad=""
  [[ "$(lc_dl_run displayed "$lc_dl_line" | head -1)" == "P=1 F=0" ]] || lc_dl_bad+=" the server fixture's Displayed line did not pass;"
  lc_dl_out=$(lc_dl_run clip "$lc_dl_line")
  [[ "$(head -1 <<<"$lc_dl_out")" == "P=0 F=1" && "$lc_dl_out" == *"token-seen=0"* ]] \
    || lc_dl_bad+=" a clip-token wait passed a fixture that logs none: $(tr '\n' '|' <<<"$lc_dl_out");"
  lc_dl_out=$(lc_dl_run displayed '09-25 12:00:00.100   219   238 I ActivityTaskManager: Displayed org.other/.Main for user 0: +5ms\n')
  [[ "$(head -1 <<<"$lc_dl_out")" == "P=0 F=1" ]] \
    || lc_dl_bad+=" another app's Displayed line passed: $(tr '\n' '|' <<<"$lc_dl_out");"
  lc_dl_out=$(lc_dl_run displayed '' "$lc_dl_line" fails)
  [[ "$(head -1 <<<"$lc_dl_out")" == "P=0 F=1" && "$lc_dl_out" == *"earlier"* ]] \
    || lc_dl_bad+=" an old Displayed line left by a failed clear confirmed a launch that never displayed: $(tr '\n' '|' <<<"$lc_dl_out");"
  [[ "$(lc_dl_run displayed "$lc_dl_line" "$lc_dl_line" works | head -1)" == "P=1 F=0" ]] \
    || lc_dl_bad+=" a clear that took did not let this launch's own Displayed line pass;"
  if [[ -z "$lc_dl_bad" ]]; then
    ok "1td: the server fixture's launch is confirmed by its own Displayed line, a clip-token wait fails it, and neither another app's line nor one a failed clear left behind counts"
  else
    bad "1td:$lc_dl_bad"
  fi
  unset -f lc_dl_run
  unset lc_dl_line lc_dl_bad lc_dl_out

  lc_be_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/gsi-update-lib.sh"
      lc_be_env="$2"
      if [[ -n "$lc_be_env" ]]; then
        GSI_LEG_ENV_FILE="$lc_be_env" GSI_LEG_PER_BOOT_KNOBS=RHIZO_FAULT_NO_READY GSI_LEG_SKIP_KNOBS=RHIZO_RELEASE_SWITCH
      fi
      log() { :; }
      fail() { echo "FAIL $*"; }
      test_scratch_log() { printf '/dev/null'; }
      kill_vm() { [[ -n "$lc_be_env" ]] && echo "AT-REBOOT $(tr '\n' ' ' < "$lc_be_env")" >> "$lc_be_log"; return 0; }
      boot_vm() { :; }
      wait_for_boot_slot() { :; }
      wait_for_ssh() { :; }
      wait_for_guest_ready() { :; }
      ssh_vm() {
        [[ "${1:-}" == -t ]] && shift 2
        echo "GUEST $*" >> "$lc_be_log"
        [[ -n "$lc_be_env" && "$*" == *"'$lc_be_env'"* ]] && bash -c "$*" 2>/dev/null
      }
      lc_be_noop() { :; }
      boot_and_start lc-be a16 "" "$1" lc_be_noop
    )
  }
  lc_be_env=$(mktemp) lc_be_log=$(mktemp)
  printf 'RHIZO_PERMISSIVE=1\n' > "$lc_be_env"
  lc_be_bad=""
  lc_be_run "RHIZO_FAULT_NO_READY=1 RHIZO_RELEASE_SWITCH=1" "$lc_be_env"
  [[ "$(tr '\n' ' ' < "$lc_be_env")" == "RHIZO_PERMISSIVE=1 RHIZO_FAULT_NO_READY=1 " ]] \
    || lc_be_bad+=" a try's knobs left the packaged env file '$(tr '\n' ' ' < "$lc_be_env")', want the fault knob and no release-switch marker;"
  : > "$lc_be_log"
  lc_be_run "RHIZO_RELEASE_SWITCH=1" "$lc_be_env"
  [[ "$(tr '\n' ' ' < "$lc_be_env")" == "RHIZO_PERMISSIVE=1 " ]] \
    || lc_be_bad+=" the boot after the tries kept '$(tr '\n' ' ' < "$lc_be_env")', want the fault knob gone;"
  grep -qx 'GUEST systemctl start androidd.service' "$lc_be_log" \
    || lc_be_bad+=" boot_and_start never started androidd: $(tr '\n' '|' < "$lc_be_log");"
  [[ "$(grep '^AT-REBOOT' "$lc_be_log")" == "AT-REBOOT RHIZO_PERMISSIVE=1 " ]] \
    || lc_be_bad+=" the reboot after the tries began with '$(grep '^AT-REBOOT' "$lc_be_log")', want the fault knob gone before it;"
  : > "$lc_be_log"
  lc_be_run "RHIZO_FAULT_NO_READY=1 RHIZO_RELEASE_SWITCH=1" ""
  lc_be_out=$(cat "$lc_be_log")
  [[ "$lc_be_out" == *"echo 'RHIZO_FAULT_NO_READY=1' >> '/root/androidd.env'"* && "$lc_be_out" == *"echo 'RHIZO_RELEASE_SWITCH=1' >> '/root/androidd.env'"* ]] \
    || lc_be_bad+=" the rig's boot_and_start no longer arms both knobs in /root/androidd.env: $(tr '\n' '|' <<<"$lc_be_out");"
  if [[ -z "$lc_be_bad" ]]; then
    ok "1te: a packaged host's GSI legs arm the fault knob in /etc/rhizo/androidd.env for one start, gone before the next reboot, never the rig's release-switch marker, and the rig's legs are unchanged"
  else
    bad "1te:$lc_be_bad"
  fi
  rm -f "$lc_be_env" "$lc_be_log"
  unset -f lc_be_run
  unset lc_be_env lc_be_log lc_be_bad lc_be_out

  lc_gu_run() {
    (
      FAILED=0 EV=$(mktemp -d)
      printf 'claim_id\tresult\n' > "$EV/claims.tsv"
      [[ "$2" != - ]] && printf 'step.6.gsi-update-leg\t%s\n' "$2" >> "$EV/claims.tsv"
      LC_GSI_ARM_STATUS="RHIZO_GSI_UPDATE current=a15 candidate=a16 tries=3 previous=-"
      LC_GSI_CONFIRM_STATUS="RHIZO_GSI_UPDATE current=a16 candidate=- tries=- previous=a15"
      ssh_vm() { :; }
      log() { :; }
      pass() { :; }
      fail() { FAILED=$((FAILED + 1)); echo "FAIL $*"; }
      "$1" server; rc=$?
      echo "rc=$rc F=$FAILED"
      rm -rf "$EV"
    )
  }
  lc_gu_bad=""
  for lc_gu_fn in lc_assert_gsi.update lc_assert_cli.gsi; do
    lc_gu_out=$(lc_gu_run "$lc_gu_fn" pass)
    [[ "$(tail -1 <<<"$lc_gu_out")" == "rc=0 F=0" ]] \
      || lc_gu_bad+=" $lc_gu_fn did not pass on exact lines and a passed update leg: $(tr '\n' '|' <<<"$lc_gu_out");"
    for lc_gu_row in fail -; do
      lc_gu_out=$(lc_gu_run "$lc_gu_fn" "$lc_gu_row")
      [[ "$(tail -1 <<<"$lc_gu_out")" == "rc=1 F=1" && "$lc_gu_out" == *"6.gsi-update-leg"* ]] \
        || lc_gu_bad+=" $lc_gu_fn passed exact lines with the update leg's row '$lc_gu_row': $(tr '\n' '|' <<<"$lc_gu_out");"
    done
  done
  if [[ -z "$lc_gu_bad" ]]; then
    ok "1tf: gsi.update and cli.gsi pass only with step 6's update leg passed, and fail by name on a failed or absent leg under exact arm and confirm lines"
  else
    bad "1tf:$lc_gu_bad"
  fi
  unset -f lc_gu_run
  unset lc_gu_bad lc_gu_fn lc_gu_out lc_gu_row

  lc_as_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/gsi-update-lib.sh"
      FAILED=0 EV=$(mktemp -d)
      printf 'claim_id\tresult\n' > "$EV/claims.tsv"
      [[ "$1" != - ]] && printf 'step.6.gsi-update-leg\t%s\n' "$1" >> "$EV/claims.tsv"
      declare -A GSI_DIR=([a15]=/srv/rhizo/gsi_system_a15 [a16]=/srv/rhizo/gsi_system)
      DESKAPP_PKG=com.rhizo.deskapp LC_GSI_PLANTED_ON=a15 LC_GSI_DATA_TOKEN="$4"
      lc_as_live="$2" lc_as_setting="$3"
      ssh_vm() { printf 'ro.build.version.sdk=36 ro.system.build.version.release=16 '; }
      android_sh() {
        case "$2" in
          getprop*) printf '%b' "$lc_as_live" ;;
          "settings get global $LC_GSI_DATA_KEY") printf '%s' "$lc_as_setting" ;;
          "pm list packages") echo "package:com.rhizo.deskapp" ;;
        esac
      }
      test_scratch_log() { printf '%s/%s.log' "$EV" "$1"; }
      lc_resolve_init() { echo 42; }
      assert_deskapp_launches() { :; }
      log() { :; }
      pass() { :; }
      fail() { FAILED=$((FAILED + 1)); echo "FAIL $*"; }
      lc_assert_gsi.app-survives server; rc=$?
      echo "rc=$rc F=$FAILED"
      rm -rf "$EV"
    )
  }
  lc_as_tok=rhizo-lc-0f0e0d0c
  lc_as_bad=""
  lc_as_out=$(lc_as_run pass '36\n16\n' "$lc_as_tok" "$lc_as_tok")
  [[ "$(tail -1 <<<"$lc_as_out")" == "rc=0 F=0" ]] \
    || lc_as_bad+=" a16 carrying the app and a15's value did not pass: $(tr '\n' '|' <<<"$lc_as_out");"
  lc_as_out=$(lc_as_run fail '36\n16\n' "$lc_as_tok" "$lc_as_tok")
  [[ "$(tail -1 <<<"$lc_as_out")" == "rc=1 F=1" && "$lc_as_out" == *"6.gsi-update-leg"* ]] \
    || lc_as_bad+=" a failed update leg passed: $(tr '\n' '|' <<<"$lc_as_out");"
  lc_as_out=$(lc_as_run pass '35\n15\n' "$lc_as_tok" "$lc_as_tok")
  [[ "$(tail -1 <<<"$lc_as_out")" == "rc=1 F=1" && "$lc_as_out" == *"did not boot a16"* ]] \
    || lc_as_bad+=" a15 still running passed: $(tr '\n' '|' <<<"$lc_as_out");"
  lc_as_out=$(lc_as_run pass '36\n16\n' null "$lc_as_tok")
  [[ "$(tail -1 <<<"$lc_as_out")" == "rc=1 F=1" && "$lc_as_out" == *"reads 'null'"* ]] \
    || lc_as_bad+=" a /data that lost a15's value passed: $(tr '\n' '|' <<<"$lc_as_out");"
  lc_as_out=$(lc_as_run pass '36\n16\n' rhizo-lc-other "$lc_as_tok")
  [[ "$(tail -1 <<<"$lc_as_out")" == "rc=1 F=1" ]] \
    || lc_as_bad+=" another run's value passed: $(tr '\n' '|' <<<"$lc_as_out");"
  lc_as_out=$(lc_as_run pass '36\n16\n' "" "")
  [[ "$(tail -1 <<<"$lc_as_out")" == "rc=1 F=1" && "$lc_as_out" == *"no data value"* ]] \
    || lc_as_bad+=" a plant that recorded no value passed: $(tr '\n' '|' <<<"$lc_as_out");"
  if [[ -z "$lc_as_bad" ]]; then
    ok "1tg: gsi.app-survives passes only on a running a16 after a passed update leg with a15's planted value read back, and fails by name on a failed leg, a15 still running, a lost or foreign value, or no plant"
  else
    bad "1tg:$lc_as_bad"
  fi
  unset -f lc_as_run
  unset lc_as_tok lc_as_bad lc_as_out

  lc_pd_run() {
    (
      FAILED=0 INIT=42 lc_pd_fx=$(mktemp -d)
      echo 0 > "$lc_pd_fx/ms"; echo 0 > "$lc_pd_fx/polls"
      lc_pd_base="$1" lc_pd_after="$2" lc_pd_back="$3"
      date() { echo "$(( $(cat "$lc_pd_fx/ms") * 1000000 ))"; }
      sleep() { echo $(( $(cat "$lc_pd_fx/ms") + ${1%%.*} * 1000 )) > "$lc_pd_fx/ms"; }
      android_sh() {
        case "$2" in
          "toybox stat -c %y /data/system/users/0")
            echo $(( $(cat "$lc_pd_fx/polls") + 1 )) > "$lc_pd_fx/polls"
            if [[ -e "$lc_pd_fx/put" ]]; then printf '%s\n' "$lc_pd_after"; else printf '%s\n' "$lc_pd_base"; fi ;;
          "settings put global $LC_GSI_DATA_KEY "*) printf '%s' "${2##* }" > "$lc_pd_fx/put" ;;
          "settings get global $LC_GSI_DATA_KEY")
            if [[ "$lc_pd_back" == same ]]; then cat "$lc_pd_fx/put"; else printf 'null'; fi ;;
        esac
      }
      log() { :; }
      pass() { :; }
      fail() { FAILED=$((FAILED + 1)); echo "FAIL $*"; }
      _lc_plant_gsi_data a15; rc=$?
      echo "rc=$rc F=$FAILED token=$([[ -n "$LC_GSI_DATA_TOKEN" && "$LC_GSI_DATA_TOKEN" == "$(cat "$lc_pd_fx/put" 2>/dev/null)" ]] && echo set || echo empty) polls=$(cat "$lc_pd_fx/polls")"
      rm -rf "$lc_pd_fx"
    )
  }
  lc_pd_t0='2026-09-25 12:00:00.100000000 +0000' lc_pd_t1='2026-09-25 12:00:01.200000000 +0000'
  lc_pd_bad=""
  lc_pd_out=$(lc_pd_run "$lc_pd_t0" "$lc_pd_t1" same)
  [[ "$lc_pd_out" =~ rc=0\ F=0\ token=set\ polls=([0-9]+)$ ]] && (( BASH_REMATCH[1] >= 4 )) \
    || lc_pd_bad+=" a value read back and renamed onto disk was not planted after the flush ceiling: $(tr '\n' '|' <<<"$lc_pd_out");"
  lc_pd_out=$(lc_pd_run "$lc_pd_t0" "$lc_pd_t0" same)
  [[ "$(tail -1 <<<"$lc_pd_out")" == "rc=1 F=1 token=empty"* && "$lc_pd_out" == *"never proved durable"* ]] \
    || lc_pd_bad+=" a value whose directory never renamed was planted: $(tr '\n' '|' <<<"$lc_pd_out");"
  lc_pd_out=$(lc_pd_run "$lc_pd_t0" "$lc_pd_t1" other)
  [[ "$(tail -1 <<<"$lc_pd_out")" == "rc=1 F=1 token=empty"* && "$lc_pd_out" == *"reads 'null'"* ]] \
    || lc_pd_bad+=" a put the provider never took was planted: $(tr '\n' '|' <<<"$lc_pd_out");"
  lc_pd_out=$(lc_pd_run "" "$lc_pd_t1" same)
  [[ "$(tail -1 <<<"$lc_pd_out")" == "rc=1 F=1 token=empty"* && "$lc_pd_out" == *"mtime is unreadable"* ]] \
    || lc_pd_bad+=" an unreadable settings directory was planted into: $(tr '\n' '|' <<<"$lc_pd_out");"
  if [[ -z "$lc_pd_bad" ]]; then
    ok "1th: step 6 records its planted value only once it read back and its settings directory renamed past the provider's flush ceiling, and fails by name on no rename, a refused put or an unreadable directory"
  else
    bad "1th:$lc_pd_bad"
  fi
  unset -f lc_pd_run
  unset lc_pd_t0 lc_pd_t1 lc_pd_bad lc_pd_out

  lc_br_fx=$(mktemp -d) || exit 1
  lc_br_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      lc_br_deskd="$1" lc_br_auth="$3"
      printf 'rhizo-deskd: listening on 192.168.100.1:47100\nrhizo-deskd: android app authenticated\n' > "$lc_br_fx/deskd.log"
      : > "$lc_br_fx/starts"; rm -f "$lc_br_fx/appended"; echo 0 > "$lc_br_fx/t"; echo 0 > "$lc_br_fx/polls"
      date() { local t; t=$(( $(cat "$lc_br_fx/t") + 1 )); echo "$t" > "$lc_br_fx/t"; echo "$t"; }
      sleep() { :; }
      INIT=4242
      ssh_vm() {
        local body="${*: -1}" n
        body="${body//\/var\/log\/rhizo\/rhizo-deskd.log/$lc_br_fx/deskd.log}"
        case "$body" in
          *'systemctl start'*|*'systemctl restart'*) echo "$body" >> "$lc_br_fx/starts" ;;
          *'systemctl is-active rhizo-deskd.service'*)
            n=$(( $(cat "$lc_br_fx/polls") + 1 )); echo "$n" > "$lc_br_fx/polls"
            if [[ "$lc_br_deskd" == up ]] && (( n >= 3 )); then
              if [[ "$lc_br_auth" == after && ! -e "$lc_br_fx/appended" ]]; then
                printf 'rhizo-deskd: listening on 192.168.100.1:47100\nrhizo-deskd: android app authenticated\n' >> "$lc_br_fx/deskd.log"
                touch "$lc_br_fx/appended"
              fi
              echo active
            else
              echo inactive
            fi ;;
          *'systemctl show -p Result'*) echo exit-code ;;
          *'ActiveState --value rhizo-desk-token.service'*) echo active ;;
          *'stat -c%s'*|*'tail -c +'*) ( eval "$body" ) ;;
        esac
        return 0
      }
      android_sh() {
        case "${*: -1}" in
          *'pm path com.rhizo.desktop'*) echo package:/system_ext/app/RhizoDesktop/RhizoDesktop.apk ;;
          *default_input_method*) echo com.rhizo.desktop/.RhizoIme ;;
          *enabled_notification_listeners*) echo com.rhizo.desktop/com.rhizo.desktop.NotifListener ;;
        esac
      }
      FAILED=0
      lc_br_off=""
      [[ "$2" == size ]] && lc_br_off=$(desk_log_offset /var/log/rhizo/rhizo-deskd.log)
      _lc_desktop_connect_bridge "$lc_br_off" >/dev/null 2>"$lc_br_fx/claim.err"
      echo "RC=$? FAILED=$FAILED STARTS=$(grep -c . "$lc_br_fx/starts")"
    )
  }
  lc_br_out=$(lc_br_run up size after)
  if [[ "$lc_br_out" == "RC=0 FAILED=0 STARTS=0" ]]; then
    ok "1u: the bridge passes when N brings rhizo-deskd up on its own and it authenticates past the pre-restart offset, with no unit started by the cycle"
  else
    bad "1u: the bridge with deskd up on its own read '${lc_br_out:-nothing}': $(grep FAIL "$lc_br_fx/claim.err" | head -1)"
  fi
  for lc_br_case in "down size after|N did not bring rhizo-deskd.service up with the sandbox: rhizo-deskd.service is 'inactive' (Result=exit-code)" \
                    "up size before|logged no 'android app authenticated' past byte" \
                    "up - after|rhizo-deskd.log's size before step 4's restart read '<nothing>', not a byte offset"; do
    IFS='|' read -r lc_br_args lc_br_want <<<"$lc_br_case"
    read -ra lc_br_argv <<<"$lc_br_args"
    lc_br_out=$(lc_br_run "${lc_br_argv[@]}")
    if [[ "$lc_br_out" == "RC=1 FAILED=1 STARTS=0" ]] && grep -qF "$lc_br_want" "$lc_br_fx/claim.err"; then
      ok "1u: the bridge ($lc_br_args) fails by name without starting a unit: $lc_br_want"
    else
      bad "1u: the bridge ($lc_br_args) read '${lc_br_out:-nothing}', want RC=1 FAILED=1 STARTS=0 naming '$lc_br_want': $(grep FAIL "$lc_br_fx/claim.err" | head -1)"
    fi
  done
  lc_br_out=$( (
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
    ssh_vm() { return 255; }
    desk_log_offset /var/log/rhizo/rhizo-deskd.log; echo "RC=$?"
    ssh_vm() { echo 4096; }
    desk_log_offset /var/log/rhizo/rhizo-deskd.log; echo "RC=$?"
  ) 2>/dev/null )
  if [[ "$lc_br_out" == $'RC=1\n4096\nRC=0' ]]; then
    ok "1u: desk_log_offset prints nothing and returns 1 on a read that answers nothing, and the size on one that does"
  else
    bad "1u: desk_log_offset on a dead read, then a live one, printed '$(tr '\n' '|' <<<"$lc_br_out")', want RC=1 with no offset, then 4096 RC=0"
  fi
  lc_br_out=$( (
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
    EV="$lc_br_fx"; : > "$lc_br_fx/calls"
    ssh_vm() { case "${*: -1}" in *'stat -c%s /var/log/rhizo/rhizo-deskd.log'*) echo "CALL stat" >> "$lc_br_fx/calls"; echo 1234 ;; esac; }
    lc_sandbox_up() { echo "CALL sandbox_up $1" >> "$lc_br_fx/calls"; INIT=4242; }
    _lc_desktop_connect_bridge() { echo "CALL bridge $1" >> "$lc_br_fx/calls"; }
    lc_step4_restart gnome >/dev/null 2>&1
    echo "gnome:$(tr '\n' '|' < "$lc_br_fx/calls")"
    : > "$lc_br_fx/calls"
    lc_step4_restart server >/dev/null 2>&1
    echo "server:$(tr '\n' '|' < "$lc_br_fx/calls")"
  ) )
  if [[ "$lc_br_out" == $'gnome:CALL stat|CALL sandbox_up 4|CALL bridge 1234|\nserver:CALL sandbox_up 4|' ]]; then
    ok "1u: lc_step4_restart reads rhizo-deskd.log's size before the sandbox restart and hands that offset to the bridge; server connects no bridge"
  else
    bad "1u: lc_step4_restart's order read '$(tr '\n' ' ' <<<"$lc_br_out")', want the offset read, then lc_sandbox_up 4, then the bridge given that offset"
  fi
  rm -rf "$lc_br_fx"
  unset -f lc_br_run
  unset lc_br_fx lc_br_out lc_br_case lc_br_args lc_br_want lc_br_argv


  lc_db_fx=$(mktemp -d) || exit 1
  lc_db_mk() {
    mkdir -p "$1" "$lc_db_fx/pkg-$3-$4/DEBIAN"
    { printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: selftest <selftest@rig>\n' "$3" "$4"
      [[ -z "${5:-}" ]] || printf 'Depends: %s\n' "$5"
      printf 'Description: selftest\n'; } > "$lc_db_fx/pkg-$3-$4/DEBIAN/control"
    dpkg-deb --build "$lc_db_fx/pkg-$3-$4" "$1/$2" >/dev/null 2>&1
  }
  lc_db_mk "$lc_db_fx/one" rhizo_9.9.9_amd64.deb rhizo 0.1.1
  lc_db_mk "$lc_db_fx/two" rhizo_0.1.9_amd64.deb rhizo 0.1.9
  lc_db_mk "$lc_db_fx/two" rhizo_0.1.10_amd64.deb rhizo 0.1.10
  mkdir -p "$lc_db_fx/none"
  lc_db_run() {
    (
      source "$repo_root/tools/fetch/pools/deb/deb-pool-lib.sh"
      RHIZO_DEB_DIR="$1"; unset RHIZO_KERNEL_DEB_DIR
      [[ "$2" == stub-ok ]] && _lc_deb_require() { return 0; }
      FAILED=0 LC_NEW_DEB="" LC_DEB_NEW_VERSION="" LC_DEB_EVIDENCE=""
      lc_resolve_new_debs >/dev/null 2>"$lc_db_fx/claim.err"
      echo "RC=$? FAILED=$FAILED NEW=${LC_NEW_DEB##*/} V=$LC_DEB_NEW_VERSION${3:+ K=${LC_KERNEL_DEBS[*]##*/}}"
      printf '%s' "$LC_DEB_EVIDENCE"
    )
  }
  lc_db_want="RC=0 FAILED=0 NEW=rhizo_9.9.9_amd64.deb V=0.1.1
deb new=rhizo_9.9.9_amd64.deb version=0.1.1 sha256=$(sha256sum "$lc_db_fx/one/rhizo_9.9.9_amd64.deb" | cut -d' ' -f1)"
  lc_db_out=$(lc_db_run "$lc_db_fx/one" stub-ok)
  if [[ "$lc_db_out" == "$lc_db_want" ]]; then
    ok "1w: the one rhizo .deb resolves, its version read off the package (0.1.1, not the file name's 9.9.9) and its sha256 recorded under its basename"
  else
    bad "1w: the one rhizo .deb read '$(tr '\n' '|' <<<"$lc_db_out")', want '$(tr '\n' '|' <<<"$lc_db_want")': $(grep FAIL "$lc_db_fx/claim.err" | head -1)"
  fi
  lc_db_out=$(lc_db_run "$lc_db_fx/two" stub-ok)
  if [[ "$(head -1 <<<"$lc_db_out")" == "RC=1 FAILED=1 NEW= V=" ]] && grep -q 'new wants exactly one rhizo_\*_amd64.deb in .*, found 2: ' "$lc_db_fx/claim.err" \
     && grep -q 'rhizo_0.1.9_amd64.deb' "$lc_db_fx/claim.err" && grep -q 'rhizo_0.1.10_amd64.deb' "$lc_db_fx/claim.err"; then
    ok "1w: two N builds (0.1.9 beside 0.1.10) fail naming both, never picking one"
  else
    bad "1w: two N builds read '$(tr '\n' '|' <<<"$lc_db_out")': $(grep FAIL "$lc_db_fx/claim.err" | head -1)"
  fi
  lc_db_out=$(lc_db_run "$lc_db_fx/none" stub-ok)
  if [[ "$(head -1 <<<"$lc_db_out")" == "RC=1 FAILED=1 NEW= V=" ]] && [[ "$(grep -c 'found 0: <none>' "$lc_db_fx/claim.err")" == 1 ]]; then
    ok "1w: an empty package dir fails naming the missing rhizo package"
  else
    bad "1w: an empty package dir read '$(tr '\n' '|' <<<"$lc_db_out")': $(grep FAIL "$lc_db_fx/claim.err" | tr '\n' '|')"
  fi
  lc_db_out=$(lc_db_run "$lc_db_fx/one" real)
  if [[ "$lc_db_out" == "RC=1 FAILED=1 NEW=rhizo_9.9.9_amd64.deb V=0.1.1"* ]] \
     && grep -q "rhizo_9.9.9_amd64.deb is not this tree's build (no stamp)" "$lc_db_fx/claim.err"; then
    ok "1w: a rhizo .deb with no build stamp is refused as not this tree's build"
  else
    bad "1w: an unstamped rhizo .deb read '$(tr '\n' '|' <<<"$lc_db_out")': $(grep FAIL "$lc_db_fx/claim.err" | head -1)"
  fi
  lc_db_mk "$lc_db_fx/kern" rhizo_0.1.2_amd64.deb rhizo 0.1.2 "libc6, linux-image-rhizo, linux-headers-rhizo"
  lc_db_mk "$lc_db_fx/kern" linux-image-rhizo_9.9.9-1_amd64.deb linux-image-rhizo 9.9.9-1 "linux-image-9.9.9-rhizo (= 9.9.9-1)"
  lc_db_mk "$lc_db_fx/kern" linux-headers-rhizo_9.9.9-1_amd64.deb linux-headers-rhizo 9.9.9-1 "linux-headers-9.9.9-rhizo (= 9.9.9-1)"
  lc_db_mk "$lc_db_fx/kern" linux-image-9.9.9-rhizo_9.9.9-1_amd64.deb linux-image-9.9.9-rhizo 9.9.9-1
  lc_db_mk "$lc_db_fx/kern" linux-headers-9.9.9-rhizo_9.9.9-1_amd64.deb linux-headers-9.9.9-rhizo 9.9.9-1
  lc_db_out=$(lc_db_run "$lc_db_fx/kern" stub-ok kernel)
  if [[ "$(head -1 <<<"$lc_db_out")" == "RC=0 FAILED=0 NEW=rhizo_0.1.2_amd64.deb V=0.1.2 K=linux-headers-rhizo_9.9.9-1_amd64.deb linux-headers-9.9.9-rhizo_9.9.9-1_amd64.deb linux-image-rhizo_9.9.9-1_amd64.deb linux-image-9.9.9-rhizo_9.9.9-1_amd64.deb" ]] \
     && [[ "$(grep -c '^deb kernel=linux-\(image\|headers\)-\(9.9.9-\)\{0,1\}rhizo_9.9.9-1_amd64.deb version=9.9.9-1 sha256=[0-9a-f]\{64\}$' <<<"$lc_db_out")" == 4 ]]; then
    ok "1w: an N depending on the Rhizo kernel resolves its two meta .debs and the two they pin, each recorded with its version and sha256"
  else
    bad "1w: an N depending on the Rhizo kernel read '$(tr '\n' '|' <<<"$lc_db_out")': $(grep FAIL "$lc_db_fx/claim.err" | head -1)"
  fi
  lc_db_out=$(RHIZO_GUEST_OS=cachyos lc_db_run "$lc_db_fx/kern" stub-ok kernel)
  if [[ "$(head -1 <<<"$lc_db_out")" == "RC=0 FAILED=0 NEW=rhizo_0.1.2_amd64.deb V=0.1.2 K=" ]]; then
    ok "1w: a cachyos cycle resolves no Ubuntu kernel .deb"
  else
    bad "1w: a cachyos cycle read '$(tr '\n' '|' <<<"$lc_db_out")'"
  fi
  mv "$lc_db_fx/kern/linux-headers-9.9.9-rhizo_9.9.9-1_amd64.deb" "$lc_db_fx/"
  lc_db_out=$(lc_db_run "$lc_db_fx/kern" stub-ok kernel)
  if [[ "$(head -1 <<<"$lc_db_out")" == "RC=1 FAILED=1 NEW=rhizo_0.1.2_amd64.deb V=0.1.2 K=" ]] \
     && grep -q 'depends on a Rhizo kernel .deb .* lacks' "$lc_db_fx/claim.err" && grep -qF 'linux-headers-9.9.9-rhizo (= 9.9.9-1)' "$lc_db_fx/claim.err"; then
    ok "1w: a missing versioned headers .deb fails naming the package and version its meta .deb pins"
  else
    bad "1w: a missing versioned headers .deb read '$(tr '\n' '|' <<<"$lc_db_out")': $(tr '\n' '|' < "$lc_db_fx/claim.err")"
  fi
  rm -rf "$lc_db_fx"
  unset -f lc_db_mk lc_db_run
  unset lc_db_fx lc_db_out lc_db_want

  _lc_st_raw_starts() { declare -f "$@" | grep -nE 'guest_uptime|systemctl start androidd'; }
  lc_st_raw_start() { local t0; t0=$(guest_uptime); ssh_vm -t 600 'systemctl start androidd.service'; wait_sandbox_started 420 "$t0"; }
  lc_x_hits=$(_lc_st_raw_starts lifecycle_run_cycle lc_step3_finish_upgrade lc_step4_restart lc_step5_app_check)
  if [[ -z "$(_lc_st_raw_starts lc_st_raw_start)" ]]; then
    bad "1x: the raw-start scan misses a function that reads guest_uptime and starts androidd itself"
  elif [[ -n "$lc_x_hits" ]]; then
    bad "1x: a step starts the sandbox without lc_sandbox_up: $(tr '\n' '|' <<<"$lc_x_hits")"
  elif ! grep -q 'step_claim 2.sandbox-up lc_sandbox_up 2' <<<"$(declare -f lifecycle_run_cycle)" \
       || ! grep -q 'step_claim 4.sandbox-up lc_sandbox_up 4' <<<"$(declare -f lc_step4_restart)"; then
    bad "1x: step 2 or step 4 no longer starts its sandbox through lc_sandbox_up"
  else
    ok "1x: steps 2, 3, 4, 5 and 8 start the sandbox only through lc_sandbox_up (the scan flags a raw guest_uptime + systemctl start)"
  fi
  unset -f _lc_st_raw_starts lc_st_raw_start
  unset lc_x_hits

  lc_ac_fx=$(mktemp -d) || exit 1
  lc_ac_run() {
    (
      TEST_APT_OFFLINE_CONF="$lc_ac_fx/apt.conf"; rm -f "$TEST_APT_OFFLINE_CONF"
      [[ "$1" == present ]] && echo 'Dir::Etc::sourcelist "x";' > "$TEST_APT_OFFLINE_CONF"
      ssh_vm() { [[ "$lc_ac_mode" == dead ]] && return 255; ( eval "${*: -1}" ); }
      lc_ac_mode="$1" FAILED=0
      lc_apt_conf_present 8 >/dev/null 2>"$lc_ac_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_ac_bad=""
  [[ "$(lc_ac_run present)" == "RC=0 FAILED=0" ]] || lc_ac_bad+=" present: $(lc_ac_run present);"
  for lc_ac_mode in missing dead; do
    [[ "$(lc_ac_run "$lc_ac_mode")" == "RC=1 FAILED=1" ]] && grep -qF "the offline apt configuration $lc_ac_fx/apt.conf is not on the guest" "$lc_ac_fx/claim.err" \
      || lc_ac_bad+=" $lc_ac_mode: $(lc_ac_run "$lc_ac_mode") $(head -1 "$lc_ac_fx/claim.err");"
  done
  for lc_ac_step in 8 9b 10; do
    lc_ac_text=$(declare -f lifecycle_run_cycle | sed -n "/lc_step${lc_ac_step}_reinstall ()/,/^ *}/p")
    grep -q "lc_apt_conf_present $lc_ac_step" <<<"$lc_ac_text" \
      && [[ "$(grep -n 'lc_apt_conf_present\|installer_install_reboot_prepare' <<<"$lc_ac_text" | head -1)" == *lc_apt_conf_present* ]] \
      || lc_ac_bad+=" step $lc_ac_step's reinstall does not check the conf before installer_install_reboot_prepare;"
  done
  for lc_ac_range in "0 2 no" "4 4 no" "0 3 yes" "9b 10 yes" "4 7 no" "5 8 yes"; do
    read -r lc_ac_from lc_ac_to lc_ac_want <<<"$lc_ac_range"
    lc_ac_got=$( LC_FROM_IDX=$(_lc_step_index "$lc_ac_from"); LC_TO_IDX=$(_lc_step_index "$lc_ac_to")
                 _lc_range_needs_n && echo yes || echo no )
    [[ "$lc_ac_got" == "$lc_ac_want" ]] || lc_ac_bad+=" steps $lc_ac_from..$lc_ac_to need N: $lc_ac_got, want $lc_ac_want;"
  done
  if [[ -z "$lc_ac_bad" ]]; then
    ok "1y: a reinstall's apt conf check passes a present conf and fails a missing or unread one by name, runs before each of steps 8/9b/10's installs, and N resolves only for a range that installs it"
  else
    bad "1y:$lc_ac_bad"
  fi
  rm -rf "$lc_ac_fx"
  unset -f lc_ac_run
  unset lc_ac_fx lc_ac_bad lc_ac_mode lc_ac_step lc_ac_text lc_ac_range lc_ac_from lc_ac_to lc_ac_want lc_ac_got

  lc_apt_fx=$(mktemp -d) || exit 1
  lc_apt_run() {
    (
      EV="$lc_apt_fx" FAILED=0 lc_apt_answer="$2"
      printf 'claim_id\tresult\nstep.5.ubuntu-update\t%s\n' "$1" > "$EV/claims.tsv"
      ssh_vm() { printf '%s' "$lc_apt_answer"; }
      lc_assert_install.apt-helpers-as-root >/dev/null 2>"$lc_apt_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_apt_case() {
    local out; out=$(lc_apt_run "$2" "$3")
    if [[ "$4" == pass ]]; then
      [[ "$out" == "RC=0 FAILED=0" ]] || lc_apt_bad+=" $1: $out $(grep FAIL "$lc_apt_fx/claim.err" | head -1);"
    elif [[ "$out" != "RC=1 FAILED=1" ]] || ! grep -qF "$4" "$lc_apt_fx/claim.err"; then
      lc_apt_bad+=" $1: $out, want a fail naming '$4': $(grep FAIL "$lc_apt_fx/claim.err" | head -1);"
    fi
  }
  lc_apt_good=$'enforce=1\nlink=/usr/lib/rhizo/host-mode/etc/apt/apt.conf.d/50rhizo\nAPT::Sandbox::User "root";\nowner=root:root /var/lib/apt/lists/partial\nowner=root:root /var/lib/apt/lists/auxfiles\nowner=root:root /var/cache/apt/archives/partial\nDONE'
  lc_apt_bad=""
  lc_apt_case "good guest" pass "$lc_apt_good" pass
  lc_apt_case "permissive" pass "${lc_apt_good/enforce=1/enforce=0}" "/sys/fs/selinux/enforce reads '0', want 1"
  lc_apt_case "no link" pass "${lc_apt_good/link=\/usr\/lib\/rhizo\/host-mode/link=}" "is not host mode's link"
  lc_apt_case "sandbox _apt" pass "${lc_apt_good/\"root\"/\"_apt\"}" "apt-config does not read APT::Sandbox::User"
  lc_apt_case "partial still _apt" pass "${lc_apt_good/owner=root:root \/var\/lib\/apt\/lists\/partial/owner=_apt:root /var/lib/apt/lists/partial}" "2 of apt's 3 partial dirs are root:root"
  lc_apt_case "no DONE" pass "${lc_apt_good%DONE}" "incomplete guest read (no DONE token)"
  lc_apt_case "step 5 failed" fail "$lc_apt_good" "step.5.ubuntu-update did not pass"
  lc_apt_case "step 5 failed on an _apt partial dir" fail "${lc_apt_good/owner=root:root \/var\/lib\/apt\/lists\/partial/owner=_apt:root /var/lib/apt/lists/partial}" "owner=_apt:root /var/lib/apt/lists/partial"
  if [[ -z "$lc_apt_bad" ]]; then
    ok "1z: install.apt-helpers-as-root passes a good guest and fails by name on permissive, no 50rhizo link, sandbox _apt, an _apt partial dir, no DONE and a step 5 that did not pass, naming the dir owners when both fail"
  else
    bad "1z:$lc_apt_bad"
  fi
  rm -rf "$lc_apt_fx"
  unset -f lc_apt_run lc_apt_case
  unset lc_apt_fx lc_apt_good lc_apt_bad

  lc_hp_fx=$(mktemp -d) || exit 1
  python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$lc_hp_fx/qmp.sock"
  lc_hp_fw_pairs() {
    local i
    for (( i = 0; i < $1; i++ )); do
      echo "[ 4480.54] audit: type=1400 audit(1790432037.003:$((206166 + 2 * i))): avc:  denied  { dac_read_search } for  pid=$2 comm=\"fwupd\" capability=2  scontext=u:r:rhizo_host:s0 tcontext=u:r:rhizo_host:s0 tclass=capability permissive=0"
      echo "[ 4480.54] audit: type=1400 audit(1790432037.003:$((206167 + 2 * i))): avc:  denied  { dac_override } for  pid=$2 comm=\"fwupd\" capability=1  scontext=u:r:rhizo_host:s0 tcontext=u:r:rhizo_host:s0 tclass=capability permissive=0"
    done
  }
  lc_hp_udisksd_pair='[ 4480.60] audit: type=1400 audit(1790432037.100:7): avc:  denied  { dac_read_search } for  pid=412 comm="udisksd" capability=2  scontext=u:r:rhizo_host:s0 tcontext=u:r:rhizo_host:s0 tclass=capability permissive=0
[ 4480.60] audit: type=1400 audit(1790432037.100:8): avc:  denied  { dac_override } for  pid=412 comm="udisksd" capability=1  scontext=u:r:rhizo_host:s0 tcontext=u:r:rhizo_host:s0 tclass=capability permissive=0'
  lc_hp_run() {
    (
      REPO="$lc_hp_fx" VAR_DIR="$lc_hp_fx" SUFFIX="" QMP_SOCK="$lc_hp_fx/qmp.sock" FAILED=0 lc_hp_mode="$1"
      [[ "$1" == no-qmp ]] && QMP_SOCK="$lc_hp_fx/absent.sock"
      rm -f "$lc_hp_fx/kbd.plugged" "$lc_hp_fx/blk.plugged" "$lc_hp_fx/mon.started" "$lc_hp_fx/mon.stopped" "$lc_hp_fx/fwpid.reads" "$lc_hp_fx/fwq.reads" \
            "$lc_hp_fx/udev.reads"
      : > "$lc_hp_fx/qmp.log"
      lc_hp_qmp() {
        printf '%s\n' "$1" >> "$lc_hp_fx/qmp.log"
        case "$1" in
          *'"device_add"'*rhzhp_kbd*)
            if [[ "$lc_hp_mode" == kbd-refused ]]; then
              echo '{"error": {"class": "GenericError", "desc": "Bus pci.0 does not support hotplugging"}}'
              return 0
            fi
            touch "$lc_hp_fx/kbd.plugged" ;;
          *'"device_add"'*rhzhp_blk*) touch "$lc_hp_fx/blk.plugged" ;;
        esac
        echo '{"return": {}}'
      }
      ssh_vm() {
        local body="${*: -1}" lbl=u:object_r:rhizo_host_device:s0
        case "$body" in
          "$LC_HP_LISTENERS_SH")
            echo x >> "$lc_hp_fx/udev.reads"
            case "$lc_hp_mode:$(wc -l < "$lc_hp_fx/udev.reads")" in
              udev-unmeasured:*) echo 'systemd=258 udevd=300 mon=301' ;;
              udevd-restart:2) echo 'systemd=262 udevd=377 mon=301' ;;
              udev-nomon:*) echo 'systemd=262 udevd=300 mon=' ;;
              udev*) echo 'systemd=262 udevd=300 mon=301' ;;
              *) echo 'systemd=255 udevd=300 mon=301' ;;
            esac ;;
          'cat /sys/fs/selinux/enforce') echo 1 ;;
          'cat /proc/self/attr/current') printf 'u:r:rhizo_host:s0\0' ;;
          *systemd-udevd.service*)
            if [[ "$lc_hp_mode" == udevd-kernel ]]; then printf 'u:r:kernel:s0\0'; else printf 'u:r:rhizo_host:s0\0'; fi ;;
          *os.getxattr*)
            case "$body" in
              *"'/usr/bin/kmod' 2>"*) lbl=u:object_r:rhizo_host_exec:s0 ;;
              *"dummy.ko.zst' 2>"*) lbl=u:object_r:rhizo_host_module_file:s0 ;;
              *"'/dev/input/event5' 2>"*) [[ "$lc_hp_mode" == ev-device ]] && lbl=u:object_r:device:s0 ;;
            esac
            echo "$lbl" ;;
          'modinfo -n dummy') echo /lib/modules/6.8.0-150-generic/kernel/drivers/net/dummy.ko.zst ;;
          *'modprobe -r dummy 2>/dev/null; test -d /sys/module/dummy && echo loaded || echo gone')
            case "$lc_hp_mode" in dummy-stuck) echo loaded ;; dummy-unread) return 255 ;; *) echo gone ;; esac ;;
          'modprobe -r virtio_input 2>/dev/null; test -d /sys/module/virtio_input && echo yes || echo no')
            if [[ "$lc_hp_mode" == kbd-preloaded ]]; then echo yes; else echo no; fi ;;
          'ip link add rhzhp0 type dummy') [[ "$lc_hp_mode" != no-autoload ]] || return 2 ;;
          'test -d /sys/module/dummy && echo yes || echo no'|'ip -o link show'*)
            if [[ "$lc_hp_mode" == no-autoload ]]; then echo no; else echo yes; fi ;;
          *'grep "^ADD " /run/rhizo-lc-hpmon.log'*)
            touch "$lc_hp_fx/mon.stopped"
            [[ "$lc_hp_mode" == mon-blind ]] || case "$lc_hp_mode" in
              mon-gone) echo 'ADD /module/dummy gone' ;;
              mon-unread) echo 'ADD /module/dummy unread' ;;
              fwupd-anyread) echo 'ADD /module/dummy 240' ;;
              *) echo 'ADD /module/dummy 200' ;;
            esac
            printf '%s\n' 'ADD /devices/virtual/net/rhzhp0 644' 'ADD /devices/virtual/net/rhzhp0/queues/rx-0 none' \
              'ADD /devices/pci0000:00/0000:00:1e.0 644' 'ADD /devices/pci0000:00/0000:00:1e.0/virtio6 644' \
              'ADD /module/virtio_input 200' 'ADD /bus/virtio/drivers/virtio_input 200' \
              'ADD /devices/pci0000:00/0000:00:1e.0/virtio6/input/input32/event4 644' \
              'ADD /devices/pci0000:00/0000:00:1f.0/virtio7/block/vdc 644'
            [[ "$lc_hp_mode" != idle-gone ]] || echo 'ADD /devices/virtual/net/rhzhp1 gone'
            [[ "$lc_hp_mode" != udev-other ]] || echo 'ADD /devices/virtual/misc/rhzwo 200'
            [[ "$lc_hp_mode" == mon-cut ]] || echo DONE ;;
          *' --unit=rhizo-lc-hpmon '*)
            touch "$lc_hp_fx/mon.started"
            [[ "$lc_hp_mode" == mon-dead ]] || echo READY ;;
          'systemctl show -p MainPID --value fwupd.service')
            echo x >> "$lc_hp_fx/fwpid.reads"
            case "$lc_hp_mode" in
              fwupd-restart) if [[ "$(wc -l < "$lc_hp_fx/fwpid.reads")" == 1 ]]; then echo 5945; else echo 6001; fi ;;
              fwupd-unread) echo 'Failed to connect to bus: No such file or directory' ;;
              fwupd-idle) echo 0 ;;
              fwupd|fwupd-*|mon-gone|mon-unread) echo 5945 ;;
              *) echo 0 ;;
            esac ;;
          *'/proc/net/netlink'*)
            echo x >> "$lc_hp_fx/fwq.reads"
            case "$lc_hp_mode:$(wc -l < "$lc_hp_fx/fwq.reads")" in
              fwupd-queued:2) echo '2048 0' ;;
              fwupd-dropped:1) echo '0 3' ;;
              fwupd-dropped:2) echo '0 5' ;;
              fwupd-nosock:*) ;;
              *) echo '0 0' ;;
            esac ;;
          "echo 'LC_SENTINEL_"*) return 0 ;;
          "dmesg | awk -v s='LC_SENTINEL_"*"' '\$NF==s'") sed -n "s/^dmesg | awk -v s='\(LC_SENTINEL_[^']*\)' .*/\1/p" <<<"$body" ;;
          "dmesg | awk -v s='LC_SENTINEL_"*"' -v e='LC_SENTINEL_"*)
            case "$lc_hp_mode" in
              window-cut) echo LC_WINDOW_START ;;
              scrolled) echo DONE ;;
              *) echo LC_WINDOW_START
                 case "$lc_hp_mode" in
                   denial) echo '[   90.1] audit: type=1400 audit(1.0:9): avc:  denied  { read } for  pid=412 comm="udisksd" name="vdc" scontext=u:r:rhizo_host:s0 tcontext=u:object_r:device:s0 tclass=blk_file permissive=0' ;;
                   kernel-denial) echo '[   90.3] audit: type=1400 audit(1.0:10): avc:  denied  { mknod } for  pid=33 comm="kdevtmpfs" capability=27  scontext=u:r:kernel:s0 tcontext=u:r:kernel:s0 tclass=capability permissive=0' ;;
                   sandbox-noise) echo '[  841.4] audit: type=1400 audit(1790262306.779:4040): avc:  denied  { sys_ptrace } for  pid=12064 comm="init" capability=19  scontext=u:r:init:s0 tcontext=u:r:init:s0 tclass=capability permissive=0' ;;
                   audit-lost) echo '[   90.2] audit: audit_lost=3 audit_rate_limit=0 audit_backlog_limit=64' ;;
                   printk-limit) echo '[   90.2] audit: printk limit exceeded' ;;
                   fwupd-extra) lc_hp_fw_pairs 10 5945 ;;
                   fwupd-planted) lc_hp_fw_pairs 1 5945 | head -1; echo "$lc_hp_udisksd_pair"
                                  lc_hp_fw_pairs 1 5945 | tail -1; lc_hp_fw_pairs 8 5945 ;;
                   fwupd-rawio) lc_hp_fw_pairs 9 5945
                                echo '[ 4480.70] audit: type=1400 audit(1790432037.200:9): avc:  denied  { sys_rawio } for  pid=5945 comm="fwupd" capability=17  scontext=u:r:rhizo_host:s0 tcontext=u:r:rhizo_host:s0 tclass=capability permissive=0' ;;
                   fwupd|fwupd-*) lc_hp_fw_pairs 9 5945 ;;
                   udev|udev-*) lc_hp_fw_pairs "$([[ "$lc_hp_mode" == udev-extra ]] && echo 4 || echo 3)" 300 | sed 's/comm="fwupd"/comm="systemd-udevd"/'
                                lc_hp_fw_pairs 3 301 | sed 's/comm="fwupd"/comm="udevadm"/'
                                paste -d '\n' <(lc_hp_fw_pairs 1 4240 | sed 's/comm="fwupd"/comm="(udev-worker)"/') \
                                               <(lc_hp_fw_pairs 1 4242 | sed 's/comm="fwupd"/comm="(udev-worker)"/')
                                lc_hp_fw_pairs "$(case "$lc_hp_mode" in udev-worker-fewer) echo 1 ;; udev-worker-extra) echo 3 ;; *) echo 2 ;; esac)" 4241 \
                                  | sed 's/comm="fwupd"/comm="(udev-worker)"/' ;;
                   binfmt) echo '[  827.33] audit: type=1400 audit(1790470872.725:8893): avc:  denied  { remount } for  pid=40139 comm="(ostnamed)" scontext=u:r:rhizo_host:s0 tcontext=u:object_r:binfmt_miscfs:s0 tclass=filesystem permissive=0' ;;
                   binfmt-other) echo '[  827.33] audit: type=1400 audit(1790470872.725:8893): avc:  denied  { remount } for  pid=40139 comm="mount" scontext=u:r:rhizo_host:s0 tcontext=u:object_r:binfmt_miscfs:s0 tclass=filesystem permissive=0' ;;
                   journald) echo '[  827.30] audit: type=1400 audit(1790470872.695:8891): avc:  denied  { dac_read_search } for  pid=2362 comm="systemd-journal" capability=2  scontext=u:r:rhizo_host:s0 tcontext=u:r:rhizo_host:s0 tclass=capability permissive=0'
                             echo '[  827.30] audit: type=1400 audit(1790470872.695:8892): avc:  denied  { dac_override } for  pid=2362 comm="systemd-journal" capability=1  scontext=u:r:rhizo_host:s0 tcontext=u:r:rhizo_host:s0 tclass=capability permissive=0' ;;
                   userns) echo '[  827.37] audit: type=1400 audit(1790470872.772:8897): avc:  denied  { create } for  pid=40143 comm="(upowerd)" scontext=u:r:rhizo_host:s0 tcontext=u:r:rhizo_host:s0 tclass=user_namespace permissive=0' ;;
                 esac
                 echo LC_WINDOW_END; echo DONE ;;
            esac ;;
          'test -d /sys/module/virtio_input && echo yes || echo no')
            if [[ -e "$lc_hp_fx/kbd.plugged" ]]; then echo yes; else echo no; fi ;;
          'for e in /sys/class/input/event*'*) [[ ! -e "$lc_hp_fx/kbd.plugged" ]] || echo /dev/input/event5 ;;
          'readlink -f /dev/disk/by-id/virtio-rhzhp') [[ ! -e "$lc_hp_fx/blk.plugged" ]] || echo /dev/vdc ;;
          "stat -c %G '/dev/input/event5'") echo input ;;
          "test -e '"*) if [[ "$lc_hp_mode" == present ]]; then echo present; else echo gone; fi ;;
          'ip link del rhzhp0'*|'udevadm wait'*) return 0 ;;
          *) return 255 ;;
        esac
      }
      lc_assert_host.hotplug-after-flip >/dev/null 2>"$lc_hp_fx/claim.err"
      echo "RC=$? FAILED=$FAILED IMG=$([[ -e "$lc_hp_fx/rhzhp.img" ]] && echo left || echo gone)"
    )
  }
  lc_hp_sent() { sed -E 's/.*"execute":"([a-z_-]+)".*"(id|node-name)":"([a-z_]+)".*/\1 \3/' "$lc_hp_fx/qmp.log" | tr '\n' '|'; }
  lc_hp_cycle="device_add rhzhp_kbd|blockdev-add rhzhp|device_add rhzhp_blk|device_del rhzhp_kbd|device_del rhzhp_blk|blockdev-del rhzhp|"
  lc_hp_bad=""
  lc_hp_mon_left() {
    [[ ! -e "$lc_hp_fx/mon.started" || -e "$lc_hp_fx/mon.stopped" ]] || lc_hp_bad+=" $1: the add monitor was started and never stopped;"
  }
  for lc_hp_mode in good sandbox-noise fwupd idle-gone binfmt udev udev-worker-fewer; do
    lc_hp_out=$(lc_hp_run "$lc_hp_mode")
    [[ "$lc_hp_out" == "RC=0 FAILED=0 IMG=gone" && "$(lc_hp_sent)" == "$lc_hp_cycle" ]] \
      || lc_hp_bad+=" $lc_hp_mode: $lc_hp_out sent '$(lc_hp_sent)' $(grep FAIL "$lc_hp_fx/claim.err" | head -1);"
    lc_hp_mon_left "$lc_hp_mode"
    [[ "$lc_hp_mode" != fwupd ]] \
      || grep -qF 'fwupd (pid 5945) refused 9 uevent reads, all derived from 3 adds of a uevent with no read bit' "$lc_hp_fx/claim.err" \
      || lc_hp_bad+=" fwupd: the pass line does not account 9 pairs to 3 unreadable adds: $(grep 'ok:' "$lc_hp_fx/claim.err" | head -1);"
    [[ "$lc_hp_mode" != udev ]] \
      || grep -qF "systemd 262's udev refused the uevent reads 2 module and 1 driver adds derive" "$lc_hp_fx/claim.err" \
      || lc_hp_bad+=" udev: the pass line does not account udev's reads to 2 module and 1 driver adds: $(grep 'ok:' "$lc_hp_fx/claim.err" | head -1);"
    [[ "$lc_hp_mode" != binfmt ]] \
      || grep -qF '1 binfmt_misc remount(s) a service start made in its own namespace' "$lc_hp_fx/claim.err" \
      || lc_hp_bad+=" binfmt: the pass line does not account the service's refused binfmt_misc remount: $(grep 'ok:' "$lc_hp_fx/claim.err" | head -1);"
  done
  for lc_hp_case in "no-qmp|no QMP socket at '$lc_hp_fx/absent.sock'|" \
                    "udevd-kernel|systemd-udevd runs as 'u:r:kernel:s0', not rhizo_host|" \
                    "dummy-stuck|dummy reads 'loaded' after modprobe -r, not gone|" \
                    "dummy-unread|dummy reads '<unread>' after modprobe -r, not gone|" \
                    "no-autoload|ip link add type dummy rc=2, module loaded=no, link=no|" \
                    "kbd-preloaded|virtio_input reads 'yes' before the plug, not unloaded|" \
                    "kbd-refused|QMP refused the virtio keyboard|device_add rhzhp_kbd|" \
                    "ev-device|/dev/input/event5 is u:object_r:device:s0|$lc_hp_cycle" \
                    "denial|host denials: [   90.1] audit: type=1400 audit(1.0:9): avc:  denied  { read } for  pid=412 comm=\"udisksd\"|$lc_hp_cycle" \
                    "kernel-denial|host denials: [   90.3] audit: type=1400 audit(1.0:10): avc:  denied  { mknod } for  pid=33 comm=\"kdevtmpfs\"|$lc_hp_cycle" \
                    "window-cut|the kmsg window from the autoload to the unplug was not read whole|$lc_hp_cycle" \
                    "scrolled|the kmsg window from the autoload to the unplug was not read whole|$lc_hp_cycle" \
                    "audit-lost|the kmsg window from the autoload to the unplug was not read whole|$lc_hp_cycle" \
                    "printk-limit|the kmsg window from the autoload to the unplug was not read whole|$lc_hp_cycle" \
                    "present|a node outlived its device_del (present)|$lc_hp_cycle" \
                    "mon-dead|the udev add monitor on the guest never printed READY (got '<nothing>')|" \
                    "mon-blind|the udev add monitor logged no add of /module/dummy|$lc_hp_cycle" \
                    "mon-gone|the add monitor could not read /module/dummy/uevent (gone)|$lc_hp_cycle" \
                    "mon-unread|the add monitor could not read /module/dummy/uevent (unread)|$lc_hp_cycle" \
                    "fwupd-queued|fwupd's udev socket read '0 0' (queued bytes, drops) at the window's start and '2048 0' at the monitor's stop|$lc_hp_cycle" \
                    "fwupd-dropped|fwupd's udev socket read '0 3' (queued bytes, drops) at the window's start and '0 5' at the monitor's stop|$lc_hp_cycle" \
                    "fwupd-nosock|fwupd's udev socket read '<none>' (queued bytes, drops) at the window's start and '<none>' at the monitor's stop|$lc_hp_cycle" \
                    "mon-cut|the udev add monitor's log did not read back|$lc_hp_cycle" \
                    "fwupd-extra|fwupd (pid 5945) logged 10 dac_read_search/dac_override pairs where the window's 3 adds of a uevent with no read bit derive 9|$lc_hp_cycle" \
                    "fwupd-anyread|fwupd (pid 5945) logged 9 dac_read_search/dac_override pairs where the window's 2 adds of a uevent with no read bit derive 6|$lc_hp_cycle" \
                    "fwupd-planted|host denials: [ 4480.60] audit: type=1400 audit(1790432037.100:7): avc:  denied  { dac_read_search } for  pid=412 comm=\"udisksd\"|$lc_hp_cycle" \
                    "fwupd-rawio|host denials: [ 4480.70] audit: type=1400 audit(1790432037.200:9): avc:  denied  { sys_rawio } for  pid=5945 comm=\"fwupd\"|$lc_hp_cycle" \
                    "fwupd-idle|host denials: [ 4480.54] audit: type=1400 audit(1790432037.003:206166): avc:  denied  { dac_read_search } for  pid=5945 comm=\"fwupd\"|$lc_hp_cycle" \
                    "fwupd-restart|fwupd.service's MainPID read '5945' before the window and '6001' after it|$lc_hp_cycle" \
                    "fwupd-unread|fwupd.service's MainPID read '<unread>' before the window|$lc_hp_cycle" \
                    "udev-extra|systemd-udevd (pid 300) logged 4 dac_read_search/dac_override pairs where the window's 2 module and 1 driver adds of a uevent with no read bit derive 3 (systemd 262)|$lc_hp_cycle" \
                    "udev-worker-extra|(udev-worker) (every pid) logged 5 dac_read_search/dac_override pairs where the window's 2 module and 1 driver adds of a uevent with no read bit derive at most 4 (systemd 262)|$lc_hp_cycle" \
                    "udev-other|the window added a uevent with no read bit outside a module or a driver (/devices/virtual/misc/rhzwo)|$lc_hp_cycle" \
                    "udev-unmeasured|systemd '258' (listeners read 'systemd=258 udevd=300 mon=301'): how often its udev listeners read an unreadable uevent is not measured|$lc_hp_cycle" \
                    "udevd-restart|udev's listeners read 'systemd=262 udevd=300 mon=301' before the window and 'systemd=262 udevd=377 mon=301' at the monitor's stop|$lc_hp_cycle" \
                    "udev-nomon|udev's listeners read 'systemd=262 udevd=300 mon=' before the window|$lc_hp_cycle" \
                    "binfmt-other|host denials: [  827.33] audit: type=1400 audit(1790470872.725:8893): avc:  denied  { remount } for  pid=40139 comm=\"mount\"|$lc_hp_cycle" \
                    "journald|host denials: [  827.30] audit: type=1400 audit(1790470872.695:8891): avc:  denied  { dac_read_search } for  pid=2362 comm=\"systemd-journal\"|$lc_hp_cycle" \
                    "userns|host denials: [  827.37] audit: type=1400 audit(1790470872.772:8897): avc:  denied  { create } for  pid=40143 comm=\"(upowerd)\"|$lc_hp_cycle"; do
    IFS='|' read -r lc_hp_mode lc_hp_want lc_hp_sent_want <<<"$lc_hp_case"
    [[ "$lc_hp_case" == *"|$lc_hp_cycle" ]] && lc_hp_sent_want="$lc_hp_cycle"
    [[ -n "$lc_hp_sent_want" && "$lc_hp_sent_want" != *'|' ]] && lc_hp_sent_want+='|'
    lc_hp_out=$(lc_hp_run "$lc_hp_mode")
    if [[ "$lc_hp_out" != "RC=1 FAILED=1 IMG=gone" ]] || ! grep -qF "$lc_hp_want" "$lc_hp_fx/claim.err" \
       || [[ "$(lc_hp_sent)" != "$lc_hp_sent_want" ]]; then
      lc_hp_bad+=" $lc_hp_mode: $lc_hp_out sent '$(lc_hp_sent)', want a fail naming '$lc_hp_want' after sending '$lc_hp_sent_want': $(grep FAIL "$lc_hp_fx/claim.err" | head -1);"
    fi
    lc_hp_mon_left "$lc_hp_mode"
  done
  grep -qF 'udevadm monitor --udev | while' <<<"$LC_HP_MON_SH" && grep -qF 'if [ "$src $ts" = "UDEV -" ]; then echo READY' <<<"$LC_HP_MON_SH" \
    || lc_hp_bad+=" LC_HP_MON_SH no longer reads every udev add or no longer prints READY on udevadm's UDEV header;"
  declare -f lc_assert_host.hotplug-after-flip | awk '/lc_hp_mon_start/ && !m { m = NR } /lc_dmesg_sentinel/ && !s { s = NR } END { exit !(m && s && s < m) }' \
    || lc_hp_bad+=" host.hotplug-after-flip starts the add monitor before its start sentinel;"
  declare -f lc_assert_host.hotplug-after-flip | awk '/modprobe -r dummy/ { d = NR } /device_del.*rhzhp_blk/ && !u { u = NR } /mon=\$\(lc_hp_mon_stop\)/ { m = NR } END { exit !(u && d > u && m > d) }' \
    || lc_hp_bad+=" host.hotplug-after-flip unloads dummy before the unplug;"
  mkdir -p "$lc_hp_fx/mon/bin" "$lc_hp_fx/mon/sys/module/fuse" "$lc_hp_fx/mon/sys/devices/virtual/net/lo/queues/rx-0" \
           "$lc_hp_fx/mon/sys/bus/x/drivers/y" "$lc_hp_fx/mon/sys/devices/looped"
  : > "$lc_hp_fx/mon/sys/module/fuse/uevent"; chmod 0200 "$lc_hp_fx/mon/sys/module/fuse/uevent"
  : > "$lc_hp_fx/mon/sys/devices/virtual/net/lo/uevent"; chmod 0644 "$lc_hp_fx/mon/sys/devices/virtual/net/lo/uevent"
  : > "$lc_hp_fx/mon/sys/bus/x/drivers/y/uevent"; chmod 0200 "$lc_hp_fx/mon/sys/bus/x/drivers/y/uevent"
  ln -s uevent "$lc_hp_fx/mon/sys/devices/looped/uevent"
  printf '%s\n' '#!/bin/sh' 'cat <<EOT' 'monitor will print the received events for:' \
    'UDEV - the event which udev sends out after rule processing' '' \
    'UDEV  [4480.100001] add      /module/fuse (module)' 'KERNEL[4480.100002] add      /module/kernelonly (module)' \
    'UDEV  [4480.200001] add      /devices/virtual/net/lo (net)' 'UDEV  [4480.300001] add      /devices/virtual/net/lo/queues/rx-0 (queues)' \
    'UDEV  [4480.400001] remove   /module/fuse (module)' 'UDEV  [4480.500001] add      /module/gonemod (module)' \
    'UDEV  [4480.600001] add      /devices/looped (misc)' 'UDEV  [4480.700001] add      /bus/x/drivers/y (drivers)' 'EOT' \
    > "$lc_hp_fx/mon/bin/udevadm"
  chmod +x "$lc_hp_fx/mon/bin/udevadm"
  lc_hp_mon_out=$(LC_HP_SYS="$lc_hp_fx/mon/sys" PATH="$lc_hp_fx/mon/bin:$PATH" sh -c "$LC_HP_MON_SH" 2>&1)
  lc_hp_mon_want=$(printf '%s\n' READY 'ADD /module/fuse 200' 'ADD /devices/virtual/net/lo 644' \
    'ADD /devices/virtual/net/lo/queues/rx-0 none' 'ADD /module/gonemod gone' 'ADD /devices/looped unread' 'ADD /bus/x/drivers/y 200')
  [[ "$lc_hp_mon_out" == "$lc_hp_mon_want" ]] \
    || lc_hp_bad+=" LC_HP_MON_SH over a recorded transcript printed '$(tr '\n' '|' <<<"$lc_hp_mon_out")', want '$(tr '\n' '|' <<<"$lc_hp_mon_want")';"
  mkdir -p "$lc_hp_fx/srv"
  python3 - "$lc_hp_fx/srv/q.sock" "$lc_hp_fx/srv/log" "$lc_hp_fx/srv/pid" <<'PYEOF'
import json, os, socket, sys
sock, log, pidf = sys.argv[1:4]
s = socket.socket(socket.AF_UNIX)
s.bind(sock)
s.listen(4)
pid = os.fork()
if pid:
    open(pidf, "w").write(str(pid))
    sys.exit(0)
os.setsid()
null = os.open(os.devnull, os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(null, fd)
s.settimeout(60)
while True:
    try:
        c, _ = s.accept()
    except OSError:
        break
    f = c.makefile("rw")
    f.write(json.dumps({"QMP": {"version": {}, "capabilities": []}}) + "\n")
    f.flush()
    for line in f:
        with open(log, "a") as lf:
            lf.write(line)
        refuse = json.loads(line).get("arguments", {}).get("driver") == "refuse-me"
        f.write(json.dumps({"error": {"class": "GenericError", "desc": "refused"}} if refuse else {"return": {}}) + "\n")
        f.flush()
    c.close()
PYEOF
  lc_hp_ok_reply=$(QMP_SOCK="$lc_hp_fx/srv/q.sock" lc_hp_qmp '{"execute":"device_add","arguments":{"driver":"virtio-keyboard-pci","id":"t1"}}')
  lc_hp_err_reply=$(QMP_SOCK="$lc_hp_fx/srv/q.sock" lc_hp_qmp '{"execute":"device_add","arguments":{"driver":"refuse-me","id":"t2"}}')
  kill "$(cat "$lc_hp_fx/srv/pid" 2>/dev/null)" 2>/dev/null
  if [[ "$lc_hp_ok_reply" != *'"return"'* || "$lc_hp_ok_reply" == *'"error"'* || "$lc_hp_err_reply" != *'"error"'* ]]; then
    lc_hp_bad+=" lc_hp_qmp over a real socket read '$(tr '\n' ' ' <<<"$lc_hp_ok_reply")' and '$(tr '\n' ' ' <<<"$lc_hp_err_reply")';"
  elif [[ "$(grep -c '"qmp_capabilities"' "$lc_hp_fx/srv/log")/$(grep -c '"device_add"' "$lc_hp_fx/srv/log")" != 2/2 ]]; then
    lc_hp_bad+=" lc_hp_qmp did not send qmp_capabilities ahead of each command: $(tr '\n' ' ' < "$lc_hp_fx/srv/log");"
  fi
  if [[ -z "$lc_hp_bad" ]]; then
    ok "1za: host.hotplug-after-flip plugs and unplugs a keyboard and a disk and passes a good guest and one whose window holds only the sandbox's own init noise, fails by name on no QMP socket, udevd in kernel, dummy loaded or unread before the autoload, no autoload, virtio_input loaded before the plug, a refused plug, a device-labeled node, a denial from rhizo_host or from kernel, a kmsg window cut, scrolled out or with dropped audit records and a leftover node, passes a window holding exactly the fwupd uevent pairs its monitored adds derive and fails by name on one pair more, a readable uevent, another process's DAC pair inside fwupd's, a fwupd sys_rawio, fwupd pairs with fwupd not running, a restarted or unread fwupd, a fwupd udev socket still queued, dropping or absent at the stop and a dead, blind, cut, gone or unread add monitor, passes a gone add with fwupd not running and a service start's refused binfmt_misc remount from its pre-exec child, fails by name on another process's remount, journald's DAC pair and a refused user namespace, passes systemd 262's udevd, monitor and worker pairs derived from the same adds (the workers' as a ceiling) and fails by name on one pair more of the manager's or the workers', an unmeasured systemd, a restarted udevd and no monitor pid, starts the monitor after the start sentinel and unloads dummy only after the unplug, runs LC_HP_MON_SH over a recorded transcript, stops the monitor on every exit path, and lc_hp_qmp reads a real QMP socket"
  else
    bad "1za:$lc_hp_bad"
  fi
  rm -rf "$lc_hp_fx"
  unset -f lc_hp_run lc_hp_sent lc_hp_fw_pairs lc_hp_mon_left
  unset lc_hp_fx lc_hp_cycle lc_hp_bad lc_hp_out lc_hp_case lc_hp_mode lc_hp_want lc_hp_sent_want lc_hp_ok_reply lc_hp_err_reply lc_hp_udisksd_pair lc_hp_mon_out lc_hp_mon_want

  lc_km_fx=$(mktemp -d)
  mkdir "$lc_km_fx/bin"
  printf '#!/bin/sh\ncat "%s"\n' "$lc_km_fx/ring" > "$lc_km_fx/bin/dmesg"
  chmod +x "$lc_km_fx/bin/dmesg"
  lc_km_refused='[  120.960502] L3: server.adb_reach=lan refused to arm: no operator key at /etc/rhizo/adb_keys, rule not created'
  printf '%s\n' '[  111.813167] RHIZO_TEST_SENTINEL_847091_29956' '[  111.813170] LC_SENTINEL_847091_29956' \
    '[  113.393096] L3: server.adb_reach=lan armed: DNAT ens4:5555 -> 192.168.100.50:5555' \
    '[  119.481959] RHIZO_TEST_SENTINEL_847091_2995' '[  119.481962] LC_SENTINEL_847091_2995' \
    "$lc_km_refused" '[  121.000000] LC_SENTINEL_847091_29' > "$lc_km_fx/ring"
  lc_km_bad=$(
    ssh_vm() { local c="${*: -1}"; PATH="$lc_km_fx/bin:$PATH" bash -c "${c//> \/dev\/kmsg/>> $lc_km_fx/ring}"; }
    BOOT_LOG="$lc_km_fx/boot.log"
    got=$(guest_marker_since RHIZO_TEST_SENTINEL_847091_2995 'server.adb_reach=lan')
    [[ "$got" == "$lc_km_refused" ]] || printf '%s' " guest_marker_since read from an earlier sentinel holding its tag: $(tr '\n' '|' <<<"$got");"
    got=$(lc_dmesg_since LC_SENTINEL_847091_2995 'server.adb_reach=lan')
    [[ "$got" == "$lc_km_refused" ]] || printf '%s' " lc_dmesg_since read from an earlier sentinel holding its tag: $(tr '\n' '|' <<<"$got");"
    got=$(lc_dmesg_window LC_SENTINEL_847091_2995 LC_SENTINEL_847091_29) || got="<rc=$?>"
    [[ "$got" == "$lc_km_refused" ]] || printf '%s' " lc_dmesg_window did not cut between its own two sentinels: $(tr '\n' '|' <<<"$got");"
    a=$(guest_sentinel 2>/dev/null); b=$(guest_sentinel 2>/dev/null)
    [[ -n "$a" && -n "$b" && "${a##*_}" -lt "${b##*_}" ]] || printf '%s' " guest_sentinel did not write two tags in increasing order: '$a' then '$b';"
    a=$(lc_dmesg_sentinel); b=$(lc_dmesg_sentinel)
    [[ -n "$a" && -n "$b" && "${a##*_}" -lt "${b##*_}" ]] || printf '%s' " lc_dmesg_sentinel did not write two tags in increasing order: '$a' then '$b';"
  )
  if [[ -z "$lc_km_bad" ]]; then
    ok "1zp: guest_marker_since, lc_dmesg_since and lc_dmesg_window match a sentinel as the whole line's last field, so one whose tag is a prefix of an earlier sentinel's (server run 1's 2995 after 29956) reads from its own line, and guest_sentinel and lc_dmesg_sentinel draw each tag from the clock"
  else
    bad "1zp:$lc_km_bad"
  fi
  rm -rf "$lc_km_fx"
  unset lc_km_fx lc_km_refused lc_km_bad

  lc_dv_bad=""
  lc_dv_fx=$(mktemp -d)
  lc_dv_kmsg() {
    printf '%s\n' 'RHIZO_MARKER launch_start sandbox=0' 'RHIZO_MARKER coldboot=failed reason=nodes' \
      'RHIZO_MARKER launch_start sandbox=0' "$@" 'RHIZO_MARKER launch_start sandbox=1' \
      'RHIZO_MARKER coldboot_vold=failed reason=sink-tmpfs'
  }
  lc_dv_good=(RHIZO_MARKER\ coldboot=first-stage\ loops=8 'RHIZO_MARKER coldboot_shadow=ok children=9 uevent=virtual/net/lo/uevent' 'RHIZO_MARKER coldboot_vold=ok uevents=57')
  lc_dv_win=$(lc_start_window "$(lc_dv_kmsg "${lc_dv_good[@]}")")
  [[ "$lc_dv_win" == *coldboot_vold=ok* && "$lc_dv_win" != *reason=nodes* && "$lc_dv_win" != *sink-tmpfs* ]] \
    || lc_dv_bad+=" lc_start_window did not cut sandbox 0's last start from the one before it and instance 1's after it: $(tr '\n' '|' <<<"$lc_dv_win");"
  lc_dv_dump() {
    printf '%s\n' 'Event Hub State:' '  BuiltInKeyboardId: -2' '  Devices:' '    -1: Virtual' \
      '      Path: <virtual>' '      Location: '
    [[ "$lc_dv_mode" == no-composer ]] \
      || printf '%s\n' '    2: rhizo-touch-0' '      Path: /dev/input/event4' '      Location: rhizo-port-0'
    printf '%s\n' '    3: rhizo-keyboard-1' '      Path: /dev/input/event5' '      Location: rhizo-port-1'
    [[ "$lc_dv_mode" == eventhub-host ]] \
      && printf '%s\n' '    4: QEMU USB Keyboard' '      Path: /dev/input/event9' '      Location: usb-0000:00:1d.0-1/input0'
    [[ "$lc_dv_mode" == composer-port7 ]] \
      && printf '%s\n' '    6: rhizo-keyboard-7' '      Path: /dev/input/event11' '      Location: rhizo-port-7'
    [[ "$lc_dv_mode" == forged-opened ]] \
      && printf '%s\n' '    6: rhizo-lc-forged' '      Path: /dev/input/event11' '      Location: rhizo-port-7'
    [[ "$#" -gt 0 ]] && printf '%s\n' "$@"
    printf '%s\n' 'Input Reader State:' '  Device 2: rhizo-touch-0' '      Location: stray'
  }
  lc_dv_run() {
    (
      FAILED=0
      fail() { echo "$*" >> "$lc_dv_fx/err"; FAILED=$((FAILED + 1)); }
      pass() { :; }
      lc_dv_mode="$2"
      QMP_SOCK="$lc_dv_fx/q.sock"
      REPO="$lc_dv_fx" VAR_DIR="$lc_dv_fx"
      echo 0 > "$lc_dv_fx/pidof"
      lc_resolve_init() { echo 4242; }
      resolve_init_pid() { echo 6161; }
      guest_uptime() { echo 100.5; }
      wait_sandbox_started() { [[ "$lc_dv_mode" != no-boot ]]; }
      lc_dmesg_sentinel() { [[ "$lc_dv_mode" == no-sentinel ]] && return 1; echo SENT; }
      lc_dmesg_since() {
        case "$2" in
          'RHIZO_MARKER input_fence=')
            echo "[ 9.1] RHIZO_MARKER input_fence=withheld node=/dev/input/event9 dev=13:73 phys=usb-0000:00:1d.0-1/input0"
            [[ "$lc_dv_mode" == ueventd-made ]] \
              && echo "[ 9.2] RHIZO_MARKER input_fence=withheld node=/dev/hidraw0 dev=245:0 removed=reconcile" ;;
          'Cannot chown ')
            [[ "$lc_dv_mode" == no-refusal ]] \
              || printf '%s\n' '[ 9.0] ueventd: Cannot chown /dev/input/event9 0 -1: No such file or directory' \
                   '[ 9.0] ueventd: Cannot chown /dev/hidraw0 1000 -1: No such file or directory' ;;
        esac
        return 0
      }
      lc_hp_qmp() {
        echo "$1" >> "$lc_dv_fx/qmp"
        [[ "$lc_dv_mode" == qmp-refused && "$1" == *qemu-xhci* ]] && { echo '{"error": {"class": "GenericError"}}'; return 0; }
        [[ "$lc_dv_mode" == late-refused && "$1" == *rhznd_blk* && "$1" == *device_add* ]] && { echo '{"error": {"class": "GenericError"}}'; return 0; }
        echo '{"return": {}}'
      }
      ssh_vm() {
        local body="${*: -1}"
        case "$body" in
          'journalctl -k -b -o cat --no-pager; echo DONE')
            case "$lc_dv_mode" in
              cut) lc_dv_kmsg "${lc_dv_good[@]}" ;;
              no-start) echo DONE ;;
              vold-failed) lc_dv_kmsg "${lc_dv_good[@]:0:2}" 'RHIZO_MARKER coldboot_vold=failed reason=bind:/sys/devices/x/uevent bound=3/57'; echo DONE ;;
              vold-zero) lc_dv_kmsg "${lc_dv_good[@]:0:2}" 'RHIZO_MARKER coldboot_vold=ok uevents=0'; echo DONE ;;
              *) lc_dv_kmsg "${lc_dv_good[@]}"; echo DONE ;;
            esac ;;
          'systemctl is-active androidd.service 2>/dev/null; echo DONE')
            [[ "$lc_dv_mode" == still-active ]] && echo active || echo inactive
            echo DONE ;;
          'find /sys/devices -name uevent'*)
            printf '%s\n' /devices/virtual/block/loop0 /devices/pci0000:00/0000:00:1f.2/block/sda DONE ;;
          'systemctl stop rhizo-lc-kmon.service 2>/dev/null; systemctl reset-failed'*)
            [[ "$lc_dv_mode" == no-monitor ]] || echo READY ;;
          'systemctl stop rhizo-lc-kmon.service 2>/dev/null; grep "^ADD "'*)
            echo 'ADD /devices/virtual/net/veth1'
            echo 'ADD /devices/virtual/block/dm-3'
            [[ "$lc_dv_mode" == reannounced ]] && echo 'ADD /devices/virtual/block/loop0'
            echo DONE ;;
          'for e in /sys/class/input/event*; do grep -qx rhizo-lc-hid'*)
            echo DEVNAME=input/event13
            [[ "$lc_dv_mode" == hid-host-libinput ]] || echo LIBINPUT_IGNORE_DEVICE=1
            if [[ "$lc_dv_mode" == hid-phys ]]; then echo PHYS=usb-0000:00:14.0-1/input0
            else echo PHYS=rhizo-uhid-0-0123456789abcdef; fi ;;
          "n=$LC_IN_FORGED_NAME; r() { for e in /sys/class/input/event*"*)
            [[ "$lc_dv_mode" == forge-absent ]] || echo "event14 $LC_IN_FORGED_PHYS" ;;
          'for e in /sys/class/input/event*; do grep -qx rhizo-lc-own'*)
            printf '%s\n' DEVNAME=input/event12 ID_INPUT=
            [[ "$lc_dv_mode" == host-libinput ]] || echo LIBINPUT_IGNORE_DEVICE=1 ;;
          'for e in /sys/class/input/event*'*) [[ "$lc_dv_mode" == no-event ]] || echo event9 ;;
          'for e in /sys/class/hidraw/hidraw*'*) echo hidraw0 ;;
          'timeout 30 sh -c '*'RHIZO_MARKER block_sink='*)
            case "$lc_dv_mode" in
              late-unsunk) : ;;
              late-failed) echo '[ 99.1] RHIZO_MARKER block_sink=failed reason=bind:/sys/devices/pci0000:00/0000:00:1c.0/virtio5/block/vdb/uevent bound=0 -- a vold restart writes that device' ;;
              *) echo '[ 99.1] RHIZO_MARKER block_sink=late bound=1' ;;
            esac ;;
          'timeout 30 sh -c'*) [[ "$lc_dv_mode" == not-acted ]] || echo ACTED ;;
          'udevadm wait -t 30 /dev/disk/by-id/virtio-rhznd'*) : ;;
          'readlink -f /dev/disk/by-id/virtio-rhznd') [[ "$lc_dv_mode" == late-absent ]] || echo /dev/vdb ;;
          'readlink -f /sys/class/block/vdb/uevent') echo /sys/devices/pci0000:00/0000:00:1c.0/virtio5/block/vdb/uevent ;;
          "awk '\$5 == "*)
            if [[ "$lc_dv_mode" == late-unmounted ]]; then echo 0; else echo 1; fi
            echo DONE ;;
          'test -d /sys/module/cuse'*)
            [[ "$lc_dv_mode" == no-cuse ]] || echo cuse=loaded
            echo uhid-node=present
            if [[ "$lc_dv_mode" == uhid-unit-down ]]; then echo "units=active failed"; else echo "units=active active"; fi
            echo "registered=3"
            if [[ "$lc_dv_mode" == supervisor-unconfined ]]; then echo "supervisor-label=u:r:kernel:s0"
            else echo "supervisor-label=u:r:rhizo_inputd:s0"; fi
            echo "broker-label=u:r:rhizo_uhidd:s0"
            if [[ "$lc_dv_mode" == permissive ]]; then echo enforce=0; else echo enforce=1; fi
            if [[ "$lc_dv_mode" == no-fdstore ]]; then echo fdstore=0; else echo fdstore=2; fi
            if [[ "$lc_dv_mode" == not-adopted ]]; then echo sup-adopted=0; else echo sup-adopted=1; fi
            if [[ "$lc_dv_mode" == journal-dropped ]]; then echo sup-registered=0; else echo sup-registered=2; fi
            if [[ "$lc_dv_mode" == broker-journal-dropped ]]; then echo broker-created=0
            elif [[ "$lc_dv_mode" == earlier-broker && "$body" == *"--after-cursor="* ]]; then echo broker-created=0
            else echo broker-created=1; fi ;;
          'journalctl -n 0 --show-cursor'*) echo '-- cursor: s=0123;i=42' ;;
          'b0=$(systemctl show -p MainPID --value rhizo-inputd-uhid@'*'systemctl restart rhizo-inputd@'*)
            if [[ "$lc_dv_mode" == restart-stuck ]]; then echo "restarted=activating inactive"
            else echo "restarted=active active"; fi
            if [[ "$lc_dv_mode" == broker-kept ]]; then echo "broker-pids=812 812"; echo broker-renewed=no
            else echo "broker-pids=812 907"; echo broker-renewed=yes; fi ;;
          'for d in /sys/class/cuse/rhizo-*-uhid'*) printf '%s\n' 'rhizo-0-uhid 10:60' 'rhizo-1-uhid 10:61' ;;
          *) : ;;
        esac
      }
      android_sh() {
        [[ "$lc_dv_mode" == android-dead ]] && return 97
        case "$2" in
          'pidof ueventd')
            local n; n=$(( $(cat "$lc_dv_fx/pidof") + 1 )); echo "$n" > "$lc_dv_fx/pidof"
            if [[ "$lc_dv_mode" == ueventd-died && "$n" == 2 ]]; then echo 999; else echo 321; fi ;;
          'ls /dev/input; echo LS_RC=$?')
            if [[ "$lc_dv_mode" == ls-failed ]]; then
              printf '%s\n' 'ls: /dev/input: Permission denied' 'LS_RC=1'
            else
              printf '%s\n' event4 event5
              [[ "$lc_dv_mode" == host-node ]] && echo event9
              echo LS_RC=0
            fi ;;
          'ls /dev; echo LS_RC=$?')
            printf '%s\n' input null uinput
            [[ "$lc_dv_mode" == hidraw-node ]] && echo hidraw0
            echo LS_RC=0 ;;
          'if [ -d /dev/bus/usb ]'*)
            [[ "$lc_dv_mode" == usb-node ]] && echo /dev/bus/usb/001/002
            echo FIND_RC=0 ;;
          'dumpsys input') lc_dv_dump ;;
          'date +"%m-%d %H:%M:%S.000"') echo '09-28 21:12:07.000' ;;
          "logcat -d -v threadtime -t '09-28 21:12:07.000' -s EventHub")
            [[ "$lc_dv_mode" == hid-not-opened ]] \
              && echo '09-28 21:12:08.080   394   673 E EventHub: could not open /dev/input/event13, Permission denied' ;;
          'stat -c "%t %T" /dev/uhid')
            if [[ "$lc_dv_mode" == uhid-foreign ]]; then echo "a 3e"; else echo "a 3c"; fi ;;
          'f=/data/local/tmp/rhizo-lc-hid;'*)
            [[ "$lc_dv_mode" == hid-no-node ]] && echo HIDNODE= || echo HIDNODE=event13
            [[ "$lc_dv_mode" == hid-no-key ]] || echo 'EV EV_KEY       KEY_A                DOWN'
            if [[ "$lc_dv_mode" == hid-not-opened ]]; then lc_dv_dump
            else lc_dv_dump '    8: rhizo-lc-hid' '      Path: /dev/input/event13' '      Location: rhizo-uhid-0-0123456789abcdef'; fi ;;
          '(echo '*)
            if [[ "$lc_dv_mode" == own-withheld ]]; then lc_dv_dump
            elif [[ "$lc_dv_mode" == forged-late ]]; then
              lc_dv_dump '    6: rhizo-lc-forged' '      Path: /dev/input/event14' '      Location: rhizo-port-7' \
                '    7: rhizo-lc-own' '      Path: /dev/input/event12' '      Location: '
            else lc_dv_dump '    7: rhizo-lc-own' '      Path: /dev/input/event12' '      Location: '; fi ;;
        esac
        return 0
      }
      "lc_assert_$1" >/dev/null 2>&1
      echo "RC=$? FAILED=$FAILED"
      echo "${INIT:-}" > "$lc_dv_fx/init"
    )
  }
  lc_dv_sock=$(python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); print("ok")' "$lc_dv_fx/q.sock" 2>&1)
  [[ "$lc_dv_sock" == ok ]] || lc_dv_bad+=" could not make the fixture QMP socket: $lc_dv_sock;"
  for lc_dv_case in \
      "host.no-device-reannounce|good|" \
      "host.no-device-reannounce|reannounced|an add for 1 device(s) that existed before the start: /devices/virtual/block/loop0" \
      "host.no-device-reannounce|still-active|reads 'active' after systemctl stop" \
      "host.no-device-reannounce|no-monitor|never printed READY" \
      "host.no-device-reannounce|no-boot|did not reach boot_completed" \
      "host.no-device-reannounce|cut|kernel journal did not read back whole" \
      "host.no-device-reannounce|no-start|no RHIZO_MARKER launch_start sandbox=0" \
      "host.no-device-reannounce|vold-failed|RHIZO_MARKER coldboot_vold=failed reason=bind:/sys/devices/x/uevent" \
      "host.no-device-reannounce|vold-zero|coldboot_vold=ok covered 0 uevents" \
      "host.no-device-reannounce|late-refused|QMP refused the late disk" \
      "host.no-device-reannounce|late-absent|the late disk never showed up on the host" \
      "host.no-device-reannounce|late-unsunk|no RHIZO_MARKER block_sink=late after the late disk's plug" \
      "host.no-device-reannounce|late-failed|RHIZO_MARKER block_sink=failed reason=bind:" \
      "host.no-device-reannounce|late-unmounted|is not a mount point in init's mount namespace" \
      "sandbox.host-input-invisible|good|" \
      "sandbox.host-input-invisible|host-node|Android's /dev/input holds event9" \
      "sandbox.host-input-invisible|ls-failed|ls /dev/input did not complete: LS_RC=1" \
      "sandbox.host-input-invisible|hidraw-node|Android's /dev holds hidraw0" \
      "sandbox.host-input-invisible|usb-node|Android's /dev/bus/usb holds /dev/bus/usb/001/002" \
      "sandbox.host-input-invisible|ueventd-made|a node was made and then removed, not withheld" \
      "sandbox.host-input-invisible|no-refusal|ueventd logged no refused node for /dev/input/event9" \
      "sandbox.host-input-invisible|ueventd-died|ueventd's pid went from '321' to '999'" \
      "sandbox.host-input-invisible|eventhub-host|EventHub opened /dev/input/event9 (QEMU USB Keyboard), the host's keyboard" \
      "sandbox.host-input-invisible|composer-port7|" \
      "sandbox.host-input-invisible|forged-opened|the host's device rhizo-lc-forged forged with this instance's phys rhizo-port-7" \
      "sandbox.host-input-invisible|no-composer|EventHub lists no device at rhizo-port-0" \
      "sandbox.host-input-invisible|own-withheld|EventHub never opened rhizo-lc-own" \
      "sandbox.host-input-invisible|forge-absent|the forged device never existed on the host with phys rhizo-port-7" \
      "sandbox.host-input-invisible|forged-late|EventHub opened /dev/input/event14, the host's device rhizo-lc-forged forged with this instance's phys rhizo-port-7" \
      "sandbox.host-input-invisible|qmp-refused|QMP refused the USB controller" \
      "sandbox.host-input-invisible|no-cuse|the host does not report cuse=loaded" \
      "sandbox.host-input-invisible|uhid-unit-down|the host does not report units=active active" \
      "sandbox.host-input-invisible|host-libinput|the host's udev left rhizo-lc-own to the host's libinput" \
      "sandbox.host-input-invisible|supervisor-unconfined|the supervisor does not run in rhizo_inputd" \
      "sandbox.host-input-invisible|restart-stuck|a supervisor restart under enforcement did not come back active" \
      "sandbox.host-input-invisible|broker-kept|the uhid broker kept its pid across the supervisor restart: broker-pids=812 812" \
      "sandbox.host-input-invisible|permissive|the host is not enforcing" \
      "sandbox.host-input-invisible|no-fdstore|the supervisor's fd store holds fdstore=0" \
      "sandbox.host-input-invisible|not-adopted|the restarted supervisor's journal has no adopted listener" \
      "sandbox.host-input-invisible|journal-dropped|the restarted supervisor's journal registers nothing" \
      "sandbox.host-input-invisible|broker-journal-dropped|the restarted broker's journal records no uhid create" \
      "sandbox.host-input-invisible|earlier-broker|the restarted broker's journal records no uhid create" \
      "sandbox.host-input-invisible|uhid-foreign|Android's /dev/uhid (a 3e) is none of the host's CUSE devices" \
      "sandbox.host-input-invisible|hid-no-node|Android's hid command created no input node" \
      "sandbox.host-input-invisible|hid-no-key|a key the hid device reported never reached Android's getevent" \
      "sandbox.host-input-invisible|hid-not-opened|EventHub never opened rhizo-lc-hid" \
      "sandbox.host-input-invisible|hid-host-libinput|the host's udev left rhizo-lc-hid to the host's libinput" \
      "sandbox.host-input-invisible|hid-phys|rhizo-lc-hid's phys is not this instance's broker token" \
      "sandbox.host-input-invisible|no-event|not both" \
      "sandbox.host-input-invisible|not-acted|and the fence removed none" \
      "sandbox.host-input-invisible|android-dead|ls /dev/input did not complete" \
      "sandbox.host-input-invisible|no-sentinel|could not plant a dmesg sentinel"; do
    IFS='|' read -r lc_dv_claim lc_dv_mode lc_dv_want <<<"$lc_dv_case"
    : > "$lc_dv_fx/err"; : > "$lc_dv_fx/qmp"
    lc_dv_out=$(lc_dv_run "$lc_dv_claim" "$lc_dv_mode")
    case "$lc_dv_claim|$lc_dv_mode" in
      host.no-device-reannounce\|good) [[ "$(cat "$lc_dv_fx/init")" == 6161 ]] \
        || lc_dv_bad+=" host.no-device-reannounce, a good guest: INIT reads '$(cat "$lc_dv_fx/init")' after the restart, not its init 6161;" ;;
      host.no-device-reannounce\|no-boot) [[ -z "$(cat "$lc_dv_fx/init")" ]] \
        || lc_dv_bad+=" host.no-device-reannounce, no boot: INIT still reads '$(cat "$lc_dv_fx/init")', the init the stop ended;" ;;
    esac
    if [[ -z "$lc_dv_want" ]]; then
      [[ "$lc_dv_out" == "RC=0 FAILED=0" ]] || lc_dv_bad+=" $lc_dv_claim, a good guest: want RC=0 FAILED=0, got '$lc_dv_out' $(cat "$lc_dv_fx/err");"
    elif [[ "$lc_dv_out" != "RC=1 FAILED=1" ]] || ! grep -qF -- "$lc_dv_want" "$lc_dv_fx/err"; then
      lc_dv_bad+=" $lc_dv_claim, guest '$lc_dv_mode': want RC=1 FAILED=1 naming '$lc_dv_want', got '$lc_dv_out' $(cat "$lc_dv_fx/err");"
    fi
    if [[ "$lc_dv_mode" == hid-not-opened ]]; then
      grep -qx HIDNODE=event13 "$EV/host-input-invisible-hid-out.log" 2>/dev/null \
        || lc_dv_bad+=" $lc_dv_claim, guest '$lc_dv_mode': the hid run is not in \$EV/host-input-invisible-hid-out.log;"
      grep -q ' rhizo-lc-own$' "$EV/host-input-invisible-own-dump.log" 2>/dev/null \
        || lc_dv_bad+=" $lc_dv_claim, guest '$lc_dv_mode': the own dump is not in \$EV/host-input-invisible-own-dump.log;"
      grep -qF 'could not open /dev/input/event13, Permission denied' "$EV/host-input-invisible-eventhub-logcat.log" 2>/dev/null \
        || lc_dv_bad+=" $lc_dv_claim, guest '$lc_dv_mode': EventHub's refusal is not in \$EV/host-input-invisible-eventhub-logcat.log;"
    fi
    if [[ "$lc_dv_mode" == android-dead ]] && ! grep -q '^<none: ' "$EV/host-input-invisible-hid-out.log" 2>/dev/null; then
      lc_dv_bad+=" $lc_dv_claim, guest '$lc_dv_mode': a dead android_sh left \$EV/host-input-invisible-hid-out.log without an explicit <none>;"
    fi
    if [[ "$lc_dv_mode" == no-sentinel ]] && compgen -G "$EV/host-input-invisible-*.log" >/dev/null; then
      lc_dv_bad+=" $lc_dv_claim, guest '$lc_dv_mode': an early return left the previous run's \$EV/host-input-invisible-*.log;"
    fi
    if [[ "$lc_dv_claim" == host.* ]] && grep -q '"device_add".*rhznd_blk' "$lc_dv_fx/qmp" \
        && ! { grep -q '"device_del".*rhznd_blk' "$lc_dv_fx/qmp" && grep -q '"blockdev-del".*rhznd' "$lc_dv_fx/qmp"; }; then
      lc_dv_bad+=" $lc_dv_claim, guest '$lc_dv_mode': the late disk was plugged and never unplugged;"
    fi
    if [[ "$lc_dv_claim" == sandbox.* && "$lc_dv_mode" != qmp-refused ]] && grep -q '"device_add"' "$lc_dv_fx/qmp" \
        && ! { grep -q '"device_del".*rhzin_ukbd' "$lc_dv_fx/qmp" && grep -q '"device_del".*rhzin_xhci' "$lc_dv_fx/qmp"; }; then
      lc_dv_bad+=" $lc_dv_claim, guest '$lc_dv_mode': the keyboard or its controller was plugged and never unplugged;"
    fi
  done
  if [[ -z "$lc_dv_bad" ]]; then
    ok "1zy: host.no-device-reannounce passes a start whose host monitor saw adds only of new devices and whose markers are clean, leaving INIT on that start's init, and fails by name on an add of a device that existed before, a stop that left it active, no monitor, no boot, a cut journal, no start, a vold failure, vold covering 0, and a disk plugged after the start that QMP refused, never appeared, drew no block_sink=late, drew block_sink=failed or is no mount point in init's namespace, unplugging it on every path; sandbox.host-input-invisible passes a guest where the composer's devices and Android's own uinput device reach EventHub and the host's do not, and fails by name on the host's evdev, hidraw or usbfs node, a made-and-removed node, no ueventd refusal, a restarted ueventd, EventHub opening the host's keyboard or the forged device in either dump, a forged device the host never held, no composer device, Android's own device withheld, no cuse module, a uhid broker down, the host's libinput taking Android's own device, a supervisor outside rhizo_inputd, a supervisor restart under enforcement that did not come back, a host not enforcing, an empty fd store, a restart that adopted nothing, either daemon's journal lines dropped, a broker line from before the restart, a /dev/uhid that is no instance's CUSE device, an Android hid device that got no node, delivered no key, was never opened, was left to the host's libinput or carries no broker token, a failed ls, a refused plug, no host event, ueventd never acting, a dead android_sh and no sentinel, unplugging on every path and leaving no earlier run's evidence behind an early return"
  else
    bad "1zy:$lc_dv_bad"
  fi
  rm -rf "$lc_dv_fx"
  unset -f lc_dv_kmsg lc_dv_run lc_dv_dump
  unset lc_dv_bad lc_dv_fx lc_dv_good lc_dv_win lc_dv_sock lc_dv_case lc_dv_claim lc_dv_mode lc_dv_want lc_dv_out

  lc_sw_fx=$(mktemp -d) || exit 1
  lc_sw_bad=""
  lc_sw_td=$(sed -n 's/^SWAP_FSTAB_LINE="\(.*\)"$/\1/p' "$repo_root/src/install/teardown/teardown.sh")
  lc_sw_guard=$(sed -n '/^swapfile_fstab_entries() {/,/^}/p' "$repo_root/src/install/bootstrap/bootstrap.sh")
  printf 'LABEL=cloudimg-rootfs / ext4 discard,errors=remount-ro 0 1\n%s\n' "$LC_SWAPFILE_FSTAB_LINE" > "$lc_sw_fx/fstab"
  if [[ -z "$lc_sw_td" || -z "$lc_sw_guard" ]]; then
    lc_sw_bad+=" could not read teardown's SWAP_FSTAB_LINE ('$lc_sw_td') or bootstrap's swapfile_fstab_entries;"
  else
    ! grep -qxF "$lc_sw_td" "$lc_sw_fx/fstab" || lc_sw_bad+=" teardown's SWAP_FSTAB_LINE '$lc_sw_td' matches step 0's fixture line;"
    [[ "$(SWAPFILE=/swapfile FSTAB="$lc_sw_fx/fstab" bash -c "$lc_sw_guard"$'\n''swapfile_fstab_entries')" == "$LC_SWAPFILE_FSTAB_LINE" ]] \
      || lc_sw_bad+=" bootstrap's swapfile_fstab_entries misses step 0's fixture line;"
  fi
  [[ "$(awk '{print $1, $3}' <<<"$LC_SWAPFILE_FSTAB_LINE")" == "/swapfile swap" ]] \
    || lc_sw_bad+=" step 0's fixture line is not a /swapfile path swap line: '$LC_SWAPFILE_FSTAB_LINE';"
  lc_sw_step0=$(declare -f lifecycle_run_cycle | sed -n '/lc_step 0 /,/lc_step 1 /p')
  grep -qF "echo '\$LC_SWAPFILE_FSTAB_LINE' >> /etc/fstab" <<<"$lc_sw_step0" && ! grep -qF 'UUID=$' <<<"$lc_sw_step0" \
    || lc_sw_bad+=" step 0 does not append LC_SWAPFILE_FSTAB_LINE, and only it, to /etc/fstab;"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/swapfile                               file\t\t262140\t\t0\t\t-2\n' > "$lc_sw_fx/swaps-on"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/swapfile2                              file\t\t262140\t\t0\t\t-2\n' > "$lc_sw_fx/swaps-off"
  lc_sw_step1() {
    (
      cp "$lc_sw_fx/swaps-on" "$lc_sw_fx/swaps"
      lc_sw_after="$1" EV="$lc_sw_fx" REPO="$lc_sw_fx" VAR_DIR="$lc_sw_fx"
      printf 'claim_id\tresult\n' > "$EV/claims.tsv"
      wait_for_ssh() { return 0; }
      ssh_vm() {
        local b="${*: -1}"
        case "$b" in
          *'/proc/swaps'*) eval "${b//\/proc\/swaps/$lc_sw_fx/swaps}" ;;
          *random/boot_id*) echo bid-1 ;;
          *list-boots*) printf '1\nDONE\n' ;;
          *) return 255 ;;
        esac
      }
      lc_one_deb() { return 0; }
      installer_seed_gsi_zip() { :; }
      installer_seed_gsi_zip_release() { :; }
      installer_stage_offline_repo() { :; }
      installer_transfer_artifact() { :; }
      lc_pkgwin() { shift 2; "$@"; }
      installer_install_reboot_prepare() { cp "$lc_sw_fx/swaps-$lc_sw_after" "$lc_sw_fx/swaps"; }
      RHIZO_LIFECYCLE_FROM_STEP=1 RHIZO_LIFECYCLE_TO_STEP=1 lifecycle_run_cycle server >/dev/null 2>&1
      LC_SWAPFILE_INODE_SEED=12 LC_SWAPFILE_UUID_SEED=uuid-1
      LC_SWAPFILE_INODE_AFTER_REMOVE=12 LC_SWAPFILE_UUID_AFTER_REMOVE=uuid-1
      LC_SWAPFILE_INODE_AFTER_PURGE=12 LC_SWAPFILE_UUID_AFTER_PURGE=uuid-1
      FAILED=0
      lc_assert_packaging.swapfile-precise-removal >/dev/null 2>"$lc_sw_fx/claim.err"
      echo "$LC_SWAPFILE_ACTIVE_BEFORE_INSTALL/$LC_SWAPFILE_ACTIVE_AFTER_INSTALL RC=$? FAILED=$FAILED"
    )
  }
  lc_sw_out=$(lc_sw_step1 on)
  [[ "$lc_sw_out" == "1/1 RC=0 FAILED=0" ]] \
    || lc_sw_bad+=" active across step 1: $lc_sw_out, want 1/1 and a pass: $(grep FAIL "$lc_sw_fx/claim.err" | head -1);"
  lc_sw_out=$(lc_sw_step1 off)
  [[ "$lc_sw_out" == "1/0 RC=1 FAILED=1" ]] && grep -qF "was not active after step 1's reboot (/proc/swaps rows: '0', want 1)" "$lc_sw_fx/claim.err" \
    || lc_sw_bad+=" inactive after step 1's reboot: $lc_sw_out, want 1/0 and a fail naming it: $(grep FAIL "$lc_sw_fx/claim.err" | head -1);"
  for lc_sw_case in "0|'0', want 1" "|'<not recorded>', want 1"; do
    IFS='|' read -r lc_sw_before lc_sw_want <<<"$lc_sw_case"
    lc_sw_out=$(
      ssh_vm() { return 255; }
      LC_SWAPFILE_ACTIVE_BEFORE_INSTALL="$lc_sw_before" LC_SWAPFILE_ACTIVE_AFTER_INSTALL=1
      LC_SWAPFILE_INODE_SEED=12 LC_SWAPFILE_UUID_SEED=uuid-1 FAILED=0
      lc_assert_packaging.swapfile-precise-removal >/dev/null 2>"$lc_sw_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
    [[ "$lc_sw_out" == "RC=1 FAILED=1" ]] && grep -qF "was not active before step 1's install (/proc/swaps rows: $lc_sw_want)" "$lc_sw_fx/claim.err" \
      || lc_sw_bad+=" before-install rows '$lc_sw_before': $lc_sw_out, want a fail naming it: $(grep FAIL "$lc_sw_fx/claim.err" | head -1);"
  done
  if [[ -z "$lc_sw_bad" ]]; then
    ok "1zb: step 0's swapfile line is a path line teardown's SWAP_FSTAB_LINE misses and bootstrap's swapfile_fstab_entries sees, step 1 reads /proc/swaps around its install, and the claim fails by name when /swapfile is inactive before the install or after its reboot"
  else
    bad "1zb:$lc_sw_bad"
  fi
  rm -rf "$lc_sw_fx"
  unset -f lc_sw_step1
  unset lc_sw_fx lc_sw_bad lc_sw_td lc_sw_guard lc_sw_step0 lc_sw_out lc_sw_case lc_sw_before lc_sw_want

  lc_se_fx=$(mktemp -d) || exit 1
  lc_se_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  # shellcheck disable=SC2016
  lc_se_render_py='
import os, re, shutil, sys
root, props = sys.argv[1], set(sys.argv[2].split(","))
rules = open(os.path.join(root, "debian", "rules")).read().replace("\\\n", " ")
EXEC = ("ExecCondition", "ExecStartPre", "ExecStart", "ExecStartPost", "ExecReload", "ExecStop", "ExecStopPost")
PATHS = ("PathExists", "PathExistsGlob", "PathChanged", "PathModified", "DirectoryNotEmpty")
LISTEN = ("ListenStream", "ListenDatagram", "ListenSequentialPacket", "ListenFIFO")
def entries(path):
    out, cont = [], ""
    for raw in open(path):
        line = cont + raw.rstrip("\n")
        cont = ""
        if line.endswith("\\"):
            cont = line[:-1] + " "
            continue
        s = line.strip()
        if s and s[0] not in "#;[" and "=" in s:
            k, v = s.split("=", 1)
            out.append((k.strip(), v.strip()))
    return out
def instance(name):
    if name == "user@.service":
        return "user@1000.service", "1000"
    if name == "session-.scope":
        return "session-2.scope", "2"
    return name.replace("@.", "@1."), "1"
def spec(v, unit, i):
    for a, b in (("%i", i), ("%I", i), ("%t", "/run"), ("%h", "/root"), ("%S", "/var/lib"), ("%C", "/var/cache"),
                 ("%L", "/var/log"), ("%E", "/etc"), ("%T", "/tmp"), ("%V", "/var/tmp"), ("%n", unit),
                 ("%N", unit.rsplit(".", 1)[0]), ("%%", "%")):
        v = v.replace(a, b)
    return v
def show(k, v):
    if not v:
        return None
    if k in EXEC:
        argv = v.lstrip("-@:+!|")
        return "%s={ path=%s ; argv[]=%s ; ignore_errors=%s ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }" % (
            k, argv.split()[0], argv, "yes" if v.startswith("-") else "no")
    if k in PATHS:
        return "Paths=%s (%s)" % (v, k)
    if k in LISTEN:
        return "Listen=%s (%s)" % (v, k[6:])
    if k == "EnvironmentFile":
        return "EnvironmentFiles=%s (ignore_errors=%s)" % (v.lstrip("-"), "yes" if v.startswith("-") else "no")
    if k in ("StandardInput", "StandardOutput", "StandardError") and re.match(r"(file|append|truncate):", v):
        return "%sFileDescriptorName=%s" % (k, v.split(":", 1)[1])
    return "%s=%s" % (k, v) if k in props else None
units, drops = {}, {}
for line in rules.splitlines():
    t = line.split()
    if len(t) < 3 or t[0] != "install" or "-d" in t:
        continue
    dest = t[-1].strip("\x22")
    srcs = [x.strip("\x22") for x in t[1:-1] if x[0] != "-" and not x.isdigit()]
    if dest == "$(UNITS)/":
        for src in srcs:
            units[os.path.basename(src)] = src
        continue
    m = re.match(r"\$\((?:UNITS\)|PAYLOAD\)/host-mode/usr/lib/systemd/system)/([^/]+)\.d/([^/]+)$", dest)
    if m:
        drops.setdefault(m.group(1), []).extend((src, m.group(2)) for src in srcs)
        continue
    m = re.match(r"\$\(UNITS\)/([^/]+)$", dest)
    if m and len(srcs) == 1:
        units[m.group(1)] = srcs[0]
def place(src, path):  # copy a file into the fixture root
    dst = sys.argv[3] + path
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(os.path.join(root, src), dst)
for name in sorted(set(units) | set(drops)):
    unit, i = instance(name)
    print("@@ " + unit)
    if name in units:
        print("FragmentPath=/usr/lib/systemd/system/" + name)
        place(units[name], "/usr/lib/systemd/system/" + name)
    if name in drops:
        print("DropInPaths=" + " ".join("/usr/lib/systemd/system/%s.d/%s" % (name, d) for _, d in drops[name]))
        for src, d in drops[name]:
            place(src, "/usr/lib/systemd/system/%s.d/%s" % (name, d))
    for src in ([units[name]] if name in units else []) + [s for s, _ in drops.get(name, [])]:
        for k, v in entries(os.path.join(root, src)):
            r = show(k, spec(v, unit, i))
            if r:
                print(r)
'
  lc_se_shipped=$(python3 -c "$lc_se_render_py" "$lc_se_repo" "$LC_UNIT_PATH_PROPS" "$lc_se_fx/shipped-root")
  lc_se_all() {
    printf '%s\n' "$lc_se_units"
    [[ -e "$lc_se_fx/planted" ]] || return 0
    printf '@@ rhizo-lc-dacprobe.path\nFragmentPath=/run/systemd/transient/rhizo-lc-dacprobe.path\nPaths=%s/rhizo-lc-dacprobe-* (PathExistsGlob)\n' "$lc_se_rd"
    printf '@@ rhizo-lc-dacprobe.service\nFragmentPath=/run/systemd/transient/rhizo-lc-dacprobe.service\nExecStart={ path=/bin/true ; argv[]=/bin/true ; ignore_errors=no }\n'
  }
  lc_se_systemctl() {
    local prop="" u first=1 lf_only
    case "$1" in
      list-units)
        (( lc_se_lu_empty )) && return "$lc_se_lu_rc"
        for u in $(lc_se_all | sed -n 's/^@@ //p'); do
          [[ "$u" == rhizo-lc-dacprobe.* ]] && (( ! lc_se_ctl_listed )) && continue
          for lf_only in $lc_se_lf_only; do [[ "$u" == "$lf_only" ]] && continue 2; done
          echo "$u loaded active running fixture"
        done
        return "$lc_se_lu_rc" ;;
      list-unit-files) printf '%s\n' "$lc_se_lf" ;;
      show)
        shift
        while [[ "${1:-}" == -* ]]; do
          case "$1" in
            -p) prop=$2; shift 2 ;;
            --value) shift ;;
            --) shift; break ;;
            *) echo "systemctl: invalid option -- '${1#-}'" >&2; return 1 ;;
          esac
        done
        for u in "$@"; do
          (( first )) || echo
          first=0
          case "$prop:$u" in
            LoadState:rhizo-desktop-session.path) sed -n 1p <<<"$lc_se_load" ;;
            LoadState:rhizo-desktop-session.service) sed -n 2p <<<"$lc_se_load" ;;
            LoadState:*) echo not-found ;;
            *:*@.*) echo "Failed to get properties: Unit name $u is missing the instance name." >&2; return 1 ;;
            *)
              [[ "$u" == "$lc_se_show_fail" ]] && return 1
              [[ "$u" == "$lc_se_no_id" ]] || echo "Id=$u"
              lc_se_all | LC_SE_U=$u awk '/^@@ / { f = (substr($0, 4) == ENVIRON["LC_SE_U"]); next } f' ;;
          esac
        done ;;
    esac
  }
  lc_se_file() {
    mkdir -p "$lc_se_fx/root${1%/*}" && printf '%s\n' "$2" > "$lc_se_fx/root$1"
  }
  lc_se_getent() {
    [[ "$1" == passwd ]] || return 2
    case "$2" in
      deskuser|"$lc_se_uid") echo "deskuser:x:$lc_se_uid:$lc_se_uid:Desk User,,,:/home/deskuser:/bin/bash" ;;
      *) return 2 ;;
    esac
  }
  lc_se_plant() {
    local t=/run/systemd/transient/rhizo-lc-dacprobe
    lc_se_file "$t.path" $'[Unit]\nDescription=/bin/true\n[Path]\n'"PathExistsGlob=$lc_se_rd/rhizo-lc-dacprobe-*"
    lc_se_file "$t.service" "[Unit]
Description=/bin/true
$( (( lc_se_ctl_cond_lost )) || grep -o -- '-p Condition[A-Za-z]*=[^ ]*' <<<"$1" | cut -c4-)
[Service]
ExecStart=/bin/true"
    touch "$lc_se_fx/planted"
  }
  lc_se_run() {
    (
      FAILED=0 LC_DESKTOP_USER=deskuser
      rm -f "$lc_se_fx/planted"
      local f
      for f in $(lc_se_all | sed -n 's/^FragmentPath=//p; s/^DropInPaths=//p'); do
        [[ -e "$lc_se_fx/root$f" ]] || lc_se_file "$f" ""
      done
      for f in $lc_se_unreadable; do rm -f "$lc_se_fx/root$f"; done
      eval "$LC_ST_REAL_DESK_USER_SH"
      desk_env() { echo "RHIZO_DESK_UID=$lc_se_uid WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=$lc_se_rd"; }
      ssh_vm() {
        shift 2
        case "$1" in
          _dus=*) printf '%s\n' "$lc_se_user" ;;
          *"systemctl show -p LoadState"*|*"list-unit-files"*) ( systemctl() { lc_se_systemctl "$@"; }; eval "$1" ) ;;
          *"SHOWRC"*)
            ( systemctl() { lc_se_systemctl "$@"; }; eval "$1" ) | if (( lc_se_show_cut )); then grep -vx DONE; else cat; fi ;;
          *"FILERC"*)
            ( sed() { local a=("$@"); a[-1]=$lc_se_fx/root${a[-1]}; command sed "${a[@]}"; }
              getent() { lc_se_getent "$@"; }
              eval "$1" ) 2>/dev/null \
              | LC_SE_SKIP=$lc_se_file_skip awk -v cut="$lc_se_file_cut" '
                  /^FILE / { s = ENVIRON["LC_SE_SKIP"] != "" && substr($0, 6) == ENVIRON["LC_SE_SKIP"] }
                  !s && !(cut && $0 == "DONE")
                  /^FILERC / { s = 0 }' ;;
          *"daemon-reload >/dev/null 2>&1; echo RC="*) echo "RC=$lc_se_reload_rc" ;;
          *"systemd-run "*"; echo RC="*) (( lc_se_ctl_rc )) || lc_se_plant "$1"; echo "RC=$lc_se_ctl_rc" ;;
          *"systemctl stop rhizo-lc-dacprobe"*) rm -f "$lc_se_fx/planted" ;;
          *) : ;;
        esac
      }
      lc_assert_session.env-from-user-manager >/dev/null 2>"$lc_se_fx/claim.err"
      local rc=$? left=""
      [[ -e "$lc_se_fx/planted" ]] && left=" PROBE-LEFT"
      echo "RC=$rc FAILED=$FAILED$left"
    )
  }
  lc_se_case() {
    local out; out=$(lc_se_run)
    if [[ "$2" == pass ]]; then
      [[ "$out" == "RC=0 FAILED=0" ]] || lc_se_bad+=" $1: $out $(grep FAIL "$lc_se_fx/claim.err" | head -1);"
    elif [[ "$out" != "RC=1 FAILED=1" ]] || ! grep -qF -- "$2" "$lc_se_fx/claim.err"; then
      lc_se_bad+=" $1: $out, want a fail naming '$2': $(grep FAIL "$lc_se_fx/claim.err" | head -1);"
    fi
  }
  lc_se_uid=1000 lc_se_root=0
  lc_se_rd="/run/user/$lc_se_uid" lc_se_root_rd="/run/user/$lc_se_root" lc_se_other_rd="/run/user/$((lc_se_uid + 1))"
  lc_se_env="XDG_RUNTIME_DIR=$lc_se_rd"$'\nWAYLAND_DISPLAY=wayland-1\n'"RHIZO_WAYLAND_HOST_SOCKET=$lc_se_rd/wayland-1"$'\n'"DBUS_SESSION_BUS_ADDRESS=unix:path=$lc_se_rd/bus"$'\nHOME=/home/deskuser'
  lc_se_stock="@@ -.mount
SourcePath=/proc/self/mountinfo
Where=/
What=/dev/vda1
Type=ext4
@@ -.slice
@@ user-runtime-dir@$lc_se_uid.service
FragmentPath=/usr/lib/systemd/system/user-runtime-dir@.service
ExecStart={ path=/usr/lib/systemd/systemd-user-runtime-dir ; argv[]=/usr/lib/systemd/systemd-user-runtime-dir start $lc_se_uid ; ignore_errors=no }
@@ run-user-$lc_se_uid.mount
SourcePath=/proc/self/mountinfo
Where=$lc_se_rd
What=tmpfs
Type=tmpfs
Options=rw,nosuid,nodev,relatime,size=1G,mode=700,uid=$lc_se_uid,gid=$lc_se_uid
@@ home.mount
FragmentPath=/run/systemd/generator/home.mount
SourcePath=/etc/fstab
Where=/home
What=/dev/vda3
@@ run-user-$lc_se_uid-gvfs.mount
SourcePath=/proc/self/mountinfo
Where=$lc_se_rd/gvfs
What=gvfsd-fuse
Type=fuse.gvfsd-fuse
Options=rw,nosuid,nodev,relatime,user_id=$lc_se_uid,group_id=$lc_se_uid
@@ run-user-$lc_se_uid-doc.mount
SourcePath=/proc/self/mountinfo
Where=$lc_se_rd/doc
What=portal
Type=fuse.portal
Options=rw,nosuid,nodev,relatime,user_id=$lc_se_uid,group_id=$lc_se_uid
@@ systemd-logind.service
FragmentPath=/usr/lib/systemd/system/systemd-logind.service
ReadWritePaths=/etc /run"
  lc_se_st=$lc_se_fx/shipped-root
  mkdir -p "$lc_se_st/usr/lib/systemd/system" "$lc_se_st/run/systemd/generator"
  printf '%s\n' '[Unit]' 'Description=User Runtime Directory /run/user/%i' 'Documentation=man:user@.service(5)' \
    'After=dbus.service' 'StopWhenUnneeded=yes' 'IgnoreOnIsolate=yes' '' '[Service]' \
    'ExecStart=/usr/lib/systemd/systemd-user-runtime-dir start %i' 'ExecStop=/usr/lib/systemd/systemd-user-runtime-dir stop %i' \
    'Type=oneshot' 'RemainAfterExit=yes' 'Slice=user-%i.slice' > "$lc_se_st/usr/lib/systemd/system/user-runtime-dir@.service"
  printf '%s\n' '# Automatically generated by systemd-fstab-generator' '' '[Unit]' \
    'Documentation=man:fstab(5) man:systemd-fstab-generator(8)' 'SourcePath=/etc/fstab' 'Before=local-fs.target' '' \
    '[Mount]' 'What=/dev/vda3' 'Where=/home' 'Type=ext4' > "$lc_se_st/run/systemd/generator/home.mount"
  printf '%s\n' '[Unit]' 'Description=User Login Management' 'ConditionPathExists=!/etc/rhizo-fixture-no-logind' \
    '[Service]' 'ReadWritePaths=/etc /run' > "$lc_se_st/usr/lib/systemd/system/systemd-logind.service"
  lc_se_reset() {
    rm -rf "$lc_se_fx/root" && cp -a "$lc_se_st" "$lc_se_fx/root"
    lc_se_unreadable="" lc_se_file_cut=0 lc_se_file_skip="" lc_se_ctl_cond_lost=0
    lc_se_load=$'not-found\nnot-found'
    lc_se_user=$'active\nactive\n1000\n1000 644 1005\n/home/deskuser\n'"$lc_se_env"$'\nDONE'
    lc_se_units="$lc_se_shipped"$'\n'"$lc_se_stock"
    lc_se_lf=$'getty@.service enabled enabled\nrhizo-display-pool.path enabled enabled'
    lc_se_lf_only="" lc_se_lu_empty=0 lc_se_lu_rc=0 lc_se_show_fail="" lc_se_no_id="" lc_se_show_cut=0
    lc_se_ctl_rc=0 lc_se_ctl_listed=1 lc_se_reload_rc=0
  }
  lc_se_bad=""
  for lc_se_want in androidd.service rhizo-deskd.service rhizo-display-pool.path androidd@1.service user@1000.service; do
    grep -qx "@@ $lc_se_want" <<<"$lc_se_shipped" || lc_se_bad+=" the shipped rendering has no $lc_se_want;"
  done
  grep -q '^@@ rhizo-desktop-session' <<<"$lc_se_shipped" && lc_se_bad+=" the shipped rendering holds a desktop-session user unit;"
  (( $(grep -c '^@@ ' <<<"$lc_se_shipped") >= 30 )) || lc_se_bad+=" the shipped rendering has under 30 units;"
  lc_se_reset; lc_se_case "the user-unit design over the shipped system units and stock boundary units" pass
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\nWorkingDirectory=/home/deskuser'
  lc_se_case "a system unit with WorkingDirectory=/home/deskuser" "rhizo-lc-fixture.service WorkingDirectory /home/deskuser"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-wl-watch.path\nFragmentPath=/etc/systemd/system/rhizo-wl-watch.path\n'"Paths=$lc_se_rd/wayland-0 (PathExists)"
  lc_se_case "a .path unit watching the runtime dir's wayland-0" "rhizo-wl-watch.path Paths $lc_se_rd/wayland-0"
  lc_se_reset
  lc_se_units+=$'\n@@ rhizo-desktop-session.path\nFragmentPath=/etc/systemd/system/rhizo-desktop-session.path\n'"Paths=$(sed -n 's/^PathExistsGlob=//p' "$lc_se_repo/src/services/units/session/desktop-session.path") (PathExistsGlob)"
  lc_se_case "the shipped desktop-session .path loaded as a system unit" "rhizo-desktop-session.path Paths $lc_se_rd/wayland-*"
  lc_se_reset; lc_se_lu_empty=1; lc_se_case "an empty list-units" "the system units could not be read: list-units named no unit"
  lc_se_reset; lc_se_user=${lc_se_user//\/home\/deskuser/\/srv\/deskuser}
  lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\nEnvironmentFiles=/srv/deskuser/.config/rhizo.env (ignore_errors=no)'
  lc_se_case "an EnvironmentFiles in a home outside /home" "rhizo-lc-fixture.service EnvironmentFiles /srv/deskuser/.config/rhizo.env"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\n'"StandardOutputFileDescriptorName=$lc_se_other_rd/rhizo.log"
  lc_se_case "stdout into another user's runtime dir" "rhizo-lc-fixture.service StandardOutputFileDescriptorName $lc_se_other_rd/rhizo.log"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\nExecStart={ path=/usr/bin/cat ; argv[]=/usr/bin/cat /home/deskuser/notes ; ignore_errors=no }'
  lc_se_case "an ExecStart argument under /home/" "rhizo-lc-fixture.service ExecStart /home/deskuser/notes"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\nBindPaths=/home/deskuser/share:/srv/share:rbind'
  lc_se_case "a BindPaths source in a home" "rhizo-lc-fixture.service BindPaths /home/deskuser/share"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\nReadWritePaths=/home/rhizo-other/data'
  lc_se_case "another account's home under /home/" "rhizo-lc-fixture.service ReadWritePaths /home/rhizo-other/data"
  lc_se_reset; lc_se_units+=$'\n@@ run-user-'"$lc_se_uid"$'-x.mount\nSourcePath=/proc/self/mountinfo\n'"Where=$lc_se_rd/x"$'\nWhat=rhizo-hostfsd\nType=fuse.rhizo-hostfsd\nOptions=rw,nosuid,nodev,relatime,user_id=0,group_id=0'
  lc_se_case "a root fuse mount in the runtime dir the mount table holds" "run-user-$lc_se_uid-x.mount Where $lc_se_rd/x (a mount-table unit, What=rhizo-hostfsd Type=fuse.rhizo-hostfsd, not a user's own FUSE mount)"
  lc_se_reset; lc_se_units+=$'\n@@ home-deskuser-share.mount\nSourcePath=/proc/self/mountinfo\nWhere=/home/deskuser/share\nWhat=/dev/vda1\nType=ext4\nOptions=rw,relatime'
  lc_se_case "a mount-table bind from /var/lib/rhizo into a home (What= the backing device)" "home-deskuser-share.mount Where /home/deskuser/share"
  lc_se_reset; lc_se_units+=$'\n@@ run-user-'"$lc_se_uid"$'-rhizo.mount\nSourcePath=/proc/self/mountinfo\n'"Where=$lc_se_rd/rhizo"$'\nWhat=tmpfs\nType=tmpfs\nOptions=rw,relatime'
  lc_se_case "a root tmpfs mounted under the runtime dir" "run-user-$lc_se_uid-rhizo.mount Where $lc_se_rd/rhizo"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-rd-watch.path\nFragmentPath=/etc/systemd/system/rhizo-rd-watch.path\n'"Paths=$lc_se_rd (PathChanged)"
  lc_se_case "a .path unit watching the runtime dir itself" "rhizo-rd-watch.path Paths $lc_se_rd"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\nWorkingDirectory=~\nUser=deskuser'
  lc_se_case "a system unit run as the desktop user with WorkingDirectory=~" "rhizo-lc-fixture.service WorkingDirectory ~ (the home of User=deskuser)"
  lc_se_reset; lc_se_units+=$'\n@@ home-deskuser-data.mount\nFragmentPath=/run/systemd/generator/home-deskuser-data.mount\nSourcePath=/etc/fstab\nWhere=/home/deskuser/data\nWhat=/dev/vdb1'
  lc_se_case "an fstab mount into a home, which a generator wrote" "home-deskuser-data.mount Where /home/deskuser/data"
  lc_se_cond() {
    lc_se_units+=$'\n@@ '"$1"$'\nFragmentPath=/etc/systemd/system/'"$1"
    lc_se_file "/etc/systemd/system/$1" "$2"
  }
  lc_se_reset; lc_se_cond rhizo-lc-cond.service $'[Unit]\nDescription=fixture\n'"ConditionPathExists=$lc_se_rd/wayland-0"$'\n[Service]\nExecStart=/bin/true'
  lc_se_case "a ConditionPathExists on the runtime dir's wayland-0" "rhizo-lc-cond.service ConditionPathExists $lc_se_rd/wayland-0"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-drop@'"$lc_se_uid"$'.service\nFragmentPath=/etc/systemd/system/rhizo-lc-drop@.service'
  lc_se_units+=$'\nDropInPaths=/usr/lib/systemd/system/rhizo-lc-drop@.service.d/10-base.conf /etc/systemd/system/rhizo-lc-drop@.service.d/50-wl.conf'
  lc_se_file /etc/systemd/system/rhizo-lc-drop@.service $'[Unit]\nConditionPathExists=/etc/rhizo\n[Service]\nExecStart=/bin/true'
  lc_se_file /etc/systemd/system/rhizo-lc-drop@.service.d/50-wl.conf $'[Unit]\nConditionDirectoryNotEmpty=| !/run/user/%i'
  lc_se_case "a drop-in adding a triggering, negated Condition on /run/user/%i" "rhizo-lc-drop@$lc_se_uid.service ConditionDirectoryNotEmpty $lc_se_rd (in /etc/systemd/system/rhizo-lc-drop@.service.d/50-wl.conf)"
  lc_se_reset; lc_se_cond rhizo-lc-cond.service $'[Unit]\nConditionPathExists=/etc/foo\nAssertPathIsDirectory=|!/etc/foo.d\n[Service]\nExecStart=/bin/true'
  lc_se_case "a Condition and an Assert on /etc/foo" pass
  lc_se_reset; lc_se_cond rhizo-lc-gone.service '[Unit]'; lc_se_unreadable=/etc/systemd/system/rhizo-lc-gone.service
  lc_se_case "an unreadable FragmentPath" "rhizo-lc-gone.service unit file /etc/systemd/system/rhizo-lc-gone.service could not be read (sed rc 2)"
  lc_se_reset; lc_se_cond rhizo-lc-cond.service $'[Unit]\nAssertPathExists=%h/.config/rhizo\n[Service]\nUser=deskuser'; lc_se_units+=$'\nUser=deskuser'
  lc_se_case "an AssertPathExists on %h as User=deskuser" "rhizo-lc-cond.service AssertPathExists /home/deskuser/.config/rhizo"
  lc_se_reset; lc_se_cond rhizo-lc-cond.service $'[Unit]\nConditionPathExists=!/run/user/%U/bus\n[Service]\nUser='"$lc_se_uid"; lc_se_units+=$'\nUser='"$lc_se_uid"
  lc_se_case "a negated Condition on /run/user/%U as a numeric User=" "rhizo-lc-cond.service ConditionPathExists $lc_se_rd/bus"
  lc_se_reset; lc_se_cond rhizo-lc-cond.service $'[Unit]\nAssertPathExists=%h/x\n[Service]\nUser=rhizo-nobody'; lc_se_units+=$'\nUser=rhizo-nobody'
  lc_se_case "a %h Condition whose User= does not resolve" "rhizo-lc-cond.service AssertPathExists=%h/x names %h or %U and User=rhizo-nobody did not resolve"
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-esc@run-user-'"$lc_se_uid"$'-wayland\\x2d0.service\nFragmentPath=/etc/systemd/system/rhizo-lc-esc@.service'
  lc_se_file /etc/systemd/system/rhizo-lc-esc@.service $'[Unit]\nConditionPathIsSymbolicLink=/%I\nConditionPathExists=%f.lock'
  lc_se_case "Conditions on /%I and %f of an escaped instance" "rhizo-lc-esc@run-user-$lc_se_uid-wayland\\x2d0.service ConditionPathIsSymbolicLink $lc_se_rd/wayland-0"
  grep -qF "ConditionPathExists $lc_se_rd/wayland-0.lock" "$lc_se_fx/claim.err" || lc_se_bad+=" %f of an escaped instance was not resolved: $(grep FAIL "$lc_se_fx/claim.err" | head -1);"
  lc_se_reset; lc_se_cond rhizo-lc-cond.service $'[Unit]\nConditionPathExistsGlob=/run/user/*/wayland-*'
  lc_se_case "a Condition glob over every runtime dir" "rhizo-lc-cond.service ConditionPathExistsGlob /run/user/*/wayland-*"
  lc_se_reset; lc_se_cond rhizo-lc-cond.service $'[Unit]\nConditionPathExists=\\\n'"  $lc_se_rd/rhizo-cont"
  lc_se_case "a Condition continued onto the next line" "rhizo-lc-cond.service ConditionPathExists $lc_se_rd/rhizo-cont"
  lc_se_reset; lc_se_cond rhizo-lc-cond.service $'[Service]\nExecStart=/bin/true\n'"ConditionPathExists=$lc_se_rd/wayland-0"
  lc_se_case "a Condition key in [Service], which PID 1 ignores" pass
  lc_se_reset; sed -i "s#^ConditionPathExists=|!/var/lib/rhizo/\\.prepared\$#ConditionPathExists=|!$lc_se_rd/.prepared#" "$lc_se_fx/root/usr/lib/systemd/system/rhizo-prepare.service"
  lc_se_case "the shipped rhizo-prepare.service's own Condition moved into the runtime dir" "rhizo-prepare.service ConditionPathExists $lc_se_rd/.prepared"
  lc_se_reset; lc_se_file_cut=1; lc_se_case "a unit file read that never finished" "the unit file read never finished"
  lc_se_reset; lc_se_file_skip=/usr/lib/systemd/system/rhizo-display-pool.path
  lc_se_case "a unit file the finished read never returned" "rhizo-display-pool.path unit file /usr/lib/systemd/system/rhizo-display-pool.path was never read"
  lc_se_reset; lc_se_ctl_cond_lost=1
  lc_se_case "a planted .service whose Condition the file read never names" "the planted PID 1 .service's ConditionPathExists under $lc_se_rd was not named"
  unset -f lc_se_cond
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-nofile.service\nWorkingDirectory=/home/deskuser'
  lc_se_case "a unit with no file (no fragment, drop-in or source)" pass
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\n'"WorkingDirectory=$lc_se_root_rd/rhizo"$'\nReadOnlyPaths=-/home'
  lc_se_case "root's own runtime dir and /home itself" pass
  lc_se_reset; lc_se_lf+=$'\nrhizo-lf-only.service enabled enabled'; lc_se_lf_only=rhizo-lf-only.service
  lc_se_units+=$'\n@@ rhizo-lf-only.service\nFragmentPath=/etc/systemd/system/rhizo-lf-only.service\nReadOnlyPaths=/home/deskuser/x'
  lc_se_case "an enabled unit file PID 1 has not loaded" "rhizo-lf-only.service ReadOnlyPaths /home/deskuser/x"
  lc_se_scope() {
    lc_se_units+=$'\n@@ '"$1"$'\nFragmentPath='"$2"$'\nSlice='"$3"$'\nRequiresMountsFor='"$4"
    lc_se_file "$2" $'# This is a transient unit file, created programmatically via the systemd API. Do not edit.\n[Unit]\nDescription=Session 4 of User deskuser\n'"RequiresMountsFor=$4"$'\n[Scope]\n'"Slice=$3"
  }
  lc_se_reset; lc_se_scope session-4.scope /run/systemd/transient/session-4.scope "user-$lc_se_uid.slice" /home/deskuser
  lc_se_case "logind's own session scope requiring its user's home mounted" pass
  lc_se_reset; lc_se_units+=$'\n@@ rhizo-lc-fixture.service\nFragmentPath=/etc/systemd/system/rhizo-lc-fixture.service\nSlice='"user-$lc_se_uid.slice"$'\nRequiresMountsFor=/home/deskuser'
  lc_se_case "a Rhizo unit in the user's slice requiring the user's home mounted" "rhizo-lc-fixture.service RequiresMountsFor /home/deskuser"
  lc_se_reset; lc_se_scope session-4.scope /etc/systemd/system/session-4.scope "user-$lc_se_uid.slice" /home/deskuser
  lc_se_case "a session-named scope from a unit file, not logind's transient one" "session-4.scope RequiresMountsFor /home/deskuser"
  lc_se_reset; lc_se_scope session-4.scope /run/systemd/transient/session-4.scope "user-$lc_se_uid.slice" /home/deskuser/data
  lc_se_case "a session scope requiring a path inside its user's home" "session-4.scope RequiresMountsFor /home/deskuser/data"
  lc_se_reset; lc_se_scope session-4.scope /run/systemd/transient/session-4.scope "user-$lc_se_uid.slice" /home/rhizo-other
  lc_se_case "a session scope requiring another account's home" "session-4.scope RequiresMountsFor /home/rhizo-other"
  lc_se_reset; lc_se_scope session-4.scope /run/systemd/transient/session-4.scope "user-$((lc_se_uid + 1)).slice" /home/deskuser
  lc_se_case "a session scope whose slice's uid is not the home's user" "session-4.scope RequiresMountsFor /home/deskuser"
  lc_se_reset; lc_se_scope session-4.scope /run/systemd/transient/session-4.scope "user-$lc_se_uid.slice" /home/deskuser
  lc_se_units+=$'\nWorkingDirectory=/home/deskuser'
  lc_se_case "a session scope's other property in its user's home" "session-4.scope WorkingDirectory /home/deskuser"
  lc_se_reset; lc_se_scope rhizo-4.scope /run/systemd/transient/rhizo-4.scope "user-$lc_se_uid.slice" /home/deskuser
  lc_se_case "a transient scope not named session-<id>.scope" "rhizo-4.scope RequiresMountsFor /home/deskuser"
  unset -f lc_se_scope
  lc_se_reset; lc_se_show_fail=rhizo-display-pool.path; lc_se_case "a unit whose read failed" "rhizo-display-pool.path systemctl show exited 1"
  lc_se_reset; lc_se_no_id=androidd.service; lc_se_case "a unit read with no Id" "androidd.service read no Id"
  lc_se_reset; lc_se_lu_rc=1; lc_se_case "a list-units that failed" "a unit listing failed (LURC=1"
  lc_se_reset; lc_se_show_cut=1; lc_se_case "a unit read that never finished" "the unit read never finished"
  lc_se_reset; lc_se_ctl_listed=0
  lc_se_case "a planted .path the unit read never lists" "the planted PID 1 .path watching $lc_se_rd was not named"
  lc_se_reset; lc_se_ctl_rc=1; lc_se_case "a control that could not be planted" "the planted PID 1 .path could not be started (RC=1)"
  lc_se_reset; lc_se_reload_rc=1; lc_se_case "a refused daemon-reload" "systemctl daemon-reload did not exit 0 (RC=1)"
  lc_se_reset; lc_se_load=$'loaded\nloaded'
  lc_se_case "PID 1 loading the pair" "PID 1 still loads a desktop-session unit: rhizo-desktop-session.path=loaded rhizo-desktop-session.service=loaded"
  lc_se_reset; lc_se_load=$'not-found\nloaded'
  lc_se_case "PID 1 loading the .service alone" "PID 1 still loads a desktop-session unit: rhizo-desktop-session.path=not-found rhizo-desktop-session.service=loaded"
  lc_se_reset; lc_se_load=$'\n'; lc_se_case "an empty LoadState read" "PID 1 still loads a desktop-session unit: rhizo-desktop-session.path= rhizo-desktop-session.service="
  lc_se_reset; lc_se_user=${lc_se_user/active$'\n'active/active$'\n'inactive}; lc_se_case "an inactive user .service" "manager does not run the pair: active inactive"
  lc_se_reset; lc_se_user=${lc_se_user/1000 644 1005/1000 644 900}; lc_se_case "a session.env older than the socket" "file: '1000 644 900', socket mtime '1000'"
  lc_se_reset; lc_se_user=${lc_se_user/1000 644 1005/0 644 1005}; lc_se_case "a root-owned session.env" "file: '0 644 1005'"
  lc_se_reset; lc_se_user=${lc_se_user/1000 644 1005/1000 600 1005}; lc_se_case "a 0600 session.env" "file: '1000 600 1005'"
  lc_se_reset; lc_se_user=${lc_se_user/1000$'\n'1000 644 1005/1000$'\n'none}; lc_se_case "an absent session.env" "file: 'none"
  lc_se_reset; lc_se_user=${lc_se_user/"XDG_RUNTIME_DIR=$lc_se_rd"/"XDG_RUNTIME_DIR=$lc_se_root_rd"}
  lc_se_case "another user's values" "session.env does not name deskuser's own session: XDG_RUNTIME_DIR=$lc_se_root_rd"
  lc_se_reset; lc_se_user=${lc_se_user%$'\n'DONE}; lc_se_case "a user read with no DONE" "the desktop user's read never finished"
  if [[ -z "$lc_se_bad" ]]; then
    ok "1zc: session.env-from-user-manager passes the user-unit design over every system unit debian/rules ships, rendered from its own files, beside /home, the runtime dir's own mount, root's own runtime dir, the mount-table gvfs and document-portal mounts under it and logind's own transient session scope requiring its user's home, and fails by name on a session scope from a unit file, misnamed, in another uid's slice or requiring another path, a Rhizo unit requiring the home, PID 1 loading the pair or the .service alone, an empty LoadState read, a system unit naming a path under /home/, the user's home outside /home or a non-root /run/user/<uid>/ (WorkingDirectory, a .path's watch incl. the shipped desktop-session .path, EnvironmentFiles, stdout, an ExecStart argument, BindPaths, an enabled unit not loaded, a .path on the runtime dir itself, WorkingDirectory=~ as the desktop user, an fstab mount a generator wrote, a mount-table root FUSE, bind or tmpfs mount, as systemd prints their What=, and a Condition or Assert in a fragment or drop-in, the shipped rhizo-prepare.service's own among them, through its | and ! prefixes, a continued line and the %i, %I, %f, %h and %U of its unit, or a glob over every runtime dir), an empty or failed listing, a unit read failed, Id-less or unfinished, a unit file unreadable, unreturned or unfinished, a %h whose User= has no passwd entry, a control unplanted or unlisted, a planted Condition unnamed, a refused reload, and a session.env inactive, outdated, root-owned, 0600, absent, foreign or unread"
  else
    bad "1zc:$lc_se_bad"
  fi
  rm -rf "$lc_se_fx"
  unset -f lc_se_run lc_se_case lc_se_reset lc_se_all lc_se_systemctl lc_se_file lc_se_getent lc_se_plant
  unset lc_se_fx lc_se_bad lc_se_env lc_se_load lc_se_user lc_se_repo lc_se_render_py lc_se_shipped lc_se_stock lc_se_want
  unset lc_se_units lc_se_lf lc_se_lf_only lc_se_lu_empty lc_se_lu_rc lc_se_show_fail lc_se_no_id lc_se_show_cut
  unset lc_se_ctl_rc lc_se_ctl_listed lc_se_reload_rc lc_se_st lc_se_unreadable lc_se_file_cut lc_se_file_skip lc_se_ctl_cond_lost
  unset lc_se_uid lc_se_root lc_se_rd lc_se_root_rd lc_se_other_rd

  lc_pg_fx=$(mktemp -d) || exit 1
  lc_pg_pgrep() {
    local full=0 exact=0 all=0 pat line pid comm cmd hit
    while [[ "${1:-}" == -* ]]; do
      [[ "$1" == *f* ]] && full=1
      [[ "$1" == *x* ]] && exact=1
      [[ "$1" == *a* ]] && all=1
      shift
    done
    pat=$1
    while IFS=$'\t' read -r pid comm cmd; do
      if (( full )); then hit=$cmd; else hit=$comm; fi
      if (( exact )); then [[ "$hit" =~ ^($pat)$ ]] || continue
      else [[ "$hit" =~ $pat ]] || continue; fi
      if (( all )); then echo "$pid $cmd"; else echo "$pid"; fi
    done < "$lc_pg_fx/table"
  }
  ssh_vm() {
    shift 2
    { cat "$lc_pg_fx/procs"; printf '999\tbash\tbash -c %s\n' "$1"; } > "$lc_pg_fx/table"
    ( pgrep() { lc_pg_pgrep "$@"; }; eval "$1" )
  }
  lc_pg_bad=""
  : > "$lc_pg_fx/procs"
  lc_pg_old=$(ssh_vm -t 10 'pgrep -af xdg-open 2>/dev/null')
  [[ "$lc_pg_old" == "999 bash -c pgrep -af xdg-open 2>/dev/null" ]] \
    || lc_pg_bad+=" the model does not reproduce a pgrep -f that matches its own ssh shell (got '$lc_pg_old');"
  lc_pg_got=$(lc_procs_named xdg-open 10)
  [[ -z "$lc_pg_got" ]] || lc_pg_bad+=" lc_procs_named found '$lc_pg_got' on a guest with no xdg-open;"
  printf '4242\txdg-open\t/bin/sh /usr/bin/xdg-open https://example.com/lc-open-uri-off-1\n' > "$lc_pg_fx/procs"
  lc_pg_got=$(lc_procs_named xdg-open 10)
  [[ "$lc_pg_got" == "4242 /bin/sh /usr/bin/xdg-open https://example.com/lc-open-uri-off-1" ]] \
    || lc_pg_bad+=" lc_procs_named missed a live xdg-open (got '$lc_pg_got');"
  printf '5151\trhizo-wlbridge\t/usr/lib/rhizo/deskbridge/rhizo-wlbridge --caps clipboard\n' > "$lc_pg_fx/procs"
  lc_pg_got=$(lc_procs_named rhizo-wlbridge)
  [[ "$lc_pg_got" == "5151 /usr/lib/rhizo/deskbridge/rhizo-wlbridge --caps clipboard" ]] \
    || lc_pg_bad+=" lc_procs_named rhizo-wlbridge read '$lc_pg_got', not the one live bridge;"
  lc_pg_lint=$(grep -nE "p(grep|kill) -[a-z]*f" "$LC_TOOLS_DIR/cycle.sh" \
    | grep -vE "^[0-9]+: *#" | grep -vE "p(grep|kill) -[a-z]*f[a-z]* +(['\"][^'\"]*\[|[^'\"[:space:]]*\[)" | sed 's/^/cycle.sh:/')
  lc_pg_lint+=$(grep -nE "p(grep|kill) -[a-z]*f" "$LC_TOOLS_DIR"/claims-*.sh \
    | grep -vE "^[^:]+:[0-9]+: *#" | grep -vE "p(grep|kill) -[a-z]*f[a-z]* +(['\"][^'\"]*\[|[^'\"[:space:]]*\[)")
  [[ -z "$lc_pg_lint" ]] || lc_pg_bad+=" a claim probe matches its own shell: $(tr '\n' ' ' <<<"$lc_pg_lint");"
  if [[ -z "$lc_pg_bad" ]]; then
    ok "1zl: a probe by pgrep -f finds its own ssh shell, lc_procs_named finds nothing on a clean guest and exactly the live process otherwise, and no claim body probes by an unbracketed pgrep/pkill -f pattern"
  else
    bad "1zl:$lc_pg_bad"
  fi
  unset -f ssh_vm lc_pg_pgrep
  rm -rf "$lc_pg_fx"
  unset lc_pg_fx lc_pg_bad lc_pg_old lc_pg_got lc_pg_lint

  lc_nb_run() {
    (
      FAILED=0
      lc_nb_state=on
      ssh_vm() {
        shift 2
        case "$1" in
          *policy_or_deny*) [[ "$lc_nb_state" == on ]] && echo "True frozenset()" || echo "False frozenset()" ;;
          *'-p MainPID'*) echo "$lc_nb_pid" ;;
          *'-p User'*) echo deskuser ;;
          *'ss -xp'*) ( runuser() { local u=$2; shift 3; lc_nb_as=$u "$@"; }
                        ss() { lc_nb_ss; }; eval "$1" ) ;;
          *'systemctl is-active rhizo-deskd.service'*) echo active ;;
          *'stat -c%s /var/log/rhizo/rhizo-deskd.log'*) echo 100 ;;
          *'tail -c +101 /var/log/rhizo/rhizo-deskd.log'*) printf '%s\n' "[00:00:00] desktop.notifications is off: the session bus is not attached" "[00:00:01] android app authenticated" ;;
          *'systemctl show -p ActiveState --value rhizo-desk-token.service'*) echo active ;;
          *LC_POLICY_ABSENT_MARKER*) printf 'LC_POLICY_ABSENT_MARKER\n%s\n' "$PROBE_DONE_TAG" ;;
          *"printf '[desktop]"*) lc_nb_state=off ;;
          *'rm -f /etc/rhizo/policy.conf'*) lc_nb_state=on ;;
          *'test -f /etc/rhizo/policy.conf'*) printf 'ABSENT\n%s\n' "$PROBE_DONE_TAG" ;;
          *'systemctl restart rhizo-deskd.service'*) : ;;
          *) return 255 ;;
        esac
      }
      lc_nb_ss() {
        (( lc_nb_bus )) || return 0
        if [[ "${lc_nb_as:-root}" == deskuser ]]; then
          echo 'u_str ESTAB 0 0 * 41001 * 41002 users:(("python3",pid=777,fd=6))'
        else
          echo 'u_str ESTAB 0 0 * 41001 * 41002'
        fi
      }
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      lc_assert_capability.desktop-notifications >/dev/null 2>"$lc_nb_err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_nb_err=$(mktemp) || exit 1
  lc_nb_bad=""
  lc_nb_pid=777 lc_nb_bus=1
  lc_nb_root=$( ssh_vm() { shift 2; ( ss() { lc_nb_as=root; echo 'u_str ESTAB 0 0 * 41001 * 41002'; }; eval "$1" ); }
                ssh_vm -t 15 "ss -xp 2>/dev/null | grep ESTAB | grep pid=777," )
  [[ -z "$lc_nb_root" ]] || lc_nb_bad+=" the model's root vantage named a pid ('$lc_nb_root');"
  lc_nb_out=$(lc_nb_run)
  [[ "$lc_nb_out" == "RC=0 FAILED=0" ]] \
    || lc_nb_bad+=" a live bus client read as deskd's own user: $lc_nb_out $(grep FAIL "$lc_nb_err" | head -1);"
  lc_nb_bus=0; lc_nb_out=$(lc_nb_run)
  [[ "$lc_nb_out" == "RC=1 FAILED=1" ]] && grep -qF "(pid 777, user deskuser) holds no ESTABLISHED unix socket" "$lc_nb_err" \
    || lc_nb_bad+=" no bus client: $lc_nb_out, want the no-ESTABLISHED fail: $(grep FAIL "$lc_nb_err" | head -1);"
  lc_nb_bus=1 lc_nb_pid=0; lc_nb_out=$(lc_nb_run)
  [[ "$lc_nb_out" == "RC=1 FAILED=1" ]] && grep -qF "MainPID read '0'" "$lc_nb_err" \
    || lc_nb_bad+=" MainPID 0: $lc_nb_out, want the MainPID fail: $(grep FAIL "$lc_nb_err" | head -1);"
  if [[ -z "$lc_nb_bad" ]]; then
    ok "1zm: capability.desktop-notifications finds deskd's bus client reading ss as deskd's own User= where root sees no pid, and fails by name on no ESTABLISHED socket and on a MainPID of 0"
  else
    bad "1zm:$lc_nb_bad"
  fi
  rm -f "$lc_nb_err"
  unset -f lc_nb_run
  unset lc_nb_err lc_nb_bad lc_nb_pid lc_nb_bus lc_nb_root lc_nb_out

  lc_pb_fx=$(mktemp -d) || exit 1
  lc_pb_hook() {
    (
      BUS_ADDR="$1" DESK_USER=deskuser DESK_RUNTIME_DIR="$lc_pb_fx/rd" lc_pb_answer="$2"
      : > "$lc_pb_fx/runs"
      lc_seat_login_record() { :; }
      ssh_vm() {
        case "${*: -1}" in
          *'dbus-daemon --session --fork --print-address'*) echo run >> "$lc_pb_fx/runs"; printf '%s\n' "$lc_pb_answer" ;;
          *) return 255 ;;
        esac
      }
      LIFECYCLE_PROFILE=sway installer_post_reboot_hook "selftest reboot" 2>/dev/null
      echo "$BUS_ADDR|$(wc -l < "$lc_pb_fx/runs")"
    )
  }
  lc_pb_bad=""
  lc_pb_out=$(lc_pb_hook unix:path=/tmp/dbus-OLD,guid=1 unix:path=/tmp/dbus-NEW,guid=2)
  [[ "$lc_pb_out" == "unix:path=/tmp/dbus-NEW,guid=2|1" ]] || lc_pb_bad+=" a reboot kept step 2's bus: '$lc_pb_out';"
  lc_pb_out=$(lc_pb_hook unix:path=/tmp/dbus-OLD,guid=1 "")
  [[ "$lc_pb_out" == "|1" ]] || lc_pb_bad+=" no dbus-daemon after the reboot left BUS_ADDR '$lc_pb_out', want it emptied;"
  lc_pb_out=$(lc_pb_hook "" unix:path=/tmp/dbus-NEW,guid=2)
  [[ "$lc_pb_out" == "|0" ]] || lc_pb_bad+=" a cycle with no private bus got one started: '$lc_pb_out';"
  lc_pb_out=$(
    FAILED=0 BUS_ADDR="" APP_PKG=com.rhizo.deskapp LC_ENTRY_PATH=/usr/share/applications/rhizo-com.rhizo.deskapp.desktop
    ssh_vm() { case "${*: -1}" in cat*) printf '[Desktop Entry]\nName=x\n' ;; *) return 255 ;; esac; }
    notify_sink_start() { echo "sink started on '${1:-}'" >&2; return 0; }
    lc_assert_applifecycle.uninstall-entry-action 2>&1 >/dev/null; echo "RC=$? FAILED=$FAILED"
  )
  [[ "$lc_pb_out" == *"no private session bus to run the removal on (BUS_ADDR='')"*"RC=1 FAILED=1" && "$lc_pb_out" != *"sink started"* ]] \
    || lc_pb_bad+=" uninstall-entry-action on an empty BUS_ADDR: $(tr '\n' ' ' <<<"$lc_pb_out");"
  if [[ -z "$lc_pb_bad" ]]; then
    ok "1zn: a reboot replaces the private bus step 2 started, empties BUS_ADDR when no dbus-daemon starts, starts none for a cycle with no private bus, and uninstall-entry-action fails by name on an empty BUS_ADDR before any sink starts"
  else
    bad "1zn:$lc_pb_bad"
  fi
  rm -rf "$lc_pb_fx"
  unset -f lc_pb_hook
  unset lc_pb_fx lc_pb_bad lc_pb_out

  lc_lw_out=$(
    FAILED=0 APP_PKG=com.rhizo.deskapp APP_ACT=com.rhizo.deskapp.MainActivity
    ssh_vm() {
      case "${*: -1}" in
        *'wc -l < /run/rhizo-launch/rhizo-launch.log'*) echo 5 ;;
        *'rhizo-launch.sh com.rhizo.deskapp'*) echo rc=1 ;;
        *'tail -3 /tmp/rhizo-lifecycle-launch-windows-usable.log'*) echo "RHIZO_LAUNCH_FAILED reason=display-add" ;;
        *) return 255 ;;
      esac
    }
    desktop_close_all_app_windows() { [[ "$2" == rhizo-com.rhizo.deskapp ]]; }
    lc_assert_desktop.windows-usable 2>&1 >/dev/null; echo "RC=$? FAILED=$FAILED"
  )
  if [[ "$lc_lw_out" == *"desktop.windows-usable: rhizo-launch.sh for com.rhizo.deskapp/com.rhizo.deskapp.MainActivity did not report rc=0 (last line: rc=1; its log ends: RHIZO_LAUNCH_FAILED reason=display-add"*"RC=1 FAILED=1" ]]; then
    ok "1zo: desktop.windows-usable names a failed launch's own rc and log tail, not a default"
  else
    bad "1zo: desktop.windows-usable on a failed launch read: $(tr '\n' ' ' <<<"$lc_lw_out")"
  fi
  unset lc_lw_out

  lc_cr_fx=$(mktemp -d) || exit 1
  lc_cr_out=$( (
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
    INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=com.rhizo.deskapp.MainActivity
    echo 0 > "$lc_cr_fx/polls"
    logcat_since_marker() { echo "09-26 03:47:58.000"; }
    clip_focus_snapshot() { :; }
    android_sh() {
      local n
      case "${*: -1}" in
        *'logcat -d -b all'*)
          n=$(( $(cat "$lc_cr_fx/polls") + 1 )); echo "$n" > "$lc_cr_fx/polls"
          [[ "${*: -1}" == *"-t '09-26 03:47:58.000'"* ]] \
            || echo "09-26 03:47:42.100 I RhizoDeskApp: RHIZO_CLIP_READ mime=text/plain b64=b2xk"
          (( n >= 2 )) && echo "09-26 03:47:59.300 I RhizoDeskApp: RHIZO_CLIP_READ mime=text/plain b64=bmV3"
          ;;
      esac
      return 0
    }
    clip_read 'RHIZO_CLIP_READ mime=[^ ]* b64=[A-Za-z0-9+/=]*' 20 /dev/null; echo " RC=$?"
  ) 2>/dev/null )
  if [[ "$lc_cr_out" == "RHIZO_CLIP_READ mime=text/plain b64=bmV3 RC=0" ]]; then
    ok "1zq: clip_read returns the app's own read, logged after its trigger, and never the older RHIZO_CLIP_READ still in the ring"
  else
    bad "1zq: clip_read with an older read in the ring answered '$lc_cr_out', want the new read's token"
  fi
  rm -rf "$lc_cr_fx"
  unset lc_cr_fx lc_cr_out

  lc_fz_fx=$(mktemp -d) || exit 1
  lc_fz_cgmk() {
    mkdir -p "$lc_fz_fx/cg/$1"
    echo 0 > "$lc_fz_fx/cg/$1/cgroup.freeze"
    printf 'populated 1\nfrozen 0\n' > "$lc_fz_fx/cg/$1/cgroup.events"
    local p; : > "$lc_fz_fx/cg/$1/cgroup.procs"
    for p in "${@:2}"; do
      echo "$p" >> "$lc_fz_fx/cg/$1/cgroup.procs"
      mkdir -p "$lc_fz_fx/proc/$p"; echo "0::/$1" > "$lc_fz_fx/proc/$p/cgroup"; echo "proc$p" > "$lc_fz_fx/proc/$p/comm"
    done
  }
  lc_fz_kernel() {
    local ev d f
    while read -r ev; do
      d=${ev%/cgroup.events} f=0
      while [[ "$d" == "$lc_fz_fx/cg"/* ]]; do
        [[ "$(<"$d/cgroup.freeze")" == 1 ]] && { f=1; break; }
        d=${d%/*}
      done
      printf 'populated 1\nfrozen %s\n' "$f" > "$ev"
    done < <(find "$lc_fz_fx/cg" -name cgroup.events)
  }
  lc_fz_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=com.rhizo.deskapp.MainActivity
      lc_fz_left="$1" lc_fz_bridge="${2:-up}" lc_fz_focus="${3:-ok}" lc_fz_guest="${4:-ok}" lc_fz_carrier="${5:-handed}"
      : > "$lc_fz_fx/calls"; echo 0 > "$lc_fz_fx/ctl"; rm -f "$lc_fz_fx/handed" "$lc_fz_fx/acked"
      rm -rf "${lc_fz_fx:?}/cg" "${lc_fz_fx:?}/proc" "${lc_fz_fx:?}/bin"; mkdir -p "$lc_fz_fx/bin"
      lc_fz_cgmk rhizo; lc_fz_cgmk rhizo/init 1; lc_fz_cgmk rhizo/launcher 7
      lc_fz_cgmk rhizo/system; lc_fz_cgmk rhizo/system/uid_1000
      lc_fz_cgmk rhizo/system/uid_1000/pid_100 100; lc_fz_cgmk rhizo/system/uid_1000/pid_200 200
      lc_fz_cgmk rhizo/system/uid_1041 ; lc_fz_cgmk rhizo/system/uid_1041/pid_300 300
      lc_fz_cgmk rhizo/apps; lc_fz_cgmk rhizo/apps/uid_10077; lc_fz_cgmk rhizo/apps/uid_10077/pid_400 400
      lc_fz_cgmk rhizo/apps/uid_10099; lc_fz_cgmk rhizo/apps/uid_10099/pid_500 500
      echo 1 > "$lc_fz_fx/cg/rhizo/apps/uid_10099/pid_500/cgroup.freeze"
      local lc_fz_comp=200
      [[ "$lc_fz_guest" == two-composers ]] && { lc_fz_cgmk rhizo/system/uid_1000/pid_201 201; lc_fz_comp="200 201"; }
      [[ "$lc_fz_guest" == live-beside ]] && echo 202 >> "$lc_fz_fx/cg/rhizo/system/uid_1000/pid_200/cgroup.procs"
      if [[ "$lc_fz_guest" == unlisted-beside ]]; then
        rm -f "$lc_fz_fx/cg/rhizo/system/uid_1000/pid_200/cgroup.procs"
        mkdir "$lc_fz_fx/cg/rhizo/system/uid_1000/pid_200/cgroup.procs"
      fi
      printf '#!/bin/sh\n[ "$*" = "-x rhizo-composer" ] || exit 2\nprintf "%%s\\n" %s\n' "$lc_fz_comp" > "$lc_fz_fx/bin/pgrep"
      chmod +x "$lc_fz_fx/bin/pgrep"
      lc_fz_kernel
      _lc_desktop_stack_cgroup() { echo /sys/fs/cgroup/rhizo; }
      _lc_desktop_bridge_current() {
        echo current >> "$lc_fz_fx/calls"
        [[ "$lc_fz_bridge" == up ]] || { echo "no android app authenticated since the last listening on"; return 1; }
      }
      android_sh() { case "$2" in *clip_write*) echo clip-write >> "$lc_fz_fx/calls" ;; esac; return 0; }
      app_wait_token() { echo RHIZO_CLIP_WROTE; }
      rhizo_ctl_out() {
        local n; n=$(( $(cat "$lc_fz_fx/ctl") + 1 )); echo "$n" > "$lc_fz_fx/ctl"
        (( n >= 2 )) && echo "clip set-ok cid=1"
        if [[ -e "$lc_fz_fx/handed" && "$lc_fz_carrier" != unacked ]]; then
          echo "clip set-ok cid=2"; touch "$lc_fz_fx/acked"
        fi
        return 0
      }
      _lc_desktop_bridge_restart() { echo restart >> "$lc_fz_fx/calls"; }
      desk_clipboard() {
        if [[ "$1" == focus-rhizo ]]; then
          echo focus >> "$lc_fz_fx/calls"
          [[ "$lc_fz_focus" == ok ]] || { echo "no Rhizo window is mapped to take focus"; return 1; }
          return 0
        fi
        [[ "$1" == mark ]] && { echo 7; return 0; }
        [[ "$1 $4" == "get 7" ]] || { echo "paste-without-mark" >> "$lc_fz_fx/calls"; return 1; }
        echo "paste" >> "$lc_fz_fx/calls"
        [[ "$lc_fz_carrier" == already || -e "$lc_fz_fx/acked" ]] || return 1
        [[ "$lc_fz_guest" != mute ]] && grep -qx 'frozen 0' "$lc_fz_fx/cg/rhizo/system/uid_1000/pid_200/cgroup.events" \
          && base64 -w0 < "$lc_fz_fx/want"
      }
      nonce() { echo 0123456789abcdef; }
      echo 1000 > "$lc_fz_fx/now"
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_fz_fx/now"); echo $(( n + 1 )) > "$lc_fz_fx/now"; echo "$n"
      }
      sleep() { :; }
      printf 'rhizo-frozen-0123456789abcdef' > "$lc_fz_fx/want"
      ssh_vm() {
        local body="${*: -1}" rc=0
        case "$body" in
          *'pkill -x rhizo-wlbridge'*) echo pkill >> "$lc_fz_fx/calls"; [[ "$lc_fz_carrier" == handed || "$lc_fz_carrier" == unacked ]] && touch "$lc_fz_fx/handed" ;;
          *'stat -c%s /var/log/rhizo/rhizo-deskd.log'*) echo 4096 ;;
          *'tail -c +4097 /var/log/rhizo/rhizo-deskd.log'*"clip carrier: "*)
            grep -qx carrier "$lc_fz_fx/calls" || echo carrier >> "$lc_fz_fx/calls"
            case "$lc_fz_carrier" in
              handed|unacked) echo "[08:27:10] clip carrier: rhizo-wlbridge gone, Android's text/plain handed to the composer's leg" ;;
              already) echo "[08:27:10] clip carrier: rhizo-wlbridge gone, the composer's leg already carries Android's clip" ;;
            esac
            echo DONE ;;
          *'ps -e -o pid=,stat=,comm=,args= && echo DONE'*)
            [[ "$lc_fz_left" == PSFAIL ]] && return 0
            printf '    1 Ss   systemd         /sbin/init\n 6000 S    rhizo-wlbridge- /tmp/rhizo-wlbridge-test --caps clipboard\n%s%sDONE\n' "$lc_fz_left" "${lc_fz_left:+$'\n'}" ;;
          *'echo 1 > /sys/fs/cgroup/rhizo/cgroup.freeze'*) echo freeze >> "$lc_fz_fx/calls"; echo 1 > "$lc_fz_fx/cg/rhizo/cgroup.freeze" ;;
          *'cat /sys/fs/cgroup/rhizo/cgroup.freeze'*) cat "$lc_fz_fx/cg/rhizo/cgroup.freeze" ;;
          *'echo 0 > /sys/fs/cgroup/rhizo/cgroup.freeze'*) echo unfreeze >> "$lc_fz_fx/calls"; echo 0 > "$lc_fz_fx/cg/rhizo/cgroup.freeze" ;;
          'bash -c '*)
            case "$body" in
              *unfreeze*) echo unfreeze >> "$lc_fz_fx/calls" ;;
              *LIVE*) echo verify >> "$lc_fz_fx/calls"
                [[ "$lc_fz_guest" == parent-lag ]] && printf 'populated 1\nfrozen 0\n' > "$lc_fz_fx/cg/rhizo/apps/cgroup.events" ;;
              *FROZE*) echo freeze >> "$lc_fz_fx/calls" ;;
            esac
            body=${body//\/sys\/fs\/cgroup/$lc_fz_fx/cg}; body=${body//\/proc\//$lc_fz_fx/proc/}
            PATH="$lc_fz_fx/bin:$PATH" eval "$body"; rc=$? ;;
          *) return 255 ;;
        esac
        lc_fz_kernel
        return "$rc"
      }
      lc_assert_clipboard.frozen-source >/dev/null 2>"$lc_fz_fx/err"
      echo "RC=$? FAILED=$FAILED $(tr '\n' ' ' < "$lc_fz_fx/calls")"
    )
  }
  lc_fz_unfrozen() {
    [[ "$(find "$lc_fz_fx/cg" -name cgroup.freeze -exec grep -l '^1$' {} + | sed "s|^$lc_fz_fx/cg/||")" == rhizo/apps/uid_10099/pid_500/cgroup.freeze ]]
  }
  lc_fz_bad=""
  lc_fz_out=$(lc_fz_run "")
  [[ "$lc_fz_out" == "RC=0 FAILED=0 current focus clip-write pkill carrier freeze verify paste unfreeze restart " ]] && lc_fz_unfrozen \
    || lc_fz_bad+=" wlbridge gone: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want current focus clip-write pkill carrier freeze verify paste unfreeze restart, a pass and every freeze but stock's undone;"
  lc_fz_out=$(lc_fz_run " 5151 Z    rhizo-wlbridge  [rhizo-wlbridge] <defunct>")
  [[ "$lc_fz_out" == "RC=0 FAILED=0 current focus clip-write pkill carrier freeze verify paste unfreeze restart " ]] \
    || lc_fz_bad+=" wlbridge a zombie: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want the zombie read as gone and a pass;"
  lc_fz_out=$(lc_fz_run PSFAIL)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus clip-write pkill restart " ]] && grep -qF "was not gone after its pkill (<the read never finished>)" "$lc_fz_fx/err" \
    || lc_fz_bad+=" ps failed: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming the unfinished read, no freeze or paste;"
  lc_fz_out=$(lc_fz_run " 5151 S    rhizo-wlbridge  /usr/lib/rhizo/deskbridge/rhizo-wlbridge --caps clipboard")
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus clip-write pkill restart " ]] && grep -qF "rhizo-wlbridge was not gone after its pkill (5151" "$lc_fz_fx/err" \
    || lc_fz_bad+=" wlbridge survived: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming it, no freeze or paste, and the bridge restarted;"
  lc_fz_out=$(lc_fz_run "" down)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current " ]] && grep -qF "the bridge was not up for the app's clip to cross: no android app authenticated" "$lc_fz_fx/err" \
    || lc_fz_bad+=" bridge still reconnecting: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming it before the app writes its clip;"
  lc_fz_out=$(lc_fz_run "" up none)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus " ]] && grep -qF "no Rhizo window took focus for the app's copy: no Rhizo window is mapped" "$lc_fz_fx/err" \
    || lc_fz_bad+=" no Rhizo window to focus: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming it before the app writes its clip;"
  lc_fz_out=$(lc_fz_run "" up ok two-composers)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus clip-write pkill carrier freeze restart " ]] && grep -qF "ERR 2 rhizo-composer processes in " "$lc_fz_fx/err" && lc_fz_unfrozen \
    || lc_fz_bad+=" two composers: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming both, nothing frozen and no paste;"
  lc_fz_out=$(lc_fz_run "" up ok parent-lag)
  [[ "$lc_fz_out" == "RC=0 FAILED=0 current focus clip-write pkill carrier freeze verify paste unfreeze restart " ]] && lc_fz_unfrozen \
    || lc_fz_bad+=" a frozen parent whose own cgroup.events lags its children: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a pass read off each process's own cgroup;"
  lc_fz_out=$(lc_fz_run "" up ok live-beside)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus clip-write pkill carrier freeze verify unfreeze restart " ]] && grep -qF "LIVE 202 " "$lc_fz_fx/err" && lc_fz_unfrozen \
    || lc_fz_bad+=" a process live beside the composer: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming LIVE 202, no paste, and every freeze undone;"
  lc_fz_out=$(lc_fz_run "" up ok unlisted-beside)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus clip-write pkill carrier freeze verify unfreeze restart " ]] && grep -qF "ERR could not list " "$lc_fz_fx/err" && lc_fz_unfrozen \
    || lc_fz_bad+=" a cgroup beside the composer whose processes do not list: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming the unread cgroup.procs, no paste, and every freeze undone;"
  lc_fz_out=$(lc_fz_run "" up ok mute)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus clip-write pkill carrier freeze verify paste unfreeze restart " ]] && grep -qF "with every Android process but the composer (pid 200) frozen (the composer's own copy did not answer)" "$lc_fz_fx/err" && lc_fz_unfrozen \
    || lc_fz_bad+=" a composer that never answers: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming it and every freeze undone;"
  lc_fz_out=$(lc_fz_run "" up ok ok already)
  [[ "$lc_fz_out" == "RC=0 FAILED=0 current focus clip-write pkill carrier freeze verify paste unfreeze restart " ]] \
    || lc_fz_bad+=" gnome, the composer already the carrier: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a pass;"
  lc_fz_out=$(lc_fz_run "" up ok ok silent)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus clip-write pkill carrier restart " ]] && grep -qF "rhizo-deskd logged no clip carrier line" "$lc_fz_fx/err" \
    || lc_fz_bad+=" deskd silent on its wlbridge's exit: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming it, no freeze;"
  lc_fz_out=$(lc_fz_run "" up ok ok unacked)
  [[ "$lc_fz_out" == "RC=1 FAILED=1 current focus clip-write pkill carrier restart " ]] && grep -qF "the composer never acknowledged the clip rhizo-deskd handed it" "$lc_fz_fx/err" \
    || lc_fz_bad+=" a handed clip the composer never acknowledged: '$lc_fz_out' $(grep FAIL "$lc_fz_fx/err" | head -1), want a fail naming it, no freeze;"
  if [[ -z "$lc_fz_bad" ]]; then
    ok "1zr: clipboard.frozen-source writes the app's clip only over a bridge authenticated to the running deskd and with a Rhizo window focused (failing by name before it otherwise), pastes only once rhizo-deskd's wlbridge is gone (a zombie counting as gone) and every Android process but the composer reads frozen in its own cgroup (a parent whose count lags passing), leaves a stock-frozen app frozen, undoes every freeze, fails by name when the wlbridge survives its pkill, on two composers, a process live beside it, a cgroup beside it whose processes do not list and a composer that never answers, freezes on sway only once the composer acknowledged the clip rhizo-deskd handed it after its wlbridge exited (failing by name when deskd says nothing or the composer never acks), and restarts the bridge on every path"
  else
    bad "1zr:$lc_fz_bad"
  fi
  rm -rf "$lc_fz_fx"
  unset -f lc_fz_run lc_fz_cgmk lc_fz_kernel lc_fz_unfrozen
  unset lc_fz_fx lc_fz_bad lc_fz_out

  lc_ns_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_ns_fx/bin" && printf '#!/bin/sh\nexit 0\n' > "$lc_ns_fx/bin/scp" && chmod +x "$lc_ns_fx/bin/scp"
  lc_ns_out=$( (
    set -o pipefail
    RHIZO_DESKTOP_PROFILE=sway NOTIF_REC=/tmp/rhizo-lifecycle-notif.jsonl NOTIF_FIFO=/tmp/rhizo-lifecycle-notify.fifo
    SSH_OPTS=() SSH_PORT=0 SSH_TARGET=root@127.0.0.1 PATH="$lc_ns_fx/bin:$PATH"
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
    gcmd_root() { return 0; }
    wait_guest() { return 0; }
    ssh_vm() { echo 'unix:path=/tmp/dbus-sink,guid=1'; }
    gcmd_user() {
      case "$1" in
        *pgrep*) [[ -e "$lc_ns_fx/started" ]] && echo 4242; return 0 ;;
        *"rm -f $NOTIF_FIFO $NOTIF_REC"*)
          rm -f "$lc_ns_fx/rec"; touch "$lc_ns_fx/started"
          grep -qxF ": > $NOTIF_REC" <<<"$1" && : > "$lc_ns_fx/rec"
          return 0 ;;
        *"cat $NOTIF_REC"*) cat "$lc_ns_fx/rec" 2>/dev/null ;;
      esac
    }
    desk_notifications list; echo "RC=$?"
  ) 2>/dev/null )
  if [[ "$lc_ns_out" == "RC=0" ]]; then
    ok "1zy: sway's desk_notifications list, the first call, starts the sink and lists nothing with rc 0, before any notification has written the sink's record"
  else
    bad "1zy: sway's first desk_notifications list, before any notification, read '$(tr '\n' ' ' <<<"$lc_ns_out")', want RC=0 and no records"
  fi
  rm -rf "$lc_ns_fx"
  unset lc_ns_fx lc_ns_out

  lc_dd_fx=$(mktemp -d) || exit 1
  lc_dd_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 lc_dd_id="$1" lc_dd_base="${2:-ok}"
      rm -f "$lc_dd_fx"/*.txt; echo 0 > "$lc_dd_fx/reads"; echo 1000 > "$lc_dd_fx/now"
      printf 'display added id=2 port=2\ndrop id=2 port=2 mime=text/plain path=/data/rhizo_control/drop-2-77-1-0 x=50 y=50\n' > "$lc_dd_fx/control.out"
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_dd_fx/now"); echo $(( n + 1 )) > "$lc_dd_fx/now"; echo "$n"
      }
      sleep() { :; }
      nonce() { echo 5eed; }
      st() { printf '%s' "$1"; }
      desktop_activate_display_window() { return 0; }
      desktop_mapped_window_rect() { echo "0 0 100 100"; }
      desk_dnd() {
        [[ "$1" == drop ]] && echo "drop id=$lc_dd_id port=$lc_dd_id mime=text/plain path=/data/rhizo_control/drop-$lc_dd_id-88-2-0 x=50 y=50" >> "$lc_dd_fx/control.out"
        return 0
      }
      logcat_since_marker() { echo '09-26 08:00:00.000'; }
      android_sh() { return 0; }
      ssh_vm() { case "${*: -1}" in *'stat -c%s /var/log/rhizo/rhizo-deskd.log'*) echo 0 ;; esac; return 0; }
      gcmd_user() { return 0; }
      probe_cmd() { return 97; }
      _ssh_vm_out() {
        local n; n=$(( $(<"$lc_dd_fx/reads") + 1 )); echo "$n" > "$lc_dd_fx/reads"
        if (( n == 1 )); then
          case "$lc_dd_base" in
            empty) return 124 ;;
            cut) printf '3'; return 124 ;;
          esac
        fi
        local cmd="${*: -1}"
        cmd=${cmd#nsenter -a -t 4242 -- /system/bin/toybox }
        cmd=${cmd//\/data\/rhizo_control\/control.out/$lc_dd_fx/control.out}
        eval "command $cmd" | sed "s#$lc_dd_fx/control.out#/data/rhizo_control/control.out#"
      }
      rhizo_ctl_out() {
        local n; n=$(( $(<"$lc_dd_fx/reads") + 1 )); echo "$n" > "$lc_dd_fx/reads"
        (( n == 1 )) && [[ "$lc_dd_base" != ok ]] && return 0
        cat "$lc_dd_fx/control.out"
      }
      app_wait_token() { echo "RHIZO_DROP mime=text/plain b64=$(printf 'rhizo-drop-5eed' | base64 -w0)"; }
      desktop_assert_dnd_drop_onto_app 4242 2 "$lc_dd_fx" >/dev/null 2>"$lc_dd_fx/err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_dd_bad=""
  lc_dd_out=$(lc_dd_run 2)
  [[ "$lc_dd_out" == "RC=0 FAILED=0" ]] \
    || lc_dd_bad+=" a new drop on display 2: '$lc_dd_out' $(grep FAIL "$lc_dd_fx/err" | head -1), want a pass;"
  lc_dd_out=$(lc_dd_run 1)
  [[ "$lc_dd_out" == "RC=1 FAILED=1" ]] && grep -qF "never delivered a drop to display 2" "$lc_dd_fx/err" \
    || lc_dd_bad+=" a new drop on display 1 with the target on 2: '$lc_dd_out' $(grep FAIL "$lc_dd_fx/err" | head -1), want a fail naming display 2;"
  for lc_dd_f in drop-d2-control-out drop-d2-dnd-deskd drop-d2-dnd-logcat drop-d2-dnd-outputs drop-d2-dnd-tree drop-d2-dnd-clip-out drop-d2-dnd-sway-log; do
    [[ -s "$lc_dd_fx/$lc_dd_f.txt" ]] || lc_dd_bad+=" the failed drop left no $lc_dd_f.txt;"
  done
  [[ "$(cat "$lc_dd_fx/drop-d2-dnd-deskd.txt" 2>/dev/null)" == '<none>' ]] \
    || lc_dd_bad+=" drop-d2-dnd-deskd.txt from an empty read is not an explicit <none>;"
  for lc_dd_f in empty cut; do
    lc_dd_out=$(lc_dd_run 1 "$lc_dd_f")
    [[ "$lc_dd_out" == "RC=1 FAILED=1" ]] && grep -qF "control.out's line count did not read before the drop" "$lc_dd_fx/err" \
      || lc_dd_bad+=" a $lc_dd_f baseline read, an earlier leg's drop on display 2 and this leg's on 1: '$lc_dd_out' $(grep -E 'FAIL|PASS' "$lc_dd_fx/err" | head -1), want a fail naming the unread baseline;"
    [[ -s "$lc_dd_fx/drop-d2-control-out.txt" ]] || lc_dd_bad+=" the $lc_dd_f-baseline return left no drop-d2-control-out.txt;"
  done
  if [[ -z "$lc_dd_bad" ]]; then
    ok "1zz: the drop leg passes on a drop line control.out gained for its own display, and fails by name when only another display's drop arrives or its baseline read was empty or cut short"
  else
    bad "1zz:$lc_dd_bad"
  fi
  rm -rf "$lc_dd_fx"
  unset -f lc_dd_run
  unset lc_dd_fx lc_dd_bad lc_dd_out lc_dd_f

  lc_pu_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_pu_fx/bin"
  cat > "$lc_pu_fx/bin/systemctl" <<'STUB'
#!/bin/bash
m=$LC_PU_MODE s=$LC_PU_STATE
prop() { [ -e "$s/$1.$2" ] && cat "$s/$1.$2" || echo "$3"; }
has_upower() { [ "$m" != upower-absent ]; }
case "$1" in
  list-units)
    [ "$m" = list-fail ] && exit 1
    [ "$m" = no-pu-units ] || [ "$m" = no-uuidd ] || echo "uuidd.service loaded inactive dead uuidd"
    if [ "$m" != no-pu-units ] && has_upower; then echo "upower.service loaded active running upower"; fi
    echo "ssh.service loaded active running ssh" ;;
  cat)
    case "$2" in
      uuidd.service|upower.service) printf '# /usr/lib/systemd/system/%s\n[Service]\nPrivateUsers=yes\n' "$2" ;;
      *) printf '# /usr/lib/systemd/system/%s\n[Service]\nExecStart=/usr/sbin/sshd\n' "$2" ;;
    esac ;;
  show)
    u=${*: -1}
    case "$3" in
      DropInPaths) [ "$m" = dropin-unread ] && echo /usr/lib/systemd/system/service.d/10-timeout-abort.conf \
                     || echo /usr/lib/systemd/system/service.d/10-timeout-abort.conf /usr/lib/systemd/system/service.d/50-rhizo-private-users.conf ;;
      LoadState) if [ "$u" != upower.service ] || has_upower; then echo loaded; else echo not-found; fi ;;
      InvocationID) prop "$u" inv "" ;;
      Result) prop "$u" result success ;;
      ActiveState) prop "$u" active inactive ;;
      ExecMainStatus) prop "$u" status 0 ;;
    esac ;;
  is-active) prop "$2" active inactive ;;
  start)
    u=$2
    [ "$m" = start-noop ] && exit 0
    echo "$u-$(date +%N)" > "$s/$u.inv"
    if [ "$m" = today ] || { [ "$u" = upower.service ] && [ "$m" = upower-failed ]; } \
       || { [ "$u" = uuidd.service ] && [ "$m" = uuidd-failed ]; }; then
      echo exit-code > "$s/$u.result"; echo failed > "$s/$u.active"; echo 217 > "$s/$u.status"; exit 1
    fi
    echo success > "$s/$u.result"; echo active > "$s/$u.active"; echo 0 > "$s/$u.status" ;;
  *) echo "stub systemctl: unexpected $*" >&2; exit 2 ;;
esac
STUB
  cat > "$lc_pu_fx/bin/systemd-run" <<'STUB'
#!/bin/bash
m=$LC_PU_MODE
if [ "$1" = --user ]; then
  case "$m" in
    *nobus) echo 'Failed to connect to bus: No such file or directory' >&2; exit 1 ;;
    user-hostns) echo '         0          0 4294967295' ;;
    user-runfail) exit 217 ;; user-emptymap) ;;
    *) echo '      1000       1000          1' ;;
  esac
  exit 0
fi
case "$m" in
  today|runfail) exit 217 ;; emptymap) ;;
  private-map) echo '         0          0          1' ;;
  *) echo '         0          0 4294967295' ;;
esac
STUB
  cat > "$lc_pu_fx/bin/dpkg-query" <<'STUB'
#!/bin/bash
[ "$LC_PU_MODE" = dropin-foreign ] && exit 1
echo "rhizo: ${*: -1}"
STUB
  cat > "$lc_pu_fx/bin/pacman" <<'STUB'
#!/bin/bash
[ "$LC_PU_MODE" = dropin-foreign ] && exit 1
echo rhizo
STUB
  cat > "$lc_pu_fx/bin/cat" <<'STUB'
#!/bin/bash
case "$1" in
  /sys/fs/selinux/enforce) [ "$LC_PU_MODE" = notenforcing ] && echo 0 || echo 1 ;;
  */service.d/50-rhizo-private-users.conf)
    case "$LC_PU_MODE" in today|dropin-absent) exit 1 ;; esac
    printf '# the neverallow\n[Service]\n'
    [ "$LC_PU_MODE" = dropin-on ] && echo PrivateUsers=yes || echo PrivateUsers=no ;;
  *) exec /bin/cat "$@" ;;
esac
STUB
  chmod +x "$lc_pu_fx/bin/"*
  lc_pu_run() {
    (
      FAILED=0 lc_pu_mode="$2"
      echo 0 > "$lc_pu_fx/clock"
      date() { local t; t=$(( $(cat "$lc_pu_fx/clock") + 20 )); echo "$t" > "$lc_pu_fx/clock"; echo "$t"; }
      sleep() { :; }
      desk_user_sh() {
        if [[ "${*: -1}" == "$LC_PRIVATE_USERS_USER_CMD" ]]; then
          : > "$lc_pu_fx/user-ran"
          [[ "$lc_pu_mode" == user-cut ]] && { echo 'Connection closed'; return 255; }
          PATH="$lc_pu_fx/bin:$PATH" LC_PU_MODE="${lc_pu_mode#server-}" bash -c "${*: -1}"
          return
        fi
        case "${*: -1}" in
          *'systemd-run --user'*) [[ "$lc_pu_mode" == startfail ]] && { echo 'Failed to connect to bus'; echo rc=1; } || echo rc=0 ;;
          *'systemctl --user stop'*) : > "$lc_pu_fx/stopped" ;;
          *rhizo-probe-client*)
            case "$lc_pu_mode" in
              user-served) sed -n "s/.*'echo \(rhizo-lc-probe-[0-9a-f]*\)'.*/\1/p" <<<"${*: -1}"; echo rc=0 ;;
              user-cut) echo 'connect: Permission denied' ;;
              user-peercred) echo 'RHIZO_PROBE_REFUSED: peer uid 1000 is not root'
                             echo 'RHIZO_PROBE_NO_TRAILER: connection closed without a completion marker'; echo rc=98 ;;
              user-hangup) echo 'RHIZO_PROBE_NO_TRAILER: connection closed without a completion marker'; echo rc=98 ;;
              user-noexec) echo '/bin/bash: line 1: /usr/lib/rhizo/rhizo-probe-client: Permission denied'; echo rc=126 ;;
              *) echo 'RHIZO_PROBE_UNREACHABLE: Permission denied'; echo rc=97 ;;
            esac ;;
        esac
      }
      ssh_vm() {
        local c="${*: -1}" st="$lc_pu_fx/state"
        if [[ "$c" == "$LC_PRIVATE_USERS_CMD" ]]; then
          rm -rf "$st"; mkdir -p "$st"
          case "${lc_pu_mode#server-}" in
            today|upower-failed|upower-boot-failed)
              echo boot > "$st/upower.service.inv"; echo exit-code > "$st/upower.service.result"
              echo failed > "$st/upower.service.active"; echo 217 > "$st/upower.service.status" ;;
            upower-idle|upower-absent) ;;
            *) echo boot > "$st/upower.service.inv"; echo active > "$st/upower.service.active" ;;
          esac
          PATH="$lc_pu_fx/bin:$PATH" LC_PU_MODE="${lc_pu_mode#server-}" LC_PU_STATE="$st" bash -c "$c"
          return
        fi
        case "$c" in
          *'journalctl _SYSTEMD_USER_UNIT='*)
            local unit; unit=$(sed -n 's/.*_SYSTEMD_USER_UNIT=\([^ ]*\)\.service.*/\1/p' <<<"$c")
            if [[ "$lc_pu_mode" != noentry ]]; then
              printf '__CURSOR=s=1\n_UID=1000\n'
              [[ "$lc_pu_mode" == noinv ]] || printf '_SYSTEMD_INVOCATION_ID=%032d\n' 7
              printf '_SYSTEMD_USER_UNIT=%s.service\nMESSAGE=%s\n\n' "$unit" "$unit"
            fi
            echo DONE ;;
          *rhizo-probe-client*)
            [[ "$lc_pu_mode" == root-dead ]] || sed -n "s/.*'echo \(rhizo-lc-probe-[0-9a-f]*\)'.*/\1/p" <<<"$c"
            echo rc=0 ;;
          *) return 255 ;;
        esac
      }
      local prof=gnome; [[ "$lc_pu_mode" == server-* ]] && prof=server
      [[ "$lc_pu_mode" == noprofile ]] && prof=""
      "lc_assert_$1" $prof >/dev/null 2>"$lc_pu_fx/err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_pu_bad=""
  for lc_pu_case in "host.private-users-services|good|" "host.private-users-services|upower-absent|" \
                    "host.private-users-services|upower-idle|" \
                    "host.private-users-services|today|(a) a PrivateUsers=yes transient system service did not run in the host's namespace (run_rc=217" \
                    "host.private-users-services|today|(b) stock PrivateUsers= units that did not run this boot (unit:invocation:result:state:status): uuidd.service:" \
                    "host.private-users-services|today|(c) /usr/lib/systemd/system/service.d/50-rhizo-private-users.conf is absent" \
                    "host.private-users-services|runfail|(a) a PrivateUsers=yes transient system service did not run in the host's namespace (run_rc=217, uid_map '<none>'" \
                    "host.private-users-services|emptymap|(a) a PrivateUsers=yes transient system service did not run in the host's namespace (run_rc=0, uid_map '<none>'" \
                    "host.private-users-services|private-map|(run_rc=0, uid_map '0 0 1|', want '0 0 4294967295|')" \
                    "host.private-users-services|list-fail|(b) systemctl list-units did not answer (pu_list_rc=1)" \
                    "host.private-users-services|list-fail|(b) no loaded system unit declaring PrivateUsers= was checked (pu_checked=0)" \
                    "host.private-users-services|no-pu-units|(b) no loaded system unit declaring PrivateUsers= was checked (pu_checked=0)" \
                    "host.private-users-services|no-uuidd|(b) uuidd.service was not among the units checked" \
                    "host.private-users-services|uuidd-failed|:exit-code:failed:217" \
                    "host.private-users-services|start-noop|(b) stock PrivateUsers= units that did not run this boot (unit:invocation:result:state:status): uuidd.service::success:inactive:0" \
                    "host.private-users-services|upower-failed|(b) upower.service reads upower_boot=failed after boot and upower=failed" \
                    "host.private-users-services|upower-boot-failed|(b) upower.service reads upower_boot=failed after boot and upower=active" \
                    "host.private-users-services|dropin-absent|(c) /usr/lib/systemd/system/service.d/50-rhizo-private-users.conf is absent" \
                    "host.private-users-services|dropin-foreign|is not rhizo's packaged file (dropin_owner=)" \
                    "host.private-users-services|dropin-on|sets no [Service] PrivateUsers=no (dropin_off=0)" \
                    "host.private-users-services|dropin-unread|among systemd-journald.service's DropInPaths (dropin_read=0)" \
                    "host.private-users-services|user-hostns|(d) a desktop user's PrivateUsers=yes unit (urun_rc=0) read uid_map '0 0 4294967295|', not a private user namespace" \
                    "host.private-users-services|user-runfail|(d) a desktop user's PrivateUsers=yes unit (urun_rc=217) read uid_map '<none>'" \
                    "host.private-users-services|user-emptymap|(d) a desktop user's PrivateUsers=yes unit (urun_rc=0) read uid_map '<none>'" \
                    "host.private-users-services|user-cut|(d) incomplete desktop-user read (no DONE token)" \
                    "host.private-users-services|notenforcing|the host is not enforcing (enforce=0)" \
                    "host.private-users-services|server-nobus|" \
                    "host.private-users-services|server-today|(c) /usr/lib/systemd/system/service.d/50-rhizo-private-users.conf is absent" \
                    "host.private-users-services|user-nobus|(d) a desktop user's PrivateUsers=yes unit (urun_rc=1) read uid_map 'Failed to connect to bus: No such file or directory|'" \
                    "host.private-users-services|noprofile|host.private-users-services: no cycle profile argument" \
                    "host.journal-user-units|good|" \
                    "host.journal-user-units|noinv|carries no _SYSTEMD_INVOCATION_ID" \
                    "host.journal-user-units|noentry|the journal held no entry of user unit" \
                    "host.journal-user-units|startfail|could not start a user unit to log from" \
                    "host.probe-root-only|good|" \
                    "host.probe-root-only|root-dead|root's own probe of the sandbox did not answer" \
                    "host.probe-root-only|user-served|the desktop user ran a command in Android through rhizo-probed" \
                    "host.probe-root-only|user-cut|the desktop user's probe attempt never finished" \
                    "host.probe-root-only|user-peercred|" \
                    "host.probe-root-only|user-hangup|neither by the socket's DAC nor by rhizo-probed's refusal" \
                    "host.probe-root-only|user-noexec|neither by the socket's DAC nor by rhizo-probed's refusal"; do
    IFS='|' read -r lc_pu_claim lc_pu_mode lc_pu_want <<<"$lc_pu_case"
    rm -f "$lc_pu_fx/stopped" "$lc_pu_fx/user-ran"
    lc_pu_out=$(lc_pu_run "$lc_pu_claim" "$lc_pu_mode")
    if [[ -z "$lc_pu_want" ]]; then
      [[ "$lc_pu_out" == "RC=0 FAILED=0" ]] || lc_pu_bad+=" $lc_pu_claim $lc_pu_mode: '$lc_pu_out' $(grep FAIL "$lc_pu_fx/err" | head -1), want a pass;"
    else
      [[ "$lc_pu_out" == "RC=1 FAILED=1" ]] && grep -qF -- "$lc_pu_want" "$lc_pu_fx/err" \
        || lc_pu_bad+=" $lc_pu_claim $lc_pu_mode: '$lc_pu_out' $(grep FAIL "$lc_pu_fx/err" | head -1), want a fail naming '$lc_pu_want';"
    fi
    [[ "$lc_pu_mode" != server-* || ! -e "$lc_pu_fx/user-ran" ]] \
      || lc_pu_bad+=" $lc_pu_claim $lc_pu_mode: ran a desktop user's unit on server, whose profile has no user manager;"
    [[ "$lc_pu_claim" != host.journal-user-units || "$lc_pu_mode" == startfail || -e "$lc_pu_fx/stopped" ]] \
      || lc_pu_bad+=" $lc_pu_claim $lc_pu_mode: the user unit it started was never stopped;"
  done
  if [[ -z "$lc_pu_bad" ]]; then
    ok "1zz5: host.private-users-services, running its own guest scripts on stub commands, passes on the opt-out's host map, uuidd and upower started this boot and succeeding, upower idle or absent, rhizo's drop-in read and a desktop user's private uid_map, and fails by name on today's 217/USER host for each of (a), (b) and (c), on a private system map, an unanswered or empty unit list, no uuidd, a unit that failed or never started, each drop-in defect and a desktop user's host map, failed or empty run, cut read or missing bus on gnome, while server skips (d) by profile without running a user unit and no profile fails; host.journal-user-units passes on an entry with an invocation id, fails by name on one without, on no entry and on no unit, and stops the unit it started; host.probe-root-only passes only when root's probe answers and the desktop user's is refused by the socket's DAC or rhizo-probed's own refusal, and fails one that reached neither"
  else
    bad "1zz5:$lc_pu_bad"
  fi
  rm -rf "$lc_pu_fx"
  unset -f lc_pu_run
  unset lc_pu_fx lc_pu_bad lc_pu_out lc_pu_case lc_pu_claim lc_pu_mode lc_pu_want

  lc_km_fx=$(mktemp -d) || exit 1
  lc_km_run() {
    (
      FAILED=0 EV="$lc_km_fx/ev" lc_km_mode="$1"
      mkdir -p "$EV"; : > "$lc_km_fx/control.out"; echo 0 > "$lc_km_fx/shows"; : > "$lc_km_fx/layout"; : > "$lc_km_fx/digests"
      echo 0 > "$lc_km_fx/clock"
      date() { local t; t=$(( $(cat "$lc_km_fx/clock") + 20 )); echo "$t" > "$lc_km_fx/clock"; echo "$t"; }
      sleep() { :; }
      desk_keyboard_layout() {
        echo "$1" > "$lc_km_fx/layout"
        local d; d=$(( ${#1} * 1000 + $(wc -l < "$lc_km_fx/control.out") ))
        [[ "$lc_km_mode" != same ]] || d=4242
        echo "$d $1" >> "$lc_km_fx/digests"
        echo "keymap ready bytes=48000 digest=$d path=/data/rhizo_control/keymap-$d" >> "$lc_km_fx/control.out"
        case "$lc_km_mode" in
          no-table) ;;
          earlier) echo "keymap table-loaded digest=12 entries=90" >> "$lc_km_fx/control.out" ;;
          *) echo "keymap table-loaded digest=$d entries=90" >> "$lc_km_fx/control.out" ;;
        esac
      }
      ssh_vm() {
        local c="${*: -1}"
        case "$c" in
          *'systemctl show -p ActiveState'*)
            local n; n=$(( $(cat "$lc_km_fx/shows") + 1 )); echo "$n" > "$lc_km_fx/shows"
            if [[ "$lc_km_mode" == inactive ]]; then printf 'ActiveState=failed\nResult=exit-code\nInvocationID=\nExecMainStatus=1\nNRestarts=0\n'
            elif [[ "$lc_km_mode" == restarted && "$n" == 2 ]]; then printf 'ActiveState=active\nInvocationID=%032d\n' 2
            else printf 'ActiveState=active\nInvocationID=%032d\n' 1; fi
            echo '--- /var/log/rhizo/rhizo-keymapd.log'; echo DONE ;;
          "stat -c%s $LC_KM_CONTROL_OUT") stat -c%s "$lc_km_fx/control.out" ;;
          *keymapd.py*)
            local kd kl; kd=$(sed -n 's/.*keymap-\([0-9]*\).*/\1/p' <<<"$c"); kl=$(awk -v d="$kd" '$1 == d {l = $2} END {print l}' "$lc_km_fx/digests")
            if [[ "$lc_km_mode" == fnv-mismatch ]]; then echo "fnv=$(( kd + 1 ))"; else echo "fnv=$kd"; fi
            if [[ "$kl" == fr && "$lc_km_mode" != us-chars ]]; then echo q=a; else echo q=q; fi
            echo DONE ;;
          "tail -c +"*" $LC_KM_CONTROL_OUT 2>/dev/null") bash -c "${c//$LC_KM_CONTROL_OUT/$lc_km_fx/control.out}" ;;
          *) return 255 ;;
        esac
      }
      lc_assert_desktop.keymap-follows-host >/dev/null 2>"$lc_km_fx/err"
      echo "RC=$? FAILED=$FAILED LAYOUT=$(cat "$lc_km_fx/layout")"
    )
  }
  lc_km_bad=""
  lc_km_out=$(lc_km_run good)
  [[ "$lc_km_out" == "RC=0 FAILED=0 LAYOUT=us" ]] && grep -qF 'fr: keymap table-loaded digest=' "$lc_km_fx/err" \
    || lc_km_bad+=" good: '$lc_km_out' $(grep FAIL "$lc_km_fx/err" | head -1), want a pass naming each loaded table;"
  for lc_km_case in "inactive|rhizo-keymapd.service is 'failed'|" \
                    "no-table|after the host layout went to fr, control.out past byte 0 logged no 'keymap table-loaded'|us" \
                    "earlier|after the host layout went to fr, control.out past byte 0 logged no 'keymap table-loaded'|us" \
                    "restarted|after the layout changes, was active invocation|us" \
                    "same|the composer loaded the same keymap digest 4242 after the host went to fr and after it went back to us|us" \
                    "us-chars|after the host went to fr, the keymap the composer loaded (digest 2000) resolves KEY_Q to 'q', not 'a'|us" \
                    "fnv-mismatch|not the composer's keymap digest|us"; do
    IFS='|' read -r lc_km_mode lc_km_want lc_km_layout <<<"$lc_km_case"
    lc_km_out=$(lc_km_run "$lc_km_mode")
    [[ "$lc_km_out" == "RC=1 FAILED=1 LAYOUT=$lc_km_layout" ]] && grep -qF "$lc_km_want" "$lc_km_fx/err" \
      || lc_km_bad+=" $lc_km_mode: '$lc_km_out' $(grep FAIL "$lc_km_fx/err" | head -1), want a fail naming '$lc_km_want' with the host left on '${lc_km_layout:-<untouched>}';"
    grep -q '^ActiveState=' "$lc_km_fx/ev/keymapd.txt" 2>/dev/null \
      || lc_km_bad+=" $lc_km_mode: \$EV/keymapd.txt does not hold the daemon's state;"
  done
  if [[ -z "$lc_km_bad" ]]; then
    ok "1zz4: desktop.keymap-follows-host passes only when the composer loads the table for each keymap announced after a layout change, keymapd's resolver gives that file KEY_Q = a on fr and q on us, and keymapd stays one invocation, fails by name on the wrong character or another file, fails by name on an inactive daemon, a missing or earlier table, one digest for both layouts and a restart, puts the host back on us, and saves keymapd's state every time"
  else
    bad "1zz4:$lc_km_bad"
  fi
  rm -rf "$lc_km_fx"
  unset -f lc_km_run
  unset lc_km_fx lc_km_bad lc_km_out lc_km_case lc_km_mode lc_km_want lc_km_layout

  lc_hs_bad=""
  lc_hs_body=$(declare -f lifecycle_run_cycle)
  for lc_hs_phase in remove purge; do
    awk -v r="reboot_and_wait \"cycle-\$profile post-$lc_hs_phase\"" -v t="take_snapshot \"cycle-\$profile after-$lc_hs_phase\"" \
      'index($0, r) { rb = NR } index($0, t) { ts = NR } /lc_host_settle / && rb && !ts { s = NR } END { exit !(rb && ts && s && rb < s && s < ts) }' <<<"$lc_hs_body" \
      || lc_hs_bad+=" the $lc_hs_phase census is not taken after lc_host_settle, between the reboot and the snapshot;"
  done
  lc_hs_run() {
    (
      lc_hs_state="$1" lc_hs_dpkg="$2"
      ssh_vm() {
        case "${*: -1}" in
          *'is-system-running --wait'*) [[ -z "$lc_hs_state" ]] || echo "$lc_hs_state"; echo "RC=$([[ "$lc_hs_state" == running ]] && echo 0 || echo 1)" ;;
          *'list-jobs'*) printf '%s\n' 'JOB UNIT TYPE STATE' '812 rhizo-resync.service start running' '1 jobs listed.' ;;
          *'lock-frontend'*) echo '/var/lib/dpkg/lock-frontend: root 4242 F.... unattended-upgr' ;;
          *) return 255 ;;
        esac
      }
      wait_dpkg_free() { [[ "$lc_hs_dpkg" == free ]]; }
      lc_hs_why=$(lc_host_settle "7: after remove+reboot"); echo "RC=$? $lc_hs_why"
    )
  }
  for lc_hs_case in "running|free|RC=0 " "degraded|free|RC=0 " \
                    "starting|free|RC=1 7: after remove+reboot: systemctl is-system-running --wait read 'starting' (RC=1) within 300s, still queued: JOB UNIT TYPE STATE 812 rhizo-resync.service start running 1 jobs listed." \
                    "|free|RC=1 7: after remove+reboot: systemctl is-system-running --wait read '<nothing>' (RC=1) within 300s, still queued: JOB UNIT TYPE STATE 812 rhizo-resync.service start running 1 jobs listed." \
                    "running|held|RC=1 7: after remove+reboot: the dpkg lock was still held 300s after the boot finished (/var/lib/dpkg/lock-frontend: root 4242 F.... unattended-upgr)"; do
    IFS='|' read -r lc_hs_state lc_hs_dpkg lc_hs_want <<<"$lc_hs_case"
    lc_hs_out=$(lc_hs_run "$lc_hs_state" "$lc_hs_dpkg")
    [[ "$lc_hs_out" == "$lc_hs_want" ]] || lc_hs_bad+=" is-system-running '$lc_hs_state', dpkg $lc_hs_dpkg: got '$lc_hs_out', want '$lc_hs_want';"
  done
  if [[ -z "$lc_hs_bad" ]]; then
    ok "1zz3: the remove and purge censuses wait for the rebooted host's boot to finish and dpkg to free, and a boot or dpkg that never settles names the jobs or the lock holder"
  else
    bad "1zz3:$lc_hs_bad"
  fi
  unset -f lc_hs_run
  unset lc_hs_bad lc_hs_body lc_hs_phase lc_hs_case lc_hs_state lc_hs_dpkg lc_hs_want lc_hs_out

  lc_pb_fx=$(mktemp -d) || exit 1
  lc_pb_run() {
    (
      FAILED=0 lc_pb_bridge="${3:-up}"
      : > "$lc_pb_fx/calls"; echo 0 > "$lc_pb_fx/inv"; rm -f "$lc_pb_fx/restored"
      lc_save_policy_conf() { printf '[audio]\nout = yes\n'; }
      lc_arm_policy_restore() { :; }
      lc_restore_policy_conf() { echo restore >> "$lc_pb_fx/calls"; : > "$lc_pb_fx/restored"; }
      probe_ssh() { echo ABSENT; }
      probe_ssh_result() { echo ABSENT; }
      lc_procs_named() { :; }
      lc_idle_verdict() {
        if [[ -e "$lc_pb_fx/restored" ]]; then echo "started this run's own session count at 0 -- the 0 adb entries already in the conntrack table, phantom or real, are never counted"
        else echo "server.idle_stop_s=0 -- idle-stop is off, exiting"; fi
      }
      lc_inv_journal_line() { echo "policy.conf does not parse -- denying every optional capability"; }
      _lc_desktop_bridge_restart() {
        echo bridge-restart >> "$lc_pb_fx/calls"
        [[ "$lc_pb_bridge" == up ]] || { echo "rhizo-deskd logged no 'android app authenticated' past byte 7 within 60s of its token delivery"; return 1; }
      }
      sleep() { echo sleep >> "$lc_pb_fx/calls"; }
      ssh_vm() {
        case "${*: -1}" in
          *'restart rhizo-deskd.service'*) echo deskd-restart >> "$lc_pb_fx/calls"; echo DONE ;;
          *capabilities*) echo 1 ;;
          *'is-active rhizo-audiod'*) echo active ;;
          *'/run/rhizo-audio/audiod'*) echo UP ;;
          *'capability-allowed.sh audio.out'*) return 0 ;;
          *'capability-allowed.sh desktop.'*) return 1 ;;
          *InvocationID*) local n; n=$(( $(<"$lc_pb_fx/inv") + 1 )); echo "$n" > "$lc_pb_fx/inv"; printf '%032d\n' "$n" ;;
          *ConditionResult*) echo no ;;
          *) return 0 ;;
        esac
      }
      "lc_assert_$1" "$2" >/dev/null 2>"$lc_pb_fx/err"
      echo "RC=$? FAILED=$FAILED $(tr '\n' ' ' < "$lc_pb_fx/calls")"
    )
  }
  lc_pb_bad=""
  for lc_pb_p in gnome sway; do
    lc_pb_out=$(lc_pb_run policy.absent-is-defaults "$lc_pb_p")
    [[ "$lc_pb_out" == "RC=0 FAILED=0 bridge-restart restore bridge-restart " ]] \
      || lc_pb_bad+=" absent-is-defaults $lc_pb_p: '$lc_pb_out' $(grep FAIL "$lc_pb_fx/err" | head -1), want the bridge restarted and waited on under the defaults and after the restore, no sleep;"
    lc_pb_out=$(lc_pb_run policy.absent-is-defaults "$lc_pb_p" down)
    [[ "$lc_pb_out" == "RC=1 FAILED=2 bridge-restart restore bridge-restart " ]] && grep -qF "the bridge did not come back up over the restarted deskd: rhizo-deskd logged no 'android app authenticated'" "$lc_pb_fx/err" \
      || lc_pb_bad+=" absent-is-defaults $lc_pb_p, bridge down: '$lc_pb_out' $(grep FAIL "$lc_pb_fx/err" | head -1), want both legs failing by the bridge's own reason;"
    lc_pb_out=$(lc_pb_run policy.unparsable-denies-optional "$lc_pb_p")
    [[ "$lc_pb_out" == "RC=0 FAILED=0 deskd-restart restore bridge-restart " ]] \
      || lc_pb_bad+=" unparsable-denies-optional $lc_pb_p: '$lc_pb_out' $(grep FAIL "$lc_pb_fx/err" | head -1), want the withheld restart waited on to its job's end and the restore through the bridge restart, no sleep;"
    lc_pb_out=$(lc_pb_run policy.unparsable-denies-optional "$lc_pb_p" down)
    [[ "$lc_pb_out" == "RC=1 FAILED=1 deskd-restart restore bridge-restart " ]] && grep -qF "restored, the bridge did not come back up over the restarted deskd" "$lc_pb_fx/err" \
      || lc_pb_bad+=" unparsable-denies-optional $lc_pb_p, bridge down: '$lc_pb_out' $(grep FAIL "$lc_pb_fx/err" | head -1), want a fail naming the bridge after the restore;"
  done
  lc_pb_out=$(lc_pb_run policy.absent-is-defaults server)
  [[ "$lc_pb_out" == "RC=0 FAILED=0 restore " ]] \
    || lc_pb_bad+=" absent-is-defaults server: '$lc_pb_out' $(grep FAIL "$lc_pb_fx/err" | head -1), want no deskd restart on a host that masks it;"
  lc_pb_out=$(lc_pb_run policy.unparsable-denies-optional server)
  [[ "$lc_pb_out" == "RC=0 FAILED=0 restore " ]] \
    || lc_pb_bad+=" unparsable-denies-optional server: '$lc_pb_out' $(grep FAIL "$lc_pb_fx/err" | head -1), want no deskd restart on a host that masks it;"
  if [[ -z "$lc_pb_bad" ]]; then
    ok "1zz2: policy.absent-is-defaults and policy.unparsable-denies-optional put the bridge back through _lc_desktop_bridge_restart and fail by name when it stays down, wait the withheld deskd restart to its job's end with no sleep, and restart no deskd on a server host"
  else
    bad "1zz2:$lc_pb_bad"
  fi
  rm -rf "$lc_pb_fx"
  unset -f lc_pb_run
  unset lc_pb_fx lc_pb_bad lc_pb_out lc_pb_p

  lc_bc_fx=$(mktemp -d) || exit 1
  lc_bc_run() {
    (
      printf '%s\n' "$@" > "$lc_bc_fx/log"
      echo 0 > "$lc_bc_fx/clock"
      date() { local t; t=$(( $(cat "$lc_bc_fx/clock") + 20 )); echo "$t" > "$lc_bc_fx/clock"; echo "$t"; }
      sleep() { :; }
      desk_unit_await_active() { return 0; }
      desk_token_settled() { return 0; }
      ssh_vm() { local c="${*: -1}"; bash -c "${c//\/var\/log\/rhizo\/rhizo-deskd.log/$lc_bc_fx/log}"; }
      _lc_desktop_bridge_current 30 >/dev/null
      echo "RC=$?"
    )
  }
  lc_bc_bad=""
  [[ "$(lc_bc_run '[1] listening on 192.168.100.1:47100' '[2] android app authenticated')" == RC=0 ]] \
    || lc_bc_bad+=" an android app authenticated since the last start read as not current;"
  [[ "$(lc_bc_run '[1] listening on 192.168.100.1:47100' '[2] android app authenticated' '[3] android app disconnected: eof')" == RC=1 ]] \
    || lc_bc_bad+=" an android app that disconnected read as current;"
  [[ "$(lc_bc_run '[1] listening on 192.168.100.1:47100' '[2] android app authenticated' '[3] listening on 192.168.100.1:47100')" == RC=1 ]] \
    || lc_bc_bad+=" the previous deskd's authenticated android app read as current for the restarted one;"
  [[ "$(lc_bc_run '[1] listening on 192.168.100.1:47100' '[2] android app authenticated' '[3] android app disconnected: eof' '[4] android app authenticated')" == RC=0 ]] \
    || lc_bc_bad+=" an android app back after a disconnect read as not current;"
  [[ "$(lc_bc_run '[2] android app authenticated')" == RC=1 ]] \
    || lc_bc_bad+=" a log with no 'listening on' read as current;"
  lc_ou_run() {
    (
      FAILED=0 INIT=4242 LC_OU_START="$1" LC_OU_OFF="$2" LC_OU_RESTORE="$3" LC_OU_XDG="${4:-opened}" LC_OU_ANDROID="${5:-told}"
      echo on > "$lc_bc_fx/policy"; : > "$lc_bc_fx/deskd.log"; : > "$lc_bc_fx/views"; echo 0 > "$lc_bc_fx/restarts"
      : > "$lc_bc_fx/logcat"; : > "$lc_bc_fx/xdg"; : > "$lc_bc_fx/handler"
      echo 0 > "$lc_bc_fx/clock"
      date() { local t; t=$(( $(cat "$lc_bc_fx/clock") + 20 )); echo "$t" > "$lc_bc_fx/clock"; echo "$t"; }
      sleep() { :; }
      lc_need_guest() { return 0; }
      lc_unit_active() { return 0; }
      lc_read_capability() { [[ "$(cat "$lc_bc_fx/policy")" == on ]] && echo "True frozenset({'http', 'https'})" || echo "False frozenset()"; }
      lc_save_policy_conf() { return 0; }
      lc_arm_policy_restore() { return 0; }
      lc_restore_policy_conf() { echo on > "$lc_bc_fx/policy"; }
      lc_procs_named() { [[ "$1" != xdg-open ]] || cat "$lc_bc_fx/xdg"; }
      _lc_desktop_bridge_current() { [[ "$LC_OU_START" == up ]] || { echo "no android app authenticated since the last listening on"; return 1; }; }
      _lc_desktop_bridge_restart() {
        local n; n=$(( $(cat "$lc_bc_fx/restarts") + 1 )); echo "$n" > "$lc_bc_fx/restarts"
        (( n == 2 )) && [[ "$LC_OU_RESTORE" == down ]] && { echo "rhizo-deskd logged no 'android app authenticated'"; return 1; }
        return 0
      }
      android_sh() {
        [[ "$2" != logcat* ]] || { cat "$lc_bc_fx/logcat"; return 0; }
        local uri; uri=$(sed -n "s/.*-d '\([^']*\)'.*/\1/p" <<<"$2")
        echo "$uri" >> "$lc_bc_fx/views"
        if [[ "$(cat "$lc_bc_fx/policy")" == on ]]; then
          echo "[1] open android -> host: $uri" >> "$lc_bc_fx/deskd.log"
          case "$LC_OU_XDG" in
            opened) echo "[1] xdg-open opened $uri" >> "$lc_bc_fx/deskd.log" ;;
            failed) echo "[1] xdg-open failed for $uri: rc=3 xdg-open: no method available for opening '$uri'" >> "$lc_bc_fx/deskd.log" ;;
            running) echo "4711 /bin/sh /usr/bin/xdg-open $uri" > "$lc_bc_fx/xdg"; echo "4712 firefox" > "$lc_bc_fx/handler" ;;
            running-bare) echo "4711 /bin/sh /usr/bin/xdg-open $uri" > "$lc_bc_fx/xdg"; echo "4713 xdg-mime" > "$lc_bc_fx/handler" ;;
          esac
        elif [[ "$LC_OU_OFF" == refuses ]]; then
          echo "[2] open request scheme 'https' is not in the allowlist [], refused: $uri" >> "$lc_bc_fx/deskd.log"
          [[ "$LC_OU_ANDROID" != told ]] \
            || echo "09-26 22:00:00.000  4242  4300 I rhizo-desk: RHIZO_LINK_FAILED uri=$uri why=this host's policy does not open https links" >> "$lc_bc_fx/logcat"
        else
          echo "[2] open request scheme 'https' is not in the allowlist [], refused: https://example.com/lc-open-uri-on-queued" >> "$lc_bc_fx/deskd.log"
        fi
        return 0
      }
      ssh_vm() {
        local c="${*: -1}"
        case "$c" in
          *'stat -c%s /var/log/rhizo/rhizo-deskd.log'*) stat -c%s "$lc_bc_fx/deskd.log" ;;
          *'tail -c +'*'/var/log/rhizo/rhizo-deskd.log'*) bash -c "${c//\/var\/log\/rhizo\/rhizo-deskd.log/$lc_bc_fx/deskd.log}" ;;
          *"printf '[desktop]"*) echo off > "$lc_bc_fx/policy" ;;
          *'systemctl is-active rhizo-deskd.service'*) echo active ;;
          *'pgrep -l -P 4711'*) cat "$lc_bc_fx/handler" ;;
          *) return 255 ;;
        esac
      }
      lc_assert_capability.desktop-open-uri >/dev/null 2>"$lc_bc_fx/err"
      echo "RC=$? FAILED=$FAILED VIEWS=$(grep -c . "$lc_bc_fx/views")"
    )
  }
  lc_ou_out=$(lc_ou_run up refuses up)
  [[ "$lc_ou_out" == "RC=0 FAILED=0 VIEWS=2" ]] \
    || lc_bc_bad+=" open-uri, every leg as designed: '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want a pass;"
  lc_ou_out=$(lc_ou_run down refuses up)
  { [[ "$lc_ou_out" == "RC=1 FAILED=1 VIEWS=0" ]] && grep -qF "the bridge was not up to send the on leg over: no android app authenticated" "$lc_bc_fx/err"; } \
    || lc_bc_bad+=" open-uri over a bridge still reconnecting: '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want a named fail before any request;"
  lc_ou_out=$(lc_ou_run up late-only up)
  { [[ "$lc_ou_out" == "RC=1 FAILED=1 VIEWS=2" ]] && grep -qF "withheld, rhizo-deskd.log (past byte offset" "$lc_bc_fx/err" \
      && grep -qF "never logged refusing https://example.com/lc-open-uri-off-" "$lc_bc_fx/err"; } \
    || lc_bc_bad+=" open-uri whose withheld deskd refused only an earlier queued request: '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want the withheld leg failed by its own uri;"
  lc_ou_out=$(lc_ou_run up refuses down)
  { [[ "$lc_ou_out" == "RC=1 FAILED=1 VIEWS=2" ]] && grep -qF "restored, the bridge did not come back up over the restarted deskd: rhizo-deskd logged no 'android app authenticated'" "$lc_bc_fx/err"; } \
    || lc_bc_bad+=" open-uri whose restore left the android app unauthenticated: '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want a named restore fail;"
  lc_ou_out=$(lc_ou_run up refuses up running)
  [[ "$lc_ou_out" == "RC=0 FAILED=0 VIEWS=2" ]] \
    || lc_bc_bad+=" open-uri whose handler still holds xdg-open: '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want a pass;"
  lc_ou_out=$(lc_ou_run up refuses up running-bare)
  { [[ "$lc_ou_out" == "RC=1 FAILED=1 VIEWS=2" ]] && grep -qF "no xdg-open carrying it runs a handler" "$lc_bc_fx/err"; } \
    || lc_bc_bad+=" open-uri whose xdg-open is still resolving a handler (xdg-mime under it): '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want a named fail;"
  lc_ou_out=$(lc_ou_run up refuses up failed)
  { [[ "$lc_ou_out" == "RC=1 FAILED=1 VIEWS=2" ]] && grep -qF "on, deskd's xdg-open did not open https://example.com/lc-open-uri-on-" "$lc_bc_fx/err" \
      && grep -qF "no method available" "$lc_bc_fx/err"; } \
    || lc_bc_bad+=" open-uri whose xdg-open failed: '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want a fail in deskd's own words;"
  lc_ou_out=$(lc_ou_run up refuses up silent)
  { [[ "$lc_ou_out" == "RC=1 FAILED=1 VIEWS=2" ]] && grep -qF "on, deskd logged no outcome for its xdg-open of" "$lc_bc_fx/err"; } \
    || lc_bc_bad+=" open-uri with no xdg-open outcome and none running: '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want a named fail;"
  lc_ou_out=$(lc_ou_run up refuses up opened silent)
  { [[ "$lc_ou_out" == "RC=1 FAILED=1 VIEWS=2" ]] && grep -qF "but Android never logged RHIZO_LINK_FAILED for it" "$lc_bc_fx/err"; } \
    || lc_bc_bad+=" open-uri whose refusal never reached Android: '$lc_ou_out' $(grep FAIL "$lc_bc_fx/err" | head -1), want a named fail;"
  if [[ -z "$lc_bc_bad" ]]; then
    ok "1zs: the bridge reads current only for an android app authenticated since deskd's last start with no disconnect after, and capability.desktop-open-uri sends only over it, fails an on leg whose xdg-open failed or left no outcome (a live xdg-open passes only with a handler under it), fails the withheld leg unless a refusal names its own uri and reaches Android, and fails a restore that leaves the android app unauthenticated"
  else
    bad "1zs:$lc_bc_bad"
  fi
  rm -rf "$lc_bc_fx"
  unset -f lc_bc_run lc_ou_run
  unset lc_bc_fx lc_bc_bad lc_ou_out

  lc_na_fx=$(mktemp -d) || exit 1
  lc_na_run() {
    (
      FAILED=0 lc_na_answer="$2"
      ssh_vm() { printf '%s' "$lc_na_answer"; }
      lc_assert_host.new-account-home "$1" >/dev/null 2>"$lc_na_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_na_case() {
    local out; out=$(lc_na_run "$2" "$3")
    if [[ "$4" == pass ]]; then
      [[ "$out" == "RC=0 FAILED=0" ]] || lc_na_bad+=" $1: $out $(grep FAIL "$lc_na_fx/claim.err" | head -1);"
    elif [[ "$out" != "RC=1 FAILED=1" ]] || ! grep -qF -- "$4" "$lc_na_fx/claim.err"; then
      lc_na_bad+=" $1: $out, want a fail naming '$4': $(grep FAIL "$lc_na_fx/claim.err" | head -1);"
    fi
  }
  lc_na_skel=.bash_logout/.bashrc/.profile/
  lc_na_good=$'enforce=1\nskel=3\nlogin_home_mode=750\nskel_names='"$lc_na_skel"$'\nadduser=/usr/sbin/adduser\nterm_adduser_rc=82\nterm_adduser_err=err: open >/home/rhzterm/./.profile: Permission denied \nterm_account=absent\ncreate_via=accounts-daemon\ncreate_rc=0\nhome_before=750:rhzskel:\nuser_at_rc=0\nhome_after=750:rhzskel:'"$lc_na_skel"$'\nbashrc=same\nskel_alias=ll\nlogin_shell_alias=yes\njournal_fill=1\ncleanup=ok\nDONE'
  lc_na_useradd=${lc_na_good/create_via=accounts-daemon/create_via=useradd}
  lc_na_bad=""
  lc_na_case "gnome through accounts-daemon" gnome "$lc_na_good" pass
  lc_na_case "server through useradd" server "$lc_na_useradd" pass
  lc_na_case "sway through useradd" sway "$lc_na_useradd" pass
  lc_na_case "gnome with no accounts-daemon" gnome "$lc_na_useradd" "gnome has no accounts-daemon"
  lc_na_case "permissive" gnome "${lc_na_good/enforce=1/enforce=0}" "want enforce=1, got enforce=0"
  lc_na_case "terminal adduser succeeding" gnome "${lc_na_good/term_adduser_rc=82/term_adduser_rc=0}" "terminal adduser succeeded"
  lc_na_err="err: open >/home/rhzterm/./.profile: Permission denied"
  lc_na_other="fatal: The user rhzterm already exists."
  lc_na_mkdir="err: mkdir: /home/rhzterm/./.config: Permission denied"
  lc_na_case "a terminal adduser failing for another reason" gnome "${lc_na_good/"$lc_na_err"/$lc_na_other}" \
    "terminal adduser failed, but not with the disclosed skel copy's"
  lc_na_case "a terminal adduser whose stderr was discarded" gnome "${lc_na_good/"$lc_na_err"/}" \
    "but not with the disclosed skel copy's"
  lc_na_case "a terminal adduser failing on a skel directory" gnome "${lc_na_good/"$lc_na_err"/$lc_na_mkdir}" pass
  lc_na_case "no terminal adduser exit status" gnome "${lc_na_good/term_adduser_rc=82/}" "no terminal adduser exit status read"
  lc_na_case "no adduser at all" gnome "${lc_na_good/adduser=\/usr\/sbin\/adduser/adduser=absent}" "the host has no adduser"
  lc_na_cachy=$(sed -e 's|^adduser=.*|adduser=absent|' -e '/^term_adduser_/d' -e 's|^term_account=absent|term_account=present|' \
    -e 's|^login_home_mode=750|login_home_mode=700|' -e 's|^home_before=750|home_before=700|' -e 's|^home_after=750|home_after=700|' <<<"$lc_na_good")
  lc_na_cachy=${lc_na_cachy%$'\n'DONE}$'\nterm_useradd_rc=0\nterm_home_entries=0\nDONE'
  RHIZO_GUEST_OS=cachyos lc_na_case "plasma on cachyos through useradd -m" plasma "$lc_na_cachy" pass
  RHIZO_GUEST_OS=cachyos lc_na_case "a cachyos useradd -m that copied skel" plasma "${lc_na_cachy/term_home_entries=0/term_home_entries=3}" \
    "did not exit 0 with an empty home"
  lc_na_case "a home at another mode than login.defs" gnome "${lc_na_good/login_home_mode=750/login_home_mode=700}" "want home_before=700:rhzskel:"
  lc_na_case "the failed adduser's account left" gnome "${lc_na_good/term_account=absent/term_account=present}" "want term_account=absent, got term_account=present"
  lc_na_case "CreateUser failing" gnome "${lc_na_good/create_rc=0/create_rc=1}" "want create_rc=0, got create_rc=1"
  lc_na_case "a home filled at creation" gnome "${lc_na_good/home_before=750:rhzskel:/home_before=750:rhzskel:$lc_na_skel}" "want home_before=750:rhzskel:, got home_before=750:rhzskel:$lc_na_skel"
  lc_na_case "a home its owner cannot list" gnome "${lc_na_good/home_before=750:rhzskel:/home_before=750:rhzskel:unreadable}" "got home_before=750:rhzskel:unreadable"
  lc_na_case "user@ not starting" gnome "${lc_na_good/user_at_rc=0/user_at_rc=1}" "want user_at_rc=0, got user_at_rc=1"
  lc_na_case "a home left empty" gnome "${lc_na_good/home_after=750:rhzskel:$lc_na_skel/home_after=750:rhzskel:}" "want home_after=750:rhzskel:$lc_na_skel, got home_after=750:rhzskel:: "
  lc_na_case "a home holding as many entries as skel but other ones" gnome \
    "${lc_na_good/home_after=750:rhzskel:$lc_na_skel/home_after=750:rhzskel:.bashrc/.cache/.profile/}" \
    "want home_after=750:rhzskel:$lc_na_skel, got home_after=750:rhzskel:.bashrc/.cache/.profile/"
  lc_na_case "a home opened to 0755" gnome "${lc_na_good/home_after=750:rhzskel:$lc_na_skel/home_after=755:rhzskel:$lc_na_skel}" "want home_after=750:rhzskel:$lc_na_skel, got home_after=755:rhzskel:$lc_na_skel"
  lc_na_case "no skel name list" gnome "${lc_na_good/skel_names=$lc_na_skel/skel_names=}" "no /etc/skel name list read"
  lc_na_case "a .bashrc that is not skel's" gnome "${lc_na_good/bashrc=same/bashrc=differs}" "want bashrc=same, got bashrc=differs"
  lc_na_case "a login shell without skel's alias" gnome "${lc_na_good/login_shell_alias=yes/login_shell_alias=no}" "want login_shell_alias=yes, got login_shell_alias=no"
  lc_na_case "no fill line in user@'s journal" gnome "${lc_na_good/journal_fill=1/journal_fill=0}" "want journal_fill=1, got journal_fill=0"
  lc_na_case "a cleanup that left the account files changed" gnome "${lc_na_good/cleanup=ok/cleanup=left: changed:/etc/passwd}" "want cleanup=ok, got cleanup=left: changed:/etc/passwd"
  lc_na_case "an empty /etc/skel" gnome "${lc_na_good/skel=3/skel=0}" "/etc/skel lists '0' entries"
  lc_na_case "no DONE" gnome "${lc_na_good%DONE}" "incomplete guest read (no DONE token)"
  if [[ -z "$lc_na_bad" ]]; then
    ok "1zd: host.new-account-home passes accounts-daemon on gnome and useradd on sway and server, and fails by name on gnome without accounts-daemon, permissive, a terminal adduser that works, is missing, fails for an undisclosed reason or with no status, or leaves its account, a failed create, a home filled or unreadable at creation, user@ not starting, a home left empty, opened or holding other names than skel, no skel name list, a foreign .bashrc, no alias in a login shell, no journal fill line, a cleanup that left anything, an empty skel and no DONE"
  else
    bad "1zd:$lc_na_bad"
  fi
  rm -rf "$lc_na_fx"
  unset -f lc_na_run lc_na_case
  unset lc_na_fx lc_na_bad lc_na_good lc_na_useradd lc_na_skel lc_na_err lc_na_other lc_na_mkdir

  lc_rh_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_rh_fx/bin"
  printf '#!/bin/sh\nwhile [ "${1#--}" != "$1" ]; do shift; done\nexec "$@"\n' > "$lc_rh_fx/bin/setpriv"
  chmod +x "$lc_rh_fx/bin/setpriv"
  lc_rh_try() {
    rm -rf "${lc_rh_fx:?}/home"
    mkdir -p "$lc_rh_fx/home/.config" "$lc_rh_fx/start"
    touch "$lc_rh_fx/home/.bashrc" "$lc_rh_fx/home/.config/x"
    ( cd "$lc_rh_fx/start" && chmod 0 . && PATH="$lc_rh_fx/bin:$PATH" bash -c "$1"$'\nremove_home "$0"' "$lc_rh_fx/home" ) >/dev/null 2>&1
    chmod 0700 "$lc_rh_fx/start"
    if [[ -e "$lc_rh_fx/home" ]]; then echo left; else echo gone; fi
  }
  lc_rh_old='remove_home() {
  setpriv --reuid="$(stat -c %u "$1")" --regid="$(stat -c %g "$1")" --clear-groups \
     sh -c "chmod -R u+rwX $1 && find $1 -mindepth 1 -delete" && rmdir "$1"
}'
  lc_rh_new=$(lc_rh_try "$LC_REMOVE_HOME_FN")
  lc_rh_planted=$(lc_rh_try "$lc_rh_old")
  lc_rh_call='remove_home "$h" || left="$left home:$h"'
  if [[ "$lc_rh_new" == gone && "$lc_rh_planted" == left \
        && "$LC_NEW_ACCOUNT_HOME_CMD" == "$LC_REMOVE_HOME_FN"$'\n'* && "$LC_NEW_ACCOUNT_HOME_CMD" == *"$lc_rh_call"* \
        && "$LC_USER_MANAGER_START_CMD" == "$LC_REMOVE_HOME_FN"$'\n'* && "$LC_USER_MANAGER_START_CMD" == *"$lc_rh_call"* \
        && "$LC_NEW_ACCOUNT_HOME_CMD$LC_USER_MANAGER_START_CMD" != *'find $h '* ]]; then
    ok "1zd2: both host.* guest scripts define remove_home first and call it for every home; run from a directory the account cannot enter it removes the home, where a delete run as the account from there leaves it"
  else
    bad "1zd2: from a directory the account cannot enter, remove_home read '$lc_rh_new' (want gone) and a delete run as the account '$lc_rh_planted' (want left); both scripts must begin with LC_REMOVE_HOME_FN and call it for each home"
  fi
  rm -rf "$lc_rh_fx"
  unset -f lc_rh_try
  unset lc_rh_fx lc_rh_old lc_rh_new lc_rh_planted lc_rh_call

  lc_um_fx=$(mktemp -d) || exit 1
  lc_um_run() {
    (
      FAILED=0 lc_um_answer="$2"
      ssh_vm() { printf '%s' "$lc_um_answer"; }
      lc_assert_host.user-manager-start "$1" >/dev/null 2>"$lc_um_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_um_case() {
    local out; out=$(lc_um_run "$2" "$3")
    if [[ "$4" == pass ]]; then
      [[ "$out" == "RC=0 FAILED=0" ]] || lc_um_bad+=" $1: $out $(grep FAIL "$lc_um_fx/claim.err" | head -1);"
    elif [[ "$out" != "RC=1 FAILED=1" ]] || ! grep -qF -- "$4" "$lc_um_fx/claim.err"; then
      lc_um_bad+=" $1: $out, want a fail naming '$4': $(grep FAIL "$lc_um_fx/claim.err" | head -1);"
    fi
  }
  lc_um_login=$'run_rc=0\nclass=user\nmanager=running\nbus=yes\nresult=success\nstatus=0\nuser_at=inactive\nleftover=yes'
  lc_um_good=$'enforce=1\ncreate_rc=0\nkey_rc=0\nauthkeys_rc=0\nuid=1001\n'"$(sed 's/^/first_/' <<<"$lc_um_login")"$'\n'"$(sed 's/^/again_/' <<<"$lc_um_login")"
  lc_um_greeter=$'greeter_policy_at=41000000\ngreeter_user_at_started=52000000\ngreeter_user_at_failed=0\ngreeter_seat_session_at=61000000'
  lc_um_good+=$'\nreset_logged=1\n'"$lc_um_greeter"$'\ncgroup_after_cleanup=gone\ncleanup=ok\nDONE'
  lc_um_nogdm=${lc_um_good/"$lc_um_greeter"/greeter_user_at=no-greeter-account}
  lc_um_bad=""
  bash -n <<<"$LC_USER_MANAGER_START_CMD" 2>"$lc_um_fx/syntax.err" \
    || lc_um_bad+=" the guest command does not parse: $(head -1 "$lc_um_fx/syntax.err");"
  [[ "$LC_USER_MANAGER_START_CMD" == *'ssh -n -i "$key"'*'"$u@127.0.0.1"'* \
     && "$LC_USER_MANAGER_START_CMD" != *PAMName=* ]] \
    || lc_um_bad+=" the guest command does not log in through sshd, or still opens a tty-less PAM session;"
  lc_um_case "gnome with gdm's greeter reaped after the timed login" gnome "$lc_um_good" pass
  lc_um_case "gnome on a host with no gdm" gnome "$lc_um_nogdm" "gnome logs in through gdm's greeter, and this host has no gdm account"
  lc_um_case "plasma, whose autologin starts no greeter" plasma "$lc_um_nogdm" pass
  lc_um_case "sway" sway "$lc_um_nogdm" pass
  lc_um_case "server" server "$lc_um_nogdm" pass
  lc_um_case "a degraded manager" server "${lc_um_nogdm/again_manager=running/again_manager=degraded}" pass
  lc_um_case "a logout that left no cgroup and so no reset" server \
    "$(sed -e 's/^first_leftover=yes$/first_leftover=no/' -e 's/^reset_logged=1$/reset_logged=0/' <<<"$lc_um_nogdm")" pass
  lc_um_case "permissive" gnome "${lc_um_good/enforce=1/enforce=0}" "want enforce=1, got enforce=0"
  lc_um_case "a failed useradd" server "${lc_um_nogdm/create_rc=0/create_rc=9}" "want create_rc=0, got create_rc=9"
  lc_um_case "a login that did not run" server "${lc_um_nogdm/first_run_rc=0/first_run_rc=1}" "want first_run_rc=0, got first_run_rc=1"
  lc_um_case "a tty-less PAM session, class background" server \
    "${lc_um_nogdm/first_class=user/first_class=background}" "want first_class=user, got first_class=background"
  lc_um_case "no key made" server "${lc_um_nogdm/key_rc=0/key_rc=1}" "want key_rc=0, got key_rc=1"
  lc_um_case "no key installed as the account" server "${lc_um_nogdm/authkeys_rc=0/authkeys_rc=1}" "want authkeys_rc=0, got authkeys_rc=1"
  lc_um_case "a login with no logind session" server \
    "${lc_um_nogdm/first_class=user/first_class=Failed to get session path: No session known}" "want first_class=user, got first_class=Failed to get session path"
  lc_um_case "user@ failing on its drop-in" sway "${lc_um_nogdm/first_result=success/first_result=resources}" "want first_result=success, got first_result=resources"
  lc_um_case "a manager that never came up" sway \
    "${lc_um_nogdm/first_manager=running/first_manager=Failed to connect to bus: No medium found}" "want first_manager=running or degraded, got first_manager=Failed to connect to bus"
  lc_um_case "no manager line" sway "$(sed '/^first_manager=/d' <<<"$lc_um_nogdm")" "want first_manager=running or degraded, got no first_manager line"
  lc_um_case "no session bus" gnome "${lc_um_good/first_bus=yes/first_bus=no}" "want first_bus=yes, got first_bus=no"
  lc_um_case "user@ still up after the logout" server "${lc_um_nogdm/first_user_at=inactive/first_user_at=deactivating}" "want first_user_at=inactive, got first_user_at=deactivating"
  lc_um_case "the next start failing on the leftover cgroup" sway \
    "${lc_um_nogdm/again_status=0/again_status=219}" "want again_status=0, got again_status=219"
  lc_um_case "the next start's result" sway "${lc_um_nogdm/again_result=success/again_result=exit-code}" "want again_result=success, got again_result=exit-code"
  lc_um_case "no session bus after the logout" sway "${lc_um_nogdm/again_bus=yes/again_bus=no}" "want again_bus=yes, got again_bus=no"
  lc_um_case "a leftover cgroup no prep unit reset" server "${lc_um_nogdm/reset_logged=1/reset_logged=0}" "the first logout left user@'s cgroup and the second start logged no reset"
  lc_um_case "no leftover read" server "$(sed '/^first_leftover=/d' <<<"$lc_um_nogdm")" "no leftover-cgroup or reset count read"
  lc_um_case "no reset count" server "$(sed '/^reset_logged=/d' <<<"$lc_um_nogdm")" "no leftover-cgroup or reset count read"
  lc_um_case "the greeter's user manager failing once" gnome "${lc_um_good/greeter_user_at_failed=0/greeter_user_at_failed=1}" "gdm's greeter's user manager failed to start 1 time(s) this boot"
  lc_um_case "no greeter user manager start this boot" gnome "${lc_um_good/greeter_user_at_started=52000000/greeter_user_at_started=}" "holds no start of gdm's greeter's user manager"
  lc_um_case "a greeter user manager started before the policy" gnome "${lc_um_good/greeter_user_at_started=52000000/greeter_user_at_started=30000000}" "not after rhizo-policy.service finished"
  lc_um_case "no policy load read" gnome "${lc_um_good/greeter_policy_at=41000000/greeter_policy_at=}" "not after rhizo-policy.service finished"
  lc_um_case "a greeter user manager started after the seat session" gnome "${lc_um_good/greeter_user_at_started=52000000/greeter_user_at_started=70000000}" "not before deskuser's seat session"
  lc_um_case "no seat session read" gnome "${lc_um_good/greeter_seat_session_at=61000000/greeter_seat_session_at=}" \
    "holds no logind session of deskuser (read"
  lc_um_case "an unread seat session" gnome "${lc_um_good/greeter_seat_session_at=61000000/greeter_seat_session_at=x}" \
    "holds no logind session of deskuser (read"
  lc_um_case "no greeter lines on gnome" gnome "$(sed '/^greeter_/d' <<<"$lc_um_good")" "gdm's greeter's user manager failed to start <unread> time(s)"
  lc_um_case "a cgroup the cleanup left" server "${lc_um_nogdm/cgroup_after_cleanup=gone/cgroup_after_cleanup=left}" "want cgroup_after_cleanup=gone, got cgroup_after_cleanup=left"
  lc_um_case "a cleanup that left the account files changed" server "${lc_um_nogdm/cleanup=ok/cleanup=left: changed:/etc/passwd}" "want cleanup=ok, got cleanup=left: changed:/etc/passwd"
  lc_um_case "no DONE" server "${lc_um_nogdm%DONE}" "incomplete guest read (no DONE token)"
  if [[ -z "$lc_um_bad" ]]; then
    ok "1ze: host.user-manager-start passes gnome whose gdm greeter was already reaped, sway and server, a degraded manager and a logout with no leftover cgroup, and fails by name on permissive, a failed useradd, no key made or installed, a tty-less background session, a login that did not run or got no logind session, user@ failing, no or no running manager, no session bus, user@ up after the logout, the next start failing, a leftover cgroup never reset, no leftover or reset read, on gnome no gdm, a greeter user manager that failed, never started, started before the policy or after the seat session, no seat session at all (named as that, not as an order), or no greeter read at all, a cleanup that left anything and no DONE"
  else
    bad "1ze:$lc_um_bad"
  fi
  rm -rf "$lc_um_fx"
  unset -f lc_um_run lc_um_case
  unset lc_um_fx lc_um_bad lc_um_good lc_um_nogdm lc_um_login lc_um_greeter

  lc_sl_fx=$(mktemp -d) || exit 1
  lc_sl_good=$'UID=1000\nSEAT_ACTIVE=3\nSESSION_Id=3\nSESSION_Name=deskuser\nSESSION_Seat=seat0\nSESSION_Active=yes'
  lc_sl_good+=$'\nSESSION_State=active\nSESSION_Class=user\nSESSION_Service=login\nSESSION_TimestampMonotonic=20000000'
  lc_sl_good+=$'\nSESSION_VTNr=1\nLOGIND_TTYS=/dev/tty1 /dev/tty6 '
  lc_sl_good+=$'\nPOLICY_LoadState=loaded\nPOLICY_ActiveState=active\nPOLICY_ActiveEnterTimestampMonotonic=15000000'
  lc_sl_good+=$'\nCOMP_PIDS=4242\nCOMP_PS=1000 u:r:rhizo_host:s0\nCOMP_CGROUP=/user.slice/user-1000.slice/session-3.scope'
  lc_sl_good+=$'\nCOMP_UNIT_START=20000100\nSOCKET=wayland-1\nDONE'
  lc_sl_record() {
    (
      EV="$lc_sl_fx" LC_SEAT_LOGIN_ROWS="" LC_SEAT_LOGIN_N=0 lc_sl_read="$2"
      ssh_vm() { echo 0a1b2c3d-0000-4000-8000-00000000abcd; }
      desk_session_up() { return 0; }
      desk_seat_read() { printf '%s\n' "$lc_sl_read"; }
      LIFECYCLE_PROFILE="$1" installer_post_reboot_hook "selftest reboot" 2>/dev/null
      [[ -n "$LC_SEAT_LOGIN_ROWS" ]] && printf '%s' "$LC_SEAT_LOGIN_ROWS" || echo "no row"
    )
  }
  lc_sl_bad=""
  lc_sl_row=$(lc_sl_record sway "$lc_sl_good")
  [[ "$lc_sl_row" == $'0a1b2c3d00004000800000000000abcd\tselftest reboot\tpolicy\tpass\t'* ]] \
    || lc_sl_bad+=" the good read recorded '$lc_sl_row';"
  [[ "$(lc_sl_record server "$lc_sl_good")" == "no row" ]] || lc_sl_bad+=" a server boot recorded a seat-login row;"
  while IFS='|' read -r lc_sl_label lc_sl_from lc_sl_to lc_sl_want; do
    lc_sl_read=${lc_sl_good/"$lc_sl_from"/"$lc_sl_to"}
    [[ "$lc_sl_label" == "an empty read" ]] && lc_sl_read=""
    [[ "$lc_sl_label" == "a read with no DONE" ]] && lc_sl_read=${lc_sl_good%$'\n'DONE}
    lc_sl_row=$(lc_sl_record sway "$lc_sl_read")
    [[ "$(cut -f4 <<<"$lc_sl_row")" == fail && "$(cut -f5 <<<"$lc_sl_row")" == *"$lc_sl_want"* ]] \
      || lc_sl_bad+=" $lc_sl_label recorded '$lc_sl_row', want a fail naming $lc_sl_want;"
  done <<'CASES'
an empty read|-|-|read.incomplete
a read with no DONE|-|-|read.incomplete
loginctl with no active session|SEAT_ACTIVE=3|SEAT_ACTIVE=|seat.no-active-session
loginctl naming another user|SESSION_Name=deskuser|SESSION_Name=gdm|seat.not-desktop-user
loginctl with an inactive session|SESSION_Active=yes|SESSION_Active=no|seat.not-active
logind holding no console VT|LOGIND_TTYS=/dev/tty1 /dev/tty6 |LOGIND_TTYS=/dev/tty6 |seat.no-vt-control
ps -Z unreadable|COMP_PS=1000 u:r:rhizo_host:s0|COMP_PS=|compositor.ps-unreadable
ps -Z in kernel|COMP_PS=1000 u:r:rhizo_host:s0|COMP_PS=1000 u:r:kernel:s0|compositor.not-rhizo-host
systemctl with the policy unit failed|POLICY_ActiveState=active|POLICY_ActiveState=failed|policy.not-active
systemctl with no policy timestamp|POLICY_ActiveEnterTimestampMonotonic=15000000|POLICY_ActiveEnterTimestampMonotonic=0|policy.timestamp-unread
systemctl with the compositor before the policy|COMP_UNIT_START=20000100|COMP_UNIT_START=100|order.compositor-before-policy
CASES
  lc_sl_claim() {
    (
      EV="$lc_sl_fx" FAILED=0 LC_SEAT_LOGIN_ROWS="$1" lc_sl_journal="$2" lc_sl_listed="$3"
      ssh_vm() {
        if [[ "${*: -1}" == "${LC_LIST_BOOTS_CMD:-<unset>}" ]]; then printf '%s' "$lc_sl_listed"; else printf '%s' "$lc_sl_journal"; fi
      }
      lc_assert_host.seat-login >/dev/null 2>"$lc_sl_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_sl_case() {
    local out; out=$(lc_sl_claim "$2" "$3" "${5-$'aaaa\nbbbb\ncccc\nDONE'}")
    if [[ "$4" == pass ]]; then
      [[ "$out" == "RC=0 FAILED=0" ]] || lc_sl_bad+=" claim, $1: $out $(grep FAIL "$lc_sl_fx/claim.err" | head -1);"
    elif [[ "$out" != "RC=1 FAILED=1" ]] || ! grep -qF -- "$4" "$lc_sl_fx/claim.err"; then
      lc_sl_bad+=" claim, $1: $out, want a fail naming '$4': $(grep FAIL "$lc_sl_fx/claim.err" | head -1);"
    fi
  }
  lc_sl_rows=$'aaaa\tcycle-sway stock\tstock\tpass\tok\nbbbb\t[cycle-sway] install\tpolicy\tpass\tok\ncccc\tcycle-sway upgrade\tpolicy\tpass\tok\n'
  lc_sl_case "every policy boot read" "$lc_sl_rows" $'bbbb\ncccc\nDONE' pass
  lc_sl_case "no rows" "" $'bbbb\nDONE' "no boot of this cycle recorded a seat-login read"
  lc_sl_case "a failed row" "${lc_sl_rows/cccc$'\t'cycle-sway upgrade$'\t'policy$'\t'pass/cccc$'\t'cycle-sway upgrade$'\t'policy$'\t'fail}" \
    $'bbbb\ncccc\nDONE' "boot(s) came up without a working seat login"
  lc_sl_case "a policy boot with no row" "$lc_sl_rows" $'bbbb\ncccc\ndddd\nDONE' "boot(s) dddd started rhizo-policy.service"
  lc_sl_case "a policy boot recorded as stock" "$lc_sl_rows" $'aaaa\nbbbb\ncccc\nDONE' "boot(s) aaaa started rhizo-policy.service"
  lc_sl_case "a journal read with no DONE" "$lc_sl_rows" $'bbbb\ncccc' "never finished"
  lc_sl_case "an empty journal" "$lc_sl_rows" 'DONE' "holds no boot whose PID 1 started rhizo-policy.service"
  lc_sl_case "a stock boot read that the journal does not list" "$lc_sl_rows" $'bbbb\ncccc\nDONE' \
    "boot(s) aaaa (cycle-sway stock) are not in this disk's journal" $'bbbb\ncccc\nDONE'
  lc_sl_case "a policy boot read that the journal does not list" "$lc_sl_rows" $'bbbb\nDONE' \
    "boot(s) cccc (cycle-sway upgrade) are not in this disk's journal" $'aaaa\nbbbb\nDONE'
  lc_sl_case "a policy boot read whose policy start the journal lacks" \
    "$lc_sl_rows"$'eeee\tcycle-sway reinstall\tpolicy\tpass\tok\n' $'bbbb\ncccc\nDONE' \
    "boot(s) eeee (cycle-sway reinstall) ran under the policy but the journal's rhizo-policy.service starts miss them" \
    $'aaaa\nbbbb\ncccc\neeee\nDONE'
  lc_sl_case "a boot-list read with no DONE" "$lc_sl_rows" $'bbbb\ncccc\nDONE' "the journal's boot list never finished" \
    $'aaaa\nbbbb\ncccc'
  lc_sl_case "a row whose boot id was never read" "${lc_sl_rows/aaaa/<unread>}" $'bbbb\ncccc\nDONE' \
    "boot(s) <unread> (cycle-sway stock) are not in this disk's journal"
  bash -n <<<"$LC_POLICY_BOOTS_CMD" 2>"$lc_sl_fx/syntax.err" \
    || lc_sl_bad+=" LC_POLICY_BOOTS_CMD does not parse: $(head -1 "$lc_sl_fx/syntax.err");"
  bash -n <<<"${LC_LIST_BOOTS_CMD:-}" 2>"$lc_sl_fx/syntax.err" && [[ -n "${LC_LIST_BOOTS_CMD:-}" ]] \
    || lc_sl_bad+=" LC_LIST_BOOTS_CMD is unset or does not parse: $(head -1 "$lc_sl_fx/syntax.err");"
  lc_sl_listed=$(printf '%s\n' 'IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY' \
      ' -1 0a1b2c3d00004000800000000000abcd Thu 2026-09-24 10:00:00 UTC Thu 2026-09-24 10:05:00 UTC' \
      '  0 1f2e3d4c00004000800000000000dcba Thu 2026-09-24 10:06:00 UTC Thu 2026-09-24 10:09:00 UTC' \
    | awk "${LC_LIST_BOOTS_AWK:-}")
  [[ "$lc_sl_listed" == $'0a1b2c3d00004000800000000000abcd\n1f2e3d4c00004000800000000000dcba' ]] \
    || lc_sl_bad+=" LC_LIST_BOOTS_AWK read a --list-boots table as '$(tr '\n' ' ' <<<"$lc_sl_listed")';"
  bash -n <<<"$DESK_SEAT_READ" 2>"$lc_sl_fx/syntax.err" \
    || lc_sl_bad+=" DESK_SEAT_READ does not parse: $(head -1 "$lc_sl_fx/syntax.err");"
  for lc_sl_lib in lib/installer-lib.sh:reboot_and_wait lib/gsi-update-lib.sh:boot_and_start; do
    # shellcheck source=/dev/null
    grep -q 'installer_post_reboot_hook "\$' <<<"$( ( source "$(dirname "${BASH_SOURCE[0]}")/../${lc_sl_lib%%:*}"; declare -f "${lc_sl_lib#*:}" ) 2>/dev/null)" \
      || lc_sl_bad+=" ${lc_sl_lib%%:*}'s ${lc_sl_lib#*:} never calls installer_post_reboot_hook;"
  done
  if [[ -z "$lc_sl_bad" ]]; then
    ok "1zf: host.seat-login records a passing policy row for a good seat read and none on server, a failing row naming an empty or DONE-less read, loginctl with no, another user's or an inactive session, logind holding no console VT, ps -Z unreadable or in kernel, and systemctl with the policy failed, unstamped or after the compositor; the claim passes when every policy boot has a passing row and fails by name on no rows, a failed row, a policy boot with no row or only a stock one, an unfinished or empty journal read, a boot read that the journal does not list, and a policy boot read its policy starts lack; reboot_and_wait and boot_and_start both call the hook"
  else
    bad "1zf:$lc_sl_bad"
  fi
  rm -rf "$lc_sl_fx"
  unset -f lc_sl_record lc_sl_claim lc_sl_case
  unset lc_sl_fx lc_sl_good lc_sl_bad lc_sl_row lc_sl_read lc_sl_label lc_sl_from lc_sl_to lc_sl_want lc_sl_rows lc_sl_lib lc_sl_listed

  lc_cl_settings=$'Display #0 (activities from top to bottom):\n      topResumedActivity=ActivityRecord{2 u0 com.rhizo.home/.Home t2}'
  lc_cl_settings+=$'\nDisplay #3 (activities from top to bottom):\n      topResumedActivity=ActivityRecord{1 u0 com.android.settings/.Settings t9}'
  lc_cl_settings+=$'\n  ResumedActivity: ActivityRecord{1 u0 com.android.settings/.Settings t9}'
  lc_cl_home=$'Display #0 (activities from top to bottom):\n      topResumedActivity=ActivityRecord{2 u0 com.rhizo.home/.Home t2}'
  lc_cl_home+=$'\n  ResumedActivity: ActivityRecord{2 u0 com.rhizo.home/.Home t2}'
  lc_cl_home+=$'\n  LastResumedActivity: ActivityRecord{1 u0 com.android.settings/.Settings t9}'
  lc_cl_run() {
    (
      FAILED=0 lc_cl_stop="$2" lc_cl_launch="$3" lc_cl_dump="${4:-ok}"
      [[ "$1" == settings ]] && printf '%s\n' "$lc_cl_settings" > "$lc_cl_fx/resumed" \
        || printf '%s\n' "$lc_cl_home" > "$lc_cl_fx/resumed"
      lc_need_guest() { return 0; }
      lc_resolve_init() { echo 4242; }
      lc_resolve_activity() { printf 'com.android.settings/.Settings'; }
      android_sh() {
        case "$2" in
          'am force-stop com.android.settings'*)
            case "$lc_cl_stop" in
              dead) return 97 ;;
              rc255) echo 'FORCE_STOP_RC=255' ;;
              works) printf '%s\n' "$lc_cl_home" > "$lc_cl_fx/resumed"; echo 'FORCE_STOP_RC=0' ;;
              noop) echo 'FORCE_STOP_RC=0' ;;
            esac ;;
          'dumpsys activity activities'*)
            if [[ "$2" == *'echo DONE'* && "$lc_cl_dump" == nodump ]]; then
              printf "Can't find service: activity\nDONE\n"
              return 0
            fi
            printf 'ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)\n%s\n' "$(<"$lc_cl_fx/resumed")"
            [[ "$2" == *'echo DONE'* && "$lc_cl_dump" != cut ]] && echo DONE ;;
        esac
        return 0
      }
      lc_rhizo() {
        printf '%s' "$*" > "$lc_cl_fx/argv"
        [[ "$lc_cl_launch" == works ]] && printf '%s\n' "$lc_cl_settings" > "$lc_cl_fx/resumed"
        echo "RHIZO_LAUNCHED pkg=com.android.settings display=0 cdisplay=3"
      }
      : > "$lc_cl_fx/argv"
      echo 1000 > "$lc_cl_fx/now"
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_cl_fx/now"); echo $(( n + 10 )) > "$lc_cl_fx/now"; echo "$n"
      }
      sleep() { :; }
      lc_assert_cli.launch >/dev/null 2>"$lc_cl_fx/err"
      echo "RC=$? FAILED=$FAILED ARGV=$(<"$lc_cl_fx/argv")"
    )
  }
  lc_cl_fx=$(mktemp -d) || exit 1
  lc_cl_bad=""
  lc_cl_out=$(lc_cl_run home works works)
  [[ "$lc_cl_out" == "RC=0 FAILED=0 ARGV=launch com.android.settings" ]] \
    || lc_cl_bad+=" a launch whose app resumed: want RC=0 FAILED=0 ARGV=launch com.android.settings, got '$lc_cl_out';"
  lc_cl_out=$(lc_cl_run home works noop)
  [[ "$lc_cl_out" == "RC=1 FAILED=1 ARGV=launch com.android.settings" ]] \
    || lc_cl_bad+=" a launch whose app never resumed: want RC=1 FAILED=1, got '$lc_cl_out';"
  lc_cl_out=$(lc_cl_run settings works works)
  [[ "$lc_cl_out" == "RC=0 FAILED=0 ARGV=launch com.android.settings" ]] \
    || lc_cl_bad+=" an already-resumed app the force-stop stopped, then launched: want RC=0 FAILED=0 ARGV=launch com.android.settings, got '$lc_cl_out';"
  lc_cl_out=$(lc_cl_run settings noop noop)
  [[ "$lc_cl_out" == "RC=1 FAILED=1 ARGV=" ]] \
    && grep -q 'com.android.settings is still the resumed activity after am force-stop' "$lc_cl_fx/err" \
    || lc_cl_bad+=" an app the force-stop left resumed: want RC=1 FAILED=1 ARGV= and a fail naming it still resumed, got '$lc_cl_out' $(grep FAIL "$lc_cl_fx/err" | head -1);"
  lc_cl_out=$(lc_cl_run settings rc255 works)
  [[ "$lc_cl_out" == "RC=1 FAILED=1 ARGV=" ]] && grep -q 'am force-stop com.android.settings' "$lc_cl_fx/err" \
    || lc_cl_bad+=" a force-stop that exited 255: want RC=1 FAILED=1 ARGV= naming the force-stop, got '$lc_cl_out';"
  lc_cl_out=$(lc_cl_run settings dead works)
  [[ "$lc_cl_out" == "RC=1 FAILED=1 ARGV=" ]] \
    || lc_cl_bad+=" a force-stop android_sh never ran (97): want RC=1 FAILED=1 ARGV=, got '$lc_cl_out';"
  lc_cl_out=$(lc_cl_run home works works cut)
  [[ "$lc_cl_out" == "RC=1 FAILED=1 ARGV=" ]] \
    || lc_cl_bad+=" a pre-launch dump cut before its DONE: want RC=1 FAILED=1 ARGV=, got '$lc_cl_out';"
  lc_cl_out=$(lc_cl_run home works works nodump)
  [[ "$lc_cl_out" == "RC=1 FAILED=1 ARGV=" ]] \
    || lc_cl_bad+=" a pre-launch read that is no activity dump: want RC=1 FAILED=1 ARGV=, got '$lc_cl_out';"
  # shellcheck disable=SC2046
  lc_cl_out=$(declare -f $(declare -F | awk '$3 != "cycle_selftest" {print $3}') | grep -E 'rhizo launch|lc_rhizo [0-9 ]*launch' | grep -E '_ACT\b|##\*/' | sed 's/^ *//')
  [[ -z "$lc_cl_out" ]] || lc_cl_bad+=" a claim passes an activity as rhizo launch's argument: $(tr '\n' ' ' <<<"$lc_cl_out");"
  if [[ -z "$lc_cl_bad" ]]; then
    ok "1zg: cli.launch runs rhizo launch with the package alone, as a synthesized entry does, fails when the app never resumes, fails before launching when the force-stop failed, never ran or left the app resumed or its dump is cut or not a dump, and no claim passes rhizo launch an activity"
  else
    bad "1zg:$lc_cl_bad"
  fi
  rm -rf "$lc_cl_fx"
  unset -f lc_cl_run
  unset lc_cl_fx lc_cl_bad lc_cl_out lc_cl_settings lc_cl_home

  lc_cd_fx=$(mktemp -d) || exit 1
  lc_cd_run() {
    (
      FAILED=0 EV="$lc_cd_fx" lc_cd_out="$1" lc_cd_rc="${2:-0}" lc_cd_prof="${3:-desktop}"
      lc_need_guest() { return 0; }
      lc_rhizo() {
        case "$1" in
          doctor) printf '%s\n' "$lc_cd_out"; return "$lc_cd_rc" ;;
          profile) echo "RHIZO_PROFILE profile=$lc_cd_prof" ;;
        esac
      }
      lc_assert_cli.doctor >/dev/null 2>"$lc_cd_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_cd_bad=""
  lc_cd_issues=$'[rhizo] checking this host for Rhizo\'s requirements\n[rhizo]   platform: ok -- Ubuntu 24.04'
  lc_cd_issues+=$'\n[rhizo]   rhizo-deskd.service: fail -- is \'failed\', not active, with androidd.service running'
  lc_cd_issues+=$'\n[rhizo]   rhizo-audiod.service: fail -- is \'failed\', not active, with androidd.service running'
  lc_cd_issues+=$'\n[rhizo]   pipewire-socket: warn -- no pipewire-0 socket for the desktop user\nRHIZO_DOCTOR_ISSUES issues=2 warnings=1'
  lc_cd_out=$(lc_cd_run "$lc_cd_issues")
  [[ "$lc_cd_out" == "RC=1 FAILED=1" ]] || lc_cd_bad+=" a report with issues: want RC=1 FAILED=1, got '$lc_cd_out';"
  grep -q "rhizo-deskd.service: fail -- is 'failed'.*rhizo-audiod.service: fail -- is 'failed'" "$lc_cd_fx/claim.err" \
    || lc_cd_bad+=" the fail does not name each failed check: $(grep FAIL "$lc_cd_fx/claim.err" | head -1);"
  cmp -s <(printf '%s\n' "$lc_cd_issues") <(sed -n '2,$p' "$lc_cd_fx/cli-doctor.txt" 2>/dev/null) \
    || lc_cd_bad+=" \$EV/cli-doctor.txt does not hold doctor's whole report after a failing run;"
  rm -f "$lc_cd_fx/cli-doctor.txt"
  lc_cd_out=$(lc_cd_run $'[rhizo]   platform: ok -- Ubuntu 24.04\nRHIZO_DOCTOR_OK warnings=0')
  [[ "$lc_cd_out" == "RC=0 FAILED=0" ]] || lc_cd_bad+=" a clean report: want RC=0 FAILED=0, got '$lc_cd_out';"
  grep -qx 'RHIZO_DOCTOR_OK warnings=0' "$lc_cd_fx/cli-doctor.txt" 2>/dev/null \
    || lc_cd_bad+=" \$EV/cli-doctor.txt does not hold doctor's report after a passing run;"
  lc_cd_out=$(lc_cd_run $'[rhizo]   platform: ok -- Ubuntu 24.04\nRHIZO_DOCTOR_OK warnings=0' 3)
  [[ "$lc_cd_out" == "RC=1 FAILED=1" ]] && grep -q 'exited 3' "$lc_cd_fx/claim.err" \
    || lc_cd_bad+=" an OK line from a doctor that exited 3: want RC=1 FAILED=1 naming the exit, got '$lc_cd_out' $(grep FAIL "$lc_cd_fx/claim.err" | head -1);"
  lc_cd_server=$'[rhizo]   conntrack: ok -- nf_conntrack loaded\n[rhizo]   adb endpoint: 192.168.100.2:5555\nRHIZO_DOCTOR_OK warnings=0'
  lc_cd_out=$(lc_cd_run "$lc_cd_server" 0 server)
  [[ "$lc_cd_out" == "RC=0 FAILED=0" ]] || lc_cd_bad+=" a clean server report: want RC=0 FAILED=0, got '$lc_cd_out' $(grep FAIL "$lc_cd_fx/claim.err" | head -1);"
  lc_cd_out=$(lc_cd_run "$lc_cd_server" 124 server)
  [[ "$lc_cd_out" == "RC=1 FAILED=1" ]] && grep -q 'exited 124' "$lc_cd_fx/claim.err" \
    || lc_cd_bad+=" an OK server report whose ssh timed out (124): want RC=1 FAILED=1 naming the exit, got '$lc_cd_out' $(grep FAIL "$lc_cd_fx/claim.err" | head -1);"
  lc_cd_server=$'[rhizo]   conntrack: ok -- nf_conntrack loaded\n[rhizo]   adb endpoint: 192.168.100.2:5555'
  lc_cd_server+=$'\n[rhizo]   rhizo-server-idle.service: fail -- is \'failed\'\nRHIZO_DOCTOR_ISSUES issues=1 warnings=0'
  for lc_cd_case in "0 server" "124 server" "124 desktop"; do
    lc_cd_out=$(lc_cd_run "$lc_cd_server" $lc_cd_case)
    [[ "$lc_cd_out" == "RC=1 FAILED=1" ]] && grep -q "rhizo-server-idle.service: fail -- is 'failed'" "$lc_cd_fx/claim.err" \
      || lc_cd_bad+=" an ISSUES report (exit/profile $lc_cd_case): want RC=1 FAILED=1 naming the failed check, got '$lc_cd_out' $(grep FAIL "$lc_cd_fx/claim.err" | head -1);"
  done
  if [[ -z "$lc_cd_bad" ]]; then
    ok "1zh: cli.doctor saves doctor's whole report to \$EV/cli-doctor.txt on a pass and a fail, its fail names each failed check whatever doctor's exit, and an OK line from a doctor that exited nonzero fails on desktop and server"
  else
    bad "1zh:$lc_cd_bad"
  fi
  rm -rf "$lc_cd_fx"
  unset -f lc_cd_run
  unset lc_cd_fx lc_cd_bad lc_cd_out lc_cd_issues lc_cd_server lc_cd_case

  lc_cs_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_cs_fx/bin"
  printf '#!/bin/bash\nfor d in $(ls "$LC_CS_GUEST/proc" | sort -n); do\n  tr "\\0" " " < "$LC_CS_GUEST/proc/$d/cmdline" | grep -q "init second_stage" && echo "$d"\ndone\nexit 0\n' \
    > "$lc_cs_fx/bin/pgrep"
  chmod +x "$lc_cs_fx/bin/pgrep"
  lc_cs_guest() {
    rm -rf "$lc_cs_fx/guest"; mkdir -p "$lc_cs_fx/guest/proc" "$lc_cs_fx/guest/root"
    local a
    for a in "$@"; do
      case "$a" in
        pidfile=*) printf '%s\n' "${a#pidfile=}" > "$lc_cs_fx/guest/root/.rhizo_init_pid" ;;
        pidfile-1=*) printf '%s\n' "${a#pidfile-1=}" > "$lc_cs_fx/guest/root/.rhizo_init_pid-1" ;;
        *) local pid=${a%%:*} cg=/rhizo/init
           [[ "$pid" == *@* ]] && { cg=${pid#*@}; pid=${pid%%@*}; }
           mkdir -p "$lc_cs_fx/guest/proc/$pid"; printf '%s' "${a#*:}" | tr ' ' '\0' > "$lc_cs_fx/guest/proc/$pid/cmdline"
           printf '0::%s\n' "$cg" > "$lc_cs_fx/guest/proc/$pid/cgroup" ;;
      esac
    done
  }
  lc_cs_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      FAILED=0 INIT=111
      lc_need_guest() { return 0; }
      ssh_vm() {
        local body="${*: -1}"
        case "$body" in
          *'is-active androidd.service'*) printf 'inactive\nDONE\n' ;;
          'systemctl stop androidd.service') ;;
          *) body=${body//\/proc\//$lc_cs_fx/guest/proc/}; body=${body//\/root\//$lc_cs_fx/guest/root/}
             LC_CS_GUEST="$lc_cs_fx/guest" PATH="$lc_cs_fx/bin:$PATH" bash -c "$body" ;;
        esac
        return 0
      }
      lc_rhizo() { echo "RHIZO_STARTED"; }
      lc_unit_active() { return 0; }
      guest_uptime() { echo 100.5; }
      wait_sandbox_started() { return 0; }
      sleep() { SECONDS=$(( SECONDS + ${1%%[!0-9]*} )); }
      lc_assert_cli.start >/dev/null 2>/dev/null
      echo "RC=$? FAILED=$FAILED INIT=$INIT"
    )
  }
  lc_cs_bad=""
  lc_cs_guest "222:/system/bin/init second_stage" "230:/system/bin/init second_stage" pidfile=222
  lc_cs_out=$(lc_cs_run)
  [[ "$lc_cs_out" == "RC=0 FAILED=0 INIT=222" ]] || lc_cs_bad+=" a start whose new init resolves: want RC=0 FAILED=0 INIT=222, got '$lc_cs_out';"
  lc_cs_guest "150@/rhizo-1/init:/system/bin/init second_stage" "222:/system/bin/init second_stage" \
    "230:/system/bin/init second_stage" pidfile=222 pidfile-1=150
  lc_cs_out=$(lc_cs_run)
  [[ "$lc_cs_out" == "RC=0 FAILED=0 INIT=222" ]] \
    || lc_cs_bad+=" androidd@1's init at a lower pid: want RC=0 FAILED=0 INIT=222 (androidd.service's own), got '$lc_cs_out';"
  lc_cs_guest "150@/rhizo-1/init:/system/bin/init second_stage" pidfile-1=150
  lc_cs_out=$(lc_cs_run)
  [[ "$lc_cs_out" == "RC=1 FAILED=1 INIT=" ]] \
    || lc_cs_bad+=" only androidd@1's init running: want RC=1 FAILED=1 INIT=, got '$lc_cs_out';"
  lc_cs_guest "150@/rhizo-1/init:/system/bin/init second_stage" pidfile=111 pidfile-1=150
  lc_cs_out=$(lc_cs_run)
  [[ "$lc_cs_out" == "RC=1 FAILED=1 INIT=" ]] \
    || lc_cs_bad+=" a recorded init pid that is gone: want RC=1 FAILED=1 INIT=, got '$lc_cs_out';"
  lc_cs_guest "150@/rhizo-1/init:/system/bin/init second_stage" "300:/usr/sbin/sshd -D" pidfile=300 pidfile-1=150
  lc_cs_out=$(lc_cs_run)
  [[ "$lc_cs_out" == "RC=1 FAILED=1 INIT=" ]] \
    || lc_cs_bad+=" a recorded init pid reused by sshd: want RC=1 FAILED=1 INIT=, got '$lc_cs_out';"
  lc_cs_guest "222@/user.slice/user-1000.slice/session-3.scope:/system/bin/init second_stage" pidfile=222
  lc_cs_out=$(lc_cs_run)
  [[ "$lc_cs_out" == "RC=1 FAILED=1 INIT=" ]] \
    || lc_cs_bad+=" a recorded pid naming a stand-in outside the stack: want RC=1 FAILED=1 INIT=, got '$lc_cs_out';"
  lc_cs_guest
  lc_cs_out=$(lc_cs_run)
  [[ "$lc_cs_out" == "RC=1 FAILED=1 INIT=" ]] || lc_cs_bad+=" a start whose new init never resolves: want RC=1 FAILED=1 INIT=, got '$lc_cs_out';"
  if [[ -z "$lc_cs_bad" ]]; then
    ok "1zi: cli.start leaves INIT naming the init androidd.service's own start recorded, not androidd@1's older init at a lower pid, and empty with a fail when no live init is recorded, the record is outdated, names a non-init or a stand-in outside the stack"
  else
    bad "1zi:$lc_cs_bad"
  fi
  rm -rf "$lc_cs_fx"
  unset -f lc_cs_run lc_cs_guest
  unset lc_cs_bad lc_cs_out lc_cs_fx

  lc_na_fx=$(mktemp -d) || exit 1
  lc_na_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=.MainActivity lc_na_fires="$2"
      rm -f "$lc_na_fx/activated" "$lc_na_fx/posted"; echo 1000 > "$lc_na_fx/now"
      printf '[00:00:01] notification 0|com.rhizo.deskapp|3|null|10123 -> desktop id 11\n[00:00:02] notification 12 activated (default)\n' > "$lc_na_fx/deskd.log"
      lc_need_guest() { return 0; }
      nonce() { echo 5eed; }
      ssh_vm() { shift 2; bash -c "${1//\/var\/log\/rhizo\/rhizo-deskd.log/$lc_na_fx/deskd.log}"; }
      android_sh() {
        case "$2" in
          'dumpsys activity activities')
            printf '  topResumedActivity=ActivityRecord{a1 u0 android/com.android.internal.app.ResolverActivity t1}\n'
            printf '  topResumedActivity=ActivityRecord{b2 u0 com.rhizo.deskapp/.MainActivity t9}\n' ;;
          'logcat -d -b all')
            [[ "$lc_na_fires" == deaf ]] && return 98
            echo 'I RhizoDesk: RHIZO_NOTIF_ACTIVATED title=rhizo-activate-0ld'
            echo 'I RhizoDesk: RHIZO_NOTIF_ACTIVATED'
            [[ -e "$lc_na_fx/activated" ]] && echo "I RhizoDesk: RHIZO_NOTIF_ACTIVATED title=$(<"$lc_na_fx/activated")" ;;
        esac
        return 0
      }
      _lc_desktop_notify_post_via_desk() {
        printf '%s' "$1" > "$lc_na_fx/posted"
        _LC_DESKTOP_NOTIFY_OFF=$(stat -c%s "$lc_na_fx/deskd.log")
        echo '[00:00:03] notification 0|com.rhizo.deskapp|3|null|10123 -> desktop id 12' >> "$lc_na_fx/deskd.log"
        _LC_DESKTOP_NOTIFY_ID=7 _LC_DESKTOP_NOTIFY_AID=3
      }
      desk_notifications() {
        [[ "$1" == activate ]] || return 0
        [[ "$2" == 7 && "${3:-}" == default ]] || return 1
        case "$lc_na_fires" in
          js-error)
            echo 'notifications: org.gnome.gjs.JSError.Error: notification ext-5: the shell took no click on it' >&2
            return 1 ;;
          own) cp "$lc_na_fx/posted" "$lc_na_fx/activated"; echo '[00:00:04] notification 12 activated (default)' >> "$lc_na_fx/deskd.log" ;;
          app-only|earlier) cp "$lc_na_fx/posted" "$lc_na_fx/activated" ;;
          other-key) cp "$lc_na_fx/posted" "$lc_na_fx/activated"; echo '[00:00:04] notification 12 activated (Open)' >> "$lc_na_fx/deskd.log" ;;
          other) printf 'rhizo-icon-9999' > "$lc_na_fx/activated"; echo '[00:00:04] notification 12 activated (default)' >> "$lc_na_fx/deskd.log" ;;
          deaf) echo '[00:00:04] notification 12 activated (default)' >> "$lc_na_fx/deskd.log" ;;
        esac
        return 0
      }
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_na_fx/now"); echo $(( n + 10 )) > "$lc_na_fx/now"; echo "$n"
      }
      sleep() { :; }
      "lc_assert_$1" >/dev/null 2>"$lc_na_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_na_bad=""
  lc_na_claim=desktop.notifications-activation
  lc_na_out=$(lc_na_run "$lc_na_claim" own)
  [[ "$lc_na_out" == "RC=0 FAILED=0" ]] \
    || lc_na_bad+=" $lc_na_claim, its own notification activated: want RC=0 FAILED=0, got '$lc_na_out' $(grep FAIL "$lc_na_fx/claim.err" | head -1);"
  for lc_na_case in \
      "none|rhizo-deskd never logged 'notification 12 activated (default)'" \
      "other|never logged RHIZO_NOTIF_ACTIVATED title=" \
      "deaf|never logged RHIZO_NOTIF_ACTIVATED title=" \
      "app-only|rhizo-deskd never logged 'notification 12 activated (default)'" \
      "earlier|rhizo-deskd never logged 'notification 12 activated (default)'" \
      "other-key|rhizo-deskd never logged 'notification 12 activated (default)'" \
      "js-error|org.gnome.gjs.JSError.Error: notification ext-5: the shell took no click on it"; do
    lc_na_fires=${lc_na_case%%|*} lc_na_want=${lc_na_case#*|}
    lc_na_out=$(lc_na_run "$lc_na_claim" "$lc_na_fires")
    { [[ "$lc_na_out" == "RC=1 FAILED=1" ]] && grep -qF -- "$lc_na_want" "$lc_na_fx/claim.err"; } \
      || lc_na_bad+=" $lc_na_claim, activation '$lc_na_fires': want RC=1 FAILED=1 naming '$lc_na_want', got '$lc_na_out' $(grep FAIL "$lc_na_fx/claim.err" | head -1);"
  done
  if [[ -z "$lc_na_bad" ]]; then
    ok "1zj: notifications-activation passes only on rhizo-deskd's own 'activated (default)' past the click for this post's desktop id and RHIZO_NOTIF_ACTIVATED carrying its own posted title, and fails by name on no activation, another notification firing, a logcat that reads nothing, the app's token with no deskd event, deskd's event for another key or from before the click, and the harness's own error carried whole"
  else
    bad "1zj:$lc_na_bad"
  fi
  rm -rf "$lc_na_fx"
  unset -f lc_na_run
  unset lc_na_fx lc_na_bad lc_na_out lc_na_claim lc_na_fires lc_na_case lc_na_want

  lc_nr_fx=$(mktemp -d) || exit 1
  lc_nr_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=.MainActivity lc_nr_mode="$1"
      rm -f "$lc_nr_fx/posted" "$lc_nr_fx/reply" "$lc_nr_fx/activated" "$lc_nr_fx/replied" "$lc_nr_fx/seen"
      echo 1000 > "$lc_nr_fx/now"
      printf '[00:00:02] notification 12 activated (default)\n' > "$lc_nr_fx/deskd.log"
      ssh_vm() { shift 2; bash -c "${1//\/var\/log\/rhizo\/rhizo-deskd.log/$lc_nr_fx/deskd.log}"; }
      lc_need_guest() { return 0; }
      nonce() { echo 5eed; }
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_nr_fx/now"); echo $(( n + 10 )) > "$lc_nr_fx/now"; echo "$n"
      }
      sleep() { :; }
      android_sh() {
        [[ "$2" == 'logcat -d -b all' ]] || return 0
        [[ "$lc_nr_mode" == deaf ]] && return 98
        if [[ "$lc_nr_mode" == deaf-after-click && -e "$lc_nr_fx/activated" ]]; then
          [[ -e "$lc_nr_fx/seen" ]] && return 98
          touch "$lc_nr_fx/seen"
        fi
        echo 'I RhizoDeskApp: RHIZO_NOTIF_REPLY_POSTED title=rhizo-reply-0ld remote_inputs=1'
        echo 'I RhizoDeskApp: RHIZO_NOTIF_ACTIVATED title=rhizo-reply-0ld'
        if [[ -e "$lc_nr_fx/reply" ]]; then
          local n=1; [[ "$lc_nr_mode" == no-remote-input ]] && n=0
          echo "I RhizoDeskApp: RHIZO_NOTIF_REPLY_POSTED title=$(<"$lc_nr_fx/posted") remote_inputs=$n"
        fi
        [[ -e "$lc_nr_fx/activated" ]] && echo "I RhizoDeskApp: RHIZO_NOTIF_ACTIVATED title=$(<"$lc_nr_fx/activated")"
        [[ -e "$lc_nr_fx/replied" ]] && echo "I RhizoDeskApp: RHIZO_NOTIF_REPLIED title=$(<"$lc_nr_fx/replied") b64="
        return 0
      }
      _lc_desktop_notify_post_via_desk() {
        printf '%s' "$1" > "$lc_nr_fx/posted"
        [[ "${3:-}" == reply ]] && touch "$lc_nr_fx/reply"
        local d=true; [[ "$lc_nr_mode" == no-default ]] && d=false; [[ "$lc_nr_mode" == unknown-default ]] && d=null
        _LC_DESKTOP_NOTIFY_OFF=$(stat -c%s "$lc_nr_fx/deskd.log")
        echo '[00:00:03] notification 0|com.rhizo.deskapp|5|null|10123 -> desktop id 12' >> "$lc_nr_fx/deskd.log"
        _LC_DESKTOP_NOTIFY_ID=9 _LC_DESKTOP_NOTIFY_AID=5
        _LC_DESKTOP_NOTIFY_REC="{\"id\": \"9\", \"title\": \"$1\", \"body\": \"rhizo-notify-body\", \"has_default_action\": $d}"
      }
      desk_notifications() {
        [[ "$1" == activate && "$2" == 9 && "$lc_nr_mode" != refused ]] || return 1
        [[ "${3:-}" == default ]] || return 0
        [[ "$lc_nr_mode" == fires-nothing || "$lc_nr_mode" == app-only ]] \
          || echo '[00:00:04] notification 12 activated (default)' >> "$lc_nr_fx/deskd.log"
        case "$lc_nr_mode" in
          fires-nothing) : ;;
          fires-other) printf 'rhizo-reply-0ld' > "$lc_nr_fx/activated" ;;
          fires-reply) cp "$lc_nr_fx/posted" "$lc_nr_fx/replied" ;;
          fires-both) cp "$lc_nr_fx/posted" "$lc_nr_fx/activated"; cp "$lc_nr_fx/posted" "$lc_nr_fx/replied" ;;
          *) cp "$lc_nr_fx/posted" "$lc_nr_fx/activated" ;;
        esac
        return 0
      }
      lc_assert_desktop.notifications-inline-reply-fallback >/dev/null 2>"$lc_nr_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_nr_bad=""
  lc_nr_out=$(lc_nr_run clicked)
  [[ "$lc_nr_out" == "RC=0 FAILED=0" ]] \
    || lc_nr_bad+=" a click opening the conversation: want RC=0 FAILED=0, got '$lc_nr_out' $(grep FAIL "$lc_nr_fx/claim.err" | head -1);"
  lc_nr_out=$(lc_nr_run unknown-default)
  [[ "$lc_nr_out" == "RC=0 FAILED=0" ]] \
    || lc_nr_bad+=" a click opening the conversation from a record whose default action the desktop cannot report: want RC=0 FAILED=0, got '$lc_nr_out' $(grep FAIL "$lc_nr_fx/claim.err" | head -1);"
  for lc_nr_case in \
      "no-remote-input|never logged RHIZO_NOTIF_REPLY_POSTED title=rhizo-reply-5eed with a RemoteInput" \
      "no-default|offers no default action (has_default_action=False)" \
      "refused|did not take a click on notification 9" \
      "fires-nothing|rhizo-deskd never logged 'notification 12 activated (default)'" \
      "app-only|rhizo-deskd never logged 'notification 12 activated (default)'" \
      "fires-other|never logged RHIZO_NOTIF_ACTIVATED title=rhizo-reply-5eed" \
      "fires-reply|never logged RHIZO_NOTIF_ACTIVATED title=rhizo-reply-5eed" \
      "fires-both|fired its RemoteInput reply's own PendingIntent (RHIZO_NOTIF_REPLIED title=rhizo-reply-5eed)" \
      "deaf|never logged RHIZO_NOTIF_REPLY_POSTED title=rhizo-reply-5eed" \
      "deaf-after-click|the logcat read after the click (rc 98)"; do
    lc_nr_mode=${lc_nr_case%%|*} lc_nr_want=${lc_nr_case#*|}
    lc_nr_out=$(lc_nr_run "$lc_nr_mode")
    { [[ "$lc_nr_out" == "RC=1 FAILED=1" ]] && grep -qF -- "$lc_nr_want" "$lc_nr_fx/claim.err"; } \
      || lc_nr_bad+=" '$lc_nr_mode': want RC=1 FAILED=1 naming '$lc_nr_want', got '$lc_nr_out' $(grep FAIL "$lc_nr_fx/claim.err" | head -1);"
  done
  if [[ -z "$lc_nr_bad" ]]; then
    ok "1zx: notifications-inline-reply-fallback passes only when a click with the declared key default, which rhizo-deskd logs as activated (default) for this post, opens the RemoteInput-carrying conversation it posted through its contentIntent, a record with an unreportable default action among them, and fails by name on no RemoteInput, no default action, a refused click, a click firing nothing, another notification or the reply, no deskd event, and a logcat deaf before the post or after the click"
  else
    bad "1zx:$lc_nr_bad"
  fi
  rm -rf "$lc_nr_fx"
  unset -f lc_nr_run
  unset lc_nr_fx lc_nr_bad lc_nr_out lc_nr_case lc_nr_mode lc_nr_want

  lc_ci_fx=$(mktemp -d) || exit 1
  lc_ci_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=.MainActivity TEST_STEP=ci lc_ci_mode="$1"
      EV="$lc_ci_fx/ev" WORKDIR="$lc_ci_fx/wd"
      rm -rf "$EV" "$WORKDIR" "$lc_ci_fx/logcat" "$lc_ci_fx/host.b64"; mkdir -p "$EV" "$WORKDIR"
      echo 1000 > "$lc_ci_fx/now"
      make_png "$lc_ci_fx/old.png" 1 2 3
      base64 -w0 < "$lc_ci_fx/old.png" > "$lc_ci_fx/android.b64"
      printf '[00:00:01] clip composer -> android: image/png, %s bytes\n' "$(stat -c%s "$lc_ci_fx/old.png")" > "$lc_ci_fx/deskd.log"
      lc_need_guest() { return 0; }
      nonce() { echo 5eed5eed5eed; }
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_ci_fx/now"); echo $(( n + 1 )) > "$lc_ci_fx/now"; echo "$n"
      }
      sleep() { :; }
      ssh_vm() { shift 2; bash -c "${1//\/var\/log\/rhizo\/rhizo-deskd.log/$lc_ci_fx/deskd.log}"; }
      android_sh() {
        case "$2" in
          'logcat -d -b all') cat "$lc_ci_fx/logcat" 2>/dev/null ;;
          *'--es cmd clip_write --es mime image/png --es b64 '*)
            printf '%s' "${2##* }" > "$lc_ci_fx/host.b64"
            echo 'I RhizoDeskApp: RHIZO_CLIP_WROTE mime=image/png' >> "$lc_ci_fx/logcat" ;;
        esac
        return 0
      }
      clip_read() {
        local b; b=$(<"$lc_ci_fx/android.b64")
        echo "I RhizoDeskApp: RHIZO_CLIP_READ mime=image/png b64=$b" >> "$lc_ci_fx/logcat"
        printf 'RHIZO_CLIP_READ mime=image/png b64=%s' "$b"
      }
      desk_clipboard() {
        case "$1" in
          set)
            if [[ "$lc_ci_mode" == set-refused ]]; then
              echo "mutter never took the pad's selection within 10s"; return 1
            fi
            [[ "$lc_ci_mode" == no-relay ]] && return 0
            printf '%s' "$3" > "$lc_ci_fx/android.b64"
            printf '[00:00:05] clip composer -> android: image/png, %s bytes\n' "$(printf '%s' "$3" | base64 -d | wc -c)" >> "$lc_ci_fx/deskd.log"
            return 0 ;;
          focus-rhizo) return 0 ;;
          mark) echo 0 ;;
          get) cat "$lc_ci_fx/host.b64" ;;
        esac
      }
      lc_assert_desktop.clipboard-images >/dev/null 2>"$lc_ci_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_ci_bad=""
  lc_ci_out=$(lc_ci_run ok)
  [[ "$lc_ci_out" == "RC=0 FAILED=0" ]] \
    || lc_ci_bad+=" a set deskd relayed and the app read: want RC=0 FAILED=0, got '$lc_ci_out' $(grep FAIL "$lc_ci_fx/claim.err" | head -1);"
  for lc_ci_case in \
      "set-refused|mutter never took the pad's selection within 10s" \
      "set-refused|rhizo-deskd never relayed the host's image/png" \
      "no-relay|rhizo-deskd never relayed the host's image/png"; do
    lc_ci_mode=${lc_ci_case%%|*} lc_ci_want=${lc_ci_case#*|}
    lc_ci_out=$(lc_ci_run "$lc_ci_mode")
    { [[ "$lc_ci_out" == "RC=1 FAILED=1" ]] && grep -qF -- "$lc_ci_want" "$lc_ci_fx/claim.err"; } \
      || lc_ci_bad+=" '$lc_ci_mode': want RC=1 FAILED=1 naming '$lc_ci_want', got '$lc_ci_out' $(grep FAIL "$lc_ci_fx/claim.err" | head -1);"
  done
  if [[ -z "$lc_ci_bad" ]]; then
    ok "1zci: clipboard-images reads the app's image only after rhizo-deskd relays this set's own image/png, by size past the set, and fails by name, the set's own refusal carried, when mutter never took the set or deskd never relayed it while Android still held an earlier round's image"
  else
    bad "1zci:$lc_ci_bad"
  fi
  rm -rf "$lc_ci_fx"
  unset -f lc_ci_run
  unset lc_ci_fx lc_ci_bad lc_ci_out lc_ci_case lc_ci_mode lc_ci_want

  lc_cb_fx=$(mktemp -d) || exit 1
  lc_cb_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=.MainActivity TEST_STEP=cb lc_cb_mode="$1"
      EV="$lc_cb_fx/ev" WORKDIR="$lc_cb_fx/wd"
      rm -rf "$EV" "$WORKDIR" "$lc_cb_fx/logcat" "$lc_cb_fx/host.b64" "$lc_cb_fx/pending.b64"
      mkdir -p "$EV" "$WORKDIR"
      printf 'clip set-ok cid=1\n' > "$lc_cb_fx/ctl.out"
      echo 1000 > "$lc_cb_fx/now"
      printf 'rhizo-control-9494e39371bd9ea39855995e' | base64 -w0 > "$lc_cb_fx/android.b64"
      printf '[00:00:01] clip composer -> android: text/plain, 38 bytes\n' > "$lc_cb_fx/deskd.log"
      lc_need_guest() { return 0; }
      nonce() { echo 3ab3e28679d1b3f41407ee67; }
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_cb_fx/now"); echo $(( n + 1 )) > "$lc_cb_fx/now"; echo "$n"
      }
      sleep() { :; }
      logcat_since_marker() { echo '09-27 23:50:30.000'; }
      desk_log_offset() { stat -c%s "$lc_cb_fx/deskd.log"; }
      ssh_vm() {
        shift 2
        if [[ "$1" == *'tail -c +'* && -s "$lc_cb_fx/pending.b64" && "$lc_cb_mode" != no-relay ]]; then
          cp "$lc_cb_fx/pending.b64" "$lc_cb_fx/android.b64"
          printf '[00:00:05] clip composer -> android: text/plain, %s bytes\n' \
            "$(base64 -d < "$lc_cb_fx/pending.b64" | wc -c)" >> "$lc_cb_fx/deskd.log"
          : > "$lc_cb_fx/pending.b64"
        fi
        bash -c "${1//\/var\/log\/rhizo\/rhizo-deskd.log/$lc_cb_fx/deskd.log}"
      }
      android_sh() {
        case "$2" in
          'logcat -d -b all') cat "$lc_cb_fx/logcat" 2>/dev/null ;;
          *'--es cmd clip_write --es mime text/plain --es b64 '*)
            printf '%s' "${2##* }" > "$lc_cb_fx/host.b64"
            echo 'I RhizoDeskApp: RHIZO_CLIP_WROTE mime=text/plain' >> "$lc_cb_fx/logcat"
            [[ "$lc_cb_mode" == no-setok ]] || echo 'clip set-ok cid=2' >> "$lc_cb_fx/ctl.out" ;;
        esac
        return 0
      }
      _dnd_ctl_lines() { wc -l < "$lc_cb_fx/ctl.out"; }
      _dnd_ctl_read() { shift; "${@:1:$(( $# - 1 ))}" "$lc_cb_fx/ctl.out"; }
      clip_read() {
        local b; b=$(<"$lc_cb_fx/android.b64")
        echo "I RhizoDeskApp: RHIZO_CLIP_READ mime=text/plain b64=$b" >> "$lc_cb_fx/logcat"
        printf 'RHIZO_CLIP_READ mime=text/plain b64=%s' "$b"
      }
      desk_clipboard() {
        case "$1" in
          set) printf '%s' "$3" > "$lc_cb_fx/pending.b64"; return 0 ;;
          focus-rhizo) return 0 ;;
          mark) echo 0 ;;
          get) cat "$lc_cb_fx/host.b64" ;;
        esac
      }
      lc_assert_desktop.clipboard-both-ways >/dev/null 2>"$lc_cb_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_cb_bad=""
  lc_cb_out=$(lc_cb_run late)
  [[ "$lc_cb_out" == "RC=0 FAILED=0" ]] \
    || lc_cb_bad+=" a set deskd relayed after the claim first looked: want RC=0 FAILED=0, got '$lc_cb_out' $(grep FAIL "$lc_cb_fx/claim.err" | head -1);"
  lc_cb_out=$(lc_cb_run no-relay)
  { [[ "$lc_cb_out" == "RC=1 FAILED=1" ]] \
      && grep -qF -- "rhizo-deskd never relayed the host's text/plain (34 bytes)" "$lc_cb_fx/claim.err"; } \
    || lc_cb_bad+=" 'no-relay': want RC=1 FAILED=1 naming the missing relay, got '$lc_cb_out' $(grep FAIL "$lc_cb_fx/claim.err" | head -1);"
  lc_cb_out=$(lc_cb_run no-setok)
  { [[ "$lc_cb_out" == "RC=1 FAILED=1" ]] \
      && grep -qF -- "the composer never acknowledged the app's clip" "$lc_cb_fx/claim.err"; } \
    || lc_cb_bad+=" 'no-setok': want RC=1 FAILED=1 naming the missing set-ok, got '$lc_cb_out' $(grep FAIL "$lc_cb_fx/claim.err" | head -1);"
  if [[ -z "$lc_cb_bad" ]]; then
    ok "1zcb: clipboard-both-ways reads the app's text only after rhizo-deskd relays this set's own text/plain, by length past the set, and fails by name when deskd never relays it while Android still holds the last leg's clip, or when the composer never acks the app's clip"
  else
    bad "1zcb:$lc_cb_bad"
  fi
  rm -rf "$lc_cb_fx"
  unset -f lc_cb_run
  unset lc_cb_fx lc_cb_bad lc_cb_out

  lc_np_fx=$(mktemp -d) || exit 1
  lc_np_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=.MainActivity EV="$lc_np_fx" TEST_STEP=np
      lc_np_mode="$2"
      rm -f "$lc_np_fx/granted" "$lc_np_fx/posted" "$lc_np_fx/activated" "$lc_np_fx/sink" "$lc_np_fx/reply"
      echo 1000 > "$lc_np_fx/now"
      lc_need_guest() { return 0; }
      nonce() { echo 5eed; }
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_np_fx/now"); echo $(( n + 1 )) > "$lc_np_fx/now"; echo "$n"
      }
      sleep() { :; }
      android_sh() {
        case "$2" in
          'pm grant com.rhizo.deskapp android.permission.POST_NOTIFICATIONS')
            [[ "$lc_np_mode" == grant-refused ]] || touch "$lc_np_fx/granted" ;;
          'dumpsys package com.rhizo.deskapp')
            [[ "$lc_np_mode" == dumpsys-deaf ]] && return 98
            printf 'Packages:\n  Package [com.rhizo.deskapp] (1a2b):\n    requested permissions:\n      android.permission.POST_NOTIFICATIONS\n'
            printf '    User 0: ceDataInode=1 installed=true\n      runtime permissions:\n'
            if [[ -e "$lc_np_fx/granted" ]]; then
              printf '        android.permission.POST_NOTIFICATIONS: granted=true, flags=[ USER_SET ]\n'
            else
              printf '        android.permission.POST_NOTIFICATIONS: granted=false, flags=[ USER_SENSITIVE_WHEN_GRANTED ]\n'
            fi ;;
          *'--es cmd notify --es title '*)
            [[ "$2" == *' --ez reply true'* ]] && touch "$lc_np_fx/reply"
            local t="${2#*--es title }"; t="${t%% *}"
            printf '%s' "$t" > "$lc_np_fx/posted"
            [[ -e "$lc_np_fx/granted" && "$lc_np_mode" != nms-suppressed && -e "$lc_np_fx/sink" ]] \
              && [[ "$lc_np_mode" != bridge-refused && "$lc_np_mode" != bridge-silent ]] \
              && cp "$lc_np_fx/posted" "$lc_np_fx/delivered" ;;
          'cmd notification list')
            printf '0|android|17|null|1000\n0|com.rhizo.deskapp|1|null|10077\n'
            [[ -e "$lc_np_fx/posted" && -e "$lc_np_fx/granted" && "$lc_np_mode" != nms-suppressed ]] \
              && printf '0|com.rhizo.deskapp|77|null|10077\n' ;;
          'logcat -d -b all')
            echo 'I RhizoDesk: RHIZO_NOTIF_POSTED id=76 title=rhizo-old-0'
            [[ -e "$lc_np_fx/posted" ]] && echo "I RhizoDesk: RHIZO_NOTIF_POSTED id=77 title=$(<"$lc_np_fx/posted")"
            [[ -e "$lc_np_fx/reply" ]] && echo "I RhizoDesk: RHIZO_NOTIF_REPLY_POSTED title=$(<"$lc_np_fx/posted") remote_inputs=1"
            [[ -e "$lc_np_fx/activated" ]] && echo "I RhizoDesk: RHIZO_NOTIF_ACTIVATED title=$(<"$lc_np_fx/activated")" ;;
        esac
        return 0
      }
      ssh_vm() {
        local body="${*: -1}"
        case "$body" in
          *'stat -c%s /var/log/rhizo/rhizo-deskd.log'*) echo 4096 ;;
          *'tail -c +4097 /var/log/rhizo/rhizo-deskd.log'*)
            echo '[08:01:02] clip android -> host: text/plain, 12 bytes'
            [[ "$lc_np_mode" == bridge-refused ]] \
              && echo '[08:01:30] desktop refused the notification from com.rhizo.deskapp: org.freedesktop.DBus.Error.ServiceUnknown: The name org.freedesktop.Notifications was not provided by any .service files'
            [[ -e "$lc_np_fx/delivered" ]] && echo '[08:01:31] notification 0|com.rhizo.deskapp|77|null|10077 -> desktop id 12'
            [[ -e "$lc_np_fx/activated" ]] && echo '[08:01:40] notification 12 activated (default)'
            [[ "$body" == *'; echo DONE'* ]] && echo DONE
            : ;;
        esac
        return 0
      }
      desk_notifications() {
        case "$1" in
          list)
            [[ "$lc_np_mode" == desk-down ]] && return 1
            touch "$lc_np_fx/sink"
            echo '{"id": "3", "source": "rhizo-com.rhizo.deskapp", "title": "rhizo-old-0", "body": "", "has_default_action": true}'
            [[ -e "$lc_np_fx/delivered" ]] \
              && echo "{\"id\": \"9\", \"source\": \"rhizo-com.rhizo.deskapp\", \"title\": \"$(<"$lc_np_fx/delivered")\", \"body\": \"rhizo-notify-body\", \"has_default_action\": true}"
            return 0 ;;
          activate)
            [[ "$2" == 9 && "${3:-}" == default ]] || return 1
            cp "$lc_np_fx/delivered" "$lc_np_fx/activated"; return 0 ;;
        esac
      }
      rm -f "$lc_np_fx/delivered"
      "lc_assert_$1" >/dev/null 2>"$lc_np_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_np_bad=""
  for lc_np_claim in desktop.notifications-activation desktop.notifications-inline-reply-fallback; do
    lc_np_out=$(lc_np_run "$lc_np_claim" good)
    [[ "$lc_np_out" == "RC=0 FAILED=0" ]] \
      || lc_np_bad+=" $lc_np_claim, a fixture that may post and a desktop that is up: want RC=0 FAILED=0, got '$lc_np_out' $(grep FAIL "$lc_np_fx/claim.err" | head -1);"
    for lc_np_case in \
        "grant-refused|does not hold POST_NOTIFICATIONS" \
        "dumpsys-deaf|dumpsys package com.rhizo.deskapp read nothing" \
        "nms-suppressed|NotificationManagerService never listed com.rhizo.deskapp's notification 77" \
        "desk-down|the desktop's notification service did not answer before the post" \
        "bridge-refused|desktop refused the notification from com.rhizo.deskapp" \
        "bridge-silent|no line naming it"; do
      lc_np_mode=${lc_np_case%%|*} lc_np_want=${lc_np_case#*|}
      lc_np_out=$(lc_np_run "$lc_np_claim" "$lc_np_mode")
      { [[ "$lc_np_out" == "RC=1 FAILED=1" ]] && grep -qF -- "$lc_np_want" "$lc_np_fx/claim.err"; } \
        || lc_np_bad+=" $lc_np_claim, guest '$lc_np_mode': want RC=1 FAILED=1 naming '$lc_np_want', got '$lc_np_out' $(grep FAIL "$lc_np_fx/claim.err" | head -1);"
    done
  done
  if [[ -z "$lc_np_bad" ]]; then
    ok "1zu: the notification activation claims post only once the fixture holds POST_NOTIFICATIONS and the desktop's notification service answers, and name the link that broke: a refused grant, a deaf dumpsys, NMS suppressing the post, the desktop down, the desktop refusing it, and the android app never relaying it"
  else
    bad "1zu:$lc_np_bad"
  fi
  rm -rf "$lc_np_fx"
  unset -f lc_np_run
  unset lc_np_fx lc_np_bad lc_np_out lc_np_claim lc_np_case lc_np_mode lc_np_want

  lc_ni_fx=$(mktemp -d) || exit 1
  lc_ni_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=.MainActivity EV="$lc_ni_fx" TEST_STEP=ni
      WORKDIR="$lc_ni_fx" NOTIF_REC=/tmp/rhizo-lifecycle-notif.jsonl NOTIF_FIFO=/tmp/rhizo-lifecycle-notify.fifo
      lc_ni_profile="$1" lc_ni_mode="$2"
      rm -f "$lc_ni_fx/granted" "$lc_ni_fx/posted" "$lc_ni_fx/delivered" "$lc_ni_fx/ev-"*
      echo 1000 > "$lc_ni_fx/now"
      case "$lc_ni_mode" in
        flat) ;;
        wrong-icon) make_png "$lc_ni_fx/icon-0.png" 200 17 99 ;;
        *) make_png "$lc_ni_fx/icon-0.png" 17 200 99 ;;
      esac
      [[ "$lc_ni_mode" != flat ]] || python3 -c '
import struct, sys, zlib
w = h = 16
rows = b"".join(b"\x00" + bytes([9, 9, 9]) * w for _ in range(h))
def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))' "$lc_ni_fx/icon-0.png"
      lc_need_guest() { return 0; }
      nonce() { echo 5eed; }
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_ni_fx/now"); echo $(( n + 1 )) > "$lc_ni_fx/now"; echo "$n"
      }
      sleep() { :; }
      android_sh() {
        case "$2" in
          'pm grant com.rhizo.deskapp android.permission.POST_NOTIFICATIONS')
            [[ "$lc_ni_mode" == grant-refused ]] || touch "$lc_ni_fx/granted" ;;
          'dumpsys package com.rhizo.deskapp')
            printf '      runtime permissions:\n        android.permission.POST_NOTIFICATIONS: granted=%s\n' \
              "$([[ -e "$lc_ni_fx/granted" ]] && echo true || echo false)" ;;
          *'--es cmd notify --es title '*)
            local t="${2#*--es title }"; t="${t%% *}"
            printf '%s' "$t" > "$lc_ni_fx/posted"
            [[ "$2" == *'--es icon_b64 '* && -e "$lc_ni_fx/granted" ]] && cp "$lc_ni_fx/posted" "$lc_ni_fx/delivered" ;;
          'cmd notification list')
            [[ -e "$lc_ni_fx/posted" && -e "$lc_ni_fx/granted" ]] && printf '0|com.rhizo.deskapp|77|null|10077\n' ;;
          'logcat -d -b all')
            [[ -e "$lc_ni_fx/posted" ]] && echo "I RhizoDesk: RHIZO_NOTIF_POSTED id=77 title=$(<"$lc_ni_fx/posted")" ;;
        esac
        return 0
      }
      lc_ni_icon=/tmp/rhizo-notif-icons.q1w2e3/icon-0.png
      ssh_vm() {
        local body="${*: -1}"
        case "$body" in
          *'stat -c%s /var/log/rhizo/rhizo-deskd.log'*) echo 4096 ;;
          *"grep -aF 'rhizo-notif-5eed' $NOTIF_REC"*)
            [[ -e "$lc_ni_fx/delivered" ]] \
              && echo "{\"id\": 9, \"summary\": \"rhizo-notif-5eed\", \"hints\": {\"image-path\": \"$lc_ni_icon\"}}" ;;
        esac
        return 0
      }
      pull() { return 1; }
      notify_sink_start() { [[ "$lc_ni_profile" == sway ]]; }
      notify_sink_stop() { :; }
      desk_user_sh() {
        [[ "$lc_ni_mode" == unreadable ]] && { echo 'base64: /tmp/rhizo-notif-icons.q1w2e3/icon-0.png: Permission denied' >&2; return 1; }
        [[ "$2" == *"$lc_ni_icon"* ]] || return 1
        base64 -w0 < "$lc_ni_fx/icon-0.png"; echo; echo DONE
      }
      desk_notifications() {
        case "$1" in
          list)
            [[ -e "$lc_ni_fx/delivered" ]] || return 0
            local icon="$lc_ni_icon"
            [[ "$lc_ni_mode" == no-icon ]] && icon=""
            echo "{\"id\": \"9\", \"source\": \"rhizo-com.rhizo.deskapp\", \"title\": \"$(<"$lc_ni_fx/delivered")\", \"body\": \"rhizo-notify-body\", \"has_default_action\": true, \"icon\": \"$icon\"}" ;;
        esac
        return 0
      }
      "lc_assert_desktop.notifications-icon" >/dev/null 2>"$lc_ni_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_ni_bad=""
  for lc_ni_profile in sway gnome; do
    lc_ni_out=$(lc_ni_run "$lc_ni_profile" good)
    [[ "$lc_ni_out" == "RC=0 FAILED=0" ]] \
      || lc_ni_bad+=" $lc_ni_profile, the daemon handed the icon and the desktop user reads it: want RC=0 FAILED=0, got '$lc_ni_out' $(grep FAIL "$lc_ni_fx/claim.err" | head -1);"
    [[ "$lc_ni_out" != "RC=0 FAILED=0" ]] || cmp -s "$lc_ni_fx/ni-notification-icon.png" "$lc_ni_fx/icon-0.png" \
      || lc_ni_bad+=" $lc_ni_profile: the icon kept in \$EV is not the bytes the daemon was handed;"
    for lc_ni_case in \
        "grant-refused|does not hold POST_NOTIFICATIONS" \
        "no-icon|carried no icon file" \
        "unreadable|could not read /tmp/rhizo-notif-icons.q1w2e3/icon-0.png" \
        "flat|has only 1 distinct color" \
        "wrong-icon|has mean_r="; do
      lc_ni_mode=${lc_ni_case%%|*} lc_ni_want=${lc_ni_case#*|}
      lc_ni_out=$(lc_ni_run "$lc_ni_profile" "$lc_ni_mode")
      { [[ "$lc_ni_out" == "RC=1 FAILED=1" ]] && grep -qF -- "$lc_ni_want" "$lc_ni_fx/claim.err"; } \
        || lc_ni_bad+=" $lc_ni_profile, guest '$lc_ni_mode': want RC=1 FAILED=1 naming '$lc_ni_want', got '$lc_ni_out' $(grep FAIL "$lc_ni_fx/claim.err" | head -1);"
      [[ "$(head -1 "$lc_ni_fx/ni-notification-record.json" 2>/dev/null)" == '<none>' || "$lc_ni_mode" != grant-refused ]] \
        || lc_ni_bad+=" $lc_ni_profile, guest '$lc_ni_mode': the record file is not an explicit <none> on the failure path;"
    done
  done
  printf '%s\n' \
    '{"id": 4, "summary": "p", "actions": ["default", "Open"], "hints": {"image-path": "/tmp/rhizo-notif-icons.q1w2e3/icon-3.png", "desktop-entry": "rhizo-com.rhizo.deskapp"}}' \
    '{"id": 5, "summary": "d", "actions": [], "hints": {"image-data": {"file": "5.png", "width": 2, "height": 2}}}' \
    '{"id": 6, "summary": "n", "actions": [], "hints": {}}' > "$lc_ni_fx/sink.jsonl"
  lc_ni_out=$(
    RHIZO_DESKTOP_PROFILE=sway NOTIF_REC=/tmp/rhizo-lifecycle-notif.jsonl
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
    gcmd_user() { case "$1" in *pgrep*) echo 4242 ;; *"cat $NOTIF_REC"*) cat "$lc_ni_fx/sink.jsonl" ;; esac; }
    desk_notifications list | python3 -c 'import json,sys; print(" ".join("%s=%s" % (r["title"], r["icon"] or "-") for r in map(json.loads, sys.stdin)))'
  )
  [[ "$lc_ni_out" == "p=/tmp/rhizo-notif-icons.q1w2e3/icon-3.png d=- n=-" ]] \
    || lc_ni_bad+=" sway's desk_notifications list gave icons '$lc_ni_out', wanted p=<its image-path> d=- n=-;"
  if [[ -z "$lc_ni_bad" ]]; then
    ok "1zv: desktop.notifications-icon passes on either profile on the icon file the desktop's own daemon was handed, read as the desktop user, and fails by name on a refused grant, a notification with no icon, an icon the desktop user cannot read, a one-color icon, and another many-colored icon than the one it posted; sway's list names only an image-path hint's file"
  else
    bad "1zv:$lc_ni_bad"
  fi
  rm -rf "$lc_ni_fx"
  unset -f lc_ni_run
  unset lc_ni_fx lc_ni_bad lc_ni_out lc_ni_profile lc_ni_case lc_ni_mode lc_ni_want

  lc_it_fx=$(mktemp -d) || exit 1
  lc_it_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 INIT=4242 APP_PKG=com.rhizo.deskapp APP_ACT=.MainActivity BRIDGE_PKG=com.rhizo.desktop
      EV="$lc_it_fx" TEST_STEP=it LC_FIXTURE_LABEL="Rhizo Desk Test"
      lc_it_mode="$1"
      rm -f "$lc_it_fx/relay" "$lc_it_fx/h2a" "$lc_it_fx/window-read"; : > "$lc_it_fx/log"; : > "$lc_it_fx/deskd.log"
      [[ "$lc_it_mode" == earlier-control || "$lc_it_mode" == deaf-baseline ]] \
        && echo 'I ClipboardService: Rhizo Desk Test pasted from your clipboard' > "$lc_it_fx/log"
      logcat_since_marker() { android_sh "$1" "date +'%m-%d %H:%M:%S.000'" 2>/dev/null | tr -d '\r' | tail -1; }
      echo 1000 > "$lc_it_fx/now"
      lc_need_guest() { return 0; }
      nonce() { echo 5eed; }
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_it_fx/now"); echo $(( n + 1 )) > "$lc_it_fx/now"; echo "$n"
      }
      sleep() { :; }
      android_sh() {
        local b64
        case "$2" in
          "date +'%m-%d %H:%M:%S.000'") echo '09-26 08:00:00.000' ;;
          'settings get secure default_input_method')
            if [[ "$lc_it_mode" == not-ime ]]; then echo 'com.android.inputmethod.latin/.LatinIME'; else echo 'com.rhizo.desktop/.RhizoIme'; fi ;;
          'settings get secure clipboard_show_access_notifications')
            if [[ "$lc_it_mode" == detector-dead ]]; then echo 0; else echo null; fi ;;
          *'--es cmd clip_write'*)
            b64="${2##* }"
            echo "I RhizoDesk: RHIZO_CLIP_WROTE b64=$b64" >> "$lc_it_fx/log"
            [[ "$lc_it_mode" == relay-lost ]] || printf '%s' "$b64" > "$lc_it_fx/relay"
            [[ "$lc_it_mode" == toast-bug ]] && echo 'I ClipboardService: Rhizo Desktop Bridge pasted from your clipboard' >> "$lc_it_fx/log" ;;
          *'--es cmd clip_read'*)
            if [[ -e "$lc_it_fx/h2a" && "$lc_it_mode" != h2a-lost ]]; then
              echo "I RhizoDesk: RHIZO_CLIP_READ mime=text/plain b64=$(<"$lc_it_fx/h2a")" >> "$lc_it_fx/log"
              [[ "$lc_it_mode" == detector-dead || "$lc_it_mode" == earlier-control || "$lc_it_mode" == deaf-baseline ]] \
                || echo 'I ClipboardService: Rhizo Desk Test pasted from your clipboard' >> "$lc_it_fx/log"
            else
              echo "I RhizoDesk: RHIZO_CLIP_READ mime=text/plain b64=$(<"$lc_it_fx/relay")" >> "$lc_it_fx/log"
            fi ;;
          'logcat -d -b all') cat "$lc_it_fx/log" ;;
          "logcat -d -b all -t '09-26 08:00:00.000'")
            if [[ "$lc_it_mode" == deaf-baseline && ! -e "$lc_it_fx/window-read" ]]; then
              touch "$lc_it_fx/window-read"; return 98
            fi
            touch "$lc_it_fx/window-read"; cat "$lc_it_fx/log" ;;
          'logcat -d -b system -m 2')
            if [[ "$lc_it_mode" == rotated ]]; then
              echo '09-26 08:00:30.412  1066  1101 I ActivityManager: rotated past the marker'
            else
              printf -- '--------- beginning of system\n09-26 07:41:02.118   226   226 I SystemServer: Entered the Android system server!\n'
            fi ;;
        esac
        return 0
      }
      desk_clipboard() {
        case "$1" in
          get) [[ -e "$lc_it_fx/relay" ]] && cat "$lc_it_fx/relay"; return 0 ;;
          set)
            printf '%s' "$3" > "$lc_it_fx/h2a"
            [[ "$lc_it_mode" == ctrl-relay-lost ]] \
              || printf ' clip composer -> android: text/plain, %s bytes\n' "$(base64 -d <<<"$3" | wc -c)" >> "$lc_it_fx/deskd.log"
            return 0 ;;
        esac
      }
      desk_log_offset() { stat -c%s "$lc_it_fx/deskd.log" 2>/dev/null || echo 0; }
      ssh_vm() { shift 2; bash -c "${1//\/var\/log\/rhizo\/rhizo-deskd.log/$lc_it_fx/deskd.log}"; }
      "lc_assert_desktop.ime-no-toast" >/dev/null 2>"$lc_it_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_it_bad=""
  lc_it_out=$(lc_it_run good)
  [[ "$lc_it_out" == "RC=0 FAILED=0" ]] \
    || lc_it_bad+=" the android app's relay logged no toast and the fixture's read of the android app's clip did: want RC=0 FAILED=0, got '$lc_it_out' $(grep FAIL "$lc_it_fx/claim.err" | head -1);"
  grep -qF 'Rhizo Desk Test pasted from your clipboard' "$lc_it_fx/it-ime-toast-log.txt" 2>/dev/null \
    || lc_it_bad+=" the good run kept no ClipboardService line in \$EV;"
  for lc_it_case in \
      "toast-bug|Rhizo Desktop Bridge pasted from your clipboard" \
      "detector-dead|clipboard_show_access_notifications=0" \
      "earlier-control|logged no new 'Rhizo Desk Test pasted from your clipboard'" \
      "deaf-baseline|does not hold this run's own RHIZO_CLIP_WROTE" \
      "rotated|oldest entry is" \
      "relay-lost|never received the android app's relay" \
      "not-ime|not the android app's own IME" \
      "h2a-lost|the positive control's host clip never reached the app" \
      "ctrl-relay-lost|the positive control's host clip was never relayed"; do
    lc_it_mode=${lc_it_case%%|*} lc_it_want=${lc_it_case#*|}
    lc_it_out=$(lc_it_run "$lc_it_mode")
    { [[ "$lc_it_out" == "RC=1 FAILED=1" ]] && grep -qF -- "$lc_it_want" "$lc_it_fx/claim.err"; } \
      || lc_it_bad+=" guest '$lc_it_mode': want RC=1 FAILED=1 naming '$lc_it_want', got '$lc_it_out' $(grep FAIL "$lc_it_fx/claim.err" | head -1);"
  done
  if [[ -z "$lc_it_bad" ]]; then
    ok "1zw: desktop.ime-no-toast passes when ClipboardService logs no access line for the android app's default-IME relay and does log one for the focused fixture reading the android app's clip, and fails by name on a line during the relay, a dead detector, a dead detector behind an earlier claim's line, a relay window read that answered nothing, a system log that rotated past the marker, a lost relay, an android app that is not the default IME, a positive control whose host clip never arrived, and one deskd never relayed at all"
  else
    bad "1zw:$lc_it_bad"
  fi
  rm -rf "$lc_it_fx"
  unset -f lc_it_run
  unset lc_it_fx lc_it_bad lc_it_out lc_it_case lc_it_mode lc_it_want

  lc_cb_fx=$(mktemp -d) || exit 1
  lc_cb_run() {
    (
      rm -rf "$lc_cb_fx/g"; mkdir -p "$lc_cb_fx/g/usr/deskbridge" "$lc_cb_fx/g/share" "$lc_cb_fx/g/tmp"
      case "$1" in
        usr)   echo packaged > "$lc_cb_fx/g/usr/deskbridge/rhizo-wlbridge" ;;
        share) echo staged > "$lc_cb_fx/g/share/rhizo-wlbridge" ;;
      esac
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 CLIP_FIFO=/tmp/rhizo-clip.fifo
      gcmd_root() { bash -c "$(sed -e "s#/tmp/rhizo-#$lc_cb_fx/g/tmp/rhizo-#g" -e "s#/usr/lib/rhizo#$lc_cb_fx/g/usr#g" \
                                   -e "s#/root/share#$lc_cb_fx/g/share#g" <<<"$1")"; }
      gcmd_user() { return 0; }
      wait_guest() { return 0; }
      clip_start >/dev/null 2>"$lc_cb_fx/claim.err"
      echo "RC=$? STAGED=$(cat "$lc_cb_fx/g/tmp/rhizo-wlbridge-test" 2>/dev/null)"
    )
  }
  lc_cb_bad=""
  lc_cb_out=$(lc_cb_run usr)
  [[ "$lc_cb_out" == "RC=0 STAGED=packaged" ]] || lc_cb_bad+=" a packaged host: want RC=0 STAGED=packaged, got '$lc_cb_out' $(head -1 "$lc_cb_fx/claim.err");"
  lc_cb_out=$(lc_cb_run share)
  [[ "$lc_cb_out" == "RC=0 STAGED=staged" ]] || lc_cb_bad+=" a rig with only /root/share: want RC=0 STAGED=staged, got '$lc_cb_out' $(head -1 "$lc_cb_fx/claim.err");"
  lc_cb_out=$(lc_cb_run none)
  { [[ "$lc_cb_out" == "RC=1 STAGED=" ]] && grep -q 'could not stage the system test.s own clipboard client from any of' "$lc_cb_fx/claim.err"; } \
    || lc_cb_bad+=" a guest with neither: want RC=1 naming the sources tried, got '$lc_cb_out' $(head -1 "$lc_cb_fx/claim.err");"
  if [[ -z "$lc_cb_bad" ]]; then
    ok "1zk: clip_start stages the clipboard client from the deb's own rhizo-wlbridge, from /root/share on a rig with only that, and fails naming both when neither exists"
  else
    bad "1zk:$lc_cb_bad"
  fi
  rm -rf "$lc_cb_fx"
  unset -f lc_cb_run
  unset lc_cb_fx lc_cb_bad lc_cb_out

  lc_gc_fx=$(mktemp -d) || exit 1
  lc_gc_run() {
    local pad_focus="$1"; shift
    (
      : > "$lc_gc_fx/clip.out"; : > "$lc_gc_fx/actions"; echo "" > "$lc_gc_fx/sel"
      RHIZO_DESKTOP_PROFILE=gnome
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 CLIP_FIFO=/tmp/rhizo-clip.fifo APP_PKG=com.rhizo.deskapp INIT=4242
      gcmd_user() { [[ "$1" == *pgrep* ]] && return 0; bash -c "$(sed "s#/tmp/rhizo-clip.out#$lc_gc_fx/clip.out#g" <<<"$1")" 2>/dev/null; }
      clip_start() { echo start >> "$lc_gc_fx/actions"; }
      _gnome_harness() { echo "harness $1" >> "$lc_gc_fx/actions"; }
      desk_windows() {
        printf '%s\n' '{"id": 3, "app_id": "rhizo", "title": "Rhizo", "x": 0, "y": 32, "w": 1280, "h": 768, "focused": false}' \
          '{"id": 5, "app_id": "rhizo-com.rhizo.deskapp", "title": "Rhizo Desk Test", "x": 0, "y": 32, "w": 1280, "h": 768, "focused": true}'
        grep -q '^dragpad on$' "$lc_gc_fx/actions" \
          && echo '{"id": 7, "app_id": "rhizo-dragpad", "title": "rhizo-dragpad", "x": 22, "y": 49, "w": 64, "h": 64, "focused": false}'
      }
      desk_window_op() {
        echo "activate $1" >> "$lc_gc_fx/actions"
        if [[ "$1" == 7 && "$pad_focus" == yes ]]; then
          echo "focus pad" >> "$lc_gc_fx/clip.out"
          [[ -s "$lc_gc_fx/sel" ]] && echo "selection $(cat "$lc_gc_fx/sel")" >> "$lc_gc_fx/clip.out"
        fi
        return 0
      }
      clipcmd() {
        echo "$1" >> "$lc_gc_fx/actions"
        case "$1" in
          "dragpad on") echo padmapped >> "$lc_gc_fx/clip.out" ;;
          "set "*)
            if grep -q '^focus pad$' "$lc_gc_fx/clip.out"; then
              local m; m=$(cut -d' ' -f2 <<<"$1"); echo "${m//,/ }" > "$lc_gc_fx/sel"
              echo "selection none" >> "$lc_gc_fx/clip.out"
              echo "selection $(tr ',' '\n' <<<"$m" | tac | tr '\n' ' ' | sed 's/ $//')" >> "$lc_gc_fx/clip.out"
            else
              echo "error the pad does not hold keyboard focus, so the compositor would refuse the selection" >> "$lc_gc_fx/clip.out"
            fi ;;
          "get text/plain") echo "data text/plain aG9zdA==" >> "$lc_gc_fx/clip.out" ;;
        esac
      }
      sleep() { :; }
      out=$(desk_clipboard "$@" 2>"$lc_gc_fx/err")
      echo "RC=$? OUT=$out"
    )
  }
  lc_gc_bad=""
  lc_gc_out=$(lc_gc_run yes set text/plain,x-kde-passwordManagerHint aGludA==)
  lc_gc_acts=$(tr '\n' '|' < "$lc_gc_fx/actions")
  [[ "$lc_gc_out" == "RC=0 OUT=" && "$lc_gc_acts" == "start|dragpad on|harness window-op 7 above|activate 7|set text/plain,x-kde-passwordManagerHint aGludA==|activate 5|" ]] \
    || lc_gc_bad+=" set: '$lc_gc_out' did '$lc_gc_acts' $(head -1 "$lc_gc_fx/err"), want the pad focused, both mimes set on it and the app's window focused after;"
  lc_gc_out=$(lc_gc_run no set text/plain aGk=)
  lc_gc_acts=$(tr '\n' '|' < "$lc_gc_fx/actions")
  { [[ "$lc_gc_out" == "RC=1 OUT=" ]] && grep -qF "the pad never got keyboard focus" "$lc_gc_fx/err" && [[ "$lc_gc_acts" != *"|set "* ]]; } \
    || lc_gc_bad+=" set with no pad focus: '$lc_gc_out' did '$lc_gc_acts' $(head -1 "$lc_gc_fx/err"), want a fail naming it and no set sent;"
  lc_gc_out=$(lc_gc_run yes get text/plain 5)
  lc_gc_acts=$(tr '\n' '|' < "$lc_gc_fx/actions")
  [[ "$lc_gc_out" == "RC=0 OUT=aG9zdA==" && "$lc_gc_acts" == *"activate 7|get text/plain|activate 5|" ]] \
    || lc_gc_bad+=" get: '$lc_gc_out' did '$lc_gc_acts' $(head -1 "$lc_gc_fx/err"), want the pad's read bytes and the app's window focused after;"
  if [[ -z "$lc_gc_bad" ]]; then
    ok "1zt: gnome's desk_clipboard sets and reads the host selection through the system test's own pad, focused while it does, needs mutter's echo of a set, leaves the app's window focused, and fails by name when the pad never gets focus"
  else
    bad "1zt:$lc_gc_bad"
  fi

  lc_gd_run() {
    local accept="$1"
    (
      : > "$lc_gc_fx/clip.out"; : > "$lc_gc_fx/actions"
      RHIZO_DESKTOP_PROFILE=gnome
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 CLIP_FIFO=/tmp/rhizo-clip.fifo
      gcmd_user() { [[ "$1" == *pgrep* ]] && return 0; bash -c "$(sed "s#/tmp/rhizo-clip.out#$lc_gc_fx/clip.out#g" <<<"$1")" 2>/dev/null; }
      desk_windows() { echo '{"id": 7, "app_id": "rhizo-dragpad", "title": "rhizo-dragpad", "x": 22, "y": 49, "w": 64, "h": 64}'; }
      clipcmd() {
        echo "$1" >> "$lc_gc_fx/actions"
        case "$1" in "dragarm "*) echo "dragarmed $(cut -d' ' -f2 <<<"$1")" >> "$lc_gc_fx/clip.out" ;; esac
      }
      _gnome_pointer() {
        echo "pointer $1" >> "$lc_gc_fx/actions"
        case "$1" in
          "press 54 81") echo "dragstarted text/plain" >> "$lc_gc_fx/clip.out" ;;
          "moveto 640 416") [[ "$accept" == yes ]] && echo "dragtarget text/plain" >> "$lc_gc_fx/clip.out" ;;
        esac
        return 0
      }
      sleep() { :; }
      out=$(desk_dnd drop 640 416 text/plain ZHJvcA==)
      echo "RC=$? OUT=$out"
    )
  }
  lc_gd_bad=""
  lc_gd_out=$(lc_gd_run yes)
  lc_gd_acts=$(tr '\n' '|' < "$lc_gc_fx/actions")
  [[ "$lc_gd_out" == "RC=0 OUT=" && "$lc_gd_acts" == "dragarm text/plain ZHJvcA==|pointer press 54 81|pointer moveto 640 416|pointer release|" ]] \
    || lc_gd_bad+=" accepted: '$lc_gd_out' did '$lc_gd_acts', want arm, press on the pad's center, carry, release;"
  lc_gd_out=$(lc_gd_run no)
  lc_gd_acts=$(tr '\n' '|' < "$lc_gc_fx/actions")
  { [[ "$lc_gd_out" == "RC=1 OUT="*"never accepted the drag"* ]] && [[ "$lc_gd_acts" == *"pointer moveto 640 416|pointer release|" ]]; } \
    || lc_gd_bad+=" never accepted: '$lc_gd_out' did '$lc_gd_acts', want a fail naming it and the button released;"
  if [[ -z "$lc_gd_bad" ]]; then
    ok "1zu: gnome's desk_dnd drop arms the pad, presses it through the pointer session, and releases over the target only once it accepted -- one it never accepts is named and released"
  else
    bad "1zu:$lc_gd_bad"
  fi
  rm -rf "$lc_gc_fx"
  unset -f lc_gc_run lc_gd_run
  unset lc_gc_fx lc_gc_bad lc_gc_out lc_gc_acts lc_gd_bad lc_gd_out lc_gd_acts

  lc_pp_fx=$(mktemp -d) || exit 1
  lc_pp_run() {
    local lc_pp_answer="$1"
    (
      : > "$lc_pp_fx/clip.out"; : > "$lc_pp_fx/actions"
      RHIZO_DESKTOP_PROFILE=sway
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 CLIP_FIFO=/tmp/rhizo-clip.fifo
      gcmd_user() { [[ "$1" == *pgrep* ]] && { echo 4242; return 0; }; bash -c "$(sed "s#/tmp/rhizo-clip.out#$lc_pp_fx/clip.out#g" <<<"$1")" 2>/dev/null; }
      clipcmd() {
        echo "$1" >> "$lc_pp_fx/actions"
        [[ "$1" == padorigin ]] && echo "$lc_pp_answer" >> "$lc_pp_fx/clip.out"
        return 0
      }
      sleep() { :; }
      out=$(desk_dnd pad-point)
      echo "RC=$? OUT=$out"
    )
  }
  lc_pp_bad=""
  lc_pp_out=$(lc_pp_run "padorigin 3840 0")
  [[ "$lc_pp_out" == "RC=0 OUT=3872 32" && "$(cat "$lc_pp_fx/actions")" == padorigin ]] \
    || lc_pp_bad+=" a pad proven at 3840,0: '$lc_pp_out' after '$(tr '\n' '|' < "$lc_pp_fx/actions")', want 3872 32 from the bridge's own padorigin;"
  lc_pp_out=$(lc_pp_run "error the pointer never entered the drag pad: not at its assumed origin 0,0")
  [[ "$lc_pp_out" == "RC=1 OUT="*"never entered the drag pad"* ]] \
    || lc_pp_bad+=" a bridge that never entered the pad: '$lc_pp_out', want a fail carrying its error;"
  if [[ -z "$lc_pp_bad" ]]; then
    ok "2da: sway's desk_dnd pad-point answers the pad's origin the bridge proved with a real enter, and names the bridge's error when it could not"
  else
    bad "2da:$lc_pp_bad"
  fi
  rm -rf "$lc_pp_fx"
  unset -f lc_pp_run
  unset lc_pp_fx lc_pp_bad lc_pp_out

  lc_wr_run() {
    (
      RHIZO_DESKTOP_PROFILE=sway
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
      lc_wr_x="$1" lc_wr_read="${2:-ok}"
      _desktop_window_for_display() { printf '{"id": 7, "x": %s, "y": 0, "w": 960, "h": 1080}' "$lc_wr_x"; }
      desk_outputs() {
        [[ "$1" == list && "$lc_wr_read" == ok ]] || return 1
        echo '[{"name": "Virtual-1", "active": true, "rect": {"x": 0, "y": 0, "width": 1920, "height": 1080}}, {"name": "HEADLESS-2", "active": false, "rect": {"x": 1920, "y": 0, "width": 1920, "height": 1080}}]'
      }
      out=$(desktop_mapped_window_rect 2 0)
      echo "RC=$? OUT=$out"
    )
  }
  lc_wr_bad=""
  lc_wr_out=$(lc_wr_run 960)
  [[ "$lc_wr_out" == "RC=0 OUT=960 0 960 1080" ]] || lc_wr_bad+=" a window on the output: '$lc_wr_out', want its rect;"
  lc_wr_out=$(lc_wr_run 4800)
  [[ "$lc_wr_out" == "RC=1 OUT="*"4800 0 960 1080"*"no active output"* ]] \
    || lc_wr_bad+=" a window at x=4800 on a 1920-wide output: '$lc_wr_out', want a refusal naming the rect;"
  lc_wr_out=$(lc_wr_run 2400)
  [[ "$lc_wr_out" == "RC=1 OUT="*"no active output"* ]] \
    || lc_wr_bad+=" a window on an inactive output: '$lc_wr_out', want a refusal;"
  lc_wr_out=$(lc_wr_run 960 dead)
  [[ "$lc_wr_out" == "RC=1 OUT="*"outputs did not read"* ]] \
    || lc_wr_bad+=" an outputs read that failed: '$lc_wr_out', want a refusal naming the read;"
  if [[ -z "$lc_wr_bad" ]]; then
    ok "2db: desktop_mapped_window_rect answers a rect whose center is on an active output and refuses, by name, one on none or an unread layout"
  else
    bad "2db:$lc_wr_bad"
  fi
  unset -f lc_wr_run
  unset lc_wr_bad lc_wr_out

  lc_tw_run() {
    (
      RHIZO_DESKTOP_PROFILE=sway
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
      INIT=4242 lc_tw_own="$1" lc_tw_fx=$(mktemp -d)
      : > "$lc_tw_fx/acts"; : > "$lc_tw_fx/ctl"
      sleep() { :; }
      resolve_display_toplevel() { echo "rhizo-com.rhizo.deskapp Rhizo Desk Test"; }
      desk_windows() {
        local f21=false f22=false last; last=$(tail -1 "$lc_tw_fx/acts")
        [[ "$last" == 21 ]] && f21=true; [[ "$last" == 22 ]] && f22=true
        echo "{\"id\": 21, \"app_id\": \"rhizo-com.rhizo.deskapp\", \"title\": \"Rhizo Desk Test\", \"x\": 960, \"y\": 0, \"w\": 960, \"h\": 1080, \"focused\": $f21}"
        echo "{\"id\": 22, \"app_id\": \"rhizo-com.rhizo.deskapp\", \"title\": \"Rhizo Desk Test\", \"x\": 100, \"y\": 0, \"w\": 960, \"h\": 1080, \"focused\": $f22}"
      }
      desk_window_op() { cat > /dev/null; [[ "$2" == activate ]] && echo "$1" >> "$lc_tw_fx/acts"; return 0; }
      desk_outputs() { echo '[{"name": "Virtual-1", "active": true, "rect": {"x": 0, "y": 0, "width": 1920, "height": 1080}}]'; }
      rhizo_ctl() {
        local a=0; [[ "$(tail -1 "$lc_tw_fx/acts")" == "$lc_tw_own" ]] && a=1
        echo "display toplevel id=$4 app_id=rhizo-com.rhizo.deskapp maximized=0 fullscreen=0 activated=$a resizing=0 scale=1 output=Virtual-1 title=Rhizo Desk Test" >> "$lc_tw_fx/ctl"
      }
      _dnd_ctl_lines() { wc -l < "$lc_tw_fx/ctl"; }
      _dnd_ctl_read() {
        shift; local -a argv=("$@") i
        for i in "${!argv[@]}"; do [[ "${argv[$i]}" == /data/rhizo_control/control.out ]] && argv[$i]="$lc_tw_fx/ctl"; done
        "${argv[@]}"
      }
      out=$(desktop_activate_display_window 3 0); rc=$?
      rect=$(desktop_mapped_window_rect 3 0)
      echo "RC=$rc ACT=$(tr '\n' ',' < "$lc_tw_fx/acts") RECT=$rect OUT=$out"
      rm -rf "$lc_tw_fx"
    )
  }
  lc_tw_bad=""
  lc_tw_out=$(lc_tw_run 22)
  [[ "$lc_tw_out" == "RC=0 ACT="*"22, RECT=100 0 960 1080 OUT=" ]] \
    || lc_tw_bad+=" display 3's window listed second behind display 2's twin: '$lc_tw_out', want 22 activated last and its rect;"
  lc_tw_out=$(lc_tw_run 21)
  [[ "$lc_tw_out" == "RC=0 ACT=21, RECT=960 0 960 1080 OUT=" ]] \
    || lc_tw_bad+=" display 3's window listed first: '$lc_tw_out', want 21 alone activated and its rect;"
  lc_tw_out=$(lc_tw_run none)
  [[ "$lc_tw_out" == "RC=1 "*"OUT="*"display 3"* ]] \
    || lc_tw_bad+=" no twin the composer calls display 3's: '$lc_tw_out', want a refusal naming the display;"
  if [[ -z "$lc_tw_bad" ]]; then
    ok "2dba: desktop_activate_display_window picks, among windows sharing one app's identity, the one the composer reports activated for that display, and the rect read after is that window's"
  else
    bad "2dba:$lc_tw_bad"
  fi
  unset -f lc_tw_run
  unset lc_tw_bad lc_tw_out

  lc_ts_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
      INIT=4242 lc_ts_mode="$1" lc_ts_fx=$(mktemp -d)
      echo "display toplevel id=3 app_id=rhizo-com.rhizo.deskapp maximized=0 fullscreen=0 activated=1 resizing=0 scale=1 output=Virtual-1 title=Rhizo Desk Test" \
        > "$lc_ts_fx/ctl"
      sleep() { :; }
      _dnd_ctl_lines() { wc -l < "$lc_ts_fx/ctl"; }
      _dnd_ctl_read() {
        shift; local -a argv=("$@") i
        for i in "${!argv[@]}"; do [[ "${argv[$i]}" == /data/rhizo_control/control.out ]] && argv[$i]="$lc_ts_fx/ctl"; done
        "${argv[@]}"
      }
      rhizo_ctl() {
        local a=0; [[ "$lc_ts_mode" == live ]] && a=1
        echo "display toplevel id=3 app_id=rhizo-com.rhizo.deskapp maximized=0 fullscreen=0 activated=$a resizing=0 scale=1 output=Virtual-1 title=Rhizo Desk Test" \
          >> "$lc_ts_fx/ctl"
      }
      _display_toplevel_activated 3 </dev/null; rc=$?
      echo "RC=$rc"
      rm -rf "$lc_ts_fx"
    )
  }
  lc_ts_bad=""
  lc_ts_out=$(lc_ts_run dead)
  [[ "$lc_ts_out" == "RC=1" ]] \
    || lc_ts_bad+=" an earlier activated=1 already in control.out before the baseline passed a raise the composer never answered: '$lc_ts_out';"
  lc_ts_out=$(lc_ts_run live)
  [[ "$lc_ts_out" == "RC=0" ]] \
    || lc_ts_bad+=" an activated=1 appended past the baseline did not pass: '$lc_ts_out';"
  if [[ -z "$lc_ts_bad" ]]; then
    ok "2dbb: _display_toplevel_activated's baseline is control.out's own line count taken right before each request"
  else
    bad "2dbb:$lc_ts_bad"
  fi
  unset -f lc_ts_run
  unset lc_ts_bad lc_ts_out

  lc_lo_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-lib.sh" >/dev/null 2>&1
      INIT=4242 lc_lo_mode="$1" lc_lo_fx=$(mktemp -d)
      : > "$lc_lo_fx/acts"; : > "$lc_lo_fx/ctl"
      sleep() { :; }
      resolve_display_toplevel() { echo "rhizo-com.rhizo.deskapp Rhizo Desk Test"; }
      desk_windows() {
        echo '{"id": 31, "app_id": "rhizo-com.rhizo.deskapp", "title": "Rhizo Desk Test", "x": 0, "y": 32, "w": 1280, "h": 768, "focused": false}'
      }
      desk_window_op() { cat > /dev/null; [[ "$2" == activate ]] && echo "$1" >> "$lc_lo_fx/acts"; return 0; }
      rhizo_ctl() {
        local a=0; [[ "$lc_lo_mode" == yes ]] && a=1
        echo "display toplevel id=4 app_id=rhizo-com.rhizo.deskapp maximized=1 fullscreen=0 activated=$a resizing=0 scale=1 output=Virtual-1 title=Rhizo Desk Test" >> "$lc_lo_fx/ctl"
      }
      _dnd_ctl_lines() { wc -l < "$lc_lo_fx/ctl"; }
      _dnd_ctl_read() {
        shift; local -a argv=("$@") i
        for i in "${!argv[@]}"; do [[ "${argv[$i]}" == /data/rhizo_control/control.out ]] && argv[$i]="$lc_lo_fx/ctl"; done
        "${argv[@]}"
      }
      desktop_activate_display_window 4 0 >/dev/null; rc=$?
      echo "RC=$rc ACT=$(grep -c . "$lc_lo_fx/acts")"
      rm -rf "$lc_lo_fx"
    )
  }
  lc_lo_bad=""
  lc_lo_out=$(lc_lo_run no)
  [[ "$lc_lo_out" == "RC=1 ACT=1" ]] \
    || lc_lo_bad+=" a lone window the composer never activates did not fail after being raised once: '$lc_lo_out', want RC=1 with exactly one activate call;"
  lc_lo_out=$(lc_lo_run yes)
  [[ "$lc_lo_out" == "RC=0 ACT=1" ]] \
    || lc_lo_bad+=" a lone window the composer does activate did not pass: '$lc_lo_out';"
  if [[ -z "$lc_lo_bad" ]]; then
    ok "2dbc: desktop_activate_display_window proves even a lone window's own activation through _display_toplevel_activated"
  else
    bad "2dbc:$lc_lo_bad"
  fi
  unset -f lc_lo_run
  unset lc_lo_bad lc_lo_out

  lc_wu_run() {
    (
      FAILED=0 APP_PKG=com.rhizo.deskapp APP_ACT=com.rhizo.deskapp.MainActivity lc_wu_mode="$1"
      lc_wu_fx=$(mktemp -d); : > "$lc_wu_fx/order"
      lc_need_guest() { return 0; }
      ssh_vm() {
        case "${*: -1}" in
          *'wc -l < /run/rhizo-launch/rhizo-launch.log'*) echo 0 ;;
          *'rhizo-launch.sh com.rhizo.deskapp'*) echo rc=0 ;;
          *'tail -n +1 /run/rhizo-launch/rhizo-launch.log'*) echo 'event=am_start_return pid=1 cdisplay=9' ;;
        esac
      }
      desk_windows() { echo '{"id": 9, "app_id": "rhizo-com.rhizo.deskapp", "w": 1280, "h": 768}'; }
      resolve_display_toplevel() { echo "rhizo-com.rhizo.deskapp Rhizo Desk Test"; }
      desktop_activate_display_window() {
        echo "activate $1" >> "$lc_wu_fx/order"
        [[ "$lc_wu_mode" == ok ]] || { echo "activating display $1's window failed"; return 1; }
      }
      assert_window_painted() { echo "paint $2" >> "$lc_wu_fx/order"; }
      desktop_close_all_app_windows() { echo "close $2" >> "$lc_wu_fx/order"; }
      lc_assert_desktop.windows-usable >/dev/null 2>"$lc_wu_fx/err"
      echo "RC=$? FAILED=$FAILED ORDER=$(tr '\n' ',' < "$lc_wu_fx/order")"
      rm -rf "$lc_wu_fx"
    )
  }
  lc_wu_bad=""
  lc_wu_out=$(lc_wu_run ok)
  [[ "$lc_wu_out" == "RC=0 FAILED=0 ORDER=close rhizo-com.rhizo.deskapp,activate 9,paint 9," ]] \
    || lc_wu_bad+=" a raise that succeeds did not activate before painting: '$lc_wu_out';"
  lc_wu_out=$(lc_wu_run fail)
  [[ "$lc_wu_out" == "RC=1 FAILED=1 ORDER=close rhizo-com.rhizo.deskapp,activate 9," ]] \
    || lc_wu_bad+=" a raise that fails still reached assert_window_painted, or failed wrong: '$lc_wu_out';"
  if [[ -z "$lc_wu_bad" ]]; then
    ok "2dbd: desktop.windows-usable raises the display's own window before sampling whether it painted, and never samples at all when the raise fails"
  else
    bad "2dbd:$lc_wu_bad"
  fi
  unset -f lc_wu_run
  unset lc_wu_bad lc_wu_out

  lc_ac_fx=$(mktemp -d) || exit 1
  lc_ac_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 lc_ac_ok="$2"
      : > "$lc_ac_fx/actions"; echo 1000 > "$lc_ac_fx/now"
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_ac_fx/now"); echo $(( n + 50 )) > "$lc_ac_fx/now"; echo "$n"
      }
      sleep() { :; }
      nonce() { echo 5eed; }
      desktop_activate_display_window() { echo "activate $1" >> "$lc_ac_fx/actions"; [[ "$lc_ac_ok" == ok ]] || { echo "activating display $1's window failed"; return 1; }; }
      desktop_mapped_window_rect() { echo "rect $1" >> "$lc_ac_fx/actions"; echo "0 0 100 100"; }
      desk_dnd() { echo "dnd $*" >> "$lc_ac_fx/actions"; [[ "$1" == pad-point ]] && echo "32 32"; return 0; }
      desktop_dnd_evidence() { :; }
      logcat_since_marker() { echo '09-26 08:00:00.000'; }
      desk_log_offset() { echo 0; }
      _dnd_ctl_lines() { echo 3; }
      _dnd_ctl_read() { :; }
      android_sh() { return 0; }
      app_wait_token() { return 1; }
      clip_mark() { echo 0; }
      clip_await() { return 1; }
      ssh_vm() { return 0; }
      gcmd_user() { return 0; }
      if [[ "$1" == drop ]]; then
        desktop_assert_dnd_drop_onto_app 4242 2 "$lc_ac_fx" >/dev/null 2>"$lc_ac_fx/err"
      else
        desktop_assert_dnd_drag_out_of_app 4242 com.rhizo.deskapp .MainActivity 2 "$lc_ac_fx" >/dev/null 2>"$lc_ac_fx/err"
      fi
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_ac_bad=""
  for lc_ac_leg in drop dragout; do
    lc_ac_run "$lc_ac_leg" ok >/dev/null
    lc_ac_acts=$(tr '\n' '|' < "$lc_ac_fx/actions")
    [[ "$lc_ac_acts" == *"activate 2|rect 2|"* && "$lc_ac_acts" != *"dnd press"*"activate 2|rect 2|"* ]] \
      || lc_ac_bad+=" $lc_ac_leg: did '$lc_ac_acts', want display 2's window activated right before its rect is read;"
    lc_ac_out=$(lc_ac_run "$lc_ac_leg" no)
    lc_ac_acts=$(tr '\n' '|' < "$lc_ac_fx/actions")
    { [[ "$lc_ac_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "activating display 2's window failed" "$lc_ac_fx/err" \
        && [[ "$lc_ac_acts" != *"dnd drop"* && "$lc_ac_acts" != *"dnd press"* ]]; } \
      || lc_ac_bad+=" $lc_ac_leg with no activation: '$lc_ac_out' did '$lc_ac_acts' $(grep FAIL "$lc_ac_fx/err" | head -1), want a fail naming it and nothing pressed;"
  done
  if [[ -z "$lc_ac_bad" ]]; then
    ok "2dc: the drop and drag-out legs activate the target display's own window before reading its rect, and fail by name, pressing nothing, when it cannot be activated"
  else
    bad "2dc:$lc_ac_bad"
  fi
  rm -rf "$lc_ac_fx"
  unset -f lc_ac_run
  unset lc_ac_fx lc_ac_bad lc_ac_out lc_ac_acts lc_ac_leg

  lc_la_fx=$(mktemp -d) || exit 1
  lc_la_run() {
    (
      FAILED=0 APP_PKG=com.rhizo.deskapp LC_ENTRY_PATH=/usr/share/applications/rhizo-com.rhizo.deskapp.desktop
      EV="$lc_la_fx" lc_la_ctl_raised="$1" lc_la_reply="$2" lc_la_applied="$3" lc_la_raised="$4" lc_la_launch="${5:-ok}"
      : > "$lc_la_fx/actions"; echo none > "$lc_la_fx/leg"; echo 1000 > "$lc_la_fx/now"
      date() {
        [[ "${1:-}" == +%s ]] || { command date "$@"; return; }
        local n; n=$(<"$lc_la_fx/now"); echo $(( n + 10 )) > "$lc_la_fx/now"; echo "$n"
      }
      sleep() { :; }
      lc_need_guest() { return 0; }
      lc_resolve_init() { echo 4242; }
      desktop_close_all_app_windows() { echo close >> "$lc_la_fx/actions"; }
      desktop_focus_holder_up() { echo holder-up >> "$lc_la_fx/actions"; }
      desktop_focus_holder_down() { echo holder-down >> "$lc_la_fx/actions"; }
      logcat_since_marker() { echo '09-27 02:00:00.000'; }
      _dnd_ctl_lines() { echo 10; }
      ssh_vm() {
        case "${*: -1}" in
          *'wc -l'*) echo 10 ;;
          *'tail -n +11'*)
            case "$(<"$lc_la_fx/leg")" in
              control) echo "1.0 event=am_start_return pid=77 pkg=com.rhizo.deskapp activity=.MainActivity display=5 cdisplay=5 bus=none" ;;
              token) echo "2.0 event=am_start_return pid=78 pkg=com.rhizo.deskapp activity=.MainActivity display=2 cdisplay=2 bus=none" ;;
            esac ;;
        esac
        return 0
      }
      desk_launch_entry() {
        echo "launch $*" >> "$lc_la_fx/actions"
        [[ "$1" == "done" ]] && return 0
        if [[ "${2:-}" == --no-token ]]; then
          echo control > "$lc_la_fx/leg"; echo "launched token=none pid=77"; return 0
        fi
        echo token > "$lc_la_fx/leg"
        [[ "$lc_la_launch" == ok ]] || { echo "launch-failed the launch context gave the entry no activation token"; return 1; }
        echo "launched token=t pid=78"
      }
      desk_windows() {
        local f=false leg; leg=$(<"$lc_la_fx/leg")
        [[ "$leg" == control && "$lc_la_ctl_raised" == yes ]] && f=true
        [[ "$leg" == token && "$lc_la_raised" == yes ]] && f=true
        echo "{\"id\": 18, \"app_id\": \"rhizo-com.rhizo.deskapp\", \"title\": \"x\", \"w\": 960, \"h\": 1080, \"focused\": $f}"
      }
      _dnd_ctl_read() { [[ "$lc_la_reply" == none ]] || echo "$lc_la_reply"; }
      logcat_vm() {
        [[ "$lc_la_applied" == yes ]] && echo "09-27 02:00:03.000 131 143 I rhizo-wayland-backend: WaylandBackend::PresentFrame: display 2 mapped, activated with its held token=t"
        return 0
      }
      lc_assert_applifecycle.launch-activates-window >/dev/null 2>"$lc_la_fx/err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_la_bad=""
  lc_la_out=$(lc_la_run no "display activate-held id=2" yes yes)
  [[ "$lc_la_out" == "RC=0 FAILED=0" && "$(grep -c '^launch /usr' "$lc_la_fx/actions")" == 2 && "$(grep -c '^launch done' "$lc_la_fx/actions")" == 2 ]] \
    || lc_la_bad+=" an unraised control, a held token applied on the launch's display and the window focused: '$lc_la_out' did '$(tr '\n' '|' < "$lc_la_fx/actions")' $(grep FAIL "$lc_la_fx/err" | head -1), want a pass with both launches and the launcher closed after each;"
  [[ "$(grep -c '^holder-up$' "$lc_la_fx/actions")" == 2 && "$(grep -m1 -n -e '^holder-up$' -e '^launch /usr' "$lc_la_fx/actions")" == *holder-up && "$(tail -1 "$lc_la_fx/actions")" == holder-down ]] \
    || lc_la_bad+=" the focus holder: did '$(tr '\n' '|' < "$lc_la_fx/actions")', want holder-up before each launch and holder-down last;"
  grep -q -- "--no-token" "$lc_la_fx/actions" || lc_la_bad+=" no control launch ran with --no-token;"
  lc_la_out=$(lc_la_run no "display activated id=2" no yes)
  [[ "$lc_la_out" == "RC=0 FAILED=0" ]] \
    || lc_la_bad+=" an immediate activation of the launch's display with the window focused: '$lc_la_out' $(grep FAIL "$lc_la_fx/err" | head -1), want a pass;"
  lc_la_out=$(lc_la_run yes "display activate-held id=2" yes yes)
  [[ "$lc_la_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "the control launch with no token left" "$lc_la_fx/err" \
    || lc_la_bad+=" a compositor that focuses a new window on map: '$lc_la_out', want a fail naming the control;"
  lc_la_out=$(lc_la_run no "display activated id=9" yes yes)
  [[ "$lc_la_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "for the launch's display 2" "$lc_la_fx/err" \
    || lc_la_bad+=" another display's activate reply: '$lc_la_out', want a fail naming the launch's display;"
  lc_la_out=$(lc_la_run no "display activate-held id=2" no yes)
  [[ "$lc_la_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "never logged activating with it" "$lc_la_fx/err" \
    || lc_la_bad+=" a held token never applied: '$lc_la_out', want a fail naming it;"
  lc_la_out=$(lc_la_run no "display activate-failed id=2 reason=refused" no yes)
  [[ "$lc_la_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "refused the launch's token" "$lc_la_fx/err" \
    || lc_la_bad+=" a refused token: '$lc_la_out', want a fail naming the refusal;"
  lc_la_out=$(lc_la_run no "display activate-held id=2" yes no)
  [[ "$lc_la_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "neither focused nor urgent" "$lc_la_fx/err" \
    || lc_la_bad+=" an applied token and an unraised window: '$lc_la_out', want a fail naming the window;"
  lc_la_out=$(lc_la_run no "display activate-held id=2" yes yes no)
  [[ "$lc_la_out" == "RC=1 FAILED="[1-9]* ]] && grep -qF "gave the entry no activation token" "$lc_la_fx/err" && [[ "$(tail -2 "$lc_la_fx/actions" | tr '\n' '|')" == "launch done|holder-down|" ]] \
    || lc_la_bad+=" a token launch that got no token: '$lc_la_out', want a fail carrying the launcher's line, the launcher closed and the focus holder stopped;"
  if [[ -z "$lc_la_bad" ]]; then
    ok "2de: applifecycle.launch-activates-window passes only past an unraised no-token control, on the composer's own answer for the launch's display and the token applied, with the window then raised, and fails by name on map-time focus, another display's reply, a held token never applied, a refusal, an unraised window or no token"
  else
    bad "2de:$lc_la_bad"
  fi
  rm -rf "$lc_la_fx"
  unset -f lc_la_run
  unset lc_la_fx lc_la_bad lc_la_out

  lc_wd_fx=$(mktemp -d) || exit 1
  lc_wd_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 CLIP_FIFO=/tmp/rhizo-clip.fifo
      printf 'ready\nselection text/plain\ndata text/plain %s\n' "$(printf round-1 | base64 -w0)" > "$lc_wd_fx/clip.out"
      printf round-1 > "$lc_wd_fx/current"
      echo 0 > "$lc_wd_fx/reads"
      gcmd_user() {
        local n; n=$(( $(cat "$lc_wd_fx/reads") + 1 )); echo "$n" > "$lc_wd_fx/reads"
        if (( n == 3 )); then printf round-2 > "$lc_wd_fx/current"; echo "selection text/plain" >> "$lc_wd_fx/clip.out"; fi
        bash -c "$(sed "s#/tmp/rhizo-clip.out#$lc_wd_fx/clip.out#g" <<<"$1")" 2>/dev/null
      }
      clipcmd() {
        [[ "$1" == "get text/plain" ]] && echo "data text/plain $(base64 -w0 < "$lc_wd_fx/current")" >> "$lc_wd_fx/clip.out"
      }
      sleep() { :; }
      local since=""
      [[ "$1" == yes ]] && since=$(clip_mark)
      got=$(clip_wait_data text/plain 20 $since)
      echo "RC=$? GOT=$(base64 -d <<<"$got")"
    )
  }
  lc_wd_bad=""
  lc_wd_out=$(lc_wd_run yes)
  [[ "$lc_wd_out" == "RC=0 GOT=round-2" ]] || lc_wd_bad+=" with a mark: '$lc_wd_out', want the round-2 clip once the selection changed;"
  lc_wd_out=$(lc_wd_run no)
  [[ "$lc_wd_out" == "RC=0 GOT=round-1" && "$(grep -c '^data ' "$lc_wd_fx/clip.out")" == 2 ]] \
    || lc_wd_bad+=" without a mark: '$lc_wd_out', want the answer to its own get, not the earlier line;"
  if [[ -z "$lc_wd_bad" ]]; then
    ok "1zv: clip_wait_data answers from its own get, and with a mark waits for the selection to change after it"
  else
    bad "1zv:$lc_wd_bad"
  fi
  rm -rf "$lc_wd_fx"
  unset -f lc_wd_run
  unset lc_wd_fx lc_wd_bad lc_wd_out

  lc_ur_fx=$(mktemp -d) || exit 1
  lc_ur_run() {
    (
      rm -rf "$lc_ur_fx/g"; mkdir -p "$lc_ur_fx/g/apps" "$lc_ur_fx/g/tmp" "$lc_ur_fx/g/home/.config"
      [[ "$2" == - ]] || printf '%s\n' "$2" > "$lc_ur_fx/g/home/.config/mimeapps.list"
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/desktop-assert-lib.sh"
      FAILED=0 LC_UR_DELIVER="$1"; echo 1000 > "$lc_ur_fx/clock"
      lc_ur_guest() { sed -e "s#/usr/share/applications#$lc_ur_fx/g/apps#g" -e "s#/tmp/rhizo-url#$lc_ur_fx/g/tmp/rhizo-url#g" <<<"$1"; }
      gcmd_root() { bash -c "$(lc_ur_guest "$1")"; }
      gcmd_user() { HOME="$lc_ur_fx/g/home" bash -c "$(lc_ur_guest "$1")"; }
      android_sh() {
        case "$2" in
          *"get-role-holders"*) echo "com.rhizo.desktop" ;;
          *"send_url --es uri "*)
            (( LC_UR_DELIVER )) && "$lc_ur_fx/g/tmp/rhizo-url-record.sh" "${2##* }" ;;
        esac
        return 0
      }
      app_wait_token() { printf 'RHIZO_SENT_VIEW'; }
      date() { local t; t=$(( $(cat "$lc_ur_fx/clock") + 30 )); echo "$t" > "$lc_ur_fx/clock"; echo "$t"; }
      sleep() { :; }
      desktop_assert_link_android_to_host 4242 com.rhizo.selftest com.rhizo.selftest.Main com.rhizo.desktop \
        >/dev/null 2>"$lc_ur_fx/claim.err"
      echo "RC=$? FAILED=$FAILED"
    )
  }
  lc_ur_left() {
    local w=""
    [[ -e "$lc_ur_fx/g/apps/rhizo-url-record.desktop" ]] && w+=" entry"
    [[ -e "$lc_ur_fx/g/tmp/rhizo-url-record.sh" ]] && w+=" script"
    [[ -e "$lc_ur_fx/g/tmp/rhizo-url-received" ]] && w+=" received"
    compgen -G "$lc_ur_fx/g/home/.config/*rhizo-url-record*" >/dev/null && w+=" backup"
    printf '%s' "${w:- none}"
  }
  lc_ur_bad=""
  lc_ur_prior=$'[Default Applications]\nx-scheme-handler/https=firefox_firefox.desktop'
  lc_ur_out=$(lc_ur_run 1 "$lc_ur_prior")
  [[ "$lc_ur_out" == "RC=0 FAILED=0" ]] || lc_ur_bad+=" a delivered link did not pass: '$lc_ur_out' $(head -1 "$lc_ur_fx/claim.err");"
  [[ "$(lc_ur_left)" == " none" ]] || lc_ur_bad+=" a delivered link left:$(lc_ur_left);"
  [[ "$(cat "$lc_ur_fx/g/home/.config/mimeapps.list" 2>/dev/null)" == "$lc_ur_prior" ]] \
    || lc_ur_bad+=" a delivered link did not put the user's own mimeapps.list back;"
  lc_ur_out=$(lc_ur_run 0 -)
  { [[ "$lc_ur_out" == "RC=1 FAILED=1" ]] && grep -q "the host handler received ''" "$lc_ur_fx/claim.err"; } \
    || lc_ur_bad+=" a link that never arrived did not fail by name: '$lc_ur_out' $(head -1 "$lc_ur_fx/claim.err");"
  [[ "$(lc_ur_left)" == " none" ]] || lc_ur_bad+=" a link that never arrived left:$(lc_ur_left);"
  [[ ! -e "$lc_ur_fx/g/home/.config/mimeapps.list" ]] \
    || lc_ur_bad+=" a user with no mimeapps.list before the leg has one after it;"
  if [[ -z "$lc_ur_bad" ]]; then
    ok "1zl: the Android-to-host link leg removes its URL recorder entry and script and restores the user's mimeapps.list, whether the link arrived or not and whether the file existed"
  else
    bad "1zl:$lc_ur_bad"
  fi
  rm -rf "$lc_ur_fx"
  unset -f lc_ur_run lc_ur_left
  unset lc_ur_fx lc_ur_bad lc_ur_out lc_ur_prior

  lc_rs_fx=$(mktemp -d) || exit 1
  lc_rs_run() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/install-lib.sh"
      FAILED=0 LC_RS_ENTRY="$1" INIT=4242 APP_PKG=com.rhizo.selftest APP_ACT=com.rhizo.selftest.Main
      DESK_USER=deskuser LC_ENTRY_PATH=/usr/share/applications/rhizo-com.rhizo.selftest.desktop
      echo 1000 > "$lc_rs_fx/clock"; : > "$lc_rs_fx/stops"; echo active > "$lc_rs_fx/state"
      date() { local t; t=$(( $(cat "$lc_rs_fx/clock") + 30 )); echo "$t" > "$lc_rs_fx/clock"; echo "$t"; }
      sleep() { :; }
      lc_need_guest() { return 0; }
      ssh_vm() {
        local body="${*: -1}"
        case "$body" in
          *"if [ -f '$LC_ENTRY_PATH' ]"*) echo "$LC_RS_ENTRY" ;;
          *"systemctl stop androidd.service"*) echo x >> "$lc_rs_fx/stops"; echo inactive > "$lc_rs_fx/state" ;;
          *"systemctl is-active androidd.service"*) cat "$lc_rs_fx/state" ;;
        esac
        return 0
      }
      user_sh() { echo active > "$lc_rs_fx/state"; printf 'RHIZO_SANDBOX starting=1\nRHIZO_LAUNCHED pkg=%s display=0 cdisplay=1\nrc=0\n' "$APP_PKG"; }
      resolve_init_pid() { echo 5151; }
      case "${LC_RS_AWAKE:-yes}" in
        yes) wait_device_awake() { printf 'mWakefulness=Awake'; return 0; } ;;
        no)  wait_device_awake() { printf 'mWakefulness=Asleep'; return 1; } ;;
      esac
      case "${LC_RS_DUMP:-ontop}" in
        ontop) android_sh() {
                 printf 'Display #2 (activities from top to bottom):\n  * Task{a #9 type=standard A=10076:%s U=0 visible=true sz=1}\n    topResumedActivity=ActivityRecord{1 u0 %s/%s t9}\nRHIZO_DUMPSYS_RC=0\n' \
                   "$APP_PKG" "$APP_PKG" "$APP_ACT"; } ;;
        empty) android_sh() { return 0; } ;;
        broken) android_sh() { printf "Can't find service: activity\nRHIZO_DUMPSYS_RC=20\n"; } ;;
        unreachable) android_sh() { return 97; } ;;
      esac
      lc_assert_applifecycle.restart-from-user-side >/dev/null 2>"$lc_rs_fx/claim.err"
      echo "RC=$? FAILED=$FAILED STOPS=$(grep -c x "$lc_rs_fx/stops")"
    )
  }
  lc_rs_bad=""
  lc_rs_out=$(lc_rs_run PRESENT)
  [[ "$lc_rs_out" == "RC=0 FAILED=0 STOPS=1" ]] || lc_rs_bad+=" an entry already there did not let the restart pass: '$lc_rs_out' $(head -1 "$lc_rs_fx/claim.err");"
  lc_rs_out=$(lc_rs_run ABSENT)
  { [[ "$lc_rs_out" == "RC=1 FAILED=1 STOPS=0" ]] && grep -q 'did not come back' "$lc_rs_fx/claim.err"; } \
    || lc_rs_bad+=" an entry that never came back did not fail by name before the stop: '$lc_rs_out' $(head -1 "$lc_rs_fx/claim.err");"
  for lc_rs_dump in empty broken unreachable; do
    lc_rs_out=$(LC_RS_DUMP=$lc_rs_dump lc_rs_run PRESENT)
    { [[ "$lc_rs_out" == "RC=1 FAILED=1 STOPS=1" ]] \
        && grep -q 'dumpsys activity activities did not complete' "$lc_rs_fx/claim.err" \
        && ! grep -q 'no topResumedActivity names' "$lc_rs_fx/claim.err"; } \
      || lc_rs_bad+=" a $lc_rs_dump resumed-activity read did not fail naming the read: '$lc_rs_out' $(head -1 "$lc_rs_fx/claim.err");"
  done
  lc_rs_out=$(LC_RS_AWAKE=no lc_rs_run PRESENT)
  { [[ "$lc_rs_out" == "RC=1 FAILED=1 STOPS=1" ]] && grep -q 'never read awake' "$lc_rs_fx/claim.err"; } \
    || lc_rs_bad+=" a sandbox that never read awake did not fail by name: '$lc_rs_out' $(head -1 "$lc_rs_fx/claim.err");"
  if [[ -z "$lc_rs_bad" ]]; then
    ok "1zm: restart-from-user-side waits for the app's entry before stopping the sandbox, passes once it is there, fails naming it when it never comes back, and fails naming a restarted sandbox that never reads awake"
  else
    bad "1zm:$lc_rs_bad"
  fi
  rm -rf "$lc_rs_fx"
  unset -f lc_rs_run
  unset lc_rs_fx lc_rs_bad lc_rs_out

  lc_sp_fx=$(mktemp -d) || exit 1
  lc_sp_graph() {
    local app='' link='' tap='' taplinks=''
    case "${2:-app}" in
      absent) ;;
      *) tap=',{"id":70,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"rhizo-lc-app-tap","media.class":"Stream/Input/Audio"}}}' ;;
    esac
    case "${2:-app}" in
      app) taplinks=',{"id":71,"type":"PipeWire:Interface:Link","info":{"output-node-id":41,"input-node-id":70,"state":"active"}}' ;;
      paused) taplinks=',{"id":71,"type":"PipeWire:Interface:Link","info":{"output-node-id":41,"input-node-id":70,"state":"paused"}}' ;;
      other) taplinks=',{"id":72,"type":"PipeWire:Interface:Link","info":{"output-node-id":50,"input-node-id":70,"state":"active"}}' ;;
      both) taplinks=',{"id":71,"type":"PipeWire:Interface:Link","info":{"output-node-id":41,"input-node-id":70,"state":"active"}},{"id":72,"type":"PipeWire:Interface:Link","info":{"output-node-id":50,"input-node-id":70,"state":"active"}}' ;;
    esac
    [[ "$1" == none ]] || app=',{"id":41,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"rhizo.bus0","application.name":"com.rhizo.audiotest.a","media.class":"Stream/Output/Audio"}}}'
    case "$1" in
      linked) link=',{"id":61,"type":"PipeWire:Interface:Link","info":{"output-node-id":41,"input-node-id":40,"state":"active"}}' ;;
      paused) link=',{"id":61,"type":"PipeWire:Interface:Link","info":{"output-node-id":41,"input-node-id":40,"state":"paused"}}' ;;
      elsewhere) link=',{"id":61,"type":"PipeWire:Interface:Link","info":{"output-node-id":41,"input-node-id":45,"state":"active"}}' ;;
    esac
    printf '%s' '[{"id":34,"type":"PipeWire:Interface:Metadata","props":{"metadata.name":"default"},"metadata":[{"subject":0,"key":"default.audio.sink","type":"Spa:String:JSON","value":{"name":"rhizo_lc_host_sink"}}]}' \
      ',{"id":40,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"rhizo_lc_host_sink","media.class":"Audio/Sink"}}}' \
      ',{"id":45,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"other_sink","media.class":"Audio/Sink"}}}' \
      ',{"id":50,"type":"PipeWire:Interface:Node","info":{"props":{"node.name":"Firefox","application.name":"Firefox","media.class":"Stream/Output/Audio"}}}' \
      ',{"id":60,"type":"PipeWire:Interface:Link","info":{"output-node-id":50,"input-node-id":40,"state":"active"}}' \
      "$app" "$link" "$tap" "$taplinks" ']'
  }
  lc_sp_run() {
    (
      FAILED=0 INIT=4242 REPO="$lc_sp_fx" VAR_DIR="$lc_sp_fx" EV="$lc_sp_fx/ev" TEST_STEP=4 LC_SP_SINK="$1" LC_SP_PWRC="$2"
      LC_SP_STREAMS="${3:-1}" LC_SP_UNDO="${4:-GONE}" LC_SP_APP="${5:-linked}" LC_SP_DUMP="${6:-during}"
      LC_SP_ENTRY="${7:-yes}" LC_SP_LAUNCH="${8:-ok}" LC_SP_TAP="${9:-app}" LC_SP_WAV="${10:-tone}" LC_SP_PRE="${11:-ok}"
      SSH_OPTS=() SSH_PORT=0 SSH_TARGET=fake APPS_DIR=/usr/share/applications DESK_USER=deskuser
      mkdir -p "$lc_sp_fx/share" "$lc_sp_fx/ev"; : > "$lc_sp_fx/share/rhizo-audiotest-a.apk"; : > "$lc_sp_fx/events"
      ev() { printf '%s\n' "$1" >> "$lc_sp_fx/events"; }
      lc_need_guest() { return 0; }
      lc_unit_active() { return 0; }
      lc_rhizo() { return 0; }
      guest_now() { echo 1000.5; }
      DRAIN_ENTRY_WAIT_S=240
      drain_wrote_entry() { [[ "$2" == com.rhizo.audiotest.a && "$3" == 1000.5 ]]; }
      wait_guest_file() { [[ "$2" == /usr/share/applications/rhizo-com.rhizo.audiotest.a.desktop && "$LC_SP_ENTRY" == yes ]]; }
      ssh_vm() {
        case "${*: -1}" in
          *"/run/rhizo-audio/status"*) printf 'streams=%s\nSTATUS_READ\n' "$LC_SP_STREAMS" ;;
          *rhizo-launch.log*) echo "1790409142.1 audio pkg=com.rhizo.audiotest.a: no bus assigned, sharing primary output" ;;
        esac
        return 0
      }
      timeout() { shift; "$@"; }
      scp() { return 0; }
      android_sh() { case "$2" in "pm list packages") echo package:com.rhizo.audiotest.a ;; *"am start"*) ev am-start ;; *force-stop*) ev app-stop ;; esac; return 0; }
      app_wait_token() { printf 'RHIZO_AUDIO_PLAYING'; }
      user_sh() {
        case "$2" in
          "/usr/bin/rhizo launch com.rhizo.audiotest.a "*)
            ev launch
            if [[ "$LC_SP_LAUNCH" == ok ]]; then
              printf 'RHIZO_LAUNCHED pkg=com.rhizo.audiotest.a display=3 cdisplay=3\nrc=0\n'
            else
              printf 'RHIZO_FAIL rhizo-launch.sh exited 1 for com.rhizo.audiotest.a\nrc=1\n'
            fi
            return 0 ;;
          *"pw-cli create-node"*)
            case "$LC_SP_SINK" in none) ev sink-made; echo MADE_SINK ;; have) echo HAVE_SINK ;; *) echo NO_SINK ;; esac ;;
          *"pw-cli destroy"*) ev sink-destroyed; echo "$LC_SP_UNDO" ;;
          *pw-record*)
            ev capture
            case "$2" in *"--target 0 -P '{ node.name=rhizo-lc-app-tap }'"*) ;; *) ev capture-not-the-tap ;; esac
            case "$2" in *pw-dump*) lc_sp_graph "$LC_SP_APP" "$LC_SP_TAP" > "$lc_sp_fx/guest-graph.json" ;; esac
            [[ "$LC_SP_DUMP" == during ]] && echo PW_DUMP_IN_CAPTURE
            return "$LC_SP_PWRC" ;;
          *"pw-dump > /tmp/rhizo-lifecycle-audio-graph-pre.json"*)
            [[ "$LC_SP_PRE" == ok ]] || return 1
            lc_sp_graph "$LC_SP_APP" absent > "$lc_sp_fx/guest-graph-pre.json"
            echo PRE_DUMP ;;
        esac
        return 0
      }
      pull() {
        case "$1" in
          *graph-pre.json) [[ -f "$lc_sp_fx/guest-graph-pre.json" ]] && cp "$lc_sp_fx/guest-graph-pre.json" "$2"; return ;;
          *.json) [[ -f "$lc_sp_fx/guest-graph.json" ]] && cp "$lc_sp_fx/guest-graph.json" "$2"; return ;;
        esac
        python3 -c 'import math,struct,sys,wave
a = 8000 if sys.argv[2] == "tone" else 0
w=wave.open(sys.argv[1],"wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b"".join(struct.pack("<hh",v,v) for v in (int(a*math.sin(2*math.pi*440*i/48000)) for i in range(4800))))' "$2" "$LC_SP_WAV"
      }
      lc_assert_audio.sound-plays >/dev/null 2>"$lc_sp_fx/claim.err"
      echo "RC=$? FAILED=$FAILED EVENTS=$(paste -sd, "$lc_sp_fx/events")"
    )
  }
  lc_sp_bad=""
  lc_sp_out=$(lc_sp_run none 0)
  [[ "$lc_sp_out" == "RC=0 FAILED=0 EVENTS=sink-made,launch,capture,app-stop,sink-destroyed" ]] \
    || lc_sp_bad+=" a host with no sink: want the sink made before the app and destroyed after, passing, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run none 1)
  [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=sink-made,launch,capture,app-stop,sink-destroyed" ]] \
    || lc_sp_bad+=" a failed capture: want a failure with the sink still destroyed, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run have 0)
  [[ "$lc_sp_out" == "RC=0 FAILED=0 EVENTS=launch,capture,app-stop" ]] \
    || lc_sp_bad+=" a host that has a sink: want nothing made or destroyed, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run cannot 0)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=" ]] && grep -q 'no Audio/Sink' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" a sink that cannot be made: want a named failure before the app, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run have 0 0)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=launch,capture,app-stop" ]] && grep -q 'rhizo-audiod carried no stream' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" a capture with audiod carrying no stream: want a named failure, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run none 0 1 UNREAD)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=sink-made,launch,capture,app-stop,sink-destroyed" ]] && grep -q 'not shown gone' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" an undo whose graph read failed: want a named failure, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run have 0 1 GONE none)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=launch,app-stop" ]] && grep -q 'no rhizo\.\* stream of com.rhizo.audiotest.a' "$lc_sp_fx/claim.err" \
      && grep -qF 'its launch: 1790409142.1 audio pkg=com.rhizo.audiotest.a: no bus assigned, sharing primary output' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" audiod reporting streams=1 while the graph holds only another client in the default sink: want a named failure carrying the launch's own audio line, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run have 0 1 GONE linked during no)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=" ]] && grep -q 'rhizo-com.rhizo.audiotest.a.desktop did not appear' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" no menu entry to launch the fixture by: want a named failure before anything plays, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run have 0 1 GONE linked during yes fail)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=launch,app-stop" ]] && grep -q 'rhizo launch com.rhizo.audiotest.a (as deskuser) did not launch it' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" rhizo launch failing: want a named failure with the app stopped and no capture, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run have 0 1 GONE elsewhere)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=launch,app-stop" ]] && grep -q 'no active link' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" the app's stream linked to a sink that is not the default: want a named failure, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run have 0 1 GONE paused)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=launch,app-stop" ]] && grep -q 'no active link' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" the app's link to the default sink paused: want a named failure, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  lc_sp_out=$(lc_sp_run have 0 1 GONE linked after)
  { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS=launch,capture,app-stop" ]] && grep -q 'not read while the capture ran' "$lc_sp_fx/claim.err"; } \
    || lc_sp_bad+=" a graph not shown read during the capture: want a named failure, got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  for lc_sp_case in \
      "app silent|silent|app|ok|com.rhizo.audiotest.a's own node rhizo.bus0, captured alone, is silent" \
      "tap reads another client|tone|other|ok|the capture stream rhizo-lc-app-tap also reads Firefox (node 50), not only com.rhizo.audiotest.a" \
      "tap reads the app and another client|tone|both|ok|also reads Firefox (node 50)" \
      "tap with no input link|tone|none|ok|the capture stream rhizo-lc-app-tap has no input link" \
      "tap link paused|tone|paused|ok|no active link from com.rhizo.audiotest.a into the capture stream rhizo-lc-app-tap" \
      "tap absent from the graph|tone|absent|ok|the capture stream rhizo-lc-app-tap is not in the graph" \
      "pre-capture graph unread|tone|app|fail|could not be read before the capture"; do
    IFS='|' read -r lc_sp_label lc_sp_wav lc_sp_tap lc_sp_pre lc_sp_want <<<"$lc_sp_case"
    lc_sp_out=$(lc_sp_run have 0 1 GONE linked during yes ok "$lc_sp_tap" "$lc_sp_wav" "$lc_sp_pre")
    { [[ "$lc_sp_out" == "RC=1 FAILED=1 EVENTS="* && "$lc_sp_out" != *capture-not-the-tap* ]] && grep -qF -- "$lc_sp_want" "$lc_sp_fx/claim.err"; } \
      || lc_sp_bad+=" $lc_sp_label: want a failure naming '$lc_sp_want', got '$lc_sp_out' $(head -1 "$lc_sp_fx/claim.err");"
  done
  if [[ -z "$lc_sp_bad" ]]; then
    ok "1zn: audio.sound-plays makes a null sink before the app plays on a host with none and destroys it on every path, proven gone, leaves a host's own sink alone, fails by name when none can be made, starts the app only through rhizo launch by its menu entry (failing by name with no entry or a failed launch), ties the sound to the app's own audiod stream actively linked into the default sink in graphs read before and during the capture, and measures it through a tap linked to that node alone: another client's sound with the app silent fails, as does a tap reading any other node, none, a paused link, or no tap"
  else
    bad "1zn:$lc_sp_bad"
  fi
  rm -rf "$lc_sp_fx"
  unset -f lc_sp_run
  unset lc_sp_fx lc_sp_bad lc_sp_out lc_sp_case lc_sp_label lc_sp_wav lc_sp_tap lc_sp_pre lc_sp_want

  before=$FAILED
  if lc_assert_readme.current-state; then
    ok "readme.current-state passes against the real, intact README.md"
  else
    bad "readme.current-state failed against the real tree"
  fi
  FAILED=$before
  corrupt_root="$(mktemp -d)"
  echo "this readme carries none of the promised sentence" > "$corrupt_root/README.md"
  before=$FAILED
  if (grep -qF 'CachyOS + KDE Plasma' "$corrupt_root/README.md"); then
    bad "the corrupted fixture still contains the claim's own quote"
  elif (( FAILED == before )); then
    :
    ok "a readme missing the promised sentence would not satisfy this claim's grep"
  fi
  rm -rf "$corrupt_root"

  : > "$EV/claims.tsv"
  before=$FAILED
  claim_assert selftest.undefined-claim this_function_does_not_exist
  if (( FAILED == before )); then
    bad "claim_assert with an undefined function did not fail"
  elif ! grep -qx $'selftest\.undefined-claim\tfail' "$EV/claims.tsv"; then
    bad "claim_assert with an undefined function did not record a fail row"
  else
    ok "claim_assert with an undefined function records fail"
  fi

  : > "$EV/claims.tsv"
  lc_selftest_pass() { pass "synthetic"; return 0; }
  lc_selftest_fail() { fail "synthetic"; return 1; }
  claim_assert selftest.pass-claim lc_selftest_pass
  claim_assert selftest.fail-claim lc_selftest_fail
  claim_fence selftest.fenced-claim "selftest reason"
  lines=$(( $(wc -l < "$EV/claims.tsv") - 1 ))
  if [[ "$lines" -eq 3 ]]; then
    ok "claims.tsv gets exactly one line per claim_assert/claim_fence call"
  else
    bad "claims.tsv has $lines row(s) after 3 calls, want 3"
  fi
  if [[ "$(head -1 "$EV/claims.tsv")" == $'claim_id\tresult' ]]; then
    ok "claims.tsv's first line is the plain claim_id/result header"
  else
    bad "claims.tsv's header is $(head -1 "$EV/claims.tsv" | cat -A), want claim_id\\tresult"
  fi
  if grep -qx $'selftest\.pass-claim\tpass' "$EV/claims.tsv" \
     && grep -qx $'selftest\.fail-claim\tfail' "$EV/claims.tsv" \
     && grep -qx $'selftest\.fenced-claim\tfenced' "$EV/claims.tsv"; then
    ok "claims.tsv records pass, fail and fenced results correctly, as exactly two columns"
  else
    bad "claims.tsv rows do not carry the expected two-column result"
    sed 's/^/    saw: /' "$EV/claims.tsv" >&2
  fi

  : > "$EV/claims.tsv"
  lc_selftest_fail_then_pass() { fail "synthetic: something is wrong"; pass "synthetic: but this runs anyway"; return 0; }
  lc_selftest_skip_only() { skip "synthetic: not run this time"; return 0; }
  claim_assert selftest.fail-then-pass-claim lc_selftest_fail_then_pass
  claim_assert selftest.skip-only-claim lc_selftest_skip_only
  if grep -qx $'selftest\.fail-then-pass-claim\tfail' "$EV/claims.tsv"; then
    ok "a body that calls fail() and then still returns 0 records fail, not pass"
  else
    bad "a body that calls fail() and then returns 0 was recorded as: $(grep '^selftest\.fail-then-pass-claim' "$EV/claims.tsv")"
  fi
  if grep -qx $'selftest\.skip-only-claim\tfail' "$EV/claims.tsv"; then
    ok "a body that only calls skip() records fail, not pass"
  else
    bad "a body that only calls skip() was recorded as: $(grep '^selftest\.skip-only-claim' "$EV/claims.tsv")"
  fi

  doc_only_ids="readme.what-that-buys readme.current-state"
  for profile in gnome sway server; do
    : > "$EV/claims.tsv"
    lifecycle_run_cycle "$profile" >/dev/null 2>&1
    total=$(( $(wc -l < "$EV/claims.tsv") - 1 ))
    uniq=$(tail -n +2 "$EV/claims.tsv" | cut -f1 | sort -u | wc -l)
    if [[ "$total" -gt 0 && "$total" -eq "$uniq" ]]; then
      ok "lifecycle_run_cycle $profile: $total claims, each recorded exactly once"
    else
      bad "lifecycle_run_cycle $profile: $total lines, $uniq unique ids -- want equal and > 0"
    fi
    unexpected=""
    while IFS=$'\t' read -r cid result; do
      [[ "$cid" == "claim_id" ]] && continue
      [[ "$result" == pass ]] || continue
      case " $doc_only_ids " in
        *" $cid "*) : ;;
        *) unexpected="$unexpected $cid" ;;
      esac
    done < "$EV/claims.tsv"
    if [[ -n "$unexpected" ]]; then
      bad "lifecycle_run_cycle $profile: claim(s) passed with no guest outside the doc-only allowlist:$unexpected"
    else
      ok "lifecycle_run_cycle $profile: every pass (if any) is a doc-only claim; every guest-dependent claim failed closed"
    fi
  done

  for profile in gnome sway server; do
    : > "$EV/claims.tsv"; : > "$EV/claims-detail.tsv"
    lifecycle_run_cycle "$profile" >/dev/null 2>&1
    lc_site_bad=""
    lc_site_want="install.cmd-status:2 policy.absent-is-defaults:4 policy.unparsable-denies-optional:4 host.new-account-home:4 host.user-manager-start:4"
    [[ "$profile" == server ]] || lc_site_want+=" policy.off-is-unreachable:4 session.env-from-user-manager:4"
    for lc_site_pair in $lc_site_want; do
      lc_site_step=$(awk -F'\t' -v id="${lc_site_pair%%:*}" -v want="${lc_site_pair##*:}: " \
        '$1 == id {n++; if (index($2, want) != 1) bad = bad "|" $2} END {print (n ? bad : "|<no row>")}' "$EV/claims-detail.tsv")
      [[ -z "$lc_site_step" ]] \
        || lc_site_bad+=" ${lc_site_pair%%:*} in '${lc_site_step#|}' (want step ${lc_site_pair##*:})"
    done
    [[ "$profile" == server ]] && grep -q '^session\.env-from-user-manager' "$EV/claims-detail.tsv" \
      && lc_site_bad+=" session.env-from-user-manager asserted on server, which has no desktop session"
    if [[ -z "$lc_site_bad" ]]; then
      ok "4b: lifecycle_run_cycle $profile sites install.cmd-status in step 2 and the policy.*, host.new-account-home, host.user-manager-start and (desktop only) session.env-from-user-manager claims in step 4"
    else
      bad "4b: lifecycle_run_cycle $profile mis-sites:$lc_site_bad"
    fi
  done
  unset lc_site_bad lc_site_want lc_site_pair lc_site_step
  if grep -qE 'desk_(token_settled|android_granted|android_await_auth)|rhizo-deskd' <<<"$(declare -f _lc_desktop_plant_fixture_apps)"; then
    bad "4b: _lc_desktop_plant_fixture_apps (step 2, on N-1) still waits on the deskd bridge N-1 does not ship"
  elif ! grep -q 'lc_step4_restart "$profile"' <<<"$(declare -f lifecycle_run_cycle)" \
       || ! grep -q 'step_claim 4.bridge-connected _lc_desktop_connect_bridge "$off"' <<<"$(declare -f lc_step4_restart)"; then
    bad "4b: step 4 never connects the bridge as step_claim 4.bridge-connected with the deskd log offset lc_step4_restart read"
  else
    ok "4b: the desktop bridge connects in step 4, on N, and the step-2 fixture plant never waits on its token"
  fi

  _lc_row() { awk -F'\t' -v id="$1" '$1 == id {r = $2} END {print r}' "$EV/claims.tsv"; }

  for bad_knob in RHIZO_LIFECYCLE_FROM_STEP=11 RHIZO_LIFECYCLE_FROM_STEP=9c RHIZO_LIFECYCLE_FROM_STEP=04 \
                  RHIZO_LIFECYCLE_TO_STEP=12 RHIZO_LIFECYCLE_KEEP_VM=yes; do
    : > "$EV/claims.tsv"
    before=$FAILED
    env_name="${bad_knob%%=*}"
    declare -x "$bad_knob"
    lifecycle_run_cycle server 2>"$EV/refusal.log"
    unset "$env_name"
    if (( FAILED == before )); then
      bad "5a: $bad_knob did not fail lifecycle_run_cycle"
    elif [[ -s "$EV/claims.tsv" || -n "$LC_BODY_TRACE" ]]; then
      bad "5a: $bad_knob still ran $(( $(wc -l < "$EV/claims.tsv") - 1 )) claim(s) and bodies '$LC_BODY_TRACE'"
    elif ! grep -qF "$bad_knob" "$EV/refusal.log"; then
      bad "5a: $bad_knob's refusal does not name it: $(head -2 "$EV/refusal.log" | tr '\n' ' ')"
    else
      ok "5a: $bad_knob refuses by name before any step runs"
    fi
  done

  body_steps="0 1 2 3 4 5 6 7 8 9 9b 10"
  got_steps=$(declare -f lifecycle_run_cycle | grep -oE '\blc_body [0-9a-z]+' | awk '{printf "%s ", $2}')
  if [[ "$got_steps" != "$body_steps " ]]; then
    bad "5b: lifecycle_run_cycle system tests bodies for steps '$got_steps' through lc_body, want '$body_steps '"
  fi
  for profile in gnome sway server plasma; do
    : > "$EV/claims.tsv"; : > "$EV/claims-detail.tsv"
    LIFECYCLE_PROFILE="$profile" RHIZO_LIFECYCLE_FROM_STEP=4 lifecycle_run_cycle "$profile" >"$EV/run-5b.log" 2>&1
    unsited_bad=$(sed -n 's/.*claim \([^ :]*\): not asserted -- .*/\1/p' "$EV/run-5b.log" \
                  | grep -xF -f <(_lc_expected_claims "$profile") | tr '\n' ' ')
    want_trace=""
    for s in $body_steps; do
      if (( $(_lc_step_index "$s") < $(_lc_step_index 4) )); then want_trace+="$s:skip "; else want_trace+="$s:nolive "; fi
    done
    early=$(awk -F'\t' '$2 ~ /^[0-3]: / {print $1}' "$EV/claims-detail.tsv" | sort -u)
    step4=$(awk -F'\t' '$2 ~ /^4: / {print $1}' "$EV/claims-detail.tsv" | sort -u)
    early_bad="" step4_bad=""
    for cid in $early; do [[ "$(_lc_row "$cid")" == not_run ]] || early_bad+=" $cid=$(_lc_row "$cid")"; done
    for cid in $step4; do [[ "$(_lc_row "$cid")" == pass || "$(_lc_row "$cid")" == fail ]] || step4_bad+=" $cid=$(_lc_row "$cid")"; done
    if [[ "$LC_BODY_TRACE" != "$want_trace" ]]; then
      bad "5b: FROM_STEP=4 $profile ran bodies '$LC_BODY_TRACE', want '$want_trace'"
    elif [[ -n "$unsited_bad" ]]; then
      bad "5b: FROM_STEP=4 $profile passed over claims claims.tsv sites in it as unsited: $unsited_bad"
    elif [[ -z "$early" || -n "$early_bad" ]]; then
      bad "5b: FROM_STEP=4 $profile: a claim sited in steps 0-3 was not recorded not_run:${early_bad:- none sited there}"
    elif [[ -z "$step4" || -n "$step4_bad" ]]; then
      bad "5b: FROM_STEP=4 $profile: a step-4 claim was not asserted:${step4_bad:- none recorded}"
    else
      ok "5b: FROM_STEP=4 $profile skips the bodies of 0-3, records their $(wc -w <<<"$early") claims not_run and asserts all $(wc -w <<<"$step4") of step 4's"
    fi
  done

  lc_selftest_reads_bid() { [[ -n "$LC_INSTALL_BID_BEFORE" ]] || { fail "no boot_id"; return 1; }; }
  lc_selftest_via_helper() { _lc_selftest_boots; }
  _lc_selftest_boots() { [[ -n "$LC_INSTALL_BOOTS_AFTER" ]] || { fail "no boot count"; return 1; }; }
  lc_selftest_reads_diff_row() { _lc_step_passed 7.selftest-diff || { fail "row"; return 1; }; }
  : > "$EV/claims.tsv"
  LC_CUR_STEP=6 LC_FROM_IDX=$(_lc_step_index 4)
  RHIZO_LIFECYCLE_FROM_STEP=4 claim_assert selftest.reads-bid lc_selftest_reads_bid
  RHIZO_LIFECYCLE_FROM_STEP=4 claim_assert selftest.via-helper lc_selftest_via_helper
  LC_FROM_IDX=$(_lc_step_index 1)
  RHIZO_LIFECYCLE_FROM_STEP=1 claim_assert selftest.reads-bid-from-1 lc_selftest_reads_bid
  printf 'step.7.selftest-diff\tnot_run\n' >> "$EV/claims.tsv"
  LC_CUR_STEP=7 LC_FROM_IDX=$(_lc_step_index 7)
  RHIZO_LIFECYCLE_FROM_STEP=7 claim_assert selftest.reads-row lc_selftest_reads_diff_row
  LC_CUR_STEP="" LC_FROM_IDX=0
  if [[ "$(_lc_row selftest.reads-bid)" != not_run ]] || ! grep -q $'^selftest\\.reads-bid\t.*LC_INSTALL_BID_BEFORE.*step 1' "$EV/claims-detail.tsv"; then
    bad "5c: a step-6 claim reading step 1's LC_INSTALL_BID_BEFORE under FROM_STEP=4 recorded '$(_lc_row selftest.reads-bid)', want not_run naming the variable and step 1"
  elif [[ "$(_lc_row selftest.via-helper)" != not_run ]]; then
    bad "5c: a claim reading step 1's state through an _lc_ helper recorded '$(_lc_row selftest.via-helper)', want not_run"
  elif [[ "$(_lc_row selftest.reads-bid-from-1)" != fail ]]; then
    bad "5c: under FROM_STEP=1 (step 1 runs) the same claim recorded '$(_lc_row selftest.reads-bid-from-1)', want it asserted (fail on its empty variable)"
  elif [[ "$(_lc_row selftest.reads-row)" != not_run ]]; then
    bad "5c: a claim reading a step row recorded not_run came out '$(_lc_row selftest.reads-row)', want not_run"
  else
    ok "5c: step-1 state read directly, through a helper, or via a not_run row is not_run under FROM_STEP=4/7, and asserted under FROM_STEP=1"
  fi
  : > "$EV/claims.tsv"
  RHIZO_LIFECYCLE_FROM_STEP=4 lifecycle_run_cycle server >/dev/null 2>&1
  if [[ "$(_lc_row install.one-reboot)" != not_run || "$(_lc_row packaging.swapfile-precise-removal)" != not_run ]]; then
    bad "5c: FROM_STEP=4 recorded install.one-reboot=$(_lc_row install.one-reboot) packaging.swapfile-precise-removal=$(_lc_row packaging.swapfile-precise-removal), want both not_run"
  elif ! grep -q $'^packaging\\.swapfile-precise-removal\t.*LC_SWAPFILE_.*step 0' "$EV/claims-detail.tsv"; then
    bad "5c: packaging.swapfile-precise-removal (step 9) is not_run, but not for reading step 0's swapfile seed"
  else
    ok "5c: FROM_STEP=4 records install.one-reboot (step 1) and packaging.swapfile-precise-removal (step 9, reads step 0's seed) not_run"
  fi

  for profile in gnome sway server; do
    : > "$EV/claims.tsv"
    lifecycle_run_cycle "$profile" >/dev/null 2>&1
    cp "$EV/claims.tsv" "$EV/claims-plain.tsv"; plain_trace="$LC_BODY_TRACE"
    : > "$EV/claims.tsv"
    RHIZO_LIFECYCLE_KEEP_VM=1 lifecycle_run_cycle "$profile" >/dev/null 2>&1
    if ! cmp -s "$EV/claims-plain.tsv" "$EV/claims.tsv" || [[ "$LC_BODY_TRACE" != "$plain_trace" ]]; then
      bad "5d: KEEP_VM=1 changed $profile's claims or bodies: $(diff "$EV/claims-plain.tsv" "$EV/claims.tsv" | head -3 | tr '\n' ' ')"
    else
      ok "5d: KEEP_VM=1 leaves $profile's $(( $(wc -l < "$EV/claims.tsv") - 1 )) claim results and its bodies unchanged"
    fi
  done


  _lc_range_bad() {
    local f t s i cid step r out="" want=""
    f=$(_lc_step_index "$1"); t=$(_lc_step_index "$2")
    for s in $body_steps; do
      i=$(_lc_step_index "$s")
      if (( i < f || i > t )); then want+="$s:skip "; else want+="$s:nolive "; fi
    done
    [[ "$LC_BODY_TRACE" == "$want" ]] || out+=" bodies '$LC_BODY_TRACE', want '$want';"
    while IFS=$'\t' read -r cid step _; do
      i=$(_lc_step_index "${step%%:*}") || continue
      r=$(_lc_row "$cid")
      if (( i < f || i > t )); then
        [[ "$r" == not_run ]] || out+=" $cid=$r (step ${step%%:*}, want not_run);"
      else
        [[ "$r" == pass || "$r" == fail ]] || out+=" $cid=$r (step ${step%%:*}, want asserted);"
      fi
    done < "$EV/claims-detail.tsv"
    printf '%s' "$out"
  }
  : > "$EV/claims.tsv"
  before=$FAILED
  RHIZO_LIFECYCLE_FROM_STEP=5 RHIZO_LIFECYCLE_TO_STEP=4 lifecycle_run_cycle server 2>"$EV/refusal.log"
  if (( FAILED == before )) || [[ -s "$EV/claims.tsv" || -n "$LC_BODY_TRACE" ]]; then
    bad "5f: FROM_STEP=5 TO_STEP=4 did not refuse before any step ran"
  elif ! grep -qF 'RHIZO_LIFECYCLE_FROM_STEP=5 comes after RHIZO_LIFECYCLE_TO_STEP=4' "$EV/refusal.log"; then
    bad "5f: FROM_STEP=5 TO_STEP=4's refusal does not name both: $(head -2 "$EV/refusal.log" | tr '\n' ' ')"
  else
    ok "5f: FROM_STEP=5 TO_STEP=4 refuses by name before any step runs"
  fi
  for range in "0 4" "4 4"; do
    read -r rf rt <<<"$range"
    for profile in gnome sway server; do
      : > "$EV/claims.tsv"; : > "$EV/claims-detail.tsv"
      if [[ "$rf" == 0 ]]; then
        RHIZO_LIFECYCLE_TO_STEP=$rt lifecycle_run_cycle "$profile" >/dev/null 2>&1
      else
        RHIZO_LIFECYCLE_FROM_STEP=$rf RHIZO_LIFECYCLE_TO_STEP=$rt lifecycle_run_cycle "$profile" >/dev/null 2>&1
      fi
      mism=$(_lc_range_bad "$rf" "$rt")
      if [[ -n "$mism" ]]; then
        bad "5f: steps $rf..$rt $profile:$(head -c 400 <<<"$mism")"
      else
        ok "5f: steps $rf..$rt $profile system tests in only those bodies, asserts only the claims sited there and records the rest not_run"
      fi
    done
  done
  : > "$EV/claims.tsv"
  lifecycle_run_cycle server >/dev/null 2>&1
  cp "$EV/claims.tsv" "$EV/claims-plain.tsv"; plain_trace="$LC_BODY_TRACE"
  : > "$EV/claims.tsv"
  RHIZO_LIFECYCLE_TO_STEP=10 lifecycle_run_cycle server >/dev/null 2>&1
  if ! cmp -s "$EV/claims-plain.tsv" "$EV/claims.tsv" || [[ "$LC_BODY_TRACE" != "$plain_trace" ]]; then
    bad "5f: TO_STEP=10 (the last step) differs from a plain cycle"
  else
    ok "5f: TO_STEP=10 runs exactly the plain cycle"
  fi

  lc_st_finish() {
    (
      source "$(dirname "${BASH_SOURCE[0]}")/../lib/installer-lib.sh"
      LC_ST_PREP="$1" APP_PKG=org.example.fixture INIT=1
      _lc_step_passed() { return 0; }
      dpkg-deb() { echo 0.1.4; }
      reboot_and_wait() { return 0; }
      sleep() { :; }
      lc_sandbox_up() { return 0; }
      android_sh() { echo "package:$APP_PKG"; }
      ssh_vm() {
        case "${*: -1}" in
          *selinux/enforce*) printf '1\nDONE\n' ;;
          *"ino=%i"*) printf 'ino=12 crtime=34\nDONE\n' ;;
          "wc -l < /var/log/rhizo/prepare.log; echo DONE") printf '5\nDONE\n' ;;
          "tail -n +6 /var/log/rhizo/prepare.log") printf '%s\n' "$LC_ST_PREP" ;;
          *".prepared; echo DONE") printf 'kernel=k\nversion=0.1.4\nDONE\n' ;;
          *"VERSION; echo DONE") printf '0.1.4\nDONE\n' ;;
          "uname -r") echo "${LC_ST_UNAME:-7.1.0-rc1-rhizo}" ;;
          *kernel-check.sh*) echo rc=0 ;;
          *) return 255 ;;
        esac
      }
      printf '[rhizo] reboot to finish the upgrade\n[rhizo] the sandbox already ran on this boot\n' \
        > "$EV/server-upgrade-install.log"
      before=$FAILED
      lc_step3_finish_upgrade server "$EV/rhizo.deb" 2>"$EV/finish.err"; rc=$?
      echo "rc=$rc failed=$((FAILED - before)) survived=$(grep -c 'survived the upgrade' "$EV/finish.err")"
    )
  }
  OK_LINE="RHIZO_PREPARE_OK key=k tree=t sepolicy=s template=t data=kept dexopt=1/1"
  got=$(lc_st_finish "$OK_LINE")
  if [[ "$got" == "rc=0 failed=0 survived=0" ]]; then
    ok "5g: step 3's reboot passes a prepare the postinst's cleared marker let run"
  else
    bad "5g: step 3's reboot on a plain prepare.log: $got, want rc=0 failed=0 survived=0 ($(head -2 "$EV/finish.err"))"
  fi
  got=$(lc_st_finish "RHIZO_PREPARE_KERNEL_REFRESHED=1 kernel=k prepared=payload-changed"$'\n'"$OK_LINE")
  if [[ "$got" == "rc=1 failed=1 survived=1" ]]; then
    ok "5g: step 3's reboot fails by name when the refresh removed a marker the upgrade left"
  else
    bad "5g: step 3's reboot after the refresh removed the old marker: $got, want rc=1 failed=1 survived=1"
  fi
  got=$(LC_ST_UNAME=6.8.0-1-generic lc_st_finish "$OK_LINE")
  if [[ "$got" == "rc=1 failed=1 survived=0" ]] && grep -q "booted '6.8.0-1-generic', not the Rhizo kernel the rhizo package depends on" "$EV/finish.err"; then
    ok "5g: step 3's reboot fails by name when the guest booted a stock kernel and not the Rhizo kernel"
  else
    bad "5g: step 3's reboot into a stock kernel read $got, want rc=1 failed=1 survived=0 naming the kernel ($(grep FAIL "$EV/finish.err" | head -1))"
  fi

  lc_md_fx=$(mktemp -d) || exit 1
  lc_md_run() {
    (
      INSTALLER_SELINUX_MODE="$1" FAILED=0 EV="$lc_md_fx"
      printf 'REBOOT REQUIRED\n' > "$EV/cycle-sway-install.log"
      ssh_vm() {
        echo "${*: -1}" >> "$lc_md_fx/reads"
        case "${*: -1}" in
          *90-rhizo.cfg*) printf 'GRUB_CMDLINE_LINUX="security=selinux"\nDONE\n' ;;
          "cat /proc/cmdline") echo "BOOT_IMAGE=/vmlinuz root=/dev/vda1 security=selinux" ;;
          *) return 255 ;;
        esac
      }
      : > "$lc_md_fx/reads"
      "lc_assert_$2" sway >/dev/null 2>"$lc_md_fx/claim.err"
      echo "RC=$? FAILED=$FAILED READS=$(grep -c . "$lc_md_fx/reads")"
    )
  }
  lc_md_bad=""
  for lc_md_id in cli.install install.requirements install.apt-helpers-as-root host.new-account-home \
                  host.private-users-services host.user-manager-start; do
    for lc_md_mode in namespace ""; do
      lc_md_out=$(lc_md_run "$lc_md_mode" "$lc_md_id")
      [[ "$lc_md_out" == "RC=1 FAILED=1 READS=0" ]] \
        && grep -qF "$lc_md_id: namespace mode: this claim asserts host mode's" "$lc_md_fx/claim.err" \
        || lc_md_bad+=" $lc_md_id under mode '${lc_md_mode:-<unset>}': $lc_md_out, $(grep FAIL "$lc_md_fx/claim.err" | head -1);"
    done
  done
  for lc_md_id in cli.install install.requirements; do
    lc_md_out=$(lc_md_run host "$lc_md_id")
    [[ "$lc_md_out" == "RC=0 FAILED=0 READS=1" ]] && grep -qF "$lc_md_id: host mode: " "$lc_md_fx/claim.err" \
      || lc_md_bad+=" $lc_md_id in host mode: $lc_md_out, $(grep -E 'FAIL|ok:' "$lc_md_fx/claim.err" | head -1);"
  done
  if [[ -z "$lc_md_bad" ]]; then
    ok "5h: the six host-mode claims fail by name in namespace mode, or with no mode pinned, before reading the guest, and a host-mode pass names host mode"
  else
    bad "5h:$lc_md_bad"
  fi
  rm -rf "$lc_md_fx"
  unset -f lc_md_run
  unset lc_md_fx lc_md_bad lc_md_id lc_md_mode lc_md_out

  if grep -qF 'reboot_and_wait "lc_post_reboot_sandbox $profile 5"' <<<"$(declare -f lifecycle_run_cycle)"; then
    ok "5i: step 5 reboots after the host's kernel update with reboot_and_wait, pinning no kernel"
  else
    bad "5i: step 5 does not pass reboot_and_wait to ubuntu_update_leg as its reboot"
  fi

  lc_kp_fx=$(mktemp -d) || exit 1
  mkdir -p "$lc_kp_fx/bin"
  printf '#!/bin/sh\nprintf "%%b" "$LC_KP_QUERY"\nexit "$LC_KP_QUERY_RC"\n' > "$lc_kp_fx/bin/dpkg-query"
  printf '#!/bin/sh\necho "apt-get $*" >> "%s/calls"\nexit "$LC_KP_APT_RC"\n' "$lc_kp_fx" > "$lc_kp_fx/bin/apt-get"
  chmod +x "$lc_kp_fx/bin/dpkg-query" "$lc_kp_fx/bin/apt-get"
  lc_kp_run() {
    (
      FAILED=0 EV="$lc_kp_fx" LC_KERNEL_DEBS=() lc_kp_query="$1" lc_kp_query_rc="$2" lc_kp_apt_rc="$3"
      [[ "$4" == expected ]] && LC_KERNEL_DEBS=(linux-image-rhizo_9_amd64.deb)
      : > "$lc_kp_fx/calls"
      ssh_vm() {
        env PATH="$lc_kp_fx/bin:$PATH" LC_KP_QUERY="$lc_kp_query" LC_KP_QUERY_RC="$lc_kp_query_rc" LC_KP_APT_RC="$lc_kp_apt_rc" \
          bash -c "${*: -1}"
      }
      lc_purge_rhizo_kernel sway 2>"$lc_kp_fx/claim.err"
      echo "RC=$? FAILED=$FAILED $(tr '\n' '|' < "$lc_kp_fx/calls")"
    )
  }
  lc_kp_bad=""
  lc_kp_out=$(lc_kp_run 'ii  linux-headers-9.9.9-rhizo\nii  linux-image-rhizo\nrc  linux-image-8.8.8-rhizo\niU  linux-headers-rhizo\n' 0 0 expected)
  [[ "$lc_kp_out" == "RC=0 FAILED=0 apt-get purge -y linux-headers-9.9.9-rhizo linux-image-rhizo|" ]] \
    || lc_kp_bad+=" two installed kernel packages read '$lc_kp_out', want one apt-get purge of the two ii ones;"
  lc_kp_out=$(lc_kp_run 'ii  linux-image-rhizo\n' 0 100 expected)
  [[ "$lc_kp_out" == "RC=1 FAILED=1 apt-get purge -y linux-image-rhizo|" ]] && grep -q 'exited 100' "$lc_kp_fx/claim.err" \
    || lc_kp_bad+=" a failed purge read '$lc_kp_out', want a fail naming exit 100;"
  lc_kp_out=$(lc_kp_run 'dpkg-query: no packages found matching linux-image-*rhizo\n' 1 0 expected)
  [[ "$lc_kp_out" == "RC=1 FAILED=1 " ]] && grep -q 'no Rhizo kernel package was installed to purge' "$lc_kp_fx/claim.err" \
    || lc_kp_bad+=" no kernel installed while N depends on it read '$lc_kp_out', want a fail by name;"
  lc_kp_out=$(lc_kp_run 'dpkg-query: no packages found matching linux-image-*rhizo\n' 1 0 none)
  [[ "$lc_kp_out" == "RC=0 FAILED=0 " ]] \
    || lc_kp_bad+=" no kernel installed while N depends on none read '$lc_kp_out', want a pass with no purge;"
  lc_kp_out=$(lc_kp_run 'dpkg-query: error: database broken\n' 2 0 expected)
  [[ "$lc_kp_out" == "RC=1 FAILED=1 " ]] && grep -q 'could not list the installed Rhizo kernel packages: KERNEL_QUERY_RC=2' "$lc_kp_fx/claim.err" \
    || lc_kp_bad+=" a failing dpkg-query read '$lc_kp_out', want a fail naming its status;"
  if [[ -z "$lc_kp_bad" ]]; then
    ok "5j: step 9 purges each installed Rhizo kernel package by name with apt-get, and fails by name on a failed purge, a kernel N needs that is not installed, or a dpkg-query failure"
  else
    bad "5j:$lc_kp_bad"
  fi
  if [[ "$(grep -c 'lc_purge_rhizo_kernel "$profile"' <<<"$(declare -f lifecycle_run_cycle | sed -n '/lc_step 9 /,/lc_step 9b /p')")" != 2 ]]; then
    bad "5j: step 9 does not purge the Rhizo kernel on both the Ubuntu and the cachyos branch before its census"
  fi
  rm -rf "$lc_kp_fx"
  unset -f lc_kp_run
  unset lc_kp_fx lc_kp_bad lc_kp_out

  exit $(( BAD > 0 ? 1 : 0 ))
}

cycle_selftest "$@"
