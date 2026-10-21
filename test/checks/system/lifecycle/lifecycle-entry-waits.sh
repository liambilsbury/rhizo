#!/bin/bash
# check the lifecycle app-entry waits
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# run the wait cases and print failures
run_cases() {
  local tools="$1"
  (
    set +u
    EV=$(mktemp -d) || exit 1
    STUBBIN=$(mktemp -d) || exit 1
    trap 'rm -rf "$EV" "$STUBBIN"' EXIT
    printf '#!/bin/sh\nexit 0\n' > "$STUBBIN/scp"
    chmod +x "$STUBBIN/scp"
    PATH="$STUBBIN:$PATH"
    FAILED=0
    MSGS=""
    log()  { :; }
    fail() { MSGS+="$*"$'\n'; FAILED=$((FAILED + 1)); }
    pass() { :; }
    step() { :; }
    source "$tools/lib/install-lib.sh"
    source "$tools/cycle/cycle.sh"
    SSH_OPTS=() SSH_PORT=0 SSH_TARGET=fake VAR_DIR="$EV" INIT=4242
    DESK_USER=tester WORKDIR="$EV" DOWNLOADS=/home/tester/Downloads
    touch "$EV/rhizo-deskapp.apk"

    casefail() { echo "CASE-FAIL $1: $2"; }
    run() {
      local name="$1" want="$2" never="$3"
      shift 3
      MSGS="" FAILED=0 CALLS=""
      "$@" >/dev/null 2>&1
      local rc=$?
      if (( rc == 0 || FAILED == 0 )); then
        casefail "$name" "rc=$rc FAILED=$FAILED, want a named failure"
      elif [[ "$MSGS" != *"$want"* ]]; then
        casefail "$name" "failed, but not naming '$want': ${MSGS//$'\n'/ | }"
      elif [[ "$never" != - && "$MSGS" == *"$never"* ]]; then
        casefail "$name" "failed on '$never', a symptom, not the cause: ${MSGS//$'\n'/ | }"
      fi
    }

    ssh_vm() { CALLS+="ssh:$*"$'\n'; case "$*" in *"[ -f "*) echo "$ENTRY_STATE" ;; esac; return 0; }
    user_sh() { CALLS+="user:$2"$'\n'; case "$2" in *"xdg-mime default"*) echo "XDG_MIME_RC=$MIME_RC" ;; esac; return 0; }
    app_wait_token() { return 1; }
    ENTRY_STATE=ABSENT MIME_RC=0
    run "handoff: absent entry" "is absent" - install_file_handoff rhizo-com.rhizo.deskapp.desktop
    [[ "$CALLS" == *"xdg-open"* ]] && casefail "handoff: absent entry" "went on to xdg-open with no entry"
    ENTRY_STATE=PRESENT MIME_RC=1
    run "handoff: xdg-mime default fails" "xdg-mime default rhizo-com.rhizo.deskapp.desktop text/plain exited" - \
      install_file_handoff rhizo-com.rhizo.deskapp.desktop
    [[ "$CALLS" == *"xdg-open"* ]] && casefail "handoff: xdg-mime default fails" "went on to xdg-open after the default failed"

    awt_run() {
      local lib="$1"
      (
        # shellcheck source=/dev/null
        source <(sed -n '/^app_wait_token()/,/^}/p' "$lib")
        INIT=1234
        AWT_N=$(mktemp) || exit 0
        trap 'rm -f "$AWT_N"' EXIT
        echo 0 > "$AWT_N"
        android_sh() {
          local cmd="$2" full n=$(( $(<"$AWT_N") + 1 ))
          echo "$n" > "$AWT_N"
          full="09-30 17:58:18.400  2089  2089 I RhizoDeskApp: RHIZO_DROP mime=text/plain b64=OLD=
09-30 18:01:02.372  1121  1121 I rhizo-desk: RHIZO_DRAG_ARMED"
          (( n >= 2 )) && full="$full
09-30 18:01:04.900  2089  2089 I RhizoDeskApp: RHIZO_DROP mime=text/plain b64=NEW="
          if [[ "$cmd" == *"-t '"* ]]; then
            local since; since=$(sed -n "s/.*-t '\\([^']*\\)'.*/\\1/p" <<<"$cmd")
            awk -v since="$since" 'function k(s){gsub(/[-: .]/,"",s);return s} {if (k(substr($0,1,18)) > k(since)) print}' <<<"$full"
          else
            printf '%s\n' "$full"
          fi
        }
        local pat="RHIZO_DROP mime=[^ ]* b64=[A-Za-z0-9+/=]*" got
        got=$(app_wait_token "$pat" 30)
        [[ "$got" == *"b64=OLD="* ]] \
          || casefail "app_wait_token: since filter" "with no since, the earlier line before the marker did not match (got '$got')"
        echo 0 > "$AWT_N"
        got=$(app_wait_token "$pat" 30 "09-30 18:01:02.000")
        [[ "$got" == *"b64=NEW="* && "$got" != *"b64=OLD="* ]] \
          || casefail "app_wait_token: since filter" "with a since past the earlier line, want only this leg's own b64=NEW, got '$got'"
        if app_wait_token "$pat" 1 "" >/dev/null 2>&1; then
          casefail "app_wait_token: since filter" "an empty since (3 args given) was accepted instead of failing closed"
        fi
      )
    }
    awt_run "$tools/lib/desktop-assert-lib.sh"

    awp_run() {
      (
        cd "$1" || exit 0
        _DESKTOP_LIB_DIR="$PWD"
        # shellcheck source=/dev/null
        source <(sed -n '/^assert_window_painted()/,/^}/p' ./desktop-lib.sh)
        AWP=$(mktemp -d) || exit 0
        EV="$AWP" TEST_NAME=awp FAILED=0
        python3 - "$AWP/frame.png" <<'PY'
import struct, sys, zlib
w, h = 128, 80
raw = b''.join(b'\x00' + bytes(v for x in range(w) for v in (x * 7 % 256, (x + y) % 256, 40 + y % 200))
               for y in range(h))
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(sys.argv[1], 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
                              + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
PY
        _desktop_window_for_display() {
          local n; n=$(( $(cat "$AWP/reads" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$AWP/reads"
          if (( n == 1 )); then echo '{"x": 0, "y": 3, "w": 96, "h": 108}'
          else echo '{"x": 0, "y": 3, "w": 128, "h": 76}'; fi
        }
        display_toplevel_unmapped_reason() { :; }
        desk_windows() { :; }
        desk_shot() { return 0; }
        pull() { cp "$AWP/frame.png" "$2"; }
        sleep() { :; }
        log() { :; }
        pass() { :; }
        fail() { echo "$*" >> "$AWP/fails"; FAILED=$((FAILED + 1)); }
        assert_window_painted awp 2 >/dev/null 2>&1
        (( $? == 0 && FAILED == 0 )) \
          || casefail "assert_window_painted: current rect" "a window maximized after its first rect read failed the paint check: $(head -1 "$AWP/fails" 2>/dev/null)"
        rm -rf "$AWP"
      )
    }
    awp_run "$tools/lib"

    awt_since_re='app_wait_token "[^"]*" [0-9]+ "[^"]*"'
    for awt_file in lib/desktop-assert-lib.sh lib/install-lib.sh desktop/desktop.sh cycle/claims-desktop.sh; do
      while IFS=: read -r awt_ln awt_txt; do
        [[ "$awt_txt" == *'title=$title'* ]] && continue
        [[ "$awt_txt" =~ $awt_since_re ]] \
          || casefail "app_wait_token: since argument" "$awt_file:$awt_ln carries no 3rd (since) argument: ${awt_txt# }"
      done < <(grep -n 'app_wait_token "' "$tools/$awt_file")
    done

    wait_guest_file() { CALLS+="wait:$*"$'\n'; return 1; }
    lc_rhizo() { return "$INSTALL_RC"; }
    android_sh() { case "$2" in "pm list packages") printf '%b' "$PM_LIST" ;; esac; return 0; }
    INSTALL_RC=1 PM_LIST=""
    run "audio: install refused" "rhizo app install" "did not appear" _lc_audio_sound_plays "$EV/rhizo-deskapp.apk"
    [[ "$CALLS" == *"wait:"* ]] && casefail "audio: install refused" "waited on the entry anyway"
    INSTALL_RC=0 PM_LIST="package:com.other\n"
    run "audio: package not listed" "missing from pm list packages" "did not appear" \
      _lc_audio_sound_plays "$EV/rhizo-deskapp.apk"
    [[ "$CALLS" == *"wait:"* ]] && casefail "audio: package not listed" "waited on the entry anyway"

    DRAIN_ENTRY_WAIT_S=1
    GUEST_NOW=1000.5
    DRAIN_JOURNAL=""
    ssh_vm() {
      CALLS+="ssh:$*"$'\n'
      case "$*" in
        *"date +%s.%N"*) echo "$GUEST_NOW" ;;
        *"journalctl -b -u rhizo-resync.service"*) printf '%s' "$DRAIN_JOURNAL"; echo DONE ;;
      esac
      return 0
    }
    earlier="999.000000 host python3[77]: [rhizo-appsync] package com.rhizo.audiotest.a: entry /usr/share/applications/rhizo-com.rhizo.audiotest.a.desktop written, defaults {}"$'\n'
    own="${earlier/999.000000/1001.000000}"
    other="1001.000000 host python3[77]: [rhizo-appsync] package com.other: entry /usr/share/applications/rhizo-com.other.desktop written, defaults {}"$'\n'
    failed_line="1001.000000 host python3[77]: [rhizo-appsync] package com.rhizo.audiotest.a: FAIL: entry /usr/share/applications/rhizo-com.rhizo.audiotest.a.desktop written but its defaults or the desktop database were not"$'\n'
    for spec in "earlier:$earlier:1" "own:$own:0" "other package:$other:1" "failed sync:$failed_line:1" "empty journal::1"; do
      label=${spec%%:*}; rest=${spec#*:}; want=${rest##*:}; DRAIN_JOURNAL=${rest%:*}
      if drain_wrote_entry 1 com.rhizo.audiotest.a 1000.5 >/dev/null 2>&1; then got=0; else got=1; fi
      [[ "$got" == "$want" ]] || casefail "drain line: $label" "drain_wrote_entry returned $got, want $want"
    done
    INSTALL_RC=0 PM_LIST="package:com.rhizo.audiotest.a\n" DRAIN_JOURNAL="$earlier" CALLS=""
    wait_guest_file() { CALLS+="wait:$*"$'\n'; return 0; }
    user_sh() { CALLS+="user:$2"$'\n'; return 0; }
    run "audio: earlier drain line" "no drain line for com.rhizo.audiotest.a" - \
      _lc_audio_sound_plays "$EV/rhizo-deskapp.apk"
    [[ "$CALLS" == *"user:"*"rhizo launch"* ]] && casefail "audio: earlier drain line" "launched on an earlier drain line"
    DRAIN_JOURNAL="$own" MSGS="" FAILED=0
    _lc_audio_sound_plays "$EV/rhizo-deskapp.apk" >/dev/null 2>&1
    [[ "$MSGS" == *"drain line"* ]] && casefail "audio: own drain line" "failed on the drain with this install's own line: ${MSGS//$'\n'/ | }"
    grep -q 'drain_wrote_entry "\$DRAIN_ENTRY_WAIT_S" "\$pkg" "\$since"' <<<"$(declare -f install_apk_via_broker)" \
      || casefail "broker: drain line" "install_apk_via_broker does not wait on this install's drain line"
    unset DRAIN_ENTRY_WAIT_S

    APP_PKG=com.rhizo.deskapp APP_ACT=com.rhizo.deskapp.MainActivity profile=gnome
    ssh_vm() { case "$*" in *rhizo-launch.sh*) echo "rc=1" ;; esac; return 0; }
    desk_windows() { return 0; }
    assert_window_painted() { return 0; }
    run "step 10: launch failed" "rhizo-launch.sh $APP_PKG $APP_ACT reported 'rc=1'" "cdisplay=" \
      lc_step10_app_paints gnome

    local body
    body=$(declare -f lifecycle_run_cycle | awk '/10.reinstall-purge-prepare-ok/{on=1} on{print} /lc_step10_app_paints/{if(on) exit}')
    { grep -q '_lc_desktop_plant_fixture_apps "\$VAR_DIR/share/rhizo-deskapp.apk"' <<<"$body" \
        && grep -q 'step_claim 10.fixture-planted lc_step10_plant_fixture' <<<"$body"; } \
      || casefail "step 10: plant" "no fixture plant claimed between 10.reinstall-purge-prepare-ok and the launch"

    local bound
    bound=$(resync_bound 2>/dev/null)
    if [[ ! "$bound" =~ ^[0-9]+$ ]]; then
      casefail "step 4: bound" "resync_bound read '${bound:-<nothing>}' from rhizo-resync.service, not RuntimeMaxSec's seconds"
    fi
    resync_bound() { echo 3; }
    RESYNC_POLL_S=0.2
    LC_ENTRY_PATH=/usr/share/applications/rhizo-com.rhizo.deskapp.desktop
    wait_guest_file() { [[ "$ENTRY_STATE" == PRESENT ]]; }
    ssh_vm() {
      case "$*" in
        *rhizo-resync.service*)
          printf '%s\nqueue=%s\ndrained=%s\ntrigger=%s\nsynced=init=%s trigger=%s\nstamping=1\nDONE\n' \
            "$RESYNC" "$QSIZE" "$QDONE" "$TRIG" "$SINIT" "$STRIG" ;;
      esac
      return 0
    }
    ENTRY_STATE=PRESENT RESYNC=active QSIZE=40 QDONE=40 TRIG=t0 SINIT=4242 STRIG=t0
    run "step 4: resync never settles" "queue=40 drained=40" - lc_step4_entries_synced
    RESYNC=inactive QSIZE=0 QDONE=0 SINIT=1111
    run "step 4: no resync of this sandbox" "not this sandbox's init 4242" - lc_step4_entries_synced
    ssh_vm() {
      case "$*" in
        *rhizo-resync.service*)
          printf 'inactive\nqueue=0\ndrained=0\ntrigger=1790541104.2446868\nsynced=init=8431 trigger=1790541104.2446868\nstamping=1\nlast_run=Result=success ExecMainStatus=0\nprune_path=active\nprune=inactive\nprune_synced=nosandbox trigger=1790541104.2446868\nprune_stamping=1\nDONE\n' ;;
      esac
      return 0
    }
    INIT=13948
    run "step 4: iteration 5's stamp for the outgoing init" \
      "not this sandbox's init 13948 -- resync stamp 'init=8431 trigger=1790541104.2446868'" - lc_step4_entries_synced
    INIT=4242
    ssh_vm() {
      case "$*" in
        *rhizo-resync.service*)
          printf '%s\nqueue=%s\ndrained=%s\ntrigger=%s\nsynced=init=%s trigger=%s\nstamping=1\nDONE\n' \
            "$RESYNC" "$QSIZE" "$QDONE" "$TRIG" "$SINIT" "$STRIG" ;;
      esac
      return 0
    }
    SINIT=4242
    TRIG=t1
    run "step 4: owed trigger" "still owed a run after 3s (rhizo-resync.service's RuntimeMaxSec=): want synced=init=4242 trigger=t1, read 'init=4242 trigger=t0'" - lc_step4_entries_synced
    TRIG=t0
    QSIZE=40 QDONE=20
    run "step 4: queue never drained" "queue=40 drained=20" - lc_step4_entries_synced
    ENTRY_STATE=ABSENT
    run "step 4: entry never appeared" "did not appear within 3s" - lc_step4_entries_synced
    ENTRY_STATE=PRESENT QSIZE=40 QDONE=40
    MSGS="" FAILED=0
    out=$(lc_step4_entries_synced 2>&1); rc=$?
    if (( rc != 0 || FAILED != 0 )); then
      casefail "step 4: synced" "an idle resync with a drained queue failed: rc=$rc ${MSGS//$'\n'/ | }"
    fi
    RESYNC=failed
    run "step 4: resync failed" "rhizo-resync.service is failed" - lc_step4_entries_synced
    exit 0
  )
}

# print each failed case with its label
report() {
  local out="$2"
  if grep -q '^CASE-FAIL' <<<"$out"; then
    grep '^CASE-FAIL' <<<"$out" | sed "s/^/FAIL: $1: /"
    return 1
  fi
  return 0
}

out=$(run_cases "$HERE/../../../system")
report check-lifecycle-entry-waits "$out" || exit 1
if [[ "${1:-}" != "--selftest" ]]; then
  echo "check-lifecycle-entry-waits: OK (every entry wait and its precondition fails by name at its cause)"
  exit 0
fi

# edit a scratch copy and run the cases
mutant() {
  local scratch
  scratch=$(mktemp -d) || return 1
  mkdir -p "$scratch/test" "$scratch/src/services" || return 1
  cp -a "$HERE/../../../system" "$scratch/test/system"
  cp -a "$HERE/../../../../src/services/units" "$scratch/src/services/units"
  sed -i "$3" "$scratch/test/system/$2"
  if cmp -s "$HERE/../../../system/$2" "$scratch/test/system/$2"; then
    echo "SELFTEST FAIL: the mutation for '$1' changed nothing in $2"; rm -rf "$scratch"; return 1
  fi
  local got; got=$(run_cases "$scratch/test/system")
  rm -rf "$scratch"
  if ! grep -q "^CASE-FAIL $1" <<<"$got"; then
    echo "SELFTEST FAIL: with its fix cut out of $2, '$1' still passed"
    return 1
  fi
}
MUT_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$MUT_DIR"' EXIT
i=0
# run a command in the background with its output in a numbered file
bg() { "$@" > "$MUT_DIR/$i" 2>&1 & i=$((i + 1)); }
bg mutant "handoff: absent entry" lib/install-lib.sh '/APPS_DIR\/\$entry_filename")" == PRESENT/,/return 1; }/d'
bg mutant "audio: install refused" cycle/claims-desktop.sh 's/|| { fail "audio.sound-plays: rhizo app install did not accept $apk"; return 1; }/|| true/'
bg mutant "audio: package not listed" cycle/claims-desktop.sh 's/|| { fail "audio.sound-plays: $pkg missing from pm list packages after its install"; return 1; }/|| true/'
bg mutant "handoff: xdg-mime default fails" lib/install-lib.sh 's/\[\[ "$mime_rc" == 0 \]\] \\/true \\/'
bg mutant "step 10: plant" cycle/cycle.sh '/step_claim 10.fixture-planted lc_step10_plant_fixture/d'
bg mutant "step 10: launch failed" cycle/cycle.sh '/\[\[ "\$lrc" == rc=0 \]\] ||/d'
bg mutant "step 4: queue never drained" lib/install-lib.sh 's/ \&\& "\$q" == "\$d"//'
bg mutant "drain line: earlier" lib/install-lib.sh 's/(\$1 + 0) >= (s + 0) \&\& //'
bg mutant "audio: earlier drain line" cycle/claims-desktop.sh 's/if ! drain_wrote_entry "\$DRAIN_ENTRY_WAIT_S" "\$pkg" "\$since"; then/if false; then/'
bg mutant "broker: drain line" lib/install-lib.sh '/^  drain_wrote_entry "\$DRAIN_ENTRY_WAIT_S" "\$pkg" "\$since" \\$/,/^    || fail "no drain line for/d'
bg mutant "step 4: no resync of this sandbox" lib/install-lib.sh 's/ESI_VERDICT=otherinit; return 0/ESI_VERDICT=idle; return 0/'
bg mutant "step 4: iteration 5's stamp for the outgoing init" lib/install-lib.sh 's/ESI_VERDICT=otherinit; return 0/return 1/'
bg mutant "step 4: owed trigger" lib/install-lib.sh 's/"\$synced" == \*" trigger=\$trig"/"$synced" == *" trigger="*/'
bg mutant "app_wait_token: since filter" lib/desktop-assert-lib.sh '/^app_wait_token() {/,/^}/s/-t '\''$since'\''//'
bg mutant "app_wait_token: since argument" desktop/desktop.sh 's/app_wait_token "RHIZO_CLIP_WROTE" 30 "$wrote_since"/app_wait_token "RHIZO_CLIP_WROTE" 30/'
bg mutant "assert_window_painted: current rect" lib/desktop-lib.sh '/^    if win=.(_desktop_window_for_display "$disp" 5); then$/,/^    fi$/d'
wait
rc=0
for (( j = 0; j < i; j++ )); do
  if [[ ! -e "$MUT_DIR/$j" ]]; then echo "SELFTEST FAIL: mutant $j left no result"; rc=1
  elif [[ -s "$MUT_DIR/$j" ]]; then cat "$MUT_DIR/$j"; rc=1; fi
done
(( rc == 0 )) && echo "check-lifecycle-entry-waits --selftest: OK (each fix cut back out is caught by its own case)"
exit "$rc"
