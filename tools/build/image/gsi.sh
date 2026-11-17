#!/bin/bash
# Android 16 or 17 gsi_x86_64 GSI build from unmodified AOSP source
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

# print a [gsi] line to stderr
log() { echo "[gsi] $*" >&2; }
# print the usage text
usage() {
  cat <<'EOF'
gsi.sh --variant user|userdebug [--release a16|a17] [--revision N] [--release-config CONFIG] [--jobs N]
       [--skip-build]
gsi.sh --selftest
EOF
}

KEYMINT_STASH=""

# git stash the KeyMint patches in system/keymaster
stash_keymint() {
  local d="$1/system/keymaster" tag
  tag="rhizo gsi.sh $(date +%s%N)"
  [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || return 0
  git -C "$d" stash push -q -m "$tag" || { log "git stash push failed in $d"; return 1; }
  KEYMINT_STASH=$(git -C "$d" stash list --format='%H %gs' | grep -F "$tag" | head -1 | cut -d' ' -f1)
  [[ -n "$KEYMINT_STASH" ]] || { log "no stash '$tag' in git -C $d stash list"; return 1; }
  log "stashed the KeyMint patches in system/keymaster"
}

# git stash apply the KeyMint patches and drop the stash
restore_keymint() {
  local d="$1/system/keymaster" ref
  [[ -n "$KEYMINT_STASH" ]] || return 0
  if git -C "$d" diff --quiet "$KEYMINT_STASH" -- . 2>/dev/null; then
    log "git diff $KEYMINT_STASH in system/keymaster is empty"
  else
    git -C "$d" stash apply -q "$KEYMINT_STASH" || { log "git -C $d stash apply $KEYMINT_STASH failed"; return 1; }
  fi
  ref=$(git -C "$d" stash list --format='%gd %H' | awk -v s="$KEYMINT_STASH" '$2 == s {print $1; exit}')
  [[ -n "$ref" ]] && git -C "$d" stash drop -q "$ref"
  KEYMINT_STASH=""
  log "applied the KeyMint patches in system/keymaster"
}

# check that each AOSP project has no local changes and HEAD at the manifest revision
check_tree_clean() {
  local aosp="$1" p m dirty=0
  while read -r p; do
    if [[ -n "$(git -C "$aosp/$p" status --porcelain 2>&1)" ]]; then
      log "git status of AOSP project $p is not empty"
      dirty=1
    fi
    m=$(git -C "$aosp/$p" for-each-ref --format='%(objectname)' refs/remotes/m/ 2>/dev/null | head -1)
    if [[ -n "$m" && "$m" != "$(git -C "$aosp/$p" rev-parse HEAD 2>/dev/null)" ]]; then
      log "AOSP project $p HEAD is not the manifest revision"
      dirty=1
    fi
  done < "$aosp/.repo/project.list"
  (( dirty == 0 )) || return 1
}

# print the digests of the certificates and AVB public keys in a keys dir
own_key_digests() {
  local keys="$1" k t
  for k in "$keys"/*.x509.pem; do
    [[ -f "$k" ]] && echo "cert $(openssl x509 -in "$k" -outform DER | sha256sum | cut -d' ' -f1)"
  done
  t=$(mktemp)
  for k in "$keys"/*.pem; do
    [[ -f "$k" && "$k" != *.x509.pem ]] || continue
    "${AVBTOOL:-avbtool}" extract_public_key --key "$k" --output "$t" >/dev/null 2>&1 \
      && echo "avb $(sha1sum < "$t" | cut -d' ' -f1)"
  done
  rm -f "$t"
}

# print the apks and apexes with certificate PRESIGNED in META
presigned_names() {
  grep -hE '(^|[[:space:]])(container_)?certificate="PRESIGNED"' "$1/apkcerts.txt" "$1/apexkeys.txt" | sed -n 's/^name="\([^"]*\)".*/\1/p' | sort -u
}

# print the certificate digests of apksigner --print-certs output
apksigner_certs() {
  sed -nE 's/^(Signer #[0-9]+|V[0-9.]+ Signer:) certificate SHA-256 digest: */cert /p'
}

# print the signer digests of an apk, apex or capex
signer_digests() {
  local f="$1" t
  apksigner verify --print-certs "$f" 2>/dev/null | apksigner_certs
  case "$f" in
    *.apex)
      t=$(mktemp)
      unzip -p "$f" apex_payload.img > "$t" 2>/dev/null \
        && avbtool info_image --image "$t" 2>/dev/null | sed -n 's/^Public key (sha1): *\(.*\)$/avb \1/p'
      rm -f "$t" ;;
    *.capex)
      t=$(mktemp -d)
      unzip -q -o "$f" original_apex -d "$t" 2>/dev/null && mv "$t/original_apex" "$t/inner.apex" && signer_digests "$t/inner.apex" | grep '^avb '
      rm -rf "$t" ;;
  esac
}

# check that the apks, apexes and capexes are signed with the keys in $2
check_signed_files() {
  local dir="$1" own="$2" presigned="${3:-/dev/null}" f d digests bad_n=0 n=0
  while IFS= read -r -d '' f; do
    if grep -qxF "${f##*/}" "$presigned"; then
      log "${f#"$dir"/} is PRESIGNED"
      continue
    fi
    n=$((n + 1))
    digests=$(signer_digests "$f")
    if ! grep -q '^cert ' <<< "$digests"; then
      log "no signature in ${f#"$dir"/}"
      bad_n=$((bad_n + 1)); continue
    fi
    if [[ "$f" == *.apex || "$f" == *.capex ]] && ! grep -q '^avb ' <<< "$digests"; then
      log "no payload key in ${f#"$dir"/}"
      bad_n=$((bad_n + 1)); continue
    fi
    while read -r d; do
      grep -qxF "$d" "$own" && continue
      log "${f#"$dir"/} signer $d is not in $own"
      bad_n=$((bad_n + 1))
    done <<< "$digests"
  done < <(find "$dir" -type f \( -name '*.apk' -o -name '*.apex' -o -name '*.capex' \) -print0)
  log "checked $n signed files, $bad_n with keys not in $own"
  (( n > 0 && bad_n == 0 ))
}

# check that the AVB footer key of an image is in $2
check_image_avb() {
  local key
  key=$("${AVBTOOL:-avbtool}" info_image --image "$1" 2>/dev/null | sed -n 's/^Public key (sha1): *\(.*\)$/\1/p' | head -1)
  if [[ -n "$key" ]] && grep -qxF "avb $key" "$2"; then log "ok AVB footer key $key"; return 0; fi
  log "AVB footer key '${key:-none}' is not in $2"
  return 1
}

# check a zip's sha against a release's pin in a gsi-pins.sh
pin_matches() {
  [[ "$1" == "$(sed -n "s/^GSI_SHA\[${3:-a16}\]=\"\(.*\)\"$/\1/p" "$2")" ]]
}

# print the make target, pin file, checkout link, override variable, BUILD_ID variable and release config of a release
release_paths() {
  case "$1" in
    a16) echo "inputs tools/fetch/build-inputs.sh aosp-android16-qpr2 RHIZO_AOSP_DIR AOSP_BUILD_ID bp4a" ;;
    a17) echo "inputs-a17 tools/fetch/aosp-a17.sh aosp-android17 RHIZO_AOSP_A17_DIR AOSP_A17_BUILD_ID cp2a" ;;
    *) return 1 ;;
  esac
}

# check that an image is ext4
is_ext4_image() {
  dumpe2fs -h "$1" 2>/dev/null | grep -q '^Filesystem features:.*\bextent\b'
}

# check the image build.prop and product build.prop against the variant
check_posture() {
  local prop="$1" variant="$2" build_id="$3" revision="$4" product_prop="${5:-$1}" k want got bad=0 tags=release-keys
  [[ "$variant" == userdebug ]] && tags=test-keys
  for k in ro.build.id="$build_id" ro.build.type="$variant" ro.build.tags="$tags" ro.build.version.incremental="rhizo$revision"; do
    want="${k#*=}"; k="${k%%=*}"
    got=$(sed -n "s/^${k//./\\.}=//p" "$prop" | tail -1)
    if [[ "$got" == "$want" ]]; then log "ok $k=$got"; else log "$k=$got, expected $want"; bad=1; fi
  done
  got=$(sed -n 's/^ro\.product\.build\.fingerprint=//p' "$product_prop" | tail -1)
  if [[ "$got" == Android/gsi_x86_64/* ]]; then log "ok ro.product.build.fingerprint=$got"; else log "ro.product.build.fingerprint=$got, expected Android/gsi_x86_64/..."; bad=1; fi
  (( bad == 0 ))
}

# test the tree, signing, pin and posture checks on fixtures
selftest() {
  local tmp fail=0 p out
  tmp=$(mktemp -d)
  mkdir -p "$tmp/aosp/.repo"
  for p in projA system/keymaster; do
    mkdir -p "$tmp/aosp/$p"
    git -C "$tmp/aosp/$p" init -q
    echo base > "$tmp/aosp/$p/file"
    git -C "$tmp/aosp/$p" add file
    git -C "$tmp/aosp/$p" -c user.name=t -c user.email=t@t commit -q -m base
    echo "$p" >> "$tmp/aosp/.repo/project.list"
  done

  check_tree_clean "$tmp/aosp" >/dev/null 2>&1 \
    || { echo "FAIL check_tree_clean on a clean tree returns 0"; fail=1; }

  echo x >> "$tmp/aosp/projA/file"
  out=$(check_tree_clean "$tmp/aosp" 2>&1)
  [[ $? -ne 0 && "$out" == *projA* ]] || { echo "FAIL check_tree_clean with an edited projA returns 1 ($out)"; fail=1; }
  git -C "$tmp/aosp/projA" checkout -q file

  echo patch >> "$tmp/aosp/system/keymaster/file"
  stash_keymint "$tmp/aosp" >/dev/null 2>&1
  check_tree_clean "$tmp/aosp" >/dev/null 2>&1 \
    || { echo "FAIL check_tree_clean after stash_keymint returns 0"; fail=1; }
  restore_keymint "$tmp/aosp" >/dev/null 2>&1
  grep -q patch "$tmp/aosp/system/keymaster/file" || { echo "FAIL system/keymaster/file has patch after restore_keymint"; fail=1; }

  stash_keymint "$tmp/aosp" >/dev/null 2>&1
  echo patch >> "$tmp/aosp/system/keymaster/file"
  restore_keymint "$tmp/aosp" >/dev/null 2>&1 || { echo "FAIL restore_keymint with the patches in place returns 0"; fail=1; }
  [[ -z "$(git -C "$tmp/aosp/system/keymaster" stash list)" ]] || { echo "FAIL git stash list is empty after restore_keymint"; fail=1; }

  git -C "$tmp/aosp/system/keymaster" checkout -q file
  git -C "$tmp/aosp/projA" update-ref refs/remotes/m/rev HEAD
  check_tree_clean "$tmp/aosp" >/dev/null 2>&1 || { echo "FAIL check_tree_clean with projA HEAD at refs/remotes/m returns 0"; fail=1; }
  echo y > "$tmp/aosp/projA/new" && git -C "$tmp/aosp/projA" add new
  git -C "$tmp/aosp/projA" -c user.name=t -c user.email=t@t commit -q -m local
  out=$(check_tree_clean "$tmp/aosp" 2>&1)
  [[ $? -ne 0 && "$out" == *projA* ]] || { echo "FAIL check_tree_clean with a local projA commit returns 1 ($out)"; fail=1; }

  mkdir -p "$tmp/keys" "$tmp/meta" "$tmp/signed/SYSTEM/app" "$tmp/signed/SYSTEM/apex" "$tmp/empty"
  openssl req -new -x509 -newkey rsa:2048 -nodes -keyout "$tmp/keys/platform.key" -out "$tmp/keys/platform.x509.pem" -subj /CN=t -days 1 >/dev/null 2>&1
  openssl genrsa -out "$tmp/keys/com.x.pem" 1024 >/dev/null 2>&1
  # shellcheck disable=SC2016
  printf '#!/bin/bash\ncase "$1" in extract_public_key) sha1sum < "$3" | cut -c1-8 > "$5" ;; info_image) echo "Public key (sha1): $(cat "$3.key")" ;; esac\n' > "$tmp/avbtool"
  chmod +x "$tmp/avbtool"
  local own_cert own_avb
  own_cert=$(openssl x509 -in "$tmp/keys/platform.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
  own_avb=$(sha1sum < "$tmp/keys/com.x.pem" | cut -c1-8 | sha1sum | cut -d' ' -f1)
  AVBTOOL="$tmp/avbtool" own_key_digests "$tmp/keys" > "$tmp/own" 2>/dev/null
  grep -qx "cert $own_cert" "$tmp/own" || { echo "FAIL own_key_digests has cert $own_cert"; fail=1; }
  grep -qx "avb $own_avb" "$tmp/own" || { echo "FAIL own_key_digests has avb $own_avb ($(cat "$tmp/own"))"; fail=1; }
  printf 'name="Foo.apk" certificate="k/platform.x509.pem" private_key="k/platform.pk8"\nname="Pre.apk" certificate="PRESIGNED" private_key=""\n' > "$tmp/meta/apkcerts.txt"
  printf 'name="com.pre.apex" public_key="" private_key="" container_certificate="PRESIGNED" container_private_key="" partition="system"\n' > "$tmp/meta/apexkeys.txt"
  presigned_names "$tmp/meta" > "$tmp/pre"
  grep -qx Pre.apk "$tmp/pre" && grep -qx com.pre.apex "$tmp/pre" && [[ "$(grep -c . "$tmp/pre")" == 2 ]] \
    || { echo "FAIL presigned_names == Pre.apk com.pre.apex ($(cat "$tmp/pre"))"; fail=1; }

  out=$(printf 'Signer #1 certificate DN: CN=Android\nSigner #1 certificate SHA-256 digest: aaaa\nSigner #1 certificate SHA-1 digest: bbbb\n' | apksigner_certs)
  [[ "$out" == "cert aaaa" ]] || { echo "FAIL apksigner_certs on Signer #1 lines == cert aaaa ($out)"; fail=1; }
  out=$(printf 'V3.0 Signer: certificate DN: CN=Android\nV3.0 Signer: certificate SHA-256 digest: cccc\nV3.0 Signer: certificate MD5 digest: dddd\n' | apksigner_certs)
  [[ "$out" == "cert cccc" ]] || { echo "FAIL apksigner_certs on V3.0 Signer lines == cert cccc ($out)"; fail=1; }

  touch "$tmp/signed/SYSTEM/app/a.apk" "$tmp/signed/SYSTEM/apex/b.apex"
  signer_digests() { case "$1" in *a.apk) echo "cert $own_cert" ;; *b.apex) echo "cert $own_cert"; echo "avb $own_avb" ;; esac; }
  check_signed_files "$tmp/signed" "$tmp/own" /dev/null >/dev/null 2>&1 || { echo "FAIL check_signed_files with own_cert and own_avb signers returns 0"; fail=1; }
  signer_digests() { case "$1" in *a.apk) echo "cert ffff" ;; *b.apex) echo "cert $own_cert"; echo "avb $own_avb" ;; esac; }
  out=$(check_signed_files "$tmp/signed" "$tmp/own" /dev/null 2>&1)
  [[ $? -ne 0 && "$out" == *a.apk* && "$out" != *b.apex* ]] || { echo "FAIL check_signed_files with a.apk cert ffff returns 1 ($out)"; fail=1; }
  signer_digests() { case "$1" in *a.apk) echo "cert $own_cert" ;; *b.apex) echo "cert $own_cert" ;; esac; }
  out=$(check_signed_files "$tmp/signed" "$tmp/own" /dev/null 2>&1)
  [[ $? -ne 0 && "$out" == *b.apex* ]] || { echo "FAIL check_signed_files without a b.apex avb key returns 1 ($out)"; fail=1; }
  signer_digests() { case "$1" in *a.apk) echo "cert $own_cert" ;; *b.apex) echo "cert $own_cert"; echo "avb eeee" ;; esac; }
  out=$(check_signed_files "$tmp/signed" "$tmp/own" /dev/null 2>&1)
  [[ $? -ne 0 && "$out" == *b.apex* ]] || { echo "FAIL check_signed_files with b.apex avb eeee returns 1 ($out)"; fail=1; }
  signer_digests() { case "$1" in *a.apk) echo "cert $own_cert" ;; esac; }
  out=$(check_signed_files "$tmp/signed" "$tmp/own" /dev/null 2>&1)
  [[ $? -ne 0 && "$out" == *b.apex* ]] || { echo "FAIL check_signed_files without a b.apex signature returns 1 ($out)"; fail=1; }
  printf 'b.apex\n' > "$tmp/presigned"
  check_signed_files "$tmp/signed" "$tmp/own" "$tmp/presigned" >/dev/null 2>&1 || { echo "FAIL check_signed_files with b.apex PRESIGNED returns 0"; fail=1; }
  check_signed_files "$tmp/empty" "$tmp/own" /dev/null >/dev/null 2>&1 && { echo "FAIL check_signed_files on an empty tree returns 1"; fail=1; }
  unset -f signer_digests

  echo "$own_avb" > "$tmp/system.img.key"
  AVBTOOL="$tmp/avbtool" check_image_avb "$tmp/system.img" "$tmp/own" >/dev/null 2>&1 || { echo "FAIL check_image_avb with avb $own_avb returns 0"; fail=1; }
  echo dddd > "$tmp/system.img.key"
  AVBTOOL="$tmp/avbtool" check_image_avb "$tmp/system.img" "$tmp/own" >/dev/null 2>&1 && { echo "FAIL check_image_avb with avb dddd returns 1"; fail=1; }

  printf 'GSI_SHA[a16]="%s"\n' "$own_cert" > "$tmp/pins.sh"
  pin_matches "$own_cert" "$tmp/pins.sh" || { echo "FAIL pin_matches own_cert pins.sh returns 0"; fail=1; }
  pin_matches ffff "$tmp/pins.sh" && { echo "FAIL pin_matches ffff pins.sh returns 1"; fail=1; }
  printf 'GSI_SHA[a17]="%s"\n' ffff >> "$tmp/pins.sh"
  pin_matches ffff "$tmp/pins.sh" a17 || { echo "FAIL pin_matches ffff pins.sh a17 returns 0"; fail=1; }
  pin_matches "$own_cert" "$tmp/pins.sh" a17 && { echo "FAIL pin_matches own_cert pins.sh a17 returns 1"; fail=1; }

  local root a17_id
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  [[ "$(release_paths a16)" == "inputs tools/fetch/build-inputs.sh aosp-android16-qpr2 RHIZO_AOSP_DIR AOSP_BUILD_ID bp4a" ]] || { echo "FAIL release_paths a16 == the a16 row ($(release_paths a16))"; fail=1; }
  [[ "$(release_paths a17)" == "inputs-a17 tools/fetch/aosp-a17.sh aosp-android17 RHIZO_AOSP_A17_DIR AOSP_A17_BUILD_ID cp2a" ]] || { echo "FAIL release_paths a17 == the a17 row ($(release_paths a17))"; fail=1; }
  release_paths a15 >/dev/null && { echo "FAIL release_paths a15 returns 1"; fail=1; }
  a17_id=$(sed -n 's/^AOSP_A17_BUILD_ID=//p' "$root/tools/fetch/aosp-a17.sh")
  [[ "rhizo-gsi_x86_64-user-$a17_id-1" == rhizo-gsi_x86_64-user-CP2A.260605.016-1 ]] || { echo "FAIL AOSP_A17_BUILD_ID == CP2A.260605.016 ($a17_id)"; fail=1; }
  mkdir -p "$tmp/a17/.repo" "$tmp/a17/build/make/core"
  echo BUILD_ID=XX1A.000000.001 > "$tmp/a17/build/make/core/build_id.mk"
  out=$(RHIZO_AOSP_A17_DIR="$tmp/a17" "$root/tools/build/image/gsi.sh" --release a17 --variant user 2>&1)
  [[ $? -ne 0 && "$out" == *"BUILD_ID is XX1A.000000.001, expected $a17_id"* ]] || { echo "FAIL gsi.sh --release a17 with BUILD_ID XX1A.000000.001 exits 1 ($out)"; fail=1; }
  out=$(RHIZO_AOSP_A17_DIR="$tmp/none" "$root/tools/build/image/gsi.sh" --release a17 --variant user 2>&1)
  [[ $? -ne 0 && "$out" == *"no $tmp/none/.repo"* ]] || { echo "FAIL gsi.sh --release a17 with RHIZO_AOSP_A17_DIR=none prints no none/.repo ($out)"; fail=1; }
  out=$("$root/tools/build/image/gsi.sh" --release a18 --variant user 2>&1)
  [[ $? -eq 2 && "$out" == *"--release a18 is not a16 or a17"* ]] || { echo "FAIL gsi.sh --release a18 exits 2 ($out)"; fail=1; }


  printf 'ro.build.id=B1\nro.build.type=user\nro.build.tags=release-keys\nro.build.version.incremental=rhizo2\nro.product.system.name=mainline\nro.system.build.fingerprint=Android/gsi_x86_64/generic_x86_64:16/B1/rhizo2:user/release-keys\n' > "$tmp/build.prop"
  printf 'ro.product.product.name=gsi_x86_64\nro.product.build.fingerprint=Android/gsi_x86_64/generic_x86_64:16/B1/rhizo2:user/release-keys\n' > "$tmp/product.prop"
  check_posture "$tmp/build.prop" user B1 2 "$tmp/product.prop" >/dev/null 2>&1 || { echo "FAIL check_posture on a gsi_x86_64 user build.prop and product.prop returns 0"; fail=1; }
  sed -i 's|^ro.system.build.fingerprint=.*|ro.system.build.fingerprint=Android/generic_system/generic:17/B1/rhizo2:user/release-keys|' "$tmp/build.prop"
  check_posture "$tmp/build.prop" user B1 2 "$tmp/product.prop" >/dev/null 2>&1 || { echo "FAIL check_posture with ro.system.build.fingerprint Android/generic_system returns 0"; fail=1; }
  sed -i 's|/gsi_x86_64/|/aosp_x86_64/|' "$tmp/product.prop"
  check_posture "$tmp/build.prop" user B1 2 "$tmp/product.prop" >/dev/null 2>&1 && { echo "FAIL check_posture with an aosp_x86_64 product.prop fingerprint returns 1"; fail=1; }
  check_posture "$tmp/build.prop" user B1 2 >/dev/null 2>&1 && { echo "FAIL check_posture without product.prop returns 1"; fail=1; }
  printf 'ro.build.id=B1\nro.build.type=user\nro.build.tags=release-keys\nro.build.version.incremental=rhizo2\nro.product.build.fingerprint=Android/gsi_x86_64/generic_x86_64:16/B1/rhizo2:user/release-keys\n' > "$tmp/build.prop"
  check_posture "$tmp/build.prop" user B1 2 >/dev/null 2>&1 || { echo "FAIL check_posture on a gsi_x86_64 user build.prop returns 0"; fail=1; }
  check_posture "$tmp/build.prop" user B1 1 >/dev/null 2>&1 && { echo "FAIL check_posture with revision 1 returns 1"; fail=1; }
  sed -i 's|/gsi_x86_64/|/aosp_x86_64/|' "$tmp/build.prop"
  check_posture "$tmp/build.prop" user B1 2 >/dev/null 2>&1 && { echo "FAIL check_posture with an aosp_x86_64 build.prop fingerprint returns 1"; fail=1; }

  mke2fs -q -F -t ext4 -O ^has_journal "$tmp/ext4.img" 4M >/dev/null 2>&1
  mke2fs -q -F -t ext2 "$tmp/ext2.img" 4M >/dev/null 2>&1
  is_ext4_image "$tmp/ext4.img" || { echo "FAIL is_ext4_image on a journal-less ext4 image returns 0"; fail=1; }
  is_ext4_image "$tmp/ext2.img" && { echo "FAIL is_ext4_image on an ext2 image returns 1"; fail=1; }

  rm -rf "$tmp"
  if (( fail )); then echo "FAIL gsi.sh --selftest"; return 1; fi
  echo "ok gsi.sh --selftest"
}

[[ "${1:-}" == --selftest ]] && { selftest; exit $?; }

VARIANT="" RELEASE=a16 REVISION=1 RELEASE_CONFIG="" JOBS="${RHIZO_BUILD_J:-18}" SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --release) RELEASE="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --release-config) RELEASE_CONFIG="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$VARIANT" == user || "$VARIANT" == userdebug ]] || { log "--variant $VARIANT is not user or userdebug"; exit 2; }
[[ "$REVISION" =~ ^[0-9]+$ ]] || { log "--revision $REVISION is not a number"; exit 2; }
paths=$(release_paths "$RELEASE") || { log "--release $RELEASE is not a16 or a17"; exit 2; }
read -r _ PIN_FILE AOSP_LINK AOSP_ENV PIN_VAR DEFAULT_CONFIG <<< "$paths"
RELEASE_CONFIG="${RELEASE_CONFIG:-$DEFAULT_CONFIG}"

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
ROOT="$PWD"
AOSP_DIR="$(readlink -f "${!AOSP_ENV:-$ROOT/$AOSP_LINK}")"
KEYS="${RHIZO_GSI_KEYS:-$HOME/.config/rhizo/gsi-keys}"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
BUILD_DIR="$ROOT/var/gsi-build"
PIN_ID=$(sed -n "s/^$PIN_VAR=//p" "$ROOT/$PIN_FILE")
[[ -n "$PIN_ID" ]] || { log "no $PIN_VAR in $PIN_FILE"; exit 1; }
NAME="rhizo-gsi_x86_64-$VARIANT-$PIN_ID-$REVISION"
OUT_DIR="out-gsi-$VARIANT"
LOG="$BUILD_DIR/build-$VARIANT-$PIN_ID-$REVISION.log"

[[ -d "$AOSP_DIR/.repo" ]] || { log "no $AOSP_DIR/.repo"; exit 1; }
id=$(sed -n 's/^BUILD_ID=//p' "$AOSP_DIR/build/make/core/build_id.mk")
[[ "$id" == "$PIN_ID" ]] || { log "AOSP checkout BUILD_ID is $id, expected $PIN_ID"; exit 1; }
mkdir -p "$BUILD_DIR"

# copy the pinned user zip into the input cache and var/gsi-dl
stage_user_zip() {
  mkdir -p "$CACHE/gsi" "$ROOT/var/gsi-dl"
  cp --remove-destination "$BUILD_DIR/$NAME.zip" "$CACHE/gsi/$NAME.zip.part" && mv "$CACHE/gsi/$NAME.zip.part" "$CACHE/gsi/$NAME.zip"
  cp --remove-destination "$BUILD_DIR/$NAME.zip" "$ROOT/var/gsi-dl/$NAME.zip.part" && mv "$ROOT/var/gsi-dl/$NAME.zip.part" "$ROOT/var/gsi-dl/$NAME.zip"
  log "staged $CACHE/gsi/$NAME.zip and var/gsi-dl/$NAME.zip"
}

if [[ -e "$BUILD_DIR/$NAME.zip" ]]; then
  sha=$(sha256sum "$BUILD_DIR/$NAME.zip" | cut -d' ' -f1)
  if [[ "$VARIANT" == user ]] && pin_matches "$sha" "$ROOT/tools/fetch/gsi-pins.sh" "$RELEASE"; then
    log "$BUILD_DIR/$NAME.zip sha256 matches the $RELEASE pin"
    stage_user_zip
    exit 0
  fi
  log "$BUILD_DIR/$NAME.zip exists and is not the pinned build"
  exit 1
fi

exec 9>"$AOSP_DIR/.rhizo-aosp.lock"
flock -n 9 || { log "flock -n $AOSP_DIR/.rhizo-aosp.lock failed"; exit 1; }
trap 'restore_keymint "$AOSP_DIR"' EXIT

# run a command in the AOSP build environment of VARIANT
in_aosp() {
  ( set +u
    cd "$AOSP_DIR" || exit 1
    export OUT_DIR BUILD_NUMBER="rhizo$REVISION" BUILD_USERNAME=rhizo BUILD_HOSTNAME=rhizo
    # shellcheck disable=SC1091
    source build/envsetup.sh >/dev/null
    lunch gsi_x86_64 "$RELEASE_CONFIG" "$VARIANT" >/dev/null || exit 1
    "$@" )
}

if (( ! SKIP_BUILD )); then
  stash_keymint "$AOSP_DIR" || exit 1
  check_tree_clean "$AOSP_DIR" || exit 1
  ( cd "$AOSP_DIR" && repo manifest -r -o "$BUILD_DIR/manifest-$VARIANT-$PIN_ID-$REVISION.xml" ) \
    || { log "repo manifest -r failed"; exit 1; }
  in_aosp m -j"$JOBS" droid target-files-package dist otatools > "$LOG" 2>&1 \
    || { tail -30 "$LOG" >&2; log "m droid target-files-package dist otatools failed (log $LOG)"; exit 1; }
  check_tree_clean "$AOSP_DIR" || { log "check_tree_clean failed after the build"; exit 1; }
  restore_keymint "$AOSP_DIR"
fi

TF="$AOSP_DIR/$OUT_DIR/dist/gsi_x86_64-target_files-rhizo$REVISION.zip"
[[ -f "$TF" ]] || { log "no $TF"; exit 1; }
STAGE=$(mktemp -d "$BUILD_DIR/stage.XXXXXX")
trap 'restore_keymint "$AOSP_DIR"; rm -rf "$STAGE"' EXIT

if [[ "$VARIANT" == user ]]; then
  mkdir -p "$KEYS" && chmod 0700 "$KEYS"
  key_out=$(tools/build/image/gsi-keys.sh "$TF" "$KEYS") || { log "gsi-keys.sh failed"; exit 1; }
  mapfile -t key_args <<< "$key_out"
  in_aosp sign_target_files_apks -o --allow_gsi_debug_sepolicy -d "$KEYS" "${key_args[@]}" "$TF" "$STAGE/signed-target_files.zip" >> "$LOG" 2>&1 \
    || { tail -30 "$LOG" >&2; log "sign_target_files_apks failed (log $LOG)"; exit 1; }
  unzip -q -o "$TF" META/apkcerts.txt META/apexkeys.txt -d "$STAGE" || { log "failed to extract META/apkcerts.txt and META/apexkeys.txt from $TF"; exit 1; }
  presigned_names "$STAGE/META" > "$STAGE/presigned"
  in_aosp own_key_digests "$KEYS" > "$STAGE/own-keys"
  TF="$STAGE/signed-target_files.zip"
  unzip -q -o "$TF" 'SYSTEM/*.apk' 'SYSTEM/*.apex' 'SYSTEM/*.capex' -d "$STAGE/signed"
  rc=$?; (( rc == 0 || rc == 11 )) || { log "unzip of the signed target-files failed with exit status $rc"; exit 1; }
  in_aosp check_signed_files "$STAGE/signed" "$STAGE/own-keys" "$STAGE/presigned" || { log "check_signed_files failed"; exit 1; }
fi

in_aosp img_from_target_files "$TF" "$STAGE/img.zip" >> "$LOG" 2>&1 \
  || { tail -30 "$LOG" >&2; log "img_from_target_files failed (log $LOG)"; exit 1; }
unzip -q -o "$STAGE/img.zip" system.img -d "$STAGE" || { log "no system.img in $STAGE/img.zip"; exit 1; }
unzip -p "$TF" SYSTEM/build.prop > "$STAGE/build.prop" || { log "no SYSTEM/build.prop in $TF"; exit 1; }
unzip -p "$TF" SYSTEM/product/etc/build.prop > "$STAGE/product.prop" || { log "no SYSTEM/product/etc/build.prop in $TF"; exit 1; }
if file -b "$STAGE/system.img" | grep -q "Android sparse image"; then
  in_aosp simg2img "$STAGE/system.img" "$STAGE/system.raw" && mv "$STAGE/system.raw" "$STAGE/system.img" || exit 1
fi
is_ext4_image "$STAGE/system.img" || { log "system.img is not ext4 ($(file -b "$STAGE/system.img"))"; exit 1; }
check_posture "$STAGE/build.prop" "$VARIANT" "$PIN_ID" "$REVISION" "$STAGE/product.prop" || { log "check_posture failed for $VARIANT"; exit 1; }
if [[ "$VARIANT" == user ]]; then
  in_aosp check_image_avb "$STAGE/system.img" "$STAGE/own-keys" || { log "check_image_avb failed for system.img"; exit 1; }
fi

python3 - "$STAGE" "$BUILD_DIR/$NAME.zip" <<'PY' || exit 1
import sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out + ".part", "w", zipfile.ZIP_DEFLATED) as z:
    for name in ("system.img", "build.prop"):
        z.write(f"{stage}/{name}", name)
PY
mv "$BUILD_DIR/$NAME.zip.part" "$BUILD_DIR/$NAME.zip"
sha=$(sha256sum "$BUILD_DIR/$NAME.zip" | cut -d' ' -f1)
echo "$sha  $NAME.zip" > "$BUILD_DIR/$NAME.zip.sha256"
log "built $BUILD_DIR/$NAME.zip sha256=$sha"

if [[ "$VARIANT" == user ]] && ! pin_matches "$sha" "$ROOT/tools/fetch/gsi-pins.sh" "$RELEASE"; then
  log "$NAME.zip sha256=$sha does not match GSI_SHA[$RELEASE] in tools/fetch/gsi-pins.sh"
elif [[ "$VARIANT" == user ]]; then
  stage_user_zip
else
  label=userdebug; [[ "$RELEASE" == a16 ]] || label="$RELEASE-userdebug"
  mkdir -p "$ROOT/var/share"
  cp --remove-destination "$STAGE/system.img" "$ROOT/var/share/gsi_$label.img.part" && mv "$ROOT/var/share/gsi_$label.img.part" "$ROOT/var/share/gsi_$label.img"
  log "staged var/share/gsi_$label.img"
fi
