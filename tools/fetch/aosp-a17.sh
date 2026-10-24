#!/bin/bash
# fetch and verify the android17-release checkout the a17 GSI builds from
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE="${RHIZO_INPUT_CACHE:-$HOME/.cache/rhizo/inputs}"
AOSP_A17_DIR="${RHIZO_AOSP_A17_DIR:-$CACHE/aosp/android17}"
AOSP_MANIFEST_URL=https://android.googlesource.com/platform/manifest
AOSP_A17_MANIFEST_BRANCH=android17-release
AOSP_A17_MANIFEST_COMMIT=29ace668ae756c7b8917c57abb440f6518844b0c
AOSP_A17_BUILD_ID=CP2A.260605.016

# print a log line to stderr
log() { echo "[aosp-a17] $*" >&2; }

# print the usage text
usage() {
  cat <<'EOF'
Usage: tools/fetch/aosp-a17.sh [--sync]
       tools/fetch/aosp-a17.sh --selftest
EOF
}

# check a checkout's manifest branch, manifest commit and BUILD_ID against the pin
validate() {
  local d="$1" rev commit id
  [[ -d "$d/.repo/manifests" ]] || { log "$d has no .repo/manifests"; return 1; }
  rev=$(sed -n 's/.*<default[^>]*revision="\([^"]*\)".*/\1/p' "$d/.repo/manifests/default.xml" | head -1)
  [[ "$rev" == "$AOSP_A17_MANIFEST_BRANCH" ]] || { log "$d's manifest default revision is '$rev', not $AOSP_A17_MANIFEST_BRANCH"; return 1; }
  commit=$(git -C "$d/.repo/manifests" rev-parse HEAD 2>/dev/null)
  [[ "$commit" == "$AOSP_A17_MANIFEST_COMMIT" ]] || { log "$d's manifest commit is '$commit', not $AOSP_A17_MANIFEST_COMMIT"; return 1; }
  id=$(sed -n 's/^BUILD_ID=//p' "$d/build/make/core/build_id.mk")
  [[ "$id" == "$AOSP_A17_BUILD_ID" ]] || { log "$d's BUILD_ID is '$id', not $AOSP_A17_BUILD_ID"; return 1; }
}

# repo init and sync the pinned checkout into a directory, resuming a partial one
sync_checkout() {
  local d="$1"
  mkdir -p "$d" && : > "$d/.rhizo-sync-started"
  log "syncing $AOSP_A17_MANIFEST_BRANCH into $d (about 140 GB, hours; a rerun resumes)"
  ( cd "$d" && repo init -q --repo-rev=v2.69 -u "$AOSP_MANIFEST_URL" -b "$AOSP_A17_MANIFEST_COMMIT" --partial-clone --clone-filter=blob:none </dev/null \
      && { repo sync -q -c -j8 </dev/null \
           || { log "some projects did not check out; syncing again at -j2"; repo sync -q -c -j2 </dev/null; }; } ) \
    || { log "repo init/sync failed in $d; run this again to resume"; return 1; }
  validate "$d" || return 1
  printf '%s\n' "$AOSP_A17_MANIFEST_COMMIT" > "$d/.rhizo-input"
}

# validate or set up the checkout and link it into the tree as aosp-android17
setup() {
  local sync="$1" d="$AOSP_A17_DIR" link="$REPO_ROOT/aosp-android17"
  if [[ -L "$link" ]]; then
    validate "$link" || return 1
    log "ok: aosp-android17 -> $(readlink -f "$link")"; return 0
  fi
  [[ -e "$link" ]] && { log "$link exists and is not a symlink; refusing to replace it"; return 1; }
  if [[ ! -d "$d/.repo" || ( -f "$d/.rhizo-sync-started" && ! -f "$d/.rhizo-input" ) ]]; then
    (( sync )) || {
      log "no complete checkout at $d; point RHIZO_AOSP_A17_DIR at one, or pass --sync to repo init/sync"
      log "  $AOSP_A17_MANIFEST_BRANCH at manifest commit $AOSP_A17_MANIFEST_COMMIT there (about 140 GB, hours)"
      return 1
    }
    sync_checkout "$d" || return 1
  fi
  validate "$d" || return 1
  ln -s "$d" "$link" || return 1
  log "ok: aosp-android17 -> $d"
}

# check the pin and the checkout checks against fixture checkouts
selftest() {
  local tmp fail=0 fx fx_commit out
  tmp=$(mktemp -d)
  [[ "$AOSP_A17_MANIFEST_BRANCH" == android17-release && "$AOSP_A17_MANIFEST_COMMIT" =~ ^[0-9a-f]{40}$ && "$AOSP_A17_BUILD_ID" =~ ^[A-Z0-9]{4}\.[0-9]{6}\.[0-9]{3}$ ]] \
    || { echo "FAIL the a17 pin is android17-release at a full commit with a BUILD_ID"; fail=1; }
  fx="$tmp/aosp17"
  mkdir -p "$fx/.repo/manifests" "$fx/build/make/core"
  printf '<manifest>\n  <default revision="%s" remote="aosp"/>\n</manifest>\n' "$AOSP_A17_MANIFEST_BRANCH" > "$fx/.repo/manifests/default.xml"
  git -C "$fx/.repo/manifests" init -q && git -C "$fx/.repo/manifests" add default.xml \
    && git -C "$fx/.repo/manifests" -c user.name=t -c user.email=t@t commit -q -m pin
  fx_commit=$(git -C "$fx/.repo/manifests" rev-parse HEAD)
  printf 'BUILD_ID=%s\n' "$AOSP_A17_BUILD_ID" > "$fx/build/make/core/build_id.mk"
  out=$(AOSP_A17_MANIFEST_COMMIT="$fx_commit" validate "$fx" 2>&1) || { echo "FAIL a checkout at the pin passes -- got: $out"; fail=1; }
  out=$(validate "$fx" 2>&1)
  [[ $? -ne 0 && "$out" == *"not $AOSP_A17_MANIFEST_COMMIT"* ]] || { echo "FAIL a checkout at another manifest commit is refused -- got: $out"; fail=1; }
  out=$(AOSP_A17_MANIFEST_COMMIT="$fx_commit" AOSP_A17_MANIFEST_BRANCH=android16-qpr2-release validate "$fx" 2>&1)
  [[ $? -ne 0 && "$out" == *"is 'android17-release', not android16-qpr2-release"* ]] || { echo "FAIL a checkout of another branch is refused -- got: $out"; fail=1; }
  printf 'BUILD_ID=XX1A.000000.001\n' > "$fx/build/make/core/build_id.mk"
  out=$(AOSP_A17_MANIFEST_COMMIT="$fx_commit" validate "$fx" 2>&1)
  [[ $? -ne 0 && "$out" == *"BUILD_ID is 'XX1A.000000.001', not $AOSP_A17_BUILD_ID"* ]] || { echo "FAIL a checkout of another BUILD_ID is refused -- got: $out"; fail=1; }
  out=$(AOSP_A17_DIR="$tmp/none" REPO_ROOT="$tmp" setup 0 2>&1)
  [[ $? -ne 0 && "$out" == *"no complete checkout at $tmp/none"* && "$out" == *"manifest commit $AOSP_A17_MANIFEST_COMMIT"* ]] \
    || { echo "FAIL a missing checkout is refused naming its pin -- got: $out"; fail=1; }
  mkdir -p "$tmp/bin"
  printf '#!/bin/sh\necho "$@" >> "%s/repo.args"\nexit 1\n' "$tmp" > "$tmp/bin/repo"
  chmod +x "$tmp/bin/repo"
  out=$(PATH="$tmp/bin:$PATH" AOSP_A17_DIR="$tmp/sync" REPO_ROOT="$tmp" setup 1 2>&1)
  [[ $? -ne 0 && -f "$tmp/sync/.rhizo-sync-started" && "$(head -1 "$tmp/repo.args")" == *"-b $AOSP_A17_MANIFEST_COMMIT "* ]] \
    || { echo "FAIL --sync repo inits at the manifest commit -- got: $out $(cat "$tmp/repo.args" 2>/dev/null)"; fail=1; }
  [[ ! -e "$tmp/aosp-android17" && ! -f "$tmp/sync/.rhizo-input" ]] || { echo "FAIL a failed sync is neither marked done nor linked"; fail=1; }
  rm -rf "$tmp"
  if (( fail )); then echo "aosp-a17.sh selftest: FAILED"; return 1; fi
  echo "aosp-a17.sh selftest: ok"
}

case "${1:-}" in
  --selftest) selftest; exit $? ;;
  --sync) setup 1 ;;
  "") setup 0 ;;
  *) usage >&2; exit 2 ;;
esac
