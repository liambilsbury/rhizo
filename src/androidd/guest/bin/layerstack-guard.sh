#!/system/bin/sh
# repair the layerstack of a display
export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH

LOGID="$1"
CID="$2"
TAG="$3"

GUARD_LOG=/data/local/tmp/rhizo-layerstack-guard.log

GUARD_POLL_S=0.25
GUARD_MISMATCH_HOLD_S=1.0
GUARD_MAX_REPAIRS=3
GUARD_REPAIR_OFF_CONFIRM_S=2
GUARD_WINDOW_S=10

# print the current time in seconds
now_t() { date +%s.%N; }

# check $1 >= $2
ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }
# print the sum of two times
add_t() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", a+b}'; }
# print the difference of two times
sub_t() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", a-b}'; }
# print the larger of two times
max_t() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.6f", (a>b)?a:b}'; }

# print the SurfaceFlinger dump
sf_dump() {
  if [ -n "$RHIZO_GUARD_SF_DUMP_FILE" ]; then
    cat "$RHIZO_GUARD_SF_DUMP_FILE"
  else
    dumpsys SurfaceFlinger 2>/dev/null
  fi
}
# print the display service dump
display_dump() {
  if [ -n "$RHIZO_GUARD_DISPLAY_DUMP_FILE" ]; then
    cat "$RHIZO_GUARD_DISPLAY_DUMP_FILE"
  else
    dumpsys display 2>/dev/null
  fi
}

# print the physical id and layer stack
sf_layerstack() {
  awk -v cid="$1" '
    $0 ~ "\\(HWC display " cid "\\):" { physid = $2 }
    physid != "" && !in_block && $0 ~ ("^Display " physid " \\(physical") { grab = 6; in_block = 1; next }
    in_block && grab > 0 {
      if ($0 ~ /layerFilter=\{layerStack=/) {
        match($0, /layerStack=[0-9]+/)
        print physid" "substr($0, RSTART + 11, RLENGTH - 11)
        found = 1
        exit
      }
      grab--
    }
    END { if (physid != "" && !found) print physid" NA" }
  '
}

# print mCurrentLayerStack for a physical display
dms_layerstack() {
  awk -v physid="$1" '
    $0 ~ ("mUniqueId=local:" physid "$") { grab = 6; next }
    grab > 0 {
      if (match($0, /mCurrentLayerStack=-?[0-9]+/)) {
        print substr($0, RSTART + 19, RLENGTH - 19)
        exit
      }
      grab--
    }
  '
}

# turn the display off and on
repair_display() {
  cmd display power-off "$LOGID"
  off_deadline=$(add_t "$(now_t)" "$GUARD_REPAIR_OFF_CONFIRM_S")
  while :; do
    ge "$(now_t)" "$off_deadline" && { repair_off_timeouts=$((repair_off_timeouts + 1)); break; }
    case "$(display_dump | dms_layerstack "$1")" in
      ''|-*) break ;;
    esac
    sleep "$GUARD_POLL_S"
  done
  cmd display power-reset "$LOGID"
}

start_t=$(now_t)
deadline_t=$(add_t "$start_t" "$GUARD_WINDOW_S")
mismatch_since=""
first_mismatch_ms="-"
repairs=0
repair_off_timeouts=0
final="-"
final_is_mismatch=0
verdict=""

while :; do
  poll_t=$(now_t)
  ge "$poll_t" "$deadline_t" && break

  result=$(sf_dump | sf_layerstack "$CID")
  if [ -z "$result" ]; then
    verdict=gone
    final=gone
    break
  fi
  physid=${result%% *}
  layerstack=${result#* }
  if [ "$layerstack" = "NA" ]; then
    sleep "$GUARD_POLL_S"
    continue
  fi

  final_is_mismatch=0
  if [ "$layerstack" != "4294967295" ]; then
    mismatch_since=""
  else
    dms_val=$(display_dump | dms_layerstack "$physid")
    case "$dms_val" in
      ''|-*)
        mismatch_since=""
        ;;
      *)
        final_is_mismatch=1
        repairable=0
        [ "$repairs" -lt "$GUARD_MAX_REPAIRS" ] && repairable=1
        if [ -z "$mismatch_since" ]; then
          mismatch_since="$poll_t"
          [ "$first_mismatch_ms" = "-" ] && first_mismatch_ms=$(awk -v a="$poll_t" -v s="$start_t" 'BEGIN{printf "%.0f", (a-s)*1000}')
          [ "$repairable" -eq 1 ] && deadline_t=$(max_t "$deadline_t" "$(add_t "$poll_t" "$GUARD_WINDOW_S")")
        fi
        held=$(sub_t "$poll_t" "$mismatch_since")
        if [ "$repairable" -eq 1 ] && ge "$held" "$GUARD_MISMATCH_HOLD_S"; then
          repair_display "$physid"
          repairs=$((repairs + 1))
          mismatch_since=""
          deadline_t=$(max_t "$deadline_t" "$(add_t "$poll_t" "$GUARD_WINDOW_S")")
        fi
        ;;
    esac
  fi
  final="$layerstack"
  sleep "$GUARD_POLL_S"
done

if [ "$verdict" != gone ]; then
  if [ "$final_is_mismatch" -eq 1 ]; then
    verdict=unrepaired
  elif [ "$repairs" -gt 0 ]; then
    verdict=repaired
  else
    verdict=ok
  fi
fi

echo "t=$(now_t) tag=$TAG logid=$LOGID cid=$CID repairs=$repairs first_mismatch_ms=$first_mismatch_ms final=$final verdict=$verdict repair_off_timeouts=$repair_off_timeouts" >> "$GUARD_LOG"
