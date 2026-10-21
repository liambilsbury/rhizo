#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMPOSER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")


def strip_comments(text):
    """drop comments from C++ source text"""
    out, i, n = [], 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            i = text.find("\n", i)
            i = n if i == -1 else i
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


def block_at(text, open_idx):
    """return the text inside a brace pair"""
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i]
    return None


def check(src):
    """check the changed composition types loop"""
    src = strip_comments(src)
    f = []
    decl = src.find("ChangedCompositionTypes changed;")
    if decl < 0:
        return [("CHANGED-MISSING", "validate no longer builds a ChangedCompositionTypes")]
    push = src.find("changedCompositionTypes>(std::move(changed))", decl)
    if push < 0:
        return [("CHANGED-NOT-RETURNED", "the ChangedCompositionTypes built in validate is never returned")]
    region = src[decl:push]
    persistent = None
    for m in re.finditer(r"for\s*\(\s*const\s+auto\s*&\s*\[\s*(\w+)\s*,\s*(\w+)\s*\]\s*:\s*ds->layers\s*\)\s*\{", region):
        body = block_at(region, m.end() - 1)
        if body is not None and "changed.layers.push_back" in body:
            persistent = (m.group(1), m.group(2), body)
    if persistent is None:
        f.append(("NOT-FROM-DISPLAY-LAYERS", "no loop over ds->layers fills changed.layers"))
    else:
        layer_id, state, body = persistent
        if not re.search(r"\b%s\.requested\s*!=\s*Composition::CLIENT\b" % re.escape(state), body):
            f.append(("NOT-FROM-STANDING-REQUEST", "the ds->layers loop does not compare %s.requested "
                      "against CLIENT" % state))
        if not re.search(r"ccl\.layer\s*=\s*%s\s*;" % re.escape(layer_id), body):
            f.append(("WRONG-LAYER-ID", "the ds->layers loop reports a layer other than its own key"))
    for m in re.finditer(r"for\s*\(\s*const\s+auto\s*&\s*\w+\s*:\s*cmd\.layers\s*\)\s*\{", region):
        body = block_at(region, m.end() - 1)
        if body is not None and "changed.layers.push_back" in body:
            f.append(("FROM-BATCH", "changed.layers is filled from cmd.layers, the batch alone"))
    return f


GOOD = """
        ChangedCompositionTypes changed;
        changed.display = cmd.display;
        for (const auto& lc : cmd.layers) {
          if (!lc.composition.has_value()) continue;
          if (lc.composition->composition == Composition::DISPLAY_DECORATION) {
            out->push_back(MakeCommandError(IComposerClient::EX_UNSUPPORTED));
          }
        }
        for (const auto& [layerId, ls] : ds->layers) {
          if (layerId == device) continue;
          if (ls.requested == Composition::CURSOR) { continue; }
          if (ls.requested != Composition::CLIENT) {
            ChangedCompositionLayer ccl;
            ccl.layer = layerId;
            ccl.composition = Composition::CLIENT;
            changed.layers.push_back(std::move(ccl));
          }
        }
        if (!changed.layers.empty()) {
          p.set<CommandResultPayload::changedCompositionTypes>(std::move(changed));
        }
"""
BAD_BATCH = """
        ChangedCompositionTypes changed;
        for (const auto& lc : cmd.layers) {
          if (!lc.composition.has_value()) continue;
          if (lc.layer == device) continue;
          if (lc.composition->composition != Composition::CLIENT) {
            ChangedCompositionLayer ccl;
            ccl.layer = lc.layer;
            ccl.composition = Composition::CLIENT;
            changed.layers.push_back(std::move(ccl));
          }
        }
        p.set<CommandResultPayload::changedCompositionTypes>(std::move(changed));
"""
BAD_NO_REQUEST = GOOD.replace("ls.requested != Composition::CLIENT", "true")
BAD_WRONG_ID = GOOD.replace("ccl.layer = layerId;", "ccl.layer = device;")
BAD_NOT_RETURNED = GOOD.replace("changedCompositionTypes>(std::move(changed))", "error>(err)")


def selftest():
    """check each source shape against the findings it must produce"""
    cases = [
        ("the standing-request loop passes", GOOD, set()),
        ("a loop over the batch alone is caught", BAD_BATCH, {"NOT-FROM-DISPLAY-LAYERS", "FROM-BATCH"}),
        ("a display-layer loop that ignores the request is caught", BAD_NO_REQUEST, {"NOT-FROM-STANDING-REQUEST"}),
        ("a report naming the wrong layer is caught", BAD_WRONG_ID, {"WRONG-LAYER-ID"}),
        ("a report never returned is caught", BAD_NOT_RETURNED, {"CHANGED-NOT-RETURNED"}),
    ]
    fails = 0
    for name, src, want in cases:
        got = {n for n, _ in check(src)}
        ok = got == want
        fails += not ok
        print(("ok" if ok else "FAIL") + ": " + name + ("" if ok else " (got %s, want %s)" % (sorted(got), sorted(want))))
    print("check-composer-changed-types selftest: %s" % ("ok" if not fails else "FAILED"))
    return 1 if fails else 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    with open(args[0] if args else COMPOSER) as f:
        findings = check(f.read())
    for name, msg in findings:
        print("FAIL %s: %s" % (name, msg))
    if findings:
        return 1
    print("validate reports every layer's standing composition request, not the batch's alone")
    return 0


if __name__ == "__main__":
    sys.exit(main())
