# shellcheck shell=bash
# print the guest CPU busy percent
guest_busy_pct() {
  ssh_vm -t 20 "awk '/^cpu /{i1=\$5;t1=0;for(f=2;f<=8;f++)t1+=\$f}
                     END{print i1\" \"t1}' /proc/stat; sleep 3;
                awk '/^cpu /{i2=\$5;t2=0;for(f=2;f<=8;f++)t2+=\$f}
                     END{print i2\" \"t2}' /proc/stat" 2>/dev/null \
    | awk 'NR==1{i1=$1;t1=$2} NR==2{i2=$1;t2=$2}
           END{dt=t2-t1; if(dt<=0){print 100; exit} printf "%d", 100-(100*(i2-i1)/dt)}'
}

# wait for two quiet 3s CPU windows
await_guest_quiet() {
  local windows="${1:-24}" quiet=0 busy=100 _
  for _ in $(seq 1 "$windows"); do
    busy=$(guest_busy_pct)
    [[ -z "$busy" ]] && busy=100
    if (( busy < 15 )); then
      quiet=$((quiet + 1))
      (( quiet >= 2 )) && { echo "quiet at ${busy}% busy"; return 0; }
    else
      quiet=0
    fi
  done
  echo "NOT QUIET after $windows windows (last ${busy}% busy)"
  return 1
}

# print the seconds between two timestamps
ago() { if [[ -n "$2" ]]; then echo "$(( $1 - $2 ))s ago"; else echo "never"; fi; }
# wait until no process has started or frozen recently
await_post_boot_wave() {
  local pkg="$1"; shift
  local deadline=$((SECONDS + 150)) ev now last_start last_freeze
  while (( SECONDS < deadline )); do
    ev=$("$@" logcat -d -v epoch -b events 2>/dev/null | grep -a "am_proc_start\|am_freeze" | grep -av "$pkg")
    now=$("$@" shell date +%s 2>/dev/null)
    last_start=$(printf '%s\n' "$ev" | grep -a am_proc_start | tail -1 | awk '{print int($1)}')
    last_freeze=$(printf '%s\n' "$ev" | grep -a am_freeze | tail -1 | awk '{print int($1)}')
    [[ -n "$now" ]] || { sleep 3; continue; }
    if (( now - ${last_start:-0} >= 35 && now - ${last_freeze:-0} >= 5 )); then
      echo "post-boot wave passed: last process start $(ago "$now" "$last_start"), last freeze $(ago "$now" "$last_freeze")"
      return 0
    fi
    sleep 3
  done
  echo "post-boot wave NOT passed by the deadline: last process start ${last_start:-?}, last freeze ${last_freeze:-?}, now $now"
  return 1
}

# count display pooled lines in rhizo_ctl output
pool_refill_count() {
  rhizo_ctl_out "$1" | grep -c "display pooled id=" || true
}

# wait for the display pool to refill
await_pool_refill() {
  local init="$1" before="$2" deadline=$((SECONDS + 60)) n
  while (( SECONDS < deadline )); do
    n=$(pool_refill_count "$init")
    if (( n > before )); then
      echo "display pool refilled ($before -> $n)"
      return 0
    fi
    sleep 2
  done
  echo "display pool NOT refilled within 60s (still $before)"
  return 1
}
