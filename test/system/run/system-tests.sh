#!/bin/bash
# list the system tests under test/system
_SYSTEM_TESTS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/system_tests.py"
# test for a test-boot-mode tag
is_system_test() {
  [[ "$1" == *.sh && -f "$1" ]] && head -n 400 "$1" 2>/dev/null | grep -q '^# test-boot-mode:'
}
# print the system test names under a directory
system_tests() {
  python3 "$_SYSTEM_TESTS_PY" ${1:+"$1"}
}
# print the file of the named system test
system_test_path() {
  python3 "$_SYSTEM_TESTS_PY" --path "$1" ${2:+"$2"}
}
# print one "name<TAB>path" line per system test under a directory
system_test_map() {
  python3 "$_SYSTEM_TESTS_PY" --map ${1:+"$1"}
}
# check the listing on a fixture tree
system_tests_selftest() {
  local t fail=0 got
  t=$(mktemp -d) || return 1
  mkdir -p "$t/boot" "$t/fixtures"
  printf '#!/bin/bash\n# test-boot-mode: cold-required\n' > "$t/top.sh"
  cp "$t/top.sh" "$t/boot/nested.sh"
  cp "$t/top.sh" "$t/fixtures/fake.sh"
  got=$(system_tests "$t" | tr '\n' ' ')
  if [[ "$got" == "nested.sh top.sh " ]]; then echo "ok   selftest: the listing finds a test one folder down and skips fixtures/"
  else echo "SELFTEST FAIL: the listing gave '$got', wanted 'nested.sh top.sh '"; fail=1; fi
  got=$(system_test_path nested.sh "$t" 2>&1)
  if [[ "$got" == "$t/boot/nested.sh" ]]; then echo "ok   selftest: a name resolves to its file one folder down"
  else echo "SELFTEST FAIL: system_test_path nested.sh gave '$got'"; fail=1; fi
  cp "$t/top.sh" "$t/boot/top.sh"
  if system_test_map "$t" >/dev/null 2>&1; then echo "SELFTEST FAIL: two tests named top.sh were accepted"; fail=1
  else echo "ok   selftest: two tests with one name are refused"; fi
  rm -rf "$t"
  echo "system-tests.sh selftest: $( ((fail)) && echo FAILED || echo ok)"
  return "$fail"
}
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == --selftest ]]; then system_tests_selftest; exit $?; fi
  system_tests "${1:-$(dirname "${BASH_SOURCE[0]}")}"
fi
