#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMPOSER = os.path.join(HERE, "..", "..", "..", "..", "src", "android", "hal", "graphics-composer", "src", "composer.cpp")

INPUT_SIGNATURE = "void OnWaylandInput("
STEP_SIGNATURE = "void StepAndroidPointer("
STEP_CALL = re.compile(r"\bStepAndroidPointer\(\s*ev\.displayId\s*,\s*mx\s*,\s*my\s*\)\s*;")
OBSERVED_IF = re.compile(r"\bif\s*\(\s*TakeObservedPointer\(\s*ev\.displayId\s*,")
OBSERVED_VARS = re.compile(r"\bTakeObservedPointer\(\s*ev\.displayId\s*,\s*&\s*(\w+)\s*,\s*&\s*(\w+)\s*\)")
MODEL_ALIAS = re.compile(r"\bauto\s*&\s*(\w+)\s*=\s*androidPointer_\[\s*displayId\s*\]\s*;")


def code_only(text):
    """blank comments and strings in C++ text"""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)


def block_at(text, open_at):
    """return the braced block at open_at"""
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return None


def function_body(text, signature):
    """return the body of a function"""
    start = text.find(signature)
    if start < 0:
        return None
    open_at = text.find("{", start)
    return None if open_at < 0 else block_at(text, open_at)


def case_block(body, kind):
    """return the braced block of a case"""
    m = re.search(r"case\s+Kind::" + kind + r"\s*:\s*\{", body)
    return None if m is None else block_at(body, m.end() - 1)


def branches(block):
    """return the two branches of TakeObservedPointer"""
    m = OBSERVED_IF.search(block)
    if m is None:
        return None, None
    open_at = block.find("{", m.end())
    taken = block_at(block, open_at) if open_at >= 0 else None
    if taken is None:
        return None, None
    rest = block[open_at + len(taken):]
    e = re.match(r"\s*else\s*\{", rest)
    other = block_at(rest, e.end() - 1) if e else None
    return taken, other


def assignments(step, name):
    """return the assignment expressions for a name"""
    out = []
    for m in re.finditer(r"\b%s\s*(?:<<|>>|[-+*/%%&|^])?=(?!=)" % name, step):
        depth, i = 0, m.end()
        while i < len(step) and not (depth == 0 and step[i] in ",;"):
            depth += step[i] in "([{"
            depth -= step[i] in ")]}"
            i += 1
        out.append(step[m.end():i])
    return out


def negates(expr):
    """detect a unary minus in an expression"""
    for i, c in enumerate(expr):
        if c != "-" or expr[i + 1:i + 2] in ("-", ">") or expr[i - 1:i] == "-":
            continue
        before = expr[:i].rstrip()
        if not before or before[-1] in "=([{,*/%+-?:!~&|^<>":
            return True
    return False


def axis_delta(step, model, axis):
    """return the problem with an axis delta"""
    field, other = ("first", "y") if axis == "x" else ("second", "x")
    ofield = "second" if axis == "x" else "first"
    exprs = assignments(step, "d" + axis)
    if len(exprs) != 1:
        return f"d{axis} is assigned {len(exprs)} times, not once"
    chain = exprs
    if re.search(r"\bn%s\b" % axis, exprs[0]):
        n = assignments(step, "n" + axis)
        if len(n) != 1:
            return f"n{axis} is assigned {len(n)} times, not once"
        chain = exprs + n
    if not any(re.search(r"\bm%s\s*-\s*%s\.%s\b" % (axis, model, field), e) for e in chain):
        return f"d{axis} is not m{axis} - ap.{field}"
    for e in chain:
        if re.search(r"\b[mnd]%s\b|\.%s\b" % (other, ofield), e):
            return f"d{axis} reads the {other} axis: {e.strip()}"
    return None


def check(source):
    """check the pointer enter and step code"""
    code = code_only(source)
    bad = []
    step = function_body(code, STEP_SIGNATURE)
    if step is None:
        bad.append(("NO-STEP-FUNCTION",
                    "composer.cpp has no StepAndroidPointer(displayId, x, y) carrying "
                    "Android's pointer to a target by one relative move"))
    else:
        alias = MODEL_ALIAS.search(step)
        model = r"(?:%s|androidPointer_\[\s*displayId\s*\])" % (re.escape(alias.group(1)) if alias else "(?!)")
        moves = list(re.finditer(r"\buinput_\.Move\(([^;]*)\)\s*;", step))
        if not moves:
            bad.append(("STEP-NO-MOVE", "StepAndroidPointer never calls uinput_.Move"))
        elif len(moves) != 1 or not re.fullmatch(r"\s*displayId\s*,\s*dx\s*,\s*dy\s*", moves[0].group(1)):
            bad.append(("STEP-MOVE-NOT-DX-DY",
                        "StepAndroidPointer's move is not the one uinput_.Move(displayId, dx, dy): "
                        + "; ".join(m.group(0) for m in moves)))
        write = re.search(r"(?:\b%s|%s)\s*=\s*\{\s*mx\s*,\s*my\s*\}\s*;"
                          % (re.escape(alias.group(1)) if alias else "(?!)",
                             r"\bandroidPointer_\[\s*displayId\s*\]"), step)
        if not write or (moves and write.start() < moves[-1].start()):
            bad.append(("STEP-NO-MODEL",
                        "StepAndroidPointer never records where it put the pointer "
                        "(ap = {mx, my} after the move)"))
        why = [w for w in (axis_delta(step, model, "x"), axis_delta(step, model, "y")) if w]
        if why:
            bad.append(("STEP-DELTA-NOT-TARGET-MINUS-MODEL",
                        "StepAndroidPointer's delta is not the target minus the model on both axes "
                        "(mx - ap.first, my - ap.second): " + "; ".join(why)))
        negated = [f"{v} = {e.strip()}" for v in ("nx", "ny", "dx", "dy")
                   for e in assignments(step, v) if negates(e)]
        if negated:
            bad.append(("STEP-DELTA-NEGATED",
                        "StepAndroidPointer negates its delta: " + "; ".join(negated)))
    body = function_body(code, INPUT_SIGNATURE)
    if body is None:
        return bad + [("NO-INPUT-FUNCTION", f"composer.cpp has no {INPUT_SIGNATURE}...)")]
    enter = case_block(body, "PointerEnter")
    if enter is None:
        bad.append(("NO-ENTER-CASE", "OnWaylandInput has no braced `case Kind::PointerEnter:`"))
    else:
        taken, other = branches(enter)
        if taken is None:
            bad.append(("ENTER-NO-OBSERVATION",
                        "the PointerEnter case never branches on TakeObservedPointer"))
        elif not STEP_CALL.search(taken):
            bad.append(("ENTER-NO-STEP",
                        "a pointer enter that took an observed position never steps Android's "
                        "pointer to where the host's entered"))
        else:
            obs = OBSERVED_VARS.search(enter)
            write = obs and re.search(
                r"\bandroidPointer_\[\s*ev\.displayId\s*\]\s*=\s*\{\s*%s\s*,\s*%s\s*\}\s*;"
                % (re.escape(obs.group(1)), re.escape(obs.group(2))), taken)
            if not write or write.start() > STEP_CALL.search(taken).start():
                bad.append(("ENTER-STEP-BEFORE-ADOPT",
                            "the observed branch steps before it writes the observation into "
                            "androidPointer_ (or never writes it)"))
        if taken is not None and (other is None or not re.search(r"\bResyncPointer\(", other)):
            bad.append(("ENTER-NO-REHOME",
                        "a pointer enter with no observation does not re-home Android's pointer "
                        "(ResyncPointer)"))
    motion = case_block(body, "PointerMotion")
    if motion is None:
        bad.append(("NO-MOTION-CASE", "OnWaylandInput has no braced `case Kind::PointerMotion:`"))
    elif not STEP_CALL.search(motion):
        bad.append(("MOTION-NO-STEP",
                    "the PointerMotion case does not step through StepAndroidPointer"))
    return bad


STEP = """
  void StepAndroidPointer(int64_t displayId, int32_t mx, int32_t my) {
    auto& ap = androidPointer_[displayId];
    const int32_t dx = mx - ap.first, dy = my - ap.second;
    if (dx != 0 || dy != 0) uinput_.Move(displayId, dx, dy);
    ap = {mx, my};
  }
"""

FIXED = STEP + """
  void OnWaylandInput(const rhizo::WaylandInputEvent& ev) {
    switch (ev.kind) {
      case Kind::PointerEnter: {
        int32_t obsX = 0, obsY = 0;
        if (TakeObservedPointer(ev.displayId, &obsX, &obsY)) {  // NOLINT
          androidPointer_[ev.displayId] = {obsX, obsY};
          StepAndroidPointer(ev.displayId, mx, my);
        } else {
          ResyncPointer(ev.displayId, mx, my);
        }
        break;
      }
      case Kind::PointerMotion: {
        if (TakeObservedPointer(ev.displayId, &obsX, &obsY)) ap = {obsX, obsY};
        StepAndroidPointer(ev.displayId, mx, my);
        break;
      }
    }
  }
"""

ADOPTED = FIXED.replace("          StepAndroidPointer(ev.displayId, mx, my);\n",
                        "          // StepAndroidPointer(ev.displayId, mx, my);\n", 1)
NO_REHOME = FIXED.replace("          ResyncPointer(ev.displayId, mx, my);\n", "", 1)
MOTION_INLINE = FIXED.replace(
    "        StepAndroidPointer(ev.displayId, mx, my);\n        break;\n      }\n    }",
    "        uinput_.Move(ev.displayId, mx - ap.first, my - ap.second);\n        break;\n      }\n    }")
NO_STEP_MOVE = FIXED.replace("    if (dx != 0 || dy != 0) uinput_.Move(displayId, dx, dy);\n", "", 1)
STEP_AFTER_IF = FIXED.replace(
    "          StepAndroidPointer(ev.displayId, mx, my);\n        } else {\n"
    "          ResyncPointer(ev.displayId, mx, my);\n        }\n",
    "        } else {\n          ResyncPointer(ev.displayId, mx, my);\n        }\n"
    "        StepAndroidPointer(ev.displayId, mx, my);\n", 1)
STEP_BEFORE_ADOPT = FIXED.replace(
    "          androidPointer_[ev.displayId] = {obsX, obsY};\n"
    "          StepAndroidPointer(ev.displayId, mx, my);\n",
    "          StepAndroidPointer(ev.displayId, mx, my);\n"
    "          androidPointer_[ev.displayId] = {obsX, obsY};\n", 1)
NO_ADOPT = FIXED.replace("          androidPointer_[ev.displayId] = {obsX, obsY};\n", "", 1)
REVERSED_X = FIXED.replace("dx = mx - ap.first", "dx = ap.first - mx", 1)
REVERSED_Y = FIXED.replace("dy = my - ap.second", "dy = ap.second - my", 1)


REAL_MUTANTS = [
    ("the real step moving by the negated delta",
     "uinput_.Move(displayId, dx, dy);", "uinput_.Move(displayId, -dx, -dy);", {"STEP-MOVE-NOT-DX-DY"}),
    ("the real step moving with its axes swapped",
     "uinput_.Move(displayId, dx, dy);", "uinput_.Move(displayId, dy, dx);", {"STEP-MOVE-NOT-DX-DY"}),
    ("the real step negating the x delta",
     "nx = static_cast<int64_t>(mx - ap.first)", "nx = -static_cast<int64_t>(mx - ap.first)",
     {"STEP-DELTA-NEGATED"}),
    ("the real step never recording the pointer",
     "    ap = {mx, my};\n", "", {"STEP-NO-MODEL"}),
]


def selftest():
    """check each source shape against the findings it must produce"""
    failures = 0
    with open(COMPOSER, encoding="utf-8") as f:
        real_source = f.read()
    cases = [
        ("the fixed shape", FIXED, set()),
        ("the enter adopting the observation", ADOPTED, {"ENTER-NO-STEP"}),
        ("the enter with no re-home", NO_REHOME, {"ENTER-NO-REHOME"}),
        ("the motion with its own arithmetic", MOTION_INLINE, {"MOTION-NO-STEP"}),
        ("a step that never moves", NO_STEP_MOVE, {"STEP-NO-MOVE"}),
        ("the step outside the observed branch", STEP_AFTER_IF, {"ENTER-NO-STEP"}),
        ("the step above the observation's model write", STEP_BEFORE_ADOPT, {"ENTER-STEP-BEFORE-ADOPT"}),
        ("the observation never written to the model", NO_ADOPT, {"ENTER-STEP-BEFORE-ADOPT"}),
        ("the x delta reversed (ap.first - mx)", REVERSED_X, {"STEP-DELTA-NOT-TARGET-MINUS-MODEL"}),
        ("the y delta reversed (ap.second - my)", REVERSED_Y, {"STEP-DELTA-NOT-TARGET-MINUS-MODEL"}),
    ]
    real_step = function_body(real_source, STEP_SIGNATURE) or ""
    for name, old, new, want in REAL_MUTANTS:
        if real_step.count(old) != 1:
            print(f"SELFTEST FAIL: {name}: composer.cpp's StepAndroidPointer holds {old!r} "
                  f"{real_step.count(old)} times, not once")
            failures += 1
            continue
        cases.append((name, real_source.replace(real_step, real_step.replace(old, new, 1), 1), want))
    for name, source, want in cases:
        if source in (FIXED, real_source) and name != "the fixed shape":
            print(f"SELFTEST FAIL: {name}: the plant changed nothing")
            failures += 1
            continue
        got = {c for c, _ in check(source)}
        if got == want:
            print(f"ok   {name}: {', '.join(sorted(got)) or 'clean'}")
        else:
            print(f"SELFTEST FAIL: {name}: got {sorted(got)}, want {sorted(want)}")
            failures += 1
    real = check(real_source)
    if real:
        print(f"SELFTEST FAIL: the real composer.cpp is not clean: {real}")
        failures += 1
    else:
        print("ok   the real composer.cpp")
    if failures:
        print(f"check-composer-pointer-enter selftest: {failures} case(s) failed")
        return 1
    print(f"check-composer-pointer-enter selftest: {len(cases) + 1} cases passed")
    return 0


def main(argv):
    """run the check or its selftest and print the result"""
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:]:
        print("usage: composer-pointer-enter.py [--selftest]", file=sys.stderr)
        return 2
    with open(COMPOSER, encoding="utf-8") as f:
        bad = check(f.read())
    for c, msg in bad:
        print(f"FAIL {c}: {msg}")
    if bad:
        return 1
    print("check-composer-pointer-enter: an enter steps Android's pointer to the host's, "
          "through the one function a motion uses")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
