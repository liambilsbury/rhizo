#!/bin/bash
# define the install, uninstall and handoff helpers
declare -F st        >/dev/null || st()        { printf '%s' "$1"; }
declare -F st_const  >/dev/null || st_const()  { printf '%s' "$1"; }
declare -F st_inject >/dev/null || st_inject() { printf '%s' "$1"; }
declare -F nonce     >/dev/null || nonce()     { head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# run a shell script as the desktop user
user_sh() {
  local b64
  b64=$(printf '%s' "$2" | base64 -w0)
  ssh_vm -t "$1" "echo '$b64' | base64 -d | runuser -u $DESK_USER -- env HOME=$DESK_HOME XDG_RUNTIME_DIR=$DESK_RUNTIME_DIR WAYLAND_DISPLAY=wayland-1 DBUS_SESSION_BUS_ADDRESS='$BUS_ADDR' PATH=/usr/local/bin:/usr/bin:/bin /usr/bin/bash -s"
}

# print a key of a desktop entry's section
entry_field() {
  awk -F= -v k="$2" '
    function unescape(s,   out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < length(s)) {
          i++
          c = substr(s, i, 1)
          if (c == "s") c = " "
          else if (c == "n") c = "\n"
          else if (c == "t") c = "\t"
          else if (c != "\\") out = out "\\"
        }
        out = out c
      }
      return out
    }
    /^\[/ { sect = ($0 == "[Desktop Entry]") }
    sect && $1 == k { sub(/^[^=]*=/, ""); print unescape($0); exit }' <<<"$1"
}

# print the Exec= line of one [Desktop Action <name>] section
action_exec() {
  awk -v want="[Desktop Action $2]" '$0 == want { sect = 1; next } /^\[/ { sect = 0 } sect && /^Exec=/ { sub(/^Exec=/, ""); print; exit }' <<<"$1"
}

# print an Exec= line without field codes
exec_command() {
  sed -e 's/%[uUfFdDnNickvm]//g' -e 's/[[:space:]]\+/ /g' -e 's/[[:space:]]*$//' <<<"$1"
}

# run a probe until it succeeds or the deadline passes
poll_until() {
  local deadline=$(( $(date +%s) + $1 )) nap="$2"
  shift 2
  POLL_READ=""
  while :; do
    "$@" && return 0
    (( $(date +%s) < deadline )) || return 1
    sleep "$nap"
  done
}

# read the resumed activity on a logical display
resumed_on_display() {
  local out rc seg
  RESUMED_READ=""
  out=$(android_sh "$1" "dumpsys activity activities; echo RHIZO_DUMP_RC=\$?"); rc=$?
  printf '%s\n' "${out:-<empty read, android_sh rc=$rc>}" > "$3"
  (( rc == 0 )) || return 2
  [[ "$out" == *$'\n'RHIZO_DUMP_RC=0 ]] || return 2
  grep -q '^ACTIVITY MANAGER ACTIVITIES' <<<"$out" || return 2
  seg=$(awk -v want="Display #$2 " '
    /Display #/ { if (inseg) exit; if (index($0, want) == 1) { inseg = 1; ti = 0; print "SEGMENT" }; next }
    inseg && (/^[^ ]/ || /^ *ResumedActivity: / || /Resumed activities/) { exit }
    inseg && /\* Task[{]/ { i = match($0, /[^ ]/); if (ti && i <= ti) exit; if (!ti) ti = i; next }
    inseg && /topResumedActivity=/ {
      line = $0
      if (match(line, /ActivityRecord[{][^ ]* [^ ]* [^ }]+/)) {
        n = split(substr(line, RSTART, RLENGTH), f, " ")
        print "RESUMED " f[n]
      } else {
        sub(/^ */, "", line)
        print "RESUMED " line
      }
      exit
    }' <<<"$out")
  [[ "$seg" == SEGMENT* ]] || return 3
  RESUMED_READ=$(sed -n 's/^RESUMED //p' <<<"$seg")
  [[ -n "$RESUMED_READ" ]] || return 4
}

# wait for a resumed activity on a display
await_resumed_on_display() {
  local deadline=$(( $(date +%s) + ${4:-10} )) st
  while :; do
    resumed_on_display "$1" "$2" "$3"; st=$?
    (( st == 4 && $(date +%s) < deadline )) || return "$st"
    sleep "${5:-0.5}"
  done
}

# print each display with a resumed activity of the package
resumed_where() {
  awk -v pkg=" $1/" '
    /^Display #/ { d = $2; sub(/^#/, "", d); next }
    /topResumedActivity=/ && index($0, pkg) { l = $0; sub(/^ */, "", l); print "display " d ": " l }' "$2"
}

# print PRESENT or ABSENT for a guest file
guest_file_state() {
  ssh_vm -t 10 "if [ -f '$1' ]; then echo PRESENT; else echo ABSENT; fi" | tr -d '\r'
}
# return true when a guest file's state matches
guest_file_is() {
  [[ "$(guest_file_state "$2")" == "$1" ]]
}
# wait until a guest file is present
wait_guest_file() {
  poll_until "$1" 2 guest_file_is PRESENT "$2"
}

# print the guest's clock
guest_now() {
  ssh_vm -t 10 'date +%s.%N' | tr -d '\r' | tail -1
}

DRAIN_ENTRY_WAIT_S=${DRAIN_ENTRY_WAIT_S:-240}

# return true when the queue drain wrote this install's entry
drain_wrote_entry() {
  local pkg="$2" since="$3"
  [[ "$since" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  _drain_line_after() {
    POLL_READ=$(ssh_vm -t 20 'journalctl -b -u rhizo-resync.service -o short-unix --no-pager 2>/dev/null; echo DONE' | tr -d '\r')
    [[ "$POLL_READ" == *DONE ]] || return 1
    awk -v s="$since" -v want="[rhizo-appsync] package $pkg: entry " '
      ($1 + 0) >= (s + 0) && index($0, want) && / written, defaults / { f = 1 }
      END { exit !f }' <<<"$POLL_READ"
  }
  poll_until "$1" 2 _drain_line_after
}

RESYNC_TRIGGER=${RESYNC_TRIGGER:-/run/rhizo-app-events/trigger}
RESYNC_QUEUE=${RESYNC_QUEUE:-/run/rhizo-app-events/queue}
RESYNC_QUEUE_STATE=${RESYNC_QUEUE_STATE:-/run/rhizo-resync/queue.offset}
RESYNC_SYNCED=${RESYNC_SYNCED:-/run/rhizo-resync/synced}
PRUNE_SYNCED=${PRUNE_SYNCED:-/run/rhizo-remove-entries/synced}
RESYNC_SCRIPT=${RESYNC_SCRIPT:-/usr/lib/rhizo/tools/resync.sh}
PRUNE_SCRIPT=${PRUNE_SCRIPT:-/usr/lib/rhizo/tools/remove-entries.sh}
RESYNC_POLL_S=${RESYNC_POLL_S:-2}

# print the longest a run of rhizo-resync.service can hold the unit
resync_bound() {
  sed -n 's/^RuntimeMaxSec=\([0-9][0-9]*\)$/\1/p' "$(dirname "${BASH_SOURCE[0]}")/../../../src/services/appsync/resync.service"
}

# print a key=value field of entry_sync_idle's read
_esi_field() {
  sed -n "s/^$1=//p" <<<"$POLL_READ" | head -1
}

# read whether the entry sync is idle
entry_sync_idle() {
  local state q d trig synced prune_on prune prune_synced
  ESI_VERDICT=unanswered
  POLL_READ=$(ssh_vm -t 20 "systemctl is-active rhizo-resync.service 2>/dev/null
echo queue=\$(stat -c %s $RESYNC_QUEUE 2>/dev/null || echo 0)
echo drained=\$(cat $RESYNC_QUEUE_STATE 2>/dev/null || echo 0)
t=\$(head -n 1 $RESYNC_TRIGGER 2>/dev/null); echo trigger=\${t:-none}
echo synced=\$(cat $RESYNC_SYNCED 2>/dev/null || echo none)
echo stamping=\$(grep -cF '$RESYNC_SYNCED' $RESYNC_SCRIPT 2>/dev/null)
echo last_run=\$(systemctl show -p ExecMainStatus -p Result rhizo-resync.service 2>/dev/null | tr '\n' ' ')
echo prune_path=\$(systemctl is-active rhizo-remove-entries.path 2>/dev/null)
echo prune=\$(systemctl is-active rhizo-remove-entries.service 2>/dev/null)
echo prune_synced=\$(cat $PRUNE_SYNCED 2>/dev/null || echo none)
echo prune_stamping=\$(grep -cF '$PRUNE_SYNCED' $PRUNE_SCRIPT 2>/dev/null)
echo DONE" | tr -d '\r')
  [[ "$POLL_READ" == *DONE ]] || return 2
  state=$(head -1 <<<"$POLL_READ")
  q=$(_esi_field queue)
  d=$(_esi_field drained)
  trig=$(_esi_field trigger)
  synced=$(_esi_field synced)
  prune=$(_esi_field prune)
  prune_synced=$(_esi_field prune_synced)
  [[ "$(_esi_field prune_path)" == active ]] && prune_on=1 || prune_on=0
  [[ "$state" == failed ]] && { ESI_VERDICT="failed:rhizo-resync.service"; return 0; }
  grep -qx 'stamping=[1-9][0-9]*' <<<"$POLL_READ" || { ESI_VERDICT="unstamped:$RESYNC_SCRIPT"; return 0; }
  if (( prune_on )); then
    [[ "$prune" == failed ]] && { ESI_VERDICT="failed:rhizo-remove-entries.service"; return 0; }
    grep -qx 'prune_stamping=[1-9][0-9]*' <<<"$POLL_READ" || { ESI_VERDICT="unstamped:$PRUNE_SCRIPT"; return 0; }
  fi
  ESI_VERDICT=owed
  [[ "$state" == inactive && "$synced" == "nosandbox trigger=$trig" ]] && { ESI_VERDICT=nosandbox; return 0; }
  if (( prune_on )); then
    [[ "$prune" == inactive && "$prune_synced" == *" trigger=$trig" ]] || return 1
  fi
  [[ "$state" == inactive && "$q" =~ ^[0-9]+$ && "$q" == "$d" && "$synced" == *" trigger=$trig" ]] || return 1
  [[ "$synced" == "init=$INIT trigger=$trig" ]] || { ESI_VERDICT=otherinit; return 0; }
  if (( prune_on )); then
    [[ "$prune_synced" == "init=$INIT trigger=$trig" || "$prune_synced" == "nosandbox trigger=$trig" ]] \
      || { ESI_VERDICT=otherinit; return 0; }
  fi
  ESI_VERDICT=idle
}

# wait until the entry sync is idle
await_entry_sync_idle() {
  local bound t0 rc unanswered=0 read_line
  if [[ ! "${INIT:-}" =~ ^[0-9]+$ ]]; then
    fail "$1: no Android init pid to tie the entry sync to (INIT='${INIT:-}')"
    return 1
  fi
  bound=${2:-$(resync_bound)}
  if [[ ! "$bound" =~ ^[0-9]+$ ]]; then
    fail "$1: rhizo-resync.service declares no RuntimeMaxSec= to bound the entry-sync wait by (read '${bound:-<nothing>}')"
    return 1
  fi
  t0=$(date +%s)
  while :; do
    entry_sync_idle; rc=$?
    (( rc == 0 )) && break
    if (( rc == 2 )); then
      if (( ++unanswered >= 3 )); then
        fail "$1: the guest answered none of 3 reads of the entry sync's state (last read: $(tr '\n' ' ' <<<"${POLL_READ:-<nothing>}"))"
        return 1
      fi
    else
      unanswered=0
    fi
    if (( $(date +%s) - t0 >= bound )); then
      fail "$1: the entry sync still owed a run after ${bound}s (rhizo-resync.service's RuntimeMaxSec=): want synced=init=$INIT trigger=$(_esi_field trigger), read '$(_esi_field synced)'; rhizo-resync.service $(head -1 <<<"$POLL_READ"), queue $(_esi_field queue) drained $(_esi_field drained); the last resync run ended $(_esi_field last_run); rhizo-remove-entries.path $(_esi_field prune_path), rhizo-remove-entries.service $(_esi_field prune), prune stamp '$(_esi_field prune_synced)'; read: $(tr '\n' ' ' <<<"${POLL_READ:-<no read>}")"
      return 1
    fi
    sleep "$RESYNC_POLL_S"
  done
  read_line=$(tr '\n' ' ' <<<"$POLL_READ")
  case "$ESI_VERDICT" in
    failed:*)
      fail "$1: ${ESI_VERDICT#failed:} is failed (the last resync run ended $(_esi_field last_run)): $read_line"
      return 1 ;;
    unstamped:*)
      fail "$1: the deployed ${ESI_VERDICT#unstamped:} records no synced stamp -- redeploy this tree: $read_line"
      return 1 ;;
    nosandbox)
      fail "$1: resync.sh's last run found no sandbox up (stamp '$(_esi_field synced)'): $read_line"
      return 1 ;;
    otherinit)
      fail "$1: the last clean runs covered the trigger as it stands but not this sandbox's init $INIT -- resync stamp '$(_esi_field synced)', prune stamp '$(_esi_field prune_synced)' (the last resync run ended $(_esi_field last_run)): $read_line"
      return 1 ;;
  esac
  log "    $1: entry sync idle after $(( $(date +%s) - t0 ))s ($(grep -E '^(queue|drained|synced|prune_synced)=' <<<"$POLL_READ" | tr '\n' ' '))"
}

# print the last RHIZO_* sentinel the CLI printed
sentinel_of() {
  grep -a -o "$2.*" <<<"$1" | tail -1 | tr -d '\r'
}

# print how many notifications the sink has recorded
notif_count() {
  ssh_vm -t 10 "if [ -f $NOTIF_REC ]; then wc -l < $NOTIF_REC; else echo 0; fi" | tr -d '\r'
}
# return true when the sink recorded a new notification
notif_arrived() {
  local now
  now=$(notif_count)
  [[ "${now:-0}" =~ ^[0-9]+$ ]] && (( now > $1 ))
}

# list all of the hicolor icon files for a package
icon_list() {
  ssh_vm -t 20 "find $ICONS_DIR -type f -name 'rhizo-$1.png' -print; echo LISTED" | tr -d '\r'
}

# print the sha256 of each file in /usr/share/applications
apps_dir_shas() {
  ssh_vm -t 30 "find $APPS_DIR -maxdepth 1 -type f -print0 | sort -z | xargs -0 -r sha256sum; echo LISTED" | tr -d '\r'
}

# print the record the sink wrote after a mark
wait_notif() {
  local mark="${1:-0}"
  [[ "$mark" =~ ^[0-9]+$ ]] || mark=0
  poll_until "$2" 2 notif_arrived "$mark" || return 1
  ssh_vm -t 10 "tail -1 $NOTIF_REC"
}


# install an APK by opening it with xdg-open
install_apk_via_broker() {
  local cyc="$1" apk_path="$2" apk_sha="$3" pkg="$4" label="$5" entry_path="$6" entry_id="$7"
  local guest_apk landed pkgs_before notif_mark open_out pkgs_after newly inbox_state
  local entry_name entry_icon icons notif notif_summary

  guest_apk="$DOWNLOADS/$(nonce).apk"
  base64 -w0 "$apk_path" > "$WORKDIR/fixture.b64"
  ssh_vm -t 120 "runuser -u $DESK_USER -- sh -c 'base64 -d > $guest_apk'" < "$WORKDIR/fixture.b64" \
    || fail "could not write the fixture into $guest_apk as $DESK_USER"
  landed=$(user_sh 40 "sha256sum $guest_apk | cut -d' ' -f1" | tr -d '\r')
  [[ "$landed" == "$apk_sha" ]] || fail "the APK in $guest_apk hashes $landed, the fixture is $apk_sha"

  pkgs_before=$(android_sh "$INIT" "pm list packages" | sort)
  notif_mark=$(notif_count)
  local since; since=$(guest_now)
  open_out=$(user_sh 240 "xdg-open $guest_apk 2>&1; echo XDG_RC=\$?")
  printf '%s\n' "$open_out" > "$EV/cycle$cyc-xdg-open-install.log"
  log "    xdg-open said: $(tr '\n' '|' <<<"$open_out" | tail -c 300)"
  pkg_listed() { POLL_READ=$(android_sh "$INIT" "pm list packages" | sort); grep -qx "package:$pkg" <<<"$POLL_READ"; }
  if ! poll_until 180 3 pkg_listed; then
    log "    $pkg not in pm list packages within 180s of the handler launch"
  fi
  pkgs_after=$(st_const "$POLL_READ")
  grep -qx "package:$pkg" <<<"$pkgs_after" || fail "$pkg does not appear in pm list packages after the handler ran"
  newly=$(comm -13 <(printf '%s\n' "$pkgs_before") <(printf '%s\n' "$pkgs_after"))
  grep -qx "package:$pkg" <<<"$newly" || fail "the pm list packages before/after diff does not include $pkg"

  inbox_state=$(ssh_vm -t 15 "if [ -d $INBOX ]; then echo INBOX=\$(find $INBOX -type f | wc -l); else echo INBOX=NODIR; fi" | tr -d '\r')
  [[ "$inbox_state" == "INBOX=0" ]] \
    || fail "the inbox reads '$inbox_state' after the install, expected INBOX=0 (NODIR is $INBOX missing or unreadable to root)"

  drain_wrote_entry "$DRAIN_ENTRY_WAIT_S" "$pkg" "$since" \
    || fail "no drain line for $pkg in rhizo-resync.service's journal at or after the install (guest clock ${since:-<unread>}) within ${DRAIN_ENTRY_WAIT_S}s"
  wait_guest_file 240 "$entry_path" \
    || fail "no $entry_path within 240s"
  entry_text=$(ssh_vm -t 15 "cat $entry_path")
  printf '%s\n' "$entry_text" > "$EV/cycle$cyc-entry.desktop"
  entry_name=$(st "$(entry_field "$entry_text" Name)")
  entry_icon=$(entry_field "$entry_text" Icon)
  [[ "$entry_name" == "$label" ]] || fail "the entry's Name= is '$entry_name', this system test's own aapt2 run read '$label'"
  [[ "$(entry_field "$entry_text" X-Rhizo-Package)" == "$pkg" ]] || fail "the entry carries no X-Rhizo-Package=$pkg"
  icons=$(icon_list "$pkg")
  grep -qx LISTED <<<"$icons" || fail "the hicolor walk did not complete"
  if [[ "$entry_icon" == "$entry_id" ]]; then
    (( $(grep -c "/rhizo-$pkg.png\$" <<<"$icons") > 0 )) || fail "Icon=$entry_icon names no file under $ICONS_DIR"
  else
    [[ "$entry_icon" == rhizo ]] || fail "the entry's Icon= is '$entry_icon', expected $entry_id or rhizo"
    [[ "$(guest_file_state "$ICONS_DIR/256x256/apps/rhizo.png")" == PRESENT ]] \
      || fail "Icon=rhizo but no generic icon at $ICONS_DIR/256x256/apps/rhizo.png"
  fi
  printf '%s\n' "$icons" > "$EV/cycle$cyc-icons.txt"

  notif=$(wait_notif "$notif_mark" 45)
  if [[ -z "$notif" ]]; then
    fail "no notification reached the user's session bus for the install"
  else
    printf '%s\n' "$notif" > "$EV/cycle$cyc-install-notification.json"
    notif_summary=$(st "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["summary"])' "$EV/cycle$cyc-install-notification.json")")
    grep -qF "$label" <<<"$notif_summary" \
      || fail "the install notification's summary is '$notif_summary', which does not name '$label'"
  fi
  pass "an APK the user dropped in their own Downloads was installed by the host's handler, entry and icons synthesized, the user notified"
}

# remove a package through its entry's Uninstall action
install_uninstall_via_entry_action() {
  local cyc="$1" nn="$2" pkg="$3" entry_path="$4" entry_filename="$5" entry_text_in="$6"
  local canary shas_before notif_mark remove_value remove_cmd remove_out removed_sentinel
  local pkgs_gone icons_gone mimeapps_text shas_after remove_notif

  canary="zz-canary-$nn.desktop"
  ssh_vm -t 20 "printf '[Desktop Entry]\nType=Application\nName=Canary $nn\nExec=/bin/true\nNoDisplay=true\n' > $APPS_DIR/$canary
printf '[Desktop Entry]\nType=Application\nName=Rhizo lookalike\nExec=/bin/true\nNoDisplay=true\n' > $APPS_DIR/rhizo-lookalike.desktop" \
    || fail "could not plant the canary entries"
  await_entry_sync_idle "the removal of $pkg: before its snapshot"
  shas_before=$(apps_dir_shas)
  grep -qx LISTED <<<"$shas_before" || fail "the pre-removal listing of $APPS_DIR did not complete"
  printf '%s\n' "$shas_before" > "$EV/cycle$cyc-apps-shas-before.txt"

  notif_mark=$(notif_count)
  remove_value=$(action_exec "$entry_text_in" Uninstall)
  remove_cmd=$(exec_command "$remove_value")
  [[ "$remove_cmd" == "rhizo app remove $pkg" ]] \
    || fail "the entry's [Desktop Action Uninstall] Exec= is '$remove_value', expected 'rhizo app remove $pkg'"
  remove_out=$(user_sh 240 "$remove_cmd 2>&1; echo EXEC_RC=\$?")
  printf '%s\n' "$remove_out" > "$EV/cycle$cyc-remove.log"
  removed_sentinel=$(sentinel_of "$remove_out" "RHIZO_APP removed=")
  [[ "$removed_sentinel" == "RHIZO_APP removed=$pkg" ]] \
    || fail "the Uninstall action printed '$removed_sentinel', expected 'RHIZO_APP removed=$pkg'"

  poll_until 240 2 guest_file_is ABSENT "$entry_path" \
    || fail "$entry_path is still there 240s after the package was removed"
  await_entry_sync_idle "the removal of $pkg: after it"
  pkgs_gone=$(st_inject "$(android_sh "$INIT" "pm list packages" | sort)" "package:$pkg")
  grep -qx "package:$pkg" <<<"$pkgs_gone" && fail "$pkg is still in pm list packages after the Uninstall action"
  icons_gone=$(st_inject "$(icon_list "$pkg")" "$ICONS_DIR/48x48/apps/rhizo-$pkg.png")
  grep -qx LISTED <<<"$icons_gone" || fail "the post-removal hicolor walk did not complete"
  (( $(grep -c "/rhizo-$pkg.png\$" <<<"$icons_gone") == 0 )) \
    || fail "hicolor still carries $(grep -c "/rhizo-$pkg.png\$" <<<"$icons_gone") icon(s) for the removed package"
  mimeapps_text=$(st_inject "$(ssh_vm -t 15 "cat $MIMEAPPS; echo LISTED")" "$entry_filename")
  printf '%s\n' "$mimeapps_text" > "$EV/cycle$cyc-mimeapps-after.txt"
  grep -qx LISTED <<<"$mimeapps_text" || fail "could not read $MIMEAPPS after the removal"
  grep -qF "$entry_filename" <<<"$mimeapps_text" && fail "$MIMEAPPS still names $entry_filename after the removal"
  grep -qF "application/vnd.android.package-archive=rhizo-apk-installer.desktop" <<<"$mimeapps_text" \
    || fail "$MIMEAPPS no longer maps the APK type to rhizo-apk-installer.desktop"

  shas_after=$(st_const "$(apps_dir_shas)")
  printf '%s\n' "$shas_after" > "$EV/cycle$cyc-apps-shas-after.txt"
  filter_shas() { grep -v -e " $entry_path\$" -e " $MIMEAPPS\$" -e " $MIMEINFO\$"; }
  if diff <(filter_shas <<<"$shas_before") <(filter_shas <<<"$shas_after") > "$EV/cycle$cyc-apps-shas.diff"; then
    pass "the package, its entry, its icons and its mimeapps lines are gone; every other entry is byte-identical"
  else
    fail "removing $pkg changed other files in $APPS_DIR (see $EV/cycle$cyc-apps-shas.diff)"
    sed 's/^/    | /' "$EV/cycle$cyc-apps-shas.diff" | head -10
  fi
  remove_notif=$(wait_notif "$notif_mark" 45)
  [[ -n "$remove_notif" ]] || fail "no notification reached the user's session bus for the removal"
  printf '%s\n' "$remove_notif" > "$EV/cycle$cyc-remove-notification.json"
  ssh_vm -t 20 "rm -f $APPS_DIR/$canary $APPS_DIR/rhizo-lookalike.desktop" >/dev/null
}

# open a Downloads file through xdg-open and check the handoff
install_file_handoff() {
  local entry_filename="$1"
  local _before_failed=$FAILED
  local note_n note_name note_sha note_len user_default want_uri got_uri got_bytes

  note_n=$(nonce)
  note_name="note-$note_n.txt"
  printf 'rhizo host file %s\n' "$note_n" > "$WORKDIR/$note_name"
  note_sha=$(sha256sum "$WORKDIR/$note_name" | cut -d' ' -f1)
  note_len=$(stat -c %s "$WORKDIR/$note_name")
  base64 -w0 "$WORKDIR/$note_name" > "$WORKDIR/note.b64"
  ssh_vm -t 60 "runuser -u $DESK_USER -- sh -c 'base64 -d > $DOWNLOADS/$note_name'" < "$WORKDIR/note.b64" \
    || fail "could not write $DOWNLOADS/$note_name as $DESK_USER"
  [[ "$(guest_file_state "$APPS_DIR/$entry_filename")" == PRESENT ]] \
    || { fail "the handoff's entry $APPS_DIR/$entry_filename is absent"; return 1; }
  local mime_set mime_rc
  mime_set=$(user_sh 40 "xdg-mime default $entry_filename text/plain 2>&1; echo XDG_MIME_RC=\$?" | tr -d '\r')
  mime_rc=$(sentinel_of "$mime_set" XDG_MIME_RC=)
  mime_rc=${mime_rc#XDG_MIME_RC=}
  [[ "$mime_rc" == 0 ]] \
    || { fail "xdg-mime default $entry_filename text/plain exited ${mime_rc:-<no rc: the call never completed>} (${mime_set:-<no output>})"; return 1; }
  user_default=$(user_sh 30 "xdg-mime query default text/plain" | tr -d '\r')
  [[ "$user_default" == "$entry_filename" ]] \
    || fail "xdg-mime resolves text/plain to '$user_default', not $entry_filename"
  local view_since; view_since=$(logcat_since_marker "$INIT")
  user_sh 120 "xdg-open $DOWNLOADS/$note_name 2>&1; echo XDG_RC=\$?" > "$EV/xdg-open-note.log" 2>&1
  want_uri="file:///storage/emulated/0/$SHARE_NAME/$note_name"
  got_uri=$(st "$(app_wait_token "RHIZO_VIEW uri=[^ ]*" 90 "$view_since")")
  [[ "$got_uri" == "RHIZO_VIEW uri=$want_uri" ]] \
    || fail "the app received '$got_uri', the host opened $DOWNLOADS/$note_name (expected uri=$want_uri)"
  got_bytes=$(st "$(app_wait_token "RHIZO_VIEW_BYTES .*" 60 "$view_since")")
  printf '%s\n' "$got_bytes" > "$EV/view-bytes.txt"
  [[ "$got_bytes" == "RHIZO_VIEW_BYTES sha256=$note_sha len=$note_len" ]] \
    || fail "the app read '$got_bytes', the host file is sha256=$note_sha len=$note_len"
  (( FAILED == _before_failed )) \
    && pass "the bytes the app read through the file URI are the bytes in the user's own file"
  (( FAILED == _before_failed ))
}
