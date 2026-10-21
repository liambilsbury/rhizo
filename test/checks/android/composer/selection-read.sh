#!/bin/bash
# test the composer selection read
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
backend=${1:-src/android/hal/graphics-composer/src/wayland/wayland_backend.cpp}
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
rc=0
if ! g++ -std=c++17 -Wall -Werror -pthread -I src/android/hal/graphics-composer/src/wayland \
    -o "$tmp/selection_read_test" src/android/hal/graphics-composer/tests/selection_read_test.cpp; then
  echo "FAIL: selection_read_test.cpp did not build"
  exit 1
fi
"$tmp/selection_read_test" || rc=1
python3 - "$backend" <<'PY' || rc=1
import re, sys
src = open(sys.argv[1]).read()
bad = []
m = re.search(r"\nvoid OnDataDeviceSelection\(void\* data, wl_data_device\*, wl_data_offer\* id\) \{\n(.*?)\n\}\n", src, re.S)
if not m:
    print("FAIL: no OnDataDeviceSelection definition in %s" % sys.argv[1])
    sys.exit(1)
body = m.group(1)
lines = [l.strip() for l in body.split("\n") if l.strip() and not l.strip().startswith("//")]
if lines[:2] != ["auto* impl = static_cast<WaylandBackend::Impl*>(data);",
                 "const uint64_t seq = impl->selections.Begin();"]:
    bad.append("OnDataDeviceSelection does not begin its event first thing: %r" % lines[:2])
if src.count("selections.Begin()") != 1:
    bad.append("selections.Begin() appears %d times in the file, not once" % src.count("selections.Begin()"))
calls = re.findall(r"rhizo_selection::ReadInThread\(\s*([^,]+),\s*([^,]+),\s*([^,]+),\s*([^,]+),", body)
if calls != [("impl->selections", "impl->mutex_", "pipeFds[0]", "seq")]:
    bad.append("ReadInThread is not called once with (impl->selections, impl->mutex_, pipeFds[0], seq): %r" % calls)
cap = body.find("if (!composerClipboardEnabled())")
start = body.find("rhizo_selection::ReadInThread(")
if cap < 0 or start < 0:
    bad.append("OnDataDeviceSelection has no capability check or no ReadInThread call to hold")
    cap = start = len(body)
after = body[cap:]
after = after[after.find("}") + 1:]
pre_thread = after[:max(after.find("rhizo_selection::ReadInThread("), 0)]
for ret in re.finditer(r"\n([^\n]*)\n\s*return;", pre_thread):
    if "PushUncarriedSelection(impl);" not in ret.group(1):
        bad.append("an early return past the capability check reports nothing: %r" % ret.group(1).strip())
done = body[start:]
push = re.findall(r"if \(verdict == rhizo_selection::Verdict::kReport\) \{\s*impl->pendingSelections\.push_back\(\{mime, std::move\(bytes\), true\}\);\s*\} else if \(verdict == rhizo_selection::Verdict::kUncarried\) \{\s*PushUncarriedSelection\(impl\);\s*\}", done)
if len(push) != 1:
    bad.append("the ReadDone does not push the bytes on kReport alone and uncarried on kUncarried")
if src.count("pendingSelections.push_back(") != 2:
    bad.append("pendingSelections.push_back appears %d times, not twice (the kReport push, PushUncarriedSelection)"
               % src.count("pendingSelections.push_back("))
for b in bad:
    print("FAIL: " + b)
if not bad:
    print("ok   OnDataDeviceSelection begins its event first, reads it through ReadInThread with that seq under impl->mutex_, reports every early return uncarried, and pushes the bytes on kReport alone")
sys.exit(1 if bad else 0)
PY
exit "$rc"
