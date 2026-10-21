#!/usr/bin/env python3

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
GLUE = "tools/build/toolchain/regen-aidl-glue.sh"
HAL = "src/android/hal/gnss/src/gnss.cpp"
HEADER = "toolchain/gen/gnss/header/aidl/android/hardware/gnss/GnssLocation.h"
ARTIFACT = "var/share/gfx_hal/rhizo-gnss-service"

UNGATED = {
    "gnssLocationFlags": "the flag word itself",
    "timestampMillis": "always read -- Utils.cpp:193 SET(Time, ...) is outside every if",
    "elapsedRealtime": "carries its own ElapsedRealtime.flags word (Utils.cpp:195)",
}
REQUIRED = {
    "HAS_LAT_LONG":
        "LocationResult.validate() refuses a location with no usable lat/lng "
        "(LocationResult.java:128-134)",
    "HAS_HORIZONTAL_ACCURACY":
        "LocationResult.validate() throws BadLocationException(\"location must have "
        "accuracy\") without it (LocationResult.java:136-138, Utils.cpp:181-183)",
}

ZERO_IS_VALUE = {
    "speedMetersPerSec":
        "the reported position is the operator's fixed point (Utils.h:105)",
}
ZERO_NEEDS_FLAG = "HAS_SPEED_ACCURACY"
OPERATOR_ONLY = {
    "HAS_ALTITUDE": "the operator supplied no altitude unless `rhizo device set gps` was given one",
    "HAS_VERTICAL_ACCURACY": "a vertical accuracy only means something beside an altitude the operator supplied",
}
OPERATOR_GUARD = re.compile(r"if\s*\(\s*fix\.hasAltitude\s*\)\s*\{([^{}]*)\}")
CLASS = re.compile(r"\bclass\s+GnssLocation\s*\{")
MEMBER = re.compile(r"^  (?!static|typedef|inline|enum|public|private)"
                    r"(?:::)?[A-Za-z_][\w:<>, ]*?[\s>]([A-Za-z_]\w*)\s*(?:=\s*[^;]*)?;\s*$",
                    re.M)
FLAG_ENUM = re.compile(r"enum\s*:\s*int32_t\s*\{\s*(HAS_\w+)\s*=\s*(\d+)\s*\}")
HEADER_HASH = re.compile(r"--hash=([0-9a-f]{40})")
GNSS_ROW = re.compile(r"^row\s+gnss\s+(\S+)\s+(\d+)\s+(\S+)\s+\d+\s+([0-9a-f]{40})", re.M)
DECL = re.compile(r"\bGnssLocation\s+(\w+)\s*;")
FLAGS_OK = re.compile(r"^GnssLocation::HAS_\w+(\s*\|\s*GnssLocation::HAS_\w+)*$")
LITERAL_ZERO = re.compile(r"^-?0(\.0*)?[fF]?$")


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


def parse_header(text):
    """return the field names and HAS_ flags"""
    m = CLASS.search(text)
    if not m:
        raise Unanswerable("%s declares no `class GnssLocation`" % HEADER)
    brace = text.index("{", m.end() - 1)
    end = balanced(text, brace, "{", "}")
    if end < 0:
        raise Unanswerable("%s's GnssLocation has no balanced body" % HEADER)
    body = text[brace + 1:end]
    cut = body.find("inline bool operator")
    fields = MEMBER.findall(body[:cut if cut >= 0 else len(body)])
    flags = {name: int(bit) for name, bit in FLAG_ENUM.findall(body)}
    if not fields:
        raise Unanswerable("no GnssLocation fields parsed out of %s" % HEADER)
    if not flags:
        raise Unanswerable("no HAS_* flags parsed out of %s" % HEADER)
    return fields, flags


def map_flags(fields, flags):
    """map each HAS_ flag to its fields"""
    gated = [f for f in fields if f not in UNGATED]
    missing = [f for f in UNGATED if f not in fields]
    if missing:
        raise Unanswerable(
            "%s no longer declares %s, an UNGATED field"
            % (HEADER, ", ".join(sorted(missing))))
    claimed = {}
    mapping = {}
    for flag in sorted(flags, key=lambda f: -len(f)):
        tokens = [t.lower() for t in flag[len("HAS_"):].split("_")]
        joined = "".join(tokens)
        hit = [f for f in gated if f.lower().startswith(joined) and f not in claimed]
        if not hit and len(tokens) > 1:
            hit = []
            for t in tokens:
                per = [f for f in gated if f.lower().startswith(t) and f not in claimed]
                if len(per) != 1:
                    hit = None
                    break
                hit.append(per[0])
            if hit is None:
                hit = []
        if not hit:
            raise Unanswerable(
                "%s in %s matches no GnssLocation field"
                % (flag, HEADER))
        for f in hit:
            claimed[f] = flag
        mapping[flag] = sorted(hit)
    orphan = [f for f in gated if f not in claimed]
    if orphan:
        raise Unanswerable(
            "GnssLocation field(s) %s are governed by no HAS_* flag"
            % ", ".join(sorted(orphan)))
    return mapping


def parse_hal(text):
    """return the flags and field assignments"""
    decls = DECL.findall(text)
    if len(decls) != 1:
        raise Unanswerable(
            "%s declares %d GnssLocation locals, want 1" % (HAL, len(decls)))
    var = decls[0]
    start = DECL.search(text).end()
    assigns = {}
    for m in re.finditer(r"\b%s\.(\w+)(?:\.\w+)*\s*=\s*([^;]*);" % re.escape(var),
                         text[start:]):
        field, rhs = m.group(1), " ".join(m.group(2).split())
        assigns.setdefault(field, rhs)
    if "gnssLocationFlags" not in assigns:
        raise Unanswerable("%s never assigns %s.gnssLocationFlags" % (HAL, var))
    expr = assigns["gnssLocationFlags"]
    if not FLAGS_OK.match(expr):
        raise Unanswerable(
            "%s.gnssLocationFlags is assigned %r, which is not a plain OR of "
            "GnssLocation::HAS_* constants" % (var, expr))
    flags = set(re.findall(r"HAS_\w+", expr))
    problems = []
    for flag in sorted(flags & set(OPERATOR_ONLY)):
        problems.append("%s is set on every report, but %s" % (flag, OPERATOR_ONLY[flag]))
    guarded = [g.span(1) for g in OPERATOR_GUARD.finditer(text)]
    for m in re.finditer(r"\b%s\.gnssLocationFlags\s*\|=\s*([^;]*);" % re.escape(var), text):
        rhs = " ".join(m.group(1).split())
        if not FLAGS_OK.match(rhs):
            raise Unanswerable(
                "%s.gnssLocationFlags |= %r is not a plain OR of GnssLocation::HAS_* constants"
                % (var, rhs))
        added = set(re.findall(r"HAS_\w+", rhs))
        flags |= added
        inside = any(lo <= m.start() < hi for lo, hi in guarded)
        for flag in sorted(added & set(OPERATOR_ONLY)):
            if not inside:
                problems.append("%s is set outside `if (fix.hasAltitude)`, but %s"
                                % (flag, OPERATOR_ONLY[flag]))
    return flags, assigns, problems


def check(header_text, hal_text):
    """return the flag and field mismatches"""
    fields, flags = parse_header(header_text)
    mapping = map_flags(fields, flags)
    set_flags, assigns, fails = parse_hal(strip_comments(hal_text))

    unknown = sorted(set_flags - set(flags))
    if unknown:
        raise Unanswerable(
            "the HAL sets %s, which %s does not declare" % (", ".join(unknown), HEADER))

    for flag, why in sorted(REQUIRED.items()):
        if flag not in flags:
            fails.append("%s is required but %s does not declare it" % (flag, HEADER))
        elif flag not in set_flags:
            fails.append("the reported GnssLocation does not set %s. %s" % (flag, why))

    field_flag = {f: fl for fl, fs in mapping.items() for f in fs}

    for field in sorted(assigns):
        if field in UNGATED:
            continue
        if field not in field_flag:
            fails.append("the HAL assigns %s, which %s does not declare as a "
                         "GnssLocation field" % (field, HEADER))
            continue
        if LITERAL_ZERO.match(assigns[field]):
            continue
        flag = field_flag[field]
        if flag not in set_flags:
            fails.append(
                "the HAL assigns %s = %s but never sets %s"
                % (field, assigns[field], flag))

    for flag in sorted(set_flags):
        for field in mapping.get(flag, []):
            if field not in assigns:
                fails.append(
                    "the HAL sets %s but never assigns %s" % (flag, field))
            elif LITERAL_ZERO.match(assigns[field]) and not (
                    field in ZERO_IS_VALUE and ZERO_NEEDS_FLAG in set_flags):
                fails.append(
                    "the HAL sets %s while assigning %s = %s, the AIDL's unset value"
                    % (flag, field, assigns[field]))
    return fails


def frozen_hash(repo):
    """return the pinned gnss hash from the glue file"""
    glue = os.path.join(repo, GLUE)
    if not os.path.exists(glue):
        raise Unanswerable("no %s to take the pinned gnss hash from" % GLUE)
    row = GNSS_ROW.search(read(glue))
    if not row:
        raise Unanswerable("%s has no `row gnss ...` line" % GLUE)
    return row.group(4)


def run(repo):
    """check the HAL against the generated header"""
    pinned = frozen_hash(repo)
    header = os.path.join(repo, HEADER)
    if not os.path.exists(header):
        raise Unanswerable(
            "no generated header at %s -- run tools/build/toolchain/regen-aidl-glue.sh --only gnss"
            % HEADER)
    header_text = read(header)
    hm = HEADER_HASH.search(header_text[:8192])
    if not hm:
        raise Unanswerable("%s carries no --hash= provenance line" % HEADER)
    if hm.group(1) != pinned:
        raise Unanswerable(
            "%s was generated from hash %s, not the %s pinned in %s -- run "
            "tools/build/toolchain/regen-aidl-glue.sh --only gnss"
            % (HEADER, hm.group(1), pinned, GLUE))
    hal = os.path.join(repo, HAL)
    if not os.path.exists(hal):
        raise Unanswerable("no %s" % HAL)
    return check(header_text, read(hal)), pinned


GOOD_HEADER = """\
/* Using: aidl --lang=ndk --hash=da99c936e327ce4b93e04fdfa4c7770913667f21 */
#pragma once
namespace gnss {
class GnssLocation {
public:
  typedef std::false_type fixed_size;
  static const char* descriptor;

  int32_t gnssLocationFlags = 0;
  double latitudeDegrees = 0.000000;
  double longitudeDegrees = 0.000000;
  double altitudeMeters = 0.000000;
  double speedMetersPerSec = 0.000000;
  double bearingDegrees = 0.000000;
  double horizontalAccuracyMeters = 0.000000;
  double verticalAccuracyMeters = 0.000000;
  double speedAccuracyMetersPerSecond = 0.000000;
  double bearingAccuracyDegrees = 0.000000;
  int64_t timestampMillis = 0L;
  ::aidl::android::hardware::gnss::ElapsedRealtime elapsedRealtime;
  inline bool operator==(const GnssLocation& _rhs) const { return true; }
  enum : int32_t { HAS_LAT_LONG = 1 };
  enum : int32_t { HAS_ALTITUDE = 2 };
  enum : int32_t { HAS_SPEED = 4 };
  enum : int32_t { HAS_BEARING = 8 };
  enum : int32_t { HAS_HORIZONTAL_ACCURACY = 16 };
  enum : int32_t { HAS_VERTICAL_ACCURACY = 32 };
  enum : int32_t { HAS_SPEED_ACCURACY = 64 };
  enum : int32_t { HAS_BEARING_ACCURACY = 128 };
};
}
"""

FLAGS_LINE = ("          loc.gnssLocationFlags = GnssLocation::HAS_LAT_LONG | "
              "GnssLocation::HAS_HORIZONTAL_ACCURACY;")
ACC_LINE = "          loc.horizontalAccuracyMeters = 5.0;"

GOOD_HAL = """\
  void pollLoop() {
    while (running_) {
      if (ReadState(&state) && parseFix(state, &lat, &lon)) {
        if (cb) {
          GnssLocation loc;
%s
          loc.latitudeDegrees = lat;
          loc.longitudeDegrees = lon;
          loc.altitudeMeters = 0;
          loc.speedMetersPerSec = 0;
          loc.bearingDegrees = 0;
%s
          loc.verticalAccuracyMeters = 0;
          loc.speedAccuracyMetersPerSecond = 0;
          loc.bearingAccuracyDegrees = 0;
          loc.timestampMillis = nowMillis();
          loc.elapsedRealtime.flags = ElapsedRealtime::HAS_TIMESTAMP_NS;
          loc.elapsedRealtime.timestampNs = nowBootNanos();
          loc.elapsedRealtime.timeUncertaintyNs = 0;
          cb->gnssLocationCb(loc);
        }
      }
    }
  }
""" % (FLAGS_LINE, ACC_LINE)


def build_fixture(root, header_text, hal_text):
    """write a fixture repo tree"""
    repo = os.path.join(root, "repo")
    os.makedirs(os.path.join(repo, os.path.dirname(GLUE)))
    os.makedirs(os.path.join(repo, os.path.dirname(HAL)))
    os.makedirs(os.path.join(repo, os.path.dirname(HEADER)))
    pinned = "da99c936e327ce4b93e04fdfa4c7770913667f21"
    with open(os.path.join(repo, GLUE), "w") as f:
        f.write("row gnss android.hardware.gnss 6 hardware/interfaces/gnss/aidl 29 %s\n" % pinned)
    with open(os.path.join(repo, HEADER), "w") as f:
        f.write(header_text)
    with open(os.path.join(repo, HAL), "w") as f:
        f.write(hal_text)
    return repo


def selftest():
    """run the checker on fixture sources"""
    import shutil
    import tempfile
    root = tempfile.mkdtemp(prefix="check-gnss-location-flags.")
    bad = 0

    def want_flagged(label, hal, needle="", header=GOOD_HEADER):
        """check that a HAL source is flagged"""
        nonlocal bad
        try:
            fails = check(header, hal)
        except Unanswerable as e:
            if needle and needle not in str(e):
                print("SELFTEST FAIL: %s was refused, but not for the stated reason: %s"
                      % (label, e))
                bad += 1
            else:
                print("ok   selftest: %s is refused (%s)" % (label, str(e)[:64]))
            return
        if not fails or (needle and not any(needle in f for f in fails)):
            print("SELFTEST FAIL: %s was not flagged: %s" % (label, fails or "clean"))
            bad += 1
        else:
            print("ok   selftest: %s is flagged" % label)

    def want_clean(label, hal, header=GOOD_HEADER):
        """check that a HAL source is not flagged and not refused"""
        nonlocal bad
        try:
            fails = check(header, hal)
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
        repo = build_fixture(os.path.join(root, "good"), GOOD_HEADER, GOOD_HAL)
        fails, _ = run(repo)
        if fails:
            print("SELFTEST FAIL: a correctly flagged GnssLocation was flagged: %s" % fails)
            bad += 1
        else:
            print("ok   selftest: a correctly flagged GnssLocation is not flagged")

        want_flagged("accuracy assigned with HAS_HORIZONTAL_ACCURACY omitted",
                     GOOD_HAL.replace(
                         FLAGS_LINE,
                         "          loc.gnssLocationFlags = GnssLocation::HAS_LAT_LONG;"),
                     "HAS_HORIZONTAL_ACCURACY")
        want_flagged("altitude given a real value with HAS_ALTITUDE omitted",
                     GOOD_HAL.replace("          loc.altitudeMeters = 0;",
                                      "          loc.altitudeMeters = 120.5;"),
                     "HAS_ALTITUDE")
        want_flagged("lat/lon assigned with HAS_LAT_LONG omitted",
                     GOOD_HAL.replace(
                         FLAGS_LINE,
                         "          loc.gnssLocationFlags = "
                         "GnssLocation::HAS_HORIZONTAL_ACCURACY;"),
                     "HAS_LAT_LONG")

        want_flagged("HAS_ALTITUDE set while altitudeMeters stays the unset zero",
                     GOOD_HAL.replace(FLAGS_LINE,
                                      FLAGS_LINE[:-1] + " | GnssLocation::HAS_ALTITUDE;"),
                     "unset value")
        want_flagged("HAS_BEARING set while bearingDegrees stays the unset zero",
                     GOOD_HAL.replace(FLAGS_LINE,
                                      FLAGS_LINE[:-1] + " | GnssLocation::HAS_BEARING;"),
                     "unset value")
        stationary = GOOD_HAL.replace(
            FLAGS_LINE, FLAGS_LINE[:-1] + " | GnssLocation::HAS_SPEED"
            " | GnssLocation::HAS_SPEED_ACCURACY;").replace(
            "          loc.speedAccuracyMetersPerSecond = 0;",
            "          loc.speedAccuracyMetersPerSecond = 1.0;")
        want_clean("a zero speed stated by a speed accuracy", stationary)
        want_flagged("a zero speed with no speed accuracy beside it",
                     stationary.replace(" | GnssLocation::HAS_SPEED_ACCURACY;", ";")
                               .replace("          loc.speedAccuracyMetersPerSecond = 1.0;\n", ""),
                     "unset value")
        operator_altitude = (
            "          if (fix.hasAltitude) {\n"
            "            loc.gnssLocationFlags |= GnssLocation::HAS_ALTITUDE"
            " | GnssLocation::HAS_VERTICAL_ACCURACY;\n"
            "            loc.altitudeMeters = fix.altitudeMeters;\n"
            "            loc.verticalAccuracyMeters = 10.0;\n"
            "          }\n")
        no_altitude = (GOOD_HAL.replace("          loc.altitudeMeters = 0;\n", "")
                               .replace("          loc.verticalAccuracyMeters = 0;\n", ""))
        guarded = no_altitude.replace("          loc.timestampMillis", operator_altitude
                                      + "          loc.timestampMillis")
        want_clean("HAS_ALTITUDE and HAS_VERTICAL_ACCURACY only beside an operator altitude",
                   guarded)
        want_flagged("HAS_ALTITUDE added outside the operator-altitude guard",
                     guarded.replace("if (fix.hasAltitude) {", "{"),
                     "outside `if (fix.hasAltitude)`")
        want_flagged("HAS_ALTITUDE in the flag word of every report",
                     no_altitude.replace(FLAGS_LINE, FLAGS_LINE[:-1] + " | GnssLocation::HAS_ALTITUDE;")
                                .replace("          loc.timestampMillis",
                                         "          loc.altitudeMeters = fix.altitudeMeters;\n"
                                         "          loc.timestampMillis"),
                     "set on every report")
        want_flagged("HAS_SPEED set with no speedMetersPerSec assignment at all",
                     GOOD_HAL.replace(FLAGS_LINE,
                                      FLAGS_LINE[:-1] + " | GnssLocation::HAS_SPEED;")
                              .replace("          loc.speedMetersPerSec = 0;\n", ""),
                     "never assigns speedMetersPerSec")
        want_flagged("HAS_VERTICAL_ACCURACY set over the unset zero",
                     GOOD_HAL.replace(
                         FLAGS_LINE,
                         FLAGS_LINE[:-1] + " | GnssLocation::HAS_VERTICAL_ACCURACY;"),
                     "verticalAccuracyMeters")

        want_flagged("neither required bit set",
                     GOOD_HAL.replace(FLAGS_LINE,
                                      "          loc.gnssLocationFlags = "
                                      "GnssLocation::HAS_ALTITUDE;")
                              .replace(ACC_LINE, "          loc.horizontalAccuracyMeters = 0;")
                              .replace("          loc.latitudeDegrees = lat;",
                                       "          loc.latitudeDegrees = 0;")
                              .replace("          loc.longitudeDegrees = lon;",
                                       "          loc.longitudeDegrees = 0;")
                              .replace("          loc.altitudeMeters = 0;",
                                       "          loc.altitudeMeters = 3.0;"),
                     "must have")

        want_clean("altitude, speed and bearing left at the unset zero, unflagged",
                   GOOD_HAL)

        want_flagged("a flag word computed instead of written",
                     GOOD_HAL.replace(FLAGS_LINE,
                                      "          loc.gnssLocationFlags = flagsFor(state);"),
                     "not a plain OR")
        want_flagged("a flag word written as a bare integer",
                     GOOD_HAL.replace(FLAGS_LINE,
                                      "          loc.gnssLocationFlags = 17;"),
                     "not a plain OR")
        want_flagged("a bit the generated header does not declare",
                     GOOD_HAL.replace(FLAGS_LINE,
                                      FLAGS_LINE[:-1] + " | GnssLocation::HAS_MADE_UP;"),
                     "does not declare")
        want_flagged("two GnssLocation locals",
                     GOOD_HAL.replace("          GnssLocation loc;",
                                      "          GnssLocation loc;\n          GnssLocation spare;"),
                     "declares 2 GnssLocation locals")
        want_flagged("no flag word assigned at all",
                     GOOD_HAL.replace(FLAGS_LINE + "\n", ""),
                     "never assigns")

        want_clean("a comment naming the missing bit beside a correct flag word",
                   GOOD_HAL.replace(
                       FLAGS_LINE,
                       "          // never HAS_LAT_LONG alone: Utils.cpp:181 needs the "
                       "accuracy bit\n" + FLAGS_LINE))

        want_flagged("a header flag matching no field",
                     GOOD_HAL, "matches no GnssLocation field",
                     header=GOOD_HEADER.replace(
                         "  enum : int32_t { HAS_ALTITUDE = 2 };",
                         "  enum : int32_t { HAS_ALTITUDE = 2 };\n"
                         "  enum : int32_t { HAS_TROPOSPHERE = 256 };"))
        want_flagged("a header field governed by no flag",
                     GOOD_HAL, "governed by no HAS_* flag",
                     header=GOOD_HEADER.replace(
                         "  double altitudeMeters = 0.000000;",
                         "  double altitudeMeters = 0.000000;\n"
                         "  double ionoDelayMeters = 0.000000;"))
        want_flagged("an exempt field renamed out of the header",
                     GOOD_HAL, "an UNGATED field",
                     header=GOOD_HEADER.replace("int64_t timestampMillis = 0L;",
                                                "int64_t timestampMicros = 0L;"))
        mapping = map_flags(*parse_header(GOOD_HEADER))
        if mapping.get("HAS_SPEED") != ["speedMetersPerSec"] or \
                mapping.get("HAS_SPEED_ACCURACY") != ["speedAccuracyMetersPerSecond"] or \
                mapping.get("HAS_LAT_LONG") != ["latitudeDegrees", "longitudeDegrees"]:
            print("SELFTEST FAIL: the derived mapping is wrong: %s" % mapping)
            bad += 1
        else:
            print("ok   selftest: HAS_SPEED, HAS_SPEED_ACCURACY and HAS_LAT_LONG map correctly")

        repo = build_fixture(os.path.join(root, "moved"),
                             GOOD_HEADER.replace("da99c936e327ce4b93e04fdfa4c7770913667f21",
                                                 "0" * 40),
                             GOOD_HAL)
        try:
            run(repo)
            print("SELFTEST FAIL: a header from another hash was judged anyway")
            bad += 1
        except Unanswerable:
            print("ok   selftest: a header from another hash is refused")

        repo = build_fixture(os.path.join(root, "noheader"), GOOD_HEADER, GOOD_HAL)
        os.remove(os.path.join(repo, HEADER))
        try:
            run(repo)
            print("SELFTEST FAIL: a missing generated header passed")
            bad += 1
        except Unanswerable:
            print("ok   selftest: a missing generated header is refused")
    finally:
        shutil.rmtree(root, ignore_errors=True)
    if bad:
        return 1
    print("check-gnss-location-flags selftest: every fixture was judged as it should be")
    return 0


def main():
    """run the check or its selftest and print the result"""
    if "--selftest" in sys.argv[1:]:
        return selftest()
    try:
        fails, pinned = run(REPO)
    except Unanswerable as e:
        print("FAIL: %s" % e)
        return 1
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-gnss-location-flags: in %s, every GnssLocation value carries its own "
          "HAS_* bit and every bit carries a value, and the framework's floor "
          "(HAS_LAT_LONG | HAS_HORIZONTAL_ACCURACY) is met (header pinned %s). "
          "Source only; %s is checked by tools/build/stamps.py."
          % (HAL, pinned[:12], ARTIFACT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
