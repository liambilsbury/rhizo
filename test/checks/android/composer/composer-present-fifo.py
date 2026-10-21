#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "wayland", "wayland_backend.cpp")


def strip_comments(text):
    """return the text with comments removed and string literals kept"""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1]); i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2); i = n if j < 0 else j + 2
        else:
            out.append(c); i += 1
    return "".join(out)


def check(text):
    """check the backend's pending-frame queue"""
    src = strip_comments(text)
    f = []
    if not re.search(r"static\s+constexpr\s+size_t\s+kPendingDepth\s*=\s*2\s*;", src):
        f.append(("QUEUE-SHAPE", "no `static constexpr size_t kPendingDepth = 2;`"))
    if not re.search(r"std::map<int64_t,\s*std::deque<PendingFrame>>\s+pendingFrames\s*;", src):
        f.append(("QUEUE-SHAPE", "pendingFrames is not a per-display std::deque<PendingFrame>"))
    m = re.search(r"auto&\s+queue\s*=\s*impl->pendingFrames\[displayId\];(.*?)impl->asyncQueued\+\+;",
                  src, re.S)
    if not m:
        f.append(("SUPERSEDE-AT-DEPTH", "PresentFrameWhenSignaled does not take the display's queue "
                  "before counting the frame"))
    else:
        body = m.group(1)
        if not re.search(r"if\s*\(queue\.size\(\)\s*>=\s*Impl::kPendingDepth\)\s*\{\s*"
                         r"Impl::ClosePending\(queue\.back\(\)\);\s*queue\.pop_back\(\);\s*"
                         r"impl->asyncSuperseded\+\+;\s*\}", body):
            f.append(("SUPERSEDE-AT-DEPTH", "a frame is not superseded only at depth, newest first, "
                      "closed before it is dropped and counted"))
        if "queue.push_back(pf);" not in body:
            f.append(("SUPERSEDE-AT-DEPTH", "the new frame is not appended behind the head"))
        if "ClosePending(queue.front())" in body or "pop_front" in body:
            f.append(("SUPERSEDE-AT-DEPTH", "the head is dropped on arrival"))
    if not re.search(r"const\s+Impl::PendingFrame&\s+head\s*=\s*kv\.second\.front\(\);\s*"
                     r"if\s*\(head\.frame\.acquireFenceFd\s*<\s*0\)", src):
        f.append(("HEAD-ONLY-POLL", "the pump does not build its poll set from each queue's front()"))
    if re.search(r"pfds\.push_back\(\{kv\.second\.frame\.acquireFenceFd", src):
        f.append(("HEAD-ONLY-POLL", "the pump polls a slot's fence directly, not the queue head's"))
    if not re.search(r"ready\.emplace_back\(id,\s*it->second\.front\(\)\);\s*it->second\.pop_front\(\);"
                     r"\s*if\s*\(it->second\.empty\(\)\)\s*impl->pendingFrames\.erase\(it\);", src):
        f.append(("IN-ORDER-POP", "a ready head does not leave by pop_front with the queue erased "
                  "only once empty"))
    if not re.search(r"for\s*\(auto&\s+pf\s*:\s*pit->second\)\s*Impl::ClosePending\(pf\);\s*"
                     r"impl->pendingFrames\.erase\(pit\);", src):
        f.append(("DROP-CLOSES", "DestroyDisplayLocked does not close every queued frame before "
                  "erasing the queue"))
    if not re.search(r"for\s*\(auto&\s+kv\s*:\s*pendingFrames\)\s*\{\s*for\s*\(auto&\s+pf\s*:\s*"
                     r"kv\.second\)\s*ClosePending\(pf\);\s*\}\s*pendingFrames\.clear\(\);", src):
        f.append(("DROP-CLOSES", "StopPump does not close every queued frame before clearing"))
    if not re.search(r"RequestCompletionLocked\(impl,\s*&ds,\s*MonotonicNs\(\)\);\s*"
                     r"wl_surface_commit\(ds\.surface\);", src):
        f.append(("COMMIT-STAMP", "PresentFrame does not request completion with the commit's "
                  "MonotonicNs() right before wl_surface_commit"))
    if not re.search(r"RequestCompletionLocked\(impl,\s*ds,\s*0\);", src):
        f.append(("COMMIT-STAMP", "KickLocked does not mark its frame-less commit with 0"))
    for name in ("OnFeedbackPresented", "OnFeedbackDiscarded"):
        m = re.search(r"void\s+" + name + r"\((.*?)\n\}", src, re.S)
        body = m.group(1) if m else ""
        if not re.search(r"int64_t\s+commitNs\s*=\s*ctx->commitNs;\s*delete\s+ctx;", body):
            f.append(("COMMIT-STAMP", "%s does not read ctx->commitNs before deleting ctx" % name))
        if not re.search(r"pendingPresented\.push_back\(\{[^}]*commitNs\}\);", body):
            f.append(("COMMIT-STAMP", "%s does not hand commitNs to the pump" % name))
    return f


ONE_SLOT_HANDOFF = '''
  pf.queuedNs = MonotonicNs();
  auto it = impl->pendingFrames.find(displayId);
  if (it != impl->pendingFrames.end()) {
    Impl::ClosePending(it->second);
    it->second = pf;
    impl->asyncSuperseded++;
  } else {
    impl->pendingFrames.emplace(displayId, pf);
  }
  impl->asyncQueued++;
'''


def selftest():
    """check the real backend and each narrower revert of it"""
    with open(BACKEND) as fh:
        real = fh.read()
    failures = []
    got = check(real)
    if got:
        failures.append("the real backend fails: %s" % got)
    m = re.search(r"  pf\.queuedNs = MonotonicNs\(\);\n  auto& queue.*?impl->asyncQueued\+\+;\n", real, re.S)
    if not m:
        failures.append("cannot locate the hand-off in the real backend to build the one-slot fixture")
    else:
        one_slot = real[:m.start()] + ONE_SLOT_HANDOFF + real[m.end():]
        codes = {c for c, _ in check(one_slot)}
        if "SUPERSEDE-AT-DEPTH" not in codes:
            failures.append("the pre-fix one-slot hand-off must fail SUPERSEDE-AT-DEPTH, got %s" % sorted(codes))
    cases = [
        ("depth of one", "kPendingDepth = 2;", "kPendingDepth = 1;", "QUEUE-SHAPE"),
        ("head polled by slot", "const Impl::PendingFrame& head = kv.second.front();",
         "const Impl::PendingFrame& head = kv.second.back();", "HEAD-ONLY-POLL"),
        ("ready frame erases the queue",
         "          it->second.pop_front();\n          if (it->second.empty()) impl->pendingFrames.erase(it);",
         "          impl->pendingFrames.erase(it);", "IN-ORDER-POP"),
        ("destroy leaks queued fds", "    for (auto& pf : pit->second) Impl::ClosePending(pf);\n", "",
         "DROP-CLOSES"),
        ("kick carries a stamp", "RequestCompletionLocked(impl, ds, 0);",
         "RequestCompletionLocked(impl, ds, MonotonicNs());", "COMMIT-STAMP"),
        ("presented listener drops the stamp",
         "  impl->pendingPresented.push_back({displayId, presentedNs, static_cast<int64_t>(refresh), false, commitNs});",
         "  impl->pendingPresented.push_back({displayId, presentedNs, static_cast<int64_t>(refresh), false, 0});",
         "COMMIT-STAMP"),
    ]
    for label, old, new, code in cases:
        if real.count(old) != 1:
            failures.append("fixture %r: expected exactly one %r in the real backend" % (label, old[:50]))
            continue
        codes = {c for c, _ in check(real.replace(old, new, 1))}
        if code not in codes:
            failures.append("fixture %r must fail %s, got %s" % (label, code, sorted(codes)))
    return failures


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        failures = selftest()
        if failures:
            for x in failures:
                print("check-composer-present-fifo selftest: %s" % x)
            return 1
        print("check-composer-present-fifo selftest ok: accepts the real shape and catches the "
              "one-slot hand-off and six narrower reverts")
        return 0
    with open(BACKEND) as fh:
        failures = check(fh.read())
    for code, why in failures:
        print("check-composer-present-fifo: [%s] %s" % (code, why))
    if failures:
        return 1
    print("frames present in order from a two-deep queue, every drop closes its fds, and every "
          "feedback carries its commit's stamp")
    return 0


if __name__ == "__main__":
    sys.exit(main())
