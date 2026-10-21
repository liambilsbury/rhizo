#!/bin/bash
# summarize the tombstone files
set -u

DIR="${1:-/run/rhizo/data/tombstones}"
BOOT_EPOCH="${2:-}"
BOOT_KERNEL="${3:-}"
MAX_FILES=10
MAX_BYTES=65536

if [[ -z "$BOOT_EPOCH" ]]; then
  now=$(date -u +%s)
  uptime_s=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
  uptime_s="${uptime_s%.*}"
  [[ "$uptime_s" =~ ^[0-9]+$ ]] || uptime_s=0
  BOOT_EPOCH=$((now - uptime_s))
fi
[[ -n "$BOOT_KERNEL" ]] || BOOT_KERNEL=$(uname -r)

# print an epoch time as an ISO UTC time
to_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

if [[ ! -e "$DIR" ]]; then
  echo "STATUS none-existed no tombstones directory at $DIR"
  exit 0
fi

listing=$(find "$DIR" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null)
find_rc=$?
listing=$(sort <<<"$listing")
if (( find_rc != 0 )); then
  echo "STATUS unreadable $DIR could not be listed"
  exit 0
fi
if [[ -z "$listing" ]]; then
  echo "STATUS none-existed $DIR holds no tombstone files"
  exit 0
fi

echo "STATUS reference this boot started $(to_iso "$BOOT_EPOCH") on kernel '$BOOT_KERNEL'"

count=0
while IFS= read -r name; do
  (( count >= MAX_FILES )) && break
  count=$((count + 1))
  f="$DIR/$name"
  if ! content=$(head -c "$MAX_BYTES" "$f" 2>/dev/null); then
    echo "SUMMARY $name UNREADABLE could not read $f"
    continue
  fi
  size=$(stat -c %s "$f" 2>/dev/null || echo '?')
  abort=$(grep -m1 '^Abort message:' <<<"$content")
  [[ -n "$abort" ]] || abort="(no Abort message line)"

  ts_raw=$(grep -m1 '^Timestamp:' <<<"$content")
  ts_raw="${ts_raw#Timestamp: }"
  kernel_raw=$(grep -m1 '^Kernel Release:' <<<"$content")
  kernel_raw="${kernel_raw#Kernel Release: }"
  kernel_raw="${kernel_raw//\'/}"

  ts_epoch=""
  [[ -n "$ts_raw" ]] && ts_epoch=$(date -u -d "$ts_raw" +%s 2>/dev/null)

  if [[ -z "$ts_epoch" ]]; then
    echo "SUMMARY $name $size UNDATED no parseable Timestamp/Kernel Release header $abort"
  elif [[ -n "$kernel_raw" && "$kernel_raw" != "$BOOT_KERNEL" ]] || (( ts_epoch < BOOT_EPOCH )); then
    echo "SUMMARY $name $size EARLIER ts=$(to_iso "$ts_epoch") kernel='$kernel_raw' predates this boot (started $(to_iso "$BOOT_EPOCH") on '$BOOT_KERNEL') $abort"
  else
    echo "SUMMARY $name $size CURRENT ts=$(to_iso "$ts_epoch") kernel='$kernel_raw' $abort"
  fi
  printf '===TOMBSTONE %s===\n%s\n===END %s===\n' "$name" "$content" "$name"
done <<<"$listing"
