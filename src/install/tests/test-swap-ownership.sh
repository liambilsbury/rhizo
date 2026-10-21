#!/bin/bash
# test swap setup and removal offline
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOOT="$HERE/../bootstrap/bootstrap.sh"
LIB="$HERE/../teardown/teardown-lib.sh"
TEARDOWN="$HERE/../teardown/teardown.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0
QUIET=0

# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then
    (( QUIET )) || echo "ok   $1"
  else
    (( QUIET )) || { echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; }
    FAILED=$((FAILED + 1))
  fi
}

# print a function's definition from a file
lift() {
  awk -v f="$1" '$0 ~ "^" f "\\(\\) *\\{" { on = 1; print; if ($0 ~ /\} *$/) exit; next }
                 on { print } on && /^}/ { exit }' "$2"
}

BOOT_FNS=(swapfile_fstab_entries swapfile_id record_has record_add swapfile_is_ours adopt_legacy_swap append_swap_fstab_line provision_swap)
BOOT_TEXT=""
for f in "${BOOT_FNS[@]}"; do
  body=$(lift "$f" "$BOOT")
  [[ -n "$body" ]] || { echo "FAIL no $f() in $BOOT"; exit 1; }
  BOOT_TEXT+="$body"$'\n'
done
LINE_DEF=$(grep -m1 '^SWAP_FSTAB_LINE=' "$BOOT")
[[ -n "$LINE_DEF" ]] || { echo "FAIL no SWAP_FSTAB_LINE= in $BOOT"; exit 1; }
LIB_TEXT=$(cat "$LIB")

SWAPFILE=/swapfile
eval "$LINE_DEF"
check "the teardown's SWAP_FSTAB_LINE is the bootstrap's" \
  "$(sed -n 's/^SWAP_FSTAB_LINE="\(.*\)"$/\1/p' "$TEARDOWN")" "$SWAP_FSTAB_LINE"

# create a scratch host and set its globals
host() {
  H="$TMP/$1"
  rm -rf "$H"; mkdir -p "$H/state"
  SWAPFILE="$H/swapfile" FSTAB="$H/fstab" PROC_SWAPS="$H/proc_swaps"
  INSTALL_RECORD="$H/state/.created-by-install" UPGRADE_FROM="$H/state/.upgrade-from"
  MEMINFO="$H/meminfo" FLAVOR=ubuntu ROOT_FSTYPE=ext2/ext3
  eval "$LINE_DEF"
  : > "$FSTAB"
  echo 'SwapTotal:       1020 kB' > "$MEMINFO"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n' > "$PROC_SWAPS"
  CALLS="$H/calls"; : > "$CALLS"
}
# write a 1MB swap area to SWAPFILE
make_swapfile() {
  head -c 1048576 /dev/zero > "$SWAPFILE"; chmod 600 "$SWAPFILE"
  mkswap ${1:+-L "$1"} "$SWAPFILE" >/dev/null 2>&1
}
# print the swapfile's device, inode and swap UUID
ident() { printf '%s:%s' "$(stat -c '%d:%i' "$SWAPFILE" 2>/dev/null)" "$(blkid -o value -s UUID "$SWAPFILE" 2>/dev/null)"; }
# print the number of swapfile tokens in the install record
tokens() { local n; n=$(grep -c '^swapfile' "$INSTALL_RECORD" 2>/dev/null); echo "${n:-0}"; }

# log its arguments
log() { echo "log $*" >> "$CALLS"; }
# log its arguments
swapon() { echo "swapon $*" >> "$CALLS"; }
# log its arguments and fail when SWAPOFF_FAILS is set
swapoff() { echo "swapoff $*" >> "$CALLS"; [[ -z "${SWAPOFF_FAILS:-}" ]]; }
# print a fixed disk free listing
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 99999999 1 99999999 1%% /\n'; }
# print the stub root filesystem type
root_fstype() { echo "$ROOT_FSTYPE"; }
# log its arguments and run the real dpkg
dpkg() { echo "dpkg $*" >> "$CALLS"; command dpkg "$@"; }
# write a 1MB file of zeros
fallocate() { head -c 1048576 /dev/zero > "${!#}"; }
# print yes when a logged call starts with the text
called() { grep -q "^$1" "$CALLS" && echo yes || echo no; }

# run the bootstrap swap provisioning and log its output
run_boot() { ( eval "$BOOT_TEXT"; provision_swap ) >> "$CALLS" 2>&1; }

# check swap provisioning on a host with no swapfile yet
scenario_new_host() {
  host new; run_boot
  local id; id=$(ident)
  check "new host: the bootstrap makes /swapfile" "$([[ -f $SWAPFILE ]] && echo yes)" yes
  check "new host: it records the file by device, inode and swap UUID" \
    "$(grep -c "^swapfile:$id\$" "$INSTALL_RECORD")" 1
  check "new host: it records the fstab line" "$(grep -cx swapfile-fstab "$INSTALL_RECORD")" 1
  check "new host: it appends the line once" "$(grep -cxF "$SWAP_FSTAB_LINE" "$FSTAB")" 1
  check "new host: it swaps on" "$(called swapon)" yes
  run_boot
  check "rerun: no second fstab line" "$(grep -cxF "$SWAP_FSTAB_LINE" "$FSTAB")" 1
  check "rerun: no second token" "$(tokens)" 2
  check "rerun: the same file" "$(ident)" "$id"
}

# run the bootstrap on a swapfile in fstab
scenario_user() {
  host "$1"; make_swapfile "${3:-}"
  local id fstab_before
  id=$(ident)
  local text="${2//SWAP/$SWAPFILE}"
  printf '%s\n' "${text//UUID_OF/$(blkid -o value -s UUID "$SWAPFILE")}" > "$FSTAB"
  fstab_before=$(cat "$FSTAB")
  run_boot
  check "$1: the user's swapfile is the same file" "$(ident)" "$id"
  check "$1: /etc/fstab is unchanged" "$(cat "$FSTAB")" "$fstab_before"
  check "$1: nothing is recorded as the bootstrap's" "$(tokens)" 0
  check "$1: the user's swapfile is not switched on" "$(called swapon)" no
}

# check swap provisioning with an fstab entry and no file
scenario_entry_no_file() {
  host entry-no-file
  printf '%s\tnone\tswap\tsw\t0\t0\n' "$SWAPFILE" > "$FSTAB"
  local before; before=$(cat "$FSTAB")
  run_boot
  check "an fstab entry with no file: nothing is made" "$([[ -e $SWAPFILE ]] && echo made || echo none)" none
  check "an fstab entry with no file: /etc/fstab is unchanged" "$(cat "$FSTAB")" "$before"
}

# check swap provisioning with swap already on
scenario_active() {
  host active
  printf '/dev/sda2 partition 1000 0 -2\n' >> "$PROC_SWAPS"
  run_boot
  check "swap already on: nothing is made" "$([[ -e $SWAPFILE ]] && echo made || echo none)" none
}

# run the bootstrap on an upgraded install
scenario_legacy() {
  host "$1"; make_swapfile
  FLAVOR=${5:-ubuntu}
  [[ -n "$3" ]] && printf '%s\n' "${3//SWAP/$SWAPFILE}" > "$FSTAB"
  echo "$SWAP_FSTAB_LINE" >> "$FSTAB"
  echo "$2" > "$UPGRADE_FROM"
  printf '/dev/sda2 partition 1000 0 -2\n' >> "$PROC_SWAPS"
  run_boot
  check "$1: recorded tokens" "$(LC_ALL=C sort "$INSTALL_RECORD" 2>/dev/null | sed "s/^swapfile:.*/swapfile:<id>/" | tr '\n' ' ')" "$4"
  check "$1: asks dpkg only on ubuntu" "$(called dpkg)" "$([[ "$FLAVOR" == ubuntu ]] && echo yes || echo no)"
}

# run the bootstrap on a given root filesystem
scenario_root_fs() {
  local want=$4
  host "$1"; ROOT_FSTYPE=$2 FLAVOR=$3; run_boot
  check "$1: a swapfile is $want" "$([[ -e $SWAPFILE ]] && echo made || echo none)" "$want"
  check "$1: swapon runs only with a file" "$(called swapon)" "$([[ $want == made ]] && echo yes || echo no)"
  check "$1: recorded tokens" "$(tokens)" "$([[ $want == made ]] && echo 2 || echo 0)"
  check "$1: /etc/fstab line written only with a file" "$(grep -cxF "$SWAP_FSTAB_LINE" "$FSTAB")" "$([[ $want == made ]] && echo 1 || echo 0)"
  check "$1: the log names btrfs only when it skips" "$(grep -c 'no swap is active and / is btrfs' "$CALLS")" "$([[ $want == none ]] && echo 1 || echo 0)"
}

# run the swap teardown on the fixture files
teardown() { ( eval "$LIB_TEXT"; teardown_swap "$INSTALL_RECORD" "$SWAPFILE" "$SWAP_FSTAB_LINE" "$FSTAB" "$PROC_SWAPS" ); }

# check the teardown of a swapfile this install made
scenario_teardown_ours() {
  host td-ours; run_boot
  printf '%s file 1020 0 -2\n' "$SWAPFILE" >> "$PROC_SWAPS"
  local out; out=$(teardown)
  check "teardown of its own: the file goes" "$([[ -e $SWAPFILE ]] && echo kept || echo gone)" gone
  check "teardown of its own: it swaps off first" "$(called swapoff)" yes
  check "teardown of its own: the line goes" "$(grep -cxF "$SWAP_FSTAB_LINE" "$FSTAB")" 0
  check "teardown of its own: it says so" "$(tr '\n' ' ' <<<"$out")" "removed-fstab removed-file "
  check "teardown of its own: the record holds no swap token" "$(tokens)" 0
}

# check the teardown of a user's swapfile
scenario_teardown_user() {
  host td-user; make_swapfile
  local id; id=$(ident)
  printf '%s\tnone\tswap\tsw\t0\t0\n' "$SWAPFILE" > "$FSTAB"
  echo "$SWAP_FSTAB_LINE" >> "$FSTAB"
  local out; out=$(teardown)
  check "teardown with no record: the user's swapfile stays" "$(ident)" "$id"
  check "teardown with no record: no fstab line goes" "$(wc -l < "$FSTAB")" 2
  check "teardown with no record: it says the file is kept" "$out" kept-file
}

# check the teardown of a swapfile replaced after install
scenario_teardown_replaced() {
  host td-replaced; run_boot
  rm -f "$SWAPFILE"; make_swapfile
  local id; id=$(ident)
  local out; out=$(teardown)
  check "a swapfile replaced since: the new one stays" "$(ident)" "$id"
  check "a swapfile replaced since: the recorded line still goes" "$(grep -cxF "$SWAP_FSTAB_LINE" "$FSTAB")" 0
  check "a swapfile replaced since: it says the file is kept" "$(tr '\n' ' ' <<<"$out")" "removed-fstab kept-file "
}

# check the teardown of a legacy fstab line with no record
scenario_teardown_legacy_line_only() {
  host td-legacy; make_swapfile
  local id; id=$(ident)
  printf '%s\tnone\tswap\tsw\t0\t0\n' "$SWAPFILE" > "$FSTAB"
  echo "$SWAP_FSTAB_LINE" >> "$FSTAB"
  echo 0.1.0 > "$UPGRADE_FROM"
  printf '/dev/sda2 partition 1000 0 -2\n' >> "$PROC_SWAPS"
  run_boot
  teardown > /dev/null
  check "0.1.0's duplicate line beside a user's: the file stays" "$(ident)" "$id"
  check "0.1.0's duplicate line beside a user's: only that line goes" \
    "$(cat "$FSTAB")" "$(printf '%s\tnone\tswap\tsw\t0\t0' "$SWAPFILE")"
}

# check the teardown when swapoff fails
scenario_teardown_deferred() {
  host td-deferred; run_boot
  printf '%s file 1020 0 -2\n' "$SWAPFILE" >> "$PROC_SWAPS"
  local id; id=$(ident)
  local out; out=$(SWAPOFF_FAILS=1 teardown)
  check "swapoff refused: the removal is deferred" "${out##*$'\n'}" "deferred-file swapoff $SWAPFILE failed"
  check "swapoff refused: the file's token stays for a reinstall before the next boot" \
    "$(grep -cx "swapfile:$id" "$INSTALL_RECORD")" 1
  check "swapoff refused: the line's token goes with the line" "$(grep -cx swapfile-fstab "$INSTALL_RECORD")" 0
}

# check fstab bytes after install and removal
scenario_fstab_bytes() {
  local name=$1 before=$2 added=${3-} want=${4-$2}
  host "fstab-$name"
  printf '%s' "$before" > "$FSTAB"
  run_boot
  printf '%s' "$added" >> "$FSTAB"
  teardown > /dev/null
  printf '%s' "$want" > "$H/fstab.want"
  check "fstab $name: the bytes are the same after install and removal" \
    "$(cmp -s "$FSTAB" "$H/fstab.want" && echo same || echo different)" same
  check "fstab $name: the record holds no fstab token" "$([[ -f $INSTALL_RECORD ]] && grep -c '^swapfile-fstab' "$INSTALL_RECORD" || echo 0)" 0
}

# check teardown after a hand-removed line
scenario_fstab_hand_removed() {
  host fstab-hand-removed
  printf 'LABEL=a / ext4 defaults 0 1\n' > "$FSTAB"
  run_boot
  sed -i "\\#^$SWAP_FSTAB_LINE\$#d" "$FSTAB"
  cp "$FSTAB" "$H/fstab.want"
  teardown > /dev/null
  check "fstab hand-removed: the bytes stay as the owner left them" \
    "$(cmp -s "$FSTAB" "$H/fstab.want" && echo same || echo different)" same
  check "fstab hand-removed: the record holds no fstab token" "$([[ -f $INSTALL_RECORD ]] && grep -c '^swapfile-fstab' "$INSTALL_RECORD" || echo 0)" 0
}

# check the bootstrap and the teardown compute a swapfile identity
scenario_ids_agree() {
  host ids; make_swapfile
  check "the bootstrap and the teardown compute one identity" \
    "$( (eval "$BOOT_TEXT"; swapfile_id) )" "$( (eval "$LIB_TEXT"; teardown_swap_id "$SWAPFILE") )"
}

# run all of the swap ownership scenarios
all_scenarios() {
  scenario_new_host
  scenario_user user-tab $'SWAP\tnone\tswap\tsw\t0\t0'
  scenario_user user-spaces 'SWAP                                 none            swap    sw              0       0'
  scenario_user user-commented '#SWAP none swap sw 0 0'
  scenario_user user-commented-spaced '  # SWAP	none swap sw 0 0'
  scenario_user user-uuid 'UUID=UUID_OF none swap sw 0 0'
  scenario_user user-uuid-quoted 'UUID="UUID_OF" none swap sw 0 0'
  scenario_user user-label 'LABEL=myswap none swap sw 0 0' myswap
  scenario_user user-no-entry ''
  scenario_entry_no_file
  scenario_active
  scenario_legacy legacy-alone 0.1.0 "" "swapfile-fstab swapfile:<id> "
  scenario_legacy legacy-beside-user 0.1.0 $'SWAP\tnone\tswap\tsw\t0\t0' "swapfile-fstab "
  scenario_legacy legacy-from-0.1.1 0.1.1 "" ""
  scenario_legacy legacy-on-cachyos 0.1.0 "" "" cachyos
  scenario_root_fs root-ext4 ext2/ext3 ubuntu made
  scenario_root_fs root-btrfs-cachyos btrfs cachyos none
  scenario_root_fs root-btrfs-ubuntu btrfs ubuntu made
  scenario_teardown_ours
  scenario_teardown_user
  scenario_teardown_replaced
  scenario_teardown_legacy_line_only
  scenario_teardown_deferred
  scenario_ids_agree
  scenario_fstab_bytes with-newline $'LABEL=a / ext4 defaults 0 1\nLABEL=b /boot ext4 defaults 0 2\n'
  scenario_fstab_bytes no-newline $'LABEL=a / ext4 defaults 0 1\nLABEL=b /boot ext4 defaults 0 2'
  scenario_fstab_bytes empty ''
  scenario_fstab_hand_removed
  scenario_fstab_bytes later-line $'LABEL=a / ext4 defaults 0 1\n' $'LABEL=c /c ext4 defaults 0 2\n' \
    $'LABEL=a / ext4 defaults 0 1\nLABEL=c /c ext4 defaults 0 2\n'
  scenario_fstab_bytes no-newline-later-line $'LABEL=a / ext4 defaults 0 1' $'LABEL=c /c ext4 defaults 0 2\n' \
    $'LABEL=a / ext4 defaults 0 1\nLABEL=c /c ext4 defaults 0 2\n'
}

all_scenarios
REAL_FAILED=$FAILED

# run all scenarios with a text mutated
mutant() {
  local orig="${!2}" mut
  mut="${orig//"$3"/"$4"}"
  if [[ "$mut" == "$orig" ]]; then
    echo "FAIL mutant '$1' changed nothing -- its anchor moved"
    REAL_FAILED=$((REAL_FAILED + 1)); return
  fi
  printf -v "$2" '%s' "$mut"
  FAILED=0; QUIET=1; all_scenarios; QUIET=0
  printf -v "$2" '%s' "$orig"
  if (( FAILED )); then
    echo "ok   mutant '$1' fails $FAILED check(s)"
  else
    echo "FAIL mutant '$1' passes every scenario"
    REAL_FAILED=$((REAL_FAILED + 1))
  fi
}
mutant "the bootstrap takes over any existing /swapfile" BOOT_TEXT 'swapfile_is_ours || {' 'true || {'
mutant "fstab entries matched only when a space follows the path" BOOT_TEXT \
  'sub(/^[[:space:]]*#*[[:space:]]*/, "", src); sub(/[[:space:]].*$/, "", src)' 'sub(/ .*$/, "", src)'
mutant "the teardown removes whatever /swapfile is there" LIB_TEXT '[[ "$owned" == *file* ]]' '[[ -f "$swapfile" ]]'
mutant "a btrfs root gets a fallocate swapfile" BOOT_TEXT '"$(root_fstype)" == btrfs' '"$(root_fstype)" == none'
mutant "ubuntu's btrfs root gets no swapfile either" BOOT_TEXT '"$FLAVOR" != ubuntu && "$(root_fstype)" == btrfs' '"$(root_fstype)" == btrfs'
mutant "the bootstrap appends to an fstab with no final newline" BOOT_TEXT "lead=\$'\\n'" 'lead=""'
mutant "the teardown only deletes the line" LIB_TEXT '[[ "$tail_text" == "${appended}x" ]]' '[[ -z "$tail_text" ]]'
mutant "the 0.1.0 upgrade check runs on any host" BOOT_TEXT '[[ "$FLAVOR" == ubuntu ]] || return 0' ':'

echo "$REAL_FAILED checks failed"
(( REAL_FAILED == 0 ))
