#!/bin/bash

# check the assert_* library
lc_need_assert_lib() {
  declare -F assert_present >/dev/null 2>&1 && return 0
  fail "claim $1: no assert_* library in scope (assert_present undefined -- server-assert-lib.sh not sourced)"
  return 1
}

# run pgrep -x on the guest
lc_procs_named() { ssh_vm -t "${2:-15}" "pgrep -a -x '$1' 2>/dev/null"; }

# write a sentinel to the guest kmsg
lc_dmesg_sentinel() {
  local tag="LC_SENTINEL_$$_${EPOCHREALTIME//[!0-9]/}" seen
  ssh_vm -t 10 "echo '$tag' > /dev/kmsg" >/dev/null 2>&1
  seen=$(ssh_vm -t 10 "dmesg | awk -v s='$tag' '\$NF==s'" 2>/dev/null)
  [[ -n "$seen" ]] || return 1
  printf '%s' "$tag"
}
# grep dmesg past a sentinel
lc_dmesg_since() {
  local sentinel="$1" pattern="$2"
  [[ -n "$sentinel" ]] || return 1
  ssh_vm -t 20 "dmesg | awk -v s='$sentinel' 'f{print} \$NF==s{f=1}' | grep -aF '$pattern'" 2>/dev/null
}
LC_AUDIT_DROPPED='printk limit exceeded|audit_lost=|(kauditd_printk_skb|audit_log_lost|audit_panic): [0-9]+ callbacks suppressed'
# print the dmesg lines between two markers
lc_dmesg_window() {
  local s="$1" e="$2" win
  [[ -n "$s" && -n "$e" ]] || return 1
  win=$(ssh_vm -t 20 "dmesg | awk -v s='$s' -v e='$e' '\$NF==e{if(f)print \"LC_WINDOW_END\"; exit} f{print} \$NF==s{f=1; print \"LC_WINDOW_START\"}'; echo DONE" 2>/dev/null)
  lc_done_strip win || return 1
  [[ "$win" == LC_WINDOW_START$'\n'* && "$win" == *$'\n'LC_WINDOW_END ]] || return 1
  win=${win#LC_WINDOW_START$'\n'}
  win=${win%LC_WINDOW_END}
  grep -qaE "$LC_AUDIT_DROPPED" <<<"$win" && return 1
  printf '%s' "$win"
}

# print allows and scope of a capability
lc_read_capability() {
  ssh_vm -t 20 "PYTHONPATH=/usr/lib/rhizo/tools python3 -c \"import sys,capabilities as rc; p=rc.policy_or_deny(log=lambda m: None); print(p.allows(sys.argv[1]), p.scope(sys.argv[1]))\" '$1'" 2>/dev/null
}

LC_POLICY_RESTORE_PENDING=0
LC_POLICY_RESTORE_CONTENT=""
LC_POLICY_TRAP_INSTALLED=""

# restore policy.conf from the saved content
lc_policy_restore_on_exit() {
  (( LC_POLICY_RESTORE_PENDING )) || return 0
  LC_POLICY_RESTORE_PENDING=0
  declare -F ssh_vm >/dev/null 2>&1 || return 0
  if [[ -z "$LC_POLICY_RESTORE_CONTENT" ]]; then
    ssh_vm -t 15 'rm -f /etc/rhizo/policy.conf' >/dev/null 2>&1
  else
    local b64; b64=$(printf '%s\n' "$LC_POLICY_RESTORE_CONTENT" | base64 -w0)
    ssh_vm -t 15 "printf '%s' '$b64' | base64 -d > /etc/rhizo/policy.conf" >/dev/null 2>&1
  fi
}
# arm the policy.conf restore at exit
lc_arm_policy_restore() {
  LC_POLICY_RESTORE_CONTENT="$1"
  LC_POLICY_RESTORE_PENDING=1
  [[ -n "$LC_POLICY_TRAP_INSTALLED" ]] && return 0
  LC_POLICY_TRAP_INSTALLED=1
  local existing; existing=$(trap -p EXIT)
  existing="${existing#trap -- \'}"; existing="${existing%\' EXIT}"
  # shellcheck disable=SC2064
  # shellcheck disable=SC2154
  trap "lc_exit_rc=\$?; lc_policy_restore_on_exit; (exit \$lc_exit_rc);${existing:+ $existing}" EXIT
}
# clear the pending policy.conf restore
lc_disarm_policy_restore() { LC_POLICY_RESTORE_PENDING=0; }

# read policy.conf from the guest
lc_save_policy_conf() {
  if ! declare -F probe_ssh >/dev/null 2>&1 || ! declare -F probe_ssh_result >/dev/null 2>&1; then
    fail "lc_save_policy_conf: probe_ssh/probe_ssh_result not sourced (server-assert-lib.sh missing)"
    return 1
  fi
  local raw out
  raw=$(probe_ssh 15 'if [ -f /etc/rhizo/policy.conf ]; then cat /etc/rhizo/policy.conf; else printf "%s" LC_POLICY_ABSENT_MARKER; fi')
  out=$(probe_ssh_result "$raw") || return 1
  [[ "$out" == "LC_POLICY_ABSENT_MARKER" ]] && out=""
  printf '%s' "$out"
  return 0
}
# restore policy.conf from the saved content
lc_restore_policy_conf() {
  local content="$1" b64 want_sha got got_raw complete
  if ! declare -F probe_ssh >/dev/null 2>&1 || ! declare -F probe_ssh_result >/dev/null 2>&1; then
    fail "lc_restore_policy_conf: probe_ssh/probe_ssh_result not sourced (server-assert-lib.sh missing)"
    return 1
  fi
  if [[ -z "$content" ]]; then
    ssh_vm -t 15 'rm -f /etc/rhizo/policy.conf' >/dev/null 2>&1
    got_raw=$(probe_ssh 15 'test -f /etc/rhizo/policy.conf && echo PRESENT || echo ABSENT')
    got=$(probe_ssh_result "$got_raw"); complete=$?
    if (( complete != 0 )); then
      fail "lc_restore_policy_conf: the remote probe confirming policy.conf is gone never completed"
      return 1
    fi
    if [[ "$got" != ABSENT ]]; then
      fail "lc_restore_policy_conf: removed policy.conf, but a read-back still finds it present ($got)"
      return 1
    fi
    lc_disarm_policy_restore
    return 0
  fi
  want_sha=$(printf '%s\n' "$content" | sha256sum | cut -d' ' -f1)
  b64=$(printf '%s\n' "$content" | base64 -w0)
  ssh_vm -t 15 "printf '%s' '$b64' | base64 -d > /etc/rhizo/policy.conf" >/dev/null 2>&1
  got_raw=$(probe_ssh 15 'sha256sum /etc/rhizo/policy.conf 2>/dev/null | cut -d" " -f1')
  got=$(probe_ssh_result "$got_raw"); complete=$?
  if (( complete != 0 )); then
    fail "lc_restore_policy_conf: the remote sha256sum read-back never completed after restoring policy.conf"
    return 1
  fi
  if [[ -z "$got" || "$got" != "$want_sha" ]]; then
    fail "lc_restore_policy_conf: policy.conf's restored sha256 ('${got:-<empty>}') does not match the saved content's own sha256 ($want_sha)"
    return 1
  fi
  lc_disarm_policy_restore
  return 0
}

# wait for the pool to reach a member count
lc_wait_pool_members() {
  local want="$1" members="" deadline=$((SECONDS + 180)) status_out
  while (( SECONDS < deadline )); do
    status_out=$(lc_rhizo 20 pool status 2>&1)
    if [[ -z "${status_out//[[:space:]]/}" ]]; then
      printf ''
      return 1
    fi
    members=$(sed -n 's/.*members=\([0-9]\+\).*/\1/p' <<<"$status_out")
    [[ "$members" == "$want" ]] && break
    sleep 5
  done
  printf '%s' "$members"
  [[ "$members" == "$want" ]]
}

LC_INSTANCE_ADD_ID=""
LC_INSTANCE_ADD_ENV=""
LC_INSTANCE_ADD_DATA=""
LC_INSTANCE_ALLOC_ID=""
LC_INSTANCE_ALLOC_ADB=""

# shellcheck disable=SC2034
LC_TEST_ADB_DEBS=/var/lib/test-adb-debs
LC_GUEST_ADB_HOME=/tmp/lc-guest-adb
LC_GUEST_ADB="env HOME=$LC_GUEST_ADB_HOME ANDROID_ADB_SERVER_PORT=5039 ADB_LOCAL_TRANSPORT_MAX_PORT=5554 adb"

# stage the operator adb key on the guest
lc_guest_adb_ready() {
  local label="$1" key="${EV:-}/cli-adbkey/adbkey" blob b64 b64pub out
  if [[ ! -s "$key" || ! -s "$key.pub" ]]; then
    fail "$label: no operator key at $key"
    return 1
  fi
  blob=$(awk '{print $1; exit}' "$key.pub")
  [[ "$blob" == QAAA* ]] || { fail "$label: $key.pub holds no adb public key"; return 1; }
  b64=$(base64 -w0 < "$key"); b64pub=$(base64 -w0 < "$key.pub")
  out=$(ssh_vm -t 30 "command -v adb >/dev/null 2>&1 || { echo NO_ADB; exit 0; }
grep -qF '$blob' /etc/rhizo/adb_keys 2>/dev/null || { echo NOT_REGISTERED; exit 0; }
mkdir -p $LC_GUEST_ADB_HOME/.android && chmod 700 $LC_GUEST_ADB_HOME/.android
printf '%s' '$b64' | base64 -d > $LC_GUEST_ADB_HOME/.android/adbkey
printf '%s' '$b64pub' | base64 -d > $LC_GUEST_ADB_HOME/.android/adbkey.pub
chmod 600 $LC_GUEST_ADB_HOME/.android/adbkey
$LC_GUEST_ADB kill-server >/dev/null 2>&1
echo READY" 2>/dev/null)
  case "$out" in
    *READY) return 0 ;;
    *NO_ADB*) fail "$label: the guest has no adb client -- step 0 stages Ubuntu's from the vm pool tools/fetch/pools/deb/fetch.sh adb-debs fetches (vm-dir:adb-debs)" ;;
    *NOT_REGISTERED*) fail "$label: the operator key cli.adb-key minted ($key.pub) is not in the guest's /etc/rhizo/adb_keys" ;;
    *) fail "$label: staging the operator key for the guest's adb client answered '${out:-nothing}'" ;;
  esac
  return 1
}

# print the guest adb state for a serial
lc_guest_adb_state() {
  ssh_vm -t 60 "$LC_GUEST_ADB disconnect $1 >/dev/null 2>&1; $LC_GUEST_ADB connect $1 >/dev/null 2>&1; timeout 20 $LC_GUEST_ADB -s $1 wait-for-device >/dev/null 2>&1; $LC_GUEST_ADB -s $1 get-state 2>&1" 2>/dev/null \
    | tr -d '\r' | tr '\n' ' ' | sed 's/ *$//'
}

# check that the sandbox network device is up with network.enabled at its default
lc_assert_capability.network-enabled() {
  lc_need_guest capability.network-enabled || return 1
  ssh_vm -t 20 'ip addr show veth-rhizo0 2>/dev/null || ip addr show 2>/dev/null | grep -q 192.168.100.1' \
    && pass "capability.network-enabled: the sandbox's network device is up by default" \
    || { fail "capability.network-enabled: no sandbox network device found with network.enabled at its default"; return 1; }
}

# print the sandbox resolver list
lc_sandbox_dns() {
  local out rc id
  out=$(android_sh "$1" 'dumpsys connectivity'); rc=$?
  (( rc == 0 )) || return 1
  out=$(tr -d '\r' <<<"$out")
  id=$(sed -n 's/^ *Active default network: \([0-9][0-9]*\) *$/\1/p' <<<"$out" | head -1)
  [[ -n "$id" ]] || return 1
  out=$(awk -v nai="NetworkAgentInfo{network{$id}" 'index($0, "NetworkAgentInfo{network{") { on = (index($0, nai) > 0) } on' <<<"$out")
  out=$(grep -oE '(^| )DnsAddresses: \[ [^]]* \]' <<<"$out" | head -1)
  [[ -n "$out" ]] || return 1
  out=${out#" "}
  out=${out#"DnsAddresses: [ "}
  printf '%s' "${out%" ]"}"
}

# compare a resolver list to an address
lc_dns_lists() { [[ "$1" == "/$2" ]]; }

# check network services from inside the sandbox
lc_assert_capability.network-services() {
  lc_need_guest capability.network-services || return 1
  local init; init=$(lc_resolve_init 60)
  [[ -n "$init" ]] || { fail "capability.network-services: no sandbox init to probe from"; return 1; }
  local leased dns tcp_out nb_out
  leased=$(android_sh "$init" 'ip -4 -o addr show scope global' | grep -oE '192\.168\.100\.[0-9]+' | head -1)
  dns=$(lc_sandbox_dns "$init") || dns=""
  local nb_read nb_mark
  nb_read=$(ssh_vm -t 15 'wc -l < /tmp/rhizo-netbridged.log && echo LC_NB_MARK_DONE' 2>/dev/null | tr -d '\r')
  nb_mark=${nb_read%%$'\n'*}
  nb_mark=${nb_mark//[[:space:]]/}
  if [[ "${nb_read##*$'\n'}" != LC_NB_MARK_DONE || ! "$nb_mark" =~ ^[0-9]+$ ]]; then
    fail "capability.network-services: the count of rhizo-netbridged's log lines (/tmp/rhizo-netbridged.log) before the probe never completed: ${nb_read:-<no output>}"
    return 1
  fi
  tcp_out=$(android_sh "$init" 'nc -4 -z -w 10 dns.google 443 2>&1; echo "NC_RC=$?"' 2>&1)
  nb_out=$(ssh_vm -t 15 "tail -n +$((nb_mark + 1)) /tmp/rhizo-netbridged.log | grep -iE 'NB_DNS_(QUERY|FORWARD) qname=dns\.google '; echo LC_NB_LOG_DONE" 2>/dev/null)
  if [[ -z "$leased" ]]; then
    fail "capability.network-services: no 192.168.100.0/24 address is assigned on the sandbox"
    return 1
  fi
  if ! lc_dns_lists "$dns" 192.168.100.1; then
    fail "capability.network-services: the active default network's resolvers (dumpsys connectivity DnsAddresses) are '${dns:-<unread>}', wanted exactly /192.168.100.1"
    return 1
  fi
  if [[ "$tcp_out" != *NC_RC=* ]]; then
    fail "capability.network-services: the TCP probe inside the sandbox never completed ('nc -4 -z -w 10 dns.google 443'): ${tcp_out:-<no output>}"
    return 1
  fi
  if [[ "$nb_out" != *LC_NB_LOG_DONE* ]]; then
    fail "capability.network-services: the read of rhizo-netbridged's own log (/tmp/rhizo-netbridged.log) never completed"
    return 1
  fi
  if ! grep -iE 'NB_DNS_QUERY qname=dns\.google ' <<<"$nb_out" | grep -qF " src=$leased:"; then
    fail "capability.network-services: the host's forwarder at 192.168.100.1 logged no query for dns.google from the sandbox's lease $leased after the probe began: $(tr '\n' ' ' <<<"$nb_out")"
    return 1
  fi
  if ! grep -qiE 'NB_DNS_FORWARD qname=dns\.google .*rcode=0 ' <<<"$nb_out"; then
    fail "capability.network-services: the host's forwarder took a query for dns.google but logged no NOERROR upstream answer: $(tr '\n' ' ' <<<"$nb_out")"
    return 1
  fi
  if ! grep -qx 'NC_RC=0' <<<"$tcp_out"; then
    fail "capability.network-services: no TCP connection to dns.google:443 completed from inside the sandbox through 192.168.100.1: $(tr '\n' ' ' <<<"$tcp_out")"
    return 1
  fi
  pass "capability.network-services: the sandbox holds a DHCP lease ($leased), Android's resolvers are [$dns], the forwarder at 192.168.100.1 logged dns.google's query and its NOERROR upstream answer, and a TCP connection to dns.google:443 completed from inside the sandbox"
}

# test desktop notifications through the session bus
lc_assert_capability.desktop-notifications() {
  lc_need_guest capability.desktop-notifications || return 1
  local on; on=$(lc_read_capability desktop.notifications)
  [[ "$on" == True* ]] \
    || { fail "capability.desktop-notifications: at its default, policy_or_deny().allows('desktop.notifications') reads '${on:-<empty>}', wanted True ..."; return 1; }
  lc_unit_active rhizo-deskd.service \
    || { fail "capability.desktop-notifications: rhizo-deskd.service is not active with the capability on"; return 1; }
  local deskd_pid deskd_user
  deskd_pid=$(ssh_vm -t 10 'systemctl show -p MainPID --value rhizo-deskd.service' | tr -d '[:space:]')
  if [[ ! "$deskd_pid" =~ ^[1-9][0-9]*$ ]]; then
    fail "capability.desktop-notifications: rhizo-deskd.service's MainPID read '${deskd_pid:-<empty>}', no process to look for a live bus client in"
    return 1
  fi
  deskd_user=$(ssh_vm -t 10 'systemctl show -p User --value rhizo-deskd.service' | tr -d '[:space:]')
  [[ -n "$deskd_user" ]] || deskd_user=root
  local bus_conn; bus_conn=$(ssh_vm -t 15 "runuser -u '$deskd_user' -- ss -xp 2>/dev/null | grep ESTAB | grep 'pid=$deskd_pid,'")
  if [[ -z "${bus_conn//[[:space:]]/}" ]]; then
    fail "capability.desktop-notifications: rhizo-deskd.service (pid $deskd_pid, user $deskd_user) holds no ESTABLISHED unix socket"
    return 1
  fi
  local off_offset; off_offset=$(ssh_vm -t 15 'stat -c%s /var/log/rhizo/rhizo-deskd.log' | tr -d '[:space:]')
  if [[ ! "$off_offset" =~ ^[0-9]+$ ]]; then
    fail "capability.desktop-notifications: could not read rhizo-deskd.log's size to take the withheld leg's lines from (got '${off_offset:-<empty>}')"
    return 1
  fi
  local prior; prior=$(lc_save_policy_conf) \
    || { fail "capability.desktop-notifications: could not read /etc/rhizo/policy.conf before editing it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  ssh_vm -t 15 "printf '[desktop]\nnotifications = off\n' > /etc/rhizo/policy.conf" >/dev/null 2>&1
  local off_why=""
  if ! off_why=$(_lc_desktop_bridge_restart); then off_why="${off_why:-no reason given}"; fi
  local log_off; log_off=$(ssh_vm -t 15 "tail -c +$((off_offset + 1)) /var/log/rhizo/rhizo-deskd.log 2>/dev/null")
  local off; off=$(lc_read_capability desktop.notifications)
  lc_restore_policy_conf "$prior" || fail "capability.desktop-notifications: restore failed"
  local restore_why=""
  if ! restore_why=$(_lc_desktop_bridge_restart); then restore_why="${restore_why:-no reason given}"; fi
  local restored; restored=$(ssh_vm -t 10 'systemctl is-active rhizo-deskd.service 2>/dev/null' | tr -d '[:space:]')
  if [[ "$off" != False* ]]; then
    fail "capability.desktop-notifications: withheld, policy_or_deny().allows('desktop.notifications') still reads '${off:-<empty>}', wanted False ..."
    return 1
  fi
  if [[ -n "$off_why" ]]; then
    fail "capability.desktop-notifications: withheld, the bridge did not come back up over the restarted deskd: $off_why"
    return 1
  fi
  if ! grep -qF 'desktop.notifications is off: the session bus is not attached' <<<"$log_off"; then
    fail "capability.desktop-notifications: withheld, rhizo-deskd.log (past byte offset $off_offset) never logged the bus-not-attached line: ${log_off:-<empty>}"
    return 1
  fi
  if [[ -n "$restore_why" ]]; then
    fail "capability.desktop-notifications: restored, the bridge did not come back up over the restarted deskd: $restore_why"
    return 1
  fi
  [[ "$restored" == active ]] \
    && pass "capability.desktop-notifications: on, rhizo-deskd.service (pid $deskd_pid) holds a live ESTABLISHED bus connection; withheld, it logs 'the session bus is not attached' and policy_or_deny() reads False; restored, active again" \
    || { fail "capability.desktop-notifications: restored, rhizo-deskd.service did not become active again (is-active=${restored:-<empty>})"; return 1; }
}

# test the drag capability of rhizo-wlbridge
lc_assert_capability.desktop-drag() {
  lc_need_guest capability.desktop-drag || return 1
  local on; on=$(lc_read_capability desktop.drag)
  [[ "$on" == True* ]] \
    || { fail "capability.desktop-drag: at its default, policy_or_deny().allows('desktop.drag') reads '${on:-<empty>}', wanted True ..."; return 1; }
  lc_unit_active rhizo-deskd.service \
    || { fail "capability.desktop-drag: rhizo-deskd.service is not active with the capability on"; return 1; }
  local argv_on; argv_on=$(lc_procs_named rhizo-wlbridge)
  if [[ -z "${argv_on//[[:space:]]/}" ]] || ! grep -q -- '--caps' <<<"$argv_on"; then
    fail "capability.desktop-drag: could not read rhizo-wlbridge's own --caps argv with the capability on: '${argv_on:-<empty>}'"
    return 1
  fi
  local prior; prior=$(lc_save_policy_conf) \
    || { fail "capability.desktop-drag: could not read /etc/rhizo/policy.conf before editing it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  ssh_vm -t 15 "printf '[desktop]\ndrag = off\n' > /etc/rhizo/policy.conf" >/dev/null 2>&1
  local off_why=""
  if ! off_why=$(_lc_desktop_bridge_restart); then off_why="${off_why:-no reason given}"; fi
  local argv_off; argv_off=$(lc_procs_named rhizo-wlbridge)
  local off; off=$(lc_read_capability desktop.drag)
  lc_restore_policy_conf "$prior" || fail "capability.desktop-drag: restore failed"
  local restore_why=""
  if ! restore_why=$(_lc_desktop_bridge_restart); then restore_why="${restore_why:-no reason given}"; fi
  local restored; restored=$(ssh_vm -t 10 'systemctl is-active rhizo-deskd.service 2>/dev/null' | tr -d '[:space:]')
  if [[ "$off" != False* ]]; then
    fail "capability.desktop-drag: withheld, policy_or_deny().allows('desktop.drag') still reads '${off:-<empty>}', wanted False ..."
    return 1
  fi
  if [[ -n "$off_why" ]]; then
    fail "capability.desktop-drag: withheld, the bridge did not come back up over the restarted deskd: $off_why"
    return 1
  fi
  if ! grep -q -- '--caps' <<<"$argv_off"; then
    fail "capability.desktop-drag: withheld, no live rhizo-wlbridge --caps argv to read after the restart: '${argv_off:-<empty>}'"
    return 1
  fi
  if grep -q 'drag' <<<"$argv_off"; then
    fail "capability.desktop-drag: withheld, rhizo-wlbridge's own --caps argv still names drag: ${argv_off:-<empty>}"
    return 1
  fi
  if [[ -n "$restore_why" ]]; then
    fail "capability.desktop-drag: restored, the bridge did not come back up over the restarted deskd: $restore_why"
    return 1
  fi
  [[ "$restored" == active ]] \
    && pass "capability.desktop-drag: on, rhizo-wlbridge's own argv names drag ($argv_on); withheld, it does not ($argv_off) and policy_or_deny() reads False; restored, active again" \
    || { fail "capability.desktop-drag: restored, rhizo-deskd.service did not become active again (is-active=${restored:-<empty>})"; return 1; }
}

# wait for a string in rhizo-deskd.log
_lc_deskd_log_await() {
  local off="$1" want="$2" deadline=$(( $(date +%s) + $3 )) out=""
  while (( $(date +%s) < deadline )); do
    out=$(ssh_vm -t 15 "tail -c +$((off + 1)) /var/log/rhizo/rhizo-deskd.log 2>/dev/null")
    grep -qF -- "$want" <<<"$out" && { printf '%s\n' "$out"; return 0; }
    sleep 1
  done
  printf '%s\n' "$out"
  return 1
}

# print the xdg-open result line for a uri
_lc_deskd_open_outcome() {
  local off="$1" uri="$2" deadline=$(( $(date +%s) + $3 )) out line
  while (( $(date +%s) < deadline )); do
    out=$(ssh_vm -t 15 "tail -c +$((off + 1)) /var/log/rhizo/rhizo-deskd.log 2>/dev/null")
    line=$(grep -F -e "xdg-open opened $uri" -e "xdg-open failed for $uri:" <<<"$out" | head -1)
    [[ -n "$line" ]] && { printf '%s\n' "$line"; return 0; }
    sleep 1
  done
  return 1
}

# print the RHIZO_LINK_FAILED line for a uri
_lc_android_link_failed() {
  local uri="$1" deadline=$(( $(date +%s) + $2 )) line
  while (( $(date +%s) < deadline )); do
    line=$(android_sh "$INIT" "logcat -d -b all -s rhizo-desk:I" 2>/dev/null | grep -aF "RHIZO_LINK_FAILED uri=$uri " | tail -1)
    [[ -n "$line" ]] && { printf '%s\n' "$line"; return 0; }
    sleep 2
  done
  return 1
}

# test desktop open-uri through xdg-open
lc_assert_capability.desktop-open-uri() {
  lc_need_guest capability.desktop-open-uri || return 1
  local on; on=$(lc_read_capability desktop.open_uri)
  [[ "$on" == True* ]] \
    || { fail "capability.desktop-open-uri: at its default, policy_or_deny().allows('desktop.open_uri') reads '${on:-<empty>}', wanted True ..."; return 1; }
  lc_unit_active rhizo-deskd.service \
    || { fail "capability.desktop-open-uri: rhizo-deskd.service is not active with the capability on"; return 1; }
  [[ -n "$INIT" ]] || { fail "capability.desktop-open-uri: no live sandbox init to send a real open request from"; return 1; }
  local why
  why=$(_lc_desktop_bridge_current 120) \
    || { fail "capability.desktop-open-uri: the bridge was not up to send the on leg over: $why"; return 1; }
  local uri_on="https://example.com/lc-open-uri-on-$$"
  local off_on; off_on=$(ssh_vm -t 15 'stat -c%s /var/log/rhizo/rhizo-deskd.log' | tr -d '[:space:]')
  if [[ ! "$off_on" =~ ^[0-9]+$ ]]; then
    fail "capability.desktop-open-uri: could not read rhizo-deskd.log's size to take the on leg's lines from (got '${off_on:-<empty>}')"
    return 1
  fi
  android_sh "$INIT" "am start -a android.intent.action.VIEW -d '$uri_on' com.rhizo.desktop/.LinkActivity" >/dev/null 2>&1
  local log_on outcome_on="" running_on=""
  log_on=$(_lc_deskd_log_await "$off_on" "$uri_on" 30)
  if grep -qF "open android -> host: $uri_on" <<<"$log_on" && ! outcome_on=$(_lc_deskd_open_outcome "$off_on" "$uri_on" 30); then
    running_on=$(lc_procs_named xdg-open 10 | grep -F -- "$uri_on")
    local xpid handler=""
    xpid=$(awk 'NR==1{print $1}' <<<"$running_on")
    [[ "$xpid" =~ ^[0-9]+$ ]] \
      && handler=$(ssh_vm -t 10 "pgrep -l -P $xpid" 2>/dev/null | grep -vE '^[0-9]+ (xdg-open|xdg-mime|xdg-settings|gio|gdbus|dbus-send)$')
    if [[ -n "$handler" ]]; then running_on+=" (handler $(tr '\n' ' ' <<<"$handler" | sed 's/ $//'))"; else running_on=""; fi
  fi

  local prior; prior=$(lc_save_policy_conf) \
    || { fail "capability.desktop-open-uri: could not read /etc/rhizo/policy.conf before editing it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  ssh_vm -t 15 "printf '[desktop]\nopen_uri = \n' > /etc/rhizo/policy.conf" >/dev/null 2>&1
  local off_why=""
  if ! off_why=$(_lc_desktop_bridge_restart); then off_why="${off_why:-no reason given}"; fi
  local off; off=$(lc_read_capability desktop.open_uri)
  local active_off; active_off=$(ssh_vm -t 10 'systemctl is-active rhizo-deskd.service 2>/dev/null' | tr -d '[:space:]')

  local uri_off="https://example.com/lc-open-uri-off-$$"
  local off_off; off_off=$(ssh_vm -t 15 'stat -c%s /var/log/rhizo/rhizo-deskd.log' | tr -d '[:space:]')
  local log_off="" xdg_off told_off=""
  if [[ -z "$off_why" && "$off_off" =~ ^[0-9]+$ ]]; then
    android_sh "$INIT" "am start -a android.intent.action.VIEW -d '$uri_off' com.rhizo.desktop/.LinkActivity" >/dev/null 2>&1
    log_off=$(_lc_deskd_log_await "$off_off" "$uri_off" 30)
    grep -F -- "$uri_off" <<<"$log_off" | grep -qF 'is not in the allowlist' \
      && told_off=$(_lc_android_link_failed "$uri_off" 30)
  fi
  xdg_off=$(lc_procs_named xdg-open 10 | grep -F -- "$uri_off")

  lc_restore_policy_conf "$prior" || fail "capability.desktop-open-uri: restore failed"
  local restore_why=""
  if ! restore_why=$(_lc_desktop_bridge_restart); then restore_why="${restore_why:-no reason given}"; fi
  local restored; restored=$(ssh_vm -t 10 'systemctl is-active rhizo-deskd.service 2>/dev/null' | tr -d '[:space:]')

  local ok=1
  if ! grep -qF "open android -> host: $uri_on" <<<"$log_on"; then
    fail "capability.desktop-open-uri: on, rhizo-deskd.log (past byte offset $off_on) never logged dispatching $uri_on within 30s: ${log_on:-<empty>}"
    ok=0
  fi
  if grep -qF 'is not in the allowlist' <<<"$log_on"; then
    fail "capability.desktop-open-uri: on, deskd refused $uri_on: $log_on"
    ok=0
  fi
  if [[ "$outcome_on" == *"xdg-open failed for"* ]]; then
    fail "capability.desktop-open-uri: on, deskd's xdg-open did not open $uri_on: $outcome_on"
    ok=0
  elif grep -qF "open android -> host: $uri_on" <<<"$log_on" && [[ -z "$outcome_on" && -z "${running_on//[[:space:]]/}" ]]; then
    fail "capability.desktop-open-uri: on, deskd logged no outcome for its xdg-open of $uri_on within 30s and no xdg-open carrying it runs a handler"
    ok=0
  fi
  if [[ "$off" != False* ]]; then
    fail "capability.desktop-open-uri: withheld (empty scheme set), policy_or_deny().allows('desktop.open_uri') still reads '${off:-<empty>}', wanted False ..."
    ok=0
  fi
  if [[ -n "$off_why" ]]; then
    fail "capability.desktop-open-uri: withheld, the bridge did not come back up over the restarted deskd: $off_why"
    ok=0
  fi
  if [[ "$active_off" != active ]]; then
    fail "capability.desktop-open-uri: withheld, rhizo-deskd.service did not stay active (is-active=${active_off:-<empty>})"
    ok=0
  fi
  if [[ ! "$off_off" =~ ^[0-9]+$ ]]; then
    fail "capability.desktop-open-uri: withheld, could not read rhizo-deskd.log's size to take the withheld leg's lines from (got '${off_off:-<empty>}')"
    ok=0
  elif ! grep -F -- "$uri_off" <<<"$log_off" | grep -qF 'is not in the allowlist'; then
    fail "capability.desktop-open-uri: withheld, rhizo-deskd.log (past byte offset $off_off) never logged refusing $uri_off: ${log_off:-<empty>}"
    ok=0
  fi
  if grep -F -- "$uri_off" <<<"$log_off" | grep -qF 'is not in the allowlist' && [[ -z "$told_off" ]]; then
    fail "capability.desktop-open-uri: withheld, deskd refused $uri_off but Android never logged RHIZO_LINK_FAILED for it within 30s"
    ok=0
  fi
  if grep -qF "open android -> host: $uri_off" <<<"$log_off"; then
    fail "capability.desktop-open-uri: withheld, deskd dispatched $uri_off anyway: $log_off"
    ok=0
  fi
  if [[ -n "${xdg_off//[[:space:]]/}" ]]; then
    fail "capability.desktop-open-uri: withheld, an xdg-open child was found after the VIEW intent for $uri_off: $xdg_off"
    ok=0
  fi
  if [[ -n "$restore_why" ]]; then
    fail "capability.desktop-open-uri: restored, the bridge did not come back up over the restarted deskd: $restore_why"
    ok=0
  fi
  if [[ "$restored" != active ]]; then
    fail "capability.desktop-open-uri: restored, rhizo-deskd.service did not become active again (is-active=${restored:-<empty>})"
    ok=0
  fi
  (( ok )) \
    && pass "capability.desktop-open-uri: on, a real VIEW intent for $uri_on was exec'd through xdg-open (deskd's dispatch line) and opened (${outcome_on:-xdg-open still holding its handler: $running_on}) with no refusal logged; withheld, the same request for $uri_off is refused by name (logged, no xdg-open carrying it, daemon stays up) and Android told of it ($told_off); restored, active again with the android app authenticated"
  (( ok ))
}

# check that audiod and its socket are up by default and gone with audio out off
lc_assert_capability.audio-out() {
  lc_need_guest capability.audio-out || return 1
  local daemon_on sock_on
  daemon_on=$(ssh_vm -t 10 'pgrep -x rhizo-audiod >/dev/null 2>&1 && echo UP || echo DOWN' | tr -d '[:space:]')
  sock_on=$(ssh_vm -t 10 'test -S /run/rhizo-audio/audiod && echo UP || echo DOWN' | tr -d '[:space:]')
  if [[ "$daemon_on" != UP || "$sock_on" != UP ]]; then
    fail "capability.audio-out: at its default, rhizo-audiod.service gives daemon=${daemon_on:-<empty>} socket=${sock_on:-<empty>}, wanted both UP"
    return 1
  fi
  local prior; prior=$(lc_save_policy_conf) \
    || { fail "capability.audio-out: could not read /etc/rhizo/policy.conf before editing it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  ssh_vm -t 15 "printf '[audio]\nout = no\n' > /etc/rhizo/policy.conf" >/dev/null 2>&1
  ssh_vm -t 10 'systemctl stop rhizo-audiod.service 2>/dev/null; systemctl reset-failed rhizo-audiod.service 2>/dev/null; systemctl start rhizo-audiod.service' >/dev/null 2>&1
  local cond active_off daemon_off sock_off
  cond=$(ssh_vm -t 10 'systemctl show -p ConditionResult --value rhizo-audiod.service 2>/dev/null' | tr -d '[:space:]')
  active_off=$(ssh_vm -t 10 'systemctl is-active rhizo-audiod.service 2>/dev/null' | tr -d '[:space:]')
  daemon_off=$(ssh_vm -t 10 'pgrep -x rhizo-audiod >/dev/null 2>&1 && echo UP || echo DOWN' | tr -d '[:space:]')
  sock_off=$(ssh_vm -t 10 'test -S /run/rhizo-audio/audiod && echo UP || echo DOWN' | tr -d '[:space:]')
  lc_restore_policy_conf "$prior" || fail "capability.audio-out: restore failed"
  ssh_vm -t 10 'systemctl reset-failed rhizo-audiod.service 2>/dev/null; systemctl start rhizo-audiod.service' >/dev/null 2>&1
  local restored; restored=$(ssh_vm -t 10 'systemctl is-active rhizo-audiod.service 2>/dev/null' | tr -d '[:space:]')
  if [[ "$cond" != no || "$active_off" == active || "$daemon_off" != DOWN || "$sock_off" != DOWN ]]; then
    fail "capability.audio-out: withheld via policy.conf, rhizo-audiod.service's own ExecCondition=capability-allowed.sh did not skip it (ConditionResult=${cond:-<empty>} is-active=${active_off:-<empty>} daemon=${daemon_off:-<empty>} socket=${sock_off:-<empty>})"
    return 1
  fi
  [[ "$restored" == active ]] \
    && pass "capability.audio-out: on (default) gives a live daemon and socket; withheld via policy.conf, rhizo-audiod.service's own ExecCondition= skips it (ConditionResult=no), no daemon, no socket; restored, active again" \
    || { fail "capability.audio-out: restored, rhizo-audiod.service did not become active again (is-active=${restored:-<empty>})"; return 1; }
}

# check that no compositor process runs on the server-profile host
lc_assert_server.no-compositor() {
  lc_need_guest server.no-compositor || return 1
  lc_need_assert_lib server.no-compositor || return 1
  local raw out complete
  raw=$(probe_ssh 20 'pgrep -x sway 2>/dev/null; pgrep -x weston 2>/dev/null; pgrep -x gnome-shell 2>/dev/null')
  out=$(probe_ssh_result "$raw"); complete=$?
  assert_no_compositor_process "server.no-compositor: no compositor process on this server-profile host" "$out" "$(( complete == 0 ))"
}

# check adb reaches the sandbox endpoint
lc_assert_server.adb-reach-host() {
  lc_need_guest server.adb-reach-host || return 1
  lc_need_assert_lib server.adb-reach-host || return 1
  local endpoint; endpoint=$(adb_endpoint_now)
  if [[ -z "$endpoint" ]]; then
    fail "server.adb-reach-host: rhizo status --json reports no adb endpoint to connect to"
    return 1
  fi
  lc_guest_adb_ready server.adb-reach-host || return 1
  local state; state=$(lc_guest_adb_state "$endpoint")
  assert_adb_state "server.adb-reach-host: adb reaches the sandbox at its own endpoint $endpoint" "$state" device
}

# print the adb state through the hostfwd port
lc_rig_adb_state() {
  local target="127.0.0.1:${1:-}" adb="${RHIZO_ADB:-$HOME/Android/Sdk/platform-tools/adb}" key="${EV:-}/cli-adbkey/adbkey" state
  [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "<no hostfwd port for this vm's guest :5555 (ADB_PORT='${1:-}')>"; return 1; }
  if [[ ! "${ANDROID_ADB_SERVER_PORT:-}" =~ ^[0-9]+$ || "$ANDROID_ADB_SERVER_PORT" == 5037 ]]; then
    echo "<no per-vm adb server port (ANDROID_ADB_SERVER_PORT='${ANDROID_ADB_SERVER_PORT:-}'), refusing the host's own 5037>"
    return 1
  fi
  [[ -x "$adb" && -s "$key" ]] || { echo "<no rig adb at $adb or no operator key at $key>"; return 1; }
  "$adb" kill-server >/dev/null 2>&1
  ADB_VENDOR_KEYS="$key" "$adb" disconnect "$target" >/dev/null 2>&1
  ADB_VENDOR_KEYS="$key" timeout 20 "$adb" connect "$target" >/dev/null 2>&1
  ADB_VENDOR_KEYS="$key" timeout 20 "$adb" -s "$target" wait-for-device >/dev/null 2>&1
  state=$(ADB_VENDOR_KEYS="$key" timeout 10 "$adb" -s "$target" get-state 2>&1 | tr -d '\r' | tr '\n' ' ' | sed 's/ *$//')
  "$adb" disconnect "$target" >/dev/null 2>&1
  "$adb" kill-server >/dev/null 2>&1
  printf '%s' "$state"
}

# check adb reach over the LAN
lc_assert_server.adb-reach-lan() {
  lc_need_guest server.adb-reach-lan || return 1
  lc_need_assert_lib server.adb-reach-lan || return 1
  local uplink; uplink=$(ssh_vm -t 10 "ip -4 route show default | awk '{print \$5; exit}'" | tr -d '[:space:]')
  if [[ -z "$uplink" ]]; then
    fail "server.adb-reach-lan: no default route on the guest"
    return 1
  fi
  local prior; prior=$(lc_save_policy_conf) \
    || { fail "server.adb-reach-lan: could not read /etc/rhizo/policy.conf before editing it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  ssh_vm -t 15 "printf '[rhizo]\nprofile = server\n[server]\nadb_reach = lan\n' > /etc/rhizo/policy.conf" >/dev/null 2>&1
  local sentinel; sentinel=$(lc_dmesg_sentinel)
  if ! lc_sandbox_up "server.adb-reach-lan: the adb_reach=lan start"; then
    lc_restore_policy_conf "$prior" || fail "server.adb-reach-lan: restore failed"
    lc_sandbox_up "server.adb-reach-lan: the restore start"
    return 1
  fi
  local armed="" nat sandbox_ip tcp_rc rig_state
  [[ -n "$sentinel" ]] && armed=$(lc_dmesg_since "$sentinel" 'server.adb_reach=lan')
  nat=$(ssh_vm -t 15 'iptables -t nat -S PREROUTING 2>/dev/null')
  sandbox_ip=$(android_sh "$INIT" "ip -4 -o addr show eth0" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
  tcp_rc=97
  [[ -n "$sandbox_ip" ]] && tcp_rc=$(veth_probe_rc "$sandbox_ip")
  rig_state=$(lc_rig_adb_state "${ADB_PORT:-}")
  lc_restore_policy_conf "$prior" || fail "server.adb-reach-lan: restore failed"
  lc_sandbox_up "server.adb-reach-lan: the restore start"
  local ok=1 foreign
  foreign=$(grep -E -- '--dport 5555 .*-j DNAT' <<<"$nat" | grep -vF -- "-i $uplink ")
  if [[ -n "$foreign" ]]; then
    fail "server.adb-reach-lan: a :5555 DNAT rule not bound to the uplink $uplink is also present ($(tr '\n' ' ' <<<"$foreign"))"
    ok=0
  fi
  if [[ -z "$sentinel" ]]; then
    fail "server.adb-reach-lan: could not place a dmesg sentinel before the lan start"
    ok=0
  else
    assert_lan_armed_marker "server.adb-reach-lan: the launcher's own account of the lan start" "$armed" || ok=0
  fi
  assert_dnat_present "server.adb-reach-lan: a DNAT rule for the adb port on the guest's own uplink $uplink" "$nat" "$uplink" || ok=0
  if [[ -z "$sandbox_ip" ]]; then
    fail "server.adb-reach-lan: the sandbox (init ${INIT:-<none>}) reported no eth0 address to probe adbd at"
    ok=0
  else
    assert_tcp_reachable "server.adb-reach-lan: adbd answers at the sandbox's own $sandbox_ip" "$tcp_rc" || ok=0
  fi
  assert_adb_state "server.adb-reach-lan: an off-host adb client reaches the sandbox through the uplink's DNAT'd :5555 (rig 127.0.0.1:${ADB_PORT:-<none>} -> guest $uplink:5555)" "$rig_state" device || ok=0
  (( ok ))
}

# test the idle stop of androidd
lc_assert_server.idle-stop() {
  lc_need_guest server.idle-stop || return 1
  lc_need_assert_lib server.idle-stop || return 1
  local prior; prior=$(lc_save_policy_conf) \
    || { fail "server.idle-stop: could not read /etc/rhizo/policy.conf before editing it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  ssh_vm -t 15 "printf '[rhizo]\nprofile = server\n[server]\nidle_stop_s = 60\n' > /etc/rhizo/policy.conf" >/dev/null 2>&1
  local since; since=$(ssh_vm -t 10 'date +%s' | tr -d '[:space:]')
  ssh_vm -t 30 'systemctl restart rhizo-server-idle.service' >/dev/null 2>&1
  # shellcheck disable=SC2034
  local IDLE_UNIT=rhizo-server-idle.service child="" inodes="" netlink="" subscribed=0 sub_deadline=$((SECONDS + 30))
  while (( SECONDS < sub_deadline )); do
    child=$(idle_detector_pid)
    inodes=$(idle_detector_sock_inodes "$child")
    netlink=$(idle_netlink)
    detector_subscribed "$netlink" "$inodes" && { subscribed=1; break; }
    sleep 1
  done
  local endpoint; endpoint=$(adb_endpoint_now)
  local session_opened=0 session_state="" disconnected_at=""
  if [[ -n "$endpoint" ]] && (( subscribed )) && lc_guest_adb_ready server.idle-stop; then
    session_state=$(lc_guest_adb_state "$endpoint")
    ssh_vm -t 15 "$LC_GUEST_ADB disconnect $endpoint" >/dev/null 2>&1
    disconnected_at=$(ssh_vm -t 10 'date +%s' 2>/dev/null | tr -d '[:space:]')
    session_opened=1
  fi
  local androidd_state="" deadline=$((SECONDS + 180)) wait_end="deadline"
  (( session_opened )) || { deadline=$SECONDS; wait_end="no-session"; }
  while (( SECONDS < deadline )); do
    androidd_state=$(ssh_vm -t 10 'systemctl is-active androidd.service 2>/dev/null' | tr -d '[:space:]')
    [[ -z "$androidd_state" ]] && { wait_end="empty-read"; break; }
    [[ "$androidd_state" == inactive ]] && { wait_end="inactive"; break; }
    sleep 5
  done
  [[ -n "$androidd_state" ]] || androidd_state=$(ssh_vm -t 10 'systemctl is-active androidd.service 2>/dev/null' | tr -d '[:space:]')
  local now; now=$(ssh_vm -t 10 'date +%s' | tr -d '[:space:]')
  local journal; journal=$(ssh_vm -t 15 "journalctl -u rhizo-server-idle.service --since @$since --no-pager -o cat" 2>/dev/null)
  ssh_vm -t 15 "journalctl -u rhizo-server-idle.service --since @$since --no-pager -o short-unix" \
    >"$EV/server-idle-stop-detector.log" 2>&1
  [[ -s "$EV/server-idle-stop-detector.log" ]] || echo "<none: no detector journal since @$since>" >"$EV/server-idle-stop-detector.log"
  ssh_vm -t 20 "journalctl --since @$since --no-pager -o short-unix _PID=1 2>/dev/null | grep -E 'rhizo-server-idle|androidd|rhizo-inputd'; systemctl list-timers --all --no-pager 2>/dev/null | grep -F rhizo-server-idle-stop" \
    >"$EV/server-idle-stop-pid1.log" 2>&1 || true
  [[ -s "$EV/server-idle-stop-pid1.log" ]] || echo "<none: PID 1's journal since @$since named no idle, androidd or inputd unit>" >"$EV/server-idle-stop-pid1.log"
  {
    echo "since=$since disconnected_at=${disconnected_at:-<none>} wait_end=$wait_end now=${now:-<none>} androidd_state=${androidd_state:-<empty>} session_state=${session_state:-<none>} endpoint=${endpoint:-<none>}"
    ssh_vm -t 15 "for t in established close_wait time_wait close; do printf 'nf_conntrack_tcp_timeout_%s=%s\n' \$t \"\$(cat /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_\$t 2>/dev/null)\"; done; conntrack -L -p tcp --reply-src '${endpoint%:*}' --reply-port-src 5555 2>&1; ss -tanp 2>/dev/null | grep -F ':5555'" 2>&1 \
      || echo "<none: the conntrack/ss read did not complete>"
  } >"$EV/server-idle-stop-timeline.log"
  local raw stop_line complete
  raw=$(probe_ssh 15 "journalctl -u rhizo-server-idle-stop.service --since @$since --no-pager -o short-unix 2>/dev/null | grep -F ' systemd[1]: Started rhizo-server-idle-stop.service'")
  stop_line=$(probe_ssh_result "$raw"); complete=$?
  local stop_ts_epoch=""
  (( complete == 0 )) && stop_ts_epoch=$(awk 'NR == 1 { split($1, t, "."); if (t[1] ~ /^[0-9]+$/) print t[1] }' <<<"$stop_line")
  lc_restore_policy_conf "$prior" || fail "server.idle-stop: restore failed"
  ssh_vm -t 30 'systemctl restart rhizo-server-idle.service' >/dev/null 2>&1
  lc_sandbox_up "server.idle-stop: the start that brings the sandbox back for the claims after this one"

  local ok=1
  if (( subscribed == 0 )); then
    fail "server.idle-stop: within 30s of its restart the idle detector (${child:-<none>}) held no joined NETLINK_NETFILTER socket among its own inodes (${inodes:-<none>})"
    ok=0
  elif [[ -z "$endpoint" ]]; then
    fail "server.idle-stop: rhizo status --json reported no adb endpoint"
    ok=0
  elif (( session_opened == 0 )); then
    fail "server.idle-stop: no adb session to $endpoint could be opened from the guest's own client"
    ok=0
  elif [[ "$session_state" != device ]]; then
    fail "server.idle-stop: the session to $endpoint settled on '${session_state:-<nothing>}', not device"
    ok=0
  fi
  if ! grep -qF 'armed a 60s idle-stop timer' <<<"$journal"; then
    fail "server.idle-stop: rhizo-server-idle.service's own journal since \$since=$since never logged 'armed a 60s idle-stop timer': ${journal:-<empty>}"
    ok=0
  fi
  if [[ -z "$now" || -z "$since" ]] || (( now - since < 60 )); then
    fail "server.idle-stop: only $(( now - since )) second(s) elapsed between arming idle_stop_s=60 and observing the stop, wanted at least 60"
    ok=0
  fi
  if (( complete != 0 )); then
    fail "server.idle-stop: the remote read of rhizo-server-idle-stop.service's own journal never completed"
    ok=0
  elif [[ -z "$stop_ts_epoch" || -z "$since" ]] || (( stop_ts_epoch < since )); then
    fail "server.idle-stop: PID 1's journal start of rhizo-server-idle-stop.service ('${stop_line:-<none>}' -> ${stop_ts_epoch:-<none>}) is not after this cycle's own \$since=$since"
    ok=0
  fi
  assert_androidd_state "server.idle-stop: androidd.service after idle_stop_s=60s with no client left" "$androidd_state" inactive || ok=0
  (( ok == 1 ))
}

# test the start triggers of androidd.service
lc_assert_server.explicit-start-only() {
  lc_need_guest server.explicit-start-only || return 1
  lc_need_assert_lib server.explicit-start-only || return 1
  local raw out complete
  raw=$(probe_ssh 15 'systemctl show -p TriggeredBy,WantedBy --value androidd.service 2>/dev/null')
  out=$(probe_ssh_result "$raw"); complete=$?
  if (( complete != 0 )); then
    fail "server.explicit-start-only: the remote systemctl show probe never completed"
    return 1
  fi
  if [[ -n "${out//[[:space:]]/}" ]]; then
    fail "server.explicit-start-only: androidd.service carries TriggeredBy/WantedBy=$out"
    return 1
  fi
  local rev bad
  raw=$(probe_ssh 20 'for u in $(systemctl show -p RequiredBy,BoundBy,UpheldBy,OnSuccessOf,OnFailureOf --value androidd.service 2>/dev/null); do echo "REV $u $(systemctl show -p WantedBy,RequiredBy,BoundBy,UpheldBy,TriggeredBy,OnSuccessOf,OnFailureOf --value "$u" 2>/dev/null | tr "\n" " ")"; done')
  rev=$(probe_ssh_result "$raw"); complete=$?
  if (( complete != 0 )); then
    fail "server.explicit-start-only: the remote read of the units that require androidd.service never completed"
    return 1
  fi
  bad=$(awk '$1 == "REV" { for (i = 3; i <= NF; i++) if ($i != "androidd.service") print $2 " is started by " $i }' <<<"$rev")
  if [[ -n "$bad" ]]; then
    fail "server.explicit-start-only: $(tr '\n' ';' <<<"$bad")"
    return 1
  fi
  local endpoint; endpoint=$(adb_endpoint_now)
  ssh_vm -t 60 'systemctl stop androidd.service' >/dev/null 2>&1
  local state1; state1=$(ssh_vm -t 15 'systemctl is-active androidd.service 2>/dev/null' | tr -d '[:space:]')
  local ep_ip="${endpoint%%:*}"
  ssh_vm -t 10 "timeout 3 bash -c '</dev/tcp/${ep_ip:-127.0.0.1}/5555' 2>/dev/null" >/dev/null 2>&1
  local state2; state2=$(ssh_vm -t 15 'systemctl is-active androidd.service 2>/dev/null' | tr -d '[:space:]')
  if ! lc_sandbox_up "server.explicit-start-only: the start that brings the sandbox back for the claims after this one"; then
    fail "server.explicit-start-only: androidd.service did not come back up for the claims after this one"
    return 1
  fi
  if [[ "$state1" != inactive || "$state2" != inactive ]]; then
    fail "server.explicit-start-only: androidd.service read '$state1' after a plain stop and '$state2' after a connect attempt, wanted inactive both times"
    return 1
  fi
  pass "server.explicit-start-only: androidd.service carries no TriggeredBy/WantedBy (out='${out:-<empty>}'), only androidd starts what requires it ($(tr '\n' ' ' <<<"${rev:-<none>}")), and it stayed inactive through a stop and a connect attempt"
}

LC_SNAP0_KEY="" LC_SNAP0_PATH=""
# take a snapshot of instance 0 and wait for it to boot
lc_snapshot0() {
  local label="$1" name="$2" t0 out rc
  LC_SNAP0_KEY="" LC_SNAP0_PATH=""
  t0=$(guest_uptime)
  if [[ ! "$t0" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    fail "$label: the guest's uptime before the snapshot read '${t0:-<nothing>}', not a number"
    return 1
  fi
  out=$(lc_rhizo 600 snapshot -i 0 "$name" 2>&1); rc=$?
  if grep -q 'stopping androidd.service' <<<"$out"; then
    INIT=""
    wait_sandbox_started 420 "$t0" && INIT=$(resolve_init_pid 60)
    if [[ -z "$INIT" ]]; then
      fail "$label: instance 0 did not reach boot_completed again after the snapshot restarted it"
      return 1
    fi
  fi
  LC_SNAP0_KEY=$(sed -n "s/^RHIZO_SNAPSHOT name=$name key=\([0-9a-f]\{12\}\) path=.*/\1/p" <<<"$out" | tail -1)
  LC_SNAP0_PATH=$(sed -n "s/^RHIZO_SNAPSHOT name=$name key=[0-9a-f]\{12\} path=\(.*\)\$/\1/p" <<<"$out" | tail -1)
  if (( rc != 0 )) || [[ -z "$LC_SNAP0_KEY" || -z "$LC_SNAP0_PATH" ]]; then
    fail "$label: rhizo snapshot -i 0 $name exited $rc with no RHIZO_SNAPSHOT name=$name key= path= line: $out"
    return 1
  fi
}

# check rhizo instance add copies the template
lc_assert_server.instance-add() {
  lc_need_guest server.instance-add || return 1
  lc_need_assert_lib server.instance-add || return 1
  local tmpl="lc-add-tmpl-$$"
  lc_snapshot0 server.instance-add "$tmpl" || return 1
  local key="$LC_SNAP0_KEY" tpath="$LC_SNAP0_PATH"
  local out rc; out=$(lc_rhizo 600 instance add 90 --from "$tmpl" 2>&1); rc=$?
  local id env data from
  id=$(sed -n 's/^RHIZO_INSTANCE_ADDED id=\([0-9]\+\).*/\1/p' <<<"$out" | head -1)
  env=$(sed -n 's/^RHIZO_INSTANCE_ADDED .*env=\([^ ]*\).*/\1/p' <<<"$out" | head -1)
  data=$(sed -n 's/^RHIZO_INSTANCE_ADDED .*data=\([^ ]*\).*/\1/p' <<<"$out" | head -1)
  from=$(sed -n 's/^RHIZO_INSTANCE_ADDED .*from=\([^ ]*\).*/\1/p' <<<"$out" | head -1)
  if (( rc != 0 )) || [[ "$id" != 90 || -z "$env" || -z "$data" || "$from" != "$tmpl" ]]; then
    fail "server.instance-add: rhizo instance add 90 --from $tmpl exited $rc with no full RHIZO_INSTANCE_ADDED id=90 ... from=$tmpl line: $out"
    ssh_vm -t 30 "rm -f '$tpath' '$tpath.meta'" >/dev/null 2>&1
    return 1
  fi
  local raw facts complete
  raw=$(probe_ssh 300 "grep -qx 'RHIZO_SANDBOX_ID=90' '$env' 2>/dev/null && echo ENV_OK; stat -c 'DATA %i %h' '$data' 2>/dev/null; stat -c 'TMPL %i' '$tpath' 2>/dev/null; echo \"SHA \$(sha256sum '$data' 2>/dev/null | cut -c1-12)\"")
  facts=$(probe_ssh_result "$raw"); complete=$?
  ssh_vm -t 30 "rm -f '$tpath' '$tpath.meta'" >/dev/null 2>&1
  local d_ino d_links t_ino sha why=()
  read -r _ d_ino d_links <<<"$(grep -m1 '^DATA ' <<<"$facts")"
  read -r _ t_ino <<<"$(grep -m1 '^TMPL ' <<<"$facts")"
  sha=$(sed -n 's/^SHA //p' <<<"$facts" | head -1)
  if (( complete != 0 )); then
    fail "server.instance-add: the read of instance 90's env and data.img never completed"
    return 1
  fi
  grep -qx ENV_OK <<<"$facts" || why+=("$env does not carry RHIZO_SANDBOX_ID=90")
  [[ -n "$d_ino" ]] || why+=("no data.img at $data")
  [[ -n "$t_ino" ]] || why+=("no template at $tpath to compare against")
  [[ -n "$d_ino" && -n "$t_ino" && "$d_ino" == "$t_ino" ]] && why+=("$data is the template's own inode $t_ino, not a copy")
  [[ -z "$d_links" || "$d_links" == 1 ]] || why+=("$data has $d_links links")
  [[ -n "$d_ino" && "$sha" != "$key" ]] && why+=("$data hashes to ${sha:-<nothing>}, not the template's key $key")
  if (( ${#why[@]} )); then
    fail "server.instance-add: instance 90 cloned from $tmpl, but $(printf '%s; ' "${why[@]}")"
    return 1
  fi
  LC_INSTANCE_ADD_ID="$id"; LC_INSTANCE_ADD_ENV="$env"; LC_INSTANCE_ADD_DATA="$data"
  pass "server.instance-add: instance 90 was cloned from $tmpl: $env names it, and $data is its own copy (inode $d_ino, one link, not the template's $t_ino) of the template's bytes (sha256 $sha...)"
}

LC_POOL_BOOT_T=480

# check rhizo instance allocate returns an instance
lc_assert_server.instance-allocate() {
  lc_need_guest server.instance-allocate || return 1
  lc_rhizo "$LC_POOL_BOOT_T" pool set 1 >/dev/null 2>&1
  local members; members=$(lc_wait_pool_members 1)
  if [[ "$members" != 1 ]]; then
    fail "server.instance-allocate: rhizo pool set 1 never reached one ready member to allocate (members=${members:-<empty>})"
    lc_rhizo 60 pool set 0 >/dev/null 2>&1
    return 1
  fi
  local out rc; out=$(lc_rhizo 90 instance allocate 2>&1); rc=$?
  local id adb
  id=$(sed -n 's/^RHIZO_ALLOCATED id=\([0-9]\+\).*/\1/p' <<<"$out" | head -1)
  adb=$(sed -n 's/.*adb=\([^ ]*\).*/\1/p' <<<"$out" | head -1)
  if (( rc != 0 )) || [[ -z "$id" || -z "$adb" ]]; then
    fail "server.instance-allocate: rhizo instance allocate exited $rc with no full RHIZO_ALLOCATED line: $out"
    lc_rhizo 60 pool set 0 >/dev/null 2>&1
    return 1
  fi
  LC_INSTANCE_ALLOC_ID="$id"; LC_INSTANCE_ALLOC_ADB="$adb"
  lc_guest_adb_ready server.instance-allocate || return 1
  local state; state=$(lc_guest_adb_state "$adb")
  [[ "$state" == device ]] \
    && pass "server.instance-allocate: instance $id was unfrozen; its own adb endpoint $adb reads get-state=device" \
    || { fail "server.instance-allocate: instance $id's adb endpoint $adb reads get-state='${state:-<empty>}', wanted device"; return 1; }
}

# check rhizo instance release frees the instance
lc_assert_server.instance-release() {
  lc_need_guest server.instance-release || return 1
  lc_need_assert_lib server.instance-release || return 1
  if [[ -z "$LC_INSTANCE_ALLOC_ID" ]]; then
    fail "server.instance-release: no instance was allocated by server.instance-allocate this cycle"
    return 1
  fi
  local out rc; out=$(lc_rhizo "$LC_POOL_BOOT_T" instance release "$LC_INSTANCE_ALLOC_ID" 2>&1); rc=$?
  if (( rc != 0 )) || ! grep -qE "^RHIZO_RELEASED id=$LC_INSTANCE_ALLOC_ID\$" <<<"$out"; then
    fail "server.instance-release: rhizo instance release $LC_INSTANCE_ALLOC_ID exited $rc with no matching RHIZO_RELEASED line: $out"
    lc_rhizo 60 pool set 0 >/dev/null 2>&1
    return 1
  fi
  local raw state complete
  raw=$(probe_ssh 30 "$LC_GUEST_ADB -s $LC_INSTANCE_ALLOC_ADB get-state 2>&1")
  state=$(probe_ssh_result "$raw"); complete=$?
  state=$(tr -d '\r\n' <<<"$state")
  local raw2 units complete2
  raw2=$(probe_ssh 20 "systemctl list-units 'androidd@*' --all --no-legend --plain 2>/dev/null")
  units=$(probe_ssh_result "$raw2"); complete2=$?
  lc_rhizo 60 pool set 0 >/dev/null 2>&1
  if (( complete != 0 )); then
    fail "server.instance-release: the remote adb get-state probe never completed"
    return 1
  fi
  if [[ -z "$state" ]]; then
    fail "server.instance-release: adb -s $LC_INSTANCE_ALLOC_ADB get-state read back nothing at all"
    return 1
  fi
  if [[ "$state" == device ]]; then
    fail "server.instance-release: instance $LC_INSTANCE_ALLOC_ID's adb endpoint $LC_INSTANCE_ALLOC_ADB still reads device after release"
    return 1
  fi
  if (( complete2 != 0 )); then
    fail "server.instance-release: the remote systemctl list-units probe never completed"
    return 1
  fi
  local id_unit="androidd@$LC_INSTANCE_ALLOC_ID.service"
  local id_sub; id_sub=$(awk -v u="$id_unit" '$1==u{print $4}' <<<"$units")
  if [[ "$id_sub" == running ]]; then
    fail "server.instance-release: $id_unit's own systemctl list-units row still reads SUB=running after release: $(awk -v u="$id_unit" '$1==u' <<<"$units")"
    return 1
  fi
  pass "server.instance-release: instance $LC_INSTANCE_ALLOC_ID was released; its adb endpoint reads '$state' (an exact, non-empty, non-device reply) and $id_unit is no longer running (SUB=${id_sub:-<absent>})"
  LC_INSTANCE_ALLOC_ID=""; LC_INSTANCE_ALLOC_ADB=""
}

# check rhizo instance remove deletes the instance
lc_assert_server.instance-remove() {
  lc_need_guest server.instance-remove || return 1
  lc_need_assert_lib server.instance-remove || return 1
  if [[ -z "$LC_INSTANCE_ADD_ID" ]]; then
    fail "server.instance-remove: no instance was added by server.instance-add this cycle"
    return 1
  fi
  local id="$LC_INSTANCE_ADD_ID" env="$LC_INSTANCE_ADD_ENV" data="$LC_INSTANCE_ADD_DATA"
  local out rc; out=$(lc_rhizo 120 instance remove "$id" 2>&1); rc=$?
  if (( rc != 0 )) || ! grep -qE "^RHIZO_INSTANCE_REMOVED id=$id " <<<"$out"; then
    fail "server.instance-remove: rhizo instance remove $id exited $rc with no matching RHIZO_INSTANCE_REMOVED line: $out"
    return 1
  fi
  local raw units complete
  raw=$(probe_ssh 20 "systemctl list-units 'androidd@*' --all --no-legend --plain 2>/dev/null | awk '{print \$1}'")
  units=$(probe_ssh_result "$raw"); complete=$?
  if (( complete != 0 )); then
    fail "server.instance-remove: the remote systemctl list-units probe never completed"
    return 1
  fi
  if grep -qxF "androidd@$id.service" <<<"$units"; then
    fail "server.instance-remove: androidd@$id.service is still listed after remove: $units"
    return 1
  fi
  local raw2 present complete2
  raw2=$(probe_ssh 20 "test -e '$env' && echo ENV_PRESENT; test -e '$data' && echo DATA_PRESENT; true")
  present=$(probe_ssh_result "$raw2"); complete2=$?
  if (( complete2 != 0 )); then
    fail "server.instance-remove: the remote probe for env=$env/data=$data never completed"
    return 1
  fi
  if grep -q ENV_PRESENT <<<"$present" || grep -q DATA_PRESENT <<<"$present"; then
    fail "server.instance-remove: instance $id's own env=$env or data=$data is still present after remove: ${present:-<empty>}"
    return 1
  fi
  LC_INSTANCE_ADD_ID=""; LC_INSTANCE_ADD_ENV=""; LC_INSTANCE_ADD_DATA=""
  pass "server.instance-remove: instance $id was removed; androidd@$id.service is absent from systemctl list-units 'androidd@*' and its own env=$env/data=$data are both gone"
}

# check rhizo pool set reads back in pool status
lc_assert_server.pool-set() {
  lc_need_guest server.pool-set || return 1
  local out rc; out=$(lc_rhizo "$LC_POOL_BOOT_T" pool set 1 2>&1); rc=$?
  if (( rc != 0 )); then
    fail "server.pool-set: rhizo pool set 1 exited $rc: $out"
    return 1
  fi
  local status; status=$(lc_rhizo 30 pool status 2>&1)
  lc_rhizo 60 pool set 0 >/dev/null 2>&1
  if grep -qE '^RHIZO_POOL k=1 ' <<<"$status"; then
    pass "server.pool-set: 'rhizo pool set 1' is read back by 'rhizo pool status' as k=1 ($status)"
  else
    fail "server.pool-set: rhizo pool status does not read back k=1 after 'pool set 1': $status"
    return 1
  fi
}

# test adb_reach=lan on a cloned instance
lc_assert_server.snapshot-clone() {
  lc_need_guest server.snapshot-clone || return 1
  local snap_name="lc-clone-tmpl-$$" clone_id=61
  lc_snapshot0 server.snapshot-clone "$snap_name" || return 1
  local tpath="$LC_SNAP0_PATH"
  local add_out add_rc
  add_out=$(lc_rhizo 600 instance add "$clone_id" --from "$snap_name" 2>&1); add_rc=$?
  if (( add_rc != 0 )) || ! grep -q "^RHIZO_INSTANCE_ADDED id=$clone_id " <<<"$add_out"; then
    fail "server.snapshot-clone: rhizo instance add $clone_id --from $snap_name exited $add_rc with no matching RHIZO_INSTANCE_ADDED line: $add_out"
    ssh_vm -t 30 "rm -f '$tpath' '$tpath.meta'" >/dev/null 2>&1
    return 1
  fi
  ssh_vm -t 15 "install -d -m 0755 /etc/rhizo/instances && printf '[server]\nadb_reach = lan\n' > /etc/rhizo/instances/$clone_id.conf" >/dev/null 2>&1
  local sentinel; sentinel=$(lc_dmesg_sentinel)
  ssh_vm -t 300 "systemctl start androidd@$clone_id.service" >/dev/null 2>&1
  local marker="" decided="" deadline=$((SECONDS + 120))
  while [[ -n "$sentinel" ]] && (( SECONDS < deadline )); do
    decided=$(lc_dmesg_since "$sentinel" 'server.adb_reach=lan')
    marker=$(lc_dmesg_since "$sentinel" 'RHIZO_MARKER adb_lan_refused=instance_above_zero')
    [[ -n "${marker//[[:space:]]/}" || "$decided" == *'server.adb_reach=lan armed'* ]] && break
    sleep 2
  done
  ssh_vm -t 120 "systemctl stop androidd@$clone_id.service" >/dev/null 2>&1
  lc_rhizo 120 instance remove "$clone_id" >/dev/null 2>&1
  ssh_vm -t 15 "rm -f /etc/rhizo/instances/$clone_id.conf '$tpath' '$tpath.meta'" >/dev/null 2>&1
  if [[ -z "$sentinel" ]]; then
    fail "server.snapshot-clone: could not place a dmesg sentinel before starting the tampered clone"
    return 1
  fi
  if [[ "$decided" == *'server.adb_reach=lan armed'* ]]; then
    fail "server.snapshot-clone: a clone at id $clone_id tampered to ask for adb_reach=lan ARMED the rule: $(grep -m1 'armed' <<<"$decided")"
    return 1
  fi
  if [[ -z "${marker//[[:space:]]/}" ]]; then
    fail "server.snapshot-clone: a clone at id $clone_id tampered to ask for adb_reach=lan did not print RHIZO_MARKER adb_lan_refused=instance_above_zero within 120s of its start"
    return 1
  fi
  pass "server.snapshot-clone: a clone tampered to ask for adb_reach=lan above instance 0 was refused ($marker)"
}

# check the control API verbs
lc_assert_server.control-api() {
  lc_need_guest server.control-api || return 1
  lc_need_assert_lib server.control-api || return 1
  [[ -n "$INIT" && -n "$APP_PKG" && -n "$APP_ACT" ]] \
    || { fail "server.control-api: no live sandbox init or fixture app from step 2 to exercise the verbs against"; return 1; }

  local client_py
  client_py=$(cat <<'PYEOF'
import json, socket, sys
verb = sys.argv[1]
id_s = sys.argv[2]
args = sys.argv[3:]
req = {"v": 1, "verb": verb}
if id_s != "-":
    req["id"] = int(id_s)
if args:
    req["args"] = args
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(90)
s.connect("/run/rhizo-api/api.sock")
s.sendall((json.dumps(req) + "\n").encode())
try:
    s.shutdown(socket.SHUT_WR)
except OSError:
    pass
buf = b""
try:
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
except socket.timeout:
    pass
sys.stdout.write(buf.decode("utf-8", "replace"))
PYEOF
)
  local client_b64; client_b64=$(printf '%s' "$client_py" | base64 -w0)
  ssh_vm -t 20 "printf '%s' '$client_b64' | base64 -d > /tmp/lc-api-client.py" >/dev/null 2>&1

  local ok=1

  local r_instances; r_instances=$(ssh_vm -t 30 'python3 /tmp/lc-api-client.py instances -' 2>/dev/null)
  if ! grep -q '"id": 0' <<<"$r_instances" || ! grep -q '"unit": "androidd.service"' <<<"$r_instances"; then
    fail "server.control-api: verb instances did not list id=0 unit=androidd.service: $r_instances"
    ok=0
  fi

  local r_logs; r_logs=$(ssh_vm -t 30 'python3 /tmp/lc-api-client.py logs 0' 2>/dev/null)
  local raw_pid main_pid pid_done
  raw_pid=$(probe_ssh 10 'systemctl show -p MainPID --value androidd.service 2>/dev/null')
  main_pid=$(probe_ssh_result "$raw_pid"); pid_done=$?
  main_pid=${main_pid//[[:space:]]/}
  if ! grep -q '"lines": \[' <<<"$r_logs"; then
    fail "server.control-api: verb logs did not return the {\"lines\": [...]} envelope for id 0: $r_logs"
    ok=0
  elif (( pid_done != 0 )) || [[ ! "$main_pid" =~ ^[1-9][0-9]*$ ]]; then
    fail "server.control-api: androidd.service's MainPID read '${main_pid:-<empty>}'"
    ok=0
  elif ! grep -qF "\"[l3] START entry=selinux_setup pid=$main_pid\"" <<<"$r_logs"; then
    fail "server.control-api: verb logs' own lines hold no line naming this start's own MainPID $main_pid ('[l3] START entry=selinux_setup pid=$main_pid'): $r_logs"
    ok=0
  else
    local last_start; last_start=$(grep -oE '"\[l3\] START entry=[^"]*"' <<<"$r_logs" | tail -1)
    if [[ "$last_start" != "\"[l3] START entry=selinux_setup pid=$main_pid\"" ]]; then
      last_start=${last_start%\"}
      fail "server.control-api: verb logs' tail names MainPID $main_pid only in an earlier start -- its last START line names pid ${last_start##*pid=}, not this start's MainPID $main_pid: $r_logs"
      ok=0
    fi
  fi

  local raw sock_probe complete
  raw=$(probe_ssh 15 "$DESK_WAYLAND_LISTENERS; ls /run/rhizo-wayland/* 2>/dev/null")
  sock_probe=$(probe_ssh_result "$raw"); complete=$?
  if (( complete != 0 )); then
    fail "server.control-api: the remote probe for a Wayland compositor socket never completed"
    ok=0
  elif [[ -n "${sock_probe//[[:space:]]/}" ]]; then
    fail "server.control-api: a Wayland compositor socket exists ($sock_probe)"
    ok=0
  fi
  local r_screenshot; r_screenshot=$(ssh_vm -t 30 'python3 /tmp/lc-api-client.py screenshot 0' 2>/dev/null)
  if ! grep -qF 'no Wayland compositor socket found' <<<"$r_screenshot"; then
    fail "server.control-api: verb screenshot did not refuse with the real 'no Wayland compositor socket found' text: $r_screenshot"
    ok=0
  fi

  local r_input; r_input=$(ssh_vm -t 30 'python3 /tmp/lc-api-client.py input 0 down 1 10 10' 2>/dev/null)
  local composer_log; composer_log=$(logcat_vm "$INIT" -d -s rhizo-uinput:V rhizo-composer:V rhizo-wayland-backend:V)
  printf '%s\n' "${composer_log:-<none: logcat returned nothing for rhizo-uinput, rhizo-composer or rhizo-wayland-backend>}" \
    >"$EV/server-control-api-composer-logcat.log"
  if ! grep -q '"injected": "down"' <<<"$r_input"; then
    fail "server.control-api: verb input did not report injected=down: $r_input (composer logcat: $EV/server-control-api-composer-logcat.log)"
    ok=0
  fi
  ssh_vm -t 30 'python3 /tmp/lc-api-client.py input 0 up 1' >/dev/null 2>&1

  local r_set; r_set=$(ssh_vm -t 60 'python3 /tmp/lc-api-client.py set 0 battery 50 charging' 2>/dev/null)
  if ! grep -q '^RHIZO_API_RC=0$' <<<"$r_set"; then
    fail "server.control-api: verb set (battery) did not relay RHIZO_API_RC=0: $r_set"
    ok=0
  else
    local batt="" batt_deadline=$((SECONDS + 30))
    while (( SECONDS < batt_deadline )); do
      batt=$(android_sh "$INIT" 'dumpsys battery' | grep -m1 -oE 'level: [0-9]+')
      [[ "$batt" == "level: 50" ]] && break
      sleep 2
    done
    if [[ "$batt" != "level: 50" ]]; then
      fail "server.control-api: verb set (battery 50 charging) relayed RHIZO_API_RC=0, but 'dumpsys battery' reads '${batt:-<empty>}' 30s later, wanted 'level: 50'"
      ok=0
    fi
  fi

  local r_install; r_install=$(ssh_vm -t 180 'python3 /tmp/lc-api-client.py install 0 /root/rhizo-lifecycle-fixture.apk' 2>/dev/null)
  if ! grep -q "^RHIZO_APP installed=$APP_PKG " <<<"$r_install" || ! grep -q '^RHIZO_API_RC=0$' <<<"$r_install"; then
    fail "server.control-api: verb install did not relay RHIZO_APP installed=$APP_PKG and RHIZO_API_RC=0: $r_install"
    ok=0
  fi

  local r_launch; r_launch=$(ssh_vm -t 90 "python3 /tmp/lc-api-client.py launch 0 $APP_PKG" 2>/dev/null)
  if ! grep -q "^RHIZO_LAUNCHED pkg=$APP_PKG " <<<"$r_launch" || ! grep -q '^RHIZO_API_RC=0$' <<<"$r_launch"; then
    fail "server.control-api: verb launch did not relay RHIZO_LAUNCHED pkg=$APP_PKG and RHIZO_API_RC=0: $r_launch"
    ok=0
  fi

  local pool_t0; pool_t0=$(ssh_vm -t 10 'date +%s' 2>/dev/null | tr -d '[:space:]')
  lc_rhizo "$LC_POOL_BOOT_T" pool set 1 >"$EV/server-control-api-pool-set.log" 2>&1
  echo "rc=$? started=${pool_t0:-<none>} returned=$(ssh_vm -t 10 'date +%s' 2>/dev/null | tr -d '[:space:]')" >>"$EV/server-control-api-pool-set.log"
  local members; members=$(lc_wait_pool_members 1)
  if [[ "$members" != 1 ]]; then
    ssh_vm -t 30 "rhizo pool status 2>&1; systemctl list-units 'androidd@*' 'rhizo-inputd*' --all --no-legend --plain --no-pager 2>&1; journalctl --since @${pool_t0:-0} --no-pager -o short-unix _PID=1 2>/dev/null | grep -E 'androidd@|rhizo-inputd' | tail -120; for f in /root/boot-[1-9]*.log; do [ -e \"\$f\" ] || continue; echo \"== \$f\"; tail -n 60 \"\$f\"; done" \
      >"$EV/server-control-api-pool-state.log" 2>&1 || true
    fail "server.control-api: rhizo pool set 1 never reached one ready member (members=${members:-<empty>}) (pool verb: $EV/server-control-api-pool-set.log, units: $EV/server-control-api-pool-state.log)"
    lc_rhizo 60 pool set 0 >/dev/null 2>&1
    ssh_vm -t 15 'rm -f /tmp/lc-api-client.py' >/dev/null 2>&1
    return 1
  fi
  echo "<none: the pool reached one ready member>" >"$EV/server-control-api-pool-state.log"
  local r_allocate; r_allocate=$(ssh_vm -t 90 'python3 /tmp/lc-api-client.py allocate -' 2>/dev/null)
  local alloc_id; alloc_id=$(sed -n 's/^RHIZO_ALLOCATED id=\([0-9]\+\).*/\1/p' <<<"$r_allocate" | head -1)
  if [[ -z "$alloc_id" ]] || ! grep -q '^RHIZO_API_RC=0$' <<<"$r_allocate"; then
    fail "server.control-api: verb allocate did not relay a RHIZO_ALLOCATED id= line and RHIZO_API_RC=0: $r_allocate"
    ok=0
  else
    local r_release; r_release=$(ssh_vm -t 90 "python3 /tmp/lc-api-client.py release $alloc_id" 2>/dev/null)
    if ! grep -q "^RHIZO_RELEASED id=$alloc_id\$" <<<"$r_release" || ! grep -q '^RHIZO_API_RC=0$' <<<"$r_release"; then
      fail "server.control-api: verb release did not relay RHIZO_RELEASED id=$alloc_id and RHIZO_API_RC=0: $r_release"
      ok=0
    fi
  fi
  lc_rhizo 60 pool set 0 >/dev/null 2>&1
  ssh_vm -t 15 'rm -f /tmp/lc-api-client.py' >/dev/null 2>&1

  if (( ok )); then
    pass "server.control-api: all nine verbs (instances, logs, screenshot, input, set, install, launch, allocate, release) answer with their own exact sentinel over rhizo-api.socket"
  fi
  (( ok ))
}

# test reading a missing policy.conf
lc_assert_policy.absent-is-defaults() {
  lc_need_guest policy.absent-is-defaults || return 1
  lc_need_assert_lib policy.absent-is-defaults || return 1
  local prior; prior=$(lc_save_policy_conf) \
    || { fail "policy.absent-is-defaults: could not read /etc/rhizo/policy.conf before deleting it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  ssh_vm -t 15 'rm -f /etc/rhizo/policy.conf' >/dev/null 2>&1
  local raw gone complete
  raw=$(probe_ssh 15 'test -f /etc/rhizo/policy.conf && echo PRESENT || echo ABSENT')
  gone=$(probe_ssh_result "$raw"); complete=$?
  if (( complete != 0 )); then
    fail "policy.absent-is-defaults: the remote probe confirming policy.conf is gone never completed"
    lc_restore_policy_conf "$prior" || fail "policy.absent-is-defaults: restore failed"
    return 1
  fi
  if [[ "$gone" != ABSENT ]]; then
    fail "policy.absent-is-defaults: removed policy.conf, but a read-back still finds it present ($gone)"
    lc_restore_policy_conf "$prior" || fail "policy.absent-is-defaults: restore failed"
    return 1
  fi
  local out
  out=$(ssh_vm -t 20 "PYTHONPATH=/usr/lib/rhizo/tools python3 -c \"from sandbox import capabilities as rc; p,err=rc.read_policy(); d=rc.defaults(); print(1 if err is None and p==d else 0)\"" 2>/dev/null | tr -d '[:space:]')
  local audio_active audio_sock audio_test_rc=""
  if [[ "${1:-}" == server ]]; then
    ssh_vm -t 15 '/usr/lib/rhizo/tools/capability-allowed.sh audio.out' >/dev/null 2>&1; audio_test_rc=$?
  else
    ssh_vm -t 10 'systemctl stop rhizo-audiod.service 2>/dev/null; systemctl reset-failed rhizo-audiod.service 2>/dev/null; systemctl start rhizo-audiod.service' >/dev/null 2>&1
    audio_active=$(ssh_vm -t 10 'systemctl is-active rhizo-audiod.service 2>/dev/null' | tr -d '[:space:]')
    audio_sock=$(ssh_vm -t 10 'test -S /run/rhizo-audio/audiod && echo UP || echo DOWN' | tr -d '[:space:]')
  fi
  local bridge_why="" restore_why=""
  if [[ "${1:-}" != server ]] && ! bridge_why=$(_lc_desktop_bridge_restart); then
    bridge_why="${bridge_why:-no reason given}"
  fi
  local pointer_off=0 pointer_evidence=""
  local wl; wl=$(lc_procs_named rhizo-wlbridge)
  if [[ -n "${wl//[[:space:]]/}" ]]; then
    pointer_evidence="wlbridge argv: $wl"
    grep -q 'pointer' <<<"$wl" || pointer_off=1
  else
    local test_rc
    ssh_vm -t 15 '/usr/lib/rhizo/tools/capability-allowed.sh desktop.pointer'; test_rc=$?
    pointer_evidence="capability-allowed.sh desktop.pointer exited $test_rc (no live wlbridge to read argv from)"
    (( test_rc == 1 )) && pointer_off=1
  fi
  lc_restore_policy_conf "$prior" || fail "policy.absent-is-defaults: restore failed"
  if [[ "${1:-}" != server ]] && ! restore_why=$(_lc_desktop_bridge_restart); then
    restore_why="${restore_why:-no reason given}"
  fi
  ssh_vm -t 10 'systemctl reset-failed rhizo-audiod.service 2>/dev/null; systemctl start rhizo-audiod.service' >/dev/null 2>&1

  local ok=1
  if [[ -n "$bridge_why" ]]; then
    fail "policy.absent-is-defaults: with policy.conf absent, the bridge did not come back up over the restarted deskd: $bridge_why"
    ok=0
  fi
  if [[ -n "$restore_why" ]]; then
    fail "policy.absent-is-defaults: restored, the bridge did not come back up over the restarted deskd: $restore_why"
    ok=0
  fi
  if [[ "$out" != 1 ]]; then
    fail "policy.absent-is-defaults: with policy.conf absent, read_policy() did not equal defaults() (got '${out:-<empty>}')"
    ok=0
  fi
  local audio_evidence
  if [[ -n "$audio_test_rc" ]]; then
    audio_evidence="capability-allowed.sh audio.out exited $audio_test_rc"
    if [[ "$audio_test_rc" != 0 ]]; then
      fail "policy.absent-is-defaults: with policy.conf absent, audio.out's own gate withheld it on this server host ($audio_evidence), wanted 0: the default is on"
      ok=0
    fi
  else
    audio_evidence="audio.out's own daemon is live (is-active=active, socket UP)"
    if [[ "$audio_active" != active || "$audio_sock" != UP ]]; then
      fail "policy.absent-is-defaults: with policy.conf absent, audio.out's own daemon read is-active=${audio_active:-<empty>} socket=${audio_sock:-<empty>}, wanted active/UP"
      ok=0
    fi
  fi
  if (( pointer_off == 0 )); then
    fail "policy.absent-is-defaults: with policy.conf absent, desktop.pointer did not read unreachable ($pointer_evidence)"
    ok=0
  fi
  (( ok )) \
    && pass "policy.absent-is-defaults: with policy.conf absent, read_policy()==defaults(), $audio_evidence, and desktop.pointer reads unreachable ($pointer_evidence)"
  (( ok ))
}

LC_IDLE_VERDICT_RE="server.idle_stop_s=0 -- idle-stop is off, exiting|started this run's own session count"
# print the journal line holding the idle verdict
lc_idle_verdict() {
  lc_inv_journal_line "$1" "$LC_IDLE_VERDICT_RE"
}

# print the first journal line matching the ERE
lc_inv_journal_line() {
  local inv="$1" re="$2" j line deadline=$((SECONDS + 30))
  [[ "$inv" =~ ^[0-9a-f]{32}$ ]] || return 1
  while (( SECONDS < deadline )); do
    j=$(ssh_vm -t 15 "journalctl _SYSTEMD_INVOCATION_ID=$inv --no-pager -o cat 2>/dev/null; echo DONE")
    lc_done_strip j || return 1
    line=$(grep -m1 -E "$re" <<<"$j")
    [[ -n "$line" ]] && { printf '%s' "$line"; return 0; }
    sleep 2
  done
  return 1
}

LC_POLICY_DENY_RE=' -- denying every optional capability$'

# print the policy-reading unit for a profile
lc_unparsable_unit() {
  if [[ "$1" == server ]]; then echo rhizo-server-idle.service; else echo rhizo-audiod.service; fi
}

# check an unparsable policy.conf denies optional capabilities
lc_assert_policy.unparsable-denies-optional() {
  local profile="${1:-}"
  lc_need_guest policy.unparsable-denies-optional || return 1
  local unit; unit=$(lc_unparsable_unit "$profile")
  local prior; prior=$(lc_save_policy_conf) \
    || { fail "policy.unparsable-denies-optional: could not read /etc/rhizo/policy.conf before editing it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  local inv_before; inv_before=$(ssh_vm -t 10 "systemctl show -p InvocationID --value $unit 2>/dev/null" | tr -d '[:space:]')
  ssh_vm -t 15 "printf 'not an ini file at all {{{\n' > /etc/rhizo/policy.conf" >/dev/null 2>&1
  local out
  out=$(ssh_vm -t 20 "PYTHONPATH=/usr/lib/rhizo/tools python3 -c \"from sandbox import capabilities as rc; p=rc.policy_or_deny(log=lambda m: None); print(1 if p==rc.deny_all() else 0)\"" 2>/dev/null | tr -d '[:space:]')
  ssh_vm -t 10 "systemctl stop $unit 2>/dev/null; systemctl reset-failed $unit 2>/dev/null; systemctl start $unit" >/dev/null 2>&1
  local cond="" inv_after verdict="" denied="" daemon_off=0 daemon_evidence
  inv_after=$(ssh_vm -t 10 "systemctl show -p InvocationID --value $unit 2>/dev/null" | tr -d '[:space:]')
  if [[ "$profile" == server ]]; then
    verdict=$(lc_idle_verdict "$inv_after")
    denied=$(lc_inv_journal_line "$inv_after" "$LC_POLICY_DENY_RE")
    [[ "$verdict" == "server.idle_stop_s=0 -- idle-stop is off, exiting" && -n "$denied" ]] && daemon_off=1
    daemon_evidence="$unit's own lines under invocation ${inv_after:-<none>}: '${verdict:-<none within 30s>}' and '${denied:-<none within 30s>}', wanted 'server.idle_stop_s=0 -- idle-stop is off, exiting' and policy_or_deny's '<why> -- denying every optional capability'"
  else
    cond=$(ssh_vm -t 10 "systemctl show -p ConditionResult --value $unit 2>/dev/null" | tr -d '[:space:]')
    [[ "$cond" == no ]] && daemon_off=1
    daemon_evidence="$unit ConditionResult: ${cond:-<empty>}, wanted no"
  fi
  local deskd_done=DONE restore_why=""
  if [[ "$profile" != server ]]; then
    deskd_done=$(ssh_vm -t 60 'systemctl restart rhizo-deskd.service >/dev/null 2>&1; echo DONE' | tr -d '[:space:]')
  fi
  local drag_off=0 drag_evidence=""
  local wl; wl=$(lc_procs_named rhizo-wlbridge)
  if [[ -n "${wl//[[:space:]]/}" ]]; then
    drag_evidence="wlbridge argv: $wl"
    grep -qE 'drag|clipboard|pointer' <<<"$wl" || drag_off=1
  else
    local test_rc
    ssh_vm -t 15 '/usr/lib/rhizo/tools/capability-allowed.sh desktop.drag'; test_rc=$?
    drag_evidence="capability-allowed.sh desktop.drag exited $test_rc (no live wlbridge to read argv from)"
    (( test_rc == 1 )) && drag_off=1
  fi
  lc_restore_policy_conf "$prior" || fail "policy.unparsable-denies-optional: restore failed"
  local restored="" inv_restored=""
  if [[ "$profile" == server ]]; then
    ssh_vm -t 10 "systemctl restart $unit" >/dev/null 2>&1
    inv_restored=$(ssh_vm -t 10 "systemctl show -p InvocationID --value $unit 2>/dev/null" | tr -d '[:space:]')
    restored=$(lc_idle_verdict "$inv_restored")
  else
    ssh_vm -t 10 "systemctl reset-failed $unit 2>/dev/null; systemctl start $unit" >/dev/null 2>&1
    if ! restore_why=$(_lc_desktop_bridge_restart); then restore_why="${restore_why:-no reason given}"; fi
  fi

  local ok=1
  if [[ "$deskd_done" != DONE ]]; then
    fail "policy.unparsable-denies-optional: with policy.conf unparsable, rhizo-deskd.service's restart job did not end within 60s (read '${deskd_done:-<empty>}')"
    ok=0
  fi
  if [[ -n "$restore_why" ]]; then
    fail "policy.unparsable-denies-optional: restored, the bridge did not come back up over the restarted deskd: $restore_why"
    ok=0
  fi
  if [[ "$out" != 1 || "$daemon_off" != 1 ]]; then
    fail "policy.unparsable-denies-optional: an unparsable policy.conf did not deny every optional capability (policy_or_deny==deny_all: ${out:-<empty>}, wanted 1; $daemon_evidence)"
    ok=0
  fi
  if [[ -z "$inv_before" || -z "$inv_after" || "$inv_after" == "$inv_before" ]]; then
    fail "policy.unparsable-denies-optional: $unit's own InvocationID did not change across the stop/reset-failed/start cycle (before='${inv_before:-<empty>}' after='${inv_after:-<empty>}')"
    ok=0
  fi
  if [[ "$profile" == server && "$restored" != "started this run's own session count"* ]]; then
    fail "policy.unparsable-denies-optional: with policy.conf restored, $unit's invocation ${inv_restored:-<none>} logged '${restored:-<nothing within 30s>}', not its session-count seed"
    ok=0
  fi
  if (( drag_off == 0 )); then
    fail "policy.unparsable-denies-optional: with policy.conf unparsable, desktop.drag did not read unreachable ($drag_evidence)"
    ok=0
  fi
  (( ok )) \
    && pass "policy.unparsable-denies-optional: with policy.conf unparsable, policy_or_deny() equals deny_all(), a new invocation of $unit withheld its capability ($daemon_evidence), and desktop.drag reads unreachable ($drag_evidence)"
  (( ok ))
}

# check audio out off leaves no audiod daemon or socket
lc_assert_policy.off-is-unreachable() {
  lc_need_guest policy.off-is-unreachable || return 1
  local prior; prior=$(lc_save_policy_conf) \
    || { fail "policy.off-is-unreachable: could not read /etc/rhizo/policy.conf before editing it -- refusing to touch it without a way back"; return 1; }
  lc_arm_policy_restore "$prior"
  ssh_vm -t 15 "printf '[audio]\nout = no\n' > /etc/rhizo/policy.conf" >/dev/null 2>&1
  ssh_vm -t 10 'systemctl stop rhizo-audiod.service 2>/dev/null; systemctl reset-failed rhizo-audiod.service 2>/dev/null; systemctl start rhizo-audiod.service' >/dev/null 2>&1
  local cond active daemon sock
  cond=$(ssh_vm -t 10 'systemctl show -p ConditionResult --value rhizo-audiod.service 2>/dev/null' | tr -d '[:space:]')
  active=$(ssh_vm -t 10 'systemctl is-active rhizo-audiod.service 2>/dev/null' | tr -d '[:space:]')
  daemon=$(ssh_vm -t 10 'pgrep -x rhizo-audiod >/dev/null 2>&1 && echo UP || echo DOWN' | tr -d '[:space:]')
  sock=$(ssh_vm -t 10 'test -S /run/rhizo-audio/audiod && echo UP || echo DOWN' | tr -d '[:space:]')
  lc_restore_policy_conf "$prior" || fail "policy.off-is-unreachable: restore failed"
  ssh_vm -t 10 'systemctl reset-failed rhizo-audiod.service 2>/dev/null; systemctl start rhizo-audiod.service' >/dev/null 2>&1
  local restored; restored=$(ssh_vm -t 10 'systemctl is-active rhizo-audiod.service 2>/dev/null' | tr -d '[:space:]')
  if [[ "$cond" != no || "$active" == active || "$daemon" != DOWN || "$sock" != DOWN ]]; then
    fail "policy.off-is-unreachable: audio.out withheld left ConditionResult=${cond:-<empty>} is-active=${active:-<empty>} daemon=${daemon:-<empty>} socket=${sock:-<empty>}, wanted no/not-active/DOWN/DOWN (no daemon, no socket, no argv exec, no unit start)"
    return 1
  fi
  if [[ "$restored" != active ]]; then
    fail "policy.off-is-unreachable: audio.out restored via policy.conf, but rhizo-audiod.service did not become active again (is-active=${restored:-<empty>})"
    return 1
  fi
  pass "policy.off-is-unreachable: audio.out withheld leaves no daemon, no socket and no unit exec (ConditionResult=no); restored, the daemon is active again"
}

# check that the sandbox's route to 1.1.1.1 goes through 192.168.100.1
lc_assert_network.internet-via-gateway() {
  lc_need_guest network.internet-via-gateway || return 1
  local init; init=$(lc_resolve_init 60)
  [[ -n "$init" ]] || { fail "network.internet-via-gateway: no sandbox init to probe from"; return 1; }
  android_sh "$init" 'ip route get 1.1.1.1 2>/dev/null' | grep -q 192.168.100.1 \
    && pass "network.internet-via-gateway: the sandbox routes through 192.168.100.1" \
    || { fail "network.internet-via-gateway: the sandbox's default route is not via 192.168.100.1"; return 1; }
}

# check that the sandbox's default network resolves through 192.168.100.1 alone
lc_assert_network.dns() {
  lc_need_guest network.dns || return 1
  local init; init=$(lc_resolve_init 60)
  [[ -n "$init" ]] || { fail "network.dns: no sandbox init to probe from"; return 1; }
  local dns
  dns=$(lc_sandbox_dns "$init") \
    || { fail "network.dns: no DnsAddresses read for the active default network from the sandbox's dumpsys connectivity"; return 1; }
  lc_dns_lists "$dns" 192.168.100.1 \
    && pass "network.dns: the sandbox's default network resolves through the host's own forwarder alone (DnsAddresses [$dns])" \
    || { fail "network.dns: the default network's resolvers are [$dns], not the host's forwarder /192.168.100.1 alone"; return 1; }
}

# test the mDNS socket on port 5353
lc_assert_network.mdns-off-default() {
  lc_need_guest network.mdns-off-default || return 1
  lc_need_assert_lib network.mdns-off-default || return 1
  local mainpid; mainpid=$(ssh_vm -t 10 'systemctl show -p MainPID --value rhizo-netbridged.service 2>/dev/null' | tr -d '[:space:]')
  if [[ ! "$mainpid" =~ ^[1-9][0-9]*$ ]]; then
    fail "network.mdns-off-default: no MainPID for rhizo-netbridged.service"
    return 1
  fi
  local argv; argv=$(ssh_vm -t 10 "ps -o args= -p $mainpid 2>/dev/null")
  if [[ -z "${argv//[[:space:]]/}" ]]; then
    fail "network.mdns-off-default: could not read rhizo-netbridged's own argv (pid $mainpid)"
    return 1
  fi
  if grep -qE -- '--services[= ][^ ]*mdns' <<<"$argv"; then
    fail "network.mdns-off-default: rhizo-netbridged's own argv already names mdns in --services: $argv"
    return 1
  fi
  local raw out complete
  raw=$(probe_ssh 20 "awk '/^Uid:/ {print \"uid\", \$2}' /proc/$mainpid/status; awk 'FNR > 1 {print \"udp\", \$2, \$8}' /proc/net/udp /proc/net/udp6")
  out=$(probe_ssh_result "$raw"); complete=$?
  if (( complete != 0 )); then
    fail "network.mdns-off-default: the remote socket-table probe never completed (no sentinel read back)"
    return 1
  fi
  local nb_uid kind addr uid port dhcp="" mdns=""
  nb_uid=$(awk '$1 == "uid" {print $2; exit}' <<<"$out")
  if [[ ! "$nb_uid" =~ ^[1-9][0-9]*$ ]]; then
    fail "network.mdns-off-default: rhizo-netbridged's MainPID $mainpid runs as uid '${nb_uid:-<unread>}', not its own unprivileged account"
    return 1
  fi
  while read -r kind addr uid; do
    [[ "$kind" == udp && "${addr##*:}" =~ ^[0-9A-Fa-f]{4}$ && "$uid" =~ ^[0-9]+$ ]] || continue
    port=$((16#${addr##*:}))
    if (( port == 67 )); then dhcp+="67:$uid "; elif (( port == 5353 )); then mdns+="5353:$uid "; fi
  done <<<"$out"
  if [[ " $dhcp" != *" 67:$nb_uid "* ]]; then
    fail "network.mdns-off-default: the same read found no udp :67 (dhcp) socket owned by rhizo-netbridged's account (uid $nb_uid, MainPID $mainpid) (:67 sockets: ${dhcp:-none})"
    return 1
  fi
  if [[ " $mdns" == *" 5353:$nb_uid "* ]]; then
    fail "network.mdns-off-default: rhizo-netbridged's own account (uid $nb_uid) holds a udp :5353 socket with mdns off by default ($mdns)"
    return 1
  fi
  local acct name uid host_own=""
  while IFS=: read -r name uid; do
    [[ "$uid" =~ ^[0-9]+$ ]] || continue
    acct=$(tr ' ' '\n' <<<"$mdns" | grep -x "5353:$uid" | sort -u | tr '\n' ' ')
    [[ -n "$acct" ]] && host_own+="$name ($acct) "
    mdns=$(tr ' ' '\n' <<<"$mdns" | grep -vx "5353:$uid" | grep . | tr '\n' ' ')
  done < <(ssh_vm -t 10 'getent passwd avahi systemd-resolve | cut -d: -f1,3' | tr -d '\r')
  if [[ -n "$mdns" ]]; then
    fail "network.mdns-off-default: something is bound to udp :5353 in the host netns with mdns off by default (not rhizo-netbridged's account uid $nb_uid, but worth flagging): $mdns"
    return 1
  fi
  [[ -z "$host_own" ]] || log "    network.mdns-off-default: the host's own responders hold :5353: $host_own"
  pass "network.mdns-off-default: rhizo-netbridged's own argv omits mdns from --services and no udp socket in the host netns is on :5353 (the same read found its account's uid $nb_uid on :67)"
}

# write the hostfs state to a file
_lc_hostfs_state() {
  ssh_vm -t 20 "systemctl is-active rhizo-hostfs.service; journalctl -b -u rhizo-hostfs.service --no-pager -o short-monotonic | tail -12
grep ' /mnt/user/0/emulated/0/Download ' /proc/$INIT/mountinfo || echo 'no Download mount in init $INIT'" > "$EV/$1-hostfs-state.txt" 2>&1
}

# test a host file read from Android
lc_assert_hostfs.shared-storage() {
  lc_need_guest hostfs.shared-storage || return 1
  lc_need_assert_lib hostfs.shared-storage || return 1
  [[ -n "$INIT" && -n "$DOWNLOADS" ]] \
    || { fail "hostfs.shared-storage: no live sandbox init or Downloads dir from step 2's fixture setup"; return 1; }
  local host_path="$DOWNLOADS/lc-hostfs-share.txt" android_path=/storage/emulated/0/Download/lc-hostfs-share.txt
  local nonce; nonce="lc-hostfs-share-$(date +%s)-$RANDOM-$$"
  desk_user_sh 15 "rm -f '$host_path'" >/dev/null 2>&1
  local raw gone complete
  raw=$(desk_user_sh 15 "test -e '$host_path' && echo PRESENT || echo ABSENT; echo $PROBE_DONE_TAG" 2>/dev/null)
  gone=$(probe_ssh_result "$raw"); complete=$?
  if (( complete != 0 )); then
    fail "hostfs.shared-storage: the remote probe confirming the host file is gone never completed"
    return 1
  fi
  if [[ "$gone" != ABSENT ]]; then
    fail "hostfs.shared-storage: could not remove a leftover $host_path before this cycle's own write ($gone)"
    return 1
  fi
  local raw2 write_out write_complete
  raw2=$(desk_user_sh 20 "printf '%s' '$nonce' > '$host_path' && echo WRITE_OK; echo $PROBE_DONE_TAG" 2>/dev/null)
  write_out=$(probe_ssh_result "$raw2"); write_complete=$?
  if (( write_complete != 0 )) || [[ "$write_out" != WRITE_OK ]]; then
    fail "hostfs.shared-storage: writing the nonce to $host_path did not report WRITE_OK (complete=$write_complete out='${write_out:-<empty>}')"
    return 1
  fi
  local host_content android_content android_rc
  host_content=$(desk_user_sh 15 "cat '$host_path' 2>/dev/null")
  android_content=$(android_sh "$INIT" "cat $android_path 2>/dev/null"); android_rc=$?
  if (( android_rc != 0 )); then
    fail "hostfs.shared-storage: android_sh could not reach the guest to read $android_path (rc=$android_rc)"
    return 1
  fi
  if [[ "$host_content" != "$nonce" ]]; then
    fail "hostfs.shared-storage: the host's own $host_path does not read back this cycle's nonce (got '${host_content:-<empty>}', wanted '$nonce')"
    return 1
  fi
  if [[ "$android_content" != "$nonce" ]]; then
    _lc_hostfs_state hostfs-shared-storage
    fail "hostfs.shared-storage: Android's $android_path does not read this cycle's nonce (got '${android_content:-<empty>}', wanted '$nonce'; see hostfs-shared-storage-hostfs-state.txt)"
    return 1
  fi
  pass "hostfs.shared-storage: a host Downloads file carrying this cycle's own nonce is readable in Android's /storage/emulated/0/Download with the identical content"
}

# check Android Downloads writes reach the host Downloads
lc_assert_hostfs.write-through() {
  lc_need_guest hostfs.write-through || return 1
  lc_need_assert_lib hostfs.write-through || return 1
  [[ -n "$INIT" && -n "$DOWNLOADS" ]] \
    || { fail "hostfs.write-through: no live sandbox init or Downloads dir from step 2's fixture setup"; return 1; }
  local host_path="$DOWNLOADS/lc-hostfs-writethrough.txt" android_path=/storage/emulated/0/Download/lc-hostfs-writethrough.txt
  local nonce; nonce="lc-hostfs-wt-$(date +%s)-$RANDOM-$$"
  android_sh "$INIT" "rm -f $android_path" >/dev/null 2>&1
  desk_user_sh 15 "rm -f '$host_path'" >/dev/null 2>&1
  local raw gone complete
  raw=$(desk_user_sh 15 "test -e '$host_path' && echo PRESENT || echo ABSENT; echo $PROBE_DONE_TAG" 2>/dev/null)
  gone=$(probe_ssh_result "$raw"); complete=$?
  if (( complete != 0 )); then
    fail "hostfs.write-through: the remote probe confirming the host file is gone never completed"
    return 1
  fi
  if [[ "$gone" != ABSENT ]]; then
    fail "hostfs.write-through: could not remove a leftover $host_path before this cycle's own write ($gone)"
    return 1
  fi
  local write_rc
  android_sh "$INIT" "printf '%s' '$nonce' > $android_path"; write_rc=$?
  if (( write_rc != 0 )); then
    fail "hostfs.write-through: the Android write of this cycle's nonce to $android_path exited $write_rc"
    return 1
  fi
  local android_content android_rc
  android_content=$(android_sh "$INIT" "cat $android_path 2>/dev/null"); android_rc=$?
  if (( android_rc != 0 )); then
    fail "hostfs.write-through: android_sh could not read $android_path back (rc=$android_rc)"
    return 1
  fi
  if [[ "$android_content" != "$nonce" ]]; then
    fail "hostfs.write-through: Android's own $android_path does not read back this cycle's nonce (got '${android_content:-<empty>}', wanted '$nonce')"
    return 1
  fi
  local host_content; host_content=$(desk_user_sh 15 "cat '$host_path' 2>/dev/null")
  if [[ "$host_content" != "$nonce" ]]; then
    _lc_hostfs_state hostfs-write-through
    fail "hostfs.write-through: the host's own $host_path does not read this cycle's nonce back (got '${host_content:-<empty>}', wanted '$nonce'; see hostfs-write-through-hostfs-state.txt)"
    return 1
  fi
  pass "hostfs.write-through: an Android write carrying this cycle's own nonce to /storage/emulated/0/Download reads back on the host with the identical content"
}

# print the SELinux label of a guest path
lc_hp_label() {
  ssh_vm -t 10 "python3 -c 'import os,sys; print(os.getxattr(sys.argv[1], \"security.selinux\").decode().rstrip(chr(0)))' '$1' 2>/dev/null || echo '<none>'" 2>/dev/null | tr -d '\r'
}

# send a QMP command to QEMU
lc_hp_qmp() {
  [[ -S "${QMP_SOCK:-}" ]] || return 1
  { echo '{"execute":"qmp_capabilities"}'; echo "$1"; sleep 0.5; } \
    | ( cd "$(dirname "$QMP_SOCK")" && timeout 10 socat - "UNIX-CONNECT:$(basename "$QMP_SOCK")" ) 2>/dev/null
}

# print host-domain denials in a kmsg window
lc_hp_avc() {
  local end win
  end=$(lc_dmesg_sentinel) || return 1
  win=$(lc_dmesg_window "$1" "$end") || return 1
  grep -aF 'avc:  denied' <<<"$win" | grep -aE 'scontext=u:r:(rhizo_host|kernel):'
  return 0
}

LC_HP_FWUPD_UEVENT_READS=3

LC_HP_MON_SH='S=${LC_HP_SYS:-/sys}; udevadm monitor --udev | while read -r src ts act path rest; do if [ "$src $ts" = "UDEV -" ]; then echo READY; continue; fi; [ "$src" = UDEV ] && [ "$act" = add ] || continue; if m=$(stat -L -c %a "$S$path/uevent" 2>/dev/null); then echo "ADD $path $m"; elif [ ! -d "$S$path" ]; then echo "ADD $path gone"; elif ls -A "$S$path" >/dev/null 2>&1 && ! ls -A "$S$path" | grep -qx uevent; then echo "ADD $path none"; else echo "ADD $path unread"; fi; done'

# start the udev add monitor on the guest
lc_hp_mon_start() {
  local mon_sh
  mon_sh=$(printf '%q' "$LC_HP_MON_SH")
  ssh_vm -t 30 "systemctl stop rhizo-lc-hpmon.service 2>/dev/null; systemctl reset-failed rhizo-lc-hpmon.service 2>/dev/null; rm -f /run/rhizo-lc-hpmon.log
systemd-run --quiet --collect --expand-environment=no --unit=rhizo-lc-hpmon -p RuntimeMaxSec=600 -p StandardOutput=file:/run/rhizo-lc-hpmon.log /bin/sh -c $mon_sh || exit 1
for i in \$(seq 1 100); do grep -qx READY /run/rhizo-lc-hpmon.log 2>/dev/null && echo READY && exit 0; sleep 0.1; done" 2>/dev/null | tr -d '\r'
}

# stop rhizo-lc-hpmon.service and print ADD log lines
lc_hp_mon_stop() {
  ssh_vm -t 20 'systemctl stop rhizo-lc-hpmon.service 2>/dev/null; grep "^ADD " /run/rhizo-lc-hpmon.log 2>/dev/null; rm -f /run/rhizo-lc-hpmon.log; echo DONE' 2>/dev/null | tr -d '\r'
}

# print the MainPID of fwupd.service
lc_hp_fwupd_pid() {
  local p
  p=$(ssh_vm -t 10 'systemctl show -p MainPID --value fwupd.service' 2>/dev/null | tr -d '[:space:]')
  if [[ "$p" =~ ^[0-9]+$ ]]; then echo "$p"; else echo '<unread>'; fi
}

# print fwupd's netlink queue bytes and drops
lc_hp_fwupd_queue() {
  local q
  q=$(ssh_vm -t 10 "awk '\$2 == 15 && \$3 == $1 && \$4 == \"00000002\" { print \$5, \$9 }' /proc/net/netlink" 2>/dev/null | tr -d '\r')
  if [[ "$q" =~ ^[0-9]+\ [0-9]+$ ]]; then echo "$q"; else echo '<none>'; fi
}

# print the DAC pair and add counts
lc_hp_fwupd_due() {
  local path mode pairs=0 adds=0
  while read -r _ path mode; do
    [[ -n "$path" && "$mode" != none ]] || continue
    if [[ ! "$mode" =~ ^[0-7]{1,4}$ ]]; then
      echo "the add monitor could not read $path/uevent (${mode:-<nothing>})"
      return 1
    fi
    if (( (8#$mode & 8#444) == 0 )); then
      (( adds += 1, pairs += LC_HP_FWUPD_UEVENT_READS ))
    fi
  done <<<"$1"
  echo "$pairs $adds"
}

# count capability denial pairs for a pid
lc_hp_dac_pairs() {
  awk -v pid="$1" -v comm="${2:-fwupd}" '
    (pid == "any" || pid ~ /^[1-9][0-9]*$/ && index($0, " pid=" pid " ")) \
      && index($0, " comm=\"" comm "\" ") && / tclass=capability / && match($0, / pid=[0-9]+ /) {
      p = substr($0, RSTART + 5, RLENGTH - 6)
      if ($0 ~ /\{ dac_read_search \}/) { if (p in held) rest[++nr] = held[p]; held[p] = $0; next }
      if ($0 ~ /\{ dac_override \}/ && (p in held)) { n++; delete held[p]; next }
    }
    { rest[++nr] = $0 }
    END {
      for (p in held) rest[++nr] = held[p]
      print "PAIRS " n + 0
      for (i = 1; i <= nr; i++) print rest[i]
    }'
}

# print udev uevent read counts per systemd major
lc_hp_udev_reads() {
  case "$1" in 255) echo "0 0 0 0" ;; 262) echo "1 1 1 2" ;; *) return 1 ;; esac
}

# count module and driver adds in ADD lines
lc_hp_udev_kinds() {
  local path mode m=0 d=0 other=""
  while read -r _ path mode; do
    [[ -n "$path" && "$mode" != none ]] || continue
    [[ "$mode" =~ ^[0-7]{1,4}$ ]] \
      || { echo "the add monitor could not read $path/uevent (${mode:-<nothing>})"; return 1; }
    (( (8#$mode & 8#444) == 0 )) || continue
    case "$path" in
      /module/*) (( m += 1 )) ;;
      /bus/*/drivers/*) (( d += 1 )) ;;
      *) other+="${other:+,}$path" ;;
    esac
  done <<<"$1"
  echo "$m $d $other"
}
LC_HP_LISTENERS_SH='echo "systemd=$(systemctl --version | awk '"'"'NR == 1 { print $2 }'"'"') udevd=$(systemctl show -p MainPID --value systemd-udevd.service) mon=$(for p in $(cat /sys/fs/cgroup/system.slice/rhizo-lc-hpmon.service/cgroup.procs 2>/dev/null); do [ "$(cat /proc/$p/comm 2>/dev/null)" = udevadm ] && echo $p; done | head -1)"'

LC_HP_BINFMT_RE='avc:  denied  \{ remount \} for  pid=[0-9]+ comm="\([^"]+\)" scontext=u:r:rhizo_host:s0 tcontext=u:object_r:binfmt_miscfs:s0 tclass=filesystem permissive=0$'

# check hot-plugged devices get rhizo_host labels
lc_assert_host.hotplug-after-flip() {
  local id=host.hotplug-after-flip
  lc_need_guest "$id" || return 1
  [[ -S "${QMP_SOCK:-}" ]] || { fail "$id: no QMP socket at '${QMP_SOCK:-}'"; return 1; }
  [[ -d "${REPO:-}" ]] || { fail "$id: REPO '${REPO:-}' is not a directory to hold the hot-plugged disk image"; return 1; }

  local enforce shell_dom udevd_dom kmod_lbl dummy_ko dummy_lbl
  enforce=$(ssh_vm -t 10 'cat /sys/fs/selinux/enforce' 2>/dev/null | tr -d '[:space:]')
  [[ "$enforce" == 1 ]] || { fail "$id: enforce=${enforce:-<unreadable>}, the claim is about an enforcing host"; return 1; }
  shell_dom=$(ssh_vm -t 10 'cat /proc/self/attr/current' 2>/dev/null | tr -d '\0\r\n')
  udevd_dom=$(ssh_vm -t 10 'cat /proc/$(systemctl show -p MainPID --value systemd-udevd.service)/attr/current' 2>/dev/null | tr -d '\0\r\n')
  [[ "$udevd_dom" == *:rhizo_host:* ]] || { fail "$id: systemd-udevd runs as '${udevd_dom:-<unreadable>}', not rhizo_host"; return 1; }
  kmod_lbl=$(lc_hp_label /usr/bin/kmod)
  [[ "$kmod_lbl" == u:object_r:rhizo_host_exec:s0 ]] || { fail "$id: /usr/bin/kmod is '$kmod_lbl', not rhizo_host_exec"; return 1; }
  dummy_ko=$(ssh_vm -t 10 'modinfo -n dummy' 2>/dev/null | tr -d '\r\n')
  [[ "$dummy_ko" == /lib/modules/* || "$dummy_ko" == /usr/lib/modules/* ]] \
    || { fail "$id: modinfo -n dummy said '${dummy_ko:-<empty>}'"; return 1; }
  dummy_lbl=$(lc_hp_label "$dummy_ko")
  [[ "$dummy_lbl" == u:object_r:rhizo_host_module_file:s0 ]] || { fail "$id: $dummy_ko is '$dummy_lbl', not rhizo_host_module_file"; return 1; }
  local null_lbl; null_lbl=$(lc_hp_label /dev/null)
  [[ "$null_lbl" == u:object_r:rhizo_host_device:s0 ]] || { fail "$id: the host's /dev/null is '$null_lbl', not rhizo_host_device"; return 1; }

  local dummy_before
  dummy_before=$(ssh_vm -t 15 'ip link del rhzhp0 2>/dev/null; modprobe -r dummy 2>/dev/null; test -d /sys/module/dummy && echo loaded || echo gone' 2>/dev/null | tr -d '[:space:]')
  [[ "$dummy_before" == gone ]] \
    || { fail "$id: dummy reads '${dummy_before:-<unread>}' after modprobe -r, not gone"; return 1; }
  local sentinel; sentinel=$(lc_dmesg_sentinel) || { fail "$id: could not plant a dmesg sentinel"; return 1; }
  local mon_ready fw_pid fw_q0="<not read>"
  mon_ready=$(lc_hp_mon_start)
  if [[ "$mon_ready" != READY ]]; then
    lc_hp_mon_stop >/dev/null
    fail "$id: the udev add monitor on the guest never printed READY (got '${mon_ready:-<nothing>}')"
    return 1
  fi
  fw_pid=$(lc_hp_fwupd_pid)
  [[ "$fw_pid" =~ ^[1-9][0-9]*$ ]] && fw_q0=$(lc_hp_fwupd_queue "$fw_pid")
  local udev_l0
  udev_l0=$(ssh_vm -t 10 "$LC_HP_LISTENERS_SH" 2>/dev/null | tr -d '\r')
  local add_rc loaded link
  ssh_vm -t 20 'ip link add rhzhp0 type dummy' >/dev/null 2>&1; add_rc=$?
  loaded=$(ssh_vm -t 10 'test -d /sys/module/dummy && echo yes || echo no' 2>/dev/null | tr -d '[:space:]')
  link=$(ssh_vm -t 10 'ip -o link show rhzhp0 >/dev/null 2>&1 && echo yes || echo no' 2>/dev/null | tr -d '[:space:]')
  if (( add_rc != 0 )) || [[ "$loaded" != yes || "$link" != yes ]]; then
    ssh_vm -t 15 'ip link del rhzhp0 2>/dev/null; modprobe -r dummy' >/dev/null 2>&1
    lc_hp_mon_stop >/dev/null
    fail "$id: ip link add type dummy rc=$add_rc, module loaded=${loaded:-<unread>}, link=${link:-<unread>} (shell $shell_dom); denials: $({ lc_hp_avc "$sentinel" || echo '<window unread>'; } | head -3)"
    return 1
  fi

  local img="$VAR_DIR/rhzhp${SUFFIX:-}.img" kbd_mod_before evs ev="" ev_lbl="" ev_grp="" kbd_mod_after reply why=()
  kbd_mod_before=$(ssh_vm -t 15 'modprobe -r virtio_input 2>/dev/null; test -d /sys/module/virtio_input && echo yes || echo no' 2>/dev/null | tr -d '[:space:]')
  [[ "$kbd_mod_before" == no ]] \
    || { ssh_vm -t 15 'ip link del rhzhp0 2>/dev/null; modprobe -r dummy' >/dev/null 2>&1; lc_hp_mon_stop >/dev/null; fail "$id: virtio_input reads '${kbd_mod_before:-<unread>}' before the plug, not unloaded"; return 1; }
  truncate -s 16M "$img" || { ssh_vm -t 15 'ip link del rhzhp0 2>/dev/null; modprobe -r dummy' >/dev/null 2>&1; lc_hp_mon_stop >/dev/null; fail "$id: could not create $img"; return 1; }
  reply=$(lc_hp_qmp '{"execute":"device_add","arguments":{"driver":"virtio-keyboard-pci","id":"rhzhp_kbd","addr":"0x1e"}}')
  if [[ "$reply" == *'"error"'* ]]; then
    rm -f "$img"
    ssh_vm -t 15 'ip link del rhzhp0 2>/dev/null; modprobe -r dummy' >/dev/null 2>&1
    lc_hp_mon_stop >/dev/null
    fail "$id: QMP refused the virtio keyboard: $(tr '\n' ' ' <<<"$reply")"
    return 1
  fi
  lc_hp_qmp "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"raw\",\"node-name\":\"rhzhp\",\"file\":{\"driver\":\"file\",\"filename\":\"$img\"}}}" >/dev/null
  reply=$(lc_hp_qmp '{"execute":"device_add","arguments":{"driver":"virtio-blk-pci","drive":"rhzhp","id":"rhzhp_blk","serial":"rhzhp","addr":"0x1f"}}')
  [[ "$reply" == *'"error"'* ]] && why+=("QMP refused the virtio disk: $(tr '\n' ' ' <<<"$reply")")
  ssh_vm -t 45 'udevadm wait -t 30 /sys/bus/pci/devices/0000:00:1e.0 /dev/disk/by-id/virtio-rhzhp && udevadm settle -t 30' >/dev/null 2>&1
  evs=$(ssh_vm -t 10 'for e in /sys/class/input/event*; do readlink -f "$e/device" | grep -q "0000:00:1e.0" && echo "/dev/input/${e##*/}"; done' 2>/dev/null | tr -d '\r')
  ev=$(head -1 <<<"$evs")
  local blk blk_lbl=""
  blk=$(ssh_vm -t 10 'readlink -f /dev/disk/by-id/virtio-rhzhp' 2>/dev/null | tr -d '\r\n')
  if [[ -n "$ev" ]]; then
    ev_lbl=$(lc_hp_label "$ev")
    ev_grp=$(ssh_vm -t 10 "stat -c %G '$ev'" | tr -d '\r\n')
  fi
  [[ -n "$blk" ]] && blk_lbl=$(lc_hp_label "$blk")
  kbd_mod_after=$(ssh_vm -t 10 'test -d /sys/module/virtio_input && echo yes || echo no' | tr -d '[:space:]')

  lc_hp_qmp '{"execute":"device_del","arguments":{"id":"rhzhp_kbd"}}' >/dev/null
  lc_hp_qmp '{"execute":"device_del","arguments":{"id":"rhzhp_blk"}}' >/dev/null
  ssh_vm -t 45 'udevadm wait --removed -t 30 /dev/disk/by-id/virtio-rhzhp /sys/bus/pci/devices/0000:00:1e.0' >/dev/null 2>&1
  local gone; gone=$(ssh_vm -t 10 "test -e '${blk:-/nonexistent}' || test -e '${ev:-/nonexistent}' && echo present || echo gone" | tr -d '[:space:]')
  ssh_vm -t 15 'ip link del rhzhp0 2>/dev/null; modprobe -r dummy' >/dev/null 2>&1
  local mon fw_after fw_q1="<not read>" udev_l1
  udev_l1=$(ssh_vm -t 10 "$LC_HP_LISTENERS_SH" 2>/dev/null | tr -d '\r')
  mon=$(lc_hp_mon_stop)
  fw_after=$(lc_hp_fwupd_pid)
  [[ "$fw_pid" =~ ^[1-9][0-9]*$ ]] && fw_q1=$(lc_hp_fwupd_queue "$fw_pid")
  local denials
  denials=$(lc_hp_avc "$sentinel") \
    || why+=("the kmsg window from the autoload to the unplug was not read whole, lost a sentinel or dropped audit records")
  reply=$(lc_hp_qmp '{"execute":"blockdev-del","arguments":{"node-name":"rhzhp"}}')
  [[ "$reply" == *'"error"'* ]] && why+=("blockdev-del rhzhp refused, the disk may still be attached to this vm's QEMU: $(tr '\n' ' ' <<<"$reply")")
  rm -f "$img"

  local fw_due fw_left fw_pairs fw_want fw_adds fw_note="fwupd not running"
  if ! lc_done_strip mon; then
    why+=("the udev add monitor's log did not read back")
  elif ! grep -q '^ADD /module/dummy ' <<<"$mon"; then
    why+=("the udev add monitor logged no add of /module/dummy")
  elif [[ "$fw_pid" == '<unread>' || "$fw_pid" != "$fw_after" ]]; then
    why+=("fwupd.service's MainPID read '$fw_pid' before the window and '$fw_after' after it")
  elif (( fw_pid == 0 )); then
    :
  elif [[ "$fw_q0" != *' '* || "$fw_q1" != "0 ${fw_q0#* }" ]]; then
    why+=("fwupd's udev socket read '$fw_q0' (queued bytes, drops) at the window's start and '$fw_q1' at the monitor's stop, not empty with no new drop")
  elif ! fw_due=$(lc_hp_fwupd_due "$mon"); then
    why+=("$fw_due")
  else
    read -r fw_want fw_adds <<<"$fw_due"
    fw_left=$(lc_hp_dac_pairs "$fw_pid" <<<"$denials")
    fw_pairs=$(head -1 <<<"$fw_left")
    fw_pairs=${fw_pairs#PAIRS }
    denials=$(tail -n +2 <<<"$fw_left")
    [[ "$fw_pairs" == "$fw_want" ]] \
      || why+=("fwupd (pid $fw_pid) logged $fw_pairs dac_read_search/dac_override pairs where the window's $fw_adds adds of a uevent with no read bit derive $fw_want ($LC_HP_FWUPD_UEVENT_READS reads each)")
    fw_note="fwupd (pid $fw_pid) refused $fw_pairs uevent reads, all derived from $fw_adds adds of a uevent with no read bit"
  fi

  local udev_note="" sd_ver udevd_pid mon_pid udev_reads udev_kinds r_mgr r_mon r_wmod r_wdrv n_mod n_drv other
  local lst lst_pid lst_comm lst_want lst_left lst_pairs
  sd_ver=$(sed -n 's/^systemd=\([0-9]*\) .*/\1/p' <<<"$udev_l0")
  udevd_pid=$(sed -n 's/.* udevd=\([0-9]*\) .*/\1/p' <<<"$udev_l0")
  mon_pid=$(sed -n 's/.* mon=\([0-9]*\)$/\1/p' <<<"$udev_l0")
  if ! udev_reads=$(lc_hp_udev_reads "$sd_ver"); then
    why+=("systemd '${sd_ver:-<unread>}' (listeners read '${udev_l0:-<nothing>}'): how often its udev listeners read an unreadable uevent is not measured")
  elif [[ ! "$udevd_pid" =~ ^[1-9][0-9]*$ || ! "$mon_pid" =~ ^[1-9][0-9]*$ || "$udev_l1" != "$udev_l0" ]]; then
    why+=("udev's listeners read '${udev_l0:-<nothing>}' before the window and '${udev_l1:-<nothing>}' at the monitor's stop, not one systemd-udevd and one monitor across it")
  elif [[ "$udev_reads" != "0 0 0 0" ]] && ! udev_kinds=$(lc_hp_udev_kinds "$mon"); then
    why+=("$udev_kinds")
  elif [[ "$udev_reads" != "0 0 0 0" ]]; then
    read -r r_mgr r_mon r_wmod r_wdrv <<<"$udev_reads"
    read -r n_mod n_drv other <<<"$udev_kinds"
    [[ -z "$other" ]] \
      || why+=("the window added a uevent with no read bit outside a module or a driver ($other), whose udev reads systemd $sd_ver was not measured for")
    for lst in "$udevd_pid:systemd-udevd:$(( (n_mod + n_drv) * r_mgr ))" "$mon_pid:udevadm:$(( (n_mod + n_drv) * r_mon ))" \
               "any:(udev-worker):$(( n_mod * r_wmod + n_drv * r_wdrv ))"; do
      IFS=: read -r lst_pid lst_comm lst_want <<<"$lst"
      lst_left=$(lc_hp_dac_pairs "$lst_pid" "$lst_comm" <<<"$denials")
      lst_pairs=$(head -1 <<<"$lst_left"); lst_pairs=${lst_pairs#PAIRS }
      denials=$(tail -n +2 <<<"$lst_left")
      if [[ "$lst_pid" == any ]]; then
        (( lst_pairs <= lst_want )) \
          || why+=("$lst_comm (every pid) logged $lst_pairs dac_read_search/dac_override pairs where the window's $n_mod module and $n_drv driver adds of a uevent with no read bit derive at most $lst_want (systemd $sd_ver)")
      else
        [[ "$lst_pairs" == "$lst_want" ]] \
          || why+=("$lst_comm (pid $lst_pid) logged $lst_pairs dac_read_search/dac_override pairs where the window's $n_mod module and $n_drv driver adds of a uevent with no read bit derive $lst_want (systemd $sd_ver)")
      fi
    done
    udev_note=", systemd $sd_ver's udev refused the uevent reads $n_mod module and $n_drv driver adds derive (manager, workers and add monitor)"
  fi

  local bf_n
  bf_n=$(grep -cE "$LC_HP_BINFMT_RE" <<<"$denials")
  denials=$(grep -vE "$LC_HP_BINFMT_RE" <<<"$denials")

  [[ -n "$ev" && -n "$blk" ]] || why+=("nodes: event='${ev:-<none>}' disk='${blk:-<none>}'")
  [[ -z "$ev" || "$ev_lbl" == u:object_r:rhizo_host_device:s0 ]] || why+=("$ev is $ev_lbl")
  [[ -z "$blk" || "$blk_lbl" == u:object_r:rhizo_host_device:s0 ]] || why+=("$blk is $blk_lbl")
  [[ -z "$ev" || "$ev_grp" == input ]] || why+=("$ev group is '$ev_grp', udev's setattr did not land")
  [[ "$kbd_mod_after" == yes ]] || why+=("virtio_input not loaded after the plug")
  [[ "$gone" == gone ]] || why+=("a node outlived its device_del (${gone:-<unread>})")
  [[ -z "$denials" ]] || why+=("host denials: $(head -3 <<<"$denials" | tr '\n' ' ')")
  if (( ${#why[@]} )); then
    fail "$id: ${why[*]}"
    return 1
  fi
  pass "$id: dummy autoloaded through the kernel's helper (shell $shell_dom), a hot-plugged keyboard ($ev, group input, virtio_input loaded by the plug) and disk ($blk) got rhizo_host_device nodes, both removed on unplug, and no host process (rhizo_host or kernel) logged a denial from the autoload to the unplug past fwupd's derived share ($fw_note$udev_note) and $bf_n binfmt_misc remount(s) a service start made in its own namespace, which the policy's deny refuses and systemd skips"
}

# print the kmsg records of instance 0's start
lc_start_window() {
  awk '/RHIZO_MARKER launch_start sandbox=0([^0-9]|$)/ { buf = ""; on = 1; next }
       /RHIZO_MARKER launch_start sandbox=/ { on = 0 }
       on { buf = buf $0 "\n" }
       END { printf "%s", buf }' <<<"$1"
}

# check the start window's coldboot markers
lc_coldboot_verdict() {
  local win="$1" m failed why=()
  for m in coldboot=first-stage coldboot_shadow=ok coldboot_vold=ok; do
    grep -qF "RHIZO_MARKER $m" <<<"$win" || why+=("no RHIZO_MARKER $m")
  done
  failed=$(grep -oE 'RHIZO_MARKER coldboot[a-z_]*=failed reason=[^ ]*' <<<"$win" | tr '\n' ' ')
  [[ -z "$failed" ]] || why+=("${failed% }")
  grep -qE 'RHIZO_MARKER coldboot_vold=ok uevents=0( |$)' <<<"$win" \
    && why+=("coldboot_vold=ok covered 0 uevents")
  (( ${#why[@]} == 0 )) && return 0
  printf '%s' "${why[*]}"
  return 1
}

LC_KMON_SH='udevadm monitor --kernel | while read -r src ts act path rest; do if [ "$src $ts" = "KERNEL -" ]; then echo READY; continue; fi; case "$src" in KERNEL*) [ "$act" = add ] && echo "ADD $path";; esac; done'

# compare ADD lines to the pre-start device paths
lc_reannounce_verdict() {
  local again
  again=$(awk 'NR == FNR { pre[$0] = 1; next } $1 == "ADD" && ($2 in pre) { print $2 }' \
            <(printf '%s\n' "$1") <(printf '%s\n' "$2"))
  [[ -z "$again" ]] && return 0
  printf 'the host received an add for %d device(s) that existed before the start: %s' \
    "$(wc -l <<<"$again" | tr -d ' ')" "$(head -6 <<<"$again" | tr '\n' ' ')"
  return 1
}

# test hot-plugging a virtio disk
lc_late_disk_sunk() {
  local img="$VAR_DIR/rhznd${SUFFIX:-}.img" reply blk="" ue="" sentinel marker="" init mi why=()
  sentinel=$(lc_dmesg_sentinel) || { echo "could not plant a dmesg sentinel before the disk plug"; return 1; }
  truncate -s 16M "$img" || { echo "could not create $img"; return 1; }
  lc_hp_qmp "{\"execute\":\"blockdev-add\",\"arguments\":{\"driver\":\"raw\",\"node-name\":\"rhznd\",\"file\":{\"driver\":\"file\",\"filename\":\"$img\"}}}" >/dev/null
  reply=$(lc_hp_qmp '{"execute":"device_add","arguments":{"driver":"virtio-blk-pci","drive":"rhznd","id":"rhznd_blk","serial":"rhznd","addr":"0x1c"}}')
  if [[ "$reply" == *'"error"'* ]]; then
    why+=("QMP refused the late disk: $(tr '\n' ' ' <<<"$reply")")
  else
    ssh_vm -t 45 'udevadm wait -t 30 /dev/disk/by-id/virtio-rhznd && udevadm settle -t 30' >/dev/null 2>&1
    blk=$(ssh_vm -t 10 'readlink -f /dev/disk/by-id/virtio-rhznd' 2>/dev/null | tr -d '\r\n')
    [[ "$blk" == /dev/* ]] && ue=$(ssh_vm -t 10 "readlink -f /sys/class/block/${blk##*/}/uevent" 2>/dev/null | tr -d '\r\n')
    if [[ "$ue" != /sys/devices/*/uevent ]]; then
      why+=("the late disk never showed up on the host (by-id link '${blk:-<none>}', uevent '${ue:-<none>}')")
    else
      marker=$(ssh_vm -t 45 "timeout 30 sh -c 'until dmesg | sed -n \"/$sentinel/,\\\$p\" | grep -qaF \"RHIZO_MARKER block_sink=\"; do sleep 0.5; done'; dmesg | sed -n '/$sentinel/,\$p' | grep -aF 'RHIZO_MARKER block_sink='" 2>/dev/null | tr -d '\r')
      [[ "$marker" == *"block_sink=late bound="* ]] || why+=("no RHIZO_MARKER block_sink=late after the late disk's plug (got '${marker:-<nothing>}')")
      [[ "$marker" == *"block_sink=failed"* ]] && why+=("$(grep -oE 'RHIZO_MARKER block_sink=failed [^-]*' <<<"$marker" | head -1)")
      init=$(lc_resolve_init 30)
      if [[ "$init" =~ ^[1-9][0-9]*$ ]]; then
        mi=$(ssh_vm -t 10 "awk '\$5 == \"${ue}\"' /proc/$init/mountinfo | wc -l; echo DONE" 2>/dev/null | tr -d '\r')
        lc_done_strip mi || why+=("init's mountinfo did not read back")
        [[ "${mi//[[:space:]]/}" =~ ^[1-9][0-9]*$ ]] \
          || why+=("${ue} is not a mount point in init's mount namespace")
      else
        why+=("no sandbox init to read the mount namespace of")
      fi
    fi
  fi
  lc_hp_qmp '{"execute":"device_del","arguments":{"id":"rhznd_blk"}}' >/dev/null
  ssh_vm -t 45 'udevadm wait --removed -t 30 /dev/disk/by-id/virtio-rhznd' >/dev/null 2>&1
  reply=$(lc_hp_qmp '{"execute":"blockdev-del","arguments":{"node-name":"rhznd"}}')
  [[ "$reply" == *'"error"'* ]] && why+=("blockdev-del rhznd refused: $(tr '\n' ' ' <<<"$reply")")
  rm -f "$img"
  (( ${#why[@]} == 0 )) && return 0
  printf '%s' "${why[*]}"
  return 1
}

# test device adds across an Android start
lc_assert_host.no-device-reannounce() {
  local id=host.no-device-reannounce
  lc_need_guest "$id" || return 1
  local state pre ready t0 mon klog win why=() w kmon_sh
  ssh_vm -t 120 'systemctl stop androidd.service' >/dev/null 2>&1
  state=$(ssh_vm -t 20 'systemctl is-active androidd.service 2>/dev/null; echo DONE' | tr -d '\r')
  lc_done_strip state || { fail "$id: androidd.service's state did not read back after the stop"; return 1; }
  [[ "$state" == inactive || "$state" == failed ]] \
    || { fail "$id: androidd.service reads '$state' after systemctl stop"; return 1; }
  pre=$(ssh_vm -t 60 'find /sys/devices -name uevent -printf "%h\n" | sed "s#^/sys##"; echo DONE' 2>/dev/null | tr -d '\r')
  lc_done_strip pre || { fail "$id: the host's device list did not read back whole"; return 1; }
  kmon_sh=$(printf '%q' "$LC_KMON_SH")
  ready=$(ssh_vm -t 30 "systemctl stop rhizo-lc-kmon.service 2>/dev/null; systemctl reset-failed rhizo-lc-kmon.service 2>/dev/null; rm -f /run/rhizo-lc-kmon.log
systemd-run --quiet --collect --expand-environment=no --unit=rhizo-lc-kmon -p RuntimeMaxSec=900 -p StandardOutput=file:/run/rhizo-lc-kmon.log /bin/sh -c $kmon_sh || exit 1
for i in \$(seq 1 100); do grep -qx READY /run/rhizo-lc-kmon.log 2>/dev/null && echo READY && exit 0; sleep 0.1; done" 2>/dev/null | tr -d '\r')
  if [[ "$ready" != READY ]]; then
    ssh_vm -t 20 'systemctl stop rhizo-lc-kmon.service 2>/dev/null' >/dev/null 2>&1
    fail "$id: the host's kernel uevent monitor never printed READY (got '${ready:-<nothing>}')"
    return 1
  fi
  t0=$(guest_uptime)
  ssh_vm -t 600 'systemctl start androidd.service' >/dev/null 2>&1
  INIT=""
  if wait_sandbox_started 420 "$t0"; then INIT=$(resolve_init_pid 60); else why+=("the sandbox did not reach boot_completed after uptime $t0"); fi
  mon=$(ssh_vm -t 20 'systemctl stop rhizo-lc-kmon.service 2>/dev/null; grep "^ADD " /run/rhizo-lc-kmon.log; rm -f /run/rhizo-lc-kmon.log; echo DONE' 2>/dev/null | tr -d '\r')
  lc_done_strip mon || why+=("the host monitor's log did not read back")
  if (( ${#why[@]} == 0 )); then
    w=$(lc_reannounce_verdict "$pre" "$mon") || why+=("$w")
  fi
  klog=$(ssh_vm -t 30 'journalctl -k -b -o cat --no-pager; echo DONE' 2>/dev/null | tr -d '\r')
  if lc_done_strip klog; then
    win=$(lc_start_window "$klog")
    if [[ -z "$win" ]]; then
      why+=("no RHIZO_MARKER launch_start sandbox=0 in this boot's kernel journal")
    else
      w=$(lc_coldboot_verdict "$win") || why+=("the start's markers: $w")
    fi
  else
    why+=("this boot's kernel journal did not read back whole")
  fi
  w=$(lc_late_disk_sunk) || why+=("late disk: $w")
  if (( ${#why[@]} )); then
    fail "$id: ${why[*]}"
    return 1
  fi
  pass "$id: a host-netns kernel uevent monitor saw no add for any of the $(wc -l <<<"$pre" | tr -d ' ') devices present before a new Android start, that start's own markers name no failed staging step, and a disk plugged after it had its uevent sunk in the sandbox's mount namespace"
}

LC_INPUT_PHYS_PREFIX='rhizo-port-'

# print EventHub devices with a /dev/input node
lc_eventhub_devices() {
  awk '/^Event Hub State:/ { on = 1; next }
       on && /^[^ ]/ { on = 0 }
       on && /^    -?[0-9]+: / { name = $0; sub(/^ *-?[0-9]+: /, "", name) }
       on && $1 == "Path:" { path = $2 }
       on && $1 == "Location:" && path ~ /^\/dev\/input\// { print path, ($2 == "" ? "-" : $2), name; path = "" }' <<<"$1"
}

# strip the status line from a read
lc_listing() {
  local read="$1" tok="$2"
  [[ "$read" == *$'\n'"$tok=0" || "$read" == "$tok=0" ]] || return 1
  printf '%s' "${read%"$tok=0"}"
}

# test the host keyboard against Android
lc_input_verdict() {
  local why=() nodes devls usb devs owns path loc name
  if ! nodes=$(lc_listing "$LC_IN_NODES" LS_RC); then why+=("ls /dev/input did not complete: $(tail -1 <<<"$LC_IN_NODES")"); fi
  if ! devls=$(lc_listing "$LC_IN_DEVLS" LS_RC); then why+=("ls /dev did not complete: $(tail -1 <<<"$LC_IN_DEVLS")"); fi
  if ! usb=$(lc_listing "$LC_IN_USBFIND" FIND_RC); then why+=("find /dev/bus/usb did not complete: $(tail -1 <<<"$LC_IN_USBFIND")"); fi
  grep -qx "$LC_IN_EV" <<<"$nodes" && why+=("Android's /dev/input holds $LC_IN_EV, the host's keyboard")
  grep -qx "$LC_IN_HIDRAW" <<<"$devls" && why+=("Android's /dev holds $LC_IN_HIDRAW, the host keyboard's raw HID reports")
  [[ -z "$(tr -d '[:space:]' <<<"$usb")" ]] || why+=("Android's /dev/bus/usb holds $(tr '\n' ' ' <<<"$usb")")
  local made
  made=$(grep -E "RHIZO_MARKER input_fence=withheld node=/dev/(input/$LC_IN_EV|$LC_IN_HIDRAW|bus/usb/[0-9/]+) " <<<"$LC_IN_MARKERS" | grep -F ' removed=')
  [[ -z "$made" ]] || why+=("a node was made and then removed, not withheld: ${made%%$'\n'*}")
  local n
  for n in "/dev/input/$LC_IN_EV" "/dev/$LC_IN_HIDRAW"; do
    grep -qF "Cannot chown $n " <<<"$LC_IN_UEVENTD" \
      || why+=("ueventd logged no refused node for $n")
  done
  [[ -n "$LC_IN_UEVENTD_PID0" && "$LC_IN_UEVENTD_PID0" == "$LC_IN_UEVENTD_PID1" ]] \
    || why+=("ueventd's pid went from '${LC_IN_UEVENTD_PID0:-<none>}' to '${LC_IN_UEVENTD_PID1:-<none>}' across the refused nodes")
  devs=$(lc_eventhub_devices "$LC_IN_DUMP")
  [[ -n "$devs" ]] || why+=("dumpsys input listed no EventHub device with a /dev/input node")
  while read -r path loc name; do
    [[ -n "$path" ]] || continue
    [[ "$path" == "/dev/input/$LC_IN_EV" ]] && why+=("EventHub opened $path ($name), the host's keyboard")
  done <<<"$devs"
  grep -q "^[^ ]* ${LC_IN_PREFIX}0 " <<<"$devs" || why+=("EventHub lists no device at ${LC_IN_PREFIX}0, the composer's own")
  owns=$(lc_eventhub_devices "$LC_IN_OWN_DUMP")
  grep -q " $LC_IN_FORGED_PHYS\$" <<<"$LC_IN_FORGED_HOST" \
    || why+=("the forged device never existed on the host with phys $LC_IN_FORGED_PHYS: ${LC_IN_FORGED_HOST:-<none>}")
  while read -r path loc name; do
    [[ -n "$path" && "$name" == "$LC_IN_FORGED_NAME" ]] || continue
    why+=("EventHub opened $path, the host's device $LC_IN_FORGED_NAME forged with this instance's phys $loc")
    break
  done < <(printf '%s\n%s\n' "$devs" "$owns")
  grep -q " ${LC_IN_OWN_NAME}\$" <<<"$owns" \
    || why+=("EventHub never opened $LC_IN_OWN_NAME, the uinput device Android's own shell created")
  local want
  for want in cuse=loaded uhid-node=present "units=active active"; do
    grep -qxF "$want" <<<"$LC_IN_BROKER" || why+=("the host does not report $want (got: $(tr '\n' ' ' <<<"$LC_IN_BROKER"))")
  done
  grep -qE '^registered=[1-9]' <<<"$LC_IN_BROKER" || why+=("the supervisor's journal registers no device this boot")
  grep -q '^supervisor-label=.*:rhizo_inputd:' <<<"$LC_IN_BROKER" \
    || why+=("the supervisor does not run in rhizo_inputd ($(grep '^supervisor-label=' <<<"$LC_IN_BROKER"))")
  grep -q '^broker-label=.*:rhizo_uhidd:' <<<"$LC_IN_BROKER" \
    || why+=("the uhid broker does not run in rhizo_uhidd ($(grep '^broker-label=' <<<"$LC_IN_BROKER"))")
  grep -qxF "restarted=active active" <<<"$LC_IN_RESTART" \
    || why+=("a supervisor restart under enforcement did not come back active: ${LC_IN_RESTART:-<no answer>}")
  grep -qxF "broker-renewed=yes" <<<"$LC_IN_RESTART" \
    || why+=("the uhid broker kept its pid across the supervisor restart: $(grep '^broker-pids=' <<<"$LC_IN_RESTART")")
  grep -qxF "enforce=1" <<<"$LC_IN_BROKER" || why+=("the host is not enforcing")
  [[ -n "$LC_IN_CURSOR" ]] || why+=("no journal cursor was read before the restart")
  grep -qE '^fdstore=([2-9]|[1-9][0-9])$' <<<"$LC_IN_BROKER" \
    || why+=("the supervisor's fd store holds $(grep '^fdstore=' <<<"$LC_IN_BROKER"), not its listener and CUSE channel")
  grep -qE '^sup-adopted=[1-9]' <<<"$LC_IN_BROKER" \
    || why+=("the restarted supervisor's journal has no adopted listener and CUSE channel")
  grep -qE '^sup-registered=[1-9]' <<<"$LC_IN_BROKER" \
    || why+=("the restarted supervisor's journal registers nothing")
  grep -qE '^broker-created=[1-9]' <<<"$LC_IN_BROKER" \
    || why+=("the restarted broker's journal records no uhid create")
  grep -qxF "LIBINPUT_IGNORE_DEVICE=1" <<<"$LC_IN_HOSTPROP" \
    || why+=("the host's udev left $LC_IN_OWN_NAME to the host's libinput: $(tr '\n' ' ' <<<"${LC_IN_HOSTPROP:-<no properties>}")")
  [[ -n "$LC_IN_ID" ]] \
    || why+=("Android's /dev/uhid (${LC_IN_UHID_DEV:-<unread>}) is none of the host's CUSE devices: $(tr '\n' ' ' <<<"${LC_IN_CUSE:-<none>}")")
  grep -q '^HIDNODE=event[0-9]' <<<"$LC_IN_HID_OUT" \
    || why+=("Android's hid command created no input node: $(grep '^HIDNODE=' <<<"$LC_IN_HID_OUT")")
  grep -q '^EV .*KEY_A .*DOWN' <<<"$LC_IN_HID_OUT" \
    || why+=("a key the hid device reported never reached Android's getevent: $(grep '^EV ' <<<"$LC_IN_HID_OUT" | tr '\n' ' ')")
  grep -q " ${LC_IN_HID_NAME}\$" <<<"$(lc_eventhub_devices "$LC_IN_HID_OUT")" \
    || why+=("EventHub never opened $LC_IN_HID_NAME, the uhid device Android's own shell created")
  grep -qxF "LIBINPUT_IGNORE_DEVICE=1" <<<"$LC_IN_HIDPROP" \
    || why+=("the host's udev left $LC_IN_HID_NAME to the host's libinput: $(tr '\n' ' ' <<<"${LC_IN_HIDPROP:-<no properties>}")")
  grep -q "^PHYS=rhizo-uhid-${LC_IN_ID:-none}-[0-9a-f]\{16\}\$" <<<"$LC_IN_HIDPROP" \
    || why+=("$LC_IN_HID_NAME's phys is not this instance's broker token: $(grep '^PHYS=' <<<"$LC_IN_HIDPROP")")
  (( ${#why[@]} == 0 )) && return 0
  printf '%s' "${why[*]}"
  return 1
}

LC_IN_OWN_JSON='{"id":1,"command":"register","name":"rhizo-lc-own","vid":6353,"pid":1,"bus":"usb","configuration":[{"type":"UI_SET_EVBIT","data":["EV_KEY"]},{"type":"UI_SET_KEYBIT","data":["KEY_A"]}]}'
LC_IN_HID_NAME=rhizo-lc-hid
LC_IN_HID_SH='f=/data/local/tmp/rhizo-lc-hid; rm -f $f.ev
exec 4>&1
{ echo '"'"'{"id":1,"command":"register","name":"rhizo-lc-hid","vid":6353,"pid":2,"bus":"usb","descriptor":[5,1,9,6,161,1,5,7,25,224,41,231,21,0,37,1,117,1,149,8,129,2,149,1,117,8,129,1,149,6,117,8,21,0,37,101,5,7,25,0,41,101,129,0,192]}'"'"'
n=; for i in $(seq 1 50); do n=$(getevent -p 2>/dev/null | awk '"'"'/^add device/ {d=$4} /name:/ && /"rhizo-lc-hid"/ {print d}'"'"' | head -1); [ -n "$n" ] && break; sleep 0.1; done
echo HIDNODE=${n#/dev/input/} >&4
timeout 5 getevent -l $n > $f.ev 2>&1 &
g=$!; sleep 1
echo '"'"'{"id":1,"command":"report","report":[0,0,4,0,0,0,0,0]}'"'"'
echo '"'"'{"id":1,"command":"report","report":[0,0,0,0,0,0,0,0]}'"'"'
wait $g; sed "s/^/EV /" $f.ev >&4
(sleep 40 4>&- &)
} | (exec 5<&0; hid - <&5 >/dev/null 2>&1 4>&- 5<&- &)
i=0; while [ $i -lt 75 ]; do dumpsys input | grep -q " rhizo-lc-hid$" && break; sleep 0.2; i=$((i + 1)); done
dumpsys input'

LC_IN_FORGED_NAME=rhizo-lc-forged
LC_IN_FORGE_PY='import fcntl,os,struct,sys,time
f=os.open("/dev/uinput",os.O_WRONLY|os.O_NONBLOCK)
fcntl.ioctl(f,0x40045564,1); fcntl.ioctl(f,0x40045565,30)
fcntl.ioctl(f,0x4008556c,sys.argv[1].encode()+b"\0")
fcntl.ioctl(f,0x405c5503,struct.pack("HHHH80sI",3,1,1,1,sys.argv[2].encode(),0))
fcntl.ioctl(f,0x5501); print("CREATED",flush=True); time.sleep(240)'

# print the instance id of a CUSE device
lc_input_cuse_id() {
  local maj min
  read -r maj min <<<"$1"
  [[ "$maj" =~ ^[0-9a-f]+$ && "$min" =~ ^[0-9a-f]+$ ]] || return 0
  awk -v want="$((16#$maj)):$((16#$min))" '$2 == want && $1 ~ /^rhizo-[0-9]+-uhid$/ { n++; id = $1 }
       END { if (n == 1) { sub(/^rhizo-/, "", id); sub(/-uhid$/, "", id); print id } }' <<<"$2"
}

# wait for ueventd to log the input node
lc_input_ueventd_acted() {
  ssh_vm -t 45 "timeout 30 sh -c 'until dmesg | awk -v s=\"$1\" \"f{print} index(\\\$0,s){f=1}\" | grep -qE \"Cannot chown /dev/input/$2 |input_fence=withheld node=/dev/input/$2 .*removed=\"; do sleep 0.2; done' && echo ACTED" 2>/dev/null | tr -d '\r'
}

# test a hot-plugged host keyboard against Android
lc_assert_sandbox.host-input-invisible() {
  local id=sandbox.host-input-invisible
  rm -f "$EV"/host-input-invisible-*.log
  lc_need_guest "$id" || return 1
  [[ -S "${QMP_SOCK:-}" ]] || { fail "$id: no QMP socket at '${QMP_SOCK:-}'"; return 1; }
  local init; init=$(lc_resolve_init 60)
  [[ -n "$init" ]] || { fail "$id: no sandbox init to read Android's input devices from"; return 1; }
  local sentinel reply acted why rc forge_py lc_in_t0 lc_in_ehlog
  sentinel=$(lc_dmesg_sentinel) || { fail "$id: could not plant a dmesg sentinel"; return 1; }
  LC_IN_UEVENTD_PID0=$(android_sh "$init" 'pidof ueventd' | tr -d '\r[:space:]')
  reply=$(lc_hp_qmp '{"execute":"device_add","arguments":{"driver":"qemu-xhci","id":"rhzin_xhci","addr":"0x1d"}}')
  if [[ -z "$reply" || "$reply" == *'"error"'* ]]; then
    fail "$id: QMP refused the USB controller: $(tr '\n' ' ' <<<"${reply:-<no reply>}")"
    return 1
  fi
  reply=$(lc_hp_qmp '{"execute":"device_add","arguments":{"driver":"usb-kbd","id":"rhzin_ukbd","bus":"rhzin_xhci.0"}}')
  ssh_vm -t 45 'udevadm wait -t 30 /sys/bus/pci/devices/0000:00:1d.0 && udevadm settle -t 30' >/dev/null 2>&1
  LC_IN_EV=$(ssh_vm -t 10 'for e in /sys/class/input/event*; do readlink -f "$e/device" | grep -q "0000:00:1d.0" && echo "${e##*/}"; done' 2>/dev/null | tr -d '\r' | head -1)
  LC_IN_HIDRAW=$(ssh_vm -t 10 'for e in /sys/class/hidraw/hidraw*; do readlink -f "$e" | grep -q "0000:00:1d.0" && echo "${e##*/}"; done' 2>/dev/null | tr -d '\r' | head -1)
  acted=$(lc_input_ueventd_acted "$sentinel" "${LC_IN_EV:-none}")
  LC_IN_NODES=$(android_sh "$init" 'ls /dev/input; echo LS_RC=$?' | tr -d '\r')
  LC_IN_DEVLS=$(android_sh "$init" 'ls /dev; echo LS_RC=$?' | tr -d '\r')
  LC_IN_USBFIND=$(android_sh "$init" 'if [ -d /dev/bus/usb ]; then find /dev/bus/usb -type c; fi; echo FIND_RC=$?' | tr -d '\r')
  LC_IN_FORGED_PHYS="${LC_INPUT_PHYS_PREFIX}7"
  forge_py=$(printf '%q' "$LC_IN_FORGE_PY")
  ssh_vm -t 20 "systemctl stop rhizo-lc-forge.service 2>/dev/null; systemctl reset-failed rhizo-lc-forge.service 2>/dev/null; systemd-run --quiet --collect --expand-environment=no --unit=rhizo-lc-forge -p RuntimeMaxSec=300 python3 -c $forge_py '$LC_IN_FORGED_PHYS' '$LC_IN_FORGED_NAME'" >/dev/null 2>&1
  LC_IN_FORGED_HOST=$(ssh_vm -t 25 "n=$LC_IN_FORGED_NAME; "'r() { for e in /sys/class/input/event*; do [ "$(cat $e/device/name 2>/dev/null)" = "$n" ] && echo "${e##*/} $(cat $e/device/phys)"; done; }; i=0; while [ $i -lt 75 ] && [ -z "$(r)" ]; do sleep 0.2; i=$((i + 1)); done; r' 2>/dev/null | tr -d '\r')
  LC_IN_DUMP=$(android_sh "$init" 'dumpsys input' | tr -d '\r')
  LC_IN_OWN_NAME=rhizo-lc-own
  LC_IN_UHID_DEV=$(android_sh "$init" 'stat -c "%t %T" /dev/uhid' | tr -d '\r')
  LC_IN_CUSE=$(ssh_vm -t 10 'for d in /sys/class/cuse/rhizo-*-uhid; do [ -e "$d/dev" ] && echo "${d##*/} $(cat "$d/dev")"; done' 2>/dev/null | tr -d '\r')
  LC_IN_ID=$(lc_input_cuse_id "$LC_IN_UHID_DEV" "$LC_IN_CUSE")
  LC_IN_CURSOR=$(ssh_vm -t 10 'journalctl -n 0 --show-cursor' 2>/dev/null | tr -d '\r' | sed -n 's/^-- cursor: //p')
  lc_in_t0=$(android_sh "$init" 'date +"%m-%d %H:%M:%S.000"' | tr -d '\r')
  LC_IN_RESTART=$(ssh_vm -t 150 "b0=\$(systemctl show -p MainPID --value rhizo-inputd-uhid@${LC_IN_ID:-none}.service); systemctl restart rhizo-inputd@${LC_IN_ID:-none}.service; timeout 60 sh -c 'while [ -n \"\$(systemctl show -p Job --value rhizo-inputd-uhid@${LC_IN_ID:-none}.service)\" ]; do sleep 0.1; done'; b1=\$(systemctl show -p MainPID --value rhizo-inputd-uhid@${LC_IN_ID:-none}.service); echo \"broker-pids=\${b0:-none} \${b1:-none}\"; echo \"broker-renewed=\$([ -n \"\$b0\" ] && [ \"\$b0\" != 0 ] && [ -n \"\$b1\" ] && [ \"\$b1\" != 0 ] && [ \"\$b0\" != \"\$b1\" ] && echo yes || echo no)\"; echo \"restarted=\$(systemctl is-active rhizo-inputd@${LC_IN_ID:-none}.service rhizo-inputd-uhid@${LC_IN_ID:-none}.service | tr '\n' ' ' | sed 's/ \$//')\""  2>/dev/null | tr -d '\r')
  LC_IN_OWN_DUMP=$(android_sh "$init" "(echo '$LC_IN_OWN_JSON'; sleep 20) | uinput - >/dev/null 2>&1 & i=0; while [ \$i -lt 75 ]; do dumpsys input | grep -q ' rhizo-lc-own\$' && break; sleep 0.2; i=\$((i + 1)); done; dumpsys input" | tr -d '\r')
  LC_IN_HOSTPROP=$(ssh_vm -t 20 'for e in /sys/class/input/event*; do grep -qx rhizo-lc-own "$e/device/name" 2>/dev/null && udevadm info -q property -p "$e"; done' 2>/dev/null | tr -d '\r')
  LC_IN_HID_OUT=$(android_sh "$init" "$LC_IN_HID_SH" | tr -d '\r')
  LC_IN_HIDPROP=$(ssh_vm -t 20 'for e in /sys/class/input/event*; do grep -qx rhizo-lc-hid "$e/device/name" 2>/dev/null && udevadm info -q property -p "$e" && echo "PHYS=$(cat "$e/device/phys")"; done' 2>/dev/null | tr -d '\r')
  LC_IN_BROKER=$(ssh_vm -t 20 "test -d /sys/module/cuse && echo cuse=loaded; test -e /sys/class/cuse/rhizo-${LC_IN_ID:-none}-uhid && echo uhid-node=present; echo \"units=\$(systemctl is-active rhizo-inputd@${LC_IN_ID:-none}.service rhizo-inputd-uhid@${LC_IN_ID:-none}.service | tr '\n' ' ' | sed 's/ \$//')\"; echo \"registered=\$(journalctl -b -u rhizo-inputd@${LC_IN_ID:-none}.service -o cat | grep -c '^rhizo-inputd supervise: RHIZO_MARKER input_owner=registered ')\"; for u in inputd inputd-uhid; do p=\$(systemctl show -p MainPID --value rhizo-\$u@${LC_IN_ID:-none}.service); echo \"\$([ \$u = inputd ] && echo supervisor || echo broker)-label=\$(cat /proc/\$p/attr/current 2>/dev/null | tr -d '\\0')\"; done; echo \"enforce=\$(cat /sys/fs/selinux/enforce)\"; echo \"fdstore=\$(systemctl show -p NFileDescriptorStore --value rhizo-inputd@${LC_IN_ID:-none}.service)\"; sp=\$(systemctl show -p MainPID --value rhizo-inputd@${LC_IN_ID:-none}.service); bp=\$(systemctl show -p MainPID --value rhizo-inputd-uhid@${LC_IN_ID:-none}.service); echo \"sup-adopted=\$(journalctl --after-cursor='${LC_IN_CURSOR:-none}' _PID=\$sp -o cat | grep -c '^rhizo-inputd supervise: RHIZO_MARKER input_owner=adopted listener=yes cuse=yes\$')\"; echo \"sup-registered=\$(journalctl --after-cursor='${LC_IN_CURSOR:-none}' _PID=\$sp -o cat | grep -c '^rhizo-inputd supervise: RHIZO_MARKER input_owner=registered ')\"; echo \"broker-created=\$(journalctl --after-cursor='${LC_IN_CURSOR:-none}' _PID=\$bp -o cat | grep -c '^rhizo-inputd uhid: RHIZO_MARKER input_owner=uhid-created ')\"" 2>/dev/null | tr -d '\r')
  ssh_vm -t 20 'systemctl stop rhizo-lc-forge.service 2>/dev/null' >/dev/null 2>&1
  LC_IN_MARKERS=$(lc_dmesg_since "$sentinel" 'RHIZO_MARKER input_fence=')
  LC_IN_UEVENTD=$(lc_dmesg_since "$sentinel" 'Cannot chown ')
  LC_IN_UEVENTD_PID1=$(android_sh "$init" 'pidof ueventd' | tr -d '\r[:space:]')
  LC_IN_PREFIX="$LC_INPUT_PHYS_PREFIX"
  lc_in_ehlog=""
  [[ -n "$lc_in_t0" ]] && lc_in_ehlog=$(android_sh "$init" "logcat -d -v threadtime -t '$lc_in_t0' -s EventHub" | tr -d '\r')
  printf '%s\n' "${LC_IN_OWN_DUMP:-<none: dumpsys input read nothing while rhizo-lc-own lived>}" \
    >"$EV/host-input-invisible-own-dump.log"
  printf '%s\n' "${LC_IN_HID_OUT:-<none: the hid run printed nothing>}" >"$EV/host-input-invisible-hid-out.log"
  printf '%s\n' "${lc_in_ehlog:-<none: no EventHub line since '${lc_in_t0:-<no guest time read>}'>}" \
    >"$EV/host-input-invisible-eventhub-logcat.log"
  lc_hp_qmp '{"execute":"device_del","arguments":{"id":"rhzin_ukbd"}}' >/dev/null
  lc_hp_qmp '{"execute":"device_del","arguments":{"id":"rhzin_xhci"}}' >/dev/null
  ssh_vm -t 45 'udevadm wait --removed -t 30 /sys/bus/pci/devices/0000:00:1d.0' >/dev/null 2>&1
  [[ -n "$LC_IN_EV" && -n "$LC_IN_HIDRAW" ]] \
    || { fail "$id: the host USB keyboard got event '${LC_IN_EV:-<none>}' and hidraw '${LC_IN_HIDRAW:-<none>}' on the host, not both"; return 1; }
  [[ "$acted" == ACTED ]] \
    || { fail "$id: within 30s the sandbox's ueventd reported no refused node for $LC_IN_EV and the fence removed none"; return 1; }
  why=$(lc_input_verdict); rc=$?
  (( rc == 0 )) || { fail "$id: $why"; return 1; }
  pass "$id: a USB keyboard plugged into the host after Android started ($LC_IN_EV, $LC_IN_HIDRAW) got no evdev, hidraw or usbfs node and no EventHub device, ueventd was refused each node and kept running, a host device forging this instance's phys stayed out, the composer's devices and Android's own uinput device reached EventHub through rhizo-inputd (cuse loaded, both units active in their own types), Android's own hid keyboard on /dev/uhid -- instance $LC_IN_ID's CUSE device -- delivered a key to getevent and EventHub carrying its broker's token, and the host's libinput ignores both of Android's own"
}
