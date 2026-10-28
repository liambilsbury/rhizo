#ifndef RHIZO_POINTER_OBSERVATION_H_
#define RHIZO_POINTER_OBSERVATION_H_

#include <cstdint>

namespace rhizo {

// clamp the pointer position to the sprite extent
inline int32_t ReconcileObservedAxis(bool haveModel, int32_t model, int32_t origin,
                                     int32_t extent) {
  if (!haveModel || extent < 1) return origin;
  const int32_t last = origin + extent - 1;
  if (model < origin) return origin;
  if (model > last) return last;
  return model;
}

// Android 15 gives the base gain to a move after VelocityTracker's 40ms stop time or below the flat curve segment
constexpr int64_t kVelocityResetNs = 45LL * 1000000LL;
constexpr int64_t kFlatCountsPerSecond = 640;  // under the flat segment: 32 mm/s at 800 cpi is 1008 counts/s

// return whether a held move of dx,dy counts can be sent now at the curve's base gain
inline bool CanSendUnaccelerated(int64_t sinceLastSendNs, int64_t dx, int64_t dy) {
  if (sinceLastSendNs >= kVelocityResetNs) return true;
  if (sinceLastSendNs <= 0) return false;
  const int64_t limit = kFlatCountsPerSecond * sinceLastSendNs / 1000000000LL;
  return dx * dx + dy * dy <= limit * limit;
}

}

#endif
