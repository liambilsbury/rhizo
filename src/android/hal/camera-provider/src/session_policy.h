#ifndef RHIZO_CAMERA_SESSION_POLICY_H
#define RHIZO_CAMERA_SESSION_POLICY_H

// compute a camera session's frame pacing and reopen timing

#include <stdint.h>

namespace rhizo::camera {

constexpr int kReopenIntervalMs = 500;
constexpr int kSilentTimeoutsBeforeReopen = 2;

// drop host frames to hold delivery under a rate
class FramePacer {
 public:
  void reset() { started_ = false; }
  bool accept(int64_t timestampNs, int32_t maxFps);

 private:
  bool started_ = false;
  int32_t fps_ = 0;
  int64_t next_ = 0;
};

bool ShouldReopen(bool stopped, int consecutiveTimeouts, bool present, int64_t msSinceLastOpen);

// the rate to open a listed mode at
struct OpenRate {
  uint32_t fpsNum = 0;
  uint32_t fpsDen = 1;
  bool belowMode = false;
};

OpenRate ChooseOpenRate(uint32_t modeFpsNum, uint32_t modeFpsDen, int32_t maxFps, bool modeRateOnly);

bool NeedsFasterStream(double streamFps, double modeFps, int32_t maxFps);

enum class FenceWait { kSignalled, kWoken, kTimedOut };

FenceWait WaitFenceOrWake(int fenceFd, int wakeFd, int timeoutMs);

}

#endif
