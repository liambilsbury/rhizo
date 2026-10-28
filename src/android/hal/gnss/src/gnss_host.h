#pragma once
#include "aidl/android/hardware/gnss/IGnssCallback.h"
#include "rhizo/device_state.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>

namespace rhizo_gnss_host {

using aidl::android::hardware::gnss::ElapsedRealtime;
using aidl::android::hardware::gnss::GnssLocation;
using aidl::android::hardware::gnss::IGnssCallback;

inline constexpr char kSourcePrefix[] = "host:";
inline constexpr size_t kMaxLineBytes = 512;
inline constexpr std::chrono::seconds kRetryDelay{2};
inline constexpr int64_t kDefaultIntervalMs = 1000;

// write a message to the kernel log
inline void Klog(const char* msg) { rhizo_device::Klog("rhizo-gnss", msg); }

// desktop fix from rhizo-locationd
struct HostFix {
  double latitudeDegrees = 0;
  double longitudeDegrees = 0;
  double accuracyMeters = 0;
  bool hasAltitude = false;
  double altitudeMeters = 0;
  bool hasSpeed = false;
  double speedMetersPerSec = 0;
  bool hasHeading = false;
  double headingDegrees = 0;
  int64_t timeMs = 0;
};

// return the socket path a --source value names
inline std::string SocketPathOf(const std::string& source) {
  const size_t prefix = sizeof(kSourcePrefix) - 1;
  if (source.compare(0, prefix, kSourcePrefix) != 0) return "";
  std::string path = source.substr(prefix);
  if (path.empty() || path[0] != '/' || path.size() >= sizeof(sockaddr_un::sun_path)) return "";
  return path;
}

// split a protocol line into its verb and key=value fields
inline std::string SplitLine(const std::string& line, std::map<std::string, std::string>* fields) {
  std::string verb;
  bool first = true;
  size_t i = 0;
  while (i < line.size()) {
    while (i < line.size() && line[i] == ' ') i++;
    size_t end = line.find(' ', i);
    if (end == std::string::npos) end = line.size();
    if (end > i) {
      std::string token = line.substr(i, end - i);
      size_t eq = token.find('=');
      if (first) {
        if (eq == std::string::npos) verb = token;
        first = false;
      } else if (eq != std::string::npos && eq > 0) {
        (*fields)[token.substr(0, eq)] = token.substr(eq + 1);
      }
    }
    i = end;
  }
  return verb;
}

// parse a finite number that fills the whole field
inline bool ParseNumber(const std::string& raw, double* out) {
  if (raw.empty()) return false;
  char* end = nullptr;
  errno = 0;
  double v = strtod(raw.c_str(), &end);
  if (end != raw.c_str() + raw.size() || errno == ERANGE || !std::isfinite(v)) return false;
  *out = v;
  return true;
}

// parse a positive integer that fills the whole field
inline bool ParseMillis(const std::string& raw, int64_t* out) {
  if (raw.empty() || raw[0] < '0' || raw[0] > '9') return false;
  char* end = nullptr;
  errno = 0;
  long long v = strtoll(raw.c_str(), &end, 10);
  if (end != raw.c_str() + raw.size() || errno == ERANGE || v <= 0) return false;
  *out = v;
  return true;
}

// parse an optional number field
inline bool ParseOptional(const std::map<std::string, std::string>& fields, const char* key,
                          bool* has, double* value) {
  auto it = fields.find(key);
  *has = false;
  if (it == fields.end()) return true;
  if (!ParseNumber(it->second, value)) return false;
  *has = true;
  return true;
}

// parse the fields of a fix line
inline bool ParseFix(const std::map<std::string, std::string>& fields, HostFix* fix) {
  auto lat = fields.find("lat");
  auto lon = fields.find("lon");
  auto acc = fields.find("acc");
  auto time = fields.find("time_ms");
  if (lat == fields.end() || lon == fields.end() || acc == fields.end() || time == fields.end())
    return false;
  if (!ParseNumber(lat->second, &fix->latitudeDegrees) || fix->latitudeDegrees < -90.0 ||
      fix->latitudeDegrees > 90.0)
    return false;
  if (!ParseNumber(lon->second, &fix->longitudeDegrees) || fix->longitudeDegrees < -180.0 ||
      fix->longitudeDegrees > 180.0)
    return false;
  if (!ParseNumber(acc->second, &fix->accuracyMeters) || fix->accuracyMeters < 0.0) return false;
  if (!ParseMillis(time->second, &fix->timeMs)) return false;
  if (!ParseOptional(fields, "alt", &fix->hasAltitude, &fix->altitudeMeters)) return false;
  if (!ParseOptional(fields, "speed", &fix->hasSpeed, &fix->speedMetersPerSec)) return false;
  if (fix->hasSpeed && fix->speedMetersPerSec < 0.0) return false;
  if (!ParseOptional(fields, "heading", &fix->hasHeading, &fix->headingDegrees)) return false;
  if (fix->hasHeading && (fix->headingDegrees < 0.0 || fix->headingDegrees > 360.0)) return false;
  if (fix->hasHeading && fix->headingDegrees == 360.0) fix->headingDegrees = 0.0;
  return true;
}

// return a fix's boot-clock time from its wall-clock age
inline int64_t FixElapsedRealtimeNs(int64_t fixTimeMs, int64_t nowRealMs, int64_t nowBootNs) {
  int64_t ageMs = nowRealMs - fixTimeMs;
  if (ageMs < 0) ageMs = 0;
  return nowBootNs - ageMs * 1000000;
}

// sanitize a daemon token
inline std::string LogToken(const std::string& raw) {
  std::string out;
  for (char c : raw) {
    if (out.size() >= 32) break;
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' ||
        c == '_')
      out.push_back(c);
  }
  return out.empty() ? "-" : out;
}

// return the wall-clock time in milliseconds
inline int64_t NowRealMs() {
  timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

// return the boot-time clock in nanoseconds
inline int64_t NowBootNs() {
  timespec ts;
  clock_gettime(CLOCK_BOOTTIME, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

// session with rhizo-locationd
class HostSource {
 public:
  // start the connection thread
  explicit HostSource(std::string path) : path_(std::move(path)), thread_([this] { run(); }) {}
  // stop the connection thread
  ~HostSource() {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      quit_ = true;
      wakeLocked();
    }
    cv_.notify_all();
    thread_.join();
  }

  HostSource(const HostSource&) = delete;
  HostSource& operator=(const HostSource&) = delete;

  // store the callback and report the source's capabilities
  void setCallback(const std::shared_ptr<IGnssCallback>& callback) {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      callback_ = callback;
    }
    callback->gnssSetCapabilitiesCb(IGnssCallback::CAPABILITY_SCHEDULING);
  }
  // return the stored callback
  std::shared_ptr<IGnssCallback> callback() {
    std::lock_guard<std::mutex> lg(mutex_);
    return callback_;
  }
  // set the interval sent in the next hello
  void setPositionIntervalMs(int64_t intervalMs) {
    std::lock_guard<std::mutex> lg(mutex_);
    intervalMs_ = intervalMs > 0 ? intervalMs : kDefaultIntervalMs;
  }
  // open a session that connects until it is stopped
  void start() {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (started_) return;
      started_ = true;
      session_++;
      lastTimeMs_ = 0;
    }
    cv_.notify_all();
  }
  // close the session and wait for a report in flight
  void stop() {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      started_ = false;
      wakeLocked();
    }
    cv_.notify_all();
    std::lock_guard<std::mutex> dispatchGuard(dispatch_);
  }
  // stop and drop the callback
  void close() {
    stop();
    std::lock_guard<std::mutex> lg(mutex_);
    callback_.reset();
  }

 private:
  // end a blocked read on the open connection
  void wakeLocked() {
    if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
  }
  // return true while a session is the open one
  bool currentLocked(uint64_t session) const { return !quit_ && started_ && session_ == session; }

  // connect and retry while the session is started
  void run() {
    std::unique_lock<std::mutex> lk(mutex_);
    while (!quit_) {
      if (!started_) {
        cv_.wait(lk);
        continue;
      }
      const uint64_t session = session_;
      const int64_t intervalMs = intervalMs_;
      lk.unlock();
      int fd = connectSocket(session);
      lk.lock();
      if (fd >= 0) {
        if (currentLocked(session)) {
          fd_ = fd;
          lk.unlock();
          serve(fd, session, intervalMs);
          lk.lock();
          fd_ = -1;
        }
        ::close(fd);
      }
      if (!currentLocked(session)) continue;
      cv_.wait_for(lk, kRetryDelay, [&] { return !currentLocked(session); });
    }
  }

  // log a refused connection once per session
  void logRefused(uint64_t session, const char* what, int err) {
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (refusedSession_ == session) return;
      refusedSession_ = session;
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "host source: %s %s: %s -- retrying every 2 s while started", what,
             path_.c_str(), strerror(err));
    Klog(buf);
  }

  // connect a socket to the daemon or return -1
  int connectSocket(uint64_t session) {
    sockaddr_un addr{};
    if (path_.size() >= sizeof(addr.sun_path)) {
      logRefused(session, "a socket path too long for", ENAMETOOLONG);
      return -1;
    }
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
      logRefused(session, "socket for", errno);
      return -1;
    }
    addr.sun_family = AF_UNIX;
    memcpy(addr.sun_path, path_.c_str(), path_.size());
    if (connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
      int err = errno;
      ::close(fd);
      logRefused(session, "connect", err);
      return -1;
    }
    return fd;
  }

  // send a whole buffer
  static bool sendAll(int fd, const char* data, size_t len) {
    while (len > 0) {
      ssize_t n = send(fd, data, len, MSG_NOSIGNAL);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return false;
      data += n;
      len -= static_cast<size_t>(n);
    }
    return true;
  }

  // send hello and read lines until the connection ends
  void serve(int fd, uint64_t session, int64_t intervalMs) {
    char hello[64];
    int len = snprintf(hello, sizeof(hello), "hello v=1 interval_ms=%lld\n",
                       static_cast<long long>(intervalMs));
    if (!sendAll(fd, hello, static_cast<size_t>(len))) {
      Klog("host source: hello not sent, the daemon closed the connection");
      return;
    }
    Klog("host source: connected to rhizo-locationd");
    std::string line;
    bool overlong = false;
    char buf[1024];
    for (;;) {
      ssize_t got = read(fd, buf, sizeof(buf));
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) break;
      for (ssize_t i = 0; i < got; i++) {
        if (buf[i] == '\n') {
          if (overlong) {
            Klog("host source: a line over 512 bytes was dropped");
          } else {
            handleLine(line, session);
          }
          line.clear();
          overlong = false;
        } else if (line.size() >= kMaxLineBytes) {
          overlong = true;
        } else {
          line.push_back(buf[i]);
        }
      }
    }
    std::lock_guard<std::mutex> lg(mutex_);
    if (currentLocked(session)) Klog("host source: the daemon closed the connection, retrying in 2 s");
  }

  // handle a line from the daemon
  void handleLine(const std::string& line, uint64_t session) {
    std::map<std::string, std::string> fields;
    std::string verb = SplitLine(line, &fields);
    if (verb == "fix") {
      HostFix fix;
      if (!ParseFix(fields, &fix)) {
        Klog("host source: a malformed fix was dropped");
        return;
      }
      report(fix, session);
    } else if (verb == "state") {
      auto value = fields.find("value");
      auto reason = fields.find("reason");
      char buf[160];
      snprintf(buf, sizeof(buf), "host source: state %s reason=%s",
               LogToken(value == fields.end() ? "" : value->second).c_str(),
               LogToken(reason == fields.end() ? "" : reason->second).c_str());
      Klog(buf);
    }
  }

  // report a new fix with its boot time
  void report(const HostFix& fix, uint64_t session) {
    std::lock_guard<std::mutex> dispatchGuard(dispatch_);
    std::shared_ptr<IGnssCallback> cb;
    bool first;
    {
      std::lock_guard<std::mutex> lg(mutex_);
      if (!currentLocked(session) || fix.timeMs == lastTimeMs_) return;
      first = lastTimeMs_ == 0;
      lastTimeMs_ = fix.timeMs;
      cb = callback_;
    }
    if (!cb) return;
    const int64_t nowRealMs = NowRealMs();
    const int64_t elapsedNs = FixElapsedRealtimeNs(fix.timeMs, nowRealMs, NowBootNs());
    if (elapsedNs <= 0) {
      Klog("host source: a fix taken before this boot was dropped");
      return;
    }
    GnssLocation loc;
    loc.gnssLocationFlags = GnssLocation::HAS_LAT_LONG | GnssLocation::HAS_HORIZONTAL_ACCURACY;
    loc.latitudeDegrees = fix.latitudeDegrees;
    loc.longitudeDegrees = fix.longitudeDegrees;
    loc.horizontalAccuracyMeters = fix.accuracyMeters;
    if (fix.hasAltitude) {
      loc.gnssLocationFlags |= GnssLocation::HAS_ALTITUDE;
      loc.altitudeMeters = fix.altitudeMeters;
    }
    if (fix.hasSpeed) {
      loc.gnssLocationFlags |= GnssLocation::HAS_SPEED;
      loc.speedMetersPerSec = fix.speedMetersPerSec;
    }
    if (fix.hasHeading) {
      loc.gnssLocationFlags |= GnssLocation::HAS_BEARING;
      loc.bearingDegrees = fix.headingDegrees;
    }
    loc.timestampMillis = fix.timeMs;
    loc.elapsedRealtime.flags = ElapsedRealtime::HAS_TIMESTAMP_NS;
    loc.elapsedRealtime.timestampNs = elapsedNs;
    cb->gnssLocationCb(loc);
    if (first) {
      char buf[128];
      snprintf(buf, sizeof(buf), "host source: first fix of the session reported, age %lld ms",
               static_cast<long long>(nowRealMs - fix.timeMs));
      Klog(buf);
    }
  }

  const std::string path_;
  std::mutex mutex_;
  std::mutex dispatch_;
  std::condition_variable cv_;
  bool quit_ = false;
  bool started_ = false;
  uint64_t session_ = 0;
  uint64_t refusedSession_ = 0;
  int64_t intervalMs_ = kDefaultIntervalMs;
  int64_t lastTimeMs_ = 0;
  int fd_ = -1;
  std::shared_ptr<IGnssCallback> callback_;
  std::thread thread_;
};

}
