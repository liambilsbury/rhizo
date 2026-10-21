#!/bin/bash
# test stopping old payload processes at upgrade
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PRERM="$ROOT/debian/rhizo.prerm"
POSTINST="$ROOT/debian/rhizo.postinst"
LIB="$ROOT/src/install/lib/pkg-lib.sh"
TEARDOWN_SCRIPT="$ROOT/src/install/teardown/teardown.sh"
SOURCE_LINE='. /usr/lib/rhizo/install/lib/pkg-lib.sh'

# print the upgrade branch of the prerm script
extract_prerm_upgrade() { sed -n '/^  upgrade)$/,/^    ;;$/p' "$1" | sed '1d;$d'; }
# print the remove branch of the prerm script
extract_prerm_remove()  { sed -n '/^  remove|deconfigure)$/,/^    ;;$/p' "$1" | sed '1d;$d'; }
# print the postinst lines that stop the old payload
extract_postinst_stop() { grep -E '^[[:space:]]+pkg_stop_old_payload([[:space:]]|$)' "$1"; }
# print the remove branch of the library's pre-replace function
extract_lib_remove() {
  sed -n '/^pkg_pre_replace() {$/,/^}$/p' "$1" | sed -n '/^    remove)$/,/^      ;;$/p' | sed '1d;$d'
}

# write a stand-in teardown script
make_fake() {
  cat > "$1" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$2"
EOF
}

# run a script body against the tree's library
run_body() {
  local lib="$1" fake="$2" tmp="$3" body="$4"
  shift 4
  [[ "$body" == *"$SOURCE_LINE"* ]] || return 3
  body=${body//"$SOURCE_LINE"/". \"\$_lib\"; TEARDOWN=\"\$_fake\"; MARK=\"\$_tmp/mark\""}
  [[ "$body" != */usr/lib/rhizo/install/lib/pkg-lib.sh* ]] || return 3
  # shellcheck disable=SC2034,SC2317
  ( _lib="$lib" _fake="$fake" _tmp="$tmp"
    systemctl() { return 0; }
    runuser() { return 0; }
    rmdir() { return 0; }
    PROG=rhizo
    TEARDOWN="$fake"
    MARK="$tmp/mark"
    set -- "$@"
    eval "$body"
  ) >/dev/null 2>&1
}

# run a body against a fake teardown script
reaches() {
  local lib="$1" body="$2" tmp log fake
  shift 2
  tmp=$(mktemp -d) || { echo 0; return; }
  log="$tmp/log"; fake="$tmp/fake-teardown.sh"
  make_fake "$fake" "$log"
  run_body "$lib" "$fake" "$tmp" "$body" "$@"
  if (( $? == 3 )); then echo refused
  elif [[ -s "$log" ]] && grep -q -- '--stop-payload-processes' "$log"; then echo 1
  else echo 0; fi
  rm -rf "$tmp"
}

# compare line numbers of two postinst blocks
check_order() {
  local f="$1" stop_line reboot_line
  stop_line=$(grep -n '^    if \[ -n "\${1:-}" \] && \[ -s "\$TEARDOWN" \]; then$' "$f" | head -1 | cut -d: -f1)
  reboot_line=$(grep -n '^    case "\${PKG_MODE:-}" in$' "$f" | head -1 | cut -d: -f1)
  if [[ -z "$stop_line" || -z "$reboot_line" ]]; then
    echo "FAIL: could not find the stop-payload-processes block or the reboot-required decision in $f to order them"
    return 1
  fi
  if (( stop_line > reboot_line )); then
    echo "FAIL: $f calls stop_payload_processes (line $stop_line) AFTER its reboot-required decision (line $reboot_line)"
    return 1
  fi
  return 0
}

# inline the library steps into the postinst
inlined() { python3 "$ROOT/tools/build/packaging/deb/maint_inline.py" "$1" > "$2"; }

# check the prerm's upgrade and remove cases
check_prerm() {
  local body remove_body lib_remove arm bad=0
  body=$(extract_prerm_upgrade "$1")
  remove_body=$(extract_prerm_remove "$1")
  lib_remove=$(extract_lib_remove "$2")
  if [[ -z "$body" || -z "$remove_body" || -z "$lib_remove" ]]; then
    echo "FAIL: could not extract debian/rhizo.prerm's upgrade) or remove|deconfigure) body," \
         "or pkg_pre_replace's remove) arm -- an anchor moved"
    return 1
  fi
  for arm in "$body" "$remove_body"; do
    if [[ "$arm" != *"$SOURCE_LINE"* || "${arm//"$SOURCE_LINE"/}" == */usr/lib/rhizo/install/lib/pkg-lib.sh* ]]; then
      echo "FAIL: a debian/rhizo.prerm arm does not source the library as '$SOURCE_LINE'"
      return 1
    fi
  done
  if [[ "$(reaches "$2" "$body" upgrade 0.1.4)" != 1 ]]; then
    echo "FAIL: debian/rhizo.prerm's upgrade) case never reaches src/install/teardown/teardown.sh --stop-payload-processes"
    bad=1
  fi
  if [[ "$(reaches "$2" "$remove_body" remove)" != 0 || "$remove_body$lib_remove" == *stop-payload-processes* ]]; then
    echo "FAIL: debian/rhizo.prerm's remove|deconfigure) case now also calls --stop-payload-processes"
    bad=1
  fi
  (( bad )) && return 1
  echo "prerm: upgrade) reaches stop_payload_processes; remove|deconfigure) is untouched"
  return 0
}

# check the postinst's stop call
check_postinst() {
  local call tmp bad=0
  call=$(extract_postinst_stop "$1")
  if [[ -z "$call" ]]; then
    echo "FAIL: could not find debian/rhizo.postinst's pkg_stop_old_payload call -- an anchor moved"
    return 1
  fi
  if ! grep -qxF "    $SOURCE_LINE" "$1"; then
    echo "FAIL: debian/rhizo.postinst does not source the library as '$SOURCE_LINE'"
    return 1
  fi
  call="$SOURCE_LINE"$'\n'"$call"
  if [[ "$(reaches "$2" "$call" configure 1.2.3-old)" != 1 ]]; then
    echo "FAIL: debian/rhizo.postinst's configure) case never reaches stop_payload_processes when \"\$2\" names an older version (an upgrade)"
    bad=1
  fi
  if [[ "$(reaches "$2" "$call" configure "")" != 0 ]]; then
    echo "FAIL: debian/rhizo.postinst's configure) case reaches stop_payload_processes on a NEW install (\"\$2\" empty)"
    bad=1
  fi
  tmp=$(mktemp)
  if ! inlined "$1" "$tmp" || ! check_order "$tmp"; then
    bad=1
  fi
  rm -f "$tmp"
  (( bad )) && return 1
  echo "postinst: configure) reaches stop_payload_processes only when replacing an older version, before the reboot-required decision, never on a new install"
  return 0
}

# check that the teardown script still parses the stop-payload option
check_flag_exists() {
  if ! grep -q -- '--stop-payload-processes) MODE=stop-payload' "$TEARDOWN_SCRIPT"; then
    echo "FAIL: src/install/teardown/teardown.sh no longer parses --stop-payload-processes"
    return 1
  fi
  echo "src/install/teardown/teardown.sh still parses --stop-payload-processes"
  return 0
}

if [[ "${1:-}" == --selftest ]]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  bad=0
  mutant() {
    mkdir -p "$T/$1/debian" "$T/$1/src/install/lib"
    cp "$PRERM" "$POSTINST" "$T/$1/debian/"
    cp "$LIB" "$T/$1/src/install/lib/"
    echo "$T/$1"
  }
  mutate() {
    cp "$1" "$1.orig"; sed -i "$2" "$1"
    cmp -s "$1" "$1.orig" && { echo "FAIL selftest: '$2' changed nothing in $1"; bad=1; }
    rm -f "$1.orig"
  }
  expect_fail() {
    grep -qF -- "$3" <<<"$2" || { echo "FAIL selftest: $1 was not reported as '$3' (said: $2)"; bad=1; }
  }

  out=$(check_prerm "$PRERM" "$LIB"; check_postinst "$POSTINST" "$LIB")
  [[ "$out" != *FAIL* ]] || { echo "FAIL selftest: the real tree does not pass: $out"; bad=1; }

  prerm() { check_prerm "$1/debian/rhizo.prerm" "$1/src/install/lib/pkg-lib.sh"; }
  postinst() { check_postinst "$1/debian/rhizo.postinst" "$1/src/install/lib/pkg-lib.sh"; }
  GUARD='^  if \[ -n "\${1:-}" \] && \[ -s "\$TEARDOWN" \]; then$'
  GUARDED_CALL='if [ "$(systemctl is-active androidd.service 2>\/dev\/null)" = active ]; then bash "$TEARDOWN"'
  GUARDED_CALL="$GUARDED_CALL --stop-payload-processes; fi"

  d=$(mutant no-prerm-call); mutate "$d/debian/rhizo.prerm" '/^    pkg_pre_replace upgrade$/d'
  expect_fail "prerm with its upgrade call deleted" "$(prerm "$d")" "upgrade) case never reaches"
  d=$(mutant no-lib-stop); mutate "$d/src/install/lib/pkg-lib.sh" '/^      if \[ -s "\$TEARDOWN" \]; then$/,/^      fi$/d'
  expect_fail "pkg_pre_replace upgrade with its teardown block deleted" "$(prerm "$d")" "upgrade) case never reaches"
  d=$(mutant remove-leak)
  mutate "$d/src/install/lib/pkg-lib.sh" \
    's/^      rm -f "\$MARK"$/      rm -f "$MARK"; bash "$TEARDOWN" --stop-payload-processes/'
  expect_fail "pkg_pre_replace remove calling the teardown" "$(prerm "$d")" "remove|deconfigure) case now also calls"
  d=$(mutant remove-guarded)
  mutate "$d/src/install/lib/pkg-lib.sh" "s/^      rm -f \"\\\$MARK\"\$/&\\n      $GUARDED_CALL/"
  expect_fail "pkg_pre_replace remove with a guarded teardown call" "$(prerm "$d")" \
    "remove|deconfigure) case now also calls"
  d=$(mutant prerm-remove-guarded)
  mutate "$d/debian/rhizo.prerm" "s/^    pkg_pre_replace remove\$/&\\n    $GUARDED_CALL/"
  expect_fail "prerm remove|deconfigure) with a guarded teardown call" "$(prerm "$d")" \
    "remove|deconfigure) case now also calls"
  d=$(mutant source-variant)
  mutate "$d/debian/rhizo.prerm" \
    's|^    \. /usr/lib/rhizo/install/lib/pkg-lib.sh$|    . "/usr/lib/rhizo/install/lib/pkg-lib.sh"|'
  expect_fail "prerm sourcing the library by another spelling" "$(prerm "$d")" "does not source the library as"
  d=$(mutant remove-as-upgrade)
  mutate "$d/debian/rhizo.prerm" 's/^    pkg_pre_replace remove$/    pkg_pre_replace upgrade/'
  expect_fail "prerm remove|deconfigure) running the upgrade arm" "$(prerm "$d")" \
    "remove|deconfigure) case now also calls"

  d=$(mutant no-guard); mutate "$d/src/install/lib/pkg-lib.sh" "s/$GUARD/  if [ -s \"\$TEARDOWN\" ]; then/"
  expect_fail "pkg_stop_old_payload with its guard stripped" "$(postinst "$d")" "on a NEW install"
  d=$(mutant wrong-arg)
  mutate "$d/debian/rhizo.postinst" 's/^    pkg_stop_old_payload "\${2:-}"$/    pkg_stop_old_payload "$1"/'
  expect_fail "pkg_stop_old_payload given \"\$1\"" "$(postinst "$d")" "on a NEW install"
  d=$(mutant no-postinst-call); mutate "$d/debian/rhizo.postinst" '/^    pkg_stop_old_payload /d'
  expect_fail "postinst without its pkg_stop_old_payload call" "$(postinst "$d")" "pkg_stop_old_payload call"
  d=$(mutant no-lib-block); mutate "$d/src/install/lib/pkg-lib.sh" "/$GUARD/,/^  fi\$/d"
  expect_fail "pkg_stop_old_payload with its block deleted" "$(postinst "$d")" "never reaches stop_payload_processes"
  d=$(mutant order); mutate "$d/debian/rhizo.postinst" '/^    pkg_stop_old_payload /{h;d};/^    pkg_reboot_notice /G'
  expect_fail "pkg_reboot_notice called before pkg_stop_old_payload" "$(postinst "$d")" \
    "AFTER its reboot-required decision"

  if (( bad )); then
    echo "check-teardown-upgrade-stop selftest: FAILED"
    exit 1
  fi
  echo "check-teardown-upgrade-stop selftest: the real tree passes, 12 planted defects each named"
  exit 0
fi

bad=0
check_prerm "$PRERM" "$LIB" || bad=1
check_postinst "$POSTINST" "$LIB" || bad=1
check_flag_exists || bad=1
exit "$bad"
