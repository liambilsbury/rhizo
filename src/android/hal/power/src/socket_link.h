#pragma once

#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <utility>

namespace rhizo_link {

constexpr int64_t kRetryNs = 100 * 1000 * 1000;

constexpr int64_t kDeniedRetryNs = 10LL * 1000 * 1000 * 1000;

using LogFn = void (*)(const char*);
using ClockFn = int64_t (*)();
using ConnectFn = int (*)(int, const struct sockaddr*, socklen_t);

// return the monotonic time in nanoseconds
inline int64_t MonotonicNs() {
  struct timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000 + ts.tv_nsec;
}

// seqpacket client socket with connect logging
class SocketLink {
 public:
  // store the link settings
  SocketLink(std::string path, std::string marker, LogFn log, ClockFn now, ConnectFn connect_fn,
             int64_t timeout_us = 0)
      : path_(std::move(path)), marker_(std::move(marker)), log_(log), now_(now), connect_(connect_fn),
        timeout_us_(timeout_us) {}

  ~SocketLink() { Close(); }

  // return the connected socket, or -1 while the link is down
  int fd() const { return fd_; }

  // return whether the link is down and due for a connect
  bool Due() const { return fd_ < 0 && now_() - last_attempt_ns_ >= RetryNs(); }

  // connect to the socket and log the result
  bool Connect() {
    Close();
    last_attempt_ns_ = now_();
    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    int err = errno;
    if (fd >= 0) {
      struct sockaddr_un addr {};
      addr.sun_family = AF_UNIX;
      strncpy(addr.sun_path, path_.c_str(), sizeof(addr.sun_path) - 1);
      if (SetTimeouts(fd) && connect_(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) == 0) {
        fd_ = fd;
        last_error_ = 0;
        Mark(0);
        return true;
      }
      err = errno;
      close(fd);
    }
    last_error_ = err;
    Mark(err);
    return false;
  }

  // send a message and return whether it was sent
  bool Send(const std::string& msg) const {
    return send(fd_, msg.data(), msg.size(), MSG_NOSIGNAL) == static_cast<ssize_t>(msg.size());
  }

  void Close() {
    if (fd_ >= 0) close(fd_);
    fd_ = -1;
  }

  void Log(const char* msg) const {
    if (log_) log_(msg);
  }

 private:
  // return the connect retry interval
  int64_t RetryNs() const {
    return last_error_ == EACCES || last_error_ == EPERM ? kDeniedRetryNs : kRetryNs;
  }

  // set the send and receive timeout on the socket
  bool SetTimeouts(int fd) const {
    if (timeout_us_ <= 0) return true;
    struct timeval tv {};
    tv.tv_sec = static_cast<time_t>(timeout_us_ / 1000000);
    tv.tv_usec = static_cast<suseconds_t>(timeout_us_ % 1000000);
    return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) == 0 &&
           setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv)) == 0;
  }

  // log the on marker or a new off reason
  void Mark(int err) {
    char buf[200];
    if (err == 0) {
      snprintf(buf, sizeof(buf), "RHIZO_MARKER %s=on socket=%s", marker_.c_str(), path_.c_str());
    } else if (err == marked_) {
      return;
    } else {
      snprintf(buf, sizeof(buf), "RHIZO_MARKER %s=off reason=%s errno=%d", marker_.c_str(),
               err == ENOENT ? "absent" : strerror(err), err);
    }
    marked_ = err;
    Log(buf);
  }

  std::string path_;
  std::string marker_;
  LogFn log_;
  ClockFn now_;
  ConnectFn connect_;
  int64_t timeout_us_;
  int fd_ = -1;
  int last_error_ = 0;
  int64_t last_attempt_ns_ = 0;
  int marked_ = -1;
};

}
