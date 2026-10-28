#ifndef RHIZO_C2_AOSP_HIDL_BUFFERPOOL_V2_0_TYPES_H
#define RHIZO_C2_AOSP_HIDL_BUFFERPOOL_V2_0_TYPES_H

// the ResultStatus enum of HIDL bufferpool 2.0

#include <stdint.h>

namespace android::hardware::media::bufferpool::V2_0 {

enum ResultStatus : int32_t {
  OK = 0,
  NO_MEMORY = 1,
  ALREADY_EXISTS = 2,
  NOT_FOUND = 3,
  CRITICAL_ERROR = 4,
};

}

#endif
