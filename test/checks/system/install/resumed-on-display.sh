#!/bin/bash
# test resumed_on_display in install-lib.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG=com.jeffliu.balancetheball

# run the cases against install-lib.sh
run_cases() {
  local tools="$1"
  (
    set +u
    G=$(mktemp -d) || exit 1
    trap 'rm -rf "$G"' EXIT
    # shellcheck source=/dev/null
    source "$tools/install-lib.sh" || { echo "CASE-FAIL source: install-lib.sh did not source"; exit 0; }

    HDR='ACTIVITY MANAGER ACTIVITIES (dumpsys activity activities)'
    task() {
      printf '  * Task{%s #%s type=standard A=10116:%s U=0 visible=true sz=1}\n' "a$1" "$1" "$PKG"
      printf '    isSleeping=%s\n' "${3:-false}"
      [[ -n "$2" ]] && printf '    topResumedActivity=ActivityRecord{b%s u0 %s t%s}\n' "$1" "$2" "$1"
      return 0
    }
    display() { printf '\nDisplay #%s (activities from top to bottom):\n' "$1"; }
    GAME="$PKG/.GameActivity"
    CONTACTS=com.android.contacts/.activities.PeopleActivity
    HOME=com.rhizo.home/.Home

    android_sh() { printf '%s' "$ANSWER"; return "${ANSWER_RC:-0}"; }
    whole() { ANSWER="$HDR"$'\n'"$1"$'\n''RHIZO_DUMP_RC=0'; ANSWER_RC=0; }

    expect() {
      local got
      resumed_on_display 4242 "$2" "$G/dump.txt"; got=$?
      [[ "$got" == "$3" ]] \
        || { echo "CASE-FAIL $1: status $got, expected $3 (read '$RESUMED_READ')"; return; }
      [[ "$RESUMED_READ" == "${4:-}" ]] \
        || echo "CASE-FAIL $1: read '$RESUMED_READ', expected '${4:-}'"
      [[ -s "$G/dump.txt" ]] || echo "CASE-FAIL $1: the read was not kept in the dump file"
    }

    whole "$(display 5; task 12 "$GAME"; display 0; task 9 "$CONTACTS"; task 2 "$HOME")"
    expect "resumed on its display" 5 0 "$GAME"

    whole "$(display 5; task 14 "$CONTACTS"; task 12 "$GAME"; display 0; task 2 "$HOME")"
    expect "another app on top names itself" 5 0 "$CONTACTS"

    ANSWER="" ANSWER_RC=0
    expect "empty read with status 0" 5 2

    ANSWER="" ANSWER_RC=97
    expect "no channel answered" 5 2

    ANSWER="$HDR"$'\n'"$(display 5; task 12 "$GAME")" ANSWER_RC=0
    expect "dump cut off before its completion line" 5 2

    ANSWER="$(display 5; task 12 "$GAME")"$'\n''RHIZO_DUMP_RC=0' ANSWER_RC=0
    expect "no dump header" 5 2

    whole "$(display 0; task 12 "$GAME"; task 2 "$HOME")"
    expect "no such display" 5 3

    whole "$(display 50; task 12 "$GAME"; display 0; task 2 "$HOME")"
    expect "display id is a prefix of another" 5 3

    whole "$(display 5; task 12 "" true; display 0; task 12 "$GAME"; task 2 "$HOME")"
    expect "display sleeping, app resumed elsewhere" 5 4
    where=$(resumed_where "$PKG" "$G/dump.txt")
    [[ "$where" == "display 0: topResumedActivity=ActivityRecord{b12 u0 $GAME t12}" ]] \
      || echo "CASE-FAIL resumed_where names the other display: '$where'"

    whole "$(display 5; task 14 ""; task 12 "$GAME"; display 0; task 2 "$HOME")"
    expect "top task not resumed, a lower one is" 5 4

    whole "$(display 5; display 0; task 2 "$HOME")"
    expect "empty display segment" 5 4

    whole "$(display 5; task 12 "$GAME")"; ANSWER_RC=98
    expect "channel status nonzero on a whole-looking read" 5 2

    whole "$(display 0; printf '    moved from Display #5 (removed)\n'; task 12 "$GAME")"
    expect "an indented mention of the display is not its segment" 5 3

    whole "$(display 5; task 14 ""; printf '  Resumed activities in task display areas (from top to bottom):\n    topResumedActivity=ActivityRecord{b12 u0 %s t12}\n' "$GAME")"
    expect "a resumed line past the segment's trailer" 5 4

    android_sh() {
      local n f
      n=$(cat "$G/reads" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$G/reads"
      f="$G/answer.$n"; [[ -e "$f" ]] || f="$G/answer.last"
      cat "$f"; return 0
    }
    answers() {
      rm -f "$G"/answer.* "$G/reads"; local i=0 d
      for d in "$@"; do i=$((i + 1)); printf '%s' "$d" > "$G/answer.$i"; done
      cp "$G/answer.$i" "$G/answer.last"
    }
    full() { printf '%s\n%s\nRHIZO_DUMP_RC=0' "$HDR" "$1"; }
    expect_await() {
      local got reads
      await_resumed_on_display 4242 5 "$G/dump.txt" 2 0.1; got=$?
      reads=$(cat "$G/reads" 2>/dev/null || echo 0)
      [[ "$got" == "$2" && "$reads" == "$3" && "$RESUMED_READ" == "${4:-}" ]] \
        || echo "CASE-FAIL $1: status $got after $reads read(s) reading '$RESUMED_READ', expected $2 after $3 reading '${4:-}'"
    }
    answers "$(full "$(display 5; task 12 "")")" "$(full "$(display 5; task 12 "$GAME")")"
    expect_await "await: a settling display is re-read until resumed" 0 2 "$GAME"
    answers "$(full "$(display 0; task 12 "$GAME")")" "$(full "$(display 5; task 12 "$GAME")")"
    expect_await "await: a missing display fails at once" 3 1
    answers "truncated" "$(full "$(display 5; task 12 "$GAME")")"
    expect_await "await: an incomplete read fails at once" 2 1
    exit 0
  )
}

# print each failing case with its label
report() {
  if grep -q '^CASE-FAIL' <<<"$2"; then
    grep '^CASE-FAIL' <<<"$2" | sed "s/^/FAIL: $1: /"
    return 1
  fi
  return 0
}

out=$(run_cases "$HERE/../system/lib")
report check-resumed-on-display "$out" || exit 1
if [[ "${1:-}" != "--selftest" ]]; then
  echo "check-resumed-on-display: OK (a resumed activity reads by name, and a dead read, a missing display and a display with nothing resumed each fail under their own status)"
  exit 0
fi

# run the cases with a check cut out
mutant() {
  local scratch got
  scratch=$(mktemp -d) || return 1
  cp -a "$HERE"/../system/lib/install-lib.sh "$scratch"/
  sed -i "$2" "$scratch/install-lib.sh"
  if cmp -s "$HERE/../system/lib/install-lib.sh" "$scratch/install-lib.sh"; then
    echo "SELFTEST FAIL: the mutation for '$1' changed nothing in install-lib.sh"; rm -rf "$scratch"; return 1
  fi
  got=$(run_cases "$scratch")
  rm -rf "$scratch"
  grep -q "^CASE-FAIL $1:" <<<"$got" || { echo "SELFTEST FAIL: with its check cut out of install-lib.sh, '$1' still passed"; return 1; }
}
rc=0
mutant "dump cut off before its completion line" '/RHIZO_DUMP_RC=0 \]\] || return 2/d' || rc=1
mutant "no dump header" "/grep -q '^ACTIVITY MANAGER ACTIVITIES' <<<\"\$out\" || return 2/d" || rc=1
mutant "no such display" '/\[\[ "\$seg" == SEGMENT\* \]\] || return 3/d' || rc=1
mutant "display id is a prefix of another" 's/want="Display #\$2 "/want="Display #$2"/' || rc=1
mutant "top task not resumed, a lower one is" 's/if (ti && i <= ti) exit; //' || rc=1
mutant "channel status nonzero on a whole-looking read" '/  (( rc == 0 )) || return 2/d' || rc=1
mutant "empty display segment" 's/if (inseg) exit; //' || rc=1
mutant "an indented mention of the display is not its segment" 's/index(\$0, want) == 1/index($0, want) > 0/' || rc=1
mutant "a resumed line past the segment's trailer" '/Resumed activities\/) { exit }/d' || rc=1
mutant "await: a settling display is re-read until resumed" 's/(( st == 4 && \$(date +%s) < deadline ))/false/' || rc=1
mutant "await: a missing display fails at once" 's/(( st == 4 && /(( st != 0 \&\& /' || rc=1
(( rc == 0 )) && echo "check-resumed-on-display --selftest: OK (each check cut back out is caught by its own case)"
exit "$rc"
