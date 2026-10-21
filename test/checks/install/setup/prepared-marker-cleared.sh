#!/bin/bash
# test the postinst marker removal
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ROOT=$(cd "$HERE/../.." && pwd)

UNIT_DEFAULT="$ROOT/src/services/units/boot/prepare.service"
POSTINST_DEFAULT="$ROOT/debian/rhizo.postinst"
CHANGED_DEFAULT="$ROOT/src/install/prepare/kernel-changed.sh"
REDEPLOY_DEFAULT="$ROOT/test/vm/redeploy.sh"
CLI_DEFAULT="$ROOT/src/install/cli/rhizo.sh"
VERSION_FILE=/usr/lib/rhizo/VERSION

# return the marker path from the unit file
marker_of() {
  sed -n 's/^ConditionPathExists=|\{0,1\}!\(.*\)$/\1/p' "$1" | head -1
}

# check the postinst clears the prepare marker
check() {
  local unit="$1" postinst="$2" marker text bad=0
  if [[ ! -f "$unit" || ! -f "$postinst" ]]; then
    echo "FAIL: missing $unit or $postinst" >&2
    return 1
  fi
  marker=$(marker_of "$unit")
  if [[ -z "$marker" ]]; then
    echo "FAIL: $(basename "$unit") has no ConditionPathExists=! marker to hold" >&2
    return 1
  fi
  if ! text=$(python3 "$ROOT/tools/build/packaging/deb/maint_inline.py" "$postinst"); then
    echo "FAIL: could not read $(basename "$postinst") with the library it sources inlined" >&2
    return 1
  fi
  if ! grep -qF "rm -f $marker" <<<"$text"; then
    echo "FAIL: $(basename "$unit") skips while $marker exists, but $(basename "$postinst") never removes it" >&2
    bad=1
  fi
  (( bad )) && return 1
  echo "prepared-marker check: $(basename "$postinst") clears $marker"
  return 0
}

# check the prepared marker in unit and script
check_kernel_pair() {
  local unit="$1" changed="$2" bad=0
  if [[ ! -f "$unit" || ! -f "$changed" ]]; then
    echo "FAIL: missing $unit or $changed" >&2
    return 1
  fi
  local marker
  marker=$(sed -n 's/.*RHIZO_PREPARED_MARKER:-\([^}]*\)}.*/\1/p' "$changed" | head -1)
  if [[ -z "$marker" ]]; then
    echo "FAIL: $(basename "$changed") names no default marker path" >&2
    return 1
  fi
  local exec_start_post
  exec_start_post=$(grep '^ExecStartPost=' "$unit" | head -1)
  if [[ -z "$exec_start_post" ]]; then
    echo "FAIL: $(basename "$unit") has no ExecStartPost= line to write $marker" >&2
    bad=1
  elif [[ "$exec_start_post" != *"> $marker'" ]]; then
    echo "FAIL: $(basename "$unit")'s ExecStartPost= does not end \"> $marker'\"" >&2
    bad=1
  elif [[ "$exec_start_post" != *'kernel=%%s'* ]]; then
    echo "FAIL: $(basename "$unit")'s ExecStartPost= no longer writes a kernel=%%s field (systemd's escape for a literal %s) into $marker" >&2
    bad=1
  fi
  if ! grep -qF "sed -n 's/^kernel=//p'" "$changed"; then
    echo "FAIL: $(basename "$changed")'s kernel_changed() no longer extracts kernel= with sed -n 's/^kernel=//p'" >&2
    bad=1
  fi
  if [[ -n "$exec_start_post" && "$exec_start_post" != *'version=%%s'* ]]; then
    echo "FAIL: $(basename "$unit")'s ExecStartPost= no longer writes a version=%%s field into $marker" >&2
    bad=1
  fi
  if ! grep -qF "sed -n 's/^version=//p'" "$changed"; then
    echo "FAIL: $(basename "$changed")'s payload_changed() no longer extracts version= with sed -n 's/^version=//p'" >&2
    bad=1
  fi
  if ! grep -qE '^After=(.* )?rhizo-kernel-refresh\.service( .*)?$' "$unit"; then
    echo "FAIL: $(basename "$unit") is not After=rhizo-kernel-refresh.service" >&2
    bad=1
  fi
  (( bad )) && return 1
  echo "prepared-marker check: $(basename "$changed") and $(basename "$unit") agree on $marker's kernel= and" \
       "version= fields, and setup runs after the refresh"
  return 0
}

# print the body of a shell function
function_text() {
  awk -v open="$2() {" '$0 == open { on = 1 } on { print } on && /^}/ { exit }' "$1"
}

# run record_setup_marker from redeploy.sh on a fixture
replay_record() {
  local redeploy="$1" unit="$2" dir="$3" write_to="$4" read_from="$5" marker
  marker=$(marker_of "$unit")
  mkdir -p "$dir/test/vm" "$dir/src/services/units/boot" && cp "$unit" "$dir/src/services/units/boot/prepare.service" || return 2
  # shellcheck disable=SC2317
  (
    cd "$dir/test/vm" || exit 2
    log() { :; }
    # shellcheck source=../vm/guest-os/guest-os-lib.sh
    source "$ROOT/test/vm/guest-os/guest-os-lib.sh"
    ssh_vm() {
      local body="${*: -1}"
      body=${body//"> $marker'"/"> $write_to'"}
      bash -c "${body//"$marker"/"$read_from"}"
    }
    eval "$(function_text "$redeploy" setup_marker_cmd)"
    eval "$(function_text "$redeploy" record_setup_marker)"
    record_setup_marker
  ) >/dev/null 2>&1
}

# check redeploy.sh writes the prepare marker
check_rig_writer() {
  local unit="$1" redeploy="$2" cli="$3" marker state_dir cli_marker fn cmd run scratch got bad=0
  local tree_line rec_line
  if [[ ! -f "$unit" || ! -f "$redeploy" || ! -f "$cli" ]]; then
    echo "FAIL: missing $unit, $redeploy or $cli" >&2
    return 1
  fi
  marker=$(marker_of "$unit")
  state_dir=$(sed -n 's/^STATE_DIR="\${RHIZO_STATE_DIR:-\([^}]*\)}"$/\1/p' "$cli" | head -1)
  cli_marker=$(sed -n 's/^PREPARED_MARKER="\$STATE_DIR\/\([^"]*\)"$/\1/p' "$cli" | head -1)
  if [[ -z "$marker" || -z "$state_dir" || -z "$cli_marker" || "$state_dir/$cli_marker" != "$marker" ]]; then
    echo "FAIL: $(basename "$cli") reads its setup marker at '${state_dir:-?}/${cli_marker:-?}', $(basename "$unit") writes '${marker:-?}'" >&2
    return 1
  fi
  fn=$(function_text "$redeploy" setup_marker_cmd)
  if [[ -z "$fn" ]]; then
    echo "FAIL: $(basename "$redeploy") defines no setup_marker_cmd" >&2
    return 1
  fi
  if ! cmd=$(bash -c "$fn"$'\n''setup_marker_cmd "$1"' _ "$unit" 2>/dev/null) || [[ "$cmd" != *"> $marker'" ]]; then
    echo "FAIL: $(basename "$redeploy")'s setup_marker_cmd gives no command writing $marker from $(basename "$unit") (got: '${cmd:-<nothing>}')" >&2
    return 1
  fi
  scratch=$(mktemp -d)
  printf 'rhizo-marker-selftest\n' > "$scratch/VERSION"
  run=${cmd//"$marker"/"$scratch/marker"}
  bash -c "${run//"$VERSION_FILE"/"$scratch/VERSION"}" 2>/dev/null
  got=$(sed -n 's/^kernel=//p' "$scratch/marker" 2>/dev/null)
  if [[ "$got" != "$(uname -r)" || "$(sed -n 's/^version=//p' "$scratch/marker" 2>/dev/null)" != rhizo-marker-selftest ]]; then
    echo "FAIL: the command $(basename "$redeploy") sends writes '$(tr '\n' ' ' < "$scratch/marker" 2>/dev/null)', not kernel=$(uname -r) and a non-empty version= read from $VERSION_FILE as $(basename "$unit")'s ExecStartPost does" >&2
    bad=1
  fi
  printf 'kernel=%s\nversion=old\n' "$(uname -r)" > "$scratch/old"
  if ! replay_record "$redeploy" "$unit" "$scratch/ok" "$scratch/new" "$scratch/new"; then
    echo "FAIL: $(basename "$redeploy")'s record_setup_marker does not pass when its marker write lands" >&2
    bad=1
  elif replay_record "$redeploy" "$unit" "$scratch/bad" "$scratch/absent/marker" "$scratch/old"; then
    echo "FAIL: $(basename "$redeploy")'s record_setup_marker passes when the guest's marker write fails and the last deploy's marker already reads kernel=$(uname -r) -- the readback must run only after the write succeeded ('\$cmd && echo ...')" >&2
    bad=1
  fi
  rm -rf "$scratch"
  if ! function_text "$redeploy" record_setup_marker | grep -qF 'setup_marker_cmd ../../src/services/units/boot/prepare.service'; then
    echo "FAIL: $(basename "$redeploy")'s record_setup_marker does not run setup_marker_cmd on ../../src/services/units/boot/prepare.service" >&2
    bad=1
  fi
  tree_line=$(grep -n '^  prepared_tree_refresh || exit 1$' "$redeploy" | head -1 | cut -d: -f1)
  rec_line=$(grep -n '^record_setup_marker || exit 1$' "$redeploy" | head -1 | cut -d: -f1)
  if [[ -z "$rec_line" ]]; then
    echo "FAIL: $(basename "$redeploy") never runs 'record_setup_marker || exit 1' at top level" >&2
    bad=1
  elif [[ -z "$tree_line" ]] || (( rec_line < tree_line )); then
    echo "FAIL: $(basename "$redeploy") records the marker (line $rec_line) before its prepared-tree step (line ${tree_line:-absent})" >&2
    bad=1
  fi
  (( bad )) && return 1
  echo "prepared-marker check: $(basename "$redeploy") replays $(basename "$unit")'s marker write after its prepared-tree step, at the path $(basename "$cli") reads"
  return 0
}

if [[ "${1:-}" == "--selftest" ]]; then
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  cp "$UNIT_DEFAULT" "$TMP/unit"; python3 "$ROOT/tools/build/packaging/deb/maint_inline.py" "$POSTINST_DEFAULT" > "$TMP/postinst"
  if ! check "$TMP/unit" "$TMP/postinst" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- the real pair does not pass" >&2
    exit 1
  fi
  grep -v "rm -f /var/lib/rhizo/.prepared" "$TMP/postinst" > "$TMP/postinst-bad"
  if check "$TMP/unit" "$TMP/postinst-bad" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- a postinst that never clears the marker was reported clean" >&2
    exit 1
  fi
  mkdir -p "$TMP/tree/debian" "$TMP/tree/install"
  cp "$ROOT/src/install/lib/pkg-lib.sh" "$TMP/tree/install/"
  grep -vx '    pkg_state_dirs' "$POSTINST_DEFAULT" > "$TMP/tree/debian/rhizo.postinst"
  if cmp -s "$POSTINST_DEFAULT" "$TMP/tree/debian/rhizo.postinst"; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- the postinst has no '    pkg_state_dirs' call to drop" >&2
    exit 1
  fi
  if check "$TMP/unit" "$TMP/tree/debian/rhizo.postinst" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- a postinst not calling pkg_state_dirs passed" >&2
    exit 1
  fi
  grep -v "^ConditionPathExists=|\{0,1\}!" "$TMP/unit" > "$TMP/unit-bad"
  if check "$TMP/unit-bad" "$TMP/postinst" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- a unit with no marker was reported clean" >&2
    exit 1
  fi

  cp "$CHANGED_DEFAULT" "$TMP/changed"
  if ! check_kernel_pair "$TMP/unit" "$TMP/changed" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- the real kernel-refresh pair does not pass" >&2
    exit 1
  fi
  sed 's#/var/lib/rhizo/\.prepared#/var/lib/rhizo/.moved#' "$TMP/changed" > "$TMP/changed-bad-path"
  if check_kernel_pair "$TMP/unit" "$TMP/changed-bad-path" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- a reader naming a marker the writer never touches was reported clean" >&2
    exit 1
  fi
  sed 's/kernel=%%s/k=%%s/' "$TMP/unit" > "$TMP/unit-no-kernel-field"
  if check_kernel_pair "$TMP/unit-no-kernel-field" "$TMP/changed" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- an ExecStartPost that stopped writing kernel= was reported clean" >&2
    exit 1
  fi
  sed 's/kernel=%%s/kernel=%s/' "$TMP/unit" > "$TMP/unit-bare-specifier"
  if check_kernel_pair "$TMP/unit-bare-specifier" "$TMP/changed" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- an ExecStartPost writing kernel=%s (systemd's shell specifier) was reported clean" >&2
    exit 1
  fi
  sed "s#> /var/lib/rhizo/\.prepared'#> /var/lib/rhizo/.prepared-elsewhere'#" "$TMP/unit" > "$TMP/unit-wrong-target"
  if check_kernel_pair "$TMP/unit-wrong-target" "$TMP/changed" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- an ExecStartPost writing a different path was reported clean because the marker string still appears elsewhere in the unit" >&2
    exit 1
  fi
  sed "s#sed -n 's/^kernel=//p'#sed -n 's/^kern=//p'#" "$TMP/changed" > "$TMP/changed-wrong-sed"
  if check_kernel_pair "$TMP/unit" "$TMP/changed-wrong-sed" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- a kernel_changed() sed that no longer matches ^kernel= was reported clean" >&2
    exit 1
  fi
  pair_catches() {
    local out
    if out=$(check_kernel_pair "$3" "$4" 2>&1) || ! grep -qF -- "$2" <<<"$out"; then
      echo "check-prepared-marker-cleared --selftest: FAIL -- $1 was not reported as '$2' (said: $out)" >&2
      exit 1
    fi
  }
  sed "s#sed -n 's/^version=//p'#sed -n 's/^ver=//p'#" "$TMP/changed" > "$TMP/changed-no-version-sed"
  pair_catches "a payload_changed() sed that no longer matches ^version=" "no longer extracts version=" \
    "$TMP/unit" "$TMP/changed-no-version-sed"
  sed 's/version=%%s/v=%%s/' "$TMP/unit" > "$TMP/unit-no-version-field"
  pair_catches "an ExecStartPost that stopped writing version=" "no longer writes a version=%%s field" \
    "$TMP/unit-no-version-field" "$TMP/changed"
  sed '/^After=.*rhizo-kernel-refresh\.service/d' "$TMP/unit" > "$TMP/unit-unordered"
  pair_catches "a prepare unit not ordered after the refresh" "is not After=rhizo-kernel-refresh.service" \
    "$TMP/unit-unordered" "$TMP/changed"

  cp "$REDEPLOY_DEFAULT" "$TMP/redeploy"; cp "$CLI_DEFAULT" "$TMP/cli"
  if ! check_rig_writer "$TMP/unit" "$TMP/redeploy" "$TMP/cli" >/dev/null 2>&1; then
    echo "check-prepared-marker-cleared --selftest: FAIL -- the real rig writer does not pass" >&2
    exit 1
  fi
  rig_catches() {
    local out
    if out=$(check_rig_writer "$3" "$4" "$5" 2>&1) || ! grep -qF -- "$2" <<<"$out"; then
      echo "check-prepared-marker-cleared --selftest: FAIL -- $1 was not reported as '$2' (said: $out)" >&2
      exit 1
    fi
  }
  grep -v '^record_setup_marker || exit 1$' "$TMP/redeploy" > "$TMP/redeploy-no-record"
  rig_catches "a deploy that never records the marker" "never runs 'record_setup_marker || exit 1'" \
    "$TMP/unit" "$TMP/redeploy-no-record" "$TMP/cli"
  sed 's/^record_setup_marker || exit 1$/record_setup_marker/' "$TMP/redeploy" > "$TMP/redeploy-unchecked"
  rig_catches "an unchecked marker write" "never runs 'record_setup_marker || exit 1'" \
    "$TMP/unit" "$TMP/redeploy-unchecked" "$TMP/cli"
  grep -v '^record_setup_marker || exit 1$' "$TMP/redeploy" \
    | sed 's/^\(  prepared_tree_refresh || exit 1\)$/record_setup_marker || exit 1\n\1/' > "$TMP/redeploy-early"
  rig_catches "a marker recorded before the prepared-tree step" "before its prepared-tree step" \
    "$TMP/unit" "$TMP/redeploy-early" "$TMP/cli"
  awk '/^setup_marker_cmd\(\) \{$/ { print; print "  printf \"%s\\n\" \"/bin/sh -c '"'"'echo done > /var/lib/rhizo/.prepared'"'"'\""; print "}"; skip = 1; next }
       skip && /^}/ { skip = 0; next } !skip' "$TMP/redeploy" > "$TMP/redeploy-own-format"
  rig_catches "a rig marker in its own format" "not kernel=$(uname -r) and a non-empty version=" \
    "$TMP/unit" "$TMP/redeploy-own-format" "$TMP/cli"
  sed 's/"\$cmd && echo /"$cmd; echo /' "$TMP/redeploy" > "$TMP/redeploy-semicolon"
  rig_catches "a readback that runs after a failed marker write" "passes when the guest's marker write fails" \
    "$TMP/unit" "$TMP/redeploy-semicolon" "$TMP/cli"
  sed 's#"\$(cat /usr/lib/rhizo/VERSION 2>/dev/null)"#""#' "$TMP/unit" > "$TMP/unit-empty-version"
  rig_catches "a marker written with an empty version=" "a non-empty version=" \
    "$TMP/unit-empty-version" "$TMP/redeploy" "$TMP/cli"
  rig_catches "an ExecStartPost carrying a bare systemd specifier" "gives no command writing" \
    "$TMP/unit-bare-specifier" "$TMP/redeploy" "$TMP/cli"
  sed 's#^PREPARED_MARKER="\$STATE_DIR/\.prepared"$#PREPARED_MARKER="$STATE_DIR/.setup-done"#' "$TMP/cli" > "$TMP/cli-moved"
  rig_catches "a CLI reading another marker path" "reads its setup marker at" \
    "$TMP/unit" "$TMP/redeploy" "$TMP/cli-moved"
  echo "check-prepared-marker-cleared --selftest: OK (20 defects caught)"
  exit 0
fi

rc=0
check "$UNIT_DEFAULT" "$POSTINST_DEFAULT" || rc=1
check_kernel_pair "$UNIT_DEFAULT" "$CHANGED_DEFAULT" || rc=1
check_rig_writer "$UNIT_DEFAULT" "$REDEPLOY_DEFAULT" "$CLI_DEFAULT" || rc=1
exit "$rc"
