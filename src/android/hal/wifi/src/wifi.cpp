#include "aidl/android/hardware/wifi/BnWifi.h"
#include "aidl/android/hardware/wifi/BnWifiChip.h"
#include "aidl/android/hardware/wifi/BnWifiStaIface.h"
#include "rhizo/device_state.h"
#include "rhizo/wifi_callbacks.h"
#include "rhizo/wifi_netdev.h"
#include "rhizo/wifi_nl80211.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <net/if.h>
#include <poll.h>
#include <sys/system_properties.h>
#include <sys/utsname.h>
#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace aidl::android::hardware::wifi;
using aidl::android::hardware::wifi::common::OuiKeyedData;
using ndk::ScopedAStatus;
using rhizo_wifi::CallbackList;

namespace {

constexpr int32_t kChipId = 0;
constexpr int32_t kStaModeId = 0;

// write a message to the kernel log
void klog(const char* msg) { rhizo_device::Klog("rhizo-wifi", msg); }

// write a formatted message to the kernel log
template <typename... Args>
void klogf(const char* fmt, Args... args) {
  char buf[256];
  snprintf(buf, sizeof(buf), fmt, args...);
  klog(buf);
}

// return a service-specific WifiStatusCode failure
ScopedAStatus Status(WifiStatusCode code) {
  return ScopedAStatus::fromServiceSpecificError(static_cast<int32_t>(code));
}

// return the STA netdev name
std::string StaIfaceName() {
  char v[PROP_VALUE_MAX] = {};
  if (__system_property_get("wifi.interface", v) > 0) return v;
  return "wlan0";
}

// netdev and nl80211 state shared by the chip and iface
struct Radio {
  std::mutex mu;
  std::string iface = StaIfaceName();
  uint32_t ifindex = 0;
  uint32_t wiphy = 0;
  rhizo_wifi::Nl80211 nl;
  bool nl_ready = false;

  // resolve nl80211 and check the netdev is a cfg80211 station
  bool CheckLocked(std::string* why) {
    if (!nl_ready) {
      int rc = nl.Init();
      if (rc != 0) {
        *why = std::string("nl80211 unavailable: ") + strerror(-rc);
        return false;
      }
      nl_ready = true;
    }
    ifindex = if_nametoindex(iface.c_str());
    if (ifindex == 0) {
      *why = "no netdev " + iface;
      return false;
    }
    rhizo_wifi::IfaceInfo info;
    int rc = nl.GetInterface(ifindex, &info);
    if (rc != 0) {
      *why = iface + " is not a cfg80211 netdev: " + strerror(-rc);
      return false;
    }
    wiphy = info.wiphy;
    return true;
  }
};

// STA interface over the existing netdev
class RhizoWifiStaIface : public BnWifiStaIface {
 public:
  explicit RhizoWifiStaIface(std::shared_ptr<Radio> radio) : radio_(std::move(radio)), name_(radio_->iface) {}

  // drop this object from service
  void Invalidate() {
    valid_ = false;
    callbacks_.Clear();
  }
  const std::string& name() const { return name_; }

  ScopedAStatus getName(std::string* out) override {
    if (!valid_) return Invalid();
    *out = name_;
    return ScopedAStatus::ok();
  }

  ScopedAStatus registerEventCallback(const std::shared_ptr<IWifiStaIfaceEventCallback>& cb) override {
    if (!valid_) return Invalid();
    if (!cb) return Status(WifiStatusCode::ERROR_INVALID_ARGS);
    callbacks_.Add(cb);
    return ScopedAStatus::ok();
  }

  ScopedAStatus getFeatureSet(int32_t* out) override {
    if (!valid_) return Invalid();
    std::lock_guard<std::mutex> lg(radio_->mu);
    std::string why;
    rhizo_wifi::WiphyInfo w;
    int rc = -ENODEV;
    if (radio_->CheckLocked(&why)) rc = radio_->nl.GetWiphy(radio_->wiphy, &w);
    if (rc != 0) {
      klogf("getFeatureSet: wiphy unreadable: %s", why.empty() ? strerror(-rc) : why.c_str());
      return Status(WifiStatusCode::ERROR_UNKNOWN);
    }
    int32_t f = 0;
    if (w.features & NL80211_FEATURE_SCAN_RANDOM_MAC_ADDR)
      f |= static_cast<int32_t>(IWifiStaIface::FeatureSetMask::SCAN_RAND);
    if (w.band_5ghz) f |= static_cast<int32_t>(IWifiStaIface::FeatureSetMask::STA_5G);
    if (w.sched_scan) f |= static_cast<int32_t>(IWifiStaIface::FeatureSetMask::PNO);
    *out = f;
    return ScopedAStatus::ok();
  }

  ScopedAStatus getFactoryMacAddress(std::array<uint8_t, 6>* out) override {
    if (!valid_) return Invalid();
    std::array<uint8_t, 6> mac{};
    int rc = rhizo_wifi::GetPermAddr(name_, &mac);
    if (rc == 0 && rhizo_wifi::UsableUnicast(mac)) {
      *out = mac;
      return ScopedAStatus::ok();
    }
    if (ReadPhyAddress(&mac)) {
      *out = mac;
      return ScopedAStatus::ok();
    }
    klogf("getFactoryMacAddress: %s has no permanent address (ethtool: %s)", name_.c_str(),
          rc ? strerror(-rc) : "all zero");
    return Status(WifiStatusCode::ERROR_UNKNOWN);
  }

  ScopedAStatus setMacAddress(const std::array<uint8_t, 6>& mac) override {
    if (!valid_) return Invalid();
    if (!rhizo_wifi::UsableUnicast(mac)) return Status(WifiStatusCode::ERROR_INVALID_ARGS);
    std::lock_guard<std::mutex> lg(radio_->mu);
    short flags = 0;
    int rc = rhizo_wifi::GetFlags(name_, &flags);
    if (rc != 0) {
      klogf("setMacAddress: %s flags unreadable: %s", name_.c_str(), strerror(-rc));
      return Status(WifiStatusCode::ERROR_UNKNOWN);
    }
    const bool was_up = flags & IFF_UP;
    if (was_up && (rc = rhizo_wifi::SetUp(name_, false)) != 0) {
      klogf("setMacAddress: %s down FAILED: %s", name_.c_str(), strerror(-rc));
      return Status(WifiStatusCode::ERROR_UNKNOWN);
    }
    const int set_rc = rhizo_wifi::SetHwAddr(name_, mac);
    if (was_up && (rc = rhizo_wifi::SetUp(name_, true)) != 0) {
      klogf("setMacAddress: %s up FAILED: %s", name_.c_str(), strerror(-rc));
      return Status(WifiStatusCode::ERROR_UNKNOWN);
    }
    if (set_rc != 0) {
      klogf("setMacAddress: %s SIOCSIFHWADDR FAILED: %s", name_.c_str(), strerror(-set_rc));
      return Status(WifiStatusCode::ERROR_UNKNOWN);
    }
    klogf("%s address set to %02x:%02x:%02x:%02x:%02x:%02x", name_.c_str(), mac[0], mac[1], mac[2], mac[3],
          mac[4], mac[5]);
    return ScopedAStatus::ok();
  }

  ScopedAStatus configureRoaming(const StaRoamingConfig&) override { return Unsupported(); }
  ScopedAStatus disableLinkLayerStatsCollection() override { return Unsupported(); }
  ScopedAStatus enableLinkLayerStatsCollection(bool) override { return Unsupported(); }
  ScopedAStatus enableNdOffload(bool) override { return Unsupported(); }
  ScopedAStatus getApfPacketFilterCapabilities(StaApfPacketFilterCapabilities*) override { return Unsupported(); }
  ScopedAStatus getBackgroundScanCapabilities(StaBackgroundScanCapabilities*) override { return Unsupported(); }
  ScopedAStatus getDebugRxPacketFates(std::vector<WifiDebugRxPacketFateReport>*) override { return Unsupported(); }
  ScopedAStatus getDebugTxPacketFates(std::vector<WifiDebugTxPacketFateReport>*) override { return Unsupported(); }
  ScopedAStatus getLinkLayerStats(StaLinkLayerStats*) override { return Unsupported(); }
  ScopedAStatus getRoamingCapabilities(StaRoamingCapabilities*) override { return Unsupported(); }
  ScopedAStatus installApfPacketFilter(const std::vector<uint8_t>&) override { return Unsupported(); }
  ScopedAStatus readApfPacketFilterData(std::vector<uint8_t>*) override { return Unsupported(); }
  ScopedAStatus setRoamingState(StaRoamingState) override { return Unsupported(); }
  ScopedAStatus setScanMode(bool) override { return Unsupported(); }
  ScopedAStatus startBackgroundScan(int32_t, const StaBackgroundScanParameters&) override { return Unsupported(); }
  ScopedAStatus startDebugPacketFateMonitoring() override { return Unsupported(); }
  ScopedAStatus startRssiMonitoring(int32_t, int32_t, int32_t) override { return Unsupported(); }
  ScopedAStatus startSendingKeepAlivePackets(int32_t, const std::vector<uint8_t>&, char16_t,
                                             const std::array<uint8_t, 6>&, const std::array<uint8_t, 6>&,
                                             int32_t) override {
    return Unsupported();
  }
  ScopedAStatus stopBackgroundScan(int32_t) override { return Unsupported(); }
  ScopedAStatus stopRssiMonitoring(int32_t) override { return Unsupported(); }
  ScopedAStatus stopSendingKeepAlivePackets(int32_t) override { return Unsupported(); }
  ScopedAStatus setDtimMultiplier(int32_t) override { return Unsupported(); }
  ScopedAStatus getCachedScanData(CachedScanData*) override { return Unsupported(); }
  ScopedAStatus twtGetCapabilities(TwtCapabilities*) override { return Unsupported(); }
  ScopedAStatus twtSessionSetup(int32_t, const TwtRequest&) override { return Unsupported(); }
  ScopedAStatus twtSessionUpdate(int32_t, int32_t, const TwtRequest&) override { return Unsupported(); }
  ScopedAStatus twtSessionSuspend(int32_t, int32_t) override { return Unsupported(); }
  ScopedAStatus twtSessionResume(int32_t, int32_t) override { return Unsupported(); }
  ScopedAStatus twtSessionTeardown(int32_t, int32_t) override { return Unsupported(); }
  ScopedAStatus twtSessionGetStats(int32_t, int32_t) override { return Unsupported(); }

 private:
  ScopedAStatus Invalid() const { return Status(WifiStatusCode::ERROR_WIFI_IFACE_INVALID); }
  ScopedAStatus Unsupported() const {
    return valid_ ? Status(WifiStatusCode::ERROR_NOT_SUPPORTED) : Invalid();
  }

  // read the wiphy's permanent address from sysfs
  bool ReadPhyAddress(std::array<uint8_t, 6>* mac) const {
    const std::string path = "/sys/class/net/" + name_ + "/phy80211/macaddress";
    FILE* f = fopen(path.c_str(), "re");
    if (!f) return false;
    unsigned b[6];
    const int n = fscanf(f, "%x:%x:%x:%x:%x:%x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]);
    fclose(f);
    if (n != 6) return false;
    for (int i = 0; i < 6; i++) (*mac)[i] = uint8_t(b[i]);
    return rhizo_wifi::UsableUnicast(*mac);
  }

  std::shared_ptr<Radio> radio_;
  const std::string name_;
  std::atomic<bool> valid_{true};
  CallbackList<IWifiStaIfaceEventCallback> callbacks_;
};

// single chip with one mode and one STA combination
class RhizoWifiChip : public BnWifiChip {
 public:
  explicit RhizoWifiChip(std::shared_ptr<Radio> radio) : radio_(std::move(radio)) {}

  // drop the chip and its iface from service
  void Invalidate() {
    std::shared_ptr<RhizoWifiStaIface> sta;
    {
      std::lock_guard<std::mutex> lg(mu_);
      valid_ = false;
      sta.swap(sta_);
    }
    if (sta) sta->Invalidate();
    callbacks_.Clear();
  }

  ScopedAStatus getId(int32_t* out) override {
    if (!valid_) return Invalid();
    *out = kChipId;
    return ScopedAStatus::ok();
  }

  ScopedAStatus getAvailableModes(std::vector<IWifiChip::ChipMode>* out) override {
    if (!valid_) return Invalid();
    IWifiChip::ChipConcurrencyCombinationLimit limit;
    limit.types = {IfaceConcurrencyType::STA};
    limit.maxIfaces = 1;
    IWifiChip::ChipConcurrencyCombination combo;
    combo.limits = {limit};
    IWifiChip::ChipMode mode;
    mode.id = kStaModeId;
    mode.availableCombinations = {combo};
    *out = {mode};
    return ScopedAStatus::ok();
  }

  ScopedAStatus configureChip(int32_t mode) override {
    if (!valid_) return Invalid();
    if (mode != kStaModeId) return Status(WifiStatusCode::ERROR_INVALID_ARGS);
    bool changed;
    {
      std::lock_guard<std::mutex> lg(mu_);
      changed = !configured_;
      configured_ = true;
    }
    if (changed) {
      klogf("chip configured to mode %d", mode);
      callbacks_.ForEach([&](const auto& cb) { cb->onChipReconfigured(mode); });
    }
    return ScopedAStatus::ok();
  }

  ScopedAStatus getMode(int32_t* out) override {
    if (!valid_) return Invalid();
    std::lock_guard<std::mutex> lg(mu_);
    if (!configured_) return Status(WifiStatusCode::ERROR_NOT_AVAILABLE);
    *out = kStaModeId;
    return ScopedAStatus::ok();
  }

  ScopedAStatus getFeatureSet(int32_t* out) override {
    if (!valid_) return Invalid();
    *out = 0;
    return ScopedAStatus::ok();
  }

  ScopedAStatus registerEventCallback(const std::shared_ptr<IWifiChipEventCallback>& cb) override {
    if (!valid_) return Invalid();
    if (!cb) return Status(WifiStatusCode::ERROR_INVALID_ARGS);
    callbacks_.Add(cb);
    return ScopedAStatus::ok();
  }

  ScopedAStatus createStaIface(std::shared_ptr<IWifiStaIface>* out) override {
    if (!valid_) return Invalid();
    std::shared_ptr<RhizoWifiStaIface> sta;
    {
      std::lock_guard<std::mutex> lg(mu_);
      if (!configured_ || sta_) return Status(WifiStatusCode::ERROR_NOT_AVAILABLE);
      if (if_nametoindex(radio_->iface.c_str()) == 0) {
        klogf("createStaIface: no netdev %s", radio_->iface.c_str());
        return Status(WifiStatusCode::ERROR_UNKNOWN);
      }
      sta_ = ndk::SharedRefBase::make<RhizoWifiStaIface>(radio_);
      sta = sta_;
    }
    klogf("sta iface %s claimed", sta->name().c_str());
    callbacks_.ForEach([&](const auto& cb) { cb->onIfaceAdded(IfaceType::STA, sta->name()); });
    *out = sta;
    return ScopedAStatus::ok();
  }

  ScopedAStatus removeStaIface(const std::string& name) override {
    if (!valid_) return Invalid();
    std::shared_ptr<RhizoWifiStaIface> sta;
    {
      std::lock_guard<std::mutex> lg(mu_);
      if (!sta_ || sta_->name() != name) return Status(WifiStatusCode::ERROR_INVALID_ARGS);
      sta.swap(sta_);
    }
    sta->Invalidate();
    klogf("sta iface %s released", name.c_str());
    callbacks_.ForEach([&](const auto& cb) { cb->onIfaceRemoved(IfaceType::STA, name); });
    return ScopedAStatus::ok();
  }

  ScopedAStatus getStaIface(const std::string& name, std::shared_ptr<IWifiStaIface>* out) override {
    if (!valid_) return Invalid();
    std::lock_guard<std::mutex> lg(mu_);
    if (!sta_ || sta_->name() != name) return Status(WifiStatusCode::ERROR_INVALID_ARGS);
    *out = sta_;
    return ScopedAStatus::ok();
  }

  ScopedAStatus getStaIfaceNames(std::vector<std::string>* out) override {
    if (!valid_) return Invalid();
    std::lock_guard<std::mutex> lg(mu_);
    out->clear();
    if (sta_) out->push_back(sta_->name());
    return ScopedAStatus::ok();
  }

  ScopedAStatus getApIfaceNames(std::vector<std::string>* out) override { return Empty(out); }
  ScopedAStatus getP2pIfaceNames(std::vector<std::string>* out) override { return Empty(out); }
  ScopedAStatus getNanIfaceNames(std::vector<std::string>* out) override { return Empty(out); }
  ScopedAStatus getApIface(const std::string&, std::shared_ptr<IWifiApIface>*) override { return NoSuchIface(); }
  ScopedAStatus getP2pIface(const std::string&, std::shared_ptr<IWifiP2pIface>*) override { return NoSuchIface(); }
  ScopedAStatus getNanIface(const std::string&, std::shared_ptr<IWifiNanIface>*) override { return NoSuchIface(); }
  ScopedAStatus removeApIface(const std::string&) override { return NoSuchIface(); }
  ScopedAStatus removeP2pIface(const std::string&) override { return NoSuchIface(); }
  ScopedAStatus removeNanIface(const std::string&) override { return NoSuchIface(); }

  ScopedAStatus setCountryCode(const std::array<uint8_t, 2>& code) override {
    if (!valid_) return Invalid();
    std::lock_guard<std::mutex> lg(mu_);
    if (code != country_) {
      country_ = code;
      klogf("chip country code recorded as %c%c, not forwarded to cfg80211", code[0], code[1]);
    }
    return ScopedAStatus::ok();
  }

  ScopedAStatus requestChipDebugInfo(IWifiChip::ChipDebugInfo* out) override {
    if (!valid_) return Invalid();
    utsname u{};
    uname(&u);
    std::string driver, version = u.release, firmware;
    ethtool_drvinfo info;
    if (rhizo_wifi::GetDrvInfo(radio_->iface, &info) == 0) {
      driver = Field(info.driver, sizeof(info.driver));
      if (!Field(info.version, sizeof(info.version)).empty()) version = Field(info.version, sizeof(info.version));
      firmware = Field(info.fw_version, sizeof(info.fw_version));
    }
    if (driver.empty()) {
      std::lock_guard<std::mutex> lg(radio_->mu);
      std::string why;
      rhizo_wifi::WiphyInfo w;
      driver = "cfg80211";
      if (radio_->CheckLocked(&why) && radio_->nl.GetWiphy(radio_->wiphy, &w) == 0 && !w.name.empty())
        driver += " wiphy " + w.name;
    }
    out->driverDescription = driver + ", kernel " + version;
    out->firmwareDescription = firmware.empty() ? "none" : firmware;
    return ScopedAStatus::ok();
  }

  ScopedAStatus createApIface(std::shared_ptr<IWifiApIface>*) override { return Unsupported(); }
  ScopedAStatus createBridgedApIface(std::shared_ptr<IWifiApIface>*) override { return Unsupported(); }
  ScopedAStatus createNanIface(std::shared_ptr<IWifiNanIface>*) override { return Unsupported(); }
  ScopedAStatus createP2pIface(std::shared_ptr<IWifiP2pIface>*) override { return Unsupported(); }
  ScopedAStatus createRttController(const std::shared_ptr<IWifiStaIface>&,
                                    std::shared_ptr<IWifiRttController>*) override {
    return Unsupported();
  }
  ScopedAStatus createApOrBridgedApIface(IfaceConcurrencyType, const std::vector<OuiKeyedData>&,
                                         std::shared_ptr<IWifiApIface>*) override {
    return Unsupported();
  }
  ScopedAStatus createApOrBridgedApIfaceWithParams(const IWifiChip::ApIfaceParams&,
                                                   std::shared_ptr<IWifiApIface>*) override {
    return Unsupported();
  }
  ScopedAStatus removeIfaceInstanceFromBridgedApIface(const std::string&, const std::string&) override {
    return Unsupported();
  }
  ScopedAStatus enableDebugErrorAlerts(bool) override { return Unsupported(); }
  ScopedAStatus flushRingBufferToFile() override { return Unsupported(); }
  ScopedAStatus forceDumpToDebugRingBuffer(const std::string&) override { return Unsupported(); }
  ScopedAStatus getDebugHostWakeReasonStats(WifiDebugHostWakeReasonStats*) override { return Unsupported(); }
  ScopedAStatus getDebugRingBuffersStatus(std::vector<WifiDebugRingBufferStatus>*) override { return Unsupported(); }
  ScopedAStatus startLoggingToDebugRingBuffer(const std::string&, WifiDebugRingBufferVerboseLevel, int32_t,
                                              int32_t) override {
    return Unsupported();
  }
  ScopedAStatus stopLoggingToDebugRingBuffer() override { return Unsupported(); }
  ScopedAStatus requestDriverDebugDump(std::vector<uint8_t>*) override { return Unsupported(); }
  ScopedAStatus requestFirmwareDebugDump(std::vector<uint8_t>*) override { return Unsupported(); }
  ScopedAStatus triggerSubsystemRestart() override { return Unsupported(); }
  ScopedAStatus getSupportedRadioCombinations(std::vector<WifiRadioCombination>*) override { return Unsupported(); }
  ScopedAStatus getWifiChipCapabilities(WifiChipCapabilities*) override { return Unsupported(); }
  ScopedAStatus getUsableChannels(WifiBand, int32_t, int32_t, std::vector<WifiUsableChannel>*) override {
    return Unsupported();
  }
  ScopedAStatus setAfcChannelAllowance(const AfcChannelAllowance&) override { return Unsupported(); }
  ScopedAStatus setCoexUnsafeChannels(const std::vector<IWifiChip::CoexUnsafeChannel>&, int32_t) override {
    return Unsupported();
  }
  ScopedAStatus setLatencyMode(IWifiChip::LatencyMode) override { return Unsupported(); }
  ScopedAStatus selectTxPowerScenario(IWifiChip::TxPowerScenario) override { return Unsupported(); }
  ScopedAStatus resetTxPowerScenario() override { return Unsupported(); }
  ScopedAStatus setMultiStaPrimaryConnection(const std::string&) override { return Unsupported(); }
  ScopedAStatus setMultiStaUseCase(IWifiChip::MultiStaUseCase) override { return Unsupported(); }
  ScopedAStatus enableStaChannelForPeerNetwork(int32_t) override { return Unsupported(); }
  ScopedAStatus setMloMode(IWifiChip::ChipMloMode) override { return Unsupported(); }
  ScopedAStatus setVoipMode(IWifiChip::VoipMode) override { return Unsupported(); }

 private:
  ScopedAStatus Invalid() const { return Status(WifiStatusCode::ERROR_WIFI_CHIP_INVALID); }
  ScopedAStatus Unsupported() const {
    return valid_ ? Status(WifiStatusCode::ERROR_NOT_SUPPORTED) : Invalid();
  }
  ScopedAStatus NoSuchIface() const {
    return valid_ ? Status(WifiStatusCode::ERROR_INVALID_ARGS) : Invalid();
  }
  ScopedAStatus Empty(std::vector<std::string>* out) const {
    if (!valid_) return Invalid();
    out->clear();
    return ScopedAStatus::ok();
  }

  // read a NUL-padded ethtool string, empty for "N/A"
  static std::string Field(const char* p, size_t n) {
    std::string s(p, strnlen(p, n));
    return s == "N/A" ? std::string() : s;
  }

  std::shared_ptr<Radio> radio_;
  std::atomic<bool> valid_{true};
  std::mutex mu_;
  bool configured_ = false;
  std::array<uint8_t, 2> country_{};
  std::shared_ptr<RhizoWifiStaIface> sta_;
  CallbackList<IWifiChipEventCallback> callbacks_;
};

// software HAL for IWifi
class RhizoWifi : public BnWifi {
 public:
  RhizoWifi() : radio_(std::make_shared<Radio>()) {}

  ScopedAStatus start() override {
    std::lock_guard<std::mutex> lg(mu_);
    if (chip_) return ScopedAStatus::ok();
    std::string why;
    {
      std::lock_guard<std::mutex> rl(radio_->mu);
      if (!radio_->CheckLocked(&why)) {
        klogf("start FAILED: %s", why.c_str());
        return Status(WifiStatusCode::ERROR_UNKNOWN);
      }
    }
    StartMonitorLocked();
    chip_ = ndk::SharedRefBase::make<RhizoWifiChip>(radio_);
    klogf("started on %s (ifindex %u, wiphy %u)", radio_->iface.c_str(), radio_->ifindex, radio_->wiphy);
    callbacks_.ForEach([](const auto& cb) { cb->onStart(); });
    return ScopedAStatus::ok();
  }

  ScopedAStatus stop() override {
    std::lock_guard<std::mutex> lg(mu_);
    if (!chip_) return ScopedAStatus::ok();
    chip_->Invalidate();
    chip_.reset();
    int rc = rhizo_wifi::SetUp(radio_->iface, false);
    if (rc != 0 && rc != -ENODEV) klogf("stop: %s down FAILED: %s", radio_->iface.c_str(), strerror(-rc));
    klog("stopped");
    callbacks_.ForEach([](const auto& cb) { cb->onStop(); });
    return ScopedAStatus::ok();
  }

  ScopedAStatus isStarted(bool* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    *out = chip_ != nullptr;
    return ScopedAStatus::ok();
  }

  ScopedAStatus getChipIds(std::vector<int32_t>* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    if (!chip_) return Status(WifiStatusCode::ERROR_NOT_STARTED);
    *out = {kChipId};
    return ScopedAStatus::ok();
  }

  ScopedAStatus getChip(int32_t id, std::shared_ptr<IWifiChip>* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    if (!chip_) return Status(WifiStatusCode::ERROR_NOT_STARTED);
    if (id != kChipId) return Status(WifiStatusCode::ERROR_INVALID_ARGS);
    *out = chip_;
    return ScopedAStatus::ok();
  }

  ScopedAStatus registerEventCallback(const std::shared_ptr<IWifiEventCallback>& cb) override {
    if (!cb) return Status(WifiStatusCode::ERROR_INVALID_ARGS);
    callbacks_.Add(cb);
    return ScopedAStatus::ok();
  }

 private:
  // watch nl80211's config group for a vanished netdev or wiphy
  void StartMonitorLocked() {
    if (monitor_.joinable()) return;
    auto group = radio_->nl.family().groups.find(NL80211_MULTICAST_GROUP_CONFIG);
    if (group == radio_->nl.family().groups.end() || !events_.Open(0) || !events_.Join(group->second)) {
      klog("nl80211 config group unavailable, wiphy loss will not be reported");
      return;
    }
    monitor_ = std::thread([this] { MonitorLoop(); });
  }

  // report a vanished netdev or wiphy as a failure
  void MonitorLoop() {
    for (;;) {
      pollfd pfd{events_.fd(), POLLIN, 0};
      if (poll(&pfd, 1, -1) < 0) {
        if (errno == EINTR) continue;
        klogf("nl80211 monitor poll FAILED: %s", strerror(errno));
        return;
      }
      uint32_t ifindex, wiphy;
      {
        std::lock_guard<std::mutex> rl(radio_->mu);
        ifindex = radio_->ifindex;
        wiphy = radio_->wiphy;
      }
      bool lost = false;
      if (!events_.ReadEvents([&](const rhizo_wifi::Reply& r) {
            if (r.cmd == NL80211_CMD_DEL_INTERFACE && r.attrs.U32(NL80211_ATTR_IFINDEX) == ifindex) lost = true;
            if (r.cmd == NL80211_CMD_DEL_WIPHY && r.attrs.U32(NL80211_ATTR_WIPHY, UINT32_MAX) == wiphy) lost = true;
          })) {
        klogf("nl80211 monitor read FAILED: %s", strerror(errno));
        return;
      }
      if (lost) OnRadioLost();
    }
  }

  // drop the chip and report the radio as lost
  void OnRadioLost() {
    std::lock_guard<std::mutex> lg(mu_);
    if (!chip_) return;
    chip_->Invalidate();
    chip_.reset();
    klogf("%s or its wiphy went away, reporting failure", radio_->iface.c_str());
    callbacks_.ForEach([](const auto& cb) { cb->onFailure(WifiStatusCode::ERROR_UNKNOWN); });
  }

  std::mutex mu_;
  std::shared_ptr<Radio> radio_;
  std::shared_ptr<RhizoWifiChip> chip_;
  CallbackList<IWifiEventCallback> callbacks_;
  rhizo_wifi::Socket events_;
  std::thread monitor_;
};

}

int main() {
  klog("main() entered");
  ABinderProcess_setThreadPoolMaxThreadCount(4);
  auto wifi = ndk::SharedRefBase::make<RhizoWifi>();
  const std::string instance = std::string(RhizoWifi::descriptor) + "/default";
  binder_status_t status = AServiceManager_addService(wifi->asBinder().get(), instance.c_str());
  if (status != STATUS_OK) {
    klogf("addService FAILED status=%d", status);
    return 1;
  }
  klog("registered, joining thread pool");
  ABinderProcess_startThreadPool();
  ABinderProcess_joinThreadPool();
  klog("joinThreadPool RETURNED (unexpected)");
  return 0;
}
