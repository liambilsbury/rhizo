#!/bin/bash
# build the product packages into var/debs
set -euo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_PREFIX \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
ROOT="$(cd "." && pwd)"
OUT="$ROOT/var/debs"
mkdir -p "$OUT"

# remove the package's other versions from a dir
drop_other_versions() {
  local dir="$1" name="$2" pkg old
  pkg="${name%%_*}"
  for old in "$dir/${pkg}_"*.deb; do
    [[ -f "$old" && "$(basename "$old")" != "$name" ]] || continue
    rm -f "$old" "$old.inputs"
    echo "[build-debs] replaced $(basename "$old") in $dir"
  done
}

AT_RHIZO_PREV="" AT_WORK=""
# remove the --at worktree and scratch directory
cleanup_at() {
  [[ -n "${AT_RHIZO_PREV:-}" ]] && git -C "$ROOT" worktree remove --force "$AT_RHIZO_PREV" 2>/dev/null || true
  [[ -n "${AT_WORK:-}" ]] && rm -rf "$AT_WORK" || true
  return 0
}

if [[ "${1:-}" == --at ]]; then
  AT_REF="${2:-}"
  [[ -n "$AT_REF" ]] || { echo "[build-debs] --at needs REF" >&2; exit 2; }
  [[ "${3:-}" == --out && -n "${4:-}" ]] || { echo "[build-debs] --at REF needs --out DIR" >&2; exit 2; }
  AT_OUT="$4"
fi

# build a source tree's packages into var/debs
build_into() {
  local src="$1" glob="$2" stamp="${3:-0}" parent f pre_digest=""
  parent=$(dirname "$src")
  if [[ "$stamp" == 1 ]]; then
    pre_digest=$(python3 -B "$ROOT/tools/build/stamps.py" deb-digest) \
      || { echo "[build-debs] could not take the pre-build input digest" >&2; exit 1; }
  fi
  ( cd "$src" && dpkg-buildpackage -us -uc -b >"$OUT/$(basename "$src").build.log" 2>&1 ) \
    || { echo "[build-debs] $src failed -- see $OUT/$(basename "$src").build.log" >&2; exit 1; }
  for f in "$parent"/$glob; do
    [[ -f "$f" ]] || continue
    drop_other_versions "$OUT" "$(basename "$f")"
    mv -f "$f" "$OUT/"
    echo "[build-debs] $(basename "$f") $(sha256sum "$OUT/$(basename "$f")" | cut -c1-16)"
    if [[ "$stamp" == 1 ]]; then
      python3 -B "$ROOT/test/checks/lib/package-tree.py" "$OUT/$(basename "$f")" "$ROOT"
      python3 -B "$ROOT/tools/build/stamps.py" deb-stamp "$OUT/$(basename "$f")" "$pre_digest"
    fi
  done
  rm -f "$parent/$(basename "$src")"_*.{buildinfo,changes} 2>/dev/null || true
}

# compare two .deb payloads
payload_digest_matches() {
  local a="$1" b="$2" da db ha hb na nb
  da=$(mktemp -d) || return 1
  db=$(mktemp -d) || { rm -rf "$da"; return 1; }
  dpkg-deb --fsys-tarfile "$a" | tar -x -C "$da" 2>/dev/null
  dpkg-deb --fsys-tarfile "$b" | tar -x -C "$db" 2>/dev/null
  rm -f "$da/usr/lib/rhizo/VERSION" "$db/usr/lib/rhizo/VERSION" \
        "$da"/usr/share/doc/rhizo/changelog* "$db"/usr/share/doc/rhizo/changelog*
  na=$(cd "$da" && find . -type f | wc -l)
  nb=$(cd "$db" && find . -type f | wc -l)
  if (( na == 0 || nb == 0 )); then
    echo "[build-debs] payload extraction produced no files to compare ($a: $na file(s), $b: $nb file(s)) -- cannot judge byte-identity" >&2
    rm -rf "$da" "$db"
    exit 1
  fi
  ha=$(cd "$da" && find . -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
  hb=$(cd "$db" && find . -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
  rm -rf "$da" "$db"
  [[ -n "$ha" && "$ha" == "$hb" ]]
}

# stage the ref's payload into its worktree's var/share
stage_prev_payload() {
  local wt="$1" ref="$2"

  [[ -x "$wt/tools/fetch/build-inputs.sh" && -x "$wt/tools/build/payload.sh" ]] \
    || { echo "[build-debs] $ref predates tools/build/payload.sh" >&2; return 1; }

  if [[ -e "$ROOT/toolchain" && ! -e "$wt/toolchain" ]]; then
    cp -a --reflink=auto "$(readlink -f "$ROOT/toolchain")" "$wt/toolchain" \
      || { echo "[build-debs] could not copy toolchain into $wt" >&2; return 1; }
  fi
  if [[ -e "$ROOT/aosp-android16-qpr2" && ! -e "$wt/aosp-android16-qpr2" ]]; then
    ln -s "$(readlink -f "$ROOT/aosp-android16-qpr2")" "$wt/aosp-android16-qpr2" \
      || { echo "[build-debs] could not link aosp-android16-qpr2 into $wt" >&2; return 1; }
  fi

  ( cd "$wt" && tools/fetch/build-inputs.sh --accept-android-sdk-license ) \
    || { echo "[build-debs] $ref's build-inputs.sh failed in $wt" >&2; return 1; }
  ( cd "$wt" && tools/build/payload.sh ) \
    || { echo "[build-debs] $ref's payload.sh failed in $wt" >&2; return 1; }

  [[ -d "$wt/var/share" && ! -L "$wt/var/share" ]] \
    || { echo "[build-debs] $wt/var/share is not a real directory after building $ref's own payload" >&2; return 1; }
  local shared
  shared=$(comm -12 \
    <(find "$wt/var/share" -type f -printf '%i\n' 2>/dev/null | sort -u) \
    <(find "$ROOT/var/share" -type f -printf '%i\n' 2>/dev/null | sort -u))
  [[ -z "$shared" ]] \
    || { echo "[build-debs] $wt/var/share shares $(wc -l <<<"$shared") inode(s) with $ROOT/var/share -- $ref's payload is not its own" >&2; return 1; }
}

# build N-1 in a throwaway detached worktree
build_at() {
  local ref="$1" outdir="$2"

  local head_version; head_version=$(dpkg-parsechangelog -l"$ROOT/debian/changelog" -SVersion)

  mkdir -p "$ROOT/var" && AT_WORK=$(mktemp -d "$ROOT/var/build-debs-at.XXXXXX") \
    || { echo "[build-debs] could not make a work dir under $ROOT/var" >&2; exit 1; }
  trap cleanup_at EXIT

  AT_RHIZO_PREV="$AT_WORK/rhizo-prev"
  git -C "$ROOT" worktree add --detach "$AT_RHIZO_PREV" "$ref" \
    || { echo "[build-debs] could not create a worktree at $ref" >&2; exit 1; }

  local ref_version; ref_version=$(dpkg-parsechangelog -l"$AT_RHIZO_PREV/debian/changelog" -SVersion)
  [[ -n "$ref_version" ]] || { echo "[build-debs] no Version in $ref's debian/changelog" >&2; exit 1; }
  if [[ "$ref_version" == "$head_version" ]]; then
    echo "[build-debs] --at $ref builds version $ref_version, the same as HEAD's -- refusing" >&2
    exit 1
  fi

  stage_prev_payload "$AT_RHIZO_PREV" "$ref" || exit 1

  mkdir -p "$outdir"
  local rhizo_commit
  rhizo_commit=$(git -C "$ROOT" rev-parse "$ref")

  ( cd "$AT_RHIZO_PREV" && dpkg-buildpackage -us -uc -b >"$AT_WORK/rhizo-prev.build.log" 2>&1 ) \
    || { echo "[build-debs] $ref failed to build -- see $AT_WORK/rhizo-prev.build.log" >&2; exit 1; }

  local f
  for f in "$AT_WORK"/rhizo_*_amd64.deb; do
    [[ -f "$f" ]] || continue
    drop_other_versions "$outdir" "$(basename "$f")"
    mv -f "$f" "$outdir/"
    printf 'commit\t%s\n' "$rhizo_commit" > "$outdir/$(basename "$f").inputs"
    echo "[build-debs] $(basename "$f") $(sha256sum "$outdir/$(basename "$f")" | cut -c1-16) (from $ref @ ${rhizo_commit:0:12})"
  done
  local prev_deb new_deb
  prev_deb=$(ls -1 "$outdir"/rhizo_*_amd64.deb 2>/dev/null | tail -1)
  new_deb=$(ls -1 "$OUT"/rhizo_*_amd64.deb 2>/dev/null | tail -1)
  if [[ -z "$prev_deb" ]]; then
    echo "[build-debs] $ref's build produced no rhizo_*_amd64.deb in $outdir" >&2
    exit 1
  fi
  if [[ -z "$new_deb" ]]; then
    echo "[build-debs] no rhizo_*_amd64.deb in $OUT to compare $(basename "$prev_deb") against -- build N first with tools/build/packaging/deb/debs.sh" >&2
    exit 1
  elif payload_digest_matches "$prev_deb" "$new_deb"; then
    echo "[build-debs] $(basename "$prev_deb") ($ref) and $(basename "$new_deb") (HEAD) have byte-identical payloads once VERSION is excluded -- refusing" >&2
    exit 1
  fi
  ls -1 "$outdir"/*.deb
}

# test cleanup_at
selftest_at_cleanup() {
  local fail=0 out

  out=$(AT_RHIZO_PREV="" AT_WORK=""; cleanup_at 2>&1; echo "rc=$?")
  [[ "$out" == "rc=0" ]] || { echo "SELFTEST FAILED: cleanup_at with its --at globals empty did not cleanly no-op: $out"; fail=1; }

  out=$(unset AT_RHIZO_PREV AT_WORK 2>/dev/null; set -euo pipefail; cleanup_at 2>&1; echo "rc=$?")
  [[ "$out" == "rc=0" ]] || { echo "SELFTEST FAILED: cleanup_at crashed with its --at globals unset (the reported defect): $out"; fail=1; }

  local fixture_work fixture_wt
  fixture_work=$(mktemp -d "${TMPDIR:-/tmp}/build-debs-selftest.XXXXXX")
  fixture_wt="$fixture_work/rhizo-fixture"
  if git -C "$ROOT" worktree add --detach "$fixture_wt" HEAD >/dev/null 2>&1; then
    ( AT_RHIZO_PREV="$fixture_wt" AT_WORK="$fixture_work"; cleanup_at )
    [[ ! -e "$fixture_wt" ]] || { echo "SELFTEST FAILED: cleanup_at left the detached worktree behind: $fixture_wt"; fail=1; }
    [[ ! -e "$fixture_work" ]] || { echo "SELFTEST FAILED: cleanup_at left the scratch dir behind: $fixture_work"; fail=1; }
    git -C "$ROOT" worktree prune >/dev/null 2>&1
  else
    echo "SELFTEST SKIPPED: could not add a fixture worktree at HEAD to exercise cleanup_at's real removal"
  fi
  rm -rf "$fixture_work" 2>/dev/null

  if (( fail )); then echo "debs.sh selftest: FAILED"; return 1; fi
  echo "debs.sh selftest: ok"
}

if [[ "${1:-}" == --selftest ]]; then
  selftest_at_cleanup; exit $?
fi

if [[ "${1:-}" == --at ]]; then
  build_at "$AT_REF" "$AT_OUT"
  exit 0
fi

build_into "$ROOT" 'rhizo_*.deb' 1
ls -1 "$OUT"/*.deb
