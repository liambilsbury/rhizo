#!/bin/bash
# var/debs/rhizo_<version>_amd64.deb build with dpkg-buildpackage
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
    echo "deleted $(basename "$old") in $dir"
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
  [[ -n "$AT_REF" ]] || { echo "--at has no REF" >&2; exit 2; }
  [[ "${3:-}" == --out && -n "${4:-}" ]] || { echo "--at REF has no --out DIR" >&2; exit 2; }
  AT_OUT="$4"
fi

# build a source tree's packages into var/debs
build_into() {
  local src="$1" glob="$2" stamp="${3:-0}" parent f pre_digest=""
  parent=$(dirname "$src")
  if [[ "$stamp" == 1 ]]; then
    pre_digest=$(python3 -B "$ROOT/tools/build/stamps.py" deb-digest) \
      || { echo "stamps.py deb-digest failed" >&2; exit 1; }
  fi
  ( cd "$src" && dpkg-buildpackage -us -uc -b >"$OUT/$(basename "$src").build.log" 2>&1 ) \
    || { echo "dpkg-buildpackage failed in $src (log $OUT/$(basename "$src").build.log)" >&2; exit 1; }
  for f in "$parent"/$glob; do
    [[ -f "$f" ]] || continue
    drop_other_versions "$OUT" "$(basename "$f")"
    mv -f "$f" "$OUT/"
    echo "wrote $(basename "$f") sha256=$(sha256sum "$OUT/$(basename "$f")" | cut -c1-16)"
    if [[ "$stamp" == 1 ]]; then
      [[ ! -e "$ROOT/test/checks/lib/package-tree.py" ]] \
        || python3 -B "$ROOT/test/checks/lib/package-tree.py" "$OUT/$(basename "$f")" "$ROOT"
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
    echo "dpkg-deb --fsys-tarfile extracted files=$na from $a and files=$nb from $b" >&2
    rm -rf "$da" "$db"
    exit 1
  fi
  ha=$(cd "$da" && find . -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
  hb=$(cd "$db" && find . -type f -exec sha256sum {} + 2>/dev/null | sort | sha256sum | cut -d' ' -f1)
  rm -rf "$da" "$db"
  [[ -n "$ha" && "$ha" == "$hb" ]]
}

# build the payload of ref in the var/share of worktree wt
stage_prev_payload() {
  local wt="$1" ref="$2"

  [[ -x "$wt/tools/fetch/build-inputs.sh" && -x "$wt/tools/build/payload.sh" ]] \
    || { echo "no tools/build/payload.sh at $ref" >&2; return 1; }

  if [[ -e "$ROOT/toolchain" && ! -e "$wt/toolchain" ]]; then
    cp -a --reflink=auto "$(readlink -f "$ROOT/toolchain")" "$wt/toolchain" \
      || { echo "failed to copy toolchain to $wt" >&2; return 1; }
  fi
  if [[ -e "$ROOT/aosp-android16-qpr2" && ! -e "$wt/aosp-android16-qpr2" ]]; then
    ln -s "$(readlink -f "$ROOT/aosp-android16-qpr2")" "$wt/aosp-android16-qpr2" \
      || { echo "failed to link aosp-android16-qpr2 in $wt" >&2; return 1; }
  fi

  ( cd "$wt" && tools/fetch/build-inputs.sh --accept-android-sdk-license ) \
    || { echo "tools/fetch/build-inputs.sh of $ref failed in $wt" >&2; return 1; }
  ( cd "$wt" && tools/build/payload.sh ) \
    || { echo "tools/build/payload.sh of $ref failed in $wt" >&2; return 1; }

  [[ -d "$wt/var/share" && ! -L "$wt/var/share" ]] \
    || { echo "$wt/var/share is not a directory" >&2; return 1; }
  local shared
  shared=$(comm -12 \
    <(find "$wt/var/share" -type f -printf '%i\n' 2>/dev/null | sort -u) \
    <(find "$ROOT/var/share" -type f -printf '%i\n' 2>/dev/null | sort -u))
  [[ -z "$shared" ]] \
    || { echo "$wt/var/share has $(wc -l <<<"$shared") inodes of $ROOT/var/share" >&2; return 1; }
}

# build the packages of ref in a detached worktree into outdir
build_at() {
  local ref="$1" outdir="$2"

  local head_version; head_version=$(dpkg-parsechangelog -l"$ROOT/debian/changelog" -SVersion)

  mkdir -p "$ROOT/var" && AT_WORK=$(mktemp -d "$ROOT/var/build-debs-at.XXXXXX") \
    || { echo "mktemp -d $ROOT/var/build-debs-at.XXXXXX failed" >&2; exit 1; }
  trap cleanup_at EXIT

  AT_RHIZO_PREV="$AT_WORK/rhizo-prev"
  git -C "$ROOT" worktree add --detach "$AT_RHIZO_PREV" "$ref" \
    || { echo "git worktree add --detach $AT_RHIZO_PREV $ref failed" >&2; exit 1; }

  local ref_version; ref_version=$(dpkg-parsechangelog -l"$AT_RHIZO_PREV/debian/changelog" -SVersion)
  [[ -n "$ref_version" ]] || { echo "no Version in debian/changelog of $ref" >&2; exit 1; }
  if [[ "$ref_version" == "$head_version" ]]; then
    echo "--at $ref Version $ref_version == HEAD Version" >&2
    exit 1
  fi

  stage_prev_payload "$AT_RHIZO_PREV" "$ref" || exit 1

  mkdir -p "$outdir"
  local rhizo_commit
  rhizo_commit=$(git -C "$ROOT" rev-parse "$ref")

  ( cd "$AT_RHIZO_PREV" && dpkg-buildpackage -us -uc -b >"$AT_WORK/rhizo-prev.build.log" 2>&1 ) \
    || { echo "dpkg-buildpackage failed for $ref (log $AT_WORK/rhizo-prev.build.log)" >&2; exit 1; }

  local f
  for f in "$AT_WORK"/rhizo_*_amd64.deb; do
    [[ -f "$f" ]] || continue
    drop_other_versions "$outdir" "$(basename "$f")"
    mv -f "$f" "$outdir/"
    printf 'commit\t%s\n' "$rhizo_commit" > "$outdir/$(basename "$f").inputs"
    echo "wrote $(basename "$f") sha256=$(sha256sum "$outdir/$(basename "$f")" | cut -c1-16) ref=$ref commit=${rhizo_commit:0:12}"
  done
  local prev_deb new_deb
  prev_deb=$(ls -1 "$outdir"/rhizo_*_amd64.deb 2>/dev/null | tail -1)
  new_deb=$(ls -1 "$OUT"/rhizo_*_amd64.deb 2>/dev/null | tail -1)
  if [[ -z "$prev_deb" ]]; then
    echo "no rhizo_*_amd64.deb in $outdir for $ref" >&2
    exit 1
  fi
  if [[ -z "$new_deb" ]]; then
    echo "no rhizo_*_amd64.deb in $OUT" >&2
    exit 1
  elif payload_digest_matches "$prev_deb" "$new_deb"; then
    echo "$(basename "$prev_deb") ($ref) and $(basename "$new_deb") (HEAD) have equal payloads without usr/lib/rhizo/VERSION" >&2
    exit 1
  fi
  ls -1 "$outdir"/*.deb
}

# test cleanup_at
selftest_at_cleanup() {
  local fail=0 out

  out=$(AT_RHIZO_PREV="" AT_WORK=""; cleanup_at 2>&1; echo "rc=$?")
  [[ "$out" == "rc=0" ]] || { echo "FAIL cleanup_at with AT_RHIZO_PREV= AT_WORK= prints rc=0 ($out)"; fail=1; }

  out=$(unset AT_RHIZO_PREV AT_WORK 2>/dev/null; set -euo pipefail; cleanup_at 2>&1; echo "rc=$?")
  [[ "$out" == "rc=0" ]] || { echo "FAIL cleanup_at with AT_RHIZO_PREV and AT_WORK unset under set -u prints rc=0 ($out)"; fail=1; }

  local fixture_work fixture_wt
  fixture_work=$(mktemp -d "${TMPDIR:-/tmp}/build-debs-selftest.XXXXXX")
  fixture_wt="$fixture_work/rhizo-fixture"
  if git -C "$ROOT" worktree add --detach "$fixture_wt" HEAD >/dev/null 2>&1; then
    ( AT_RHIZO_PREV="$fixture_wt" AT_WORK="$fixture_work"; cleanup_at )
    [[ ! -e "$fixture_wt" ]] || { echo "FAIL cleanup_at deletes the worktree $fixture_wt"; fail=1; }
    [[ ! -e "$fixture_work" ]] || { echo "FAIL cleanup_at deletes $fixture_work"; fail=1; }
    git -C "$ROOT" worktree prune >/dev/null 2>&1
  else
    echo "SKIP cleanup_at worktree removal after git worktree add failed"
  fi
  rm -rf "$fixture_work" 2>/dev/null

  if (( fail )); then echo "FAIL debs.sh --selftest"; return 1; fi
  echo "ok debs.sh --selftest"
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
