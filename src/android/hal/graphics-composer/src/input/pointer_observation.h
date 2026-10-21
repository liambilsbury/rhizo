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

}

#endif
