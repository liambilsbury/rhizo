#!/bin/bash
# test the bootloader kinds on a fixture root
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BOOT="$HERE/../bootstrap/bootstrap.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
: > "$TMP/failed"; : > "$TMP/skipped"
# print and record a failure
fail() { echo "FAIL $1"; echo x >> "$TMP/failed"; }
# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else fail "$1"; echo "       got  $2"; echo "       want $3"; fi
}
NL=$'\n'
TAB=$'\t'
TOK="security=selinux enforcing=0 loop.max_loop=64 androidboot.hardware=rhizo"
ALL_MISSING=" $TOK"
TOK_LINES="androidboot.hardware=rhizo${NL}enforcing=0${NL}loop.max_loop=64${NL}security=selinux"
BEGIN="# >>> rhizo"
END="# <<< rhizo"
# shellcheck source=fixtures/bootloader-fixtures.sh
. "$HERE/fixtures/bootloader-fixtures.sh"

mkdir "$TMP/tools"
for t in awk sed grep sort cat cp mktemp chmod mv rm rmdir mkdir touch ln readlink sync dirname tr head tail stat cmp \
         uname dd; do
  ln -s "$(type -P "$t")" "$TMP/tools/$t"
done

# print the rhizo block of a file
block() { sed -n "/^$BEGIN\$/,/^$END\$/p" "$1"; }
# print the limine missing-base refusal message
limine_no_base() {
  echo "neither $1 nor limine-entry-tool's own config files set KERNEL_CMDLINE[default] -- copy the" \
       "running cmdline into KERNEL_CMDLINE[default] in $1 first"
}
# print the cmp status of two files
cmp_rc() { cmp -s "$1" "$2"; echo $?; }

# list the files in a fixture etc/default
listing() { printf '%s\n' "$1"/etc/default/*; }
# install an awk stub for the strip program
failing_strip_awk() {
  printf '#!/bin/bash\ncase "$*" in *"!skip"*) echo "awk: cannot read" >&2; exit 2 ;; esac\nexec "%s/tools/awk" "$@"\n' "$TMP" > "$1/bin/awk"
  chmod +x "$1/bin/awk"
  hash -r
}

# install an awk stub for the block search
failing_block_awk() {
  printf '#!/bin/bash\ncase "$*" in *"found = 1"*) echo "awk: read error" >&2; exit 2 ;; esac\n%s\n' \
    "exec \"$TMP/tools/awk\" \"\$@\"" > "$1/bin/awk"
  chmod +x "$1/bin/awk"
  hash -r
}
# install a failing awk stub for cmdline parsing
failing_cmdline_awk() {
  printf '#!/bin/bash\ncase "$*" in *Snapshots*|*10_linux*) echo "awk: read error" >&2; exit 2 ;; esac\n%s\n' \
    "exec \"$TMP/tools/awk\" \"\$@\"" > "$1/bin/awk"
  chmod +x "$1/bin/awk"
  hash -r
}
# check a case or record a skip
check_unprivileged() {
  if (( EUID != 0 )); then check "$@"; return; fi
  echo "SKIP $1 -- the suite runs as root, which no mode bit stops"
  echo x >> "$TMP/skipped"
}

# run a body function on a fixture root
with_root() {
  local root="$TMP/$3"
  mkdir -p "$root/bin" "$root/etc/default" "$root/boot"
  (
    export RHIZO_BL_ROOT="$root" RHIZO_OS_RELEASE="$root/os-release" PATH="$root/bin:$TMP/tools"
    case "$1" in
      ubuntu) printf 'ID=ubuntu\nVERSION_ID="24.04"\n' ;;
      *)      printf 'ID=%s\n' "$1" ;;
    esac > "$root/os-release"
    "$2" "$root"
    # shellcheck source=../lib/host-flavor.sh
    . "$HERE/../lib/host-flavor.sh"
    # shellcheck source=../bootstrap/bootloader.sh
    . "$HERE/../bootstrap/bootloader.sh"
    "$3" "$root"
  ) || fail "$3 exited $?"
}

setup_limine()      { add_limine "$1"; }
setup_sdboot()      { add_sdboot "$1"; }
# set up a grub host whose /etc/default/grub is edited inline
setup_grub_inline() { add_grub_inline "$1"; }
# set up a grub host that takes a grub.d drop-in
setup_grub_dropin() { add_grub_dropin "$1"; }
# set up a host with no bootloader
setup_nothing()     { :; }
# set up a host with both limine and sd-boot
setup_two()         { add_limine "$1"; add_sdboot "$1"; }
# set up a limine host that also has a loader/entries folder
setup_limine_entries_dir() { add_limine "$1"; mkdir -p "$1/boot/loader/entries"; }
# set up a limine host whose /etc/default/limine is a symlink
setup_limine_symlink() { add_limine "$1"; mv "$1/etc/default/limine" "$1/real-limine"; ln -s "$1/real-limine" "$1/etc/default/limine"; }
# set up a host that boots through rEFInd
setup_refind()      { printf '"Boot" "root=UUID=abc rw"\n' > "$1/boot/refind_linux.conf"; }
# set up an ubuntu grub host with no update-grub
setup_ubuntu_grub_no_update() { mkdir -p "$1/boot/grub"; : > "$1/etc/default/grub"; }

# check the limine kind
body_limine() {
  local root="$1" f="$1/etc/default/limine" out rc snap
  cp "$f" "$root/before"
  check "limine detected"                  "$(bootloader_kind)" limine
  check "limine edited file"               "$(bootloader_config_file limine)" "$f"
  check "limine generated file"            "$(bootloader_generated limine)" "$root/boot/limine.conf"
  check "limine missing before"            "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  bootloader_present limine;               check "limine not present before" "$?" 1
  bootloader_config_current limine "$TOK"; check "limine not current before" "$?" 1
  check "limine own tokens before a write" "$(bootloader_own_tokens limine; echo "rc=$?")" "rc=0"

  bootloader_write limine "$TOK";          check "limine write rc" "$?" 0
  check "limine own tokens after the write" "$(bootloader_own_tokens limine)" "$TOK_LINES"
  check "limine write: block in the edited file" "$(block "$f")" "$BEGIN${NL}KERNEL_CMDLINE[default]+=\" $TOK\"${NL}$END"
  check "limine write: generated config still lacks the tokens" "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  check "limine write: nothing regenerated" "$(ncalls "$root" limine-update)" 0
  bootloader_present limine;               check "limine present after write" "$?" 0
  bootloader_config_current limine "$TOK"; check "limine current after write" "$?" 0
  bootloader_config_current limine "$TOK extra=1"; check "limine other tokens are not current" "$?" 1

  out=$(bootloader_regen limine); rc=$?
  check "limine regen rc"                  "$rc" 0
  check "limine regen output on stdout"    "$out" "Updating limine.conf"
  check "limine regen: nothing missing"    "$(bootloader_missing limine "$TOK")" ""
  check "limine keeps root=, after rhizo's tokens as limine-entry-tool composes them" \
    "$(grep -c 'cmdline: security=selinux .*root=UUID=44444444' "$root/boot/limine.conf")" 1

  limine_snapper_sync "$root"
  snap=$(grep -F '.snapshots/2/snapshot' "$root/boot/limine.conf")
  out=$(bootloader_apply limine "$TOK"); rc=$?
  check "limine leaves limine-snapper-sync's snapshot entry as it was" \
    "$(grep -F '.snapshots/2/snapshot' "$root/boot/limine.conf")" "$snap"
  check "limine apply rc"                  "$rc" 0
  check "limine apply output is the regeneration's" "$out" "Updating limine.conf"
  check "limine apply twice keeps one block" "$(grep -c "^$BEGIN\$" "$f")" 1
  check "limine apply regenerates"         "$(ncalls "$root" limine-update)" 2

  bootloader_strip limine;                 check "limine strip rc" "$?" 0
  check "limine strip restores the file"   "$(cmp_rc "$root/before" "$f")" 0
  bootloader_regen limine >/dev/null
  check "limine strip then regen: tokens gone" "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  bootloader_present limine;               check "limine not present after the strip" "$?" 1
  check "limine own tokens after the strip" "$(bootloader_own_tokens limine)" ""
}

# check limine stays detected beside each partial sd-boot setup
body_limine_entries_dir() {
  local root="$1"
  check "limine detected with loader/entries and no sdboot-manage.conf" "$(bootloader_kind)" limine
  printf 'LINUX_OPTIONS="quiet"\n' > "$root/etc/sdboot-manage.conf"
  check "limine detected with sdboot-manage.conf and loader/entries but no sdboot-manage command" "$(bootloader_kind)" limine
  rmdir "$root/boot/loader/entries"
  stub "$root/bin/sdboot-manage" <<<'exit 0'
  check "limine detected with sdboot-manage.conf and command but no loader/entries" "$(bootloader_kind)" limine
  rm "$root/etc/sdboot-manage.conf"
  mkdir "$root/boot/loader/entries"
  check "limine detected with loader/entries and command but no sdboot-manage.conf" "$(bootloader_kind)" limine
}

# check a limine file with two KERNEL_CMDLINE keys
body_limine_two_keys() {
  local root="$1" f="$1/etc/default/limine"
  touch "$root/boot/vmlinuz-linux-cachyos-lts"
  limine_default "$root" "$LIMINE_ESP" "$LIMINE_BASE" \
    'KERNEL_CMDLINE[linux-cachyos-lts]="quiet root=UUID=44444444-4444-4444-8444-444444444444"' \
    'KERNEL_CMDLINE[default]+=" nowatchdog"' "$LIMINE_ORDER"
  check "limine two keys: missing before"  "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  bootloader_apply limine "$TOK" >/dev/null
  check "limine two keys: one line per key" "$(block "$f")" \
    "$BEGIN${NL}KERNEL_CMDLINE[default]+=\" $TOK\"${NL}KERNEL_CMDLINE[linux-cachyos-lts]+=\" $TOK\"${NL}$END"
  check "limine two keys: both cmdlines carry the tokens" "$(grep -c 'cmdline: .*androidboot.hardware=rhizo' "$root/boot/limine.conf")" 2
  check "limine two keys: nothing missing" "$(bootloader_missing limine "$TOK")" ""
  check "limine two keys: own tokens once each" "$(bootloader_own_tokens limine)" "$TOK_LINES"
}

# check a quoted limine KERNEL_CMDLINE key
body_limine_quoted_key() {
  local root="$1" f="$1/etc/default/limine"
  limine_default "$root" "$LIMINE_ESP" "$LIMINE_BASE" 'KERNEL_CMDLINE["linux-cachyos"]="quiet root=UUID=44444444-4444-4444-8444-444444444444"' "$LIMINE_ORDER"
  bootloader_apply limine "$TOK" >/dev/null
  check "limine quoted key: the block spells the key as the file does" "$(block "$f")" \
    "$BEGIN${NL}KERNEL_CMDLINE[default]+=\" $TOK\"${NL}KERNEL_CMDLINE[\"linux-cachyos\"]+=\" $TOK\"${NL}$END"
  check "limine quoted key: nothing missing" "$(bootloader_missing limine "$TOK")" ""
  check "limine quoted key: own tokens are the block's values only" "$(bootloader_own_tokens limine)" "$TOK_LINES"
  limine_default "$root" "$LIMINE_ESP" 'KERNEL_CMDLINE["default"]="quiet root=UUID=44444444-4444-4444-8444-444444444444"' "$LIMINE_ORDER"
  bootloader_apply limine "$TOK" >/dev/null; check "limine quoted default key is a base" "$?" 0
  check "limine quoted default key: nothing missing" "$(bootloader_missing limine "$TOK")" ""
}

# check limine refuses a file with no base cmdline
body_limine_no_base() {
  local root="$1" f="$1/etc/default/limine" err rc
  limine_default "$root" 'BOOT_ORDER="*"'
  cp "$f" "$root/before"
  err=$(bootloader_apply limine "$TOK" 2>&1 >/dev/null); rc=$?
  check "limine refuses no base: rc"       "$rc" 1
  check "limine refuses no base: message"  "$err" "$(limine_no_base "$f")"
  check "limine refuses no base: file untouched" "$(cmp_rc "$root/before" "$f")" 0
  check "limine refuses no base: nothing regenerated" "$(ncalls "$root" limine-update)" 0
  bootloader_write limine "$TOK" 2>/dev/null; check "limine refuses no base: write rc" "$?" 1
}

# check all of the tokens read as missing with no cmdline or no limine.conf
body_limine_no_cmdline() {
  local root="$1" err rc
  printf 'timeout: 5\n/+CachyOS\n//linux-cachyos\n    protocol: linux\n' > "$root/boot/limine.conf"
  check "limine conf without cmdline: every token missing" "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  rm "$root/boot/limine.conf"
  sed -i '/^ESP_PATH=/d' "$root/etc/default/limine"
  check "limine without ESP_PATH or limine.conf: every token missing" "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  err=$(bootloader_generated limine 2>&1); rc=$?
  check "limine without ESP_PATH or limine.conf: generated rc" "$rc" 1
  check "limine without ESP_PATH or limine.conf: generated message" "$err" "no limine.conf found (looked for $root/boot/limine.conf $root/boot/limine/limine.conf $root/efi/limine.conf $root/boot/efi/limine.conf $root/boot/EFI/limine/limine.conf $root/limine/limine.conf)"
}

# check limine token matching in boot entries
body_limine_whole_words() {
  local root="$1"
  { limine_os CachyOS
    limine_entry linux-cachyos \
      'root=UUID=abc security=selinux notenforcing=0x xloop.max_loop=64 androidboot.hardware=rhizo'
  } \
    > "$root/boot/limine.conf"
  check "limine tokens match whole words" "$(bootloader_missing limine "$TOK")" " enforcing=0 loop.max_loop=64"
  { limine_os CachyOS; limine_entry linux-cachyos "$TOK"; } > "$root/boot/limine.conf"
  check "limine tokens at both ends of the line" "$(bootloader_missing limine "$TOK")" ""
  { limine_os CachyOS; limine_entry linux-cachyos "$TOK"
    limine_entry linux-cachyos-lts 'root=UUID=abc androidboot.hardware=rhizo'; } > "$root/boot/limine.conf"
  check "limine every boot entry must carry the tokens" "$(bootloader_missing limine "$TOK")" " security=selinux enforcing=0 loop.max_loop=64"
  { limine_os CachyOS; limine_entry linux-cachyos "$TOK"
    printf '%s\n' '     //Snapshots' '     ///2 │ 2026-10-01' '     ////linux-cachyos' \
      '     ### This kernel entry is auto-generated by limine-entry-tool' '     cmdline: quiet'
  } > "$root/boot/limine.conf"
  check "limine a snapshot entry, marked as the tool's or not, is skipped" "$(bootloader_missing limine "$TOK")" ""
  { limine_os CachyOS; limine_entry linux-cachyos "$TOK"
    printf '%s\n' '     //Snapshots' '     ///2 │ 2026-10-01' '     ////linux-cachyos' '     cmdline: quiet'
    limine_entry linux-cachyos-lts root=UUID=abc; } > "$root/boot/limine.conf"
  check "limine an entry of this OS's after its snapshots is read" "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  { limine_os "Arch Linux" 0123456789abcdef0123456789abcdef; limine_entry linux root=UUID=other
    limine_os CachyOS; limine_entry linux-cachyos "$TOK"; } > "$root/boot/limine.conf"
  check "limine another system's OS entry is not read" "$(bootloader_missing limine "$TOK")" ""
  { limine_os CachyOS; limine_entry linux-cachyos "$TOK"
    printf '%s\n' /Windows '  //windows' '  protocol: linux' '  cmdline: root=UUID=other'; } > "$root/boot/limine.conf"
  check "limine an entry limine-entry-tool did not write is not read" "$(bootloader_missing limine "$TOK")" ""
  { limine_os CachyOS
    printf '%s\n' '  //linux-cachyos' '  ### This kernel entry is auto-generated by limine-entry-tool' \
      '  protocol: linux'; } > "$root/boot/limine.conf"
  check "limine a tool entry with no cmdline: named, lacking every token" \
    "$(bootloader_missing_entries limine "$TOK")" \
    "$root/boot/limine.conf entry CachyOS/linux-cachyos$TAB$ALL_MISSING"
}

# check limine refuses a block with no end marker
body_limine_unterminated() {
  local root="$1" f="$1/etc/default/limine" err rc
  limine_default "$root" "$LIMINE_ESP" "$LIMINE_BASE" "$BEGIN" 'KERNEL_CMDLINE[default]+=" old=1"' "$LIMINE_ORDER"
  cp "$f" "$root/before"
  err=$(bootloader_apply limine "$TOK" 2>&1 >/dev/null); rc=$?
  check "limine unterminated block: apply rc" "$rc" 1
  check "limine unterminated block: message"  "$err" "$f has a '$BEGIN' line with no '$END' line after it -- fix the file by hand"
  check "limine unterminated block: file untouched" "$(cmp_rc "$root/before" "$f")" 0
  check "limine unterminated block: nothing regenerated" "$(ncalls "$root" limine-update)" 0
  err=$(bootloader_own_tokens limine 2>&1); rc=$?
  check "limine unterminated block: own tokens refused" "$rc:$err" "1:$f has a '$BEGIN' line with no '$END' line after it -- fix the file by hand"
}

# check limine write and strip keep the file's mode
body_limine_mode() {
  local f="$1/etc/default/limine" mode
  for mode in 600 644; do
    chmod "$mode" "$f"
    bootloader_write limine "$TOK"
    check "limine write keeps mode $mode"  "$(stat -c %a "$f")" "$mode"
    bootloader_strip limine
    check "limine strip keeps mode $mode"  "$(stat -c %a "$f")" "$mode"
  done
}

# check a limine marker prefix is not a block
body_limine_remove_clean() {
  local root="$1" f="$1/etc/default/limine" rc
  echo "$BEGIN-notes" >> "$f"
  cp "$f" "$root/before"
  bootloader_present limine; check "limine marker prefix is not the block" "$?" 1
  bootloader_strip limine; rc=$?
  check "limine strip without a block: rc" "$rc" 0
  check "limine strip without a block, a marker prefix: file byte-identical" "$(cmp_rc "$root/before" "$f")" 0
}

# check a failing limine regeneration returns 3 after the block was written
body_limine_regen_fails() {
  local root="$1" err rc
  : > "$root/regen-fails"
  err=$(bootloader_regen limine 2>&1); rc=$?
  check "limine regen failing: rc"        "$rc" 3
  check "limine regen failing: output"    "$err" "regeneration failed"
  bootloader_apply limine "$TOK" >/dev/null 2>&1; check "limine apply with failing regen: rc" "$?" 3
  bootloader_present limine;                      check "limine apply with failing regen: block was written" "$?" 0
}

# check the sd-boot kind
body_sdboot() {
  local root="$1" f="$1/etc/sdboot-manage.conf" out
  cp "$f" "$root/before"
  check "sdboot detected"                  "$(bootloader_kind)" sdboot
  check "sdboot edited file"               "$(bootloader_config_file sdboot)" "$f"
  check "sdboot generated"                 "$(bootloader_generated sdboot)" "$root/boot/loader/entries"
  check "sdboot missing before"            "$(bootloader_missing sdboot "$TOK")" "$ALL_MISSING"
  bootloader_write sdboot "$TOK";          check "sdboot write rc" "$?" 0
  check "sdboot write: block in the edited file" "$(block "$f")" "$BEGIN${NL}LINUX_OPTIONS=\"\$LINUX_OPTIONS $TOK\"${NL}$END"
  check "sdboot write: entries still lack the tokens" "$(bootloader_missing sdboot "$TOK")" "$ALL_MISSING"
  check "sdboot write: nothing regenerated" "$(ncalls "$root" sdboot-manage)" 0
  bootloader_config_current sdboot "$TOK"; check "sdboot current after write" "$?" 0
  out=$(bootloader_regen sdboot)
  check "sdboot regen: sdboot-manage gen prints nothing" "$out" ""
  check "sdboot regen: nothing missing"    "$(bootloader_missing sdboot "$TOK")" ""
  bootloader_apply sdboot "$TOK" >/dev/null
  check "sdboot apply twice keeps one block" "$(grep -c "^$BEGIN\$" "$f")" 1
  bootloader_strip sdboot
  check "sdboot strip restores the file"   "$(cmp_rc "$root/before" "$f")" 0
  bootloader_regen sdboot >/dev/null
  check "sdboot strip then regen: tokens gone" "$(bootloader_missing sdboot "$TOK")" "$ALL_MISSING"
}

# check sdboot with LINUX_OPTIONS and LINUX_FALLBACK_OPTIONS
body_sdboot_both_vars() {
  local root="$1" f="$1/etc/sdboot-manage.conf"
  printf 'LINUX_OPTIONS="nowatchdog quiet splash"\nLINUX_FALLBACK_OPTIONS="quiet"\n' > "$f"
  run_stub "$root/bin/sdboot-manage" gen
  check "sdboot no fallback entry without /initramfs-<name>-fallback.img" \
    "$(cd "$root/boot/loader/entries" && printf '%s\n' *)" linux-cachyos.conf
  touch "$root/initramfs-linux-cachyos-fallback.img"
  bootloader_apply sdboot "$TOK" >/dev/null
  check "sdboot the fallback entry has LINUX_FALLBACK_OPTIONS alone" \
    "$(grep '^options' "$root/boot/loader/entries/linux-cachyos-fallback.conf")" \
    "options root=UUID=abc rw rootflags=subvol=/@ quiet $TOK"
  check "sdboot LINUX_OPTIONS and LINUX_FALLBACK_OPTIONS: block" "$(block "$f")" \
    "$BEGIN${NL}LINUX_OPTIONS=\"\$LINUX_OPTIONS $TOK\"${NL}LINUX_FALLBACK_OPTIONS=\"\$LINUX_FALLBACK_OPTIONS $TOK\"${NL}$END"
  check "sdboot LINUX_OPTIONS and LINUX_FALLBACK_OPTIONS: nothing missing" "$(bootloader_missing sdboot "$TOK")" ""
  check "sdboot LINUX_OPTIONS and LINUX_FALLBACK_OPTIONS: own tokens once each" "$(bootloader_own_tokens sdboot)" "$TOK_LINES"
  check "sdboot LINUX_OPTIONS and LINUX_FALLBACK_OPTIONS: both entries carry the tokens" "$(grep -l 'androidboot.hardware=rhizo' "$root"/boot/loader/entries/*.conf | grep -c '')" 2
}

# check sd-boot token matching
body_sdboot_whole_words() {
  local root="$1"
  printf 'title CachyOS\noptions root=UUID=abc security=selinux notenforcing=0x loop.max_loop=64 androidboot.hardware=rhizo\n' > "$root/boot/loader/entries/linux-cachyos.conf"
  check "sdboot tokens match whole words" "$(bootloader_missing sdboot "$TOK")" " enforcing=0"
  rm "$root/boot/loader/entries/linux-cachyos.conf"
  check "sdboot without entries: every token missing" "$(bootloader_missing sdboot "$TOK")" "$ALL_MISSING"
}

# check the grub-inline kind
body_grub_inline() {
  local root="$1" f="$1/etc/default/grub" cfg="$1/boot/grub/grub.cfg" out
  cp "$f" "$root/before"
  check "grub-inline detected"             "$(bootloader_kind)" grub-inline
  check "grub-inline edited file"          "$(bootloader_config_file grub-inline)" "$f"
  check "grub-inline generated file"       "$(bootloader_generated grub-inline)" "$cfg"
  check "grub-inline missing before"       "$(bootloader_missing grub-inline "$TOK")" "$ALL_MISSING"
  bootloader_write grub-inline "$TOK";     check "grub-inline write rc" "$?" 0
  check "grub-inline write: block in the edited file" "$(block "$f")" "$BEGIN${NL}GRUB_CMDLINE_LINUX=\"\${GRUB_CMDLINE_LINUX:+\$GRUB_CMDLINE_LINUX }$TOK\"${NL}$END"
  check "grub-inline write: grub.cfg still lacks the tokens" "$(bootloader_missing grub-inline "$TOK")" "$ALL_MISSING"
  check "grub-inline own tokens"           "$(bootloader_own_tokens grub-inline)" "$TOK_LINES"
  out=$(bootloader_regen grub-inline)
  check "grub-inline regen output on stdout" "$out" "Generating grub configuration file ..."
  check "grub-inline regen: nothing missing" "$(bootloader_missing grub-inline "$TOK")" ""
  check "grub-inline keeps the default options" "$(grep -c 'nowatchdog quiet splash$' "$cfg")" 1
  bootloader_apply grub-inline "$TOK" >/dev/null
  check "grub-inline apply twice keeps one block" "$(grep -c "^$BEGIN\$" "$f")" 1
  bootloader_strip grub-inline
  check "grub-inline strip restores the file" "$(cmp_rc "$root/before" "$f")" 0
  bootloader_regen grub-inline >/dev/null
  check "grub-inline strip then regen: tokens gone" "$(bootloader_missing grub-inline "$TOK")" "$ALL_MISSING"
}

# check the grub-dropin kind
body_grub_dropin() {
  local root="$1" d="$1/etc/default/grub.d/90-rhizo.cfg" cfg="$1/boot/grub/grub.cfg" out
  check "grub-dropin detected"             "$(bootloader_kind)" grub-dropin
  check "grub-dropin file"                 "$(bootloader_config_file grub-dropin)" "$d"
  check "grub-dropin generated file"       "$(bootloader_generated grub-dropin)" "$cfg"
  bootloader_present grub-dropin;          check "grub-dropin not present before" "$?" 1
  bootloader_config_current grub-dropin "$TOK"; check "grub-dropin not current before" "$?" 1
  check "grub-dropin missing before"       "$(bootloader_missing grub-dropin "$TOK")" "$ALL_MISSING"
  check "grub-dropin own tokens with no drop-in" "$(bootloader_own_tokens grub-dropin; echo "rc=$?")" "rc=0"
  (umask 077; bootloader_write grub-dropin "$TOK"); check "grub-dropin write rc" "$?" 0
  check "grub-dropin write: file is world-readable" "$(stat -c %a "$d")" 644
  check "grub-dropin write: last line" "$(tail -1 "$d")" "GRUB_CMDLINE_LINUX=\"\${GRUB_CMDLINE_LINUX:+\$GRUB_CMDLINE_LINUX }$TOK\""
  check "grub-dropin write: grub.cfg still lacks the tokens" "$(bootloader_missing grub-dropin "$TOK")" "$ALL_MISSING"
  check "grub-dropin write: nothing regenerated" "$(ncalls "$root" update-grub)" 0
  check "grub-dropin own tokens"           "$(bootloader_own_tokens grub-dropin)" "$TOK_LINES"
  bootloader_present grub-dropin;          check "grub-dropin present after write" "$?" 0
  bootloader_config_current grub-dropin "$TOK"; check "grub-dropin current after write" "$?" 0
  bootloader_config_current grub-dropin "$TOK extra=1"; check "grub-dropin other tokens are not current" "$?" 1
  out=$(bootloader_regen grub-dropin)
  check "grub-dropin regen output on stdout" "$out" "Generating grub configuration file ..."
  check "grub-dropin regen: nothing missing" "$(bootloader_missing grub-dropin "$TOK")" ""
  check "grub-dropin appends to the existing options" "$(grep -c 'ro console=ttyS0 security=selinux' "$cfg")" 1
  bootloader_apply grub-dropin "$TOK" >/dev/null
  check "grub-dropin apply regenerates"    "$(ncalls "$root" update-grub)" 2
  bootloader_strip grub-dropin;            check "grub-dropin strip rc" "$?" 0
  check "grub-dropin file gone"            "$([[ -e "$d" ]] && echo 0 || echo 1)" 1
  bootloader_regen grub-dropin >/dev/null
  check "grub-dropin strip then regen: tokens gone" "$(bootloader_missing grub-dropin "$TOK")" "$ALL_MISSING"
  bootloader_present grub-dropin;          check "grub-dropin not present after the strip" "$?" 1
  bootloader_strip grub-dropin;            check "grub-dropin strip with no file: rc" "$?" 0
  mkdir "$d"
  bootloader_present grub-dropin;          check "grub-dropin: a directory at the path is present" "$?" 0
  check "grub-dropin: a directory at the path holds" "$(bootloader_holders)" grub-dropin
  bootloader_strip grub-dropin 2>/dev/null; check "grub-dropin: a directory at the path is refused by the strip" "$?" 1
  rmdir "$d"
  echo "linux /vmlinuz ro loopXmax_loop=64" > "$cfg"
  check "grub-dropin matches tokens as fixed strings" "$(bootloader_missing grub-dropin loop.max_loop=64)" " loop.max_loop=64"
  rm "$cfg"
  check "grub-dropin without grub.cfg: every token missing" "$(bootloader_missing grub-dropin "$TOK")" "$ALL_MISSING"
}

# check a host with two bootloaders
body_two() {
  local err rc
  err=$(bootloader_kind 2>&1 >/dev/null); rc=$?
  check "two bootloaders refused: rc"      "$rc" 1
  check "two bootloaders refused: message" "$err" "more than one bootloader is configured here (limine sdboot) -- set RHIZO_BOOTLOADER to the one that boots this machine"
  check "override wins"                    "$(RHIZO_BOOTLOADER=sdboot bootloader_kind)" sdboot
  err=$(RHIZO_BOOTLOADER=lilo bootloader_kind 2>&1); rc=$?
  check "unknown override: rc"             "$rc" 1
  check "unknown override: message"        "$err" "RHIZO_BOOTLOADER is 'lilo', not one of grub-dropin grub-inline limine sdboot"
}

# check a rEFInd host is refused by name
body_refind() {
  local err rc
  err=$(bootloader_kind 2>&1); rc=$?
  check "refind refused: rc"               "$rc" 1
  check "refind refused by name"           "$(grep -c "boots through rEFInd, whose $1/boot/refind_linux.conf rhizo does not edit" <<<"$err")" 1
}

LLE=sys/firmware/efi/efivars/LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a
LED=sys/firmware/efi/efivars/LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
# add Rhizo and stock kernels to a limine host
setup_limine_rhizo() {
  add_limine "$1"
  touch "$1/boot/vmlinuz-linux-cachyos-lts" "$1/boot/vmlinuz-linux-rhizo" "$1/boot/initramfs-linux-rhizo.img"
  run_stub "$1/bin/limine-update"; : > "$1/calls"
}
# add Rhizo and stock kernels to an sd-boot host
setup_sdboot_rhizo() {
  add_sdboot "$1"
  touch "$1/boot/vmlinuz-linux-cachyos-lts" "$1/boot/vmlinuz-linux-rhizo" "$1/boot/initramfs-linux-rhizo.img"
  run_stub "$1/bin/sdboot-manage" gen; : > "$1/calls"
}
# add Rhizo and stock kernels to an ubuntu grub host
setup_grub_dropin_rhizo() { add_grub_dropin "$1"; touch "$1/boot/vmlinuz-6.8.0-136-generic" "$1/boot/vmlinuz-7.1.0-rc1-rhizo"; }
# add a Rhizo kernel to a grub host edited inline
setup_grub_inline_rhizo() { add_grub_inline "$1"; touch "$1/boot/vmlinuz-linux-rhizo"; }
# print an EFI variable's bytes for a text
efivar_bytes() {
  local i
  printf '\007\000\000\000'
  if [[ "$1" == utf16 ]]; then for (( i = 0; i < ${#2}; i++ )); do printf '%s\0' "${2:i:1}"; done; printf '\0\0'
  else printf '%s\0' "$2"; fi
}

# check which entry ids name a Rhizo kernel
body_rhizo_entry_names() {
  local id
  for id in CachyOS/linux-rhizo CachyOS/linux-rhizo-fallback linux-rhizo.conf linux-rhizo-fallback.conf \
            "gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc" "Advanced options>Linux 7.1.0-rc1-rhizo"; do
    check "entry '$id' reads as the Rhizo kernel's" "$(bl_rhizo_entry "$id" && echo rhizo || echo other)" rhizo
  done
  for id in CachyOS/linux-cachyos linux-cachyos.conf "gnulinux-advanced-abc>gnulinux-6.8.0-136-generic-advanced-abc" \
            "gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-recovery-abc" Arch/linux-rhizoz - ""; do
    check "entry '$id' reads as another kernel's" "$(bl_rhizo_entry "$id" && echo rhizo || echo other)" other
  done
}

# check limine's default entry made and restored
body_default_limine() {
  local root="$1" rec="$1/record" out rc
  check "limine default before: the stock kernel" "$(bootloader_default_entry limine)" CachyOS/linux-cachyos
  out=$(bootloader_make_rhizo_default limine "$rec"); rc=$?
  check "limine make default: rc and the entry set" "$rc:$out" "0:CachyOS/linux-rhizo"
  check "limine make default: LimineLastBootedEntry names the Rhizo kernel" \
    "$(cmp -s <(efivar_bytes ascii CachyOS/linux-rhizo) "$root/$LLE" && echo same)" same
  check "limine make default records the previous default" "$(cat "$rec")" "rhizo-kernel-default CachyOS/linux-cachyos"
  bootloader_make_rhizo_default limine "$rec" >/dev/null
  check "limine make default twice keeps the first previous default" "$(cat "$rec")" \
    "rhizo-kernel-default CachyOS/linux-cachyos"
  out=$(bootloader_restore_default limine "$rec"); rc=$?
  check "limine restore puts the previous default back" "$rc:$out:$(bootloader_default_entry limine)" \
    "0:restored CachyOS/linux-cachyos:CachyOS/linux-cachyos"
  check "limine restore drops the record line" "$(cat "$rec")" ""
  out=$(bootloader_restore_default limine "$rec"); rc=$?
  check "limine restore with nothing recorded: nothing done" "$rc:$out:$(bootloader_default_entry limine)" \
    "0::CachyOS/linux-cachyos"
  bootloader_make_rhizo_default limine "$rec" >/dev/null
  efivar_put "$root" CachyOS/linux-cachyos-lts "${LLE##*/}"
  out=$(bootloader_restore_default limine "$rec"); rc=$?
  check "limine restore keeps a default the user chose after the install" \
    "$rc:$out:$(bootloader_default_entry limine):$(cat "$rec")" "0:kept CachyOS/linux-cachyos-lts:CachyOS/linux-cachyos-lts:"
  efivar_put "$root" CachyOS/linux-cachyos "${LLE##*/}"
  bootloader_make_rhizo_default limine "$rec" >/dev/null
  rm "$root/boot/vmlinuz-linux-cachyos"; run_stub "$root/bin/limine-update"
  out=$(bootloader_restore_default limine "$rec"); rc=$?
  check "limine restore of a removed kernel's default: the first other kernel, never the removed one" \
    "$rc:$out:$(bootloader_default_entry limine)" "0:restored CachyOS/linux-cachyos-lts:CachyOS/linux-cachyos-lts"
  rm "$root/$LLE"
  bootloader_make_rhizo_default limine "$rec" >/dev/null
  check "limine with no remembered entry records none" "$(cat "$rec")" "rhizo-kernel-default -"
  out=$(bootloader_restore_default limine "$rec"); rc=$?
  check "limine restore of none removes the variable" "$rc:$out:$([[ -e "$root/$LLE" ]] && echo present || echo gone)" \
    "0:restored -:gone"
  sed -i 's/^remember_last_entry: yes$/remember_last_entry: no/' "$root/boot/limine.conf"
  out=$(bootloader_make_rhizo_default limine "$rec" 2>&1); rc=$?
  check "limine without remember_last_entry: refused, named, nothing recorded" "$rc:$out:$(cat "$rec")" \
    "1:$root/boot/limine.conf does not set remember_last_entry: yes, so Limine reads no LimineLastBootedEntry:"
}

# check sd-boot's default entry made and restored
body_default_sdboot() {
  local root="$1" rec="$1/record" out rc
  check "sdboot default before: none" "$(bootloader_default_entry sdboot)" ""
  out=$(bootloader_make_rhizo_default sdboot "$rec"); rc=$?
  check "sdboot make default: rc and the entry set" "$rc:$out" "0:linux-rhizo.conf"
  check "sdboot make default: LoaderEntryDefault holds the entry in UTF-16" \
    "$(cmp -s <(efivar_bytes utf16 linux-rhizo.conf) "$root/$LED" && echo same)" same
  check "sdboot make default records no previous default" "$(cat "$rec")" "rhizo-kernel-default -"
  out=$(bootloader_restore_default sdboot "$rec"); rc=$?
  check "sdboot restore of none removes the variable" "$rc:$out:$([[ -e "$root/$LED" ]] && echo present || echo gone)" \
    "0:restored -:gone"
  bl_efivar_write "$root/$LED" utf16 linux-cachyos.conf
  bootloader_make_rhizo_default sdboot "$rec" >/dev/null
  check "sdboot make default records the previous default" "$(cat "$rec")" "rhizo-kernel-default linux-cachyos.conf"
  out=$(bootloader_restore_default sdboot "$rec"); rc=$?
  check "sdboot restore puts the previous default back" "$rc:$out:$(bootloader_default_entry sdboot)" \
    "0:restored linux-cachyos.conf:linux-cachyos.conf"
  bootloader_make_rhizo_default sdboot "$rec" >/dev/null
  bl_efivar_write "$root/$LED" utf16 linux-cachyos-lts.conf
  out=$(bootloader_restore_default sdboot "$rec"); rc=$?
  check "sdboot restore keeps a default the user chose after the install" "$rc:$out:$(bootloader_default_entry sdboot)" \
    "0:kept linux-cachyos-lts.conf:linux-cachyos-lts.conf"
  bl_efivar_write "$root/$LED" utf16 linux-cachyos.conf
  bootloader_make_rhizo_default sdboot "$rec" >/dev/null
  rm "$root/boot/vmlinuz-linux-cachyos"
  out=$(bootloader_restore_default sdboot "$rec"); rc=$?
  check "sdboot restore of a removed kernel's default clears it, never naming the removed one" \
    "$rc:$out:$([[ -e "$root/$LED" ]] && echo present || echo gone)" "0:restored -:gone"
}

# check grub's saved entry made and restored
body_default_grub_dropin() {
  local root="$1" rec="$1/record" d="$1/etc/default/grub.d/90-rhizo.cfg" out rc
  local rhizo="gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc"
  local stock="gnulinux-advanced-abc>gnulinux-6.8.0-136-generic-advanced-abc"
  BL_SAVED_DEFAULT=1
  bootloader_apply grub-dropin "$TOK" >/dev/null
  check "grub-dropin with the saved default: the drop-in sets GRUB_DEFAULT=saved" "$(tail -1 "$d")" "GRUB_DEFAULT=saved"
  bootloader_config_current grub-dropin "$TOK"; check "grub-dropin with the saved default: current" "$?" 0
  check "grub-dropin with the saved default: the drop-in's tokens are the tokens alone" \
    "$(bootloader_own_tokens grub-dropin)" "$TOK_LINES"
  # shellcheck disable=SC2016
  check "grub-dropin with the saved default: grub.cfg boots the saved entry" "$(bl_grub_cfg_default)" '${saved_entry}'
  out=$(bootloader_make_rhizo_default grub-dropin "$rec"); rc=$?
  check "grub-dropin make default: rc and the entry set" "$rc:$out:$(bl_grub_env_get saved_entry)" "0:$rhizo:$rhizo"
  check "grub-dropin make default records no previous saved entry" "$(cat "$rec")" "rhizo-kernel-default -"
  out=$(bootloader_restore_default grub-dropin "$rec"); rc=$?
  check "grub-dropin restore of none unsets saved_entry" "$rc:$out:$(grep -c '^saved_entry=' "$root/boot/grub/grubenv")" \
    "0:restored -:0"
  "$root/bin/grub-editenv" "$root/boot/grub/grubenv" set "saved_entry=$stock"
  bootloader_make_rhizo_default grub-dropin "$rec" >/dev/null
  out=$(bootloader_restore_default grub-dropin "$rec"); rc=$?
  check "grub-dropin restore puts the previous saved entry back" "$rc:$out:$(bootloader_default_entry grub-dropin)" \
    "0:restored $stock:$stock"
  bootloader_make_rhizo_default grub-dropin "$rec" >/dev/null
  "$root/bin/grub-editenv" "$root/boot/grub/grubenv" set "saved_entry=1"
  out=$(bootloader_restore_default grub-dropin "$rec"); rc=$?
  check "grub-dropin restore keeps a saved entry the user chose" "$rc:$out:$(bl_grub_env_get saved_entry)" "0:kept 1:1"
  "$root/bin/grub-editenv" "$root/boot/grub/grubenv" set "saved_entry=$stock"
  bootloader_make_rhizo_default grub-dropin "$rec" >/dev/null
  rm "$root/boot/vmlinuz-6.8.0-136-generic"; bootloader_regen grub-dropin >/dev/null
  out=$(bootloader_restore_default grub-dropin "$rec"); rc=$?
  check "grub-dropin restore of a removed kernel's saved entry unsets it" \
    "$rc:$out:$(grep -c '^saved_entry=' "$root/boot/grub/grubenv")" "0:restored -:0"
  printf 'GRUB_DEFAULT=0\n' > "$root/etc/default/grub.d/95-local.cfg"; bootloader_regen grub-dropin >/dev/null
  out=$(bootloader_make_rhizo_default grub-dropin "$rec" 2>&1); rc=$?
  check "grub-dropin whose later file sets GRUB_DEFAULT: refused, named, the saved entry put back, nothing recorded" \
    "$rc:$out:$(grep -c '^saved_entry=' "$root/boot/grub/grubenv"):$(cat "$rec")" \
    "1:set $rhizo as the default, but the next boot takes '0':0:"
}

# check grub's inline saved default made and restored
body_default_grub_inline() {
  local root="$1" rec="$1/record" f="$1/etc/default/grub" out rc
  local rhizo="gnulinux-advanced-abc>gnulinux-linux-rhizo-advanced-abc"
  BL_SAVED_DEFAULT=1
  bootloader_apply grub-inline "$TOK" >/dev/null
  check "grub-inline with the saved default: the block" "$(block "$f")" \
    "$BEGIN${NL}GRUB_CMDLINE_LINUX=\"\${GRUB_CMDLINE_LINUX:+\$GRUB_CMDLINE_LINUX }$TOK\"${NL}GRUB_DEFAULT=saved${NL}$END"
  bootloader_config_current grub-inline "$TOK"; check "grub-inline with the saved default: current" "$?" 0
  out=$(bootloader_make_rhizo_default grub-inline "$rec"); rc=$?
  check "grub-inline make default: rc and the entry set" "$rc:$out:$(bootloader_default_entry grub-inline)" "0:$rhizo:$rhizo"
  out=$(bootloader_restore_default grub-inline "$rec"); rc=$?
  check "grub-inline restore of none unsets saved_entry" "$rc:$out:$(bl_grub_env_get saved_entry)" "0:restored -:"
  bootloader_strip grub-inline
  check "grub-inline strip takes the saved default out with the block" "$(grep -c GRUB_DEFAULT "$f")" 0
}

# check the make-default refusals come before any change
body_default_refusals() {
  local root="$1" rec="$1/record" out rc
  printf '#!/bin/bash\nexit 1\n' > "$root/bin/chattr"
  out=$(bootloader_make_rhizo_default limine "$rec" 2>&1); rc=$?
  check "limine whose variable cannot be written: refused, named, nothing recorded, the default as it was" \
    "$rc|$out|$([[ -e "$rec" ]] && cat "$rec")|$(bootloader_default_entry limine)" \
    "1|cannot clear the immutable flag of $root/$LLE|$([[ -e "$rec" ]] && echo)|CachyOS/linux-cachyos"
  printf '#!/bin/bash\nexit 0\n' > "$root/bin/chattr"
  mv "$root/sys/firmware/efi/efivars" "$root/efivars.away"
  out=$(bootloader_rhizo_default_preflight limine 2>&1); rc=$?
  check "limine with no EFI variables: the preflight refuses, named" "$rc|$out" \
    "1|no $root/sys/firmware/efi/efivars, so this host's boot loader reads no EFI variable"
  mv "$root/efivars.away" "$root/sys/firmware/efi/efivars"
  bootloader_rhizo_default_preflight limine; check "limine with the Rhizo kernel and its variable: the preflight passes" "$?" 0
}

# check a restore whose write does not hold is refused
body_default_restore_readback() {
  local root="$1" rec="$1/record" out rc
  # shellcheck disable=SC2034
  BL_SAVED_DEFAULT=1
  bootloader_apply grub-dropin "$TOK" >/dev/null
  bootloader_make_rhizo_default grub-dropin "$rec" >/dev/null
  printf '#!/bin/bash\nexit 0\n' > "$root/bin/grub-editenv"
  out=$(bootloader_restore_default grub-dropin "$rec" 2>&1); rc=$?
  check "grub restore whose write does not hold: refused, named, the record line kept" \
    "$rc|$out|$(grep -c '^rhizo-kernel-default ' "$rec")" \
    "1|set the stored default back to '-', but it reads 'gnulinux-advanced-abc>gnulinux-7.1.0-rc1-rhizo-advanced-abc'|1"
}

# set up a limine host with installed kernels
setup_limine_kernels() {
  mkdir -p "$1/var/lib/limine" "$1/usr/lib/modules/7.2.9-1-cachyos" "$1/usr/lib/modules/7.1.0-rc1-rhizo"
  echo linux-cachyos > "$1/usr/lib/modules/7.2.9-1-cachyos/pkgbase"
  echo linux-rhizo > "$1/usr/lib/modules/7.1.0-rc1-rhizo/pkgbase"
  printf 'timeout: 5\n' > "$1/boot/limine.conf"
  : > "$1/etc/default/limine"
  cat > "$1/bin/limine-remove-post" <<'STUB'
#!/bin/bash
R=$RHIZO_BL_ROOT list=$RHIZO_BL_ROOT/var/lib/limine/removed_kernels.list
[[ -f "$list" ]] || exit 0
while read -r k; do
  grep -qx "$k" "$R"/usr/lib/modules/*/pkgbase 2>/dev/null && continue
  sed -i "/^  \/\/$k\$/d" "$R/boot/limine.conf"; rm -rf "${R:?}/boot/mid/$k"
done < "$list"
rm -f "$list"
STUB
  cat > "$1/bin/limine-update" <<'STUB'
#!/bin/bash
R=$RHIZO_BL_ROOT
[[ ! -e "$R/update-fails" ]] || { echo "limine-update: mkinitcpio failed" >&2; exit 4; }
for p in "$R"/usr/lib/modules/*/pkgbase; do
  [[ -f "$p" ]] || continue
  k=$(< "$p"); mkdir -p "$R/boot/mid/$k"; echo "vmlinuz of $k" > "$R/boot/mid/$k/vmlinuz"
  grep -qx "  //$k" "$R/boot/limine.conf" || echo "  //$k" >> "$R/boot/limine.conf"
done
[[ ! -f "$R/var/lib/limine/removed_kernels.list" ]] || "$R/bin/limine-remove-post"
STUB
  chmod +x "$1/bin/limine-update" "$1/bin/limine-remove-post"
  "$1/bin/limine-update"
}

# print a limine host's boot menu and /boot files
limine_boot_state() {
  local f
  cat "$1/boot/limine.conf"
  for f in "$1"/boot/mid/* "$1"/boot/mid/*/*; do [[ -e "$f" ]] && echo "${f#"$1"/}"; done
}

# check a joint removal of rhizo and the Rhizo kernel
body_limine_joint_removal() {
  local root="$1" list="$1/var/lib/limine/removed_kernels.list" alone joint out rc
  cp -a "$root" "$root.alone"
  echo linux-rhizo >> "$root.alone/var/lib/limine/removed_kernels.list"
  rm -r "$root.alone/usr/lib/modules/7.1.0-rc1-rhizo"
  RHIZO_BL_ROOT="$root.alone" "$root.alone/bin/limine-remove-post"
  alone=$(limine_boot_state "$root.alone")
  echo linux-rhizo >> "$list"
  out=$(bootloader_regen limine); rc=$?
  check "limine regen inside a transaction removing a kernel: rc, and the hook's record of it kept" \
    "$rc|$out|$(cat "$list" 2>&1)|$(cd "$root/var/lib/limine" && echo *)" "0||linux-rhizo|removed_kernels.list"
  rm -r "$root/usr/lib/modules/7.1.0-rc1-rhizo"
  "$root/bin/limine-remove-post"
  joint=$(limine_boot_state "$root")
  check "rhizo removed with the Rhizo kernel: the boot menu and /boot as the kernel's removal alone leaves them" \
    "$joint" "$alone"
  check "rhizo removed with the Rhizo kernel: no linux-rhizo entry and no files left" \
    "$(grep -c 'linux-rhizo' <<<"$joint")" 0
  out=$(bootloader_regen limine); rc=$?
  check "limine regen with no removal record: rc, nothing recorded" "$rc|$out|$(cd "$root/var/lib/limine" && echo *)" "0||*"
  echo linux-old > "$list.rhizo-regen"; echo linux-rhizo > "$list"
  out=$(bootloader_regen limine); rc=$?
  check "limine regen after an interrupted one: the record it left goes back onto the list, nothing left aside" \
    "$rc|$out|$(cat "$list" | tr '\n' ' ')|$(cd "$root/var/lib/limine" && echo *)" \
    "0||linux-rhizo linux-old |removed_kernels.list"
  : > "$root/update-fails"; echo linux-rhizo > "$list"
  out=$(bootloader_regen limine 2>&1); rc=$?
  rm "$root/update-fails"
  check "limine regen whose limine-update fails with a list: the exit code passed through, the list back as it was" \
    "$rc|$out|$(cat "$list")|$(cd "$root/var/lib/limine" && echo *)" \
    "4|limine-update: mkinitcpio failed|linux-rhizo|removed_kernels.list"
  echo linux-cachyos > "$list"; chmod 0555 "$root/var/lib/limine"
  out=$(bootloader_regen limine 2>&1); rc=$?
  chmod 0755 "$root/var/lib/limine"
  check_unprivileged "limine regen that cannot set the record aside: refused before the rebuild, named" \
    "$rc|$(tail -1 <<<"$out")|$(cat "$list")" "1|could not set $list aside|linux-cachyos"
}

# check a host without the Rhizo kernel is refused
body_default_no_rhizo_kernel() {
  local out rc
  out=$(bootloader_make_rhizo_default limine "$1/record" 2>&1); rc=$?
  check "limine with no Rhizo kernel entry: refused, named, nothing recorded" \
    "$rc:$out:$([[ -e "$1/record" ]] && echo recorded || echo none)" \
    "1:$1/boot/limine.conf lists no Rhizo kernel entry -- is the Rhizo kernel installed?:none"
}

# check a host with no bootloader is refused
body_nothing() {
  local err rc
  err=$(bootloader_kind 2>&1); rc=$?
  check "no bootloader: rc"                "$rc" 1
  check "no bootloader: message"           "$err" "no supported bootloader configuration found (looked for $1/etc/default/limine, $1/etc/sdboot-manage.conf, $1/etc/default/grub)"
}

# check an unsupported host is refused unless RHIZO_BOOTLOADER is set
body_unsupported() {
  local err rc
  err=$(bootloader_kind 2>&1); rc=$?
  check "unsupported host: rc"             "$rc" 1
  check "unsupported host: message"        "$err" "cannot find the bootloader on unsupported:arch unknown"
  check "unsupported host: override still wins" "$(RHIZO_BOOTLOADER=limine bootloader_kind)" limine
}

# check an ubuntu host without /etc/default/grub is refused
body_ubuntu_no_grub() {
  local err rc
  err=$(bootloader_kind 2>&1); rc=$?
  check "ubuntu without /etc/default/grub: rc" "$rc" 1
  check "ubuntu without /etc/default/grub: message" "$err" "no $1/etc/default/grub -- this host does not use GRUB"
}

# check an ubuntu host without update-grub is refused
body_ubuntu_no_update_grub() {
  local err rc
  err=$(bootloader_kind 2>&1); rc=$?
  check "ubuntu without update-grub: rc"   "$rc" 1
  check "ubuntu without update-grub: message, naming where it looked" "$err" "no update-grub in any of $1/usr/bin,\
 $1/usr/sbin, $1/bin, $1/sbin, $1/usr/local/sbin, $1/usr/local/bin -- grub2-common is not installed"
}

# check each kind's regen label and command
body_kinds() {
  local kind fn label cmd
  for kind in grub-dropin grub-inline limine sdboot; do
    case "$kind" in
      grub-dropin) label=update-grub;       cmd=/usr/sbin/update-grub ;;
      grub-inline) label=grub-mkconfig;     cmd="/usr/bin/grub-mkconfig -o /boot/grub/grub.cfg" ;;
      limine)      label=limine-update;     cmd=/usr/bin/limine-update ;;
      sdboot)      label="sdboot-manage gen"; cmd="/usr/bin/sdboot-manage gen" ;;
    esac
    check "$kind regen label" "$(bootloader_regen_label "$kind")" "$label"
    check "$kind regen command" "$(bootloader_regen_cmd "$kind")" "$cmd"
  done
  for fn in bootloader_config_file bootloader_generated bootloader_regen_label bootloader_regen_cmd bootloader_regen \
            bootloader_present bootloader_cmdline_tokens bootloader_rollback bootloader_own_tokens bootloader_strip \
            bootloader_regen_installed bootloader_target bootloader_regenerator bootloader_host_tokens \
            bootloader_android_tokens bootloader_regen_host_cmd bootloader_restore; do
    check "$fn refuses an unknown kind" "$("$fn" bogus 2>&1; echo "rc=$?")" "unknown bootloader kind 'bogus'${NL}rc=1"
  done
  for fn in bootloader_write bootloader_apply bootloader_config_current bootloader_lost bootloader_remaining \
            bootloader_leftover; do
    check "$fn refuses an unknown kind" "$("$fn" bogus "$TOK" 2>&1; echo "rc=$?")" "unknown bootloader kind 'bogus'${NL}rc=1"
  done
  check "bootloader_missing refuses an unknown kind" "$(bootloader_missing bogus "$TOK" 2>&1; echo "rc=$?")" "unknown bootloader kind 'bogus'${NL}rc=1"
}

MSG_NOTOK="no tokens given"
MSG_SPACING="; tokens are separated by single spaces only"
# print the bad character token message
msg_char() { echo "token '$1' has a character outside [A-Za-z0-9_.,=:/+@-]"; }

# check the limine token validation
body_limine_tokens_refused() {
  local root="$1" f="$1/etc/default/limine" i t lbl err rc
  # shellcheck disable=SC2016
  local -a bad=('' '   ' 'a"b' '$HOME' '`id`' 'x=$(id)' 'a;b' '*' "$TOK a\"b"
                " $TOK" "$TOK " $'a\tb' $'a\nb' "a  b" $'a\n' $'\ta')
  # shellcheck disable=SC2016
  local -a want=("$MSG_NOTOK" "$MSG_NOTOK" "$(msg_char 'a"b')" "$(msg_char '$HOME')" "$(msg_char '`id`')" "$(msg_char 'x=$(id)')" "$(msg_char 'a;b')" "$(msg_char '*')" "$(msg_char 'a"b')"
                 "the token string has a leading space$MSG_SPACING" "the token string has a trailing space$MSG_SPACING"
                 "the token string has a tab$MSG_SPACING" "the token string has a newline$MSG_SPACING" "the token string has a double space$MSG_SPACING"
                 "the token string has a newline$MSG_SPACING" "the token string has a tab$MSG_SPACING")
  cp "$f" "$root/before"
  for i in "${!bad[@]}"; do
    t="${bad[$i]}"
    printf -v lbl '%q' "$t"
    err=$(bootloader_write limine "$t" 2>&1 >/dev/null); rc=$?
    check "limine write refuses $lbl: rc"           "$rc" 1
    check "limine write refuses $lbl: message"      "$err" "${want[$i]}"
    check "limine write refuses $lbl: file untouched" "$(cmp_rc "$root/before" "$f")" 0
    bootloader_apply limine "$t" >/dev/null 2>&1;   check "limine apply refuses $lbl: rc" "$?" 1
    check "limine apply refuses $lbl: nothing regenerated" "$(ncalls "$root" limine-update)" 0
    err=$(bootloader_config_current limine "$t" 2>&1); rc=$?
    check "limine config_current refuses $lbl"      "$rc:$err" "1:${want[$i]}"
    err=$(bootloader_missing limine "$t" 2>&1); rc=$?
    check "limine missing refuses $lbl"             "$rc:$err" "1:${want[$i]}"
  done
  bootloader_apply limine "lsm=capability,landlock,selinux console=ttyS0,115200 a:b/c+d@e-f" >/dev/null
  check "limine accepts , : / + @ - in a token"    "$?" 0
  for t in "$REAL_TOK" "$REAL_TOK_LSM"; do
    bootloader_apply limine "$t" >/dev/null;       check "limine accepts the bootstrap's own tokens: rc" "$?" 0
    check "limine bootstrap tokens: nothing missing" "$(bootloader_missing limine "$t")" ""
    bootloader_config_current limine "$t";         check "limine bootstrap tokens: config current" "$?" 0
  done
}

# test grub-dropin writes with bad tokens
body_grub_dropin_tokens_refused() {
  local root="$1" d="$1/etc/default/grub.d/90-rhizo.cfg" t lbl
  # shellcheck disable=SC2016
  for t in '' 'a"b' '$HOME' '`id`' " $TOK" "$TOK " $'a\tb' $'a\nb' "a  b"; do
    printf -v lbl '%q' "$t"
    bootloader_write grub-dropin "$t" 2>/dev/null; check "grub-dropin write refuses $lbl: rc" "$?" 1
    check "grub-dropin write refuses $lbl: no file" "$([[ -e "$d" ]]; echo $?)" 1
  done
}

# check a failing strip awk leaves the grub file untouched
body_strip_fails() {
  local root="$1" f="$1/etc/default/grub" err rc
  cp "$f" "$root/before"
  listing "$root" > "$root/listing"
  failing_strip_awk "$root"
  err=$(bootloader_write grub-inline "$TOK" 2>&1); rc=$?
  check "grub-inline write with a failing strip: rc"      "$rc" 1
  check "grub-inline write with a failing strip: message" "$err" "awk: cannot read${NL}could not write $f"
  check "grub-inline write with a failing strip: file untouched" "$(cmp_rc "$root/before" "$f")" 0
  check "grub-inline write with a failing strip: no temp file left" "$(listing "$root")" "$(< "$root/listing")"
  bootloader_apply grub-inline "$TOK" >/dev/null 2>&1; check "grub-inline apply with a failing strip: rc" "$?" 1
  check "grub-inline apply with a failing strip: nothing regenerated" "$(ncalls "$root" grub-mkconfig)" 0
  bootloader_rollback grub-inline 2>/dev/null; check "grub-inline failed write leaves nothing to roll back" "$?" 1
  rm "$root/bin/awk"
  hash -r
  bootloader_write grub-inline "$TOK"
  cp "$f" "$root/withblock"
  failing_strip_awk "$root"
  err=$(bootloader_strip grub-inline 2>&1); rc=$?
  check "grub-inline strip with a failing strip: rc"      "$rc" 1
  check "grub-inline strip with a failing strip: message" "$err" "awk: cannot read${NL}could not write $f"
  check "grub-inline strip with a failing strip: file untouched" "$(cmp_rc "$root/withblock" "$f")" 0
  check "grub-inline strip with a failing strip: no temp file left" "$(listing "$root")" "$(< "$root/listing")"
}

# check a failing strip awk leaves the limine file untouched
body_limine_strip_fails() {
  local root="$1" f="$1/etc/default/limine" err rc
  cp "$f" "$root/before"
  failing_strip_awk "$root"
  err=$(bootloader_write limine "$TOK" 2>&1); rc=$?
  check "limine write with a failing strip: rc"      "$rc" 1
  check "limine write with a failing strip: message" "$err" "awk: cannot read${NL}could not write $f"
  check "limine write with a failing strip: file untouched" "$(cmp_rc "$root/before" "$f")" 0
}

# check a failing chmod leaves the grub file untouched
body_replace_cleanup() {
  local root="$1" f="$1/etc/default/grub" err rc
  cp "$f" "$root/before"
  listing "$root" > "$root/listing"
  printf '#!/bin/bash\nexit 1\n' > "$root/bin/chmod"
  "$TMP/tools/chmod" +x "$root/bin/chmod"
  hash -r
  err=$(bootloader_write grub-inline "$TOK" 2>&1); rc=$?
  check "grub-inline write with a failing chmod: rc"      "$rc" 1
  check "grub-inline write with a failing chmod: message" "$err" "could not write $f"
  check "grub-inline write with a failing chmod: file untouched" "$(cmp_rc "$root/before" "$f")" 0
  check "grub-inline write with a failing chmod: temp file removed" "$(listing "$root")" "$(< "$root/listing")"
}

# check a grub-inline write syncs the finished temp file before the rename
body_replace_sync() {
  local root="$1"
  cat > "$root/bin/sync" <<'STUB'
#!/bin/bash
echo "sync tmp=$([[ -e "$1" ]] && echo yes || echo no) tmp-has-block=$(grep -c '^# >>> rhizo$' "$1") target-has-block=$(grep -c '^# >>> rhizo$' "$RHIZO_BL_ROOT/etc/default/grub")" >> "$RHIZO_BL_ROOT/sync.log"
STUB
  chmod +x "$root/bin/sync"
  hash -r
  bootloader_write grub-inline "$TOK"
  check "grub-inline write syncs the finished temp file before the rename" "$(< "$root/sync.log")" "sync tmp=yes tmp-has-block=1 target-has-block=0"
}

# check a symlinked limine config stays a symlink
body_limine_symlink() {
  local root="$1" f="$1/etc/default/limine" real="$1/real-limine"
  cp "$real" "$root/before"
  bootloader_apply limine "$TOK" >/dev/null;  check "limine symlinked config: apply rc" "$?" 0
  check "limine symlinked config stays a symlink" "$([[ -L "$f" ]] && echo 0 || echo 1)" 0
  check "limine symlinked config: the target carries the block" "$(block "$real")" "$BEGIN${NL}KERNEL_CMDLINE[default]+=\" $TOK\"${NL}$END"
  check "limine symlinked config: nothing missing" "$(bootloader_missing limine "$TOK")" ""
  bootloader_rollback limine >/dev/null;      check "limine symlinked config: rollback rc" "$?" 0
  check "limine symlinked config: rollback keeps the symlink" "$([[ -L "$f" ]] && echo 0 || echo 1)" 0
  check "limine symlinked config: rollback restores the target" "$(cmp_rc "$root/before" "$real")" 0
  bootloader_write limine "$TOK"
  bootloader_strip limine;                    check "limine symlinked config: strip rc" "$?" 0
  check "limine symlinked config: strip keeps the symlink" "$([[ -L "$f" ]] && echo 0 || echo 1)" 0
  check "limine symlinked config: strip restores the target" "$(cmp_rc "$root/before" "$real")" 0
}

# check a strip of a limine file with no final newline
body_limine_remove_no_newline() {
  local root="$1" f="$1/etc/default/limine" inode
  printf '%s\n%s' "$LIMINE_ESP" "$LIMINE_BASE" > "$f"
  cp "$f" "$root/before"
  inode=$(stat -c %i "$f")
  bootloader_strip limine;                    check "limine strip without a block or final newline: rc" "$?" 0
  check "limine strip without a block or final newline: bytes unchanged" "$(cmp_rc "$root/before" "$f")" 0
  check "limine strip without a block or final newline: same inode" "$(stat -c %i "$f")" "$inode"
}

# check each limine default with no usable base is refused
body_limine_no_plain_base() {
  local root="$1" f="$1/etc/default/limine" v err rc
  local -a variants=('KERNEL_CMDLINE[default]+=""' 'KERNEL_CMDLINE[default]+=" "' '#KERNEL_CMDLINE[default]+="quiet root=UUID=abc"' '#KERNEL_CMDLINE[default]="quiet root=UUID=abc"' 'KERNEL_CMDLINE[other]="quiet"')
  for v in "${variants[@]}"; do
    limine_default "$root" "$LIMINE_ESP" "$v" "$LIMINE_ORDER"
    cp "$f" "$root/before"
    err=$(bootloader_apply limine "$TOK" 2>&1 >/dev/null); rc=$?
    check "limine refuses $v as a base: rc"      "$rc" 1
    check "limine refuses $v as a base: message" "$err" "$(limine_no_base "$f")"
    check "limine refuses $v as a base: file untouched" "$(cmp_rc "$root/before" "$f")" 0
    check "limine refuses $v as a base: nothing regenerated" "$(ncalls "$root" limine-update)" 0
  done
}

# check an append-only default is a base
body_limine_append_base() {
  local root="$1" f="$1/etc/default/limine" v rc
  local -a variants=("KERNEL_CMDLINE[default]+=\"$LIMINE_CMDLINE\"" 'KERNEL_CMDLINE["default"]+=" quiet root=UUID=abc"')
  for v in "${variants[@]}"; do
    limine_default "$root" "$LIMINE_ESP" "$v" "$LIMINE_ORDER"
    bootloader_apply limine "$TOK" >/dev/null; rc=$?
    check "limine takes $v as a base: rc" "$rc" 0
    check "limine takes $v as a base: block after it, in the host's spelling" "$(block "$f" | sed -n 2p)" "${v%%+=*}+=\" $TOK\""
    check "limine takes $v as a base: regenerated once" "$(ncalls "$root" limine-update)" 1
    check "limine takes $v as a base: nothing missing" "$(bootloader_missing limine "$TOK")" ""
  done
  check "limine append-only base: the base's tokens kept after rhizo's" \
    "$(grep -c "cmdline: $TOK quiet root=UUID=abc\$" "$root/boot/limine.conf")" 1
}

# check an sdboot-manage config with no LINUX_OPTIONS base
body_sdboot_no_base() {
  local root="$1" f="$1/etc/sdboot-manage.conf" v err rc
  local -a variants=('REMOVE_EXISTING="no"' 'LINUX_OPTIONS+=" quiet"' '#LINUX_OPTIONS="quiet"')
  for v in "${variants[@]}"; do
    printf '%s\n' "$v" > "$f"
    : > "$root/calls"
    cp "$f" "$root/before"
    err=$(bootloader_apply sdboot "$TOK" 2>&1 >/dev/null); rc=$?
    check "sdboot refuses $v as a base: rc"      "$rc" 1
    check "sdboot refuses $v as a base: message" "$err" "$f sets no LINUX_OPTIONS -- copy the running cmdline into LINUX_OPTIONS there first"
    check "sdboot refuses $v as a base: file untouched" "$(cmp_rc "$root/before" "$f")" 0
    check "sdboot refuses $v as a base: nothing regenerated" "$(ncalls "$root" sdboot-manage)" 0
  done
}

# check a CRLF limine file keeps its CRs
body_limine_crlf() {
  local root="$1" f="$1/etc/default/limine"
  printf '%s\r\n' "$LIMINE_ESP" "$LIMINE_BASE" "$BEGIN" 'KERNEL_CMDLINE[default]+=" old=1"' "$END" "$LIMINE_ORDER" > "$f"
  bootloader_present limine;                  check "limine marker with a CR is a block" "$?" 0
  check "limine CRLF block: own tokens without the CR" "$(bootloader_own_tokens limine)" "old=1"
  bootloader_write limine "$TOK";             check "limine CRLF file: write rc" "$?" 0
  printf '%s\r\n' "$LIMINE_ESP" "$LIMINE_BASE" "$LIMINE_ORDER" > "$root/expected"
  printf '%s\n' "$BEGIN" "KERNEL_CMDLINE[default]+=\" $TOK\"" "$END" >> "$root/expected"
  check "limine CRLF file: one block after write, other lines keep their CR" "$(cmp_rc "$root/expected" "$f")" 0
  bootloader_strip limine;                    check "limine CRLF file: strip rc" "$?" 0
  printf '%s\r\n' "$LIMINE_ESP" "$LIMINE_BASE" "$LIMINE_ORDER" > "$root/expected"
  check "limine CRLF file: no block after the strip, other lines keep their CR" "$(cmp_rc "$root/expected" "$f")" 0
  bootloader_present limine;                  check "limine CRLF file: not present after the strip" "$?" 1
}

LIMINE_SORTED="nowatchdog${NL}quiet${NL}root=UUID=44444444-4444-4444-8444-444444444444${NL}rootflags=subvol=/@${NL}rw${NL}splash${NL}zswap.enabled=0"
LIMINE_SORTED_SPACED=" nowatchdog quiet root=UUID=44444444-4444-4444-8444-444444444444 rootflags=subvol=/@ rw splash zswap.enabled=0"

# check a limine write over a blind base
body_limine_lost() {
  local root="$1" f="$1/etc/default/limine" before err rc
  mkdir -p "$root/etc/kernel"
  echo "$LIMINE_CMDLINE" > "$root/etc/kernel/cmdline"
  limine_default "$root" "$LIMINE_ESP" 'KERNEL_CMDLINE[default]=""' "$LIMINE_ORDER"
  cp "$f" "$root/before"
  before=$(bootloader_cmdline_tokens limine)
  check "limine cmdline tokens: sorted and unique"  "$before" "$LIMINE_SORTED"
  check "limine nothing lost before a write"        "$(bootloader_lost limine "$before")" ""
  bootloader_write limine "$TOK";                   check "limine blind base: write rc" "$?" 0
  bootloader_regen limine >/dev/null
  check "limine blind base: the tokens arrived"     "$(bootloader_missing limine "$TOK")" ""
  check "limine blind base: only rhizo's tokens are left" "$(bootloader_cmdline_tokens limine)" "androidboot.hardware=rhizo${NL}enforcing=0${NL}loop.max_loop=64${NL}security=selinux"
  check "limine blind base: the base's tokens are lost" "$(bootloader_lost limine "$before")" "$LIMINE_SORTED_SPACED"
  bootloader_rollback limine >/dev/null;            check "limine rollback rc" "$?" 0
  check "limine rollback restores the file"        "$(cmp_rc "$root/before" "$f")" 0
  check "limine rollback: cmdline is the original" "$(bootloader_cmdline_tokens limine)" "$before"
  check "limine rollback: nothing lost"            "$(bootloader_lost limine "$before")" ""
  check "limine rollback regenerates"              "$(ncalls "$root" limine-update)" 2
  err=$(bootloader_rollback limine 2>&1); rc=$?
  check "limine second rollback: rc"               "$rc" 1
  check "limine second rollback: message"          "$err" "no bootloader_write for limine in this shell to roll back"
}

# check a clean limine apply and its rollback
body_limine_lost_clean() {
  local root="$1" f="$1/etc/default/limine" before err rc
  cp "$f" "$root/before"
  before=$(bootloader_cmdline_tokens limine)
  check "limine cmdline tokens before apply"      "$before" "$LIMINE_SORTED"
  bootloader_apply limine "$TOK" >/dev/null
  check "limine clean apply loses nothing"        "$(bootloader_lost limine "$before")" ""
  bootloader_rollback limine >/dev/null;          check "limine rollback after apply: rc" "$?" 0
  check "limine rollback after apply: file restored" "$(cmp_rc "$root/before" "$f")" 0
  check "limine rollback after apply: tokens gone"   "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  err=$(bootloader_rollback sdboot 2>&1); rc=$?
  check "rollback for a kind that was not written: rc" "$rc" 1
}

# check limine's lost tokens are whole tokens taken from any one cmdline
body_limine_lost_words() {
  local root="$1" conf="$1/boot/limine.conf" before
  { limine_os CachyOS; limine_entry a 'quiet root=UUID=abc rw'; } > "$conf"
  before=$(bootloader_cmdline_tokens limine)
  { limine_os CachyOS; limine_entry a 'quiet root=UUID=abcd rw'; } > "$conf"
  check "limine lost matches whole tokens"        "$(bootloader_lost limine "$before")" " root=UUID=abc"
  { limine_os X; limine_entry a 'a b'; limine_entry b 'b c'; } > "$conf"
  before=$(bootloader_cmdline_tokens limine)
  check "limine cmdline tokens of two entries are unique" "$before" "a${NL}b${NL}c"
  { limine_os X; limine_entry a 'a b'; limine_entry b c; } > "$conf"
  check "limine a token on any one cmdline is not lost" "$(bootloader_lost limine "$before")" ""
  { limine_os X; limine_entry a a; limine_entry b c; } > "$conf"
  check "limine a token on no cmdline is lost"    "$(bootloader_lost limine "$before")" " b"
  check "limine lost takes a space-separated before" "$(bootloader_lost limine "a b c")" " b"
  check "limine lost takes a newline-separated before" "$(bootloader_lost limine $'a\nb\nc')" " b"
  check "limine lost takes a mixed before"        "$(bootloader_lost limine $'a b\nc')" " b"
  check "limine lost takes tokens as they are, without globbing" "$(bootloader_lost limine '*')" " *"
  rm "$conf"
  sed -i '/^ESP_PATH=/d' "$root/etc/default/limine"
  check "limine without ESP_PATH or limine.conf: everything is lost" "$(bootloader_lost limine "$before")" " a b c"
}

# check a drop-in overriding the sdboot options
body_sdboot_lost() {
  local root="$1" f="$1/etc/sdboot-manage.conf" d="$1/etc/sdboot-manage.conf.d/50-local.conf" before
  mkdir -p "${d%/*}"
  printf 'LINUX_OPTIONS="nowatchdog quiet"\n' > "$d"
  run_stub "$root/bin/sdboot-manage" gen
  : > "$root/calls"
  cp "$f" "$root/before"
  before=$(bootloader_cmdline_tokens sdboot)
  check "sdboot cmdline tokens: sorted and unique, the drop-in's options" "$before" \
    "nowatchdog${NL}quiet${NL}root=UUID=abc${NL}rootflags=subvol=/@${NL}rw"
  check "sdboot nothing lost before a write"       "$(bootloader_lost sdboot "$before")" ""
  bootloader_write sdboot "$TOK";                  check "sdboot under a drop-in: write rc" "$?" 0
  bootloader_regen sdboot >/dev/null
  check "sdboot under a drop-in: the tokens never arrive" "$(bootloader_missing sdboot "$TOK")" "$ALL_MISSING"
  check "sdboot under a drop-in: nothing of the base lost" "$(bootloader_lost sdboot "$before")" ""
  check "sdboot under a drop-in: its options are the host's own, the drop-in's alone" \
    "$(bootloader_token_source sdboot quiet)" "LINUX_OPTIONS in $d"
  bootloader_rollback sdboot >/dev/null;           check "sdboot rollback rc" "$?" 0
  check "sdboot rollback restores the file"        "$(cmp_rc "$root/before" "$f")" 0
  check "sdboot rollback: cmdline is the original" "$(bootloader_cmdline_tokens sdboot)" "$before"
  check "sdboot rollback: nothing lost"            "$(bootloader_lost sdboot "$before")" ""
  check "sdboot rollback regenerates"              "$(ncalls "$root" sdboot-manage)" 2
}

# check a clean sd-boot apply and its rollback
body_sdboot_lost_clean() {
  local root="$1" f="$1/etc/sdboot-manage.conf" before
  cp "$f" "$root/before"
  before=$(bootloader_cmdline_tokens sdboot)
  bootloader_apply sdboot "$TOK" >/dev/null
  check "sdboot clean apply loses nothing"         "$(bootloader_lost sdboot "$before")" ""
  bootloader_rollback sdboot >/dev/null;           check "sdboot rollback after apply: rc" "$?" 0
  check "sdboot rollback after apply: file restored" "$(cmp_rc "$root/before" "$f")" 0
}

# check a grub-inline rollback
body_grub_inline_rollback() {
  local root="$1" f="$1/etc/default/grub" before err rc
  printf 'GRUB_CMDLINE_LINUX=""' > "$f"
  run_stub "$root/bin/grub-mkconfig" -o "$root/boot/grub/grub.cfg"
  : > "$root/calls"
  cp "$f" "$root/before"
  before=$(bootloader_cmdline_tokens grub-inline)
  check "grub-inline cmdline tokens skip the first two words" "$before" "root=UUID=abc${NL}rw"
  bootloader_apply grub-inline "$TOK" >/dev/null
  check "grub-inline clean apply loses nothing"    "$(bootloader_lost grub-inline "$before")" ""
  bootloader_rollback grub-inline >/dev/null;      check "grub-inline rollback rc" "$?" 0
  check "grub-inline rollback restores a file without a final newline" "$(cmp_rc "$root/before" "$f")" 0
  check "grub-inline rollback: cmdline is the original" "$(bootloader_cmdline_tokens grub-inline)" "$before"
  check "grub-inline rollback regenerates"         "$(ncalls "$root" grub-mkconfig)" 2
  bootloader_write grub-inline "$TOK"
  rm "$f"
  err=$(bootloader_rollback grub-inline 2>&1); rc=$?
  check "grub-inline rollback when the file is gone: rc"      "$rc" 1
  check "grub-inline rollback when the file is gone: message" "${err##*$'\n'}" "could not restore $f"
  compgen -G "$f.*" >/dev/null;                    check "grub-inline rollback when the file is gone: no temp file left" "$?" 1
}

# check a limine rollback with a failing regeneration
body_limine_rollback_regen_fails() {
  local root="$1" f="$1/etc/default/limine" rc
  cp "$f" "$root/before"
  bootloader_apply limine "$TOK" >/dev/null
  : > "$root/regen-fails"
  bootloader_rollback limine >"$root/out" 2>"$root/err"; rc=$?
  check "limine rollback with a failing regeneration: rc" "$rc" 3
  check "limine rollback with a failing regeneration: the regeneration's output" "$(< "$root/out")" "regeneration failed"
  check "limine rollback with a failing regeneration: no other message" "$(< "$root/err")" ""
  check "limine rollback with a failing regeneration: file restored" "$(cmp_rc "$root/before" "$f")" 0
  rm "$root/regen-fails"
  bootloader_rollback limine >/dev/null;           check "limine rollback retried after the regeneration works: rc" "$?" 0
  check "limine rollback retried: cmdline lacks the tokens" "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
}

# check a grub-dropin rollback removes a new drop-in
body_grub_dropin_rollback() {
  local root="$1" d="$1/etc/default/grub.d/90-rhizo.cfg" before err rc
  err=$(bootloader_rollback grub-dropin 2>&1); rc=$?
  check "grub-dropin rollback with nothing saved: rc"      "$rc" 1
  check "grub-dropin rollback with nothing saved: message" "$err" "no bootloader_write for grub-dropin in this shell to roll back"
  before=$(bootloader_cmdline_tokens grub-dropin)
  check "grub-dropin cmdline tokens skip the first two words" "$before" "console=ttyS0${NL}ro${NL}root=UUID=abc"
  bootloader_apply grub-dropin "$TOK" >/dev/null
  check "grub-dropin clean apply loses nothing"    "$(bootloader_lost grub-dropin "$before")" ""
  bootloader_rollback grub-dropin >/dev/null;      check "grub-dropin rollback rc" "$?" 0
  check "grub-dropin rollback removes a drop-in that was not there" "$([[ -e "$d" ]] && echo 0 || echo 1)" 1
  check "grub-dropin rollback: cmdline is the original" "$(bootloader_cmdline_tokens grub-dropin)" "$before"
  check "grub-dropin rollback regenerates"         "$(ncalls "$root" update-grub)" 2
  bl_grub_dropin_text "$TOK" > "$root/first"
  bootloader_write grub-dropin "$TOK"
  bootloader_write grub-dropin "$TOK extra=1"
  bootloader_rollback grub-dropin >/dev/null;      check "grub-dropin rollback over an earlier drop-in: rc" "$?" 0
  check "grub-dropin rollback puts the earlier drop-in back" "$(cmp_rc "$root/first" "$d")" 0
  bootloader_write grub-dropin "$TOK"
  bootloader_write grub-dropin "" 2>/dev/null
  err=$(bootloader_rollback grub-dropin 2>&1); rc=$?
  check "grub-dropin a refused write clears what was saved: rc" "$rc" 1
  check "grub-dropin a refused write clears what was saved: drop-in kept" "$([[ -e "$d" ]] && echo 0 || echo 1)" 0
  bootloader_write grub-dropin "$TOK"
  err=$(bootloader_rollback limine 2>&1); rc=$?
  check "rollback for another kind: rc"            "$rc" 1
  check "rollback for another kind: message"       "$err" "no bootloader_write for limine in this shell to roll back"
}

# test failed grub-dropin writes and rollback
body_grub_dropin_atomic() {
  local root="$1" d="$1/etc/default/grub.d/90-rhizo.cfg" orig err rc
  orig=$(declare -f bl_grub_dropin_text)
  # shellcheck disable=SC2317
  bl_grub_dropin_text() { echo partial; return 1; }
  err=$(bootloader_write grub-dropin "$TOK" 2>&1); rc=$?
  check "grub-dropin failing write with no drop-in before: rc"      "$rc" 1
  check "grub-dropin failing write with no drop-in before: message" "$err" "could not write $d"
  check "grub-dropin failing write with no drop-in before: no file" "$([[ -e "$d" ]] && echo 0 || echo 1)" 1
  compgen -G "$d.*" >/dev/null;                    check "grub-dropin failing write with no drop-in before: no temp file" "$?" 1
  eval "$orig"
  bootloader_write grub-dropin "$TOK";             check "grub-dropin write after a failed one: rc" "$?" 0
  bootloader_rollback grub-dropin >/dev/null;      check "grub-dropin rollback after a failed then a good write: rc" "$?" 0
  check "grub-dropin rollback after a failed then a good write: no drop-in" "$([[ -e "$d" ]] && echo 0 || echo 1)" 1
  bootloader_write grub-dropin "$TOK"
  cp "$d" "$root/first"
  chmod 600 "$d"
  # shellcheck disable=SC2317
  bl_grub_dropin_text() { echo partial; return 1; }
  bootloader_write grub-dropin "$TOK extra=1" 2>/dev/null; check "grub-dropin failing write over a drop-in: rc" "$?" 1
  check "grub-dropin failing write over a drop-in: previous drop-in byte-identical" "$(cmp_rc "$root/first" "$d")" 0
  compgen -G "$d.*" >/dev/null;                    check "grub-dropin failing write over a drop-in: no temp file" "$?" 1
  eval "$orig"
  bootloader_write grub-dropin "$TOK extra=1"
  check "grub-dropin write over a drop-in keeps its mode" "$(stat -c %a "$d")" 600
  bootloader_rollback grub-dropin >/dev/null;      check "grub-dropin rollback after a failed then a good write over a drop-in: rc" "$?" 0
  check "grub-dropin rollback restores the previous drop-in" "$(cmp_rc "$root/first" "$d")" 0
  check "grub-dropin rollback keeps the drop-in's mode" "$(stat -c %a "$d")" 600
}

# check a write or apply captured in a subshell leaves nothing to roll back
body_capture_rules() {
  local root="$1" f="$1/etc/default/limine" out err rc
  cp "$f" "$root/before"
  bootloader_write limine "$TOK"
  out=$(bootloader_regen limine)
  check "limine regen output captured on its own"  "$out" "Updating limine.conf"
  bootloader_rollback limine >/dev/null;           check "limine rollback after write and a captured regen: rc" "$?" 0
  check "limine rollback after write and a captured regen: file restored" "$(cmp_rc "$root/before" "$f")" 0
  out=$(bootloader_write limine "$TOK")
  err=$(bootloader_rollback limine 2>&1); rc=$?
  check "limine a write captured with \$(...) leaves nothing to roll back: rc" "$rc" 1
  check "limine a write captured with \$(...) leaves nothing to roll back: message" "$err" "no bootloader_write for limine in this shell to roll back"
  out=$(bootloader_apply limine "$TOK")
  err=$(bootloader_rollback limine 2>&1); rc=$?
  check "limine an apply captured with \$(...) leaves nothing to roll back: rc" "$rc" 1
}

# test the bootloader_holders output
body_holders() {
  local root="$1" out err rc
  check "no holder on a new limine host" "$(bootloader_holders; echo "rc=$?")" "rc=0"
  bootloader_write limine "$TOK"
  check "limine's block makes it a holder" "$(bootloader_holders)" limine
  mkdir -p "$root/etc/default/grub.d"
  printf 'GRUB_CMDLINE_LINUX=""\n' > "$root/etc/default/grub"
  printf 'LINUX_OPTIONS="quiet"\n' > "$root/etc/sdboot-manage.conf"
  bootloader_write grub-inline "$TOK"
  bootloader_write grub-dropin "$TOK"
  bootloader_write sdboot "$TOK"
  check "every holder, in BL_KINDS order" "$(bootloader_holders)" "grub-dropin${NL}grub-inline${NL}limine${NL}sdboot"
  printf 'LINUX_OPTIONS="quiet"\n' > "$root/etc/sdboot-manage.conf"
  check "a file without the block holds nothing" "$(bootloader_holders)" "grub-dropin${NL}grub-inline${NL}limine"
  chmod 000 "$root/etc/default/limine"
  out=$(bootloader_holders 2>"$root/err"); rc=$?
  err=$(< "$root/err")
  chmod 644 "$root/etc/default/limine"
  check_unprivileged "a config file this uid cannot read: holders cannot tell" "$rc" 2
  check_unprivileged "a config file this uid cannot read: no partial answer" "$out" ""
  check_unprivileged "a config file this uid cannot read: named with the uid, once" "$err" \
    "cannot read $root/etc/default/limine as uid $EUID"
  check_unprivileged "a config file this uid cannot read: present cannot tell either" \
    "$(chmod 000 "$root/etc/default/limine"; bootloader_present limine 2>&1; echo "rc=$?"
       chmod 644 "$root/etc/default/limine")" "cannot read $root/etc/default/limine as uid $EUID${NL}rc=2"
  failing_block_awk "$root"
  out=$(bootloader_holders 2>"$root/err"); rc=$?
  err=$(< "$root/err")
  rm "$root/bin/awk"; hash -r
  check "a config file awk cannot read: rc"     "$rc" 1
  check "a config file awk cannot read: no partial answer" "$out" ""
  check "a config file awk cannot read: named"  "${err##*$'\n'}" "cannot read $root/etc/default/grub: awk exited 2"
}

# check a limine strip restores the file and regenerates nothing
body_strip() {
  local root="$1" f="$1/etc/default/limine" err rc
  cp "$f" "$root/before"
  bootloader_apply limine "$TOK" >/dev/null
  cp "$root/boot/limine.conf" "$root/generated"
  : > "$root/calls"
  bootloader_strip limine;                 check "limine strip rc" "$?" 0
  check "limine strip restores the file"   "$(cmp_rc "$root/before" "$f")" 0
  check "limine strip leaves the generated config" "$(cmp_rc "$root/generated" "$root/boot/limine.conf")" 0
  check "limine strip regenerates nothing" "$(ncalls "$root" limine-update)" 0
  bootloader_strip limine;                 check "limine strip without a block: rc" "$?" 0
  check "limine strip without a block: file byte-identical" "$(cmp_rc "$root/before" "$f")" 0
  printf '%s\n' "$LIMINE_ESP" "$BEGIN" > "$f"
  cp "$f" "$root/unterminated"
  err=$(bootloader_strip limine 2>&1); rc=$?
  check "limine strip of an unterminated block: refused" "$rc:$err" "1:$f has a '$BEGIN' line with no '$END' line after it -- fix the file by hand"
  check "limine strip of an unterminated block: file untouched" "$(cmp_rc "$root/unterminated" "$f")" 0
}

# check a grub-dropin strip removes the file and regenerates nothing
body_grub_dropin_strip() {
  local root="$1" d="$1/etc/default/grub.d/90-rhizo.cfg"
  bootloader_apply grub-dropin "$TOK" >/dev/null
  : > "$root/calls"
  bootloader_strip grub-dropin;            check "grub-dropin strip rc" "$?" 0
  check "grub-dropin strip removes the file" "$([[ -e "$d" ]] && echo 0 || echo 1)" 1
  check "grub-dropin strip regenerates nothing" "$(ncalls "$root" update-grub)" 0
  check "grub-dropin strip leaves grub.cfg's tokens" "$(bootloader_missing grub-dropin "$TOK")" ""
}

# check which tokens a limine cmdline still carries
body_remaining() {
  local root="$1" conf="$1/boot/limine.conf"
  { limine_os X; limine_entry a 'a b'; limine_entry b c; } > "$conf"
  check "remaining: the tokens some cmdline still carries" "$(bootloader_remaining limine "a b d")" " a b"
  check "remaining: a newline-separated list"   "$(bootloader_remaining limine $'c\nd')" " c"
  check "remaining: whole tokens only"          "$(bootloader_remaining limine "a=1 bb c")" " c"
  check "remaining: tokens as they are, without globbing" "$(bootloader_remaining limine '*')" ""
  check "remaining: each token once, first seen first" "$(bootloader_remaining limine "b a b c a")" " b a c"
  check "lost: each token once"                 "$(bootloader_lost limine "d e d")" " d e"
  { limine_os X; limine_entry a 'a b'
    printf '%s\n' '     //Snapshots' '     ///2 │ 2026-10-01' '     ////old' '     cmdline: c'; } > "$conf"
  check "remaining: snapshots are not a next boot" "$(bootloader_remaining limine "a c")" " a"
  chmod 000 "$conf"
  check_unprivileged "remaining: a limine.conf this uid cannot read cannot be told" \
    "$(bootloader_remaining limine "a" 2>/dev/null; echo "rc=$?")" "rc=2"
  check_unprivileged "cmdline tokens: a limine.conf this uid cannot read cannot be told" \
    "$(bootloader_cmdline_tokens limine 2>/dev/null; echo "rc=$?")" "rc=2"
  chmod 644 "$conf"
  rm "$conf"
  check "remaining: no limine.conf carries nothing" "$(bootloader_remaining limine "a b")" ""
}

# test unreadable sdboot entry files
body_sdboot_unreadable() {
  local root="$1" e="$1/boot/loader/entries"
  touch "$root/boot/vmlinuz-z"
  printf 'title Z\noptions a b\n' > "$e/z.conf"
  chmod 000 "$e/linux-cachyos.conf"
  check_unprivileged "sdboot cmdline tokens: an entry this uid cannot read, before a readable one, cannot be told" \
    "$(bootloader_cmdline_tokens sdboot 2>&1; echo "rc=$?")" "cannot read $e/linux-cachyos.conf as uid $EUID${NL}rc=2"
  chmod 644 "$e/linux-cachyos.conf"
}

# check which regeneration commands are found on PATH
body_regen_installed() {
  local root="$1"
  bootloader_regen_installed limine;       check "limine-update on PATH" "$?" 0
  bootloader_regen_installed grub-inline;  check "no grub-mkconfig on PATH" "$?" 1
  bootloader_regen_installed sdboot;       check "no sdboot-manage on PATH" "$?" 1
  stub "$root/bin/sdboot-manage" <<<'exit 0'
  hash -r
  bootloader_regen_installed sdboot;       check "sdboot-manage gen's command is sdboot-manage" "$?" 0
}

# check each kind's target and the kind that regenerates it
body_regenerator() {
  local root="$1"
  check "the grub kinds write one target"  "$(bootloader_target grub-dropin) $(bootloader_target grub-inline)" \
    "grub grub"
  check "limine and sdboot write their own" "$(bootloader_target limine) $(bootloader_target sdboot)" "limine sdboot"
  check "grub-inline regenerates itself"   "$(bootloader_regenerator grub-inline)" grub-inline
  check "grub-dropin without update-grub: grub-mkconfig writes its grub.cfg" \
    "$(bootloader_regenerator grub-dropin)" grub-inline
  check "a preferred kind of another target is passed over" "$(bootloader_regenerator grub-inline limine)" grub-inline
  check "no limine-update: no regenerator" "$(bootloader_regenerator limine; echo "rc=$?")" "rc=1"
  stub "$root/bin/update-grub" <<<'exit 0'
  hash -r
  check "grub-dropin with update-grub regenerates itself" "$(bootloader_regenerator grub-dropin)" grub-dropin
  check "the preferred kind first"         "$(bootloader_regenerator grub-dropin grub-inline)" grub-inline
}

# test bootloader_host_tokens on grub files
body_grub_host_tokens() {
  local root="$1" g="$1/etc/default/grub" err rc
  # shellcheck disable=SC2016
  {
    echo "GRUB_CMDLINE_LINUX_DEFAULT='quiet splash loglevel=8'"
    echo '#GRUB_CMDLINE_LINUX="commented=1"'
    echo 'export GRUB_CMDLINE_LINUX_RECOVERY="$GRUB_CMDLINE_LINUX nomodeset" # trailing=1'
    echo 'GRUB_TIMEOUT=5'
  } >> "$g"
  # shellcheck disable=SC2016
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} local=1"' > "$root/etc/default/grub.d/50-local.cfg"
  bootloader_write grub-dropin "$TOK"
  bootloader_write grub-inline "$TOK"
  check "grub host tokens: every GRUB_CMDLINE_LINUX* of /etc/default/grub and grub.d, rhizo's own left out" \
    "$(bootloader_host_tokens grub-dropin)" \
    "console=ttyS0${NL}local=1${NL}loglevel=8${NL}nomodeset${NL}quiet${NL}splash"
  check "grub host tokens: the same for grub-inline" \
    "$(bootloader_host_tokens grub-inline)" "$(bootloader_host_tokens grub-dropin)"
  chmod 000 "$root/etc/default/grub.d/50-local.cfg"
  err=$(bootloader_host_tokens grub-dropin 2>&1 >/dev/null); rc=$?
  chmod 644 "$root/etc/default/grub.d/50-local.cfg"
  check_unprivileged "grub host tokens: an unreadable grub.d file is named" "$rc:${err##*$'\n'}" \
    "1:cannot read $root/etc/default/grub.d/50-local.cfg"
}

# check limine's host tokens
body_limine_host_tokens() {
  local root="$1"
  mkdir -p "$root/etc/kernel"
  echo "extra=1 quiet" > "$root/etc/kernel/cmdline"
  bootloader_write limine "$TOK"
  check "limine host tokens: KERNEL_CMDLINE outside rhizo's block, and /etc/kernel/cmdline" \
    "$(bootloader_host_tokens limine)" "extra=1${NL}$LIMINE_SORTED"
  chmod 000 "$root/etc/kernel/cmdline"
  check_unprivileged "limine host tokens: an unreadable /etc/kernel/cmdline is named" \
    "$(bootloader_host_tokens limine 2>&1 >/dev/null | tail -1; echo "rc=${PIPESTATUS[0]}")" \
    "cannot read $root/etc/kernel/cmdline${NL}rc=1"
  chmod 644 "$root/etc/kernel/cmdline"
}

# check sd-boot's host tokens
body_sdboot_host_tokens() {
  local root="$1"
  printf '%s\n' 'LINUX_OPTIONS="nowatchdog quiet splash"' 'LINUX_FALLBACK_OPTIONS="quiet fb=1"' 'REMOVE_EXISTING="no"' \
    > "$root/etc/sdboot-manage.conf"
  bootloader_write sdboot "$TOK"
  check "sdboot host tokens: both options variables outside rhizo's block" \
    "$(bootloader_host_tokens sdboot)" "fb=1${NL}nowatchdog${NL}quiet${NL}splash"
}

# check which carried tokens are left over
body_leftover() {
  local root="$1" conf="$1/boot/limine.conf" out err rc
  { limine_os X; limine_entry a 'a b c'; } > "$conf"
  printf 'KERNEL_CMDLINE[default]="a"\n' > "$root/etc/default/limine"
  check "leftover: carried and not the host's"  "$(bootloader_leftover limine "a b d"; echo " rc=$?")" " b rc=0"
  check "leftover: nothing carried"             "$(bootloader_leftover limine "d e"; echo "rc=$?")" "rc=0"
  check "leftover: only the host's"             "$(bootloader_leftover limine "a"; echo "rc=$?")" "rc=0"
  chmod 000 "$root/etc/default/limine"
  out=$(bootloader_leftover limine "a b d" 2>"$root/err"); rc=$?
  err=$(< "$root/err")
  chmod 644 "$root/etc/default/limine"
  check_unprivileged "leftover: an unreadable /etc/default/limine hides ESP_PATH, so limine.conf cannot be told" \
    "$rc:$out" "2:"
  check_unprivileged "leftover: an unreadable host source is named" "${err##*$'\n'}" \
    "cannot read $root/etc/default/limine as uid $EUID"
  chmod 000 "$conf"
  check_unprivileged "leftover: a limine.conf this uid cannot read cannot be told" \
    "$(bootloader_leftover limine "a" 2>/dev/null; echo "rc=$?")" "rc=2"
  chmod 644 "$conf"
  failing_cmdline_awk "$root"
  check "leftover: a limine.conf awk cannot read is a failure" \
    "$(bootloader_leftover limine "a" 2>/dev/null; echo "rc=$?")" "rc=1"
  rm "$root/bin/awk"; hash -r
}

# test readers on an unreadable limine.conf
body_wrappers_unreadable() {
  local root="$1" conf="$1/boot/limine.conf" f
  bootloader_apply limine "$TOK" >/dev/null
  chmod 000 "$conf"
  for f in bootloader_cmdline_tokens bootloader_android_tokens bootloader_remaining bootloader_lost \
           bootloader_leftover; do
    check_unprivileged "$f: a limine.conf this uid cannot read is passed on as rc 2, named" \
      "$("$f" limine security=selinux 2>&1; echo "rc=$?")" "cannot read $conf as uid $EUID${NL}rc=2"
  done
  chmod 644 "$conf"
}

# test bootloader_kind with an unsearchable limine directory
body_refind_after_blocked() {
  local root="$1"
  limine_move_esp "$root" /boot/limine
  touch "$root/boot/refind_linux.conf"
  chmod 000 "$root/boot/limine"
  check_unprivileged "a limine.conf this uid cannot see into, beside a refind_linux.conf: cannot tell, not rEFInd" \
    "$(bootloader_kind 2>&1; echo "rc=$?")" "cannot read $root/boot/limine as uid $EUID${NL}rc=2"
  chmod 755 "$root/boot/limine"
  check "the same limine.conf searchable: limine, not rEFInd" "$(bootloader_kind 2>&1; echo "rc=$?")" "limine${NL}rc=0"
}

# test bootloader_kind with a found limine.conf
body_found_kind_wins() {
  local root="$1"
  printf 'GRUB_CMDLINE_LINUX=""\n' > "$root/etc/default/grub"
  stub "$root/bin/grub-mkconfig" <<<'exit 0'
  mkdir -p "$root/boot/grub"; chmod 000 "$root/boot/grub"
  check_unprivileged "a found limine is the answer though grub's grub.cfg cannot be read" \
    "$(bootloader_kind 2>&1; echo "rc=$?")" "limine${NL}rc=0"
  chmod 755 "$root/boot/grub"
}

# check only androidboot.* tokens are read as android tokens
body_android_tokens() {
  local root="$1" conf="$1/boot/limine.conf"
  { limine_os X; limine_entry a 'root=x androidboot.hardware=rhizo security=selinux androidboot.selinux=permissive'; } \
    > "$conf"
  check "android tokens: only androidboot.*" "$(bootloader_android_tokens limine)" \
    "androidboot.hardware=rhizo${NL}androidboot.selinux=permissive"
  { limine_os X; limine_entry a 'root=x security=selinux'; } > "$conf"
  check "android tokens: none"           "$(bootloader_android_tokens limine; echo "rc=$?")" "rc=0"
}

# check an unreadable limine.conf reads as cannot tell
body_missing_unreadable() {
  local root="$1" err rc
  chmod 000 "$root/boot/limine.conf"
  err=$(bootloader_missing limine "$TOK" 2>&1 >/dev/null); rc=$?
  chmod 644 "$root/boot/limine.conf"
  check_unprivileged "missing: a limine.conf this uid cannot read cannot be told, named with the uid" "$rc:$err" \
    "2:cannot read $root/boot/limine.conf as uid $EUID"
  failing_cmdline_awk "$root"
  err=$(bootloader_missing limine "$TOK" 2>&1 >/dev/null); rc=$?
  rm "$root/bin/awk"; hash -r
  check "missing: a limine.conf awk cannot read is a failure, named" "$rc:${err##*$'\n'}" \
    "1:cannot read the cmdlines in $root/boot/limine.conf"
}

# check an unreadable grub.cfg reads as cannot tell
body_grub_missing_unreadable() {
  local root="$1" err rc
  chmod 000 "$root/boot/grub/grub.cfg"
  err=$(bootloader_missing grub-dropin "$TOK" 2>&1 >/dev/null); rc=$?
  chmod 644 "$root/boot/grub/grub.cfg"
  check_unprivileged "missing: a grub.cfg this uid cannot read cannot be told, named with the uid" "$rc:$err" \
    "2:cannot read $root/boot/grub/grub.cfg as uid $EUID"
  failing_cmdline_awk "$root"
  err=$(bootloader_missing grub-dropin "$TOK" 2>&1 >/dev/null); rc=$?
  rm "$root/bin/awk"; hash -r
  check "missing: a grub.cfg awk cannot read is a failure, named" "$rc:${err##*$'\n'}" \
    "1:cannot read the cmdlines in $root/boot/grub/grub.cfg"
}

# test bootloader readers on an unsearchable /boot
body_boot_unsearchable() {
  local root="$1" err rc
  bootloader_apply limine "$TOK" >/dev/null
  chmod 000 "$root/boot"
  err=$(bootloader_kind 2>&1); rc=$?
  check_unprivileged "unsearchable /boot: whether limine applies cannot be told" "$rc:$err" \
    "2:cannot read $root/boot as uid $EUID"
  err=$(bootloader_generated limine 2>&1); rc=$?
  check_unprivileged "unsearchable /boot: limine.conf cannot be told" "$rc:$err" "2:cannot read $root/boot as uid $EUID"
  err=$(bootloader_missing limine "$TOK" 2>&1); rc=$?
  check_unprivileged "unsearchable /boot: the cmdlines cannot be told" "$rc:$err" \
    "2:cannot read $root/boot as uid $EUID"
  chmod 755 "$root/boot"
  chmod 000 "$root/etc/default/limine"
  err=$(bootloader_own_tokens limine 2>&1); rc=$?
  chmod 644 "$root/etc/default/limine"
  check_unprivileged "unreadable /etc/default/limine: rhizo's tokens cannot be told" "$rc:$err" \
    "2:cannot read $root/etc/default/limine as uid $EUID"
}

# test an unreadable sdboot entries directory
body_sdboot_entries_unreadable() {
  local root="$1" e="$1/boot/loader/entries" err rc
  chmod 000 "$e"
  err=$(bootloader_missing sdboot "$TOK" 2>&1); rc=$?
  chmod 755 "$e"
  check_unprivileged "unreadable sdboot entries: the cmdlines cannot be told" "$rc:$err" "2:cannot read $e as uid $EUID"
}

# check the host path of each regeneration command
body_regen_host_cmd() {
  local root="$1" user="$1/home/user/bin" err
  check "no usr tree: the system directory /bin, root left out" "$(bootloader_regen_host_cmd grub-dropin)" \
    "/bin/update-grub"
  link_usr "$root"
  check "update-grub at its usual path"     "$(bootloader_regen_host_cmd grub-dropin)" "/usr/sbin/update-grub"
  rm "$root/usr/bin" "$root/usr/sbin"
  mkdir -p "$root/usr/bin" "$root/usr/sbin" "$user"
  mv "$root/bin/update-grub" "$root/usr/sbin/grub-mkconfig"
  hash -r
  check "grub-mkconfig only under /usr/sbin, off PATH: that path, never /usr/bin" \
    "$(bootloader_regen_host_cmd grub-inline)" "/usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg"
  bootloader_regen_installed grub-inline;  check "grub-mkconfig only under /usr/sbin: installed" "$?" 0
  mv "$root/usr/sbin/grub-mkconfig" "$user/grub-mkconfig"
  err=$(PATH="$user:$root/bin:$TMP/tools" bootloader_regen_host_cmd grub-inline 2>&1)
  check "grub-mkconfig only in a user's PATH directory: not installed" "$?:$err" "1:this host has no grub-mkconfig"
  PATH="$user:$root/bin:$TMP/tools" bootloader_regen_installed grub-inline
  check "grub-mkconfig only in a user's PATH directory: regen_installed agrees" "$?" 1
  err=$(cd "$user" && PATH=".:$root/bin:$TMP/tools" bootloader_regen_host_cmd grub-inline 2>&1)
  check "grub-mkconfig only under ./ on PATH: not installed" "$?:$err" "1:this host has no grub-mkconfig"
  mv "$user/grub-mkconfig" "$root/usr/sbin/grub-mkconfig"
  ln -s ../sbin/grub-mkconfig "$root/usr/bin/grub-mkconfig"
  check "grub-mkconfig at its usual path"   "$(bootloader_regen_host_cmd grub-inline)" \
    "/usr/bin/grub-mkconfig -o /boot/grub/grub.cfg"
  rm "$root/usr/bin/grub-mkconfig"
  mkdir -p "$root/usr/local/bin" "$root/sbin"
  ln -s ../../sbin/grub-mkconfig "$root/usr/local/bin/grub-mkconfig"
  ln -s ../usr/sbin/grub-mkconfig "$root/sbin/grub-mkconfig"
  check "the system directories in their fixed order" "$(bootloader_regen_host_cmd grub-inline)" \
    "/usr/sbin/grub-mkconfig -o /boot/grub/grub.cfg"
}

# check grub cmdlines are read from the 10_linux* entries only
body_grub_scope() {
  local root="$1" cfg="$1/boot/grub/grub.cfg"
  printf '%s\n' '### BEGIN /etc/grub.d/00_header ###' '### END /etc/grub.d/00_header ###' \
    '### BEGIN /etc/grub.d/10_linux ###' 'menuentry "u" {' '	linux	/vmlinuz root=UUID=a ro  quiet security=selinux' \
    '}' 'submenu "old" {' '	linux /vmlinuz.old root=UUID=a ro recovery security=selinux' '}' \
    '### END /etc/grub.d/10_linux ###' '### BEGIN /etc/grub.d/10_linux_zfs ###' \
    '	linux /vmlinuz root=ZFS=x ro zfs=1 security=selinux' '### END /etc/grub.d/10_linux_zfs ###' \
    '### BEGIN /etc/grub.d/40_custom ###' 'menuentry "c" {' '	linux /vmlinuz-c root=UUID=c ro loglevel=8' '}' \
    '### END /etc/grub.d/40_custom ###' > "$cfg"
  check "grub cmdlines: only 10_linux* entries" "$(bootloader_cmdline_tokens grub-dropin)" \
    "quiet${NL}recovery${NL}ro${NL}root=UUID=a${NL}root=ZFS=x${NL}security=selinux${NL}zfs=1"
  check "grub cmdlines: a custom entry's token is not a next-boot one" \
    "$(bootloader_remaining grub-dropin loglevel=8)" ""
  check "grub missing: a custom entry lacking a token does not count" \
    "$(bootloader_missing grub-inline security=selinux)" ""
  check "grub missing: one 10_linux entry lacking it does" "$(bootloader_missing grub-inline quiet)" " quiet"
  printf '%s\n' 'linux /vmlinuz root=UUID=a ro security=selinux' 'linux /vmlinuz-c root=UUID=c ro loglevel=8' > "$cfg"
  check "grub cmdlines: no 10_linux section, every linux line" \
    "$(bootloader_remaining grub-dropin "loglevel=8 security=selinux")" " loglevel=8 security=selinux"
  check "grub missing: no 10_linux section, every linux line" \
    "$(bootloader_missing grub-dropin security=selinux)" " security=selinux"
}

# move update-grub and grub-gen under /usr/sbin
setup_grub_dropin_sbin() {
  add_grub_dropin "$1"; mkdir -p "$1/usr/sbin"; mv "$1/bin/update-grub" "$1/bin/grub-gen" "$1/usr/sbin/"
}
# set up a limine host with limine-update under /usr/bin
setup_limine_usr_bin()   { add_limine "$1"; mkdir -p "$1/usr/bin"; mv "$1/bin/limine-update" "$1/usr/bin/"; }
# set up a grub-dropin host with update-grub in a user's bin folder
setup_grub_dropin_user() {
  add_grub_dropin "$1"; mkdir -p "$1/home/user/bin"; mv "$1/bin/update-grub" "$1/home/user/bin/"
}
# set up a limine host with limine-update in a user's bin folder
setup_limine_user() { add_limine "$1"; mkdir -p "$1/home/user/bin"; mv "$1/bin/limine-update" "$1/home/user/bin/"; }
# check update-grub only under /usr/sbin
body_update_grub_sbin_only() {
  local root="$1" out rc
  check "update-grub only under /usr/sbin, PATH without it: detected" "$(bootloader_kind 2>&1; echo "rc=$?")" \
    "grub-dropin${NL}rc=0"
  out=$(bootloader_regen grub-dropin); rc=$?
  check "update-grub only under /usr/sbin, PATH without it: regenerated from there" \
    "$rc|$out|$(ncalls "$root" update-grub)" "0|Generating grub configuration file ...|1"
}
# check limine-update only under /usr/bin
body_limine_update_usr_bin_only() {
  local root="$1" out rc
  check "limine-update only under /usr/bin, PATH without it: detected" "$(bootloader_kind 2>&1; echo "rc=$?")" \
    "limine${NL}rc=0"
  out=$(bootloader_regen limine); rc=$?
  check "limine-update only under /usr/bin, PATH without it: regenerated from there" \
    "$rc|$out|$(ncalls "$root" limine-update)" "0|Updating limine.conf|1"
}
# check update-grub only in a user's PATH folder
body_update_grub_user_path() {
  local root="$1" out rc
  PATH="$root/home/user/bin:$root/bin:$TMP/tools"; hash -r
  out=$(bootloader_kind 2>&1); rc=$?
  check "update-grub only in a user's PATH directory: not detected" "$rc:$out" "1:no update-grub in any of\
 $root/usr/bin, $root/usr/sbin, $root/bin, $root/sbin, $root/usr/local/sbin, $root/usr/local/bin -- grub2-common is\
 not installed"
  out=$(bootloader_regen grub-dropin); rc=$?
  check "update-grub only in a user's PATH directory: never run" "$rc|$out|$(ncalls "$root" update-grub)" \
    "127|this host has no update-grub|0"
}
# check limine-update only in a user's PATH folder
body_limine_update_user_path() {
  local root="$1" out rc
  PATH="$root/home/user/bin:$root/bin:$TMP/tools"; hash -r
  out=$(bootloader_kind 2>&1); rc=$?
  check "limine-update only in a user's PATH directory: not detected, the missing command named" "$rc:$out" \
    "1:$root/etc/default/limine is there, but no limine-update is in any of $root/usr/bin, $root/usr/sbin, $root/bin,\
 $root/sbin, $root/usr/local/sbin, $root/usr/local/bin to regenerate its config -- install it"
}

# link /etc/default/limine to a private directory
setup_limine_linked() {
  add_limine "$1"; mkdir "$1/private"
  mv "$1/etc/default/limine" "$1/private/limine"; ln -s "$1/private/limine" "$1/etc/default/limine"
}
# check limine through a link into an unsearchable folder
body_limine_link_unreachable() {
  local root="$1" kind present own
  bootloader_write limine "$TOK" || fail "a block written through the link"
  chmod 000 "$root/private"
  kind=$(bootloader_kind 2>&1; echo "rc=$?")
  present=$(bootloader_present limine 2>&1; echo "rc=$?")
  own=$(bootloader_own_tokens limine 2>&1; echo "rc=$?")
  chmod 755 "$root/private"
  check_unprivileged "/etc/default/limine linked into a directory this uid cannot search: detection cannot tell" \
    "$kind" "cannot read $root/private as uid $EUID${NL}rc=2"
  check_unprivileged "/etc/default/limine linked into a directory this uid cannot search: present cannot tell" \
    "$present" "cannot read $root/private as uid $EUID${NL}rc=2"
  check_unprivileged "/etc/default/limine linked into a directory this uid cannot search: own tokens cannot tell" \
    "$own" "cannot read $root/private as uid $EUID${NL}rc=2"
  rm "$root/private/limine"
  check "/etc/default/limine linked to nothing: no limine detected" "$(bootloader_kind 2>&1; echo "rc=$?")" \
    "no supported bootloader configuration found (looked for $root/etc/default/limine, $root/etc/sdboot-manage.conf,\
 $root/etc/default/grub)${NL}rc=1"
  check "/etc/default/limine linked to nothing: absent" "$(bootloader_present limine 2>&1; echo "rc=$?")" "rc=1"
}
# set up an sd-boot host whose entry is a symlink into a private folder
setup_sdboot_entry_linked() {
  local e="$1/boot/loader/entries"
  add_sdboot "$1"; mkdir "$1/private"
  mv "$e/linux-cachyos.conf" "$1/private/"; ln -s "$1/private/linux-cachyos.conf" "$e/linux-cachyos.conf"
}
# check reading an sd-boot entry link
body_sdboot_entry_link() {
  local root="$1" out
  check "an sd-boot entry linked to a file: read" "$(bootloader_cmdline_tokens sdboot | grep -cx nowatchdog)" 1
  chmod 000 "$root/private"
  out=$(bootloader_cmdline_tokens sdboot 2>&1; echo "rc=$?")
  chmod 755 "$root/private"
  check_unprivileged "an sd-boot entry linked into a directory this uid cannot search: cannot tell" "$out" \
    "cannot read $root/private as uid $EUID${NL}rc=2"
  rm "$root/private/linux-cachyos.conf"
  check "an sd-boot entry linked to nothing: absent" "$(bootloader_cmdline_tokens sdboot 2>&1; echo "rc=$?")" "rc=0"
}
# test limine.conf in a linked ESP
body_limine_esp_link() {
  local root="$1" out
  mkdir -p "$root/private/esp"; mv "$root/boot/limine.conf" "$root/private/esp/"
  ln -s "$root/private/esp" "$root/boot/efi"
  sed -i 's|^ESP_PATH=.*|ESP_PATH="/boot/efi"|' "$root/etc/default/limine"
  check "limine.conf in an ESP linked to a directory: found" "$(bootloader_generated limine)" \
    "$root/boot/efi/limine.conf"
  chmod 000 "$root/private"
  out=$(bootloader_kind 2>&1; echo "rc=$?")
  chmod 755 "$root/private"
  check_unprivileged "limine.conf in an ESP linked into a directory this uid cannot search: cannot tell" "$out" \
    "cannot read $root/private as uid $EUID${NL}rc=2"
  rm -r "$root/private/esp"
  check "an ESP linked to nothing: refused by name" "$(bootloader_generated limine 2>&1 >/dev/null; echo "rc=$?")" \
    "$(esp_missing "$root" /boot/efi)${NL}rc=2"
}

# set up a limine host whose ESP_PATH is /efi
setup_limine_efi() { add_limine "$1"; limine_move_esp "$1" /efi; }
# set up a limine host with a stale /boot/limine.conf
setup_limine_stale() {
  add_limine "$1"; limine_move_esp "$1" /efi
  { printf '%s\n' 'timeout: 5' 'remember_last_entry: no'; limine_os CachyOS; limine_entry linux-cachyos root=UUID=stale
  } > "$1/boot/limine.conf"
}
# set up a limine host with no ESP_PATH and its ESP at /limine
setup_limine_auto() { add_limine "$1"; limine_move_esp "$1" /limine; sed -i '/^ESP_PATH=/d' "$1/etc/default/limine"; }
# set up a limine host whose ESP_PATH is set in a limine-entry-tool drop-in
setup_limine_dropin_esp() {
  add_limine "$1"; limine_move_esp "$1" /esp; sed -i '/^ESP_PATH=/d' "$1/etc/default/limine"
  mkdir -p "$1/etc/limine-entry-tool.d"; echo 'ESP_PATH="/esp"' > "$1/etc/limine-entry-tool.d/50-esp.conf"
}
# print the preflight message of a limine.conf with no Rhizo entry
no_rhizo_entry() { echo "$1 lists no Rhizo kernel entry -- is the Rhizo kernel installed?"; }
# print the refusal for an ESP_PATH that names no limine.conf
esp_missing() {
  echo "limine-entry-tool's ESP_PATH is $2, but there is no $1$2/limine.conf: mount the ESP at $2, or set ESP_PATH to" \
       "where it is mounted"
}
# check the stock layout reads /boot/limine.conf
body_limine_esp_stock() {
  check "stock ESP at /boot: limine.conf" "$(bootloader_generated limine 2>&1; echo "rc=$?")" "$1/boot/limine.conf${NL}rc=0"
  check "stock ESP at /boot: the preflight reads it" "$(bootloader_rhizo_default_preflight limine 2>&1; echo "rc=$?")" \
    "$(no_rhizo_entry "$1/boot/limine.conf")${NL}rc=1"
}
# check an ESP at /efi reads /efi/limine.conf
body_limine_esp_efi() {
  check "ESP_PATH=/efi: limine.conf" "$(bootloader_generated limine 2>&1; echo "rc=$?")" "$1/efi/limine.conf${NL}rc=0"
  check "ESP_PATH=/efi: the preflight reads it" "$(bootloader_rhizo_default_preflight limine 2>&1; echo "rc=$?")" \
    "$(no_rhizo_entry "$1/efi/limine.conf")${NL}rc=1"
}
# check ESP_PATH wins over a stale /boot/limine.conf
body_limine_esp_stale() {
  check "ESP_PATH=/efi beside a stale /boot copy: the ESP's limine.conf" \
    "$(bootloader_generated limine 2>&1; echo "rc=$?")" "$1/efi/limine.conf${NL}rc=0"
  check "ESP_PATH=/efi beside a stale /boot copy: remember_last_entry read from the ESP's" \
    "$(bootloader_rhizo_default_preflight limine 2>&1; echo "rc=$?")" "$(no_rhizo_entry "$1/efi/limine.conf")${NL}rc=1"
  check "ESP_PATH=/efi beside a stale /boot copy: tokens read from the ESP's" \
    "$(bootloader_cmdline_tokens limine | grep -c 'root=UUID=stale')" 0
}
# check an ESP_PATH that names no limine.conf refuses by name
body_limine_esp_missing() {
  rm "$1/efi/limine.conf"
  check "ESP_PATH=/efi with no limine.conf: refused by name" "$(bootloader_generated limine 2>&1; echo "rc=$?")" \
    "$(esp_missing "$1" /efi)${NL}rc=2"
  check "ESP_PATH=/efi with no limine.conf: detection refuses" "$(bootloader_kind 2>&1; echo "rc=$?")" \
    "$(esp_missing "$1" /efi)${NL}rc=2"
  printf 'timeout: 5\nremember_last_entry: yes\n' > "$1/boot/limine.conf"
  check "ESP_PATH=/efi with no limine.conf: a /boot copy is not read instead" \
    "$(bootloader_generated limine 2>&1; echo "rc=$?")" "$(esp_missing "$1" /efi)${NL}rc=2"
}
# check no ESP_PATH finds an ESP at /limine
body_limine_esp_auto() {
  check "no ESP_PATH, ESP at /limine: limine.conf" "$(bootloader_generated limine 2>&1; echo "rc=$?")" \
    "$1/limine/limine.conf${NL}rc=0"
  rm "$1/limine/limine.conf"
  check "no ESP_PATH and no limine.conf anywhere: refused by name" \
    "$(bootloader_generated limine 2>&1; echo "rc=$?")" "no limine.conf found (looked for $1/boot/limine.conf\
 $1/boot/limine/limine.conf $1/efi/limine.conf $1/boot/efi/limine.conf $1/boot/EFI/limine/limine.conf\
 $1/limine/limine.conf)${NL}rc=1"
}
# check ESP_PATH read as limine-entry-tool's ConfigReader reads it
body_limine_esp_forms() {
  local form want
  while IFS='|' read -r form want; do
    sed -i "/ESP_PATH/d" "$1/etc/default/limine"; printf '%s\n' "$form" >> "$1/etc/default/limine"
    check "ESP_PATH written as [$form]: read as [$want]" "$(bl_setting ESP_PATH "" kv "$1/etc/default/limine")" "$want"
  done <<'FORMS'
ESP_PATH="/efi"   |/efi
  ESP_PATH = "/efi"|/efi
ESP_PATH='/efi'|'/efi'
ESP_PATH="/efi"  # the ESP|"/efi"  # the ESP
ESP_PATH="/efi|"/efi
ESP_PATH=/efi"|/efi"
FORMS
  sed -i "/ESP_PATH/d" "$1/etc/default/limine"; printf '%s\n' 'ESP_PATH="/efi"   ' >> "$1/etc/default/limine"
  check "ESP_PATH with trailing spaces: /efi/limine.conf" "$(bootloader_generated limine 2>&1; echo "rc=$?")" \
    "$1/efi/limine.conf${NL}rc=0"
  sed -i "/ESP_PATH/d" "$1/etc/default/limine"; printf '%s\n' "ESP_PATH='/efi'" >> "$1/etc/default/limine"
  check "ESP_PATH in single quotes, which limine-entry-tool keeps: refused by that name" \
    "$(bootloader_generated limine 2>&1; echo "rc=$?")" "$(esp_missing "$1" "'/efi'")${NL}rc=2"
}
# check an ESP_PATH from a limine-entry-tool drop-in
body_limine_esp_dropin() {
  check "ESP_PATH=/esp from a drop-in: limine.conf" "$(bootloader_generated limine 2>&1; echo "rc=$?")" \
    "$1/esp/limine.conf${NL}rc=0"
}

# print the unsupported host message
no_supported() {
  echo "no supported bootloader configuration found (looked for $1/etc/default/limine, $1/etc/sdboot-manage.conf,\
 $1/etc/default/grub)"
}
# link a file into the private directory
link_into_private() {
  mkdir -p "$1/private"; mv "$1$2" "$1/private/${2##*/}"; ln -s "$1/private/${2##*/}" "$1$2"
}
# test bootloader_kind through a linked file
kind_through_link() {
  local out
  link_into_private "$1" "$2"
  check "$4 linked to a readable file: $3 detected" "$(bootloader_kind 2>&1; echo "rc=$?")" "$3${NL}rc=0"
  chmod 000 "$1/private"
  out=$(bootloader_kind 2>&1; echo "rc=$?")
  chmod 755 "$1/private"
  check_unprivileged "$4 linked into a directory this uid cannot search: detection cannot tell" "$out" \
    "cannot read $1/private as uid $EUID${NL}rc=2"
  rm "$1/private/${2##*/}"
  check "$4 linked to nothing: no kind detected" "$(bootloader_kind 2>&1; echo "rc=$?")" "$(no_supported "$1")${NL}rc=1"
}
# check sd-boot detection through a linked sdboot-manage.conf
body_sdboot_conf_link()  { kind_through_link "$1" /etc/sdboot-manage.conf sdboot sdboot-manage.conf; }
# check grub-inline detection through a linked /etc/default/grub
body_grub_default_link() { kind_through_link "$1" /etc/default/grub grub-inline "cachyos's /etc/default/grub"; }
# check a drop-in linked into an unsearchable folder reads as cannot tell
body_dropin_link() {
  local root="$1" out
  bootloader_apply grub-dropin "$TOK" >/dev/null
  link_into_private "$root" /etc/default/grub.d/90-rhizo.cfg
  check "a drop-in linked to a readable file: present" "$(bootloader_present grub-dropin 2>&1; echo "rc=$?")" "rc=0"
  chmod 000 "$root/private"
  out=$(bootloader_present grub-dropin 2>&1; echo "rc=$?")
  chmod 755 "$root/private"
  check_unprivileged "a drop-in linked into a directory this uid cannot search: present cannot tell" "$out" \
    "cannot read $root/private as uid $EUID${NL}rc=2"
}
# test /etc/default/limine behind a relative link
body_limine_relative_link() {
  local root="$1" out
  mkdir "$root/private"; mv "$root/etc/default/limine" "$root/private/limine"
  ln -s ../../private/limine "$root/etc/default/limine"
  check "/etc/default/limine as a relative link to a readable file: limine detected" "$(bootloader_kind)" limine
  chmod 000 "$root/private"
  out=$(bootloader_kind 2>&1; echo "rc=$?")
  chmod 755 "$root/private"
  check_unprivileged "/etc/default/limine as a relative link into a directory this uid cannot search: cannot tell" \
    "$out" "cannot read $root/etc/default/../../private as uid $EUID${NL}rc=2"
}
# test /etc/default/limine through two links
body_limine_link_chain() {
  local root="$1" out
  mkdir "$root/private"; mv "$root/etc/default/limine" "$root/private/limine"
  ln -s "$root/private/limine" "$root/hop"; ln -s "$root/hop" "$root/etc/default/limine"
  check "/etc/default/limine through two links to a readable file: limine detected" "$(bootloader_kind)" limine
  chmod 000 "$root/private"
  out=$(bootloader_kind 2>&1; echo "rc=$?")
  chmod 755 "$root/private"
  check_unprivileged "/etc/default/limine through two links into a directory this uid cannot search: cannot tell" \
    "$out" "cannot read $root/private as uid $EUID${NL}rc=2"
  rm "$root/private/limine"
  check "/etc/default/limine through two links to nothing: no kind detected" \
    "$(bootloader_kind 2>&1; echo "rc=$?")" "$(no_supported "$root")${NL}rc=1"
}

# check detection on ubuntu with an unsearchable /etc/default
body_etc_default_unsearchable_ubuntu()  { etc_default_unsearchable "$1"; }
# check detection on cachyos with an unsearchable /etc/default
body_etc_default_unsearchable_cachyos() { etc_default_unsearchable "$1"; }
# check detection with an unsearchable /etc/default reads as cannot tell
etc_default_unsearchable() {
  local root="$1" out
  chmod 000 "$root/etc/default"
  out=$(bootloader_kind 2>&1; echo "rc=$?")
  chmod 755 "$root/etc/default"
  check_unprivileged "$(host_flavor): an /etc/default this uid cannot search: detection cannot tell" "$out" \
    "cannot read $root/etc/default as uid $EUID${NL}rc=2"
}

CACHY_TOK="security=selinux $TOKENS_MID $TOKENS_ANDROIDBOOT"
# test bl_next_entries on bootloader-real files
body_real_configs() {
  local root="$1" e="$1/boot/loader/entries" b="$HERE/fixtures/bootloader-real" line
  echo 2dd58b8daf034264b2e97f1b76353ff6 > "$root/etc/machine-id"
  cp "$b/limine.conf" "$root/boot/limine.conf"
  check "real limine.conf: the kernel entry limine-entry-tool wrote, not limine-snapper-sync's two snapshots" \
    "$(bl_next_entries limine)" "$root/boot/limine.conf entry CachyOS/linux-cachyos$TAB$CACHY_TOK splash quiet\
 zswap.enabled=0 nowatchdog rw rootflags=subvol=/@ root=UUID=22222222-2222-4222-8222-222222222222"
  mkdir -p "$e"; cp "$b/loader/entries/linux-cachyos.conf" "$e/"
  touch "$root/boot/vmlinuz-linux-cachyos"
  printf 'title Other Linux\noptions root=UUID=00000000-0000-4000-8000-000000000000 rw\nlinux /other/vmlinuz\n' \
    > "$e/other-os.conf"
  check "real sd-boot entries: sdboot-manage's own, not another OS's" "$(bl_next_entries sdboot)" \
    "$e/linux-cachyos.conf${TAB}root=UUID=33333333-3333-4333-8333-333333333333 rw rootflags=subvol=/@ nowatchdog quiet\
 splash $CACHY_TOK"
  check "real sd-boot entries: the other OS's entry lacking every token leaves nothing missing" \
    "$(bootloader_missing sdboot "$CACHY_TOK")" ""
  mkdir -p "$root/boot/grub"; cp "$b/grub.cfg" "$root/boot/grub/grub.cfg"
  line="root=UUID=11111111-1111-4111-8111-111111111111 rw rootflags=subvol=@ $CACHY_TOK splash quiet zswap.enabled=0"
  line+=" nowatchdog"
  check "real grub.cfg: the simple and the advanced 10_linux entry" "$(bl_next_entries grub-inline)" \
    "$root/boot/grub/grub.cfg$TAB$line$NL$root/boot/grub/grub.cfg$TAB$line"
}

# test bl_cmdline_overridden on repeated keys
body_last_wins() {
  local rl="lsm=capability,landlock,lockdown,yama,selinux,bpf" real
  real="$rl ${CACHY_TOK#security=selinux } splash quiet zswap.enabled=0 nowatchdog rw rootflags=subvol=/@"
  real+=" root=UUID=22222222-2222-4222-8222-222222222222 lsm=landlock,lockdown,yama,integrity,bpf"
  check "the real lsm= host: its own later lsm= overrides rhizo's" \
    "$(bl_cmdline_overridden "$real" "$rl ${CACHY_TOK#security=selinux }")" \
    "$rl lsm=landlock,lockdown,yama,integrity,bpf"
  check "security=selinux with a later lsm= lacking selinux is overridden" \
    "$(bl_cmdline_overridden "security=selinux quiet lsm=landlock,bpf" security=selinux)" \
    "security=selinux lsm=landlock,bpf"
  check "security=selinux with an earlier lsm= lacking selinux is overridden too" \
    "$(bl_cmdline_overridden "lsm=landlock,bpf security=selinux" security=selinux)" "security=selinux lsm=landlock,bpf"
  check "a host lsm= holding selinux overrides nothing" \
    "$(bl_cmdline_overridden "security=selinux lsm=landlock,selinux,bpf" security=selinux)" ""
  check "security= alone: the last one counts" \
    "$(bl_cmdline_overridden "security=selinux security=apparmor" security=selinux)" \
    "security=selinux security=apparmor"
  check "loglevel= is not judged: a later quiet or loglevel= breaks nothing" \
    "$(bl_cmdline_overridden "loglevel=8 quiet loglevel=4" loglevel=8)" ""
  check "an earlier setting loses to rhizo's" "$(bl_cmdline_overridden "loglevel=4 loglevel=8" loglevel=8)" ""
  check "androidboot.* keeps its first setting, so a later one overrides nothing" \
    "$(bl_cmdline_overridden "androidboot.hardware=rhizo androidboot.hardware=x" androidboot.hardware=rhizo)" ""
}
# test a host lsm= in limine
body_limine_lsm_host() {
  local root="$1" f="$1/etc/default/limine" lsm=lsm=landlock,lockdown,yama,integrity,bpf
  local rl=lsm=capability,landlock,lockdown,yama,selinux,bpf
  limine_default "$root" "$LIMINE_ESP" "${LIMINE_BASE%\"} $lsm\"" "$LIMINE_ORDER"
  bootloader_apply limine "$rl $TOKENS_MID" >/dev/null
  check "limine, a host lsm= in KERNEL_CMDLINE[default]: rhizo's lsm= overridden" \
    "$(bootloader_overridden limine "$rl $TOKENS_MID")" "$rl $lsm"
  check "limine, a host lsm= in KERNEL_CMDLINE[default]: named by variable and file" \
    "$(bootloader_token_source limine "$lsm")" "KERNEL_CMDLINE[default] in $f"
}
# test a host lsm= in GRUB_CMDLINE_LINUX_DEFAULT
body_grub_lsm_host() {
  local root="$1" f="$1/etc/default/grub"
  printf "GRUB_CMDLINE_LINUX_DEFAULT='nowatchdog quiet splash lsm=landlock,bpf'\nGRUB_CMDLINE_LINUX=\"\"\n" > "$f"
  bootloader_apply grub-inline "security=selinux $TOKENS_MID" >/dev/null
  check "grub, a host lsm= in GRUB_CMDLINE_LINUX_DEFAULT: rhizo's security=selinux overridden" \
    "$(bootloader_overridden grub-inline "security=selinux $TOKENS_MID")" "security=selinux lsm=landlock,bpf"
  check "grub, a host lsm= in GRUB_CMDLINE_LINUX_DEFAULT: named by variable and file" \
    "$(bootloader_token_source grub-inline lsm=landlock,bpf)" "GRUB_CMDLINE_LINUX_DEFAULT in $f"
}
# test a host lsm= in sdboot-manage.conf
body_sdboot_lsm_host() {
  local root="$1" f="$1/etc/sdboot-manage.conf" rl=lsm=capability,landlock,lockdown,yama,selinux,bpf
  printf 'LINUX_OPTIONS="nowatchdog quiet splash lsm=landlock,bpf"\n' > "$f"
  bootloader_apply sdboot "$rl $TOKENS_MID" >/dev/null
  check "sdboot, a host lsm= before rhizo's: rhizo's comes last and stays" \
    "$(bootloader_overridden sdboot "$rl $TOKENS_MID")" ""
  bootloader_apply sdboot "security=selinux $TOKENS_MID" >/dev/null
  check "sdboot, a host lsm= beside rhizo's security=selinux: overridden wherever it is" \
    "$(bootloader_overridden sdboot "security=selinux $TOKENS_MID")" "security=selinux lsm=landlock,bpf"
}
# test the bootloader_missing_entries output
body_missing_entries() {
  local root="$1" e="$1/boot/loader/entries"
  echo "$LIMINE_MID" > "$root/etc/machine-id"
  printf 'title Other\noptions root=UUID=0 rw\nlinux /other/vmlinuz\n' > "$e/other-os.conf"
  bootloader_apply sdboot "$TOK" >/dev/null
  check "sdboot another OS's entry: not sdboot-manage's, so nothing is missing" "$(bootloader_missing sdboot "$TOK")" ""
  check "sdboot another OS's entry: none named" "$(bootloader_missing_entries sdboot "$TOK")" ""
  touch "$root/boot/vmlinuz-linux-cachyos-lts"
  printf 'title LTS\noptions root=UUID=abc rw\nlinux /vmlinuz-linux-cachyos-lts\n' > "$e/linux-cachyos-lts.conf"
  check "sdboot an entry of sdboot-manage's lacking the tokens: named by its file" \
    "$(bootloader_missing_entries sdboot "$TOK")" "$e/linux-cachyos-lts.conf$TAB$ALL_MISSING"
  { limine_os CachyOS; limine_entry a "$TOK"; limine_entry b "root=x security=selinux"; } > "$root/boot/limine.conf"
  check "limine an entry lacking tokens: named by its path in limine.conf" \
    "$(bootloader_missing_entries limine "$TOK")" \
    "$root/boot/limine.conf entry CachyOS/b$TAB enforcing=0 loop.max_loop=64 androidboot.hardware=rhizo"
  limine_os CachyOS > "$root/boot/limine.conf"
  check "limine no entry of the tool's at all: limine.conf lacks every token" \
    "$(bootloader_missing_entries limine "$TOK")" "$root/boot/limine.conf$TAB$ALL_MISSING"
}
# test limine OS entry name lookup
body_limine_os_by_name() {
  local root="$1" conf="$1/boot/limine.conf" other=0123456789abcdef0123456789abcdef
  { printf '%s\n' /+Mine; limine_entry a "$TOK"; printf '%s\n' /+CachyOS; limine_entry b root=x; } > "$conf"
  printf 'TARGET_OS_NAME="Mine"\n' >> "$root/etc/default/limine"
  check "limine no OS entry carrying this machine's id: the one TARGET_OS_NAME names" \
    "$(bootloader_missing limine "$TOK")" ""
  sed -i '/^TARGET_OS_NAME=/d' "$root/etc/default/limine"
  mkdir -p "$root/etc/limine-entry-tool.d"; printf 'TARGET_OS_NAME="Mine"\n' > "$root/etc/limine-entry-tool.d/50.conf"
  check "limine no OS entry carrying this machine's id: TARGET_OS_NAME from limine-entry-tool's own drop-in" \
    "$(bootloader_missing limine "$TOK")" ""
  rm "$root/etc/limine-entry-tool.d/50.conf"
  printf 'ID=cachyos\nPRETTY_NAME="Mine"\n' > "$root/os-release"
  check "limine no OS entry carrying this machine's id, no TARGET_OS_NAME: the one os-release's PRETTY_NAME names" \
    "$(bootloader_missing limine "$TOK")" ""
  printf 'ID=cachyos\nNAME="Mine"\n' > "$root/os-release"
  check "limine with no PRETTY_NAME: the one os-release's NAME names" "$(bootloader_missing limine "$TOK")" ""
  printf 'ID=cachyos\n' > "$root/os-release"
  printf 'DISTRIB_ID="CachyOS"\nDISTRIB_DESCRIPTION="Mine"\n' > "$root/etc/lsb-release"
  check "limine with no PRETTY_NAME or NAME: the one lsb-release's DISTRIB_DESCRIPTION names" \
    "$(bootloader_missing limine "$TOK")" ""
  printf 'ID=cachyos\nNAME="Other"\n' > "$root/os-release"
  check "limine no OS entry this host's by id or name: none read, every token missing" \
    "$(bootloader_missing limine "$TOK")" "$ALL_MISSING"
  { limine_os Mine "$other"; limine_entry a "$TOK"; } > "$conf"
  printf 'ID=cachyos\nPRETTY_NAME="Mine"\n' > "$root/os-release"
  check "limine the os-release name's OS entry carrying another machine id: not this host's, none read" \
    "$(bl_next_entries limine; echo "rc=$?")" "rc=0"
  printf 'ID=cachyos\nNAME="Other"\n' > "$root/os-release"
  printf 'TARGET_OS_NAME="Mine"\n' >> "$root/etc/default/limine"
  check "limine TARGET_OS_NAME's OS entry carrying another machine id: not this host's, none read" \
    "$(bl_next_entries limine; echo "rc=$?")" "rc=0"
}
# test limine with a missing machine id
body_limine_no_machine_id() {
  local root="$1" conf="$1/boot/limine.conf"
  { limine_os CachyOS; limine_entry linux-cachyos sentinel=a3-stock; } > "$conf"
  printf 'ID=cachyos\nPRETTY_NAME="CachyOS"\n' > "$root/os-release"
  rm "$root/etc/machine-id"
  check "limine no /etc/machine-id: the OS entry of that name carrying the old id is not this host's" \
    "$(bl_next_entries limine; echo "rc=$?")" "rc=0"
  { printf '%s\n' /+CachyOS; limine_entry linux-cachyos 'by name'; } > "$conf"
  check "limine no /etc/machine-id: an OS entry of that name carrying no machine id is read, as the tool takes it" \
    "$(bl_next_cmdlines limine)" "by name"
  { limine_os CachyOS; limine_entry linux-cachyos sentinel=a3-stock; } > "$conf"
  : > "$root/etc/machine-id"
  check "limine an empty /etc/machine-id: the OS entry carrying the old id is not this host's" \
    "$(bl_next_entries limine; echo "rc=$?")" "rc=0"
  check "limine-update with an empty /etc/machine-id: generates one, as the tool's wrapper does" \
    "$(bootloader_regen limine 2>/dev/null)" "Generating machine-id at /etc/machine-id...${NL}Updating limine.conf"
  check "limine-update with an empty /etc/machine-id: the old OS entry kept as it was" \
    "$(grep -c '^  cmdline: sentinel=a3-stock$' "$conf")" 1
  check "limine after limine-update: the new OS entry carrying the generated id is read" \
    "$(bl_next_cmdlines limine)" "$LIMINE_CMDLINE"
}
# test limine-entry-tool config file sources
body_limine_tool_sources() {
  local root="$1" d="$1/etc/limine-entry-tool.d/90-local.conf" u="$1/usr/share/limine-entry-tool.d/10.conf"
  local f="$1/etc/default/limine"
  mkdir -p "${d%/*}" "${u%/*}"
  printf 'KERNEL_CMDLINE[default]="lsm=landlock,bpf root=x"\n' > "$u"
  printf 'KERNEL_CMDLINE[default]+="lsm=landlock,bpf"\n' > "$root/etc/limine-entry-tool.conf"
  printf 'KERNEL_CMDLINE[default]+="lsm=landlock,bpf"\n' > "$d"
  printf '%s\n' "$LIMINE_ESP" "$LIMINE_ORDER" > "$f"
  check "limine a token from limine-entry-tool's config files: named in the tool's order" \
    "$(bootloader_token_source limine lsm=landlock,bpf)" "KERNEL_CMDLINE[default] in $u
KERNEL_CMDLINE[default] in $root/etc/limine-entry-tool.conf
KERNEL_CMDLINE[default] in $d"
  check "limine those files' tokens are the host's own" "$(bootloader_host_tokens limine | grep -cx lsm=landlock,bpf)" 1
  printf '%s\n' "$LIMINE_ESP" "$LIMINE_BASE" "$LIMINE_ORDER" > "$f"
  check "limine a drop-in's token a later KERNEL_CMDLINE[default]= replaces: named by no source" \
    "$(bootloader_token_source limine lsm=landlock,bpf)" ""
  check "limine a drop-in's token a later KERNEL_CMDLINE[default]= replaces: not the host's" \
    "$(bootloader_host_tokens limine | grep -cx lsm=landlock,bpf)" 0
  rm "$u" "$root/etc/limine-entry-tool.conf" "$d"
  printf '%s\n' "$LIMINE_ESP" 'KERNEL_CMDLINE[default]+="pre=1"' "$LIMINE_BASE" 'KERNEL_CMDLINE[default]+="post=1"' \
    "$LIMINE_ORDER" > "$f"
  check "limine a += before the key's =: replaced, not the host's" "$(bootloader_host_tokens limine | grep -cx pre=1)" 0
  check "limine a += after the key's =: the host's" "$(bootloader_host_tokens limine | grep -cx post=1)" 1
  check "limine a += before the key's =: rhizo's leftover, were it rhizo's" \
    "$({ limine_os X; limine_entry a "pre=1 post=1"; } > "$root/boot/limine.conf"; bootloader_leftover limine \
         "pre=1 post=1")" " pre=1"
  printf '%s\n' "$LIMINE_ESP" "$LIMINE_BASE" 'KERNEL_CMDLINE[default]+="post=1"' 'KERNEL_CMDLINE[fallback]="fb=1"' \
    "$LIMINE_ORDER" > "$f"
  check "limine another key's = leaves this key's words" "$(bootloader_host_tokens limine | grep -cxE 'post=1|fb=1')" 2
}
# test unquoted KERNEL_CMDLINE values
body_limine_unquoted_line() {
  local root="$1" f="$1/etc/default/limine"
  printf 'KERNEL_CMDLINE[default]+=quiet loglevel=8 \n' >> "$f"
  check "limine an unquoted KERNEL_CMDLINE value: a word past its first space is named by its source" \
    "$(bootloader_token_source limine loglevel=8)" "KERNEL_CMDLINE[default] in $f"
  check "limine an unquoted KERNEL_CMDLINE value: every word of it is the host's own" \
    "$(bootloader_host_tokens limine | grep -cxE 'quiet|loglevel=8')" 2
  limine_default "$root" "$LIMINE_ESP" "$LIMINE_BASE" "$LIMINE_ORDER"
  # shellcheck disable=SC2016
  printf 'KERNEL_CMDLINE[default]+=$X lsm=landlock\n' >> "$f"
  # shellcheck disable=SC2016
  check "limine a KERNEL_CMDLINE value is not a shell's: \$X is a word as written" \
    "$(bootloader_host_tokens limine | grep -cxF -e '$X' -e lsm=landlock)" 2
  printf 'KERNEL_CMDLINE[default]+="tc=1" # x\n' >> "$f"
  check "limine a # in a KERNEL_CMDLINE line is no comment: it and what follows are words, quotes kept" \
    "$(bootloader_host_tokens limine | grep -cxF -e '"tc=1"' -e '#' -e x)" 3
  printf 'KERNEL_CMDLINE[default]+="a "b" c"\n' >> "$f"
  check "limine quotes inside a KERNEL_CMDLINE value are kept, only the outer pair dropped" \
    "$(bootloader_host_tokens limine | grep -cxF -e a -e '"b"' -e c)" 3
  printf "KERNEL_CMDLINE[default]+='sq=1'\\n" >> "$f"
  check "limine single quotes around a KERNEL_CMDLINE value are kept" \
    "$(bootloader_host_tokens limine | grep -cxF -e "'sq=1'" -e sq=1)/$(bootloader_token_source limine "'sq=1'")" \
    "1/KERNEL_CMDLINE[default] in $f"
  bootloader_regen limine >/dev/null 2>&1
  check "limine-update keeps the single quotes, as the tool does" "$(bl_next_cmdlines limine | grep -c "'sq=1'")" 1
}
# test shell reading of sdboot-manage.conf
body_sdboot_shell_reading() {
  local root="$1" f="$1/etc/sdboot-manage.conf" d="$1/etc/sdboot-manage.conf.d"
  # shellcheck disable=SC2016
  printf '%s\n' 'X=x=1' 'LINUX_OPTIONS=quiet loglevel=8' 'LINUX_FALLBACK_OPTIONS="$X fb=1"' > "$f"
  check "sdboot an unquoted value ends at its first space" "$(bootloader_token_source sdboot loglevel=8)" ""
  check "sdboot the host's own words, \$X expanded as bash does" "$(bootloader_host_tokens sdboot)" \
    "fb=1${NL}quiet${NL}x=1"
  # shellcheck disable=SC2016
  printf '%s\n' 'LINUX_OPTIONS="$Y quiet"' > "$f"
  check "sdboot a value expanding a name no file assigns: refused by name" \
    "$(bootloader_host_tokens sdboot 2>&1; echo "rc=$?")" \
    "cannot read LINUX_OPTIONS in $f: its value has \$Y${NL}rc=1"
  mkdir -p "$d"; printf '%s\n' 'LINUX_OPTIONS="quiet"' "$BEGIN" > "$f"
  # shellcheck disable=SC2016
  printf '%s\n' 'LINUX_OPTIONS="$LINUX_OPTIONS dd=1"' > "$d/50.conf"
  check "sdboot a drop-in after a config whose rhizo block is not closed: read" \
    "$(bootloader_host_tokens sdboot)" "dd=1${NL}quiet"
}
# test repeated GRUB_CMDLINE_LINUX_DEFAULT assignments
body_grub_reset() {
  local root="$1" g="$1/etc/default/grub" d="$1/etc/default/grub.d/50-local.cfg"
  mkdir -p "${d%/*}"
  printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet lsm=landlock,bpf"' 'GRUB_CMDLINE_LINUX=""' > "$g"
  printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' > "$d"
  check "grub-inline a later plain assignment replaces the earlier: not the host's" \
    "$(bootloader_host_tokens grub-inline | grep -cx lsm=landlock,bpf)/$(bootloader_token_source grub-inline \
       lsm=landlock,bpf)" "0/"
  check "grub-dropin, as the Ubuntu base read it: every assignment counted" \
    "$(bootloader_host_tokens grub-dropin | grep -cx lsm=landlock,bpf)" 1
  # shellcheck disable=SC2016
  printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT kept=1"' > "$d"
  check "grub-inline an assignment that keeps the earlier value: both the host's" \
    "$(bootloader_host_tokens grub-inline | grep -cxE 'lsm=landlock,bpf|kept=1')" 2
}
# test an unreadable grub or sdboot config
body_shell_sources_unreadable() {
  local root="$1" kind f out
  if [[ -f "$root/etc/sdboot-manage.conf" ]]; then kind=sdboot f="$root/etc/sdboot-manage.conf"
  else kind=grub-inline f="$root/etc/default/grub"; fi
  chmod 000 "$f"
  out=$(bootloader_host_tokens "$kind" 2>&1; echo "rc=$?")
  chmod 644 "$f"
  check_unprivileged "$kind a source this uid cannot read: cannot be told, by name" "$out" \
    "cannot read $f as uid $EUID${NL}rc=2"
}
# test an unreadable limine-entry-tool drop-in
body_limine_dropin_unreadable() {
  local root="$1" d="$1/etc/limine-entry-tool.d/50.conf" out
  mkdir -p "${d%/*}"; printf 'KERNEL_CMDLINE[default]+="x=1"\n' > "$d"; chmod 000 "$d"
  out=$(bootloader_host_tokens limine 2>&1; echo "rc=$?")
  chmod 644 "$d"
  check_unprivileged "limine a drop-in this uid cannot read: cannot be told, by name" "$out" \
    "cannot read $d as uid $EUID${NL}rc=2"
  printf '%s\n' "$BEGIN" > "$d"
  check "limine /etc/default/limine after a drop-in whose rhizo block is not closed: read" \
    "$(bootloader_host_tokens limine | grep -cx 'root=UUID=44444444-4444-4444-8444-444444444444')" 1
}
# test rEFInd with a leftover /etc/default/grub
body_refind_leftover_grub() {
  local root="$1"
  printf '"Boot" "root=UUID=abc rw"\n' > "$root/boot/refind_linux.conf"; : > "$root/etc/default/grub"
  check "rEFInd with a leftover /etc/default/grub: rEFInd named" "$(bootloader_kind 2>&1; echo "rc=$?")" \
    "this host boots through rEFInd, whose $root/boot/refind_linux.conf rhizo does not edit -- supported: limine,\
 systemd-boot with sdboot-manage, grub${NL}rc=1"
}
# test the order of limine OS entry lookup
body_limine_os_precedence() {
  local root="$1" conf="$1/boot/limine.conf" other=0123456789abcdef0123456789abcdef
  printf 'ID=cachyos\nPRETTY_NAME="CachyOS"\n' > "$root/os-release"
  printf 'TARGET_OS_NAME="CachyOS"\n' >> "$root/etc/default/limine"
  { limine_os CachyOS "$other"; limine_entry a 'other machine'; limine_os CachyOS; limine_entry a 'this machine'; } \
    > "$conf"
  check "limine two OS entries of one name: the one carrying this machine's id is read" \
    "$(bl_next_cmdlines limine)" "this machine"
  { printf '%s\n' /+Pretty; limine_entry a 'by PRETTY_NAME'; printf '%s\n' /+Target; limine_entry a 'by TARGET_OS_NAME'
  } > "$conf"
  printf 'ID=cachyos\nPRETTY_NAME="Pretty"\n' > "$root/os-release"
  sed -i 's/^TARGET_OS_NAME=.*/TARGET_OS_NAME="Target"/' "$root/etc/default/limine"
  check "limine TARGET_OS_NAME and PRETTY_NAME naming different OS entries: TARGET_OS_NAME's is read" \
    "$(bl_next_cmdlines limine)" "by TARGET_OS_NAME"
  { limine_os First; limine_entry a 'first'; limine_os Second; limine_entry a 'second'; } > "$conf"
  check "limine two OS entries carrying this machine's id: the first is read" "$(bl_next_cmdlines limine)" first
  bootloader_regen limine >/dev/null 2>&1
  check "limine two OS entries carrying this machine's id: limine-update rewrites the first" \
    "$(bl_next_cmdlines limine)" "$LIMINE_CMDLINE"
  check "limine two OS entries carrying this machine's id: the second is kept as it was" \
    "$(grep -c '^/+Second$\|^  cmdline: second$' "$conf")" 2
}
# test a limine base set in a drop-in
body_limine_base_in_dropin() {
  local root="$1" u="$1/usr/share/limine-entry-tool.d/50-u.conf"
  mkdir -p "${u%/*}"
  echo "KERNEL_CMDLINE[default]=\"u0=1 $LIMINE_CMDLINE\"" > "$u"
  limine_default "$root" "$LIMINE_ESP" "$LIMINE_ORDER"
  check "limine a base only in a drop-in: applied" "$(bootloader_apply limine "$TOK" >/dev/null 2>&1; echo "rc=$?")" \
    "rc=0"
  check "limine a base only in a drop-in: rhizo's tokens go in front of it" "$(bl_next_cmdlines limine)" \
    "$TOK u0=1 $LIMINE_CMDLINE"
}
# test a per-kernel key set in a drop-in
body_limine_key_in_dropin() {
  local root="$1" d="$1/etc/limine-entry-tool.d/50-k.conf"
  mkdir -p "${d%/*}"
  echo "KERNEL_CMDLINE[linux-cachyos]=\"ks=1 $LIMINE_CMDLINE\"" > "$d"
  bootloader_apply limine "$TOK" >/dev/null 2>&1
  check "limine a per-kernel key only in a drop-in: rhizo's block adds to it" \
    "$(grep -c '^KERNEL_CMDLINE\[linux-cachyos\]+=' "$root/etc/default/limine")" 1
  check "limine a per-kernel key only in a drop-in: nothing missing" "$(bootloader_missing_entries limine "$TOK")" ""
}
# test kinds missing their regeneration command
body_untooled() {
  local root="$1"
  : > "$root/etc/sdboot-manage.conf"; : > "$root/etc/default/grub"
  check "kinds whose /etc files are there without their commands: each command named" \
    "$(bootloader_kind 2>&1; echo "rc=$?")" "$root/etc/sdboot-manage.conf is there, but no sdboot-manage is;\
 $root/etc/default/grub is there, but no grub-mkconfig is in any of $(bl_system_dirs ', ') to regenerate its config\
 -- install it${NL}rc=1"
}
# test INITRD_ENTRIES in sdboot-manage.conf
body_sdboot_initrd_entries() {
  local root="$1"
  printf '%s\n' 'LINUX_OPTIONS="nowatchdog quiet splash"' 'INITRD_ENTRIES=(intel-ucode.img)' \
    > "$root/etc/sdboot-manage.conf"
  check "sdboot INITRD_ENTRIES=(intel-ucode.img) set: the entries still read" \
    "$(bl_next_entries sdboot 2>&1 | awk -F '\t' '{print $1}'; echo "rc=$?")" \
    "$root/boot/loader/entries/linux-cachyos.conf${NL}rc=0"
}
# test KERNEL_PATTERN in sdboot-manage.conf.d
body_sdboot_pattern_comment() {
  local root="$1" d="$1/etc/sdboot-manage.conf.d"
  mkdir -p "$d"; cp "$root/boot/vmlinuz-linux-cachyos" "$root/boot/vmlinuz-linux-extra"
  printf '%s\n' 'KERNEL_PATTERN="vmlinuz-linux-e*" # extra only' > "$d/50-pat.conf"
  run_stub "$root/bin/sdboot-manage" gen
  check "sdboot a quoted KERNEL_PATTERN with a trailing comment: the entry sdboot-manage writes is read" \
    "$(bl_next_entries sdboot | awk -F '\t' '{print $1}')" "$root/boot/loader/entries/linux-extra.conf"
  cp "$root/boot/vmlinuz-linux-cachyos" "$root/boot/vmlinuz-linux spaced"
  printf '%s\n' 'KERNEL_PATTERN="vmlinuz-linux s*"' > "$d/50-pat.conf"
  run_stub "$root/bin/sdboot-manage" gen
  check "sdboot a KERNEL_PATTERN holding a blank: one glob, its entry read" \
    "$(bl_next_entries sdboot | awk -F '\t' '{print $1}')" "$root/boot/loader/entries/linux spaced.conf"
}
# test bl_setting on shell and kv files
body_setting_readers() {
  local root="$1" f="$1/settings"
  # shellcheck disable=SC2016
  printf '%s\n' "X='a b' # c" 'X="$X c"' 'X+=\ d' > "$f"
  check "bl_setting shell: quotes, a trailing comment, \$X and += as bash reads them" "$(bl_setting X z shell "$f")" \
    "a b c d"
  # shellcheck disable=SC2016
  printf '%s\n' 'X="$(date)"' > "$f"
  check "bl_setting shell: a value only running the file would tell is refused by name" \
    "$(bl_setting X z shell "$f" 2>&1; echo "rc=$?")" \
    "cannot read X in $f: its value has \$(${NL}rc=1"
  printf '%s\n' 'X = "a b" # c' 'Y="q"' > "$f"
  check "bl_setting kv: limine-entry-tool ConfigReader's reading" "$(bl_setting X z kv "$f")|$(bl_setting Y z kv "$f")" \
    '"a b" # c|q'
  printf '%s\n' 'Y="q"' > "$f"
  check "bl_setting: the default when nothing assigns the name" "$(bl_setting Z z shell "$f")" z
  # shellcheck disable=SC2016
  printf '%s\n' 'E=' 'S=abc' 'X="${E:-dflt} ${S:-no} ${S:+set} ${E:+no}"' > "$f"
  check "bl_setting shell: \${X:-text} and \${X:+text} as bash takes them" "$(bl_setting X z shell "$f")" \
    "dflt abc set "
  # shellcheck disable=SC2016
  printf '%s\n' 'X="$X q"' > "$f"
  check "bl_setting shell: a name sought expands to its default before it is assigned" "$(bl_setting X z shell "$f")" \
    "z q"
  # shellcheck disable=SC2016
  printf '%s\n' 'O=$(cat /x)' 'O+=" a"' 'X="$O"' > "$f"
  check "bl_setting shell: += onto an unknown value stays unknown" "$(bl_setting X z shell "$f" 2>&1; echo "rc=$?")" \
    "cannot read X in $f: its value has \$O${NL}rc=1"
  printf '%s\n' "$BEGIN" > "$f"; printf '%s\n' 'TARGET_OS_NAME="Mine"' > "$f.2"
  check "bl_setting kv: a later file after one whose rhizo block is not closed: read" \
    "$(bl_setting TARGET_OS_NAME "" kv "$f" "$f.2")" Mine
}
# test bl_setting refusals of non-assignment lines
body_setting_not_plain() {
  local root="$1" f="$1/settings" form n=0
  local -a forms=(
    'if false; then X=a; fi' 'X=a && X=b' 'X=a || X=b' '[ -f /x ] && X=b' 'case y in y) X=b ;; esac'
    'for i in 1; do X=b; done' 'while false; do X=b; done' 'f() { X=b; }' 'function f { X=b; }' '. /other'
    'source /other' 'unset X' 'declare X=b' 'readonly X=b' 'local X=b' 'cat <<EOF' 'X=(a b)' 'X[0]=b'
    "X=\"a \\" "X=a \\" 'X=a | cat' 'X=a > /x' 'X=a; Y=b'
  )
  for form in "${forms[@]}"; do
    n=$((n + 1))
    printf '%s\n' 'X=0' "$form" > "$f"
    check "bl_setting refuses a line not plain assignments ($n): $form" \
      "$(bl_setting X z shell "$f" 2>&1; echo "rc=$?")" \
      "cannot read X in $f: it is not plain assignments (line 2)${NL}rc=1"
  done
  printf '%s\n' 'X=0' 'INITRD_ENTRIES=(intel-ucode.img "amd ucode.img") # microcode' > "$f"
  check "bl_setting: a literal array for another name is read past" "$(bl_setting X z shell "$f" 2>&1; echo "rc=$?")" \
    "0${NL}rc=0"
  # shellcheck disable=SC2016
  for form in 'Y=(a $Z)' 'Y=(a `z`)' 'Y=(~/a)' 'Y=(a' 'Y+=(a)'; do
    printf '%s\n' 'X=0' "$form" > "$f"
    check "bl_setting refuses an array it cannot read past: $form" "$(bl_setting X z shell "$f" 2>&1; echo "rc=$?")" \
      "cannot read X in $f: it is not plain assignments (line 2)${NL}rc=1"
  done
  # shellcheck disable=SC2016
  for form in 'GRUB_X=$(x) ; unset GRUB_CMDLINE_LINUX_DEFAULT' 'GRUB_X="$HOME" GRUB_CMDLINE_LINUX_DEFAULT="lsm=x"'; do
    printf '%s\n' 'GRUB_CMDLINE_LINUX_DEFAULT="quiet"' "$form" > "$f"
    check "bl_shell_words refuses a line going on after a value it cannot tell: $form" \
      "$(bl_shell_words GRUB_CMDLINE_LINUX 'GRUB_CMDLINE_LINUX[A-Z_]*' "$f" 2>&1; echo "rc=$?")" \
      "cannot read GRUB_CMDLINE_LINUX in $f: it is not plain assignments (line 2)${NL}rc=1"
  done
  printf '%s\n' 'X=~/a' > "$f"
  check "bl_setting: a tilde, which bash expands, is a value only running the file would tell" \
    "$(bl_setting X z shell "$f" 2>&1; echo "rc=$?")" \
    "cannot read X in $f: its value has ~${NL}rc=1"
  printf '%s\n' '# comment' 'LINUX_OPTIONS="nowatchdog quiet splash"' '#LINUX_FALLBACK_OPTIONS=""' \
    'REMOVE_EXISTING="no"' 'OVERWRITE_EXISTING="yes"' 'REMOVE_OBSOLETE="yes"' > "$f"
  check "the stock sdboot-manage.conf reads" "$(bl_setting LINUX_OPTIONS "" shell "$f")" "nowatchdog quiet splash"
  printf '%s\n' 'GRUB_DEFAULT=0' 'GRUB_TIMEOUT=5' 'GRUB_DISTRIBUTOR="Arch"' \
    'GRUB_CMDLINE_LINUX_DEFAULT="splash quiet zswap.enabled=0 nowatchdog"' 'GRUB_CMDLINE_LINUX=""' \
    'GRUB_PRELOAD_MODULES="part_gpt part_msdos"' 'GRUB_TIMEOUT_STYLE=menu' 'GRUB_TERMINAL_INPUT=console' \
    '#GRUB_TERMINAL_OUTPUT=console' 'GRUB_GFXMODE=auto' 'GRUB_GFXPAYLOAD_LINUX=keep' 'GRUB_DISABLE_RECOVERY=true' > "$f"
  check "the stock /etc/default/grub reads" "$(bl_shell_words GRUB_CMDLINE_LINUX 'GRUB_CMDLINE_LINUX[A-Z_]*' "$f" \
    | awk -F '\t' '{printf "%s ", $3}')" "splash quiet zswap.enabled=0 nowatchdog "
  printf '%s\n' 'NAME="CachyOS Linux"' 'PRETTY_NAME="CachyOS"' 'ID=cachyos' 'ID_LIKE=arch' 'BUILD_ID=rolling' \
    'ANSI_COLOR="38;2;23;147;209"' 'HOME_URL="https://cachyos.org/"' 'LOGO=cachyos' > "$f"
  check "the stock os-release reads" "$(bl_setting PRETTY_NAME "" shell "$f")" CachyOS
}
# test KERNEL_PATTERN INITRD_PREFIX and DISABLE_FALLBACK
body_sdboot_tool_rule() {
  local root="$1" e="$1/boot/loader/entries" f="$1/etc/sdboot-manage.conf"
  printf 'title FB\noptions root=x\n' > "$e/linux-cachyos-fallback.conf"
  check "sdboot a -fallback.conf with no /initramfs-<name>-fallback.img is not one sdboot-manage writes" \
    "$(bl_next_entries sdboot | grep -c fallback)" 0
  touch "$root/initramfs-linux-cachyos-fallback.img"
  check "sdboot with that image the -fallback.conf is read" "$(bl_next_entries sdboot | grep -c fallback)" 1
  printf 'DISABLE_FALLBACK="yes"\n' >> "$f"
  check "sdboot DISABLE_FALLBACK=yes: no fallback entry read" "$(bl_next_entries sdboot | grep -c fallback)" 0
  printf 'KERNEL_PATTERN="vmlinuz-linux-cachyos-lts"\n' >> "$f"
  touch "$root/boot/vmlinuz-linux-cachyos-lts"; printf 'options lts\n' > "$e/linux-cachyos-lts.conf"
  check "sdboot KERNEL_PATTERN picks the kernels whose entries are read" "$(bl_next_cmdlines sdboot)" lts
  sed -i '/^KERNEL_PATTERN=/d; /^DISABLE_FALLBACK=/d' "$f"
  printf 'INITRD_PREFIX="booster"\n' >> "$f"
  check "sdboot INITRD_PREFIX names the fallback image" "$(bl_next_entries sdboot | grep -c fallback)" 0
  touch "$root/booster-linux-cachyos-fallback.img"
  check "sdboot INITRD_PREFIX's fallback image there: read" "$(bl_next_entries sdboot | grep -c fallback)" 1
}
# test an unreadable sdboot-manage.conf.d
body_sdboot_confd_unreadable() {
  local root="$1" d="$1/etc/sdboot-manage.conf.d" out tokens
  mkdir -p "$d"; chmod 000 "$d"
  out=$(bootloader_cmdline_tokens sdboot 2>&1; echo "rc=$?")
  tokens=$(bootloader_host_tokens sdboot 2>&1; echo "rc=$?")
  chmod 755 "$d"
  check_unprivileged "sdboot an sdboot-manage.conf.d this uid cannot read: the cmdlines cannot be told" "$out" \
    "cannot read $d as uid $EUID${NL}rc=2"
  check_unprivileged "sdboot an sdboot-manage.conf.d this uid cannot read: the host's own tokens cannot be told" \
    "$tokens" "cannot read $d as uid $EUID${NL}rc=2"
}
# test bl_cmdline_overridden and bl_lsm_fault on cmdlines
body_judged_keys() {
  local r=lsm=capability,landlock,lockdown,yama,selinux,bpf mb="$1/modules.builtin" real
  real="$1/lib/modules/$(uname -r)/modules.builtin"
  check "lsm: apparmor before selinux makes apparmor the major LSM" \
    "$(bl_cmdline_overridden "$r lsm=apparmor,selinux" "$r")" "$r lsm=apparmor,selinux"
  check "lsm: selinux before apparmor keeps selinux the major LSM" \
    "$(bl_cmdline_overridden "$r lsm=selinux,apparmor" "$r")" ""
  check "lsm: non-exclusive LSMs before selinux change nothing" \
    "$(bl_cmdline_overridden "$r lsm=landlock,yama,selinux,bpf" "$r")" ""
  check "lsm: smack before selinux" "$(bl_cmdline_overridden "security=selinux lsm=smack,selinux" security=selinux)" \
    "security=selinux lsm=smack,selinux"
  check "lsm: tomoyo, not exclusive, before selinux changes nothing" \
    "$(bl_cmdline_overridden "$r lsm=tomoyo,selinux" "$r")" ""
  check "lsm: tomoyo then apparmor before selinux: apparmor is the major LSM" \
    "$(bl_cmdline_overridden "$r lsm=tomoyo,apparmor,selinux" "$r")" "$r lsm=tomoyo,apparmor,selinux"
  check "lsm: the fault named past tomoyo is apparmor" "$(bl_lsm_fault tomoyo,apparmor,selinux)" \
    "puts apparmor before selinux, so apparmor is the major LSM${NL}put selinux before apparmor in it"
  check "lsm: bpf before selinux overrides rhizo's" \
    "$(bl_cmdline_overridden "$r lsm=landlock,bpf,selinux" "$r")" "$r lsm=landlock,bpf,selinux"
  check "lsm: a later lsm= putting bpf before selinux voids security=selinux too" \
    "$(bl_cmdline_overridden "security=selinux lsm=yama,bpf,selinux" security=selinux)" \
    "security=selinux lsm=yama,bpf,selinux"
  check "lsm: selinux alone, no bpf in the list" "$(bl_cmdline_overridden "$r lsm=selinux" "$r")" ""
  check "lsm: the fault named for bpf before selinux" "$(bl_lsm_fault landlock,bpf,selinux)" \
    "puts bpf before selinux, so /proc/<pid>/attr answers EINVAL and no SELinux context can be read or set${NL}put\
 selinux before bpf in it"
  check "lsm: an exclusive LSM before selinux is named before a bpf ahead of it" "$(bl_lsm_fault bpf,apparmor,selinux)" \
    "puts apparmor before selinux, so apparmor is the major LSM${NL}put selinux before apparmor in it"
  check "selinux=0 turns selinux off" "$(bl_cmdline_overridden "security=selinux selinux=0" security=selinux)" \
    "security=selinux selinux=0"
  check "selinux=0x0 is 0 too" "$(bl_cmdline_overridden "security=selinux selinux=0x0" security=selinux)" \
    "security=selinux selinux=0x0"
  check "selinux=0 then selinux=1: on" \
    "$(bl_cmdline_overridden "selinux=0 security=selinux selinux=1" security=selinux)" ""
  check "selinux=junk is refused, so an earlier selinux=0 stands" \
    "$(bl_cmdline_overridden "selinux=0 security=selinux selinux=junk" security=selinux)" "security=selinux selinux=0"
  check "selinux=+0: kstrtoul takes a leading +, so 0" \
    "$(bl_cmdline_overridden "security=selinux selinux=+0" security=selinux)" "security=selinux selinux=+0"
  check "selinux= past u64 is refused, so selinux stays on" \
    "$(bl_cmdline_overridden "security=selinux selinux=18446744073709551616" security=selinux)" ""
  check "selinux= past u64 is refused, so an earlier selinux=0 stands" \
    "$(bl_cmdline_overridden "selinux=0 security=selinux selinux=18446744073709551616" security=selinux)" \
    "security=selinux selinux=0"
  check "selinux=-1: kstrtoul refuses a -, so an earlier selinux=0 stands" \
    "$(bl_cmdline_overridden "selinux=0 security=selinux selinux=-1" security=selinux)" "security=selinux selinux=0"
  check "selinux=18446744073709551615, u64's largest, is on" \
    "$(bl_cmdline_overridden "selinux=0 security=selinux selinux=18446744073709551615" security=selinux)" ""
  check "enforcing: a later enforcing=1" "$(bl_cmdline_overridden "enforcing=0 enforcing=1" enforcing=0)" \
    "enforcing=0 enforcing=1"
  check "enforcing: a later enforcing=0" "$(bl_cmdline_overridden "enforcing=0 quiet enforcing=0" enforcing=0)" ""
  check "enforcing: 00 is 0 to kstrtoul" \
    "$(bl_cmdline_overridden "enforcing=0 enforcing=1 enforcing=00" enforcing=0)" ""
  check "enforcing: 0x0 is 0 to kstrtoul" \
    "$(bl_cmdline_overridden "enforcing=0 enforcing=1 enforcing=0x0" enforcing=0)" ""
  check "enforcing: +1 is 1 to kstrtoul" "$(bl_cmdline_overridden "enforcing=0 enforcing=+1" enforcing=0)" \
    "enforcing=0 enforcing=+1"
  check "enforcing: junk is ignored, so rhizo's stands" \
    "$(bl_cmdline_overridden "enforcing=0 enforcing=junk" enforcing=0)" ""
  check "enforcing: junk is ignored, so an earlier enforcing=1 stands" \
    "$(bl_cmdline_overridden "enforcing=0 enforcing=1 enforcing=junk" enforcing=0)" "enforcing=0 enforcing=1"
  check "binder.devices: another list later" \
    "$(bl_cmdline_overridden "binder.devices=a,b binder.devices=x" binder.devices=a,b)" \
    "binder.devices=a,b binder.devices=x"
  check "loop.max_loop: a smaller later value" \
    "$(bl_cmdline_overridden "loop.max_loop=64 loop.max_loop=8" loop.max_loop=64)" \
    "loop.max_loop=64 loop.max_loop=8"
  check "loop.max_loop: a larger later value is fine" \
    "$(bl_cmdline_overridden "loop.max_loop=64 loop.max_loop=128" loop.max_loop=64)" ""
  check "loop.max_loop: the dash spelling counts" \
    "$(bl_cmdline_overridden "loop.max_loop=64 loop.max-loop=8" loop.max_loop=64)" "loop.max_loop=64 loop.max-loop=8"
  check "loop.max_loop: -1, which param_set_int takes" \
    "$(bl_cmdline_overridden "loop.max_loop=64 loop.max_loop=-1" loop.max_loop=64)" "loop.max_loop=64 loop.max_loop=-1"
  check "loop.max_loop: past int is refused, so rhizo's stands" \
    "$(bl_cmdline_overridden "loop.max_loop=64 loop.max_loop=-2147483649" loop.max_loop=64)" ""
  printf 'kernel/drivers/block/nbd.ko\nkernel/drivers/block/loop.ko\n' > "$mb"
  check "loop.max_loop: loop built in, the built-in driver's max_loop= counts" \
    "$(RHIZO_BL_MODULES_BUILTIN=$mb bl_cmdline_overridden "loop.max_loop=64 max_loop=8" loop.max_loop=64)" \
    "loop.max_loop=64 max_loop=8"
  check "loop.max_loop: loop built in, simple_strtol reads max_loop=8k as 8" \
    "$(RHIZO_BL_MODULES_BUILTIN=$mb bl_cmdline_overridden "loop.max_loop=64 max_loop=8k" loop.max_loop=64)" \
    "loop.max_loop=64 max_loop=8k"
  check "loop.max_loop: loop built in, simple_strtol reads max_loop=64k as 64" \
    "$(RHIZO_BL_MODULES_BUILTIN=$mb bl_cmdline_overridden "loop.max_loop=64 max_loop=64k" loop.max_loop=64)" ""
  check "loop.max_loop: loop built in, simple_strtol reads max_loop=08 as octal 0" \
    "$(RHIZO_BL_MODULES_BUILTIN=$mb bl_cmdline_overridden "loop.max_loop=8 max_loop=08" loop.max_loop=8)" \
    "loop.max_loop=8 max_loop=08"
  check "loop.max_loop: loop built in, simple_strtol reads max_loop=0x40 as 64" \
    "$(RHIZO_BL_MODULES_BUILTIN=$mb bl_cmdline_overridden "loop.max_loop=64 max_loop=0x40" loop.max_loop=64)" ""
  printf 'kernel/drivers/block/nbd.ko\n' > "$mb"
  check "loop.max_loop: loop a module, a host max_loop= does nothing" \
    "$(RHIZO_BL_MODULES_BUILTIN=$mb bl_cmdline_overridden "loop.max_loop=64 max_loop=8" loop.max_loop=64)" ""
  check "loop.max_loop: no modules.builtin for the running kernel, a bare max_loop= cannot be judged, by name" \
    "$(bl_cmdline_overridden "loop.max_loop=64 max_loop=8" loop.max_loop=64 2>&1; echo "rc=$?")" \
    "cannot tell whether loop is built into $(uname -r): $real cannot be read${NL}rc=1"
  check "loop.max_loop: no modules.builtin and no bare max_loop=: never asked" \
    "$(bl_cmdline_overridden "loop.max_loop=64 loop.max_loop=8" loop.max_loop=64 2>&1; echo "rc=$?")" \
    "loop.max_loop=64 loop.max_loop=8${NL}rc=0"
  chmod 000 "$mb"
  check_unprivileged "loop.max_loop: a modules.builtin this uid cannot read cannot tell, by name" \
    "$(RHIZO_BL_MODULES_BUILTIN=$mb bl_cmdline_overridden "loop.max_loop=64 max_loop=8" loop.max_loop=64 2>&1
       echo "rc=$?")" "grep: $mb: Permission denied${NL}cannot tell whether loop is built into $(uname -r): $mb\
 cannot be read${NL}rc=1"
  chmod 644 "$mb"
  mkdir -p "$1/nouname"; printf '#!/bin/sh\nexit 1\n' > "$1/nouname/uname"; chmod +x "$1/nouname/uname"
  check "loop.max_loop: no kernel release, a bare max_loop= cannot be judged, by name" \
    "$(PATH="$1/nouname:$PATH" bl_cmdline_overridden "loop.max_loop=64 max_loop=8" loop.max_loop=64 2>&1
       echo "rc=$?")" "cannot tell whether loop is built into the running kernel: uname -r failed${NL}rc=1"
  mkdir -p "${real%/*}"; printf 'kernel/drivers/block/loop.ko\n' > "$real"
  check "loop.max_loop: the running kernel's own modules.builtin is read" \
    "$(bl_cmdline_overridden "loop.max_loop=64 max_loop=8" loop.max_loop=64)" "loop.max_loop=64 max_loop=8"
  check "loop.max_loop: a value the kernel refuses leaves rhizo's" \
    "$(bl_cmdline_overridden "loop.max_loop=64 loop.max_loop=many" loop.max_loop=64)" ""
  check "zswap.enabled: Y means 1" "$(bl_cmdline_overridden "zswap.enabled=0 zswap.enabled=Y" zswap.enabled=0)" \
    "zswap.enabled=0 zswap.enabled=Y"
  check "zswap.enabled: on means 1" "$(bl_cmdline_overridden "zswap.enabled=0 zswap.enabled=on" zswap.enabled=0)" \
    "zswap.enabled=0 zswap.enabled=on"
  check "zswap.enabled: off means 0" \
    "$(bl_cmdline_overridden "zswap.enabled=0 zswap.enabled=Y zswap.enabled=off" zswap.enabled=0)" ""
  check "zswap.enabled: a value kstrtobool refuses is ignored" \
    "$(bl_cmdline_overridden "zswap.enabled=0 zswap.enabled=Y zswap.enabled=x" zswap.enabled=0)" \
    "zswap.enabled=0 zswap.enabled=Y"
  check "zswap.enabled: N means 0" "$(bl_cmdline_overridden "zswap.enabled=1 zswap.enabled=N" zswap.enabled=1)" \
    "zswap.enabled=1 zswap.enabled=N"
  check "zswap.enabled: enabled means 1, kstrtobool reading its e" \
    "$(bl_cmdline_overridden "zswap.enabled=0 zswap.enabled=enabled" zswap.enabled=0)" \
    "zswap.enabled=0 zswap.enabled=enabled"
  check "zswap.enabled: E means 1" "$(bl_cmdline_overridden "zswap.enabled=0 zswap.enabled=E" zswap.enabled=0)" \
    "zswap.enabled=0 zswap.enabled=E"
  check "zswap.enabled: disabled means 0, kstrtobool reading its d" \
    "$(bl_cmdline_overridden "zswap.enabled=0 zswap.enabled=Y zswap.enabled=disabled" zswap.enabled=0)" ""
  check "zswap.enabled: D means 0" \
    "$(bl_cmdline_overridden "zswap.enabled=0 zswap.enabled=Y zswap.enabled=D" zswap.enabled=0)" ""
  check "audit_backlog_limit: a smaller later value" \
    "$(bl_cmdline_overridden "audit_backlog_limit=32768 audit_backlog_limit=64" audit_backlog_limit=32768)" \
    "audit_backlog_limit=32768 audit_backlog_limit=64"
  check "audit_backlog_limit: a larger later value is fine" \
    "$(bl_cmdline_overridden "audit_backlog_limit=32768 audit_backlog_limit=65536" audit_backlog_limit=32768)" ""
  check "audit_backlog_limit: kstrtouint refuses -1, so rhizo's stands" \
    "$(bl_cmdline_overridden "audit_backlog_limit=32768 audit_backlog_limit=-1" audit_backlog_limit=32768)" ""
  check "not judged: log_buf_len=, systemd.unified_cgroup_hierarchy=" \
    "$(bl_cmdline_overridden "log_buf_len=16M systemd.unified_cgroup_hierarchy=1 log_buf_len=1M \
systemd.unified_cgroup_hierarchy=0" "log_buf_len=16M systemd.unified_cgroup_hierarchy=1")" ""
  check "the wording: an lsm= voids a security=, wherever it is" \
    "$(bl_override_why security=selinux lsm=landlock,bpf "X in f")" "the host's own lsm=landlock,bpf, set by X in f,\
 voids rhizo's security=selinux, as the kernel ignores security= beside any lsm=, and leaves selinux out of the LSM\
 list -- remove that lsm= from the host's own line, or add selinux to it"
  check "the wording: an exclusive LSM before selinux" "$(bl_override_why "$r" lsm=apparmor,selinux "X in f")" \
    "the host's own lsm=apparmor,selinux, set by X in f, comes after rhizo's $r on the next boot's cmdline and puts\
 apparmor before selinux, so apparmor is the major LSM -- remove that lsm= from the host's own line, or put selinux\
 before apparmor in it"
}

# test the PATH order for bootloader_regen
body_regen_path_order() {
  local root="$1" user="$1/home/user/bin"
  mkdir -p "$user"
  printf '#!/bin/bash\necho "the grub-gen on the caller'"'"'s PATH"\n' > "$user/grub-gen"
  chmod +x "$user/grub-gen"
  check "a helper on the caller's PATH runs before a system directory's" \
    "$(PATH="$user:$root/bin:$TMP/tools" bootloader_regen grub-dropin)" "the grub-gen on the caller's PATH"
}

mkdir -p "$TMP/show-root"; link_bootstrap_tools "$TMP/show-tools"
# shellcheck disable=SC2016
RHIZO_BL_ROOT="$TMP/show-root" PATH="$TMP/show-tools" "$BL_FIX_BASH" -c '. "$1" && add_ubuntu_host "$2"' _ \
  "$HERE/fixtures/bootloader-fixtures.sh" "$TMP/show-root" || { echo "FAIL the ubuntu host fixture for --show"; exit 1; }
REAL_TOK=$(BOOT_AS_USER=1 boot_run "$TMP/show-root" "$TMP/show-tools" "$BOOT" --show)
[[ -n "$REAL_TOK" ]] || { echo "FAIL no tokens from $BOOT --show"; exit 1; }
REAL_TOK_LSM=$(BOOT_AS_USER=1 boot_run "$TMP/show-root" "$TMP/show-tools" "$BOOT" --lsm-list --show)
[[ -n "$REAL_TOK_LSM" ]] || { echo "FAIL no tokens from $BOOT --lsm-list --show"; exit 1; }

with_root cachyos setup_limine               body_limine
with_root cachyos setup_limine               body_limine_two_keys
with_root cachyos setup_limine               body_limine_quoted_key
with_root cachyos setup_limine               body_limine_no_base
with_root cachyos setup_limine               body_limine_no_cmdline
with_root cachyos setup_limine               body_limine_whole_words
with_root cachyos setup_limine               body_limine_unterminated
with_root cachyos setup_limine               body_limine_mode
with_root cachyos setup_limine               body_limine_remove_clean
with_root cachyos setup_limine               body_limine_regen_fails
with_root cachyos setup_limine               body_limine_tokens_refused
with_root cachyos setup_limine               body_limine_strip_fails
with_root cachyos setup_limine               body_limine_remove_no_newline
with_root cachyos setup_limine               body_limine_no_plain_base
with_root cachyos setup_limine               body_limine_append_base
with_root cachyos setup_limine               body_limine_crlf
with_root cachyos setup_limine               body_limine_lost
with_root cachyos setup_limine               body_limine_lost_clean
with_root cachyos setup_limine               body_limine_lost_words
with_root cachyos setup_limine               body_limine_rollback_regen_fails
with_root cachyos setup_limine               body_capture_rules
with_root cachyos setup_limine               body_holders
with_root cachyos setup_limine               body_strip
with_root cachyos setup_limine               body_remaining
with_root cachyos setup_limine               body_regen_installed
with_root ubuntu  setup_grub_dropin          body_grub_dropin_strip
with_root cachyos setup_grub_inline          body_regenerator
with_root ubuntu  setup_grub_dropin          body_grub_host_tokens
with_root cachyos setup_limine               body_limine_host_tokens
with_root cachyos setup_sdboot               body_sdboot_host_tokens
with_root cachyos setup_limine               body_leftover
with_root cachyos setup_limine               body_android_tokens
with_root cachyos setup_limine               body_missing_unreadable
with_root ubuntu  setup_grub_dropin          body_grub_missing_unreadable
with_root cachyos setup_limine               body_boot_unsearchable
with_root cachyos setup_limine               body_wrappers_unreadable
with_root cachyos setup_limine               body_found_kind_wins
with_root cachyos setup_limine               body_refind_after_blocked
with_root cachyos setup_sdboot               body_sdboot_entries_unreadable
with_root ubuntu  setup_grub_dropin          body_regen_host_cmd
with_root ubuntu  setup_grub_dropin          body_grub_scope
with_root cachyos setup_limine_symlink       body_limine_symlink
with_root cachyos setup_limine_entries_dir   body_limine_entries_dir
with_root cachyos setup_sdboot               body_sdboot
with_root cachyos setup_sdboot               body_sdboot_both_vars
with_root cachyos setup_sdboot               body_sdboot_whole_words
with_root cachyos setup_sdboot               body_sdboot_no_base
with_root cachyos setup_sdboot               body_sdboot_lost
with_root cachyos setup_sdboot               body_sdboot_lost_clean
with_root cachyos setup_sdboot               body_sdboot_unreadable
with_root cachyos setup_grub_inline          body_grub_inline
with_root cachyos setup_grub_inline          body_strip_fails
with_root cachyos setup_grub_inline          body_replace_cleanup
with_root cachyos setup_grub_inline          body_replace_sync
with_root cachyos setup_grub_inline          body_grub_inline_rollback
with_root ubuntu  setup_grub_dropin          body_grub_dropin
with_root ubuntu  setup_grub_dropin          body_grub_dropin_tokens_refused
with_root ubuntu  setup_grub_dropin          body_grub_dropin_rollback
with_root ubuntu  setup_grub_dropin          body_grub_dropin_atomic
with_root cachyos setup_two                  body_two
with_root cachyos setup_refind               body_refind
with_root cachyos setup_nothing              body_nothing
with_root arch    setup_nothing              body_unsupported
with_root ubuntu  setup_nothing              body_ubuntu_no_grub
with_root ubuntu  setup_ubuntu_grub_no_update body_ubuntu_no_update_grub
with_root cachyos setup_nothing              body_kinds
with_root cachyos setup_nothing              body_real_configs
with_root cachyos setup_nothing              body_last_wins
with_root cachyos setup_limine               body_limine_lsm_host
with_root cachyos setup_grub_inline          body_grub_lsm_host
with_root cachyos setup_sdboot               body_sdboot_lsm_host
with_root cachyos setup_sdboot               body_missing_entries
with_root ubuntu  setup_grub_dropin_sbin     body_regen_path_order
with_root cachyos setup_limine               body_limine_os_by_name
with_root cachyos setup_limine               body_limine_tool_sources
with_root cachyos setup_limine               body_limine_unquoted_line
with_root cachyos setup_limine               body_limine_os_precedence
with_root cachyos setup_limine               body_limine_no_machine_id
with_root cachyos setup_limine               body_limine_base_in_dropin
with_root cachyos setup_limine               body_limine_key_in_dropin
with_root cachyos setup_sdboot               body_sdboot_pattern_comment
with_root cachyos setup_nothing              body_setting_readers
with_root cachyos setup_nothing              body_setting_not_plain
with_root cachyos setup_sdboot               body_sdboot_initrd_entries
with_root cachyos setup_grub_inline          body_shell_sources_unreadable
with_root cachyos setup_sdboot               body_shell_sources_unreadable
with_root cachyos setup_nothing              body_untooled
with_root cachyos setup_grub_inline          body_grub_reset
with_root cachyos setup_limine               body_limine_dropin_unreadable
with_root cachyos setup_nothing              body_refind_leftover_grub
with_root cachyos setup_sdboot               body_sdboot_shell_reading
with_root cachyos setup_sdboot               body_sdboot_tool_rule
with_root cachyos setup_sdboot               body_sdboot_confd_unreadable
with_root cachyos setup_nothing              body_judged_keys
with_root ubuntu  setup_grub_dropin_sbin     body_update_grub_sbin_only
with_root cachyos setup_limine_usr_bin       body_limine_update_usr_bin_only
with_root ubuntu  setup_grub_dropin_user     body_update_grub_user_path
with_root cachyos setup_limine_user          body_limine_update_user_path
with_root cachyos setup_limine_linked        body_limine_link_unreachable
with_root cachyos setup_sdboot_entry_linked  body_sdboot_entry_link
with_root cachyos setup_limine               body_limine_esp_link
with_root cachyos setup_limine               body_limine_esp_stock
with_root cachyos setup_limine_efi           body_limine_esp_efi
with_root cachyos setup_limine_stale         body_limine_esp_stale
with_root cachyos setup_limine_efi           body_limine_esp_missing
with_root cachyos setup_limine_auto          body_limine_esp_auto
with_root cachyos setup_limine_dropin_esp    body_limine_esp_dropin
with_root cachyos setup_limine_efi           body_limine_esp_forms
with_root ubuntu  setup_grub_dropin          body_etc_default_unsearchable_ubuntu
with_root cachyos setup_sdboot               body_sdboot_conf_link
with_root cachyos setup_grub_inline          body_grub_default_link
with_root ubuntu  setup_grub_dropin          body_dropin_link
with_root cachyos setup_limine               body_limine_relative_link
with_root cachyos setup_limine               body_limine_link_chain
with_root cachyos setup_limine               body_etc_default_unsearchable_cachyos

with_root cachyos setup_limine               body_rhizo_entry_names
with_root cachyos setup_limine_rhizo         body_default_limine
with_root cachyos setup_sdboot_rhizo         body_default_sdboot
with_root ubuntu  setup_grub_dropin_rhizo    body_default_grub_dropin
with_root cachyos setup_grub_inline_rhizo    body_default_grub_inline
with_root cachyos setup_limine               body_default_no_rhizo_kernel
with_root cachyos setup_limine_rhizo         body_default_refusals
with_root ubuntu  setup_grub_dropin_rhizo    body_default_restore_readback
with_root cachyos setup_limine_kernels       body_limine_joint_removal
FAILED=$(grep -c '' "$TMP/failed")
SKIPPED=$(grep -c '' "$TMP/skipped")
SKIP_NOTE=""; (( SKIPPED )) && SKIP_NOTE=", $SKIPPED skipped as root"
(( FAILED )) && { echo "$FAILED failed$SKIP_NOTE"; exit 1; }
echo "test-bootloader: ok$SKIP_NOTE"
