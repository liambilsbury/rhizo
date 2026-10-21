#!/bin/bash
# test the adb bridge layer explanation
set -uo pipefail

SELFTEST=0
[[ "${1:-}" == "--selftest" ]] && SELFTEST=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$HERE/../vm/boot/adb-tunnel.sh"
[[ -r "$SRC" ]] || { echo "FAIL: cannot read $SRC"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

problems=()
# record a problem
note() { problems+=("$1"); }

# write a mutated copy of the script
mutate() {
  local name="$1"
  local out="$TMP/$name.sh"
  python3 - "$SRC" "$out" "$name" <<'PY'
import re, sys
src, out, name = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src).read()
if name == "no-explain":
    new, n = re.subn(
        r'\n  log "  adb connect said: \$\{connect_out:-<nothing>\}"\n'
        r'  explain_bridge \|\| true\n', '\n', s, count=1)
elif name == "silent-connect":
    new, n = re.subn(r'connect_out=\$\("\$ADB" connect "127\.0\.0\.1:\$EXT_PORT" 2>&1\)',
                     '"$ADB" connect "127.0.0.1:$EXT_PORT" >/dev/null 2>&1 || true\n'
                     'connect_out=""', s, count=1)
elif name == "old-lease-ok":
    new, n = re.subn(r'  if \[\[ "\$dnat" == "yes" && "\$dnat_ip" != "\$ip" \]\]; then\n'
                     r'(?:.*?\n)*?  fi\n', '', s, count=1)
elif name == "spare-counted":
    new, n = re.subn(r'rhizo_dl_claimed "\$1"', 'rhizo_dl_ids "$1"', s, count=1)
elif name == "host-probe":
    new, n = re.subn(r'\n  adbd=\$\(sed -n \047s/\^adbd=//p\047 <<<"\$facts"\)\n',
                     '\n  adbd=no; timeout 3 bash -c "</dev/tcp/127.0.0.1/$EXT_PORT" '
                     '2>/dev/null && adbd=yes\n', s, count=1)
else:
    sys.exit("unknown mutant " + name)
if n != 1:
    sys.exit("SELFTEST SETUP FAIL: mutant %s did not apply" % name)
open(out, "w").write(new)
PY
  [[ -s "$out" ]] || return 1
  echo "$out"
}

# run explain_bridge against fixture guest facts
run_explain() {
  local script="$1" facts="$2"
  printf '%s' "$facts" > "$TMP/facts"
  sed -n '/^explain_bridge() {/,/^}/p' "$script" > "$TMP/fn.sh"
  [[ -s "$TMP/fn.sh" ]] || { echo "EXTRACT-FAIL"; return 99; }
  bash -c '
    set -uo pipefail
    PORT=5555; EXT_PORT=5556; RHIZO_VM=1
    log() { echo "$*"; }
    bridge_facts() { cat "'"$TMP"'/facts"; }
    source "'"$TMP"'/fn.sh"
    explain_bridge
  ' 2>&1
}

FACTS_OK=$'init=1627\nip=192.168.100.50\ndnat=yes\ndnat_ip=192.168.100.50\nadbd=yes\n'
FACTS_NO_DNAT=$'init=1627\nip=192.168.100.50\ndnat=no\ndnat_ip=\nadbd=yes\n'
FACTS_NO_ADBD=$'init=1627\nip=192.168.100.50\ndnat=no\ndnat_ip=\nadbd=no\n'
FACTS_NO_LEASE=$'init=1627\nip=\ndnat=no\ndnat_ip=\nadbd=no\n'
FACTS_NO_INIT=$'init=\nip=\ndnat=no\ndnat_ip=\nadbd=no\n'
FACTS_NO_GUEST=''
FACTS_OLD_LEASE=$'init=1627\nip=192.168.100.51\ndnat=yes\ndnat_ip=192.168.100.50\nadbd=yes\n'

# check explain_bridge reports the expected layer
assert_layer() {
  local script="$1" facts="$2" want="$3" wantrc="$4"; shift 4
  local out rc
  out=$(run_explain "$script" "$facts"); rc=$?
  if ! grep -q "RHIZO_ADB_LAYER=$want" <<<"$out"; then
    note "layer '$want': got '$(grep -o 'RHIZO_ADB_LAYER=[a-z-]*' <<<"$out" | head -1)' -- $(head -1 <<<"$out")"
    return
  fi
  (( rc == wantrc )) || note "layer '$want': rc=$rc, wanted $wantrc"
  if (( wantrc != 0 )) && ! grep -q -- '->' <<<"$out"; then
    note "layer '$want': named the layer and gave no command to fix it"
  fi
  local want_text
  for want_text in "$@"; do
    grep -qi -- "$want_text" <<<"$out" || note "layer '$want': says nothing about '$want_text'"
  done
}

assert_layer "$SRC" "$FACTS_NO_GUEST"  guest   1 "explain-boot"
assert_layer "$SRC" "$FACTS_NO_INIT"   android 1 "boot-release"
assert_layer "$SRC" "$FACTS_NO_LEASE"  lease   1
assert_layer "$SRC" "$FACTS_NO_ADBD"   adbd    1 "adbd"
assert_layer "$SRC" "$FACTS_NO_DNAT"   dnat    1 "adb-tunnel.sh up" "hostfwd" "offline"
assert_layer "$SRC" "$FACTS_OLD_LEASE" old-lease 1 "adb-tunnel.sh up" "192.168.100.50"
assert_layer "$SRC" "$FACTS_OK"        none    0

out=$(run_explain "$SRC" "$FACTS_OK")
grep -q "RHIZO_ADB_LAYER=none" <<<"$out" || note "a fully-up bridge is not reported as up"
out=$(run_explain "$SRC" "$FACTS_NO_DNAT")
grep -q "RHIZO_ADB_LAYER=none" <<<"$out" && note "a missing DNAT rule is reported as a working bridge"
out=$(run_explain "$SRC" "$FACTS_OLD_LEASE")
grep -q "RHIZO_ADB_LAYER=none" <<<"$out" && note "a DNAT rule aimed at a dead lease is reported as a working bridge"

FN_FACTS=$(sed -n '/^bridge_facts() {/,/^}/p' "$SRC")
[[ -n "$FN_FACTS" ]] || note "bridge_facts() not found in adb-tunnel.sh"
grep -q 'ssh_vm' <<<"$FN_FACTS" || note "bridge_facts() does not ask the guest over ssh"
FN_EXPLAIN=$(sed -n '/^explain_bridge() {/,/^}/p' "$SRC")
grep -q 'dev/tcp/127\.0\.0\.1' <<<"$FN_EXPLAIN" \
  && note "explain_bridge() probes the host port"

SNIPPET=$(sed -n '/^INIT_PID_SNIPPET="/,/done"$/p' "$SRC")
[[ -n "$SNIPPET" ]] || note "INIT_PID_SNIPPET not found in adb-tunnel.sh"
SCAN=$(grep '^RHIZO_INIT_SCAN_BODY=' "$HERE/../vm/common.sh")
[[ -n "$SCAN" ]] || note "RHIZO_INIT_SCAN_BODY not found in common.sh"
printf '%s\n%s\n%s\n' "$SCAN" "$SNIPPET" "$FN_FACTS" > "$TMP/fn_facts.sh"
bash -c '
  set -uo pipefail
  PORT=5555
  ssh_vm() { while [[ $# -gt 1 ]]; do shift; done; printf "%s" "$1" > "'"$TMP"'/body"; }
  source "'"$TMP"'/fn_facts.sh"
  bridge_facts >/dev/null 2>&1
' >/dev/null 2>&1

if [[ ! -s "$TMP/body" ]]; then
  note "bridge_facts() sent no remote body to ssh_vm"
else
  bash -n "$TMP/body" 2>"$TMP/body.err" \
    || note "bridge_facts()'s remote shell body does not parse: $(head -1 "$TMP/body.err")"

  mkdir -p "$TMP/bin"
  for kind in stack standin; do
    mkdir -p "$TMP/proc-$kind/4242"
    printf '/system/bin/init\0second_stage\0' > "$TMP/proc-$kind/4242/cmdline"
  done
  printf '0::/rhizo/init\n' > "$TMP/proc-stack/4242/cgroup"
  printf '0::/user.slice/user-1000.slice/session-3.scope\n' > "$TMP/proc-standin/4242/cgroup"
  cat > "$TMP/bin/cat" <<'STUB'
#!/bin/bash
case "${1:-}" in
  /proc/*/comm) echo "${STUB_COMM:-init}" ;;
  /tmp/rhizo-adb-dnat-ip) [[ -n "${STUB_DNAT_IP:-}" ]] && echo "$STUB_DNAT_IP" || exit 1 ;;
  *) exec /bin/cat "$@" ;;
esac
STUB
  cat > "$TMP/bin/nsenter" <<'STUB'
#!/bin/bash
echo "2: eth0    inet ${STUB_SANDBOX_IP:-192.168.100.50}/24 brd 192.168.100.255 scope global eth0"
STUB
  cat > "$TMP/bin/iptables" <<'STUB'
#!/bin/bash
exit "${STUB_IPTABLES_RC:-0}"
STUB
  cat > "$TMP/bin/timeout" <<'STUB'
#!/bin/bash
exit "${STUB_ADBD_RC:-0}"
STUB
  chmod +x "$TMP/bin"/*

  want_fact() {
    local case_name="$1" key="$2" want="$3"; shift 3
    local got
    got=$(env PATH="$TMP/bin:$PATH" \
              RHIZO_PROC_ROOT="$TMP/proc-stack" STUB_COMM=init \
              STUB_DNAT_IP=192.168.100.50 STUB_SANDBOX_IP=192.168.100.50 \
              STUB_IPTABLES_RC=0 STUB_ADBD_RC=0 \
              "$@" bash "$TMP/body" 2>/dev/null | sed -n "s/^$key=//p")
    [[ "$got" == "$want" ]] || note "remote body, $case_name: $key='$got', wanted '$want'"
  }

  want_fact "everything up" init 4242
  want_fact "everything up" ip   192.168.100.50
  want_fact "everything up" dnat yes
  want_fact "everything up" adbd yes
  want_fact "no DNAT rule"        dnat no  STUB_IPTABLES_RC=1
  want_fact "adbd not listening"  adbd no  STUB_ADBD_RC=1
  want_fact "no recorded address" dnat no  STUB_DNAT_IP=
  want_fact "the candidate's comm is not init" init "" STUB_COMM=bash
  want_fact "only a stand-in outside the stack" init "" RHIZO_PROC_ROOT="$TMP/proc-standin"
fi

grep -vE '^[[:space:]]*#' "$SRC" > "$TMP/code.sh"
bare=$(grep -n 'pgrep -f' "$TMP/code.sh" || true)
[[ -z "$bare" ]] || note "a bare 'pgrep -f' survives: ${bare%%$'\n'*}"
[[ $(grep -c 'RHIZO_INIT_SCAN_BODY' "$TMP/code.sh") -eq 1 ]] \
  || note "'which pid is init' is asked in $(grep -c 'RHIZO_INIT_SCAN_BODY' "$TMP/code.sh") places; they will drift"

FAIL_BLOCK=$(sed -n '/wanted .device. or .unauthorized./,/^fi$/p' "$SRC")
grep -q 'connect_out' <<<"$FAIL_BLOCK" || note "the offline failure drops adb connect's own message"
grep -q 'explain_bridge' <<<"$FAIL_BLOCK" || note "the offline failure names no layer"
grep -q 'connect_out=\$("\$ADB" connect' "$SRC" || note "adb connect's output is not captured"

grep -q '"\$ADB" disconnect "127\.0\.0\.1:\$EXT_PORT"' "$SRC" \
  || note "the leftover offline transport is never disconnected before connecting"

STATUS_BLOCK=$(sed -n '/^if \[\[ "\$MODE" == "status" \]\]; then/,/^fi$/p' "$SRC")
[[ -n "$STATUS_BLOCK" ]] || note "adb-tunnel.sh has no status mode"
grep -q 'kill-server' <<<"$STATUS_BLOCK" && note "status mode kills the vm's adb server"
grep -qE '\$ADB" connect' <<<"$STATUS_BLOCK" && note "status mode answers with a connect, the one probe that cannot answer it"
grep -q 'explain_bridge' <<<"$STATUS_BLOCK" || note "status mode does not ask the guest"

# run extra_sandbox_displays on a display list reply
run_extra() {
  local script="$1"
  sed -n '/^extra_sandbox_displays() {/,/^}/p' "$script" > "$TMP/fn_extra.sh"
  [[ -s "$TMP/fn_extra.sh" ]] || { echo "EXTRACT-FAIL"; return 99; }
  bash -c '
    set -uo pipefail
    . "'"$HERE"'/../../src/androidd/host/parse-display-list.sh"
    source "'"$TMP"'/fn_extra.sh"
    extra_sandbox_displays "$1"
  ' x "$2" 2>&1
}
# check the extra display ids and return code
want_extra() {
  local out rc
  out=$(run_extra "$1" "$3"); rc=$?
  [[ "$(tr '\n' ' ' <<<"$out" | sed 's/ *$//')" == "$4" && "$rc" == "$5" ]] \
    || note "extra_sandbox_displays, $2: got '$out' rc=$rc, wanted '$4' rc=$5"
}
want_extra "$SRC" "the primary and a pooled spare" "display list 1(960x1080) 4(960x1080,pool)" "" 0
want_extra "$SRC" "a spare carrying presents" "display list 1(960x1080,p=40,v=1) 4(960x1080,pool,p=0,v=0)" "" 0
want_extra "$SRC" "a claimed app display beside the spare" "display list 1(960x1080) 2(960x1080,p=3,v=1) 4(960x1080,pool)" "2" 0
want_extra "$SRC" "two claimed app displays" "display list 1(960x1080) 2(960x1080) 3(960x1080)" "2 3" 0
want_extra "$SRC" "no reply from the composer" "" "" 1
LOOP=$(sed -n '/^deadline=\$(( \$(date +%s) + 20 ))$/,/^done$/p' "$SRC")
grep -q 'extra_sandbox_displays "$(rhizo_ctl_display_list "$INIT")"\|extra_sandbox_displays "$dlist"' <<<"$LOOP" \
  || note "the pre-tap wait does not decide on extra_sandbox_displays over the composer's own display list"

if (( SELFTEST )); then
  (( ${#problems[@]} == 0 )) || { printf 'FAIL (before selftest): %s\n' "${problems[@]}"; exit 1; }

  caught=0
  for m in no-explain silent-connect host-probe old-lease-ok spare-counted; do
    mut=$(mutate "$m") || { echo "FAIL: could not build mutant $m"; exit 1; }
    saved=("${problems[@]+"${problems[@]}"}")
    problems=()
    case "$m" in
      no-explain)
        FB=$(sed -n '/wanted .device. or .unauthorized./,/^fi$/p' "$mut")
        grep -q 'explain_bridge' <<<"$FB" || note "$m: caught"
        ;;
      silent-connect)
        grep -q 'connect_out=\$("\$ADB" connect' "$mut" || note "$m: caught"
        ;;
      host-probe)
        FD=$(sed -n '/^explain_bridge() {/,/^}/p' "$mut")
        grep -q 'dev/tcp/127\.0\.0\.1' <<<"$FD" && note "$m: caught"
        ;;
      old-lease-ok)
        MO=$(run_explain "$mut" "$FACTS_OLD_LEASE")
        grep -q "RHIZO_ADB_LAYER=none" <<<"$MO" && note "$m: caught"
        ;;
      spare-counted)
        want_extra "$mut" "$m" "display list 1(960x1080) 4(960x1080,pool)" "" 0
        ;;
    esac
    if (( ${#problems[@]} == 0 )); then
      echo "FAIL: selftest mutant '$m' was NOT caught"
      exit 1
    fi
    caught=$((caught + 1))
    problems=("${saved[@]+"${saved[@]}"}")
  done
  echo "PASS: adb bridge explanation names its layer ($caught mutants caught)"
  exit 0
fi

if (( ${#problems[@]} )); then
  printf 'FAIL: %s\n' "${problems[@]}"
  exit 1
fi
echo "PASS: adb-tunnel.sh names the layer behind an offline device, asked of the guest"
