#!/bin/bash
# print the cause of an unreachable vm
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
# print a message to stderr unless quiet
say() { (( QUIET )) || echo "$*" >&2; }
# print the CAUSE line and its explanation and exit 0
verdict() { echo "CAUSE=$1"; say "  $2"; [[ -n "${3:-}" ]] && say "  -> $3"; exit 0; }

# print how far Android got as procs and enforce fields
boot_stage() {
  local init_pid="$1" out rc enforce procs pid unreadable

  out=$(_ssh_vm_out 8 'cat /sys/fs/selinux/enforce'); rc=$?
  if (( rc != 0 )); then
    enforce="unknown:enforce-read-failed(rc=$rc)"
  else
    case "$out" in
      0) enforce="0" ;;
      1) enforce="1" ;;
      *) enforce="unknown:enforce-unexpected-value(${out:-<empty>})" ;;
    esac
  fi

  out=$(_stage_pid_by_argv0 zygote64 "$init_pid"); rc=$?
  if (( rc != 0 )); then
    procs="unknown:zygote-read-failed(rc=$rc)"
  elif [[ "$(sed -n 's/^NOINIT=//p' <<<"$out")" == "1" ]]; then
    procs="unknown:no-init"
  else
    pid=$(sed -n 's/^MATCH=//p' <<<"$out")
    unreadable=$(sed -n 's/^UNREADABLE=//p' <<<"$out")
    if [[ -z "$pid" ]]; then
      if [[ "${unreadable:-0}" -gt 0 ]]; then
        procs="unknown:zygote-cmdline-unreadable(n=$unreadable)"
      else
        procs="none"
      fi
    else
      out=$(_stage_pid_by_argv0 system_server "$init_pid"); rc=$?
      if (( rc != 0 )); then
        procs="unknown:system_server-read-failed(rc=$rc)"
      elif [[ "$(sed -n 's/^NOINIT=//p' <<<"$out")" == "1" ]]; then
        procs="unknown:no-init"
      else
        pid=$(sed -n 's/^MATCH=//p' <<<"$out")
        unreadable=$(sed -n 's/^UNREADABLE=//p' <<<"$out")
        if [[ -z "$pid" ]]; then
          if [[ "${unreadable:-0}" -gt 0 ]]; then
            procs="unknown:system_server-cmdline-unreadable(n=$unreadable)"
          else
            procs="zygote"
          fi
        else
          procs="system_server"
        fi
      fi
    fi
  fi

  echo "procs:$procs enforce:$enforce"
}

# find the pids with an argv0 in init's pid namespace
_stage_pid_by_argv0() {
  local argv0="$1" init_pid="$2" raw rc last_line
  raw=$(_ssh_vm_out 8 "root=\${RHIZO_STAGE_PROC_ROOT:-/proc}; \
    if [ ! -d \"\$root/$init_pid\" ]; then \
      echo \"MATCH=\"; echo \"UNREADABLE=0\"; echo \"NOINIT=1\"; echo __STAGE_END__; \
    else \
      init_ns=\$(readlink \"\$root/$init_pid/ns/pid\" 2>/dev/null); \
      unreadable=0; match=''; \
      for p in \"\$root\"/[0-9]*; do \
        pid=\${p##*/}; \
        if [ -n \"\$init_ns\" ]; then \
          pns=\$(readlink \"\$p/ns/pid\" 2>/dev/null); \
          [ -n \"\$pns\" ] && [ \"\$pns\" != \"\$init_ns\" ] && continue; \
        fi; \
        [ -e \"\$p\" ] || continue; \
        if [ -r \"\$p/cmdline\" ]; then \
          a0=\$(head -z -n1 \"\$p/cmdline\" 2>/dev/null | tr -d '\\0'); \
          [ \"\${a0##*/}\" = \"$argv0\" ] && { match=\"\$pid\"; break; }; \
        else \
          unreadable=\$((unreadable + 1)); \
        fi; \
      done; \
      echo \"MATCH=\$match\"; echo \"UNREADABLE=\$unreadable\"; echo \"NOINIT=0\"; echo __STAGE_END__; \
    fi")
  rc=$?
  if (( rc != 0 )); then
    return 1
  fi
  last_line="${raw##*$'\n'}"
  if [[ "$last_line" != "__STAGE_END__" ]]; then
    return 1
  fi
  printf '%s\n' "$raw"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" || -z "${RHIZO_EXPLAIN_BOOT_LIB_ONLY:-}" ]]; then

busy=$(rig_vm_busy "$RHIZO_VM")
if [[ -n "$busy" ]]; then
  verdict VM_BUSY "$busy" "boot a different vm, or wait for this one"
fi

CONSOLE="$VAR_DIR/vm-boot${SUFFIX}.log"
if grep -qi 'kernel panic\|Attempted to kill init' "$CONSOLE" 2>/dev/null; then
  verdict GUEST_KERNEL_PANIC "the guest kernel panicked" \
    "delete vm${SUFFIX}.qcow2 to re-derive the vm from the frozen base"
fi

if [[ -r "$CONSOLE" ]] && grep -q '^\[.*\] init: ' "$CONSOLE" 2>/dev/null; then
  if ! grep -q 'RHIZO_MARKER sys.boot_completed=1' "$CONSOLE" 2>/dev/null; then
    crashed=$(grep -aoE "(components|service) '[a-zA-Z_0-9.-]+' exited [0-9]+ times before boot completed" "$CONSOLE" 2>/dev/null |
              sed -E "s/.*'([^']+)'.*/\1/" | sort | uniq -c | sort -rn | head -1)
    if [[ -n "$crashed" ]]; then
      svc=$(awk '{print $2}' <<<"$crashed"); n=$(awk '{print $1}' <<<"$crashed")
      verdict "ANDROID_SERVICE_CRASHLOOP=$svc" \
        "init reports '$svc' exhausted its restarts before boot completed ($n line(s) on the console)" \
        "read $CONSOLE around the first occurrence, and logcat in the collect-boot-evidence.sh bundle"
    fi
    stalled=$(grep -aoE "Could not find 'aidl/[a-zA-Z_0-9.]+'" "$CONSOLE" 2>/dev/null |
              sed -E "s/.*aidl\/([^']+)'.*/\1/" | sort | uniq -c | sort -rn | head -1)
    if [[ -n "$stalled" ]]; then
      iface=$(awk '{print $2}' <<<"$stalled"); n=$(awk '{print $1}' <<<"$stalled")
      if (( n >= 3 )); then
        verdict "ANDROID_STALLED_ON=$iface" \
          "servicemanager asked for 'aidl/$iface' $n times and never got it" \
          "read logcat in the collected evidence"
      fi
    fi
  fi
fi

qpid=""
if [[ -f "$VM_PIDFILE" ]]; then
  p=$(cat "$VM_PIDFILE" 2>/dev/null)
  if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null &&
     [[ "$(cat "/proc/$p/comm" 2>/dev/null)" == qemu-system-* ]]; then
    qpid="$p"
  fi
fi
[[ -z "$qpid" ]] && qpid=$(lsof -t -i ":$SSH_PORT" -sTCP:LISTEN 2>/dev/null | head -1)

if [[ -z "$qpid" ]]; then
  tail_line=$(tail -3 "$CONSOLE" 2>/dev/null | tr '\n' ' ')
  if _boot_refused_via "$VAR_DIR/vm-boot${SUFFIX}.pid"; then
    verdict BOOT_REFUSED "run-vm.sh refused this boot and never started qemu for vm $RHIZO_VM -- it said: ${tail_line:-<the launcher log is empty>}" \
      "do what that line says, then boot"
  fi
  verdict QEMU_NOT_RUNNING "no qemu for vm $RHIZO_VM, nothing listening on $SSH_PORT" \
    "boot it: RHIZO_VM=$RHIZO_VM test/vm/boot-release.sh a16${tail_line:+  (console tail: ${tail_line:0:90})}"
fi

CPU_NOTE=""
smp=$(tr '\0' '\n' < "/proc/$qpid/cmdline" 2>/dev/null | grep -A1 -x -- '-smp' | tail -1)
smp="${smp%%,*}"; smp="${smp##*=}"
[[ "$smp" =~ ^[0-9]+$ ]] || smp=0
a=$(awk '{print $14+$15}' "/proc/$qpid/stat" 2>/dev/null)
csize_a=$(stat -c %s "$CONSOLE" 2>/dev/null || echo 0)
sleep 3
b=$(awk '{print $14+$15}' "/proc/$qpid/stat" 2>/dev/null)
csize_b=$(stat -c %s "$CONSOLE" 2>/dev/null || echo 0)
if [[ -n "$a" && -n "$b" ]]; then
  pct=$(( (b - a) * 100 / 3 / 100 ))
  ncpu=$(nproc 2>/dev/null || echo 1)
  load=$(awk '{printf "%d", $1}' /proc/loadavg 2>/dev/null || echo 0)
  ceiling=$(( smp * 100 ))
  progressing=0
  (( csize_b > csize_a )) && progressing=1
  if (( smp == 0 )); then
    verdict CPU_UNMEASURABLE "qemu $qpid is running but its argv carries no readable -smp" \
      "read the serial console at $CONSOLE"
  fi
  if (( pct >= ceiling * 3 / 4 && progressing == 0 )); then
    verdict GUEST_CPU_RUNAWAY "qemu $qpid is CONSUMING ${pct}% of a core (${smp} vCPUs = ${ceiling}%) and has written nothing to the console in 3s" \
      "read the serial console at $CONSOLE"
  fi
  if (( pct >= ceiling * 3 / 4 && progressing == 1 )); then
    verdict GUEST_BUSY_BOOTING "qemu $qpid is at ${pct}% of ${ceiling}% AND still writing to the console" \
      "raise --boot-wait"
  fi
  if (( pct < 100 && load > ncpu )); then
    verdict HOST_CPU_CONTENDED "qemu $qpid is getting only ${pct}% of a core while host load is ${load} on ${ncpu} cpus" \
      "check for other qemus (/proc/*/comm) and 'systemctl --user list-timers'"
  fi
  CPU_NOTE="qemu $qpid at ${pct}% of ${ceiling}% (${smp} vCPUs), host load ${load} on ${ncpu} cpus, console $( (( progressing )) && echo growing || echo quiet)"
fi

if ! ssh_vm -t 10 true >/dev/null 2>&1; then
  banner=$(ssh_port_banner 5) || banner=""
  if [[ -n "$banner" ]]; then
    verdict SSH_CLIENT_BROKEN "qemu $qpid is running and port $SSH_PORT answers \"$banner\" -- the host ssh client fails: $(ssh_vm_error)" \
      "fix the host ssh client (ControlPath directory, key, agent) and re-run without re-booting${RHIZO_SSH_CONTROL_DIR_NOTE:+ -- ControlMaster directory fallbacks taken: $RHIZO_SSH_CONTROL_DIR_NOTE}"
  fi
  verdict SSHD_UNREACHABLE "qemu $qpid is running and sshd does not answer on $SSH_PORT${CPU_NOTE:+ -- $CPU_NOTE}" \
    "read the serial console at $CONSOLE"
fi

init_pid=$(guest_init_pid 10)
if [[ -z "$init_pid" ]]; then
  verdict ANDROID_NOT_LAUNCHED "the vm is healthy and ssh works, but no Android init is running${CPU_NOTE:+ -- $CPU_NOTE}" \
    "launch it, or run test/vm/boot/preflight.sh to check the pieces init needs"
fi
bc=$(android_sh "$init_pid" "getprop sys.boot_completed" 2>/dev/null | tr -d '\r\n ')
if [[ "$bc" == 1 ]]; then
  verdict HEALTHY "vm $RHIZO_VM is up and Android reports boot_completed=1" ""
fi
stage=$(boot_stage "$init_pid")
echo "STAGE=$stage"
verdict ANDROID_NOT_BOOTED "Android init is running as pid $init_pid but boot_completed is not set (furthest reached: ${stage})${CPU_NOTE:+ -- $CPU_NOTE}" \
  "check logcat via android_sh"

fi
