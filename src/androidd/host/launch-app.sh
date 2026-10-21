#!/bin/sh
# start the package's activity on a new composer display
set -eu

SANDBOX_ID="${RHIZO_SANDBOX_ID:-0}"
RUN_DIR=/run/rhizo-launch
INIT_PID_FILE=/root/.rhizo_init_pid
RUN_ROOT=/run/rhizo
if [ "$SANDBOX_ID" != 0 ]; then
  RUN_DIR="$RUN_DIR-$SANDBOX_ID"
  INIT_PID_FILE="$INIT_PID_FILE-$SANDBOX_ID"
  RUN_ROOT="$RUN_ROOT-$SANDBOX_ID"
fi
# shellcheck disable=SC2174
mkdir -p -m 0755 "$RUN_DIR"

DESKTOP_USER=$(cat /etc/rhizo/desktop-user 2>/dev/null || true)
[ -n "$DESKTOP_USER" ] || DESKTOP_USER=ubuntu

LAUNCH_LOG="$RUN_DIR/rhizo-launch.log"
echo "$(date +%s.%N) event=invocation pid=$$ pkg=${1:-?} activity=${2:-?}" >> "$LAUNCH_LOG"

PKG="${1:?package required}"
ACT="${2:?activity required}"
VIEW_URI="${3:-}"
VIEW_MIME="${4:-}"

# print the pid of instance 0's android init
stack_init_pid() {
  _sip_pid=""
  for _sip_d in "${RHIZO_PROC_ROOT:-/proc}"/[0-9]*; do
    case "$(tr '\0' ' ' 2>/dev/null < "$_sip_d/cmdline")" in *"init second_stage"*) ;; *) continue ;; esac
    case "$(sed -n 's|^0::||p' "$_sip_d/cgroup" 2>/dev/null)" in
      /rhizo/*|/system.slice/androidd.service/android/*)
        [ -z "$_sip_pid" ] || [ "${_sip_d##*/}" -lt "$_sip_pid" ] && _sip_pid=${_sip_d##*/} ;;
    esac
  done
  [ -z "$_sip_pid" ] || echo "$_sip_pid"
}
INIT_CACHE="${TMPDIR:-/tmp}/rhizo-launch-init-$SANDBOX_ID.cache"
INIT=$(cat "$INIT_CACHE" 2>/dev/null || true)
case "$(tr '\0' ' ' 2>/dev/null < "/proc/$INIT/cmdline")" in
  *second_stage*) : ;;
  *) INIT="" ;;
esac
if [ -z "$INIT" ]; then
  INIT=$(cat "$INIT_PID_FILE" 2>/dev/null || true)
  case "$(tr '\0' ' ' 2>/dev/null < "/proc/$INIT/cmdline")" in
    *second_stage*) : ;;
    *) INIT="" ;;
  esac
  [ -n "$INIT" ] || [ -e "$INIT_PID_FILE" ] || [ "$SANDBOX_ID" != 0 ] || INIT=$(stack_init_pid)
  [ -n "$INIT" ] && printf '%s' "$INIT" > "$INIT_CACHE" 2>/dev/null
fi
[ -n "$INIT" ] || { echo "rhizo-launch: no init second_stage running" >&2; exit 1; }

echo "$(date +%s.%N) event=stage pid=$$ name=unfreeze" >> "$LAUNCH_LOG"
_here=$(dirname "$(readlink -f "$0")")
for _unfreeze_lib in "$_here/rhizo-cgroup-unfreeze.sh" /root/rhizo-cgroup-unfreeze.sh /root/share/rhizo-cgroup-unfreeze.sh; do
  # shellcheck source=/dev/null
  [ -r "$_unfreeze_lib" ] && { . "$_unfreeze_lib"; break; }
done
if command -v rhizo_unfreeze_gate >/dev/null 2>&1; then
  rhizo_unfreeze_gate "$INIT" || {
    echo "rhizo-launch: the stack is frozen and would not unfreeze" >&2; exit 1; }
fi

LOG="$RUN_DIR/rhizo-launch.log"
LOCK="$RUN_DIR/rhizo-launch.lock"
DISP_W=960
DISP_H=1080

PROBE_SOCK="$RUN_ROOT/data/local/tmp/rhizo-probe.sock"
for _pc in /root/share/rhizo-probe-client "$_here/../probe-client.py" "$_here/probe-client.py"; do
  [ -r "$_pc" ] && { PROBE_CLIENT="$_pc"; break; }
done
: "${PROBE_CLIENT:=/root/share/rhizo-probe-client}"

# print the recorded or configured SELinux mode
selinux_mode() {
  _mf="${RHIZO_SELINUX_MODE_FILE:-/run/rhizo-selinux-mode}"
  _m=""
  if [ -e "$_mf" ]; then
    _m=$(cat "$_mf") || return 1
  fi
  if [ -z "$_m" ]; then
    _m=$("${RHIZO_SELINUX_MODE_HELPER:-/usr/lib/rhizo/rhizo-selinux-mode}" \
      --env-file "${RHIZO_ANDROIDD_ENV:-/etc/rhizo/androidd.env}" --configured) || return 1
  fi
  case "$_m" in
    host|namespace) printf '%s\n' "$_m" ;;
    *) echo "rhizo-launch: the SELinux mode reads '$_m', not host or namespace" >&2; return 1 ;;
  esac
}
# run a command in android's shell
ash_inline() {
  _timeout="${2:-30}"
  _mode=$(selinux_mode) || { echo "rhizo-launch: cannot read the SELinux mode" >&2; return 1; }
  dead_marker="${TMPDIR:-/tmp}/rhizo-ash-dead.${INIT}"
  if [ "$_mode" != namespace ] && [ ! -e "$dead_marker" ]; then
    out=$(nsenter -a -t "$INIT" -- /system/bin/toybox runcon u:r:shell:s0 \
      /system/bin/sh -c "export PATH=/system/bin:/system/xbin:/vendor/bin; $*; echo RHIZO_ASH_DONE=\$?" 2>&1) || true
    case "$out" in
      *RHIZO_ASH_DONE=*)
        out="${out%RHIZO_ASH_DONE=*}"; out="${out%
}"
        printf '%s' "$out"
        return 0
        ;;
    esac
    : > "$dead_marker" 2>/dev/null
  fi
  out=$("$PROBE_CLIENT" "$PROBE_SOCK" "$_timeout" \
    "export PATH=/system/bin:/system/xbin:/vendor/bin; $*; echo RHIZO_ASH_DONE=\$?") || true
  case "$out" in
    *RHIZO_ASH_DONE=*) out="${out%RHIZO_ASH_DONE=*}"; out="${out%
}" ;;
    *) out="" ;;
  esac
  printf '%s' "$out"
}


echo "$(date +%s.%N) event=stage pid=$$ name=audio-assign" >> "$LAUNCH_LOG"

exec 9>"$LOCK"
flock 9

own_logid=""
own_cid=""
if [ -z "${RHIZO_REUSE_DISPLAY:-}" ]; then
  own=$(awk -v p=" pkg=$PKG " -v i=" init=$INIT " '
    index(" " $0 " ", " event=am_start_return ") && index(" " $0 " ", p) && index(" " $0 " ", i) {
      d = ""; c = ""
      for (n = 1; n <= NF; n++) {
        if ($n ~ /^display=[0-9]+$/) d = substr($n, 9)
        if ($n ~ /^cdisplay=[0-9]+$/) c = substr($n, 10)
      }
      if (d != "" && c != "") last = d " " c
    }
    END { print last }' "$LAUNCH_LOG" 2>/dev/null || true)
  if [ -n "$own" ]; then
    own_logid=${own% *}
    own_cid=${own#* }
  fi
fi

pool_logid=""
pool_display_id=""
pool_miss=""
pool_peeked=""
if [ -z "${RHIZO_REUSE_DISPLAY:-}" ] && [ -n "$own_logid" ]; then
  pool_line=$(cat /run/rhizo-display-pool/ready 2>/dev/null || true)
  pool_logid=$(printf '%s\n' "$pool_line" | sed -n 's/.*logid=\([0-9]*\).*/\1/p')
  pool_display_id=$(printf '%s\n' "$pool_line" | sed -n 's/.* id=\([0-9]*\).*/\1/p')
  if [ -n "$pool_display_id" ]; then
    pool_peeked=1
  else
    pool_logid=""
    pool_miss=1
  fi
elif [ -z "${RHIZO_REUSE_DISPLAY:-}" ]; then
  pop_spare() {
    mv /run/rhizo-display-pool/ready /run/rhizo-display-pool/consumed 2>/dev/null || return 1
    pool_line=$(cat /run/rhizo-display-pool/consumed 2>/dev/null || true)
    pool_logid=$(printf '%s\n' "$pool_line" | sed -n 's/.*logid=\([0-9]*\).*/\1/p')
    pool_display_id=$(printf '%s\n' "$pool_line" | sed -n 's/.* id=\([0-9]*\).*/\1/p')
    [ -n "$pool_display_id" ]
  }
  if ! pop_spare; then
    i=0
    while [ "$i" -lt "${POOL_REFILL_WAIT_ITERS:-0}" ]; do
      sleep 0.1
      if pop_spare; then break; fi
      i=$((i + 1))
    done
    [ -n "$pool_display_id" ] || pool_miss=1
  fi
fi

MAP=/run/rhizo-audio-map
BUSES=${RHIZO_AUDIO_BUSES:-4}
bus=""
touch "$MAP" 2>/dev/null || true
existing=$(awk -v p="$PKG" '$2==p {print $1; exit}' "$MAP" 2>/dev/null || true)
if [ -n "$existing" ]; then
  bus="$existing"
else
  i=0
  while [ "$i" -lt "$BUSES" ]; do
    if ! awk -v b="bus$i" '$1==b {found=1} END {exit !found}' "$MAP" 2>/dev/null; then
      bus="bus$i"
      break
    fi
    i=$((i + 1))
  done
fi

if [ -n "$bus" ] && [ "$BUSES" -gt 0 ]; then
  if [ -z "$existing" ]; then
    tmp=$(mktemp "$MAP.XXXXXX")
    awk -v b="$bus" -v p="$PKG" '$1!=b && $2!=p {print}' "$MAP" 2>/dev/null > "$tmp" || true
    echo "$bus $PKG" >> "$tmp"
    chown "$DESKTOP_USER:rhizo" "$tmp" && chmod 0644 "$tmp" \
      || echo "$(date +%s.%N) audio pkg=$PKG: could not give the map file to $DESKTOP_USER:rhizo before the swap" >> "$LOG"
    mv "$tmp" "$MAP"
    map_b64=$(base64 -w0 < "$MAP")
  else
    map_b64=""
  fi
else
  bus=""
  map_b64=""
fi

GUEST_CALL_TIMEOUT_S=80
ON_TOP_CHANNEL_MARGIN_S=10
ident_appid="rhizo-$PKG"
ident_title="$PKG"
for _desktop_entry in \
  "${XDG_DATA_HOME:-$HOME/.local/share}/applications/rhizo-$PKG.desktop" \
  "/usr/share/applications/rhizo-$PKG.desktop"; do
  [ -r "$_desktop_entry" ] || continue
  _name=$(sed -n 's/^Name=//p' "$_desktop_entry" | head -1)
  _wmclass=$(sed -n 's/^StartupWMClass=//p' "$_desktop_entry" | head -1)
  [ -n "$_wmclass" ] && ident_appid="$_wmclass"
  [ -n "$_name" ] && { ident_title="$_name"; break; }
done
ident_appid_b64=$(printf '%s' "$ident_appid" | base64 | tr -d '\n')
ident_title_b64=$(printf '%s' "$ident_title" | base64 | tr -d '\n')

echo "$(date +%s.%N) event=stage pid=$$ name=dispatch" >> "$LAUNCH_LOG"
view_uri_b64=$(printf '%s' "$VIEW_URI" | base64 | tr -d '\n')
view_mime_b64=$(printf '%s' "$VIEW_MIME" | base64 | tr -d '\n')
on_top_deadline=$(( $(date +%s) + GUEST_CALL_TIMEOUT_S - ON_TOP_CHANNEL_MARGIN_S ))
# print the desktop's xdg-activation token argument
activation_token_arg() {
  [ -n "${XDG_ACTIVATION_TOKEN:-}" ] || return 0
  case "$XDG_ACTIVATION_TOKEN" in
    *[!A-Za-z0-9_.:/+=@-]*)
      echo "$(date +%s.%N) activation pkg=$PKG: XDG_ACTIVATION_TOKEN is not one word of [A-Za-z0-9_.:/+=@-], not sent" >> "$LOG"
      return 0 ;;
  esac
  if [ "${#XDG_ACTIVATION_TOKEN}" -gt 255 ]; then
    echo "$(date +%s.%N) activation pkg=$PKG: XDG_ACTIVATION_TOKEN is ${#XDG_ACTIVATION_TOKEN} characters, limit is 255, not sent" >> "$LOG"
    return 0
  fi
  printf '%s' "$XDG_ACTIVATION_TOKEN"
}
activation_arg=$(activation_token_arg)
out=$(ash_inline "sh /system_ext/bin/rhizo-launch-app.sh $PKG $ACT $DISP_W $DISP_H '$bus' '$map_b64' '${RHIZO_REUSE_DISPLAY:-$own_logid}' '$pool_logid' '$pool_display_id' '$ident_appid_b64' '$ident_title_b64' '$view_uri_b64' '$view_mime_b64' '$on_top_deadline' '$activation_arg' '$own_cid'" "$GUEST_CALL_TIMEOUT_S")

if [ -n "$pool_miss" ] && [ -d /run/rhizo-display-pool ] \
   && printf '%s\n' "$out" | grep -q '^stage=display-add '; then
  printf 'id=none\n' > /run/rhizo-display-pool/consumed
fi
if [ -n "$pool_peeked" ] && printf '%s\n' "$out" | grep -q '^stage=pool-claim .*result=claimed'; then
  mv /run/rhizo-display-pool/ready /run/rhizo-display-pool/consumed 2>/dev/null || true
fi

fail_line=$(printf '%s\n' "$out" | grep '^stage=fail ' | tail -1)
if [ -n "$fail_line" ]; then
  reason=$(printf '%s\n' "$fail_line" | sed -n 's/.*reason=\([^ ]*\).*/\1/p')
  echo "rhizo-launch: $(date +%s) FAIL pkg=$PKG activity=$ACT: ${reason:-guest script failed}" >> "$LOG"
  case "$reason" in
    not-on-top) exit 3 ;;
    launch-error) exit 4 ;;
    process-died) exit 5 ;;
  esac
  exit 1
fi
done_line=$(printf '%s\n' "$out" | grep '^stage=done ')
if [ -z "$done_line" ]; then
  echo "rhizo-launch: $(date +%s) FAIL pkg=$PKG activity=$ACT: guest script produced no completion trailer (channel timeout, crash, or truncated output)" >> "$LOG"
  exit 1
fi
logid=$(printf '%s\n' "$done_line" | sed -n 's/.*logid=\([0-9]*\).*/\1/p')
cdisplay=$(printf '%s\n' "$done_line" | sed -n 's/.*cid=\([0-9]*\).*/\1/p')
committed=$(printf '%s\n' "$done_line" | sed -n 's/.*committed=\([A-Za-z]*\).*/\1/p')
if [ -z "$logid" ]; then
  echo "rhizo-launch: $(date +%s) FAIL pkg=$PKG activity=$ACT: done trailer carried no logid" >> "$LOG"
  exit 1
fi

printf '%s\n' "$out" | while IFS= read -r _line; do
  case "$_line" in
    "stage=done "*)
      ;;
    "stage=reuse-display "*)
      _t=$(printf '%s\n' "$_line" | sed -n 's/.* t=\([0-9][0-9]*\.[0-9]*\).*/\1/p')
      echo "$_t event=stage pid=$$ name=reuse-display" >> "$LAUNCH_LOG"
      _rlogid=$(printf '%s\n' "$_line" | sed -n 's/.*logid=\([0-9]*\).*/\1/p')
      echo "$(date +%s.%N) reuse-display pkg=$PKG display=$_rlogid" >> "$LOG"
      ;;
    "stage=audio-confirm "*)
      _t=$(printf '%s\n' "$_line" | sed -n 's/.* t=\([0-9][0-9]*\.[0-9]*\).*/\1/p')
      echo "$_t event=stage pid=$$ name=audio-confirm" >> "$LAUNCH_LOG"
      case "$_line" in
        *" bus="*)
          _abus=$(printf '%s\n' "$_line" | sed -n 's/.* bus=\([^ ]*\).*/\1/p')
          _astate=$(printf '%s\n' "$_line" | sed -n 's/.* state=//p')
          if [ "$_astate" = write-failed ]; then
            echo "$(date +%s.%N) audio pkg=$PKG: probe-channel map write FAILED" >> "$LOG"
          else
            echo "$(date +%s.%N) audio pkg=$PKG bus=$_abus -> $_astate" >> "$LOG"
          fi
          ;;
        *)
          echo "$(date +%s.%N) audio pkg=$PKG: no bus assigned, sharing primary output" >> "$LOG"
          ;;
      esac
      ;;
    "stage="*)
      _name=$(printf '%s\n' "$_line" | sed -n 's/^stage=\([^ ]*\).*/\1/p')
      _t=$(printf '%s\n' "$_line" | sed -n 's/.* t=\([0-9][0-9]*\.[0-9]*\).*/\1/p')
      [ -n "$_t" ] || _t=$(date +%s.%N)
      echo "$_t event=stage pid=$$ name=$_name" >> "$LAUNCH_LOG"
      ;;
  esac
done

echo "$(date +%s.%N) event=am_start_return pid=$$ pkg=$PKG activity=$ACT display=$logid cdisplay=${cdisplay:-$logid} bus=${bus:-none} init=$INIT" >> "$LAUNCH_LOG"
echo "$(date +%s.%N) pkg=$PKG activity=$ACT display=$logid cdisplay=${cdisplay:-$logid} bus=${bus:-none} committed=${committed:-none}" >> "$LOG"
