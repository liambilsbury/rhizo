#pragma once

#include "socket_link.h"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace rhizo_rtd {

using rhizo_link::kDeniedRetryNs;
using rhizo_link::kRetryNs;
using rhizo_link::MonotonicNs;

// join integers into a comma-separated string
template <typename T>
std::string JoinCsv(const std::vector<T>& values) {
  std::string out;
  for (size_t i = 0; i < values.size(); i++) {
    if (i) out += ',';
    out += std::to_string(values[i]);
  }
  return out;
}

// link to rhizo-rtd
class RtdLink {
 public:
  using LogFn = rhizo_link::LogFn;
  using ClockFn = rhizo_link::ClockFn;
  using ConnectFn = rhizo_link::ConnectFn;

  // store the link settings and try the first connect
  RtdLink(std::string path, LogFn log, ClockFn now = MonotonicNs, ConnectFn connect_fn = ::connect)
      : link_(std::move(path), "power_sessions", log, now, connect_fn) {
    std::lock_guard<std::mutex> lock(mu_);
    ConnectLocked();
  }

  // return whether the link is up, connecting when due
  bool TryConnect() {
    std::lock_guard<std::mutex> lock(mu_);
    return EnsureLocked();
  }

  // record a session and send its open
  void Open(int32_t sid, int32_t tgid, int32_t uid, int64_t target_ns, const std::vector<int32_t>& tids) {
    std::lock_guard<std::mutex> lock(mu_);
    Session& s = sessions_[sid];
    s = Session{tgid, uid, target_ns, tids, false};
    Deliver(OpenLine(sid, s), true);
  }

  // record a session's target duration and send it
  void Target(int32_t sid, int64_t target_ns) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = sessions_.find(sid);
    if (it == sessions_.end()) return;
    it->second.target_ns = target_ns;
    Deliver("target " + std::to_string(sid) + " " + std::to_string(target_ns), true);
  }

  // record a session's thread ids and send them
  void Threads(int32_t sid, const std::vector<int32_t>& tids) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = sessions_.find(sid);
    if (it == sessions_.end()) return;
    it->second.tids = tids;
    Deliver("threads " + std::to_string(sid) + " " + JoinCsv(tids), true);
  }

  // record a session's pause state and send it
  void SetPaused(int32_t sid, bool paused) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = sessions_.find(sid);
    if (it == sessions_.end()) return;
    it->second.paused = paused;
    Deliver((paused ? "pause " : "resume ") + std::to_string(sid), true);
  }

  // send a session's actual work durations
  void Actual(int32_t sid, const std::vector<int64_t>& durations_ns) {
    std::lock_guard<std::mutex> lock(mu_);
    if (sessions_.find(sid) == sessions_.end()) return;
    Deliver("actual " + std::to_string(sid) + " " + JoinCsv(durations_ns), false);
  }

  // forget a session and send its close
  bool Close(int32_t sid) {
    std::lock_guard<std::mutex> lock(mu_);
    if (sessions_.erase(sid) == 0) return false;
    Deliver("close " + std::to_string(sid), true);
    return true;
  }

  // return the number of open sessions
  size_t SessionCount() {
    std::lock_guard<std::mutex> lock(mu_);
    return sessions_.size();
  }

 private:
  struct Session {
    int32_t tgid;
    int32_t uid;
    int64_t target_ns;
    std::vector<int32_t> tids;
    bool paused;
  };

  // return the open message for a recorded session
  static std::string OpenLine(int32_t sid, const Session& s) {
    return "open " + std::to_string(sid) + " " + std::to_string(s.tgid) + " " + std::to_string(s.uid) + " " +
           std::to_string(s.target_ns) + " " + JoinCsv(s.tids);
  }

  // return whether the link is up, connecting when due
  bool EnsureLocked() {
    if (link_.fd() >= 0) return true;
    if (!link_.Due()) return false;
    return ConnectLocked();
  }

  // connect and reopen all of the recorded sessions
  bool ConnectLocked() { return link_.Connect() && ReplayLocked(); }

  // reopen all of the recorded sessions
  bool ReplayLocked() {
    for (const auto& [sid, s] : sessions_) {
      if (!SendLocked(OpenLine(sid, s)) || (s.paused && !SendLocked("pause " + std::to_string(sid)))) {
        DropLocked(errno);
        return false;
      }
    }
    if (!sessions_.empty()) {
      char buf[96];
      snprintf(buf, sizeof(buf), "rtd link reopened %zu session(s)", sessions_.size());
      link_.Log(buf);
    }
    return true;
  }

  bool SendLocked(const std::string& msg) { return link_.Send(msg); }

  // log the failed send and close the socket
  void DropLocked(int err) {
    char buf[160];
    snprintf(buf, sizeof(buf), "rtd send FAILED errno=%d (%s), link down", err, strerror(err));
    link_.Log(buf);
    link_.Close();
  }

  // send a message, reconnecting once on failure
  void Deliver(const std::string& msg, bool recorded) {
    if (link_.fd() >= 0) {
      if (SendLocked(msg)) return;
      DropLocked(errno);
      if (!ConnectLocked()) return;
    } else if (!EnsureLocked()) {
      return;
    }
    if (!recorded && !SendLocked(msg)) DropLocked(errno);
  }

  std::mutex mu_;
  rhizo_link::SocketLink link_;
  std::map<int32_t, Session> sessions_;
};

}
