#!/bin/bash
# test the GSI pin table in fetch-gsi.sh
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT="$HERE/../prepare/fetch-gsi.sh"
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

# print a function's definition from the script
lift() {
  awk -v f="$1" '$0 ~ "^" f "\\(\\) *\\{" {on=1} on {print} on && /^}/ {exit}' "$SCRIPT"
}
body=$(lift load_extra_pins)
[[ -n "$body" ]] || { echo "FAIL no load_extra_pins() in $SCRIPT"; exit 1; }
eval "$body"
# print a log line to stderr
log() { echo "$*" >&2; }

# load the built-in table the way fetch-gsi.sh does
builtin_table() {
  declare -gA GSI_URL GSI_SHA GSI_DESC
  GSI_URL=() GSI_SHA=() GSI_DESC=()
  eval "$(sed -n '/^declare -A GSI_URL GSI_SHA GSI_DESC$/,/^$/p' "$SCRIPT" | sed 1d)"
}

# print the table's release labels, sorted
labels() { printf '%s\n' "${!GSI_URL[@]}" | sort | paste -sd' '; }

builtin_table
check "no pins file: a16 and a17" "$(labels)" "a16 a17"
check "a16 is Rhizo's build, not Google's" "$([[ "${GSI_URL[a16]}" == https://github.com/liambilsbury/rhizo/releases/* ]] && echo yes)" "yes"
check "a17 is Rhizo's build, not Google's" "$([[ "${GSI_URL[a17]}" == https://github.com/liambilsbury/rhizo/releases/* ]] && echo yes)" "yes"
rig_a17=$(source "$HERE/../../../tools/fetch/gsi-pins.sh" && echo "${GSI_URL[a17]} ${GSI_SHA[a17]}")
check "the a17 pin is tools/fetch/gsi-pins.sh's" "${GSI_URL[a17]} ${GSI_SHA[a17]}" "$rig_a17"

sha=$(printf 'a%.0s' {1..64})
printf '# test rigs only\na15\thttps://x/a15.zip\t%s\tAndroid 15\n' "$sha" > "$TMP/pins.tsv"
builtin_table
load_extra_pins "$TMP/pins.tsv" 2>/dev/null
check "a15 row loads" "${GSI_URL[a15]:-}" "https://x/a15.zip"
check "a15 sha loads" "${GSI_SHA[a15]:-}" "$sha"
check "a15 description loads" "${GSI_DESC[a15]:-}" "Android 15"

printf 'a15\thttps://x/a15.zip\tnot-a-sha\tAndroid 15\n' > "$TMP/pins.tsv"
builtin_table
load_extra_pins "$TMP/pins.tsv" 2>/dev/null
check "bad sha row skipped" "${GSI_URL[a15]:-unset}" "unset"

a16_url=$(builtin_table; echo "${GSI_URL[a16]}")
a17_url=$(builtin_table; echo "${GSI_URL[a17]}")
printf 'a16\thttps://x/evil.zip\t%s\tevil\na17\thttps://x/evil17.zip\t%s\tevil\n../x\thttps://x/b.zip\t%s\tbad\na15\thttps://x/a15.zip\t%s\tno newline' "$sha" "$sha" "$sha" "$sha" > "$TMP/pins.tsv"
builtin_table
load_extra_pins "$TMP/pins.tsv" 2>/dev/null
check "a row never replaces the built-in a16 pin" "${GSI_URL[a16]}" "$a16_url"
check "a row never replaces the built-in a17 pin" "${GSI_URL[a17]}" "$a17_url"
check "a release name that is not a plain label is skipped" "${GSI_URL[../x]:-unset}" "unset"
check "a last row with no newline loads" "${GSI_URL[a15]:-}" "https://x/a15.zip"

builtin_table
load_extra_pins "$TMP/absent.tsv" 2>/dev/null
check "absent pins file changes nothing" "$(labels)" "a16 a17"

(( FAILED == 0 )) || { echo "$FAILED failed"; exit 1; }
echo "all passed"
