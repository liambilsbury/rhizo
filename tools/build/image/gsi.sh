#!/bin/bash
# build the Android 16 GSI from unmodified AOSP source with the stock gsi_x86_64 target
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

# print a prefixed progress line
log() { echo "[gsi] $*" >&2; }
# print the usage text
usage() {
  cat <<'EOF'
Usage: tools/build/image/gsi.sh --variant user|userdebug [--revision N] [--release CONFIG] [--jobs N] [--skip-build]
       tools/build/image/gsi.sh --selftest
EOF
}

KEYMINT_STASH=""

# set aside the KeyMint patches in system/keymaster
stash_keymint() {
  local d="$1/system/keymaster" tag
  tag="rhizo gsi.sh $(date +%s%N)"
  [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]] || return 0
  git -C "$d" stash push -q -m "$tag" || { log "could not stash $d"; return 1; }
  KEYMINT_STASH=$(git -C "$d" stash list --format='%H %gs' | grep -F "$tag" | head -1 | cut -d' ' -f1)
  [[ -n "$KEYMINT_STASH" ]] || { log "stashed system/keymaster but cannot find the stash '$tag' -- recover it with git -C $d stash list"; return 1; }
  log "set aside the KeyMint patches in system/keymaster"
}

# put the KeyMint patches back
restore_keymint() {
  local d="$1/system/keymaster" ref
  [[ -n "$KEYMINT_STASH" ]] || return 0
  if git -C "$d" diff --quiet "$KEYMINT_STASH" -- . 2>/dev/null; then
    log "the KeyMint patches were already back in system/keymaster"
  else
    git -C "$d" stash apply -q "$KEYMINT_STASH" || { log "could not restore the KeyMint patches: git -C $d stash apply $KEYMINT_STASH"; return 1; }
  fi
  ref=$(git -C "$d" stash list --format='%gd %H' | awk -v s="$KEYMINT_STASH" '$2 == s {print $1; exit}')
  [[ -n "$ref" ]] && git -C "$d" stash drop -q "$ref"
  KEYMINT_STASH=""
  log "restored the KeyMint patches in system/keymaster"
}

# check that no AOSP project has local changes or is off its manifest revision
check_tree_clean() {
  local aosp="$1" p m dirty=0
  while read -r p; do
    if [[ -n "$(git -C "$aosp/$p" status --porcelain 2>&1)" ]]; then
      log "edited AOSP project: $p"
      dirty=1
    fi
    m=$(git -C "$aosp/$p" for-each-ref --format='%(objectname)' refs/remotes/m/ 2>/dev/null | head -1)
    if [[ -n "$m" && "$m" != "$(git -C "$aosp/$p" rev-parse HEAD 2>/dev/null)" ]]; then
      log "AOSP project not at its manifest revision: $p"
      dirty=1
    fi
  done < "$aosp/.repo/project.list"
  (( dirty == 0 )) || { log "refusing to build from an edited AOSP tree"; return 1; }
}

# print the digest of all of the certificates and AVB public keys in our keys dir
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

# print the names of all of the apks and apexes META marks PRESIGNED
presigned_names() {
  grep -hE '(^|[[:space:]])(container_)?certificate="PRESIGNED"' "$1/apkcerts.txt" "$1/apexkeys.txt" | sed -n 's/^name="\([^"]*\)".*/\1/p' | sort -u
}

# print the signer digests of an apk, apex or capex
signer_digests() {
  local f="$1" t
  apksigner verify --print-certs "$f" 2>/dev/null | sed -n 's/^Signer #[0-9]* certificate SHA-256 digest: */cert /p'
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

# check all of the apks, apexes and capexes are signed with our keys
check_signed_files() {
  local dir="$1" own="$2" presigned="${3:-/dev/null}" f d digests bad_n=0 n=0
  while IFS= read -r -d '' f; do
    if grep -qxF "${f##*/}" "$presigned"; then
      log "presigned by AOSP, kept as shipped: ${f#"$dir"/}"
      continue
    fi
    n=$((n + 1))
    digests=$(signer_digests "$f")
    if ! grep -q '^cert ' <<< "$digests"; then
      log "no readable signature: ${f#"$dir"/}"
      bad_n=$((bad_n + 1)); continue
    fi
    if [[ "$f" == *.apex || "$f" == *.capex ]] && ! grep -q '^avb ' <<< "$digests"; then
      log "no readable payload key: ${f#"$dir"/}"
      bad_n=$((bad_n + 1)); continue
    fi
    while read -r d; do
      grep -qxF "$d" "$own" && continue
      log "signed with a key that is not ours ($d): ${f#"$dir"/}"
      bad_n=$((bad_n + 1))
    done <<< "$digests"
  done < <(find "$dir" -type f \( -name '*.apk' -o -name '*.apex' -o -name '*.capex' \) -print0)
  log "checked $n signed files, $bad_n not signed with our keys"
  (( n > 0 && bad_n == 0 ))
}

# check that an image's AVB footer is signed with one of our keys
check_image_avb() {
  local key
  key=$("${AVBTOOL:-avbtool}" info_image --image "$1" 2>/dev/null | sed -n 's/^Public key (sha1): *\(.*\)$/\1/p' | head -1)
  if [[ -n "$key" ]] && grep -qxF "avb $key" "$2"; then log "  ok: AVB footer key $key"; return 0; fi
  log "  WRONG: AVB footer key '${key:-none}' is not one of ours"
  return 1
}

# check a zip's sha against the a16 pin in a gsi-pins.sh
pin_matches() {
  [[ "$1" == "$(sed -n 's/^GSI_SHA\[a16\]="\(.*\)"$/\1/p' "$2")" ]]
}

# check that an image is ext4
is_ext4_image() {
  dumpe2fs -h "$1" 2>/dev/null | grep -q '^Filesystem features:.*\bextent\b'
}

# check the build.prop of the image against the variant
check_posture() {
  local prop="$1" variant="$2" build_id="$3" revision="$4" k want got bad=0 tags=release-keys
  [[ "$variant" == userdebug ]] && tags=test-keys
  for k in ro.build.id="$build_id" ro.build.type="$variant" ro.build.tags="$tags" ro.build.version.incremental="rhizo$revision"; do
    want="${k#*=}"; k="${k%%=*}"
    got=$(sed -n "s/^${k//./\\.}=//p" "$prop" | tail -1)
    if [[ "$got" == "$want" ]]; then log "  ok: $k=$got"; else log "  WRONG: $k=$got, want $want"; bad=1; fi
  done
  got=$(sed -n 's/^ro\.system\.build\.fingerprint=//p' "$prop" | tail -1)
  if [[ "$got" == Android/gsi_x86_64/* ]]; then log "  ok: fingerprint $got"; else log "  WRONG: fingerprint $got, want Android/gsi_x86_64/..."; bad=1; fi
  (( bad == 0 ))
}

# check that the AOSP fixture checks behave
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
    || { echo "FAIL clean tree passes"; fail=1; }

  echo x >> "$tmp/aosp/projA/file"
  out=$(check_tree_clean "$tmp/aosp" 2>&1)
  [[ $? -ne 0 && "$out" == *projA* ]] || { echo "FAIL edited project refused -- got: $out"; fail=1; }
  git -C "$tmp/aosp/projA" checkout -q file

  echo patch >> "$tmp/aosp/system/keymaster/file"
  stash_keymint "$tmp/aosp" >/dev/null 2>&1
  check_tree_clean "$tmp/aosp" >/dev/null 2>&1 \
    || { echo "FAIL keymaster stash allowed"; fail=1; }
  restore_keymint "$tmp/aosp" >/dev/null 2>&1
  grep -q patch "$tmp/aosp/system/keymaster/file" || { echo "FAIL keymaster patches restored"; fail=1; }

  stash_keymint "$tmp/aosp" >/dev/null 2>&1
  echo patch >> "$tmp/aosp/system/keymaster/file"
  restore_keymint "$tmp/aosp" >/dev/null 2>&1 || { echo "FAIL patches put back by someone else count as restored"; fail=1; }
  [[ -z "$(git -C "$tmp/aosp/system/keymaster" stash list)" ]] || { echo "FAIL the stash is dropped once its patches are back"; fail=1; }

  git -C "$tmp/aosp/system/keymaster" checkout -q file
  git -C "$tmp/aosp/projA" update-ref refs/remotes/m/rev HEAD
  check_tree_clean "$tmp/aosp" >/dev/null 2>&1 || { echo "FAIL a project at its manifest revision passes"; fail=1; }
  echo y > "$tmp/aosp/projA/new" && git -C "$tmp/aosp/projA" add new
  git -C "$tmp/aosp/projA" -c user.name=t -c user.email=t@t commit -q -m local
  out=$(check_tree_clean "$tmp/aosp" 2>&1)
  [[ $? -ne 0 && "$out" == *projA* ]] || { echo "FAIL a local commit is refused by project -- got: $out"; fail=1; }

  mkdir -p "$tmp/keys" "$tmp/meta" "$tmp/signed/SYSTEM/app" "$tmp/signed/SYSTEM/apex" "$tmp/empty"
  openssl req -new -x509 -newkey rsa:2048 -nodes -keyout "$tmp/keys/platform.key" -out "$tmp/keys/platform.x509.pem" -subj /CN=t -days 1 >/dev/null 2>&1
  openssl genrsa -out "$tmp/keys/com.x.pem" 1024 >/dev/null 2>&1
  # shellcheck disable=SC2016  # the stub expands its arguments
  printf '#!/bin/bash\ncase "$1" in extract_public_key) sha1sum < "$3" | cut -c1-8 > "$5" ;; info_image) echo "Public key (sha1): $(cat "$3.key")" ;; esac\n' > "$tmp/avbtool"
  chmod +x "$tmp/avbtool"
  local own_cert own_avb
  own_cert=$(openssl x509 -in "$tmp/keys/platform.x509.pem" -outform DER | sha256sum | cut -d' ' -f1)
  own_avb=$(sha1sum < "$tmp/keys/com.x.pem" | cut -c1-8 | sha1sum | cut -d' ' -f1)
  AVBTOOL="$tmp/avbtool" own_key_digests "$tmp/keys" > "$tmp/own" 2>/dev/null
  grep -qx "cert $own_cert" "$tmp/own" || { echo "FAIL our certificates' digests are listed"; fail=1; }
  grep -qx "avb $own_avb" "$tmp/own" || { echo "FAIL our AVB keys' digests are listed -- got: $(cat "$tmp/own")"; fail=1; }
  printf 'name="Foo.apk" certificate="k/platform.x509.pem" private_key="k/platform.pk8"\nname="Pre.apk" certificate="PRESIGNED" private_key=""\n' > "$tmp/meta/apkcerts.txt"
  printf 'name="com.pre.apex" public_key="" private_key="" container_certificate="PRESIGNED" container_private_key="" partition="system"\n' > "$tmp/meta/apexkeys.txt"
  presigned_names "$tmp/meta" > "$tmp/pre"
  grep -qx Pre.apk "$tmp/pre" && grep -qx com.pre.apex "$tmp/pre" && [[ "$(grep -c . "$tmp/pre")" == 2 ]] \
    || { echo "FAIL presigned names are read from META -- got: $(cat "$tmp/pre")"; fail=1; }

  touch "$tmp/signed/SYSTEM/app/a.apk" "$tmp/signed/SYSTEM/apex/b.apex"
  signer_digests() { case "$1" in *a.apk) echo "cert $own_cert" ;; *b.apex) echo "cert $own_cert"; echo "avb $own_avb" ;; esac; }
  check_signed_files "$tmp/signed" "$tmp/own" /dev/null >/dev/null 2>&1 || { echo "FAIL files signed only with our keys pass"; fail=1; }
  signer_digests() { case "$1" in *a.apk) echo "cert ffff" ;; *b.apex) echo "cert $own_cert"; echo "avb $own_avb" ;; esac; }
  out=$(check_signed_files "$tmp/signed" "$tmp/own" /dev/null 2>&1)
  [[ $? -ne 0 && "$out" == *a.apk* && "$out" != *b.apex* ]] || { echo "FAIL an apk signed with another key is refused by name -- got: $out"; fail=1; }
  signer_digests() { case "$1" in *a.apk) echo "cert $own_cert" ;; *b.apex) echo "cert $own_cert" ;; esac; }
  out=$(check_signed_files "$tmp/signed" "$tmp/own" /dev/null 2>&1)
  [[ $? -ne 0 && "$out" == *b.apex* ]] || { echo "FAIL an apex whose payload key cannot be read is refused -- got: $out"; fail=1; }
  signer_digests() { case "$1" in *a.apk) echo "cert $own_cert" ;; *b.apex) echo "cert $own_cert"; echo "avb eeee" ;; esac; }
  out=$(check_signed_files "$tmp/signed" "$tmp/own" /dev/null 2>&1)
  [[ $? -ne 0 && "$out" == *b.apex* ]] || { echo "FAIL an apex with another payload key is refused -- got: $out"; fail=1; }
  signer_digests() { case "$1" in *a.apk) echo "cert $own_cert" ;; esac; }
  out=$(check_signed_files "$tmp/signed" "$tmp/own" /dev/null 2>&1)
  [[ $? -ne 0 && "$out" == *b.apex* ]] || { echo "FAIL a file with no readable signature is refused -- got: $out"; fail=1; }
  printf 'b.apex\n' > "$tmp/presigned"
  check_signed_files "$tmp/signed" "$tmp/own" "$tmp/presigned" >/dev/null 2>&1 || { echo "FAIL a file AOSP ships presigned keeps its signature"; fail=1; }
  check_signed_files "$tmp/empty" "$tmp/own" /dev/null >/dev/null 2>&1 && { echo "FAIL a tree with nothing to check is refused"; fail=1; }
  unset -f signer_digests

  echo "$own_avb" > "$tmp/system.img.key"
  AVBTOOL="$tmp/avbtool" check_image_avb "$tmp/system.img" "$tmp/own" >/dev/null 2>&1 || { echo "FAIL an image signed with our AVB key passes"; fail=1; }
  echo dddd > "$tmp/system.img.key"
  AVBTOOL="$tmp/avbtool" check_image_avb "$tmp/system.img" "$tmp/own" >/dev/null 2>&1 && { echo "FAIL an image with the AOSP test AVB key is refused"; fail=1; }

  printf 'GSI_SHA[a16]="%s"\n' "$own_cert" > "$tmp/pins.sh"
  pin_matches "$own_cert" "$tmp/pins.sh" || { echo "FAIL a zip whose sha is the a16 pin is staged"; fail=1; }
  pin_matches ffff "$tmp/pins.sh" && { echo "FAIL a zip whose sha is not the a16 pin is not staged"; fail=1; }


  printf 'ro.build.id=B1\nro.build.type=user\nro.build.tags=release-keys\nro.build.version.incremental=rhizo2\nro.product.system.name=mainline\nro.system.build.fingerprint=Android/gsi_x86_64/generic_x86_64:16/B1/rhizo2:user/release-keys\n' > "$tmp/build.prop"
  check_posture "$tmp/build.prop" user B1 2 >/dev/null 2>&1 || { echo "FAIL a gsi_x86_64 user build passes"; fail=1; }
  check_posture "$tmp/build.prop" user B1 1 >/dev/null 2>&1 && { echo "FAIL a build of another revision is refused"; fail=1; }
  sed -i 's|/gsi_x86_64/|/aosp_x86_64/|' "$tmp/build.prop"
  check_posture "$tmp/build.prop" user B1 2 >/dev/null 2>&1 && { echo "FAIL an aosp_x86_64 build is refused"; fail=1; }

  mke2fs -q -F -t ext4 -O ^has_journal "$tmp/ext4.img" 4M >/dev/null 2>&1
  mke2fs -q -F -t ext2 "$tmp/ext2.img" 4M >/dev/null 2>&1
  is_ext4_image "$tmp/ext4.img" || { echo "FAIL a journal-less ext4 image passes, as Android builds it"; fail=1; }
  is_ext4_image "$tmp/ext2.img" && { echo "FAIL an ext2 image without extents is refused"; fail=1; }

  rm -rf "$tmp"
  if (( fail )); then echo "gsi.sh selftest: FAILED"; return 1; fi
  echo "gsi.sh selftest: ok"
}

[[ "${1:-}" == --selftest ]] && { selftest; exit $?; }

VARIANT="" REVISION=1 RELEASE_CONFIG="${GSI_RELEASE:-bp4a}" JOBS="${RHIZO_BUILD_J:-18}" SKIP_BUILD=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) VARIANT="${2:-}"; shift 2 ;;
    --revision) REVISION="${2:-}"; shift 2 ;;
    --release) RELEASE_CONFIG="${2:-}"; shift 2 ;;
    --jobs) JOBS="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$VARIANT" == user || "$VARIANT" == userdebug ]] || { log "--variant must be user or userdebug"; exit 2; }
[[ "$REVISION" =~ ^[0-9]+$ ]] || { log "--revision must be a number"; exit 2; }

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
ROOT="$PWD"
AOSP_DIR="$(readlink -f "${RHIZO_AOSP_DIR:-$ROOT/aosp-android16-qpr2}")"
KEYS="${RHIZO_GSI_KEYS:-$HOME/.config/rhizo/gsi-keys}"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
BUILD_DIR="$ROOT/var/gsi-build"
PIN_ID=$(sed -n 's/^AOSP_BUILD_ID=//p' "$ROOT/tools/fetch/build-inputs.sh")
NAME="rhizo-gsi_x86_64-$VARIANT-$PIN_ID-$REVISION"
OUT_DIR="out-gsi-$VARIANT"
LOG="$BUILD_DIR/build-$VARIANT-$REVISION.log"

[[ -d "$AOSP_DIR/.repo" ]] || { log "no AOSP checkout at $AOSP_DIR -- run make inputs first"; exit 1; }
id=$(sed -n 's/^BUILD_ID=//p' "$AOSP_DIR/build/make/core/build_id.mk")
[[ "$id" == "$PIN_ID" ]] || { log "the AOSP checkout is BUILD_ID $id, the pin is $PIN_ID"; exit 1; }
mkdir -p "$BUILD_DIR"

# copy the pinned user zip into the input cache and var/gsi-dl
stage_user_zip() {
  mkdir -p "$CACHE/gsi" "$ROOT/var/gsi-dl"
  cp --remove-destination "$BUILD_DIR/$NAME.zip" "$CACHE/gsi/$NAME.zip.part" && mv "$CACHE/gsi/$NAME.zip.part" "$CACHE/gsi/$NAME.zip"
  cp --remove-destination "$BUILD_DIR/$NAME.zip" "$ROOT/var/gsi-dl/$NAME.zip.part" && mv "$ROOT/var/gsi-dl/$NAME.zip.part" "$ROOT/var/gsi-dl/$NAME.zip"
  log "staged -> $CACHE/gsi/$NAME.zip and var/gsi-dl/$NAME.zip"
}

if [[ -e "$BUILD_DIR/$NAME.zip" ]]; then
  sha=$(sha256sum "$BUILD_DIR/$NAME.zip" | cut -d' ' -f1)
  if [[ "$VARIANT" == user ]] && pin_matches "$sha" "$ROOT/tools/fetch/gsi-pins.sh"; then
    log "$NAME.zip is already built and pinned"
    stage_user_zip
    exit 0
  fi
  log "$BUILD_DIR/$NAME.zip exists and is not the pinned build -- build another --revision, or move it aside"
  exit 1
fi

exec 9>"$AOSP_DIR/.rhizo-aosp.lock"
flock -n 9 || { log "another build holds $AOSP_DIR/.rhizo-aosp.lock"; exit 1; }
trap 'restore_keymint "$AOSP_DIR"' EXIT

# run a command in the AOSP build environment for this variant
in_aosp() {
  ( set +u
    cd "$AOSP_DIR" || exit 1
    export OUT_DIR BUILD_NUMBER="rhizo$REVISION" BUILD_USERNAME=rhizo BUILD_HOSTNAME=rhizo
    # shellcheck disable=SC1091  # the AOSP checkout's environment
    source build/envsetup.sh >/dev/null
    lunch gsi_x86_64 "$RELEASE_CONFIG" "$VARIANT" >/dev/null || exit 1
    "$@" )
}

if (( ! SKIP_BUILD )); then
  stash_keymint "$AOSP_DIR" || exit 1
  log "checking that no AOSP project is edited"
  check_tree_clean "$AOSP_DIR" || exit 1
  ( cd "$AOSP_DIR" && repo manifest -r -o "$BUILD_DIR/manifest-$VARIANT-$PIN_ID-$REVISION.xml" ) \
    || { log "repo manifest -r failed"; exit 1; }
  log "building lunch gsi_x86_64 $RELEASE_CONFIG $VARIANT into $OUT_DIR, -j$JOBS (hours); log: $LOG"
  in_aosp m -j"$JOBS" droid target-files-package dist otatools > "$LOG" 2>&1 \
    || { tail -30 "$LOG" >&2; log "the build failed -- see $LOG"; exit 1; }
  check_tree_clean "$AOSP_DIR" || { log "the AOSP tree changed during the build -- build again"; exit 1; }
  restore_keymint "$AOSP_DIR"
fi

TF="$AOSP_DIR/$OUT_DIR/dist/gsi_x86_64-target_files-rhizo$REVISION.zip"
[[ -f "$TF" ]] || { log "no $TF -- build revision $REVISION first"; exit 1; }
STAGE=$(mktemp -d "$BUILD_DIR/stage.XXXXXX")
trap 'restore_keymint "$AOSP_DIR"; rm -rf "$STAGE"' EXIT

if [[ "$VARIANT" == user ]]; then
  mkdir -p "$KEYS" && chmod 0700 "$KEYS"
  key_out=$(tools/build/image/gsi-keys.sh "$TF" "$KEYS") || { log "could not make the signing keys"; exit 1; }
  mapfile -t key_args <<< "$key_out"
  log "signing with the keys in $KEYS"
  in_aosp sign_target_files_apks -o --allow_gsi_debug_sepolicy -d "$KEYS" "${key_args[@]}" "$TF" "$STAGE/signed-target_files.zip" >> "$LOG" 2>&1 \
    || { tail -30 "$LOG" >&2; log "signing failed -- see $LOG"; exit 1; }
  unzip -q -o "$TF" META/apkcerts.txt META/apexkeys.txt -d "$STAGE" || { log "cannot read META from $TF"; exit 1; }
  presigned_names "$STAGE/META" > "$STAGE/presigned"
  in_aosp own_key_digests "$KEYS" > "$STAGE/own-keys"
  TF="$STAGE/signed-target_files.zip"
  unzip -q -o "$TF" 'SYSTEM/*.apk' 'SYSTEM/*.apex' 'SYSTEM/*.capex' -d "$STAGE/signed"
  rc=$?; (( rc == 0 || rc == 11 )) || { log "cannot unpack the signed target-files (unzip $rc)"; exit 1; }
  log "checking that every apk, apex and capex is signed with our keys"
  in_aosp check_signed_files "$STAGE/signed" "$STAGE/own-keys" "$STAGE/presigned" || { log "the signed image carries keys that are not ours"; exit 1; }
fi

in_aosp img_from_target_files "$TF" "$STAGE/img.zip" >> "$LOG" 2>&1 \
  || { tail -30 "$LOG" >&2; log "img_from_target_files failed -- see $LOG"; exit 1; }
unzip -q -o "$STAGE/img.zip" system.img -d "$STAGE" || { log "no system.img in $STAGE/img.zip"; exit 1; }
unzip -p "$TF" SYSTEM/build.prop > "$STAGE/build.prop" || { log "no SYSTEM/build.prop in $TF"; exit 1; }
if file -b "$STAGE/system.img" | grep -q "Android sparse image"; then
  in_aosp simg2img "$STAGE/system.img" "$STAGE/system.raw" && mv "$STAGE/system.raw" "$STAGE/system.img" || exit 1
fi
is_ext4_image "$STAGE/system.img" || { log "system.img is not ext4: $(file -b "$STAGE/system.img")"; exit 1; }
check_posture "$STAGE/build.prop" "$VARIANT" "$PIN_ID" "$REVISION" || { log "the image is not the $VARIANT build this script makes"; exit 1; }
if [[ "$VARIANT" == user ]]; then
  in_aosp check_image_avb "$STAGE/system.img" "$STAGE/own-keys" || { log "system.img's AVB footer is not signed with our key"; exit 1; }
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

if [[ "$VARIANT" == user ]] && ! pin_matches "$sha" "$ROOT/tools/fetch/gsi-pins.sh"; then
  log "not staged: the a16 pin is another build -- to ship this one, set GSI_URL[a16] and GSI_SHA[a16] to $NAME.zip and $sha"
  log "  in tools/fetch/gsi-pins.sh and src/install/prepare/fetch-gsi.sh, then run this again to stage it"
elif [[ "$VARIANT" == user ]]; then
  stage_user_zip
else
  mkdir -p "$ROOT/var/share"
  cp --remove-destination "$STAGE/system.img" "$ROOT/var/share/gsi_userdebug.img.part" && mv "$ROOT/var/share/gsi_userdebug.img.part" "$ROOT/var/share/gsi_userdebug.img"
  log "staged -> var/share/gsi_userdebug.img (next: tools/fetch/images/gsi.sh userdebug --from-image var/share/gsi_userdebug.img)"
fi
