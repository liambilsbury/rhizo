#!/bin/bash
# test the debian/rules build targets
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEBIAN="$(cd "$HERE/../../debian" && pwd)"
BUILD_DEBS="$HERE/../../tools/build/packaging/deb/debs.sh"

# check the order of debs.sh stamping steps
check_deb_stamp_wiring() {
  local filtered pre_line build_line tree_line stamp_line
  filtered=$(grep -vE '^[[:space:]]*#' "$1")
  pre_line=$(grep -n 'pre_digest=.*deb-digest' <<<"$filtered" | head -1 | cut -d: -f1)
  build_line=$(grep -n 'dpkg-buildpackage' <<<"$filtered" | head -1 | cut -d: -f1)
  tree_line=$(grep -nF 'package-tree.py" "$OUT/$(basename "$f")" "$ROOT"' <<<"$filtered" | head -1 | cut -d: -f1)
  stamp_line=$(grep -nF 'deb-stamp "$OUT/$(basename "$f")" "$pre_digest"' <<<"$filtered" | head -1 | cut -d: -f1)
  [[ -n "$pre_line" && -n "$build_line" && -n "$tree_line" && -n "$stamp_line" ]] || return 1
  (( pre_line < build_line && build_line < tree_line && tree_line < stamp_line ))
}

# print each altered stand-in file
trial() {
  local src="$1" tmp f
  tmp=$(mktemp -d)
  cp -a "$src" "$tmp/debian"
  rm -rf "$tmp/debian/.debhelper" "$tmp/debian/rhizo" "$tmp/debian/files" "$tmp/debian/debhelper-build-stamp"
  mkdir -p "$tmp/aosp-android16-qpr2/external/lib/build-aux" "$tmp/toolchain/src" "$tmp/mesa-src/bin/__pycache__"
  printf '#! /bin/sh\n# Attempt to guess a canonical system name.\ntimestamp='"'"'2012-02-10'"'"'\necho old\n' \
    > "$tmp/aosp-android16-qpr2/external/lib/build-aux/config.guess"
  printf '#! /bin/sh\n# Configuration validation subroutine script.\ntimestamp='"'"'2012-02-10'"'"'\necho old\n' \
    > "$tmp/toolchain/src/config.sub"
  echo keep > "$tmp/aosp-android16-qpr2/external/lib/fix.orig"
  echo keep > "$tmp/aosp-android16-qpr2/external/lib/TAGS"
  echo keep > "$tmp/toolchain/src/table.bak"
  echo keep > "$tmp/mesa-src/bin/__pycache__/gen.cpython-312.pyc"
  (cd "$tmp" && find aosp-android16-qpr2 toolchain mesa-src -type f -exec sha256sum {} + | sort -k2) > "$tmp/before.sha"
  (cd "$tmp" && debian/rules clean && debian/rules build) > "$tmp/build.log" 2>&1
  (cd "$tmp" && find aosp-android16-qpr2 toolchain mesa-src -type f -exec sha256sum {} + | sort -k2) > "$tmp/after.sha"
  grep -q 'override_dh_auto_build' "$tmp/build.log" \
    || echo "the build never reached override_dh_auto_build: $(tail -3 "$tmp/build.log" | tr '\n' ' ')"
  while read -r _ f; do
    if ! grep -q "  $f\$" "$tmp/after.sha"; then echo "$f was removed"
    elif ! grep -qxF "$(grep "  $f\$" "$tmp/before.sha")" "$tmp/after.sha"; then echo "$f was rewritten"; fi
  done < "$tmp/before.sha"
  rm -rf "$tmp"
}

if [[ "${1:-}" == --selftest ]]; then
  work=$(mktemp -d)
  cp -a "$DEBIAN" "$work/debian"
  sed -i '/^override_dh_update_autotools_config:/,/^$/d;/^override_dh_autoreconf:/,/^$/d;/^override_dh_clean:/,/^$/d' "$work/debian/rules"
  if cmp -s "$DEBIAN/rules" "$work/debian/rules"; then
    echo "FAIL selftest: debian/rules carries no scope overrides to remove"; rm -rf "$work"; exit 1
  fi
  out=$(trial "$work/debian")
  rm -rf "$work"
  for want in 'config.guess was rewritten' 'config.sub was rewritten' 'fix.orig was removed' 'TAGS was removed' \
              'table.bak was removed' 'gen.cpython-312.pyc was removed'; do
    grep -q "$want" <<<"$out" || { echo "FAIL selftest: without the overrides, '$want' was not flagged: $out"; exit 1; }
  done
  out=$(trial "$DEBIAN")
  [[ -z "$out" ]] || { echo "FAIL selftest: the real rules were flagged: $out"; exit 1; }

  work2=$(mktemp -d)
  cp "$BUILD_DEBS" "$work2/debs.sh"
  sed -i 's/deb-stamp "\$OUT\/\$(basename "\$f")" "\$pre_digest"/deb-stamp "$OUT\/$(basename "$f")"/' \
    "$work2/debs.sh"
  if cmp -s "$BUILD_DEBS" "$work2/debs.sh"; then
    echo "FAIL selftest: dropping \$pre_digest from debs.sh did not change the file"; rm -rf "$work2"; exit 1
  fi
  if check_deb_stamp_wiring "$work2/debs.sh"; then
    echo "FAIL selftest: dropping \$pre_digest from debs.sh's deb-stamp call was not caught"
    rm -rf "$work2"; exit 1
  fi
  rm -rf "$work2"
  check_deb_stamp_wiring "$BUILD_DEBS" \
    || { echo "FAIL selftest: the real debs.sh does not pass \$pre_digest to deb-stamp"; exit 1; }

  work3=$(mktemp -d)
  cp "$BUILD_DEBS" "$work3/debs.sh"
  python3 - "$work3/debs.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
start = next(i for i, l in enumerate(lines) if l.strip() == 'if [[ "$stamp" == 1 ]]; then')
end = next(i for i in range(start, len(lines)) if lines[i].strip() == "fi")
body = lines[start + 1:end]
del lines[start:end + 1]
loop_i = next(i for i, l in enumerate(lines) if l.strip().startswith('for f in "$parent"/$glob'))
lines[loop_i:loop_i] = body
open(p, "w").write("\n".join(lines))
PY
  if cmp -s "$BUILD_DEBS" "$work3/debs.sh"; then
    echo "FAIL selftest (pre-digest-taken-after-build): the mutation did not change the file"; rm -rf "$work3"; exit 1
  fi
  if check_deb_stamp_wiring "$work3/debs.sh"; then
    echo "FAIL selftest (pre-digest-taken-after-build): moving the digest after dpkg-buildpackage was not caught"
    rm -rf "$work3"; exit 1
  fi
  rm -rf "$work3"

  work4=$(mktemp -d)
  cp "$BUILD_DEBS" "$work4/debs.sh"
  python3 - "$work4/debs.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
old = '      python3 -B "$ROOT/tools/build/stamps.py" deb-stamp "$OUT/$(basename "$f")" "$pre_digest"\n'
new = ('      # deb-stamp "$OUT/$(basename "$f")" "$pre_digest"\n'
       '      python3 -B "$ROOT/tools/build/stamps.py" deb-stamp "$OUT/$(basename "$f")"\n')
assert old in t, old
open(p, "w").write(t.replace(old, new, 1))
PY
  if cmp -s "$BUILD_DEBS" "$work4/debs.sh"; then
    echo "FAIL selftest (call-dropped-comment-kept): the mutation did not change the file"; rm -rf "$work4"; exit 1
  fi
  if check_deb_stamp_wiring "$work4/debs.sh"; then
    echo "FAIL selftest (call-dropped-comment-kept): dropping \$pre_digest while a comment kept the old text was not caught"
    rm -rf "$work4"; exit 1
  fi
  rm -rf "$work4"

  work5=$(mktemp -d)
  cp "$BUILD_DEBS" "$work5/debs.sh"
  python3 - "$work5/debs.sh" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
old = '      python3 -B "$ROOT/test/checks/lib/package-tree.py" "$OUT/$(basename "$f")" "$ROOT"\n'
assert old in t, old
open(p, "w").write(t.replace(old, "", 1))
PY
  if cmp -s "$BUILD_DEBS" "$work5/debs.sh"; then
    echo "FAIL selftest (check-package-tree-dropped): the mutation did not change the file"; rm -rf "$work5"; exit 1
  fi
  if check_deb_stamp_wiring "$work5/debs.sh"; then
    echo "FAIL selftest (check-package-tree-dropped): dropping the pre-stamp package-tree.py call was not caught"
    rm -rf "$work5"; exit 1
  fi
  rm -rf "$work5"

  echo "check-deb-build-scope selftest: both trials passed, and the pre_digest wiring check catches a dropped argument, a digest moved after the build, a comment masking a dropped argument, and a dropped package-tree.py call"
  exit 0
fi

out=$(trial "$DEBIAN")
if [[ -n "$out" ]]; then
  while IFS= read -r l; do echo "FAIL: package build scope: $l"; done <<<"$out"
  exit 1
fi
if ! check_deb_stamp_wiring "$BUILD_DEBS"; then
  echo "FAIL: debs.sh no longer passes the pre-build digest to deb-stamp's [pre] argument"
  exit 1
fi
echo "the package build leaves the trees beside debian/ untouched, and deb-stamp gets its pre-build digest"
