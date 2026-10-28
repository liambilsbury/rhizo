#include "session_policy.h"

#include <errno.h>
#include <poll.h>
#include <time.h>

namespace rhizo::camera {

namespace {

constexpr int64_t kNsPerSecond = 1000000000LL;
constexpr int64_t kPacingSlackNs = 2000000;
constexpr double kRateSlack = 0.5;

int64_t MonotonicMs() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return int64_t(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

}

// return whether to deliver a frame at maxFps
bool FramePacer::accept(int64_t timestampNs, int32_t maxFps) {
  if (maxFps <= 0) return true;
  int64_t period = kNsPerSecond / maxFps;
  if (!started_ || maxFps != fps_) {
    started_ = true;
    fps_ = maxFps;
    next_ = timestampNs + period;
    return true;
  }
  int64_t slack = period / 10 < kPacingSlackNs ? period / 10 : kPacingSlackNs;
  if (timestampNs < next_ - slack) return false;
  if (timestampNs - next_ > period) next_ = timestampNs;
  next_ += period;
  return true;
}

// return whether a session reopens its host stream now
bool ShouldReopen(bool stopped, int consecutiveTimeouts, bool present, int64_t msSinceLastOpen) {
  if (!present || msSinceLastOpen < kReopenIntervalMs) return false;
  return stopped || consecutiveTimeouts >= kSilentTimeoutsBeforeReopen;
}

// return the rate to open a listed mode at
OpenRate ChooseOpenRate(uint32_t modeFpsNum, uint32_t modeFpsDen, int32_t maxFps, bool modeRateOnly) {
  OpenRate r{modeFpsNum, modeFpsDen, false};
  if (modeRateOnly || maxFps <= 0 || modeFpsDen == 0) return r;
  if (double(maxFps) + kRateSlack >= double(modeFpsNum) / modeFpsDen) return r;
  return OpenRate{static_cast<uint32_t>(maxFps), 1, true};
}

// return whether a stream must reopen to serve maxFps
bool NeedsFasterStream(double streamFps, double modeFps, int32_t maxFps) {
  return streamFps > 0 && maxFps > streamFps + kRateSlack && modeFps > streamFps + kRateSlack;
}

// wait up to timeoutMs for a sync fence or a readable wakeFd
FenceWait WaitFenceOrWake(int fenceFd, int wakeFd, int timeoutMs) {
  int64_t deadline = MonotonicMs() + timeoutMs;
  for (;;) {
    pollfd p[2] = {{fenceFd, POLLIN, 0}, {wakeFd, POLLIN, 0}};
    int left = static_cast<int>(deadline - MonotonicMs());
    if (left < 0) left = 0;
    int r = poll(p, wakeFd >= 0 ? 2 : 1, left);
    if (r < 0 && errno == EINTR) continue;
    if (r < 0) return FenceWait::kTimedOut;
    if (wakeFd >= 0 && (p[1].revents & POLLIN) != 0) return FenceWait::kWoken;
    if ((p[0].revents & POLLNVAL) != 0) return FenceWait::kTimedOut;
    if ((p[0].revents & (POLLIN | POLLERR | POLLHUP)) != 0) return FenceWait::kSignalled;
    if (r == 0 || left == 0) return FenceWait::kTimedOut;
  }
}

}
