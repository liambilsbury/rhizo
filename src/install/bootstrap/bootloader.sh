#!/bin/bash
# edit rhizo's cmdline tokens in the bootloader config
RHIZO_BL_ROOT="${RHIZO_BL_ROOT:-}"
BL_KINDS="grub-dropin grub-inline limine sdboot"
BL_MARK_BEGIN="# >>> rhizo"
BL_MARK_END="# <<< rhizo"
BL_GRUB_DEFAULT="$RHIZO_BL_ROOT/etc/default/grub"
BL_GRUB_DROPIN="$RHIZO_BL_ROOT/etc/default/grub.d/90-rhizo.cfg"
BL_GRUB_CFG="$RHIZO_BL_ROOT/boot/grub/grub.cfg"
BL_LIMINE_DEFAULT="$RHIZO_BL_ROOT/etc/default/limine"
BL_LIMINE_REMOVE_LIST="$RHIZO_BL_ROOT/var/lib/limine/removed_kernels.list"
BL_LIMINE_CONFS=("$RHIZO_BL_ROOT/boot/limine.conf" "$RHIZO_BL_ROOT/boot/limine/limine.conf" "$RHIZO_BL_ROOT/efi/limine.conf"
                 "$RHIZO_BL_ROOT/boot/efi/limine.conf" "$RHIZO_BL_ROOT/boot/EFI/limine/limine.conf"
                 "$RHIZO_BL_ROOT/limine/limine.conf")
BL_SDBOOT_CONF="$RHIZO_BL_ROOT/etc/sdboot-manage.conf"
BL_SDBOOT_ENTRIES="$RHIZO_BL_ROOT/boot/loader/entries"
BL_KERNEL_CMDLINE="$RHIZO_BL_ROOT/etc/kernel/cmdline"
BL_REFIND_CONF="$RHIZO_BL_ROOT/boot/refind_linux.conf"
BL_GRUB_ENV="$RHIZO_BL_ROOT/boot/grub/grubenv"
BL_EFIVARS="$RHIZO_BL_ROOT/sys/firmware/efi/efivars"
BL_LIMINE_LAST_ENTRY="$BL_EFIVARS/LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a"
BL_SDBOOT_DEFAULT_ENTRY="$BL_EFIVARS/LoaderEntryDefault-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
BL_SAVED_DEFAULT="${BL_SAVED_DEFAULT:-0}"

# print the unknown kind error and fail
bl_bad_kind() {
  echo "unknown bootloader kind '$1'" >&2
  return 1
}

BL_MAX_LINKS=40

# print the target of a symlink
bl_link_target() {
  local t
  t=$(readlink -- "$1") || return 1
  [[ "$t" == /* ]] || t="${1%/*}/$t"
  echo "$t"
}

# print the nearest unsearchable directory above a path
bl_unsearchable() {
  local d="$1" n="${2:-0}" t
  while [[ "$d" == /?* ]]; do
    d="${d%/*}"; d="${d:-/}"
    if [[ -d "$d" ]]; then
      if [[ -x "$d" ]]; then return 1; fi
      echo "$d"; return 0
    fi
    if [[ -L "$d" ]] && (( n < BL_MAX_LINKS )); then
      t=$(bl_link_target "$d") || { echo "$d"; return 0; }
      bl_unsearchable "$t/." $((n + 1)); return
    fi
  done
  return 1
}

# print a cannot-read message for a path
bl_unreadable() {
  local d t n="${2:-0}"
  if [[ -e "$1" ]]; then
    if [[ -r "$1" && ( ! -d "$1" || -x "$1" ) ]]; then return 1; fi
    echo "cannot read $1 as uid $EUID"; return 0
  fi
  if [[ -L "$1" ]] && (( n < BL_MAX_LINKS )); then
    t=$(bl_link_target "$1") || { echo "cannot read $1 as uid $EUID"; return 0; }
    bl_unreadable "$t" $((n + 1)); return
  fi
  d=$(bl_unsearchable "$1" "$n") || return 1
  echo "cannot read $d as uid $EUID"
}

# print the limine.conf path
bl_limine_conf() {
  local c why out esp
  local -a files=()
  out=$(bl_limine_tool_confs) || return 2
  [[ -z "$out" ]] || mapfile -t files <<<"$out"
  for c in "${files[@]}"; do
    if why=$(bl_unreadable "$c"); then echo "$why" >&2; return 2; fi
  done
  esp=$(bl_setting ESP_PATH "" kv "${files[@]}") || return 2
  if [[ -n "$esp" ]]; then
    c="$RHIZO_BL_ROOT${esp%/}/limine.conf"
    if [[ -f "$c" ]]; then echo "$c"; return 0; fi
    if why=$(bl_unreadable "$c"); then echo "$why" >&2; return 2; fi
    echo "limine-entry-tool's ESP_PATH is $esp, but there is no $c: mount the ESP at $esp, or set ESP_PATH to" \
         "where it is mounted" >&2
    return 2
  fi
  for c in "${BL_LIMINE_CONFS[@]}"; do
    if [[ -f "$c" ]]; then echo "$c"; return 0; fi
    if why=$(bl_unreadable "$c"); then echo "$why" >&2; return 2; fi
  done
  return 1
}

# print the bootloader kind of this host
bootloader_kind() {
  local flavor why rc blocked="" untooled="" found=()
  if [[ -n "${RHIZO_BOOTLOADER:-}" ]]; then
    [[ " $BL_KINDS " == *" $RHIZO_BOOTLOADER "* ]] || { echo "RHIZO_BOOTLOADER is '$RHIZO_BOOTLOADER', not one of $BL_KINDS" >&2; return 1; }
    echo "$RHIZO_BOOTLOADER"; return 0
  fi
  flavor=$(host_flavor) || true
  case "$flavor" in
    ubuntu)
      if [[ ! -f "$BL_GRUB_DEFAULT" ]]; then
        if why=$(bl_unreadable "$BL_GRUB_DEFAULT"); then echo "$why" >&2; return 2; fi
        echo "no $BL_GRUB_DEFAULT -- this host does not use GRUB" >&2
        return 1
      fi
      bootloader_regen_installed grub-dropin \
        || { echo "no update-grub in any of $(bl_system_dirs ', ') -- grub2-common is not installed" >&2; return 1; }
      echo grub-dropin; return 0 ;;
    cachyos) ;;
    *) echo "cannot find the bootloader on $flavor" >&2; return 1 ;;
  esac
  if bootloader_regen_installed limine; then
    if [[ -f "$BL_LIMINE_DEFAULT" ]]; then
      rc=0; why=$(bl_limine_conf 2>&1 >/dev/null) || rc=$?
      case $rc in 0) found+=(limine) ;; 2) blocked=$why ;; esac
    elif why=$(bl_unreadable "$BL_LIMINE_DEFAULT"); then blocked=$why; fi
  elif [[ -f "$BL_LIMINE_DEFAULT" ]]; then untooled+="; $BL_LIMINE_DEFAULT is there, but no limine-update is"
  fi
  if bootloader_regen_installed sdboot; then
    if [[ ! -f "$BL_SDBOOT_CONF" ]]; then
      if why=$(bl_unreadable "$BL_SDBOOT_CONF"); then blocked=$why; fi
    elif [[ -d "$BL_SDBOOT_ENTRIES" ]]; then found+=(sdboot)
    elif why=$(bl_unreadable "$BL_SDBOOT_ENTRIES"); then blocked=$why; fi
  elif [[ -f "$BL_SDBOOT_CONF" ]]; then untooled+="; $BL_SDBOOT_CONF is there, but no sdboot-manage is"
  fi
  if bootloader_regen_installed grub-inline; then
    if [[ ! -f "$BL_GRUB_DEFAULT" ]]; then
      if why=$(bl_unreadable "$BL_GRUB_DEFAULT"); then blocked=$why; fi
    elif [[ -f "$BL_GRUB_CFG" ]]; then found+=(grub-inline)
    elif why=$(bl_unreadable "$BL_GRUB_CFG"); then blocked=$why; fi
  elif [[ -f "$BL_GRUB_DEFAULT" ]]; then untooled+="; $BL_GRUB_DEFAULT is there, but no grub-mkconfig is"
  fi
  if (( ${#found[@]} == 1 )); then echo "${found[0]}"; return 0; fi
  if (( ${#found[@]} > 1 )); then
    echo "more than one bootloader is configured here (${found[*]}) -- set RHIZO_BOOTLOADER to the one that boots this machine" >&2
    return 1
  fi
  if [[ -n "$blocked" ]]; then echo "$blocked" >&2; return 2; fi
  if [[ -f "$BL_REFIND_CONF" ]]; then
    echo "this host boots through rEFInd, whose $BL_REFIND_CONF rhizo does not edit -- supported: limine, systemd-boot with sdboot-manage, grub" >&2
    return 1
  fi
  if why=$(bl_unreadable "$BL_REFIND_CONF"); then echo "$why" >&2; return 2; fi
  if [[ -n "$untooled" ]]; then
    echo "${untooled#; } in any of $(bl_system_dirs ', ') to regenerate its config -- install it" >&2
    return 1
  fi
  echo "no supported bootloader configuration found (looked for $BL_LIMINE_DEFAULT, $BL_SDBOOT_CONF, $BL_GRUB_DEFAULT)" >&2
  return 1
}

# print the config file for a kind
bootloader_config_file() {
  case "$1" in
    grub-dropin) echo "$BL_GRUB_DROPIN" ;;
    grub-inline) echo "$BL_GRUB_DEFAULT" ;;
    limine)      echo "$BL_LIMINE_DEFAULT" ;;
    sdboot)      echo "$BL_SDBOOT_CONF" ;;
    *)           bl_bad_kind "$1" ;;
  esac
}

# print the generated config path for a kind
bootloader_generated() {
  local rc=0
  case "$1" in
    grub-dropin|grub-inline) echo "$BL_GRUB_CFG" ;;
    limine)
      bl_limine_conf || rc=$?
      (( rc != 1 )) || echo "no limine.conf found (looked for ${BL_LIMINE_CONFS[*]})" >&2
      return "$rc" ;;
    sdboot) echo "$BL_SDBOOT_ENTRIES" ;;
    *)      bl_bad_kind "$1" ;;
  esac
}

# print the regeneration command name for a kind
bootloader_regen_label() {
  case "$1" in
    grub-dropin) echo "update-grub" ;;
    grub-inline) echo "grub-mkconfig" ;;
    limine)      echo "limine-update" ;;
    sdboot)      echo "sdboot-manage gen" ;;
    *)           bl_bad_kind "$1" ;;
  esac
}

# print the regeneration command line for a kind
bootloader_regen_cmd() {
  case "$1" in
    grub-dropin) echo "/usr/sbin/update-grub" ;;
    grub-inline) echo "/usr/bin/grub-mkconfig -o /boot/grub/grub.cfg" ;;
    limine)      echo "/usr/bin/limine-update" ;;
    sdboot)      echo "/usr/bin/sdboot-manage gen" ;;
    *)           bl_bad_kind "$1" ;;
  esac
}

BL_SYSTEM_DIRS="/usr/bin /usr/sbin /bin /sbin /usr/local/sbin /usr/local/bin"

# print the system directories under RHIZO_BL_ROOT
bl_system_dirs() {
  local d out=""
  for d in $BL_SYSTEM_DIRS; do out+="${out:+$1}$RHIZO_BL_ROOT$d"; done
  echo "$out"
}

# print the path of the regeneration command
bl_regen_path() {
  local usual label dir
  usual=$(bootloader_regen_cmd "$1") || return 1
  usual=${usual%% *}
  if [[ -x "$RHIZO_BL_ROOT$usual" ]]; then echo "$usual"; return 0; fi
  label=$(bootloader_regen_label "$1")
  for dir in $BL_SYSTEM_DIRS; do
    if [[ -x "$RHIZO_BL_ROOT$dir/${label%% *}" ]]; then echo "$dir/${label%% *}"; return 0; fi
  done
  return 1
}

# check the regeneration command exists
bootloader_regen_installed() {
  bl_regen_path "$1" >/dev/null
}

# print the regeneration command line for this host
bootloader_regen_host_cmd() {
  local usual path
  usual=$(bootloader_regen_cmd "$1") || return 1
  path=$(bl_regen_path "$1") || { echo "this host has no $(bootloader_regen_label "$1")" >&2; return 1; }
  echo "$path${usual#"${usual%% *}"}"
}

# print the bootloader name for a kind
bootloader_target() {
  case "$1" in
    grub-dropin|grub-inline) echo grub ;;
    limine|sdboot)           echo "$1" ;;
    *)                       bl_bad_kind "$1" ;;
  esac
}

# print a kind with an installed regeneration command
bootloader_regenerator() {
  local target k
  target=$(bootloader_target "$1") || return 1
  for k in ${2:+"$2"} "$1" $BL_KINDS; do
    if [[ "$(bootloader_target "$k")" == "$target" ]] && bootloader_regen_installed "$k"; then echo "$k"; return 0; fi
  done
  return 1
}

# run the regeneration command for a kind
bootloader_regen() {
  local path rc=0 aside=""
  local -a args
  case "$1" in
    grub-dropin|limine) args=() ;;
    grub-inline)        args=(-o "$BL_GRUB_CFG") ;;
    sdboot)             args=(gen) ;;
    *)                  bl_bad_kind "$1"; return ;;
  esac
  if [[ "$1" == limine && -e "$BL_LIMINE_REMOVE_LIST.rhizo-regen" ]]; then
    if ! { cat -- "$BL_LIMINE_REMOVE_LIST.rhizo-regen" >> "$BL_LIMINE_REMOVE_LIST" \
           && rm -f -- "$BL_LIMINE_REMOVE_LIST.rhizo-regen"; } 2>&1; then
      echo "could not put the record an interrupted run left in $BL_LIMINE_REMOVE_LIST.rhizo-regen back onto" \
           "$BL_LIMINE_REMOVE_LIST"
      return 1
    fi
  fi
  path=$(bl_regen_path "$1") || { echo "this host has no $(bootloader_regen_label "$1")"; return 127; }
  if [[ "$1" == limine && -e "$BL_LIMINE_REMOVE_LIST" ]]; then
    aside="$BL_LIMINE_REMOVE_LIST.rhizo-regen"
    if ! mv -f -- "$BL_LIMINE_REMOVE_LIST" "$aside" 2>&1; then
      echo "could not set $BL_LIMINE_REMOVE_LIST aside"
      return 1
    fi
  fi
  PATH="${PATH:+$PATH:}$(bl_system_dirs :)" "$RHIZO_BL_ROOT$path" "${args[@]}" 2>&1 || rc=$?
  if [[ -n "$aside" ]] && ! mv -f -- "$aside" "$BL_LIMINE_REMOVE_LIST" 2>&1; then
    echo "could not put $BL_LIMINE_REMOVE_LIST back from $aside"
    (( rc )) || rc=1
  fi
  return "$rc"
}

# shellcheck disable=SC2016
BL_AWK_L='{ l = $0; sub(/\r$/, "", l) }'

BL_SAVED_KIND=""
BL_SAVED_HAD=0
BL_SAVED_TEXT=""

# print the lines outside rhizo's block
bl_block_strip() {
  awk -v b="$BL_MARK_BEGIN" -v e="$BL_MARK_END" "$BL_AWK_L"' l == b {skip = 1; next} l == e {skip = 0; next} !skip' "$1"
}

# print rhizo's marked block from a file
bl_block_get() {
  awk -v b="$BL_MARK_BEGIN" -v e="$BL_MARK_END" "$BL_AWK_L"' l == b {on = 1} on {print} l == e {on = 0}' "$1"
}

# check a file for rhizo's begin marker
bl_block_has() {
  awk -v b="$BL_MARK_BEGIN" "$BL_AWK_L"' l == b {found = 1} END {exit !found}' "$1"
}

# check a file's begin and end markers
bl_block_check() {
  local rc=0
  awk -v b="$BL_MARK_BEGIN" -v e="$BL_MARK_END" "$BL_AWK_L"' l == b {if (open) bad = 1; open = 1} l == e {open = 0} END {if (open || bad) exit 3}' "$1" || rc=$?
  case $rc in
    0) return 0 ;;
    3) echo "$1 has a '$BL_MARK_BEGIN' line with no '$BL_MARK_END' line after it -- fix the file by hand" >&2 ;;
    *) echo "cannot read $1: awk exited $rc" >&2 ;;
  esac
  return 1
}

# grep the file text outside the rhizo block
bl_outside_has() {
  local text
  text=$(bl_block_strip "$1") || return 2
  grep -Eq -- "$2" <<<"$text"
}

# replace a file with command output
bl_replace() {
  local file tmp
  local -a chmod_args=("$1")
  file=$(readlink -f -- "$2") || return 1
  [[ "$1" != keep ]] || chmod_args=(--reference="$file")
  shift 2
  tmp=$(mktemp "$file.XXXXXX") || return 1
  if "$@" > "$tmp" && chmod "${chmod_args[@]}" "$tmp" && sync "$tmp" && mv "$tmp" "$file"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# print the file mode for a grub drop-in
bl_dropin_mode() {
  if [[ -e "$1" ]]; then echo keep; else echo 0644; fi
}

# print the KERNEL_CMDLINE keys set outside rhizo's block
bl_limine_keys() {
  local set
  set=$(bl_limine_settings) || return 1
  awk -F '\t' '
    NF && $2 != "" { if (!($2 in spelled)) order[++n] = $2; spelled[$2] = $3 }
    END {
      for (i = 1; i <= n; i++) { k = spelled[order[i]]; sub(/^KERNEL_CMDLINE\[/, "", k); sub(/\]$/, "", k); print k }
    }
  ' <<<"$set"
}

# print rhizo's block for a kind
bl_block_text() {
  local kind="$1" tokens="$2" k keys fb=0
  case "$kind" in
    limine) keys=$(bl_limine_keys) || return 1 ;;
    sdboot)
      bl_outside_has "$BL_SDBOOT_CONF" '^[[:space:]]*LINUX_FALLBACK_OPTIONS=' || fb=$?
      (( fb == 2 )) && return 1 ;;
  esac
  echo "$BL_MARK_BEGIN"
  case "$kind" in
    grub-inline)
      echo "GRUB_CMDLINE_LINUX=\"\${GRUB_CMDLINE_LINUX:+\$GRUB_CMDLINE_LINUX }$tokens\""
      [[ "$BL_SAVED_DEFAULT" != 1 ]] || echo "GRUB_DEFAULT=saved" ;;
    sdboot)
      echo "LINUX_OPTIONS=\"\$LINUX_OPTIONS $tokens\""
      (( fb == 0 )) && echo "LINUX_FALLBACK_OPTIONS=\"\$LINUX_FALLBACK_OPTIONS $tokens\"" ;;
    limine)
      while IFS= read -r k; do
        echo "KERNEL_CMDLINE[$k]+=\" $tokens\""
      done <<<"$keys" ;;
  esac
  echo "$BL_MARK_END"
}

# print a file with rhizo's block rewritten
bl_block_rewrite() {
  bl_block_strip "$3" && bl_block_text "$1" "$2"
}

# print the grub drop-in text
bl_grub_dropin_text() {
  if [[ "$BL_SAVED_DEFAULT" == 1 && " $1 " == *selinux* ]]; then
    cat <<EOF
# Written by install/bootstrap/bootstrap.sh: Rhizo's kernel command line
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:+\$GRUB_CMDLINE_LINUX }$1"
GRUB_DEFAULT=saved
EOF
    return
  fi
  if [[ "$BL_SAVED_DEFAULT" == 1 ]]; then
    cat <<EOF
# Written by install/bootstrap/bootstrap.sh: Rhizo's kernel command line
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:+\$GRUB_CMDLINE_LINUX }$1"
GRUB_DEFAULT=saved
EOF
    return
  fi
  cat <<EOF
# Written by install/bootstrap/bootstrap.sh: Rhizo's kernel command line
GRUB_CMDLINE_LINUX="\${GRUB_CMDLINE_LINUX:+\$GRUB_CMDLINE_LINUX }$1"
EOF
}

# validate a kernel command line token string
bl_tokens_ok() {
  local - LC_ALL=C tok why any=0
  set -f
  for tok in $1; do
    [[ "$tok" =~ ^[A-Za-z0-9_.,=:/+@-]+$ ]] || { echo "token '$tok' has a character outside [A-Za-z0-9_.,=:/+@-]" >&2; return 1; }
    any=1
  done
  (( any )) || { echo "no tokens given" >&2; return 1; }
  case "$1" in
    " "*)     why="a leading space" ;;
    *" ")     why="a trailing space" ;;
    *$'\t'*)  why="a tab" ;;
    *$'\n'*)  why="a newline" ;;
    *"  "*)   why="a double space" ;;
    *)        return 0 ;;
  esac
  echo "the token string has $why; tokens are separated by single spaces only" >&2
  return 1
}

# check the bootloader config sets a base cmdline
bl_base_check() {
  local kind="$1" file="$2" rc=0 re msg set
  case "$kind" in
    limine)
      set=$(bl_limine_settings) || return 1
      awk -F '\t' '$2 == "default" && ($1 == "=" || $5 ~ /[^[:space:]]/) {found = 1} END {exit !found}' <<<"$set" && return 0
      echo "neither $file nor limine-entry-tool's own config files set KERNEL_CMDLINE[default] -- copy the" \
           "running cmdline into KERNEL_CMDLINE[default] in $file first" >&2
      return 1 ;;
    sdboot)
      re='^[[:space:]]*LINUX_OPTIONS='
      msg="$file sets no LINUX_OPTIONS -- copy the running cmdline into LINUX_OPTIONS there first" ;;
    *) return 0 ;;
  esac
  bl_outside_has "$file" "$re" || rc=$?
  case $rc in
    0) return 0 ;;
    1) echo "$msg" >&2 ;;
    *) echo "cannot read $file" >&2 ;;
  esac
  return 1
}

# save a file's text for bootloader_rollback
bl_save() {
  local text
  if [[ -f "$2" ]]; then
    text=$(cat -- "$2" && echo x) || return 1
    BL_SAVED_TEXT=${text%x}
    BL_SAVED_HAD=1
  else
    BL_SAVED_TEXT=""
    BL_SAVED_HAD=0
  fi
  BL_SAVED_KIND="$1"
}

# print the saved file text
bl_saved_text() {
  printf '%s' "$BL_SAVED_TEXT"
}

# write rhizo's tokens into a kind's config file
bootloader_write() {
  local kind="$1" tokens="$2" file
  BL_SAVED_KIND=""
  file=$(bootloader_config_file "$kind") || return 1
  bl_tokens_ok "$tokens" || return 1
  if [[ "$kind" != grub-dropin ]]; then
    [[ -f "$file" ]] || { echo "no $file to put rhizo's tokens in" >&2; return 1; }
    bl_block_check "$file" || return 1
    bl_base_check "$kind" "$file" || return 1
  fi
  bl_save "$kind" "$file" || return 1
  if [[ "$kind" == grub-dropin ]]; then
    mkdir -p "$(dirname "$file")" && bl_replace "$(bl_dropin_mode "$file")" "$file" bl_grub_dropin_text "$tokens"
  else
    bl_replace keep "$file" bl_block_rewrite "$kind" "$tokens" "$file"
  fi || { BL_SAVED_KIND=""; echo "could not write $file" >&2; return 1; }
}

# write rhizo's tokens and regenerate the config
bootloader_apply() {
  bootloader_write "$1" "$2" || return
  bootloader_regen "$1"
}

# restore the saved config file text
bootloader_restore() {
  local kind="$1" file
  file=$(bootloader_config_file "$kind") || return 1
  if [[ "$BL_SAVED_KIND" != "$kind" ]]; then
    echo "no bootloader_write for $kind in this shell to roll back" >&2
    return 1
  fi
  if [[ "$kind" == grub-dropin ]]; then
    if (( BL_SAVED_HAD )); then bl_replace "$(bl_dropin_mode "$file")" "$file" bl_saved_text; else rm -f "$file"; fi
  else
    bl_replace keep "$file" bl_saved_text
  fi || { echo "could not restore $file" >&2; return 1; }
}

# restore the replaced text and regenerate
bootloader_rollback() {
  bootloader_restore "$1" || return 1
  bootloader_regen "$1" || return
  BL_SAVED_KIND=""
}

# check a kind's config file holds the tokens
bootloader_config_current() {
  local kind="$1" tokens="$2" file want
  file=$(bootloader_config_file "$kind") || return 1
  bl_tokens_ok "$tokens" || return 1
  [[ -f "$file" ]] || return 1
  if [[ "$kind" == grub-dropin ]]; then
    [[ "$(cat "$file")" == "$(bl_grub_dropin_text "$tokens")" ]]
  else
    want=$(bl_block_text "$kind" "$tokens") || return 1
    [[ "$(bl_block_get "$file")" == "$want" ]]
  fi
}

# check a kind's file for rhizo's tokens
bootloader_present() {
  local file why rc=0
  file=$(bootloader_config_file "$1") || return 1
  if [[ "$1" == grub-dropin ]]; then
    [[ ! -e "$file" ]] || return 0
    if why=$(bl_unreadable "$file"); then echo "$why" >&2; return 2; fi
    return 1
  fi
  if why=$(bl_unreadable "$file"); then echo "$why" >&2; return 2; fi
  [[ -f "$file" ]] || return 1
  bl_block_has "$file" || rc=$?
  case $rc in
    0|1) return "$rc" ;;
    *)   echo "cannot read $file: awk exited $rc" >&2; return 3 ;;
  esac
}

# print the kinds with rhizo's tokens
bootloader_holders() {
  local kind rc held=""
  for kind in $BL_KINDS; do
    rc=0
    bootloader_present "$kind" || rc=$?
    case $rc in
      0) held+="$kind"$'\n' ;;
      1) ;;
      2) return 2 ;;
      *) return 1 ;;
    esac
  done
  printf '%s' "$held"
}

BL_LIMINE_TOOL_MARK="### This kernel entry is auto-generated by limine-entry-tool"

# print the existing files among the paths
bl_conf_files() {
  local p f why
  for p; do
    if [[ "$p" == */ ]]; then
      if why=$(bl_unreadable "${p%/}"); then echo "$why" >&2; return 2; fi
      for f in "$p"*.conf; do [[ ! -f "$f" ]] || echo "$f"; done
    elif [[ -e "$p" ]]; then
      echo "$p"
    fi
  done
}
# print the limine-entry-tool config file paths
bl_limine_tool_confs() {
  bl_conf_files "$RHIZO_BL_ROOT/usr/share/limine-entry-tool.d/" "$RHIZO_BL_ROOT/etc/limine-entry-tool.conf" \
    "$RHIZO_BL_ROOT/etc/limine-entry-tool.d/" "$BL_LIMINE_DEFAULT"
}
# print the sdboot-manage config file paths
bl_sdboot_confs() {
  bl_conf_files "$BL_SDBOOT_CONF" "$RHIZO_BL_ROOT/usr/lib/sdboot-manage.conf.d/" \
    "$RHIZO_BL_ROOT/etc/sdboot-manage.conf.d/"
}
# shellcheck disable=SC2016
BL_AWK_SH='
  function ref(m,    k) {
    rn = ""; rl = 0; rop = ""; rt = ""
    if (match(m, /^[$][A-Za-z_][A-Za-z0-9_]*/)) { rn = substr(m, 2, RLENGTH - 1); rl = RLENGTH; return }
    if (match(m, /^[$][{][A-Za-z_][A-Za-z0-9_]*[}]/)) { rn = substr(m, 3, RLENGTH - 3); rl = RLENGTH; return }
    if (match(m, /^[$][{][A-Za-z_][A-Za-z0-9_]*:[-+]/) && (k = index(m, "}"))) {
      rn = substr(m, 3, RLENGTH - 4); rop = substr(m, RLENGTH, 1); rt = substr(m, RLENGTH + 1, k - RLENGTH - 1)
      rl = k
    }
  }
  # expand the variable reference in m
  function deref(m,    name, op, txt, len, x, k, depth, ch) {
    ref(m); len = rl; name = rn; op = rop; txt = rt; dl = len
    if (!len) {
      if (bad == "") bad = substr(m, 1, 2)
      if (substr(m, 1, 2) == "$(") {
        for (k = 2; k <= length(m); k++) {
          ch = substr(m, k, 1)
          if (ch == "(") depth++
          else if (ch == ")" && --depth == 0) break
        }
        if (k > length(m)) shape = 1
        dl = k
      } else if (substr(m, 1, 2) == "${") { k = index(m, "}"); if (!k) { shape = 1; k = length(m) } dl = k }
      else dl = (length(m) > 1) ? 2 : 1
      xo = ""; return ""
    }
    if (!(name in V)) {
      if (name !~ want) { if (bad == "") bad = "$" name; xo = ""; return "" }
      V[name] = d; O[name] = ""
    }
    if ((op == "-" && V[name] == "") || (op == "+" && V[name] != "")) { x = expand_text(txt); dl = len; return x }
    if (op == "+") { xo = ""; dl = len; return "" }
    xo = O[name]; dl = len; return V[name]
  }
  function expand_text(t,    o, oo, c, x) {
    o = ""; oo = ""
    while (t != "" && bad == "") {
      c = substr(t, 1, 1)
      if (c == "$") { x = deref(t); o = o x; oo = oo xo; t = substr(t, dl + 1) }
      else if (c == "`") bad = c
      else { o = o c; oo = oo me; t = substr(t, 2) }
    }
    xo = oo; return o
  }
  # return the length of the backtick command
  function tick(m,    j) {
    if (bad == "") bad = "`"
    j = index(substr(m, 2), "`"); if (!j) { shape = 1; return length(m) }
    return j + 1
  }
  # return the index of the closing parenthesis
  function array_end(m,    i, c, q) {
    for (i = 2; i <= length(m); i++) {
      c = substr(m, i, 1)
      if (q != "") { if (c == q) q = "" }
      else if (c == "\"" || c == "\047") q = c
      else if (c == ")") return i
    }
    return 0
  }
  # read the value of an assignment
  function word(s,    out, i, c, j, x) {
    out = ""; wo = ""; i = 1
    while (i <= length(s) && !shape) {
      c = substr(s, i, 1)
      if (c ~ /[ \t;&|<>()]/) break
      if (c == "\047") {
        j = index(substr(s, i + 1), "\047"); if (!j) { shape = 1; break }
        x = substr(s, i + 1, j - 1); out = out x; wo = wo mine(x); i += j + 1
      } else if (c == "\"") {
        for (i++; i <= length(s) && !shape && (c = substr(s, i, 1)) != "\""; ) {
          if (c == "\\" && substr(s, i + 1, 1) ~ /[$`"\\]/) { out = out substr(s, i + 1, 1); wo = wo me; i += 2 }
          else if (c == "$") { x = deref(substr(s, i)); out = out x; wo = wo xo; i += dl }
          else if (c == "`") i += tick(substr(s, i))
          else { out = out c; wo = wo me; i++ }
        }
        if (i > length(s)) { shape = 1; break }
        i++
      } else if (c == "\\") {
        if (i == length(s)) { shape = 1; break }
        out = out substr(s, i + 1, 1); wo = wo me; i += 2
      }
      else if (c == "$") { x = deref(substr(s, i)); out = out x; wo = wo xo; i += dl }
      else if (c == "`") i += tick(substr(s, i))
      else {
        if (c == "~" && (i == 1 || substr(s, i - 1, 1) == ":") && bad == "") bad = c
        out = out c; wo = wo me; i++
      }
    }
    wl = i - 1
    return out
  }
  function mine(x,    o) { o = ""; while (length(o) < length(x)) o = o me; return o }
  function not_plain() {
    printf "cannot read %s in %s: it is not plain assignments (line %d)\n", label, FILENAME, FNR > "/dev/stderr"
    failed = 1; exit 1
  }
  # assign a value to a variable
  function assign(nm, add, v) {
    if (bad == "" && add && (nm in unknown)) bad = "$" nm
    if (bad != "") {
      if (nm ~ want) {
        printf "cannot read %s in %s: its value has %s\n", nm, FILENAME, \
          bad > "/dev/stderr"
        failed = 1; exit 1
      }
      delete V[nm]; delete O[nm]; unknown[nm] = 1; return
    }
    delete unknown[nm]
    if (!(nm in V)) { V[nm] = ""; O[nm] = "" }
    V[nm] = (add ? V[nm] : "") v; O[nm] = (add ? O[nm] : "") wo
    if (nm ~ want && !(nm in seen)) { seen[nm] = 1; order[++names] = nm }
  }
  FNR == 1 { skip = 0; me = sprintf("%c", 48 + ++files); file[me] = FILENAME }
  $0 == b { skip = 1; next }
  $0 == e { skip = 0; next }
  skip || $0 ~ /^[[:space:]]*(#.*)?$/ { next }
  $0 ~ /^[[:space:]]*export([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)+[[:space:]]*(#.*)?$/ { next }
  {
    rest = $0; sub(/^[[:space:]]*(export[[:space:]]+)?/, "", rest)
    do {
      if (!match(rest, /^[A-Za-z_][A-Za-z0-9_]*[+]?=/)) not_plain()
      nm = substr(rest, 1, RLENGTH); add = (nm ~ /[+]=$/); sub(/[+]?=$/, "", nm)
      rest = substr(rest, RLENGTH + 1)
      if (substr(rest, 1, 1) == "(") {
        k = array_end(rest)
        if (add || nm ~ want || !k || substr(rest, 1, k) ~ /[$`~]/) not_plain()
        delete V[nm]; delete O[nm]; unknown[nm] = 1
        rest = substr(rest, k + 1); sub(/^[ \t]+/, "", rest)
        continue
      }
      bad = ""; shape = 0; v = word(rest)
      if (shape) not_plain()
      rest = substr(rest, wl + 1)
      assign(nm, add, v)
      sub(/^[ \t]+/, "", rest)
      if (bad != "" && rest != "" && rest !~ /^#/) not_plain()
    } while (rest != "" && rest !~ /^#/)
  }
'

# print the last value assigned to a variable
bl_setting() {
  local name="$1" def="$2" how="$3"
  shift 3
  if (( ! $# )); then echo "$def"; return 0; fi
  if [[ "$how" == kv ]]; then
    awk -v n="$name" -v d="$def" -v b="$BL_MARK_BEGIN" -v e="$BL_MARK_END" '
      FNR == 1 { skip = 0 }
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      {
        l = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", l)
        if (skip || l == "" || substr(l, 1, 1) == "#") next
        a = index(l, "+="); q = index(l, "=")
        if (a) { k = substr(l, 1, a - 1); v = substr(l, a + 2) } else if (q) { k = substr(l, 1, q - 1); v = substr(l, q + 1) } else next
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", k); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"") v = substr(v, 2, length(v) - 2)
        if (k == n) { val = v; set = 1 }
      }
      END { print set ? val : d }' "$@"
    return
  fi
  awk -v want="^$name\$" -v label="$name" -v d="$def" -v b="$BL_MARK_BEGIN" -v e="$BL_MARK_END" "$BL_AWK_SH"'
    END { if (!failed) print (names ? V[order[1]] : d) }' "$@"
}

# print each word of the matching variables
bl_shell_words() {
  local label="$1" ere="$2"
  shift 2
  (( $# )) || return 0
  awk -v want="^($ere)\$" -v label="$label" -v d="" -v b="$BL_MARK_BEGIN" -v e="$BL_MARK_END" "$BL_AWK_SH"'
    END {
      if (failed) exit 1
      for (k = 1; k <= names; k++) {
        n = order[k]; s = V[n]; w = ""
        for (i = 1; i <= length(s) + 1; i++) {
          c = substr(s, i, 1)
          if (c == "" || c ~ /[ \t]/) { if (w != "") print n "\t" file[f] "\t" w; w = "" }
          else { if (w == "") f = substr(O[n], i, 1); w = w c }
        }
      }
    }' "$@"
}

# print the limine.conf kernel entries and cmdlines
bl_limine_entries() {
  local rc=0
  awk -v w="$1" -v mark="$BL_LIMINE_TOOL_MARK" -v mid="$2" -v tname="$3" -v pname="$4" '
    function header(l) { sub(/^[[:space:]]*/, "", l); sub(/[[:space:]]*$/, "", l); return l }
    function close_entry() { if (own && !printed) print w " entry " path "\t"; own = 0 }
    NR == FNR {
      if ($0 ~ /^[[:space:]]*\/+/) {
        l = header($0); d = match(l, /[^\/]/) - 1
        if (d == 1) { nodes++; nm = substr(l, 2); sub(/^\+/, "", nm); osname[nodes] = nm; body = 1 } else body = 0
      } else if (body && $0 ~ /^[[:space:]]*comment:/ && (" " $0) ~ /[[:space:]]machine-id=/) {
        hasmid[nodes] = 1
        if (!bymid && mid != "" && (" " $0 " ") ~ ("[[:space:]]machine-id=" mid "[[:space:]]")) bymid = nodes
      }
      next
    }
    !picked {
      picked = 1; target = bymid
      for (i = 1; !target && tname != "" && i <= nodes; i++) if (osname[i] == tname && !hasmid[i]) target = i
      for (i = 1; !target && pname != "" && i <= nodes; i++) if (osname[i] == pname && !hasmid[i]) target = i
    }
    /^[[:space:]]*\/+/ {
      close_entry()
      l = header($0); depth = match(l, /[^\/]/) - 1; name = substr(l, depth + 1); sub(/^\+/, "", name)
      if (depth == 1) node++
      if (skip && depth <= skipdepth) skip = 0
      if (!skip && name == "Snapshots") { skip = 1; skipdepth = depth }
      part[depth] = name; path = part[1]
      for (i = 2; i <= depth; i++) path = path "/" part[i]
      first = 1; printed = 0
      next
    }
    first && NF { first = 0; own = target && node == target && !skip && header($0) == mark }
    own && /^[[:space:]]*cmdline:/ {
      sub(/^[[:space:]]*cmdline:[[:space:]]*/, ""); print w " entry " path "\t" $0; printed = 1
    }
    END { close_entry(); if (!target) exit 3 }
  ' "$1" "$1" || rc=$?
  case $rc in 0|3) return "$rc" ;; *) return 1 ;; esac
}

# print the cmdline of each next-boot entry
bl_next_entries() {
  local f k opts line why rc=0 mid="" tname pname out
  local -a files=()
  case "$1" in
    grub-dropin|grub-inline)
      if why=$(bl_unreadable "$BL_GRUB_CFG"); then echo "$why" >&2; return 2; fi
      if [[ -f "$BL_GRUB_CFG" ]]; then
        awk -v w="$BL_GRUB_CFG" '
          $1 == "###" && $2 == "BEGIN" { sec = ($3 ~ /^\/etc\/grub\.d\/10_linux/); if (sec) marked = 1; next }
          $1 == "###" && $2 == "END" { sec = 0; next }
          $1 == "linux" {
            n++; in10[n] = sec; l = ""
            for (i = 3; i <= NF; i++) l = l (i > 3 ? " " : "") $i
            line[n] = l
          }
          END { for (i = 1; i <= n; i++) if (!marked || in10[i]) print w "\t" line[i] }
        ' "$BL_GRUB_CFG" || return 1
      fi ;;
    limine)
      f=$(bl_limine_conf) || rc=$?
      (( rc != 2 )) || return 2
      (( rc == 0 )) || return 0
      if why=$(bl_unreadable "$f"); then echo "$why" >&2; return 2; fi
      if why=$(bl_unreadable "$RHIZO_BL_ROOT/etc/machine-id"); then echo "$why" >&2; return 2; fi
      [[ ! -s "$RHIZO_BL_ROOT/etc/machine-id" ]] || mid=$(< "$RHIZO_BL_ROOT/etc/machine-id") || return 1
      rc=0; bl_limine_entries "$f" "$mid" "" "" || rc=$?
      (( rc == 3 )) || return "$rc"
      out=$(bl_limine_tool_confs) || return
      [[ -z "$out" ]] || mapfile -t files <<<"$out"
      tname=$(bl_setting TARGET_OS_NAME "" kv "${files[@]}") || return 1
      pname=""
      if [[ -f "${RHIZO_OS_RELEASE:-/etc/os-release}" ]]; then
        pname=$(bl_setting PRETTY_NAME "" shell "${RHIZO_OS_RELEASE:-/etc/os-release}") || return 1
        [[ -n "$pname" ]] || pname=$(bl_setting NAME "" shell "${RHIZO_OS_RELEASE:-/etc/os-release}") || return 1
      fi
      if [[ -z "$pname" && -f "$RHIZO_BL_ROOT/etc/lsb-release" ]]; then
        pname=$(bl_setting DISTRIB_DESCRIPTION "" shell "$RHIZO_BL_ROOT/etc/lsb-release") || return 1
      fi
      rc=0; bl_limine_entries "$f" "" "$tname" "$pname" || rc=$?
      (( rc == 3 )) || return "$rc" ;;
    sdboot)
      out=$(bl_sdboot_own) || return
      [[ -n "$out" ]] || return 0
      while IFS=$'\t' read -r f k; do
        if [[ -e "$f" || -L "$f" ]] && why=$(bl_unreadable "$f"); then echo "$why" >&2; return 2; fi
        [[ -e "$f" ]] || continue
        opts=$(sed -n 's/^options[[:space:]]*//p' "$f") || return 1
        while IFS= read -r line; do printf '%s\t%s\n' "$f" "$line"; done <<<"$opts"
      done <<<"$out" ;;
  esac
}

# print the entry files sdboot-manage writes
bl_sdboot_own() {
  local k kernel name pattern prefix disable why out
  local -a files=()
  if why=$(bl_unreadable "$BL_SDBOOT_ENTRIES"); then echo "$why" >&2; return 2; fi
  out=$(bl_sdboot_confs) || return
  [[ -z "$out" ]] || mapfile -t files <<<"$out"
  pattern=$(bl_setting KERNEL_PATTERN 'vmlinuz-*' shell "${files[@]}") || return 1
  prefix=$(bl_setting INITRD_PREFIX initramfs shell "${files[@]}") || return 1
  disable=$(bl_setting DISABLE_FALLBACK no shell "${files[@]}") || return 1
  local IFS=
  for k in "${BL_SDBOOT_ENTRIES%/loader/entries}"/$pattern; do
    [[ -f "$k" ]] || continue
    kernel="/${k##*/}" name=${kernel//vmlinuz-/}; name=${name#/}
    printf '%s\t%s\n' "$BL_SDBOOT_ENTRIES/$name.conf" main
    if [[ "$disable" != yes && -e "$RHIZO_BL_ROOT${kernel//vmlinuz/$prefix}-fallback.img" ]]; then
      printf '%s\t%s\n' "$BL_SDBOOT_ENTRIES/$name-fallback.conf" fallback
    fi
  done
}

# print the next-boot cmdlines
bl_next_cmdlines() {
  local out line
  out=$(bl_next_entries "$1") || return
  [[ -n "$out" ]] || return 0
  while IFS= read -r line; do printf '%s\n' "${line#*$'\t'}"; done <<<"$out"
}

# print the sorted unique tokens of all of the cmdlines
bootloader_cmdline_tokens() {
  local lines=""
  case "$1" in
    limine|sdboot|grub-dropin|grub-inline) lines=$(bl_next_cmdlines "$1") || return ;;
    *) bl_bad_kind "$1"; return ;;
  esac
  awk '{for (i = 1; i <= NF; i++) print $i}' <<<"$lines" | LC_ALL=C sort -u
}

# print the tokens in the rhizo config block
bootloader_own_tokens() {
  local file text why
  file=$(bootloader_config_file "$1") || return 1
  if why=$(bl_unreadable "$file"); then echo "$why" >&2; return 2; fi
  [[ -f "$file" ]] || return 0
  if [[ "$1" == grub-dropin ]]; then
    text=$(cat -- "$file") || return 1
  else
    bl_block_check "$file" || return 1
    text=$(bl_block_get "$file") || return 1
  fi
  awk '/^[[:space:]]*#/ {next}
    { l = $0; sub(/\r$/, "", l); if (!match(l, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?="/)) next
      v = substr(l, RLENGTH + 1); sub(/"[[:space:]]*$/, "", v)
      sub(/^\$\{[^}]*\}/, "", v); sub(/^\$[A-Za-z_][A-Za-z0-9_]*/, "", v)
      n = split(v, w, /[[:space:]]+/); for (j = 1; j <= n; j++) if (w[j] != "") print w[j] }' <<<"$text" | LC_ALL=C sort -u
}

# print each token the generated config lacks
bootloader_missing() {
  local kind="$1" tokens="$2" tok lines line rc=0
  bl_tokens_ok "$tokens" || return 1
  case "$kind" in
    limine|sdboot|grub-dropin|grub-inline)
      lines=$(bl_next_cmdlines "$kind") || rc=$?
      (( rc != 2 )) || return 2
      if (( rc != 0 )); then
        echo "cannot read the cmdlines in $(bootloader_generated "$kind")" >&2
        return 1
      fi
      for tok in $tokens; do
        while IFS= read -r line; do
          if [[ " $line " != *" $tok "* ]]; then printf ' %s' "$tok"; break; fi
        done <<<"$lines"
      done ;;
    *) bl_bad_kind "$kind" ;;
  esac
}

# print each entry and the tokens it lacks
bootloader_missing_entries() {
  local - entries line where prev="" cmd acc="" tok out rc=0
  bl_tokens_ok "$2" || return 1
  entries=$(bl_next_entries "$1") || rc=$?
  (( rc != 2 )) || return 2
  if (( rc != 0 )); then echo "cannot read the cmdlines in $(bootloader_generated "$1")" >&2; return 1; fi
  set -f
  [[ -n "$entries" ]] || entries="$(bootloader_generated "$1")"$'\t'
  while IFS= read -r line; do
    where=${line%%$'\t'*} cmd=${line#*$'\t'}
    if [[ "$where" != "$prev" ]]; then
      out=""; for tok in $2; do [[ "$acc" != *" $tok "* ]] || out+=" $tok"; done
      [[ -z "$out" ]] || printf '%s\t%s\n' "$prev" "$out"
      prev=$where acc=" "
    fi
    for tok in $2; do [[ " $cmd " == *" $tok "* || "$acc" == *" $tok "* ]] || acc+="$tok "; done
  done <<<"$entries"
  out=""; for tok in $2; do [[ "$acc" != *" $tok "* ]] || out+=" $tok"; done
  [[ -z "$out" ]] || printf '%s\t%s\n' "$prev" "$out"
}

BL_EXCLUSIVE_LSMS="selinux apparmor smack"

# print the cmdline words matching the names
bl_settings() {
  local - w n
  set -f
  for w in $2; do
    [[ "$w" == *=* ]] || continue
    n=${w%%=*}
    [[ " ${1//-/_} " != *" ${n//-/_} "* ]] || echo "$w"
  done
}
# print the last matching cmdline word
bl_last_setting() {
  local all
  all=$(bl_settings "$1" "$2")
  [[ -n "$all" ]] && echo "${all##*$'\n'}"
}
# parse a kernel integer and print it
bl_number() {
  local LC_ALL=C v="$1" kind="${2:-u64}" neg="" base digits max
  case "$v" in
    +*) v=${v#+} ;;
    -*) [[ "$kind" == s32 ]] || return 1; neg=- v=${v#-} ;;
  esac
  if [[ "$v" =~ ^0[xX]([0-9a-fA-F]+)$ ]]; then base=16 digits=${BASH_REMATCH[1],,}
  elif [[ "$v" =~ ^0([0-7]*)$ ]]; then base=8 digits=${BASH_REMATCH[1]}
  elif [[ "$v" =~ ^[1-9][0-9]*$ ]]; then base=10 digits=$v
  else return 1; fi
  while [[ "$digits" == 0?* ]]; do digits=${digits#0}; done
  digits=${digits:-0}
  case "$kind$neg:$base" in
    u64:10) max=18446744073709551615 ;; u64:16) max=ffffffffffffffff ;; u64:8) max=1777777777777777777777 ;;
    u32:10) max=4294967295 ;; u32:16) max=ffffffff ;; u32:8) max=37777777777 ;;
    s32:10) max=2147483647 ;; s32:16) max=7fffffff ;; s32:8) max=17777777777 ;;
    s32-:10) max=2147483648 ;; s32-:16) max=80000000 ;; s32-:8) max=20000000000 ;;
  esac
  # shellcheck disable=SC2071
  (( ${#digits} < ${#max} )) || { (( ${#digits} == ${#max} )) && [[ ! "$digits" > "$max" ]]; } || return 1
  if (( ${#digits} > 15 )); then echo "${neg}9223372036854775807"; else echo "$neg$(( $base#$digits ))"; fi
}
# check and print the unsigned 32-bit value
bl_u32() { bl_number "$1" u32; }
# print the leading number of the value
bl_strtol() {
  local v="$1" neg=""
  [[ "$v" != -* ]] || neg=- v=${v#-}
  if [[ "$v" =~ ^0[xX]([0-9a-fA-F]{1,15}) ]]; then echo "$neg$(( 16#${BASH_REMATCH[1]} ))"
  elif [[ "$v" =~ ^0([0-7]{0,15}) ]]; then echo "$neg$(( 8#${BASH_REMATCH[1]:-0} ))"
  elif [[ "$v" =~ ^([0-9]{1,15}) ]]; then echo "$neg$(( 10#${BASH_REMATCH[1]} ))"
  else echo 0; fi
}
# print 1 or 0 for a boolean value
bl_bool() {
  case "$1" in
    [yYtTeE1]*|[oO][nN]*) echo 1 ;;
    [nNfFdD0]*|[oO][fF]*) echo 0 ;;
    *) return 1 ;;
  esac
}
# print the last valid setting among the names
bl_last_taken() {
  local s last=""
  while IFS= read -r s; do
    [[ -z "$s" ]] || ! "$1" "${s#*=}" >/dev/null || last=$s
  done <<<"$(bl_settings "$2" "$3")"
  [[ -n "$last" ]] && echo "$last"
}
# look up loop in modules.builtin
bl_loop_builtin() {
  local rel f rc=0
  if ! rel=$(uname -r); then
    echo "cannot tell whether loop is built into the running kernel: uname -r failed" >&2; return 2
  fi
  f="${RHIZO_BL_MODULES_BUILTIN:-$RHIZO_BL_ROOT/lib/modules/$rel/modules.builtin}"
  if [[ -f "$f" ]]; then grep -q '/loop\.ko$' "$f" || rc=$?; else rc=2; fi
  (( rc < 2 )) || { echo "cannot tell whether loop is built into $rel: $f cannot be read" >&2; return 2; }
  return "$rc"
}
# test for selinux first among exclusive LSMs
bl_lsm_selinux_major() {
  local - l
  set -f
  for l in ${1//,/ }; do
    [[ " $BL_EXCLUSIVE_LSMS " != *" $l "* ]] || { [[ "$l" == selinux ]]; return; }
  done
  return 1
}
# test for bpf ahead of selinux
bl_lsm_bpf_first() {
  local - l
  set -f
  for l in ${1//,/ }; do
    case "$l" in
      selinux) return 1 ;;
      bpf) return 0 ;;
    esac
  done
  return 1
}
# test for a usable selinux major LSM
bl_lsm_selinux_usable() { bl_lsm_selinux_major "$1" && ! bl_lsm_bpf_first "$1"; }

# print each token a later setting overrides
bl_cmdline_overridden() {
  local - tok key want last have s n v all rc lsmtok=""
  set -f
  for tok in $2; do
    key=${tok%%=*} want=${tok#*=}
    case $key in
      lsm|security)
        lsmtok=$tok
        if last=$(bl_last_setting lsm "$1"); then
          bl_lsm_selinux_usable "${last#*=}" || echo "$tok $last"
        elif [[ "$key" == security ]] && last=$(bl_last_setting security "$1"); then
          [[ "${last#*=}" == selinux ]] || echo "$tok $last"
        fi ;;
      enforcing)
        if last=$(bl_last_taken bl_number enforcing "$1") && have=$(bl_number "${last#*=}") \
           && want=$(bl_number "$want"); then
          (( (have != 0) == (want != 0) )) || echo "$tok $last"
        fi ;;
      binder.devices)
        if last=$(bl_last_setting "$key" "$1"); then [[ "${last#*=}" == "$want" ]] || echo "$tok $last"; fi ;;
      loop.max_loop)
        all=$(bl_settings "loop.max_loop max_loop" "$1") have="" last=""
        while IFS= read -r s; do
          [[ -n "$s" ]] || continue
          n=${s%%=*}
          if [[ "${n//-/_}" == max_loop ]]; then
            rc=0; bl_loop_builtin || rc=$?
            (( rc != 2 )) || return 1
            (( rc == 0 )) || continue
            v=$(bl_strtol "${s#*=}")
          else
            v=$(bl_number "${s#*=}" s32) || continue
          fi
          have=$v last=$s
        done <<<"$all"
        if [[ -n "$have" ]] && want=$(bl_number "$want" s32); then (( have >= want )) || echo "$tok $last"; fi ;;
      audit_backlog_limit)
        if last=$(bl_last_taken bl_u32 "$key" "$1") && have=$(bl_u32 "${last#*=}") && want=$(bl_u32 "$want"); then
          (( have >= want )) || echo "$tok $last"
        fi ;;
      zswap.enabled)
        if last=$(bl_last_taken bl_bool zswap.enabled "$1"); then
          [[ "$(bl_bool "${last#*=}")" == "$(bl_bool "$want")" ]] || echo "$tok $last"
        fi ;;
    esac
  done
  if [[ -n "$lsmtok" ]] && last=$(bl_last_taken bl_number selinux "$1") && (( $(bl_number "${last#*=}") == 0 )); then
    echo "$lsmtok $last"
  fi
}

# print the LSM list fault and its fix
bl_lsm_fault() {
  local - l
  set -f
  if [[ ",$1," != *",selinux,"* ]]; then
    printf '%s\n' "leaves selinux out of the LSM list" "add selinux to it"
    return
  fi
  for l in ${1//,/ }; do
    [[ " $BL_EXCLUSIVE_LSMS " != *" $l "* ]] || break
  done
  if [[ "$l" == selinux ]]; then
    printf '%s\n' "puts bpf before selinux, so /proc/<pid>/attr answers EINVAL and no SELinux context can be read or set" \
      "put selinux before bpf in it"
    return
  fi
  printf '%s\n' "puts $l before selinux, so $l is the major LSM" "put selinux before $l in it"
}

# print the override message for a token
bl_override_why() {
  local key=${2%%=*} what fix
  case ${key//-/_} in
    lsm)
      { IFS= read -r what; IFS= read -r fix; } <<<"$(bl_lsm_fault "${2#*=}")"
      if [[ "$1" == security=* ]]; then
        echo "the host's own $2, set by $3, voids rhizo's $1, as the kernel ignores security= beside any lsm=, and" \
             "$what -- remove that lsm= from the host's own line, or $fix"
      else
        echo "the host's own $2, set by $3, comes after rhizo's $1 on the next boot's cmdline and $what -- remove" \
             "that lsm= from the host's own line, or $fix"
      fi ;;
    selinux)
      echo "the host's own $2, set by $3, turns selinux off on the next boot -- remove that $key= from the host's" \
           "own line" ;;
    loop.max_loop|max_loop|audit_backlog_limit)
      echo "the host's own $2, set by $3, comes after rhizo's $1 on the next boot's cmdline and asks for less --" \
           "remove that $key= from the host's own line, or raise it to at least ${1#*=}" ;;
    *)
      echo "the host's own $2, set by $3, comes after rhizo's $1 on the next boot's cmdline and takes effect instead" \
           "-- remove that $key= from the host's own line" ;;
  esac
}

# print the tokens overridden on any next-boot cmdline
bootloader_overridden() {
  local entries line o found out=""
  entries=$(bl_next_entries "$1") || return
  [[ -n "$entries" ]] || return 0
  while IFS= read -r line; do
    found=$(bl_cmdline_overridden "${line#*$'\t'}" "$2") || return 1
    while IFS= read -r o; do
      [[ -z "$o" || $'\n'"$out" == *$'\n'"$o"$'\n'* ]] || out+="$o"$'\n'
    done <<<"$found"
  done <<<"$entries"
  printf '%s' "$out"
}

# print the tokens present or absent on cmdlines
bl_tokens_where() {
  local - now tok where seen=" "
  now=$(bootloader_cmdline_tokens "$1") || return
  set -f
  for tok in $2; do
    [[ "$seen" != *" $tok "* ]] || continue
    seen+="$tok "
    where=off
    [[ $'\n'"$now"$'\n' != *$'\n'"$tok"$'\n'* ]] || where=on
    [[ "$where" != "$3" ]] || printf ' %s' "$tok"
  done
}

# print each token missing from all cmdlines
bootloader_lost() {
  bl_tokens_where "$1" "$2" off
}

# print each token some cmdline carries
bootloader_remaining() {
  bl_tokens_where "$1" "$2" on
}

# print the words assigned to matching variables
bl_assigned_words() {
  awk -v b="$BL_MARK_BEGIN" -v e="$BL_MARK_END" -v re="^[[:space:]]*(export[[:space:]]+)?($2)[+]?=" \
      -v named="${3:-}" "$BL_AWK_L"'
    l == b {skip = 1; next}
    l == e {skip = 0; next}
    skip || l ~ /^[[:space:]]*#/ || !match(l, re) {next}
    { name = substr(l, RSTART, RLENGTH); sub(/^[[:space:]]*(export[[:space:]]+)?/, "", name); sub(/[+]?=$/, "", name)
      v = substr(l, RLENGTH + 1); q = substr(v, 1, 1)
      if (q == "\"" || q == "\047") { v = substr(v, 2); i = index(v, q); if (i) v = substr(v, 1, i - 1) }
      else sub(/[[:space:]].*/, "", v)
      gsub(/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*/, " ", v)
      n = split(v, w, /[[:space:]]+/)
      for (j = 1; j <= n; j++) if (w[j] != "") print (named == "" ? "" : name "\t") w[j] }' "$1"
}

# print the KERNEL_CMDLINE assignments in limine files
bl_limine_settings() {
  local f out why
  local -a files=()
  out=$(bl_limine_tool_confs) || return
  [[ -z "$out" ]] || mapfile -t files <<<"$out"
  (( ${#files[@]} )) || return 0
  for f in "${files[@]}"; do
    if why=$(bl_unreadable "$f"); then echo "$why" >&2; return 2; fi
  done
  awk -v b="$BL_MARK_BEGIN" -v e="$BL_MARK_END" "$BL_AWK_L"'
    FNR == 1 {skip = 0}
    l == b {skip = 1; next}
    l == e {skip = 0; next}
    skip || l ~ /^[[:space:]]*#/ || !match(l, /^[[:space:]]*KERNEL_CMDLINE\[[^]]*\][+]?=/) {next}
    { name = substr(l, RSTART, RLENGTH); sub(/^[[:space:]]*/, "", name); op = (name ~ /[+]=$/) ? "+" : "="
      sub(/[+]?=$/, "", name); key = name; sub(/^KERNEL_CMDLINE\[/, "", key); sub(/\]$/, "", key)
      gsub(/["\047]/, "", key)
      v = substr(l, RSTART + RLENGTH); sub(/[[:space:]]+$/, "", v)
      if (length(v) > 1 && v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      print op "\t" key "\t" name "\t" FILENAME "\t" v }' "${files[@]}" \
    || { echo "cannot read ${files[*]}" >&2; return 1; }
}

# print the words limine files put on cmdlines
bl_limine_words() {
  local set
  set=$(bl_limine_settings) || return
  awk -F '\t' '
    NF {
      if ($1 == "=") for (i = 1; i <= n; i++) if (k[i] == $2) dead[i] = 1
      m = split($5, w, /[[:space:]]+/)
      for (j = 1; j <= m; j++) if (w[j] != "") { n++; k[n] = $2; out[n] = $3 "\t" $4 "\t" w[j] }
    }
    END { for (i = 1; i <= n; i++) if (!dead[i]) print out[i] }' <<<"$set"
}

# set the BL_HOST_* variables for a kind
bl_host_sources() {
  local f out
  BL_HOST_SRCS=()
  case "$1" in
    grub-dropin|grub-inline)
      BL_HOST_ERE='GRUB_CMDLINE_LINUX[A-Z_]*' BL_HOST_LABEL=GRUB_CMDLINE_LINUX BL_HOST_SRCS=("$BL_GRUB_DEFAULT")
      for f in "$RHIZO_BL_ROOT/etc/default/grub.d"/*.cfg; do
        if [[ "$f" != "$BL_GRUB_DROPIN" ]]; then BL_HOST_SRCS+=("$f"); fi
      done
      return 0 ;;
    sdboot) BL_HOST_ERE='LINUX(_FALLBACK)?_OPTIONS' BL_HOST_LABEL=LINUX_OPTIONS; out=$(bl_sdboot_confs) || return ;;
    *)      bl_bad_kind "$1"; return ;;
  esac
  [[ -z "$out" ]] || mapfile -t BL_HOST_SRCS <<<"$out"
}

# print the cmdline words of the host config
bl_host_words() {
  local f named why
  local -a there=()
  if [[ "$1" == limine ]]; then bl_limine_words; return; fi
  bl_host_sources "$1" || return
  if [[ "$1" == grub-dropin ]]; then
    for f in "${BL_HOST_SRCS[@]}"; do
      [[ -e "$f" ]] || continue
      named=$(bl_assigned_words "$f" "$BL_HOST_ERE" named) || { echo "cannot read $f" >&2; return 1; }
      [[ -z "$named" ]] || awk -F '\t' -v f="$f" '{print $1 "\t" f "\t" $2}' <<<"$named"
    done
    return 0
  fi
  for f in "${BL_HOST_SRCS[@]}"; do
    [[ -e "$f" ]] || continue
    if why=$(bl_unreadable "$f"); then echo "$why" >&2; return 2; fi
    there+=("$f")
  done
  bl_shell_words "$BL_HOST_LABEL" "$BL_HOST_ERE" "${there[@]}"
}

# print the cmdline the host config builds
bl_host_lines() {
  local set words entries own f kcmd="" recovery rc
  local -a there=()
  case "$1" in
    limine)
      rc=0; entries=$(bl_next_entries limine) || rc=$?
      (( rc != 1 )) || { echo "cannot read the cmdlines in $(bootloader_generated limine)" >&2; return 1; }
      (( rc == 0 )) || return "$rc"
      [[ -n "$entries" ]] || return 0
      set=$(bl_limine_settings) || return
      if [[ -e "$BL_KERNEL_CMDLINE" ]]; then
        kcmd=$(awk '{for (i = 1; i <= NF; i++) printf "%s%s", (n++ ? " " : ""), $i}' "$BL_KERNEL_CMDLINE") \
          || { echo "cannot read $BL_KERNEL_CMDLINE" >&2; return 1; }
      fi
      awk -F '\t' -v kcmd="$kcmd" '
        function key(k) { return (k in line) ? k : "default" }
        NR == FNR {
          if (NF < 2) next
          if ($1 == "=") line[$2] = $5
          else line[$2] = $5 (line[$2] != "" && $5 != "" ? " " : "") line[$2]
          next
        }
        {
          e = $1; sub(/\t.*/, "", e); sub(/.*\//, "", e); fb = (e ~ /-fallback$/)
          k = (fb && ("fallback" in line)) ? "fallback" : key(fb ? substr(e, 1, length(e) - 9) : e)
          print ((k in line) ? line[k] : kcmd)
        }' <(printf '%s\n' "$set") <(printf '%s\n' "$entries") ;;
    sdboot)
      own=$(bl_sdboot_own) || return
      [[ -n "$own" ]] || return 0
      words=$(bl_host_words sdboot) || return
      awk -F '\t' '
        NR == FNR { if (NF) v[$1] = v[$1] (v[$1] != "" ? " " : "") $3; next }
        { print ($2 == "fallback") ? v["LINUX_FALLBACK_OPTIONS"] : v["LINUX_OPTIONS"] }
      ' <(printf '%s\n' "$words") <(printf '%s\n' "$own") ;;
    grub-inline|grub-dropin)
      words=$(bl_host_words "$1") || return
      bl_host_sources "$1" || return
      for f in "${BL_HOST_SRCS[@]}"; do [[ ! -e "$f" ]] || there+=("$f"); done
      recovery=$(bl_setting GRUB_DISABLE_RECOVERY false shell "${there[@]}") || return 1
      awk -F '\t' -v recovery="$recovery" '
        NF { v[$1] = v[$1] (v[$1] != "" ? " " : "") $3 }
        END {
          l = v["GRUB_CMDLINE_LINUX"]; d = v["GRUB_CMDLINE_LINUX_DEFAULT"]
          print l (l != "" && d != "" ? " " : "") d
          if (recovery != "true") {
            r = ("GRUB_CMDLINE_LINUX_RECOVERY" in v) ? v["GRUB_CMDLINE_LINUX_RECOVERY"] : "single"
            print r (r != "" && l != "" ? " " : "") l
          }
        }' <<<"$words" ;;
    *) bl_bad_kind "$1" ;;
  esac
}

# print the sorted tokens of the host config
bootloader_host_tokens() {
  local words
  words=$(bl_host_words "$1") || return
  words=$(awk -F '\t' '{print $3}' <<<"$words")
  if [[ "$1" == limine && -e "$BL_KERNEL_CMDLINE" ]]; then
    words+=$'\n'$(awk '{for (i = 1; i <= NF; i++) print $i}' "$BL_KERNEL_CMDLINE") \
      || { echo "cannot read $BL_KERNEL_CMDLINE" >&2; return 1; }
  fi
  awk 'NF' <<<"$words" | LC_ALL=C sort -u
}

# print the variable and file for the token
bootloader_token_source() {
  local words rc=0
  words=$(bl_host_words "$1") || return
  awk -F '\t' -v w="$2" '$3 == w && !seen[$1 "\t" $2]++ {print $1 " in " $2}' <<<"$words"
  [[ "$1" == limine && -e "$BL_KERNEL_CMDLINE" ]] || return 0
  awk -v w="$2" '{for (i = 1; i <= NF; i++) if ($i == w) found = 1} END {exit !found}' "$BL_KERNEL_CMDLINE" || rc=$?
  case $rc in
    0) echo "$BL_KERNEL_CMDLINE" ;;
    1) ;;
    *) echo "cannot read $BL_KERNEL_CMDLINE" >&2; return 1 ;;
  esac
}

# print the cmdline tokens the host config lacks
bootloader_leftover() {
  local - still host tok out=""
  still=$(bootloader_remaining "$1" "$2") || return
  [[ -n "$still" ]] || return 0
  host=$(bootloader_host_tokens "$1") || { printf '%s' "$still"; return 3; }
  set -f
  for tok in $still; do
    [[ $'\n'"$host"$'\n' == *$'\n'"$tok"$'\n'* ]] || out+=" $tok"
  done
  printf '%s' "$out"
}

# print the androidboot tokens on the cmdline
bootloader_android_tokens() {
  local now
  now=$(bootloader_cmdline_tokens "$1") || return
  awk '/^androidboot\./' <<<"$now"
}

# remove rhizo contributions from the config file
bootloader_strip() {
  local kind="$1" file
  file=$(bootloader_config_file "$kind") || return 1
  if [[ "$kind" == grub-dropin ]]; then
    rm -f "$file" || return 1
  elif [[ -f "$file" ]]; then
    bl_block_check "$file" || return 1
    if bl_block_has "$file"; then
      bl_replace keep "$file" bl_block_strip "$file" || { echo "could not write $file" >&2; return 1; }
    fi
  fi
}

# print the path of a tool under RHIZO_BL_ROOT
bl_tool_path() {
  local dir
  for dir in $BL_SYSTEM_DIRS; do
    if [[ -x "$RHIZO_BL_ROOT$dir/$1" ]]; then echo "$RHIZO_BL_ROOT$dir/$1"; return 0; fi
  done
  echo "this host has no $1 in any of $(bl_system_dirs ', ')" >&2
  return 1
}

# check that a boot entry id names a Rhizo kernel
bl_rhizo_entry() {
  local name="${1##*[/>]}"
  name=${name%.conf}; name=${name#gnulinux-}; name=${name%-advanced-*}; name=${name%-fallback}
  [[ "$name" == *-rhizo ]]
}

# print an EFI variable's value as text
bl_efivar_read() {
  [[ -e "$1" ]] || return 0
  tail -c +5 "$1" | tr -d '\0' || { echo "cannot read $1" >&2; return 1; }
}

# write an EFI variable's attributes and NUL-terminated value
bl_efivar_write() {
  local tmp i rc=0
  [[ -d "$BL_EFIVARS" ]] || { echo "no $BL_EFIVARS, so this host's boot loader reads no EFI variable" >&2; return 1; }
  tmp=$(mktemp) || return 1
  {
    printf '\007\000\000\000'
    if [[ "$2" == utf16 ]]; then
      for (( i = 0; i < ${#3}; i++ )); do printf '%s\0' "${3:i:1}"; done
      printf '\0\0'
    else
      printf '%s\0' "$3"
    fi
  } > "$tmp" || rc=1
  if (( rc == 0 )) && [[ -e "$1" ]] && ! chattr -i "$1"; then echo "cannot clear the immutable flag of $1" >&2; rc=1; fi
  if (( rc == 0 )) && ! dd if="$tmp" of="$1" bs=4096 status=none; then echo "cannot write $1" >&2; rc=1; fi
  rm -f "$tmp"
  return "$rc"
}

# remove an EFI variable
bl_efivar_remove() {
  [[ -e "$1" ]] || return 0
  chattr -i "$1" || { echo "cannot clear the immutable flag of $1" >&2; return 1; }
  rm -f "$1" || { echo "cannot remove $1" >&2; return 1; }
}

# print a grubenv variable's value
bl_grub_env_get() {
  [[ -e "$BL_GRUB_ENV" ]] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$BL_GRUB_ENV" \
    || { echo "cannot read $BL_GRUB_ENV" >&2; return 1; }
}

# print grub.cfg's menu entry ids with their submenus
bl_grub_entry_ids() {
  [[ -f "$BL_GRUB_CFG" ]] || { echo "no $BL_GRUB_CFG" >&2; return 1; }
  # shellcheck disable=SC2016
  awk '
    function idof(l) { if (!match(l, /\$menuentry_id_option +\047[^\047]*\047/)) return ""
                       l = substr(l, RSTART, RLENGTH); sub(/^[^\047]*\047/, "", l); sub(/\047$/, "", l); return l }
    /^[[:space:]]*submenu[[:space:]]/ { sub_id = idof($0); next }
    /^}/ { sub_id = "" }
    /^[[:space:]]*menuentry[[:space:]]/ { id = idof($0); if (id != "") print (sub_id != "" ? sub_id ">" : "") id }
  ' "$BL_GRUB_CFG" || { echo "cannot read $BL_GRUB_CFG" >&2; return 1; }
}

# print grub.cfg's default line value
bl_grub_cfg_default() {
  # shellcheck disable=SC2016
  awk '/^[[:space:]]*set[[:space:]]+default=/ { v = $0; sub(/^[^=]*=/, "", v); gsub(/"/, "", v)
                                                if (v != "${next_entry}") last = v }
       END { print last }' "$BL_GRUB_CFG" || { echo "cannot read $BL_GRUB_CFG" >&2; return 1; }
}

# print the stored default entry id for a kind
bl_default_stored() {
  case "$1" in
    limine)                  bl_efivar_read "$BL_LIMINE_LAST_ENTRY" ;;
    sdboot)                  bl_efivar_read "$BL_SDBOOT_DEFAULT_ENTRY" ;;
    grub-dropin|grub-inline) bl_grub_env_get saved_entry ;;
    *)                       bl_bad_kind "$1" ;;
  esac
}

# print the next boot's default entry id
bootloader_default_entry() {
  local def
  case "$1" in
    grub-dropin|grub-inline)
      def=$(bl_grub_cfg_default) || return 1
      # shellcheck disable=SC2016
      if [[ "$def" == '${saved_entry}' ]]; then bl_grub_env_get saved_entry; else echo "$def"; fi ;;
    *) bl_default_stored "$1" ;;
  esac
}

# print all of the boot entry ids of a kind
bl_entry_ids() {
  local out line f k
  case "$1" in
    limine)
      out=$(bl_next_entries limine) || { echo "cannot read the entries in $(bootloader_generated limine)" >&2; return 1; }
      [[ -z "$out" ]] && return 0
      while IFS= read -r line; do line=${line%%$'\t'*}; echo "${line#* entry }"; done <<<"$out" ;;
    sdboot)
      out=$(bl_sdboot_own) || return 1
      [[ -z "$out" ]] && return 0
      while IFS=$'\t' read -r f k; do [[ "$k" != main || ! -e "$f" ]] || echo "${f##*/}"; done <<<"$out" ;;
    grub-dropin|grub-inline) bl_grub_entry_ids ;;
    *) bl_bad_kind "$1" ;;
  esac
}

# print the first matching boot entry id
bl_first_entry() {
  local ids id
  ids=$(bl_entry_ids "$1") || return 1
  while IFS= read -r id; do
    [[ -n "$id" && "${id##*[/>]}" != *-fallback* ]] || continue
    if [[ "$2" == rhizo ]] && bl_rhizo_entry "$id"; then echo "$id"; return 0; fi
    if [[ "$2" == other ]] && ! bl_rhizo_entry "$id"; then echo "$id"; return 0; fi
  done <<<"$ids"
}

# check that the next boot lists an entry id
bl_entry_exists() {
  local ids numeric='^[0-9>]+$'
  [[ "$1" != grub-* || ! "$2" =~ $numeric ]] || return 0
  ids=$(bl_entry_ids "$1") || return 2
  [[ $'\n'"$ids"$'\n' == *$'\n'"$2"$'\n'* ]]
}

# set or clear a kind's stored default entry
bl_default_set() {
  local tool
  case "$1" in
    limine)
      if [[ "$2" == - ]]; then bl_efivar_remove "$BL_LIMINE_LAST_ENTRY"; else bl_efivar_write "$BL_LIMINE_LAST_ENTRY" ascii "$2"; fi ;;
    sdboot)
      if [[ "$2" == - ]]; then bl_efivar_remove "$BL_SDBOOT_DEFAULT_ENTRY"; else bl_efivar_write "$BL_SDBOOT_DEFAULT_ENTRY" utf16 "$2"; fi ;;
    grub-dropin|grub-inline)
      tool=$(bl_tool_path grub-editenv) || return 1
      if [[ "$2" == - ]]; then
        "$tool" "$BL_GRUB_ENV" unset saved_entry || { echo "grub-editenv could not unset saved_entry in $BL_GRUB_ENV" >&2; return 1; }
      else
        "$tool" "$BL_GRUB_ENV" set "saved_entry=$2" || { echo "grub-editenv could not set saved_entry in $BL_GRUB_ENV" >&2; return 1; }
      fi ;;
    *) bl_bad_kind "$1" ;;
  esac
}

# check a kind can make the Rhizo kernel its default
bootloader_rhizo_default_preflight() {
  local kind="$1" conf id
  case "$kind" in
    limine)
      conf=$(bootloader_generated limine) || return 1
      grep -q '^[[:space:]]*remember_last_entry:[[:space:]]*yes' "$conf" \
        || { echo "$conf does not set remember_last_entry: yes, so Limine reads no LimineLastBootedEntry" >&2; return 1; }
      [[ -d "$BL_EFIVARS" ]] || { echo "no $BL_EFIVARS, so this host's boot loader reads no EFI variable" >&2; return 1; } ;;
    sdboot)
      [[ -d "$BL_EFIVARS" ]] || { echo "no $BL_EFIVARS, so this host's boot loader reads no EFI variable" >&2; return 1; } ;;
    grub-dropin|grub-inline) bl_tool_path grub-editenv >/dev/null || return 1 ;;
    *) bl_bad_kind "$kind"; return ;;
  esac
  id=$(bl_first_entry "$kind" rhizo) || return 1
  [[ -n "$id" ]] || { echo "$(bootloader_generated "$kind") lists no Rhizo kernel entry -- is the Rhizo kernel installed?" >&2; return 1; }
}

# make the Rhizo kernel the default boot entry
bootloader_make_rhizo_default() {
  local kind="$1" record="$2" id prev now added=0
  bootloader_rhizo_default_preflight "$kind" || return 1
  id=$(bl_first_entry "$kind" rhizo) || return 1
  prev=$(bl_default_stored "$kind") || return 1
  if ! grep -q '^rhizo-kernel-default ' "$record" 2>/dev/null; then
    { mkdir -p "$(dirname "$record")" && echo "rhizo-kernel-default ${prev:--}" >> "$record"; } \
      || { echo "cannot record the previous default entry in $record" >&2; return 1; }
    added=1
  fi
  if bl_default_set "$kind" "$id"; then
    if now=$(bootloader_default_entry "$kind") && bl_rhizo_entry "$now"; then
      echo "$id"
      return 0
    fi
    echo "set $id as the default, but the next boot takes '${now:-the first entry}'" >&2
    bl_default_set "$kind" "${prev:--}" || echo "could not put the stored default back to '${prev:--}'" >&2
  fi
  if (( added )) && ! sed -i '/^rhizo-kernel-default /d' "$record"; then
    echo "could not drop the rhizo-kernel-default line from $record" >&2
  fi
  return 1
}

# restore the default boot entry the record keeps
bootloader_restore_default() {
  local kind="$1" record="$2" line prev now target rc=0
  line=$(grep -m1 '^rhizo-kernel-default ' "$record" 2>/dev/null) || return 0
  prev=${line#rhizo-kernel-default }
  now=$(bl_default_stored "$kind") || return 1
  if ! bl_rhizo_entry "$now"; then
    echo "kept ${now:--}"
  else
    target=$prev
    if [[ "$prev" != - ]]; then
      bl_entry_exists "$kind" "$prev" || rc=$?
      (( rc != 2 )) || return 1
      if (( rc )) || bl_rhizo_entry "$prev"; then
        target=-
        [[ "$kind" != limine ]] || target=$(bl_first_entry limine other) || return 1
        target=${target:--}
      fi
    fi
    bl_default_set "$kind" "$target" || return 1
    now=$(bl_default_stored "$kind") || return 1
    [[ "${now:--}" == "$target" ]] \
      || { echo "set the stored default back to '$target', but it reads '${now:--}'" >&2; return 1; }
    echo "restored $target"
  fi
  sed -i '/^rhizo-kernel-default /d' "$record" || { echo "could not drop the rhizo-kernel-default line from $record" >&2; return 1; }
}
