#!/bin/bash
# make the GSI signing keys and print their sign_target_files_apks arguments
set -uo pipefail

# print a prefixed progress line
log() { echo "[gsi-keys] $*" >&2; }
# print the usage text
usage() {
  cat <<'EOF'
Usage: tools/build/image/gsi-keys.sh <target-files.zip> <keys dir>
       tools/build/image/gsi-keys.sh --selftest
EOF
}

DEFAULT_KEYS=(releasekey platform shared media networkstack sdk_sandbox)
SECURITY_DIR=build/make/target/product/security

# make a certificate key pair unless it exists
make_cert_key() {
  local keys="$1" name="$2"
  [[ -f "$keys/$name.pk8" && -f "$keys/$name.x509.pem" ]] && return 0
  ( cd "$keys" && "$MAKE_KEY" "$name" "/O=Rhizo/CN=$name" </dev/null >/dev/null 2>&1 )
  [[ -s "$keys/$name.pk8" && -s "$keys/$name.x509.pem" ]] || { log "could not make key $name"; return 1; }
  chmod 0600 "$keys/$name.pk8"
  log "made key $name"
}

# make an RSA key for an apex payload or an AVB footer unless it exists
make_payload_key() {
  local keys="$1" name="$2" bits="${3:-${PAYLOAD_KEY_BITS:-4096}}"
  [[ -f "$keys/$name.pem" ]] && return 0
  openssl genrsa -out "$keys/$name.pem" "$bits" >/dev/null 2>&1 \
    || { log "could not make payload key $name"; return 1; }
  chmod 0600 "$keys/$name.pem"
  log "made payload key $name"
}

# make all of the keys META's signers need and print the arguments that map them
make_keys() {
  local meta="$1" keys="$2" k cert base apex
  for k in "${DEFAULT_KEYS[@]}"; do make_cert_key "$keys" "$k" || return 1; done
  for k in system vbmeta; do
    make_payload_key "$keys" "avb_$k" 4096 || return 1
    printf '%s\n' "--avb_${k}_key" "$keys/avb_$k.pem" "--avb_${k}_algorithm" SHA256_RSA4096
  done
  while read -r cert; do
    [[ -z "$cert" || "$cert" == PRESIGNED ]] && continue
    cert="${cert%.x509.pem}"; base="${cert##*/}"
    [[ "$cert" == "$SECURITY_DIR/$base" && " ${DEFAULT_KEYS[*]} testkey devkey " == *" $base "* ]] && continue
    make_cert_key "$keys" "$base" || return 1
    printf '%s\n' -k "$cert=$keys/$base"
  done < <(sed -n 's/.*certificate="\([^"]*\)".*/\1/p' "$meta/apkcerts.txt" | sort -u)
  while read -r apex cert; do
    [[ -z "$cert" || "$cert" == PRESIGNED ]] && continue
    base="${apex%.apex}"
    make_cert_key "$keys" "$base" && make_payload_key "$keys" "$base" || return 1
    printf '%s\n' --extra_apks "$apex=$keys/$base" --extra_apex_payload_key "$apex=$keys/$base.pem"
  done < <(sed -n 's/^name="\([^"]*\)".*container_certificate="\([^"]*\)".*/\1 \2/p' "$meta/apexkeys.txt")
}

# check the key arguments and the keys made for a fixture META
selftest() {
  local tmp fail=0 out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/META" "$tmp/keys"
  # shellcheck disable=SC2016  # the stub expands its arguments
  printf '#!/bin/bash\necho k > "$1.pk8"; echo c > "$1.x509.pem"\nexit 1\n' > "$tmp/make_key"
  chmod +x "$tmp/make_key"
  cat > "$tmp/META/apkcerts.txt" <<'TXT'
name="Settings.apk" certificate="build/make/target/product/security/platform.x509.pem" private_key="build/make/target/product/security/platform.pk8"
name="Bluetooth.apk" certificate="build/make/target/product/security/bluetooth.x509.pem" private_key="build/make/target/product/security/bluetooth.pk8"
name="Foo.apk" certificate="packages/modules/Foo/com.android.foo.x509.pem" private_key="packages/modules/Foo/com.android.foo.pk8"
name="Pre.apk" certificate="PRESIGNED" private_key=""
TXT
  cat > "$tmp/META/apexkeys.txt" <<'TXT'
name="com.x.apex" public_key="system/apex/com.x.avbpubkey" private_key="system/apex/com.x.pem" container_certificate="system/apex/com.x.x509.pem" container_private_key="system/apex/com.x.pk8" partition="system"
name="com.pre.apex" public_key="" private_key="" container_certificate="PRESIGNED" container_private_key="" partition="system"
TXT
  out=$(MAKE_KEY="$tmp/make_key" PAYLOAD_KEY_BITS=1024 make_keys "$tmp/META" "$tmp/keys" 2>/dev/null)
  [[ "$out" != *security/platform* ]] || { echo "FAIL a default key is left to -d"; fail=1; }
  [[ "$out" == *$'-k\nbuild/make/target/product/security/bluetooth='"$tmp/keys/bluetooth"* ]] \
    || { echo "FAIL a non-default security key is mapped with -k -- got: $out"; fail=1; }
  [[ "$out" == *$'-k\npackages/modules/Foo/com.android.foo='"$tmp/keys/com.android.foo"* ]] \
    || { echo "FAIL a module key is mapped with -k -- got: $out"; fail=1; }
  [[ "$out" == *$'--extra_apks\ncom.x.apex='"$tmp/keys/com.x"* && "$out" == *$'--extra_apex_payload_key\ncom.x.apex='"$tmp/keys/com.x.pem"* ]] \
    || { echo "FAIL an apex gets container and payload keys -- got: $out"; fail=1; }
  [[ "$out" != *com.pre* && "$out" != *Pre.apk* ]] || { echo "FAIL presigned entries are left alone"; fail=1; }
  local k
  for k in releasekey platform shared media networkstack sdk_sandbox bluetooth com.android.foo com.x; do
    [[ -f "$tmp/keys/$k.pk8" && -f "$tmp/keys/$k.x509.pem" ]] || { echo "FAIL key $k made"; fail=1; }
  done
  [[ -f "$tmp/keys/com.x.pem" ]] || { echo "FAIL apex payload key made"; fail=1; }
  [[ "$out" == *$'--avb_system_key\n'"$tmp/keys/avb_system.pem"$'\n--avb_system_algorithm\nSHA256_RSA4096'* ]] \
    || { echo "FAIL the system image's AVB footer gets its own key -- got: $out"; fail=1; }
  [[ "$out" == *$'--avb_vbmeta_key\n'"$tmp/keys/avb_vbmeta.pem"$'\n--avb_vbmeta_algorithm\nSHA256_RSA4096'* ]] \
    || { echo "FAIL vbmeta gets its own key -- got: $out"; fail=1; }
  [[ -f "$tmp/keys/avb_system.pem" && -f "$tmp/keys/avb_vbmeta.pem" ]] || { echo "FAIL the AVB keys are made"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "gsi-keys.sh selftest: FAILED"; return 1; fi
  echo "gsi-keys.sh selftest: ok"
}

[[ "${1:-}" == --selftest ]] && { selftest; exit $?; }

[[ $# -eq 2 ]] || { usage >&2; exit 2; }
TF="$1" KEYS="$2"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MAKE_KEY="${MAKE_KEY:-$(readlink -f "${RHIZO_AOSP_DIR:-$ROOT/aosp-android16-qpr2}")/development/tools/make_key}"
[[ -x "$MAKE_KEY" ]] || { log "no make_key at $MAKE_KEY"; exit 1; }
mkdir -p "$KEYS" && chmod 0700 "$KEYS"
[[ -n "$(ls -A "$KEYS")" ]] || log "first keys in $KEYS: back them up; an image signed with other keys needs Android's data wiped"
META=$(mktemp -d)
trap 'rm -rf "$META"' EXIT
unzip -q -o "$TF" META/apkcerts.txt META/apexkeys.txt -d "$META" || { log "cannot read META from $TF"; exit 1; }
make_keys "$META/META" "$KEYS"
