#!/bin/bash
# fetch, verify and unpack an Aurora Store or LiteGapps payload
set -uo pipefail

PROG=rhizo-fetch-app
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STATE="${RHIZO_STATE_DIR:-/var/lib/rhizo}"
LOG_FILE="${RHIZO_LOG_DIR:-/var/log/rhizo}/gapps.log"
PINS="${RHIZO_APP_PINS:-$HERE/app-pins.tsv}"
TAKE_DIR="${RHIZO_APP_TAKE_DIR:-$HERE}"
NAME="-"
RELEASE=""
FROM_FILE=""

# log a line to stderr and a writable gapps.log
log() {
  echo "[$PROG] $*" >&2
  if [[ -w "$LOG_FILE" ]] || [[ ! -e "$LOG_FILE" && -w "${LOG_FILE%/*}" ]]; then
    printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "$PROG" "$*" >> "$LOG_FILE" 2>/dev/null
  fi
  return 0
}
# print a refusal reason and exit 3
refuse() { local t="$1"; shift; log "REFUSED: $*"; echo "RHIZO_APP_REFUSED name=$NAME reason=$t"; exit 3; }
# print a failure reason and exit 1
failstop() { local t="$1"; shift; log "FAILED: $*"; echo "RHIZO_APP_FAILED name=$NAME reason=$t"; exit 1; }
# print the usage text
usage() {
  cat <<'EOF'
Usage: fetch-app.sh aurora [--from-file PATH]
       fetch-app.sh litegapps --release a16|a17 [--from-file PATH]
EOF
}
# run store_payload.py isolated from the environment
store() { python3 -I "$HERE/store_payload.py" "$@"; }
# append a captured stderr file to the log
replay() { local l; while IFS= read -r l; do log "$l"; done < "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release|--from-file)
      [[ $# -ge 2 ]] || refuse usage "$1 takes a value"
      if [[ "$1" == --release ]]; then RELEASE="$2"; else FROM_FILE="$2"; fi
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) refuse usage "unknown argument '$1'" ;;
    *) [[ "$NAME" == - ]] || refuse usage "one app at a time, not '$NAME' and '$1'"; NAME="$1"; shift ;;
  esac
done
case "$NAME" in
  aurora)
    [[ -z "$RELEASE" || "$RELEASE" == any ]] || log "Aurora Store is one APK for every release; ignoring --release $RELEASE"
    RELEASE=any ;;
  litegapps)
    [[ "$RELEASE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || refuse usage "litegapps takes --release a16|a17" ;;
  -) refuse usage "name an app: aurora or litegapps" ;;
  *) refuse unknown-app "no app '$NAME' -- known: aurora litegapps" ;;
esac

# print the installed or source-tree path of capability-allowed.sh
capability_allowed() {
  local c
  if [[ -n "${RHIZO_CAPABILITY_ALLOWED:-}" ]]; then
    [[ -f "$RHIZO_CAPABILITY_ALLOWED" ]] && printf '%s' "$RHIZO_CAPABILITY_ALLOWED"
    return
  fi
  for c in "$HERE/../../tools/capability-allowed.sh" "$HERE/../../androidd/sandbox/capability-allowed.sh"; do
    [[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}
if [[ "$NAME" == aurora ]]; then
  cap=$(capability_allowed) || failstop policy-check "no capability-allowed.sh beside $0"
  out=$(sh "$cap" apps.aurora 2>&1); rc=$?
  [[ -z "$out" ]] || log "$out"
  case "$rc" in
    0) log "policy apps.aurora is on" ;;
    1) log "policy apps.aurora is off in /etc/rhizo/policy.conf: not fetching Aurora Store"
       echo "RHIZO_APP_SKIPPED name=aurora reason=policy-off"; exit 0 ;;
    *) failstop policy-check "$cap apps.aurora exited $rc" ;;
  esac
fi

# print the pin row fields for a name and release
pin_row() {
  local f="$1" name="$2" rel="$3" n r url sha size signer desc
  [[ -f "$f" ]] || return 3
  while IFS=$'\t' read -r n r url sha size signer desc || [[ -n "$n" ]]; do
    [[ -z "$n" || "$n" == \#* ]] && continue
    [[ "$n" == "$name" && "$r" == "$rel" ]] || continue
    [[ "$url" == https://* && "$sha" =~ ^[0-9a-f]{64}$ && "$size" =~ ^[1-9][0-9]*$ \
       && ( "$signer" == - || "$signer" =~ ^[0-9a-f]{64}$ ) && -n "$desc" ]] || return 2
    printf '%s\t%s\t%s\t%s\t%s\n' "$url" "$sha" "$size" "$signer" "$desc"
    return 0
  done < "$f"
  return 1
}
row=$(pin_row "$PINS" "$NAME" "$RELEASE"); rc=$?
case "$rc" in
  0) IFS=$'\t' read -r URL WANT SIZE SIGNER DESC <<<"$row" ;;
  1) refuse no-pin "no $NAME pin for release '$RELEASE' in $PINS" ;;
  2) failstop bad-pin "the $NAME $RELEASE row in $PINS is malformed" ;;
  *) failstop no-pins "cannot read $PINS" ;;
esac
[[ "$NAME" != aurora || "$SIGNER" != - ]] || failstop bad-pin "the aurora row in $PINS pins no signer"
TAKE="$TAKE_DIR/litegapps-$RELEASE.tsv"
[[ "$NAME" != litegapps || -f "$TAKE" ]] || failstop no-take-list "no $TAKE for the $RELEASE pin"

[[ $EUID -eq 0 || -n "${RHIZO_STATE_DIR:-}" ]] || refuse not-root "must run as root (it writes $STATE)"
. "$(dirname "${BASH_SOURCE[0]}")/../lib/host-flavor.sh" \
  || refuse library-unreadable "cannot read host-flavor.sh beside $0"
why=$(host_state_subvolume_check) || refuse root-snapshot-boot "$why"
command -v python3 >/dev/null 2>&1 || refuse no-python3 "python3 is required to check and unpack the payload"
command -v curl >/dev/null 2>&1 || [[ -n "$FROM_FILE" ]] || refuse no-curl "curl is required to download $DESC"
if [[ -n "$FROM_FILE" ]]; then
  [[ -f "$FROM_FILE" ]] || refuse no-such-file "--from-file '$FROM_FILE' does not exist"
  have=$(sha256sum "$FROM_FILE" | cut -d' ' -f1)
  [[ "$have" == "$WANT" ]] || failstop sha256-mismatch "$FROM_FILE is $have, the pin is $WANT"
fi

if [[ "$NAME" == aurora ]]; then DEST_ROOT="$STATE/aurora"; else DEST_ROOT="$STATE/gapps/$RELEASE"; fi
SHA12="${WANT:0:12}"
{ mkdir -p "$DEST_ROOT" && chmod 0755 "$DEST_ROOT"; } || failstop mkdir-failed "cannot create $DEST_ROOT"
exec 9>"$DEST_ROOT/.lock" || failstop lock-failed "cannot open $DEST_ROOT/.lock"
flock -n 9 || refuse busy "another fetch of $NAME $RELEASE holds $DEST_ROOT/.lock"

# print a verifying payload directory already unpacked from this pin
existing_payload() {
  local d
  for d in "$DEST_ROOT"/*"$SHA12"; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    [[ "${d##*/}" == "$SHA12" || "${d##*/}" =~ ^[0-9]+-$SHA12$ ]] || continue
    store verify "$d" >/dev/null 2>&1 && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# point current at a payload directory and remove the rest
make_current() {
  local key="$1" d
  rm -f "$DEST_ROOT/.current.new"
  { ln -s "$key" "$DEST_ROOT/.current.new" && mv -T "$DEST_ROOT/.current.new" "$DEST_ROOT/current"; } \
    || failstop current-failed "cannot point $DEST_ROOT/current at $key"
  for d in "$DEST_ROOT"/* "$DEST_ROOT"/.[!.]*; do
    [[ -d "$d" && ! -L "$d" && "${d##*/}" != "$key" ]] || continue
    rm -rf --one-file-system -- "$d" && log "removed the older payload $d"
  done
  sync -f "$DEST_ROOT" 2>/dev/null
}

if d=$(existing_payload); then
  make_current "${d##*/}"
  log "$DESC is already unpacked and verified at $d"
  echo "RHIZO_APP_FETCHED name=$NAME release=$RELEASE dir=$d"
  exit 0
fi

SCRATCH_ROOT="$STATE/fetch-scratch"
# remove scratch directories an earlier run left
sweep_stale_scratch() {
  local d
  [[ -d "$SCRATCH_ROOT" ]] || return 0
  while IFS= read -r -d '' d; do
    rm -rf --one-file-system -- "$d" || log "could not remove $d"
  done < <(find "$SCRATCH_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'app.*' -user "$(id -u)" -mmin +1440 -print0)
}
sweep_stale_scratch
# shellcheck disable=SC2174
mkdir -p -m 0700 "$SCRATCH_ROOT" || failstop mktemp-failed "cannot create $SCRATCH_ROOT"
TMP=$(mktemp -d "$SCRATCH_ROOT/app.XXXXXX") || failstop mktemp-failed "cannot create a scratch directory below $SCRATCH_ROOT"
# remove the scratch directory and its download
cleanup() { rm -rf --one-file-system -- "$TMP"; rmdir -- "$SCRATCH_ROOT" 2>/dev/null; }
trap cleanup EXIT

avail_kb=$(df -Pk "$STATE" 2>/dev/null | awk 'NR == 2 {print $4}')
need_kb=$(( SIZE * 4 / 1024 ))
[[ ! "$avail_kb" =~ ^[0-9]+$ ]] || (( avail_kb >= need_kb )) \
  || failstop no-space "$STATE has $((avail_kb / 1024)) MiB free; unpacking $DESC needs $((need_kb / 1024)) MiB"

# download an https url, capped at the pinned size
download() {
  local url="$1" out="$2"
  curl -fsS -L --proto =https --proto-redir =https --retry 3 --retry-delay 5 --connect-timeout 30 \
       --max-filesize "$SIZE" -o "$out.part" "$url" || { rm -f "$out.part"; return 1; }
  mv "$out.part" "$out"
}

if [[ -n "$FROM_FILE" ]]; then
  FILE="$FROM_FILE"
  log "using $FILE (its sha256 matched the pin)"
else
  urls=("$URL")
  [[ "$URL" == https://f-droid.org/repo/* ]] && urls+=("https://f-droid.org/archive/${URL#https://f-droid.org/repo/}")
  FILE="$TMP/download"
  for u in "${urls[@]}"; do
    log "downloading $DESC from $u"
    download "$u" "$FILE" && break
    log "could not fetch $u"
  done
  [[ -f "$FILE" ]] || failstop download-failed "could not fetch $DESC from ${urls[*]}"
  have=$(sha256sum "$FILE" | cut -d' ' -f1)
  [[ "$have" == "$WANT" ]] || failstop sha256-mismatch "the download is $have, the pin is $WANT"
fi
log "sha256 verified against the pin: $WANT"

# print the reason= token of store_payload.py's last line
reason_of() { local r; r=$(sed -n 's/^RHIZO_PAYLOAD_[A-Z]* reason=\([a-z0-9-]*\)$/\1/p' <<<"$1" | tail -1); printf '%s' "${r:-$2}"; }

if [[ "$NAME" == aurora ]]; then
  info=$(store apk-info "$FILE" 2>"$TMP/store.log"); rc=$?
  replay "$TMP/store.log"
  (( rc == 0 )) || refuse "$(reason_of "$info" bad-apk)" "cannot read the Aurora Store APK"
  pkg="" vc="" signers=""
  for kv in $info; do
    case "$kv" in
      package=*) pkg="${kv#*=}" ;;
      version_code=*) vc="${kv#*=}" ;;
      signer_sha256=*) signers="${kv#*=}" ;;
    esac
  done
  [[ "$signers" == "$SIGNER" ]] \
    || refuse signer-mismatch "the APK is signed by '${signers:-nothing}', the pin is $SIGNER"
  [[ "$vc" =~ ^[0-9]+$ && "${URL##*/}" == "${pkg}_${vc}.apk" ]] \
    || refuse apk-mismatch "the APK is ${pkg:-no package} version ${vc:-none}, the pin names ${URL##*/}"
  log "the APK is $pkg version $vc, signed by the pinned key $SIGNER"
  KEY="$vc-$SHA12"
  out=$(store extract --file "$FILE" --dest app/AuroraStore/AuroraStore.apk --sha256 "$WANT" --out "$TMP/payload" \
          2>"$TMP/store.log"); rc=$?
else
  KEY="$SHA12"
  out=$(store extract --zip "$FILE" --take "$TAKE" \
          --add "$HERE/privapp-gapps-rhizo.xml=etc/permissions/gapps-rhizo.xml" --out "$TMP/payload" \
          2>"$TMP/store.log"); rc=$?
fi
replay "$TMP/store.log"
case "$rc" in
  0) log "unpacked: ${out##*RHIZO_PAYLOAD_OK }" ;;
  3) refuse "$(reason_of "$out" unsafe-archive)" "store_payload.py refused $DESC" ;;
  *) failstop "$(reason_of "$out" extract-failed)" "store_payload.py could not unpack $DESC" ;;
esac
[[ -n "$FROM_FILE" ]] || rm -f "$FILE"
store verify "$TMP/payload" >"$TMP/verify.log" 2>&1 || { replay "$TMP/verify.log"; failstop verify-failed "the unpacked payload does not verify"; }

[[ ! -e "$DEST_ROOT/$KEY" ]] || mv -T "$DEST_ROOT/$KEY" "$TMP/stale" \
  || failstop rename-failed "cannot move the stale $DEST_ROOT/$KEY aside"
mv -T "$TMP/payload" "$DEST_ROOT/$KEY" || failstop rename-failed "cannot move the payload into $DEST_ROOT/$KEY"
sync -f "$DEST_ROOT/$KEY" 2>/dev/null
make_current "$KEY"
log "unpacked $DESC at $DEST_ROOT/$KEY"
echo "RHIZO_APP_FETCHED name=$NAME release=$RELEASE dir=$DEST_ROOT/$KEY"
