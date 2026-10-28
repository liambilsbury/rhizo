#include "common.h"
#include "sta_iface.h"
#include "rhizo/wifi_netdev.h"
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <net/if.h>
#include <unistd.h>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>

using namespace rhizo_supplicant;

namespace {

// software HAL for ISupplicant
class RhizoSupplicant : public BnSupplicant {
 public:
  ScopedAStatus addStaInterface(const std::string& name, std::shared_ptr<ISupplicantStaIface>* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    if (sta_.count(name)) return Status(SupplicantStatusCode::FAILURE_IFACE_EXISTS);
    int rc = Engine::Get().Init();
    if (rc != 0) {
      klogf("addStaInterface %s: nl80211 unavailable: %s", name.c_str(), strerror(-rc));
      return Status(SupplicantStatusCode::FAILURE_UNKNOWN);
    }
    const uint32_t ifindex = if_nametoindex(name.c_str());
    if (ifindex == 0) {
      klogf("addStaInterface: no netdev %s", name.c_str());
      return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
    }
    rhizo_wifi::IfaceInfo info;
    rc = Engine::Get().nl().GetInterface(ifindex, &info);
    if (rc != 0 || info.iftype != NL80211_IFTYPE_STATION) {
      klogf("addStaInterface: %s is not a cfg80211 station (%s)", name.c_str(), rc ? strerror(-rc) : "iftype");
      return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
    }
    if (!info.ssid.empty()) {
      klogf("%s still associated from an earlier owner, leaving", name.c_str());
      Engine::Get().nl().Disconnect(ifindex, 3);
    }
    rc = rhizo_wifi::SetUp(name, true);
    if (rc != 0) klogf("%s up FAILED: %s", name.c_str(), strerror(-rc));
    auto iface = ndk::SharedRefBase::make<StaIface>(name, ifindex);
    std::weak_ptr<StaIface> weak = iface;
    iface->OnCallbacksDied([this, weak] {
      auto i = weak.lock();
      if (!i) return;
      klogf("%s: every callback's process died, removing it", i->name().c_str());
      RemoveSta(i->name(), i.get());
    });
    Engine::Get().Add(iface);
    sta_[name] = iface;
    klogf("sta interface %s added (ifindex %u)", name.c_str(), ifindex);
    callbacks_.ForEach([&](const auto& cb) { cb->onInterfaceCreated(name); });
    *out = iface;
    return ScopedAStatus::ok();
  }

  ScopedAStatus removeInterface(const IfaceInfo& info) override {
    if (info.type != IfaceType::STA || !RemoveSta(info.name, nullptr))
      return Status(SupplicantStatusCode::FAILURE_IFACE_UNKNOWN);
    return ScopedAStatus::ok();
  }

  ScopedAStatus getStaInterface(const std::string& name, std::shared_ptr<ISupplicantStaIface>* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    auto it = sta_.find(name);
    if (it == sta_.end()) return Status(SupplicantStatusCode::FAILURE_IFACE_UNKNOWN);
    *out = it->second;
    return ScopedAStatus::ok();
  }

  ScopedAStatus listInterfaces(std::vector<IfaceInfo>* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    out->clear();
    for (auto& s : sta_) {
      IfaceInfo i;
      i.type = IfaceType::STA;
      i.name = s.first;
      out->push_back(i);
    }
    return ScopedAStatus::ok();
  }

  ScopedAStatus setDebugParams(DebugLevel level, bool show_timestamp, bool show_keys) override {
    if (Bits(level) < Bits(DebugLevel::EXCESSIVE) || Bits(level) > Bits(DebugLevel::ERROR))
      return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
    std::lock_guard<std::mutex> lg(mu_);
    level_ = level;
    show_timestamp_ = show_timestamp;
    show_keys_ = show_keys;
    return ScopedAStatus::ok();
  }

  ScopedAStatus getDebugLevel(DebugLevel* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    *out = level_;
    return ScopedAStatus::ok();
  }

  ScopedAStatus isDebugShowTimestampEnabled(bool* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    *out = show_timestamp_;
    return ScopedAStatus::ok();
  }

  ScopedAStatus isDebugShowKeysEnabled(bool* out) override {
    std::lock_guard<std::mutex> lg(mu_);
    *out = show_keys_;
    return ScopedAStatus::ok();
  }

  ScopedAStatus setConcurrencyPriority(IfaceType type) override {
    if (type != IfaceType::STA && type != IfaceType::P2P) return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
    std::lock_guard<std::mutex> lg(mu_);
    priority_ = type;
    return ScopedAStatus::ok();
  }

  ScopedAStatus registerCallback(const std::shared_ptr<ISupplicantCallback>& cb) override {
    if (!cb) return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
    callbacks_.Add(cb);
    return ScopedAStatus::ok();
  }

  ScopedAStatus registerNonStandardCertCallback(const std::shared_ptr<INonStandardCertCallback>& cb) override {
    if (!cb) return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
    std::lock_guard<std::mutex> lg(mu_);
    cert_callback_ = cb;
    return ScopedAStatus::ok();
  }

  ScopedAStatus terminate() override {
    klog("terminate: leaving associations and exiting");
    std::lock_guard<std::mutex> lg(mu_);
    for (auto& s : sta_) s.second->Shutdown();
    _exit(0);
  }

  ScopedAStatus addP2pInterface(const std::string&, std::shared_ptr<ISupplicantP2pIface>*) override {
    return Status(SupplicantStatusCode::FAILURE_UNSUPPORTED);
  }
  ScopedAStatus getP2pInterface(const std::string&, std::shared_ptr<ISupplicantP2pIface>*) override {
    return Status(SupplicantStatusCode::FAILURE_UNSUPPORTED);
  }

 private:
  // take the named interface out of service
  bool RemoveSta(const std::string& name, const StaIface* only) {
    std::shared_ptr<StaIface> iface;
    {
      std::lock_guard<std::mutex> lg(mu_);
      auto it = sta_.find(name);
      if (it == sta_.end() || (only && it->second.get() != only)) return false;
      iface = it->second;
      sta_.erase(it);
    }
    iface->Remove();
    klogf("sta interface %s removed", name.c_str());
    callbacks_.ForEach([&](const auto& cb) { cb->onInterfaceRemoved(name); });
    return true;
  }

  std::mutex mu_;
  std::map<std::string, std::shared_ptr<StaIface>> sta_;
  DebugLevel level_ = DebugLevel::INFO;
  bool show_timestamp_ = false;
  bool show_keys_ = false;
  IfaceType priority_ = IfaceType::STA;
  std::shared_ptr<INonStandardCertCallback> cert_callback_;
  rhizo_wifi::CallbackList<ISupplicantCallback> callbacks_;
};

}

int main() {
  klog("main() entered");
  ABinderProcess_setThreadPoolMaxThreadCount(4);
  auto supplicant = ndk::SharedRefBase::make<RhizoSupplicant>();
  const std::string instance = std::string(RhizoSupplicant::descriptor) + "/default";
  binder_status_t status = AServiceManager_addService(supplicant->asBinder().get(), instance.c_str());
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
