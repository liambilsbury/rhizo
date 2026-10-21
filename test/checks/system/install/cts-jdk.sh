#!/bin/bash
# check the JDK a CTS or VTS suite runs under
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$HERE/../system/cts/cts-jdk-lib.sh"
PAIR="$HERE/../system/install/certified-pair.sh"
[[ -r "$LIB" ]] || { echo "FAIL: cannot read $LIB"; exit 1; }
[[ -r "$PAIR" ]] || { echo "FAIL: cannot read $PAIR"; exit 1; }
# shellcheck source=/dev/null
source "$LIB"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=()
# record a failure
fail() { FAILURES+=("$1"); }

# make a JDK home whose java prints the given version string
make_jdk() {
  mkdir -p "$1/bin"
  printf '#!/bin/sh\necho "openjdk version \\"%s\\" 2024-07-16" >&2\n' "$2" > "$1/bin/java"
  chmod +x "$1/bin/java"
}

# expect suite_java_home to print a home
expect_home() {
  local name="$1" root="$2" jvm="$3" want="$4" got
  got=$(suite_java_home "$root" "$jvm" 2>/dev/null) || { fail "$name: refused, wanted $want"; return; }
  [[ "$got" == "$want" ]] || fail "$name: chose $got, wanted $want"
}

# expect suite_java_home to refuse, naming each given word
expect_refusal() {
  local name="$1" root="$2" jvm="$3" out w; shift 3
  if out=$(suite_java_home "$root" "$jvm" 2>&1 >/dev/null); then
    fail "$name: chose a JDK, wanted a refusal"
    return
  fi
  for w in "$@"; do
    [[ "$out" == *"$w"* ]] || fail "$name: the refusal does not name '$w' (got: $out)"
  done
}

suite="$WORK/android-cts" bare="$WORK/android-vts" jvm="$WORK/jvm" old="$WORK/old-jvm" eleven="$WORK/jvm-11"
mkdir -p "$suite/tools" "$bare/tools"
make_jdk "$suite/jdk" "21.0.4"
make_jdk "$jvm/java-8-openjdk" "1.8.0_504"
make_jdk "$jvm/java-17-openjdk" "17.0.12"
make_jdk "$jvm/java-21-openjdk" "21.0.8"
mkdir -p "$jvm/java-11-headless-only"
make_jdk "$old/java-8-openjdk" "1.8.0_504"
make_jdk "$eleven/java-11-openjdk-amd64" "11.0.24"

expect_home "a suite carrying its own jdk/" "$suite" "$jvm" "$suite/jdk"
expect_home "a suite without one, the JVM folder holding 8, 17 and 21" "$bare" "$jvm" "$jvm/java-21-openjdk"
expect_home "a suite without one, the JVM folder holding only 11" "$bare" "$eleven" "$eleven/java-11-openjdk-amd64"
expect_refusal "a suite without one, the JVM folder holding only 8" "$bare" "$old" \
  "$bare" "JDK 11" "$old" "java-8-openjdk=8"
expect_refusal "a suite without one and no JVM folder" "$bare" "$WORK/none" "$bare" "JDK 11"

grep -q '/usr/lib/jvm/java-' "$PAIR" && fail "certified-pair.sh still names a JDK path of its own"
grep -q 'suite_java_home "\$root"' "$PAIR" || fail "certified-pair.sh does not take each suite's JDK from suite_java_home"

if (( ${#FAILURES[@]} )); then
  printf 'FAIL: %s\n' "${FAILURES[@]}"
  exit 1
fi
echo "check-cts-jdk selftest: a suite's own jdk/ wins, the newest JDK 11 or later is found without one, 11 is enough, and a host with only JDK 8 or no JVM folder is refused by name"
