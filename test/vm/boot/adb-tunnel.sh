#!/bin/bash
# manage the adb bridge from the host to the sandbox's adbd
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit
source ../common.sh
source ../../system/lib/sway-lib.sh

ADB=~/Android/Sdk/platform-tools/adb

MODE="${1:-}"
STOP=0
[[ "${2:-}" == "--stop" ]] && STOP=1
if [[ "$MODE" != "up" && "$MODE" != "status" && "$MODE" != "bridge-only" ]]; then
  echo "usage: $0 up [--stop] | $0 status | $0 bridge-only" >&2; exit 2
fi

PORT=5555
EXT_PORT="$ADB_PORT"
ALLOW_BTN_X=1306
ALLOW_BTN_Y=650
ALWAYS_ALLOW_X=589
ALWAYS_ALLOW_Y=567

# print the sandbox's eth0 IPv4 address
sandbox_eth0_ip() {
  local init_pid="$1"
  ssh_vm -t 10 "nsenter -t $init_pid -n -- ip -4 -o addr show eth0" 2>/dev/null \
    | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1
}

# probe the sandbox's adb port over TCP
probe_tcp() {
  local ip="$1"
  ssh_vm -t 5 "timeout 3 bash -c '</dev/tcp/$ip/$PORT' 2>/dev/null" >/dev/null 2>&1
}

INIT_PID_SNIPPET="init=''
    for p in \$($RHIZO_INIT_SCAN_BODY); do
      [ \"\$(cat /proc/\$p/comm 2>/dev/null)\" = init ] || continue
      [ \"\$(awk '/^NSpid:/{if (NF>=3 && \$NF!=1) print \"foreign\"}' /proc/\$p/status 2>/dev/null)\" = foreign ] && continue
      init=\$p; break
    done"

# print the guest's bridge state
bridge_facts() {
  ssh_vm -t 20 "$INIT_PID_SNIPPET
    ip=''
    [ -n \"\$init\" ] && ip=\$(nsenter -t \"\$init\" -n -- ip -4 -o addr show eth0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print \$2}' | head -1)
    dnat_ip=\$(cat /tmp/rhizo-adb-dnat-ip 2>/dev/null)
    dnat=no
    if [ -n \"\$dnat_ip\" ]; then
      if iptables -t nat -C PREROUTING -p tcp --dport $PORT -j DNAT --to-destination \"\$dnat_ip:$PORT\" 2>/dev/null &&
         iptables -t nat -C OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DNAT --to-destination \"\$dnat_ip:$PORT\" 2>/dev/null; then
        dnat=yes
      fi
    fi
    adbd=no
    if [ -n \"\$ip\" ]; then
      timeout 3 bash -c \"</dev/tcp/\$ip/$PORT\" 2>/dev/null && adbd=yes
    fi
    echo \"init=\$init\"
    echo \"ip=\$ip\"
    echo \"dnat=\$dnat\"
    echo \"dnat_ip=\$dnat_ip\"
    echo \"adbd=\$adbd\"" 2>/dev/null
}

# print the missing layer and the command that fixes it
explain_bridge() {
  local facts init ip dnat dnat_ip adbd
  facts=$(bridge_facts)
  init=$(sed -n 's/^init=//p' <<<"$facts")
  ip=$(sed -n 's/^ip=//p' <<<"$facts")
  dnat=$(sed -n 's/^dnat=//p' <<<"$facts")
  dnat_ip=$(sed -n 's/^dnat_ip=//p' <<<"$facts")
  adbd=$(sed -n 's/^adbd=//p' <<<"$facts")
  if [[ -z "$facts" ]]; then
    log "RHIZO_ADB_LAYER=guest -- the guest did not answer ssh"
    log "  -> explain the boot, not adb: RHIZO_VM=$RHIZO_VM test/vm/boot/explain-boot.sh"
    return 1
  fi
  if [[ -z "$init" ]]; then
    log "RHIZO_ADB_LAYER=android -- the guest answers and carries no 'init second_stage': Android is not running"
    log "  -> boot it: RHIZO_VM=$RHIZO_VM test/vm/boot-release.sh a16"
    return 1
  fi
  if [[ -z "$ip" ]]; then
    log "RHIZO_ADB_LAYER=lease -- init is pid $init and its eth0 carries no IPv4 lease"
    log "  -> rhizo-netbridged is the DHCP server"
    return 1
  fi
  if [[ "$adbd" != "yes" ]]; then
    log "RHIZO_ADB_LAYER=adbd -- $ip:$PORT does not accept from the VM root netns: adbd is not listening"
    log "  -> check it on the guest: getprop init.svc.adbd"
    return 1
  fi
  if [[ "$dnat" == "yes" && "$dnat_ip" != "$ip" ]]; then
    log "RHIZO_ADB_LAYER=old-lease -- the DNAT rule forwards $PORT to $dnat_ip and the sandbox now holds $ip"
    log "  the rule is present and forwards to nobody"
    log "  -> reinstall it against the current lease: RHIZO_VM=$RHIZO_VM test/vm/boot/adb-tunnel.sh up"
    return 1
  fi
  if [[ "$dnat" != "yes" ]]; then
    log "RHIZO_ADB_LAYER=dnat -- adbd is up at $ip:$PORT and the guest carries no DNAT rule to it${dnat_ip:+ (last recorded address was $dnat_ip)}"
    log "  127.0.0.1:$EXT_PORT still accepts: it is QEMU's hostfwd, not Android"
    log "  a bare 'adb connect' to it leaves an offline device"
    log "  -> bring the bridge up: RHIZO_VM=$RHIZO_VM test/vm/boot/adb-tunnel.sh up"
    return 1
  fi
  log "RHIZO_ADB_LAYER=none -- every guest-side hop is up (init=$init sandbox=$ip adbd=yes dnat=yes)"
  return 0
}

# remove the DNAT rules and the recorded address
stop_dnat() {
  ssh_vm -t 10 "iptables -t nat -D PREROUTING -p tcp --dport $PORT -j DNAT --to-destination \$(cat /tmp/rhizo-adb-dnat-ip 2>/dev/null):$PORT 2>/dev/null
    iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DNAT --to-destination \$(cat /tmp/rhizo-adb-dnat-ip 2>/dev/null):$PORT 2>/dev/null
    iptables -D FORWARD -p tcp -d \$(cat /tmp/rhizo-adb-dnat-ip 2>/dev/null) --dport $PORT -j ACCEPT 2>/dev/null
    rm -f /tmp/rhizo-adb-dnat-ip
    true" || true
  log "DNAT rules removed"
}

if (( STOP )); then
  stop_dnat
  exit 0
fi

if [[ "$MODE" == "status" ]]; then
  if explain_bridge; then
    log "ADB BRIDGE UP -- 127.0.0.1:$EXT_PORT reaches the sandbox's adbd"
    exit 0
  fi
  exit 1
fi

# install the DNAT bridge and return 1 on failure
install_adb_bridge() {
  INIT=$(ssh_vm -t 10 "$INIT_PID_SNIPPET
    echo \"\$init\"" 2>/dev/null | tr -d '[:space:]')
  [[ -n "$INIT" ]] || { log "FAIL: no init second_stage running -- boot the sandbox first"; return 1; }
  NET_WAIT="${RHIZO_NET_WAIT:-60}"
  IP=$(wait_for_nonempty "$NET_WAIT" sandbox_eth0_ip "$INIT")
  [[ -n "$IP" ]] || { log "FAIL: sandbox eth0 has no DHCP-leased address yet (waited ${NET_WAIT}s)"; return 1; }
  log "sandbox eth0 = $IP (init_pid=$INIT)"

  if ! probe_tcp "$IP"; then
    log "FAIL: $IP:$PORT not reachable from the VM root netns -- check: getprop init.svc.adbd"
    return 1
  fi
  log "adbd listener reachable at $IP:$PORT from the VM root netns"

  stop_dnat >/dev/null 2>&1
  ssh_vm -t 10 "set -e
    iptables -t nat -A PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $IP:$PORT
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 --dport $PORT -j DNAT --to-destination $IP:$PORT
    iptables -t nat -A POSTROUTING -p tcp -d $IP --dport $PORT -j MASQUERADE
    iptables -C FORWARD -p tcp -d $IP --dport $PORT -j ACCEPT 2>/dev/null \\
      || iptables -I FORWARD 1 -p tcp -d $IP --dport $PORT -j ACCEPT
    iptables -t nat -C PREROUTING -p tcp --dport $PORT -j DNAT --to-destination $IP:$PORT
    echo $IP > /tmp/rhizo-adb-dnat-ip
    echo DNAT_OK" >/dev/null || { log "FAIL: could not install DNAT rules"; return 1; }
  log "DNAT up: host 127.0.0.1:$EXT_PORT -> qemu hostfwd -> VM root netns 127.0.0.1:$PORT -> sandbox $IP:$PORT"
}

if [[ "$MODE" == "bridge-only" ]]; then
  install_adb_bridge || exit 1
  exit 0
fi

install_adb_bridge || exit 1

# print the claimed sandbox displays other than display 1
extra_sandbox_displays() {
  [[ "$1" == "display list"* ]] || return 1
  rhizo_dl_claimed "$1" | grep -vx 1
  return 0
}

# print the adb state of the host-mapped device
adb_state() { "$ADB" devices | awk -v want="127.0.0.1:$EXT_PORT" '$1==want{print $2}'; }

"$ADB" kill-server >/dev/null 2>&1 || true
"$ADB" disconnect "127.0.0.1:$EXT_PORT" >/dev/null 2>&1 || true
connect_out=$("$ADB" connect "127.0.0.1:$EXT_PORT" 2>&1)
state=""
deadline=$(( $(date +%s) + 20 ))
while (( $(date +%s) < deadline )); do
  state=$(adb_state)
  [[ -n "$state" ]] && break
  sleep 1
done
log "adb state after connect: '${state:-<none>}'"

if [[ "$state" == "device" ]]; then
  log "ADB BRIDGE UP -- 127.0.0.1:$EXT_PORT is device"
  exit 0
fi

if [[ "$state" != "unauthorized" ]]; then
  log "FAIL: unexpected adb state '${state:-<none>}' (wanted 'device' or 'unauthorized')"
  log "  adb connect said: ${connect_out:-<nothing>}"
  explain_bridge || true
  exit 1
fi

log "state=unauthorized -- clearing the real 'Allow USB debugging?' dialog"
android_sh "$INIT" "cmd battery set ac 1" >/dev/null
android_sh "$INIT" "settings put global stay_on_while_plugged_in 7" >/dev/null
android_sh "$INIT" "input keyevent 224" >/dev/null
android_sh "$INIT" "wm dismiss-keyguard" >/dev/null

deadline=$(( $(date +%s) + 20 ))
while true; do
  dlist=$(rhizo_ctl_display_list "$INIT" 2>/dev/null)
  if extra_ids=$(extra_sandbox_displays "$dlist"); then
    [[ -z "$extra_ids" ]] && break
  else
    extra_ids="<the composer never answered display list>"
  fi
  (( $(date +%s) >= deadline )) && { log "FAIL: extra display(s) still alive after 20s: $(echo "$extra_ids" | tr '\n' ' ') (composer: ${dlist:-<no reply>}; Android: $(android_sh "$INIT" "dumpsys display | grep -oE \"mDisplayId=[0-9]+\"" 2>/dev/null | sort -u | tr '\n' ' '))"; exit 1; }
  while read -r cid; do
    [[ -n "$cid" ]] && gcmd_user "swaymsg '[con_id=$cid] kill'" >/dev/null 2>&1
  done < <(gcmd_user "swaymsg -t get_tree | python3 -c \"
import json,sys
def walk(n):
    for c in n.get('nodes',[])+n.get('floating_nodes',[]):
        if c.get('pid'):
            app = c.get('app_id') or ''
            name = c.get('name') or ''
            if app != 'rhizo' or name.startswith('Rhizo display'):  # toplevel-literal-ok
                print(c['id'])
        walk(c)
walk(json.load(sys.stdin))\"" 2>/dev/null)
  sleep 2
done
log "confirmed no sandbox display but the primary is claimed (spares: $(rhizo_dl_spares "$dlist" | tr '\n' ' '))"

android_sh "$INIT" "am start -n com.android.systemui/com.android.systemui.usb.UsbDebuggingActivity" >/dev/null

inject_start || { log "FAIL: could not start the virtual pointer"; exit 1; }

EV_DIR="$REPO/var/measurements/certified-pair$SUFFIX"
mkdir -p "$EV_DIR"
shot /tmp/rhizo-adb-auth-dialog.png >/dev/null 2>&1
pull /tmp/rhizo-adb-auth-dialog.png "$EV_DIR/adb-auth-dialog.png" >/dev/null 2>&1
region_stat=$(python3 ../../system/tools/pngstat.py "$EV_DIR/adb-auth-dialog.png" --region 580,420,780,260 2>/dev/null)
nonblack=$(echo "$region_stat" | grep '^nonblack_pct=' | cut -d= -f2)
if ! awk -v v="${nonblack:-0}" 'BEGIN{exit !(v>50)}'; then
  log "FAIL: the confirmation dialog is not showing (region ${nonblack:-0}% nonblack) -- see $EV_DIR/adb-auth-dialog.png"
  exit 1
fi
log "confirmation dialog confirmed on screen (region ${nonblack}% nonblack) -- checking 'always allow'"

CHECKBOX_REGION="578,554,24,24"
shot /tmp/rhizo-adb-checkbox-pre.png >/dev/null 2>&1
pull /tmp/rhizo-adb-checkbox-pre.png "$EV_DIR/adb-checkbox-pre.png" >/dev/null 2>&1
checked=0
cb_attempt=0
cb_deadline=$(( $(date +%s) + 20 ))
while (( $(date +%s) < cb_deadline )); do
  cb_attempt=$((cb_attempt+1))
  (( cb_attempt > 1 && (cb_attempt - 1) % 3 == 0 )) && inject_start
  inject_click "$ALWAYS_ALLOW_X" "$ALWAYS_ALLOW_Y" 1920 1080
  sleep 1
  shot /tmp/rhizo-adb-checkbox-post.png >/dev/null 2>&1
  pull /tmp/rhizo-adb-checkbox-post.png "$EV_DIR/adb-checkbox-post.png" >/dev/null 2>&1
  diff_stat=$(python3 ../../system/tools/pngstat.py --diff "$EV_DIR/adb-checkbox-pre.png" "$EV_DIR/adb-checkbox-post.png" --region "$CHECKBOX_REGION" 2>/dev/null)
  changed_pct=$(echo "$diff_stat" | grep '^changed_pct=' | cut -d= -f2)
  if awk -v v="${changed_pct:-0}" 'BEGIN{exit !(v>15)}'; then
    checked=1
    log "  checkbox attempt $cb_attempt: confirmed toggled (${changed_pct}% of glyph region changed)"
    break
  fi
  log "  checkbox attempt $cb_attempt: no visible change (${changed_pct:-0}%), retrying"
done
(( checked )) || { log "FAIL: 'Always allow' checkbox never visibly toggled after $cb_attempt tap attempts -- see $EV_DIR/adb-checkbox-pre.png / adb-checkbox-post.png"; exit 1; }
log "tapping ALLOW"

state=""
attempt=0
deadline=$(( $(date +%s) + 30 ))
while (( $(date +%s) < deadline )); do
  attempt=$((attempt+1))
  (( attempt > 1 && (attempt - 1) % 3 == 0 )) && inject_start
  inject_click "$ALLOW_BTN_X" "$ALLOW_BTN_Y" 1920 1080
  sleep 2
  state=$(adb_state)
  [[ "$state" == "device" ]] && break
  log "  tap attempt $attempt: state='$state', retrying"
done
[[ "$state" == "device" ]] || { log "FAIL: still '$state' after $attempt tap attempts"; exit 1; }
log "ADB BRIDGE UP -- 127.0.0.1:$EXT_PORT is device (after clearing the auth dialog, $attempt tap attempt(s))"
