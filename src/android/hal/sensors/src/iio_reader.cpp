// read a sensor's IIO channel files
#include "iio_reader.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <cmath>

#include "log.h"

namespace rhizo::sensors {

namespace {

// read a file from offset 0, returning bytes or -errno
ssize_t preadAll(int fd, char* buf, size_t cap) {
  for (;;) {
    ssize_t n = pread(fd, buf, cap, 0);
    if (n < 0 && errno == EINTR) continue;
    return n < 0 ? -errno : n;
  }
}

// read a number from an attribute file
bool readNumberFile(const std::string& path, double* out) {
  int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  char buf[64];
  ssize_t n = preadAll(fd, buf, sizeof(buf) - 1);
  ::close(fd);
  if (n <= 0) return false;
  return parseIioValue(buf, static_cast<size_t>(n), out);
}

}

// return the CLOCK_BOOTTIME time in nanoseconds
int64_t bootTimeNs() {
  timespec ts{};
  clock_gettime(CLOCK_BOOTTIME, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

// parse an IIO integer or decimal value
bool parseIioValue(const char* text, size_t len, double* out) {
  char buf[64];
  if (len == 0 || len >= sizeof(buf)) return false;
  memcpy(buf, text, len);
  buf[len] = '\0';
  while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == ' ' || buf[len - 1] == '\t')) buf[--len] = '\0';
  size_t start = 0;
  while (start < len && (buf[start] == ' ' || buf[start] == '\t')) start++;
  if (start == len) return false;
  for (size_t i = start; i < len; i++) {
    char c = buf[i];
    if (!((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E')) return false;
  }
  errno = 0;
  char* end = nullptr;
  double v = strtod(buf + start, &end);
  if (errno == ERANGE || end != buf + len || !std::isfinite(v)) return false;
  *out = v;
  return true;
}

IioChannels::IioChannels(const SensorConf& conf)
    : conf_(conf), fds_(conf.channels.size(), -1), scale_(conf.channels.size()), offset_(conf.channels.size()) {
  for (size_t i = 0; i < conf.channels.size(); i++) {
    scale_[i] = conf.channels[i].scale;
    offset_[i] = conf.channels[i].offset;
  }
}

IioChannels::~IioChannels() {
  stop();
}

// open the channels and re-read the scale and offset paths
void IioChannels::start() {
  stop();
  for (size_t i = 0; i < conf_.channels.size(); i++) {
    const ChannelConf& c = conf_.channels[i];
    fds_[i] = ::open(c.path.c_str(), O_RDONLY | O_CLOEXEC);
    scale_[i] = c.scale;
    offset_[i] = c.offset;
    double v = 0;
    if (!c.scalePath.empty()) {
      if (readNumberFile(c.scalePath, &v) && v != 0) {
        scale_[i] = v * unitFactor(conf_.kind);
      } else {
        klogf("%s: %s unreadable, using the launch-time scale %g", conf_.name.c_str(), c.scalePath.c_str(), c.scale);
      }
    }
    if (!c.offsetPath.empty()) {
      if (readNumberFile(c.offsetPath, &v)) {
        offset_[i] = v;
      } else {
        klogf("%s: %s unreadable, using the launch-time offset %g", conf_.name.c_str(), c.offsetPath.c_str(), c.offset);
      }
    }
  }
}

// close the channels
void IioChannels::stop() {
  for (int& fd : fds_) {
    if (fd >= 0) ::close(fd);
    fd = -1;
  }
}

// read the channels, returning 0 or the first failure's errno
int IioChannels::read(Reading* out, std::string* failedPath) {
  double raw[3] = {0, 0, 0};
  size_t n = conf_.channels.size();
  for (size_t i = 0; i < n; i++) {
    const std::string& path = conf_.channels[i].path;
    if (fds_[i] < 0) {
      fds_[i] = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
      if (fds_[i] < 0) {
        if (failedPath) *failedPath = path;
        return errno ? errno : EIO;
      }
    }
    char buf[64];
    ssize_t got = preadAll(fds_[i], buf, sizeof(buf) - 1);
    int err = 0;
    if (got < 0) err = static_cast<int>(-got);
    else if (got == 0 || !parseIioValue(buf, static_cast<size_t>(got), &raw[i])) err = EIO;
    if (err) {
      ::close(fds_[i]);
      fds_[i] = -1;
      if (failedPath) *failedPath = path;
      return err;
    }
  }
  int64_t ts = bootTimeNs();
  double val[3] = {0, 0, 0};
  for (size_t i = 0; i < n; i++) val[i] = (raw[i] + offset_[i]) * scale_[i];
  out->timestampNs = ts;
  out->count = static_cast<int>(n);
  if (isVector(conf_.kind)) {
    const double* m = conf_.matrix;
    for (int r = 0; r < 3; r++) {
      out->v[r] = static_cast<float>(m[r * 3] * val[0] + m[r * 3 + 1] * val[1] + m[r * 3 + 2] * val[2]);
    }
  } else {
    out->v[0] = static_cast<float>(val[0]);
    out->v[1] = out->v[2] = 0;
  }
  return 0;
}

// record a read's result
void ReadHealth::note(int err, const std::string& failedPath) {
  if (err && !paused_) {
    paused_ = true;
    klogf("%s paused: %s: %s", name_.c_str(), failedPath.c_str(), strerror(err));
  } else if (!err && paused_) {
    paused_ = false;
    klogf("%s resumed", name_.c_str());
  }
}

}
