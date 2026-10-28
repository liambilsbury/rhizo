#include "aidl/android/hardware/thermal/BnThermal.h"
#include "rhizo/device_state.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <mutex>
#include <string>
#include <vector>

using namespace aidl::android::hardware::thermal;
using ndk::ScopedAStatus;

namespace {

constexpr float kMinPlausibleC = -40.0f;
constexpr float kMaxPlausibleC = 150.0f;

// write a message to the kernel log
void klog(const char* msg) { rhizo_device::Klog("rhizo-thermal", msg); }

// return an illegal-argument exception status
ScopedAStatus illegalArgument(const char* msg) {
  return ScopedAStatus::fromExceptionCodeWithMessage(EX_ILLEGAL_ARGUMENT, msg);
}

// parse skin_temp_c from the device state
bool parseSkinTempC(const std::map<std::string, std::string>& state, float* out) {
  auto it = state.find("skin_temp_c");
  if (it == state.end()) return false;
  char* end = nullptr;
  float v = strtof(it->second.c_str(), &end);
  if (end == it->second.c_str() || *end != '\0' || std::isnan(v) ||
      v < kMinPlausibleC || v > kMaxPlausibleC) {
    char buf[192];
    snprintf(buf, sizeof(buf),
             "device-state.conf: bad skin_temp_c '%s' (want a number between %g and %g), ignoring",
             it->second.c_str(), kMinPlausibleC, kMaxPlausibleC);
    klog(buf);
    return false;
  }
  *out = v;
  return true;
}

constexpr float kHotThresholds[7] = {30.0f, 31.0f, 32.0f, 33.0f, 34.0f, 35.0f, 36.0f};

// return the throttling severity for a temperature
ThrottlingSeverity severityFor(float value) {
  ThrottlingSeverity sev = ThrottlingSeverity::NONE;
  for (int i = 1; i < 7; i++) {
    if (value >= kHotThresholds[i]) sev = static_cast<ThrottlingSeverity>(i);
  }
  return sev;
}

// return the skin temperature
Temperature SkinTemperature() {
  Temperature t;
  t.name = "skin";
  t.type = TemperatureType::SKIN;
  t.value = 30.1f;
  t.throttlingStatus = ThrottlingSeverity::NONE;

  std::map<std::string, std::string> state;
  float overridden;
  if (rhizo_device::ReadState(&state) && parseSkinTempC(state, &overridden)) {
    t.value = overridden;
    t.throttlingStatus = severityFor(overridden);
  }
  return t;
}
// return the skin temperature thresholds
TemperatureThreshold SkinThreshold() {
  TemperatureThreshold th;
  th.name = "skin";
  th.type = TemperatureType::SKIN;
  th.hotThrottlingThresholds = {kHotThresholds[0], kHotThresholds[1], kHotThresholds[2],
                                 kHotThresholds[3], kHotThresholds[4], kHotThresholds[5],
                                 kHotThresholds[6]};
  th.coldThrottlingThresholds = {NAN, NAN, NAN, NAN, NAN, NAN, NAN};
  return th;
}

// software HAL for IThermal
class RhizoThermal : public BnThermal {
 public:
  // return no cooling devices
  ScopedAStatus getCoolingDevices(std::vector<CoolingDevice>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }
  // return no cooling devices of the given type
  ScopedAStatus getCoolingDevicesWithType(CoolingType, std::vector<CoolingDevice>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }
  // return the skin temperature
  ScopedAStatus getTemperatures(std::vector<Temperature>* out) override {
    *out = {SkinTemperature()};
    return ScopedAStatus::ok();
  }
  // return the skin temperature when the type is skin
  ScopedAStatus getTemperaturesWithType(TemperatureType type, std::vector<Temperature>* out) override {
    out->clear();
    if (type == TemperatureType::SKIN) out->push_back(SkinTemperature());
    return ScopedAStatus::ok();
  }
  // return the skin temperature thresholds
  ScopedAStatus getTemperatureThresholds(std::vector<TemperatureThreshold>* out) override {
    *out = {SkinThreshold()};
    return ScopedAStatus::ok();
  }
  // return the skin thresholds when the type is skin
  ScopedAStatus getTemperatureThresholdsWithType(TemperatureType type,
                                                  std::vector<TemperatureThreshold>* out) override {
    out->clear();
    if (type == TemperatureType::SKIN) out->push_back(SkinThreshold());
    return ScopedAStatus::ok();
  }

  // add a thermal changed callback
  ScopedAStatus registerThermalChangedCallback(
      const std::shared_ptr<IThermalChangedCallback>& callback) override {
    if (callback == nullptr) return illegalArgument("callback is null");
    std::lock_guard<std::mutex> lg(mutex_);
    for (auto& cb : thermalCallbacks_) {
      if (cb.callback->asBinder() == callback->asBinder()) {
        return illegalArgument("callback already registered");
      }
    }
    thermalCallbacks_.push_back({callback, std::nullopt});
    return ScopedAStatus::ok();
  }
  // add a typed thermal changed callback
  ScopedAStatus registerThermalChangedCallbackWithType(
      const std::shared_ptr<IThermalChangedCallback>& callback, TemperatureType type) override {
    if (callback == nullptr) return illegalArgument("callback is null");
    std::lock_guard<std::mutex> lg(mutex_);
    for (auto& cb : thermalCallbacks_) {
      if (cb.callback->asBinder() == callback->asBinder()) {
        return illegalArgument("callback already registered");
      }
    }
    thermalCallbacks_.push_back({callback, type});
    return ScopedAStatus::ok();
  }
  // remove a thermal changed callback
  ScopedAStatus unregisterThermalChangedCallback(
      const std::shared_ptr<IThermalChangedCallback>& callback) override {
    if (callback == nullptr) return illegalArgument("callback is null");
    std::lock_guard<std::mutex> lg(mutex_);
    auto it = std::find_if(thermalCallbacks_.begin(), thermalCallbacks_.end(),
                            [&](const auto& cb) { return cb.callback->asBinder() == callback->asBinder(); });
    if (it == thermalCallbacks_.end()) return illegalArgument("callback not registered");
    thermalCallbacks_.erase(it);
    return ScopedAStatus::ok();
  }

  // add a cooling device changed callback
  ScopedAStatus registerCoolingDeviceChangedCallbackWithType(
      const std::shared_ptr<ICoolingDeviceChangedCallback>& callback, CoolingType type) override {
    if (callback == nullptr) return illegalArgument("callback is null");
    std::lock_guard<std::mutex> lg(mutex_);
    for (auto& cb : coolingCallbacks_) {
      if (cb.callback->asBinder() == callback->asBinder()) {
        return illegalArgument("callback already registered");
      }
    }
    coolingCallbacks_.push_back({callback, type});
    return ScopedAStatus::ok();
  }
  // remove a cooling device changed callback
  ScopedAStatus unregisterCoolingDeviceChangedCallback(
      const std::shared_ptr<ICoolingDeviceChangedCallback>& callback) override {
    if (callback == nullptr) return illegalArgument("callback is null");
    std::lock_guard<std::mutex> lg(mutex_);
    auto it = std::find_if(coolingCallbacks_.begin(), coolingCallbacks_.end(),
                            [&](const auto& cb) { return cb.callback->asBinder() == callback->asBinder(); });
    if (it == coolingCallbacks_.end()) return illegalArgument("callback not registered");
    coolingCallbacks_.erase(it);
    return ScopedAStatus::ok();
  }

  // return unsupported for skin temperature forecasts
  ScopedAStatus forecastSkinTemperature(int32_t forecastSeconds, float*) override {
    if (forecastSeconds < 0) return illegalArgument("forecastSeconds is negative");
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }

 private:
  struct ThermalCb {
    std::shared_ptr<IThermalChangedCallback> callback;
    std::optional<TemperatureType> type;
  };
  struct CoolingCb {
    std::shared_ptr<ICoolingDeviceChangedCallback> callback;
    CoolingType type;
  };

  // send the skin temperature to the callbacks
  void broadcastThermalChanged() {
    std::vector<std::shared_ptr<IThermalChangedCallback>> cbs;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      for (auto& cb : thermalCallbacks_) {
        if (!cb.type.has_value() || *cb.type == TemperatureType::SKIN) cbs.push_back(cb.callback);
      }
    }
    if (cbs.empty()) return;
    Temperature t = SkinTemperature();
    for (auto& cb : cbs) cb->notifyThrottling(t);
  }

  std::mutex mutex_;
  std::vector<ThermalCb> thermalCallbacks_;
  std::vector<CoolingCb> coolingCallbacks_;
  rhizo_device::Watcher watcher_{"rhizo-thermal", [this] { broadcastThermalChanged(); }};
};

}

// register the thermal service and join the binder thread pool
int main() {
  klog("main() entered");
  auto device = ndk::SharedRefBase::make<RhizoThermal>();
  const std::string instance = std::string(RhizoThermal::descriptor) + "/default";
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
