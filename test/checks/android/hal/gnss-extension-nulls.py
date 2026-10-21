#!/usr/bin/env python3

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
GLUE = "tools/build/toolchain/regen-aidl-glue.sh"
HAL = "src/android/hal/gnss/src/gnss.cpp"
ARTIFACT = "var/share/gfx_hal/rhizo-gnss-service"

DEREFERENCED = {
    "getExtensionPsds":
        "boot: GnssNative_init -> GnssPsds.cpp:38 (wrapped at Gnss.cpp:736, "
        "called at com_android_server_location_GnssLocationProvider.cpp:330)",
    "getExtensionGnssGeofence":
        "boot: GnssNative_init -> GnssGeofence.cpp:39 (wrapped at Gnss.cpp:630, "
        "called at com_android_server_location_GnssLocationProvider.cpp:342)",
    "getExtensionMeasurementCorrections":
        "boot: GnssNative_init -> MeasurementCorrections.cpp:293 (wrapped at "
        "Gnss.cpp:672, called at "
        "com_android_server_location_GnssLocationProvider.cpp:363)",
    "getExtensionGnssBatching":
        "boot: GnssLocationProvider.handleEnable -> GnssBatching.cpp:37 (wrapped "
        "at Gnss.cpp:646, called at "
        "com_android_server_location_GnssLocationProvider.cpp:871 from "
        "GnssLocationProvider.java:924)",
    "getExtensionGnssNavigationMessage":
        "any listener registration: GnssNavigationMessage.cpp:39 (wrapped at "
        "Gnss.cpp:511, called at "
        "com_android_server_location_GnssLocationProvider.cpp:758; advertised as "
        "supported at :743 whatever we return)",
}

AIDL_METHOD = re.compile(
    r"^\s*((?:@\w+(?:\([^)]*\))?\s+)*)[\w.]+\s+(getExtension\w+)\s*\(\s*\)\s*;", re.M)
BNGNSS_CLASS = re.compile(r"\bclass\s+(\w+)\s*:\s*public\s+BnGnss\s*\{")
MAIN_BODY = re.compile(r"\bint\s+main\s*\(")
MAKE = re.compile(r"ndk::SharedRefBase::make\s*<\s*(\w+)\s*>")
HAL_METHOD = re.compile(r"ScopedAStatus\s+(getExtension\w+)\s*\(")
GNSS_ROW = re.compile(r"^row\s+gnss\s+(\S+)\s+(\d+)\s+(\S+)\s+\d+\s+([0-9a-f]{40})", re.M)
REGISTER = "AServiceManager_addService"
GOOD_RHS = re.compile(r"^\s*ndk::SharedRefBase::make\s*<")


class Unanswerable(Exception):
    """exception for an unanswerable check"""


def read(path):
    """return the text of a file"""
    with open(path) as f:
        return f.read()


def strip_comments(text):
    """return the text without block and line comments"""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def nullable_by_method(aidl_text):
    """map getExtension methods to @nullable flags"""
    out = {}
    for annotations, name in AIDL_METHOD.findall(strip_comments(aidl_text)):
        out[name] = "@nullable" in annotations
    return out


def balanced(text, start, opener, closer):
    """return the index of the matching closer"""
    depth = 0
    i = start
    while i < len(text):
        if text[i] == opener:
            depth += 1
        elif text[i] == closer:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def registered_class_body(text):
    """return the body of the registered BnGnss class"""
    classes = {}
    for m in BNGNSS_CLASS.finditer(text):
        brace = text.index("{", m.end() - 1)
        end = balanced(text, brace, "{", "}")
        if end < 0:
            raise Unanswerable("class %s : public BnGnss has no balanced body" % m.group(1))
        classes[m.group(1)] = text[brace + 1:end]
    if not classes:
        raise Unanswerable("%s defines no `: public BnGnss` class" % HAL)
    mm = MAIN_BODY.search(text)
    if not mm:
        raise Unanswerable("%s has no main()" % HAL)
    args_end = balanced(text, mm.end() - 1, "(", ")")
    brace = text.find("{", args_end)
    end = balanced(text, brace, "{", "}") if brace >= 0 else -1
    if end < 0:
        raise Unanswerable("%s has no balanced main() body" % HAL)
    main_body = text[brace + 1:end]
    if REGISTER not in main_body:
        raise Unanswerable("%s's main() never calls %s" % (HAL, REGISTER))
    made = [n for n in MAKE.findall(main_body) if n in classes]
    if len(set(made)) != 1:
        raise Unanswerable(
            "main() constructs %s of the file's BnGnss subclasses (%s of %s), want 1"
            % (len(set(made)), sorted(set(made)) or "none", sorted(classes)))
    return made[0], classes[made[0]]


def split_params(params):
    """split a parameter list at top-level commas"""
    out, depth, cur = [], 0, ""
    for ch in params:
        if ch in "<([":
            depth += 1
        elif ch in ">)]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [p.strip() for p in out]


def accessors(class_body):
    """map accessor names to parameters and bodies"""
    found = {}
    duplicates = []
    for m in HAL_METHOD.finditer(class_body):
        name = m.group(1)
        args_end = balanced(class_body, m.end() - 1, "(", ")")
        if args_end < 0:
            continue
        brace = class_body.find("{", args_end)
        if brace < 0:
            continue
        body_end = balanced(class_body, brace, "{", "}")
        if body_end < 0:
            continue
        params = split_params(class_body[m.end():args_end])
        if name in found:
            duplicates.append(name)
        found[name] = (params, class_body[brace + 1:body_end])
    if duplicates:
        raise Unanswerable(
            "the registered implementation defines %s twice, so no verdict about "
            "%s can be trusted" % (", ".join(sorted(set(duplicates))),
                                   "them" if len(set(duplicates)) > 1 else "it"))
    return found


def judge_accessor(name, params, body):
    """return the reason an accessor fails"""
    if len(params) != 1:
        return ("%s takes %d parameters, want 1 out-parameter" % (name, len(params)))
    om = re.search(r"\*\s*(\w+)\s*$", params[0])
    if not om:
        return ("%s's parameter %r is not a recognizable out-pointer" % (name, params[0].strip()))
    out = om.group(1)

    writes = []
    for m in re.finditer(r"(\*\s*)?\b%s\s*=(?!=)" % re.escape(out), body):
        end = body.find(";", m.end())
        rhs = body[m.end():end if end >= 0 else len(body)]
        if m.group(1):
            writes.append((m.start(), "*%s = %s" % (out, rhs.strip()), rhs))
        else:
            writes.append((m.start(),
                           "%s = %s (rebinds the pointer, not the pointee)"
                           % (out, rhs.strip()), None))
    for m in re.finditer(r"\b%s\s*->\s*reset\s*\(" % re.escape(out), body):
        writes.append((m.start(), "%s->reset(...)" % out, None))
    writes.sort()

    if not writes:
        return ("%s never assigns to its out-parameter %s, the same as `*%s = nullptr;`" % (name, out, out))
    if len(writes) > 1:
        return ("%s writes its out-parameter %d times (%s), want exactly one "
                "ndk::SharedRefBase::make" % (name, len(writes),
                                          "; ".join(w[1] for w in writes)))
    pos, shown, rhs = writes[0]
    if rhs is None or not GOOD_RHS.match(rhs):
        return ("%s assigns `%s` to its out-parameter, which is not "
                "ndk::SharedRefBase::make<...>" % (name, shown))
    ret = re.search(r"\breturn\b", body)
    if ret and ret.start() < pos:
        return ("%s can return before it assigns its out-parameter (a `return` at "
                "offset %d precedes the assignment at %d)" % (name, ret.start(), pos))
    return None


def check(aidl_text, hal_text):
    """return the HAL accessor failures"""
    nullable = nullable_by_method(aidl_text)
    if not nullable:
        raise Unanswerable("the frozen IGnss dump declares no getExtension methods")
    text = strip_comments(hal_text)
    cls, body = registered_class_body(text)
    found = accessors(body)
    if not found:
        raise Unanswerable("the registered implementation %s defines no getExtension "
                           "methods" % cls)

    fails = []
    for name in sorted(DEREFERENCED):
        if name not in nullable:
            fails.append("%s is in DEREFERENCED, but the frozen IGnss dump has no such method" % name)
    for name in sorted(nullable):
        if name not in found:
            fails.append("the frozen IGnss dump declares %s and the registered "
                         "implementation %s does not override it" % (name, cls))
    for name in sorted(found):
        if name not in nullable:
            fails.append("%s overrides %s, which the frozen IGnss dump does not declare" % (cls, name))
    for name in sorted(found):
        params, abody = found[name]
        why = judge_accessor(name, params, abody)
        if why is None:
            continue
        if name in DEREFERENCED:
            fails.append("%s -- and the stock framework dereferences it: %s"
                         % (why, DEREFERENCED[name]))
        elif not nullable.get(name, False):
            fails.append("%s -- and it is NOT @nullable in the frozen IGnss dump" % why)
        else:
            fails.append("%s" % why)
    return fails


def frozen_dump(repo, aosp):
    """locate the frozen IGnss dump and its hash"""
    glue = os.path.join(repo, GLUE)
    if not os.path.exists(glue):
        raise Unanswerable("no %s to take the frozen gnss package, version and hash from" % GLUE)
    row = GNSS_ROW.search(read(glue))
    if not row:
        raise Unanswerable("%s has no `row gnss ...` line" % GLUE)
    pkg, ver, subdir, pinned = row.groups()
    dump = os.path.join(aosp, subdir, "aidl_api", pkg, ver)
    if not os.path.isdir(dump):
        raise Unanswerable(
            "no frozen AIDL dump at %s -- point RHIZO_AOSP_DIR at the "
            "aosp-android16-qpr2 checkout, or run tools/fetch/build-inputs.sh aosp"
            % dump)
    hashed = os.path.join(dump, ".hash")
    if not os.path.exists(hashed):
        raise Unanswerable("%s has no .hash" % dump)
    got = read(hashed).strip()
    if got != pinned:
        raise Unanswerable(
            "the frozen dump at %s hashes %s, not the %s pinned in %s"
            % (dump, got, pinned, GLUE))
    aidl = os.path.join(dump, pkg.replace(".", os.sep), "IGnss.aidl")
    if not os.path.exists(aidl):
        raise Unanswerable("no IGnss.aidl in the frozen dump at %s" % dump)
    return aidl, pinned, dump


def run(repo, aosp):
    """check the HAL against the frozen dump"""
    aidl, pinned, _ = frozen_dump(repo, aosp)
    hal = os.path.join(repo, HAL)
    if not os.path.exists(hal):
        raise Unanswerable("no %s" % HAL)
    return check(read(aidl), read(hal)), pinned


GOOD_AIDL = """\
package android.hardware.gnss;
@VintfStability
interface IGnss {
  void setCallback(in android.hardware.gnss.IGnssCallback callback);
  @nullable android.hardware.gnss.IGnssPsds getExtensionPsds();
  android.hardware.gnss.IGnssConfiguration getExtensionGnssConfiguration();
  @nullable android.hardware.gnss.IGnssBatching getExtensionGnssBatching();
  @nullable android.hardware.gnss.IGnssGeofence getExtensionGnssGeofence();
  @nullable android.hardware.gnss.IGnssNavigationMessageInterface getExtensionGnssNavigationMessage();
  @nullable android.hardware.gnss.measurement_corrections.IMeasurementCorrectionsInterface getExtensionMeasurementCorrections();
}
"""

GOOD_HAL = """\
class RhizoGnss : public BnGnss {
 public:
  ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssPsds>();
    return ScopedAStatus::ok();
  }
  ScopedAStatus getExtensionGnssConfiguration(std::shared_ptr<IGnssConfiguration>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssConfiguration>();
    return ScopedAStatus::ok();
  }
  ScopedAStatus getExtensionGnssBatching(std::shared_ptr<IGnssBatching>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssBatching>();
    return ScopedAStatus::ok();
  }
  ScopedAStatus getExtensionGnssGeofence(std::shared_ptr<IGnssGeofence>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssGeofence>();
    return ScopedAStatus::ok();
  }
  ScopedAStatus getExtensionGnssNavigationMessage(
      std::shared_ptr<IGnssNavigationMessageInterface>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssNavigationMessage>();
    return ScopedAStatus::ok();
  }
  ScopedAStatus getExtensionMeasurementCorrections(
      std::shared_ptr<measurement_corrections::IMeasurementCorrectionsInterface>* out) override {
    *out = ndk::SharedRefBase::make<RhizoMeasurementCorrections>();
    return ScopedAStatus::ok();
  }
};

int main() {
  auto device = ndk::SharedRefBase::make<RhizoGnss>();
  const std::string instance = std::string(RhizoGnss::descriptor) + "/default";
  binder_status_t status = AServiceManager_addService(device->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) return 1;
  ABinderProcess_joinThreadPool();
  return 0;
}
"""

PSDS_GOOD = "    *out = ndk::SharedRefBase::make<RhizoGnssPsds>();"

NULL_SHAPES = [
    ("the nullptr literal", "    *out = nullptr;"),
    ("a nullptr literal split across lines", "    *out =\n        nullptr;"),
    ("value-initialization", "    *out = {};"),
    ("a default-constructed shared_ptr", "    *out = std::shared_ptr<IGnssPsds>();"),
    ("assignment from a default-constructed local",
     "    std::shared_ptr<IGnssPsds> psds;\n    *out = psds;"),
    ("reset on the out-parameter", "    out->reset();"),
    ("the assignment deleted outright", ""),
    ("an early return in front of the assignment",
     "    if (!deviceGnssEnabled()) return ScopedAStatus::ok();\n" + PSDS_GOOD),
    ("rebinding the out-pointer instead of the pointee",
     "    out = nullptr;"),
]


def build_fixture(root, aidl_text, hal_text):
    """write a fixture repo and AOSP checkout"""
    repo = os.path.join(root, "repo")
    aosp = os.path.join(root, "aosp")
    dump = os.path.join(aosp, "hardware/interfaces/gnss/aidl/aidl_api/android.hardware.gnss/6")
    pkgdir = os.path.join(dump, "android/hardware/gnss")
    os.makedirs(pkgdir)
    os.makedirs(os.path.join(repo, os.path.dirname(GLUE)))
    os.makedirs(os.path.join(repo, os.path.dirname(HAL)))
    pinned = "da99c936e327ce4b93e04fdfa4c7770913667f21"
    with open(os.path.join(repo, GLUE), "w") as f:
        f.write("row gnss android.hardware.gnss 6 hardware/interfaces/gnss/aidl 29 %s\n" % pinned)
    with open(os.path.join(dump, ".hash"), "w") as f:
        f.write(pinned + "\n")
    with open(os.path.join(pkgdir, "IGnss.aidl"), "w") as f:
        f.write(aidl_text)
    with open(os.path.join(repo, HAL), "w") as f:
        f.write(hal_text)
    return repo, aosp


def nulled(name, replacement):
    """replace an accessor's assignment in GOOD_HAL"""
    good = "    *out = ndk::SharedRefBase::make<Rhizo%s>();" % {
        "getExtensionPsds": "GnssPsds",
        "getExtensionGnssBatching": "GnssBatching",
        "getExtensionGnssGeofence": "GnssGeofence",
        "getExtensionGnssNavigationMessage": "GnssNavigationMessage",
        "getExtensionMeasurementCorrections": "MeasurementCorrections",
        "getExtensionGnssConfiguration": "GnssConfiguration",
    }[name]
    if GOOD_HAL.count(good) != 1:
        raise AssertionError("fixture has %d copies of %s's assignment"
                             % (GOOD_HAL.count(good), name))
    if replacement == "":
        return GOOD_HAL.replace(good + "\n", "")
    return GOOD_HAL.replace(good, replacement)


def selftest():
    """run the checker on fixture HAL sources"""
    import shutil
    import tempfile
    root = tempfile.mkdtemp(prefix="check-gnss-extension-nulls.")
    bad = 0

    def want_flagged(label, hal, needle="", aidl=GOOD_AIDL):
        """check that a HAL source is flagged"""
        nonlocal bad
        try:
            fails = check(aidl, hal)
        except Unanswerable as e:
            if needle and needle not in str(e):
                print("SELFTEST FAIL: %s was refused, but not for the stated reason: %s"
                      % (label, e))
                bad += 1
            else:
                print("ok   selftest: %s is refused (%s)" % (label, str(e)[:60]))
            return
        if not fails or (needle and not any(needle in f for f in fails)):
            print("SELFTEST FAIL: %s was not flagged: %s" % (label, fails or "clean"))
            bad += 1
        else:
            print("ok   selftest: %s is flagged" % label)

    def want_clean(label, hal, aidl=GOOD_AIDL):
        """check that a HAL source is not flagged and not refused"""
        nonlocal bad
        try:
            fails = check(aidl, hal)
        except Unanswerable as e:
            print("SELFTEST FAIL: %s was refused: %s" % (label, e))
            bad += 1
            return
        if fails:
            print("SELFTEST FAIL: %s was flagged: %s" % (label, fails))
            bad += 1
        else:
            print("ok   selftest: %s is not flagged" % label)

    try:
        repo, aosp = build_fixture(os.path.join(root, "good"), GOOD_AIDL, GOOD_HAL)
        fails, _ = run(repo, aosp)
        if fails:
            print("SELFTEST FAIL: a HAL returning a real object from every extension "
                  "was flagged: %s" % fails)
            bad += 1
        else:
            print("ok   selftest: real objects everywhere are not flagged")

        for label, shape in NULL_SHAPES:
            want_flagged("PSDS by %s" % label, nulled("getExtensionPsds", shape),
                         "getExtensionPsds")

        for name in sorted(DEREFERENCED):
            hal = nulled(name, "    *out = nullptr;")
            try:
                fails = check(GOOD_AIDL, hal)
            except Unanswerable as e:
                print("SELFTEST FAIL: %s nulled was refused: %s" % (name, e))
                bad += 1
                continue
            if not any(f.startswith(name + " ") and "stock framework dereferences" in f
                       for f in fails):
                print("SELFTEST FAIL: %s nulled was not flagged by name with its "
                      "citation: %s" % (name, fails))
                bad += 1
            else:
                print("ok   selftest: %s nulled is flagged by name with its citation" % name)

        want_flagged("a nullptr from a non-@nullable extension, attributed to us",
                     nulled("getExtensionGnssConfiguration", "    *out = nullptr;"),
                     "NOT @nullable")

        flipped = GOOD_AIDL.replace(
            "@nullable android.hardware.gnss.IGnssPsds getExtensionPsds();",
            "android.hardware.gnss.IGnssPsds getExtensionPsds();")
        want_flagged("a nulled PSDS once the dump drops @nullable",
                     nulled("getExtensionPsds", "    *out = nullptr;"),
                     "getExtensionPsds", aidl=flipped)

        want_clean("a comment naming the defect beside a correct assignment",
                   nulled("getExtensionPsds",
                          "    // never `*out = nullptr;` here: GnssPsds.cpp:38 derefs it\n"
                          + PSDS_GOOD))

        decoy = ("class RhizoGnssDisabled : public BnGnss {\n"
                 " public:\n"
                 "  ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>* out) override {\n"
                 "    *out = nullptr;\n"
                 "    return ScopedAStatus::ok();\n"
                 "  }\n"
                 "};\n\n")
        want_clean("an unregistered decoy BnGnss class holding a null, before the real one",
                   decoy + GOOD_HAL)
        mirror = nulled("getExtensionPsds", "    *out = nullptr;")
        good_decoy = ("class RhizoGnssSpare : public BnGnss {\n"
                      " public:\n"
                      "  ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>* out) override {\n"
                      + PSDS_GOOD + "\n"
                      "    return ScopedAStatus::ok();\n"
                      "  }\n"
                      "};\n\n")
        want_flagged("a null in the REGISTERED class masked by a later correct decoy",
                     mirror + good_decoy, "getExtensionPsds")
        want_flagged("a duplicate definition of one accessor in the registered class",
                     GOOD_HAL.replace(
                         "  ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>* out) override {",
                         "  ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>* out) override {\n"
                         "    return ScopedAStatus::ok();\n"
                         "  }\n"
                         "  ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>* out) override {",
                         1),
                     "twice")
        want_flagged("a main() that registers nothing",
                     GOOD_HAL.replace(REGISTER, "SomethingElse"), REGISTER)

        shrunk = GOOD_AIDL.replace(
            "  @nullable android.hardware.gnss.IGnssPsds getExtensionPsds();\n", "")
        want_flagged("an accessor the frozen dump does not declare", GOOD_HAL,
                     "does not declare", aidl=shrunk)

        shrunkhal = nulled("getExtensionPsds", PSDS_GOOD)
        shrunkhal = re.sub(
            r"  ScopedAStatus getExtensionPsds\([^{]*\{[^}]*\}\n", "", shrunkhal)
        want_flagged("a fact table naming a method the dump lost", shrunkhal,
                     "has no such method", aidl=shrunk)

        dropped = re.sub(
            r"  ScopedAStatus getExtensionGnssGeofence\([^{]*\{[^}]*\}\n", "", GOOD_HAL)
        want_flagged("an unimplemented extension", dropped, "does not override it")

        repo, aosp = build_fixture(os.path.join(root, "moved"), GOOD_AIDL, GOOD_HAL)
        with open(os.path.join(
                aosp, "hardware/interfaces/gnss/aidl/aidl_api/android.hardware.gnss/6/.hash"),
                "w") as f:
            f.write("0000000000000000000000000000000000000000\n")
        try:
            run(repo, aosp)
            print("SELFTEST FAIL: a dump whose hash moved was judged anyway")
            bad += 1
        except Unanswerable:
            print("ok   selftest: a dump whose hash moved is refused")

        repo, _ = build_fixture(os.path.join(root, "noaosp"), GOOD_AIDL, GOOD_HAL)
        try:
            run(repo, os.path.join(root, "noaosp", "absent"))
            print("SELFTEST FAIL: a missing AOSP checkout passed")
            bad += 1
        except Unanswerable:
            print("ok   selftest: a missing AOSP checkout is refused")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    if bad:
        return 1
    print("check-gnss-extension-nulls selftest: every fixture was judged as it should be")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    aosp = os.environ.get("RHIZO_AOSP_DIR") or os.path.join(REPO, "aosp-android16-qpr2")
    try:
        fails, pinned = run(REPO, aosp)
    except Unanswerable as e:
        print("FAIL: %s" % e)
        return 1
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-gnss-extension-nulls: in %s, the registered IGnss implementation "
          "constructs a real object for every extension the framework dereferences "
          "(frozen dump %s). Source only; %s is checked by %s."
          % (HAL, pinned[:12], ARTIFACT, "tools/build/stamps.py"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
