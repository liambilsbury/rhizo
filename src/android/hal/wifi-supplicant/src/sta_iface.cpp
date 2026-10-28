#include "sta_iface.h"
#include "rhizo/wifi_netdev.h"
#include <poll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <algorithm>
#include <cerrno>
#include <cstring>

namespace rhizo_supplicant {

namespace {

constexpr auto kScanWait = std::chrono::seconds(10);
constexpr auto kConnectWait = std::chrono::seconds(10);
constexpr auto kLeaveWait = std::chrono::seconds(2);
constexpr auto kRetryDelay = std::chrono::seconds(5);
constexpr int kMaxNotFound = 5;
constexpr uint16_t kReasonDeauthLeaving = 3;
constexpr int kStatusUnspecified = 1;
constexpr uint16_t kCapPrivacy = 0x0010;
constexpr int32_t kWidth20 = 0, kWidth40 = 1, kWidth80 = 2, kWidth160 = 3, kWidth80P80 = 4, kWidth320 = 7;

// format a BSSID as text
std::string MacText(const std::array<uint8_t, 6>& m) {
  char buf[18];
  snprintf(buf, sizeof(buf), "%02x:%02x:%02x:%02x:%02x:%02x", m[0], m[1], m[2], m[3], m[4], m[5]);
  return buf;
}

// format an SSID as text with other bytes escaped
std::string SsidText(const std::vector<uint8_t>& s) {
  std::string out;
  for (uint8_t c : s) {
    if (c >= 0x20 && c < 0x7f && c != '\\') {
      out += char(c);
    } else {
      char buf[5];
      snprintf(buf, sizeof(buf), "\\x%02x", c);
      out += buf;
    }
  }
  return out;
}

// copy a 6-byte address into a byte vector
std::vector<uint8_t> Vec(const std::array<uint8_t, 6>& m) { return std::vector<uint8_t>(m.begin(), m.end()); }

// map a rate's width to a WifiChannelWidthInMhz value
int32_t WidthCode(int width) {
  switch (width) {
    case 40: return kWidth40;
    case 80: return kWidth80;
    case 160: return kWidth160;
    case 8080: return kWidth80P80;
    case 320: return kWidth320;
    default: return kWidth20;
  }
}

}

StaIface::StaIface(std::string name, uint32_t ifindex) : name_(std::move(name)), ifindex_(ifindex) {}

// queue a command
void StaIface::Post(Cmd cmd, int32_t net) {
  {
    std::lock_guard<std::mutex> lg(mu_);
    if (cmd == Cmd::kSelect || cmd == Cmd::kReassociate || cmd == Cmd::kReconnect) explicit_disconnect_ = false;
    if (cmd == Cmd::kDisconnect) explicit_disconnect_ = true;
    cmds_.emplace_back(cmd, net);
  }
  Engine::Get().Wake();
}

// run fn when the last callback's process has died
void StaIface::OnCallbacksDied(std::function<void()> fn) {
  callbacks_.OnDeath([fn](size_t left) {
    if (left == 0) fn();
  });
}

// handle an nl80211 event
void StaIface::OnNlEvent(const rhizo_wifi::Reply& r) {
  if (r.attrs.U32(NL80211_ATTR_IFINDEX) != ifindex_) return;
  std::lock_guard<std::mutex> lg(mu_);
  if (removed_) return;
  const auto now = Clock::now();
  if (r.cmd == NL80211_CMD_CONNECT) {
    const int status = r.attrs.U16(NL80211_ATTR_STATUS_CODE);
    const bool timed_out = r.attrs.Has(NL80211_ATTR_TIMED_OUT);
    if (phase_ == Phase::kLeaving) {
      if (status != 0 || timed_out) AfterLeaveLocked(now);
      return;
    }
    if (phase_ != Phase::kConnecting) return;
    if (status != 0 || timed_out) {
      RejectedLocked(status ? status : kStatusUnspecified, timed_out);
      return;
    }
    rhizo_wifi::Span mac = r.attrs.Get(NL80211_ATTR_MAC);
    if (mac.n == 6) memcpy(target_.bssid.data(), mac.p, 6);
    phase_ = Phase::kConnected;
    has_deadline_ = false;
    want_ = -1;
    EmitStateLocked(StaIfaceCallbackState::ASSOCIATED, true);
    const std::vector<uint8_t> bssid = Vec(target_.bssid);
    callbacks_.ForEach([&](const auto& cb) { cb->onBssidChanged(BssidChangeReason::ASSOC_COMPLETE, bssid); });
    EmitStateLocked(StaIfaceCallbackState::COMPLETED, true);
    klogf("%s connected to %s (%s, %u MHz)", name_.c_str(), SsidText(target_.ssid).c_str(),
          MacText(target_.bssid).c_str(), target_.freq);
  } else if (r.cmd == NL80211_CMD_DISCONNECT) {
    const uint16_t reason = r.attrs.U16(NL80211_ATTR_REASON_CODE, kReasonDeauthLeaving);
    const bool by_ap = r.attrs.Has(NL80211_ATTR_DISCONNECTED_BY_AP);
    if (phase_ == Phase::kConnected) {
      phase_ = Phase::kIdle;
      LostLocked(reason, !by_ap);
      if (by_ap && auto_reconnect_ && !explicit_disconnect_ && selected_ >= 0) BeginLocked(selected_, true, true, now);
    } else if (phase_ == Phase::kLeaving) {
      if (leaving_connected_) {
        leaving_connected_ = false;
        LostLocked(reason, !by_ap);
      }
      AfterLeaveLocked(now);
    } else if (phase_ == Phase::kConnecting) {
      RejectedLocked(kStatusUnspecified, false);
    }
  } else if (r.cmd == NL80211_CMD_NEW_SCAN_RESULTS || r.cmd == NL80211_CMD_SCAN_ABORTED) {
    if (phase_ == Phase::kScanning) {
      scanned_ = true;
      FindLocked(now);
    }
  }
}

// run queued commands, then an expired timer
void StaIface::Step(Clock::time_point now) {
  std::lock_guard<std::mutex> lg(mu_);
  while (!cmds_.empty() && !removed_) {
    auto c = cmds_.front();
    cmds_.pop_front();
    RunLocked(c.first, c.second, now);
  }
  if (removed_ || !has_deadline_ || now < deadline_) return;
  has_deadline_ = false;
  switch (phase_) {
    case Phase::kLeaving:
      if (leaving_connected_) {
        leaving_connected_ = false;
        LostLocked(kReasonDeauthLeaving, true);
      }
      AfterLeaveLocked(now);
      break;
    case Phase::kScanning:
      scanned_ = true;
      FindLocked(now);
      break;
    case Phase::kConnecting:
      klogf("%s association with %s timed out", name_.c_str(), MacText(target_.bssid).c_str());
      Engine::Get().nl().Disconnect(ifindex_, kReasonDeauthLeaving);
      RejectedLocked(kStatusUnspecified, true);
      break;
    case Phase::kRetryWait:
      FindLocked(now);
      break;
    default:
      break;
  }
}

// carry out a queued command
void StaIface::RunLocked(Cmd cmd, int32_t net, Clock::time_point now) {
  switch (cmd) {
    case Cmd::kSelect: {
      selected_ = net;
      NetworkConfig cfg;
      if (phase_ == Phase::kConnected && target_.net == net && ConfigLocked(net, &cfg) &&
          (!cfg.PinsBssid() || std::equal(cfg.bssid.begin(), cfg.bssid.end(), target_.bssid.begin()))) {
        EmitStateLocked(StaIfaceCallbackState::COMPLETED, true);
        return;
      }
      BeginLocked(net, true, true, now);
      return;
    }
    case Cmd::kEnable: {
      if (phase_ != Phase::kIdle || networks_.size() != 1) return;
      NetworkConfig cfg;
      rhizo_wifi::Bss bss;
      if (!ConfigLocked(net, &cfg) || !MatchLocked(cfg, &bss)) return;
      want_ = net;
      allow_scan_ = false;
      retry_ = false;
      scanned_ = true;
      ConnectLocked(cfg, bss, now);
      return;
    }
    case Cmd::kDisconnect:
      AbortLocked();
      return;
    case Cmd::kReconnect:
    case Cmd::kReassociate:
      if (selected_ >= 0) BeginLocked(selected_, true, true, now);
      return;
    case Cmd::kForget:
      if (selected_ == net) selected_ = -1;
      if (want_ == net || ((phase_ == Phase::kConnected || phase_ == Phase::kConnecting) && target_.net == net))
        AbortLocked();
      return;
    case Cmd::kRemove:
      if (phase_ == Phase::kConnected || phase_ == Phase::kConnecting || phase_ == Phase::kLeaving)
        Engine::Get().nl().Disconnect(ifindex_, kReasonDeauthLeaving);
      phase_ = Phase::kIdle;
      has_deadline_ = false;
      removed_ = true;
      finished_ = true;
      return;
  }
}

// start an attempt on a network
void StaIface::BeginLocked(int32_t net, bool allow_scan, bool retry, Clock::time_point now) {
  NetworkConfig cfg;
  if (!ConfigLocked(net, &cfg)) return;
  want_ = net;
  allow_scan_ = allow_scan;
  retry_ = retry;
  scanned_ = false;
  not_found_ = 0;
  if (phase_ == Phase::kLeaving) return;
  if (phase_ == Phase::kConnected || phase_ == Phase::kConnecting) {
    leaving_connected_ = phase_ == Phase::kConnected;
    int rc = Engine::Get().nl().Disconnect(ifindex_, kReasonDeauthLeaving);
    if (rc == 0) {
      phase_ = Phase::kLeaving;
      deadline_ = now + kLeaveWait;
      has_deadline_ = true;
      return;
    }
    klogf("%s leave before a new attempt FAILED: %s", name_.c_str(), strerror(-rc));
    if (leaving_connected_) LostLocked(kReasonDeauthLeaving, true);
    leaving_connected_ = false;
  }
  FindLocked(now);
}

// find the selected network in the BSS table
void StaIface::FindLocked(Clock::time_point now) {
  NetworkConfig cfg;
  if (want_ < 0 || !ConfigLocked(want_, &cfg)) {
    phase_ = Phase::kIdle;
    has_deadline_ = false;
    want_ = -1;
    EmitDisconnectedLocked();
    return;
  }
  rhizo_wifi::Bss bss;
  if (MatchLocked(cfg, &bss)) {
    ConnectLocked(cfg, bss, now);
    return;
  }
  if (allow_scan_ && !scanned_ && !cfg.ssid.empty()) {
    int rc = Engine::Get().nl().TriggerScan(ifindex_, cfg.ssid);
    if (rc == 0 || rc == -EBUSY) {
      phase_ = Phase::kScanning;
      deadline_ = now + kScanWait;
      has_deadline_ = true;
      target_ = Target{want_, cfg.ssid, {}, 0};
      EmitStateLocked(StaIfaceCallbackState::SCANNING, true);
      return;
    }
    klogf("%s scan for %s FAILED: %s", name_.c_str(), SsidText(cfg.ssid).c_str(), strerror(-rc));
  }
  NotFoundLocked(now);
}

// start associating with a BSS
void StaIface::ConnectLocked(const NetworkConfig& cfg, const rhizo_wifi::Bss& bss, Clock::time_point now) {
  target_ = Target{want_, cfg.ssid, bss.bssid, bss.freq};
  const std::vector<uint8_t> bssid = Vec(bss.bssid);
  callbacks_.ForEach([&](const auto& cb) { cb->onBssidChanged(BssidChangeReason::ASSOC_START, bssid); });
  EmitStateLocked(StaIfaceCallbackState::AUTHENTICATING, true);
  EmitStateLocked(StaIfaceCallbackState::ASSOCIATING, true);
  int rc = Engine::Get().nl().Connect(ifindex_, cfg.ssid, bss.bssid, bss.freq);
  if (rc != 0) {
    klogf("%s connect to %s FAILED: %s", name_.c_str(), MacText(bss.bssid).c_str(), strerror(-rc));
    RejectedLocked(kStatusUnspecified, false);
    return;
  }
  phase_ = Phase::kConnecting;
  deadline_ = now + kConnectWait;
  has_deadline_ = true;
  klogf("%s associating with %s (%s, %u MHz)", name_.c_str(), SsidText(cfg.ssid).c_str(),
        MacText(bss.bssid).c_str(), bss.freq);
}

// report the selected network missing and wait to look again
void StaIface::NotFoundLocked(Clock::time_point now) {
  NetworkConfig cfg;
  ConfigLocked(want_, &cfg);
  klogf("%s network %s not found", name_.c_str(), SsidText(cfg.ssid).c_str());
  callbacks_.ForEach([&](const auto& cb) { cb->onNetworkNotFound(cfg.ssid); });
  EmitDisconnectedLocked();
  if (retry_ && !explicit_disconnect_ && ++not_found_ < kMaxNotFound) {
    phase_ = Phase::kRetryWait;
    scanned_ = false;
    deadline_ = now + kRetryDelay;
    has_deadline_ = true;
    return;
  }
  phase_ = Phase::kIdle;
  has_deadline_ = false;
  want_ = -1;
}

// report a failed association
void StaIface::RejectedLocked(int status, bool timed_out) {
  AssociationRejectionData d;
  d.ssid = target_.ssid;
  d.bssid = Vec(target_.bssid);
  d.statusCode = StaIfaceStatusCode(status);
  d.timedOut = timed_out;
  callbacks_.ForEach([&](const auto& cb) { cb->onAssociationRejected(d); });
  klogf("%s association with %s rejected (status %d%s)", name_.c_str(), MacText(target_.bssid).c_str(), status,
        timed_out ? ", timed out" : "");
  phase_ = Phase::kIdle;
  has_deadline_ = false;
  want_ = -1;
  EmitDisconnectedLocked();
  target_ = Target{};
}

// report a lost association
void StaIface::LostLocked(uint16_t reason, bool locally) {
  const std::vector<uint8_t> bssid = Vec(target_.bssid);
  const auto code = StaIfaceReasonCode(reason ? reason : Bits(StaIfaceReasonCode::UNSPECIFIED));
  callbacks_.ForEach([&](const auto& cb) { cb->onDisconnected(bssid, locally, code); });
  klogf("%s disconnected from %s (reason %u, %s)", name_.c_str(), MacText(target_.bssid).c_str(), reason,
        locally ? "local" : "by the AP");
  EmitDisconnectedLocked();
  target_ = Target{};
}

// end any attempt and leave any association
void StaIface::AbortLocked() {
  want_ = -1;
  switch (phase_) {
    case Phase::kConnected: {
      int rc = Engine::Get().nl().Disconnect(ifindex_, kReasonDeauthLeaving);
      if (rc != 0) {
        klogf("%s disconnect FAILED: %s", name_.c_str(), strerror(-rc));
        phase_ = Phase::kIdle;
        LostLocked(kReasonDeauthLeaving, true);
        return;
      }
      phase_ = Phase::kLeaving;
      leaving_connected_ = true;
      deadline_ = Clock::now() + kLeaveWait;
      has_deadline_ = true;
      return;
    }
    case Phase::kConnecting:
      Engine::Get().nl().Disconnect(ifindex_, kReasonDeauthLeaving);
      [[fallthrough]];
    case Phase::kScanning:
    case Phase::kRetryWait:
      phase_ = Phase::kIdle;
      has_deadline_ = false;
      EmitDisconnectedLocked();
      target_ = Target{};
      return;
    default:
      return;
  }
}

// continue after the previous association is gone
void StaIface::AfterLeaveLocked(Clock::time_point now) {
  has_deadline_ = false;
  phase_ = Phase::kIdle;
  if (want_ >= 0) {
    FindLocked(now);
    return;
  }
  EmitDisconnectedLocked();
  target_ = Target{};
}

// pick the strongest open BSS of the network's SSID
bool StaIface::MatchLocked(const NetworkConfig& cfg, rhizo_wifi::Bss* out) {
  if (cfg.ssid.empty() || !cfg.Open()) return false;
  std::vector<rhizo_wifi::Bss> table;
  int rc = Engine::Get().nl().GetScan(ifindex_, &table);
  if (rc != 0) {
    klogf("%s BSS table unreadable: %s", name_.c_str(), strerror(-rc));
    return false;
  }
  bool found = false;
  for (const auto& b : table) {
    if (b.ssid != cfg.ssid || b.freq == 0) continue;
    if ((b.capability & kCapPrivacy) || b.rsn || b.wpa) continue;
    if (cfg.PinsBssid() && !std::equal(b.bssid.begin(), b.bssid.end(), cfg.bssid.begin())) continue;
    if (!found || b.signal_mbm > out->signal_mbm) *out = b;
    found = true;
  }
  return found;
}

// copy a network's configuration
bool StaIface::ConfigLocked(int32_t net, NetworkConfig* out) {
  auto it = networks_.find(net);
  if (it == networks_.end()) return false;
  *out = it->second->Config();
  return true;
}

// send a state change to the callbacks
void StaIface::EmitStateLocked(StaIfaceCallbackState s, bool network_specific) {
  SupplicantStateChangeData d;
  d.newState = s;
  d.id = -1;
  d.keyMgmtMask = KeyMgmtMask(0);
  d.frequencyMhz = 0;
  d.filsHlpSent = false;
  if (network_specific) {
    d.id = target_.net;
    d.ssid = target_.ssid;
    d.bssid = target_.bssid;
    d.frequencyMhz = int32_t(target_.freq);
    if (Bits(s) >= Bits(StaIfaceCallbackState::AUTHENTICATING)) d.keyMgmtMask = KeyMgmtMask::NONE;
  }
  state_ = s;
  callbacks_.ForEach([&](const auto& cb) { cb->onSupplicantStateChanged(d); });
}

// send DISCONNECTED unless it was the last state sent
void StaIface::EmitDisconnectedLocked() {
  if (state_ != StaIfaceCallbackState::DISCONNECTED) EmitStateLocked(StaIfaceCallbackState::DISCONNECTED, false);
}

// return the time of the next queued command or timer
bool StaIface::NextDeadline(Clock::time_point* at) {
  std::lock_guard<std::mutex> lg(mu_);
  if (!cmds_.empty()) {
    *at = Clock::now();
    return true;
  }
  if (!has_deadline_) return false;
  *at = deadline_;
  return true;
}

// return true once the interface is removed and wound down
bool StaIface::Finished() {
  std::lock_guard<std::mutex> lg(mu_);
  return finished_;
}

// take the interface out of service
void StaIface::Remove() {
  std::map<int32_t, std::shared_ptr<StaNetwork>> nets;
  {
    std::lock_guard<std::mutex> lg(mu_);
    valid_ = false;
    nets.swap(networks_);
    cmds_.emplace_back(Cmd::kRemove, -1);
  }
  for (auto& n : nets) n.second->Invalidate();
  callbacks_.Clear();
  Engine::Get().Wake();
}

// leave any association before the process exits
void StaIface::Shutdown() {
  std::lock_guard<std::mutex> lg(mu_);
  if (phase_ == Phase::kConnected || phase_ == Phase::kConnecting || phase_ == Phase::kLeaving)
    Engine::Get().nl().Disconnect(ifindex_, kReasonDeauthLeaving);
}

ScopedAStatus StaIface::getName(std::string* out) {
  if (!valid_) return Invalid();
  *out = name_;
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::getType(IfaceType* out) {
  if (!valid_) return Invalid();
  *out = IfaceType::STA;
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::registerCallback(const std::shared_ptr<ISupplicantStaIfaceCallback>& cb) {
  if (!valid_) return Invalid();
  if (!cb) return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
  callbacks_.Add(cb);
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::addNetwork(std::shared_ptr<ISupplicantStaNetwork>* out) {
  if (!valid_) return Invalid();
  std::shared_ptr<StaNetwork> net;
  {
    std::lock_guard<std::mutex> lg(mu_);
    const int32_t id = next_id_++;
    net = ndk::SharedRefBase::make<StaNetwork>(ref<StaIface>(), id, name_);
    networks_[id] = net;
  }
  callbacks_.ForEach([&](const auto& cb) { cb->onNetworkAdded(net->id()); });
  *out = net;
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::removeNetwork(int32_t id) {
  if (!valid_) return Invalid();
  std::shared_ptr<StaNetwork> net;
  {
    std::lock_guard<std::mutex> lg(mu_);
    auto it = networks_.find(id);
    if (it == networks_.end()) return Status(SupplicantStatusCode::FAILURE_NETWORK_UNKNOWN);
    net = it->second;
    networks_.erase(it);
    cmds_.emplace_back(Cmd::kForget, id);
  }
  net->Invalidate();
  Engine::Get().Wake();
  callbacks_.ForEach([&](const auto& cb) { cb->onNetworkRemoved(id); });
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::getNetwork(int32_t id, std::shared_ptr<ISupplicantStaNetwork>* out) {
  if (!valid_) return Invalid();
  std::lock_guard<std::mutex> lg(mu_);
  auto it = networks_.find(id);
  if (it == networks_.end()) return Status(SupplicantStatusCode::FAILURE_NETWORK_UNKNOWN);
  *out = it->second;
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::listNetworks(std::vector<int32_t>* out) {
  if (!valid_) return Invalid();
  std::lock_guard<std::mutex> lg(mu_);
  out->clear();
  for (auto& n : networks_) out->push_back(n.first);
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::disconnect() {
  if (!valid_) return Invalid();
  Post(Cmd::kDisconnect);
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::reconnect() {
  if (!valid_) return Invalid();
  {
    std::lock_guard<std::mutex> lg(mu_);
    if (!explicit_disconnect_) return Status(SupplicantStatusCode::FAILURE_IFACE_NOT_DISCONNECTED);
  }
  Post(Cmd::kReconnect);
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::reassociate() {
  if (!valid_) return Invalid();
  Post(Cmd::kReassociate);
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::enableAutoReconnect(bool enable) { return Record([&] { auto_reconnect_ = enable; }); }

ScopedAStatus StaIface::getMacAddress(std::vector<uint8_t>* out) {
  if (!valid_) return Invalid();
  std::array<uint8_t, 6> mac{};
  int rc = rhizo_wifi::GetHwAddr(name_, &mac);
  if (rc != 0) {
    klogf("%s address unreadable: %s", name_.c_str(), strerror(-rc));
    return Status(SupplicantStatusCode::FAILURE_UNKNOWN);
  }
  *out = Vec(mac);
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::getKeyMgmtCapabilities(KeyMgmtMask* out) {
  if (!valid_) return Invalid();
  *out = KeyMgmtMask::NONE;
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::getWpaDriverCapabilities(WpaDriverCapabilitiesMask* out) {
  if (!valid_) return Invalid();
  *out = WpaDriverCapabilitiesMask(0);
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::getConnectionCapabilities(ConnectionCapabilities* out) {
  if (!valid_) return Invalid();
  std::lock_guard<std::mutex> lg(mu_);
  *out = ConnectionCapabilities{};
  out->technology = WifiTechnology::UNKNOWN;
  out->legacyMode = LegacyMode::UNKNOWN;
  if (phase_ != Phase::kConnected) return ScopedAStatus::ok();
  rhizo_wifi::StationInfo st;
  int rc = Engine::Get().nl().GetStation(ifindex_, target_.bssid, &st);
  if (rc != 0) {
    klogf("%s station info unreadable: %s", name_.c_str(), strerror(-rc));
    return Status(SupplicantStatusCode::FAILURE_UNKNOWN);
  }
  out->technology = WifiTechnology(st.tx.tech);
  out->channelBandwidth = WidthCode(st.tx.width);
  out->maxNumberTxSpatialStreams = st.tx.nss;
  out->maxNumberRxSpatialStreams = st.rx.bitrate100k ? st.rx.nss : st.tx.nss;
  if (st.tx.tech == Bits(WifiTechnology::LEGACY)) {
    const uint32_t top = std::max(st.tx.bitrate100k, st.rx.bitrate100k);
    if (target_.freq >= 5000) out->legacyMode = LegacyMode::A_MODE;
    else out->legacyMode = top > 110 ? LegacyMode::G_MODE : LegacyMode::B_MODE;
  }
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::getConnectionMloLinksInfo(MloLinksInfo* out) {
  if (!valid_) return Invalid();
  *out = MloLinksInfo{};
  out->apMloLinkId = -1;
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::getSignalPollResults(std::vector<SignalPollResult>* out) {
  if (!valid_) return Invalid();
  std::lock_guard<std::mutex> lg(mu_);
  out->clear();
  if (phase_ != Phase::kConnected) return ScopedAStatus::ok();
  rhizo_wifi::StationInfo st;
  int rc = Engine::Get().nl().GetStation(ifindex_, target_.bssid, &st);
  if (rc != 0 || !st.has_signal) {
    klogf("%s signal poll FAILED: %s", name_.c_str(), rc ? strerror(-rc) : "no signal reported");
    return Status(SupplicantStatusCode::FAILURE_UNKNOWN);
  }
  SignalPollResult r;
  r.linkId = 0;
  r.currentRssiDbm = st.signal_dbm;
  r.txBitrateMbps = int32_t(st.tx.bitrate100k / 10);
  r.rxBitrateMbps = int32_t(st.rx.bitrate100k / 10);
  r.frequencyMhz = int32_t(target_.freq);
  out->push_back(r);
  return ScopedAStatus::ok();
}

ScopedAStatus StaIface::setPowerSave(bool enable) {
  if (!valid_) return Invalid();
  int rc = Engine::Get().nl().SetPowerSave(ifindex_, enable);
  if (rc == 0) return ScopedAStatus::ok();
  klogf("%s power save %s FAILED: %s", name_.c_str(), enable ? "on" : "off", strerror(-rc));
  return Status(rc == -EOPNOTSUPP ? SupplicantStatusCode::FAILURE_UNSUPPORTED : SupplicantStatusCode::FAILURE_UNKNOWN);
}

ScopedAStatus StaIface::setCountryCode(const std::vector<uint8_t>& code) {
  if (!valid_) return Invalid();
  if (code.size() != 2) return Status(SupplicantStatusCode::FAILURE_ARGS_INVALID);
  std::lock_guard<std::mutex> lg(mu_);
  if (code[0] != country_[0] || code[1] != country_[1]) {
    country_ = {code[0], code[1]};
    klogf("%s country code recorded as %c%c, not forwarded to cfg80211", name_.c_str(), code[0], code[1]);
  }
  return ScopedAStatus::ok();
}

ScopedAStatus StaNetwork::select() {
  if (!valid_) return Invalid();
  auto iface = iface_.lock();
  if (!iface) return Invalid();
  SetEnabled(true);
  iface->Post(StaIface::Cmd::kSelect, id_);
  return ScopedAStatus::ok();
}

ScopedAStatus StaNetwork::enable(bool no_connect) {
  if (!valid_) return Invalid();
  auto iface = iface_.lock();
  if (!iface) return Invalid();
  SetEnabled(true);
  if (!no_connect) iface->Post(StaIface::Cmd::kEnable, id_);
  return ScopedAStatus::ok();
}

ScopedAStatus StaNetwork::disable() {
  if (!valid_) return Invalid();
  auto iface = iface_.lock();
  if (!iface) return Invalid();
  SetEnabled(false);
  iface->Post(StaIface::Cmd::kForget, id_);
  return ScopedAStatus::ok();
}

// return the process-wide engine
Engine& Engine::Get() {
  static Engine* engine = new Engine();
  return *engine;
}

// open the nl80211 sockets and start the event thread once
int Engine::Init() {
  std::lock_guard<std::mutex> lg(mu_);
  if (ready_) return 0;
  int rc = nl_.Init();
  if (rc != 0) return rc;
  if (!events_.Open(0)) return -errno;
  for (const char* g : {NL80211_MULTICAST_GROUP_MLME, NL80211_MULTICAST_GROUP_SCAN}) {
    auto it = nl_.family().groups.find(g);
    if (it == nl_.family().groups.end() || !events_.Join(it->second)) {
      klogf("nl80211 group %s unavailable", g);
      return -ENOENT;
    }
  }
  wake_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (wake_ < 0) return -errno;
  thread_ = std::thread([this] { Run(); });
  ready_ = true;
  return 0;
}

// hand an interface to the event thread
void Engine::Add(const std::shared_ptr<StaIface>& iface) {
  {
    std::lock_guard<std::mutex> lg(mu_);
    ifaces_.push_back(iface);
  }
  Wake();
}

// wake the event thread
void Engine::Wake() {
  if (wake_ < 0) return;
  const uint64_t one = 1;
  if (write(wake_, &one, sizeof(one)) < 0 && errno != EAGAIN) klogf("engine wake FAILED: %s", strerror(errno));
}

// deliver nl80211 events, commands and timers to the interfaces
void Engine::Run() {
  for (;;) {
    std::vector<std::shared_ptr<StaIface>> snap;
    {
      std::lock_guard<std::mutex> lg(mu_);
      snap = ifaces_;
    }
    int timeout = -1;
    auto now = Clock::now();
    for (auto& i : snap) {
      Clock::time_point at;
      if (!i->NextDeadline(&at)) continue;
      const auto ms = at <= now ? 0
                                : int(std::chrono::duration_cast<std::chrono::milliseconds>(
                                          at - now + std::chrono::microseconds(999))
                                          .count());
      timeout = timeout < 0 ? ms : std::min(timeout, ms);
    }
    pollfd fds[2] = {{wake_, POLLIN, 0}, {events_.fd(), POLLIN, 0}};
    if (poll(fds, 2, timeout) < 0 && errno != EINTR) {
      klogf("engine poll FAILED: %s", strerror(errno));
      return;
    }
    if (fds[0].revents & POLLIN) {
      uint64_t drained;
      while (read(wake_, &drained, sizeof(drained)) > 0) {}
    }
    if (fds[1].revents & POLLIN) {
      if (!events_.ReadEvents([&](const rhizo_wifi::Reply& r) {
            for (auto& i : snap) i->OnNlEvent(r);
          }))
        klogf("nl80211 event read FAILED: %s", strerror(errno));
    }
    now = Clock::now();
    for (auto& i : snap) i->Step(now);
    std::lock_guard<std::mutex> lg(mu_);
    ifaces_.erase(std::remove_if(ifaces_.begin(), ifaces_.end(), [](const auto& i) { return i->Finished(); }),
                  ifaces_.end());
  }
}

}
