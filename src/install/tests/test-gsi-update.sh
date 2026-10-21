#!/bin/bash
# test gsi-update.sh offline
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../update/gsi-update.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"
    echo "       got  $2"
    echo "       want $3"
    FAILED=$((FAILED + 1))
  fi
}

GSI_ROOT="$TMP/gsiroot"
for rel_dir in gsi_system gsi_system_a15 gsi_system_a17; do
  mkdir -p "$GSI_ROOT/$rel_dir/bin"
  printf '#!/bin/sh\nexit 0\n' > "$GSI_ROOT/$rel_dir/bin/init"
  chmod +x "$GSI_ROOT/$rel_dir/bin/init"
done

DATA_IMG_PATH="$TMP/data.img"
printf '%s' "OLD_DATA_BYTES_A16" > "$DATA_IMG_PATH"

FETCH_STUB="$TMP/gsi.sh"
printf '#!/bin/sh\nexit 0\n' > "$FETCH_STUB"; chmod +x "$FETCH_STUB"
E2FSCK_STUB="$TMP/e2fsck-stub.sh"
printf '#!/bin/sh\nexit 0\n' > "$E2FSCK_STUB"; chmod +x "$E2FSCK_STUB"
PREPARE_STUB="$TMP/prepare.sh"
PREPARE_RECORD="$TMP/prepare-data-img.recorded"
cat > "$PREPARE_STUB" <<EOF
#!/bin/sh
printf '%s' "\$RHIZO_DATA_IMG" > "$PREPARE_RECORD"
exit 0
EOF
chmod +x "$PREPARE_STUB"

AWAIT_RESULT="$TMP/await-result"
AWAIT_STUB="$TMP/await-boot.py"
AWAIT_HOOK="$TMP/await-hook.sh"
cat > "$AWAIT_STUB" <<PYEOF
import os, subprocess, sys
if os.path.exists("$AWAIT_HOOK"):
    subprocess.run(["bash", "$AWAIT_HOOK"], check=True)
    os.unlink("$AWAIT_HOOK")
with open("$AWAIT_RESULT") as f:
    sys.exit(int(f.read().strip()))
PYEOF

ANDROIDD_ENV="$TMP/androidd.env"
RUNTIME_FILE="$TMP/runtime.env"
export RHIZO_RUNTIME_ENV="$RUNTIME_FILE"

KALLSYMS_PATCHED="$TMP/kallsyms-patched"
printf '%s\n' 'ffffffff81000000 T _stext' 'ffffffff81234560 T bpf_get_current_pid_tgid_vnr' \
  'ffffffff81234600 t bpf_get_netns_cookie_sock_create' > "$KALLSYMS_PATCHED"
KALLSYMS_STOCK="$TMP/kallsyms-stock"
printf '%s\n' '0000000000000000 T _stext' '0000000000000000 t bpf_get_netns_cookie_sockopt' \
  '0000000000000000 T bpf_get_current_pid_tgid' '0000000000000000 t bpf_get_netns_cookie_sock' > "$KALLSYMS_STOCK"
export RHIZO_KALLSYMS="$KALLSYMS_PATCHED"

ATTR_CURRENT="$TMP/attr-current"
printf 'kernel' > "$ATTR_CURRENT"
export RHIZO_ATTR_CURRENT="$ATTR_CURRENT"
export RHIZO_SELINUX_MODE_HELPER="$HERE/../../androidd/host/selinux-mode.py"
export RHIZO_SELINUX_MODE=host

export RHIZO_STATE_DIR="$TMP/state"
export RHIZO_DATA_IMG="$DATA_IMG_PATH"
export RHIZO_GSI_ROOT="$GSI_ROOT"
export RHIZO_FETCH_GSI="$FETCH_STUB"
export RHIZO_PREPARE_SH="$PREPARE_STUB"
export RHIZO_AWAIT_BOOT="$AWAIT_STUB"
export RHIZO_E2FSCK="$E2FSCK_STUB"
export RHIZO_ANDROIDD_ENV="$ANDROIDD_ENV"
BOOT_ID="$TMP/boot_id"
printf 'boot-0' > "$BOOT_ID"
export RHIZO_BOOT_ID_FILE="$BOOT_ID"
# write a new boot id and begin the boot
begin_new_boot() { cat /proc/sys/kernel/random/uuid > "$BOOT_ID"; cmd_begin_boot; }
# shellcheck source=src/install/update/gsi-update.sh
RHIZO_GSI_UPDATE_SOURCE_ONLY=1 source "$SCRIPT"

# report the sandbox as not running
sandbox_running() { return 1; }

A16_TREE=$(release_tree a16)
A17_TREE=$(release_tree a17)

# print a key's last value from the runtime state file
env_val() {
  sed -n "s/^$1=//p" "$RUNTIME_FILE" | tail -1
}

out=$(cmd_status 2>/dev/null)
check "status with no state and no meta reports a16" "$(tail -1 <<<"$out")" \
      "RHIZO_GSI_UPDATE current=a16 candidate=- tries=- previous=-"

printf 'release=a17\nvariant=user\ntemplate=\n' > "$DATA_IMG_PATH.meta"
out=$(cmd_status 2>/dev/null)
check "status with no state file reads current from data.img.meta" \
      "$(tail -1 <<<"$out")" \
      "RHIZO_GSI_UPDATE current=a17 candidate=- tries=- previous=-"
rm -f "$DATA_IMG_PATH.meta"

out=$(cmd_update --release a16 2>/dev/null)
check "update --release equal to current refuses already-current" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=already-current"

out=$(cmd_update --release bogus 2>/dev/null)
check "update on an unknown release refuses unknown-release" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=unknown-release"

out=$(cmd_update --release a17 --tries 0 2>/dev/null)
check "update --tries 0 refuses bad-tries" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=bad-tries"

out=$(cmd_update --release a17 --tries x 2>/dev/null)
check "update --tries x refuses bad-tries" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=bad-tries"

check "none of the refusals above wrote a state file" \
      "$([[ -f "$STATE" ]] && echo present || echo absent)" absent

KFETCH_LOG="$TMP/kernel-fetch.log"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$KFETCH_LOG" > "$TMP/fetch-kernel-record.sh"
chmod +x "$TMP/fetch-kernel-record.sh"
_fetch_ok="$FETCH_SH"
FETCH_SH="$TMP/fetch-kernel-record.sh"
KALLSYMS="$KALLSYMS_STOCK"
out=$(cmd_update --release a17 2>&1)
check "update --release a17 on a kernel without the patches' functions refuses kernel-unsupported" \
      "$(tail -1 <<<"$out")" "RHIZO_GSI_UPDATE_REFUSED reason=kernel-unsupported"
check "the refusal names both missing functions" \
      "$(grep -c 'bpf_get_current_pid_tgid_vnr bpf_get_netns_cookie_sock_create' <<<"$out")" 1
check "the refusal comes before any fetch" "$([[ -s "$KFETCH_LOG" ]] && echo fetched || echo none)" none
grep -v bpf_get_netns_cookie_sock_create "$KALLSYMS_PATCHED" > "$TMP/kallsyms-half"
KALLSYMS="$TMP/kallsyms-half"
out=$(cmd_update --release a17 2>/dev/null)
check "a kernel carrying only one of the two functions refuses too" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=kernel-unsupported"
KALLSYMS="$TMP/no-such-kallsyms"
out=$(cmd_update --release a17 2>/dev/null)
check "an unreadable symbol table refuses rather than guessing" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=kernel-unsupported"
KALLSYMS="$KALLSYMS_STOCK"
check "kernel-check passes a15 on a stock kernel" \
      "$(cmd_kernel_check --release a15 2>/dev/null)" "RHIZO_GSI_KERNEL_OK release=a15"
check "kernel-check refuses a17 on a stock kernel" \
      "$(cmd_kernel_check --release a17 2>/dev/null)" "RHIZO_GSI_UPDATE_REFUSED reason=kernel-unsupported"
check "kernel-check refuses an unknown release" \
      "$(cmd_kernel_check --release a99 2>/dev/null)" "RHIZO_GSI_UPDATE_REFUSED reason=unknown-release"
KALLSYMS="$KALLSYMS_PATCHED"
check "kernel-check passes a17 on a kernel carrying both functions" \
      "$(cmd_kernel_check --release a17 2>/dev/null)" "RHIZO_GSI_KERNEL_OK release=a17"
check "no kernel refusal wrote a state file" \
      "$([[ -f "$STATE" ]] && echo present || echo absent)" absent
FETCH_SH="$_fetch_ok"

out=$(cmd_update --release a17 2>/dev/null)
check "update --release a17 prints the armed trial's final line" \
      "$(tail -1 <<<"$out")" \
      "RHIZO_GSI_UPDATE current=a16 candidate=a17 tries=3 previous=-"
check "the armed state carries good_release=a16" "$(state_get good_release)" a16
check "the armed state carries trial_release=a17" "$(state_get trial_release)" a17
check "the armed state carries trial_tries=3" "$(state_get trial_tries)" 3
check "arming a trial copies data.img to trial-data.img" \
      "$([[ -s "$TRIAL_IMG" ]] && echo present || echo absent)" present
check "the update runs no prepare at all" \
      "$([[ -e "$PREPARE_RECORD" ]] && echo ran || echo skipped)" skipped
check "the trial's own meta sidecar carries the new release" \
      "$(sed -n 's/^release=//p' "$TRIAL_IMG.meta" | tail -1)" a17

out=$(cmd_update --release a15 2>/dev/null)
check "a second update while one is armed refuses trial-in-flight" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=trial-in-flight"

begin_new_boot >/dev/null 2>&1
check "begin-boot call 1 leaves 2 tries" "$(state_get trial_tries)" 2
check "begin-boot call 1 points RHIZO_GSI at the a17 tree" "$(env_val RHIZO_GSI)" "$A17_TREE"
check "begin-boot call 1 points RHIZO_DATA_IMG at the trial image" \
      "$(env_val RHIZO_DATA_IMG)" "$TRIAL_IMG"
check "begin-boot call 1 sets RHIZO_RELEASE=a17" "$(env_val RHIZO_RELEASE)" a17

out=$(cmd_begin_boot 2>&1)
check "a second begin-boot in the same boot spends no try" "$(state_get trial_tries)" 2
check "it keeps the launch env on the trial the boot loaded" "$(env_val RHIZO_RELEASE)" a17
check "it keeps the trial's own /data" "$(env_val RHIZO_DATA_IMG)" "$TRIAL_IMG"
check "it says the boot's try was already spent" \
      "$(grep -c 'RHIZO_MARKER gsi_update_try_this_boot=a17 left=2' <<<"$out")" 1

begin_new_boot >/dev/null 2>&1
check "begin-boot call 2 leaves 1 try" "$(state_get trial_tries)" 1

begin_new_boot >/dev/null 2>&1
check "begin-boot call 3 leaves 0 tries" "$(state_get trial_tries)" 0
check "the trial is still armed with 0 tries" "$(state_get trial_release)" a17
cmd_begin_boot >/dev/null 2>&1
check "a start later in the boot that spent the last try still runs the trial" "$(env_val RHIZO_RELEASE)" a17
check "and leaves it armed until the next boot" "$(state_get trial_release)" a17
printf '' > "$BOOT_ID"
out=$(cmd_begin_boot 2>/dev/null)
check "an unreadable boot id fails rather than spending blind" "$out" "RHIZO_GSI_UPDATE_FAILED reason=boot-id"

out=$(begin_new_boot 2>&1)
check "begin-boot with no tries left drops the trial fields" \
      "$(state_get trial_release || echo none)" none
check "begin-boot with no tries left keeps good_release=a16" \
      "$(state_get good_release)" a16
check "begin-boot with no tries left deletes trial-data.img" \
      "$([[ -e "$TRIAL_IMG" ]] && echo present || echo absent)" absent
check "begin-boot with no tries left points RHIZO_GSI back at a16" \
      "$(env_val RHIZO_GSI)" "$A16_TREE"
check "begin-boot with no tries left leaves no RHIZO_DATA_IMG line" \
      "$(env_val RHIZO_DATA_IMG)" ""
check "the rollback carries its own marker" \
      "$(grep -c 'RHIZO_MARKER gsi_update_rolled_back=a17-to-a16' <<<"$out")" 1

out=$(cmd_rollback 2>/dev/null)
check "rollback with no previous release refuses no-previous" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=no-previous"

cmd_update --release a17 >/dev/null 2>&1
out=$(cmd_abort 2>/dev/null)
check "abort's final line shows no candidate" "$(tail -1 <<<"$out")" \
      "RHIZO_GSI_UPDATE current=a16 candidate=- tries=- previous=-"
check "abort leaves good_release untouched" "$(state_get good_release)" a16
check "abort drops trial_release" "$(state_get trial_release || echo none)" none
check "abort deletes trial-data.img" \
      "$([[ -e "$TRIAL_IMG" ]] && echo present || echo absent)" absent
check "abort points RHIZO_GSI back at a16" "$(env_val RHIZO_GSI)" "$A16_TREE"

cmd_update --release a17 >/dev/null 2>&1
begin_new_boot >/dev/null 2>&1
printf '%s' "NEW_DATA_BYTES_A17" > "$TRIAL_IMG"
printf 0 > "$AWAIT_RESULT"
out=$(cmd_confirm 2>/dev/null)
check "confirm after a good boot promotes to a17" "$(tail -1 <<<"$out")" \
      "RHIZO_GSI_UPDATE current=a17 candidate=- tries=- previous=a16"
check "confirm records previous_release=a16" "$(state_get previous_release)" a16
check "confirm keeps the old data.img as previous-data.img" \
      "$(cat "$PREVIOUS_IMG")" "OLD_DATA_BYTES_A16"
check "confirm moves the trial's data.img into place" \
      "$(cat "$DATA_IMG")" "NEW_DATA_BYTES_A17"
check "confirm updates data.img.meta to the new release" \
      "$(sed -n 's/^release=//p' "$DATA_IMG.meta" | tail -1)" a17

out=$(cmd_rollback 2>/dev/null)
check "rollback after a promotion restores good_release=a16" \
      "$(tail -1 <<<"$out")" \
      "RHIZO_GSI_UPDATE current=a16 candidate=- tries=- previous=-"
check "rollback restores the old data.img content" \
      "$(cat "$DATA_IMG")" "OLD_DATA_BYTES_A16"
check "rollback removes previous-data.img" \
      "$([[ -e "$PREVIOUS_IMG" ]] && echo present || echo absent)" absent

cmd_update --release a17 --tries 7 >/dev/null 2>&1
begin_new_boot >/dev/null 2>&1
printf 1 > "$AWAIT_RESULT"
out=$(cmd_confirm 2>/dev/null)
check "confirm output after a failed boot is empty (nothing to promote)" \
      "$out" ""
check "a failed confirm leaves good_release alone" "$(state_get good_release)" a16
check "a failed confirm leaves the trial armed" "$(state_get trial_release)" a17
check "a failed confirm leaves the try its boot spent and no more" "$(state_get trial_tries)" 6
check "a failed confirm does not touch data.img" "$(cat "$DATA_IMG")" "OLD_DATA_BYTES_A16"

cat /proc/sys/kernel/random/uuid > "$BOOT_ID"
printf 0 > "$AWAIT_RESULT"
out=$(cmd_confirm 2>&1)
check "confirm on a boot that did not run the trial promotes nothing" "$(state_get good_release)" a16
check "that confirm leaves the trial armed" "$(state_get trial_release)" a17
check "that confirm leaves its tries alone" "$(state_get trial_tries)" 6
check "that confirm does not touch data.img" "$(cat "$DATA_IMG")" "OLD_DATA_BYTES_A16"
check "that confirm prints no promotion marker" "$(grep -c 'gsi_update_good=' <<<"$out")" 0
check "that confirm says the boot ran no trial" \
      "$(grep -c 'RHIZO_MARKER gsi_update_confirm_not_trial_boot=a17' <<<"$out")" 1
_trial_boot=$(state_get trial_boot)
state_write "good_release=a16" "trial_release=a17" "trial_tries=6"
printf '' > "$BOOT_ID"
out=$(cmd_confirm 2>&1)
check "confirm with no trial_boot and no readable boot id promotes nothing" "$(state_get good_release)" a16
check "and leaves the trial armed" "$(state_get trial_release)" a17
state_write "good_release=a16" "trial_release=a17" "trial_tries=6" "trial_boot=$_trial_boot"
printf '%s' "$_trial_boot" > "$BOOT_ID"
printf 'printf "good_release=a16\\n" > "%s"; rm -f "%s"\n' "$STATE" "$TRIAL_IMG" > "$AWAIT_HOOK"
printf 0 > "$AWAIT_RESULT"
out=$(cmd_confirm 2>&1)
check "the planted abort ran during the wait" "$([[ -e "$AWAIT_HOOK" ]] && echo pending || echo ran)" ran
check "confirm after an abort during its wait promotes nothing" "$(state_get good_release)" a16
check "and keeps data.img in place" "$(cat "$DATA_IMG")" "OLD_DATA_BYTES_A16"
check "and sets no rollback /data aside" \
      "$([[ -e "$PREVIOUS_IMG" ]] && echo present || echo absent)" absent
state_write "good_release=a16" "trial_release=a17" "trial_tries=6" "trial_boot=$_trial_boot"
printf 'TRIAL' > "$TRIAL_IMG"

out=$(cmd_rollback 2>/dev/null)
check "rollback while a trial is armed refuses trial-in-flight" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=trial-in-flight"

cmd_abort >/dev/null 2>&1

cmd_update --release a17 >/dev/null 2>&1
KALLSYMS="$KALLSYMS_STOCK"
out=$(begin_new_boot 2>&1)
KALLSYMS="$KALLSYMS_PATCHED"
check "begin-boot on a kernel that cannot run the trial drops it" \
      "$(state_get trial_release || echo none)" none
check "that begin-boot keeps good_release=a16" "$(state_get good_release)" a16
check "that begin-boot starts the good release" "$(env_val RHIZO_RELEASE)" a16
check "that begin-boot deletes trial-data.img" \
      "$([[ -e "$TRIAL_IMG" ]] && echo present || echo absent)" absent
check "that begin-boot carries its own marker" \
      "$(grep -c 'RHIZO_MARKER gsi_update_kernel_unsupported=a17' <<<"$out")" 1

printf 'release=a15\nvariant=user\nwipe_data=1\n' > "$PREPARE_REQUEST"
out=$(cmd_update --release a17 2>/dev/null)
check "update while a deferred prepare waits refuses prepare-pending" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=prepare-pending"
state_write "good_release=a16" "trial_release=a17" "trial_tries=3"
printf 'RHIZO_RELEASE=a16\n' > "$RUNTIME_FILE"
out=$(begin_new_boot 2>&1)
check "begin-boot while a deferred prepare waits spends no try" "$(state_get trial_tries)" 3
check "begin-boot while a deferred prepare waits leaves the launch env alone" "$(env_val RHIZO_RELEASE)" a16
check "begin-boot while a deferred prepare waits names it" "$(grep -c 'a prepare of a15 is pending' <<<"$out")" 1
out=$(cmd_adopt --release a15 2>/dev/null)
check "adopt while a trial is armed refuses trial-in-flight" "$out" \
      "RHIZO_GSI_UPDATE_REFUSED reason=trial-in-flight"
rm -f "$PREPARE_REQUEST"
state_write "good_release=a16" "previous_release=a17"
printf 'A17_DATA' > "$PREVIOUS_IMG"; printf 'release=a17\n' > "$PREVIOUS_IMG.meta"
out=$(cmd_adopt --release a15 2>/dev/null)
check "adopt makes the prepared release current, with no rollback" "$out" \
      "RHIZO_GSI_UPDATE current=a15 candidate=- tries=- previous=-"
check "adopt drops another release's rollback /data" \
      "$([[ -e "$PREVIOUS_IMG" || -e "$PREVIOUS_IMG.meta" ]] && echo present || echo absent)" absent
state_write "good_release=a15" "previous_release=a16"
printf 'A16_DATA' > "$PREVIOUS_IMG"
out=$(cmd_adopt --release a15 2>/dev/null)
check "adopt of the release already current changes nothing" "$out" \
      "RHIZO_GSI_UPDATE current=a15 candidate=- tries=- previous=a16"
check "adopt of the release already current keeps its rollback /data" "$(cat "$PREVIOUS_IMG")" A16_DATA
rm -f "$PREVIOUS_IMG"
state_write "good_release=a16"
: > "$RUNTIME_FILE"

state_write "good_release=a16"
check "state_write leaves no .tmp behind after a normal write" \
      "$([[ -e "$STATE.tmp" ]] && echo present || echo absent)" absent
echo "not a key=value line, just garbage" > "$STATE.tmp"
check "state_get reads the real state file, ignoring a garbage .tmp beside it" \
      "$(state_get good_release)" a16
rm -f "$STATE.tmp"

cat > "$RUNTIME_FILE" <<'EOF'
RHIZO_PERMISSIVE=1
RHIZO_GSI=/some/old/path
RHIZO_WIPE_DATA=1
EOF
begin_new_boot >/dev/null 2>&1
check "the merge keeps an unrelated line" "$(env_val RHIZO_PERMISSIVE)" 1
check "a leftover wipe from the last deploy is overwritten, not carried" \
      "$(env_val RHIZO_WIPE_DATA)" 0
check "the merge leaves exactly one RHIZO_GSI= line" \
      "$(grep -c '^RHIZO_GSI=' "$RUNTIME_FILE")" 1

printf 'release=a16\nvariant=userdebug\ntemplate=t1\n' > "$DATA_IMG.meta"
cmd_update --release a17 >/dev/null 2>&1
check "the trial meta seeds variant from the live data.img.meta" \
      "$(sed -n 's/^variant=//p' "$TRIAL_IMG.meta" | tail -1)" userdebug
begin_new_boot >/dev/null 2>&1
printf 0 > "$AWAIT_RESULT"
cmd_confirm >/dev/null 2>&1
check "variant=userdebug survives an update-then-confirm round trip" \
      "$(sed -n 's/^variant=//p' "$DATA_IMG.meta" | tail -1)" userdebug
check "the promoted data.img.meta also carries the new release" \
      "$(sed -n 's/^release=//p' "$DATA_IMG.meta" | tail -1)" a17

printf '#!/bin/bash\nexit 1\n' > "$TMP/fetch-fail.sh"; chmod +x "$TMP/fetch-fail.sh"
_fetch_ok="$FETCH_SH"
FETCH_SH="$TMP/fetch-fail.sh"
out=$(cmd_update --release a16 2>/dev/null)
FETCH_SH="$_fetch_ok"
check "update refuses when the fetch fails" "$out" "RHIZO_GSI_UPDATE_FAILED reason=fetch"
check "a failed fetch leaves no trial image" \
      "$([[ -e "$TRIAL_IMG" ]] && echo present || echo absent)" absent
check "a failed fetch arms no trial in the state file" \
      "$(state_get trial_release || echo none)" none

rm -f "$STATE"
printf 'release=a17\nvariant=user\n' > "$DATA_IMG.meta"
printf 'RHIZO_RELEASE=a15\n' > "$RUNTIME_FILE"
check "with no state, the current release is what androidd.env last booted" \
      "$(current_release_guess)" a15
check "status reports that release too" \
      "$(cmd_status 2>/dev/null | tail -1)" \
      "RHIZO_GSI_UPDATE current=a15 candidate=- tries=- previous=-"
: > "$RUNTIME_FILE"
check "with no env release, it falls to the data.img sidecar" \
      "$(current_release_guess)" a17
rm -f "$DATA_IMG.meta"
check "with neither, it answers a16" "$(current_release_guess)" a16
state_write "good_release=a17"

( cmd_update --release a16 ) >/dev/null 2>&1
( begin_new_boot ) >/dev/null 2>&1
check "a trial start declares the release change to the launcher" \
      "$(env_val RHIZO_DATA_RELEASE_CHANGE)" 1
check "a trial start never wipes the /data it exists to carry" \
      "$(env_val RHIZO_WIPE_DATA)" 0
( cmd_abort ) >/dev/null 2>&1
check "the declaration is gone once no trial is armed" \
      "$(grep -c '^RHIZO_DATA_RELEASE_CHANGE=' "$RUNTIME_FILE")" 0

FETCH_LOG="$TMP/fetch-args.log"
cat > "$TMP/fetch-record.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$FETCH_LOG"
[[ " \$* " == *" --fetch-only "* ]] && { echo "RHIZO_GSI_FETCHED release=a15 sha256=x"; exit 0; }
[[ " \$* " == *" --derive-only "* ]] && { echo "RHIZO_GSI_DERIVED release=\$2 dir=x"; exit 0; }
mkdir -p "$GSI_ROOT/gsi_system_a15/bin" && echo init > "$GSI_ROOT/gsi_system_a15/bin/init"
EOF
chmod +x "$TMP/fetch-record.sh"
rm -rf "$GSI_ROOT/gsi_system_a15"
: > "$FETCH_LOG"
_fetch_ok="$FETCH_SH"
FETCH_SH="$TMP/fetch-record.sh"
printf 'u:r:rhizo_host:s0' > "$ATTR_CURRENT"
out=$(cmd_update --release a15 2>/dev/null)
check "update under a loaded policy still arms the trial" "$(tail -1 <<<"$out")" \
      "RHIZO_GSI_UPDATE current=a17 candidate=a15 tries=3 previous=-"
check "update under a loaded policy only fetches, never stages" "$(cat "$FETCH_LOG")" \
      "--release a15 --fetch-only"
check "update under a loaded policy leaves the a15 tree unstaged" \
      "$([[ -e "$GSI_ROOT/gsi_system_a15/bin/init" ]] && echo present || echo absent)" absent

out=$(begin_new_boot 2>&1)
check "begin-boot under a loaded policy spends no try" "$(state_get trial_tries)" 3
check "begin-boot under a loaded policy starts the good release" "$(env_val RHIZO_RELEASE)" a17
check "begin-boot under a loaded policy says the trial waits for a reboot" \
      "$(grep -c 'RHIZO_MARKER gsi_update_stage_waiting=a15' <<<"$out")" 1
check "begin-boot under a loaded policy never tries to stage" \
      "$(grep -c -- '--release a15' "$FETCH_LOG")" 1
check "begin-boot under a loaded policy derives the good release's own libraries" \
      "$(tail -1 "$FETCH_LOG")" "--release a17 --derive-only"
printf 0 > "$AWAIT_RESULT"
out=$(cmd_confirm 2>&1)
check "confirm after a stage-waiting boot keeps good_release=a17" "$(state_get good_release)" a17
check "confirm after a stage-waiting boot leaves the a15 trial armed" "$(state_get trial_release)" a15
check "confirm after a stage-waiting boot leaves its tries alone" "$(state_get trial_tries)" 3
check "confirm after a stage-waiting boot keeps the trial's own /data" \
      "$([[ -e "$TRIAL_IMG" ]] && echo present || echo absent)" present
check "confirm after a stage-waiting boot records no rollback release" \
      "$(state_get previous_release || echo none)" none
check "confirm after a stage-waiting boot prints no promotion marker" \
      "$(grep -c 'gsi_update_good=' <<<"$out")" 0

printf 'kernel' > "$ATTR_CURRENT"
: > "$FETCH_LOG"
begin_new_boot >/dev/null 2>&1
check "begin-boot before the load stages offline from the verified zip, then derives the trial's libraries" \
      "$(tr '\n' ' ' < "$FETCH_LOG")" "--release a15 --offline --release a15 --derive-only "
check "begin-boot before the load leaves the a15 tree staged" \
      "$([[ -s "$GSI_ROOT/gsi_system_a15/bin/init" ]] && echo present || echo absent)" present
check "begin-boot spends the try once the tree is staged" "$(state_get trial_tries)" 2
check "begin-boot then points RHIZO_GSI at the a15 tree" \
      "$(env_val RHIZO_GSI)" "$(release_tree a15)"
( cmd_abort ) >/dev/null 2>&1

rm -rf "$GSI_ROOT/gsi_system_a15"
printf 'u:r:rhizo_host:s0' > "$ATTR_CURRENT"
( cmd_update --release a15 ) >/dev/null 2>&1
printf 'kernel' > "$ATTR_CURRENT"
FETCH_SH="$TMP/fetch-fail.sh"
out=$(begin_new_boot 2>&1)
FETCH_SH="$_fetch_ok"
check "a failed boot-time stage drops the trial" "$(state_get trial_release || echo none)" none
check "a failed boot-time stage keeps good_release=a17" "$(state_get good_release)" a17
check "a failed boot-time stage deletes trial-data.img" \
      "$([[ -e "$TRIAL_IMG" ]] && echo present || echo absent)" absent
check "a failed boot-time stage starts the good release" "$(env_val RHIZO_RELEASE)" a17
check "a failed boot-time stage carries its own marker" \
      "$(grep -c 'RHIZO_MARKER gsi_update_stage_failed=a15' <<<"$out")" 1

: > "$FETCH_LOG"
FETCH_SH="$TMP/fetch-record.sh"
out=$(cmd_update --release a15 2>/dev/null)
FETCH_SH="$_fetch_ok"
check "update with no policy loaded stages the tree itself" "$(cat "$FETCH_LOG")" "--release a15"
check "update with no policy loaded leaves the tree staged" \
      "$([[ -s "$GSI_ROOT/gsi_system_a15/bin/init" ]] && echo present || echo absent)" present
( cmd_abort ) >/dev/null 2>&1

rm -rf "$GSI_ROOT/gsi_system_a15"
: > "$FETCH_LOG"
FETCH_SH="$TMP/fetch-record.sh"
printf 'system_u:system_r:initrc_t:s0' > "$ATTR_CURRENT"
out=$(RHIZO_SELINUX_MODE=namespace cmd_update --release a15 2>/dev/null)
check "update in namespace mode under the host's own policy stages the tree itself" "$(cat "$FETCH_LOG")" \
      "--release a15"
rm -rf "$GSI_ROOT/gsi_system_a15"
: > "$FETCH_LOG"
out=$(RHIZO_SELINUX_MODE=namespace begin_new_boot 2>&1)
check "begin-boot in namespace mode under the host's own policy stages offline" "$(head -1 "$FETCH_LOG")" \
      "--release a15 --offline"
check "begin-boot in namespace mode under the host's own policy does not wait for a reboot" \
      "$(grep -c 'gsi_update_stage_waiting' <<<"$out")" 0
( cmd_abort ) >/dev/null 2>&1
printf 'kernel' > "$ATTR_CURRENT"
FETCH_SH="$_fetch_ok"

cat > "$TMP/fetch-derive.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$FETCH_LOG"
if [[ " \$* " == *" --derive-only "* ]]; then
  [[ -n "\${DERIVE_FAIL:-}" && "\$2" == "\$DERIVE_FAIL" ]] && { echo "RHIZO_GSI_FAILED reason=gsi-libs-missing"; exit 1; }
  echo "RHIZO_GSI_DERIVED release=\$2 dir=x"
fi
exit 0
EOF
chmod +x "$TMP/fetch-derive.sh"
FETCH_SH="$TMP/fetch-derive.sh"

( cmd_update --release a15 ) >/dev/null 2>&1
: > "$FETCH_LOG"
begin_new_boot >/dev/null 2>&1
check "a trial start derives the candidate's own libraries before its boot" \
      "$(cat "$FETCH_LOG")" "--release a15 --derive-only"
check "the try is spent once the candidate has its libraries" "$(state_get trial_tries)" 2
: > "$FETCH_LOG"
( cmd_abort ) >/dev/null 2>&1
check "abort derives the good release's libraries for the start it points back at" \
      "$(cat "$FETCH_LOG")" "--release a17 --derive-only"

( cmd_update --release a15 ) >/dev/null 2>&1
: > "$FETCH_LOG"
export DERIVE_FAIL=a15
out=$(begin_new_boot 2>&1)
check "a trial whose libraries cannot be derived is dropped" "$(state_get trial_release || echo none)" none
check "a trial whose libraries cannot be derived keeps good_release=a17" "$(state_get good_release)" a17
check "a trial whose libraries cannot be derived deletes trial-data.img" \
      "$([[ -e "$TRIAL_IMG" ]] && echo present || echo absent)" absent
check "a trial whose libraries cannot be derived starts the good release" "$(env_val RHIZO_RELEASE)" a17
check "a trial whose libraries cannot be derived carries its own marker" \
      "$(grep -c 'RHIZO_MARKER gsi_update_libs_failed=a15' <<<"$out")" 1
check "the fallback start derives the good release's libraries" \
      "$(tail -1 "$FETCH_LOG")" "--release a17 --derive-only"
unset DERIVE_FAIL

( cmd_update --release a15 ) >/dev/null 2>&1
( begin_new_boot ) >/dev/null 2>&1
printf 0 > "$AWAIT_RESULT"
( cmd_confirm ) >/dev/null 2>&1
export DERIVE_FAIL=a17
out=$(cmd_rollback 2>/dev/null)
check "a rollback whose release cannot get its libraries fails by name" "$out" \
      "RHIZO_GSI_UPDATE_FAILED reason=gsi-libs"
check "that rollback leaves good_release=a15" "$(state_get good_release)" a15
check "that rollback keeps previous-data.img" \
      "$([[ -s "$PREVIOUS_IMG" ]] && echo present || echo absent)" present
unset DERIVE_FAIL
: > "$FETCH_LOG"
out=$(cmd_rollback 2>/dev/null)
check "a rollback derives the previous release's libraries" "$(cat "$FETCH_LOG")" "--release a17 --derive-only"
check "that rollback lands on a17" "$(tail -1 <<<"$out")" \
      "RHIZO_GSI_UPDATE current=a17 candidate=- tries=- previous=-"
FETCH_SH="$_fetch_ok"

echo "$FAILED checks failed"
[[ $FAILED -eq 0 ]]
