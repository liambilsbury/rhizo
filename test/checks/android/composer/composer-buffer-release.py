#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMPOSER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")
BACKEND = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "wayland", "wayland_backend.cpp")

EDGE_KLOGS = (
    ("EDGE-ADD", "add port=%d claimed=%d"),
    ("EDGE-CONNECTED", "hotplug CONNECTED sent"),
    ("EDGE-DISCONNECT-FIRST", "DISCONNECTED sent attempt=1"),
    ("EDGE-DISCONNECT-RETRY", "DISCONNECTED sent attempt=%d"),
    ("EDGE-DESTROYLAYER", "sf destroyLayer %lld while removing"),
    ("EDGE-VSYNC", "sf setVsyncEnabled %d while removing"),
    ("EDGE-POWERMODE", "sf setPowerMode %d while removing"),
    ("EDGE-OTHER-CALL", "call fn=%s while removing"),
    ("EDGE-RELEASED", "sf-released after %lldms"),
    ("EDGE-ORPHANED", "SF-ORPHANED port=%d withheld"),
    ("EDGE-FREED", "freed ct=%zu layers=%zu layer_slots=%zu"),
)

AUDIT_FIELDS = ("live=", "awaiting_sf=", "orphaned=", "held_fds_live=")


def strip_comments(text):
    """drop comments from C++ source text"""
    out = []
    i, n = 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            i = text.find("\n", i)
            if i == -1:
                i = n
            continue
        if two == "/*":
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        c = text[i]
        if c in ('"', "'"):
            out.append(c)
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == "\\" and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                done = text[i] == c
                i += 1
                if done:
                    break
            continue
        out.append(c)
        i += 1
    return "".join(out)


def check(text, backend):
    """return the list of failed rules"""
    code = strip_comments(text)
    back = strip_comments(backend)
    f = []

    for struct in ("HeldBuffer", "LayerState"):
        if not re.search(r"~%s\s*\(\s*\)" % struct, code):
            f.append(("NO-DESTRUCTOR-" + struct.upper(),
                      "%s has no destructor" % struct))
        if not re.search(r"%s\s*\(\s*const\s+%s\s*&\s*\)\s*=\s*delete" % (struct, struct), code):
            f.append(("COPYABLE-" + struct.upper(),
                      "%s's copy constructor is not deleted" % struct))
        if not re.search(r"%s\s*&\s*operator\s*=\s*\(\s*const\s+%s\s*&\s*\)\s*=\s*delete"
                         % (struct, struct), code):
            f.append(("COPY-ASSIGNABLE-" + struct.upper(),
                      "%s's copy assignment is not deleted" % struct))
        if not re.search(r"%s\s*\(\s*%s\s*&&" % (struct, struct), code):
            f.append(("NO-MOVE-" + struct.upper(),
                      "%s has no move constructor" % struct))
        if not re.search(r"%s\s*&\s*operator\s*=\s*\(\s*%s\s*&&" % (struct, struct), code):
            f.append(("NO-MOVE-ASSIGN-" + struct.upper(),
                      "%s has no move assignment" % struct))

    if not re.search(r"int\s+(WaylandBackend::)?ReleaseSlot\s*\(", back):
        f.append(("NO-BACKEND-RELEASE-SLOT",
                  "the backend has no ReleaseSlot()"))
    destroy = re.search(r"ScopedAStatus\s+destroyLayer\s*\(.*?\n  \}", code, re.S)
    if not destroy:
        f.append(("NO-DESTROY-LAYER", "destroyLayer is gone"))
    elif "ReleaseSlot(" not in destroy.group(0):
        f.append(("NO-SLOT-RELEASE-ON-DESTROY",
                  "destroyLayer does not release the compositor's cached buffers for the "
                  "slots the layer held"))
    apply_cmds = re.search(r"void\s+ApplyLayerCommands\s*\(.*?\n  \}", code, re.S)
    if apply_cmds and "bufferSlotsToClear" in apply_cmds.group(0) \
            and "pendingSlotReleases" not in apply_cmds.group(0):
        f.append(("NO-SLOT-RELEASE-ON-CLEAR",
                  "a slot SurfaceFlinger clears does not queue its compositor buffer for "
                  "release"))

    adopt = re.search(r"void\s+Adopt\s*\(\s*int\s+\w+\s*\)\s*\{(.*?)\n  \}", code, re.S)
    if not adopt:
        f.append(("NO-ADOPT", "HeldBuffer has no Adopt()"))
    else:
        body = adopt.group(1)
        if "fstat(" not in body or "st_ino" not in body or re.search(r"\bino\s*=", body) is None:
            f.append(("NO-INO-FSTAT", "Adopt() does not fstat the fd into `ino`"))
        if "g_heldFdsLive" not in body:
            f.append(("NO-LIVE-COUNT-UP", "Adopt() does not increment g_heldFdsLive"))

    reset = re.search(r"void\s+Reset\s*\(\s*\)\s*\{(.*?)\n  \}", code, re.S)
    if not reset or "g_heldFdsLive" not in reset.group(1):
        f.append(("NO-LIVE-COUNT-DOWN", "HeldBuffer::Reset() does not decrement "
                  "g_heldFdsLive"))

    m = re.search(r"\.fd\s*=\s*dup\s*\(", code)
    if m:
        f.append(("DUP-BYPASSES-ADOPT",
                  "a dup'd fd is assigned straight into a HeldBuffer's `fd` instead of "
                  "going through Adopt()"))

    lk = re.search(r"void\s+LifecycleKlogf\s*\(\s*int64_t\s+\w+,\s*const\s+char\*\s+fmt,\s*\.\.\.\s*\)"
                   r"\s*\{(.*?)\n\}", code, re.S)
    if not lk:
        f.append(("NO-LIFECYCLE-KLOGF", "no LifecycleKlogf()"))
    elif "composerDebugEnabled()" not in lk.group(1):
        f.append(("LIFECYCLE-KLOG-UNGATED",
                  "LifecycleKlogf() does not check composerDebugEnabled()"))

    for rule, literal in EDGE_KLOGS:
        if literal not in code:
            f.append((rule, "no klog carries %r" % literal))

    if not re.search(r'strcmp\(noun,\s*"audit"\)', code):
        f.append(("NO-AUDIT-VERB", "no `display audit` control verb"))
    for field in AUDIT_FIELDS:
        if field not in code:
            f.append(("AUDIT-FIELD-MISSING",
                      "the `display audit` reply carries no %r" % field))
    if not re.search(r'strcmp\(noun,\s*"buffers"\)', code):
        f.append(("NO-BUFFERS-VERB", "no `display buffers` control verb"))
    if "DescribeSlots(" not in code:
        f.append(("NO-BACKEND-SLOTS", "`display buffers` never calls the backend's "
                  "DescribeSlots()"))
    if "WaylandBackend::DescribeSlots" not in back:
        f.append(("BACKEND-SLOTS-UNIMPLEMENTED",
                  "the Wayland backend defines no DescribeSlots()"))

    if not re.search(r"taken\.layers\.clear\(\)", code):
        f.append(("LAYERS-NEVER-FREED",
                  "the removal path never clears `taken.layers`"))

    return f


GOOD = r'''
std::atomic<int> g_heldFdsLive{0};

struct HeldBuffer {
  int fd = -1;
  ino_t ino = 0;
  rhizo::DecodedHandle decoded;
  HeldBuffer() = default;
  ~HeldBuffer() { Reset(); }
  HeldBuffer(const HeldBuffer&) = delete;
  HeldBuffer& operator=(const HeldBuffer&) = delete;
  HeldBuffer(HeldBuffer&& o) noexcept : fd(o.fd) { o.fd = -1; }
  HeldBuffer& operator=(HeldBuffer&& o) noexcept { return *this; }
  void Adopt(int dupFd) {
    Reset();
    fd = dupFd;
    if (fd < 0) return;
    g_heldFdsLive.fetch_add(1, std::memory_order_relaxed);
    struct stat st{};
    ino = fstat(fd, &st) == 0 ? st.st_ino : 0;
  }
  void Reset() {
    if (fd >= 0) {
      close(fd);
      g_heldFdsLive.fetch_sub(1, std::memory_order_relaxed);
    }
    fd = -1;
  }
};

void LifecycleKlogf(int64_t id, const char* fmt, ...) {
  if (!composerDebugEnabled()) return;
  klogf("display %lld lifecycle %s", (long long)id, body);
}

  struct LayerState {
    std::map<int32_t, HeldBuffer> slots;
    OwnedFd acquire;
    LayerState() = default;
    ~LayerState() { Reset(); }
    LayerState(const LayerState&) = delete;
    LayerState& operator=(const LayerState&) = delete;
    LayerState(LayerState&&) = default;
    LayerState& operator=(LayerState&&) = default;
    void Reset() {
      slots.clear();
      acquire.reset();
    }
  };

void edges() {
  LifecycleKlogf(id, "add port=%d claimed=%d", port, claimed ? 1 : 0);
  LifecycleKlogf(id, "hotplug CONNECTED sent");
  LifecycleKlogf(id, "DISCONNECTED sent attempt=1");
  LifecycleKlogf(id, "DISCONNECTED sent attempt=%d", attempt);
  LifecycleKlogf(display, "sf destroyLayer %lld while removing", (long long)layer);
  LifecycleKlogf(display, "sf setVsyncEnabled %d while removing", enabled ? 1 : 0);
  LifecycleKlogf(display, "sf setPowerMode %d while removing", (int32_t)mode);
  LifecycleKlogf(ds.id, "call fn=%s while removing", who);
  LifecycleKlogf(id, "sf-released after %lldms", (long long)ms);
  LifecycleKlogf(id, "SF-ORPHANED port=%d withheld", taken.port);
  LifecycleKlogf(id, "freed ct=%zu layers=%zu layer_slots=%zu current=%d readback=%d "
                 "held_before=%d held_after=%d", a, b, c, d, e, f, g);
}

void finish() {
  taken.current.Reset();
  taken.clientTargetSlots.clear();
  taken.layers.clear();
}

  ScopedAStatus destroyLayer(int64_t display, int64_t layer) override {
    std::vector<int32_t> wlSlots;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      for (const auto& kv : lit->second.slots) wlSlots.push_back(kDeviceSlotBase + kv.first);
      lit->second.Reset();
      ds->layers.erase(lit);
    }
    int dropped = 0;
    for (int32_t wlSlot : wlSlots) dropped += wayland_.ReleaseSlot(display, wlSlot);
    return ok();
  }

  void ApplyLayerCommands(DisplayState& ds, const DisplayCommand& cmd) {
    if (lc.bufferSlotsToClear.has_value()) {
      for (int32_t s : *lc.bufferSlotsToClear) {
        ls.slots.erase(s);
        ds.pendingSlotReleases.push_back(kDeviceSlotBase + s);
      }
    }
  }

void verbs() {
  if (!strcmp(noun, "audit")) {
    WriteControlReply("display audit live=" + live + " awaiting_sf=" + awaiting + " orphaned=" +
                      orphaned + " held_fds_live=" + std::to_string(g_heldFdsLive.load()));
  }
  if (!strcmp(noun, "buffers")) {
    for (const auto& sl : wayland_.DescribeSlots(id)) reply += " wl[";
  }
}
'''

GOOD_BACKEND = '''
std::vector<WaylandSlotInfo> WaylandBackend::DescribeSlots(int64_t displayId) const {
  return {};
}

int WaylandBackend::ReleaseSlot(int64_t displayId, int32_t slot) {
  std::lock_guard<std::mutex> lg(impl_->mutex_);
  DisplayState* ds = impl_->Find(displayId);
  if (!ds) return 0;
  auto it = ds->bufferCache.find(slot);
  if (it == ds->bufferCache.end()) return 0;
  const bool had = it->second.buffer != nullptr;
  if (had) wl_buffer_destroy(it->second.buffer);
  ds->bufferCache.erase(it);
  return had ? 1 : 0;
}
'''


def selftest():
    """check the real shape and each planted-defect copy of it"""
    cases = [("the real shape", GOOD, GOOD_BACKEND, set())]

    def bad(label, old, new, rules, backend=GOOD_BACKEND):
        """record a planted case with a replaced text"""
        assert GOOD.count(old) >= 1, old
        cases.append((label, GOOD.replace(old, new, 1), backend, rules))

    bad("HeldBuffer loses its destructor", "  ~HeldBuffer() { Reset(); }\n", "",
        {"NO-DESTRUCTOR-HELDBUFFER"})
    bad("HeldBuffer becomes copyable", "  HeldBuffer(const HeldBuffer&) = delete;\n", "",
        {"COPYABLE-HELDBUFFER"})
    bad("HeldBuffer loses its move constructor",
        "  HeldBuffer(HeldBuffer&& o) noexcept : fd(o.fd) { o.fd = -1; }\n", "",
        {"NO-MOVE-HELDBUFFER"})
    bad("LayerState loses its destructor", "    ~LayerState() { Reset(); }\n", "",
        {"NO-DESTRUCTOR-LAYERSTATE"})
    bad("destroyLayer stops releasing the compositor's cached buffers",
        "    for (int32_t wlSlot : wlSlots) dropped += wayland_.ReleaseSlot(display, wlSlot);\n",
        "", {"NO-SLOT-RELEASE-ON-DESTROY"})
    bad("a cleared slot no longer queues its compositor buffer",
        "        ds.pendingSlotReleases.push_back(kDeviceSlotBase + s);\n", "",
        {"NO-SLOT-RELEASE-ON-CLEAR"})
    cases.append(("the backend loses ReleaseSlot", GOOD,
                  GOOD_BACKEND.replace("int WaylandBackend::ReleaseSlot", "int Removed", 1),
                  {"NO-BACKEND-RELEASE-SLOT"}))
    bad("LayerState becomes copyable", "    LayerState(const LayerState&) = delete;\n", "",
        {"COPYABLE-LAYERSTATE"})
    bad("LayerState loses its move assignment",
        "    LayerState& operator=(LayerState&&) = default;\n", "",
        {"NO-MOVE-ASSIGN-LAYERSTATE"})
    bad("Adopt stops recording the inode",
        "    ino = fstat(fd, &st) == 0 ? st.st_ino : 0;\n", "",
        {"NO-INO-FSTAT"})
    bad("Adopt stops counting the fd",
        "    g_heldFdsLive.fetch_add(1, std::memory_order_relaxed);\n", "",
        {"NO-LIVE-COUNT-UP"})
    bad("Reset stops counting the fd down",
        "      g_heldFdsLive.fetch_sub(1, std::memory_order_relaxed);\n", "",
        {"NO-LIVE-COUNT-DOWN"})
    bad("a dup lands in a HeldBuffer without Adopt",
        "  taken.current.Reset();", "  taken.current.fd = dup(other);",
        {"DUP-BYPASSES-ADOPT"})
    bad("the lifecycle klogs lose their system test",
        "  if (!composerDebugEnabled()) return;\n", "", {"LIFECYCLE-KLOG-UNGATED"})
    bad("the release edge loses its klog",
        '  LifecycleKlogf(id, "sf-released after %lldms", (long long)ms);\n', "",
        {"EDGE-RELEASED"})
    bad("the orphan edge loses its klog",
        '  LifecycleKlogf(id, "SF-ORPHANED port=%d withheld", taken.port);\n', "",
        {"EDGE-ORPHANED"})
    bad("the freed-accounting klog goes",
        '  LifecycleKlogf(id, "freed ct=%zu layers=%zu layer_slots=%zu current=%d readback=%d "',
        '  LifecycleKlogf(id, "released some buffers "', {"EDGE-FREED"})
    bad("the destroyLayer edge loses its klog",
        '  LifecycleKlogf(display, "sf destroyLayer %lld while removing", (long long)layer);\n',
        "", {"EDGE-DESTROYLAYER"})
    bad("the audit verb goes", 'if (!strcmp(noun, "audit")) {', "if (false) {",
        {"NO-AUDIT-VERB"})
    bad("the audit reply drops held_fds_live", ' + " held_fds_live=" + ', " + ",
        {"AUDIT-FIELD-MISSING"})
    bad("the buffers verb goes", 'if (!strcmp(noun, "buffers")) {', "if (false) {",
        {"NO-BUFFERS-VERB"})
    bad("the layer slots are never freed on removal", "  taken.layers.clear();\n", "",
        {"LAYERS-NEVER-FREED"})
    bad("the backend never implements DescribeSlots", "void finish() {", "void finish() {",
        {"BACKEND-SLOTS-UNIMPLEMENTED"}, backend="")

    rc = 0
    for label, src, backend, want in cases:
        got = {rule for rule, _ in check(src, backend)}
        if want:
            missing = want - got
            if missing:
                print("SELFTEST FAILED: %s -- wanted %s, got %s"
                      % (label, sorted(want), sorted(got) or "no findings"), file=sys.stderr)
                rc = 1
        elif got:
            print("SELFTEST FAILED: %s -- wanted no findings, got %s"
                  % (label, sorted(got)), file=sys.stderr)
            rc = 1
    if rc == 0:
        print("selftest ok: accepts the real shape and catches %d reverted defects"
              % (len(cases) - 1))
    return rc


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    for path in (COMPOSER, BACKEND):
        if not os.path.exists(path):
            print("composer-buffer-release.py: %s not found" % path, file=sys.stderr)
            return 1
    failures = check(open(COMPOSER).read(), open(BACKEND).read())
    if failures:
        print("the composer can leak a held buffer, or its display lifecycle is unreadable:",
              file=sys.stderr)
        for rule, detail in failures:
            print("  [%s] %s" % (rule, detail), file=sys.stderr)
        return 1
    print("held buffers are move-only with destructors, every dup goes through Adopt, and "
          "every display lifecycle edge has its klog")
    return 0


if __name__ == "__main__":
    sys.exit(main())
