#!/bin/bash
# label guard log lines current or earlier
set -u

FILE="${1:-/data/local/tmp/rhizo-layerstack-guard.log}"
BOOT_EPOCH="${2:-}"

if [[ -z "$BOOT_EPOCH" ]]; then
  now=$(date -u +%s)
  uptime_s=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
  uptime_s="${uptime_s%.*}"
  [[ "$uptime_s" =~ ^[0-9]+$ ]] || uptime_s=0
  BOOT_EPOCH=$((now - uptime_s))
fi

# print an epoch time as an ISO UTC time
to_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

if [[ ! -e "$FILE" ]]; then
  echo "STATUS none-existed no guard log at $FILE"
  exit 0
fi
if ! content=$(cat "$FILE" 2>/dev/null); then
  echo "STATUS unreadable $FILE could not be read"
  exit 0
fi
if [[ -z "$content" ]]; then
  echo "STATUS empty $FILE exists but the guard never appended a verdict"
  exit 0
fi

echo "STATUS reference this boot started $(to_iso "$BOOT_EPOCH")"

cur=0 earlier=0 bad=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  t="${line#t=}"; t="${t%% *}"
  if [[ ! "$t" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    bad=$((bad + 1))
    echo "LINE UNPARSEABLE $line"
  elif awk -v a="$t" -v b="$BOOT_EPOCH" 'BEGIN{exit !(a>=b)}'; then
    cur=$((cur + 1))
    echo "LINE CURRENT $line"
  else
    earlier=$((earlier + 1))
    echo "LINE EARLIER $line"
  fi
done <<<"$content"

echo "SUMMARY total=$((cur + earlier + bad)) current=$cur earlier=$earlier unparseable=$bad"
