#!/bin/bash
# test install_uninstall_via_entry_action in install-lib.sh
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG=com.jeffliu.balancetheball

# run the removal window cases
run_cases() {
  local tools="$1"
  (
    set +u
    G=$(mktemp -d) || exit 1
    trap 'rm -rf "$G"' EXIT
    mkdir -p "$G/bin" "$G/run"
    cat > "$G/bin/systemctl" <<'EOF'
#!/bin/bash
g=$FAKE_GUEST
trig() { local t; t=$(head -n 1 "$g/run/trigger" 2>/dev/null); echo "${t:-none}"; }
case "$1 $2" in
  "show "*)
    printf 'ExecMainStatus=%s\nResult=%s\n' "$(cat "$g/last-status" 2>/dev/null || echo 0)" \
      "$(cat "$g/last-result" 2>/dev/null || echo success)"
    exit 0 ;;
  "is-active rhizo-remove-entries.path")
    cat "$g/prune-path" 2>/dev/null || echo inactive
    exit 0 ;;
  "is-active rhizo-remove-entries.service")
    pstate=$(cat "$g/prune-state" 2>/dev/null || echo inactive)
    echo "$pstate"
    if [[ "$pstate" == active ]]; then
      if [[ -f "$g/prune-complete" ]]; then bash "$g/prune-complete"; rm -f "$g/prune-complete"; fi
      printf 'init=%s trigger=%s\n' "$FAKE_INIT" "$(trig)" > "$g/run/prune-synced"
      echo inactive > "$g/prune-state"
    fi
    [[ "$pstate" == active ]]
    exit ;;
esac
state=$(cat "$g/state")
echo "$state"
if [[ "$state" == active ]]; then
  if [[ -f "$g/on-complete" ]]; then bash "$g/on-complete"; rm -f "$g/on-complete"; fi
  [[ -f "$g/no-stamp" ]] || printf 'init=%s trigger=%s\n' "$FAKE_INIT" "$(trig)" > "$g/run/synced"
  echo inactive > "$g/state"
elif [[ "$state" == inactive && -f "$g/on-next" && ! -f "$g/on-next.seen" ]]; then
  touch "$g/on-next.seen"
elif [[ "$state" == inactive && -f "$g/on-next" ]]; then
  rm -f "$g/on-next.seen"
  date +%s.%N > "$g/run/trigger"
  mv "$g/on-next" "$g/on-complete"
  echo active > "$g/state"
  [[ "$(cat "$g/prune-path" 2>/dev/null)" == active ]] && echo active > "$g/prune-state"
fi
[[ "$state" == active ]]
EOF
    chmod +x "$G/bin/systemctl"
    export FAKE_GUEST="$G" FAKE_INIT=4242 PATH="$G/bin:$PATH"

    MSGS="" FAILED=0
    log()  { :; }
    fail() { MSGS+="$*"$'\n'; FAILED=$((FAILED + 1)); }
    pass() { :; }
    source "$tools/lib/install-lib.sh"
    resync_bound() { echo 3; }
    RESYNC_POLL_S=0.1
    ssh_vm() { [[ "$1" == -t ]] && shift 2; bash -c "$1"; }
    android_sh() { case "$2" in "pm list packages") printf 'package:com.android.calendar\n' ;; esac; }
    INIT=4242 EV="$G/ev" WORKDIR="$G/ev"
    APPS_DIR="$G/apps" ICONS_DIR="$G/icons" NOTIF_REC="$G/notif.jsonl"
    MIMEAPPS="$APPS_DIR/mimeapps.list" MIMEINFO="$APPS_DIR/mimeinfo.cache"
    RESYNC_TRIGGER="$G/run/trigger" RESYNC_QUEUE="$G/run/queue"
    RESYNC_QUEUE_STATE="$G/run/queue.offset" RESYNC_SYNCED="$G/run/synced" RESYNC_SCRIPT="$G/resync.sh"
    PRUNE_SYNCED="$G/run/prune-synced" PRUNE_SCRIPT="$G/remove-entries.sh"
    ENTRY_NAME="rhizo-$PKG.desktop" ENTRY_PATH="$G/apps/rhizo-$PKG.desktop"
    ENTRY_TEXT="[Desktop Entry]
Name=Balance the Ball
Exec=rhizo launch $PKG %u
X-Rhizo-Package=$PKG

[Desktop Action Uninstall]
Exec=rhizo app remove $PKG"
    entry_of() { printf '[Desktop Entry]\nName=%s\nX-Rhizo-Package=%s\n' "$1" "$1"; }

    user_sh() {
      case "$2" in
        *"rhizo app remove $PKG"*)
          systemctl is-active rhizo-resync.service >/dev/null
          systemctl is-active rhizo-remove-entries.service >/dev/null
          [[ -f "$G/removal-now" ]] && bash "$G/removal-now"
          rm -f "$ENTRY_PATH"
          date +%s.%N > "$RESYNC_TRIGGER"
          [[ -f "$G/removal-run" ]] && cp "$G/removal-run" "$G/on-complete"
          echo active > "$G/state"
          [[ "$(cat "$G/prune-path")" == active ]] && echo active > "$G/prune-state"
          echo '{"summary":"removed"}' >> "$NOTIF_REC"
          printf 'RHIZO_APP removed=%s\nEXEC_RC=0\n' "$PKG" ;;
      esac
    }

    reset_guest() {
      rm -rf "$G/apps" "$G/icons" "$G/ev" "$G/run" "$G/on-complete" "$G/removal-now" "$G/removal-run" \
             "$G/on-next" "$G/on-next.seen" "$G/no-stamp" "$G/prune-complete" "$G/last-status" \
             "$G/last-result" "$NOTIF_REC"
      mkdir -p "$G/apps" "$G/icons" "$G/ev" "$G/run"
      printf '%s\n' "$ENTRY_TEXT" > "$ENTRY_PATH"
      entry_of com.android.calendar > "$G/apps/rhizo-com.android.calendar.desktop"
      printf '[Default Applications]\napplication/vnd.android.package-archive=rhizo-apk-installer.desktop\n' > "$MIMEAPPS"
      : > "$NOTIF_REC"
      printf 'a\nb\n' > "$RESYNC_QUEUE"; echo 4 > "$RESYNC_QUEUE_STATE"
      date +%s.%N > "$RESYNC_TRIGGER"
      printf 'init=4242 trigger=%s\n' "$(head -n 1 "$RESYNC_TRIGGER")" > "$RESYNC_SYNCED"
      cp "$RESYNC_SYNCED" "$PRUNE_SYNCED"
      echo inactive > "$G/state"; echo inactive > "$G/prune-state"; echo active > "$G/prune-path"
      printf 'printf ... > %s\n' "$RESYNC_SYNCED" > "$RESYNC_SCRIPT"
      printf 'printf ... > %s\n' "$PRUNE_SYNCED" > "$PRUNE_SCRIPT"
      INIT=4242
    }
    probe() {
      local rc
      entry_sync_idle >/dev/null 2>&1; rc=$?
      (( rc == $2 )) || casefail "$1" "entry_sync_idle returned $rc ($ESI_VERDICT), want $2: $(tr '\n' ' ' <<<"$POLL_READ")"
    }
    owe() {
      date +%s.%N > "$RESYNC_TRIGGER"
      printf '%s\n' "$1" > "$G/on-complete"
      echo active > "$G/state"
      echo active > "$G/prune-state"
    }
    casefail() { echo "CASE-FAIL $1: $2"; }
    expect() {
      MSGS="" FAILED=0
      install_uninstall_via_entry_action 1 n0 "$PKG" "$ENTRY_PATH" "$ENTRY_NAME" "$ENTRY_TEXT" >/dev/null 2>&1
      if [[ "$2" == pass ]]; then
        (( FAILED == 0 )) || casefail "$1" "want a pass, failed: ${MSGS//$'\n'/ | }"
      elif (( FAILED == 0 )); then
        casefail "$1" "want a failure naming '$2', it passed"
      elif [[ "$MSGS" != *"$2"* ]]; then
        casefail "$1" "failed, but not naming '$2': ${MSGS//$'\n'/ | }"
      fi
    }

    reset_guest
    expect "settled guest" pass

    reset_guest
    owe "$(printf 'printf "[Desktop Entry]\\nName=A\\n" > %q/rhizo-com.rhizo.audiotest.a.desktop' "$APPS_DIR")"
    expect "owed run lands mid-window" pass
    [[ -f "$APPS_DIR/rhizo-com.rhizo.audiotest.a.desktop" ]] \
      || casefail "owed run lands mid-window" "the owed run never wrote its entry: the case proved nothing"

    reset_guest
    printf 'f=%q; cp "$f" "$f.tmp" && mv "$f.tmp" "$f"\n' "$G/apps/rhizo-com.android.calendar.desktop" > "$G/removal-run"
    expect "removal run rewrites identically" pass

    reset_guest
    printf 'rm -f %q\n' "$G/apps/rhizo-com.android.calendar.desktop" > "$G/removal-now"
    expect "removal deletes another entry" "changed other files"

    reset_guest
    printf 'echo Comment=late >> %q\n' "$G/apps/rhizo-com.android.calendar.desktop" > "$G/removal-run"
    expect "removal run edits another entry" "changed other files"

    reset_guest
    date +%s.%N > "$RESYNC_TRIGGER"; echo failed > "$G/state"
    expect "failed unit owing a trigger" "rhizo-resync.service is failed"

    reset_guest
    rm -f "$RESYNC_SYNCED"; date +%s.%N > "$RESYNC_TRIGGER"; touch "$G/no-stamp"
    echo 'echo "[rhizo-resync] synced init $INIT"' > "$RESYNC_SCRIPT"
    expect "deployed resync records no stamp" "records no synced stamp"

    reset_guest
    printf 'c\n' >> "$RESYNC_QUEUE"
    printf 'echo 6 > %q; printf "[Desktop Entry]\\nName=B\\n" > %q/rhizo-com.rhizo.audiotest.b.desktop\n' \
      "$RESYNC_QUEUE_STATE" "$APPS_DIR" > "$G/on-next"
    expect "queued package lands mid-window" pass
    reset_guest
    touch -r "$RESYNC_TRIGGER" "$G/tick"
    date +%s.%N > "$RESYNC_TRIGGER"
    touch -r "$G/tick" "$RESYNC_TRIGGER"
    probe "trigger content moved within one mtime" 1

    reset_guest
    echo active > "$G/prune-state"
    probe "prune active, resync idle" 1
    reset_guest
    date +%s.%N > "$RESYNC_TRIGGER"
    printf 'init=4242 trigger=%s\n' "$(head -n 1 "$RESYNC_TRIGGER")" > "$RESYNC_SYNCED"
    probe "prune owed, resync idle" 1
    reset_guest
    entry_of com.gone > "$G/apps/rhizo-com.gone.desktop"
    printf 'rm -f %q\n' "$G/apps/rhizo-com.gone.desktop" > "$G/prune-complete"
    echo active > "$G/prune-state"
    expect "owed prune lands mid-window" pass
    [[ -f "$G/apps/rhizo-com.gone.desktop" ]] \
      && casefail "owed prune lands mid-window" "the owed prune never ran: the case proved nothing"
    reset_guest
    echo inactive > "$G/prune-path"; echo none > "$PRUNE_SYNCED"
    probe "prune masked" 0

    reset_guest
    echo failed > "$G/prune-state"
    expect "failed prune" "rhizo-remove-entries.service is failed"

    reset_guest
    printf 'nosandbox trigger=%s\n' "$(head -n 1 "$RESYNC_TRIGGER")" > "$RESYNC_SYNCED"
    expect "resync found no sandbox" "found no sandbox up"

    reset_guest
    INIT=""
    expect "empty INIT refused" "no Android init pid"
    INIT=4242

    for want in "timeout names the last run|the last resync run ended ExecMainStatus=1 Result=exit-code" \
                "timeout names the stamp it wanted|want synced=init=4242 trigger=@TRIG@"; do
      reset_guest
      date +%s.%N > "$RESYNC_TRIGGER"
      echo 1 > "$G/last-status"; echo exit-code > "$G/last-result"
      w=${want#*|}
      expect "${want%%|*}" "${w/@TRIG@/$(head -n 1 "$RESYNC_TRIGGER")}"
    done

    reset_guest
    ssh_vm() { [[ "$1" == -t ]] && shift 2; case "$1" in *rhizo-resync.service*) return 255 ;; esac; bash -c "$1"; }
    expect "unanswered sync read" "answered none of 3 reads"
    exit 0
  )
}

# print the failing cases for a label
report() {
  if grep -q '^CASE-FAIL' <<<"$2"; then
    grep '^CASE-FAIL' <<<"$2" | sed "s/^/FAIL: $1: /"
    return 1
  fi
  return 0
}

out=$(run_cases "$HERE/../system")
report check-install-removal-window "$out" || exit 1
if [[ "${1:-}" != "--selftest" ]]; then
  echo "check-install-removal-window: OK (the removal window holds only the removal, and a removal touching another entry still fails)"
  exit 0
fi

# run the cases against a mutated install-lib.sh
mutant() {
  local scratch got
  scratch=$(mktemp -d) || return 1
  mkdir -p "$scratch/test/system/lib" "$scratch/src/services/appsync" || return 1
  cp -a "$HERE"/../system/lib/install-lib.sh "$scratch/test/system/lib/"
  cp -a "$HERE"/../../src/services/appsync/resync.service "$scratch/src/services/appsync/"
  sed -i "$2" "$scratch/test/system/lib/install-lib.sh"
  if cmp -s "$HERE/../system/lib/install-lib.sh" "$scratch/test/system/lib/install-lib.sh"; then
    echo "SELFTEST FAIL: the mutation for '$1' changed nothing in install-lib.sh"; rm -rf "$scratch"; return 1
  fi
  got=$(run_cases "$scratch/test/system")
  rm -rf "$scratch"
  grep -q "^CASE-FAIL $1:" <<<"$got" || { echo "SELFTEST FAIL: with its fix cut out of install-lib.sh, '$1' still passed"; return 1; }
}
MUT_DIR=$(mktemp -d) || exit 1
trap 'rm -rf "$MUT_DIR"' EXIT
i=0
# run a command in the background with its output in a numbered file
bg() { "$@" > "$MUT_DIR/$i" 2>&1 & i=$((i + 1)); }
bg mutant "owed run lands mid-window" '/await_entry_sync_idle "the removal of \$pkg: before its snapshot"/d'
bg mutant "removal run edits another entry" '/await_entry_sync_idle "the removal of \$pkg: after it"/d'
bg mutant "queued package lands mid-window" 's/ \&\& "\$q" == "\$d"//'
bg mutant "failed unit owing a trigger" 's/\[\[ "\$state" == failed \]\] \&\& {[^}]*}/:/'
bg mutant "deployed resync records no stamp" '/-qx .stamping=/d'
bg mutant "prune active, resync idle" 's/\[\[ "\$(_esi_field prune_path)" == active \]\] \&\& prune_on=1 || prune_on=0/prune_on=0/'
bg mutant "prune owed, resync idle" 's/"\$prune_synced" == \*" trigger=\$trig"/"$prune_synced" == *" trigger="*/'
bg mutant "failed prune" 's/\[\[ "\$prune" == failed \]\] \&\& {[^}]*}/:/'
bg mutant "resync found no sandbox" '/ESI_VERDICT=nosandbox; return 0/d'
bg mutant "empty INIT refused" '/no Android init pid to tie/d'
bg mutant "timeout names the last run" 's/; the last resync run ended \$(_esi_field last_run)//'
bg mutant "timeout names the stamp it wanted" 's/want synced=init=\$INIT trigger=\$(_esi_field trigger), //'
bg mutant "settled guest" 's/head -n 1 \$RESYNC_TRIGGER/stat -c %y $RESYNC_TRIGGER/'
bg mutant "unanswered sync read" 's/(( ++unanswered >= 3 ))/false/'
wait
rc=0
for (( j = 0; j < i; j++ )); do
  if [[ ! -e "$MUT_DIR/$j" ]]; then echo "SELFTEST FAIL: mutant $j left no result"; rc=1
  elif [[ -s "$MUT_DIR/$j" ]]; then cat "$MUT_DIR/$j"; rc=1; fi
done
(( rc == 0 )) && echo "check-install-removal-window --selftest: OK (each wait cut back out is caught by its own case)"
exit "$rc"
