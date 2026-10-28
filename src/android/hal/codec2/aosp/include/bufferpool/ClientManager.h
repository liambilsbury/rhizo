#ifndef RHIZO_C2_AOSP_HIDL_BUFFERPOOL_CLIENT_MANAGER_H
#define RHIZO_C2_AOSP_HIDL_BUFFERPOOL_CLIENT_MANAGER_H

// stub the HIDL bufferpool 2.0 ClientManager

#include <stdint.h>

#include <memory>
#include <vector>

#include <cutils/native_handle.h>
#include <utils/RefBase.h>
#include <utils/StrongPointer.h>

#include <bufferpool/BufferPoolTypes.h>

namespace android::hardware::media::bufferpool::V2_0::implementation {

struct ClientManager : public virtual RefBase {
  static sp<ClientManager> getInstance() { return nullptr; }

  ResultStatus create(const std::shared_ptr<BufferPoolAllocator>&, ConnectionId*) {
    return ResultStatus::CRITICAL_ERROR;
  }
  ResultStatus close(ConnectionId) { return ResultStatus::CRITICAL_ERROR; }
  ResultStatus flush(ConnectionId) { return ResultStatus::CRITICAL_ERROR; }
  ResultStatus allocate(ConnectionId, const std::vector<uint8_t>&, native_handle_t**,
                        std::shared_ptr<BufferPoolData>*) {
    return ResultStatus::CRITICAL_ERROR;
  }
};

}

#endif
