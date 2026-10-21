#!/bin/bash
# check that sign.sh signs an EFI image
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); tmp=$(mktemp -d); trap 'rm -r "$tmp"' EXIT
ld -V | grep -qw i386pep || { echo "NOT RUN: test-sign.sh: ld has no i386pep (PE) emulation"; exit 77; }
failed=0
# print ok or FAIL for a comparison
check() {
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1"; echo "       got  $2"; echo "       want $3"; failed=1; fi
}
# make a throwaway key and certificate named $1
mkkey() {
  openssl req -new -x509 -newkey rsa:2048 -nodes -subj "/CN=$1" -days 1 \
    -keyout "$tmp/$1.key" -out "$tmp/$1.crt" 2>/dev/null
}

mkkey good; mkkey other
printf '.text\n.globl _start\n_start: ret\n' > "$tmp/t.s"
if ! { as "$tmp/t.s" -o "$tmp/t.o" && ld -m i386pep --subsystem 10 -e _start -o "$tmp/k.efi" "$tmp/t.o"; }; then
  echo "FAIL could not build a scratch EFI image"; exit 1
fi
cp "$tmp/k.efi" "$tmp/orig.efi"

check "an unsigned image does not verify" "$(sbverify --cert "$tmp/good.crt" "$tmp/k.efi" >/dev/null 2>&1; echo $?)" 1
"$here/../packaging/sign.sh" "$tmp/k.efi" "$tmp/good.key" "$tmp/good.crt" >/dev/null 2>&1; rc=$?
check "sign.sh exits 0" "$rc" 0
check "the image verifies against the certificate after" \
  "$(sbverify --cert "$tmp/good.crt" "$tmp/k.efi" >/dev/null 2>&1; echo $?)" 0
check "the image changed" "$(cmp -s "$tmp/k.efi" "$tmp/orig.efi"; echo $?)" 1
check "no .signed file is left" "$(ls "$tmp/k.efi.signed" 2>/dev/null)" ""

cp "$tmp/orig.efi" "$tmp/m.efi"
"$here/../packaging/sign.sh" "$tmp/m.efi" "$tmp/good.key" "$tmp/other.crt" >/dev/null 2>&1; rc=$?
check "a certificate that does not match the key fails" "$((rc != 0))" 1
check "and leaves the image as it was" "$(cmp -s "$tmp/m.efi" "$tmp/orig.efi"; echo $?)" 0
check "and leaves no .signed file" "$(ls "$tmp/m.efi.signed" 2>/dev/null)" ""

mkdir "$tmp/bin"
printf '#!/bin/bash\n[[ -f "${@: -1}" ]] && touch %q\nexit 1\n' "$tmp/signed-seen" > "$tmp/bin/sbverify"
chmod +x "$tmp/bin/sbverify"
cp "$tmp/orig.efi" "$tmp/v.efi"
PATH="$tmp/bin:$PATH" "$here/../packaging/sign.sh" "$tmp/v.efi" "$tmp/good.key" "$tmp/good.crt" >/dev/null 2>&1; rc=$?
check "a failure after sbsign fails" "$((rc != 0))" 1
check "sbsign wrote the .signed file before it" "$(ls "$tmp/signed-seen" 2>/dev/null)" "$tmp/signed-seen"
check "and the image is left as it was" "$(cmp -s "$tmp/v.efi" "$tmp/orig.efi"; echo $?)" 0
check "and no .signed file is left" "$(ls "$tmp/v.efi.signed" 2>/dev/null)" ""
exit "$failed"
