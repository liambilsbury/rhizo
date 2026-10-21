#!/usr/bin/env python3
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
UINPUT = "src/android/hal/graphics-composer/src/input/uinput.cpp"
COMPOSER = "src/android/hal/graphics-composer/src/composer.cpp"
POLICY = "src/androidd/guest/sepolicy/policy.cil"


def function_body(text, signature):
    """return the braced body of a function"""
    start = text.find(signature)
    if start < 0:
        return None
    open_at = text.find("{", start)
    depth = 0
    for i in range(open_at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_at:i + 1]
    return None


def code_only(text):
    """remove // comments from C++ text"""
    return re.sub(r"//[^\n]*", "", text)


def check(files):
    """check the uinput pool and composer for the deferred mouse"""
    bad = []
    uinput = code_only(files[UINPUT])
    composer = code_only(files[COMPOSER])
    policy = files[POLICY]

    create = function_body(uinput, "bool UinputDevices::CreatePoolDeviceLocked(")
    if create is None:
        bad.append("uinput.cpp has no CreatePoolDeviceLocked")
    else:
        mouse = create[create.find("pd.mouse.fd = OpenUinput();"):]
        creates = re.findall(r"ioctl\(pd\.mouse\.fd, UI_DEV_CREATE\)", mouse)
        if not re.search(r"else if \(port == kMinPort\) \{\s*if \(ioctl\(pd\.mouse\.fd, UI_DEV_CREATE\) == 0\)", mouse) \
                or len(creates) != 1:
            bad.append("the pool creates a secondary port's mouse device at boot")
        if "SetupMouse(pd.mouse.fd, port)" not in mouse:
            bad.append("the pool does not set every port's mouse up before the flip")

    publish = function_body(uinput, "void UinputDevices::PublishMouse(")
    if publish is None:
        bad.append("uinput.cpp has no UinputDevices::PublishMouse")
    elif not re.search(r"ioctl\(mouse\.fd, UI_DEV_CREATE\) != 0\).*?mouse\.created = true;", publish, re.S):
        bad.append("PublishMouse does not create the mouse device and record it")

    destroy = function_body(uinput, "void UinputDevices::Destroy(")
    if destroy is None or "ioctl(mouse.fd, UI_DEV_DESTROY)" not in destroy:
        bad.append("Destroy does not destroy a secondary mouse")
    else:
        if "kMinPort" not in destroy:
            bad.append("Destroy may destroy the primary display's mouse")
        m = re.search(r"if \(ioctl\(mouse\.fd, UI_DEV_DESTROY\) != 0\) \{.*?\} else \{(.*?)\n    \}", destroy, re.S)
        if not m or "mouse.created = false;" not in m.group(1):
            bad.append("Destroy records the mouse as gone without a successful UI_DEV_DESTROY")
        elif "SetupMouse(mouse.fd" not in m.group(1):
            bad.append("Destroy does not set the mouse up again, and a destroyed uinput device keeps none of its bits")

    for name in ("Scroll", "Move", "MoveHome", "MoveTo"):
        body = function_body(uinput, "bool UinputDevices::%s(" % name)
        if body is None or "created" not in body:
            bad.append("UinputDevices::%s writes to a mouse whose device may not exist yet" % name)

    calls = [m.start() for m in re.finditer(r"uinput_\.PublishMouse\(", composer)]
    if len(calls) != 1:
        bad.append("composer.cpp calls uinput_.PublishMouse %d times, expected once, from the present path" % len(calls))
    else:
        head = composer[max(0, calls[0] - 400):calls[0]]
        guard = head[head.rfind("if ("):]
        if "!ds->layers.empty()" not in guard:
            bad.append("the composer creates a display's mouse without requiring a composited layer on it")
        if "kPrimaryDisplayId" not in guard:
            bad.append("the composer's PublishMouse call does not exclude the primary display")
        if "!ds->mousePublished" not in guard or "ds->mousePublished = true" not in composer[calls[0] - 200:calls[0]]:
            bad.append("the composer does not create a display's mouse once per display")
        present = composer.rfind("PresentBufferedFrame(*ds, cmd);", 0, calls[0])
        if present < 0 or calls[0] - present > 600:
            bad.append("uinput_.PublishMouse is not called from the present path, right after the frame is presented")

    grants = []
    for m in re.finditer(r"^\(allow rhizo_composer uhid_device \(chr_file \(([^)]*)\)\)\)", policy, re.M):
        grants.extend(m.group(1).split())
    if "ioctl" not in grants:
        bad.append("rhizo-policy.cil does not grant rhizo_composer ioctl on uhid_device")
    return bad


def load(root):
    """return the text of the checked files under a root"""
    return {rel: open(os.path.join(root, rel)).read() for rel in (UINPUT, COMPOSER, POLICY)}


def selftest():
    """check the live tree and each planted-defect copy of it"""
    live = load(ROOT)
    problems = check(live)
    assert not problems, "the live tree must pass: %s" % problems

    def mutate(rel, old, new):
        """return a copy of the files with a text replaced"""
        files = dict(live)
        assert files[rel].count(old) == 1, "fixture anchor must occur once in %s: %r" % (rel, old[:60])
        files[rel] = files[rel].replace(old, new, 1)
        return files

    cases = [
        ("every mouse created at boot",
         mutate(UINPUT, "    } else if (port == kMinPort) {\n      if (ioctl(pd.mouse.fd, UI_DEV_CREATE) == 0) {",
                "    } else {\n      if (ioctl(pd.mouse.fd, UI_DEV_CREATE) == 0) {"),
         "creates a secondary port's mouse device at boot"),
        ("no late create",
         mutate(UINPUT, "  if (ioctl(mouse.fd, UI_DEV_CREATE) != 0) {", "  if (false) {"),
         "does not create the mouse device"),
        ("no destroy",
         mutate(UINPUT, "      if (ioctl(mouse.fd, UI_DEV_DESTROY) != 0) {", "      if (true) {"),
         "Destroy does not destroy a secondary mouse"),
        ("gone without a successful destroy",
         mutate(UINPUT, "      } else {\n        mouse.created = false;\n", "      }\n      {\n        mouse.created = false;\n"),
         "without a successful UI_DEV_DESTROY"),
        ("no setup after destroy",
         mutate(UINPUT, "        if (!SetupMouse(mouse.fd, dit->second)) {\n          close(mouse.fd);\n          mouse.fd = -1;\n        }\n",
                ""),
         "does not set the mouse up again"),
        ("move without the created system test",
         mutate(UINPUT, "bool UinputDevices::Move(int64_t displayId, int32_t dx, int32_t dy) {\n  std::lock_guard<std::mutex> lg(mutex_);\n"
                        "  auto dit = displayToPort_.find(displayId);\n  if (dit == displayToPort_.end() || (dx == 0 && dy == 0)) return false;\n"
                        "  const Device& mouse = pool_[dit->second].mouse;\n  if (mouse.fd < 0 || !mouse.created) return false;\n",
                "bool UinputDevices::Move(int64_t displayId, int32_t dx, int32_t dy) {\n  std::lock_guard<std::mutex> lg(mutex_);\n"
                "  auto dit = displayToPort_.find(displayId);\n  if (dit == displayToPort_.end() || (dx == 0 && dy == 0)) return false;\n"
                "  const Device& mouse = pool_[dit->second].mouse;\n  if (mouse.fd < 0) return false;\n"),
         "UinputDevices::Move writes to a mouse"),
        ("created before any layer",
         mutate(COMPOSER, "!ds->mousePublished && !ds->layers.empty() && cmd.display != kPrimaryDisplayId",
                "!ds->mousePublished && cmd.display != kPrimaryDisplayId"),
         "without requiring a composited layer"),
        ("primary included",
         mutate(COMPOSER, "!ds->mousePublished && !ds->layers.empty() && cmd.display != kPrimaryDisplayId",
                "!ds->mousePublished && !ds->layers.empty()"),
         "does not exclude the primary display"),
        ("policy ioctl removed",
         mutate(POLICY, "(allow rhizo_composer uhid_device (chr_file (open write ioctl append lock map)))",
                "(allow rhizo_composer uhid_device (chr_file (open write append lock map)))"),
         "ioctl on uhid_device"),
    ]
    for name, files, want in cases:
        got = check(files)
        assert any(want in g for g in got), "%s: expected a problem naming %r, got %s" % (name, want, got)
    print("check-composer-deferred-mouse selftest: the live tree passes; %d single regressions each fail by name" % len(cases))


def main():
    """run the check or its selftest and print the result"""
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return 0
    root = sys.argv[1] if len(sys.argv) > 1 else ROOT
    problems = check(load(root))
    for p in problems:
        print("FAIL: %s" % p)
    if problems:
        return 1
    print("check-composer-deferred-mouse: a secondary display's mouse device is created on its first composited layer, "
          "destroyed and set up again when it goes, and the policy grants the ioctls")
    return 0


if __name__ == "__main__":
    sys.exit(main())
