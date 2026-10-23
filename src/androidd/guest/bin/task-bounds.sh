#!/system/bin/sh
# apply the composer's window sizes to each display's freeform task and minimize all of the windows on HOME
D=/data/rhizo_control
M=/data/local/tmp/rhizo-tasks
mkdir -p "$M"
echo $$ > "$M/helper.pid"
# print the first task on Android display $1
display_task() {
  dumpsys activity activities | awk -v d="Display #$1 " 'index($0, d) == 1 { on = 1; next }
    /^Display #/ { on = 0 }
    on && match($0, /Task\{[0-9a-f]+ #[0-9]+/) { s = substr($0, RSTART, RLENGTH); sub(/.*#/, "", s); print s; exit }'
}
logcat -b main,events -T 1 -s wm_task_removed:I RhizoHome:I 2>/dev/null | while read -r line; do
  case "$line" in
    *" RhizoHome: "*) echo display minimize-all > "$D/control"; continue ;;
  esac
  task=$(echo "$line" | sed -n 's/.*wm_task_removed: \[\([0-9]*\),.*/\1/p')
  [ -n "$task" ] || continue
  for f in "$M"/task-*; do
    [ "$(cat "$f" 2>/dev/null)" = "$task" ] || continue
    cid=${f##*/task-}
    next=$(display_task "$(cat "$M/display-$cid" 2>/dev/null)")
    rm -f "$M/last-$cid"
    if [ -n "$next" ] && [ "$next" != "$task" ]; then
      echo "$next" > "$f"
    else
      rm -f "$f" "$M/display-$cid"
      echo display remove "$cid" > "$D/control"
    fi
  done
done &
inotifyd - "$D:w" | while read -r _ _ file; do
  case "$file" in
    task-close-*)
      cid=${file#task-close-}
      task=""
      read -r task < "$M/task-$cid" 2>/dev/null
      if [ -n "$task" ] && dumpsys activity activities | grep -qE "Task\{[0-9a-f]+ #$task[^0-9]" \
          && am stack remove "$task" >/dev/null 2>&1; then
        continue
      fi
      rm -f "$M/task-$cid" "$M/display-$cid" "$M/last-$cid"
      echo display remove "$cid" > "$D/control"
      continue ;;
    task-bounds-*) ;;
    *) continue ;;
  esac
  cid=${file#task-bounds-}
  read -r w h < "$D/$file" || continue
  task=""; last=""
  read -r task < "$M/task-$cid" 2>/dev/null
  [ -n "$task" ] || continue
  read -r last < "$M/last-$cid" 2>/dev/null
  [ "$w $h" = "$last" ] && continue
  cmd activity task resize "$task" 0 0 "$w" "$h" >/dev/null 2>&1 && echo "$w $h" > "$M/last-$cid"
done
