#pragma once
#include "common.h"
#include "sta_network.h"
#include "rhizo/wifi_callbacks.h"
#include "rhizo/wifi_nl80211.h"
#include <atomic>
#include <chrono>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

namespace rhizo_supplicant {

using Clock = std::chrono::steady_clock;

// STA netdev with its networks and association state machine
class StaIface : public BnSupplicantStaIface {
 public:
  StaIface(std::string name, uint32_t ifindex);

  // command posted to an interface
  enum class Cmd { kSelect, kEnable, kDisconnect, kReconnect, kReassociate, kForget, kRemove };
  void Post(Cmd cmd, int32_t net = -1);
  void OnNlEvent(const rhizo_wifi::Reply& r);
  void Step(Clock::time_point now);
  bool NextDeadline(Clock::time_point* at);
  bool Finished();
  void Remove();
  void Shutdown();
  void OnCallbacksDied(std::function<void()> fn);
  const std::string& name() const { return name_; }

  ScopedAStatus getName(std::string* out) override;
  ScopedAStatus getType(IfaceType* out) override;
  ScopedAStatus registerCallback(const std::shared_ptr<ISupplicantStaIfaceCallback>& cb) override;
  ScopedAStatus addNetwork(std::shared_ptr<ISupplicantStaNetwork>* out) override;
  ScopedAStatus removeNetwork(int32_t id) override;
  ScopedAStatus getNetwork(int32_t id, std::shared_ptr<ISupplicantStaNetwork>* out) override;
  ScopedAStatus listNetworks(std::vector<int32_t>* out) override;
  ScopedAStatus disconnect() override;
  ScopedAStatus reconnect() override;
  ScopedAStatus reassociate() override;
  ScopedAStatus enableAutoReconnect(bool enable) override;
  ScopedAStatus getMacAddress(std::vector<uint8_t>* out) override;
  ScopedAStatus getKeyMgmtCapabilities(KeyMgmtMask* out) override;
  ScopedAStatus getWpaDriverCapabilities(WpaDriverCapabilitiesMask* out) override;
  ScopedAStatus getConnectionCapabilities(ConnectionCapabilities* out) override;
  ScopedAStatus getConnectionMloLinksInfo(MloLinksInfo* out) override;
  ScopedAStatus getSignalPollResults(std::vector<SignalPollResult>* out) override;
  ScopedAStatus setPowerSave(bool enable) override;
  ScopedAStatus setCountryCode(const std::vector<uint8_t>& code) override;

  ScopedAStatus setBtCoexistenceMode(BtCoexistenceMode v) override { return Record([&] { bt_coex_mode_ = v; }); }
  ScopedAStatus setBtCoexistenceScanModeEnabled(bool v) override { return Record([&] { bt_coex_scan_ = v; }); }
  ScopedAStatus setSuspendModeEnabled(bool v) override { return Record([&] { suspend_mode_ = v; }); }
  ScopedAStatus setExternalSim(bool v) override { return Record([&] { external_sim_ = v; }); }
  ScopedAStatus setQosPolicyFeatureEnabled(bool v) override { return Record([&] { qos_policy_ = v; }); }
  ScopedAStatus removeAllQosPolicies() override { return Record([] {}); }
  ScopedAStatus setWpsDeviceName(const std::string& v) override { return Record([&] { wps_.device_name = v; }); }
  ScopedAStatus setWpsDeviceType(const std::vector<uint8_t>& v) override {
    return Record([&] { wps_.device_type = v; });
  }
  ScopedAStatus setWpsManufacturer(const std::string& v) override { return Record([&] { wps_.manufacturer = v; }); }
  ScopedAStatus setWpsModelName(const std::string& v) override { return Record([&] { wps_.model_name = v; }); }
  ScopedAStatus setWpsModelNumber(const std::string& v) override { return Record([&] { wps_.model_number = v; }); }
  ScopedAStatus setWpsSerialNumber(const std::string& v) override { return Record([&] { wps_.serial_number = v; }); }
  ScopedAStatus setWpsConfigMethods(WpsConfigMethods v) override { return Record([&] { wps_.config_methods = v; }); }
  ScopedAStatus sendQosPolicyResponse(int32_t, bool, const std::vector<QosPolicyStatus>&) override {
    return Fail(SupplicantStatusCode::FAILURE_ARGS_INVALID);
  }

  ScopedAStatus addDppPeerUri(const std::string&, int32_t*) override { return Unsupported(); }
  ScopedAStatus removeDppUri(int32_t) override { return Unsupported(); }
  ScopedAStatus generateDppBootstrapInfoForResponder(const std::vector<uint8_t>&, const std::string&, DppCurve,
                                                     DppResponderBootstrapInfo*) override {
    return Unsupported();
  }
  ScopedAStatus generateSelfDppConfiguration(const std::string&, const std::vector<uint8_t>&) override {
    return Unsupported();
  }
  ScopedAStatus startDppConfiguratorInitiator(int32_t, int32_t, const std::string&, const std::string&,
                                              const std::string&, DppNetRole, DppAkm, const std::vector<uint8_t>&,
                                              std::vector<uint8_t>*) override {
    return Unsupported();
  }
  ScopedAStatus startDppEnrolleeInitiator(int32_t, int32_t) override { return Unsupported(); }
  ScopedAStatus startDppEnrolleeResponder(int32_t) override { return Unsupported(); }
  ScopedAStatus stopDppInitiator() override { return Unsupported(); }
  ScopedAStatus stopDppResponder(int32_t) override { return Unsupported(); }
  ScopedAStatus addExtRadioWork(const std::string&, int32_t, int32_t, int32_t*) override { return Unsupported(); }
  ScopedAStatus removeExtRadioWork(int32_t) override { return Unsupported(); }
  ScopedAStatus addRxFilter(RxFilterType) override { return Unsupported(); }
  ScopedAStatus removeRxFilter(RxFilterType) override { return Unsupported(); }
  ScopedAStatus startRxFilter() override { return Unsupported(); }
  ScopedAStatus stopRxFilter() override { return Unsupported(); }
  ScopedAStatus cancelWps() override { return Unsupported(); }
  ScopedAStatus startWpsPbc(const std::vector<uint8_t>&) override { return Unsupported(); }
  ScopedAStatus startWpsPinDisplay(const std::vector<uint8_t>&, std::string*) override { return Unsupported(); }
  ScopedAStatus startWpsPinKeypad(const std::string&) override { return Unsupported(); }
  ScopedAStatus startWpsRegistrar(const std::vector<uint8_t>&, const std::string&) override { return Unsupported(); }
  ScopedAStatus filsHlpAddRequest(const std::vector<uint8_t>&, const std::vector<uint8_t>&) override {
    return Unsupported();
  }
  ScopedAStatus filsHlpFlushRequest() override { return Unsupported(); }
  ScopedAStatus initiateAnqpQuery(const std::vector<uint8_t>&, const std::vector<AnqpInfoId>&,
                                  const std::vector<Hs20AnqpSubtypes>&) override {
    return Unsupported();
  }
  ScopedAStatus initiateHs20IconQuery(const std::vector<uint8_t>&, const std::string&) override {
    return Unsupported();
  }
  ScopedAStatus initiateVenueUrlAnqpQuery(const std::vector<uint8_t>&) override { return Unsupported(); }
  ScopedAStatus initiateTdlsDiscover(const std::vector<uint8_t>&) override { return Unsupported(); }
  ScopedAStatus initiateTdlsSetup(const std::vector<uint8_t>&) override { return Unsupported(); }
  ScopedAStatus initiateTdlsTeardown(const std::vector<uint8_t>&) override { return Unsupported(); }
  ScopedAStatus setMboCellularDataStatus(bool) override { return Unsupported(); }
  ScopedAStatus addQosPolicyRequestForScs(const std::vector<QosPolicyScsData>&,
                                          std::vector<QosPolicyScsRequestStatus>*) override {
    return Unsupported();
  }
  ScopedAStatus removeQosPolicyForScs(const std::vector<uint8_t>&, std::vector<QosPolicyScsRequestStatus>*) override {
    return Unsupported();
  }
  ScopedAStatus configureMscs(const MscsParams&) override { return Unsupported(); }
  ScopedAStatus disableMscs() override { return Unsupported(); }

 private:
  enum class Phase { kIdle, kLeaving, kScanning, kConnecting, kConnected, kRetryWait };

  // BSS of an attempt or association
  struct Target {
    int32_t net = -1;
    std::vector<uint8_t> ssid;
    std::array<uint8_t, 6> bssid{};
    uint32_t freq = 0;
  };

  // recorded WPS settings
  struct WpsSettings {
    std::string device_name, manufacturer, model_name, model_number, serial_number;
    std::vector<uint8_t> device_type;
    WpsConfigMethods config_methods = WpsConfigMethods(0);
  };

  ScopedAStatus Invalid() const { return Status(SupplicantStatusCode::FAILURE_IFACE_INVALID); }
  ScopedAStatus Fail(SupplicantStatusCode c) const { return valid_ ? Status(c) : Invalid(); }
  ScopedAStatus Unsupported() const { return Fail(SupplicantStatusCode::FAILURE_UNSUPPORTED); }
  // store a hint under the lock
  template <typename F>
  ScopedAStatus Record(F f) {
    if (!valid_) return Invalid();
    std::lock_guard<std::mutex> lg(mu_);
    f();
    return ScopedAStatus::ok();
  }

  void RunLocked(Cmd cmd, int32_t net, Clock::time_point now);
  void BeginLocked(int32_t net, bool allow_scan, bool retry, Clock::time_point now);
  void FindLocked(Clock::time_point now);
  void ConnectLocked(const NetworkConfig& cfg, const rhizo_wifi::Bss& bss, Clock::time_point now);
  void NotFoundLocked(Clock::time_point now);
  void RejectedLocked(int status, bool timed_out);
  void LostLocked(uint16_t reason, bool locally);
  void AbortLocked();
  void AfterLeaveLocked(Clock::time_point now);
  bool MatchLocked(const NetworkConfig& cfg, rhizo_wifi::Bss* out);
  bool ConfigLocked(int32_t net, NetworkConfig* out);
  void EmitStateLocked(StaIfaceCallbackState s, bool network_specific);
  void EmitDisconnectedLocked();

  const std::string name_;
  const uint32_t ifindex_;
  std::atomic<bool> valid_{true};
  std::mutex mu_;
  std::map<int32_t, std::shared_ptr<StaNetwork>> networks_;
  int32_t next_id_ = 0;
  std::deque<std::pair<Cmd, int32_t>> cmds_;
  rhizo_wifi::CallbackList<ISupplicantStaIfaceCallback> callbacks_;

  Phase phase_ = Phase::kIdle;
  StaIfaceCallbackState state_ = StaIfaceCallbackState::DISCONNECTED;
  Target target_;
  bool leaving_connected_ = false;
  int32_t want_ = -1;
  bool allow_scan_ = false;
  bool retry_ = false;
  bool scanned_ = false;
  int not_found_ = 0;
  bool has_deadline_ = false;
  Clock::time_point deadline_{};
  int32_t selected_ = -1;
  bool explicit_disconnect_ = false;
  bool auto_reconnect_ = true;
  bool removed_ = false;
  bool finished_ = false;

  BtCoexistenceMode bt_coex_mode_ = BtCoexistenceMode::SENSE;
  bool bt_coex_scan_ = false;
  bool suspend_mode_ = false;
  bool external_sim_ = false;
  bool qos_policy_ = false;
  std::array<uint8_t, 2> country_{};
  WpsSettings wps_;
};

// nl80211 sockets and the thread that drives the interfaces
class Engine {
 public:
  static Engine& Get();
  int Init();
  rhizo_wifi::Nl80211& nl() { return nl_; }
  void Add(const std::shared_ptr<StaIface>& iface);
  void Wake();

 private:
  void Run();

  std::mutex mu_;
  bool ready_ = false;
  rhizo_wifi::Nl80211 nl_;
  rhizo_wifi::Socket events_;
  int wake_ = -1;
  std::vector<std::shared_ptr<StaIface>> ifaces_;
  std::thread thread_;
};

}
