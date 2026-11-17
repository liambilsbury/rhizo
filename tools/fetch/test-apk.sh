#!/bin/bash
# var/share/rhizo-test-fixture.apk var/share/rhizo-test-fixture.json
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit
SHARE="$(pwd)/var/share"
mkdir -p "$SHARE"

APK_OUT="$SHARE/rhizo-test-fixture.apk"
META_OUT="$SHARE/rhizo-test-fixture.json"
INDEX_CACHE="/tmp/rhizo-fdroid-index-v2.json"
INDEX_MAX_AGE_S=$((24 * 3600))

source ./tools/build/toolchain/android-sdk.sh
android_sdk_resolve || exit 1

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

# print a [fetch-test-apk] line to stderr
log() { echo "[fetch-test-apk] $*" >&2; }

if [[ "$FORCE" == 0 && -f "$APK_OUT" && -f "$META_OUT" ]]; then
  want_sha=$(python3 -c "import json; print(json.load(open('$META_OUT'))['sha256'])" 2>/dev/null)
  got_sha=$(sha256sum "$APK_OUT" 2>/dev/null | cut -d' ' -f1)
  if [[ -n "$want_sha" && "$want_sha" == "$got_sha" ]]; then
    pkg=$(python3 -c "import json; print(json.load(open('$META_OUT'))['package'])")
    log "ok $APK_OUT package=$pkg sha256=$got_sha"
    cat "$META_OUT" >&2
    exit 0
  fi
  log "sha256 of $APK_OUT does not match $META_OUT"
fi

need_fetch=1
if [[ -f "$INDEX_CACHE" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$INDEX_CACHE") ))
  (( age < INDEX_MAX_AGE_S )) && need_fetch=0
fi
if (( need_fetch )); then
  curl -sS --max-time 90 -o "$INDEX_CACHE.tmp" \
    https://f-droid.org/repo/index-v2.json || { log "curl https://f-droid.org/repo/index-v2.json failed"; exit 1; }
  mv "$INDEX_CACHE.tmp" "$INDEX_CACHE"
else
  log "$INDEX_CACHE age_s=$((age))"
fi

CANDS=$(python3 tools/fetch/test-apk-candidates.py "$INDEX_CACHE")
n=$(grep -c . <<<"$CANDS" || true)
log "candidates=$n"
[[ "$n" -gt 0 ]] || { log "test-apk-candidates.py printed no candidates"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

while IFS=$'\t' read -r size pkgname fname sha; do
  [[ -n "$pkgname" ]] || continue
  out="$WORK/cand.apk"
  log "candidate $pkgname bytes=${size} file=$fname"
  if ! curl -sS --max-time 30 -o "$out" "https://f-droid.org/repo${fname}"; then
    log "skip $pkgname curl failed"; continue
  fi
  gotsha=$(sha256sum "$out" | cut -d' ' -f1)
  if [[ "$gotsha" != "$sha" ]]; then
    log "skip $pkgname sha256 $gotsha, expected $sha"; continue
  fi

  badging=$("$AAPT2" dump badging "$out" 2>/dev/null)
  if [[ -z "$badging" ]]; then log "skip $pkgname aapt2 dump badging printed nothing"; continue; fi

  if grep -q "^native-code:" <<<"$badging"; then
    log "skip $pkgname native-code"; continue
  fi
  if grep -qi "testOnly='.*true.*'\|testOnly='1'" <<<"$badging"; then
    log "skip $pkgname testOnly"; continue
  fi
  target=$(grep -m1 '^targetSdkVersion:' <<<"$badging" | grep -o "[0-9]\+")
  if [[ -z "$target" || "$target" -lt 26 ]]; then
    log "skip $pkgname targetSdkVersion='$target' < 26"; continue
  fi
  bad_perm=""
  while read -r p; do
    case "$p" in
      *READ_CALENDAR*|*WRITE_CALENDAR*|*CAMERA*|*READ_CONTACTS*|*WRITE_CONTACTS*|*GET_ACCOUNTS*|\
      *ACCESS_FINE_LOCATION*|*ACCESS_COARSE_LOCATION*|*ACCESS_BACKGROUND_LOCATION*|*RECORD_AUDIO*|\
      *READ_PHONE_STATE*|*READ_PHONE_NUMBERS*|*CALL_PHONE*|*ANSWER_PHONE_CALLS*|*READ_CALL_LOG*|*WRITE_CALL_LOG*|\
      *ADD_VOICEMAIL*|*USE_SIP*|*PROCESS_OUTGOING_CALLS*|*BODY_SENSORS*|*SEND_SMS*|*RECEIVE_SMS*|*READ_SMS*|\
      *RECEIVE_WAP_PUSH*|*RECEIVE_MMS*|*READ_EXTERNAL_STORAGE*|*WRITE_EXTERNAL_STORAGE*|*MANAGE_EXTERNAL_STORAGE*|\
      *ACCESS_MEDIA_LOCATION*|*READ_MEDIA_IMAGES*|*READ_MEDIA_VIDEO*|*READ_MEDIA_AUDIO*|*ACTIVITY_RECOGNITION*|\
      *BLUETOOTH_ADVERTISE*|*BLUETOOTH_SCAN*|*BLUETOOTH_CONNECT*|*NEARBY_WIFI_DEVICES*|*POST_NOTIFICATIONS*)
        bad_perm="$p" ;;
    esac
  done < <(grep "^uses-permission:" <<<"$badging" | grep -o "name='[^']*'" | sed "s/name='//;s/'//")
  if [[ -n "$bad_perm" ]]; then
    log "skip $pkgname permission $bad_perm"; continue
  fi

  la=$(grep -m1 "^launchable-activity:" <<<"$badging")
  if [[ -z "$la" ]]; then
    log "skip $pkgname no launchable-activity"; continue
  fi
  act=$(echo "$la" | sed "s/.*name='\([^']*\)'.*/\1/")

  if ! "$ZIPALIGN" -c 4 "$out" >/tmp/rhizo-zipalign-check.log 2>&1; then
    log "skip $pkgname zipalign -c 4 failed"
    continue
  fi

  label=$(grep -m1 "^application-label:" <<<"$badging" | sed "s/^application-label:'//;s/'\$//")

  cp --remove-destination "$out" "$APK_OUT"
  cat > "$META_OUT" << EOF
{
  "package": "$pkgname",
  "activity": "$act",
  "label": "$label",
  "sha256": "$gotsha",
  "source_url": "https://f-droid.org/repo${fname}",
  "size": $size,
  "target_sdk": $target,
  "selected_at": "$(date -u +%FT%TZ)"
}
EOF
  log "wrote $APK_OUT package=$pkgname activity=$act label='$label' sha256=$gotsha"
  cat "$META_OUT" >&2
  exit 0
done <<< "$CANDS"

log "no candidate passed the aapt2 and zipalign checks"
exit 1
