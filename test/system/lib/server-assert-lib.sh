#!/bin/bash
# define server-mode assertions and guest probes

_SERVER_ASSERT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fail when the adb-tunnel.sh log shows a tap on an authorization dialog
assert_adb_no_tap() {
  local label="$1" log="$2"
  if grep -q "clearing the real 'Allow USB debugging?' dialog" <<<"$log"; then
    fail "$label: adb-tunnel.sh cleared an authorization dialog"
    return 1
  fi
  if ! grep -q "ADB BRIDGE UP" <<<"$log"; then
    fail "$label: adb-tunnel.sh never reported the bridge up: $(tail -3 <<<"$log")"
    return 1
  fi
  pass "$label: adb reached 'device' with no tap"
}

# check the sys.boot_completed property
assert_boot_completed() {
  local label="$1" v="$2"
  [[ "$v" == "1" ]] || { fail "$label: sys.boot_completed='${v:-<empty>}', wanted 1"; return 1; }
  pass "$label: sys.boot_completed=1"
}

# check for a compositor socket
assert_no_wayland_socket() {
  local label="$1" out="$2" complete="${3:-1}"
  if [[ "$complete" != 1 ]]; then
    fail "$label: the remote probe never completed (no sentinel read back)"
    return 1
  fi
  if [[ -n "${out//[[:space:]]/}" ]]; then
    fail "$label: a compositor socket exists for the sandbox to bind: $out"
    return 1
  fi
  pass "$label: no compositor socket under /run/user/<uid> or /run/rhizo-wayland"
}

# check the boot log for the headless marker
assert_headless_marker() {
  local label="$1" out="$2"
  grep -q 'wayland socket NOT FOUND' <<<"$out" \
    || { fail "$label: the launcher never reported a headless boot (no 'wayland socket NOT FOUND' marker): $(tail -2 <<<"$out")"; return 1; }
  pass "$label: the launcher reported this boot presents nothing"
}

# check the guest for a compositor process
assert_no_compositor_process() {
  local label="$1" out="$2" complete="${3:-1}"
  if [[ "$complete" != 1 ]]; then
    fail "$label: the remote probe never completed (no sentinel read back)"
    return 1
  fi
  [[ -z "${out//[[:space:]]/}" ]] || { fail "$label: a compositor process is running on the guest: $out"; return 1; }
  pass "$label: no sway or weston process on the guest"
}

# check the masked state of a unit
assert_unit_masked() {
  local label="$1" unit="$2" out="$3" load active
  load=$(grep -m1 '^LoadState=' <<<"$out" | cut -d= -f2)
  active=$(grep -m1 '^ActiveState=' <<<"$out" | cut -d= -f2)
  if [[ "$load" == masked && "$active" == inactive ]]; then
    pass "$label: $unit is inactive (masked)"
    return 0
  fi
  fail "$label: $unit is LoadState=${load:-<none>} ActiveState=${active:-<none>}, wanted masked/inactive"
  return 1
}

# check the loaded state of a unit
assert_unit_unmasked() {
  local label="$1" unit="$2" out="$3" load
  load=$(grep -m1 '^LoadState=' <<<"$out" | cut -d= -f2)
  if [[ "$load" == loaded ]]; then
    pass "$label: $unit is loaded (not masked)"
    return 0
  fi
  fail "$label: $unit is LoadState=${load:-<none>}, wanted loaded (not masked)"
  return 1
}

# check the active state of a unit
assert_unit_active() {
  local label="$1" unit="$2" out="$3" load active
  load=$(grep -m1 '^LoadState=' <<<"$out" | cut -d= -f2)
  active=$(grep -m1 '^ActiveState=' <<<"$out" | cut -d= -f2)
  if [[ "$load" == loaded && "$active" == active ]]; then
    pass "$label: $unit is active"
    return 0
  fi
  fail "$label: $unit is LoadState=${load:-<none>} ActiveState=${active:-<none>}, wanted loaded/active"
  return 1
}

# check the profile=server line
assert_profile_applied() {
  local label="$1" out="$2"
  grep -q '^RHIZO_PROFILE profile=server$' <<<"$out" \
    || { fail "$label: no 'RHIZO_PROFILE profile=server' line: $(tail -2 <<<"$out")"; return 1; }
  pass "$label: the CLI reports profile=server"
}

# check policy.conf contains the settings
assert_policy_written() {
  local label="$1" out="$2" reach="$3" idle="$4" dri="$5" want miss=""
  for want in "profile = server" "adb_reach = $reach" "idle_stop_s = $idle" \
              "display = $DISPLAY_GEOMETRY" "screen_off_s = $SCREEN_OFF_S" "dri = $dri"; do
    grep -qxF "$want" <<<"$out" || miss+="'$want' "
  done
  [[ -z "$miss" ]] || { fail "$label: $POLICY_CONF does not carry $miss(it reads: $(tr '\n' ' ' <<<"$out"))"; return 1; }
  pass "$label: $POLICY_CONF carries adb_reach=$reach idle_stop_s=$idle dri=$dri"
}

# check the adb key registration output
assert_adbkey_registered() {
  local label="$1" add="$2" list="$3" n
  grep -q '^RHIZO_ADBKEY added=1$' <<<"$add" \
    || { fail "$label: 'rhizo adb-key add' did not report added=1: $(tail -2 <<<"$add")"; return 1; }
  n=$(sed -n 's/^RHIZO_ADBKEY list=//p' <<<"$list" | head -1)
  if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
    fail "$label: 'rhizo adb-key list' reports ${n:-<no list= line>} registered key(s), wanted at least 1"
    return 1
  fi
  pass "$label: the operator key is registered ($n in $POLICY_CONF's own directory)"
}

# check the status json fields
assert_status_json() {
  local label="$1" out="$2" bad
  bad=$(python3 -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError as exc:
    print("not JSON: %s" % exc); raise SystemExit
bad = []
if d.get("profile") != "server":
    bad.append("profile=%r" % d.get("profile"))
if d.get("boot_completed") != "1":
    bad.append("boot_completed=%r" % d.get("boot_completed"))
if not d.get("adb"):
    bad.append("adb=%r" % d.get("adb"))
if not d.get("adb_keys"):
    bad.append("adb_keys=%r" % d.get("adb_keys"))
print("; ".join(bad))' "$out" 2>&1)
  [[ -z "$bad" ]] || { fail "$label: rhizo status --json reports $bad"; return 1; }
  pass "$label: status --json reports profile=server, boot_completed=1, an adb endpoint and a registered key"
}

# check doctor output for the adb endpoint
assert_doctor_server() {
  local label="$1" out="$2"
  grep -q 'adb endpoint: ' <<<"$out" \
    || { fail "$label: rhizo doctor printed no adb endpoint line under the server profile"; return 1; }
  grep -q 'adb endpoint: not running$' <<<"$out" \
    && { fail "$label: rhizo doctor reports the sandbox is not running"; return 1; }
  grep -qE '^RHIZO_DOCTOR_(OK|ISSUES) ' <<<"$out" \
    || { fail "$label: rhizo doctor printed no RHIZO_DOCTOR_ sentinel: $(tail -2 <<<"$out")"; return 1; }
  grep -q '^RHIZO_DOCTOR_ISSUES ' <<<"$out" \
    && { fail "$label: rhizo doctor reports issues: $(grep ': fail -- ' <<<"$out" | tr '\n' ' ')"; return 1; }
  pass "$label: rhizo doctor is clean and reports the adb endpoint"
}

# check the display size and density
assert_display_geometry() {
  local label="$1" out="$2" want_wh="$3" want_dpi="$4" real dens
  real=$(grep -oE 'real [0-9]+ x [0-9]+' <<<"$out" | head -1 | sed -E 's/real ([0-9]+) x ([0-9]+)/\1x\2/')
  dens=$(grep -oE 'density [0-9]+' <<<"$out" | head -1 | grep -oE '[0-9]+')
  if [[ "$real" != "$want_wh" ]]; then
    fail "$label: dumpsys display reports real=${real:-<none>}, wanted $want_wh"
    return 1
  fi
  if [[ "$dens" != "$want_dpi" ]]; then
    fail "$label: dumpsys display reports density=${dens:-<none>}, wanted $want_dpi"
    return 1
  fi
  pass "$label: ${real} at ${dens}dpi"
}

# compare ro.sf.lcd_density with the given dpi
assert_sf_density() {
  local label="$1" got="$2" want="$3"
  [[ "$got" == "$want" ]] || { fail "$label: ro.sf.lcd_density='${got:-<empty>}', wanted $want"; return 1; }
  pass "$label: ro.sf.lcd_density=$got"
}

CLIENT_TARGET_MIN_RGB_PCT=50

# test the composer sample for painted pixels
client_target_is_painted() {
  local line wh rgbpct
  line=$(grep -oE 'CLIENT TARGET display=[0-9]+ [0-9]+x[0-9]+ stride=[0-9]+ sampled=[0-9]+ nonZero=[0-9]+ \([0-9]+%\) rgbNonZero=[0-9]+ \([0-9]+%\)' <<<"$1" | tail -1)
  [[ -n "$line" ]] || return 1
  wh=$(grep -oE '[0-9]+x[0-9]+' <<<"$line" | head -1)
  rgbpct=$(grep -oE 'rgbNonZero=[0-9]+ \([0-9]+%\)' <<<"$line" | grep -oE '[0-9]+%' | tr -d '%')
  [[ "$wh" == "$2" ]] || return 1
  [[ "$rgbpct" =~ ^[0-9]+$ ]] && (( rgbpct > CLIENT_TARGET_MIN_RGB_PCT ))
}

# check the composer sample for painted pixels
assert_client_target_painted() {
  local label="$1" out="$2" want_wh="$3" line wh rgbpct
  line=$(grep -oE 'CLIENT TARGET display=[0-9]+ [0-9]+x[0-9]+ stride=[0-9]+ sampled=[0-9]+ nonZero=[0-9]+ \([0-9]+%\) rgbNonZero=[0-9]+ \([0-9]+%\)' <<<"$out" | tail -1)
  if [[ -z "$line" ]]; then
    fail "$label: no 'CLIENT TARGET' sample line at all"
    return 1
  fi
  wh=$(grep -oE '[0-9]+x[0-9]+' <<<"$line" | head -1)
  rgbpct=$(grep -oE 'rgbNonZero=[0-9]+ \([0-9]+%\)' <<<"$line" | grep -oE '[0-9]+%' | tr -d '%')
  if [[ "$wh" != "$want_wh" ]]; then
    fail "$label: the composer's client-target sample is ${wh:-<none>}, wanted $want_wh"
    return 1
  fi
  if [[ ! "$rgbpct" =~ ^[0-9]+$ ]] || (( rgbpct <= CLIENT_TARGET_MIN_RGB_PCT )); then
    fail "$label: the composer's client-target sample is only ${rgbpct:-<none>}% non-black RGB at the right size"
    return 1
  fi
  pass "$label: a ${wh} client-target sample, ${rgbpct}% non-black RGB ($line)"
}

# check the screen_off_timeout setting value
assert_screen_off_setting() {
  local label="$1" got="$2" want_s="$3" want_ms
  want_ms=$((want_s * 1000))
  got=$(tr -d '[:space:]' <<<"$got")
  [[ "$got" == "$want_ms" ]] || { fail "$label: settings get system screen_off_timeout=${got:-<empty>}, wanted $want_ms (${want_s}s)"; return 1; }
  pass "$label: screen_off_timeout=${got}ms"
}

# check dumpsys reports wakefulness Asleep and state OFF
assert_display_off() {
  local label="$1" power="$2" display="$3" wake state
  wake=$(grep -m1 -oE 'mWakefulness=[A-Za-z]+' <<<"$power" | cut -d= -f2)
  state=$(grep -m1 -oE 'mState=[A-Za-z_]+' <<<"$display" | cut -d= -f2)
  if [[ "$wake" != Asleep ]]; then
    fail "$label: dumpsys power reports mWakefulness=${wake:-<none>}, wanted Asleep"
    return 1
  fi
  if [[ "$state" != OFF ]]; then
    fail "$label: dumpsys display reports mState=${state:-<none>}, wanted OFF"
    return 1
  fi
  pass "$label: mWakefulness=Asleep and mState=OFF"
}

# check the presented-frame counter increased
assert_frames_advanced() {
  local label="$1" before="$2" after="$3"
  if [[ ! "$before" =~ ^[0-9]+$ || ! "$after" =~ ^[0-9]+$ ]]; then
    fail "$label: could not read the composer's presented-frame counter (before='${before:-<none>}' after='${after:-<none>}')"
    return 1
  fi
  if (( after <= before )); then
    fail "$label: the presented-frame counter held at $before while the display was ON and an app was drawing"
    return 1
  fi
  pass "$label: the presented-frame counter advanced $before -> $after with the display ON"
}

# fail on a changed presented-frame counter
assert_frames_stalled() {
  local label="$1" before="$2" after="$3"
  if [[ ! "$before" =~ ^[0-9]+$ || ! "$after" =~ ^[0-9]+$ ]]; then
    fail "$label: could not read the composer's presented-frame counter (before='${before:-<none>}' after='${after:-<none>}')"
    return 1
  fi
  if (( after != before )); then
    fail "$label: the presented-frame counter moved ($before -> $after) with the display OFF"
    return 1
  fi
  pass "$label: the presented-frame counter held at $before with the display OFF"
}

PROBE_DONE_TAG="RHIZO_PROBE_DONE_$$"

# run the command over ssh with PROBE_DONE_TAG
probe_ssh() {
  ssh_vm -t "$1" "$2; echo $PROBE_DONE_TAG" 2>/dev/null
}

# remove the PROBE_DONE_TAG line from probe_ssh output
probe_ssh_result() {
  local out="$1"
  grep -qxF "$PROBE_DONE_TAG" <<<"$out" || return 1
  grep -vxF "$PROBE_DONE_TAG" <<<"$out"
  return 0
}

# check the install output reports Success
assert_install_ok() {
  local label="$1" out="$2"
  grep -q 'Success' <<<"$out" || { fail "$label: $out"; return 1; }
  pass "$label: $(tr '\n' ' ' <<<"$out")"
}

# check the am start output reports Status ok
assert_launch_ok() {
  local label="$1" out="$2"
  if grep -q '^Error' <<<"$out"; then
    fail "$label: $out"
    return 1
  fi
  if ! grep -q '^Status: ok' <<<"$out"; then
    fail "$label: no 'Status: ok' in the am start -W output: $out"
    return 1
  fi
  pass "$label: $(grep -E '^(Status|TotalTime|Complete)' <<<"$out" | tr '\n' ' ')"
}

# fail on a dport-5555 DNAT rule
assert_dnat_absent() {
  local label="$1" out="$2" uplink="$3" complete="${4:-1}" hit
  if [[ "$complete" != 1 ]]; then
    fail "$label: the remote probe never completed (no sentinel read back)"
    return 1
  fi
  grep -qE '^-P PREROUTING ' <<<"$out" \
    || { fail "$label: that is not an iptables -S PREROUTING listing (no '-P PREROUTING' policy line): $(tr '\n' ' ' <<<"$out")"; return 1; }
  hit=$(grep -E -- "-i $uplink .*--dport 5555 .*-j DNAT" <<<"$out")
  [[ -z "$hit" ]] || { fail "$label: a dport-5555 DNAT rule on $uplink exists: $hit"; return 1; }
  pass "$label: no dport-5555 DNAT rule on $uplink"
}

# check a dport-5555 DNAT rule matches the uplink
assert_dnat_present() {
  local label="$1" out="$2" uplink="$3" hit
  hit=$(grep -E -- "-i $uplink .*--dport 5555 .*-j DNAT" <<<"$out")
  [[ -n "$hit" ]] || { fail "$label: no dport-5555 DNAT rule on $uplink: $(tr '\n' ' ' <<<"$out")"; return 1; }
  pass "$label: ${hit# }"
}

# check the boot log for the armed marker
assert_lan_armed_marker() {
  local label="$1" out="$2"
  if grep -q 'server.adb_reach=lan refused to arm' <<<"$out"; then
    fail "$label: the launcher refused to arm the rule: $(grep -m1 'refused to arm' <<<"$out")"
    return 1
  fi
  grep -q 'server.adb_reach=lan armed: DNAT' <<<"$out" \
    || { fail "$label: the launcher never reported arming the lan rule: $(tail -2 <<<"$out")"; return 1; }
  pass "$label: $(grep -m1 -o 'server.adb_reach=lan armed: DNAT.*' <<<"$out")"
}

# check the boot log for the refusal marker
assert_lan_refused_marker() {
  local label="$1" out="$2" want_reason="${3:-}"
  if grep -q 'server.adb_reach=lan armed:' <<<"$out"; then
    fail "$label: the launcher armed the rule anyway: $(grep -m1 'armed:' <<<"$out")"
    return 1
  fi
  local line; line=$(grep -m1 -o 'server.adb_reach=lan refused to arm.*' <<<"$out")
  [[ -n "$line" ]] || { fail "$label: no 'refused to arm' marker at all: $(tail -2 <<<"$out")"; return 1; }
  if [[ -n "$want_reason" ]] && [[ "$line" != *"$want_reason"* ]]; then
    fail "$label: refused, but not naming '$want_reason': $line"
    return 1
  fi
  pass "$label: $line"
}

# check the boot log for the instance marker
assert_adb_lan_instance_marker() {
  local label="$1" out="$2"
  grep -q 'RHIZO_MARKER adb_lan_refused=instance_above_zero' <<<"$out" \
    || { fail "$label: no RHIZO_MARKER adb_lan_refused=instance_above_zero: $(tail -2 <<<"$out")"; return 1; }
  pass "$label: RHIZO_MARKER adb_lan_refused=instance_above_zero"
}

# check adb root output and the uid
assert_adb_root_refused() {
  local label="$1" root_out="$2" id_out="$3"
  if grep -qiE 'restarting adbd as root' <<<"$root_out"; then
    fail "$label: adb root reported restarting adbd as root: $root_out"
    return 1
  fi
  if ! grep -qi 'cannot run as root' <<<"$root_out"; then
    fail "$label: adb root did not report its own real refusal (cannot run as root): $root_out"
    return 1
  fi
  if ! grep -qE '(^|[^0-9])uid=[1-9][0-9]*\(' <<<"$id_out"; then
    fail "$label: id did not read back a real non-root uid afterward: $id_out"
    return 1
  fi
  pass "$label: adb root did not grant root ($(head -1 <<<"$root_out"))"
}

# check the adb state for adbd reachability
assert_adb_unreachable() {
  local label="$1" state="$2"
  case "$state" in
    device|unauthorized)
      fail "$label: adb reached adbd from the uplink side (state '$state') with no rule for it"
      return 1 ;;
  esac
  pass "$label: the uplink side does not reach adbd (state '${state:-<none>}')"
}

# compare the adb state with the given state
assert_adb_state() {
  local label="$1" state="$2" want="$3"
  [[ "$state" == "$want" ]] || { fail "$label: adb state '${state:-<none>}', wanted '$want'"; return 1; }
  pass "$label: adb state is $state"
}

# check the adb key revocation output and state
assert_live_revoke() {
  local label="$1" out="$2" state="$3" before="$4" after="$5" session="$6"
  grep -q '^RHIZO_ADBKEY removed=1$' <<<"$out" \
    || { fail "$label: 'rhizo adb-key remove' did not report removed=1: $(tail -2 <<<"$out" | tr '\n' ' ')"; return 1; }
  grep -q "from the running sandbox's /adb_keys and restarted adbd" <<<"$out" \
    || { fail "$label: the remove never reached the running sandbox's /adb_keys and adbd: $(tr '\n' ' ' <<<"$out" | cut -c1-300)"; return 1; }
  [[ "$session" == closed ]] \
    || { fail "$label: a session the key opened before the remove was still open 30s after it"; return 1; }
  [[ "$state" == unauthorized ]] \
    || { fail "$label: the removed key reads '${state:-<none>}' on its next connect, wanted 'unauthorized'"; return 1; }
  [[ -n "$before" && "$before" == "$after" ]] \
    || { fail "$label: the sandbox's init went ${before:-<unread>} -> ${after:-<unread>}"; return 1; }
  pass "$label: removed, its open session ended, it reads unauthorized, and init $before never restarted"
}

# check the veth-side connect succeeded
assert_tcp_reachable() {
  local label="$1" rc="$2"
  (( rc == 0 )) || { fail "$label: the veth-side connect to adbd FAILED (rc=$rc)"; return 1; }
  pass "$label: adbd answers on the veth side"
}

# fail on a host share fuse mount
assert_no_hostfs_mount() {
  local label="$1" out="$2" hit
  hit=$(awk '$3=="fuse" && ($2 ~ /^\/mnt\/user\/0\/emulated\/0\//||$2 ~ /^\/data\/media\/0\//)' <<<"$out")
  [[ -z "$hit" ]] || { fail "$label: a host share is mounted in the sandbox: $hit"; return 1; }
  grep -q ' / ' <<<"$out" || { fail "$label: that is not a mount table: $(head -2 <<<"$out")"; return 1; }
  pass "$label: no host share mounted in the sandbox"
}

# check the conntrack socket joined its netlink groups
detector_subscribed() {
  local netlink="$1" inodes="$2"
  [[ -n "${inodes//[[:space:]]/}" ]] || return 1
  awk -v want="$inodes" '
    BEGIN { n=split(want, a, /[[:space:]]+/); for (k=1;k<=n;k++) if (a[k]!="") mine[a[k]]=1 }
    NR>1 && $2==12 && $4 !~ /^0+$/ && ($10 in mine) { found=1 }
    END { exit found?0:1 }' <<<"$netlink"
}

# check the idle detector subscribed to ctnetlink
assert_detector_subscribed() {
  local label="$1" netlink="$2" inodes="$3" child="${4:-}" other
  if [[ -z "${inodes//[[:space:]]/}" ]]; then
    fail "$label: idle detector ${child:-<none>} exposes no socket inodes (/proc/<pid>/fd unreadable or the detector is gone)"
    return 1
  fi
  if ! detector_subscribed "$netlink" "$inodes"; then
    other=$(awk 'NR>1 && $2==12 && $4 !~ /^0+$/ { printf "portid=%s(groups=%s,inode=%s) ", $3, $4, $10 }' <<<"$netlink")
    if [[ -n "$other" ]]; then
      fail "$label: none of idle detector ${child:-?}'s own socket inodes ($inodes) holds a joined NETLINK_NETFILTER socket, though other netfilter subscribers exist ($other) -- those belong to another process: ${netlink:-<none>}"
    else
      fail "$label: idle detector ${child:-?} has no NETLINK_NETFILTER socket with a nonzero group mask -- NOT yet watching ctnetlink: ${netlink:-<none>}"
    fi
    return 1
  fi
  pass "$label: subscribed (idle detector ${child:-?} owns a joined NETLINK_NETFILTER socket)"
}

# scan the journal for a counted session
session_counted() {
  grep -qE 'count=[1-9][0-9]* NEW tcp reply-src=' <<<"$1"
}

# check the journal for a counted session
assert_session_counted() {
  local label="$1" journal="$2"
  if ! session_counted "$journal"; then
    fail "$label: no 'count=N NEW' line in this start's journal: ${journal:-<none>}"
    return 1
  fi
  pass "$label: counted ($(grep -E 'count=[1-9][0-9]* NEW tcp reply-src=' <<<"$journal" | tail -1 | cut -c1-90))"
}

# check the SELinux enforce flip completed
enforce_flip_done() {
  local text="$1" enforce btime flip ts
  [[ "$text" == *RHIZO_FLIP_DONE ]] || return 1
  enforce=$(sed -n 's/^ENFORCE=//p' <<<"$text" | head -1)
  btime=$(sed -n 's/^BTIME=//p' <<<"$text" | head -1)
  flip=$(sed -n 's/^FLIP=//p' <<<"$text" | head -1)
  [[ "$enforce" == 1 && "$btime" =~ ^[0-9]+$ ]] || return 1
  [[ "$flip" =~ ^([0-9]+)(\.[0-9]+)?\ real\ enforce\ flip:\ (wrote\ 1|already\ enforcing) ]] || return 1
  ts="${BASH_REMATCH[1]}"
  (( ts >= btime ))
}

# read the SELinux enforce state over ssh
enforce_flip_read() {
  ssh_vm -t 15 'echo "ENFORCE=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
    echo "BTIME=$(awk "/^btime/ {print \$2}" /proc/stat)"
    echo "FLIP=$(grep -a "real enforce flip" /var/log/rhizo/rhizo-primer.log 2>/dev/null | tail -1)"
    echo RHIZO_FLIP_DONE' 2>/dev/null | tr -d '\r'
}

# poll enforce_flip_read and print the last read
await_enforce_flip() {
  local deadline=$((SECONDS + $1)) read=""
  while (( SECONDS < deadline )); do
    read=$(enforce_flip_read)
    enforce_flip_done "$read" && break
    sleep 1
  done
  printf '%s' "$read"
}

# check the enforce flip completed
assert_enforce_flipped() {
  local label="$1" text="$2"
  if enforce_flip_done "$text"; then
    pass "$label: this boot's real enforce flip is done ($(sed -n 's/^FLIP=//p' <<<"$text" | head -1))"
  else
    fail "$label: no real enforce flip this boot within the wait -- read: $(tr '\n' ' ' <<<"${text:-<nothing>}")"
  fi
}

# check await_enforce_flip precedes the 0k adb read
assert_flip_wait_before_0k() {
  local label="$1" text="$2" wait_at assert_at k_at
  wait_at=$(grep -n 'FLIP_READ=$(await_enforce_flip ' <<<"$text" | head -1 | cut -d: -f1)
  assert_at=$(grep -n 'assert_enforce_flipped "[^"]*" "$FLIP_READ"' <<<"$text" | head -1 | cut -d: -f1)
  k_at=$(grep -n '^UNREG_STATE=' <<<"$text" | head -1 | cut -d: -f1)
  if [[ -n "$wait_at" && -n "$assert_at" && -n "$k_at" ]] && (( wait_at < assert_at && assert_at < k_at )); then
    pass "$label: 0k stands behind an asserted wait for this boot's enforce flip"
  else
    fail "$label: 0k is not preceded by FLIP_READ=\$(await_enforce_flip ...) and its assert_enforce_flipped (wait=${wait_at:-none} assert=${assert_at:-none} 0k=${k_at:-none})"
  fi
}

# check the subscribe wait precedes the 4m2 connect
assert_subscribe_barrier_present() {
  local label="$1" src="$2" deadline poll assertion connect netlink inodes
  connect=$(grep -n 'ADB_STATE_4M2=\$(uplink_adb_state' <<<"$src" | head -1 | cut -d: -f1)
  if [[ -z "$connect" ]]; then
    fail "$label: no 4m2 connect (ADB_STATE_4M2=\$(uplink_adb_state ...)) in the text given"
    return 1
  fi
  deadline=$(grep -n 'SUB_DEADLINE=\$((SECONDS' <<<"$src" | head -1 | cut -d: -f1)
  poll=$(grep -nE '(^|[^_])detector_subscribed "' <<<"$src" | head -1 | cut -d: -f1)
  assertion=$(grep -n 'assert_detector_subscribed "' <<<"$src" | head -1 | cut -d: -f1)
  if [[ -z "$deadline" || -z "$poll" || -z "$assertion" ]]; then
    fail "$label: 4m2's own precondition is gone (deadline: ${deadline:-none}, poll: ${poll:-none}, assertion: ${assertion:-none})"
    return 1
  fi
  if (( assertion > connect )); then
    fail "$label: the subscribe wait stands AFTER 4m2's connect (line $assertion vs $connect)"
    return 1
  fi
  netlink=$(grep -n 'SUB_NETLINK=\$(idle_netlink)' <<<"$src" | head -1 | cut -d: -f1)
  if [[ -z "$netlink" ]] || (( netlink > poll )); then
    fail "$label: the subscribe wait does not read /proc/net/netlink before testing (read: ${netlink:-none}, test: $poll)"
    return 1
  fi
  inodes=$(grep -n 'SUB_INODES=\$(idle_detector_sock_inodes' <<<"$src" | head -1 | cut -d: -f1)
  if [[ -z "$inodes" ]] || (( inodes > poll )); then
    fail "$label: the subscribe wait does not read the idle detector's own socket inodes before testing (read: ${inodes:-none}, test: $poll)"
    return 1
  fi
  pass "$label: 4m2's connect stands behind a deadline-bounded subscribe wait"
}

# check the idle timer unit state
assert_idle_timer_armed() {
  local label="$1" out="$2" active
  active=$(grep -m1 '^ActiveState=' <<<"$out" | cut -d= -f2)
  [[ "$active" == active ]] || { fail "$label: $IDLE_STOP_UNIT.timer is '${active:-<none>}', wanted active (armed)"; return 1; }
  pass "$label: $IDLE_STOP_UNIT.timer is armed"
}

# compare androidd.service state with the given state
assert_androidd_state() {
  local label="$1" out="$2" want="$3"
  [[ "$out" == "$want" ]] || { fail "$label: androidd.service is '${out:-<none>}', wanted '$want'"; return 1; }
  pass "$label: androidd.service is $out"
}

# require a non-blank value
assert_present() {
  local label="$1" what="$2" value="$3"
  [[ -n "${value//[[:space:]]/}" ]] || { fail "$label: $what"; return 1; }
  pass "$label: $value"
}

# poll for the sandbox init pid
resolve_init() {
  local deadline=$((SECONDS + $1)) pid=""
  while (( SECONDS < deadline )); do
    pid=$(guest_init_pid 15)
    [[ -n "$pid" ]] && break
    sleep 3
  done
  printf '%s' "$pid"
}

# write policy.conf and print it
write_policy() {
  local reach="$1" idle="$2" dri="$3" cmd
  cmd="install -d -m 0755 /etc/rhizo"
  cmd+=$'\n'": > $POLICY_CONF"
  cmd+=$'\n'"echo '[rhizo]' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'profile = server' >> $POLICY_CONF"
  cmd+=$'\n'"echo '[server]' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'adb_reach = $reach' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'idle_stop_s = $idle' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'display = $DISPLAY_GEOMETRY' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'screen_off_s = $SCREEN_OFF_S' >> $POLICY_CONF"
  cmd+=$'\n'"echo '[devices]' >> $POLICY_CONF"
  cmd+=$'\n'"echo 'dri = $dri' >> $POLICY_CONF"
  cmd+=$'\n'"cat $POLICY_CONF"
  ssh_vm -t 20 "$cmd"
}

# search boot.log and dmesg for a pattern
guest_marker() {
  ssh_vm -t 20 "grep -aF '$1' $BOOT_LOG 2>/dev/null; dmesg | grep -aF '$1'" 2>/dev/null
}

# write a sentinel line to /dev/kmsg
guest_sentinel() {
  local tag="RHIZO_TEST_SENTINEL_$$_${EPOCHREALTIME//[!0-9]/}"
  ssh_vm -t 10 "echo '$tag' > /dev/kmsg" >/dev/null 2>&1
  local seen
  seen=$(ssh_vm -t 10 "dmesg | awk -v s='$tag' '\$NF==s'" 2>/dev/null)
  if [[ -z "$seen" ]]; then
    echo "server.sh: guest_sentinel wrote '$tag' to /dev/kmsg but dmesg never showed it back" >&2
    return 1
  fi
  printf '%s' "$tag"
}

# search boot.log and dmesg from the sentinel
guest_marker_since() {
  local sentinel="$1" pattern="$2"
  if [[ -z "$sentinel" ]]; then
    echo "server.sh: guest_marker_since called with an empty sentinel -- refusing to scan dmesg unscoped" >&2
    return 1
  fi
  ssh_vm -t 20 "grep -aF '$pattern' $BOOT_LOG 2>/dev/null; dmesg | awk -v s='$sentinel' 'f{print} \$NF==s{f=1}' | grep -aF '$pattern'" 2>/dev/null
}

# print the adb state of the test device
adb_state() { "$ADB" devices | awk -v want="$ADB_TARGET" '$1==want{print $2}'; }

# reconnect adb through qemu hostfwd and print state
uplink_adb_state() {
  local deadline=$((SECONDS + $1)) state="" attempt=0 log="$EV/uplink-adb-connect.log"
  "$ADB" kill-server >/dev/null 2>&1
  while (( SECONDS < deadline )); do
    attempt=$((attempt + 1))
    "$ADB" disconnect "$ADB_TARGET" >>"$log" 2>&1
    "$ADB" connect "$ADB_TARGET" >>"$log" 2>&1
    state=$(adb_state)
    "$ADB" devices -l >>"$log" 2>&1
    printf 'attempt %d: state=%s\n' "$attempt" "${state:-<none>}" >>"$log"
    [[ "$state" == device ]] && break
    sleep 3
  done
  printf '%s' "$state"
}

# probe adbd port 5555 and print rc
veth_probe_rc() {
  ssh_vm -t 10 "timeout 3 bash -c '</dev/tcp/$1/5555' 2>/dev/null" >/dev/null 2>&1
  echo $?
}

# poll adb for sys.boot_completed
adb_boot_completed() {
  local deadline=$((SECONDS + $1)) bc=""
  while (( SECONDS < deadline )); do
    bc=$(adbx shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
    [[ "$bc" == 1 ]] && break
    sleep 3
  done
  printf '%s' "$bc"
}

# print the idle unit InvocationID
idle_invocation() {
  ssh_vm -t 10 "systemctl show -p InvocationID --value $IDLE_UNIT" 2>/dev/null | tr -d '[:space:]'
}

# read the idle unit journal for a start
idle_journal() {
  local inv="$1" since="$2"
  if [[ "$inv" =~ ^[0-9a-f]+$ ]]; then
    ssh_vm -t 15 "journalctl _SYSTEMD_INVOCATION_ID=$inv --no-pager -o cat" 2>/dev/null
  elif [[ "$since" =~ ^[0-9]+$ ]]; then
    ssh_vm -t 15 "journalctl -u $IDLE_UNIT --since @$since --no-pager -o cat" 2>/dev/null
  else
    echo "server.sh: idle_journal has neither an invocation id nor an epoch to scope on -- refusing to read $IDLE_UNIT's whole journal" >&2
    return 1
  fi
}

# print the pid of the idle detector
idle_detector_pid() {
  local mainpid
  mainpid=$(ssh_vm -t 10 "systemctl show -p MainPID --value $IDLE_UNIT" 2>/dev/null | tr -d '[:space:]')
  [[ "$mainpid" =~ ^[1-9][0-9]*$ ]] || return 1
  echo "$mainpid"
}

# print the socket inodes of the idle detector
idle_detector_sock_inodes() {
  local cp="$1"
  [[ "$cp" =~ ^[1-9][0-9]*$ ]] || return 1
  ssh_vm -t 10 "for f in /proc/$cp/fd/*; do readlink \"\$f\"; done 2>/dev/null" 2>/dev/null \
    | sed -n 's/^socket:\[\([0-9]\+\)\]$/\1/p' | tr '\n' ' '
}

# read /proc/net/netlink from the guest
idle_netlink() {
  ssh_vm -t 10 'cat /proc/net/netlink' 2>/dev/null
}

# save the idle unit journal to evidence
save_idle_journal() {
  local text
  text=$(ssh_vm -t 20 "journalctl -u $IDLE_UNIT --no-pager -n 300" 2>/dev/null)
  save_evidence idle-journal.txt "${text:-<none: journalctl -u $IDLE_UNIT returned nothing>}"
}

# save the conntrack table's open adb entries
save_idle_table() {
  local text
  text=$(ssh_vm -t 20 "PYTHONPATH=/usr/lib/rhizo python3 -c 'import importlib.util as u; s = u.spec_from_file_location(\"idle\", \"/usr/lib/rhizo/server-idle/server-idle.py\"); m = u.module_from_spec(s); s.loader.exec_module(m); print(sorted(m.read_table(), key=str))'" 2>&1)
  save_evidence "$1" "${text:-<none: the conntrack dump printed nothing>}"
}

# wake the display and dismiss the keyguard
wake_display() {
  android_sh "$1" "input keyevent 224" >/dev/null 2>&1
  android_sh "$1" "wm dismiss-keyguard" >/dev/null 2>&1
}

# print the stack cgroup path
resolve_stack_cgroup() {
  local rel path
  rel=$(ssh_vm -t 10 "cat /proc/$1/cgroup" 2>/dev/null | sed -n 's/^0:://p' | tr -d '[:space:]')
  [[ "$rel" == /*/* ]] || return 1
  path="/sys/fs/cgroup${rel%/*}"
  ssh_vm -t 10 "test -r '$path/memory.stat'" >/dev/null 2>&1 || return 1
  printf '%s' "$path"
}

# print the adb endpoint from rhizo status
adb_endpoint_now() {
  local status_json
  status_json=$(ssh_vm -t 60 'rhizo status --json' 2>/dev/null | tail -1)
  python3 -c 'import json,sys
try:
    print(json.loads(sys.argv[1]).get("adb") or "")
except ValueError:
    print("")' "$status_json" 2>/dev/null
}

# print the presents count from the composer
presented_count() {
  "$_SERVER_ASSERT_LIB_DIR/../tools/presented-count.sh" "$1" 1 presents 2>/dev/null | tr -d '[:space:]'
}

