#pragma once
#include <linux/genetlink.h>
#include <linux/netlink.h>
#include <linux/nl80211.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace rhizo_wifi {

// a borrowed byte range inside a netlink message
struct Span {
  const uint8_t* p = nullptr;
  size_t n = 0;
};

// netlink attributes keyed by type
class Attrs {
 public:
  Attrs() = default;
  Attrs(const uint8_t* p, size_t n) { Parse(p, n); }
  explicit Attrs(Span s) { Parse(s.p, s.n); }

  // index the attributes in a buffer
  void Parse(const uint8_t* p, size_t n) {
    while (n >= NLA_HDRLEN) {
      nlattr a;
      memcpy(&a, p, sizeof(a));
      if (a.nla_len < NLA_HDRLEN || a.nla_len > n) return;
      map_[a.nla_type & NLA_TYPE_MASK] = Span{p + NLA_HDRLEN, size_t(a.nla_len - NLA_HDRLEN)};
      const size_t step = NLA_ALIGN(a.nla_len);
      if (step >= n) return;
      p += step;
      n -= step;
    }
  }
  bool Has(int t) const { return map_.count(t) != 0; }
  Span Get(int t) const {
    auto it = map_.find(t);
    return it == map_.end() ? Span{} : it->second;
  }
  uint8_t U8(int t, uint8_t d = 0) const { return Scalar<uint8_t>(t, d); }
  uint16_t U16(int t, uint16_t d = 0) const { return Scalar<uint16_t>(t, d); }
  uint32_t U32(int t, uint32_t d = 0) const { return Scalar<uint32_t>(t, d); }
  uint64_t U64(int t, uint64_t d = 0) const { return Scalar<uint64_t>(t, d); }
  std::vector<uint8_t> Bytes(int t) const {
    Span s = Get(t);
    return std::vector<uint8_t>(s.p, s.p + s.n);
  }
  std::string Str(int t) const {
    Span s = Get(t);
    std::string out(reinterpret_cast<const char*>(s.p), s.n);
    while (!out.empty() && out.back() == '\0') out.pop_back();
    return out;
  }
  Attrs Nested(int t) const { return Attrs(Get(t)); }
  const std::map<int, Span>& All() const { return map_; }

 private:
  template <typename T>
  T Scalar(int t, T d) const {
    Span s = Get(t);
    if (s.n < sizeof(T)) return d;
    T v;
    memcpy(&v, s.p, sizeof(T));
    return v;
  }
  std::map<int, Span> map_;
};

// list the attributes of a nest with duplicates
inline std::vector<std::pair<int, Span>> NestList(Span s) {
  std::vector<std::pair<int, Span>> out;
  const uint8_t* p = s.p;
  size_t n = s.n;
  while (n >= NLA_HDRLEN) {
    nlattr a;
    memcpy(&a, p, sizeof(a));
    if (a.nla_len < NLA_HDRLEN || a.nla_len > n) break;
    out.emplace_back(a.nla_type & NLA_TYPE_MASK, Span{p + NLA_HDRLEN, size_t(a.nla_len - NLA_HDRLEN)});
    const size_t step = NLA_ALIGN(a.nla_len);
    if (step >= n) break;
    p += step;
    n -= step;
  }
  return out;
}

// generic netlink request under construction
class Msg {
 public:
  Msg(uint16_t family, uint8_t cmd, uint16_t flags) {
    buf_.resize(NLMSG_HDRLEN + GENL_HDRLEN);
    nlmsghdr h{};
    h.nlmsg_type = family;
    h.nlmsg_flags = flags;
    memcpy(buf_.data(), &h, sizeof(h));
    genlmsghdr g{};
    g.cmd = cmd;
    g.version = 1;
    memcpy(buf_.data() + NLMSG_HDRLEN, &g, sizeof(g));
  }
  void Put(uint16_t type, const void* data, size_t len) {
    nlattr a{};
    a.nla_len = uint16_t(NLA_HDRLEN + len);
    a.nla_type = type;
    const size_t at = buf_.size();
    buf_.resize(at + NLA_ALIGN(a.nla_len));
    memcpy(buf_.data() + at, &a, sizeof(a));
    if (len) memcpy(buf_.data() + at + NLA_HDRLEN, data, len);
  }
  void U8(uint16_t t, uint8_t v) { Put(t, &v, sizeof(v)); }
  void U16(uint16_t t, uint16_t v) { Put(t, &v, sizeof(v)); }
  void U32(uint16_t t, uint32_t v) { Put(t, &v, sizeof(v)); }
  void Flag(uint16_t t) { Put(t, nullptr, 0); }
  void Str(uint16_t t, const std::string& s) { Put(t, s.c_str(), s.size() + 1); }
  void Bytes(uint16_t t, const std::vector<uint8_t>& v) { Put(t, v.data(), v.size()); }
  size_t Begin(uint16_t t) {
    const size_t at = buf_.size();
    Put(t | NLA_F_NESTED, nullptr, 0);
    return at;
  }
  void End(size_t at) {
    const uint16_t len = uint16_t(buf_.size() - at);
    memcpy(buf_.data() + at, &len, sizeof(len));
  }
  std::vector<uint8_t>& Finish(uint32_t seq) {
    nlmsghdr h;
    memcpy(&h, buf_.data(), sizeof(h));
    h.nlmsg_len = uint32_t(buf_.size());
    h.nlmsg_seq = seq;
    memcpy(buf_.data(), &h, sizeof(h));
    return buf_;
  }
  uint16_t Flags() const {
    nlmsghdr h;
    memcpy(&h, buf_.data(), sizeof(h));
    return h.nlmsg_flags;
  }

 private:
  std::vector<uint8_t> buf_;
};

// received generic netlink message
struct Reply {
  uint8_t cmd = 0;
  Attrs attrs;
};

// NETLINK_GENERIC socket
class Socket {
 public:
  ~Socket() { Close(); }

  // open and bind the socket with a receive timeout
  bool Open(int timeout_ms) {
    Close();
    fd_ = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_GENERIC);
    if (fd_ < 0) return false;
    sockaddr_nl sa{};
    sa.nl_family = AF_NETLINK;
    if (bind(fd_, reinterpret_cast<sockaddr*>(&sa), sizeof(sa)) != 0) return Fail();
    socklen_t len = sizeof(sa);
    if (getsockname(fd_, reinterpret_cast<sockaddr*>(&sa), &len) != 0) return Fail();
    portid_ = sa.nl_pid;
    int one = 1;
    setsockopt(fd_, SOL_NETLINK, NETLINK_CAP_ACK, &one, sizeof(one));
    int rcvbuf = 1 << 18;
    setsockopt(fd_, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    if (timeout_ms > 0) {
      timeval tv{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
      setsockopt(fd_, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    }
    return true;
  }
  void Close() {
    if (fd_ >= 0) close(fd_);
    fd_ = -1;
  }
  int fd() const { return fd_; }

  // join a multicast group
  bool Join(uint32_t group) {
    return setsockopt(fd_, SOL_NETLINK, NETLINK_ADD_MEMBERSHIP, &group, sizeof(group)) == 0;
  }

  // send a request and return 0 or a negative errno
  int Request(Msg& m, const std::function<void(const Reply&)>& on_reply) {
    std::lock_guard<std::mutex> lg(mu_);
    if (fd_ < 0) return -EBADF;
    const uint32_t seq = ++seq_;
    const bool dump = (m.Flags() & NLM_F_DUMP) == NLM_F_DUMP;
    std::vector<uint8_t>& out = m.Finish(seq);
    sockaddr_nl to{};
    to.nl_family = AF_NETLINK;
    if (sendto(fd_, out.data(), out.size(), 0, reinterpret_cast<sockaddr*>(&to), sizeof(to)) < 0) return -errno;
    std::vector<uint8_t> buf(1 << 16);
    for (;;) {
      ssize_t n = recv(fd_, buf.data(), buf.size(), 0);
      if (n < 0) {
        if (errno == EINTR) continue;
        return errno == EAGAIN || errno == EWOULDBLOCK ? -ETIMEDOUT : -errno;
      }
      size_t left = size_t(n);
      const uint8_t* p = buf.data();
      while (left >= NLMSG_HDRLEN) {
        nlmsghdr h;
        memcpy(&h, p, sizeof(h));
        if (h.nlmsg_len < NLMSG_HDRLEN || h.nlmsg_len > left) break;
        const uint8_t* body = p + NLMSG_HDRLEN;
        const size_t blen = h.nlmsg_len - NLMSG_HDRLEN;
        const size_t step = NLMSG_ALIGN(h.nlmsg_len);
        p += step < left ? step : left;
        left -= step < left ? step : left;
        if (h.nlmsg_seq != seq || h.nlmsg_pid != portid_) continue;
        if (h.nlmsg_type == NLMSG_ERROR) {
          int err = 0;
          if (blen >= sizeof(int)) memcpy(&err, body, sizeof(int));
          if (err != 0 || !dump) return err;
          continue;
        }
        if (h.nlmsg_type == NLMSG_DONE) {
          int err = 0;
          if (blen >= sizeof(int)) memcpy(&err, body, sizeof(int));
          return err;
        }
        if (blen < GENL_HDRLEN) continue;
        genlmsghdr g;
        memcpy(&g, body, sizeof(g));
        Reply r;
        r.cmd = g.cmd;
        r.attrs.Parse(body + GENL_HDRLEN, blen - GENL_HDRLEN);
        if (on_reply) on_reply(r);
      }
    }
  }

  // read a datagram of events
  bool ReadEvents(const std::function<void(const Reply&)>& on_event) {
    std::vector<uint8_t> buf(1 << 16);
    ssize_t n = recv(fd_, buf.data(), buf.size(), MSG_DONTWAIT);
    if (n < 0) return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR || errno == ENOBUFS;
    size_t left = size_t(n);
    const uint8_t* p = buf.data();
    while (left >= NLMSG_HDRLEN) {
      nlmsghdr h;
      memcpy(&h, p, sizeof(h));
      if (h.nlmsg_len < NLMSG_HDRLEN || h.nlmsg_len > left) break;
      const uint8_t* body = p + NLMSG_HDRLEN;
      const size_t blen = h.nlmsg_len - NLMSG_HDRLEN;
      const size_t step = NLMSG_ALIGN(h.nlmsg_len);
      p += step < left ? step : left;
      left -= step < left ? step : left;
      if (h.nlmsg_type < NLMSG_MIN_TYPE || blen < GENL_HDRLEN) continue;
      genlmsghdr g;
      memcpy(&g, body, sizeof(g));
      Reply r;
      r.cmd = g.cmd;
      r.attrs.Parse(body + GENL_HDRLEN, blen - GENL_HDRLEN);
      on_event(r);
    }
    return true;
  }

 private:
  bool Fail() {
    Close();
    return false;
  }
  int fd_ = -1;
  uint32_t portid_ = 0;
  uint32_t seq_ = 0;
  std::mutex mu_;
};

// nl80211 family id and multicast groups
struct Family {
  uint16_t id = 0;
  std::map<std::string, uint32_t> groups;
};

// resolve a generic netlink family by name
inline int ResolveFamily(Socket& s, const char* name, Family* out) {
  Msg m(GENL_ID_CTRL, CTRL_CMD_GETFAMILY, NLM_F_REQUEST | NLM_F_ACK);
  m.Str(CTRL_ATTR_FAMILY_NAME, name);
  Family f;
  int rc = s.Request(m, [&](const Reply& r) {
    f.id = r.attrs.U16(CTRL_ATTR_FAMILY_ID);
    for (auto& g : NestList(r.attrs.Get(CTRL_ATTR_MCAST_GROUPS))) {
      Attrs ga(g.second);
      f.groups[ga.Str(CTRL_ATTR_MCAST_GRP_NAME)] = ga.U32(CTRL_ATTR_MCAST_GRP_ID);
    }
  });
  if (rc == 0 && f.id == 0) rc = -ENOENT;
  if (rc == 0) *out = f;
  return rc;
}

// netdev attributes from GET_INTERFACE
struct IfaceInfo {
  uint32_t wiphy = 0;
  uint32_t iftype = 0;
  std::array<uint8_t, 6> mac{};
  std::vector<uint8_t> ssid;
};

// wiphy attributes from a split GET_WIPHY dump
struct WiphyInfo {
  std::string name;
  uint32_t features = 0;
  bool band_5ghz = false;
  bool band_6ghz = false;
  bool sched_scan = false;
};

// entry of cfg80211's BSS table
struct Bss {
  std::array<uint8_t, 6> bssid{};
  uint32_t freq = 0;
  uint16_t capability = 0;
  int32_t signal_mbm = 0;
  uint32_t status = UINT32_MAX;
  std::vector<uint8_t> ssid;
  bool rsn = false;
  bool wpa = false;
};

// station statistics
struct Rate {
  uint32_t bitrate100k = 0;
  int tech = 0;
  int nss = 1;
  int width = 20;
};
struct StationInfo {
  int signal_dbm = 0;
  bool has_signal = false;
  Rate tx;
  Rate rx;
};

// read a rate-info nest into technology, streams and width
inline Rate ParseRate(const Attrs& r) {
  Rate out;
  out.bitrate100k = r.Has(NL80211_RATE_INFO_BITRATE32) ? r.U32(NL80211_RATE_INFO_BITRATE32)
                                                       : r.U16(NL80211_RATE_INFO_BITRATE);
  if (r.Has(NL80211_RATE_INFO_EHT_MCS)) {
    out.tech = 5;
    out.nss = r.U8(NL80211_RATE_INFO_EHT_NSS, 1);
  } else if (r.Has(NL80211_RATE_INFO_HE_MCS)) {
    out.tech = 4;
    out.nss = r.U8(NL80211_RATE_INFO_HE_NSS, 1);
  } else if (r.Has(NL80211_RATE_INFO_VHT_MCS)) {
    out.tech = 3;
    out.nss = r.U8(NL80211_RATE_INFO_VHT_NSS, 1);
  } else if (r.Has(NL80211_RATE_INFO_MCS)) {
    out.tech = 2;
    out.nss = r.U8(NL80211_RATE_INFO_MCS) / 8 + 1;
  } else {
    out.tech = 1;
  }
  if (r.Has(NL80211_RATE_INFO_320_MHZ_WIDTH)) out.width = 320;
  else if (r.Has(NL80211_RATE_INFO_160_MHZ_WIDTH)) out.width = 160;
  else if (r.Has(NL80211_RATE_INFO_80P80_MHZ_WIDTH)) out.width = 8080;
  else if (r.Has(NL80211_RATE_INFO_80_MHZ_WIDTH)) out.width = 80;
  else if (r.Has(NL80211_RATE_INFO_40_MHZ_WIDTH)) out.width = 40;
  if (out.nss < 1) out.nss = 1;
  return out;
}

// parse the SSID and WPA/RSN elements of an IE buffer
inline void ParseIes(const std::vector<uint8_t>& ies, Bss* b) {
  size_t i = 0;
  bool have_ssid = false;
  while (i + 2 <= ies.size()) {
    const uint8_t id = ies[i], len = ies[i + 1];
    if (i + 2 + len > ies.size()) break;
    const uint8_t* d = ies.data() + i + 2;
    if (id == 0 && !have_ssid) {
      b->ssid.assign(d, d + len);
      have_ssid = true;
    } else if (id == 48) {
      b->rsn = true;
    } else if (id == 221 && len >= 4 && d[0] == 0x00 && d[1] == 0x50 && d[2] == 0xf2 && d[3] == 0x01) {
      b->wpa = true;
    }
    i += 2 + len;
  }
}

// nl80211 requests over a socket
class Nl80211 {
 public:
  // open the request socket and resolve the family
  int Init() {
    if (!sock_.Open(4000)) return -errno;
    return ResolveFamily(sock_, NL80211_GENL_NAME, &family_);
  }
  const Family& family() const { return family_; }
  Socket& socket() { return sock_; }

  // read the interface attributes of a netdev
  int GetInterface(uint32_t ifindex, IfaceInfo* out) {
    Msg m(family_.id, NL80211_CMD_GET_INTERFACE, NLM_F_REQUEST | NLM_F_ACK);
    m.U32(NL80211_ATTR_IFINDEX, ifindex);
    bool got = false;
    int rc = sock_.Request(m, [&](const Reply& r) {
      if (r.cmd != NL80211_CMD_NEW_INTERFACE) return;
      got = true;
      out->wiphy = r.attrs.U32(NL80211_ATTR_WIPHY);
      out->iftype = r.attrs.U32(NL80211_ATTR_IFTYPE);
      Span mac = r.attrs.Get(NL80211_ATTR_MAC);
      if (mac.n == 6) memcpy(out->mac.data(), mac.p, 6);
      out->ssid = r.attrs.Bytes(NL80211_ATTR_SSID);
    });
    if (rc == 0 && !got) rc = -ENODEV;
    return rc;
  }

  // read a wiphy's name, features, bands and scheduled-scan support
  int GetWiphy(uint32_t wiphy, WiphyInfo* out) {
    Msg m(family_.id, NL80211_CMD_GET_WIPHY, NLM_F_REQUEST | NLM_F_ACK | NLM_F_DUMP);
    m.U32(NL80211_ATTR_WIPHY, wiphy);
    m.Flag(NL80211_ATTR_SPLIT_WIPHY_DUMP);
    WiphyInfo w;
    bool got = false;
    int rc = sock_.Request(m, [&](const Reply& r) {
      if (r.cmd != NL80211_CMD_NEW_WIPHY || r.attrs.U32(NL80211_ATTR_WIPHY, UINT32_MAX) != wiphy) return;
      got = true;
      if (r.attrs.Has(NL80211_ATTR_WIPHY_NAME)) w.name = r.attrs.Str(NL80211_ATTR_WIPHY_NAME);
      if (r.attrs.Has(NL80211_ATTR_FEATURE_FLAGS)) w.features = r.attrs.U32(NL80211_ATTR_FEATURE_FLAGS);
      for (auto& b : NestList(r.attrs.Get(NL80211_ATTR_WIPHY_BANDS))) {
        if (b.first == NL80211_BAND_5GHZ) w.band_5ghz = true;
        if (b.first == NL80211_BAND_6GHZ) w.band_6ghz = true;
      }
      if (r.attrs.U32(NL80211_ATTR_SCHED_SCAN_MAX_REQS) > 0) w.sched_scan = true;
      for (auto& c : NestList(r.attrs.Get(NL80211_ATTR_SUPPORTED_COMMANDS))) {
        uint32_t cmd = 0;
        if (c.second.n >= 4) memcpy(&cmd, c.second.p, 4);
        if (cmd == NL80211_CMD_START_SCHED_SCAN) w.sched_scan = true;
      }
    });
    if (rc == 0 && !got) rc = -ENODEV;
    if (rc == 0) *out = w;
    return rc;
  }

  // dump cfg80211's BSS table
  int GetScan(uint32_t ifindex, std::vector<Bss>* out) {
    Msg m(family_.id, NL80211_CMD_GET_SCAN, NLM_F_REQUEST | NLM_F_ACK | NLM_F_DUMP);
    m.U32(NL80211_ATTR_IFINDEX, ifindex);
    out->clear();
    return sock_.Request(m, [&](const Reply& r) {
      if (r.cmd != NL80211_CMD_NEW_SCAN_RESULTS || !r.attrs.Has(NL80211_ATTR_BSS)) return;
      Attrs a = r.attrs.Nested(NL80211_ATTR_BSS);
      Span id = a.Get(NL80211_BSS_BSSID);
      if (id.n != 6) return;
      Bss b;
      memcpy(b.bssid.data(), id.p, 6);
      b.freq = a.U32(NL80211_BSS_FREQUENCY);
      b.capability = a.U16(NL80211_BSS_CAPABILITY);
      b.signal_mbm = int32_t(a.U32(NL80211_BSS_SIGNAL_MBM));
      b.status = a.U32(NL80211_BSS_STATUS, UINT32_MAX);
      std::vector<uint8_t> ies = a.Bytes(NL80211_BSS_INFORMATION_ELEMENTS);
      if (ies.empty()) ies = a.Bytes(NL80211_BSS_BEACON_IES);
      ParseIes(ies, &b);
      out->push_back(std::move(b));
    });
  }

  // trigger a scan directed at an SSID
  int TriggerScan(uint32_t ifindex, const std::vector<uint8_t>& ssid) {
    Msg m(family_.id, NL80211_CMD_TRIGGER_SCAN, NLM_F_REQUEST | NLM_F_ACK);
    m.U32(NL80211_ATTR_IFINDEX, ifindex);
    size_t n = m.Begin(NL80211_ATTR_SCAN_SSIDS);
    m.Bytes(1, ssid);
    m.End(n);
    return sock_.Request(m, nullptr);
  }

  // connect to an open BSS
  int Connect(uint32_t ifindex, const std::vector<uint8_t>& ssid, const std::array<uint8_t, 6>& bssid,
              uint32_t freq) {
    Msg m(family_.id, NL80211_CMD_CONNECT, NLM_F_REQUEST | NLM_F_ACK);
    m.U32(NL80211_ATTR_IFINDEX, ifindex);
    m.Bytes(NL80211_ATTR_SSID, ssid);
    m.Put(NL80211_ATTR_MAC, bssid.data(), 6);
    if (freq) m.U32(NL80211_ATTR_WIPHY_FREQ, freq);
    m.U32(NL80211_ATTR_AUTH_TYPE, NL80211_AUTHTYPE_OPEN_SYSTEM);
    m.Flag(NL80211_ATTR_SOCKET_OWNER);
    return sock_.Request(m, nullptr);
  }

  // leave the current association
  int Disconnect(uint32_t ifindex, uint16_t reason) {
    Msg m(family_.id, NL80211_CMD_DISCONNECT, NLM_F_REQUEST | NLM_F_ACK);
    m.U32(NL80211_ATTR_IFINDEX, ifindex);
    m.U16(NL80211_ATTR_REASON_CODE, reason);
    return sock_.Request(m, nullptr);
  }

  // read a peer's signal and rates
  int GetStation(uint32_t ifindex, const std::array<uint8_t, 6>& mac, StationInfo* out) {
    Msg m(family_.id, NL80211_CMD_GET_STATION, NLM_F_REQUEST | NLM_F_ACK);
    m.U32(NL80211_ATTR_IFINDEX, ifindex);
    m.Put(NL80211_ATTR_MAC, mac.data(), 6);
    bool got = false;
    int rc = sock_.Request(m, [&](const Reply& r) {
      if (r.cmd != NL80211_CMD_NEW_STATION || !r.attrs.Has(NL80211_ATTR_STA_INFO)) return;
      got = true;
      Attrs s = r.attrs.Nested(NL80211_ATTR_STA_INFO);
      if (s.Has(NL80211_STA_INFO_SIGNAL)) {
        out->has_signal = true;
        out->signal_dbm = int8_t(s.U8(NL80211_STA_INFO_SIGNAL));
      }
      if (s.Has(NL80211_STA_INFO_TX_BITRATE)) out->tx = ParseRate(s.Nested(NL80211_STA_INFO_TX_BITRATE));
      if (s.Has(NL80211_STA_INFO_RX_BITRATE)) out->rx = ParseRate(s.Nested(NL80211_STA_INFO_RX_BITRATE));
    });
    if (rc == 0 && !got) rc = -ENOENT;
    return rc;
  }

  // set the interface's power-save state
  int SetPowerSave(uint32_t ifindex, bool on) {
    Msg m(family_.id, NL80211_CMD_SET_POWER_SAVE, NLM_F_REQUEST | NLM_F_ACK);
    m.U32(NL80211_ATTR_IFINDEX, ifindex);
    m.U32(NL80211_ATTR_PS_STATE, on ? NL80211_PS_ENABLED : NL80211_PS_DISABLED);
    return sock_.Request(m, nullptr);
  }

 private:
  Socket sock_;
  Family family_;
};

}
