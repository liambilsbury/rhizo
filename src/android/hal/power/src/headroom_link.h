#pragma once

#include "socket_link.h"

#include <sys/stat.h>

#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>

namespace rhizo_headroom {

using rhizo_link::kDeniedRetryNs;
using rhizo_link::kRetryNs;
using rhizo_link::MonotonicNs;

constexpr int64_t kTimeoutUs = 250 * 1000;

// link to rhizo-headroomd
class HeadroomLink {
 public:
  using LogFn = rhizo_link::LogFn;
  using ClockFn = rhizo_link::ClockFn;
  using ConnectFn = rhizo_link::ConnectFn;

  // store the link settings and try the first connect
  HeadroomLink(std::string path, LogFn log, ClockFn now = MonotonicNs, ConnectFn connect_fn = ::connect)
      : dir_(path.substr(0, path.rfind('/'))),
        link_(std::move(path), "power_headroom", log, now, connect_fn, kTimeoutUs) {
    std::lock_guard<std::mutex> lock(mu_);
    link_.Connect();
  }

  // return whether the socket directory is bound into the sandbox
  bool Supported() {
    std::lock_guard<std::mutex> lock(mu_);
    EnsureLocked();
    struct stat st {};
    if (!supported_) supported_ = stat(dir_.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
    return supported_;
  }

  // ask for the CPU headroom, reconnecting once on failure
  float Query(bool average, int32_t window_ms) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!EnsureLocked()) return NAN;
    char req[48];
    snprintf(req, sizeof(req), "headroom %s %d", average ? "average" : "min", window_ms);
    if (!link_.Send(req)) {
      DropLocked("send", errno);
      if (!link_.Connect()) return NAN;
      if (!link_.Send(req)) return DropLocked("send", errno);
    }
    return ReplyLocked();
  }

 private:
  // return whether the link is up, connecting when due
  bool EnsureLocked() { return link_.fd() >= 0 || (link_.Due() && link_.Connect()); }

  // read the reply and return its headroom, or NaN
  float ReplyLocked() {
    char rep[128];
    ssize_t n = recv(link_.fd(), rep, sizeof(rep) - 1, 0);
    if (n <= 0) return DropLocked(n == 0 ? "recv eof" : "recv", n == 0 ? 0 : errno);
    rep[n] = '\0';
    if (strncmp(rep, "nan ", 4) == 0) return NAN;
    if (strncmp(rep, "ok ", 3) == 0) {
      char* end = nullptr;
      float value = strtof(rep + 3, &end);
      if (end != rep + 3 && value >= 0.0f && value <= 100.0f) return value;
    }
    return DropLocked(rep, 0);
  }

  // log the failed exchange and close the socket
  float DropLocked(const char* what, int err) {
    char buf[200];
    snprintf(buf, sizeof(buf), "headroom link FAILED %s errno=%d (%s), link down", what, err,
             err ? strerror(err) : "none");
    link_.Log(buf);
    link_.Close();
    return NAN;
  }

  std::mutex mu_;
  std::string dir_;
  rhizo_link::SocketLink link_;
  bool supported_ = false;
};

}
