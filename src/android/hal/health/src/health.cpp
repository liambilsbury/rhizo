#include "aidl/android/hardware/health/BnHealth.h"
#include "rhizo/device_state.h"
#include "health_host.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

using namespace aidl::android::hardware::health;
using ndk::ScopedAStatus;

namespace {

// write a message to the kernel log
void klog(const char* msg) { rhizo_device::Klog("rhizo-health", msg); }

// parse battery_level from the device state
bool parseBatteryLevel(const std::map<std::string, std::string>& state, int* out) {
  auto it = state.find("battery_level");
  if (it == state.end()) return false;
  char* end = nullptr;
  long v = strtol(it->second.c_str(), &end, 10);
  if (end == it->second.c_str() || *end != '\0' || v < 0 || v > 100) {
    char buf[192];
    snprintf(buf, sizeof(buf), "device-state.conf: bad battery_level '%s' (want an integer 0-100), ignoring",
             it->second.c_str());
    klog(buf);
    return false;
  }
  *out = static_cast<int>(v);
  return true;
}

// parse battery_charging from the device state
bool parseBatteryCharging(const std::map<std::string, std::string>& state, bool* charging) {
  auto it = state.find("battery_charging");
  if (it == state.end()) return false;
  if (it->second == "charging") { *charging = true; return true; }
  if (it->second == "discharging") { *charging = false; return true; }
  char buf[192];
  snprintf(buf, sizeof(buf),
           "device-state.conf: bad battery_charging '%s' (want 'charging' or 'discharging'), ignoring",
           it->second.c_str());
  klog(buf);
  return false;
}

// map a battery level to a capacity level
BatteryCapacityLevel capacityLevelFor(int level) {
  if (level <= 5) return BatteryCapacityLevel::CRITICAL;
  if (level <= 15) return BatteryCapacityLevel::LOW;
  if (level >= 100) return BatteryCapacityLevel::FULL;
  return BatteryCapacityLevel::NORMAL;
}

// build the health info from the device state
HealthInfo MakeHealthInfo() {
  HealthInfo h = rhizo_health_host::NoBatteryInfo();

  std::map<std::string, std::string> state;
  if (!rhizo_device::ReadState(&state)) return h;

  int level = 0;
  bool haveLevel = parseBatteryLevel(state, &level);
  bool charging = false;
  bool haveCharging = parseBatteryCharging(state, &charging);
  if (!haveLevel && !haveCharging) return h;

  h.batteryPresent = true;
  h.batteryHealth = BatteryHealth::GOOD;
  h.batteryTechnology = "Li-ion";
  if (haveLevel) {
    h.batteryLevel = level;
    h.batteryCapacityLevel = capacityLevelFor(level);
  }
  if (haveCharging) {
    h.batteryStatus = charging ? BatteryStatus::CHARGING : BatteryStatus::DISCHARGING;
    h.chargerAcOnline = charging;
  }
  return h;
}

// software HAL for IHealth
class RhizoHealth : public BnHealth {
 public:
  // use the host source or the operator's device state
  explicit RhizoHealth(std::shared_ptr<rhizo_health_host::Source> host) : host_(std::move(host)) {}
  // add a callback and send it the current health info
  ScopedAStatus registerCallback(const std::shared_ptr<IHealthInfoCallback>& cb) override {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      callbacks_.push_back(cb);
    }
    cb->healthInfoChanged(healthInfo());
    return ScopedAStatus::ok();
  }
  // remove a registered health callback
  ScopedAStatus unregisterCallback(const std::shared_ptr<IHealthInfoCallback>& cb) override {
    std::lock_guard<std::mutex> lg(mutex_);
    auto target = cb->asBinder();
    auto it = std::find_if(callbacks_.begin(), callbacks_.end(),
                            [&](const auto& c) { return c->asBinder() == target; });
    if (it == callbacks_.end()) {
      return ScopedAStatus::fromExceptionCode(EX_ILLEGAL_ARGUMENT);
    }
    callbacks_.erase(it);
    return ScopedAStatus::ok();
  }
  // send the health info to all of the callbacks
  ScopedAStatus update() override {
    broadcast();
    return ScopedAStatus::ok();
  }
  // return the host's charge counter or 0
  ScopedAStatus getChargeCounterUah(int32_t* out) override {
    if (host_) return ScopedAStatus::fromExceptionCode(rhizo_health_host::ChargeCounterUah(host_->read(), out));
    *out = 0;
    return ScopedAStatus::ok();
  }
  // return the host's current or 0
  ScopedAStatus getCurrentNowMicroamps(int32_t* out) override {
    if (host_) return ScopedAStatus::fromExceptionCode(rhizo_health_host::CurrentNowMicroamps(host_->read(), out));
    *out = 0;
    return ScopedAStatus::ok();
  }
  // return the host's average current or 0
  ScopedAStatus getCurrentAverageMicroamps(int32_t* out) override {
    if (host_) {
      return ScopedAStatus::fromExceptionCode(rhizo_health_host::CurrentAverageMicroamps(host_->read(), out));
    }
    *out = 0;
    return ScopedAStatus::ok();
  }
  // return the battery level
  ScopedAStatus getCapacity(int32_t* out) override {
    *out = healthInfo().batteryLevel;
    return ScopedAStatus::ok();
  }
  // return the host's energy counter or 0
  ScopedAStatus getEnergyCounterNwh(int64_t* out) override {
    if (host_) return ScopedAStatus::fromExceptionCode(rhizo_health_host::EnergyCounterNwh(host_->read(), out));
    *out = 0;
    return ScopedAStatus::ok();
  }
  // return the battery status
  ScopedAStatus getChargeStatus(BatteryStatus* out) override {
    *out = healthInfo().batteryStatus;
    return ScopedAStatus::ok();
  }
  // return an empty storage info list
  ScopedAStatus getStorageInfo(std::vector<StorageInfo>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }
  // return an empty disk stats list
  ScopedAStatus getDiskStats(std::vector<DiskStats>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }
  // return the current health info
  ScopedAStatus getHealthInfo(HealthInfo* out) override {
    *out = healthInfo();
    return ScopedAStatus::ok();
  }
  // reject a charging policy change
  ScopedAStatus setChargingPolicy(BatteryChargingPolicy) override {
    return ScopedAStatus::fromExceptionCode(EX_UNSUPPORTED_OPERATION);
  }
  // return the default charging policy
  ScopedAStatus getChargingPolicy(BatteryChargingPolicy* out) override {
    *out = BatteryChargingPolicy::DEFAULT;
    return ScopedAStatus::ok();
  }
  // return empty battery health data
  ScopedAStatus getBatteryHealthData(BatteryHealthData* out) override {
    *out = BatteryHealthData();
    return ScopedAStatus::ok();
  }
  // return an empty hinge info list
  ScopedAStatus getHingeInfo(std::vector<HingeInfo>* out) override {
    out->clear();
    return ScopedAStatus::ok();
  }

 private:
  // build the health info from the host or device state
  HealthInfo healthInfo() { return host_ ? rhizo_health_host::InfoOf(host_->read()) : MakeHealthInfo(); }
  // send the health info to the callbacks
  void broadcast() {
    std::vector<std::shared_ptr<IHealthInfoCallback>> cbs;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      cbs = callbacks_;
    }
    HealthInfo info = healthInfo();
    for (auto& cb : cbs) cb->healthInfoChanged(info);
  }

  std::shared_ptr<rhizo_health_host::Source> host_;
  std::mutex mutex_;
  std::vector<std::shared_ptr<IHealthInfoCallback>> callbacks_;
  rhizo_device::Watcher watcher_{"rhizo-health", [this] { broadcast(); }};
};

// parse --source into a host source
bool parseSource(int argc, char** argv, std::shared_ptr<rhizo_health_host::Source>* host) {
  if (argc == 1) return true;
  if (argc != 3 || std::string(argv[1]) != "--source" || std::string(argv[2]) != "host") return false;
  *host = std::make_shared<rhizo_health_host::Source>(rhizo_health_host::kBatteryPath, klog);
  return true;
}

}

// register the health service and join the binder thread pool
int main(int argc, char** argv) {
  klog("main() entered");
  std::shared_ptr<rhizo_health_host::Source> host;
  if (!parseSource(argc, argv, &host)) {
    klog("usage: rhizo-health-service [--source host], refusing to start");
    return 2;
  }
  klog(host ? "source host" : "source operator");
  auto device = ndk::SharedRefBase::make<RhizoHealth>(host);
  const std::string instance = std::string(RhizoHealth::descriptor) + "/default";
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
