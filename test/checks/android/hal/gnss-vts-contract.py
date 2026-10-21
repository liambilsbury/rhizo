#!/usr/bin/env python3

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(HERE))))
SRC_DIR = "src/android/hal/gnss/src"
HAL = SRC_DIR + "/gnss.cpp"
SIM = SRC_DIR + "/gnss_sim.h"
VTS = "hardware/interfaces/gnss/aidl/vts/gnss_hal_test_cases.cpp"

REQUIRED_CAPABILITIES = {
    "CAPABILITY_MEASUREMENTS": "GnssCapabilites expects it on a non-automotive device (%s:189)" % VTS,
    "CAPABILITY_SCHEDULING": "GnssCapabilites expects it (%s:191)" % VTS,
}
UNBACKED_CAPABILITIES = {
    "CAPABILITY_SATELLITE_BLOCKLIST": "setBlocklist stores nothing",
    "CAPABILITY_CORRELATION_VECTOR": "no correlation vectors are produced",
    "CAPABILITY_SATELLITE_PVT": "no SatellitePvt is produced",
    "CAPABILITY_ANTENNA_INFO": "no antenna info is produced",
    "CAPABILITY_MEASUREMENT_CORRECTIONS": "corrections are accepted and ignored",
    "CAPABILITY_ACCUMULATED_DELTA_RANGE": "no accumulated delta range is produced",
}
EMPTY_INPUT_ERRORS = {
    "injectPsdsData": "TestPsdsExtension asserts empty PSDS data fails (%s:335)" % VTS,
    "injectNiSuplMessageData": "TestAGnssRilExtension asserts an empty NI message fails (%s:1191)" % VTS,
    "injectGnssAssistance": "TestGnssAssistanceExtension asserts empty assistance fails (%s:1940)" % VTS,
}
ERROR_CALL = "fromServiceSpecificError(IGnss::ERROR_INVALID_ARGUMENT)"

HARNESS = r"""
#include "gnss_sim.h"
#include <cstdio>
using namespace rhizo_gnss_sim;
int main() {
  int minUsed = 1000, badCn0 = 0;
  for (int lat = -80; lat <= 80; lat += 20)
    for (int lon = -160; lon <= 160; lon += 40)
      for (int step = 0; step < 48; step++) {
        std::vector<Sat> v = visible(lat, lon, 1.4e9 + step * 1800.0);
        int used = 0;
        for (const Sat& s : v) {
          if (s.usedInFix) used++;
          if (!(s.cn0DbHz - 1.0 > 0.0 && s.cn0DbHz <= 65.0)) badCn0++;
        }
        if (used < minUsed) minUsed = used;
      }
  printf("min_used %d\nbad_cn0 %d\n", minUsed, badCn0);
  const int64_t off = -1;
  const int64_t levels[] = {1000, 2000, 4000, 20000, off};
  for (int64_t loc : levels)
    for (int64_t meas : levels) {
      Request r{loc != off, loc, meas != off, meas};
      printf("iv %lld %lld %lld %lld\n", (long long)loc, (long long)meas,
             (long long)measurementIntervalMs(r), (long long)svStatusIntervalMs(r));
    }
  return 0;
}
"""


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


def body_of(text, name):
    """return the body of the first function named name"""
    for m in re.finditer(r"\b%s\s*\(" % re.escape(name), text):
        paren = text.index("(", m.start())
        depth, i = 0, paren
        while i < len(text):
            depth += text[i] == "("
            depth -= text[i] == ")"
            i += 1
            if depth == 0:
                break
        rest = text[i:].lstrip()
        rest = re.sub(r"^(override|const|noexcept|\s)*", "", rest)
        if not rest.startswith("{"):
            continue
        start = text.index("{", i)
        depth, j = 0, start
        while j < len(text):
            depth += text[j] == "{"
            depth -= text[j] == "}"
            j += 1
            if depth == 0:
                return text[start:j]
    raise Unanswerable("%s defines no function %s" % (HAL, name))


def class_body(text, name):
    """return the brace-balanced body of the class named name"""
    m = re.search(r"\bclass\s+%s\b[^{;]*\{" % re.escape(name), text)
    if not m:
        raise Unanswerable("%s defines no class %s" % (HAL, name))
    depth, j = 1, m.end()
    while j < len(text) and depth:
        depth += text[j] == "{"
        depth -= text[j] == "}"
        j += 1
    return text[m.end():j]


def check_source(hal_text):
    """return the contract mismatches found by reading the HAL source"""
    text = strip_comments(hal_text)
    fails = []
    set_callback = body_of(class_body(text, "RhizoGnss"), "setCallback")
    caps = set(re.findall(r"CAPABILITY_\w+", set_callback))
    for cap, why in sorted(REQUIRED_CAPABILITIES.items()):
        if cap not in caps:
            fails.append("setCallback does not report %s. %s" % (cap, why))
    for cap, why in sorted(UNBACKED_CAPABILITIES.items()):
        if cap in caps:
            fails.append("setCallback reports %s but %s" % (cap, why))
    signals = re.search(r"gnssSetSignalTypeCapabilitiesCb\s*\(([^;]*)\)\s*;", set_callback)
    if not signals:
        fails.append("setCallback never calls gnssSetSignalTypeCapabilitiesCb (%s:164)" % VTS)
    elif re.fullmatch(r"\s*\{\s*\}\s*", signals.group(1)):
        fails.append("setCallback reports an empty signal type list; GnssCapabilites asserts it "
                     "is not empty (%s:196)" % VTS)
    power = body_of(class_body(text, "RhizoGnssPowerIndication"), "setCallback")
    if "setCapabilitiesCb" not in power:
        fails.append("the power indication setCallback never calls setCapabilitiesCb (%s:545)" % VTS)
    for name, why in sorted(EMPTY_INPUT_ERRORS.items()):
        if ERROR_CALL not in body_of(text, name):
            fails.append("%s never returns %s. %s" % (name, ERROR_CALL, why))
    if "timeEstimateMs" not in body_of(text, "debugData"):
        fails.append("getDebugData leaves DebugData.time unset (Utils.cpp:81)")
    if "setPositionIntervalMs(options.minIntervalMs)" not in body_of(text, "setPositionMode"):
        fails.append("setPositionMode does not store minIntervalMs (%s:240)" % VTS)
    if "isfinite" not in body_of(text, "parseFix"):
        fails.append("parseFix accepts a non-finite gnss_alt such as nan")
    return fails


def build_and_run(sim_text):
    """run the geometry and scheduling header in a harness"""
    cxx = shutil.which("c++") or shutil.which("g++") or shutil.which("clang++")
    if not cxx:
        raise Unanswerable("no c++ compiler to build the geometry and scheduling harness")
    root = tempfile.mkdtemp(prefix="check-gnss-vts-contract.")
    try:
        with open(os.path.join(root, "gnss_sim.h"), "w") as f:
            f.write(sim_text)
        with open(os.path.join(root, "harness.cc"), "w") as f:
            f.write(HARNESS)
        exe = os.path.join(root, "harness")
        cp = subprocess.run([cxx, "-std=c++17", "-I", root, os.path.join(root, "harness.cc"),
                             "-o", exe], capture_output=True, text=True)
        if cp.returncode:
            raise Unanswerable("the geometry and scheduling header does not compile: %s"
                               % cp.stderr.strip()[:400])
        out = subprocess.run([exe], capture_output=True, text=True, timeout=120)
        if out.returncode:
            raise Unanswerable("the harness exited %d" % out.returncode)
        return out.stdout.splitlines()
    finally:
        shutil.rmtree(root, ignore_errors=True)


def check_behavior(sim_text):
    """check the contract by running the header"""
    values, table = {}, {}
    for line in build_and_run(sim_text):
        parts = line.split()
        if parts[0] == "iv":
            table[(int(parts[1]), int(parts[2]))] = (int(parts[3]), int(parts[4]))
        else:
            values[parts[0]] = int(parts[1])
    fails = []
    if values["min_used"] < 4:
        fails.append("a receiver tracks only %d satellites used in a fix somewhere on the grid, want 4"
                     % values["min_used"])
    if values["bad_cn0"]:
        fails.append("%d tracked satellites report a baseband C/N0 outside (0, 65] dB-Hz "
                     "(%s:310, gnss_hal_test.cpp:395)" % (values["bad_cn0"], VTS))
    off = -1
    for (loc, meas), (m_iv, sv_iv) in sorted(table.items()):
        active = [x for x in (loc, meas) if x != off]
        if meas != off:
            want_meas = min(loc, max(meas, 1000)) if loc != off else max(meas, 1000)
            if m_iv != want_meas:
                fails.append("location %s ms, measurement %d ms: measurements arrive every %d ms, "
                             "want %d (TestGnssMeasurementIntervals_*)"
                             % ("off" if loc == off else loc, meas, m_iv, want_meas))
        if active:
            want_sv = min(max(x, 1000) for x in active)
            if sv_iv != want_sv:
                fails.append("location %s ms, measurement %s ms: satellite status arrives every "
                             "%d ms, want %d (TestSvStatusIntervals)"
                             % ("off" if loc == off else loc, "off" if meas == off else meas,
                                sv_iv, want_sv))
    return fails


def run(repo):
    """return the contract mismatches of the HAL source and header"""
    hal, sim = os.path.join(repo, HAL), os.path.join(repo, SIM)
    for path in (hal, sim):
        if not os.path.exists(path):
            raise Unanswerable("no %s" % os.path.relpath(path, repo))
    return check_source(read(hal)) + check_behavior(read(sim))


def selftest():
    """run both halves on defective copies of the real files"""
    bad = 0
    hal, sim = read(os.path.join(REPO, HAL)), read(os.path.join(REPO, SIM))

    def mutate(text, old, new, label):
        """return a copy of text with a required edit applied"""
        if text.count(old) != 1:
            raise Unanswerable("the selftest fixture for %s no longer matches %s" % (label, old))
        return text.replace(old, new)

    def want(label, fails, needle):
        """report whether a defect was flagged"""
        nonlocal bad
        if any(needle in f for f in fails):
            print("ok   selftest: %s is flagged" % label)
        else:
            print("SELFTEST FAIL: %s was not flagged: %s" % (label, fails or "clean"))
            bad += 1

    base = check_source(hal)
    if base:
        print("SELFTEST FAIL: the real HAL source was flagged: %s" % base)
        bad += 1
    else:
        print("ok   selftest: the real HAL source is not flagged")
    base = check_behavior(sim)
    if base:
        print("SELFTEST FAIL: the real header was flagged: %s" % base)
        bad += 1
    else:
        print("ok   selftest: the real header is not flagged")

    want("MEASUREMENTS capability dropped",
         check_source(mutate(hal, "IGnssCallback::CAPABILITY_SCHEDULING |\n"
                             "                                    IGnssCallback::CAPABILITY_MEASUREMENTS",
                             "IGnssCallback::CAPABILITY_SCHEDULING", "capabilities")),
         "CAPABILITY_MEASUREMENTS")
    want("SCHEDULING capability dropped",
         check_source(mutate(hal, "IGnssCallback::CAPABILITY_SCHEDULING |\n"
                             "                                    IGnssCallback::CAPABILITY_MEASUREMENTS",
                             "IGnssCallback::CAPABILITY_MEASUREMENTS", "capabilities")),
         "CAPABILITY_SCHEDULING")
    want("a blocklist capability the HAL cannot back",
         check_source(mutate(hal, "IGnssCallback::CAPABILITY_SCHEDULING |",
                             "IGnssCallback::CAPABILITY_SATELLITE_BLOCKLIST | "
                             "IGnssCallback::CAPABILITY_SCHEDULING |", "capabilities")),
         "CAPABILITY_SATELLITE_BLOCKLIST")
    want("an empty signal type list",
         check_source(mutate(hal, "gnssSetSignalTypeCapabilitiesCb({gpsL1Signal()})",
                             "gnssSetSignalTypeCapabilitiesCb({})", "signal types")),
         "empty signal type list")
    want("power indication that never reports capabilities",
         check_source(mutate(hal, "return callback->setCapabilitiesCb(0);",
                             "return ScopedAStatus::ok();", "power")),
         "never calls setCapabilitiesCb")
    for name in sorted(EMPTY_INPUT_ERRORS):
        at = re.search(r"ScopedAStatus\s+%s\(" % name, hal).start()
        call = "ScopedAStatus::" + ERROR_CALL
        if call not in hal[at:]:
            raise Unanswerable("the selftest fixture for %s no longer matches %s" % (name, call))
        broken = hal[:at] + hal[at:].replace(call, "ScopedAStatus::ok()", 1)
        want("%s accepting empty input" % name, check_source(broken), name)
    want("debug data without a time",
         check_source(mutate(hal, "data.time.timeEstimateMs = nowMillis();", "", "debug")),
         "DebugData.time")
    want("a gnss_alt of nan accepted",
         check_source(mutate(hal, "!std::isfinite(valt) || ", "", "gnss_alt")),
         "non-finite gnss_alt")
    want("a position interval that is not stored",
         check_source(mutate(hal, "receiver_->setPositionIntervalMs(options.minIntervalMs);", "",
                             "position")),
         "setPositionMode")
    want("a constellation too small for a fix",
         check_behavior(mutate(sim, "k < 30", "k < 4", "constellation")),
         "satellites used in a fix")
    want("measurements slower than the location interval",
         check_behavior(mutate(sim, "return r.locationActive ? std::min(r.locationMs, m) : m;",
                               "return m;", "measurement interval")),
         "measurements arrive every")
    want("satellite status slower than the fastest consumer",
         check_behavior(mutate(sim, "return std::min(r.locationMs, measurementIntervalMs(r));",
                               "return r.locationMs;", "sv interval")),
         "satellite status arrives every")
    if bad:
        return 1
    print("check-gnss-vts-contract selftest: every fixture was judged as it should be")
    return 0


def main():
    """run the check or its selftest and print the result"""
    try:
        if "--selftest" in sys.argv[1:]:
            return selftest()
        fails = run(REPO)
    except Unanswerable as e:
        print("FAIL: %s" % e)
        return 1
    for f in fails:
        print("FAIL: %s" % f)
    if fails:
        return 1
    print("check-gnss-vts-contract: %s meets the capability, callback, empty-input, satellite "
          "and interval requirements read from %s and %s" % (HAL, VTS, "gnss_hal_test.cpp"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
