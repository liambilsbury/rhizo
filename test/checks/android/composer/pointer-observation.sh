#!/bin/bash
# test the composer pointer observation code
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
# check the composer cursor position call sites
check_calls() {
  python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
code = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", " ", src, flags=re.S))
bad = []
sets = re.findall(r"\bSetObservedPointer\(\s*ds\.id\s*,\s*ls\.cursorPosX\s*,\s*ls\.cursorPosY\s*(,[^;]*)?\)\s*;", code)
if len(sets) != 1:
    bad.append("the cursorPosition observation is made %d times, not once" % len(sets))
elif not re.fullmatch(r",\s*spriteW\s*,\s*spriteH\s*", sets[0] or ""):
    bad.append("the cursorPosition observation carries no sprite extent: SetObservedPointer(ds.id, "
               "ls.cursorPosX, ls.cursorPosY%s)" % (sets[0] or ""))
else:
    m = re.search(r"int32_t spriteW = 0, spriteH = 0;(.*?)SetObservedPointer\(\s*ds\.id", code, re.S)
    if not m or not re.search(r"spriteW\s*=\s*\w+->second\.decoded\.width\s*;", m.group(1)) \
            or not re.search(r"spriteH\s*=\s*\w+->second\.decoded\.height\s*;", m.group(1)):
        bad.append("spriteW/spriteH are not the sprite buffer's decoded width and height")
def body_of(signature):
    m = re.search(signature, code)
    if not m:
        return ""
    depth, i = 0, m.end() - 1
    for j in range(i, len(code)):
        depth += code[j] == "{"
        depth -= code[j] == "}"
        if depth == 0:
            return code[i:j + 1]
    return ""
store = body_of(r"\bvoid SetObservedPointer\([^)]*\)\s*\{")
if not store:
    bad.append("no SetObservedPointer definition")
elif not re.search(r"\bobservedPointer_\[\s*displayId\s*\]\s*=\s*\{\s*x\s*,\s*y\s*,\s*w\s*,\s*h\s*\}\s*;", store):
    bad.append("SetObservedPointer does not store the observation whole: observedPointer_[displayId] = {x, y, w, h}")
body = body_of(r"\bbool TakeObservedPointer\([^)]*\)\s*\{")
if not body:
    bad.append("no TakeObservedPointer definition")
else:
    if not re.search(r"\bmit\s*=\s*androidPointer_\.find\(\s*displayId\s*\)", body):
        bad.append("TakeObservedPointer does not read the model from androidPointer_")
    if not re.search(r"\bhaveModel\s*=\s*mit\s*!=\s*androidPointer_\.end\(\)\s*;", body):
        bad.append("TakeObservedPointer's haveModel is not mit != androidPointer_.end()")
    for axis, pos, ext, part in (("x", "x", "w", "first"), ("y", "y", "h", "second")):
        if not re.search(r"\*%s\s*=\s*rhizo::ReconcileObservedAxis\(\s*haveModel\s*,\s*haveModel\s*\?\s*"
                         r"mit->second\.%s\s*:\s*0\s*,\s*o\.%s\s*,\s*o\.%s\s*\)\s*;" % (axis, part, pos, ext), body):
            bad.append("TakeObservedPointer's %s is not ReconcileObservedAxis(haveModel, haveModel ? "
                       "mit->second.%s : 0, o.%s, o.%s)" % (axis, part, pos, ext))
for b in bad:
    print("FAIL: %s" % b)
if bad:
    sys.exit(1)
print("ok   the composer bounds Android's pointer by the observed sprite, from its own model")
PY
}

if [[ "${1:-}" == --selftest ]]; then
  real=src/android/hal/graphics-composer/src/composer.cpp
  check_calls "$real" >"$tmp/out" || { cat "$tmp/out"; echo "check-pointer-observation --selftest: FAIL -- the real composer fails"; exit 1; }
  st=0
  while IFS='|' read -r label from to; do
    python3 - "$real" "$tmp/mutant.cpp" "$from" "$to" <<'PY' || { echo "FAIL: mutant '$label' did not apply"; st=1; continue; }
import sys
src = open(sys.argv[1]).read()
if src.count(sys.argv[3]) != 1:
    sys.exit(1)
open(sys.argv[2], "w").write(src.replace(sys.argv[3], sys.argv[4]))
PY
    if check_calls "$tmp/mutant.cpp" >"$tmp/out"; then
      echo "FAIL: mutant '$label' passed"; st=1
    else
      echo "ok   mutant '$label' caught: $(grep -m1 FAIL "$tmp/out")"
    fi
  done <<'MUT'
no model on x|ReconcileObservedAxis(haveModel, haveModel ? mit->second.first|ReconcileObservedAxis(false, haveModel ? mit->second.first
extent dropped at the store|observedPointer_[displayId] = {x, y, w, h};|observedPointer_[displayId] = {x, y, 0, 0};
extent 0,0 at the call site|ls.cursorPosX, ls.cursorPosY, spriteW, spriteH)|ls.cursorPosX, ls.cursorPosY, 0, 0)
o.h on x|o.x, o.w)|o.x, o.h)
MUT
  [[ $st == 0 ]] && echo "check-pointer-observation --selftest: OK (four mutants caught, the real composer clean)" \
    || echo "check-pointer-observation --selftest: FAIL"
  exit $st
fi

composer=${1:-src/android/hal/graphics-composer/src/composer.cpp}
rc=0
if ! g++ -std=c++17 -Wall -Werror -I src/android/hal/graphics-composer/src/input \
    -o "$tmp/pointer_observation_test" src/android/hal/graphics-composer/tests/pointer_observation_test.cpp; then
  echo "FAIL: pointer_observation_test.cpp did not build"
  exit 1
fi
"$tmp/pointer_observation_test" || rc=1
check_calls "$composer" || rc=1
exit $rc
