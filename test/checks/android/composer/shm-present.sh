#!/bin/bash
# test the composer's wl_shm present helpers
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." || exit 1
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
composer=src/android/hal/graphics-composer/src/composer.cpp
backend=src/android/hal/graphics-composer/src/wayland/wayland_backend.cpp
cat >"$tmp/memfd_branches.py" <<'PY'
import re, sys


def strip(src):
    """drop the comments from C++ source"""
    return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", " ", src, flags=re.S))


def body_of(code, signature):
    """return the braced body after the first match of signature"""
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


def check(composer, backend):
    """return what the composer's and the backend's memfd branches get wrong"""
    comp, back = strip(composer), strip(backend)
    bad = []
    cand = body_of(comp, r"\bint64_t DeviceCandidate\(DisplayState& ds\)\s*\{")
    if not cand:
        bad.append("no DeviceCandidate definition")
    else:
        if not re.search(r"if\s*\(\s*rhizo::IsShmemFile\(\s*sit->second\.fd\s*\)\s*\)\s*\{\s*"
                         r"if\s*\(\s*!rhizo::ShmemSealedAgainstShrink\(\s*sit->second\.fd\s*\)\s*\)\s*return\s+refuse\(\"shm-unsealed\"\);\s*"
                         r"if\s*\(\s*!wayland_\.AcceptsShmFormat\(\s*fmt\s*\)\s*\)\s*return\s+refuse\(\"shm-format\"\);\s*\}"
                         r"\s*else\s+if\s*\(\s*!wayland_\.AcceptsBuffer\(\s*fmt\s*,\s*d\.modifier\s*\)\s*\)\s*\{\s*"
                         r"return\s+refuse\(\"modifier\"\);\s*\}", cand):
            bad.append("DeviceCandidate does not refuse an unsealed shmem layer (shm-unsealed), judge a sealed one by "
                       "AcceptsShmFormat (shm-format) and every other layer by AcceptsBuffer (modifier)")
        if cand.count("AcceptsBuffer(") != 1:
            bad.append("DeviceCandidate calls AcceptsBuffer %d times, not once in the dmabuf branch"
                       % cand.count("AcceptsBuffer("))
    accepts = body_of(back, r"\bbool WaylandBackend::AcceptsShmFormat\(uint32_t drmFormat\) const\s*\{")
    if not re.search(r"return\s+impl_->shm\s*!=\s*nullptr\s*&&\s*ShmPresentable\(\s*impl_->shmFormats\s*,\s*drmFormat\s*\)\s*;",
                     accepts):
        bad.append("AcceptsShmFormat is not impl_->shm != nullptr && ShmPresentable(impl_->shmFormats, drmFormat)")
    present = body_of(back, r"\bbool WaylandBackend::PresentFrame\(int64_t displayId, const WaylandFrame& frame\)\s*\{")
    if not re.search(r"const\s+int\s+seals\s*=\s*fcntl\(\s*frame\.dmabufFd\s*,\s*F_GET_SEALS\s*\)\s*;\s*"
                     r"const\s+bool\s+shmem\s*=\s*seals\s*>=\s*0\s*;", present) or \
            not re.search(r"if\s*\(\s*shmem\s*\)\s*\{\s*attach\s*=\s*ShmFrameBufferLocked\([^;]*\bseals\s*\)", present):
        bad.append("PresentFrame does not tell shmem by its F_GET_SEALS seals and send it, with them, to ShmFrameBufferLocked")
    if not re.search(r"if\s*\(\s*shmem\s*&&\s*!SealsHoldSize\(\s*seals\s*\)\s*\)\s*\{\s*impl->lastPresentDropped\s*=\s*true\s*;",
                     present):
        bad.append("PresentFrame does not drop a shmem frame whose seals do not hold its size")
    seal_at, size_at = present.find("F_GET_SEALS"), present.find("fstat(frame.dmabufFd")
    if seal_at < 0 or size_at < 0 or seal_at > size_at:
        bad.append("PresentFrame reads the frame's size before its seals")
    shm = body_of(back, r"\bwl_buffer\* ShmFrameBufferLocked\([^)]*\)\s*\{")
    if not re.search(r"if\s*\(\s*!ShmCopyFits\(\s*frame\.width\s*,\s*frame\.height\s*,\s*frame\.strideBytes\s*,\s*"
                     r"st\.st_size\s*\)\s*\)\s*\{", shm) or shm.find("ShmCopyFits(") > shm.find("mmap(nullptr, frameSize"):
        bad.append("ShmFrameBufferLocked does not refuse, before it maps the frame, a copy whose stride or file is short")
    if not re.search(r"const\s+uint32_t\s+shmFormat\s*=\s*ShmFormatOf\(\s*frame\.drmFormat\s*\)\s*;\s*"
                     r"if\s*\(\s*impl->shmFormats\.count\(\s*shmFormat\s*\)\s*&&\s*ShmSealsAllowZeroCopy\(\s*seals\s*\)\s*&&\s*"
                     r"ShmZeroCopyFits\(\s*frame\.drmFormat\s*,\s*"
                     r"frame\.width\s*,\s*frame\.height\s*,\s*frame\.strideBytes\s*,\s*st\.st_size\s*\)\s*\)", shm) or \
            not re.search(r"const\s+uint32_t\s+to\s*=\s*ShmCopyFormat\(\s*frame\.drmFormat\s*\)\s*;", shm):
        bad.append("ShmFrameBufferLocked does not decide zero-copy by the advertised ShmFormatOf with ShmSealsAllowZeroCopy "
                   "and ShmZeroCopyFits, and the copy by ShmCopyFormat, the two halves of ShmPresentable")
    paths = body_of(back, r"\bconst char\* WaylandBackend::PresentPaths\(\) const\s*\{")
    if not re.search(r"return\s+PresentPathsName\(\s*impl_->dmabuf\s*!=\s*nullptr\s*,\s*impl_->shm\s*!=\s*nullptr\s*\)\s*;",
                     paths):
        bad.append("PresentPaths does not name the bound globals through PresentPathsName(impl_->dmabuf != nullptr, "
                   "impl_->shm != nullptr)")
    if not re.search(r'klogf\(\s*"EnsureWaylandConnected: Wayland connection established, presenting via %s"\s*,\s*'
                     r'wayland_\.PresentPaths\(\)\s*\)', comp) or "presenting via zwp_linux_dmabuf_v1" in comp:
        bad.append("the composer's connect line does not name the present paths the backend bound (wayland_.PresentPaths())")
    return bad


MUTANTS = [
    ("memfd judged by the dmabuf table", "composer",
     'if (!wayland_.AcceptsShmFormat(fmt)) return refuse("shm-format");',
     'if (!wayland_.AcceptsBuffer(fmt, d.modifier)) return refuse("shm-format");'),
    ("no shmem test", "composer", "if (rhizo::IsShmemFile(sit->second.fd)) {", "if (false) {"),
    ("unsealed shmem made DEVICE", "composer",
     '      if (!rhizo::ShmemSealedAgainstShrink(sit->second.fd)) return refuse("shm-unsealed");\n', ""),
    ("memfd also needs the dmabuf table", "composer",
     '    } else if (!wayland_.AcceptsBuffer(fmt, d.modifier)) {\n      return refuse("modifier");\n    }',
     '    }\n    if (!wayland_.AcceptsBuffer(fmt, d.modifier)) {\n      return refuse("modifier");\n    }'),
    ("shm query ignores the wl_shm bind", "backend",
     "return impl_->shm != nullptr && ShmPresentable(", "return ShmPresentable("),
    ("present never tells shmem", "backend", "const bool shmem = seals >= 0;", "const bool shmem = false;"),
    ("backend presents an unsealed frame", "backend", "if (shmem && !SealsHoldSize(seals)) {", "if (false) {"),
    ("size read before the seals", "backend", "  const int seals = fcntl(frame.dmabufFd, F_GET_SEALS);",
     "  struct stat early{};\n  fstat(frame.dmabufFd, &early);\n  const int seals = fcntl(frame.dmabufFd, F_GET_SEALS);"),
    ("zero-copy under a write seal", "backend", "ShmSealsAllowZeroCopy(seals) &&", ""),
    ("zero-copy past the stride or file", "backend",
     "ShmSealsAllowZeroCopy(seals) &&\n      ShmZeroCopyFits(frame.drmFormat, frame.width, frame.height, frame.strideBytes, st.st_size)",
     "ShmSealsAllowZeroCopy(seals)"),
    ("copy past the file", "backend",
     "if (!ShmCopyFits(frame.width, frame.height, frame.strideBytes, st.st_size)) {", "if (false) {"),
    ("connect line says dmabuf whatever was bound", "composer",
     'klogf("EnsureWaylandConnected: Wayland connection established, presenting via %s", wayland_.PresentPaths());',
     'klog("EnsureWaylandConnected: Wayland connection established, presenting via zwp_linux_dmabuf_v1");'),
    ("present paths ignore the wl_shm bind", "backend",
     "return PresentPathsName(impl_->dmabuf != nullptr, impl_->shm != nullptr);",
     "return PresentPathsName(impl_->dmabuf != nullptr, false);"),
]


def selftest(composer, backend):
    """run the check on the real sources and on each mutant"""
    real = {"composer": open(composer).read(), "backend": open(backend).read()}
    st = 0
    got = check(real["composer"], real["backend"])
    if got:
        print("FAIL: the real sources fail: %s" % got)
        st = 1
    for label, which, old, new in MUTANTS:
        if real[which].count(old) != 1:
            print("FAIL: mutant '%s' did not apply" % label)
            st = 1
            continue
        src = dict(real)
        src[which] = real[which].replace(old, new)
        found = check(src["composer"], src["backend"])
        if found:
            print("ok   mutant '%s' caught: %s" % (label, found[0]))
        else:
            print("FAIL: mutant '%s' passed" % label)
            st = 1
    print("check-shm-present --selftest: %s" % ("OK (%d mutants caught, the real sources clean)" % len(MUTANTS) if st == 0 else "FAIL"))
    return st


def main():
    """check the given composer and backend, or run the selftest"""
    if sys.argv[1] == "--selftest":
        return selftest(sys.argv[2], sys.argv[3])
    bad = check(open(sys.argv[1]).read(), open(sys.argv[2]).read())
    for b in bad:
        print("FAIL: " + b)
    if not bad:
        print("ok   a shmem layer is DEVICE only sealed and when wl_shm can present its format, and a shmem frame goes to wl_shm only sealed, zero-copy only when it fits")
    return 1 if bad else 0


sys.exit(main())
PY

if [[ "${1:-}" == --selftest ]]; then
  python3 "$tmp/memfd_branches.py" --selftest "$composer" "$backend"
  exit $?
fi

rc=0
g++ -std=c++17 -Wall -Werror -I src/android/hal/graphics-composer/src/wayland -I src/android/hal/common/include -o "$tmp/t" \
  src/android/hal/graphics-composer/tests/shm_present_test.cpp || { echo "FAIL: shm_present_test.cpp did not build"; exit 1; }
"$tmp/t" || rc=1
python3 "$tmp/memfd_branches.py" "$composer" "$backend" || rc=1
exit $rc
