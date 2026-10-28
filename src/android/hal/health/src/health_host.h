#pragma once
#include "aidl/android/hardware/health/HealthInfo.h"
#include <android/binder_status.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <functional>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <utility>

namespace rhizo_health_host {

using aidl::android::hardware::health::BatteryCapacityLevel;
using aidl::android::hardware::health::BatteryChargingPolicy;
using aidl::android::hardware::health::BatteryChargingState;
using aidl::android::hardware::health::BatteryHealth;
using aidl::android::hardware::health::BatteryStatus;
using aidl::android::hardware::health::HealthInfo;

inline constexpr char kBatteryPath[] = "/vendor/etc/rhizo-device-state/host-battery";
inline constexpr char kEndLine[] = "end=1";
inline constexpr size_t kMaxFileBytes = 4096;
inline constexpr int kLockRetries = 5;
inline constexpr int kLockRetryMs = 10;
inline constexpr int64_t kDesignCapacityAboveUah = 100000;
inline constexpr int64_t kDesignCapacityBelowUah = 100000000;
inline constexpr int64_t kInt32Min = std::numeric_limits<int32_t>::min();
inline constexpr int64_t kInt32Max = std::numeric_limits<int32_t>::max();
inline constexpr int64_t kInt64Min = std::numeric_limits<int64_t>::min();
inline constexpr int64_t kInt64Max = std::numeric_limits<int64_t>::max();

// host-battery v1 reading with optional values
struct Reading {
  bool present = false;
  int32_t level = 0;
  std::string status;
  std::string health;
  std::string technology;
  std::optional<int64_t> voltageUv;
  std::optional<int32_t> currentNowUa;
  std::optional<int32_t> currentAvgUa;
  std::optional<int32_t> tempDc;
  std::optional<int32_t> chargeCounterUah;
  std::optional<int32_t> chargeFullUah;
  std::optional<int64_t> chargeFullDesignUah;
  std::optional<int64_t> energyNowUwh;
  std::optional<int32_t> cycleCount;
  std::optional<int64_t> timeToFullS;
  bool acOnline = false;
  bool usbOnline = false;
  bool wirelessOnline = false;
  std::optional<int32_t> maxChargingCurrentUa;
  std::optional<int32_t> maxChargingVoltageUv;
};

// result of a host-battery file read
enum class Read { kText, kAbsent, kUnreadable };

// content kind of a host-battery file
enum class Verdict { kReading, kNoBattery, kTorn };

// return the health info of a batteryless device on AC
inline HealthInfo NoBatteryInfo() {
  HealthInfo h;
  h.chargerAcOnline = true;
  h.chargerUsbOnline = false;
  h.chargerWirelessOnline = false;
  h.chargerDockOnline = false;
  h.maxChargingCurrentMicroamps = 0;
  h.maxChargingVoltageMicrovolts = 0;
  h.batteryStatus = BatteryStatus::FULL;
  h.batteryHealth = BatteryHealth::UNKNOWN;
  h.batteryPresent = false;
  h.batteryLevel = 100;
  h.batteryVoltageMillivolts = 0;
  h.batteryTemperatureTenthsCelsius = 0;
  h.batteryCurrentMicroamps = 0;
  h.batteryCycleCount = 0;
  h.batteryFullChargeUah = 0;
  h.batteryChargeCounterUah = 0;
  h.batteryTechnology = "";
  h.batteryCurrentAverageMicroamps = 0;
  h.diskStats = {};
  h.storageInfos = {};
  h.batteryCapacityLevel = BatteryCapacityLevel::FULL;
  h.batteryChargeTimeToFullNowSeconds =
      HealthInfo::BATTERY_CHARGE_TIME_TO_FULL_NOW_SECONDS_UNSUPPORTED;
  h.batteryFullChargeDesignCapacityUah = 0;
  h.chargingState = BatteryChargingState::NORMAL;
  h.chargingPolicy = BatteryChargingPolicy::DEFAULT;
  h.batteryHealthData = std::nullopt;
  h.hingeInfos = std::nullopt;
  return h;
}

// parse a whole decimal number in [lo, hi]
inline bool ParseInt(const std::string& s, int64_t lo, int64_t hi, int64_t* out) {
  size_t digit = (!s.empty() && s[0] == '-') ? 1 : 0;
  if (digit >= s.size() || !isdigit(static_cast<unsigned char>(s[digit]))) return false;
  errno = 0;
  char* end = nullptr;
  long long v = strtoll(s.c_str(), &end, 10);
  if (errno != 0 || *end != '\0' || v < lo || v > hi) return false;
  *out = v;
  return true;
}

// parse an integer key into its optional field
template <typename T>
inline void TakeInt(const std::map<std::string, std::string>& kv, const char* key, int64_t lo, int64_t hi,
                    std::optional<T>* field, std::string* bad) {
  auto it = kv.find(key);
  if (it == kv.end()) return;
  int64_t v = 0;
  if (ParseInt(it->second, lo, hi, &v)) {
    *field = static_cast<T>(v);
  } else {
    *bad += (bad->empty() ? "" : " ") + std::string(key);
  }
}

// parse a 0 or 1 key into a flag
inline void TakeFlag(const std::map<std::string, std::string>& kv, const char* key, bool* field,
                     std::string* bad) {
  auto it = kv.find(key);
  if (it == kv.end()) return;
  if (it->second == "0" || it->second == "1") {
    *field = it->second == "1";
  } else {
    *bad += (bad->empty() ? "" : " ") + std::string(key);
  }
}

// parse host-battery text into a reading
inline Verdict Parse(const std::string& text, Reading* out, std::string* why) {
  std::map<std::string, std::string> kv;
  size_t start = 0;
  size_t after_end = std::string::npos;
  while (start < text.size()) {
    size_t nl = text.find('\n', start);
    if (nl == std::string::npos) break;
    std::string line = text.substr(start, nl - start);
    start = nl + 1;
    if (line == kEndLine) {
      after_end = start;
      break;
    }
    size_t eq = line.find('=');
    if (eq == std::string::npos || eq == 0) continue;
    kv[line.substr(0, eq)] = line.substr(eq + 1);
  }
  if (after_end == std::string::npos) {
    *why = "torn (no end=1 line)";
    return Verdict::kTorn;
  }
  if (after_end != text.size()) {
    *why = "torn (content after end=1)";
    return Verdict::kTorn;
  }
  auto version = kv.find("version");
  if (version == kv.end()) {
    *why = "no version line";
    return Verdict::kNoBattery;
  }
  if (version->second != "1") {
    *why = "version " + version->second.substr(0, 16) + ", want 1";
    return Verdict::kNoBattery;
  }
  auto present = kv.find("present");
  if (present == kv.end() || (present->second != "0" && present->second != "1")) {
    *why = "no present=0 or present=1 line";
    return Verdict::kNoBattery;
  }
  *out = Reading();
  if (present->second == "0") return Verdict::kReading;
  auto level = kv.find("level");
  int64_t lv = 0;
  if (level == kv.end() || !ParseInt(level->second, 0, 100, &lv)) {
    *why = "present=1 with no level 0-100";
    return Verdict::kNoBattery;
  }
  out->present = true;
  out->level = static_cast<int32_t>(lv);
  auto text_of = [&](const char* key) {
    auto it = kv.find(key);
    return it == kv.end() ? std::string() : it->second;
  };
  out->status = text_of("status");
  out->health = text_of("health");
  out->technology = text_of("technology");
  std::string bad;
  TakeInt(kv, "voltage_uv", kInt32Min * 1000, kInt32Max * 1000, &out->voltageUv, &bad);
  TakeInt(kv, "current_now_ua", kInt32Min, kInt32Max, &out->currentNowUa, &bad);
  TakeInt(kv, "current_avg_ua", kInt32Min, kInt32Max, &out->currentAvgUa, &bad);
  TakeInt(kv, "temp_dc", kInt32Min, kInt32Max, &out->tempDc, &bad);
  TakeInt(kv, "charge_counter_uah", kInt32Min, kInt32Max, &out->chargeCounterUah, &bad);
  TakeInt(kv, "charge_full_uah", kInt32Min, kInt32Max, &out->chargeFullUah, &bad);
  TakeInt(kv, "charge_full_design_uah", kInt64Min, kInt64Max, &out->chargeFullDesignUah, &bad);
  TakeInt(kv, "energy_now_uwh", 0, kInt64Max / 1000, &out->energyNowUwh, &bad);
  TakeInt(kv, "cycle_count", kInt32Min, kInt32Max, &out->cycleCount, &bad);
  TakeInt(kv, "time_to_full_s", 0, kInt64Max, &out->timeToFullS, &bad);
  TakeFlag(kv, "ac_online", &out->acOnline, &bad);
  TakeFlag(kv, "usb_online", &out->usbOnline, &bad);
  TakeFlag(kv, "wireless_online", &out->wirelessOnline, &bad);
  TakeInt(kv, "max_charging_current_ua", kInt32Min, kInt32Max, &out->maxChargingCurrentUa, &bad);
  TakeInt(kv, "max_charging_voltage_uv", kInt32Min, kInt32Max, &out->maxChargingVoltageUv, &bad);
  if (!bad.empty()) *why = "ignoring bad " + bad;
  return Verdict::kReading;
}

// read a file under a shared lock with retries
inline Read ReadLocked(const char* path, int retries, int retry_ms, std::string* text, std::string* why) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) {
    if (errno == ENOENT) {
      *why = "absent";
      return Read::kAbsent;
    }
    *why = "unreadable (open errno=" + std::to_string(errno) + ")";
    return Read::kUnreadable;
  }
  int tries = 0;
  while (flock(fd, LOCK_SH | LOCK_NB) != 0) {
    if (errno == EINTR) continue;
    if (errno == EWOULDBLOCK && tries < retries) {
      tries++;
      usleep(static_cast<useconds_t>(retry_ms) * 1000);
      continue;
    }
    *why = errno == EWOULDBLOCK ? "locked by its writer past " + std::to_string(retries) + " retries"
                                : "unreadable (flock errno=" + std::to_string(errno) + ")";
    close(fd);
    return Read::kUnreadable;
  }
  char buf[kMaxFileBytes + 1];
  size_t len = 0;
  int err = 0;
  while (len < sizeof(buf)) {
    ssize_t n = read(fd, buf + len, sizeof(buf) - len);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) err = errno;
    if (n <= 0) break;
    len += static_cast<size_t>(n);
  }
  flock(fd, LOCK_UN);
  close(fd);
  if (err != 0) {
    *why = "unreadable (read errno=" + std::to_string(err) + ")";
    return Read::kUnreadable;
  }
  if (len > kMaxFileBytes) {
    *why = "larger than " + std::to_string(kMaxFileBytes) + " bytes";
    return Read::kUnreadable;
  }
  text->assign(buf, len);
  return Read::kText;
}

// map a host-battery health token to the HAL's battery health
inline BatteryHealth HealthOf(const std::string& token) {
  if (token == "good" || token == "warm" || token == "cool") return BatteryHealth::GOOD;
  if (token == "overheat" || token == "hot") return BatteryHealth::OVERHEAT;
  if (token == "dead") return BatteryHealth::DEAD;
  if (token == "over-voltage") return BatteryHealth::OVER_VOLTAGE;
  if (token == "unspecified-failure") return BatteryHealth::UNSPECIFIED_FAILURE;
  if (token == "cold") return BatteryHealth::COLD;
  if (token == "calibration-required") return BatteryHealth::INCONSISTENT;
  return BatteryHealth::UNKNOWN;
}

// map a host-battery status token to the HAL's battery status
inline BatteryStatus StatusOf(const std::string& token) {
  if (token == "charging") return BatteryStatus::CHARGING;
  if (token == "discharging") return BatteryStatus::DISCHARGING;
  if (token == "not-charging") return BatteryStatus::NOT_CHARGING;
  if (token == "full") return BatteryStatus::FULL;
  return BatteryStatus::UNKNOWN;
}

// return the charging state a battery health implies
inline BatteryChargingState ChargingStateOf(BatteryHealth health) {
  if (health == BatteryHealth::OVERHEAT) return BatteryChargingState::TOO_HOT;
  if (health == BatteryHealth::COLD) return BatteryChargingState::TOO_COLD;
  return BatteryChargingState::NORMAL;
}

// return a present battery's capacity level
inline BatteryCapacityLevel CapacityLevelOf(const Reading& r) {
  if (r.level == 0 && !r.acOnline && !r.usbOnline && !r.wirelessOnline) return BatteryCapacityLevel::CRITICAL;
  if (r.level == 100) return BatteryCapacityLevel::FULL;
  return BatteryCapacityLevel::NORMAL;
}

// return the design capacity or 0 outside the AIDL range
inline int32_t DesignCapacityOf(const std::optional<int64_t>& uah) {
  if (!uah || *uah <= kDesignCapacityAboveUah || *uah >= kDesignCapacityBelowUah) return 0;
  return static_cast<int32_t>(*uah);
}

// return the health info of a reading
inline HealthInfo InfoOf(const Reading& r) {
  HealthInfo h = NoBatteryInfo();
  if (!r.present) return h;
  h.chargerAcOnline = r.acOnline;
  h.chargerUsbOnline = r.usbOnline;
  h.chargerWirelessOnline = r.wirelessOnline;
  h.maxChargingCurrentMicroamps = r.maxChargingCurrentUa.value_or(0);
  h.maxChargingVoltageMicrovolts = r.maxChargingVoltageUv.value_or(0);
  h.batteryStatus = StatusOf(r.status);
  h.batteryHealth = HealthOf(r.health);
  h.batteryPresent = true;
  h.batteryLevel = r.level;
  h.batteryVoltageMillivolts = static_cast<int32_t>(r.voltageUv.value_or(0) / 1000);
  h.batteryTemperatureTenthsCelsius = r.tempDc.value_or(0);
  h.batteryCurrentMicroamps = r.currentNowUa.value_or(0);
  h.batteryCycleCount = r.cycleCount.value_or(0);
  h.batteryFullChargeUah = r.chargeFullUah.value_or(0);
  h.batteryChargeCounterUah = r.chargeCounterUah.value_or(0);
  h.batteryTechnology = r.technology;
  h.batteryCurrentAverageMicroamps = r.currentAvgUa.value_or(0);
  h.batteryCapacityLevel = CapacityLevelOf(r);
  h.batteryChargeTimeToFullNowSeconds =
      r.timeToFullS.value_or(HealthInfo::BATTERY_CHARGE_TIME_TO_FULL_NOW_SECONDS_UNSUPPORTED);
  h.batteryFullChargeDesignCapacityUah = DesignCapacityOf(r.chargeFullDesignUah);
  h.chargingState = ChargingStateOf(h.batteryHealth);
  h.chargingPolicy = BatteryChargingPolicy::DEFAULT;
  return h;
}

// answer a getter from a host value or as unsupported
template <typename T>
inline binder_exception_t Answer(const Reading& r, const std::optional<T>& v, T* out) {
  if (!r.present || !v) return EX_UNSUPPORTED_OPERATION;
  *out = *v;
  return EX_NONE;
}

// answer getChargeCounterUah from a reading
inline binder_exception_t ChargeCounterUah(const Reading& r, int32_t* out) {
  return Answer(r, r.chargeCounterUah, out);
}

// answer getCurrentNowMicroamps from a reading
inline binder_exception_t CurrentNowMicroamps(const Reading& r, int32_t* out) {
  return Answer(r, r.currentNowUa, out);
}

// answer getCurrentAverageMicroamps from a reading
inline binder_exception_t CurrentAverageMicroamps(const Reading& r, int32_t* out) {
  return Answer(r, r.currentAvgUa, out);
}

// answer getEnergyCounterNwh from a reading's energy in uWh
inline binder_exception_t EnergyCounterNwh(const Reading& r, int64_t* out) {
  int64_t uwh = 0;
  binder_exception_t ex = Answer(r, r.energyNowUwh, &uwh);
  if (ex == EX_NONE) *out = uwh * 1000;
  return ex;
}

// host battery read from the relay's file
class Source {
 public:
  // read path with lock retries
  Source(std::string path, std::function<void(const char*)> log, int retries = kLockRetries,
         int retry_ms = kLockRetryMs)
      : path_(std::move(path)), log_(std::move(log)), retries_(retries), retry_ms_(retry_ms) {}
  // return the current or last complete reading
  Reading read() {
    Reading r;
    std::string text, why;
    Read got = ReadLocked(path_.c_str(), retries_, retry_ms_, &text, &why);
    Verdict verdict = got == Read::kText ? Parse(text, &r, &why) : Verdict::kNoBattery;
    std::lock_guard<std::mutex> lg(mutex_);
    if (got == Read::kUnreadable || verdict == Verdict::kTorn) {
      r = have_last_ ? last_ : Reading();
      note(why + (have_last_ ? ", reporting the last complete reading" : ", reporting no battery"));
    } else if (verdict == Verdict::kNoBattery) {
      r = Reading();
      have_last_ = false;
      note(why + ", reporting no battery");
    } else {
      last_ = r;
      have_last_ = true;
      note(why);
    }
    return r;
  }

 private:
  // log a changed read status
  void note(const std::string& why) {
    if (why == logged_) return;
    std::string line = why.empty() ? "host-battery read as v1 again" : "host-battery " + why;
    logged_ = why;
    log_(line.c_str());
  }

  std::string path_;
  std::function<void(const char*)> log_;
  int retries_;
  int retry_ms_;
  std::mutex mutex_;
  Reading last_;
  bool have_last_ = false;
  std::string logged_;
};

}
