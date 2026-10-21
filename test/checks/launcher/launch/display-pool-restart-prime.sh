#!/bin/bash
# test priming a spare on stack restart
set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POOL_FILL="${RHIZO_CHECK_FILL_DISPLAY_POOL:-$TOOLS_DIR/../../src/androidd/host/fill-display-pool.sh}"
IDLE="$TOOLS_DIR/../../src/androidd/host/release-idle-display.sh"

# run a copy of the script under test
run_prime() {
  local script="$1" t="$2" scenario="$3"
  mkdir -p "$t/pool" "$t/data/rhizo_control" "$t/tools" "$t/bin" "$t/cg"
  local n
  n=$(grep -c '^POOL_DIR=/run/rhizo-display-pool$' "$script")
  [[ "$n" == 1 ]] || { echo "HARNESS: $script has $n POOL_DIR=/run/rhizo-display-pool lines, want 1"; return 2; }
  sed "s#^POOL_DIR=/run/rhizo-display-pool\$#POOL_DIR=$t/pool#" "$script" > "$t/rhizo-fill-display-pool.sh"
  cp "$TOOLS_DIR/../../src/androidd/host/parse-display-list.sh" "$t/tools/rhizo-display-list.sh"
  cat > "$t/tools/rhizo-cgroup-unfreeze.sh" <<EOF
rhizo_stack_cgroup() { echo "$t/cg"; }
rhizo_stack_frozen() { return 1; }
EOF
  mkdir -p "$t/proc/4242"
  printf '/system/bin/init\0second_stage\0' > "$t/proc/4242/cmdline"
  printf '0::/rhizo/init\n' > "$t/proc/4242/cgroup"
  printf '#!/bin/sh\necho "$*" >> %s/logger.log\n' "$t" > "$t/bin/logger"
  printf '#!/bin/sh\nexit 0\n' > "$t/bin/sleep"
  cat > "$t/rhizo-probe-client" <<EOF
#!/bin/bash
cmd="\${3#export PATH=/system/bin:/system/xbin:/vendor/bin; }"
case "\$cmd" in
  "getprop sys.boot_completed") echo 1 ;;
  "echo display list > /data/rhizo_control/control")
    echo "display list \$(cat $t/live-displays)" >> $t/data/rhizo_control/control.out ;;
  "echo display remove "*) echo "\$cmd" >> $t/removed.log ;;
  "sh /system_ext/bin/rhizo-add-pool-display.sh "*)
    echo guest >> $t/guest.log
    printf 'stage=wake awake=was-Awake\nstage=done id=3 logid=3 port=2 w=960 h=1080\n' ;;
  *) cd $t && sh -c "\$(printf '%s' "\$cmd" | sed -e 's#toybox grep#grep#g' -e 's#/data/#$t/data/#g')" 2>&1 ;;
esac
exit 0
EOF
  chmod +x "$t/bin/"* "$t/rhizo-probe-client"
  echo "1(960x1080)" > "$t/live-displays"
  if [[ "$scenario" == restart ]]; then
    echo "logid=2 id=2 port=1 w=960 h=1080" > "$t/pool/ready"
  else
    echo "display added id=1 port=0 960x1080" > "$t/data/rhizo_control/control.out"
  fi
  RHIZO_PROC_ROOT="$t/proc" PATH="$t/bin:$PATH" sh "$t/rhizo-fill-display-pool.sh" > "$t/run.log" 2>&1
  echo "rc=$?"
}

# print the reason the prime failed
verdict() {
  local t="$1"
  [[ -s "$t/guest.log" ]] || { echo "the pool fill never ran"; return; }
  grep -q '^logid=3 id=3 port=2 ' "$t/pool/ready" 2>/dev/null \
    || echo "the ready file does not name the new spare ($(cat "$t/pool/ready" 2>/dev/null || echo absent))"
}

# list the reply count commands in both scripts
count_commands() {
  grep -n "probe [0-9]* 'toybox grep -c" "$POOL_FILL" "$IDLE"
}

if [[ "${1:-}" == "--selftest" ]]; then
  work=$(mktemp -d) || exit 1
  trap 'rm -rf "$work"' EXIT
  sed "s#toybox grep -c \"^display list\" /data/rhizo_control/control.out 2>/dev/null'#toybox grep -c \"^display list\" /data/rhizo_control/control.out'#" \
    "$POOL_FILL" > "$work/pool-fill-bare.sh"
  if cmp -s "$work/pool-fill-bare.sh" "$POOL_FILL"; then
    echo "SELFTEST FAILED: could not seed the bare count into a copy of $POOL_FILL" >&2; exit 1
  fi
  mkdir "$work/bare"
  run_prime "$work/pool-fill-bare.sh" "$work/bare" restart >/dev/null
  why=$(verdict "$work/bare")
  [[ -n "$why" ]] || { echo "SELFTEST FAILED: a bare reply count still primed a restarted stack" >&2; exit 1; }
  echo "selftest ok: a bare reply count leaves a restarted stack with no spare ($why)"
  mkdir "$work/first"
  run_prime "$work/pool-fill-bare.sh" "$work/first" first-boot >/dev/null
  why=$(verdict "$work/first")
  [[ -z "$why" ]] || { echo "SELFTEST FAILED: even a bare count's first-boot prime made no spare: $why" >&2; exit 1; }
  echo "selftest ok: the same bare count still primes a first boot, whose reply log already exists"
  exit 0
fi

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
fail=0
out=$(run_prime "$POOL_FILL" "$work" restart)
[[ "$out" == HARNESS:* ]] && { echo "check-display-pool-restart-prime: $out"; exit 1; }
why=$(verdict "$work")
if [[ -n "$why" ]]; then
  echo "check-display-pool-restart-prime: a stack restarted with an empty reply log gets no spare: $why"
  sed 's/^/  | /' "$work/run.log" | tail -5
  fail=1
fi
while IFS= read -r line; do
  [[ "$line" == *"2>/dev/null'"* ]] && continue
  echo "check-display-pool-restart-prime: a reply count keeps the remote stderr: $line"
  fail=1
done < <(count_commands)
(( fail )) || echo "check-display-pool-restart-prime: a restarted stack's prime discards the old spare and makes a new one"
exit $fail
