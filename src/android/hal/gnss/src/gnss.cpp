#include "aidl/android/hardware/gnss/BnAGnss.h"
#include "aidl/android/hardware/gnss/BnAGnssRil.h"
#include "aidl/android/hardware/gnss/BnGnss.h"
#include "aidl/android/hardware/gnss/BnGnssAntennaInfo.h"
#include "aidl/android/hardware/gnss/BnGnssBatching.h"
#include "aidl/android/hardware/gnss/BnGnssConfiguration.h"
#include "aidl/android/hardware/gnss/BnGnssDebug.h"
#include "aidl/android/hardware/gnss/BnGnssGeofence.h"
#include "aidl/android/hardware/gnss/BnGnssMeasurementInterface.h"
#include "aidl/android/hardware/gnss/BnGnssNavigationMessageInterface.h"
#include "aidl/android/hardware/gnss/BnGnssPowerIndication.h"
#include "aidl/android/hardware/gnss/BnGnssPsds.h"
#include "aidl/android/hardware/gnss/gnss_assistance/BnGnssAssistanceInterface.h"
#include "aidl/android/hardware/gnss/measurement_corrections/BnMeasurementCorrectionsInterface.h"
#include "aidl/android/hardware/gnss/visibility_control/BnGnssVisibilityControl.h"
#include "rhizo/device_state.h"
#include "gnss_host.h"
#include "gnss_sim.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <fcntl.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <condition_variable>
#include <cstdlib>
#include <ctime>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace aidl::android::hardware::gnss;
using ndk::ScopedAStatus;

namespace {

// write a message to the kernel log
void klog(const char* msg) { rhizo_device::Klog("rhizo-gnss", msg); }

// operator-set position
struct Fix {
  double latitudeDegrees;
  double longitudeDegrees;
  bool hasAltitude;
  double altitudeMeters;
};

// parse gnss_lat, gnss_lon and gnss_alt from state
bool parseFix(const std::map<std::string, std::string>& state, Fix* fix) {
  auto la = state.find("gnss_lat");
  auto lo = state.find("gnss_lon");
  if (la == state.end() && lo == state.end()) return false;
  if (la == state.end() || lo == state.end()) {
    klog("device-state.conf: gnss_lat and gnss_lon must both be set, ignoring");
    return false;
  }
  char* end = nullptr;
  double vlat = strtod(la->second.c_str(), &end);
  bool okLat = end != la->second.c_str() && *end == '\0' && vlat >= -90.0 && vlat <= 90.0;
  end = nullptr;
  double vlon = strtod(lo->second.c_str(), &end);
  bool okLon = end != lo->second.c_str() && *end == '\0' && vlon >= -180.0 && vlon <= 180.0;
  if (!okLat || !okLon) {
    char buf[224];
    snprintf(buf, sizeof(buf),
             "device-state.conf: bad gnss fix lat='%s' lon='%s' (want -90..90 / -180..180), ignoring",
             la->second.c_str(), lo->second.c_str());
    klog(buf);
    return false;
  }
  if (vlat == 0.0 && vlon == 0.0) {
    klog("device-state.conf: gnss fix 0,0 is refused by the framework as the null "
         "island; set a real gnss_lat/gnss_lon, ignoring");
    return false;
  }
  fix->latitudeDegrees = vlat;
  fix->longitudeDegrees = vlon;
  fix->hasAltitude = false;
  fix->altitudeMeters = 0;
  auto al = state.find("gnss_alt");
  if (al == state.end()) return true;
  double valt = strtod(al->second.c_str(), &end);
  if (end == al->second.c_str() || *end != '\0' || !std::isfinite(valt) || valt < -1000.0 ||
      valt > 30000.0) {
    char buf[160];
    snprintf(buf, sizeof(buf), "device-state.conf: bad gnss_alt='%s' (want -1000..30000), no altitude",
             al->second.c_str());
    klog(buf);
    return true;
  }
  fix->hasAltitude = true;
  fix->altitudeMeters = valt;
  return true;
}

// return the wall-clock time in milliseconds
int64_t nowMillis() {
  timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// return the boot-time clock in nanoseconds
int64_t nowBootNanos() {
  timespec ts;
  clock_gettime(CLOCK_BOOTTIME, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

using SteadyClock = std::chrono::steady_clock;
namespace sim = rhizo_gnss_sim;

constexpr std::chrono::milliseconds kFirstEpochDelay{250};
constexpr double kHorizontalAccuracyMeters = 5.0;
constexpr double kVerticalAccuracyMeters = 10.0;
constexpr double kUnknownAltitudeAccuracyMeters = 20000.0;
constexpr double kSpeedAccuracyMetersPerSecond = 1.0;
constexpr int kSystemInfoYear = 2024;

// return the GPS L1 signal type
GnssSignalType gpsL1Signal() {
  GnssSignalType signal;
  signal.constellation = GnssConstellationType::GPS;
  signal.carrierFrequencyHz = sim::kL1Hz;
  signal.codeType = GnssSignalType::CODE_TYPE_C;
  return signal;
}

// build the GNSS system info
IGnssCallback::GnssSystemInfo systemInfo(bool host) {
  IGnssCallback::GnssSystemInfo info;
  info.yearOfHw = host ? 0 : kSystemInfoYear;
  info.name = host ? "rhizo-host-location" : "rhizo-gnss";
  return info;
}

// software receiver reporting the operator's fix
class Receiver {
 public:
  // start the scheduling thread
  Receiver() : thread_([this] { run(); }) {}
  // stop the scheduling thread
  ~Receiver() {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      quit_ = true;
    }
    cv_.notify_all();
    thread_.join();
  }

  // store the callback for location and satellite status
  void setGnssCallback(const std::shared_ptr<IGnssCallback>& callback) {
    std::lock_guard<std::mutex> lg(mutex_);
    gnssCallback_ = callback;
  }
  // return the stored location callback
  std::shared_ptr<IGnssCallback> gnssCallback() {
    std::lock_guard<std::mutex> lg(mutex_);
    return gnssCallback_;
  }
  // store the requested time between locations
  void setPositionIntervalMs(int64_t intervalMs) {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      positionIntervalMs_ = std::max(intervalMs, sim::kMinPositionIntervalMs);
    }
    cv_.notify_all();
  }
  // begin location reports
  void startLocation() { activate(&location_); }
  // end location reports
  void stopLocation() { deactivate(&location_); }
  // begin satellite status reports
  void startSvStatus() { activate(&svStatus_); }
  // end satellite status reports
  void stopSvStatus() { deactivate(&svStatus_); }
  // begin measurement reports
  void startMeasurement(const std::shared_ptr<IGnssMeasurementCallback>& callback,
                        int64_t intervalMs, bool fullTracking) {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      measurementCallback_ = callback;
      measurementIntervalMs_ = intervalMs;
      fullTracking_ = fullTracking;
      begin(&measurement_);
    }
    cv_.notify_all();
  }
  // stop measurement reports
  void stopMeasurement() {
    deactivate(&measurement_);
    std::lock_guard<std::mutex> lg(mutex_);
    measurementCallback_.reset();
  }
  // stop all of the reports
  void closeAll() {
    stopLocation();
    stopSvStatus();
    stopMeasurement();
    std::lock_guard<std::mutex> lg(mutex_);
    gnssCallback_.reset();
    positionIntervalMs_ = sim::kDefaultSvIntervalMs;
  }
  // read the operator's fix from state
  bool readFix(Fix* fix) const {
    std::map<std::string, std::string> state;
    return rhizo_device::ReadState(&state) && parseFix(state, fix);
  }
  // return debug data for the current fix
  IGnssDebug::DebugData debugData() const {
    IGnssDebug::DebugData data;
    data.time.timeEstimateMs = nowMillis();
    data.time.timeUncertaintyNs = 1.0e6f;
    data.time.frequencyUncertaintyNsPerSec = 100.0f;
    Fix fix;
    if (!readFix(&fix)) return data;
    data.position.valid = true;
    data.position.latitudeDegrees = fix.latitudeDegrees;
    data.position.longitudeDegrees = fix.longitudeDegrees;
    data.position.horizontalAccuracyMeters = kHorizontalAccuracyMeters;
    data.position.altitudeMeters = static_cast<float>(fix.altitudeMeters);
    data.position.verticalAccuracyMeters =
        fix.hasAltitude ? kVerticalAccuracyMeters : kUnknownAltitudeAccuracyMeters;
    data.position.speedAccuracyMetersPerSecond = kSpeedAccuracyMetersPerSecond;
    data.position.bearingAccuracyDegrees = 180.0;
    for (const sim::Sat& sat : sim::visible(fix.latitudeDegrees, fix.longitudeDegrees, gpsSeconds())) {
      IGnssDebug::SatelliteData entry;
      entry.svid = sat.svid;
      entry.constellation = GnssConstellationType::GPS;
      entry.ephemerisType = IGnssDebug::SatelliteEphemerisType::EPHEMERIS;
      entry.ephemerisSource = SatellitePvt::SatelliteEphemerisSource::OTHER;
      entry.ephemerisHealth = IGnssDebug::SatelliteEphemerisHealth::GOOD;
      data.satelliteDataArray.push_back(entry);
    }
    return data;
  }

 private:
  // timing of a report stream
  struct Stream {
    bool active = false;
    bool emitted = false;
    SteadyClock::time_point firstAt;
    SteadyClock::time_point last;
  };

  // return the GPS seconds since the GPS epoch
  static double gpsSeconds() {
    return static_cast<double>(nowMillis()) / 1000.0 - sim::kGpsToUnixSeconds + sim::kGpsLeapSeconds;
  }
  // mark a stream active
  static void begin(Stream* stream) {
    stream->active = true;
    stream->emitted = false;
    stream->firstAt = SteadyClock::now() + kFirstEpochDelay;
  }
  // start a stream
  void activate(Stream* stream) {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (stream->active) return;
      begin(stream);
    }
    cv_.notify_all();
  }
  // stop a stream
  void deactivate(Stream* stream) {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      stream->active = false;
    }
    cv_.notify_all();
    std::lock_guard<std::mutex> dispatchGuard(dispatch_);
  }
  // return when a stream's next report is due
  static SteadyClock::time_point dueAt(const Stream& stream, int64_t intervalMs) {
    return stream.emitted ? stream.last + std::chrono::milliseconds(intervalMs) : stream.firstAt;
  }

  // send reports at each stream's interval
  void run() {
    std::unique_lock<std::mutex> lk(mutex_);
    while (!quit_) {
      sim::Request request{location_.active, positionIntervalMs_, measurement_.active,
                           measurementIntervalMs_};
      const int64_t intervalsMs[3] = {positionIntervalMs_, sim::svStatusIntervalMs(request),
                                      sim::measurementIntervalMs(request)};
      Stream* streams[3] = {&location_, &svStatus_, &measurement_};
      bool any = false;
      SteadyClock::time_point earliest;
      for (int i = 0; i < 3; i++) {
        if (!streams[i]->active) continue;
        auto due = dueAt(*streams[i], intervalsMs[i]);
        if (!any || due < earliest) earliest = due;
        any = true;
      }
      if (!any) {
        cv_.wait(lk);
        continue;
      }
      auto now = SteadyClock::now();
      if (earliest > now) {
        cv_.wait_until(lk, earliest);
        continue;
      }
      bool report[3] = {false, false, false};
      for (int i = 0; i < 3; i++) {
        if (!streams[i]->active) continue;
        auto due = dueAt(*streams[i], intervalsMs[i]);
        if (due > now) continue;
        report[i] = true;
        streams[i]->last = (now - due > std::chrono::milliseconds(intervalsMs[i])) ? now : due;
        streams[i]->emitted = true;
      }
      auto gnssCallback = gnssCallback_;
      auto measurementCallback = measurementCallback_;
      bool fullTracking = fullTracking_;
      std::unique_lock<std::mutex> dispatchLock(dispatch_);
      lk.unlock();
      sendReports(report[0] ? gnssCallback : nullptr, report[1] ? gnssCallback : nullptr,
                  report[2] ? measurementCallback : nullptr, fullTracking);
      dispatchLock.unlock();
      lk.lock();
    }
  }

  // send the reports that are due
  void sendReports(const std::shared_ptr<IGnssCallback>& locationCallback,
                   const std::shared_ptr<IGnssCallback>& svStatusCallback,
                   const std::shared_ptr<IGnssMeasurementCallback>& measurementCallback,
                   bool fullTracking) const {
    Fix fix;
    if (!readFix(&fix)) return;
    if (locationCallback) {
      GnssLocation loc;
      loc.gnssLocationFlags = GnssLocation::HAS_LAT_LONG | GnssLocation::HAS_SPEED |
                              GnssLocation::HAS_HORIZONTAL_ACCURACY | GnssLocation::HAS_SPEED_ACCURACY;
      loc.latitudeDegrees = fix.latitudeDegrees;
      loc.longitudeDegrees = fix.longitudeDegrees;
      loc.speedMetersPerSec = 0;
      loc.horizontalAccuracyMeters = kHorizontalAccuracyMeters;
      if (fix.hasAltitude) {
        loc.gnssLocationFlags |= GnssLocation::HAS_ALTITUDE | GnssLocation::HAS_VERTICAL_ACCURACY;
        loc.altitudeMeters = fix.altitudeMeters;
        loc.verticalAccuracyMeters = kVerticalAccuracyMeters;
      }
      loc.speedAccuracyMetersPerSecond = kSpeedAccuracyMetersPerSecond;
      loc.timestampMillis = nowMillis();
      loc.elapsedRealtime.flags = ElapsedRealtime::HAS_TIMESTAMP_NS;
      loc.elapsedRealtime.timestampNs = nowBootNanos();
      loc.elapsedRealtime.timeUncertaintyNs = 0;
      locationCallback->gnssLocationCb(loc);
    }
    if (!svStatusCallback && !measurementCallback) return;
    std::vector<sim::Sat> sats =
        sim::visible(fix.latitudeDegrees, fix.longitudeDegrees, gpsSeconds());
    if (svStatusCallback) svStatusCallback->gnssSvStatusCb(svInfoList(sats));
    if (measurementCallback) measurementCallback->gnssMeasurementCb(measurementData(sats, fullTracking));
  }

  // return the satellite status list
  static std::vector<IGnssCallback::GnssSvInfo> svInfoList(const std::vector<sim::Sat>& sats) {
    std::vector<IGnssCallback::GnssSvInfo> list;
    for (const sim::Sat& sat : sats) {
      IGnssCallback::GnssSvInfo info;
      info.svid = sat.svid;
      info.constellation = GnssConstellationType::GPS;
      info.cN0Dbhz = static_cast<float>(sat.cn0DbHz);
      info.basebandCN0DbHz = static_cast<float>(sat.cn0DbHz - 1.0);
      info.elevationDegrees = static_cast<float>(sat.elevationDeg);
      info.azimuthDegrees = static_cast<float>(sat.azimuthDeg);
      info.carrierFrequencyHz = static_cast<int64_t>(sim::kL1Hz);
      info.svFlag = static_cast<int32_t>(IGnssCallback::GnssSvFlags::HAS_EPHEMERIS_DATA) |
                    static_cast<int32_t>(IGnssCallback::GnssSvFlags::HAS_ALMANAC_DATA) |
                    static_cast<int32_t>(IGnssCallback::GnssSvFlags::HAS_CARRIER_FREQUENCY) |
                    (sat.usedInFix ? static_cast<int32_t>(IGnssCallback::GnssSvFlags::USED_IN_FIX) : 0);
      list.push_back(info);
    }
    return list;
  }

  // return a measurement report
  static GnssData measurementData(const std::vector<sim::Sat>& sats, bool fullTracking) {
    GnssData data;
    int64_t bootNs = nowBootNanos();
    double unixSeconds = static_cast<double>(nowMillis()) / 1000.0;
    int64_t gpsNs = static_cast<int64_t>((unixSeconds - sim::kGpsToUnixSeconds +
                                          sim::kGpsLeapSeconds) * 1.0e9);
    data.clock.gnssClockFlags = GnssClock::HAS_LEAP_SECOND | GnssClock::HAS_FULL_BIAS;
    data.clock.leapSecond = sim::kGpsLeapSeconds;
    data.clock.timeNs = bootNs;
    data.clock.fullBiasNs = bootNs - gpsNs;
    data.elapsedRealtime.flags = ElapsedRealtime::HAS_TIMESTAMP_NS;
    data.elapsedRealtime.timestampNs = bootNs;
    data.isFullTracking = fullTracking;
    GnssData::GnssAgc agc;
    agc.constellation = GnssConstellationType::GPS;
    agc.carrierFrequencyHz = static_cast<int64_t>(sim::kL1Hz);
    data.gnssAgcs.push_back(agc);
    double towNs = sim::gpsTimeOfWeekSeconds(unixSeconds) * 1.0e9;
    for (const sim::Sat& sat : sats) {
      if (!sat.usedInFix) continue;
      GnssMeasurement m;
      m.svid = sat.svid;
      m.signalType = gpsL1Signal();
      m.state = GnssMeasurement::STATE_CODE_LOCK | GnssMeasurement::STATE_BIT_SYNC |
                GnssMeasurement::STATE_SUBFRAME_SYNC | GnssMeasurement::STATE_TOW_DECODED;
      m.receivedSvTimeInNs = static_cast<int64_t>(towNs - sat.rangeM / sim::kSpeedOfLight * 1.0e9);
      m.receivedSvTimeUncertaintyInNs = 10;
      m.antennaCN0DbHz = sat.cn0DbHz;
      m.basebandCN0DbHz = sat.cn0DbHz - 1.0;
      m.pseudorangeRateMps = sat.rangeRateMps;
      m.pseudorangeRateUncertaintyMps = 1.0;
      data.measurements.push_back(m);
    }
    return data;
  }

  std::mutex mutex_;
  std::mutex dispatch_;
  std::condition_variable cv_;
  bool quit_ = false;
  std::shared_ptr<IGnssCallback> gnssCallback_;
  std::shared_ptr<IGnssMeasurementCallback> measurementCallback_;
  int64_t positionIntervalMs_ = sim::kDefaultSvIntervalMs;
  int64_t measurementIntervalMs_ = sim::kDefaultSvIntervalMs;
  bool fullTracking_ = false;
  Stream location_;
  Stream svStatus_;
  Stream measurement_;
  std::thread thread_;
};

class RhizoGnssConfiguration : public BnGnssConfiguration {
 public:
  // ignore the SUPL version
  ScopedAStatus setSuplVersion(int32_t) override { return ScopedAStatus::ok(); }
  // ignore the SUPL mode
  ScopedAStatus setSuplMode(int32_t) override { return ScopedAStatus::ok(); }
  // ignore the LPP profile
  ScopedAStatus setLppProfile(int32_t) override { return ScopedAStatus::ok(); }
  // ignore the GLONASS positioning protocol
  ScopedAStatus setGlonassPositioningProtocol(int32_t) override { return ScopedAStatus::ok(); }
  // ignore the emergency SUPL PDN setting
  ScopedAStatus setEmergencySuplPdn(bool) override { return ScopedAStatus::ok(); }
  // ignore the emergency extension seconds
  ScopedAStatus setEsExtensionSec(int32_t) override { return ScopedAStatus::ok(); }
  // ignore the blocklist
  ScopedAStatus setBlocklist(const std::vector<BlocklistedSource>&) override { return ScopedAStatus::ok(); }
};

class RhizoGnssMeasurement : public BnGnssMeasurementInterface {
 public:
  // share the receiver
  explicit RhizoGnssMeasurement(std::shared_ptr<Receiver> receiver) : receiver_(std::move(receiver)) {}
  // start measurements at the default interval
  ScopedAStatus setCallback(const std::shared_ptr<IGnssMeasurementCallback>& callback,
                            bool enableFullTracking, bool) override {
    if (!callback) return ScopedAStatus::fromServiceSpecificError(IGnss::ERROR_INVALID_ARGUMENT);
    receiver_->startMeasurement(callback, sim::kDefaultSvIntervalMs, enableFullTracking);
    return ScopedAStatus::ok();
  }
  // stop measurement reports
  ScopedAStatus close() override {
    receiver_->stopMeasurement();
    return ScopedAStatus::ok();
  }
  // start measurements at the requested interval
  ScopedAStatus setCallbackWithOptions(const std::shared_ptr<IGnssMeasurementCallback>& callback,
                                        const IGnssMeasurementInterface::Options& options) override {
    if (!callback) return ScopedAStatus::fromServiceSpecificError(IGnss::ERROR_INVALID_ARGUMENT);
    receiver_->startMeasurement(callback, options.intervalMs, options.enableFullTracking);
    return ScopedAStatus::ok();
  }

 private:
  std::shared_ptr<Receiver> receiver_;
};

class RhizoGnssPowerIndication : public BnGnssPowerIndication {
 public:
  // report that no power statistics are supported
  ScopedAStatus setCallback(const std::shared_ptr<IGnssPowerIndicationCallback>& callback) override {
    if (!callback) return ScopedAStatus::fromServiceSpecificError(IGnss::ERROR_INVALID_ARGUMENT);
    return callback->setCapabilitiesCb(0);
  }
  // accept the power stats request
  ScopedAStatus requestGnssPowerStats() override {
    return ScopedAStatus::ok();
  }
};

class RhizoAGnss : public BnAGnss {
 public:
  // ignore the AGNSS callback
  ScopedAStatus setCallback(const std::shared_ptr<IAGnssCallback>&) override { return ScopedAStatus::ok(); }
  // ignore the data connection closing
  ScopedAStatus dataConnClosed() override { return ScopedAStatus::ok(); }
  // ignore the data connection failing
  ScopedAStatus dataConnFailed() override { return ScopedAStatus::ok(); }
  // ignore the server setting
  ScopedAStatus setServer(IAGnssCallback::AGnssType, const std::string&, int32_t) override {
    return ScopedAStatus::ok();
  }
  // ignore the data connection opening
  ScopedAStatus dataConnOpen(int64_t, const std::string&, IAGnss::ApnIpType) override {
    return ScopedAStatus::ok();
  }
};

class RhizoAGnssRil : public BnAGnssRil {
 public:
  // ignore the AGNSS RIL callback
  ScopedAStatus setCallback(const std::shared_ptr<IAGnssRilCallback>&) override { return ScopedAStatus::ok(); }
  // ignore the reference location
  ScopedAStatus setRefLocation(const IAGnssRil::AGnssRefLocation&) override { return ScopedAStatus::ok(); }
  // ignore the set id
  ScopedAStatus setSetId(IAGnssRil::SetIdType, const std::string&) override { return ScopedAStatus::ok(); }
  // ignore the network state
  ScopedAStatus updateNetworkState(const IAGnssRil::NetworkAttributes&) override { return ScopedAStatus::ok(); }
  // reject an empty NI SUPL message
  ScopedAStatus injectNiSuplMessageData(const std::vector<uint8_t>& message, int32_t) override {
    if (message.empty()) return ScopedAStatus::fromServiceSpecificError(IGnss::ERROR_INVALID_ARGUMENT);
    return ScopedAStatus::ok();
  }
};

class RhizoGnssDebug : public BnGnssDebug {
 public:
  // share the receiver
  explicit RhizoGnssDebug(std::shared_ptr<Receiver> receiver) : receiver_(std::move(receiver)) {}
  // return debug data for the operator's fix
  ScopedAStatus getDebugData(IGnssDebug::DebugData* out) override {
    *out = receiver_ ? receiver_->debugData() : IGnssDebug::DebugData();
    return ScopedAStatus::ok();
  }

 private:
  std::shared_ptr<Receiver> receiver_;
};

class RhizoGnssAntennaInfo : public BnGnssAntennaInfo {
 public:
  // ignore the antenna info callback
  ScopedAStatus setCallback(const std::shared_ptr<IGnssAntennaInfoCallback>&) override {
    return ScopedAStatus::ok();
  }
  // do nothing on close
  ScopedAStatus close() override { return ScopedAStatus::ok(); }
};

class RhizoGnssVisibilityControl : public visibility_control::BnGnssVisibilityControl {
 public:
  // ignore the NFW location access list
  ScopedAStatus enableNfwLocationAccess(const std::vector<std::string>&) override {
    return ScopedAStatus::ok();
  }
  // ignore the visibility control callback
  ScopedAStatus setCallback(
      const std::shared_ptr<visibility_control::IGnssVisibilityControlCallback>&) override {
    return ScopedAStatus::ok();
  }
};

class RhizoGnssAssistance : public gnss_assistance::BnGnssAssistanceInterface {
 public:
  // reject assistance data without GPS ephemeris
  ScopedAStatus injectGnssAssistance(const gnss_assistance::GnssAssistance& assistance) override {
    if (!assistance.gpsAssistance || assistance.gpsAssistance->satelliteEphemeris.empty())
      return ScopedAStatus::fromServiceSpecificError(IGnss::ERROR_INVALID_ARGUMENT);
    return ScopedAStatus::ok();
  }
  // ignore the assistance callback
  ScopedAStatus setCallback(const std::shared_ptr<gnss_assistance::IGnssAssistanceCallback>&) override {
    return ScopedAStatus::ok();
  }
};

class RhizoGnssPsds : public BnGnssPsds {
 public:
  // ignore the PSDS callback
  ScopedAStatus setCallback(const std::shared_ptr<IGnssPsdsCallback>&) override {
    return ScopedAStatus::ok();
  }
  // reject empty PSDS data
  ScopedAStatus injectPsdsData(PsdsType, const std::vector<uint8_t>& data) override {
    if (data.empty()) return ScopedAStatus::fromServiceSpecificError(IGnss::ERROR_INVALID_ARGUMENT);
    return ScopedAStatus::ok();
  }
};

class RhizoGnssBatching : public BnGnssBatching {
 public:
  // ignore the batching callback
  ScopedAStatus init(const std::shared_ptr<IGnssBatchingCallback>&) override {
    return ScopedAStatus::ok();
  }
  // return a batch size of zero
  ScopedAStatus getBatchSize(int32_t* out) override {
    *out = 0;
    return ScopedAStatus::ok();
  }
  // ignore starting batching
  ScopedAStatus start(const IGnssBatching::Options&) override { return ScopedAStatus::ok(); }
  // ignore flushing
  ScopedAStatus flush() override { return ScopedAStatus::ok(); }
  // ignore stopping batching
  ScopedAStatus stop() override { return ScopedAStatus::ok(); }
  // ignore cleanup
  ScopedAStatus cleanup() override { return ScopedAStatus::ok(); }
};

class RhizoGnssGeofence : public BnGnssGeofence {
 public:
  // accept the geofence callback
  ScopedAStatus setCallback(const std::shared_ptr<IGnssGeofenceCallback>&) override {
    return ScopedAStatus::ok();
  }
  // accept the geofence
  ScopedAStatus addGeofence(int32_t, double, double, double, int32_t, int32_t, int32_t,
                            int32_t) override {
    return ScopedAStatus::ok();
  }
  // ignore pausing a geofence
  ScopedAStatus pauseGeofence(int32_t) override { return ScopedAStatus::ok(); }
  // ignore resuming a geofence
  ScopedAStatus resumeGeofence(int32_t, int32_t) override { return ScopedAStatus::ok(); }
  // ignore removing a geofence
  ScopedAStatus removeGeofence(int32_t) override { return ScopedAStatus::ok(); }
};

class RhizoGnssNavigationMessage : public BnGnssNavigationMessageInterface {
 public:
  // accept the navigation message callback
  ScopedAStatus setCallback(const std::shared_ptr<IGnssNavigationMessageCallback>&) override {
    return ScopedAStatus::ok();
  }
  // do nothing on close
  ScopedAStatus close() override { return ScopedAStatus::ok(); }
};

class RhizoMeasurementCorrections
    : public measurement_corrections::BnMeasurementCorrectionsInterface {
 public:
  // accept the measurement corrections
  ScopedAStatus setCorrections(
      const measurement_corrections::MeasurementCorrections&) override {
    return ScopedAStatus::ok();
  }
  // ignore the measurement corrections callback
  ScopedAStatus setCallback(
      const std::shared_ptr<measurement_corrections::IMeasurementCorrectionsCallback>&)
      override {
    return ScopedAStatus::ok();
  }
};

class RhizoGnss : public BnGnss {
 public:
  // use the host source or the operator's receiver
  explicit RhizoGnss(std::shared_ptr<rhizo_gnss_host::HostSource> host)
      : host_(std::move(host)), receiver_(host_ ? nullptr : std::make_shared<Receiver>()) {}
  // store the callback and report capabilities
  ScopedAStatus setCallback(const std::shared_ptr<IGnssCallback>& callback) override {
    if (!callback) return ScopedAStatus::fromServiceSpecificError(IGnss::ERROR_INVALID_ARGUMENT);
    if (host_) {
      host_->setCallback(callback);
      callback->gnssSetSystemInfoCb(systemInfo(true));
      return ScopedAStatus::ok();
    }
    receiver_->setGnssCallback(callback);
    callback->gnssSetCapabilitiesCb(IGnssCallback::CAPABILITY_SCHEDULING |
                                    IGnssCallback::CAPABILITY_MEASUREMENTS);
    callback->gnssSetSystemInfoCb(systemInfo(false));
    callback->gnssSetSignalTypeCapabilitiesCb({gpsL1Signal()});
    return ScopedAStatus::ok();
  }
  // stop all of the reports
  ScopedAStatus close() override {
    if (host_) {
      host_->close();
    } else {
      receiver_->closeAll();
    }
    return ScopedAStatus::ok();
  }
  // return a PSDS interface
  ScopedAStatus getExtensionPsds(std::shared_ptr<IGnssPsds>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssPsds>();
    return ScopedAStatus::ok();
  }
  // return a GNSS configuration interface
  ScopedAStatus getExtensionGnssConfiguration(std::shared_ptr<IGnssConfiguration>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssConfiguration>();
    return ScopedAStatus::ok();
  }
  // return a GNSS measurement interface
  ScopedAStatus getExtensionGnssMeasurement(std::shared_ptr<IGnssMeasurementInterface>* out) override {
    if (host_) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    *out = ndk::SharedRefBase::make<RhizoGnssMeasurement>(receiver_);
    return ScopedAStatus::ok();
  }
  // return a GNSS power indication interface
  ScopedAStatus getExtensionGnssPowerIndication(std::shared_ptr<IGnssPowerIndication>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssPowerIndication>();
    return ScopedAStatus::ok();
  }
  // return a GNSS batching interface
  ScopedAStatus getExtensionGnssBatching(std::shared_ptr<IGnssBatching>* out) override {
    if (host_) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    *out = ndk::SharedRefBase::make<RhizoGnssBatching>();
    return ScopedAStatus::ok();
  }
  // return a GNSS geofence interface
  ScopedAStatus getExtensionGnssGeofence(std::shared_ptr<IGnssGeofence>* out) override {
    if (host_) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    *out = ndk::SharedRefBase::make<RhizoGnssGeofence>();
    return ScopedAStatus::ok();
  }
  // return a GNSS navigation message interface
  ScopedAStatus getExtensionGnssNavigationMessage(
      std::shared_ptr<IGnssNavigationMessageInterface>* out) override {
    if (host_) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    *out = ndk::SharedRefBase::make<RhizoGnssNavigationMessage>();
    return ScopedAStatus::ok();
  }
  // return an AGNSS interface
  ScopedAStatus getExtensionAGnss(std::shared_ptr<IAGnss>* out) override {
    *out = ndk::SharedRefBase::make<RhizoAGnss>();
    return ScopedAStatus::ok();
  }
  // return an AGNSS RIL interface
  ScopedAStatus getExtensionAGnssRil(std::shared_ptr<IAGnssRil>* out) override {
    *out = ndk::SharedRefBase::make<RhizoAGnssRil>();
    return ScopedAStatus::ok();
  }
  // return a GNSS debug interface
  ScopedAStatus getExtensionGnssDebug(std::shared_ptr<IGnssDebug>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssDebug>(receiver_);
    return ScopedAStatus::ok();
  }
  // return a GNSS visibility control interface
  ScopedAStatus getExtensionGnssVisibilityControl(
      std::shared_ptr<visibility_control::IGnssVisibilityControl>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssVisibilityControl>();
    return ScopedAStatus::ok();
  }
  // start location reports
  ScopedAStatus start() override {
    std::shared_ptr<IGnssCallback> cb = host_ ? host_->callback() : receiver_->gnssCallback();
    if (host_) {
      host_->start();
    } else {
      receiver_->startLocation();
    }
    if (cb) cb->gnssStatusCb(IGnssCallback::GnssStatusValue::SESSION_BEGIN);
    return ScopedAStatus::ok();
  }
  // stop location reports
  ScopedAStatus stop() override {
    if (host_) {
      host_->stop();
    } else {
      receiver_->stopLocation();
    }
    std::shared_ptr<IGnssCallback> cb = host_ ? host_->callback() : receiver_->gnssCallback();
    if (cb) cb->gnssStatusCb(IGnssCallback::GnssStatusValue::SESSION_END);
    return ScopedAStatus::ok();
  }
  // ignore the injected time
  ScopedAStatus injectTime(int64_t, int64_t, int32_t) override { return ScopedAStatus::ok(); }
  // ignore the injected location
  ScopedAStatus injectLocation(const GnssLocation&) override { return ScopedAStatus::ok(); }
  // ignore the injected best location
  ScopedAStatus injectBestLocation(const GnssLocation&) override { return ScopedAStatus::ok(); }
  // ignore deleting aiding data
  ScopedAStatus deleteAidingData(IGnss::GnssAidingData) override { return ScopedAStatus::ok(); }
  // store the interval between locations
  ScopedAStatus setPositionMode(const IGnss::PositionModeOptions& options) override {
    if (host_) {
      host_->setPositionIntervalMs(options.minIntervalMs);
    } else {
      receiver_->setPositionIntervalMs(options.minIntervalMs);
    }
    return ScopedAStatus::ok();
  }
  // return a GNSS antenna info interface
  ScopedAStatus getExtensionGnssAntennaInfo(std::shared_ptr<IGnssAntennaInfo>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssAntennaInfo>();
    return ScopedAStatus::ok();
  }
  // return a measurement corrections interface
  ScopedAStatus getExtensionMeasurementCorrections(
      std::shared_ptr<measurement_corrections::IMeasurementCorrectionsInterface>* out) override {
    if (host_) return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
    *out = ndk::SharedRefBase::make<RhizoMeasurementCorrections>();
    return ScopedAStatus::ok();
  }
  // start satellite status reports
  ScopedAStatus startSvStatus() override {
    if (!host_) receiver_->startSvStatus();
    return ScopedAStatus::ok();
  }
  // stop satellite status reports
  ScopedAStatus stopSvStatus() override {
    if (!host_) receiver_->stopSvStatus();
    return ScopedAStatus::ok();
  }
  // ignore starting NMEA
  ScopedAStatus startNmea() override { return ScopedAStatus::ok(); }
  // ignore stopping NMEA
  ScopedAStatus stopNmea() override { return ScopedAStatus::ok(); }
  // return a GNSS assistance interface
  ScopedAStatus getExtensionGnssAssistanceInterface(
      std::shared_ptr<gnss_assistance::IGnssAssistanceInterface>* out) override {
    *out = ndk::SharedRefBase::make<RhizoGnssAssistance>();
    return ScopedAStatus::ok();
  }

 private:
  std::shared_ptr<rhizo_gnss_host::HostSource> host_;
  std::shared_ptr<Receiver> receiver_;
};

// parse --source into a host source
bool parseSource(int argc, char** argv, std::shared_ptr<rhizo_gnss_host::HostSource>* host) {
  if (argc == 1) return true;
  if (argc != 3 || std::string(argv[1]) != "--source") return false;
  std::string path = rhizo_gnss_host::SocketPathOf(argv[2]);
  if (path.empty()) return false;
  *host = std::make_shared<rhizo_gnss_host::HostSource>(path);
  return true;
}

}

// register the GNSS service and join the binder thread pool
int main(int argc, char** argv) {
  klog("main() entered");
  std::shared_ptr<rhizo_gnss_host::HostSource> host;
  if (!parseSource(argc, argv, &host)) {
    klog("usage: rhizo-gnss-service [--source host:<absolute socket path>], refusing to start");
    return 2;
  }
  klog(host ? "source: host (the desktop's location through rhizo-locationd)"
            : "source: operator (device-state.conf)");
  auto device = ndk::SharedRefBase::make<RhizoGnss>(host);
  const std::string instance = std::string(RhizoGnss::descriptor) + "/default";
  binder_status_t status = AServiceManager_addService(device->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    char buf[128];
    snprintf(buf, sizeof(buf), "addService FAILED status=%d", status);
    klog(buf);
    return 1;
  }
  klog("registered, joining thread pool");
  ABinderProcess_setThreadPoolMaxThreadCount(0);
  ABinderProcess_joinThreadPool();
  klog("joinThreadPool RETURNED (unexpected)");
  return 0;
}
