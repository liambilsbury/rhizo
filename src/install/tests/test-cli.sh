#!/bin/bash
# test rhizo.sh argument handling
# shellcheck disable=SC2034
# shellcheck source=src/install/cli/rhizo.sh
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CLI="$HERE/../cli/rhizo.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
RUN_LOG="$TMP/checks-run"; : > "$RUN_LOG"
FAIL_LOG="$TMP/checks-failed"; : > "$FAIL_LOG"
SKIP_LOG="$TMP/checks-skipped"; : > "$SKIP_LOG"

# print ok or FAIL for a comparison
check() {
  echo "$1" >> "$RUN_LOG"
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "       got  $2"
    echo "       want $3"
    echo "$1" >> "$FAIL_LOG"
  fi
}
# run check or count a skip
check_unprivileged() {
  if (( EUID != 0 )); then check "$@"; return; fi
  echo "SKIP $1 -- the suite runs as root, which no mode bit or non-root refusal stops"
  echo "$1" >> "$SKIP_LOG"
}

export RHIZO_SELINUX_MODE_FILE="$TMP/selinux-mode-host"; echo host > "$RHIZO_SELINUX_MODE_FILE"
printf '#!/bin/sh\necho host\n' > "$TMP/selinux-mode-helper-host"; chmod +x "$TMP/selinux-mode-helper-host"
export RHIZO_SELINUX_MODE_HELPER="$TMP/selinux-mode-helper-host"
RHIZO_STATE_DIR="$TMP/state" RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
ETC_RHIZO="$TMP/etc"; mkdir -p "$ETC_RHIZO"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$TMP/os-release-ubuntu"
export RHIZO_OS_RELEASE="$TMP/os-release-ubuntu"
INSTALL_DIR="$HERE/.." load_host_libs
check "the suite runs the tree's own host libraries" \
      "$(shopt -s extdebug; declare -F host_flavor bootloader_kind | cut -d' ' -f3- | tr '\n' ' ')" \
      "$HERE/../lib/host-flavor.sh $HERE/../bootstrap/bootloader.sh "

PROC_NET_UNIX="$TMP/proc_net_unix"
printf '%s\n' 'Num       RefCount Protocol Flags    Type St Inode Path' \
  '0000000000000000: 00000002 00000000 00010000 0001 01 101 /run/user/1000/pipewire-0' \
  '0000000000000000: 00000003 00000000 00000000 0001 03 102 /run/user/1000/pipewire-0' \
  '0000000000000000: 00000003 00000000 00000000 0001 03 103 /run/user/1001/pipewire-0' > "$PROC_NET_UNIX"
check "a listening socket in another user's runtime dir is found" \
  "$(unix_socket_listening /run/user/1000/pipewire-0 && echo yes || echo no)" yes
check "a connected end with no listener is not found" \
  "$(unix_socket_listening /run/user/1001/pipewire-0 && echo yes || echo no)" no
check "a path nothing binds is not found" \
  "$(unix_socket_listening /run/user/1000/wayland-0 && echo yes || echo no)" no

NASTY="content://com.android.externalstorage.documents/document/x'y;z w"
body=$(resolve_activity_body com.x "$NASTY" "text/plain")
check "a URI's quote, semicolon and space are absent from the body" \
      "$(grep -cF "x'y;z w" <<<"$body")" 0
carried=$(grep -oE '\-d "\$\(echo [A-Za-z0-9+/=]+' <<<"$body" | awk '{print $NF}' \
          | base64 -d)
check "the URI arrives intact after the guest decodes it" "$carried" "$NASTY"
mime_carried=$(grep -oE '\-t "\$\(echo [A-Za-z0-9+/=]+' <<<"$body" | awk '{print $NF}' \
               | base64 -d)
check "the type arrives intact too" "$mime_carried" "text/plain"
check "the body decodes with the guest's own base64" \
      "$(grep -c 'toybox base64 -d' <<<"$body")" 1

url_body=$(resolve_activity_body com.x "https://example.test/a b" "")
check "a scheme URL asks with BROWSABLE" \
      "$(grep -c 'android.intent.category.BROWSABLE' <<<"$url_body")" 1
check "a scheme URL asks with no type" "$(grep -c ' -t ' <<<"$url_body")" 0
check "a content URI asks with a type" "$(grep -c ' -t ' <<<"$body")" 1
check "a content URI asks without BROWSABLE" \
      "$(grep -c 'BROWSABLE' <<<"$body")" 0

for pair in "mailto:a@b uri" "tel:+1 uri" "geo:0,0 uri" "https://x/y uri" \
            "file:///tmp/x path" "FILE:///tmp/x path" "/tmp/x path" \
            "relative.txt path" "x.y+z-1:q uri"; do
  set -- $pair
  check "$1 routes to the $2 branch" "$(launch_arg_kind "$1")" "$2"
done

# print accept or reject for a package name
pkg_verdict() { ( check_package_name "$1" ) >/dev/null 2>&1 && echo accept || echo reject; }
for pair in ".. reject" ".a reject" "a accept" "com.x accept" "a/b reject"; do
  set -- $pair
  check "package name $1 -> $2" "$(pkg_verdict "$1")" "$2"
done

check "an encoded percent decodes to one" "$(urldecode '100%25done.pdf')" '100%done.pdf'
check "a bare percent is left alone" "$(urldecode '100% done.pdf')" '100% done.pdf'
check "an encoded space decodes" "$(urldecode '/tmp/a%20b')" '/tmp/a b'

check "python's table names a pdf" "$(host_mime_guess /tmp/x.pdf)" 'application/pdf'
mkdir -p "$TMP/tools" "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/xdg-mime"; chmod +x "$TMP/bin/xdg-mime"
printf 'print("{}")\n' > "$TMP/tools/hostfs.py"
touch "$TMP/report.pdf"
(
  PATH="$TMP/bin:$PATH"; TOOLS_DIR="$TMP/tools"
  share_row() { printf '%s\t%s\t%s\n' Download report.pdf "content://x/doc/1"; }
  resolve_host_file "$TMP/report.pdf"
  echo "$VIEW_MIME"
) > "$TMP/mime.out" 2>&1
check "an empty xdg-mime answer reaches the second source" \
      "$(tail -1 "$TMP/mime.out")" 'application/pdf'

export FAKE_GROUPS="$TMP/groups"; : > "$FAKE_GROUPS"
cat > "$TMP/bin/getent" <<'EOF'
#!/bin/sh
[ "$1" = group ] && grep -qx "$2" "$FAKE_GROUPS" && exit 0
exit 2
EOF
cat > "$TMP/bin/groupadd" <<'EOF'
#!/bin/sh
grep -qx rhizo "$FAKE_GROUPS" || echo rhizo >> "$FAKE_GROUPS"
EOF
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/usermod"
chmod +x "$TMP/bin/getent" "$TMP/bin/groupadd" "$TMP/bin/usermod"
echo tester > "$ETC_RHIZO/desktop-user"
(
  PATH="$TMP/bin:$PATH"
  ensure_broker_group
  ensure_broker_group
) >/dev/null 2>&1
check "the created group is recorded once" \
      "$(grep -c '^group:rhizo$' "$INSTALL_RECORD")" 1
: > "$FAKE_GROUPS"; echo rhizo >> "$FAKE_GROUPS"; rm -f "$INSTALL_RECORD"
(
  PATH="$TMP/bin:$PATH"
  ensure_broker_group
) >/dev/null 2>&1
check "a group the machine already had is not recorded" \
      "$([[ -e "$INSTALL_RECORD" ]] && echo present || echo absent)" absent

U1K="$TMP/u1k"; mkdir -p "$U1K/bin"
export U1K_PASSWD="$U1K/passwd" U1K_GROUP="$U1K/group"
cat > "$U1K/bin/getent" <<'EOF'
#!/bin/sh
db=$U1K_PASSWD; [ "$1" = group ] && db=$U1K_GROUP
awk -F: -v k="$2" '$1 == k || $3 == k { print; found = 1 } END { exit !found }' "$db" 2>/dev/null || exit 2
EOF
cat > "$U1K/bin/adduser" <<'EOF'
#!/bin/sh
for a; do name=$a; done
echo "$name:x:1000:1000::/nonexistent:/usr/sbin/nologin" >> "$U1K_PASSWD"
grep -q "^$name:" "$U1K_GROUP" 2>/dev/null || echo "$name:x:1000:" >> "$U1K_GROUP"
EOF
chmod +x "$U1K/bin/getent" "$U1K/bin/adduser"
# run resolve_uid1000 on fixture passwd and group files
u1k_case() {
  : > "$U1K_PASSWD"; : > "$U1K_GROUP"; rm -f "$INSTALL_RECORD" "$ETC_RHIZO/desktop-user"
  [[ "$1" == - ]] || echo "$1" > "$U1K_PASSWD"
  [[ "$2" == - ]] || echo "$2" > "$U1K_GROUP"
  [[ "$3" == - ]] || echo "$3" > "$ETC_RHIZO/desktop-user"
  ( PATH="$U1K/bin:$PATH"; unset SUDO_USER; resolve_uid1000 ) >/dev/null 2>&1
}
# print the install record on one line
record_of() { tr '\n' ' ' < "$INSTALL_RECORD" 2>/dev/null | sed 's/ $//'; }
u1k_case - - -
check "an unclaimed uid 1000 gets rhizo-appwatch, recorded as this install's user and group" \
      "$(record_of)" "user:rhizo-appwatch group:rhizo-appwatch"
check "... and desktop-user names it" "$(cat "$ETC_RHIZO/desktop-user")" rhizo-appwatch
u1k_case - "rhizo-appwatch:x:1000:" -
check "a group rhizo-appwatch the host already had is not recorded" "$(record_of)" "user:rhizo-appwatch"
u1k_case "tester:x:1000:1000::/home/tester:/bin/bash" - -
check "a person at uid 1000 is never recorded" "$(record_of)" ""
u1k_case "rhizo-appwatch:x:1000:1000::/nonexistent:/usr/sbin/nologin" "rhizo-appwatch:x:1000:" -
check "a rhizo-appwatch this run did not create is not recorded as this install's" "$(record_of)" ""
u1k_case "tester:x:1000:1000::/home/tester:/bin/bash" - rhizo-appwatch
check "a desktop-user naming an account that is no longer uid 1000 is rewritten" \
      "$(cat "$ETC_RHIZO/desktop-user")" tester
export U1K_ARGV="$U1K/useradd.argv"
cat > "$U1K/bin/useradd" <<'EOF'
#!/bin/sh
echo "$*" > "$U1K_ARGV"
uid=; name=
while [ $# -gt 0 ]; do case "$1" in --uid) uid=$2; shift ;; *) name=$1 ;; esac; shift; done
echo "$name:x:$uid:$uid::/nonexistent:/usr/bin/nologin" >> "$U1K_PASSWD"
grep -q "^$name:" "$U1K_GROUP" 2>/dev/null || echo "$name:x:$uid:" >> "$U1K_GROUP"
EOF
chmod +x "$U1K/bin/useradd"
printf 'ID=cachyos\n' > "$U1K/os-release-cachyos"
RHIZO_OS_RELEASE="$U1K/os-release-cachyos" u1k_case - - -
U1K_USERADD="--system --user-group --no-create-home --home-dir /nonexistent --shell /usr/bin/nologin"
check "on cachyos an unclaimed uid 1000 gets rhizo-appwatch from useradd, recorded as this install's" \
      "$(record_of) | $(cat "$U1K_ARGV" 2>/dev/null)" \
      "user:rhizo-appwatch group:rhizo-appwatch | $U1K_USERADD --uid 1000 rhizo-appwatch"
rm -f "$U1K_ARGV"
RHIZO_OS_RELEASE="$U1K/os-release-cachyos" u1k_case \
  "rhizo-appwatch:x:977:977::/nonexistent:/usr/bin/nologin" "rhizo-appwatch:x:977:" -; U1K_RC=$?
check "on cachyos a rhizo-appwatch at another uid stops the install, recording nothing and creating nothing" \
      "$U1K_RC|$(record_of)|$(cat "$ETC_RHIZO/desktop-user" 2>/dev/null)|$(cat "$U1K_ARGV" 2>/dev/null)" "1|||"
rm -f "$INSTALL_RECORD"; echo tester > "$ETC_RHIZO/desktop-user"

export XDG_DATA_HOME="$TMP/xdg"
mkdir -p "$XDG_DATA_HOME/applications"
cat > "$XDG_DATA_HOME/applications/rhizo-com.x.desktop" <<'EOF'
[Desktop Entry]
Name=HTML Viewer
X-Rhizo-Package=com.x
X-Rhizo-Activity=
EOF
out=$(cmd_launch com.x 2>&1)
check "a handler-only entry with no argument fails by name" "$out" \
      "RHIZO_FAIL com.x has no launcher activity; it opens files and links only"

cat > "$TMP/tools/rhizo-launch.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$RECORD_ARGV"
echo "$(date +%s) event=am_start_return pid=$$ display=4 cdisplay=9" >> "$LAUNCH_LOG"
EOF
chmod +x "$TMP/tools/rhizo-launch.sh"
# run cmd_launch with stubbed functions
run_launch() {
  local record="$1"; shift
  (
    TOOLS_DIR="$TMP/tools"; LAUNCH_LOG="$TMP/launch.log"; RECORD_ARGV="$record"
    export RECORD_ARGV LAUNCH_LOG
    : > "$LAUNCH_LOG"
    require_probe_client() { :; }
    start_sandbox() { :; }
    resolve_host_file() { VIEW_URI="content://x/doc/9"; VIEW_MIME="text/plain"; }
    android_sh() { echo "$1" > "$TMP/body.out"; echo "com.x/.ViewActivity"; }
    cmd_launch "$@"
  )
}
out=$(run_launch "$TMP/argv.path" com.x "$TMP/report.pdf" 2>&1 | tail -1)
check "a handler-only entry with a path resolves the activity" "$out" \
      "RHIZO_LAUNCHED pkg=com.x display=4 cdisplay=9"
check "the resolved activity is what the launch script got" \
      "$(sed -n 2p "$TMP/argv.path")" ".ViewActivity"

out=$(run_launch "$TMP/argv.url" com.x "https://example.test/y" 2>&1 | tail -1)
check "a URL launch resolves too" "$out" "RHIZO_LAUNCHED pkg=com.x display=4 cdisplay=9"
check "a URL launch does not dispatch to the launcher activity" \
      "$(sed -n 2p "$TMP/argv.url")" ".ViewActivity"
check "the URL's own resolve body carried BROWSABLE" \
      "$(grep -c BROWSABLE "$TMP/body.out")" 1

mv "$TMP/tools/rhizo-launch.sh" "$TMP/tools/rhizo-launch.sh.real"
cat > "$TMP/tools/rhizo-launch.sh" <<'EOF'
#!/bin/sh
exit 3
EOF
chmod +x "$TMP/tools/rhizo-launch.sh"
out=$(run_launch "$TMP/argv.ontop" com.x "https://example.test/y" 2>&1 | tail -1)
check "a launch whose app never tops its display fails as not-on-top, by name" "${out%% -- *}" \
      "RHIZO_FAIL reason=not-on-top pkg=com.x"
printf '#!/bin/sh\nexit 4\n' > "$TMP/tools/rhizo-launch.sh"
out=$(run_launch "$TMP/argv.ontop" com.x "https://example.test/y" 2>&1 | tail -1)
check "a launch am start refused fails as launch-error, by name" "${out%% -- *}" \
      "RHIZO_FAIL reason=launch-error pkg=com.x"
printf '#!/bin/sh\nexit 5\n' > "$TMP/tools/rhizo-launch.sh"
out=$(run_launch "$TMP/argv.ontop" com.x "https://example.test/y" 2>&1 | tail -1)
check "a launch whose process died starting fails as process-died, by name" "${out%% -- *}" \
      "RHIZO_FAIL reason=process-died pkg=com.x"
mv "$TMP/tools/rhizo-launch.sh.real" "$TMP/tools/rhizo-launch.sh"

# run cmd_launch for a given profile
srv_launch() {
  (
    TOOLS_DIR="$TMP/tools"; LAUNCH_LOG="$TMP/launch.log"; RECORD_ARGV="$TMP/argv.srv"
    SRV_REPLY="$2"
    export RECORD_ARGV LAUNCH_LOG
    : > "$LAUNCH_LOG"; rm -f "$TMP/body.srv"
    require_probe_client() { :; }
    start_sandbox() { :; }
    read_capability() { [[ "$1" == rhizo.profile ]] && echo "$SRV_PROFILE"; }
    android_sh() { echo "$1" > "$TMP/body.srv"; printf '%b\n' "$SRV_REPLY"; }
    SRV_PROFILE="$1" cmd_launch "$3"
  ) 2>&1 | tail -1
}
check "the server profile resolves the launcher activity from Android and launches it" \
      "$(srv_launch server 'priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\ncom.srv/.MainActivity' com.srv)" \
      "RHIZO_LAUNCHED pkg=com.srv display=4 cdisplay=9"
check "... handing the launch script the activity Android named" "$(sed -n 2p "$TMP/argv.srv")" ".MainActivity"
check "... resolved as MAIN in LAUNCHER for that package alone" \
      "$(grep -c -- '-a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p com.srv' "$TMP/body.srv")" 1
check "a package Android has no launcher activity for fails by name on the server profile" \
      "$(srv_launch server 'No activity found' com.gone)" \
      "RHIZO_FAIL com.gone has no launcher activity, or is not installed (resolve-activity said: No activity found)"
check "the desktop profile still launches only what its sync wrote an entry for" \
      "$(srv_launch desktop 'com.srv/.MainActivity' com.srv | grep -c '^RHIZO_FAIL no rhizo-com.srv.desktop under ')" 1

mkdir -p "$TMP/locked"
touch "$TMP/locked/note.txt"
chmod 000 "$TMP/locked"
check_unprivileged "this account cannot read through the locked directory" \
      "$(cat "$TMP/locked/note.txt" 2>/dev/null; echo "rc=$?")" "rc=1"
# run cmd_launch and print its last line
launch_out() {
  (
    TOOLS_DIR="$TMP/tools"; LAUNCH_LOG="$TMP/launch.log"
    start_sandbox() { :; }
    cmd_launch "$@"
  ) 2>&1 | tail -1
}
check "--mime reaches the share translation on a path it cannot read" \
      "$(launch_out com.x "$TMP/locked/note.txt" --mime text/plain)" \
      "RHIZO_FAIL $TMP/locked/note.txt is not inside any shared folder; add it in /etc/rhizo/hostfs.conf"
check_unprivileged "without --mime the same path fails on the read" \
      "$(launch_out com.x "$TMP/locked/note.txt")" \
      "RHIZO_FAIL $TMP/locked/note.txt does not name a file on this host"
check "--mime on a URL is refused rather than ignored" \
      "$(launch_out com.x https://example.test/y --mime text/html)" \
      "RHIZO_FAIL --mime applies to a host file, not the URL https://example.test/y"
chmod 755 "$TMP/locked"

PREPARE_TMP=$(mktemp -d)
mkdir -p "$PREPARE_TMP/lib/install/"{bootstrap,prepare,update,teardown,lib,cli} "$PREPARE_TMP/state/prepared/aaaaaaaaaaaa" "$PREPARE_TMP/state/prepared/bbbbbbbbbbbb"
echo m > "$PREPARE_TMP/state/prepared/aaaaaaaaaaaa/manifest.json"
echo m > "$PREPARE_TMP/state/prepared/bbbbbbbbbbbb/manifest.json"
ln -s bbbbbbbbbbbb "$PREPARE_TMP/state/prepared/current"
cat > "$PREPARE_TMP/lib/install/prepare/prepare.sh" <<'STUBEOF'
#!/bin/sh
echo "RHIZO_PREPARE_OK key=bbbbbbbbbbbb tree=/x sepolicy=/x template=cccccccccccc data=preserved dexopt=0/0 binder=0"
exit 0
STUBEOF
chmod +x "$PREPARE_TMP/lib/install/prepare/prepare.sh"
# print file types and checksums of a directory
snapshot() {
  ( cd "$1" && find . -mindepth 1 -printf '%y %p\n' | sort
    find . -mindepth 1 -type f -exec sha256sum {} + | sort )
}
before=$(snapshot "$PREPARE_TMP/state/prepared")
cmd_prepare_out=$( ( RHIZO_LIB_DIR="$PREPARE_TMP/lib" RHIZO_STATE_DIR="$PREPARE_TMP/state" RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  gc_cache() { :; }
  cmd_prepare ) 2>&1 ); cmd_prepare_rc=$?
after=$(snapshot "$PREPARE_TMP/state/prepared")
check "cmd_prepare (stubbed, successful) exits 0" "$cmd_prepare_rc" 0
check "cmd_prepare's own success line reaches stdout" \
      "$(grep -c '^RHIZO_PREPARE_OK key=bbbbbbbbbbbb ' <<<"$cmd_prepare_out")" 1
check "cmd_prepare leaves PREPARED_ROOT untouched after a successful (stubbed) prepare" "$after" "$before"
rm -rf "$PREPARE_TMP"

UP_TMP=$(mktemp -d)
mkdir -p "$UP_TMP/lib/install/"{bootstrap,prepare,update,teardown,lib,cli} "$UP_TMP/state" "$UP_TMP/run"
export UP_CALLS="$UP_TMP/calls" UP_ENFORCE_FILE="$UP_TMP/enforce"
cat > "$UP_TMP/lib/install/bootstrap/bootstrap.sh" <<'STUBEOF'
#!/bin/sh
echo bootstrap >> "$UP_CALLS"
echo RHIZO_BOOTSTRAP_ALREADY_APPLIED=1
STUBEOF
cat > "$UP_TMP/lib/install/prepare/prepare.sh" <<'STUBEOF'
#!/bin/sh
echo "prepare $*" >> "$UP_CALLS"
if [ "${1:-}" != --verify ] && [ "$(cat "$UP_ENFORCE_FILE" 2>/dev/null)" != 0 ]; then
  echo "RHIZO_PREPARE_REFUSED reason=enforcing"
  exit 1
fi
echo "RHIZO_PREPARE_OK key=bbbbbbbbbbbb tree=/x sepolicy=/x template=cccccccccccc data=kept dexopt=0/0 binder=0"
STUBEOF
cat > "$UP_TMP/lib/rhizo-selinux-mode" <<'STUBEOF'
#!/bin/sh
[ -n "${UP_CALLS:-}" ] && echo "mode $*" >> "$UP_CALLS"
[ "${UP_MODE_FAIL:-}" = 1 ] && exit 3
why="the Rhizo kernel runs without Landlock ABI 6; remove lsm= from its boot line or add landlock to it"
case " $* " in
  *" --why "*) echo "$why" ;;
  *" --mode-and-why "*) case "${UP_MODE:-namespace}" in refuse:*) printf '%s\t%s\n' "$UP_MODE" "$why" ;;
                                                       *) echo "${UP_MODE:-namespace}" ;; esac ;;
  *) echo "${UP_MODE:-namespace}" ;;
esac
STUBEOF
chmod +x "$UP_TMP/lib/rhizo-selinux-mode"
chmod +x "$UP_TMP/lib/install/bootstrap/bootstrap.sh" "$UP_TMP/lib/install/prepare/prepare.sh"
# run cmd_upgrade with stubbed systemctl
run_upgrade() {
  UP_ENFORCE="$1" UP_ACTIVE="$2" UP_ENABLED="$3"; shift 3
  : > "$UP_CALLS"
  rm -f "$UP_TMP/run/reboot-required" "$UP_TMP/enforce"
  printf 'kernel=k\nversion=0.1.0\n' > "$UP_TMP/state/.prepared"
  [[ "$UP_ENFORCE" == none ]] || echo "$UP_ENFORCE" > "$UP_TMP/enforce"
  UP_OUT=$( ( RHIZO_LIB_DIR="$UP_TMP/lib" RHIZO_STATE_DIR="$UP_TMP/state" RHIZO_RUN_MOUNT="$UP_TMP/run" \
    RHIZO_SELINUX_ENFORCE="$UP_TMP/enforce" RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
    gc_cache() { :; }
    systemctl() {
      case "$1 $2" in
        "is-active androidd.service") echo "$UP_ACTIVE" ;;
        "is-enabled rhizo-prepare.service") echo "$UP_ENABLED" ;;
        *) echo "unexpected systemctl $*" >&2; return 1 ;;
      esac
    }
    cmd_upgrade "$@" ) 2>&1 ); UP_RC=$?
}
# print whether the prepared marker was kept or cleared
up_marker() { [[ -e "$UP_TMP/state/.prepared" ]] && echo kept || echo cleared; }
# print whether the reboot-required flag is set or unset
up_flag() { [[ -e "$UP_TMP/run/reboot-required" ]] && echo set || echo unset; }

run_upgrade 1 active enabled
check "upgrade with the sandbox running under enforcement exits 0" "$UP_RC" 0
check "it prints exactly 'reboot to finish the upgrade'" \
      "$(grep -cx '\[rhizo\] reboot to finish the upgrade' <<<"$UP_OUT")" 1
check "it ends on the deferred sentinel" \
      "$(grep -cx 'RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=enforcing' <<<"$UP_OUT")" 1
check "it re-applies the bootstrap and never runs prepare under enforcement" \
      "$(tr '\n' ' ' < "$UP_CALLS")" "bootstrap "
check "it clears the marker so the next boot's rhizo-prepare.service runs" "$(up_marker)" cleared
check "it sets the host's reboot-required flag" "$(up_flag)" set

run_upgrade 1 inactive enabled
check "upgrade with the sandbox stopped but enforcing still defers (rc)" "$UP_RC" 0
check "upgrade with the sandbox stopped but enforcing never runs prepare" \
      "$(tr '\n' ' ' < "$UP_CALLS")" "bootstrap "
check "upgrade with the sandbox stopped but enforcing asks for the reboot" \
      "$(grep -cx '\[rhizo\] reboot to finish the upgrade' <<<"$UP_OUT")" 1

run_upgrade 1 inactive disabled
check "a disabled rhizo-prepare.service fails the deferred upgrade" "$UP_RC" 1
check "the failure names the unit's state" \
      "$(grep -c "rhizo-prepare.service is 'disabled': run 'systemctl enable rhizo-prepare.service', then 'rhizo upgrade'" <<<"$UP_OUT")" 1
check "a refused deferral keeps the marker" "$(up_marker)" kept
check "a refused deferral sets no reboot flag" "$(up_flag)" unset

run_upgrade 0 inactive enabled
check "upgrade with no policy enforcing defers too (rc)" "$UP_RC" 0
check "upgrade with no policy enforcing never runs prepare" \
      "$(tr '\n' ' ' < "$UP_CALLS")" "bootstrap "
check "upgrade with no policy enforcing prints exactly 'reboot to finish the upgrade'" \
      "$(grep -cx '\[rhizo\] reboot to finish the upgrade' <<<"$UP_OUT")" 1
check "upgrade with no policy enforcing ends on the setup-at-boot sentinel" \
      "$(grep -cx 'RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=setup-at-boot' <<<"$UP_OUT")" 1
check "upgrade with no policy enforcing clears the marker" "$(up_marker)" cleared
check "upgrade with no policy enforcing sets the reboot flag" "$(up_flag)" set

run_upgrade 0 active enabled
check "upgrade with a sandbox running and no policy enforcing defers (rc)" "$UP_RC" 0
check "that deferral runs no prepare under the running sandbox" "$(tr '\n' ' ' < "$UP_CALLS")" "bootstrap "

run_upgrade none inactive enabled
check "upgrade on a boot without selinuxfs defers (rc)" "$UP_RC" 0
check "upgrade on a boot without selinuxfs never runs prepare" "$(tr '\n' ' ' < "$UP_CALLS")" "bootstrap "
check "upgrade on a boot without selinuxfs names setup-at-boot" \
      "$(grep -cx 'RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=setup-at-boot' <<<"$UP_OUT")" 1

run_upgrade 0 inactive disabled
check "a disabled rhizo-prepare.service fails the deferral with no policy enforcing" "$UP_RC" 1
check "that refusal keeps the marker" "$(up_marker)" kept

run_upgrade 1 active enabled --verify
check "upgrade --verify under enforcement still reaches prepare --verify" \
      "$(tr '\n' ' ' < "$UP_CALLS")" "bootstrap prepare --verify "
check "upgrade --verify under enforcement keeps the marker" "$(up_marker)" kept
run_upgrade 0 inactive enabled --verify
check "upgrade --verify with no policy enforcing reaches prepare --verify" \
      "$(tr '\n' ' ' < "$UP_CALLS")" "bootstrap prepare --verify "
check "upgrade --verify with no policy enforcing asks for no reboot" \
      "$(grep -c 'reboot to finish the upgrade' <<<"$UP_OUT")" 0

PR_TMP=$(mktemp -d)
mkdir -p "$PR_TMP/lib/install/"{bootstrap,prepare,update,teardown,lib,cli} "$PR_TMP/state" "$PR_TMP/run" "$PR_TMP/etc" "$PR_TMP/srv/gsi_system/bin"
echo init > "$PR_TMP/srv/gsi_system/bin/init"
export PR_CALLS="$PR_TMP/calls"
printf '#!/bin/sh\necho "prepare $*" >> "$PR_CALLS"\necho "RHIZO_PREPARE_OK key=bbbbbbbbbbbb tree=/x sepolicy=/x template=cccccccccccc data=kept dexopt=0/0 binder=0"\n' \
  > "$PR_TMP/lib/install/prepare/prepare.sh"
printf '#!/bin/sh\necho "fetch $*" >> "$PR_CALLS"\necho "${PR_FETCH_OUT:-RHIZO_GSI_FETCHED release=$2 sha256=x}"\n' \
  > "$PR_TMP/lib/install/prepare/fetch-gsi.sh"
printf '#!/bin/sh\ncase "$1" in\n  status) echo "RHIZO_GSI_UPDATE current=${PR_CURRENT:-a16} candidate=${PR_CANDIDATE:--} tries=- previous=-" ;;\n  kernel-check) echo "${PR_KERNEL_OUT:-RHIZO_GSI_KERNEL_OK release=$3}" ;;\nesac\n' \
  > "$PR_TMP/lib/install/update/gsi-update.sh"
chmod +x "$PR_TMP"/lib/install/*/*.sh
# run cmd_prepare with stubbed systemctl
run_prepare() {
  local enforce="$1"; shift
  : > "$PR_CALLS"
  rm -f "$PR_TMP/state/prepare-request" "$PR_TMP/run/reboot-required"
  printf 'kernel=k\nversion=0.1.3\n' > "$PR_TMP/state/.prepared"
  echo "$enforce" > "$PR_TMP/enforce"
  PR_OUT=$( ( export RHIZO_CLI_TEST_NO_ROOT=1
    RHIZO_LIB_DIR="$PR_TMP/lib" RHIZO_STATE_DIR="$PR_TMP/state" RHIZO_RUN_MOUNT="$PR_TMP/run" \
    RHIZO_ETC_DIR="$PR_TMP/etc" RHIZO_GSI_ROOT="$PR_TMP/srv" RHIZO_SELINUX_ENFORCE="$PR_TMP/enforce" \
    RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
    gc_cache() { :; }
    systemctl() { [[ "$1 $2" == "is-enabled rhizo-prepare.service" ]] && echo "${PR_ENABLED:-enabled}"; }
    cmd_prepare "$@" ) 2>&1 ); PR_RC=$?
}
# print the prepare request on one line
pr_request() { cat "$PR_TMP/state/prepare-request" 2>/dev/null | tr '\n' ' '; }
# print the recorded calls on one line
pr_calls() { tr '\n' ' ' < "$PR_CALLS"; }

run_prepare 1 --release a15 --wipe-data
check "prepare --release a15 --wipe-data under enforcement exits 0" "$PR_RC" 0
check "it never runs the prepare script under enforcement" "$(grep -c '^prepare' "$PR_CALLS")" 0
check "it fetches the unstaged a15 image now, verified, for the next boot" "$(pr_calls)" "fetch --release a15 --fetch-only "
check "it records the release, variant and wipe for rhizo-prepare.service" "$(pr_request)" \
      "release=a15 variant= wipe_data=1 "
check "it clears the setup marker so the next boot's rhizo-prepare.service runs" \
      "$([[ -e "$PR_TMP/state/.prepared" ]] && echo kept || echo cleared)" cleared
check "it sets the host's reboot-required flag" \
      "$([[ -e "$PR_TMP/run/reboot-required" ]] && echo set || echo unset)" set
check "it ends on the deferred sentinel naming the release" \
      "$(grep -cx 'RHIZO_PREPARE_REBOOT_REQUIRED=1 reason=enforcing release=a15' <<<"$PR_OUT")" 1

run_prepare 1 --release a16
check "re-preparing the current release needs no wipe, and stages nothing already staged" "$(pr_calls)" ""
check "it records release=a16 wipe_data=0" "$(pr_request)" "release=a16 variant= wipe_data=0 "

run_prepare 1 --release a15
check "switching release without --wipe-data fails" "$PR_RC" 1
check "the failure names the /data it would lose and rhizo gsi update" \
      "$(grep -c "needs --wipe-data; 'rhizo gsi update --release a15' keeps /data" <<<"$PR_OUT")" 1
check "a refused deferral records nothing" "$(pr_request)" ""
check "a refused deferral keeps the marker" \
      "$([[ -e "$PR_TMP/state/.prepared" ]] && echo kept || echo cleared)" kept

PR_KERNEL_OUT="RHIZO_GSI_UPDATE_REFUSED reason=kernel-unsupported" run_prepare 1 --release a17 --wipe-data
check "a release this kernel cannot run is refused kernel-unsupported" \
      "$(tail -1 <<<"$PR_OUT")" "RHIZO_PREPARE_REFUSED reason=kernel-unsupported"
check "that refusal fetches nothing and records nothing" "$(pr_calls)$(pr_request)" ""

PR_CANDIDATE=a16 PR_CURRENT=a15 run_prepare 1 --release a15 --wipe-data
check "a deferral under an armed rhizo gsi trial fails" "$PR_RC" 1
check "that failure names the trial" "$(grep -c 'a rhizo gsi trial of a16 is armed' <<<"$PR_OUT")" 1

run_prepare 1 --release a15 --wipe-data --gsi /srv/x
check "an option the next boot cannot carry fails the deferral" "$PR_RC" 1
check "that failure names the option" "$(grep -c "takes --release, --variant and --wipe-data, not '--gsi'" <<<"$PR_OUT")" 1

PR_FETCH_OUT="RHIZO_GSI_FAILED reason=download-failed" run_prepare 1 --release a15 --wipe-data
check "an image that cannot be fetched now fails the deferral" "$PR_RC" 1
check "and records nothing" "$(pr_request)" ""

PR_ENABLED=disabled run_prepare 1 --release a15 --wipe-data
check "a disabled rhizo-prepare.service fails the deferral" "$PR_RC" 1
check "that failure names what the next boot would not do" \
      "$(grep -c "rhizo-prepare.service is 'disabled': run 'systemctl enable rhizo-prepare.service', then 'rhizo prepare'" <<<"$PR_OUT")" 1

run_prepare 0 --release a15 --wipe-data
check "prepare with no policy enforcing runs the script now" "$(pr_calls)" \
      "prepare --payload $PR_TMP/lib --release a15 --wipe-data "
check "and records no deferral" "$(pr_request)" ""
run_prepare 0 --payload /elsewhere
check "an explicit --payload is passed as given" "$(pr_calls)" "prepare --payload /elsewhere "
rm -rf "$PR_TMP"

( RHIZO_LIB_DIR="$UP_TMP/lib" RHIZO_STATE_DIR="$UP_TMP/state" RHIZO_SELINUX_ENFORCE="$UP_TMP/enforce" RHIZO_ETC_DIR="$UP_TMP/etc" \
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  UP_PREP_STATE=inactive
  systemctl() { [[ "$1 $2" == "is-active rhizo-prepare.service" ]] && echo "$UP_PREP_STATE"; }
  printf 'kernel=k\nversion=0.1.1\n' > "$UP_TMP/state/.prepared"; echo 1 > "$UP_TMP/enforce"
  check "a written marker reads setup done" "$(setup_state)" "done"
  rm -f "$UP_TMP/state/.prepared"
  check "no marker under enforcement reads pending-reboot" "$(setup_state)" pending-reboot
  check "doctor names the reboot for a pending-reboot setup" \
        "$(check_setup 2>&1 | grep -c 'setup: warn -- reboot to finish the install or upgrade')" 1
  echo 0 > "$UP_TMP/enforce"
  check "no marker, no policy enforcing and prepare idle reads pending-reboot" "$(setup_state)" pending-reboot
  UP_PREP_STATE=activating
  check "no marker while rhizo-prepare.service runs reads pending" "$(setup_state)" pending
  check "doctor names the running unit for a pending setup" \
        "$(check_setup 2>&1 | grep -c 'setup has not finished; see systemctl status rhizo-prepare.service')" 1
  UP_PREP_STATE=failed
  rm -f "$UP_TMP/enforce"
  check "no marker, no selinuxfs and a failed prepare reads pending-reboot" "$(setup_state)" pending-reboot
  SENT="the Rhizo kernel runs without Landlock ABI 6; remove lsm= from its boot line or add landlock to it"
  export UP_MODE=refuse:kernel-has-no-landlock
  check "a refusing mode helper reads setup refused, not pending-reboot" "$(setup_state)" refused
  check "a start names the reason and the sentence, never a pending reboot" "$(refuse_start_without_setup)" \
        "RHIZO_FAIL setup refused on this boot (refuse:kernel-has-no-landlock): $SENT"
  export UP_MODE_FAIL=1
  check "a failing mode helper reads helper-failed" "$(setup_state)" helper-failed
  check "a start names the failing helper and its exit status" "$(refuse_start_without_setup 2>&1 | sed "s|$UP_TMP|UP|")" \
        "RHIZO_FAIL setup state unknown: UP/lib/rhizo-selinux-mode exited 3 reading this boot's SELinux mode"
  unset UP_MODE UP_MODE_FAIL
  check "a startable mode helper leaves the pending-reboot state unchanged" "$(setup_state)" pending-reboot
  export UP_MODE=refuse:kernel-has-no-selinux-namespaces
  UP_RUNNING="6.8.0-1-generic"
  uname() { echo "$UP_RUNNING"; }
  dpkg-query() { printf '%s' "$UP_DPKG"; return "${UP_DPKG_RC:-0}"; }
  pacman() { printf '%s' "$UP_PACMAN"; return "${UP_PACMAN_RC:-0}"; }
  mkdir -p "$UP_TMP/boot"; : > "$UP_TMP/boot/vmlinuz-7.1.0-rc1-rhizo"; RHIZO_BOOT_DIR="$UP_TMP/boot"
  UP_DPKG="" UP_DPKG_RC=1
  check "a leftover Rhizo kernel file with no package reads refused" "$(setup_state)" refused
  UP_DPKG="ii  linux-image-7.1.0-rc1-rhizo"$'\n' UP_DPKG_RC=0
  check "a stock kernel with the Rhizo kernel package installed reads pending-reboot" "$(setup_state)" pending-reboot
  check "status names the reboot into the installed Rhizo kernel" \
        "$(cmd_status 2>&1 | grep -c 'setup        : pending-reboot; reboot into the Rhizo kernel, 7.1.0-rc1-rhizo')" 1
  UP_RUNNING="7.1.0-rc1-rhizo"
  check "the installed Rhizo kernel running without namespaces stays refused" "$(setup_state)" refused
  UP_RUNNING="6.8.0-1-generic" UP_DPKG_RC=2
  check "a package tool that fails reads refused, never pending-reboot" "$(setup_state)" refused
  check "a failing package tool is named in the refusal" \
        "$(cmd_status 2>&1 | grep -c 'setup        : refused (kernel-has-no-selinux-namespaces); .*dpkg-query exited 2 listing the Rhizo kernel')" 1
  UP_DPKG="" UP_DPKG_RC=1
  check "no Rhizo kernel package names no tool failure" \
        "$(cmd_status 2>&1 | grep -c 'dpkg-query exited')" 0
  UP_DPKG=$'ii  linux-image-7.1.0-rc1-rhizo\nii  linux-image-7.10.0-rc1-rhizo\n' UP_DPKG_RC=0
  check "two installed Rhizo kernels name the newest" \
        "$(cmd_status 2>&1 | grep -c 'reboot into the Rhizo kernel, 7.10.0-rc1-rhizo')" 1
  UP_DPKG=$'ii  linux-image-rhizo\n' UP_DPKG_RC=0
  check "a meta package alone reads refused" "$(setup_state)" refused
  UP_DPKG_RC=2
  UP_DPKG="rc  linux-image-7.1.0-rc1-rhizo"$'\n' UP_DPKG_RC=0
  check "a removed Rhizo kernel package with config left reads refused" "$(setup_state)" refused
  RHIZO_OS_RELEASE="$TMP/os-release-cachy"; printf 'ID=cachyos\n' > "$RHIZO_OS_RELEASE"
  UP_PACMAN="linux-rhizo 7.1.0_rc1_rhizo-37"$'\n' UP_PACMAN_RC=0
  check "pacman's Rhizo kernel reads pending-reboot on CachyOS" "$(setup_state)" pending-reboot
  UP_RUNNING="7.1.0-rc1-rhizo"
  check "pacman's Rhizo kernel running without namespaces stays refused" "$(setup_state)" refused
  UP_PACMAN="" UP_PACMAN_RC=1 UP_RUNNING="6.8.0-1-generic"
  check "no pacman Rhizo kernel reads refused" "$(setup_state)" refused
  RHIZO_OS_RELEASE="$TMP/os-release-nothing"
  check "a failed host flavor probe is named in the refusal" \
        "$(cmd_status 2>&1 | grep -c 'setup        : refused (kernel-has-no-selinux-namespaces); .*no-os-release')" 1
  RHIZO_OS_RELEASE="$TMP/os-release-ubuntu"
  unset -f uname dpkg-query pacman
  mkdir -p "$UP_TMP/etc"; echo "pkg_login_tty_on 1" > "$UP_TMP/etc/install-failed"
  printf 'kernel=k\nversion=0.1.1\n' > "$UP_TMP/state/.prepared"
  check "a saved configure failure reads install-failed, even over an earlier version's setup" \
        "$(setup_state)" install-failed
  check "doctor fails the setup, naming the step and what to do" \
        "$(check_setup 2>&1 | grep -c 'setup: fail -- the install failed at pkg_login_tty_on (exit 1): fix that step, then install the same packages again')" 1
  out=$(refuse_start_without_setup 2>&1; echo "rc=$?")
  check "a start after a failed install is refused, naming the step" "$out" \
        "RHIZO_FAIL the install failed at pkg_login_tty_on (exit 1): fix that step, then install the same packages again"
  rm -f "$UP_TMP/etc/install-failed" "$UP_TMP/state/.prepared"
)
UP_WAIT="pacman is running rhizo's configure: wait for it, or with no pacman running remove $UP_TMP/db.lck and run\
 'sudo /usr/share/libalpm/scripts/rhizo-configure'"
( RHIZO_STATE_DIR="$UP_TMP/state" RHIZO_ETC_DIR="$UP_TMP/etc" RHIZO_PACMAN_DB_LOCK="$UP_TMP/db.lck" \
  RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  systemctl() { echo inactive; }
  printf 'kernel=k\nversion=0.1.1\n' > "$UP_TMP/state/.prepared"; : > "$UP_TMP/state/.configure-pending"
  : > "$UP_TMP/db.lck"
  check "a pending configure while pacman holds its lock reads configuring, even over an earlier .prepared" \
        "$(setup_state)" configuring
  check "doctor warns that pacman is still configuring, and how to finish after a crashed pacman" \
        "$(check_setup 2>&1)" "[rhizo]   setup: warn -- $UP_WAIT"
  check "a start while pacman configures is refused, saying to wait" "$(refuse_start_without_setup; echo "rc=$?")" \
        "RHIZO_FAIL $UP_WAIT"
  rm "$UP_TMP/db.lck"
  check "a pending configure with no pacman lock reads install-failed" "$(setup_state)" install-failed
  : > "$UP_TMP/db.lck"; mkdir -p "$UP_TMP/etc"; echo "pkg_accounts 1" > "$UP_TMP/etc/install-failed"
  check "a saved failed step reads install-failed, even while pacman holds its lock" "$(setup_state)" install-failed
  rm -f "$UP_TMP/etc/install-failed" "$UP_TMP/state/.configure-pending" "$UP_TMP/db.lck" "$UP_TMP/state/.prepared"
)
( RHIZO_LIB_DIR="$UP_TMP/lib" RHIZO_STATE_DIR="$UP_TMP/state" RHIZO_GSI_ROOT="$UP_TMP/gsi" \
  RHIZO_VAR_LOG="$UP_TMP/log" RHIZO_SELINUX_ENFORCE="$UP_TMP/enforce" RHIZO_ETC_DIR="$UP_TMP/etc" \
  RHIZO_PACMAN_DB_LOCK="$UP_TMP/db.lck" RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
  rm -f "$UP_TMP/state/.prepared"; echo 1 > "$UP_TMP/enforce"
  sandbox_init_pid() { :; }
  systemctl() { echo inactive; }
  policy_status_line() { echo "loaded (boot-time load)"; }
  out=$(cmd_status 2>&1)
  check "status reports the pending-reboot setup" \
        "$(grep -c '^\[rhizo\] setup        : pending-reboot; reboot to finish the install or upgrade' <<<"$out")" 1
  check "status's sentinel carries setup=pending-reboot" "$(tail -1 <<<"$out")" \
        "RHIZO_STATUS running=0 unit=inactive data=absent setup=pending-reboot"
  read_capability() { echo desktop; }
  check "status --json carries setup" \
        "$(cmd_status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["setup"])')" pending-reboot
  mkdir -p "$UP_TMP/etc"; echo "pkg_state_dirs_btrfs 1" > "$UP_TMP/etc/install-failed"
  out=$(cmd_status 2>&1)
  check "status names the step a failed install stopped at" \
        "$(grep -c '^\[rhizo\] setup        : install-failed; the install failed at pkg_state_dirs_btrfs (exit 1): fix that step, then install the same packages again' <<<"$out")" 1
  check "status's sentinel carries setup=install-failed" "$(tail -1 <<<"$out")" \
        "RHIZO_STATUS running=0 unit=inactive data=absent setup=install-failed"
  rm -f "$UP_TMP/etc/install-failed"
  : > "$UP_TMP/state/.configure-pending"; : > "$UP_TMP/db.lck"
  out=$(cmd_status 2>&1)
  check "status says pacman is still configuring, and how to finish after a crashed pacman" \
        "$(grep -cxF "[rhizo] setup        : configuring; $UP_WAIT" <<<"$out")|$(tail -1 <<<"$out")" \
        "1|RHIZO_STATUS running=0 unit=inactive data=absent setup=configuring"
  rm -f "$UP_TMP/db.lck" "$UP_TMP/state/.configure-pending" "$UP_TMP/state/.prepared"
  out=$(UP_MODE=refuse:kernel-has-no-landlock cmd_status 2>&1)
  check "status names the refusal and its sentence in place of pending-reboot" \
        "$(grep -cxF "[rhizo] setup        : refused (kernel-has-no-landlock); the Rhizo kernel runs without Landlock ABI 6; remove lsm= from its boot line or add landlock to it" <<<"$out")|$(tail -1 <<<"$out")" \
        "1|RHIZO_STATUS running=0 unit=inactive data=absent setup=refused"
  export UP_CALLS="$UP_TMP/mode-calls"; : > "$UP_CALLS"
  UP_MODE=refuse:kernel-has-no-landlock cmd_status >/dev/null 2>&1
  check "status reads the mode helper's answer once" "$(wc -l < "$UP_CALLS")" 1
  : > "$UP_CALLS"; UP_MODE=refuse:kernel-has-no-landlock cmd_status --json >/dev/null 2>&1
  check "status --json reads the mode helper's answer once" "$(wc -l < "$UP_CALLS")" 1
  : > "$UP_CALLS"; UP_MODE=refuse:kernel-has-no-landlock check_setup >/dev/null 2>&1
  check "doctor's setup row reads the mode helper's answer once" "$(wc -l < "$UP_CALLS")" 1
  unset UP_CALLS
  out=$(UP_MODE_FAIL=1 cmd_status 2>&1)
  check "status names a failing mode helper and its exit status" \
        "$(grep -c "^\[rhizo\] setup        : unknown; .*/lib/rhizo-selinux-mode exited 3 reading this boot's SELinux mode" <<<"$out")|$(tail -1 <<<"$out")" \
        "1|RHIZO_STATUS running=0 unit=inactive data=absent setup=helper-failed"
  out=$(cmd_status 2>&1)
  check "status with a startable helper still reads pending-reboot" "$(tail -1 <<<"$out")" \
        "RHIZO_STATUS running=0 unit=inactive data=absent setup=pending-reboot"
)
rm -rf "$UP_TMP"

cmd_device set battery 42 discharging
check "battery keys land in device-state.conf" \
      "$(sort "$DEVICE_DIR/device-state.conf")" \
      "$(printf 'battery_charging=discharging\nbattery_level=42' )"
cmd_device set thermal 55.5
check "a second verb's key does not erase the first's" \
      "$(grep -c '^battery_level=42$' "$DEVICE_DIR/device-state.conf")" 1
check "the second verb's own key is there too" \
      "$(grep -c '^skin_temp_c=55.5$' "$DEVICE_DIR/device-state.conf")" 1
cmd_device set battery 10 charging
check "re-setting a verb replaces its own keys, not duplicates them" \
      "$(grep -c '^battery_level=' "$DEVICE_DIR/device-state.conf")" 1
check "the replaced value is the new one" \
      "$(grep -c '^battery_level=10$' "$DEVICE_DIR/device-state.conf")" 1
check "an out-of-range battery level is refused by name" \
      "$( (cmd_device set battery 101 charging) 2>&1 )" \
      "[rhizo] FAIL: battery level must be an integer 0-100, not '101'"
check "an unknown charging state is refused by name" \
      "$( (cmd_device set battery 50 sideways) 2>&1 )" \
      "[rhizo] FAIL: battery state must be 'charging' or 'discharging', not 'sideways'"
check "a non-numeric thermal value is refused by name" \
      "$( (cmd_device set thermal notanumber) 2>&1 )" \
      "[rhizo] FAIL: thermal value must be a number between -40 and 150, not 'notanumber'"
check "a gps fix outside real coordinates is refused by name" \
      "$( (cmd_device set gps 999 0) 2>&1 )" \
      "[rhizo] FAIL: gps latitude must be a number between -90 and 90, not '999'"
check "a gps altitude outside real heights is refused by name" \
      "$( (cmd_device set gps 51.5 -0.1 99999) 2>&1 )" \
      "[rhizo] FAIL: gps altitude must be a number between -1000 and 30000, not '99999'"
check "a gps fix with an extra argument is refused by name" \
      "$( (cmd_device set gps 51.5 -0.1 11 extra) 2>&1 )" \
      "[rhizo] FAIL: gps takes <lat> <lon> [alt], not '51.5 -0.1 11 extra'"
cmd_device set gps 51.5 -0.1 11 >/dev/null 2>&1
check "a gps fix with an altitude writes gnss_alt" \
      "$(grep -c '^gnss_alt=11$' "$DEVICE_DIR/device-state.conf")" 1
cmd_device set gps 51.5 -0.1 >/dev/null 2>&1
check "a gps fix without an altitude removes the earlier gnss_alt" \
      "$(grep -c '^gnss_alt=' "$DEVICE_DIR/device-state.conf")|$(grep -c '^gnss_lat=51.5$' "$DEVICE_DIR/device-state.conf")" "0|1"

cmd_device set sensor accel 1.5 -2 9.8
check "sensor accel writes one file, not merged into device-state.conf" \
      "$(cat "$DEVICE_DIR/sensor-accel.conf")" "x=1.5
y=-2
z=9.8"
cmd_device set sensor gyro 0.1 0.2 0.3
check "sensor gyro writes its own separate file" \
      "$(cat "$DEVICE_DIR/sensor-gyro.conf")" "x=0.1
y=0.2
z=0.3"
check "setting gyro does not touch accel's own file" \
      "$(cat "$DEVICE_DIR/sensor-accel.conf")" "x=1.5
y=-2
z=9.8"
cmd_device set sensor light 400
check "sensor light writes lux=400" "$(cat "$DEVICE_DIR/sensor-light.conf")" "lux=400"
check "an out-of-range accel value is refused by name" \
      "$( (cmd_device set sensor accel 1 2 99999) 2>&1 )" \
      "[rhizo] FAIL: accel z must be a number between -1000 and 1000, not '99999'"
check "an out-of-range light value is refused by name" \
      "$( (cmd_device set sensor light 999999) 2>&1 )" \
      "[rhizo] FAIL: light lux must be a number between 0 and 200000, not '999999'"
check "an unknown sensor name is refused by name" \
      "$( (cmd_device set sensor frobnicate) 2>&1 )" \
      "[rhizo] FAIL: device set sensor takes accel, gyro or light, not 'frobnicate'"
echo test-frame > "$TMP/frame.png"
cmd_device set camera "$TMP/frame.png"
check "camera copies the file byte for byte into DEVICE_DIR" \
      "$(cat "$DEVICE_DIR/camera.frame")" "test-frame"
check "camera refuses an unreadable path by name" \
      "$( (cmd_device set camera "$TMP/does-not-exist.png") 2>&1 )" \
      "[rhizo] FAIL: cannot read $TMP/does-not-exist.png"
check "device set still takes battery, thermal, gps, sensor or camera -- and no other word" \
      "$( (cmd_device set frobnicate) 2>&1 )" \
      "[rhizo] FAIL: device set takes battery, thermal, gps, sensor or camera, not 'frobnicate'"

check "an unknown device subcommand is refused by name" \
      "$( (cmd_device foo) 2>&1 )" \
      "[rhizo] FAIL: device takes 'set', not 'foo'"
cat > "$TMP/policy.conf" <<'EOF'
# a comment that must survive
[rhizo]
profile = desktop

[server]
idle_stop_s = 600
EOF
( LIB_DIR="$HERE/../../androidd"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/policy.conf"; write_profile_key server )
check "an existing profile= line is updated in place" \
      "$(sed -n 's/^profile = //p' "$TMP/policy.conf")" "server"
check "a comment elsewhere in the file survives" \
      "$(grep -c '^# a comment that must survive$' "$TMP/policy.conf")" 1
check "a key in another section survives untouched" \
      "$(grep -c '^idle_stop_s = 600$' "$TMP/policy.conf")" 1
check "still exactly one profile line, not a duplicate" \
      "$(grep -c '^profile = ' "$TMP/policy.conf")" 1

cat > "$TMP/policy2.conf" <<'EOF'
[server]
idle_stop_s = 30
EOF
( LIB_DIR="$HERE/../../androidd"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/policy2.conf"; write_profile_key desktop )
check "a file with no [rhizo] section gets one appended" \
      "$(grep -c '^\[rhizo\]$' "$TMP/policy2.conf")" 1
check "the appended section carries the key" \
      "$(sed -n 's/^profile = //p' "$TMP/policy2.conf")" "desktop"
check "the file's own pre-existing section is untouched" \
      "$(grep -c '^idle_stop_s = 30$' "$TMP/policy2.conf")" 1

rm -f "$TMP/policy3.conf"
( LIB_DIR="$HERE/../../androidd"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/policy3.conf"; write_profile_key server )
check "an absent policy.conf is created with just the key" \
      "$(sed -n 's/^profile = //p' "$TMP/policy3.conf")" "server"

LIB="$HERE/../../androidd"
printf '# keep me\n[rhizo]\nprofile = server\n' > "$TMP/gpu.conf"
( LIB_DIR="$LIB"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/gpu.conf"; write_policy_key devices dri off )
check "write_policy_key appends [devices] with dri = off" \
      "$(sed -n '/^\[devices\]$/,/^\[/p' "$TMP/gpu.conf" | grep -c '^dri = off$')" 1
check "write_policy_key leaves the other lines alone" \
      "$(grep -c -e '^# keep me$' -e '^profile = server$' "$TMP/gpu.conf")" 2
( LIB_DIR="$LIB"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/gpu.conf"; write_policy_key devices dri on )
check "write_policy_key updates the key in place" \
      "$(grep -c '^dri = ' "$TMP/gpu.conf"):$(sed -n 's/^dri = //p' "$TMP/gpu.conf")" "1:on"
printf '[devices]\ntun = no\n\n[rhizo]\nprofile = server\n' > "$TMP/gpu2.conf"
( LIB_DIR="$LIB"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/gpu2.conf"; write_policy_key devices dri off )
check "write_policy_key adds the key inside an existing section, not after the next one" \
      "$(sed -n '/^\[devices\]$/,/^\[rhizo\]$/p' "$TMP/gpu2.conf" | grep -c -e '^dri = off$' -e '^tun = no$'):$(grep -c '^\[devices\]$' "$TMP/gpu2.conf")" "2:1"
check "write_profile_key still writes [rhizo] profile through the generic writer" \
      "$( ( LIB_DIR="$LIB"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/gpu2.conf"; write_profile_key desktop )
          sed -n 's/^profile = //p' "$TMP/gpu2.conf"):$(grep -c '^dri = off$' "$TMP/gpu2.conf")" "desktop:1"
# print why a policy file does not parse
parse_error_of() { ( LIB_DIR="$LIB"; policy_parse_error "$1" ); }
for pair in "trailing-space|[devices] \ntun = no\n" "upper-case|[devices]\nDRI = on\n" "colon|[devices]\ndri: on\n"; do
  name=${pair%%|*}
  printf '%b' "${pair#*|}" > "$TMP/gpu-$name.conf"
  ( LIB_DIR="$LIB"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/gpu-$name.conf"; write_policy_key devices dri off ) 2>/dev/null
  check "write_policy_key on a $name file leaves one [devices] section and one dri key, set off, and the file parses" \
        "$(grep -c '^\[devices\] *$' "$TMP/gpu-$name.conf"):$(grep -ciE '^dri[ \t]*[=:]' "$TMP/gpu-$name.conf"):$(grep -c '^dri = off$' "$TMP/gpu-$name.conf"):$(parse_error_of "$TMP/gpu-$name.conf")" \
        "1:1:1:"
done
printf '[devices]\ndri = on\n' > "$TMP/gpu-verify.conf"; cp "$TMP/gpu-verify.conf" "$TMP/gpu-verify.orig"
out=$( ( LIB_DIR="$LIB"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/gpu-verify.conf"
         policy_parse_error() { [[ "$1" == "$POLICY_CONF" ]] || echo "fixture: the rewritten file does not parse"; }
         write_policy_key devices dri off ) 2>&1 ); rc=$?
check "write_policy_key refuses a rewrite that does not parse, by name, leaving the file and no temp file" \
      "$rc:$(grep -c 'fixture: the rewritten file does not parse' <<<"$out"):$(cmp -s "$TMP/gpu-verify.orig" "$TMP/gpu-verify.conf" && echo same):$(compgen -G "$TMP/gpu-verify.conf.*" | wc -l)" \
      "1:1:same:0"
printf '[devices]\ndri = off\n' > "$TMP/off.conf"
check "gpu show reads dri off and names the software set" \
      "$( ( LIB_DIR="$LIB"; export RHIZO_POLICY_CONF="$TMP/off.conf"; POLICY_CONF="$TMP/off.conf"; cmd_gpu show ) 2>/dev/null)" \
      "RHIZO_GPU dri=off driver=gpu_driver_software"
printf '[devices]\ndri = maybe\n' > "$TMP/bad-dri.conf"
out=$( ( LIB_DIR="$LIB"; export RHIZO_POLICY_CONF="$TMP/bad-dri.conf"; POLICY_CONF="$TMP/bad-dri.conf"; cmd_gpu show ) 2>&1 ); rc=$?
check "gpu show on a policy.conf that does not parse fails naming the error, never reporting the software mode" \
      "$rc:$(grep -c "dri='maybe', expected yes or no" <<<"$out"):$(grep -c 'RHIZO_GPU' <<<"$out")" "1:1:0"
check "gpu maybe is refused by name" \
      "$( ( LIB_DIR="$LIB"; cmd_gpu maybe ) 2>&1 | grep -c 'gpu takes show, on or off')" 1
printf '#!/bin/sh\necho "detect-gpu-driver: no render node under /x" >&2\nexit 1\n' > "$TMP/no-node.sh"
check "doctor skips the render node when dri is off" \
      "$( ( LIB_DIR="$LIB"; export RHIZO_POLICY_CONF="$TMP/off.conf"; ETC_RHIZO="$TMP"; GPU_RESOLVER="$TMP/no-node.sh"
            report() { echo "$1 $2"; }
            check_render_node ) 2>/dev/null)" "render-node skip"
printf '[devices]\ndri = on\n' > "$TMP/on.conf"
check "doctor's no-node failure names the switch" \
      "$( ( LIB_DIR="$LIB"; export RHIZO_POLICY_CONF="$TMP/on.conf"; ETC_RHIZO="$TMP"; GPU_RESOLVER="$TMP/no-node.sh"
            report() { echo "$*"; }
            check_render_node ) 2>/dev/null | grep -c "render-node fail.*run 'sudo rhizo gpu off'")" 1

GPU_PROC="$TMP/gpu-proc"; GPU_RUN="$TMP/gpu-run"; GPU_INSTALL="$TMP/gpu-install"; GPU_CALLS="$TMP/gpu-calls"
GPU_TEMPLATES="$TMP/gpu-templates"; GPU_CACHE="$TMP/gpu-cache"
mkdir -p "$GPU_PROC/1/attr" "$GPU_RUN" "$GPU_INSTALL/prepare" "$TMP/gpu-empty-install" "$GPU_TEMPLATES" "$GPU_CACHE"
echo 0 > "$TMP/gpu-enforce"
printf '#!/bin/sh\necho "prepare $*" >> "%s"\n[ -z "${GPU_TEMPLATE_KEY:-}" ] || echo "RHIZO_PREPARE_OK template=$GPU_TEMPLATE_KEY"\nexit "${GPU_PREPARE_RC:-0}"\n' "$GPU_CALLS" > "$GPU_INSTALL/prepare/prepare.sh"
chmod +x "$GPU_INSTALL/prepare/prepare.sh"
# run cmd_gpu on a policy text
gpu_case() {
  printf '%b' "$1" > "$TMP/gpu-case.conf"
  printf '%s\0' "$2" > "$GPU_PROC/1/attr/current"
  if [[ "$3" == - ]]; then rm -f "$GPU_RUN/rhizo-policy-mode"; else printf 'dri=%s\n' "$3" > "$GPU_RUN/rhizo-policy-mode"; fi
  shift 3
  : > "$GPU_CALLS"
  ( LIB_DIR="$LIB"; ETC_RHIZO="$TMP"; POLICY_CONF="$TMP/gpu-case.conf"; export RHIZO_POLICY_CONF="$POLICY_CONF"
    PROC_ROOT="$GPU_PROC"; POLICY_MODE_FILE="$GPU_RUN/rhizo-policy-mode"; INSTALL_DIR="${GPU_INSTALL_DIR:-$GPU_INSTALL}"
    TEMPLATES_ROOT="$GPU_TEMPLATES"; VAR_CACHE="$GPU_CACHE"; SELINUX_ENFORCE_FILE="$TMP/gpu-enforce"
    export RHIZO_CLI_TEST_NO_ROOT="${GPU_NO_ROOT-1}" GPU_PREPARE_RC="${GPU_PREPARE_RC:-0}" GPU_TEMPLATE_KEY="${GPU_TEMPLATE_KEY:-}"
    mark_setup_pending() {
      echo "mark $*" >> "$GPU_CALLS"
      [[ -z "${GPU_MARK_FAIL:-}" ]] || die "rhizo-prepare.service is 'not installed', so the next boot would not $1"
    }
    systemctl() { echo "systemctl $*" >> "$GPU_CALLS"; }
    reboot() { echo "reboot $*" >> "$GPU_CALLS"; }
    shutdown() { echo "shutdown $*" >> "$GPU_CALLS"; }
    cmd_gpu "$@" ) 2>"$TMP/gpu-err"
}
# print the gpu case's recorded calls on one line
gpu_calls() { paste -sd';' "$GPU_CALLS"; }
check "gpu with no argument shows" "$(gpu_case '[devices]\ndri = off\n' kernel -)" \
      "RHIZO_GPU dri=off driver=gpu_driver_software"
check "gpu show names the loaded policy's mode when it differs from the configured one" \
      "$(gpu_case '' u:r:rhizo_host:s0 off show)" "RHIZO_GPU dri=on driver=gpu_driver loaded=off"
check "gpu show says why the loaded mode is named, on stderr" \
      "$(grep -c 'applies after a host reboot' "$TMP/gpu-err")" 1
check "gpu show leaves out a loaded mode that matches" \
      "$(gpu_case '[devices]\ndri = off\n' u:r:kernel:s0 off show)" "RHIZO_GPU dri=off driver=gpu_driver_software"
check "gpu show ignores the record while no rhizo policy is loaded" \
      "$(gpu_case '[devices]\ndri = off\n' kernel on show)" "RHIZO_GPU dri=off driver=gpu_driver_software"
out=$(gpu_case '[rhizo]\nprofile = server\n' u:r:rhizo_host:s0 on off); rc=$?
check "gpu off under a policy loaded for on writes the key and asks for a host reboot" \
      "$rc:$out:$(sed -n 's/^dri = //p' "$TMP/gpu-case.conf"):$(grep -c '^profile = server$' "$TMP/gpu-case.conf")" \
      "0:RHIZO_GPU_REBOOT_REQUIRED=1 dri=off loaded=on:off:1"
check "gpu off under a policy loaded for on marks the next boot's prepare and runs none now, nor any reboot" \
      "$(gpu_calls)" "mark rebuild the prepared tree for devices.dri = off gpu off"
check "gpu off under a policy loaded for on says a restart is not enough" \
      "$(grep -c 'applies after a host reboot' "$TMP/gpu-err")" 1
out=$(gpu_case '' u:r:rhizo_host:s0 off off); rc=$?
check "gpu off under a policy already loaded for off needs no reboot and prepares nothing" \
      "$rc:$out:$(gpu_calls)" "0:RHIZO_GPU dri=off driver=gpu_driver_software:"
out=$(gpu_case '' u:r:rhizo_host:s0 - off); rc=$?
check "gpu off under a loaded policy that recorded no mode asks for a reboot" \
      "$rc:$out" "0:RHIZO_GPU_REBOOT_REQUIRED=1 dri=off loaded=unknown"
out=$(GPU_MARK_FAIL=1 gpu_case '' u:r:rhizo_host:s0 on off); rc=$?
check "gpu off whose next-boot prepare cannot be marked still switches, asks for the reboot and says why" \
      "$rc:$out:$(grep -c "rhizo-prepare.service is 'not installed'" "$TMP/gpu-err"):$(grep -c 'each start copies' "$TMP/gpu-err")" \
      "0:RHIZO_GPU_REBOOT_REQUIRED=1 dri=off loaded=on:1:1"
out=$(gpu_case '[devices]\ndri = off\n' kernel - on); rc=$?
check "gpu on with no policy loaded prepares now from the installed payload" \
      "$rc:$out:$(gpu_calls)" "0:RHIZO_GPU dri=on driver=gpu_driver:prepare --payload $LIB"
out=$(GPU_PREPARE_RC=1 gpu_case '' kernel - off); rc=$?
check "gpu off whose prepare fails still switches and says each start copies" \
      "$rc:$out:$(sed -n 's/^dri = //p' "$TMP/gpu-case.conf"):$(grep -c "prepare failed: each start copies until 'sudo rhizo prepare' succeeds" "$TMP/gpu-err")" \
      "0:RHIZO_GPU dri=off driver=gpu_driver_software:off:1"
out=$(gpu_case '[stream]\nenabled = maybe\n' u:r:rhizo_host:s0 on off); rc=$?
check "gpu off on a policy.conf that does not parse is refused and leaves it as it was" \
      "$rc:$out:$(printf '[stream]\nenabled = maybe\n' | cmp -s - "$TMP/gpu-case.conf" && echo same):$(grep -c 'expected yes or no' "$TMP/gpu-err")" \
      "1::same:1"
out=$(GPU_NO_ROOT=0 gpu_case '' u:r:rhizo_host:s0 on off); rc=$?
check_unprivileged "gpu off as another user is refused before it writes" \
      "$rc:$(grep -c 'gpu off must run as root' "$TMP/gpu-err"):$(grep -c '^dri' "$TMP/gpu-case.conf")" "1:1:0"
for k in aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc; do : > "$GPU_TEMPLATES/data-template.$k.img"; done
touch -d '2026-01-01' "$GPU_TEMPLATES/data-template.aaaaaaaaaaaa.img"
touch -d '2026-01-02' "$GPU_TEMPLATES/data-template.bbbbbbbbbbbb.img"
out=$(GPU_TEMPLATE_KEY=cccccccccccc gpu_case '' kernel - off); rc=$?
check "gpu off with no policy loaded goes through prepare's own path, pruning old data templates after a success" \
      "$rc:$out:$(ls "$GPU_TEMPLATES" | tr '\n' ' ')" \
      "0:RHIZO_GPU dri=off driver=gpu_driver_software:data-template.bbbbbbbbbbbb.img data-template.cccccccccccc.img "
out=$(GPU_INSTALL_DIR="$TMP/gpu-empty-install" gpu_case '' kernel - off); rc=$?
check "gpu off with no policy loaded and no prepare script names the missing script and still switches" \
      "$rc:$out:$(grep -c "no $TMP/gpu-empty-install/prepare/prepare.sh" "$TMP/gpu-err"):$(grep -c 'prepare failed' "$TMP/gpu-err")" \
      "0:RHIZO_GPU dri=off driver=gpu_driver_software:1:1"
check "rhizo dispatches gpu to cmd_gpu" "$(grep -cE '^  gpu\) +cmd_gpu "\$@" ;;$' "$HERE/../cli/rhizo.sh")" 1
check "the usage names gpu's three forms" "$(grep -c '^  gpu \[show|on|off\]' "$HERE/../cli/rhizo.sh")" 1

BAD_ETC="$TMP/bad-etc"; mkdir -p "$BAD_ETC" "$TMP/bad-install/bootstrap" "$TMP/bad-install/lib"
printf '# an operator typo\n[stream]\nenabled = maybe\n' > "$BAD_ETC/policy.conf"
cp "$BAD_ETC/policy.conf" "$TMP/bad-policy.orig"
BAD_ERR="$BAD_ETC/policy.conf: [stream] enabled='maybe', expected yes or no"
printf '#!/bin/sh\necho "bootstrap $*"\n' > "$TMP/bad-install/bootstrap/bootstrap.sh"
printf 'pkg_enter_host_mode() { :; }\n' > "$TMP/bad-install/lib/pkg-lib.sh"
chmod +x "$TMP/bad-install/bootstrap/bootstrap.sh"
# run a command against the unparseable policy.conf
bad_policy() {
  cp "$TMP/bad-policy.orig" "$BAD_ETC/policy.conf"
  ( LIB_DIR="$HERE/../../androidd"; ETC_RHIZO="$BAD_ETC"; POLICY_CONF="$BAD_ETC/policy.conf"
    INSTALL_DIR="$TMP/bad-install"; export RHIZO_POLICY_CONF="$POLICY_CONF" RHIZO_CLI_TEST_NO_ROOT=1
    apply_profile() { echo "apply_profile [$1]"; }
    load_host_libs() { :; }; resolve_uid1000() { :; }; ensure_broker_group() { :; }; seed_apk_handler() { :; }
    systemctl() { :; }
    eval "$1" ) 2>"$TMP/bad-err"
}
# print whether the policy file is unchanged or rewritten
bad_unchanged() { cmp -s "$BAD_ETC/policy.conf" "$TMP/bad-policy.orig" && echo unchanged || echo rewritten; }
NOT_REWRITTEN="[rhizo] $BAD_ERR: applying desktop to the units only"
out=$(bad_policy 'cmd_profile show'); rc=$?
check "an unparseable policy.conf: profile show prints desktop alone on stdout" "$rc:$out" \
      "0:RHIZO_PROFILE profile=desktop"
check "an unparseable policy.conf: profile show names the file on stderr" \
      "$(cat "$TMP/bad-err")" "$BAD_ERR -- denying every optional capability"
out=$(bad_policy 'cmd_profile desktop'); rc=$?
check "an unparseable policy.conf: profile desktop applies desktop to the units" "$rc:$out" \
      "0:apply_profile [desktop]"
check "an unparseable policy.conf: profile desktop says the file is not rewritten" \
      "$(cat "$TMP/bad-err")" "$NOT_REWRITTEN"
check "an unparseable policy.conf: profile desktop leaves its bytes" "$(bad_unchanged)" unchanged
out=$(bad_policy 'cmd_profile server'); rc=$?
check "an unparseable policy.conf: profile server is refused before any unit changes" "$rc:$out" "1:"
check "an unparseable policy.conf: the refusal names the file" "$(cat "$TMP/bad-err")" \
      "[rhizo] FAIL: profile server refused: $BAD_ERR: fix it, then set the profile again"
check "an unparseable policy.conf: profile server leaves its bytes" "$(bad_unchanged)" unchanged
out=$(bad_policy 'cmd_install --verbose'); rc=$?
check "an unparseable policy.conf: install applies desktop and goes on to the bootstrap" "$rc:$out" \
      "0:apply_profile [desktop]
bootstrap --verbose"
check "an unparseable policy.conf: install names the file, then says it is not rewritten" \
      "$(cat "$TMP/bad-err")" "$BAD_ERR -- denying every optional capability
$NOT_REWRITTEN"
check "an unparseable policy.conf: install leaves its bytes" "$(bad_unchanged)" unchanged
mkdir -p "$TMP/noisy-lib/sandbox"
printf 'import sys\ndef read_policy(path=None):\n    print("a warning", file=sys.stderr)\n    return {}, None\n' \
  > "$TMP/noisy-lib/sandbox/capabilities.py"
# run check_policy_parse on the unparseable policy.conf
parse_verdict() {
  ( LIB_DIR="$1"; POLICY_CONF="$BAD_ETC/policy.conf"; DOCTOR_ISSUES=0; DOCTOR_WARNINGS=0; check_policy_parse ) 2>&1
}
check "doctor: a parser that also writes to stderr is read by its stdout" "$(parse_verdict "$TMP/noisy-lib")" \
      "a warning
[rhizo]   policy-parse: ok -- $BAD_ETC/policy.conf parses or is absent"
check "doctor: an unparseable policy.conf fails policy-parse by name" \
      "$(parse_verdict "$HERE/../../androidd" | grep -cxF "[rhizo]   policy-parse: fail -- $BAD_ERR: every optional capability is off")" 1

mkdir -p "$TMP/bin"
cat > "$TMP/bin/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "$TMP/systemctl.log"
exit 0
EOF
chmod +x "$TMP/bin/systemctl"

SYSTEMD_ETC="$TMP/systemd-etc"; mkdir -p "$SYSTEMD_ETC"

: > "$TMP/systemctl.log"
( PATH="$TMP/bin:$PATH"; SYSTEMD_ETC_DIR="$SYSTEMD_ETC"; apply_profile server ) >/dev/null
check "server masks (and stops) all nineteen desktop-only system units in one call" \
      "$(grep -cx 'mask --now rhizo-display-pool.path rhizo-display-pool.service rhizo-display-pool-release.service rhizo-app-events.service rhizo-resync.path rhizo-resync.service rhizo-resync-rearm.service rhizo-remove-entries.path rhizo-remove-entries.service rhizo-desktop-attach.path rhizo-desktop-attach.service rhizo-session-start.path rhizo-session-start.service rhizo-hostfs.service rhizo-deskd.service rhizo-desk-token.service rhizo-audiod.service rhizo-displayd.service rhizo-keymapd.service' "$TMP/systemctl.log")" 1
check "server masks the two desktop-only user units for every user manager" \
      "$(grep -cx -- '--global mask rhizo-desktop-session.path rhizo-desktop-session.service rhizo-desk-notify.path rhizo-desk-notify.service' "$TMP/systemctl.log")" 1
check "server never masks a desktop-session unit in the system manager, where it does not run" \
      "$(grep -v -- '--global' "$TMP/systemctl.log" | grep -c 'rhizo-desktop-session')" 0
check "server unmasks the idle unit" \
      "$(grep -cx 'unmask rhizo-server-idle.service' "$TMP/systemctl.log")" 1
check "server enables the idle unit" \
      "$(grep -cx 'enable rhizo-server-idle.service' "$TMP/systemctl.log")" 1
check "rhizo-brokerd.socket is never named -- it stays either way" \
      "$(grep -c 'rhizo-brokerd.socket' "$TMP/systemctl.log")" 0
check "server enables (and starts) the control API socket" \
      "$(grep -cx 'enable --now rhizo-api.socket' "$TMP/systemctl.log")" 1

: > "$TMP/systemctl.log"
( PATH="$TMP/bin:$PATH"; SYSTEMD_ETC_DIR="$SYSTEMD_ETC"; apply_profile desktop ) >/dev/null
check "desktop unmasks all nineteen system units in one call" \
      "$(grep -cx 'unmask rhizo-display-pool.path rhizo-display-pool.service rhizo-display-pool-release.service rhizo-app-events.service rhizo-resync.path rhizo-resync.service rhizo-resync-rearm.service rhizo-remove-entries.path rhizo-remove-entries.service rhizo-desktop-attach.path rhizo-desktop-attach.service rhizo-session-start.path rhizo-session-start.service rhizo-hostfs.service rhizo-deskd.service rhizo-desk-token.service rhizo-audiod.service rhizo-displayd.service rhizo-keymapd.service' "$TMP/systemctl.log")" 1
check "desktop unmasks the two user units for every user manager" \
      "$(grep -cx -- '--global unmask rhizo-desktop-session.path rhizo-desktop-session.service rhizo-desk-notify.path rhizo-desk-notify.service' "$TMP/systemctl.log")" 1
check "desktop enables both user path units, so a host upgraded under server still gets the relay" \
      "$(grep -cx -- '--global enable rhizo-desktop-session.path rhizo-desk-notify.path' "$TMP/systemctl.log")" 1
check "desktop masks the idle unit back" \
      "$(grep -cx 'mask rhizo-server-idle.service' "$TMP/systemctl.log")" 1
check "desktop disables (and stops) the control API socket" \
      "$(grep -cx 'disable --now rhizo-api.socket' "$TMP/systemctl.log")" 1

# run apply_profile with a stubbed systemctl
profile_calls() {
  : > "$TMP/systemctl.log"
  (
    SYSTEMD_ETC_DIR="$SYSTEMD_ETC"; ANDROIDD_STUB="$2"; START_RC="${3:-0}"
    DESKTOP_SESSION_ENV="${4:-$TMP/session.env}"; DESKTOP_SESSION_ENV_WAIT_S=1
    systemctl() {
      echo "$*" >> "$TMP/systemctl.log"
      case "$*" in
        "is-active androidd.service") echo "$ANDROIDD_STUB" ;;
        "show -p Wants --value androidd.service")
          echo "rhizo-policy.service rhizo-hostfs.service rhizo-update-begin.service rhizo-deskd.service rhizo-audiod.service rhizo-displayd.service rhizo-keymapd.service rhizo-rtd.service" ;;
        "is-enabled rhizo-display-pool.path"|"is-enabled rhizo-display-pool-release.service"|"is-enabled rhizo-app-events.service"|"is-enabled rhizo-resync.path"|"is-enabled rhizo-remove-entries.path"|"is-enabled rhizo-desktop-attach.path")
          echo enabled ;;
        is-enabled*) echo static ;;
        start*) return "$START_RC" ;;
      esac
      return 0
    }
    apply_profile "$1" 2>&1
  )
}
: > "$TMP/session.env"
out=$(profile_calls desktop active)
check "desktop with Android running starts the session watch, the enabled watchers, then androidd.service's daemons without blocking" \
      "$(grep -E '^start ' "$TMP/systemctl.log" | tr '\n' ';')" \
      "start rhizo-desktop-attach.path;start rhizo-display-pool.path rhizo-display-pool-release.service rhizo-app-events.service rhizo-resync.path rhizo-remove-entries.path;start --no-block rhizo-hostfs.service rhizo-deskd.service rhizo-audiod.service rhizo-displayd.service rhizo-keymapd.service;"
check "desktop starts them after the unmask" \
      "$(awk '/^unmask /{u=NR} /^start /{if(!s)s=NR} END{print (u && s && u<s) ? "after" : "before"}' "$TMP/systemctl.log")" after
check "desktop edits the idle unit and the API socket before it starts the session watch" \
      "$(awk '/^mask rhizo-server-idle/{m=NR} /^start rhizo-desktop-attach.path/{a=NR} END{print (m && a && m<a) ? "before" : "after"}' "$TMP/systemctl.log")" before
out=$(profile_calls desktop active 0 "$TMP/absent.env")
check "desktop with Android running but no desktop session starts the watch and the watchers and leaves the daemons to the attach path" \
      "$(grep -E '^start ' "$TMP/systemctl.log" | tr '\n' ';')/$(grep -c 'no desktop session within 1s' <<<"$out")" \
      "start rhizo-desktop-attach.path;start rhizo-display-pool.path rhizo-display-pool-release.service rhizo-app-events.service rhizo-resync.path rhizo-remove-entries.path;/1"
check "desktop leaves the units a start pulls in or a path triggers to systemd" \
      "$(grep -cE '^start .*(rhizo-desk-token|rhizo-resync\.service|rhizo-remove-entries\.service|rhizo-display-pool\.service|rhizo-desktop-attach\.service|rhizo-resync-rearm)' "$TMP/systemctl.log")" 0
check "desktop never starts or restarts the sandbox" \
      "$(grep -cE '^(re)?start .*androidd' "$TMP/systemctl.log")" 0
check "desktop with Android running ends on the profile line" \
      "$(tail -1 <<<"$out")" "RHIZO_PROFILE profile=desktop"
out=$(profile_calls desktop inactive)
check "desktop with Android down starts only the session watch" \
      "$(grep -E '^start ' "$TMP/systemctl.log" | tr '\n' ';')" "start rhizo-desktop-attach.path;"
out=$(profile_calls desktop activating)
check "desktop with Android starting starts the session watch, the watchers and the daemons" \
      "$(grep -cE '^start ' "$TMP/systemctl.log")" 3
out=$(profile_calls desktop deactivating)
check "desktop with Android stopping starts only the session watch" \
      "$(grep -E '^start ' "$TMP/systemctl.log" | tr '\n' ';')" "start rhizo-desktop-attach.path;"
out=$(profile_calls server active)
check "server starts nothing" "$(grep -cE '^(re)?start ' "$TMP/systemctl.log")" 0
out=$(profile_calls desktop active 1)
check "a start the manager refuses fails the switch by name, with no profile line" \
      "$(grep -c -E 'systemctl start (failed for the desktop-only units|rhizo-desktop-attach.path failed)' <<<"$out")/$(grep -cx 'RHIZO_PROFILE profile=desktop' <<<"$out")" 1/0

cat > "$TMP/bin/systemctl-nounit" <<EOF
#!/bin/sh
echo "\$*" >> "$TMP/systemctl.log"
[ "\$1" = cat ] && exit 1
exit 0
EOF
chmod +x "$TMP/bin/systemctl-nounit"
: > "$TMP/systemctl.log"
# run the stub that reports a missing unit
out=$( PATH="$TMP/bin:$PATH"; systemctl() { "$TMP/bin/systemctl-nounit" "$@"; }; set_api_socket enable 2>&1 )
check "an absent control API socket warns by name rather than dying" \
      "$(grep -c 'warning: rhizo-api.socket is not installed$' <<<"$out")" 1
check "an absent control API socket is never enabled" \
      "$(grep -c 'enable --now rhizo-api.socket' "$TMP/systemctl.log")" 0

echo "not a symlink" > "$SYSTEMD_ETC/rhizo-display-pool.path"
ln -sf /dev/null "$SYSTEMD_ETC/rhizo-resync.path"
: > "$TMP/systemctl.log"
( PATH="$TMP/bin:$PATH"; SYSTEMD_ETC_DIR="$SYSTEMD_ETC"; apply_profile server ) >/dev/null
check "a leftover regular file at a unit's override path is removed before masking" \
      "$([[ -e "$SYSTEMD_ETC/rhizo-display-pool.path" ]] && echo present || echo gone)" gone
check "an existing symlink at a unit's override path is left alone" \
      "$(readlink "$SYSTEMD_ETC/rhizo-resync.path")" /dev/null
check "masking still ran after clearing the leftover file" \
      "$(grep -cx 'mask --now rhizo-display-pool.path rhizo-display-pool.service rhizo-display-pool-release.service rhizo-app-events.service rhizo-resync.path rhizo-resync.service rhizo-resync-rearm.service rhizo-remove-entries.path rhizo-remove-entries.service rhizo-desktop-attach.path rhizo-desktop-attach.service rhizo-session-start.path rhizo-session-start.service rhizo-hostfs.service rhizo-deskd.service rhizo-desk-token.service rhizo-audiod.service rhizo-displayd.service rhizo-keymapd.service' "$TMP/systemctl.log")" 1

rm -f "$SYSTEMD_ETC/rhizo-server-idle.service"
echo "not a symlink" > "$SYSTEMD_ETC/rhizo-server-idle.service"
: > "$TMP/systemctl.log"
( PATH="$TMP/bin:$PATH"; SYSTEMD_ETC_DIR="$SYSTEMD_ETC"; apply_profile desktop ) >/dev/null
check "desktop's own leftover regular file (the idle unit) is removed before masking" \
      "$([[ -e "$SYSTEMD_ETC/rhizo-server-idle.service" ]] && echo present || echo gone)" gone
check "desktop still masks the idle unit after clearing its leftover file" \
      "$(grep -cx 'mask rhizo-server-idle.service' "$TMP/systemctl.log")" 1

# run apply_profile with stubbed systemctl
server_switch_report() {
  (
    DU_STUB="$1" OWNER_STUB="$2" MGR_STUB="$3" RUNUSER_RC="${4:-0}"
    ETC_RHIZO="$TMP/switch-etc"; rm -rf "$ETC_RHIZO"; mkdir -p "$ETC_RHIZO"
    [[ "$DU_STUB" == - ]] || echo "$DU_STUB" > "$ETC_RHIZO/desktop-user"
    SYSTEMD_ETC_DIR="$SYSTEMD_ETC"
    systemctl() { [[ "$*" == "is-active user@1000.service" ]] && echo "$MGR_STUB"; return 0; }
    getent() { [[ "$*" == "passwd 1000" && "$OWNER_STUB" != - ]] && echo "$OWNER_STUB:x:1000:1000::/home/$OWNER_STUB:/bin/bash"; }
    runuser() { echo "ran: runuser $*"; return "$RUNUSER_RC"; }
    apply_profile server 2>&1
  )
}
# print the command that stops the desktop session units as the user
stop_as() { echo "ran: runuser -u $1 -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user stop rhizo-desktop-session.path rhizo-desktop-session.service rhizo-desk-notify.path rhizo-desk-notify.service"; }
out=$(server_switch_report - ubuntu active)
check "no desktop-user file: server still switches, stopping the pair as uid 1000's account" \
      "$(grep -cx 'RHIZO_PROFILE profile=server' <<<"$out")/$(grep -cxF "$(stop_as ubuntu)" <<<"$out")" 1/1
out=$(server_switch_report alice alice active)
check "a configured desktop user owning uid 1000 stops the pair in its own manager" \
      "$(grep -cx 'RHIZO_PROFILE profile=server' <<<"$out")/$(grep -cxF "$(stop_as alice)" <<<"$out")" 1/1
out=$(server_switch_report alice bob active)
check "a desktop-user file naming another account stops the pair as uid 1000's owner, never as it" \
      "$(grep -cx 'RHIZO_PROFILE profile=server' <<<"$out")/$(grep -cxF "$(stop_as bob)" <<<"$out")/$(grep -c 'runuser -u alice' <<<"$out")" 1/1/0
out=$(server_switch_report - ubuntu inactive)
check "no running manager for uid 1000: server switches and enters no manager" \
      "$(grep -cx 'RHIZO_PROFILE profile=server' <<<"$out")/$(grep -c '^ran: runuser' <<<"$out")" 1/0
out=$(server_switch_report alice - active)
check "a running uid 1000 manager no account resolves to refuses the switch by name" \
      "$(grep -cx 'RHIZO_PROFILE profile=server' <<<"$out")/$(grep -c 'user@1000.service is running with no account at uid 1000' <<<"$out")/$(grep -c '^ran: runuser' <<<"$out")" 0/1/0
out=$(server_switch_report alice alice active 1)
check "a stop the running manager refuses fails the switch" \
      "$(grep -cx 'RHIZO_PROFILE profile=server' <<<"$out")/$(grep -c 'could not stop rhizo-desktop-session.path rhizo-desktop-session.service rhizo-desk-notify.path rhizo-desk-notify.service' <<<"$out")" 0/1

# run check_server_profile_for_instance with a stubbed profile
profile_verdict() {
  (
    PROFILE_STUB="$1"
    read_capability() { printf '%s\n' "$PROFILE_STUB"; }
    check_server_profile_for_instance "$2" 2>&1 && echo accepted
  )
}
check "instance 0 is accepted whatever the profile" \
      "$(profile_verdict desktop 0)" "accepted"
check "an id above 0 is accepted under the server profile" \
      "$(profile_verdict server 3)" "accepted"
out=$(profile_verdict desktop 3)
check "an id above 0 is refused under the desktop profile" \
      "$(grep -c 'instance add 3 refused' <<<"$out")" 1
check "the refusal names the profile it actually read" \
      "$(grep -c 'rhizo.profile is desktop, not server' <<<"$out")" 1
check "the refusal says what to do about it" \
      "$(grep -c "run 'rhizo profile server' first" <<<"$out")" 1
check "the refusal names the units the profile masks" \
      "$(grep -c 'rhizo-remove-entries.service' <<<"$out")" 1

INITTMP="$TMP/initpid"; mkdir -p "$INITTMP"
# write a fake /proc entry for a pid
fakeproc() {
  local pid="$1" cg="$2"; shift 2
  mkdir -p "$INITTMP/proc/$pid"
  printf '%s\0' "$@" > "$INITTMP/proc/$pid/cmdline"
  printf '0::%s\n' "$cg" > "$INITTMP/proc/$pid/cgroup"
}
fakeproc 4242 /rhizo/init init second_stage
fakeproc 10001 /rhizo/init init second_stage
fakeproc 1200 /user.slice/user-1000.slice/session-3.scope init second_stage
fakeproc 1300 /rhizo-host init second_stage
fakeproc 1400 /rhizo/system/uid_1000/pid_1400 /system/bin/surfaceflinger
fakeproc 1500 /rhizo-2/init init second_stage
bash -c 'exec -a "init second_stage" sleep 60' &
real_decoy=$!
echo 4242 > "$INITTMP/live"
echo 999999 > "$INITTMP/dead"
echo 1400 > "$INITTMP/notinit"
echo "not-a-pid" > "$INITTMP/garbage"
: > "$INITTMP/empty"
check "a pid file naming a live init answers with that pid" \
      "$( PROC_ROOT="$INITTMP/proc" INIT_PID_FILE="$INITTMP/live"; sandbox_init_pid )" 4242
check "a pid file naming a dead pid answers with nothing, never a peer's init" \
      "$( PROC_ROOT="$INITTMP/proc" INIT_PID_FILE="$INITTMP/dead"; sandbox_init_pid )" ""
check "a pid file naming a live process that is not init answers with nothing" \
      "$( PROC_ROOT="$INITTMP/proc" INIT_PID_FILE="$INITTMP/notinit"; sandbox_init_pid )" ""
check "a pid file holding junk answers with nothing" \
      "$( PROC_ROOT="$INITTMP/proc" INIT_PID_FILE="$INITTMP/garbage"; sandbox_init_pid )" ""
check "an empty pid file answers with nothing" \
      "$( PROC_ROOT="$INITTMP/proc" INIT_PID_FILE="$INITTMP/empty"; sandbox_init_pid )" ""
check "no pid file at all: the scan finds the init in the stack's own cgroup, past decoys named alike" \
      "$( PROC_ROOT="$INITTMP/proc" INIT_PID_FILE="$INITTMP/absent"; sandbox_init_pid )" 4242
rm -rf "$INITTMP/proc/4242" "$INITTMP/proc/10001"
fakeproc 4343 /system.slice/androidd.service/android/init init second_stage
check "no pid file, the stack under androidd.service's delegated cgroup: the scan finds its init" \
      "$( PROC_ROOT="$INITTMP/proc" INIT_PID_FILE="$INITTMP/absent"; sandbox_init_pid )" 4343
rm -rf "$INITTMP/proc/4343"
check "no pid file and only decoys named alike outside the stack: the scan answers with nothing" \
      "$( PROC_ROOT="$INITTMP/proc" INIT_PID_FILE="$INITTMP/absent"; sandbox_init_pid )" ""
kill "$real_decoy" 2>/dev/null
wait "$real_decoy" 2>/dev/null
unset -f fakeproc

ADBETC="$TMP/adbetc"; mkdir -p "$ADBETC"
echo "not a key at all" > "$TMP/badkey.txt"
out=$( ( ETC_RHIZO="$ADBETC"; ADB_KEYS_FILE="$ADBETC/adb_keys"; cmd_adbkey_add "$TMP/badkey.txt" ) 2>&1)
check "a non-key line is refused by name" \
      "$(grep -c 'not an adb public key' <<<"$out")" 1
check "nothing was written for a refused key" \
      "$(wc -l < "$ADBETC/adb_keys" 2>/dev/null || echo 0)" 0

REALKEY="QAAA$(head -c 260 /dev/zero | tr '\0' 'A')== user@host"
out=$( ( ETC_RHIZO="$ADBETC"; ADB_KEYS_FILE="$ADBETC/adb_keys"; echo "$REALKEY" | cmd_adbkey_add - ) 2>&1)
check "a real key line is accepted" "$(tail -1 <<<"$out")" "RHIZO_ADBKEY added=1"
check "the key line is written verbatim" "$(cat "$ADBETC/adb_keys")" "$REALKEY"
check "adb_keys is 0640" "$(stat -c %a "$ADBETC/adb_keys")" "640"

out=$( ( ETC_RHIZO="$ADBETC"; ADB_KEYS_FILE="$ADBETC/adb_keys"; echo "$REALKEY" | cmd_adbkey_add - ) 2>&1)
check "re-adding the same key is a no-op, not a duplicate line" \
      "$(tail -1 <<<"$out")-$(wc -l < "$ADBETC/adb_keys")" "RHIZO_ADBKEY added=0-1"

fpr=$(fingerprint_adb_key "$(awk '{print $1}' <<<"$REALKEY")")
out=$( ( ETC_RHIZO="$ADBETC"; ADB_KEYS_FILE="$ADBETC/adb_keys"; cmd_adbkey_list ) 2>&1)
check "list names the registered fingerprint" "$(grep -c "$fpr" <<<"$out")" 1
out=$( ( ETC_RHIZO="$ADBETC"; ADB_KEYS_FILE="$ADBETC/adb_keys"; cmd_adbkey_remove "$fpr" ) 2>&1)
check "remove takes the key out by fingerprint" "$(tail -1 <<<"$out")" "RHIZO_ADBKEY removed=1"
check "the file is empty afterwards" "$(wc -l < "$ADBETC/adb_keys")" 0

LIVEDIR="$TMP/live/misc/adb"; mkdir -p "$LIVEDIR"
printf '%s\n%s\n' "$REALKEY" "QAAA$(head -c 260 /dev/zero | tr '\0' 'B')== other@host" > "$LIVEDIR/adb_keys"
chmod 0640 "$LIVEDIR/adb_keys"; chmod 02750 "$LIVEDIR"
CHOWN_LOG="$TMP/chown.log"; : > "$CHOWN_LOG"
# log its arguments
out=$( ( LIVE_ADB_KEYS="$LIVEDIR/adb_keys"; chown() { echo "$*" >> "$CHOWN_LOG"; }
         revoke_live_adb_key "$fpr" ) 2>&1)
check "the live revoke strips the key and keeps the other" \
      "$(grep -c "^QAAA" "$LIVEDIR/adb_keys")-$(grep -c 'user@host' "$LIVEDIR/adb_keys")" "1-0"
check "the live revoke takes the dir and file to root before reading" \
      "$(head -2 "$CHOWN_LOG" | cut -d' ' -f1 | tr '\n' ' ')" "0:0 0:0 "
check "the live revoke hands both back to system:shell" \
      "$(tail -2 "$CHOWN_LOG" | cut -d' ' -f1 | tr '\n' ' ')" "1000:2000 1000:2000 "
check "the live dir is 2750 again" "$(stat -c %a "$LIVEDIR")" "2750"
check "the live file is 640 again" "$(stat -c %a "$LIVEDIR/adb_keys")" "640"

SYSPROC="$TMP/sysproc"
mkdir -p "$SYSPROC/100/root" "$SYSPROC/100/ns" "$SYSPROC/150/ns" "$SYSPROC/160/ns"
printf 'init\0second_stage\0' > "$SYSPROC/100/cmdline"; echo init > "$SYSPROC/100/comm"
ln -s 'pid:[4026532001]' "$SYSPROC/100/ns/pid"
echo adbd > "$SYSPROC/150/comm"; ln -s 'pid:[4026532001]' "$SYSPROC/150/ns/pid"
echo adbd > "$SYSPROC/160/comm"; ln -s 'pid:[4026531836]' "$SYSPROC/160/ns/pid"
printf '%s\n%s\n' "$REALKEY" "QAAA$(head -c 260 /dev/zero | tr '\0' 'B')== other@host" > "$SYSPROC/100/root/adb_keys"
echo 100 > "$TMP/sysinit.pid"
sys_inode=$(stat -c %i "$SYSPROC/100/root/adb_keys")
KILL_LOG="$TMP/kill.log"; : > "$KILL_LOG"
# log its arguments
out=$( ( PROC_ROOT="$SYSPROC"; INIT_PID_FILE="$TMP/sysinit.pid"; kill() { echo "$*" >> "$KILL_LOG"; }
         revoke_system_adb_key "$fpr" ) 2>&1)
check "the live /adb_keys loses the removed key and keeps the other" \
      "$(grep -c 'user@host' "$SYSPROC/100/root/adb_keys" 2>/dev/null)-$(grep -c 'other@host' "$SYSPROC/100/root/adb_keys" 2>/dev/null)" "0-1"
check "the live /adb_keys is rewritten in place, keeping its inode and label" \
      "$(stat -c %i "$SYSPROC/100/root/adb_keys")" "$sys_inode"
check "only the sandbox's own adbd is killed, so its open sessions end" "$(cat "$KILL_LOG")" "-KILL 150"
: > "$KILL_LOG"
# log its arguments
out=$( ( PROC_ROOT="$SYSPROC"; INIT_PID_FILE="$TMP/sysinit.pid"; kill() { echo "$*" >> "$KILL_LOG"; }
         revoke_system_adb_key "$fpr" ) 2>&1)
check "a key the live /adb_keys no longer holds restarts nothing" "$(cat "$KILL_LOG")" ""
out=$( ( ETC_RHIZO="$ADBETC"; ADB_KEYS_FILE="$ADBETC/adb_keys"; echo "$REALKEY" | cmd_adbkey_add - >/dev/null
         printf '%s\n' "$REALKEY" >> "$SYSPROC/100/root/adb_keys"
         PROC_ROOT="$SYSPROC"; INIT_PID_FILE="$TMP/sysinit.pid"; LIVE_ADB_KEYS="$TMP/absent/adb_keys"
         kill() { echo "$*" >> "$KILL_LOG"; }; cmd_adbkey_remove "$fpr" ) 2>&1)
check "adb-key remove revokes live through the running sandbox's /adb_keys" \
      "$(grep -c 'user@host' "$SYSPROC/100/root/adb_keys")-$(cat "$KILL_LOG")" "0--KILL 150"

RESET_ROOT="$TMP/reset"; mkdir -p "$RESET_ROOT/install/"{bootstrap,prepare,update,teardown,lib,cli} "$RESET_ROOT/state"
RESET_ARGS_LOG="$TMP/reset-args.log"; : > "$RESET_ARGS_LOG"
cat > "$RESET_ROOT/install/prepare/prepare.sh" <<EOF
#!/bin/sh
echo "\$* RHIZO_DATA_IMG=\$RHIZO_DATA_IMG" >> "$RESET_ARGS_LOG"
echo "RHIZO_PREPARE_OK key=abc tree=/x sepolicy=/y template=def data=instantiated dexopt=skipped/skipped binder=z"
EOF
chmod +x "$RESET_ROOT/install/prepare/prepare.sh"
cat > "$RESET_ROOT/install/prepare/await-boot-completed.py" <<'EOF'
#!/usr/bin/env python3
import sys
sys.exit(0)
EOF
chmod +x "$RESET_ROOT/install/prepare/await-boot-completed.py"
: > "$TMP/systemctl.log"
cat > "$RESET_ROOT/state/data.img.meta" <<'EOF'
release=a17
variant=user
template=def
provenance=instantiated
EOF
touch "$RESET_ROOT/state/data.img"
out=$(
  PATH="$TMP/bin:$PATH"
  INSTALL_DIR="$RESET_ROOT/install"; DATA_IMG="$RESET_ROOT/state/data.img"
  wait_boot_completed() { return 0; }
  do_reset 2>&1
)
check "reset prints its own sentinel" "$(tail -1 <<<"$out")" "RHIZO_RESET ok"
check "reset targets the release recorded in data.img.meta, not the a16 default" \
      "$(grep -o -- '--release [a-z0-9]*' "$RESET_ARGS_LOG")" "--release a17"
check "reset passes --wipe-data -- the only path that re-instantiates" \
      "$(grep -c -- '--wipe-data' "$RESET_ARGS_LOG")" 1
check "reset skips the setup boot's own dexopt pass" \
      "$(grep -c -- '--skip-setup-boot' "$RESET_ARGS_LOG")" 1
check "reset calls prepare.sh exactly once -- no second instantiate" \
      "$(wc -l < "$RESET_ARGS_LOG")" 1
check "reset stops androidd.service before touching data.img" \
      "$(grep -cx 'stop androidd.service' "$TMP/systemctl.log")" 1
check "reset starts androidd.service after the template lands" \
      "$(grep -cx 'start androidd.service' "$TMP/systemctl.log")" 1
check "reset at id 0 pins the image it read the release from" \
      "$(grep -c "RHIZO_DATA_IMG=$RESET_ROOT/state/data.img" "$RESET_ARGS_LOG")" 1
check "reset at id 0 names instance 0 to the prepare script" \
      "$(grep -o -- '--sandbox-id [0-9]*' "$RESET_ARGS_LOG")" "--sandbox-id 0"

R2="$TMP/reset-i2"; mkdir -p "$R2/install/"{bootstrap,prepare,update,teardown,lib,cli} "$R2/state/instances/2"
R2ARGS="$TMP/reset-i2-args.log"; : > "$R2ARGS"
cat > "$R2/install/prepare/prepare.sh" <<EOF
#!/bin/sh
echo "\$* RHIZO_DATA_IMG=\$RHIZO_DATA_IMG" >> "$R2ARGS"
rm -f "\$RHIZO_DATA_IMG"
echo "RHIZO_PREPARE_OK key=abc tree=/x sepolicy=/y template=def data=instantiated dexopt=skipped/skipped binder=z"
EOF
chmod +x "$R2/install/prepare/prepare.sh"
cp "$RESET_ROOT/install/prepare/await-boot-completed.py" "$R2/install/prepare/await-boot-completed.py"
printf 'release=a16\nvariant=user\n' > "$R2/state/data.img.meta"
echo "instance 0's apps and data" > "$R2/state/data.img"
printf 'release=a17\nvariant=user\n' > "$R2/state/instances/2/data.img.meta"
echo "instance 2's apps and data" > "$R2/state/instances/2/data.img"
: > "$TMP/systemctl.log"
out=$(
  PATH="$TMP/bin:$PATH"
  STATE_DIR="$R2/state"; INSTALL_DIR="$R2/install"
  set_instance_vars 2
  wait_boot_completed() { return 0; }
  do_reset 2>&1
)
check "reset -i 2 prints its own sentinel" "$(tail -1 <<<"$out")" "RHIZO_RESET ok"
check "reset -i 2 wipes INSTANCE 2's data.img" \
      "$([[ -e "$R2/state/instances/2/data.img" ]] && echo present || echo wiped)" wiped
check "reset -i 2 leaves instance 0's data.img and every app in it untouched" \
      "$(cat "$R2/state/data.img")" "instance 0's apps and data"
check "reset -i 2 names instance 2 to the prepare script" \
      "$(grep -o -- '--sandbox-id [0-9]*' "$R2ARGS")" "--sandbox-id 2"
check "reset -i 2 pins instance 2's own image, exported so the child sees it" \
      "$(grep -c "RHIZO_DATA_IMG=$R2/state/instances/2/data.img" "$R2ARGS")" 1
check "reset -i 2 reads the release from instance 2's sidecar, not instance 0's" \
      "$(grep -o -- '--release [a-z0-9]*' "$R2ARGS")" "--release a17"
check "reset -i 2 stops androidd@2.service" \
      "$(grep -cx 'stop androidd@2.service' "$TMP/systemctl.log")" 1
check "reset -i 2 starts androidd@2.service" \
      "$(grep -cx 'start androidd@2.service' "$TMP/systemctl.log")" 1
check "reset -i 2 never touches instance 0's unit" \
      "$(grep -c 'androidd\.service' "$TMP/systemctl.log")" 0

: > "$TMP/systemctl.log"
echo "instance 2's apps and data" > "$R2/state/instances/2/data.img"
printf 'release=a17\nvariant=user\n' > "$R2/state/instances/2/data.img.meta"
out=$(
  PATH="$TMP/bin:$PATH"
  STATE_DIR="$R2/state"; INSTALL_DIR="$R2/install"
  set_instance_vars 2
  wait_boot_completed() { return 1; }
  do_reset 2>&1
)
check "reset fails when THIS instance never reports sys.boot_completed" \
      "$(grep -c 'RHIZO_RESET ok' <<<"$out")" 0
check "the refusal names the instance whose own property never arrived" \
      "$(grep -c 'instance 2 reported no sys.boot_completed=1 over its probe socket' <<<"$out")" 1

PREP="$HERE/../prepare/prepare.sh"
check "prepare at id 0 resolves instance 0's own image and unit" \
      "$("$PREP" --show-paths | sed -n 's/.*\(data_img=[^ ]*\) \(unit=[^ ]*\).*/\1 \2/p')" \
      "data_img=/var/lib/rhizo/data.img unit=androidd.service"
check "prepare at id 2 resolves instance 2's own image and unit" \
      "$("$PREP" --sandbox-id 2 --show-paths | sed -n 's/.*\(data_img=[^ ]*\) \(unit=[^ ]*\).*/\1 \2/p')" \
      "data_img=/var/lib/rhizo/instances/2/data.img unit=androidd@2.service"
check "prepare keeps each instance's resume record apart" \
      "$("$PREP" --sandbox-id 2 --show-paths | grep -c 'resume_file=/root/.rhizo_prepare_resume-2')" 1
check "prepare canonicalizes a leading-zero id to one instance" \
      "$("$PREP" --sandbox-id 07 --show-paths | sed -n 's/.*\(unit=[^ ]*\).*/\1/p')" "unit=androidd@7.service"
check "prepare refuses an out-of-range id" \
      "$("$PREP" --sandbox-id 100 --show-paths >/dev/null 2>&1; echo $?)" 2
out=$("$PREP" --sandbox-id 2 2>&1)
check "prepare above id 0 refuses a setup boot by name" \
      "$(grep -c 'RHIZO_PREPARE_REFUSED reason=instance-setup-boot' <<<"$out")" 1
check "the refusal names --skip-setup-boot" \
      "$(grep -c 'needs --skip-setup-boot' <<<"$out")" 1

check "instance_data_img(0) is the plain path" "$(RHIZO_STATE_DIR="$TMP/state" RHIZO_CLI_SOURCE_ONLY=1 bash -c "source '$CLI'; instance_data_img 0")" "$TMP/state/data.img"
check "instance_data_img(3) is per-instance" "$(RHIZO_STATE_DIR="$TMP/state" RHIZO_CLI_SOURCE_ONLY=1 bash -c "source '$CLI'; instance_data_img 3")" "$TMP/state/instances/3/data.img"
check "instance_unit(0) is the plain unit" "$(RHIZO_CLI_SOURCE_ONLY=1 bash -c "source '$CLI'; instance_unit 0")" "androidd.service"
check "instance_unit(3) is the template instantiation" "$(RHIZO_CLI_SOURCE_ONLY=1 bash -c "source '$CLI'; instance_unit 3")" "androidd@3.service"

# print accept or reject for an instance id
check_id_verdict() { ( check_instance_id "$1" ) >/dev/null 2>&1 && echo accept || echo reject; }
for pair in "0 reject" "1 accept" "99 accept" "100 reject" "-1 reject" "abc reject" "07 accept"; do
  set -- $pair
  check "instance id $1 -> $2" "$(check_id_verdict "$1")" "$2"
done

# print accept or reject for a template name
check_tmpl_verdict() { ( check_template_name "$1" ) >/dev/null 2>&1 && echo accept || echo reject; }
for pair in "clean-1 accept" "a.b_c accept" "../etc reject" "bad;rm reject" ".hidden reject" "ok accept"; do
  set -- $pair
  check "template name '$1' -> $2" "$(check_tmpl_verdict "$1")" "$2"
done

(
  RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  reason=$(pool_refusal 4 $((2000 * 1024 * 1024)))
  check "pool_refusal names the size and the shortfall" \
        "$([[ "$reason" == *"pool size 4 needs "* && "$reason" == *" MB of headroom"* ]] && echo yes || echo no)" yes
  check "pool_refusal is silent when it fits" \
        "$(pool_refusal 1 $((600 * 1024 * 1024)))" ""
  check "pool_refusal 0 always fits (an empty pool costs nothing)" \
        "$(pool_refusal 0 0)" ""
)

POOL_TMP=$(mktemp -d)
(
  RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  ETC_RHIZO="$POOL_TMP/etc"; POOL_MEMBERS="$POOL_TMP/pool-members"
  mkdir -p "$ETC_RHIZO/instances"
  : > "$POOL_MEMBERS"
  check "pool_member_count of an empty file is 0" "$(pool_member_count)" 0
  check "the first free id on an empty host is 1" "$(pool_next_free_id)" 1
  echo "RHIZO_SANDBOX_ID=1" > "$ETC_RHIZO/instances/1.env"
  check "a configured instance is skipped" "$(pool_next_free_id)" 2
  echo 2 >> "$POOL_MEMBERS"
  check "pool_member_count reflects one member" "$(pool_member_count)" 1
  check "a pool member is skipped too" "$(pool_next_free_id)" 3
)
rm -rf "$POOL_TMP"

(
  RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  take_dash_i device set battery 20 discharging
  check "take_dash_i: no -i present leaves the value empty" "$TAKE_DASH_I_VALUE" ""
  check "take_dash_i: no -i present leaves every arg, in order" \
        "${TAKE_DASH_I_ARGS[*]}" "device set battery 20 discharging"

  take_dash_i -i 2 device set battery 20 discharging
  check "take_dash_i: a leading -i is captured" "$TAKE_DASH_I_VALUE" "2"
  check "take_dash_i: a leading -i is removed, the rest survives in order" \
        "${TAKE_DASH_I_ARGS[*]}" "device set battery 20 discharging"

  take_dash_i device set -i 2 battery 20 discharging
  check "take_dash_i: a trailing -i is captured" "$TAKE_DASH_I_VALUE" "2"
  check "take_dash_i: a trailing -i is removed, the rest survives in order" \
        "${TAKE_DASH_I_ARGS[*]}" "device set battery 20 discharging"
)

(
  RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  sandbox_id_verdict() { ( validate_sandbox_id "$1" ) >/dev/null 2>&1 && echo accept || echo reject; }
  for pair in "0 accept" "99 accept" "100 reject" "-1 reject" "abc reject"; do
    set -- $pair
    check "validate_sandbox_id $1 -> $2" "$(sandbox_id_verdict "$1")" "$2"
  done
  check "validate_sandbox_id's refusal matches sandbox/core.py's own wording (out of range)" \
        "$( (validate_sandbox_id 100) 2>&1 )" \
        "[rhizo] FAIL: RHIZO_SANDBOX_ID=100 refused: NET_SUBNET below needs a single id 0-99, two free octet digits and no sign"
  check "validate_sandbox_id's refusal matches sandbox/core.py's own wording (non-numeric)" \
        "$( (validate_sandbox_id abc) 2>&1 )" \
        "[rhizo] FAIL: RHIZO_SANDBOX_ID=abc refused: NET_SUBNET below needs a single id 0-99, two free octet digits and no sign"
)

cat > "$TMP/id_vars.sh" <<'EOF'
#!/bin/bash
source "$CLI_PATH"
printf '%s\n' "$RUN_ROOT" "$PROBE_SOCK" "$LIVE_ADB_KEYS" "$INBOX_HOST_DIR" "$DATA_IMG" "$DEVICE_DIR" "$LAUNCH_LOG" "$INIT_PID_FILE"
EOF
# print the per-instance variables of rhizo.sh
id_vars() {
  RHIZO_SANDBOX_ID="$1" RHIZO_STATE_DIR="$TMP/idstate" RHIZO_CLI_SOURCE_ONLY=1 CLI_PATH="$CLI" \
    bash "$TMP/id_vars.sh"
}
id0_vars=$(id_vars 0)
check "id 0: RUN_ROOT is byte-identical to today" "$(sed -n 1p <<<"$id0_vars")" "/run/rhizo"
check "id 0: PROBE_SOCK is byte-identical to today" "$(sed -n 2p <<<"$id0_vars")" \
      "/run/rhizo/data/local/tmp/rhizo-probe.sock"
check "id 0: LIVE_ADB_KEYS is byte-identical to today" "$(sed -n 3p <<<"$id0_vars")" \
      "/run/rhizo/data/misc/adb/adb_keys"
check "id 0: INBOX_HOST_DIR is byte-identical to today" "$(sed -n 4p <<<"$id0_vars")" "/run/rhizo/data/rhizo_inbox"
check "id 0: DATA_IMG is byte-identical to today" "$(sed -n 5p <<<"$id0_vars")" "$TMP/idstate/data.img"
check "id 0: DEVICE_DIR is byte-identical to today" "$(sed -n 6p <<<"$id0_vars")" "$TMP/idstate/device-state"
check "id 0: LAUNCH_LOG is byte-identical to today" "$(sed -n 7p <<<"$id0_vars")" "/run/rhizo-launch/rhizo-launch.log"
check "id 0: INIT_PID_FILE is byte-identical to today" "$(sed -n 8p <<<"$id0_vars")" \
      "/root/.rhizo_init_pid"

id2_vars=$(id_vars 2)
check "id 2: RUN_ROOT gets the suffixed form" "$(sed -n 1p <<<"$id2_vars")" "/run/rhizo-2"
check "id 2: PROBE_SOCK gets the suffixed form" "$(sed -n 2p <<<"$id2_vars")" \
      "/run/rhizo-2/data/local/tmp/rhizo-probe.sock"
check "id 2: LIVE_ADB_KEYS gets the suffixed form" "$(sed -n 3p <<<"$id2_vars")" \
      "/run/rhizo-2/data/misc/adb/adb_keys"
check "id 2: INBOX_HOST_DIR gets the suffixed form" "$(sed -n 4p <<<"$id2_vars")" "/run/rhizo-2/data/rhizo_inbox"
check "id 2: DATA_IMG gets the suffixed form" "$(sed -n 5p <<<"$id2_vars")" "$TMP/idstate/instances/2/data.img"
check "id 2: DEVICE_DIR gets the suffixed form" "$(sed -n 6p <<<"$id2_vars")" "$TMP/idstate/device-state-2"
check "id 2: LAUNCH_LOG gets the suffixed form" "$(sed -n 7p <<<"$id2_vars")" \
      "/run/rhizo-launch-2/rhizo-launch.log"
check "id 2: INIT_PID_FILE gets the suffixed form" "$(sed -n 8p <<<"$id2_vars")" \
      "/root/.rhizo_init_pid-2"

(
  RHIZO_STATE_DIR="$TMP/selstate" RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"

  GLOBAL_INSTANCE_ID=2
  cmd_device set battery 77 charging
  check "leading -i (GLOBAL_INSTANCE_ID): battery lands under instance 2's own DEVICE_DIR" \
        "$(grep -c '^battery_level=77$' "$TMP/selstate/device-state-2/device-state.conf" 2>/dev/null)" 1
  GLOBAL_INSTANCE_ID=""

  cmd_device set -i 3 battery 55 discharging
  check "trailing -i: battery lands under instance 3's own DEVICE_DIR" \
        "$(grep -c '^battery_level=55$' "$TMP/selstate/device-state-3/device-state.conf" 2>/dev/null)" 1
  check "trailing -i does not also write instance 2's own DEVICE_DIR" \
        "$(grep -c '^battery_level=55$' "$TMP/selstate/device-state-2/device-state.conf" 2>/dev/null)" 0

  GLOBAL_INSTANCE_ID=100
  check "a bad id is refused by name (leading position)" \
        "$( (cmd_device set battery 1 charging) 2>&1 )" \
        "[rhizo] FAIL: RHIZO_SANDBOX_ID=100 refused: NET_SUBNET below needs a single id 0-99, two free octet digits and no sign"
  GLOBAL_INSTANCE_ID=""
  check "a bad id is refused by name (trailing position)" \
        "$( (cmd_device set -i notanumber battery 1 charging) 2>&1 )" \
        "[rhizo] FAIL: RHIZO_SANDBOX_ID=notanumber refused: NET_SUBNET below needs a single id 0-99, two free octet digits and no sign"
)

mkdir -p "$TMP/bin"
ORDER_LOG="$TMP/order.log"
cat > "$TMP/bin/systemctl" <<EOF
#!/bin/sh
echo "systemctl \$*" >> "$ORDER_LOG"
case "\$1" in
  is-active)
    echo "\$FAKE_UNIT_STATE"
    [ "\$FAKE_UNIT_STATE" = active ] && exit 0
    exit 3
    ;;
  show)
    echo "\$FAKE_FREEZER_STATE"
    exit 0
    ;;
esac
[ -n "\$FAKE_SYSTEMCTL_FAIL" ] && [ "\$1" = "\$FAKE_SYSTEMCTL_FAIL" ] && exit 1
exit 0
EOF
chmod +x "$TMP/bin/systemctl"
cat > "$TMP/bin/sync" <<EOF
#!/bin/sh
echo "sync \$*" >> "$ORDER_LOG"
exit 0
EOF
chmod +x "$TMP/bin/sync"

(
  STATE_DIR="$TMP/snapstate-running"; TEMPLATES_ROOT="$STATE_DIR/templates"
  mkdir -p "$STATE_DIR"
  echo "fake data.img" > "$STATE_DIR/data.img"
  PATH="$TMP/bin:$PATH"
  export FAKE_UNIT_STATE=active FAKE_FREEZER_STATE=running
  wait_probe_socket() { echo "wait_probe_socket $*" >> "$ORDER_LOG"; return 0; }
  : > "$ORDER_LOG"
  out=$(do_snapshot 0 running-case 2>&1)
  check "do_snapshot (running instance) succeeds" \
        "$(grep -c '^RHIZO_SNAPSHOT name=running-case' <<<"$out")" 1
  check "running instance: never unfreezes (it was not frozen)" "$(grep -c 'systemctl thaw' "$ORDER_LOG")" 0
  check "running instance: never freezes (it was not a pool member)" \
        "$(grep -c 'systemctl freeze' "$ORDER_LOG")" 0
  stop_line=$(grep -n 'systemctl stop androidd.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  sync_line=$(grep -n '^sync -f' "$ORDER_LOG" | head -1 | cut -d: -f1)
  start_line=$(grep -n 'systemctl start androidd.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  check "running instance: stop, sync and start all ran" \
        "$( [[ -n "$stop_line" && -n "$sync_line" && -n "$start_line" ]] && echo yes || echo no )" yes
  check "running instance: stop before sync before start, in that order" \
        "$( (( stop_line < sync_line && sync_line < start_line )) && echo yes || echo no )" yes
)

(
  STATE_DIR="$TMP/snapstate-pool"; TEMPLATES_ROOT="$STATE_DIR/templates"
  mkdir -p "$STATE_DIR/instances/2"
  echo "fake pool member data.img" > "$STATE_DIR/instances/2/data.img"
  PATH="$TMP/bin:$PATH"
  export FAKE_UNIT_STATE=active FAKE_FREEZER_STATE=frozen
  wait_probe_socket() { echo "wait_probe_socket $*" >> "$ORDER_LOG"; return 0; }
  wait_boot_completed() { echo "wait_boot_completed $*" >> "$ORDER_LOG"; return 0; }
  : > "$ORDER_LOG"
  out=$(do_snapshot 2 pool-case 2>&1)
  check "do_snapshot (frozen pool member) succeeds" \
        "$(grep -c '^RHIZO_SNAPSHOT name=pool-case' <<<"$out")" 1
  unfreeze_line=$(grep -n 'systemctl thaw androidd@2.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  stop_line=$(grep -n 'systemctl stop androidd@2.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  sync_line=$(grep -n '^sync -f' "$ORDER_LOG" | head -1 | cut -d: -f1)
  start_line=$(grep -n 'systemctl start androidd@2.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  wait_line=$(grep -n 'wait_probe_socket 2 120' "$ORDER_LOG" | head -1 | cut -d: -f1)
  boot_line=$(grep -n 'wait_boot_completed 2 300' "$ORDER_LOG" | head -1 | cut -d: -f1)
  freeze_line=$(grep -n 'systemctl freeze androidd@2.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  check "frozen pool member: unfreeze, stop, sync, start, wait, boot wait and freeze all ran" \
        "$( [[ -n "$unfreeze_line" && -n "$stop_line" && -n "$sync_line" && -n "$start_line" \
              && -n "$wait_line" && -n "$boot_line" && -n "$freeze_line" ]] && echo yes || echo no )" yes
  check "frozen pool member: unfreeze < stop < sync < start < wait < boot wait < freeze, in that order" \
        "$( (( unfreeze_line < stop_line && stop_line < sync_line && sync_line < start_line \
              && start_line < wait_line && wait_line < boot_line && boot_line < freeze_line )) && echo yes || echo no )" yes
)

(
  PR="$TMP/poolreconcile"; mkdir -p "$PR/etc/instances"
  ETC_RHIZO="$PR/etc"; STATE_DIR="$PR"; TEMPLATES_ROOT="$PR/templates"
  POOL_MEMBERS="$PR/pool-members"; POOL_PENDING="$PR/pool-pending"
  POOL_LOCK_FILE="$PR/pool.lock"; POOL_CONF="$PR/pool.conf"
  PATH="$TMP/bin:$PATH"
  export FAKE_UNIT_STATE=inactive FAKE_FREEZER_STATE=running
  check_server_profile_for_instance() { return 0; }
  wait_probe_socket() { echo "wait_probe_socket $*" >> "$ORDER_LOG"; return 0; }
  wait_boot_completed() { echo "wait_boot_completed $*" >> "$ORDER_LOG"; [[ "$PR_BOOTS" == yes ]]; }

  : > "$POOL_MEMBERS"; : > "$POOL_PENDING"; : > "$ORDER_LOG"
  PR_BOOTS=yes
  reconcile_pool 1 >/dev/null 2>&1
  start_line=$(grep -n 'systemctl start androidd@1.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  wait_line=$(grep -n 'wait_probe_socket 1 120' "$ORDER_LOG" | head -1 | cut -d: -f1)
  boot_line=$(grep -n 'wait_boot_completed 1 300' "$ORDER_LOG" | head -1 | cut -d: -f1)
  freeze_line=$(grep -n 'systemctl freeze androidd@1.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  check "reconcile_pool: start, probe-socket wait, boot wait and freeze all ran" \
        "$( [[ -n "$start_line" && -n "$wait_line" && -n "$boot_line" && -n "$freeze_line" ]] && echo yes || echo no )" yes
  check "reconcile_pool: start < probe-socket wait < boot wait < freeze -- booted, then frozen" \
        "$( (( start_line < wait_line && wait_line < boot_line && boot_line < freeze_line )) && echo yes || echo no )" yes
  check "reconcile_pool: the booted member is a member" "$(tr '\n' ' ' < "$POOL_MEMBERS")" "1 "
  check "reconcile_pool: its reservation is gone" "$(pool_pending_count)" 0

  rm -f "$PR/etc/instances/"*.env; : > "$POOL_MEMBERS"; : > "$POOL_PENDING"; : > "$ORDER_LOG"
  PR_BOOTS=no
  reconcile_pool 1 >/dev/null 2>&1
  check "reconcile_pool: a member that never boots is never frozen" \
        "$(grep -c 'systemctl freeze' "$ORDER_LOG")" 0
  check "reconcile_pool: a member that never boots is stopped" \
        "$(grep -c 'systemctl stop androidd@1.service' "$ORDER_LOG")" 1
  check "reconcile_pool: a member that never boots is left out of the pool" "$(pool_member_count)" 0
  check "reconcile_pool: a member that never boots leaves no reservation" "$(pool_pending_count)" 0
)

(
  STATE_DIR="$TMP/snapstate-activating"; TEMPLATES_ROOT="$STATE_DIR/templates"
  mkdir -p "$STATE_DIR/instances/4"
  echo "fake booting data.img" > "$STATE_DIR/instances/4/data.img"
  PATH="$TMP/bin:$PATH"
  export FAKE_UNIT_STATE=activating FAKE_FREEZER_STATE=running
  wait_probe_socket() { echo "wait_probe_socket $*" >> "$ORDER_LOG"; return 0; }
  : > "$ORDER_LOG"
  out=$(do_snapshot 4 activating-case 2>&1)
  check "do_snapshot (activating instance) still succeeds" \
        "$(grep -c '^RHIZO_SNAPSHOT name=activating-case' <<<"$out")" 1
  check "an activating instance IS stopped before its data.img is copied" \
        "$(grep -c 'systemctl stop androidd@4.service' "$ORDER_LOG")" 1
  stop_line=$(grep -n 'systemctl stop androidd@4.service' "$ORDER_LOG" | head -1 | cut -d: -f1)
  sync_line=$(grep -n '^sync -f' "$ORDER_LOG" | head -1 | cut -d: -f1)
  check "the stop comes before the sync for an activating instance too" \
        "$( (( stop_line < sync_line )) && echo yes || echo no )" yes
  check "an activating instance is started again afterwards" \
        "$(grep -c 'systemctl start androidd@4.service' "$ORDER_LOG")" 1
)

(
  STATE_DIR="$TMP/snapstate-inactive"; TEMPLATES_ROOT="$STATE_DIR/templates"
  mkdir -p "$STATE_DIR/instances/5"
  echo "fake stopped data.img" > "$STATE_DIR/instances/5/data.img"
  PATH="$TMP/bin:$PATH"
  export FAKE_UNIT_STATE=inactive FAKE_FREEZER_STATE=running
  : > "$ORDER_LOG"
  out=$(do_snapshot 5 inactive-case 2>&1)
  check "do_snapshot (inactive instance) succeeds" \
        "$(grep -c '^RHIZO_SNAPSHOT name=inactive-case' <<<"$out")" 1
  check "an inactive instance is never stopped" "$(grep -c 'systemctl stop' "$ORDER_LOG")" 0
  check "an inactive instance is never started just because it was snapshotted" \
        "$(grep -c 'systemctl start' "$ORDER_LOG")" 0
)

(
  STATE_DIR="$TMP/snapstate-syncfail"; TEMPLATES_ROOT="$STATE_DIR/templates"
  mkdir -p "$STATE_DIR/instances/6"
  echo "fake data.img" > "$STATE_DIR/instances/6/data.img"
  PATH="$TMP/bin:$PATH"
  export FAKE_UNIT_STATE=active FAKE_FREEZER_STATE=running
  : > "$ORDER_LOG"
  sync() { echo "sync $*" >> "$ORDER_LOG"; return 1; }
  out=$( do_snapshot 6 syncfail-case 2>&1 )
  check "a failed sync refuses the snapshot" \
        "$(grep -c 'RHIZO_SNAPSHOT' <<<"$out")" 0
  check "a failed sync still restores the instance it stopped" \
        "$(grep -c 'systemctl start androidd@6.service' "$ORDER_LOG")" 1
)

(
  STATE_DIR="$TMP/snapstate-signal"; TEMPLATES_ROOT="$STATE_DIR/templates"
  mkdir -p "$STATE_DIR/instances/8"
  echo "fake data.img" > "$STATE_DIR/instances/8/data.img"
  PATH="$TMP/bin:$PATH"
  export FAKE_UNIT_STATE=active FAKE_FREEZER_STATE=running
  : > "$ORDER_LOG"
  cp() { kill -TERM $BASHPID; }
  ( do_snapshot 8 signal-case ) >/dev/null 2>&1
  check "a signal after the stop still restores the instance" \
        "$(grep -c 'systemctl start androidd@8.service' "$ORDER_LOG")" 1
  check "the interrupted snapshot wrote no template" \
        "$(find "$TMP/snapstate-signal/templates" -mindepth 1 -maxdepth 1 -name '*signal-case*' 2>/dev/null | wc -l)" 0
)

(
  RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  PL="$TMP/poollock"; mkdir -p "$PL/etc"
  ETC_RHIZO="$PL/etc"; STATE_DIR="$PL"
  POOL_MEMBERS="$PL/pool-members"; POOL_PENDING="$PL/pool-pending"
  POOL_LOCK_FILE="$PL/pool.lock"; POOL_CONF="$PL/pool.conf"
  : > "$POOL_MEMBERS"; : > "$POOL_PENDING"

  pool_member_add 3; pool_member_add 7; pool_member_add 9
  check "pool_member_add appends each id once" "$(tr '\n' ' ' < "$POOL_MEMBERS")" "3 7 9 "
  pool_member_add 7
  check "pool_member_add is idempotent -- no duplicate line" \
        "$(grep -cx 7 "$POOL_MEMBERS")" 1
  pool_member_claim 7
  check "pool_member_claim removes the id it was given, not the last line" \
        "$(tr '\n' ' ' < "$POOL_MEMBERS")" "3 9 "
  check "claiming an id that is not a member reports so" \
        "$(pool_member_claim 42 && echo claimed || echo absent)" absent
  check "a failed claim leaves the file alone" "$(tr '\n' ' ' < "$POOL_MEMBERS")" "3 9 "

  pool_pending_add 4
  check "a pending reservation is not counted as a member" "$(pool_member_count)" 2
  check "a pending reservation is counted as pending" "$(pool_pending_count)" 1
  check "pool_next_free_id skips a pending reservation" "$(pool_next_free_id)" 1
  pool_member_add 1; pool_member_add 2
  check "pool_next_free_id skips members and reservations together" "$(pool_next_free_id)" 5
  pool_pending_drop 4
  check "a dropped reservation frees its id again" "$(pool_next_free_id)" 4

  printf 'K=6\n' > "$POOL_CONF"
  check "pool_target_k reads the configured K" "$(pool_target_k)" 6
  rm -f "$POOL_CONF"
  check "pool_target_k answers 0 with no pool.conf" "$(pool_target_k)" 0
)

(
  RHIZO_STATE_DIR="$TMP/canon" RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  check "instance_data_img 07 is instance_data_img 7" \
        "$(instance_data_img 07)" "$(instance_data_img 7)"
  check "instance_unit 07 is instance_unit 7" "$(instance_unit 07)" "androidd@7.service"
  check "instance_unit 00 is still instance 0's bare unit" "$(instance_unit 00)" "androidd.service"
  check "instance_run_root 07 is instance 7's own tree" "$(instance_run_root 07)" "/run/rhizo-7"
  check "instance_boot_log 0 is the id-0 log the drop-in writes" \
        "$(instance_boot_log 0)" "/var/log/rhizo/boot.log"
  check "instance_boot_log 2 is the templated drop-in's own boot-%i.log" \
        "$(instance_boot_log 2)" "/var/log/rhizo/boot-2.log"
)
(
  CANON="$TMP/canon-add"; mkdir -p "$CANON/etc/instances" "$CANON/state"
  RHIZO_STATE_DIR="$CANON/state" RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  ETC_RHIZO="$CANON/etc"; STATE_DIR="$CANON/state"
  out=$(do_instance_add 07 "" 2>&1)
  check "instance add 07 configures instance 7, not instance 07" \
        "$(grep -c 'RHIZO_INSTANCE_ADDED id=7 ' <<<"$out")" 1
  check "the env file is named for the canonical id" \
        "$([[ -s "$CANON/etc/instances/7.env" ]] && echo present || echo absent)" present
  check "no second env file is minted for the zero-padded spelling" \
        "$([[ -e "$CANON/etc/instances/07.env" ]] && echo present || echo absent)" absent
  check "the env file carries the id the launcher will read back" \
        "$(cat "$CANON/etc/instances/7.env")" "RHIZO_SANDBOX_ID=7"
  out=$( (do_instance_add 7 "") 2>&1 )
  check "adding 7 after 07 is refused as already configured" \
        "$(grep -c 'instance 7 is already configured' <<<"$out")" 1
)

(
  RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  PROC_ROOT="$TMP/f12proc"; mkdir -p "$PROC_ROOT/4242"
  printf 'init\0second_stage\0' > "$PROC_ROOT/4242/cmdline"
  printf '0::/rhizo/init\n' > "$PROC_ROOT/4242/cgroup"
  INIT_PID_BASE="$TMP/does-not-exist-pidfile"
  INIT_PID_FILE="$INIT_PID_BASE"
  check "id 0 with no pid file still falls back to the scan" \
        "$(sandbox_init_pid 0)" 4242
  check "an id above 0 with no pid file of its own answers with nothing" \
        "$(sandbox_init_pid 5)" ""
)

(
  RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  read_capability() { echo lan; }
  ip() { echo "default via 10.0.0.1 dev eth9"; }
  sandbox_init_pid() { echo 1234; }
  PROBE_CLIENT="$TMP/no-such-probe-client"
  check "at id 0 under adb_reach=lan the uplink address is printed" \
        "$(ip() { case "$*" in *route*) echo "default via 10.0.0.1 dev eth9" ;; *) echo "9: eth9    inet 10.0.0.7/24 brd 10.0.0.255 scope global eth9" ;; esac; }
           sandbox_adb_endpoint 0)" "10.0.0.7:5555"
  check "above id 0 the uplink address is never offered as that instance's" \
        "$(ip() { case "$*" in *route*) echo "default via 10.0.0.1 dev eth9" ;; *) echo "9: eth9    inet 10.0.0.7/24 brd 10.0.0.255 scope global eth9" ;; esac; }
           sandbox_adb_endpoint 3)" ""
)

(
  RM="$TMP/instremove"; mkdir -p "$RM/etc/instances" "$RM/state/instances/3"
  RHIZO_STATE_DIR="$RM/state" RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  ETC_RHIZO="$RM/etc"; STATE_DIR="$RM/state"
  POOL_MEMBERS="$RM/state/pool-members"; POOL_PENDING="$RM/state/pool-pending"
  POOL_LOCK_FILE="$RM/state/pool.lock"
  PATH="$TMP/bin:$PATH"
  export FAKE_UNIT_STATE=inactive FAKE_FREEZER_STATE=running
  : > "$ORDER_LOG"
  echo "RHIZO_SANDBOX_ID=3" > "$RM/etc/instances/3.env"
  echo "instance 3's data" > "$RM/state/instances/3/data.img"
  printf 'release=a16\n' > "$RM/state/instances/3/data.img.meta"
  printf '2\n3\n5\n' > "$POOL_MEMBERS"
  out=$(do_instance_remove 3 0 2>&1)
  check "instance remove reports what it removed" \
        "$(grep -c '^RHIZO_INSTANCE_REMOVED id=3 env=removed data=removed' <<<"$out")" 1
  check "instance remove takes the id out of the pool by id, not by position" \
        "$(tr '\n' ' ' < "$POOL_MEMBERS")" "2 5 "
  check "instance remove stops the instance's own unit" \
        "$(grep -c 'systemctl stop androidd@3.service' "$ORDER_LOG")" 1
  check "instance remove deletes the env file, which is what frees the id" \
        "$([[ -e "$RM/etc/instances/3.env" ]] && echo present || echo gone)" gone
  check "instance remove deletes the image the id was burning" \
        "$([[ -e "$RM/state/instances/3/data.img" ]] && echo present || echo gone)" gone
  check "instance remove deletes the image's sidecar with it" \
        "$([[ -e "$RM/state/instances/3/data.img.meta" ]] && echo present || echo gone)" gone
  check "the freed id is selectable again" "$(pool_next_free_id)" 1

  mkdir -p "$RM/state/instances/9"
  echo "RHIZO_SANDBOX_ID=9" > "$RM/etc/instances/9.env"
  echo "instance 9's data" > "$RM/state/instances/9/data.img"
  out=$(do_instance_remove 9 1 2>&1)
  check "--keep-data says so in the sentinel" \
        "$(grep -c '^RHIZO_INSTANCE_REMOVED id=9 env=removed data=kept' <<<"$out")" 1
  check "--keep-data leaves the image on disk" \
        "$(cat "$RM/state/instances/9/data.img")" "instance 9's data"

  mkdir -p "$RM/bin" "$RM/state/instances/4/vendor/bin" "$RM/state/instances/4/vendor/lib64"
  real4=$(realpath "$RM/state/instances/4")
  printf '%s\n' \
    "22 1 252:1 / / rw,relatime shared:1 - ext4 /dev/vda1 rw" \
    "30 22 0:25 / /run rw,nosuid shared:5 - tmpfs tmpfs rw" \
    "90 30 0:60 / /run/rhizo-4 rw shared:40 - tmpfs tmpfs rw,mode=755" \
    "91 90 252:1 $real4/vendor /run/rhizo-4/vendor rw,relatime - ext4 /dev/vda1 rw" \
    "92 91 252:1 /var/lib/rhizo/prepared/k/vendor/bin /run/rhizo-4/vendor/bin ro,relatime - ext4 /dev/vda1 rw" \
    "93 91 252:1 /var/lib/rhizo/prepared/k/vendor/lib64 /run/rhizo-4/vendor/lib64 ro,relatime - ext4 /dev/vda1 rw" \
    "94 90 7:50 / /run/rhizo-4/data rw - ext4 /dev/loop50 rw" \
    "95 22 252:1 /srv/other /mnt/other rw - ext4 /dev/vda1 rw" \
    "96 22 252:1 $real4-old /mnt/sibling rw - ext4 /dev/vda1 rw" > "$RM/mountinfo"
  printf 'import sys\nopen("%s/umount.log", "a").write(" ".join(sys.argv[1:]) + "\\n")\n' "$RM" > "$RM/bin/hostops.py"
  : > "$RM/umount.log"
  echo "RHIZO_SANDBOX_ID=4" > "$RM/etc/instances/4.env"
  out=$(RHIZO_HOSTOPS="$RM/bin/hostops.py"; PROC_MOUNTINFO="$RM/mountinfo"; do_instance_remove 4 0 2>&1)
  check "instance remove detaches a mount inside its directory reached only through a bind of it, deepest first" \
        "$(tr '\n' ' ' < "$RM/umount.log")" \
        "umount -b /run/rhizo-4/vendor/bin umount -b /run/rhizo-4/vendor/lib64 umount -b /run/rhizo-4/vendor "
  check "... and then removes the directory" \
        "$(grep -c '^RHIZO_INSTANCE_REMOVED id=4 ' <<<"$out"):$([[ -e "$RM/state/instances/4" ]] && echo present || echo gone)" "1:gone"
  printf 'import sys\nsys.exit(32)\n' > "$RM/bin/hostops.py"
  mkdir -p "$RM/state/instances/4/vendor/bin"
  echo "RHIZO_SANDBOX_ID=4" > "$RM/etc/instances/4.env"
  out=$(RHIZO_HOSTOPS="$RM/bin/hostops.py"; PROC_MOUNTINFO="$RM/mountinfo"; do_instance_remove 4 0 2>&1)
  check "a mount that will not go refuses the remove by name before any rm walks it" \
        "$(grep -c 'cannot unmount /run/rhizo-4/vendor/bin under instance 4.s directory: instance 4 not removed' <<<"$out"):$([[ -d "$RM/state/instances/4/vendor/bin" ]] && echo kept || echo walked)" "1:kept"
)
(
  RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
  check_unprivileged "instance remove is refused to a non-root caller by name" \
        "$( (cmd_instance_remove 3) 2>&1 | grep -c 'instance remove must run as root')" 1
  check "instance remove refuses id 0, which 'rhizo install' owns" \
        "$( (check_instance_id 0) 2>&1 | grep -c 'instance id must be 1-99')" 1
  check "instance takes remove as a subcommand" \
        "$( (cmd_instance) 2>&1 | grep -c 'add, remove, allocate, release')" 1
  check "an unknown instance subcommand names the four that exist" \
        "$( (cmd_instance nope) 2>&1 | grep -c 'add, remove, allocate or release')" 1
  check "pool takes reconcile as a subcommand" \
        "$( (cmd_pool) 2>&1 | grep -c 'set, status, reconcile')" 1
)

# run start_sandbox with stubbed systemctl
run_start_sandbox() {
  (
    ST="$TMP/start-setup"; rm -rf "$ST"; mkdir -p "$ST/state" "$ST/lib"
    printf '#!/bin/sh\necho host\n' > "$ST/lib/rhizo-selinux-mode"; chmod +x "$ST/lib/rhizo-selinux-mode"
    case "${3:-done}" in
      done) printf 'kernel=k\nversion=0.1.1\n' > "$ST/state/.prepared"; echo 1 > "$ST/enforce" ;;
      enforcing) echo 1 > "$ST/enforce" ;;
      no-lsm) : ;;
    esac
    export RHIZO_LIB_DIR="$ST/lib"
    RHIZO_STATE_DIR="$ST/state" RHIZO_SELINUX_ENFORCE="$ST/enforce" RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
    STUB_STATE="$1" STUB_INIT="$2" STUB_RUNNING="${4:-0}"
    require_probe_client() { :; }
    sandbox_init_pid() { [[ -f "$TMP/started" || "$STUB_RUNNING" == 1 ]] && printf '%s' "$STUB_INIT"; }
    systemctl() {
      case "$1" in
        start) : > "$TMP/started" ;;
        is-active) if [[ -f "$TMP/started" ]]; then echo "$STUB_STATE"; else echo inactive; fi ;;
      esac
    }
    android_sh() { echo 1; }
    rm -f "$TMP/started"
    start_sandbox && echo "STARTED"
  ) 2>&1 | tail -1
}
out=$(timeout 30 bash -c "$(declare -f run_start_sandbox); CLI='$CLI' TMP='$TMP'; run_start_sandbox inactive ''")
check "a unit that went inactive with no init fails the launch at once, naming its state" \
      "$out" "RHIZO_FAIL androidd.service went inactive with no 'init second_stage': see journalctl -u androidd.service and /var/log/rhizo/supervisor.log"
out=$(timeout 30 bash -c "$(declare -f run_start_sandbox); CLI='$CLI' TMP='$TMP'; run_start_sandbox failed ''")
check "a unit that failed with no init fails the launch at once too" \
      "$(grep -c "^RHIZO_FAIL androidd.service went failed" <<<"$out")" 1
out=$(timeout 30 bash -c "$(declare -f run_start_sandbox); CLI='$CLI' TMP='$TMP'; run_start_sandbox active 4242")
check "an active unit whose init reads boot_completed=1 still starts" "$out" "STARTED"

out=$(timeout 30 bash -c "$(declare -f run_start_sandbox); CLI='$CLI' TMP='$TMP'; run_start_sandbox active 4242 enforcing")
check "a start with setup pending a reboot under enforcement refuses, naming the reboot that finishes the upgrade" \
      "$(grep -c "^RHIZO_FAIL setup is pending a reboot: reboot to finish the upgrade$" <<<"$out")" 1
check "the refused start never reaches systemctl start" "$([[ -e "$TMP/started" ]] && echo started || echo not-started)" not-started
out=$(timeout 30 bash -c "$(declare -f run_start_sandbox); CLI='$CLI' TMP='$TMP'; run_start_sandbox active 4242 no-lsm")
check "a start before the install's own LSM reboot refuses, naming the reboot that finishes the install" \
      "$(grep -c "^RHIZO_FAIL setup is pending a reboot: reboot to finish the install$" <<<"$out")" 1
check "that refused start never reaches systemctl start either" "$([[ -e "$TMP/started" ]] && echo started || echo not-started)" not-started
out=$(timeout 30 bash -c "$(declare -f run_start_sandbox); CLI='$CLI' TMP='$TMP'; run_start_sandbox active 4242 enforcing 1")
check "a sandbox already running with setup pending a reboot is not refused -- it is not a start" "$out" "STARTED"

# run start_sandbox with stubbed android_sh and date
run_start_sandbox_refused() {
  (
    RHIZO_CLI_SOURCE_ONLY=1; source "$CLI"
    STUB_REFUSALS="$1"
    require_probe_client() { :; }
    sandbox_init_pid() { printf 4242; }
    systemctl() { [[ "$1" == is-active ]] && echo activating; }
    echo 0 > "$TMP/polls"; echo 0 > "$TMP/clock"
    date() { local t; t=$(( $(cat "$TMP/clock") + 60 )); echo "$t" > "$TMP/clock"; echo "$t"; }
    sleep() { :; }
    android_sh() {
      local n; n=$(( $(cat "$TMP/polls") + 1 )); echo "$n" > "$TMP/polls"
      if (( n <= STUB_REFUSALS )); then
        echo "RHIZO_PROBE_UNREACHABLE: [Errno 111] Connection refused" >&2
        return 3
      fi
      echo 1
    }
    start_sandbox && echo "STARTED"
  ) 2>&1
}
out=$(timeout 30 bash -c "$(declare -f run_start_sandbox_refused); CLI='$CLI' TMP='$TMP'; run_start_sandbox_refused 3")
check "a start whose probe refuses three polls prints no refusal line" \
      "$(grep -c RHIZO_PROBE_UNREACHABLE <<<"$out")" 0
check "it names the wait once and its outcome once, then starts" \
      "$(grep -cE '^\[rhizo\] waiting up to 300s for sys.boot_completed=1 from androidd.service over ' <<<"$out"):$(grep -cE '^\[rhizo\] androidd.service reported sys.boot_completed=1 after [0-9]+s$' <<<"$out"):$(tail -1 <<<"$out")" \
      "1:1:STARTED"
out=$(timeout 30 bash -c "$(declare -f run_start_sandbox_refused); CLI='$CLI' TMP='$TMP'; run_start_sandbox_refused 99")
check "a start that never answers fails naming the last refusal, printed once" \
      "$(grep -c RHIZO_PROBE_UNREACHABLE <<<"$out"):$(grep -c "^RHIZO_FAIL init second_stage is running but sys.boot_completed never read 1 within 300s (last read 'RHIZO_PROBE_UNREACHABLE: \[Errno 111\] Connection refused'" <<<"$out")" \
      "1:1"

PU_TMP="$TMP/policy-unit"; mkdir -p "$PU_TMP"; echo 1 > "$PU_TMP/enforce"
# run check_policy_unit with stubbed systemctl
policy_unit_report() {
  (
    STUB_ENABLED=$1 STUB_ACTIVE=$2 STUB_PLINE=$3
    SELINUX_ENFORCE_FILE=${4:-$PU_TMP/enforce}
    systemctl() {
      case "$1" in
        is-enabled) [[ -n "$STUB_ENABLED" ]] && echo "$STUB_ENABLED" ;;
        is-active) echo "$STUB_ACTIVE" ;;
      esac
    }
    policy_status_line() { echo "$STUB_PLINE"; }
    DOCTOR_ISSUES=0 DOCTOR_WARNINGS=0
    check_policy_unit 2>&1
    echo "counts issues=$DOCTOR_ISSUES warnings=$DOCTOR_WARNINGS"
  )
}
out=$(policy_unit_report masked inactive "loaded (source unknown: no state file)")
check "a masked policy unit reads warn, not fail" \
      "$(grep -c "policy-unit: warn -- rhizo-policy.service is masked ('" <<<"$out")" 1
check "a masked policy unit counts no issue" "$(grep -c '^counts issues=0 warnings=1$' <<<"$out")" 1
check "a masked policy unit names the policy's current state" \
      "$(grep -c "('loaded (source unknown: no state file)', enforce=" <<<"$out")" 1
out=$(policy_unit_report masked-runtime inactive "not loaded")
check "a runtime-masked policy unit reads warn" \
      "$(grep -c "policy-unit: warn -- rhizo-policy.service is masked-runtime ('" <<<"$out")" 1
out=$(policy_unit_report enabled inactive "not loaded")
check "an enabled policy unit that never ran reads fail" \
      "$(grep -c "policy-unit: fail -- rhizo-policy.service is 'inactive' and 'enabled', not active" <<<"$out")" 1
check "an enabled policy unit that never ran counts one issue" \
      "$(grep -c '^counts issues=1 ' <<<"$out")" 1
out=$(policy_unit_report disabled inactive "not loaded")
check "a disabled policy unit reads fail and names 'disabled'" \
      "$(grep -c "policy-unit: fail -- rhizo-policy.service is 'inactive' and 'disabled', not active" <<<"$out")" 1
out=$(policy_unit_report enabled failed "not loaded")
check "a failed policy unit reads fail" \
      "$(grep -c 'policy-unit: fail -- rhizo-policy.service failed: no Android policy loaded at boot' <<<"$out")" 1
out=$(policy_unit_report enabled active "loaded (source unknown: no state file)")
check "an active policy unit with no boot-time load reads fail" \
      "$(grep -c 'policy-unit: fail -- rhizo-policy.service is active and loaded no verified policy this boot' <<<"$out")" 1
out=$(policy_unit_report not-found inactive "not loaded")
check "an absent policy unit reads warn" \
      "$(grep -c 'policy-unit: warn -- rhizo-policy.service is not installed' <<<"$out")" 1
out=$(policy_unit_report enabled inactive "not loaded" "$PU_TMP/absent")
check "a boot without selinuxfs reads warn, not the never-ran fail" \
      "$(grep -c 'policy-unit: warn -- SELinux is not the active LSM on this boot' <<<"$out")" 1
check "a boot without selinuxfs counts no issue" "$(grep -c '^counts issues=0 warnings=1$' <<<"$out")" 1
out=$(policy_unit_report enabled active "loaded-at-boot by first-androidd-start, verified by rhizo-policy.service 2026-09-24T08:00:00Z")
check "an active unit that verified an earlier start's load reads ok" \
      "$(grep -c 'policy-unit: ok -- rhizo-policy.service is active: loaded-at-boot by first-androidd-start' <<<"$out")" 1

# run policy_status_line against a state file and a pid 1 context
policy_line_for() {
  (
    mkdir -p "$PU_TMP/proc/1/attr"
    printf '%s\0' "${2:-u:r:rhizo_host:s0}" > "$PU_TMP/proc/1/attr/current"
    PROC_ROOT="$PU_TMP/proc"
    printf '%s\n' "$1" > "$PU_TMP/state"
    eval "$(declare -f policy_status_line | sed -e "s#/run/rhizo-policy-loaded#$PU_TMP/state#g")"
    policy_status_line
  )
}
check "policy_status_line asks rhizo_policy_loaded, not a copy of its test" \
      "$(declare -f policy_status_line | grep -c 'rhizo_policy_loaded'):$(declare -f policy_status_line | grep -c 'attr/current')" "1:0"
check "a pid 1 still in the bare kernel sid reads as not loaded" "$(policy_line_for 'loaded_at=T1' kernel)" "not loaded"
check "a load this unit made names it and the sha" \
      "$(policy_line_for $'loaded_at=T1\nloaded_by=rhizo-policy.service\nsha256=0123456789abcdef')" \
      "loaded-at-boot by rhizo-policy.service T1 sha=0123456789ab"
check "a state file from before loaded_by existed still reads as the unit's own load" \
      "$(policy_line_for $'loaded_at=T1\nsha256=0123456789abcdef')" \
      "loaded-at-boot by rhizo-policy.service T1 sha=0123456789ab"
check "an earlier start's load is named as that, verified by the unit" \
      "$(policy_line_for $'loaded_at=T2\nloaded_by=first-androidd-start\nsha256=')" \
      "loaded-at-boot by first-androidd-start, verified by rhizo-policy.service T2"
check "the server profile never masks rhizo-policy.service" \
      "$(printf '%s\n' "${SERVER_MASKED_UNITS[@]}" | grep -cx 'rhizo-policy.service')" 0

# run check_desktop_daemons with stubbed commands
pipewire_probe_report() {
  (
    STUB_ME=$1
    systemctl() { case "$1" in is-enabled) echo masked ;; is-active) echo inactive ;; esac; }
    read_capability() { echo desktop; }
    id() { case "$1" in -u) [[ -n "${2:-}" ]] && echo 1000 || echo "$STUB_ME" ;; esac; }
    runuser() { echo "ran: runuser $*"; return 0; }
    test() { echo "ran: test $*"; return 1; }
    unix_socket_listening() { echo "ran: unix_socket_listening $*"; return 0; }
    PETC="$TMP/pw-etc"; mkdir -p "$PETC"; echo deskuser > "$PETC/desktop-user"
    ETC_RHIZO="$PETC" DOCTOR_ISSUES=0 DOCTOR_WARNINGS=0
    check_desktop_daemons 2>&1
  )
}
for me in 0 1000 1001; do
  out=$(pipewire_probe_report "$me")
  check "uid $me asks /proc/net/unix for the owner's PipeWire socket and never stats the 0700 dir" \
        "$(grep -c '^ran: unix_socket_listening /run/user/1000/pipewire-0$' <<<"$out")/$(grep -cE '^ran: (runuser|test)' <<<"$out")" 1/0
  check "uid $me reads a listening PipeWire socket as present" \
        "$(grep -c 'pipewire-socket: ok -- /run/user/1000/pipewire-0 present' <<<"$out")" 1
done

LH="$TMP/libs"; mkdir -p "$LH/install/"{bootstrap,prepare,update,teardown,lib,cli} "$LH/elsewhere"
printf 'host_flavor() { echo from-payload; }\n' > "$LH/install/lib/host-flavor.sh"
check "the payload's flavor library is the one sourced" \
      "$( ( INSTALL_DIR="$LH/install"; load_host_libs; host_flavor ) 2>&1)" from-payload
check "with no library in the payload or beside the CLI, loading fails naming both places" \
      "$( ( INSTALL_DIR="$LH/elsewhere"; SELF="$LH/elsewhere/rhizo"; load_host_libs; echo loaded ) 2>&1 | tail -1)" \
      "[rhizo] FAIL: cannot read lib/host-flavor.sh in $LH/elsewhere or beside $LH/elsewhere/rhizo"

DR="$TMP/doctor"; mkdir -p "$DR/boot" "$DR/mods" "$DR/tools" "$DR/bin" "$DR/none"
printf 'NAME="CachyOS Linux"\nID=cachyos\nID_LIKE=arch\nBUILD_ID=rolling\n' > "$DR/os-release-cachyos"
printf 'NAME="Arch Linux"\nID=arch\nBUILD_ID=rolling\n' > "$DR/os-release-arch"
for t in sed tr head cat grep gzip zcat cut; do ln -s "$(type -P "$t")" "$DR/tools/$t"; done
# write the arguments as a gzipped kernel config
dr_config() { printf '%s\n' "$@" | gzip > "$DR/config.gz"; }
# write an executable stub tool with a given body
dr_tool() { printf '#!/bin/sh\n%s\n' "${2:-exit 0}" > "$DR/bin/$1"; chmod +x "$DR/bin/$1"; }
# run a doctor check on a fixture host
doctor_report() {
  (
    RHIZO_OS_RELEASE="$1" RHIZO_BOOT_DIR="$DR/boot" RHIZO_PROC_CONFIG="$DR/config.gz"
    KERNEL_MODULES_ROOT="$DR/mods" TOOLS_DIR="$DR/none"
    PROC_SWAPS="$DR/swaps" RHIZO_LSM_FILE="$DR/lsm" SELINUX_ENFORCE_FILE="$DR/enforce"
    GPU_RESOLVER="$HERE/../prepare/detect-gpu-driver.sh" ETC_RHIZO="$DR/etc" LIB_DIR="$HERE/../../androidd"
    export RHIZO_POLICY_CONF="$DR/etc/policy.conf"
    export RHIZO_SYS_CLASS_DRM="$DR/sys" RHIZO_DEV_DRI="$DR/dev"
    PATH="$DR/bin:${DR_PATH:-$PATH}"
    uname() { case "$1" in -r) echo 7.2.9-1-cachyos ;; -m) echo "${DR_ARCH:-x86_64}" ;; esac; }
    DOCTOR_ISSUES=0 DOCTOR_WARNINGS=0
    "$2" 2>&1
    echo "counts issues=$DOCTOR_ISSUES warnings=$DOCTOR_WARNINGS"
  )
}

out=$(doctor_report "$DR/os-release-cachyos" check_platform)
check "doctor reads a cachyos x86_64 host as supported" "$(grep -c 'platform: ok -- CachyOS x86_64$' <<<"$out")" 1
out=$(doctor_report "$DR/os-release-arch" check_platform)
DR_BOTH="Rhizo targets Ubuntu 24.04 on x86_64 or aarch64 and CachyOS on x86_64"
check "doctor fails an arch host naming both supported hosts" \
      "$(grep -cF "platform: fail -- arch unknown x86_64 is unsupported; $DR_BOTH" <<<"$out")" 1
out=$(doctor_report "$TMP/os-release-ubuntu" check_platform)
check "doctor reads ubuntu 24.04 x86_64 as supported, as before" \
      "$(grep -cx '\[rhizo\]   platform: ok -- Ubuntu 24.04 x86_64' <<<"$out")" 1
out=$(DR_ARCH=riscv64 doctor_report "$TMP/os-release-ubuntu" check_platform)
DR_UBUNTU_ONLY="Rhizo targets Ubuntu 24.04 on x86_64 or aarch64"
check "doctor fails ubuntu 24.04 on another arch in ubuntu's own words, as before" \
      "$(grep -cxF "[rhizo]   platform: fail -- ubuntu 24.04 riscv64 is unsupported; $DR_UBUNTU_ONLY" <<<"$out")" 1

dr_config CONFIG_SECURITY_SELINUX=y CONFIG_CC_IS_CLANG=y
out=$(doctor_report "$DR/os-release-cachyos" check_selinux_kconfig)
check "doctor reads selinux from a cachyos kernel's config.gz alone" \
      "$(grep -cF "selinux-kconfig: ok -- CONFIG_SECURITY_SELINUX=y in $DR/config.gz" <<<"$out")" 1
dr_config CONFIG_SECURITY_APPARMOR=y
out=$(doctor_report "$DR/os-release-cachyos" check_selinux_kconfig)
check "doctor fails a config.gz without selinux" \
      "$(grep -cF "selinux-kconfig: fail -- $DR/config.gz does not set CONFIG_SECURITY_SELINUX=y" <<<"$out")" 1
echo 'not gzip' > "$DR/config.gz"
out=$(doctor_report "$DR/os-release-cachyos" check_selinux_kconfig)
check "doctor fails a config.gz it cannot read as unread, not as lacking selinux, in one line" \
      "$(grep -c "selinux-kconfig: fail -- cannot read $DR/config.gz (.*)$" \
         <<<"$out")/$(wc -l <<<"$out")" "1/2"
rm -f "$DR/config.gz"
out=$(doctor_report "$DR/os-release-cachyos" check_selinux_kconfig)
check "doctor with no kernel config names both places it looked" \
      "$(grep -cF "selinux-kconfig: fail -- no readable $DR/config.gz or $DR/boot/config-7.2.9-1-cachyos" <<<"$out")" 1

dr_config CONFIG_SECURITY_SELINUX=y CONFIG_CC_IS_CLANG=y
out=$(doctor_report "$DR/os-release-cachyos" check_kernel_modules_tree)
check "doctor warns when a kernel upgrade has removed the running kernel's module tree" \
      "$(grep -cF "kernel-modules-tree: warn -- no $DR/mods/7.2.9-1-cachyos: reboot into the installed kernel" \
         <<<"$out")" 1
mkdir -p "$DR/mods/7.2.9-1-cachyos"; echo linux-cachyos > "$DR/mods/7.2.9-1-cachyos/pkgbase"
out=$(doctor_report "$DR/os-release-cachyos" check_kernel_modules_tree)
check "doctor reads the running kernel's module tree" \
      "$(grep -cF "kernel-modules-tree: ok -- $DR/mods/7.2.9-1-cachyos" <<<"$out")" 1

printf 'Filename\tType\tSize\tUsed\tPriority\n' > "$DR/swaps"
out=$(doctor_report "$DR/os-release-cachyos" check_swap)
check "doctor warns on a host with no swap" "$(grep -c 'swap: warn -- no swap device' <<<"$out")" 1
printf 'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0 partition 8038396 0 100\n' > "$DR/swaps"
out=$(doctor_report "$DR/os-release-cachyos" check_swap)
check "doctor names a zram swap device" "$(grep -c 'swap: ok -- /dev/zram0$' <<<"$out")" 1
rm -f "$DR/swaps"
out=$(doctor_report "$DR/os-release-cachyos" check_swap)
check "doctor reads an unreadable swap table as unread, not as no swap" \
      "$(grep -cF "swap: warn -- cannot read $DR/swaps" <<<"$out")" 1

DR_WHY="devices.dri is on and needs a render node: install a GPU driver, or run 'sudo rhizo gpu off'"
mkdir -p "$DR/sys" "$DR/dev" "$DR/etc"
out=$(doctor_report "$DR/os-release-cachyos" check_render_node)
check "doctor fails a host with no render node, in the gpu resolver's words" \
      "$(grep -cxF "[rhizo]   render-node: fail -- no render node under $DR/sys; $DR_WHY" <<<"$out")/$(tail -1 <<<"$out")" \
      "1/counts issues=1 warnings=0"
for row in "renderD128 2147483648 card0" "renderD129 17095983104 card1"; do
  read -r name vram card <<<"$row"
  mkdir -p "$DR/sys/$name/device/drm/$card"
  echo DRIVER=amdgpu > "$DR/sys/$name/device/uevent"
  echo "$vram" > "$DR/sys/$name/device/mem_info_vram_total"
done
out=$(doctor_report "$DR/os-release-cachyos" check_render_node)
check "doctor fails a chosen render node with no device file, by name" \
      "$(grep -cxF "[rhizo]   render-node: fail -- no $DR/dev/renderD129; $DR_WHY" <<<"$out")" 1
: > "$DR/dev/renderD129"
out=$(doctor_report "$DR/os-release-cachyos" check_render_node)
check "doctor fails a regular file where the chosen render node belongs" \
      "$(grep -cxF "[rhizo]   render-node: fail -- no $DR/dev/renderD129; $DR_WHY" <<<"$out")" 1
rm "$DR/dev/renderD129"; ln -s /dev/null "$DR/dev/renderD129"
out=$(doctor_report "$TMP/os-release-ubuntu" check_render_node)
check "doctor names the render node with the most video memory, and its variant" \
      "$(grep -cxF "[rhizo]   render-node: ok -- $DR/dev/renderD129 (amd)" <<<"$out")/$(tail -1 <<<"$out")" \
      "1/counts issues=0 warnings=0"
ln -s /dev/null "$DR/dev/renderD128"
printf 'RHIZO_RENDER_NODE=%s\n' "$DR/dev/renderD128" > "$DR/etc/androidd.env"
out=$(doctor_report "$TMP/os-release-ubuntu" check_render_node)
check "doctor follows androidd.env's RHIZO_RENDER_NODE" \
      "$(grep -cxF "[rhizo]   render-node: ok -- $DR/dev/renderD128 (amd)" <<<"$out")" 1
rm -f "$DR/etc/androidd.env"
check "doctor asks the gpu resolver the launcher asks, with androidd.env" \
      "$(grep -c '"$GPU_RESOLVER" --node --env-file "$ETC_RHIZO/androidd.env"' "$HERE/../cli/rhizo.sh")" 2
check "doctor runs the render-node check" "$(grep -cx '  check_render_node' "$HERE/../cli/rhizo.sh")" 1
rm -f "$DR/dev/renderD128" "$DR/dev/renderD129"
printf '[devices]\ndri = off\n' > "$DR/etc/policy.conf"
out=$(doctor_report "$TMP/os-release-ubuntu" check_render_node)
check "doctor skips the render node with dri off, as neither an issue nor a warning" \
      "$(grep -cxF "[rhizo]   render-node: skip -- devices.dri is off: Android renders in software" <<<"$out")/$(tail -1 <<<"$out")" \
      "1/counts issues=0 warnings=0"
printf '[devices]\ndri = maybe\n' > "$DR/etc/policy.conf"
out=$(doctor_report "$TMP/os-release-ubuntu" check_render_node)
check "doctor fails the render node on a policy.conf that does not parse, naming host-policy-error, never skipping it as software" \
      "$(grep -c "render-node: fail -- cannot read devices.dri: .*dri='maybe', expected yes or no; every start is refused (gpu_driver_refused=host-policy-error)" <<<"$out")/$(grep -c 'render-node: skip' <<<"$out")" \
      "1/0"
printf '[devices]\ndri = off\n[stream]\nenabled = yes\n' > "$DR/etc/policy.conf"
out=$(doctor_report "$TMP/os-release-ubuntu" check_stream_gpu)
check "doctor warns that dri off withholds the stream export stream.enabled asks for" \
      "$(grep -c 'stream: warn -- stream.enabled is on and devices.dri is off: each start withholds the stream (stream_refused=devices-dri-off)' <<<"$out")/$(tail -1 <<<"$out")" \
      "1/counts issues=0 warnings=1"
printf '[devices]\ndri = on\n[stream]\nenabled = yes\n' > "$DR/etc/policy.conf"
out=$(doctor_report "$TMP/os-release-ubuntu" check_stream_gpu)
check "doctor says nothing of the stream with dri on" "$(tail -1 <<<"$out")/$(grep -c 'stream:' <<<"$out")" "counts issues=0 warnings=0/0"
printf '[devices]\ndri = off\n' > "$DR/etc/policy.conf"
out=$(doctor_report "$TMP/os-release-ubuntu" check_stream_gpu)
check "doctor says nothing of the stream with dri off and the stream off" "$(tail -1 <<<"$out")/$(grep -c 'stream:' <<<"$out")" "counts issues=0 warnings=0/0"
check "doctor runs the stream check" "$(grep -cx '  check_stream_gpu' "$HERE/../cli/rhizo.sh")" 1
rm -f "$DR/etc/policy.conf"

echo capability,landlock,lockdown,yama,selinux,bpf > "$DR/lsm"; echo 0 > "$DR/enforce"
out=$(doctor_report "$DR/os-release-cachyos" check_selinuxfs)
check "doctor reads selinuxfs mounted under an active selinux" \
      "$(grep -c 'selinuxfs: ok -- mounted at /sys/fs/selinux$' <<<"$out")" 1
rm -f "$DR/enforce"
out=$(doctor_report "$DR/os-release-cachyos" check_selinuxfs)
DR_NO_FS="selinux is an active LSM and /sys/fs/selinux is not mounted: see systemctl status rhizo-selinuxfs.service"
check "doctor fails an active selinux with no selinuxfs, naming the unit that mounts it" \
      "$(grep -cF "selinuxfs: fail -- $DR_NO_FS" <<<"$out")/$(tail -1 <<<"$out")" "1/counts issues=1 warnings=0"
echo capability,landlock,lockdown,yama,bpf > "$DR/lsm"
check "doctor prints no selinuxfs line while selinux is not active" \
      "$(doctor_report "$DR/os-release-cachyos" check_selinuxfs)" "counts issues=0 warnings=0"
echo capability,landlock,lockdown,yama,bpf,selinux > "$DR/lsm"
out=$(doctor_report "$DR/os-release-cachyos" check_selinux_active)
DR_BPF="bpf precedes selinux in the active LSM list (capability,landlock,lockdown,yama,bpf,selinux): run 'rhizo install' and reboot"
check "doctor fails a cachyos host running selinux behind bpf, naming the order" \
      "$(grep -cF "selinux-active: fail -- $DR_BPF" <<<"$out")/$(tail -1 <<<"$out")" "1/counts issues=1 warnings=0"
echo capability,landlock,lockdown,yama,selinux,bpf > "$DR/lsm"
out=$(doctor_report "$DR/os-release-cachyos" check_selinux_active)
check "doctor passes a cachyos host running selinux ahead of bpf" \
      "$(grep -cF "selinux-active: ok -- selinux is the active LSM (lsm=capability,landlock,lockdown,yama,selinux,bpf," \
         <<<"$out")/$(tail -1 <<<"$out")" "1/counts issues=0 warnings=0"

dr_tool pacman '[ "$1" = -Dk ] || exit 9
echo "No database errors have been found!"'
out=$(doctor_report "$DR/os-release-cachyos" check_apt_health)
check "doctor reads a consistent pacman database as pkg-health ok" \
      "$(grep -c 'pkg-health: ok -- pacman -Dk reports a consistent package database$' <<<"$out")" 1
check "... and asks nothing of dpkg or apt on cachyos" "$(grep -c apt- <<<"$out")" 0
dr_tool pacman '[ "$1" = -Dk ] || exit 9
echo "error: missing dependency libfoo for rhizo"; exit 1'
out=$(doctor_report "$DR/os-release-cachyos" check_apt_health)
check "doctor fails pkg-health with what pacman -Dk found" \
      "$(grep -c 'pkg-health: fail -- pacman -Dk: error: missing dependency libfoo for rhizo' <<<"$out")" 1
rm -f "$DR/bin/pacman"

mkdir -p "$DR/kernel-tools"
# write the kernel-check.sh stub with a given body
dr_kernel_tool() { printf '#!/bin/sh\n%s\n' "$1" > "$DR/kernel-tools/kernel-check.sh"; chmod +x "$DR/kernel-tools/kernel-check.sh"; }
# run check_kernel with the stub kernel-check.sh
dr_kernel() { TOOLS_DIR="$DR/kernel-tools" check_kernel; }
dr_kernel_tool 'exit 0'
out=$(doctor_report "$DR/os-release-cachyos" dr_kernel)
check "doctor reads the Rhizo kernel through kernel-check.sh" \
      "$(grep -cxF "[rhizo]   kernel: ok -- 7.2.9-1-cachyos has built-in binder, /dev/ashmem and /proc/config.gz" <<<"$out")" 1
DR_STOCK="[rhizo-kernel-check] 7.2.9-1-cachyos has no built-in binder: boot the Rhizo kernel"
dr_kernel_tool "echo '$DR_STOCK' >&2; exit 1"
out=$(doctor_report "$DR/os-release-cachyos" dr_kernel)
check "doctor warns with kernel-check.sh's own reason on a stock kernel" \
      "$(grep -cxF "[rhizo]   kernel: warn -- $DR_STOCK" <<<"$out")" 1

out=$( (
  for f in $(declare -F | awk '$3 ~ /^check_/ {print $3}'); do eval "$f() { echo $f; }"; done
  read_capability() { echo desktop; }
  INSTALL_DIR="$(cd "$HERE/.." && pwd)"
  cmd_doctor 2>&1
) )
check "doctor asks the bootloader, selinuxfs and swap right after the active LSM" \
      "$(grep -A3 -x check_selinux_active <<<"$out" | tr '\n' ' ')" \
      "check_selinux_active check_bootloader check_selinuxfs check_swap "

BLD="$TMP/bl-doctor"; mkdir -p "$BLD"
BLD_TOK="security=selinux enforcing=0 loop.max_loop=64 androidboot.hardware=rhizo"
BLD_OWN="androidboot.hardware=rhizo enforcing=0 loop.max_loop=64 security=selinux"
BLD_SUDO=": run 'sudo rhizo doctor' to check the bootloader config"
# write the limine bootloader tokens
bl_written() { bootloader_write limine "$BLD_TOK"; }
# apply the limine bootloader tokens
bl_applied() { bootloader_apply limine "$BLD_TOK" >/dev/null; }
# remove the limine-update tool
bl_no_loader() { rm -f "$RHIZO_BL_ROOT/bin/limine-update"; }
# remove limine-update and the limine default config
bl_nothing() { rm -f "$RHIZO_BL_ROOT/bin/limine-update" "$RHIZO_BL_ROOT/etc/default/limine"; }
# write the limine tokens and remove limine.conf
bl_no_conf() { bl_written; rm -f "$RHIZO_BL_ROOT/boot/limine.conf"; RHIZO_BOOTLOADER=limine; }
# write the limine tokens and remove limine.conf and ESP_PATH
bl_no_conf_no_esp() { bl_no_conf; sed -i '/^ESP_PATH=/d' "$RHIZO_BL_ROOT/etc/default/limine"; }
# install an awk wrapper that fails on Snapshots arguments
bl_awk_fails() {
  bl_written
  printf '#!/bin/sh\ncase "$*" in *Snapshots*) echo "awk: cannot read" >&2; exit 2 ;; esac\nexec %s "$@"\n' \
    "$(type -P awk)" > "$RHIZO_BL_ROOT/bin/awk"
  chmod +x "$RHIZO_BL_ROOT/bin/awk"
}
# write a limine config with max_loop=8
bl_max_loop_unknown() {
  limine_default "$1" "$LIMINE_ESP" "KERNEL_CMDLINE[default]=\"$LIMINE_CMDLINE max_loop=8\"" "$LIMINE_ORDER"
  bl_applied
}
# apply the tokens and make /boot unsearchable
bl_boot_unsearchable() { bl_applied; chmod 000 "$RHIZO_BL_ROOT/boot"; }
# make grub.cfg unreadable
bl_grub_unreadable() {
  bootloader_apply grub-dropin "$BLD_TOK" >/dev/null
  chmod 000 "$RHIZO_BL_ROOT/boot/grub/grub.cfg"
}
# run check_bootloader on a fixture host
bootloader_report() {
  local root="$BLD/$1"
  mkdir -p "$root/bin" "$root/etc/default" "$root/boot"
  (
    . "$HERE/fixtures/bootloader-fixtures.sh"
    export RHIZO_BL_ROOT="$root"
    RHIZO_OS_RELEASE="$DR/os-release-cachyos" INSTALL_DIR="$HERE/.." PATH="$root/bin:$PATH"
    [[ "${BLD_HOST:-}" != ubuntu ]] || RHIZO_OS_RELEASE="$TMP/os-release-ubuntu"
    load_host_libs
    if [[ "${BLD_HOST:-}" == ubuntu ]]; then add_grub_dropin "$root"; else add_limine "$root"; fi
    if [[ -n "${2:-}" ]]; then "$2" "$root"; fi
    hash -r
    DOCTOR_ISSUES=0 DOCTOR_WARNINGS=0
    check_bootloader 2>&1
    echo "counts issues=$DOCTOR_ISSUES warnings=$DOCTOR_WARNINGS"
  )
  chmod -R u+rwX "$root"
}
out=$(bootloader_report before)
check "doctor warns on a host whose bootloader config holds none of rhizo's tokens" \
      "$(grep -cxF "[rhizo]   bootloader: warn -- rhizo's cmdline tokens are not configured: run 'rhizo install'" \
         <<<"$out")" 1
out=$(bootloader_report written bl_written)
check "doctor warns on tokens written but not yet regenerated into the next boot, listing them" \
      "$(grep -cF "warn -- limine: $BLD/written/boot/limine.conf lacks: $BLD_OWN; run 'rhizo install'" <<<"$out")" 1
out=$(bootloader_report after bl_applied)
check "doctor reads a limine host whose next boot carries every token as ok" \
      "$(grep -cF "bootloader: ok -- limine: $BLD/after/boot/limine.conf carries every token" <<<"$out")" 1
out=$(bootloader_report no-loader bl_no_loader)
check "doctor fails a host whose limine-update is gone, naming it" \
      "$(grep -c "bootloader: fail -- $BLD/no-loader/etc/default/limine is there, but no limine-update is in any of"\
 <<<"$out")" 1
out=$(bootloader_report nothing bl_nothing)
check "doctor fails a host with no bootloader it can find, saying where it looked" \
      "$(grep -c 'bootloader: fail -- no supported bootloader configuration found' <<<"$out")" 1
out=$(bootloader_report no-conf bl_no_conf)
check "doctor names the limine.conf a named bootloader's ESP_PATH lacks" \
      "$(grep -c "bootloader: warn -- limine-entry-tool's ESP_PATH is /boot, but there is no $BLD/no-conf/boot/limine.conf" \
         <<<"$out")" 1
out=$(bootloader_report no-conf-no-esp bl_no_conf_no_esp)
check "doctor fails a named bootloader whose generated config is missing" \
      "$(grep -c 'bootloader: fail -- no limine.conf found' <<<"$out")" 1
out=$(bootloader_report unreadable bl_awk_fails)
check "doctor fails a generated config it cannot read, not reading it as lacking tokens" \
      "$(grep -cF "bootloader: fail -- awk: cannot read; cannot read the cmdlines in $BLD/unreadable/boot/limine.conf" \
         <<<"$out")/$(grep -c 'bootloader: warn' <<<"$out")" "1/0"
out=$(bootloader_report max-loop bl_max_loop_unknown)
check "doctor fails a host max_loop= it cannot judge, naming the kernel and the list it cannot read" \
      "$(grep -cxF "[rhizo]   bootloader: fail -- cannot tell whether loop is built into $(uname -r):\
 $BLD/max-loop/lib/modules/$(uname -r)/modules.builtin cannot be read" <<<"$out")" 1
out=$(bootloader_report boot-unsearchable bl_boot_unsearchable)
check_unprivileged "doctor as a user who cannot search /boot asks for root, never calling the bootloader absent" \
      "$(grep -cxF "[rhizo]   bootloader: warn -- cannot read $BLD/boot-unsearchable/boot as uid $EUID$BLD_SUDO" \
         <<<"$out")" 1
out=$(BLD_HOST=ubuntu bootloader_report grub-unreadable bl_grub_unreadable)
BLD_GRUB_CFG="$BLD/grub-unreadable/boot/grub/grub.cfg"
check_unprivileged "doctor as a user who cannot read ubuntu's grub.cfg asks for root, never calling tokens lacking" \
      "$(grep -cxF "[rhizo]   bootloader: warn -- cannot read $BLD_GRUB_CFG as uid $EUID$BLD_SUDO" <<<"$out")" 1
# apply the grub-dropin tokens and add boot/efi
bl_grub_applied() { bootloader_apply grub-dropin "$BLD_TOK" >/dev/null; mkdir -p "$RHIZO_BL_ROOT/boot/efi"; }
# apply the grub tokens and make the efi directory unreadable
bl_grub_efi_shut() { bl_grub_applied; chmod 000 "$RHIZO_BL_ROOT/boot/efi"; }
out=$(BLD_HOST=ubuntu bootloader_report efi-open bl_grub_applied)
efi_open=${out//"$BLD/efi-open"/@ROOT@}
out=$(BLD_HOST=ubuntu bootloader_report efi-shut bl_grub_efi_shut)
check_unprivileged "doctor on ubuntu with an ESP this uid cannot search says what it says with a searchable one" \
      "${out//"$BLD/efi-shut"/@ROOT@}" "$efi_open"
check "... which is that grub.cfg carries every token" "$(head -1 <<<"$efi_open")" \
      "[rhizo]   bootloader: ok -- grub-dropin: @ROOT@/boot/grub/grub.cfg carries every token"
# add lsm=landlock,bpf to the limine defaults file
bl_limine_host_lsm() {
  bl_applied
  sed -i 's/^\(KERNEL_CMDLINE\[default\]=".*\)"$/\1 lsm=landlock,bpf"/' "$1/etc/default/limine"
  run_stub "$1/bin/limine-update"
}
out=$(bootloader_report host-lsm bl_limine_host_lsm)
check "doctor warns on a limine host whose own lsm= voids rhizo's security=, naming where it is set" \
      "$(head -1 <<<"$out")" "[rhizo]   bootloader: warn -- limine: $BLD/host-lsm/boot/limine.conf carries every token,\
 but the host's own lsm=landlock,bpf, set by KERNEL_CMDLINE[default] in $BLD/host-lsm/etc/default/limine, voids\
 rhizo's security=selinux, as the kernel ignores security= beside any lsm=, and leaves selinux out of the LSM list --\
 remove that lsm= from the host's own line, or add selinux to it"
# move update-grub into usr/sbin
bl_grub_sbin_only() {
  bootloader_apply grub-dropin "$BLD_TOK" >/dev/null
  mkdir -p "$1/usr/sbin"; mv "$1/bin/update-grub" "$1/bin/grub-gen" "$1/usr/sbin/"
}
# apply the grub-dropin and move update-grub into a user directory on PATH
bl_grub_user_path() {
  bootloader_apply grub-dropin "$BLD_TOK" >/dev/null
  mkdir -p "$1/home/user/bin"; mv "$1/bin/update-grub" "$1/home/user/bin/"
  PATH="$1/home/user/bin:$PATH"
}
out=$(BLD_HOST=ubuntu bootloader_report sbin-only bl_grub_sbin_only)
check "doctor finds update-grub under /usr/sbin with no PATH entry naming it" "$(head -1 <<<"$out")" \
      "[rhizo]   bootloader: ok -- grub-dropin: $BLD/sbin-only/boot/grub/grub.cfg carries every token"
out=$(BLD_HOST=ubuntu bootloader_report user-path bl_grub_user_path)
check "doctor does not take an update-grub only on a user's PATH" "$(head -1 <<<"$out")" \
      "[rhizo]   bootloader: fail -- no update-grub in any of $BLD/user-path/usr/bin, $BLD/user-path/usr/sbin,\
 $BLD/user-path/bin, $BLD/user-path/sbin, $BLD/user-path/usr/local/sbin, $BLD/user-path/usr/local/bin --\
 grub2-common is not installed"
# link /etc/default/limine into a private directory
bl_limine_private() {
  bl_applied
  mkdir "$1/private"
  mv "$1/etc/default/limine" "$1/private/limine"; ln -s "$1/private/limine" "$1/etc/default/limine"
  chmod 000 "$1/private"
}
out=$(bootloader_report limine-private bl_limine_private)
check_unprivileged "doctor on a /etc/default/limine linked out of this uid's reach asks for root" \
      "$(head -1 <<<"$out")" \
      "[rhizo]   bootloader: warn -- cannot read $BLD/limine-private/private as uid $EUID$BLD_SUDO"
chmod 000 "$BLD/limine-private/private"
# shellcheck disable=SC2016
out=$(RHIZO_BL_ROOT="$BLD/limine-private" RHIZO_OS_RELEASE="$DR/os-release-cachyos" \
      PATH="$BLD/limine-private/bin:$PATH" unshare -r bash -c 'RHIZO_CLI_SOURCE_ONLY=1 source "$1"
  INSTALL_DIR="$2" load_host_libs; DOCTOR_ISSUES=0 DOCTOR_WARNINGS=0; check_bootloader 2>&1' x "$CLI" "$HERE/.." 2>&1)
chmod 755 "$BLD/limine-private/private"
check "doctor as root on the same link reads the config through it" "$out" \
      "[rhizo]   bootloader: ok -- limine: $BLD/limine-private/boot/limine.conf carries every token"
# make /etc/default unsearchable
bl_grub_etc_shut() { bootloader_apply grub-dropin "$BLD_TOK" >/dev/null; chmod 000 "$1/etc/default"; }
out=$(BLD_HOST=ubuntu bootloader_report etc-shut bl_grub_etc_shut)
check_unprivileged "doctor on ubuntu with an /etc/default this uid cannot search asks for root" "$(head -1 <<<"$out")" \
      "[rhizo]   bootloader: warn -- cannot read $BLD/etc-shut/etc/default as uid $EUID$BLD_SUDO"
out=$(unshare -r bash -c 'RHIZO_CLI_SOURCE_ONLY=1 source "$1"; INSTALL_DIR="$2" load_host_libs
  bootloader_kind() { echo "cannot read /fixture/boot as uid $EUID" >&2; return 2; }
  DOCTOR_ISSUES=0 DOCTOR_WARNINGS=0; check_bootloader 2>&1' x "$CLI" "$HERE/.." 2>&1)
check "doctor as root fails a path the library cannot read, rather than asking for root" \
      "$out" "[rhizo]   bootloader: fail -- cannot read /fixture/boot as uid 0"

UN_TMP="$TMP/uninstall"; mkdir -p "$UN_TMP/lib/install/"{bootstrap,prepare,update,teardown,lib,cli} "$UN_TMP/bin" "$UN_TMP/state"
export UN_CALLS="$UN_TMP/calls"
printf '#!/bin/sh\necho "teardown $*" >> "$UN_CALLS"\nexit "${UN_TEARDOWN_RC:-0}"\n' \
  > "$UN_TMP/lib/install/teardown/teardown.sh"
printf '#!/bin/sh\necho "apt-get $*" >> "$UN_CALLS"\n' > "$UN_TMP/bin/apt-get"
printf '#!/bin/sh\n[ "$UN_STATUS" != "?" ] || exit 2\nprintf %%s "$UN_STATUS"\n[ -n "$UN_STATUS" ]\n' \
  > "$UN_TMP/bin/dpkg-query"
chmod +x "$UN_TMP/lib/install/teardown/teardown.sh" "$UN_TMP/bin/apt-get" "$UN_TMP/bin/dpkg-query"
# run cmd_uninstall with stubbed apt-get and dpkg-query
run_uninstall() {
  export UN_STATUS="$1"; local yes="$2"; shift 2
  : > "$UN_CALLS"
  UN_OUT=$( ( RHIZO_LIB_DIR="$UN_TMP/lib" RHIZO_STATE_DIR="$UN_TMP/state" RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
    PATH="$UN_TMP/bin:$PATH"; export RHIZO_ASSUME_YES="$yes" RHIZO_PACMAN_LOG="${UN_PACMAN_LOG:-$UN_TMP/no-pacman.log}"
    cmd_uninstall "$@" ) 2>&1 </dev/null ); UN_RC=$?
}
# print the recorded calls separated by semicolons
un_calls() { tr '\n' ';' < "$UN_CALLS"; }

run_uninstall installed 1 --purge
check "uninstall --purge on a dpkg install purges rhizo through apt" \
      "$(un_calls)" "apt-get -y purge rhizo;"
run_uninstall installed 1
check "uninstall on a dpkg install removes rhizo through apt" \
      "$(un_calls)" "apt-get -y remove rhizo;"
run_uninstall installed 0
check "uninstall without RHIZO_ASSUME_YES leaves apt's own prompt in place" \
      "$(un_calls)" "apt-get remove rhizo;"
run_uninstall half-configured 1 --purge
check "a half-configured package is still dpkg's to purge" \
      "$(un_calls)" "apt-get -y purge rhizo;"
run_uninstall installed 0 --purge
check "an unconfirmed purge with no terminal runs nothing" "$UN_RC/$(un_calls)" "1/"
run_uninstall installed 1 --verify
check "uninstall --verify only reads, through the teardown" "$(un_calls)" "teardown --verify;"
run_uninstall installed 1 --purge --verify
check "uninstall --purge --verify only reads, through the teardown" "$(un_calls)" "teardown --verify --purge;"
run_uninstall installed 1 --bogus
check "an unknown option on a dpkg install runs nothing" "$UN_RC/$(un_calls)" "1/"
run_uninstall "" 1 --purge
check "uninstall --purge with no dpkg record runs the teardown itself" "$(un_calls)" "teardown --purge;"
run_uninstall config-files 1
check "uninstall with only rhizo's conffiles left runs the teardown itself" "$(un_calls)" "teardown ;"

printf 'ID=cachyos\n' > "$UN_TMP/os-release-cachyos"
cat > "$UN_TMP/bin/pacman" <<'EOF'
#!/bin/sh
if [ "$1" = -Qq ] && [ $# -eq 2 ]; then
  case " $UN_PACMAN_UNKNOWN " in *" $2 "*) exit "${UN_PACMAN_UNKNOWN_RC:-2}" ;; esac
  case " $UN_PACMAN_HOLDS " in *" $2 "*) exit 0 ;; esac
  exit 1
fi
if [ "$1" = -Qq ]; then
  shift; rc=0
  for p; do case " $UN_PACMAN_DEPS " in *" $p "*) echo "$p" ;; *) echo "error: package '$p' was not found" >&2; rc=1 ;; esac; done
  exit "$rc"
fi
if [ "$1" = -Qi ]; then shift; for p; do cat "$UN_TMP/qi/$p"; echo; done; exit 0; fi
echo "pacman $* purge=${RHIZO_TEARDOWN_PURGE:-}" >> "$UN_CALLS"
EOF
chmod +x "$UN_TMP/bin/pacman"
# run run_uninstall with stubbed pacman
run_uninstall_pacman() {
  export UN_PACMAN_HOLDS="$1" UN_PACMAN_UNKNOWN="$2"; shift 2
  RHIZO_OS_RELEASE="$UN_TMP/os-release-cachyos" run_uninstall installed "$@"
}
run_uninstall_pacman "rhizo" "" 1
check "uninstall on a pacman install removes rhizo through pacman" \
      "$(un_calls)" "pacman -R --noconfirm rhizo purge=;"
run_uninstall_pacman "rhizo" "" 1 --purge
check "uninstall --purge on a pacman install removes rhizo with its files and tells the teardown to purge" \
      "$(un_calls)" "pacman -Rn --noconfirm rhizo purge=1;"
run_uninstall_pacman "rhizo" "" 0
check "uninstall without RHIZO_ASSUME_YES leaves pacman's own prompt in place" \
      "$(un_calls)" "pacman -R rhizo purge=;"
run_uninstall_pacman "" "" 1 --purge
check "uninstall --purge with no pacman record runs the teardown itself" "$(un_calls)" "teardown --purge;"
run_uninstall_pacman "" "rhizo" 1
check "uninstall refuses, running nothing, when pacman cannot say whether it holds rhizo" \
      "$UN_RC/$(un_calls)/$(grep -c 'whether rhizo is installed: nothing removed' <<<"$UN_OUT")" "1//1"
printf 'ID=arch\n' > "$UN_TMP/os-release-arch"
RHIZO_OS_RELEASE="$UN_TMP/os-release-arch" run_uninstall installed 1
check "uninstall refuses, running nothing, on a host where it cannot tell which package manager to ask" \
      "$UN_RC/$(un_calls)/$(grep -c 'both dpkg-query and pacman are installed: nothing removed' <<<"$UN_OUT")" "1//1"
UN_PACMAN_UNKNOWN_RC=126 run_uninstall_pacman "" "rhizo" 1
check "uninstall refuses, running nothing, when pacman answers for rhizo with neither 0 nor 1" \
      "$UN_RC/$(un_calls)/$(grep -c 'whether rhizo is installed: nothing removed' <<<"$UN_OUT")" "1//1"
export RHIZO_TEARDOWN_PURGE=1
run_uninstall_pacman "rhizo" "" 1
unset RHIZO_TEARDOWN_PURGE
check "a RHIZO_TEARDOWN_PURGE the caller set never reaches pacman without --purge" \
      "$(un_calls)" "pacman -R --noconfirm rhizo purge=;"
run_uninstall_pacman "rhizo" "" 0 --purge
check "an unconfirmed purge on a pacman install with no terminal runs nothing" "$UN_RC/$(un_calls)" "1/"
run_uninstall_pacman "rhizo" "" 1 --bogus
check "an unknown option on a pacman install runs nothing" \
      "$UN_RC/$(un_calls)/$(grep -c 'uninstall on a pacman install takes only --purge or --verify, got: --bogus' \
         <<<"$UN_OUT")" "1//1"
export UN_TMP UN_PACMAN_LOG="$UN_TMP/pacman.log"; mkdir -p "$UN_TMP/qi"
printf '%s\n' "[2026-09-01T10:00:00+0000] [ALPM] transaction started" \
  "[2026-09-01T10:00:01+0000] [ALPM] installed orphan (1-1)" "[2026-09-01T10:00:02+0000] [ALPM] transaction completed" \
  "[2026-10-01T10:00:00+0000] [ALPM] transaction started" "[2026-10-01T10:00:01+0000] [ALPM] installed dash (0.5-1)" \
  "[2026-10-01T10:00:01+0000] [ALPM] installed shared (1-1)" "[2026-10-01T10:00:01+0000] [ALPM] installed byhand (1-1)" \
  "[2026-10-01T10:00:01+0000] [ALPM] installed gone (1-1)" "[2026-10-01T10:00:02+0000] [ALPM] installed rhizo (0.1.4-1)" \
  "[2026-10-01T10:00:03+0000] [ALPM] transaction completed" "[2026-10-02T10:00:00+0000] [ALPM] transaction started" \
  "[2026-10-02T10:00:01+0000] [ALPM] upgraded rhizo (0.1.4-1 -> 0.1.5-1)" \
  "[2026-10-02T10:00:01+0000] [ALPM] installed pahole (1-1)" "[2026-10-02T10:00:02+0000] [ALPM] transaction completed" \
  > "$UN_PACMAN_LOG"
qi() { printf 'Name            : %s\nRequired By     : %s\nInstall Reason  : %s\n' "$1" "$2" "$3" > "$UN_TMP/qi/$1"; }
qi dash rhizo "Installed as a dependency for another package"
qi shared "rhizo  userapp" "Installed as a dependency for another package"
qi byhand None "Explicitly installed"
qi pahole rhizo "Installed as a dependency for another package"
export UN_PACMAN_DEPS="dash shared byhand pahole orphan"
run_uninstall_pacman "rhizo" "" 1 --purge
check "uninstall on pacman removes exactly what Rhizo's install and upgrade added, never -s" \
      "$(un_calls)" "pacman -Rn --noconfirm rhizo dash pahole purge=1;"
check "... and names them" "$(grep -cxF '[rhizo]   dash pahole' <<<"$UN_OUT")" 1
chmod 000 "$UN_PACMAN_LOG"
run_uninstall_pacman "rhizo" "" 1
chmod 644 "$UN_PACMAN_LOG"
check_unprivileged "uninstall on pacman with an unreadable log removes only Rhizo's own packages, saying why" \
      "$(un_calls)|$(grep -c "none named: cannot read $UN_PACMAN_LOG as uid $EUID" <<<"$UN_OUT")" \
      "pacman -R --noconfirm rhizo purge=;|1"
unset UN_PACMAN_LOG UN_PACMAN_DEPS
run_uninstall "?" 1
UN_DPKG_ERR="whether rhizo is installed: nothing removed (cannot query packages: dpkg-query exited 2)"
check "on ubuntu a dpkg-query that errors refuses, running nothing, where the base read it as not held" \
      "$UN_RC/$(un_calls)/$(grep -cF "$UN_DPKG_ERR" <<<"$UN_OUT")" "1//1"

IN_TMP="$TMP/install-libs"; mkdir -p "$IN_TMP/install/"{bootstrap,prepare,update,teardown,lib,cli}
printf '#!/bin/sh\nexit 0\n' > "$IN_TMP/install/bootstrap/bootstrap.sh"
chmod +x "$IN_TMP/install/bootstrap/bootstrap.sh"
out=$( (
  unset -f host_flavor
  INSTALL_DIR="$IN_TMP/install"; export RHIZO_CLI_TEST_NO_ROOT=1
  resolve_uid1000() { echo "flavor=$(host_flavor)"; exit 0; }
  cmd_install --profile desktop
) 2>&1)
check "install loads the host libraries before it resolves the uid-1000 account" "$(tail -1 <<<"$out")" flavor=ubuntu

GC_TMP="$TMP/gc-cache"; mkdir -p "$GC_TMP/gsi"
for n in a b c d e; do echo "$n" > "$GC_TMP/precompiled_sepolicy.$n"; done
echo z > "$GC_TMP/gsi/system.zip"
for n in plat system_ext vendor; do echo "$n" > "$GC_TMP/${n}_file_contexts"; done
touch -d '2026-01-01 00:00:01' "$GC_TMP/precompiled_sepolicy.a" "$GC_TMP/gsi"
touch -d '2026-01-01 00:00:02' "$GC_TMP/precompiled_sepolicy.b"
touch -d '2026-01-01 00:00:03' "$GC_TMP/precompiled_sepolicy.c"
touch -d '2026-01-01 00:00:03' "$GC_TMP/precompiled_sepolicy.d" "$GC_TMP/precompiled_sepolicy.e"
touch -d '2026-01-01 00:00:04' "$GC_TMP/precompiled_sepolicy.d"
touch -d '2026-01-01 00:00:05' "$GC_TMP/precompiled_sepolicy.e"
touch -d '2026-01-01 00:00:04' "$GC_TMP/plat_file_contexts" "$GC_TMP/system_ext_file_contexts"
touch -d '2026-01-01 00:00:05' "$GC_TMP/vendor_file_contexts"
gc_out=$( ( RHIZO_VAR_CACHE="$GC_TMP" RHIZO_STATE_DIR="$TMP/state" RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"; gc_cache ) 2>&1 )
check "gc_cache drops only the oldest precompiled_sepolicy, keeping four" \
      "$(cd "$GC_TMP" && ls -d precompiled_sepolicy.* | tr '\n' ' ')" \
      "precompiled_sepolicy.b precompiled_sepolicy.c precompiled_sepolicy.d precompiled_sepolicy.e "
check "gc_cache keeps every file_contexts file and the gsi zip" \
      "$(cd "$GC_TMP" && ls *_file_contexts gsi/system.zip | tr '\n' ' ')" \
      "gsi/system.zip plat_file_contexts system_ext_file_contexts vendor_file_contexts "
check "gc_cache prints no rm error" "$(grep -c 'rm:' <<<"$gc_out")" 0
check "gc_cache logs the one precompiled_sepolicy it removed" "$(grep -c 'removed old cache entry precompiled_sepolicy.a' <<<"$gc_out")" 1
gc_out2=$( ( RHIZO_VAR_CACHE="$GC_TMP" RHIZO_STATE_DIR="$TMP/state" RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"; gc_cache ) 2>&1 )
check "gc_cache removes nothing at the limit" "$(cd "$GC_TMP" && ls -d precompiled_sepolicy.* | wc -l)$(grep -c removed <<<"$gc_out2")" 40
GC_EMPTY="$TMP/gc-cache-empty"; mkdir -p "$GC_EMPTY"
check "gc_cache on an empty cache succeeds quietly" \
      "$( ( RHIZO_VAR_CACHE="$GC_EMPTY" RHIZO_STATE_DIR="$TMP/state" RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"; gc_cache ) 2>&1; echo rc=$?)" "rc=0"

NS="$TMP/selinuxns"; mkdir -p "$NS/run/rhizo" "$NS/run/rhizo-selinuxns" "$NS/run/rhizo-selinuxns-2" "$NS/lib/install/"{bootstrap,prepare,update,teardown,lib,cli} \
  "$NS/etc" "$NS/log" "$NS/state"
export NS_KEPT="$NS/state/host-mode-kept.env"
cat > "$NS/lib/rhizo-selinux-mode" <<'EOF'
#!/bin/sh
[ -n "${NS_CALLS:-}" ] && echo "$*" >> "$NS_CALLS"
case " $* " in
  *" --configured "*) grep -qx RHIZO_SELINUX_MODE=host "$NS_KEPT" 2>/dev/null && echo host || echo "${NS_CONFIGURED:-namespace}" ;;
  *" --landlock-abi "*) echo 7 ;;
  *" --host-state "*) [ "${NS_HOST_STATE:-none}" = fail ] && exit 3; echo "${NS_HOST_STATE:-none}" ;;
  *" --why "*) echo "boot the Rhizo kernel (uname -r ends in -rhizo) to start Android" ;;
  *" --mode-and-why "*) case "${NS_LIVE:-namespace}" in
    refuse:*) printf '%s\t%s\n' "$NS_LIVE" "boot the Rhizo kernel (uname -r ends in -rhizo) to start Android" ;;
    *) echo "${NS_LIVE:-namespace}" ;; esac ;;
  *) echo "${NS_LIVE:-namespace}" ;;
esac
EOF
cat > "$NS/lib/install/prepare/prepare.sh" <<EOF
#!/bin/sh
echo "\$*" >> "$NS/prepare-args"
case " \$* " in
  *" --data-only "*) echo "RHIZO_PREPARE_DATA_ONLY=1 template=def" ;;
  *) echo "RHIZO_PREPARE_OK key=abc tree=/x sepolicy=/y template=def data=kept dexopt=0/0 binder=z" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$NS/lib/install/bootstrap/bootstrap.sh"
printf 'pkg_leave_host_mode() { echo "pkg_leave_host_mode record=$RHIZO_INSTALL_RECORD" >&2; }
pkg_enter_host_mode() { echo "pkg_enter_host_mode record=$RHIZO_INSTALL_RECORD" >&2; return "${NS_ENTER_RC:-0}"; }\n' \
  > "$NS/lib/install/lib/pkg-lib.sh"
printf '#!/bin/sh\necho "teardown $*" >&2\n[ "$1" = --list-host-labels ] || exit 9\nprintf "%%b\\n" "$NS_LABELS"\n' \
  > "$NS/lib/install/teardown/teardown.sh"
printf 'import sys\nsys.exit(0)\n' > "$NS/lib/install/prepare/await-boot-completed.py"
chmod +x "$NS/lib/rhizo-selinux-mode" "$NS/lib/install/"*/*
# run code in a fresh cli on the fixture's dirs
ns_run() {
  (
    unset RHIZO_SELINUX_MODE_HELPER
    if [[ "$1" == none ]]; then rm -f "$NS/mode"; else echo "$1" > "$NS/mode"; fi
    RHIZO_SELINUX_CONFIG="$NS/selinux-config" \
    RHIZO_SELINUX_MODE_FILE="$NS/mode" RHIZO_RUN_MOUNT="$NS/run" RHIZO_LIB_DIR="$NS/lib" RHIZO_ETC_DIR="$NS/etc" \
      RHIZO_SELINUX_ENFORCE="$NS/enforce" RHIZO_STATE_DIR="$NS/state" RHIZO_VAR_LOG="$NS/log" \
      RHIZO_CLI_SOURCE_ONLY=1 source "$CLI"
    eval "$2"
  ) 2>&1
}

check "selinux_mode reads the mode this boot's start recorded" "$(ns_run namespace selinux_mode)" namespace
check "selinux_mode reads a recorded host mode" "$(ns_run host selinux_mode)" host
check "selinux_mode asks the mode helper for the configured mode before any start" \
      "$(NS_CONFIGURED=host ns_run none selinux_mode):$(ns_run none selinux_mode)" "host:namespace"
out=$(ns_run none 'LIB_DIR="$NS/no-lib"; selinux_mode; echo rc=$?')
check "selinux_mode fails by name, never host, when the mode helper cannot run" \
      "$(tail -1 <<<"$out"):$(grep -c 'cannot read the configured SELinux mode' <<<"$out"):$(grep -cx host <<<"$out")" "rc=1:1:0"
check "selinux_mode reads an empty mode file as unrecorded and asks the helper" \
      "$(NS_CONFIGURED=host ns_run '' selinux_mode):$(ns_run '' selinux_mode)" "host:namespace"
out=$(ns_run none 'mkdir -p "$NS/mode-dir"; SELINUX_MODE_FILE="$NS/mode-dir"; selinux_mode; echo rc=$?')
check "selinux_mode fails by name on a mode file it cannot read" \
      "$(tail -1 <<<"$out"):$(grep -c "cannot read $NS/mode-dir" <<<"$out")" "rc=1:1"
out=$(ns_run permissive 'selinux_mode; echo rc=$?')
check "selinux_mode fails by name on a mode file holding neither mode" \
      "$(tail -1 <<<"$out"):$(grep -c "reads 'permissive', not host or namespace" <<<"$out")" "rc=1:1"
out=$(ns_run none 'LIB_DIR="$NS/no-lib"; selinux_mode_is namespace; echo "went on rc=$?"')
check "selinux_mode_is stops the verb by name when the mode cannot be read" \
      "$(grep -c 'went on' <<<"$out"):$(grep -c 'FAIL: cannot read the SELinux mode' <<<"$out")" "0:1"
out=$(ns_run none 'LIB_DIR="$NS/no-lib"; android_enforce_state; echo "rc=$?"; selinuxns_verdict; echo "rc=$?"')
check "android_enforce_state and selinuxns_verdict return 2 when the mode cannot be read" \
      "$(grep -E '^rc=' <<<"$out" | tr '\n' ' ')" "rc=2 rc=2 "
out=$(ns_run none 'LIB_DIR="$NS/no-lib"; check_policy_unit; check_selinuxfs; check_selinux_active; echo "went on"')
check "the doctor's mode checks report a failure by name and go on when the mode cannot be read" \
      "$(grep -cE '(policy-unit|selinuxfs|selinux-active): fail -- cannot read the SELinux mode' <<<"$out"):$(grep -c 'went on' <<<"$out")" "3:1"

out=$(ns_run none 'label_android_file "$NS/f" u:object_r:rhizo_inbox_file:s0; echo rc=$?')
check "label_android_file fails closed, naming the mode file, when it is absent" \
      "$(tail -1 <<<"$out"):$(grep -c "cannot read the SELinux mode from $NS/mode" <<<"$out")" "rc=1:1"
check "label_android_file under a recorded host mode writes nothing and succeeds" \
      "$(ns_run host 'label_android_file "$NS/f" u:object_r:rhizo_inbox_file:s0; echo rc=$?')" "rc=0"

check "instance_records_dir names rhizo-selinuxns for instance 0 and rhizo-selinuxns-<id> above, beside the run roots" \
      "$(ns_run namespace 'instance_records_dir 0; instance_records_dir 03')" "$NS/run/rhizo-selinuxns
$NS/run/rhizo-selinuxns-3"
echo 1 > "$NS/run/rhizo-selinuxns/android-enforce"; echo 0 > "$NS/run/rhizo-selinuxns-2/android-enforce"
echo 0 > "$NS/enforce"
check "android_enforce_state reads instance 0's own state in namespace mode" "$(ns_run namespace android_enforce_state)" 1
check "android_enforce_state reads the named instance's own state" "$(ns_run namespace 'android_enforce_state 2')" 0
check "android_enforce_state reads the host node in host mode" "$(ns_run host android_enforce_state)" 0
rm -f "$NS/run/rhizo-selinuxns/android-enforce"
check "android_enforce_state is empty before a namespace-mode start" "$(ns_run namespace android_enforce_state)" ""

echo refused:relabeller-eof > "$NS/run/rhizo-selinuxns/selinuxns-verdict"
check "selinuxns_verdict reads the instance's verdict in namespace mode" "$(ns_run namespace selinuxns_verdict)" \
      refused:relabeller-eof
check "selinuxns_verdict is empty in host mode" "$(ns_run host selinuxns_verdict)" ""
check "a refused namespace start is named by policy_refusal_note" "$(ns_run namespace policy_refusal_note)" \
      "Android's SELinux namespace start was refused: relabeller-eof. "
check "host mode's policy_refusal_note names no namespace refusal" "$(ns_run host policy_refusal_note)" ""

START_REPLAY='require_probe_client() { :; }; sandbox_init_pid() { [[ -f "$NS/no-init" ]] || printf 4242; }
  rec="$NS/run/rhizo-selinuxns"
  # answer the unit state and this start InvocationID
  systemctl() {
    case "$1" in
      start) : > "$NS/started" ;;
      is-active) cat "$NS/unit-state" ;;
      show) [[ "$*" == *InvocationID* ]] && echo new-start ;;
    esac
  }
  android_sh() { cat "$NS/boot-completed"; }
  # run the launcher step queued for this poll
  sleep() { local n; n=$(( $(cat "$NS/polls") + 1 )); echo "$n" > "$NS/polls"; [[ -f "$NS/step-$n" ]] && bash "$NS/step-$n"; return 0; }
  start_sandbox && echo STARTED'
start_replay() {
  rm -f "$NS"/step-* "$NS/started" "$NS/no-init"; echo 0 > "$NS/polls"; echo activating > "$NS/unit-state"; echo 0 > "$NS/boot-completed"
  echo refused:relabeller-eof > "$NS/run/rhizo-selinuxns/selinuxns-verdict"
  echo old-start > "$NS/run/rhizo-selinuxns/start-id"
  printf 'echo pending > %s; echo new-start > %s\n' "$NS/run/rhizo-selinuxns/selinuxns-verdict" "$NS/run/rhizo-selinuxns/start-id" > "$NS/step-2"
  if [[ "$1" == none ]]; then
    printf 'echo %s > %s; : > %s\n' "$2" "$NS/unit-state" "$NS/no-init" > "$NS/step-2"
  else
    printf 'echo %s > %s; echo 1 > %s\n' "$1" "$NS/run/rhizo-selinuxns/selinuxns-verdict" "$NS/boot-completed" > "$NS/step-3"
  fi
  ns_run namespace "$START_REPLAY" | grep -E "^RHIZO_FAIL|^STARTED|reported sys.boot_completed"
}
out=$(start_replay enforced active)
check "a start after a refused one waits past the earlier start's verdict and starts" \
      "$(grep -c '^RHIZO_FAIL' <<<"$out"):$(tail -1 <<<"$out")" "0:STARTED"
check "it names this start's verdict, not the earlier refusal" "$(grep -c 'SELinux namespace verdict enforced' <<<"$out")" 1
out=$(start_replay refused:landlock-domain active)
check "a start refused by its own verdict fails naming that refusal" \
      "$(grep -c "^RHIZO_FAIL Android's SELinux namespace start was refused: landlock-domain" <<<"$out")" 1
out=$(start_replay none failed)
check "a unit that fails before writing this start's verdict fails naming its state, never the earlier refusal" \
      "$(grep -c '^RHIZO_FAIL' <<<"$out"):$(grep -c 'relabeller-eof' <<<"$out"):$(grep -c 'went failed' <<<"$out")" "1:0:1"

touch "$NS/state/data.img"; echo 1 > "$NS/run/rhizo-selinuxns/android-enforce"; echo 0 > "$NS/enforce"
: > "$NS/prepare-args"
out=$(ns_run namespace 'PATH="$TMP/bin:$PATH"; wait_boot_completed() { return 0; }; do_reset')
check "reset with Android enforcing in namespace mode re-instantiates data only" \
      "$(grep -c -- '--data-only' "$NS/prepare-args"):$(tail -1 <<<"$out")" "1:RHIZO_RESET ok"
: > "$NS/prepare-args"
out=$(ns_run host 'PATH="$TMP/bin:$PATH"; wait_boot_completed() { return 0; }; do_reset')
check "reset in host mode reads the host node, not Android's namespace state" \
      "$(grep -c -- '--wipe-data' "$NS/prepare-args"):$(tail -1 <<<"$out")" "1:RHIZO_RESET ok"
: > "$NS/prepare-args"
out=$(ns_run namespace 'systemctl() { [[ "$1" == stop ]] && { echo stopped > "$NS/run/rhizo-selinuxns/selinuxns-verdict"
    echo 0 > "$NS/run/rhizo-selinuxns/android-enforce"; rm -rf "$NS/run/rhizo"; }; return 0; }
  wait_boot_completed() { return 0; }; do_reset')
run_root_after=$([[ -d "$NS/run/rhizo" ]] && echo kept || echo released)
check "reset in namespace mode reads Android's enforce state before its stop records the start's end and releases the run root" \
      "$run_root_after:$(grep -c -- '--data-only' "$NS/prepare-args"):$(tail -1 <<<"$out")" "released:1:RHIZO_RESET ok"
mkdir -p "$NS/run/rhizo"

echo 1 > "$NS/enforce"; : > "$NS/prepare-args"
out=$(ns_run namespace 'export RHIZO_CLI_TEST_NO_ROOT=1; gc_cache() { :; }; prepare_now --release a16')
check "prepare in namespace mode runs now on a host whose enforce node reads 1" \
      "$(cat "$NS/prepare-args")" "--payload $NS/lib --release a16"
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"; echo 'selinux-mode namespace' > "$NS/state/.created-by-install"
NS_UNITS='systemctl() { [[ "$1 ${2:-}" == "is-enabled rhizo-prepare.service" ]] && echo enabled; return 0; }'
out=$(ns_run namespace "$NS_UNITS; uname() { echo 7.0.0-38-generic; }; cmd_upgrade")
check "upgrade in namespace mode on a stock kernel asks for the reboot into the Rhizo kernel, never naming enforcement" \
      "$(grep -c 'reason=enforcing\|policy' <<<"$out"):$(tail -1 <<<"$out")" \
      "0:RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=rhizo-kernel"
check "upgrade in namespace mode over a namespace-mode install leaves host mode alone" \
      "$(grep -c 'pkg_leave_host_mode\|teardown' <<<"$out")" 0
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"
out=$(ns_run namespace "$NS_UNITS; uname() { echo 7.1.0-rc1-rhizo; }; cmd_upgrade")
check "upgrade in namespace mode on the Rhizo kernel defers setup to the next boot, naming no host policy" \
      "$(grep -c 'reason=enforcing\|policy' <<<"$out"):$(tail -1 <<<"$out")" \
      "0:RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=setup-at-boot"
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"; echo 'group:rhizo' > "$NS/state/.created-by-install"
out=$(ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; $NS_UNITS; cmd_upgrade")
check "upgrade in namespace mode over a host-mode install undoes host mode's edits, then re-applies the bootstrap" \
      "$(grep -e '^pkg_leave_host_mode' -e '^teardown' <<<"$out" | tr '\n' ';'):$(tail -1 <<<"$out")" \
      "pkg_leave_host_mode record=$NS/state/.created-by-install;:RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=rhizo-kernel"
check "an upgrade with no host-mode mark records no label removal" "$([[ -e "$NS/state/.host-labels-pending" ]] && echo kept)" ""
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"; printf 'group:rhizo\nlogin-defs-tty\n' > "$NS/state/.created-by-install"
out=$(ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; $NS_UNITS; cmd_upgrade")
check "an upgrade over a host-mode install names the switch, how to keep host mode, and the reboot it needs" \
      "$(grep -c "set RHIZO_SELINUX_MODE=host in $NS/etc/androidd.env and run 'rhizo install' to stay in host mode" <<<"$out"):$(grep -c \
         'switching this host from host mode to SELinux namespace mode, in effect after a reboot' <<<"$out")" "1:1"
check "an upgrade over a host-mode install records the label removal for the next boot, strips nothing, and goes on" \
      "$(cat "$NS/state/.host-labels-pending"):$(grep -c '^teardown' <<<"$out"):$(grep -c \
         'the next boot removes host mode.s SELinux labels from host files (rhizo-host-labels.service)' <<<"$out"):$(tail -1 <<<"$out")" \
      "pending:0:1:RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=rhizo-kernel"
rm -f "$NS/state/.host-labels-pending"
echo 'group:rhizo' > "$NS/state/.created-by-install"
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"
out=$(ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; $NS_UNITS; cmd_upgrade")
check "an upgrade with no host-mode mark says nothing of a switch" "$(grep -c 'To keep host mode' <<<"$out")" 0
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"; printf 'group:rhizo\nlogin-defs-tty\n' > "$NS/state/.created-by-install"
out=$(ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; $NS_UNITS
  HOST_LABELS_PENDING=\"$NS/no-dir/.host-labels-pending\"; cmd_upgrade")
check "a label removal record that cannot be written is named, and the upgrade goes on" \
      "$(grep -c "could not write $NS/no-dir/.host-labels-pending" <<<"$out"):$(tail -1 <<<"$out")" \
      "1:RHIZO_UPGRADE_REBOOT_REQUIRED=1 reason=rhizo-kernel"
echo 'group:rhizo' > "$NS/state/.created-by-install"
# print the status line for a planted label removal record and unit state
labels_line() {
  if [[ "$1" == none ]]; then rm -f "$NS/state/.host-labels-pending"; else printf '%s' "$1" > "$NS/state/.host-labels-pending"; fi
  ns_run namespace "systemctl() { [[ \"\$1 \$2\" == 'is-failed rhizo-host-labels.service' ]] && echo ${2:-inactive}; }
    host_labels_status"
}
check "status names no label removal when none is recorded" "$(labels_line none)" ""
check "status names a pending label removal for the next boot" "$(labels_line $'pending\n')" \
      "pending: the next boot removes host mode's labels (rhizo-host-labels.service)"
check "status names a removal whose unit failed before recording a reason" "$(labels_line $'pending\n' failed)" \
      "failed on this boot (journalctl -b -u rhizo-host-labels.service); the next boot retries"
check "status names a refused removal with the teardown's sentence" \
      "$(labels_line $'refused host-policy-loaded\nrestore with sudo restorecon -F /usr/sbin/sshd\n')" \
      "refused (host-policy-loaded): restore with sudo restorecon -F /usr/sbin/sshd"
check "status names a failed removal with the teardown's sentence" \
      "$(labels_line $'failed host-labels-clear-failed\nthe next boot tries again\n')" \
      "failed (host-labels-clear-failed): the next boot tries again"
check "status names a record it cannot read" "$(labels_line $'garbled\n')" \
      "unknown: $NS/state/.host-labels-pending reads 'garbled'"
labels_line $'pending\n' > /dev/null
out=$(NS_CONFIGURED=host ns_run host "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; resolve_uid1000() { :; }
  ensure_broker_group() { :; }; seed_apk_handler() { :; }; systemctl() { :; }; write_profile_key() { :; }
  apply_profile() { :; }; read_capability() { echo desktop; }; cmd_install")
check "a host-mode install drops a pending label removal, which host mode keeps" \
      "$([[ -e "$NS/state/.host-labels-pending" ]] && echo kept):$(grep -c 'host mode labels stay on host files' <<<"$out")" ":1"
check "a host-mode install applies host mode's files and edits through the library" \
      "$(grep '^pkg_enter_host_mode\|^pkg_leave_host_mode' <<<"$out")" "pkg_enter_host_mode record=$NS/state/.created-by-install"
out=$(NS_ENTER_RC=1 NS_CONFIGURED=host ns_run host "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }
  resolve_uid1000() { :; }; ensure_broker_group() { :; }; seed_apk_handler() { :; }; systemctl() { :; }
  write_profile_key() { :; }; apply_profile() { :; }; read_capability() { echo desktop; }; cmd_install; echo went on")
check "a host-mode install whose host-mode files fail stops before the bootstrap, named" "$(tail -1 <<<"$out")" \
      "[rhizo] FAIL: could not apply host mode's pacman.conf, login.defs or file links (see above)"
out=$(ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; resolve_uid1000() { :; }
  ensure_broker_group() { :; }; seed_apk_handler() { :; }; systemctl() { :; }; write_profile_key() { :; }
  apply_profile() { :; }; read_capability() { echo desktop; }; echo 'selinux-mode namespace' > \"$NS/state/.created-by-install\"
  cmd_install")
check "a namespace-mode install applies no host-mode file or edit" "$(grep -c '^pkg_enter_host_mode' <<<"$out")" 0
HELD_OUT='labeled: /usr/sbin/sshd\nfiles: /usr/sbin/sshd and 12 files under /usr/lib/modules
command: sudo restorecon -F /usr/sbin/sshd && sudo restorecon -RF /usr/lib/modules
RHIZO_TEARDOWN_HOST_LABELS labeled=1'
KEPT="$NS/state/host-mode-kept.env"
mkdir -p "$NS/default/policy"; : > "$NS/default/policy/policy.33"
KEEP_STEPS="1. reboot; 2. run 'sudo rhizo stop' and keep Android stopped; 3. run 'sudo restorecon -F /usr/sbin/sshd &&\
 sudo restorecon -RF /usr/lib/modules'; 4. run 'sudo rhizo install'"
# run an upgrade over a host-mode install
kept_upgrade() {
  if [[ "$1" == none ]]; then rm -f "$NS/selinux-config"; else printf '%s\n' "$1" > "$NS/selinux-config"; fi
  printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"; printf 'group:rhizo\nlogin-defs-tty\n' > "$NS/state/.created-by-install"
  printf 'RHIZO_SELINUX_MODE=namespace\n' > "$NS/etc/androidd.env"; rm -f "$NS/state/.host-labels-pending"
  NS_LABELS="$2" ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; $NS_UNITS; cmd_upgrade"
}
rm -f "$KEPT"
out=$(kept_upgrade $'SELINUX=enforcing\nSELINUXTYPE=default' "$HELD_OUT")
check "an upgrade on a host with its own enforcing policy and held labels keeps host mode, naming the steps to switch" \
      "$(grep -c '^pkg_leave_host_mode' <<<"$out"):$(grep -c '^pkg_enter_host_mode' <<<"$out"):$(sed -n 2p "$KEPT")\
:$([[ -e "$NS/state/.host-labels-pending" ]] && echo pending):$(grep -cF "To switch to namespace mode: $KEEP_STEPS" <<<"$out")" \
      "0:1:RHIZO_SELINUX_MODE=host::1"
check "a kept host mode leaves androidd.env, the package's conffile, as the package wrote it" \
      "$(cat "$NS/etc/androidd.env")" "RHIZO_SELINUX_MODE=namespace"
check "the kept host mode is recorded with the same steps for rhizo status" \
      "$(sed -n '1s/^# this host loads its own SELinux policy.*/found/p' "$KEPT")|$(grep -cF "$KEEP_STEPS" "$KEPT")" "found|1"
check "the kept upgrade names the host's config and the files" \
      "$(grep -c "SELINUX=enforcing SELINUXTYPE=default in $NS/selinux-config) and host mode's label is on /usr/sbin/sshd and 12 files" <<<"$out")" 1
out=$(ns_run namespace "sandbox_init_pid() { :; }; systemctl() { echo inactive; }; cmd_status")
check "rhizo status names the kept host mode and the steps to switch" \
      "$(grep -cF "[rhizo] host mode    : kept; this host loads its own SELinux policy" <<<"$out"):$(grep -cF "$KEEP_STEPS" <<<"$out")" "1:1"
out=$(kept_upgrade $'SELINUX=enforcing\nSELINUXTYPE=default' "$HELD_OUT")
check "a re-run while the labels are still held keeps host mode and its record" \
      "$(grep -c '^pkg_leave_host_mode' <<<"$out"):$(sed -n 2p "$KEPT")" "0:RHIZO_SELINUX_MODE=host"
out=$(kept_upgrade $'SELINUX=enforcing\nSELINUXTYPE=default' 'RHIZO_TEARDOWN_HOST_LABELS labeled=0')
check "after the owner's restorecon, the run drops the kept host mode and switches to namespace mode" \
      "$(grep -c "no host file has host mode's label: removed " <<<"$out"):$(grep -c '^pkg_leave_host_mode' <<<"$out"):$([[ -e "$KEPT" ]] && echo kept)\
:$(cat "$NS/state/.host-labels-pending" 2>&1)" "1:1::pending"
out=$(kept_upgrade $'SELINUX=permissive\nSELINUXTYPE=default' 'RHIZO_TEARDOWN_HOST_LABELS labeled=0')
check "a host policy with no label held switches to namespace mode on the first upgrade" \
      "$(grep -c '^pkg_leave_host_mode' <<<"$out"):$(cat "$NS/state/.host-labels-pending" 2>&1):$([[ -e "$KEPT" ]] && echo kept)" \
      "1:pending:"
out=$(kept_upgrade $'SELINUX=disabled\nSELINUXTYPE=default' "$HELD_OUT")
check "a host config that loads no policy switches to namespace mode" \
      "$(grep -c '^pkg_leave_host_mode' <<<"$out"):$(grep -c '^teardown --list-host-labels' <<<"$out"):$([[ -e "$KEPT" ]] && echo kept)" "1:0:"
out=$(kept_upgrade none "$HELD_OUT")
check "a host with no SELinux config switches to namespace mode" "$(grep -c '^pkg_leave_host_mode' <<<"$out")" 1
rm -f "$KEPT"
out=$(kept_upgrade $'SELINUX=enforcing\nSELINUXTYPE=gone' "$HELD_OUT")
check "a config naming a policy type with no policy file switches to namespace mode, naming that case" \
      "$(grep -c '^pkg_leave_host_mode' <<<"$out"):$(grep -c '^teardown --list-host-labels' <<<"$out"):$([[ -e "$KEPT" ]] && echo kept)\
:$(grep -c "no $NS/gone/policy/policy.\* for SELINUXTYPE=gone in $NS/selinux-config:" <<<"$out")" \
      "1:0::1"
rm -f "$KEPT"
out=$(kept_upgrade $'SELINUX=enforcing\nSELINUXTYPE=default' 'garbage')
check "a failed label scan keeps host mode, naming the scan's output and how to list the files" \
      "$(grep -c '^pkg_leave_host_mode' <<<"$out"):$(sed -n 2p "$KEPT"):$(grep -c "the label scan printed 'garbage'" <<<"$out")" \
      "0:RHIZO_SELINUX_MODE=host:1"
printf '# kept\nRHIZO_SELINUX_MODE=host\n' > "$KEPT"; printf 'SELINUX=enforcing\nSELINUXTYPE=default\n' > "$NS/selinux-config"
out=$(NS_LABELS='RHIZO_TEARDOWN_HOST_LABELS labeled=0' ns_run namespace 'refuse_start_mid_switch; echo "went on"')
check "a start while the switch from a kept host mode is half done is refused by name, naming how to finish" \
      "$(grep -c "host mode is kept and no host file has host mode's label" <<<"$out"):$(grep -c "run 'sudo rhizo install' to switch" <<<"$out")\
:$(grep -c 'went on' <<<"$out")" "1:1:0"
out=$(NS_LABELS="$HELD_OUT" ns_run namespace 'refuse_start_mid_switch; echo "went on"')
check "a start in a kept host mode whose labels are still held goes on" "$(tail -1 <<<"$out")" "went on"
rm -f "$KEPT"
out=$(NS_LABELS='RHIZO_TEARDOWN_HOST_LABELS labeled=0' ns_run namespace 'refuse_start_mid_switch; echo "went on"')
check "a start with no kept host mode scans nothing and goes on" "$(grep -c '^teardown' <<<"$out"):$(tail -1 <<<"$out")" \
      "0:went on"
check "start_sandbox runs the half-done switch refusal before it starts the unit" \
      "$(sed -n '/^start_sandbox()/,/^}/p' "$CLI" | grep -A1 '^      refuse_start_without_mode$' | tail -1 | tr -d ' ')" \
      "refuse_start_mid_switch"
printf 'SELINUX=enforcing\nSELINUXTYPE=default\n' > "$NS/selinux-config"; printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"
printf 'group:rhizo\nlogin-defs-tty\n' > "$NS/state/.created-by-install"
out=$(NS_LABELS="$HELD_OUT" ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; $NS_UNITS
  HOST_MODE_KEPT=\"$NS/no-dir/host-mode-kept.env\"; cmd_upgrade; echo \"exported=\$RHIZO_SELINUX_MODE\"")
check "a kept record that cannot be written is named, and the run still keeps host mode" \
      "$(grep -c "could not write $NS/no-dir/host-mode-kept.env" <<<"$out"):$(grep -c '^pkg_leave_host_mode' <<<"$out")\
:$(tail -1 <<<"$out")" "1:0:exported=host"
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"; echo 'group:rhizo' > "$NS/state/.created-by-install"
printf 'SELINUX=enforcing\nSELINUXTYPE=default\n' > "$NS/selinux-config"
out=$(NS_LABELS="$HELD_OUT" ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; $NS_UNITS; cmd_upgrade")
check "a namespace install on a host with its own policy and no host-mode mark goes on, scanning nothing" \
      "$(grep -c '^teardown --list-host-labels' <<<"$out"):$(grep -c 'keeps host mode' <<<"$out")" "0:0"
rm -f "$NS/selinux-config" "$KEPT" "$NS/state/.host-labels-pending" "$NS/state/.prepared" "$NS/default/policy/policy.33"
printf 'RHIZO_SELINUX_MODE=namespace\n' > "$NS/etc/androidd.env"
echo 'group:rhizo' > "$NS/state/.created-by-install"
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"
NS_STATUS='sandbox_init_pid() { :; }; systemctl() { echo inactive; }; cmd_status'
out=$(NS_LIVE=refuse:kernel-has-no-selinux-namespaces ns_run none "$NS_STATUS")
check "status on a prepared host names a boot the mode helper refuses" \
      "$(grep -cxF '[rhizo] this boot    : refused (kernel-has-no-selinux-namespaces): boot the Rhizo kernel (uname -r ends in -rhizo) to start Android' <<<"$out")" 1
out=$(ns_run none "$NS_STATUS")
check "status on a prepared host whose boot can start Android names no refusal" "$(grep -c 'this boot' <<<"$out")" 0
rm -f "$NS/state/.prepared"
echo 'group:rhizo' > "$NS/state/.created-by-install"
out=$(ns_run namespace "export RHIZO_CLI_TEST_NO_ROOT=1; resolve_uid1000() { echo resolved; }; LIB_DIR=\"$NS/no-lib\"
  cmd_install")
check "install with no mode helper stops before any account or unit change, named" \
      "$(grep -c resolved <<<"$out"):$(tail -2 <<<"$out" | head -1 | sed 's/^.*: line [0-9]*: //')" \
      "0:[rhizo] cannot read the configured SELinux mode from $NS/no-lib/rhizo-selinux-mode"
mkdir -p "$NS/bad-lib"; printf '#!/bin/sh\necho "rhizo-selinux-mode: broken" >&2\nexit 255\n' > "$NS/bad-lib/rhizo-selinux-mode"
chmod +x "$NS/bad-lib/rhizo-selinux-mode"
out=$(ns_run namespace "$NS_UNITS; RHIZO_SELINUX_MODE_HELPER=\"$NS/bad-lib/rhizo-selinux-mode\" cmd_upgrade")
check "upgrade with a failing mode helper stops before the bootstrap, its message shown" \
      "$(tr '\n' '|' <<<"$out")" "rhizo-selinux-mode: broken|[rhizo] cannot read the configured SELinux mode from\
 $NS/bad-lib/rhizo-selinux-mode|[rhizo] FAIL: upgrade needs the configured SELinux mode (see above)|"
printf 'kernel=k\nversion=0.1.3\n' > "$NS/state/.prepared"; echo 'group:rhizo' > "$NS/state/.created-by-install"
out=$(NS_CONFIGURED=host ns_run host "export RHIZO_CLI_TEST_NO_ROOT=1; load_host_libs() { :; }; $NS_UNITS; cmd_upgrade")
check "upgrade in host mode over a record with no namespace line runs no migration" \
      "$(grep -c '^pkg_leave_host_mode\|^teardown' <<<"$out")" 0
out=$(ns_run namespace "$NS_UNITS; prepare_now() { echo prepare \"\$*\"; }; cmd_upgrade --verify")
check "upgrade --verify in namespace mode runs prepare's check alone: no migration, no bootstrap apply" \
      "$(grep -c '^pkg_leave_host_mode\|^teardown\|re-applying' <<<"$out")" 0
out=$(NS_CONFIGURED=bogus ns_run namespace "$NS_UNITS; cmd_upgrade")
check "a configured mode that is neither stops the upgrade before any change" \
      "$(tail -2 <<<"$out")" "[rhizo] $NS/lib/rhizo-selinux-mode --configured printed 'bogus', not host or namespace
[rhizo] FAIL: upgrade needs the configured SELinux mode (see above)"
rm -f "$NS/state/.created-by-install"

# print the selinux or policy line of rhizo status
ns_status_line() {
  if [[ "$2" == none ]]; then rm -f "$NS/run/rhizo-selinuxns/selinuxns-verdict"
  else echo "$2" > "$NS/run/rhizo-selinuxns/selinuxns-verdict"; fi
  ns_run "$1" 'sandbox_init_pid() { :; }; systemctl() { echo inactive; }; policy_status_line() { echo "not loaded"; }
    cmd_status' | grep -E '^\[rhizo\] (selinux|policy) +:'
}
for pair in "enforced:Android enforcing" \
            "pending:Android start ended with no verdict (recorded 'pending', unit inactive)" \
            "handed-off:Android start ended with no verdict (recorded 'handed-off', unit inactive)" \
            "refused:relabeller-timeout:Android refused: relabeller-timeout" \
            "permissive:Android permissive (RHIZO_PERMISSIVE=1)" "stopped:Android stopped" \
            "none:Android not started on this boot"; do
  v=${pair%%:Android*}; want=${pair#"$v":}
  check "status in namespace mode reads verdict $v as '$want', with no host enforce" \
        "$(ns_status_line namespace "$v")" "[rhizo] selinux      : namespace, $want"
done
echo pending > "$NS/run/rhizo-selinuxns/selinuxns-verdict"
check "status reads a pending verdict under an activating unit as Android starting" \
      "$(ns_run namespace 'sandbox_init_pid() { :; }; systemctl() { echo activating; }; policy_status_line() { :; }
        cmd_status' | grep -E '^\[rhizo\] selinux +:')" "[rhizo] selinux      : namespace, Android starting"
echo stopped > "$NS/run/rhizo-selinuxns/selinuxns-verdict"; echo 0 > "$NS/run/rhizo-selinuxns/android-enforce"
check "status after a stop reads the records a start's end leaves as Android stopped with enforce state 0" \
      "$(ns_run namespace 'sandbox_init_pid() { :; }; systemctl() { echo inactive; }; policy_status_line() { :; }
        cmd_status' | grep -E '^\[rhizo\] (sandbox|selinux) +:'):$(ns_run namespace android_enforce_state)" \
      "[rhizo] sandbox      : not running
[rhizo] selinux      : namespace, Android stopped:0"
check "status in host mode keeps the policy line and the host enforce node" \
      "$(ns_status_line host enforced)" "[rhizo] policy       : not loaded enforce=1"
rm -rf "$NS/run/rhizo"
check "status after a stop released the run root still names the start's refusal" \
      "$(ns_status_line namespace refused:relabeller-timeout)" \
      "[rhizo] selinux      : namespace, Android refused: relabeller-timeout"
mkdir -p "$NS/run/rhizo"
touch "$NS/lib/probe-client.py"
# print the boot line of rhizo status
ns_boot_line() {
  NS_INIT="$2" NS_BC="$3" ns_run "$1" 'sandbox_init_pid() { [[ "$NS_INIT" == none ]] || printf %s "$NS_INIT"; }
    systemctl() { echo active; }; policy_status_line() { echo "not loaded"; }; sandbox_adb_endpoint() { :; }
    android_sh() { [[ "$1" == "getprop sys.boot_completed" ]] && printf "%s\n" "$NS_BC"; }
    cmd_status' | grep -E '^\[rhizo\] (boot|last boot) +:'
}
check "status in host mode reads sys.boot_completed=1 through the probe" \
      "$(ns_boot_line host 4242 1)" "[rhizo] boot         : sys.boot_completed=1"
check "status in host mode reports a boot the probe reads as not completed" \
      "$(ns_boot_line host 4242 0)" "[rhizo] boot         : sys.boot_completed reads '0', not 1"
check "status in namespace mode reads sys.boot_completed=1 through the probe" \
      "$(ns_boot_line namespace 4242 1)" "[rhizo] boot         : sys.boot_completed=1"
check "status with no sandbox running names the last boot's log and asks no probe" \
      "$(ns_boot_line host none 1)" "[rhizo] boot         : not running; last boot log $NS/log/boot.log"

# run a doctor check in a fresh cli for a recorded mode
ns_doctor() {
  ns_run "$1" 'uname() { echo 7.2.9-1-rhizo; }
    systemctl() { case "$1" in is-enabled) echo enabled ;; is-active) echo inactive ;; esac; }
    DOCTOR_ISSUES=0 DOCTOR_WARNINGS=0; '"$2"'; echo "counts issues=$DOCTOR_ISSUES warnings=$DOCTOR_WARNINGS"'
}
check "doctor passes namespace mode, naming the kernel and the Landlock ABI" \
      "$(ns_doctor namespace check_selinux_active)" \
      "[rhizo]   selinux-active: ok -- SELinux namespace mode: kernel 7.2.9-1-rhizo, Landlock ABI 7
[rhizo]   host-selinux: ok -- host SELinux none: Rhizo leaves it as found
counts issues=0 warnings=0"
check "doctor reports an enforcing host policy as found, not as an issue" \
      "$(NS_HOST_STATE=enforcing ns_doctor namespace check_selinux_active | tail -2)" \
      "[rhizo]   host-selinux: ok -- host SELinux enforcing: Rhizo leaves it as found
counts issues=0 warnings=0"
check "doctor warns a namespace-mode host still on a kernel with no SELinux namespaces" \
      "$(NS_LIVE=refuse:kernel-has-no-selinux-namespaces ns_doctor namespace check_selinux_active)" \
      "[rhizo]   selinux-active: warn -- boot the Rhizo kernel (uname -r ends in -rhizo) to start Android (refuse:kernel-has-no-selinux-namespaces)
counts issues=0 warnings=1"
check "doctor fails a namespace-mode host the mode helper refuses for another reason" \
      "$(NS_LIVE=refuse:kernel-has-no-landlock ns_doctor namespace check_selinux_active | tail -1)" "counts issues=1 warnings=0"
export NS_CALLS="$NS/mode-calls"; : > "$NS_CALLS"
NS_LIVE=refuse:kernel-has-no-landlock ns_doctor namespace check_selinux_active >/dev/null
check "doctor asks the mode helper once for a refusal and its reason" "$(sort -u "$NS_CALLS")" \
      "--env-file $NS/etc/androidd.env --mode-and-why"
unset NS_CALLS
check "doctor warns, naming the helper and its exit status, when --host-state fails" \
      "$(NS_HOST_STATE=fail ns_doctor namespace check_selinux_active | tail -2 | sed "s|$NS|NS|")" \
      "[rhizo]   host-selinux: warn -- NS/lib/rhizo-selinux-mode --host-state exited 3
counts issues=0 warnings=1"
check "doctor skips the host selinuxfs check in namespace mode" "$(ns_doctor namespace check_selinuxfs)" \
      "[rhizo]   selinuxfs: skip -- namespace mode: Android mounts selinuxfs in its namespace
counts issues=0 warnings=0"
check "doctor skips the host policy unit check in namespace mode" "$(ns_doctor namespace check_policy_unit)" \
      "[rhizo]   policy-unit: skip -- namespace mode: the host loads no policy
counts issues=0 warnings=0"

rm -f "$NS/state/.prepared"; echo 1 > "$NS/enforce"
out=$(ns_run namespace 'systemctl() { echo inactive; }; refuse_start_without_setup')
check "a start pending a reboot in namespace mode names the Rhizo kernel" \
      "$(grep -c "^RHIZO_FAIL setup is pending a reboot: reboot into the Rhizo kernel to finish the install or upgrade$" <<<"$out")" 1
check "and names neither host enforcement nor SELinux becoming the security module" \
      "$(grep -c "security module\|policy loads" <<<"$out")" 0

# run start_sandbox on a booted init
ns_start() {
  echo "$2" > "$NS/run/rhizo-selinuxns/selinuxns-verdict"
  echo this-start > "$NS/run/rhizo-selinuxns/start-id"
  if [[ -n "${3:-}" ]]; then echo "$3" > "$NS/etc/androidd.env"; else rm -f "$NS/etc/androidd.env"; fi
  echo 0 > "$NS/clock"
  ns_run "$1" 'require_probe_client() { :; }; sandbox_init_pid() { printf 4242; }
    systemctl() { case "$1" in is-active) echo active ;; show) echo this-start ;; esac; }
    date() { local t; t=$(( $(cat "$NS/clock") + 60 )); echo "$t" > "$NS/clock"; echo "$t"; }
    sleep() { :; }; android_sh() { echo 1; }
    start_sandbox && echo STARTED' | tail -1
}
check "a namespace-mode start succeeds once Android answers boot_completed and the verdict reads enforced" \
      "$(ns_start namespace enforced)" STARTED
check "a refused namespace start fails naming the reason" "$(ns_start namespace refused:relabeller-timeout)" \
      "RHIZO_FAIL Android's SELinux namespace start was refused: relabeller-timeout (androidd.service is active)"
check "a namespace start still pending after boot_completed fails at the deadline naming the verdict" \
      "$(ns_start namespace pending)" \
      "RHIZO_FAIL Android reported sys.boot_completed=1 with SELinux namespace verdict 'pending', not enforced, after 300s (androidd.service is active)"
check "a permissive verdict fails a start whose androidd.env does not ask for permissive" \
      "$(ns_start namespace permissive)" \
      "RHIZO_FAIL Android reported sys.boot_completed=1 with SELinux namespace verdict 'permissive', not enforced, after 300s (androidd.service is active)"
check "a permissive verdict starts under RHIZO_PERMISSIVE=1" "$(ns_start namespace permissive RHIZO_PERMISSIVE=1)" STARTED
check "a host-mode start reads no namespace verdict" "$(ns_start host refused:relabeller-timeout)" STARTED

# run start_sandbox with no sandbox up
ns_cold_start() {
  rm -f "$NS/calls" "$NS/etc/install-failed" "$NS/state/.configure-pending"; : > "$NS/state/.prepared"
  ns_run namespace "require_probe_client() { :; }; sandbox_init_pid() { :; }
    systemctl() { echo \"systemctl \$*\" >> \"$NS/calls\"; [[ \$1 == start ]] && exit 7; }
    $1; start_sandbox"
  echo "rc=$?"
}
export NS_CALLS="$NS/mode-calls"; : > "$NS_CALLS"
NS_LIVE=refuse:kernel-has-no-selinux-namespaces ns_cold_start : >/dev/null
check "a refused start asks the mode helper once for the refusal and its reason" \
      "$(grep -c -- '--env-file' "$NS_CALLS")|$(grep -c -- '--mode-and-why' "$NS_CALLS")" "1|1"
unset NS_CALLS
out=$(NS_LIVE=refuse:kernel-has-no-selinux-namespaces ns_cold_start :)
check "a start on a kernel without SELinux namespaces prints the helper's reason, and starts nothing" \
      "$out|$(grep -c 'start' "$NS/calls" 2>/dev/null || true)" "RHIZO_FAIL boot the Rhizo kernel (uname -r ends in -rhizo) to\
 start Android (refuse:kernel-has-no-selinux-namespaces)
rc=1|0"
out=$(ns_cold_start 'LIB_DIR="$NS/bad-lib"')
check "a start whose mode helper fails names the helper, and starts nothing" \
      "$(tail -2 <<<"$out")|$(grep -c 'start' "$NS/calls" 2>/dev/null || true)" "RHIZO_FAIL cannot read this boot's SELinux\
 mode from $NS/bad-lib/rhizo-selinux-mode (exit 255, see above)
rc=1|0"
out=$(ns_cold_start :)
check "a start the helper allows reaches systemctl start" "$(tail -1 <<<"$out")|$(grep -c '^systemctl start androidd.service$' \
      "$NS/calls")" "rc=7|1"

: > "$NS/state/.configure-pending"
check "a configure pacman's hook never finished reads as install-failed, even over a .prepared marker" \
      "$(ns_run namespace 'setup_state; install_failed_note')" "install-failed
pacman's configure hook did not finish ($NS/state/.configure-pending exists): run\
 'sudo /usr/share/libalpm/scripts/rhizo-configure', or install the same packages again"
out=$(ns_run namespace "require_probe_client() { :; }; sandbox_init_pid() { :; }
  systemctl() { echo \"systemctl \$*\" >> \"$NS/calls\"; }; start_sandbox")
check "a start with the hook's configure left pending refuses, naming the hook" \
      "$(grep -c "^RHIZO_FAIL pacman's configure hook did not finish" <<<"$out")" 1
echo 'pkg_accounts 1' > "$NS/etc/install-failed"
check "a saved failed step still names that step over a pending configure" "$(ns_run namespace install_failed_note)" \
      "the install failed at pkg_accounts (exit 1): fix that step, then install the same packages again"
rm -f "$NS/etc/install-failed" "$NS/state/.configure-pending"

STOP="$TMP/stop"; mkdir -p "$STOP/bin" "$STOP/etc" "$STOP/state"
cat > "$STOP/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$STOP/calls"
case "\$1" in
  stop) rm -f "$STOP/active-\$2"; [[ -e "$STOP/fail-stop" ]] && exit 1; exit 0 ;;
  is-active)
    [[ ! -e "$STOP/active-\$2" ]] || { echo active; exit 0; }
    cat "$STOP/state-after" 2>/dev/null || echo inactive; [[ "\$(cat "$STOP/state-after" 2>/dev/null)" == active ]] ;;
esac
EOF
chmod +x "$STOP/bin/systemctl"
# run a rhizo stop command line
stop_run() {
  rm -f "$STOP/calls"
  PATH="$STOP/bin:$PATH" RHIZO_CLI_TEST_NO_ROOT=1 RHIZO_ETC_DIR="$STOP/etc" RHIZO_STATE_DIR="$STOP/state" \
    RHIZO_VAR_LOG="$STOP/log" bash "$CLI" "$@" 2>&1
  echo "rc=$?"
}
check "rhizo stop stops androidd.service and confirms it inactive" \
      "$(stop_run stop | tr '\n' '|')$(tr '\n' '|' < "$STOP/calls")" \
      "[rhizo] stopping androidd.service|[rhizo] androidd.service is inactive|rc=0|systemctl stop androidd.service|\
systemctl is-active androidd.service|"
mkdir -p "$STOP/etc/instances"; echo RHIZO_SANDBOX_ID=3 > "$STOP/etc/instances/3.env"
echo RHIZO_SANDBOX_ID=7 > "$STOP/etc/instances/7.env"
check "rhizo stop -i 3 stops instance 3's own unit" "$(stop_run stop -i 3 | head -1)" "[rhizo] stopping androidd@3.service"
check "rhizo stop -i 4, never configured: refused, named, nothing stopped" \
      "$(stop_run stop -i 4 | tr '\n' '|')$(tr '\n' '|' < "$STOP/calls")" \
      "[rhizo] FAIL: instance 4 is not configured: no $STOP/etc/instances/4.env ('rhizo instance add 4' makes one)|rc=1|\
systemctl is-active androidd@4.service|"
: > "$STOP/active-androidd@5.service"
check "rhizo stop -i 5, its env file deleted while the unit still runs: stopped, the missing file named" \
      "$(stop_run stop -i 5 | tr '\n' '|')" "[rhizo] androidd@5.service is active with no $STOP/etc/instances/5.env|\
[rhizo] stopping androidd@5.service|[rhizo] androidd@5.service is inactive|rc=0|"
check "rhizo -i 07 stop reaches the same unit as -i 7" "$(stop_run -i 07 stop | head -1)" "[rhizo] stopping androidd@7.service"
check "rhizo stop with a stray argument: refused before any stop" "$(stop_run stop now | tail -2 | tr '\n' '|')$([[ -e "$STOP/calls" ]] && echo called)" \
      "[rhizo] FAIL: stop takes no arguments but -i <id>|rc=1|"
touch "$STOP/fail-stop"
check "a failed systemctl stop fails rhizo stop, naming the unit's state" "$(stop_run stop | tail -2 | tr '\n' '|')" \
      "[rhizo] FAIL: systemctl stop androidd.service failed (unit state: inactive)|rc=1|"
rm "$STOP/fail-stop"; echo active > "$STOP/state-after"
check "a unit still active after systemctl stop returned 0: rhizo stop fails, named" "$(stop_run stop | tail -2 | tr '\n' '|')" \
      "[rhizo] FAIL: systemctl stop androidd.service returned 0 but the unit is 'active', not inactive|rc=1|"
rm "$STOP/state-after"
rm -f "$STOP/calls"
check_unprivileged "rhizo stop refuses a caller that is not root, before any stop" \
      "$(RHIZO_CLI_TEST_NO_ROOT=0 RHIZO_ETC_DIR="$STOP/etc" RHIZO_STATE_DIR="$STOP/state" PATH="$STOP/bin:$PATH" \
         bash "$CLI" stop 2>&1; echo "rc=$?"; [[ -e "$STOP/calls" ]] && echo called)" \
      "[rhizo] FAIL: stop must run as root
rc=1"

AH="$TMP/apt-history"; mkdir -p "$AH/log" "$AH/dpkg"; TAB=$'\t'
added_run() {
  (
    dpkg() { echo amd64; }
    dpkg-query() {
      local n rc=0; shift 3
      for n; do
        if grep -qx "$n" "$AH/installed"; then printf 'ii  %s\n' "${n%:*}:$([[ $n == *:* ]] && echo "${n#*:}" || echo amd64)"
        else rc=1; fi
      done
      return "$rc"
    }
    apt-mark() { local n; shift; for n; do grep -qx "$n" "$AH/auto" && echo "$n"; done; return 0; }
    apt-get() { local n; shift 2; for n; do echo "Purg $n [1]"; done; [[ " $* " != *" gcc "* ]] || cat "$AH/outside" 2>/dev/null; return 0; }
    apt-cache() { cat "$AH/deps"; }
    RHIZO_APT_HISTORY_DIR="$AH/log" RHIZO_DPKG_LOG_DIR="$AH/dpkg" rhizo_added_packages
  )
  echo "rc=$?"
}
# write an apt transaction to a history file
added_txn() { printf '\nStart-Date: %s\nCommandline: apt install\nInstall: %s\nEnd-Date: %s\n' "$2" "$3" "$2"; }
check "added packages: no apt history names none, by name" "$(added_run)" \
      "no apt history in $AH/log, so the packages Rhizo's install added cannot be named
rc=2"
added_txn x 2026-10-01 "vim:amd64 (9, automatic)" > "$AH/log/history.log"
check "added packages: a history with no rhizo transaction names none, by name" "$(added_run)" \
      "apt's history in $AH/log holds no transaction that installed rhizo, so the packages it added cannot be named
rc=2"
added_txn x "2026-09-01  10:00:00" "rhizo:amd64 (0.1.3), olddep:amd64 (1, automatic)" | gzip > "$AH/log/history.log.2.gz"
added_txn x "2026-10-02  10:00:00" "gcc:amd64 (13, automatic), rhizo:amd64 (0.1.4), make:amd64 (4.3, automatic), libfoo:i386 (1, \
automatic), keepme:amd64 (1, automatic), gone:amd64 (1, automatic)" \
  | gzip > "$AH/log/history.log.1.gz"
printf '%s\n' gcc make libfoo:i386 keepme olddep > "$AH/installed"
printf '%s\n' gcc make libfoo:i386 olddep > "$AH/auto"
printf '%s\n' "2026-10-02 10:00:00 install gcc:amd64 <none> 13" "2026-10-02 10:00:00 install make:amd64 <none> 4.3" \
  "2026-10-02 10:00:00 install libfoo:i386 <none> 1" "2026-10-02 10:00:00 install keepme:amd64 <none> 1" \
  "2026-10-02 10:00:00 install gone:amd64 <none> 1" > "$AH/dpkg/dpkg.log"
check "added packages: the newest rhizo transaction's automatic ones, still installed and automatic" "$(added_run)" \
      "purge${TAB}gcc
purge${TAB}libfoo:i386
purge${TAB}make
rc=0"
echo "Remv libtool [1]" > "$AH/outside"
printf '%s\n' libtool "  Depends: gcc" gcc "  Depends: libc6" > "$AH/deps"
check "added packages: one a package outside the list depends on is left out" "$(added_run)" \
      "purge${TAB}libfoo:i386
purge${TAB}make
rc=0"
rm "$AH/outside"
added_txn x "2026-10-05  09:00:00" "dwarves:amd64 (1, automatic), pahole:amd64 (1, automatic)" \
  | sed 's/^Install: \(.*\)$/Upgrade: rhizo:amd64 (0.1.4, 0.1.5)\nInstall: \1/' > "$AH/log/history.log"
printf '%s\n' dwarves pahole >> "$AH/installed"; printf '%s\n' dwarves pahole >> "$AH/auto"
printf '%s\n' "2026-10-05 09:00:00 install dwarves:amd64 <none> 1" "2026-10-05 09:00:00 install pahole:amd64 <none> 1" \
  >> "$AH/dpkg/dpkg.log"
check "added packages: an upgrade of rhizo adds what it installed" "$(added_run)" \
      "purge${TAB}dwarves
purge${TAB}gcc
purge${TAB}libfoo:i386
purge${TAB}make
purge${TAB}pahole
rc=0"
sed -i 's/install make:amd64 <none> 4.3/install make:amd64 4.2 4.3/' "$AH/dpkg/dpkg.log"
check "added packages: one whose older configuration files dpkg kept is named for remove, not purge" \
      "$(added_run | grep make)" "remove${TAB}make"
sed -i '/install gcc:amd64/d' "$AH/dpkg/dpkg.log"
check "added packages: one dpkg's log does not show installed names none, by name" "$(added_run)" \
      "dpkg's log in $AH/dpkg holds no install of gcc between 2026-10-02 10:00:00 and 2026-10-02 10:00:00, so whether\
 it had configuration files before Rhizo cannot be told
rc=2"
chmod 000 "$AH/log/history.log.1.gz"
check_unprivileged "added packages: an unreadable rotated history names none, by name" "$(added_run)" \
      "cannot read $AH/log/history.log.1.gz as uid $EUID, so the packages Rhizo's install added cannot be named
rc=2"
chmod 644 "$AH/log/history.log.1.gz"

RAN=$(grep -c . "$RUN_LOG")
FAILED=$(grep -c . "$FAIL_LOG")
SKIPPED=$(grep -c . "$SKIP_LOG")
SKIP_NOTE=""; (( SKIPPED )) && SKIP_NOTE=", $SKIPPED skipped as root"
echo "$RAN checks run, $FAILED failed$SKIP_NOTE"
[[ $FAILED -eq 0 ]]
