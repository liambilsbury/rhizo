#!/bin/bash
# pull the guest's boot evidence into a stamped directory
set -uo pipefail

GUARD_ONLY=0
ASSERT_ONLY=0
case "${1:-}" in
  --guard-only)  GUARD_ONLY=1; shift ;;
  --assert-only) ASSERT_ONLY=1; shift ;;
esac

DEST="${1:-}"
LABEL="${2:-}"
if [[ -z "$DEST" ]]; then
  echo "collect-boot-evidence.sh: usage: test/vm/boot/collect-boot-evidence.sh [--guard-only|--assert-only] <dest-dir> [label]" >&2
  exit 2
fi
[[ "$DEST" == /* ]] || DEST="$PWD/$DEST"
[[ -z "${RHIZO_PREFLIGHT_EVIDENCE:-}" || "$RHIZO_PREFLIGHT_EVIDENCE" == /* ]] \
  || RHIZO_PREFLIGHT_EVIDENCE="$PWD/$RHIZO_PREFLIGHT_EVIDENCE"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
[[ -n "$LABEL" ]] && STAMP="$STAMP-${LABEL//\//-}"
DEST="$DEST/$STAMP"

cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh
console="$VAR_DIR/vm-boot${SUFFIX}.log"
mkdir -p "$DEST" || { echo "collect-boot-evidence: cannot create $DEST" >&2; exit 2; }

MANIFEST="$DEST/MANIFEST.txt"
: > "$MANIFEST"
GOT=0
LOST=0
EARLIER=0

# append a line to the manifest
note() { echo "$*" >> "$MANIFEST"; }

# record an item as kept or missed
keep() {
  local name="$1" f="$2"
  if [[ -s "$f" ]]; then
    note "$(printf '%-22s %8s bytes  %s' "$name" "$(stat -c %s "$f")" "$(basename "$f")")"
    GOT=$((GOT + 1))
  else
    rm -f "$f"
    note "$(printf '%-22s %s' "$name" "EMPTY -- nothing was written")"
    LOST=$((LOST + 1))
  fi
}

# record an item as missed, with its reason
drop() {
  note "$(printf '%-22s %s' "$1" "$2")"
  LOST=$((LOST + 1))
}

# pull the Class X guard's per-display verdict log for this boot
collect_guard_log() {
  local guard_raw guard_out rest gearlier gcur
  guard_raw=$(ssh_vm -t 45 'bash -s' -- < "$REPO/test/vm/boot/collect-layerstack-guard.sh" 2>/dev/null)
  if [[ -z "$guard_raw" ]]; then
    drop "layerstack guard log" "vm $RHIZO_VM does not answer ssh on port $SSH_PORT"
    return
  fi
  guard_out="$DEST/layerstack-guard.txt"
  : > "$guard_out"
  while IFS= read -r line; do
    case "$line" in
      "STATUS none-existed "*) drop "layerstack guard log" "${line#STATUS none-existed }" ;;
      "STATUS unreadable "*)   drop "layerstack guard log" "${line#STATUS unreadable }" ;;
      "STATUS empty "*)
        note "$(printf '%-22s %s' "layerstack guard log" "EMPTY -- ${line#STATUS empty }")"
        LOST=$((LOST + 1))
        ;;
      "STATUS reference "*) ;;
      "LINE "*) echo "${line#LINE }" >> "$guard_out" ;;
      "SUMMARY "*)
        rest="${line#SUMMARY }"
        note "$(printf '%-22s %s' "layerstack guard log" "$rest")"
        gearlier=$(sed -n 's/.*earlier=\([0-9]*\).*/\1/p' <<<"$rest")
        gcur=$(sed -n 's/.*current=\([0-9]*\).*/\1/p' <<<"$rest")
        [[ "$gearlier" =~ ^[0-9]+$ ]] && (( gearlier > 0 )) && EARLIER=$((EARLIER + gearlier))
        [[ "$gcur" == "0" ]] && note "$(printf '%-22s %s' "layerstack guard log" \
          "0 line(s) date to this boot")"
        ;;
    esac
  done <<<"$guard_raw"
  if [[ -s "$guard_out" ]]; then
    keep "layerstack guard log" "$guard_out"
  else
    rm -f "$guard_out"
  fi
}

# copy the system test's log files
collect_test_ev_logs() {
  local ev="${RHIZO_TEST_EV_DIR:-}" f base found=0
  if [[ -z "$ev" ]]; then
    drop "test's own \$EV logs" "RHIZO_TEST_EV_DIR not set by the caller"
    return
  fi
  if [[ ! -d "$ev" ]]; then
    drop "test's own \$EV logs" "RHIZO_TEST_EV_DIR=$ev is not a directory"
    return
  fi
  for f in "$ev"/*.log; do
    [[ -e "$f" ]] || continue
    found=1
    base=$(basename "$f")
    cp -p "$f" "$DEST/test-ev-$base" 2>/dev/null
    keep "system test log: $base" "$DEST/test-ev-$base"
  done
  (( found )) || note "$(printf '%-22s %s' "test's own \$EV logs" "none exist yet under $ev")"
}

# write the entry sync's journal and state for this boot
collect_resync_journal() {
  local f="$DEST/resync-journal.txt" out body rc
  out=$(ssh_vm -t 45 '{ journalctl -b -q -u rhizo-resync.service -u rhizo-remove-entries.service -u rhizo-resync.path -u rhizo-remove-entries.path -u rhizo-app-events.service -u rhizo-resync-rearm.service -o short-iso-precise --no-pager 2>&1; echo "journalctl_rc=$?"; } | tail -n 3000
echo RHIZO_JOURNAL_END
echo "== rhizo-resync.service: $(systemctl is-active rhizo-resync.service 2>&1) rhizo-remove-entries.service: $(systemctl is-active rhizo-remove-entries.service 2>&1)"
echo "resync_lines=$(journalctl -b -q -u rhizo-resync.service -u rhizo-remove-entries.service --no-pager 2>/dev/null | wc -l)"
t=$(head -n 1 /run/rhizo-app-events/trigger 2>/dev/null); echo "trigger=${t:-none}"
echo "synced=$(cat /run/rhizo-resync/synced 2>/dev/null || echo none)"
echo "prune_synced=$(cat /run/rhizo-remove-entries/synced 2>/dev/null || echo none)"
echo "queue=$(stat -c %s /run/rhizo-app-events/queue 2>/dev/null || echo 0) drained=$(cat /run/rhizo-resync/queue.offset 2>/dev/null || echo 0)"
echo RHIZO_STATE_END' 2>/dev/null | tr -d '\r')
  if [[ "$out" != *RHIZO_STATE_END ]]; then
    printf '<unreachable>\n' > "$f"
    drop "resync journal" "vm $RHIZO_VM did not finish answering (resync-journal.txt reads <unreachable>)"
    return
  fi
  body=${out%%RHIZO_JOURNAL_END*}
  rc=$(sed -n 's/^journalctl_rc=//p' <<<"$body" | tail -1)
  body=$(sed '/^journalctl_rc=/d' <<<"$body")
  if [[ "$rc" != 0 ]]; then
    printf '%s\n' "$out" | sed -e '/^RHIZO_JOURNAL_END$/d' -e '/^RHIZO_STATE_END$/d' > "$f"
    drop "resync journal" "journalctl exited ${rc:-<unread>} (its stderr is in resync-journal.txt)"
    return
  fi
  if [[ -z "${body//[[:space:]]/}" || "$(sed -n 's/^resync_lines=//p' <<<"$out")" == 0 ]]; then
    { printf '<none>\n'; printf '%s\n' "$out" | sed -e '/^RHIZO_JOURNAL_END$/d' -e '/^RHIZO_STATE_END$/d'; } > "$f"
    note "$(printf '%-22s %s' "resync journal" "<none> -- journalctl exited 0 with no rhizo-resync/prune line this boot")"
    return
  fi
  printf '%s\n' "$out" | sed -e '/^RHIZO_JOURNAL_END$/d' -e '/^RHIZO_STATE_END$/d' > "$f"
  keep "resync journal" "$f"
  note "$(printf '%-22s %s' "" "journalctl exited 0")"
}

# collect the items for --assert-only
run_assert_only() {
  collect_guard_log

  if [[ -r "$console" ]]; then
    cp -p "$console" "$DEST/console.txt"
    keep "qemu console" "$DEST/console.txt"
  else
    drop "qemu console" "no readable $console"
  fi
  if ! rig_run_identity "$DEST/identity.txt" --meta 2>/dev/null; then
    drop "run identity" "rig_run_identity failed"
  elif [[ -s "$DEST/identity.txt" ]]; then
    keep "run identity" "$DEST/identity.txt"
  fi

  if ! ssh_vm -t 15 true >/dev/null 2>&1; then
    drop "guest state" "vm $RHIZO_VM does not answer ssh on port $SSH_PORT"
    drop "logcat" "vm $RHIZO_VM does not answer ssh on port $SSH_PORT"
    drop "getprop" "vm $RHIZO_VM does not answer ssh on port $SSH_PORT"
  else
    ssh_vm -t 60 '
      echo "== uname -r"; uname -r
      echo "== df -h /"; df -h /
      echo "== binder"; [ -e /sys/module/binder/parameters/devices ] && echo "devices=$(cat /sys/module/binder/parameters/devices)" || echo "(no built-in binder)"
      [ -c /dev/ashmem ] && echo ashmem=char || echo "ashmem=absent"; [ -e /proc/config.gz ] && echo config.gz=present || echo "config.gz=absent"
      echo "== selinux"; cat /sys/fs/selinux/enforce 2>/dev/null | sed "s/^/enforce=/"
      echo "== androidd.service"; systemctl is-active androidd.service 2>/dev/null
      echo "== android cgroup tree"; find /sys/fs/cgroup -maxdepth 5 -name "uid_*" -o -maxdepth 3 -name "android" 2>/dev/null | head -40
      echo "== /run/rhizo"; ls -la /run/rhizo 2>/dev/null | head -20
      echo "== gsi trees"; ls -d /srv/rhizo/* 2>/dev/null
    ' > "$DEST/guest-state.txt" 2>/dev/null
    keep "guest state" "$DEST/guest-state.txt"

    ssh_vm -t 45 'tail -n 400 /var/log/rhizo/supervisor.log 2>/dev/null' > "$DEST/supervisor-tail.txt" 2>/dev/null
    if [[ -s "$DEST/supervisor-tail.txt" ]]; then
      keep "supervisor log (tail)" "$DEST/supervisor-tail.txt"
    else
      rm -f "$DEST/supervisor-tail.txt"
      drop "supervisor log (tail)" "/var/log/rhizo/supervisor.log is absent or empty on the guest"
    fi

    ssh_vm -t 60 'tail -n 20000 /var/log/rhizo/rhizo-avc.log 2>/dev/null' > "$DEST/avc-tail.txt" 2>/dev/null
    if [[ -s "$DEST/avc-tail.txt" ]]; then
      keep "AVC log (tail)" "$DEST/avc-tail.txt"
    else
      rm -f "$DEST/avc-tail.txt"
      drop "AVC log (tail)" "/var/log/rhizo/rhizo-avc.log is absent or empty on the guest"
    fi

    local init_pid
    init_pid=$(guest_init_pid 15)
    if [[ -z "$init_pid" ]]; then
      drop "logcat" "no init second_stage on the guest"
      drop "getprop" "no init second_stage on the guest"
    else
      note "$(printf '%-22s %s' "android init pid" "$init_pid")"
      logcat_vm "$init_pid" -d -v threadtime > "$DEST/logcat.txt" 2>/dev/null
      keep "logcat" "$DEST/logcat.txt"
      android_sh "$init_pid" getprop > "$DEST/getprop.txt" 2>/dev/null
      keep "getprop" "$DEST/getprop.txt"
      android_sh "$init_pid" "ls -laZ /data/misc/adb; echo '== adb_keys (key prefix, comment)'; cut -c1-24,700- /data/misc/adb/adb_keys; echo '== adb_allowed_connection_time'; settings get global adb_allowed_connection_time" \
        > "$DEST/adb-keys-dir.txt" 2>&1
      keep "adb key dir" "$DEST/adb-keys-dir.txt"
    fi
  fi

  collect_resync_journal
  collect_test_ev_logs
}

note "collected at $(date -u '+%Y-%m-%dT%H:%M:%SZ') for vm $RHIZO_VM${LABEL:+ ($LABEL)}"
note ""

if (( GUARD_ONLY )); then
  collect_guard_log
  note ""
  note "collected $GOT item(s), missed $LOST, $EARLIER marked earlier (predate this boot)"
  echo "collect-boot-evidence: guard-only: $GOT item(s) into $DEST, $LOST missed, $EARLIER earlier (see MANIFEST.txt)" >&2
  exit 0
fi

if (( ASSERT_ONLY )); then
  run_assert_only
  note ""
  note "collected $GOT item(s), missed $LOST, $EARLIER marked earlier (predate this boot)"
  echo "collect-boot-evidence: assert-only: $GOT item(s) into $DEST, $LOST missed, $EARLIER earlier (see MANIFEST.txt)" >&2
  exit 0
fi

if [[ "$LABEL" != test-preflight-failed ]]; then
  note "$(printf '%-22s %s' "preflight output" "not applicable to label '$LABEL'")"
elif [[ -n "${RHIZO_PREFLIGHT_EVIDENCE:-}" ]]; then
  if [[ -s "$RHIZO_PREFLIGHT_EVIDENCE" ]]; then
    cp -p "$RHIZO_PREFLIGHT_EVIDENCE" "$DEST/preflight.txt"
    keep "preflight output" "$DEST/preflight.txt"
  else
    drop "preflight output" "$RHIZO_PREFLIGHT_EVIDENCE is empty or unreadable"
  fi
else
  note "$(printf '%-22s %s' "preflight output" "RHIZO_PREFLIGHT_EVIDENCE not set by the caller")"
fi

if [[ -r "$console" ]]; then
  cp -p "$console" "$DEST/console.txt"
  keep "qemu console" "$DEST/console.txt"
else
  drop "qemu console" "no readable $console"
fi

if ! rig_run_identity "$DEST/identity.txt" --meta 2>/dev/null; then
  drop "run identity" "rig_run_identity failed"
elif [[ -s "$DEST/identity.txt" ]]; then
  keep "run identity" "$DEST/identity.txt"
fi

if ! ssh_vm -t 15 true >/dev/null 2>&1; then
  drop "guest-side files" "vm $RHIZO_VM does not answer ssh on port $SSH_PORT"
  note ""
  note "collected $GOT item(s), missed $LOST"
  echo "collect-boot-evidence: $GOT item(s) into $DEST, $LOST missed (see MANIFEST.txt)" >&2
  exit 0
fi

REF_BOOT_EPOCH=""
REF_KERNEL=""
read -r ref_now ref_uptime REF_KERNEL <<<"$(ssh_vm -t 15 'echo "$(date -u +%s) $(cut -d" " -f1 /proc/uptime) $(uname -r)"' 2>/dev/null)"
if [[ "$ref_now" =~ ^[0-9]+$ && "$ref_uptime" =~ ^[0-9]+ ]]; then
  REF_BOOT_EPOCH=$((ref_now - ${ref_uptime%.*}))
  note "$(printf '%-22s %s' "boot reference" "started $(date -u -d "@$REF_BOOT_EPOCH" '+%Y-%m-%dT%H:%M:%SZ') on kernel '$REF_KERNEL'")"
else
  note "$(printf '%-22s %s' "boot reference" "could not be established -- the before-this-boot checks below are skipped")"
fi

# mark a pulled item from before this boot as EARLIER
note_before_boot() {
  [[ -n "$REF_BOOT_EPOCH" ]] || return 0
  local name="$1" src="$2" mtime
  mtime=$(ssh_vm -t 15 "stat -c %Y '$src'" 2>/dev/null)
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 0
  if (( mtime < REF_BOOT_EPOCH )); then
    note "$(printf '%-22s %s' "$name" "EARLIER -- guest source last written $(date -u -d "@$mtime" '+%Y-%m-%dT%H:%M:%SZ'), before this boot started")"
    EARLIER=$((EARLIER + 1))
  fi
}

# copy a guest file and record the result
pull() {
  local name="$1" src="$2" out="$DEST/$3" lines="${4:-}"
  if [[ -n "$lines" ]]; then
    ssh_vm -t 60 "tail -n $lines '$src' 2>/dev/null" > "$out" 2>/dev/null
  else
    timeout 120 scp -q "${SSH_OPTS[@]}" -P "$SSH_PORT" "$SSH_TARGET:$src" "$out" 2>/dev/null
  fi
  if [[ -s "$out" ]]; then
    keep "$name" "$out"
    note_before_boot "$name" "$src"
  else
    rm -f "$out"
    if ssh_vm -t 15 "test -e '$src'" >/dev/null 2>&1; then
      drop "$name" "$src exists on the guest but came back empty"
    else
      drop "$name" "$src does not exist on the guest"
    fi
  fi
}

pull "launcher boot.log"  /root/boot.log          launcher-boot.txt
pull "host primer log"    /var/log/rhizo/rhizo-primer.log  primer.txt
pull "AVC log (tail)"     /var/log/rhizo/rhizo-avc.log     avc-tail.txt 4000
pull "supervisor log (tail)" /var/log/rhizo/supervisor.log supervisor-tail.txt 400
pull "secilc stderr"      /tmp/secilc.err         secilc-err.txt

ssh_vm -t 45 'dmesg' > "$DEST/guest-dmesg.txt" 2>/dev/null
keep "guest dmesg" "$DEST/guest-dmesg.txt"

ssh_vm -t 60 '
  echo "== uname -r"; uname -r
  echo "== df -h /"; df -h /
  echo "== binder"; [ -e /sys/module/binder/parameters/devices ] && echo "devices=$(cat /sys/module/binder/parameters/devices)" || echo "(no built-in binder)"
  [ -c /dev/ashmem ] && echo ashmem=char || echo "ashmem=absent"; [ -e /proc/config.gz ] && echo config.gz=present || echo "config.gz=absent"
  echo "== selinux"; cat /sys/fs/selinux/enforce 2>/dev/null | sed "s/^/enforce=/"
  echo "== androidd.service"; systemctl is-active androidd.service 2>/dev/null
  echo "== android cgroup tree"; find /sys/fs/cgroup -maxdepth 5 -name "uid_*" -o -maxdepth 3 -name "android" 2>/dev/null | head -40
  echo "== /run/rhizo"; ls -la /run/rhizo 2>/dev/null | head -20
  echo "== gsi trees"; ls -d /srv/rhizo/* 2>/dev/null
' > "$DEST/guest-state.txt" 2>/dev/null
keep "guest state" "$DEST/guest-state.txt"

ssh_vm -t 45 'journalctl -u androidd.service -b --no-pager 2>/dev/null | tail -400' \
  > "$DEST/androidd-journal.txt" 2>/dev/null
if [[ -s "$DEST/androidd-journal.txt" ]]; then
  keep "androidd journal" "$DEST/androidd-journal.txt"
else
  rm -f "$DEST/androidd-journal.txt"
  note "$(printf '%-22s %s' "androidd journal" "empty")"
fi

collect_resync_journal

init_pid=$(guest_init_pid 15)
if [[ -z "$init_pid" ]]; then
  drop "logcat" "no init second_stage on the guest"
  drop "getprop" "no init second_stage on the guest"
else
  note "$(printf '%-22s %s' "android init pid" "$init_pid")"
  logcat_vm "$init_pid" -d -v threadtime > "$DEST/logcat.txt" 2>/dev/null
  keep "logcat" "$DEST/logcat.txt"
  android_sh "$init_pid" getprop > "$DEST/getprop.txt" 2>/dev/null
  keep "getprop" "$DEST/getprop.txt"
fi

tomb_raw=$(ssh_vm -t 45 'bash -s' -- < "$REPO/test/vm/boot/collect-tombstones.sh" 2>/dev/null)
if [[ -z "$tomb_raw" ]]; then
  drop "tombstones" "collect-tombstones.sh produced no output over ssh"
else
  cur=""
  while IFS= read -r line; do
    case "$line" in
      "STATUS "*)
        note "$(printf '%-22s %s' "tombstones" "${line#STATUS }")"
        [[ "$line" == "STATUS unreadable"* ]] && LOST=$((LOST + 1))
        ;;
      "SUMMARY "*)
        note "$(printf '%-22s %s' "tombstone" "${line#SUMMARY }")"
        [[ "$line" == *" UNREADABLE "* ]] && LOST=$((LOST + 1))
        [[ "$line" == *" EARLIER "* ]] && EARLIER=$((EARLIER + 1))
        ;;
      "===TOMBSTONE "*"===")
        name="${line#===TOMBSTONE }"; name="${name%===}"
        cur="$DEST/tombstone-$name.txt"
        : > "$cur"
        ;;
      "===END "*"===")
        [[ -n "$cur" ]] && keep "tombstone file" "$cur"
        cur=""
        ;;
      *)
        [[ -n "$cur" ]] && echo "$line" >> "$cur"
        ;;
    esac
  done <<<"$tomb_raw"
fi

collect_guard_log

note ""
note "collected $GOT item(s), missed $LOST, $EARLIER marked earlier (predate this boot)"
if [[ -z "${TEST_NAME:-}" && -z "${RHIZO_BOOT_NO_ROW:-}" ]]; then
  rig_boot_outcome "${RHIZO_VM:-0}" FAILED ${LABEL:+"cause=$LABEL"} >/dev/null 2>&1 \
    || note "boot record not updated"
elif [[ -n "${RHIZO_BOOT_NO_ROW:-}" ]]; then
  note "boot log left alone -- this attempt was refused before it had its own row"
fi
echo "collect-boot-evidence: $GOT item(s) into $DEST, $LOST missed, $EARLIER earlier (see MANIFEST.txt)" >&2
exit 0
